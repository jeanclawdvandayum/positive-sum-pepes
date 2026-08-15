// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title MockPoolManager - Minimal IPoolManager stand-in for unit tests
/// @notice Only `initialize` does real work (forwards to the hook's
///         beforeInitialize, mirroring v4-core PoolManager behavior so the
///         CurveHook pool-key gate is exercised end-to-end). Every other
///         function reverts — the unit suite never swaps or manages liquidity
///         through a PoolManager (that's what the fork integration suite is for).
contract MockPoolManager is IPoolManager {
    error NotSupported();

    /// @dev Mirrors PoolManager.initialize: calls the hook's beforeInitialize
    ///      gate (which validates the canonical currency pair).
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24) {
        IHooks(address(key.hooks)).beforeInitialize(msg.sender, key, sqrtPriceX96);
        return 0;
    }

    function unlock(bytes calldata) external pure returns (bytes memory) { revert NotSupported(); }
    function modifyLiquidity(PoolKey memory, ModifyLiquidityParams memory, bytes calldata)
        external
        pure
        returns (BalanceDelta, BalanceDelta)
    { revert NotSupported(); }
    function swap(PoolKey memory, SwapParams memory, bytes calldata)
        external
        pure
        returns (BalanceDelta)
    { revert NotSupported(); }
    function donate(PoolKey memory, uint256, uint256, bytes calldata)
        external
        pure
        returns (BalanceDelta)
    { revert NotSupported(); }
    function sync(Currency) external pure { revert NotSupported(); }
    function take(Currency, address, uint256) external pure { revert NotSupported(); }
    function settle() external payable returns (uint256) { revert NotSupported(); }
    function settleFor(address) external payable returns (uint256) { revert NotSupported(); }
    function clear(Currency, uint256) external pure { revert NotSupported(); }
    function mint(address, uint256, uint256) external pure { revert NotSupported(); }
    function burn(address, uint256, uint256) external pure { revert NotSupported(); }
    function updateDynamicLPFee(PoolKey memory, uint24) external pure { revert NotSupported(); }

    // IProtocolFees
    function protocolFeesAccrued(Currency) external pure returns (uint256) { revert NotSupported(); }
    function setProtocolFee(PoolKey memory, uint24) external pure { revert NotSupported(); }
    function setProtocolFeeController(address) external pure { revert NotSupported(); }
    function collectProtocolFees(address, Currency, uint256) external pure returns (uint256) { revert NotSupported(); }
    function protocolFeeController() external pure returns (address) { revert NotSupported(); }

    // IERC6909Claims
    function balanceOf(address, uint256) external pure returns (uint256) { revert NotSupported(); }
    function allowance(address, address, uint256) external pure returns (uint256) { revert NotSupported(); }
    function isOperator(address, address) external pure returns (bool) { revert NotSupported(); }
    function transfer(address, uint256, uint256) external pure returns (bool) { revert NotSupported(); }
    function transferFrom(address, address, uint256, uint256) external pure returns (bool) { revert NotSupported(); }
    function approve(address, uint256, uint256) external pure returns (bool) { revert NotSupported(); }
    function setOperator(address, bool) external pure returns (bool) { revert NotSupported(); }

    // IExtsload
    function extsload(bytes32) external pure returns (bytes32) { revert NotSupported(); }
    function extsload(bytes32, uint256) external pure returns (bytes32[] memory) { revert NotSupported(); }
    function extsload(bytes32[] calldata) external pure returns (bytes32[] memory) { revert NotSupported(); }

    // IExttload
    function exttload(bytes32) external pure returns (bytes32) { revert NotSupported(); }
    function exttload(bytes32[] calldata) external pure returns (bytes32[] memory) { revert NotSupported(); }
}
