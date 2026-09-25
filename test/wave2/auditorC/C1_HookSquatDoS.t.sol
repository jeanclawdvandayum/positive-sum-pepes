// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CBase} from "./CBase.sol";
import {HookDeployer} from "../../../src/HookDeployer.sol";
import {PSPToken} from "../../../src/PSPToken.sol";
import {PSPReferralRegistry} from "../../../src/PSPReferralRegistry.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {PSPFactory} from "../../../src/PSPFactory.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";
import {IRoundController} from "../../../src/interfaces/IRoundController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @title C-1 battery — hook-squat DoS, staged-spawn edition (2026-08-30)
/// @notice History: the legacy deterministic salt scan (salt 0,1,2,...) made
///         every future hook address computable from public state, so an
///         orphan deployed at the predicted address collided the spawn's
///         create2 and bricked finalizeCarpet FOREVER (fork-verified HIGH,
///         2026-08-18). First fix: block-context entropy. Second fix
///         (staging): the whole round address set is create2-derived from
///         salts rooted in the reserve block's own context — nothing about
///         round n+1 is computable before the reserve runs, and even the
///         committed reservation can only be "helped", never hijacked
///         (occupying a predicted create2 address requires the identical
///         initcode). The nonce-based pre-launch prediction the original
///         attack relied on is structurally dead: there IS no next-nonce.
contract C1_HookSquatDoS is CBase {

    /// v5.1: registries are per-round — orphan deploys only need SOME
    /// registry address for the ctor arg; a throwaway is fine.
    function _dummyRegistry() internal returns (address) {
        return address(new PSPReferralRegistry(address(2), 1000e18));
    }

    /// @dev the attacker's one-shot deploy reach, reconstituted on top of
    ///      the production pair (mineHook + deployHookAt — the legacy
    ///      one-shot deployHook was deleted for EIP-170 headroom; the
    ///      permissionless surface is identical).
    function _orphanHook(address controller, address registry, CurveMath.CurveConfig memory cfg)
        internal
        returns (address orphan)
    {
        (address cand, bytes32 salt) =
            hookDeployer.mineHook(IPoolManager(address(poolManager)), controller, registry, cfg, address(this), 131_072);
        orphan = hookDeployer.deployHookAt(
            salt, IPoolManager(address(poolManager)), controller, registry, cfg, address(this)
        );
        assertEq(orphan, cand, "orphan at mined address");
    }

    /// @dev CLOCK-REDESIGN: the staging battery keeps the SPLIT factory
    ///      primitives alive on purpose — detonate() composes markDestroyed +
    ///      spawnNextRound (reserve+birth) in one tx, which would consume the
    ///      reservation before this suite can observe it. The staged path is
    ///      controller markDestroyed → permissionless reserveSpawn →
    ///      permissionless birthRound.
    function _stageNextRound() internal {
        vm.prank(address(controller1));
        factory.markDestroyed(1);
        factory.reserveSpawn(1);
    }

    /// Control: the staged prediction is exact. A clean stage + birth
    /// lands every contract at its reserved address.
    function test_C1_control_PredictionIsExact_CleanSpawnWorks() public {
        _launchRound1();
        _stageNextRound();

                // field-wise read into a struct: plain destructures overflow via-ir
        PSPFactory.SpawnReservation memory res0;
        (res0.fromRoundId, res0.newRoundId, res0.tokenSalt, res0.controllerSalt, res0.hookSalt, res0.token, res0.controller, res0.hook, res0.contextHash, res0.greenRoot, res0.greenCount, res0.active, res0.name, res0.symbol, res0.phase) = factory.reservation();
        assertTrue(res0.active, "reservation live after finalize");
        address token = res0.token;
        address controller = res0.controller;
        address hook = res0.hook;

        factory.birthRound();

        assertEq(factory.currentRoundId(), 2, "round 2 spawned");
        PSPFactory.Round memory r2 = factory.getRound(2);
        assertTrue(address(r2.controller) == controller, "controller at reserved address");
        assertTrue(address(r2.token) == token, "token at reserved address");
        assertTrue(address(r2.hook) == hook, "hook at reserved address");
        assertFalse(r2.destroyed);
    }

    /// MITIGATION PIN (was: the pre-launch squat brick). The attacker
    /// deploys an orphan hook aimed at a GUESSED controller address — under
    /// staging there is no better guess available: the real controller's
    /// salt root includes the reserve block's prevrandao. The reservation
    /// mines its own salt in its own block; the orphan is dead weight.
    function test_C1_attack_PreLaunchSquatIsNowInert() public {
        // ---- attacker squats immediately after round 1 deploys ----
        // Everything below derives from PUBLIC state; no privileged role.
        // The guess is a plain address (the old next-nonce prediction is
        // dead — create2 addresses are salt-rooted, not nonce-rooted).
        address guessedController = makeAddr("guessed-controller");
        vm.prank(attacker);
        address orphan = _orphanHook(
            guessedController, _dummyRegistry(), _gameCurveFromPublicState()
        );
        assertTrue(orphan.code.length > 0, "orphan hook deployed (into the squat block's salt space)");

        // ---- honest round life: predeposit, launch, a real buy ----
        _launchRound1();
        vm.startPrank(alice);
        mixETH.approve(address(swapper), 10e18);
        swapper.buy(_key(), 10e18, alice);
        vm.stopPrank();

        // ---- the clock strikes zero; anyone detonates (one tx: flat +
        //      locks open + successor birthed around the orphan). Later
        //      block => fresh entropy => the orphan's salt space missed. ----
        uint256 reserveBefore = mixETH.balanceOf(address(hook1));
        assertGt(reserveBefore, 0, "hook still custodies unredeemed backing");
        _detonateRound1();
        assertGt(controller1.flatTime(), 0, "round is flat");

        // ---- the rebirth completed around the orphan ----
        assertEq(factory.currentRoundId(), 2, "round 2 spawned despite the squat");
        PSPFactory.Round memory r2 = factory.getRound(2);
        assertTrue(address(r2.controller) != address(0), "round-2 controller exists");
        assertTrue(address(r2.hook) != orphan, "round-2 hook dodged the orphan");
        assertTrue(CurveHook(address(r2.hook)).mode() == CurveHook.Mode.Predeposit, "round 2 born in Predeposit");
        // 2026-08-30 indefinite redemption: the dying hook KEEPS the
        // unclaimed backing — payable via redeemBacking forever
        assertEq(mixETH.balanceOf(address(hook1)), reserveBefore, "dead hook still custodies the backing");
    }

    /// The orphan cannot be weaponized: its controller slot is a guessed
    /// address with no code, so the orphan's own guards are unreachable.
    function test_C1_orphanIsInert() public {
        vm.prank(attacker);
        address orphan = _orphanHook(
            makeAddr("guessed-controller"), _dummyRegistry(), _gameCurveFromPublicState()
        );
        // nobody can drive the orphan: the controller address has no code
        // (no owner exists to call setHook/setFactoryRoundId), and setMode
        // is controller-only. Verify the guard:
        vm.prank(attacker);
        vm.expectRevert();
        CurveHook(orphan).setMode(CurveHook.Mode.Destroyed);
    }

    /// STAGED-SPECIFIC: front-running a COMMITTED reservation with an
    /// identical pre-deploy is harmless — create2 address binding means the
    /// occupant IS the canonical contract; birth wires it instead of failing.
    /// Every leg (token, controller+staker, registry, hook) can be pre-
    /// deployed by anyone — but ONLY as the byte-identical contract: the
    /// hook's constructor has no external legs (BaseHook + three stores),
    /// and a variant deploy with different args simply lands elsewhere.
    function test_C1_committedReservationCannotBeHijacked() public {
        _launchRound1();
        _stageNextRound();

        assertTrue(factory.reservationActive(), "committed");
                // field-wise read (slot 3 is tokenSalt — was misread as hookSalt in
        // the original C-1 miss; destructures overflow via-ir — see above)
        PSPFactory.SpawnReservation memory r;
        (r.fromRoundId, r.newRoundId, r.tokenSalt, r.controllerSalt, r.hookSalt, r.token, r.controller, r.hook, r.contextHash, r.greenRoot, r.greenCount, r.active, r.name, r.symbol, r.phase) = factory.reservation();
        bytes32 tokenSalt = r.tokenSalt;
        bytes32 controllerSalt = r.controllerSalt;
        bytes32 hookSalt = r.hookSalt;
        address token = r.token;
        address controller = r.controller;
        address hook = r.hook;

        // byte-identical config by construction: deployRound stored exactly
        // CBase's _curve() into gameCurve (the hook's stored zones are
        // normalized — NOT a faithful mirror — so don't rebuild from those)
        CurveMath.CurveConfig memory cfg = _curve();

        // predicted sibling addresses, same derivations the factory used
        // (scoped: salts die before the deploy legs — liveness is what
        // via-ir's stack budget counts)
        address registry;
        {
            bytes32 stakerSalt = keccak256(abi.encode(controller, "psp-staker"));
            address staker = factory.stakerDeployer().predictStaker(
                stakerSalt, IERC20(token), IRoundController(controller), factory.descriptor()
            );
            assertEq(staker.code.length, 0, "staker not yet born");
            bytes32 registrySalt = keccak256(abi.encode(controller, "psp-registry"));
            registry = factory.controllerDeployer().predictRegistry(
                registrySalt, staker, factory.REFERRAL_MIN_STAKE()
            );
        }

        // ---- (a) hostile variant: same committed salt, DIFFERENT args
        //      (in its own helper — the inline try/catch was the frame that
        //      pushed this test past via-ir's stack limit).
        _tryRogueVariant(hookSalt, registry, cfg, hook);

        // ---- (b) helpful path: identical controller first, then the hook
        // (each leg lives in its own helper: one frame, one concern — the
        // combined test function is several slots too deep for via-ir)
        vm.prank(attacker);
        assertEq(
            _helpController(controllerSalt, token, controller, cfg),
            controller,
            "attacker could only deploy the identical controller"
        );
        vm.prank(attacker);
        assertEq(_helpRegistry(controller), registry, "identical registry");
        vm.prank(attacker);
        assertEq(_helpHook(hookSalt, controller, registry, cfg), hook, "attacker could only deploy the identical hook");

        // birth completes around the pre-deployed, identical contracts
        _completeBirthAround(controller, hook);
    }

    /// @dev (a) hostile variant: same committed salt, DIFFERENT args. The
    ///      hook's ctor has no external legs, but the variant's target
    ///      address was never flag-mined — the salt was mined ONLY for the
    ///      identical initcode. Best case for the attacker, the variant
    ///      lands at a different address (inert orphan); usually the ctor's
    ///      own flag self-check rejects the un-mined address outright.
    function _tryRogueVariant(
        bytes32 hookSalt,
        address registry,
        CurveMath.CurveConfig memory cfg,
        address hook
    ) internal {
        vm.prank(attacker);
        try hookDeployer.deployHookAt(
            hookSalt, IPoolManager(address(poolManager)), makeAddr("rogue-controller"), registry, cfg, address(this)
        ) returns (address rogueHook) {
            assertTrue(rogueHook != hook, "variant lands elsewhere - reserved slot untouchable");
        } catch {
            // the variant could not even deploy at this salt — even stronger
        }
    }

    function _completeBirthAround(address controller, address hook) internal {
        vm.prank(rando);
        factory.birthRound();
        assertEq(address(factory.getRound(2).controller), controller, "reserved controller wired");
        assertEq(address(factory.getRound(2).hook), hook, "reserved hook wired");
        assertTrue(CurveHook(hook).mode() == CurveHook.Mode.Predeposit, "born in Predeposit");
    }

    // ---- plumbing ----
    /// @dev The identical-args "helpful" deploy from the reservation's own
    ///      committed context (green window from the timings slot, the
    ///      factory's open window + greenlist, round 1 as the prev token).
    function _helpController(
        bytes32 salt,
        address token,
        address controller,
        CurveMath.CurveConfig memory cfg
    ) internal returns (address) {
        return address(
            factory.controllerDeployer().deployControllerAt(
                salt,
                PSPToken(token),
                IERC20(address(mixETH)),
                cfg,
                address(factory),
                factory.descriptor(),
                factory.stakerDeployer(),
                uint64(cfg.timings & CurveMath.TIMINGS_MASK),
                factory.openWindowSec(),
                factory.nextGreenRoot(),
                factory.nextGreenCount(),
                0,
                PSPToken(factory.pspRoundToken(1))
            )
        );
    }

    function _helpRegistry(address controller) internal returns (address) {
        bytes32 salt = keccak256(abi.encode(controller, "psp-registry"));
        return factory.controllerDeployer().deployRegistryAt(
            salt, IRoundController(controller).stakerAddress(), factory.REFERRAL_MIN_STAKE()
        );
    }

    function _helpHook(
        bytes32 salt,
        address controller,
        address registry,
        CurveMath.CurveConfig memory cfg
    ) internal returns (address) {
        return hookDeployer.deployHookAt(
            salt, IPoolManager(address(poolManager)), controller, registry, cfg, address(this)
        );
    }

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
