// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BBase, BRouter, HookProbe} from "./BBase.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @title B1 — curve-mode pricing symmetry, round-trip extraction, solvency slack,
///        fee-ledger exactness. REAL PoolManager.
contract B1_CurveRoundTrip is BBase {
    // ── happy path on real PM: full netting, exact accounting ──
    function test_B1a_honestBuyThenSell_nettsAndBalancesHold() public {
        _launch(100e18);

        uint256 aliceMixBefore = mixETH.balanceOf(alice);
        uint256 S0 = hook.totalSupplyPSP();
        uint256 amt = 10e18;

        // exact expected output via the hook's own view (user slice = 95% of input)
        uint256 expOut = CurveMath.computeBuyOutput(amt - (amt * 500) / 10000, S0, _cfg());
        uint256 pspOut = _buy(alice, amt);

        assertEq(pspOut, expOut, "psp out != curve(user slice)");
        assertEq(psp.balanceOf(alice), pspOut, "psp not delivered");
        assertEq(mixETH.balanceOf(alice), aliceMixBefore - amt, "mix not debited exactly");
        assertEq(
            hook.reserveMixETH() + _feeLedger(), mixETH.balanceOf(address(hook)), "hook balance split broken"
        );
        assertGe(_slack(), 0, "curve solvency violated after buy");

        // exact expected sell: integral over her segment, user keeps 95%
        uint256 expIntegral = CurveMath.computeSellOutput(pspOut, hook.totalSupplyPSP(), _cfg());
        uint256 mixBack = _sell(alice, pspOut);
        assertEq(mixBack, expIntegral - (expIntegral * 500) / 10000, "sell != 95% of integral");

        assertLe(mixBack, (amt * 9500) / 10000, "sell returned more than buy slice");
        assertLt(mixBack, (amt * 9100) / 10000, "round trip must lose >9%");
        assertGe(_slack(), 0, "curve solvency violated after sell");
        assertEq(psp.balanceOf(alice), 0, "psp not fully spent");
    }

    // ── buy haircut conservativeness at library level (deployed config) ──
    function test_B1b_buyOutputAlwaysIntegralBounded_fuzz(uint128 input, uint128 supply) public view {
        vm.assume(input >= 1e12);
        vm.assume(supply <= 1e27);
        CurveMath.CurveConfig memory c = _cfg();
        uint256 out = CurveMath.computeBuyOutput(input, supply, c);
        if (out == 0) return;
        assertLe(
            CurveMath.curveIntegral(supply, supply + out, c), input, "buy minted more than integral-bounded"
        );
    }

    // ── Fuzz: random interleaved buys/sells keep R >= ∫ and balance >= reserve ──
    int256 minSlackSeen;

    function test_B1c_solvencyUnderRandomFlow_fuzz(uint64 seed) public {
        _launch(100e18);

        uint256 alicePsp;
        for (uint8 i = 0; i < 6; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bool doBuy = (r & 1) == 0 || alicePsp < 2e15;
            if (doBuy) {
                uint256 amt = bound(r, 1e15, 100e18);
                alicePsp += _buy(alice, amt);
            } else {
                uint256 amt = bound(r, 1e15, alicePsp);
                _sell(alice, amt);
                alicePsp -= amt;
            }
            int256 s = _slack();
            if (s < minSlackSeen) minSlackSeen = s;
            assertGe(s, 0, "solvency slack went negative");
            assertGe(mixETH.balanceOf(address(hook)), hook.reserveMixETH(), "balance < reserve");
        }
    }

    // ── interleaved: bob pumps between alice's buy and sell ──
    function test_B1d_interleavedRoundTripBoundedByTopSegment() public {
        _launch(100e18);
        uint256 psp1 = _buy(alice, 10e18);
        _buy(bob, 50e18); // price pushed up

        // alice now sells the TOP segment [S-psp1, S] — priced above her buy slice
        uint256 S = hook.totalSupplyPSP();
        uint256 expIntegral = CurveMath.computeSellOutput(psp1, S, _cfg());
        uint256 mixBack = _sell(alice, psp1);
        assertEq(mixBack, expIntegral - (expIntegral * 500) / 10000, "sell != 95% of top-segment integral");
        // extraction bound: she cannot get back more than 95% of the CURRENT value of
        // her slice. The near-flat production shape means bob's pump barely raises
        // the top segment above her entry — the correct lower bound is her own
        // fee-adjusted input (buy haircut ≤2bps + 5% sell fee), not 95% of input:
        // mixBack ≥ 10e18 * 0.95 * 0.9998 * 0.95 ≈ 9.0231e18
        assertGt(mixBack, 9.0231e18, "round trip below fee-adjusted recovery");
        // NOTE: curve-mode sell fees are FLOORED ((out*500)/10000), so the user
        // keeps the sub-wei dust: mixBack >= ceil(95% of integral). Pin with the
        // ceiled bound (flat-mode sells ceiling their fees — see B2a — this
        // asymmetry is recorded as an INFO finding in the report).
        assertGe(mixBack, (expIntegral * 9500) / 10000, "sell below 95% of integral");
        assertLe(mixBack, (expIntegral * 9500 + 9999) / 10000, "exceeded top-segment bound");
        assertGe(_slack(), 0, "solvency broken");
    }

    // ── fee ledger exactness after buys + sells ──
    function test_B1e_feeLedgerExact() public {
        _launch(100e18);

        uint256 expectedFees = 0;
        uint256[3] memory amounts = [uint256(1e18), 7.3e18, 2e15];
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amt2 = amounts[i];
            _buy(bob, amt2);
            // buy (unattributed, v5.1): referral budget (50bps of volume) has
            // no chain to pay -> falls through to stakers = FULL 5% of volume
            expectedFees += (amt2 * 500) / 10000;
        }

        // one sell of half his balance
        uint256 pspBal = psp.balanceOf(bob);
        uint256 pspIn = pspBal / 2;
        uint256 integral = hook.getSellOutput(pspIn);
        _sell(bob, pspIn);
        expectedFees += (integral * 500) / 10000;

        assertEq(_feeLedger(), expectedFees, "fee ledger mismatch");
    }

    // ── supply can never be fully sold ──
    function test_B1f_cannotSellEntireSupply() public {
        _launch(100e18);
        uint256 pspOut = _buy(alice, 10e18);
        uint256 S = hook.totalSupplyPSP();
        vm.startPrank(alice);
        // settleMode NONE: alice doesn't hold S PSP (the pot does), so a pull
        // would fail on her balance before the hook's own guard fires. The
        // hook checks SellExceedsSupply BEFORE any take/settle, so the unpaid
        // input never matters — the revert reason is the guard itself.
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = BRouter.Call({isBuy: false, amount: S, settleMode: 1, takeMode: 0});
        // The hook PM-gates beforeSwap (NotPoolManager on direct calls — pinned
        // in B3n), so pin the exact reason via revert-data containment through
        // the real PM: WrappedError(hook, beforeSwap, SellExceedsSupply, ...)
        // (call made as alice so the router's pre-pull succeeds)
        (bool ok, bytes memory data) =
            address(router).call(abi.encodeCall(BRouter.execute, (key, calls, alice)));
        vm.stopPrank();
        assertFalse(ok, "full-supply sell should revert");
        assertTrue(_contains(data, abi.encodeWithSignature("SellExceedsSupply()")), "wrong revert reason");

        // but alice selling exactly her own balance works (pot PSP is not hers)
        _sell(alice, pspOut);
        assertGt(hook.totalSupplyPSP(), 0, "supply should retain pot floor");
        // pot retired 2026-08-19: swap fees flow to the staker accumulator (B1e pins exact math)
    }

    // ── dust swaps rejected (C-1) ──
    function test_B1g_dustSwapRejected() public {
        _launch(100e18);
        vm.startPrank(alice);
        mixETH.approve(address(router), 1e12);
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = BRouter.Call({isBuy: true, amount: 1e12 - 1, settleMode: 0, takeMode: 0});
        (bool ok, bytes memory data) =
            address(router).call(abi.encodeCall(BRouter.execute, (key, calls, alice)));
        vm.stopPrank();
        assertFalse(ok, "dust swap should revert");
        assertTrue(_contains(data, abi.encodeWithSignature("SwapTooSmall()")), "wrong revert reason");
    }

    // ── repeated small sells: rounding-direction dust probe (curve mode) ──
    function test_B1h_manySmallSellsDustProbe() public {
        _launch(100e18);
        uint256 out = _buy(alice, 5e18);
        uint256 slice = out / 500;
        for (uint256 i = 0; i < 499; i++) {
            _sell(alice, slice);
            assertGe(_slack(), 0, "slack went negative on tiny sells");
        }
        console2.log("B1h final slack (wei):", _slack() < 0 ? uint256(-_slack()) : uint256(_slack()));
        assertTrue(_slack() >= 0);
    }
}
