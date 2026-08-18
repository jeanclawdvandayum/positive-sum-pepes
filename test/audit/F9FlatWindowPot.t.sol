// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {AuditLifecycleTest} from "./AuditLifecycle.t.sol";

/// @title F-9 probe: flat-window pot accrual at finalize.
/// @notice Second-eyes finding: pot PSP credited during the 3-day flat
///         window is never redeemed by finalizeCarpet. Its backing drains
///         to the factory as generic carry (round-2 predeposit shares)
///         instead of the ring-fenced side pot (share-less thickening),
///         and the residual pot PSP tokens die at the controller.
///         This test PINS current behavior — flip the asserts when fixed.
contract F9FlatWindowPotTest is AuditLifecycleTest {
    function test_F9_FlatWindowPotNeverRedeemed() public {
        _launchAndStake();
        _bomb();

        // carol trades during the flat window: buy then sell
        uint256 bought = _buy(carol, 10e18);
        vm.startPrank(carol);
        psp.approve(address(zapOut), type(uint256).max);
        uint256 back = zapOut.sellToMix(_key(), bought, 0, 0);
        vm.stopPrank();
        assertGt(back, 0, "flat sell paid");

        (uint256 potAfterSell,) = controller.potState();
        console2.log("pot PSP accrued during flat window:", potAfterSell);
        assertGt(potAfterSell, 0, "F9 setup: flat sell should accrue pot");

        // finalize the round
        skip(3 days + 1);
        controller.finalizeCarpet();

        (uint256 potAfterFinal,) = controller.potState();
        console2.log("pot PSP AFTER finalize:", potAfterFinal);
        // PIN: pot ledger still nonzero — never redeemed at finalize
        assertEq(potAfterFinal, potAfterSell, "PIN: F-9 present (not redeemed)");

        // residual PSP physically at controller beyond locker principal
        uint256 resid = psp.balanceOf(address(controller));
        uint256 locked = controller.totalLocked();
        assertEq(resid - locked, potAfterSell, "residual == unredeemed pot PSP");
    }
}
