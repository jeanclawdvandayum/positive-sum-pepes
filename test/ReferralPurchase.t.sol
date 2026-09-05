// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockMixETH} from "./mocks/MockMixETH.sol";
import {RealV4Base} from "./RealV4Lifecycle.t.sol";
import {PSPReferralRegistry} from "../src/PSPReferralRegistry.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ReferralPurchaseTest
/// @notice Atomic, caller-authenticated attribution on a real V4 PoolManager.
contract ReferralPurchaseTest is RealV4Base {
    PSPReferralRegistry reg;
    PSPStaker staker;
    uint256 bobNft;
    address carol = makeAddr("ref-carol");
    address dave = makeAddr("ref-dave");

    function createMixETH() internal override returns (MockMixETH) { return new ReferralCallbackMix(); }

    function setUp() public override {
        super.setUp();
        reg = PSPReferralRegistry(factory.referralRegistryOf(1));
        staker = controller.staker();
        vm.prank(bob);
        controller.claimPredepositPSP();
        bobNft = staker.primaryOf(bob);
        mixETH.transfer(alice, 100e18);
        vm.prank(alice);
        mixETH.approve(address(reg), type(uint256).max);
    }

    function _buy(address buyer, uint256 ref) internal returns (uint256) {
        vm.prank(buyer);
        return reg.buyWithMix(poolKey, 0.005e18, 1, block.timestamp + 600, ref);
    }

    function _pepe(address who) internal returns (uint256) {
        mixETH.transfer(who, 1e18);
        vm.startPrank(who);
        mixETH.approve(address(zapIn), 1e18);
        uint256 amount = zapIn.buyWithMix(poolKey, 1e18, 1, 0);
        pspToken.approve(address(staker), amount);
        staker.lock(amount);
        uint256 id = staker.primaryOf(who);
        vm.stopPrank();
        assertTrue(reg.canReferNft(id));
        return id;
    }

    function test_FirstPurchaseBindsPaysAndCreditsBuyerAtomically() public {
        uint256 beforeBob = mixETH.balanceOf(bob);
        uint256 beforePot = hook.potBalance();
        uint256 beforeDeployer = hook.deployerCredit();
        uint256 fee = 0.005e18 * uint256(hook.swapFeeBps()) / 10000;
        uint256 stakerLeg = fee * 6000 / 10000;
        uint256 potLeg = fee * 3500 / 10000;
        uint256 referralLeg = fee - stakerLeg - potLeg;
        uint256 out = _buy(alice, bobNft);
        assertTrue(reg.attributed(alice));
        assertEq(reg.traderRefNftOf(alice), bobNft);
        assertEq(mixETH.balanceOf(bob) - beforeBob, referralLeg * 8000 / 10000);
        assertEq(hook.potBalance() - beforePot, potLeg + referralLeg - referralLeg * 8000 / 10000);
        assertEq(hook.deployerCredit(), beforeDeployer);
        assertEq(pspToken.balanceOf(alice), out);
        assertEq(mixETH.balanceOf(alice), 100e18 - 0.005e18);
        assertEq(mixETH.balanceOf(address(reg)), 0);
        assertEq(pspToken.balanceOf(address(reg)), 0);
        (address owner,,,) = hook.board(0);
        assertEq(owner, alice);
    }

    function test_SlippageFailureRollsBackAttributionAndAllValue() public {
        uint256 pot = hook.potBalance();
        uint256 reserves = hook.reserveMixETH();
        uint256 balance = mixETH.balanceOf(bob);
        vm.prank(alice);
        vm.expectRevert(PSPReferralRegistry.InsufficientOutput.selector);
        reg.buyWithMix(poolKey, 0.005e18, type(uint256).max, 0, bobNft);
        assertFalse(reg.attributed(alice));
        assertEq(reg.traderRefNftOf(alice), 0);
        assertEq(hook.reserveMixETH(), reserves);
        assertEq(hook.potBalance(), pot);
        assertEq(mixETH.balanceOf(bob), balance);
        assertEq(mixETH.balanceOf(alice), 100e18);
    }

    function test_ExpiredAndBelowMinimumPurchasesCannotBind() public {
        vm.prank(alice);
        vm.expectRevert(PSPReferralRegistry.Expired.selector);
        reg.buyWithMix(poolKey, 0.005e18, 1, block.timestamp - 1, bobNft);
        assertFalse(reg.attributed(alice));
        vm.prank(alice);
        vm.expectRevert(); // V4 wraps the hook's minimum-input revert
        reg.buyWithMix(poolKey, 0.005e18 - 1, 1, 0, bobNft);
        assertFalse(reg.attributed(alice));
    }

    function test_FailedTransferCannotBind() public {
        vm.prank(alice);
        mixETH.approve(address(reg), 0);
        vm.prank(alice);
        vm.expectRevert();
        reg.buyWithMix(poolKey, 0.005e18, 1, 0, bobNft);
        assertFalse(reg.attributed(alice));
    }

    function test_ClockZeroCannotBind() public {
        vm.warp(hook.detonationAt());
        vm.prank(alice);
        vm.expectRevert();
        reg.buyWithMix(poolKey, 0.005e18, 1, 0, bobNft);
        assertFalse(reg.attributed(alice));
    }

    function test_BuyWithoutLinkKeepsAttributionAvailable() public {
        _buy(alice, 0);
        assertFalse(reg.attributed(alice));
        _buy(alice, bobNft);
        assertEq(reg.traderRefNftOf(alice), bobNft);
    }

    function test_InvalidLinkSkipsWithoutBreakingBuy() public {
        vm.expectEmit(true, true, false, true, address(reg));
        emit PSPReferralRegistry.ReferralSkipped(alice, 999, PSPReferralRegistry.NotQualifiedReferrer.selector);
        assertGt(_buy(alice, 999), 0);
        assertFalse(reg.attributed(alice));
        _buy(alice, bobNft);
        assertEq(reg.traderRefNftOf(alice), bobNft);
    }

    function test_SelfReferralOnNonPrimaryNftIsSkipped() public {
        _pepe(alice);
        vm.prank(alice);
        staker.lock(0);
        uint256 second = staker.tokenOfOwnerByIndex(alice, 1);
        assertTrue(reg.canReferNft(second));
        _buy(alice, second);
        assertFalse(reg.attributed(alice));
        vm.prank(alice);
        vm.expectRevert(PSPReferralRegistry.SelfReferral.selector);
        reg.record(second);
    }

    function test_LaterHintsAndDirectRecordCannotReplaceEntry() public {
        uint256 other = _pepe(carol);
        _buy(alice, bobNft);
        _buy(alice, other);
        _buy(alice, 0);
        _buy(alice, type(uint256).max);
        assertEq(reg.traderRefNftOf(alice), bobNft);
        vm.prank(alice);
        vm.expectRevert(PSPReferralRegistry.AlreadyReferred.selector);
        reg.record(other);
    }

    function testFuzz_RecordedEntrySurvivesEveryLaterHint(uint256 hint) public {
        _buy(alice, bobNft);
        _buy(alice, hint);
        assertEq(reg.traderRefNftOf(alice), bobNft);
    }

    function test_AcquiredPrimaryCannotChangeRecordedPayout() public {
        uint256 carolNft = _pepe(carol);
        uint256 daveNft = _pepe(dave);
        vm.prank(carol);
        reg.record(daveNft);
        _buy(alice, bobNft);
        vm.prank(carol);
        staker.transferFrom(carol, alice, carolNft);
        (address[5] memory who,) = reg.payoutFor(alice);
        assertEq(who[0], bob);
        assertEq(reg.traderRefNftOf(alice), bobNft);
    }

    function test_AcquiringAttributedNftDoesNotBindRecipient() public {
        uint256 carolNft = _pepe(carol);
        vm.prank(carol);
        reg.record(bobNft);
        vm.prank(carol);
        staker.transferFrom(carol, alice, carolNft);
        (address[5] memory who,) = reg.payoutFor(alice);
        assertEq(who[0], address(0));
        assertFalse(reg.attributed(alice));
    }

    function test_NewOwnerCannotRewriteNftAncestry() public {
        uint256 carolNft = _pepe(carol);
        uint256 daveNft = _pepe(dave);
        vm.prank(carol);
        reg.record(bobNft);
        vm.prank(carol);
        staker.transferFrom(carol, alice, carolNft);
        _buy(alice, daveNft);
        assertEq(reg.nftRefOf(carolNft), bobNft);
        assertEq(reg.traderRefNftOf(alice), daveNft);
    }

    function test_CycleIsSkippedAndPurchaseStillWorks() public {
        uint256 aliceNft = _pepe(alice);
        vm.prank(bob);
        reg.record(aliceNft);
        _buy(alice, bobNft);
        assertFalse(reg.attributed(alice));
        vm.prank(alice);
        vm.expectRevert(PSPReferralRegistry.WouldCreateCycle.selector);
        reg.record(bobNft);
    }

    function test_ForgedTraderHintCannotBindVictim() public {
        mixETH.transfer(carol, 1e18);
        vm.startPrank(carol);
        mixETH.approve(address(zapIn), 1e18);
        zapIn.buyWithMixFor(poolKey, 0.005e18, 1, 0, alice);
        vm.stopPrank();
        assertFalse(reg.attributed(alice));
        assertEq(reg.traderRefNftOf(alice), 0);
        _buy(alice, bobNft);
        assertEq(reg.traderRefNftOf(alice), bobNft);
    }

    function test_CallbackCannotSpendStandingAllowance() public {
        bytes memory payload = abi.encode(PSPReferralRegistry.Purchase(poolKey, 1e18, 1, alice,
            Currency.unwrap(poolKey.currency0) == address(mixETH)));
        vm.expectRevert(PSPReferralRegistry.UnauthorizedCallback.selector);
        reg.unlockCallback(payload);
        vm.prank(address(poolManager));
        vm.expectRevert(PSPReferralRegistry.UnauthorizedCallback.selector);
        reg.unlockCallback(payload);
        assertEq(mixETH.balanceOf(alice), 100e18);
    }

    function test_WrongPoolCannotBindOrSpend() public {
        PoolKey memory wrong = poolKey;
        wrong.currency1 = wrong.currency0;
        vm.prank(alice);
        vm.expectRevert(PSPReferralRegistry.BadPool.selector);
        reg.buyWithMix(wrong, 0.005e18, 1, 0, bobNft);
        wrong = poolKey;
        wrong.fee = 0;
        vm.prank(alice);
        vm.expectRevert(PSPReferralRegistry.BadPool.selector);
        reg.buyWithMix(wrong, 0.005e18, 1, 0, bobNft);
        assertFalse(reg.attributed(alice));
    }

    function test_TransferReferrerNftPaysItsNewOwnerWithoutChangingEntry() public {
        _buy(alice, bobNft);
        vm.prank(bob);
        staker.transferFrom(bob, carol, bobNft);
        uint256 beforeCarol = mixETH.balanceOf(carol);
        _buy(alice, 0);
        assertGt(mixETH.balanceOf(carol), beforeCarol);
        assertEq(reg.traderRefNftOf(alice), bobNft);
    }

    function test_RecordedReferralSurvivesSellAndBuy() public {
        uint256 amount = _buy(alice, bobNft);
        uint256 beforeBob = mixETH.balanceOf(bob);
        vm.startPrank(alice);
        pspToken.approve(address(zapOut), amount);
        zapOut.sellToMix(poolKey, amount, 1, 0);
        vm.stopPrank();
        assertGt(mixETH.balanceOf(bob), beforeBob);
        _buy(alice, 0);
        assertEq(reg.traderRefNftOf(alice), bobNft);
    }

    function test_TokenCallbackCannotReenterPurchaseOrRegistration() public {
        ReferralCallbackMix token = ReferralCallbackMix(payable(address(mixETH)));
        token.arm(address(reg), abi.encodeCall(reg.buyWithMix, (poolKey, 0.005e18, 1, 0, bobNft)), bobNft);
        _buy(alice, bobNft);
        assertTrue(token.attempted());
        assertFalse(token.bought());
        assertFalse(token.recorded());
        assertFalse(reg.attributed(address(token)));
        assertEq(reg.traderRefNftOf(alice), bobNft);
        assertEq(mixETH.balanceOf(alice), 100e18 - 0.005e18);
    }

    function test_DecoyRegistryCannotRouteTheRoundPurchase() public {
        PSPReferralRegistry decoy = new PSPReferralRegistry(address(staker), 1000e18);
        vm.startPrank(alice);
        mixETH.approve(address(decoy), 1e18);
        vm.expectRevert(PSPReferralRegistry.BadPool.selector);
        decoy.buyWithMix(poolKey, 0.005e18, 1, 0, bobNft);
        vm.stopPrank();
        assertFalse(decoy.attributed(alice));
        assertFalse(reg.attributed(alice));
    }

    function test_NextRoundStartsWithFreshAttribution() public {
        _buy(alice, bobNft);
        vm.warp(hook.detonationAt());
        controller.detonate{gas: 1_000_000}();
        factory.reserveSpawn(1);
        for (uint256 i; i < 3; i++) factory.birthStep{gas: 12_000_000}();
        PSPReferralRegistry next = PSPReferralRegistry(factory.referralRegistryOf(2));
        assertTrue(address(next) != address(reg));
        assertFalse(next.attributed(alice));
        assertEq(next.traderRefNftOf(alice), 0);
        assertEq(reg.traderRefNftOf(alice), bobNft);
    }
}

/// @notice Real ERC20 transfers with an adversarial transferFrom callback.
contract ReferralCallbackMix is MockMixETH {
    address target;
    bytes purchase;
    uint256 ref;
    bool public attempted;
    bool public bought;
    bool public recorded;
    function arm(address registry, bytes memory data, uint256 id) external {
        target = registry; purchase = data; ref = id;
    }
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (target != address(0) && !attempted) {
            attempted = true;
            (bought,) = target.call(purchase);
            (recorded,) = target.call(abi.encodeCall(PSPReferralRegistry.record, (ref)));
        }
        return super.transferFrom(from, to, value);
    }
}
