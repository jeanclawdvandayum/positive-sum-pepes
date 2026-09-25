// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SineV3Math} from "../src/SineV3Math.sol";
import {SineV3TestData as SineV3Data} from "./helpers/SineV3TestData.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {PSPToken} from "../src/PSPToken.sol";
import {RoundController} from "../src/RoundController.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {ControllerDeployer} from "../src/ControllerDeployer.sol";
import {StakerDeployer} from "../src/StakerDeployer.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {Greenlist} from "./helpers/Greenlist.sol";
import {CSwapper} from "./wave2/auditorC/CBase.sol";

import {MockMixETH} from "./mocks/MockMixETH.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

/// @dev Short env-style windows: green rides packed timing slot [0] (the
///      old predeposit slot), open rides the factory's openWindowSec leg —
///      exactly the knobs DeployPSP's PSP_GREEN_SEC / PSP_OPEN_SEC set.
/// @dev floor(500 mixETH / 3) — the green cap for a three-entry csv.
uint256 constant GREEN_CAP_3 = 166_666_666_666_666_666_666;
uint256 constant GREEN_SEC = 120;
uint256 constant OPEN_SEC = 180;
uint256 constant VEST_SEC = 3600;

/// @title GreenlistIbcoBase — greenlist-IBCO rules v3 harness
/// @notice Real factory birth path (deployRound / detonate→spawn), sine
///         flavor (the production curve, so the split-buy integrals are
///         the exact deployed math), csv merkle greenlists built in the
///         same tree format the deploy tooling pins.
abstract contract GreenlistIbcoBase is Test {
    MockPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;
    CSwapper swapper;

    address alice = makeAddr("ibco-alice");
    address bob = makeAddr("ibco-bob");
    address carol = makeAddr("ibco-carol");
    address dave = makeAddr("ibco-dave");
    address erin = makeAddr("ibco-erin");
    address rando = makeAddr("ibco-rando");

    address[] csvEmpty;

    function setUp() public virtual {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 500_000e18}();
        poolManager = new MockPoolManager();
        _newFactory();
        swapper = new CSwapper(IPoolManager(address(poolManager)), IERC20(address(mixETH)));
        address[6] memory wallets = [alice, bob, carol, dave, erin, rando];
        for (uint256 i; i < wallets.length; ++i) {
            mixETH.transfer(wallets[i], 1000e18);
        }
    }

    function _newFactory() internal {
        factory = new PSPFactory(
            IPoolManager(address(poolManager)),
            IERC20(address(mixETH)),
            new HookDeployer(),
            new ControllerDeployer(),
            new StakerDeployer(),
            address(new SineV3Math(SineV3Data.deploy())),
            CurveMath.packTimings(GREEN_SEC, VEST_SEC), // slot [0] = green window
            address(this) // deployerCutTo
        );
        factory.setOpenWindow(uint64(OPEN_SEC));
        factory.configureSineV3(75_000_000_000_000);
    }

    function _csv3() internal returns (address[] memory csv) {
        csv = new address[](3); // odd size: pins the duplicate-pad tree walk
        csv[0] = alice;
        csv[1] = bob;
        csv[2] = carol;
    }

    function _deployRound(address[] memory csv) internal returns (PSPFactory.Round memory r) {
        factory.setNextGreenlist(csv.length == 0 ? bytes32(0) : Greenlist.rootOf(csv), csv.length);
        (uint256 id,) = factory.deployRound(PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
        }));
        r = factory.getRound(id);
    }

    // ── deposits ──

    function _green(RoundController c, address[] memory csv, address who, uint256 amt) internal {
        vm.startPrank(who);
        mixETH.approve(address(c), amt);
        c.predepositGreen(amt, Greenlist.proofOf(csv, who));
        vm.stopPrank();
    }

    /// @dev Rootless green deposit — valid only for previous-round holders
    ///      (the frozen PSP holder map is their proof).
    function _greenRootless(RoundController c, address who, uint256 amt) internal {
        vm.startPrank(who);
        mixETH.approve(address(c), amt);
        c.predepositGreen(amt, new bytes32[](0));
        vm.stopPrank();
    }

    function _open(RoundController c, address who, uint256 amt) internal {
        vm.startPrank(who);
        mixETH.approve(address(c), amt);
        c.predeposit(amt);
        vm.stopPrank();
    }

    /// @dev Fill the open tranche from fresh 10-cap wallets. The cap guards
    ///      the BENEFICIARY, so one funder may spread credits wide.
    function _openFor(RoundController c, uint256 perWallet, uint256 wallets, string memory tag)
        internal
    {
        for (uint256 i; i < wallets; ++i) {
            address w = makeAddr(string.concat(tag, vm.toString(i)));
            mixETH.transfer(w, perWallet);
            vm.startPrank(w);
            mixETH.approve(address(c), perWallet);
            c.predepositFor(w, perWallet);
            vm.stopPrank();
        }
    }

    // ── lifecycle ──

    function _launchOwner(RoundController c) internal {
        vm.prank(address(factory)); // the controller's owner may launch early
        c.launchPooledBuy();
    }

    function _detonate(PSPFactory.Round memory r) internal returns (PSPFactory.Round memory next) {
        vm.warp(r.hook.detonationAt() + 1);
        r.controller.detonate();
        next = factory.getRound(factory.currentRoundId());
    }

    function _key(PSPFactory.Round memory r) internal view returns (PoolKey memory k) {
        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(address(r.token));
        if (c0 > c1) (c0, c1) = (c1, c0);
        k = PoolKey(c0, c1, 0x800000, 60, IHooks(address(r.hook)));
    }

    /// @dev Curve buy (CSwapper settles through the mock manager).
    function _buy(PSPFactory.Round memory r, address who, uint256 amt) internal {
        vm.startPrank(who);
        mixETH.approve(address(swapper), amt);
        swapper.buy(_key(r), amt, who);
        vm.stopPrank();
    }

    /// @dev Claim and drain to the wallet's own ERC20 balance — the staker
    ///      parks claimed PSP at its own address, and only a withdrawal
    ///      makes the WALLET a PSP holder for the frozen greenlist.
    function _claimAndWithdraw(RoundController c, address who) internal {
        vm.prank(who);
        c.claimPredepositPSP();
        PSPStaker staker = c.staker();
        uint256 id = staker.primaryOf(who);
        vm.prank(who);
        staker.requestWithdraw(id);
        skip(c.VEST_DURATION() + 1); // the six-epoch decay is spent
        vm.prank(who);
        staker.withdraw(id);
    }

    /// @dev Claimed principal behind a wallet's genesis pepe.
    function _principalOf(RoundController c, address who) internal view returns (uint256) {
        PSPStaker staker = c.staker();
        (uint256 amount,,,,) = staker.positions(staker.primaryOf(who));
        return amount;
    }
}

