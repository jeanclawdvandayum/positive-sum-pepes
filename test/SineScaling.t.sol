// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SineMath} from "../src/libraries/SineMath.sol";
import {FixedPointMathLib as FPML} from "solady/src/utils/FixedPointMathLib.sol";

/// @title SineScalingTest
/// @notice The actual IBCO raise changes curve distances, not its price ratios.
contract SineScalingTest is Test {
    function curve(uint256 boot, uint24 amplitude) internal pure returns (SineMath.Curve memory) {
        return SineMath.materialize(
            SineMath.Params(1e13, 4_477_562_267_871_699, 0.06e18, 10_000e18, amplitude), boot
        );
    }

    function test_TinyAndLargeRaisesKeepTheSamePriceTargets() public pure {
        uint256[8] memory boots = [uint256(1), 1000, 0.005e18, 1e18, 450e18, 1_000_000e18, 1e30, 1e36];
        for (uint256 i; i < boots.length; ++i) {
            SineMath.Curve memory c = curve(boots[i], 10000);
            assertApproxEqRel(c.B, 0.000075e18, 1e5, "IBCO seam stays calibrated");
            assertApproxEqRel(SineMath.priceAt(c, c.boot + 3 * c.lam), 0.06e18, 1e5, "third wave target");
            assertApproxEqRel(FPML.divWad(0.06e18, c.B), 800e18, 1e5, "800x after IBCO");
            assertGt(c.q0, 0, "positive genesis supply");
            assertGe(SineMath.supplyAt(c, c.boot + 1), c.q0, "launch seam");
        }
    }

    function testFuzz_PricesInvariantAndSupplyScales(uint8 exponent, uint64 rawRatio, uint16 rawAmp) public pure {
        uint256 boot = 10 ** bound(exponent, 12, 36);
        uint256 ratio = bound(rawRatio, 1e15, 8e18);
        uint24 amp = uint24(bound(rawAmp, 0, 10000));
        SineMath.Curve memory small = curve(boot, amp);
        SineMath.Curve memory large = curve(boot * 10, amp);
        uint256 rSmall = small.boot + FPML.mulWad(small.lam, ratio);
        uint256 rLarge = large.boot + FPML.mulWad(large.lam, ratio);
        assertApproxEqRel(SineMath.priceAt(small, rSmall), SineMath.priceAt(large, rLarge), 1e8, "same normalized price");
        assertApproxEqRel(SineMath.supplyAt(small, rSmall) * 10, SineMath.supplyAt(large, rLarge), 1e8, "supply scales with raise");
    }

    function testFuzz_PredepositInverseProtectsBacking(uint8 exponent, uint64 rawPart) public pure {
        SineMath.Curve memory c = curve(10 ** bound(exponent, 0, 36), 10000);
        uint256 target = FPML.mulWad(c.q0, bound(rawPart, 1, 1e18));
        uint256 endpoint = SineMath.reserveAt(c, target);
        assertGe(SineMath.supplyAt(c, endpoint), target, "pre-IBCO inverse pays conservatively");
        assertLe(endpoint, c.boot, "pre-IBCO inverse stays within boot");
    }

    function testFuzz_MinimumBuyAtLargeRaiseCannotProfit(uint8 exponent, uint64 rawPosition, uint16 rawAmp) public pure {
        SineMath.Curve memory c = curve(10 ** bound(exponent, 24, 36), uint24(bound(rawAmp, 0, 10000)));
        uint256 reserve = c.boot + FPML.mulWad(c.lam, bound(rawPosition, 0, 6e18));
        uint256 spent = 0.0045e18;
        uint256 bought = SineMath.buyOut(c, reserve, spent);
        if (bought == 0) return;
        assertLe(SineMath.sellOut(c, reserve + spent, bought), spent, "large raise minimum roundtrip");
    }

    function test_MinimumBuyAtLargeRaiseEdges() public pure {
        uint256[3] memory boots = [uint256(1e24), 1e30, 1e36];
        for (uint256 i; i < boots.length; ++i) {
            SineMath.Curve memory c = curve(boots[i], 10000);
            for (uint256 part; part < 16; ++part) {
                uint256 reserve = c.boot + c.lam * part / 4;
                uint256 spent = 0.0045e18;
                uint256 bought = SineMath.buyOut(c, reserve, spent);
                if (bought == 0) continue;
                assertLe(SineMath.sellOut(c, reserve + spent, bought), spent, "large edge roundtrip");
            }
        }
    }
    function test_TenMillionBuyCanStillExitFromSaturatedReserve() public pure {
        SineMath.Curve memory c = curve(900e18, 10000);
        uint256 bought = SineMath.buyOut(c, c.boot, 10_000_000e18);
        assertGt(bought, 0);
        uint256 sold = SineMath.sellOut(c, c.boot + 10_000_000e18, bought);
        assertGt(sold, 0);
        assertLe(sold, 10_000_000e18);
    }

    function testFuzz_DeepReciprocalStepsCannotProfit(uint8 exponent, uint8 rawStep, uint64 rawExtra) public pure {
        SineMath.Curve memory c = curve(10 ** bound(exponent, 24, 36), 0);
        uint256 step = bound(rawStep, 1, 20);
        uint256 argument = uint256(FPML.lnWad(int256(1e36 / step)));
        uint256 reserve = c.boot + FPML.fullMulDiv(argument, c.lam, c.waveTrend);
        uint256 spent = 0.0045e18 + bound(rawExtra, 0, 1e18);
        uint256 bought = SineMath.buyOut(c, reserve, spent);
        if (bought == 0) return;
        assertLe(SineMath.sellOut(c, reserve + spent, bought), spent, "reciprocal step roundtrip");
    }

}
