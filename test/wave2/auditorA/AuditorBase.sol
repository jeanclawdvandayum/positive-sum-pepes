// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PSPToken} from "../../../src/PSPToken.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";
import {MockMixETH} from "../../mocks/MockMixETH.sol";
import {AuditorFactory} from "./AuditorMocks.sol";
import {AuditorHook} from "./AuditorMocks.sol";

/// @dev Shared harness: controller deployed with AuditorFactory as owner and
///      AuditorHook wired. Governance ops driven via pranks on the factory.
contract AuditorBase is Test {
    MockMixETH mixETH;
    PSPToken psp;
    AuditorFactory audFactory;
    AuditorHook audHook;
    RoundController controller;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address eve = makeAddr("eve");

    // same shape as test/unit/Controller.t.sol (validated config)
    CurveMath.CurveConfig curve =
        CurveMath.singleCurve(0.0001e18, 100_000_000e18, 0.000000046e18, 0.1e18);

    function setUp() public virtual {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 2_000_000e18}();

        audFactory = new AuditorFactory();
        psp = new PSPToken("PSP", "PSP", address(audFactory));
        controller = new RoundController(psp, IERC20(address(mixETH)), curve, address(audFactory));

        audHook = new AuditorHook(IERC20(address(mixETH)));

        // wire: factory owns token + controller, hook attached
        vm.startPrank(address(audFactory));
        psp.setController(address(controller));
        controller.setHook(CurveHook(payable(address(audHook))));
        vm.stopPrank();

        // fund actors
        mixETH.transfer(alice, 100_000e18);
        mixETH.transfer(bob, 100_000e18);
        mixETH.transfer(carol, 100_000e18);
        mixETH.transfer(dave, 100_000e18);
        mixETH.transfer(eve, 100_000e18);
    }

    // ─────────────── lifecycle helpers ───────────────

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        mixETH.approve(address(controller), amount);
        controller.predeposit(amount);
        vm.stopPrank();
    }

    /// @dev factory (owner) launches the pooled buy with whatever predeposits exist
    function _launch() internal {
        vm.prank(address(audFactory));
        controller.launchPooledBuy();
    }

    /// @dev claim genesis PSP — auto-locks into the governance lock
    function _claim(address who) internal {
        vm.prank(who);
        controller.claimPredepositPSP();
    }

    /// @dev `proposer` proposes + votes yes, window passes, bomb executes
    function _bomb(address proposer) internal {
        vm.prank(proposer);
        controller.proposeCarpetBomb();
        vm.prank(proposer);
        controller.voteCarpetBomb(true);
        _warpPastVote();
        controller.carpetBomb();
    }

    function _warpPastVote() internal {
        vm.warp(block.timestamp + controller.VOTE_DURATION() + 1);
    }

    function _warpPastFlatWindow() internal {
        vm.warp(controller.flatTime() + controller.FLAT_EXIT_WINDOW() + 1);
    }

    /// @dev H-1 custody: every PSP at the controller is accounted for
    function _assertPspInvariant(string memory tag) internal view {
        assertEq(
            psp.balanceOf(address(controller)),
            controller.totalLocked() + controller.potPSPBalance(),
            tag
        );
    }
}
