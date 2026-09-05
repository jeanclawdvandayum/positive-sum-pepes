// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title GameRules
/// @notice Purchase thresholds denominated in gross mixETH, including fees.
library GameRules {
    uint256 internal constant MIN_BUY = 0.005 ether;
    uint256 internal constant SECONDS_PER_UNIT = 4 minutes + 20 seconds;
}
