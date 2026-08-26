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
///      side of finding A-1. The swap itself settles honestly; the hookData
///      bytes naming (trader, refNft) are forged. Post-fix (2026-08-26) the
///      hook only honors 32-byte (trader) hints and NEVER records, so these
///      forged bytes are inert: they cannot create or consume attribution.
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
        // the swap itself is honest; the hookData is forged. Pre-fix, the
        // hook TRUSTED these bytes to lazily bind attribution; post-fix it
        // decodes only 32-byte (trader) hints and never records, so the
        // forged 64-byte payload is ignored wholesale.
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

/// @title PoisonedAttributionTest — regression proof for the forged-hookData
///        referral attribution attack (multi-agent audit 2026-08-23, A-1;
///        FIXED 2026-08-26).
///
///        Pre-fix vector: PSPReferralRegistry.recordFor was authorized-hook-only,
///        but the HOOK decoded (trader, referrerNftId) from V4 hookData — bytes
///        ANY direct poolManager.swap caller controls. A qualified attacker
///        swapping with hookData=(victim, attackerNft) consumed the victim's
///        one-time lazy attribution and rerouted every future carve-out.
///
///        Fix: attribution binds ONLY via the user-signed registry.record()
///        (msg.sender). The hook decodes a 32-byte trader hint purely for
///        payout continuation and never records; recordFor/setRecorder and
///        the whole authorized-recorder surface are deleted.
///
///        This test replays the exact pre-fix attack and asserts it is DEAD:
///        the forged swap binds nothing, the attacker earns nothing, and the
///        victim can still bind his intended referrer afterwards.
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

    function _buyViaZap(address user, uint256 mixAmount) internal returns (uint256) {
        vm.startPrank(user);
        mixETH.approve(address(zapIn), mixAmount);
        uint256 out = zapIn.buyWithMix(poolKey, mixAmount, 0, 0);
        vm.stopPrank();
        return out;
    }

    function _buyPlain(address user, uint256 mixAmount) internal returns (uint256) {
        return _buyViaZap(user, mixAmount);
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

    function test_PoC_ForgedHookDataCannotStealAttribution() public {
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
        //        (byte-identical to the pre-fix exploit: 64 forged bytes
        //        naming (victim, attackerNft))
        vm.startPrank(relayer);
        mixETH.approve(address(attacker), 5e18);
        attacker.attack(poolKey, 5e18, bob, malloryNft, IERC20(address(mixETH)));
        vm.stopPrank();

        // ── assert: hijack BLOCKED (A-1 fix 2026-08-26) ──
        assertFalse(registry.attributed(bob), "FIXED: forged hookData consumed nothing");
        (address[5] memory who,) = registry.payoutFor(bob);
        assertEq(who[0], address(0), "FIXED: no payout edge exists to the attacker");
        assertEq(mixETH.balanceOf(mallory), 800e18, "FIXED: attacker earned nothing from the forged swap");

        // bob's LEGIT attribution still works after the attack: he records
        // alice himself — the one-time slot was never consumed
        vm.prank(bob);
        registry.record(aliceNft);
        (who,) = registry.payoutFor(bob);
        assertEq(who[0], alice, "victim binds his INTENDED referrer after the attack");

        // and bob's subsequent trade pays alice's chain — never mallory's
        uint256 aliceBefore = mixETH.balanceOf(alice);
        uint256 bobBag = _buyPlain(bob, 10e18);
        assertGt(bobBag, 0);
        assertGt(mixETH.balanceOf(alice), aliceBefore, "tier-1 paid to the intended referrer");
        assertEq(mixETH.balanceOf(mallory), 800e18, "attacker never earns");

        console.log("A-1 regression: forged hookData is inert; victim binds intended referrer");
    }
}
