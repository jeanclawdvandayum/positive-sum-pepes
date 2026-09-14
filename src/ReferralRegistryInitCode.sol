// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PSPReferralRegistry} from "./PSPReferralRegistry.sol";

/// @title ReferralRegistryInitCode
/// @notice Holds registry creation code so ControllerDeployer stays within EIP-170.
contract ReferralRegistryInitCode {
    /// @notice Build the exact creation program shared by prediction and deployment.
    function registryInitCode(address staker, uint256 minStakePSP) external pure returns (bytes memory) {
        return abi.encodePacked(type(PSPReferralRegistry).creationCode, abi.encode(staker, minStakePSP));
    }
}
