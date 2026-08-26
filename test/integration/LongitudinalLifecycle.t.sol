// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {PSPStaker} from "../../src/PSPStaker.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../src/PSPZapOut.sol";
import {PSPReferralRegistry} from "../../src/PSPReferralRegistry.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {StakerDeployer} from "../../src/StakerDeployer.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {IMixETH} from "../../src/interfaces/IMixETH.sol";

import {MainnetConfig} from "./MainnetConfig.sol";
import {V4SwapRouter} from "./V4SwapRouter.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";

/// @title LongitudinalLifecycleTest (fork)
/// @notice Deep multi-user longitudinal lifecycle: two full rounds across
///         ~4 months of simulated time — genesis predeposit → launch → chosen-pepe
///         hatching → a 10-epoch trading era with referral flow and rolling fee
///         claims → lock expiry / relock / top-up → carpet-bomb governance →
///         flat exit window → finalize + rebirth with carried reserve → round-2
///         genesis. Every phase asserts two global invariants:
///           I1 (mixETH conservation): minted supply == sum of balances across
///              every contract/user the system ever created — no value leak.
///           I2 (PSP conservation): user wallets + staker custody == totalSupply.
///         Rules honored: no vm.mockCall/expectCall (real contracts only),
///         skip() for all time travel (fork-genesis warp quirk), cached staker
///         view before pranked calls, per-leg truncation tolerance on exact-sum
///         fee assertions (N * totalLocked / PRECISION).
contract LongitudinalLifecycleTest is Test {
    using StateLibrary for IPoolManager;

    // ─────────────── System ───────────────
    IPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;
    PSPZapIn zapIn;
    PSPZapOut zapOut;
    V4SwapRouter router;

    // Round 1
    PSPToken psp;
    RoundController controller;
    PSPStaker stakerV; // cached: single vm.prank must not be eaten by the staker() view
    CurveHook hook;
    PSPReferralRegistry registry;
    PoolKey poolKey;

    // Round 2 (populated after rebirth)
    PSPToken psp2;
    RoundController controller2;
    PSPStaker staker2;

    // ─────────────── Cast ───────────────
    address alice = makeAddr("alice"); // genesis 200 + referrer
    address bob = makeAddr("bob"); // genesis 100, relocker
    address carol = makeAddr("carol"); // genesis 50, partial seller
    address dave = makeAddr("dave"); // genesis 50, proposer, top-up
    address eve = makeAddr("eve"); // genesis 25
    address frank = makeAddr("frank"); // pure trader, never locks
    address gina = makeAddr("gina"); // chosen-pepe hatcher, finalizer
    address hank = makeAddr("hank"); // chosen-pepe hatcher via referral, no-voter
    address zed = makeAddr("zed"); // late locker, early-unlock revert case
    address ivy = makeAddr("ivy"); // round-2 genesis
    address jake = makeAddr("jake"); // round-2 genesis
    address kyle = makeAddr("kyle"); // round-2 pepe hatcher (no stake)

    address[11] users;

    mapping(address => uint256) feesClaimed; // cumulative mixETH fees paid out
    uint256 constant MINTED = 100_000e18; // mixETH minted into the mock

    // ─────────────── Setup ───────────────

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        poolManager = IPoolManager(MainnetConfig.POOL_MANAGER);
        mixETH = new MockMixETH();
        mixETH.depositETH{value: MINTED}();

        factory = new PSPFactory(
            poolManager, IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer(), new StakerDeployer(), 0
        );
        zapIn = new PSPZapIn(IMixETH(address(mixETH)), poolManager);
        zapOut = new PSPZapOut(IMixETH(address(mixETH)), poolManager);
        router = new V4SwapRouter(poolManager);

        users = [alice, bob, carol, dave, eve, frank, gina, hank, zed, ivy, jake];
        _deal(alice, 1_000e18);
        _deal(bob, 1_000e18);
        _deal(carol, 1_000e18);
        _deal(dave, 1_000e18);
        _deal(eve, 1_000e18);
        _deal(frank, 500e18);
        _deal(gina, 500e18);
        _deal(hank, 500e18);
        _deal(zed, 500e18);
        _deal(ivy, 500e18);
        _deal(jake, 500e18);

        _deployRound();
        _auditMixETH("setUp");
        _auditPSP("setUp");
    }

    // ══════════════════════════════════════════════════════════════
    //  THE LONG HAUL: birth → life → death → rebirth, 8+ users, ~4 months
    // ══════════════════════════════════════════════════════════════

    function test_Longitudinal_FullLifecycleTwoRounds() public {
        // ── Phase A: genesis predeposit (day 0) + permissionless launch (day 7) ──
        _predeposit(alice, 200e18);
        _predeposit(bob, 100e18);
        _predeposit(carol, 50e18);
        _predeposit(dave, 50e18);
        _predeposit(eve, 25e18);

        (,,, bool closed,, bool windowOver, bool launchable) = controller.predepositState();
        assertFalse(closed, "window open");
        assertFalse(windowOver, "day 0: window not over");
        assertFalse(launchable, "day 0: not launchable");

        skip(7 days + 1);
        vm.prank(frank); // permissionless: non-depositor launches on window-over
        controller.launchPooledBuy();

        uint256 totalInitial = controller.totalInitialPSP();
        assertGt(totalInitial, 0, "genesis PSP minted");

        uint256 aAmt = _claim(alice);
        uint256 bAmt = _claim(bob);
        uint256 cAmt = _claim(carol);
        uint256 dAmt = _claim(dave);
        uint256 eAmt = _claim(eve);

        // proportional: 200/425, 100/425, 50/425, 50/425, 25/425
        assertApproxEqRel(aAmt, totalInitial * 200 / 425, 0.001e18, "alice ~47%");
        assertApproxEqRel(bAmt, totalInitial * 100 / 425, 0.001e18, "bob ~23.5%");
        assertApproxEqRel(cAmt, totalInitial * 50 / 425, 0.001e18, "carol ~11.8%");
        assertApproxEqRel(dAmt, totalInitial * 50 / 425, 0.001e18, "dave ~11.8%");
        assertApproxEqRel(eAmt, totalInitial * 25 / 425, 0.002e18, "eve ~5.9%");

        // genesis shares truncate per-claim: after ALL depositors claim, a few
        // wei can remain locked in the controller's virtual position forever
        // (dust, non-extractable — the L-4 truncation family). Bound it.
        assertApproxEqAbs(
            stakerV.totalLocked(), aAmt + bAmt + cAmt + dAmt + eAmt, 10, "all genesis locked (dust-bound)"
        );
        assertEq(psp.balanceOf(address(stakerV)), stakerV.totalLocked(), "staker custody = locked");
        for (uint256 i; i < 5; i++) {
            assertTrue(stakerV.tokenOf(users[i]) != 0, "position NFT minted");
        }
        _auditMixETH("A: launched");
        _auditPSP("A: launched");

        // ── Phase B: chosen-pepe hatching + referral flow (day 8) ──
        skip(1 days);
        _buy(gina, 20e18); // plain curve buy via router
        uint256 hankOut = _buyViaZap(hank, 20e18, alice); // referral: hank → alice
        assertGt(hankOut, 0, "zap buy out");
        assertEq(registry.traderRefNftOf(hank), stakerV.tokenOf(alice), "hank bound to alice");

        vm.startPrank(gina);
        psp.approve(address(stakerV), psp.balanceOf(gina));
        stakerV.lockWithPepe(psp.balanceOf(gina), 42);
        vm.stopPrank();
        vm.startPrank(hank);
        psp.approve(address(stakerV), hankOut);
        stakerV.lockWithPepe(hankOut, 777);
        vm.stopPrank();

        assertEq(stakerV.ownerOf(42), gina, "gina owns pepe 42");
        assertEq(stakerV.ownerOf(777), hank, "hank owns pepe 777");

        // second pepe reverts; taken id reverts
        vm.prank(gina);
        vm.expectRevert(PSPStaker.PepeAlreadyOwned.selector);
        stakerV.lockWithPepe(0, 4242);
        // gina already owns her pepe — a SECOND chosen id hits the ownership
        // gate BEFORE the taken-id gate (check order in lockWithPepe)
        vm.prank(gina);
        vm.expectRevert(PSPStaker.PepeAlreadyOwned.selector);
        stakerV.lockWithPepe(0, 555);
        // a FRESH face asking for hank's taken id 777 hits the taken-id gate
        address mallory = makeAddr("mallory");
        vm.prank(mallory);
        vm.expectRevert(PSPStaker.BadPepeId.selector);
        stakerV.lockWithPepe(0, 777);

        // hatch with zero stake: pure art position
        vm.prank(frank);
        stakerV.lockWithPepe(0, 31337);
        assertEq(stakerV.ownerOf(31337), frank, "frank hatched a pepe with 0 stake");

        _auditMixETH("B: hatched");
        _auditPSP("B: hatched");

        // ── Phase C: trading era — 10 epochs × 9 days, rolling fee claims ──
        // zed joins at epoch 6 (day ~61) with a chosen pepe, locking well past
        // the era's end — the early-unlock revert case.
        for (uint256 epoch = 1; epoch <= 10; epoch++) {
            skip(9 days);

            _buy(frank, 5e18);
            _buy(gina, 5e18);
            _buy(hank, 6e18);
            _buy(eve, 3e18);
            // frank is the designated LIQUID trader (sell pressure), but the
            // carpet quorum denominator is max(locked, SUPPLY) — a big liquid
            // bag makes 69% unreachable by lockers alone. He cycles: keeps
            // only the last buy's dust unsold (~1% of supply).
            {
                uint256 frankBag = psp.balanceOf(frank);
                if (frankBag / 10 > 1e15) _sell(frank, frankBag * 9 / 10);
            }
            if (epoch == 6) {
                uint256 zedOut = _buy(zed, 15e18);
                vm.startPrank(zed);
                psp.approve(address(stakerV), zedOut);
                stakerV.lockWithPepe(zedOut, 424242);
                vm.stopPrank();
            }

            // every locker harvests; assert exact payout == pending preview
            for (uint256 i; i < users.length; i++) {
                _claimFeesChecked(users[i]);
            }

            _auditMixETH(string.concat("C epoch ", vm.toString(epoch)));
            _auditPSP(string.concat("C epoch ", vm.toString(epoch)));
        }

        // day ≈ 8 + 90 = 98: genesis locks (claimed day 7, unlock day 97) are ripe
        // ── Phase D: lock lifecycle ──
        skip(1 days); // day ~99

        // bob relocks inside his window tail → fresh 90d extension
        (uint256 bobAmt,, uint256 bobLock, uint256 bobUnlock) = stakerV.positions(bob);
        assertGt(block.timestamp, bobUnlock - controller.RELOCK_WINDOW(), "bob in relock window");
        vm.prank(bob);
        stakerV.relock();
        (,, uint256 bobLock2, uint256 bobUnlock2) = stakerV.positions(bob);
        assertEq(bobUnlock2, block.timestamp + controller.EXTEND_DURATION(), "relock extends 90d");
        assertEq(bobLock2, block.timestamp, "relock restamps lockTime");
        assertGt(bobUnlock2, bobUnlock, "extended");

        // dave tops up (buys + locks more)
        uint256 daveBuy = _buy(dave, 10e18);
        _lock(dave, daveBuy);
        assertGt(stakerV.lockedPSPOf(dave), dAmt, "dave topped up");

        // zed (locked epoch 6, day ~61+90=151) cannot unlock yet
        vm.prank(zed);
        vm.expectRevert(PSPStaker.LockNotExpired.selector);
        stakerV.unlock();

        // bob's amount survives relock; carol still locked
        assertEq(stakerV.lockedPSPOf(bob), bobAmt, "relock keeps amount");
        assertTrue(stakerV.lockedPSPOf(carol) > 0, "carol locked");

        _auditMixETH("D: lock lifecycle");
        _auditPSP("D: lock lifecycle");

        // ── Phase E: carpet-bomb governance (day ~100) ──
        skip(1 days); // temporal guard: every lock action is ≥1s before propose
        vm.prank(dave);
        controller.proposeCarpetBomb();

        // vote guard: dave just proposed — a NEW lock after propose is barred
        vm.startPrank(eve);
        psp.approve(address(stakerV), psp.balanceOf(eve));
        stakerV.lock(psp.balanceOf(eve)); // eve tops up post-propose → lockTime = now
        vm.stopPrank();
        vm.prank(eve);
        vm.expectRevert(RoundController.VoteLockedAfterPropose.selector);
        controller.voteCarpetBomb(true);

        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        vm.prank(carol);
        controller.voteCarpetBomb(true);
        vm.prank(dave);
        controller.voteCarpetBomb(true);
        vm.prank(gina);
        controller.voteCarpetBomb(true);
        vm.prank(zed);
        controller.voteCarpetBomb(true);
        vm.prank(hank);
        controller.voteCarpetBomb(false); // the dissenter
        // eve sits this one out (her post-propose top-up)

        skip(controller.VOTE_DURATION() + 1);
        vm.prank(frank); // permissionless execution by a non-locker
        controller.carpetBomb();

        assertTrue(controller.flatTime() != 0, "flattened");
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Flat), "hook flat");

        // flat mode opens every lock immediately — alice never waited out 90d
        uint256 aliceLocked = stakerV.lockedPSPOf(alice);
        assertGt(aliceLocked, 0, "alice locked pre-bomb");
        uint256 alicePSPBefore = psp.balanceOf(alice);
        vm.prank(alice);
        stakerV.unlock();
        assertEq(psp.balanceOf(alice) - alicePSPBefore, aliceLocked, "alice unlocked full");
        assertEq(stakerV.lockedPSPOf(alice), 0, "alice position drained");
        assertEq(stakerV.ownerOf(42), gina, "pepe 42 untouched by alice unlock");

        _auditMixETH("E: bombed");
        _auditPSP("E: bombed");

        // ── Phase F: flat exit window → finalize → rebirth ──
        // flat sells pay average backing: alice (unlocked in Phase E) sells half her bag
        uint256 aliceBag = psp.balanceOf(alice);
        assertGt(aliceBag, 0, "alice holds liquid PSP post-unlock");
        uint256 aliceMixBefore = mixETH.balanceOf(alice);
        _sell(alice, aliceBag / 2);
        uint256 aliceProceeds = mixETH.balanceOf(alice) - aliceMixBefore;
        uint256 avgBacking = (hook.reserveMixETH() * 1e18) / hook.totalSupplyPSP();
        assertApproxEqRel(aliceProceeds, (aliceBag / 2) * avgBacking / 1e18, 0.02e18, "flat sell ~ avg backing");

        skip(controller.FLAT_EXIT_WINDOW() + 1);
        uint256 factoryBefore = mixETH.balanceOf(address(factory));
        // drainAll takes the hook's FULL balance (reserve + fee surplus)
        uint256 carryExpected = mixETH.balanceOf(address(hook));
        vm.prank(gina);
        controller.finalizeCarpet();

        // finalize auto-spawns round 2 and seeds it — the carry never rests
        // at the factory (factory delta == 0, forwarding is atomic)
        assertEq(mixETH.balanceOf(address(factory)) - factoryBefore, 0, "no carry rests at the factory");
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Destroyed), "hook destroyed");
        assertTrue(factory.getRound(1).destroyed, "round 1 marked destroyed");

        // rebirth: round 2 exists, wired, with the carry as its genesis offer
        PSPFactory.Round memory r2 = factory.getRound(2);
        assertFalse(r2.destroyed, "round 2 alive");
        controller2 = r2.controller;
        staker2 = controller2.staker();
        psp2 = r2.token;
        r2HookCached = r2.hook;
        assertGt(carryExpected, 0, "carry seeded round 2");
        assertEq(mixETH.balanceOf(address(controller2)), carryExpected, "carry parked at round-2 controller");
        assertEq(address(controller2.factory()), address(factory), "round 2 wired to factory");

        // round-1 pepes survive their round's death
        assertEq(stakerV.ownerOf(42), gina, "pepe 42 survives round death");
        assertEq(stakerV.ownerOf(777), hank, "pepe 777 survives round death");
        assertEq(stakerV.ownerOf(31337), frank, "frank's pepe survives");
        assertEq(stakerV.ownerOf(424242), zed, "zed's pepe survives");

        _auditMixETH("F: finalized");

        // ── Phase G: round-2 genesis, seeded by round-1's corpse ──
        // the carry IS a predeposit (factory-deposited) and PREDEPOSIT_CAP is
        // 500 mix: this round's carry exceeds the cap, so the public window
        // never opens — the round is instantly launchable by ANYONE. The
        // public-predeposit + carry boot path is covered by RebirthCarryExact.
        assertTrue(controller2.totalPredepositMixETH() >= controller2.PREDEPOSIT_CAP(), "carry saturated the cap");
        vm.prank(frank); // a stranger launches — no window wait needed
        controller2.launchPooledBuy();

        // boot = carried reserve EXACTLY; initial PSP follows the curve exactly
        assertEq(
            controller2.totalInitialPSP(),
            CurveMath.computeBuyOutput(carryExpected, 0, cfgCached),
            "round-2 genesis = curve(carry)"
        );

        // fresh staker: pepe ids restart per round — a fresh face takes id 42
        // on round 2, no conflict with gina's round-1 pepe (kyle holds no stake)
        vm.prank(kyle);
        staker2.lockWithPepe(0, 42);
        assertEq(staker2.ownerOf(42), kyle, "pepe 42 reborn on round 2");
        assertEq(stakerV.ownerOf(42), gina, "round-1 pepe 42 still gina's");

        _auditMixETH("G: round 2 live");

        // ── Phase H: the books, closed ──
        // every mixETH ever minted is still somewhere we know
        _auditMixETH("H: final");
        // round-1 PSP books still balance (burned supply + wallets + custody)
        _auditPSP("H: final round 1");

        console.log("=== LONGITUDINAL SUMMARY ===");
        console.log("carry into round 2:", carryExpected);
        console.log("round-2 initial PSP:", controller2.totalInitialPSP());
        uint256 totalFees;
        for (uint256 i; i < users.length; i++) {
            totalFees += feesClaimed[users[i]];
        }
        console.log("total fees claimed (mixETH):", totalFees);
        console.log("alice fees:", feesClaimed[alice]);
        console.log("bob fees:", feesClaimed[bob]);
        console.log("carol fees:", feesClaimed[carol]);
        console.log("dave fees:", feesClaimed[dave]);
        console.log("eve fees:", feesClaimed[eve]);
        console.log("gina fees:", feesClaimed[gina]);
        console.log("hank fees:", feesClaimed[hank]);
        console.log("zed fees:", feesClaimed[zed]);
    }

    // ══════════════════════════════════════════════════════════════
    //  Fee fairness across staggered joins, 120 distributions
    // ══════════════════════════════════════════════════════════════

    function test_Longitudinal_FeeFairnessStaggeredJoins() public {
        _predeposit(alice, 100e18);
        skip(7 days + 1);
        vm.prank(frank);
        controller.launchPooledBuy();
        _claim(alice); // alice locked from day 7 — her day-7 top-up buy (below)
        uint256 giftBag = _buy(alice, 20e18); // fee event BEFORE zed exists
        _lock(alice, 0); // no-op amount (alice already locked via claim)

        skip(23 days); // zed joins a month in — bags will DIFFER (price rose);
        // zed's bag arrives FEE-FREE (wallet transfer) so no fee event lands
        // between the two locks: from here both bags see the same stream
        vm.prank(alice);
        psp.transfer(zed, giftBag); // fairness is per-PSP, not per-bag
        _lock(zed, giftBag);

        // 120 fee-generating buys by the non-locking trader — BOTH bags are
        // live for the entire stream; per-PSP accrual OVER THE STREAM must
        // converge (pre-stream balances snapshotted so alice's legitimately
        // larger lifetime total — she was live during her day-7 buy — cancels)
        uint256 alicePre = stakerV.pendingFeesOf(alice);
        uint256 zedPre = stakerV.pendingFeesOf(zed);
        uint256 aliceAmt = stakerV.lockedPSPOf(alice);
        uint256 zedAmt = stakerV.lockedPSPOf(zed);
        // 120 small fee events; both bags live throughout (staggered-join
        // fairness = equal per-PSP accrual over a SHARED window)
        for (uint256 i; i < 120; i++) {
            _buy(frank, 1e18);
        }
        uint256 aliceEarned = _claimFeesChecked(alice) - alicePre;
        uint256 zedEarned = _claimFeesChecked(zed) - zedPre;
        assertGt(aliceEarned, 0, "alice accrued");
        assertGt(zedEarned, 0, "zed accrued");

        // per-PSP STREAM-window accrual converges within accumulator dust:
        // N wei per distribution per user (Synthetix bound), unequal bags
        uint256 alicePerPSP = aliceEarned * 1e18 / aliceAmt;
        uint256 zedPerPSP = zedEarned * 1e18 / zedAmt;
        assertApproxEqAbs(alicePerPSP, zedPerPSP, 200, "per-PSP fees converge (dust bound)");

        _auditMixETH("fairness final");
    }

    // ══════════════════════════════════════════════════════════════
    //  100+ alternating buy/sell cycles across three traders
    // ══════════════════════════════════════════════════════════════

    function test_Longitudinal_BuySellChains100() public {
        _predeposit(alice, 100e18);
        skip(7 days + 1);
        vm.prank(frank);
        controller.launchPooledBuy();
        _claim(alice);

        address[3] memory traders = [frank, gina, hank];
        uint256 frankStart = mixETH.balanceOf(frank);

        for (uint256 i; i < 102; i++) {
            address t = traders[i % 3];
            _buy(t, 3e18);
            uint256 bag = psp.balanceOf(t);
            if (bag > 1e15) _sell(t, bag / 3); // partial sell-back every cycle
            if (i % 12 == 11) _auditMixETH("chain checkpoint");
        }

        // round-tripping is not free money: frank spent 306 mixETH buying;
        // whatever he recovered via sells is strictly less than that.
        uint256 frankRecovered = mixETH.balanceOf(frank) - (frankStart - 102 * 3e18);
        assertLt(frankRecovered, 102 * 3e18, "round-trip is not free money");
        assertGt(hook.reserveMixETH(), 0, "reserve alive after 100 cycles");
        assertGt(hook.totalSupplyPSP(), 0, "supply alive");
        _auditPSP("chains final");
        _auditMixETH("chains final");
    }

    // ══════════════════════════════════════════════════════════════
    //  Rebirth carry: exact accounting into round 2
    // ══════════════════════════════════════════════════════════════

    function test_Longitudinal_RebirthCarryExact() public {
        _predeposit(alice, 100e18);
        skip(7 days + 1);
        vm.prank(frank);
        controller.launchPooledBuy();
        _claim(alice);

        // generate fees + trading depth, then bomb through
        _buy(bob, 10e18);
        _buy(carol, 10e18);
        skip(1);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        skip(controller.VOTE_DURATION() + 1);
        controller.carpetBomb();
        skip(controller.FLAT_EXIT_WINDOW() + 1);

        // drainAll takes the hook's FULL balance (reserve + unclaimed fee
        // surplus) — measure both sides of the transfer exactly
        uint256 preCarry = mixETH.balanceOf(address(hook));
        assertGt(preCarry, hook.reserveMixETH(), "fee surplus over reserve");
        vm.prank(frank);
        controller.finalizeCarpet();

        // the factory never parks the carry — spawnNextRound forwards it to the
        // newborn controller immediately as its carryBonus predeposit offer
        PSPFactory.Round memory r2 = factory.getRound(2);
        controller2 = r2.controller;
        staker2 = controller2.staker(); // audit tracks round-2 custody too
        r2HookCached = CurveHook(r2.hook);
        assertEq(
            mixETH.balanceOf(address(controller2)), preCarry, "carry parked at round-2 controller"
        );

        // round-2 predeposit pool starts empty; the carry rides in the boot
        _predepositTo(controller2, bob, 10e18);
        vm.prank(address(factory));
        controller2.launchPooledBuy();
        assertEq(
            controller2.totalInitialPSP(),
            CurveMath.computeBuyOutput(10e18 + preCarry, 0, cfgCached),
            "boot = fresh + carry, exact"
        );
        _auditMixETH("carry exact final");
    }

    // ══════════════════════════════════════════════════════════════
    //  GLOBAL INVARIANTS
    // ══════════════════════════════════════════════════════════════

    /// @dev I1: every mixETH ever minted is still inside the known system.
    ///      Covers users, curve hook, factory, controllers, stakers, zaps,
    ///      router, poolManager — a leak anywhere else shows as a deficit.
    function _auditMixETH(string memory phase) internal view {
        uint256 sum = mixETH.balanceOf(address(this)); // unminted remainder held by the test
        for (uint256 i; i < users.length; i++) {
            sum += mixETH.balanceOf(users[i]);
        }
        sum += mixETH.balanceOf(address(hook));
        sum += mixETH.balanceOf(address(factory));
        sum += mixETH.balanceOf(address(controller));
        sum += mixETH.balanceOf(address(stakerV));
        sum += mixETH.balanceOf(address(zapIn));
        sum += mixETH.balanceOf(address(zapOut));
        sum += mixETH.balanceOf(address(router));
        sum += mixETH.balanceOf(address(poolManager));
        if (address(controller2) != address(0)) {
            sum += mixETH.balanceOf(address(controller2));
            sum += mixETH.balanceOf(address(staker2));
            sum += mixETH.balanceOf(address(r2HookCached));
            // the rebirth carry parks at round-2's CONTROLLER (seedCarry)
            // until its launch, and round-2's staker can hold fees thereafter
        }
        assertEq(sum, MINTED, string.concat("mixETH conservation: ", phase));
    }

    /// @dev I2: round-1 PSP — user wallets + staker custody == totalSupply.
    function _auditPSP(string memory phase) internal view {
        uint256 sum = psp.balanceOf(address(stakerV));
        for (uint256 i; i < users.length; i++) {
            sum += psp.balanceOf(users[i]);
        }
        assertEq(sum, psp.totalSupply(), string.concat("PSP conservation: ", phase));
    }

    // ══════════════════════════════════════════════════════════════
    //  HELPERS
    // ══════════════════════════════════════════════════════════════

    CurveHook r2HookCached;
    CurveMath.CurveConfig cfgCached; // round-2 spawn inherits round-1 params

    function _deployRound() internal {
        CurveMath.CurveConfig memory cfg = CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);
        cfgCached = cfg;
        PSPFactory.RoundParams memory params =
            PSPFactory.RoundParams({name: "Positive Sum Pepes", symbol: "PSP", curveConfig: cfg});
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory round = factory.getRound(roundId);
        psp = round.token;
        controller = round.controller;
        stakerV = controller.staker();
        hook = round.hook;
        registry = PSPReferralRegistry(factory.referralRegistryOf(roundId));

        Currency currency0 = Currency.wrap(address(mixETH));
        Currency currency1 = Currency.wrap(address(psp));
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

    function _deal(address to, uint256 amount) internal {
        mixETH.transfer(to, amount);
    }

    function _predeposit(address user, uint256 amount) internal {
        _predepositTo(controller, user, amount);
    }

    function _predepositTo(RoundController c, address user, uint256 amount) internal {
        vm.startPrank(user);
        mixETH.approve(address(c), amount);
        c.predeposit(amount);
        vm.stopPrank();
    }

    function _claim(address user) internal returns (uint256) {
        return _claimFrom(controller, user);
    }

    function _claimFrom(RoundController c, address user) internal returns (uint256) {
        vm.prank(user);
        c.claimPredepositPSP();
        return PSPStaker(c.staker()).lockedPSPOf(user);
    }

    function _lock(address user, uint256 amount) internal {
        vm.startPrank(user);
        psp.approve(address(stakerV), amount);
        stakerV.lock(amount);
        vm.stopPrank();
    }

    function _buy(address user, uint256 mixAmount) internal returns (uint256) {
        uint256 before = psp.balanceOf(user);
        vm.startPrank(user);
        mixETH.approve(address(router), mixAmount);
        bool z = _isMixETHCurrency0();
        SwapParams memory params = SwapParams({
            amountSpecified: -int256(mixAmount),
            sqrtPriceLimitX96: z ? _minPrice() : _maxPrice(),
            zeroForOne: z
        });
        router.swap(poolKey, params);
        vm.stopPrank();
        return psp.balanceOf(user) - before;
    }

    function _buyViaZap(address user, uint256 mixAmount, address referrer) internal returns (uint256) {
        uint256 before = psp.balanceOf(user);
        uint256 refNft = referrer == address(0) ? 0 : stakerV.tokenOf(referrer);
        vm.startPrank(user);
        mixETH.approve(address(zapIn), mixAmount);
        zapIn.buyWithMix(poolKey, mixAmount, 0, 0, refNft);
        vm.stopPrank();
        return psp.balanceOf(user) - before;
    }

    function _sell(address user, uint256 pspAmount) internal {
        vm.startPrank(user);
        psp.approve(address(router), pspAmount);
        bool z = !_isMixETHCurrency0();
        SwapParams memory params = SwapParams({
            amountSpecified: -int256(pspAmount),
            sqrtPriceLimitX96: z ? _maxPrice() : _minPrice(),
            zeroForOne: z
        });
        router.swap(poolKey, params);
        vm.stopPrank();
    }

    function _claimFeesChecked(address user) internal returns (uint256 paid) {
        uint256 pending = stakerV.pendingFeesOf(user);
        if (pending == 0) return 0;
        uint256 before = mixETH.balanceOf(user);
        vm.prank(user);
        stakerV.claimFees();
        assertEq(mixETH.balanceOf(user) - before, pending, "fee payout == preview");
        feesClaimed[user] += pending;
        return pending;
    }

    function _isMixETHCurrency0() internal view returns (bool) {
        return Currency.wrap(address(mixETH)) < Currency.wrap(address(psp));
    }

    function _minPrice() internal pure returns (uint160) {
        return 4295128740;
    }

    function _maxPrice() internal pure returns (uint160) {
        return 1461446703485210103287273052203988822378723970341;
    }

    receive() external payable {}
}
