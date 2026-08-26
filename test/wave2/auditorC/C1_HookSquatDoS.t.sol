// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CBase} from "./CBase.sol";
import {PSPReferralRegistry} from "../../../src/PSPReferralRegistry.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {PSPFactory} from "../../../src/PSPFactory.sol";
import {HookDeployer} from "../../../src/HookDeployer.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title C-1 - Permissionless deterministic hook-address squatting permanently
///        bricks round finalization and locks the dying round's reserve.
///
/// POST-FIX (2026-08-18): remediated by entropy-keyed salt mining
/// (HookMiner.findWithEntropy) + occupied-candidate fall-through in
/// HookDeployer.deployHook. The pre-launch squat below still deploys an
/// orphan, but its address was derived from the SQUAT block's entropy -
/// at finalize time (a later block) the salt space is entirely different,
/// so the orphan is not even a candidate. The strongest surviving attack
/// (same-block front-run of candidate 0) is pinned in
/// test/audit/C1SquatFork.t.sol on the mainnet fork. Original root-cause
/// chain, kept for the record:
///
/// Root cause chain (pre-fix):
///   1. HookDeployer.deployHook was permissionless and fully deterministic:
///      salt = FIRST salt (0, 1, 2, ...) whose CREATE2 address carries the
///      flag bits for (deployer=HookDeployer, flags, initCodeHash).
///   2. The next round's controller address is a plain CREATE address -
///      predictable from the ControllerDeployer vessel's public nonce
///      (next round consumes two nonces: token, then controller).
///   3. The spawn's curve config is fully public BEFORE the spawn:
///      gameCurve() getter + current hook's getCurveZones(). So the exact
///      future initCode - its hash and mined salt - was on-chain public.
///   4. An attacker pre-deployed the orphan hook at that exact address via
///      the same vessel. When the factory later create2ed with the same
///      salt, the target had code; create2 returned 0 and deployHook
///      reverted DeployFailed - FOREVER, because every retry mined the
///      identical salt (HookMiner.find had no occupied-address probe; it
///      was removed by the H-2 gas fix). finalizeCarpet reverted
///      FactorySpawnFailed and the dying round's reserve was locked.
contract C1_HookSquatDoS is CBase {

    /// v5.1: registries are per-round — orphan deploys only need SOME
    /// registry address for the ctor arg; a throwaway is fine.
    function _dummyRegistry() internal returns (address) {
        return address(new PSPReferralRegistry(address(2), 1000e18));
    }
    /// Control: the nonce-based prediction is exact. A clean finalize spawns
    /// round 2 at precisely the predicted controller address.
    function test_C1_control_PredictionIsExact_CleanSpawnWorks() public {
        address predicted = _predictedNextController();
        // EIP-161: contracts are born with nonce 1. POST-SPLIT (2026-08-18)
        // each round consumes exactly ONE vessel nonce (controller only —
        // the token deploys via a fresh TokenDeployer off the factory) -
        // proven in C4_Probe.
        assertEq(vm.getNonce(address(controllerDeployer)), 2, "vessel nonce after round 1");

        _launchRound1();
        _bombRound1();
        _warpPastFlatWindow();
        controller1.finalizeCarpet();

        assertEq(factory.currentRoundId(), 2, "round 2 spawned");
        PSPFactory.Round memory r2 = factory.getRound(2);
        assertTrue(address(r2.controller) == predicted, "controller deployed at predicted address");
        assertFalse(r2.destroyed);
    }

    /// MITIGATION PIN (was: the pre-launch squat brick). The attacker runs
    /// the identical pre-launch squat, but entropy-keyed salts mean the
    /// orphan's address belongs to the SQUAT block's salt space - finalize
    /// runs in a later block and never looks at it. The rebirth completes
    /// end to end; the orphan is dead weight the attacker paid for.
    function test_C1_attack_PreLaunchSquatIsNowInert() public {
        // ---- attacker squats immediately after round 1 deploys ----
        // Everything below derives from PUBLIC state; no privileged role.
        uint256 vesselNonce = vm.getNonce(address(controllerDeployer)); // == 2
        address predictedController = vm.computeCreateAddress(address(controllerDeployer), vesselNonce);
        assertEq(predictedController, _predictedNextController(), "nonce math");

        vm.prank(attacker);
        (address orphan,) =
            hookDeployer.deployHook(IPoolManager(address(poolManager)), predictedController, _dummyRegistry(), _gameCurveFromPublicState());
        assertTrue(orphan.code.length > 0, "orphan hook deployed (into the squat block's salt space)");

        // ---- honest round life: predeposit, launch, a real buy ----
        _launchRound1();
        vm.startPrank(alice);
        mixETH.approve(address(swapper), 10e18);
        swapper.buy(_key(), 10e18, alice);
        vm.stopPrank();

        // ---- governance kills the round; flat window opens and passes ----
        _bombRound1();
        assertGt(controller1.flatTime(), 0, "round is flat");
        _warpPastFlatWindow();

        // ---- finalize: later block => different entropy => orphan missed ----
        uint256 reserveBefore = mixETH.balanceOf(address(hook1));
        assertGt(reserveBefore, 0, "hook still custodies unredeemed backing");
        vm.prank(rando); // permissionless caller, like the real flow
        controller1.finalizeCarpet();

        // ---- the rebirth completed around the orphan ----
        assertEq(factory.currentRoundId(), 2, "round 2 spawned despite the squat");
        PSPFactory.Round memory r2 = factory.getRound(2);
        assertTrue(address(r2.controller) != address(0), "round-2 controller exists");
        assertTrue(address(r2.hook) != orphan, "round-2 hook dodged the orphan");
        assertTrue(CurveHook(address(r2.hook)).mode() == CurveHook.Mode.Predeposit, "round 2 born in Predeposit");
        assertEq(mixETH.balanceOf(address(hook1)), 0, "dying round fully drained - no stranded reserve");
    }

    /// The orphan cannot be weaponized: its controller slot is a future
    /// address with no code, so the orphan's own guards are unreachable.
    function test_C1_orphanIsInert() public {
        uint256 vesselNonce = vm.getNonce(address(controllerDeployer));
        address predictedController = vm.computeCreateAddress(address(controllerDeployer), vesselNonce + 1);
        vm.prank(attacker);
        (address orphan,) = hookDeployer.deployHook(
            IPoolManager(address(poolManager)), predictedController, _dummyRegistry(), _gameCurveFromPublicState()
        );
        // nobody can drive the orphan: the controller address has no code
        // (no owner exists to call setHook/setFactoryRoundId), and setMode
        // is controller-only. Verify the guard:
        vm.prank(attacker);
        vm.expectRevert();
        CurveHook(orphan).setMode(CurveHook.Mode.Destroyed);
    }

    // ---- plumbing ----
    function _key() internal view returns (PoolKey memory) {
        address c0 = address(mixETH);
        address c1 = address(psp1);
        if (c0 > c1) (c0, c1) = (c1, c0);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook1))
        });
    }
}
