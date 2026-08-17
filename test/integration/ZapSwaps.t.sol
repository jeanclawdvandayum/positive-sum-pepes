// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {PSPFactory} from "../../src/PSPFactory.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {RoundController} from "../../src/RoundController.sol";
import {PSPToken} from "../../src/PSPToken.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../src/PSPZapOut.sol";
import {IMixETH} from "../../src/interfaces/IMixETH.sol";

import {MainnetConfig} from "./MainnetConfig.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";

/// @title ZapSwapsTest — the ETH <-> PSP round trip on a real V4
///        PoolManager with real curve pricing. Alice never holds mixETH:
///        she enters with ETH via PSPZapIn and exits to ETH via PSPZapOut.
contract ZapSwapsTest is Test {
    IPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;
    PSPZapIn zapIn;
    PSPZapOut zapOut;

    RoundController controller;
    PSPToken pspToken;
    CurveHook hook;
    PoolKey poolKey;

    address alice = makeAddr("psp-zap-alice-x7749"); // ETH-only user
    address bob = makeAddr("psp-zap-bob-x7749"); // mixETH user (bootstraps the round)

    function setUp() public {
        uint256 forkBlock = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
        if (forkBlock > 0) {
            vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);
        } else {
            vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        }

        poolManager = IPoolManager(MainnetConfig.POOL_MANAGER);
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();

        factory = new PSPFactory(
            poolManager, IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer()
        );
        zapIn = new PSPZapIn(IMixETH(address(mixETH)), poolManager);
        zapOut = new PSPZapOut(IMixETH(address(mixETH)), poolManager);

        // Deploy a round
        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
        });
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory round = factory.getRound(roundId);
        controller = round.controller;
        pspToken = round.token;
        hook = round.hook;

        // Pool key, sorted like the factory builds it
        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(address(pspToken));
        if (c0 > c1) (c0, c1) = (c1, c0);
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: hook});

        // Bob bootstraps: predeposit + launch
        mixETH.transfer(bob, 100e18);
        vm.startPrank(bob);
        mixETH.approve(address(controller), 100e18);
        controller.predeposit(100e18);
        vm.stopPrank();

        vm.prank(address(factory));
        controller.launchPooledBuy();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Zap in: ETH -> mixETH -> curve swap -> PSP
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_ZapInBuyETHToPSP() public {
        vm.deal(alice, 5e18);
        vm.prank(alice);
        uint256 pspOut = zapIn.zapInBuy{value: 5e18}(poolKey, 1, 0);

        assertGt(pspOut, 0, "PSP out");
        assertEq(pspToken.balanceOf(alice), pspOut, "alice holds the PSP");
        assertEq(pspToken.balanceOf(address(zapIn)), 0, "zap holds no PSP");
        assertEq(mixETH.balanceOf(address(zapIn)), 0, "zap holds no mixETH");
        assertEq(alice.balance, 0, "all ETH spent");
    }

    function test_Fork_ZapInBuySlippageReverts() public {
        vm.deal(alice, 5e18);
        vm.prank(alice);
        vm.expectRevert(PSPZapIn.InsufficientOutput.selector);
        zapIn.zapInBuy{value: 5e18}(poolKey, type(uint256).max, 0);
    }

    function test_Fork_ZapInBuyDeadlineReverts() public {
        vm.deal(alice, 5e18);
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vm.expectRevert(PSPZapIn.Expired.selector);
        zapIn.zapInBuy{value: 5e18}(poolKey, 1, block.timestamp - 1);
    }

    function test_Fork_ZapInBuyBadPoolReverts() public {
        // mixETH on both sides
        PoolKey memory bad = PoolKey({
            currency0: Currency.wrap(address(mixETH)),
            currency1: Currency.wrap(address(mixETH)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: hook
        });
        vm.deal(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(PSPZapIn.BadPool.selector);
        zapIn.zapInBuy{value: 1e18}(bad, 1, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Zap out: PSP -> curve swap -> mixETH -> redeem -> ETH
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_ZapOutPSPToETH() public {
        // Alice enters with ETH...
        vm.deal(alice, 5e18);
        vm.prank(alice);
        uint256 pspOut = zapIn.zapInBuy{value: 5e18}(poolKey, 1, 0);
        assertGt(pspOut, 0, "setup: bought PSP");

        // ...and exits to ETH in one call
        vm.startPrank(alice);
        pspToken.approve(address(zapOut), pspOut);
        uint256 ethOut = zapOut.zapOut(poolKey, pspOut, 1, 0);
        vm.stopPrank();

        assertGt(ethOut, 0, "ETH out");
        assertGt(alice.balance, 0, "alice got ETH back");
        assertLt(alice.balance, 5e18, "round trip pays the spread");
        assertEq(pspToken.balanceOf(alice), 0, "alice sold everything");
        assertEq(mixETH.balanceOf(address(zapOut)), 0, "zap holds no mixETH");
        assertEq(address(zapOut).balance, 0, "zap holds no ETH");
    }

    function test_Fork_ZapOutSlippageReverts() public {
        vm.deal(alice, 5e18);
        vm.prank(alice);
        uint256 pspOut = zapIn.zapInBuy{value: 5e18}(poolKey, 1, 0);

        vm.startPrank(alice);
        pspToken.approve(address(zapOut), pspOut);
        vm.expectRevert(PSPZapOut.InsufficientOutput.selector);
        zapOut.zapOut(poolKey, pspOut, type(uint256).max, 0);
        vm.stopPrank();

        // Reverted call rolled the whole tx back: alice keeps her PSP,
        // the zap holds nothing (nothing ever left her in a committed state)
        assertEq(pspToken.balanceOf(alice), pspOut, "PSP unchanged by revert");
        assertEq(pspToken.balanceOf(address(zapOut)), 0, "zap holds no PSP");
        assertEq(address(zapOut).balance, 0, "no ETH stuck");
    }

    function test_Fork_ZapOutDeadlineReverts() public {
        vm.deal(alice, 5e18);
        vm.prank(alice);
        uint256 pspOut = zapIn.zapInBuy{value: 5e18}(poolKey, 1, 0);

        vm.warp(block.timestamp + 1);
        vm.startPrank(alice);
        pspToken.approve(address(zapOut), pspOut);
        vm.expectRevert(PSPZapOut.Expired.selector);
        zapOut.zapOut(poolKey, pspOut, 1, block.timestamp - 1);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Raw mixETH legs (no ETH involved)
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_BuyWithMixAndSellToMix() public {
        // bob predeposited everything in setUp; refresh his mixETH
        mixETH.transfer(bob, 10e18);

        // bob buys PSP straight from his mixETH balance
        vm.startPrank(bob);
        mixETH.approve(address(zapIn), 5e18);
        uint256 pspOut = zapIn.buyWithMix(poolKey, 5e18, 1, 0);
        vm.stopPrank();

        assertGt(pspOut, 0, "bob got PSP");
        assertEq(pspToken.balanceOf(bob), pspOut, "PSP with bob");
        assertEq(pspToken.balanceOf(address(zapIn)), 0, "zapIn clean");
        uint256 bobMixAfterBuy = mixETH.balanceOf(bob);

        // ...and sells it back to mixETH in one call
        vm.startPrank(bob);
        pspToken.approve(address(zapOut), pspOut);
        uint256 mixOut = zapOut.sellToMix(poolKey, pspOut, 1, 0);
        vm.stopPrank();

        assertGt(mixOut, 0, "mix out");
        assertEq(mixETH.balanceOf(bob), bobMixAfterBuy + mixOut, "mix credited to bob");
        assertEq(pspToken.balanceOf(bob), 0, "bob sold all PSP");
        assertEq(mixETH.balanceOf(address(zapOut)), 0, "zapOut clean");
        assertEq(address(zapOut).balance, 0, "no ETH involved");
    }

    function test_Fork_SellToMixSlippageReverts() public {
        mixETH.transfer(bob, 10e18);
        vm.startPrank(bob);
        mixETH.approve(address(zapIn), 5e18);
        uint256 pspOut = zapIn.buyWithMix(poolKey, 5e18, 1, 0);

        pspToken.approve(address(zapOut), pspOut);
        vm.expectRevert(PSPZapOut.InsufficientOutput.selector);
        zapOut.sellToMix(poolKey, pspOut, type(uint256).max, 0);
        vm.stopPrank();

        // revert rolled everything back
        assertEq(pspToken.balanceOf(bob), pspOut, "PSP unchanged");
        assertEq(mixETH.balanceOf(address(zapOut)), 0, "zapOut clean");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Access control on the callback
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_UnlockCallbackOnlyPoolManager() public {
        vm.expectRevert(PSPZapIn.NotPoolManager.selector);
        zapIn.unlockCallback("");

        vm.expectRevert(PSPZapOut.NotPoolManager.selector);
        zapOut.unlockCallback("");
    }
}
