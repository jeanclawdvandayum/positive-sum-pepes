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
    function test_C2_CarryAndPotForwardedExactly() public {
        _launchRound1();

        // Real buy flow through the mock PM - side pot accrues as PSP
        vm.startPrank(alice);
        mixETH.approve(address(swapper), 10e18);
        swapper.buy(_key(), 10e18, alice);
        vm.stopPrank();
        (uint256 potPSP,) = controller1.potState();
        assertGt(potPSP, 0, "buy accrued pot PSP");

        _bombRound1();

        // Bomb redeemed the pot at average backing - ring-fenced at factory
        uint256 pot = factory.sidePot();
        assertGt(pot, 0, "pot credited at factory");
        assertEq(mixETH.balanceOf(address(factory)), pot, "factory holds only the pot so far");
        assertEq(controller1.potPSPBalance(), 0, "pot PSP burned");

        _warpPastFlatWindow();

        // What the dying hook custodies at finalize time = the carry
        uint256 carry = mixETH.balanceOf(address(hook1));
        assertGt(carry, 0, "unredeemed backing remains (backing of kept PSP + dust)");

        controller1.finalizeCarpet();

        // ── conservation: everything left the factory into round 2 ──
        assertEq(factory.currentRoundId(), 2);
        assertEq(mixETH.balanceOf(address(factory)), 0, "no mixETH stranded at factory");
        assertEq(factory.sidePot(), 0, "side pot ledger emptied");

        PSPFactory.Round memory r2 = factory.getRound(2);
        assertEq(r2.controller.totalPredepositMixETH(), carry, "carry - round-2 predeposit, exact");
        (uint256 factoryDeposit,) = r2.controller.predeposits(address(factory));
        assertEq(factoryDeposit, carry, "earmarked to factory");
        assertEq(r2.controller.totalPotMixETH(), pot, "pot - round-2 pot depth, exact");
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

    /// Zero-pot branch: no buys - side pot stays empty - spawn forwards carry
    /// only, potDeposit path skipped entirely.
    function test_C2_ZeroPotBranch() public {
        _launchRound1();
        _bombRound1();
        assertEq(factory.sidePot(), 0, "no pot without swap flow");
        _warpPastFlatWindow();
        uint256 carry = mixETH.balanceOf(address(hook1));
        controller1.finalizeCarpet();

        PSPFactory.Round memory r2 = factory.getRound(2);
        assertEq(r2.controller.totalPredepositMixETH(), carry);
        assertEq(r2.controller.totalPotMixETH(), 0);
        assertEq(mixETH.balanceOf(address(factory)), 0);
    }

    /// Guards on the ledger credit: only the CURRENT round's controller, and
    /// never beyond the tokens actually held.
    function test_C2_CreditSidePotGuards() public {
        // rando is not a round controller
        vm.prank(rando);
        vm.expectRevert(PSPFactory.NotRoundController.selector);
        factory.creditSidePot(1);

        // round-1 controller is current but factory balance is zero
        vm.prank(address(controller1));
        vm.expectRevert(PSPFactory.SidePotOverdrawn.selector);
        factory.creditSidePot(1);

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

    /// Donation accounting: mixETH airdropped straight to the factory cannot
    /// be earmarked as pot by anyone but the current controller (and the only
    /// code path a real controller has is carpetBomb's exact redemption). It
    /// rides the generic carry into the next round instead.
    function test_C2_DonationsRideTheCarry() public {
        _launchRound1();
        _bombRound1();
        uint256 donated = 7e18;
        mixETH.transfer(address(factory), donated);

        // rando cannot earmark
        vm.prank(rando);
        vm.expectRevert(PSPFactory.NotRoundController.selector);
        factory.creditSidePot(donated);

        _warpPastFlatWindow();
        uint256 reserve = mixETH.balanceOf(address(hook1));
        uint256 pot = factory.sidePot();
        controller1.finalizeCarpet();

        // donated + reserve all became round-2 predeposit carry; pot separate
        PSPFactory.Round memory r2 = factory.getRound(2);
        assertEq(r2.controller.totalPredepositMixETH(), reserve + donated, "donation joined the carry");
        assertEq(r2.controller.totalPotMixETH(), pot);
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
