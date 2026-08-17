// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CurveMath} from "./libraries/CurveMath.sol";
import {IRoundController} from "./interfaces/IRoundController.sol";

/// @title CurveHook - V4 hook implementing S-curve bonding curve for PSP
/// @notice Handles pricing, minting/burning PSP, and fee extraction.
///         Curve, reserve, and fees are all denominated in mixETH — the vault's
///         exchange rate is NEVER read in the settlement path (NK24 rate-short
///         fix: buys used to credit the reserve at the buy-time rate while
///         sells converted an ETH integral at the live rate, leaving the
///         reserve short a depeg put with only a 1bps haircut as cushion;
///         any rate drop > haircut extracted other holders' backing).
///         mixETH yield/losses now accrue pro-rata to all PSP holders.
///         Fees stay in hook balance (over the reserve), claimable via sendFees().
contract CurveHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurveMath for CurveMath.CurveConfig;
    using SafeERC20 for IERC20;

    // ─────────────── Errors ───────────────
    error NotActive();
    error NotController();
    error InvalidMode();
    error BuyZeroAmount();
    error SellExceedsSupply();
    error InsufficientFees();
    error SwapTooSmall(); // C-1 fix: blocks dust-scale precision arb on the curve
    error ZeroOutput(); // a swap must deliver a nonzero user output — never absorb input silently
    error WrongPoolCurrencies(); // L-2 fix: pool-key gate on initialization
    error WrongPoolParams(); // NK24: canonical fee/tickSpacing gate — no decoy pools

    // ─────────────── Types ───────────────
    enum Mode { Predeposit, Active, Flat, Destroyed }

    // ─────────────── Immutables ───────────────
    IRoundController public immutable controller;
    CurveMath.CurveConfig public curveConfig;
    uint24 public constant SWAP_FEE_BIPS = 500; // 5% total swap fee
    /// @dev Side-pot cut of the swap fee, taken as PSP instead of mixETH:
    ///      buys mint it through the curve (backed), sells skim it off the
    ///      burned input. The remaining 475 bips go to the staker accumulator.
    uint24 public constant POT_FEE_BIPS = 25; // 0.25%
    /// @dev Canonical V4 pool parameters — the only pool this hook serves.
    ///      0x800000 = dynamic-fee flag (hook-priced; fee field unused).
    uint24 public constant CANONICAL_FEE = 0x800000;
    int24 public constant CANONICAL_TICK_SPACING = 60;
    /// @dev C-1 fix: minimum swap input. Below ~1e12 wei, curveIntegral
    ///      fixed-point truncation (pStart/k rounding) can exceed the 1 bps
    ///      conservative haircut, making dust round-trips profitable in wei
    /// terms. Economically nil, but the invariant violation is real — block it.
    uint256 public constant MIN_SWAP_INPUT = 1e12; // 0.000001 tokens

    // ─────────────── State ───────────────
    Mode public mode = Mode.Predeposit;
    uint256 public reserveMixETH;   // mixETH backing circulating PSP (excludes fees)
    uint256 public totalSupplyPSP;  // total PSP minted by curve
    bool public poolInitialized;

    // ─────────────── Events ───────────────
    // All value fields mixETH-denominated (curve unit of account).
    event Buy(address indexed buyer, uint256 mixETHIn, uint256 pspOut, uint256 newSupply, uint256 newReserveMixETH);
    event Sell(address indexed seller, uint256 pspIn, uint256 mixETHOut, uint256 newSupply, uint256 newReserveMixETH);
    event ModeChanged(Mode newMode);
    event PoolInitialized();
    event FeesSent(address indexed to, uint256 mixETHAmount);
    event Drained(address indexed to, uint256 mixETHAmount);
    event PotBackingRedeemed(uint256 pspAmount, uint256 mixETHOut);

    // ─────────────── Constructor ───────────────
    constructor(IPoolManager _poolManager, IRoundController _controller, CurveMath.CurveConfig memory _config)
        BaseHook(_poolManager)
    {
        controller = _controller;
        curveConfig = _config;
    }

    // ─────────────── Settlement Helpers ───────────────

    function _settleCurrency(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        // V4 pattern: sync FIRST (snapshot old balance), then transfer, then settle.
        // If transfer happens before sync, settle sees no delta and reverts with CurrencyNotSettled.
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    // ─────────────── Dynamic Reserve ───────────────

    /// @notice ETH-denominated value of the curve reserve (excludes accumulated fees)
    /// @dev DISPLAY ONLY — never used in settlement math. Computed dynamically
    ///      from reserveMixETH at the current exchange rate for UIs/events-free
    ///      consumption. The swap path itself never reads the vault rate (NK24).
    function totalReserveETH() public view returns (uint256) {
        return controller.mixETHToETH(reserveMixETH);
    }

    // ─────────────── Hook Permissions ───────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // L-2: gate pool init to the canonical pair
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────── Hook Callbacks ───────────────

    /// @dev L-2 fix: this hook must only ever serve the canonical
    ///      {mixETH, PSP} pool created by PSPFactory. Without the gate anyone
    ///      could initialize decoy pools keyed to this hook's address; the
    ///      hook's PSP/mixETH custody can never square against such a pool's
    ///      currencies, so decoy pools are permanent dead liquidity traps.
    ///      Order-independent: either sort orientation of the pair is accepted.
    ///      NK24: currency-gating alone still allowed decoy pools at other fee
    ///      tiers / tick spacings — accounting-safe (state is shared) but a
    ///      pure phishing surface. Gate the canonical parameters too.
    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal
        view
        override
        returns (bytes4)
    {
        Currency mixETH = controller.getMixETH();
        Currency psp = Currency.wrap(address(controller.getPSP()));

        bool isCanonical =
            (key.currency0 == mixETH && key.currency1 == psp)
                || (key.currency0 == psp && key.currency1 == mixETH);
        if (!isCanonical) revert WrongPoolCurrencies();

        if (key.fee != CANONICAL_FEE || key.tickSpacing != CANONICAL_TICK_SPACING) {
            revert WrongPoolParams();
        }

        return IHooks.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal pure override returns (bytes4)
    { revert("NoStandardLiquidity"); }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal pure override returns (bytes4)
    { revert("NoStandardLiquidity"); }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (mode != Mode.Active && mode != Mode.Flat) revert NotActive();

        Currency mixETH = controller.getMixETH();
        Currency psp = Currency.wrap(address(controller.getPSP()));

        bool isBuy = params.zeroForOne
            ? (key.currency0 == mixETH)
            : (key.currency1 == mixETH);

        if (params.amountSpecified >= 0) revert("ExactOutNotSupported");

        uint256 inputAmount = uint256(int256(-params.amountSpecified));

        // C-1 fix: reject dust swaps — below this size the curve math's
        // fixed-point precision can make round-trips profitable (in wei terms)
        if (inputAmount < MIN_SWAP_INPUT) revert SwapTooSmall();

        if (isBuy) {
            return _handleBuy(key, params, inputAmount, mixETH, psp);
        } else {
            return _handleSell(key, params, inputAmount, mixETH, psp);
        }
    }

    // ─────────────── Buy Logic ───────────────

    function _handleBuy(PoolKey calldata key, SwapParams calldata params, uint256 mixETHInput,
        Currency mixETH, Currency psp)
        internal returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (mode == Mode.Flat) {
            return _handleFlatBuy(key, params, mixETHInput, mixETH, psp);
        }

        // NK24 fix: mixETH is the unit of account — the curve is solved
        // directly in mixETH. No vault-rate read anywhere in this path.
        //
        // Fee split: 5% total. 4.75% mixETH → staker accumulator; 0.25%
        // flows through the curve AFTER the user's slice and mints PSP to
        // the controller's side pot (backed 1:1 by its mixETH in reserve).
        uint256 feeMixETH = (mixETHInput * SWAP_FEE_BIPS) / 10000;
        uint256 potMixETH = (mixETHInput * POT_FEE_BIPS) / 10000;
        uint256 stakerFeeMixETH = feeMixETH - potMixETH;
        uint256 curveMixETH = mixETHInput - feeMixETH;

        // Compute PSP outputs — user first at 95%, pot second at 0.25%
        uint256 pspOut = CurveMath.computeBuyOutput(curveMixETH, totalSupplyPSP, curveConfig);
        if (pspOut == 0) revert ZeroOutput();
        uint256 potPSP = CurveMath.computeBuyOutput(potMixETH, totalSupplyPSP + pspOut, curveConfig);

        // CEI: update state before external calls
        // curveMixETH + potMixETH enter the reserve; stakerFeeMixETH stays in
        // balance as available fees
        reserveMixETH += curveMixETH + potMixETH;
        totalSupplyPSP += pspOut + potPSP;

        emit Buy(msg.sender, mixETHInput, pspOut, totalSupplyPSP, reserveMixETH);

        // Take mixETH from PoolManager to hook custody
        poolManager.take(mixETH, address(this), mixETHInput);

        // Mint PSP for the buyer
        controller.mintPSPForSwap(pspOut);

        // Mint the pot's backed PSP (held unlocked by the controller — never
        // staked, never sold; the ONLY exit is carpet-bomb redemption)
        if (potPSP > 0) {
            controller.mintPotPSP(potPSP);
        }

        // Route staker fee to controller accumulator (mixETH-denominated)
        if (stakerFeeMixETH > 0) {
            controller.addFees(stakerFeeMixETH);
        }

        // Settle PSP to PoolManager
        _settleCurrency(psp, pspOut);

        // V4 BeforeSwapDelta convention:
        // specified positive = hook PROVIDES specified currency (reduces AMM amount to 0)
        // unspecified negative = hook PROVIDES unspecified output (consumes it from pool)
        BeforeSwapDelta hookDelta = toBeforeSwapDelta(
            int128(int256(mixETHInput)),   // +input: hook handles the specified input
            int128(-int256(pspOut))         // -output: hook provides the unspecified output
        );

        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    // ─────────────── Sell Logic ───────────────

    function _handleSell(PoolKey calldata key, SwapParams calldata params, uint256 pspInputAmount,
        Currency mixETH, Currency psp)
        internal returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (pspInputAmount == 0) revert BuyZeroAmount();
        if (pspInputAmount >= totalSupplyPSP) revert SellExceedsSupply();

        if (mode == Mode.Flat) {
            return _handleFlatSell(key, params, pspInputAmount, mixETH, psp);
        }

        // NK24 fix: compute the sell integral natively in mixETH. The reserve
        // is debited exactly what the curve says, in the same unit it is
        // denominated in — a vault-rate move can no longer make the debit
        // exceed the corresponding buy credits (the old code converted an
        // ETH integral at the LIVE rate, so a >1bps rate drop between buy and
        // sell extracted other holders' backing; a 95% drop underflowed the
        // reserve and bricked every sell).
        uint256 mixETHOut = CurveMath.computeSellOutput(pspInputAmount, totalSupplyPSP, curveConfig);

        // Fee split: 5% of the out-value total. 4.75% mixETH → stakers.
        // The pot's 0.25% is taken IN PSP: 0.25% of the sold PSP is
        // transferred to the pot instead of burned, so its backing stays
        // in the reserve. User still receives 95% of the full integral.
        uint256 feeMixETH = (mixETHOut * SWAP_FEE_BIPS) / 10000;
        uint256 potMixETH = (mixETHOut * POT_FEE_BIPS) / 10000;
        uint256 stakerFeeMixETH = feeMixETH - potMixETH;
        uint256 mixETHToUser = mixETHOut - feeMixETH;
        uint256 potPSPCut = (pspInputAmount * POT_FEE_BIPS) / 10000;
        uint256 burnAmount = pspInputAmount - potPSPCut;
        if (mixETHToUser == 0) revert ZeroOutput();

        // CEI: reserve decreases by the out-value MINUS the pot slice (that
        // mixETH now backs the pot's unburned PSP); supply drops by burnAmount
        reserveMixETH -= (mixETHOut - potMixETH);
        totalSupplyPSP -= burnAmount;

        emit Sell(msg.sender, pspInputAmount, mixETHToUser, totalSupplyPSP, reserveMixETH);

        // Take PSP from PoolManager to hook custody (pre-funded by router)
        poolManager.take(psp, address(this), pspInputAmount);

        // Burn the user's PSP; route the pot's cut to the controller (unlocked,
        // never restaked — carpet-bomb redemption is its only exit)
        controller.burnPSPForSwap(burnAmount);
        if (potPSPCut > 0) {
            IERC20(Currency.unwrap(psp)).safeTransfer(address(controller), potPSPCut);
            controller.creditPotPSP(potPSPCut);
        }

        // Send mixETH to user via PoolManager
        _settleCurrency(mixETH, mixETHToUser);

        // Route staker fee
        if (stakerFeeMixETH > 0) {
            controller.addFees(stakerFeeMixETH);
        }

        // V4 BeforeSwapDelta: specified positive = hook handles input, unspecified negative = hook provides output
        BeforeSwapDelta hookDelta = toBeforeSwapDelta(
            int128(int256(pspInputAmount)),  // +input: hook handles the specified PSP input
            int128(-int256(mixETHToUser))    // -output: hook provides the unspecified mixETH output
        );

        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    // ─────────────── Flat Mode (Destruction) ───────────────

    function _handleFlatBuy(PoolKey calldata, SwapParams calldata, uint256 mixETHInput,
        Currency mixETH, Currency psp)
        internal returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (totalSupplyPSP == 0) revert NotActive();

        // Flat price in mixETH terms
        uint256 flatPriceMixETH = (reserveMixETH * 1e18) / totalSupplyPSP;

        // Fee split as on the curve: 4.75% stakers (mixETH), 0.25% pot (PSP
        // at the flat price — buys leave the flat price invariant, so the
        // pot's slice prices identically before or after the user's)
        uint256 feeMixETH = (mixETHInput * SWAP_FEE_BIPS) / 10000;
        uint256 potMixETH = (mixETHInput * POT_FEE_BIPS) / 10000;
        uint256 stakerFeeMixETH = feeMixETH - potMixETH;
        uint256 buyMixETH = mixETHInput - feeMixETH;

        uint256 pspOut = (buyMixETH * 1e18) / flatPriceMixETH;
        if (pspOut == 0) revert ZeroOutput();
        uint256 potPSP = (potMixETH * 1e18) / flatPriceMixETH;

        reserveMixETH += buyMixETH + potMixETH;
        totalSupplyPSP += pspOut + potPSP;

        emit Buy(msg.sender, mixETHInput, pspOut, totalSupplyPSP, reserveMixETH);

        poolManager.take(mixETH, address(this), mixETHInput);
        controller.mintPSPForSwap(pspOut);
        if (potPSP > 0) controller.mintPotPSP(potPSP);
        _settleCurrency(psp, pspOut);

        if (stakerFeeMixETH > 0) controller.addFees(stakerFeeMixETH);

        BeforeSwapDelta hookDelta = toBeforeSwapDelta(
            int128(int256(mixETHInput)),   // +input: hook handles specified input
            int128(-int256(pspOut))         // -output: hook provides unspecified output
        );
        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    function _handleFlatSell(PoolKey calldata, SwapParams calldata, uint256 pspInputAmount,
        Currency mixETH, Currency psp)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (totalSupplyPSP == 0) revert NotActive();

        // Direct computation to avoid divide-before-multiply rounding
        // flatPrice = reserveMixETH / totalSupplyPSP (in 1e18)
        // totalMixETHOut = pspInputAmount * flatPrice / 1e18
        //   = pspInputAmount * reserveMixETH / totalSupplyPSP
        uint256 totalMixETHOut = (pspInputAmount * reserveMixETH) / totalSupplyPSP;
        // Fee split as on the curve: pot's 0.25% taken in PSP (unburned —
        // its backing stays in reserve), stakers get 4.75% in mixETH
        uint256 feeMixETH = (totalMixETHOut * SWAP_FEE_BIPS) / 10000;
        uint256 potMixETH = (totalMixETHOut * POT_FEE_BIPS) / 10000;
        uint256 stakerFeeMixETH = feeMixETH - potMixETH;
        uint256 mixETHToUser = totalMixETHOut - feeMixETH;
        uint256 potPSPCut = (pspInputAmount * POT_FEE_BIPS) / 10000;
        uint256 burnAmount = pspInputAmount - potPSPCut;
        if (mixETHToUser == 0) revert ZeroOutput();

        reserveMixETH -= (totalMixETHOut - potMixETH);
        totalSupplyPSP -= burnAmount;

        emit Sell(msg.sender, pspInputAmount, mixETHToUser, totalSupplyPSP, reserveMixETH);

        // Take PSP from PoolManager to hook custody (pre-funded by router)
        poolManager.take(psp, address(this), pspInputAmount);

        controller.burnPSPForSwap(burnAmount);
        if (potPSPCut > 0) {
            IERC20(Currency.unwrap(psp)).safeTransfer(address(controller), potPSPCut);
            controller.creditPotPSP(potPSPCut);
        }
        _settleCurrency(mixETH, mixETHToUser);

        if (stakerFeeMixETH > 0) controller.addFees(stakerFeeMixETH);

        BeforeSwapDelta hookDelta = toBeforeSwapDelta(
            int128(int256(pspInputAmount)),  // +input: hook handles specified input
            int128(-int256(mixETHToUser))    // -output: hook provides unspecified output
        );
        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    // ─────────────── Fee Distribution ───────────────

    /// @notice Send accumulated fees to a locker (called by controller during claimFees)
    /// @dev Available fees = hook's mixETH balance - reserveMixETH.
    ///      No separate counter needed: the invariant is
    ///      balanceOf(hook) = reserveMixETH + availableFees.
    function sendFees(address to, uint256 mixETHAmount) external {
        if (msg.sender != address(controller)) revert NotController();

        address mixETHAddr = Currency.unwrap(controller.getMixETH());
        uint256 balance = IERC20(mixETHAddr).balanceOf(address(this));
        // Solidity 0.8 reverts on underflow if balance < reserveMixETH
        uint256 available = balance - reserveMixETH;
        if (mixETHAmount > available) revert InsufficientFees();

        IERC20(mixETHAddr).safeTransfer(to, mixETHAmount);

        emit FeesSent(to, mixETHAmount);
    }

    // ─────────────── Destruction Support ───────────────

    /// @notice Redeem the side pot's PSP at average backing (reserve/supply).
    /// @dev Controller-only, called from carpetBomb() BEFORE drainAll — the
    ///      pot PSP is never sold on any market during the round; this is its
    ///      only exit. Pro-rata at average backing, not the sell integral:
    ///      the pot is an eternal compounding position, not a round-tripper.
    function redeemPotBacking(uint256 pspAmount) external returns (uint256 mixETHOut) {
        if (msg.sender != address(controller)) revert NotController();
        if (pspAmount == 0 || totalSupplyPSP == 0) return 0;

        mixETHOut = (reserveMixETH * pspAmount) / totalSupplyPSP;
        reserveMixETH -= mixETHOut;
        totalSupplyPSP -= pspAmount;

        IERC20(Currency.unwrap(controller.getMixETH())).safeTransfer(msg.sender, mixETHOut);

        emit PotBackingRedeemed(pspAmount, mixETHOut);
    }

    /// @notice Drain ALL mixETH (reserve + fees) for round carry-over
    /// @return mixETHAmount Total mixETH transferred to `to`
    function drainAll(address to) external returns (uint256) {
        if (msg.sender != address(controller)) revert NotController();

        address mixETHAddr = Currency.unwrap(controller.getMixETH());
        uint256 balance = IERC20(mixETHAddr).balanceOf(address(this));
        if (balance > 0) {
            IERC20(mixETHAddr).safeTransfer(to, balance);
        }
        reserveMixETH = 0;

        emit Drained(to, balance);
        return balance;
    }

    // ─────────────── Mode Management ───────────────

    function setMode(Mode newMode) external {
        if (msg.sender != address(controller)) revert NotController();

        // Enforce valid transitions
        if (mode == Mode.Predeposit && newMode != Mode.Active) revert InvalidMode();
        if (mode == Mode.Active && newMode != Mode.Flat) revert InvalidMode();
        if (mode == Mode.Flat && newMode != Mode.Destroyed) revert InvalidMode();
        if (mode == Mode.Destroyed) revert InvalidMode();

        mode = newMode;
        emit ModeChanged(newMode);
    }

    /// @notice Initialize curve state with pooled predeposit buy
    /// @param _reserveMixETH The actual mixETH amount transferred to this hook
    function initializeCurve(uint256 _reserveMixETH, uint256 _initialSupply) external {
        if (msg.sender != address(controller)) revert NotController();
        if (poolInitialized) revert InvalidMode();

        reserveMixETH = _reserveMixETH;
        totalSupplyPSP = _initialSupply;
        poolInitialized = true;

        emit PoolInitialized();
    }

    // ─────────────── View Functions ───────────────

    /// @notice Full curve zones (auto-getter omits arrays)
    function getCurveZones() external view returns (CurveMath.Zone[] memory) {
        return curveConfig.zones;
    }

    /// @return mixETH-denominated marginal price (curve unit of account)
    function getMarginalPrice() external view returns (uint256) {
        return CurveMath.marginalPrice(totalSupplyPSP, curveConfig);
    }

    /// @return mixETH-denominated flat-mode price (NK24: no ETH conversion)
    function getFlatPrice() external view returns (uint256) {
        if (totalSupplyPSP == 0) return 0;
        return (reserveMixETH * 1e18) / totalSupplyPSP;
    }

    /// @param mixETHInput mixETH to spend on the curve
    /// @return PSP output for a mixETH input (curve unit of account)
    function getBuyOutput(uint256 mixETHInput) external view returns (uint256) {
        return CurveMath.computeBuyOutput(mixETHInput, totalSupplyPSP, curveConfig);
    }

    /// @return mixETH output for a PSP sell (curve unit of account)
    function getSellOutput(uint256 pspInput) external view returns (uint256) {
        return CurveMath.computeSellOutput(pspInput, totalSupplyPSP, curveConfig);
    }
}
