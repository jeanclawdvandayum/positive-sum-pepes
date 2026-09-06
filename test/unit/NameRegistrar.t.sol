// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {PSPNameRegistrar} from "../../src/names/PSPNameRegistrar.sol";
import {PSPNameCustody} from "../../src/names/PSPNameCustody.sol";
import {INameEligibility} from "../../src/names/PSPStakeNameGate.sol";
import {IWeiNames} from "../../src/interfaces/IWeiNames.sol";
import {CustodyNamesMock} from "./NameCustody.t.sol";

contract NameGateMock is INameEligibility {
    mapping(address => bool) public qualified;
    function setEligible(address who, bool value) external { qualified[who] = value; }
    function isEligible(address who, bytes calldata) external view returns (bool) { return qualified[who]; }
}

contract NameReceiver is IERC721Receiver {
    PSPNameRegistrar public registrar;
    IWeiNames public names;
    bool public forward;
    bool public reentrySucceeded;
    constructor(PSPNameRegistrar r, IWeiNames n, bool forward_) { registrar = r; names = n; forward = forward_; }
    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        (reentrySucceeded,) = address(registrar).call(abi.encodeCall(registrar.commit, (bytes32(uint256(1)))));
        if (forward) names.transferFrom(address(this), address(0xBAD), id);
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract NameRegistrarTest is Test {
    address admin = address(0xAD);
    address alice = address(0xA1);
    address bob = address(0xB0);
    bytes32 salt = bytes32(uint256(1234));
    CustodyNamesMock names;
    NameGateMock gate;
    PSPNameRegistrar reg;

    function setUp() public {
        names = new CustodyNamesMock(admin);
        gate = new NameGateMock();
        reg = new PSPNameRegistrar(IWeiNames(address(names)), 1, admin, gate);
        gate.setEligible(alice, true);
        vm.startPrank(admin);
        names.safeTransferFrom(admin, address(reg), 1);
        reg.setRegistrationEnabled(true);
        vm.stopPrank();
        vm.deal(bob, 1 ether);
    }
    function _commit(address who, string memory label) internal {
        bytes32 c = reg.makeCommitment(who, label, salt);
        vm.prank(who);
        reg.commit(c);
    }
    function _register(address who, string memory label, uint256 value) internal returns (uint256) {
        _commit(who, label);
        skip(60);
        vm.prank(who);
        return reg.register{value: value}(label, salt, "");
    }
    function testFreeAndPaidRegisterDirectlyToWalletAndSelectPrimary() public {
        uint256 a = _register(alice, "frog", 0);
        uint256 b = _register(bob, "degen", 0.0005 ether);
        assertEq(names.ownerOf(a), alice);
        assertEq(names.resolve(a), alice);
        assertEq(reg.primaryName(alice), a);
        assertEq(reg.primaryName(bob), b);
        assertEq(address(reg).balance, 0.0005 ether);
    }
    function testCopiedCommitmentCannotStealRevealedName() public {
        _commit(alice, "frog");
        bytes32 stolen = reg.makeCommitment(alice, "frog", salt);
        vm.prank(bob);
        reg.commit(stolen);
        skip(60);
        vm.prank(bob);
        vm.expectRevert(PSPNameRegistrar.InvalidCommitment.selector);
        reg.register{value: 0.0005 ether}("frog", salt, "");
        vm.prank(alice);
        reg.register("frog", salt, "");
    }
    function testCommitmentTimingAndReplay() public {
        _commit(alice, "frog");
        vm.prank(alice);
        vm.expectRevert(PSPNameRegistrar.CommitmentTooYoung.selector);
        reg.register("frog", salt, "");
        skip(60);
        vm.prank(alice);
        reg.register("frog", salt, "");
        vm.prank(alice);
        vm.expectRevert(PSPNameRegistrar.InvalidCommitment.selector);
        reg.register("frog", salt, "");
        _commit(alice, "frog-two");
        skip(1 days + 1);
        vm.prank(alice);
        vm.expectRevert(PSPNameRegistrar.CommitmentExpired.selector);
        reg.register("frog-two", salt, "");
    }
    function testPublicCallerCannotReclaimOccupiedChild() public {
        uint256 id = _register(alice, "frog", 0);
        _commit(bob, "frog");
        skip(60);
        vm.prank(bob);
        vm.expectRevert(PSPNameRegistrar.NameUnavailable.selector);
        reg.register{value: 0.0005 ether}("frog", salt, "");
        assertEq(names.ownerOf(id), alice);
    }
    function testEligibilityIsRecheckedAtReveal() public {
        _commit(alice, "frog");
        gate.setEligible(alice, false);
        skip(60);
        vm.prank(alice);
        vm.expectRevert(PSPNameCustody.WrongPayment.selector);
        reg.register("frog", salt, "");
        vm.deal(alice, 0.0005 ether);
        vm.prank(alice);
        reg.register{value: 0.0005 ether}("frog", salt, "");
    }
    function testFuzzExactFeeOnly(uint96 payment) public {
        vm.assume(payment != 0.0005 ether);
        vm.deal(bob, payment);
        _commit(bob, "frog");
        skip(60);
        vm.prank(bob);
        vm.expectRevert(PSPNameCustody.WrongPayment.selector);
        reg.register{value: payment}("frog", salt, "");
        assertEq(address(reg).balance, 0);
    }
    function testFuzzCommitmentSeparatesWalletChainDeploymentAndSalt(address other, uint64 chain, bytes32 differentSalt) public {
        bytes32 original = reg.makeCommitment(alice, "frog", salt);
        if (other != alice) assertNotEq(original, reg.makeCommitment(other, "frog", salt));
        if (differentSalt != salt) assertNotEq(original, reg.makeCommitment(alice, "frog", differentSalt));
        uint256 oldChain = block.chainid;
        vm.chainId(chain);
        if (chain != oldChain) assertNotEq(original, reg.makeCommitment(alice, "frog", salt));
        vm.chainId(oldChain);
        PSPNameRegistrar otherRegistrar = new PSPNameRegistrar(IWeiNames(address(names)), 1, admin, gate);
        assertNotEq(original, otherRegistrar.makeCommitment(alice, "frog", salt));
    }
    function testGateRotationPausesAndInvalidatesOldCommitment() public {
        _commit(alice, "frog");
        vm.startPrank(admin);
        reg.setEligibilityGate(new NameGateMock());
        assertFalse(reg.registrationEnabled());
        reg.setRegistrationEnabled(true);
        vm.stopPrank();
        skip(60);
        vm.prank(alice);
        vm.expectRevert(PSPNameRegistrar.InvalidCommitment.selector);
        reg.register("frog", salt, "");
    }
    function testParentEpochRotationInvalidatesOldCommitment() public {
        _commit(alice, "frog");
        names.advanceEpoch();
        vm.prank(admin);
        reg.setRegistrationEnabled(true);
        skip(60);
        vm.prank(alice);
        vm.expectRevert(PSPNameRegistrar.InvalidCommitment.selector);
        reg.register("frog", salt, "");
    }
    function testReceiverReentryFailsAndMintTimeTransferRevertsAtomically() public {
        NameReceiver normal = new NameReceiver(reg, IWeiNames(address(names)), false);
        gate.setEligible(address(normal), true);
        _register(address(normal), "contract-frog", 0);
        assertFalse(normal.reentrySucceeded());
        NameReceiver forwarding = new NameReceiver(reg, IWeiNames(address(names)), true);
        gate.setEligible(address(forwarding), true);
        _commit(address(forwarding), "forwarding-frog");
        skip(60);
        vm.prank(address(forwarding));
        vm.expectRevert(PSPNameRegistrar.NameOwnershipMismatch.selector);
        reg.register("forwarding-frog", salt, "");
        assertTrue(names.isAvailable("forwarding-frog", 1));
        assertEq(reg.primaryName(address(forwarding)), 0);
    }
    function testTransferredNameCanBeSelectedOnlyByNewOwnerWithMatchingResolution() public {
        uint256 id = _register(alice, "frog", 0);
        vm.startPrank(alice);
        names.transferFrom(alice, bob, id);
        vm.expectRevert(PSPNameRegistrar.NameOwnershipMismatch.selector);
        reg.selectPrimaryName(id);
        vm.stopPrank();
        vm.startPrank(bob);
        reg.selectPrimaryName(id);
        assertEq(reg.primaryName(bob), id);
        names.setAddr(id, alice);
        vm.expectRevert(PSPNameRegistrar.NameOwnershipMismatch.selector);
        reg.selectPrimaryName(id);
        reg.selectPrimaryName(0);
        vm.stopPrank();
        assertEq(reg.primaryName(bob), 0);
    }
    function testFeeRevenueOnlyAdminWithdraws() public {
        _register(bob, "frog", 0.0005 ether);
        vm.prank(bob);
        vm.expectRevert();
        reg.withdrawFees(payable(bob));
        vm.prank(admin);
        reg.withdrawFees(payable(admin));
        assertEq(admin.balance, 0.0005 ether);
        assertEq(address(reg).balance, 0);
    }
    function testInvalidLabelsRejectedBeforeCommitting() public {
        string[7] memory invalid = ["", "Frog", "frog.wei", "-frog", "frog-", "frog space", "123456789012345678901234567890123"];
        for (uint256 i; i < invalid.length; i++) {
            vm.expectRevert(PSPNameRegistrar.InvalidLabel.selector);
            reg.makeCommitment(alice, invalid[i], salt);
        }
    }
}
