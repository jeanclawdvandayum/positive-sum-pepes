// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

/// @title AuditA — fresh-eyes curve math battery
/// Focus: over-mint on buy, over-pay on sell, round-trip solvency, boundary
/// continuity, randomized valid multi-zone configs, and the flat-mode
/// double-division asymmetry (_handleFlatBuy floors flatPrice; _handleFlatSell
/// divides directly). All math mirrors EXACT formulas from CurveHook.
contract AuditCurveMathTest is Test {
    using CurveMath for CurveMath.CurveConfig;

    // ─────────────────────────────────────────────────────────────
    // A1: buy output must never over-mint (integral <= input) on
    //     randomized VALID multi-zone configs, fresh random seeds.
    // ─────────────────────────────────────────────────────────────
    function test_A1_NoOverMint_RandomMultiZone(
        uint256 seed,
        uint256 supply,
        uint256 input
    ) public pure {
        CurveMath.CurveConfig memory cc = _randomValidConfig(seed);
        supply = bound(supply, 0, 1e28);
        input = bound(input, 1e12, 100_000e18);

        uint256 out = CurveMath.computeBuyOutput(input, supply, cc);
        if (out == 0) return;
        uint256 spent = CurveMath.curveIntegral(supply, supply + out, cc);
        assertLe(spent, input, "A1: over-mint (integral > input)");
    }

    // ─────────────────────────────────────────────────────────────
    // A2: buy-then-sell-everything round trip must lose money
    // ─────────────────────────────────────────────────────────────
    function test_A2_RoundTripLossy_RandomMultiZone(
        uint256 seed,
        uint256 supply,
        uint256 input
    ) public pure {
        CurveMath.CurveConfig memory cc = _randomValidConfig(seed);
        supply = bound(supply, 0, 1e28);
        input = bound(input, 1e12, 100_000e18);

        uint256 out = CurveMath.computeBuyOutput(input, supply, cc);
        if (out < 2) return;
        uint256 back = CurveMath.computeSellOutput(out, supply + out, cc);
        assertLt(back, input, "A2: round trip profitable (pre-fee!)");
    }

    // ─────────────────────────────────────────────────────────────
    // A3: sell output must not exceed the true integral
    // ─────────────────────────────────────────────────────────────
    function test_A3_SellNeverOverPays(
        uint256 seed,
        uint256 supply,
        uint256 sellAmt
    ) public pure {
        CurveMath.CurveConfig memory cc = _randomValidConfig(seed);
        supply = bound(supply, 2, 1e28); // >=2: sellAmt bound needs supply-1 >= 1
        sellAmt = bound(sellAmt, 1, supply - 1);

        uint256 out = CurveMath.computeSellOutput(sellAmt, supply, cc);
        uint256 spent = CurveMath.curveIntegral(supply - sellAmt, supply, cc);
        assertEq(out, spent, "A3: sell output != integral");
    }

    // ─────────────────────────────────────────────────────────────
    // A4: marginalPrice continuity across zone boundaries
    // ─────────────────────────────────────────────────────────────
    function test_A4_PriceContinuousAtBoundaries(uint256 seed) public pure {
        CurveMath.CurveConfig memory cc = _randomValidConfig(seed);
        for (uint256 i = 0; i < cc.zones.length; i++) {
            uint256 b = cc.zones[i].endSupply;
            if (b == type(uint256).max) break;
            uint256 lo = CurveMath.marginalPrice(b > 1 ? b - 1 : 0, cc);
            uint256 at = CurveMath.marginalPrice(b, cc);
            uint256 hi = CurveMath.marginalPrice(b + 1, cc);
            // continuity: price at boundary must sit between neighbors
            assertTrue(lo <= at && at <= hi, "A4: price discontinuous at boundary");
        }
    }

    // ─────────────────────────────────────────────────────────────
    // A5: FLAT MODE — the double-division asymmetry.
    //     _handleFlatBuy:  flatPrice = (R*1e18)/S (floored);
    //                      pspOut    = (buyMix*1e18)/flatPrice
    //     _handleFlatSell: out = (psp*R)/S directly.
    //     Floored flatPrice can OVER-mint relative to fair pro-rata by up to
    //     F_exact/F. Fuzz buy->sell round trips in flat mode for profit.
    //     (Pre-fee: buy pays 5%, sell pays 5%, pot cut 0.25% each way.)
    // ─────────────────────────────────────────────────────────────
    function test_A5_FlatRoundTripNoProfit(
        uint256 R,
        uint256 S,
        uint256 i
    ) public pure {
        // supply within MAX_SUPPLY, reserve plausible
        S = bound(S, 1e6, 1e28);
        R = bound(R, 1, 10_000_000e18);
        i = bound(i, 1e12, 1000e18); // MIN_SWAP_INPUT floor

        uint256 flatPrice = (R * 1e18) / S;
        vm.assume(flatPrice > 0); // hook reverts otherwise (div by zero)

        // ── buy leg (exact mirror of _handleFlatBuy, F-9: zero fee) ──
        // 2026-08-19: the hook mints by DIRECT pro-rata (i*S/R), not via a
        // floored flatPrice — the two-step floor was A6's over-mint source
        uint256 buyMix = i;
        uint256 pspOut = (buyMix * S) / R;
        if (pspOut == 0) return; // hook reverts ZeroOutput

        uint256 R1 = R + buyMix;
        uint256 S1 = S + pspOut;

        // ── sell leg (exact mirror of _handleFlatSell, F-9: zero fee) ──
        uint256 totalOut = (pspOut * R1) / S1;
        uint256 toUser = totalOut;
        if (toUser == 0) return; // hook reverts ZeroOutput

        assertLe(toUser, i, "A5: FLAT round trip profitable");
    }

    // ─────────────────────────────────────────────────────────────
    // A6: FLAT MODE ratio drift. FINDING (extreme range): _handleFlatBuy
    //     mints at FLOORED flatPrice, so each buy over-mints vs true
    //     pro-rata by up to F_exact/F = (F+1)/F. At production-like
    //     F >= 1e14 (avg backing >= 0.0001 mix/PSP) the drift is <= 1e-14
    //     relative and backing is preserved to within dust. This test
    //     enforces the production-range bound; the raw property breaks
    //     only when F is a few wei (absurd configs), documented in the
    //     audit report as LOW.
    // ─────────────────────────────────────────────────────────────
    function test_A6_FlatBuyNeverDilutesBacking(
        uint256 R,
        uint256 S,
        uint256 i
    ) public pure {
        S = bound(S, 1e6, 1e28);
        R = bound(R, 1, 10_000_000e18);
        i = bound(i, 1e12, 1000e18);

        // L-3 fixed model: direct pro-rata (x * S) / R, mirroring the contract
        // (F-9: zero fee in Flat — no fee/pot slices in the model)
        uint256 buyMix = i;
        uint256 pspOut = (buyMix * S) / R;
        if (pspOut == 0) return;

        uint256 R1 = R + buyMix;
        uint256 S1 = S + pspOut;

        // STRICT: floored mints mean R*(S1) <= R1*S always — no slack needed
        assertGe(R1 * S, R * S1, "A6: flat buy diluted backing");
    }

    // ─────────────────────────────────────────────────────────────
    // A7: FLAT MODE — same for sells: backing must not dilute, and
    //     repeated sells must each get the SAME effective rate.
    // ─────────────────────────────────────────────────────────────
    function test_A7_FlatSellNeverDilutesBacking(
        uint256 R,
        uint256 S,
        uint256 psp
    ) public pure {
        S = bound(S, 2e12, 1e28);
        R = bound(R, 1, 10_000_000e18);
        psp = bound(psp, 1e12, S / 2); // sells must be < supply

        // (F-9: zero fee in Flat — out = floor(psp * R) / S, full burn)
        uint256 totalOut = (psp * R) / S;
        if (totalOut == 0) return;

        uint256 R1 = R - totalOut;
        uint256 S1 = S - psp;

        assertGe(R1 * S, R * S1, "A7: flat sell diluted backing");
    }

    // ─────────────────────────────────────────────────────────────
    // A8: genesis buy edge — computeBuyOutput at supply=0 for the boot
    //     amounts used in production (0.001e18 P0 curve)
    // ─────────────────────────────────────────────────────────────
    function test_A8_GenesisBuyDeterministic() public pure {
        CurveMath.CurveConfig memory cc =
            CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);
        uint256 out1 = CurveMath.computeBuyOutput(60e18, 0, cc);
        uint256 out2 = CurveMath.computeBuyOutput(60e18, 0, cc);
        assertEq(out1, out2, "A8: genesis buy not deterministic");
        // exact regression pin (60e18 mix at production single-curve config):
        assertEq(out1, 59_985_722_351_052_614_577_360, "A8: genesis output drifted");
    }

    // ═══════════════════════════════════════════════════════════
    //  helpers
    // ═══════════════════════════════════════════════════════════

    /// @dev Randomized VALID config: alternating exp/log zones with sane
    ///      boundaries/rates that always pass CurveMath.validate().
    ///      multiCurve boundaries are zone STARTS: [0, b1, ..., b_{n-1}],
    ///      last zone runs b_{n-1} → type(uint256).max (must be flat exp).
    function _randomValidConfig(uint256 seed) internal pure returns (CurveMath.CurveConfig memory) {
        uint256 n = 2 + (seed % 5); // 2..6 zones
        uint256[] memory boundaries = new uint256[](n);
        uint256[] memory rates = new uint256[](n);
        bool[] memory exps = new bool[](n);

        uint256 r = seed;
        uint256 cursor;
        for (uint256 i = 0; i < n; i++) {
            r = _next(r);
            if (i == 0) {
                boundaries[i] = 0; // required
                exps[i] = true; // required (log-first reverts in validate)
                uint256 cap = 7e36 / 1e24; // width of first zone ~1e24
                rates[i] = 1 + (r % (cap > 1e17 ? 1e17 : cap));
            } else if (i == n - 1) {
                // unbounded tail: only exp k=0 is valid. If no middle zones
                // advanced the cursor (n == 2), give the first zone real width.
                boundaries[i] = cursor == 0 ? 1e24 : cursor;
                exps[i] = true;
                rates[i] = 0;
            } else {
                // advance cursor by a sane width (1e21..1e24 tokens)
                uint256 width = 1e21 + (r % 1e24);
                cursor = cursor + width;
                if (cursor > 4e27) cursor = 4e27;
                boundaries[i] = cursor;
                // NOTE: do NOT read boundaries[i+1] here — it is still 0
                // (unassigned); `boundaries[i+1] - cursor` underflowed and
                // faked a CurveMath panic for every n>=4 config (M-2 deflation).
                exps[i] = ((r >> 128) & 1) == 1;
                if (exps[i]) {
                    // k <= min(100e18, MAX_EXP_K_WIDTH/width); assume the
                    // next zone spans at least 1e24 (conservative cap basis)
                    uint256 cap = 7e36 / 1e24; // 7e12
                    rates[i] = 1 + (r % (cap > 1e12 ? 1e12 : cap));
                } else {
                    // log: rate <= 1e18; keep away from 1e18 to avoid (1-k)→0 degeneracy
                    rates[i] = 1 + (r % 0.9e18);
                }
            }
        }
        // enforce monotonic boundaries for the tail-start (cursor may have clamped)
        if (n >= 3 && boundaries[n - 1] <= boundaries[n - 2]) {
            boundaries[n - 1] = boundaries[n - 2] + 1e24 > 4e27
                ? 4e27
                : boundaries[n - 2] + 1e24;
        }
        CurveMath.CurveConfig memory cc = CurveMath.multiCurve(
            0.0001e18 + (r % 1e18), boundaries, rates, exps
        );
        CurveMath.validate(cc);
        return cc;
    }

    function _next(uint256 x) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(x)));
    }
}
