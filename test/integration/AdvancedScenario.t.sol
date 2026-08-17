// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

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

/// @title AdvancedScenarioTest
/// @notice Tests yield reinvestment, multi-round lifecycle, slippage protection,
///         and edge cases that require the enhanced MockMixETH with adjustable rates.
contract AdvancedScenarioTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;
    V4SwapRouter public router;

    PSPToken pspToken;
    RoundController controller;
    CurveHook hook;
    PoolKey poolKey;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        poolManager = IPoolManager(MainnetConfig.POOL_MANAGER);
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();

        factory = new PSPFactory(poolManager, IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer());
        router = new V4SwapRouter(poolManager);

        _dealMixETH(alice, 1_000e18);
        _dealMixETH(bob, 1_000e18);
        _dealMixETH(carol, 1_000e18);

        _deployRound();
    }

    // ══════════════════════════════════════════════════════════════
    //  YIELD: Yield accrues in mixETH, strengthening backing per PSP
    // ══════════════════════════════════════════════════════════════

    function test_Adv_YieldAccrualIncreasesReserve() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claimAndLock(alice);

        uint256 reserveBefore = hook.totalReserveETH();

        // Simulate 10% yield — mixETH becomes worth more ETH
        vm.deal(address(mixETH), 10_000e18);
        mixETH.simulateYield{value: 10_000e18}(10_000e18);

        uint256 reserveAfter = hook.totalReserveETH();

        console.log("=== Yield Accrual ===");
        console.log("Reserve (ETH) before:", reserveBefore);
        console.log("Reserve (ETH) after:", reserveAfter);

        assertGt(reserveAfter, reserveBefore, "Reserve value increased from yield");
    }

    // ══════════════════════════════════════════════════════════════
    //  YIELD: Yield doesn't break fee distribution
    // ══════════════════════════════════════════════════════════════

    function test_Adv_YieldDoesNotBreakFees() public {
        _predeposit(alice, 100e18);
        _predeposit(bob, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claimAndLock(alice);
        _claimAndLock(bob);

        // Generate fees
        _buy(carol, 30e18);

        // Simulate yield — just accrues in mixETH balance, no protocol intervention
        vm.deal(address(mixETH), 2_000e18);
        mixETH.simulateYield{value: 2_000e18}(2_000e18);

        // Generate more fees
        _buy(carol, 20e18);

        // Alice claims
        uint256 aliceBefore = mixETH.balanceOf(alice);
        vm.prank(alice);
        controller.claimFees();
        uint256 aliceFees = mixETH.balanceOf(alice) - aliceBefore;

        // Bob claims
        uint256 bobBefore = mixETH.balanceOf(bob);
        vm.prank(bob);
        controller.claimFees();
        uint256 bobFees = mixETH.balanceOf(bob) - bobBefore;

        console.log("=== Yield + Fees ===");
        console.log("Alice fees:", aliceFees);
        console.log("Bob fees:", bobFees);

        assertGt(aliceFees, 0, "Alice earned fees");
        assertGt(bobFees, 0, "Bob earned fees");
        // They locked equal amounts before fees, so should be equal
        assertApproxEqRel(aliceFees, bobFees, 0.01e18, "Alice ~ Bob");
    }

    // ══════════════════════════════════════════════════════════════
    //  MULTI-ROUND 1: Full round 1 → destroy → deployNextRound → round 2 active
    // ══════════════════════════════════════════════════════════════

    function test_Adv_MultiRoundLifecycle() public {
        console.log("=== MULTI-ROUND LIFECYCLE ===");

        // Round 1: predeposit, launch, trade, destroy
        _predeposit(alice, 150e18);
        _predeposit(bob, 50e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claimAndLock(alice);
        _claimAndLock(bob);

        // Generate some fees
        _buy(carol, 20e18);

        // Govern + destroy
        // M-1: locks must predate the proposal timestamp
        skip(1); // fork tests: skip() reads live time; inline block.timestamp reads fork genesis
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);

        skip(3 days + 1);

        // carpetBomb destroys round 1 AND births round 2 with the carry seeded
        controller.carpetBomb();
        skip(3 days + 1);
        controller.finalizeCarpet();
        console.log("Round 1 destroyed; round 2 auto-spawned with carry");

        // Verify round 2 exists, seeded, in its predeposit window
        uint256 round2Id = factory.currentRoundId();
        assertEq(round2Id, 2, "Round 2 deployed");

        PSPFactory.Round memory round2 = factory.getRound(2);
        RoundController controller2 = round2.controller;
        CurveHook hook2 = round2.hook;

        assertGt(
            mixETH.balanceOf(address(controller2)), 0, "Round 2 seeded with carry"
        );
        assertFalse(controller2.predepositClosed(), "Round 2 in predeposit window");
        assertEq(mixETH.balanceOf(address(factory)), 0, "factory emptied");

        // Launch round 2's curve with the carried funds
        vm.prank(address(factory));
        controller2.launchPooledBuy();

        console.log("Round 2 mode:", uint8(hook2.mode()));
        assertEq(uint8(hook2.mode()), uint8(CurveHook.Mode.Active), "Round 2 active");

        // Verify round 2 has the carried funds
        assertGt(hook2.totalReserveETH(), 0, "Round 2 has reserve");
        assertGt(hook2.totalSupplyPSP(), 0, "Round 2 has supply");

        // Verify round 1 PSP is burned/dead
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Destroyed), "Round 1 destroyed");

        console.log("Round 2 reserve (ETH):", hook2.totalReserveETH());
        console.log("Round 2 supply:", hook2.totalSupplyPSP());

        // Round 2 should be tradeable
        // Fund alice for round 2 trading
        _dealMixETH(alice, 100e18);
        vm.startPrank(alice);
        mixETH.approve(address(router), 10e18);

        Currency currency0 = Currency.wrap(address(mixETH));
        Currency currency1 = Currency.wrap(address(round2.token));
        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }
        PoolKey memory key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0x800000,
            tickSpacing: 60,
            hooks: hook2
        });

        bool zeroForOne = Currency.wrap(address(mixETH)) < Currency.wrap(address(round2.token));
        SwapParams memory params2 = SwapParams({
            amountSpecified: -int256(10e18),
            sqrtPriceLimitX96: zeroForOne ? _minPrice() : _maxPrice(),
            zeroForOne: zeroForOne
        });
        router.swap(key2, params2);
        vm.stopPrank();

        assertGt(round2.token.balanceOf(alice), 0, "Alice bought PSP2");
        console.log("Alice bought PSP2:", round2.token.balanceOf(alice));
    }

    // ══════════════════════════════════════════════════════════════
    //  MULTI-ROUND 2: Three rounds in sequence
    // ══════════════════════════════════════════════════════════════

    function test_Adv_ThreeRoundsInSequence() public {
        console.log("=== THREE ROUNDS IN SEQUENCE ===");

        CurveMath.CurveConfig memory config = CurveMath.singleCurve(
            0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18
        );

        // Round 1
        _predeposit(alice, 100e18);
        _predeposit(bob, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claimAndLock(alice);
        _claimAndLock(bob);

        // M-1: locks must predate the proposal timestamp
        skip(1); // fork tests: skip() reads live time; inline block.timestamp reads fork genesis
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        skip(3 days + 1);
        controller.carpetBomb();
        skip(3 days + 1);
        controller.finalizeCarpet();
        console.log("Round 1 destroyed (and round 2 auto-spawned)");

        // Round 2: born inside carpetBomb, seeded with the carry, NOT launched —
        // it opens its own predeposit window
        PSPFactory.Round memory r2 = factory.getRound(2);
        RoundController c2 = r2.controller;
        CurveHook h2 = r2.hook;
        assertFalse(c2.predepositClosed(), "round 2 in its predeposit window");
        assertGt(mixETH.balanceOf(address(c2)), 0, "round 2 seeded with carry");

        // Owner launches round 2 (window floor is for the public, not the protocol)
        vm.prank(address(factory));
        c2.launchPooledBuy();
        console.log("Round 2 deployed + seeded + launched");

        // Round 2 state checks continue (c2 = r2.controller, h2 = r2.hook above)

        // Factory deposited all carried funds and is the sole depositor
        // PSP is minted to controller, factory claims (auto-locked)
        vm.prank(address(factory));
        c2.claimPredepositPSP();
        (uint256 factoryPSP2,,,) = c2.locks(address(factory));
        assertGt(factoryPSP2, 0, "Factory has round 2 PSP (locked)");

        // Transfer locked PSP — need to unlock first since it's auto-locked
        // Warp past lock period
        skip(90 days + 1);
        vm.prank(address(factory));
        c2.unlock();
        uint256 freePSP2 = r2.token.balanceOf(address(factory));
        assertGt(freePSP2, 0, "Factory has free PSP2");

        // Transfer PSP from factory to alice for governance
        vm.prank(address(factory));
        r2.token.transfer(alice, freePSP2);

        vm.startPrank(alice);
        r2.token.approve(address(c2), freePSP2);
        c2.lock(freePSP2);
        // M-1: locks must predate the proposal timestamp
        skip(1);
        c2.proposeCarpetBomb();
        c2.voteCarpetBomb(true);
        vm.stopPrank();

        // Warp well past voting period
        skip(3 days + 1);
        c2.carpetBomb();
        skip(3 days + 1);
        c2.finalizeCarpet();
        console.log("Round 2 destroyed");

        // Round 3: auto-spawned by round 2's bomb, seeded, in its predeposit window
        console.log("Round 3 deployed + seeded");
        assertEq(factory.currentRoundId(), 3, "3 rounds exist");
        PSPFactory.Round memory r3 = factory.getRound(3);
        assertFalse(r3.controller.predepositClosed(), "R3 in predeposit window");

        // Owner launches round 3
        vm.prank(address(factory));
        r3.controller.launchPooledBuy();
        assertEq(uint8(CurveHook(address(r3.hook)).mode()), uint8(CurveHook.Mode.Active), "R3 active");
        assertGt(CurveHook(address(r3.hook)).totalSupplyPSP(), 0, "R3 has supply");

        console.log("Round 3 supply:", CurveHook(address(r3.hook)).totalSupplyPSP());
        console.log("=== THREE ROUNDS COMPLETE ===");
    }

    // ══════════════════════════════════════════════════════════════
    //  SLIPPAGE 1: Slippage protection reverts on insufficient output
    // ══════════════════════════════════════════════════════════════

    function test_Adv_SlippageProtection() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claim(alice);

        // Try to buy with ridiculous min output (should revert)
        vm.startPrank(bob);
        mixETH.approve(address(router), 10e18);

        bool zeroForOne = _isMixETHCurrency0();
        SwapParams memory params = SwapParams({
            amountSpecified: -int256(10e18),
            sqrtPriceLimitX96: zeroForOne ? _minPrice() : _maxPrice(),
            zeroForOne: zeroForOne
        });

        // Set minOutput to max uint (impossible to satisfy)
        vm.expectRevert(V4SwapRouter.InsufficientOutput.selector);
        router.swap(poolKey, params, type(uint256).max, block.timestamp + 1);
        vm.stopPrank();

        console.log("Slippage protection: correctly reverted");
    }

    // ══════════════════════════════════════════════════════════════
    //  SLIPPAGE 2: Deadline check reverts on expired tx
    // ══════════════════════════════════════════════════════════════

    function test_Adv_DeadlineProtection() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claim(alice);

        vm.startPrank(bob);
        mixETH.approve(address(router), 10e18);

        bool zeroForOne = _isMixETHCurrency0();
        SwapParams memory params = SwapParams({
            amountSpecified: -int256(10e18),
            sqrtPriceLimitX96: zeroForOne ? _minPrice() : _maxPrice(),
            zeroForOne: zeroForOne
        });

        // Set deadline in the past
        vm.expectRevert(V4SwapRouter.Expired.selector);
        router.swap(poolKey, params, 0, block.timestamp - 1);
        vm.stopPrank();

        console.log("Deadline protection: correctly reverted");
    }

    // ══════════════════════════════════════════════════════════════
    //  SLIPPAGE 3: Reasonable slippage allows valid swaps
    // ══════════════════════════════════════════════════════════════

    function test_Adv_ReasonableSlippagePasses() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claim(alice);

        // First buy to see what output looks like
        _buy(bob, 10e18);
        uint256 pspFromFirstBuy = pspToken.balanceOf(bob);

        // Carol buys with conservative slippage (50% of expected output)
        vm.startPrank(carol);
        mixETH.approve(address(router), 10e18);

        bool zeroForOne = _isMixETHCurrency0();
        SwapParams memory params = SwapParams({
            amountSpecified: -int256(10e18),
            sqrtPriceLimitX96: zeroForOne ? _minPrice() : _maxPrice(),
            zeroForOne: zeroForOne
        });

        uint256 minOut = pspFromFirstBuy / 2; // 50% slippage tolerance
        router.swap(poolKey, params, minOut, block.timestamp + 300);
        vm.stopPrank();

        assertGt(pspToken.balanceOf(carol), minOut, "Carol got >= min output");
        console.log("Carol PSP with slippage:", pspToken.balanceOf(carol));
    }

    // ══════════════════════════════════════════════════════════════
    //  EDGE 1: Simultaneous buys from multiple users (same block)
    // ══════════════════════════════════════════════════════════════

    function test_Adv_SimultaneousBuysSameBlock() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claim(alice);

        uint256 reserveBefore = hook.reserveMixETH();
        uint256 supplyBefore = hook.totalSupplyPSP();

        // 3 users buy in the same block
        _buy(alice, 10e18);
        _buy(bob, 20e18);
        _buy(carol, 15e18);

        uint256 reserveAfter = hook.reserveMixETH();
        uint256 supplyAfter = hook.totalSupplyPSP();

        uint256 totalInput = 10e18 + 20e18 + 15e18;
        // 95% curve + 0.25% side-pot PSP mint (both enter the reserve);
        // 4.75% is the staker fee, held over the reserve
        assertEq(reserveAfter - reserveBefore, totalInput - (totalInput * 475) / 10000,
                 "Reserve increased by total minus staker fees");
        assertGt(supplyAfter, supplyBefore, "Supply increased");

        console.log("=== Same-Block Sequential Buys ===");
        console.log("Alice PSP:", pspToken.balanceOf(alice));
        console.log("Bob PSP:", pspToken.balanceOf(bob));
        console.log("Carol PSP:", pspToken.balanceOf(carol));
        console.log("Supply delta:", supplyAfter - supplyBefore);
    }

    // ══════════════════════════════════════════════════════════════
    //  EDGE 2: Repeated dust buys accumulate correctly
    // ══════════════════════════════════════════════════════════════

    function test_Adv_RepeatedDustBuys() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claim(alice);

        // 20 buys of 0.1 mixETH each
        uint256 perBuy = 0.1e18;
        for (uint256 i = 0; i < 20; i++) {
            _buy(bob, perBuy);
        }

        uint256 bobPSP = pspToken.balanceOf(bob);
        assertGt(bobPSP, 0, "Bob accumulated PSP");

        // Compare to single bulk buy of 2 mixETH
        _buy(carol, 2e18);
        uint256 carolPSP = pspToken.balanceOf(carol);

        console.log("=== Dust vs Bulk ===");
        console.log("20x0.1 buys:", bobPSP);
        console.log("1x2 bulk buy:", carolPSP);

        // Carol should get slightly more (lower effective price since she buys earlier on curve)
        // Actually bob buys first (supply lower), so bob should get slightly more per unit
        // But both buy over the same supply range, difference is rounding dust
        assertApproxEqRel(bobPSP, carolPSP, 0.01e18, "Dust ~ Bulk within 1%");
    }

    // ══════════════════════════════════════════════════════════════
    //  EDGE 3: Sell almost all supply (1 wei remaining)
    // ══════════════════════════════════════════════════════════════

    function test_Adv_SellAlmostAllSupply() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claim(alice);

        _buy(bob, 10e18);
        uint256 bobPSP = pspToken.balanceOf(bob);

        // Sell all but 1 wei
        if (bobPSP > 1) {
            _sell(bob, bobPSP - 1);
        }

        assertEq(pspToken.balanceOf(bob), 1, "Bob has 1 wei PSP left");
        assertGt(hook.totalSupplyPSP(), 0, "Supply > 0");

        console.log("=== Near-Total Sell ===");
        console.log("Bob remaining PSP:", pspToken.balanceOf(bob));
        console.log("Hook supply:", hook.totalSupplyPSP());
        console.log("Hook reserve:", hook.reserveMixETH());
    }

    // ══════════════════════════════════════════════════════════════
    //  HELPERS
    // ══════════════════════════════════════════════════════════════

    function _deployRound() internal {
        CurveMath.CurveConfig memory config = CurveMath.singleCurve(
            0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18
        );

        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: config
        });

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

    function _claim(address user) internal returns (uint256) {
        vm.prank(user);
        controller.claimPredepositPSP();
        (uint256 amount,,,) = controller.locks(user);
        return amount;
    }

    function _claimAndLock(address user) internal {
        _claim(user);
    }

    function _lock(address user, uint256 amount) internal {
        vm.startPrank(user);
        pspToken.approve(address(controller), amount);
        controller.lock(amount);
        vm.stopPrank();
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
