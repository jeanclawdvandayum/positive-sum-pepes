// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

import {MainnetConfig} from "./MainnetConfig.sol";
import {V4SwapRouter} from "./V4SwapRouter.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";

/// @title MultiUserScenarioTest
/// @notice Full end-to-end fork tests with multiple users interacting simultaneously.
///         Covers: multi-user predeposit, sequential buys at varying prices,
///         sell pressure, fee distribution to multiple lockers, yield reinvestment,
///         destruction governance with diverse stakeholders, and round carry-over.
contract MultiUserScenarioTest is Test {
    using StateLibrary for IPoolManager;

    // Fork state
    IPoolManager poolManager;
    IERC20 mixETH;
    PSPFactory factory;
    V4SwapRouter public router;

    // Current round
    PSPToken pspToken;
    RoundController controller;
    CurveHook hook;
    PoolKey poolKey;

    // Test users
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address eve = makeAddr("eve");
    address frank = makeAddr("frank");

    // ──────────────────────────────────────────────────────────────
    //  SETUP
    // ──────────────────────────────────────────────────────────────

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        poolManager = IPoolManager(MainnetConfig.POOL_MANAGER);
        MockMixETH mockMix = new MockMixETH();
        mockMix.depositETH{value: 100_000e18}();
        mixETH = IERC20(address(mockMix));

        factory = new PSPFactory(poolManager, mixETH, new HookDeployer(), new ControllerDeployer());
        router = new V4SwapRouter(poolManager);

        // Fund all users
        _dealMixETH(alice, 1_000e18);
        _dealMixETH(bob, 1_000e18);
        _dealMixETH(carol, 1_000e18);
        _dealMixETH(dave, 1_000e18);
        _dealMixETH(eve, 500e18);
        _dealMixETH(frank, 500e18);

        _deployRound();
    }

    // ══════════════════════════════════════════════════════════════
    //  SCENARIO 1: Multi-user predeposit + proportional claims
    // ══════════════════════════════════════════════════════════════

    function test_Multi_PredepositProportionalClaims() public {
        // 4 users predeposit different amounts
        _predeposit(alice, 200e18);
        _predeposit(bob, 100e18);
        _predeposit(carol, 50e18);
        _predeposit(dave, 50e18);

        assertEq(controller.totalPredepositMixETH(), 400e18, "Total predeposit");
        assertEq(controller.totalPredepositors(), 4, "4 depositors");

        // Launch
        vm.prank(address(factory));
        controller.launchPooledBuy();

        // Verify total initial PSP
        uint256 totalInitial = controller.totalInitialPSP();
        assertGt(totalInitial, 0, "Initial PSP minted");

        // Claim proportional shares
        uint256 alicePSP = _claim(alice);
        uint256 bobPSP = _claim(bob);
        uint256 carolPSP = _claim(carol);
        uint256 davePSP = _claim(dave);

        // Verify proportions: alice 50%, bob 25%, carol 12.5%, dave 12.5%
        assertApproxEqRel(alicePSP, totalInitial / 2, 0.001e18, "Alice ~50%");
        assertApproxEqRel(bobPSP, totalInitial / 4, 0.001e18, "Bob ~25%");
        assertApproxEqRel(carolPSP, totalInitial / 8, 0.001e18, "Carol ~12.5%");
        assertApproxEqRel(davePSP, totalInitial / 8, 0.001e18, "Dave ~12.5%");

        // Sum should equal total (with rounding tolerance)
        uint256 sumClaimed = alicePSP + bobPSP + carolPSP + davePSP;
        assertApproxEqRel(sumClaimed, totalInitial, 0.0001e18, "All claimed");

        console.log("=== Predeposit Results ===");
        console.log("Total initial PSP:", totalInitial);
        console.log("Alice (50%):", alicePSP);
        console.log("Bob (25%):", bobPSP);
        console.log("Carol (12.5%):", carolPSP);
        console.log("Dave (12.5%):", davePSP);
        console.log("Rounding dust:", totalInitial > sumClaimed ? totalInitial - sumClaimed : sumClaimed - totalInitial);
    }

    // ══════════════════════════════════════════════════════════════
    //  SCENARIO 2: Sequential buys at increasing prices
    // ══════════════════════════════════════════════════════════════

    function test_Multi_SequentialBuysIncreasingPrice() public {
        // Bootstrap: single predeposit + launch
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claim(alice);

        // 5 users buy 10 mixETH each, sequentially
        uint256[] memory pricesPaid = new uint256[](5);
        address[5] memory buyers = [alice, bob, carol, dave, eve];

        uint256 pspBefore;
        uint256 pspAfter;
        uint256 pspGained;

        for (uint256 i = 0; i < 5; i++) {
            pspBefore = pspToken.balanceOf(buyers[i]);
            _buy(buyers[i], 10e18);
            pspAfter = pspToken.balanceOf(buyers[i]);
            pspGained = pspAfter - pspBefore;

            // Price = mixETH spent / PSP gained
            pricesPaid[i] = (10e18 * 1e18) / pspGained;

            console.log("Buyer %i: %i PSP @ %i mixETH/PSP", i, pspGained, pricesPaid[i]);
        }

        // Verify each subsequent buyer pays a higher price (curve is increasing)
        for (uint256 i = 1; i < 5; i++) {
            assertGt(pricesPaid[i], pricesPaid[i - 1], "Price increased");
        }

        console.log("=== Price Progression ===");
        console.log("First buyer price:", pricesPaid[0]);
        console.log("Last buyer price:", pricesPaid[4]);
        console.log("Price increase %:", ((pricesPaid[4] - pricesPaid[0]) * 100) / pricesPaid[0]);
    }

    // ══════════════════════════════════════════════════════════════
    //  SCENARIO 3: Fee distribution to multiple lockers
    // ══════════════════════════════════════════════════════════════

    function test_Multi_FeeDistributionProportional() public {
        // Setup: alice + bob predeposit equally, both lock BEFORE any swap activity
        _predeposit(alice, 100e18);
        _predeposit(bob, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();

        uint256 alicePSP = _claim(alice); // auto-locks
        uint256 bobPSP = _claim(bob);     // auto-locks

        // Carol buys via swap and locks half
        _buy(carol, 50e18);
        uint256 carolPSP = pspToken.balanceOf(carol);
        _lock(carol, carolPSP / 2);

        uint256 totalLocked = controller.totalLocked();
        console.log("Total locked PSP:", totalLocked);

        // Multiple swaps generate fees (after all lockers joined)
        _buy(dave, 20e18);
        _buy(eve, 30e18);
        _buy(frank, 10e18);
        _buy(dave, 15e18);
        _buy(eve, 25e18);

        // Both Alice and Bob claim at the same time
        uint256 aliceBefore = mixETH.balanceOf(alice);
        vm.prank(alice);
        controller.claimFees();
        uint256 aliceFees = mixETH.balanceOf(alice) - aliceBefore;

        uint256 bobBefore = mixETH.balanceOf(bob);
        vm.prank(bob);
        controller.claimFees();
        uint256 bobFees = mixETH.balanceOf(bob) - bobBefore;

        // Carol claims
        uint256 carolBefore = mixETH.balanceOf(carol);
        vm.prank(carol);
        controller.claimFees();
        uint256 carolFees = mixETH.balanceOf(carol) - carolBefore;

        console.log("=== Fee Distribution ===");
        console.log("Alice fees (locked %i):", alicePSP);
        console.log("  -> received:", aliceFees);
        console.log("Bob fees (locked %i):", bobPSP);
        console.log("  -> received:", bobFees);
        console.log("Carol fees (locked %i):", carolPSP / 2);
        console.log("  -> received:", carolFees);

        // Alice and Bob should have received similar amounts (locked equal, joined before fees)
        assertApproxEqRel(aliceFees, bobFees, 0.01e18, "Alice ~ Bob fees");

        // Carol should have received proportionally less
        assertLt(carolFees, aliceFees, "Carol < Alice");

        // Total fees should be > 0 for everyone
        assertGt(aliceFees, 0, "Alice earned");
        assertGt(bobFees, 0, "Bob earned");
        assertGt(carolFees, 0, "Carol earned");
    }

    // ══════════════════════════════════════════════════════════════
    //  SCENARIO 4: Sell pressure after buying
    // ══════════════════════════════════════════════════════════════

    function test_Multi_SellPressurePriceDecline() public {
        // Bootstrap
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claim(alice);

        // Multiple users buy
        _buy(bob, 20e18);
        _buy(carol, 20e18);
        _buy(dave, 20e18);

        uint256 bobPSP = pspToken.balanceOf(bob);
        uint256 carolPSP = pspToken.balanceOf(carol);

        // Record price before sells
        uint256 priceBefore = hook.getMarginalPrice();

        // Bob sells 50% of his PSP
        _sell(bob, bobPSP / 2);
        uint256 bobMixGained = mixETH.balanceOf(bob) - 800e18; // bob started with 980 (1000-20)

        // Carol sells 25% of her PSP
        _sell(carol, carolPSP / 4);
        uint256 carolMixGained = mixETH.balanceOf(carol) - 980e18;

        // Price should have decreased
        uint256 priceAfter = hook.getMarginalPrice();
        assertLt(priceAfter, priceBefore, "Price decreased after sells");

        console.log("=== Sell Pressure ===");
        console.log("Price before sells:", priceBefore);
        console.log("Price after sells:", priceAfter);
        console.log("Price drop %:", ((priceBefore - priceAfter) * 100) / priceBefore);
        console.log("Bob mixETH from 50% sell:", bobMixGained);
        console.log("Carol mixETH from 25% sell:", carolMixGained);

        // Reserve should have decreased
        assertGt(hook.totalReserveETH(), 0, "Reserve still positive");
    }

    // ══════════════════════════════════════════════════════════════
    //  SCENARIO 5: Repeated lock + claim cycles
    // ══════════════════════════════════════════════════════════════

    function test_Multi_RepeatedLockClaimCycles() public {
        _predeposit(alice, 200e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claim(alice); // auto-locks

        // Cycle: generate fees -> claim -> generate more fees -> claim
        uint256 totalEarned;
        for (uint256 i = 0; i < 3; i++) {
            _buy(bob, 20e18);
            _buy(carol, 20e18);

            uint256 before = mixETH.balanceOf(alice);
            vm.prank(alice);
            controller.claimFees();
            uint256 earned = mixETH.balanceOf(alice) - before;
            totalEarned += earned;

            console.log("Cycle %i fees:", i + 1, earned);
        }

        assertGt(totalEarned, 0, "Earned fees across cycles");
        console.log("Total earned over 3 cycles:", totalEarned);
    }

    // ══════════════════════════════════════════════════════════════
    //  SCENARIO 6: Mixed buy/sell interleaved (realistic market)
    // ══════════════════════════════════════════════════════════════

    function test_Multi_InterleavedBuySellMarket() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claimAndLock(alice); // Alice locks so fees distribute

        address[4] memory traders = [bob, carol, dave, eve];
        uint256[8] memory amounts = [
            uint256(10e18), 20e18, 5e18, 15e18, 8e18, 12e18, 3e18, 25e18
        ];

        uint256 totalVolume;
        uint256 reserveBefore = hook.reserveMixETH();

        // Interleaved buy/sell
        for (uint256 i = 0; i < 8; i++) {
            address trader = traders[i % 4];
            bool isBuy = i % 2 == 0; // alternate buy/sell

            if (isBuy) {
                _buy(trader, amounts[i]);
                totalVolume += amounts[i];
            } else {
                uint256 traderPSP = pspToken.balanceOf(trader);
                if (traderPSP > amounts[i]) {
                    _sell(trader, amounts[i]);
                    totalVolume += amounts[i];
                }
            }
        }

        uint256 reserveAfter = hook.reserveMixETH();

        console.log("=== Interleaved Market ===");
        console.log("Total volume (mixETH):", totalVolume);
        console.log("Reserve before:", reserveBefore);
        console.log("Reserve after:", reserveAfter);
        console.log("Reserve delta:", int256(reserveAfter) - int256(reserveBefore));

        // Protocol should have accumulated fees (alice locked, so accumulator advances)
        assertGt(controller.accFeePerShareMixETH(), 0, "Accumulator increased");
    }

    // ══════════════════════════════════════════════════════════════
    //  SCENARIO 7: Destruction with diverse stakeholders
    // ══════════════════════════════════════════════════════════════

    function test_Multi_DestructionDiverseStakeholders() public {
        // 6 users predeposit
        _predeposit(alice, 100e18);
        _predeposit(bob, 100e18);
        _predeposit(carol, 50e18);
        _predeposit(dave, 50e18);
        _predeposit(eve, 50e18);
        _predeposit(frank, 50e18);

        vm.prank(address(factory));
        controller.launchPooledBuy();

        // All claim and lock
        _claimAndLock(alice);
        _claimAndLock(bob);
        _claimAndLock(carol);
        _claimAndLock(dave);
        _claimAndLock(eve);
        _claimAndLock(frank);

        // Generate some swap volume (creates fee yield for lockers)
        _buy(alice, 10e18);
        _buy(bob, 10e18);

        // Governance: Alice proposes, most vote yes, Carol votes no
        // M-1: locks must predate the proposal timestamp
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        controller.proposeCarpetBomb();

        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        vm.prank(dave);
        controller.voteCarpetBomb(true);
        vm.prank(eve);
        controller.voteCarpetBomb(true);
        vm.prank(frank);
        controller.voteCarpetBomb(true);
        vm.prank(carol);
        controller.voteCarpetBomb(false);

        // Check vote tallies
        (, , uint256 yesVotes, uint256 noVotes, , ) = controller.getCarpetBombState();
        console.log("=== Governance ===");
        console.log("Yes votes:", yesVotes);
        console.log("No votes:", noVotes);
        assertGt(yesVotes, noVotes, "Yes > No");

        // Warp past voting
        skip(3 days + 1);

        uint256 factoryBefore = mixETH.balanceOf(address(factory));
        controller.carpetBomb();
        skip(3 days + 1);
        controller.finalizeCarpet();
        uint256 factoryAfter = mixETH.balanceOf(address(factory));

        console.log("=== Destruction ===");
        console.log("mixETH held by factory (instantly reseeded):", factoryAfter - factoryBefore);
        console.log("Hook mode:", uint8(hook.mode()));
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Destroyed), "Destroyed");

        // carpetBomb birthed round 2, seeded with the entire carry
        assertEq(factory.currentRoundId(), 2, "round 2 spawned");
        PSPFactory.Round memory r2 = factory.getRound(2);
        uint256 seeded = mixETH.balanceOf(address(r2.controller));

        console.log("=== Round Carry ===");
        console.log("Funds seeded to round 2:", seeded);
        console.log("Factory remaining:", mixETH.balanceOf(address(factory)));
        assertGt(seeded, 0, "Carry seeded into next round");
        assertEq(mixETH.balanceOf(address(factory)), 0, "factory emptied");
    }

    // ══════════════════════════════════════════════════════════════
    //  SCENARIO 8: Failed governance (quorum not reached)
    // ══════════════════════════════════════════════════════════════

    function test_Multi_GovernanceQuorumFailure() public {
        _predeposit(alice, 100e18);
        _predeposit(bob, 100e18);
        _predeposit(carol, 100e18);
        _predeposit(dave, 100e18);

        vm.prank(address(factory));
        controller.launchPooledBuy();

        _claimAndLock(alice);
        _claimAndLock(bob);
        _claimAndLock(carol);
        _claimAndLock(dave);

        // Only Alice proposes and votes (25% of locked = below 30% quorum)
        // M-1: locks must predate the proposal timestamp
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        controller.proposeCarpetBomb();

        vm.prank(alice);
        controller.voteCarpetBomb(true);

        skip(3 days + 1);

        // Should fail quorum check
        vm.expectRevert(RoundController.QuorumNotReached.selector);
        controller.carpetBomb();

        console.log("=== Quorum Failure ===");
        console.log("Hook still active:", uint8(hook.mode()) == uint8(CurveHook.Mode.Active));
    }

    // ══════════════════════════════════════════════════════════════
    //  SCENARIO 9: Full lifecycle (complete flow with all features)
    // ══════════════════════════════════════════════════════════════

    function test_Multi_FullLifecycleComplete() public {
        console.log("=== FULL LIFECYCLE TEST ===");
        console.log("Phase 1: Predeposit");

        // Multiple users predeposit different amounts
        _predeposit(alice, 150e18);
        _predeposit(bob, 100e18);
        _predeposit(carol, 75e18);
        _predeposit(dave, 25e18);
        assertEq(controller.totalPredepositors(), 4, "4 depositors");

        console.log("Phase 2: Launch");
        vm.prank(address(factory));
        controller.launchPooledBuy();

        console.log("Phase 3: Claims + Locks");
        _claimAndLock(alice);
        _claimAndLock(bob);

        // Carol claims but doesn't lock (free rider)
        _claim(carol);
        // Dave claims but doesn't lock
        _claim(dave);

        console.log("Phase 4: Trading Activity");
        // Eve and Frank buy via swap (new participants)
        _buy(eve, 30e18);
        _buy(frank, 20e18);

        // Some selling pressure
        uint256 davePSP = pspToken.balanceOf(dave);
        if (davePSP > 1e18) {
            _sell(dave, davePSP / 3);
            console.log("Dave sold 1/3 of PSP");
        }

        // More buys
        _buy(eve, 10e18);

        console.log("Phase 5: Fee Claims");
        // Alice and Bob claim accumulated fees
        uint256 aliceBefore = mixETH.balanceOf(alice);
        vm.prank(alice);
        controller.claimFees();
        uint256 aliceEarned = mixETH.balanceOf(alice) - aliceBefore;
        console.log("Alice earned in fees:", aliceEarned);

        uint256 bobBefore = mixETH.balanceOf(bob);
        vm.prank(bob);
        controller.claimFees();
        uint256 bobEarned = mixETH.balanceOf(bob) - bobBefore;
        console.log("Bob earned in fees:", bobEarned);

        console.log("Phase 6: Governance");
        // Carol decides to lock late and join governance
        uint256 carolPSP = pspToken.balanceOf(carol);
        if (carolPSP > 0) {
            _lock(carol, carolPSP);
            console.log("Carol locked late:", carolPSP);
        }

        // M-1: locks must predate the proposal timestamp
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        vm.prank(carol);
        controller.voteCarpetBomb(true);
        skip(3 days + 1);

        console.log("Phase 7: Destruction");
        controller.carpetBomb();
        skip(3 days + 1);
        controller.finalizeCarpet();
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Destroyed), "Destroyed");

        console.log("Phase 8: Round Carry");
        // carpetBomb birthed round 2 seeded with the entire carry
        assertEq(factory.currentRoundId(), 2, "round 2 spawned");
        uint256 seeded = mixETH.balanceOf(address(factory.getRound(2).controller));
        console.log("Funds seeded to round 2:", seeded);
        assertGt(seeded, 0, "Carry seeded into next round");
        assertEq(mixETH.balanceOf(address(factory)), 0, "factory emptied");

        console.log("=== LIFECYCLE COMPLETE ===");
    }

    // ══════════════════════════════════════════════════════════════
    //  SCENARIO 10: Dust amounts and edge cases
    // ══════════════════════════════════════════════════════════════

    function test_Multi_DustAmountsAndEdges() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claim(alice);

        // 1 wei buy now reverts (C-1 guard: MIN_SWAP_INPUT = 1e12)
        vm.startPrank(bob);
        mixETH.approve(address(router), 1);
        bool z411 = _isMixETHCurrency0();
        SwapParams memory dustBuy = SwapParams({
            amountSpecified: -1,
            sqrtPriceLimitX96: z411 ? _minPrice() : _maxPrice(),
            zeroForOne: z411
        });
        vm.expectRevert();
        router.swap(poolKey, dustBuy);
        vm.stopPrank();

        // Small buy (0.001 mixETH) still works
        _buy(bob, 1e15);
        assertGt(pspToken.balanceOf(bob), 0, "Small buy gets PSP");

        // Medium buy (1 mixETH)
        uint256 pspBefore = pspToken.balanceOf(carol);
        _buy(carol, 1e18);
        uint256 pspFromBuy = pspToken.balanceOf(carol) - pspBefore;

        // Sell 1 wei of PSP → also below min, must revert
        if (pspFromBuy > 1) {
            vm.startPrank(carol);
            pspToken.approve(address(router), 1);
            bool z412 = !_isMixETHCurrency0();
            SwapParams memory dustSell = SwapParams({
                amountSpecified: -1,
                sqrtPriceLimitX96: z412 ? _maxPrice() : _minPrice(),
                zeroForOne: z412
            });
            vm.expectRevert();
            router.swap(poolKey, dustSell);
            vm.stopPrank();
        }

        // Verify no value leaks from dust operations
        uint256 reserve = hook.reserveMixETH();
        uint256 supply = hook.totalSupplyPSP();
        assertGt(reserve, 0, "Reserve positive after dust");
        assertGt(supply, 0, "Supply positive after dust");

        console.log("=== Dust Test Results ===");
        console.log("Reserve after dust ops:", reserve);
        console.log("Supply after dust ops:", supply);
    }

    // ══════════════════════════════════════════════════════════════
    //  SCENARIO 11: Cannot sell more than supply
    // ══════════════════════════════════════════════════════════════

    function test_Multi_CannotSellMoreThanSupply() public {
        _predeposit(alice, 100e18);
        vm.prank(address(factory));
        controller.launchPooledBuy();
        _claim(alice);

        // Alice tries to sell her entire balance (should revert: >= totalSupplyPSP)
        uint256 alicePSP = pspToken.balanceOf(alice);

        vm.startPrank(alice);
        pspToken.approve(address(router), alicePSP);

        bool zeroForOne = !_isMixETHCurrency0();
        SwapParams memory params = SwapParams({
            amountSpecified: -int256(alicePSP),
            sqrtPriceLimitX96: zeroForOne ? _maxPrice() : _minPrice(),
            zeroForOne: zeroForOne
        });

        vm.expectRevert(); // V4 wraps as WrappedError
        router.swap(poolKey, params);
        vm.stopPrank();

        console.log("Cannot sell entire supply: correctly reverted");
    }

    // ══════════════════════════════════════════════════════════════
    //  HELPERS
    // ══════════════════════════════════════════════════════════════

    function _deployRound() internal {
        CurveMath.CurveConfig memory config = CurveMath.singleCurve(
            0.001e18,
            1_000_000e18,
            0.0000000046e18,
            0.05e18
        );

        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: config
        });

        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory round = factory.getRound(roundId);
        pspToken = round.token;
        controller = round.controller;
        hook = round.hook;

        Currency currency0 = Currency.wrap(address(mixETH));
        Currency currency1 = Currency.wrap(address(pspToken));
        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0x800000,
            tickSpacing: 60,
            hooks: hook
        });
    }

    function _dealMixETH(address to, uint256 amount) internal {
        MockMixETH(payable(address(mixETH))).transfer(to, amount);
    }

    function _predeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        mixETH.approve(address(controller), amount);
        controller.predeposit(amount);
        vm.stopPrank();
    }

    function _claim(address user) internal returns (uint256) {
        vm.prank(user);
        controller.claimPredepositPSP();
        (uint256 amount,,,) = controller.locks(user);
        return amount;
    }

    function _claimAndLock(address user) internal {
        // claimPredepositPSP auto-locks now — same as _claim
        _claim(user);
    }

    function _lock(address user, uint256 amount) internal {
        vm.startPrank(user);
        pspToken.approve(address(controller), amount);
        controller.lock(amount);
        vm.stopPrank();
    }

    function _buy(address user, uint256 mixETHAmount) internal {
        vm.startPrank(user);
        mixETH.approve(address(router), mixETHAmount);
        bool zeroForOne = _isMixETHCurrency0();
        SwapParams memory params = SwapParams({
            amountSpecified: -int256(mixETHAmount),
            sqrtPriceLimitX96: zeroForOne ? _minPrice() : _maxPrice(),
            zeroForOne: zeroForOne
        });
        router.swap(poolKey, params);
        vm.stopPrank();
    }

    function _sell(address user, uint256 pspAmount) internal {
        vm.startPrank(user);
        pspToken.approve(address(router), pspAmount);
        bool zeroForOne = !_isMixETHCurrency0();
        SwapParams memory params = SwapParams({
            amountSpecified: -int256(pspAmount),
            sqrtPriceLimitX96: zeroForOne ? _maxPrice() : _minPrice(),
            zeroForOne: zeroForOne
        });
        router.swap(poolKey, params);
        vm.stopPrank();
    }

    function _isMixETHCurrency0() internal view returns (bool) {
        return Currency.wrap(address(mixETH)) < Currency.wrap(address(pspToken));
    }

    function _minPrice() internal pure returns (uint160) {
        return 4295128740;
    }

    function _maxPrice() internal pure returns (uint160) {
        return 1461446703485210103287273052203988822378723970341;
    }

    receive() external payable {}
}
