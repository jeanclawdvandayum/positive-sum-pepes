// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IWeiNames} from "../src/interfaces/IWeiNames.sol";
import {PSPNameRegistrar} from "../src/names/PSPNameRegistrar.sol";
import {PSPRemoteNameGate} from "../src/names/PSPRemoteNameGate.sol";

/// @title DeployRemoteNames
/// @notice Deploy the approved remote eligibility integration on Ethereum or a
/// local Ethereum fork. Parent custody and activation are separate admin calls.
contract DeployRemoteNames is Script {
    uint256 constant TEST_PARENT = 6361740363536127648378182158538670061512393038427336338828631921647240523046;
    function run() external {
        require(block.chainid == 1 || block.chainid == 31337, "use Ethereum or its local fork");
        IWeiNames names = IWeiNames(0x0000000000696760E15f265e828DB644A0c242EB);
        require(address(names).codehash == 0x5b791c832d4373a8d4f977c37d6973a5dbe0924c6d287a2effaa549be31c0221,
            "unexpected WNS code: inspect before deploying");
        uint256 parent = vm.envOr("PSP_NAME_PARENT_ID", TEST_PARENT);
        address admin = vm.envAddress("PSP_NAME_ADMIN");
        address signer = vm.envAddress("PSP_NAME_SIGNER");
        address factory = vm.envAddress("PSP_NAME_FACTORY");
        uint256 sourceChain = vm.envUint("PSP_NAME_SOURCE_CHAIN_ID");
        require(names.ownerOf(parent) == admin, "admin must own the parent");
        require(signer != admin, "use a dedicated low-privilege permit signer");
        require(sourceChain == 84532 || sourceChain == 8453, "unsupported PSP source network");
        require(sourceChain != 84532 || parent == TEST_PARENT, "testnet eligibility is for pepetesters only");
        vm.startBroadcast();
        PSPRemoteNameGate gate = new PSPRemoteNameGate(admin, signer, sourceChain, factory);
        PSPNameRegistrar registrar = new PSPNameRegistrar(names, parent, admin, gate);
        vm.stopBroadcast();
        console.log("name registrar:", address(registrar));
        console.log("remote eligibility gate:", address(gate));
        console.log("permit signer:", signer);
        console.log("source chain:", sourceChain);
        console.log("source factory:", factory);
        console.log("parent remains with admin:", names.ownerOf(parent));
        console.log("registration enabled:", registrar.registrationEnabled());
    }
}
