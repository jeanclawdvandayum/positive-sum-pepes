// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IMixETH} from "../../src/interfaces/IMixETH.sol";

import {PSPFactory} from "../../src/PSPFactory.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../src/PSPZapOut.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @title MockPoolManagerE2E — proves the functional mock executes the REAL
///        v4 swap flow end-to-end (zap → unlock → sync/settle → beforeSwap
///        hook → take) so the anvil lab can actually trade. This is the same
///        path the frontend wallet buttons use.
contract MockPoolManagerE2ETest is Test {
    MockMixETH mixETH;
    MockPoolManager poolManager;
    PSPFactory factory;
    PSPZapIn zapIn;
    PSPZapOut zapOut;
    IERC20 pspToken;
    address controller;
    address hook;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();
        poolManager = new MockPoolManager();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)), IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer()
        , 0);

        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
        });
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory r = factory.getRound(roundId);
        pspToken = r.token;
        controller = address(r.controller);
        hook = address(r.hook);

        zapIn = new PSPZapIn(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));
        zapOut = new PSPZapOut(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));

        // fund users
        vm.deal(alice, 1_000e18);
        vm.deal(bob, 1_000e18);
        mixETH.depositETH{value: 500e18}();
        mixETH.transfer(alice, 200e18);
        mixETH.transfer(bob, 100e18);
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(mixETH)),
            currency1: Currency.wrap(address(pspToken)),
            fee: 0x800000, // hook-flagged
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
    }

    function _launch() internal {
        vm.startPrank(alice);
        mixETH.approve(controller, 60e18);
        // controller.potDeposit-style receiver handles plain transfers
        (bool ok,) = controller.call(abi.encodeWithSignature("predeposit(uint256)", 60e18));
        assertTrue(ok, "predeposit failed");
        vm.stopPrank();

        vm.prank(address(factory)); // factory is the controller owner mid-round
        (bool ok2,) = controller.call(abi.encodeWithSignature("launchPooledBuy()"));
        assertTrue(ok2, "launch failed");
    }

    /// Full trade loop through the REAL zap contracts against the mock pm.
    function test_E2E_ZapBuyAndSell_AgainstMockPM() public {
        _launch();

        // ── buy through the real zap (the exact path the UI button drives) ──
        vm.startPrank(alice);
        mixETH.approve(address(zapIn), 10e18);
        uint256 pspOut = zapIn.buyWithMix(_poolKey(), 10e18, 0, 0);
        vm.stopPrank();

        assertGt(pspOut, 0, "zap buy returned nothing");
        assertEq(pspToken.balanceOf(alice), pspOut, "alice did not receive the PSP");

        // side pot accrued: 25 bps of the fee stream, minted as PSP
        (uint256 potPSP, uint256 potMix) = _potState();
        assertGt(potPSP, 0, "side pot did not accrue on buy");
        assertEq(potMix, 0, "no mixETH funded during a live round");

        // ── sell it all back through the real zap-out ──
        uint256 mixBefore = mixETH.balanceOf(alice);
        vm.startPrank(alice);
        pspToken.approve(address(zapOut), pspOut);
        uint256 mixBack = zapOut.sellToMix(_poolKey(), pspOut, 0, 0);
        vm.stopPrank();

        assertGt(mixBack, 0, "zap sell returned nothing");
        assertEq(mixETH.balanceOf(alice), mixBefore + mixBack, "alice did not receive mixETH");

        // sell path also accrues the pot (skimmed as unburned PSP)
        (uint256 potPSP2,) = _potState();
        assertGt(potPSP2, potPSP, "side pot did not accrue on sell");

        // mock pm holds no dust: hook took its input, zap took its output
        assertEq(pspToken.balanceOf(address(poolManager)), 0, "PSP dust left in mock pm");
        assertEq(mixETH.balanceOf(address(poolManager)), 0, "mixETH dust left in mock pm");
    }

    function _potState() internal view returns (uint256, uint256) {
        (bool ok, bytes memory data) =
            controller.staticcall(abi.encodeWithSignature("potState()"));
        require(ok, "potState()");
        return abi.decode(data, (uint256, uint256));
    }
}
