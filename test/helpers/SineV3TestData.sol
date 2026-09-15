// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @title SineV3TestData
/// @notice Deploy the actual generated creation artifacts without embedding
/// their 85KB payload in every test contract. Production scripts use the
/// ordinary SineV3Data utility. These CREATEs retain constructor checks,
/// returned runtime bytes, and deployment gas; no code is installed with etch.
library SineV3TestData {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function deploy() internal returns (address[4] memory shards) {
        for (uint256 i; i < 4; ++i) {
            bytes memory code = VM.getCode(string.concat("SineV3Data.sol:SineV3Data", VM.toString(i)));
            address shard;
            assembly ("memory-safe") { shard := create(0, add(code, 32), mload(code)) }
            require(shard != address(0) && shard.code.length != 0, "sine data deployment failed");
            shards[i] = shard;
        }
    }
}
