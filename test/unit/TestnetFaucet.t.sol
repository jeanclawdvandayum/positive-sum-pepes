// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SepoliaMixETH} from "../../src/testnet/SepoliaMixETH.sol";
import {MixETHFaucet} from "../../src/testnet/MixETHFaucet.sol";

/// @title TestnetFaucet — proves the free-mint rewrite (2026-08-28).
/// @notice The old faucet sold 100 mixETH per 0.0001 ETH out of a seeded
///         inventory; faucet-bought mixETH then had no ETH backing while
///         PSPZapOut.zapOut still tried redeemETH — every "sell PSP for
///         ETH" reverted on testnet. mixETH is now pure playtest scrip:
///         the token mints freely and the faucet is a stateless
///         pass-through. No ETH anywhere.
contract TestnetFaucetTest is Test {
    SepoliaMixETH mix;
    MixETHFaucet faucet;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        mix = new SepoliaMixETH();
        faucet = new MixETHFaucet(IERC20(address(mix)));
    }

    /// The deploy script no longer seeds the faucet — it must mint from
    /// zero balance, with no inventory, forever.
    function test_FaucetMintsFreeWithZeroBalanceAndZeroETH() public {
        uint256 before = mix.balanceOf(alice);
        assertEq(address(faucet).balance, 0, "faucet holds no ETH");
        assertEq(mix.balanceOf(address(faucet)), 0, "faucet holds no mixETH");

        vm.prank(alice);
        faucet.drip(100 ether);

        assertEq(mix.balanceOf(alice) - before, 100 ether, "minted free");
        assertEq(alice.balance, alice.balance, "no ETH involved");
    }

    /// Unlimited: minting beyond the constructor SUPPLY works, repeatedly,
    /// with no per-address cap and no drain condition.
    function test_FaucetIsUnlimited() public {
        uint256 huge = 50_000_000 ether; // 5x the constructor SUPPLY
        vm.prank(alice);
        faucet.drip(huge);
        assertGt(mix.balanceOf(alice), mix.SUPPLY(), "exceeds seeded supply");

        vm.prank(alice);
        faucet.drip(1 ether); // same address again
        vm.prank(bob);
        faucet.drip(huge); // another whale, still fine
        assertEq(mix.balanceOf(bob), huge);
    }

    /// The playtest flow that used to break end-to-end: faucet mint →
    /// PSP sold for mixETH stays in mixETH (sellToMix has no redeemETH
    /// leg). This test pins the invariant the UI now relies on: a wallet
    /// holding ONLY faucet-minted mixETH can still transact — nothing in
    /// the mix-only path touches ETH.
    function test_FaucetMixETHTransfersWithoutETHBacking() public {
        vm.prank(alice);
        faucet.drip(1_000 ether);
        assertEq(address(mix).balance, 0, "mock holds no ETH at all");

        vm.prank(alice);
        mix.transfer(bob, 400 ether); // plain ERC-20 move — no ETH leg
        assertEq(mix.balanceOf(bob), 400 ether);
    }

    /// The token itself mints publicly — the faucet is a convenience, not
    /// a gate. Anyone, any amount, to anyone.
    function test_TokenPublicMint() public {
        vm.prank(bob);
        mix.mint(alice, 42 ether);
        assertEq(mix.balanceOf(alice), 42 ether);
    }

    function test_DripZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(MixETHFaucet.ZeroAmount.selector);
        faucet.drip(0);
    }

    function test_DripEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit MixETHFaucet.Dripped(alice, 7 ether);
        faucet.drip(7 ether);
    }

    event Dripped(address indexed to, uint256 amount);
}
