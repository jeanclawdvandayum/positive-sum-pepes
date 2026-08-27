// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SepoliaMixETH} from "../../src/testnet/SepoliaMixETH.sol";
import {MixETHFaucet} from "../../src/testnet/MixETHFaucet.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {RoundController} from "../../src/RoundController.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {StakerDeployer} from "../../src/StakerDeployer.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @title SepoliaTestnetTest — playtest kit pins (branch: sepolia)
/// @notice Pins the Friday-playtest surface: the dumb 1:1 mixETH wrapper,
///         the subsidized faucet rate (0.0001 ETH -> 100 mixETH), and the
///         playtest timing profile (1d predeposit · 2d lock · +1d extend ·
///         1d relock window · 1d vote) decoded through a REAL factory
///         round — the same value DeployPSP._testnetTimings() packs.
contract SepoliaTestnetTest is Test {
    SepoliaMixETH mix;
    MixETHFaucet faucet;

    address tester = makeAddr("tester");

    function setUp() public {
        mix = new SepoliaMixETH(); // 10M minted to this test contract
        faucet = new MixETHFaucet(IERC20(address(mix)));
        mix.transfer(address(faucet), mix.balanceOf(address(this)));
    }

    // ══════════════════════════════════════════════════════════════
    //  SepoliaMixETH — hardcoded 1:1, no yield, no admin
    // ══════════════════════════════════════════════════════════════

    function test_Mix_SupplyMintedToDeployer() public {
        assertEq(mix.balanceOf(address(this)), 0, "deployer seeded the faucet fully in setUp");
        assertEq(mix.totalSupply(), 10_000_000e18, "10M supply");
        assertEq(mix.balanceOf(address(faucet)), 10_000_000e18, "faucet holds it all");
        assertEq(mix.totalAssets(), mix.totalSupply(), "1:1 totalAssets");
    }

    function test_Mix_WrapUnwrapExactlyOneToOne() public {
        vm.deal(address(this), 5 ether);
        uint256 shares = mix.depositETH{value: 5 ether}();
        assertEq(shares, 5 ether, "5 ETH -> exactly 5 mixETH (hardcoded rate)");

        uint256 ethBefore = address(this).balance;
        uint256 ethOut = mix.redeemETH(2 ether);
        assertEq(ethOut, 2 ether, "redeem quote 1:1");
        assertEq(address(this).balance - ethBefore, 2 ether, "ETH received 1:1");
        assertEq(mix.balanceOf(address(this)), 3 ether, "shares burned");
    }

    /// @dev The rate cannot move: there is no yield or rate function to
    ///      call, so the proof is structural — wrap and unwrap after any
    ///      elapsed time still clears at exactly 1:1.
    function test_Mix_RateNeverMoves() public {
        vm.deal(address(this), 1 ether);
        mix.depositETH{value: 1 ether}();
        skip(30 days);
        uint256 ethOut = mix.redeemETH(1 ether);
        assertEq(ethOut, 1 ether, "still 1:1 after a month - no yield accrues");
    }

    // ══════════════════════════════════════════════════════════════
    //  MixETHFaucet — 0.0001 ETH buys 100 mixETH
    // ══════════════════════════════════════════════════════════════

    function test_Faucet_DripRateIsExact() public {
        vm.deal(tester, 1 ether);
        uint256 mixBefore = mix.balanceOf(tester);

        vm.prank(tester);
        faucet.drip{value: 0.0001 ether}();
        assertEq(mix.balanceOf(tester) - mixBefore, 100e18, "0.0001 ETH -> exactly 100 mixETH");
        assertEq(mix.balanceOf(address(faucet)), 10_000_000e18 - 100e18, "inventory decremented");
        assertEq(address(faucet).balance, 0.0001 ether, "ETH collected");
    }

    function test_Faucet_MultiplesAndDustKept() public {
        vm.deal(tester, 1 ether);
        uint256 ethBefore = tester.balance;
        uint256 mixBefore = mix.balanceOf(tester);

        // 0.00035 = 3 full units + 0.00005 dust below one unit
        vm.prank(tester);
        faucet.drip{value: 0.00035 ether}();
        assertEq(mix.balanceOf(tester) - mixBefore, 300e18, "3 units -> 300 mixETH");
        assertEq(ethBefore - tester.balance, 0.00035 ether, "full value taken (dust kept, not refunded)");
    }

    function test_Faucet_TooLittleReverts() public {
        vm.deal(tester, 1 ether);
        vm.prank(tester);
        vm.expectRevert(MixETHFaucet.TooLittle.selector);
        faucet.drip{value: 0.00005 ether}(); // below one unit

        vm.prank(tester);
        vm.expectRevert(MixETHFaucet.TooLittle.selector);
        faucet.drip{value: 0}();
    }

    function test_Faucet_EmptyInventoryReverts() public {
        // drain to 50 mixETH, then ask for a full 100 drip
        SepoliaMixETH smallMix = new SepoliaMixETH();
        MixETHFaucet smallFaucet = new MixETHFaucet(IERC20(address(smallMix)));
        smallMix.transfer(address(smallFaucet), 50e18);

        vm.deal(tester, 1 ether);
        vm.prank(tester);
        vm.expectRevert(MixETHFaucet.FaucetEmpty.selector);
        smallFaucet.drip{value: 0.0001 ether}();
        assertEq(tester.balance, 1 ether, "revert refunds the ETH");
    }

    // ══════════════════════════════════════════════════════════════
    //  Playtest timing profile — decoded through a real factory round
    //  (mirrors DeployPSP._testnetTimings: 1d predeposit · 2d lock ·
    //   +1d extend · 1d relock window · 1d vote)
    // ══════════════════════════════════════════════════════════════

    function test_Timings_PlaytestProfileReadback() public {
        uint256 profile = CurveMath.packTimings(1 days, 2 days, 1 days, 1 days, 1 days);
        MockPoolManager poolManager = new MockPoolManager();
        PSPFactory factory = new PSPFactory(
            IPoolManager(address(poolManager)),
            IERC20(address(mix)),
            new HookDeployer(),
            new ControllerDeployer(),
            new StakerDeployer(),
            profile
        );

        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
        });
        (uint256 roundId,) = factory.deployRound(params);
        RoundController controller = factory.getRound(roundId).controller;

        assertEq(controller.PREDEPOSIT_DURATION(), 1 days, "predeposit window = 1 day");
        assertEq(controller.LOCK_DURATION(), 2 days, "lock = 2 days");
        assertEq(controller.EXTEND_DURATION(), 1 days, "relock extends +1 day");
        assertEq(controller.RELOCK_WINDOW(), 1 days, "relock opens 1 day before expiry");
        assertEq(controller.VOTE_DURATION(), 1 days, "bomb vote = 1 day");
    }

    /// @dev Accepts ETH from redeemETH (test contract is the wrapper user).
    receive() external payable {}
}
