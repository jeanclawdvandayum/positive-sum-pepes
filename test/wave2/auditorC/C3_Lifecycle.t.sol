// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CBase} from "./CBase.sol";
import {TokenDeployer} from "../../../src/ControllerDeployer.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {PSPFactory} from "../../../src/PSPFactory.sol";
import {PSPToken} from "../../../src/PSPToken.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title C-3 battery - round-chaining integrity, token authority handoff,
///        deployer-vessel assumptions, EIP-170 headroom, low-level call wiring.
contract C3_Lifecycle is CBase {
    /// The three factory callbacks RoundController invokes through raw
    /// factory.call() with precomputed selectors (EIP-170 optimization).
    /// A mismatch would silently call nothing (returns ok=true for missing
    /// functions? no - returns empty success for non-existent fallback-less
    /// targets, i.e. ok=false) - either way, verify them mathematically.
    function test_C3_SelectorConstants() public pure {
        assertEq(bytes4(keccak256("markDestroyed(uint256)")), bytes4(0x723c5612), "markDestroyed selector");
        assertEq(bytes4(keccak256("spawnNextRound(uint256)")), bytes4(0x1c9424dc), "spawnNextRound selector");
        assertEq(bytes4(keccak256("creditSidePot(uint256)")), bytes4(0xada2e425), "creditSidePot selector");
    }

    /// EIP-170: every deployed artifact must stay under 24 KiB - including
    /// the factory, both vessels, hook, token. Log sizes for the report.
    function test_C3_EIP170_Sizes() public {
        uint256 limit = 24576;
        _size("PSPFactory", address(factory), limit);
        _size("HookDeployer", address(hookDeployer), limit);
        _size("ControllerDeployer", address(controllerDeployer), limit);
        _size("CurveHook", address(hook1), limit);
        _size("PSPToken", address(psp1), limit);
        _size("RoundController", address(controller1), limit);
    }

    function _size(string memory what, address a, uint256 limit) internal {
        uint256 s = a.code.length;
        emit log_string(string.concat(what, " = ", vm.toString(s), " bytes (limit ", vm.toString(limit), ")"));
        assertLe(s, limit, string.concat(what, " exceeds EIP-170"));
    }

    /// C-2 (finding): the owner can deployRound a PARALLEL round mid-life of
    /// round 1. The new round becomes current; the old round's finalize-spawn
    /// then fails NotLatestRound forever. This is the only round-chaining
    /// corruption path (no other way to make two rounds "live"), and it needs
    /// owner action - but the factory then offers no reconciliation: the old
    /// round's reserve is stranded and its successor never spawns.
    function test_C3_ParallelRoundBricksOldChain() public {
        _launchRound1();
        _bombRound1();
        _warpPastFlatWindow();

        // owner sidesteps the chain and opens a parallel game
        vm.startPrank(address(factory.owner()));
        PSPFactory.RoundParams memory p = PSPFactory.RoundParams({
            name: "Parallel Game",
            symbol: "PAR",
            curveConfig: _curve()
        });
        factory.deployRound(p);
        vm.stopPrank();
        assertEq(factory.currentRoundId(), 2, "parallel round became current");

        // the dying round can never hand off now
        uint256 reserveLocked = mixETH.balanceOf(address(hook1));
        vm.prank(rando);
        vm.expectRevert(RoundController.FactorySpawnFailed.selector);
        controller1.finalizeCarpet();

        // direct path shows the exact guard
        vm.prank(address(controller1));
        factory.markDestroyed(1);
        vm.prank(rando);
        vm.expectRevert(PSPFactory.NotLatestRound.selector);
        factory.spawnNextRound(1);

        assertEq(mixETH.balanceOf(address(hook1)), reserveLocked, "old reserve stranded");
        assertTrue(factory.getRound(1).destroyed);
        assertFalse(factory.getRound(2).destroyed);
    }

    /// PSPToken authority handoff: factory is temp admin, controller is set
    /// exactly once, mint/burn gated to the controller, and the factory has
    /// no residual mint authority afterwards.
    function test_C3_TokenAuthority() public {
        // mint/burn from anyone (incl. the factory) - OnlyController
        vm.prank(address(factory));
        vm.expectRevert(PSPToken.OnlyController.selector);
        psp1.mint(alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(PSPToken.OnlyController.selector);
        psp1.burn(alice, 1e18);

        // setController: non-factory rejected; second call rejected
        vm.prank(rando);
        vm.expectRevert(PSPToken.OnlyFactory.selector);
        psp1.setController(rando);

        vm.prank(address(factory));
        vm.expectRevert(PSPToken.AlreadySet.selector);
        psp1.setController(address(controller1));
    }

    /// Deployer vessels are permissionless: anyone can deploy fake tokens and
    /// controllers through them. Verify the factory registry ignores fakes
    /// (rounds[] untouched, currentRoundId untouched) and the fake controller
    /// cannot reach factory callbacks (NotRoundController).
    function test_C3_VesselsPermissionlessButInert() public {
        uint256 roundsBefore = factory.currentRoundId();

        PSPToken fakeToken = new TokenDeployer().deployToken("Fake", "FK", rando);
        RoundController fakeController =
            controllerDeployer.deployController(fakeToken, IERC20(address(mixETH)), _curve(), rando);

        assertEq(factory.currentRoundId(), roundsBefore, "registry untouched");
        PSPFactory.Round memory r1 = factory.getRound(1);
        assertTrue(address(r1.token) != address(fakeToken));
        assertTrue(address(r1.controller) != address(fakeController));

        vm.prank(address(fakeController));
        vm.expectRevert(PSPFactory.NotRoundController.selector);
        factory.markDestroyed(1);

        vm.prank(address(fakeController));
        vm.expectRevert(PSPFactory.NotRoundController.selector);
        factory.creditSidePot(1);
    }

    /// deployRound is the only owner-gated entry; spawn/markDestroyed/credit
    /// hold without it. Non-owner deployRound reverts.
    function test_C3_DeployRoundOwnerOnly() public {
        vm.prank(rando);
        vm.expectRevert();
        factory.deployRound(
            PSPFactory.RoundParams({name: "x", symbol: "x", curveConfig: _curve()})
        );
    }

    /// The spawn's curve is inherited EXACTLY: gameCurve after spawn equals
    /// gameCurve before (P0 + zones), and the new hook carries the same zones
    /// (initCode determinism already proven by C-1's collision).
    function test_C3_CurveInheritanceExact() public {
        CurveMath.CurveConfig memory before = _gameCurveFromPublicState();
        _launchRound1();
        _bombRound1();
        _warpPastFlatWindow();
        controller1.finalizeCarpet();

        CurveHook hook2 = factory.getRound(2).hook;
        (uint256 p0After,) = factory.gameCurve();
        assertEq(p0After, before.P0, "P0 inherited");
        CurveMath.Zone[] memory zAfter = hook2.getCurveZones();
        assertEq(zAfter.length, before.zones.length, "zone count inherited");
        for (uint256 i; i < zAfter.length; i++) {
            assertEq(zAfter[i].startSupply, before.zones[i].startSupply);
            assertEq(zAfter[i].endSupply, before.zones[i].endSupply);
            assertEq(zAfter[i].rate, before.zones[i].rate);
            assertTrue(zAfter[i].isExponential == before.zones[i].isExponential);
        }
    }

    /// Round-2 naming: "<baseName> <id>" / "<baseSymbol><id>".
    function test_C3_SpawnNaming() public {
        _launchRound1();
        _bombRound1();
        _warpPastFlatWindow();
        controller1.finalizeCarpet();

        PSPFactory.Round memory r2 = factory.getRound(2);
        assertEq(r2.name, "Positive Sum Pepes 2");
        assertEq(r2.symbol, "PSP2");
        assertEq(PSPToken(address(r2.token)).name(), "Positive Sum Pepes 2");
        assertEq(PSPToken(address(r2.token)).symbol(), "PSP2");
    }
}
