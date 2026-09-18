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

/// @dev Audit PoCs (2026-09-18 pass over single-sine-spec @ e9a70d44).
///      Each test pins an OBSERVED behaviour on the real local V4 rig so the
///      report's residual notes are evidence-backed, not speculation.
contract FableAuditPoC is RealV4Base {
    address carol = makeAddr("fable-carol");
    PlainRouter router;

    function setUp() public override {
        super.setUp();
        router = new PlainRouter(poolManager, IERC20(address(mixETH)));
        mixETH.transfer(alice, 5_000e18);
        mixETH.transfer(carol, 5_000e18);
        vm.prank(alice);
        mixETH.approve(address(router), type(uint256).max);
        vm.prank(alice);
        mixETH.approve(address(zapIn), type(uint256).max);
        vm.prank(carol);
        mixETH.approve(address(zapIn), type(uint256).max);
    }

    /* ---------------------------------------------------------------
       F1 - Generic routers (empty hookData) seat the ROUTER, not the
       human. After detonation that pot share is claimable only by the
       router contract, so it is stranded in the escrow forever.
       --------------------------------------------------------------- */
    function test_F1_EmptyHookDataSeatsTheRouterAndStrandsThePot() public {
        skip(1 hours);
        uint256 tp = hook.ticketPrice();
        vm.prank(alice);
        router.buy(poolKey, tp * 10, alice);

        // every live seat belongs to the router contract, not alice
        CurveHook.LadderEntry[10] memory ladder = hook.getLadder();
        assertEq(ladder[0].buyer, address(router), "F1: seat credited to the router");
        assertEq(hook.seatedCount(), 10, "F1: ten seats taken");

        skip(hook.detWindow() + 1);
        controller.detonate();

        uint256 pot = hook.potBalance();
        assertGt(pot, 0, "F1: frozen pot is non-empty");
        assertEq(hook.claimablePot(alice), 0, "F1: alice has no claim");
        assertEq(hook.claimablePot(address(router)), pot, "F1: whole pot belongs to the router");
        // the router has no claim function -> the mixETH is unreachable
        vm.expectRevert(CurveHook.NothingToClaim.selector);
        vm.prank(alice);
        hook.claimPot();
    }

    /* ---------------------------------------------------------------
       F2 - Referral self-rebate: record against a friend's qualifying
       NFT, then take custody of that NFT. Every later trade pays the
       tier-1 leg (80% of the 5%-of-fee referral leg) to the trader.
       --------------------------------------------------------------- */
    function test_F2_ReferralSelfRebateViaNftTransfer() public {
        PSPStaker staker = controller.staker();
        PSPReferralRegistry registry = PSPReferralRegistry(factory.referralRegistryOf(1));

        // bob claims his genesis share (well above the 1,000 PSP referrer bar)
        vm.prank(bob);
        controller.claimPredepositPSP();
        uint256 bobNft = staker.tokenOfOwnerByIndex(bob, 0);
        assertTrue(registry.canReferNft(bobNft), "F2: bob's NFT qualifies");

        // alice binds to bob's NFT, then bob hands the NFT to alice
        vm.prank(alice);
        registry.record(bobNft);
        vm.prank(bob);
        staker.transferFrom(bob, alice, bobNft);

        // alice's own trade now pays alice
        uint256 before = registry.claimableReferral(alice);
        vm.prank(alice);
        zapIn.buyWithMix(poolKey, 100e18, 0, 0);
        uint256 earned = registry.claimableReferral(alice) - before;
        assertGt(earned, 0, "F2: trader collects their own referral leg");

        // and it is exactly the tier-1 cut of the 5% referral leg
        uint256 fee = 100e18 * 1000 / 10000; // pre-wave 10% fee band
        uint256 refLeg = fee - fee * 6000 / 10000 - fee * 3500 / 10000;
        assertEq(earned, refLeg * 8000 / 10000, "F2: tier-1 = 80% of the referral leg");
    }

    /* ---------------------------------------------------------------
       F3 - Owner power: reserveGenesis/deployRound carry no "current
       round is dead" guard. The owner can birth round 2 while round 1
       is still Active; round 1's detonate() then cannot spawn (spawn
       chains strictly forward) and reports nextRound = 0.
       --------------------------------------------------------------- */
    function test_F3_OwnerCanBirthGenesisOverALiveRound() public {
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Active));
        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
        });
        factory.reserveGenesis(params);
        factory.birthRound();
        assertEq(factory.currentRoundId(), 2, "F3: round 2 born over a live round 1");
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Active), "F3: round 1 still Active");

        skip(hook.detWindow() + 1);
        vm.recordLogs();
        controller.detonate();
        // round 1 flattened but could not spawn (NotLatestRound is tolerated)
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Flat));
        assertEq(factory.currentRoundId(), 2, "F3: no round 3 was spawned by round 1");
    }

    /* ---------------------------------------------------------------
       F4 - Pre-launch minimum after a real rebirth (471b0443): the
       successor hook quotes the fixed 0.005 floor before its pool
       exists, and the predeposit path (which re-runs the exact genesis
       calculation each time) stays affordable.
       --------------------------------------------------------------- */
    function test_F4_RebirthPreLaunchMinimumAndPredepositGas() public {
        skip(hook.detWindow() + 1);
        controller.detonate();
        assertEq(factory.currentRoundId(), 2, "F4: successor born in detonate()");

        PSPFactory.Round memory r2 = factory.getRound(2);
        assertFalse(r2.hook.poolInitialized());
        assertEq(r2.hook.ticketPrice(), 0.005 ether, "F4: pre-launch spot = 0.005");
        assertEq(r2.hook.MIN_BUY_INPUT(), 0.005 ether, "F4: pre-launch minimum = 0.005");

        vm.startPrank(carol);
        mixETH.approve(address(r2.controller), type(uint256).max);
        uint256 g0 = gasleft();
        r2.controller.predeposit(10e18);
        uint256 firstDeposit = g0 - gasleft();
        g0 = gasleft();
        r2.controller.predeposit(10e18);
        uint256 secondDeposit = g0 - gasleft();
        vm.stopPrank();
        emit log_named_uint("F4: first predeposit gas", firstDeposit);
        emit log_named_uint("F4: second predeposit gas", secondDeposit);
        assertLt(secondDeposit, 3_000_000, "F4: predeposit stays under 3M gas");

        // launch after the window and confirm pot-priced spots take over
        skip(r2.controller.PREDEPOSIT_DURATION() + 1);
        r2.controller.launchPooledBuy();
        uint256 pot = r2.hook.potBalance();
        uint256 expected = pot / 10_000 + (pot % 10_000 == 0 ? 0 : 1);
        assertEq(r2.hook.ticketPrice(), expected, "F4: post-launch spot = ceil(pot/10k)");
        assertEq(r2.hook.MIN_BUY_INPUT(), expected, "F4: minimum tracks the spot");
    }

    /* ---------------------------------------------------------------
       F5 - Third-party stakeFor cannot move a position into decay,
       reset it, or capture its fees: the donor only adds principal and
       the owner's accrued fees are paid to the OWNER first.
       --------------------------------------------------------------- */
    function test_F5_StrangerStakeForOnlyBenefitsOwner() public {
        PSPStaker staker = controller.staker();
        vm.prank(bob);
        controller.claimPredepositPSP();
        uint256 bobNft = staker.tokenOfOwnerByIndex(bob, 0);

        // fee events so bob has something accrued; carol also needs PSP
        vm.prank(alice);
        zapIn.buyWithMix(poolKey, 100e18, 0, 0);
        vm.prank(carol);
        zapIn.buyWithMix(poolKey, 1e18, 0, 0);
        uint256 pending = staker.pendingFeesOf(bobNft);
        assertGt(pending, 0);

        // carol donates 1 wei of PSP into bob's pepe
        uint256 bobMixBefore = mixETH.balanceOf(bob);
        uint256 carolMixBefore = mixETH.balanceOf(carol);
        vm.startPrank(carol);
        IERC20(address(pspToken)).approve(address(staker), 1);
        staker.stakeFor(bob, bobNft, 1);
        vm.stopPrank();

        assertEq(mixETH.balanceOf(bob) - bobMixBefore, pending, "F5: fees settled to the owner");
        assertEq(mixETH.balanceOf(carol), carolMixBefore, "F5: donor received nothing");
        assertFalse(staker.isWithdrawing(bobNft));
        assertEq(staker.ownerOf(bobNft), bob);
    }

    /* ---------------------------------------------------------------
       F6 - Dust-size buys are exempt from MIN_SWAP_INPUT on v3 rounds.
       On a tiny-boot round the ladder spot sits far below 1e12 wei, so
       this is the one path where sub-dust curve buys settle. Round
       trips must still lose and the hook must stay solvent.
       --------------------------------------------------------------- */
    function testFuzz_F6_TinyRoundDustRoundTripNeverWins(uint256 spend, uint8 legs) public {
        // fresh tiny round: detonate round 1, spawn round 2, seed 0.05 mixETH
        skip(hook.detWindow() + 1);
        controller.detonate();
        PSPFactory.Round memory r2 = factory.getRound(2);
        vm.startPrank(carol);
        mixETH.approve(address(r2.controller), type(uint256).max);
        r2.controller.predeposit(0.05e18);
        vm.stopPrank();
        skip(r2.controller.PREDEPOSIT_DURATION() + 1);
        r2.controller.launchPooledBuy();
        CurveHook h = r2.hook;
        PoolKey memory key = _keyFor(address(r2.token), h);
        uint256 tp = h.ticketPrice();
        assertLt(tp, h.MIN_SWAP_INPUT(), "F6: spot below the dust guard");

        legs = uint8(bound(legs, 1, 6));
        spend = bound(spend, tp, 1e14);
        vm.startPrank(alice);
        mixETH.approve(address(zapIn), type(uint256).max);
        IERC20(address(r2.token)).approve(address(zapOut), type(uint256).max);
        uint256 mixIn;
        uint256 pspGot;
        for (uint256 i; i < legs; ++i) {
            uint256 s = spend + i; // adjacent sizes probe rounding edges
            if (s < h.ticketPrice()) s = h.ticketPrice();
            pspGot += zapIn.buyWithMix(key, s, 0, 0);
            mixIn += s;
        }
        uint256 mixOut;
        if (pspGot >= h.MIN_SWAP_INPUT() && pspGot < h.totalSupplyPSP()) {
            mixOut = zapOut.sellToMix(key, pspGot, 0, 0);
        }
        vm.stopPrank();
        assertLt(mixOut, mixIn, "F6: round trip must lose");
        _assertSolvent(h);
    }

    function _keyFor(address token, CurveHook h) internal view returns (PoolKey memory k) {
        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(token);
        if (c0 > c1) (c0, c1) = (c1, c0);
        k = PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: h});
    }

    function _assertSolvent(CurveHook h) internal view {
        uint256 bal = mixETH.balanceOf(address(h));
        uint256 escrow = h.reserveMixETH() + (h.potBalance() - h.potPaid()) + (h.deployerCredit() - h.deployerCreditPaid());
        assertGe(bal, escrow, "solvency: balance covers reserve + escrows");
        (,, uint256 boot, uint256 lam,,, address table) = h.sineV3Info();
        uint256 q = ISineV3MathView(table).supplyWad(h.reserveMixETH(), boot, lam, h.sinePL());
        assertLe(h.totalSupplyPSP(), q, "supply never exceeds the curve integral");
    }
}

