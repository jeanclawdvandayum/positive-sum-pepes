// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RealV4Base} from "./RealV4Lifecycle.t.sol";
import {MockMixETH} from "./mocks/MockMixETH.sol";
import {PSPReferralRegistry} from "../src/PSPReferralRegistry.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ReferralRewardsTest
/// @notice Wallet-owned referral liabilities stay backed across trades, transfers and round death.
contract ReferralRewardsTest is RealV4Base {
    PSPReferralRegistry private registry;
    PSPStaker private staking;
    ReferralRewardsMix private token;
    address private carol = makeAddr("reward-carol");
    uint256 private referrerId;

    function createMixETH() internal override returns (MockMixETH) { return new ReferralRewardsMix(); }

    function setUp() public override {
        super.setUp();
        registry = PSPReferralRegistry(factory.referralRegistryOf(1));
        staking = controller.staker();
        token = ReferralRewardsMix(payable(address(mixETH)));
        vm.prank(bob);
        controller.claimPredepositPSP();
        referrerId = staking.primaryOf(bob);
        mixETH.transfer(alice, 100e18);
        vm.prank(alice);
        mixETH.approve(address(registry), type(uint256).max);
    }

    function _buy(uint256 amount) private returns (uint256) {
        vm.prank(alice);
        return registry.buyWithMix(poolKey, amount, 1, 0, referrerId);
    }

    function _fundCredit(address recipient, uint256 amount) private {
        mixETH.transfer(address(registry), amount);
        address[5] memory recipients;
        uint256[5] memory amounts;
        recipients[0] = recipient;
        amounts[0] = amount;
        vm.prank(address(hook));
        registry.creditReferralRewards(recipients, amounts);
    }

    function test_ClaimPaysExactCreditOnceAndLeavesStakingFeesAlone() public {
        uint256 walletBefore = mixETH.balanceOf(bob);
        _buy(1e18);
        uint256 credit = registry.claimableReferral(bob);
        uint256 stakingFees = staking.pendingFeesOf(referrerId);
        assertEq(registry.REFERRAL_REWARDS_VERSION(), 1);
        assertGt(credit, 0);
        assertEq(mixETH.balanceOf(bob), walletBefore);
        assertEq(mixETH.balanceOf(address(registry)), credit);
        assertEq(registry.totalReferralOutstanding(), credit);

        vm.expectEmit(true, false, false, true, address(registry));
        emit PSPReferralRegistry.ReferralRewardsClaimed(bob, credit);
        vm.prank(bob);
        registry.claimReferralRewards();
        assertEq(mixETH.balanceOf(bob), walletBefore + credit);
        assertEq(staking.pendingFeesOf(referrerId), stakingFees);
        assertEq(registry.claimableReferral(bob), 0);
        assertEq(registry.totalReferralOutstanding(), 0);
        assertEq(mixETH.balanceOf(address(registry)), 0);

        vm.prank(bob);
        vm.expectRevert(PSPReferralRegistry.NothingToClaim.selector);
        registry.claimReferralRewards();
    }

    function test_NftOperatorCannotClaimOwnersReferralRewards() public {
        _buy(1e18);
        uint256 credit = registry.claimableReferral(bob);
        vm.prank(bob);
        staking.setApprovalForAll(carol, true);
        vm.prank(carol);
        vm.expectRevert(PSPReferralRegistry.NothingToClaim.selector);
        registry.claimReferralRewards();
        assertEq(registry.claimableReferral(bob), credit);
        assertEq(registry.totalReferralOutstanding(), credit);
    }

    function test_OnlyRoundHookCanCreditEvenWhenEscrowHasSurplus() public {
        mixETH.transfer(address(registry), 1e18);
        address[5] memory recipients;
        uint256[5] memory amounts;
        recipients[0] = alice;
        amounts[0] = 1e18;
        address[4] memory callers = [alice, address(controller), address(poolManager), address(factory)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(PSPReferralRegistry.UnauthorizedRewardCredit.selector);
            registry.creditReferralRewards(recipients, amounts);
        }
        assertEq(registry.claimableReferral(alice), 0);
        assertEq(registry.totalReferralOutstanding(), 0);
        assertEq(mixETH.balanceOf(address(registry)), 1e18);
    }

    function test_UnbackedCreditRollsBackEveryRecipientAndCounter() public {
        _fundCredit(bob, 0.5e18);
        mixETH.transfer(address(registry), 1e18);
        address[5] memory recipients;
        uint256[5] memory amounts;
        recipients[0] = bob;
        recipients[4] = carol;
        amounts[0] = 1e18;
        amounts[4] = 1;
        vm.prank(address(hook));
        vm.expectRevert(PSPReferralRegistry.UnbackedRewards.selector);
        registry.creditReferralRewards(recipients, amounts);
        assertEq(registry.claimableReferral(bob), 0.5e18);
        assertEq(registry.claimableReferral(carol), 0);
        assertEq(registry.totalReferralOutstanding(), 0.5e18);
    }

    function test_PreviouslyAllocatedBackingCannotBeCreditedTwice() public {
        _fundCredit(bob, 1e18);
        address[5] memory recipients;
        uint256[5] memory amounts;
        recipients[0] = carol;
        amounts[0] = 1;
        vm.prank(address(hook));
        vm.expectRevert(PSPReferralRegistry.UnbackedRewards.selector);
        registry.creditReferralRewards(recipients, amounts);
        assertEq(registry.claimableReferral(bob), 1e18);
        assertEq(registry.claimableReferral(carol), 0);
        assertEq(registry.totalReferralOutstanding(), 1e18);
    }

    function test_ZeroRecipientCannotCreateUnclaimableLiability() public {
        mixETH.transfer(address(registry), 1e18);
        address[5] memory recipients;
        uint256[5] memory amounts;
        recipients[0] = bob;
        amounts[0] = 1;
        amounts[4] = 1;
        vm.prank(address(hook));
        vm.expectRevert(PSPReferralRegistry.ZeroAddress.selector);
        registry.creditReferralRewards(recipients, amounts);
        assertEq(registry.claimableReferral(bob), 0);
        assertEq(registry.claimableReferral(address(0)), 0);
        assertEq(registry.totalReferralOutstanding(), 0);
    }

    function test_FailedPayoutPreservesCreditAndTradeCanStillAccrue() public {
        token.setBlocked(bob, true);
        _buy(1e18);
        uint256 credit = registry.claimableReferral(bob);
        uint256 balance = mixETH.balanceOf(address(registry));
        vm.prank(bob);
        vm.expectRevert();
        registry.claimReferralRewards();
        assertEq(registry.claimableReferral(bob), credit);
        assertEq(registry.totalReferralOutstanding(), credit);
        assertEq(mixETH.balanceOf(address(registry)), balance);
        _buy(1e18);
        assertGt(registry.claimableReferral(bob), credit);

        token.setBlocked(bob, false);
        credit = registry.claimableReferral(bob);
        uint256 walletBefore = mixETH.balanceOf(bob);
        vm.prank(bob);
        registry.claimReferralRewards();
        assertEq(mixETH.balanceOf(bob), walletBefore + credit);
        assertEq(registry.totalReferralOutstanding(), 0);
    }

    function test_TransferFailureToEscrowRollsBackEntirePurchase() public {
        token.setBlocked(address(registry), true);
        uint256 reserves = hook.reserveMixETH();
        uint256 pot = hook.potBalance();
        uint256 tickets = hook.ticketCount();
        vm.prank(alice);
        vm.expectRevert();
        registry.buyWithMix(poolKey, 1e18, 1, 0, referrerId);
        assertFalse(registry.attributed(alice));
        assertEq(registry.claimableReferral(bob), 0);
        assertEq(registry.totalReferralOutstanding(), 0);
        assertEq(mixETH.balanceOf(alice), 100e18);
        assertEq(pspToken.balanceOf(alice), 0);
        assertEq(hook.reserveMixETH(), reserves);
        assertEq(hook.potBalance(), pot);
        assertEq(hook.ticketCount(), tickets);
    }

    function test_PayoutCallbackCannotReenterClaim() public {
        _buy(1e18);
        uint256 credit = registry.claimableReferral(bob);
        uint256 walletBefore = mixETH.balanceOf(bob);
        token.armClaimCallback(address(registry));
        vm.prank(bob);
        registry.claimReferralRewards();
        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackFailure(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(mixETH.balanceOf(bob), walletBefore + credit);
        assertEq(registry.totalReferralOutstanding(), 0);
    }

    function test_TransferKeepsEarnedCreditAndMovesOnlyFutureCredit() public {
        _buy(1e18);
        uint256 earnedByBob = registry.claimableReferral(bob);
        vm.prank(bob);
        staking.transferFrom(bob, carol, referrerId);
        _buy(1e18);
        uint256 earnedByCarol = registry.claimableReferral(carol);
        assertGt(earnedByCarol, 0);
        assertEq(registry.claimableReferral(bob), earnedByBob);
        assertEq(registry.totalReferralOutstanding(), earnedByBob + earnedByCarol);
        uint256 bobBalance = mixETH.balanceOf(bob);
        vm.prank(bob);
        registry.claimReferralRewards();
        assertEq(mixETH.balanceOf(bob), bobBalance + earnedByBob);
        assertEq(registry.totalReferralOutstanding(), earnedByCarol);
        vm.prank(carol);
        registry.claimReferralRewards();
        assertEq(mixETH.balanceOf(address(registry)), 0);
        assertEq(registry.totalReferralOutstanding(), 0);
    }

    function test_ClaimRemainsOpenAfterDetonationWithdrawalAndNextRound() public {
        _buy(1e18);
        uint256 credit = registry.claimableReferral(bob);
        vm.warp(hook.detonationAt());
        controller.detonate{gas: 1_000_000}();
        vm.prank(bob);
        staking.withdraw(referrerId);
        factory.reserveSpawn(1);
        for (uint256 i; i < 3; ++i) factory.birthStep{gas: 12_000_000}();
        PSPReferralRegistry next = PSPReferralRegistry(factory.referralRegistryOf(2));
        assertEq(next.claimableReferral(bob), 0);
        assertEq(next.totalReferralOutstanding(), 0);
        assertEq(registry.claimableReferral(bob), credit);
        uint256 walletBefore = mixETH.balanceOf(bob);
        vm.prank(bob);
        registry.claimReferralRewards();
        assertEq(mixETH.balanceOf(bob), walletBefore + credit);
        assertEq(registry.totalReferralOutstanding(), 0);
    }

    function testFuzz_BuyAndSellEscrowConservesEveryRewardWei(uint256 gross) public {
        gross = bound(gross, 0.005e18, 50e18);
        uint256 hookBefore = mixETH.balanceOf(address(hook));
        uint256 stakerBefore = mixETH.balanceOf(address(staking));
        uint256 walletBefore = mixETH.balanceOf(bob);
        uint256 bought = _buy(gross);
        uint256 creditAfterBuy = registry.claimableReferral(bob);
        assertGt(creditAfterBuy, 0);
        assertEq(mixETH.balanceOf(bob), walletBefore);
        assertEq(mixETH.balanceOf(address(registry)), creditAfterBuy);
        assertEq(registry.totalReferralOutstanding(), creditAfterBuy);
        assertEq(
            mixETH.balanceOf(address(hook)) + mixETH.balanceOf(address(staking)) + creditAfterBuy,
            hookBefore + stakerBefore + gross,
            "buy input is conserved across backing, staking and referral escrow"
        );

        uint256 buyerBeforeSell = mixETH.balanceOf(alice);
        vm.startPrank(alice);
        pspToken.approve(address(zapOut), bought);
        zapOut.sellToMix(poolKey, bought, 1, 0);
        vm.stopPrank();
        uint256 creditAfterSell = registry.claimableReferral(bob);
        assertGt(creditAfterSell, creditAfterBuy);
        assertEq(registry.totalReferralOutstanding(), creditAfterSell);
        assertEq(mixETH.balanceOf(address(registry)), creditAfterSell);
        assertEq(
            mixETH.balanceOf(address(hook)) + mixETH.balanceOf(address(staking)) + creditAfterSell
                + mixETH.balanceOf(alice) - buyerBeforeSell,
            hookBefore + stakerBefore + gross,
            "sell output and all unpaid obligations conserve the original funds"
        );
        vm.prank(bob);
        registry.claimReferralRewards();
        assertEq(mixETH.balanceOf(bob) - walletBefore, creditAfterSell);
        assertEq(mixETH.balanceOf(address(registry)), 0);
        assertEq(registry.totalReferralOutstanding(), 0);
    }
}

/// @notice Test token with recipient failures and an adversarial callback on payouts.
contract ReferralRewardsMix is MockMixETH {
    mapping(address => bool) private blocked;
    address private callbackRegistry;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes4 public callbackFailure;

    function setBlocked(address recipient, bool value) external { blocked[recipient] = value; }
    function armClaimCallback(address registry) external { callbackRegistry = registry; }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (blocked[to]) return false;
        if (msg.sender == callbackRegistry && !callbackAttempted) {
            callbackAttempted = true;
            bytes memory reason;
            (callbackSucceeded, reason) = callbackRegistry.call(
                abi.encodeCall(PSPReferralRegistry.claimReferralRewards, ())
            );
            if (reason.length >= 4) callbackFailure = bytes4(reason);
        }
        return super.transfer(to, value);
    }
}
