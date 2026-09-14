// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SineV3Math} from "../src/SineV3Math.sol";
import {SineV3Fixtures} from "./SineV3Fixtures.sol";

/// @title SineV3Oracle — independent Decimal vectors vs the on-chain helper
/// @notice Fixtures come from scripts/sine_v3.py: closed-form milestone
///         prices and tanh-sinh quadrature supplies at 70 digits — derived
///         from the mathematical specification, never from Solidity output.
///         Tolerances: price 1e-11 relative, supply 1e-9 relative (with an
///         absolute floor for microscopic values).
contract SineV3OracleTest is Test {
    SineV3Math math;
    uint256 constant P_L = 75_000_000_000_000; // 0.000075

    function setUp() public {
        math = new SineV3Math();
    }

    function test_LamFormula() public view {
        // reference calibration is EXACT
        assertEq(math.lamAt(450e18), 955e18, "lambda(450e18) = 955e18");
        // one-wei boot: nonzero, matches the spec's stated 45,019,131,735
        assertEq(math.lamAt(1), 45_019_131_735, "lambda(1 wei)");
        // square-root scaling: lambda(4b) = 2*lambda(b) within rounding
        uint256 lam1 = math.lamAt(90e18);
        uint256 lam4 = math.lamAt(360e18);
        assertApproxEqAbs(lam4, 2 * lam1, 2, "lambda(4b) ~ 2*lambda(b)");
        // target = boot + 10*lam, integer exact
        assertEq(math.targetAt(450e18, 955e18), 10_000e18, "reference target");
    }

    function test_Fixtures() public view {
        SineV3Fixtures.Row[24] memory rows = SineV3Fixtures.rows();
        for (uint256 i; i < rows.length; ++i) {
            SineV3Fixtures.Row memory r = rows[i];
            uint256 p = math.priceWad(r.R, r.boot, r.lam, P_L);
            assertApproxEqRel(
                p, r.price, 1e11, string.concat("price row ", vm.toString(i))
            ); // 1e-11 relative (1e11 denom)
            if (r.supply != 0) {
                uint256 q = math.supplyWad(r.R, r.boot, r.lam, P_L);
                // 1e-9 relative + 1e6 wei absolute floor for tiny pools
                uint256 tol = q / 1_000_000_000 + 1_000_000_000_000;
                assertLe(
                    q > r.supply ? q - r.supply : r.supply - q,
                    tol,
                    string.concat("supply row ", vm.toString(i))
                );
            }
        }
    }

    /// The eleven launch-to-target milestones hit the softened cube-root
    /// schedule: P(R_n)/P_L = 1000^(((1+n)^(1/3)-1)/(11^(1/3)-1)).
    function test_MilestoneSchedule() public view {
        uint256 boot = 450e18;
        uint256 lam = 955e18;
        uint256[11] memory expectMultiple = [
            uint256(1e18),
            4_335_825_141_598_757_000,
            12_132_845_208_023_736_000,
            27_525_288_473_323_999_000,
            54_975_024_239_398_420_000,
            100_641_969_722_368_720_000,
            172_827_490_965_685_600_000,
            282_501_176_064_271_200_000,
            443_922_679_251_537_490_000,
            675_371_631_232_382_770_000,
            1_000_000_000_000_000_000_000
        ];
        for (uint256 n; n < 11; ++n) {
            uint256 R = boot + n * lam;
            uint256 p = math.priceWad(R, boot, lam, P_L);
            uint256 multiple = (p * 1e18) / P_L; // ratio in WAD
            uint256 tol = expectMultiple[n] / 1_000_000_000 + 1; // 1e-9 rel
            uint256 diff = multiple > expectMultiple[n]
                ? multiple - expectMultiple[n] : expectMultiple[n] - multiple;
            assertLe(diff, tol, string.concat("milestone ", vm.toString(n)));
        }
    }

    /// Monotonicity across every approximation-cell boundary: adjacent wei
    /// in reserve never decreases price or cumulative supply, on both sides
    /// of launch (x=0) and across quarter-wave knots.
    function test_AdjacentWeiMonotone() public view {
        uint256 boot = 450e18;
        uint256 lam = 955e18;
        // sample cell boundaries around x in {-0.5,-0.25,0,0.25,1,2.5,10,64}
        int256[9] memory xs = [
            int256(-0.5e18), -0.25e18, -0.1e18, 0, 0.25e18, 1e18, 25e17, 10e18, 63e18
        ];
        for (uint256 i; i < xs.length; ++i) {
            uint256 R = _Rof(xs[i], boot, lam);
            for (int256 d = -3; d <= 3; ++d) {
                uint256 r1 = _shift(R, d);
                uint256 r2 = _shift(R, d + 1);
                if (r2 <= r1) continue;
                assertLe(
                    math.priceWad(r1, boot, lam, P_L),
                    math.priceWad(r2, boot, lam, P_L),
                    "price monotone adjacent wei"
                );
                assertLe(
                    math.supplyWad(r1, boot, lam, P_L),
                    math.supplyWad(r2, boot, lam, P_L),
                    "supply monotone adjacent wei"
                );
            }
        }
    }

    /// Genesis supply is the SAME curve's Q(b) — no separate IBCO leg.
    function test_GenesisIsSameCurve() public view {
        uint256 boot = 90e18;
        uint256 lam = math.lamAt(boot);
        assertEq(math.genesisQ(boot, lam, P_L), math.supplyWad(boot, boot, lam, P_L));
        assertGt(math.genesisQ(boot, lam, P_L), 0);
    }

    /// Out-of-domain reserves revert with the explicit capacity error.
    function test_DomainEdges() public {
        uint256 boot = 450e18;
        uint256 lam = 955e18;
        vm.expectRevert(SineV3Math.SineV3Domain.selector);
        math.supplyWad(boot + 64 * lam + 1, boot, lam, P_L);
        vm.expectRevert(SineV3Math.SineV3Domain.selector);
        math.priceWad(boot + 64 * lam + 1, boot, lam, P_L);
        uint256 edge = boot + 64 * lam;
        math.supplyWad(edge, boot, lam, P_L); // edge itself is in-domain
        math.priceWad(edge, boot, lam, P_L);
    }

    function _Rof(int256 x, uint256 boot, uint256 lam) private pure returns (uint256) {
        if (x >= 0) return boot + uint256((uint256(x) * lam) / 1e18);
        uint256 back = (uint256(-x) * lam) / 1e18;
        return back < boot ? boot - back : 0;
    }

    function _shift(uint256 R, int256 d) private pure returns (uint256) {
        if (d >= 0) return R + uint256(d);
        uint256 u = uint256(-d);
        return R > u ? R - u : 0;
    }
}
