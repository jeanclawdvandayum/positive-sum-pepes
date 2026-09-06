// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IWeiNames} from "../src/interfaces/IWeiNames.sol";
import {PSPNameRegistrar} from "../src/names/PSPNameRegistrar.sol";
import {PSPStakeNameGate, INameGateFactory} from "../src/names/PSPStakeNameGate.sol";

/// @title DeployNames
/// @notice Local-fork rehearsal of the same-chain integration. Real Ethereum
/// deployment awaits the cross-chain eligibility decision in docs/audit/NAMES.md.
/// This script never transfers a parent domain or activates registrations.
contract DeployNames is Script {
    function run() external {
        require(block.chainid == 31337, "names rehearsal: use a local mainnet fork");
        IWeiNames names = IWeiNames(0x0000000000696760E15f265e828DB644A0c242EB);
        require(address(names).codehash == 0x5b791c832d4373a8d4f977c37d6973a5dbe0924c6d287a2effaa549be31c0221,
            "unexpected WNS code: inspect before deploying");
        uint256 parent = vm.envOr("PSP_NAME_PARENT_ID", uint256(6361740363536127648378182158538670061512393038427336338828631921647240523046));
        address admin = vm.envAddress("PSP_NAME_ADMIN");
        require(names.ownerOf(parent) == admin, "admin must own the parent");
        INameGateFactory factory = INameGateFactory(vm.envAddress("PSP_NAME_FACTORY"));
        // Verifies that a local PSP deployment exists; a Base Sepolia address
        // copied onto an Ethereum fork is not a cross-chain integration.
        (address token, address controller,,,,) = factory.rounds(1);
        require(token.code.length > 0 && controller.code.length > 0, "local PSP round missing");
        vm.startBroadcast();
        PSPStakeNameGate gate = new PSPStakeNameGate(factory);
        PSPNameRegistrar registrar = new PSPNameRegistrar(names, parent, admin, gate);
        vm.stopBroadcast();
        console.log("name registrar:", address(registrar));
        console.log("same-chain eligibility gate:", address(gate));
        console.log("parent remains with admin:", names.ownerOf(parent));
        console.log("registration enabled:", registrar.registrationEnabled());
    }
}
