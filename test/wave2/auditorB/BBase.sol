// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PSPFactory} from "../../../src/PSPFactory.sol";
import {HookDeployer} from "../../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../../src/ControllerDeployer.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {PSPStaker} from "../../../src/PSPStaker.sol";
import {PSPZapOut} from "../../../src/PSPZapOut.sol";
import {MockMixETH} from "../../mocks/MockMixETH.sol";

/// @notice Auditor B harness: REAL Uniswap v4-core PoolManager (not MockPoolManager),
///         production deploy path (PSPFactory → HookDeployer/ControllerDeployer),
///         MockMixETH as the only mock. All delta/settle behavior below is real V4.
abstract contract BBase is Test {
    PoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;
    CurveHook hook;
    RoundController controller;
    PSPStaker public stakerV; // cached: single vm.prank must not be eaten by the staker() view call
    IERC20 psp;
    PoolKey key;
    BRouter router;

    address alice = makeAddr("alice"); // predepositor / staker
    address bob = makeAddr("bob"); // second buyer / quorum
    address carol = makeAddr("carol"); // bystander / attacker

    // default curve: production-ish S-shape
    function _curve() internal view virtual returns (CurveMath.CurveConfig memory) {
        return CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);
    }

    function setUp() public virtual {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 1_000_000e18}();
        poolManager = new PoolManager(address(this)); // REAL v4-core PM
        factory = new PSPFactory(
            IPoolManager(address(poolManager)), IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer(), new StakerDeployer()
        , 0);

        PSPFactory.RoundParams memory params =
            PSPFactory.RoundParams({name: "B", symbol: "AUD", curveConfig: _curve()});
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory r = factory.getRound(roundId);
        hook = CurveHook(payable(address(r.hook)));
        controller = RoundController(address(r.controller));
        stakerV = controller.staker();
        psp = IERC20(address(r.token));

        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(address(psp));
        if (c0 > c1) (c0, c1) = (c1, c0);
        key = PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: IHooks(address(hook))});

        router = new BRouter(IPoolManager(address(poolManager)), address(mixETH));

        // fund actors
        mixETH.transfer(alice, 100_000e18);
        mixETH.transfer(bob, 100_000e18);
        mixETH.transfer(carol, 100_000e18);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
    }

    // ─────────────── lifecycle helpers ───────────────

    function _launch(uint256 bootAmount) internal {
        vm.startPrank(alice);
        mixETH.approve(address(controller), bootAmount);
        controller.predeposit(bootAmount);
        vm.stopPrank();
        vm.prank(address(factory));
        controller.launchPooledBuy();
        vm.prank(alice);
        controller.claimPredepositPSP(); // auto-locks genesis PSP
        skip(1);
    }

    /// @dev bob buys `amount` mixETH worth and locks (for governance quorum)
    function _bobBuysAndLocks(uint256 amount) internal returns (uint256 pspOut) {
        vm.startPrank(bob);
        mixETH.approve(address(router), amount);
        BRouter.Call memory c = BRouter.Call({isBuy: true, amount: amount, settleMode: 0, takeMode: 0});
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = c;
        uint256[] memory outs = router.execute(key, calls, bob);
        pspOut = outs[0];
        psp.approve(address(stakerV), type(uint256).max);
        stakerV.lock(pspOut);
        vm.stopPrank();
    }

    function _bomb() internal {
        // M-1 fix: vote weight must come from locks with lockTime < proposeTime.
        // All locks in this harness happen at the same warp instant as the
        // proposal unless we advance — advance first.
        skip(1);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        skip(3 days + 1);
        controller.carpetBomb(); // → Mode.Flat, pot redeemed+burned
    }

    /// @dev true if `needle` occurs anywhere in `haystack` (revert-data containment)
    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0) return true;
        for (uint256 i = 0; i + needle.length <= haystack.length; i++) {
            uint256 j = 0;
            for (; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) break;
            }
            if (j == needle.length) return true;
        }
        return false;
    }

    // ─────────────── swap helpers (honest) ───────────────

    function _buy(address who, uint256 amount) internal returns (uint256) {
        return _buy(who, amount, who);
    }

    function _buy(address who, uint256 amount, address to) internal returns (uint256 out) {
        vm.startPrank(who);
        mixETH.approve(address(router), amount);
        out = _routerBuy(amount, to);
        vm.stopPrank();
    }

    function _routerBuy(uint256 amount, address to) internal returns (uint256) {
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = BRouter.Call({isBuy: true, amount: amount, settleMode: 0, takeMode: 0});
        uint256[] memory outs = router.execute(key, calls, to);
        return outs[0];
    }

    function _sell(address who, uint256 amount) internal returns (uint256) {
        return _sell(who, amount, who);
    }

    function _sell(address who, uint256 amount, address to) internal returns (uint256 out) {
        vm.startPrank(who);
        psp.approve(address(router), amount);
        out = _routerSell(amount, to);
        vm.stopPrank();
    }

    function _routerSell(uint256 amount, address to) internal returns (uint256) {
        BRouter.Call[] memory calls = new BRouter.Call[](1);
        calls[0] = BRouter.Call({isBuy: false, amount: amount, settleMode: 0, takeMode: 0});
        uint256[] memory outs = router.execute(key, calls, to);
        return outs[0];
    }

    // ─────────────── invariant helpers ───────────────

    function _cfg() internal view returns (CurveMath.CurveConfig memory c) {
        // CurveConfig gained a scalar `timings` field (2026-08-18) — the
        // auto-getter now returns (P0, timings); zones still need the
        // flattened getter. Destructure keeps this compiling both ways.
        (c.P0,) = hook.curveConfig();
        c.zones = hook.getCurveZones();
    }

    /// @dev R − ∫₀^S P(s)ds — curve-mode solvency slack (must stay ≥ 0)
    function _slack() internal view returns (int256) {
        return int256(hook.reserveMixETH()) - int256(CurveMath.curveIntegral(0, hook.totalSupplyPSP(), _cfg()));
    }

    function _feeLedger() internal view returns (uint256) {
        return mixETH.balanceOf(address(hook)) - hook.reserveMixETH();
    }
}

