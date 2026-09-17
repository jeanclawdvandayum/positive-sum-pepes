// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RealV4Base} from "./RealV4Lifecycle.t.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// AUDIT PoC SUITE - evm-cortex re-audit of single-sine-spec (d0e5507b)
// (2026-09-16, scoopy: "verify every finding with a poc, dont fix just report").
// Targets the integration gaps left by the Sept-15 battery (114 v3 tests):
// quote-vs-execution parity (V3-INT-3/5 fix sites had ZERO direct coverage),
// the ticket-intent guard end-to-end, pre-fee ticket sampling, and the
// binding minimum asymmetry. No src changes; tests assert OBSERVED behavior.
contract SineV3AuditPoC is RealV4Base {
    address trader = makeAddr("poct-trader");
    address rival = makeAddr("poct-rival");
    GuardedSwapper swapper;

    function setUp() public override {
        super.setUp();
        swapper = new GuardedSwapper(poolManager, IERC20(address(mixETH)));
        mixETH.depositETH{value: 1_000_000e18}();
        mixETH.transfer(trader, 500_000e18);
        mixETH.transfer(rival, 500_000e18);
        vm.startPrank(trader);
        mixETH.approve(address(swapper), type(uint256).max);
        IERC20(address(pspToken)).approve(address(swapper), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(rival);
        mixETH.approve(address(swapper), type(uint256).max);
        IERC20(address(pspToken)).approve(address(swapper), type(uint256).max);
        vm.stopPrank();
    }

    /* ---------------------------------------------------------------
       T1 - Quote vs execution parity, BUYS (V3-INT-3 fix site).
       sineBuyQuote(x) must equal the real V4 output for the same x,
       and revert exactly where execution reverts. A mismatch is a
       sandwich/UX trap: quotes are what frontends protect users with.
       --------------------------------------------------------------- */
    function test_T1_BuyQuoteMatchesExecution() public {
        uint256 tp = hook.ticketPrice();
        uint256[4] memory spends = [tp, tp * 3, 1e18, 50e18];
        for (uint256 i; i < spends.length; ++i) {
            uint256 q = hook.getBuyOutput(spends[i]);
            vm.prank(trader);
            uint256 got = swapper.buy(poolKey, spends[i], trader, trader, 0);
            assertEq(q, got, "T1: buy quote != execution");
        }
        // reverts agree: a below-minimum spend reverts in BOTH paths
        // (guard order: SwapTooSmall fires before ZeroOutput in the quote)
        vm.expectRevert(CurveHook.SwapTooSmall.selector);
        hook.getBuyOutput(tp - 1);
        vm.prank(trader);
        vm.expectRevert(); // WrappedError-wrapped at the PM boundary
        swapper.buy(poolKey, tp - 1, trader, trader, 0);
    }

    /* ---------------------------------------------------------------
       T2 - Quote vs execution parity, SELLS (V3-INT-5 fix site),
       including the fee slice and the supply guard.
       --------------------------------------------------------------- */
    function test_T2_SellQuoteMatchesExecution() public {
        vm.prank(trader);
        uint256 psp = swapper.buy(poolKey, 100e18, trader, trader, 0);
        uint256 half = psp / 2;

        uint256 q = hook.getSellOutput(half);
        vm.prank(trader);
        uint256 got = swapper.sell(poolKey, half, trader);
        assertEq(q, got, "T2: sell quote != execution");

        // supply guard parity: selling the whole supply reverts in both
        uint256 total = hook.totalSupplyPSP();
        vm.expectRevert(CurveHook.SellExceedsSupply.selector);
        hook.getSellOutput(total);
        vm.prank(trader);
        vm.expectRevert(); // wrapped
        swapper.sell(poolKey, total, trader);
    }

    /* ---------------------------------------------------------------
       T3 - TicketPriceMoved guard, end-to-end through real V4.
       A guarded route pins the quoted ladder price; a rival fee event
       that reprices the pot must trip the guard, and the tight guard
       (== current price) must NOT trip on the trader's own buy.
       --------------------------------------------------------------- */
    function test_T3_TicketGuardEndToEnd() public {
        uint256 tp0 = hook.ticketPrice();
        // rival's fee event reprices the pot upward
        vm.prank(rival);
        swapper.buy(poolKey, 100e18, rival, rival, 0);
        uint256 tp1 = hook.ticketPrice();
        assertGt(tp1, tp0, "rival fee event must raise the ticket price");

        // stale guard trips (WrappedError at the unlock boundary)
        vm.prank(trader);
        vm.expectRevert();
        swapper.buy(poolKey, tp1 * 2, trader, trader, tp0);

        // current-price guard passes; own fee never trips it (pre-fee sample)
        uint256 tp2 = hook.ticketPrice();
        vm.prank(trader);
        uint256 got = swapper.buy(poolKey, tp2 * 2, trader, trader, tp2);
        assertGt(got, 0, "T3: guarded buy at current price succeeds");
    }

    /* ---------------------------------------------------------------
       T4 - Pre-fee ticket sampling: a buy of EXACTLY one spot earns
       exactly one unit (clock +TIME_PER_UNIT), even though its own
       fee grows the pot for later buyers.
       --------------------------------------------------------------- */
    function test_T4_PreFeeSamplingOneSpotOneUnit() public {
        skip(1 hours); // clock headroom: the 72h cap absorbs same-block adds
        uint256 tp = hook.ticketPrice();
        uint256 before = hook.detonationAt();
        vm.prank(trader);
        swapper.buy(poolKey, tp, trader, trader, 0);
        assertEq(hook.detonationAt() - before, hook.TIME_PER_UNIT(), "T4: one spot = one unit");
        assertGt(hook.ticketPrice(), tp, "T4: the buy's own fee repriced LATER spots");
    }

    /* ---------------------------------------------------------------
       T5 - The current ladder spot is the BINDING buy minimum on v3
       rounds: tp-1 wei reverts, tp passes.
       --------------------------------------------------------------- */
    function test_T5_TicketPriceIsTheBindingMinimum() public {
        uint256 tp = hook.ticketPrice();
        vm.prank(trader);
        vm.expectRevert(); // SwapTooSmall, WrappedError-wrapped
        swapper.buy(poolKey, tp - 1, trader, trader, 0);
        vm.prank(trader);
        uint256 got = swapper.buy(poolKey, tp, trader, trader, 0);
        assertGt(got, 0, "T5: exactly one spot passes");
    }

    /* ---------------------------------------------------------------
       T6 - Sell-side minimum asymmetry: v3 buys are exempt from the
       dust guard, but SELLS keep MIN_SWAP_INPUT on sine rounds.
       --------------------------------------------------------------- */
    function test_T6_SellsKeepTheDustGuard() public {
        vm.prank(trader);
        uint256 psp = swapper.buy(poolKey, 10e18, trader, trader, 0);
        uint256 min = hook.MIN_SWAP_INPUT(); // hoisted: getters eat prank/expectRevert
        vm.prank(trader);
        vm.expectRevert(); // SwapTooSmall, WrappedError-wrapped
        swapper.sell(poolKey, min - 1, trader);
        vm.prank(trader);
        uint256 got = swapper.sell(poolKey, min, trader);
        assertGt(got, 0, "T6: at the minimum, sells pass");
        assertGt(psp, 0);
    }
}

/// @dev Minimal V4 router: like wave2's TicketSwapper, plus the v3 guarded
///      route (64-byte hookData = (trader, maxTicketPrice)) and a sell leg.
contract GuardedSwapper {
    IPoolManager public immutable pm;
    IERC20 public immutable mix;

    constructor(IPoolManager _pm, IERC20 _mix) {
        pm = _pm;
        mix = _mix;
    }

    function buy(PoolKey calldata key, uint256 mixIn, address to, address trader, uint256 maxTicketPrice)
        external
        returns (uint256 pspOut)
    {
        mix.transferFrom(msg.sender, address(this), mixIn);
        bytes memory r = pm.unlock(abi.encode(key, mixIn, to, trader, maxTicketPrice, false));
        return abi.decode(r, (uint256));
    }

    function sell(PoolKey calldata key, uint256 pspIn, address to) external returns (uint256 mixOut) {
        // pull the PSP first (non-mix currency), like the reference SellRouter
        IERC20(Currency.unwrap(key.currency1 == Currency.wrap(address(mix)) ? key.currency0 : key.currency1))
            .transferFrom(msg.sender, address(this), pspIn);
        bytes memory r = pm.unlock(abi.encode(key, pspIn, to, address(0), 0, true));
        return abi.decode(r, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, uint256 amt, address to, address trader, uint256 maxTicketPrice, bool isSell) =
            abi.decode(data, (PoolKey, uint256, address, address, uint256, bool));
        bool mixIsZero = Currency.unwrap(key.currency0) == address(mix);
        Currency mixCur = mixIsZero ? key.currency0 : key.currency1;
        Currency pspCur = mixIsZero ? key.currency1 : key.currency0;

        if (!isSell) {
            pm.sync(mixCur);
            mix.transfer(address(pm), amt);
            pm.settle();
            BalanceDelta d = pm.swap(
                key,
                SwapParams({
                    amountSpecified: -int256(amt),
                    sqrtPriceLimitX96: mixIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                    zeroForOne: mixIsZero
                }),
                maxTicketPrice != 0 ? abi.encode(trader, maxTicketPrice) : abi.encode(trader)
            );
            int256 pspDelta = mixIsZero ? d.amount1() : d.amount0();
            require(pspDelta > 0, "no out");
            uint256 out = uint256(int256(pspDelta));
            pm.take(pspCur, to, out);
            return abi.encode(out);
        } else {
            pm.sync(pspCur);
            IERC20(Currency.unwrap(pspCur)).transfer(address(pm), amt);
            pm.settle();
            BalanceDelta d = pm.swap(
                key,
                SwapParams({
                    amountSpecified: -int256(amt), // exact input of pspIn
                    sqrtPriceLimitX96: mixIsZero ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1,
                    zeroForOne: !mixIsZero
                }),
                "" // sells do not decode hookData
            );
            int256 mixDelta = mixIsZero ? d.amount0() : d.amount1();
            require(mixDelta > 0, "no out");
            uint256 out = uint256(int256(mixDelta));
            pm.take(mixCur, to, out);
            return abi.encode(out);
        }
    }
}
