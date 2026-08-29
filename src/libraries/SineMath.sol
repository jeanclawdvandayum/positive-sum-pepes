// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib as FPML} from "solady/src/utils/FixedPointMathLib.sol";

/// @title SineMath — parametric tilted-sine bonding curve (scoopy 2026-08-29)
/// @notice Price is a function of cumulative mixETH RAISED (reserve), not supply:
///
///   predeposit (R in [0, boot]):     p = p0 · e^(preK·R)
///   wave region  (R in [boot, top]): p = B · e^( s·(R−boot) + A·sin(π + 2π·(R−boot)/λ) )
///   tail         (R > top):          p = pTop + tailSlope·(R−top)
///
/// with top = boot + span, span = magM·boot, λ = span/3 (three waves), trend
/// s = lnTop/span, and amplitude A = (ampBps/10⁴)·s·λ/2π. At ampBps = 10000
/// ("45° tilt") A·2π = s·λ exactly: the wave never turns down — flat treads at
/// launch and at every wave top, steepest climb through the mids, monotone by
/// construction. The phase offset π puts a flat tread at the launch seam.
///
/// Supply has no closed form over the wave (∫ e^(−A·sin)); cumulative supply is
/// computed as a **pure function of the reserve endpoint**:
///   q(R) = q0 + cp[j] + GL8( a_j → R ),   a_j = boot + j·span/12
/// where cp[j] are checkpoint integrals (computed once at materialize) and GL8
/// is 8-point Gauss–Legendre quadrature with FIXED nodes — a deterministic
/// function of R alone. Endpoint purity makes buy/sell integrals telescope
/// EXACTLY under any order-chopping (partition-invariance, the B4j class).
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
    uint256 internal constant N_CHECKPOINTS = 13; // quarter-wave anchors, 3 waves
    uint256 internal constant WAVES = 3;

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
        uint256 p0;     // price at reserve 0 (WAD mixETH per PSP)
        uint256 preK;   // predeposit growth, ln-units per mixETH (WAD)
        uint256 magM;   // wave span = magM × actual boot (WAD multiple, ≥ 1e18)
        uint256 lnTop;  // ln(pTop / B): total trend climb over the wave region (WAD)
        uint24 ampBps;  // amplitude in bps of the 45° maximum (≤ 10_000)
    }

    /// @notice Materialized curve — built once at launch from the ACTUAL
    ///         predeposit raise, so the wave is anchored to real boot and every
    ///         boundary price is invariant to how much was actually raised
    ///         (same W-cancellation as the dial lab).
    struct Curve {
        uint256 p0;
        uint256 preK;
        uint256 boot;     // actual raise; wave region = [boot, top]
        uint256 span;     // magM·boot; top = boot + span
        uint256 segWidth; // span / 12 (quarter-wave checkpoint spacing)
        uint256 lam;      // 4·segWidth (wavelength; anchors stay exact integers)
        uint256 B;        // p0·e^(preK·boot) — price at launch seam
        uint256 slope;    // s = lnTop/span (ln-units per mixETH)
        uint256 amp;      // ln-units; ≤ slope·lam/2π by construction
        uint256 pTop;     // B·e^lnTop — exact top anchor
        uint256 tailSlope; // slope·pTop — linear tail absolute slope
        uint256 q0;       // genesis supply at launch (predeposit leg integral)
        uint256 qTop;     // supply at curve top = q0 + cp[12]
        uint256[N_CHECKPOINTS] cp; // cumulative supply increments at anchors (cp[0]=0)
    }

    // ─────────────── errors ───────────────
    error InvalidParams();
    error ExpOverflow();

    // ─────────────── validation ───────────────

    function validate(Params memory p) internal pure {
        if (p.p0 == 0 || p.preK == 0 || p.lnTop == 0) revert InvalidParams();
        if (p.magM < WAD) revert InvalidParams();           // span ≥ boot
        if (p.ampBps > 10_000) revert InvalidParams();      // 45° cap ⇒ monotone
    }

    // ─────────────── materialization (once, at launch) ───────────────

    function materialize(Params memory p, uint256 bootActual) internal pure returns (Curve memory c) {
        if (bootActual == 0) revert InvalidParams();
        c.p0 = p.p0;
        c.preK = p.preK;
        c.boot = bootActual;
        c.span = FPML.mulWad(p.magM, bootActual);
        c.segWidth = c.span / 12;
        c.lam = c.segWidth * 4;
        uint256 preArg = FPML.mulWad(p.preK, bootActual);
        if (int256(preArg) > MAX_EXP_ARG || p.lnTop > uint256(MAX_EXP_ARG)) revert ExpOverflow();
        c.B = FPML.mulWad(p.p0, uint256(FPML.expWad(int256(preArg))));
        c.slope = FPML.divWad(p.lnTop, c.span);
        // amp = ampBps/1e4 · slope·λ/(2π)
        c.amp = FPML.mulWad(
            uint256(p.ampBps) * 1e14,
            FPML.divWad(FPML.mulWad(c.slope, c.lam), TWO_PI_WAD)
        );
        c.pTop = FPML.mulWad(c.B, uint256(FPML.expWad(int256(p.lnTop))));
        c.tailSlope = FPML.mulWad(c.slope, c.pTop);
        // genesis supply: q0 = (1 − e^(−preK·boot)) / (preK·p0)
        uint256 expNeg = uint256(FPML.expWad(-int256(preArg)));
        c.q0 = FPML.divWad(WAD - expNeg, FPML.mulWad(p.preK, p.p0));
        // checkpoints: GL8 over each quarter-wave segment
        uint256 acc = 0;
        for (uint256 j = 1; j < N_CHECKPOINTS; j++) {
            uint256 a = c.boot + (j - 1) * c.segWidth;
            uint256 b = c.boot + j * c.segWidth;
            acc += _gl8Supply(c, a, b);
            c.cp[j] = acc;
        }
        c.qTop = c.q0 + c.cp[N_CHECKPOINTS - 1];
    }

    // ─────────────── price ───────────────

    /// @notice Marginal price at cumulative reserve R (WAD mixETH per PSP).
    function priceAt(Curve memory c, uint256 R) internal pure returns (uint256) {
        if (R <= c.boot) {
            return FPML.mulWad(c.p0, uint256(FPML.expWad(int256(FPML.mulWad(c.preK, R)))));
        }
        uint256 top = c.boot + c.span;
        if (R <= top) {
            uint256 u = (R - c.boot) % c.lam; // exact integer mod — no angle precision loss
            // phase = π + 2π·u/λ  (sin evaluated on the reduced angle)
            int256 sinv = _sinWad(PI_WAD + FPML.mulWad(u, FPML.divWad(TWO_PI_WAD, c.lam)));
            // solady mulWad is uint-only — split the sign by hand
            int256 ampTerm = sinv < 0
                ? -int256(FPML.mulWad(c.amp, uint256(-sinv)))
                : int256(FPML.mulWad(c.amp, uint256(sinv)));
            int256 arg = int256(FPML.mulWad(c.slope, R - c.boot)) + ampTerm;
            if (arg > MAX_EXP_ARG) revert ExpOverflow();
            return FPML.mulWad(c.B, uint256(FPML.expWad(arg)));
        }
        return c.pTop + FPML.mulWad(c.tailSlope, R - top);
    }

    // ─────────────── cumulative supply (endpoint-pure) ───────────────

    /// @notice q(R) — PSP minted from reserve 0 through R. Pure in R:
    ///         identical inputs give identical outputs regardless of trade
    ///         history ⇒ buy/sell integrals telescope exactly under chopping.
    function supplyAt(Curve memory c, uint256 R) internal pure returns (uint256) {
        if (R <= c.boot) {
            uint256 expNeg = uint256(FPML.expWad(-int256(FPML.mulWad(c.preK, R))));
            return FPML.divWad(WAD - expNeg, FPML.mulWad(c.preK, c.p0));
        }
        if (R >= c.boot + c.span) {
            // tail: qTop + ln(1 + tailSlope·Δ/pTop)/tailSlope
            uint256 delta = R - (c.boot + c.span);
            uint256 lnArg = WAD + FPML.divWad(FPML.mulWad(c.tailSlope, delta), c.pTop);
            return c.qTop + FPML.divWad(uint256(FPML.lnWad(int256(lnArg))), c.tailSlope);
        }
        uint256 j = (R - c.boot) / c.segWidth; // 0..11
        uint256 a = c.boot + j * c.segWidth;
        return c.q0 + c.cp[j] + _gl8Supply(c, a, R);
    }

    /// @notice Inverse of supplyAt: the reserve R with q(R) = qTarget
    ///         (conservative: returns the largest R with q(R) ≤ qTarget).
    function reserveAt(Curve memory c, uint256 qTarget) internal pure returns (uint256) {
        if (qTarget <= c.q0) {
            // predeposit invert: R = −ln(1 − q·preK·p0)/preK
            uint256 x = FPML.mulWad(FPML.mulWad(qTarget, c.preK), c.p0); // q·preK·p0 ≤ 1
            if (x >= WAD) return c.boot;
            return FPML.divWad(uint256(-FPML.lnWad(int256(WAD - x))), c.preK);
        }
        if (qTarget >= c.qTop) {
            // tail invert: R = top + pTop·(e^(tailSlope·Δq) − 1)/tailSlope
            uint256 dq = qTarget - c.qTop;
            uint256 eu = uint256(FPML.expWad(int256(FPML.mulWad(c.tailSlope, dq))));
            return c.boot + c.span + FPML.divWad(FPML.mulWad(c.pTop, eu - WAD), c.tailSlope);
        }
        // wave region: locate segment, Newton on the local integral, integer clamp
        uint256 local = qTarget - c.q0; // in [1, cp[12])
        uint256 j = 0;
        for (uint256 k = 1; k < N_CHECKPOINTS; k++) {
            if (c.cp[k] < local) j = k; else break;
        }
        uint256 a = c.boot + j * c.segWidth;
        uint256 L = local - c.cp[j];
        uint256 segSup = c.cp[j + 1] - c.cp[j];
        // linear-interpolation start
        uint256 R = a + FPML.mulWad(c.segWidth, FPML.divWad(L, segSup == 0 ? 1 : segSup));
        for (uint256 it = 0; it < 8; it++) {
            uint256 have = _gl8Supply(c, a, R);
            if (have == L) break;
            // ΔR = (L − have)·p(R)  (dq/dR = 1/p)
            int256 step = int256(FPML.mulWad(L > have ? L - have : have - L, priceAt(c, R)));
            if (L > have) {
                R += uint256(step);
            } else {
                R = R > uint256(step) ? R - uint256(step) : a;
            }
        }
        // conservative clamp: largest R with integral ≤ L (each step is ≥ 1 wei
        // of reserve; bounded so gas is capped even on pathological configs)
        uint256 guard = 0;
        while (_gl8Supply(c, a, R) > L && guard < 256) {
            R -= 1;
            guard += 1;
        }
        return R;
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
        return R - Rn;
    }

    // ─────────────── internals ───────────────

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
