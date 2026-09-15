// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SineV3Math} from "src/SineV3Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {RoundController} from "../src/RoundController.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {ControllerDeployer} from "../src/ControllerDeployer.sol";
import {StakerDeployer} from "../src/StakerDeployer.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {SineMath} from "../src/libraries/SineMath.sol";
import {SepoliaMixETH} from "../src/testnet/SepoliaMixETH.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {TicketSwapper} from "./wave2/auditorC/CBase.sol";

/// @title UncappedCapacityTest
/// @notice Large IBCOs keep claim and exit arithmetic valid; individual V4 swaps fit their delta widths.
contract UncappedCapacityTest is Test {
    SepoliaMixETH mix;
    MockPoolManager manager;
    PSPFactory factory;
    PSPFactory.Round round;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        mix = new SepoliaMixETH();
        manager = new MockPoolManager();
        factory = new PSPFactory(IPoolManager(address(manager)), IERC20(address(mix)),
            new HookDeployer(), new ControllerDeployer(), new StakerDeployer(),
            address(new SineV3Math()),
            CurveMath.packTimingsCapped(60, 120, 180, 0), address(this));
        factory.configureSineV3(75_000_000_000_000);
        factory.deployRound(PSPFactory.RoundParams("PSP", "PSP", CurveMath.singleCurve(
            0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)));
        round = factory.getRound(1);
    }

    function _deposit(RoundController ctl, address who, uint256 amount) private {
        mix.mint(who, amount);
        vm.startPrank(who);
        mix.approve(address(ctl), amount);
        ctl.predeposit(amount);
        vm.stopPrank();
    }

    function _launch() private {
        skip(60);
        round.controller.launchPooledBuy();
    }

    function _key() private view returns (PoolKey memory key) {
        Currency a = Currency.wrap(address(mix));
        Currency b = Currency.wrap(address(round.token));
        if (a > b) (a, b) = (b, a);
        return PoolKey(a, b, 0x800000, 60, IHooks(address(round.hook)));
    }

    function _expectSwapTooLarge(bool isBuy, uint256 amount) private {
        PoolKey memory key = _key();
        bool buyZeroForOne = Currency.unwrap(key.currency0) == address(mix);
        uint256 reserves = round.hook.reserveMixETH();
        uint256 supply = round.hook.totalSupplyPSP();
        vm.prank(address(manager));
        vm.expectRevert(CurveHook.SwapTooLarge.selector);
        round.hook.beforeSwap(alice, key, SwapParams(isBuy ? buyZeroForOne : !buyZeroForOne,
            -int256(amount), 0), "");
        assertEq(round.hook.reserveMixETH(), reserves);
        assertEq(round.hook.totalSupplyPSP(), supply);
    }

    function test_LargeIBCOLaunchClaimsAndDirectRedemption() public {
        // v3 supported ceiling: ~576k mix gross (net boot <= ~518,841 mix —
        // the helper's 16-wave prelaunch table edge). The old 1e37-scale
        // boots are arithmetic capacity errors by design now.
        _deposit(round.controller, alice, 150_000e18);
        _deposit(round.controller, bob, 300_000e18);
        _launch();
        uint256 snapshot = round.controller.genesisPSPSnapshot();
        uint256 expected = Math.mulDiv(snapshot, 150_000e18, 450_000e18);
        vm.prank(alice);
        round.controller.claimPredepositPSP();
        PSPStaker staker = round.controller.staker();
        uint256 id = staker.primaryOf(alice);
        (uint256 principal,,,,) = staker.positions(id);
        assertEq(principal, expected);
        skip(180);
        round.controller.detonate{gas: 1_000_000}();
        vm.startPrank(alice);
        staker.withdraw(id);
        round.token.approve(address(round.hook), principal);
        uint256 paid = round.hook.redeemBacking(principal);
        vm.stopPrank();
        assertApproxEqAbs(paid, 150_000e18, 1);
    }

    function test_UnrepresentableDepositRollsBackBeforeItCanPoisonLaunch() public {
        _deposit(round.controller, alice, 500e18);
        uint256 oversized = type(uint256).max / 2;
        mix.mint(bob, oversized);
        vm.startPrank(bob);
        mix.approve(address(round.controller), oversized);
        vm.expectRevert(RoundController.PredepositCapacityExceeded.selector);
        round.controller.predeposit(oversized);
        vm.stopPrank();
        assertEq(mix.balanceOf(bob), oversized);
        assertEq(round.controller.totalPredepositMixETH(), 500e18);
        _launch();
        assertEq(uint8(round.hook.mode()), uint8(CurveHook.Mode.Active));
    }

    function test_UnrepresentableFactoryDonationCannotBlockTheNextRound() public {
        _deposit(round.controller, alice, 500e18);
        _launch();
        skip(180);
        round.controller.detonate{gas: 1_000_000}();
        uint256 oversized = type(uint256).max / 2;
        mix.mint(address(factory), oversized);
        factory.reserveSpawn(1);
        for (uint256 i; i < 3; ++i) factory.birthStep();
        PSPFactory.Round memory next = factory.getRound(2);
        assertEq(mix.balanceOf(address(factory)), oversized);
        assertEq(next.controller.totalPredepositMixETH(), 0);
        assertEq(mix.allowance(address(factory), address(next.controller)), 0);
        _deposit(next.controller, bob, 500e18);
        skip(60);
        next.controller.launchPooledBuy();
        assertEq(uint8(next.hook.mode()), uint8(CurveHook.Mode.Active));
    }

    function test_V4RejectsInputsBeyondSigned128Bits() public {
        _deposit(round.controller, alice, 450_000e18); // top of the supported band
        _launch();
        uint256 oversized = uint256(uint128(type(int128).max)) + 1;
        _expectSwapTooLarge(true, oversized);
        _expectSwapTooLarge(false, oversized);
        skip(180);
        round.controller.detonate{gas: 1_000_000}();
        _expectSwapTooLarge(false, oversized);
    }

    function test_V4RejectsBuyBeyondTheWaveDomain() public {
        // v3 fixed-shape curves cap Q at ~5e29 PSP-wei — a buy output can no
        // longer approach int128. The equivalent protection is the explicit
        // domain capacity error, raised BEFORE any state change.
        _deposit(round.controller, alice, 450_000e18);
        _launch();
        PoolKey memory key = _key();
        bool buyZeroForOne = Currency.unwrap(key.currency0) == address(mix);
        uint256 reserves = round.hook.reserveMixETH();
        uint256 supply = round.hook.totalSupplyPSP();
        vm.prank(address(manager));
        vm.expectRevert(SineV3Math.SineV3Domain.selector);
        round.hook.beforeSwap(alice, key, SwapParams(buyZeroForOne, -int256(1e35), 0), "");
        assertEq(round.hook.reserveMixETH(), reserves);
        assertEq(round.hook.totalSupplyPSP(), supply);
    }

    function test_V4RejectsOversizedActiveAndFlatSellOutputs() public {
        // v3 fixed curve tops at ~1,927 mix/PSP: no in-range input can push a
        // mixETH OUTPUT past int128. A sell larger than the minted supply
        // reverts SellExceedsSupply in BOTH live and flat modes, state intact.
        _useHighPriceCurve();
        _deposit(round.controller, alice, 450_000e18);
        _launch();
        _expectSellExceedsSupply(1e38);
        skip(180);
        round.controller.detonate{gas: 1_000_000}();
        _expectSellExceedsSupply(1e38);
    }

    function _expectSellExceedsSupply(uint256 amount) private {
        PoolKey memory key = _key();
        bool buyZeroForOne = Currency.unwrap(key.currency0) == address(mix);
        uint256 reserves = round.hook.reserveMixETH();
        uint256 supply = round.hook.totalSupplyPSP();
        vm.prank(address(manager));
        vm.expectRevert(CurveHook.SellExceedsSupply.selector);
        round.hook.beforeSwap(alice, key, SwapParams(!buyZeroForOne, -int256(amount), 0), "");
        assertEq(round.hook.reserveMixETH(), reserves);
        assertEq(round.hook.totalSupplyPSP(), supply);
    }
    function _useHighPriceCurve() private {
        factory = new PSPFactory(IPoolManager(address(manager)), IERC20(address(mix)),
            factory.hookDeployer(), factory.controllerDeployer(), factory.stakerDeployer(),
            factory.sineV3Table(), CurveMath.packTimingsCapped(60, 120, 180, 0), address(this));
        factory.configureSineV3(75_000_000_000_000);
        factory.deployRound(PSPFactory.RoundParams("PSP", "PSP", CurveMath.singleCurve(
            0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)));
        round = factory.getRound(1);
    }

    function test_LargeRepresentablePotRemainsClaimable() public {
        _useHighPriceCurve();
        _deposit(round.controller, alice, 500_000e18); // gross at the cap
        _launch();
        TicketSwapper swapper = new TicketSwapper(IPoolManager(address(manager)), IERC20(address(mix)));
        // boot 450k mix + 64 waves of headroom (~1.93M mix): a 1M-mix buy
        // stays in-domain, buys ~200k tickets (bounded seat writes), and
        // leaves a claimable pot an order of magnitude above the genesis pot.
        mix.mint(alice, 1e24);
        vm.startPrank(alice);
        mix.approve(address(swapper), 1e24);
        swapper.buy(_key(), 1e24, alice, alice);
        vm.stopPrank();
        assertGt(round.hook.ticketCount(), 100_000);
        (, uint256 lam, uint256 target,) = round.hook.sineV3();
        assertLe(round.hook.reserveMixETH(), target + 64 * lam);
        uint256 pot = round.hook.potBalance();
        skip(180);
        round.controller.detonate{gas: 1_000_000}();
        uint256 claim = round.hook.claimablePot(alice);
        assertApproxEqAbs(claim, pot, 10);
        uint256 before = mix.balanceOf(alice);
        vm.prank(alice);
        round.hook.claimPot();
        assertEq(mix.balanceOf(alice) - before, claim);
    }

}
