// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {CurveHook} from "./CurveHook.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {IRoundController} from "./interfaces/IRoundController.sol";
import {PSPReferralRegistry} from "./PSPReferralRegistry.sol";

/// @title HookDeployer — mines and CREATE2-deploys CurveHook instances
/// @notice Exists purely for EIP-170: the factory embedded CurveHook's ~11KB
///         creation code TWICE (once as the `type(CurveHook).creationCode`
///         literal for mining, once inside the `new CurveHook{salt}`
///         expression) on top of RoundController's and PSPToken's creation
///         code — 41KB runtime, well past the 24,576-byte deploy limit.
///         Outsourcing the hook deploy drops the factory back under budget;
///         this contract holds the literal exactly once.
///
///         Staged spawn (2026-08-30): the rebirth loop's gas lottery — a
///         14-bit flag match is geometric (median ~2^13 iterations, observed
///         tail past 60k), so an in-deploy mine could push a one-tx spawn
///         past any per-tx cap — is split across the pair mineHook (view,
///         bounded, called in the deposit-free reserve) and deployHookAt
///         (deterministic, called in the birth). The legacy one-shot
///         mine-and-deploy was deleted for EIP-170 headroom; its
///         permissionless reach is fully preserved by the pair.
contract HookDeployer {
    error DeployFailed();

    /// @dev Single initCode construction shared by mineHook and deployHookAt
    ///      — EIP-170: one encoder, one creation-code reference.
    ///      deployerCutTo (CLOCK-REDESIGN §3): the 1% unattributed-fee rake
    ///      recipient, immutable on every hook the factory births.
    function _hookInitCode(
        IPoolManager pm,
        address controller,
        address referralRegistry,
        CurveMath.CurveConfig calldata config,
        address deployerCutTo
    ) internal view returns (bytes memory) {
        return bytes.concat(
            type(CurveHook).creationCode,
            abi.encode(
                pm, IRoundController(controller), PSPReferralRegistry(referralRegistry), config, deployerCutTo
            )
        );
    }

    /// @dev Flag set every round's hook must carry. L-2: BEFORE_INITIALIZE
    ///      gates pool initialization to the canonical {mixETH, PSP} pair.
    function _hookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
    }

    /// @dev Entropy domain separator for the salt space — keyed to block
    ///      context + the controller address (C-1, fork-verified 2026-08-18:
    ///      salt candidates must be unknowable before the block that runs
    ///      the mine, or an orphan pre-squat can collide the spawn's create2
    ///      forever).
    function _entropy(address controller) internal view returns (bytes32) {
        return keccak256(abi.encode(block.prevrandao, block.timestamp, block.number, controller));
    }

    /// @dev Bounded flag-mine. Pure view: computes the candidate sequence
    ///      for THIS block's entropy, skips squatted candidates, and reverts
    ///      with MiningExhausted after `maxIter` total candidates scanned so
    ///      the reserve tx bounces CHEAP — no deposits exist at reserve
    ///      time. The next block's entropy re-rolls the salt space.
    error MiningExhausted();

    function mineHook(
        IPoolManager pm,
        address controller,
        address referralRegistry,
        CurveMath.CurveConfig calldata config,
        address deployerCutTo,
        uint256 maxIter
    ) external view returns (address hookAddr, bytes32 salt) {
        bytes memory initCode = _hookInitCode(pm, controller, referralRegistry, config, deployerCutTo);
        bytes32 entropy = _entropy(controller);

        uint256 scanFrom;
        uint256 scanned;
        while (true) {
            uint256 budget = maxIter - scanned;
            if (budget == 0) revert MiningExhausted(); // cap=0 would underflow the lap bound
            (address cand, bytes32 s, uint256 nextFrom) = HookMiner.nextCandidateCapped(
                address(this), entropy, _hookFlags(), initCode, "", scanFrom, budget
            );
            scanned += nextFrom - scanFrom;
            scanFrom = nextFrom;
            if (cand.code.length == 0) return (cand, s);
            // squatted (identical initcode+salt+deployer or a 160-bit
            // preimage collision): fall through to the next candidate
            if (scanned >= maxIter) revert MiningExhausted();
        }
    }

    /// @dev Deploy the hook at an already-mined salt. Verifies the create2
    ///      address equals the prediction before returning; an occupied
    ///      prediction returns as-is (idempotent — occupancy by anything but
    ///      the identical contract is a 160-bit preimage break).
    function deployHookAt(
        bytes32 salt,
        IPoolManager pm,
        address controller,
        address referralRegistry,
        CurveMath.CurveConfig calldata config,
        address deployerCutTo
    ) external returns (address hookAddr) {
        bytes memory initCode = _hookInitCode(pm, controller, referralRegistry, config, deployerCutTo);
        address expected = HookMiner.computeAddress(address(this), uint256(salt), initCode);
        if (expected.code.length > 0) return expected; // already born, identically
        assembly ("memory-safe") {
            hookAddr := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (hookAddr != expected) revert DeployFailed();
    }
}
