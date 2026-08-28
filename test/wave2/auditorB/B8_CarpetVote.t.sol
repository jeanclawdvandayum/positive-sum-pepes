// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BBase, BRouter} from "./BBase.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Carpet-vote semantics — scoopy's Sepolia playtest findings,
///         2026-08-27 wave (still true) + the 2026-08-29 wave:
///         (1) quorum is measured against VOTABLE locked PSP — total locked
///             NOT awaiting a withdraw cooldown, evaluated LIVE (snapshot
///             retired)
///         (2) stakes made AFTER a proposal can vote on it
///         (3) fresh stakes carry full voting power in their creation
///             epoch (only the fee engine epoch-gates) — immediate propose
///         (4) an armed withdraw request HARD-EXCLUDES the position from
///             voting (the old 5/6, 4/6 … decay vote is dead) — canceling
///             the request restores full power instantly
///         (5) votes are cast BY PEPES (per-NFT), with per-pepe dedup
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

    /// @dev (1) Quorum denominator = LIVE votable weight. With a large
    ///      UNSTAKED supply floating (supply >> staked), a full-staked-weights
    ///      yes vote must still reach quorum — the old max(weight, supply)
    ///      floor made this exact scenario unreachable (frozen governance).
    function test_QuorumIsVotableNotTotalSupply() public {
        _launch(500e18); // alice: predeposit → genesis claim → epoch warp

        // bob mints a big unstaked bag on the curve: supply > staked
        uint256 bobBag = _bobBuysUnlocked(50_000e18);
        uint256 supply = psp.totalSupply();
        uint256 staked = stakerV.totalWeight();
        assertGt(supply, staked, "precondition: unstaked supply exists");
        assertEq(stakerV.totalVotableWeight(), staked, "votable == total while nobody is unstaking");

        vm.prank(alice);
        controller.proposeCarpetBomb();

        // alice alone is 100% of votable weight → quorum + majority
        _voteAll(alice, true);
        (, uint256 proposeTime,,,) = controller.currentProposal();
        vm.warp(proposeTime + 3 days + 1);
        controller.carpetBomb(); // would revert QuorumNotReached under supply floor
    }

    /// @dev (1b) LIVE denominator: arming a withdraw mid-vote SHRINKS the
    ///      quorum bar (the unstaking PSP leaves the denominator) — and the
    ///      unstaking wallet can no longer vote it. Here the remaining
    ///      stakers alone must still clear quorum.
    function test_QuorumDenominatorTracksUnstaking() public {
        _launch(500e18); // alice = genesis staker
        _bobBuysAndLocks(2_000e18); // bob stakes more than alice's genesis

        vm.prank(bob);
        controller.proposeCarpetBomb();

        uint256 before = stakerV.totalVotableWeight();
        uint256 bobPepe = stakerV.tokenOfOwnerByIndex(bob, 0);

        // bob arms his withdraw MID-VOTE: he leaves the voter pool and the
        // denominator together
        vm.prank(bob);
        stakerV.requestWithdraw(bobPepe);
        assertLt(stakerV.totalVotableWeight(), before, "unstaking shrank the denominator");

        // bob's pepe can no longer vote (hard exclusion)
        uint256[] memory bobIds = new uint256[](1);
        bobIds[0] = bobPepe;
        vm.prank(bob);
        vm.expectRevert(RoundController.NotLocker.selector);
        controller.voteCarpetBomb(bobIds, true);

        // alice alone is now 100% of the votable denominator → executable
        _voteAll(alice, true);
        (, uint256 proposeTime,,,) = controller.currentProposal();
        vm.warp(proposeTime + 3 days + 1);
        controller.carpetBomb();
    }

    /// @dev (2)+(3) Stake AFTER the proposal — same epoch, no boundary wait —
    ///      votes at full power.
    function test_PostProposeSameEpochStakeVotes() public {
        _launch(500e18);
        vm.prank(alice);
        controller.proposeCarpetBomb();

        uint256 pspOut = _bobBuysAndLocks(1_000e18); // AFTER propose, same epoch
        assertGt(pspOut, 0, "precondition: bob bought");

        _voteAll(bob, true);

        (,, uint256 yesVotes,,) = controller.currentProposal();
        assertEq(yesVotes, pspOut, "post-propose same-epoch stake voted at full power");
    }

    /// @dev (3) A fresh stake can propose immediately — no epoch-boundary
    ///      wait for governance.
    function test_FreshStakeProposesSameEpoch() public {
        _launch(500e18);
        _bobBuysAndLocks(1_000e18);
        vm.prank(bob);
        controller.proposeCarpetBomb(); // no warp — must not revert
        (address proposer,,,,) = controller.currentProposal();
        assertEq(proposer, bob, "fresh stake proposed in its creation epoch");
    }

    /// @dev (4) HARD exclusion: an armed withdraw request zeroes the vote
    ///      weight immediately (no 5/6 → 4/6 slide), and canceling the
    ///      request restores FULL power instantly — scoopy 2026-08-29.
    function test_UnstakingCannotVote_CancelRestores() public {
        _launch(500e18);
        uint256 pspOut = _bobBuysAndLocks(6_000e18);
        uint256 pepeId = stakerV.tokenOfOwnerByIndex(bob, 0);

        // full power before any request
        assertEq(stakerV.voteWeight(bob, block.timestamp), pspOut, "full power while locked");
        assertEq(stakerV.pepeVoteWeight(pepeId, block.timestamp), pspOut, "per-pepe view agrees");

        vm.prank(bob);
        stakerV.requestWithdraw(pepeId);

        // ZERO immediately — the request epoch grace is gone for votes
        assertEq(stakerV.voteWeight(bob, block.timestamp), 0, "hard-excluded while unstaking");
        assertEq(stakerV.pepeVoteWeight(pepeId, block.timestamp), 0, "per-pepe view excluded too");
        assertEq(
            stakerV.totalVotableWeight(),
            stakerV.totalWeight() - pspOut,
            "denominator excluded the unstaking principal"
        );

        // cancel → full power restored INSTANTLY (same timestamp class)
        vm.prank(bob);
        stakerV.cancelWithdraw(pepeId);
        assertEq(stakerV.voteWeight(bob, block.timestamp), pspOut, "cancel restored full power");
        assertEq(stakerV.totalVotableWeight(), stakerV.totalWeight(), "denominator restored");
    }

    /// @dev (5) Per-pepe dedup: a pepe votes once per proposal; a wallet
    ///      with TWO pepes can split them across yes/no; voting someone
    ///      else's pepe reverts.
    function test_PerPepeVoting() public {
        _launch(500e18);
        uint256 bagA = _bobBuysAndLocks(1_000e18); // pepe 1
        uint256 bagB;
        {
            vm.startPrank(bob);
            psp.approve(address(stakerV), type(uint256).max);
            // bob buys more and locks into a SECOND pepe
            mixETH.approve(address(router), 500e18);
            BRouter.Call memory c = BRouter.Call({isBuy: true, amount: 500e18, settleMode: 0, takeMode: 0});
            BRouter.Call[] memory calls = new BRouter.Call[](1);
            calls[0] = c;
            uint256[] memory outs = router.execute(key, calls, bob);
            bagB = outs[0];
            stakerV.lock(bagB);
            vm.stopPrank();
        }
        uint256 p1 = stakerV.tokenOfOwnerByIndex(bob, 0);
        uint256 p2 = stakerV.tokenOfOwnerByIndex(bob, 1);
        assertEq(stakerV.balanceOf(bob), 2, "bob owns two pepes");

        vm.prank(alice);
        controller.proposeCarpetBomb();

        // split vote: pepe 1 yes, pepe 2 no — same wallet, same proposal
        uint256[] memory yesIds = new uint256[](1);
        yesIds[0] = p1;
        vm.prank(bob);
        controller.voteCarpetBomb(yesIds, true);
        uint256[] memory noIds = new uint256[](1);
        noIds[0] = p2;
        vm.prank(bob);
        controller.voteCarpetBomb(noIds, false);

        (,, uint256 yesVotes, uint256 noVotes,) = controller.currentProposal();
        assertEq(yesVotes, bagA, "pepe 1 voted yes at full weight");
        assertEq(noVotes, bagB, "pepe 2 voted no at full weight");

        // pepe 1 cannot vote AGAIN this proposal
        vm.prank(bob);
        vm.expectRevert(RoundController.AlreadyVoted.selector);
        controller.voteCarpetBomb(yesIds, true);

        // alice cannot vote WITH bob's pepe
        vm.prank(alice);
        vm.expectRevert(RoundController.NotPepeOwner.selector);
        controller.voteCarpetBomb(yesIds, true);
    }

    /// @dev Repro (scoopy 2026-08-27, Sepolia): buys work, sells revert
    ///      while a carpet-bomb vote is active. Sell before propose (sanity),
    ///      propose, vote, sell again during the live window.
    function test_SellDuringActiveVote() public {
        _launch(500e18);
        uint256 bag = _bobBuysUnlocked(2_000e18); // unstaked PSP — sellable
        assertGt(bag, 0, "precondition: bob holds PSP");

        BRouter.Call[] memory sell = new BRouter.Call[](1);
        sell[0] = BRouter.Call({isBuy: false, amount: bag / 4, settleMode: 0, takeMode: 0});

        // sanity: sell BEFORE any proposal works
        vm.startPrank(bob);
        psp.approve(address(router), bag / 4);
        router.execute(key, sell, bob);
        vm.stopPrank();

        // propose + yes vote from the genesis staker
        vm.prank(alice);
        controller.proposeCarpetBomb();
        _voteAll(alice, true);

        // sell DURING the live vote — reported broken on Sepolia
        vm.startPrank(bob);
        psp.approve(address(router), bag / 4);
        uint256[] memory outs = router.execute(key, sell, bob);
        vm.stopPrank();
        assertGt(outs[0], 0, "sell during active vote paid out");
    }

    /// @dev Hardened repro: same scenario but with real time passage (epochs
    ///      crossing under the engine) and interleaved staker actions around
    ///      the vote — matches the Sepolia playtest sequence shape.
    function test_SellDuringActiveVoteWithEpochPassage() public {
        _launch(500e18);
        uint256 bag = _bobBuysUnlocked(2_000e18);

        // carol stakes + arms a withdraw (engine deltas live)
        vm.startPrank(carol);
        mixETH.approve(address(router), 500e18);
        BRouter.Call[] memory buy = new BRouter.Call[](1);
        buy[0] = BRouter.Call({isBuy: true, amount: 500e18, settleMode: 0, takeMode: 0});
        uint256[] memory bought = router.execute(key, buy, carol);
        uint256 carolBag = bought[0];
        psp.approve(address(stakerV), type(uint256).max);
        stakerV.lock(carolBag);
        uint256 carolPepe = stakerV.tokenOfOwnerByIndex(carol, 0);
        stakerV.requestWithdraw(carolPepe);
        vm.stopPrank();

        // epochs pass first (decay steps apply, walk state accumulates) —
        // then propose: votes and the sell stay INSIDE the 3d window
        uint256 t0 = block.timestamp;
        vm.warp(((t0 / 7 days) + 2) * 7 days + 1);

        // propose + vote from the full-weight staker
        vm.prank(alice);
        controller.proposeCarpetBomb();
        _voteAll(alice, true);

        // carol is UNSTAKING — her pepe cannot vote anymore (2026-08-29:
        // hard exclusion; the old partial-decay vote is dead)
        uint256[] memory carolIds = new uint256[](1);
        carolIds[0] = carolPepe;
        vm.prank(carol);
        vm.expectRevert(RoundController.NotLocker.selector);
        controller.voteCarpetBomb(carolIds, false);

        // sell during the live vote, engine mid-walk
        vm.startPrank(bob);
        psp.approve(address(router), bag / 4);
        BRouter.Call[] memory sell = new BRouter.Call[](1);
        sell[0] = BRouter.Call({isBuy: false, amount: bag / 4, settleMode: 0, takeMode: 0});
        uint256[] memory outs = router.execute(key, sell, bob);
        vm.stopPrank();
        assertGt(outs[0], 0, "sell mid-vote with epoch passage paid out");
    }
}
