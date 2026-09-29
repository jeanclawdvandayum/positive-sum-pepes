// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {DeploymentSupport} from "./DeploymentSupport.sol";

import {PSPFactory} from "../src/PSPFactory.sol";
import {PSPGraveZap} from "../src/PSPGraveZap.sol";

/// @title DeployGraveZap — the one-transaction graveyard exit router.
/// @notice PSPGraveZap pins ONLY the mixETH token (one deployment serves
///         every round of that mix deployment — the hook and staker are
///         per-call arguments), so unlike DeployReinvestor this needs no
///         second-pass round reads: deploy once, point VITE_GRAVE_ZAP at it.
///
///         The frontend's "exit round" button (pot claim + fee claim +
///         unlock + fee-free PSP redemption in ONE transaction) stays hidden
///         until this address is set.
///
/// Env:
///   PSP_FACTORY  deployed PSPFactory (required, for validation + the mix pin)
///   PSP_TESTNET  true for Base Sepolia checks; PSP_ANVIL for local mocks
contract DeployGraveZap is DeploymentSupport {
    function run() external {
        bool testnet = vm.envOr("PSP_TESTNET", false);
        _validateModes(vm.envOr("PSP_ANVIL", false), testnet);
        PSPFactory factory = PSPFactory(vm.envAddress("PSP_FACTORY"));
        _validateFactory(factory, testnet);
        // mix pin only — the zap takes hook/staker per call, so it serves
        // settled and live rounds alike (a settled factory is fine here)
        address mix = address(factory.mixETH());

        vm.startBroadcast();
        PSPGraveZap zap = new PSPGraveZap(mix);
        vm.stopBroadcast();

        console.log("grave zap:", address(zap));
        console.log("mixETH:", mix);
        console.log("factory:", address(factory));
    }
}
