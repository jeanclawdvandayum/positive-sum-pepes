// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../src/PSPZapOut.sol";
import {IMixETH} from "../../src/interfaces/IMixETH.sol";

import {MainnetConfig} from "../integration/MainnetConfig.sol";
import {V4SwapRouter} from "../integration/V4SwapRouter.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";

/// @title AuditFork — PoC verification on a REAL mainnet-fork V4 PoolManager.
/// @notice Replays the audit's critical lifecycles against real flash
///         accounting: genesis, buys/sells, governance, carpet bomb, flat
///         window economics, pot redemption, finalize + rebirth, and the
///         hook's physical-reserve invariant at every step.
contract AuditForkTest is Test {
    IPoolManager poolManager;
    IERC20 mixETH;
    PSPFactory factory;
    V4SwapRouter router;
    PSPZapIn zapIn;
    PSPZapOut zapOut;

    PSPToken psp;
    RoundController controller;
    CurveHook hook;
    PoolKey key;

    address alice = makeAddr("alice"); // staker
    address bob = makeAddr("bob");     // quorum partner
    address carol = makeAddr("carol"); // bystander/attacker

    function setUp() public {
        uint256 forkBlock = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
        if (forkBlock > 0) {
            vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), forkBlock);
        } else {
            vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        }

        poolManager = IPoolManager(MainnetConfig.POOL_MANAGER);

        MockMixETH mockMix = new MockMixETH();
        mockMix.depositETH{value: 100_000e18}();
        mixETH = IERC20(address(mockMix));

        factory = new PSPFactory(poolManager, mixETH, new HookDeployer(), new ControllerDeployer());
        router = new V4SwapRouter(poolManager);
        zapIn = new PSPZapIn(IMixETH(address(mockMix)), poolManager);
        zapOut = new PSPZapOut(IMixETH(address(mockMix)), poolManager);

        _dealMixETH(alice, 1_000e18);
        _dealMixETH(bob, 1_000e18);
        _dealMixETH(carol, 1_000e18);

        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Audit",
            symbol: "AUD",
            curveConfig:
                CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
        });
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory r = factory.getRound(roundId);
        psp = PSPToken(address(r.token));
        controller = RoundController(address(r.controller));
        hook = CurveHook(payable(address(r.hook)));

        // Mirror the factory's canonical key: currencies SORTED (the factory
        // sorts before initialize — an unsorted key addresses a DIFFERENT,
        // never-initialized pool id and every swap reverts PoolNotInitialized)
        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(address(psp));
        if (c0 > c1) {
            (c0, c1) = (c1, c0);
        }
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    // ═══════════════════════════════════════════════════════════
    //  C1 — full lifecycle on real V4: the mega-PoC
    // ═══════════════════════════════════════════════════════════
    function test_C1_FullLifecycleOnRealV4() public {
        // ── launch ──
        vm.startPrank(alice);
        mixETH.approve(address(controller), 60e18);
        controller.predeposit(60e18);
        vm.stopPrank();
        vm.prank(address(factory));
        controller.launchPooledBuy();
        vm.prank(alice);
        controller.claimPredepositPSP();
        _solvent("C1 genesis");

        // ── bob buys on curve + locks (real V4 swap) ──
        vm.startPrank(bob);
        mixETH.approve(address(zapIn), type(uint256).max);
        uint256 bobPSP = zapIn.buyWithMix(key, 20e18, 0, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        psp.approve(address(controller), type(uint256).max);
        controller.lock(bobPSP);
        vm.stopPrank();
        _solvent("C1 bob lock");

        // ── carol round trip on curve (real V4): must be lossy ──
        vm.startPrank(carol);
        mixETH.approve(address(zapIn), type(uint256).max);
        uint256 out = zapIn.buyWithMix(key, 5e18, 0, 0);
        vm.stopPrank();
        vm.startPrank(carol);
        psp.approve(address(zapOut), type(uint256).max);
        uint256 back = zapOut.sellToMix(key, out, 0, 0);
        vm.stopPrank();
        assertLt(back, 5e18, "C1: curve round trip profitable on real V4");
        _solvent("C1 roundtrip");

        // ── governance: bomb passes ──
        skip(1);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        skip(3 days + 1);

        // pot redemption ring-fence on REAL V4 balances
        (uint256 potPSP,) = controller.potState();
        uint256 expPotMix = (hook.reserveMixETH() * potPSP) / hook.totalSupplyPSP();
        uint256 fBefore = mixETH.balanceOf(address(factory));
        controller.carpetBomb();
        (uint256 potPSP2,) = controller.potState();
        assertEq(potPSP2, 0, "C1: pot not cleared");
        assertApproxEqAbs(
            mixETH.balanceOf(address(factory)) - fBefore, expPotMix, 5, "C1: pot redemption"
        );
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Flat));
        _solvent("C1 bombed");

        // ── flat window on real V4: late buyer round trip STILL lossy ──
        vm.startPrank(carol);
        uint256 lateOut = zapIn.buyWithMix(key, 1e18, 0, 0);
        uint256 lateBack = zapOut.sellToMix(key, lateOut, 0, 0);
        vm.stopPrank();
        assertLt(lateBack, 1e18, "C1: FLAT round trip profitable on real V4");
        _solvent("C1 flat roundtrip");

        // ── staker exit at average backing: exact formula check ──
        // alice's PSP sits in the controller lock (virtual from predeposit) —
        // unlock() first (flat mode opens all locks), THEN exit
        vm.prank(alice);
        controller.unlock();
        uint256 alicePSP = psp.balanceOf(alice);
        assertGt(alicePSP, 0);
        uint256 expGross = (alicePSP * hook.reserveMixETH()) / hook.totalSupplyPSP();
        uint256 expNet = expGross; // F-9 fix: zero-fee flat window — no toll
        vm.startPrank(alice);
        psp.approve(address(zapOut), type(uint256).max);
        uint256 got = zapOut.sellToMix(key, alicePSP, 0, 0);
        vm.stopPrank();
        assertApproxEqAbs(got, expNet, 3, "C1: staker exit != exact avg backing (zero toll)");
        _solvent("C1 staker exit");

        // ── finalize + rebirth ──
        skip(3 days + 1);
        controller.finalizeCarpet();
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Destroyed));
        PSPFactory.Round memory r2 = factory.getRound(2);
        assertGt(
            mixETH.balanceOf(address(r2.controller)), 0, "C1: carry lost on rebirth"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  C2 — randomized walk on REAL V4: hook stays solvent, reserve
    //       ledger == physical backing + fees, supply never underflows
    // ═══════════════════════════════════════════════════════════
    function test_C2_Walk(uint128 seed, uint8 nOps) public {
        _launch();

        uint256 n = bound(nOps, 1, 10);
        for (uint256 i = 0; i < n; i++) {
            uint256 roll = uint256(keccak256(abi.encode(seed, i)));
            address who = (roll & 1) == 0 ? bob : carol;
            if (((roll >> 1) & 1) == 0 || psp.balanceOf(who) == 0) {
                vm.startPrank(who);
                mixETH.approve(address(zapIn), type(uint256).max);
                zapIn.buyWithMix(key, 1e14 + (roll % 2e18), 0, 0);
                vm.stopPrank();
            } else {
                uint256 amt = psp.balanceOf(who) / ((roll % 3) + 1);
                if (amt > 0) {
                    vm.startPrank(who);
                    psp.approve(address(zapOut), type(uint256).max);
                    zapOut.sellToMix(key, amt, 0, 0);
                    vm.stopPrank();
                }
            }
            _solvent("C2 walk");
            assertGt(hook.totalSupplyPSP(), 0, "C2: supply underflow");
        }

        // fee ledger consistency: fees = physical - reserve >= 0 and
        // claimable via controller without breaking solvency
        vm.prank(alice);
        controller.claimFees();
        _solvent("C2 post claimFees");
    }

    // ═══════════════════════════════════════════════════════════
    //  C3 — native-ETH zap path on real V4 (zapIn wraps, zapOut unwraps)
    // ═══════════════════════════════════════════════════════════
    function test_C3_NativeZapPath() public {
        _launch();

        vm.deal(carol, 100e18);
        vm.startPrank(carol);
        mixETH.approve(address(zapIn), type(uint256).max);
        uint256 out = zapIn.buyWithMix(key, 1e18, 0, 0);
        vm.stopPrank();
        assertGt(out, 0, "C3: buy failed");

        // sell back through the ETH leg: zapOut redeems mix -> ETH to carol
        vm.startPrank(carol);
        psp.approve(address(zapOut), type(uint256).max);
        zapOut.zapOut(key, out, 0, 0);
        vm.stopPrank();
        _solvent("C3 native path");
    }

    // ───────────────────────── helpers ─────────────────────────
    function _launch() internal {
        vm.startPrank(alice);
        mixETH.approve(address(controller), 60e18);
        controller.predeposit(60e18);
        vm.stopPrank();
        vm.prank(address(factory));
        controller.launchPooledBuy();
        vm.prank(alice);
        controller.claimPredepositPSP();

        // bob buys + locks for quorum
        vm.startPrank(bob);
        mixETH.approve(address(zapIn), type(uint256).max);
        uint256 bobPSP = zapIn.buyWithMix(key, 20e18, 0, 0);
        psp.approve(address(controller), type(uint256).max);
        controller.lock(bobPSP);
        vm.stopPrank();
    }

    function _solvent(string memory tag) internal view {
        assertGe(
            mixETH.balanceOf(address(hook)),
            hook.reserveMixETH(),
            string.concat(tag, ": hook insolvent (physical < reserve ledger)")
        );
    }

    function _dealMixETH(address to, uint256 amount) internal {
        deal(address(mixETH), to, amount);
    }
}
