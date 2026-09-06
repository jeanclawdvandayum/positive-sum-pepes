// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PSPNameRegistrar} from "../../src/names/PSPNameRegistrar.sol";
import {PSPRemoteNameGate} from "../../src/names/PSPRemoteNameGate.sol";
import {IWeiNames} from "../../src/interfaces/IWeiNames.sol";
import {CustodyNamesMock} from "./NameCustody.t.sol";

contract NameRemoteGateTest is Test {
    uint256 constant KEY = 0xA11CE;
    address admin = address(0xAD);
    address alice = address(0xA1);
    address bob = address(0xB0);
    bytes32 salt = keccak256("salt");
    CustodyNamesMock names;
    PSPNameRegistrar reg;
    PSPRemoteNameGate gate;

    function setUp() public {
        vm.warp(1800000000);
        names = new CustodyNamesMock(admin);
        gate = new PSPRemoteNameGate(admin, vm.addr(KEY), 84532, address(0xFA));
        reg = new PSPNameRegistrar(IWeiNames(address(names)), 1, admin, gate);
        vm.startPrank(admin);
        names.safeTransferFrom(admin, address(reg), 1);
        reg.setRegistrationEnabled(true);
        vm.stopPrank();
        _commit(alice, "frog");
        skip(60);
        vm.deal(bob, 1 ether);
    }
    function _commit(address who, string memory label) internal {
        bytes32 hash = reg.makeCommitment(who, label, salt);
        vm.prank(who); reg.commit(hash);
    }
    function _permit() internal view returns (PSPRemoteNameGate.Permit memory p) {
        (bytes32 hash,, uint64 epoch, uint256 version) = reg.commitments(alice);
        p = PSPRemoteNameGate.Permit(address(reg), alice, hash, reg.commitNonce(alice), epoch, version,
            gate.signerEpoch(), 1, 0, 1234, keccak256("source block"), block.timestamp, block.timestamp + 180);
    }
    function _sign(PSPRemoteNameGate.Permit memory p) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, gate.permitDigest(p));
        return abi.encode(p, v, r, s);
    }
    function _reject(bytes memory proof) internal {
        vm.expectRevert(); reg.registrationPrice(alice, proof);
    }
    function testFreeRemoteRegisterAndEmptyProofPaidRegister() public {
        bytes memory proof = _sign(_permit());
        assertEq(reg.registrationPrice(alice, proof), 0);
        vm.prank(alice); uint256 id = reg.register("frog", salt, proof);
        assertEq(names.ownerOf(id), alice);
        assertEq(reg.primaryName(alice), id);
        _reject(proof); // consumption invalidates the permit even before expiry
        _commit(bob, "paid"); skip(60);
        vm.prank(bob); reg.register{value: 0.0005 ether}("paid", salt, "");
        assertEq(address(reg).balance, 0.0005 ether);
    }
    function testRepeatFundedClaimsRemainAllowedWithFreshCommitAndPermit() public {
        bytes memory proof = _sign(_permit());
        vm.prank(alice); reg.register("frog", salt, proof);
        _commit(alice, "frog-two"); skip(60);
        proof = _sign(_permit());
        vm.prank(alice); uint256 id = reg.register("frog-two", salt, proof);
        assertEq(names.balanceOf(alice), 2);
        assertEq(reg.primaryName(alice), id);
    }
    function testSameHashSameBlockReplacementInvalidatesOldPermit() public {
        bytes memory proof = _sign(_permit());
        _commit(alice, "frog");
        _reject(proof);
        assertEq(reg.commitNonce(alice), 2);
    }
    function testSignerRevocationRotationAndReturnInvalidatesOldPermits() public {
        bytes memory proof = _sign(_permit());
        vm.prank(bob); vm.expectRevert(); gate.setSigner(bob);
        vm.prank(admin); gate.setSigner(address(0));
        _reject(proof);
        assertEq(reg.registrationPrice(bob, ""), 0.0005 ether);
        vm.prank(admin); gate.setSigner(vm.addr(KEY));
        _reject(proof);
        assertEq(reg.registrationPrice(alice, _sign(_permit())), 0);
    }
    function testPermitLifetimeBoundaries() public {
        PSPRemoteNameGate.Permit memory p = _permit();
        bytes memory proof = _sign(p);
        skip(180);
        assertEq(reg.registrationPrice(alice, proof), 0);
        skip(1); _reject(proof);
        p = _permit(); p.issuedAt += 1; _reject(_sign(p));
        p = _permit(); p.deadline += 1; _reject(_sign(p));
        p = _permit(); p.deadline = p.issuedAt - 1; _reject(_sign(p));
    }
    function testWrongWalletGateRegistrarChainAndSignerRejected() public {
        PSPRemoteNameGate.Permit memory p = _permit();
        bytes memory proof = _sign(p);
        vm.expectRevert(); reg.registrationPrice(bob, proof);
        vm.expectRevert(); gate.isEligible(alice, proof);
        uint256 chain = block.chainid;
        vm.chainId(chain + 1); _reject(proof); vm.chainId(chain);
        PSPRemoteNameGate other = new PSPRemoteNameGate(admin, vm.addr(KEY), 84532, address(0xFA));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, other.permitDigest(p));
        _reject(abi.encode(p, v, r, s));
        (v,r,s) = vm.sign(KEY + 1, gate.permitDigest(p));
        _reject(abi.encode(p, v, r, s));
        p.registrar = address(other); _reject(_sign(p));
    }
    function testParentAndGateEpochChangesInvalidatePermit() public {
        bytes memory proof = _sign(_permit());
        names.advanceEpoch();
        vm.prank(admin); reg.setRegistrationEnabled(true);
        _reject(proof);
        _commit(alice, "frog"); proof = _sign(_permit());
        vm.prank(admin); reg.setEligibilityGate(gate);
        vm.prank(admin); reg.setRegistrationEnabled(true);
        _reject(proof);
    }
    function testFuzzEverySignedWordIsAuthenticated(uint8 word, bytes32 mask) public {
        vm.assume(mask != 0);
        bytes memory proof = _sign(_permit());
        uint256 offset = uint256(word % 13) * 32;
        assembly ("memory-safe") {
            let loc := add(add(proof, 32), offset)
            mstore(loc, xor(mload(loc), mask))
        }
        _reject(proof);
    }
    function testFuzzMalformedProofNeverBecomesPaid(uint16 length) public {
        length = uint16(bound(length, 1, 2048));
        _reject(new bytes(length));
    }
    function testRecoveryAdminCanRotateInTwoStepsButCannotRenounce() public {
        vm.prank(admin); vm.expectRevert(PSPRemoteNameGate.KeepRecoveryAdmin.selector); gate.renounceOwnership();
        vm.prank(admin); gate.transferOwnership(bob);
        vm.prank(alice); vm.expectRevert(); gate.acceptOwnership();
        vm.prank(bob); gate.acceptOwnership();
        vm.prank(bob); gate.setSigner(bob);
        assertEq(gate.signer(), bob);
    }
}
