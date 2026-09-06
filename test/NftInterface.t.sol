// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {ReviewPSP, ReviewController} from "./SkillStakingReview.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRoundController} from "../src/interfaces/IRoundController.sol";

/// @dev Observes the position during its callback and probes guarded entry points.
contract PositionReceiver is IERC721Receiver, Test {
    PSPStaker immutable staking;
    address public operator;
    address public from;
    bytes public data;
    uint256 public received;
    uint8 public behavior;
    error Rejected(uint256 id);
    constructor(PSPStaker s) { staking = s; }
    function configure(uint8 b) external { behavior = b; }
    function onERC721Received(address op, address sender, uint256 id, bytes calldata payload) external returns (bytes4) {
        require(msg.sender == address(staking));
        if (behavior == 1) return bytes4(0);
        if (behavior == 2) revert Rejected(id);
        if (behavior == 3) { assembly { revert(0, 0) } }
        assertEq(staking.ownerOf(id), address(this));
        assertEq(staking.getApproved(id), address(0));
        assertEq(staking.tokenOfOwnerByIndex(address(this), 0), id);
        (uint256 principal,,,,) = staking.positions(id);
        assertEq(staking.stakedTotalOf(address(this)), principal);
        if (behavior == 4) {
            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            staking.transferFrom(address(this), sender, id);
            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            staking.claimFees(id);
            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            staking.requestWithdraw(id);
            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            staking.withdraw(id);
        }
        operator = op; from = sender; data = payload; received = id;
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @title NftInterfaceTest
/// @notice ERC-721 permissions, callback atomicity and position conservation.
contract NftInterfaceTest is Test {
    ReviewPSP token;
    PSPStaker staking;
    PositionReceiver receiver;
    address alice = makeAddr("nft-alice");
    address bob = makeAddr("nft-bob");
    address operator = makeAddr("nft-operator");
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    function setUp() public {
        token = new ReviewPSP();
        staking = new PSPStaker(IERC20(address(token)), IRoundController(address(new ReviewController())), address(0));
        receiver = new PositionReceiver(staking);
        token.mint(alice, 600e18);
        vm.startPrank(alice);
        token.approve(address(staking), type(uint256).max);
        staking.lockWithPepe(600e18, 1);
        staking.lockWithPepe(0, 2);
        vm.stopPrank();
    }

    function test_InterfaceAndMissingTokenValidation() public {
        assertTrue(staking.supportsInterface(0x80ac58cd));
        assertTrue(staking.supportsInterface(0x01ffc9a7));
        assertTrue(staking.supportsInterface(0x5b5e139f));
        assertFalse(staking.supportsInterface(0xffffffff));
        assertFalse(staking.supportsInterface(0x780e9d63)); // partial enumeration is not IERC721Enumerable
        vm.expectRevert(PSPStaker.ZeroAddress.selector); staking.balanceOf(address(0));
        vm.expectRevert(PSPStaker.NotNftOwner.selector); staking.getApproved(0);
        vm.expectRevert(PSPStaker.NotNftOwner.selector); staking.approve(operator, 999);
        vm.expectRevert(PSPStaker.NotNftOwner.selector); staking.tokenURI(999);
        assertEq(staking.tokenURI(1), ""); // deliberately art-free fixture
    }

    function test_IndividualApprovalCannotEscalateOrAffectAnotherPepe() public {
        vm.prank(bob); vm.expectRevert(PSPStaker.NotAuthorizedNft.selector); staking.approve(operator, 1);
        vm.expectEmit(true, true, true, true); emit Approval(alice, operator, 1);
        vm.prank(alice); staking.approve(operator, 1);
        assertEq(staking.getApproved(1), operator);
        vm.startPrank(operator);
        vm.expectRevert(PSPStaker.NotAuthorizedNft.selector); staking.approve(bob, 1);
        vm.expectRevert(PSPStaker.NotAuthorizedNft.selector); staking.transferFrom(alice, bob, 2);
        vm.expectRevert(PSPStaker.NotNftOwner.selector); staking.requestWithdraw(1);
        staking.safeTransferFrom(alice, bob, 1);
        vm.stopPrank();
        assertEq(staking.getApproved(1), address(0));
        vm.prank(operator); vm.expectRevert(PSPStaker.NotAuthorizedNft.selector); staking.transferFrom(bob, operator, 1);
        assertEq(staking.ownerOf(2), alice);
    }

    function test_ReplacementRevocationAndCollectionDelegation() public {
        vm.startPrank(alice);
        staking.setApprovalForAll(operator, true);
        vm.stopPrank();
        vm.prank(operator); staking.approve(bob, 1);
        vm.startPrank(alice);
        staking.approve(address(0), 1);
        staking.setApprovalForAll(operator, false);
        vm.stopPrank();
        vm.prank(bob); vm.expectRevert(PSPStaker.NotAuthorizedNft.selector); staking.transferFrom(alice, bob, 1);
        vm.prank(operator); vm.expectRevert(PSPStaker.NotAuthorizedNft.selector); staking.transferFrom(alice, bob, 1);
        vm.startPrank(alice);
        staking.approve(operator, 1);
        staking.approve(bob, 1);
        vm.stopPrank();
        vm.prank(operator); vm.expectRevert(PSPStaker.NotAuthorizedNft.selector); staking.transferFrom(alice, bob, 1);
        vm.prank(bob); staking.transferFrom(alice, bob, 1);
    }

    function test_SafeReceiverSeesCompleteStateAndGetsExactPayload() public {
        receiver.configure(4);
        vm.startPrank(alice);
        staking.requestWithdraw(1);
        staking.approve(operator, 1);
        vm.stopPrank();
        uint256 end = staking.withdrawableAt(1);
        vm.prank(operator); staking.safeTransferFrom(alice, address(receiver), 1, hex"1234567890");
        assertEq(receiver.operator(), operator);
        assertEq(receiver.from(), alice);
        assertEq(receiver.data(), hex"1234567890");
        assertEq(receiver.received(), 1);
        assertTrue(staking.isWithdrawing(1));
        assertEq(staking.withdrawableAt(1), end);
        assertEq(staking.stakedTotalOf(alice), 0);
        assertEq(staking.totalLocked(), 600e18);
        skip(6 days);
        vm.prank(address(receiver)); staking.withdraw(1);
        assertEq(token.balanceOf(address(receiver)), 600e18);
        assertEq(staking.ownerOf(1), address(receiver)); // husk survives
    }

    function test_ThreeArgumentOverloadUsesEmptyData() public {
        vm.prank(alice); staking.safeTransferFrom(alice, address(receiver), 2);
        assertEq(receiver.data().length, 0);
        assertEq(receiver.operator(), alice);
    }

    function test_ReceiverRejectionRollsBackApprovalEnumerationAndPrincipal() public {
        vm.prank(alice); staking.approve(operator, 1);
        for (uint8 b = 1; b <= 3; ++b) {
            receiver.configure(b);
            bytes memory expected = b == 2 ? abi.encodeWithSelector(PositionReceiver.Rejected.selector, 1)
                : abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver));
            vm.prank(operator); vm.expectRevert(expected);
            staking.safeTransferFrom(alice, address(receiver), 1, "payload");
            assertEq(staking.ownerOf(1), alice);
            assertEq(staking.getApproved(1), operator);
            assertEq(staking.balanceOf(alice), 2);
            assertEq(staking.tokenOfOwnerByIndex(alice, 0), 1);
            assertEq(staking.stakedTotalOf(alice), 600e18);
            assertEq(staking.stakedTotalOf(address(receiver)), 0);
            assertEq(staking.balanceOf(address(receiver)), 0);
        }
    }

    function test_UnsafeRecipientsAndIncorrectSenderRejected() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(token)));
        staking.safeTransferFrom(alice, address(token), 1);
        vm.expectRevert(PSPStaker.BadNftTransfer.selector); staking.safeTransferFrom(alice, address(0), 1);
        vm.expectRevert(PSPStaker.BadNftTransfer.selector); staking.safeTransferFrom(alice, address(staking), 1);
        vm.expectRevert(PSPStaker.NotNftOwner.selector); staking.safeTransferFrom(bob, alice, 1);
        // Plain transfer remains available to contracts without receiver support.
        staking.transferFrom(alice, address(token), 1);
        vm.stopPrank();
        assertEq(staking.ownerOf(1), address(token));
    }

    function testFuzz_ApprovalClearsAcrossTransferSequence(uint256 seed) public {
        address[3] memory holders = [alice, bob, makeAddr("third-holder")];
        address[2] memory owners = [alice, alice];
        for (uint256 i; i < 32; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 index = seed % 2;
            uint256 id = index + 1;
            address from = owners[index];
            address to = holders[(seed >> 8) % 3];
            vm.prank(from); staking.approve(operator, id);
            vm.prank(operator);
            if (seed & 4 != 0) staking.safeTransferFrom(from, to, id);
            else staking.transferFrom(from, to, id);
            owners[index] = to;
            assertEq(staking.getApproved(id), address(0), "including self transfers");
            for (uint256 j; j < 3; ++j) {
                uint256 count = (owners[0] == holders[j] ? 1 : 0) + (owners[1] == holders[j] ? 1 : 0);
                assertEq(staking.balanceOf(holders[j]), count);
                assertEq(staking.stakedTotalOf(holders[j]), owners[0] == holders[j] ? 600e18 : 0);
                for (uint256 k; k < count; ++k) {
                    uint256 owned = staking.tokenOfOwnerByIndex(holders[j], k);
                    assertEq(owners[owned - 1], holders[j]);
                    if (k != 0) assertTrue(owned != staking.tokenOfOwnerByIndex(holders[j], 0));
                }
            }
        }
    }
}
