// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BBase, BRouter} from "./BBase.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @title B2 — flat-mode invariants, curve→flat switch, MAX_SUPPLY overshoot.
contract B2_FlatInvariants is BBase {
    function _flatState() internal {
        _launch(100e18);
        _bobBuysAndLocks(20e18);
        _bomb();
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Flat), "not flat");
    }

    // ── flat sell pays EXACTLY pro-rata (F-9 fix: zero-fee flat window) ──
    function test_B2a_flatSellExactProRata() public {
        _flatState();
        uint256 out = _buy(carol, 10e18); // flat buy to give carol PSP
        uint256 R = hook.reserveMixETH();
        uint256 S = hook.totalSupplyPSP();

        uint256 pspIn = out / 2;
        uint256 expTotal = (pspIn * R) / S; // floor
        uint256 expUser = expTotal; // no toll — floor-only pro-rata
        uint256 mixBack = _sell(carol, pspIn);
        assertEq(mixBack, expUser, "flat sell != exact floor pro-rata (zero fee)");
    }

    // ── core flat invariant: after every op, R1*S0 >= R0*S1 (no backing dilution) ──
    function test_B2b_flatProRataInvariant_fuzz(uint64 seed) public {
        _flatState();
        _buy(carol, 10e18); // carol holds PSP

        for (uint8 i = 0; i < 6; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 R0 = hook.reserveMixETH();
            uint256 S0 = hook.totalSupplyPSP();

            if ((r & 1) == 0) {
                _buy(carol, bound(r, 1e12, 50e18));
            } else {
                uint256 bal = psp.balanceOf(carol);
                _sell(carol, bound(r, 1e12, bal / 2 + 1e12));
            }

            uint256 R1 = hook.reserveMixETH();
            uint256 S1 = hook.totalSupplyPSP();
            assertGe(R1 * S0, R0 * S1, "FLAT INVARIANT BROKEN: R1*S0 < R0*S1");
            assertGe(mixETH.balanceOf(address(hook)), hook.reserveMixETH(), "balance < reserve");
        }
    }

    // ── curve→flat switch: price discontinuity direction + continuity within flat ──
    function test_B2c_modeSwitchContinuity() public {
        _launch(100e18);
        _bobBuysAndLocks(20e18);

        uint256 marginalBefore = hook.getMarginalPrice(); // P(S) in curve mode
        uint256 out = _buy(carol, 1e18); // carol holds some PSP pre-flatten

        // what a curve-mode sell of carol's tokens WOULD pay (view-only)
        uint256 curveSellQuote = hook.getSellOutput(out);

        _bomb();
        uint256 flatPrice = hook.getFlatPrice();

        assertApproxEqRel(flatPrice, marginalBefore, 2e16, "flat price vs marginal discontinuity > 2%");
        console2.log("marginal P(S) before flatten:", marginalBefore);
        console2.log("flat R/S after flatten:     ", flatPrice);

        // post-flatten sell pays pro-rata; with the near-flat production shape the
        // haircut slack (≤ ~1bps of volume) sits in the same band as the curve's
        // own rise, so assert value-continuity within 2% instead of strict order
        uint256 R = hook.reserveMixETH();
        uint256 S = hook.totalSupplyPSP();
        uint256 flatTotal = (out * R) / S;
        // solvency: flat price can never be below the average curve price actually paid in
        uint256 avgCurve = CurveMath.curveIntegral(0, S, _cfg()) / S;
        assertGe(R / S, avgCurve, "flat price below average paid-in (solvency)");
        // continuity: flat sell value within 2% of the curve sell quote (no cliff)
        assertApproxEqRel(flatTotal, curveSellQuote, 2e16, "flat/curve sell value discontinuity > 2%");
        console2.log("curve sell quote (wei mix):", curveSellQuote);
        console2.log("flat sell payout (wei mix):", flatTotal);

        // within flat mode itself, price is continuous: consecutive small sells
        // pay the same per-token price (within rounding)
        uint256 p1 = _sell(carol, out / 3);
        uint256 p2 = _sell(carol, out / 3);
        uint256 per1 = (p1 * 1e18) / (out / 3);
        uint256 per2 = (p2 * 1e18) / (out / 3);
        // each sell shrinks S and R pro-rata → price identical within 1 wei/token scale
        assertApproxEqRel(per1, per2, 1e15, "flat price not continuous within flat mode"); // 0.1%
    }

    // ── flat round trip strictly loses (fees both ways) ──
    function test_B2d_flatRoundTripBreaksEven() public {
        _flatState();
        uint256 amt = 10e18;
        uint256 out = _buy(carol, amt);
        uint256 back = _sell(carol, out);
        // F-9 fix (zero-fee flat window): a flat round trip is EXACTLY
        // break-even — floor-only pro-rata both ways, no fee leakage in
        // either direction (double-floor dust <= a few wei at 1e18 scale).
        // Pre-fix this pinned the ~0.95^2 fee-bound round trip.
        assertLe(back, amt, "flat round trip must not create value");
        assertApproxEqAbs(back, amt, 5, "flat round trip is break-even (zero fee)");
    }

    // ── dust sell in flat mode reverts loudly (ZeroOutput), never silently burns ──
    function test_B2e_flatDustSellReverts() public {
        _flatState();
        _buy(carol, 10e18);
        // construct a sale whose total pro-rata output rounds to ~0:
        // sell exactly MIN_SWAP_INPUT PSP; total = pspIn*R/S. With R/S ~ 0.001e18
        // this is ~1e9 wei — nonzero, so instead probe the ZeroOutput guard by
        // exhausting: sell all but dust, then attempt the remainder.
        uint256 bal = psp.balanceOf(carol);
        _sell(carol, bal - 1e12); // leave exactly 1e12 (min size)
        // final 1e12 sell must either pay out or revert — never silently absorb
        uint256 R = hook.reserveMixETH();
        uint256 S = hook.totalSupplyPSP();
        uint256 total = (1e12 * R) / S;
        uint256 fee = ((total * 500) + 9999) / 10000;
        if (total <= fee) {
            vm.startPrank(carol);
            psp.approve(address(router), 1e12);
            BRouter.Call[] memory calls = new BRouter.Call[](1);
            calls[0] = BRouter.Call({isBuy: false, amount: 1e12, settleMode: 0, takeMode: 0});
            vm.expectRevert(CurveHook.ZeroOutput.selector);
            router.execute(key, calls, carol);
            vm.stopPrank();
        } else {
            _sell(carol, 1e12);
        }
    }

    // ── F-9 fix: flat trades accrue NO fees (zero-fee flat window) ──
    // ── v5.1 (2026-08-19): pot ledger removed with the pot — prove the
    //    flat window pays no staker fees either (fee accumulator frozen)
    function test_B2f_noFlatFeeAccrual() public {
        _flatState();
        uint256 out = _buy(carol, 10e18);
        uint256 accBefore = stakerV.accFeePerShareMixETH();
        uint256 pendBefore = stakerV.pendingFeesMixETH();
        _sell(carol, out / 2);
        assertEq(stakerV.accFeePerShareMixETH(), accBefore, "accumulator frozen in flat");
        assertEq(stakerV.pendingFeesMixETH(), pendBefore, "no fees accrue in flat");
    }
}

