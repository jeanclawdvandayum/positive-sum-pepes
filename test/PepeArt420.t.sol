// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PepeDescriptor420} from "../src/PepeDescriptor420.sol";
import {PepeExpandedDescriptor} from "../src/PepeExpandedDescriptor.sol";
import {PepeDna} from "../src/libraries/PepeDna.sol";
import {PepeArt420} from "../src/art/PepeArt420.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRoundController} from "../src/interfaces/IRoundController.sol";

/// @title PepeArt420Test
/// @notice Release 3 (420 edition): storage integrity, extended names,
/// version wiring and the version-3 collision space.
contract PepeArt420Test is Test {
    PepeDescriptor420 edition;
    address constant CONTROLLER = address(0x123);

    function setUp() public {
        edition = new PepeDescriptor420();
        vm.mockCall(CONTROLLER, abi.encodeWithSignature("flatTime()"), abi.encode(uint256(0)));
        vm.mockCall(CONTROLLER, abi.encodeWithSignature("hookAddress()"), abi.encode(address(0)));
    }

    function test_RenderMatchesClientFixtures() public {
        string memory fixture = vm.readFile("script/expanded-art-fixtures.json");
        uint256[] memory dna = vm.parseJsonUintArray(fixture, ".dna");
        bytes32[] memory expected = abi.decode(vm.parseJson(fixture, ".pepe420"), (bytes32[]));
        for (uint256 i; i < dna.length; ++i) {
            assertEq(keccak256(bytes(edition.renderSVG(dna[i]))), expected[i]);
        }
    }

    function test_StorageContainsExactReleaseBytesAndFits() public view {
        bytes memory code = edition.artData().code;
        assertEq(code, bytes.concat(hex"00", PepeArt420.DATA));
        assertLt(code.length, 24576);
        assertLt(address(edition).code.length, 24576);
        assertEq(edition.ART_VERSION(), 3);
        assertEq(PepeDna.combinations(3), 529056528);
        // 420 traits keep the descriptor name style: human-readable, JSON safe.
        assertEq(edition.exprName(12), "Munchies");
        assertEq(edition.exprName(13), "Cottonmouth");
        assertEq(edition.hatName(11), "Rasta Tam");
        assertEq(edition.hatName(12), "Bucket Hat");
        assertEq(edition.itemName(1), "Joint");
        assertEq(edition.itemName(6), "Blunt");
        assertEq(edition.itemName(11), "Weed Vape");
        assertEq(edition.itemName(12), "Leaf Chain");
        assertEq(edition.itemName(13), "Smoke Rings");
        assertEq(edition.skinName(10), "Purp");
        assertEq(edition.irisName(10), "Redeye");
        assertEq(edition.bgName(10), "Haze");
        assertEq(edition.bgName(11), "Purple Haze");
        assertEq(edition.bgName(12), "Kush");
    }

    function testFuzz_CodecRoundTripAndRendererAgree(uint256 dna, uint32 index) public view {
        uint256 key = PepeDna.key(dna, 3);
        assertGt(key, 0);
        assertLe(key, 529056528);
        assertEq(abi.encode(edition.decode(dna)), abi.encode(edition.decode(PepeDna.fromKey(key, 3))));
        uint256 bounded = bound(index, 1, 529056528);
        assertEq(PepeDna.key(PepeDna.fromKey(bounded, 3), 3), bounded);
        // Older releases keep their own codec and collision spaces.
        assertEq(PepeDna.key(dna), PepeDna.key(dna, 1));
    }

    function test_StakerFreezesReleaseThree() public {
        PSPStaker staker = new PSPStaker(IERC20(address(1)), IRoundController(CONTROLLER), address(edition));
        assertEq(staker.PEPE_DNA_VERSION(), 3);
        // Release 2 stays deployable side by side; rounds never share a codec.
        PepeExpandedDescriptor expanded = new PepeExpandedDescriptor();
        PSPStaker roundTwo = new PSPStaker(IERC20(address(1)), IRoundController(CONTROLLER), address(expanded));
        assertEq(roundTwo.PEPE_DNA_VERSION(), 2);
    }

    function test_ReservationAndMintShare420CollisionSpaceForever() public {
        PSPStaker staker = new PSPStaker(IERC20(address(1)), IRoundController(CONTROLLER), address(edition));
        // Independently searched keccak(id) collision under the 420 trait counts.
        uint256 first = 10806;
        uint256 aliasId = 17205;
        assertEq(PepeDna.key(uint256(keccak256(abi.encode(first))), 3), PepeDna.key(uint256(keccak256(abi.encode(aliasId))), 3));
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
        assertEq(staker.tokenURI(first), edition.tokenURI(staker.dnaOf(first)));
        staker.transferFrom(address(this), address(0xbeef), first);
        assertFalse(staker.isPepeAvailable(aliasId));
        assertEq(staker.ownerOf(first), address(0xbeef));
    }
}
