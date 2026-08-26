// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PSPToken} from "../../src/PSPToken.sol";
import {RoundController} from "../../src/RoundController.sol";
import {PSPStaker} from "../../src/PSPStaker.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";
import {StakerDeployer} from "src/StakerDeployer.sol";


/// @dev tiny descriptor stub — proves tokenURI is fed dnaOf[tokenId].
contract StubDescriptor {
    function tokenURI(uint256 dna) external pure returns (string memory) {
        uint8 last = uint8(dna);
        bytes memory hexs = "0123456789abcdef";
        return string(abi.encodePacked("pepe:P", hexs[last >> 4], hexs[last & 15]));
    }
}

/// @dev stands in for PSPFactory (Ownable2Step): controller.owner() == this.
contract MockFactory {
    address public owner;
    constructor() { owner = msg.sender; }
}

/// @title PepeStakerTest — pepe-first onboarding + husk persistence
/// @notice 2026-08-22 semantics:
///          - lock(0) mints the participation NFT (pepe-first path)
///          - unlock() keeps the NFT as a husk (proof of participation)
///          - re-locking revives the husk; a husk can receive a live position
contract PepeStakerTest is Test {
    RoundController controller;
    PSPStaker stakerV;
    MockMixETH mixETH;
    PSPToken pspToken;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    MockFactory mockFactory; // controller.owner() — exposes owner() like PSPFactory
    StubDescriptor stub; // the art renderer wired at construction

    function setUp() public {
        mixETH = new MockMixETH();
        mixETH.depositETH{value: 1000e18}();
        mockFactory = new MockFactory();
        stub = new StubDescriptor();
        CurveMath.CurveConfig memory params =
            CurveMath.singleCurve(0.0001e18, 100_000_000e18, 0.000000046e18, 0.1e18);
        pspToken = new PSPToken("Positive Sum Pepes", "PSP", address(this));
        controller =
            new RoundController(pspToken, IERC20(address(mixETH)), params, address(mockFactory), address(stub), new StakerDeployer());
        stakerV = controller.staker();
        pspToken.setController(address(controller));

        vm.startPrank(address(controller));
        pspToken.mint(alice, 10_000e18);
        pspToken.mint(bob, 10_000e18);
        vm.stopPrank();

        vm.prank(alice);
        pspToken.approve(address(stakerV), type(uint256).max);
        vm.prank(bob);
        pspToken.approve(address(stakerV), type(uint256).max);

        mixETH.transfer(address(controller), 1000e18);
    }

    // ─────────────────────────────────────────────────────────────
    // lock(0): the pepe-first path
    // ─────────────────────────────────────────────────────────────

    function test_PepeOnlyMint() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit PSPStaker.Transfer(address(0), alice, 1);
        stakerV.lock(0);

        uint256 id = stakerV.tokenOf(alice);
        assertEq(id, 1, "first token id");
        assertEq(stakerV.ownerOf(id), alice);
        assertEq(stakerV.lockedPSPOf(alice), 0, "no stake");
        assertEq(stakerV.totalLocked(), 0);
        (, , uint256 __pos1, ) = stakerV.positions(alice);
        assertEq(__pos1, 0, "no clock");

        // deterministic DNA: keccak256(tokenId)
        assertEq(stakerV.dnaOf(id), uint256(keccak256(abi.encodePacked(id))), "dna");

        // idempotent — no second NFT, no Transfer
        vm.prank(alice);
        stakerV.lock(0);
        assertEq(stakerV.tokenOf(alice), id, "still one NFT");
        assertEq(pspToken.balanceOf(alice), 10_000e18, "no PSP moved");
    }

    function test_PepeFirstThenStake() public {
        vm.prank(alice);
        stakerV.lock(0);
        uint256 id = stakerV.tokenOf(alice);

        // staking later rides the SAME NFT — no remint
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit PSPStaker.Locked(alice, 1_000e18);
        stakerV.lock(1_000e18);

        assertEq(stakerV.tokenOf(alice), id, "same NFT");
        assertEq(stakerV.lockedPSPOf(alice), 1_000e18);
        assertEq(pspToken.balanceOf(address(stakerV)), 1_000e18, "custody at staker");
    }

    // ─────────────────────────────────────────────────────────────
    // unlock(): the husk survives (proof of participation)
    // ─────────────────────────────────────────────────────────────

    function test_UnlockKeepsNftAsHusk() public {
        vm.prank(alice);
        stakerV.lock(1_000e18);
        uint256 id = stakerV.tokenOf(alice);
        uint256 dna = stakerV.dnaOf(id);

        vm.warp(block.timestamp + 91 days);
        vm.prank(alice);
        stakerV.unlock();

        // principal returned, position gone
        assertEq(pspToken.balanceOf(alice), 10_000e18, "PSP back");
        assertEq(stakerV.lockedPSPOf(alice), 0, "no position");
        assertEq(stakerV.totalLocked(), 0);

        // THE NFT SURVIVES — pepe stays with its owner forever
        assertEq(stakerV.ownerOf(id), alice, "husk owned by alice");
        assertEq(stakerV.tokenOf(alice), id, "husk still hers");
        assertEq(stakerV.dnaOf(id), dna, "art unchanged");
        assertEq(stakerV.balanceOf(alice), 1, "ERC-721 balance");
    }

    function test_RestakeRevivesHusk() public {
        vm.prank(alice);
        stakerV.lock(1_000e18);
        uint256 id = stakerV.tokenOf(alice);

        vm.warp(block.timestamp + 91 days);
        vm.prank(alice);
        stakerV.unlock();

        // re-lock: the husk revives — same NFT, no remint
        vm.prank(alice);
        stakerV.lock(500e18);
        assertEq(stakerV.tokenOf(alice), id, "revived husk, same id");
        assertEq(stakerV.lockedPSPOf(alice), 500e18);
    }

    // ─────────────────────────────────────────────────────────────
    // transfers: husk holders can receive live positions
    // ─────────────────────────────────────────────────────────────

    function test_HuskReceivesLivePosition() public {
        vm.prank(alice);
        stakerV.lock(1_000e18); // alice: live position
        vm.prank(bob);
        stakerV.lock(0); // bob: husk only
        uint256 bobId = stakerV.tokenOf(bob);
        uint256 aliceId = stakerV.tokenOf(alice);

        // alice's whole position transfers onto bob's husk
        vm.prank(alice);
        stakerV.transferFrom(alice, bob, aliceId);

        assertEq(stakerV.lockedPSPOf(bob), 1_000e18, "position on bob");
        assertEq(stakerV.tokenOf(bob), bobId, "bob keeps HIS pepe");
        assertEq(stakerV.ownerOf(bobId), bob, "bob's husk is the NFT now");
        assertEq(stakerV.tokenOf(alice), 0, "alice's NFT retired");
        assertEq(stakerV.lockedPSPOf(alice), 0);
    }

    function test_TransferToLivePositionStillReverts() public {
        vm.prank(alice);
        stakerV.lock(1_000e18);
        vm.prank(bob);
        stakerV.lock(1_000e18); // both live
        uint256 aliceId = stakerV.tokenOf(alice);

        vm.prank(alice);
        vm.expectRevert(PSPStaker.RecipientHasPosition.selector);
        stakerV.transferFrom(alice, bob, aliceId);
    }

    // ─────────────────────────────────────────────────────────────
    // descriptor wiring (rides the constructor via the factory)
    // ─────────────────────────────────────────────────────────────

    function test_DescriptorRidesConstructorAndFeedsTokenURI() public {
        assertEq(stakerV.descriptor(), address(stub), "wired at birth");

        vm.prank(alice);
        stakerV.lock(1_000e18);
        uint256 id = stakerV.tokenOf(alice);

        // tokenURI must be fed THIS token's dna
        string memory uri = stakerV.tokenURI(id);
        assertGt(bytes(uri).length, 5, "descriptor answered");
        assertTrue(_startsWith(uri, "pepe:P"), "dna-fed URI");
    }

    function test_NoDescriptorRoundRevertsTokenURI() public {
        // a factory that never set a descriptor births rounds without art;
        // staticcall to the zero address returns empty returndata and the
        // string decode of it reverts — loud, deterministic "no art" failure
        RoundController bare = new RoundController(
            pspToken, IERC20(address(mixETH)), CurveMath.singleCurve(
                0.0001e18, 100_000_000e18, 0.000000046e18, 0.1e18
            ), address(mockFactory), address(0), new StakerDeployer());
        // cache the staker: bare.staker() between prank and lock would
        // eat the prank (view call consumes it) — the classic trap
        PSPStaker bareStaker = bare.staker();
        vm.prank(bob);
        bareStaker.lock(0); // pepe-first mint needs no tokens
        uint256 id = bareStaker.tokenOf(bob);
        vm.expectRevert();
        bareStaker.tokenURI(id);
    }

    function _startsWith(string memory s, string memory p) internal pure returns (bool) {
        bytes memory sb = bytes(s);
        bytes memory pb = bytes(p);
        if (sb.length < pb.length) return false;
        for (uint256 i; i < pb.length; i++) {
            if (sb[i] != pb[i]) return false;
        }
        return true;
    }

    // ─────────────────────────────────────────────────────────────
    // lockWithPepe: the chosen-art path (2026-08-23)
    // ─────────────────────────────────────────────────────────────

    uint256 constant CHOSEN = 1_234_567_890_123e6; // user-entropy id range (never collides with early sequential)

    function test_ChosenPepeHatchNoStake() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit PSPStaker.Transfer(address(0), alice, CHOSEN);
        stakerV.lockWithPepe(0, CHOSEN);

        assertEq(stakerV.tokenOf(alice), CHOSEN, "chosen id minted");
        assertEq(stakerV.ownerOf(CHOSEN), alice);
        assertEq(stakerV.lockedPSPOf(alice), 0, "no stake");
        // the WHOLE point: dna = keccak(chosen id) → the pepe you previewed
        assertEq(stakerV.dnaOf(CHOSEN), uint256(keccak256(abi.encodePacked(CHOSEN))), "dna");
    }

    function test_ChosenPepeWithStake() public {
        vm.prank(alice);
        stakerV.lockWithPepe(2_500e18, CHOSEN);

        assertEq(stakerV.tokenOf(alice), CHOSEN);
        assertEq(stakerV.lockedPSPOf(alice), 2_500e18, "staked");
        assertEq(pspToken.balanceOf(address(stakerV)), 2_500e18, "PSP in vault");
        (, , , uint256 unlock) = stakerV.positions(alice);
        assertGt(unlock, block.timestamp, "clock running");
    }

    function test_ChosenPepeTakenReverts() public {
        vm.prank(alice);
        stakerV.lockWithPepe(0, CHOSEN);

        vm.prank(bob);
        vm.expectRevert(PSPStaker.BadPepeId.selector);
        stakerV.lockWithPepe(0, CHOSEN);
    }

    function test_ChosenPepeZeroIdReverts() public {
        vm.prank(alice);
        vm.expectRevert(PSPStaker.BadPepeId.selector);
        stakerV.lockWithPepe(0, 0);
    }

    function test_ChosenPepeAlreadyOwnedReverts() public {
        vm.prank(alice);
        stakerV.lockWithPepe(0, CHOSEN);

        // topping up with a second chosen pepe must fail — lock() is the top-up path
        vm.prank(alice);
        vm.expectRevert(PSPStaker.PepeAlreadyOwned.selector);
        stakerV.lockWithPepe(1_000e18, CHOSEN + 1);

        // but plain lock() still tops up the chosen pepe
        vm.prank(alice);
        stakerV.lock(1_000e18);
        assertEq(stakerV.tokenOf(alice), CHOSEN, "same pepe");
        assertEq(stakerV.lockedPSPOf(alice), 1_000e18, "topped up");
    }

    function test_SequentialSkipsClaimedChosenId() public {
        // bob claims the id sequential minting would hand out next (1)
        vm.prank(bob);
        stakerV.lockWithPepe(0, 1);

        // alice's sequential mint must hop to 2, not overwrite bob's NFT
        vm.prank(alice);
        stakerV.lock(0);
        assertEq(stakerV.tokenOf(alice), 2, "skipped claimed id");
        assertEq(stakerV.ownerOf(1), bob, "chosen id intact");
    }

    function test_ChosenPepePreviewMatchesMint() public {
        // the UI contract: preview via renderSVG(keccak(id)) BEFORE minting,
        // mint, then tokenURI must render the SAME dna — no bait and switch
        uint256 dna = uint256(keccak256(abi.encodePacked(CHOSEN)));
        assertEq(bytes(stub.tokenURI(dna)).length > 0, true, "preview renders");

        vm.prank(alice);
        stakerV.lockWithPepe(5e18, CHOSEN);
        assertEq(
            keccak256(bytes(stakerV.tokenURI(CHOSEN))),
            keccak256(bytes(stub.tokenURI(dna))),
            "minted art == previewed art"
        );
    }
}
