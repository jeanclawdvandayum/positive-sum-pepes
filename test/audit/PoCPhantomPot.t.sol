// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {PSPFactory} from "../../src/PSPFactory.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../src/PSPZapOut.sol";
import {IMixETH} from "../../src/interfaces/IMixETH.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

/// @title PoC — H-1: Phantom pot PSP shortfall
/// @notice Buy-side pot PSP is credited to a LEDGER (mintPotPSP) but never
///         minted as ERC20, while the hook's supply ledger counts it. At
///         carpetBomb the controller burns potPSPBalance REAL PSP from its
///         wallet — which contains only staker principal. Result: the
///         controller's PSP wallet ends short of totalLocked by exactly the
///         accumulated phantom pot PSP; the LAST staker(s) to unlock are
///         bricked (ERC20InsufficientBalance on unlock, permanent).
///
///         This test PASSES while the bug exists (documents the shortfall)
///         and will FAIL once fixed (assertion of the shortfall flips).
contract PoCPhantomPotTest is Test {
    MockMixETH mix;
    MockPoolManager pm;
    PSPFactory factory;
    PSPZapIn zapIn;
    PSPZapOut zapOut;

    IERC20 psp;
    RoundController controller;
    CurveHook hook;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    PoolKey key;

    function setUp() public {
        pm = new MockPoolManager();
        mix = new MockMixETH();
        mix.depositETH{value: 1_000e18}();

        factory = new PSPFactory(
            IPoolManager(address(pm)),
            IERC20(address(mix)),
            new HookDeployer(),
            new ControllerDeployer()
        , 0);
        zapIn = new PSPZapIn(IMixETH(address(mix)), IPoolManager(address(pm)));
        zapOut = new PSPZapOut(IMixETH(address(mix)), IPoolManager(address(pm)));

        vm.deal(alice, 100e18);
        vm.deal(bob, 100e18);
        mix.transfer(alice, 100e18);
        mix.transfer(bob, 100e18);

        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "PoC",
            symbol: "POC",
            curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 4_600_000_000, 0.05e18)
        });
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory r = factory.getRound(roundId);
        psp = IERC20(address(r.token));
        controller = RoundController(address(r.controller));
        hook = CurveHook(payable(address(r.hook)));

        key = PoolKey({
            currency0: Currency.wrap(address(mix)),
            currency1: Currency.wrap(address(psp)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function test_PhantomPotShortfallBricksLastUnlocker() public {
        // ── launch: alice predeposits 60 mix (genesis lock), bob buys 20 ──
        vm.startPrank(alice);
        mix.approve(address(controller), 60e18);
        controller.predeposit(60e18);
        vm.stopPrank();
        vm.prank(address(factory));
        controller.launchPooledBuy();
        vm.prank(alice);
        controller.claimPredepositPSP();

        vm.startPrank(bob);
        mix.approve(address(zapIn), type(uint256).max);
        uint256 bobPSP = zapIn.buyWithMix(key, 20e18, 0, 0);
        psp.approve(address(controller), type(uint256).max);
        controller.lock(bobPSP);
        vm.stopPrank();

        // Pre-bomb invariant: controller wallet covers ALL lock obligations
        // (plus real pot PSP: genesis pot share + sell-path cuts)
        assertGe(
            psp.balanceOf(address(controller)),
            controller.totalLocked(),
            "pre-bomb: wallet < totalLocked already"
        );

        uint256 walletBefore = psp.balanceOf(address(controller));
        uint256 lockedBefore = controller.totalLocked();
        uint256 potLedger = controller.potPSPBalance();
        uint256 walletSlack = walletBefore - lockedBefore; // real pot PSP held
        console2.log("wallet before:", walletBefore);
        console2.log("locked before:", lockedBefore);
        console2.log("pot ledger:  ", potLedger);
        console2.log("real slack:  ", walletSlack);

        // ── bomb passes ──
        skip(1);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        skip(3 days + 1);
        controller.carpetBomb();

        // ── post-bomb: wallet must still cover totalLocked. H-1 FIXED ──
        uint256 walletAfter = psp.balanceOf(address(controller));
        uint256 lockedAfter = controller.totalLocked();
        console2.log("wallet after: ", walletAfter);
        console2.log("locked after: ", lockedAfter);
        console2.log("pot ledger:  ", controller.potPSPBalance());

        // H-1 regression: the burn of potPSPBalance must consume ONLY the
        // pot's real PSP — staker principal untouched
        assertGe(
            walletAfter,
            lockedAfter,
            "H-1 REGRESSION: wallet < totalLocked after bomb (phantom pot PSP)"
        );
        assertEq(
            walletAfter,
            lockedAfter,
            "H-1: bomb should burn exactly the pot ledger, leaving principal"
        );
        assertEq(controller.potPSPBalance(), 0, "H-1: pot ledger not cleared");

        // ── THE BRICK, UNBRICKED: every staker unlocks, including the LAST ──
        vm.prank(alice);
        controller.unlock();

        vm.prank(bob);
        controller.unlock(); // last locker: must NOT revert

        // both positions now free PSP in wallets, zero residual locks
        assertEq(controller.totalLocked(), 0, "locks remain after full unlock");
        (uint256 bobStill,,, ) = controller.locks(bob);
        assertEq(bobStill, 0, "bob lock not cleared");
        assertGt(psp.balanceOf(bob), 0, "bob got nothing out");
    }
}
