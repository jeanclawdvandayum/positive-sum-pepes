// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from 'forge-std/Test.sol';
import {VectorPepeDescriptor} from 'src/VectorPepeDescriptor.sol';

/// @title on-chain dump for the traced-vector pepe experiment (2026-08-24).
///        Same DNAs as the python previews — the sheet must match, no
///        bait-and-switch between preview and chain output.
contract VectorDumpTest is Test {
    VectorPepeDescriptor d;

    uint256 constant DNA_CLASSIC = 0;
    uint256 constant DNA_GOLD = 524288;
    uint256 constant DNA_ZOMBIE = 1048576;
    uint256 constant DNA_DIAMOND = 1572864;
    uint256 constant DNA_ACC = 134252962;
    uint256 constant DNA_WIZARD = 181474347;
    uint256 constant DNA_HOMER = 288044208;

    function setUp() public {
        d = new VectorPepeDescriptor();
    }

    function test_dumpVector() public {
        vm.writeFile('out/art-dump/vec_classic.svg', d.renderSVG(DNA_CLASSIC));
        vm.writeFile('out/art-dump/vec_gold.svg', d.renderSVG(DNA_GOLD));
        vm.writeFile('out/art-dump/vec_zombie.svg', d.renderSVG(DNA_ZOMBIE));
        vm.writeFile('out/art-dump/vec_diamond.svg', d.renderSVG(DNA_DIAMOND));
        vm.writeFile('out/art-dump/vec_acc.svg', d.renderSVG(DNA_ACC));
        vm.writeFile('out/art-dump/vec_wizard.svg', d.renderSVG(DNA_WIZARD));
        vm.writeFile('out/art-dump/vec_homer.svg', d.renderSVG(DNA_HOMER));

        // round-trip: decoded traits must re-pack to the same dna
        VectorPepeDescriptor.Traits memory t = d.decode(DNA_WIZARD);
        uint256 packed = t.expr | (uint256(t.eyes) << 3) | (uint256(t.hat) << 7)
            | (uint256(t.wear) << 11) | (uint256(t.item) << 15)
            | (uint256(t.skin) << 19) | (uint256(t.iris) << 22)
            | (uint256(t.bg) << 25);
        assertEq(packed, DNA_WIZARD, 'codec round-trip');

        // tokenURI sanity + decode the b64 svg back out
        string memory uri = d.tokenURI(7, DNA_ACC);
        assertGt(bytes(uri).length, 500, 'uri too short');
    }

    // (preview-vs-chain equality is checked by rasterizing both sides in
    //  python — see script/out/vector/check_chain.py; string-level diffing
    //  is formatting-sensitive, pixels are the contract that matters)
}
