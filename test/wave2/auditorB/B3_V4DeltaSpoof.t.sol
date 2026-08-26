// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BBase, BRouter, HookProbe} from "./BBase.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {BaseHook} from "../../../lib/uniswap-hooks/src/base/BaseHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title B3 — V4 delta/settle integrity against the REAL PoolManager.
///        Every spoof path must fail closed; honest netting must be exact.
contract B3_V4DeltaSpoof is BBase {
    // ── honest buy+sell: both net to zero inside their unlocks (else unlock reverts) ──
    function test_B3a_honestFlowsNetZero() public {
        _launch(100e18);
        uint256 out = _buy(alice, 10e18);
        _sell(alice, out / 2);
        assertGt(_slack(), 0);
    }

    // ── two swaps in ONE unlock: sequential netting across currencies ──
    function test_B3b_twoSwapsOneUnlock() public {
        _launch(100e18);
        vm.startPrank(alice);
        mixETH.approve(address(router), 20e18);
        BRouter.Call[] memory calls = new BRouter.Call[](2);
        calls[0] = BRouter.Call({isBuy: true, amount: 12e18, settleMode: 0, takeMode: 0});
        calls[1] = BRouter.Call({isBuy: true, amount: 8e18, settleMode: 0, takeMode: 0});
        uint256[] memory outs = router.execute(key, calls, alice);
        vm.stopPrank();
        assertEq(psp.balanceOf(alice), outs[0] + outs[1], "batched buys mis-netted");
        assertGt(_slack(), 0);
    }

    // ── SPOOF: swap without settling input → whole unlock must revert, state untouched ──
    function test_B3d_noSettleReverts() public {
        _launch(100e18);
        uint256 S = hook.totalSupplyPSP();
        uint256 R = hook.reserveMixETH();

        vm.startPrank(alice);
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = BRouter.Call({isBuy: true, amount: 10e18, settleMode: 1, takeMode: 0}); // NO settle
        vm.expectRevert();
        router.execute(key, calls, alice);
        vm.stopPrank();

        assertEq(hook.totalSupplyPSP(), S, "supply changed on failed swap");
        assertEq(hook.reserveMixETH(), R, "reserve changed on failed swap");
    }

    // ── SPOOF: settle half the input → reverts ──
    function test_B3e_halfSettleReverts() public {
        _launch(100e18);
        vm.startPrank(alice);
        mixETH.approve(address(router), 10e18);
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = BRouter.Call({isBuy: true, amount: 10e18, settleMode: 2, takeMode: 0});
        vm.expectRevert();
        router.execute(key, calls, alice);
        vm.stopPrank();
    }

    // ── SPOOF: over-settle 2x, take exact output, no refund → unlock close fails ──
    function test_B3f_overSettleNoRefundReverts() public {
        _launch(100e18);
        vm.startPrank(alice);
        mixETH.approve(address(router), 20e18);
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = BRouter.Call({isBuy: true, amount: 10e18, settleMode: 3, takeMode: 0});
        vm.expectRevert();
        router.execute(key, calls, alice);
        vm.stopPrank();
    }

    // ── SPOOF: take double the credited output → unlock close fails ──
    function test_B3g_doubleTakeReverts() public {
        _launch(100e18);
        vm.startPrank(alice);
        mixETH.approve(address(router), 10e18);
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = BRouter.Call({isBuy: true, amount: 10e18, settleMode: 0, takeMode: 2});
        vm.expectRevert();
        router.execute(key, calls, alice);
        vm.stopPrank();
    }

    // ── SPOOF: donate tokens to the PM, then swap without settling ──
    //    The donation must NOT subsidize a free swap: router's own delta stays open.
    function test_B3h_donateToPMThenUnpaidSwapReverts() public {
        _launch(100e18);

        mixETH.transfer(address(poolManager), 50e18); // carol/test donates mixETH
        vm.prank(alice);
        psp.transfer(address(poolManager), psp.balanceOf(alice) / 2);

        vm.startPrank(alice);
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = BRouter.Call({isBuy: true, amount: 10e18, settleMode: 1, takeMode: 0});
        vm.expectRevert();
        router.execute(key, calls, alice);
        vm.stopPrank();

        // paid swap still works with donations sitting in the PM
        uint256 out = _buy(alice, 10e18);
        assertGt(out, 0);
    }

    // ── amountSpecified = int256.min reverts cleanly ──
    function test_B3i_int256MinAmount() public {
        _launch(100e18);
        RawSwapper raw = new RawSwapper(poolManager);
        vm.expectRevert(); // -int256.min overflows inside the hook (checked) or take fails
        raw.buy(key, type(int256).min);
    }

    // ── hookData is ignored: attacker-controlled hookData changes nothing ──
    function test_B3j_hookDataIgnored() public {
        _launch(100e18);
        HookDataRouter hd = new HookDataRouter(poolManager, address(mixETH));
        mixETH.transfer(address(hd), 10e18);
        // FIX (harness): buyExact used to `return 0;` without decoding the
        // callback result — the assertion compared 0 > 0. Decode properly.
        uint256 out = hd.buyExact(key, 10e18, hex"deadbeef");
        assertGt(out, 0, "hookData should not affect execution");
        assertEq(psp.balanceOf(address(this)), out);
    }

    // ── exact-out direction rejected by the hook ──
    function test_B3k_exactOutRejected() public {
        _launch(100e18);
        RawSwapper raw = new RawSwapper(poolManager);
        mixETH.transfer(address(raw), 10e18);
        // through the PM the string revert arrives wrapped by IHooks.WrappedError
        (bool ok, bytes memory data) =
            address(raw).call(abi.encodeCall(RawSwapper.swapExactOut, (key, 1e18)));
        assertFalse(ok, "exact-out should revert");
        assertTrue(
            _contains(data, abi.encodeWithSignature("Error(string)", "ExactOutNotSupported")),
            "wrong revert reason"
        );
    }

    // ── POSITIVE PIN: the hook's callbacks are gated to the PoolManager —
    //    direct calls (no PM wrap) revert NotPoolManager. This is what makes
    //    delta accounting unspoofable outside a real unlock.
    function test_B3n_hookCallbacksGatedToPM() public {
        _launch(100e18);
        HookProbe probe = new HookProbe(hook, address(mixETH));
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        probe.buy(key, 1e18);
    }

    // ── sqrtPriceLimitX96 is IGNORED: the hook consumes the full delta, so the
    //    V4 price-limit machinery never runs. A limit that would allow ZERO
    //    price movement on a normal AMM still fills the full amount here.
    //    Slippage protection must come from router-level minOut (zaps do).
    function test_B3m_sqrtPriceLimitIgnored() public {
        _launch(100e18);
        // for zeroForOne the limit must be BELOW current price to be valid; pass
        // MAX-1 instead — on a normal pool this direction+limit combo is an
        // immediate revert / no-op. Here the full 10e18 still fills.
        bool mixIsZero = Currency.unwrap(key.currency0) == address(mixETH);
        DirectLimit dl = new DirectLimit(poolManager, mixIsZero, address(mixETH));
        mixETH.transfer(address(dl), 10e18);
        uint256 out = dl.buyWithLimit(key, 10e18, TickMath.MAX_SQRT_PRICE - 1, mixIsZero);
        assertGt(out, 0, "limit-side swap should still fill fully via hook");
        assertEq(psp.balanceOf(address(this)), out, "output delivered");
    }

    // ── input exceeding the 150M ethInput cap: user pays full, gets capped output.
    //    Silently absorbs the excess into the reserve (donation), no revert.
    function test_B3l_inputOver150MCapSilentlyDonates() public {
        _launch(100e18);

        // mint enough mixETH for a >150M input (only possible in mock; on mainnet
        // mixETH supply bounds this — but the mechanism is worth pinning)
        vm.deal(address(this), 400_000_001 ether);
        mixETH.depositETH{value: 200_000_000e18}();
        mixETH.transfer(alice, 200_000_000e18);

        uint256 outAtCap = CurveMath.computeBuyOutput(150_000_000e18, hook.totalSupplyPSP(), _cfg());
        uint256 out = _buy(alice, 200_000_000e18);

        // user paid 200M but received exactly the output of the capped 150M
        assertEq(out, outAtCap, "output should equal capped-input output");
        // and the reserve kept the difference (over-backing, not theft)
        assertGe(hook.reserveMixETH(), 200_000_000e18 * 95 / 100, "reserve should absorb full input");
        assertGt(_slack(), 0, "solvency holds (massively over-backed)");
    }
}

