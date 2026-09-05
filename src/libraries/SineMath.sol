// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib as FPML} from "solady/src/utils/FixedPointMathLib.sol";

/// @title SineMath — INDEFINITE tilted-sine bonding curve (scoopy 2026-09-03)
/// @notice Price is a function of cumulative mixETH RAISED (reserve), not supply.
///         The curve has exactly TWO regimes — no segmented phases, no tail:
///
///   predeposit (R in [0, boot]):  p = p0 · e^(preK·R)
///   wave       (R > boot):        p = B · e^( s·(R−boot) + A·sin(π + 2π·(R−boot)/λ) )
///
///   ...and the wave NEVER ends. The trend is anchored by the target: the
///   curve passes through pTarget at targetReserve, sitting on a wave tread
///   (target − boot = 3·λ = whole waves; sin = 0 there), then keeps waving
///   upward forever — every crest a flat tread, every trough a climb, monotone
///   by construction at ampBps = 10000 (45° tilt: A·2π = s·λ).
///
///   λ = (targetReserve − boot) / 3, s = ln(pTarget/B) / (3·λ),
///   A = (ampBps/10⁴)·s·λ/2π.
///
/// Supply integrates reciprocal price using four fixed GL8 cells in the
/// first wavelength. Completed waves use a rounded geometric sum, with
/// partial waves scaled between the same adjacent integer endpoints. Supply is a pure
/// function of reserve, so endpoint differences telescope under chopping.
/// Fixed-point supply eventually saturates; mathematical infinity is not
/// representable. Geometric powers use bounded exponentiation by squaring.
///
/// Buys need no inversion (spend IS ΔR); sells invert q(R) by Newton with a
/// conservative integer clamp. Buy output carries the CurveMath-conservative
/// 1-wei + 1 bps haircut so sell(buy(x)) < x strictly.
library SineMath {
    // ─────────────── constants ───────────────
    uint256 internal constant WAD = 1e18;
    uint256 internal constant PI_WAD = 3141592653589793238; // 3.141592653589793238
    uint256 internal constant TWO_PI_WAD = 6283185307179586476;
    uint256 internal constant HALF_PI_WAD = 1570796326794896619;
    /// @dev expWad input cap: ln(type(uint256).max) in WAD (solady panic guard)
    int256 internal constant MAX_EXP_ARG = 135305999368893231588;
    /// @dev waves between launch seam and target (tread at the target)
    uint256 internal constant WAVES = 3;
    /// @dev min trend across one wavelength, WAD (keeps (g − 1) precise for
    ///      the geometric-series division; 0.01 WAD ⇒ g − 1 ≥ ~1.005e16)
    uint256 internal constant MIN_WAVE_TREND = 1e16;

    // GL8 nodes u_i (ascending, WAD) and weights ŵ_i (WAD, Σ ŵ = 1):
    // ∫_a^b f ≈ (b−a) · Σ ŵ_i · f(a + (b−a)·u_i)
    uint256 internal constant GL8_U0 = 19855071751231912;
    uint256 internal constant GL8_U1 = 101666761293186640;
    uint256 internal constant GL8_U2 = 237233795041835520;
    uint256 internal constant GL8_U3 = 408282678752175040;
    uint256 internal constant GL8_U4 = 591717321247824896;
    uint256 internal constant GL8_U5 = 762766204958164480;
    uint256 internal constant GL8_U6 = 898333238706813312;
    uint256 internal constant GL8_U7 = 980144928248768128;
    uint256 internal constant GL8_W0 = 50614268145188264;
    uint256 internal constant GL8_W1 = 111190517226687232;
    uint256 internal constant GL8_W2 = 156853322938943584;
    uint256 internal constant GL8_W3 = 181341891689180896;

    // ─────────────── types ───────────────

    /// @notice Deploy-time parameters (validated by `validate`).
    struct Params {
        uint256 p0;            // price at reserve 0 (WAD mixETH per PSP)
        uint256 preK;          // predeposit growth, ln-units per mixETH (WAD)
        uint256 pTarget;       // marginal price at the target reserve (WAD)
        uint256 targetReserve; // reserve where price = pTarget (WAD mixETH)
        uint24 ampBps;         // amplitude in bps of the 45° maximum (≤ 10_000)
    }

    /// @notice Materialized curve — built once at launch from the ACTUAL
    ///         post-fee boot, so the wave is anchored to real boot and the
    ///         launch-seam price is B regardless of trade history.
    struct Curve {
        uint256 p0;
        uint256 preK;
        uint256 boot;          // actual post-fee raise; the wave starts here
        uint256 targetReserve; // price pTarget lands on a tread here
        uint256 lam;           // wavelength = (targetReserve − boot) / 3
        uint256 B;             // p0·e^(preK·boot) — price at launch seam
        uint256 slope;         // s = ln(pTarget/B) / (3·λ) (ln-units per mixETH)
        uint256 amp;           // ln-units; ≤ slope·λ/2π by construction
        uint256 g;             // e^(s·λ) — per-wave envelope growth (> WAD)
        uint256 W;             // supply minted across the FIRST wavelength
        uint256 q0;            // genesis supply at launch (predeposit leg integral)
    }

    // ─────────────── errors ───────────────
    error InvalidParams();
    error ExpOverflow();
    error ExpPreArg();
    error ExpLnArg();
    error ExpPriceArg();

    // ─────────────── validation ───────────────

    function validate(Params memory p) internal pure {
        // RS-2: supported fixed-point configuration domain. Unbounded inputs
        // used to pass validation yet round slope to zero at launch, making
        // every post-launch quote divide by zero. These limits also bound
        // phase/slope rounding and predeposit products before arithmetic.
        if (p.p0 < 1e9 || p.p0 > 1e18 || p.preK < 1e12 || p.preK > 1e16) revert InvalidParams();
        if (p.targetReserve < 451e18 || p.targetReserve > 1_000_000e18) revert InvalidParams();
        if (p.pTarget == 0 || p.pTarget > p.p0 * 10_000_000) revert InvalidParams();
        // AUD-8: every public raise (up to 500 gross / 450 net mixETH)
        // must materialize successfully before accepting any deposits.
        uint256 preArg = FPML.mulWad(p.preK, 450e18);
        if (preArg >= uint256(MAX_EXP_ARG)) revert InvalidParams();
        uint256 maxBootPrice = FPML.mulWad(p.p0, uint256(FPML.expWad(int256(preArg))));
        if (maxBootPrice == 0 || FPML.divWad(p.pTarget, maxBootPrice) < WAD + MIN_WAVE_TREND / 3) revert InvalidParams();
        if (FPML.mulWad(p.preK, p.p0) == 0) revert InvalidParams();
        if (p.ampBps > 10_000) revert InvalidParams();      // 45° cap ⇒ monotone
    }

    // ─────────────── materialization (once, at launch) ───────────────

    function materialize(Params memory p, uint256 bootActual) internal pure returns (Curve memory c) {
        if (bootActual == 0) revert InvalidParams();
        if (bootActual >= p.targetReserve) revert InvalidParams(); // target must be ahead
        c.p0 = p.p0;
        c.preK = p.preK;
        c.boot = bootActual;
        c.targetReserve = p.targetReserve;
        c.lam = (p.targetReserve - bootActual) / WAVES;
        uint256 preArg = FPML.mulWad(p.preK, bootActual);
        if (int256(preArg) > MAX_EXP_ARG) revert ExpPreArg();
        c.B = FPML.mulWad(p.p0, uint256(FPML.expWad(int256(preArg))));
        // trend: pTarget/B across 3·λ (the target sits on a whole-wave tread —
        // sin = 0 there, so the trend alone lands the price ON pTarget)
        uint256 lnArg = FPML.divWad(p.pTarget, c.B);
        if (lnArg < WAD + MIN_WAVE_TREND / 3) revert InvalidParams(); // (g−1) precision floor
        // (no upper cap: ln(600) = 6.4 for the 10k/0.06 target is a legal
        // log-ratio — the old ExpLnArg guard here was a copy of the EXP
        // argument cap and wrongly rejected the entire 600x trend)
        c.slope = FPML.divWad(uint256(FPML.lnWad(int256(lnArg))), c.lam * WAVES);
        if (c.slope == 0) revert InvalidParams();
        // amp = ampBps/1e4 · slope·λ/(2π)
        c.amp = FPML.mulWad(
            uint256(p.ampBps) * 1e14,
            FPML.divWad(FPML.mulWad(c.slope, c.lam), TWO_PI_WAD)
        );
        c.g = uint256(FPML.expWad(int256(FPML.mulWad(c.slope, c.lam))));
        if (c.g <= WAD) revert InvalidParams();
        // First wavelength: four fixed GL8 cells, checked against a Decimal oracle.
        c.W = _waveSupply(c, c.lam);
        // genesis supply: q0 = (1 − e^(−preK·boot)) / (preK·p0)
        uint256 expNeg = uint256(FPML.expWad(-int256(preArg)));
        c.q0 = FPML.divWad(WAD - expNeg, FPML.mulWad(p.preK, p.p0));
        if (c.W == 0 || c.q0 == 0) revert InvalidParams();
    }

    // ─────────────── price ───────────────

    /// @notice Marginal price at cumulative reserve R (WAD mixETH per PSP).
    ///         Unbounded above: the wave rides the exponential trend forever.
    function priceAt(Curve memory c, uint256 R) internal pure returns (uint256) {
        if (R <= c.boot) {
            return FPML.mulWad(c.p0, uint256(FPML.expWad(int256(FPML.mulWad(c.preK, R)))));
        }
        uint256 u = (R - c.boot) % c.lam; // exact integer mod — no angle precision loss
        // phase = π + 2π·u/λ  (sin evaluated on the reduced angle)
        int256 sinv = _sinWad(PI_WAD + FPML.mulWad(u, FPML.divWad(TWO_PI_WAD, c.lam)));
        // solady mulWad is uint-only — split the sign by hand
        int256 ampTerm = sinv < 0
            ? -int256(FPML.mulWad(c.amp, uint256(-sinv)))
            : int256(FPML.mulWad(c.amp, uint256(sinv)));
        int256 arg = int256(FPML.mulWad(c.slope, R - c.boot)) + ampTerm;
        if (arg > MAX_EXP_ARG) revert ExpPriceArg();
        return FPML.mulWad(c.B, uint256(FPML.expWad(arg)));
    }

    // ─────────────── cumulative supply (endpoint-pure, unbounded) ───────────────

    /// @notice q(R) — PSP minted from reserve 0 through R. Pure in R:
    ///         identical inputs give identical outputs regardless of trade
    ///         history ⇒ buy/sell integrals telescope exactly under chopping.
    ///         Rounded geometric endpoints plus composite GL8 for the partial wave.
    function supplyAt(Curve memory c, uint256 R) internal pure returns (uint256) {
        if (R <= c.boot) {
            uint256 expNeg = uint256(FPML.expWad(-int256(FPML.mulWad(c.preK, R))));
            return FPML.divWad(WAD - expNeg, FPML.mulWad(c.preK, c.p0));
        }
        uint256 d = R - c.boot;
        uint256 k = d / c.lam;  // completed waves
        // AUD-6: normalize each partial wave between its two computed
        // cumulative endpoints. Rounding cannot create a downward wave seam.
        // Exponentiation by squaring keeps very shallow trends bounded in gas.
        uint256 invG = FPML.fullMulDiv(WAD, WAD, c.g);
        uint256 left = FPML.fullMulDiv(c.W, WAD - FPML.rpow(invG, k, WAD), WAD - invG);
        uint256 right = FPML.fullMulDiv(c.W, WAD - FPML.rpow(invG, k + 1, WAD), WAD - invG);
        uint256 partialSupply = _waveSupply(c, d % c.lam);
        if (partialSupply > c.W) partialSupply = c.W;
        return c.q0 + left + FPML.fullMulDiv(partialSupply, right - left, c.W);
    }

    /// @notice Inverse of supplyAt: the reserve R with q(R) = qTarget
    ///         (post-boot: returns an upper reserve endpoint to avoid overpaying sells).
    /// @dev Starts from the CLOSED-FORM fractional wave index — the total
    ///      supply at d = x·λ past boot is q0 + W·g·(1−g⁻ˣ)/(g−1), so
    ///      x = −ln(1 − dQ·(g−1)/(W·g)) / ln(g) lands within one wavelength
    ///      of the true reserve; Newton (convex ⇒ alternating, contracting)
    ///      then refines inside that neighborhood. No runaway walks: prices
    ///      near the start are the prices near the answer.
    function reserveAt(Curve memory c, uint256 qTarget) internal pure returns (uint256) {
        if (qTarget <= c.q0) {
            // predeposit invert: R = −ln(1 − q·preK·p0)/preK
            uint256 preX = FPML.mulWad(FPML.mulWad(qTarget, c.preK), c.p0); // q·preK·p0 ≤ 1
            if (preX >= WAD) return c.boot;
            return FPML.divWad(uint256(-FPML.lnWad(int256(WAD - preX))), c.preK);
        }
        // g⁻ˣ = 1 − dQ·(g−1)/(W·g)   (dQ = qTarget − q0; strictly > 0 here)
        uint256 invG = FPML.fullMulDiv(WAD, WAD, c.g);
        uint256 fraction = FPML.fullMulDiv(qTarget - c.q0, WAD - invG, c.W);
        if (fraction >= WAD) revert InvalidParams(); // outside representable inverse domain
        uint256 gNegX = WAD - fraction;
        uint256 x = FPML.divWad(uint256(-FPML.lnWad(int256(gNegX))), uint256(FPML.lnWad(int256(c.g))));
        uint256 R = c.boot + FPML.mulWad(x, c.lam);
        // AUD-6: bracket Newton and return the UPPER reserve endpoint.
        // A lower endpoint overpays a seller (payout = old reserve - endpoint).
        uint256 lo = c.boot;
        uint256 hi = R + c.lam;
        for (uint256 i; supplyAt(c, hi) < qTarget; ++i) {
            if (i == 16) revert InvalidParams();
            hi += c.lam;
        }
        for (uint256 it; it < 96 && hi - lo > 1; ++it) {
            uint256 have = supplyAt(c, R);
            if (have == qTarget) return R;
            if (have < qTarget) lo = R;
            else hi = R;
            uint256 candidate;
            if (it < 16) {
                uint256 delta = have < qTarget ? qTarget - have : have - qTarget;
                uint256 step = FPML.mulWad(delta, priceAt(c, R));
                candidate = have < qTarget ? R + step : (step < R ? R - step : 0);
            }
            R = candidate > lo && candidate < hi ? candidate : lo + (hi - lo) / 2;
        }
        return hi;
    }

    // ─────────────── swap outputs ───────────────

    /// @notice PSP out for a curve spend of c mixETH at reserve R (pre-fee).
    ///         Buy needs no inversion — spend IS ΔR.
    function buyOut(Curve memory c, uint256 R, uint256 spend) internal pure returns (uint256) {
        uint256 out = supplyAt(c, R + spend) - supplyAt(c, R);
        if (out <= 1) return 0;
        out -= 1;                 // 1-wei haircut (CurveMath convention)
        return out * 9999 / 10000; // 1 bps conservative — strict round-trip
    }

    /// @notice mixETH out for burning pspIn PSP at reserve R (pre-fee).
    ///         Conservative by the integer clamp in reserveAt.
    function sellOut(Curve memory c, uint256 R, uint256 pspIn) internal pure returns (uint256) {
        uint256 qNow = supplyAt(c, R);
        if (pspIn >= qNow) return R; // caller guards supply; defensive floor
        uint256 Rn = reserveAt(c, qNow - pspIn);
        return Rn >= R ? 0 : R - Rn;
    }

    // ─────────────── internals ───────────────

    /// @dev Four fixed cells per canonical wavelength. Partial intervals
    /// reuse completed cells, improving accuracy and endpoint continuity.
    function _waveSupply(Curve memory c, uint256 distance) private pure returns (uint256 result) {
        uint256 a = c.boot;
        uint256 end = c.boot + distance;
        for (uint256 i = 1; i <= 4 && a < end; ++i) {
            uint256 b = c.boot + c.lam * i / 4;
            if (b > end) b = end;
            result += _gl8Supply(c, a, b);
            a = b;
        }
    }

    /// @dev 8-point Gauss–Legendre quadrature of dR/p over [a, b].
    function _gl8Supply(Curve memory c, uint256 a, uint256 b) internal pure returns (uint256) {
        if (b <= a) return 0;
        uint256 w = b - a;
        uint256 acc = FPML.mulWad(GL8_W0, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U0))))
            + FPML.mulWad(GL8_W1, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U1))))
            + FPML.mulWad(GL8_W2, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U2))))
            + FPML.mulWad(GL8_W3, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U3))))
            + FPML.mulWad(GL8_W3, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U4))))
            + FPML.mulWad(GL8_W2, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U5))))
            + FPML.mulWad(GL8_W1, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U6))))
            + FPML.mulWad(GL8_W0, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U7))));
        return FPML.mulWad(w, acc);
    }

    /// @dev sin(x) for x in [0, 2π·WAD). Reflections reduce to [0, π/2],
    ///      then a 10-term Taylor series in WAD (max rel error < 1e-18 there).
    function _sinWad(uint256 x) internal pure returns (int256) {
        if (x >= TWO_PI_WAD) x -= TWO_PI_WAD; // callers pass [π, 3π) — reduce once
        if (x > PI_WAD) {
            // sin(x) = −sin(x−π) on (π, 2π)
            uint256 y = x - PI_WAD;
            return -_sinWad(y <= HALF_PI_WAD ? y : PI_WAD - y);
        }
        if (x > HALF_PI_WAD) x = PI_WAD - x; // sin(π−x) = sin(x); now [0, π/2]
        // sin(x) = x·Σ (−1)^n x^{2n}/(2n+1)!, via the recurrence
        // term_n = term_{n−1}·t/((2n)(2n+1)) — divisors 6,20,42,72,110,156,210,272,342,420
        uint256 t = FPML.mulWad(x, x);
        uint256 s = WAD;
        uint256 term = FPML.mulWad(WAD, FPML.mulWad(t, 166666666666666667)); // /6
        s -= term;
        term = FPML.mulWad(term, FPML.mulWad(t, 50000000000000000)); // /20
        s += term;
        term = FPML.mulWad(term, FPML.mulWad(t, 23809523809523810)); // /42
        s -= term;
        term = FPML.mulWad(term, FPML.mulWad(t, 13888888888888889)); // /72
        s += term;
        term = FPML.mulWad(term, FPML.mulWad(t, 9090909090909091)); // /110
        s -= term;
        term = FPML.mulWad(term, FPML.mulWad(t, 6410256410256410)); // /156
        s += term;
        term = FPML.mulWad(term, FPML.mulWad(t, 4761904761904762)); // /210
        s -= term;
        term = FPML.mulWad(term, FPML.mulWad(t, 3676470588235294)); // /272
        s += term;
        term = FPML.mulWad(term, FPML.mulWad(t, 2923976608187135)); // /342
        s -= term;
        term = FPML.mulWad(term, FPML.mulWad(t, 2380952380952381)); // /420
        s += term;
        return int256(FPML.mulWad(x, s));
    }
}
