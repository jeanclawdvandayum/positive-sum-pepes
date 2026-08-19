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

/// @title PSPZapOut — sell PSP, receive ETH.
/// @notice Swaps PSP for mixETH on the round's V4 pool, then redeems the
///         mixETH for ETH in the same transaction. Holds no funds between
///         transactions; ETH is forwarded to the caller.
contract PSPZapOut {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    IMixETH public immutable mixETH;
    IPoolManager public immutable poolManager;

    error ZeroAmount();
    error Expired();
    error InsufficientOutput();
    error NotPoolManager();
    error BadPool();
    error EthForwardFailed();

    struct SellData {
        PoolKey key;
        uint256 pspIn;
        address pspToken;
        address to;
        address trader;   // referral attribution (0x0 = none)
        address referrer;
    }

    constructor(IMixETH _mixETH, IPoolManager _poolManager) {
        mixETH = _mixETH;
        poolManager = _poolManager;
    }

    /// @notice Sell PSP for ETH in one call.
    /// @param key The round's {mixETH, PSP} pool key (either currency sort)
    /// @param pspIn Amount of PSP to sell (caller must have approved this router)
    /// @param minMixOut Revert if the swap yields fewer mixETH shares
    /// @param deadline Revert if executed after this timestamp (0 = off)
    /// @param referrer Optional referral attribution (0x0 = unattributed)
    /// @return ethOut ETH forwarded to the caller
    function zapOut(PoolKey calldata key, uint256 pspIn, uint256 minMixOut, uint256 deadline, address referrer)
        external
        returns (uint256 ethOut)
    {
        if (pspIn == 0) revert ZeroAmount();
        if (deadline != 0 && block.timestamp > deadline) revert Expired();

        bool mixIsZero = Currency.unwrap(key.currency0) == address(mixETH);
        bool mixIsOne = Currency.unwrap(key.currency1) == address(mixETH);
        if (mixIsZero == mixIsOne) revert BadPool();

        IERC20 psp = IERC20(Currency.unwrap(mixIsZero ? key.currency1 : key.currency0));
        psp.safeTransferFrom(msg.sender, address(this), pspIn);

        bytes memory result = poolManager.unlock(
            abi.encode(SellData({
                key: key, pspIn: pspIn, pspToken: address(psp), to: msg.sender,
                trader: msg.sender, referrer: referrer
            }))
        );
        uint256 mixOut = abi.decode(result, (uint256));
        if (mixOut < minMixOut) revert InsufficientOutput();

        // Redeem mixETH -> ETH. The vault sends ETH to this contract;
        // forward everything from this swap to the caller.
        uint256 ethBefore = address(this).balance;
        mixETH.redeemETH(mixOut);
        ethOut = address(this).balance - ethBefore;
        (bool ok,) = msg.sender.call{value: ethOut}("");
        if (!ok) revert EthForwardFailed();
    }

    /// @notice Sell PSP for mixETH (no ETH leg).
    /// @param key The round's {mixETH, PSP} pool key (either currency sort)
    /// @param pspIn Amount of PSP to sell (caller must have approved this router)
    /// @param minMixOut Revert if the swap yields fewer mixETH shares
    /// @param deadline Revert if executed after this timestamp (0 = off)
    /// @param referrer Optional referral attribution (see zapOut)
    /// @return mixOut mixETH sent to the caller
    function sellToMix(PoolKey calldata key, uint256 pspIn, uint256 minMixOut, uint256 deadline, address referrer)
        external
        returns (uint256 mixOut)
    {
        if (pspIn == 0) revert ZeroAmount();
        if (deadline != 0 && block.timestamp > deadline) revert Expired();

        bool mixIsZero = Currency.unwrap(key.currency0) == address(mixETH);
        bool mixIsOne = Currency.unwrap(key.currency1) == address(mixETH);
        if (mixIsZero == mixIsOne) revert BadPool();

        address pspTokenAddr =
            Currency.unwrap(mixIsZero ? key.currency1 : key.currency0);
        IERC20(pspTokenAddr).safeTransferFrom(msg.sender, address(this), pspIn);

        bytes memory result = poolManager.unlock(
            abi.encode(SellData({
                key: key, pspIn: pspIn, pspToken: pspTokenAddr, to: msg.sender,
                trader: msg.sender, referrer: referrer
            }))
        );
        mixOut = abi.decode(result, (uint256));
        if (mixOut < minMixOut) revert InsufficientOutput();

        IERC20(address(mixETH)).safeTransfer(msg.sender, mixOut);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        SellData memory d = abi.decode(data, (SellData));

        bool mixIsZero = Currency.unwrap(d.key.currency0) == address(mixETH);
        Currency mixCur = mixIsZero ? d.key.currency0 : d.key.currency1;
        Currency pspCur = mixIsZero ? d.key.currency1 : d.key.currency0;

        // Pre-settle the exact PSP input: sync, transfer, settle
        poolManager.sync(pspCur);
        IERC20(d.pspToken).safeTransfer(address(poolManager), d.pspIn);
        poolManager.settle();

        // Sell: PSP -> mix. Price limit is the far bound in swap direction.
        // hookData carries (trader, referrer) for the 50bps referral
        // carve-out; empty when unattributed (fees then all go to stakers).
        BalanceDelta delta = poolManager.swap(
            d.key,
            SwapParams({
                amountSpecified: -int256(d.pspIn),
                sqrtPriceLimitX96: mixIsZero
                    ? TickMath.MAX_SQRT_PRICE - 1
                    : TickMath.MIN_SQRT_PRICE + 1,
                zeroForOne: !mixIsZero
            }),
            d.referrer != address(0) ? abi.encode(d.trader, d.referrer) : new bytes(0)
        );

        // mix delta is positive (owed to us); take it here so we can redeem.
        int256 mixDelta = mixIsZero ? delta.amount0() : delta.amount1();
        if (mixDelta <= 0) revert InsufficientOutput();
        uint256 mixOut = uint256(int256(mixDelta));

        poolManager.take(mixCur, address(this), mixOut);
        return abi.encode(mixOut);
    }

    /// @dev mixETH redeems ETH to this contract; anything else is a donation.
    receive() external payable {}
}
