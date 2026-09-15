// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RealV4Base} from "./RealV4Lifecycle.t.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {ISineV3Math} from "../src/interfaces/ISineV3Math.sol";

/// @title Sell quote and real-V4 execution parity
contract SellQuoteParityTest is RealV4Base {
    function _buy() private returns (uint256 bought) {
        mixETH.approve(address(zapIn), 1e18);
        bought = zapIn.buyWithMix(poolKey, 1e18, 1, block.timestamp);
        pspToken.approve(address(zapOut), type(uint256).max);
    }

    function test_ActiveSellQuoteMatchesExactMinimumAndFundedSale() public {
        uint256 bought = _buy();
        uint256 quote = hook.getSellOutput(1e12);
        uint256 mixBefore = mixETH.balanceOf(address(this));
        uint256 paid = zapOut.sellToMix(poolKey, 1e12, quote, block.timestamp);
        assertEq(paid, quote);
        assertEq(mixETH.balanceOf(address(this)) - mixBefore, quote);
        uint256 amount = (bought - 1e12) / 2;
        quote = hook.getSellOutput(amount);
        assertEq(zapOut.sellToMix(poolKey, amount, quote, block.timestamp), quote);
    }

    function test_InvalidSellInputsFailBeforeQuoteMath() public {
        _buy();
        vm.expectRevert(CurveHook.SwapTooSmall.selector);
        hook.getSellOutput(0);
        vm.expectRevert(CurveHook.SwapTooSmall.selector);
        hook.getSellOutput(1e12 - 1);
        vm.expectRevert();
        zapOut.sellToMix(poolKey, 1e12 - 1, 0, block.timestamp);
        vm.expectRevert(CurveHook.SwapTooLarge.selector);
        hook.getSellOutput(uint256(uint128(type(int128).max)) + 1);
        uint256 supply = hook.totalSupplyPSP();
        vm.expectRevert(CurveHook.SellExceedsSupply.selector);
        hook.getSellOutput(supply);
        vm.expectRevert(CurveHook.SellExceedsSupply.selector);
        hook.getSellOutput(supply + 1);
    }

    function test_ZeroAndOversizedOutputsRejectQuotesAndExecution() public {
        _buy();
        uint256 reserveBefore = hook.reserveMixETH();
        uint256 supplyBefore = hook.totalSupplyPSP();
        uint256 ownerPspBefore = pspToken.balanceOf(address(this));
        bytes memory selector = abi.encodeWithSelector(ISineV3Math.sellOut.selector);
        vm.mockCall(hook.sineV3Table(), selector, abi.encode(uint256(0)));
        vm.expectRevert(CurveHook.ZeroOutput.selector);
        hook.getSellOutput(1e12);
        vm.expectRevert();
        zapOut.sellToMix(poolKey, 1e12, 0, block.timestamp);
        vm.mockCall(hook.sineV3Table(), selector, abi.encode(uint256(uint128(type(int128).max)) * 2));
        vm.expectRevert(CurveHook.SwapTooLarge.selector);
        hook.getSellOutput(1e12);
        vm.expectRevert();
        zapOut.sellToMix(poolKey, 1e12, 0, block.timestamp);
        vm.clearMockedCalls();
        assertEq(hook.reserveMixETH(), reserveBefore);
        assertEq(hook.totalSupplyPSP(), supplyBefore);
        assertEq(pspToken.balanceOf(address(this)), ownerPspBefore);
    }

    function test_ClockFlatAndDestroyedQuoteStatesMatchRoute() public {
        uint256 bought = _buy();
        vm.warp(hook.detonationAt());
        vm.expectRevert(CurveHook.TradingHalted.selector);
        hook.getSellOutput(1e12);
        vm.expectRevert();
        zapOut.sellToMix(poolKey, 1e12, 0, block.timestamp);
        controller.detonate{gas: 2_000_000}();
        uint256 quote = hook.getSellOutput(bought / 2);
        assertEq(zapOut.sellToMix(poolKey, bought / 2, quote, block.timestamp), quote);
        uint256 supply = hook.totalSupplyPSP();
        vm.expectRevert(CurveHook.SellExceedsSupply.selector);
        hook.getSellOutput(supply);
        vm.prank(address(controller));
        hook.setMode(CurveHook.Mode.Destroyed);
        vm.expectRevert(CurveHook.NotActive.selector);
        hook.getSellOutput(1e12);
        vm.expectRevert();
        zapOut.sellToMix(poolKey, 1e12, 0, block.timestamp);
    }

    function test_PredepositQuoteUsesNotActive() public {
        vm.warp(hook.detonationAt());
        controller.detonate{gas: 2_000_000}();
        factory.reserveSpawn(factory.currentRoundId());
        for (uint256 i; i < 3; ++i) {
            factory.birthStep();
        }
        PSPFactory.Round memory next = factory.getRound(factory.currentRoundId());
        assertEq(uint8(next.hook.mode()), uint8(CurveHook.Mode.Predeposit));
        vm.expectRevert(CurveHook.NotActive.selector);
        next.hook.getSellOutput(1e12);
    }
}
