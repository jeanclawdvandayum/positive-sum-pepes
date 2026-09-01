// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PSPToken} from "../../../src/PSPToken.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {PSPFactory} from "../../../src/PSPFactory.sol";
import {HookDeployer} from "../../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../../src/ControllerDeployer.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";

import {MockMixETH} from "../../mocks/MockMixETH.sol";
import {MockPoolManager} from "../../mocks/MockPoolManager.sol";
import {StakerDeployer} from "../../../src/StakerDeployer.sol";
import {PSPStaker} from "../../../src/PSPStaker.sol";

/// @dev Auditor C harness: the REAL PSPFactory + both deployer vessels + the
///      REAL CurveHook flow against the functional MockPoolManager. No source
///      mocks for the system under audit — only the V4 pool manager and the
///      mixETH vault are mocked (same as the repo's own unit suite).
contract CBase is Test {
    MockPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;
    HookDeployer hookDeployer;
    ControllerDeployer controllerDeployer;
    CSwapper swapper;

    // Round 1 (deployed in setUp)
    PSPToken psp1;
    RoundController controller1;
    CurveHook hook1;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");
    address rando = makeAddr("rando");

    function setUp() public virtual {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 2_000_000e18}();
        poolManager = new MockPoolManager();
        hookDeployer = new HookDeployer();
        controllerDeployer = new ControllerDeployer();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)),
            IERC20(address(mixETH)),
            hookDeployer,
            controllerDeployer,
            new StakerDeployer(),
            0,
            address(this) // deployerCutTo (CLOCK-REDESIGN §3)
        );
        swapper = new CSwapper(IPoolManager(address(poolManager)), IERC20(address(mixETH)));

        _deployRound1();
        mixETH.transfer(alice, 1_000e18);
        mixETH.transfer(bob, 1_000e18);
        mixETH.transfer(attacker, 1_000e18);
    }

    function _curve() internal pure returns (CurveMath.CurveConfig memory) {
        return CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);
    }

    function _deployRound1() internal {
        PSPFactory.RoundParams memory params =
            PSPFactory.RoundParams({name: "Positive Sum Pepes", symbol: "PSP", curveConfig: _curve()});
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory round = factory.getRound(roundId);
        psp1 = round.token;
        controller1 = round.controller;
        hook1 = round.hook;
    }

    /// @dev Predeposit 200 each from alice+bob, launch via the factory (the
    ///      controller's owner), both claim — real staked weight + supply.
    ///      CLOCK-REDESIGN §1 (2026-09-01): launch INSIDE a fresh epoch with
    ///      NO terminal warp. The old shape ended with a warp past
    ///      detonationAt (lock-liveness under governance) — every post-launch
    ///      buy/sell then reverted TradingHalted (the dead-clock wall).
    ///      Warping to the epoch-1 boundary BEFORE the predeposit anchors the
    ///      claims in a nonzero epoch AND leaves block.timestamp == launch
    ///      ts, so the clock is armed and ALIVE for the next 72h of test
    ///      time. Timeline is explicit from here on:
    ///        - detonation: _detonateRound1() (warps to zero, one-tx kill);
    ///        - staker weight LIVE (epoch+1): skip to the next 7-day
    ///          boundary AFTER trading — that warp kills the clock (a 7-day
    ///          epoch outlives the 72h window), so trade first, warp after.
    ///      Same shape as ClockDetonation's _launchLive (now delegating
    ///      here); returns the launch ts.
    function _launchRound1() internal returns (uint256 launchTs) {
        vm.warp(7 days + 1); // epoch 1 — staker anchors cleanly (never epoch 0)
        launchTs = block.timestamp;

        vm.startPrank(alice);
        mixETH.approve(address(controller1), 200e18);
        controller1.predeposit(200e18);
        vm.stopPrank();

        vm.startPrank(bob);
        mixETH.approve(address(controller1), 200e18);
        controller1.predeposit(200e18);
        vm.stopPrank();

        vm.prank(address(factory));
        controller1.launchPooledBuy();

        vm.prank(alice);
        controller1.claimPredepositPSP();
        vm.prank(bob);
        controller1.claimPredepositPSP();
        // no terminal warp: detonationAt == launchTs + 72h stays in the future
    }

    /// @dev CLOCK-REDESIGN §4 kill: warp past the hook's detonation clock
    ///      and let any rando detonate — one tx flattens the round, opens
    ///      every lock, and births round 2 on the factory (the governance
    ///      round-trip died 2026-09-01; its coverage lives in the clock
    ///      tests). Round 2 EXISTS when this returns.
    function _detonateRound1() internal {
        vm.warp(hook1.detonationAt() + 1);
        vm.prank(rando);
        controller1.detonate();
    }

    /// @dev Reconstruct the factory's gameCurve from PUBLIC state only:
    ///      P0 from the auto-getter, zones from the deployed hook. This is
    ///      exactly what an on-chain attacker can read.
    function _gameCurveFromPublicState() internal view returns (CurveMath.CurveConfig memory cfg) {
        (uint256 p0,) = factory.gameCurve(); // + timings (ignored)
        CurveMath.Zone[] memory zones = hook1.getCurveZones();
        cfg = CurveMath.CurveConfig({timings: 0, P0: p0, zones: zones});
    }

    /// @dev Predict the address of the controller that the NEXT round would
    ///      get: the ControllerDeployer vessel is a plain CREATE deployer, so
    ///      addresses are (vessel, nonce) pairs, fully public. POST-SPLIT
    ///      (2026-08-18) the vessel deploys ONLY the controller — the token
    ///      rides a fresh TokenDeployer created by the factory each round —
    ///      so the next controller consumes the vessel's NEXT nonce directly.
    function _predictedNextController() internal view returns (address) {
        uint256 n = vm.getNonce(address(controllerDeployer));
        return vm.computeCreateAddress(address(controllerDeployer), n);
    }
}

