// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

import {MainnetConfig} from "./MainnetConfig.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";

/// @title ChaosForkTest — End-to-end adversarial scenarios on the real V4 stack
/// @notice Zombie rounds, concurrent pools, atomic MEV churn, cross-round pollution.
contract ChaosForkTest is Test {
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;

    // Round state (multiple rounds for chaos tests)
    struct RoundCtx {
        PSPToken token;
        RoundController controller;
        CurveHook hook;
        PoolKey key;
    }

    RoundCtx r1;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        poolManager = IPoolManager(MainnetConfig.POOL_MANAGER);

        mixETH = new MockMixETH();
        mixETH.depositETH{value: 1_000_000e18}();

        factory = new PSPFactory(poolManager, mixETH);

        mixETH.transfer(alice, 50_000e18);
        mixETH.transfer(bob, 50_000e18);
        mixETH.transfer(carol, 50_000e18);
        mixETH.transfer(attacker, 50_000e18);

        r1 = _deployRound();
        _launchRound(r1, alice, 100e18);
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 1: Zombie pool — swaps after carpetBomb revert
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_ZombiePoolRejectsSwaps() public {
        // Warm the pool with a real swap first
        _buy(r1, bob, 10e18);

        // Carpet bomb (69% quorum: alice predeposit-locked everything)
        vm.prank(alice);
        r1.controller.proposeCarpetBomb();
        vm.prank(alice);
        r1.controller.voteCarpetBomb(true);
        vm.warp(block.timestamp + 3 days + 1);
        r1.controller.carpetBomb();

        assertEq(uint8(r1.hook.mode()), uint8(CurveHook.Mode.Destroyed));

        // Buy on the corpse → NotActive
        _approveBuy(r1, bob, 1e18);
        vm.expectRevert();
        _unlockBuy(r1, bob, 1e18);

        // Sell on the corpse → NotActive
        uint256 bobPSP = r1.token.balanceOf(bob);
        assertGt(bobPSP, 0);
        _approveSell(r1, bob, bobPSP);
        vm.expectRevert();
        _unlockSell(r1, bob, bobPSP);
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 2: Locking into a zombie round is REJECTED (Z-1 fixed)
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_ZombieLockAfterBomb() public {
        _buy(r1, bob, 10e18);

        vm.prank(alice);
        r1.controller.proposeCarpetBomb();
        vm.prank(alice);
        r1.controller.voteCarpetBomb(true);
        vm.warp(block.timestamp + 3 days + 1);
        r1.controller.carpetBomb();

        // Bob tries to lock his PSP into the dead round → rejected
        vm.prank(bob);
        r1.token.approve(address(r1.controller), 10e18);
        vm.prank(bob);
        vm.expectRevert(RoundController.RoundDestroyed.selector);
        r1.controller.lock(10e18);

        (uint256 amt,,,) = r1.controller.locks(bob);
        assertEq(amt, 0, "no zombie lock created");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 3: Two concurrent rounds — no state pollution between pools
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_TwoConcurrentRoundsIsolated() public {
        // Round 1 is active. Deploy round 2 WITHOUT destroying round 1.
        RoundCtx memory r2 = _deployRound();
        _launchRound(r2, carol, 100e18);

        // Both pools trade
        _buy(r1, bob, 5e18);
        _buy(r2, alice, 7e18);

        // Reserves are isolated per round
        assertGt(r1.hook.totalSupplyPSP(), 0);
        assertGt(r2.hook.totalSupplyPSP(), 0);

        // Round 1's PSP is useless in round 2's pool: different PoolKey
        // (PSP1 not a currency in pool 2 — selling there is structurally impossible)
        uint256 bobPSP1 = r1.token.balanceOf(bob);
        assertGt(bobPSP1, 0);
        assertEq(r2.token.balanceOf(bob), 0, "no cross-round PSP leakage");

        // Bob sells in r1 — r2 state untouched
        uint256 r2SupplyBefore = r2.hook.totalSupplyPSP();
        _sell(r1, bob, bobPSP1);
        assertEq(r2.hook.totalSupplyPSP(), r2SupplyBefore, "r2 polluted by r1 sell");

        // Carol's predeposit claim auto-locked during launch — verify
        (uint256 carolAmt,,,) = r2.controller.locks(carol);
        assertGt(carolAmt, 0);
        (uint256 aliceAmt,,,) = r1.controller.locks(alice);
        assertGt(aliceAmt, 0, "r1 lock vanished");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 4: Atomic multi-swap churn — MEV bot in ONE unlock callback
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_AtomicChurnLosesMoney() public {
        AtomicChurner churner = new AtomicChurner(poolManager);

        // Fund the churner
        mixETH.transfer(address(churner), 20e18);

        uint256 cycles = 4;
        uint256 buySize = 3e18;

        uint256 mixBefore = mixETH.balanceOf(address(churner));
        churner.churn(r1.key, cycles, buySize);
        uint256 mixAfter = mixETH.balanceOf(address(churner));

        console.log("churner start:", mixBefore);
        console.log("churner end:  ", mixAfter);
        console.log("net loss:", int256(mixBefore) - int256(mixAfter));

        // MEV bot doing 4 atomic buy-sell cycles must LOSE money
        // (2 x 5% fees per cycle + curve round-trip slippage)
        assertLt(mixAfter, mixBefore, "atomic churn extracted value!");
        // No PSP dust left in the churner (it sold everything)
        assertEq(r1.token.balanceOf(address(churner)), 0, "churner left PSP behind");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 5: Carpet bomb → deployNextRound full chaos sequence
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_BombAndRebornRoundTrades() public {
        // Multiple participants
        _buy(r1, bob, 20e18);
        _buy(r1, carol, 15e18);

        uint256 r1Supply = r1.hook.totalSupplyPSP();
        uint256 r1Reserve = r1.hook.reserveMixETH();

        // Bomb it
        vm.prank(alice);
        r1.controller.proposeCarpetBomb();
        vm.prank(alice);
        r1.controller.voteCarpetBomb(true);
        vm.warp(block.timestamp + 3 days + 1);
        r1.controller.carpetBomb();

        // Factory received everything
        uint256 factoryBalance = mixETH.balanceOf(address(factory));
        assertGe(factoryBalance, r1Reserve, "factory got less than the reserve");

        // deployNextRound: one call, new round seeded + launched
        CurveMath.CurveConfig memory config = _curveConfig();
        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "PSP Round 2", symbol: "PSP2", curveConfig: config
        });
        (uint256 roundId2,) = factory.deployNextRound(1, params);
        assertEq(roundId2, 2);

        PSPFactory.Round memory r2 = factory.getRound(2);
        assertGt(r2.hook.totalSupplyPSP(), 0, "round 2 launched with carried funds");
        assertGt(r2.hook.reserveMixETH(), 0, "round 2 has reserves");
        assertEq(mixETH.balanceOf(address(factory)), 0, "factory emptied");

        // New round trades normally; old round is dead
        _buy(_ctx(2), attacker, 5e18);
        _approveBuy(r1, attacker, 1e18);
        vm.expectRevert();
        _unlockBuy(r1, attacker, 1e18);

        console.log("r1 supply (dead):", r1Supply);
        console.log("r2 supply (born):", r2.hook.totalSupplyPSP());
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 6: Direct PoolManager swap without pre-settling — flash-accounting abuse
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_UnfundedSwapRevertsCleanly() public {
        // Attacker calls poolManager.swap inside unlock WITHOUT sending input
        // tokens first. The hook's take() should revert (insufficient reserves
        // in PM) — no free PSP minting from thin air.
        NakedSwapper naked = new NakedSwapper(poolManager);
        vm.expectRevert();
        naked.tryFreeSwap(r1.key, 1e18);
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 6b: Dust swaps below MIN_SWAP_INPUT revert (C-1 guard)
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_DustSwapReverts() public {
        // Buy below min → reverts (hook's SwapTooSmall wrapped by V4)
        _approveBuy(r1, attacker, 1e11);
        vm.expectRevert();
        _unlockBuy(r1, attacker, 1e11);

        // Exactly at min → allowed
        _buy(r1, attacker, 1e12);
        uint256 pspGot = r1.token.balanceOf(attacker);
        assertGt(pspGot, 0, "min-size buy works");

        // Sell below min → reverts
        _approveSell(r1, attacker, 1e11);
        vm.expectRevert();
        _unlockSell(r1, attacker, 1e11);
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 6c: Zero-output swaps revert, never absorb input (I-2)
    // ═══════════════════════════════════════════════════════════════

    /// @dev A buy above MIN_SWAP_INPUT whose output floors to 0 wei PSP
    ///      must revert instead of silently absorbing the input.
    function test_Fork_ZeroOutputBuyReverts() public {
        // Price the round so high that a min-scale buy mints 0 PSP:
        // output = input * 1e18 / P0 floors to zero when input << P0
        CurveMath.CurveConfig memory insane = CurveMath.singleCurve(
            1e30, // P0: 1e30 ETH per PSP
            100_000_000e18,
            0.0000000046e18,
            0.05e18
        );
        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Insane Pepes",
            symbol: "IPSP",
            curveConfig: insane
        });
        (uint256 roundId,) = factory.deployRound(params);
        RoundCtx memory ctx = _ctx(roundId);
        _launchRound(ctx, alice, 100e18);

        // Exactly MIN_SWAP_INPUT: after the 5% fee haircut the curve input
        // is 0.95e12, and 0.95e12 * 1e18 / 1e30 floors to 0 wei PSP
        // → ZeroOutput (wrapped by V4). C-1 alone cannot catch this —
        // the input clears the min but buys nothing at P0 = 1e30.
        _approveBuy(ctx, attacker, 1e12);
        vm.expectRevert();
        _unlockBuy(ctx, attacker, 1e12);

        // Nothing was absorbed: no PSP minted, input balance untouched
        assertEq(ctx.token.balanceOf(attacker), 0, "no PSP minted from nothing");
        assertEq(mixETH.balanceOf(attacker), 50_000e18, "no input absorbed");
        _assertPoolSolvent(ctx);
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 7: Interleaved buy/sell across both rounds in the same block
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_InterleavedSameBlockMultiPool() public {
        RoundCtx memory r2 = _deployRound();
        _launchRound(r2, carol, 100e18);

        uint256 snapshot = vm.snapshotState();

        // Attacker alternates: buy r1, buy r2, sell r1, buy r1, sell r2
        _buy(r1, attacker, 3e18);
        _buy(r2, attacker, 4e18);
        _sell(r1, attacker, r1.token.balanceOf(attacker));
        _buy(r1, attacker, 2e18);
        _sell(r2, attacker, r2.token.balanceOf(attacker));

        // Attacker must have lost money across the interleave
        uint256 mixNow = mixETH.balanceOf(attacker);
        assertLt(mixNow, 50_000e18, "interleaved multi-pool churn profited");

        // Both pools still solvent: reserves ≤ hook balances
        _assertPoolSolvent(r1);
        _assertPoolSolvent(r2);

        vm.revertToState(snapshot);
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 8: Fee self-dealing on the real stack — sole locker rebate
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_SoleLockerCapturesAllSwapFees() public {
        // Alice predeposit-claimed → she's the sole locker
        (uint256 aliceLock,,,) = r1.controller.locks(alice);
        assertGt(aliceLock, 0);
        assertEq(r1.controller.totalLocked(), aliceLock, "alice is sole locker");

        // Bob churns: every buy pays 5% to the accumulator
        uint256 aliceMixBefore = mixETH.balanceOf(alice);
        _buy(r1, bob, 10e18);
        _buy(r1, bob, 10e18);
        _buy(r1, bob, 10e18);

        vm.prank(alice);
        r1.controller.claimFees();
        uint256 aliceFees = mixETH.balanceOf(alice) - aliceMixBefore;

        // ~5% of 30 ETH = 1.5 ETH to the sole locker
        assertApproxEqRel(aliceFees, 1.5e18, 5e16, "sole locker rebate mismatch");
        console.log("sole locker extracted from bob's churn:", aliceFees);
    }

    // ═══════════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _curveConfig() internal pure returns (CurveMath.CurveConfig memory) {
        return CurveMath.singleCurve(
            0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18
        );
    }

    function _deployRound() internal returns (RoundCtx memory ctx) {
        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: _curveConfig()
        });

        (uint256 roundId,) = factory.deployRound(params);
        return _ctx(roundId);
    }

    function _ctx(uint256 roundId) internal view returns (RoundCtx memory ctx) {
        PSPFactory.Round memory r = factory.getRound(roundId);
        ctx.token = r.token;
        ctx.controller = r.controller;
        ctx.hook = r.hook;

        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(address(r.token));
        if (c0 > c1) (c0, c1) = (c1, c0);
        ctx.key = PoolKey({
            currency0: c0, currency1: c1,
            fee: 0x800000, tickSpacing: 60, hooks: r.hook
        });
    }

    function _launchRound(RoundCtx memory ctx, address predepositor, uint256 amount) internal {
        vm.prank(predepositor);
        mixETH.approve(address(ctx.controller), amount);
        vm.prank(predepositor);
        ctx.controller.predeposit(amount);
        vm.prank(address(factory));
        ctx.controller.launchPooledBuy();
        // Claim predeposit PSP (auto-locks vlCVX-style) so governance works
        vm.prank(predepositor);
        ctx.controller.claimPredepositPSP();
        // M-1: locks must predate any proposal timestamp (tests propose right after)
        vm.warp(block.timestamp + 1);
    }

    function _buy(RoundCtx memory ctx, address user, uint256 mixAmount) internal {
        _approveBuy(ctx, user, mixAmount);
        _unlockBuy(ctx, user, mixAmount);
    }

    /// @dev Approve only — call before vm.expectRevert so the revert
    ///      assertion targets the unlock/swap, not the successful approve
    function _approveBuy(RoundCtx memory ctx, address user, uint256 mixAmount) internal {
        vm.prank(user);
        mixETH.approve(address(this), mixAmount);
    }

    function _unlockBuy(RoundCtx memory ctx, address user, uint256 mixAmount) internal {
        bool zeroForOne = Currency.wrap(address(mixETH)) == ctx.key.currency0;
        poolManager.unlock(abi.encode(
            user, address(mixETH), mixAmount, ctx.key, mixAmount, zeroForOne
        ));
    }

    function _sell(RoundCtx memory ctx, address user, uint256 pspAmount) internal {
        _approveSell(ctx, user, pspAmount);
        _unlockSell(ctx, user, pspAmount);
    }

    function _approveSell(RoundCtx memory ctx, address user, uint256 pspAmount) internal {
        vm.prank(user);
        ctx.token.approve(address(this), pspAmount);
    }

    function _unlockSell(RoundCtx memory ctx, address user, uint256 pspAmount) internal {
        bool zeroForOne = !(Currency.wrap(address(mixETH)) == ctx.key.currency0);
        poolManager.unlock(abi.encode(
            user, address(ctx.token), pspAmount, ctx.key, pspAmount, zeroForOne
        ));
    }

    function _assertPoolSolvent(RoundCtx memory ctx) internal view {
        uint256 balance = mixETH.balanceOf(address(ctx.hook));
        assertGe(balance, ctx.hook.reserveMixETH(), "hook balance below reserve");
    }

    // Router callback: decode our hack payload and execute pre-settle + swap + take
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not PM");
        (
            address user,
            address tokenIn,
            uint256 amount,
            PoolKey memory key,
            int256 amountSpecified,
            bool zeroForOne
        ) = abi.decode(data, (address, address, uint256, PoolKey, int256, bool));

        SwapParams memory sp = SwapParams({
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne
                ? 4295128740
                : 1461446703485210103287273052203988822378723970341,
            zeroForOne: zeroForOne
        });

        Currency inCur = Currency.wrap(tokenIn);
        poolManager.sync(inCur);
        SafeERC20.safeTransferFrom(IERC20(tokenIn), user, address(poolManager), amount);
        poolManager.settle();

        BalanceDelta delta = poolManager.swap(key, sp, "");
        if (delta.amount0() > 0) poolManager.take(key.currency0, user, uint256(int256(delta.amount0())));
        if (delta.amount1() > 0) poolManager.take(key.currency1, user, uint256(int256(delta.amount1())));
        return "";
    }
}

/// @title AtomicChurner — MEV bot doing N buy-sell cycles in ONE unlock
contract AtomicChurner {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _pm) {
        poolManager = _pm;
    }

    function churn(PoolKey calldata key, uint256 cycles, uint256 buySize) external {
        poolManager.unlock(abi.encode(key, cycles, buySize));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not PM");
        (PoolKey memory key, uint256 cycles, uint256 buySize) =
            abi.decode(data, (PoolKey, uint256, uint256));

        IERC20 mix = IERC20(Currency.unwrap(key.currency0));
        IERC20 psp = IERC20(Currency.unwrap(key.currency1));

        for (uint256 i = 0; i < cycles; i++) {
            // BUY: settle mix in, swap, take PSP out
            poolManager.sync(key.currency0);
            mix.safeTransfer(address(poolManager), buySize);
            poolManager.settle();

            BalanceDelta buyDelta = poolManager.swap(key, SwapParams({
                amountSpecified: -int256(buySize),
                sqrtPriceLimitX96: 4295128740,
                zeroForOne: true
            }), "");

            uint256 pspOut;
            if (buyDelta.amount1() > 0) {
                pspOut = uint256(int256(buyDelta.amount1()));
                poolManager.take(key.currency1, address(this), pspOut);
            } else {
                pspOut = psp.balanceOf(address(this));
            }

            // SELL: settle PSP in, swap, take mix out
            poolManager.sync(key.currency1);
            psp.safeTransfer(address(poolManager), pspOut);
            poolManager.settle();

            BalanceDelta sellDelta = poolManager.swap(key, SwapParams({
                amountSpecified: -int256(pspOut),
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341,
                zeroForOne: false
            }), "");

            if (sellDelta.amount0() > 0) {
                poolManager.take(key.currency0, address(this), uint256(int256(sellDelta.amount0())));
            }
        }
        return "";
    }
}

/// @title NakedSwapper — swaps without funding the PoolManager first
contract NakedSwapper {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _pm) {
        poolManager = _pm;
    }

    function tryFreeSwap(PoolKey calldata key, uint256 amount) external {
        poolManager.unlock(abi.encode(key, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 amount) = abi.decode(data, (PoolKey, uint256));
        // NO pre-settle: swap directly, hoping the hook mints PSP from nothing
        poolManager.swap(key, SwapParams({
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: 4295128740,
            zeroForOne: true
        }), "");
        return "";
    }
}
