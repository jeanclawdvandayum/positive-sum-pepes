// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {DeploymentSupport} from "./DeploymentSupport.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {PSPZapIn} from "../src/PSPZapIn.sol";
import {PSPZapOut} from "../src/PSPZapOut.sol";
import {IMixETH} from "../src/interfaces/IMixETH.sol";

/// @title CompleteBaseDeploy
/// @notice Resume genesis after factory, descriptor and sine configuration land.
/// Provide PSP_ZAPIN / PSP_ZAPOUT to reuse already deployed routers. Missing
/// router addresses deploy fresh instances, so retain their successful receipts.
/// PSP_TESTNET defaults the embedded page to the read-only testnet record.
contract CompleteBaseDeploy is DeploymentSupport {
    function run() external {
        bool testnet = vm.envOr("PSP_TESTNET", false);
        _validateModes(vm.envOr("PSP_ANVIL", false), testnet);
        PSPFactory factory = PSPFactory(vm.envAddress("PSP_FACTORY"));
        _validateFactory(factory, testnet);
        address zapIn = vm.envOr("PSP_ZAPIN", address(0));
        address zapOut = vm.envOr("PSP_ZAPOUT", address(0));
        // Validate supplied routers and the HTML input before any new writes.
        if (zapIn != address(0)) _validateZapIn(zapIn, factory);
        if (zapOut != address(0)) _validateZapOut(zapOut, factory);
        bool publishHtml = bytes(factory.html()).length == 0;
        string memory html;
        if (publishHtml) {
            require(factory.owner() == msg.sender, "HTML publication requires factory owner");
            html = vm.replace(vm.readFile(_htmlPath(testnet)), "__FACTORY__", vm.toString(address(factory)));
        }

        _completeGenesis(factory);
        _validateCurrentRound(factory, factory.currentRoundId());
        if (publishHtml) {
            vm.startBroadcast();
            factory.setHtml(html);
            vm.stopBroadcast();
        }
        if (zapIn == address(0)) {
            vm.startBroadcast();
            zapIn = address(new PSPZapIn(IMixETH(address(factory.mixETH())), factory.poolManager()));
            vm.stopBroadcast();
        }
        if (zapOut == address(0)) {
            vm.startBroadcast();
            zapOut = address(new PSPZapOut(IMixETH(address(factory.mixETH())), factory.poolManager()));
            vm.stopBroadcast();
        }
        console.log("round:", factory.currentRoundId());
        console.log("factory:", address(factory));
        console.log("zapIn:", zapIn);
        console.log("zapOut:", zapOut);
    }
}
