// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {PSPFactory} from "../src/PSPFactory.sol";
import {PSPToken} from "../src/PSPToken.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {RoundController} from "../src/RoundController.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {ControllerDeployer} from "../src/ControllerDeployer.sol";
import {StakerDeployer} from "../src/StakerDeployer.sol";
import {Curve1Zones} from "../src/curves/Curve1Zones.sol";
import {SineMath} from "../src/libraries/SineMath.sol";

import {CBase, CSwapper} from "./wave2/auditorC/CBase.sol";
import {MockMixETH} from "./mocks/MockMixETH.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

/// @title SineFee — the sliding swap fee on sine rounds (scoopy 2026-08-30)
/// @notice Fee is a continuous function of reserve depth, anchored to the
///         wave's domain:
///            R ≤ boot        → 10%      (pre-wave raise: the early game)
///            boot < R < top   → linear decay 10% → 2.5% across the wave
///            R ≥ top          → 2.5%     (above the sine — deep reserve)
///         Zone-curve rounds keep the flat 5% (pinned in RedeemIndefinite).
///         This harness mirrors DeployPSP's production sine path exactly:
///         arm the factory, deploy with a 1-zone creation shape, predeposit
///         (→ boot), launch, buy across the regions.
contract SineFee is Test {
    MockPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;
    CSwapper swapper;

    PSPToken psp1;
    RoundController controller1;
    CurveHook hook1;

    address alice = makeAddr("alice");
    address rando = makeAddr("rando");

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 2_000_000e18}();
        mixETH.transfer(rando, 100_000e18); // the buyer wallet (fresh, unattributed)
        poolManager = new MockPoolManager();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)),
            IERC20(address(mixETH)),
            new HookDeployer(),
            new ControllerDeployer(),
            new StakerDeployer(),
            0
        );
        swapper = new CSwapper(IPoolManager(address(poolManager)), IERC20(address(mixETH)));

        // DeployPSP's default arm (tilted sine, dial-lab verified shape)
        factory.configureSine(SineMath.Params({
            p0: 1e13,
            preK: 4_605_170_185_988_092,
            magM: 20e18,
            lnTop: 6_396_929_655_216_146_432,
            ampBps: 10_000
        }));

        PSPFactory.RoundParams memory p = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: Curve1Zones.config() // creation-code shape only
        });
        (uint256 roundId,) = factory.deployRound(p);
        PSPToken token = factory.getRound(roundId).token;
        psp1 = token;
        controller1 = factory.getRound(roundId).controller;
        hook1 = factory.getRound(roundId).hook;
    }

    function _launch(uint256 boot) internal {
        mixETH.transfer(alice, boot);
        vm.startPrank(alice);
        mixETH.approve(address(controller1), boot);
        controller1.predeposit(boot);
        vm.stopPrank();
        vm.prank(address(factory));
        controller1.launchPooledBuy();
        vm.prank(alice);
        controller1.claimPredepositPSP();
    }

    function _buy(uint256 amount) internal returns (uint256 out) {
        vm.prank(rando); // fresh wallet, no attribution — full fee to stakers
        mixETH.approve(address(swapper), amount);
        vm.prank(rando);
        out = swapper.buy(_key(), amount, rando);
    }

    function _key() internal view returns (PoolKey memory) {
        address c0 = address(mixETH);
        address c1 = address(psp1);
        if (c0 > c1) (c0, c1) = (c1, c0);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook1))
        });
    }

    /// The three regions, read straight off the fee view.
    function test_FeeRegions() public {
        _launch(100e18); // boot = 100 mix
        // auto-getter omits cp[]: (p0, preK, boot, span, segWidth, lam, B,
        // slope, amp, pTop, tailSlope, q0, qTop)
        (,, uint256 boot, uint256 span,,,,,,,,,) = hook1.sineCurve();
        assertEq(boot, 100e18, "boot = actual raise");
        assertEq(span, 2000e18, "span = magM x boot");

        // launch seam: R == boot → pre-wave fee (r <= boot)
        assertEq(hook1.reserveMixETH(), boot, "reserve at launch = boot");
        assertEq(hook1.swapFeeBps(), 1000, "10% pre-wave");

        // mid-wave: linear decay — R moves by the POST-FEE input, so assert
        // against the live reserve, not the nominal buy size
        _buy(1000e18);
        uint256 rMid = hook1.reserveMixETH();
        assertGt(rMid, boot, "past the seam");
        assertLt(rMid, boot + span, "still inside the wave");
        assertEq(
            uint256(hook1.swapFeeBps()),
            1000 - ((750 * (rMid - boot)) / span),
            "mid-wave: linear in reserve depth"
        );

        // above the wave: R >= boot + span -> 2.5% (buy past the top; the
        // fee itself is mid-wave-priced, so leave headroom)
        _buy(2000e18);
        assertGe(hook1.reserveMixETH(), boot + span, "past the wave top");
        assertEq(hook1.swapFeeBps(), 250, "2.5% above the sine");
    }

    /// Execution matches the view: reserve grows by input minus the CURRENT
    /// fee slice; the fee lands in the claimable surplus (balance - reserve).
    function test_FeeChargedInExecution() public {
        _launch(100e18);

        uint256 feeBps = hook1.swapFeeBps(); // 1000 at the seam
        uint256 inAmt = 10e18;
        uint256 rBefore = hook1.reserveMixETH();
        uint256 sBefore = mixETH.balanceOf(address(hook1)) - rBefore; // surplus

        _buy(inAmt);

        uint256 fee = (inAmt * feeBps) / 10000;
        assertEq(hook1.reserveMixETH(), rBefore + inAmt - fee, "reserve += post-fee input");
        uint256 sAfter = mixETH.balanceOf(address(hook1)) - hook1.reserveMixETH();
        assertEq(sAfter - sBefore, fee, "fee slice accrued to stakers' surplus");
    }

    /// Quote parity (B7b principle, sine-aware): getBuyOutput/getSellOutput
    /// mirror execution exactly — same curve, same fee basis.
    function test_QuoteParity() public {
        _launch(100e18);
        uint256 inAmt = 5e18;

        uint256 quote = hook1.getBuyOutput(inAmt);
        uint256 out = _buy(inAmt);
        assertEq(quote, out, "buy quote == execution");
    }
}
