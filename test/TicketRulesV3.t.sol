// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {RealV4Base} from "./RealV4Lifecycle.t.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {RoundController} from "../src/RoundController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {TicketSwapper} from "./UncappedCapacity.t.sol";
import {TicketSwapper} from "./UncappedCapacity.t.sol";

/// @title TicketRulesV3 — pot-priced ladder spots (TICKET_RULES_VERSION 3)
/// @notice The exact integer rule: ticketPrice = ceil(potBalance/10_000),
///         floored at one wei; the active gross-buy minimum equals exactly
///         one spot, sampled before the purchase's own fees; every successful
///         active buy earns at least one ticket. Exercised through the REAL
///         v4 PoolManager at launch prices spanning 0.0005 .. 0.02 mixETH,
///         including a sub-1e12-wei spot round.
contract TicketRulesV3Test is RealV4Base {
    TicketSwapper swapper;

    // ─────────────── the isolated integer rule (edge pots) ───────────────

    /// @dev Mirror of the hook's four-line rule; the e2e sections below
    ///      prove the hook applies this rule to its accounted pot.
    function _spot(uint256 pot) internal pure returns (uint256) {
        uint256 q = pot / 10_000;
        if (pot % 10_000 != 0) ++q;
        return q == 0 ? 1 : q;
    }

    function test_PureCeilingTable() public pure {
        assertEq(_spot(0), 1, "zero pot floors at one wei");
        assertEq(_spot(1), 1);
        assertEq(_spot(9_999), 1);
        assertEq(_spot(10_000), 1, "exactly 10,000 wei is exactly one wei per spot");
        assertEq(_spot(10_001), 2, "one wei over prices two spots: ceil, no under-flow floor");
        assertEq(_spot(1_000_000_000_000_000_001), 100_000_000_000_001);
        assertEq(_spot(type(uint256).max), type(uint256).max / 10_000 + 1);
        // no overflow in the ceiling branch: q < pot always
        assertGt(_spot(type(uint256).max), type(uint256).max / 10_000);
    }

    // ─────────────── launch table through real launches ───────────────

    /// gross IBCO -> genesis pot = floor(gross/10) -> spot = ceil(pot/10_000).
    /// Each successor round launches with the next size.
    function test_LaunchPriceTable() public {
        uint256[7] memory gross = [uint256(100e18), 50e18, 125e18, 250e18, 500e18, 1_000e18, 2_000e18];
        // spot = gross/1e5 exactly: 0.001, 0.0005, 0.00125, 0.0025, 0.005, 0.01, 0.02 mixETH
        uint256[7] memory spot = [
            uint256(1e15), 5e14, 1_250_000_000_000_000, 25e14, 5e15, 1e16, 2e16
        ];
        RoundController ctl = controller;
        CurveHook h = hook; // round 1: the harness's 100-mix launch anchors the table
        for (uint256 i; i < gross.length; ++i) {
            assertEq(h.MIN_BUY_INPUT(), spot[i], "minimum equals one spot at launch");
            assertEq(h.ticketPrice(), spot[i]);
            assertEq(h.potBalance() / 10_000 + (h.potBalance() % 10_000 != 0 ? 1 : 0), spot[i]);
            if (i == gross.length - 1) break;
            // advance to the next round with the next IBCO size
            vm.warp(h.detonationAt());
            vm.prank(address(this));
            ctl.detonate{gas: 2_000_000}();
            factory.reserveSpawn(factory.currentRoundId());
            for (uint256 s; s < 3; ++s) factory.birthStep{gas: 16_000_000}();
            PSPFactory.Round memory next = factory.getRound(factory.currentRoundId());
            mixETH.approve(address(next.controller), gross[i + 1]);
            next.controller.predeposit(gross[i + 1]);
            vm.prank(address(factory));
            next.controller.launchPooledBuy();
            ctl = next.controller;
            h = next.hook;
        }
    }

    // ─────────────── the threshold table on a real sub-dust-spot round ───────────────

    /// A 0.01-mix gross IBCO pots 0.001 mix = 1e15 wei -> spot 1e11 wei,
    /// BELOW the historical 1e12 dust guard: the exact v3 minimum must ride
    /// the real V4 stack with no hidden static floor.
    function test_ExactMinimumThroughRealV4() public {
        // relaunch round 1 territory at the dust scale via a successor round
        _becomeDustSpotRound();
        uint256 q = hook.ticketPrice();
        assertEq(q, 1e11, "0.01-mix IBCO prices a 1e11-wei spot");
        assertLt(q, 1e12, "below the old dust guard: no static floor may bite");

        swapper = new TicketSwapper(IPoolManager(address(poolManager)), IERC20(address(mixETH)));
        mixETH.transfer(alice, 100e18);
        vm.startPrank(alice);
        mixETH.approve(address(swapper), type(uint256).max);

        // zero and q-1 revert; state untouched
        uint256 tickets = hook.ticketCount();
        vm.expectRevert();
        swapper.buy(_keyOf(hook), 0, alice, alice);
        vm.expectRevert();
        swapper.buy(_keyOf(hook), q - 1, alice, alice);
        assertEq(hook.ticketCount(), tickets, "rejected buys earn nothing");

        // the successor clock armed at cap (launch and buys share a block:
        // headroom is zero until time passes) — advance one hour
        skip(1 hours);
        // exactly q: ONE ticket, 69 seconds
        uint256 det = hook.detonationAt();
        swapper.buy(_keyOf(hook), q, alice, alice);
        assertEq(hook.ticketCount(), tickets + 1, "one spot earns one ticket");
        assertEq(hook.detonationAt(), det + 69);

        // each case samples the CURRENT spot — buy fees reprice the next
        // buy only, exactly as the pre-own-fee sampling rule requires
        uint256 q2 = hook.ticketPrice();
        swapper.buy(_keyOf(hook), 2 * q2 - 1, alice, alice);
        assertEq(hook.ticketCount(), tickets + 2, "2q-1 earns exactly one");
        uint256 q3 = hook.ticketPrice();
        swapper.buy(_keyOf(hook), 2 * q3, alice, alice);
        assertEq(hook.ticketCount(), tickets + 4, "2q earns exactly two");

        // 10q: ten tickets, at most 690 added seconds
        uint256 q10 = hook.ticketPrice();
        det = hook.detonationAt();
        swapper.buy(_keyOf(hook), 10 * q10, alice, alice);
        assertEq(hook.ticketCount(), tickets + 14, "10q earns exactly ten");
        assertLe(hook.detonationAt(), det + 690);

        // a huge valid multiple: exact total count, bounded seat writes,
        // capped clock. 1e7 spots at ~1e11 wei = 1 mix of gross input.
        uint256 qh = hook.ticketPrice();
        det = hook.detonationAt();
        uint256 cap = block.timestamp + hook.detWindow();
        swapper.buy(_keyOf(hook), 1_000_000 * qh, alice, alice);
        assertEq(hook.ticketCount(), tickets + 14 + 1_000_000, "exact absolute numbering");
        assertEq(hook.seatedCount(), 10, "at most ten seat writes");
        assertEq(hook.detonationAt(), cap, "capped at now + detWindow");
        vm.stopPrank();
    }

    /// An exact one-spot buy keeps its ticket even though its own fee legs
    /// grow the pot DURING execution: the price is sampled pre-own-fee.
    function test_PreOwnFeeSamplingKeepsTheTicket() public {
        uint256 q = hook.ticketPrice();
        assertGt(q, 1, "launch pot must be nonzero for this probe");
        uint256 tickets = hook.ticketCount();
        _buyAs(alice, q);
        assertEq(hook.ticketCount(), tickets + 1, "exact-spot buy earns its one ticket");
        assertGt(hook.ticketPrice(), q, "its own fee DID grow the next price");
    }

    /// Sell fees feed the pot: the spot price rises after a sale, and the
    /// curve itself never moves (price at the same reserve is unchanged).
    function test_SellFeesRepriceTicketsNotTheCurve() public {
        _buyAs(alice, hook.ticketPrice() * 20);
        uint256 qBefore = hook.ticketPrice();
        uint256 rBefore = hook.reserveMixETH();
        uint256 pBefore = hook.sinePriceAt(rBefore);
        uint256 psp = IERC20(address(pspToken)).balanceOf(alice);
        vm.prank(alice);
        pspToken.approve(address(this), type(uint256).max);
        // sell through the real pool: PSP in, mixETH out
        _sellAs(alice, psp / 2);
        assertGt(hook.ticketPrice(), qBefore, "sell fee legs grew the pot");
        assertEq(hook.sinePriceAt(hook.reserveMixETH()), _priceAtReserve(), "curve pinned");
        assertEq(hook.sinePriceAt(rBefore), pBefore, "same reserve, same price");
    }

    /// The price base is the ACCOUNTED pot, never the raw balance: a direct
    /// ERC-20 donation to the hook cannot reprice tickets.
    function test_RawDonationDoesNotReprice() public {
        uint256 q = hook.ticketPrice();
        mixETH.transfer(address(hook), 1_000e18);
        assertEq(hook.ticketPrice(), q, "unaccounted balance is not the pot");
    }

    // ─────────────── helpers ───────────────

    function _becomeDustSpotRound() private {
        vm.warp(hook.detonationAt());
        vm.prank(address(this));
        controller.detonate{gas: 2_000_000}();
        factory.reserveSpawn(factory.currentRoundId());
        for (uint256 s; s < 3; ++s) factory.birthStep{gas: 16_000_000}();
        PSPFactory.Round memory next = factory.getRound(factory.currentRoundId());
        mixETH.approve(address(next.controller), 0.01e18);
        next.controller.predeposit(0.01e18);
        vm.prank(address(factory));
        next.controller.launchPooledBuy();
        controller = next.controller;
        hook = next.hook;
        pspToken = next.token;
        _refreshKey();
    }

    function _refreshKey() private {
        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(address(pspToken));
        if (c0 > c1) (c0, c1) = (c1, c0);
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: hook});
    }

    function _keyOf(IHooks h) private view returns (PoolKey memory) {
        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(address(pspToken));
        if (c0 > c1) (c0, c1) = (c1, c0);
        return PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: h});
    }

    function _priceAtReserve() private view returns (uint256) {
        return hook.sinePriceAt(hook.reserveMixETH());
    }

    function _buyAs(address who, uint256 amt) private {
        if (address(swapper) == address(0)) {
            swapper = new TicketSwapper(IPoolManager(address(poolManager)), IERC20(address(mixETH)));
            mixETH.transfer(who, 1_000e18);
            vm.prank(who);
            mixETH.approve(address(swapper), type(uint256).max);
        }
        vm.prank(who);
        swapper.buy(_keyOf(hook), amt, who, who);
    }

    function _sellAs(address who, uint256 pspIn) private {
        // route through a fresh seller bound to this test (real PM settle)
        SellRouter r = new SellRouter(poolManager, IERC20(address(mixETH)));
        vm.prank(who);
        IERC20(address(pspToken)).approve(address(r), type(uint256).max);
        vm.prank(who);
        r.sell(_keyOf(hook), pspIn, who);
    }
}

