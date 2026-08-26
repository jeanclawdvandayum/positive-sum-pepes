// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IMixETH} from "./interfaces/IMixETH.sol";
import {RoundController} from "./RoundController.sol";

/// @title PSPZapIn — pay ETH, join the game.
/// @notice Wraps ETH into mixETH and either predeposits into a round's
///         controller (crediting the PSP to the caller, not this router)
///         or buys PSP on the curve via the V4 pool. Holds no funds between
///         transactions; the caller owns all slippage parameters.
contract PSPZapIn {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    IMixETH public immutable mixETH;
    IPoolManager public immutable poolManager;

    error ZeroAmount();
    error Expired();
    error InsufficientShares();
    error InsufficientOutput();
    error NotPoolManager();
    error BadPool();

    struct BuyData {
        PoolKey key;
        uint256 mixIn;
        uint256 minPspOut;
        address to;
        address trader;   // referral payout identity (0x0 = none)
    }

    constructor(IMixETH _mixETH, IPoolManager _poolManager) {
        mixETH = _mixETH;
        poolManager = _poolManager;
    }

    /// @notice Wrap msg.value of ETH and predeposit for the caller.
    /// @param controller The round's controller
    /// @param minSharesMinted Revert if the wrap mints fewer mixETH shares
    ///        (guards against exchange-rate movement between quote and fill)
    /// @return shares mixETH actually deposited
    function zapInPredeposit(RoundController controller, uint256 minSharesMinted)
        external
        payable
        returns (uint256 shares)
    {
        if (msg.value == 0) revert ZeroAmount();

        shares = _wrap(msg.value);
        if (shares < minSharesMinted) revert InsufficientShares();

        IERC20(address(mixETH)).forceApprove(address(controller), shares);
        controller.predepositFor(msg.sender, shares);
    }

    /// @notice Wrap msg.value of ETH and buy PSP on the curve.
    /// @param key The round's {mixETH, PSP} pool key (either currency sort)
    /// @param minPspOut Revert if fewer PSP tokens come out
    /// @param deadline Revert if executed after this timestamp (0 = off)
    /// @return pspOut PSP sent to the caller
    /// @dev Referral attribution is NOT set here — it binds only via the
    ///      user-signed registry.record(refNft) (A-1 fix 2026-08-26); this
    ///      zap merely carries the trader identity so RECORDED chains keep
    ///      earning on every trade.
    function zapInBuy(PoolKey calldata key, uint256 minPspOut, uint256 deadline)
        external
        payable
        returns (uint256 pspOut)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (deadline != 0 && block.timestamp > deadline) revert Expired();

        // Validate the pool references mixETH exactly once (the callback
        // derives direction the same way — mismatched keys revert in unlock).
        bool mixIsZero = Currency.unwrap(key.currency0) == address(mixETH);
        bool mixIsOne = Currency.unwrap(key.currency1) == address(mixETH);
        if (mixIsZero == mixIsOne) revert BadPool();

        uint256 mixIn = _wrap(msg.value);

        bytes memory result = poolManager.unlock(
            abi.encode(BuyData({
                key: key, mixIn: mixIn, minPspOut: minPspOut, to: msg.sender,
                trader: msg.sender
            }))
        );
        pspOut = abi.decode(result, (uint256));
    }

    /// @notice Swap already-held mixETH for PSP on the curve (no ETH leg).
    /// @param key The round's {mixETH, PSP} pool key (either currency sort)
    /// @param mixIn mixETH to spend (caller must have approved this router)
    /// @param minPspOut Revert if fewer PSP tokens come out
    /// @param deadline Revert if executed after this timestamp (0 = off)
    /// @return pspOut PSP sent to the caller
    /// @dev Referral attribution binds only via registry.record(refNft) —
    ///      never through this router (A-1 fix 2026-08-26).
    function buyWithMix(PoolKey calldata key, uint256 mixIn, uint256 minPspOut, uint256 deadline)
        external
        returns (uint256 pspOut)
    {
        if (mixIn == 0) revert ZeroAmount();
        if (deadline != 0 && block.timestamp > deadline) revert Expired();

        bool mixIsZero = Currency.unwrap(key.currency0) == address(mixETH);
        bool mixIsOne = Currency.unwrap(key.currency1) == address(mixETH);
        if (mixIsZero == mixIsOne) revert BadPool();

        IERC20(address(mixETH)).safeTransferFrom(msg.sender, address(this), mixIn);

        bytes memory result = poolManager.unlock(
            abi.encode(BuyData({
                key: key, mixIn: mixIn, minPspOut: minPspOut, to: msg.sender,
                trader: msg.sender
            }))
        );
        pspOut = abi.decode(result, (uint256));
    }

    /// @dev Wrap ETH, measuring shares by balance diff (robust to FoT quirks).
    function _wrap(uint256 ethAmount) internal returns (uint256 shares) {
        IERC20 mix = IERC20(address(mixETH));
        uint256 balBefore = mix.balanceOf(address(this));
        mixETH.depositETH{value: ethAmount}();
        shares = mix.balanceOf(address(this)) - balBefore;
    }

    /// @dev The PSP side is whichever currency is not mixETH. Pool ordering
    ///      is address-sorted, not semantic — never assume mixETH is currency0.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        BuyData memory d = abi.decode(data, (BuyData));

        bool mixIsZero = Currency.unwrap(d.key.currency0) == address(mixETH);
        Currency mixCur = mixIsZero ? d.key.currency0 : d.key.currency1;

        // Pre-settle the exact input: sync, transfer, settle
        poolManager.sync(mixCur);
        IERC20(Currency.unwrap(mixCur)).safeTransfer(address(poolManager), d.mixIn);
        poolManager.settle();

        // Buy: mix -> PSP. Price limit is the far bound in swap direction.
        // hookData carries the TRADER address so the hook can pay the
        // trader's already-RECORDED referral chain (attribution itself is
        // never created here — A-1 fix 2026-08-26).
        BalanceDelta delta = poolManager.swap(
            d.key,
            SwapParams({
                amountSpecified: -int256(d.mixIn),
                sqrtPriceLimitX96: mixIsZero
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1,
                zeroForOne: mixIsZero
            }),
            // ALWAYS carry the trader — an attributed trader must keep
            // paying their chain on every trade, including plain ones
            // (empty hookData made the hook see trader == 0 and skip
            // payouts entirely; fixed 2026-08-19)
            abi.encode(d.trader)
        );

        // PSP delta is positive (owed to us); take it for the caller.
        Currency pspCur = mixIsZero ? d.key.currency1 : d.key.currency0;
        int256 pspDelta = mixIsZero ? delta.amount1() : delta.amount0();
        if (pspDelta <= 0) revert InsufficientOutput();
        uint256 pspOut = uint256(int256(pspDelta));
        if (pspOut < d.minPspOut) revert InsufficientOutput();

        poolManager.take(pspCur, d.to, pspOut);
        return abi.encode(pspOut);
    }
}
