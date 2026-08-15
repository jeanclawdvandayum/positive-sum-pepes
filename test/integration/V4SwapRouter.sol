// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title V4SwapRouter - Minimal router for V4 swaps with custom curve hooks
/// @notice Implements unlock/callback: sync → transfer → settle (pre-fund PM),
///         then swap, then take output.
/// @dev Includes slippage protection and deadline check.
///      Uses pre-settle pattern because the hook calls poolManager.take() inside
///      beforeSwap, requiring PM to physically hold input tokens before swap fires.
contract V4SwapRouter {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;

    struct SwapCallbackData {
        PoolKey poolKey;
        SwapParams params;
        address sender;
        uint256 minOutput;  // slippage protection: minimum output tokens
        uint256 deadline;   // tx must execute before this timestamp
    }

    error Expired();
    error InsufficientOutput();
    error NotPoolManager();

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Swap with slippage and deadline protection
    /// @param key V4 pool key
    /// @param params Swap parameters (amountSpecified negative for exact input)
    /// @param minOutput Minimum output tokens to receive (0 = no slippage check)
    /// @param deadline Unix timestamp after which tx reverts (0 = no deadline)
    function swap(PoolKey calldata key, SwapParams calldata params, uint256 minOutput, uint256 deadline)
        external
        returns (BalanceDelta delta)
    {
        if (deadline > 0 && block.timestamp > deadline) revert Expired();

        SwapCallbackData memory data = SwapCallbackData({
            poolKey: key,
            params: params,
            sender: msg.sender,
            minOutput: minOutput,
            deadline: deadline
        });

        bytes memory returnData = poolManager.unlock(abi.encode(data));
        delta = abi.decode(returnData, (BalanceDelta));
    }

    /// @notice Simplified swap without slippage/deadline (backward compatible)
    function swap(PoolKey calldata key, SwapParams calldata params)
        external
        returns (BalanceDelta delta)
    {
        SwapCallbackData memory data = SwapCallbackData({
            poolKey: key,
            params: params,
            sender: msg.sender,
            minOutput: 0,
            deadline: 0
        });

        bytes memory returnData = poolManager.unlock(abi.encode(data));
        delta = abi.decode(returnData, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        SwapCallbackData memory decoded = abi.decode(data, (SwapCallbackData));

        bool zeroForOne = decoded.params.zeroForOne;
        Currency inCurrency = zeroForOne
            ? decoded.poolKey.currency0
            : decoded.poolKey.currency1;
        Currency outCurrency = zeroForOne
            ? decoded.poolKey.currency1
            : decoded.poolKey.currency0;
        uint256 inputAmount = uint256(-decoded.params.amountSpecified);

        // 1. Pre-settle: sync FIRST (records old balance), then transfer, then settle
        poolManager.sync(inCurrency);
        IERC20(Currency.unwrap(inCurrency)).safeTransferFrom(
            decoded.sender,
            address(poolManager),
            inputAmount
        );
        poolManager.settle();

        // 2. Swap (hook fires, calls take/settle, returns BeforeSwapDelta)
        BalanceDelta delta = poolManager.swap(decoded.poolKey, decoded.params, "");

        // 3. Take output only (positive deltas)
        int256 amt0 = delta.amount0();
        int256 amt1 = delta.amount1();

        if (amt0 > 0) {
            poolManager.take(decoded.poolKey.currency0, decoded.sender, uint256(amt0));
        }
        if (amt1 > 0) {
            poolManager.take(decoded.poolKey.currency1, decoded.sender, uint256(amt1));
        }

        // 4. Slippage check: verify output >= minOutput
        if (decoded.minOutput > 0) {
            uint256 outputAmount = zeroForOne ? uint256(amt1) : uint256(amt0);
            if (outputAmount < decoded.minOutput) revert InsufficientOutput();
        }

        return abi.encode(delta);
    }
}
