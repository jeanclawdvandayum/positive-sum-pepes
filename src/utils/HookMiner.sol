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

    // C-1 remediation: per-pass iteration cap for the entropy-keyed miner.
    // A pass matches 14 exact flag bits (the 5 enabled + 9 cleared), i.e.
    // one candidate per ~2^14 iterations (~2-3M gas/pass, the same profile
    // the legacy find() had post-H-2). The cap tail-matches find(): a
    // >160k-iteration pass happens with p ~ 1/20,000 rounds and simply
    // reverts that attempt; the next block redraws with fresh entropy.
    uint256 constant MAX_ENTROPY_LOOP = 160_444;

    /// @notice Entropy-keyed candidate mining with scan resume (C-1 remediation)
    /// @dev Legacy find() scans salts 0,1,2,... so the mined address is a
    ///      function of public state alone — anyone could pre-deploy an
    ///      orphan at a future hook address and permanently collide the
    ///      round-spawn create2 (fork-verified 2026-08-18). Here the salt
    ///      space is offset by caller-supplied `entropy` (block context at
    ///      deploy time): salt_i = bytes32(uint256(entropy) + i). The base
    ///      is unpredictable before the block that supplies it, so the
    ///      candidate set is unknowable in advance; the per-iteration cost
    ///      matches find() exactly (one keccak over the 85-byte create2
    ///      preimage — salts are a search space, not secrets, so they need
    ///      no hash derivation of their own). Returns the FIRST flag match
    ///      at or after `fromIndex`, plus the resume cursor, so callers
    ///      fall through squatted addresses one extra mining pass each
    ///      (honest path: a single ~2^14 pass).
    /// @param entropy Domain separator for the salt space (keccak of
    ///        prevrandao/timestamp/number/controller at deploy time)
    /// @param fromIndex Salt index to resume scanning after (0 for the
    ///        first candidate; pass the returned nextFrom to advance)
    /// @return addr The first flag-matching candidate address at index >= fromIndex
    /// @return salt The salt that produces addr via create2
    /// @return nextFrom Index just past this match (scan-resume cursor)
    function nextCandidate(
        address deployer,
        bytes32 entropy,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs,
        uint256 fromIndex
    )
        internal
        view
        returns (address addr, bytes32 salt, uint256 nextFrom)
    {
        flags = flags & FLAG_MASK;
        bytes32 codeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        // Address preimage, allocated once; only the salt slot is rewritten
        // per iteration (the same hoisted-hash discipline as find()).
        // data = 0xFF | deployer | salt | codeHash (85 bytes)
        bytes memory data = abi.encodePacked(bytes1(0xFF), deployer, bytes32(uint256(0)), codeHash);
        uint256 base = uint256(entropy);

        for (uint256 i = fromIndex; i < MAX_ENTROPY_LOOP; i++) {
            assembly ("memory-safe") {
                // salt_i = entropy_base + i (counter-offset salt space)
                mstore(add(add(data, 0x20), 21), add(base, i))
                // address = last 20 bytes of keccak256(0xFF | deployer | salt_i | codeHash)
                let a := and(keccak256(add(data, 0x20), 85), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                // 0x3FFF == FLAG_MASK (14-bit all-ones); aliased constants
                // are not assembly-legal, only direct literals
                if eq(and(a, 0x3FFF), flags) {
                    addr := a
                    salt := add(base, i)
                }
            }
            if (addr != address(0)) return (addr, salt, i + 1);
        }
        revert("HookMiner: no candidate below cap");
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
