// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CBase} from "./wave2/auditorC/CBase.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {PSPToken} from "../src/PSPToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @title RedeemIndefinite — PSP → reserveBacking, forever (scoopy 2026-08-30)
/// @notice The redesign: finalizeCarpet no longer drains the dying hook.
///         The dead hook custodies the backing of unredeemed PSP forever,
///         payable via the permissionless, fee-free redeemBacking(). Death
///         does not endow the sequel — abandoned value waits for its owner.
contract RedeemIndefinite is CBase {

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

    /// Redeem WHILE FLAT (the clock struck zero and detonate just ran).
    function test_RedeemWhileFlat_ExactProRata() public {
        _launchRound1();
        vm.startPrank(alice);
        mixETH.approve(address(swapper), 10e18);
        swapper.buy(_key(), 10e18, alice);
        vm.stopPrank();
        _detonateRound1();

        uint256 pspBal = psp1.balanceOf(alice);
        uint256 R = hook1.reserveMixETH();
        uint256 S = hook1.totalSupplyPSP();
        assertGt(pspBal, 0);

        uint256 half = pspBal / 2;
        uint256 expected = (half * R) / S;

        vm.startPrank(alice);
        psp1.approve(address(hook1), half);
        uint256 out = hook1.redeemBacking(half);
        vm.stopPrank();

        assertEq(out, expected, "floor(inxR/S)");
        assertEq(psp1.balanceOf(alice), pspBal - half, "PSP burned");
        assertEq(hook1.reserveMixETH(), R - expected, "reserve debited");
        assertEq(hook1.totalSupplyPSP(), S - half, "supply dropped");
        // R/S invariant: the payout per PSP never changes after death
        assertEq(
            (hook1.reserveMixETH() * 1e18) / hook1.totalSupplyPSP(),
            (R * 1e18) / S,
            "backing per PSP preserved"
        );
    }

    /// The full comeback: the clock struck zero, detonate birthed round 2 in
    /// the same tx, then a YEAR passes and a holder still redeems. Flat sells
    /// shrink the pie pro-rata; redemption afterwards keeps paying the same
    /// backing/PSP. The pot ladder and the deployer rake are pulled too —
    /// every wei the dead hook custodies leaves with an owner.
    function test_RedeemOneYearLate_AfterRebirth() public {
        _launchRound1();
        vm.startPrank(alice);
        mixETH.approve(address(swapper), 10e18);
        swapper.buy(_key(), 10e18, alice);
        vm.stopPrank();
        _detonateRound1();
        assertEq(factory.currentRoundId(), 2, "round 2 exists");

        // a year goes by
        vm.warp(block.timestamp + 365 days);

        // Claims AUTO-LOCK as pepe NFTs — the comeback path for every wallet
        // is: open each pepe (flat bypass, forever) -> withdraw -> redeem
        PSPStaker staker = PSPStaker(controller1.stakerAddress());
        uint256 preTotal = mixETH.balanceOf(address(hook1)); // reserve + escrows + fee surplus
        address[2] memory wallets = [alice, bob];
        uint256 mixBefore = mixETH.balanceOf(alice) + mixETH.balanceOf(bob)
            + mixETH.balanceOf(address(this)); // deployerCutTo = this harness
        for (uint256 i; i < 2; ++i) {
            uint256 n = staker.balanceOf(wallets[i]);
            for (uint256 j; j < n; ++j) {
                uint256 id = staker.tokenOfOwnerByIndex(wallets[i], j);
                vm.prank(wallets[i]);
                staker.withdraw(id); // locks open forever post-detonation
            }
            uint256 pspBal = psp1.balanceOf(wallets[i]);
            if (pspBal > 0) {
                vm.startPrank(wallets[i]);
                psp1.approve(address(hook1), pspBal);
                hook1.redeemBacking(pspBal);
                vm.stopPrank();
            }
        }

        // CLOCK-REDESIGN §2/§3: the ladder pot (alice holds the only buy
        // ticket — a 1-seat board renormalizes to 100%) and the 1% rake
        // (unattributed buy → deployerCredit, deployerCutTo = this harness)
        // are PULL claims. Nobody but alice/this can hold them here.
        vm.prank(alice);
        hook1.claimPot();
        hook1.claimDeployerCredit();

        // conservation: backing + pot + rake + accrued fee credits — every
        // wei the dead hook custodied left with its owners (rounding dust
        // ≤ 10 wei)
        uint256 redeemed = mixETH.balanceOf(alice) + mixETH.balanceOf(bob)
            + mixETH.balanceOf(address(this)) - mixBefore;
        assertApproxEqAbs(redeemed, preTotal, 10, "every wei of custody accounted for");
        assertLe(hook1.reserveMixETH(), 1, "last holder drains the reserve (<=1 wei floor dust)");
        assertLe(hook1.totalSupplyPSP(), 1, "supply fully retired (<=1 wei dust)");
        assertApproxEqAbs(mixETH.balanceOf(address(hook1)), 0, 10, "hook swept clean");
    }

    /// The staked comeback: PSP locked in a pepe NFT at death. Locks open at
    /// flatTime and STAY open (the bypass keys on flatTime != 0, forever) —
    /// withdraw a year later, then redeem.
    function test_StakedComeback_WithdrawThenRedeem() public {
        _launchRound1();
        vm.startPrank(alice);
        mixETH.approve(address(swapper), 10e18);
        uint256 pspOut = swapper.buy(_key(), 10e18, alice);
        vm.stopPrank();

        PSPStaker staker = PSPStaker(controller1.stakerAddress());
        vm.startPrank(alice);
        psp1.approve(address(staker), pspOut);
        staker.lock(pspOut);
        uint256 pepeId = staker.primaryOf(alice); // her FIRST pepe (genesis claim)
        (uint256 principal,,,,) = staker.positions(pepeId);
        vm.stopPrank();
        assertGt(principal, 0);

        _detonateRound1();
        vm.warp(block.timestamp + 365 days);

        // the comeback: open lock → PSP → backing
        vm.startPrank(alice);
        staker.withdraw(pepeId); // flatTime != 0 — no vest wait, forever
        uint256 pspBal = psp1.balanceOf(alice);
        assertEq(pspBal, principal, "principal returned in full");
        uint256 expected = (pspBal * hook1.reserveMixETH()) / hook1.totalSupplyPSP();
        psp1.approve(address(hook1), pspBal);
        uint256 out = hook1.redeemBacking(pspBal);
        vm.stopPrank();
        assertEq(out, expected, "redeemed exact backing after the year");
    }

    /// Guards: no redemption while the round is live; dust and oversize
    /// bounce; the retired drain surface stays retired.
    function test_RedeemGuards() public {
        _launchRound1();

        vm.prank(alice);
        vm.expectRevert(CurveHook.NotActive.selector);
        hook1.redeemBacking(1);

        _detonateRound1();

        uint256 over = hook1.totalSupplyPSP() + 1; // read BEFORE arming expectRevert
        vm.prank(alice);
        vm.expectRevert(CurveHook.BuyZeroAmount.selector);
        hook1.redeemBacking(0);

        vm.prank(alice);
        vm.expectRevert(CurveHook.SellExceedsSupply.selector);
        hook1.redeemBacking(over);
    }

    /// Zone rounds keep the flat 5% — the slide is sine-only.
    function test_ZoneRoundsKeepFlatFee() public {
        _launchRound1();
        assertEq(hook1.swapFeeBps(), hook1.SWAP_FEE_BIPS(), "zone curve: flat 5%");
    }
}
