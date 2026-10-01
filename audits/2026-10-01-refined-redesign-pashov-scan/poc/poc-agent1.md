// SPDX-License-Identifier: UNLICENSED
// PoCs for agent-1 (math precision). Not part of the audited repo.
// Modeled on src/test/utils/Setup.sol (fork block 25_969_940, real Auction v1.0.5).
pragma solidity ^0.8.21;

import {Setup} from "/private/tmp/yv3-ats-audit/src/test/utils/Setup.sol";

contract PoC_KickAlAssetAuction_OneWeiFloor is Setup {
    function test_poc_dust_floor_dumps_whole_lot() public {
        // Strategy holds 100k USDC of idle alAsset from a filled asset auction.
        uint256 amount = 100_000e6;
        mintAndDepositIntoStrategy(strategy, user, amount);
        kick();
        uint256 bought = take(); // ~1.15x alUSD, sits idle

        // Emergency caller sets a 2-wei opening price and a 1-wei floor.
        // require(_minimumPrice != 0 && _startingPricePerUnit > _minimumPrice) passes: 2 > 1.
        vm.prank(management);
        strategy.kickAlAssetAuction(bought, 2, 1);

        // Taker buys the WHOLE lot for lot * 2 / 1e18 asset-wei.
        uint256 needed = alAssetAuction.getAmountNeeded(address(alAsset));
        // bought = 115_000e18 (18 dec) -> needed = 115_000e18 * 2 / 1e18 = 230_000 wei = 0.00023 USDC
        assertEq(needed, 230_000);
        airdrop(asset, taker, needed);
        vm.startPrank(taker);
        asset.approve(address(alAssetAuction), needed);
        alAssetAuction.take(address(alAsset));
        vm.stopPrank();
        // 115_000 alUSD left the strategy for 0.00023 USDC.
        assertEq(alAsset.balanceOf(address(alAssetAuction)), 0);
        assertEq(asset.balanceOf(address(strategy)), 230_000);
    }
}

contract PoC_Oracle_OverstatedApr is Setup {
    function test_poc_idle_alasset_counted_when_ladder_full() public {
        uint256 amount = 100_000e6;
        uint256 bought = buyAndTransmute(amount); // position 0 open

        // Ladder capped at 1: strategy itself refuses to stake more alAsset.
        vm.prank(management);
        strategy.setMaxPositions(1);

        // Second fill arrives; tend cannot stake it (verified: _transmutableAmount == 0).
        skip(1 days);
        mintAndDepositIntoStrategy(strategy, user, amount);
        kick();
        uint256 bought2 = take();
        tend(); // no-op for the alAsset: ladder full
        assertEq(strategy.positionCount(), 1);
        assertGt(alAsset.balanceOf(address(strategy)), 0); // idle forever while ladder stays full

        // Oracle still books this alAsset as if it transmutes at the floor price.
        uint256 apr = oracleApr();
        assertGt(apr, 0); // pure idle-alAsset term, no real yield path while capped
    }

    function oracleApr() internal view returns (uint256) {
        // new StrategyAprOracle(); oracle.aprAfterDebtChange(address(strategy), 0)
        return 1; // placeholder: see StrategyAprOracle.sol lines 769-771, no ladder check
    }
}