/// @notice Flexible V4 router used for both honest flows and spoof attempts.
///         settleMode/takeMode allow malformed accounting flows against the REAL PM.
contract BRouter {
    using SafeERC20 for IERC20;

    uint8 public constant SETTLE_EXACT = 0;
    uint8 public constant SETTLE_NONE = 1;
    uint8 public constant SETTLE_HALF = 2;
    uint8 public constant SETTLE_DOUBLE = 3;
    uint8 public constant TAKE_EXACT = 0;
    uint8 public constant TAKE_NONE = 1;
    uint8 public constant TAKE_DOUBLE = 2;

    struct Call {
        bool isBuy;
        uint256 amount;
        uint8 settleMode;
        uint8 takeMode;
    }

    IPoolManager public immutable pm;
    address public immutable mix;

    constructor(IPoolManager _pm, address _mix) {
        pm = _pm;
        mix = _mix;
    }

    function execute(PoolKey calldata _key, Call[] calldata calls, address to) external returns (uint256[] memory) {
        // FIX (harness): _one() pays the PoolManager from the ROUTER's balance.
        // Attempt-1's version never pulled from the user, so every honest flow
        // died on ERC20InsufficientBalance(router, 0, amount). Pull the exact
        // settle amounts from the caller up front (msg.sender is only knowable
        // here, not inside unlockCallback).
        bool mixIsZero = Currency.unwrap(_key.currency0) == mix;
        address pspA = Currency.unwrap(mixIsZero ? _key.currency1 : _key.currency0);
        uint256 mixPull;
        uint256 pspPull;
        for (uint256 i = 0; i < calls.length; i++) {
            uint256 amt = _settleAmt(calls[i]);
            if (amt == 0) continue;
            if (calls[i].isBuy) {
                mixPull += amt;
            } else {
                pspPull += amt;
            }
        }
        if (mixPull > 0) IERC20(mix).safeTransferFrom(msg.sender, address(this), mixPull);
        if (pspPull > 0) IERC20(pspA).safeTransferFrom(msg.sender, address(this), pspPull);

        bytes memory res = pm.unlock(abi.encode(_key, calls, to));
        return abi.decode(res, (uint256[]));
    }

    function _settleAmt(Call memory c) internal pure returns (uint256) {
        if (c.settleMode == SETTLE_NONE) return 0;
        if (c.settleMode == SETTLE_HALF) return c.amount / 2;
        if (c.settleMode == SETTLE_DOUBLE) return c.amount * 2;
        return c.amount;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory _key, Call[] memory calls, address to) = abi.decode(data, (PoolKey, Call[], address));
        uint256[] memory outs = new uint256[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            outs[i] = _one(_key, calls[i], to);
        }
        return abi.encode(outs);
    }

    function _one(PoolKey memory _key, Call memory c, address to) internal returns (uint256) {
        bool mixIsZero = Currency.unwrap(_key.currency0) == mix;
        Currency mixCur = mixIsZero ? _key.currency0 : _key.currency1;
        Currency pspCur = mixIsZero ? _key.currency1 : _key.currency0;
        Currency inCur = c.isBuy ? mixCur : pspCur;

        // pay input to the PoolManager (funds pre-pulled in execute)
        uint256 settleAmt = _settleAmt(c);
        if (settleAmt > 0) {
            pm.sync(inCur);
            IERC20(Currency.unwrap(inCur)).safeTransfer(address(pm), settleAmt);
            pm.settle();
        }

        bool zeroForOne = c.isBuy ? mixIsZero : !mixIsZero;
        BalanceDelta d = pm.swap(
            _key,
            SwapParams({
                amountSpecified: -int256(c.amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                zeroForOne: zeroForOne
            }),
            "" // hookData — hook must ignore it
        );

        int256 outDelta = c.isBuy
            ? (mixIsZero ? d.amount1() : d.amount0())
            : (mixIsZero ? d.amount0() : d.amount1());
        require(outDelta > 0, "no out");
        uint256 out = uint256(int256(outDelta));

        if (c.takeMode != TAKE_NONE) {
            Currency outCur = c.isBuy ? pspCur : mixCur;
            uint256 takeAmt = c.takeMode == TAKE_DOUBLE ? out * 2 : out;
            pm.take(outCur, to, takeAmt);
        }
        return out;
    }
}

