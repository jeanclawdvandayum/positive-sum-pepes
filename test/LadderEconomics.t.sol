// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {RealV4Base} from "./RealV4Lifecycle.t.sol";
import {console} from "forge-std/Test.sol";

/// @title LadderEconomicsTest
/// @notice Economic behavior deliberately allowed by the approved ticket rules.
contract LadderEconomicsTest is RealV4Base {
    function test_RoundTripCanWinExistingPotWithoutHoldingPSP() public {
        mixETH.transfer(alice, 1e18);
        uint256 existingPot = hook.potBalance();
        uint256 receivedBefore = controller.staker().totalFeesReceived();
        vm.startPrank(alice);
        mixETH.approve(address(zapIn), type(uint256).max);
        pspToken.approve(address(zapOut), type(uint256).max);
        uint256 bought = zapIn.buyWithMix(poolKey, 0.05e18, 1, block.timestamp);
        uint256 returned = zapOut.sellToMix(poolKey, bought, 1, block.timestamp);
        vm.stopPrank();
        assertLt(returned, 0.05e18, "round trip itself pays fees");
        assertEq(hook.seatedCount(), 10);
        assertEq(pspToken.balanceOf(alice), 0, "selling does not remove tickets");
        skip(hook.detonationAt() - block.timestamp);
        controller.detonate{gas: 1_000_000}();
        uint256 winnings = hook.claimablePot(alice);
        vm.prank(alice); hook.claimPot();
        uint256 profit = mixETH.balanceOf(alice) - 1e18;
        assertGt(profit, 0, "existing pot subsidizes the last buyer if unchallenged");
        assertGt(controller.staker().totalFeesReceived(), receivedBefore);
        console.log("existing pot (wei mixETH)", existingPot);
        console.log("round-trip irreversible cost (wei mixETH)", 0.05e18 - returned);
        console.log("pot won (wei mixETH)", winnings);
        console.log("net wallet profit excluding gas (wei mixETH)", profit);
    }

    function test_MajorityStakerRecapturesFeesAcrossBuySellBuy() public {
        vm.prank(bob); controller.claimPredepositPSP();
        mixETH.transfer(bob, 1e18);
        uint256 paidBefore = controller.staker().totalFeesPaid();
        uint256 receivedBefore = controller.staker().totalFeesReceived();
        uint256 potBefore = hook.potBalance();
        vm.startPrank(bob);
        mixETH.approve(address(zapIn), type(uint256).max);
        pspToken.approve(address(zapOut), type(uint256).max);
        uint256 bought = zapIn.buyWithMix(poolKey, 0.05e18, 1, block.timestamp);
        uint256 returned = zapOut.sellToMix(poolKey, bought, 1, block.timestamp);
        zapIn.buyWithMix(poolKey, 0.05e18, 1, block.timestamp);
        uint256 id = controller.staker().primaryOf(bob);
        uint256 fees = controller.staker().pendingFeesOf(id);
        controller.staker().claimFees(id);
        vm.stopPrank();
        assertEq(hook.ticketCount(), 99, "first buy earns fifty, the fee-grown ticket price earns forty-nine");
        assertGt(hook.potBalance(), potBefore);
        assertEq(controller.staker().totalFeesPaid() - paidBefore, fees);
        assertApproxEqAbs(fees, controller.staker().totalFeesReceived() - receivedBefore, 1);
        console.log("buy-sell cost before staker recapture (wei mixETH)", 0.05e18 - returned);
        console.log("staker fees recaptured over all three legs (wei mixETH)", fees);
        console.log("pot added over all three legs (wei mixETH)", hook.potBalance() - potBefore);
    }
}
