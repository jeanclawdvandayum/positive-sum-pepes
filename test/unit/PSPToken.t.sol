// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {PSPToken} from "../../src/PSPToken.sol";

/// @title PSPTokenTest — Access control and edge case tests for PSP token
contract PSPTokenTest is Test {
    PSPToken token;
    address factory = makeAddr("factory");
    address controller = makeAddr("controller");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");

    function setUp() public {
        token = new PSPToken("Positive Sum Pepes", "PSP", factory);
    }

    // ═════════════════════════════════════════════════════════
    //  DEPLOYMENT TESTS
    // ═════════════════════════════════════════════════════════

    function test_Deploy_NameSymbol() public view {
        assertEq(token.name(), "Positive Sum Pepes");
        assertEq(token.symbol(), "PSP");
    }

    function test_Deploy_FactorySet() public view {
        assertEq(token.factory(), factory);
    }

    function test_Deploy_ControllerNotSetYet() public view {
        assertEq(token.controller(), address(0));
    }

    function test_Deploy_ZeroFactoryFails() public {
        vm.expectRevert(PSPToken.ZeroAddress.selector);
        new PSPToken("Test", "TST", address(0));
    }

    // ═════════════════════════════════════════════════════════
    //  ACCESS CONTROL TESTS
    // ═════════════════════════════════════════════════════════

    /// @dev Only factory can set controller
    function test_AC_OnlyFactoryCanSetController() public {
        vm.prank(factory);
        token.setController(controller);
        assertEq(token.controller(), controller);
    }

    /// @dev Attacker can't set controller
    function test_AC_AttackerCantSetController() public {
        vm.prank(attacker);
        vm.expectRevert(PSPToken.OnlyFactory.selector);
        token.setController(attacker);
    }

    /// @dev Can't set controller twice
    function test_AC_CantSetControllerTwice() public {
        vm.prank(factory);
        token.setController(controller);

        vm.prank(factory);
        vm.expectRevert(PSPToken.AlreadySet.selector);
        token.setController(alice);
    }

    /// @dev Can't set controller to zero address
    function test_AC_CantSetZeroController() public {
        vm.prank(factory);
        vm.expectRevert(PSPToken.ZeroAddress.selector);
        token.setController(address(0));
    }

    /// @dev Only controller can mint
    function test_AC_OnlyControllerCanMint() public {
        vm.prank(factory);
        token.setController(controller);

        vm.prank(controller);
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
    }

    /// @dev Attacker can't mint
    function test_AC_AttackerCantMint() public {
        vm.prank(factory);
        token.setController(controller);

        vm.prank(attacker);
        vm.expectRevert(PSPToken.OnlyController.selector);
        token.mint(attacker, 1e18);
    }

    /// @dev Only controller can burn
    function test_AC_OnlyControllerCanBurn() public {
        vm.prank(factory);
        token.setController(controller);

        vm.prank(controller);
        token.mint(alice, 100e18);

        vm.prank(controller);
        token.burn(alice, 50e18);
        assertEq(token.balanceOf(alice), 50e18);
    }

    /// @dev Attacker can't burn
    function test_AC_AttackerCantBurn() public {
        vm.prank(factory);
        token.setController(controller);

        vm.prank(controller);
        token.mint(alice, 100e18);

        vm.prank(attacker);
        vm.expectRevert(PSPToken.OnlyController.selector);
        token.burn(alice, 50e18);
    }

    /// @dev Can't mint before controller is set
    function test_AC_CantMintBeforeControllerSet() public {
        // Controller is address(0), nobody can call as 0
        // Even prank(0) won't work for external calls
        vm.expectRevert(PSPToken.OnlyController.selector);
        token.mint(alice, 100e18);
    }

    // ═════════════════════════════════════════════════════════
    //  ERC-20 STANDARD TESTS
    // ═════════════════════════════════════════════════════════

    function test_ERC20_Transfer() public {
        vm.prank(factory);
        token.setController(controller);

        vm.prank(controller);
        token.mint(alice, 100e18);

        vm.prank(alice);
        token.transfer(attacker, 30e18);
        assertEq(token.balanceOf(alice), 70e18);
        assertEq(token.balanceOf(attacker), 30e18);
    }

    function test_ERC20_TransferInsufficientBalance() public {
        vm.prank(factory);
        token.setController(controller);

        vm.prank(controller);
        token.mint(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert();
        token.transfer(attacker, 101e18);
    }

    function test_ERC20_ApproveAndTransferFrom() public {
        vm.prank(factory);
        token.setController(controller);

        vm.prank(controller);
        token.mint(alice, 100e18);

        vm.prank(alice);
        token.approve(attacker, 50e18);

        vm.prank(attacker);
        token.transferFrom(alice, attacker, 30e18);
        assertEq(token.balanceOf(alice), 70e18);
        assertEq(token.balanceOf(attacker), 30e18);
        assertEq(token.allowance(alice, attacker), 20e18);
    }

    function test_ERC20_TransferFromInsufficientAllowance() public {
        vm.prank(factory);
        token.setController(controller);

        vm.prank(controller);
        token.mint(alice, 100e18);

        vm.prank(alice);
        token.approve(attacker, 50e18);

        vm.prank(attacker);
        vm.expectRevert();
        token.transferFrom(alice, attacker, 51e18);
    }

    /// @dev Zero address transfer should fail
    function test_ERC20_TransferToZeroFails() public {
        vm.prank(factory);
        token.setController(controller);

        vm.prank(controller);
        token.mint(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert();
        token.transfer(address(0), 10e18);
    }

    // ═════════════════════════════════════════════════════════
    //  PERMIT TESTS
    // ═════════════════════════════════════════════════════════

    /// @dev Permit signature works
    function test_Permit_GrantsAllowance() public {
        vm.prank(factory);
        token.setController(controller);

        uint256 privateKey = 0xA11CE;
        address owner = vm.addr(privateKey);

        vm.prank(controller);
        token.mint(owner, 100e18);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(
                    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                    owner,
                    attacker,
                    50e18,
                    0,
                    deadline
                ))
            ))
        );

        token.permit(owner, attacker, 50e18, deadline, v, r, s);
        assertEq(token.allowance(owner, attacker), 50e18);
    }

    /// @dev Expired permit fails
    function test_Permit_ExpiredFails() public {
        vm.prank(factory);
        token.setController(controller);

        uint256 privateKey = 0xA11CE;
        address owner = vm.addr(privateKey);

        vm.prank(controller);
        token.mint(owner, 100e18);

        uint256 deadline = block.timestamp - 1; // past
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(
                    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                    owner,
                    attacker,
                    50e18,
                    0,
                    deadline
                ))
            ))
        );

        vm.expectRevert();
        token.permit(owner, attacker, 50e18, deadline, v, r, s);
    }

    // ═════════════════════════════════════════════════════════
    //  EDGE CASES
    // ═════════════════════════════════════════════════════════

    /// @dev Burn more than balance fails
    function test_Edge_BurnMoreThanBalance() public {
        vm.prank(factory);
        token.setController(controller);

        vm.prank(controller);
        token.mint(alice, 100e18);

        vm.prank(controller);
        vm.expectRevert();
        token.burn(alice, 101e18);
    }

    /// @dev Mint to zero address fails
    function test_Edge_MintToZero() public {
        vm.prank(factory);
        token.setController(controller);

        vm.prank(controller);
        vm.expectRevert();
        token.mint(address(0), 100e18);
    }

    /// @dev Mint 0 tokens (should work, no-op)
    function test_Edge_MintZero() public {
        vm.prank(factory);
        token.setController(controller);

        vm.prank(controller);
        token.mint(alice, 0);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Transfer 0 tokens (should work)
    function test_Edge_TransferZero() public {
        vm.prank(factory);
        token.setController(controller);

        vm.prank(controller);
        token.mint(alice, 100e18);

        vm.prank(alice);
        token.transfer(attacker, 0);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(attacker), 0);
    }

    /// @dev Total supply tracks correctly after multiple mints/burns
    function test_Edge_TotalSupplyConservation() public {
        vm.prank(factory);
        token.setController(controller);

        uint256 total = 0;
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(controller);
            token.mint(alice, 100e18);
            total += 100e18;
        }
        assertEq(token.totalSupply(), total, "Total supply after mints");

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(controller);
            token.burn(alice, 50e18);
            total -= 50e18;
        }
        assertEq(token.totalSupply(), total, "Total supply after burns");
    }
}
