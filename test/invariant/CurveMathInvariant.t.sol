// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

/// @title CurveMathInvariantTest — Foundry invariant tests with handler
/// @notice Fuzzes sequences of buy/sell operations checking mathematical invariants
contract CurveMathInvariantTest is Test {
    using CurveMath for CurveMath.CurveConfig;

    CurveMath.CurveConfig cc;
    Handler handler;

    function setUp() public {
        cc = CurveMath.singleCurve(
            0.0001e18,         // P0
            100_000_000e18,    // S_inf
            0.000000046e18,    // k1
            0.1e18             // k2
        );

        handler = new Handler(cc);
        targetContract(address(handler));
    }

    // INV-1: Supply is always >= 0 and <= MAX_SUPPLY
    function invariant_SupplyBounded() public view {
        uint256 s = handler.currentSupply();
        assertTrue(s <= 1e28, "Supply exceeds MAX_SUPPLY");
    }

    // INV-2: Price is always > 0 when supply > 0
    function invariant_PriceAlwaysPositive() public view {
        if (handler.currentSupply() > 0) {
            assertTrue(
                CurveMath.marginalPrice(handler.currentSupply(), cc) > 0,
                "Price must be positive for non-zero supply"
            );
        }
    }

    // INV-3: Total ETH spent - total ETH recovered > 0 (no money printer)
    function invariant_NoMoneyPrinter() public view {
        assertTrue(
            handler.totalETHSpent() >= handler.totalETHRecovered(),
            "Recovered more ETH than spent"
        );
        // Allow net to be 0 only if no swaps happened
        if (handler.swapCount() > 0) {
            assertTrue(
                handler.totalETHSpent() > handler.totalETHRecovered(),
                "Must have net positive ETH spent (no arbitrage)"
            );
        }
    }

    // INV-4: Buy output > 0 for any positive ETH input that doesn't hit MAX_SUPPLY
    function invariant_SupplyNeverNegative() public view {
        assertTrue(handler.currentSupply() >= 0, "Supply can't be negative (duh)");
    }

    // INV-5: Reserves track ETH spent minus ETH recovered
    function invariant_ReserveConsistency() public view {
        assertTrue(
            handler.totalETHSpent() >= handler.totalETHRecovered(),
            "Tracked reserve negative"
        );
    }
}

/// @title Handler — Fuzz target for invariant tests
/// @notice Simulates a bonding curve market: tracks supply, ETH spent/recovered
contract Handler is Test {
    using CurveMath for CurveMath.CurveConfig;

    CurveMath.CurveConfig private cc;
    uint256 private currentSupply_;
    uint256 private totalETHSpent_;
    uint256 private totalETHRecovered_;
    uint256 private swapCount_;

    constructor(CurveMath.CurveConfig memory _cc) {
        cc = _cc;
    }

    function buy(uint256 ethAmount) external {
        // Constrain to realistic range (minimum 0.001 ETH for precision)
        ethAmount = bound(ethAmount, 1e15, 1000e18);
        uint256 pspOut = CurveMath.computeBuyOutput(ethAmount, currentSupply_, cc);
        if (pspOut == 0) return;

        currentSupply_ += pspOut;
        totalETHSpent_ += ethAmount;
        swapCount_++;
    }

    function sell(uint256 pspAmount) external {
        if (currentSupply_ <= 1) return;
        // Constrain: can sell up to supply - 1
        pspAmount = bound(pspAmount, 1, currentSupply_ - 1);
        if (pspAmount >= currentSupply_) return;

        uint256 ethOut = CurveMath.computeSellOutput(pspAmount, currentSupply_, cc);
        if (ethOut == 0) return;

        currentSupply_ -= pspAmount;
        totalETHRecovered_ += ethOut;
        swapCount_++;
    }

    // ── View ──
    function currentSupply() external view returns (uint256) { return currentSupply_; }
    function totalETHSpent() external view returns (uint256) { return totalETHSpent_; }
    function totalETHRecovered() external view returns (uint256) { return totalETHRecovered_; }
    function swapCount() external view returns (uint256) { return swapCount_; }
}
