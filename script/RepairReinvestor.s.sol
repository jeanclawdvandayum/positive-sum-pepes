// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {PSPZapIn} from "../src/PSPZapIn.sol";
import {PSPReinvestor} from "../src/PSPReinvestor.sol";
import {IPSPStaker} from "../src/interfaces/IPSPStaker.sol";
import {IPSPZapIn} from "../src/interfaces/IPSPZapIn.sol";
import {IMixETH} from "../src/interfaces/IMixETH.sol";

/// @title RepairReinvestor
/// @notice Testnet-only router replacement. Retains the current round and all assets.
contract RepairReinvestor is Script {
    function run() external {
        require(block.chainid == 84532, "Base Sepolia only");
        PSPFactory factory = PSPFactory(vm.envAddress("PSP_FACTORY"));
        uint256 id = factory.currentRoundId();
        require(id == vm.envUint("PSP_ROUND"), "round changed; recheck wiring");
        PSPFactory.Round memory r = factory.getRound(id);
        require(address(r.controller) != address(0) && !r.destroyed, "round unavailable");
        vm.startBroadcast();
        PSPZapIn zap = new PSPZapIn(IMixETH(address(factory.mixETH())), factory.poolManager());
        PSPReinvestor reinvestor = new PSPReinvestor(IPSPStaker(r.controller.stakerAddress()),
            IPSPZapIn(address(zap)), IERC20(address(factory.mixETH())), IERC20(address(r.token)));
        vm.stopBroadcast();
        console.log("round", id);
        console.log("replacement zap", address(zap));
        console.log("replacement reinvestor", address(reinvestor));
    }
}
