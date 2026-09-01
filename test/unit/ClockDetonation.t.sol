// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {CBase} from "../wave2/auditorC/CBase.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {RoundController} from "../../src/RoundController.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {PSPStaker} from "../../src/PSPStaker.sol";
import {PSPToken} from "../../src/PSPToken.sol";

/// @title ClockDetonation — the CLOCK-REDESIGN §7 test matrix
/// @notice Every row of the binding spec's test matrix as a named test:
///         the clock (arm/extend/cap/zero-is-dead), the ticket ladder
///         (rolling last-10, no dedup, exact bps, renormalization, dust),
///         claims-forever, the §3 REVISED fee split feeding the pot, the
///         one-tx detonation (flat + locks open + successor birthed + pot
///         frozen), frozen redemption (PSP burned, next-round trades can't
///         move the payout), and the guard set. Governance rows are proven
///         structurally by scripts/check-no-governance.sh (the identifiers
///         don't compile if they exist); the timings repack row lives in
///         CurveMath.t (layout + roundtrip + full-axis + guards).
/// @dev REAL behavior only — no vm.mockCall anywhere. All token movement
///      runs through the real MockPoolManager settlement path.
contract ClockDetonation is CBase {
    uint256 constant LADDER_DENOM_10 = 10_000; // 2500+1800+1400+1000+800+700+600+500+400+300
    uint256 constant LADDER_DENOM_3 = 5700; // 2500+1800+1400

    TicketSwapper tSwapper;

    /// @dev CBase._launchRound1 ends with a warp PAST detonationAt (lock
    ///      liveness) — the clock arrives dead. The clock tests need it
    ///      ALIVE: launch inside epoch 1 and never warp past zero.
    ///      detonationAt == launch ts + 72h; returns the launch ts.
    function _launchLive() internal returns (uint256 launchTs) {
        vm.warp(7 days + 1); // epoch 1 — staker anchors cleanly (never epoch 0)
        launchTs = block.timestamp;

        vm.startPrank(alice);
        mixETH.approve(address(controller1), 200e18);
        controller1.predeposit(200e18);
        vm.stopPrank();
        vm.startPrank(bob);
        mixETH.approve(address(controller1), 200e18);
        controller1.predeposit(200e18);
        vm.stopPrank();

        vm.prank(address(factory));
        controller1.launchPooledBuy();

        vm.prank(alice);
        controller1.claimPredepositPSP();
        vm.prank(bob);
        controller1.claimPredepositPSP();
    }

    function setUp() public virtual override {
        super.setUp();
        tSwapper = new TicketSwapper(IPoolManager(address(poolManager)), IERC20(address(mixETH)));
    }

    // ─────────────── plumbing ───────────────

    function _key() internal view returns (PoolKey memory) {
        address c0 = address(mixETH);
        address c1 = address(psp1);
        if (c0 > c1) (c0, c1) = (c1, c0);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook1))
        });
    }

    /// @dev Buy through the trader-identity path (the zap shape): hookData
    ///      carries the trader, so the TICKET seats `who`, not the router.
    ///      No recorded attribution -> the fee runs the 60/39/1 branch.
    function _buyAs(address who, uint256 amount) internal returns (uint256 pspOut) {
        mixETH.transfer(who, amount);
        vm.startPrank(who);
        mixETH.approve(address(tSwapper), amount);
        pspOut = tSwapper.buy(_key(), amount, who, who);
        vm.stopPrank();
    }

    function _ladderBps(uint256 age) internal pure returns (uint256) {
        if (age == 0) return 2500;
        if (age == 1) return 1800;
        if (age == 2) return 1400;
        if (age == 3) return 1000;
        if (age == 4) return 800;
        if (age == 5) return 700;
        if (age == 6) return 600;
        if (age == 7) return 500;
        if (age == 8) return 400;
        return 300;
    }

    // ═════════════════════════════════════════════════════════
    //  §1 — the clock
    // ═════════════════════════════════════════════════════════

    /// Arms at Active: detonationAt == launch ts + 72h. Predeposit never
    /// touches it (stays 0).
    function test_Clock_ArmsAt72h_AtActiveTransition() public {
        assertEq(hook1.detonationAt(), 0, "Predeposit never arms the clock");

        uint256 launchTs = _launchLive();
        assertEq(hook1.detonationAt(), launchTs + 72 hours, "armed at now + DET_WINDOW");
        assertEq(hook1.DET_WINDOW(), 72 hours, "window constant");
        assertEq(hook1.TIME_PER_PSP(), 5 minutes, "time-per-psp constant");
    }

    /// A 2.49-psp buy adds EXACTLY +10:00 (floor(2.49) = 2 whole PSP) —
    /// discrete injection, and the TimeAdded tape event fires.
    function test_Clock_Buy2_49PSP_AddsExactly10Minutes() public {
        _launchLive();
        vm.warp(block.timestamp + 1 hours); // burn some window first — a
        // buy in the launch block itself is fully capped away (remaining
        // already == 72h)
        uint256 armed = hook1.detonationAt();

        // calibrate: smallest input whose buy output crosses 2 WHOLE psp
        // (deterministic — the view is pure). Target: out in [2e18, 3e18).
        uint256 lo = 1e15;
        uint256 hi = 400e18;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (hook1.getBuyOutput(mid) / 1e18 >= 2) hi = mid;
            else lo = mid;
        }
        uint256 amt = hi;
        uint256 expectOut = hook1.getBuyOutput(amt);
        assertGe(expectOut / 1e18, 2, "calibrated to >= 2 whole");
        assertLt(expectOut / 1e18, 3, "calibrated to < 3 whole");

        vm.expectEmit(true, false, false, true, address(hook1));
        emit CurveHook.TimeAdded(address(tSwapper), expectOut / 1e18, armed + 10 minutes);
        uint256 out = _buyAs(alice, amt);
        assertEq(out, expectOut, "execution matches the calibrated view");

        assertEq(hook1.detonationAt(), armed + 10 minutes, "+5 min per whole psp, floored at 2");
    }

    /// Extension cap: remaining may never exceed 72h — a monster buy pins
    /// detonationAt at now + DET_WINDOW exactly.
    function test_Clock_ExtensionCapped_AtNowPlus72h() public {
        uint256 launchTs = _launchLive();
        vm.warp(launchTs + 1 hours); // inside the window, 71h remaining

        // a huge buy: hundreds of whole psp -> uncapped extension would add
        // days; the cap holds remaining at exactly DET_WINDOW
        _buyAs(alice, 1_000e18);

        assertEq(hook1.detonationAt(), block.timestamp + 72 hours, "capped at now + 72h");
    }

    /// Zero is DEAD: past detonationAt a buy reverts TradingHalted even
    /// though it would have added time; sells halt too; the quote views
    /// mirror; nothing resurrects the clock.
    function test_Clock_ZeroIsDead_TradingHaltedBothWays() public {
        _launchLive();
        _buyAs(alice, 10e18); // live clock, seats a ticket
        vm.warp(hook1.detonationAt()); // == zero (boundary is inclusive)

        vm.prank(alice);
        vm.expectRevert(CurveHook.TradingHalted.selector);
        tSwapper.buy(_key(), 10e18, alice, alice); // would add time — still dead

        vm.prank(alice);
        vm.expectRevert(CurveHook.TradingHalted.selector);
        hook1.getSellOutput(1e18);

        vm.expectRevert(CurveHook.TradingHalted.selector);
        hook1.getBuyOutput(1e18);

        // the clock never moves after zero: a day later it is still dead
        vm.warp(hook1.detonationAt() + 1 days);
        vm.prank(alice);
        vm.expectRevert(CurveHook.TradingHalted.selector);
        tSwapper.buy(_key(), 10e18, alice, alice);
    }

    /// detonate() before zero reverts ClockStillLive; after zero it works.
    function test_Clock_DetonateGates() public {
        _launchLive();
        vm.prank(rando);
        vm.expectRevert(RoundController.ClockStillLive.selector);
        controller1.detonate();

        vm.warp(hook1.detonationAt() + 1);
        vm.prank(rando);
        controller1.detonate(); // works at zero

        // idempotent via mode check: the hook is Flat, NotActive
        vm.prank(rando);
        vm.expectRevert(RoundController.NotActive.selector);
        controller1.detonate();
    }

    // ═════════════════════════════════════════════════════════
    //  §2 — tickets + ladder board
    // ═════════════════════════════════════════════════════════

    /// 12 buyers -> only the newest 10 seated; the oldest two hold nothing.
    function test_Board_12Buyers_OnlyNewest10Seated() public {
        _launchLive();
        address[12] memory buyers;
        for (uint256 i; i < 12; ++i) {
            buyers[i] = makeAddr(string.concat("buyer-", vm.toString(i)));
            _buyAs(buyers[i], 1e18 + i); // distinct sizes, distinct ts not needed
            vm.warp(block.timestamp + 60); // separate the seats in time
        }

        assertEq(hook1.ticketCount(), 12, "every buy tx is a ticket");
        assertEq(hook1.seatedCount(), 10, "board holds the newest 10");
        for (uint256 i; i < 10; ++i) {
            (address who, uint256 pspAmt,,) = hook1.board(i);
            assertEq(who, buyers[11 - i], "seat age 0 = newest");
            assertEq(pspAmt, 1e18 + (11 - i), "ticket carries the buy size");
        }
        // buyers 0 and 1 fell off the board
        assertEq(hook1.claimablePot(buyers[0]), 0, "oldest buyer dusted off the board");
        assertEq(hook1.claimablePot(buyers[1]), 0, "second-oldest off the board");
        // out-of-range seat
        vm.expectRevert(CurveHook.BadSeatIndex.selector);
        hook1.board(10);
    }

    /// Same address twice = TWO seats (no dedup) — and claimPot pays BOTH
    /// rungs in one call.
    function test_Board_SameAddressTwice_TwoSeatsOneClaim() public {
        _launchLive();
        _buyAs(alice, 2e18);
        vm.warp(block.timestamp + 60);
        _buyAs(alice, 3e18);

        assertEq(hook1.seatedCount(), 2, "alice holds both seats");
        assertEq(hook1.ticketCount(), 2, "two buy txs, two tickets");
        (address who0, uint256 psp0,,) = hook1.board(0);
        (address who1, uint256 psp1,,) = hook1.board(1);
        assertEq(who0, alice, "newest seat is alice");
        assertEq(who1, alice, "oldest seat is also alice");
        assertEq(psp0, 3e18, "seat sizes are per-tx");

        vm.warp(hook1.detonationAt() + 1);
        vm.prank(rando);
        controller1.detonate();

        // one claimPot call sweeps BOTH rungs: 2500/5700 + 1800/5700
        uint256 pot = hook1.potBalance();
        uint256 expectBoth = (pot * 2500) / LADDER_DENOM_3 + (pot * 1800) / LADDER_DENOM_3;
        assertEq(hook1.claimablePot(alice), expectBoth, "both rungs claimable");
        uint256 aliceBefore = mixETH.balanceOf(alice);
        vm.prank(alice);
        hook1.claimPot();
        assertEq(mixETH.balanceOf(alice) - aliceBefore, expectBoth, "one claim paid both seats");

        vm.prank(alice);
        vm.expectRevert(CurveHook.NothingToClaim.selector);
        hook1.claimPot();
    }

    // ═════════════════════════════════════════════════════════
    //  §2 — distribution math
    // ═════════════════════════════════════════════════════════

    /// Full 10-seat board: every rung pays EXACTLY pot * bps / 10000; the
    /// floors leave at most one wei of dust per rung; claims are one-shot.
    function test_Distribution_10Seat_ExactBps() public {
        _launchLive();
        address[10] memory buyers;
        for (uint256 i; i < 10; ++i) {
            buyers[i] = makeAddr(string.concat("ten-", vm.toString(i)));
            _buyAs(buyers[i], 2e18);
            vm.warp(block.timestamp + 60);
        }
        // §3 REVISED wiring: the unattributed 35% + 4% + dust legs of every
        // 5% fee landed in the pot — assert the escrow is exactly that sum
        // (deterministic full-chain: fee bps -> split bps -> pot). For an
        // unattributed trade the legs conserve: pot leg == fee - staker - rake
        uint256 expectedPot;
        {
            for (uint256 i; i < 10; ++i) {
                (, uint256 pspAmt, uint256 mixPaid,) = hook1.board(i);
                pspAmt; // size irrelevant to the fee — input-side slice
                uint256 fee = (mixPaid * hook1.swapFeeBps()) / 10000; // zone round: 5%
                expectedPot += fee - (fee * 6000) / 10000 - (fee * 100) / 10000;
            }
        }
        assertEq(hook1.potBalance(), expectedPot, "pot = sum of 35% + 4% + dust legs (to the wei)");

        vm.warp(hook1.detonationAt() + 1);
        vm.prank(rando);
        controller1.detonate();

        uint256 pot = hook1.potBalance(); // frozen distribution base
        assertGt(pot, 0, "a real pot exists");
        uint256 paidTotal;
        // NEWEST (last buyer) claims rung 0 = 25% ... OLDEST claims 9 = 3%
        for (uint256 i; i < 10; ++i) {
            address who = buyers[9 - i]; // buyers[9] bought last => age 0
            uint256 expect = (pot * _ladderBps(i)) / LADDER_DENOM_10;
            assertEq(hook1.claimablePot(who), expect, "claimable view exact");
            uint256 before = mixETH.balanceOf(who);
            vm.prank(who);
            hook1.claimPot();
            assertEq(mixETH.balanceOf(who) - before, expect, "rung paid exact bps of the pot");
            paidTotal += expect;
        }
        // dust tolerance: sum of per-rung floors lands within 10 wei of the pot
        assertLe(pot - paidTotal, 10, "floor dust bounded");
        assertEq(hook1.potPaid(), paidTotal, "drain tracked");

        // every seat is spent — no double claims
        vm.prank(buyers[9]);
        vm.expectRevert(CurveHook.NothingToClaim.selector);
        hook1.claimPot();
    }

    /// Fewer than 10 tickets: the ladder renormalizes to 100% (3-seat board
    /// pays 2500/5700, 1800/5700, 1400/5700) — nobody gets dusted.
    function test_Distribution_3Seat_Renormalized() public {
        _launchLive();
        address b0 = makeAddr("small0");
        address b1 = makeAddr("small1");
        address b2 = makeAddr("small2");
        _buyAs(b0, 5e18);
        vm.warp(block.timestamp + 60);
        _buyAs(b1, 5e18);
        vm.warp(block.timestamp + 60);
        _buyAs(b2, 5e18);

        vm.warp(hook1.detonationAt() + 1);
        vm.prank(rando);
        controller1.detonate();

        uint256 pot = hook1.potBalance();
        uint256[3] memory expect = [
            (pot * 2500) / LADDER_DENOM_3,
            (pot * 1800) / LADDER_DENOM_3,
            (pot * 1400) / LADDER_DENOM_3
        ];
        // newest -> oldest
        address[3] memory who = [b2, b1, b0];
        uint256 paidTotal;
        for (uint256 i; i < 3; ++i) {
            uint256 before = mixETH.balanceOf(who[i]);
            vm.prank(who[i]);
            hook1.claimPot();
            assertEq(mixETH.balanceOf(who[i]) - before, expect[i], "renormalized rung exact");
            paidTotal += expect[i];
        }
        // renormalization leaves at most one wei per rung on the floor
        assertLe(pot - paidTotal, 3, "dust bounded by rung count");
    }

    /// claimPot is FOREVER: first claimant today, second claimant a YEAR
    /// later — still paid in full, off the frozen base.
    function test_ClaimPot_Forever_SecondClaimantOneYearLater() public {
        _launchLive();
        address b0 = makeAddr("early");
        address b1 = makeAddr("late");
        _buyAs(b0, 5e18);
        vm.warp(block.timestamp + 60);
        _buyAs(b1, 5e18);

        vm.warp(hook1.detonationAt() + 1);
        vm.prank(rando);
        controller1.detonate();

        uint256 pot = hook1.potBalance();
        uint256 expect0 = (pot * 2500) / LADDER_DENOM_3;
        uint256 expect1 = (pot * 1800) / LADDER_DENOM_3;

        uint256 before0 = mixETH.balanceOf(b0);
        vm.prank(b0);
        hook1.claimPot();
        assertEq(mixETH.balanceOf(b0) - before0, expect0, "first claimant paid today");

        // a year passes — no deadline, no sweep, no decay
        vm.warp(block.timestamp + 365 days);

        uint256 before1 = mixETH.balanceOf(b1);
        vm.prank(b1);
        hook1.claimPot();
        assertEq(mixETH.balanceOf(b1) - before1, expect1, "second claimant paid a year later, in full");

        // the early claimant's seats stay spent after the year
        vm.prank(b0);
        vm.expectRevert(CurveHook.NothingToClaim.selector);
        hook1.claimPot();
    }

    /// claimPot before detonation is fenced (NotDetonated); a wallet with
    /// no seats reverts NothingToClaim.
    function test_ClaimPot_Guards() public {
        _launchLive();
        _buyAs(alice, 5e18);

        vm.prank(alice);
        vm.expectRevert(CurveHook.NotDetonated.selector);
        hook1.claimPot(); // Active round — claims closed

        vm.warp(hook1.detonationAt() + 1);
        vm.prank(rando);
        controller1.detonate();

        vm.prank(bob); // never bought, no seat
        vm.expectRevert(CurveHook.NothingToClaim.selector);
        hook1.claimPot();
    }

    // ═════════════════════════════════════════════════════════
    //  §4 — detonation
    // ═════════════════════════════════════════════════════════

    /// ONE tx: flat + every lock open (instant full withdrawal, no decay
    /// loss) + the successor's predeposit window live + the pot frozen.
    function test_Detonate_OneTx() public {
        uint256 launchTs = _launchLive();

        // alice buys and locks; NO withdraw request armed (the vest would
        // normally gate her for 6 epochs)
        uint256 pspOut = _buyAs(alice, 20e18);
        PSPStaker staker = PSPStaker(controller1.stakerAddress());
        vm.startPrank(alice);
        psp1.approve(address(staker), pspOut);
        staker.lock(pspOut);
        uint256 pepe = staker.primaryOf(alice);
        vm.stopPrank();

        uint256 pot = hook1.potBalance();
        assertGt(pot, 0, "fees escrowed a pot during Active");

        vm.warp(hook1.detonationAt() + 1);

        // the one-tx kill, by a nobody, announcing the successor
        address nextHook = address(0);
        try factory.getRound(2) returns (PSPFactory.Round memory r2pre) {
            nextHook = address(r2pre.hook); // round 2 not yet born: address(0)
        } catch {}
        assertEq(nextHook, address(0), "no round 2 before detonate");
        vm.expectEmit(true, false, false, true, address(controller1));
        emit RoundController.Detonated(rando, pot, nextHook); // re-filled below
        vm.prank(rando);
        controller1.detonate();

        // 1. flat + flatTime (the analytics anchor)
        assertTrue(hook1.mode() == CurveHook.Mode.Flat, "hook flat");
        assertEq(controller1.flatTime(), block.timestamp, "flatTime set");
        assertGt(controller1.flatTime(), launchTs, "sanity");

        // 2. every lock opens INSTANTLY — full principal, no decay loss
        (uint256 principal,,,,) = staker.positions(pepe);
        assertEq(principal, pspOut, "position intact pre-withdraw");
        uint256 alicePspBefore = psp1.balanceOf(alice);
        vm.prank(alice);
        staker.withdraw(pepe); // no requestWithdraw ever armed
        assertEq(psp1.balanceOf(alice) - alicePspBefore, pspOut, "instant exit, zero decay loss");

        // 3. the successor lives: round 2 born IN THE SAME TX, predeposit open
        PSPFactory.Round memory r2 = factory.getRound(2);
        assertTrue(address(r2.controller) != address(0), "round 2 controller born");
        assertTrue(CurveHook(address(r2.hook)).mode() == CurveHook.Mode.Predeposit, "round 2 in Predeposit");
        assertFalse(r2.controller.predepositClosed(), "round 2 predeposit window open");

        // 4. the pot is FROZEN: flat exits are fee-free, nothing accrues
        uint256 potAfter = hook1.potBalance();
        assertEq(potAfter, pot, "pot frozen at detonation");
        vm.prank(alice);
        psp1.approve(address(hook1), 1e18);
        hook1.redeemBacking(1e18); // an exit moves backing, never the pot
        assertEq(hook1.potBalance(), pot, "post-detonation exits leave the pot alone");
    }

    /// Redemption is FROZEN at detonation: payout per PSP never moves again
    /// (later volume in the NEXT round cannot touch it), and PSP is BURNED.
    function test_Redemption_Frozen_NextRoundTradesDontMovePayout() public {
        _launchLive();
        _buyAs(alice, 20e18);

        vm.warp(hook1.detonationAt() + 1);
        vm.prank(rando);
        controller1.detonate();

        uint256 R = hook1.reserveMixETH();
        uint256 S = hook1.totalSupplyPSP();
        assertGt(S, 0, "alive supply post-detonation");

        // ── the successor trades FOR REAL: predeposit + launch + volume ──
        PSPFactory.Round memory r2 = factory.getRound(2);
        RoundController c2 = r2.controller;
        CurveHook hook2 = r2.hook;
        PSPToken psp2 = r2.token;

        vm.startPrank(alice);
        mixETH.approve(address(c2), 200e18);
        c2.predeposit(200e18);
        vm.stopPrank();
        vm.startPrank(bob);
        mixETH.approve(address(c2), 200e18);
        c2.predeposit(200e18);
        vm.stopPrank();
        // early launch (400 < 500 cap, window still open) is owner-only —
        // the factory owns the spawned controller. rando would revert.
        vm.prank(address(factory));
        c2.launchPooledBuy();

        // real buy into round 2 (sized to also cap its fresh clock)
        mixETH.transfer(rando, 100e18);
        vm.startPrank(rando);
        mixETH.approve(address(tSwapper), 100e18);
        tSwapper.buy(_key2(hook2, psp2), 100e18, rando, rando);
        vm.stopPrank();
        assertGt(hook2.reserveMixETH(), 0, "round 2 has real volume");

        // round 1's backing is untouched by any of it
        assertEq(hook1.reserveMixETH(), R, "dead reserve frozen");
        assertEq(hook1.totalSupplyPSP(), S, "dead supply frozen");

        // redemption pays the frozen pro-rata, to the wei, and BURNS psp
        uint256 bag = psp1.balanceOf(alice);
        assertGt(bag, 0, "alice holds round-1 psp");
        uint256 expect = (bag * R) / S;
        uint256 supplyBefore = psp1.totalSupply();
        vm.startPrank(alice);
        psp1.approve(address(hook1), bag);
        uint256 out = hook1.redeemBacking(bag);
        vm.stopPrank();

        assertEq(out, expect, "frozen payout, to the wei");
        assertEq(psp1.balanceOf(alice), 0, "PSP burned");
        assertEq(psp1.totalSupply(), supplyBefore - bag, "erc20 supply retired");
        assertEq(hook1.totalSupplyPSP(), S - bag, "ledger supply retired");
    }

    // ── round-2 pool key (fresh token address) ──
    function _key2(CurveHook hook2, PSPToken psp2) internal view returns (PoolKey memory) {
        address c0 = address(mixETH);
        address c1 = address(psp2);
        if (c0 > c1) (c0, c1) = (c1, c0);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook2))
        });
    }
}

