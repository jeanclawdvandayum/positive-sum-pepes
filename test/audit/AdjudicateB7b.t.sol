// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BBase} from "../wave2/auditorB/BBase.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Wave2 adjudication: B7b quote-vs-execution discrepancy
/// @notice B7b failed: hook.getBuyOutput(1e18)=4.7626e21 vs BRouter-reported
///         buy=5.0132e21 (ratio 1.0525 ~= 1/0.95). This test computes the
///         SOURCE-CORRECT fee-adjusted expectation f(0.95*x) and checks what
///         the hook actually minted, isolating protocol bug vs B harness bug.
contract AdjudicateB7b is BBase {
    function test_adjudicate_quoteVsExecution() public {
        _launch(100e18);
        uint256 bobOut = _buy(bob, 3_000e18);
        _buy(carol, 500e18);
        _sell(bob, bobOut / 2, bob);

        CurveMath.CurveConfig memory cfg = _curve();
        uint256 S = hook.totalSupplyPSP();
        uint256 x = 1e18;

        // views
        uint256 quoteFull = hook.getBuyOutput(x); // f(x) — curve unit, fee-exclusive
        uint256 feeAdj = CurveMath.computeBuyOutput(x * 9500 / 10000, S, cfg); // f(0.95x) — user slice
        uint256 potSlice =
            CurveMath.computeBuyOutput(x * 25 / 10000, S + feeAdj, cfg); // pot slice

        // execution: PSP balance delta of buyer (user slice only)
        uint256 balBefore = psp.balanceOf(alice);
        _buy(alice, x, alice);
        uint256 got = psp.balanceOf(alice) - balBefore;

        // supply delta should equal user + pot slice
        uint256 supplyDelta = hook.totalSupplyPSP() - S;

        // log everything
        emit log_named_uint("quote f(x)      ", quoteFull);
        emit log_named_uint("expect f(0.95x) ", feeAdj);
        emit log_named_uint("expect potSlice ", potSlice);
        emit log_named_uint("executed got    ", got);
        emit log_named_uint("supplyDelta     ", supplyDelta);

        // ── adjudication asserts (updated 2026-08-19) ──
        // (1) execution matches source-correct fee-adjusted math → no protocol bug
        assertEq(got, feeAdj, "user output != f(0.95x)");
        // (2) v5.1: the pot is retired — every minted PSP belongs to the buyer,
        //     so the ledger delta is EXACTLY the user slice
        assertEq(supplyDelta, got, "supply delta != user output");
        // (3) B7b catch: the view now MIRRORS execution (f(0.95x)) instead of
        //     overstating by the 5% fee — quotes are exact
        assertEq(quoteFull, feeAdj, "view must mirror execution exactly");
    }

    /// B7d adjudication: log the ACTUAL revert data for the foreign-currency key
    function test_adjudicate_foreignCurrencyRevertData() public {
        _launch(100e18);
        // replicate B7d's foreign key exactly: currency0 kept, currency1 replaced
        address foreignAddr = address(new MockMixETH());
        PoolKey memory kCur = key;
        kCur.currency1 = Currency.wrap(foreignAddr);
        (bool ok3, bytes memory d3) =
            address(poolManager).call(abi.encodeCall(IPoolManager.initialize, (kCur, 79228162514264337593543950336)));
        emit log_named_uint("ok3", ok3 ? 1 : 0);
        emit log_bytes(d3);
        assertTrue(!ok3, "must revert");
        // the hook's gate should be reachable: check address ordering
        emit log_named_uint("currency0   ", uint256(uint160(Currency.unwrap(kCur.currency0))));
        emit log_named_uint("foreign     ", uint256(uint160(foreignAddr)));
    }
}
