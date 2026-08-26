// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {AuditCurveMathTest} from "./AuditCurveMath.t.sol";

/// @title ProbeM2 — decode the A1/A4 panic 0x11 counterexamples
/// @notice Inherits AuditCurveMathTest so _randomValidConfig is THE battery's
///         exact generator — zero drift possible. The seeds below are the
///         shrinker-minimized counterexamples from the 20k-run deep fuzz
///         (fresh panics, not cache replays).
contract ProbeM2Test is AuditCurveMathTest {
    using CurveMath for CurveMath.CurveConfig;

    function _dump(CurveMath.CurveConfig memory cc) internal pure {
        console2.log("P0", cc.P0);
        console2.log("zones", cc.zones.length);
        for (uint256 i = 0; i < cc.zones.length; i++) {
            console2.log(unicode"── zone", i);
            console2.log("  start", cc.zones[i].startSupply);
            console2.log("  end  ", cc.zones[i].endSupply);
            console2.log("  rate ", cc.zones[i].rate);
            console2.log("  isExp", cc.zones[i].isExponential);
        }
    }

    /// A1 fresh counterexample:
    ///   seed=7182847911341963963393729480982643815343320577776407492635692
    ///   supply=123538459370918342220071427974702775969086 input=15164005329216582438894658555379705001442835611708010586839331420347696280
    function test_M2_A1_Repro() public {
        uint256 seed = 7182847911341963963393729480982643815343320577776407492635692;
        uint256 supply = 123_538_459_370_918_342_220_071_427_974_702_775_969_086;
        uint256 input = 151_640_053_292_165_824_388_946_585_553_797_050_014_428_356_117_080_105_868_393_314_203_476_962_80;

        CurveMath.CurveConfig memory cc = _randomValidConfig(seed);
        _dump(cc);
        supply = bound(supply, 0, 1e28);
        input = bound(input, 1e12, 100_000e18);
        console2.log("supply", supply);
        console2.log("input ", input);

        console2.log("marginal price at supply:");
        uint256 p = CurveMath.marginalPrice(supply, cc);
        console2.log("  price", p);

        console2.log("computeBuyOutput:");
        uint256 out = CurveMath.computeBuyOutput(input, supply, cc);
        console2.log("  out", out);

        uint256 spent = CurveMath.curveIntegral(supply, supply + out, cc);
        console2.log("  spent", spent);
        assertLe(spent, input, "A1: over-mint");
    }

    /// A4 fresh counterexample: seed=135305999368893231588 (boundary walk)
    function test_M2_A4_Repro() public {
        uint256 seed = 135_305_999_368_893_231_588;
        CurveMath.CurveConfig memory cc = _randomValidConfig(seed);
        _dump(cc);
        for (uint256 i = 0; i < cc.zones.length; i++) {
            uint256 b = cc.zones[i].endSupply;
            if (b == type(uint256).max) break;
            console2.log("boundary", b);
            console2.log("  below:", CurveMath.marginalPrice(b - 1, cc));
            console2.log("  at:  ", CurveMath.marginalPrice(b, cc));
            console2.log("  after:", CurveMath.marginalPrice(b + 1, cc));
        }
    }
}
