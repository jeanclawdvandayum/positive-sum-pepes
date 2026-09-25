// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {SineV3Math} from "../../src/SineV3Math.sol";
import {SineV3TestData as SineV3Data} from "../helpers/SineV3TestData.sol";
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
/// @notice The capped IBCO keeps its public window; reaching the pooled cap
///         early makes the launch permissionless, while factory carry is
///         cap-exempt but counts toward the total. Rules v3: the public
///         open phase caps every wallet at 10 mixETH, so pooled-cap tests
///         fill through a crowd of fresh beneficiaries (predepositFor —
///         the cap guards the beneficiary, not the sender).
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
        factory = new PSPFactory(IPoolManager(address(poolManager)), IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer(), new StakerDeployer(), address(new SineV3Math(SineV3Data.deploy())), 0, address(this));

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

    /// @dev Fill the pooled cap through fresh 10-cap wallets.
    function _openPooled(uint256 amount) internal {
        uint256 wallets = amount / 10e18;
        for (uint256 i; i < wallets; ++i) {
            address w = makeAddr(string.concat("pooled-", vm.toString(i)));
            mixETH.transfer(w, 10e18);
            vm.startPrank(w);
            mixETH.approve(address(controller), 10e18);
            controller.predepositFor(w, 10e18);
            vm.stopPrank();
        }
    }

    function _carry(uint256 amount) internal {
        mixETH.transfer(address(factory), amount);
        vm.startPrank(address(factory));
        mixETH.approve(address(controller), amount);
        controller.seedCarry(amount);
        vm.stopPrank();
    }

    // ─────────────── constants ───────────────

    function test_constants() public view {
        // rules v3 mainnet defaults: no csv + no previous holders on this
        // genesis round, so the whole window runs as the open phase
        assertEq(controller.GREEN_DURATION(), 1 days, "one-day green default");
        assertEq(controller.OPEN_DURATION(), 1 days, "one-day open default");
        assertEq(controller.GREEN_PER_WALLET(), 0, "no members: green disabled");
        assertEq(controller.OPEN_PER_WALLET(), 10e18, "open wallet cap");
        assertEq(controller.PREDEPOSIT_CAP(), 1000 ether, "testnet pooled cap");
        assertEq(controller.VEST_DURATION(), 28 days, "four-week decay horizon");
        assertEq(controller.staker().epochSize(), 28 days / 6);
    }

    function test_PublicDepositOverWalletCapAndPooledTopUp() public {
        // one call over the open-phase wallet cap
        mixETH.transfer(alice, 10e18 + 1);
        vm.startPrank(alice);
        mixETH.approve(address(controller), 10e18 + 1);
        vm.expectRevert(RoundController.WalletCapExceeded.selector);
        controller.predeposit(10e18 + 1);
        vm.stopPrank();
        assertEq(controller.totalPredepositMixETH(), 0, "reverted deposit counted nothing");

        // top-up past the remaining pooled headroom
        _openPooled(600e18);
        mixETH.transfer(bob, 401e18);
        vm.startPrank(bob);
        mixETH.approve(address(controller), 401e18);
        // ruling: the per-wallet cap fires BEFORE the pooled cap — a
        // single over-both deposit reports WalletCapExceeded
        vm.expectRevert(RoundController.WalletCapExceeded.selector);
        controller.predepositFor(bob, 401e18); // 401 > 10 wallet, 600+401 > 1000 pooled
        vm.stopPrank();
        assertEq(controller.totalPredepositMixETH(), 600e18);
        (uint256 credited,,) = controller.predeposits(bob);
        assertEq(credited, 0, "reverted top-up credited nothing");
        (,,,, bool reached,,,,,,) = controller.predepositState();
        assertFalse(reached, "still under the cap");
    }

    function testFuzzPositiveSubMinimumPredeposit(uint64 raw) public {
        uint256 amount = bound(raw, 1, 0.005e18 - 1);
        _deposit(alice, amount);
        (uint256 credited,,) = controller.predeposits(alice);
        assertEq(credited, amount);
        assertEq(controller.totalPredepositMixETH(), amount);
        assertEq(controller.PREDEPOSIT_RULES_VERSION(), 3);
    }

    function testOneWeiAndPredepositForAreAccepted() public {
        _deposit(alice, 1);
        mixETH.transfer(bob, 2);
        vm.startPrank(bob);
        mixETH.approve(address(controller), 2);
        controller.predepositFor(alice, 2);
        vm.stopPrank();
        (uint256 credited,,) = controller.predeposits(alice);
        assertEq(credited, 3);
        assertEq(controller.totalPredepositors(), 1);
    }

    function testZeroPredepositStillRejected() public {
        vm.expectRevert(RoundController.ZeroAmount.selector);
        controller.predeposit(0);
        vm.expectRevert(RoundController.ZeroAmount.selector);
        controller.predepositFor(alice, 0);
    }

    function testFuzzDustShortOfCapKeepsWindowOpen(uint64 raw) public {
        uint256 dust = bound(raw, 1, 0.005e18 - 1);
        _deposit(alice, 10e18 - dust); // a full wallet, dust short of its cap
        assertEq(controller.totalPredepositMixETH(), 10e18 - dust);
        (,,,, bool reached,,,,,,) = controller.predepositState();
        assertFalse(reached, "dust short of the cap");
        (,,,,,, bool launchable,,,,) = controller.predepositState();
        assertFalse(launchable);
    }

    function test_state_ViewFields() public {
        _deposit(alice, 10e18);
        // split reads keep the via-ir frame shallow (11-tuple + locals)
        (uint256 total, uint256 cap, uint256 start, bool closed,,,,,,,) = controller.predepositState();
        (,,,, bool capReached, bool windowOver, bool launchable,,,,) = controller.predepositState();
        (,,,,,,, uint8 phaseNow, uint256 greenTotal, uint256 greenPerWallet, uint256 openPerWallet) =
            controller.predepositState();
        assertEq(total, 10e18);
        assertEq(cap, 1000e18);
        assertEq(start, controller.predepositStartTime());
        assertFalse(closed);
        assertFalse(capReached);
        assertFalse(windowOver);
        assertFalse(launchable);
        assertEq(uint256(phaseNow), 1, "open whole-way on a memberless round");
        assertEq(greenTotal, 0);
        assertEq(greenPerWallet, 0);
        assertEq(openPerWallet, 10e18);

        vm.warp(start + controller.OPEN_DURATION());
        (,,,,, bool wo2, bool l2,,,,) = controller.predepositState();
        assertTrue(wo2, "window over at exactly OPEN_DURATION (inclusive)");
        assertTrue(l2);
    }


    function test_window_OwnerMayLaunchEarly() public {
        _deposit(alice, 10e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        assertTrue(controller.predepositClosed(), "owner early launch");
    }

    function test_window_CapReachedAllowsNonOwnerLaunchBeforeWindowEnds() public {
        _openPooled(990e18);
        _deposit(alice, 10e18 - 1);
        (,,,, bool capReached,,,,,,) = controller.predepositState();
        assertFalse(capReached, "one wei short of the cap");
        vm.prank(rando);
        vm.expectRevert(RoundController.PredepositOpen.selector);
        controller.launchPooledBuy();
        assertFalse(controller.predepositClosed());

        _deposit(bob, 1); // public total reaches exactly 1000 mixETH
        (,,,, bool reached,,,,,,) = controller.predepositState();
        assertTrue(reached, "exactly at the cap");
        vm.prank(rando); // non-owner, window still open
        controller.launchPooledBuy();
        assertTrue(controller.predepositClosed());
    }

    function test_window_PredepositBlockedAfterClose() public {
        _deposit(alice, 10e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        vm.expectRevert(RoundController.PredepositClosed.selector);
        controller.predeposit(1e18);
    }

    // ─────────────── carry seeding ───────────────

    function test_seedCarry_FactoryOnlyAndSubCapCarryKeepsWindowOpen() public {
        vm.prank(rando);
        vm.expectRevert(RoundController.NotFactory.selector);
        controller.seedCarry(500e18);

        _carry(500e18);

        assertEq(controller.totalPredepositMixETH(), 500e18);
        (,,,, bool capReached, bool windowOver,,,,,) = controller.predepositState();
        assertFalse(capReached, "sub-cap carry");
        assertFalse(windowOver);
        vm.prank(rando);
        vm.expectRevert(RoundController.PredepositOpen.selector);
        controller.launchPooledBuy();
    }

    function test_seedCarry_AboveTheCapIsExemptAndMakesRoundLaunchable() public {
        _carry(25_000e18); // far above the pooled cap — exempt, but counted
        assertEq(controller.totalPredepositMixETH(), 25_000e18);
        (uint256 factoryShares,,) = controller.predeposits(address(factory));
        assertEq(factoryShares, 25_000e18, "carry is a full share");
        (,,,, bool capReached, bool windowOver,,,,,) = controller.predepositState();
        assertTrue(capReached, "carry counts toward the total");
        assertFalse(windowOver, "carry does not shorten the window");

        // no public headroom remains: even one wei reverts CapExceeded
        mixETH.transfer(alice, 1);
        vm.startPrank(alice);
        mixETH.approve(address(controller), 1);
        vm.expectRevert(RoundController.CapExceeded.selector);
        controller.predeposit(1);
        vm.stopPrank();

        vm.prank(rando); // non-owner, window still open
        controller.launchPooledBuy();
        assertTrue(controller.predepositClosed());
    }

    function test_seedCarry_StillAcceptsPublicDepositsAfter() public {
        _carry(600e18);
        _deposit(alice, 10e18);
        assertEq(controller.totalPredepositMixETH(), 610e18);

        // fill the remaining pooled headroom exactly, then one wei reverts
        _openPooled(390e18);
        assertEq(controller.totalPredepositMixETH(), 1000e18);
        mixETH.transfer(bob, 1);
        vm.startPrank(bob);
        mixETH.approve(address(controller), 1);
        vm.expectRevert(RoundController.CapExceeded.selector);
        controller.predeposit(1);
        vm.stopPrank();
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
