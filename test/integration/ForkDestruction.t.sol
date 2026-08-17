// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

import {MainnetConfig} from "./MainnetConfig.sol";
import {V4IntegrationTest} from "./V4Integration.t.sol";

/// @title ForkDestructionTest
/// @notice Tests the full destruction lifecycle on fork:
///         predeposit -> launch -> lock -> govern -> destroy -> carry to next round
///
/// Run: forge test --match-contract ForkDestructionTest --fork-url $MAINNET_RPC_URL -vvv
contract ForkDestructionTest is V4IntegrationTest {

    function test_Fork_FullDestructionLifecycle() public {
        // Phase 1: Predeposit
        vm.startPrank(alice);
        mixETH.approve(address(controller), 200e18);
        controller.predeposit(200e18);
        vm.stopPrank();

        vm.startPrank(bob);
        mixETH.approve(address(controller), 200e18);
        controller.predeposit(200e18);
        vm.stopPrank();

        // Phase 2: Launch
        vm.prank(address(factory));
        controller.launchPooledBuy();

        // Phase 3: Claim (auto-locks)
        vm.prank(alice);
        controller.claimPredepositPSP();

        vm.prank(bob);
        controller.claimPredepositPSP();

        // Phase 4: Governance — propose + vote
        // M-1: locks must predate the proposal timestamp
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        controller.proposeCarpetBomb();

        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);

        // Phase 5: Warp past voting period
        skip(3 days + 1);

        // Phase 6: Execute destruction — carry forwards into spawned round 2
        controller.carpetBomb();
        skip(3 days + 1);
        controller.finalizeCarpet();

        assertTrue(factory.currentRoundId() == 2, "Round 2 spawned");
        uint256 seeded = mixETH.balanceOf(address(factory.getRound(2).controller));
        assertTrue(seeded > 0, "Carry seeded into round 2");
        assertEq(mixETH.balanceOf(address(factory)), 0, "Factory emptied");

        (,,,, bool executed,) = controller.getCarpetBombState();
        assertTrue(executed, "Destruction executed");

        // Phase 7: Hook mode is Destroyed
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Destroyed), "Hook destroyed");

        // Phase 8: Can't swap on destroyed hook
        // Must approve first, then expectRevert right before the swap call
        vm.startPrank(alice);
        mixETH.approve(address(router), 1e18);
        SwapParams memory destroyParams = SwapParams({
            amountSpecified: -int256(1e18),
            sqrtPriceLimitX96: _isMixETHCurrency0() ? _minPrice() : _maxPrice(),
            zeroForOne: _isMixETHCurrency0()
        });
        vm.expectRevert(); // V4 wraps hook reverts as WrappedError
        router.swap(poolKey, destroyParams);
        vm.stopPrank();

        console.log("mixETH seeded to round 2 predeposit:", seeded);
    }

    function test_Fork_CarryToNextRound() public {
        // Run destruction first (reuse the full lifecycle)
        vm.startPrank(alice);
        mixETH.approve(address(controller), 200e18);
        controller.predeposit(200e18);
        vm.stopPrank();

        vm.startPrank(bob);
        mixETH.approve(address(controller), 200e18);
        controller.predeposit(200e18);
        vm.stopPrank();

        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();
        vm.prank(bob);
        controller.claimPredepositPSP();

        // M-1: locks must predate the proposal timestamp
        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);

        vm.prank(bob);
        controller.voteCarpetBomb(true);

        skip(3 days + 1);
        controller.carpetBomb();
        skip(3 days + 1);
        controller.finalizeCarpet();

        // carpetBomb birthed round 2 and seeded it with the entire carry
        assertEq(factory.currentRoundId(), 2, "round 2 spawned");
        PSPFactory.Round memory r2 = factory.getRound(2);
        uint256 seeded = mixETH.balanceOf(address(r2.controller));
        assertGt(seeded, 0, "carry seeded into round 2 predeposit");
        assertEq(mixETH.balanceOf(address(factory)), 0, "factory emptied");

        console.log("Funds carried:", seeded);
    }
}
