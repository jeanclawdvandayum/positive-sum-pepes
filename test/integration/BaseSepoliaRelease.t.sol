// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPStaker} from "../../src/PSPStaker.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../src/PSPZapOut.sol";
import {PSPReinvestor} from "../../src/PSPReinvestor.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface IFreeMix { function mint(address to, uint256 amount) external; }

/// @title BaseSepoliaReleaseTest
/// @notice Fork-only validation of actual deployed code; never broadcasts transactions.
contract BaseSepoliaReleaseTest is Test {
    function test_DeployedReleaseTwoRoundsAndOldExits() public {
        if (!vm.envOr("PSP_RELEASE_TESTNET", false)) { vm.skip(true); return; }
        assertEq(block.chainid, 84532, "testnet only");
        PSPFactory factory = PSPFactory(vm.envAddress("PSP_FACTORY"));
        PSPZapIn zapIn = PSPZapIn(vm.envAddress("PSP_ZAPIN"));
        PSPZapOut zapOut = PSPZapOut(vm.envAddress("PSP_ZAPOUT"));
        PSPReinvestor reinvestor = PSPReinvestor(vm.envAddress("PSP_REINVESTOR"));
        PSPFactory.Round memory r = factory.getRound(1);
        PSPStaker staker = r.controller.staker();
        IERC20 mix = factory.mixETH();
        address a = makeAddr("release-alice");
        address b = makeAddr("release-bob");
        assertEq(r.hook.MIN_BUY_INPUT(), 0.005e18);
        assertEq(r.hook.TIME_PER_UNIT(), 260);
        assertEq(address(reinvestor.staker()), address(staker));

        IFreeMix(address(mix)).mint(a, 50e18);
        IFreeMix(address(mix)).mint(b, 50e18);
        IFreeMix(address(mix)).mint(address(this), 100e18);
        vm.startPrank(a); mix.approve(address(r.controller), 50e18); r.controller.predeposit(50e18); vm.stopPrank();
        vm.startPrank(b); mix.approve(address(r.controller), 50e18); r.controller.predeposit(50e18); vm.stopPrank();
        skip(r.controller.PREDEPOSIT_DURATION());
        r.controller.launchPooledBuy();
        vm.prank(a); r.controller.claimPredepositPSP();
        uint256 idA = staker.primaryOf(a);
        Currency c0 = Currency.wrap(address(mix)); Currency c1 = Currency.wrap(address(r.token));
        if(c0 > c1) (c0,c1)=(c1,c0);
        PoolKey memory key = PoolKey(c0,c1,0x800000,60,r.hook);
        mix.approve(address(zapIn), type(uint256).max);
        uint256 bought = zapIn.buyWithMix(key, 2e18, r.hook.getBuyOutput(2e18), block.timestamp);
        r.token.approve(address(zapOut), bought);
        zapOut.sellToMix(key, bought / 2, 1, block.timestamp);
        assertEq(r.hook.ticketCount(), 400);
        assertGt(staker.pendingFeesOf(0), 0, "unclaimed genesis share keeps fees");
        vm.prank(b); r.controller.claimPredepositPSP();
        uint256 idB = staker.primaryOf(b);
        vm.prank(a); staker.requestWithdraw(idA);
        zapIn.buyWithMix(key, 1e18, 1, block.timestamp);
        uint256 earned = staker.pendingFeesOf(idA);
        assertGt(earned, 0);
        skip(30 minutes);
        assertEq(staker.pendingFeesOf(idA), earned, "earned credit does not decay");
        vm.startPrank(b);
        staker.setApprovalForAll(address(reinvestor), true);
        reinvestor.reinvest(idB, key, 1, block.timestamp);
        vm.stopPrank();
        skip(r.hook.detonationAt() - block.timestamp);
        r.controller.detonate{gas: 1_000_000}();
        vm.prank(a); staker.withdraw(idA);
        assertGt(mix.balanceOf(a), 0, "earned fees paid on withdrawal");

        factory.reserveSpawn(1);
        for (uint256 i; i < 3; ++i) factory.birthStep{gas: 12_000_000}();
        assertEq(factory.currentRoundId(), 2);
        PSPFactory.Round memory next = factory.getRound(2);
        mix.approve(address(next.controller), 0.005e18);
        next.controller.predeposit(0.005e18);
        skip(next.controller.PREDEPOSIT_DURATION());
        next.controller.launchPooledBuy();
        assertEq(uint8(next.hook.mode()), uint8(CurveHook.Mode.Active));
        assertEq(next.hook.TIME_PER_UNIT(), 260);

        // The new round is active before the old round's final exits.
        vm.prank(b); staker.withdraw(idB);
        address[3] memory holders = [a,b,address(this)];
        for(uint256 i; i < 3; ++i){
            vm.startPrank(holders[i]);
            uint256 balance = r.token.balanceOf(holders[i]);
            r.token.approve(address(r.hook), balance);
            if(balance > 0)r.hook.redeemBacking(balance);
            if(r.hook.claimablePot(holders[i]) > 0)r.hook.claimPot();
            vm.stopPrank();
        }
        assertEq(staker.totalLocked(), 0);
        assertEq(r.token.totalSupply(), 0);
        assertEq(r.hook.reserveMixETH(), 0);
        assertEq(uint8(next.hook.mode()), uint8(CurveHook.Mode.Active));
    }
}
