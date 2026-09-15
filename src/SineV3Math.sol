// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib as FPML} from "solady/src/utils/FixedPointMathLib.sol";
import {SineV3Price} from "./SineV3Price.sol";
import {SineV3Primitive} from "./SineV3Primitive.sol";

/// @title Single tilted-sine settlement with softened cube-root growth
/// @notice One price formula applies before and after launch:
/// x=(R-boot)/lambda; s=x-sin(2*pi*x)/(2*pi);
/// P=P_L*exp(K*sign(s)*(cbrt(1+abs(s))-1)). K calibrates wave ten to
/// 1,000 times launch price. Supply integrates its reciprocal from reserve
/// zero. The cumulative primitive uses immutable, authenticated data and
/// ordered interpolation; its integer output cannot decrease with reserve.
/// No owner, write method, delegatecall, or replaceable data address exists.
contract SineV3Math is SineV3Primitive {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant B_REF = 450e18;
    uint256 internal constant LAM_REF = 955e18;
    uint256 public constant POST_WAVES = 4096;
    // The opening price must be at least one price wei. With P_L <= 1e18,
    // that implies boot < 681,937,422 mixETH. This loose preliminary bound
    // makes every subsequent product safe; the actual price decides capacity.
    uint256 internal constant BOOT_ARITHMETIC_BOUND = 682_000_000e18;

    error SineV3Domain();

    /// @notice Pin the four canonical, STOP-prefixed data shards permanently.
    constructor(address[4] memory shards) SineV3Primitive(shards) {}

    /// @notice Square-root wavelength, exactly 955 mixETH at 450 net backing.
    function lamAt(uint256 bootWei) public pure returns (uint256) {
        if (bootWei > BOOT_ARITHMETIC_BOUND) revert SineV3Domain();
        return FPML.sqrt(FPML.fullMulDiv(LAM_REF * LAM_REF, bootWei, B_REF));
    }

    /// @notice The tenth-wave reserve target: boot + 10*lambda.
    function targetAt(uint256 bootWei, uint256 lamWei) public pure returns (uint256) {
        return bootWei + 10 * lamWei;
    }

    /// @notice Last reserve endpoint before the remaining integral is below
    /// one mintable PSP wei for every admitted launch and custom launch price.
    function maxReserve(uint256 boot, uint256 lam, uint256 pL) external pure returns (uint256) {
        _checkDomain(boot, boot, lam, pL);
        return boot + POST_WAVES * lam;
    }

    /// @notice Marginal price, in mixETH wei per whole PSP.
    function priceWad(uint256 R, uint256 boot, uint256 lam, uint256 pL) public pure returns (uint256) {
        _checkDomain(R, boot, lam, pL);
        return _price(R, boot, lam, pL);
    }

    /// @notice Cumulative PSP wei from reserve zero through R. Coordinates
    /// retain the exact reserve fraction; no WAD phase truncation precedes
    /// integration, including one-wei moves at very large launch backing.
    function supplyWad(uint256 R, uint256 boot, uint256 lam, uint256 pL) public view returns (uint256) {
        _checkDomain(R, boot, lam, pL);
        if (R == 0) return 0;
        return _supply(_fAtReserve(R, boot, lam), _fAtReserve(0, boot, lam), lam, pL);
    }

    /// @notice Genesis supply uses the same primitive as all later trades.
    function genesisQ(uint256 boot, uint256 lam, uint256 pL) external view returns (uint256) {
        return supplyWad(boot, boot, lam, pL);
    }

    /// @notice PSP out for net curve spend; capped by the starting spot,
    /// reduced by one PSP wei, then by the existing one-basis-point haircut.
    function buyOut(uint256 R, uint256 boot, uint256 lam, uint256 pL, uint256 spend)
        external view returns (uint256)
    {
        _checkDomain(R, boot, lam, pL);
        // Check before addition as well as before any caller state change.
        if (spend > boot + POST_WAVES * lam - R) revert SineV3Domain();
        int256 f0 = _fAtReserve(0, boot, lam);
        uint256 beforeSupply = _supply(_fAtReserve(R, boot, lam), f0, lam, pL);
        uint256 afterSupply = _supply(_fAtReserve(R + spend, boot, lam), f0, lam, pL);
        if (afterSupply <= beforeSupply) return 0;
        uint256 out = afterSupply - beforeSupply;
        uint256 spotBound = FPML.fullMulDiv(spend, WAD, _price(R, boot, lam, pL));
        if (out > spotBound) out = spotBound;
        if (out <= 1) return 0;
        return FPML.fullMulDiv(out - 1, 9999, 10000);
    }

    /// @notice Gross mixETH out for a PSP burn. The inverse returns the
    /// smallest reserve endpoint whose rounded supply reaches the target.
    /// Its final bracket is checked; no unresolved estimate can be settled.
    function sellOut(uint256 R, uint256 boot, uint256 lam, uint256 pL, uint256 pspIn)
        external view returns (uint256)
    {
        _checkDomain(R, boot, lam, pL);
        int256 f0 = _fAtReserve(0, boot, lam);
        uint256 qNow = _supply(_fAtReserve(R, boot, lam), f0, lam, pL);
        if (pspIn >= qNow) return R;
        uint256 next = _reserveAtPrimitive(R, boot, lam, pL, qNow - pspIn, f0);
        if (next > R) revert SineV3InverseDidNotConverge();
        uint256 out = R - next;
        uint256 p = _price(R, boot, lam, pL);
        // A floored price is not an upper bound: near one price wei it can
        // cut a valid payout almost in half. The proven approximation error
        // is below 4e-14 relative; this 1e-11 envelope plus two price units
        // also covers final flooring. The monotone inverse remains binding.
        uint256 upperPrice = p + p / 100_000_000_000 + 2;
        uint256 spotBound = FPML.fullMulDiv(pspIn, upperPrice, WAD);
        return out < spotBound ? out : spotBound;
    }

    function _supply(int256 fR, int256 f0, uint256 lam, uint256 pL) private pure returns (uint256) {
        if (fR < f0) revert SineV3Domain();
        // F has 36 decimal places; PSP and mixETH use 18.
        return FPML.fullMulDiv(lam, uint256(fR - f0), pL * WAD);
    }

    function _price(uint256 R, uint256 boot, uint256 lam, uint256 pL) private pure returns (uint256) {
        int256 x = R >= boot
            ? int256(FPML.fullMulDiv(R - boot, WAD, lam))
            : -int256(FPML.fullMulDiv(boot - R, WAD, lam));
        return SineV3Price.priceAtX(x, pL);
    }

    function _checkDomain(uint256 R, uint256 boot, uint256 lam, uint256 pL) private pure {
        if (boot == 0 || boot > BOOT_ARITHMETIC_BOUND || pL < 1e9 || pL > 1e18) revert SineV3Domain();
        if (lam != lamAt(boot) || 2 * boot > 1161 * lam || R > boot + POST_WAVES * lam) revert SineV3Domain();
        // Coverage reaches -580.5 waves. The opening price check gives the
        // actual, price-dependent launch limit and prevents division by zero.
        if (_price(0, boot, lam, pL) == 0) revert SineV3Domain();
    }
}
