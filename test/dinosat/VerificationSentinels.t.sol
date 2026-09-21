// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @title Negative controls for the symbolic verification runner
/// @notice These are intentional failures, not production properties.
contract VerificationSentinels is Test {
    function check_false_assertion(uint256 x) public pure {
        assert(x < x);
    }

    function check_empty_domain(uint256 x) public pure {
        vm.assume(x > 0);
        vm.assume(x == 0);
        assert(x == 1);
    }

    function test_false_assertion_reverts() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(1)));
        this.check_false_assertion(1);
    }
}
