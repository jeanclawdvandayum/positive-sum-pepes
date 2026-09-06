// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {DeploymentSupport} from "./DeploymentSupport.sol";
import {PSPFactory} from "../src/PSPFactory.sol";

/// @title CompleteGenesis
/// @notice Resume only the unfinished genesis phase. Reads configuration from
/// PSP_FACTORY on chain; completed phases and an existing reservation are kept.
contract CompleteGenesis is DeploymentSupport {
    function run() external {
        bool testnet = vm.envOr("PSP_TESTNET", false);
        _validateModes(vm.envOr("PSP_ANVIL", false), testnet);
        PSPFactory factory = PSPFactory(vm.envAddress("PSP_FACTORY"));
        _validateFactory(factory, testnet);
        _completeGenesis(factory);
        console.log("completed round:", factory.currentRoundId());
    }
}
