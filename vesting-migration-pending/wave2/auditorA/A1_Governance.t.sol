// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AuditorBase} from "./AuditorBase.sol";
import {RoundController} from "../../../../src/RoundController.sol";
import {PSPStaker} from "../../../../src/PSPStaker.sol";
import {CurveHook} from "../../../../src/CurveHook.sol";

/// @title A1 — RoundController governance surface (carpet bomb voting)
/// @dev Independent auditor PoCs: quorum/majority math, vote-eligibility
///      (M-1), proposal lifecycle (G-2/G-3/G-4), supply-floor denominator.
contract A1_GovernanceTest is AuditorBase {
    // ─────────────────────────────────────────────────────────────
    // Quorum & majority math
    // ─────────────────────────────────────────────────────────────

    /// 60% cast < 69% quorum → carpetBomb reverts QuorumNotReached
    function test_quorum_subthreshold_reverts() public {
        _deposit(alice, 60e18);
        _deposit(bob, 40e18);
        _launch();
        _claim(alice);
        _claim(bob);

        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        // bob abstains → cast = 60% of locked
        vm.warp(block.timestamp + 3 days + 1);

        vm.expectRevert(RoundController.QuorumNotReached.selector);
        controller.carpetBomb();
    }

    /// 80% cast ≥ 69% quorum, 100% yes → executes
    function test_quorum_suprathreshold_executes() public {
        _deposit(alice, 80e18);
        _deposit(bob, 20e18);
        _launch();
        _claim(alice);
        _claim(bob);

        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.warp(block.timestamp + 3 days + 1);

        controller.carpetBomb();
        assertGt(controller.flatTime(), 0, "should be flat");
    }

    /// Tie (50/50) fails majority despite 100% quorum
    function test_majority_tie_fails() public {
        _deposit(alice, 50e18);
        _deposit(bob, 25e18);
        _deposit(carol, 25e18);
        _launch();
        _claim(alice);
        _claim(bob);
        _claim(carol);

        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(false);
        vm.prank(carol);
        controller.voteCarpetBomb(false);
        vm.warp(block.timestamp + 3 days + 1);

        vm.expectRevert(RoundController.MajorityNotReached.selector);
        controller.carpetBomb();
    }

    /// NK24 supply floor: quorum denominator = max(totalLocked, hook supply).
    /// Sole predepositor holding 100% of locked PSP still fails quorum when
    /// the hook supply (pot PSP + curve supply) is 2x the locked amount —
    /// the thin-lock capture vector stays dead.
    function test_supply_floor_blocks_thin_lock_capture() public {
        _deposit(alice, 100e18);
        _launch();
        _claim(alice); // alice = 100% of totalLocked == G

        // inflate hook supply 2x (v5.1: no pot mint — curve supply alone;
        //  the mock sets it directly, same denominator effect)
        uint256 g = stakerV.totalLocked();
        audHook.setSupply(audHook.totalSupplyPSP() + g);

        vm.prank(alice);
        controller.proposeCarpetBomb();
        (,,,, uint256 lockedAtPropose,) = controller.currentProposal();
        assertEq(lockedAtPropose, 2 * g, "denominator should be max(locked, supply)");

        vm.prank(alice);
        controller.voteCarpetBomb(true); // 100% of locked = only 50% of supply
        vm.warp(block.timestamp + 3 days + 1);

        vm.expectRevert(RoundController.QuorumNotReached.selector);
        controller.carpetBomb();
    }

    // ─────────────────────────────────────────────────────────────
    // M-1: only pre-propose locks vote
    // ─────────────────────────────────────────────────────────────

    /// Locking fresh PSP after propose → vote reverts
    function test_M1_lock_after_propose_cannot_vote() public {
        _deposit(alice, 60e18);
        _deposit(bob, 40e18);
        _launch();
        _claim(alice);
        _claim(bob);

        // give eve liquid PSP via alice's expired lock (90d)
        vm.warp(block.timestamp + 90 days);
        vm.prank(alice);
        stakerV.unlock();
        uint256 alicePSP = psp.balanceOf(alice);
        vm.prank(alice);
        psp.transfer(eve, alicePSP / 2);

        // eve locks at T, bob proposes at the SAME T afterwards
        vm.prank(eve);
        psp.approve(address(stakerV), alicePSP / 2);
        vm.prank(eve);
        stakerV.lock(alicePSP / 2); // lockTime = now

        vm.prank(bob);
        controller.proposeCarpetBomb(); // proposeTime == eve's lockTime

        vm.prank(eve);
        vm.expectRevert(RoundController.VoteLockedAfterPropose.selector);
        controller.voteCarpetBomb(true);
    }

    /// relock() after propose resets lockTime → vote reverts
    function test_M1_relock_after_propose_cannot_vote() public {
        _deposit(alice, 60e18);
        _deposit(bob, 40e18);
        _launch();
        _claim(alice);
        _claim(bob);

        // open the relock window (last 7d of the 90d term)
        vm.warp(block.timestamp + 83 days);
        vm.prank(bob);
        stakerV.relock(); // lockTime = now

        vm.prank(alice);
        controller.proposeCarpetBomb(); // same timestamp, after relock

        vm.prank(bob);
        vm.expectRevert(RoundController.VoteLockedAfterPropose.selector);
        controller.voteCarpetBomb(true);
    }

    /// claimPredepositPSP() after propose resets lockTime → vote reverts
    function test_M1_claim_after_propose_cannot_vote() public {
        _deposit(alice, 60e18);
        _deposit(bob, 40e18);
        _deposit(dave, 10e18);
        _launch();
        _claim(alice);
        _claim(bob);
        // dave delays his claim

        vm.prank(alice);
        controller.proposeCarpetBomb();

        vm.warp(block.timestamp + 1); // claim strictly after propose
        vm.prank(dave);
        controller.claimPredepositPSP(); // lockTime = now > proposeTime

        vm.prank(dave);
        vm.expectRevert(RoundController.VoteLockedAfterPropose.selector);
        controller.voteCarpetBomb(true);
    }

    /// Locks cannot be exited mid-vote (90d term ≫ 3d window) — totalVotes
    /// is structurally capped at lockedAtPropose from below as well.
    function test_cannot_unlock_mid_vote() public {
        _deposit(alice, 60e18);
        _launch();
        _claim(alice);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);

        vm.prank(alice);
        vm.expectRevert(PSPStaker.LockNotExpired.selector);
        stakerV.unlock();
    }

    // ─────────────────────────────────────────────────────────────
    // G-2 / G-3 / G-4: proposal lifecycle
    // ─────────────────────────────────────────────────────────────

    /// A failed (sub-quorum) proposal is replaceable after its window;
    /// prior voters are re-enfranchised (G-3); the replacement can pass.
    function test_G2_failed_proposal_replaceable_voters_reenfranchised() public {
        _deposit(alice, 60e18);
        _deposit(bob, 40e18);
        _launch();
        _claim(alice);
        _claim(bob);

        // P1: alice alone proposes + votes (60% — will fail quorum)
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.warp(block.timestamp + 3 days + 1);
        vm.expectRevert(RoundController.QuorumNotReached.selector);
        controller.carpetBomb();

        // P2 replaces P1 (G-2: window closed + failed)
        vm.prank(bob);
        controller.proposeCarpetBomb();
        assertEq(controller.proposalCount(), 2, "proposalCount should advance");
        (address proposer,,,,,) = controller.currentProposal();
        assertEq(proposer, bob, "P2 proposer");

        // G-3: alice (voted on P1) votes again on P2 — no AlreadyVoted
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        _warpPastVote(); // absolute: past P2's window

        controller.carpetBomb();
        assertGt(controller.flatTime(), 0, "P2 should execute");
    }

    /// A PASSING-but-unexecuted proposal cannot be replaced (G-4) — an
    /// attacker cannot front-run execute() with propose() to wipe votes.
    function test_G4_passing_unexecuted_blocks_replacement() public {
        _deposit(alice, 100e18);
        _launch();
        _claim(alice);

        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true); // 100% cast
        vm.warp(block.timestamp + 3 days + 1); // executable, not executed

        vm.prank(alice);
        vm.expectRevert(RoundController.ProposalExists.selector);
        controller.proposeCarpetBomb();

        // still executable afterwards
        controller.carpetBomb();
        assertGt(controller.flatTime(), 0, "should execute");

        // and once flat, no new proposals at all
        vm.prank(alice);
        vm.expectRevert(RoundController.RoundDestroyed.selector);
        controller.proposeCarpetBomb();
    }

    /// No double voting on the same proposal
    function test_double_vote_reverts() public {
        _deposit(alice, 100e18);
        _launch();
        _claim(alice);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(alice);
        vm.expectRevert(RoundController.AlreadyVoted.selector);
        controller.voteCarpetBomb(true);
    }

    /// Voting before any proposal / after window / as non-locker
    function test_vote_gates() public {
        _deposit(alice, 100e18);
        _launch();
        _claim(alice);

        vm.prank(alice);
        vm.expectRevert(RoundController.ProposalExists.selector); // reused error name
        controller.voteCarpetBomb(true);

        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(alice);
        vm.expectRevert(RoundController.VotingEnded.selector);
        controller.voteCarpetBomb(true);

        vm.prank(bob);
        vm.expectRevert(PSPStaker.NotLocker.selector);
        controller.proposeCarpetBomb();
    }

    /// carpetBomb double-execution blocked
    function test_double_execute_reverts() public {
        _deposit(alice, 100e18);
        _launch();
        _claim(alice);
        _bomb(alice);
        vm.expectRevert(RoundController.AlreadyExecuted.selector);
        controller.carpetBomb();
    }

    /// Early execution (inside voting window) blocked
    function test_execute_inside_window_reverts() public {
        _deposit(alice, 100e18);
        _launch();
        _claim(alice);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.expectRevert(RoundController.VotingEnded.selector); // reused error name
        controller.carpetBomb();
    }

    /// Proposing during flat/destroyed rounds blocked (Z-1 governance side)
    function test_propose_blocked_when_flat() public {
        _deposit(alice, 100e18);
        _launch();
        _claim(alice);
        _bomb(alice);
        vm.prank(alice);
        vm.expectRevert(RoundController.RoundDestroyed.selector);
        controller.proposeCarpetBomb();
    }
}
