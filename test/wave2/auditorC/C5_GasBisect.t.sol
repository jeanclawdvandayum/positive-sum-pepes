// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CBase} from "./CBase.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
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
        vm.prank(attacker);
        (address orphan,) =
            hookDeployer.deployHook(IPoolManager(address(poolManager)), predictedController, _gameCurveFromPublicState());

        // ── legacy deterministic miner, replicated verbatim ──
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory initCode = bytes.concat(
            type(CurveHook).creationCode, abi.encode(IPoolManager(address(poolManager)), predictedController, _gameCurveFromPublicState())
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
        assertLt(passGas, 4_000_000, "one mining pass must stay bounded (~2^14 iters)");

        // ── the vessel actually deployed at an entropy candidate ──
        assertTrue(cand == orphan, "vessel deployed at the first entropy candidate of this block");
    }
}
