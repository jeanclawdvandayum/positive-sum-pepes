// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SineV3Primitive} from "../../src/SineV3Primitive.sol";
import {SineV3Data} from "../../src/SineV3Data.sol";

/// @title DinoSAT symbolic tests — SineV3Primitive cumulative curve
/// @notice The heart of AUD-V3-1's fix: within a graded cell, integer
///         de Casteljau over ordered controls is non-decreasing in the
///         reserve. Attempted per selected cell with symbolic intra-cell
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
    // selected graded cells — sunk negative cells, a reachable negative
    // quarter, a zero-adjacent quarter, positive half/wide cells, and the
    // final plateau — F(start + r) <= F(start + r + 1) for symbolic r.
    // Technique: T3 enumeration + symbolic intra-cell offset.
    // A selected-cell check does not establish all-cell monotonicity. Sunk
    // cells and the terminal plateau do not exercise nonconstant interpolation.
    // ════════════════════════════════════════════════

    function _checkCellMonotone(uint256 i, uint256 r) internal view {
        Cell memory cell = _prepare(i);
        uint256 lo = _edgeLow(cell.left4);
        uint256 span = _cellWidthReserve(cell.width4);
        // offset keeps both probes strictly inside the cell
        vm.assume(r < span - 1);
        int256 v1 = _atReserve(cell, lo + r, BOOT, LAM);
        int256 v2 = _atReserve(cell, lo + r + 1, BOOT, LAM);
        assert(v1 <= v2);
    }

    /// @notice Cell 0: sunk leftmost half cell (phase4 -2322 to -2320).
    function check_cell_monotone_0(uint256 r) public view {
        _checkCellMonotone(0, r);
    }

    /// @notice Cell 500: sunk negative-half cell (phase4 -418).
    function check_cell_monotone_500(uint256 r) public view {
        _checkCellMonotone(500, r);
    }

    /// @notice Cell 708: sunk quarter cell (phase4 -3 to -2).
    function check_cell_monotone_708(uint256 r) public view {
        _checkCellMonotone(708, r);
    }

    /// @notice Reachable negative quarter cell, from phase -0.25 to zero.
    function check_cell_monotone_710(uint256 r) public view {
        _checkCellMonotone(710, r);
    }

    /// @notice Cell 711: the zero-anchored quarter cell (phase4 0 to 1).
    function check_cell_monotone_711(uint256 r) public view {
        _checkCellMonotone(711, r);
    }

    /// @notice Cell 712: the second launch quarter cell (phase4 1 to 2) —
    /// the upper half of the canonical buyOut spend domain [boot, boot + lam/2).
    /// Added 2026-09-22: with 711 it covers both cells buyOut's launch-row
    /// properties read; per-cell EVM monotonicity here is the EVM pillar of
    /// the buyOut supply-monotone closure (the full-domain EVM proof stays
    /// blocked on halmos 0.3.3 symbolic EXTCODECOPY offsets).
    function check_cell_monotone_712(uint256 r) public view {
        _checkCellMonotone(712, r);
    }

    /// @notice Cell 716: positive-half cell (phase4 6 to 8).
    function check_cell_monotone_716(uint256 r) public view {
        _checkCellMonotone(716, r);
    }

    /// @notice Cell 1000: positive-wide cell (phase4 636).
    function check_cell_monotone_1000(uint256 r) public view {
        _checkCellMonotone(1000, r);
    }

    /// @notice Constant rounded terminal plateau, not an interpolation proof.
    function check_cell_terminal_plateau(uint256 r) public view {
        assert(_knot(4936) == _knot(4937));
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
        uint256[4] memory reachable = [uint256(710), 711, 712, 716];
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

    /// @notice Selected nonconstant cells have strictly increasing anchors.
    function test_check_selected_knots_strictly_increase() public view {
        uint256[9] memory cells = [uint256(0), 1, 500, 708, 710, 711, 712, 716, 1000];
        for (uint256 k; k < cells.length; ++k) {
            assert(_knot(cells[k]) < _knot(cells[k] + 1));
        }
    }

    /// @notice Every anchor pair is ordered; the final plateau is included.
    function test_all_knots_nondecreasing() public view {
        int256 previous = _knot(0);
        for (uint256 i = 1; i < 4938; ++i) {
            int256 next = _knot(i);
            assert(previous <= next);
            previous = next;
        }
        assert(_knot(4936) == _knot(4937));
    }

    // ════════════════════════════════════════════════
    // FUZZ WRAPPERS (T17)
    // ════════════════════════════════════════════════

    function _fuzzCellMonotone(uint256 i, uint256 rawR) internal view {
        Cell memory cell = _prepare(i);
        uint256 span = _cellWidthReserve(cell.width4);
        uint256 r = bound(rawR, 0, span - 2);
        uint256 lo = _edgeLow(cell.left4);
        assert(_atReserve(cell, lo + r, BOOT, LAM)
            <= _atReserve(cell, lo + r + 1, BOOT, LAM));
    }

    function test_fuzz_cell_monotone_0(uint256 r) public view { _fuzzCellMonotone(0, r); }
    function test_fuzz_cell_monotone_500(uint256 r) public view { _fuzzCellMonotone(500, r); }
    function test_fuzz_cell_monotone_708(uint256 r) public view { _fuzzCellMonotone(708, r); }
    function test_fuzz_cell_monotone_710(uint256 r) public view { _fuzzCellMonotone(710, r); }
    function test_fuzz_cell_monotone_711(uint256 r) public view { _fuzzCellMonotone(711, r); }
    function test_fuzz_cell_monotone_712(uint256 r) public view { _fuzzCellMonotone(712, r); }
    function test_fuzz_cell_monotone_716(uint256 r) public view { _fuzzCellMonotone(716, r); }
    function test_fuzz_cell_monotone_1000(uint256 r) public view { _fuzzCellMonotone(1000, r); }
    function test_fuzz_cell_terminal_plateau(uint256 r) public view {
        assert(_knot(4936) == _knot(4937));
        _fuzzCellMonotone(4936, r);
    }
}
