// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CBase} from "./CBase.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {PSPFactory} from "../../../src/PSPFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title C-2 battery - value handoff across the finalize-spawn boundary.
/// Attacks: lost or duplicated carry/pot, phantom pot credits, double spawn,
/// zombie rounds. Expectation: the handoff is exact, guarded, and single-shot.
contract C2_Handoff is CBase {
    function test_C2_CarryForwardedExactly() public {
        _launchRound1();

        // Real buy flow through the mock PM (fees accrue to stakers now,
        // not to any pot — v5.1 killed it)
        vm.startPrank(alice);
        mixETH.approve(address(swapper), 10e18);
        swapper.buy(_key(), 10e18, alice);
        vm.stopPrank();

        _detonateRound1();

        // v5.1+: detonate flattens + births in one tx — nothing redeemed,
        // nothing ring-fenced, nothing left at the factory
        assertEq(mixETH.balanceOf(address(factory)), 0, "factory holds nothing post-detonate");

        // What the dying hook custodies — under indefinite redemption
        // (2026-08-30) this STAYS PUT: the backing of unredeemed PSP,
        // payable via hook.redeemBacking forever
        uint256 backing = mixETH.balanceOf(address(hook1));
        assertGt(backing, 0, "unredeemed backing remains (backing of kept PSP + dust)");

        // ── the new model: death does not endow. The dead hook keeps every
        //    wei; round 2's boot is its own predeposit (factory held nothing
        //    here). Abandoned value waits for its owner, indefinitely. ──
        assertEq(factory.currentRoundId(), 2);
        assertEq(mixETH.balanceOf(address(factory)), 0, "no mixETH stranded at factory");
        assertEq(mixETH.balanceOf(address(hook1)), backing, "dead hook kept the backing - redemption is indefinite");

        PSPFactory.Round memory r2 = factory.getRound(2);
        assertEq(r2.controller.totalPredepositMixETH(), 0, "no carry - round 2 starts from its own raise");
        (uint256 factoryDeposit,) = r2.controller.predeposits(address(factory));
        assertEq(factoryDeposit, 0, "nothing earmarked to factory");

        // v5.1: the referral graph resets — round 2 runs a FRESH registry
        assertTrue(
            factory.referralRegistryOf(2) != address(0)
                && factory.referralRegistryOf(2) != factory.referralRegistryOf(1),
            "per-round registry reborn"
        );
        assertTrue(factory.getRound(1).destroyed, "round 1 marked destroyed");
        assertFalse(r2.destroyed, "round 2 live");
        assertFalse(r2.controller.predepositClosed(), "round 2 open for public predeposit");
        assertGt(address(r2.token).code.length, 0);

        // ── no duplication: every replay path is guarded ──
        vm.prank(rando);
        vm.expectRevert(PSPFactory.NotLatestRound.selector);
        factory.spawnNextRound(1);

        vm.prank(rando);
        vm.expectRevert(PSPFactory.RoundNotDestroyed.selector);
        factory.spawnNextRound(2);

        vm.prank(rando);
        vm.expectRevert(PSPFactory.RoundNotFound.selector);
        factory.spawnNextRound(99);
    }

    /// No-buy branch: no swap flow at all — the reserve simply waits.
    function test_C2_NoBuyBranch() public {
        _launchRound1();
        uint256 backing = mixETH.balanceOf(address(hook1));
        _detonateRound1();

        PSPFactory.Round memory r2 = factory.getRound(2);
        assertEq(r2.controller.totalPredepositMixETH(), 0, "no carry");
        assertEq(mixETH.balanceOf(address(factory)), 0);
        assertEq(mixETH.balanceOf(address(hook1)), backing, "backing waits in the dead hook");
    }

    /// Guards on the destroy flag: only a round's own controller flips it.
    /// (v5.1: the side-pot credit path was deleted with the pot.)
    function test_C2_DestroyFlagGuards() public {
        // markDestroyed from a non-controller
        vm.prank(rando);
        vm.expectRevert(PSPFactory.NotRoundController.selector);
        factory.markDestroyed(1);

        // markDestroyed from the round's own controller works and is
        // idempotent (pure flag flip, no side effects)
        vm.prank(address(controller1));
        factory.markDestroyed(1);
        vm.prank(address(controller1));
        factory.markDestroyed(1);
        assertTrue(factory.getRound(1).destroyed);
    }

    /// Donation accounting: mixETH airdropped straight to the factory rides
    /// the generic carry into the next round. Under indefinite redemption
    /// (2026-08-30) this is the ONLY carry: the dead hook's reserve stays
    /// with the dead hook, waiting for its holders.
    function test_C2_DonationsRideTheCarry() public {
        _launchRound1();
        uint256 donated = 7e18;
        mixETH.transfer(address(factory), donated);
        uint256 backing = mixETH.balanceOf(address(hook1));
        _detonateRound1(); // births round 2 in-tx — the donation rides along

        // only the donation became round-2 predeposit carry
        PSPFactory.Round memory r2 = factory.getRound(2);
        assertEq(r2.controller.totalPredepositMixETH(), donated, "donation joined the carry");
        assertEq(mixETH.balanceOf(address(factory)), 0);
        assertEq(mixETH.balanceOf(address(hook1)), backing, "hook reserve untouched by the donation");
    }

    function _key() internal view returns (PoolKey memory) {
        address c0 = address(mixETH);
        address c1 = address(psp1);
        if (c0 > c1) (c0, c1) = (c1, c0);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook1))
        });
    }
}
