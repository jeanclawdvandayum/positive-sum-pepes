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

    // ── F-B6c (updated 2026-08-30): the admin drain surface is GONE —
    //    drainAll was removed entirely (indefinite-redemption redesign):
    //    the dead hook custodies backing forever and pays it out only via
    //    the permissionless redeemBacking. The mid-Active-drain panic class
    //    this test originally pinned is now structurally unreachable.
    function test_B6c_drainSurfaceRemoved() public {
        _launch(100e18);
        _buy(alice, 10e18);
        assertGt(hook.reserveMixETH(), 0, "reserve live");

        // the retired selector must not exist — controller or not
        vm.prank(address(controller));
        (bool ok,) = address(hook).call(abi.encodeWithSignature("drainAll(address)", address(controller)));
        assertFalse(ok, "drainAll is gone for good");
    }

    // ── F-B6d: flat buys are DISABLED outright (scoopy 2026-08-29) ──
    // Flat mode is a one-way exit: _handleBuy reverts BuyingDisabled before
    // any math, so the old post-drain div-by-zero panic class is unreachable.
    function test_B6d_flatBuyDisabled() public {
        _launch(100e18);
        _bobBuysAndLocks(20e18);
        _bomb(); // → Mode.Flat

        vm.startPrank(alice);
        mixETH.approve(address(router), 1e18);
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = BRouter.Call({isBuy: true, amount: 1e18, settleMode: 0, takeMode: 0});
        (bool ok, bytes memory data) =
            address(router).call(abi.encodeCall(BRouter.execute, (key, calls, alice)));
        vm.stopPrank();
        assertFalse(ok, "flat buy must revert");
        assertTrue(
            _contains(data, abi.encodeWithSelector(CurveHook.BuyingDisabled.selector)),
            "expected BuyingDisabled"
        );

        // the quote view mirrors execution (B7b principle)
        vm.expectRevert(CurveHook.BuyingDisabled.selector);
        hook.getBuyOutput(1e18);

        // sanity: the flat SELL path stays open (exit window)
        uint256 bag = psp.balanceOf(alice);
        if (bag > 0) {
            psp.approve(address(router), bag / 10);
            BRouter.Call[] memory sell = new BRouter.Call[](1);
            sell[0] = BRouter.Call({isBuy: false, amount: bag / 10, settleMode: 0, takeMode: 0});
            uint256[] memory outs = router.execute(key, sell, alice);
            assertGt(outs[0], 0, "flat sell still pays pro-rata");
        }
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
        hook.initializeCurve(1, 1);
        vm.stopPrank();
    }
}
