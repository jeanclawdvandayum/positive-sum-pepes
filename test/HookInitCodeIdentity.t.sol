// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {HookInitCode} from "../src/HookInitCode.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";

/// @title HookInitCodeIdentityTest
/// @notice The immutable data shards reconstruct the exact CREATE2 program.
contract HookInitCodeIdentityTest is Test {
    function test_ShardedCreationCodeIsByteIdentical() public {
        HookInitCode oracle = new HookInitCode();
        CurveMath.CurveConfig memory config = CurveMath.singleCurve(1e13, 1_000_000e18, 1e12, 5e16);
        IPoolManager manager = IPoolManager(address(1));
        bytes memory expected = bytes.concat(type(CurveHook).creationCode, abi.encode(manager, address(2), address(3), config, address(4)));
        assertEq(oracle.hookInitCode(manager, address(2), address(3), config, address(4)), expected);
        assertEq(uint8(oracle.first().code[0]), 0, "first shard is STOP-prefixed");
        assertEq(uint8(oracle.second().code[0]), 0, "second shard is STOP-prefixed");
        assertLt(oracle.first().code.length, 24576);
        assertLt(oracle.second().code.length, 24576);
    }
}
