// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SineV3Math} from "../src/SineV3Math.sol";
import {SineV3TestData as SineV3Data} from "./helpers/SineV3TestData.sol";
import {SineV3SmallReserveFixtures} from "./SineV3SmallReserveFixtures.sol";

/// @title SineV3SmallReserveOracleTest
/// @notice Local supply must agree with an independent integral at large launches.
contract SineV3SmallReserveOracleTest is Test {
    SineV3Math private math;

    function setUp() public {
        math = new SineV3Math(SineV3Data.deploy());
    }

    function test_SmallReserveSupplyMatchesIndependentSimpsonOracle() public view {
        SineV3SmallReserveFixtures.Row[150] memory rows = SineV3SmallReserveFixtures.rows();
        for (uint256 i; i < rows.length; ++i) {
            SineV3SmallReserveFixtures.Row memory r = rows[i];
            assertEq(math.lamAt(r.boot), r.wavelength);
            uint256 actual = math.supplyWad(r.reserve, r.boot, r.wavelength, r.price);
            uint256 error = actual > r.expected ? actual - r.expected : r.expected - actual;
            assertLe(error, r.expected / 1e9 + 1,
                string.concat("small-reserve supply exceeds oracle error at row ", vm.toString(i)));
        }
    }
}
