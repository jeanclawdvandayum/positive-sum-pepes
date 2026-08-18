// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BBase, BRouter, HookProbe} from "./BBase.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {PSPToken} from "../../../src/PSPToken.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";
import {PSPFactory} from "../../../src/PSPFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, PoolKey, IHooks} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockMixETH} from "../../mocks/MockMixETH.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {console2} from "forge-std/console2.sol";

/// @title B7 — auditorB supplemental coverage: multi-zone end-to-end through
///        the real pool, deploy-gate impact of the B-3 config family, pool-init
///        spoof gates, donation semantics, quote integrity, controller-trust
///        boundary of initializeCurve, and the sell→buy round trip.
contract B7_Supplemental is BBase {
    // ── override the round's curve with a 3-zone S-shape ──
    // zone0 exp [0, 1e21) k=0.0001e18 (k*width = 0.1 WAD)
    // zone1 log [1e21, 5e21) k=0.5e18
    // zone2 flat tail [5e21, ∞)
    function _curve() internal view virtual override returns (CurveMath.CurveConfig memory) {
        uint256[] memory b = new uint256[](3);
        b[0] = 0;
        b[1] = 1e21;
        b[2] = 5e21;
        uint256[] memory r = new uint256[](3);
        r[0] = 0.0001e18;
        r[1] = 0.5e18;
        r[2] = 0;
        bool[] memory e = new bool[](3);
        e[0] = true;
        e[1] = false;
        e[2] = true;
        return CurveMath.multiCurve(0.001e18, b, r, e);
    }

    // ─────────────── B7a: B-3 config family breaks the round AT LAUNCH ───────────────
    //     The factory path enforces validate() but validate() has no P0 bound:
    //     a round whose curve is validate-legal can never launch (fail-closed,
    //     predepositors stuck until refund). Pin the deployed-round impact.
    function test_B7a_fatP0RoundDeploysButCannotLaunch() public {
        // build the B-3 failing config
        CurveMath.CurveConfig memory bad;
        bad.P0 = 1e59;
        CurveMath.Zone[] memory z = new CurveMath.Zone[](2);
        z[0] = CurveMath.Zone({startSupply: 0, endSupply: 1e25, rate: 116_225_508_139, isExponential: true});
        z[1] = CurveMath.Zone({startSupply: 1e25, endSupply: type(uint256).max, rate: 0, isExponential: true});
        bad.zones = z;

        // factory accepts it (controller constructor validate() passes)
        PSPFactory.RoundParams memory params =
            PSPFactory.RoundParams({name: "BAD", symbol: "BAD", curveConfig: bad});
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory r = factory.getRound(roundId);
        RoundController badCtl = RoundController(address(r.controller));
        CurveHook badHook = CurveHook(payable(address(r.hook)));

        // predeposit works
        vm.startPrank(alice);
        IERC20(address(mixETH)).approve(address(badCtl), 100e18);
        badCtl.predeposit(100e18);
        vm.stopPrank();

        // launch reverts: genesis computeBuyOutput overflows (MulWadFailed) or
        // returns 0 (ZeroAmount) — either way the round is stillborn
        vm.prank(address(factory));
        (bool ok, bytes memory data) =
            address(badCtl).call(abi.encodeCall(RoundController.launchPooledBuy, ()));
        assertFalse(ok, "launch must fail on the B-3 config family");
        assertTrue(
            _contains(data, hex"bac65e5b") // MulWadFailed()
                || _contains(data, abi.encodeWithSignature("ZeroAmount()")),
            "unexpected launch failure mode"
        );
        // fail-closed: curve never armed, mode never leaves Predeposit
        assertEq(uint8(badHook.mode()), uint8(CurveHook.Mode.Predeposit));
    }

    // ─────────────── B7b: multi-zone end-to-end accounting through the pool ───────────────
    function test_B7b_multiZoneAccounting() public {
        _launch(100e18); // PREDEPOSIT_CAP = 500e18; genesis still spans all zones
        uint256 S0 = hook.totalSupplyPSP();
        uint256 R0 = hook.reserveMixETH();
        assertTrue(S0 > 1e21, "genesis should reach the log zone");

        // ledger == ERC20 at genesis
        assertEq(PSPToken(address(psp)).totalSupply(), S0, "ledger != ERC20 supply");

        // buys and sells crossing zone boundaries both directions
        uint256 o1 = _buy(bob, 3_000e18); // deepens position in log zone / crosses into tail
        uint256 o2 = _buy(carol, 500e18);
        uint256 s1 = _sell(bob, o1 / 2, bob); // sell from within the log/tail zone
        uint256 s2 = _sell(carol, o2, carol);

        // invariants after each op (checked at end; per-op checked in B1/B2 fuzz)
        uint256 S1 = hook.totalSupplyPSP();
        assertEq(PSPToken(address(psp)).totalSupply(), S1, "ledger != ERC20 supply after flow");
        assertGe(hook.reserveMixETH(), R0 * 99 / 100, "reserve collapsed");
        assertLe(S1, S0 + o1 + o2, "supply grew beyond mints");
        // slack (fee ledger backing) non-negative: balance >= reserve
        assertGe(mixETH.balanceOf(address(hook)), hook.reserveMixETH(), "balance < reserve");

        // sell→buy round trip loses (complement of B1a's buy→sell)
        uint256 back = _buy(bob, s1 + s2, bob);
        assertLt(back, o1 / 2 + o2, "sell-then-buy round trip gained PSP");

        // quote integrity: views match execution
        uint256 q = hook.getBuyOutput(1e18);
        uint256 before = hook.totalSupplyPSP();
        uint256 got = _buy(carol, 1e18);
        assertEq(got, q, "getBuyOutput != executed buy (multi-zone)");
        assertEq(hook.totalSupplyPSP() - before, got);
    }

    // ─────────────── B7c: price continuity at zone boundaries (library views) ───────────────
    function test_B7c_zoneBoundaryPriceContinuous() public view {
        CurveMath.CurveConfig memory c = _curve();
        // at S = 1e21 (zone0 exp end == zone1 log start) price must be equal
        uint256 pBelow = CurveMath.marginalPrice(1e21 - 1, c);
        uint256 pAt = CurveMath.marginalPrice(1e21, c);
        uint256 pAbove = CurveMath.marginalPrice(1e21 + 1, c);
        assertApproxEqRel(pBelow, pAt, 1e15, "price jump at zone boundary (low)");
        assertApproxEqRel(pAt, pAbove, 1e15, "price jump at zone boundary (high)");
        // and at 5e21 (log→flat)
        assertApproxEqRel(CurveMath.marginalPrice(5e21 - 1, c), CurveMath.marginalPrice(5e21, c), 1e15);
        // through the real hook: views agree with the library at current supply
        // (genesis has not run; marginal price at S=0 is P0)
        assertEq(hook.getMarginalPrice(), CurveMath.marginalPrice(0, c), "hook view != library at S=0");
    }

    // ─────────────── B7d: spoofed pool initialization is gated ───────────────
    function test_B7d_poolInitGates() public {
        // wrong fee tier (the PM wraps the hook's revert in WrappedError)
        PoolKey memory kFee = key;
        kFee.fee = 3000;
        (bool ok1, bytes memory d1) =
            address(poolManager).call(abi.encodeCall(IPoolManager.initialize, (kFee, 79228162514264337593543950336)));
        assertFalse(ok1, "wrong fee must be rejected");
        assertTrue(_contains(d1, abi.encodeWithSelector(CurveHook.WrongPoolParams.selector)), "wrong error: fee");

        // wrong tick spacing
        PoolKey memory kTick = key;
        kTick.tickSpacing = 10;
        (bool ok2, bytes memory d2) =
            address(poolManager).call(abi.encodeCall(IPoolManager.initialize, (kTick, 79228162514264337593543950336)));
        assertFalse(ok2, "wrong tickSpacing must be rejected");
        assertTrue(_contains(d2, abi.encodeWithSelector(CurveHook.WrongPoolParams.selector)), "wrong error: tickSpacing");

        // foreign currency pair (mixETH + attacker token)
        MockMixETH foreign = new MockMixETH();
        PoolKey memory kCur = PoolKey({
            currency0: key.currency0,
            currency1: Currency.wrap(address(foreign)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        (bool ok3, bytes memory d3) =
            address(poolManager).call(abi.encodeCall(IPoolManager.initialize, (kCur, 79228162514264337593543950336)));
        assertFalse(ok3, "foreign currencies must be rejected");
        assertTrue(_contains(d3, abi.encodeWithSelector(CurveHook.WrongPoolCurrencies.selector)), "wrong error: currencies");
    }

    // ─────────────── B7e: donation semantics on the hook ───────────────
    function test_B7e_donations() public {
        _launch(100e18);
        _buy(bob, 10e18); // accrue some real fees
        uint256 feesBefore = mixETH.balanceOf(address(hook)) - hook.reserveMixETH();

        // (i) mixETH donated directly to the hook lands in the SWEEPABLE ledger
        //     (becomes staker fees), not in the reserve: no dilution/backing change
        uint256 reserveBeforeDonation = hook.reserveMixETH();
        vm.prank(carol);
        mixETH.transfer(address(hook), 5e18);
        assertEq(hook.reserveMixETH(), reserveBeforeDonation, "donation moved the reserve");
        uint256 ledger = mixETH.balanceOf(address(hook)) - hook.reserveMixETH();
        assertGe(ledger, feesBefore + 5e18, "donation not credited to sweepable ledger");
        // controller can sweep it
        vm.prank(address(controller));
        hook.sendFees(alice, ledger);
        assertEq(mixETH.balanceOf(address(hook)), hook.reserveMixETH(), "sweep left dust");

        // (ii) PSP donated to the hook is STUCK: swaps never touch a pre-existing
        //      PSP balance (burn + pot cut always come from the taken input)
        uint256 pspOut = _buy(carol, 2e18);
        vm.prank(carol);
        psp.transfer(address(hook), pspOut);
        uint256 hookPSP = psp.balanceOf(address(hook));
        _buy(bob, 1e18); // unrelated swaps must not absorb it
        _sell(bob, 1e18, bob); // sells must not burn it
        assertGe(psp.balanceOf(address(hook)), hookPSP, "donated PSP was consumed");
        // Reconcile ERC20 supply vs the hook ledger exactly: the only gaps are
        // the donated PSP sitting at the hook and the controller's PHANTOM pot
        // credit (ledger counts pot PSP that was never ERC20-minted at genesis).
        //   phantom = potPSPBalance − (psp at controller − totalLocked)
        uint256 realPot = psp.balanceOf(address(controller)) - controller.totalLocked();
        uint256 phantom = controller.potPSPBalance() - realPot;
        assertEq(
            PSPToken(address(psp)).totalSupply(),
            hook.totalSupplyPSP() + hookPSP - phantom,
            "ERC20 == ledger + donated - phantomPot"
        );
        // INFO: no recovery path exists for the donated PSP — it is locked
    }

    // ─────────────── B7f: initializeCurve trusts the controller blindly ───────────────
    //     No cross-check vs PSP.totalSupply() or the hook's actual mixETH
    //     balance. A wrong (or malicious) controller arms nonsense state the
    //     hook happily prices against. Trust-boundary pin (not exploitable by
    //     non-controller actors).
    function test_B7f_initializeCurveBlindTrust() public {
        // fresh un-launched round in Predeposit
        vm.prank(address(controller));
        hook.initializeCurve(1e18, 12345); // nonsense: ERC20 supply is still 0
        assertEq(hook.totalSupplyPSP(), 12345);
        assertEq(hook.reserveMixETH(), 1e18);
        assertEq(PSPToken(address(psp)).totalSupply(), 0, "ERC20 supply disagrees with ledger");
        // no revert, no sanity check — controller must be correct
        vm.prank(address(controller));
        hook.setMode(CurveHook.Mode.Active);
        // pro-rata flat math operates on the fiction if flattened
        vm.prank(address(controller));
        hook.setMode(CurveHook.Mode.Flat);
        uint256 q = hook.getFlatPrice(); // 1e18 * 1e18 / 12345
        assertTrue(q > 0);
    }

    // ─────────────── B7g: exact-out rejection is uniform (both directions) ───────────────
    function test_B7g_exactOutRejectedBothDirections() public {
        _launch(100e18);
        EOAmount eo = new EOAmount(poolManager, address(mixETH));
        // exact-out BUY (positive amountSpecified, zeroForOne = mix→psp)
        (bool okB, bytes memory retB) = address(eo).call(
            abi.encodeCall(EOAmount.swapEO, (key, int256(1e18), true))
        );
        assertFalse(okB, "exact-out BUY must be rejected");
        assertTrue(_contains(retB, abi.encodeWithSignature("Error(string)", "ExactOutNotSupported")), "wrong error (buy)");
        // exact-out SELL (positive amountSpecified, psp→mix)
        (bool okS, bytes memory retS) = address(eo).call(
            abi.encodeCall(EOAmount.swapEO, (key, int256(1e18), false))
        );
        assertFalse(okS, "exact-out SELL must be rejected");
        assertTrue(_contains(retS, abi.encodeWithSignature("Error(string)", "ExactOutNotSupported")), "wrong error (sell)");
    }
}

/// @dev minimal router driving poolManager.swap with an EXACT-OUT (positive)
///      amountSpecified through a real unlock, either direction.
contract EOAmount {
    IPoolManager public immutable pm;
    address public immutable mix;

    constructor(IPoolManager _pm, address _mix) {
        pm = _pm;
        mix = _mix;
    }

    function swapEO(PoolKey calldata key, int256 amt, bool asBuy) external returns (uint256) {
        pm.unlock(abi.encode(key, amt, asBuy));
        return 0;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, int256 amt, bool asBuy) = abi.decode(data, (PoolKey, int256, bool));
        bool mixIsZero = Currency.unwrap(key.currency0) == mix;
        // buy = mix→psp; zeroForOne must reflect the actual currency ordering
        pm.swap(
            key,
            SwapParams({
                amountSpecified: amt, // positive == exact-out
                sqrtPriceLimitX96: 0,
                zeroForOne: asBuy ? mixIsZero : !mixIsZero
            }),
            hex""
        );
        return "";
    }
}
