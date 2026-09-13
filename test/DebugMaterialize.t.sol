// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {SineMath} from "../src/libraries/SineMath.sol";
import {FixedPointMathLib as FPML} from "solady/src/utils/FixedPointMathLib.sol";

contract MaterializeDirect is Test {
    function test_MaterializeDirect() public pure {
        SineMath.Params memory p = SineMath.Params(1e13, 4_605_170_185_988_092, 0.06e18, 10_000e18, 10_000);
        SineMath.Curve memory c = SineMath.materialize(p, 500e18);
        console.log("B", c.B);
        console.log("g", c.g);
        console.log("W", c.W);
        console.log("q0", c.q0);
        console.log("wave trend", c.waveTrend);
        console.log("lam", c.lam);
    }
}

contract TargetTreadProbe is Test {
    function test_Probe() public pure {
        SineMath.Params memory p = SineMath.Params(1e13, 4_605_170_185_988_092, 0.06e18, 10_000e18, 10_000);
        SineMath.Curve memory c = SineMath.materialize(p, 500e18);
        console.log("p(10,000 mix) wei:", SineMath.priceAt(c, 10_000e18));
        console.log("p(target wei):", SineMath.priceAt(c, c.targetReserve));
        console.log("p(seam):", SineMath.priceAt(c, c.boot));
        console.log("p(0):", SineMath.priceAt(c, 0));
    }
}
