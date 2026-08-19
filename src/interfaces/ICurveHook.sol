// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal CurveHook surface for PSPStaker (avoids importing the
///         full hook — EIP-170 discipline on the staker's embedded creation
///         code inside RoundController).
interface ICurveHook {
    enum Mode { Predeposit, Active, Flat, Destroyed }

    function mode() external view returns (Mode);
    function sendFees(address to, uint256 mixETHAmount) external;
}
