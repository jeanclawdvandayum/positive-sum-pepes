// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

import {MainnetConfig} from "./MainnetConfig.sol";
import {V4SwapRouter} from "./V4SwapRouter.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";

/// @title SidePotTest
/// @notice Proves the 25bps side-pot mechanics end to end:
///         1. Fee split math on curve buys/sells (4.75% stakers, 0.25% pot in PSP)
///         2. Pot PSP never locks — totalLocked is invariant to pot accrual
///         3. Carpet bomb redeems the pot at average backing into factory.sidePot
///         4. Round 2's genesis curve is thickened by the pot on top of the
///            500-mixETH public cap, share-less, and predepositors' claims are
///            not diluted by it
contract SidePotTest is Test {
    IPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;
    V4SwapRouter public router;

    CurveMath.CurveConfig cfg;

    PSPToken pspToken;
    RoundController controller;
    CurveHook hook;
    PoolKey poolKey;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        poolManager = IPoolManager(MainnetConfig.POOL_MANAGER);
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();

        factory = new PSPFactory(poolManager, IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer(), 0);
        router = new V4SwapRouter(poolManager);

        _dealMixETH(alice, 2_000e18);
        _dealMixETH(bob, 2_000e18);

        _deployRound();
    }

    // ══════════════════════════════════════════════════════════════
    //  POT-1: buy fee split — 4.75% stakers, 0.25% pot (as PSP), 95% curve
    // ══════════════════════════════════════════════════════════════
    function test_Pot1_BuyFeeSplit() public {
        _predeposit(alice, 100e18);
        _launch();
        _claim(alice);

        uint256 supplyBefore = hook.totalSupplyPSP();
        uint256 reserveBefore = hook.reserveMixETH();
        uint256 lockedBefore = controller.totalLocked();
        uint256 aliceMixBefore = mixETH.balanceOf(alice);

        _buy(bob, 10e18);

        // exact split of 10e18: 9.5 curve + 0.025 pot into reserve, 0.475 staker fee
        uint256 userOut = CurveMath.computeBuyOutput(9.5e18, supplyBefore, cfg);
        uint256 potOut = CurveMath.computeBuyOutput(0.025e18, supplyBefore + userOut, cfg);

        assertEq(hook.totalSupplyPSP(), supplyBefore + userOut + potOut, "supply = user + pot mint");
        assertEq(hook.reserveMixETH() - reserveBefore, 9.525e18, "reserve grew by curve + pot mixETH");
        (uint256 potPSP,) = controller.potState();
        assertEq(potPSP, potOut, "pot ledger = curve output of the pot leg");

        // staker stream: alice is the sole locker (genesis claim) -> 0.475e18
        // (delta covers accFeePerShare division dust, ~1 part in 10^11)
        uint256 aliceMixAfterClaim = _claimFees(alice);
        assertApproxEqAbs(aliceMixAfterClaim - aliceMixBefore, 0.475e18, 1e12, "staker fee = 4.75%");

        // pot accrual NEVER touches the lock ledger
        assertEq(controller.totalLocked(), lockedBefore, "pot accrual left totalLocked untouched");
    }

    // ══════════════════════════════════════════════════════════════
    //  POT-2: sell fee split — pot skims 0.25% of sold PSP unburned,
    //         its backing stays in the reserve
    // ══════════════════════════════════════════════════════════════
    function test_Pot2_SellFeeSplit() public {
        _predeposit(alice, 100e18);
        _launch();
        _claim(alice);
        _buy(bob, 10e18);

        uint256 bobPSP = pspToken.balanceOf(bob);
        uint256 supplyBefore = hook.totalSupplyPSP();
        uint256 reserveBefore = hook.reserveMixETH();
        (uint256 potBefore,) = controller.potState();
        uint256 bobMixBefore = mixETH.balanceOf(bob);

        uint256 sellAmt = bobPSP / 2;
        _sell(bob, sellAmt);

        uint256 integral = CurveMath.computeSellOutput(sellAmt, supplyBefore, cfg);
        uint256 potCut = (sellAmt * 25) / 10000;

        assertEq(hook.totalSupplyPSP(), supplyBefore - sellAmt + potCut, "supply dropped by 99.75% of sold");
        assertEq(hook.reserveMixETH(), reserveBefore - integral + (integral * 25) / 10000,
                 "reserve kept the pot slice's backing");
        (uint256 potAfter,) = controller.potState();
        assertEq(potAfter - potBefore, potCut, "pot skimmed 0.25% of sold PSP");
        assertApproxEqAbs(mixETH.balanceOf(bob) - bobMixBefore, integral - (integral * 500) / 10000, 10,
                          "seller received 95% of the integral");
    }

    // ══════════════════════════════════════════════════════════════
    //  POT-3: full lifecycle — volume accrues pot, carpet bomb redeems
    //         it into factory.sidePot, round 2's curve is thickened
    //         share-less on top of the 500 public cap
    // ══════════════════════════════════════════════════════════════
    function test_Pot3_FullLifecycleBombAndRebirth() public {
        // ── round 1: launch, churn (pot accrues), bomb ──
        _predeposit(alice, 100e18);
        _launch();
        _claim(alice); // alice holds the entire genesis lock

        _buy(bob, 10e18); // pot: buy cut
        _sell(bob, pspToken.balanceOf(bob) / 2); // pot: sell skim

        (uint256 potPSP,) = controller.potState();
        assertGt(potPSP, 0, "pot accrued PSP from both legs");

        // alice single-handedly passes quorum+majority (genesis >> churn).
        // skip a second so her lock predates the proposal (M-1 check)
        skip(1);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        skip(3 days + 1);

        uint256 supplyAtBomb = hook.totalSupplyPSP();
        uint256 reserveAtBomb = hook.reserveMixETH();
        uint256 expectedRedemption = (reserveAtBomb * potPSP) / supplyAtBomb;
        assertGt(expectedRedemption, 0, "pot redemption would be positive");

        uint256 factoryMixBefore = mixETH.balanceOf(address(factory));
        vm.prank(bob); // permissionless execution
        controller.carpetBomb();
        skip(3 days + 1);
        controller.finalizeCarpet();

        // ── round 2: spawned INSIDE the bomb tx; carry AND pot both flowed
        // through the factory and are already seated in round 2's controller ──
        (uint256 potAfterBomb,) = controller.potState();
        assertEq(potAfterBomb, 0, "pot PSP burned on bomb");
        assertEq(factory.currentRoundId(), 2, "round 2 spawned");
        assertEq(factory.sidePot(), 0, "factory side pot released to round 2");
        PSPFactory.Round memory r2 = factory.getRound(2);
        (, uint256 potFunded) = r2.controller.potState();
        assertEq(potFunded, expectedRedemption, "pot redemption seated in round 2");
        uint256 carry = r2.controller.totalPredepositMixETH();

        // user cap still 500 for the PUBLIC, pot rides on top
        vm.startPrank(bob);
        mixETH.approve(address(r2.controller), 600e18);
        vm.expectRevert(RoundController.CapExceeded.selector);
        r2.controller.predeposit(600e18);
        mixETH.approve(address(r2.controller), 100e18);
        r2.controller.predeposit(100e18);
        vm.stopPrank();

        // pot was forwarded share-less: totalPredeposit excludes it
        (uint256 totalPre, uint256 cap2,,,, ,) = r2.controller.predepositState();
        assertEq(cap2, 500e18, "public cap unchanged");
        assertEq(totalPre, carry + 100e18, "predeposit = carry shares + bob (no pot)");
        (, uint256 potFundedAfterLaunch) = r2.controller.potState();
        assertEq(potFundedAfterLaunch, potFunded, "pot funding untouched by bob's deposit");

        // launch: boot = predeposit + pot
        vm.prank(address(factory));
        r2.controller.launchPooledBuy();

        uint256 boot = carry + 100e18 + expectedRedemption;
        assertEq(r2.hook.reserveMixETH(), boot, "round 2 curve = predeposit + pot depth");

        uint256 initialPSP = CurveMath.computeBuyOutput(boot, 0, cfg);
        uint256 potShare = (initialPSP * expectedRedemption) / boot;
        assertEq(r2.controller.totalInitialPSP(), initialPSP, "genesis mint computed on full boot");
        assertEq(r2.controller.genesisPSPSnapshot(), initialPSP - potShare,
                 "claimable pool excludes pot share");
        (uint256 potPSP2,) = r2.controller.potState();
        assertEq(potPSP2, potShare, "pot holds its genesis slice unlocked");
        (uint256 vcLock,,,) = _locks(r2.controller, address(r2.controller));
        assertEq(vcLock, initialPSP - potShare,
                 "genesis virtual lock excludes pot slice");

        // bob claims predeposit-proportional share of the CLAIMABLE pool —
        // the pot's depth does not dilute him
        vm.prank(bob);
        r2.controller.claimPredepositPSP();
        (uint256 bobLock,,,) = _locks(r2.controller, bob);
        uint256 bobExpected = ((initialPSP - potShare) * 100e18) / (carry + 100e18);
        assertEq(bobLock, bobExpected, "claim not diluted by pot depth");
    }

    // ─────────────────────────── helpers ───────────────────────────

    function _locks(RoundController c, address user)
        internal
        view
        returns (uint256 amount, uint256 rewardDebt, uint256 lockTime, uint256 unlockTime)
    {
        (amount, rewardDebt, lockTime, unlockTime) = c.locks(user);
    }

    function _deployRound() internal {
        cfg = CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);

        PSPFactory.RoundParams memory params =
            PSPFactory.RoundParams({name: "Positive Sum Pepes", symbol: "PSP", curveConfig: cfg});

        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory round = factory.getRound(roundId);
        pspToken = round.token;
        controller = round.controller;
        hook = round.hook;

        Currency currency0 = Currency.wrap(address(mixETH));
        Currency currency1 = Currency.wrap(address(pspToken));
        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0x800000,
            tickSpacing: 60,
            hooks: hook
        });
    }

    function _dealMixETH(address to, uint256 amount) internal {
        mixETH.transfer(to, amount);
    }

    function _predeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        mixETH.approve(address(controller), amount);
        controller.predeposit(amount);
        vm.stopPrank();
    }

    function _launch() internal {
        vm.prank(address(factory));
        controller.launchPooledBuy();
    }

    function _claim(address user) internal {
        vm.prank(user);
        controller.claimPredepositPSP();
    }

    function _claimFees(address user) internal returns (uint256) {
        uint256 before = mixETH.balanceOf(user);
        vm.prank(user);
        controller.claimFees();
        return mixETH.balanceOf(user);
    }

    function _buy(address user, uint256 mixETHAmount) internal {
        vm.startPrank(user);
        mixETH.approve(address(router), mixETHAmount);
        bool zeroForOne = _isMixETHCurrency0();
        SwapParams memory params = SwapParams({
            amountSpecified: -int256(mixETHAmount),
            sqrtPriceLimitX96: zeroForOne ? _minPrice() : _maxPrice(),
            zeroForOne: zeroForOne
        });
        router.swap(poolKey, params);
        vm.stopPrank();
    }

    function _sell(address user, uint256 pspAmount) internal {
        vm.startPrank(user);
        pspToken.approve(address(router), pspAmount);
        bool zeroForOne = !_isMixETHCurrency0();
        SwapParams memory params = SwapParams({
            amountSpecified: -int256(pspAmount),
            sqrtPriceLimitX96: zeroForOne ? _maxPrice() : _minPrice(),
            zeroForOne: zeroForOne
        });
        router.swap(poolKey, params);
        vm.stopPrank();
    }

    function _isMixETHCurrency0() internal view returns (bool) {
        return Currency.wrap(address(mixETH)) < Currency.wrap(address(pspToken));
    }

    function _minPrice() internal pure returns (uint160) {
        return 4295128740;
    }

    function _maxPrice() internal pure returns (uint160) {
        return 1461446703485210103287273052203988822378723970341;
    }

    receive() external payable {}
}
