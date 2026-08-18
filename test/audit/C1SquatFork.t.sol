// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AuditForkTest} from "./AuditFork.t.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {HookMiner} from "../../src/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title Wave2 C-1 fork verification (auditorC HIGH) - POST-FIX
/// @notice The deterministic hook-address squat bricked the rebirth loop on
///         the REAL mainnet-fork V4 PoolManager (see git history for the
///         original PoC). Fix: HookMiner.findWithEntropy keys the salt space
///         to block context (prevrandao/timestamp/number + controller), and
///         HookDeployer falls through occupied candidates. These tests pin
///         the FIXED behavior on the same fork:
///         1. same-block front-run (the strongest surviving attack): the
///            squatter shares the finalize block's entropy, occupies the
///            exact candidate the spawn would use - and the spawn simply
///            deploys at the next candidate. Round 2 lives.
///         2. all 4 candidates squatted in one block: THIS block's spawn
///            fails cleanly (no gas-burn), and the next block - new entropy -
///            succeeds. Sustaining a block requires re-squatting all 4
///            candidate deployments every block: unbounded grief cost vs one retry tx.
///         3. CI gas bound on the whole finalize->spawn path (mining loop
///            discipline: on-chain mining must stay block-executable).
contract C1SquatForkTest is AuditForkTest {
    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    /// Walk round 1 to a closed flat window; finalize is callable NOW.
    function _toFinalizable() internal {
        vm.startPrank(alice);
        mixETH.approve(address(controller), 60e18);
        controller.predeposit(60e18);
        vm.stopPrank();
        vm.prank(address(factory));
        controller.launchPooledBuy();
        vm.prank(alice);
        controller.claimPredepositPSP();

        vm.startPrank(bob);
        mixETH.approve(address(zapIn), type(uint256).max);
        uint256 bobPSP = zapIn.buyWithMix(key, 20e18, 0, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        psp.approve(address(controller), type(uint256).max);
        controller.lock(bobPSP);
        vm.stopPrank();

        skip(1);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        skip(3 days + 1);
        controller.carpetBomb();
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Flat), "flat window open");
        skip(3 days + 1 hours); // window closed
    }

    /// Round-2 controller address from public state (CREATE nonce of the
    /// ControllerDeployer vessel - unchanged by the C-1 fix).
    function _predictedCtrl2() internal view returns (address) {
        address vessel = address(factory.controllerDeployer());
        uint256 vesselNonce = vm.getNonce(vessel); // 3 after round 1 (born at 1, +2 deploys)
        // round 2: token consumes `vesselNonce`, controller consumes `vesselNonce + 1`
        return vm.computeCreateAddress(vessel, vesselNonce + 1);
    }

    /// Replicate deployHook's candidate derivation test-side: proves which
    /// candidate index the vessel picks and which address it skips to.
    function _candidates(address ctrl2)
        internal
        view
        returns (address[] memory addrs)
    {
        CurveMath.CurveConfig memory cfg =
            CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18); // == setUp config, inherited byte-exact
        bytes memory initCode = bytes.concat(type(CurveHook).creationCode, abi.encode(poolManager, ctrl2, cfg));
        bytes32 entropy = keccak256(abi.encode(block.prevrandao, block.timestamp, block.number, ctrl2));
        addrs = new address[](4);
        uint256 scanFrom;
        for (uint256 k; k < 4; k++) {
            (addrs[k],, scanFrom) = HookMiner.nextCandidate(
                address(factory.hookDeployer()), entropy, FLAGS, initCode, "", scanFrom
            );
        }
    }

    /// TEST 1: same-block front-run squat of candidate 0 - the strongest
    /// attack that survives the fix. The block context (and therefore the
    /// salt-space entropy) is PINNED to constants so this test's mining draw
    /// is identical across runs and CI: the gas assertions are regression
    /// tripwires against a fixed baseline, not a flaky tail sample.
    function test_C1_FORK_SameBlockSquatIsSkipped() public {
        _toFinalizable();
        // pin the draw: absolute values far past every lifecycle gate
        vm.prevrandao(bytes32(uint256(0xC1C1C1C1C1C1C1C1)));
        vm.warp(2_000_000_000);
        vm.roll(50_000_000);

        address predictedCtrl2 = _predictedCtrl2();
        address[] memory cands = _candidates(predictedCtrl2);

        // attacker (carol, no role, no capital) front-runs the finalize tx
        // IN THE SAME BLOCK: identical entropy, so the vessel itself deploys
        // the orphan at exactly candidate 0
        CurveMath.CurveConfig memory cfg2 =
            CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);
        vm.prank(carol);
        (address orphan,) = factory.hookDeployer().deployHook(poolManager, predictedCtrl2, cfg2);
        assertEq(orphan, cands[0], "vessel squat landed on predicted candidate 0");

        // finalize in the SAME block (same entropy): spawn skips the orphan
        uint256 g0 = gasleft();
        controller.finalizeCarpet();
        uint256 spent = g0 - gasleft();

        PSPFactory.Round memory r2 = factory.getRound(2);
        assertTrue(address(r2.controller) != address(0), "round 2 spawned - rebirth alive");
        assertEq(address(r2.hook), cands[1], "hook deployed at candidate 1 (skip worked)");
        assertTrue(address(r2.hook) != orphan, "hook dodged the squat");
        assertTrue(address(r2.hook).code.length > 0, "round-2 hook has code");

        // CI gas bound: fixed baseline (pinned draw) + margin. The mining
        // draw is geometric per fresh block (median ~2^14 iters/pass, heavy
        // tail — the same distribution legacy find() always had); this test
        // pins one sample of it so the bound can't flake. Deterministic
        // single-pass pin lives in C5_GasBisect (local context).
        assertLt(spent, 18_000_000, "finalize+spawn gas (1 squat, pinned) regressed");
        emit log_named_uint("finalizeCarpet gas (1 squat, post-fix)", spent);
    }

    /// TEST 2: residual risk, honestly pinned - squatting ALL candidates
    /// blocks THIS block's spawn, cleanly; the NEXT block's spawn (new
    /// entropy) succeeds without any further attacker action being required
    /// for the defense. Sustaining the block = 4 re-squats per block forever.
    function test_C1_FORK_AllCandidatesSquat_BlocksOneBlockOnly() public {
        _toFinalizable();
        address predictedCtrl2 = _predictedCtrl2();
        address[] memory cands = _candidates(predictedCtrl2);

        // attacker exhausts every candidate in this block's salt space
        CurveMath.CurveConfig memory cfg2 =
            CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);
        for (uint256 i; i < 4; i++) {
            vm.prank(carol);
            (address squatted,) = factory.hookDeployer().deployHook(poolManager, predictedCtrl2, cfg2);
            assertEq(squatted, cands[i], "sequential squats fill candidates in order");
        }

        // this block: spawn fails (clean revert - the occupied-probe means
        // no create2 ever fires into an occupied address, so no gas burn)
        vm.expectRevert();
        controller.finalizeCarpet();
        assertTrue(address(factory.getRound(2).controller) == address(0), "no round 2 this block");

        // next block: fresh entropy -> a wholly different candidate space;
        // the attacker's orphans are irrelevant. Defense cost: one retry.
        // (Retry context pinned for a deterministic honest-path gas baseline.)
        vm.prevrandao(bytes32(uint256(0xD2D2D2D2D2D2D2D2)));
        vm.warp(2_000_000_001);
        vm.roll(50_000_001);
        uint256 g0 = gasleft();
        controller.finalizeCarpet();
        uint256 honestSpent = g0 - gasleft();
        emit log_named_uint("finalizeCarpet gas (honest path, post-fix)", honestSpent);
        assertLt(honestSpent, 12_000_000, "honest finalize+spawn regressed");

        PSPFactory.Round memory r2 = factory.getRound(2);
        assertTrue(address(r2.controller) != address(0), "round 2 spawns on the retry block");
        bool dodged = true;
        for (uint256 i; i < 4; i++) {
            if (address(r2.hook) == cands[i]) dodged = false;
        }
        assertTrue(dodged, "retry hook is outside the squatted salt space");
    }
}
