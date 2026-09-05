// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {PSPReinvestor} from "../../src/PSPReinvestor.sol";
import {PSPStaker} from "../../src/PSPStaker.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {IPSPStaker} from "../../src/interfaces/IPSPStaker.sol";
import {IPSPZapIn} from "../../src/interfaces/IPSPZapIn.sol";
import {IMixETH} from "../../src/interfaces/IMixETH.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface IRepairMixMint { function mint(address to, uint256 amount) external; }

/// @title ReinvestRepairTest
/// @notice Local fork of the live round: replacement code before/after broadcast.
contract ReinvestRepairTest is Test {
    function test_RepairAgainstLiveRoundKeepsOwnerAttributionAndClaims() public {
        if (!vm.envOr("PSP_REINVEST_REPAIR_TEST", false)) { vm.skip(true); return; }
        assertEq(block.chainid, 84532);
        PSPFactory factory = PSPFactory(vm.envAddress("PSP_FACTORY"));
        PSPFactory.Round memory r = factory.getRound(factory.currentRoundId());
        PSPStaker staking = r.controller.staker();
        IERC20 mix = factory.mixETH();
        PSPZapIn zap;
        PSPReinvestor reinvestor;
        if (vm.envOr("PSP_USE_DEPLOYED_REPAIR", false)) {
            zap = PSPZapIn(vm.envAddress("PSP_ZAPIN"));
            reinvestor = PSPReinvestor(vm.envAddress("PSP_REINVESTOR"));
        } else {
            zap = new PSPZapIn(IMixETH(address(mix)), factory.poolManager());
            reinvestor = new PSPReinvestor(IPSPStaker(address(staking)), IPSPZapIn(address(zap)), mix, IERC20(address(r.token)));
        }
        assertEq(reinvestor.ATTRIBUTION_VERSION(), 1);
        assertEq(address(reinvestor.zapIn()), address(zap));
        assertEq(address(reinvestor.staker()), address(staking));
        assertEq(address(reinvestor.psp()), address(r.token));
        assertEq(address(reinvestor.mix()), address(mix));
        assertEq(uint8(r.hook.mode()), uint8(CurveHook.Mode.Active));
        address owner = makeAddr("repair-nft-owner");
        address operator = makeAddr("repair-operator");
        IRepairMixMint(address(mix)).mint(owner, 200e18);
        IRepairMixMint(address(mix)).mint(address(this), 500e18);
        Currency c0 = Currency.wrap(address(mix)); Currency c1 = Currency.wrap(address(r.token));
        if (c0 > c1) (c0, c1) = (c1, c0);
        PoolKey memory key = PoolKey(c0, c1, 0x800000, 60, r.hook);
        vm.startPrank(owner);
        mix.approve(address(zap), 200e18);
        uint256 bought = zap.buyWithMix(key, 200e18, 1, block.timestamp);
        r.token.approve(address(staking), bought);
        staking.lock(bought / 2); staking.lock(bought - bought / 2);
        uint256[] memory ids = new uint256[](2);
        ids[0] = staking.tokenOfOwnerByIndex(owner, 0); ids[1] = staking.tokenOfOwnerByIndex(owner, 1);
        staking.setApprovalForAll(address(reinvestor), true);
        staking.setApprovalForAll(operator, true);
        vm.stopPrank();
        mix.approve(address(zap), 500e18);
        zap.buyWithMix(key, 250e18, 1, block.timestamp);
        uint256 beforeTickets = r.hook.ticketCount();
        uint256 fees = staking.pendingFeesOf(ids[0]);
        assertGe(fees, 0.05e18);
        vm.prank(operator, makeAddr("repair-unrelated-origin"));
        reinvestor.reinvest(ids[0], key, 1, block.timestamp);
        assertEq(r.hook.ticketCount() - beforeTickets, fees / 0.005e18);
        for (uint256 i; i < 10; ++i) { (address buyer,,,) = r.hook.board(i); assertEq(buyer, owner); }
        zap.buyWithMix(key, 250e18, 1, block.timestamp);
        vm.prank(operator); reinvestor.reinvestAll(ids, key, 1, block.timestamp);
        for (uint256 i; i < 10; ++i) { (address buyer,,,) = r.hook.board(i); assertEq(buyer, owner); }
        assertEq(staking.ownerOf(ids[0]), owner); assertEq(staking.ownerOf(ids[1]), owner);
        assertEq(staking.balanceOf(owner), 2);
        assertEq(mix.balanceOf(address(reinvestor)), 0);
        assertLe(r.token.balanceOf(address(reinvestor)), 1);
        skip(r.hook.detonationAt() - block.timestamp);
        r.controller.detonate{gas: 1_000_000}();
        assertEq(r.hook.claimablePot(address(reinvestor)), 0);
        assertEq(r.hook.claimablePot(operator), 0);
        uint256 pot = r.hook.claimablePot(owner);
        assertGt(pot, 0);
        assertLt(r.hook.potBalance() - pot, 10, "only per-seat rounding dust remains");
        uint256 balance = mix.balanceOf(owner);
        vm.prank(owner); r.hook.claimPot();
        assertEq(mix.balanceOf(owner) - balance, pot);
    }
}
