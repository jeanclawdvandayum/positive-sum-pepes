// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RealV4Base} from "./RealV4Lifecycle.t.sol";
import {PSPReferralRegistry} from "../src/PSPReferralRegistry.sol";
import {PSPStaker} from "../src/PSPStaker.sol";

/// @title SkillCallbackReviewTest
/// @notice Reproduces referral delivery across an owner-deduplication gap on real V4.
contract SkillCallbackReviewTest is RealV4Base {
    PSPReferralRegistry private registry;
    PSPStaker private staking;
    address private carol = makeAddr("callback-carol");
    address private dave = makeAddr("callback-dave");
    address private erin = makeAddr("callback-erin");
    address private frank = makeAddr("callback-frank");
    uint256[5] private chain;

    function setUp() public override {
        super.setUp();
        registry = PSPReferralRegistry(factory.referralRegistryOf(1));
        staking = controller.staker();
        vm.prank(bob);
        controller.claimPredepositPSP();
        uint256 bobNft = staking.primaryOf(bob);
        uint256 carolNft = _newReferrer(carol);
        uint256 daveNft = _newReferrer(dave);
        uint256 erinNft = _newReferrer(erin);
        uint256 frankNft = _newReferrer(frank);
        chain = [bobNft, carolNft, daveNft, erinNft, frankNft];

        vm.prank(erin);
        registry.record(frankNft);
        vm.prank(dave);
        registry.record(erinNft);
        vm.prank(carol);
        registry.record(daveNft);
        vm.prank(bob);
        registry.record(carolNft);
        vm.prank(alice);
        registry.record(bobNft);

        // The token edge remains carolNft -> daveNft. Bob now owns tiers
        // one and two, so only tier two should be suppressed by deduplication.
        vm.prank(carol);
        staking.transferFrom(carol, bob, carolNft);
        (address[5] memory who, uint24[5] memory bps) = registry.payoutFor(alice);
        assertEq(who[0], bob);
        assertEq(who[1], address(0));
        assertEq(who[2], dave);
        assertEq(who[3], erin);
        assertEq(bps[2], 500);
        assertEq(bps[3], 200);

        mixETH.transfer(alice, 1e18);
        vm.prank(alice);
        mixETH.approve(address(registry), 1e18);
    }

    function _newReferrer(address who) private returns (uint256 id) {
        mixETH.transfer(who, 1e18);
        vm.startPrank(who);
        mixETH.approve(address(zapIn), 1e18);
        uint256 bought = zapIn.buyWithMix(poolKey, 1e18, 1, 0);
        pspToken.approve(address(staking), bought);
        staking.lock(bought);
        id = staking.primaryOf(who);
        vm.stopPrank();
        assertTrue(registry.canReferNft(id));
    }

    function test_BuyPaysDistinctAncestorsAfterDuplicateOwner() public {
        uint256 fee = 0.005e18 * uint256(hook.swapFeeBps()) / 10000;
        uint256 stakerLeg = fee * 6000 / 10000;
        uint256 potLeg = fee * 3500 / 10000;
        uint256 referralLeg = fee - stakerLeg - potLeg;
        uint256 daveBefore = mixETH.balanceOf(dave);
        uint256 erinBefore = mixETH.balanceOf(erin);
        uint256 bobBefore = mixETH.balanceOf(bob);
        uint256 frankBefore = mixETH.balanceOf(frank);
        uint256 potBefore = hook.potBalance();
        vm.prank(alice);
        registry.buyWithMix(poolKey, 0.005e18, 1, 0, 0);

        uint256 paidBob = mixETH.balanceOf(bob) - bobBefore;
        uint256 paidDave = mixETH.balanceOf(dave) - daveBefore;
        uint256 paidErin = mixETH.balanceOf(erin) - erinBefore;
        uint256 paidFrank = mixETH.balanceOf(frank) - frankBefore;
        assertEq(paidBob, referralLeg * 8000 / 10000, "duplicate owner receives only first tier");
        assertEq(paidDave, referralLeg * 500 / 10000, "distinct third tier is not truncated");
        assertEq(paidErin, referralLeg * 200 / 10000, "distinct fourth tier is not truncated");
        assertEq(paidFrank, referralLeg * 100 / 10000, "distinct fifth tier is not truncated");
        assertEq(hook.potBalance() - potBefore, potLeg + referralLeg - paidBob - paidDave - paidErin - paidFrank);
    }

    function test_SellPaysDistinctAncestorsAfterDuplicateOwner() public {
        vm.startPrank(alice);
        uint256 bought = registry.buyWithMix(poolKey, 0.005e18, 1, 0, 0);
        pspToken.approve(address(zapOut), bought);
        vm.stopPrank();
        uint256 daveBefore = mixETH.balanceOf(dave);
        uint256 erinBefore = mixETH.balanceOf(erin);
        uint256 reserveBefore = hook.reserveMixETH();
        uint256 feeBps = uint256(hook.swapFeeBps());
        vm.prank(alice);
        zapOut.sellToMix(poolKey, bought, 1, 0);
        uint256 fee = (reserveBefore - hook.reserveMixETH()) * feeBps / 10000;
        uint256 referralLeg = fee - fee * 6000 / 10000 - fee * 3500 / 10000;
        assertEq(mixETH.balanceOf(dave) - daveBefore, referralLeg * 500 / 10000,
            "sell pays distinct third tier after duplicate");
        assertEq(mixETH.balanceOf(erin) - erinBefore, referralLeg * 200 / 10000,
            "sell pays distinct fourth tier after duplicate");
    }

    function testFuzz_TransferredChainPaysEachOwnerFirstTierOnly(uint256 seed) public {
        address[5] memory actors = [bob, carol, dave, erin, frank];
        uint256[5] memory tiers = [uint256(8000), 1200, 500, 200, 100];
        uint256[5] memory expected;
        uint256[5] memory beforeBalance;
        bool[5] memory seen;
        uint256 fee = 0.005e18 * uint256(hook.swapFeeBps()) / 10000;
        uint256 leg = fee - fee * 6000 / 10000 - fee * 3500 / 10000;
        for (uint256 i; i < 5; ++i) {
            uint256 ownerIndex = (seed >> (i * 8)) % 5;
            address currentOwner = staking.ownerOf(chain[i]);
            vm.prank(currentOwner);
            staking.transferFrom(currentOwner, actors[ownerIndex], chain[i]);
            if (!seen[ownerIndex]) {
                seen[ownerIndex] = true;
                expected[ownerIndex] = leg * tiers[i] / 10000;
            }
            beforeBalance[i] = mixETH.balanceOf(actors[i]);
        }
        uint256 potBefore = hook.potBalance();
        vm.prank(alice);
        registry.buyWithMix(poolKey, 0.005e18, 1, 0, 0);
        uint256 paid;
        for (uint256 i; i < 5; ++i) {
            assertEq(mixETH.balanceOf(actors[i]) - beforeBalance[i], expected[i], "first owned tier only");
            paid += expected[i];
        }
        assertEq(hook.potBalance() - potBefore, fee * 3500 / 10000 + leg - paid);
    }
}
