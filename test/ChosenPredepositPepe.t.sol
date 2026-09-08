// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PredepositPrecisionTest} from "./PredepositPrecision.t.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {RoundController} from "../src/RoundController.sol";

/// @title ChosenPredepositPepeTest
/// @notice Selected art must preserve pooled principal, fees and retryable claims.
contract ChosenPredepositPepeTest is PredepositPrecisionTest {
    function _prepareChosenClaim() private {
        vm.startPrank(bob);
        mixETH.approve(address(controller), 10e18);
        controller.predeposit(10e18);
        vm.stopPrank();
        _launch(100e18);
    }

    function testFuzz_ChosenClaimMintsExactPreview(uint64 raw) public {
        uint256 id = bound(uint256(raw), 1e12, type(uint64).max);
        _prepareChosenClaim();
        vm.assume(stakerV.isPepeAvailable(id));
        uint256 total = stakerV.totalLocked();
        vm.prank(bob);
        controller.claimPredepositPSPWithPepe(id);
        assertEq(stakerV.ownerOf(id), bob);
        assertEq(stakerV.dnaOf(id), uint256(keccak256(abi.encode(id))));
        assertEq(stakerV.totalLocked(), total);
        assertFalse(stakerV.isPepeAvailable(id));
        vm.prank(bob);
        vm.expectRevert(RoundController.PredepositClosed.selector);
        controller.claimPredepositPSP();
    }

    function test_TakenSelectionLeavesClaimRetryable() public {
        _prepareChosenClaim();
        uint256 id = 1234567891234;
        vm.prank(alice);
        stakerV.lockWithPepe(0, id);
        uint256 total = stakerV.totalLocked();
        vm.prank(bob);
        vm.expectRevert(PSPStaker.BadPepeId.selector);
        controller.claimPredepositPSPWithPepe(id);
        (, bool claimed) = controller.predeposits(bob);
        assertFalse(claimed);
        assertEq(stakerV.totalLocked(), total);
        vm.prank(bob);
        controller.claimPredepositPSPWithPepe(id + 1);
        assertEq(stakerV.ownerOf(id + 1), bob);
    }

    function test_ZeroIdAndNonDepositorCannotClaim() public {
        _prepareChosenClaim();
        vm.prank(bob);
        vm.expectRevert(PSPStaker.BadPepeId.selector);
        controller.claimPredepositPSPWithPepe(0);
        vm.prank(address(123));
        vm.expectRevert(RoundController.ZeroAmount.selector);
        controller.claimPredepositPSPWithPepe(1234);
        vm.prank(bob);
        vm.expectRevert(PSPStaker.NotController.selector);
        stakerV.claimGenesisShareWithPepe(bob, 1e18, 1234);
    }
    function test_TraitAliasRevertsWithoutConsumingClaim() public {
        _prepareChosenClaim();
        vm.prank(alice);
        stakerV.lockWithPepe(0, 4046);
        vm.prank(bob);
        vm.expectRevert(PSPStaker.PepeDnaTaken.selector);
        controller.claimPredepositPSPWithPepe(5249);
        (, bool claimed) = controller.predeposits(bob);
        assertFalse(claimed);
        vm.prank(bob);
        controller.claimPredepositPSPWithPepe(6000);
        assertEq(stakerV.ownerOf(6000), bob);
    }

    function test_ChosenAndRandomClaimsPreserveSamePrincipalAndFees() public {
        _prepareChosenClaim();
        _buy(carol, 10e18);
        uint256 snapshot = vm.snapshotState();
        uint256 beforeMix = mixETH.balanceOf(bob);
        vm.prank(bob);
        controller.claimPredepositPSP();
        uint256 principal = stakerV.stakedTotalOf(bob);
        uint256 feesPaid = mixETH.balanceOf(bob) - beforeMix;
        uint256 weight = stakerV.totalWeight();
        assertGt(feesPaid, 0);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.prank(bob);
        controller.claimPredepositPSPWithPepe(7777777);
        assertEq(stakerV.stakedTotalOf(bob), principal);
        assertEq(mixETH.balanceOf(bob) - beforeMix, feesPaid);
        assertEq(stakerV.totalWeight(), weight);
    }

    function test_ChosenClaimStillWorksAfterDetonation() public {
        _prepareChosenClaim();
        _bomb();
        vm.prank(bob);
        controller.claimPredepositPSPWithPepe(7777777);
        assertEq(stakerV.ownerOf(7777777), bob);
        vm.prank(bob);
        stakerV.withdraw(7777777);
        assertGt(psp.balanceOf(bob), 0);
        assertFalse(stakerV.isPepeAvailable(7777777));
        assertFalse(stakerV.isPepeAvailable(0));
    }

    function test_ChosenMaxIdAndBothDoubleClaimRoutes() public {
        _prepareChosenClaim();
        vm.prank(bob);
        controller.claimPredepositPSPWithPepe(type(uint256).max);
        assertEq(stakerV.ownerOf(type(uint256).max), bob);
        assertEq(stakerV.dnaOf(type(uint256).max), uint256(keccak256(abi.encode(type(uint256).max))));
        vm.prank(bob);
        vm.expectRevert(RoundController.PredepositClosed.selector);
        controller.claimPredepositPSPWithPepe(1234);
        vm.prank(bob);
        vm.expectRevert(RoundController.PredepositClosed.selector);
        controller.claimPredepositPSP();
    }

    function test_ChosenClaimBeforeLaunchPreservesDeposit() public {
        vm.startPrank(bob);
        mixETH.approve(address(controller), 10e18);
        controller.predeposit(10e18);
        vm.expectRevert(RoundController.ZeroShare.selector);
        controller.claimPredepositPSPWithPepe(1234);
        vm.stopPrank();
        (uint256 amount, bool claimed) = controller.predeposits(bob);
        assertEq(amount, 10e18);
        assertFalse(claimed);
        _launch(100e18);
        vm.prank(bob);
        controller.claimPredepositPSPWithPepe(1234);
        assertEq(stakerV.ownerOf(1234), bob);
    }

    function test_ChosenClaimDefersFailedPayoutAndPaysExactlyOnceLater() public {
        _prepareChosenClaim();
        _buy(carol, 10e18);
        uint256 beforeMix = mixETH.balanceOf(bob);
        // Match the selector so any proportional payout to the chosen NFT fails.
        vm.mockCallRevert(address(hook), abi.encodeWithSignature("sendFees(address,uint256)"), "");
        vm.prank(bob);
        controller.claimPredepositPSPWithPepe(7777777);
        uint256 deferred = stakerV.pendingFeesOf(7777777);
        assertGt(deferred, 0);
        assertEq(mixETH.balanceOf(bob), beforeMix);
        assertEq(stakerV.ownerOf(7777777), bob);
        vm.clearMockedCalls();
        vm.prank(bob);
        stakerV.claimFees(7777777);
        assertEq(mixETH.balanceOf(bob) - beforeMix, deferred);
        assertEq(stakerV.pendingFeesOf(7777777), 0);
        vm.prank(bob);
        vm.expectRevert(PSPStaker.NothingToClaim.selector);
        stakerV.claimFees(7777777);
        assertEq(mixETH.balanceOf(bob) - beforeMix, deferred);
    }

    function test_TraitFailureRollsBackEveryWrittenAccountingSlot() public {
        _prepareChosenClaim();
        _buy(carol, 10e18);
        vm.prank(alice);
        stakerV.lockWithPepe(0, 4046);
        uint256 snapshot = vm.snapshotState();
        vm.record();
        vm.prank(bob);
        vm.expectRevert(PSPStaker.PepeDnaTaken.selector);
        controller.claimPredepositPSPWithPepe(5249);
        (, bytes32[] memory controllerSlots) = vm.accesses(address(controller));
        (, bytes32[] memory stakerSlots) = vm.accesses(address(stakerV));
        bytes32[] memory afterController = _slotValues(address(controller), controllerSlots);
        bytes32[] memory afterStaker = _slotValues(address(stakerV), stakerSlots);
        assertGt(controllerSlots.length, 0);
        assertGt(stakerSlots.length, 0);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        // Includes private fractional fee carry as well as principal and flags.
        assertEq(abi.encode(afterController), abi.encode(_slotValues(address(controller), controllerSlots)));
        assertEq(abi.encode(afterStaker), abi.encode(_slotValues(address(stakerV), stakerSlots)));
    }

    function _slotValues(address target, bytes32[] memory slots) private view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) values[i] = vm.load(target, slots[i]);
    }

}
