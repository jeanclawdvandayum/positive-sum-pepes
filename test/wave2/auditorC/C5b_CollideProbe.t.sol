// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// Minimal characterization: what does create2 into an OCCUPIED address cost
/// (revm)? Pure EVM semantics probe — no protocol contracts involved.
contract Tiny {
    uint256 public x;
    constructor(uint256 v) {
        x = v;
    }
}

contract CollideProbe is Test {
    function deploy(bytes32 salt, uint256 v) internal returns (address a) {
        bytes memory code = abi.encodePacked(type(Tiny).creationCode, abi.encode(v));
        assembly ("memory-safe") {
            a := create2(0, add(code, 0x20), mload(code), salt)
        }
    }

    function test_collisionCost() public {
        bytes32 salt = bytes32("same");
        uint256 g0 = gasleft();
        address a = deploy(salt, 1);
        emit log_named_uint("fresh create2", g0 - gasleft());
        assertTrue(a != address(0));

        // same salt, same code → same target, now occupied
        uint256 g1 = gasleft();
        address b = deploy(salt, 2);
        emit log_named_uint("occupied create2 returned", b == address(0) ? 1 : 0);
        emit log_named_uint("occupied create2 gas", g1 - gasleft());
    }
}
