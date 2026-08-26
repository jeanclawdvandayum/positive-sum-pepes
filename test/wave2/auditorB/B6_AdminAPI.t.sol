// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BBase, BRouter, HookProbe} from "./BBase.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {PSPToken} from "../../../src/PSPToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @title B6 — controller-facing hook APIs: trust assumptions made concrete.
///        The controller is a trusted multisig actor, but the hook's own API
///        surface should be safe-by-construction where cheap. These tests pin
///        exactly which safety properties rest on the caller's behavior.
contract B6_AdminAPI is BBase {
    // (2026-08-19) _flatWithPotAccrued + F-B6a (redeemPotBacking double-draw)
    // removed with the side pot — the function no longer exists.

    // ── F-B6b: initializeCurve is one-shot — re-arming accounting after launch
    //    is impossible (verified: the earlier hypothesis of a mid-flight reset
    //    was wrong; poolInitialized locks it).
    function test_B6b_initializeCurveLockedAfterLaunch() public {
        _launch(100e18);

        vm.prank(address(controller));
        vm.expectRevert(CurveHook.InvalidMode.selector);
        hook.initializeCurve(1, 1);
    }

    // ── F-B6c: drainAll mid-Active leaves curve sells to underflow-panic
    //    (not a graceful revert). Current controller only drains after
    //    setMode(Destroyed) atomically — pins the sequencing dependency.
    function test_B6c_drainMidActiveThenSellPanics() public {
        _launch(100e18);
        uint256 out = _buy(alice, 10e18);

        vm.prank(address(controller));
        hook.drainAll(address(controller)); // mode still Active
        assertEq(hook.reserveMixETH(), 0);

        // through the PM the panic arrives wrapped by IHooks.WrappedError;
        // the hook PM-gates beforeSwap (NotPoolManager on direct calls), so
        // pin the exact panic via revert-data containment
        vm.startPrank(alice);
        psp.approve(address(router), out);
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = BRouter.Call({isBuy: false, amount: out, settleMode: 0, takeMode: 0});
        (bool ok, bytes memory data) =
            address(router).call(abi.encodeCall(BRouter.execute, (key, calls, alice)));
        vm.stopPrank();
        assertFalse(ok, "post-drain sell should revert");
        assertTrue(
            _contains(data, abi.encodeWithSignature("Panic(uint256)", 0x11)),
            "expected reserve-underflow panic"
        );
    }

    // ── F-B6d: drainAll mid-Flat leaves flat buys to div-by-zero panic ──
    function test_B6d_drainMidFlatThenBuyPanics() public {
        _launch(100e18);
        _bobBuysAndLocks(20e18);
        _bomb();

        vm.prank(address(controller));
        hook.drainAll(address(controller)); // mode still Flat

        vm.startPrank(alice);
        mixETH.approve(address(router), 1e18);
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = BRouter.Call({isBuy: true, amount: 1e18, settleMode: 0, takeMode: 0});
        (bool ok, bytes memory data) =
            address(router).call(abi.encodeCall(BRouter.execute, (key, calls, alice)));
        vm.stopPrank();
        assertFalse(ok, "post-drain flat buy should revert");
        assertTrue(
            _contains(data, abi.encodeWithSignature("Panic(uint256)", 0x12)),
            "expected division-by-zero panic"
        );
    }

    // ── mode transitions are strictly enforced ──
    function test_B6e_modeTransitionsEnforced() public {
        _launch(100e18);
        vm.prank(address(controller));
        vm.expectRevert(CurveHook.InvalidMode.selector);
        hook.setMode(CurveHook.Mode.Destroyed); // Active → Destroyed not allowed
        vm.prank(address(controller));
        hook.setMode(CurveHook.Mode.Flat); // Active → Flat OK

        vm.prank(address(controller));
        vm.expectRevert(CurveHook.InvalidMode.selector);
        hook.setMode(CurveHook.Mode.Active); // Flat → Active not allowed
        vm.prank(address(controller));
        hook.setMode(CurveHook.Mode.Destroyed); // Flat → Destroyed OK

        vm.prank(address(controller));
        vm.expectRevert(CurveHook.InvalidMode.selector);
        hook.setMode(CurveHook.Mode.Destroyed); // Destroyed frozen
    }

    // ── non-controller cannot touch admin APIs ──
    function test_B6f_adminApisGated() public {
        _launch(100e18);
        vm.startPrank(carol);
        vm.expectRevert(CurveHook.NotController.selector);
        hook.sendFees(carol, 1);
        vm.expectRevert(CurveHook.NotController.selector);
        hook.drainAll(carol);
        vm.expectRevert(CurveHook.NotController.selector);
        hook.initializeCurve(1, 1);
        vm.stopPrank();
    }
}