import {CurveMath} from "../../../src/libraries/CurveMath.sol";

/// @dev Minimal router exposing raw swap params (int256 min, hookData, exact-out).
contract RawSwapper {
    IPoolManager public immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function buy(PoolKey calldata key, int256 amount) external returns (uint256) {
        pm.unlock(abi.encode(key, amount, false));
        return 0;
    }

    function swapExactOut(PoolKey calldata key, uint256 wantOut) external returns (uint256) {
        pm.unlock(abi.encode(key, int256(wantOut), true));
        return 0;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, int256 amt, bool exactOut) = abi.decode(data, (PoolKey, int256, bool));
        pm.swap(
            key,
            SwapParams({
                amountSpecified: exactOut ? amt : amt, // +amount == exact-out probe
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
                zeroForOne: true
            }),
            hex""
        );
        return "";
    }
}

/// @dev Settles exact input, swaps with attacker-controlled hookData, takes output
///      for the caller of buyExact.
contract HookDataRouter {
    using SafeERC20 for IERC20;

    IPoolManager public immutable pm;
    address public immutable mix;

    constructor(IPoolManager _pm, address _mix) {
        pm = _pm;
        mix = _mix;
    }

    function buyExact(PoolKey calldata key, uint256 mixIn, bytes calldata hookData) external returns (uint256) {
        bytes memory res = pm.unlock(abi.encode(key, mixIn, hookData, msg.sender));
        return abi.decode(res, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, uint256 mixIn, bytes memory hookData, address to) =
            abi.decode(data, (PoolKey, uint256, bytes, address));
        bool mixIsZero = Currency.unwrap(key.currency0) == mix;
        Currency mixCur = mixIsZero ? key.currency0 : key.currency1;
        Currency pspCur = mixIsZero ? key.currency1 : key.currency0;

        pm.sync(mixCur);
        IERC20(Currency.unwrap(mixCur)).safeTransfer(address(pm), mixIn);
        pm.settle();

        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                amountSpecified: -int256(mixIn),
                sqrtPriceLimitX96: mixIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                zeroForOne: mixIsZero
            }),
            hookData
        );
        int256 outDelta = mixIsZero ? d.amount1() : d.amount0();
        require(outDelta > 0, "no out");
        uint256 out = uint256(int256(outDelta));
        pm.take(pspCur, to, out);
        return abi.encode(out);
    }
}

