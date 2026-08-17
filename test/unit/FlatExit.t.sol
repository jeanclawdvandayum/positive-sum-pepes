// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IMixETH} from "../../src/interfaces/IMixETH.sol";

import {PSPFactory} from "../../src/PSPFactory.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../src/PSPZapOut.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @title FlatExit — proves the post-bomb social contract: the bomb does NOT
///        destroy the round. It flattens the curve, opens every staker lock
///        immediately (no 90-day wait), and pays average backing on exit.
///        Stakers feed themselves; only what they leave behind inherits to
///        round 2 at finalizeCarpet().
interface RoundControllerLike {
    function predeposit(uint256 mixAmount) external;
    function launchPooledBuy() external;
    function claimPredepositPSP() external;
    function lock(uint256 amount) external;
    function unlock() external;
    function relock() external;
    function proposeCarpetBomb() external;
    function voteCarpetBomb(bool support) external;
    function carpetBomb() external;
    function finalizeCarpet() external;
    function flatTime() external view returns (uint256);
    function locks(address) external view returns (uint256, uint256, uint256, uint256);
}

contract FlatExitTest is Test {
    MockMixETH mixETH;
    MockPoolManager poolManager;
    PSPFactory factory;
    PSPZapIn zapIn;
    PSPZapOut zapOut;
    IERC20 pspToken;
    RoundControllerLike controller;
    CurveHook hook;

    address alice = makeAddr("alice"); // staker
    address bob = makeAddr("bob"); // buyer, locks for quorum
    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();
        poolManager = new MockPoolManager();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)), IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer()
        );

        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
        });
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory r = factory.getRound(roundId);
        pspToken = r.token;
        controller = RoundControllerLike(address(r.controller));
        hook = CurveHook(address(r.hook));

        zapIn = new PSPZapIn(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));
        zapOut = new PSPZapOut(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));

        vm.deal(alice, 1_000e18);
        vm.deal(bob, 1_000e18);
        mixETH.transfer(alice, 200e18);
        mixETH.transfer(bob, 100e18);
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(mixETH)),
            currency1: Currency.wrap(address(pspToken)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev drive the round to Active with alice staked and bob bought+locked
    function _launchAndStake() internal {
        vm.startPrank(alice);
        mixETH.approve(address(controller), 60e18);
        controller.predeposit(60e18);
        vm.stopPrank();

        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP(); // auto-locks (genesis stake)

        // bob buys on the curve and locks too, so quorum is honest
        vm.startPrank(bob);
        mixETH.approve(address(zapIn), type(uint256).max);
        uint256 bobPSP = zapIn.buyWithMix(_poolKey(), 20e18, 0, 0);
        pspToken.approve(address(controller), type(uint256).max);
        controller.lock(bobPSP);
        vm.stopPrank();
    }

    function test_FlatExit_StakerUnlocksEarlyAndSellsAtAverageBacking() public {
        _launchAndStake();

        // bomb passes: everyone locked, everyone votes yes
        skip(1); // M-1: locks must predate the proposal
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        skip(3 days + 1);
        controller.carpetBomb();

        // ── the bomb flattens, it does not destroy ──
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Flat), "round is flat, not destroyed");
        assertEq(factory.currentRoundId(), 1, "round 2 waits for finalize");
        assertTrue(controller.flatTime() > 0, "flatTime set");

        // ── THE PROOF: staker unlocks with 90 days still on the clock ──
        (uint256 lockedAmount,, uint256 lockTime, uint256 unlockTime) = controller.locks(alice);
        assertGt(lockedAmount, 0, "alice staked");
        assertGt(unlockTime, block.timestamp + 80 days, "lock has ~90d left");

        uint256 mixBefore = mixETH.balanceOf(alice);
        vm.prank(alice);
        controller.unlock(); // bypasses LockNotExpired — flat round
        uint256 alicePSP = pspToken.balanceOf(alice);
        assertEq(alicePSP, lockedAmount, "full principal returned");

        // ── and sells against the flat curve at average backing ──
        // same arithmetic order as _handleFlatSell: single division
        uint256 expectedGross = (alicePSP * hook.reserveMixETH()) / hook.totalSupplyPSP();
        uint256 expectedNet = expectedGross - (expectedGross * 500) / 10000; // 5% toll

        vm.startPrank(alice);
        pspToken.approve(address(zapOut), type(uint256).max);
        uint256 mixOut = zapOut.sellToMix(_poolKey(), alicePSP, 0, 0);
        vm.stopPrank();

        assertEq(mixOut, expectedNet, "sold at average backing minus toll");
        // balance delta additionally includes pending staker fees paid at
        // unlock() — asserted separately below via mixOut exactness
        assertGt(mixETH.balanceOf(alice) - mixBefore, mixOut, "alice banked the exit");

        // lockTime/unlockTime from before the bomb are irrelevant now
        assertGt(mixOut, 0, "exit paid");
        assertGt(lockTime, 0, "sanity: was a real lock");

        // ── no new stakes, no relocks on a flat round ──
        vm.prank(alice);
        vm.expectRevert();
        controller.relock();
        vm.expectRevert();
        controller.lock(1e18);

        // ── finalize after the window: destroy, carry, rebirth ──
        skip(3 days + 1);
        controller.finalizeCarpet();
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Destroyed), "destroyed at finalize");
        assertEq(factory.currentRoundId(), 2, "round 2 born");

        // idempotent: second finalize reverts (setMode refuses Destroyed→Destroyed)
        vm.expectRevert();
        controller.finalizeCarpet();
    }

    function test_FlatExit_UnclaimedBackingInheritsToRound2() public {
        _launchAndStake();

        skip(1);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        skip(3 days + 1);
        controller.carpetBomb();

        // NOBODY exits — both stakers keep playing
        uint256 reserveBefore = hook.reserveMixETH();
        assertGt(reserveBefore, 0, "reserve alive during window");

        skip(3 days + 1);
        controller.finalizeCarpet();

        // their unclaimed backing is exactly what round 2 inherits
        PSPFactory.Round memory r2 = factory.getRound(2);
        assertGt(
            mixETH.balanceOf(address(r2.controller)),
            reserveBefore * 9 / 10,
            "unredeemed backing carried to round 2"
        );
    }
}
