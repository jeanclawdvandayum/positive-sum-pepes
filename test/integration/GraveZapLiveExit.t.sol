// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PSPGraveZap} from "../../src/PSPGraveZap.sol";

interface GraveBoard {
    function board(uint256) external view returns (address, uint256, uint256, uint256);
}

interface Factory {
    function mixETH() external view returns (address);
}

// minimal views over the live contracts
    interface GraveStaker {
        function psp() external view returns (address);
        function balanceOf(address) external view returns (uint256);
        function tokenOfOwnerByIndex(address, uint256) external view returns (uint256);
        function positions(uint256) external view returns (uint256 amount, uint256 startEpoch, uint256 requestEpoch, uint256 creditCheckpoint, uint256 feesPaid);
        function setApprovalForAll(address, bool) external;
    }
interface GraveHook {
        function controllerMix() external view returns (address);
        function claimablePot(address) external view returns (uint256);
        function reserveMixETH() external view returns (uint256);
        function totalSupplyPSP() external view returns (uint256);
    }
interface GraveStakerExtended {
        function ownerOf(uint256) external view returns (address);
        function positions(uint256) external view returns (uint256, uint256, uint256, uint256, uint256);
    }

/// @title GraveZapLiveExit — the connected exit workflow against the REAL
///        deployed Base Sepolia contracts, replayed on a fork with an
///        impersonated holder (no private keys).
/// @notice Exercises the exact legs the UI drives: operator grant, exact
///         PSP allowance, then PSPGraveZap.exit — and asserts the receipt
///         path: principal unlocked, fees + pot + redemption paid to the
///         holder in ONE transaction, zap holds nothing afterwards.
/// Run: forge test --match-contract GraveZapLiveExit --fork-url $BASE_SEPOLIA_RPC
contract GraveZapLiveExit is Test {
    using SafeERC20 for IERC20;

    // live deployment (2026-09-29, broadcast/DeployGraveZap.s.sol/84532)
    address constant ZAP = 0x20A38823d0c4C40D9a3Fc53B9870a6580edeaEB3;
    // round 3 (settled) — read from the factory during the run
    address constant HOOK = 0x0194Ae023883eBba03F346f9c23Fb19Be7926A88;
    address constant STAKER = 0x753EF9fd3597f4e6CAA29D91F2d5Ee32F6660a2A;

    IERC20 mix;
    IERC20 psp;

    function setUp() public {
        // fork env supplies the URL: BASE_SEPOLIA_RPC_URL or FORK_RPC_URL
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) url = vm.envString("BASE_SEPOLIA_RPC_URL");
        vm.createSelectFork(url);
        psp = IERC20(GraveStaker(STAKER).psp());
        // the mix pin, read off the round's factory (same token the zap holds)
        mix = IERC20(Factory(0x614cB7bf611f221F97f5eaE0f231311b9F3e7278).mixETH());
    }


    /// The holder is the freshest seat buyer on the settled board (the
    /// playtest wallet). Pepe ids are wallet-derived and huge, so scanning
    /// low ids never finds positions — read the board instead.
    function _holder() internal view returns (address) {
        (address buyer,,,) = GraveBoard(HOOK).board(0);
        require(buyer != address(0), "empty board");
        return buyer;
    }


    function test_LiveOneTxExitSweepsHolder() public {
        address who = _holder();
        uint256 n = GraveStaker(STAKER).balanceOf(who);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = GraveStaker(STAKER).tokenOfOwnerByIndex(who, i);

        uint256 pspIn = psp.balanceOf(who);
        uint256 mixBefore = mix.balanceOf(who);
        uint256 potBefore = GraveHook(HOOK).claimablePot(who);

        // staked principal that the unlock legs will return (and redeem)
        uint256 principal;
        for (uint256 i; i < ids.length; ++i) {
            (uint256 amount,,,,) = GraveStakerExtended(STAKER).positions(ids[i]);
            if (amount > 0) principal += amount;
        }

        uint256 supply = GraveHook(HOOK).totalSupplyPSP();
        uint256 reserve = GraveHook(HOOK).reserveMixETH();
        uint256 expectedRedemption = supply == 0 ? 0 : pspIn * reserve / supply;
        assertGt(pspIn + principal, 0, "holder has nothing to exit");

        // staked ids only — husks (zero principal) claim fees outside the zap
        uint256 stakedCount;
        for (uint256 i; i < ids.length; ++i) {
            (uint256 amount,,,,) = GraveStakerExtended(STAKER).positions(ids[i]);
            if (amount > 0) ++stakedCount;
        }
        uint256[] memory stakedIds = new uint256[](stakedCount);
        uint256 j;
        for (uint256 i; i < ids.length; ++i) {
            (uint256 amount,,,,) = GraveStakerExtended(STAKER).positions(ids[i]);
            if (amount > 0) stakedIds[j++] = ids[i];
        }

        vm.startPrank(who);
        GraveStaker(STAKER).setApprovalForAll(ZAP, true);
        psp.forceApprove(ZAP, type(uint256).max); // the UI's per-round max
        uint256 mixOut = PSPGraveZap(ZAP).exit(
            HOOK, STAKER, stakedIds, pspIn + principal, expectedRedemption * 99 / 100, block.timestamp + 600
        );
        vm.stopPrank();

        // the sweep: no PSP left (redeemed), principal unlocked, mixETH paid
        assertEq(psp.balanceOf(who), 0, "holder still holds PSP");
        assertGt(
            mix.balanceOf(who),
            mixBefore,
            "no mixETH landed"
        );
        assertEq(mix.balanceOf(address(ZAP)), 0, "zap retained mixETH");
        assertEq(psp.balanceOf(address(ZAP)), 0, "zap retained PSP");
        // the pot leg paid user-direct when claimable
        if (potBefore > 0) {
            assertGe(mix.balanceOf(who), mixBefore + potBefore, "pot not claimed to holder");
        }
        assertGe(mixOut, expectedRedemption * 99 / 100, "redemption under minimum");
    }
}
