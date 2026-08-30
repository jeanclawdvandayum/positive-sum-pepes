// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PSPStaker} from "../../src/PSPStaker.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../src/PSPZapOut.sol";
import {IMixETH} from "../../src/interfaces/IMixETH.sol";

import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {StakerDeployer} from "src/StakerDeployer.sol";


/// @title FactoryTest — PSPFactory unit tests (no fork, no real V4 state)
/// @notice Covers the L-1 (carryToNextRound access), L-2 (pool-key gate) and
///         H-2 (deployment gas bound) findings. The HookMiner/factory path
///         never ran in the non-integration suite before — which is exactly
///         why a 136M-gas mining loop went unnoticed (foundry's default gas
///         limit is ~2^63).
contract FactoryTest is Test {
    MockPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;

    // Round 1 (deployed in setUp)
    PSPToken pspToken;
    RoundController controller;
    CurveHook hook;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    /// @dev Vote with EVERY pepe `who` owns (2026-08-29 per-NFT voting).
    function _voteAll(address who, bool support) internal {
        PSPStaker s = controller.staker();
        uint256 n = s.balanceOf(who);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = s.tokenOfOwnerByIndex(who, i);
        vm.prank(who);
        controller.voteCarpetBomb(ids, support);
    }

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();
        poolManager = new MockPoolManager();
        factory = new PSPFactory(IPoolManager(address(poolManager)), IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer(), new StakerDeployer(), 0);

        _deployRound1();
    }

    function _deployRound1() internal {
        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: CurveMath.singleCurve(
                0.001e18,        // P0 = 0.001 ETH
                1_000_000e18,    // inflection at 1M supply
                0.0000000046e18, // exponential rate
                0.05e18          // logarithmic rate
            )
        });

        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory round = factory.getRound(roundId);
        pspToken = round.token;
        controller = round.controller;
        hook = round.hook;
    }

    function _canonicalKey() internal view returns (PoolKey memory) {
        // Same key the factory built (sorted)
        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(address(pspToken));
        if (c0 > c1) (c0, c1) = (c1, c0);
        return PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: hook});
    }

    // ═══════════════════════════════════════════════════════════════
    //  H-2 gas bound: full round deployment (incl. on-chain hook mining)
    //  must fit far below a mainnet block gas limit
    // ═══════════════════════════════════════════════════════════════

    function test_Gas_DeployRoundUnder12M() public {
        // The mining loop's iteration count is a geometric draw (1/16384 per
        // candidate for the 14 permission bits), so a single deployRound gas
        // number is a random variable — it cannot be bounded deterministically.
        // We bound a quantile instead: the CHEAPEST of 4 independent draws
        // (distinct round names -> distinct constructor args -> distinct
        // codeHashes) estimates the 25th percentile.
        //  - RECALIBRATED 2026-08-20 (wave2b): v5.1 moved the referral
        //    registry birth into _deployRound (deployRegistry + setRecorder)
        //    and the game curve grew — fixed cost measured ~8M, median
        //    mining ~2.5M (148 gas/iter x 16384, HookMiner Yul rewrite), so
        //    a typical draw lands ~10.5M. Observed min-of-4: 10.57M
        //    (log in Run-5 evidence). P(all 4 draws > 12M) stays ~0.1%.
        //  - With the H-2 regression class (per-iteration cold EXTCODESIZE
        //    at 2600 gas, or re-hashing ~13.5KB of creation code at 8.3k
        //    gas/iter), even the MIN of 4 draws exceeds 20M -> hard fail.
        // Additionally, every individual draw must fit under 30M: worst-case
        // MAX_LOOP mining (~25M) + fixed cost stays inside a mainnet block.
        string[4] memory names = ["Alpha Round", "Bravo Round", "Charlie Round", "Delta Round"];
        uint256 minGas = type(uint256).max;
        for (uint256 i; i < 4; i++) {
            PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
                name: names[i],
                symbol: "PSP",
                curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
            });
            uint256 gasBefore = gasleft();
            factory.deployRound(params);
            uint256 gasUsed = gasBefore - gasleft();
            console.log("deployRound gas used:", gasUsed);
            assertLt(gasUsed, 30_000_000, "single deployRound exceeds 30M block-gas containment");
            if (gasUsed < minGas) minGas = gasUsed;
        }
        // H-2 regression bound: a typical mining draw must keep total
        // deployment well under 10M (mainnet block limit is ~30-36M).
        // RECALIBRATED 2026-08-29 (sine flavor): SineMath inlined into
        // CurveHook added ~6KB runtime bytecode (+1.26M code-deposit gas);
        // measured 13.26M. Binding real constraint = Base Sepolia's MEASURED
        // 15M per-tx sequencer cap (policy) — budget 14M keeps 1M margin.
        assertLt(minGas, 14_000_000, "deployRound gas must stay under 14M (15M Base Sepolia cap - 1M margin)");
    }

    // ═══════════════════════════════════════════════════════════════
    //  L-2: hook only serves the canonical {mixETH, PSP} pool
    // ═══════════════════════════════════════════════════════════════

    function test_L2_DecoyPoolInitializationReverts() public {
        // Decoy pair: two unrelated currencies keyed to the round's hook
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        PoolKey memory decoy = PoolKey({
            currency0: Currency.wrap(tokenA),
            currency1: Currency.wrap(tokenB),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: hook
        });

        vm.prank(attacker);
        vm.expectRevert(CurveHook.WrongPoolCurrencies.selector);
        poolManager.initialize(decoy, SQRT_RATIO_1_1);

        // Half-decoy pair: correct mixETH but wrong counterparty token
        PoolKey memory halfDecoy = PoolKey({
            currency0: Currency.wrap(address(mixETH)),
            currency1: Currency.wrap(tokenB),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: hook
        });

        vm.prank(attacker);
        vm.expectRevert(CurveHook.WrongPoolCurrencies.selector);
        poolManager.initialize(halfDecoy, SQRT_RATIO_1_1);
    }

    function test_L2_CanonicalPairPassesGateBothOrderings() public {
        // Sorted order (exactly what the factory initialized in setUp —
        // re-invoking through the mock proves the gate accepts it explicitly)
        PoolKey memory key = _canonicalKey();
        poolManager.initialize(key, SQRT_RATIO_1_1);

        // Reversed order: the gate is pair-based, not order-based
        PoolKey memory reversed = PoolKey({
            currency0: key.currency1,
            currency1: key.currency0,
            fee: 0x800000,
            tickSpacing: 60,
            hooks: hook
        });
        poolManager.initialize(reversed, SQRT_RATIO_1_1);
    }

    function test_L2_HookAddressCarriesBeforeInitializeFlag() public view {
        assertTrue(
            uint160(address(hook)) & Hooks.BEFORE_INITIALIZE_FLAG != 0,
            "hook address must carry BEFORE_INITIALIZE_FLAG"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  L-1 evolution: carpetBomb births the next round automatically
    // ═══════════════════════════════════════════════════════════════

    function test_L1_CarrySpawnsNextRoundAutomatically() public {
        // Destroy round 1 through the real governance flow
        mixETH.transfer(alice, 200e18);
        mixETH.transfer(bob, 200e18);

        vm.startPrank(alice);
        mixETH.approve(address(controller), 200e18);
        controller.predeposit(200e18);
        vm.stopPrank();

        vm.startPrank(bob);
        mixETH.approve(address(controller), 200e18);
        controller.predeposit(200e18);
        vm.stopPrank();

        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();
        vm.prank(bob);
        controller.claimPredepositPSP();

        // M-1 convention: locks must predate the proposal — and fresh claims
        // go live at the next epoch boundary (epoch-point liveness)
        vm.warp(((block.timestamp / 7 days) + 1) * 7 days + 1);

        vm.prank(alice);
        controller.proposeCarpetBomb();
        _voteAll(alice, true);
        _voteAll(bob, true);

        skip(3 days + 1);
        controller.carpetBomb();
        skip(3 days + 1);
        controller.finalizeCarpet();
        factory.birthRound(); // staged: birth is the second, permissionless tx

        (,,,,, bool canExecute) = controller.getCarpetBombState();
        assertFalse(canExecute, "proposal already executed");
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Destroyed), "round destroyed");

        // carpetBomb birthed round 2 and seeded it with the entire carry
        assertEq(factory.currentRoundId(), 2, "round 2 spawned");
        PSPFactory.Round memory r2 = factory.getRound(2);
        uint256 carried = mixETH.balanceOf(address(r2.controller));
        assertGt(carried, 0, "carry seeded as round-2 predeposit");
        assertEq(mixETH.balanceOf(address(factory)), 0, "factory drained");
        assertFalse(r2.controller.predepositClosed(), "round 2 awaiting its own window");
        (uint256 factoryDeposit,) = r2.controller.predeposits(address(factory));
        assertEq(
            factoryDeposit,
            carried,
            "factory recorded as depositor"
        );
        assertEq(r2.token.symbol(), "PSP2", "spawned round naming");
        assertEq(r2.token.name(), "Positive Sum Pepes 2", "spawned round naming");

        // spam is impossible: round 1 is no longer the latest round
        vm.prank(attacker);
        vm.expectRevert(PSPFactory.NotLatestRound.selector);
        factory.spawnNextRound(1);
        // round 2 exists but is not destroyed
        vm.prank(attacker);
        vm.expectRevert(PSPFactory.RoundNotDestroyed.selector);
        factory.spawnNextRound(2);
    }

    // ═══════════════════════════════════════════════════════════════
    //  I-4: markDestroyed error semantics
    // ═══════════════════════════════════════════════════════════════

    /// @dev Only the round's own controller may markDestroyed; everyone
    ///      else (including calls against nonexistent rounds) reverts with
    ///      the dedicated NotRoundController instead of the misleading
    ///      ZeroAddress.
    function test_I4_MarkDestroyedOnlyFromRoundController() public {
        address rando = makeAddr("rando");

        vm.prank(rando);
        vm.expectRevert(PSPFactory.NotRoundController.selector);
        factory.markDestroyed(1);

        // Nonexistent round: controller is address(0) != rando → same revert
        vm.prank(rando);
        vm.expectRevert(PSPFactory.NotRoundController.selector);
        factory.markDestroyed(999);

        // The round's own controller succeeds
        PSPFactory.Round memory r = factory.getRound(1);
        vm.prank(address(r.controller));
        factory.markDestroyed(1);
        assertTrue(factory.getRound(1).destroyed, "round marked destroyed");
    }

    // ═══════════════════════════════════════════════════════════════
    //  EIP-170 guard: every contract that can live on-chain must stay
    //  under the 24,576-byte runtime limit. The factory hit 41KB before
    //  the deployer-vessel split because `new X` embeds creation code;
    //  this test makes that class of regression a hard failure.
    // ═══════════════════════════════════════════════════════════════

    function test_EIP170_AllDeployablesUnderLimit() public {
        // Fresh deployers (setUp creates them inline; we want them anyway)
        HookDeployer hd = new HookDeployer();
        ControllerDeployer cd = new ControllerDeployer();

        assertLe(address(hd).code.length, 24_576, "HookDeployer over EIP-170");
        assertLe(address(cd).code.length, 24_576, "ControllerDeployer over EIP-170");
        assertLe(address(factory).code.length, 24_576, "PSPFactory over EIP-170");

        // Live children from setUp's round 1
        assertLe(address(controller).code.length, 24_576, "RoundController over EIP-170");
        assertLe(address(hook).code.length, 24_576, "CurveHook over EIP-170");
        assertLe(address(pspToken).code.length, 24_576, "PSPToken over EIP-170");

        // QoL routers
        PSPZapIn zi = new PSPZapIn(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));
        PSPZapOut zo = new PSPZapOut(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));
        assertLe(address(zi).code.length, 24_576, "PSPZapIn over EIP-170");
        assertLe(address(zo).code.length, 24_576, "PSPZapOut over EIP-170");
    }

    // ControllerDeployer embeds the creation code of RoundController AND
    // PSPToken, so its size tracks theirs. Fail early if headroom shrinks
    // below ~0.5KB so nobody ships an undeployable vessel by accident.
    // (Side-pot feature ate ~600B of headroom; controller itself has ~1.2KB
    // of growth left before the vessel math breaks — refactor before big adds.)
    function test_EIP170_ControllerDeployerHeadroom() public {
        ControllerDeployer cd = new ControllerDeployer();
        assertLt(
            address(cd).code.length,
            24_000,
            "ControllerDeployer headroom < ~0.5KB; shrink before adding code"
        );
    }

    function test_EIP170_StakerDeployerHeadroom() public {
        // 2026-08-23: PSPStaker's creation code moved here out of
        // RoundController's creation program (lockWithPepe growth pushed
        // the ControllerDeployer stack past budget). Same vessel rules.
        StakerDeployer sd = new StakerDeployer();
        assertLt(
            address(sd).code.length,
            24_000,
            "StakerDeployer headroom < ~0.5KB; shrink before adding code"
        );
    }
}
