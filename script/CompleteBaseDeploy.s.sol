// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PSPFactory} from "../src/PSPFactory.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {Curve1Zones} from "../src/curves/Curve1Zones.sol";
import {PSPZapIn} from "../src/PSPZapIn.sol";
import {PSPZapOut} from "../src/PSPZapOut.sol";
import {IMixETH} from "../src/interfaces/IMixETH.sol";

/// @title CompleteBaseDeploy — finish a DeployPSP broadcast that a node's
///        per-tx gas cap cut short.
/// @notice 2026-09-03 Base Sepolia: the genesis deployRound leg (~12M
///        constant + salt-mine tail, see PSPFactory staging notes) breached
///        the RPC's per-tx cap ON SEND after mocks/factory/sine landed.
///        This script finishes the remaining legs idempotently: each leg
///        checks chain state first, so re-running is safe. If the birth
///        still bounces on send, just retry — every attempt re-rolls the
///        mine entropy and a failed send costs nothing.
/// Env: PSP_FACTORY (required), PSP_TESTNET + timing knobs (same as
///      DeployPSP), PSP_HTML (default script/app.html).
contract CompleteBaseDeploy is Script {
    function run() external {
        PSPFactory factory = PSPFactory(vm.envAddress("PSP_FACTORY"));
        bool testnet = vm.envOr("PSP_TESTNET", false);

        // 1) genesis round — owner reserves, then 3 permissionless birth
        //    steps (each its own tx, deterministic, under every per-tx cap)
        uint256 roundId = factory.currentRoundId();
        if (roundId == 0) {
            if (!factory.reservationActive()) {
                CurveMath.CurveConfig memory cc = Curve1Zones.config();
                cc.timings = testnet
                    ? CurveMath.packTimingsCapped(
                        vm.envOr("PSP_PREDEPOSIT_SEC", uint256(2 hours)),
                        vm.envOr("PSP_VEST_SEC", uint256(1 hours)),
                        vm.envOr("PSP_DET_SEC", uint256(2 hours)),
                        vm.envOr("PSP_WALLET_CAP_MIX", uint256(10))
                    )
                    : 0;
                vm.startBroadcast();
                factory.reserveGenesis(
                    PSPFactory.RoundParams({name: "Positive Sum Pepes", symbol: "PSP", curveConfig: cc})
                );
                vm.stopBroadcast();
            }
            for (uint256 i; i < 4 && factory.currentRoundId() == 0; i++) {
                vm.startBroadcast();
                factory.birthStep(); // 1..3; a 4th call reverting is harmless
                vm.stopBroadcast();
            }
            require(factory.currentRoundId() != 0, "genesis birth did not complete");
            roundId = factory.currentRoundId();
            console.log("round born:", roundId);
        } else {
            console.log("round already live:", roundId);
        }

        // 2) on-chain UI — skip if already published
        if (bytes(factory.html()).length == 0) {
            string memory h = vm.readFile(vm.envOr("PSP_HTML", string("script/app.html")));
            h = vm.replace(h, "__FACTORY__", vm.toString(address(factory)));
            vm.startBroadcast();
            factory.setHtml(h);
            vm.stopBroadcast();
            console.log("ui bytes:", bytes(h).length);
        } else {
            console.log("ui already published");
        }

        // 3) quality-of-life routers (standalone contracts; the UI gets
        //    their addresses from env, the reinvestor pass needs zapIn)
        vm.startBroadcast();
        IPoolManager pm = factory.poolManager();
        IMixETH mix = IMixETH(address(factory.mixETH()));
        PSPZapIn zapIn = new PSPZapIn(mix, pm);
        PSPZapOut zapOut = new PSPZapOut(mix, pm);
        vm.stopBroadcast();
        console.log("zapIn:", address(zapIn));
        console.log("zapOut:", address(zapOut));
        console.log("factory:", address(factory));
    }
}
