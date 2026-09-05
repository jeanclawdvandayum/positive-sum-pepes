// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {Curve1Zones} from "../src/curves/Curve1Zones.sol";

/// @title CompleteGenesis — finish a deploy where the birth steps didn't fire.
contract CompleteGenesis is Script {
    function run() external {
        PSPFactory factory = PSPFactory(vm.envAddress("PSP_FACTORY"));
        bool testnet = vm.envOr("PSP_TESTNET", false);

        if (factory.currentRoundId() != 0) {
            console.log("round already live:", factory.currentRoundId());
            return;
        }

        CurveMath.CurveConfig memory cc = Curve1Zones.config();
        cc.timings = testnet
            ? CurveMath.packTimingsCapped(
                vm.envOr("PSP_PREDEPOSIT_SEC", uint256(2 hours)),
                vm.envOr("PSP_VEST_SEC", uint256(1 hours)),
                vm.envOr("PSP_DET_SEC", uint256(2 hours)),
                vm.envOr("PSP_WALLET_CAP_MIX", uint256(0))
            )
            : 0;

        vm.startBroadcast();
        factory.reserveGenesis(PSPFactory.RoundParams({
            name: "Positive Sum Pepes", symbol: "PSP", curveConfig: cc
        }));
        vm.stopBroadcast();
        console.log("reserveGenesis done, active:", factory.reservationActive());

        vm.startBroadcast();
        factory.birthStep();
        vm.stopBroadcast();
        console.log("birthStep 1 done, phase:", factory.reservationPhase());

        vm.startBroadcast();
        factory.birthStep();
        vm.stopBroadcast();
        console.log("birthStep 2 done, phase:", factory.reservationPhase());

        vm.startBroadcast();
        factory.birthStep();
        vm.stopBroadcast();
        console.log("birthStep 3 done, currentRoundId:", factory.currentRoundId());
    }
}
