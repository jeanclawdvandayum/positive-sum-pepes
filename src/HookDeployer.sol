// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {CurveHook} from "./CurveHook.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @title HookDeployer — mines and CREATE2-deploys CurveHook instances
/// @notice Exists purely for EIP-170: the factory embedded CurveHook's ~11KB
///         creation code TWICE (once as the `type(CurveHook).creationCode`
///         literal for mining, once inside the `new CurveHook{salt}`
///         expression) on top of RoundController's and PSPToken's creation
///         code — 41KB runtime, well past the 24,576-byte deploy limit.
///         Outsourcing the hook deploy drops the factory back under budget;
///         this contract holds the literal exactly once (mined and deployed
///         from the same `initCode` bytes).
contract HookDeployer {
    error DeployFailed();

    /// @dev Permissionless by design: an orphan CurveHook is inert — the
    ///      factory only ever trusts hooks it wired into a round itself.
    ///      Returns (hookAddress, salt) so callers can verify determinism.
    function deployHook(
        IPoolManager pm,
        address controller,
        CurveMath.CurveConfig memory config
    ) external returns (address hookAddr, bytes32 salt) {
        // L-2: BEFORE_INITIALIZE_FLAG gates pool initialization to the
        // canonical {mixETH, PSP} pair (see CurveHook._beforeInitialize).
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        // Single embedding of the creation code — reused for mining AND deploy
        bytes memory initCode = bytes.concat(
            type(CurveHook).creationCode,
            abi.encode(pm, controller, config)
        );

        // find() packs (creationCode, args) internally; passing (initCode, "")
        // hashes exactly the bytes we deploy with
        (address expected, bytes32 s) = HookMiner.find(address(this), flags, initCode, "");
        salt = s;

        assembly ("memory-safe") {
            hookAddr := create2(0, add(initCode, 0x20), mload(initCode), s)
        }
        if (hookAddr != expected) revert DeployFailed();
    }
}
