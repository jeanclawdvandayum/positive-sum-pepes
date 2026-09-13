// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BBase} from "./wave2/auditorB/BBase.sol";
import {SineMath} from "../src/libraries/SineMath.sol";

/// @title PredepositPrecisionTest
/// @notice Tiny individual deposits join a pooled launch and claim against the production sine
/// curve and real V4 manager; the active-buy minimum stays independent.
contract PredepositPrecisionTest is BBase {
    function setUp() public override {
        super.setUp();
        vm.prank(address(factory));
        hook.configureSine(SineMath.Params(1e13, 4_605_170_185_988_092, 0.06e18, 10_000e18, 10000));
    }

    function testOneWeiDepositJoinsAndClaimsPooledLaunch() public {
        _tinyDepositorLaunch(1);
        assertEq(hook.MIN_BUY_INPUT(), 0.005e18);
    }

    function testFuzzSubMinimumDepositJoinsAndClaimsPooledLaunch(uint64 raw) public {
        _tinyDepositorLaunch(bound(raw, 1, 0.005e18 - 1));
    }

    function _tinyDepositorLaunch(uint256 amount) internal {
        vm.startPrank(bob);
        mixETH.approve(address(controller), amount);
        controller.predeposit(amount);
        vm.stopPrank();
        _launch(100e18);
        uint256 preview = stakerV.genesisPepeDna(bob);
        vm.prank(bob);
        controller.claimPredepositPSP();
        assertEq(controller.totalPredepositMixETH(), 100e18 + amount);
        assertEq(mixETH.balanceOf(address(hook)), 100e18 + amount);
        assertGt(psp.totalSupply(), 0);
        assertEq(stakerV.balanceOf(bob), 1);
        assertEq(stakerV.primaryOf(bob), uint256(uint160(bob)));
        assertEq(stakerV.dnaOf(stakerV.primaryOf(bob)), preview);
    }

    function testOneWeiWholePoolCanLaunchAndClaim() public {
        vm.startPrank(alice);
        mixETH.approve(address(controller), 1);
        controller.predeposit(1);
        vm.stopPrank();
        skip(controller.PREDEPOSIT_DURATION());
        controller.launchPooledBuy();
        vm.prank(alice);
        controller.claimPredepositPSP();
        assertTrue(controller.predepositClosed());
        assertEq(stakerV.balanceOf(alice), 1);
        assertGt(psp.totalSupply(), 0);
        assertEq(hook.reserveMixETH(), 1);
    }
}
