// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SineV3Math} from "../src/SineV3Math.sol";
import {SineV3SellFixtures} from "./SineV3SellFixtures.sol";
import {SineV3TestData as SineV3Data} from "./helpers/SineV3TestData.sol";

/// @title SineV3ReviewRegressionTest
/// @notice Preserve counterexamples to the required monotonic price and supply.
/// These assertions preserve the numerical failures found in the first review.
contract SineV3ReviewRegressionTest is Test {
    SineV3Math private math;
    uint256 private constant LAUNCH_PRICE = 75_000_000_000_000;

    function setUp() public {
        math = new SineV3Math(SineV3Data.deploy());
    }

    /// @notice One more reserve wei must not reduce supply at the 500-mixETH calibration.
    /// @dev Current outputs are 17671194694734242672866666 and
    /// 17671194694734242660133333 PSP wei: a decrease of 12,733,333 wei.
    /// Both coordinates are inside the partial cell immediately below wave 4.75.
    function test_BaselineSupplyNeverDecreasesAtAdjacentReserveWei() public view {
        uint256 boot = 450e18;
        uint256 lam = math.lamAt(boot);
        uint256 reserve = 4_986_249_999_999_999_998_089;

        uint256 beforeSupply = math.supplyWad(reserve, boot, lam, LAUNCH_PRICE);
        uint256 afterSupply = math.supplyWad(reserve + 1, boot, lam, LAUNCH_PRICE);

        assertGe(afterSupply, beforeSupply, "v3 baseline supply decreases after one reserve wei");
    }

    /// @notice The same partial-cell defect also affects a supported larger launch.
    /// @dev Current outputs are 97770880328780142869233225775 and
    /// 97770880328780142869043408449 PSP wei: a decrease of 189,817,326 wei.
    function test_LargeLaunchSupplyNeverDecreasesAtAdjacentReserveWei() public view {
        uint256 boot = 100_000e18;
        uint256 lam = math.lamAt(boot);
        uint256 reserve = 167_622_422_419_556_140_040_432;

        uint256 beforeSupply = math.supplyWad(reserve, boot, lam, LAUNCH_PRICE);
        uint256 afterSupply = math.supplyWad(reserve + 1, boot, lam, LAUNCH_PRICE);

        assertGe(afterSupply, beforeSupply, "v3 large-launch supply decreases after one reserve wei");
    }

    /// @notice One more reserve wei must not reduce the marginal price after wave ten.
    /// @dev Current outputs are 613048911149785684 and 613048911149785681.
    /// This is the quarter-wave boundary at x = 16.5, within the supported domain.
    function test_BaselinePriceNeverDecreasesAtAdjacentReserveWei() public view {
        uint256 boot = 450e18;
        uint256 lam = math.lamAt(boot);
        uint256 reserve = 16_207_499_999_999_999_999_999;

        uint256 beforePrice = math.priceWad(reserve, boot, lam, LAUNCH_PRICE);
        uint256 afterPrice = math.priceWad(reserve + 1, boot, lam, LAUNCH_PRICE);

        assertGe(afterPrice, beforePrice, "v3 price decreases after one reserve wei");
    }

    /// @notice A small sale after wave 32 must not return an unresolved Newton bound.
    /// @dev The old loop paid 2,977,509,581 wei instead of 19,309,571,239,079 wei.
    function test_InverseClosesBracketForSmallSaleAtWave32() public view {
        _checkSmallSale(SineV3SellFixtures.rows()[1]);
    }

    /// @notice A small sale after wave 63 must receive the complete curve output.
    /// @dev The old loop paid 5,861,800,334 wei instead of 1,690,898,741,711,268 wei.
    function test_InverseClosesBracketForSmallSaleAtWave63() public view {
        _checkSmallSale(SineV3SellFixtures.rows()[2]);
    }

    /// @notice Arbitrary helper arguments must not return a stale inverse bound.
    /// @dev These arguments exceed the reserve width possible for a factory curve.
    function test_InverseFailsClosedForUnsupportedBracketWidth() public {
        uint256 boot = 1;
        uint256 lam = uint256(1) << 225;
        uint256 reserve = uint256(1) << 230;
        vm.expectRevert(SineV3Math.SineV3Domain.selector);
        math.sellOut(reserve, boot, lam, LAUNCH_PRICE, 1);
    }

    function _checkSmallSale(SineV3SellFixtures.Row memory row) private view {
        uint256 target = math.supplyWad(row.reserve, row.boot, row.lam, LAUNCH_PRICE) - row.sold;
        uint256 out = math.sellOut(row.reserve, row.boot, row.lam, LAUNCH_PRICE, row.sold);
        uint256 next = row.reserve - out;
        // Check the canonical primitive freshly at both reserve endpoints.
        // Together with monotonic Q, these comparisons prove minimality.
        assertGe(math.supplyWad(next, row.boot, row.lam, LAUNCH_PRICE), target);
        assertLt(math.supplyWad(next - 1, row.boot, row.lam, LAUNCH_PRICE), target);

        // The reference uses independent tanh-sinh integration. One rounded
        // PSP wei can move the reserve endpoint by up to its upper spot price.
        uint256 price = math.priceWad(row.reserve, row.boot, row.lam, LAUNCH_PRICE);
        uint256 onePSPWei = price / 1e18 + 2;
        assertApproxEqAbs(out, row.grossOut, row.grossOut / 1e9 + onePSPWei + 1);
    }
}
