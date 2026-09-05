// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RealV4Base} from "./RealV4Lifecycle.t.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {PSPReinvestor} from "../src/PSPReinvestor.sol";
import {IPSPStaker} from "../src/interfaces/IPSPStaker.sol";
import {IPSPZapIn} from "../src/interfaces/IPSPZapIn.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MultiOwnerStatefulTest
/// @notice Real V4, three wallets, transferable positions, vesting and complete exits.
contract MultiOwnerStatefulTest is RealV4Base {
    PSPStaker private staking;
    PSPReinvestor private compounder;
    address[3] private actors;
    uint256[] private ids;
    uint256[9] public successes;

    function testTimings() internal pure override returns (uint256) {
        return CurveMath.packTimingsCapped(1 hours, 1 hours, 2 hours, 0);
    }

    function setUp() public override {
        super.setUp();
        staking = controller.staker();
        compounder = new PSPReinvestor(IPSPStaker(address(staking)), IPSPZapIn(address(zapIn)),
            IERC20(address(mixETH)), IERC20(address(pspToken)));
        actors = [address(this), alice, bob];
        for (uint256 i; i < 3; ++i) {
            if (i != 0) mixETH.transfer(actors[i], 1000e18);
            vm.startPrank(actors[i]);
            mixETH.approve(address(zapIn), type(uint256).max);
            pspToken.approve(address(zapOut), type(uint256).max);
            pspToken.approve(address(hook), type(uint256).max);
            pspToken.approve(address(staking), type(uint256).max);
            staking.setApprovalForAll(address(compounder), true);
            vm.stopPrank();
        }
        vm.prank(bob); controller.claimPredepositPSP();
        ids.push(1);
        this.buy(0, 1e18); this.stake(0, 100);
        this.buy(1, 1e18); this.stake(1, 200);
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = this.buy.selector;
        selectors[1] = this.sell.selector;
        selectors[2] = this.stake.selector;
        selectors[3] = this.manageWithdrawal.selector;
        selectors[4] = this.movePosition.selector;
        selectors[5] = this.claim.selector;
        selectors[6] = this.withdraw.selector;
        selectors[7] = this.reinvest.selector;
        selectors[8] = this.advance.selector;
        selectors[9] = this.settle.selector;
        targetContract(address(this));
        targetSelector(FuzzSelector(address(this), selectors));
    }

    function _alive() private view returns (bool) {
        return hook.mode() == CurveHook.Mode.Active && block.timestamp < hook.detonationAt();
    }
    function _amount(uint256 id) private view returns (uint256 amount) { (amount,,,,) = staking.positions(id); }

    function buy(uint8 who, uint64 seed) external {
        if (!_alive()) return;
        address actor = actors[who % 3];
        uint256 balance = mixETH.balanceOf(actor);
        if (balance < 0.005e18) return;
        uint256 amount = bound(seed, 0.005e18, balance < 10e18 ? balance : 10e18);
        uint256 quote = hook.getBuyOutput(amount);
        vm.prank(actor); assertEq(zapIn.buyWithMix(poolKey, amount, quote, block.timestamp), quote);
        ++successes[0];
    }
    function sell(uint8 who, uint64 seed) external {
        if (!_alive()) return;
        address actor = actors[who % 3];
        uint256 balance = pspToken.balanceOf(actor);
        if (balance < 1e12) return;
        uint256 amount = bound(seed, 1e12, balance);
        uint256 quote = hook.getSellOutput(amount);
        if (quote == 0) return;
        vm.prank(actor); assertEq(zapOut.sellToMix(poolKey, amount, quote, block.timestamp), quote);
        ++successes[1];
    }
    function stake(uint8 who, uint64 seed) external {
        if (!_alive() || ids.length >= 15) return;
        address actor = actors[who % 3];
        uint256 balance = pspToken.balanceOf(actor);
        if (balance == 0) return;
        ids.push(staking.nextTokenId());
        vm.prank(actor); staking.lock(bound(seed, 1, balance));
        ++successes[2];
    }
    function manageWithdrawal(uint8 seed, bool cancel) external {
        uint256 id = ids[seed % ids.length];
        if (_amount(id) == 0) return;
        address owner = staking.ownerOf(id);
        if (cancel && staking.isWithdrawing(id)) {
            vm.prank(owner); staking.cancelWithdraw(id); ++successes[3];
        } else if (!cancel && !staking.isWithdrawing(id)) {
            vm.prank(owner); staking.requestWithdraw(id); ++successes[3];
        }
    }
    function movePosition(uint8 seed, uint8 who) external {
        uint256 id = ids[seed % ids.length];
        address owner = staking.ownerOf(id);
        vm.prank(owner); staking.transferFrom(owner, actors[who % 3], id);
        ++successes[4];
    }
    function claim(uint8 seed) external {
        uint256 id = ids[seed % ids.length];
        if (staking.pendingFeesOf(id) == 0) return;
        vm.prank(staking.ownerOf(id)); staking.claimFees(id);
        ++successes[5];
    }
    function withdraw(uint8 seed) public {
        uint256 id = ids[seed % ids.length];
        if (_amount(id) == 0) return;
        (,, uint256 r,,) = staking.positions(id);
        if (hook.mode() == CurveHook.Mode.Active &&
            (!staking.isWithdrawing(id) || block.timestamp / staking.epochSize() < r + 6)) return;
        vm.prank(staking.ownerOf(id)); staking.withdraw(id);
        ++successes[6];
    }
    function reinvest(uint8 seed) external {
        if (!_alive()) return;
        uint256 id = ids[seed % ids.length];
        uint256 fees = staking.pendingFeesOf(id);
        if (fees < 0.005e18 || _amount(id) == 0 || staking.isWithdrawing(id)) return;
        uint256 quote = hook.getBuyOutput(fees);
        vm.prank(staking.ownerOf(id)); compounder.reinvest(id, poolKey, quote, block.timestamp);
        ++successes[7];
    }
    function advance(uint16 seed) external { skip(bound(seed, 1, 15 minutes)); }
    function settle() public {
        if (hook.mode() != CurveHook.Mode.Active || block.timestamp < hook.detonationAt()) return;
        controller.detonate{gas: 1_000_000}(); ++successes[8];
    }
    function invariant_AllPositionAndEscrowLiabilitiesAreCovered() public view {
        uint256 principal;
        uint256 weight;
        uint256 owed = staking.pendingFeesOf(0) + staking.pendingFeesMixETH();
        for (uint256 i; i < ids.length; ++i) {
            principal += _amount(ids[i]);
            weight += staking.weightAt(ids[i], block.timestamp / staking.epochSize());
            owed += staking.pendingFeesOf(ids[i]);
        }
        assertEq(principal, staking.totalLocked());
        assertEq(principal, pspToken.balanceOf(address(staking)));
        assertEq(weight, staking.totalWeight());
        assertLe(owed + staking.totalFeesPaid(), staking.totalFeesReceived());
        assertGe(mixETH.balanceOf(address(hook)), hook.reserveMixETH() + hook.potBalance() - hook.potPaid()
            + hook.deployerCredit() - hook.deployerCreditPaid() + owed);
        assertEq(hook.totalSupplyPSP(), pspToken.totalSupply());
        assertEq(mixETH.balanceOf(address(compounder)), 0);
        assertEq(pspToken.balanceOf(address(compounder)), 0);
    }
    function afterInvariant() public {
        if (_alive()) skip(hook.detonationAt() - block.timestamp);
        settle();
        for (uint256 i; i < ids.length; ++i) withdraw(uint8(i));
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(actors[i]);
            uint256 balance = pspToken.balanceOf(actors[i]);
            if (balance > 0) hook.redeemBacking(balance);
            if (hook.claimablePot(actors[i]) > 0) hook.claimPot();
            vm.stopPrank();
        }
        invariant_AllPositionAndEscrowLiabilitiesAreCovered();
        assertEq(staking.totalLocked(), 0, "all principal exited");
        assertEq(pspToken.totalSupply(), 0, "all holders redeemed");
        assertEq(hook.reserveMixETH(), 0, "last redemption receives remaining backing");
    }

    function test_InterleavedActionsAndCompleteExit() public {
        this.manageWithdrawal(0, false);
        skip(20 minutes);
        this.buy(1, 1e18); this.claim(0);
        this.movePosition(0, 1);
        this.manageWithdrawal(0, true);
        this.buy(0, 1e18);
        this.reinvest(0);
        this.sell(1, 1e18);
        this.manageWithdrawal(0, false);
        skip(70 minutes);
        this.withdraw(0);
        invariant_AllPositionAndEscrowLiabilitiesAreCovered();
        afterInvariant();
        for (uint256 i; i < successes.length; ++i) assertGt(successes[i], 0, "action exercised");
    }
}
