// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {PSPToken} from "../../../src/PSPToken.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {PSPStaker} from "../../../src/PSPStaker.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {PSPFactory} from "../../../src/PSPFactory.sol";
import {HookDeployer} from "../../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../../src/ControllerDeployer.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";

import {MainnetConfig} from "../../integration/MainnetConfig.sol";
import {V4SwapRouter} from "../../integration/V4SwapRouter.sol";
import {MockMixETH} from "../../mocks/MockMixETH.sol";
import {StakerDeployer} from "src/StakerDeployer.sol";


/// @title LockMechanicsTest
/// @notice Dedicated tests for vlCVX-style lock/unlock/relock mechanics.
contract LockMechanicsTest is Test {
    IPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;
    V4SwapRouter public router;

    PSPToken pspToken;
    RoundController controller;
    PSPStaker public stakerV; // cached: single vm.prank must not be eaten by the staker() view call
    CurveHook hook;
    PoolKey poolKey;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        poolManager = IPoolManager(MainnetConfig.POOL_MANAGER);
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();

        factory = new PSPFactory(poolManager, IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer(), new StakerDeployer(), 0);
        router = new V4SwapRouter(poolManager);

        mixETH.transfer(alice, 1_000e18);
        mixETH.transfer(bob, 1_000e18);

        _deployRound();
    }

    // ══════════════════════════════════════════════════════════════
    //  LOCK 1: Predeposit claim auto-locks with correct unlock time
    // ══════════════════════════════════════════════════════════════

    function test_Lock_PredepositAutoLocks() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();

        uint256 amount = stakerV.lockedPSPOf(alice);
        (,, uint256 lockTime, ) = stakerV.positions(alice);
        (,, , uint256 unlockTime) = stakerV.positions(alice);
        assertGt(amount, 0, "PSP locked");
        assertEq(pspToken.balanceOf(alice), 0, "No free PSP");
        assertGt(unlockTime, block.timestamp, "Unlock in future");
        assertEq(unlockTime - lockTime, 90 days, "90 day lock");
        assertEq(stakerV.totalLocked(), amount, "Total locked");
    }

    // ══════════════════════════════════════════════════════════════
    //  LOCK 2: Cannot unlock before expiry
    // ══════════════════════════════════════════════════════════════

    function test_Lock_CannotUnlockBeforeExpiry() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();

        // Try to unlock immediately
        vm.prank(alice);
        vm.expectRevert(PSPStaker.LockNotExpired.selector);
        stakerV.unlock();
    }

    // ══════════════════════════════════════════════════════════════
    //  LOCK 3: Can unlock after expiry
    // ══════════════════════════════════════════════════════════════

    function test_Lock_CanUnlockAfterExpiry() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();
        uint256 lockedAmount = stakerV.lockedPSPOf(alice);

        // Warp past expiry
        skip(90 days + 1);

        vm.prank(alice);
        stakerV.unlock();

        assertEq(pspToken.balanceOf(alice), lockedAmount, "Got PSP back");
        assertEq(stakerV.totalLocked(), 0, "Nothing locked");
        uint256 amountAfter = stakerV.lockedPSPOf(alice);
        assertEq(amountAfter, 0, "Lock cleared");
    }

    // ══════════════════════════════════════════════════════════════
    //  LOCK 4: Cannot relock too early
    // ══════════════════════════════════════════════════════════════

    function test_Lock_CannotRelockTooEarly() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();

        // Warp to day 80 (inside lock, outside relock window)
        skip(80 days);

        vm.prank(alice);
        vm.expectRevert(PSPStaker.TooEarlyToRelock.selector);
        stakerV.relock();
    }

    // ══════════════════════════════════════════════════════════════
    //  LOCK 5: Can relock in the last week
    // ══════════════════════════════════════════════════════════════

    function test_Lock_CanRelockInLastWeek() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();
        (,, , uint256 unlockBefore) = stakerV.positions(alice);

        // Warp to day 85 (inside relock window: last 7 days)
        skip(85 days);

        vm.prank(alice);
        stakerV.relock();

        (,, , uint256 unlockAfter) = stakerV.positions(alice);
        assertGt(unlockAfter, unlockBefore, "Unlock extended");
        assertEq(unlockAfter - block.timestamp, 90 days, "Extended by 90 days from now");
    }

    // ══════════════════════════════════════════════════════════════
    //  LOCK 6: Swap-bought PSP can be locked separately
    // ══════════════════════════════════════════════════════════════

    function test_Lock_SwapBoughtPSPCanLock() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        vm.prank(alice);
        controller.claimPredepositPSP(); // auto-locks

        // Bob buys via swap (gets free PSP)
        _buy(bob, 50e18);
        uint256 bobPSP = pspToken.balanceOf(bob);
        assertGt(bobPSP, 0, "Bob has free PSP");

        // Bob locks his swap-bought PSP
        vm.startPrank(bob);
        pspToken.approve(address(stakerV), bobPSP);
        stakerV.lock(bobPSP);
        vm.stopPrank();

        uint256 bobLocked = stakerV.lockedPSPOf(bob);
        (,, , uint256 bobUnlock) = stakerV.positions(bob);
        assertEq(bobLocked, bobPSP, "Bob locked all swap PSP");
        assertEq(bobUnlock, block.timestamp + 90 days, "90 day lock");
        assertEq(pspToken.balanceOf(bob), 0, "Bob has no free PSP");
    }

    // ══════════════════════════════════════════════════════════════
    //  LOCK 7: Unlock + re-lock cycle
    // ══════════════════════════════════════════════════════════════

    function test_Lock_UnlockRelockCycle() public {
        _predeposit(alice, 100e18);
        _predeposit(bob, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();
        vm.prank(bob);
        controller.claimPredepositPSP();

        skip(90 days + 1);

        // Alice unlocks
        vm.prank(alice);
        stakerV.unlock();
        uint256 alicePSP = pspToken.balanceOf(alice);
        assertGt(alicePSP, 0, "Alice unlocked");

        // Alice can re-lock (fresh 90 day lock)
        vm.startPrank(alice);
        pspToken.approve(address(stakerV), alicePSP);
        stakerV.lock(alicePSP);
        vm.stopPrank();

        uint256 aliceLocked = stakerV.lockedPSPOf(alice);
        (,, , uint256 aliceUnlock) = stakerV.positions(alice);
        assertEq(aliceLocked, alicePSP, "Alice re-locked");
        assertEq(aliceUnlock, block.timestamp + 90 days, "New 90 day lock");
    }

    // ══════════════════════════════════════════════════════════════
    //  LOCK 8: Expired lock still earns fees until withdrawn
    // ══════════════════════════════════════════════════════════════

    function test_Lock_ExpiredEarnsUntilWithdrawn() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();

        // Warp past expiry but DON'T unlock
        skip(90 days + 1);

        // Bob buys (generates fees)
        _buy(bob, 50e18);

        // Alice can still claim fees even though lock expired
        // (she hasn't called unlock yet — still counts as locked)
        uint256 aliceBefore = mixETH.balanceOf(alice);
        vm.prank(alice);
        stakerV.claimFees();
        uint256 earned = mixETH.balanceOf(alice) - aliceBefore;

        assertGt(earned, 0, "Alice earned fees after expiry (not yet unlocked)");
    }

    // ══════════════════════════════════════════════════════════════
    //  LOCK 9: Multiple relock cycles (vlCVX-style continuous locking)
    // ══════════════════════════════════════════════════════════════

    function test_Lock_ContinuousRelocking() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();

        // Simulate 4 quarters of continuous relocking
        for (uint256 i = 0; i < 4; i++) {
            // Warp to relock window (85 days from last lock)
            skip(85 days);

            uint256 loopAmount = stakerV.lockedPSPOf(alice);
            assertGt(loopAmount, 0, "Still locked");

            vm.prank(alice);
            stakerV.relock();

            (,, , uint256 unlockTime) = stakerV.positions(alice);
            assertEq(unlockTime - block.timestamp, 90 days, "Extended 90 days");
        }

        // After ~340 days of continuous locking, alice is still locked
        uint256 amount = stakerV.lockedPSPOf(alice);
        assertGt(amount, 0, "Still locked after 4 quarters");
        assertEq(pspToken.balanceOf(alice), 0, "No free PSP");
    }

    // ══════════════════════════════════════════════════════════════
    //  HELPERS
    // ══════════════════════════════════════════════════════════════

    function _deployRound() internal {
        CurveMath.CurveConfig memory config = CurveMath.singleCurve(
            0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18
        );

        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "PSP", symbol: "PSP", curveConfig: config
        });

        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory round = factory.getRound(roundId);
        pspToken = round.token;
        controller = round.controller;
        stakerV = controller.staker();
        hook = round.hook;

        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(address(pspToken));
        if (c0 > c1) (c0, c1) = (c1, c0);

        poolKey = PoolKey({
            currency0: c0, currency1: c1,
            fee: 0x800000, tickSpacing: 60, hooks: hook
        });
    }

    function _predeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        mixETH.approve(address(controller), amount);
        controller.predeposit(amount);
        vm.stopPrank();
    }

    function _buy(address user, uint256 mixETHAmount) internal {
        vm.startPrank(user);
        mixETH.approve(address(router), mixETHAmount);
        bool zeroForOne = Currency.wrap(address(mixETH)) < Currency.wrap(address(pspToken));
        SwapParams memory params = SwapParams({
            amountSpecified: -int256(mixETHAmount),
            sqrtPriceLimitX96: zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341,
            zeroForOne: zeroForOne
        });
        router.swap(poolKey, params);
        vm.stopPrank();
    }

    receive() external payable {}
}
