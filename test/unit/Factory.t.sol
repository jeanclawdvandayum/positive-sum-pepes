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
import {CurveMath} from "../../src/libraries/CurveMath.sol";

import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

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

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();
        poolManager = new MockPoolManager();
        factory = new PSPFactory(IPoolManager(address(poolManager)), IERC20(address(mixETH)));

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

    function test_Gas_DeployRoundUnder10M() public {
        // The mining loop's iteration count is a geometric draw (1/16384 per
        // candidate for the 14 permission bits), so a single deployRound gas
        // number is a random variable — it cannot be bounded deterministically.
        // We bound a quantile instead: the CHEAPEST of 4 independent draws
        // (distinct round names -> distinct constructor args -> distinct
        // codeHashes) estimates the 25th percentile.
        //  - Fixed deploy cost is ~4M; median mining is ~2.5M (155 gas/iter x
        //    16384), so a typical draw lands ~6.5M total. P(all 4 draws > 10M)
        //    ~ 0.008% — effectively never.
        //  - With the H-2 regression (per-iteration cold EXTCODESIZE at 2600
        //    gas, or worse, re-hashing ~13.5KB of creation code at 8.3k
        //    gas/iter), even the MIN of 4 draws exceeds 35M -> hard fail.
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
        assertLt(minGas, 10_000_000, "deployRound gas must stay under 10M");
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
    //  L-1: carryToNextRound is owner-only
    // ═══════════════════════════════════════════════════════════════

    function test_L1_CarryToNextRoundOwnerOnly() public {
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

        // M-1 convention: locks must predate the proposal
        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);

        vm.warp(block.timestamp + 3 days + 1);
        controller.carpetBomb();

        (,,,,, bool canExecute) = controller.getCarpetBombState();
        assertFalse(canExecute, "proposal already executed");
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Destroyed), "round destroyed");

        // Attacker can no longer front-run the carry (L-1)
        uint256 factoryBalance = mixETH.balanceOf(address(factory));
        assertGt(factoryBalance, 0, "factory holds carried mixETH");

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker, address(this))
        );
        factory.carryToNextRound(1);

        // Factory balance untouched by the failed attempt
        assertEq(mixETH.balanceOf(address(factory)), factoryBalance, "no drain on failed attempt");

        // Owner path still works and sweeps the carry to owner()
        uint256 ownerBefore = mixETH.balanceOf(address(this));
        factory.carryToNextRound(1);
        assertEq(mixETH.balanceOf(address(factory)), 0, "factory drained");
        assertEq(
            mixETH.balanceOf(address(this)) - ownerBefore,
            factoryBalance,
            "owner received carry"
        );
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
}
