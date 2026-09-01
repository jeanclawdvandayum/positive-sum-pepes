// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CBase} from "./CBase.sol";
import {PSPFactory} from "../../../src/PSPFactory.sol";

/// Determinism probe, staged-spawn edition (2026-08-30).
///
/// PRE-STAGING topology (nonce CREATE, retired):
///   vessel  : deploys ONLY the RoundController (one nonce per round)
///   factory : one plain CREATE per round — a fresh TokenDeployer
///   token   : first CREATE of that round's TokenDeployer (nonce 1)
///   addresses publicly precomputable from (deployer, next-nonce)
///
/// POST-STAGING topology (create2, current):
///   every round contract deploys via CREATE2 from salted deployers;
///   salts root at keccak(prevrandao, timestamp, number, roundId) —
///   unknowable before the reserve block — so NO address in the next
///   round is publicly precomputable (the C-1 pre-squat class dies
///   structurally). This probe pins the mechanics the SpawnStaging
///   suite's prediction-exactness assertions rely on.
contract C4_Probe is CBase {
    function test_C4_VesselNonceMechanics() public {
        // NOTE (pinned 2026-08-30): CREATE2 increments the SENDER's nonce
        // (Yellow Paper §7 — EIP-1014 removed it from the ADDRESS
        // DERIVATION only). So per round: controller vessel +2 (controller
        // + registry), hook/staker/token vessels +1 each — create counts,
        // not create-prediction state.
        uint256 n0 = vm.getNonce(address(controllerDeployer));
        uint256 f0 = vm.getNonce(address(factory));

        // The C-1 security property, post-staging: the legacy nonce-based
        // prediction CANNOT land on the reserved addresses. Round n+1's
        // salts root at the reserve block's own context; there is no
        // public "next nonce" to squat.
        address nonceGuess = vm.computeCreateAddress(address(controllerDeployer), n0);
        address nonceGuess2 = vm.computeCreateAddress(address(controllerDeployer), n0 + 1);

        _launchRound1();
        // CLOCK-REDESIGN: this probe pins the STAGED primitives, so it takes
        // the split path (controller markDestroyed → permissionless
        // reserveSpawn) rather than detonate()'s composed one-tx birth.
        vm.prank(address(controller1));
        factory.markDestroyed(1);
        factory.reserveSpawn(1); // reserves

        PSPFactory.SpawnReservation memory r = _reservation();
        assertTrue(r.active, "reservation live");
        assertEq(uint256(r.newRoundId), 2, "round id");
        assertTrue(r.token != address(0) && r.controller != address(0) && r.hook != address(0));
        assertTrue(r.controller != nonceGuess && r.controller != nonceGuess2, "nonce prediction misses (C-1 dead)");

        vm.prank(rando);
        factory.birthRound();

        // Factory never deploys per-round contracts itself (the ctor's
        // TokenDeployer was its only create, ever).
        assertEq(vm.getNonce(address(factory)), f0, "factory nonce frozen after ctor");
        // Per-round vessel create counts (nonce bumps from create2 sends)
        assertEq(vm.getNonce(address(controllerDeployer)), n0 + 2, "controller + registry");
        // Predictions exact
        PSPFactory.Round memory r2 = factory.getRound(2);
        assertTrue(address(r2.controller) == r.controller, "controller at predicted create2 address");
        assertTrue(address(r2.token) == r.token, "token at predicted create2 address");
        assertTrue(address(r2.hook) == r.hook, "hook at mined create2 address");
    }

    function _reservation() internal view returns (PSPFactory.SpawnReservation memory r) {
        (
            uint128 fromRoundId,
            uint128 newRoundId,
            bytes32 tokenSalt,
            bytes32 controllerSalt,
            bytes32 hookSalt,
            address token,
            address controller,
            address hook,
            bytes32 contextHash,
            bool active
        ) = factory.reservation();
        r = PSPFactory.SpawnReservation({
            fromRoundId: fromRoundId,
            newRoundId: newRoundId,
            tokenSalt: tokenSalt,
            controllerSalt: controllerSalt,
            hookSalt: hookSalt,
            token: token,
            controller: controller,
            hook: hook,
            contextHash: contextHash,
            active: active
        });
    }
}
