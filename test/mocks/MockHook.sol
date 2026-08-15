// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockHook - Minimal hook stand-in for controller tests
/// @notice Implements just the functions the controller calls on CurveHook,
///         with real mixETH transfers for fee distribution.
contract MockHook {
    IERC20 public immutable mixETH;
    uint256 public reserveMixETH;
    uint256 public totalSupplyPSP;
    bool public poolInitialized;

    // Mirror CurveHook.Mode for type compatibility
    enum Mode { Predeposit, Active, Flat, Destroyed }
    Mode public mode = Mode.Predeposit;

    constructor(address _mixETH) {
        mixETH = IERC20(_mixETH);
    }

    error InsufficientFees();

    function sendFees(address to, uint256 mixETHAmount) external {
        // Mirror real CurveHook: available = balance - reserve; cap-checked
        uint256 available = mixETH.balanceOf(address(this)) - reserveMixETH;
        if (mixETHAmount > available) revert InsufficientFees();
        mixETH.transfer(to, mixETHAmount);
    }

    function drainAll(address to) external returns (uint256) {
        uint256 bal = mixETH.balanceOf(address(this));
        if (bal > 0) mixETH.transfer(to, bal);
        reserveMixETH = 0;
        return bal;
    }

    function setMode(uint8 newMode) external {
        // Real transition (needed for Z-1 guard tests: lock() checks mode)
        mode = Mode(newMode);
    }

    function getFlatPrice() external view returns (uint256) {
        if (totalSupplyPSP == 0) return 0;
        return (mixETH.balanceOf(address(this)) * 1e18) / totalSupplyPSP;
    }

    function totalReserveETH() external view returns (uint256) {
        return mixETH.balanceOf(address(this)) - reserveMixETH;
    }

    function initializeCurve(uint256 _reserveMixETH, uint256 _initialSupply) external {
        require(!poolInitialized, "Already initialized");
        reserveMixETH = _reserveMixETH;
        totalSupplyPSP = _initialSupply;
        poolInitialized = true;
    }
}
