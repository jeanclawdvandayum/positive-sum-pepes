// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PSPFactory} from "../../src/PSPFactory.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {RoundController} from "../../src/RoundController.sol";
import {PSPToken} from "../../src/PSPToken.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {IMixETH} from "../../src/interfaces/IMixETH.sol";

import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @title ZapPredepositTest — the ETH wrap + predeposit path needs no chain
///        state, so this is pure unit: real MockMixETH vault math, real
///        controller accounting, no mocks of token movement.
contract ZapPredepositTest is Test {
    MockMixETH mixETH;
    MockPoolManager poolManager;
    PSPFactory factory;
    PSPZapIn zapIn;

    RoundController controller;
    PSPToken pspToken;
    CurveHook hook;

    address alice = makeAddr("alice"); // ETH-only user — never touches mixETH

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();
        poolManager = new MockPoolManager();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)), IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer()
        );
        zapIn = new PSPZapIn(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));

        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: CurveMath.singleCurve(
                0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18
            )
        });
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory round = factory.getRound(roundId);
        controller = round.controller;
        pspToken = round.token;
        hook = round.hook;
    }

    function test_ZapInPredeposit_CreditsUserNotZap() public {
        vm.deal(alice, 10e18);
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        uint256 shares = zapIn.zapInPredeposit{value: 10e18}(controller, 0);

        assertEq(shares, 10e18, "1:1 wrap");
        assertEq(alice.balance, ethBefore - 10e18, "ETH spent");
        (uint256 recorded,) = controller.predeposits(alice);
        assertEq(recorded, 10e18, "predeposit credited to alice");
        (uint256 zapRecorded,) = controller.predeposits(address(zapIn));
        assertEq(zapRecorded, 0, "zap holds no predeposit");
        assertEq(mixETH.balanceOf(address(zapIn)), 0, "zap holds no mixETH");
        assertEq(controller.totalPredepositMixETH(), 10e18, "cap accounting");
    }

    function test_ZapInPredeposit_ExchangeRateHonored() public {
        // LST accrued: 1 share = 2 ETH now
        mixETH.setExchangeRate(2e18);
        vm.deal(alice, 10e18);

        vm.prank(alice);
        uint256 shares = zapIn.zapInPredeposit{value: 10e18}(controller, 4e18);

        assertEq(shares, 5e18, "10 ETH at 2:1 = 5 shares");
        (uint256 recorded,) = controller.predeposits(alice);
        assertEq(recorded, 5e18, "credited in shares, not ETH");
    }

    function test_ZapInPredeposit_MinSharesReverts() public {
        mixETH.setExchangeRate(2e18);
        vm.deal(alice, 10e18);

        vm.prank(alice);
        vm.expectRevert(PSPZapIn.InsufficientShares.selector);
        zapIn.zapInPredeposit{value: 10e18}(controller, 6e18); // only 5 minted
    }

    function test_ZapInPredeposit_ZeroETHReverts() public {
        vm.prank(alice);
        vm.expectRevert(PSPZapIn.ZeroAmount.selector);
        zapIn.zapInPredeposit(controller, 0);
    }

    function test_ZapInPredeposit_CapExceededPropagates() public {
        // Fill the cap exactly through the zap (500 mixETH cap)
        vm.deal(alice, 1_000_000e18);
        vm.startPrank(alice);
        zapIn.zapInPredeposit{value: controller.PREDEPOSIT_CAP()}(controller, 0);

        vm.expectRevert(RoundController.CapExceeded.selector);
        zapIn.zapInPredeposit{value: 1}(controller, 0);
        vm.stopPrank();
    }

    function test_PredepositForIsPermissionless() public {
        // A rando can deposit for alice — same trust model as ERC-4626
        // depositFor: crediting someone can only benefit them.
        address rando = makeAddr("rando");
        mixETH.transfer(rando, 3e18);

        vm.startPrank(rando);
        mixETH.approve(address(controller), 3e18);
        controller.predepositFor(alice, 3e18);
        vm.stopPrank();

        (uint256 recorded,) = controller.predeposits(alice);
        assertEq(recorded, 3e18, "alice credited");
        (uint256 randoRecorded,) = controller.predeposits(rando);
        assertEq(randoRecorded, 0, "rando not credited");
    }

    function test_EIP170_ZapsUnderLimit() public {
        assertLe(address(zapIn).code.length, 24_576, "PSPZapIn over EIP-170");
    }
}
