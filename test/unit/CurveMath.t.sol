// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

/// @title CurveMathTest — Exhaustive tests for bonding curve math
contract CurveMathTest is Test {
    using CurveMath for CurveMath.CurveConfig;

    CurveMath.CurveConfig cc;
    CurveMath.CurveConfig multiCC;

    function setUp() public {
        // Single S-curve: exp(0→100M) → log(100M→∞)
        // k1 sized for ~100x price growth from P0 to P(S_inf)
        // e^(k1 * S_inf) = 100 → k1 = ln(100)/100M ≈ 4.6e-8 → 0.000000046e18
        cc = CurveMath.singleCurve(
            0.0001e18,         // P0: 0.0001 ETH
            100_000_000e18,    // S_inf: 100M PSP
            0.000000046e18,    // k1: ~100x growth over exponential phase
            0.1e18             // k2: gentle logarithmic
        );

        // Multi-oscillation: exp → log → exp → log (4 zones)
        uint256[] memory boundaries = new uint256[](4);
        boundaries[0] = 0;
        boundaries[1] = 10_000_000e18;   // Zone 0: exp [0, 10M]
        boundaries[2] = 50_000_000e18;   // Zone 1: log [10M, 50M] (stability island)
        boundaries[3] = 60_000_000e18;   // Zone 2: exp [50M, 60M] (volatility burst)
        // Zone 3: log [60M, ∞) (final stability)

        // k_exp for 10x in 10M: e^(k*10M) = 10 → k = ln(10)/10M ≈ 2.3e-7
        // k_exp2 for 5x in 10M: e^(k*10M) = 5 → k = ln(5)/10M ≈ 1.6e-7
        uint256[] memory rates = new uint256[](4);
        rates[0] = 0.00000023e18;   // k_exp1: ~10x growth in first burst
        rates[1] = 0.02e18;         // k_log1: gentle log (stability)
        rates[2] = 0.00000016e18;   // k_exp2: ~5x growth in second burst
        rates[3] = 0.01e18;         // k_log2: very gentle (deep stability)

        bool[] memory expFlags = new bool[](4);
        expFlags[0] = true;   // exponential
        expFlags[1] = false;  // logarithmic (stable)
        expFlags[2] = true;   // exponential (volatile)
        expFlags[3] = false;  // logarithmic (stable)

        multiCC = CurveMath.multiCurve(0.0001e18, boundaries, rates, expFlags);
    }

    // ═════════════════════════════════════════════════════════
    //  PRICE TESTS — Single Curve
    // ═════════════════════════════════════════════════════════

    function test_PriceAtZero() public view {
        assertEq(CurveMath.marginalPrice(0, cc), 0.0001e18, "Price at 0 = P0");
    }

    function test_PriceMonotonicIncreasing() public {
        uint256 prev = 0;
        for (uint256 s = 1e18; s <= 200_000_000e18; s += 10_000_000e18) {
            uint256 price = CurveMath.marginalPrice(s, cc);
            assertTrue(price > prev, "Price must increase");
            prev = price;
        }
    }

    function test_PriceInflectionContinuous() public {
        uint256 S_inf = 100_000_000e18;
        uint256 justBefore = CurveMath.marginalPrice(S_inf - 1, cc);
        uint256 atInflection = CurveMath.marginalPrice(S_inf, cc);
        uint256 justAfter = CurveMath.marginalPrice(S_inf + 1, cc);
        // Prices should be very close at the boundary
        assertApproxEqRel(justBefore, atInflection, 0.001e18, "Price continuous at inflection (before)");
        assertApproxEqRel(atInflection, justAfter, 0.001e18, "Price continuous at inflection (after)");
    }

    // ═════════════════════════════════════════════════════════
    //  BUY OUTPUT TESTS
    // ═════════════════════════════════════════════════════════

    function test_FirstBuy() public {
        uint256 ethInput = 1e18;
        uint256 pspOut = CurveMath.computeBuyOutput(ethInput, 0, cc);
        assertTrue(pspOut > 0, "First buy > 0");
        assertTrue(pspOut < 10_000e18, "First buy < ethInput/P0 (price rises)");
        console.log("1 ETH buys", pspOut / 1e18, "PSP at supply 0");
    }

    function test_BuyZeroETH() public {
        assertEq(CurveMath.computeBuyOutput(0, 0, cc), 0);
    }

    function test_BuyIncreasesSupplyAndPrice() public {
        uint256 ethIn = 5e18;
        uint256 supply = 0;

        for (uint256 i = 0; i < 5; i++) {
            uint256 pspOut = CurveMath.computeBuyOutput(ethIn, supply, cc);
            uint256 priceBefore = CurveMath.marginalPrice(supply, cc);
            uint256 priceAfter = CurveMath.marginalPrice(supply + pspOut, cc);

            assertTrue(pspOut > 0, "Must get PSP");
            assertTrue(priceAfter > priceBefore, "Price must rise after buy");
            

            supply += pspOut;
        }
    }

    // ═════════════════════════════════════════════════════════
    //  SELL OUTPUT TESTS
    // ═════════════════════════════════════════════════════════

    function test_SellZeroPSP() public {
        assertEq(CurveMath.computeSellOutput(0, 100_000e18, cc), 0);
    }

    function test_SellMoreThanSupply() public {
        assertEq(CurveMath.computeSellOutput(100_001e18, 100_000e18, cc), 0);
    }

    function test_SellDecreasesPrice() public {
        // Buy to get supply
        uint256 supply = CurveMath.computeBuyOutput(10e18, 0, cc);
        uint256 priceAfterBuy = CurveMath.marginalPrice(supply, cc);

        // Sell half
        uint256 half = supply / 2;
        uint256 ethOut = CurveMath.computeSellOutput(half, supply, cc);
        uint256 priceAfterSell = CurveMath.marginalPrice(supply - half, cc);

        assertTrue(ethOut > 0, "Sell returns ETH");
        assertTrue(priceAfterSell < priceAfterBuy, "Price drops after sell");
    }

    // ═════════════════════════════════════════════════════════
    //  ROUND-TRIP CONSERVATION (CRITICAL INVARIANT)
    // ═════════════════════════════════════════════════════════

    function test_BuyThenSellRoundTrip() public {
        uint256 ethIn = 1e18;
        uint256 supply = CurveMath.computeBuyOutput(ethIn, 0, cc);
        // Sell supply - 1 (can't sell entire supply, guard prevents drain)
        uint256 ethOut = CurveMath.computeSellOutput(supply - 1, supply, cc);

        console.log("Round-trip: in=%d, out=%d, loss=%d%%", ethIn/1e15, ethOut/1e15, (ethIn-ethOut)*100/ethIn);

        assertTrue(ethOut > 0, "Round-trip returns ETH");
        assertTrue(ethOut < ethIn, "Sell must return less than buy");
        assertTrue(ethOut > ethIn / 2, "Round-trip loss < 50%");
    }

    function test_BuyThenSellAtHigherSupply() public {
        uint256 baseSupply = CurveMath.computeBuyOutput(5e18, 0, cc);
        uint256 ethIn = 1e18;
        uint256 pspBought = CurveMath.computeBuyOutput(ethIn, baseSupply, cc);
        uint256 ethOut = CurveMath.computeSellOutput(pspBought - 1, baseSupply + pspBought, cc);
        assertTrue(ethOut > 0 && ethOut < ethIn, "Round-trip: 0 < out < in");
    }

    function test_SmallSwapLowSlippage() public {
        // Small swaps relative to supply should have low slippage
        uint256 supply = CurveMath.computeBuyOutput(100e18, 0, cc); // decent supply
        uint256 smallBuy = 0.001e18; // tiny

        uint256 pspOut = CurveMath.computeBuyOutput(smallBuy, supply, cc);
        uint256 ethBack = CurveMath.computeSellOutput(pspOut, supply + pspOut, cc);

        // For a very small swap, slippage should be minimal
        uint256 loss = smallBuy > ethBack ? smallBuy - ethBack : 0;
        console.log("Small swap loss %: %d", loss * 10000 / smallBuy);

        // Less than 5% loss for a tiny swap
        assertTrue(loss * 100 < smallBuy * 5, "Small swap < 5% loss");
    }

    // ═════════════════════════════════════════════════════════
    //  MULTI-OSCILLATION TESTS
    // ═════════════════════════════════════════════════════════

    function test_MultiCurve_PriceAtZero() public view {
        assertEq(CurveMath.marginalPrice(0, multiCC), 0.0001e18, "Multi: price at 0 = P0");
    }

    function test_MultiCurve_PriceMonotonic() public {
        uint256 prev = 0;
        uint256[] memory checkpoints = new uint256[](8);
        checkpoints[0] = 1e18;
        checkpoints[1] = 5_000_000e18;
        checkpoints[2] = 10_000_000e18;  // boundary 0→1
        checkpoints[3] = 30_000_000e18;
        checkpoints[4] = 50_000_000e18;  // boundary 1→2
        checkpoints[5] = 55_000_000e18;
        checkpoints[6] = 60_000_000e18;  // boundary 2→3
        checkpoints[7] = 80_000_000e18;

        for (uint256 i = 0; i < 8; i++) {
            uint256 price = CurveMath.marginalPrice(checkpoints[i], multiCC);
            assertTrue(price > prev, "Multi: price must increase at checkpoint %i");
            console.log("Multi price at %dM: %d", checkpoints[i]/1e6/1e18, price/1e12);
            prev = price;
        }
    }

    function test_MultiCurve_BoundaryContinuity() public {
        // Price should be continuous at each boundary
        uint256[] memory boundaries = new uint256[](3);
        boundaries[0] = 10_000_000e18;
        boundaries[1] = 50_000_000e18;
        boundaries[2] = 60_000_000e18;

        for (uint256 i = 0; i < 3; i++) {
            uint256 priceBefore = CurveMath.marginalPrice(boundaries[i] - 1, multiCC);
            uint256 priceAfter = CurveMath.marginalPrice(boundaries[i], multiCC);
            assertApproxEqRel(priceBefore, priceAfter, 0.001e18, "Multi: discontinuous at boundary %i");
        }
    }

    function test_MultiCurve_ZonesHaveDifferentGrowthRates() public {
        // Zone 0 (exp): price should grow faster than zone 1 (log)
        uint256 expGrowth = CurveMath.marginalPrice(5_000_000e18, multiCC)
            * 1e18 / CurveMath.marginalPrice(1_000_000e18, multiCC);
        uint256 logGrowth = CurveMath.marginalPrice(40_000_000e18, multiCC)
            * 1e18 / CurveMath.marginalPrice(20_000_000e18, multiCC);

        assertTrue(expGrowth > logGrowth, "Exp zone should grow faster than log zone");
        console.log("Exp zone growth ratio: %d", expGrowth);
        console.log("Log zone growth ratio: %d", logGrowth);
    }

    function test_MultiCurve_SecondExpBurstFaster() public {
        // Zone 2 (second exp burst, 50M→60M) should show rapid growth
        uint256 priceBefore = CurveMath.marginalPrice(52_000_000e18, multiCC);
        uint256 priceAfter = CurveMath.marginalPrice(58_000_000e18, multiCC);
        uint256 growthRatio = priceAfter * 1e18 / priceBefore;

        // Should see significant growth in 6M PSP of the exp zone
        assertTrue(growthRatio > 1.1e18, "Second exp burst should show >10% growth");
        console.log("Second exp burst 52M-58M ratio: %d", growthRatio);
    }

    function test_MultiCurve_RoundTrip() public {
        uint256 ethIn = 1e18;
        uint256 supply = CurveMath.computeBuyOutput(ethIn, 0, multiCC);
        vm.assume(supply > 1);
        uint256 ethOut = CurveMath.computeSellOutput(supply - 1, supply, multiCC);
        assertTrue(ethOut > 0 && ethOut < ethIn, "Multi round-trip: 0 < out < in");
    }

    function test_MultiCurve_CrossBoundarySwap() public {
        // Buy starting in zone 0, crossing into zone 1
        uint256 startSupply = 9_000_000e18;
        // Need enough ETH to cross 1M PSP boundary at ~0.0001 ETH price
        // At 9M supply, price is ~0.0001 * e^(0.00000023 * 9M) ≈ 0.0001 * 8.2 ≈ 0.0008 ETH
        // 1M PSP at 0.0008 = 800 ETH. Use 1000 ETH to ensure crossing.
        uint256 ethIn = 1000e18;
        uint256 pspOut = CurveMath.computeBuyOutput(ethIn, startSupply, multiCC);

        assertTrue(pspOut > 0, "Cross-boundary buy > 0");

        // Sell back (minus 1 for guard)
        if (pspOut > 1) {
            uint256 ethOut = CurveMath.computeSellOutput(pspOut - 1, startSupply + pspOut, multiCC);
            assertTrue(ethOut > 0 && ethOut < ethIn, "Cross-boundary round-trip valid");
        }
    }

    // ═════════════════════════════════════════════════════════
    //  FUZZ TESTS
    // ═════════════════════════════════════════════════════════

    function testFuzz_BuyOutputPositive(uint256 ethInput, uint256 currentSupply) public view {
        vm.assume(ethInput > 0.001e18 && ethInput < 100e18);
        vm.assume(currentSupply < 50_000_000e18);

        uint256 pspOut = CurveMath.computeBuyOutput(ethInput, currentSupply, cc);
        assertTrue(pspOut > 0);
    }

    function testFuzz_PriceMonotonic(uint256 s1, uint256 s2) public view {
        vm.assume(s2 > s1);
        vm.assume(s2 < 50_000_000e18);
        vm.assume(s1 > 1e18);

        uint256 p1 = CurveMath.marginalPrice(s1, cc);
        uint256 p2 = CurveMath.marginalPrice(s2, cc);
        assertTrue(p2 >= p1, "Price must be monotonically increasing");
    }

    function testFuzz_RoundTrip(uint256 ethInput) public {
        vm.assume(ethInput > 0.01e18 && ethInput < 10e18);

        uint256 supply = CurveMath.computeBuyOutput(ethInput, 0, cc);
        vm.assume(supply > 1);
        uint256 ethOut = CurveMath.computeSellOutput(supply - 1, supply, cc);

        assertTrue(ethOut > 0, "Fuzz round-trip: out > 0");
        // Post-convergence clamp guarantees strict round-trip conservation
        assertTrue(ethOut < ethInput, "Fuzz round-trip: out must be < in (no arb)");
    }

    function testFuzz_MultiRoundTrip(uint256 ethInput) public {
        vm.assume(ethInput > 0.01e18 && ethInput < 10e18);

        uint256 supply = CurveMath.computeBuyOutput(ethInput, 0, multiCC);
        vm.assume(supply > 1);
        uint256 ethOut = CurveMath.computeSellOutput(supply - 1, supply, multiCC);

        assertTrue(ethOut > 0, "Multi fuzz: out > 0");
        assertTrue(ethOut < ethInput, "Multi fuzz: out must be < in (no arb)");
    }

    function testFuzz_BuyAtArbitrarySupply(uint256 ethInput, uint256 supply) public {
        vm.assume(ethInput > 0.01e18 && ethInput < 1000e18);
        vm.assume(supply > 1e18 && supply < 95_000_000e18);

        uint256 pspOut = CurveMath.computeBuyOutput(ethInput, supply, cc);
        assertTrue(pspOut > 0);
        vm.assume(pspOut > 1);

        uint256 ethOut = CurveMath.computeSellOutput(pspOut - 1, supply + pspOut, cc);
        assertTrue(ethOut > 0, "Fuzz buy-at: out > 0");
        assertTrue(ethOut < ethInput, "Fuzz buy-at: out must be < in (no arb)");
    }
}