/// @dev Minimal independent unlock/swap router (auditor-owned; mirrors the
///      settlement flow a V4 swapper must drive: sync → pay → settle → swap →
///      take). Used to generate real buy flow (and thus side-pot accrual).
contract CSwapper {
    IPoolManager public immutable pm;
    IERC20 public immutable mix;

    constructor(IPoolManager _pm, IERC20 _mix) {
        pm = _pm;
        mix = _mix;
    }

    function buy(PoolKey calldata key, uint256 mixIn, address to) external returns (uint256 pspOut) {
        mix.transferFrom(msg.sender, address(this), mixIn);
        bytes memory r = pm.unlock(abi.encode(key, mixIn, to));
        return abi.decode(r, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, uint256 mixIn, address to) = abi.decode(data, (PoolKey, uint256, address));
        bool mixIsZero = Currency.unwrap(key.currency0) == address(mix);
        Currency mixCur = mixIsZero ? key.currency0 : key.currency1;
        Currency pspCur = mixIsZero ? key.currency1 : key.currency0;

        pm.sync(mixCur);
        mix.transfer(address(pm), mixIn);
        pm.settle();

        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                amountSpecified: -int256(mixIn),
                sqrtPriceLimitX96: mixIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                zeroForOne: mixIsZero
            }),
            ""
        );
        int256 pspDelta = mixIsZero ? d.amount1() : d.amount0();
        require(pspDelta > 0, "no out");
        uint256 out = uint256(int256(pspDelta));
        pm.take(pspCur, to, out);
        return abi.encode(out);
    }
}

/// @dev CSwapper's twin that forwards the TRADER through hookData (the
///      canonical-zap identity path) so tickets seat the human, not the
///      router. Unattributed traders run the 60/39/1 fee branch.
///      (Lifted here from ClockDetonation.t.sol 2026-09-01 so the
///      redemption tests can buy on the hinted path too.)
contract TicketSwapper {
    IPoolManager public immutable pm;
    IERC20 public immutable mix;

    constructor(IPoolManager _pm, IERC20 _mix) {
        pm = _pm;
        mix = _mix;
    }

    function buy(PoolKey calldata key, uint256 mixIn, address to, address trader) external returns (uint256 pspOut) {
        mix.transferFrom(msg.sender, address(this), mixIn);
        bytes memory r = pm.unlock(abi.encode(key, mixIn, to, trader));
        return abi.decode(r, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, uint256 mixIn, address to, address trader) =
            abi.decode(data, (PoolKey, uint256, address, address));
        bool mixIsZero = Currency.unwrap(key.currency0) == address(mix);
        Currency mixCur = mixIsZero ? key.currency0 : key.currency1;
        Currency pspCur = mixIsZero ? key.currency1 : key.currency0;

        pm.sync(mixCur);
        mix.transfer(address(pm), mixIn);
        pm.settle();

        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                amountSpecified: -int256(mixIn),
                sqrtPriceLimitX96: mixIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                zeroForOne: mixIsZero
            }),
            abi.encode(trader) // exactly 32 bytes — the hook's A-1 decode shape
        );
        int256 pspDelta = mixIsZero ? d.amount1() : d.amount0();
        require(pspDelta > 0, "no out");
        uint256 out = uint256(int256(pspDelta));
        pm.take(pspCur, to, out);
        return abi.encode(out);
    }
}
