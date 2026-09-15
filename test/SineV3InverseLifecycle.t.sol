// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RealV4Base} from "./RealV4Lifecycle.t.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ISineV3Math} from "../src/interfaces/ISineV3Math.sol";
import {SineV3SellFixtures} from "./SineV3SellFixtures.sol";

/// @title SineV3InverseLifecycleTest
/// @notice Check a small sale after a funded launch and buy through real V4.
contract SineV3InverseLifecycleTest is RealV4Base {
    function test_RealV4SmallSaleAtWave63PaysCompleteCurveOutput() public {
        // Create a successor with the small launch from the review counterexample.
        vm.warp(hook.detonationAt());
        controller.detonate{gas: 2_000_000}();
        factory.reserveSpawn(factory.currentRoundId());
        for (uint256 i; i < 3; ++i) {
            factory.birthStep();
        }
        PSPFactory.Round memory next = factory.getRound(factory.currentRoundId());
        controller = next.controller;
        pspToken = next.token;
        hook = next.hook;

        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(address(pspToken));
        if (c0 > c1) (c0, c1) = (c1, c0);
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: hook});

        uint256 grossDeposit = 1_111_111_111_111;
        mixETH.approve(address(controller), grossDeposit);
        controller.predeposit(grossDeposit);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        assertEq(hook.reserveMixETH(), 1e12);

        uint256 grossBuy = 3_151_339_221_488_046_750;
        mixETH.approve(address(zapIn), grossBuy);
        zapIn.buyWithMix(poolKey, grossBuy, 1, block.timestamp + 1 hours);
        uint256 reserveBefore = 2_836_206_299_339_242_075;
        assertEq(hook.reserveMixETH(), reserveBefore);
        (uint256 boot, uint256 lam,,) = hook.sineV3();
        assertEq(reserveBefore, boot + 63 * lam);

        uint256 pspIn = 1e12;
        assertGe(pspToken.balanceOf(address(this)), pspIn);
        SineV3SellFixtures.Row memory fixture = SineV3SellFixtures.rows()[2];
        uint256 expectedGross = ISineV3Math(hook.sineV3Table()).sellOut(reserveBefore, boot, lam, 75e12, pspIn);
        // Independent tanh-sinh reference, plus the reserve value of one
        // rounded PSP wei and the required relative integral tolerance.
        assertApproxEqAbs(expectedGross, fixture.grossOut, fixture.grossOut / 1e9 + 1693);
        uint256 expectedFee = expectedGross * 250 / 10_000;
        uint256 expectedNet = expectedGross - expectedFee;
        assertEq(hook.swapFeeBps(), 250);
        assertEq(hook.getSellOutput(pspIn), expectedNet);

        uint256 mixBefore = mixETH.balanceOf(address(this));
        pspToken.approve(address(zapOut), pspIn);
        uint256 gasBefore = gasleft();
        uint256 paid = zapOut.sellToMix(poolKey, pspIn, expectedNet, block.timestamp + 1 hours);
        uint256 sellGas = gasBefore - gasleft();

        assertEq(paid, expectedNet);
        assertEq(mixETH.balanceOf(address(this)) - mixBefore, expectedNet);
        assertEq(hook.reserveMixETH(), reserveBefore - expectedGross);
        assertLt(sellGas, 12_000_000, "small-sale inverse exceeds the transaction gas budget");
        emit log_named_uint("real V4 small-sale gas", sellGas);
    }
}
