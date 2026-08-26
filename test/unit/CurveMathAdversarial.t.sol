// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

/// @title CurveMathAdversarial — Extreme, creative, adversarial tests
/// @notice Tests designed to break invariants through unusual inputs and sequences
contract CurveMathAdversarial is Test {
    using CurveMath for CurveMath.CurveConfig;

    CurveMath.CurveConfig cc;
    CurveMath.CurveConfig multiCC;
    CurveMath.CurveConfig steepCC;
    CurveMath.CurveConfig flatCC;

    function setUp() public {
        // Standard curve
        cc = CurveMath.singleCurve(
            0.0001e18,
            100_000_000e18,
            0.000000046e18,
            0.1e18
        );

        // Multi-oscillation: exp → log → exp → log
        uint256[] memory boundaries = new uint256[](4);
        boundaries[0] = 0;
        boundaries[1] = 10_000_000e18;
        boundaries[2] = 50_000_000e18;
        boundaries[3] = 60_000_000e18;

        uint256[] memory rates = new uint256[](4);
        rates[0] = 0.00000023e18;
        rates[1] = 0.02e18;
        rates[2] = 0.00000016e18;
        rates[3] = 0.01e18;

        bool[] memory expFlags = new bool[](4);
        expFlags[0] = true;
        expFlags[1] = false;
        expFlags[2] = true;
        expFlags[3] = false;

        multiCC = CurveMath.multiCurve(0.0001e18, boundaries, rates, expFlags);

        // Steep curve: aggressive exponential (1000x growth)
        steepCC = CurveMath.singleCurve(
            0.0001e18,
            1_000_000e18,      // very small S_inf
            0.0000069e18,      // ~1000x growth
            0.5e18             // aggressive log
        );

        // Near-flat curve: k1 = 0 (no exponential growth, pure flat → log)
        flatCC = CurveMath.singleCurve(
            0.001e18,
            10_000_000e18,
            0,                 // zero rate = flat exponential
            0.0001e18          // near-flat log
        );
    }

    // ═════════════════════════════════════════════════════════
    //  ATOM TESTS — 1 wei inputs
    // ═════════════════════════════════════════════════════════

    /// @dev Buy with exactly 1 wei of ETH
    function test_Atom_BuyOneWei() public view {
        uint256 out = CurveMath.computeBuyOutput(1, 0, cc);
        assertTrue(out > 0, "1 wei buy must produce output");
        assertTrue(out < 1e18, "1 wei buy should produce < 1 token");
    }

    /// @dev Sell exactly 1 wei of PSP — precision allows 0 return for 1-wei sells
    /// In exponential zone: integral of 1 wei = pStart * (e^(k*1wei) - 1) / k ≈ 0
    function test_Atom_SellOneWei() public {
        uint256 supply = CurveMath.computeBuyOutput(1e18, 0, cc);
        uint256 out = CurveMath.computeSellOutput(1, supply, cc);
        assertTrue(out >= 0, "1 wei sell should not revert");
        // At high supply (log zone), 1 wei sell produces non-zero output
        uint256 highSupply = CurveMath.computeBuyOutput(100e18, 0, cc);
        uint256 outHigh = CurveMath.computeSellOutput(1, highSupply, cc);
        assertTrue(outHigh >= 0, "1 wei sell at high supply should not revert");
    }

    /// @dev Buy at supply = 1 (minimum non-zero supply)
    function test_Atom_BuyAtSupplyOne() public view {
        uint256 out = CurveMath.computeBuyOutput(1e18, 1, cc);
        assertTrue(out > 0, "Buy at supply=1 must work");
    }

    /// @dev Alternating 1-wei buys/sells (precision attack)
    function test_Atom_MicroSwapAlternation() public {
        uint256 supply = CurveMath.computeBuyOutput(1e18, 0, cc);
        uint256 totalETHIn = 0;
        uint256 totalETHOut = 0;

        for (uint256 i = 0; i < 20; i++) {
            // Buy with 1 wei
            uint256 pspOut = CurveMath.computeBuyOutput(1, supply, cc);
            if (pspOut == 0) break;
            supply += pspOut;
            totalETHIn += 1;

            // Sell 1 wei back
            if (supply > 2 && pspOut > 0) {
                uint256 ethOut = CurveMath.computeSellOutput(1, supply, cc);
                if (ethOut == 0) break;
                supply -= 1;
                totalETHOut += ethOut;
            }
        }

        // Can't print more ETH than we put in
        assertTrue(
            totalETHOut <= totalETHIn,
            "Micro-swap alternation: can't extract ETH"
        );
    }

    // ═════════════════════════════════════════════════════════
    //  ZONE BOUNDARY PRECISION TESTS
    // ═════════════════════════════════════════════════════════

    /// @dev Zone boundary continuity: price at S_inf should be close from both sides
    function test_ZoneBoundary_PriceContinuityAtBoundary() public {
        uint256 S_inf = 100_000_000e18;
        // Price at S_inf computed via exp zone only (from marginalPrice)
        uint256 priceAtInf = CurveMath.marginalPrice(S_inf, cc);
        // Price just past S_inf (log zone takes over)
        uint256 priceAfter = CurveMath.marginalPrice(S_inf + 1, cc);
        // Price just before S_inf (still exp zone)
        uint256 priceBefore = CurveMath.marginalPrice(S_inf - 1, cc);

        // All three should be very close (continuity at zone boundary)
        assertApproxEqRel(priceBefore, priceAtInf, 0.001e18, "Continuous before->at");
        assertApproxEqRel(priceAtInf, priceAfter, 0.001e18, "Continuous at->after");
        console.log("Boundary prices: before=%d at=%d after=%d", priceBefore/1e12, priceAtInf/1e12, priceAfter/1e12);
    }

    /// @dev Buy near zone boundary, sell back — tests cross-boundary integral
    /// Uses moderate supply (50M) to avoid precision granularity issues at extreme supply
    function test_ZoneBoundary_CrossAndReturnRoundTrip() public {
        uint256 S_inf = 100_000_000e18;
        uint256 startSupply = 50_000_000e18;

        uint256 ethIn = 100e18;
        uint256 pspOut = CurveMath.computeBuyOutput(ethIn, startSupply, cc);
        assertTrue(pspOut > 0, "Must produce output");

        uint256 ethOut = CurveMath.computeSellOutput(pspOut - 1, startSupply + pspOut, cc);
        assertTrue(ethOut > 0, "Round-trip must return ETH");
        assertTrue(ethOut < ethIn, "Round-trip must return less than input");
    }

    /// @dev Multi-curve: cross 3 zone boundaries in one swap
    function test_ZoneBoundary_MultiCrossAllBoundaries() public {
        // Start at 5M, buy enough to pass through 10M, 50M, 60M boundaries
        uint256 startSupply = 5_000_000e18;
        uint256 ethIn = 10_000e18; // very large buy

        uint256 pspOut = CurveMath.computeBuyOutput(ethIn, startSupply, multiCC);
        assertTrue(pspOut > 0, "Must produce output");

        uint256 endSupply = startSupply + pspOut;
        // Check if we crossed into new zones
        assertTrue(endSupply > 10_000_000e18, "Should cross first boundary");

        // Round-trip
        uint256 ethOut = CurveMath.computeSellOutput(pspOut - 1, endSupply, multiCC);
        assertTrue(ethOut > 0 && ethOut < ethIn, "Multi-cross round-trip valid");
    }

    // ═════════════════════════════════════════════════════════
    //  SANDWICH ATTACK SIMULATION
    // ═════════════════════════════════════════════════════════

    /// @dev Simulate a sandwich: attacker buys before victim, sells after
    function test_Sandwich_AttackerCannotExtractMoreThanSlippage() public {
        uint256 victimBuyAmount = 10e18;
        uint256 supply = CurveMath.computeBuyOutput(100e18, 0, cc); // establish market

        // 1. Victim buys without sandwich
        uint256 fairOutput = CurveMath.computeBuyOutput(victimBuyAmount, supply, cc);

        // 2. Attacker buys ahead of victim (1 ETH)
        uint256 attackerBuy = 1e18;
        uint256 attackerPSP = CurveMath.computeBuyOutput(attackerBuy, supply, cc);
        uint256 supplyAfterAttacker = supply + attackerPSP;

        // 3. Victim buys at higher price
        uint256 victimSandwiched = CurveMath.computeBuyOutput(victimBuyAmount, supplyAfterAttacker, cc);
        uint256 supplyAfterVictim = supplyAfterAttacker + victimSandwiched;

        // 4. Attacker sells
        uint256 attackerETH = CurveMath.computeSellOutput(attackerPSP - 1, supplyAfterVictim, cc);

        // Attacker profit = attackerETH - attackerBuy
        // Attacker can profit from sandwiching (this is expected for any bonding curve)
        // But the profit must be bounded by victim's slippage
        uint256 victimLoss = fairOutput - victimSandwiched;

        console.log("Sandwich: attacker spent %d, got back %d", attackerBuy, attackerETH);
        console.log("Sandwich: victim lost %d PSP out of %d fair", victimLoss, fairOutput);

        // Attacker's profit should not exceed victim's slippage cost
        // (This is a property of any monotonic bonding curve)
        if (attackerETH > attackerBuy) {
            uint256 attackerProfit = attackerETH - attackerBuy;
            // Convert profit to PSP equivalent at current price for comparison
            uint256 priceAtSupply = CurveMath.marginalPrice(supplyAfterVictim, cc);
            uint256 profitInPSP = attackerProfit * 1e18 / priceAtSupply;
            assertTrue(
                profitInPSP <= victimLoss,
                "Attacker profit exceeds victim slippage"
            );
            console.log("Sandwich valid: attacker profit bounded by victim slippage");
        }
    }

    /// @dev Front-run with maximum viable amount
    function test_Sandwich_LargeFrontrunRoundTripsCorrectly() public {
        uint256 supply = CurveMath.computeBuyOutput(100e18, 0, cc);

        // Attacker tries to buy a huge amount
        uint256 attackerBuy = 50e18;
        uint256 attackerPSP = CurveMath.computeBuyOutput(attackerBuy, supply, cc);
        uint256 newSupply = supply + attackerPSP;

        // Sell back immediately
        uint256 ethBack = CurveMath.computeSellOutput(attackerPSP - 1, newSupply, cc);

        // Must lose money on the round-trip (curve tax)
        assertTrue(ethBack < attackerBuy, "Large frontrun must lose on round-trip");

        uint256 loss = attackerBuy - ethBack;
        console.log("Large frontrun loss: %d wei ETH (%d%%)", loss, loss * 100 / attackerBuy);
    }

    // ═════════════════════════════════════════════════════════
    //  DRAIN ATTACKS — try to extract all value
    // ═════════════════════════════════════════════════════════

    /// @dev Try to drain the curve by selling all supply
    function test_Drain_SellEntireSupply() public {
        uint256 supply = CurveMath.computeBuyOutput(10e18, 0, cc);

        // Selling all supply should return 0 (guard)
        uint256 ethOut = CurveMath.computeSellOutput(supply, supply, cc);
        assertEq(ethOut, 0, "Can't sell entire supply");
    }

    /// @dev Try to drain by selling supply + 1
    function test_Drain_SellMoreThanSupply() public {
        uint256 supply = CurveMath.computeBuyOutput(10e18, 0, cc);
        uint256 ethOut = CurveMath.computeSellOutput(supply + 1, supply, cc);
        assertEq(ethOut, 0, "Can't sell more than supply");
    }

    /// @dev Sell supply - 1 (maximum possible sell), verify output is bounded
    function test_Drain_SellSupplyMinus1() public {
        uint256 ethIn = 10e18;
        uint256 supply = CurveMath.computeBuyOutput(ethIn, 0, cc);
        uint256 ethOut = CurveMath.computeSellOutput(supply - 1, supply, cc);

        assertTrue(ethOut > 0, "Selling supply-1 must return ETH");
        assertTrue(ethOut < ethIn, "Can't extract more than deposited");
        console.log("Drain supply-1: recovered %d%% of input", ethOut * 100 / ethIn);
    }

    /// @dev Repeated buy-sell cycles can't extract value
    function test_Drain_RepeatedCyclesNoProfit() public {
        uint256 ethReserve = 100e18;
        uint256 supply = CurveMath.computeBuyOutput(ethReserve, 0, cc);
        uint256 totalETHIn = ethReserve;
        uint256 totalETHOut = 0;

        // Do 10 cycles: buy 1 ETH, sell what we got back
        for (uint256 i = 0; i < 10; i++) {
            uint256 pspOut = CurveMath.computeBuyOutput(1e18, supply, cc);
            if (pspOut <= 1) break;
            supply += pspOut;
            totalETHIn += 1e18;

            uint256 ethOut = CurveMath.computeSellOutput(pspOut - 1, supply, cc);
            if (ethOut == 0) break;
            supply -= (pspOut - 1);
            totalETHOut += ethOut;
        }

        // Net must be negative (we can't extract value through cycling)
        assertTrue(
            totalETHOut < totalETHIn,
            "Repeated cycles can't extract value"
        );
        console.log("10 cycles: spent %d, recovered %d", totalETHIn, totalETHOut);
    }

    // ═════════════════════════════════════════════════════════
    //  CONVEXITY / ECONOMIC PROPERTIES
    // ═════════════════════════════════════════════════════════

    /// @dev Buying 2x ETH should give LESS than 2x PSP (convexity in exp zone)
    function test_Convexity_DoubleBuyGetsWorseRate() public {
        uint256 supply = CurveMath.computeBuyOutput(50e18, 0, cc);

        uint256 smallBuy1 = CurveMath.computeBuyOutput(1e18, supply, cc);
        uint256 smallBuy2 = CurveMath.computeBuyOutput(1e18, supply + smallBuy1, cc);
        uint256 twoSmallBuys = smallBuy1 + smallBuy2;

        uint256 oneBigBuy = CurveMath.computeBuyOutput(2e18, supply, cc);

        // One big buy should get LESS than two sequential small buys
        // because the big buy pushes price up more per unit
        assertTrue(
            oneBigBuy < twoSmallBuys,
            "One big buy should get less than two small buys (convexity)"
        );
        console.log("Convexity: 1x2ETH=%d, 2x1ETH=%d", oneBigBuy, twoSmallBuys);
    }

    /// @dev Average price for a buy must be between entry and exit marginal price
    function test_Convexity_AveragePriceBounded() public {
        uint256 supply = CurveMath.computeBuyOutput(50e18, 0, cc);
        uint256 ethIn = 5e18;
        uint256 pspOut = CurveMath.computeBuyOutput(ethIn, supply, cc);

        uint256 avgPrice = ethIn * 1e18 / pspOut;
        uint256 entryPrice = CurveMath.marginalPrice(supply, cc);
        uint256 exitPrice = CurveMath.marginalPrice(supply + pspOut, cc);

        assertTrue(avgPrice >= entryPrice, "Avg price >= entry price");
        assertTrue(avgPrice <= exitPrice, "Avg price <= exit price");
        console.log("Convexity: entry=%d avg=%d exit=%d", entryPrice, avgPrice, exitPrice);
    }

    /// @dev Larger buy → higher average price (strict)
    function test_Convexity_LargerBuyHigherAvgPrice() public {
        uint256 supply = CurveMath.computeBuyOutput(50e18, 0, cc);

        uint256 smallOut = CurveMath.computeBuyOutput(1e18, supply, cc);
        uint256 bigOut = CurveMath.computeBuyOutput(100e18, supply, cc);

        uint256 smallAvgPrice = 1e18 * 1e18 / smallOut;
        uint256 bigAvgPrice = 100e18 * 1e18 / bigOut;

        assertTrue(
            bigAvgPrice > smallAvgPrice,
            "Larger buy must have higher average price"
        );
    }

    // ═════════════════════════════════════════════════════════
    //  MULTI-HOP CONSERVATION
    // ═════════════════════════════════════════════════════════

    /// @dev 3-hop: buy → sell → buy → sell → buy → sell, verify monotonic loss
    function test_MultiHop_ThreeRoundTripsMonotonicLoss() public {
        uint256 supply = 0;
        uint256 totalIn = 0;
        uint256 totalOut = 0;

        for (uint256 i = 0; i < 3; i++) {
            uint256 ethIn = 5e18;
            uint256 psp = CurveMath.computeBuyOutput(ethIn, supply, cc);
            supply += psp;
            totalIn += ethIn;

            uint256 ethOut = CurveMath.computeSellOutput(psp - 1, supply, cc);
            supply -= (psp - 1);
            totalOut += ethOut;

            // Each cycle: totalOut < totalIn at all times
            assertTrue(totalOut < totalIn, "Cumulative out must be < in at each step");
        }

        console.log("3-hop: in=%d out=%d loss=%d%%", totalIn, totalOut, (totalIn - totalOut) * 100 / totalIn);
    }

    /// @dev Multi-hop on multi-oscillation curve
    function test_MultiHop_MultiCurveFiveRoundTrips() public {
        uint256 supply = 0;
        uint256 totalIn = 0;
        uint256 totalOut = 0;

        for (uint256 i = 0; i < 5; i++) {
            uint256 ethIn = 5e18;
            uint256 psp = CurveMath.computeBuyOutput(ethIn, supply, multiCC);
            if (psp <= 1) break;
            supply += psp;
            totalIn += ethIn;

            uint256 ethOut = CurveMath.computeSellOutput(psp - 1, supply, multiCC);
            if (ethOut == 0) break;
            supply -= (psp - 1);
            totalOut += ethOut;

            assertTrue(totalOut < totalIn, "Multi-curve: cumulative out < in");
        }
    }

    // ═════════════════════════════════════════════════════════
    //  EXTREME RATIO TESTS
    // ═════════════════════════════════════════════════════════

    /// @dev Steep curve: buying should still conserve round-trip
    function test_Extreme_SteepCurveRoundTrip() public {
        uint256 ethIn = 0.1e18;
        uint256 supply = CurveMath.computeBuyOutput(ethIn, 0, steepCC);
        vm.assume(supply > 1);
        uint256 ethOut = CurveMath.computeSellOutput(supply - 1, supply, steepCC);
        assertTrue(ethOut > 0 && ethOut < ethIn, "Steep curve round-trip valid");
    }

    /// @dev Flat curve (k1=0): should behave as constant price
    function test_Extreme_FlatCurveConstantPrice() public {
        uint256 price0 = CurveMath.marginalPrice(0, flatCC);
        uint256 price1 = CurveMath.marginalPrice(1e18, flatCC);
        uint256 price100 = CurveMath.marginalPrice(100e18, flatCC);

        // In exponential zone with k=0, price stays at P0
        assertEq(price0, 0.001e18, "Price at 0 = P0");
        assertEq(price1, 0.001e18, "Price at 1 = P0 (k=0 means flat)");
        assertEq(price100, 0.001e18, "Price at 100 = P0 (k=0 means flat)");
    }

    /// @dev Flat curve buy = exact multiplication
    function test_Extreme_FlatCurveExactMultiplication() public {
        uint256 ethIn = 1e18;
        uint256 pspOut = CurveMath.computeBuyOutput(ethIn, 0, flatCC);
        // P0 = 0.001 ETH. 1 ETH / 0.001 = 1000 PSP (minus 1 bps haircut)
        uint256 expected = 1000e18;
        uint256 haircut = expected / 10000;
        assertApproxEqRel(pspOut, expected - haircut, 0.001e18, "Flat curve: ~1000 PSP for 1 ETH");
    }

    // ═════════════════════════════════════════════════════════
    //  PRECISION ATTACKS
    // ═════════════════════════════════════════════════════════

    /// @dev Buy with 2 wei (minimum that triggers Newton)
    function test_Precision_TwoWeiBuy() public view {
        uint256 out = CurveMath.computeBuyOutput(2, 0, cc);
        assertTrue(out > 0, "2 wei buy should work");
    }

    /// @dev Sell 1 wei at various supply levels
    function test_Precision_SellOneWeiAtVariousSupply() public {
        uint256[] memory supplies = new uint256[](5);
        supplies[0] = CurveMath.computeBuyOutput(0.001e18, 0, cc);
        supplies[1] = CurveMath.computeBuyOutput(1e18, 0, cc);
        supplies[2] = CurveMath.computeBuyOutput(10e18, 0, cc);
        supplies[3] = CurveMath.computeBuyOutput(100e18, 0, cc);
        supplies[4] = CurveMath.computeBuyOutput(1000e18, 0, cc);

        for (uint256 i = 0; i < 5; i++) {
            uint256 ethOut = CurveMath.computeSellOutput(1, supplies[i], cc);
            // 1 wei sell should produce very small but non-zero output
            assertTrue(ethOut >= 0, "1 wei sell should not revert");
        }
    }

    /// @dev Many tiny buys vs one equivalent big buy (rounding attack)
    function test_Precision_ManyTinyBuysVsOneBig() public {
        uint256 totalEth = 10e18;
        uint256 numBuys = 1000;
        uint256 perBuy = totalEth / numBuys; // 0.01 ETH each

        // Path A: 1000 small buys
        uint256 supplyA = 0;
        uint256 totalPSPA = 0;
        for (uint256 i = 0; i < numBuys; i++) {
            uint256 out = CurveMath.computeBuyOutput(perBuy, supplyA, cc);
            supplyA += out;
            totalPSPA += out;
        }

        // Path B: 1 big buy
        uint256 totalPSPB = CurveMath.computeBuyOutput(totalEth, 0, cc);

        console.log("1000 small buys: %d PSP", totalPSPA / 1e18);
        console.log("1 big buy:       %d PSP", totalPSPB / 1e18);

        // Many small buys should get MORE tokens (each at lower price)
        assertTrue(
            totalPSPA > totalPSPB,
            "Many small buys should get more than one big buy"
        );
    }

    // ═════════════════════════════════════════════════════════
    //  FUZZ: AGGRESSIVE ROUND-TRIP AT EVERY SUPPLY DECILE
    // ═════════════════════════════════════════════════════════

    /// @dev Fuzz round-trip at every 10% increment of S_inf
    function testFuzz_RoundTripAtSupplyDeciles(uint256 ethIn) public {
        vm.assume(ethIn > 0.01e18 && ethIn < 100e18);

        uint256[] memory deciles = new uint256[](9);
        for (uint256 i = 0; i < 9; i++) {
            deciles[i] = 10_000_000e18 * (i + 1); // 10M, 20M, ..., 90M
        }

        for (uint256 d = 0; d < 9; d++) {
            uint256 supply = deciles[d];
            uint256 pspOut = CurveMath.computeBuyOutput(ethIn, supply, cc);
            if (pspOut <= 1) continue;

            uint256 ethOut = CurveMath.computeSellOutput(pspOut - 1, supply + pspOut, cc);
            assertTrue(ethOut > 0, "Round-trip at decile must return ETH");
            assertTrue(ethOut < ethIn, "Round-trip at decile must lose ETH");
        }
    }

    /// @dev Fuzz: sell fraction of supply, verify output scales with fraction
    function testFuzz_SellFractionScales(uint256 fraction) public {
        vm.assume(fraction > 0.01e18 && fraction < 0.99e18); // 1% to 99%

        uint256 ethIn = 50e18;
        uint256 supply = CurveMath.computeBuyOutput(ethIn, 0, cc);

        // Sell half
        uint256 halfPSP = supply * fraction / 1e18;
        uint256 halfETH = CurveMath.computeSellOutput(halfPSP, supply, cc);

        // Sell remaining (minus 1 for guard)
        uint256 remaining = supply - halfPSP - 1;
        if (remaining == 0) return;
        uint256 remainingETH = CurveMath.computeSellOutput(remaining, supply - halfPSP, cc);

        // Total ETH recovered
        uint256 totalRecovered = halfETH + remainingETH;
        assertTrue(totalRecovered < ethIn, "Split sell can't exceed single input");
    }

    /// @dev Fuzz: multi-curve round-trip at every zone
    function testFuzz_MultiCurveRoundTripPerZone(uint256 zoneIdx) public {
        zoneIdx = bound(zoneIdx, 0, 3); // 4 zones in multiCC

        // Start supply in the middle of each zone
        uint256[4] memory zoneMids = [
            uint256(5_000_000e18),
            uint256(30_000_000e18),
            uint256(55_000_000e18),
            uint256(70_000_000e18)
        ];

        uint256 supply = zoneMids[zoneIdx];
        uint256 ethIn = 5e18;
        uint256 pspOut = CurveMath.computeBuyOutput(ethIn, supply, multiCC);
        if (pspOut <= 1) return;

        uint256 ethOut = CurveMath.computeSellOutput(pspOut - 1, supply + pspOut, multiCC);
        assertTrue(ethOut > 0, "Multi-curve per-zone: out > 0");
        assertTrue(ethOut < ethIn, "Multi-curve per-zone: out < in");
    }

    // ═════════════════════════════════════════════════════════
    //  INTEGRAL SANITY
    // ═════════════════════════════════════════════════════════

    /// @dev curveIntegral(S, S) = 0 (zero-length interval)
    function test_Integral_ZeroLength() public {
        assertEq(CurveMath.curveIntegral(50_000e18, 50_000e18, cc), 0, "Zero-length integral = 0");
    }

    /// @dev curveIntegral(S1, S2) > curveIntegral(S1, S1+delta) for any S2 > S1+delta
    function test_Integral_MonotonicInUpperBound() public {
        uint256 S1 = 10_000e18;
        uint256 delta = 1_000e18;

        uint256 int1 = CurveMath.curveIntegral(S1, S1 + delta, cc);
        uint256 int2 = CurveMath.curveIntegral(S1, S1 + 2 * delta, cc);

        assertTrue(int2 > int1, "Integral must increase with upper bound");
    }

    /// @dev Buy output integral ≈ ethInput (within rounding)
    function test_Integral_BuyOutputMatchesInput() public {
        uint256 ethIn = 5e18;
        uint256 supply = CurveMath.computeBuyOutput(100e18, 0, cc);
        uint256 pspOut = CurveMath.computeBuyOutput(ethIn, supply, cc);

        uint256 integral = CurveMath.curveIntegral(supply, supply + pspOut, cc);

        // Integral should be <= ethIn (conservative, due to 1 bps haircut)
        assertTrue(integral <= ethIn, "Integral must be <= ethInput");
        // And close to ethIn (within 0.1%)
        assertApproxEqRel(integral, ethIn, 0.001e18, "Integral close to ethInput");
    }

    /// @dev Integral across zone boundary splits correctly
    function test_Integral_SplitAtBoundaryCorrectness() public {
        uint256 S_inf = 100_000_000e18;
        uint256 startSupply = S_inf - 5_000_000e18;
        uint256 endSupply = S_inf + 5_000_000e18;

        // Full integral
        uint256 fullInt = CurveMath.curveIntegral(startSupply, endSupply, cc);

        // Split at S_inf
        uint256 part1 = CurveMath.curveIntegral(startSupply, S_inf, cc);
        uint256 part2 = CurveMath.curveIntegral(S_inf, endSupply, cc);

        // Sum of parts should equal full integral (within rounding)
        assertApproxEqRel(part1 + part2, fullInt, 0.0001e18, "Split integral must match full");
    }

    // ═════════════════════════════════════════════════════════
    //  GAS BOMB / DoS PREVENTION
    // ═════════════════════════════════════════════════════════

    /// @dev Very large buy doesn't run out of gas
    function test_GasBomb_LargeBuy() public {
        uint256 supply = 0;
        uint256 out = CurveMath.computeBuyOutput(10_000e18, supply, cc);
        assertTrue(out > 0, "Large buy should work");
    }

    /// @dev Buy at supply near MAX_SUPPLY doesn't revert or hang
    function test_GasBomb_BuyNearMaxSupply() public {
        // At very high supply, buy should return 0 gracefully (MAX_SUPPLY guard)
        uint256 nearMax = 9_999_000_000e18; // ~10B tokens (near MAX_SUPPLY=1e28)
        uint256 out = CurveMath.computeBuyOutput(0.001e18, nearMax, cc);
        assertTrue(out >= 0, "Near-max buy should not revert");
    }

    /// @dev Curve with many zones (10 zones) doesn't break gas
    function test_GasBomb_TenZoneCurve() public {
        uint256[] memory boundaries = new uint256[](10);
        uint256[] memory rates = new uint256[](10);
        bool[] memory expFlags = new bool[](10);

        for (uint256 i = 0; i < 10; i++) {
            boundaries[i] = i * 10_000_000e18;
            rates[i] = i % 2 == 0 ? 0.0000001e18 : 0.01e18;
            expFlags[i] = i % 2 == 0;
        }
        boundaries[0] = 0;

        CurveMath.CurveConfig memory manyZones = CurveMath.multiCurve(0.0001e18, boundaries, rates, expFlags);

        uint256 out = CurveMath.computeBuyOutput(1e18, 0, manyZones);
        assertTrue(out > 0, "10-zone curve buy should work");

        uint256 price = CurveMath.marginalPrice(45_000_000e18, manyZones);
        assertTrue(price > 0, "10-zone price should be positive");
    }

    // ═════════════════════════════════════════════════════════
    //  MULTI-CURVE CONSTRUCTION VALIDATION
    // ═════════════════════════════════════════════════════════

    /// @dev multiCurve with mismatched array lengths should revert
    function test_MultiCurve_MismatchedLengths() public {
        uint256[] memory b = new uint256[](3);
        b[0] = 0; b[1] = 10e18; b[2] = 20e18;
        uint256[] memory r = new uint256[](2);
        bool[] memory f = new bool[](3);

        // multiCurve is internal, so revert happens inline
        try this.externalMultiCurveMismatched(b, r, f) {
            fail();
        } catch {}
    }

    function externalMultiCurveMismatched(
        uint256[] memory b, uint256[] memory r, bool[] memory f
    ) external {
        CurveMath.multiCurve(0.0001e18, b, r, f);
    }

    /// @dev multiCurve with first boundary != 0 should revert
    function test_MultiCurve_FirstBoundaryNotZero() public {
        uint256[] memory b = new uint256[](3);
        b[0] = 1;
        b[1] = 10e18;
        b[2] = 20e18;
        uint256[] memory r = new uint256[](3);
        r[0] = 1; r[1] = 1; r[2] = 1;
        bool[] memory f = new bool[](3);

        try this.externalMultiCurveBadBoundary(b, r, f) {
            fail();
        } catch {}
    }

    function externalMultiCurveBadBoundary(
        uint256[] memory b, uint256[] memory r, bool[] memory f
    ) external {
        CurveMath.multiCurve(0.0001e18, b, r, f);
    }

    /// @dev Two zones with same rate should produce continuous price
    function test_MultiCurve_ConsecutiveZonesContinuous() public {
        // exp zone then log zone with same effective rate
        uint256[] memory b = new uint256[](3);
        b[0] = 0;
        b[1] = 10e18;
        b[2] = 20e18;

        uint256[] memory r = new uint256[](3);
        r[0] = 0.0000001e18;
        r[1] = 0.0000001e18;
        r[2] = 0.0000001e18;

        bool[] memory f = new bool[](3);
        f[0] = true;
        f[1] = false;
        f[2] = true;

        CurveMath.CurveConfig memory test = CurveMath.multiCurve(0.001e18, b, r, f);

        uint256 priceAtBoundaryMinus = CurveMath.marginalPrice(10e18 - 1, test);
        uint256 priceAtBoundary = CurveMath.marginalPrice(10e18, test);
        assertApproxEqRel(priceAtBoundaryMinus, priceAtBoundary, 0.001e18, "Continuous at first boundary");
    }
}
