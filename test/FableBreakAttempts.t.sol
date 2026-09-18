// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RealV4Base} from "./RealV4Lifecycle.t.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {RoundController} from "../src/RoundController.sol";
import {PSPReferralRegistry} from "../src/PSPReferralRegistry.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @dev Adversarial campaign (2026-09-18). Three families:
///        A  random multi-actor lifecycle, then EVERYONE exits EVERYTHING —
///           no reverts, PSP supply reaches zero, hook holds only dust;
///        B  brick attempts on launch / detonate / rebirth / withdraw / sells;
///        T  theft attempts on claims, seats, referral credits, exits.
///      Short timings so the vest engine is exercised: 1h predeposit, 6h vest
///      (1h epochs), 12h clock.
contract FableBreakAttempts is RealV4Base {
    PSPStaker staker;
    PSPReferralRegistry registry;
    address carol = makeAddr("brk-carol");
    address dave = makeAddr("brk-dave");
    address[4] actors;
    uint256 seedState;

    function testTimings() internal pure override returns (uint256) {
        return CurveMath.packTimingsCapped(1 hours, 6 hours, 12 hours, 0);
    }

    function setUp() public override {
        super.setUp();
        staker = controller.staker();
        registry = PSPReferralRegistry(factory.referralRegistryOf(1));
        actors = [alice, carol, dave, bob];
        for (uint256 i; i < 4; ++i) {
            address a = actors[i];
            if (a != bob) mixETH.transfer(a, 3_000e18);
            vm.startPrank(a);
            mixETH.approve(address(zapIn), type(uint256).max);
            mixETH.approve(address(registry), type(uint256).max);
            pspToken.approve(address(zapOut), type(uint256).max);
            pspToken.approve(address(hook), type(uint256).max);
            pspToken.approve(address(staker), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ───────────────────────── helpers ─────────────────────────

    function _rnd(uint256 mod) internal returns (uint256) {
        seedState = uint256(keccak256(abi.encode(seedState)));
        return mod == 0 ? 0 : seedState % mod;
    }

    function _tradable() internal view returns (bool) {
        return hook.mode() == CurveHook.Mode.Active && block.timestamp < hook.detonationAt();
    }

    function _pepesOf(address a) internal view returns (uint256[] memory ids) {
        uint256 n = staker.balanceOf(a);
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = staker.tokenOfOwnerByIndex(a, i);
    }

    function _buy(address who, uint256 amt) internal returns (bool) {
        if (!_tradable()) return false;
        uint256 tp = hook.ticketPrice();
        if (amt < tp) amt = tp;
        if (mixETH.balanceOf(who) < amt) return false;
        vm.prank(who);
        zapIn.buyWithMix(poolKey, amt, 0, 0);
        return true;
    }

    function _sell(address who, uint256 amt) internal returns (bool) {
        if (!_tradable()) return false;
        if (amt < 1e12 || amt >= hook.totalSupplyPSP()) return false;
        vm.prank(who);
        zapOut.sellToMix(poolKey, amt, 0, 0);
        return true;
    }

    function _assertHookInvariants() internal view {
        uint256 liabilities = hook.reserveMixETH() + (hook.potBalance() - hook.potPaid())
            + (hook.deployerCredit() - hook.deployerCreditPaid()) + staker.pendingFeesMixETH();
        assertGe(mixETH.balanceOf(address(hook)), liabilities, "hook solvent");
        assertEq(hook.totalSupplyPSP(), pspToken.totalSupply(), "supply mirrors token");
        assertGe(mixETH.balanceOf(address(registry)), registry.totalReferralOutstanding(), "registry backed");
    }

    // ───────────────────────── family A ─────────────────────────

    /// forge-config: default.fuzz.runs = 48
    function testFuzz_A_EveryoneCanFullyExitAfterChaos(uint256 seed) public {
        seedState = seed;
        // bob may or may not claim his genesis share before the chaos
        if (_rnd(2) == 0) { vm.prank(bob); controller.claimPredepositPSP(); }

        uint256 steps = 24 + _rnd(24);
        for (uint256 s; s < steps; ++s) {
            address who = actors[_rnd(4)];
            uint256 action = _rnd(11);
            if (action == 0) {
                _buy(who, 1e15 + _rnd(150e18));
            } else if (action == 1) {
                uint256 bal = pspToken.balanceOf(who);
                if (bal > 1e12) _sell(who, 1e12 + _rnd(bal - 1e12));
            } else if (action == 2) {
                uint256 bal = pspToken.balanceOf(who);
                if (bal > 0 && _tradable()) { vm.prank(who); staker.lock(1 + _rnd(bal)); }
            } else if (action == 3) {
                uint256[] memory ids = _pepesOf(who);
                uint256 bal = pspToken.balanceOf(who);
                if (ids.length > 0 && bal > 0 && _tradable()) {
                    uint256 id = ids[_rnd(ids.length)];
                    if (!staker.isWithdrawing(id)) { vm.prank(who); staker.stakeFor(who, id, 1 + _rnd(bal)); }
                }
            } else if (action == 4) {
                uint256[] memory ids = _pepesOf(who);
                if (ids.length > 0) {
                    uint256 id = ids[_rnd(ids.length)];
                    (uint256 amt,,,,) = staker.positions(id);
                    if (amt > 0 && !staker.isWithdrawing(id)) { vm.prank(who); staker.requestWithdraw(id); }
                }
            } else if (action == 5) {
                uint256[] memory ids = _pepesOf(who);
                if (ids.length > 0) {
                    uint256 id = ids[_rnd(ids.length)];
                    if (staker.isWithdrawing(id)) { vm.prank(who); staker.cancelWithdraw(id); }
                }
            } else if (action == 6) {
                uint256[] memory ids = _pepesOf(who);
                if (ids.length > 0) {
                    uint256 id = ids[_rnd(ids.length)];
                    if (staker.isWithdrawing(id) && block.timestamp >= staker.withdrawableAt(id)) {
                        vm.prank(who); staker.withdraw(id);
                    }
                }
            } else if (action == 7) {
                uint256[] memory ids = _pepesOf(who);
                if (ids.length > 0) {
                    uint256 id = ids[_rnd(ids.length)];
                    if (staker.pendingFeesOf(id) > 0) { vm.prank(who); staker.claimFees(id); }
                }
            } else if (action == 8) {
                uint256[] memory ids = _pepesOf(who);
                if (ids.length > 0) {
                    address to = actors[_rnd(4)];
                    if (to != who) { vm.prank(who); staker.transferFrom(who, to, ids[_rnd(ids.length)]); }
                }
            } else if (action == 9) {
                skip(1 minutes + _rnd(80 minutes));
            } else {
                // referral: bind to another actor's first pepe when it qualifies
                address ref = actors[_rnd(4)];
                uint256 nft = staker.primaryOf(ref);
                if (ref != who && nft != 0 && !registry.attributed(who) && registry.canReferNft(nft)) {
                    // a chain that loops back to `who` is refused (WouldCreateCycle) — expected
                    vm.prank(who);
                    try registry.record(nft) {} catch (bytes memory err) {
                        assertEq(bytes4(err), PSPReferralRegistry.WouldCreateCycle.selector, "only cycle refusals");
                    }
                }
            }
            _assertHookInvariants();
        }

        // ── death ──
        if (block.timestamp < hook.detonationAt()) vm.warp(hook.detonationAt());
        controller.detonate();
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Flat), "flat after detonation");

        // ── everyone exits everything ──
        (bool claimed,) = _dep(bob);
        if (!claimed) { vm.prank(bob); controller.claimPredepositPSP(); }
        for (uint256 i; i < 4; ++i) {
            address a = actors[i];
            if (hook.claimablePot(a) > 0) { vm.prank(a); hook.claimPot(); }
            uint256[] memory ids = _pepesOf(a);
            for (uint256 j; j < ids.length; ++j) {
                (uint256 amt,,,,) = staker.positions(ids[j]);
                if (amt > 0) { vm.prank(a); staker.withdraw(ids[j]); }
                if (staker.pendingFeesOf(ids[j]) > 0) { vm.prank(a); staker.claimFees(ids[j]); }
            }
            uint256 psp = pspToken.balanceOf(a);
            if (psp > 0) { vm.prank(a); hook.redeemBacking(psp); }
            if (registry.claimableReferral(a) > 0) { vm.prank(a); registry.claimReferralRewards(); }
        }
        if (hook.deployerCredit() > hook.deployerCreditPaid()) hook.claimDeployerCredit();

        // ── nothing left behind ──
        assertEq(pspToken.totalSupply(), 0, "every PSP redeemed");
        assertEq(hook.reserveMixETH(), 0, "reserve fully paid out");
        assertEq(pspToken.balanceOf(address(staker)), 0, "staker holds no PSP");
        assertEq(registry.totalReferralOutstanding(), 0, "referral escrow drained");
        assertLe(mixETH.balanceOf(address(hook)), 1_000, "hook holds only rounding dust");
        assertLe(hook.potBalance() - hook.potPaid(), 10, "pot dust bounded");
    }

    function _dep(address a) internal view returns (bool claimed, uint256 amt) {
        (amt, claimed) = controller.predeposits(a);
    }

    // ───────────────────────── family B: brick attempts ─────────────────────────

    /// B1: an owner reservation pending at detonation must not stop the
    /// round from dying, and the loop must be recoverable afterwards.
    function test_B1_DetonateWithPendingReservationThenRecover() public {
        factory.reserveGenesis(PSPFactory.RoundParams({
            name: "X", symbol: "X",
            curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
        }));
        vm.warp(hook.detonationAt());
        controller.detonate();
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Flat));
        assertEq(factory.currentRoundId(), 1, "spawn bounced on ReservationActive");
        // recovery: void, permissionless reserve + birth
        factory.voidReservation();
        vm.prank(dave);
        factory.reserveSpawn(1);
        vm.prank(dave);
        factory.birthRound();
        assertEq(factory.currentRoundId(), 2, "successor born permissionlessly");
        // and round-1 exits still work
        vm.prank(bob); controller.claimPredepositPSP();
        uint256 id = staker.primaryOf(bob);
        vm.prank(bob); staker.withdraw(id);
        uint256 bobPsp = pspToken.balanceOf(bob);
        vm.prank(bob); hook.redeemBacking(bobPsp);
        assertEq(pspToken.totalSupply(), 0);
    }

    /// B2: drive the reserve deep below the launch backing with repeated
    /// sells, trade back up, and sell again. The inverse must never fail.
    function testFuzz_B2_DeepSellBelowBootNeverBricks(uint256 seed) public {
        seedState = seed;
        vm.prank(bob); controller.claimPredepositPSP();
        uint256 id = staker.primaryOf(bob);
        vm.prank(bob); staker.requestWithdraw(id);
        skip(6 hours + 1);
        vm.prank(bob); staker.withdraw(id); // bob now holds ~all supply liquid
        uint256 boot = hook.reserveMixETH();
        for (uint256 i; i < 12; ++i) {
            uint256 bal = pspToken.balanceOf(bob);
            uint256 supply = hook.totalSupplyPSP();
            // sell a large random fraction, leaving at least 1e12 + 1 wei in supply
            uint256 maxSell = supply > 2e12 ? supply - 1e12 - 1 : 0;
            if (maxSell > bal) maxSell = bal;
            if (maxSell < 1e12) break;
            uint256 amt = 1e12 + _rnd(maxSell - 1e12 + 1);
            _sell(bob, amt);
            _assertHookInvariants();
            if (_rnd(3) == 0) _buy(alice, 1e15 + _rnd(5e18));
        }
        assertLt(hook.reserveMixETH(), boot, "reserve went below the launch backing");
        emit log_named_uint("B2: reserve after deep sells (wei)", hook.reserveMixETH());
        // trade back up and out
        _buy(alice, 200e18);
        _sell(alice, pspToken.balanceOf(alice) / 2);
        vm.warp(hook.detonationAt());
        controller.detonate();
        uint256 aPsp = pspToken.balanceOf(alice);
        vm.prank(alice); hook.redeemBacking(aPsp);
        uint256 bPsp = pspToken.balanceOf(bob);
        vm.prank(bob); hook.redeemBacking(bPsp);
        assertEq(pspToken.totalSupply(), 0);
    }

    /// B3: a position in every decay phase (request epoch + k) can still
    /// leave at flat, and the global weight stays consistent.
    function testFuzz_B3_WithdrawAtFlatFromEveryDecayPhase(uint8 k) public {
        k = uint8(bound(k, 0, 9));
        vm.prank(bob); controller.claimPredepositPSP();
        uint256 id = staker.primaryOf(bob);
        _buy(alice, 20e18);
        uint256 half = pspToken.balanceOf(alice) / 2;
        vm.prank(alice); staker.lock(half); // second live position
        vm.prank(bob); staker.requestWithdraw(id);
        skip(uint256(k) * 1 hours);
        if (block.timestamp < hook.detonationAt()) vm.warp(hook.detonationAt());
        controller.detonate();
        vm.prank(bob); staker.withdraw(id);
        uint256 aliceId = staker.primaryOf(alice);
        (uint256 aliceAmt,,,,) = staker.positions(aliceId);
        assertEq(staker.totalWeight(), aliceAmt, "global weight == remaining live weight");
        vm.prank(alice); staker.withdraw(aliceId);
        assertEq(staker.totalWeight(), 0, "weight zero once everyone left");
        assertEq(pspToken.balanceOf(address(staker)), 0);
    }

    /// B4: seat evictions with mixed buyers — claims sum to the frozen pot.
    function test_B4_LadderClaimsSumToPotAcrossEvictions() public {
        skip(1 hours);
        uint256 tp = hook.ticketPrice();
        _buy(alice, tp * 4);
        _buy(carol, hook.ticketPrice() * 7);   // evicts alice's older seats
        _buy(dave, hook.ticketPrice() * 3);
        _buy(alice, hook.ticketPrice() * 2);
        assertGt(hook.ticketCount(), 10);
        vm.warp(hook.detonationAt());
        controller.detonate();
        uint256 pot = hook.potBalance();
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            uint256 c = hook.claimablePot(actors[i]);
            sum += c;
            if (c > 0) { vm.prank(actors[i]); hook.claimPot(); }
        }
        assertLe(sum, pot, "claims never exceed the pot");
        assertGe(sum + 10, pot, "at most 10 wei of rounding dust");
        assertEq(hook.potPaid(), sum);
        vm.prank(alice); vm.expectRevert(CurveHook.NothingToClaim.selector); hook.claimPot();
    }

    /// B5: push the curve to its capacity edge; buys must fail closed
    /// while sells, detonation and redemption keep working.
    function test_B5_CapacityEdgeFailsClosedButExitsWork() public {
        vm.deal(address(this), 3_000_000e18);
        mixETH.depositETH{value: 2_500_000e18}();
        mixETH.transfer(alice, 2_500_000e18);
        uint256 spent;
        bytes memory lastErr;
        for (uint256 i; i < 60; ++i) {
            uint256 amt = 50_000e18;
            vm.prank(alice);
            try zapIn.buyWithMix(poolKey, amt, 0, 0) { spent += amt; }
            catch (bytes memory err) { lastErr = err; break; }
        }
        emit log_named_uint("B5: mixETH absorbed before the curve refused (1e18)", spent / 1e18);
        emit log_named_uint("B5: reserve (1e18)", hook.reserveMixETH() / 1e18);
        assertGt(lastErr.length, 0, "a buy eventually fails closed");
        // sells keep working from the accepted state
        uint256 half = pspToken.balanceOf(alice) / 2;
        if (half >= 1e12) { vm.prank(alice); zapOut.sellToMix(poolKey, half, 0, 0); }
        _assertHookInvariants();
        vm.warp(hook.detonationAt());
        controller.detonate();
        uint256 aPsp = pspToken.balanceOf(alice);
        vm.prank(alice); hook.redeemBacking(aPsp);
        vm.prank(bob); controller.claimPredepositPSP();
        uint256 bobId = staker.primaryOf(bob);
        vm.prank(bob); staker.withdraw(bobId);
        uint256 bPsp = pspToken.balanceOf(bob);
        vm.prank(bob); hook.redeemBacking(bPsp);
        assertEq(pspToken.totalSupply(), 0);
    }

    /// B6: exact clock boundary — the last buy at detonationAt-1 lands and
    /// extends; at detonationAt buys/sells halt and detonate works.
    function test_B6_ClockBoundaryIsExact() public {
        uint256 at = hook.detonationAt();
        vm.warp(at - 1);
        assertTrue(_buy(alice, 1e18), "buy one second before zero");
        assertGt(hook.detonationAt(), at, "extended");
        uint256 at2 = hook.detonationAt();
        vm.warp(at2);
        vm.prank(alice); vm.expectRevert(); zapIn.buyWithMix(poolKey, 1e18, 0, 0);
        vm.prank(alice); vm.expectRevert(); zapOut.sellToMix(poolKey, 1e12, 0, 0);
        controller.detonate();
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Flat));
    }

    /// B7: a stuck-in-predeposit successor (nobody deposits) is not a
    /// dead end: any 1-wei deposit after the window lets anyone launch.
    function test_B7_EmptySuccessorIsRecoverableByAnyone() public {
        vm.warp(hook.detonationAt());
        controller.detonate();
        PSPFactory.Round memory r2 = factory.getRound(2);
        skip(r2.controller.PREDEPOSIT_DURATION() + 1);
        vm.expectRevert(); // zero boot cannot launch
        r2.controller.launchPooledBuy();
        vm.startPrank(dave);
        mixETH.approve(address(r2.controller), 1);
        r2.controller.predeposit(1);
        r2.controller.launchPooledBuy();
        vm.stopPrank();
        assertEq(uint8(r2.hook.mode()), uint8(CurveHook.Mode.Active));
    }

    /// B8: a mixETH vault-rate move mid-round changes NOTHING in settlement
    /// (NK24): quotes, ticket price, and exit values are rate-independent.
    function test_B8_VaultRateMoveIsInvisibleToSettlement() public {
        _buy(alice, 50e18);
        uint256 q1 = hook.getBuyOutput(5e18);
        uint256 s1 = hook.getSellOutput(1e18);
        uint256 tp1 = hook.ticketPrice();
        mixETH.setExchangeRate(1.7e18);           // +70% yield
        assertEq(hook.getBuyOutput(5e18), q1, "buy quote ignores the vault rate");
        assertEq(hook.getSellOutput(1e18), s1, "sell quote ignores the vault rate");
        assertEq(hook.ticketPrice(), tp1, "ticket price ignores the vault rate");
        mixETH.setExchangeRate(3e18);             // another jump (mock only moves up)
        assertEq(hook.getBuyOutput(5e18), q1);
        assertEq(hook.getSellOutput(1e18), s1);
        _buy(carol, 5e18);
        _sell(alice, 1e18);
        _assertHookInvariants();
        vm.warp(hook.detonationAt());
        controller.detonate();
        uint256 aPsp = pspToken.balanceOf(alice);
        vm.prank(alice); hook.redeemBacking(aPsp);
        _assertHookInvariants();
    }

    // ───────────────────────── family T: theft attempts ─────────────────────────

    function test_T1_DoubleClaimsYieldNothing() public {
        vm.prank(bob); controller.claimPredepositPSP();
        uint256 id = staker.primaryOf(bob);
        _buy(alice, 50e18);
        uint256 before = mixETH.balanceOf(bob);
        vm.prank(bob); staker.claimFees(id);
        uint256 paid = mixETH.balanceOf(bob) - before;
        assertGt(paid, 0);
        vm.prank(bob); vm.expectRevert(PSPStaker.NothingToClaim.selector); staker.claimFees(id);
        uint256[] memory dup = new uint256[](3); dup[0] = id; dup[1] = id; dup[2] = id;
        vm.prank(bob); vm.expectRevert(PSPStaker.NothingToClaim.selector); staker.claimAllTo(dup, bob);
        vm.prank(bob); vm.expectRevert(RoundController.PredepositClosed.selector); controller.claimPredepositPSP();
    }

    function test_T2_PrivilegedEntryPointsRejectStrangers() public {
        address[5] memory who; uint256[5] memory amts; amts[0] = 1; who[0] = alice;
        vm.prank(alice); vm.expectRevert(PSPReferralRegistry.UnauthorizedRewardCredit.selector);
        registry.creditReferralRewards(who, amts);
        vm.prank(alice); vm.expectRevert(CurveHook.NotController.selector); hook.setMode(CurveHook.Mode.Flat);
        vm.prank(alice); vm.expectRevert(CurveHook.NotController.selector); hook.initializeCurve(1, 1, 0);
        vm.prank(alice); vm.expectRevert(CurveHook.NotController.selector); hook.configureSineV3(1e12, address(1));
        vm.prank(alice); vm.expectRevert(CurveHook.NotController.selector); hook.sendFees(alice, 1);
        vm.prank(alice); vm.expectRevert(RoundController.NotHook.selector); controller.mintPSPForSwap(1);
        vm.prank(alice); vm.expectRevert(RoundController.NotFactory.selector); controller.seedCarry(1);
        vm.prank(alice); vm.expectRevert(PSPStaker.NotController.selector); staker.lockGenesis(1);
        vm.prank(alice); vm.expectRevert(PSPStaker.NotController.selector); staker.claimGenesisShare(alice, 1);
        vm.prank(alice); vm.expectRevert(PSPFactory.NotRoundController.selector); factory.markDestroyed(1);
        vm.prank(alice); vm.expectRevert(); factory.reserveGenesis(PSPFactory.RoundParams({
            name: "X", symbol: "X",
            curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
        }));
        vm.prank(alice); vm.expectRevert(); factory.configureSineV3(1e12);
    }

    /// T3: after death, the V4 flat sell and redeemBacking pay the same
    /// per-PSP rate; neither can be used to skim the other.
    function test_T3_FlatSellAndRedeemAgree() public {
        _buy(alice, 100e18);
        _buy(carol, 100e18);
        vm.warp(hook.detonationAt());
        controller.detonate();
        uint256 a = pspToken.balanceOf(alice) / 3;
        uint256 c = pspToken.balanceOf(carol) / 3;
        vm.prank(alice); uint256 viaV4 = zapOut.sellToMix(poolKey, a, 0, 0);
        vm.prank(carol); uint256 viaRedeem = hook.redeemBacking(c);
        // same rate within 1 wei per unit
        uint256 rateA = viaV4 * 1e18 / a;
        uint256 rateC = viaRedeem * 1e18 / c;
        assertApproxEqAbs(rateA, rateC, 2, "flat sell and redeem pay the same rate");
    }

    /// T4: a direct PM swap naming a victim as trader can only CREDIT the
    /// victim; the attacker keeps paying and gets only their PSP.
    function test_T4_SpoofedTraderOnlyCreditsTheVictim() public {
        Spoofer sp = new Spoofer(poolManager, IERC20(address(mixETH)));
        vm.prank(alice); mixETH.approve(address(sp), type(uint256).max);
        skip(1 hours);
        uint256 tp = hook.ticketPrice();
        uint256 victimMix = mixETH.balanceOf(dave);
        uint256 victimPsp = pspToken.balanceOf(dave);
        vm.prank(alice);
        uint256 got = sp.buy(poolKey, tp * 3, alice, dave, tp);
        assertGt(got, 0);
        assertEq(pspToken.balanceOf(alice), got, "attacker got the PSP they paid for");
        assertEq(mixETH.balanceOf(dave), victimMix, "victim mixETH untouched");
        assertEq(pspToken.balanceOf(dave), victimPsp, "victim PSP untouched");
        CurveHook.LadderEntry[10] memory l = hook.getLadder();
        assertEq(l[0].buyer, dave, "seats credited to the named trader");
        // nothing can be pulled from dave via hookData: no allowance path exists
        assertEq(mixETH.allowance(dave, address(sp)), 0);
    }

    /// T5: genesis claim after the successor is born still pays the right
    /// share plus its accrued fees, and a second wallet cannot claim it.
    function test_T5_LateGenesisClaimAfterRebirth() public {
        _buy(alice, 100e18); // fees accrue to the genesis position
        vm.warp(hook.detonationAt());
        controller.detonate();
        assertEq(factory.currentRoundId(), 2);
        vm.prank(alice); vm.expectRevert(RoundController.ZeroAmount.selector); controller.claimPredepositPSP();
        uint256 before = mixETH.balanceOf(bob);
        vm.prank(bob); controller.claimPredepositPSP();
        assertGt(mixETH.balanceOf(bob) - before, 0, "accrued genesis fees paid on claim");
        uint256 id = staker.primaryOf(bob);
        (uint256 amt,,,,) = staker.positions(id);
        assertEq(amt, controller.genesisPSPSnapshot(), "sole depositor gets the whole genesis");
        vm.prank(bob); staker.withdraw(id);
        vm.prank(bob); hook.redeemBacking(amt);
    }
}

