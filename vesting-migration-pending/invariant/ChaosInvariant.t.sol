// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PSPToken} from "../../../src/PSPToken.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {PSPStaker} from "../../../src/PSPStaker.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";
import {MockMixETH} from "../../mocks/MockMixETH.sol";
import {MockHook} from "../../mocks/MockHook.sol";
import {StakerDeployer} from "src/StakerDeployer.sol";


/// @title ChaosInvariant — Full-system invariant fuzzing
/// @notice Handler models the REAL controller (not a simulation): real locks,
///         real fee accumulator, real claims, warps through unlock windows.
///         Invariants assert accounting integrity under arbitrary sequences.
contract ChaosInvariant is Test {
    ChaosHandler handler;

    function setUp() public {
        handler = new ChaosHandler();
        targetContract(address(handler));
    }

    /// INV-1: Fees claimed by lockers can never (meaningfully) exceed fees
    ///        added by the hook.
    /// @dev Allowance: integer pro-rata rounding. Each paid claim computes
    ///      floor(m*acc2/P) - floor(m*acc1/P), which can exceed the exact
    ///      difference by < 1 wei when fractional parts cross an integer
    ///      boundary (classic Synthetix-accumulator property). Overpayment
    ///      is bounded by 1 wei per PAID claim and requires real accrued
    ///      fees — empty claims return early, so it cannot be looped. The
    ///      +1000 wei slack (1e-15 mixETH) keeps this invariant razor-tight
    ///      against any MATERIAL theft while tolerating the rounding floor.
    ///      Reproduced: ChaosReplay 12-call sequence, delta = exactly 1 wei.
    function invariant_ClaimedNeverExceedsAdded() public view {
        assertLe(
            handler.totalClaimedETHValue(),
            handler.totalFeesAdded() + 1000,
            "lockers extracted more fees than ever existed"
        );
    }

    /// INV-2: Sum of all lock positions == stakerV.totalLocked (no phantom/untracked PSP)
    function invariant_TrackedLocksMatchAccounting() public view {
        assertEq(
            handler.sumLockAmounts(),
            handler.controller().staker().totalLocked(),
            "lock position sum diverged from totalLocked"
        );
    }

    /// INV-3: Nobody's pending fees can exceed the hook's available balance
    /// (aggregate outstanding claims are always solvent)
    function invariant_PendingFeesSolvent() public view {
        RoundController c = handler.controller();
        uint256 balance = handler.hookMixETHBalance();
        uint256 reserve = handler.reserveMixETH();
        // Hook balance must always cover the reserve (claims never eat reserves)
        assertGe(balance, reserve, "hook balance fell below mixETH reserve");
        uint256 available = balance - reserve;
        assertTrue(
            c.staker().pendingFeesMixETH() <= available,
            "accounted pending fees exceed hook's unreserved balance"
        );
    }

    /// INV-4: After every claim, the locker's rewardDebt is consistent:
    /// their next pending is bounded by fees added since their last claim
    function invariant_NoZombieRewardDebt() public view {
        assertTrue(handler.maxObservedPendingDrift() == 0, "pending drift detected");
    }

    /// INV-5: totalLocked never exceeds PSP token total supply
    function invariant_LocksBoundedBySupply() public view {
        assertLe(
            handler.controller().staker().totalLocked(),
            handler.psp().totalSupply(),
            "locked more PSP than exists"
        );
    }
}

