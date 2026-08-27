// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AuditorBase} from "./AuditorBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoundController} from "../../../../src/RoundController.sol";
import {PSPStaker} from "../../../../src/PSPStaker.sol";
import {CurveHook} from "../../../../src/CurveHook.sol";
import {CurveMath} from "../../../../src/libraries/CurveMath.sol";
import {PSPToken} from "../../../../src/PSPToken.sol";
import {MockMixETH} from "../../../mocks/MockMixETH.sol";
import {AuditorHook} from "./AuditorMocks.sol";
import {HostileMixETH} from "./AuditorMocks.sol";
import {ReentryAttacker} from "./AuditorMocks.sol";
import {console2} from "forge-std/console2.sol";
import {StakerDeployer} from "src/StakerDeployer.sol";


/// @title A2 — RoundController accounting: fee accumulator, genesis split,
///        PSP custody invariant, claim gating, reentrancy, sweep protection.
contract A2_AccountingTest is AuditorBase {
    // ─────────────────────────────────────────────────────────────
    // F-3: accumulator floor truncation strands dust permanently
    // ─────────────────────────────────────────────────────────────

    /// addFees(2) with totalLocked = G ≫ 2: acc += (2*1e18)/G == 0 and
    /// pendingFeesMixETH is unconditionally zeroed — the 2 wei can never be
    /// claimed by anyone.
    function test_F3_accumulator_dust_stranded_forever() public {
        _deposit(alice, 100e18);
        _launch();
        _claim(alice); // sole depositor: totalLocked == initialPSP == G
        uint256 g = stakerV.totalLocked();
        assertGt(g, 2e18, "precondition: large G");

        vm.startPrank(address(audHook));
        controller.addFees(2);
        controller.addFees(3);
        vm.stopPrank();

        assertEq(stakerV.accFeePerShareMixETH(), 0, "acc should still be 0");
        assertEq(stakerV.pendingFeesMixETH(), 0, "pending zeroed despite 5 wei added");

        vm.prank(alice);
        vm.expectRevert(PSPStaker.NothingToClaim.selector);
        stakerV.claimFees();

        console2.log("wei of fees permanently unclaimable: 5");
    }

    // ─────────────────────────────────────────────────────────────
    // Fee distribution correctness
    // ─────────────────────────────────────────────────────────────

    /// 60/40 lockers split a funded fee batch; conservation within rounding
    function test_fee_split_conservation() public {
        _deposit(alice, 60e18);
        _deposit(bob, 40e18);
        _launch();
        _claim(alice);
        _claim(bob);

        mixETH.transfer(address(audHook), 1e18); // fee surplus above reserve
        vm.prank(address(audHook));
        controller.addFees(1e18);

        uint256 aliceMixBefore = mixETH.balanceOf(alice);
        uint256 bobMixBefore = mixETH.balanceOf(bob);
        vm.prank(alice);
        stakerV.claimFees();
        vm.prank(bob);
        stakerV.claimFees();

        uint256 paid = (mixETH.balanceOf(alice) - aliceMixBefore)
            + (mixETH.balanceOf(bob) - bobMixBefore);
        uint256 l = stakerV.totalLocked();
        assertLe(paid, 1e18, "over-distribution");
        // masterchef-style double floor: up to ~L/1e18 wei per claim
        assertLe(1e18 - paid, 2 * (l / 1e18) + 10, "lost more than double-floor dust");
        console2.log("rounding dust lost (wei):", 1e18 - paid);
    }

    /// Genesis-lock fees accrue to the SHARE, payable at claim time even
    /// long after launch (NK24 genesis-lock design works as documented).
    function test_genesis_fees_paid_to_late_claimer() public {
        _deposit(alice, 100e18);
        _launch();

        mixETH.transfer(address(audHook), 1e18);
        vm.prank(address(audHook));
        controller.addFees(1e18);

        vm.warp(block.timestamp + 30 days); // claim a month late
        uint256 before = mixETH.balanceOf(alice);
        _claim(alice);

        uint256 received = mixETH.balanceOf(alice) - before;
        uint256 l = stakerV.totalLocked();
        assertApproxEqAbs(received, 1e18, l / 1e18 + 2, "fees on share not paid at claim");
        assertLe(received, 1e18, "over-paid");
    }

    /// Strict claimFees path reverts on hook surplus shortfall (M-2
    /// documented); the forfeit paths still release PSP principal.
    function test_strict_claim_reverts_but_unlock_releases_principal() public {
        _deposit(alice, 100e18);
        _launch();
        _claim(alice);

        vm.prank(address(audHook));
        controller.addFees(1e18); // ledger-only: hook NOT funded

        vm.prank(alice);
        vm.expectRevert(AuditorHook.InsufficientFees.selector);
        stakerV.claimFees();

        vm.warp(block.timestamp + 90 days);
        vm.expectEmit(true, true, true, true, address(stakerV)); // (2026-08-19) Unlocked emits from the staker
        emit PSPStaker.Unlocked(alice, stakerV.totalLocked());
        vm.prank(alice);
        stakerV.unlock();
        assertEq(psp.balanceOf(alice), controller.genesisPSPSnapshot(), "principal released");
        _assertPspInvariant("after forfeit-unlock");
    }

    // ─────────────────────────────────────────────────────────────
    // H-1 custody invariant: psp.balanceOf(controller) == totalLocked + pot
    // ─────────────────────────────────────────────────────────────

    function test_psp_custody_invariant_across_ops() public {
        _deposit(alice, 100e18);
        _launch();
        _claim(alice);
        _assertPspInvariant("post-launch");

        // (2026-08-19) pot mint/credit paths removed with the side pot —
        // the only PSP movements are lock/unlock through the staker now

        // a second locker joins: custody tracks both
        // (covered in depth by Referral.t.sol R7)

        // unlock drains the staker's lock leg back to the user
        vm.warp(block.timestamp + 90 days);
        vm.prank(alice);
        stakerV.unlock();
        assertEq(stakerV.totalLocked(), 0);
        assertEq(psp.balanceOf(address(controller)), 0);
        _assertPspInvariant("post unlock");
        assertGe(psp.balanceOf(address(stakerV)), stakerV.totalLocked(), "staker custody covers all locks");
    }

    // ─────────────────────────────────────────────────────────────
    // claimPredepositPSP gating
    // ─────────────────────────────────────────────────────────────

    function test_double_claim_reverts() public {
        _deposit(alice, 100e18);
        _launch();
        _claim(alice);
        vm.prank(alice);
        vm.expectRevert(RoundController.PredepositClosed.selector);
        controller.claimPredepositPSP();
    }

    /// Pre-launch claim impossible (genesis snapshot is 0 → ZeroShare)
    function test_claim_before_launch_reverts() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(RoundController.ZeroShare.selector);
        controller.claimPredepositPSP();
    }

    /// Dust depositor: share truncates to 0 → claim refused, flag NOT set
    /// (L-4). Built on a 1:1-start curve so the math is exact.
    function test_zero_share_dust_depositor_not_marked_claimed() public {
        // separate stack with P0 = 1 PSP/mixETH
        CurveMath.CurveConfig memory curve2 =
            CurveMath.singleCurve(1e18, 100_000_000e18, 0.000000046e18, 0.1e18);
        PSPToken psp2 = new PSPToken("P2", "P2", address(audFactory));
        RoundController controller2 =
            new RoundController(psp2, mixETH, curve2, address(audFactory), address(0), new StakerDeployer());
        vm.startPrank(address(audFactory));
        psp2.setController(address(controller2));
        controller2.setHook(CurveHook(payable(address(audHook))));
        vm.stopPrank();

        // alice deposits 1 wei — dust next to bob's real deposit
        vm.startPrank(alice);
        mixETH.approve(address(controller2), 1);
        controller2.predeposit(1);
        vm.stopPrank();
        vm.startPrank(bob);
        mixETH.approve(address(controller2), 100e18);
        controller2.predeposit(100e18);
        vm.stopPrank();

        vm.prank(address(audFactory));
        controller2.launchPooledBuy();

        // alice's share: 1 wei * 1e18 / ~100e18 truncates to 0
        vm.prank(alice);
        vm.expectRevert(RoundController.ZeroShare.selector);
        controller2.claimPredepositPSP();

        // L-4: the reverted claim must NOT flip the claimed flag
        (, bool aliceClaimed) = controller2.predeposits(alice);
        assertFalse(aliceClaimed, "L-4: dust claim must not mark claimed");

        // sanity: bob (non-dust) claims fine on the same stack
        vm.prank(bob);
        controller2.claimPredepositPSP();
    }
}
