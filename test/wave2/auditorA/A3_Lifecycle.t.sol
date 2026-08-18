// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AuditorBase} from "./AuditorBase.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {PSPToken} from "../../../src/PSPToken.sol";
import {AuditorFactory} from "./AuditorMocks.sol";
import {AuditorHook} from "./AuditorMocks.sol";
import {FailFactory} from "./AuditorMocks.sol";
import {console2} from "forge-std/console2.sol";

/// @title A3 — lifecycle & phase-guard findings: post-launch carry/pot
///        seeding, flat-window pot stranding, finalize fee sweep, relock.
contract A3_LifecycleTest is AuditorBase {
    // ─────────────────────────────────────────────────────────────
    // F-1a: seedCarry() has no predepositClosed guard — post-launch
    //       invocation dilutes depositor claims 2x and hands the factory
    //       a fresh voting lock.
    // ─────────────────────────────────────────────────────────────
    function test_F1a_post_launch_seedCarry_dilutes_predepositors() public {
        _deposit(alice, 100e18);
        _launch();

        // factory (trusted owner side) seeds carry AFTER launch — accepted
        mixETH.transfer(address(audFactory), 100e18);
        vm.startPrank(address(audFactory));
        mixETH.approve(address(controller), 100e18);
        controller.seedCarry(100e18);
        vm.stopPrank();

        assertEq(controller.totalPredepositMixETH(), 200e18, "denominator inflated");
        (uint256 fDep,) = controller.predeposits(address(audFactory));
        assertEq(fDep, 100e18, "factory got a predeposit share post-launch");

        uint256 g = controller.genesisPSPSnapshot();
        _claim(alice);
        (uint256 aliceAmt,,,) = controller.locks(alice);
        assertApproxEqAbs(aliceAmt, (g * 100e18) / 200e18, 2, "alice's half-diluted share");
        assertLt(aliceAmt, g, "dilution: alice receives < her boot share");

        // factory claims the other half — and gains a governance lock
        vm.prank(address(audFactory));
        controller.claimPredepositPSP();
        (uint256 fAmt,,,) = controller.locks(address(audFactory));
        assertApproxEqAbs(fAmt, aliceAmt, 2, "factory captured half of genesis PSP");

        // conservation: no PSP created/lost, but 50% of alice's boot value
        // was redirected to the factory by one post-launch call
        assertApproxEqAbs(aliceAmt + fAmt, g, 2);
        _assertPspInvariant("post F1a");
    }

    /// Seeding after all genesis shares are claimed makes the factory's own
    /// claim panic (underflow on the exhausted genesis lock).
    function test_F1a2_factory_claim_after_genesis_exhausted_panics() public {
        _deposit(alice, 100e18);
        _launch();
        _claim(alice); // genesis lock drained to 0

        mixETH.transfer(address(audFactory), 100e18);
        vm.startPrank(address(audFactory));
        mixETH.approve(address(controller), 100e18);
        controller.seedCarry(100e18);
        vm.expectRevert(abi.encodeWithSelector(0x4e487b71, 0x11)); // Panic(0x11)
        controller.claimPredepositPSP();
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────
    // F-1b: potDeposit() post-launch — funds sit as "stray" mixETH and are
    //       owner-sweepable; totalPotMixETH ledger drifts.
    // ─────────────────────────────────────────────────────────────
    function test_F1b_post_launch_potDeposit_then_owner_sweep() public {
        _deposit(alice, 100e18);
        _launch();

        mixETH.transfer(address(audFactory), 50e18);
        vm.startPrank(address(audFactory));
        mixETH.approve(address(controller), 50e18);
        controller.potDeposit(50e18); // accepted post-launch
        vm.stopPrank();

        assertEq(controller.totalPotMixETH(), 50e18, "ledger records pot funding");
        assertEq(mixETH.balanceOf(address(controller)), 50e18, "mixETH idle at controller");
        assertEq(controller.potPSPBalance(), 0, "no pot PSP backs it");

        // post-launch mixETH is sweepable by the owner (I-1 stray-rescue)
        uint256 fBefore = mixETH.balanceOf(address(audFactory));
        vm.prank(address(audFactory));
        controller.sweep(address(mixETH));
        assertEq(mixETH.balanceOf(address(audFactory)), fBefore + 50e18, "pot funds swept");
        assertEq(controller.totalPotMixETH(), 50e18, "ledger still claims a pot");
    }

    // ─────────────────────────────────────────────────────────────
    // F-2: pot PSP accrued DURING the flat window can never be redeemed —
    //       carpetBomb already executed, finalizeCarpet ignores it.
    // ─────────────────────────────────────────────────────────────
    function test_F2_flat_window_pot_accrual_stranded_forever() public {
        _deposit(alice, 100e18);
        _launch();
        _claim(alice);
        _bomb(alice); // pot was 0 at bomb time
        assertEq(controller.potPSPBalance(), 0);

        // flat-window buy accrues pot (mintPotPSP — real PSP to controller)
        vm.prank(address(audHook));
        controller.mintPotPSP(1e21);
        // flat-window sell accrues pot (real PSP transfer + ledger credit)
        vm.startPrank(address(audHook));
        controller.mintPSPForSwap(1e20);
        psp.transfer(address(controller), 1e20);
        controller.creditPotPSP(1e20);
        vm.stopPrank();

        assertEq(controller.potPSPBalance(), 11e20);
        _assertPspInvariant("post flat trades");

        _warpPastFlatWindow();
        controller.finalizeCarpet();

        // F-2 core: nothing credited to the ring-fenced side pot
        assertEq(audFactory.sidePot(), 0, "flat-window pot never reached factory");
        assertEq(controller.potPSPBalance(), 11e20, "pot PSP stranded at controller");
        _assertPspInvariant("post finalize");
        assertEq(mixETH.balanceOf(address(audHook)), 0, "hook drained");
        assertEq(audFactory.spawnCount(), 1, "next round spawned");

        // no exit remains for the stranded pot
        vm.expectRevert(RoundController.AlreadyExecuted.selector);
        controller.carpetBomb();
        vm.prank(address(audFactory));
        vm.expectRevert(RoundController.ProtectedToken.selector);
        controller.sweep(address(psp));
    }

    // ─────────────────────────────────────────────────────────────
    // Verified-safe: pre-launch potDeposit + bomb-time redemption works
    // ─────────────────────────────────────────────────────────────
    function test_pot_redemption_happy_path() public {
        _deposit(alice, 100e18);
        mixETH.transfer(address(audFactory), 20e18);
        vm.startPrank(address(audFactory));
        mixETH.approve(address(controller), 20e18);
        controller.potDeposit(20e18); // PRE-launch — the intended path
        vm.stopPrank();

        _launch();
        uint256 initialPSP = audHook.totalSupplyPSP();
        uint256 expectedPotShare = (initialPSP * 20e18) / 120e18;
        _claim(alice);

        _bomb(alice);

        uint256 out = audFactory.sidePot();
        assertGt(out, 0, "pot redemption credited");
        assertEq(mixETH.balanceOf(address(audFactory)), out, "funds at factory");
        assertEq(controller.potPSPBalance(), 0, "pot ledger cleared");
        assertLt(audHook.totalSupplyPSP(), initialPSP, "hook supply reduced");
        assertApproxEqAbs(
            initialPSP - audHook.totalSupplyPSP(), expectedPotShare, 1, "burned ~ pot share"
        );
        _assertPspInvariant("post pot redemption");
    }

    // ─────────────────────────────────────────────────────────────
    // F-4: finalize drains unclaimed staker fees into the carry
    // ─────────────────────────────────────────────────────────────
    function test_finalize_sweeps_unclaimed_fees_bob_forfeits() public {
        _deposit(alice, 60e18);
        _deposit(bob, 40e18);
        _launch();
        _claim(alice);
        _claim(bob);
        (uint256 bobShare,,,) = controller.locks(bob);

        mixETH.transfer(address(audHook), 100e18);
        vm.prank(address(audHook));
        controller.addFees(100e18);

        // alice claims hers in time
        uint256 aBefore = mixETH.balanceOf(alice);
        vm.prank(alice);
        controller.claimFees();
        assertApproxEqRel(mixETH.balanceOf(alice) - aBefore, 60e18, 1e15);

        // both lockers vote yes → 100% cast, quorum passes
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        _warpPastVote();
        controller.carpetBomb(); // bob's ~40e18 fees still pending through the flat window
        _warpPastFlatWindow();

        uint256 fBefore = mixETH.balanceOf(address(audFactory));
        controller.finalizeCarpet();
        assertEq(mixETH.balanceOf(address(audHook)), 0, "hook drained");
        assertGt(mixETH.balanceOf(address(audFactory)) - fBefore, 39e18, "bob's fees in carry");

        // bob's strict claim path is bricked; principal still exits
        vm.prank(bob);
        vm.expectRevert(AuditorHook.InsufficientFees.selector);
        controller.claimFees();

        vm.expectEmit(true, true, false, false, address(controller));
        emit RoundController.FeesForfeited(bob, 0);
        vm.prank(bob);
        controller.unlock();
        assertEq(psp.balanceOf(bob), bobShare, "principal released");
    }

    // ─────────────────────────────────────────────────────────────
    // INFO: relock() has no upper bound — works long after expiry
    // ─────────────────────────────────────────────────────────────
    function test_relock_callable_long_after_expiry() public {
        _deposit(alice, 100e18);
        _deposit(bob, 100e18);
        _launch();
        _claim(alice);
        _claim(bob);

        vm.warp(block.timestamp + 84 days); // inside the last-7d window
        vm.prank(bob);
        controller.relock(); // documented behavior

        vm.warp(block.timestamp + 11 days); // 5 days past expiry, window closed
        vm.prank(alice);
        controller.relock(); // still succeeds — natspec says window-only
        (,,, uint256 ut) = controller.locks(alice);
        assertEq(ut, block.timestamp + 90 days, "lock silently extended 90d");
    }

    // ─────────────────────────────────────────────────────────────
    // Flat-window exits: unlock bypasses expiry; Z-1 blocks new locks
    // ─────────────────────────────────────────────────────────────
    function test_unlock_flat_bypass_and_lock_blocked() public {
        _deposit(alice, 100e18);
        _launch();
        _claim(alice);
        uint256 g = controller.genesisPSPSnapshot();

        _bomb(alice); // flat: locks open immediately

        vm.prank(alice);
        controller.unlock(); // NOT 90 days old yet
        assertEq(psp.balanceOf(alice), g, "flat exit delivered principal");

        vm.startPrank(alice);
        psp.approve(address(controller), g);
        vm.expectRevert(RoundController.RoundDestroyed.selector);
        controller.lock(g);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────
    // finalizeCarpet atomicity: factory spawn failure reverts everything
    // ─────────────────────────────────────────────────────────────
    function test_finalize_atomic_on_factory_spawn_failure() public {
        FailFactory ff = new FailFactory();
        PSPToken psp2 = new PSPToken("T", "T", address(ff));
        RoundController c2 =
            new RoundController(psp2, IERC20(address(mixETH)), curve, address(ff));
        AuditorHook h2 = new AuditorHook(IERC20(address(mixETH)));
        vm.startPrank(address(ff));
        psp2.setController(address(c2));
        c2.setHook(CurveHook(payable(address(h2))));
        vm.stopPrank();

        // launch + governance quorum via alice's genesis lock
        vm.startPrank(alice);
        mixETH.approve(address(c2), 60e18);
        c2.predeposit(60e18);
        vm.stopPrank();
        vm.prank(address(ff));
        c2.launchPooledBuy();
        vm.prank(alice);
        c2.claimPredepositPSP();

        skip(1); // lockTime strictly before proposeTime
        vm.prank(alice);
        c2.proposeCarpetBomb();
        vm.prank(alice);
        c2.voteCarpetBomb(true);
        vm.warp(block.timestamp + c2.VOTE_DURATION() + 1);
        c2.carpetBomb();
        assertGt(c2.flatTime(), 0, "flat window open");

        _warpPastFlatWindow(c2);

        // factory spawn reverts -> finalize is atomic: the typed
        // FactorySpawnFailed() wraps the failure, nothing half-applied
        vm.expectRevert(RoundController.FactorySpawnFailed.selector);
        c2.finalizeCarpet();

        // still flat, hook untouched: retry possible once factory is fixed
        assertGt(c2.flatTime(), 0, "still flat after failed finalize");
        assertEq(uint256(h2.mode()), 2, "hook still Flat");
        vm.expectRevert(RoundController.FactorySpawnFailed.selector);
        c2.finalizeCarpet();
    }
}
