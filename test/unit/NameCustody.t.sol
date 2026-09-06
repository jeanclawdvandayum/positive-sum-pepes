// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IWeiNames} from "../../src/interfaces/IWeiNames.sol";
import {PSPNameCustody} from "../../src/names/PSPNameCustody.sol";

contract NameCustodyHarness is PSPNameCustody {
    constructor(IWeiNames names_, uint256 id, address admin) PSPNameCustody(names_, id, admin) {}
    function checkActive() external view { _requireActiveParent(); }
}

/// @dev Behavioral fixture; canonical deployment is exercised separately on a fork.
contract CustodyNamesMock is ERC721 {
    struct Record { string label; uint256 parent; uint64 expiresAt; uint64 epoch; uint64 parentEpoch; }
    mapping(uint256 => Record) public records;
    mapping(uint256 => address) public resolved;
    uint256 public constant FEE = 0.001 ether;
    constructor(address holder) ERC721("WNS fixture", "WNS") {
        records[1] = Record("pepetesters", 0, uint64(block.timestamp + 365 days), 1, 0);
        _mint(holder, 1);
    }
    function resolve(uint256 id) external view returns (address) {
        Record memory r = records[id];
        if (r.parent == 0 ? r.expiresAt < block.timestamp :
            records[r.parent].expiresAt < block.timestamp || r.parentEpoch != records[r.parent].epoch) return address(0);
        return resolved[id] == address(0) ? ownerOf(id) : resolved[id];
    }
    function isAvailable(string calldata label, uint256 parent) external view returns (bool) {
        uint256 id = uint256(keccak256(abi.encodePacked(bytes32(parent), keccak256(bytes(label)))));
        return _ownerOf(id) == address(0) || records[id].parentEpoch != records[parent].epoch;
    }
    function registerSubdomainFor(string calldata label, uint256 parent, address to) external returns (uint256 id) {
        require(ownerOf(parent) == msg.sender);
        require(block.timestamp <= records[parent].expiresAt);
        id = uint256(keccak256(abi.encodePacked(bytes32(parent), keccak256(bytes(label)))));
        if (_ownerOf(id) != address(0)) _burn(id);
        records[id] = Record(label, parent, 0, records[id].epoch + 1, records[parent].epoch);
        delete resolved[id];
        _safeMint(to, id);
    }
    function getFee(uint256) external pure returns (uint256) { return FEE; }
    function renew(uint256 id) external payable { require(msg.value == FEE); records[id].expiresAt += 365 days; }
    function setAddr(uint256 id, address account) external { require(ownerOf(id) == msg.sender); resolved[id] = account; }
    function advanceEpoch() external { records[1].epoch++; }
    function mintOther(address to) external { _safeMint(to, 2); }
}

contract NameCustodyTest is Test {
    address admin = address(0xA11CE);
    address bob = address(0xB0B);
    CustodyNamesMock names;
    NameCustodyHarness custody;

    function setUp() public {
        names = new CustodyNamesMock(admin);
        custody = new NameCustodyHarness(IWeiNames(address(names)), 1, admin);
        vm.prank(admin);
        names.safeTransferFrom(admin, address(custody), 1);
    }

    function testCustodyRequiresExplicitActivationAndAdminCanRecover() public {
        vm.expectRevert(PSPNameCustody.RegistrationClosed.selector);
        custody.checkActive();
        vm.startPrank(admin);
        custody.setRegistrationEnabled(true);
        custody.checkActive();
        custody.recoverParent(admin);
        vm.stopPrank();
        assertEq(names.ownerOf(1), admin);
        assertFalse(custody.registrationEnabled());
        vm.prank(admin);
        vm.expectRevert(PSPNameCustody.InvalidParent.selector);
        custody.setRegistrationEnabled(true);
    }

    function testExpiryAndReregistrationFailClosed() public {
        vm.prank(admin);
        custody.setRegistrationEnabled(true);
        names.advanceEpoch();
        vm.expectRevert(PSPNameCustody.RegistrationClosed.selector);
        custody.checkActive();
        vm.prank(admin);
        custody.setRegistrationEnabled(true);
        skip(366 days);
        vm.expectRevert(PSPNameCustody.RegistrationClosed.selector);
        custody.checkActive();
    }

    function testOnlyAdminCanRecoverManageAndRenew() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        custody.recoverParent(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        custody.setParentAddress(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        custody.renewParent();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        custody.setRegistrationEnabled(true);
        vm.stopPrank();
        assertEq(names.ownerOf(1), address(custody));
    }

    function testTwoStepAdminRotationKeepsRecoveryAvailable() public {
        vm.prank(admin);
        custody.transferOwnership(bob);
        assertEq(custody.owner(), admin);
        vm.startPrank(bob);
        custody.acceptOwnership();
        custody.recoverParent(bob);
        vm.stopPrank();
        assertEq(names.ownerOf(1), bob);
        vm.prank(bob);
        vm.expectRevert(PSPNameCustody.OwnershipRequired.selector);
        custody.renounceOwnership();
    }

    function testRenewalUsesOnlyExactNewPayment() public {
        vm.deal(address(custody), 1 ether); // pre-existing registration fees
        vm.deal(admin, 1 ether);
        (,, uint64 beforeExpiry,,) = names.records(1);
        vm.startPrank(admin);
        vm.expectRevert(PSPNameCustody.WrongPayment.selector);
        custody.renewParent();
        vm.expectRevert(PSPNameCustody.WrongPayment.selector);
        custody.renewParent{value: 0.002 ether}();
        custody.renewParent{value: 0.001 ether}();
        vm.stopPrank();
        (,, uint64 afterExpiry,,) = names.records(1);
        assertEq(afterExpiry - beforeExpiry, 365 days);
        assertEq(address(custody).balance, 1 ether);
    }

    function testRejectUnexpectedNFTAndSpoofedReceiverCallback() public {
        vm.expectRevert(PSPNameCustody.UnexpectedNFT.selector);
        names.mintOther(address(custody));
        vm.expectRevert(PSPNameCustody.UnexpectedNFT.selector);
        custody.onERC721Received(admin, admin, 1, "");
    }

    function testRecoveryToNonReceiverRollsBackCustodyAndPause() public {
        vm.startPrank(admin);
        custody.setRegistrationEnabled(true);
        vm.expectRevert();
        custody.recoverParent(address(names));
        vm.stopPrank();
        assertTrue(custody.registrationEnabled());
        assertEq(names.ownerOf(1), address(custody));
    }

    function testParentResolutionCanBeManagedWhileCustodied() public {
        vm.startPrank(admin);
        custody.setParentAddress(admin);
        custody.setRegistrationEnabled(true);
        vm.stopPrank();
        assertEq(names.resolve(1), admin);
        custody.checkActive();
    }
}
