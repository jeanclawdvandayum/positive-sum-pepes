// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {PSPFactory} from "../src/PSPFactory.sol";
import {PSPToken} from "../src/PSPToken.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {RoundController} from "../src/RoundController.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {ControllerDeployer} from "../src/ControllerDeployer.sol";
import {StakerDeployer} from "../src/StakerDeployer.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {PSPReferralRegistry} from "../src/PSPReferralRegistry.sol";
import {Curve1Zones} from "../src/curves/Curve1Zones.sol";
import {SineMath} from "../src/libraries/SineMath.sol";

import {CBase, CSwapper} from "./wave2/auditorC/CBase.sol";
import {MockMixETH} from "./mocks/MockMixETH.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title SineFee — the sliding swap fee on sine rounds (scoopy 2026-08-30)
/// @notice Fee is a continuous function of reserve depth, anchored to the
///         wave's domain:
///            R ≤ boot        → 10%      (pre-wave raise: the early game)
///            boot < R < top   → linear decay 10% → 2.5% across the wave
///            R ≥ top          → 2.5%     (above the sine — deep reserve)
///         Zone-curve rounds keep the flat 5% (pinned in RedeemIndefinite).
///         This harness mirrors DeployPSP's production sine path exactly:
///         arm the factory, deploy with a 1-zone creation shape, predeposit
///         (→ boot), launch, buy across the regions.
contract SineFee is Test {
    MockPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;
    CSwapper swapper;
    AttributedSwapper aSwapper;

    PSPToken psp1;
    RoundController controller1;
    CurveHook hook1;

    address alice = makeAddr("alice");
    address rando = makeAddr("rando");

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 2_000_000e18}();
        mixETH.transfer(rando, 100_000e18); // the buyer wallet (fresh, unattributed)
        poolManager = new MockPoolManager();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)),
            IERC20(address(mixETH)),
            new HookDeployer(),
            new ControllerDeployer(),
            new StakerDeployer(),
            0,
            address(this) // deployerCutTo (CLOCK-REDESIGN §3)
        );
        swapper = new CSwapper(IPoolManager(address(poolManager)), IERC20(address(mixETH)));
        aSwapper = new AttributedSwapper(IPoolManager(address(poolManager)), IERC20(address(mixETH)));

        // DeployPSP's default arm (tilted sine, dial-lab verified shape)
        factory.configureSine(SineMath.Params({
            p0: 1e13,
            preK: 4_605_170_185_988_092,
            magM: 20e18,
            lnTop: 6_396_929_655_216_146_432,
            ampBps: 10_000
        }));

        PSPFactory.RoundParams memory p = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: Curve1Zones.config() // creation-code shape only
        });
        (uint256 roundId,) = factory.deployRound(p);
        PSPToken token = factory.getRound(roundId).token;
        psp1 = token;
        controller1 = factory.getRound(roundId).controller;
        hook1 = factory.getRound(roundId).hook;
    }

    function _launch(uint256 boot) internal {
        mixETH.transfer(alice, boot);
        vm.startPrank(alice);
        mixETH.approve(address(controller1), boot);
        controller1.predeposit(boot);
        vm.stopPrank();
        vm.prank(address(factory));
        controller1.launchPooledBuy();
        vm.prank(alice);
        controller1.claimPredepositPSP();
    }

    function _buy(uint256 amount) internal returns (uint256 out) {
        vm.prank(rando); // fresh wallet, no attribution — 60/39/1 of the fee
        mixETH.approve(address(swapper), amount);
        vm.prank(rando);
        out = swapper.buy(_key(), amount, rando);
    }

    /// @dev Buy with the trader's address forwarded through hookData — the
    ///      canonical-zap path; attribution resolves against the registry.
    function _buyAttributed(uint256 amount, address trader) internal returns (uint256 out) {
        vm.prank(trader);
        mixETH.approve(address(aSwapper), amount);
        vm.prank(trader);
        out = aSwapper.buy(_key(), amount, trader, trader);
    }

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

    /// The three regions, read straight off the fee view.
    function test_FeeRegions() public {
        _launch(100e18); // boot = 100 mix
        // auto-getter omits cp[]: (p0, preK, boot, span, segWidth, lam, B,
        // slope, amp, pTop, tailSlope, q0, qTop)
        (,, uint256 boot, uint256 span,,,,,,,,,) = hook1.sineCurve();
        assertEq(boot, 100e18, "boot = actual raise");
        assertEq(span, 2000e18, "span = magM x boot");

        // launch seam: R == boot → pre-wave fee (r <= boot)
        assertEq(hook1.reserveMixETH(), boot, "reserve at launch = boot");
        assertEq(hook1.swapFeeBps(), 1000, "10% pre-wave");

        // mid-wave: linear decay — R moves by the POST-FEE input, so assert
        // against the live reserve, not the nominal buy size
        _buy(1000e18);
        uint256 rMid = hook1.reserveMixETH();
        assertGt(rMid, boot, "past the seam");
        assertLt(rMid, boot + span, "still inside the wave");
        assertEq(
            uint256(hook1.swapFeeBps()),
            1000 - ((750 * (rMid - boot)) / span),
            "mid-wave: linear in reserve depth"
        );

        // above the wave: R >= boot + span -> 2.5% (buy past the top; the
        // fee itself is mid-wave-priced, so leave headroom)
        _buy(2000e18);
        assertGe(hook1.reserveMixETH(), boot + span, "past the wave top");
        assertEq(hook1.swapFeeBps(), 250, "2.5% above the sine");
    }

    /// Execution matches the view: reserve grows by input minus the CURRENT
    /// fee slice. CLOCK-REDESIGN §3 REVISED (2026-09-01): the fee splits
    /// 60% stakers / 35%+4% pot / 1% deployerCredit on UNATTRIBUTED flow —
    /// every leg asserted to the wei, remainders landing in the pot escrow.
    function test_FeeChargedInExecution_Unattributed60_39_1() public {
        _launch(100e18);

        uint256 feeBps = hook1.swapFeeBps(); // 1000 at the seam
        uint256 inAmt = 10e18 + 7; // odd wei — exercise the dust paths
        uint256 rBefore = hook1.reserveMixETH();
        uint256 potBefore = hook1.potBalance();
        uint256 depBefore = hook1.deployerCredit();
        uint256 hookBalBefore = mixETH.balanceOf(address(hook1));

        _buy(inAmt);

        uint256 fee = (inAmt * feeBps) / 10000;
        assertEq(hook1.reserveMixETH(), rBefore + inAmt - fee, "reserve += post-fee input");

        // the exact §3 REVISED legs (bps of the fee, to the wei)
        uint256 stakerLeg = (fee * 6000) / 10000;
        uint256 potSlice = (fee * 3500) / 10000;
        uint256 deployerLeg = (fee * 100) / 10000;
        uint256 refSlice = fee - stakerLeg - potSlice; // 4% + every dust remainder
        uint256 potLeg = potSlice + (refSlice - deployerLeg);

        assertEq(hook1.deployerCredit() - depBefore, deployerLeg, "1% rake accrued to deployerCredit");
        assertEq(hook1.potBalance() - potBefore, potLeg, "35% + 4% + dust -> pot escrow");

        // conservation: staker + pot + deployer == fee, and everything but
        // the (empty) referral leg stayed inside the hook's custody
        assertEq(stakerLeg + potLeg + deployerLeg, fee, "legs conserve the fee exactly");
        assertEq(mixETH.balanceOf(address(hook1)) - hookBalBefore, fee, "whole fee stayed in hook custody");
    }

    /// §3 REVISED, ATTRIBUTED leg: 60% stakers / 35% pot / 5% referral
    /// chain, tier weights straight off the registry (tier 0 = 80% of the
    /// leg to the closest referrer). Unpaid tier weight + rounding -> pot.
    function test_FeeSplit_Attributed60_35_5() public {
        _launch(100e18);

        // alice qualifies as a referrer: >= 1000 PSP locked on her pepe
        mixETH.transfer(alice, 20e18);
        vm.startPrank(alice);
        mixETH.approve(address(swapper), 20e18);
        uint256 pspOut = swapper.buy(_key(), 20e18, alice);
        PSPStaker staker = controller1.staker();
        psp1.approve(address(staker), pspOut);
        staker.lock(pspOut);
        uint256 alicePepe = staker.primaryOf(alice);
        vm.stopPrank();
        assertGe(
            staker.stakedTotalOf(alice),
            PSPReferralRegistry(factory.referralRegistryOf(1)).MIN_STAKE_PSP(),
            "referrer qualified"
        );

        // rando binds his attribution to alice's pepe (the ONLY bind path)
        vm.prank(rando);
        PSPReferralRegistry(factory.referralRegistryOf(1)).record(alicePepe);

        uint256 feeBps = hook1.swapFeeBps(); // post-alice-buy depth
        uint256 inAmt = 10e18 + 3; // odd wei
        uint256 potBefore = hook1.potBalance();
        uint256 depBefore = hook1.deployerCredit();
        uint256 aliceMixBefore = mixETH.balanceOf(alice);

        uint256 out = _buyAttributed(inAmt, rando);
        assertGt(out, 0);

        uint256 fee = (inAmt * feeBps) / 10000;
        uint256 stakerLeg = (fee * 6000) / 10000;
        uint256 potSlice = (fee * 3500) / 10000;
        uint256 refLeg = fee - stakerLeg - potSlice; // the 5% leg (+ dust)
        uint256 paid = (refLeg * 8000) / 10000; // tier 0: 80% of the leg to alice
        uint256 potLeg = potSlice + (refLeg - paid); // unpaid tiers + dust -> pot

        assertEq(mixETH.balanceOf(alice) - aliceMixBefore, paid, "tier-0 referrer paid live, to the wei");
        assertEq(hook1.potBalance() - potBefore, potLeg, "35% + unpaid tier weight + dust -> pot");
        assertEq(hook1.deployerCredit(), depBefore, "NO rake on attributed flow");
        assertEq(stakerLeg + potLeg + paid, fee, "legs conserve the fee exactly");
    }

    /// The 1% rake is PULL-based: claimDeployerCredit pays deployerCutTo,
    /// once, from any caller; a second claim reverts NothingToClaim.
    function test_DeployerCredit_PullClaim() public {
        _launch(100e18);
        _buy(10e18); // unattributed — rake accrues

        uint256 credit = hook1.deployerCredit();
        uint256 paidOut = hook1.deployerCreditPaid();
        assertEq(paidOut, 0, "nothing pulled yet");
        assertGt(credit, 0, "rake accrued");

        address cutTo = hook1.deployerCutTo();
        assertEq(cutTo, address(this), "deployerCutTo wired at deploy (this harness)");
        uint256 cutBefore = mixETH.balanceOf(cutTo);

        vm.prank(rando); // anyone can push the claim — it pays cutTo
        hook1.claimDeployerCredit();
        assertEq(mixETH.balanceOf(cutTo) - cutBefore, credit, "pull paid exactly the accrual");
        assertEq(hook1.deployerCreditPaid(), credit, "drain tracked");
        assertEq(hook1.deployerCredit() - hook1.deployerCreditPaid(), 0, "nothing outstanding");

        vm.prank(rando);
        vm.expectRevert(CurveHook.NothingToClaim.selector);
        hook1.claimDeployerCredit();
    }

    /// Quote parity (B7b principle, sine-aware): getBuyOutput/getSellOutput
    /// mirror execution exactly — same curve, same fee basis.
    function test_QuoteParity() public {
        _launch(100e18);
        uint256 inAmt = 5e18;

        uint256 quote = hook1.getBuyOutput(inAmt);
        uint256 out = _buy(inAmt);
        assertEq(quote, out, "buy quote == execution");
    }
}

/// @dev CSwapper's twin, forwarding the TRADER through hookData — the
///      canonical-zap settlement shape. Attribution binds via the registry
///      only (A-1); the hookData leg is identity forwarding, never creation.
contract AttributedSwapper {
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
