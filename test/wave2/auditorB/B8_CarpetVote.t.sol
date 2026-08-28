// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BBase, BRouter} from "./BBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Carpet-vote semantics — scoopy's Sepolia playtest findings,
///         fixed 2026-08-27:
///         (1) quorum is measured against STAKED PSP, not total supply
///         (2) stakes made AFTER a proposal can vote on it
///         (3) fresh stakes carry full voting power in their creation
///             epoch (only the fee engine epoch-gates) — immediate propose
///         (4) an armed withdraw request still decays the vote exactly
///             like the fee engine (5/6, 4/6, … 0)
contract B8_CarpetVote is BBase {
    /// @dev bob buys on the curve but does NOT lock — creates unstaked PSP
    ///      supply so totalSupply > staked weight.
    function _bobBuysUnlocked(uint256 amount) internal returns (uint256 pspOut) {
        vm.startPrank(bob);
        mixETH.approve(address(router), amount);
        BRouter.Call memory c = BRouter.Call({isBuy: true, amount: amount, settleMode: 0, takeMode: 0});
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = c;
        uint256[] memory outs = router.execute(key, calls, bob);
        pspOut = outs[0];
        vm.stopPrank();
    }

    /// @dev (1) Quorum denominator = staked weight. With a large UNSTAKED
    ///      supply floating (supply >> staked), a full-staked-weights yes
    ///      vote must still reach quorum — the old max(weight, supply)
    ///      floor made this exact scenario unreachable (frozen governance).
    function test_QuorumIsStakedNotTotalSupply() public {
        _launch(500e18); // alice: predeposit → genesis claim → epoch warp

        // bob mints a big unstaked bag on the curve: supply > staked
        uint256 bobBag = _bobBuysUnlocked(50_000e18);
        uint256 supply = psp.totalSupply();
        uint256 staked = stakerV.totalWeight();
        assertGt(supply, staked, "precondition: unstaked supply exists");

        vm.prank(alice);
        controller.proposeCarpetBomb();

        // denominator snapshot is the STAKED weight, not supply
        (,,,, uint256 locked,) = controller.currentProposal();
        assertEq(locked, staked, "quorum denominator = staked weight");

        // alice alone is 100% of staked weight → quorum + majority
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        (, uint256 proposeTime,,,,) = controller.currentProposal();
        vm.warp(proposeTime + 3 days + 1);
        controller.carpetBomb(); // would revert QuorumNotReached under supply floor
    }

    /// @dev (2)+(3) Stake AFTER the proposal — same epoch, no boundary wait —
    ///      votes at full power. Old code: NotLocker (weight read at
    ///      proposeTime, zero for post-propose and same-epoch locks).
    function test_PostProposeSameEpochStakeVotes() public {
        _launch(500e18);
        vm.prank(alice);
        controller.proposeCarpetBomb();

        uint256 pspOut = _bobBuysAndLocks(1_000e18); // AFTER propose, same epoch
        assertGt(pspOut, 0, "precondition: bob bought");

        vm.prank(bob);
        controller.voteCarpetBomb(true);

        (,, uint256 yesVotes,,,) = controller.currentProposal();
        assertEq(yesVotes, pspOut, "post-propose same-epoch stake voted at full power");
    }

    /// @dev (3) A fresh stake can propose immediately — no epoch-boundary
    ///      wait for governance. Old code: NotLocker in propose.
    function test_FreshStakeProposesSameEpoch() public {
        _launch(500e18);
        _bobBuysAndLocks(1_000e18);
        vm.prank(bob);
        controller.proposeCarpetBomb(); // no warp — must not revert
        (address proposer,,,,,) = controller.currentProposal();
        assertEq(proposer, bob, "fresh stake proposed in its creation epoch");
    }

    /// @dev (4) Vote weight decays step-for-step with the fee engine once a
    ///      withdraw request is armed: full through the request epoch, then
    ///      5/6, 3/6, 0 after the 1st, 3rd, 6th boundaries.
    function test_VoteWeightDecaysWithRequest() public {
        _launch(500e18);
        uint256 pspOut = _bobBuysAndLocks(6_000e18);
        uint256 pepeId = stakerV.tokenOfOwnerByIndex(bob, 0);

        // full power before any request
        assertEq(stakerV.voteWeight(bob, block.timestamp), pspOut, "full power while locked");

        vm.prank(bob);
        stakerV.requestWithdraw(pepeId);

        // full through the request epoch (dust-free amount: 6000 % 6 == 0)
        uint256 full = pspOut - (pspOut % 6);
        assertEq(stakerV.voteWeight(bob, block.timestamp), full, "full through request epoch");

        // absolute t0-anchored warps — via-ir CSE merges repeated
        // `block.timestamp / 7 days` subexpressions otherwise (lesson: the
        // second relative warp silently evaluates against the pre-warp ts)
        uint256 t0 = block.timestamp;
        uint256 E = 7 days;

        // +1 epoch → 5/6
        vm.warp(((t0 / E) + 1) * E + 1);
        assertEq(stakerV.voteWeight(bob, block.timestamp), full - full / 6, "5/6 after one epoch");

        // +3 epochs total → 3/6
        vm.warp(((t0 / E) + 3) * E + 1);
        assertEq(stakerV.voteWeight(bob, block.timestamp), full - 3 * (full / 6), "3/6 after three epochs");

        // +6 epochs total → 0
        vm.warp(((t0 / E) + 6) * E + 1);
        assertEq(stakerV.voteWeight(bob, block.timestamp), 0, "zero after six epochs");
    }
}
