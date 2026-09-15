// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SineV3Math} from "../src/SineV3Math.sol";
import {SineV3TestData as SineV3Data} from "./helpers/SineV3TestData.sol";

/// @title SineV3DataSecurityTest
/// @notice Only the generated immutable data may control settlement.
contract SineV3DataSecurityTest is Test {
    address[4] private shards;

    function setUp() public {
        shards = SineV3Data.deploy();
    }

    function test_AllDataIsPinnedAndHasInertRuntime() public {
        SineV3Math math = new SineV3Math(shards);
        assertEq(math.dataShardCount(), 4);
        for (uint256 i; i < 4; ++i) {
            assertEq(math.dataShard(i), shards[i]);
            bytes memory code = shards[i].code;
            assertEq(uint8(code[0]), 0, "data must start with STOP");
            assertLe(code.length, 24_576);
            bytes32 beforeHash = shards[i].codehash;
            (bool success, bytes memory result) = shards[i].call(abi.encodeWithSignature("destroy()"));
            assertTrue(success);
            assertEq(result.length, 0);
            assertEq(shards[i].codehash, beforeHash);
        }
        uint256 supply = math.genesisQ(450e18, 955e18, 75e12);
        (bool changed,) = address(math).call(abi.encodeWithSignature("setDataShard(uint256,address)", 0, address(this)));
        assertFalse(changed, "settlement data must have no setter");
        assertEq(math.genesisQ(450e18, 955e18, 75e12), supply);
    }

    function test_MissingReorderedAndDuplicatedDataCannotDeploy() public {
        address[4] memory changed = shards;
        changed[0] = address(0);
        vm.expectRevert();
        new SineV3Math(changed);
        changed = shards;
        (changed[0], changed[1]) = (changed[1], changed[0]);
        vm.expectRevert();
        new SineV3Math(changed);
        changed = shards;
        changed[3] = changed[2];
        vm.expectRevert();
        new SineV3Math(changed);
    }

    function test_OneAlteredDataByteCannotDeploy() public {
        bytes memory damaged = shards[0].code;
        damaged[damaged.length - 1] = bytes1(uint8(damaged[damaged.length - 1]) ^ 1);
        vm.etch(shards[0], damaged);
        vm.expectRevert();
        new SineV3Math(shards);
    }
}
