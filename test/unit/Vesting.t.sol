// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {PSPStaker} from "../../src/PSPStaker.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockHook} from "../mocks/MockHook.sol";
import {StakerDeployer} from "src/StakerDeployer.sol";

contract MockFactory {
    address public owner;
    constructor() { owner = msg.sender; }
}

/// @title VestingTest — InfiniFi epoch-point decay: pins, exact fee splits,
///         staggered decayers, gating, votes, dust, sparse replays.
/// @notice Epoch = VEST/6 = 7d. Weight changes go live at the NEXT epoch
///         boundary; a request at epoch E holds full weight through E and
///         steps down 5/6, 4/6, … 0 at each boundary after (k = e - E).
///         Fees are credited live via the creditPerWeight accumulator and
///         are claimable the moment they land (see FeeImmediacy.t.sol).
/// @dev All warps are ABSOLUTE from a captured t0 — two textually identical
///      `vm.warp(block.timestamp + X)` expressions in one function get CSE'd
///      by via-ir and the second re-evaluates with the stale timestamp.
contract VestingTest is Test {
    RoundController controller;
    PSPStaker stakerV;
    MockMixETH mixETH;
    PSPToken pspToken;
    MockHook hook;
    MockFactory mockFactory;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant VEST = 42 days;
    uint256 constant EPOCH = 7 days; // VEST / 6
    uint256 t0; // setUp ends exactly on the epoch-2 boundary

    /// @dev decay math mirror: (base, slope) for an amount
    function _dec(uint256 amount) internal pure returns (uint256 base, uint256 slope) {
        base = amount - (amount % 6);
        slope = base / 6;
    }

    /// @dev expected weight of an amount at k epochs past its request
    function _wAt(uint256 amount, uint256 k) internal pure returns (uint256) {
        if (k >= 6) return 0;
        (uint256 base, uint256 slope) = _dec(amount);
        return base - k * slope;
    }

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 1000e18}();
        mockFactory = new MockFactory();
        CurveMath.CurveConfig memory params =
            CurveMath.singleCurve(0.0001e18, 100_000_000e18, 0.000000046e18, 0.1e18);
        pspToken = new PSPToken("Positive Sum Pepes", "PSP", address(this));
        controller =
            new RoundController(pspToken, IERC20(address(mixETH)), params, address(mockFactory), address(0), new StakerDeployer());
        stakerV = controller.staker();
        pspToken.setController(address(controller));

        vm.startPrank(address(controller));
        pspToken.mint(alice, 10_000e18);
        pspToken.mint(bob, 10_000e18);
        vm.stopPrank();

        hook = new MockHook(address(mixETH));
        mixETH.transfer(address(hook), 500e18);
        vm.prank(address(mockFactory));
        controller.setHook(CurveHook(payable(address(hook))));

        // anchor exactly ON an epoch boundary (epoch 1), then stake — both
        // stakes share epoch 1 and go live at epoch 2 (= t0)
        vm.warp(((block.timestamp / EPOCH) + 1) * EPOCH);

        vm.startPrank(alice);
        pspToken.approve(address(stakerV), type(uint256).max);
        stakerV.lockWithPepe(1000e18, 101);
        vm.stopPrank();
        vm.startPrank(bob);
        pspToken.approve(address(stakerV), type(uint256).max);
        stakerV.lockWithPepe(1000e18, 202);
        vm.stopPrank();

        vm.warp(block.timestamp + EPOCH); // enter epoch 2: both live
        t0 = block.timestamp; // == 2 * EPOCH exactly
    }

    function _feedFees(uint256 amount) internal {
        vm.prank(address(controller));
        stakerV.addFees(amount);
    }

    // ── decay pins: the exact spec numbers, boundary-anchored ──

    function test_DecayPins() public {
        vm.prank(alice);
        stakerV.requestWithdraw(101); // requestEpoch = 2, full through it
        assertEq(stakerV.biasOf(101, block.timestamp), 1000e18, "full through request epoch");

        vm.warp(t0 + 1 * EPOCH); // +1 week → 5/6
        assertEq(stakerV.biasOf(101, block.timestamp), _wAt(1000e18, 1), "1wk = 5/6");

        vm.warp(t0 + 3 * EPOCH); // +3 weeks → 1/2
        assertEq(stakerV.biasOf(101, block.timestamp), _wAt(1000e18, 3), "3wk = 1/2");

        vm.warp(t0 + 6 * EPOCH); // +6 weeks → 0
        assertEq(stakerV.biasOf(101, block.timestamp), 0, "6wk = 0");
        assertEq(stakerV.totalWeight(), 1000e18, "bob remains at full");
    }

    // ── staggered decayers: the former known-issue, now exact ──

    function test_TotalWeightStaggeredExact() public {
        vm.prank(alice);
        stakerV.requestWithdraw(101); // epoch 2
        vm.warp(t0 + 1 * EPOCH); // epoch 3
        vm.prank(bob);
        stakerV.requestWithdraw(202); // epoch 3
        vm.warp(t0 + 2 * EPOCH); // epoch 4: alice k=2, bob k=1

        assertEq(stakerV.biasOf(101, block.timestamp), _wAt(1000e18, 2));
        assertEq(stakerV.biasOf(202, block.timestamp), _wAt(1000e18, 1));
        assertEq(stakerV.totalWeight(), _wAt(1000e18, 2) + _wAt(1000e18, 1), "aggregate exact");

        vm.warp(t0 + 6 * EPOCH); // epoch 8: alice exhausted (k=6), bob k=5
        assertEq(stakerV.totalWeight(), _wAt(1000e18, 5), "alice 0 + bob 5/6");
    }

    // ── exact fee splits: same-epoch vs decayer, floor-for-floor ──

    function test_FeeSplitExact() public {
        _feedFees(100e18); // during epoch 2: both live, 50/50
        assertEq(stakerV.pendingFeesOf(101), 50e18, "live immediately, no epoch wait");
        assertEq(stakerV.pendingFeesOf(202), 50e18);

        vm.warp(t0 + 1 * EPOCH); // epoch 3
        assertEq(stakerV.pendingFeesOf(101), 50e18);
        assertEq(stakerV.pendingFeesOf(202), 50e18);

        vm.prank(alice);
        stakerV.requestWithdraw(101); // r=3: settles + pays the 50e18
        assertEq(mixETH.balanceOf(alice), 50e18);

        vm.warp(t0 + 2 * EPOCH); // epoch 4: alice k=1
        uint256 wA = _wAt(1000e18, 1);
        uint256 total = wA + 1000e18;
        _feedFees(150e18); // during epoch 4

        vm.warp(t0 + 3 * EPOCH); // epoch 5: alice k=2 (blessed: claims scale
        // at the CURRENT weight, so epoch-4 fees settle at k=2, not k=1)
        uint256 wA2 = _wAt(1000e18, 2);
        uint256 expA = (150e18 * wA2) / total; // decayer share (approximation)
        uint256 expB = (150e18 * 1000e18) / total;
        assertEq(stakerV.pendingFeesOf(101), expA, "decayer share at current weight");
        // bob settled nothing since epoch 2 — his epoch-2 50e18 rides along
        assertEq(stakerV.pendingFeesOf(202), 50e18 + expB, "stayer share (+unclaimed ep2)");
        assertTrue(expA + expB <= 150e18, "never over-distributes");

        vm.prank(alice);
        stakerV.claimFees(101);
        assertEq(mixETH.balanceOf(alice), 50e18 + expA);
        vm.prank(bob);
        stakerV.claimFees(202);
        assertEq(mixETH.balanceOf(bob), 50e18 + expB);
    }

    // ── lifecycle gates ──

    function test_WithdrawGating() public {
        vm.prank(alice);
        stakerV.requestWithdraw(101); // r=2
        assertEq(stakerV.withdrawableAt(101), 8 * EPOCH);

        vm.prank(alice);
        vm.expectRevert(PSPStaker.VestNotComplete.selector);
        stakerV.withdraw(101);

        vm.warp(8 * EPOCH); // first instant it unlocks
        uint256 pspBefore = pspToken.balanceOf(alice);
        vm.prank(alice);
        stakerV.withdraw(101);
        assertEq(pspToken.balanceOf(alice) - pspBefore, 1000e18);
        (uint256 amt,,,,,) = stakerV.positions(101);
        assertEq(amt, 0);
        assertEq(stakerV.ownerOf(101), alice, "NFT kept as husk");

        // husk re-stakeable
        vm.prank(alice);
        stakerV.stakeFor(alice, 101, 5e18);
        (uint256 amt2,,,,,) = stakerV.positions(101);
        assertEq(amt2, 5e18);
    }

    function test_WithdrawWithoutRequestReverts() public {
        vm.prank(alice);
        vm.expectRevert(PSPStaker.NotDecaying.selector);
        stakerV.withdraw(101);
    }

    function test_CancelRestoresFullPower() public {
        vm.prank(alice);
        stakerV.requestWithdraw(101); // r=2
        vm.warp(t0 + 1 * EPOCH); // epoch 3: alice k=1
        assertEq(stakerV.biasOf(101, block.timestamp), _wAt(1000e18, 1));

        vm.prank(alice);
        stakerV.cancelWithdraw(101);
        // documented quirk: the cancel epoch itself is forfeit (re-anchored),
        // full power returns at the next boundary
        assertEq(stakerV.biasOf(101, block.timestamp), 0, "cancel epoch forfeit");

        vm.warp(t0 + 2 * EPOCH); // epoch 4
        assertEq(stakerV.biasOf(101, block.timestamp), 1000e18, "restored");
        assertEq(stakerV.totalWeight(), 2000e18, "aggregate restored");
    }

    function test_CancelSameEpoch() public {
        vm.prank(alice);
        stakerV.requestWithdraw(101);
        vm.prank(alice);
        stakerV.cancelWithdraw(101);
        vm.warp(t0 + 1 * EPOCH);
        assertEq(stakerV.biasOf(101, block.timestamp), 1000e18, "nothing ever decayed");
        assertEq(stakerV.totalWeight(), 2000e18);
    }

    function test_StakeForRevertsWhileDecaying() public {
        vm.prank(alice);
        stakerV.requestWithdraw(101);
        vm.prank(alice);
        vm.expectRevert(PSPStaker.RequestActive.selector);
        stakerV.stakeFor(alice, 101, 1e18);
    }

    // ── multi-position + multiclaim ──

    function test_MultiPepesAndClaimAll() public {
        vm.startPrank(alice);
        stakerV.lock(250e18); // second pepe, sequential id = 1, stakes at epoch 2
        vm.stopPrank();
        assertEq(stakerV.balanceOf(alice), 2);

        vm.warp(t0 + 1 * EPOCH); // epoch 3: all three live
        _feedFees(75e18); // weights 1000 + 1000 + 250

        vm.warp(t0 + 2 * EPOCH); // epoch 4: closed
        uint256 exp101 = (uint256(75e18) * 1000e18) / 2250e18;
        uint256 exp1 = (uint256(75e18) * 250e18) / 2250e18;
        assertEq(stakerV.pendingFeesOf(101), exp101);
        assertEq(stakerV.pendingFeesOf(1), exp1);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 101;
        ids[1] = 1;
        vm.prank(alice);
        stakerV.claimAllTo(ids, alice);
        assertEq(mixETH.balanceOf(alice), exp101 + exp1);
    }

    // ── vote weights: propose-time snapshot semantics ──

    function test_VoteWeightSnapshot() public {
        vm.prank(alice);
        stakerV.requestWithdraw(101); // r=2
        uint256 propose = t0 + 1; // still epoch 2 → full weight
        assertEq(stakerV.voteWeight(alice, propose), 1000e18);

        vm.warp(t0 + 3 * EPOCH); // epoch 5
        assertEq(stakerV.voteWeight(alice, propose), 1000e18, "snapshot frozen at propose");
        assertEq(stakerV.biasOf(101, block.timestamp), _wAt(1000e18, 3));

        // post-propose action excluded: bob tops up AFTER propose
        vm.warp(propose + 1);
        vm.prank(bob);
        stakerV.stakeFor(bob, 202, 1e18);
        assertEq(stakerV.voteWeight(bob, propose), 0);
    }

    // ── dust: amounts not divisible by 6 still hit exactly zero ──

    function test_DustRounding() public {
        vm.startPrank(alice);
        stakerV.lockWithPepe(1003e18, 303); // stakes at epoch 2
        vm.stopPrank();
        vm.warp(t0 + 1 * EPOCH); // epoch 3: live

        vm.prank(alice);
        stakerV.requestWithdraw(303); // r=3
        assertEq(stakerV.biasOf(303, block.timestamp), 1003e18, "full at request");

        vm.warp(t0 + 7 * EPOCH); // epoch 9: k=6
        assertEq(stakerV.biasOf(303, block.timestamp), 0, "dust-safe zero");
        assertEq(stakerV.totalWeight(), 2000e18, "global clean");
    }

    // ── sparse replay: fees across a quiet gap, single claim at the end ──

    function test_SparseReplayAcrossGap() public {
        _feedFees(60e18); // epoch 2
        vm.warp(t0 + 4 * EPOCH); // epoch 6 — three silent epochs
        _feedFees(120e18); // epoch 6
        vm.warp(t0 + 5 * EPOCH); // epoch 7

        assertEq(stakerV.pendingFeesOf(101), 90e18, "60*1/2 + 120*1/2");
        assertEq(stakerV.pendingFeesOf(202), 90e18);

        vm.prank(alice);
        stakerV.claimFees(101);
        assertEq(mixETH.balanceOf(alice), 90e18);
    }

    // ── genesis share claims carry their fee share ──

    function test_GenesisShareFees() public {
        vm.startPrank(address(controller));
        stakerV.lockGenesis(2000e18); // stakes at epoch 2 like everyone
        vm.stopPrank();

        vm.warp(t0 + 1 * EPOCH); // epoch 3: genesis + alice + bob live (4000 total)
        _feedFees(100e18); // genesis half = 50e18

        vm.warp(t0 + 2 * EPOCH); // epoch 4: closed
        uint256 genesisCut = (uint256(100e18) * 2000e18) / 4000e18;

        uint256 mixBefore = mixETH.balanceOf(alice);
        vm.prank(address(controller));
        stakerV.claimGenesisShare(alice, 500e18); // 1/4 of genesis → 1/4 of its cut

        assertEq(mixETH.balanceOf(alice) - mixBefore, genesisCut * 500e18 / 2000e18);
        (uint256 amt,,,,,) = stakerV.positions(1);
        assertEq(amt, 500e18, "fresh pepe carries the share");
        assertEq(stakerV.ownerOf(1), alice);
    }
}
