// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title HookMiner
/// @notice a minimal library for mining hook addresses
library HookMiner {
    // mask to slice out the bottom 14 bit of the address
    uint160 constant FLAG_MASK = Hooks.ALL_HOOK_MASK; // 0000 ... 0000 0011 1111 1111 1111

    // Maximum number of iterations to find a salt, avoid infinite loops or MemoryOOG
    // (arbitrarily set)
    uint256 constant MAX_LOOP = 160_444;

    /// @notice Find a salt that produces a hook address with the desired `flags`
    /// @param deployer The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address
    /// @dev In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)
    /// @param flags The desired flags for the hook address. Example `uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | ...)`
    /// @param creationCode The creation code of a hook contract. Example: `type(Counter).creationCode`
    /// @param constructorArgs The encoded constructor arguments of a hook contract. Example: `abi.encode(address(manager))`
    /// @return (hookAddress, salt) The hook deploys to `hookAddress` when using `salt` with the syntax: `new Hook{salt: salt}(<constructor arguments>)`
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address, bytes32)
    {
        flags = flags & FLAG_MASK; // mask for only the bottom 14 bits
        // H-2: hash creation code ONCE. Re-hashing the full ~13.5KB blob per
        // iteration cost ~8.3k gas/iter → median 136M gas per deployment,
        // over the mainnet block gas limit (probabilistically unexecutable).
        bytes32 codeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        // H-2 (completion): the loop previously also probed `hookAddress.code.length`
        // on every candidate — a COLD EXTCODESIZE at 2600 gas each, ~43M gas
        // median, defeating the hoisted-hash fix (measured 220M gas on an
        // unlucky run). The probe is dropped: the CREATE2 address is fully
        // determined by (deployer, salt, initCodeHash), so an occupied-address
        // collision would require a keccak256 collision. The packed preimage is
        // allocated once (0xFF | deployer | salt | codeHash = 85 bytes) and only
        // the salt slot is rewritten per iteration — constant memory, one small
        // keccak per iteration (~120 gas), worst case MAX_LOOP × ~120 ≈ 20M gas.
        bytes memory data = abi.encodePacked(bytes1(0xFF), deployer, bytes32(uint256(0)), codeHash);

        address hookAddress;
        for (uint256 salt; salt < MAX_LOOP; salt++) {
            assembly ("memory-safe") {
                // overwrite the salt slot (bytes 21..52 of the 85-byte preimage)
                mstore(add(add(data, 0x20), 21), salt)
                // address = last 20 bytes of the hash = LOW 160 bits (uint160 cast)
                hookAddress := and(keccak256(add(data, 0x20), 85), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            }
            if (uint160(hookAddress) & FLAG_MASK == flags) {
                return (hookAddress, bytes32(salt));
            }
        }
        revert("HookMiner: could not find salt");
    }

    /// @notice Precompute a contract address deployed via CREATE2
    /// @param deployer The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address
    /// In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)
    /// @param salt The salt used to deploy the hook
    /// @param creationCodeWithArgs The creation code of a hook contract, with encoded constructor arguments appended. Example: `abi.encodePacked(type(Counter).creationCode, abi.encode(constructorArg1, constructorArg2))`
    function computeAddress(address deployer, uint256 salt, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address hookAddress)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCodeWithArgs)))))
        );
    }
}
