// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SineMath} from "../src/libraries/SineMath.sol";
import {SineVectors} from "./SineVectors.sol";

/// @title SineOracleTest
/// @notice Independent Decimal/Simpson price and integral vectors plus inverse properties.
contract SineOracleTest is Test {
    function curve(uint256 boot, uint24 amp) internal pure returns (SineMath.Curve memory) {
        return SineMath.materialize(SineMath.Params(1e13, 4_605_170_185_988_092, 0.06e18, 10_000e18, amp), boot);
    }

    function test_IndependentDecimalVectors() public pure {
        uint256[5][] memory rows = SineVectors.rows();
        for (uint256 i; i < rows.length; ++i) {
            uint256[5] memory v = rows[i];
            SineMath.Curve memory c = curve(v[0], uint24(v[1]));
            assertApproxEqRel(SineMath.priceAt(c, v[2]), v[3], 1e7, "independent price");
            assertApproxEqRel(SineMath.supplyAt(c, v[2]), v[4], 1e9, "independent integral");
        }
    }

    function testFuzz_RoundtripNoProfit(uint96 rawBoot, uint96 rawReserve, uint64 rawBuy, uint16 rawAmp) public pure {
        uint256 boot = bound(rawBoot, 0.005e18, 450e18);
        uint256 reserve = bound(rawReserve, boot, 30_000e18);
        uint256 spend = bound(rawBuy, 0.005e18, 10e18);
        SineMath.Curve memory c = curve(boot, uint24(bound(rawAmp, 0, 10000)));
        uint256 out = SineMath.buyOut(c, reserve, spend);
        if (out == 0) return;
        uint256 back = SineMath.sellOut(c, reserve + spend, out);
        assertLe(back, spend, "curve roundtrip extracts reserve");
    }

    function testFuzz_InverseUpperBracket(uint96 rawReserve, uint16 rawAmp) public pure {
        SineMath.Curve memory c = curve(90e18, uint24(bound(rawAmp, 0, 10000)));
        uint256 reserve = bound(rawReserve, 100e18, 30_000e18);
        uint256 target = SineMath.supplyAt(c, reserve) * 999 / 1000;
        if (target <= c.q0) return;
        uint256 result = SineMath.reserveAt(c, target);
        assertGe(SineMath.supplyAt(c, result), target, "inverse must not overpay sells");
        assertLe(result, reserve, "positive sell cannot increase reserve");
    }

    function testFuzz_WaveSeamMonotone(uint8 rawWave, uint16 rawAmp) public pure {
        SineMath.Curve memory c = curve(90e18, uint24(bound(rawAmp, 0, 10000)));
        uint256 seam = c.boot + bound(rawWave, 1, 8) * c.lam;
        assertLe(SineMath.supplyAt(c, seam - 1), SineMath.supplyAt(c, seam), "left seam");
        assertLe(SineMath.supplyAt(c, seam), SineMath.supplyAt(c, seam + 1), "right seam");
    }
    function testFuzz_CellSeamMonotone(uint8 rawCell, uint16 rawAmp) public pure {
        SineMath.Curve memory c = curve(90e18, uint24(bound(rawAmp, 0, 10000)));
        uint256 seam = c.boot + c.lam * bound(rawCell, 1, 3) / 4;
        assertLe(SineMath.supplyAt(c, seam - 1), SineMath.supplyAt(c, seam), "left cell seam");
        assertLe(SineMath.supplyAt(c, seam), SineMath.supplyAt(c, seam + 1), "right cell seam");
    }

    function test_ShallowTrendBeyond256Waves() public pure {
        SineMath.Params memory p = SineMath.Params(1e13, 1e12, 1005e10, 10_000e18, 10000);
        SineMath.validate(p);
        SineMath.Curve memory c = SineMath.materialize(p, 450e18);
        uint256 left = SineMath.supplyAt(c, c.boot + 256 * c.lam);
        uint256 right = SineMath.supplyAt(c, c.boot + 300 * c.lam);
        assertGt(right, left, "shallow curve remains usable beyond 256 waves");
    }

}
