// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IWeiNames} from "../../src/interfaces/IWeiNames.sol";
import {PSPNameCustody} from "../../src/names/PSPNameCustody.sol";
import {NameCustodyHarness} from "../unit/NameCustody.t.sol";
import {PSPNameRegistrar} from "../../src/names/PSPNameRegistrar.sol";
import {NameGateMock} from "../unit/NameRegistrar.t.sol";

/// @notice Local fork only: never signs or broadcasts an Ethereum transaction.
/// Run with WNS_FORK_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-contract WeiNamesForkTest -vv
contract WeiNamesForkTest is Test {
    IWeiNames constant WNS = IWeiNames(0x0000000000696760E15f265e828DB644A0c242EB);
    uint256 constant PARENT = 6361740363536127648378182158538670061512393038427336338828631921647240523046;
    address constant ADMIN = 0x1d52Ad18c074b8125fBCFDFcD01773c6BEdbd88A;
    address alice = address(0xA11CE);
    NameCustodyHarness custody;

    function setUp() public {
        vm.createSelectFork(vm.envString("WNS_FORK_RPC_URL"), 25915356);
        assertEq(address(WNS).codehash, 0x5b791c832d4373a8d4f977c37d6973a5dbe0924c6d287a2effaa549be31c0221);
        assertEq(WNS.ownerOf(PARENT), ADMIN);
        assertEq(WNS.getFullName(PARENT), "pepetesters.wei");
        custody = new NameCustodyHarness(WNS, PARENT, ADMIN);
    }

    function testApprovalAloneCannotRegisterChildren() public {
        vm.prank(ADMIN);
        WNS.approve(address(custody), PARENT);
        vm.prank(address(custody));
        vm.expectRevert();
        WNS.registerSubdomainFor("psp-fork-check", PARENT, alice);
    }

    function testActualWNSFreeAndPaidRegistrarFlow() public {
        NameGateMock gate = new NameGateMock();
        gate.setEligible(alice, true);
        PSPNameRegistrar registrar = new PSPNameRegistrar(WNS, PARENT, ADMIN, gate);
        vm.startPrank(ADMIN);
        WNS.safeTransferFrom(ADMIN, address(registrar), PARENT);
        registrar.setRegistrationEnabled(true);
        vm.stopPrank();
        address bob = address(0xB0B);
        bytes32 salt = keccak256("local-fork-secret");
        bytes32 freeCommit = registrar.makeCommitment(alice, "psp-free-rehearsal", salt);
        bytes32 paidCommit = registrar.makeCommitment(bob, "psp-paid-rehearsal", salt);
        vm.prank(alice);
        registrar.commit(freeCommit);
        vm.prank(bob);
        registrar.commit(paidCommit);
        skip(60);
        vm.prank(alice);
        uint256 freeId = registrar.register("psp-free-rehearsal", salt, "");
        vm.deal(bob, 0.0005 ether);
        vm.prank(bob);
        uint256 paidId = registrar.register{value: 0.0005 ether}("psp-paid-rehearsal", salt, "");
        assertEq(WNS.ownerOf(freeId), alice);
        assertEq(WNS.getFullName(freeId), "psp-free-rehearsal.pepetesters.wei");
        assertEq(WNS.resolve(paidId), bob);
        assertEq(registrar.primaryName(alice), freeId);
        assertEq(registrar.primaryName(bob), paidId);
        assertEq(address(registrar).balance, 0.0005 ether);
    }

    function testRealCustodyMintResolveRecoverAndRenew() public {
        vm.startPrank(ADMIN);
        WNS.safeTransferFrom(ADMIN, address(custody), PARENT);
        custody.setRegistrationEnabled(true);
        vm.stopPrank();
        custody.checkActive();
        vm.prank(address(custody));
        uint256 id = WNS.registerSubdomainFor("psp-fork-check", PARENT, alice);
        assertEq(WNS.ownerOf(id), alice);
        assertEq(WNS.resolve(id), alice);
        assertEq(WNS.getFullName(id), "psp-fork-check.pepetesters.wei");
        assertEq(WNS.primaryName(alice), 0, "WNS does not set the user's reverse record automatically");
        assertFalse(WNS.isAvailable("psp-fork-check", PARENT));
        uint256 fee = WNS.getFee(bytes("pepetesters").length);
        vm.deal(ADMIN, fee);
        vm.startPrank(ADMIN);
        custody.setParentAddress(ADMIN);
        custody.setParentText("url", "https://example.com");
        custody.setParentCoinAddress(60, abi.encodePacked(ADMIN));
        custody.setParentContenthash(hex"e3010170");
        custody.renewParent{value: fee}();
        custody.recoverParent(ADMIN);
        vm.stopPrank();
        assertEq(WNS.ownerOf(PARENT), ADMIN);
        assertEq(WNS.ownerOf(id), alice);
        assertEq(WNS.resolve(id), alice);
        assertFalse(custody.registrationEnabled());
    }

    function testExpiredParentNeedsRenewalBeforeRecoveryAndChildResolution() public {
        vm.startPrank(ADMIN);
        WNS.safeTransferFrom(ADMIN, address(custody), PARENT);
        custody.setRegistrationEnabled(true);
        vm.stopPrank();
        vm.prank(address(custody));
        uint256 id = WNS.registerSubdomainFor("psp-fork-expiry", PARENT, alice);
        skip(366 days);
        assertEq(WNS.resolve(id), address(0));
        vm.startPrank(ADMIN);
        vm.expectRevert();
        custody.recoverParent(ADMIN);
        uint256 fee = WNS.getFee(bytes("pepetesters").length);
        vm.deal(ADMIN, fee);
        custody.renewParent{value: fee}();
        custody.recoverParent(ADMIN);
        vm.stopPrank();
        assertEq(WNS.resolve(id), alice);
    }
}
