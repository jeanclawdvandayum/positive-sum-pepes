// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {StakerDeployer} from "../../src/StakerDeployer.sol";

import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @title StagedGenesisTest — the multi-tx genesis/rebirth path (2026-09-03)
/// @notice The post-clock-redesign composed birth is ~18.6-21M — over Base
///         Sepolia's ≈2^24 (16.78M) per-tx cap — so genesis runs as
///         reserveGenesis + 3× birthStep. These tests prove the split path
///         produces the same result as the composed one, is permissionless
///         after the reserve, fails closed on stale context, and keeps
///         every leg far under any per-tx cap.
contract StagedGenesisTest is Test {
    MockPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;

    address alice = makeAddr("alice");

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();
        poolManager = new MockPoolManager();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)),
            IERC20(address(mixETH)),
            new HookDeployer(),
            new ControllerDeployer(),
            new StakerDeployer(),
            0,
            address(this)
        );
        factory.setDescriptor(_descriptor1());
    }

    function _params() internal pure returns (PSPFactory.RoundParams memory) {
        return PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: CurveMath.singleCurve(
                0.001e18,        // P0
                1_000_000e18,    // inflection
                0.0000000046e18, // exp rate
                0.05e18          // log rate
            )
        });
    }

    function _descriptor1() internal pure returns (address) {
        return address(uint160(uint256(keccak256("descriptor"))));
    }

    function _descriptor2() internal pure returns (address) {
        return address(uint160(uint256(keccak256("descriptor-2"))));
    }

    /// Happy path: reserve (owner) → 3 birthSteps (a stranger pays the gas —
    /// the factory must not care who finishes the birth).
    function test_StagedGenesis_FullFlow() public {
        factory.reserveGenesis(_params());
        assertTrue(factory.reservationActive(), "reservation committed");
        assertEq(factory.reservationPhase(), 1, "phase CONTRACTS");
        assertEq(factory.currentRoundId(), 0, "nothing born yet");

        vm.prank(alice);
        factory.birthStep();
        assertEq(factory.reservationPhase(), 2, "phase PERIPHERY");
        vm.prank(alice);
        factory.birthStep();
        assertEq(factory.reservationPhase(), 3, "phase WIRE");
        assertEq(factory.currentRoundId(), 0, "still nothing born");

        vm.prank(alice);
        factory.birthStep();

        assertEq(factory.currentRoundId(), 1, "round 1 born");
        assertFalse(factory.reservationActive(), "reservation cleared");
        assertEq(factory.reservationPhase(), 0, "phase cleared");

        PSPFactory.Round memory r = factory.getRound(1);
        assertTrue(r.token != PSPToken(address(0)), "token");
        assertTrue(r.controller != RoundController(address(0)), "controller");
        assertTrue(r.hook != CurveHook(address(0)), "hook");
        assertEq(r.name, "Positive Sum Pepes", "name");
        assertEq(r.symbol, "PSP", "symbol");

        // wiring identical to the composed path
        RoundController c = r.controller;
        assertEq(address(c.hook()), address(r.hook), "hook wired");
        assertEq(address(PSPToken(address(r.token)).controller()), address(c), "token wired");
        assertTrue(c.stakerAddress() != address(0), "staker born");
        assertTrue(factory.referralRegistryOf(1) != address(0), "registry born");
        assertGt(c.PREDEPOSIT_DURATION(), 0, "timings landed");

        // no leftover state blocks the next reservation
        factory.reserveGenesis(_params());
        assertTrue(factory.reservationActive(), "re-reservable after birth");
        factory.voidReservation();
    }

    /// Every leg stays far under the tightest per-tx cap we target (Base
    /// Sepolia operator cap ≈ 16.78M). Create costs are chain-independent,
    /// so local numbers carry; the 2026-09-03 fork trace confirmed the
    /// split against real Base Sepolia state.
    function test_StagedGenesis_GasBounds() public {
        factory.reserveGenesis(_params());

        uint256 g0 = gasleft();
        factory.birthStep();
        uint256 leg1 = g0 - gasleft();

        g0 = gasleft();
        vm.prank(alice);
        factory.birthStep();
        uint256 leg2 = g0 - gasleft();

        g0 = gasleft();
        vm.prank(alice);
        factory.birthStep();
        uint256 leg3 = g0 - gasleft();

        console.log("birthStep CONTRACTS:", leg1);
        console.log("birthStep PERIPHERY:", leg2);
        console.log("birthStep WIRE:", leg3);
        assertLt(leg1, 10_000_000, "contracts leg over budget");
        assertLt(leg2, 10_000_000, "periphery leg over budget");
        assertLt(leg3, 2_000_000, "wire leg over budget");
    }

    /// Guards: birthStep without a reservation; double reserve; voided
    /// reservation; re-reserve after void.
    function test_StagedGenesis_Guards() public {
        vm.prank(alice);
        vm.expectRevert(PSPFactory.NoReservation.selector);
        factory.birthStep();

        factory.reserveGenesis(_params());
        vm.expectRevert(PSPFactory.ReservationActive.selector);
        factory.reserveGenesis(_params());

        factory.voidReservation();
        assertFalse(factory.reservationActive(), "voided");
        vm.prank(alice);
        vm.expectRevert(PSPFactory.NoReservation.selector);
        factory.birthStep();

        factory.reserveGenesis(_params());
        assertTrue(factory.reservationActive(), "re-reserved after void");
        factory.voidReservation();
    }

    /// Stale context fails CLOSED before any create: descriptor changed
    /// after the reserve → the contracts leg refuses (the controller's
    /// initcode embeds the descriptor — deploying with the new one would
    /// miss the committed prediction).
    function test_StagedGenesis_StaleDescriptorFailsClosed() public {
        factory.reserveGenesis(_params());
        factory.setDescriptor(_descriptor2());
        vm.expectRevert(PSPFactory.ReservationStale.selector);
        factory.birthStep();
        assertEq(factory.currentRoundId(), 0, "nothing leaked");
    }

    /// Stale context caught at the wire gate: descriptor changed after the
    /// phases that embedded it, before final wiring.
    function test_StagedGenesis_StaleDescriptorCaughtAtWire() public {
        factory.reserveGenesis(_params());
        factory.birthStep();
        factory.birthStep();
        factory.setDescriptor(_descriptor2());
        vm.prank(alice);
        vm.expectRevert(PSPFactory.ReservationStale.selector);
        factory.birthStep();
        assertEq(factory.currentRoundId(), 0, "round not recorded");
    }

    /// Rebirth through the split path: destroy round 1, reserveSpawn, then
    /// three stranger-paid birthSteps — round 2 inherits the carry.
    function test_StagedGenesis_RebirthSplit() public {
        factory.reserveGenesis(_params());
        factory.birthStep();
        factory.birthStep();
        factory.birthStep();

        PSPFactory.Round memory r1 = factory.getRound(1);
        mixETH.depositETH{value: 40e18}();
        mixETH.transfer(address(factory), 40e18);

        vm.prank(address(r1.controller));
        factory.markDestroyed(1);

        factory.reserveSpawn(1); // permissionless
        assertEq(factory.reservationPhase(), 1, "rebirth reserved");

        vm.prank(alice);
        factory.birthStep();
        vm.prank(alice);
        factory.birthStep();
        vm.expectEmit(true, true, true, true, address(factory));
        emit PSPFactory.ETHCarried(1, 2, 40e18);
        vm.prank(alice);
        factory.birthStep();

        assertEq(factory.currentRoundId(), 2, "round 2 born");
        PSPFactory.Round memory r2 = factory.getRound(2);
        assertEq(r2.name, "Positive Sum Pepes 2", "round 2 name");
        assertEq(r2.symbol, "PSP2", "round 2 symbol");
        assertTrue(r2.controller != r1.controller, "fresh controller");
        assertTrue(factory.referralRegistryOf(2) != address(0), "registry wired");
    }

    /// The composed paths (deployRound / spawnNextRound / birthRound) still
    /// exist and behave for uncapped chains (anvil, mainnet).
    function test_StagedGenesis_ComposedPathsIntact() public {
        (uint256 roundId, address hookAddr) = factory.deployRound(_params());
        assertEq(roundId, 1, "composed genesis");
        assertTrue(hookAddr != address(0), "composed hook");

        PSPFactory.Round memory r1 = factory.getRound(1);
        mixETH.depositETH{value: 40e18}();
        mixETH.transfer(address(factory), 40e18);
        vm.prank(address(r1.controller));
        factory.markDestroyed(1);

        factory.reserveSpawn(1);
        (uint256 rid2, address hook2) = factory.birthRound();
        assertEq(rid2, 2, "composed rebirth");
        assertTrue(hook2 != address(0), "composed rebirth hook");
        assertEq(factory.getRound(2).name, "Positive Sum Pepes 2", "composed naming");
    }
}
