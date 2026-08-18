// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

/// @dev Adversarial boundary probes for the 51-bit timing pack (scratch).
contract TimingBoundaryAttackTest is Test {
    uint256 constant M51 = (1 << 51) - 1;

    function test_boundary_allMax() public pure {
        uint256 t = CurveMath.packTimings(M51, M51, M51, M51, M51);
        assertEq(t, type(uint256).max >> 1); // 2^255 - 1
        assertEq(t & CurveMath.TIMINGS_MASK, M51);
        assertEq((t >> 51) & CurveMath.TIMINGS_MASK, M51);
        assertEq((t >> 204) & CurveMath.TIMINGS_MASK, M51);
    }

    /// Overflow of one field spills into the NEXT field's LSB and the
    /// original slot reads zero -> TimingsIncomplete catches it at deploy.
    /// (Hand-rolled packing: packTimings now refuses oversize at pack time.)
    function test_boundary_overflowPredeposit() public pure {
        uint256 t = (1 << 51) | (3 days << 51) | (1 days << 102) | (1 days << 153) | (1 days << 204);
        assertEq(t & CurveMath.TIMINGS_MASK, 0, "predeposit slot reads zero");
        assertEq((t >> 51) & CurveMath.TIMINGS_MASK, 3 days + 1, "spill lands in lock LSB");
    }

    /// Overflow of the LAST field: bit 256 lost entirely, vote reads zero.
    /// (Hand-rolled packing: packTimings now refuses oversize at pack time.)
    function test_boundary_overflowVote() public pure {
        uint256 t = (1 days) | (3 days << 51) | (1 days << 102) | (1 days << 153) | ((1 << 51) << 204);
        assertEq((t >> 204) & CurveMath.TIMINGS_MASK, 0, "vote slot zero");
    }

    /// 51-bit upper sane boundary: ~71.6M years, decodes clean.
    function test_boundary_upperSane() public pure {
        uint256 v = M51;
        uint256 t = CurveMath.packTimings(1 days, v, 1 days, 1 days, v);
        assertEq((t >> 51) & CurveMath.TIMINGS_MASK, v);
        assertEq((t >> 204) & CurveMath.TIMINGS_MASK, v);
    }

    /// No field collision: adjacent fields never overlap (5*51=255<256).
    function test_noCollision() public pure {
        uint256 t = CurveMath.packTimings(1, 1, 1, 1, 1);
        assertEq(t, 1 | (1 << 51) | (1 << 102) | (1 << 153) | (1 << 204));
    }

    /// Nonzero garbage spill (lock = 2^51 + 5) is refused at PACK time —
    /// the deploy-side guard cannot see it (all slots decode nonzero).
    /// External wrapper: library-internal calls can't be expectRevert-caught.
    PackWrapper pw = new PackWrapper();

    function test_packRefusesNonzeroSpill() public {
        vm.expectRevert(CurveMath.TimingsOverflow.selector);
        pw.pack(1 days, (1 << 51) + 5, 1 days, 1 days, 1 days);
        vm.expectRevert(CurveMath.TimingsOverflow.selector);
        pw.pack(1 days, 3 days, 1 days, 1 days, 1 << 51);
        // sanity: sane values still pack
        uint256 t = pw.pack(1 days, 3 days, 1 days, 1 days, 1 days);
        assertEq((t >> 51) & CurveMath.TIMINGS_MASK, 3 days);
    }
}

contract PackWrapper {
    function pack(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e)
        external
        pure
        returns (uint256)
    {
        return CurveMath.packTimings(a, b, c, d, e);
    }
}
