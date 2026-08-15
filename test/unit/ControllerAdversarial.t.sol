// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockHook} from "../mocks/MockHook.sol";

/// @title ControllerAdversarial - Stress tests for fee accumulator, governance, access control
contract ControllerAdversarial is Test {
    RoundController controller;
    MockMixETH mixETH;
    PSPToken pspToken;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address factory = makeAddr("factory");
    address attacker = makeAddr("attacker");

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();

        CurveMath.CurveConfig memory params = CurveMath.singleCurve(
            0.0001e18,
            100_000_000e18,
            0.000000046e18,
            0.1e18
        );

        pspToken = new PSPToken("Positive Sum Pepes", "PSP", address(this));
        controller = new RoundController(pspToken, IERC20(address(mixETH)), params, factory);
        pspToken.setController(address(controller));

        vm.startPrank(address(controller));
        pspToken.mint(alice, 100_000e18);
        pspToken.mint(bob, 100_000e18);
        pspToken.mint(carol, 100_000e18);
        pspToken.mint(dave, 1_000e18);
        vm.stopPrank();

        address[4] memory users = [alice, bob, carol, dave];
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(users[i]);
            pspToken.approve(address(controller), type(uint256).max);
        }

        mixETH.transfer(address(controller), 50_000e18);
    }

    /// @dev Deploy + fund a real MockHook for fee tests
    function _setupHook() internal returns (MockHook) {
        MockHook hook = new MockHook(address(mixETH));
        mixETH.transfer(address(hook), 10_000e18);
        vm.prank(factory);
        controller.setHook(CurveHook(address(hook)));
        return hook;
    }

    // FEE ACCUMULATOR STRESS TESTS

    function test_Fee_ProportionalDistribution() public {
        vm.prank(alice);
        controller.lock(3000e18);
        vm.prank(bob);
        controller.lock(1000e18);

        MockHook hook = _setupHook();

        vm.prank(address(hook));
        controller.addFees(100e18);

        vm.prank(alice);
        controller.claimFees();
        uint256 aliceBalance = mixETH.balanceOf(alice);

        vm.prank(bob);
        controller.claimFees();
        uint256 bobBalance = mixETH.balanceOf(bob);

        assertApproxEqRel(aliceBalance, bobBalance * 3, 0.01e18, "Alice ~3x Bob");
    }

    function test_Fee_LateLockerGetsNoPastFees() public {
        vm.prank(alice);
        controller.lock(1000e18);

        MockHook hook = _setupHook();

        vm.prank(address(hook));
        controller.addFees(100e18);

        vm.prank(bob);
        controller.lock(1000e18);

        vm.prank(alice);
        controller.claimFees();
        assertTrue(mixETH.balanceOf(alice) > 0, "Alice gets fees");

        vm.prank(bob);
        vm.expectRevert(RoundController.NothingToClaim.selector);
        controller.claimFees();
    }

    function test_Fee_DoubleClaimNothing() public {
        vm.prank(alice);
        controller.lock(1000e18);

        MockHook hook = _setupHook();

        vm.prank(address(hook));
        controller.addFees(100e18);

        vm.prank(alice);
        controller.claimFees();
        uint256 firstClaim = mixETH.balanceOf(alice);
        assertTrue(firstClaim > 0, "First claim has value");

        vm.prank(alice);
        vm.expectRevert(RoundController.NothingToClaim.selector);
        controller.claimFees();
    }

    function test_Fee_IncrementalLock() public {
        MockHook hook = _setupHook();

        vm.prank(alice);
        controller.lock(1000e18);

        vm.prank(address(hook));
        controller.addFees(50e18);

        vm.prank(alice);
        controller.lock(1000e18);

        uint256 afterLock = mixETH.balanceOf(alice);
        assertTrue(afterLock > 0, "Claimed pending on re-lock");

        vm.prank(address(hook));
        controller.addFees(50e18);

        vm.prank(alice);
        controller.claimFees();
        assertTrue(mixETH.balanceOf(alice) > afterLock, "More after second claim");
    }

    function test_Fee_ThreeLockerDistribution() public {
        vm.prank(alice);
        controller.lock(5000e18);
        vm.prank(bob);
        controller.lock(3000e18);
        vm.prank(carol);
        controller.lock(2000e18);

        MockHook hook = _setupHook();

        vm.prank(address(hook));
        controller.addFees(1000e18);

        vm.prank(alice);
        controller.claimFees();
        uint256 aliceAmt = mixETH.balanceOf(alice);

        vm.prank(bob);
        controller.claimFees();
        uint256 bobAmt = mixETH.balanceOf(bob);

        vm.prank(carol);
        controller.claimFees();
        uint256 carolAmt = mixETH.balanceOf(carol);

        assertApproxEqRel(aliceAmt, 500e18, 0.02e18, "Alice ~500");
        assertApproxEqRel(bobAmt, 300e18, 0.02e18, "Bob ~300");
        assertApproxEqRel(carolAmt, 200e18, 0.02e18, "Carol ~200");
    }

    // GOVERNANCE ADVERSARIAL TESTS

    function test_Gov_DoubleProposalFails() public {
        vm.prank(alice);
        controller.lock(1000e18);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        vm.expectRevert(RoundController.ProposalExists.selector);
        controller.proposeCarpetBomb();
    }

    function test_Gov_AllNoVotesFailsQuorum() public {
        vm.prank(alice);
        controller.lock(5000e18);
        vm.prank(bob);
        controller.lock(5000e18);
        vm.warp(block.timestamp + 1); // M-1: locks must predate the proposal
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(false);
        vm.prank(bob);
        controller.voteCarpetBomb(false);
        vm.warp(block.timestamp + 3 days + 1);
        vm.expectRevert();
        controller.carpetBomb();
    }

    function test_Gov_SmallLockerLowVotingWeight() public {
        vm.prank(alice);
        controller.lock(99_000e18);
        vm.prank(dave);
        controller.lock(1_000e18);
        vm.warp(block.timestamp + 1); // M-1: locks must predate the proposal
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(dave);
        controller.voteCarpetBomb(true);
        vm.prank(alice);
        controller.voteCarpetBomb(false);
        vm.warp(block.timestamp + 3 days + 1);
        vm.expectRevert();
        controller.carpetBomb();
    }

    function test_Gov_VoteAfterPeriodFails() public {
        vm.prank(alice);
        controller.lock(1000e18);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(bob);
        controller.lock(1000e18);
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(bob);
        vm.expectRevert(RoundController.VotingEnded.selector);
        controller.voteCarpetBomb(true);
    }

    function test_Gov_ExactQuorumBoundary() public {
        // 69% quorum: 6900 of 10000 participate → passes quorum but majority fails
        vm.prank(alice);
        controller.lock(7000e18);
        vm.prank(bob);
        controller.lock(3000e18);
        vm.warp(block.timestamp + 1); // M-1: locks must predate the proposal
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        vm.prank(alice);
        controller.voteCarpetBomb(false);
        vm.warp(block.timestamp + 3 days + 1);
        // totalVotes = 10000 (100%), yes = 3000 → quorum passes but majority fails
        vm.expectRevert(RoundController.MajorityNotReached.selector);
        controller.carpetBomb();
    }

    function test_Gov_QuorumFailsBelow69Percent() public {
        // 50% participation — would pass old 30% quorum but fails new 69%
        vm.prank(alice);
        controller.lock(5000e18);
        vm.prank(bob);
        controller.lock(5000e18);
        // Only alice votes (5000 of 10000 = 50%)
        vm.warp(block.timestamp + 1); // M-1: locks must predate the proposal
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.warp(block.timestamp + 3 days + 1);
        // 5000/10000 = 50% < 69% quorum
        vm.expectRevert(RoundController.QuorumNotReached.selector);
        controller.carpetBomb();
    }

    function test_Gov_QuorumPassesExactly69Percent() public {
        // 69% participation, all yes → should succeed
        MockHook hook = _setupHook();
        vm.prank(factory);
        controller.setFactoryRoundId(1);

        vm.prank(alice);
        controller.lock(6900e18);
        vm.prank(bob);
        controller.lock(3100e18); // non-voter
        vm.warp(block.timestamp + 1); // M-1: locks must predate the proposal
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.warp(block.timestamp + 3 days + 1);
        // 6900/10000 = 69% exactly, all yes → quorum + majority both pass
        controller.carpetBomb();
        // Verify it executed
        (,,,, bool executed,) = controller.getCarpetBombState();
        assertTrue(executed);
    }

    function test_Gov_AttackerCantPropose() public {
        vm.prank(attacker);
        vm.expectRevert(RoundController.NotLocker.selector);
        controller.proposeCarpetBomb();
    }

    function test_Gov_AttackerCantForceExecute() public {
        vm.prank(alice);
        controller.lock(1000e18);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(attacker);
        vm.expectRevert();
        controller.carpetBomb();
    }

    // FUZZ: LOCKING + FEE DISTRIBUTION

    function testFuzz_ProportionalSplit(uint256 aliceLock, uint256 bobLock) public {
        aliceLock = bound(aliceLock, 1e18, 100_000e18);
        bobLock = bound(bobLock, 1e18, 100_000e18);

        vm.prank(alice);
        controller.lock(aliceLock);
        vm.prank(bob);
        controller.lock(bobLock);

        MockHook hook = _setupHook();

        vm.prank(address(hook));
        controller.addFees(100e18);

        vm.prank(alice);
        controller.claimFees();
        uint256 aBal = mixETH.balanceOf(alice);

        vm.prank(bob);
        controller.claimFees();
        uint256 bBal = mixETH.balanceOf(bob);

        assertTrue(aBal > 0 && bBal > 0, "Both got fees");
        uint256 expectedRatio = aliceLock * 1e18 / bobLock;
        uint256 actualRatio = aBal * 1e18 / bBal;
        assertApproxEqRel(expectedRatio, actualRatio, 0.02e18, "Ratio matches lock ratio");
    }

    function testFuzz_IncrementalLockingFees(
        uint256 lock1,
        uint256 fee1,
        uint256 lock2,
        uint256 fee2
    ) public {
        lock1 = bound(lock1, 1e18, 50_000e18);
        fee1 = bound(fee1, 1e18, 1000e18);
        lock2 = bound(lock2, 1e18, 50_000e18);
        fee2 = bound(fee2, 1e18, 1000e18);

        MockHook hook = _setupHook();

        vm.prank(alice);
        controller.lock(lock1);

        vm.prank(address(hook));
        controller.addFees(fee1);

        vm.prank(alice);
        controller.lock(lock2);
        uint256 firstClaim = mixETH.balanceOf(alice);

        vm.prank(address(hook));
        controller.addFees(fee2);

        vm.prank(alice);
        controller.claimFees();
        uint256 secondClaim = mixETH.balanceOf(alice) - firstClaim;

        assertTrue(firstClaim > 0, "First claim > 0");
        assertTrue(secondClaim > 0, "Second claim > 0");
    }
}
