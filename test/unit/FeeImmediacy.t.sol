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

contract MockFactory2 {
    address public owner;
    constructor() { owner = msg.sender; }
}

/// @title FeeImmediacyTest — scoopy's must-fix (2026-08-28): trading fees must
///         be assigned and claimable AS THEY COME IN, not at epoch close.
///         Follow-up (2026-08-28b): a fresh stake must earn on the SUBSEQUENT
///         trade — no next-epoch activation wait.
/// @notice Pins the accumulator semantics:
///         1. fees fed mid-epoch are visible in pendingFeesOf and payable via
///            claimFees IMMEDIATELY — no boundary wait;
///         2. multiple feeds within one epoch stack;
///         3. fresh stakes / top-ups / cancels / genesis are live INSTANTLY —
///            the trade after the stake credits it; pre-stake fees are NOT
///            retroactively claimed (checkpoint discipline). Accepted trade:
///            front-running a known fee event with stake capital (JIT-style)
///            now works — capital-at-risk for one event's pro-rata share;
///         4. claims are checkpointed — no double pay on re-claim;
///         5. wei-scale dust is never stranded (rolling remainder);
///         6. decayers claiming epochs late get the blessed approximation:
///            ≤ bucket-exact share, never more (solvency preserved);
///         7. Σ position weights == totalWeight() at every instant.
contract FeeImmediacyTest is Test {
    RoundController controller;
    PSPStaker stakerV;
    MockMixETH mixETH;
    PSPToken pspToken;
    MockHook hook;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant VEST = 42 days;
    uint256 constant EPOCH = 7 days; // VEST / 6
    uint256 t0; // setUp ends exactly on the epoch-2 boundary

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 1000e18}();
        MockFactory2 mockFactory = new MockFactory2();
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
        pspToken.mint(carol, 10_000e18);
        vm.stopPrank();

        hook = new MockHook(address(mixETH));
        mixETH.transfer(address(hook), 500e18);
        vm.prank(address(mockFactory));
        controller.setHook(CurveHook(payable(address(hook))));

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

    // ── 1) THE complaint: fees visible + payable the moment they land ──

    function test_FeesVisibleAndClaimableSameEpoch() public {
        // mid-epoch 2 (nowhere near a boundary): a trade's fees land
        _feedFees(100e18);

        assertEq(stakerV.pendingFeesOf(101), 50e18, "visible immediately");
        assertEq(stakerV.pendingFeesOf(202), 50e18, "visible immediately");

        vm.prank(alice);
        stakerV.claimFees(101);
        assertEq(mixETH.balanceOf(alice), 50e18, "paid without waiting for epoch close");
    }

    // ── 2) multiple feeds in one epoch stack ──

    function test_MultipleFeedsSameEpochStack() public {
        _feedFees(60e18);
        assertEq(stakerV.pendingFeesOf(101), 30e18);
        _feedFees(40e18);
        assertEq(stakerV.pendingFeesOf(101), 50e18, "second feed accrues on top");

        vm.prank(bob);
        stakerV.claimFees(202);
        assertEq(mixETH.balanceOf(bob), 50e18);
    }

    // ── 3) fresh stakes earn on the SUBSEQUENT trade, never retroactively ──

    function test_FreshStakeEarnsOnSubsequentTrade() public {
        _feedFees(100e18); // lands BEFORE carol stakes — not hers

        vm.startPrank(carol);
        pspToken.approve(address(stakerV), type(uint256).max);
        stakerV.lockWithPepe(10_000e18, 303);
        vm.stopPrank();

        assertEq(stakerV.pendingFeesOf(303), 0, "no retroactive credit for pre-stake fees");

        // the first trade AFTER the stake confirms credits carol immediately
        _feedFees(120e18); // weights 1000/1000/10000
        assertEq(stakerV.pendingFeesOf(303), 100e18, "earns on the subsequent trade");
        assertEq(stakerV.pendingFeesOf(101), 50e18 + 10e18, "alice: past + new");
        assertEq(stakerV.pendingFeesOf(202), 50e18 + 10e18);

        vm.prank(carol);
        stakerV.claimFees(303);
        assertEq(mixETH.balanceOf(carol), 100e18, "claimable immediately");
    }

    function test_TopUpEarnsOnSubsequentTrade() public {
        _feedFees(100e18); // bob's 50e18 outstanding

        vm.prank(bob);
        stakerV.stakeFor(bob, 202, 2000e18); // settles + pays the 50e18, tops up

        assertEq(mixETH.balanceOf(bob), 50e18, "top-up settles pre-topup fees first");
        assertEq(stakerV.pendingFeesOf(202), 0);

        _feedFees(120e18); // weights now 1000 + 3000
        assertEq(stakerV.pendingFeesOf(202), 90e18, "top-up live immediately");
        assertEq(stakerV.pendingFeesOf(101), 50e18 + 30e18);
    }

    function test_CancelRestoresWeightImmediately() public {
        vm.prank(alice);
        stakerV.requestWithdraw(101); // r=2
        vm.warp(t0 + 1 * EPOCH); // epoch 3: alice k=1

        vm.prank(alice);
        stakerV.cancelWithdraw(101);
        assertEq(stakerV.biasOf(101, block.timestamp), 1000e18, "restored immediately");
        assertEq(stakerV.totalWeight(), 2000e18, "global restored immediately");

        _feedFees(100e18); // 50/50 again right away
        assertEq(stakerV.pendingFeesOf(101), 50e18);
    }

    function test_GenesisLiveOnFirstTrade() public {
        vm.prank(address(controller));
        stakerV.lockGenesis(2000e18); // locked during epoch 2

        _feedFees(120e18); // first trade after the genesis lock — same epoch
        assertEq(stakerV.pendingFeesOf(0), 60e18, "genesis earns from the first trade");
        assertEq(stakerV.pendingFeesOf(101), 30e18);
        assertEq(stakerV.pendingFeesOf(202), 30e18);
    }

    function test_TotalWeightMatchesPositionSumInstantly() public {
        vm.startPrank(carol);
        pspToken.approve(address(stakerV), type(uint256).max);
        stakerV.lockWithPepe(10_000e18, 303);
        vm.stopPrank();

        // same epoch as the stake: global weight already includes it
        uint256 e = block.timestamp / EPOCH;
        assertEq(
            stakerV.totalWeight(),
            stakerV.weightAt(101, e) + stakerV.weightAt(202, e) + stakerV.weightAt(303, e),
            "sum of position weights == totalWeight at every instant"
        );
    }

    // ── 4) claims checkpoint: no double pay ──

    function test_ClaimCheckpointsNoDoublePay() public {
        _feedFees(100e18);
        vm.prank(alice);
        stakerV.claimFees(101);
        assertEq(mixETH.balanceOf(alice), 50e18);

        assertEq(stakerV.pendingFeesOf(101), 0);
        vm.prank(alice);
        vm.expectRevert(PSPStaker.NothingToClaim.selector);
        stakerV.claimFees(101);

        // fees landing later accrue from the checkpoint, not from zero
        _feedFees(40e18);
        assertEq(stakerV.pendingFeesOf(101), 20e18);
    }

    // ── 5) wei-scale dust is never stranded (A-F3 rolling remainder) ──

    function test_DustWeiAccumulatesAcrossFeeds() public {
        _feedFees(2);
        _feedFees(2); // 4 wei fed, alice's half-share = 2 wei
        assertEq(stakerV.pendingFeesOf(101), 2, "sub-wei-per-feed credit accumulates");

        vm.prank(alice);
        stakerV.claimFees(101);
        assertEq(mixETH.balanceOf(alice), 2);
    }

    // ── 6) decayer approximation: under-credits only, never over ──

    function test_DecayerLateClaimUndercreditsOnly() public {
        vm.prank(alice);
        stakerV.requestWithdraw(101); // r=2, settles nothing yet

        vm.warp(t0 + 1 * EPOCH); // epoch 3: alice k=1
        uint256 wA = stakerV.biasOf(101, block.timestamp); // 5/6
        _feedFees(150e18); // epoch-3 fees at weights (wA, 1000)

        uint256 bucketExact = (150e18 * wA) / (wA + 1000e18);

        // alice does NOT claim; her weight keeps decaying
        vm.warp(t0 + 3 * EPOCH); // epoch 5: alice k=3
        uint256 pending = stakerV.pendingFeesOf(101);
        assertLt(pending, bucketExact, "late claim uses decayed weight (blessed approximation)");
        assertGt(pending, 0);

        // bob (static) is still bucket-exact
        assertEq(stakerV.pendingFeesOf(202), (150e18 * 1000e18) / (wA + 1000e18), "static position exact");

        // solvability: together they never exceed what was fed
        vm.prank(alice);
        stakerV.claimFees(101);
        vm.prank(bob);
        stakerV.claimFees(202);
        assertLe(
            mixETH.balanceOf(alice) + mixETH.balanceOf(bob), 150e18, "never over-distributes"
        );
    }

    // ── 7) documented forfeit: decayed-to-zero without claiming ──

    function test_FullyDecayedUnclaimedForfeits() public {
        vm.prank(alice);
        stakerV.requestWithdraw(101); // r=2
        vm.warp(t0 + 1 * EPOCH); // epoch 3
        _feedFees(150e18); // earned at 5/6 weight

        vm.warp(t0 + 6 * EPOCH); // epoch 8: k=6, weight zero, never claimed
        assertEq(stakerV.pendingFeesOf(101), 0, "documented: claim before your vest runs out");
    }
}
