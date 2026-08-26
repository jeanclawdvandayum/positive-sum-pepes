// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from 'forge-std/Test.sol';
import {PepeDescriptor8Bit} from 'src/PepeDescriptor8Bit.sol';

/// @title side-by-side dumps: current pixel vs 8-bit apple snap (both chain
///        output). DNAs mirror the python preview samples.
contract CompareDumpTest is Test {
    PepeDescriptor8Bit d8;

    uint256 constant DNA_CLASSIC = 0;
    uint256 constant DNA_GOLD = 524288;
    uint256 constant DNA_ZOMBIE = 1048576;
    uint256 constant DNA_DIAMOND = 1572864;
    uint256 constant DNA_ACC = 134252962;
    uint256 constant DNA_WIZARD = 181474347;
    uint256 constant DNA_HOMER = 288044208;

    function setUp() public {
        d8 = new PepeDescriptor8Bit();
    }

    function test_dump8bit() public {
        vm.writeFile('out/art-dump/8bit_classic.svg', d8.renderSVG(DNA_CLASSIC));
        vm.writeFile('out/art-dump/8bit_gold.svg', d8.renderSVG(DNA_GOLD));
        vm.writeFile('out/art-dump/8bit_zombie.svg', d8.renderSVG(DNA_ZOMBIE));
        vm.writeFile('out/art-dump/8bit_diamond.svg', d8.renderSVG(DNA_DIAMOND));
        vm.writeFile('out/art-dump/8bit_acc.svg', d8.renderSVG(DNA_ACC));
        vm.writeFile('out/art-dump/8bit_wizard.svg', d8.renderSVG(DNA_WIZARD));
        vm.writeFile('out/art-dump/8bit_homer.svg', d8.renderSVG(DNA_HOMER));
        // spot-check tokenURI decodes
        string memory uri = d8.tokenURI(DNA_ACC);
        assertGt(bytes(uri).length, 200, 'uri too short');
    }
}