interface ISineV3MathView {
    function supplyWad(uint256 R, uint256 boot, uint256 lam, uint256 pL) external view returns (uint256);
}

/// @dev A "generic" V4 router: exact-input buy with EMPTY hookData, the
///      way a third-party aggregator would route.
contract PlainRouter {
    IPoolManager public immutable pm;
    IERC20 public immutable mix;

    constructor(IPoolManager _pm, IERC20 _mix) {
        pm = _pm;
        mix = _mix;
    }

    function buy(PoolKey calldata key, uint256 mixIn, address to) external returns (uint256) {
        mix.transferFrom(msg.sender, address(this), mixIn);
        return abi.decode(pm.unlock(abi.encode(key, mixIn, to)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, uint256 amt, address to) = abi.decode(data, (PoolKey, uint256, address));
        bool mixIsZero = Currency.unwrap(key.currency0) == address(mix);
        Currency mixCur = mixIsZero ? key.currency0 : key.currency1;
        Currency pspCur = mixIsZero ? key.currency1 : key.currency0;
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
            ""
        );
        int256 pspDelta = mixIsZero ? d.amount1() : d.amount0();
        require(pspDelta > 0, "no out");
        uint256 out = uint256(int256(pspDelta));
        pm.take(pspCur, to, out);
        return abi.encode(out);
    }
}
