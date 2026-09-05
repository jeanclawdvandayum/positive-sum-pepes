// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {RealV4Base} from "./RealV4Lifecycle.t.sol";
import {CurveHook} from "../src/CurveHook.sol";

/// @title SineStatefulTest
/// @notice Random real-V4 trade/time/settlement sequences; unexpected reverts fail.
contract SineStatefulTest is RealV4Base {
    uint256 public successfulBuys;
    uint256 public successfulSells;

    function setUp() public override {
        super.setUp();
        mixETH.approve(address(zapIn), type(uint256).max);
        pspToken.approve(address(zapOut), type(uint256).max);
        pspToken.approve(address(hook), type(uint256).max);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0]=this.buy.selector;
        selectors[1]=this.sell.selector;
        selectors[2]=this.advance.selector;
        selectors[3]=this.settle.selector;
        selectors[4]=this.redeem.selector;
        targetSelector(FuzzSelector(address(this),selectors));
        targetContract(address(this));
        this.buy(0); // every run begins with a real funded trade
    }

    function buy(uint64 seed) external {
        if(hook.mode()!=CurveHook.Mode.Active || block.timestamp>=hook.detonationAt())return;
        uint256 balance=mixETH.balanceOf(address(this));
        if(balance<0.005e18)return;
        uint256 amount=bound(seed,0.005e18,balance<100e18?balance:100e18);
        uint256 quote=hook.getBuyOutput(amount);
        uint256 before=hook.ticketCount();
        uint256 got=zapIn.buyWithMix(poolKey,amount,quote,block.timestamp);
        assertEq(got,quote,"buy quote matches real settlement");
        assertEq(hook.ticketCount()-before,amount/0.005e18);
        successfulBuys++;
    }

    function sell(uint64 seed) external {
        if(hook.mode()!=CurveHook.Mode.Active || block.timestamp>=hook.detonationAt())return;
        uint256 balance=pspToken.balanceOf(address(this));
        if(balance<1e12)return;
        uint256 amount=bound(seed,1e12,balance);
        uint256 quote=hook.getSellOutput(amount);
        if(quote==0)return;
        uint256 deadline=hook.detonationAt();
        uint256 tickets=hook.ticketCount();
        assertEq(zapOut.sellToMix(poolKey,amount,quote,block.timestamp),quote);
        assertEq(hook.detonationAt(),deadline);
        assertEq(hook.ticketCount(),tickets);
        successfulSells++;
    }

    function advance(uint32 seed) external { skip(bound(seed,1,12 hours)); }

    function settle() external {
        if(hook.mode()!=CurveHook.Mode.Active || block.timestamp<hook.detonationAt())return;
        controller.detonate{gas:1_000_000}();
        if(hook.claimablePot(address(this))>0)hook.claimPot();
    }

    function redeem() external {
        if(hook.mode()!=CurveHook.Mode.Flat)return;
        uint256 balance=pspToken.balanceOf(address(this));
        if(balance>0)hook.redeemBacking(balance);
    }

    function invariant_SupplyAndEscrowSolvent() public view {
        assertEq(hook.totalSupplyPSP(),pspToken.totalSupply());
        uint256 liabilities=hook.reserveMixETH()+hook.potBalance()-hook.potPaid()
            +hook.deployerCredit()-hook.deployerCreditPaid()
            +controller.staker().pendingFeesMixETH()+controller.staker().pendingFeesOf(0);
        assertGe(mixETH.balanceOf(address(hook)),liabilities);
        assertLe(hook.seatedCount(),10);
        if(hook.mode()==CurveHook.Mode.Active)assertLe(hook.detonationAt(),block.timestamp+hook.detWindow());
        assertEq(mixETH.balanceOf(address(zapIn)),0);
        assertEq(pspToken.balanceOf(address(zapOut)),0);
    }
}
