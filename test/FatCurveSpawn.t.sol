// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {SineV3Math} from "src/SineV3Math.sol";
import {SineV3Data} from "src/SineV3Data.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {RoundController} from "../src/RoundController.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {ControllerDeployer} from "../src/ControllerDeployer.sol";
import {StakerDeployer} from "../src/StakerDeployer.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {LinearZones} from "../src/curves/LinearZones.sol";

import {MockMixETH} from "./mocks/MockMixETH.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

/// @title FatCurveSpawn — 34-zone staged-spawn gas canaries (2026-08-30)
/// @notice The legacy 34-zone curve remains reachable through the factory.
///         Measure its composed convenience path and prove the current release's
///         reserve + three birthStep transactions each fit the deployment cap.
contract FatCurveSpawn is Test {
    MockPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 2_000_000e18}();
        poolManager = new MockPoolManager();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)),
            IERC20(address(mixETH)),
            new HookDeployer(),
            new ControllerDeployer(),
            new StakerDeployer(),
            address(new SineV3Math(SineV3Data.deploy())),
            0,
            address(this) // deployerCutTo (CLOCK-REDESIGN §3)
        );
    }

    function _deployFatRound1() internal returns (RoundController controller1) {
        PSPFactory.RoundParams memory p = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: LinearZones.config()
        });
        (uint256 roundId,) = factory.deployRound(p);
        controller1 = factory.getRound(roundId).controller;
    }

    /// Genesis: the composed one-tx shim (reserve + birth) at 34 zones.
    /// Logged, not capped — the 34-zone genesis is a mainnet/OP-stack
    /// artifact by design (see DeployPSP PSP_CURVE docs).
    function test_gas_genesis34() public {
        uint256 g0 = gasleft();
        RoundController c1 = _deployFatRound1();
        console2.log("genesis deployRound 34-zone (composed reserve+birth):", g0 - gasleft());
        assertTrue(address(c1) != address(0), "round 1 born");
    }

    /// AUD-15: adding registry purchase code increases the composed birth cost.
    /// READINESS.md requires the existing three-step birth path on capped chains.
    /// Preserve the composed measurement, then enforce a stricter 12M per-step
    /// budget on the SAME reserved round instead of raising the old 2^24 limit.
    function test_gas_rebirth34() public {
        RoundController c1 = _deployFatRound1();

        vm.prank(address(c1));
        factory.markDestroyed(1);

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
            console2.log("reserveSpawn 34-zone (attempts incl. tail retries):", attempts);
            console2.log("reserveSpawn 34-zone gas (successful attempt):", gReserve);
        }

        uint256 checkpoint = vm.snapshotState();
        uint256 g0 = gasleft();
        factory.birthRound(); // rando can call; test contract is fine too
        uint256 gBirth = g0 - gasleft();
        console2.log("birthRound 34-zone:", gBirth);

        assertEq(factory.currentRoundId(), 2, "round 2 born");
        assertTrue(address(factory.getRound(2).hook) != address(0), "hook exists");
        assertTrue(vm.revertToState(checkpoint), "restore the reserved round");
        for (uint256 phase = 1; phase <= 3; phase++) {
            assertEq(factory.reservationPhase(), phase, "resume the expected phase");
            uint256 stepStart = gasleft();
            factory.birthStep{gas: 12_000_000}();
            uint256 spent = stepStart - gasleft();
            console2.log("34-zone birth phase / gas:", phase, spent);
            assertLt(spent, 12_000_000, "every release birth transaction stays below 12M");
        }
        assertEq(factory.currentRoundId(), 2, "split round 2 born");
        assertFalse(factory.reservationActive(), "birth complete");
        assertTrue(address(factory.getRound(2).hook) != address(0), "split hook exists");
        assertTrue(gReserve < 16_777_216, "34-zone reserve must fit Sepolia's 2^24 per-tx cap");
    }
}
