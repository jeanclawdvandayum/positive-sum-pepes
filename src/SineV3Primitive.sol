// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib as FPML} from "solady/src/utils/FixedPointMathLib.sol";
import {SineV3Price} from "./SineV3Price.sol";
import {SineV3Bernstein} from "./SineV3Bernstein.sol";
import {SineV3DataInfo} from "./SineV3DataInfo.sol";

/// @title Immutable monotone cumulative integral for the single sine curve
/// @notice Canonical cell endpoints and positive Bernstein density controls
/// define one cumulative primitive. Integer de Casteljau interpolation of
/// ordered controls is nondecreasing, including at adjacent reserve wei.
abstract contract SineV3Primitive {
    uint256 private constant FRACTION_SCALE = 1e54;
    address private immutable _data0;
    address private immutable _data1;
    address private immutable _data2;
    address private immutable _data3;

    error SineV3DataMismatch();
    error SineV3PrimitiveDomain();
    error SineV3Coefficient();
    error SineV3InverseDidNotConverge();

    struct Cell {
        int256 left4;
        uint256 width4;
        int256 lower;
        uint256[18] controls;
    }

    constructor(address[4] memory shards) {
        if (_phase4(SineV3DataInfo.COUNT - 1) != 16384 || _phase4(SineV3DataInfo.ZERO_INDEX) != 0) {
            revert SineV3DataMismatch();
        }
        if (
            shards[0].codehash != SineV3DataInfo.HASH0 || shards[0].code.length != SineV3DataInfo.BYTES0
                || shards[1].codehash != SineV3DataInfo.HASH1 || shards[1].code.length != SineV3DataInfo.BYTES1
                || shards[2].codehash != SineV3DataInfo.HASH2 || shards[2].code.length != SineV3DataInfo.BYTES2
                || shards[3].codehash != SineV3DataInfo.HASH3 || shards[3].code.length != SineV3DataInfo.BYTES3
        ) {
            revert SineV3DataMismatch();
        }
        _data0 = shards[0];
        _data1 = shards[1];
        _data2 = shards[2];
        _data3 = shards[3];
    }

    /// @notice Number of immutable data contracts authenticated at construction.
    function dataShardCount() external pure returns (uint256) {
        return 4;
    }

    /// @notice Canonical data address, available for independent deployment checks.
    function dataShard(uint256 i) public view returns (address) {
        if (i == 0) return _data0;
        if (i == 1) return _data1;
        if (i == 2) return _data2;
        if (i == 3) return _data3;
        revert SineV3PrimitiveDomain();
    }

    function _knot(uint256 i) internal view returns (int256) {
        if (i >= SineV3DataInfo.COUNT) revert SineV3PrimitiveDomain();
        bool negative = i < SineV3DataInfo.ZERO_INDEX;
        uint256 width = negative ? 24 : 16;
        uint256 offset = negative ? i * 24 : SineV3DataInfo.NEGATIVE_BYTES + (i - SineV3DataInfo.ZERO_INDEX) * 16;
        address shard;
        if (offset < SineV3DataInfo.START1) {
            shard = _data0;
        } else if (offset < SineV3DataInfo.START2) {
            shard = _data1;
            offset -= SineV3DataInfo.START1;
        } else if (offset < SineV3DataInfo.START3) {
            shard = _data2;
            offset -= SineV3DataInfo.START2;
        } else {
            shard = _data3;
            offset -= SineV3DataInfo.START3;
        }
        uint256 value;
        assembly ("memory-safe") {
            let p := mload(0x40)
            extcodecopy(shard, p, add(offset, 1), width)
            value := shr(sub(256, mul(width, 8)), mload(p))
        }
        return negative ? -int256(value) : int256(value);
    }

    function _phase4(uint256 i) internal pure returns (int256) {
        if (i >= SineV3DataInfo.COUNT) revert SineV3PrimitiveDomain();
        if (i == 0) return -2322;
        if (i <= SineV3DataInfo.FIRST_HALF_INDEX) return -2320 + int256(4 * (i - 1));
        if (i <= SineV3DataInfo.FIRST_QUARTER_INDEX) return -512 + int256(2 * (i - SineV3DataInfo.FIRST_HALF_INDEX));
        if (i <= SineV3DataInfo.LAST_QUARTER_INDEX) return -4 + int256(i - SineV3DataInfo.FIRST_QUARTER_INDEX);
        if (i <= SineV3DataInfo.LAST_HALF_INDEX) return 4 + int256(2 * (i - SineV3DataInfo.LAST_QUARTER_INDEX));
        return 512 + int256(4 * (i - SineV3DataInfo.LAST_HALF_INDEX));
    }

    function _cellIndex(uint256 R, uint256 boot, uint256 lam) private pure returns (uint256) {
        if (lam == 0) revert SineV3PrimitiveDomain();
        // The settlement caller checks the tighter parameter domain first.
        // Keep these products bounded even when a test harness calls directly.
        if (R > type(uint256).max / 4 || boot > type(uint256).max / 4 || lam > type(uint256).max / 16384) {
            revert SineV3PrimitiveDomain();
        }
        if (4 * boot > 2322 * lam || R > boot + 4096 * lam) revert SineV3PrimitiveDomain();
        int256 z = R >= boot ? int256(4 * (R - boot) / lam) : -int256(FPML.divUp(4 * (boot - R), lam));
        if (z < -2320) return 0;
        if (z < -512) return 1 + uint256(z + 2320) / 4;
        if (z < -4) return SineV3DataInfo.FIRST_HALF_INDEX + uint256(z + 512) / 2;
        if (z < 4) return SineV3DataInfo.FIRST_QUARTER_INDEX + uint256(z + 4);
        if (z < 512) return SineV3DataInfo.LAST_QUARTER_INDEX + uint256(z - 4) / 2;
        return SineV3DataInfo.LAST_HALF_INDEX + uint256(z - 512) / 4;
    }

    function _prepare(uint256 i) internal view returns (Cell memory cell) {
        cell.left4 = _phase4(i);
        cell.width4 = uint256(_phase4(i + 1) - cell.left4);
        cell.lower = _knot(i);
        uint256 span = uint256(_knot(i + 1) - cell.lower);
        if (span == 0) return cell;
        bytes memory phases = SineV3Bernstein.phases();
        bytes memory matrix = SineV3Bernstein.matrix();
        // floor division, including half/quarter cells before phase zero.
        int256 base = cell.left4 >= 0 ? cell.left4 / 4 : -int256(FPML.divUp(uint256(-cell.left4), 4));
        uint256 fraction4 = uint256(cell.left4 - 4 * base);
        uint256 kind = cell.width4 == 4 ? 0 : (cell.width4 == 2 ? 1 + fraction4 / 2 : 3 + fraction4);
        uint256[17] memory samples;
        // Density normalization cancels this scale. The positive tail needs
        // extra precision; the negative side keeps signed matrix sums small.
        uint256 scale = cell.left4 < 0 ? 1e36 : 1e54;
        for (uint256 j; j < 17; ++j) {
            uint256 offset = (kind * 17 + j) * 8;
            uint256 phase;
            assembly ("memory-safe") { phase := shr(192, mload(add(add(phases, 32), offset))) }
            samples[j] = SineV3Price.densityAtPhase(base * 1e18 + int256(phase), scale);
        }
        uint256 total;
        for (uint256 row; row < 17; ++row) {
            int256 coefficient;
            for (uint256 col; col < 17; ++col) {
                uint256 offset = ((row <= 8 ? row : 16 - row) * 17 + col) * 16;
                int256 weight;
                assembly ("memory-safe") { weight := signextend(15, shr(128, mload(add(add(matrix, 32), offset)))) }
                uint256 sample = samples[row <= 8 ? col : 16 - col];
                uint256 magnitude = FPML.fullMulDiv(uint256(weight < 0 ? -weight : weight), sample, 1e27);
                coefficient += weight < 0 ? -int256(magnitude) : int256(magnitude);
            }
            if (coefficient <= 0) revert SineV3Coefficient();
            total += uint256(coefficient);
            cell.controls[row + 1] = total;
        }
        // One common normalization pins both endpoints exactly. Positive
        // coefficients imply ordered controls; floor preserves that order.
        for (uint256 j = 1; j < 17; ++j) {
            cell.controls[j] = FPML.fullMulDiv(span, cell.controls[j], total);
        }
        cell.controls[17] = span;
    }

    function _atReserve(Cell memory cell, uint256 R, uint256 boot, uint256 lam) internal pure returns (int256 value) {
        (value,) = _atReserveWithSlope(cell, R, boot, lam);
    }

    function _atReserveWithSlope(Cell memory cell, uint256 R, uint256 boot, uint256 lam)
        private
        pure
        returns (int256 value, uint256 gap)
    {
        uint256 numerator;
        if (cell.left4 >= 0) {
            if (R < boot) return (cell.lower, cell.controls[1]);
            uint256 start = uint256(cell.left4) * lam;
            uint256 position = 4 * (R - boot);
            if (position <= start) return (cell.lower, cell.controls[1]);
            numerator = position - start;
        } else {
            uint256 start = uint256(-cell.left4) * lam;
            if (R >= boot) {
                numerator = start + 4 * (R - boot);
            } else {
                uint256 position = 4 * (boot - R);
                if (position >= start) return (cell.lower, cell.controls[1]);
                numerator = start - position;
            }
        }
        uint256 denominator = cell.width4 * lam;
        if (numerator >= denominator) {
            return (cell.lower + int256(cell.controls[17]), cell.controls[17] - cell.controls[16]);
        }
        uint256 t = FPML.fullMulDiv(numerator, FRACTION_SCALE, denominator);
        // Copy the controls: inverse queries must not mutate their cached cell.
        uint256[18] memory values;
        for (uint256 j; j < 18; ++j) {
            values[j] = cell.controls[j];
        }
        for (uint256 count = 17; count > 1; --count) {
            for (uint256 j; j < count; ++j) {
                values[j] += FPML.fullMulDiv(values[j + 1] - values[j], t, FRACTION_SCALE);
            }
        }
        // The degree-one control gap approximates dF/dt divided by 17.
        // It only accelerates the bracket search; settlement never trusts it.
        gap = values[1] - values[0];
        value = cell.lower + int256(values[0] + FPML.fullMulDiv(gap, t, FRACTION_SCALE));
    }

    function _fAtReserve(uint256 R, uint256 boot, uint256 lam) internal view returns (int256) {
        uint256 i = _cellIndex(R, boot, lam);
        if (i == SineV3DataInfo.COUNT - 1) return _knot(i);
        return _atReserve(_prepare(i), R, boot, lam);
    }

    function _reserveAtPrimitive(uint256 maxR, uint256 boot, uint256 lam, uint256 pL, uint256 qTarget, int256 f0)
        internal
        view
        returns (uint256)
    {
        if (qTarget == 0) return 0;
        // floor(lam*(F-f0)/(pL*1e18)) >= qTarget iff F >= target.
        uint256 distance = FPML.fullMulDivUp(qTarget, pL * 1e18, lam);
        if (distance > uint256(type(int256).max)) revert SineV3InverseDidNotConverge();
        int256 target = f0 + int256(distance);
        uint256 lo;
        uint256 hi = SineV3DataInfo.COUNT - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_knot(mid) >= target) hi = mid;
            else lo = mid + 1;
        }
        if (hi == 0 || _knot(hi) < target) revert SineV3InverseDidNotConverge();
        Cell memory cell = _prepare(hi - 1);
        uint256 lower = _reserveFloor(cell.left4, boot, lam);
        uint256 upper = _reserveCeil(cell.left4 + int256(cell.width4), boot, lam);
        if (upper > maxR) upper = maxR;
        if (lower >= upper || _atReserve(cell, upper, boot, lam) < target) revert SineV3InverseDidNotConverge();
        // Up to 16 Newton evaluations use the cached polynomial derivative.
        // The remaining 112 steps are forced bisections. Factory-supported
        // cells are narrower than 2^81 reserve wei, so this always closes the
        // bracket even if every Newton candidate fails. Other harness inputs
        // fail closed if they exceed this proved factory reserve-width domain.
        uint256 candidate = upper;
        for (uint256 step; step < 128 && upper - lower > 1; ++step) {
            (int256 value, uint256 gap) = _atReserveWithSlope(cell, candidate, boot, lam);
            if (value >= target) upper = candidate;
            else lower = candidate;
            uint256 next = lower + (upper - lower) / 2;
            if (step + 1 < 16 && gap != 0 && upper - lower > 1) {
                // A zero-sized Newton move probes the adjacent reserve wei.
                // This closes an ordinary rounded root quickly; a wider
                // plateau still reaches the mandatory bisection phase.
                next = value >= target ? candidate - 1 : candidate + 1;
                uint256 distanceF = uint256(value >= target ? value - target : target - value);
                // dF/dR = 17*gap*4/(width4*lambda). Integer rounding can
                // perturb this slope, hence the strict bracket check below.
                uint256 delta = FPML.fullMulDiv(distanceF, cell.width4 * lam, 68 * gap);
                if (delta != 0) {
                    if (value > target && delta < candidate - lower) next = candidate - delta;
                    else if (value < target && delta < upper - candidate) next = candidate + delta;
                }
            }
            candidate = next;
        }
        if (
            upper - lower > 1 || _atReserve(cell, upper, boot, lam) < target
                || (upper != 0 && _atReserve(cell, upper - 1, boot, lam) >= target)
        ) {
            revert SineV3InverseDidNotConverge();
        }
        return upper;
    }

    function _reserveFloor(int256 x4, uint256 boot, uint256 lam) private pure returns (uint256) {
        if (x4 >= 0) return boot + uint256(x4) * lam / 4;
        uint256 back = FPML.divUp(uint256(-x4) * lam, 4);
        return back >= boot ? 0 : boot - back;
    }

    function _reserveCeil(int256 x4, uint256 boot, uint256 lam) private pure returns (uint256) {
        if (x4 >= 0) return boot + FPML.divUp(uint256(x4) * lam, 4);
        uint256 back = uint256(-x4) * lam / 4;
        return back >= boot ? 0 : boot - back;
    }
}
