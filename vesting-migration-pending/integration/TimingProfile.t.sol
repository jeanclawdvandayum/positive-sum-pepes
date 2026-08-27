// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PSPFactory} from "../../../src/PSPFactory.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {HookDeployer} from "../../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../../src/ControllerDeployer.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";

import {MockMixETH} from "../../mocks/MockMixETH.sol";
import {MockPoolManager} from "../../mocks/MockPoolManager.sol";
import {StakerDeployer} from "../../../src/StakerDeployer.sol";

/// @title Timing-profile integration pins (2026-08-19)
/// @notice The original 5x64-bit timings packing shifted the vote slot by
///         256 bits — uint256 << 256 == 0 — so EVERY custom profile deployed
///         with VOTE_DURATION == 0: the vote window closed the instant it
///         opened, carpet-bomb governance died, and nothing reverted. Found
///         on the sepolia dry-run; mainnet (timings == 0) was never affected.
///         This suite pins the 51-bit repack end to end:
///           1. decode fidelity for defaults and the fast profile
///           2. the TimingsIncomplete tripwire (zero slot → revert, not silence)
///           3. a FULL vote cycle under the fast profile, including a vote
///              INSIDE the window (the exact call the bug killed)
contract TimingProfileTest is Test {
    MockPoolManager poolManager;
    MockMixETH mixETH;
    HookDeployer hookDeployer;
    ControllerDeployer controllerDeployer;
    PSPFactory factory;
    RoundController controller;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function _deployFactory(uint256 timings) internal {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 2_000_000e18}();
        poolManager = new MockPoolManager();
        hookDeployer = new HookDeployer();
        controllerDeployer = new ControllerDeployer();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)),
            IERC20(address(mixETH)),
            hookDeployer,
            controllerDeployer,
            new StakerDeployer(),
            timings
        );
        mixETH.transfer(alice, 1_000e18);
        mixETH.transfer(bob, 1_000e18);
    }

    function _deployRound() internal {
        CurveMath.CurveConfig memory cfg = CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);
        factory.deployRound(
            PSPFactory.RoundParams({name: "Positive Sum Pepes", symbol: "PSP", curveConfig: cfg})
        );
        controller = RoundController(address(factory.getRound(1).controller));
    }

    /// The pre-bug layout: the fifth field silently vanished.
    function test_bug_regression_legacyLayoutSilentlyDropsVoteSlot() public pure {
        uint256 legacy = uint256(1 days) | (uint256(3 days) << 64) | (uint256(1 days) << 128)
            | (uint256(1 days) << 192) | (uint256(1 days) << 256);
        // the vote contribution is literally zero bits
        assertEq(legacy, uint256(1 days) | (uint256(3 days) << 64) | (uint256(1 days) << 128) | (uint256(1 days) << 192));
        // ...and the decode could never see it
        assertEq(legacy >> 256, 0);
    }

    function test_defaults_decode_when_timings_zero() public {
        _deployFactory(0);
        _deployRound();
        assertEq(controller.PREDEPOSIT_DURATION(), 7 days);
        assertEq(controller.LOCK_DURATION(), 90 days);
        assertEq(controller.EXTEND_DURATION(), 90 days);
        assertEq(controller.RELOCK_WINDOW(), 7 days);
        assertEq(controller.VOTE_DURATION(), 3 days);
    }

    function test_fast_profile_decodes_exactly() public {
        _deployFactory(CurveMath.packTimings(1 days, 3 days, 1 days, 1 days, 1 days));
        _deployRound();
        assertEq(controller.PREDEPOSIT_DURATION(), 1 days, "predeposit slot");
        assertEq(controller.LOCK_DURATION(), 3 days, "lock slot");
        assertEq(controller.EXTEND_DURATION(), 1 days, "extend slot");
        assertEq(controller.RELOCK_WINDOW(), 1 days, "relock slot");
        assertEq(controller.VOTE_DURATION(), 1 days, "vote slot (dropped by 5x64 layout)");
    }

    function test_incomplete_profile_reverts_not_silences() public {
        _deployFactory(CurveMath.packTimings(1 days, 3 days, 1 days, 1 days, 0));
        vm.expectRevert(RoundController.TimingsIncomplete.selector);
        _deployRound();
    }

    /// The full governance cycle at fast timings — with a vote cast INSIDE
    /// the window, the exact call the truncation bug reverted (VotingEnded).
    function test_vote_cycle_under_fast_profile() public {
        _deployFactory(CurveMath.packTimings(1 days, 3 days, 1 days, 1 days, 1 days));
        _deployRound();

        // cap reached (500 mixETH) auto-launches without the owner
        vm.startPrank(alice);
        mixETH.approve(address(controller), 250e18);
        controller.predeposit(250e18);
        vm.stopPrank();
        vm.startPrank(bob);
        mixETH.approve(address(controller), 250e18);
        controller.predeposit(250e18);
        vm.stopPrank();
        vm.prank(makeAddr("rando"));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();
        vm.prank(bob);
        controller.claimPredepositPSP();
        skip(1); // locks strictly predate the proposal (anti lock-capture)

        vm.prank(alice);
        controller.proposeCarpetBomb();

        // +1h must be INSIDE the vote window: VOTE_DURATION == 1 day.
        // This is the assertion the 5x64 bug failed.
        skip(1 hours);
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);

        // past the 1d window the vote closes and quorum+majority execute
        (, uint256 proposeTime,,,,) = controller.currentProposal();
        vm.warp(proposeTime + 1 days + 1);
        controller.carpetBomb();
        assertGt(controller.flatTime(), 0, "round flattened after fast vote cycle");
    }
}
