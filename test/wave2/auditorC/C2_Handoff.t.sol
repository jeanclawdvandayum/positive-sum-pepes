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

        _bombRound1();

        // v5.1: bomb flattens only — nothing redeemed, nothing ring-fenced
        assertEq(mixETH.balanceOf(address(factory)), 0, "factory holds nothing post-bomb");

        _warpPastFlatWindow();

        // What the dying hook custodies at finalize time = the carry
        uint256 carry = mixETH.balanceOf(address(hook1));
        assertGt(carry, 0, "unredeemed backing remains (backing of kept PSP + dust)");

        controller1.finalizeCarpet();

        // ── conservation: everything left the factory into round 2 ──
        assertEq(factory.currentRoundId(), 2);
        assertEq(mixETH.balanceOf(address(factory)), 0, "no mixETH stranded at factory");

        PSPFactory.Round memory r2 = factory.getRound(2);
        assertEq(r2.controller.totalPredepositMixETH(), carry, "carry - round-2 predeposit, exact");
        (uint256 factoryDeposit,) = r2.controller.predeposits(address(factory));
        assertEq(factoryDeposit, carry, "earmarked to factory");

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

    /// No-buy branch: no swap flow at all — spawn forwards the whole
    /// reserve as carry (v5.1: there is no pot branch anymore).
    function test_C2_NoBuyBranch() public {
        _launchRound1();
        _bombRound1();
        _warpPastFlatWindow();
        uint256 carry = mixETH.balanceOf(address(hook1));
        controller1.finalizeCarpet();

        PSPFactory.Round memory r2 = factory.getRound(2);
        assertEq(r2.controller.totalPredepositMixETH(), carry);
        assertEq(mixETH.balanceOf(address(factory)), 0);
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
    /// the generic carry into the next round (v5.1: no pot earmark path
    /// exists anymore — the credit surface was deleted).
    function test_C2_DonationsRideTheCarry() public {
        _launchRound1();
        _bombRound1();
        uint256 donated = 7e18;
        mixETH.transfer(address(factory), donated);

        _warpPastFlatWindow();
        uint256 reserve = mixETH.balanceOf(address(hook1));
        controller1.finalizeCarpet();

        // donated + reserve all became round-2 predeposit carry
        PSPFactory.Round memory r2 = factory.getRound(2);
        assertEq(r2.controller.totalPredepositMixETH(), reserve + donated, "donation joined the carry");
        assertEq(mixETH.balanceOf(address(factory)), 0);
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
