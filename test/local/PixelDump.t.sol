// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from 'forge-std/Test.sol';
import {PepeDescriptor} from 'src/PepeDescriptor.sol';

/// @title current pixel-pipeline chain dumps (same DNAs as the vector /
///        8-bit dumps) for the art-direction comparison sheet.
contract PixelDumpTest is Test {
    PepeDescriptor d;

    uint256 constant DNA_CLASSIC = 0;
    uint256 constant DNA_GOLD = 524288;
    uint256 constant DNA_ZOMBIE = 1048576;
    uint256 constant DNA_DIAMOND = 1572864;
    uint256 constant DNA_ACC = 134252962;
    uint256 constant DNA_WIZARD = 181474347;
    uint256 constant DNA_HOMER = 288044208;

    function setUp() public {
        d = new PepeDescriptor();
    }

    function test_dumpPixel() public {
        vm.writeFile('out/art-dump/pix_classic.svg', d.renderSVG(DNA_CLASSIC));
        vm.writeFile('out/art-dump/pix_gold.svg', d.renderSVG(DNA_GOLD));
        vm.writeFile('out/art-dump/pix_zombie.svg', d.renderSVG(DNA_ZOMBIE));
        vm.writeFile('out/art-dump/pix_diamond.svg', d.renderSVG(DNA_DIAMOND));
        vm.writeFile('out/art-dump/pix_acc.svg', d.renderSVG(DNA_ACC));
        vm.writeFile('out/art-dump/pix_wizard.svg', d.renderSVG(DNA_WIZARD));
        vm.writeFile('out/art-dump/pix_homer.svg', d.renderSVG(DNA_HOMER));
    }
}
