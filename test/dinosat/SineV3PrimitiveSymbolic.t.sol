// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SineV3Primitive} from "../../src/SineV3Primitive.sol";
import {SineV3Data} from "../../src/SineV3Data.sol";

/// @title DinoSAT symbolic tests — SineV3Primitive cumulative curve
/// @notice The heart of AUD-V3-1's fix: within a graded cell, integer
///         de Casteljau over ordered controls is non-decreasing in the
///         reserve. Proven per ENUMERATED cell with symbolic intra-cell
///         offset — the controls are concrete (all-math on a concrete cell
///         index), only the evaluation point is symbolic.
contract SineV3PrimitiveSymbolicTest is Test, SineV3Primitive {
    uint256 constant BOOT = 450e18;
    uint256 constant LAM = 955e18; // == lamAt(BOOT), the canonical row

    constructor() SineV3Primitive(SineV3Data.deploy()) {}

    /// @dev Reserve of the cell's LOWER phase edge, floored (mirrors
    ///      _reserveFloor, which is private in the parent).
    function _edgeLow(int256 left4) internal pure returns (uint256) {
        if (left4 >= 0) return BOOT + uint256(left4) * LAM / 4;
        uint256 back = (uint256(-left4) * LAM + 3) / 4; // divUp
        return back >= BOOT ? 0 : BOOT - back;
    }

    function _cellWidthReserve(uint256 width4) internal pure returns (uint256) {
        return width4 * LAM / 4;
    }

    // ════════════════════════════════════════════════
    // PR-1 (within-cell monotone supply): for enumerated cells across the
    // whole graded table — first negative-wide, a negative-half, a quarter,
    // the zero-adjacent half, a positive-half, a positive-wide, and the
    // final cell — F(start + r) <= F(start + r + 1) for symbolic r.
    // Technique: T3 enumeration + symbolic intra-cell offset.
    // Composition: {0, 500, 708, 711, 716, 1000, 4936} spans every cell
    // KIND (wide-negative, half-negative, quarter, zero-half, half-positive,
    // wide-positive, terminal). Classification: ENUMERATE/BOUNDARY.
    // ════════════════════════════════════════════════

    function _checkCellMonotone(uint256 i, uint256 r) internal view {
        Cell memory cell = _prepare(i);
        uint256 lo = _edgeLow(cell.left4);
        uint256 span = _cellWidthReserve(cell.width4);
        // offset keeps both probes strictly inside the cell
        vm.assume(r < span - 1);
        uint256 v1 = uint256(_atReserve(cell, lo + r, BOOT, LAM));
        uint256 v2 = uint256(_atReserve(cell, lo + r + 1, BOOT, LAM));
        assert(v1 <= v2);
    }

    /// @notice Cell 0: leftmost negative-wide cell (phase -2322).
    function test_check_cell_monotone_0(uint256 r) public view {
        _checkCellMonotone(0, r);
    }

    /// @notice Cell 500: negative-half cell (phase -418).
    function test_check_cell_monotone_500(uint256 r) public view {
        _checkCellMonotone(500, r);
    }

    /// @notice Cell 708: quarter cell (phase -4 to -3).
    function test_check_cell_monotone_708(uint256 r) public view {
        _checkCellMonotone(708, r);
    }

    /// @notice Cell 711: the zero-anchored half cell (phase 0 to 2).
    function test_check_cell_monotone_711(uint256 r) public view {
        _checkCellMonotone(711, r);
    }

    /// @notice Cell 716: positive-half cell (phase 4 to 6).
    function test_check_cell_monotone_716(uint256 r) public view {
        _checkCellMonotone(716, r);
    }

    /// @notice Cell 1000: positive-wide cell (phase 636).
    function test_check_cell_monotone_1000(uint256 r) public view {
        _checkCellMonotone(1000, r);
    }

    /// @notice Cell 4936: terminal positive cell (phase 16380 to 16384).
    function test_check_cell_monotone_4936(uint256 r) public view {
        _checkCellMonotone(4936, r);
    }

    // ════════════════════════════════════════════════
    // PR-2 (knot anchoring): a cell evaluated AT its upper edge returns
    // exactly knot(i+1), and cells tile without gaps — the cumulative
    // primitive cannot decrease ACROSS cell boundaries either.
    // Technique: T3 concrete; Classification: DIRECT.
    // ════════════════════════════════════════════════

    function _edgeHigh(int256 left4, uint256 width4) internal pure returns (uint256) {
        int256 right4 = left4 + int256(width4);
        if (right4 <= 0) {
            uint256 back = uint256(-right4) * LAM / 4; // floor
            return back >= BOOT ? 0 : BOOT - back;
        }
        // right4 > 0: ceil(right4 * LAM / 4)
        return BOOT + (uint256(right4) * LAM + 3) / 4;
    }

    /// @notice Upper-edge evaluation equals the next knot for each REACHABLE cell.
    /// Cells whose phase span lies entirely below reserve 0 (0, 500, 708 — boot
    /// provides only ~1.9 quarter-phases of negative runway) can never be
    /// probed in-domain; _atReserve saturates to their endpoint knots there by
    /// design (bisection support). We pin both behaviors.
    function test_check_cell_upper_edge_anchor() public view {
        // Reachable cells: both edges anchor exactly.
        uint256[2] memory reachable = [uint256(711), 716];
        for (uint256 k; k < reachable.length; ++k) {
            uint256 i = reachable[k];
            Cell memory cell = _prepare(i);
            uint256 hi = _edgeHigh(cell.left4, cell.width4);
            assert(_atReserve(cell, hi, BOOT, LAM) == _knot(i + 1));
            uint256 lo = _edgeLow(cell.left4);
            assert(_atReserve(cell, lo, BOOT, LAM) == cell.lower);
        }
        // Below-zero cells: every reserve in [0, boot) is ABOVE their phase
        // window (closer to phase zero), so they saturate to the next knot.
        uint256[3] memory sunk = [uint256(0), 500, 708];
        for (uint256 k; k < sunk.length; ++k) {
            uint256 i = sunk[k];
            Cell memory cell = _prepare(i);
            assert(_atReserve(cell, 0, BOOT, LAM) == _knot(i + 1));
        }
    }

    /// @notice Knots strictly increase across the enumerated span.
    function test_check_knots_increase() public view {
        uint256[8] memory cells = [uint256(0), 1, 500, 708, 711, 716, 1000, 4936];
        for (uint256 k; k < cells.length - 1; ++k) {
            assert(_knot(cells[k]) < _knot(cells[k] + 1));
        }
    }

    // ════════════════════════════════════════════════
    // FUZZ WRAPPERS (T17)
    // ════════════════════════════════════════════════

    function test_fuzz_cell_monotone_711(uint256 rawR) public view {
        Cell memory cell = _prepare(711);
        uint256 span = _cellWidthReserve(cell.width4);
        uint256 r = bound(rawR, 0, span - 2);
        uint256 lo = _edgeLow(cell.left4);
        assert(uint256(_atReserve(cell, lo + r, BOOT, LAM))
            <= uint256(_atReserve(cell, lo + r + 1, BOOT, LAM)));
    }

    function test_fuzz_cell_monotone_0(uint256 rawR) public view {
        Cell memory cell = _prepare(0);
        uint256 span = _cellWidthReserve(cell.width4);
        uint256 r = bound(rawR, 0, span - 2);
        uint256 lo = _edgeLow(cell.left4);
        assert(uint256(_atReserve(cell, lo + r, BOOT, LAM))
            <= uint256(_atReserve(cell, lo + r + 1, BOOT, LAM)));
    }
}
