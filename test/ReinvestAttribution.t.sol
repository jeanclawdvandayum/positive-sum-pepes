// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RealV4Base} from "./RealV4Lifecycle.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PSPReinvestor} from "../src/PSPReinvestor.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {PSPZapIn} from "../src/PSPZapIn.sol";
import {IPSPStaker} from "../src/interfaces/IPSPStaker.sol";
import {IPSPZapIn} from "../src/interfaces/IPSPZapIn.sol";

/// @title ReinvestAttributionTest
/// @notice AUD-14: real-V4 reinvestment keeps economic and event ownership.
contract ReinvestAttributionTest is RealV4Base {
    PSPReinvestor reinvestor;
    PSPStaker staking;
    address operator = makeAddr("reinvest-operator");
    uint256 ownerId;

    function setUp() public override {
        super.setUp();
        staking = controller.staker();
        reinvestor = new PSPReinvestor(IPSPStaker(address(staking)), IPSPZapIn(address(zapIn)),
            IERC20(address(mixETH)), IERC20(address(pspToken)));
        vm.startPrank(bob);
        controller.claimPredepositPSP();
        ownerId = staking.primaryOf(bob);
        staking.setApprovalForAll(address(reinvestor), true);
        staking.setApprovalForAll(operator, true);
        vm.stopPrank();
        // Alice is the owner's recorded referrer; the operator has no referral.
        mixETH.transfer(alice, 2e18);
        vm.startPrank(alice);
        mixETH.approve(address(zapIn), 2e18);
        uint256 bought = zapIn.buyWithMix(poolKey, 2e18, 1, block.timestamp);
        pspToken.approve(address(staking), bought);
        staking.lockWithPepe(bought, 777);
        vm.stopPrank();
        vm.startPrank(bob); hook.referralRegistry().record(777); vm.stopPrank();
        mixETH.approve(address(zapIn), type(uint256).max);
    }

    function test_OwnerReinvestCreditsSeatsEventsReferralsAndPot() public { _exercise(false, false); }
    function test_OperatorReinvestCreditsOwnerNotCallerOrOrigin() public { _exercise(false, true); }
    function test_OwnerBatchReinvestCreditsSeatsEventsReferralsAndPot() public { _exercise(true, false); }
    function test_OperatorBatchReinvestCreditsOwnerNotCallerOrOrigin() public { _exercise(true, true); }

    function test_IndividualWrapperApprovalReinvestsOnlyItsPepe() public {
        vm.startPrank(bob);
        staking.setApprovalForAll(address(reinvestor), false);
        staking.approve(address(reinvestor), ownerId);
        vm.stopPrank();
        _exercise(false, false);
    }

    function test_IndividualExternalOperatorCanReinvestWithoutCollectionApproval() public {
        vm.startPrank(bob);
        staking.setApprovalForAll(operator, false);
        staking.approve(operator, ownerId);
        vm.stopPrank();
        _exercise(false, true);
    }

    function test_IndividualApprovalCannotAuthorizeAnotherBatchEntry() public {
        vm.startPrank(bob);
        staking.lockWithPepe(0, 888);
        staking.setApprovalForAll(operator, false);
        staking.approve(operator, ownerId);
        vm.stopPrank();
        uint256[] memory ids = new uint256[](2);
        ids[0] = ownerId; ids[1] = 888;
        uint256 fees = staking.pendingFeesOf(ownerId);
        uint256 tickets = hook.ticketCount();
        vm.prank(operator); vm.expectRevert(PSPReinvestor.Unauthorized.selector);
        reinvestor.reinvestAll(ids, poolKey, 1, block.timestamp);
        assertEq(staking.pendingFeesOf(ownerId), fees);
        assertEq(hook.ticketCount(), tickets);
    }

    function test_TransferCarriesFeesAndRevokesOldClaimPermission() public {
        vm.prank(bob); staking.requestWithdraw(ownerId);
        zapIn.buyWithMix(poolKey, 2e18, 1, block.timestamp);
        uint256 fees = staking.pendingFeesOf(ownerId);
        assertGt(fees, 0);
        vm.startPrank(bob);
        staking.approve(operator, ownerId);
        staking.safeTransferFrom(bob, alice, ownerId);
        vm.stopPrank();
        assertEq(staking.pendingFeesOf(ownerId), fees);
        vm.prank(bob); vm.expectRevert(PSPStaker.NotNftOwner.selector); staking.claimFees(ownerId);
        vm.prank(operator); vm.expectRevert(PSPStaker.NotNftOwner.selector); staking.claimFees(ownerId);
        uint256 balance = mixETH.balanceOf(alice);
        vm.prank(alice); staking.claimFees(ownerId);
        assertEq(mixETH.balanceOf(alice) - balance, fees);
        assertTrue(staking.isWithdrawing(ownerId));
    }

    function test_IndividualFeeClaimsAreScopedAndRevocable() public {
        zapIn.buyWithMix(poolKey, 2e18, 1, block.timestamp);
        vm.startPrank(bob);
        staking.setApprovalForAll(operator, false);
        staking.approve(operator, ownerId);
        vm.stopPrank();
        uint256 fees = staking.pendingFeesOf(ownerId);
        uint256 before = mixETH.balanceOf(operator);
        vm.prank(operator); staking.claimFeesTo(ownerId, operator);
        assertEq(mixETH.balanceOf(operator) - before, fees);
        vm.prank(operator); vm.expectRevert(PSPStaker.NotNftOwner.selector); staking.claimFees(777);
        zapIn.buyWithMix(poolKey, 2e18, 1, block.timestamp);
        vm.prank(bob); staking.approve(address(0), ownerId);
        vm.prank(operator); vm.expectRevert(PSPStaker.NotNftOwner.selector); staking.claimFees(ownerId);
    }

    function _exercise(bool batch, bool viaOperator) internal {
        uint256[] memory ids = new uint256[](batch ? 2 : 1);
        ids[0] = ownerId;
        if (batch) {
            uint256 extra = zapIn.buyWithMix(poolKey, 1e18, 1, block.timestamp);
            pspToken.transfer(bob, extra);
            vm.startPrank(bob);
            pspToken.approve(address(staking), extra);
            staking.lockWithPepe(extra, 888);
            vm.stopPrank();
            ids[1] = 888;
        }
        zapIn.buyWithMix(poolKey, 2e18, 1, block.timestamp);
        uint256 fees;
        uint256[] memory amounts = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            fees += staking.pendingFeesOf(ids[i]);
            (amounts[i],,,,) = staking.positions(ids[i]);
        }
        assertGe(fees, 0.05e18, "test replaces all ten seats");
        uint256 quote = hook.getBuyOutput(fees);
        uint256 fee = fees * hook.swapFeeBps() / 10000;
        uint256 referral = (fee - fee * 6000 / 10000 - fee * 3500 / 10000) * 8000 / 10000;
        uint256 refBefore = hook.referralRegistry().claimableReferral(alice);
        uint256 ticketsBefore = hook.ticketCount();
        uint256 nftsBefore = staking.balanceOf(bob);
        vm.recordLogs();
        vm.prank(viaOperator ? operator : bob, makeAddr("unrelated-tx-origin"));
        if (batch) reinvestor.reinvestAll(ids, poolKey, quote, block.timestamp);
        else reinvestor.reinvest(ownerId, poolKey, quote, block.timestamp);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 buys;
        uint256 times;
        uint256 referrals;
        address registry = address(hook.referralRegistry());
        for (uint256 i; i < logs.length; ++i) {
            bytes32 eventId = logs[i].topics[0];
            if (logs[i].emitter == registry && eventId == keccak256("ReferralRewardsCredited(address,uint256)")) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), alice, "owner's referral recipient");
                assertEq(abi.decode(logs[i].data, (uint256)), referral, "credited referral amount");
                ++referrals;
            } else if (logs[i].emitter != address(hook)) continue;
            else if (eventId == keccak256("Buy(address,uint256,uint256,uint256,uint256)")) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), bob, "buy owner"); ++buys;
            } else if (eventId == keccak256("TimeAdded(address,uint256,uint256)")) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), bob, "clock owner"); ++times;
            }
        }
        assertEq(buys, 1, "one Buy event"); assertEq(times, 1, "one TimeAdded event"); assertEq(referrals, 1, "one ReferralRewardsCredited event");
        assertEq(hook.referralRegistry().claimableReferral(alice) - refBefore, referral, "owner's recorded referral chain credited");
        assertEq(hook.ticketCount() - ticketsBefore, fees / 0.005e18);
        for (uint256 i; i < 10; ++i) { (address buyer,,,) = hook.board(i); assertEq(buyer, bob); }
        for (uint256 i; i < ids.length; ++i) {
            (uint256 amount,,,,) = staking.positions(ids[i]);
            assertGt(amount, amounts[i]); assertEq(staking.ownerOf(ids[i]), bob);
        }
        assertEq(staking.balanceOf(bob), nftsBefore);
        assertEq(pspToken.balanceOf(operator), 0);
        assertLe(pspToken.balanceOf(address(reinvestor)), ids.length - 1);
        assertEq(mixETH.balanceOf(address(reinvestor)), 0);
        vm.warp(hook.detonationAt());
        controller.detonate{gas: 1_000_000}();
        assertEq(hook.claimablePot(address(reinvestor)), 0);
        assertEq(hook.claimablePot(address(zapIn)), 0);
        assertEq(hook.claimablePot(operator), 0);
        uint256 pot = hook.potBalance();
        uint256[10] memory bps = [uint256(2500), 1800, 1400, 1000, 800, 700, 600, 500, 400, 300];
        uint256 payout;
        for (uint256 i; i < 10; ++i) payout += pot * bps[i] / 10000;
        assertEq(hook.claimablePot(bob), payout, "owner can claim all ten rounded seat payouts");
        uint256 beforeClaim = mixETH.balanceOf(bob);
        vm.prank(bob); hook.claimPot();
        assertEq(mixETH.balanceOf(bob) - beforeClaim, payout);
    }

    function test_BuyForSpendsCallerFundsAndKeepsTokensWithCaller() public {
        uint256 buyerMix = mixETH.balanceOf(operator);
        uint256 callerMix = mixETH.balanceOf(address(this));
        uint256 callerPsp = pspToken.balanceOf(address(this));
        uint256 price = hook.ticketPrice();
        uint256 out = zapIn.buyWithMixFor(poolKey, price, 1, block.timestamp, operator);
        assertEq(mixETH.balanceOf(address(this)), callerMix - price);
        assertEq(mixETH.balanceOf(operator), buyerMix);
        assertEq(pspToken.balanceOf(address(this)), callerPsp + out);
        assertEq(pspToken.balanceOf(operator), 0);
        (address buyer,,,) = hook.board(0); assertEq(buyer, operator);
        assertFalse(hook.referralRegistry().attributed(operator), "does not create attribution");
    }

    function test_BuyForCannotSpendBeneficiaryAllowance() public {
        mixETH.transfer(operator, 1e18);
        vm.prank(operator); mixETH.approve(address(zapIn), type(uint256).max);
        address attacker = makeAddr("unfunded-attacker");
        vm.prank(attacker); vm.expectRevert();
        zapIn.buyWithMixFor(poolKey, 0.005e18, 1, block.timestamp, operator);
        assertEq(mixETH.balanceOf(operator), 1e18);
    }

    function test_BuyForRejectsZeroTraderAndPreservesSlippageDeadline() public {
        vm.expectRevert(PSPZapIn.ZeroTrader.selector);
        zapIn.buyWithMixFor(poolKey, 0.005e18, 1, block.timestamp, address(0));
        vm.expectRevert(PSPZapIn.Expired.selector);
        zapIn.buyWithMixFor(poolKey, 0.005e18, 1, block.timestamp - 1, bob);
        uint256 tickets = hook.ticketCount();
        uint256 balance = mixETH.balanceOf(address(this));
        vm.expectRevert(PSPZapIn.InsufficientOutput.selector);
        zapIn.buyWithMixFor(poolKey, 0.005e18, type(uint256).max, block.timestamp, bob);
        assertEq(hook.ticketCount(), tickets); assertEq(mixETH.balanceOf(address(this)), balance);
    }
}
