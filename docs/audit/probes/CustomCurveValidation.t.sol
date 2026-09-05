// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {SineMath} from "../../../src/libraries/SineMath.sol";
// Historical pre-fix reproduction. Current SineMath correctly rejects this
// configuration; the active regression is in test/SineMath.t.sol.
contract SineDomainProbe is Test {
    function probeSupply(SineMath.Curve memory c, uint256 r) external pure returns(uint256) {
        return SineMath.supplyAt(c, r);
    }
    function test_ValidationAcceptsZeroSlopeUntradeableCurve() public {
        SineMath.Params memory p = SineMath.Params(1e13, 4_605_170_185_988_092, 0.06e18, 1e40, 10000);
        SineMath.validate(p);
        SineMath.Curve memory c = SineMath.materialize(p, 90e18);
        assertEq(c.slope, 0);
        assertEq(c.g, 1e18);
        vm.expectRevert();
        this.probeSupply(c, c.boot + 0.005e18);
    }
}