/// @dev Router that lets the TEST choose sqrtPriceLimitX96 and swap direction,
///      self-funded, settles input and takes output for the test contract.
contract DirectLimit {
    using SafeERC20 for IERC20;

    IPoolManager public immutable pm;
    bool public immutable mixIsZero;
    address public immutable mix;

    constructor(IPoolManager _pm, bool _mixIsZero, address _mix) {
        pm = _pm;
        mixIsZero = _mixIsZero;
        mix = _mix;
    }

    function buyWithLimit(PoolKey calldata key, uint256 mixIn, uint160 limit, bool zeroForOne)
        external
        returns (uint256)
    {
        bytes memory res = pm.unlock(abi.encode(key, mixIn, limit, zeroForOne, msg.sender));
        return abi.decode(res, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, uint256 mixIn, uint160 limit, bool zeroForOne, address to) =
            abi.decode(data, (PoolKey, uint256, uint160, bool, address));
        Currency mixCur = mixIsZero ? key.currency0 : key.currency1;
        Currency pspCur = mixIsZero ? key.currency1 : key.currency0;

        pm.sync(mixCur);
        IERC20(mix).safeTransfer(address(pm), mixIn);
        pm.settle();

        BalanceDelta d = pm.swap(
            key,
            SwapParams({amountSpecified: -int256(mixIn), sqrtPriceLimitX96: limit, zeroForOne: zeroForOne}),
            ""
        );
        int256 outDelta = mixIsZero ? d.amount1() : d.amount0();
        require(outDelta > 0, "no out");
        uint256 out = uint256(int256(outDelta));
        pm.take(pspCur, to, out);
        return abi.encode(out);
    }
}
