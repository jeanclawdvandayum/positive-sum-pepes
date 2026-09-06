// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {IRoundController} from "../src/interfaces/IRoundController.sol";

contract ReviewPSP is ERC20 {
    constructor() ERC20("Review PSP", "PSP") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Staking-only fixture: no fee balance or hook callbacks are needed here.
contract ReviewController {
    uint256 public constant VEST_DURATION = 6 days;
    uint256 public constant flatTime = 0;
    address public constant hookAddress = address(0);
    function genesis(PSPStaker s, uint256 amount) external { s.lockGenesis(amount); }
    function claim(PSPStaker s, address to, uint256 amount) external { s.claimGenesisShare(to, amount); }
}

/// @title SkillStakingReviewTest
/// @notice Withdrawal views agree with exits, and chosen art cannot crowd out fresh mints.
contract SkillStakingReviewTest is Test {
    ReviewPSP token;
    ReviewController controller;
    PSPStaker staking;
    address alice = makeAddr("review-alice");

    function setUp() public {
        token = new ReviewPSP();
        controller = new ReviewController();
        staking = new PSPStaker(IERC20(address(token)), IRoundController(address(controller)), address(0));
        token.mint(alice, 600e18);
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
    }

    function test_EpochZeroWithdrawalViewMatchesExecutableExit() public {
        vm.warp(1);
        vm.startPrank(alice);
        staking.lockWithPepe(600e18, 1);
        assertEq(staking.withdrawableAt(1), type(uint256).max);
        staking.requestWithdraw(1);
        assertEq(staking.withdrawableAt(1), 6 days);
        skip(6 days);
        staking.withdraw(1);
        assertEq(token.balanceOf(alice), 600e18);
        assertEq(staking.withdrawableAt(1), type(uint256).max);
        vm.stopPrank();
    }

    function test_GenesisClaimGasIndependentOfChosenIdRun() public {
        // These free hatches can be spread over many transactions. The claim
        // has its own fixed gas budget, independent of the setup budget.
        // Automatic minting fills the same ID run and resolves any art aliases.
        for (uint256 i = 1; i <= 2048; ++i) staking.lock(0);
        staking.lockWithPepe(0, uint256(uint160(alice))); // occupy the preferred ID/art
        token.mint(address(staking), 600e18);
        controller.genesis(staking, 600e18);
        vm.prank(address(controller));
        (bool ok,) = address(staking).call{gas: 450_000}(
            abi.encodeCall(staking.claimGenesisShare, (alice, 600e18))
        );
        assertTrue(ok, "chosen ID run must not make the next genesis claim scan every NFT");
        assertEq(staking.ownerOf(2049), alice);
        (uint256 amount,,,,) = staking.positions(2049);
        assertEq(amount, 600e18);
    }

    function test_ReferralStakeLookupGasIndependentOfUnsolicitedNfts() public {
        vm.prank(alice);
        staking.lockWithPepe(600e18, 9000);
        for (uint256 i = 1; i <= 1024; ++i) {
            staking.lockWithPepe(0, i);
            staking.transferFrom(address(this), alice, i);
        }
        (bool ok, bytes memory result) = address(staking).staticcall{gas: 30_000}(
            abi.encodeCall(staking.stakedTotalOf, (alice))
        );
        assertTrue(ok, "unsolicited empty NFTs must not increase referral qualification cost");
        assertEq(abi.decode(result, (uint256)), 600e18);
    }

    function test_PartialGenesisTopupTransferAndExitPreserveOwnerTotals() public {
        vm.warp(1);
        address bob = makeAddr("review-bob");
        token.mint(address(staking), 1200e18);
        controller.genesis(staking, 1200e18);
        assertEq(staking.stakedTotalOf(address(controller)), 0);
        assertEq(staking.stakedTotalOf(alice), 0);
        vm.prank(alice);
        staking.lockWithPepe(600e18, 42);
        controller.claim(staking, alice, 500e18);
        controller.claim(staking, bob, 700e18);
        assertEq(staking.stakedTotalOf(alice), 1100e18);
        assertEq(staking.stakedTotalOf(bob), 700e18);
        vm.prank(alice);
        staking.transferFrom(alice, bob, 42);
        vm.prank(bob);
        staking.transferFrom(bob, bob, 42);
        token.mint(address(this), 100e18);
        token.approve(address(staking), 100e18);
        staking.stakeFor(bob, 42, 100e18);
        assertEq(staking.stakedTotalOf(alice), 500e18);
        assertEq(staking.stakedTotalOf(bob), 1400e18);
        vm.prank(bob);
        staking.requestWithdraw(42);
        skip(6 days);
        vm.prank(bob);
        staking.withdraw(42);
        assertEq(staking.stakedTotalOf(alice), 500e18);
        assertEq(staking.stakedTotalOf(bob), 700e18);
        assertEq(staking.totalLocked(), 1200e18);
        assertEq(token.balanceOf(address(staking)), 1200e18);
    }

    function testFuzz_FreshIdsMatchIndependentOccupiedSet(uint256 seed) public {
        bool[129] memory occupied;
        uint256 expected = 1;
        for (uint256 i; i < 64; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            if (seed % 3 != 0) {
                uint256 chosen = 1 + seed % 128;
                if (occupied[chosen]) continue;
                staking.lockWithPepe(0, chosen);
                occupied[chosen] = true;
            } else {
                while (occupied[expected]) ++expected;
                vm.prank(alice);
                staking.lock(0);
                assertEq(staking.ownerOf(expected), alice);
                occupied[expected] = true;
            }
        }
        while (occupied[expected]) ++expected;
        vm.prank(alice);
        staking.lock(0);
        assertEq(staking.ownerOf(expected), alice);
    }

    function test_ChosenIdsAtUintBoundaryRemainValid() public {
        staking.lockWithPepe(0, type(uint256).max);
        staking.lockWithPepe(0, type(uint256).max - 2);
        staking.lockWithPepe(0, type(uint256).max - 1);
        vm.prank(alice);
        staking.lock(0);
        assertEq(staking.ownerOf(1), alice);
        assertEq(staking.ownerOf(type(uint256).max), address(this));
    }
}
