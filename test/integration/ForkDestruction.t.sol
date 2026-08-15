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
        vm.warp(block.timestamp + 3 days + 1);

        // Phase 6: Execute destruction
        uint256 factoryMixBefore = mixETH.balanceOf(address(factory));
        controller.carpetBomb();
        uint256 factoryMixAfter = mixETH.balanceOf(address(factory));

        assertTrue(factoryMixAfter > factoryMixBefore, "Factory received carried mixETH");

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

        console.log("mixETH carried to factory:", factoryMixAfter - factoryMixBefore);
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

        vm.warp(block.timestamp + 3 days + 1);
        controller.carpetBomb();

        // Now carry to next round
        uint256 roundId = factory.currentRoundId();
        uint256 factoryBefore = mixETH.balanceOf(address(factory));
        uint256 ownerBefore = mixETH.balanceOf(address(this));

        factory.carryToNextRound(roundId);

        uint256 ownerAfter = mixETH.balanceOf(address(this));
        assertGe(ownerAfter, ownerBefore, "Owner received carried funds");

        console.log("Funds carried:", ownerAfter - ownerBefore);
    }
}
