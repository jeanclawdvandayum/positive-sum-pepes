// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {CurveHook} from "./CurveHook.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {IRoundController} from "./interfaces/IRoundController.sol";
import {PSPReferralRegistry} from "./PSPReferralRegistry.sol";

/// @title HookInitCode — the single on-chain home of CurveHook's creation code
/// @notice EIP-170 vessel arithmetic (2026-09-01): HookDeployer's runtime
///         embedded `type(CurveHook).creationCode` (~23.3KB) plus the mining
///         and deploy machinery — the CLOCK-REDESIGN clock/ladder/pot
///         additions grew CurveHook past the point where the literal plus
///         ~2KB of machinery fit under the 24,576-byte deploy limit
///         (25,266B observed). The literal now lives HERE, in a contract
///         whose ONLY job is assembling the canonical hook initCode, and the
///         deployer vessel carries just the machinery (~1.4KB).
///
///         Determinism is PRESERVED BY CONSTRUCTION: this contract is the
///         ONE source of the initCode bytes. HookDeployer mines against
///         `initOracle.hookInitCode(...)` and deploys with create2 against
///         the exact same bytes — a reservation's committed addresses and a
///         birth's create2 landings can never disagree. Any edit to
///         CurveHook changes these bytes (and therefore every mined hook
///         address), exactly as before — nothing downstream hand-rolls the
///         construction (factory, scripts, and tests all route through the
///         deployer), so the change is loud, not silent.
///
///         Deployed once per HookDeployer (born in its constructor), so the
///         `new HookDeployer()` deployment flow is unchanged for every
///         existing caller.
interface IHookInitCode {
    function hookInitCode(
        IPoolManager pm,
        address controller,
        address referralRegistry,
        CurveMath.CurveConfig calldata config,
        address deployerCutTo
    ) external pure returns (bytes memory);
}

contract HookInitCode {
    /// @dev Canonical CurveHook initCode: creation code ++ abi-encoded
    ///      constructor args (deployerCutTo is CLOCK-REDESIGN §3 — the 1%
    ///      unattributed-fee rake recipient, immutable on every hook the
    ///      factory births). Byte-for-byte the construction HookDeployer
    ///      embedded inline before the split.
    function hookInitCode(
        IPoolManager pm,
        address controller,
        address referralRegistry,
        CurveMath.CurveConfig calldata config,
        address deployerCutTo
    ) external pure returns (bytes memory) {
        return bytes.concat(
            type(CurveHook).creationCode,
            abi.encode(
                pm, IRoundController(controller), PSPReferralRegistry(referralRegistry), config, deployerCutTo
            )
        );
    }
}
