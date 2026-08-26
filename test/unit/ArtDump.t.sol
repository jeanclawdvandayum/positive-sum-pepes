// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PepeDescriptor} from "src/PepeDescriptor.sol";
import {PepeArtData} from "src/PepeArtData.sol";

/// @title ArtDump — writes the REAL renderer output to out/art-dump/
///         for eyeball previews + regression diffs (v5, DNA-driven).
///         Axes are 10 across the board (studio pass v3, 2026-08-27).
contract ArtDump is Test {
    PepeDescriptor d;

    function setUp() public {
        d = new PepeDescriptor();
        vm.createDir("out/art-dump", true);
    }

    function _dna(
        uint8 expr,
        uint8 eyes,
        uint8 hat,
        uint8 wear,
        uint8 item,
        uint8 skin,
        uint8 iris,
        uint8 bg
    ) internal view returns (uint256) {
        return d.pack(
            PepeDescriptor.Traits(expr, eyes, hat, wear, item, skin, iris, bg)
        );
    }

    function _dump(string memory prefix, uint8 axis, uint8 count) internal {
        for (uint8 i; i < count; ++i) {
            uint256 dna = axis == 0
                ? _dna(i, 0, 0, 0, 0, 0, 0, 0)
                : axis == 1
                ? _dna(0, i, 0, 0, 0, 0, 0, 0)
                : axis == 2
                ? _dna(0, 0, i, 0, 0, 0, 0, 0)
                : axis == 3
                ? _dna(0, 0, 0, i, 0, 0, 0, 0)
                : axis == 4
                ? _dna(0, 0, 0, 0, i, 0, 0, 0)
                : axis == 5
                ? _dna(0, 0, 0, 0, 0, i, 0, 0)
                : axis == 6
                ? _dna(0, 0, 0, 0, 0, 0, i, 0)
                : _dna(0, 0, 0, 0, 0, 0, 0, i);
            vm.writeFile(
                string.concat(
                    "out/art-dump/",
                    prefix,
                    "_",
                    vm.toString(i),
                    ".svg"
                ),
                d.renderSVG(dna)
            );
        }
    }

    function test_DumpTraits() public {
        _dump("expr", 0, PepeArtData.EXPR_COUNT);   // 10
        _dump("eye", 1, PepeArtData.EYE_COUNT);      // 10
        _dump("hat", 2, PepeArtData.HAT_COUNT);      // 10
        _dump("wear", 3, PepeArtData.WEAR_COUNT);    // 10
        _dump("item", 4, PepeArtData.ITEM_COUNT);    // 10
        _dump("skin", 5, PepeArtData.SKIN_COUNT);    // 10
        _dump("iris", 6, PepeArtData.IRIS_COUNT);    // 10
        _dump("bg", 7, PepeArtData.BG_COUNT);        // 10

        // studio pass v3 highlights: the new traits on full pepes
        uint256[16] memory hl = [
            _dna(8, 0, 0, 0, 0, 0, 0, 0),        // CRINGE (gritted teeth)
            _dna(9, 0, 0, 0, 0, 0, 0, 0),        // MEH
            _dna(0, 9, 0, 0, 0, 0, 0, 0),        // CROSSEYED
            _dna(1, 0, 9, 0, 0, 0, 0, 0),        // HOODIE + smile
            _dna(0, 0, 0, 7, 0, 0, 0, 0),        // 3D GLASSES
            _dna(0, 0, 0, 8, 0, 0, 0, 0),        // CYBERSHADES
            _dna(0, 0, 0, 9, 0, 0, 0, 0),        // COOLSHADES
            _dna(3, 0, 0, 0, 6, 0, 0, 0),        // CIGAR + laugh
            _dna(0, 0, 0, 0, 7, 0, 0, 0),        // BONG
            _dna(0, 0, 0, 0, 8, 0, 0, 0),        // LOLLIPOP
            _dna(0, 0, 0, 0, 9, 0, 0, 0),        // JARHEAD
            _dna(0, 0, 0, 0, 0, 8, 0, 0),        // TOAD skin
            _dna(0, 0, 0, 0, 0, 9, 0, 0),        // SICK skin
            _dna(0, 0, 0, 0, 0, 5, 7, 0),        // LIME + magenta iris
            _dna(0, 0, 0, 0, 0, 0, 8, 0),        // NEON GREEN iris
            _dna(6, 4, 6, 3, 6, 1, 4, 7)         // kitchen sink
        ];
        for (uint8 i; i < 16; ++i) {
            vm.writeFile(
                string.concat("out/art-dump/hl_", vm.toString(i), ".svg"),
                d.renderSVG(hl[i])
            );
        }

        // 16 random full-DNA pepes, deterministic seed
        uint256 seed = 0x505;
        for (uint8 i; i < 16; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 dna = seed % PepeArtData.COMBOS;
            vm.writeFile(
                string.concat(
                    "out/art-dump/random_",
                    vm.toString(i),
                    ".svg"
                ),
                d.renderSVG(dna)
            );
            vm.writeFile(
                string.concat(
                    "out/art-dump/random_",
                    vm.toString(i),
                    ".json"
                ),
                d.tokenURI(dna)
            );
        }
        emit log_string("dumped 80 axis SVGs + 16 highlights + 16 random pepes to out/art-dump/");
    }
}
