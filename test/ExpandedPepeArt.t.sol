// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PepeExpandedDescriptor} from "../src/PepeExpandedDescriptor.sol";
import {PepeDescriptor} from "../src/PepeDescriptor.sol";
import {PepeDna} from "../src/libraries/PepeDna.sol";
import {ExpandedPepeArt} from "../src/art/ExpandedPepeArt.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRoundController} from "../src/interfaces/IRoundController.sol";

contract UnsupportedDescriptor {
    function ART_VERSION() external pure returns (uint256) { return 3; }
}

/// @title ExpandedPepeArtTest
/// @notice Immutable art version, canonical collision protection and storage integrity.
contract ExpandedPepeArtTest is Test {
    PepeExpandedDescriptor expanded;
    address constant CONTROLLER = address(0x123);

    function setUp() public {
        expanded = new PepeExpandedDescriptor();
        vm.mockCall(CONTROLLER, abi.encodeWithSignature("flatTime()"), abi.encode(uint256(0)));
        vm.mockCall(CONTROLLER, abi.encodeWithSignature("hookAddress()"), abi.encode(address(0)));
    }

    function test_RenderMatchesClientFixtures() public {
        string memory fixture = vm.readFile("script/expanded-art-fixtures.json");
        uint256[] memory dna = vm.parseJsonUintArray(fixture, ".dna");
        bytes32[] memory expected = abi.decode(vm.parseJson(fixture, ".expanded"), (bytes32[]));
        bytes32[] memory legacyExpected = abi.decode(vm.parseJson(fixture, ".legacy"), (bytes32[]));
        PepeDescriptor legacy = new PepeDescriptor();
        for (uint256 i; i < dna.length; ++i) {
            assertEq(keccak256(bytes(expanded.renderSVG(dna[i]))), expected[i]);
            assertEq(keccak256(bytes(legacy.renderSVG(dna[i]))), legacyExpected[i]);
        }
    }

    function test_StorageContainsExactReleaseBytesAndFits() public view {
        bytes memory code = expanded.artData().code;
        assertEq(code, bytes.concat(hex"00", ExpandedPepeArt.DATA));
        assertLt(code.length, 24576);
        assertLt(address(expanded).code.length, 24576);
        assertEq(expanded.ART_VERSION(), 2);
        assertEq(PepeDna.combinations(2), 191664000);
        assertEq(expanded.exprName(10), "Amazing");
        assertEq(expanded.exprName(11), "Rage");
        assertEq(expanded.eyeName(10), "Sus");
        assertEq(expanded.hatName(10), "Fuck My Shit Up");
        assertEq(expanded.wearName(10), "Reading Glasses");
        assertEq(expanded.wearName(11), "Unibrow");
        assertEq(expanded.itemName(10), "Knife");
    }

    function testFuzz_CodecRoundTripAndRendererAgree(uint256 dna, uint32 index) public view {
        uint256 key = PepeDna.key(dna, 2);
        assertGt(key, 0);
        assertLe(key, 191664000);
        assertEq(abi.encode(expanded.decode(dna)), abi.encode(expanded.decode(PepeDna.fromKey(key, 2))));
        uint256 bounded = bound(index, 1, 191664000);
        assertEq(PepeDna.key(PepeDna.fromKey(bounded, 2), 2), bounded);
        // Legacy callers retain their original codec and aliases.
        assertEq(PepeDna.key(dna), PepeDna.key(dna, 1));
        assertEq(PepeDna.fromKey(PepeDna.key(dna)), PepeDna.fromKey(PepeDna.key(dna, 1), 1));
    }

    function test_VersionFrozenPerStakerAndUnknownVersionRejected() public {
        PepeDescriptor old = new PepeDescriptor();
        PSPStaker legacy = new PSPStaker(IERC20(address(1)), IRoundController(CONTROLLER), address(old));
        PSPStaker next = new PSPStaker(IERC20(address(1)), IRoundController(CONTROLLER), address(expanded));
        assertEq(legacy.PEPE_DNA_VERSION(), 1);
        assertEq(next.PEPE_DNA_VERSION(), 2);
        UnsupportedDescriptor unknown = new UnsupportedDescriptor();
        vm.expectRevert(PSPStaker.UnsupportedArtVersion.selector);
        new PSPStaker(IERC20(address(1)), IRoundController(CONTROLLER), address(unknown));
    }

    function test_ReservationAndMintShareExpandedCollisionSpaceForever() public {
        PSPStaker staker = new PSPStaker(IERC20(address(1)), IRoundController(CONTROLLER), address(expanded));
        // Independently searched keccak(id) collision under expanded trait counts.
        uint256 first = 14367;
        uint256 aliasId = 16450;
        assertEq(PepeDna.key(uint256(keccak256(abi.encode(first))), 2), PepeDna.key(uint256(keccak256(abi.encode(aliasId))), 2));
        vm.prank(CONTROLLER);
        staker.reserveGenesisPepe(address(this), first);
        assertFalse(staker.isPepeAvailable(first));
        assertFalse(staker.isPepeAvailable(aliasId));
        vm.expectRevert(PSPStaker.PepeDnaTaken.selector);
        staker.lockWithPepe(0, aliasId);
        vm.mockCall(CONTROLLER, abi.encodeWithSignature("VEST_DURATION()"), abi.encode(uint256(6 days)));
        vm.prank(CONTROLLER);
        staker.lockGenesis(1e18);
        vm.mockCall(CONTROLLER, abi.encodeWithSignature("flatTime()"), abi.encode(uint256(1)));
        vm.prank(CONTROLLER);
        staker.claimGenesisShareWithPepe(address(this), 1e18, first);
        assertEq(staker.dnaOf(first), uint256(keccak256(abi.encode(first))));
        assertEq(staker.reservedPepeOwner(first), address(0));
        assertEq(staker.tokenURI(first), expanded.tokenURI(staker.dnaOf(first)));
        staker.transferFrom(address(this), address(0xbeef), first);
        assertFalse(staker.isPepeAvailable(aliasId));
        assertEq(staker.ownerOf(first), address(0xbeef));
    }

    function test_LegacyAliasCanBeDistinctExpandedArt() public {
        PSPStaker staker = new PSPStaker(IERC20(address(1)), IRoundController(CONTROLLER), address(expanded));
        staker.lockWithPepe(0, 4046);
        assertTrue(staker.isPepeAvailable(5249));
        staker.lockWithPepe(0, 5249);
        assertEq(staker.balanceOf(address(this)), 2);
    }
}
