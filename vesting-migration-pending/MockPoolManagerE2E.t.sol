// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IMixETH} from "../../src/interfaces/IMixETH.sol";

import {PSPFactory} from "../../src/PSPFactory.sol";
import {PSPStaker} from "../../src/PSPStaker.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../src/PSPZapOut.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {StakerDeployer} from "src/StakerDeployer.sol";


/// @dev Minimal view surface of CurveHook used for fee-ledger reconciliation.
interface IHookViews {
    function reserveMixETH() external view returns (uint256);
}

/// @title MockPoolManagerE2E — proves the functional mock executes the REAL
///        v4 swap flow end-to-end (zap → unlock → sync/settle → beforeSwap
///        hook → take) so the anvil lab can actually trade. This is the same
///        path the frontend wallet buttons use.
contract MockPoolManagerE2ETest is Test {
    MockMixETH mixETH;
    MockPoolManager poolManager;
    PSPFactory factory;
    PSPZapIn zapIn;
    PSPZapOut zapOut;
    IERC20 pspToken;
    address controller;
    PSPStaker stakerV; // cached staker (fee-era assertions)
    address hookAddr; // fee custody lives in the hook until finalize
    address hook;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();
        poolManager = new MockPoolManager();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)), IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer(), new StakerDeployer()
        , 0);

        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
        });
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory r = factory.getRound(roundId);
        pspToken = r.token;
        controller = address(r.controller);
        stakerV = r.controller.staker();
        // (2026-08-19) was a self-assignment (`hookAddr = hookAddr`) — the
        // key was built hookless and MockPoolManager's beforeSwap call died
        // on address(0). Bind the round's actual hook.
        hookAddr = address(r.hook);
        hook = hookAddr;

        zapIn = new PSPZapIn(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));
        zapOut = new PSPZapOut(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));

        // fund users
        vm.deal(alice, 1_000e18);
        vm.deal(bob, 1_000e18);
        mixETH.depositETH{value: 500e18}();
        mixETH.transfer(alice, 200e18);
        mixETH.transfer(bob, 100e18);
    }

    /// @dev Hook's curve reserve (mixETH backing circulating PSP). The gap
    ///      between the hook's ERC20 balance and this is the fee ledger —
    ///      fees physically live at the hook, earmarked for stakers.
    function hookReserve() internal view returns (uint256) {
        return IHookViews(hookAddr).reserveMixETH();
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(mixETH)),
            currency1: Currency.wrap(address(pspToken)),
            fee: 0x800000, // hook-flagged
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
    }

    function _launch() internal {
        vm.startPrank(alice);
        mixETH.approve(controller, 60e18);
        // controller.potDeposit-style receiver handles plain transfers
        (bool ok,) = controller.call(abi.encodeWithSignature("predeposit(uint256)", 60e18));
        assertTrue(ok, "predeposit failed");
        vm.stopPrank();

        vm.prank(address(factory)); // factory is the controller owner mid-round
        (bool ok2,) = controller.call(abi.encodeWithSignature("launchPooledBuy()"));
        assertTrue(ok2, "launch failed");
    }

    /// Full trade loop through the REAL zap contracts against the mock pm.
    function test_E2E_ZapBuyAndSell_AgainstMockPM() public {
        _launch();

        // ── buy through the real zap (the exact path the UI button drives) ──
        // (2026-08-19) v5.1 fee observability: fees are ledger-folded at the
        // staker instantly (pendingFeesMixETH is transient — _updateAccum-
        // ulator zeroes it into accFeePerShareMixETH on the same call), and
        // physically held by the hook as balance − reserveMixETH. Assert the
        // HOOK FEE LEDGER (real ERC20 custody) and the STAKER ACCUMULATOR.
        uint256 accBeforeBuy = stakerV.accFeePerShareMixETH();
        uint256 feeLedgerBeforeBuy = mixETH.balanceOf(hookAddr) - hookReserve();
        vm.startPrank(alice);
        mixETH.approve(address(zapIn), 10e18);
        uint256 pspOut = zapIn.buyWithMix(_poolKey(), 10e18, 0, 0);
        vm.stopPrank();

        assertGt(pspOut, 0, "zap buy returned nothing");
        assertEq(pspToken.balanceOf(alice), pspOut, "alice did not receive the PSP");

        // unattributed trade -> the FULL 5% of volume sits in the hook's fee
        // ledger, earmarked for stakers (nothing leaked to a referral chain)
        assertEq(
            mixETH.balanceOf(hookAddr) - hookReserve() - feeLedgerBeforeBuy,
            10e18 * 500 / 10000,
            "buy fee = full 5% (unattributed)"
        );
        // ...and the staker accumulator recorded exactly that slice (floor
        // rounding in accFeePerShare += fee*1e18/totalLocked and the back-
        // multiplication caps the discrepancy far below 1e6 wei)
        assertApproxEqAbs(
            (stakerV.accFeePerShareMixETH() - accBeforeBuy) * stakerV.totalLocked() / stakerV.PRECISION(),
            10e18 * 500 / 10000,
            1e6,
            "buy fee not folded into staker accumulator"
        );

        // ── sell it all back through the real zap-out ──
        uint256 mixBefore = mixETH.balanceOf(alice);
        uint256 feeLedgerBeforeSell = mixETH.balanceOf(hookAddr) - hookReserve();
        uint256 accBeforeSell = stakerV.accFeePerShareMixETH();
        vm.startPrank(alice);
        pspToken.approve(address(zapOut), pspOut);
        uint256 mixBack = zapOut.sellToMix(_poolKey(), pspOut, 0, 0);
        vm.stopPrank();

        assertGt(mixBack, 0, "zap sell returned nothing");
        assertEq(mixETH.balanceOf(alice), mixBefore + mixBack, "alice did not receive mixETH");

        // sell fee is 5% of the GROSS out-value; mixBack is the net 95% —
        // reconcile the hook fee ledger within floor tolerance
        uint256 expectedSellFee = mixBack * 500 / 9500;
        assertApproxEqAbs(
            mixETH.balanceOf(hookAddr) - hookReserve() - feeLedgerBeforeSell,
            expectedSellFee,
            3,
            "sell fee = 5% of out-value"
        );
        assertApproxEqAbs(
            (stakerV.accFeePerShareMixETH() - accBeforeSell) * stakerV.totalLocked() / stakerV.PRECISION(),
            expectedSellFee,
            1e6,
            "sell fee not folded into staker accumulator"
        );

        // mock pm holds no dust: hook took its input, zap took its output
        assertEq(pspToken.balanceOf(address(poolManager)), 0, "PSP dust left in mock pm");
        assertEq(mixETH.balanceOf(address(poolManager)), 0, "mixETH dust left in mock pm");
    }

}
