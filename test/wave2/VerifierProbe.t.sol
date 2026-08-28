// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BBase, BRouter} from "./auditorB/BBase.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {PSPStaker} from "../../../src/PSPStaker.sol";

/// @dev INDEPENDENT VERIFIER PROBES (throwaway — not part of the suite).
///      Hunting bypasses the committed suite does not cover.
contract VerifierProbe is BBase {
    uint256 constant EPOCH = 7 days;

    /// @dev ATTACK DEMO (accepted trade, post-window variant): a stake made
    ///      AFTER the vote window closed front-runs carpetBomb() and flips a
    ///      passing proposal to QuorumNotReached. Quorum would pass at window
    ///      close (100% yes), then carol's late stake breaks it at execution.
    function test_probe_LateStakeFrontRunsExecution() public {
        _launch(500e18);
        uint256 aliceW = stakerV.voteWeight(alice, block.timestamp);

        vm.prank(alice);
        controller.proposeCarpetBomb();
        _voteAll(alice, true); // alice = 100% of denominator → quorum + majority

        (, uint256 proposeTime,,,) = controller.currentProposal();
        skip(3 days + 1); // window closed — nobody can vote anymore

        // carol stakes just before anyone executes (≈1000 mixETH worth of PSP
        // — far more than the ~45% of alice's weight the flip needs)
        uint256 carolBag = _carolBuysAndLocks(1_000e18);
        assertGt(stakerV.pepeVoteWeight(stakerV.tokenOfOwnerByIndex(carol, 0), block.timestamp), 0, "her stake WOULD be votable (accepted trade)");

        // quorum now: aliceW vs (aliceW + carolBag) at 69% → fails
        vm.expectRevert(RoundController.QuorumNotReached.selector);
        controller.carpetBomb();
    }

    /// @dev Bypass probe: fully withdrawn position ("husk" NFT) — ownerOf
    ///      still resolves (NFT survives), but the position is deleted.
    ///      Must NOT be able to vote or propose with it.
    function test_probe_HuskNftCannotVote() public {
        _launch(500e18);
        uint256 pspOut = _bobBuysAndLocks(6_000e18);
        uint256 pepe = stakerV.tokenOfOwnerByIndex(bob, 0);

        vm.prank(alice);
        controller.proposeCarpetBomb(); // proposal must exist first

        vm.startPrank(bob);
        stakerV.requestWithdraw(pepe);
        skip(6 * EPOCH); // vest fully out
        stakerV.withdraw(pepe); // position deleted, NFT husk stays
        assertEq(psp.balanceOf(bob), pspOut, "principal returned");

        uint256[] memory ids = new uint256[](1);
        ids[0] = pepe;
        vm.expectRevert(RoundController.NotLocker.selector);
        controller.voteCarpetBomb(ids, true);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(RoundController.NotLocker.selector);
        controller.voteCarpetBomb(ids, true); // still nothing while the proposal lives

        vm.prank(bob);
        vm.expectRevert(RoundController.NotLocker.selector);
        controller.proposeCarpetBomb(); // husk cannot propose either
    }

    /// @dev Duplicate ids in one batch must not double-count (whole tx reverts).
    function test_probe_DuplicateIdsRevert() public {
        _launch(500e18);
        _bobBuysAndLocks(6_000e18);
        uint256 pepe = stakerV.tokenOfOwnerByIndex(bob, 0);

        vm.prank(alice);
        controller.proposeCarpetBomb();

        uint256[] memory ids = new uint256[](2);
        ids[0] = pepe;
        ids[1] = pepe;
        vm.prank(bob);
        vm.expectRevert(RoundController.AlreadyVoted.selector);
        controller.voteCarpetBomb(ids, true);
        (,, uint256 yes,,) = controller.currentProposal();
        assertEq(yes, 0, "nothing counted on revert");
    }

    /// @dev Transfer of an ARMED pepe must not move vote power to the buyer.
    function test_probe_TransferArmedPepeNoVote() public {
        _launch(500e18);
        uint256 bagA = _bobBuysAndLocks(6_000e18);
        uint256 pepe = stakerV.tokenOfOwnerByIndex(bob, 0);
        uint256 denomBefore = stakerV.totalVotableWeight();

        vm.prank(bob);
        stakerV.requestWithdraw(pepe);
        assertEq(stakerV.totalVotableWeight(), denomBefore - bagA, "excluded on arm");

        vm.prank(bob);
        stakerV.transferFrom(bob, carol, pepe); // NFT + decay clock move together

        assertEq(stakerV.ownerOf(pepe), carol, "carol owns it now");
        assertEq(stakerV.totalVotableWeight(), denomBefore - bagA, "transfer moved no weight");
        assertEq(stakerV.pepeVoteWeight(pepe, block.timestamp), 0, "still unarmed-excluded");

        vm.prank(alice);
        controller.proposeCarpetBomb();
        uint256[] memory ids = new uint256[](1);
        ids[0] = pepe;
        vm.prank(carol);
        vm.expectRevert(RoundController.NotLocker.selector);
        controller.voteCarpetBomb(ids, true); // new owner cannot vote an armed position
    }

    /// @dev Drift gauntlet: every mutation site keeps totalVotable == Σ
    ///      request-free principal (== totalWeight for /6-clean amounts).
    ///      Ends with a FLAT-PATH exit of a request-free position.
    function test_probe_TotalVotableGauntlet() public {
        _launch(500e18); // genesis locked + claimed → votable == weight
        assertEq(stakerV.totalVotableWeight(), stakerV.totalWeight(), "genesis netted");

        uint256 bagA = _bobBuysAndLocks(6_000e18); // divisible by 6
        assertEq(stakerV.totalVotableWeight(), stakerV.totalWeight(), "stake counted");
        uint256 pepeA = stakerV.tokenOfOwnerByIndex(bob, 0);

        // request → exclude
        vm.prank(bob);
        stakerV.requestWithdraw(pepeA);
        assertEq(stakerV.totalVotableWeight(), stakerV.totalWeight() - bagA, "armed excluded");

        // cancel → restore
        vm.prank(bob);
        stakerV.cancelWithdraw(pepeA);
        assertEq(stakerV.totalVotableWeight(), stakerV.totalWeight(), "cancel restored");

        // permissionless top-up onto the same pepe counts too
        uint256 bagB = _bobBuysAndLocks(1_200e18); // fresh pepe
        assertEq(stakerV.totalVotableWeight(), stakerV.totalWeight(), "second stake counted");

        // stakeFor top-up onto pepeA (carol funds bob's position)
        vm.startPrank(carol);
        mixETH.approve(address(router), 600e18);
        _routerBuy(600e18, carol);
        psp.approve(address(stakerV), type(uint256).max);
        stakerV.stakeFor(bob, pepeA, 600e18);
        vm.stopPrank();
        assertEq(stakerV.totalVotableWeight(), stakerV.totalWeight(), "stakeFor counted");

        // re-arm → wait the vest → withdraw (request path: no double-spend)
        vm.prank(bob);
        stakerV.requestWithdraw(pepeA);
        skip(6 * EPOCH);
        vm.prank(bob);
        stakerV.withdraw(pepeA);
        assertEq(stakerV.totalVotableWeight(), stakerV.totalWeight(), "request-path withdraw netted");

        // bomb → flat → flat-path exit of the request-free pepe
        skip((((block.timestamp / EPOCH) + 1) * EPOCH + 1) - block.timestamp);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        _voteAll(alice, true);
        _voteAll(bob, true);
        skip(3 days + 1);
        controller.carpetBomb(); // → Flat

        uint256 pepeB = stakerV.tokenOfOwnerByIndex(bob, 0);
        uint256 before = stakerV.totalVotableWeight();
        vm.prank(bob);
        stakerV.withdraw(pepeB); // flat path: request-free exit
        assertEq(stakerV.totalVotableWeight(), before - bagB, "flat exit excluded");
        assertGt(stakerV.totalVotableWeight(), 0, "no underflow (genesis remains)");
    }

    function _carolBuysAndLocks(uint256 mixIn) internal returns (uint256 pspOut) {
        vm.startPrank(carol);
        mixETH.approve(address(router), mixIn);
        BRouter.Call memory c = BRouter.Call({isBuy: true, amount: mixIn, settleMode: 0, takeMode: 0});
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = c;
        uint256[] memory outs = router.execute(key, calls, carol);
        pspOut = outs[0];
        psp.approve(address(stakerV), type(uint256).max);
        stakerV.lock(pspOut);
        vm.stopPrank();
    }
}
