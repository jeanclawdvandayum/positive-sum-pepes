// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PSPFactory} from "../src/PSPFactory.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {ControllerDeployer} from "../src/ControllerDeployer.sol";
import {StakerDeployer} from "../src/StakerDeployer.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {RoundController} from "../src/RoundController.sol";
import {TokenDeployer} from "../src/ControllerDeployer.sol";
import {PSPToken} from "../src/PSPToken.sol";

import {MockMixETH} from "./mocks/MockMixETH.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

/// @dev Is deployRound gas actually draw-dependent? 12 rounds, fresh block
///      entropy each (mining salts key off prevrandao/timestamp/number +
///      controller address, which differs per round anyway).
contract DeployGasSpread is Test {
    MockMixETH mixETH;
    MockPoolManager poolManager;
    PSPFactory factory;
    HookDeployer hookDeployer;

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();
        poolManager = new MockPoolManager();
        hookDeployer = new HookDeployer();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)),
            IERC20(address(mixETH)),
            hookDeployer,
            new ControllerDeployer(),
            new StakerDeployer(),
            0,
            address(this) // deployerCutTo (CLOCK-REDESIGN §3)
        );
    }

    function _params() internal pure returns (PSPFactory.RoundParams memory) {
        return PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
        });
    }

    function test_deployRound_gas_spread() public {
        uint256 lo = type(uint256).max;
        uint256 hi = 0;
        for (uint256 i = 0; i < 12; i++) {
            vm.roll(block.number + 7 + i);
            vm.warp(block.timestamp + 121 + i * 13);
            uint256 g0 = gasleft();
            (uint256 rid, address ha) = factory.deployRound(_params());
            uint256 g = g0 - gasleft();
            rid; ha;
            if (g < lo) lo = g;
            if (g > hi) hi = g;
            console2.log("draw", i, "deployRound gas:", g);
        }
        console2.log("min :", lo);
        console2.log("max :", hi);
        console2.log("spread (max-min):", hi - lo);
    }

    function test_deployHook_gas_spread() public {
        // one real round first, for a genuine controller/registry/config
        (uint256 rid,) = factory.deployRound(_params());
        (, RoundController ctl,,,,) = factory.rounds(rid);
        address registry = factory.referralRegistryOf(rid);

        uint256 lo = type(uint256).max;
        uint256 hi = 0;
        for (uint256 i = 0; i < 12; i++) {
            vm.roll(block.number + 11 + i);
            vm.warp(block.timestamp + 97 + i * 7);
            uint256 g0 = gasleft();
            (address p, bytes32 s) = hookDeployer.mineHook(
                IPoolManager(address(poolManager)),
                address(ctl),
                registry,
                _params().curveConfig,
                address(this), // deployerCutTo (CLOCK-REDESIGN §3)
                131_072
            );
            address ha = hookDeployer.deployHookAt(
                s, IPoolManager(address(poolManager)), address(ctl), registry, _params().curveConfig, address(this)
            );
            p;
            uint256 g = g0 - gasleft();
            ha; s;
            if (g < lo) lo = g;
            if (g > hi) hi = g;
            console2.log("draw", i, "deployHook gas:", g);
        }
        console2.log("min :", lo);
        console2.log("max :", hi);
        console2.log("spread (max-min):", hi - lo);
    }

    /// @dev attribute the non-mining variance: token deploy, controller
    ///      deploy (incl. staker), and registry deploy, isolated per step.
    function test_step_attribution() public {
        (uint256 rid,) = factory.deployRound(_params()); // warm canonical path
        rid;
        uint256 loTok = type(uint256).max; uint256 hiTok = 0;
        uint256 loCtl = type(uint256).max; uint256 hiCtl = 0;
        uint256 loReg = type(uint256).max; uint256 hiReg = 0;
        for (uint256 i = 0; i < 12; i++) {
            vm.roll(block.number + 5 + i);
            vm.warp(block.timestamp + 61 + i * 11);

            uint256 g0 = gasleft();
            PSPToken tok = new TokenDeployer().deployToken("Positive Sum Pepes", "PSP", address(factory));
            uint256 gTok = g0 - gasleft();
            if (gTok < loTok) loTok = gTok;
            if (gTok > hiTok) hiTok = gTok;

            CurveMath.CurveConfig memory cfg = _params().curveConfig;
            cfg.timings = 0; // matches factory roundTimings in this setUp
            g0 = gasleft();
            RoundController ctl = factory.controllerDeployer().deployController(
                tok, IERC20(address(mixETH)), cfg, address(factory), factory.descriptor(), factory.stakerDeployer()
            );
            uint256 gCtl = g0 - gasleft();
            if (gCtl < loCtl) loCtl = gCtl;
            if (gCtl > hiCtl) hiCtl = gCtl;

            g0 = gasleft();
            address reg = factory.controllerDeployer().deployRegistry(ctl.stakerAddress(), factory.REFERRAL_MIN_STAKE());
            uint256 gReg = g0 - gasleft();
            if (gReg < loReg) loReg = gReg;
            if (gReg > hiReg) hiReg = gReg;

            // hook mining against THIS iteration's fresh controller —
            // mirrors deployRound's context exactly (constructor args differ
            // per round, entropy keyed to controller address)
            g0 = gasleft();
            (address p2, bytes32 s2) = hookDeployer.mineHook(
                IPoolManager(address(poolManager)), address(ctl), reg, cfg, address(this), 131_072
            );
            address h2 = hookDeployer.deployHookAt(
                s2, IPoolManager(address(poolManager)), address(ctl), reg, cfg, address(this)
            );
            uint256 gHook = g0 - gasleft();
            h2; p2;

            console2.log("iter", i, "token / controller / registry / hook-mining gas:");
            console2.log("    tok/ctl/reg:", gTok, gCtl, gReg);
            console2.log("    hook:", gHook);
        }
        console2.log("token     min/max:", loTok, hiTok);
        console2.log("controller min/max:", loCtl, hiCtl);
        console2.log("registry  min/max:", loReg, hiReg);
    }
}