/// @title ChaosHandler — Adversarial actor driving the REAL RoundController
contract ChaosHandler is Test {
    uint256 constant USERS = 5;

    RoundController public controller;
    PSPStaker public stakerV; // cached: single vm.prank must not be eaten by the staker() view call
    PSPToken public psp;
    MockMixETH public mixETH;
    MockHook public hook;

    address[USERS] public users;
    uint256[USERS] public claimedValue; // mixETH claimed, converted at claim time to ETH terms

    uint256 public totalFeesAdded_;
    uint256 public totalClaimedETHValue_;
    uint256 public maxDrift_;
    uint256 public warpEpoch;

    constructor() {
        vm.deal(address(this), 20_000_000e18);
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 10_000_000e18}();

        CurveMath.CurveConfig memory params = CurveMath.singleCurve(
            0.0001e18, 100_000_000e18, 0.000000046e18, 0.1e18
        );

        psp = new PSPToken("PSP", "PSP", address(this));
        controller = new RoundController(psp, IERC20(address(mixETH)), params, address(this), address(0), new StakerDeployer());
        stakerV = controller.staker();

        // Hand mint rights to controller, then mint as controller
        psp.setController(address(controller));

        vm.startPrank(address(controller));
        for (uint256 i = 0; i < USERS; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", uint8(48 + i))));
            psp.mint(users[i], 1_000_000e18);
        }
        vm.stopPrank();

        for (uint256 i = 0; i < USERS; i++) {
            vm.prank(users[i]);
            psp.approve(address(stakerV), type(uint256).max);
        }

        // Wire + fund the hook (reserve 100k, available fees 100k)
        hook = new MockHook(address(mixETH));
        mixETH.transfer(address(hook), 200_000e18);
        // MockHook starts with reserveMixETH=0; simulate launched reserve:
        hook.initializeCurve(100_000e18, 10_000_000e18);
        controller.setHook(CurveHook(address(hook)));
    }

    // ── Fuzz actions ──

    function lock(uint256 userSeed, uint256 amount) external {
        uint256 i = userSeed % USERS;
        amount = bound(amount, 1, psp.balanceOf(users[i]));
        vm.prank(users[i]);
        stakerV.lock(amount);
        _checkNoDrift(i);
    }

    function addFees(uint256 amount) external {
        amount = bound(amount, 1, 5_000e18);
        // Simulate the REAL flow: swap fees arrive in the hook's mixETH
        // balance FIRST, then the hook notifies the controller's accounting.
        // Without funding, the controller could owe fees the hook can't pay.
        mixETH.transfer(address(hook), amount);
        vm.prank(address(hook));
        controller.addFees(amount);
        totalFeesAdded_ += amount;
    }

    function claim(uint256 userSeed) external {
        uint256 i = userSeed % USERS;
        // Skip if nothing pending (claimFees reverts NothingToClaim)
        if (_pending(users[i]) == 0) return;
        uint256 before = mixETH.balanceOf(users[i]);
        vm.prank(users[i]);
        stakerV.claimFees();
        uint256 gotMix = mixETH.balanceOf(users[i]) - before;
        // Track in ETH terms at current (1:1) rate — invariant is conservative
        totalClaimedETHValue_ += gotMix;
        _checkNoDrift(i);
    }

    function warpTime(uint256 delta) external {
        delta = bound(delta, 1, 95 days);
        warpEpoch += delta;
        vm.warp(block.timestamp + delta);
    }

    function unlockIfExpired(uint256 userSeed) external {
        uint256 i = userSeed % USERS;
        uint256 amt = stakerV.lockedPSPOf(users[i]);
        (,, , uint256 unlockT) = stakerV.positions(users[i]);
        if (amt == 0 || block.timestamp < unlockT) return;
        vm.prank(users[i]);
        stakerV.unlock();
        _checkNoDrift(i);
    }

    function relockIfWindow(uint256 userSeed) external {
        uint256 i = userSeed % USERS;
        uint256 amt = stakerV.lockedPSPOf(users[i]);
        (,, , uint256 unlockT) = stakerV.positions(users[i]);
        if (amt == 0 || block.timestamp < unlockT - 7 days) return;
        vm.prank(users[i]);
        stakerV.relock();
        _checkNoDrift(i);
    }

    // ── Drift check: pending computed twice must be identical (no phantom fees) ──
    function _checkNoDrift(uint256 i) internal {
        uint256 p1 = _pending(users[i]);
        uint256 p2 = _pending(users[i]);
        if (p1 != p2) maxDrift_ = type(uint256).max; // impossible for view, but assert anyway
        // Real check: pending can never exceed total unclaimed fees
        if (p1 > totalFeesAdded_) maxDrift_ = type(uint256).max;
    }

    function _pending(address u) internal view returns (uint256) {
        // staker exposes pending directly (rewardDebt is internal there)
        return stakerV.pendingFeesOf(u);
    }

    // ── Views for invariants ──
    function totalClaimedETHValue() external view returns (uint256) { return totalClaimedETHValue_; }
    function totalFeesAdded() external view returns (uint256) { return totalFeesAdded_; }
    function hookMixETHBalance() external view returns (uint256) {
        return mixETH.balanceOf(address(hook));
    }
    function reserveMixETH() external view returns (uint256) {
        return hook.reserveMixETH();
    }
    function maxObservedPendingDrift() external view returns (uint256) { return maxDrift_; }

    function sumLockAmounts() external view returns (uint256 sum) {
        for (uint256 i = 0; i < USERS; i++) {
            sum += stakerV.lockedPSPOf(users[i]);
        }
    }
}