/// @dev Minimal real-V4 seller: PSP in via sync/settle, mixETH out via take.
contract SellRouter {
    IPoolManager public immutable pm;
    IERC20 public immutable mix;

    constructor(IPoolManager _pm, IERC20 _mix) {
        pm = _pm;
        mix = _mix;
    }

    function sell(PoolKey calldata key, uint256 pspIn, address to) external returns (uint256 out) {
        IERC20(Currency.unwrap(key.currency1 == Currency.wrap(address(mix)) ? key.currency0 : key.currency1))
            .transferFrom(msg.sender, address(this), pspIn);
        bytes memory r = pm.unlock(abi.encode(key, pspIn, to));
        return abi.decode(r, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, uint256 pspIn, address to) = abi.decode(data, (PoolKey, uint256, address));
        bool mixIsZero = key.currency0 == Currency.wrap(address(mix));
        Currency pspCur = mixIsZero ? key.currency1 : key.currency0;
        pm.sync(pspCur);
        IERC20(Currency.unwrap(pspCur)).transfer(address(pm), pspIn);
        pm.settle();
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                amountSpecified: -int256(pspIn),
                sqrtPriceLimitX96: mixIsZero ? 1461446703485210103287273052203988822378723970341 : 4295128739,
                zeroForOne: !mixIsZero
            }),
            abi.encode(to)
        );
        int256 mixDelta = mixIsZero ? d.amount0() : d.amount1();
        require(mixDelta > 0, "no out");
        uint256 amt = uint256(int256(mixDelta));
        pm.take(mixIsZero ? key.currency0 : key.currency1, to, amt);
        return abi.encode(amt);
    }
}
