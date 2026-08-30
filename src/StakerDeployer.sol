// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRoundController} from "./interfaces/IRoundController.sol";
import {PSPStaker} from "./PSPStaker.sol";

/// @title StakerDeployer — deploys the per-round PSPStaker
/// @notice EIP-170 companion vessel (same family as HookDeployer /
///         ControllerDeployer / TokenDeployer): RoundController used to
///         `new PSPStaker(...)` in its constructor, embedding ~7.4KB of
///         staker creation code inside RoundController's creation program,
///         which itself rides inside ControllerDeployer — and lockWithPepe
///         (the chosen-art path, 2026-08-23) pushed that stack past the
///         24,000-byte internal budget. PSPStaker's creation code lives
///         HERE now. Pure vessel: args pass straight through, nothing is
///         verified beyond deploy success.
contract StakerDeployer {
    error DeployFailed();

    function deployStaker(
        IERC20 psp,
        IRoundController controller,
        address descriptor
    ) external returns (PSPStaker staker) {
        staker = new PSPStaker(psp, controller, descriptor);
        if (address(staker) == address(0)) revert DeployFailed();
    }

    // ─────────────── staged spawn (2026-08-30) ───────────────
    // Salted CREATE2 + prediction so the factory can know every round
    // contract's address BEFORE deploying any of them. The controller
    // derives its staker salt from its own (create2-predicted) address,
    // keeping the whole round's address set computable from one root.

    /// @dev CREATE2 variant. Occupied-address create2 reverts; callers
    ///      probe `predictStaker(...).code.length` first (idempotent birth).
    function deployStakerAt(
        bytes32 salt,
        IERC20 psp,
        IRoundController controller,
        address descriptor
    ) external returns (PSPStaker staker) {
        staker = new PSPStaker{salt: salt}(psp, controller, descriptor);
    }

    /// @dev Pure create2 address prediction — must be called on the SAME
    ///      deployer instance that will run deployStakerAt.
    function predictStaker(
        bytes32 salt,
        IERC20 psp,
        IRoundController controller,
        address descriptor
    ) external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(abi.encodePacked(
                type(PSPStaker).creationCode,
                abi.encode(psp, controller, descriptor)
            ))
        )))));
    }
}
