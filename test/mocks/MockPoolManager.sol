// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockPoolManager — functional-enough IPoolManager for local e2e labs
/// @notice `initialize` forwards to the hook's gate (as before). `unlock`,
///         `swap`, `sync`, `settle`, `take` implement just enough lenient
///         flash accounting for a beforeSwapReturnDelta-style hook (like
///         CurveHook) that settles everything itself:
///           - sync(c) snapshots the PM's token balance
///           - settle() returns balance-now minus snapshot (ERC20 delta) or
///             msg.value (ETH), clearing the snapshot
///           - take(c, to, amt) pays tokens out of PM holdings
///           - swap() calls hook.beforeSwap and echoes its delta
///         No delta enforcement at unlock exit, no liquidity, no ERC-6909 —
///         strictly for demos/unit flows, never a substitute for the fork
///         integration suite.
contract MockPoolManager is IPoolManager {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    error NotSupported();
    error NotUnlocked();
    error NoActiveSync();

    /// @dev unlocker allowed to sync/settle/take/swap (v4: only inside unlock)
    address private _unlocker;

    /// @dev currency => balance snapshot taken at sync(); 0 = no snapshot
    mapping(Currency => uint256) private _syncedBalance;

    event Swapped(PoolKey key, SwapParams params, BeforeSwapDelta hookDelta);

    // ─────────────── v4 entry points ───────────────

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24) {
        IHooks(address(key.hooks)).beforeInitialize(msg.sender, key, sqrtPriceX96);
        return 0;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        if (_unlocker != address(0)) revert NotUnlocked();
        _unlocker = msg.sender;
        // typed call — a raw .call would double-offset-encode the return data
        // and callers' abi.decode would read the offset word (0x20) instead
        bytes memory result = IUnlockCallback(msg.sender).unlockCallback(data);
        _unlocker = address(0);
        return result;
    }

    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (BalanceDelta)
    {
        if (_unlocker == address(0)) revert NotUnlocked();

        (, BeforeSwapDelta hookDelta,) =
            IHooks(address(key.hooks)).beforeSwap(msg.sender, key, params, hookData);

        // afterSwap only when the hook enables it (v4 permission semantics)
        if (Hooks.hasPermission(IHooks(address(key.hooks)), Hooks.AFTER_SWAP_FLAG)) {
            IHooks(address(key.hooks)).afterSwap(
                msg.sender, key, params, BalanceDelta.wrap(0), hookData
            );
        }

        emit Swapped(key, params, hookDelta);

        // Derive the swapper's BalanceDelta from the hook's BeforeSwapDelta
        // (beforeSwapReturnDelta convention): specified side = what the
        // swapper paid (negative exact-in), unspecified side = the output the
        // hook provided (hookDelta.unspecified is negative → negate).
        int256 specified = params.amountSpecified;
        int256 unspecified = -int256(BeforeSwapDeltaLibrary.getUnspecifiedDelta(hookDelta));
        return params.zeroForOne
            ? toBalanceDelta(int128(specified), int128(unspecified))
            : toBalanceDelta(int128(unspecified), int128(specified));
    }

    // ─────────────── lenient flash accounting ───────────────

    function sync(Currency currency) external {
        if (_unlocker == address(0)) revert NotUnlocked();
        _syncedBalance[currency] = _balanceOf(currency);
        _lastSyncedCurrency = currency;
    }

    function settle() external payable returns (uint256) {
        if (_unlocker == address(0)) revert NotUnlocked();
        if (msg.value > 0) return msg.value; // native — no sync needed
        if (Currency.unwrap(_lastSyncedCurrency) == address(0)) revert NoActiveSync();
        uint256 paid = _balanceOf(_lastSyncedCurrency) - _syncedBalance[_lastSyncedCurrency];
        _syncedBalance[_lastSyncedCurrency] = 0;
        _lastSyncedCurrency = Currency.wrap(address(0));
        return paid;
    }

    function take(Currency currency, address to, uint256 amount) external {
        if (_unlocker == address(0)) revert NotUnlocked();
        if (Currency.unwrap(currency) != address(0)) {
            IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        } else {
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok,) = to.call{value: amount}("");
            require(ok, "ETHTransferFailed");
        }
    }

    // ─────────────── everything else stays unsupported ───────────────

    function modifyLiquidity(PoolKey memory, ModifyLiquidityParams memory, bytes calldata)
        external
        pure
        returns (BalanceDelta, BalanceDelta)
    { revert NotSupported(); }
    function donate(PoolKey memory, uint256, uint256, bytes calldata)
        external
        pure
        returns (BalanceDelta)
    { revert NotSupported(); }
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
    function transfer(address, uint256, uint256) external pure returns (bool) { revert NotSupported(); }
    function transferFrom(address, address, uint256, uint256) external pure returns (bool) { revert NotSupported(); }
    function approve(address, uint256, uint256) external pure returns (bool) { revert NotSupported(); }
    function allowance(address, address, uint256) external pure returns (uint256) { revert NotSupported(); }
    function totalSupply(uint256) external pure returns (uint256) { revert NotSupported(); }
    function isOperator(address, address) external pure returns (bool) { revert NotSupported(); }
    function setOperator(address, bool) external pure returns (bool) { revert NotSupported(); }

    // IExtsload / IExttload
    function extsload(bytes32) external pure returns (bytes32) { revert NotSupported(); }
    function extsload(bytes32, uint256) external pure returns (bytes32[] memory) { revert NotSupported(); }
    function extsload(bytes32[] calldata) external pure returns (bytes32[] memory) { revert NotSupported(); }
    function exttload(bytes32) external pure returns (bytes32) { revert NotSupported(); }
    function exttload(bytes32[] calldata) external pure returns (bytes32[] memory) { revert NotSupported(); }

    receive() external payable {}

    // ─────────────── internals ───────────────

    /// @dev most recent synced currency — settle() needs to know which token
    ///      without a Currency argument (v4 infers it from the caller's
    ///      reserves delta; the hook/zap pattern is strictly one-sync-at-a-time)
    Currency private _lastSyncedCurrency;

    function _balanceOf(Currency currency) private view returns (uint256) {
        return Currency.unwrap(currency) == address(0)
            ? address(this).balance
            : IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }
}
