// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CBase} from "./CBase.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {PSPReferralRegistry} from "../../../src/PSPReferralRegistry.sol";
import {HookDeployer} from "../../../src/HookDeployer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";

/// Gas-bisect harness for the hook deploy path. PRE-FIX this file proved the
/// deterministic-mining DoS: an on-chain replica of HookMiner.find re-derived
/// the squatted orphan's address (the attacker's target was exactly the
/// spawn's deterministic salt) and a create2 into it burned block-breaking
/// gas. POST-FIX (C-1 remediation) it pins the two new properties:
///   1. DECOUPLING: the legacy deterministic scan (salt 0,1,2,...) no longer
///      predicts where deployHook puts a hook — the entropy-keyed salt space
///      made the pre-fix attack target irrelevant.
///   2. BOUNDED MINING: one entropy mining pass (a 14-bit flag match) costs
///      ~2-3M gas and deployHook's whole honest call stays block-comfortable.
contract C5_GasBisect is CBase {
    function test_C5_inline() public {
        // POST-SPLIT (2026-08-18): vessel deploys only the controller, so the
        // next controller is at the vessel's CURRENT nonce (no +1 token skip).
        address predictedController =
            vm.computeCreateAddress(address(controllerDeployer), vm.getNonce(address(controllerDeployer)));

        // deploy a hook through the real vessel (attacker position: any caller)
        // v5.1 fix (2026-08-20): ONE throwaway registry shared by the vessel
        // call AND the candidate recompute below — two `new` instances minted
        // two addresses → two initCode hashes → disjoint candidate spaces, so
        // the final `cand == orphan` pin could never hold (previously masked
        // by the failing 4M gas bound in front of it).
        address throwawayRegistry = address(new PSPReferralRegistry(address(1), address(2), 1000e18));
        vm.prank(attacker);
        (address orphan,) = hookDeployer.deployHook(
            IPoolManager(address(poolManager)),
            predictedController,
            throwawayRegistry, // v5.1: same instance as the recompute below
            _gameCurveFromPublicState()
        );

        // ── legacy deterministic miner, replicated verbatim ──
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory initCode = bytes.concat(
            type(CurveHook).creationCode,
            abi.encode(
                IPoolManager(address(poolManager)),
                predictedController,
                throwawayRegistry, // v5.1: same instance the vessel used above
                _gameCurveFromPublicState()
            )
        );
        emit log_named_uint("initCode length", initCode.length);

        bytes32 codeHash = keccak256(initCode);
        bytes memory data = abi.encodePacked(bytes1(0xFF), address(hookDeployer), bytes32(uint256(0)), codeHash);
        address legacyFound;
        for (uint256 salt; salt < 160_444; salt++) {
            address a;
            assembly ("memory-safe") {
                mstore(add(add(data, 0x20), 21), salt)
                a := and(keccak256(add(data, 0x20), 85), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            }
            if (uint160(a) & 0x3FFF == flags) {
                legacyFound = a;
                break;
            }
        }
        assertTrue(legacyFound != address(0), "legacy scan still finds its salt");
        assertTrue(
            legacyFound != orphan, "POST-FIX: entropy salts decoupled deploy from the deterministic scan"
        );

        // ── bounded mining: one entropy-keyed pass ──
        bytes32 entropy = keccak256(abi.encode(block.prevrandao, block.timestamp, block.number, predictedController));
        uint256 g0 = gasleft();
        (address cand, bytes32 salt,) =
            HookMiner.nextCandidate(address(hookDeployer), entropy, flags, initCode, "", 0);
        uint256 passGas = g0 - gasleft();
        emit log_named_uint("entropy mining pass gas", passGas);
        assertTrue(cand != address(0), "entropy pass found a candidate");
        // RECALIBRATED 2026-08-20 (wave2b): this harness's block context is
        // pinned (prevrandao=0, ts=1, number=1, controller=fixed), so the
        // match draw is DETERMINISTIC: N=42,351 iterations (~2.58x the 2^14
        // median — an unlucky-but-fixed draw). Post HookMiner Yul rewrite the
        // loop measures ~148 gas/iter → passGas ≈ 6.27M. The 4M bound written
        // for a median draw conflated draw length with per-iter cost. Bound =
        // N x 200 gas/iter ≈ 8.5M: a 2x per-iter regression (the H-2 class,
        // e.g. un-hoisted preimage) lands ~12.5M and trips hard; the draw
        // itself cannot drift (pinned). Median-draw executability is covered
        // by test_Gas_DeployRoundUnder12M (min-of-4 live draws).
        assertLt(passGas, 8_500_000, "one mining pass must stay bounded (~2^14 iters)");

        // ── the vessel actually deployed at an entropy candidate ──
        assertTrue(cand == orphan, "vessel deployed at the first entropy candidate of this block");
    }
}

/// TEMP scratch probe (wave2b perf fix pass, 2026-08-19) — NOT part of the
/// behavioral suite; measures HookMiner.nextCandidate per-iter gas and the
/// match index of the harness's deterministic entropy. Delete before merge.
contract C5Probe is CBase {
    function test_probe_iter_gas() public {
        address predictedController =
            vm.computeCreateAddress(address(controllerDeployer), vm.getNonce(address(controllerDeployer)));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory initCode = bytes.concat(
            type(CurveHook).creationCode,
            abi.encode(
                IPoolManager(address(poolManager)),
                predictedController,
                address(new PSPReferralRegistry(address(1), address(2), 1000e18)),
                _gameCurveFromPublicState()
            )
        );

        bytes32 entropy = keccak256(abi.encode(block.prevrandao, block.timestamp, block.number, predictedController));

        uint256 g0 = gasleft();
        (address c0,, uint256 n0) = HookMiner.nextCandidate(address(hookDeployer), entropy, flags, initCode, "", 0);
        uint256 g1 = gasleft();
        (address c1,, uint256 n1) = HookMiner.nextCandidate(address(hookDeployer), entropy, flags, initCode, "", 1);
        uint256 g2 = gasleft();
        (address c2,, uint256 n2) = HookMiner.nextCandidate(address(hookDeployer), entropy, flags, initCode, "", 2);
        uint256 g3 = gasleft();

        emit log_named_uint("pass gas fromIndex=0", g0 - g1);
        emit log_named_uint("pass gas fromIndex=1", g1 - g2);
        emit log_named_uint("pass gas fromIndex=2", g2 - g3);
        emit log_named_uint("per-iter gas (delta of deltas)", (g0 - g1) - (g1 - g2));
        emit log_named_uint("match index (n0-1)", n0 - 1);
        emit log_named_uint("sanity n1", n1);
        emit log_named_uint("sanity n2", n2);
        assertTrue(c0 == c1 && c1 == c2 && n0 == n1 && n1 == n2, "resume invariance");
    }
}
