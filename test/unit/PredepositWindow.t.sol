// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {SineV3Math} from "../../src/SineV3Math.sol";
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


/// @title PredepositWindowTest
/// @notice Uncapped IBCO deposits retain the full three-day public launch window.
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
        factory = new PSPFactory(IPoolManager(address(poolManager)), IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer(), new StakerDeployer(), address(new SineV3Math()), 0, address(this));

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
        assertEq(controller.PREDEPOSIT_DURATION(), 3 days, "three days");
        assertEq(controller.PREDEPOSIT_CAP(), 0, "uncapped sentinel");
        assertEq(controller.VEST_DURATION(), 28 days, "four-week decay horizon");
        assertEq(controller.staker().epochSize(), 28 days / 6);
    }

    function test_UncappedDepositCanExceedFormerCapInOneCallAndTopUp() public {
        _deposit(alice, 20_000e18);
        _deposit(alice, 10_000e18);
        _deposit(bob, 15_000e18);
        assertEq(controller.totalPredepositMixETH(), 45_000e18);
        (uint256 credited,) = controller.predeposits(alice);
        assertEq(credited, 30_000e18);
        (,,,, bool reached,, bool launchable) = controller.predepositState();
        assertFalse(reached);
        assertFalse(launchable);
        vm.prank(rando);
        vm.expectRevert(RoundController.PredepositOpen.selector);
        controller.launchPooledBuy();
    }

    function testFuzzPositiveSubMinimumPredeposit(uint64 raw) public {
        uint256 amount = bound(raw, 1, 0.005e18 - 1);
        _deposit(alice, amount);
        (uint256 credited,) = controller.predeposits(alice);
        assertEq(credited, amount);
        assertEq(controller.totalPredepositMixETH(), amount);
        assertEq(controller.PREDEPOSIT_RULES_VERSION(), 2);
    }

    function testOneWeiAndPredepositForAreAccepted() public {
        _deposit(alice, 1);
        mixETH.transfer(bob, 2);
        vm.startPrank(bob);
        mixETH.approve(address(controller), 2);
        controller.predepositFor(alice, 2);
        vm.stopPrank();
        (uint256 credited,) = controller.predeposits(alice);
        assertEq(credited, 3);
        assertEq(controller.totalPredepositors(), 1);
    }

    function testZeroPredepositStillRejected() public {
        vm.expectRevert(RoundController.ZeroAmount.selector);
        controller.predeposit(0);
        vm.expectRevert(RoundController.ZeroAmount.selector);
        controller.predepositFor(alice, 0);
    }

    function testFuzzDustAtFormerCapKeepsWindowOpen(uint64 raw) public {
        uint256 dust = bound(raw, 1, 0.005e18 - 1);
        _deposit(alice, 1000e18 - dust);
        _deposit(bob, dust);
        _deposit(bob, 1);
        assertEq(controller.totalPredepositMixETH(), 1000e18 + 1);
        (,,,, bool reached,, bool launchable) = controller.predepositState();
        assertFalse(reached);
        assertFalse(launchable);
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
        skip(3 days + 1);
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
        _deposit(alice, 500e18);
        (
            uint256 total,
            uint256 cap,
            uint256 start,
            bool closed,
            bool capReached,
            bool windowOver,
            bool launchable
        ) = controller.predepositState();
        assertEq(total, 1000e18 / 2);
        assertEq(cap, 0);
        assertEq(start, controller.predepositStartTime());
        assertFalse(closed);
        assertFalse(capReached);
        assertFalse(windowOver);
        assertFalse(launchable);

        vm.warp(start + 3 days);
        (,,,,, bool wo2, bool l2) = controller.predepositState();
        assertTrue(wo2, "window over at exactly 3 days (inclusive)");
        assertTrue(l2);
    }

    // ─────────────── carry seeding ───────────────

    function test_seedCarry_FactoryOnlyAndKeepsTheFullWindow() public {
        vm.prank(rando);
        vm.expectRevert(RoundController.NotFactory.selector);
        controller.seedCarry(25_000e18);

        mixETH.transfer(address(factory), 25_000e18);
        vm.startPrank(address(factory));
        mixETH.approve(address(controller), 25_000e18);
        controller.seedCarry(25_000e18);
        vm.stopPrank();

        assertEq(controller.totalPredepositMixETH(), 25_000e18);
        (,,,, bool capReached, bool windowOver, bool launchable) = controller.predepositState();
        assertFalse(capReached);
        assertFalse(windowOver);
        assertFalse(launchable);
        vm.prank(rando);
        vm.expectRevert(RoundController.PredepositOpen.selector);
        controller.launchPooledBuy();
    }

    function test_seedCarry_StillAcceptsPublicDepositsAfter() public {
        mixETH.transfer(address(factory), 5000e18);
        vm.startPrank(address(factory));
        mixETH.approve(address(controller), 5000e18);
        controller.seedCarry(5000e18);
        vm.stopPrank();
        _deposit(alice, 10_000e18);
        assertEq(controller.totalPredepositMixETH(), 15_000e18);
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
