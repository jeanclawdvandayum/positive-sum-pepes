// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {CBase} from "./wave2/auditorC/CBase.sol";

import {HookDeployer} from "../src/HookDeployer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {RoundController} from "../src/RoundController.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {IRoundController} from "../src/interfaces/IRoundController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SpawnStaging — the two-stage permissionless rebirth (2026-08-30)
/// @notice finalizeCarpet now RESERVES (bounded flag-mine, deposit-free);
///         birthRound (anyone) executes deterministically. These tests pin:
///         prediction exactness, idempotent birth under front-running, the
///         guard set, carry continuity, and the gas canaries that motivated
///         the whole design: reserve bounded, birth variance-free.
contract SpawnStaging is CBase {
    // ── generic round lifecycle (CBase's helpers are round-1-fixed) ──

    function _launch(RoundController c) internal {
        _launch(c, 200e18);
    }

    /// @dev `amt` per depositor: reborn rounds open with the carry already
    ///      counted against PREDEPOSIT_CAP (500 mix), so later rounds use
    ///      smaller amounts to fit the remaining headroom.
    function _launch(RoundController c, uint256 amt) internal {
        vm.startPrank(alice);
        mixETH.approve(address(c), amt);
        c.predeposit(amt);
        vm.stopPrank();

        vm.startPrank(bob);
        mixETH.approve(address(c), amt);
        c.predeposit(amt);
        vm.stopPrank();

        vm.prank(address(factory));
        c.launchPooledBuy();

        vm.prank(alice);
        c.claimPredepositPSP();
        vm.prank(bob);
        c.claimPredepositPSP();
        vm.warp(((block.timestamp / 7 days) + 1) * 7 days + 1);
    }

    function _voteAll(RoundController c, address who) internal {
        PSPStaker s = c.staker();
        uint256 n = s.balanceOf(who);
        uint256[] memory ids = new uint256[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            uint256 id = s.tokenOfOwnerByIndex(who, i);
            if (s.pepeVoteWeight(id, block.timestamp) == 0) continue;
            ids[k++] = id;
        }
        assembly {
            mstore(ids, k)
        }
        if (k == 0) return;
        vm.prank(who);
        c.voteCarpetBomb(ids, true);
    }

    function _bomb(RoundController c) internal {
        vm.prank(alice);
        c.proposeCarpetBomb();
        _voteAll(c, alice);
        _voteAll(c, bob);
        (, uint256 proposeTime,,,) = c.currentProposal();
        vm.warp(proposeTime + 3 days + 1);
        c.carpetBomb();
    }

    function _kill(RoundController c) internal {
        _launch(c);
        _bomb(c);
        vm.warp(c.flatTime() + 3 days + 1);
    }

    function _reservation()
        internal
        view
        returns (PSPFactory.SpawnReservation memory r)
    {
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

    // ─────────────── lifecycle ───────────────

    /// Death reserves; the successor does not exist yet; anyone births it;
    /// every address matches the reservation bit-for-bit.
    function test_staged_rebirth_e2e() public {
        _kill(controller1);
        controller1.finalizeCarpet(); // reserves only

        PSPFactory.SpawnReservation memory r = _reservation();
        assertTrue(r.active, "reservation live");
        assertEq(uint256(r.newRoundId), 2, "newRoundId");
        assertEq(uint256(r.fromRoundId), 1, "fromRoundId");
        assertEq(factory.currentRoundId(), 1, "round 2 not yet born");
        assertEq(address(factory.getRound(2).token), address(0), "round 2 empty pre-birth");

        vm.prank(rando); // permissionless birth
        factory.birthRound();

        PSPFactory.Round memory r2 = factory.getRound(2);
        assertEq(address(r2.token), r.token, "token == prediction");
        assertEq(address(r2.controller), r.controller, "controller == prediction");
        assertEq(address(r2.hook), r.hook, "hook == prediction");
        assertEq(factory.currentRoundId(), 2, "currentRoundId advanced");
        assertFalse(_reservation().active, "reservation consumed");
        assertEq(r2.name, "Positive Sum Pepes 2");
        assertEq(r2.symbol, "PSP2");
    }

    /// Under indefinite redemption (2026-08-30) death no longer drains — the
    /// ONLY carry is mixETH actually held by the factory (donations). A
    /// donated carry reaches round 2's predeposit at birth; the dying hook's
    /// reserve stays put, waiting for its holders.
    function test_carry_flows_through_birth() public {
        uint256 donated = 7e18;
        mixETH.transfer(address(factory), donated);

        _kill(controller1);
        controller1.finalizeCarpet();

        uint256 carry = mixETH.balanceOf(address(factory));
        assertEq(carry, donated, "factory-held donation is the carry");

        vm.expectEmit(true, true, true, true, address(factory));
        emit PSPFactory.ETHCarried(1, 2, carry);
        vm.prank(rando);
        factory.birthRound();

        assertEq(mixETH.balanceOf(address(factory)), 0, "carry fully seeded");
        assertGt(mixETH.balanceOf(address(hook1)), 0, "dying hook keeps its backing");
    }

    /// staker + registry predictions (derived from the predicted controller)
    /// match what actually deployed — the full address set was computable
    /// at reserve time.
    function test_predictions_exact() public {
        _kill(controller1);
        controller1.finalizeCarpet();
        vm.prank(rando);
        factory.birthRound();

        PSPFactory.Round memory r2 = factory.getRound(2);
        bytes32 stakerSalt = keccak256(abi.encode(address(r2.controller), "psp-staker"));
        address stakerPred = factory.stakerDeployer().predictStaker(
            stakerSalt,
            IERC20(address(r2.token)),
            IRoundController(address(r2.controller)),
            factory.descriptor()
        );
        assertEq(r2.controller.stakerAddress(), stakerPred, "staker prediction");

        bytes32 registrySalt = keccak256(abi.encode(address(r2.controller), "psp-registry"));
        address regPred = factory.controllerDeployer().predictRegistry(
            registrySalt, r2.controller.stakerAddress(), factory.REFERRAL_MIN_STAKE()
        );
        assertEq(factory.referralRegistryOf(2), regPred, "registry prediction");
    }

    /// Front-running the birth with an identical pre-deploy is harmless:
    /// create2 address binding means the occupant IS the canonical token,
    /// and birth wires it instead of reverting.
    function test_birth_idempotent_when_front_run() public {
        _kill(controller1);
        controller1.finalizeCarpet();
        PSPFactory.SpawnReservation memory r = _reservation();

        // attacker pre-deploys the token at the committed salt with the
        // IDENTICAL args (only those hit the predicted address)
        vm.prank(attacker);
        factory.tokenDeployer().deployTokenAt(
            r.tokenSalt, "Positive Sum Pepes 2", "PSP2", address(factory)
        );

        vm.prank(rando);
        factory.birthRound(); // must complete, not revert

        assertEq(address(factory.getRound(2).token), r.token, "same token wired");
    }

    // ─────────────── guards ───────────────

    function test_guards() public {
        // reserve on a live round
        vm.expectRevert(PSPFactory.RoundNotDestroyed.selector);
        factory.reserveSpawn(1);

        // birth with nothing reserved
        vm.expectRevert(PSPFactory.NoReservation.selector);
        factory.birthRound();

        // reserve → double reserve fenced
        _kill(controller1);
        controller1.finalizeCarpet();
        vm.expectRevert(PSPFactory.ReservationActive.selector);
        factory.reserveSpawn(1);

        // consumed reservation → birth fenced
        vm.prank(rando);
        factory.birthRound();
        vm.expectRevert(PSPFactory.NoReservation.selector);
        factory.birthRound();

        // round 2 is live now — reserve from it fenced
        vm.expectRevert(PSPFactory.RoundNotDestroyed.selector);
        factory.reserveSpawn(2);
    }

    /// Mid-flight context change (descriptor) fails CLOSED at birth;
    /// owner voids and re-reserves under the new context.
    function test_stale_context_fenced() public {
        _kill(controller1);
        controller1.finalizeCarpet();

        factory.setDescriptor(address(0xBEEF)); // owner, mid-flight

        vm.expectRevert(PSPFactory.ReservationStale.selector);
        vm.prank(rando);
        factory.birthRound();

        factory.voidReservation(); // owner escape hatch
        vm.expectRevert(PSPFactory.NoReservation.selector);
        vm.prank(rando);
        factory.birthRound();

        factory.reserveSpawn(1); // re-reserve under new descriptor
        vm.prank(rando);
        factory.birthRound(); // succeeds
        assertEq(factory.currentRoundId(), 2);
    }

    /// The composed one-tx rebirth still works for direct callers.
    function test_spawnNextRound_composed_compat() public {
        _kill(controller1);
        vm.prank(address(controller1));
        factory.markDestroyed(1); // finalizeCarpet's job, done manually here

        vm.prank(rando);
        (uint256 id, address h) = factory.spawnNextRound(1);
        assertEq(id, 2, "round id");
        assertTrue(h != address(0), "hook addr");
        assertEq(address(factory.getRound(2).hook), h);
        assertFalse(_reservation().active, "consumed");
    }

    // ─────────────── gas canaries (the point of the redesign) ───────────────

    /// reserveSpawn worst case is bounded by HOOK_SCAN_CAP; birthRound is
    /// variance-free across rounds (no mining, all create2 from committed
    /// salts).
    function test_gas_reserve_bounded_birth_flat() public {
        _kill(controller1);

        uint256 g0 = gasleft();
        controller1.finalizeCarpet(); // drain + mark + reserve
        uint256 gFinalize = g0 - gasleft();

        factory.voidReservation();
        vm.roll(block.number + 3);
        vm.warp(block.timestamp + 101); // fresh block entropy

        // The ~0.03% tail: a draw with no flag match inside HOOK_SCAN_CAP
        // reverts cheap (no deposits exist). Production semantics = retry
        // next block with fresh entropy; mirror them here.
        uint256 gReserve;
        {
            uint256 attempts;
            while (true) {
                attempts++;
                uint256 t0 = gasleft();
                try factory.reserveSpawn(1) {
                    gReserve = t0 - gasleft();
                    break;
                } catch {
                    assertTrue(attempts < 24, "reserve never found a flag match");
                    vm.roll(block.number + 1);
                    vm.warp(block.timestamp + 13);
                }
            }
            console2.log("reserve attempts (incl. tail retries):", attempts);
        }

        vm.prank(rando);
        g0 = gasleft();
        factory.birthRound();
        uint256 gBirth1 = g0 - gasleft();

        // round 3, fresh entropy. Round 2's public kill can't reach quorum
        // (carry 400 of the 500 cap isn't votable by alice/bob), so this
        // second rebirth uses the direct destruction primitive — the gas
        // properties under test are birth's, not governance's.
        RoundController c2 = factory.getRound(2).controller;
        vm.roll(block.number + 7);
        vm.prank(address(c2));
        factory.markDestroyed(2);
        factory.reserveSpawn(2);

        vm.prank(rando);
        g0 = gasleft();
        factory.birthRound();
        uint256 gBirth2 = g0 - gasleft();

        console2.log("finalizeCarpet (drain+reserve):", gFinalize);
        console2.log("pure reserveSpawn            :", gReserve);
        console2.log("birthRound round 2           :", gBirth1);
        console2.log("birthRound round 3           :", gBirth2);

        assertLe(gFinalize, 13_000_000, "finalize over budget");
        assertLe(gReserve, 12_500_000, "reserve over cap");
        assertLe(gBirth1, 12_500_000, "birth 2 over cap");
        assertLe(gBirth2, 12_500_000, "birth 3 over cap");
        // 133k observed spread == the seedCarry path (round 2 seeded a
        // 400-mix carry, round 3 none) — structural, not mining variance
        // (birth contains zero mining by construction).
        uint256 spread = gBirth1 > gBirth2 ? gBirth1 - gBirth2 : gBirth2 - gBirth1;
        assertLt(spread, 250_000, "birth gas variance");
    }

    /// The reserve's flag-mine respects the caller's bound: a scan whose
    /// entropy yields no match within the bound reverts (CapExhausted from
    /// the library or MiningExhausted from the budget guard) instead of
    /// running the historical 160k-candidate lottery.
    function test_mining_bound_enforced() public {
        _kill(controller1);
        controller1.finalizeCarpet();
        PSPFactory.SpawnReservation memory r = _reservation();

        // The mined hook address must actually carry the v4 flag bits —
        // the reservation is a real flag-matched candidate.
        assertTrue(uint160(uint256(uint160(r.hook))) & 0x3FFF != 0, "hook flags nonempty");

        // A cap of 0 must revert MiningExhausted, not scan forever —
        // exercises the budget-underflow guard in HookDeployer.mineHook.
        // (hoist the view calls: expectRevert binds to the NEXT call)
        HookDeployer hd = factory.hookDeployer();
        IPoolManager pm = IPoolManager(address(poolManager));
        address reg = factory.referralRegistryOf(2);
        CurveMath.CurveConfig memory cfg = _curve();
        vm.expectRevert(HookDeployer.MiningExhausted.selector);
        hd.mineHook(pm, r.controller, reg, cfg, 0);
    }
}
