// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib as FPML} from "solady/src/utils/FixedPointMathLib.sol";

/// @title SineMath — INDEFINITE tilted-sine bonding curve (scoopy 2026-09-03)
/// @notice Price is a function of cumulative mixETH RAISED (reserve), not supply.
///         The curve has exactly TWO regimes — no segmented phases, no tail:
///
///   predeposit (R in [0, boot]):  p = p0 · e^(preGrowth·R/boot)
///   wave       (R > boot):        p = B · e^( trend·(R−boot)/λ + A·sin(π + 2π·(R−boot)/λ) )
///
///   ...and the wave NEVER ends. The trend is anchored by the target: the
///   curve passes through pTarget at targetReserve, sitting on a wave tread
///   (target − boot = 3·λ = whole waves; sin = 0 there), then keeps waving
///   upward forever — every crest a flat tread, every trough a climb, monotone
///   by construction at ampBps = 10000 (45° tilt: A·2π = trend).
///
///   λ = (targetReserve − boot) / 3, trend = ln(pTarget/B) / 3,
///   A = (ampBps/10⁴)·trend/2π. Parameters describe a 450 mixETH net
///   reference raise. Reserve distances scale with the actual net IBCO raise.
///   Dimensionless growth avoids rounding a per-reserve slope down to zero.
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
    uint256 internal constant REFERENCE_BOOT = 450e18;
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
        uint256 preK;          // growth per mixETH at the 450-mixETH reference raise (WAD)
        uint256 pTarget;       // marginal price at the target reserve (WAD)
        uint256 targetReserve; // reference reserve where price = pTarget (WAD mixETH)
        uint24 ampBps;         // amplitude in bps of the 45° maximum (≤ 10_000)
    }

    /// @notice Materialized curve — built once at launch from the ACTUAL
    ///         post-fee boot, so the wave is anchored to real boot and the
    ///         launch-seam price is B regardless of trade history.
    struct Curve {
        uint256 p0;
        uint256 preGrowth;     // dimensionless log growth across the entire IBCO (WAD)
        uint256 boot;          // actual post-fee raise; the wave starts here
        uint256 targetReserve; // price pTarget lands on a tread here
        uint256 lam;           // wavelength = (targetReserve − boot) / 3
        uint256 B;             // p0·e^preGrowth — price at launch seam
        uint256 waveTrend;     // ln(pTarget/B) / 3, dimensionless per-wave growth (WAD)
        uint256 amp;           // ln-units; ≤ waveTrend/2π by construction
        uint256 g;             // e^waveTrend — per-wave envelope growth (> WAD)
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
        // RS-2: parameters remain bounded in reference coordinates. The
        // actual raise changes reserve distances, never exponential arguments.
        if (p.p0 < 1e9 || p.p0 > 1e18 || p.preK < 1e12 || p.preK > 1e16) revert InvalidParams();
        if (p.targetReserve < 451e18 || p.targetReserve > 1_000_000e18) revert InvalidParams();
        if (p.pTarget == 0 || p.pTarget > p.p0 * 10_000_000) revert InvalidParams();
        uint256 preGrowth = FPML.mulWad(p.preK, REFERENCE_BOOT);
        uint256 bootPrice = FPML.mulWad(p.p0, uint256(FPML.expWad(int256(preGrowth))));
        if (bootPrice == 0 || FPML.divWad(p.pTarget, bootPrice) < WAD + MIN_WAVE_TREND / 3) revert InvalidParams();
        if (p.ampBps > 10_000) revert InvalidParams();
    }

    // ─────────────── materialization (once, at launch) ───────────────

    function materialize(Params memory p, uint256 bootActual) internal pure returns (Curve memory c) {
        validate(p);
        if (bootActual == 0) revert InvalidParams();
        c.p0 = p.p0;
        c.preGrowth = FPML.mulWad(p.preK, REFERENCE_BOOT);
        c.boot = bootActual;
        c.targetReserve = FPML.fullMulDiv(p.targetReserve, bootActual, REFERENCE_BOOT);
        c.lam = (c.targetReserve - bootActual) / WAVES;
        if (c.lam == 0) revert InvalidParams();
        c.B = FPML.mulWad(p.p0, uint256(FPML.expWad(int256(c.preGrowth))));
        uint256 lnArg = FPML.divWad(p.pTarget, c.B);
        c.waveTrend = uint256(FPML.lnWad(int256(lnArg))) / WAVES;
        c.amp = FPML.fullMulDiv(uint256(p.ampBps) * 1e14, c.waveTrend, TWO_PI_WAD);
        c.g = uint256(FPML.expWad(int256(c.waveTrend)));
        c.W = _waveSupply(c, c.lam);
        c.q0 = _preSupply(c, bootActual);
        if (c.W == 0 || c.q0 == 0) revert InvalidParams();
        uint256 invG = FPML.fullMulDiv(WAD, WAD, c.g);
        uint256 waveLimit = FPML.fullMulDivUp(c.W, WAD, WAD - invG);
        if (waveLimit > type(uint256).max - c.q0) revert InvalidParams();
    }

    // ─────────────── price ───────────────

    /// @notice Marginal price at cumulative reserve R (WAD mixETH per PSP).
    ///         Unbounded above: the wave rides the exponential trend forever.
    function priceAt(Curve memory c, uint256 R) internal pure returns (uint256) {
        if (R <= c.boot) {
            return FPML.mulWad(c.p0, uint256(FPML.expWad(int256(FPML.fullMulDiv(c.preGrowth, R, c.boot)))));
        }
        int256 arg = _waveExponent(c, R - c.boot);
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
            return _preSupply(c, R);
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
        if (qTarget <= c.q0) return _preReserveAt(c, qTarget);
        // g⁻ˣ = 1 − dQ·(g−1)/(W·g)   (dQ = qTarget − q0; strictly > 0 here)
        uint256 invG = FPML.fullMulDiv(WAD, WAD, c.g);
        uint256 fraction = FPML.fullMulDiv(qTarget - c.q0, WAD - invG, c.W);
        if (fraction >= WAD) revert InvalidParams(); // outside representable inverse domain
        uint256 gNegX = WAD - fraction;
        uint256 x = FPML.divWad(uint256(-FPML.lnWad(int256(gNegX))), uint256(FPML.lnWad(int256(c.g))));
        uint256 R = c.boot + FPML.fullMulDiv(x, c.lam, WAD);
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
                uint256 step = FPML.fullMulDiv(delta, priceAt(c, R), WAD);
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
        uint256 beforeSupply = supplyAt(c, R);
        uint256 afterSupply = supplyAt(c, R + spend);
        if (afterSupply <= beforeSupply) return 0;
        uint256 out = afterSupply - beforeSupply;
        // RS-3: any integral under a monotone price is bounded by the
        // starting spot price. This also contains GL8 rounding at very large
        // raises, where a minimum-size buy is microscopic in curve units.
        uint256 spotBound = FPML.fullMulDiv(spend, _inversePriceAt(c, R, false), WAD);
        if (out > spotBound) out = spotBound;
        if (out <= 1) return 0;
        out -= 1;                 // 1-wei haircut (CurveMath convention)
        return FPML.fullMulDiv(out, 9999, 10000); // 1 bps conservative — strict round-trip
    }

    /// @notice mixETH out for burning pspIn PSP at reserve R (pre-fee).
    ///         Conservative by the integer clamp in reserveAt.
    function sellOut(Curve memory c, uint256 R, uint256 pspIn) internal pure returns (uint256) {
        uint256 qNow = supplyAt(c, R);
        if (pspIn >= qNow) return R; // caller guards supply; defensive floor
        uint256 Rn = reserveAt(c, qNow - pspIn);
        if (Rn >= R) return 0;
        uint256 out = R - Rn;
        uint256 inverseSpot = _inversePriceAt(c, R, true);
        if (inverseSpot != 0) {
            // A sell traverses prices at or below its starting spot price.
            // Bound numerical inversion by that independent geometric limit.
            uint256 spotBound = FPML.fullMulDiv(pspIn, WAD, inverseSpot);
            if (out > spotBound) out = spotBound;
        }
        return out;
    }

    // ─────────────── internals ───────────────

    /// @dev Reciprocal spot price avoids evaluating a positive exponential
    /// beyond its representable horizon. A zero value means fixed-point
    /// precision cannot represent any new output at this reserve.
    function _inversePriceAt(Curve memory c, uint256 R, bool roundUp) private pure returns (uint256) {
        if (R <= c.boot) {
            uint256 preArg = FPML.fullMulDiv(c.preGrowth, R, c.boot);
            uint256 preReciprocal = uint256(FPML.expWad(-int256(preArg)));
            return roundUp ? FPML.fullMulDivUp(preReciprocal + 1, WAD, c.p0)
                : FPML.fullMulDiv(preReciprocal, WAD, c.p0);
        }
        uint256 distance = R - c.boot;
        if (distance / c.lam > (42e18 + c.amp) / c.waveTrend + 1) return 0;
        int256 arg = _waveExponent(c, distance);
        uint256 reciprocal = uint256(FPML.expWad(-arg));
        // The sell bound rounds the reciprocal up. Otherwise a one-unit
        // drop near exp(-arg) saturation could inflate a dust sell's value.
        return roundUp ? FPML.fullMulDivUp(reciprocal + 1, WAD, c.B)
            : FPML.fullMulDiv(reciprocal, WAD, c.B);
    }

    function _waveExponent(Curve memory c, uint256 distance) private pure returns (int256) {
        uint256 u = distance % c.lam;
        int256 sinv = _sinWad(PI_WAD + FPML.fullMulDiv(TWO_PI_WAD, u, c.lam));
        int256 ampTerm = sinv < 0
            ? -int256(FPML.mulWad(c.amp, uint256(-sinv)))
            : int256(FPML.mulWad(c.amp, uint256(sinv)));
        uint256 trendArg = FPML.fullMulDiv(c.waveTrend, distance, c.lam);
        if (trendArg > uint256(MAX_EXP_ARG) + c.amp) revert ExpPriceArg();
        return int256(trendArg) + ampTerm;
    }

    /// @dev q(R) = boot/p0 · (1 − exp(−preGrowth·R/boot))/preGrowth.
    /// Growth is normalized before scaling the integral to the actual raise.
    function _preSupply(Curve memory c, uint256 R) private pure returns (uint256) {
        uint256 arg = FPML.fullMulDiv(c.preGrowth, R, c.boot);
        uint256 expNeg = uint256(FPML.expWad(-int256(arg)));
        uint256 fraction = FPML.fullMulDiv(WAD - expNeg, WAD, c.preGrowth);
        return FPML.fullMulDiv(c.boot, fraction, c.p0);
    }

    /// @dev Invert the rounded predeposit supply with an upper bracket.
    /// This includes its fixed-point plateaus and never overpays backing.
    function _preReserveAt(Curve memory c, uint256 target) private pure returns (uint256) {
        if (target == 0) return 0;
        if (target == c.q0) return c.boot;
        uint256 lo;
        uint256 hi = c.boot;
        for (uint256 i; i < 96 && hi - lo > 1; ++i) {
            uint256 mid = lo + (hi - lo) / 2;
            if (_preSupply(c, mid) >= target) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    /// @dev Four fixed cells per canonical wavelength. Partial intervals
    /// reuse completed cells, improving accuracy and endpoint continuity.
    function _waveSupply(Curve memory c, uint256 distance) private pure returns (uint256 result) {
        uint256 a = c.boot;
        uint256 end = c.boot + distance;
        for (uint256 i = 1; i <= 4 && a < end; ++i) {
            uint256 b = c.boot + FPML.fullMulDiv(c.lam, i, 4);
            if (b > end) b = end;
            result += _gl8Supply(c, a, b);
            a = b;
        }
    }

    /// @dev 8-point Gauss–Legendre quadrature of dR/p over [a, b].
    function _gl8Supply(Curve memory c, uint256 a, uint256 b) internal pure returns (uint256) {
        if (b <= a) return 0;
        uint256 w = b - a;
        uint256[8] memory nodes = [GL8_U0, GL8_U1, GL8_U2, GL8_U3, GL8_U4, GL8_U5, GL8_U6, GL8_U7];
        uint256[4] memory weights = [GL8_W0, GL8_W1, GL8_W2, GL8_W3];
        uint256 acc;
        for (uint256 i; i < 8; ++i) {
            uint256 node = a + FPML.fullMulDiv(w, nodes[i], WAD);
            uint256 weightIndex;
            unchecked { weightIndex = i < 4 ? i : 7 - i; }
            acc += FPML.mulWad(weights[weightIndex], FPML.divWad(WAD, priceAt(c, node)));
        }
        return FPML.fullMulDiv(w, acc, WAD);
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
        // sin(x) = x · Σ (-1)^n x^(2n)/(2n+1)! for n=0..10.
        // Small integer divisors avoid duplicating ten reciprocal constants
        // in every hook deployment. The polynomial and reduced domain remain
        // unchanged; the independent Decimal oracle checks its precision.
        uint256 t = FPML.mulWad(x, x);
        uint256 s = WAD;
        uint256 term = WAD;
        // n <= 10 and x <= pi/2 bound every product below 3e36.
        // Terms decrease after the first and the alternating sum stays positive.
        unchecked {
            for (uint256 n = 1; n <= 10; ++n) {
                term = (term * t) / (WAD * (2 * n) * (2 * n + 1));
                if (n & 1 == 1) s -= term;
                else s += term;
            }
        }
        return int256(FPML.mulWad(x, s));
    }
}
