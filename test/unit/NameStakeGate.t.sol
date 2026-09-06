// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BBase} from "../wave2/auditorB/BBase.sol";
import {PSPStakeNameGate, INameGateFactory} from "../../src/names/PSPStakeNameGate.sol";

/// @notice Gate integration against the production factory and actual PSP NFTs.
contract NameStakeGateTest is BBase {
    function testQualificationTracksPrincipalOwnershipAndRoundRegistry() public {
        _launch(100 ether);
        PSPStakeNameGate gate = new PSPStakeNameGate(INameGateFactory(address(factory)));
        uint256 id = stakerV.primaryOf(alice);
        bytes memory proof = abi.encode(uint256(1), id);
        assertTrue(gate.isEligible(alice, proof));
        assertFalse(gate.isEligible(bob, proof));
        assertFalse(gate.isEligible(alice, abi.encode(uint256(999), id)));
        assertFalse(gate.isEligible(alice, abi.encode(uint256(1), uint256(999))));
        assertFalse(gate.isEligible(alice, ""));
        assertFalse(gate.isEligible(alice, hex"01"));
        vm.prank(alice);
        stakerV.setApprovalForAll(bob, true);
        assertFalse(gate.isEligible(bob, proof), "operator is not owner");
        vm.prank(alice);
        stakerV.transferFrom(alice, bob, id);
        assertFalse(gate.isEligible(alice, proof));
        assertTrue(gate.isEligible(bob, proof));
        vm.prank(bob);
        stakerV.requestWithdraw(id);
        assertTrue(gate.isEligible(bob, proof), "positive principal still qualifies during exit");
        skip(50 days);
        vm.prank(bob);
        stakerV.withdraw(id);
        assertEq(stakerV.ownerOf(id), bob, "husk remains owned");
        assertFalse(gate.isEligible(bob, proof), "empty NFT does not qualify");
    }
}