/// @title B2Whale — flat-mode buys have NO MAX_SUPPLY cap.
///        With a validate-legal but extreme-low-P0 curve, a single whale flat buy
///        pushes totalSupplyPSP far above MAX_SUPPLY (1e28). Prove no panic, no
///        dilution (pro-rata invariant still holds), and flat sells keep working.
contract B2Whale_FlatOvershoot is BBase {
    function _curve() internal view override returns (CurveMath.CurveConfig memory) {
        // P0 = 1e-6 mixETH per PSP — validate()-legal, absurdly cheap
        return CurveMath.singleCurve(1e12, 1_000_000e18, 0.0000000046e18, 0.05e18);
    }

    function test_B2g_flatBuyOvershootsMaxSupply_noPanicNoDilution() public {
        _launch(100e18);
        _bobBuysAndLocks(20e18);
        _bomb(); // Flat

        uint256 R0 = hook.reserveMixETH();
        uint256 S0 = hook.totalSupplyPSP();
        assertLt(S0, 1e28, "setup: expected S below cap pre-whale");

        // mint 1M mixETH to bob (mock vault) and whale-buy in flat mode
        vm.deal(address(this), 2_000_000 ether);
        mixETH.depositETH{value: 1_000_000e18}();
        mixETH.transfer(bob, 1_000_000e18);

        uint256 whaleOut = _buy(bob, 1_000_000e18);
        uint256 R1 = hook.reserveMixETH();
        uint256 S1 = hook.totalSupplyPSP();

        console2.log("S before whale:", S0);
        console2.log("S after whale: ", S1);
        console2.log("MAX_SUPPLY:    ", uint256(1e28));

        if (S1 > 1e28) {
            // overshoot observed — must still be sound
            assertGe(R1 * S0, R0 * S1, "pro-rata invariant broken at overshoot");
            // flat sell of whale stake works and does not panic on pspIn*R
            uint256 back = _sell(bob, whaleOut / 2);
            assertGt(back, 0);
            uint256 R2 = hook.reserveMixETH();
            uint256 S2 = hook.totalSupplyPSP();
            assertGe(R2 * S0, R0 * S2, "pro-rata invariant broken after whale sell");
        } else {
            // if the default boot sizing didn't push past cap, still assert soundness
            assertGe(R1 * S0, R0 * S1);
        }
        assertGe(mixETH.balanceOf(address(hook)), hook.reserveMixETH(), "balance < reserve");
    }
}
