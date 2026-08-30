// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {PSPStaker} from "../../src/PSPStaker.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {StakerDeployer} from "../../src/StakerDeployer.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @title PlaytestFixes2 — scoopy's 2026-08-29 testnet-demo feedback wave
/// @notice Covers the per-wallet predeposit cap (#7) and the factory's
///         UI round views + rebirth loop (#6): currentRound, pspRoundToken,
///         roundPool, roundInfo — including round 2 = PSP2 after a bomb.
contract PlaytestFixes2 is Test {
    MockPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;
    PSPStaker stakerV;
    RoundController controller;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    PSPToken psp1;

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();
        poolManager = new MockPoolManager();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)),
            IERC20(address(mixETH)),
            new HookDeployer(),
            new ControllerDeployer(),
            new StakerDeployer(),
            0
        );

        PSPFactory.RoundParams memory params;
        params.name = "Positive Sum Pepes";
        params.symbol = "PSP";
        params.curveConfig = CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);
        factory.deployRound(params);

        (PSPToken tok1, RoundController ctl1,,,,) = factory.rounds(1);
        controller = ctl1;
        stakerV = controller.staker();
        psp1 = tok1;

        mixETH.transfer(alice, 20_000e18);
        mixETH.transfer(bob, 20_000e18);
    }

    /// @dev A second factory carrying the TESTNET packed profile incl. the
    ///      per-wallet cap (10 whole mixETH) — the cap is factory-packed, so
    ///      capped rounds need their own factory.
    function _cappedController() internal returns (RoundController c) {
        PSPFactory f = new PSPFactory(
            IPoolManager(address(poolManager)),
            IERC20(address(mixETH)),
            new HookDeployer(),
            new ControllerDeployer(),
            new StakerDeployer(),
            CurveMath.packTimingsCapped(2 hours, 1 hours, 30 minutes, 10 minutes, 10)
        );
        PSPFactory.RoundParams memory params;
        params.name = "Capped";
        params.symbol = "CAP";
        params.curveConfig = CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);
        f.deployRound(params);
        (, c,,,,) = f.rounds(1);
        assertEq(c.PREDEPOSIT_CAP_PER_WALLET(), 10e18, "cap packed");
    }

    // ─────────────── #7: per-wallet predeposit cap ───────────────

    function test_PerWalletPredepositCap() public {
        RoundController c = _cappedController();
        vm.startPrank(alice);
        mixETH.approve(address(c), type(uint256).max);

        // 10 is the ceiling — depositing exactly 10 works
        c.predeposit(10e18);
        (uint256 aliceDep,) = c.predeposits(alice);
        assertEq(aliceDep, 10e18);

        // any further top-up reverts (10 + ε > 10)
        vm.expectRevert(RoundController.WalletCapExceeded.selector);
        c.predeposit(1);
        vm.stopPrank();

        // a fresh wallet still has its own 10
        vm.startPrank(bob);
        mixETH.approve(address(c), type(uint256).max);
        c.predeposit(10e18);
        (uint256 bobDep,) = c.predeposits(bob);
        assertEq(bobDep, 10e18);

        // overshooting in ONE tx reverts too
        vm.expectRevert(RoundController.WalletCapExceeded.selector);
        c.predeposit(10e18 + 1);
        vm.stopPrank();
    }

    function test_PerWalletCapIsPerBeneficiary() public {
        RoundController c = _cappedController();
        // predepositFor credits the BENEFICIARY — the cap guards bob, even
        // when alice is the one sending funds
        vm.startPrank(alice);
        mixETH.approve(address(c), type(uint256).max);
        c.predepositFor(bob, 6e18);
        vm.expectRevert(RoundController.WalletCapExceeded.selector);
        c.predepositFor(bob, 5e18); // 6 + 5 > 10
        vm.stopPrank();
    }

    function test_UncappedProfileHasNoWalletCap() public {
        // the default (timings == 0) factory is UNCAPPED — one wallet may
        // predeposit the whole global cap (mainnet + legacy-test semantics)
        assertEq(controller.PREDEPOSIT_CAP_PER_WALLET(), 0);
        vm.startPrank(alice);
        mixETH.approve(address(controller), type(uint256).max);
        controller.predeposit(500e18);
        vm.stopPrank();
        assertEq(controller.totalPredepositMixETH(), 500e18);
    }

    // ─────────────── #6: factory UI views + rebirth ───────────────

    function test_FactoryViews_Round1() public {
        assertEq(factory.currentRound(), 1, "currentRound = 1");

        (PSPToken tokR1, RoundController ctlR1, CurveHook hookR1,,, ) = factory.rounds(1);
        address tok = factory.pspRoundToken(1);
        assertTrue(tok != address(0));
        assertEq(tok, address(tokR1));

        (address c0, address c1, uint24 fee, int24 spacing, address hook) = factory.roundPool(1);
        assertEq(fee, 0x800000, "dynamic-fee flag");
        assertEq(spacing, factory.tickSpacing());
        assertEq(hook, address(hookR1));
        if (address(mixETH) < tok) {
            assertEq(c0, address(mixETH));
            assertEq(c1, tok);
        } else {
            assertEq(c0, tok);
            assertEq(c1, address(mixETH));
        }

        (
            address token,
            address ctl,
            address hk,
            address stk,
            address registry,
            string memory name,
            string memory symbol,
            bool destroyed,
            uint256 pd,
            uint256 vest,
            uint256 vote,
            uint256 flatExit
        ) = factory.roundInfo(1);
        assertEq(token, tok);
        assertEq(ctl, address(ctlR1));
        assertEq(hk, hook);
        assertEq(stk, address(stakerV));
        assertTrue(registry != address(0));
        assertEq(name, "Positive Sum Pepes");
        assertEq(symbol, "PSP");
        assertFalse(destroyed);
        // mainnet-default timings (factory constructed with _timings == 0)
        assertEq(pd, 7 days);
        assertEq(vest, 42 days);
        assertEq(vote, 3 days);
        assertEq(flatExit, 3 days);
    }

    function test_FactoryViews_UnknownRoundReverts() public {
        vm.expectRevert(PSPFactory.RoundNotFound.selector);
        factory.pspRoundToken(99);
        vm.expectRevert(PSPFactory.RoundNotFound.selector);
        factory.roundPool(99);
        vm.expectRevert(PSPFactory.RoundNotFound.selector);
        factory.roundInfo(99);
    }

    /// @dev The full rebirth loop, exercising the views at every hop:
    ///      predeposit → launch → stake → bomb → exit window → finalize
    ///      → round 2 exists as "Positive Sum Pepes 2"/"PSP2" with the
    ///      carry seeded and its own fresh token, starting from ITS
    ///      predeposit phase.
    function test_Rebirth_Round2IsPSP2_FromPredeposit() public {
        // ── round 1 lifecycle ──
        vm.startPrank(alice);
        mixETH.approve(address(controller), 100e18);
        controller.predeposit(100e18);
        vm.stopPrank();
        vm.prank(address(factory)); // owner may launch before the window closes
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();
        // epoch boundary so the claim carries vote weight
        vm.warp(((block.timestamp / 7 days) + 1) * 7 days + 1);

        address psp1Addr = address(psp1);

        // ── bomb: propose + unanimous vote + execute ──
        vm.prank(alice);
        controller.proposeCarpetBomb();
        _voteAll(alice, true);
        (, uint256 proposeTime,,,) = controller.currentProposal();
        vm.warp(proposeTime + 3 days + 1);
        controller.carpetBomb(); // → Flat

        // flat: buys dead, sells open (exit at average backing)
        (,, CurveHook hook1,,,) = factory.rounds(1);
        vm.expectRevert(CurveHook.BuyingDisabled.selector);
        hook1.getBuyOutput(1e18);

        // ── exit window closes → finalize births round 2 ──
        vm.warp(block.timestamp + 3 days + 1);
        controller.finalizeCarpet();
        factory.birthRound(); // staged: birth is the second, permissionless tx

        assertEq(factory.currentRound(), 2, "round 2 is current");

        // round 2's token is a NEW ERC20 ("PSP2"), not round 1's
        address psp2 = factory.pspRoundToken(2);
        assertTrue(psp2 != address(0));
        assertTrue(psp2 != psp1Addr, "round 2 must have its own token");
        assertEq(PSPToken(psp2).name(), "Positive Sum Pepes 2");
        assertEq(PSPToken(psp2).symbol(), "PSP2");

        // round 2 starts from ITS predeposit phase: mode 0, window open
        (, RoundController c2, CurveHook hook2,,,) = factory.rounds(2);
        assertEq(uint8(hook2.mode()), uint8(CurveHook.Mode.Predeposit));
        assertFalse(c2.predepositClosed());

        // the carry seeded round 2's predeposit (round 1's whole reserve)
        assertGt(c2.totalPredepositMixETH(), 0, "carry seeded the new predeposit");

        // roundInfo(2) exposes everything the UI needs
        (,,,,, string memory n2, string memory s2, bool destroyed2,,,,) = factory.roundInfo(2);
        assertEq(n2, "Positive Sum Pepes 2");
        assertEq(s2, "PSP2");
        assertFalse(destroyed2);

        // ...and round 1 is flagged destroyed in the same view
        (,,,,,,, bool destroyed1,,,,) = factory.roundInfo(1);
        assertTrue(destroyed1);

        // a wallet can predeposit into round 2 immediately (per-wallet cap fresh)
        vm.startPrank(bob);
        mixETH.approve(address(c2), type(uint256).max);
        c2.predeposit(10e18);
        vm.stopPrank();
    }

    function _voteAll(address who, bool support) internal {
        uint256 n = stakerV.balanceOf(who);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = stakerV.tokenOfOwnerByIndex(who, i);
        vm.prank(who);
        controller.voteCarpetBomb(ids, support);
    }
}
