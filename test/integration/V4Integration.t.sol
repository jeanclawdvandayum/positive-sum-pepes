// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
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

/// @title V4IntegrationTest
/// @notice End-to-end fork test: deploy PSP against real V4 PoolManager,
///         route swaps through the real V4 router, verify hook pricing.
///
///         This is the test that catches the two bugs flagged for integration:
///         1. BeforeSwapDelta direction (currency sorting)
///         2. _settleCurrency ordering (V4 flash accounting)
///
/// Run: forge test --match-contract V4IntegrationTest --fork-url $MAINNET_RPC_URL -vvv
contract V4IntegrationTest is Test {
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

    function setUp() public {
        // Fork mainnet
        uint256 forkBlock = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
        if (forkBlock > 0) {
            vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);
        } else {
            vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        }

        poolManager = IPoolManager(MainnetConfig.POOL_MANAGER);

        // Deploy MockMixETH on the fork (real PoolManager, mock token)
        // We use a mock because the real VaultV2 has internal accounting that
        // doesn't work with vm.deal cheat codes or V4's raw transfer pattern.
        // The V4 integration (hook, flash accounting, BeforeSwapDelta) is what
        // we're testing here, not the mixETH vault itself.
        MockMixETH mockMix = new MockMixETH();
        mockMix.depositETH{value: 100_000e18}();
        mixETH = IERC20(address(mockMix));

        // Deploy PSPFactory with real PoolManager
        factory = new PSPFactory(poolManager, mixETH, new HookDeployer(), new ControllerDeployer());

        // Deploy V4 swap router (handles unlock/callback + pre-settle pattern)
        router = new V4SwapRouter(poolManager);

        // Fund test users with mixETH
        // We deal mixETH tokens directly (cheat code) since acquiring real mixETH
        // requires depositing WETH into the Alchemix V3 vault (complex flow)
        _dealMixETH(alice, 1_000e18);
        _dealMixETH(bob, 1_000e18);

        // Deploy a round
        _deployRound();
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 1: Hook deploys with correct address flags
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_HookHasCorrectFlags() public view {
        uint160 hookFlags = uint160(address(hook));
        uint160 mask = Hooks.ALL_HOOK_MASK;

        assertTrue(hookFlags & Hooks.BEFORE_ADD_LIQUIDITY_FLAG != 0, "beforeAddLiquidity flag");
        assertTrue(hookFlags & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG != 0, "beforeRemoveLiquidity flag");
        assertTrue(hookFlags & Hooks.BEFORE_SWAP_FLAG != 0, "beforeSwap flag");
        assertTrue(hookFlags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0, "beforeSwapReturnDelta flag");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 2: Pool initialized correctly on real PoolManager
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_PoolInitialized() public view {
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        assertGt(sqrtPriceX96, 0, "Pool has a price");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 3: Buy PSP through V4 swap
    //  This tests BeforeSwapDelta direction + settle ordering
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_BuyPSPViaV4Swap() public {
        // Predeposit + launch
        vm.startPrank(alice);
        mixETH.approve(address(controller), 100e18);
        controller.predeposit(100e18);
        vm.stopPrank();

        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();

        // Verify auto-lock (predeposit PSP is locked, not free balance)
        (uint256 aliceLocked,,,) = controller.locks(alice);
        assertGt(aliceLocked, 0, "Alice locked PSP from predeposit");

        // Now do a real V4 swap: mixETH -> PSP via router
        uint256 mixETHIn = 10e18;
        uint256 pspBefore = pspToken.balanceOf(alice);

        _doSwap(alice, mixETHIn, true);

        uint256 pspAfter = pspToken.balanceOf(alice);
        assertGt(pspAfter, pspBefore, "Alice received PSP from swap");

        console.log("PSP from predeposit (locked):", aliceLocked);
        console.log("PSP from swap (free):", pspAfter - pspBefore);

        // Verify hook state updated
        assertGt(hook.totalSupplyPSP(), 0, "Hook supply increased");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 4: Sell PSP through V4 swap
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_SellPSPViaV4Swap() public {
        // Setup: predeposit + launch + claim
        vm.startPrank(alice);
        mixETH.approve(address(controller), 100e18);
        controller.predeposit(100e18);
        vm.stopPrank();

        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();

        // First buy via swap to establish supply and get free PSP
        _doSwap(alice, 10e18, true);

        // Now sell some swap-bought PSP back (predeposit PSP is locked)
        uint256 pspToSell = pspToken.balanceOf(alice) / 4; // sell 25% of free PSP
        vm.assume(pspToSell > 0);

        uint256 mixBefore = mixETH.balanceOf(alice);
        _doSwap(alice, pspToSell, false);
        uint256 mixReceived = mixETH.balanceOf(alice) - mixBefore;

        assertGt(mixReceived, 0, "Alice received mixETH from sell");

        console.log("PSP sold:", pspToSell);
        console.log("mixETH received:", mixReceived);
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 5: Round-trip (buy then sell) loses value (no arb)
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_RoundTripNoArb() public {
        // Launch
        vm.startPrank(alice);
        mixETH.approve(address(controller), 100e18);
        controller.predeposit(100e18);
        vm.stopPrank();

        vm.prank(address(factory));
        controller.launchPooledBuy();

        // Buy via swap
        uint256 mixBefore = mixETH.balanceOf(alice);
        _doSwap(alice, 10e18, true);
        uint256 pspBought = pspToken.balanceOf(alice);

        // Sell all back
        _doSwap(alice, pspBought, false);
        uint256 mixAfter = mixETH.balanceOf(alice);

        console.log("mixETH before:", mixBefore);
        console.log("mixETH after:", mixAfter);
        console.log("Net change:", int256(mixAfter) - int256(mixBefore));

        // Should have lost value (fees + curve slippage)
        assertLt(mixAfter, mixBefore, "Round trip loses value");
    }

    // ═══════════════════════════════════════════════════════════════
    //  TEST 6: Fees accumulate in hook, claimable by lockers
    // ═══════════════════════════════════════════════════════════════

    function test_Fork_FeesAccumulateAndClaim() public {
        // Launch
        vm.startPrank(alice);
        mixETH.approve(address(controller), 100e18);
        controller.predeposit(100e18);
        vm.stopPrank();

        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();

        // Predeposit claim auto-locks PSP — alice is now a locker
        // No need for explicit lock() call

        // Bob buys via swap (generates fees)
        _doSwap(bob, 50e18, true);

        // Alice claims fees
        uint256 mixBefore = mixETH.balanceOf(alice);
        vm.prank(alice);
        controller.claimFees();
        uint256 mixGained = mixETH.balanceOf(alice) - mixBefore;

        assertGt(mixGained, 0, "Alice earned fees from Bob's swap");
        console.log("Fees earned by locker:", mixGained);
    }

    // ═══════════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _deployRound() internal {
        CurveMath.CurveConfig memory config = CurveMath.singleCurve(
            0.001e18,          // P0 = 0.001 ETH
            1_000_000e18,      // inflection at 1M supply
            0.0000000046e18,   // exponential rate
            0.05e18            // logarithmic rate
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

        // Construct pool key (same as factory does internally)
        Currency currency0 = Currency.wrap(address(mixETH));
        Currency currency1 = Currency.wrap(address(pspToken));
        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0x800000, // dynamic fee
            tickSpacing: 60,
            hooks: hook
        });
    }

    function _dealMixETH(address to, uint256 amount) internal {
        // MockMixETH is a standard ERC20, so transfer works directly
        MockMixETH(payable(address(mixETH))).transfer(to, amount);
    }

    function _isMixETHCurrency0() internal view returns (bool) {
        return Currency.wrap(address(mixETH)) < Currency.wrap(address(pspToken));
    }

    function _minPrice() internal pure returns (uint160) {
        return 4295128740; // MIN_SQRT_RATIO + 1
    }

    function _maxPrice() internal pure returns (uint160) {
        return 1461446703485210103287273052203988822378723970341; // MAX_SQRT_RATIO - 1
    }

    /// @dev Execute a swap via our V4SwapRouter. isBuy=true means mixETH->PSP, false means PSP->mixETH
    function _doSwap(address user, uint256 amount, bool isBuy) internal {
        Currency inCurrency = isBuy
            ? Currency.wrap(address(mixETH))
            : Currency.wrap(address(pspToken));

        bool zeroForOne = isBuy ? _isMixETHCurrency0() : !_isMixETHCurrency0();

        SwapParams memory params = SwapParams({
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? _minPrice() : _maxPrice(),
            zeroForOne: zeroForOne
        });

        vm.startPrank(user);
        // Approve router to pull input tokens for pre-settle
        IERC20(Currency.unwrap(inCurrency)).approve(address(router), amount);
        router.swap(poolKey, params);
        vm.stopPrank();
    }

    receive() external payable {}
}