/// @dev CSwapper's twin that forwards the TRADER through hookData (the
///      canonical-zap identity path) so tickets seat the human, not the
///      router. Unattributed traders run the 60/39/1 fee branch.
contract TicketSwapper {
    IPoolManager public immutable pm;
    IERC20 public immutable mix;

    constructor(IPoolManager _pm, IERC20 _mix) {
        pm = _pm;
        mix = _mix;
    }

    function buy(PoolKey calldata key, uint256 mixIn, address to, address trader) external returns (uint256 pspOut) {
        mix.transferFrom(msg.sender, address(this), mixIn);
        bytes memory r = pm.unlock(abi.encode(key, mixIn, to, trader));
        return abi.decode(r, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, uint256 mixIn, address to, address trader) =
            abi.decode(data, (PoolKey, uint256, address, address));
        bool mixIsZero = Currency.unwrap(key.currency0) == address(mix);
        Currency mixCur = mixIsZero ? key.currency0 : key.currency1;
        Currency pspCur = mixIsZero ? key.currency1 : key.currency0;

        pm.sync(mixCur);
        mix.transfer(address(pm), mixIn);
        pm.settle();

        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                amountSpecified: -int256(mixIn),
                sqrtPriceLimitX96: mixIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                zeroForOne: mixIsZero
            }),
            abi.encode(trader) // exactly 32 bytes — the hook's A-1 decode shape
        );
        int256 pspDelta = mixIsZero ? d.amount1() : d.amount0();
        require(pspDelta > 0, "no out");
        uint256 out = uint256(int256(pspDelta));
        pm.take(pspCur, to, out);
        return abi.encode(out);
    }
}