contract Spoofer {
    IPoolManager public immutable pm;
    IERC20 public immutable mix;
    constructor(IPoolManager _pm, IERC20 _mix) { pm = _pm; mix = _mix; }
    function buy(PoolKey calldata key, uint256 mixIn, address to, address trader, uint256 maxTp) external returns (uint256) {
        mix.transferFrom(msg.sender, address(this), mixIn);
        return abi.decode(pm.unlock(abi.encode(key, mixIn, to, trader, maxTp)), (uint256));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm));
        (PoolKey memory key, uint256 amt, address to, address trader, uint256 maxTp) =
            abi.decode(data, (PoolKey, uint256, address, address, uint256));
        bool mixIsZero = Currency.unwrap(key.currency0) == address(mix);
        Currency mixCur = mixIsZero ? key.currency0 : key.currency1;
        Currency pspCur = mixIsZero ? key.currency1 : key.currency0;
        pm.sync(mixCur); mix.transfer(address(pm), amt); pm.settle();
        BalanceDelta d = pm.swap(key, SwapParams({
            amountSpecified: -int256(amt),
            sqrtPriceLimitX96: mixIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            zeroForOne: mixIsZero
        }), abi.encode(trader, maxTp));
        int256 pd = mixIsZero ? d.amount1() : d.amount0();
        uint256 out = uint256(int256(pd));
        pm.take(pspCur, to, out);
        return abi.encode(out);
    }
}
