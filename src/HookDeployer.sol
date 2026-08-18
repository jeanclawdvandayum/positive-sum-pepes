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

    /// @dev C-1 remediation: how many mined salt candidates deployHook will
    ///      fall through before giving up. Each squatted candidate costs the
    ///      spawn one extra ~2^14 mining pass (~2-3M gas); 4 candidates cap
    ///      the worst-case mining at ~11M so a fully squatted block still
    ///      reverts well inside mainnet gas. Sustaining a block requires
    ///      occupying every candidate in the same block (same entropy), then
    ///      re-squatting in every subsequent retry block — unbounded grief
    ///      cost against a one-tx defense.
    uint256 public constant MAX_SALT_CANDIDATES = 4;

    /// @dev Permissionless by design: an orphan CurveHook is inert — the
    ///      factory only ever trusts hooks it wired into a round itself.
    ///      Returns (hookAddress, salt) so callers can verify the deployed
    ///      address matches a candidate the caller derived from the same
    ///      block context.
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

        // C-1 (2026-08-18, fork-verified HIGH): the legacy deterministic scan
        // (salt 0,1,2,...) made every future hook address computable from
        // public state — vessel nonce -> controller address -> first salt —
        // so an orphan deployed at the predicted address collided the create2
        // and bricked finalizeCarpet forever. Salt candidates are now keyed
        // to block context: unknowable before the block that runs the spawn,
        // so pre-squatting is impossible and same-block front-runs must hit
        // every candidate to matter.
        bytes32 entropy =
            keccak256(abi.encode(block.prevrandao, block.timestamp, block.number, controller));

        // Probe-then-create2 is race-free inside one atomic call: nothing can
        // deploy between the extcodesize probe and the create2. Each squatted
        // candidate costs one cold probe plus one resumed mining pass.
        uint256 scanFrom;
        for (uint256 k; k < MAX_SALT_CANDIDATES; k++) {
            (address cand, bytes32 s, uint256 next) =
                HookMiner.nextCandidate(address(this), entropy, flags, initCode, "", scanFrom);
            scanFrom = next;
            if (cand.code.length > 0) continue; // squatted: fall through
            assembly ("memory-safe") {
                hookAddr := create2(0, add(initCode, 0x20), mload(initCode), s)
            }
            if (hookAddr != cand) {
                // defense-in-depth: an intra-call collision is impossible
                // after the probe; guard the create2 result regardless
                hookAddr = address(0);
                continue;
            }
            salt = s;
            return (hookAddr, salt);
        }
        revert DeployFailed();
    }
}