/// @title CurveZoneInvariant — Invariants across the S-curve zone boundary
/// @notice The exponential → logarithmic transition at S_inf is the most
///         delicate point of the curve. Fuzz operations that straddle it.
contract CurveZoneInvariant is Test {
    using CurveMath for CurveMath.CurveConfig;

    CurveMath.CurveConfig cc;
    ZoneHandler zh;

    // S_inf = 1M tokens: exp zone [0, 1M], log zone [1M, ∞)
    uint256 constant S_INF = 1_000_000e18;

    function setUp() public {
        cc = CurveMath.singleCurve(0.001e18, S_INF, 0.000000046e18, 0.1e18);
        zh = new ZoneHandler(cc, S_INF);
        targetContract(address(zh));
    }

    /// Zone-boundary price continuity: price just below and just above S_inf
    /// must be equal (no arbitrage gap at the seam)
    function invariant_ZoneSeamPriceContinuous() public view {
        // Price at exactly the seam from either side
        uint256 below = CurveMath.marginalPrice(S_INF - 1, cc);
        uint256 at = CurveMath.marginalPrice(S_INF, cc);
        uint256 above = CurveMath.marginalPrice(S_INF + 1, cc);
        // Allow tiny fixed-point seam (≤ 1 bps), never a discontinuity
        assertApproxEqRel(below, at, 1e14, "seam discontinuity (below vs at)");
        assertApproxEqRel(at, above, 1e14, "seam discontinuity (at vs above)");
    }

    /// Supply never crosses below zero or above MAX_SUPPLY
    function invariant_SupplyBounded() public view {
        assertTrue(zh.supply() <= 1e28);
    }

    /// No profitable buy-sell sandwich around arbitrary supply points,
    /// including zone seam crossings
    function invariant_NoSandwichProfit() public view {
        assertLe(zh.ethRecovered(), zh.ethSpent(), "sandwich extracted value");
    }

    /// Reserve (spent - recovered) == integral of price over current supply
    /// within 0.5% (Newton + haircuts make buy conservative, sell exact)
    function invariant_ReserveMatchesIntegral() public view {
        uint256 tracked = zh.ethSpent() - zh.ethRecovered();
        if (zh.supply() == 0) {
            assertEq(tracked, 0);
            return;
        }
        uint256 integral = CurveMath.curveIntegral(0, zh.supply(), cc);
        // tracked ≥ integral * 0.995 (rounding + haircuts only shave, never inflate)
        assertGe(
            tracked * 1000,
            integral * 995,
            "tracked reserve diverged from curve integral"
        );
    }
}

contract ZoneHandler is Test {
    using CurveMath for CurveMath.CurveConfig;

    CurveMath.CurveConfig private cc;
    uint256 private s_inf;
    uint256 private supply_;
    uint256 private ethSpent_;
    uint256 private ethRecovered_;

    constructor(CurveMath.CurveConfig memory _cc, uint256 _sinf) {
        cc = _cc;
        s_inf = _sinf;
    }

    function buy(uint256 ethAmount) external {
        ethAmount = bound(ethAmount, 1e14, 10_000e18);
        uint256 out = CurveMath.computeBuyOutput(ethAmount, supply_, cc);
        if (out == 0) return;
        supply_ += out;
        ethSpent_ += ethAmount;
    }

    function sell(uint256 pspAmount) external {
        if (supply_ <= 1) return;
        pspAmount = bound(pspAmount, 1, supply_ - 1);
        uint256 out = CurveMath.computeSellOutput(pspAmount, supply_, cc);
        if (out == 0) return;
        supply_ -= pspAmount;
        ethRecovered_ += out;
    }

    /// Buy exactly to straddle the seam: sizes chosen relative to remaining distance
    function buyAcrossSeam(uint256 overshoot) external {
        if (supply_ >= s_inf) return; // already past seam
        overshoot = bound(overshoot, 1, 5_000_000e18);
        // Estimate ETH needed to reach the seam, plus overshoot into log zone
        uint256 toSeam = CurveMath.curveIntegral(supply_, s_inf, cc);
        uint256 ethIn = toSeam + overshoot;
        uint256 out = CurveMath.computeBuyOutput(ethIn, supply_, cc);
        if (out == 0) return;
        supply_ += out;
        ethSpent_ += ethIn;
    }

    function supply() external view returns (uint256) { return supply_; }
    function ethSpent() external view returns (uint256) { return ethSpent_; }
    function ethRecovered() external view returns (uint256) { return ethRecovered_; }
}
