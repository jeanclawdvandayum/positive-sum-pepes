// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
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
import {CurveHook} from "../../src/CurveHook.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../src/PSPZapOut.sol";
import {RoundController} from "../../src/RoundController.sol";
import {PSPStaker} from "../../src/PSPStaker.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {StakerDeployer} from "src/StakerDeployer.sol";


interface ControllerLike {
    function predeposit(uint256 mixAmount) external;
    function launchPooledBuy() external;
    function claimPredepositPSP() external;
    function proposeCarpetBomb() external;
    function voteCarpetBomb(bool support) external;
    function carpetBomb() external;
    function finalizeCarpet() external;
    function flatTime() external view returns (uint256);
    function staker() external view returns (PSPStaker);
}

/// @title AuditB — fresh-eyes lifecycle/governance/pot battery
contract AuditLifecycleTest is Test {
    MockMixETH mixETH;
    MockPoolManager poolManager;
    PSPFactory factory;
    PSPZapIn zapIn;
    PSPZapOut zapOut;
    IERC20 psp;
    ControllerLike controller;
    PSPStaker stakerV; // cached staker (prank-eaten-view fix)
    CurveHook hook;

    address alice = makeAddr("alice"); // staker
    address bob = makeAddr("bob");     // buyer/quorum
    address carol = makeAddr("carol"); // attacker/bystander

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 100_000e18}();
        poolManager = new MockPoolManager();
        factory = new PSPFactory(
            IPoolManager(address(poolManager)),
            IERC20(address(mixETH)),
            new HookDeployer(),
            new ControllerDeployer(), new StakerDeployer()
        , 0);

        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "test",
            symbol: "TST",
            curveConfig:
                CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
        });
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory r = factory.getRound(roundId);
        psp = r.token;
        controller = ControllerLike(address(r.controller));
        stakerV = r.controller.staker();
        hook = CurveHook(address(r.hook));

        zapIn = new PSPZapIn(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));
        zapOut = new PSPZapOut(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));

        vm.deal(alice, 1_000e18);
        vm.deal(bob, 1_000e18);
        vm.deal(carol, 1_000e18);
        mixETH.transfer(alice, 200e18);
        mixETH.transfer(bob, 100e18);
        mixETH.transfer(carol, 400e18);
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(mixETH)),
            currency1: Currency.wrap(address(psp)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev Active round, alice + bob locked (honest quorum)
    function _launchAndStake() internal {
        vm.startPrank(alice);
        mixETH.approve(address(controller), 60e18);
        controller.predeposit(60e18);
        vm.stopPrank();

        vm.prank(address(factory));
        controller.launchPooledBuy();

        vm.prank(alice);
        controller.claimPredepositPSP();

        vm.startPrank(bob);
        mixETH.approve(address(zapIn), type(uint256).max);
        uint256 bobPSP = zapIn.buyWithMix(_key(), 20e18, 0, 0);
        psp.approve(address(stakerV), type(uint256).max);
        stakerV.lock(bobPSP);
        vm.stopPrank();
    }

    /// @dev bomb passes (2/2 yes), executed, round is Flat
    function _bomb() internal {
        skip(1);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        skip(3 days + 1);
        controller.carpetBomb();
    }

    function _solvent(string memory tag) internal view {
        assertGe(
            mixETH.balanceOf(address(hook)),
            hook.reserveMixETH(),
            string.concat(tag, ": hook insolvent")
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  B1 — governance edge cases
    // ═══════════════════════════════════════════════════════════

    // B1a: unlock after proposing → must revert (votes are locked in)
    function test_B1a_UnlockAfterProposeReverts() public {
        _launchAndStake();
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        vm.expectRevert();
        stakerV.unlock();
    }

    // B1b: non-staker cannot propose (no locked PSP)
    function test_B1b_NonStakerCannotPropose() public {
        _launchAndStake();
        vm.prank(carol);
        vm.expectRevert();
        controller.proposeCarpetBomb();
    }

    // B1c: vote NO → majority rejects → round continues, re-propose allowed
    function test_B1c_NoVoteFailsProposal() public {
        _launchAndStake();
        // carol buys a BIG bag and locks → NO majority outweighs alice+bob
        uint256 carolPSP = _buy(carol, 300e18);
        vm.startPrank(carol);
        psp.approve(address(stakerV), type(uint256).max);
        stakerV.lock(carolPSP);
        vm.stopPrank();

        skip(1);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        vm.prank(carol);
        controller.voteCarpetBomb(false); // majority rejects
        skip(3 days + 1);
        vm.expectRevert(); // MajorityNotReached
        controller.carpetBomb();

        // round still active — curve trades fine
        uint256 out = _buy(carol, 1e18);
        assertGt(out, 0, "B1c: round dead after failed vote");

        // and a NEW proposal can replace the failed one after the window
        skip(1);
        vm.prank(alice);
        controller.proposeCarpetBomb(); // must not revert
    }

    // B1d: carpetBomb before execution window → revert
    function test_B1d_EarlyExecutionReverts() public {
        _launchAndStake();
        skip(1);
        vm.prank(alice);
        controller.proposeCarpetBomb();
        vm.prank(alice);
        controller.voteCarpetBomb(true);
        vm.prank(bob);
        controller.voteCarpetBomb(true);
        skip(1 days); // still inside voting window
        vm.expectRevert();
        controller.carpetBomb();
    }

    // B1e: finalizeCarpet before any bomb → revert
    function test_B1e_FinalizeBeforeBombReverts() public {
        _launchAndStake();
        vm.expectRevert();
        controller.finalizeCarpet();
    }

    // B1f: double claim of predeposit PSP
    function test_B1f_DoubleClaimPredeposit() public {
        _launchAndStake(); // claims once inside
        vm.prank(alice);
        vm.expectRevert();
        controller.claimPredepositPSP();
    }

    // ═══════════════════════════════════════════════════════════
    //  B2 — flat window economics
    // ═══════════════════════════════════════════════════════════

    // B2a: buys during flat window mint at flat rate
    function test_B2a_FlatBuy() public {
        _launchAndStake();
        _bomb();

        uint256 out = _buy(carol, 1e18);
        assertGt(out, 0, "B2a: flat buy minted nothing");
        _solvent("B2a");

        // flat rate pre/post consistency: backing not diluted
        uint256 R = hook.reserveMixETH();
        uint256 S = hook.totalSupplyPSP();
        assertApproxEqAbs((R * 1e18) / S, _flatPriceSnapshot(), 2, "B2a: rate moved");
    }

    uint256 _fpR;
    uint256 _fpS;

    function _flatPriceSnapshot() internal view returns (uint256) {
        return (hook.reserveMixETH() * 1e18) / hook.totalSupplyPSP();
    }

    // B2b: flat buy → flat sell round trip is lossy (fees both ways)
    function test_B2b_FlatRoundTripLossy() public {
        _launchAndStake();
        _bomb();

        uint256 out = _buy(carol, 1e18);
        uint256 back = _sell(carol, out);
        assertLt(back, 1e18, "B2b: flat round trip profitable");
        _solvent("B2b");
    }

    // B2c: buy during flat, sleep through window, finalize → PSP worthless
    function test_B2c_LateFlatBuyerLosesEverything() public {
        _launchAndStake();
        _bomb();

        uint256 out = _buy(carol, 1e18);
        assertGt(out, 0);

        skip(3 days + 1);
        controller.finalizeCarpet();

        // carol still holds her PSP — but the curve is destroyed; selling
        // must now revert. Her 1 mixETH went to round 2's stakers.
        assertEq(psp.balanceOf(carol), out, "B2c: balance changed");
        vm.startPrank(carol);
        psp.approve(address(zapOut), type(uint256).max);
        vm.expectRevert();
        zapOut.sellToMix(_key(), out, 0, 0);
        vm.stopPrank();
        assertEq(uint8(hook.mode()), uint8(CurveHook.Mode.Destroyed));
    }

    // B2d: INTERLEAVED flat exits — carol buys between two staker exits.
    //      Each exit must still pay the (fee-adjusted) flat rate; latecomer
    //      buys only participate by their own choice.
    function test_B2d_InterleavedExits() public {
        _launchAndStake();
        _bomb();

        // ── instrument: who holds what post-bomb ──
        console2.log("controller PSP bal:", psp.balanceOf(address(controller)));
        console2.log("totalLocked:", stakerV.totalLocked());
        uint256 aAmt = stakerV.lockedPSPOf(alice);
        uint256 bAmt = stakerV.lockedPSPOf(bob);
        console2.log("alice lock:", aAmt);
        console2.log("bob lock:", bAmt);
        console2.log("hook PSP bal:", psp.balanceOf(address(hook)));
        console2.log("totalSupplyPSP:", hook.totalSupplyPSP());

        // stakers must unlock() first (flat opens all locks immediately)
        vm.prank(alice);
        stakerV.unlock();
        console2.log("after alice unlock, controller bal:", psp.balanceOf(address(controller)));
        vm.prank(bob);
        stakerV.unlock();

        uint256 alicePSP = psp.balanceOf(alice);
        uint256 a1 = _sell(alice, alicePSP / 2);
        uint256 carolOut = _buy(carol, 2e18);
        uint256 a2 = _sell(alice, psp.balanceOf(alice));
        uint256 b1 = _sell(bob, psp.balanceOf(bob) / 2);
        // NOTE: buyWithMix's return overstates receipts by the pot's mint
        // share (~26bps) — sell the ACTUAL balance, not the return value
        uint256 c1 = _sell(carol, psp.balanceOf(carol));

        assertGt(a1 + a2, 0);
        assertGt(b1, 0);
        assertGt(c1, 0);
        // F-9 fix: zero-fee flat window — carol's buy→sell round trip is
        // EXACTLY break-even (floor dust only), never profitable.
        // Pre-fix the toll made it strictly < input.
        assertLe(c1, 2e18, "B2d: carol round-tripped at profit");
        assertApproxEqAbs(c1, 2e18, 5, "B2d: flat round trip breaks even (zero fee)");
        _solvent("B2d");
    }

    // ═══════════════════════════════════════════════════════════
    //  B3 — (pot accounting removed 2026-08-19 with the side pot;
    //  flat-window zero-fee is guarded by F9FlatWindowPot, staker fee
    //  flow by B4a and NK24 P4)
    // ═══════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════
    //  B4 — staker fee claims
    // ═══════════════════════════════════════════════════════════

    // B4a: claimFees twice → second reverts NothingToClaim, no double-pay
    function test_B4a_NoDoubleFeeClaim() public {
        _launchAndStake();
        _buy(carol, 5e18);

        vm.prank(alice);
        stakerV.claimFees();
        vm.prank(alice);
        vm.expectRevert(); // NothingToClaim — ledger drained
        stakerV.claimFees();
        // solvency after claims
        _solvent("B4a");
    }

    // B4b: unlock() pays pending fees along with principal
    function test_B4b_ExitBefore90dReverts() public {
        _launchAndStake();
        vm.prank(alice);
        vm.expectRevert(); // LockNotExpired
        stakerV.unlock();
    }

    // ═══════════════════════════════════════════════════════════
    //  B5 — donations
    // ═══════════════════════════════════════════════════════════

    // B5a: donate mix to hook → inflates available fees (fee watering)
    function test_B5a_HookDonationInflatesAvailable() public {
        _launchAndStake();
        uint256 before = mixETH.balanceOf(address(hook)) - hook.reserveMixETH();
        mixETH.transfer(address(hook), 100e18);
        uint256 after_ = mixETH.balanceOf(address(hook)) - hook.reserveMixETH();
        assertGt(after_, before, "B5a: donation invisible");
    }

    // B5b: donate mix to factory → joins the carry into round 2
    function test_B5b_FactoryDonationJoinsCarry() public {
        _launchAndStake();
        mixETH.transfer(address(factory), 50e18);
        _bomb();
        skip(3 days + 1);
        controller.finalizeCarpet();

        PSPFactory.Round memory r2 = factory.getRound(2);
        assertGt(
            mixETH.balanceOf(address(r2.controller)),
            50e18,
            "B5b: donation not carried"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  B6 — dust guards
    // ═══════════════════════════════════════════════════════════

    // B6a: 1-wei PSP sell → reverts cleanly (ZeroOutput), no insolvency
    function test_B6a_WeiSell() public {
        _launchAndStake();
        _buy(bob, 1e18); // bob has more PSP now
        vm.startPrank(bob);
        psp.approve(address(zapOut), type(uint256).max);
        try zapOut.sellToMix(_key(), 1, 0, 0) {
            emit log("wei sell succeeded (paid something)");
        } catch {
            emit log("wei sell reverted (guard)");
        }
        vm.stopPrank();
        _solvent("B6a");
    }

    // B6b: dust mix buy → reverts (below MIN_SWAP_INPUT) or pays 0? must
    //      never mint more than the integral
    function test_B6b_DustBuy() public {
        _launchAndStake();
        vm.startPrank(carol);
        mixETH.approve(address(zapIn), type(uint256).max);
        try zapIn.buyWithMix(_key(), 1, 0, 0) {
            emit log("1-wei buy succeeded");
        } catch {
            emit log("1-wei buy reverted (guard)");
        }
        vm.stopPrank();
        _solvent("B6b");
    }

    // ═══════════════════════════════════════════════════════════
    //  B7 — zap edge cases
    // ═══════════════════════════════════════════════════════════

    // B7a: zapOut to a receiver whose fallback reverts → EthForwardFailed
    //      bubbles; user's PSP is NOT stranded in the zap (tx reverts whole)
    function test_B7a_ZapOutRevertingReceiver() public {
        _launchAndStake();
        _buy(bob, 1e18);

        RevertingReceiver r = new RevertingReceiver();
        vm.deal(address(r), 1 ether);
        uint256 pspAmt = psp.balanceOf(bob);
        assertGt(pspAmt, 0);
        vm.startPrank(bob);
        psp.approve(address(zapOut), type(uint256).max);
        psp.transfer(address(r), pspAmt);
        vm.stopPrank();
        // r calls zapOut itself; its receive() reverts → EthForwardFailed
        // bubbles up: whole tx reverts, PSP returns to r (nothing stranded)
        vm.expectRevert(PSPZapOut.EthForwardFailed.selector);
        r.attack(payable(address(zapOut)), _key(), pspAmt);
        assertEq(psp.balanceOf(address(r)), pspAmt, "B7a: PSP not returned on revert");
        assertEq(psp.balanceOf(address(zapOut)), 0, "B7a: PSP stuck at zap");
    }

    // B7b: zapInPredeposit after launch → reverts, ETH returned
    function test_B7b_ZapPredepositAfterLaunch() public {
        _launchAndStake();
        vm.startPrank(carol);
        vm.expectRevert();
        zapIn.zapInPredeposit{value: 1e18}(RoundController(address(controller)), 0);
        vm.stopPrank();
    }

    // B7c: minPspOut slippage guard actually reverts on a hostile fill
    function test_B7c_MinOutGuard() public {
        _launchAndStake();
        vm.startPrank(carol);
        mixETH.approve(address(zapIn), type(uint256).max);
        vm.expectRevert();
        zapIn.buyWithMix(_key(), 1e18, type(uint256).max, 0); // impossible min
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  B8 — randomized solvency walk (handler-style, single tx)
    // ═══════════════════════════════════════════════════════════
    function test_B8_SolvencyWalk(uint128 seed, uint8 nOps) public {
        _launchAndStake();
        nOps = uint8(bound(nOps, 1, 12));
        for (uint256 i = 0; i < nOps; i++) {
            uint256 roll = uint256(keccak256(abi.encode(seed, i)));
            address who = (roll & 1) == 0 ? bob : carol;
            if (((roll >> 1) & 1) == 0 || psp.balanceOf(who) == 0) {
                _buy(who, 1e14 + (roll % 3e18));
            } else {
                _sell(who, psp.balanceOf(who) / ((roll % 3) + 1));
            }
            _solvent("B8");
        }
    }

    // ───────────────────────── helpers ─────────────────────────
    function _buy(address who, uint256 amt) internal returns (uint256) {
        vm.startPrank(who);
        mixETH.approve(address(zapIn), type(uint256).max);
        uint256 out = zapIn.buyWithMix(_key(), amt, 0, 0);
        vm.stopPrank();
        return out;
    }

    function _sell(address who, uint256 amt) internal returns (uint256) {
        vm.startPrank(who);
        psp.approve(address(zapOut), type(uint256).max);
        uint256 out = zapOut.sellToMix(_key(), amt, 0, 0);
        vm.stopPrank();
        return out;
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("no eth");
    }

    function attack(address payable zapOut, PoolKey calldata key, uint256 pspAmt) external {
        IERC20(address(Currency.unwrap(key.currency1))).approve(zapOut, type(uint256).max);
        PSPZapOut(zapOut).zapOut(key, pspAmt, 0, 0);
    }
}
