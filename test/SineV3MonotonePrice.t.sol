// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SineV3Price} from "../src/SineV3Price.sol";
import {SineV3PriceFixtures} from "./SineV3PriceFixtures.sol";

contract SineV3PriceHarness {
    function phaseAt(int256 x) external pure returns (int256) {
        return SineV3Price.phaseAt(x);
    }

    function exponentAt(int256 x) external pure returns (int256) {
        return SineV3Price.exponentAt(x);
    }

    function exponentAtPhase(int256 s) external pure returns (int256) {
        return SineV3Price.exponentAtPhase(s);
    }

    function priceAtX(int256 x, uint256 pL) external pure returns (uint256) {
        return SineV3Price.priceAtX(x, pL);
    }

    function scaledExp(int256 e, uint256 scale) external pure returns (uint256) {
        return SineV3Price.scaledExp(e, scale);
    }
}

/// @title Rounded single-sine price monotonicity and independent reference tests
contract SineV3MonotonePriceTest is Test {
    SineV3PriceHarness internal h = new SineV3PriceHarness();
    int256 internal constant LN2 = 693147180559945309;

    function test_IndependentPriceFixtures() public view {
        for (uint256 i; i < SineV3PriceFixtures.COUNT; ++i) {
            (int256 x, uint256 pL, uint256 expected) = SineV3PriceFixtures.row(i);
            uint256 actual = h.priceAtX(x, pL);
            uint256 error = actual > expected ? actual - expected : expected - actual;
            assertLe(error, expected / 100_000_000_000 + 1, "independent price tolerance");
        }
    }

    function test_QuarterAndSignSeamsAreOrdered() public view {
        int256[18] memory quarters =
            [int256(-4000), -1200, -400, -256, -64, -4, -3, -2, -1, 0, 1, 2, 3, 19, 66, 256, 512, 40000];
        for (uint256 i; i < quarters.length; ++i) {
            int256 x = quarters[i] * 25e16;
            assertLe(h.phaseAt(x - 1), h.phaseAt(x), "phase left seam");
            assertLe(h.phaseAt(x), h.phaseAt(x + 1), "phase right seam");
            assertLe(h.priceAtX(x - 1, 75e12), h.priceAtX(x, 75e12), "price left seam");
            assertLe(h.priceAtX(x, 75e12), h.priceAtX(x + 1, 75e12), "price right seam");
        }
    }

    function test_BinaryExponentSeamsAreOrdered() public view {
        for (int256 k = -255; k < 196; ++k) {
            int256 e = k * LN2;
            uint256 scale = k > 0 ? 1 : 1e54;
            assertLe(h.scaledExp(e - 1, scale), h.scaledExp(e, scale), "binary left seam");
            assertLe(h.scaledExp(e, scale), h.scaledExp(e + 1, scale), "binary right seam");
        }
    }

    function test_CustomPriceRetainsPrecisionBeforeBinaryScaling() public view {
        // Flooring the normalized multiplier to pL precision before its
        // positive binary shift would lose up to 1e-9 relative here.
        uint256 actual = h.scaledExp(100e18, 1e9);
        uint256 expected = 26881171418161354484126255515800135873611118773741922;
        uint256 error = actual > expected ? actual - expected : expected - actual;
        assertLe(error, expected / 100_000_000_000 + 1);
    }

    function test_LaunchAndNegativeReflection() public view {
        assertEq(h.phaseAt(0), 0);
        assertEq(h.exponentAt(0), 0);
        assertEq(h.priceAtX(0, 75e12), 75e12);
        assertEq(h.priceAtX(0, 1e9), 1e9);
        assertEq(h.phaseAt(-475e16), -h.phaseAt(475e16));
        assertEq(h.exponentAt(-475e16), -h.exponentAt(475e16));
        // A sub-WAD-root input has no artificial jump in marginal price.
        assertEq(h.priceAtX(-1, 75e12), 75e12);
        assertEq(h.priceAtX(1, 75e12), 75e12);
    }

    function test_DensityAtHighPrecisionDoesNotUnderflowAt64Waves() public pure {
        assertGt(SineV3Price.densityAtX(1000e18, 1e54), 0);
        assertGt(SineV3Price.densityAtX(10000e18, 1e54), 0);
    }

    function test_ArithmeticDomainFailsClosed() public {
        vm.expectRevert(SineV3Price.SineV3PriceDomain.selector);
        h.phaseAt(type(int256).min);
        vm.expectRevert(SineV3Price.SineV3PriceDomain.selector);
        h.phaseAt(type(int256).max);
        vm.expectRevert(SineV3Price.SineV3PriceOverflow.selector);
        h.scaledExp(200e18, 1e18);
        assertEq(h.scaledExp(-200e18, 1e18), 0);
    }

    function test_ExtremeSignedAndBinaryInputsFailClosed() public {
        int256 phaseBound = int256(type(uint256).max / 1e36 - 2e18);
        assertLe(h.phaseAt(phaseBound - 1), h.phaseAt(phaseBound));
        assertLe(h.phaseAt(-phaseBound), h.phaseAt(-phaseBound + 1));
        assertEq(h.phaseAt(-phaseBound), -h.phaseAt(phaseBound));
        assertEq(h.scaledExp(type(int256).min, 1e54), 0);
        assertEq(h.scaledExp(0, type(uint256).max / 2), type(uint256).max / 2);
        assertEq(h.scaledExp(LN2, type(uint256).max / 2), type(uint256).max - 1);
        assertLe(h.scaledExp(LN2 - 1, type(uint256).max / 2), type(uint256).max - 1);
        assertEq(h.scaledExp(255 * LN2, 1), uint256(1) << 255);
        vm.expectRevert();
        h.scaledExp(LN2 + 1, type(uint256).max / 2);
        vm.expectRevert(SineV3Price.SineV3PriceOverflow.selector);
        h.scaledExp(256 * LN2, 1);
        vm.expectRevert(SineV3Price.SineV3PriceDomain.selector);
        h.scaledExp(0, type(uint256).max / 2 + 1);
        vm.expectRevert(SineV3Price.SineV3PriceDomain.selector);
        h.exponentAtPhase(type(int256).min);
        vm.expectRevert(SineV3Price.SineV3PriceDomain.selector);
        h.exponentAtPhase(int256(type(uint256).max / 1e36 - 1e18 + 1));
        assertEq(h.exponentAtPhase(0), 0);
    }

    function testFuzz_AdjacentPriceAndPhaseAreMonotone(uint256 raw, uint256 priceRaw) public view {
        int256 x = int256(raw % 11000e18) - 1000e18;
        uint256 pL = 1e9 + priceRaw % (1e18 - 1e9 + 1);
        assertLe(h.phaseAt(x), h.phaseAt(x + 1), "adjacent phase");
        assertLe(h.exponentAt(x), h.exponentAt(x + 1), "adjacent exponent");
        assertLe(h.priceAtX(x, pL), h.priceAtX(x + 1, pL), "adjacent price");
    }

    function testFuzz_OrderedDistantCoordinatesAreMonotone(uint256 aRaw, uint256 bRaw) public view {
        int256 a = int256(aRaw % 11000e18) - 1000e18;
        int256 b = int256(bRaw % 11000e18) - 1000e18;
        if (a > b) (a, b) = (b, a);
        assertLe(h.phaseAt(a), h.phaseAt(b));
        assertLe(h.exponentAt(a), h.exponentAt(b));
        assertLe(h.priceAtX(a, 1e9), h.priceAtX(b, 1e9));
        assertLe(h.priceAtX(a, 1e18), h.priceAtX(b, 1e18));
    }

    function testFuzz_AdjacentExponentValuesAreMonotone(uint256 raw) public view {
        int256 exponent = int256(raw % 250e18) - 200e18;
        assertLe(h.scaledExp(exponent, 1e54), h.scaledExp(exponent + 1, 1e54));
        exponent = int256(raw % 335e18) - 200e18;
        assertLe(h.scaledExp(exponent, 1e18), h.scaledExp(exponent + 1, 1e18));
    }
}
