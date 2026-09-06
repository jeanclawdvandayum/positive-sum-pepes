// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {DeploymentSupport} from "./DeploymentSupport.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PSPFactory} from "../src/PSPFactory.sol";
import {PSPZapIn} from "../src/PSPZapIn.sol";
import {PSPReinvestor} from "../src/PSPReinvestor.sol";
import {IPSPStaker} from "../src/interfaces/IPSPStaker.sol";
import {IPSPZapIn} from "../src/interfaces/IPSPZapIn.sol";

/// @title DeployReinvestor — second pass for the claim-and-compound router
///        (2026-08-30).
/// @notice Why a second script: staged round addresses are salted from BLOCK
///         ENTROPY. A forge script's local simulation mines different salts
///         than its broadcast, so any address read from round state INSIDE
///         the deploying script is the sim's, not the chain's — the original
///         single-pass DeployPSP built PSPReinvestor's constructor args from
///         sim state and reverted on-chain (forceApprove against a codeless
///         token). This script runs AFTER DeployPSP's broadcast has landed
///         and reads the REAL round from the RPC, so sim == chain.
///
/// Env:
///   PSP_FACTORY  deployed PSPFactory (required)
///   PSP_ZAPIN    owner-attributing router from the same release (required)
///   PSP_ROUND    completed current round (defaults to factory.currentRoundId)
///   PSP_TESTNET  true for Base Sepolia checks; PSP_ANVIL for local mocks
contract DeployReinvestor is DeploymentSupport {
    function run() external {
        bool testnet = vm.envOr("PSP_TESTNET", false);
        _validateModes(vm.envOr("PSP_ANVIL", false), testnet);
        PSPFactory factory = PSPFactory(vm.envAddress("PSP_FACTORY"));
        _validateFactory(factory, testnet);
        uint256 roundId = vm.envOr("PSP_ROUND", factory.currentRoundId());
        PSPZapIn zapIn = PSPZapIn(vm.envAddress("PSP_ZAPIN"));
        _validateZapIn(address(zapIn), factory);
        PSPFactory.Round memory r = _validateCurrentRound(factory, roundId);

        vm.startBroadcast();
        PSPReinvestor reinvestor =
            new PSPReinvestor(IPSPStaker(r.controller.stakerAddress()), IPSPZapIn(address(zapIn)), IERC20(address(factory.mixETH())), IERC20(address(r.token)));
        vm.stopBroadcast();
        require(reinvestor.ATTRIBUTION_VERSION() == 1, "reinvestor attribution mismatch");

        console.log("round:", roundId);
        console.log("token:", address(r.token));
        console.log("controller:", address(r.controller));
        console.log("hook:", address(r.hook));
        console.log("reinvestor:", address(reinvestor));
    }
}
