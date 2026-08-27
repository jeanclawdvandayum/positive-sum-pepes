// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IMixETH} from "../../../../src/interfaces/IMixETH.sol";

import {PSPFactory} from "../../../../src/PSPFactory.sol";
import {HookDeployer} from "../../../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../../../src/ControllerDeployer.sol";
import {CurveMath} from "../../../../src/libraries/CurveMath.sol";
import {PSPZapIn} from "../../../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../../../src/PSPZapOut.sol";
import {RoundController} from "../../../../src/RoundController.sol";
import {PSPStaker} from "../../../../src/PSPStaker.sol";
import {MockMixETH} from "../../../mocks/MockMixETH.sol";
import {MockPoolManager} from "../../../mocks/MockPoolManager.sol";
import {console2} from "forge-std/console2.sol";
import {StakerDeployer} from "src/StakerDeployer.sol";


/// @title A4 — end-to-end against the REAL PSPFactory / CurveHook / zaps
///        (MockPoolManager executes the genuine v4 swap flow).
///        Proves F-2 (flat-window pot stranding) on the deployed system and
///        that the round-2 rebirth loop survives it.
contract A4_E2ETest is Test {
    MockMixETH mixETH;
    MockPoolManager poolManager;
    PSPFactory factory;
    PSPZapIn zapIn;
    PSPZapOut zapOut;
    IERC20 pspToken;
    RoundController controller;
    PSPStaker public stakerV; // cached: single vm.prank must not be eaten by the staker() view call
    address hook;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 200_000e18}();
        poolManager = new MockPoolManager();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)), IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer(), new StakerDeployer()
        , 0);

        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
        });
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory r = factory.getRound(roundId);
        pspToken = r.token;
        controller = r.controller;
        stakerV = controller.staker();
        hook = address(r.hook);

        zapIn = new PSPZapIn(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));
        zapOut = new PSPZapOut(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));

        vm.deal(alice, 1_000e18);
        vm.deal(bob, 1_000e18);
        mixETH.transfer(alice, 500e18);
        mixETH.transfer(bob, 500e18);
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(mixETH)),
            currency1: Currency.wrap(address(pspToken)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
    }

    function _launch() internal {
        vm.startPrank(alice);
        mixETH.approve(address(controller), 60e18);
        controller.predeposit(60e18);
        vm.stopPrank();

        vm.prank(address(factory)); // factory owns the controller mid-round
        controller.launchPooledBuy();
    }

    /// Full lifecycle: launch → curve trade → bomb → flat window →
    /// redeemed & ring-fenced at factory) → flat trades (F-9 fixed: zero
    /// fee, nothing accrues) → finalize (round 2 spawned; nothing stranded).
    function test_E2E_F9_flat_window_zero_fee_nothing_stranded() public {
        _launch();
        vm.prank(alice);
        controller.claimPredepositPSP();
        vm.warp(block.timestamp + 1); // lockTime strictly before proposeTime

        // ── curve-phase trade: bob buys, pot accrues ──
        vm.startPrank(bob);
        mixETH.approve(address(zapIn), 10e18);
        uint256 bobPSP = zapIn.buyWithMix(_poolKey(), 10e18, 0, 0);
        vm.stopPrank();
        // (2026-08-19) pot accrual removed — curve buys pay the 50bps
        // referral carve-out live (unattributed here → stakers)

        // ── governance: alice (sole locker) bombs ──
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.warp(block.timestamp + 3 days + 1);
        controller.carpetBomb();
        assertGt(controller.flatTime(), 0, "flat window open");

        // ── flat window: alice unlocks (flat bypass) and exits; bob buys ──
        vm.prank(alice);
        stakerV.unlock();
        uint256 alicePSP = pspToken.balanceOf(alice);
        assertGt(alicePSP, 0, "unlock should release principal");

        vm.startPrank(alice);
        pspToken.approve(address(zapOut), alicePSP / 2);
        uint256 mixOut = zapOut.sellToMix(_poolKey(), alicePSP / 2, 0, 0);
        vm.stopPrank();
        assertGt(mixOut, 0, "flat sell paid out");

        vm.startPrank(bob);
        mixETH.approve(address(zapIn), 5e18);
        zapIn.buyWithMix(_poolKey(), 5e18, 0, 0);
        vm.stopPrank();

        // F-9 FIXED (2026-08-19): zero-fee flat window — dying-round trades
        // accrue NOTHING. Pre-fix the pot seeded a stranded pot; the pot is
        // now gone entirely, so flat trades touch no fee path at all.
        assertEq(
            pspToken.balanceOf(address(controller)),
            stakerV.totalLocked(),
            "H-1 custody invariant (real stack, referral era)"
        );

        // ── finalize: 3-day flat window elapses ──
        vm.warp(controller.flatTime() + 3 days + 1);
        controller.finalizeCarpet();

        // round 2 spawned
        assertEq(factory.currentRoundId(), 2, "round 2 should exist");
        PSPFactory.Round memory r2 = factory.getRound(2);

        // v5.1 (2026-08-19): the pot is retired — the bomb-time reserve
        // carries as plain predeposit backing (whole-balance spawn).
        // Nothing stranded at the dead controller: no PSP sits there beyond
        // locker principal.
        assertEq(
            pspToken.balanceOf(address(controller)),
            stakerV.totalLocked(),
            "F-9 fixed: no orphaned PSP beyond locker principal"
        );

        // v5.1: referral graph is per-round — round 2 got a FRESH registry
        address reg1 = factory.referralRegistryOf(1);
        address reg2 = factory.referralRegistryOf(2);
        assertTrue(reg1 != address(0) && reg2 != address(0), "registries born");
        assertTrue(reg1 != reg2, "graph resets at round boundary");
        // unclaimed backing still carries into round 2 predeposit (by design)
        assertGt(r2.controller.totalPredepositMixETH(), 0, "carry seeded round 2");

        // no later exit: carpetBomb re-execution and PSP sweep both blocked
        vm.expectRevert(RoundController.AlreadyExecuted.selector);
        controller.carpetBomb();
        vm.prank(address(factory));
        vm.expectRevert(RoundController.ProtectedToken.selector);
        controller.sweep(address(pspToken));
    }

    /// The rebirth loop survives F-2: round 2 accepts predeposits, launches,
    /// and trades through the real zaps.
    function test_E2E_round2_rebirth_loop_alive() public {
        test_E2E_F9_flat_window_zero_fee_nothing_stranded();

        PSPFactory.Round memory r2 = factory.getRound(2);
        RoundController c2 = r2.controller;
        IERC20 psp2 = r2.token;

        vm.startPrank(alice);
        IERC20(address(mixETH)).approve(address(c2), 20e18);
        c2.predeposit(20e18);
        vm.stopPrank();
        vm.prank(address(factory));
        c2.launchPooledBuy();
        vm.prank(alice);
        c2.claimPredepositPSP();

        // trade round 2's PSP through the real zap path
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(mixETH)),
            currency1: Currency.wrap(address(psp2)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(r2.hook))
        });
        vm.startPrank(bob);
        IERC20(address(mixETH)).approve(address(zapIn), 3e18);
        uint256 out = zapIn.buyWithMix(key2, 3e18, 0, 0);
        vm.stopPrank();
        assertGt(out, 0, "round 2 trades fine");
    }
}
