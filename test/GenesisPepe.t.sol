// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {IRoundController} from "../src/interfaces/IRoundController.sol";
import {PepeDna} from "../src/libraries/PepeDna.sol";
import {PepeDescriptor} from "../src/PepeDescriptor.sol";
import {ReviewPSP, ReviewController} from "./SkillStakingReview.t.sol";

/// @dev Raw-DNA mint exists only in this harness to exercise hash/modulo aliases.
contract GenesisArtHarness is PSPStaker {
    constructor(IERC20 token, IRoundController c) PSPStaker(token, c, address(0)) {}
    function mintDna(address to, uint256 id, uint256 dna) external { _mint(to, id, dna); }
}

/// @title GenesisPepeTest
/// @notice Block-hash art, immutable round uniqueness and bounded collision handling.
contract GenesisPepeTest is Test {
    ReviewPSP token;
    ReviewController c;
    GenesisArtHarness s;
    PepeDescriptor renderer;
    address alice = address(0xab);
    address bob = address(0xcd);

    function setUp() public {
        vm.roll(100);
        vm.setBlockhash(99, keccak256("round birth"));
        token = new ReviewPSP();
        c = new ReviewController();
        s = _newStaker();
        renderer = new PepeDescriptor();
    }

    function _newStaker() internal returns (GenesisArtHarness result) {
        result = new GenesisArtHarness(IERC20(address(token)), IRoundController(address(c)));
        token.mint(address(result), 1000e18);
        c.genesis(result, 1000e18);
    }

    function _traits(uint256 dna) internal view returns (bytes32) {
        return keccak256(abi.encode(renderer.decode(dna)));
    }

    function test_GenesisPreviewMatchesMintInsteadOfAddressPlaceholder() public {
        uint256 preview = s.genesisPepeDna(alice);
        assertTrue(preview != uint256(keccak256(abi.encode(uint256(uint160(alice))))));
        c.claim(s, alice, 100e18);
        assertEq(s.primaryOf(alice), uint256(uint160(alice)));
        assertEq(s.dnaOf(s.primaryOf(alice)), preview);
        assertEq(s.stakedTotalOf(alice), 100e18);
    }

    function testFuzz_ClaimTimingAndOrderDoNotRerollAvailableArt(uint160 a, uint160 b) public {
        a = uint160(bound(a, 1, type(uint160).max));
        b = uint160(bound(b, 1, type(uint160).max));
        vm.assume(a != b);
        address first = address(a);
        address second = address(b);
        uint256 da = s.genesisPepeDna(first);
        uint256 db = s.genesisPepeDna(second);
        vm.assume(_traits(da) != _traits(db));
        uint256 snapshot = vm.snapshotState();
        c.claim(s, first, 100e18);
        c.claim(s, second, 200e18);
        assertEq(s.dnaOf(a), da);
        assertEq(s.dnaOf(b), db);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        // The source block hash is outside the EVM's 256-block window, and
        // the claim block has different entropy. The stored seed still applies.
        vm.roll(1000);
        vm.setBlockhash(999, keccak256("later claim"));
        skip(1 days);
        assertEq(s.genesisPepeDna(first), da);
        assertEq(s.genesisPepeDna(second), db);
        c.claim(s, second, 200e18);
        c.claim(s, first, 100e18);
        assertEq(s.dnaOf(a), da);
        assertEq(s.dnaOf(b), db);
        assertEq(s.totalLocked(), 1000e18);
        assertEq(s.totalWeight(), 1000e18);
    }

    function testFuzz_BirthBlockhashChangesArtAtSameContractAddress(bytes32 entropy) public {
        uint256 snapshot = vm.snapshotState();
        vm.setBlockhash(99, entropy);
        GenesisArtHarness first = _newStaker();
        address deployedAt = address(first);
        uint256 dna = first.genesisPepeDna(alice);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.setBlockhash(99, entropy ^ bytes32(uint256(1)));
        GenesisArtHarness replay = _newStaker();
        assertEq(address(replay), deployedAt, "isolate block hash from address entropy");
        assertTrue(replay.genesisPepeDna(alice) != dna, "birth block hash must affect DNA");
    }

    function test_RoundAddressSeparatesArtEvenWithSameBirthBlockhash() public {
        GenesisArtHarness otherRound = _newStaker();
        assertTrue(otherRound.genesisPepeDna(alice) != s.genesisPepeDna(alice));
    }

    function test_BlockZeroCanStillCreateAndClaim() public {
        vm.roll(0);
        GenesisArtHarness genesisBlockRound = _newStaker();
        uint256 preview = genesisBlockRound.genesisPepeDna(alice);
        c.claim(genesisBlockRound, alice, 100e18);
        assertEq(genesisBlockRound.dnaOf(genesisBlockRound.primaryOf(alice)), preview);
    }

    function test_ChosenIdsWithDifferentHashesButSameTraitsRevert() public {
        uint256 first = 4046;
        uint256 aliasId = 5249;
        uint256 da = s.dnaOf(first);
        uint256 db = s.dnaOf(aliasId);
        assertTrue(da != db);
        assertEq(_traits(da), _traits(db));
        s.lockWithPepe(0, first);
        assertFalse(s.isPepeAvailable(aliasId));
        vm.expectRevert(PSPStaker.PepeDnaTaken.selector);
        s.lockWithPepe(0, aliasId);
        assertEq(s.balanceOf(address(this)), 1);
    }

    function test_IdSquattingCannotStealOrBlockTheGenesisPosition() public {
        uint256 preferred = uint256(uint160(alice));
        s.lockWithPepe(0, preferred);
        uint256 attackerDna = s.dnaOf(preferred);
        uint256 preview = s.genesisPepeDna(alice);
        c.claim(s, alice, 100e18);
        uint256 id = s.primaryOf(alice);
        assertEq(id, 1);
        assertEq(s.ownerOf(preferred), address(this));
        assertEq(s.dnaOf(preferred), attackerDna);
        assertEq(s.dnaOf(id), preview);
        assertTrue(_traits(s.dnaOf(id)) != _traits(attackerDna));
        assertEq(s.stakedTotalOf(address(this)), 0);
        assertEq(s.stakedTotalOf(alice), 100e18);
    }

    function test_ArtCollisionWithDifferentIdAlsoResolvesBeforeClaim() public {
        uint256 dna = s.genesisPepeDna(alice);
        s.mintDna(bob, 999, dna ^ (1 << 255)); // same rendered traits
        uint256 preview = s.genesisPepeDna(alice);
        c.claim(s, alice, 100e18);
        uint256 id = s.primaryOf(alice);
        assertEq(id, uint256(uint160(alice)));
        assertEq(s.dnaOf(id), preview);
        assertTrue(_traits(preview) != _traits(dna));
    }

    function test_ZeroDnaAndModuloAliasesStayReservedAfterTransferAndWithdrawal() public {
        s.mintDna(alice, 88, 0);
        assertEq(s.dnaOf(88), 0);
        token.mint(alice, 6e18);
        vm.startPrank(alice);
        token.approve(address(s), 6e18);
        s.stakeFor(alice, 88, 6e18);
        s.requestWithdraw(88);
        skip(6 days);
        s.withdraw(88);
        s.transferFrom(alice, bob, 88);
        vm.stopPrank();
        assertEq(s.dnaOf(88), 0);
        assertEq(s.ownerOf(88), bob);
        vm.expectRevert(PSPStaker.PepeDnaTaken.selector);
        s.mintDna(alice, 89, 0xaaaaaaaa); // all eight traits wrap to zero
        vm.expectRevert(PSPStaker.PepeDnaTaken.selector);
        s.mintDna(alice, 89, 1 << 255); // unused high bits cannot make new art
        GenesisArtHarness otherRound = _newStaker();
        otherRound.mintDna(alice, 88, 0); // uniqueness is per round
    }

    function test_CollisionLookupSkipsAnOccupiedArtRunWithinFixedGas() public {
        // Occupy the round-seeded art and wallet ID independently of chosen-ID hashing.
        uint256 reservedKey = PepeDna.key(s.genesisPepeDna(alice));
        s.mintDna(bob, uint256(uint160(alice)), s.genesisPepeDna(alice));
        for (uint256 i = 1; i <= 1024; ++i) {
            if (i != reservedKey) s.mintDna(bob, 10000 + i, PepeDna.fromKey(i));
        }
        uint256 preview = s.genesisPepeDna(alice);
        assertEq(PepeDna.key(preview), reservedKey == 1025 ? 1026 : 1025);
        vm.prank(address(c));
        (bool ok,) = address(s).call{gas: 450_000}(abi.encodeCall(s.claimGenesisShare, (alice, 100e18)));
        assertTrue(ok, "claim must not scan occupied art or NFT IDs");
        assertEq(s.dnaOf(s.primaryOf(alice)), preview);
    }

    function test_AutomaticMintResolvesTakenArt() public {
        uint256 initial = s.dnaOf(1);
        s.mintDna(bob, 99, initial);
        vm.prank(alice);
        s.lock(0);
        assertEq(s.primaryOf(alice), 1);
        assertTrue(_traits(s.dnaOf(1)) != _traits(initial));
    }

    function testFuzz_FirstFreeArtMatchesIndependentOccupiedSet(uint256 seed) public {
        bool[129] memory used;
        uint256 reservedKey = PepeDna.key(s.genesisPepeDna(alice));
        s.mintDna(bob, uint256(uint160(alice)), s.genesisPepeDna(alice));
        if (reservedKey <= 128) used[reservedKey] = true;
        for (uint256 i; i < 64; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            if (seed % 3 != 0) {
                uint256 chosen = 1 + seed % 128;
                if (used[chosen]) continue;
                s.mintDna(bob, 1000000 + i, PepeDna.fromKey(chosen));
                used[chosen] = true;
            } else {
                uint256 expected = 1;
                while (used[expected]) ++expected;
                assertEq(PepeDna.key(s.genesisPepeDna(alice)), expected);
                uint256 count = s.balanceOf(alice);
                c.claim(s, alice, 1e18);
                uint256 id = s.tokenOfOwnerByIndex(alice, count);
                assertEq(PepeDna.key(s.dnaOf(id)), expected);
                used[expected] = true;
            }
        }
    }

    function testFuzz_CanonicalIdentityMatchesProductionDecoder(uint256 dna, uint32 raw) public view {
        uint256 index = bound(raw, 1, PepeDna.COMBINATIONS);
        uint256 canonical = PepeDna.fromKey(PepeDna.key(dna));
        assertEq(_traits(canonical), _traits(dna));
        assertEq(PepeDna.key(PepeDna.fromKey(index)), index);
        uint256 other = index == PepeDna.COMBINATIONS ? 1 : index + 1;
        assertTrue(_traits(PepeDna.fromKey(index)) != _traits(PepeDna.fromKey(other)));
    }

    function testFuzz_MixedMintsKeepUniqueImmutableTraits(uint256 seed) public {
        bytes32[48] memory used;
        for (uint256 i; i < used.length; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address user = address(uint160(1 + seed % (type(uint160).max - 1)));
            uint256 count = s.balanceOf(user);
            if (i % 3 == 0) c.claim(s, user, 1e18);
            else if (i % 3 == 1) { vm.prank(user); s.lock(0); }
            else {
                uint256 candidate = 100000 + i;
                bool available = s.isPepeAvailable(candidate);
                vm.prank(user);
                if (available) s.lockWithPepe(0, candidate);
                else s.lock(0);
            }
            uint256 id = s.tokenOfOwnerByIndex(user, count);
            uint256 dna = s.dnaOf(id);
            used[i] = _traits(dna);
            for (uint256 j; j < i; ++j) assertTrue(used[i] != used[j]);
            vm.prank(user);
            s.transferFrom(user, address(this), id);
            assertEq(s.dnaOf(id), dna);
        }
    }
}
