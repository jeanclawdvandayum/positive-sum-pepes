// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BBase, BRouter, RevertingReceiver, ReentrantForward} from "./BBase.sol";
import {PSPZapIn} from "../../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../../src/PSPZapOut.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {PSPFactory} from "../../../src/PSPFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IMixETH} from "../../../src/interfaces/IMixETH.sol";

/// @title B5 — PSPZapIn / PSPZapOut against the REAL PoolManager.
contract B5_Zaps is BBase {
    PSPZapIn zapIn;
    PSPZapOut zapOut;

    function setUp() public virtual override {
        super.setUp();
        zapIn = new PSPZapIn(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));
        zapOut = new PSPZapOut(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));
        _launch(100e18);
    }

    // ── zapInBuy: wrap → swap, delivered PSP, exact accounting ──
    function test_B5a_zapInBuyHappy() public {
        vm.deal(alice, 50 ether);
        uint256 pspOut = zapInBuy(alice, 10 ether, 0);
        assertGt(pspOut, 0);
        assertEq(psp.balanceOf(alice), pspOut);
        assertEq(address(zapIn).balance, 0, "zap holds no ETH after");
        assertEq(mixETH.balanceOf(address(zapIn)), 0, "zap holds no mix after");
        assertGt(_slack(), 0);
    }

    function zapInBuy(address who, uint256 eth, uint256 minOut) internal returns (uint256) {
        vm.prank(who);
        return zapIn.zapInBuy{value: eth}(key, minOut, 0);
    }

    // ── minPspOut enforcement reverts the WHOLE tx — no partial state ──
    function test_B5b_zapInBuyMinOutRevertsCleanly() public {
        uint256 pspBefore = psp.balanceOf(alice);
        uint256 ethBefore = alice.balance;
        vm.deal(alice, 50 ether);
        ethBefore; // silence

        // fair output quote via the hook's view (ETH==mixETH 1:1 in mock).
        // (2026-08-19) getBuyOutput now mirrors execution: it applies the
        // 5% swap fee internally (curve only sees post-fee input). The old
        // pre-subtraction double-cut the fee, underquoted, and fair+1 was
        // still attainable — so nothing reverted.
        uint256 fair = hook.getBuyOutput(10e18);
        assertGt(fair, 0);

        vm.prank(alice);
        vm.expectRevert(PSPZapIn.InsufficientOutput.selector);
        zapIn.zapInBuy{value: 10 ether}(key, fair + 1, 0);

        assertEq(psp.balanceOf(alice), pspBefore, "psp changed on reverted zap");
        assertEq(alice.balance, 50 ether, "ETH not returned");
    }

    // ── buyWithMix: exact spend, revert returns everything ──
    function test_B5c_buyWithMixHappyAndRevert() public {
        vm.startPrank(alice);
        mixETH.approve(address(zapIn), 10e18);
        uint256 out = zapIn.buyWithMix(key, 10e18, 0, 0);
        vm.stopPrank();
        assertEq(psp.balanceOf(alice), out);

        // revert path
        uint256 mixBefore = mixETH.balanceOf(alice);
        vm.startPrank(alice);
        mixETH.approve(address(zapIn), 10e18);
        vm.expectRevert(PSPZapIn.InsufficientOutput.selector);
        zapIn.buyWithMix(key, 10e18, out + 1, 0); // impossible min
        vm.stopPrank();
        assertEq(mixETH.balanceOf(alice), mixBefore, "mix not returned on revert");
        assertEq(psp.balanceOf(alice), out, "psp unchanged");
    }

    // ── deadline gate ──
    function test_B5d_deadline() public {
        vm.warp(1000);
        vm.deal(alice, 50 ether);
        vm.prank(alice);
        vm.expectRevert(PSPZapIn.Expired.selector);
        zapIn.zapInBuy{value: 1 ether}(key, 0, 999);
    }

    // ── zapOut: swap → redeem → forward ETH ──
    function test_B5e_zapOutHappy() public {
        uint256 out = _buy(alice, 10e18);
        uint256 ethBefore = alice.balance;

        vm.startPrank(alice);
        psp.approve(address(zapOut), out);
        uint256 ethOut = zapOut.zapOut(key, out, 0, 0);
        vm.stopPrank();

        assertGt(ethOut, 0);
        assertEq(alice.balance - ethBefore, ethOut, "ETH not forwarded exactly");
        assertEq(psp.balanceOf(alice), 0);
        assertEq(address(zapOut).balance, 0, "zap holds no ETH");
    }

    // ── reverting ETH receiver → EthForwardFailed, everything rolled back ──
    function test_B5f_zapOutRevertingReceiver() public {
        RevertingReceiver rr = new RevertingReceiver();
        uint256 out = _buy(alice, 10e18);

        vm.prank(alice);
        psp.transfer(address(rr), out);
        vm.startPrank(address(rr));
        psp.approve(address(zapOut), out);
        vm.expectRevert(PSPZapOut.EthForwardFailed.selector);
        zapOut.zapOut(key, out, 0, 0);
        vm.stopPrank();

        // rolled back: rr still holds its PSP, zap holds nothing
        assertEq(psp.balanceOf(address(rr)), out, "PSP not returned");
        assertEq(address(zapOut).balance, 0, "ETH stuck in zap");
        assertEq(mixETH.balanceOf(address(zapOut)), 0, "mix stuck in zap");
    }

    // ── reentrancy during ETH forward: nested zapOut completes independently ──
    function test_B5g_zapOutReentrancyInForward() public {
        ReentrantForward rf = new ReentrantForward();
        rf.set(zapOut, address(psp), key);

        uint256 out1 = _buy(alice, 10e18);
        vm.prank(alice);
        psp.transfer(address(rf), out1);

        uint256 rfEthBefore = address(rf).balance;
        rf.sell(out1);
        assertGt(address(rf).balance, rfEthBefore, "no ETH received");
        assertEq(rf.reenterCalls(), 1, "reentry executed");
        assertEq(psp.balanceOf(address(rf)), 0, "rf still holds PSP");
        assertEq(address(zapOut).balance, 0, "zap holds residual ETH");
        // hook state consistent
        assertGt(_slack(), 0);
        assertGe(mixETH.balanceOf(address(hook)), hook.reserveMixETH());
    }

    // ── sellToMix ──
    function test_B5h_sellToMix() public {
        uint256 out = _buy(alice, 10e18);
        uint256 mixBefore = mixETH.balanceOf(alice);
        vm.startPrank(alice);
        psp.approve(address(zapOut), out);
        uint256 mixOut = zapOut.sellToMix(key, out, 0, 0);
        vm.stopPrank();
        assertGt(mixOut, 0);
        assertEq(mixETH.balanceOf(alice) - mixBefore, mixOut, "mix not delivered exactly");
        assertEq(psp.balanceOf(alice), 0);

        // min enforcement
        uint256 out2 = _buy(alice, 5e18);
        vm.startPrank(alice);
        psp.approve(address(zapOut), out2);
        vm.expectRevert(PSPZapOut.InsufficientOutput.selector);
        zapOut.sellToMix(key, out2, type(uint256).max, 0);
        vm.stopPrank();
        assertEq(psp.balanceOf(alice), out2, "PSP returned on minOut revert");
    }

    // ── donations to the zaps are neither stolen nor spent (dust-stuck) ──
    function test_B5i_donationsNotStolenNotSpent() public {
        // donate ETH + mix to zapOut, mix to zapIn
        (bool ok,) = address(zapOut).call{value: 1 ether}("");
        assertTrue(ok);
        mixETH.transfer(address(zapOut), 5e18);
        mixETH.transfer(address(zapIn), 5e18);

        uint256 out = _buy(alice, 10e18);
        vm.prank(alice);
        psp.transfer(address(zapIn), 1e15); // PSP donation to zapIn

        // alice sells via zapOut: forwarded ETH must be ONLY her redeem delta
        vm.startPrank(alice);
        psp.approve(address(zapOut), out - 1e15);
        uint256 ethOut = zapOut.zapOut(key, out - 1e15, 0, 0);
        vm.stopPrank();

        assertEq(address(zapOut).balance, 1 ether, "donated ETH stolen by user");
        assertEq(mixETH.balanceOf(address(zapOut)), 5e18, "donated mix spent");

        // zapIn with donated mix+PSP present: user's buy must use only their own wrap
        vm.deal(alice, 20 ether);
        uint256 psp2 = zapInBuy(alice, 10 ether, 0);
        assertGt(psp2, 0);
        assertEq(mixETH.balanceOf(address(zapIn)), 5e18, "donated mix swapped");
        assertEq(psp.balanceOf(address(zapIn)), 1e15, "donated PSP spent");
    }

    // ── zapInPredeposit: full predeposit flow, no leftover approval ──
    function test_B5j_zapInPredeposit() public {
        // fresh round in Predeposit mode: deploy second round
        PSPFactory.RoundParams memory params =
            PSPFactory.RoundParams({name: "C", symbol: "C2", curveConfig: _curve()});
        (uint256 rid,) = factory.deployRound(params);
        PSPFactory.Round memory r = factory.getRound(rid);
        RoundController c2 = RoundController(address(r.controller));

        vm.deal(alice, 50 ether);
        vm.prank(alice);
        uint256 shares = zapIn.zapInPredeposit{value: 10 ether}(c2, 0);
        assertEq(shares, 10 ether, "mock vault is 1:1");
        assertEq(mixETH.allowance(address(zapIn), address(c2)), 0, "leftover approval");
        assertEq(mixETH.balanceOf(address(zapIn)), 0, "zap holds no mix");
    }
}
