// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PSPFactory} from "../../src/PSPFactory.sol";
import {PSPToken} from "../../src/PSPToken.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

/// @title NK24 — post-remediation proof suite (mainnet fork, real V4 PM).
/// @notice Every test here is a pre-fix attack, re-run against the fixed
///         contracts to prove the vector is dead:
///
///         P1. Rate-drop round trip (short put)     -> fee-only loss, reserve intact
///         P2. Catastrophic rate markdown           -> no brick, sells keep working
///         P3. Rate-rise round trip                 -> symmetric fee-only loss
///         P4. First-claim solo fee window          -> genesis virtual lock, pro-rata from launch tx
///         P5. Thin-lock carpet bomb                -> quorum floored at total PSP supply
///         P6. Decoy pool on the same hook          -> canonical fee/tickSpacing enforced
///         P7. Guard battery (unchanged, must hold)
///
///         Attacker model: no admin privileges. HostileMixETH.setRate()
///         models the vault marking totalAssets down/up — outside an
///         attacker's direct control, blast radius quantified anyway.
contract NK24Test is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;

    IPoolManager constant poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    HostileMixETH mixETH;
    PSPFactory factory;

    struct R {
        PSPToken token;
        RoundController controller;
        CurveHook hook;
        PoolKey key;
    }

    R r;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        mixETH = new HostileMixETH();
        mixETH.deposit{value: 2_000_000e18}();
        factory = new PSPFactory(poolManager, mixETH);
        mixETH.transfer(alice, 50_000e18);
        mixETH.transfer(bob, 50_000e18);
        mixETH.transfer(carol, 50_000e18);
        mixETH.transfer(attacker, 50_000e18);
        r = _deployRound();
        _launch(r, alice, 100e18);
    }

    // ── harness ────────────────────────────────────────────────────────

    function _curveConfig() internal pure returns (CurveMath.CurveConfig memory) {
        return CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);
    }

    function _deployRound() internal returns (R memory ctx) {
        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: _curveConfig()
        });
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory rr = factory.getRound(roundId);
        ctx.token = rr.token;
        ctx.controller = rr.controller;
        ctx.hook = rr.hook;
        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(address(rr.token));
        if (c0 > c1) (c0, c1) = (c1, c0);
        ctx.key = PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: rr.hook});
    }

    function _launch(R memory ctx, address who, uint256 amount) internal {
        vm.startPrank(who);
        mixETH.approve(address(ctx.controller), amount);
        ctx.controller.predeposit(amount);
        vm.stopPrank();
        vm.prank(address(factory));
        ctx.controller.launchPooledBuy();
        vm.prank(who);
        ctx.controller.claimPredepositPSP();
        skip(1); // M-1: lockTime must predate proposals
    }

    function _buy(R memory ctx, address who, uint256 mixAmount) internal {
        vm.prank(who);
        mixETH.approve(address(this), mixAmount);
        bool z41 = Currency.wrap(address(mixETH)) == ctx.key.currency0;
        poolManager.unlock(abi.encode(who, address(mixETH), mixAmount, ctx.key, z41));
    }

    function _sell(R memory ctx, address who, uint256 pspAmount) internal {
        vm.prank(who);
        ctx.token.approve(address(this), pspAmount);
        bool z41 = Currency.wrap(address(mixETH)) == ctx.key.currency0;
        poolManager.unlock(abi.encode(who, address(ctx.token), pspAmount, ctx.key, !z41));
    }

    // router callback: pre-settle input, swap, take output
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not PM");
        (address user, address tokenIn, uint256 amount, PoolKey memory key, bool zeroForOne) =
            abi.decode(data, (address, address, uint256, PoolKey, bool));

        SwapParams memory sp = SwapParams({
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne
                ? 4295128740
                : 1461446703485210103287273052203988822378723970341,
            zeroForOne: zeroForOne
        });

        Currency inCur = Currency.wrap(tokenIn);
        poolManager.sync(inCur);
        SafeERC20.safeTransferFrom(IERC20(tokenIn), user, address(poolManager), amount);
        poolManager.settle();

        BalanceDelta delta = poolManager.swap(key, sp, "");
        if (delta.amount0() > 0) poolManager.take(key.currency0, user, uint256(int256(delta.amount0())));
        if (delta.amount1() > 0) poolManager.take(key.currency1, user, uint256(int256(delta.amount1())));
        return "";
    }

    // ═══════════════════════════════════════════════════════════════
    //  P1: mixETH-native settlement kills the rate-drop short put.
    //  Pre-fix: buy at R=1, vault marks down 10%, sell converts the ETH
    //  integral back at the live rate -> attacker extracts the yield
    //  delta, predepositors' backing drains. Post-fix: the curve
    //  integral is computed natively in mixETH on both legs; the 4626
    //  rate is never read in settlement. A rate move changes nothing
    //  about the round trip — the attacker pays fees and walks away
    //  down. Vault losses now accrue pro-rata to ALL PSP holders (the
    //  intended semantics), never to a directional extractor.
    // ═══════════════════════════════════════════════════════════════

    function test_P1_RateDropRoundTrip_FeeOnlyLoss() public {
        uint256 bobBefore = mixETH.balanceOf(bob);
        _buy(r, bob, 10e18);

        // Vault marks down 10% (organic loss / adapter read-down)
        mixETH.setRate(0.9e18);

        uint256 bobPSP = r.token.balanceOf(bob);
        _sell(r, bob, bobPSP);

        uint256 bobAfter = mixETH.balanceOf(bob);
        // THE KILL: round trip is strictly loss-making — fees only
        assertLt(bobAfter, bobBefore, "rate-drop round trip must NOT be profitable");
        uint256 loss = bobBefore - bobAfter;
        // bounded: two 5% fee legs on 10e18 (~0.975e18) — no rate delta inside
        assertLt(loss, 1.5e18, "loss must be fee-scale, not rate-scale (10% = 1e18+)");
        emit log_named_decimal_uint("bob loss (mixETH wei)", loss, 18);

        // alice's backing (in mixETH, the unit of account) is intact
        uint256 reserve = r.hook.reserveMixETH();
        assertGe(reserve, 100e18, "predecessor principal drained by rate-drop round trip");
        emit log_named_decimal_uint("reserve after (mixETH wei)", reserve, 18);
    }

    // ═══════════════════════════════════════════════════════════════
    //  P2: catastrophic markdown no longer bricks the pool.
    //  Pre-fix: -95% rate made mixETH-owed exceed reserve -> every sell
    //  panicked (underflow), PSP frozen, carpet bomb the only exit.
    //  Post-fix: no rate in settlement -> sells keep settling at the
    //  mixETH integral. The vault loss is shared pro-rata via the
    //  mixETH unit of account (1 mixETH redeems for less ETH — for
    //  everyone equally), never via a settlement panic.
    // ═══════════════════════════════════════════════════════════════

    function test_P2_CatastrophicMarkdown_SellsKeepWorking() public {
        uint256 bobBefore = mixETH.balanceOf(bob);
        _buy(r, bob, 10e18);
        mixETH.setRate(0.05e18); // -95%

        uint256 bobPSP = r.token.balanceOf(bob);
        // pre-fix: panic 0x11 wrapped through V4 unlock. post-fix: settles.
        _sell(r, bob, bobPSP);

        uint256 bobAfter = mixETH.balanceOf(bob);
        assertLt(bobAfter, bobBefore, "round trip still loss-making");
        assertLt(bobBefore - bobAfter, 1.5e18, "loss fee-scale only");
        assertGe(r.hook.reserveMixETH(), 100e18, "reserve solvent after -95% markdown");
        emit log_named_decimal_uint("reserve after -95% (mixETH)", r.hook.reserveMixETH(), 18);

        // and a SECOND round trip also works — pool is not one-shot
        uint256 bob2 = mixETH.balanceOf(bob);
        _buy(r, bob, 5e18);
        _sell(r, bob, r.token.balanceOf(bob));
        assertLt(mixETH.balanceOf(bob), bob2, "second round trip also loss-making");
    }

    // ═══════════════════════════════════════════════════════════════
    //  P3: rate-rise symmetry. Pre-fix the trader ate the rate delta
    //  on the upside (asymmetric put). Post-fix: drop and rise are the
    //  SAME fee-only loss — there is no direction to trade.
    // ═══════════════════════════════════════════════════════════════

    function test_P3_RateRiseSymmetric_FeeOnlyLoss() public {
        uint256 carolBefore = mixETH.balanceOf(carol);
        _buy(r, carol, 10e18);
        mixETH.setRate(1.1e18); // +10%
        _sell(r, carol, r.token.balanceOf(carol));

        uint256 carolAfter = mixETH.balanceOf(carol);
        assertLt(carolAfter, carolBefore, "rate-rise round trip loses (fees only)");
        assertLt(carolBefore - carolAfter, 1.5e18, "loss fee-scale, not rate-scale");
        assertGe(r.hook.reserveMixETH(), 100e18, "reserve intact");
        emit log_named_decimal_uint("carol loss (mixETH wei)", carolBefore - carolAfter, 18);
    }

    // ═══════════════════════════════════════════════════════════════
    //  P4: genesis virtual lock. Pre-fix: predeposit claims were lazy,
    //  so between launch and each claim the FIRST claimer was the sole
    //  locker and captured ~100% of the early fee stream. Post-fix: the
    //  controller itself locks all initial PSP inside launchPooledBuy —
    //  fees accrue pro-rata to every predepositor from the very first
    //  post-launch trade, regardless of when they claim.
    // ═══════════════════════════════════════════════════════════════

    function test_P4_GenesisFeesAccrueProRataBeforeAnyClaim() public {
        // fresh round, TWO predepositors: alice 60e18, carol 40e18
        R memory ctx = _deployRound();
        vm.startPrank(alice);
        mixETH.approve(address(ctx.controller), 60e18);
        ctx.controller.predeposit(60e18);
        vm.stopPrank();
        vm.startPrank(carol);
        mixETH.approve(address(ctx.controller), 40e18);
        ctx.controller.predeposit(40e18);
        vm.stopPrank();
        vm.prank(address(factory));
        ctx.controller.launchPooledBuy();
        skip(1);

        // NOBODY has claimed. bob trades 100e18 -> ~5e18 of fees while the
        // virtual lock is the only locker.
        _buy(ctx, bob, 100e18);

        // now both claim — each must find their pro-rata share accrued.
        // pre-fix: whoever claimed first took ~the whole 5e18.
        uint256 aliceBefore = mixETH.balanceOf(alice);
        vm.prank(alice);
        ctx.controller.claimPredepositPSP();
        uint256 aliceFees = mixETH.balanceOf(alice) - aliceBefore;

        uint256 carolBefore = mixETH.balanceOf(carol);
        vm.prank(carol);
        ctx.controller.claimPredepositPSP();
        uint256 carolFees = mixETH.balanceOf(carol) - carolBefore;

        // 60/40 split of the ~5e18 stream — no winner-take-all
        assertGt(aliceFees, 2.7e18, "alice (60% depositor) accrued her share");
        assertGt(carolFees, 1.7e18, "carol (40% depositor) accrued her share");
        assertApproxEqAbs(aliceFees + carolFees, 5e18, 0.1e18, "full fee stream distributed");
        emit log_named_decimal_uint("alice accrued pre-claim", aliceFees, 18);
        emit log_named_decimal_uint("carol accrued pre-claim", carolFees, 18);
    }

    // ═══════════════════════════════════════════════════════════════
    //  P5: thin-lock bomb. Pre-fix: after lock exodus totalLocked -> 0,
    //  a dust buyer locked the minimum, held 100% of locked supply and
    //  bombed the whole reserve with a near-zero stake. Post-fix:
    //  quorum denominator = max(totalLocked, totalSupplyPSP) — the
    //  attacker must lock 69% of EVERYTHING outstanding.
    // ═══════════════════════════════════════════════════════════════

    function test_P5_ThinLockBombBlocked_HonestBombStillWorks() public {
        skip(91 days);
        vm.prank(alice);
        r.controller.unlock(); // totalLocked -> 0, PSP back to alice

        // attacker buys dust and locks it: 100% of LOCKED, ~1% of SUPPLY
        _buy(r, attacker, 1e18);
        vm.startPrank(attacker);
        r.token.approve(address(r.controller), type(uint256).max);
        r.controller.lock(r.token.balanceOf(attacker));
        vm.stopPrank();
        skip(1);

        vm.prank(attacker);
        r.controller.proposeCarpetBomb();
        vm.prank(attacker);
        r.controller.voteCarpetBomb(true);
        skip(3 days + 1);

        // THE KILL: dust lock cannot clear the supply-floored quorum
        vm.expectRevert();
        r.controller.carpetBomb();
        assertEq(uint8(r.hook.mode()), uint8(CurveHook.Mode.Active), "round must survive");

        // honest path intact: the failed proposal expires, alice (the real
        // holder) locks her bag, proposes, votes, executes.
        vm.startPrank(alice);
        r.token.approve(address(r.controller), type(uint256).max);
        r.controller.lock(r.token.balanceOf(alice));
        vm.stopPrank();
        skip(1);
        vm.prank(alice);
        r.controller.proposeCarpetBomb();
        vm.prank(alice);
        r.controller.voteCarpetBomb(true);
        skip(3 days + 1);
        r.controller.carpetBomb();

        assertEq(uint8(r.hook.mode()), uint8(CurveHook.Mode.Destroyed), "honest bomb executes");
        assertGt(mixETH.balanceOf(address(factory)), 100e18, "funds recovered to factory");
        emit log_named_decimal_uint("factory recovery (mixETH)", mixETH.balanceOf(address(factory)), 18);
    }

    // ═══════════════════════════════════════════════════════════════
    //  P6: decoy pool. Pre-fix: beforeInitialize only checked
    //  currencies — anyone could initialize extra pools (different
    //  fee/tickSpacing) keyed to the same hook state. Post-fix: the
    //  canonical fee (0x800000) and tickSpacing (60) are enforced.
    // ═══════════════════════════════════════════════════════════════

    function test_P6_DecoyPoolRejected() public {
        PoolKey memory decoy = PoolKey({
            currency0: r.key.currency0,
            currency1: r.key.currency1,
            fee: 3000, // NOT the canonical dynamic-fee flag
            tickSpacing: 10,
            hooks: r.hook
        });
        // V4 wraps hook reverts in WrappedError(target, selector, reason,
        // details) — unwrap and assert the inner error precisely.
        try poolManager.initialize(decoy, 79228162514264337593543950336) {
            revert("decoy initialized: WrongPoolParams gate broken");
        } catch (bytes memory err) {
            assertEq(bytes4(err), bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)")), "V4 wrap");
            // abi.decode rejects memory slices — copy the payload out first
            bytes memory wrapped = new bytes(err.length - 4);
            for (uint256 i = 0; i < wrapped.length; ++i) {
                wrapped[i] = err[i + 4];
            }
            (address target,, bytes memory reason,) =
                abi.decode(wrapped, (address, bytes4, bytes, bytes));
            assertEq(target, address(r.hook), "wrapped error blames the hook");
            assertEq(bytes4(reason), CurveHook.WrongPoolParams.selector, "inner error = WrongPoolParams");
        }

        // and the canonical params still initialize fine (fresh pair)
        PoolKey memory canonical = PoolKey({
            currency0: r.key.currency0,
            currency1: r.key.currency1,
            fee: 0x800000,
            tickSpacing: 60,
            hooks: r.hook
        });
        // already initialized in setUp — re-init reverts with V4's own
        // CurrencyAlreadyInitialized, proving the canonical pool exists
        vm.expectRevert();
        poolManager.initialize(canonical, 79228162514264337593543950336);
    }

    // ═══════════════════════════════════════════════════════════════
    //  P8: post-bomb claim. The bomb drains the hook to the factory, so
    //  unclaimed predepositors' accrued fees are forfeited (M-2: a fee
    //  leg must never block principal) — but their PSP PRINCIPAL must
    //  still be claimable from the genesis lock after destruction.
    // ═══════════════════════════════════════════════════════════════

    function test_P8_PostBombClaimStillReturnsPrincipal() public {
        // fresh round: alice 50, bob 30, carol 20 (carol will NEVER claim
        // before the bomb). alice+bob claim+lock+vote = 80% > 69% quorum.
        R memory ctx = _deployRound();
        vm.startPrank(alice);
        mixETH.approve(address(ctx.controller), 50e18);
        ctx.controller.predeposit(50e18);
        vm.stopPrank();
        vm.startPrank(bob);
        mixETH.approve(address(ctx.controller), 30e18);
        ctx.controller.predeposit(30e18);
        vm.stopPrank();
        vm.startPrank(carol);
        mixETH.approve(address(ctx.controller), 20e18);
        ctx.controller.predeposit(20e18);
        vm.stopPrank();
        vm.prank(address(factory));
        ctx.controller.launchPooledBuy();
        skip(1);

        vm.prank(alice);
        ctx.controller.claimPredepositPSP();
        vm.prank(bob);
        ctx.controller.claimPredepositPSP();
        // carol deliberately does NOT claim

        skip(1); // M-1: claimers' lockTime must predate the proposal

        vm.prank(alice);
        ctx.controller.proposeCarpetBomb();
        vm.prank(alice);
        ctx.controller.voteCarpetBomb(true);
        vm.prank(bob);
        ctx.controller.voteCarpetBomb(true);
        skip(3 days + 1);
        ctx.controller.carpetBomb();
        assertEq(uint8(ctx.hook.mode()), uint8(CurveHook.Mode.Destroyed), "round destroyed");

        // late claim: PSP principal moves out of the genesis lock even
        // though the hook (and its fee surplus) is fully drained
        (uint256 genesisBefore,,,) = ctx.controller.locks(address(ctx.controller));
        assertGt(genesisBefore, 0, "carol's share still in genesis lock");
        vm.prank(carol);
        ctx.controller.claimPredepositPSP();
        (uint256 carolLock,,,) = ctx.controller.locks(carol);
        assertGt(carolLock, 0, "principal claimable post-bomb");
        (uint256 genesisAfter,,,) = ctx.controller.locks(address(ctx.controller));
        assertEq(genesisAfter, genesisBefore - carolLock, "genesis lock decremented exactly");
    }

    // ═══════════════════════════════════════════════════════════════
    //  P9: mid-vote claim disenfranchisement. A claim during a live
    //  proposal sets lockTime = now >= proposeTime, so the claimer
    //  cannot vote on that proposal (M-1). Her shares also never voted
    //  pre-claim (they sat in the genesis lock, which cannot vote).
    //  Claiming mid-vote therefore adds ZERO new voting power — the
    //  quorum snapshot cannot be inflated through the claim path.
    // ═══════════════════════════════════════════════════════════════

    function test_P9_MidVoteClaimAddsNoVotingPower() public {
        // fresh round: alice predeposits, launches, does NOT claim.
        R memory ctx = _deployRound();
        vm.startPrank(alice);
        mixETH.approve(address(ctx.controller), 100e18);
        ctx.controller.predeposit(100e18);
        vm.stopPrank();
        vm.prank(address(factory));
        ctx.controller.launchPooledBuy();
        skip(1);

        // bob buys on the curve, locks, proposes
        _buy(ctx, bob, 10e18);
        vm.startPrank(bob);
        ctx.token.approve(address(ctx.controller), type(uint256).max);
        ctx.controller.lock(ctx.token.balanceOf(bob));
        vm.stopPrank();
        skip(1);
        vm.prank(bob);
        ctx.controller.proposeCarpetBomb();

        // alice claims mid-vote: her share leaves the genesis lock (which
        // cannot vote) and enters her own lock with lockTime = NOW
        vm.prank(alice);
        ctx.controller.claimPredepositPSP();
        (uint256 aliceLock,,,) = ctx.controller.locks(alice);
        assertGt(aliceLock, 0, "alice holds a lock");

        // she cannot vote on the live proposal: lockTime >= proposeTime
        vm.prank(alice);
        vm.expectRevert();
        ctx.controller.voteCarpetBomb(true);
    }

    // ═══════════════════════════════════════════════════════════════
    //  P10: pre-launch governance. Before launchPooledBuy there are no
    //  locks at all (the genesis lock is created inside launch), so
    //  propose is unreachable — no zero-quorum bomb on an unborn round.
    // ═══════════════════════════════════════════════════════════════

    function test_P10_PreLaunchProposeRejected() public {
        R memory ctx = _deployRound();
        vm.prank(attacker);
        vm.expectRevert();
        ctx.controller.proposeCarpetBomb();
    }

    // ═══════════════════════════════════════════════════════════════
    //  P7: guard battery (unchanged behavior, must still hold)
    // ═══════════════════════════════════════════════════════════════

    function test_P7_GuardBattery() public {
        _buy(r, bob, 1e18);
        bool z41 = Currency.wrap(address(mixETH)) == r.key.currency0;

        // undersized buy (< MIN_SWAP_INPUT = 1e12)
        vm.prank(bob);
        mixETH.approve(address(this), 1e11);
        vm.expectRevert();
        poolManager.unlock(abi.encode(bob, address(mixETH), 1e11, r.key, z41));

        // undersized sell
        vm.prank(bob);
        r.token.approve(address(this), 1e11);
        vm.expectRevert();
        poolManager.unlock(abi.encode(bob, address(r.token), 1e11, r.key, !z41));

        // oversell: sell the entire supply
        uint256 total = r.hook.totalSupplyPSP();
        vm.prank(bob);
        r.token.approve(address(this), total);
        vm.expectRevert();
        poolManager.unlock(abi.encode(bob, address(r.token), total, r.key, !z41));
    }
}

/// @dev ERC-4626-shaped mock whose totalAssets can move DOWN (the real
///      MockMixETH only allows monotonic yield-up). Models vault markdown.
contract HostileMixETH is ERC20 {
    uint256 public rate = 1e18; // ETH per share (WAD)

    constructor() ERC20("Hostile mixETH", "hMIX") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value * 1e18 / rate);
    }

    function totalAssets() external view returns (uint256) {
        return totalSupply() * rate / 1e18;
    }

    /// @dev adversarial knob — simulates the underlying vault marking down
    function setRate(uint256 newRate) external {
        rate = newRate;
    }
}