/// @title GreenlistIbcoPhases — windows, proofs, caps, launch gates
contract GreenlistIbcoPhases is GreenlistIbcoBase {
    function test_PhaseBoundaries_GreenOpenOver() public {
        PSPFactory.Round memory r = _deployRound(_csv3());
        RoundController c = r.controller;
        uint256 t0 = c.predepositStartTime();
        assertEq(c.GREEN_DURATION(), GREEN_SEC, "green from packed slot [0]");
        assertEq(c.OPEN_DURATION(), OPEN_SEC, "open from the factory's openWindowSec");
        assertEq(uint256(c.phase()), 0, "green at birth");
        vm.warp(t0 + GREEN_SEC - 1);
        assertEq(uint256(c.phase()), 0, "last green second");
        vm.warp(t0 + GREEN_SEC);
        assertEq(uint256(c.phase()), 1, "open begins (inclusive)");
        vm.warp(t0 + GREEN_SEC + OPEN_SEC - 1);
        assertEq(uint256(c.phase()), 1, "last open second");
        vm.warp(t0 + GREEN_SEC + OPEN_SEC);
        assertEq(uint256(c.phase()), 2, "over (inclusive)");

        // no csv + no previous holders: the whole window is open-phase only
        PSPFactory.Round memory bare = _deployRound(csvEmpty);
        RoundController bc = bare.controller;
        assertEq(bc.GREEN_PER_WALLET(), 0, "no members: green disabled");
        assertEq(uint256(bc.phase()), 1, "open from birth");
        vm.warp(bc.predepositStartTime() + OPEN_SEC - 1);
        assertEq(uint256(bc.phase()), 1);
        vm.warp(bc.predepositStartTime() + OPEN_SEC);
        assertEq(uint256(bc.phase()), 2, "over after OPEN only");
    }

    function test_StateViewCarriesTheV3Fields() public {
        RoundController c = _deployRound(_csv3()).controller;
        _green(c, _csv3(), alice, 30e18);
        // split reads keep the via-ir frame shallow
        (uint256 total, uint256 cap, uint256 start,,,,,,,,) = c.predepositState();
        (,,,,,,, uint8 phaseNow, uint256 greenTotal, uint256 greenPerWallet, uint256 openPerWallet) =
            c.predepositState();
        assertEq(uint256(phaseNow), 0, "green now");
        assertEq(total, 30e18, "total");
        assertEq(cap, 1000e18, "shared cap");
        assertEq(start, c.predepositStartTime());
        assertEq(greenTotal, 30e18, "green tranche pool");
        assertEq(greenPerWallet, GREEN_CAP_3, "500/N over the csv size");
        assertEq(openPerWallet, 10e18, "whale friction cap");
        assertEq(c.totalGreenMixETH(), 30e18);
        assertEq(c.greenDepositors(), 1, "alice is the green depositor");
        (uint256 amt, uint256 greenAmt, bool claimed) = c.predeposits(alice);
        assertEq(amt, 30e18, "total credited");
        assertEq(greenAmt, 30e18, "green tranche credited");
        assertFalse(claimed);
    }

    function test_GreenDeposit_ValidProofCreditsTheGreenTranche() public {
        RoundController c = _deployRound(_csv3()).controller;
        _green(c, _csv3(), bob, 1e18);
        assertEq(c.totalGreenMixETH(), 1e18);
        assertEq(c.totalPredepositMixETH(), 1e18, "green counts toward the shared pool");
        assertEq(c.totalPredepositors(), 1);
        assertEq(c.greenDepositors(), 1);
    }

    function test_GreenDeposit_ForgedAndOmittedProofsRevert() public {
        RoundController c = _deployRound(_csv3()).controller;
        address[] memory csv = _csv3();

        // non-member with no proof
        vm.startPrank(dave);
        mixETH.approve(address(c), 1e18);
        vm.expectRevert(RoundController.NotGreenlisted.selector);
        c.predepositGreen(1e18, new bytes32[](0));
        vm.stopPrank();

        // non-member presenting a member's proof
        vm.startPrank(dave);
        vm.expectRevert(RoundController.NotGreenlisted.selector);
        c.predepositGreen(1e18, Greenlist.proofOf(csv, alice));
        vm.stopPrank();

        // member with a proof from a DIFFERENT tree (superset csv)
        address[] memory other = new address[](4);
        other[0] = alice;
        other[1] = bob;
        other[2] = carol;
        other[3] = dave;
        vm.startPrank(alice);
        vm.expectRevert(RoundController.NotGreenlisted.selector);
        c.predepositGreen(1e18, Greenlist.proofOf(other, alice));
        vm.stopPrank();

        // member with a truncated (last hop missing) proof
        bytes32[] memory full = Greenlist.proofOf(csv, alice);
        bytes32[] memory cut = new bytes32[](full.length - 1);
        for (uint256 i; i < cut.length; ++i) cut[i] = full[i];
        vm.startPrank(alice);
        vm.expectRevert(RoundController.NotGreenlisted.selector);
        c.predepositGreen(1e18, cut);
        vm.stopPrank();

        assertEq(c.totalGreenMixETH(), 0, "nothing credited");
    }

    function test_GreenPerWalletCap_Is500OverN_ExactlyAtTheBoundary() public {
        address[] memory csv = _csv3();
        RoundController c = _deployRound(csv).controller;
        assertEq(c.GREEN_PER_WALLET(), GREEN_CAP_3, "N = csv entries on genesis");

        _green(c, csv, alice, GREEN_CAP_3); // exactly at the cap
        (, uint256 greenAmt,) = c.predeposits(alice);
        assertEq(greenAmt, GREEN_CAP_3);

        vm.startPrank(alice);
        mixETH.approve(address(c), 1);
        vm.expectRevert(RoundController.GreenCapExceeded.selector);
        c.predepositGreen(1, Greenlist.proofOf(csv, alice));
        vm.stopPrank();

        // a sibling member keeps their own full cap
        _green(c, csv, bob, GREEN_CAP_3);
        vm.startPrank(bob);
        mixETH.approve(address(c), 1);
        vm.expectRevert(RoundController.GreenCapExceeded.selector);
        c.predepositGreen(1, Greenlist.proofOf(csv, bob));
        vm.stopPrank();
    }

    function test_OpenCapTenPerWallet_GreenDoesNotConsumeOpenHeadroom() public {
        address[] memory csv = _csv3();
        RoundController c = _deployRound(csv).controller;

        // alice fills her ENTIRE green cap during the green phase...
        _green(c, csv, alice, GREEN_CAP_3);
        vm.warp(c.predepositStartTime() + GREEN_SEC); // open begins

        // ...and still has her full 10-mix open allowance afterwards
        _open(c, alice, 10e18);
        vm.startPrank(alice);
        mixETH.approve(address(c), 1);
        vm.expectRevert(RoundController.WalletCapExceeded.selector);
        c.predeposit(1);
        vm.stopPrank();

        // a fresh wallet: exactly 10 passes, one wei more reverts
        _open(c, bob, 10e18);
        vm.startPrank(bob);
        mixETH.approve(address(c), 1);
        vm.expectRevert(RoundController.WalletCapExceeded.selector);
        c.predeposit(1);
        vm.stopPrank();

        (uint256 amt, uint256 greenAmt,) = c.predeposits(alice);
        assertEq(amt, GREEN_CAP_3 + 10e18, "both tranches credited to one wallet");
        assertEq(greenAmt, GREEN_CAP_3, "green slice untouched by the open leg");
    }

    function test_WrongPhaseRevertsBothWays() public {
        address[] memory csv = _csv3();
        RoundController c = _deployRound(csv).controller;
        uint256 t0 = c.predepositStartTime();

        // open-path entry points during the green phase
        vm.startPrank(alice);
        mixETH.approve(address(c), type(uint256).max);
        vm.expectRevert(RoundController.WrongPhase.selector);
        c.predeposit(1e18);
        vm.expectRevert(RoundController.WrongPhase.selector);
        c.predepositFor(alice, 1e18);
        vm.expectRevert(RoundController.WrongPhase.selector);
        c.predepositWithPepe(1e18, 42);
        vm.stopPrank();

        _green(c, csv, alice, 1e18);
        vm.warp(t0 + GREEN_SEC); // open

        // green entry during the open phase
        vm.startPrank(bob);
        mixETH.approve(address(c), 1e18);
        vm.expectRevert(RoundController.WrongPhase.selector);
        c.predepositGreen(1e18, Greenlist.proofOf(csv, bob));
        vm.stopPrank();

        vm.warp(t0 + GREEN_SEC + OPEN_SEC); // over
        vm.startPrank(alice);
        vm.expectRevert(RoundController.WrongPhase.selector);
        c.predeposit(1);
        vm.expectRevert(RoundController.WrongPhase.selector);
        c.predepositGreen(1, Greenlist.proofOf(csv, alice));
        vm.stopPrank();
    }

    function test_SharedThousandCap_BoundaryAndCapLaunch() public {
        address[] memory csv = _csv3();
        RoundController c = _deployRound(csv).controller;

        // green fills its floor budget (3 x floor(500/3) — 2 wei short)
        _green(c, csv, alice, GREEN_CAP_3);
        _green(c, csv, bob, GREEN_CAP_3);
        _green(c, csv, carol, GREEN_CAP_3);
        assertEq(c.totalPredepositMixETH(), 3 * GREEN_CAP_3);

        vm.warp(c.predepositStartTime() + GREEN_SEC);
        // 49 fresh wallets fill 490; alice's 10 plus bob's 2-wei dust
        // (floor rounding leaves exactly 2 wei of green headroom) finish 1000
        _openFor(c, 10e18, 49, "shared-cap-");
        _open(c, alice, 10e18);
        _open(c, bob, 2);
        assertEq(c.totalPredepositMixETH(), 1000e18, "exactly at the shared cap");

        vm.startPrank(dave);
        mixETH.approve(address(c), 1);
        vm.expectRevert(RoundController.CapExceeded.selector);
        c.predeposit(1);
        vm.stopPrank();

        (,,,, bool capReached,, bool launchable,,,,) = c.predepositState();
        assertTrue(capReached, "cap reached mid-window");
        assertTrue(launchable, "cap makes the launch permissionless");
        vm.prank(rando); // non-owner, window still open
        c.launchPooledBuy();
        assertTrue(c.predepositClosed());
    }

    function test_LaunchGates_OwnerEarly_WindowOver_CapReached() public {
        address[] memory csv = _csv3();
        RoundController c = _deployRound(csv).controller;

        _green(c, csv, alice, 1e18);
        vm.prank(rando);
        vm.expectRevert(RoundController.PredepositOpen.selector);
        c.launchPooledBuy();

        _launchOwner(c); // owner may launch early
        assertTrue(c.predepositClosed(), "owner early launch");
    }

    function test_LaunchGates_WindowOverLetsAnyoneLaunch() public {
        RoundController c = _deployRound(_csv3()).controller;
        _green(c, _csv3(), alice, 1e18);
        vm.warp(c.predepositStartTime() + GREEN_SEC + OPEN_SEC);
        (,,,,,, bool launchable,,,,) = c.predepositState();
        assertTrue(launchable, "window over => launchable");
        vm.prank(rando);
        c.launchPooledBuy();
        assertTrue(c.predepositClosed());
    }

    function test_WindowOverStillRefusesDepositsAndZeroBootLaunch() public {
        RoundController c = _deployRound(_csv3()).controller;
        vm.warp(c.predepositStartTime() + GREEN_SEC + OPEN_SEC);
        vm.startPrank(alice);
        mixETH.approve(address(c), 1);
        vm.expectRevert(RoundController.WrongPhase.selector);
        c.predeposit(1);
        vm.stopPrank();
        vm.expectRevert(); // zero boot cannot launch
        c.launchPooledBuy();
    }
}

