// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SineV3Math} from "../src/SineV3Math.sol";
import {SineV3Primitive} from "../src/SineV3Primitive.sol";
import {SineV3TestData as SineV3Data} from "./helpers/SineV3TestData.sol";
import {SineV3DataInfo} from "../src/SineV3DataInfo.sol";
import {SineV3SellFixtures} from "./SineV3SellFixtures.sol";

contract SineV3PrimitiveHarness is SineV3Math {
    constructor(address[4] memory shards) SineV3Math(shards) {}

    function knot(uint256 i) external view returns (int256) {
        return _knot(i);
    }

    function phase4(uint256 i) external pure returns (int256) {
        return _phase4(i);
    }
}

/// @notice Check immutable data, local integer order, inverse plateaus, and gas.
contract SineV3PrimitiveTest is Test {
    SineV3PrimitiveHarness private math;
    address[4] private shards;

    function setUp() public {
        shards = SineV3Data.deploy();
        math = new SineV3PrimitiveHarness(shards);
    }

    function test_AllCanonicalAnchorsAndGridBoundaries() public view {
        assertEq(math.phase4(0), -2322);
        assertEq(math.phase4(SineV3DataInfo.FIRST_HALF_INDEX), -512);
        assertEq(math.phase4(SineV3DataInfo.FIRST_QUARTER_INDEX), -4);
        assertEq(math.phase4(SineV3DataInfo.ZERO_INDEX), 0);
        assertEq(math.phase4(SineV3DataInfo.LAST_QUARTER_INDEX), 4);
        assertEq(math.phase4(SineV3DataInfo.LAST_HALF_INDEX), 512);
        assertEq(math.phase4(SineV3DataInfo.COUNT - 1), 16384);
        int256 before = math.knot(0);
        for (uint256 i = 1; i < SineV3DataInfo.COUNT; ++i) {
            int256 next = math.knot(i);
            assertGe(next, before);
            before = next;
        }
        assertEq(math.knot(SineV3DataInfo.ZERO_INDEX), 0);
        assertEq(math.dataShardCount(), 4);
        for (uint256 i; i < 4; ++i) {
            assertEq(math.dataShard(i), shards[i]);
        }
    }

    function test_RejectsDataInWrongOrder() public {
        address temp = shards[0];
        shards[0] = shards[1];
        shards[1] = temp;
        vm.expectRevert(SineV3Primitive.SineV3DataMismatch.selector);
        new SineV3Math(shards);
    }

    function test_LowPriceSellUsesTheFullIntegral() public view {
        SineV3SellFixtures.Row memory row = SineV3SellFixtures.rows()[0];
        uint256 out = math.sellOut(row.reserve, row.boot, row.lam, 75e12, row.sold);
        assertEq(math.priceWad(row.reserve, row.boot, row.lam, 75e12), 1);
        assertApproxEqAbs(out, row.grossOut, row.grossOut / 1e9 + 2);
        // The old floor-price cap paid 1e17 despite an analytic price near1.95.
        assertGt(out, 19e16);
        _assertMinimalEndpoint(row.reserve, row.boot, row.lam, 75e12, row.sold, out);
    }

    function test_TailPlateauInverseFindsFirstRoundedSupplyEndpoint() public {
        uint256 boot = 450e18;
        uint256 lam = math.lamAt(boot);
        uint256 reserve = boot + 4096 * lam;
        uint256 gasBefore = gasleft();
        uint256 out = math.sellOut(reserve, boot, lam, 75e12, 1);
        uint256 used = gasBefore - gasleft();
        assertGt(out, 0);
        _assertMinimalEndpoint(reserve, boot, lam, 75e12, 1, out);
        assertLt(used, 12_000_000, "tail inverse exceeds gas budget");
        emit log_named_uint("tail one-PSP-wei inverse gas", used);
    }

    function test_LargeLaunchInverseGasAndMinimalEndpoint() public {
        uint256 boot = 680_000_000e18;
        uint256 lam = math.lamAt(boot);
        uint256 reserve = 1e24;
        uint256 sold = 1e37;
        uint256 gasBefore = gasleft();
        uint256 out = math.sellOut(reserve, boot, lam, 1e18, sold);
        uint256 used = gasBefore - gasleft();
        assertGt(out, 0);
        _assertMinimalEndpoint(reserve, boot, lam, 1e18, sold, out);
        assertLt(used, 12_000_000, "large-launch inverse exceeds gas budget");
        emit log_named_uint("large-launch inverse gas", used);
    }

    function testFuzz_ExactAdjacentReserveOrder(uint256 bootSeed, uint256 reserveSeed) public view {
        uint256 boot = bound(bootSeed, 1, 680_000_000e18);
        uint256 lam = math.lamAt(boot);
        uint256 reserve = bound(reserveSeed, 0, boot + 4096 * lam - 1);
        uint256 before = math.supplyWad(reserve, boot, lam, 1e18);
        uint256 afterSupply = math.supplyWad(reserve + 1, boot, lam, 1e18);
        assertGe(afterSupply, before);
    }

    function _assertMinimalEndpoint(
        uint256 reserve,
        uint256 boot,
        uint256 lam,
        uint256 price,
        uint256 sold,
        uint256 out
    ) private view {
        uint256 target = math.supplyWad(reserve, boot, lam, price) - sold;
        uint256 next = reserve - out;
        assertGe(math.supplyWad(next, boot, lam, price), target);
        if (next != 0) assertLt(math.supplyWad(next - 1, boot, lam, price), target);
    }
}
