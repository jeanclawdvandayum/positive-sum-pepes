// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {RoundController} from "../src/RoundController.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {PSPZapIn} from "../src/PSPZapIn.sol";
import {PSPZapOut} from "../src/PSPZapOut.sol";
import {SineV3Math} from "../src/SineV3Math.sol";
import {SineV3TestData as SineV3Data} from "./helpers/SineV3TestData.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {ControllerDeployer} from "../src/ControllerDeployer.sol";
import {StakerDeployer} from "../src/StakerDeployer.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {IMixETH} from "../src/interfaces/IMixETH.sol";
import {SepoliaMixETH} from "../src/testnet/SepoliaMixETH.sol";

/// @title SineV3BootstrapCapacityTest
/// @notice Accepted deposits must launch, allocate nonzero shares and retain exits.
contract SineV3BootstrapCapacityTest is Test {
    SepoliaMixETH private mix;
    IPoolManager private manager;
    SineV3Math private math;
    HookDeployer private hookDeployer;
    ControllerDeployer private controllerDeployer;
    StakerDeployer private stakerDeployer;
    PSPFactory private factory;
    PSPFactory.Round private round;
    PSPZapIn private zapIn;
    PSPZapOut private zapOut;
    address private alice = makeAddr("bootstrap-alice");
    address private bob = makeAddr("bootstrap-bob");

    function setUp() public {
        vm.warp(1000 * 7 days);
        mix = new SepoliaMixETH();
        manager = IPoolManager(address(new PoolManager(address(this))));
        math = new SineV3Math(SineV3Data.deploy());
        hookDeployer = new HookDeployer();
        controllerDeployer = new ControllerDeployer();
        stakerDeployer = new StakerDeployer();
        zapIn = new PSPZapIn(IMixETH(address(mix)), manager);
        zapOut = new PSPZapOut(IMixETH(address(mix)), manager);
        _newRound(75e12);
    }

    function _newRound(uint128 pL) private {
        factory = new PSPFactory(manager, IERC20(address(mix)), hookDeployer,
            controllerDeployer, stakerDeployer, address(math),
            CurveMath.packTimingsCapped(60, 120, 180, 0), address(this));
        factory.configureSineV3(pL);
        factory.deployRound(PSPFactory.RoundParams("Capacity PSP", "CPSP", CurveMath.singleCurve(
            0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)));
        round = factory.getRound(1);
    }

    function _deposit(address who, uint256 amount) private {
        mix.mint(who, amount);
        vm.startPrank(who);
        mix.approve(address(round.controller), amount);
        round.controller.predeposit(amount);
        vm.stopPrank();
    }

    function _rejectDeposit(address who, uint256 amount) private {
        mix.mint(who, amount);
        uint256 held = mix.balanceOf(who);
        uint256 pooled = round.controller.totalPredepositMixETH();
        uint256 count = round.controller.totalPredepositors();
        uint256 controllerBalance = mix.balanceOf(address(round.controller));
        (uint256 contribution, bool claimed) = round.controller.predeposits(who);
        vm.startPrank(who);
        mix.approve(address(round.controller), amount);
        vm.expectRevert(RoundController.PredepositCapacityExceeded.selector);
        round.controller.predeposit(amount);
        vm.stopPrank();
        assertEq(mix.balanceOf(who), held, "rejected contribution was transferred");
        assertEq(mix.balanceOf(address(round.controller)), controllerBalance);
        assertEq(round.controller.totalPredepositMixETH(), pooled);
        assertEq(round.controller.totalPredepositors(), count);
        (uint256 afterContribution, bool afterClaimed) = round.controller.predeposits(who);
        assertEq(afterContribution, contribution);
        assertEq(afterClaimed, claimed);
    }

    function _launch() private {
        vm.prank(address(factory));
        round.controller.launchPooledBuy();
        assertEq(uint8(round.hook.mode()), uint8(CurveHook.Mode.Active));
        assertGt(round.controller.genesisPSPSnapshot(), 0);
        assertEq(round.token.totalSupply(), round.controller.genesisPSPSnapshot());
        assertEq(round.controller.staker().totalLocked(), round.token.totalSupply());
        assertEq(round.controller.staker().totalWeight(), round.token.totalSupply());
    }

    function _claim(address who) private returns (uint256 id, uint256 principal) {
        vm.prank(who);
        round.controller.claimPredepositPSP();
        PSPStaker staker = round.controller.staker();
        id = staker.primaryOf(who);
        (principal,,,,) = staker.positions(id);
        assertGt(principal, 0, "accepted positive contributor received no PSP");
    }

    function _detonate() private {
        skip(180);
        round.controller.detonate{gas: 1_000_000}();
        assertEq(uint8(round.hook.mode()), uint8(CurveHook.Mode.Flat));
    }

    function _redeem(address who, uint256 id, uint256 principal) private returns (uint256 paid) {
        vm.startPrank(who);
        round.controller.staker().withdraw(id);
        assertEq(round.token.balanceOf(who), principal);
        round.token.approve(address(round.hook), principal);
        paid = round.hook.redeemBacking(principal);
        vm.stopPrank();
        assertGt(paid, 0, "accepted principal lost its redemption path");
        assertEq(round.token.balanceOf(who), 0);
    }

    function test_DefaultOneWeiLaunchClaimAndRedemption() public {
        _deposit(alice, 1);
        _launch();
        (uint256 id, uint256 principal) = _claim(alice);
        _detonate();
        assertEq(_redeem(alice, id, principal), 1);
    }

    function test_CustomMaximumPriceOneWeiLaunchClaimAndRedemption() public {
        _newRound(1e18);
        _deposit(alice, 1);
        _launch();
        (uint256 id, uint256 principal) = _claim(alice);
        _detonate();
        assertEq(_redeem(alice, id, principal), 1);
    }

    function test_LaterDepositCannotEraseAnEarlierOneWeiAllocation() public {
        _newRound(1e18);
        _deposit(alice, 1);
        _deposit(bob, 8);
        // At ten gross wei, the genesis fee removes one wei. Nine PSP wei
        // cannot give every positive one-wei share a nonzero allocation.
        _rejectDeposit(bob, 1);
        _launch();
        (uint256 aliceId, uint256 alicePrincipal) = _claim(alice);
        (uint256 bobId, uint256 bobPrincipal) = _claim(bob);
        _detonate();
        uint256 paid = _redeem(alice, aliceId, alicePrincipal);
        paid += _redeem(bob, bobId, bobPrincipal);
        assertEq(paid, 9);
    }

    function test_CarrySharesCannotEraseAnEarlierOneWeiAllocation() public {
        _newRound(1e18);
        _deposit(alice, 9);
        mix.mint(address(factory), 1);
        vm.startPrank(address(factory));
        mix.approve(address(round.controller), 1);
        vm.expectRevert(RoundController.PredepositCapacityExceeded.selector);
        round.controller.seedCarry(1);
        vm.stopPrank();
        assertEq(mix.balanceOf(address(factory)), 1);
        assertEq(round.controller.totalPredepositMixETH(), 9);
        (uint256 factoryShares,) = round.controller.predeposits(address(factory));
        assertEq(factoryShares, 0);
        _launch();
        (uint256 id, uint256 principal) = _claim(alice);
        _detonate();
        assertEq(_redeem(alice, id, principal), 9);
    }

    function test_BonusCreatesNoSharesAndUsesTheExistingDenominator() public {
        _newRound(1e18);
        _deposit(alice, 1);
        mix.mint(address(factory), 9);
        vm.startPrank(address(factory));
        mix.approve(address(round.controller), 9);
        round.controller.potDeposit(9);
        vm.stopPrank();
        assertEq(round.controller.totalPredepositMixETH(), 1);
        assertEq(round.controller.carryBonusMixETH(), 9);
        _launch();
        (uint256 id, uint256 principal) = _claim(alice);
        _detonate();
        assertEq(_redeem(alice, id, principal), 10);
    }

    function test_ZeroGenesisQuoteCannotAdmitFunds() public {
        vm.mockCall(address(round.hook),
            abi.encodeWithSelector(CurveHook.sineGenesisPSP.selector, 450e18), abi.encode(uint256(0)));
        _rejectDeposit(alice, 500e18);
        vm.clearMockedCalls();
        _deposit(alice, 1);
        _launch();
    }

    function test_OpeningPriceCapacityRejectsAllFactoryPriceExtremes() public {
        _newRound(1e9);
        _rejectDeposit(alice, 24_000_000e18);
        _newRound(75e12);
        _rejectDeposit(alice, 210_000_000e18);
        _newRound(1e18);
        _rejectDeposit(alice, 800_000_000e18);
    }

    function test_LaunchBeyondTheOldSixteenWaveLimitRetainsEveryExit() public {
        _largeLifecycle(600_000e18, false);
    }

    function test_DefaultLargeGenesisAboveSigned128RetainsEveryExit() public {
        _largeLifecycle(150_000_000e18, true);
    }

    function test_MinimumLaunchPriceLargeGenesisRetainsEveryExit() public {
        _newRound(1e9);
        _largeLifecycle(20_000_000e18, true);
    }

    function test_MaximumLaunchPriceLargeGenesisRetainsEveryExit() public {
        _newRound(1e18);
        _largeLifecycle(700_000_000e18, true);
    }

    function _largeLifecycle(uint256 gross, bool aboveSigned128) private {
        _deposit(alice, gross);
        _launch();
        uint256 q0 = round.controller.genesisPSPSnapshot();
        if (aboveSigned128) assertGt(q0, uint256(uint128(type(int128).max)));
        (uint256 id, uint256 principal) = _claim(alice);
        assertEq(principal, q0);

        Currency c0 = Currency.wrap(address(mix));
        Currency c1 = Currency.wrap(address(round.token));
        if (c0 > c1) (c0, c1) = (c1, c0);
        PoolKey memory key = PoolKey(c0, c1, 0x800000, 60, round.hook);
        uint256 ticket = round.hook.ticketPrice();
        mix.mint(bob, ticket);
        vm.startPrank(bob);
        mix.approve(address(zapIn), ticket);
        uint256 bought = zapIn.buyWithMix(key, ticket, 1, block.timestamp + 1 hours);
        assertGt(bought, 0);
        assertEq(round.hook.ticketCount(), 1);
        round.token.approve(address(zapOut), bought);
        uint256 sold = zapOut.sellToMix(key, bought, 1, block.timestamp + 1 hours);
        vm.stopPrank();
        assertGt(sold, 0);
        assertLt(sold, ticket);
        assertEq(round.hook.totalSupplyPSP(), q0);

        PSPStaker staker = round.controller.staker();
        uint256 fees = staker.pendingFeesOf(id);
        assertGt(fees, 0);
        _detonate();
        uint256 pot = round.hook.claimablePot(bob);
        assertGt(pot, 0);
        uint256 bobBefore = mix.balanceOf(bob);
        vm.prank(bob);
        round.hook.claimPot();
        assertEq(mix.balanceOf(bob) - bobBefore, pot);
        uint256 aliceBefore = mix.balanceOf(alice);
        vm.prank(alice);
        staker.claimFees(id);
        assertEq(mix.balanceOf(alice) - aliceBefore, fees);
        uint256 backing = round.hook.reserveMixETH();
        assertEq(_redeem(alice, id, principal), backing);
        assertEq(round.hook.reserveMixETH(), 0);
        assertEq(round.hook.totalSupplyPSP(), 0);
    }
}
