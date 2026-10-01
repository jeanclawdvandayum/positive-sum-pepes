// SPDX-License-Identifier: UNLICENSED
// PoC sketches for agent-5 findings. NOT part of the audited repo.
// Repo is READ-ONLY for this audit; these sketches live outside it.
pragma solidity ^0.8.21;

import {Setup} from "/private/tmp/yv3-ats-audit/src/test/utils/Setup.sol";
import {ITransmuter} from "/private/tmp/yv3-ats-audit/src/interfaces/alchemix/ITransmuter.sol";
import {IMYT} from "/private/tmp/yv3-ats-audit/src/interfaces/alchemix/IMYT.sol";

interface IBadAdapter {
    // has NO vault() and a realAssets() that always reverts
    function realAssets() external view returns (uint256);
}

contract PoC_Findings is Setup {
    // ---------------------------------------------------------------
    // F1 | kickAlAssetAuction | unbounded-auction-price-floor
    // Emergency admin passes a 1-wei floor. require accepts it.
    // ---------------------------------------------------------------
    function poc_oneWeiFloor() public {
        uint256 bought = 100_000e18; // alUSD lot (18 dec)

        // passes: 1 != 0 && 1e18 > 1
        vm.prank(management);
        strategy.kickAlAssetAuction(bought, 1e18, 1);

        // decay is 1 bp of the starting price per 3 minutes:
        // 9_999 bp needed to reach the floor ~= 20.8 days.
        skip(21 days);

        // whole 100k alUSD lot now sells for ~dust USDC while
        // estimatedTotalAssets carried it at 100_000e18 / 1.1e18 / 1e12
        // = 90_909e6 USDC. Taker (attacker) pays ~ 100_000 wei USDC.
        uint256 needed = alAssetAuction.getAmountNeeded(address(alAsset));
        assertLt(needed, 1e6); // < one USDC cent-unit for the whole lot
    }

    // ---------------------------------------------------------------
    // F2 | MYTLimitsLib.availableWithdrawLimit | uncaught-view-revert
    // Adapter without vault() whose realAssets() reverts.
    // The catch block calls realAssets() with no guard.
    // ---------------------------------------------------------------
    function poc_adapterRevert() public {
        buyAndTransmute(100_000e6); // creates value in the vault
        mature();

        address adapter = myt.liquidityAdapter();
        // make BOTH calls revert: vault() (handled, falls to catch)
        vm.mockCallRevert(adapter, abi.encodeWithSelector(bytes4(keccak256("vault()"))), "no vault");
        // and realAssets() (NOT handled, escapes)
        vm.mockCallRevert(
            adapter, abi.encodeWithSelector(IBadAdapter.realAssets.selector), "boom"
        );

        // every exit view now reverts, so redeem() reverts too — even for
        // a depositor who only wants idle USDC:
        vm.expectRevert();
        strategy.availableWithdrawLimit(user);
        vm.expectRevert();
        strategy.maxRedeem(user);
        vm.expectRevert();
        strategy.redeem(1, user, user);
    }

    // ---------------------------------------------------------------
    // F3 | _freeFunds | unclaimed-position-brick
    // One reverting claimRedemption blocks redeem/withdraw/tend/
    // emergencyWithdraw. Trigger shown: MYT transfer gate off, which
    // stops the MYT payout transfer transmuter -> strategy.
    // ---------------------------------------------------------------
    function poc_claimBrick() public {
        buyAndTransmute(100_000e6);
        mature();

        // gate flip: transmuter can no longer send MYT shares
        vm.mockCall(
            address(myt),
            abi.encodeWithSelector(IMYT.canSendShares.selector, address(transmuter)),
            abi.encode(false)
        );

        // the claim itself now reverts -> the unguarded loop reverts ->
        // _withdraw/_tend/_emergencyWithdraw all revert:
        vm.expectRevert();
        tend();
        vm.prank(user);
        vm.expectRevert();
        strategy.redeem(1, user, user);
        vm.prank(emergencyAdmin);
        vm.expectRevert();
        strategy.emergencyWithdraw(type(uint256).max);
    }
}
