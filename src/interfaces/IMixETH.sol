// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal mixETH vault interface the zap routers need.
///         depositETH mints shares at the current exchange rate;
///         redeemETH burns shares and sends ETH back to the caller.
interface IMixETH {
    function depositETH() external payable returns (uint256 shares);
    function redeemETH(uint256 shareAmount) external returns (uint256 ethOut);
}
