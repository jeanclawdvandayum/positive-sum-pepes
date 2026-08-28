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
/// @notice Pins the new accumulator semantics:
///         1. fees fed mid-epoch are visible in pendingFeesOf and payable via
///            claimFees IMMEDIATELY — no boundary wait;
///         2. multiple feeds within one epoch stack;
///         3. fresh stakes still earn nothing until the next epoch (the
///            anti-sandwich property is preserved — immediacy ≠ front-running);
///         4. claims are checkpointed — no double pay on re-claim;
///         5. wei-scale dust is never stranded (rolling remainder);
///         6. decayers claiming epochs late get the blessed approximation:
///            ≤ bucket-exact share, never more (solvency preserved).
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

    // ── 3) immediacy does NOT open a same-epoch sandwich ──

    function test_FreshStakeCannotHarvestSameEpochFees() public {
        _feedFees(100e18); // alice + bob split

        // carol sees the fee event and stakes in the same epoch
        vm.startPrank(carol);
        pspToken.approve(address(stakerV), type(uint256).max);
        stakerV.lockWithPepe(10_000e18, 303);
        vm.stopPrank();

        assertEq(stakerV.pendingFeesOf(303), 0, "fresh stake earns nothing this epoch");
        assertEq(stakerV.pendingFeesOf(101), 50e18, "existing stakers unaffected");

        // and carol cannot claim before her weight goes live at the boundary
        vm.prank(carol);
        vm.expectRevert(PSPStaker.NothingToClaim.selector);
        stakerV.claimFees(303);

        // after the boundary carol earns from NEW fees only — not the past ones
        vm.warp(t0 + EPOCH); // epoch 3
        _feedFees(120e18); // weights 1000/1000/10000 -> carol 10/12
        assertEq(stakerV.pendingFeesOf(303), 100e18, "carol earns new fees at live weight");
        assertEq(stakerV.pendingFeesOf(101), 50e18 + 10e18, "alice keeps past + new");
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
