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
    /// @return hookAddress The address the hook deploys to when using the returned salt with the syntax: `new Hook{salt: salt}(<constructor arguments>)`
    /// @return salt The mined salt that produces hookAddress
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
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
        // keccak per iteration.
        //
        // 2026-08-19 (wave2b perf): the scan loop was re-cut as ONE assembly
        // block. The old shape (per-iteration Solidity counter upkeep around an
        // `assembly` island, match test on the masked address) measured ~180
        // gas/iter; the Yul loop matches on the RAW hash word (its low 14 bits
        // equal the address's low 14 bits, so the 160-bit mask is applied only
        // on match) at ~85 gas/iter. Visited candidates, order, salt values,
        // and revert strings are unchanged.
        bytes memory data = abi.encodePacked(bytes1(0xFF), deployer, bytes32(uint256(0)), codeHash);

        assembly ("memory-safe") {
            let ptr := add(data, 0x20)
            let sp := add(ptr, 21) // salt slot: bytes 21..52 of the 85-byte preimage
            // NOTE: no `break` — under via_ir the Yul optimizer's control-flow
            // passes choke on assembly for+break here (compile blowup,
            // observed 2026-08-19). The found flag doubles as the loop
            // condition: addr is written only on match.
            // 0x3FFF == FLAG_MASK (14-bit all-ones); aliased constants are
            // not assembly-legal, only direct literals
            for { let s := 0 } and(lt(s, 0x2733c), iszero(hookAddress)) { s := add(s, 1) } {
                mstore(sp, s)
                let h := keccak256(ptr, 85)
                if eq(and(h, 0x3FFF), flags) {
                    // address = low 160 bits of the same hash word
                    hookAddress := and(h, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    salt := s
                }
            }
        }
        if (hookAddress == address(0)) revert("HookMiner: could not find salt");
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
    ///      2026-08-19 (wave2b perf): loop re-cut as ONE Yul block (~180 →
    ///      ~87 gas/iter measured) — same salt space, order, and outputs;
    ///      see find() for the hoisting technique. The scan is UNROLLED ×8:
    ///      keccak256(85B)=48 gas dominates, but the per-candidate loop
    ///      upkeep (counter, condition, back-edge jump, deep dups) measured
    ///      ~67 gas on top when each candidate owned a full lap. Eight
    ///      candidates per lap amortizes the lap overhead to ~3 gas and
    ///      replaces the per-iteration `add(base, i)` with a running
    ///      `v := v + 8`. Two counters advance in lockstep (`j` for the cap
    ///      bound, `v = base + j` for the salt word) so the tested candidate
    ///      sequence is IDENTICAL to the rolled loop for every (base,
    ///      fromIndex) pair, including across 2^256 wrap; first-match-wins is
    ///      preserved by an `fa == 0` guard on the capture path (a later
    ///      candidate in the same lap may also match but must not overwrite).
    ///      A ≤7-candidate rolled tail covers the final partial lap up to
    ///      the exact cap; beyond it the original revert fires unchanged.
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
        // historical 160,572-candidate cap preserved verbatim for every
        // existing caller (deployHook); the staged-spawn path passes its
        // own, block-limit-aware bound via nextCandidateCapped below.
        (addr, salt, nextFrom) =
            nextCandidateCapped(deployer, entropy, flags, creationCode, constructorArgs, fromIndex, 0x2733c);
    }

    /// @dev Identical scan, caller-supplied candidate cap. The staged-spawn
    ///      reserve uses ~65k (≈5.7M gas @ ~87 gas/iter — comfortably inside
    ///      Base's per-tx cap) so a flag-mine can NEVER blow the block limit:
    ///      exhaustion reverts the (deposit-free) reserve tx and the next
    ///      block's entropy re-rolls the salt space. First-match-wins,
    ///      candidate ordering, and outputs are bit-identical to the
    ///      unbounded variant run under the same cap.
    function nextCandidateCapped(
        address deployer,
        bytes32 entropy,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs,
        uint256 fromIndex,
        uint256 cap
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

        assembly ("memory-safe") {
            let ptr := add(data, 0x20)
            let sp := add(ptr, 21) // salt slot: bytes 21..52 of the 85-byte preimage
            // 0x3FFF == FLAG_MASK (14-bit all-ones); aliased constants are not
            // assembly-legal, only direct literals. The match test runs on the
            // RAW hash word (low 14 bits == address's low 14 bits); the 160-bit
            // address mask is applied only once, on match. fa doubles as the
            // found flag: written only on match, so loops exit via their
            // conditions. j counts candidates from fromIndex; v = base + j is
            // the salt word mstored into the preimage. No `break` (see find()).
            let fa := 0
            let fs := 0
            let fn := 0
            let v := add(base, fromIndex)
            let j := fromIndex
            // lapBound = cap - 7: while j < lapBound, all eight j..j+7 are < cap
            let lapBound := sub(cap, 7)
            for { } and(lt(j, lapBound), iszero(fa)) {
                j := add(j, 8)
                v := add(v, 8)
            } {
                // k=0: fa is 0 here (lap condition), no guard needed
                mstore(sp, v)
                let h := keccak256(ptr, 85)
                if eq(and(h, 0x3FFF), flags) {
                    fa := and(h, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    fs := v
                    fn := add(j, 1)
                }
                // k=1..7: guarded by fa == 0 so the FIRST match of the lap wins
                let vk := add(v, 1)
                mstore(sp, vk)
                h := keccak256(ptr, 85)
                if and(iszero(fa), eq(and(h, 0x3FFF), flags)) {
                    fa := and(h, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    fs := vk
                    fn := add(j, 2)
                }
                vk := add(v, 2)
                mstore(sp, vk)
                h := keccak256(ptr, 85)
                if and(iszero(fa), eq(and(h, 0x3FFF), flags)) {
                    fa := and(h, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    fs := vk
                    fn := add(j, 3)
                }
                vk := add(v, 3)
                mstore(sp, vk)
                h := keccak256(ptr, 85)
                if and(iszero(fa), eq(and(h, 0x3FFF), flags)) {
                    fa := and(h, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    fs := vk
                    fn := add(j, 4)
                }
                vk := add(v, 4)
                mstore(sp, vk)
                h := keccak256(ptr, 85)
                if and(iszero(fa), eq(and(h, 0x3FFF), flags)) {
                    fa := and(h, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    fs := vk
                    fn := add(j, 5)
                }
                vk := add(v, 5)
                mstore(sp, vk)
                h := keccak256(ptr, 85)
                if and(iszero(fa), eq(and(h, 0x3FFF), flags)) {
                    fa := and(h, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    fs := vk
                    fn := add(j, 6)
                }
                vk := add(v, 6)
                mstore(sp, vk)
                h := keccak256(ptr, 85)
                if and(iszero(fa), eq(and(h, 0x3FFF), flags)) {
                    fa := and(h, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    fs := vk
                    fn := add(j, 7)
                }
                vk := add(v, 7)
                mstore(sp, vk)
                h := keccak256(ptr, 85)
                if and(iszero(fa), eq(and(h, 0x3FFF), flags)) {
                    fa := and(h, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    fs := vk
                    fn := add(j, 8)
                }
            }
            // rolled tail: the final (cap - j) < 8 candidates, in order
            for { } and(lt(j, cap), iszero(fa)) {
                j := add(j, 1)
                v := add(v, 1)
            } {
                mstore(sp, v)
                let h := keccak256(ptr, 85)
                if eq(and(h, 0x3FFF), flags) {
                    fa := and(h, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                    fs := v
                    fn := add(j, 1)
                }
            }
            addr := fa
            salt := fs
            nextFrom := fn
        }
        if (addr == address(0)) revert("HookMiner: no candidate below cap");
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
