// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {StakerDeployer} from "src/StakerDeployer.sol";


/// @title PredepositWindowTest — 1-week window, 500 mixETH cap, permissionless launch
/// @notice Covers the rebirth flow added to RoundController/PSPFactory:
///         - public predeposit is hard-capped at PREDEPOSIT_CAP (overshoot reverts)
///         - hitting the cap exactly makes the round launchable by ANYONE
///         - the 7-day window expiry also makes it launchable by anyone
///         - before cap/window, a random address cannot launch (PredepositOpen)
///         - seedCarry is factory-only and cap-exempt (carry >= cap still seeds)
contract PredepositWindowTest is Test {
    MockPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;

    PSPToken pspToken;
    RoundController controller;
    CurveHook hook;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address rando = makeAddr("rando");

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();
        poolManager = new MockPoolManager();
        factory = new PSPFactory(IPoolManager(address(poolManager)), IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer(), new StakerDeployer(), 0, address(this));

        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: CurveMath.singleCurve(
                0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18
            )
        });

        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory round = factory.getRound(roundId);
        pspToken = round.token;
        controller = round.controller;
        hook = round.hook;
    }

    function _deposit(address who, uint256 amount) internal {
        mixETH.transfer(who, amount);
        vm.startPrank(who);
        mixETH.approve(address(controller), amount);
        controller.predeposit(amount);
        vm.stopPrank();
    }

    // ─────────────── constants ───────────────

    function test_constants() public view {
        assertEq(controller.PREDEPOSIT_DURATION(), 7 days, "one week");
        assertEq(controller.PREDEPOSIT_CAP(), 500e18, "500 mixETH");
    }

    // ─────────────── cap enforcement ───────────────

    function test_cap_OvershootReverts() public {
        _deposit(alice, 400e18);
        vm.prank(bob);
        mixETH.approve(address(controller), 101e18);
        mixETH.transfer(bob, 101e18);
        vm.prank(bob);
        vm.expectRevert(RoundController.CapExceeded.selector);
        controller.predeposit(101e18);
        assertEq(controller.totalPredepositMixETH(), 400e18, "nothing recorded on revert");
    }

    function test_cap_ExactFillLaunchableByAnyone() public {
        _deposit(alice, 400e18);
        _deposit(bob, 100e18); // exactly 500 — allowed
        assertEq(controller.totalPredepositMixETH(), 500e18);

        (,,,,,, bool launchable) = controller.predepositState();
        assertTrue(launchable, "cap fill => permissionless launch");

        vm.prank(rando);
        controller.launchPooledBuy();
        assertTrue(controller.predepositClosed(), "launched");
    }

    function test_cap_SecondDepositAfterCapReverts() public {
        _deposit(alice, 500e18);
        vm.prank(bob);
        vm.expectRevert(RoundController.CapExceeded.selector);
        controller.predeposit(1);
    }

    // ─────────────── window ───────────────

    function test_window_RandomCannotLaunchEarly() public {
        _deposit(alice, 100e18);
        vm.prank(rando);
        vm.expectRevert(RoundController.PredepositOpen.selector);
        controller.launchPooledBuy();
        assertFalse(controller.predepositClosed(), "still open");
    }

    function test_window_ExpiryMakesLaunchPermissionless() public {
        _deposit(alice, 100e18);
        vm.warp(block.timestamp + 7 days + 1);
        (,,,,,, bool launchable) = controller.predepositState();
        assertTrue(launchable, "window over => anyone may launch");
        vm.prank(rando);
        controller.launchPooledBuy();
        assertTrue(controller.predepositClosed());
    }

    function test_window_OwnerMayLaunchEarly() public {
        _deposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        assertTrue(controller.predepositClosed(), "owner early launch");
    }

    function test_window_PredepositBlockedAfterClose() public {
        _deposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        vm.expectRevert(RoundController.PredepositClosed.selector);
        controller.predeposit(1e18);
    }

    function test_state_ViewFields() public {
        _deposit(alice, 250e18);
        (
            uint256 total,
            uint256 cap,
            uint256 start,
            bool closed,
            bool capReached,
            bool windowOver,
            bool launchable
        ) = controller.predepositState();
        assertEq(total, 500e18 / 2);
        assertEq(cap, 500e18);
        assertEq(start, controller.predepositStartTime());
        assertFalse(closed);
        assertFalse(capReached);
        assertFalse(windowOver);
        assertFalse(launchable);

        vm.warp(start + 7 days);
        (,,,,, bool wo2, bool l2) = controller.predepositState();
        assertTrue(wo2, "window over at exactly 7 days (inclusive)");
        assertTrue(l2);
    }

    // ─────────────── carry seeding ───────────────

    function test_seedCarry_FactoryOnlyAndCapExempt() public {
        vm.prank(rando);
        vm.expectRevert(RoundController.NotFactory.selector);
        controller.seedCarry(600e18);

        // factory seeds a carry LARGER than the public cap
        mixETH.transfer(address(factory), 600e18);
        vm.prank(address(factory));
        mixETH.approve(address(controller), 600e18);
        vm.startPrank(address(factory));
        controller.seedCarry(600e18);
        vm.stopPrank();

        assertEq(controller.totalPredepositMixETH(), 600e18, "carry exceeds public cap");
        (,,,, bool capReached, bool windowOver, bool launchable) = controller.predepositState();
        assertTrue(capReached, "carry >= cap counts as reached");
        assertFalse(windowOver);
        assertTrue(launchable, "carry-heavy round instantly launchable");
        vm.prank(rando);
        controller.launchPooledBuy();
        assertTrue(controller.predepositClosed(), "permissionless launch after big carry");
    }

    function test_seedCarry_StillAcceptsPublicDepositsAfter() public {
        mixETH.transfer(address(factory), 100e18);
        vm.startPrank(address(factory));
        mixETH.approve(address(controller), 100e18);
        controller.seedCarry(100e18);
        vm.stopPrank();

        // public headroom counts from the carry, not from zero
        vm.prank(alice);
        vm.expectRevert(RoundController.CapExceeded.selector);
        controller.predeposit(500e18);
    }

    // ─────────────── html (walk-away UI) ───────────────

    function test_html_OwnerSetAndRead() public {
        assertEq(bytes(factory.html()).length, 0, "empty at genesis");
        vm.prank(rando);
        vm.expectRevert();
        factory.setHtml("<b>nope</b>");
        factory.setHtml("<html>pepes</html>");
        assertEq(factory.html(), "<html>pepes</html>");
    }
}
