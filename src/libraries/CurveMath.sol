// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib as FPML} from "solady/src/utils/FixedPointMathLib.sol";

/// @title CurveMath — Multi-oscillation bonding curve math
/// @notice Supports S-curves with N oscillations: alternating exponential (volatile)
///         and logarithmic (stable) zones, creating "islands of stability" and
///         "zones of volatility" in the price curve.
/// @dev All amounts in 1e18 precision (WAD). The curve's unit of account is
///      mixETH (the vault share token), NOT ETH: P0, prices, and integrals are
///      mixETH-denominated. The mixETH/ETH exchange rate is deliberately never
///      read in settlement math — vault yield and losses therefore accrue
///      pro-rata to PSP holders through mixETH's own rate instead of being
///      converted per-trade (which made the reserve short a depeg put).
///
/// Zone types:
///   - Exponential: P(s) = P_start * e^(k * (s - s_start))  — rapid growth, FOMO zone
///   - Logarithmic: P(s) = P_start * (1 + k * ln(s / s_start)) — gradual growth, stability island
///
/// Price is continuous at zone boundaries. Each zone's P_start = previous zone's P_end.
library CurveMath {
    uint256 internal constant WAD = 1e18;

    struct Zone {
        uint256 startSupply;  // supply at zone start (1e18)
        uint256 endSupply;    // supply at zone end (1e18), type(uint256).max for last zone
        uint256 rate;         // growth rate k (1e18)
        bool isExponential;   // true = exponential, false = logarithmic
    }

    struct CurveConfig {
        uint256 P0;           // starting price at supply=0 (1e18 ETH)
        Zone[] zones;         // ordered zones from supply 0 onward
    }

    // ═══════════════════════════════════════════════════════════════
    //  Price Functions
    // ═══════════════════════════════════════════════════════════════

    /// @notice Marginal price at supply S
    function marginalPrice(uint256 S, CurveConfig memory cc) internal pure returns (uint256) {
        if (S == 0) return cc.P0;

        uint256 price = cc.P0;
        for (uint256 i = 0; i < cc.zones.length; i++) {
            Zone memory z = cc.zones[i];
            if (S <= z.startSupply) break;

            uint256 zoneEnd = z.endSupply;
            uint256 evalPoint = S < zoneEnd ? S : zoneEnd;

            if (z.isExponential) {
                price = _expPrice(price, z.rate, evalPoint - z.startSupply);
            } else {
                price = _logPrice(price, z.rate, evalPoint, z.startSupply);
            }

            if (S <= zoneEnd) break;
        }
        return price;
    }

    /// @dev Exponential zone price: P_start * e^(k * delta)
    function _expPrice(uint256 pStart, uint256 k, uint256 delta)
        internal
        pure
        returns (uint256)
    {
        if (delta == 0) return pStart;
        // Guard against overflow: if k * delta would exceed expWad domain,
        // cap delta to prevent panic. expWad accepts up to ~1e18 * 413206.
        uint256 expInput = FPML.mulWad(k, delta);
        if (expInput > 135305999368893231588) {
            // ln(type(uint256).max) ≈ 135.3 in WAD. Beyond this, expWad panics.
            expInput = 135305999368893231588;
        }
        int256 ePow = FPML.expWad(int256(expInput));
        return FPML.mulWad(pStart, uint256(ePow));
    }

    /// @dev Logarithmic zone price: P_start * (1 + k * ln(s / s_start))
    function _logPrice(uint256 pStart, uint256 k, uint256 s, uint256 sStart)
        internal
        pure
        returns (uint256)
    {
        if (s == sStart) return pStart;
        // Cap s to prevent divWad overflow when s * WAD > type(uint256).max
        uint256 sCapped = s > MAX_SUPPLY ? MAX_SUPPLY : s;
        int256 ratio = int256(FPML.divWad(sCapped, sStart));
        int256 lnRatio = FPML.lnWad(ratio);
        // 1 + k * lnRatio (all in WAD)
        uint256 lnAbs = lnRatio > 0 ? uint256(lnRatio) : uint256(0);
        uint256 growthFactor = WAD + FPML.mulWad(k, lnAbs);
        return FPML.mulWad(pStart, growthFactor);
    }

    /// Maximum supported supply to prevent overflow in expWad/lnWad/divWad.
    /// At 1e18 precision, expWad(k * delta) overflows when k * delta > ~1e18.
    /// With k ~ 1e-7 * 1e18 = 1e11, delta up to 1e29 is safe. Cap at 1e28 (10B tokens).
    uint256 internal constant MAX_SUPPLY = 1e28; // 10 billion tokens at 1e18 precision

    // ═══════════════════════════════════════════════════════════════
    //  Buy Output: ∫_{S}^{S+ΔS} P(s) ds = ethInput → solve for ΔS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Compute PSP output for ETH input (before fee)
    /// @dev Uses Newton-Raphson with 8 iterations + post-convergence clamp
    ///      to guarantee integral(supply, supply+output) <= ethInput.
    ///      This ensures sell output is always < original buy input (no round-trip arb).
    function computeBuyOutput(uint256 ethInput, uint256 currentSupply, CurveConfig memory cc)
        internal
        pure
        returns (uint256)
    {
        if (ethInput == 0) return 0;
        if (currentSupply >= MAX_SUPPLY) return 0;

        // Cap ethInput to prevent overflow in Newton's method internal calculations.
        // Total ETH supply is ~120M. Cap at 150M with 1e18 precision.
        if (ethInput > 150_000_000e18) {
            ethInput = 150_000_000e18;
        }

        uint256 currentPrice = marginalPrice(currentSupply, cc);
        if (currentPrice == 0) return 0;

        // Initial guess: linear approximation
        uint256 deltaS = FPML.divWad(ethInput, currentPrice);
        if (deltaS == 0) return 0;

        // Cap deltaS to prevent overflow past MAX_SUPPLY
        uint256 remainingSupply = MAX_SUPPLY - currentSupply;
        if (deltaS > remainingSupply) deltaS = remainingSupply;

        // Newton-Raphson: 8 iterations for <0.01% convergence
        for (uint256 i = 0; i < 8; i++) {
            uint256 newSupply = currentSupply + deltaS;
            uint256 integral = curveIntegral(currentSupply, newSupply, cc);

            if (integral == ethInput) break;

            uint256 priceAtEnd = marginalPrice(newSupply, cc);
            if (priceAtEnd == 0) break;

            if (integral > ethInput) {
                // Overshot: reduce deltaS
                uint256 overshoot = integral - ethInput;
                uint256 adj = FPML.divWad(overshoot, priceAtEnd);
                deltaS = adj >= deltaS ? deltaS / 2 : deltaS - adj;
            } else {
                // Undershot: increase deltaS
                uint256 undershoot = ethInput - integral;
                uint256 adj = FPML.divWad(undershoot, priceAtEnd);
                // Guard against runaway
                if (adj > deltaS) {
                    adj = deltaS / 2;
                }
                deltaS += adj;
            }
        }

        // ── Post-convergence clamp: ensure integral <= ethInput ──
        // This eliminates the 0.1% Newton imprecision that allowed
        // sell output to exceed buy input in round-trip tests.
        // Do up to 3 correction passes, then final 1-wei haircut.
        for (uint256 i = 0; i < 3; i++) {
            uint256 integral = curveIntegral(currentSupply, currentSupply + deltaS, cc);
            if (integral <= ethInput) break;
            if (deltaS <= 1) break;

            uint256 overshoot = integral - ethInput;
            uint256 priceAtEnd = marginalPrice(currentSupply + deltaS, cc);
            if (priceAtEnd == 0) break;
            uint256 adj = FPML.divWad(overshoot, priceAtEnd);
            if (adj == 0) adj = 1; // at least 1 wei reduction
            deltaS = adj >= deltaS ? deltaS - 1 : deltaS - adj;
        }

        // Final shave loop (NK24): the fixed 8-round Newton + 3-pass clamp can
        // stall when the linear initial guess lands deep inside a steep
        // exponential zone — `adj = overshoot / priceAtEnd` quantizes to ~0 wei
        // because the far-end price is orders of magnitude above the average.
        // Deterministic repro minted 164x the owed amount. Bounded loop so gas
        // is capped; each pass removes `max(1, overshoot / price)` tokens, which
        // is a lower bound on the reduction needed, so deltaS decreases
        // monotonically toward integral <= ethInput.
        // NK24-MZ fix: the reduction MUST be computed with divWad — raw
        // integer division is 1e18x undersized, so on max-steepness shapes
        // (k*width up to the 7 WAD validate() cap) where Newton exits
        // non-converged, 32 passes of ~dust removal could not close the gap
        // and the loop returned an over-minting deltaS (39% repro: S=3442,
        // input=1e19 -> spent=1.39e19; round trip 1.8bps profitable). divWad
        // gives each pass full Newton-step bite; overshooting removal only
        // lands conservative (under-mint), which breaks the loop immediately.
        for (uint256 i = 0; i < 32; i++) {
            uint256 spent = curveIntegral(currentSupply, currentSupply + deltaS, cc);
            if (spent <= ethInput) break;
            if (deltaS <= 1) {
                deltaS = deltaS == 1 ? 0 : deltaS;
                break;
            }
            uint256 price = marginalPrice(currentSupply + deltaS, cc);
            if (price == 0) break; // unreachable (P0 > 0 enforced); avoids panic
            uint256 adj = FPML.divWad(spent - ethInput, price); // eth-space overshoot -> token-space reduction
            if (adj == 0) adj = 1;
            deltaS = adj >= deltaS ? deltaS / 2 : deltaS - adj;
        }
        if (deltaS == 0) return 0;

        // Final 1-wei haircut: conservative rounding in favor of protocol
        if (deltaS > 1) deltaS -= 1;

        // Safety net: 1 bps conservative haircut guarantees round-trip invariant.
        // At extreme supply values, curveIntegral() has fixed-point precision
        // granularity that can cause integral(supply) > ethInput by a few hundred
        // wei. The post-convergence clamp can't fix this because reducing deltaS
        // by 1-2 wei doesn't change the integral at that scale. A 1 bps haircut
        // reduces the integral by >> precision granularity, ensuring sell < buy.
        deltaS = deltaS * 9999 / 10000;

        // Hard cap: never exceed MAX_SUPPLY
        if (deltaS > MAX_SUPPLY - currentSupply) {
            deltaS = MAX_SUPPLY - currentSupply;
        }

        return deltaS;
    }

    // ═══════════════════════════════════════════════════════════════
    //  Sell Output: ∫_{S-ΔS}^{S} P(s) ds
    // ═══════════════════════════════════════════════════════════════

    /// @notice Compute ETH output for PSP input (before fee)
    function computeSellOutput(uint256 pspInput, uint256 currentSupply, CurveConfig memory cc)
        internal
        pure
        returns (uint256)
    {
        if (pspInput == 0 || pspInput >= currentSupply) return 0;
        if (currentSupply > MAX_SUPPLY) currentSupply = MAX_SUPPLY;
        uint256 newSupply = currentSupply - pspInput;
        return curveIntegral(newSupply, currentSupply, cc);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Integration (multi-zone aware)
    // ═══════════════════════════════════════════════════════════════

    /// @notice ∫ P(s) ds from S1 to S2, splitting at zone boundaries
    function curveIntegral(uint256 S1, uint256 S2, CurveConfig memory cc)
        internal
        pure
        returns (uint256 total)
    {
        if (S1 >= S2) return 0;

        uint256 price = cc.P0;
        for (uint256 i = 0; i < cc.zones.length; i++) {
            Zone memory z = cc.zones[i];

            // Skip zones entirely before S1
            if (z.endSupply <= S1) {
                // Advance price to zone end for next zone's starting price
                uint256 zoneEnd = z.endSupply;
                if (z.isExponential) {
                    price = _expPrice(price, z.rate, zoneEnd - z.startSupply);
                } else {
                    price = _logPrice(price, z.rate, zoneEnd, z.startSupply);
                }
                continue;
            }

            // Skip zones entirely after S2
            if (z.startSupply >= S2) break;

            // This zone overlaps [S1, S2]. Compute the overlap.
            uint256 segStart = S1 > z.startSupply ? S1 : z.startSupply;
            uint256 segEnd = S2 < z.endSupply ? S2 : z.endSupply;

            // Price at segStart within this zone
            uint256 pAtSegStart;
            if (z.isExponential) {
                pAtSegStart = _expPrice(price, z.rate, segStart - z.startSupply);
            } else {
                pAtSegStart = _logPrice(price, z.rate, segStart, z.startSupply);
            }

            // Integrate within this zone
            // For exp: pass pAtSegStart (formula: (pStart/k)*(e^(k*delta)-1))
            // For log: pass pZoneStart (= price var) directly for accuracy
            if (z.isExponential) {
                total += _integralExp(pAtSegStart, z.rate, segStart, segEnd);
            } else {
                total += _integralLog(price, z.rate, segStart, segEnd, z.startSupply);
            }

            // Advance price for next zone (only if more zones needed)
            if (S2 <= z.endSupply) break; // No more zones after this
            if (z.isExponential) {
                price = _expPrice(price, z.rate, z.endSupply - z.startSupply);
            } else {
                price = _logPrice(price, z.rate, z.endSupply, z.startSupply);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Zone Integrals
    // ═══════════════════════════════════════════════════════════════

    /// @dev ∫ pStart * e^(k*(s - s_start)) ds from segStart to segEnd
    ///    = (pStart / k) * (e^(k*(segEnd - s_start)) - e^(k*(segStart - s_start)))
    /// But pStart is already the price at segStart, so:
    ///    = (pStart / k) * (e^(k*(segEnd - segStart)) - 1)
    function _integralExp(uint256 pStart, uint256 k, uint256 segStart, uint256 segEnd)
        internal
        pure
        returns (uint256)
    {
        uint256 delta = segEnd - segStart;
        if (delta == 0) return 0;

        if (k == 0) {
            // Flat price: pStart * delta
            return FPML.mulWad(pStart, delta);
        }

        // e^(k * delta) - 1
        uint256 expInput = FPML.mulWad(k, delta);
        if (expInput > 135305999368893231588) {
            expInput = 135305999368893231588;
        }
        int256 ePow = FPML.expWad(int256(expInput));
        // ePow - WAD (since expWad returns 1e18 for e^0)
        // ePow is always >= WAD for positive exponent
        uint256 ePowMinus1 = uint256(ePow) - WAD;

        // (pStart / k) * (e^(k*delta) - 1)
        uint256 pStartOverK = FPML.divWad(pStart, k);
        return FPML.mulWad(pStartOverK, ePowMinus1);
    }

    /// @dev ∫ pZoneStart * (1 + k * ln(s / sZoneStart)) ds from segStart to segEnd
    /// Anti-derivative: F(s) = s*(1-k) + k*s*ln(s/sZoneStart)
    /// Integral = pZoneStart * (F(segEnd) - F(segStart)) / WAD
    function _integralLog(
        uint256 pZoneStart,
        uint256 k,
        uint256 segStart,
        uint256 segEnd,
        uint256 sZoneStart
    ) internal pure returns (uint256) {
        uint256 delta = segEnd - segStart;
        if (delta == 0) return 0;

        // ln values (both >= 0 since s >= sZoneStart in the zone)
        int256 lnEnd = int256(FPML.lnWad(int256(FPML.divWad(segEnd, sZoneStart))));
        int256 lnStart = int256(FPML.lnWad(int256(FPML.divWad(segStart, sZoneStart))));

        // F(s) = s*(1-k) + k*s*ln(s/S0), computed in WAD arithmetic
        // Term1: s * (WAD - k) / WAD
        // Term2: k * s * ln / WAD^2 (mulWad(k,s) gives k*s/WAD, then *ln/WAD)
        int256 F_end = int256(FPML.mulWad(segEnd, WAD - k))
            + int256(FPML.mulWad(FPML.mulWad(k, segEnd), uint256(lnEnd)));
        int256 F_start = int256(FPML.mulWad(segStart, WAD - k))
            + int256(FPML.mulWad(FPML.mulWad(k, segStart), uint256(lnStart)));

        if (F_end <= F_start) return 0;
        uint256 diff = uint256(F_end - F_start);

        return FPML.mulWad(pZoneStart, diff);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Helpers for building curve configs
    // ═══════════════════════════════════════════════════════════════

    /// @notice Build a simple single S-curve (exponential → logarithmic)
    function singleCurve(
        uint256 P0,
        uint256 S_inf,
        uint256 k1,
        uint256 k2
    ) internal pure returns (CurveConfig memory) {
        Zone[] memory zones = new Zone[](2);
        zones[0] = Zone({
            startSupply: 0,
            endSupply: S_inf,
            rate: k1,
            isExponential: true
        });
        zones[1] = Zone({
            startSupply: S_inf,
            endSupply: type(uint256).max,
            rate: k2,
            isExponential: false
        });
        return CurveConfig({P0: P0, zones: zones});
    }

    /// @notice Build a multi-oscillation curve with alternating exp/log zones
    /// @param boundaries Supply levels where zones transition. boundaries[0]=0.
    /// @param rates Growth rate for each zone (length = boundaries.length - 1... or boundaries.length with last zone to infinity)
    /// @param expFlags true=exponential, false=logarithmic for each zone
    function multiCurve(
        uint256 P0,
        uint256[] memory boundaries,
        uint256[] memory rates,
        bool[] memory expFlags
    ) internal pure returns (CurveConfig memory) {
        require(boundaries.length >= 2, "Need at least 2 boundaries");
        require(rates.length == boundaries.length, "Rate/zone count mismatch");
        require(expFlags.length == boundaries.length, "Flag/zone count mismatch");
        require(boundaries[0] == 0, "First boundary must be 0");

        Zone[] memory zones = new Zone[](boundaries.length);
        for (uint256 i = 0; i < boundaries.length; i++) {
            zones[i] = Zone({
                startSupply: boundaries[i],
                endSupply: i + 1 < boundaries.length ? boundaries[i + 1] : type(uint256).max,
                rate: rates[i],
                isExponential: expFlags[i]
            });
        }
        return CurveConfig({P0: P0, zones: zones});
    }

    /// @notice Validate a CurveConfig before deployment (M-3).
    /// @dev Raw structs passed as calldata can express gaps, overlaps, and
    ///      out-of-range rates that multiCurve() can never produce. Failure
    ///      modes include: underflow panic bricking every swap (non-monotonic
    ///      boundaries), zero integrals across gap zones minting ~the entire
    ///      remaining supply for dust input, and `WAD - k` underflow in
    ///      _integralLog for log zones with k > 1e18.
    function validate(CurveConfig memory cc) internal pure {
        uint256 n = cc.zones.length;
        require(n >= 1, "CurveMath: empty zones");
        require(n <= 50, "CurveMath: too many zones");
        require(cc.P0 > 0, "CurveMath: P0 must be > 0");

        Zone memory z = cc.zones[0];
        require(z.startSupply == 0, "CurveMath: first zone must start at 0");
        // NK24: a logarithmic zone starting at supply 0 divides by zero inside
        // _integralLog / _logPrice (`divWad(segEnd, s0)` with s0 == 0) — every
        // swap on such a curve panics 0x11. Reject log-first layouts outright.
        require(z.isExponential, "CurveMath: first zone must be exponential");

        for (uint256 i = 0; i < n; i++) {
            z = cc.zones[i];
            // Contiguity: this zone starts exactly where the previous ended
            // (checked against zones[i-1].endSupply below for i > 0).
            require(z.endSupply > z.startSupply, "CurveMath: non-increasing zone");
            if (!z.isExponential) {
                // _integralLog computes WAD - k; k > 1e18 underflows
                require(z.rate <= 1e18, "CurveMath: log rate > 1e18");
                // k == 1e18 makes the price term (1 - k) hit exactly zero;
                // permitted but noted — integral stays well-defined
            } else {
                // expWad overflow guard: k*delta must stay in int128 range;
                // k <= 100e18 with delta <= 1e28 keeps exponents sane
                require(z.rate <= 100e18, "CurveMath: exp rate too large");
                // NK24 Newton-stall guard: computeBuyOutput's linear initial
                // guess degrades when the price spans many multiples across
                // a zone. The bounded shave loop in computeBuyOutput now
                // guarantees conservative convergence for any shape, so this
                // cap is defense-in-depth keeping the guess meaningful and
                // gas bounded — NOT the primary correctness mechanism.
                // k*width (WAD) = ln(price ratio across the zone); 7 WAD
                // allows each oscillation to span up to ~1100x. Production
                // single-curve config sits at k*width ~= 0.0046 WAD.
                // Division form avoids the mulWad overflow the raw product
                // would hit on adversarial widths. An unbounded exponential
                // tail (last zone) has width ~2^256, so any k > 0 is rejected
                // there — only a flat (k == 0) tail is valid, which is the
                // intended shape anyway.
                uint256 width = z.endSupply - z.startSupply;
                require(z.rate <= MAX_EXP_K_WIDTH / width, "CurveMath: exp zone too steep (k*width)");
            }
            if (i > 0) {
                require(
                    z.startSupply == cc.zones[i - 1].endSupply,
                    "CurveMath: zone gap/overlap"
                );
            }
        }
        // Last zone must extend to infinity so every supply value is covered
        require(cc.zones[n - 1].endSupply == type(uint256).max, "CurveMath: last zone must be unbounded");
    }

    /// @dev Bound on the k*width product for exponential zones (7 WAD =
    ///      ln(~1100x) price span per zone). Stored pre-multiplied by WAD so
    ///      validate() can divide instead of multiplying (no overflow on
    ///      huge widths).
    uint256 internal constant MAX_EXP_K_WIDTH = 7e18 * 1e18; // = 7e36
}