/// @title GreenlistIbcoLaunch — split genesis buys, per-tranche claims,
///        carry placement, and the frozen-holder rebirth greenlist
contract GreenlistIbcoLaunch is GreenlistIbcoBase {
    /// @dev G = 100 green, O = 60 open (6 x 10): buy #1 covers the green
    ///      pool's post-fee boot, buy #2 the remainder — the exact sine
    ///      integral segmentation, then claimed per tranche.
    function test_SplitLaunch_ExactTrancheValuesAndClaims() public {
        address[] memory csv = new address[](1);
        csv[0] = alice;
        PSPFactory.Round memory r = _deployRound(csv);
        RoundController c = r.controller;
        CurveHook hook = r.hook;

        _green(c, csv, alice, 100e18);
        vm.warp(c.predepositStartTime() + GREEN_SEC);
        _open(c, alice, 10e18); // alice joins BOTH tranches
        _open(c, bob, 10e18);
        _open(c, carol, 10e18);
        _open(c, dave, 10e18);
        _open(c, erin, 10e18);
        _open(c, rando, 10e18);
        assertEq(c.totalPredepositMixETH(), 160e18);
        assertEq(c.totalGreenMixETH(), 100e18);

        vm.warp(c.predepositStartTime() + GREEN_SEC + OPEN_SEC);
        vm.prank(rando);
        c.launchPooledBuy();

        // exact segmentation: F(0.9*G), then F(0.9*(G+O)) - F(0.9*G)
        uint256 greenExp = hook.sineGenesisPSP(90e18);
        uint256 totalExp = hook.sineGenesisPSP(144e18);
        assertEq(c.greenPSPSnapshot(), greenExp, "buy #1 = green pool integral");
        assertEq(c.openPSPSnapshot(), totalExp - greenExp, "buy #2 = the remainder");
        assertEq(c.genesisPSPSnapshot(), totalExp, "total unchanged");
        uint256 openShare = (totalExp - greenExp) * 10e18 / 60e18;
        _claimExpect(c, alice, greenExp + openShare);
        _claimExpect(c, bob, openShare);
        _claimExpect(c, carol, openShare);
        _claimExpect(c, dave, openShare);
        _claimExpect(c, erin, openShare);
        _claimExpect(c, rando, openShare);
    }

    /// @dev Only a green pool: still launches, buy #2 is empty, the green
    ///      depositor owns the whole genesis.
    function test_OnlyGreenPoolLaunches() public {
        address[] memory csv = new address[](1);
        csv[0] = alice;
        PSPFactory.Round memory r = _deployRound(csv);
        RoundController c = r.controller;
        _green(c, csv, alice, 100e18);

        vm.warp(c.predepositStartTime() + GREEN_SEC + OPEN_SEC);
        vm.prank(rando);
        c.launchPooledBuy();
        assertEq(c.greenPSPSnapshot(), r.hook.sineGenesisPSP(90e18), "buy #1 = green integral");
        assertEq(c.openPSPSnapshot(), 0, "no open pool: buy #2 buys nothing");
        _claimExpect(c, alice, c.genesisPSPSnapshot());
    }

    /// @dev Only an open pool (no csv, no previous holders): buy #1 is
    ///      empty, everything rides buy #2.
    function test_OnlyOpenPoolLaunches() public {
        PSPFactory.Round memory r = _deployRound(csvEmpty);
        RoundController c = r.controller;
        assertEq(c.GREEN_PER_WALLET(), 0);
        _open(c, alice, 10e18);
        _open(c, bob, 10e18);

        vm.warp(c.predepositStartTime() + OPEN_SEC); // window = OPEN only
        vm.prank(rando);
        c.launchPooledBuy();

        assertEq(c.greenPSPSnapshot(), 0, "no green pool: buy #1 buys nothing");
        assertEq(c.openPSPSnapshot(), c.genesisPSPSnapshot(), "everything rides buy #2");
        uint256 half = c.genesisPSPSnapshot() / 2;
        _claimExpect(c, alice, half);
        _claimExpect(c, bob, half);
    }

    /// @dev Factory carry (the rebirth seed) joins the OPEN tranche: with
    ///      no public deposits the carry is the open pool and buy #1 is
    ///      empty.
    function test_CarryJoinsTheOpenTranche() public {
        PSPFactory.Round memory r1 = _deployRound(csvEmpty);
        _open(r1.controller, alice, 10e18);
        vm.warp(r1.controller.predepositStartTime() + OPEN_SEC);
        _launchOwner(r1.controller);

        // factory purse becomes round 2's carry (donation-shaped)
        mixETH.transfer(address(factory), 1000e18);
        PSPFactory.Round memory r2 = _detonate(r1);
        assertEq(r2.controller.totalPredepositMixETH(), 1000e18, "carry seeded at birth");
        (,,,, bool capReached,, bool launchable,,,,) = r2.controller.predepositState();
        assertTrue(capReached, "carry counts toward the cap");
        assertFalse(r2.controller.predepositClosed());
        assertTrue(launchable, "carry makes round 2 launchable");

        vm.prank(rando);
        r2.controller.launchPooledBuy();
        assertEq(r2.controller.greenPSPSnapshot(), 0, "carry is not a green deposit");
        assertEq(
            r2.controller.openPSPSnapshot(),
            r2.hook.sineGenesisPSP(900e18),
            "carry rides buy #2 (the open tranche)"
        );
    }

    /// @dev Legacy pot carry (potDeposit) rides buy #1 when the open pool
    ///      is EMPTY — a carry-only round still launches.
    function test_PotCarryRidesBuyOneWhenOpenIsEmpty() public {
        PSPFactory.Round memory r = _deployRound(csvEmpty);
        RoundController c = r.controller;

        mixETH.transfer(address(factory), 100e18); // the purse potDeposit pulls from
        vm.startPrank(address(factory));
        mixETH.approve(address(c), 100e18);
        c.potDeposit(100e18); // legacy path: carryBonusMixETH, no shares
        vm.stopPrank();
        assertEq(c.carryBonusMixETH(), 100e18);
        assertEq(c.totalPredepositMixETH(), 0, "bonus creates no shares");

        vm.warp(c.predepositStartTime() + OPEN_SEC);
        vm.prank(rando);
        c.launchPooledBuy();
        assertEq(c.greenPSPSnapshot(), r.hook.sineGenesisPSP(90e18), "carry rides buy #1");
        assertEq(c.openPSPSnapshot(), 0);
    }

    /// @dev The frozen holder map is the next round's greenlist: genesis
    ///      claimants who withdrew, curve buyers, and a wallet that
    ///      transferred everything away pre-detonation (NOT greenlisted).
    ///      Round-2 non-participants are absent from round 3's greenlist.
    function test_RebirthGreenlist_IsTheFrozenHolderMap_PreviousRoundOnly() public {
        // ── round 1: csv-less genesis, mixed holder origins ──
        PSPFactory.Round memory r1 = _deployRound(csvEmpty);
        RoundController c1 = r1.controller;
        _open(c1, alice, 10e18);
        _open(c1, bob, 10e18);
        vm.warp(c1.predepositStartTime() + OPEN_SEC);
        _launchOwner(c1);

        _claimAndWithdraw(c1, alice); // holder via genesis claim + withdrawal
        vm.prank(bob);
        c1.claimPredepositPSP(); // PSP parked in the staker: NOT a holder

        // holders via curve buys
        uint256 tp = r1.hook.ticketPrice();
        _buy(r1, carol, tp * 3);
        _buy(r1, erin, tp * 3);
        // erin dumps everything pre-detonation: holder[erin] clears
        // (balance read BEFORE the prank — a staticcall would eat it)
        uint256 erinBag = PSPToken(address(r1.token)).balanceOf(erin);
        vm.prank(erin);
        PSPToken(address(r1.token)).transfer(carol, erinBag);

        PSPStaker staker1 = c1.staker();
        assertTrue(PSPToken(address(r1.token)).holder(alice));
        assertTrue(PSPToken(address(r1.token)).holder(carol));
        assertTrue(PSPToken(address(r1.token)).holder(address(staker1)), "staked PSP counts");
        assertFalse(PSPToken(address(r1.token)).holder(bob), "parked genesis share is not held");
        assertFalse(PSPToken(address(r1.token)).holder(erin), "transferred away");

        // ── detonate: the map freezes and becomes round 2's greenlist ──
        PSPFactory.Round memory r2 = _detonate(r1);
        assertTrue(PSPToken(address(r1.token)).holdersFrozen(), "map frozen at detonation");
        uint256 n2 = PSPToken(address(r1.token)).holderCount();
        assertEq(r2.controller.GREEN_PER_WALLET(), 500e18 / n2, "500/N over frozen holders");
        assertEq(address(r2.controller.PREV_TOKEN()), address(r1.token));

        // rootless entries: holders pass with NO proof at all
        _greenRootless(r2.controller, alice, 10e18);
        _greenRootless(r2.controller, carol, 10e18);
        vm.startPrank(bob);
        mixETH.approve(address(r2.controller), 10e18);
        vm.expectRevert(RoundController.NotGreenlisted.selector);
        r2.controller.predepositGreen(10e18, new bytes32[](0));
        vm.stopPrank();
        vm.startPrank(erin);
        mixETH.approve(address(r2.controller), 10e18);
        vm.expectRevert(RoundController.NotGreenlisted.selector);
        r2.controller.predepositGreen(10e18, new bytes32[](0));
        vm.stopPrank();

        // ── round 2 plays out with alice only, then dies ──
        vm.warp(r2.controller.predepositStartTime() + GREEN_SEC + OPEN_SEC);
        vm.prank(rando);
        r2.controller.launchPooledBuy();
        _claimAndWithdraw(r2.controller, alice); // alice holds round-2 PSP

        PSPFactory.Round memory r3 = _detonate(r2);
        _assertRound3GreenlistIsRound2Only(r2, r3);
    }

    /// @dev Continuation of the rebirth test, split for the via-ir frame.
    function _assertRound3GreenlistIsRound2Only(
        PSPFactory.Round memory r2,
        PSPFactory.Round memory r3
    ) internal {
        // the greenlist is PREVIOUS-ROUND-ONLY: round-1 holders who skipped
        // round 2 (bob, carol, erin never touched token 2) are out
        PSPToken tok2 = PSPToken(address(r2.token));
        assertTrue(tok2.holder(alice));
        assertFalse(tok2.holder(bob), "round-1 play does not carry into round 3");
        assertFalse(tok2.holder(carol));
        assertFalse(tok2.holder(erin));
        assertEq(r3.controller.GREEN_PER_WALLET(), 500e18 / tok2.holderCount());

        _greenRootless(r3.controller, alice, 10e18);
        vm.startPrank(carol);
        mixETH.approve(address(r3.controller), 10e18);
        vm.expectRevert(RoundController.NotGreenlisted.selector);
        r3.controller.predepositGreen(10e18, new bytes32[](0));
        vm.stopPrank();
    }

    function _claimExpect(RoundController c, address who, uint256 expect) internal {
        vm.prank(who);
        c.claimPredepositPSP();
        assertEq(_principalOf(c, who), expect, "per-tranche pro-rata claim");
    }
}
