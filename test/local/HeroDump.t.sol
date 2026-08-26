// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PepeDescriptor} from "src/PepeDescriptor.sol";
contract HeroDump is Test {
    function test_Hero() public {
        PepeDescriptor d = new PepeDescriptor();
        vm.createDir("out/art-dump", true);
        // grin + cap + cigarette + amber + sunset
        uint256 dna = 2 | (0 << 3) | (1 << 6) | (0 << 10) | (1 << 14) | (0 << 18) | (2 << 21) | (4 << 24);
        vm.writeFile("out/art-dump/hero.svg", d.renderSVG(dna));
        // smoker neutral closeup (expression 0, everything else same)
        uint256 dna2 = 0 | (0 << 3) | (1 << 6) | (0 << 10) | (1 << 14) | (0 << 18) | (0 << 21) | (0 << 24);
        vm.writeFile("out/art-dump/hero2.svg", d.renderSVG(dna2));
        emit log_string("heroes written");
    }
}