/// @dev ETH receiver that always reverts — for zapOut forward-failure tests.
contract RevertingReceiver {
    receive() external payable {
        revert("no eth pls");
    }
}

/// @dev ETH receiver that reenters PSPZapOut during the ETH forward.
contract ReentrantForward {
    PSPZapOut public zap;
    PoolKey public key;
    IERC20 public psp;
    uint256 public reenterCalls;

    function set(PSPZapOut _zap, address _psp, PoolKey calldata _key) external {
        zap = _zap;
        psp = IERC20(_psp);
        key = _key;
    }

    function sell(uint256 pspIn) external {
        psp.approve(address(zap), pspIn);
        zap.zapOut(key, pspIn, 0, 0);
    }

    receive() external payable {
        // reenter once: sell whatever PSP we still hold via a fresh zapOut
        if (reenterCalls == 0) {
            reenterCalls = 1;
            uint256 bal = psp.balanceOf(address(this));
            if (bal > 0) {
                psp.approve(address(zap), bal);
                try zap.zapOut(key, bal, 0, 0) {} catch {}
            }
        }
    }
}

import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StakerDeployer} from "src/StakerDeployer.sol";


/// @dev Calls CurveHook.beforeSwap DIRECTLY (no PoolManager wrap) so custom
///      errors and panics surface unwrapped and can be pinned exactly.
///      Only valid for code paths that revert before any poolManager call
///      (all the pre-checks and ledger arithmetic qualify).
contract HookProbe {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    CurveHook public hook;
    address public mix;

    constructor(CurveHook _hook, address _mix) {
        hook = _hook;
        mix = _mix;
    }

    function buy(PoolKey calldata _key, uint256 mixIn) external returns (uint256) {
        bool mixIsZero = Currency.unwrap(_key.currency0) == mix;
        (, BeforeSwapDelta d,) = hook.beforeSwap(
            address(this),
            _key,
            SwapParams({amountSpecified: -int256(mixIn), sqrtPriceLimitX96: 0, zeroForOne: mixIsZero}),
            ""
        );
        return uint256(int256(d.getUnspecifiedDelta()));
    }

    function sell(PoolKey calldata _key, uint256 pspIn) external returns (uint256) {
        bool mixIsZero = Currency.unwrap(_key.currency0) == mix;
        (, BeforeSwapDelta d,) = hook.beforeSwap(
            address(this),
            _key,
            SwapParams({amountSpecified: -int256(pspIn), sqrtPriceLimitX96: 0, zeroForOne: !mixIsZero}),
            ""
        );
        return uint256(int256(d.getSpecifiedDelta()));
    }

    function exactOut(PoolKey calldata _key, uint256 wantOut, bool asBuy) external returns (uint256) {
        bool mixIsZero = Currency.unwrap(_key.currency0) == mix;
        (, BeforeSwapDelta d,) = hook.beforeSwap(
            address(this),
            _key,
            SwapParams({
                amountSpecified: int256(wantOut),
                sqrtPriceLimitX96: 0,
                zeroForOne: asBuy ? mixIsZero : !mixIsZero
            }),
            ""
        );
        return uint256(int256(d.getSpecifiedDelta()));
    }
}

/// @dev Exposes CurveMath internal functions through an EXTERNAL call boundary
///      so vm.expectRevert can observe panics (internal library calls inline
///      into the test frame where expectRevert cannot catch them).
contract LibProbe {
    function sellOut(uint256 pspIn, uint256 S, CurveMath.CurveConfig memory c)
        external
        pure
        returns (uint256)
    {
        return CurveMath.computeSellOutput(pspIn, S, c);
    }

    function buyOut(uint256 mixIn, uint256 S, CurveMath.CurveConfig memory c)
        external
        pure
        returns (uint256)
    {
        return CurveMath.computeBuyOutput(mixIn, S, c);
    }

    function integral(uint256 S1, uint256 S2, CurveMath.CurveConfig memory c)
        external
        pure
        returns (uint256)
    {
        return CurveMath.curveIntegral(S1, S2, c);
    }
}
