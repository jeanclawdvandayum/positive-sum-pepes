// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RealV4Base} from "./RealV4Lifecycle.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {IRoundController} from "../src/interfaces/IRoundController.sol";
import {StakerDeployer} from "../src/StakerDeployer.sol";

/// @title SkillLifecycleReviewTest
/// @notice Canonical staged birth must remain live between public transactions.
contract SkillLifecycleReviewTest is RealV4Base {
    function _reserve() private returns (address token, address ctl, address h) {
        // Settlement is covered separately; start at a destroyed registry entry.
        vm.prank(address(controller));
        factory.markDestroyed(1);
        factory.reserveSpawn(1);
        (,,,,,token,ctl,h,,,,,) = factory.reservation();
    }

    function test_EarlyCanonicalStakerDoesNotBlockBirth() public {
        (address token, address ctl,) = _reserve();
        bytes32 salt = keccak256(abi.encode(ctl, "psp-staker"));
        StakerDeployer vessel = factory.stakerDeployer();
        address art = factory.descriptor();
        vm.prank(alice);
        PSPStaker early = vessel.deployStakerAt(
            salt, IERC20(token), IRoundController(ctl), art
        );
        // The early object is canonical and cannot mint before its controller exists.
        vm.prank(alice);
        (bool mutated,) = address(early).call(abi.encodeCall(early.lock, (0)));
        assertFalse(mutated);
        for (uint256 i; i < 3; ++i) factory.birthStep{gas: 12_000_000}();
        assertEq(factory.currentRoundId(), 2);
        assertEq(factory.getRound(2).controller.stakerAddress(), address(early));
        assertEq(early.totalLocked(), 0);
        assertEq(early.balanceOf(alice), 0);
        // Idempotent reuse never substitutes a different descriptor or controller.
        assertEq(address(early.controller()), ctl);
        assertEq(address(early.psp()), token);
        assertEq(early.descriptor(), art);
    }

    function test_OnlyFactoryCanInitializeReservedPool() public {
        (address token,, address h) = _reserve();
        factory.birthStep{gas: 12_000_000}();
        factory.birthStep{gas: 12_000_000}();
        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(token);
        if (c0 > c1) (c0, c1) = (c1, c0);
        PoolKey memory key = PoolKey(c0, c1, 0x800000, 60, IHooks(h));
        vm.prank(alice);
        (bool initialized,) = address(poolManager).call(
            abi.encodeCall(poolManager.initialize, (key, uint160(79228162514264337593543950336)))
        );
        assertFalse(initialized, "a stranger cannot consume the reserved pool initialization");
        factory.birthStep{gas: 12_000_000}();
        assertEq(factory.currentRoundId(), 2);
        assertEq(address(factory.getRound(2).hook), h);
        assertFalse(factory.reservationActive());
    }
}
