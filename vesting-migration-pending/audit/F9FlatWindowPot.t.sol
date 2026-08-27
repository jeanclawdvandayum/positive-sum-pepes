// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {AuditLifecycleTest} from "../../vesting-migration-pending/audit/AuditLifecycle.t.sol";

/// @title F-9 regression: zero-fee flat window.
/// @notice Original finding (wave-1 F-9, re-found by auditorA wave-2): pot
///         PSP credited during the 3-day flat window was never redeemed by
///         finalizeCarpet — backing drained to the factory as generic carry
///         instead of the ring-fenced pot, and the residual pot PSP tokens
///         died at the controller.
///         FIXED 2026-08-19 by killing the swap fee at the source: Flat-mode
///         trades accrue nothing (no referral leg, no staker leg) and exits
///         pay exactly pro-rata avg backing, floor-only.
///         (Side pot fully removed 2026-08-19 — this regression now guards
///         the flat window's zero-fee property for the staker/referral fee
///         legs that replaced it.)
contract F9FlatWindowPotTest is AuditLifecycleTest {
    function test_F9_FlatWindowIsZeroFee() public {
        _launchAndStake();
        _bomb();

        // carol trades during the flat window: buy then sell
        uint256 bought = _buy(carol, 10e18);
        // capture PRE-sell state: the sell prices off reserve/supply as of
        // this moment (floor((in * R) / S) — mirrors _handleFlatSell)
        uint256 rPre = hook.reserveMixETH();
        uint256 sPre = hook.totalSupplyPSP();
        vm.startPrank(carol);
        psp.approve(address(zapOut), type(uint256).max);
        uint256 back = zapOut.sellToMix(_key(), bought, 0, 0);
        vm.stopPrank();
        assertGt(back, 0, "flat sell paid");

        // FIX: the exit paid EXACTLY pro-rata avg backing (no 4.95% toll)
        uint256 expectedOut = (bought * rPre) / sPre;
        assertEq(back, expectedOut, "F9 fixed: flat exit is exactly avg backing");

        // no orphaned staker/referral fees either: flat trades add NOTHING to
        // the hook's available fees (live-phase fees legitimately sit there
        // until stakers claim — the invariant is UNCHANGED, not zero).
        // sendFees invariant: available = hookBalance - reserveMixETH.
        uint256 hookAvail0 = mixETH.balanceOf(address(hook)) - hook.reserveMixETH();
        assertGt(hookAvail0, 0, "F9 setup: live-phase fees exist pre-flat");
        _buy(carol, 1e18); // more flat volume AFTER the measured sell
        uint256 hookAvail1 = mixETH.balanceOf(address(hook)) - hook.reserveMixETH();
        assertEq(hookAvail1, hookAvail0, "F9 fixed: flat trades accrue no fees");

        // finalize the round
        skip(3 days + 1);
        controller.finalizeCarpet();

        // no residual PSP stranded at the dying controller beyond locker
        // principal (now held by the staker)
        uint256 resid = psp.balanceOf(address(controller));
        uint256 locked = stakerV.totalLocked();
        assertEq(resid, 0, "F9 fixed: controller holds no PSP (staker owns locks)");
        assertGt(locked, 0, "staker still holds locker principal");
    }
}
