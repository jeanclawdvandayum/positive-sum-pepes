// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
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
/// @notice SpawnStaging pins the staged legs on the 2-zone playtest curve;
///         round 2 on Base Sepolia runs the canonical 34-zone staircase.
///         These canaries measure the FAT-curve costs of every staged leg
///         so the deploy docs can cite real numbers, not estimates:
///         genesis deployRound (reserve+birth composed), permissionless
///         reserveSpawn, and birthRound.
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
            0
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

    /// Rebirth: kill → reserve (bounded mine, retry semantics) → birth,
    /// all 34 zones, permissionless callers. The claim the redesign makes:
    /// birth is variance-free and fits EVERY per-tx cap — Sepolia's 2^24
    /// is the strictest one in production.
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

        uint256 g0 = gasleft();
        factory.birthRound(); // rando can call; test contract is fine too
        uint256 gBirth = g0 - gasleft();
        console2.log("birthRound 34-zone:", gBirth);

        assertEq(factory.currentRoundId(), 2, "round 2 born");
        assertTrue(address(factory.getRound(2).hook) != address(0), "hook exists");
        assertTrue(gBirth < 16_777_216, "34-zone birth must fit Sepolia's 2^24 per-tx cap");
        assertTrue(gReserve < 16_777_216, "34-zone reserve must fit Sepolia's 2^24 per-tx cap");
    }
}
