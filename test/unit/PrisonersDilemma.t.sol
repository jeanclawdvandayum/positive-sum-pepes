// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {PSPStaker} from "../../src/PSPStaker.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {StakerDeployer} from "../../src/StakerDeployer.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @title PrisonersDilemma — scoopy's 2026-08-29 commitment mechanics
/// @notice A live carpet-bomb vote commits its participants:
///           1. a wallet that cast a vote cannot arm a withdraw (any pepe)
///              until the vote concludes — and neither can anyone arm a
///              pepe that voted, even after transfer
///           2. NO ONE can cancel an armed withdraw while the vote is live,
///              including the gap between a passing vote and its execution
///         The game: seeing the pack race for the exits is exactly when you
///         vote — they are committed to leaving, you to staying, and the
///         flat curve pays everyone left the same average backing.
contract PrisonersDilemma is Test {
    MockPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;
    PSPStaker stakerV;
    RoundController controller;

    address alice = makeAddr("alice"); // the staker who springs the trap
    address bob = makeAddr("bob"); // the racer
    address carol = makeAddr("carol"); // bystander / transfer target
    PSPToken psp;

    // captured at launch — the referral carve-out leaves a little genesis
    // dust, so weights are NOT round numbers; every assert is exact against
    // these live values instead of hardcoded decimals
    uint256 aliceW; // alice's full claim weight
    uint256 bobW; // bob's full claim weight
    uint256 totalW; // totalVotable after both claims (alice + bob + husk)
    uint256 bobHalf; // bob's per-pepe stake after _bobTwoPepes

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();
        poolManager = new MockPoolManager();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)),
            IERC20(address(mixETH)),
            new HookDeployer(),
            new ControllerDeployer(),
            new StakerDeployer(),
            0
        );

        PSPFactory.RoundParams memory params;
        params.name = "Positive Sum Pepes";
        params.symbol = "PSP";
        params.curveConfig = CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);
        factory.deployRound(params);

        (PSPToken tok1, RoundController ctl1,,,,) = factory.rounds(1);
        controller = ctl1;
        stakerV = controller.staker();
        psp = tok1;

        mixETH.transfer(alice, 20_000e18);
        mixETH.transfer(bob, 20_000e18);
        mixETH.transfer(carol, 20_000e18);
    }

    // ─────────────── harness ───────────────

    /// @dev alice 60 / bob 40 predeposit → launch → both claim.
    ///      The predeposits land in epoch 0 (forge t≈1) but the LAUNCH is
    ///      warped into epoch 1: both `requestEpoch == 0` and
    ///      `lastPointEpoch == 0` are "nothing yet" sentinels, so an
    ///      epoch-0 anchor/arming would be invisible to the point walk
    ///      (unreachable in prod — real timestamps are epoch ~28k).
    function _launch() internal {
        vm.startPrank(alice);
        mixETH.approve(address(controller), 60e18);
        controller.predeposit(60e18);
        vm.stopPrank();
        vm.startPrank(bob);
        mixETH.approve(address(controller), 40e18);
        controller.predeposit(40e18);
        vm.stopPrank();
        vm.warp(7 days + 1); // the window also just closed - owner launches
        vm.prank(address(factory)); // owner may launch before the window closes
        controller.launchPooledBuy();
        vm.prank(alice);
        controller.claimPredepositPSP();
        vm.prank(bob);
        controller.claimPredepositPSP();

        aliceW = stakerV.voteWeight(alice, block.timestamp);
        bobW = stakerV.voteWeight(bob, block.timestamp);
        totalW = stakerV.totalVotable();
        // the staircase sells the boot slightly above the floor price, so
        // initial PSP ≈ 99,967e18, not 100e18 — exact against the snapshot
        assertEq(totalW, controller.totalInitialPSP(), "all initial PSP locked and votable");
    }

    function _pepe(address who) internal view returns (uint256) {
        return stakerV.tokenOfOwnerByIndex(who, 0);
    }

    function _arm(address who, uint256 pepeId) internal {
        vm.prank(who);
        stakerV.requestWithdraw(pepeId);
    }

    function _vote(address who, uint256 pepeId, bool support) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = pepeId;
        vm.prank(who);
        controller.voteCarpetBomb(ids, support);
    }

    function _propose(address who) internal returns (uint256 proposeTime) {
        vm.prank(who);
        controller.proposeCarpetBomb();
        (, proposeTime,,,,) = controller.getCarpetBombState();
    }

    function _warpPastVote() internal {
        (, uint256 proposeTime,,,,) = controller.getCarpetBombState();
        vm.warp(proposeTime + 3 days + 1);
    }

    /// @dev bob exits his genesis pepe the honest way (full 6-epoch decay),
    ///      then re-stakes as TWO pepes — one wallet with separate NFTs, so
    ///      the wallet-level and pepe-level arm guards can be told apart.
    function _bobTwoPepes() internal returns (uint256 b2, uint256 b3) {
        uint256 b1 = _pepe(bob);
        uint256 principal = stakerV.pepeVoteWeight(b1, block.timestamp);
        assertEq(principal, bobW, "sanity: bob's genesis pepe carries his full claim");

        _arm(bob, b1);
        vm.warp(stakerV.withdrawableAt(b1) + 1);
        vm.prank(bob);
        stakerV.withdraw(b1);
        assertEq(psp.balanceOf(bob), principal, "bob's principal back");

        vm.startPrank(bob);
        psp.approve(address(stakerV), type(uint256).max);
        bobHalf = psp.balanceOf(bob) / 2;
        stakerV.lock(bobHalf);
        stakerV.lock(psp.balanceOf(bob)); // sweep the odd remainder
        vm.stopPrank();
        uint256 n = stakerV.balanceOf(bob);
        b2 = stakerV.tokenOfOwnerByIndex(bob, n - 2); // b1 survives as a husk at index 0
        b3 = stakerV.tokenOfOwnerByIndex(bob, n - 1);
        assertEq(stakerV.totalVotable(), totalW, "denominator back after relock");
    }

    // ─────────────── 1. voters cannot arm ───────────────

    function test_VoterCannotArmAnyPepeWhileVoteLive() public {
        _launch();
        (uint256 b2, uint256 b3) = _bobTwoPepes();
        _propose(alice);

        // pepe guard: arming the very pepe that voted
        _vote(bob, b2, true);
        vm.prank(bob);
        vm.expectRevert(PSPStaker.VoteLocksArm.selector);
        stakerV.requestWithdraw(b2);

        // wallet guard: b3 NEVER voted, but its owner did — no hedging
        vm.prank(bob);
        vm.expectRevert(PSPStaker.VoteLocksArm.selector);
        stakerV.requestWithdraw(b3);

        // and the voter's commitment is recorded at the tally
        assertEq(controller.castWeightOn(controller.proposalCount(), bob), bobHalf);
    }

    function test_VotedPepeCannotBeArmedAfterTransfer() public {
        _launch();
        (uint256 b2,) = _bobTwoPepes();
        _propose(alice);
        _vote(bob, b2, true);

        // ship the voted pepe to a clean wallet — the vote rides along
        vm.prank(bob);
        stakerV.transferFrom(bob, carol, b2);
        assertEq(controller.castWeightOn(controller.proposalCount(), carol), 0, "carol cast nothing");

        vm.prank(carol);
        vm.expectRevert(PSPStaker.VoteLocksArm.selector);
        stakerV.requestWithdraw(b2);
    }

    function test_NonVoterCanArmWhileVoteLive() public {
        _launch();
        _propose(alice);
        assertTrue(controller.carpetVoteLive());

        // the dilemma cuts both ways: bob never voted, so he may still
        // choose the exit — and forfeit his vote (weight → 0)
        uint256 b1 = _pepe(bob);
        _arm(bob, b1);
        assertEq(stakerV.totalVotable(), totalW - bobW, "racer left the denominator");
        assertEq(stakerV.pepeVoteWeight(b1, block.timestamp), 0, "armed = mute");
    }

    // ─────────────── 2. cancels frozen while live ───────────────

    function test_CancelBlockedWhileVoteLive() public {
        _launch();
        uint256 b1 = _pepe(bob);
        _arm(bob, b1); // racer commits BEFORE the vote exists

        _propose(alice); // window opens → live
        vm.prank(bob);
        vm.expectRevert(PSPStaker.VoteLocksCancel.selector);
        stakerV.cancelWithdraw(b1);
    }

    function test_CancelBlockedBetweenPassAndExecution() public {
        _launch();
        uint256 b1 = _pepe(bob);
        _arm(bob, b1); // denominator is now alice + genesis husk

        _propose(alice);
        _vote(alice, _pepe(alice), true); // >99% quorum, unanimous majority
        _warpPastVote(); // window closed, passing, NOT yet executed

        assertTrue(controller.carpetVoteLive(), "passing vote stays live until executed");
        (,,,,, bool canExec) = controller.getCarpetBombState();
        assertTrue(canExec);

        vm.prank(bob);
        vm.expectRevert(PSPStaker.VoteLocksCancel.selector);
        stakerV.cancelWithdraw(b1);

        // execution releases everyone
        controller.carpetBomb();
        assertFalse(controller.carpetVoteLive());
    }

    function test_FailedVoteReleasesArmsAndVoters() public {
        _launch();
        (uint256 b2, uint256 b3) = _bobTwoPepes(); // two pepes, denominator totalW

        _arm(bob, b2); // racer commits BEFORE the vote
        _propose(alice);
        _vote(bob, b3, true); // ~25% < 69% quorum — and bob is now a voter too
        _warpPastVote();

        assertFalse(controller.carpetVoteLive(), "25% missed quorum - vote is dead");

        // the pre-armed racer may cancel again
        vm.prank(bob);
        stakerV.cancelWithdraw(b2);
        assertEq(stakerV.totalVotable(), totalW, "cancel restored the racer");

        // and the voter (even the pepe that voted) may arm once the failed
        // vote concluded — failure releases every commitment
        uint256 b3w = stakerV.pepeVoteWeight(b3, block.timestamp);
        vm.prank(bob);
        stakerV.requestWithdraw(b3);
        assertEq(stakerV.totalVotable(), totalW - b3w, "voter released after failure");
    }

    // ─────────────── 3. the endgame ───────────────

    function test_VoterExitsViaFlatAfterExecution() public {
        _launch();
        uint256 a1 = _pepe(alice);
        uint256 b1 = _pepe(bob);

        _arm(bob, b1); // racer shrinks the denominator
        _propose(alice);
        _vote(alice, a1, true); // >99% → passing
        _warpPastVote();
        controller.carpetBomb(); // → Flat

        // the voter's reward: every lock is open, exit at average backing
        vm.prank(alice);
        stakerV.withdraw(a1);
        assertEq(psp.balanceOf(alice), aliceW, "voter's principal out via flat");
    }

    function test_E2E_PrisonersDilemma() public {
        _launch();
        uint256 a1 = _pepe(alice);
        uint256 b1 = _pepe(bob);

        // bob races for the exit BEFORE any vote exists
        _arm(bob, b1);
        assertEq(stakerV.totalVotable(), totalW - bobW);

        // alice sees the race and springs the trap
        _propose(alice);

        // an armed racer is mute — he cannot even vote against the bomb
        uint256[] memory ids = new uint256[](1);
        ids[0] = b1;
        vm.prank(bob);
        vm.expectRevert(RoundController.NotLocker.selector);
        controller.voteCarpetBomb(ids, true);

        _vote(alice, a1, true); // >99% quorum, unanimous

        // bob is now committed: no cancel, no vote, no way back in
        vm.prank(bob);
        vm.expectRevert(PSPStaker.VoteLocksCancel.selector);
        stakerV.cancelWithdraw(b1);

        // the bomb detonates; the curve goes flat
        _warpPastVote();
        controller.carpetBomb();
        (,, CurveHook hook1,,,) = factory.rounds(1);
        assertEq(uint8(hook1.mode()), uint8(CurveHook.Mode.Flat));

        // both exit through the SAME flat window — no front-run advantage
        vm.prank(bob);
        stakerV.withdraw(b1); // armed pre-vote, flat bypasses the vest
        vm.prank(alice);
        stakerV.withdraw(a1);
        assertEq(psp.balanceOf(bob), bobW, "racer out at flat");
        assertEq(psp.balanceOf(alice), aliceW, "trapper out at flat");
    }
}
