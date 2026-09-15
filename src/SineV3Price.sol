// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib as FPML} from "solady/src/utils/FixedPointMathLib.sol";

/// @title Monotone fixed-point price for the single tilted-sine curve
/// @notice Every rounded stage preserves order: signed phase, integer cube
///         root, positive exponent scaling, and a positive Taylor exponential.
///         The curve has no wave-count cutoff. Callers must reject states whose
///         price, density, supply, or signed settlement amounts cannot be stored.
library SineV3Price {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant CONTROL_SCALE = 1e27;
    uint256 internal constant EXP_SCALE = 1e36;
    uint256 internal constant K_WAD = 5643682713637197225;
    int256 internal constant LN2_WAD = 693147180559945309;
    // cbrt((1 + |s|) * 1e36) must fit uint256. The extra wave also
    // bounds the periodic displacement, which is strictly less than one.
    uint256 internal constant MAX_PHASE_MAGNITUDE = type(uint256).max / 1e36 - 2e18;

    error SineV3PriceDomain();
    error SineV3PriceOverflow();

    /// @notice s(x) = x - sin(2*pi*x)/(2*pi), with x and result in WAD.
    /// @dev Two monotone Bernstein polynomials cover the first half wave.
    ///      Their integer controls are ordered; both share the same quarter
    ///      endpoint. Reflection covers the second half and negative x.
    ///      Floor de Casteljau interpolation is monotone in either endpoint
    ///      and its fraction. Induction proves both output order and ordered
    ///      intermediate controls, including at adjacent integer coordinates.
    ///      The sine/cosine Taylor remainder and endpoint adjustment bound
    ///      the phase error below 1.5e-14 waves. See the generator proof.
    function phaseAt(int256 x) internal pure returns (int256) {
        if (x == type(int256).min) revert SineV3PriceDomain();
        uint256 a = uint256(x < 0 ? -x : x);
        if (a > MAX_PHASE_MAGNITUDE) revert SineV3PriceDomain();
        uint256 whole = a / WAD;
        uint256 fraction = a % WAD;
        bool reflected = fraction > WAD / 2;
        if (reflected) fraction = WAD - fraction;
        uint256 v = fraction <= WAD / 4 ? _firstQuarter(4 * fraction) : _secondQuarter(4 * fraction - WAD);
        if (reflected) v = CONTROL_SCALE - v;
        uint256 value = whole * WAD + v / (CONTROL_SCALE / WAD);
        return x < 0 ? -int256(value) : int256(value);
    }

    /// @notice K * sign(s) * (cbrt(1 + abs(s)) - 1), in WAD.
    /// @dev FPML.cbrt is an exact floored integer cube root. Subtracting the
    ///      integer WAD constant preserves monotonicity and costs less than
    ///      1e-18 of real root precision. In contrast, a quotient involving
    ///      a separately rounded root need not preserve order.
    function exponentAt(int256 x) internal pure returns (int256) {
        return exponentAtPhase(phaseAt(x));
    }

    /// @notice Log-price exponent from an already evaluated primitive s(x).
    /// @dev Fixed canonical quadrature nodes can store independently checked
    ///      phase offsets and skip the periodic polynomial evaluation.
    function exponentAtPhase(int256 s) internal pure returns (int256) {
        if (s == type(int256).min) revert SineV3PriceDomain();
        uint256 magnitude = uint256(s < 0 ? -s : s);
        if (magnitude > type(uint256).max / 1e36 - WAD) revert SineV3PriceDomain();
        uint256 c = FPML.cbrt((WAD + magnitude) * 1e36);
        uint256 h = c - WAD;
        uint256 exponent = FPML.fullMulDiv(K_WAD, h, WAD);
        return s < 0 ? -int256(exponent) : int256(exponent);
    }

    /// @notice floor(scale * exp(exponent)), using a monotone approximation.
    /// @dev Supports scale <= uint256.max/2. A zero result means the chosen
    ///      scale cannot represent a positive value; callers must reject that
    ///      state if a positive price or density is required.
    ///      k=floor(exponent/ln(2)); r is in [0, ln(2)). A degree-20 positive
    ///      Taylor polynomial computes exp(r) at 1e36 precision. Every Horner
    ///      operation is monotone. At a binary boundary its left value is
    ///      below 2 and its right value is exactly 1 * 2, so it cannot fall.
    ///      ln(2) rounds down by <1e-18. For representable prices the range
    ///      reduction error remains far below the 1e-11 relative-price goal.
    ///      Positive k shifts scale before final division, retaining custom
    ///      launch-price precision. Negative k uses two exact floor divisions.
    function scaledExp(int256 exponent, uint256 scale) internal pure returns (uint256) {
        if (scale > type(uint256).max / 2) revert SineV3PriceDomain();
        int256 k = exponent / LN2_WAD;
        int256 remainder = exponent % LN2_WAD;
        if (remainder < 0) {
            --k;
            remainder += LN2_WAD;
        }
        uint256 normalized = _expReduced(uint256(remainder));
        if (k >= 0) {
            uint256 shift = uint256(k);
            if (shift > 255 || scale > type(uint256).max >> shift) revert SineV3PriceOverflow();
            return FPML.fullMulDiv(scale << shift, normalized, EXP_SCALE);
        }
        uint256 rightShift = uint256(-k);
        if (rightShift > 255) return 0;
        return FPML.fullMulDiv(scale, normalized, EXP_SCALE) >> rightShift;
    }

    /// @notice Marginal mixETH/PSP price at dimensionless WAD coordinate x.
    function priceAtX(int256 x, uint256 pL) internal pure returns (uint256) {
        return scaledExp(exponentAt(x), pL);
    }

    /// @notice Reciprocal price multiple exp(-K*H(s(x))) at a chosen scale.
    function densityAtX(int256 x, uint256 scale) internal pure returns (uint256) {
        return scaledExp(-exponentAt(x), scale);
    }

    /// @notice Reciprocal price multiple from a canonical primitive value.
    function densityAtPhase(int256 s, uint256 scale) internal pure returns (uint256) {
        return scaledExp(-exponentAtPhase(s), scale);
    }

    function _firstQuarter(uint256 t) private pure returns (uint256) {
        uint256[19] memory b = [
            uint256(0),
            0,
            0,
            151188792908844341587538,
            604755171635377366350152,
            1509838240110574572843411,
            3011477724309673773558945,
            5248602596947330567578391,
            8352096329518822444599188,
            12442976034969226106338304,
            17630720663490293131960428,
            24011780309052452696374896,
            31668294667838982216475365,
            40667043896797455959054193,
            51058649720958279258897657,
            62877038826114528816035019,
            76139174555164297767650985,
            90845056908104664231116236,
            0
        ];
        return _deCasteljau(b, 18, t);
    }

    function _secondQuarter(uint256 t) private pure returns (uint256) {
        uint256[19] memory b = [
            uint256(90845056908104664231116236),
            104733945796993553120005125,
            119906165018231213756632022,
            136361714571817646140996927,
            154087400746610974328376478,
            173056836120327446429323955,
            193230618428647962852157243,
            214556688303431132787934783,
            236970862536534144903708516,
            260397536182244024175631936,
            284750543559487048378925513,
            309934165146477130576396330,
            335844264562909974233395223,
            362369537387756352762167688,
            389392851531918370888632614,
            416792657327424034340027812,
            444444444444444454983342156,
            472222222222222162074663631,
            500000000000000000000000000
        ];
        return _deCasteljau(b, 19, t);
    }

    function _deCasteljau(uint256[19] memory b, uint256 length, uint256 t) private pure returns (uint256) {
        unchecked {
            // The controls stay ordered. Each product is below 1e45, so
            // neither multiplication nor addition approaches uint256 bounds.
            for (uint256 n = length - 1; n > 0; --n) {
                for (uint256 i; i < n; ++i) {
                    b[i] += (b[i + 1] - b[i]) * t / WAD;
                }
            }
        }
        return b[0];
    }

    function _expReduced(uint256 r) private pure returns (uint256 value) {
        // floor(1e36 / n!), n=20 down to 0. Every coefficient is positive;
        // r < ln(2)*1e18 and intermediates stay below 2e36.
        unchecked {
            value = 411031762331216485;
            value = 8220635246624329716 + value * r / WAD;
            value = 156192069685862264622 + value * r / WAD;
            value = 2811457254345520763198 + value * r / WAD;
            value = 47794773323873852974382 + value * r / WAD;
            value = 764716373181981647590113 + value * r / WAD;
            value = 11470745597729724713851697 + value * r / WAD;
            value = 160590438368216145993923771 + value * r / WAD;
            value = 2087675698786809897921009032 + value * r / WAD;
            value = 25052108385441718775052108385 + value * r / WAD;
            value = 275573192239858906525573192239 + value * r / WAD;
            value = 2755731922398589065255731922398 + value * r / WAD;
            value = 24801587301587301587301587301587 + value * r / WAD;
            value = 198412698412698412698412698412698 + value * r / WAD;
            value = 1388888888888888888888888888888888 + value * r / WAD;
            value = 8333333333333333333333333333333333 + value * r / WAD;
            value = 41666666666666666666666666666666666 + value * r / WAD;
            value = 166666666666666666666666666666666666 + value * r / WAD;
            value = 500000000000000000000000000000000000 + value * r / WAD;
            value = 1000000000000000000000000000000000000 + value * r / WAD;
            value = 1000000000000000000000000000000000000 + value * r / WAD;
        }
    }
}
