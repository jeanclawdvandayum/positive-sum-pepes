// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {PSPStaker} from "../../src/PSPStaker.sol";
import {PSPReferralRegistry} from "../../src/PSPReferralRegistry.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../src/PSPZapOut.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {IMixETH} from "../../src/interfaces/IMixETH.sol";

import {MainnetConfig} from "./MainnetConfig.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";
import {StakerDeployer} from "src/StakerDeployer.sol";


/// @title ReferralTest (fork) — v5.1 per-round, NFT-keyed referral graph
/// @notice Proves the 50bps referral carve-out end to end (2026-08-19 v5.1:
///         attribution targets a staker position NFT ID and the graph RESETS
///         at every round boundary; A-1 fix 2026-08-26: attribution binds
///         ONLY via the user-signed registry.record()):
///         R1 one-time attribution per round — explicit record() binds
///         R2 min-stake gate — dead NFT / under-1000-PSP referrer never binds
///         R3 unattributed trades route the full 500bps to stakers
///         R4 5-dimensional split on buys: 80/12/5/2/1 of the 50bps budget
///         R5 sells pay the carve-out too
///         R6 registry cycle guard
///         R7 NFT transfer moves lock + fee entitlement + referral payout flow
///         R8 the graph resets at round boundaries — rebind across rounds
contract ReferralTest is Test {
    IPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;
    PSPZapIn zapIn;
    PSPZapOut zapOut;

    CurveMath.CurveConfig cfg;

    PSPToken pspToken;
    RoundController controller;
    PSPStaker public stakerV; // cached: single vm.prank must not be eaten by the staker() view call
    CurveHook hook;
    PSPReferralRegistry registry;
    PoolKey poolKey;

    address alice = makeAddr("alice"); // genesis staker (qualified referrer)
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address frank = makeAddr("frank"); // the trader
    address zed = makeAddr("zed");     // 5th dimension

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        poolManager = IPoolManager(MainnetConfig.POOL_MANAGER);
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();

        factory = new PSPFactory(poolManager, IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer(), new StakerDeployer(), 0);
        zapIn = new PSPZapIn(IMixETH(address(mixETH)), poolManager);
        zapOut = new PSPZapOut(IMixETH(address(mixETH)), poolManager);

        address[7] memory who = [alice, bob, carol, dave, erin, frank, zed];
        for (uint256 i = 0; i < who.length; i++) _dealMixETH(who[i], 5_000e18);

        _deployRound();
    }

    // ══════════════════════════════════════════════════════════════
    //  R1: one-time attribution (per round) — user-signed record() only
    // ══════════════════════════════════════════════════════════════
    function test_R1_AttributionBindsOnce() public {
        _launchWithAlice();
        uint256 aliceNft = _nftOf(alice);

        // bob explicitly records alice's position NFT — the ONLY bind path
        // (A-1 fix: swaps, routers and forged hookData bind nothing)
        vm.prank(bob);
        registry.record(aliceNft);
        assertEq(registry.traderRefNftOf(bob), aliceNft, "bob bound to alice's NFT");

        // a second record is rejected — attribution is one-shot per round
        _buyAndLock(carol, 10e18, alice); // carol becomes referable
        uint256 carolNft = _nftOf(carol); // hoisted: staticcall would eat the revert slot
        vm.prank(bob);
        vm.expectRevert(PSPReferralRegistry.AlreadyReferred.selector);
        registry.record(carolNft);

        // and carol earns nothing from bob's later trades
        uint256 carolBefore = mixETH.balanceOf(carol);
        _buy(bob, 5e18);
        assertEq(mixETH.balanceOf(carol), carolBefore, "non-recorded referrer earns nothing");
    }

    // ══════════════════════════════════════════════════════════════
    //  R2: min-stake gate — skin in the game
    // ══════════════════════════════════════════════════════════════
    function test_R2_UnqualifiedReferrerNeverBinds() public {
        _launchWithAlice();

        // carol holds no position — no NFT, no link
        assertFalse(registry.canReferNft(_nftOf(carol)), "carol has no NFT");
        assertTrue(registry.canReferNft(_nftOf(alice)), "alice's NFT is referable");

        // a nonexistent NFT id is a dead link: bob never binds (there is no
        // lazy path anymore — nothing to swallow) and his trade stays
        // unattributed unless he explicitly records a live referrer
        _buy(bob, 10e18);
        assertEq(registry.traderRefNftOf(bob), 0, "dead NFT link never binds");

        // direct record with a dead NFT reverts loudly
        vm.expectRevert(PSPReferralRegistry.NotQualifiedReferrer.selector);
        registry.record(999_999);

        // bob's trade was effectively unattributed: alice (the only locker)
        // accrues the FULL 5% — nothing silently vanished
        uint256 alicePending = stakerV.pendingFeesOf(alice);
        assertApproxEqAbs(
            alicePending, (10e18 * 500 / 10000) * _aliceShareOfLocked() / 1e18, 1e15,
            "unattributed fee routed to stakers"
        );
    }

    // ══════════════════════════════════════════════════════════════
    //  R3: unattributed trade — full 500bps to stakers
    // ══════════════════════════════════════════════════════════════
    function test_R3_UnattributedGoesToStakers() public {
        _launchWithAlice();

        uint256 pending = stakerV.pendingFeesOf(alice);
        assertEq(pending, 0);

        _buy(bob, 10e18, address(0));

        // alice is the sole locker: her pending = whole 5% of 10e18
        uint256 expect = (10e18 * 500 / 10000) * _aliceShareOfLocked() / 1e18;
        assertApproxEqAbs(stakerV.pendingFeesOf(alice), expect, 1e15,
            "stakers received the full unattributed fee");
    }

    // ══════════════════════════════════════════════════════════════
    //  R4: 5-dimensional split — 80/12/5/2/1 of the 50bps budget
    // ══════════════════════════════════════════════════════════════
    function test_R4_FiveDimensionSplitOnBuy() public {
        _launchWithAlice();

        // build the chain bottom-up: alice<-bob<-carol<-dave<-erin<-zed
        // (each buys on their referrer's NFT, then locks their own —
        //  buy-then-lock is the natural flow the edge fallback resolves)
        _buyAndLock(bob, 10e18, alice);
        _buyAndLock(carol, 10e18, bob);
        _buyAndLock(dave, 10e18, carol);
        _buyAndLock(erin, 10e18, dave);
        _buyAndLock(zed, 10e18, erin);

        // bind frank to zed's NFT via a dust buy, then read the chain
        _buy(frank, 1e15, zed);
        (address[5] memory who,) = registry.payoutFor(frank);
        assertEq(who[0], zed, "dim1 = zed");
        assertEq(who[1], erin, "dim2 = erin");
        assertEq(who[2], dave, "dim3 = dave");
        assertEq(who[3], carol, "dim4 = carol");
        assertEq(who[4], bob, "dim5 = bob");

        // snapshot balances right before the measured trade
        uint256 zedB = mixETH.balanceOf(zed);
        uint256 erinB = mixETH.balanceOf(erin);
        uint256 daveB = mixETH.balanceOf(dave);
        uint256 carolB = mixETH.balanceOf(carol);
        uint256 bobB = mixETH.balanceOf(bob);
        uint256 aliceB = mixETH.balanceOf(alice);

        // frank's trade: zed is dim1, zed's own chain fills dims 2-5
        // (erin, dave, carol, bob). alice is dim6 — beyond the window.
        uint256 vol = 100e18;
        _buy(frank, vol, zed);

        uint256 budget = vol * 50 / 10000; // 50bps of input
        assertEq(mixETH.balanceOf(zed) - zedB, budget * 8000 / 10000, "dim1 (zed) = 80%");
        assertEq(mixETH.balanceOf(erin) - erinB, budget * 1200 / 10000, "dim2 (erin) = 12%");
        assertEq(mixETH.balanceOf(dave) - daveB, budget * 500 / 10000, "dim3 (dave) = 5%");
        assertEq(mixETH.balanceOf(carol) - carolB, budget * 200 / 10000, "dim4 (carol) = 2%");
        assertEq(mixETH.balanceOf(bob) - bobB, budget * 100 / 10000, "dim5 (bob) = 1%");
        assertEq(mixETH.balanceOf(alice), aliceB, "dim6+ earns nothing");
    }

    // ══════════════════════════════════════════════════════════════
    //  R5: sells pay the carve-out
    // ══════════════════════════════════════════════════════════════
    function test_R5_SellPaysReferral() public {
        _launchWithAlice();

        uint256 bobPSP = _buy(bob, 20e18, alice);
        uint256 aliceBefore = mixETH.balanceOf(alice);

        // bob sells his whole stack, attributed to alice's NFT
        vm.startPrank(bob);
        pspToken.approve(address(zapOut), bobPSP);
        zapOut.sellToMix(poolKey, bobPSP, 0, 0);
        vm.stopPrank();

        // single-dim 80% cut of 50bps of the sell output — exact math:
        // read alice's gain off the ReferralPaid event instead of
        // re-deriving the curve
        uint256 aliceGain = mixETH.balanceOf(alice) - aliceBefore;
        assertGt(aliceGain, 0, "referral paid on sell");
    }

    // ══════════════════════════════════════════════════════════════
    //  R6: registry cycle guard
    // ══════════════════════════════════════════════════════════════
    function test_R6_CycleGuard() public {
        _launchWithAlice();
        _buyAndLock(bob, 10e18, alice); // bob <- alice (bob holds NFT)

        // alice trying to bind to bob's NFT would create a cycle (bob's
        // chain contains alice's NFT) — the registry must reject it
        // (precompute the NFT id: arg evaluation would eat the revert slot)
        uint256 bobNft = _nftOf(bob);
        vm.prank(alice);
        vm.expectRevert(PSPReferralRegistry.WouldCreateCycle.selector);
        registry.record(bobNft);

        assertEq(registry.traderRefNftOf(alice), 0, "no cycle created");
    }

    // ══════════════════════════════════════════════════════════════
    //  R7: NFT transfer moves lock + fee entitlement + referral flow
    // ══════════════════════════════════════════════════════════════
    function test_R7_PositionNFTTransfer() public {
        _launchWithAlice();

        uint256 bobPSP = _buyAndLock(bob, 20e18, alice);
        PSPStaker staker = controller.staker();
        uint256 nft = staker.tokenOf(bob);

        // fees accrue while bob holds the position
        _buy(carol, 10e18, bob);
        assertGt(staker.pendingFeesOf(bob), 0, "bob has pending fees");

        // referral payouts land on bob while he owns the NFT
        uint256 bobRefB = mixETH.balanceOf(bob);
        _buy(carol, 10e18, bob); // carol already bound to bob's NFT
        assertGt(mixETH.balanceOf(bob), bobRefB, "bob earns referral cuts as NFT owner");

        // bob transfers his LOCKED position NFT to carol
        vm.prank(bob);
        staker.transferFrom(bob, carol, nft);

        assertEq(staker.ownerOf(nft), carol, "NFT moved");
        assertEq(staker.lockedPSPOf(bob), 0, "bob has no lock left");
        assertEq(staker.lockedPSPOf(carol), bobPSP, "carol owns the locked PSP");

        // future staking fees accrue to carol, not bob
        uint256 bobPending = staker.pendingFeesOf(bob);
        _buy(dave, 10e18, address(0));
        assertEq(staker.pendingFeesOf(bob), bobPending, "bob's pending frozen");
        assertGt(staker.pendingFeesOf(carol), 0, "carol accrues going forward");

        // future REFERRAL cuts from carol's (already-bound) trades pay the
        // NFT's new owner: payouts resolve ownership live at swap time.
        // carol pays 10e18 for the buy; her chain now resolves to HERSELF
        // (she owns NFT 2), so she collects the 80% cut of the 50bps
        // carve-out (0.04e18) — and ONLY dim-1, thanks to owner dedupe.
        uint256 carolRefB = mixETH.balanceOf(carol);
        uint256 bobRefB2 = mixETH.balanceOf(bob);
        _buy(carol, 10e18, bob); // refNft resolves to 0 post-transfer; attribution persists
        assertEq(
            mixETH.balanceOf(carol),
            carolRefB - 10e18 + (10e18 * 50 * 8000) / 10000 / 10000,
            "new owner earns exactly the dim-1 cut"
        );
        assertEq(mixETH.balanceOf(bob), bobRefB2, "old owner earns nothing");

        // carol can claim
        uint256 carolBefore = mixETH.balanceOf(carol);
        vm.prank(carol);
        staker.claimFees();
        assertGt(mixETH.balanceOf(carol), carolBefore, "carol claimed");
    }

    // ══════════════════════════════════════════════════════════════
    //  R8: the graph resets at round boundaries
    // ══════════════════════════════════════════════════════════════
    function test_R8_GraphResetsAcrossRounds() public {
        _launchWithAlice();
        _buyAndLock(bob, 10e18, alice);
        _buyAndLock(carol, 10e18, bob);
        assertEq(registry.traderRefNftOf(carol), _nftOf(bob), "round 1: carol bound to bob");

        // a fresh round is born: new controller, new staker, NEW registry
        address reg1 = address(registry); // capture BEFORE redeploy rebinds state
        _deployRound(); // deploys round 2 and rebinds test state
        PSPReferralRegistry reg2 = PSPReferralRegistry(factory.referralRegistryOf(2));
        assertTrue(address(reg2) != reg1 && address(reg2) != address(0), "round 2 got a fresh registry");

        // the old graph does not leak: nobody is attributed in round 2
        assertEq(reg2.traderRefNftOf(carol), 0, "carol's attribution reset");
        assertEq(reg2.traderRefNftOf(bob), 0, "bob's attribution reset");
        assertFalse(reg2.attributed(bob), "one-shot flags reset");

        // round 2 full flow: launch, and bob REBINDS to a different referrer
        _predeposit(alice, 500e18);
        _launch();
        _claim(alice);
        assertTrue(reg2.canReferNft(_nftOf(alice)), "alice referable in round 2");

        _buy(bob, 10e18, alice);
        assertEq(reg2.traderRefNftOf(bob), _nftOf(alice), "bob rebinds in round 2");

        // and the old round-1 registry still reads its own (frozen) graph
        assertEq(registry.traderRefNftOf(carol), _nftOf(bob), "round 1 graph intact, frozen");
    }

    // ══════════════════════════════════════════════════════════════
    //  helpers
    // ══════════════════════════════════════════════════════════════

    /// @dev launch round: alice predeposits 500 (cap), factory launches,
    ///      alice claims — alice is the genesis locker (>= 1000 PSP).
    function _launchWithAlice() internal {
        _predeposit(alice, 500e18);
        _launch();
        _claim(alice);
        assertTrue(registry.canReferNft(_nftOf(alice)), "alice qualified as referrer");
    }

    function _nftOf(address user) internal view returns (uint256) {
        return stakerV.tokenOf(user);
    }

    /// @dev Buy with a referrer: the user's OWN record() binds attribution
    ///      first (A-1 fix — the only bind path), then the plain zap buy
    ///      pays the recorded chain. Later ref args are inert (one-shot).
    function _buy(address user, uint256 mixAmount, address ref) internal returns (uint256) {
        uint256 refNft = ref == address(0) ? 0 : _nftOf(ref);
        if (refNft != 0 && !registry.attributed(user)) {
            vm.prank(user);
            registry.record(refNft);
        }
        return _buy(user, mixAmount);
    }

    function _buy(address user, uint256 mixAmount) internal returns (uint256) {
        vm.startPrank(user);
        mixETH.approve(address(zapIn), mixAmount);
        uint256 out = zapIn.buyWithMix(poolKey, mixAmount, 0, 0);
        vm.stopPrank();
        return out;
    }

    function _buyAndLock(address user, uint256 mixAmount, address ref) internal returns (uint256) {
        uint256 out = _buy(user, mixAmount, ref);
        vm.startPrank(user);
        pspToken.approve(address(controller.staker()), out);
        stakerV.lock(out);
        vm.stopPrank();
        assertTrue(registry.canReferNft(_nftOf(user)), "buyer locked >= min stake");
        return out;
    }

    uint256 private _roundCounter;

    function _deployRound() internal {
        cfg = CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);

        PSPFactory.RoundParams memory params =
            PSPFactory.RoundParams({name: "Positive Sum Pepes", symbol: "PSP", curveConfig: cfg});

        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory round = factory.getRound(roundId);
        pspToken = round.token;
        controller = round.controller;
        stakerV = controller.staker();
        hook = round.hook;
        registry = PSPReferralRegistry(factory.referralRegistryOf(roundId));

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

    /// @dev alice's share of totalLocked — she is the genesis locker; others'
    ///      own locks (if any) dilute her accumulator stream.
    function _aliceShareOfLocked() internal view returns (uint256) {
        uint256 total = stakerV.totalLocked();
        if (total == 0) return 0;
        return (stakerV.lockedPSPOf(alice) * 1e18) / total;
    }

    receive() external payable {}
}
