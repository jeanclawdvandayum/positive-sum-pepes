// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib as FPML} from "solady/src/utils/FixedPointMathLib.sol";
import {SineV3Knots} from "./SineV3Knots.sol";

/// @title SineV3Math — ONE continuous tilted-sine curve, softened cube-root
///        growth (scoopy 2026-09-14 handoff, SINE_RULES_VERSION 3).
/// @notice A single price formula governs prelaunch and active reserves:
///
///            lambda = 955 * sqrt(b / 450)          (b = actual net backing)
///            R_target = b + 10 * lambda
///            x(R) = (R - b) / lambda
///            s(x) = x - sin(2*pi*x) / (2*pi)
///            H(z) = sign(z) * (cbrt(1 + |z|) - 1)
///            K = ln(1000) / (cbrt(11) - 1)
///            P(R) = P_L * exp(K * H(s(x(R))))
///            Q(R) = (lambda / P_L) * (F(x(R)) - F(x(0)))
///            F(x) = integral_0^x exp(-K * H(s(t))) dt
///
///         The tenth wave lands at exactly 1,000x the launch spot price by
///         construction; wave 10 is a calibration point, not a phase. Supply
///         integrates the SAME curve from reserve zero — genesis allocation
///         is Q(b), not a separate exponential leg.
///
///         Numerics: F is evaluated from canonical quarter-wave knots
///         (SineV3Knots, GL16-derived, x in [-16, +64]) plus one 8-point
///         Gauss-Legendre partial cell at each interval end — O(1) work per
///         evaluation regardless of waves crossed. Worst measured partial
///         error 3.8e-17 relative (independent 70-digit Decimal reference).
///         Partial cells are clamped inside their knot bracket so the
///         rounded F never steps down (monotone by construction).
///
///         Sells invert Q with a bracketed Newton/bisection hybrid on
///         [0, R]; Q is strictly increasing (price is positive), so the
///         bisection fallback guarantees termination. The returned endpoint
///         is the UPPER reserve — a conservative payout bound.
///
///         Deployed once per factory; every round's hook calls it read-only.
///         No storage, no owner, no configuration — the table is the code.
contract SineV3Math {
    // ─────────────── constants ───────────────
    uint256 internal constant WAD = 1e18;
    uint256 internal constant PI_WAD = 3141592653589793238;      // 3.141592653589793238
    uint256 internal constant TWO_PI_WAD = 6283185307179586476;  // 6.283185307179586476
    uint256 internal constant HALF_PI_WAD = 1570796326794896619; // 1.570796326794896619
    /// @dev reference calibration: net backing 450 mixETH, wavelength 955
    uint256 internal constant B_REF = 450e18;
    uint256 internal constant LAM_REF = 955e18;
    /// @dev waves from launch seam to the fee-schedule target
    uint256 internal constant WAVES_TO_TARGET = 10;
    /// @dev supported domain, dimensionless waves: prelaunch span and
    ///      postlaunch reach. Caps net backing at ~518,841 mixETH and price
    ///      at ~1,927 mixETH/PSP for every round — arithmetic capacity,
    ///      not an economic fundraising cap.
    uint256 internal constant PRE_WAVES = 16;
    uint256 internal constant POST_WAVES = 64;

    // GL8 nodes u_i (ascending, WAD) and weights w_i (WAD, first half;
    // symmetric). int_a^b f ~= (b-a) * sum w_i f(a + (b-a)u_i).
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

    // ─────────────── errors ───────────────
    error SineV3Domain(); // reserve outside the supported [-16, +64] wave span

    // ─────────────── materialization ───────────────

    /// @notice Wavelength from actual net backing:
    ///         lambdaWei = floorSqrt(fullMulDiv(955e18^2, bootWei, 450e18)).
    ///         Square-root scaling of the ADDITIONAL backing to target —
    ///         never 10_000*sqrt(D/500), which can fall below launch
    ///         backing for large raises. Exactly 955e18 at the 450e18
    ///         reference; 45,019,131,735 at a one-wei boot (never zero).
    function lamAt(uint256 bootWei) public pure returns (uint256) {
        return FPML.sqrt(FPML.fullMulDiv(LAM_REF * LAM_REF, bootWei, B_REF));
    }

    /// @notice The tenth-wave reserve target: boot + 10*lambda (integer exact).
    function targetAt(uint256 bootWei, uint256 lamWei) public pure returns (uint256) {
        return bootWei + WAVES_TO_TARGET * lamWei;
    }

    // ─────────────── price ───────────────

    /// @notice Marginal price at cumulative reserve R (WAD mixETH per PSP).
    function priceWad(uint256 R, uint256 boot, uint256 lam, uint256 pL) public pure returns (uint256) {
        _checkDomain(R, boot, lam);
        return FPML.mulWad(pL, uint256(FPML.expWad(_exponentAt(_xOf(R, boot, lam)))));
    }

    // ─────────────── cumulative supply (endpoint-pure) ───────────────

    /// @notice Q(R) — PSP minted from reserve 0 through R (WAD PSP).
    ///         Pure in R: identical inputs give identical outputs,
    ///         so buy/sell integrals telescope exactly under chopping.
    function supplyWad(uint256 R, uint256 boot, uint256 lam, uint256 pL) public pure returns (uint256) {
        _checkDomain(R, boot, lam);
        int256 fR = _F(_xOf(R, boot, lam));
        int256 f0 = _F(_negX0(boot, lam));
        // Q = lam * (F(xR) - F(x0)) / pL. Both endpoints can sit on the
        // negative side (prelaunch) where F < 0: use magnitudes, R >= 0
        // guarantees xR >= x0 so the span is never negative.
        uint256 span = fR >= 0 ? uint256(fR) + uint256(-f0) : uint256(-f0) - uint256(-fR);
        return FPML.fullMulDiv(lam, span, pL);
    }

    /// @notice Genesis supply Q(b) — the same curve's integral to launch.
    function genesisQ(uint256 boot, uint256 lam, uint256 pL) external pure returns (uint256) {
        return supplyWad(boot, boot, lam, pL);
    }

    // ─────────────── swap outputs ───────────────

    /// @notice PSP out for a curve spend of `spend` mixETH at reserve R.
    ///         Conservative: spot bound + 1-wei + 1 bps haircut keep
    ///         sell(buy(x)) < x strictly. Reverts SineV3Domain when the
    ///         spend would push the reserve past the supported span —
    ///         before any caller state changes.
    function buyOut(uint256 R, uint256 boot, uint256 lam, uint256 pL, uint256 spend)
        external
        pure
        returns (uint256)
    {
        uint256 before = supplyWad(R, boot, lam, pL);
        uint256 afterS = supplyWad(R + spend, boot, lam, pL); // domain-checked
        if (afterS <= before) return 0;
        uint256 out = afterS - before;
        // Any integral of a monotone price is bounded by the starting spot
        // reciprocal. Rounded down — the bound only ever cuts.
        uint256 bound = FPML.fullMulDiv(spend, WAD, priceWad(R, boot, lam, pL));
        if (out > bound) out = bound;
        if (out <= 1) return 0;
        out -= 1;                                        // 1-wei haircut
        return FPML.fullMulDiv(out, 9999, 10000);        // 1 bps conservative
    }

    /// @notice mixETH out for burning `pspIn` PSP at reserve R (pre-fee).
    ///         Conservative: upper-endpoint inverse + spot clamp.
    function sellOut(uint256 R, uint256 boot, uint256 lam, uint256 pL, uint256 pspIn)
        external
        pure
        returns (uint256)
    {
        uint256 qNow = supplyWad(R, boot, lam, pL);
        if (pspIn >= qNow) return R; // caller guards supply; defensive floor
        uint256 Rn = _reserveAt(R, boot, lam, pL, qNow - pspIn);
        if (Rn >= R) return 0;
        uint256 out = R - Rn;
        // A sell traverses prices at or below its starting spot price; bound
        // numerical inversion by that independent geometric limit.
        uint256 bound = FPML.fullMulDiv(pspIn, priceWad(R, boot, lam, pL), WAD);
        if (out > bound) out = bound;
        return out;
    }

    // ─────────────── internals: coordinates ───────────────

    function _xOf(uint256 R, uint256 boot, uint256 lam) private pure returns (int256) {
        if (R >= boot) return int256(FPML.fullMulDiv(R - boot, WAD, lam));
        return -int256(FPML.fullMulDiv(boot - R, WAD, lam));
    }

    /// @dev x(0) = -boot/lam (truncated toward zero; error < 1e-18 waves).
    function _negX0(uint256 boot, uint256 lam) private pure returns (int256) {
        return -int256(FPML.fullMulDiv(boot, WAD, lam));
    }

    /// @dev Supported span, integer-exact: boot <= 16*lam and R <= boot+64*lam.
    function _checkDomain(uint256 R, uint256 boot, uint256 lam) private pure {
        if (boot > PRE_WAVES * lam || R > boot + POST_WAVES * lam) revert SineV3Domain();
    }

    // ─────────────── internals: F from knots + GL8 partial ───────────────

    /// @dev Signed F at wad x in [-16e18, 64e18]. Cell qi = floor(4x) holds
    ///      x in [qi/4, (qi+1)/4); F(x) = F(qi/4) + GL8([qi/4, x]).
    ///      The partial is clamped to the knot bracket so rounded F never
    ///      steps down (AUD-6 pattern; knots are strictly monotone per side).
    function _F(int256 x) private pure returns (int256) {
        if (x == 0) return 0;
        // qi = floor(x*4), integer floor for negatives included
        int256 q4 = x * 4;
        int256 qi = q4 >= 0 ? int256(uint256(q4) / WAD)
            : -int256((uint256(-q4) / WAD) + (uint256(-q4) % WAD != 0 ? 1 : 0));
        uint256 idx = uint256(int256(qi) + int256(SineV3Knots.ZERO_INDEX));
        uint256 anchor = SineV3Knots.knot(idx);          // |F(qi/4)|, WAD
        int256 anchorX = qi * int256(25e16);             // qi/4 in WAD, exact
        uint256 dx = uint256(x - anchorX);               // [0, 0.25e18)
        if (dx == 0) return qi >= 0 ? int256(anchor) : -int256(anchor);
        // bracket cap on the partial (magnitude of the remaining cell)
        uint256 capNext = SineV3Knots.knot(idx + 1);
        uint256 cap = qi >= 0 ? capNext - anchor : anchor - capNext;
        uint256 part = _gl8Partial(anchorX, dx);
        if (part > cap) part = cap;
        return qi >= 0 ? int256(anchor + part) : -int256(anchor - part);
    }

    /// @dev One GL8 cell over [a, a+dx] in wad-x space: dx * sum(w_i * density(a + dx*u_i)).
    function _gl8Partial(int256 a, uint256 dx) private pure returns (uint256) {
        uint256 acc = FPML.mulWad(GL8_W0, _density(a + int256(FPML.mulWad(dx, GL8_U0))));
        acc += FPML.mulWad(GL8_W1, _density(a + int256(FPML.mulWad(dx, GL8_U1))));
        acc += FPML.mulWad(GL8_W2, _density(a + int256(FPML.mulWad(dx, GL8_U2))));
        acc += FPML.mulWad(GL8_W3, _density(a + int256(FPML.mulWad(dx, GL8_U3))));
        acc += FPML.mulWad(GL8_W3, _density(a + int256(FPML.mulWad(dx, GL8_U4))));
        acc += FPML.mulWad(GL8_W2, _density(a + int256(FPML.mulWad(dx, GL8_U5))));
        acc += FPML.mulWad(GL8_W1, _density(a + int256(FPML.mulWad(dx, GL8_U6))));
        acc += FPML.mulWad(GL8_W0, _density(a + int256(FPML.mulWad(dx, GL8_U7))));
        return FPML.fullMulDiv(dx, acc, WAD);
    }

    /// @dev exp(-K*H(s(x))) — the dimensionless supply density of F.
    function _density(int256 x) private pure returns (uint256) {
        return uint256(FPML.expWad(-_exponentAt(x)));
    }

    /// @dev K * H(s(x)) in WAD — the log-price multiple of P_L.
    function _exponentAt(int256 x) private pure returns (int256) {
        // s(x) = x - sin(2*pi*x)/(2*pi) over the fractional wave
        int256 frac = x % int256(WAD);
        if (frac < 0) frac += int256(WAD);
        int256 sinv = _sinWad(FPML.mulWad(TWO_PI_WAD, uint256(frac)));
        int256 s = x - (sinv < 0
            ? -int256(FPML.fullMulDiv(uint256(-sinv), WAD, TWO_PI_WAD))
            : int256(FPML.fullMulDiv(uint256(sinv), WAD, TWO_PI_WAD)));
        // H(z) = z / (c^2 + c + 1), c = cbrt(1+|z|) — the cancellation-safe
        // identity; H(0) = 0. |z| <= ~65e18 in-domain.
        uint256 zAbs = s < 0 ? uint256(-s) : uint256(s);
        uint256 c = FPML.cbrtWad(WAD + zAbs);
        // c*c is raw-scaled — bring it to WAD before summing with c and 1.
        uint256 denom = FPML.fullMulDiv(c, c, WAD) + c + WAD;
        int256 h = s < 0 ? -int256(FPML.fullMulDiv(zAbs, WAD, denom))
            : int256(FPML.fullMulDiv(zAbs, WAD, denom));
        // |K*H| <= ~33e18 in-domain: comfortably inside expWad's range.
        return _mulWadSigned(int256(SineV3Knots.K_WAD), h);
    }

    /// @dev Signed mulWad — the vendored solady predates the signed overload.
    ///      |K_WAD * h| stays far below 2^127 in-domain.
    function _mulWadSigned(int256 a, int256 b) private pure returns (int256) {
        if (a == 0 || b == 0) return 0;
        bool neg = (a < 0) != (b < 0);
        uint256 ua = a < 0 ? uint256(-a) : uint256(a);
        uint256 ub = b < 0 ? uint256(-b) : uint256(b);
        uint256 r = FPML.fullMulDiv(ua, ub, WAD);
        return neg ? -int256(r) : int256(r);
    }

    // ─────────────── internals: inverse ───────────────

    /// @dev Smallest R with supplyWad(R) >= qTarget (upper endpoint — never
    ///      overpays a seller). Bracketed Newton/bisection on [0, R]:
    ///      Q strictly increasing guarantees bisection termination; the
    ///      Newton tangent accelerates from a good seed.
    function _reserveAt(uint256 R, uint256 boot, uint256 lam, uint256 pL, uint256 qTarget)
        private
        pure
        returns (uint256)
    {
        // proportional seed: reserve scales with the remaining supply
        // fraction (seed IS the candidate estimate, not a delta to subtract)
        uint256 seed = FPML.fullMulDiv(R, qTarget, supplyWad(R, boot, lam, pL));
        uint256 cand = seed < R ? seed : R;
        uint256 lo;
        uint256 hi = R;
        for (uint256 i; i < 128 && hi > lo + 1; ++i) {
            uint256 have = supplyWad(cand, boot, lam, pL);
            if (have == qTarget) return cand;
            if (have < qTarget) lo = cand;
            else hi = cand;
            // Newton step along 1/P; fall back to bisection outside (lo, hi)
            uint256 delta = have < qTarget ? qTarget - have : have - qTarget;
            uint256 step = FPML.fullMulDiv(delta, priceWad(cand, boot, lam, pL), WAD);
            uint256 next = have < qTarget
                ? (step < type(uint256).max - cand ? cand + step : type(uint256).max)
                : (step < cand ? cand - step : 0);
            cand = (next > lo && next < hi) ? next : lo + (hi - lo) / 2;
        }
        return hi;
    }

    // ─────────────── internals: sine ───────────────

    /// @dev sin(x) for x in [0, 2π*WAD). Reflections reduce to [0, π/2],
    ///      then a 10-term Taylor series in WAD (max rel error < 1e-18
    ///      there). Identical to the proven SineMath v2 implementation.
    function _sinWad(uint256 x) private pure returns (int256) {
        if (x >= TWO_PI_WAD) x -= TWO_PI_WAD;
        if (x > PI_WAD) {
            // sin(x) = -sin(x-π) on (π, 2π)
            uint256 y = x - PI_WAD;
            return -_sinWad(y <= HALF_PI_WAD ? y : PI_WAD - y);
        }
        if (x > HALF_PI_WAD) x = PI_WAD - x; // sin(π-x) = sin(x); now [0, π/2]
        uint256 t = FPML.mulWad(x, x);
        uint256 s = WAD;
        uint256 term = WAD;
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
