// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BBase} from "./BBase.sol";
import {PSPGraveZap} from "../../../src/PSPGraveZap.sol";
import {PSPZapIn} from "../../../src/PSPZapIn.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {PSPStaker} from "../../../src/PSPStaker.sol";
import {IMixETH} from "../../../src/interfaces/IMixETH.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title B6 — PSPGraveZap: one-tx graveyard exit against the REAL PoolManager.
/// @dev Real behavior only: a live launch, real buys (seats), real locks,
///      real detonation, then the zap. No mocked token movement anywhere.
contract B6_GraveZap is BBase {
    PSPGraveZap zap;
    PSPZapIn zapIn;

    function setUp() public virtual override {
        super.setUp();
        zap = new PSPGraveZap(address(mixETH));
        zapIn = new PSPZapIn(IMixETH(address(mixETH)), IPoolManager(address(poolManager)));
        _launch(100e18);
    }

    function _staked(uint256 pepeId) internal view returns (uint256 amount) {
        (amount,,,,) = PSPStaker(address(stakerV)).positions(pepeId);
    }

    /// @dev alice buys via zapIn.buyWithMix (trader = alice → SHE holds the
    ///      seats; the raw router path attributes tickets to its swapper),
    ///      locks the PSP, bomb falls.
    function _aliceStakes() internal returns (uint256 pepeId) {
        vm.startPrank(alice);
        mixETH.approve(address(zapIn), 10e18);
        uint256 pspOut = zapIn.buyWithMix(key, 10e18, 0, 0);
        psp.approve(address(stakerV), type(uint256).max);
        pepeId = stakerV.nextTokenId();
        stakerV.lock(pspOut);
        vm.stopPrank();
    }

    // ── happy path: pot + fees + unlock + redeem all in ONE tx ──
    function test_B6a_ExitSweepsEverything() public {
        uint256 pepeId = _aliceStakes();
        _bomb();
        uint256 amount = _staked(pepeId);
        assertGt(amount, 0, "stake exists");

        uint256 mixBefore = mixETH.balanceOf(alice);
        uint256 potDue = hook.claimablePot(alice);
        assertGt(potDue, 0, "alice held seats");

        vm.startPrank(alice);
        stakerV.setApprovalForAll(address(zap), true);
        psp.approve(address(zap), type(uint256).max);
        uint256 mixOut = zap.exit(address(hook), address(stakerV), _single(pepeId), amount, 0, 0);
        vm.stopPrank();

        // pot arrived user-direct; fees were zero (no trades while staked)
        assertEq(mixETH.balanceOf(alice) - mixBefore, potDue + mixOut, "pot + swap out, exact");

        // lock opened: NFT survives, position drained, PSP sold
        assertEq(_staked(pepeId), 0, "position drained");
        assertEq(stakerV.ownerOf(pepeId), alice, "NFT husk survives");
        assertEq(psp.balanceOf(alice), 0, "all PSP redeemed");
        assertEq(psp.balanceOf(address(zap)), 0, "zap holds no PSP");
        assertEq(mixETH.balanceOf(address(zap)), 0, "zap holds no mix");
    }

    // ── minMixOut reverts the WHOLE exit — no partial state survives ──
    function test_B6b_MinOutRevertsEverything() public {
        uint256 pepeId = _aliceStakes();
        _bomb();
        uint256 amount = _staked(pepeId);

        uint256 potBefore = hook.claimablePot(alice);
        assertGt(potBefore, 0);

        vm.startPrank(alice);
        stakerV.setApprovalForAll(address(zap), true);
        psp.approve(address(zap), type(uint256).max);
        uint256 fair = hook.getSellOutput(amount);
        vm.expectRevert(PSPGraveZap.InsufficientOutput.selector);
        zap.exit(address(hook), address(stakerV), _single(pepeId), amount, fair + 1, 0);
        vm.stopPrank();

        // nothing moved: pot claimable, position intact, PSP still locked
        assertEq(hook.claimablePot(alice), potBefore, "pot untouched");
        assertEq(_staked(pepeId), amount, "position intact");
        assertEq(psp.balanceOf(alice), 0, "PSP still locked");
    }

    // ── authorization: a stranger (no NFT approval) cannot unlock via the zap ──
    function test_B6c_StrangerCannotExit() public {
        uint256 pepeId = _aliceStakes();
        _bomb();
        uint256 amount = _staked(pepeId);

        vm.startPrank(carol);
        psp.approve(address(zap), type(uint256).max);
        bytes memory reason = abi.encodeWithSelector(PSPStaker.NotNftOwner.selector);
        vm.expectRevert(reason);
        zap.exit(address(hook), address(stakerV), _single(pepeId), amount, 0, 0);
        vm.stopPrank();

        assertEq(_staked(pepeId), amount, "position intact");
        assertEq(psp.balanceOf(carol), 0, "carol got nothing");
    }

    // ── claimPotFor: a third party can only CREDIT the seat owner ──
    function test_B6d_ClaimPotForPaysOwnerOnly() public {
        _aliceStakes();
        _bomb();

        uint256 due = hook.claimablePot(alice);
        assertGt(due, 0);
        uint256 mixBefore = mixETH.balanceOf(alice);
        uint256 carolBefore = mixETH.balanceOf(carol);

        vm.prank(carol);
        CurveHook(address(hook)).claimPotFor(alice);

        assertEq(mixETH.balanceOf(alice) - mixBefore, due, "alice paid in full");
        assertEq(mixETH.balanceOf(carol), carolBefore, "carol got nothing");
        assertEq(hook.claimablePot(alice), 0, "seats marked claimed");
    }

    // ── withdrawFor: operator call pays the OWNER principal ──
    function test_B6e_WithdrawForPaysOwner() public {
        uint256 pepeId = _aliceStakes();
        _bomb();
        uint256 amount = _staked(pepeId);

        vm.startPrank(alice);
        stakerV.setApprovalForAll(carol, true);
        vm.stopPrank();

        uint256 pspBefore = psp.balanceOf(alice);
        vm.prank(carol);
        stakerV.withdrawFor(pepeId);

        assertEq(psp.balanceOf(alice) - pspBefore, amount, "principal to owner");
        assertEq(psp.balanceOf(carol), 0, "operator got nothing");
        assertEq(_staked(pepeId), 0, "lock opened");
    }

    // ── zero-fee wallet: fees leg skipped, no NothingToClaim revert ──
    function test_B6f_CleanWalletClaimsSkip() public {
        uint256 pepeId = _aliceStakes();
        _bobBuysAndLocks(5e18); // a trade while alice is staked → fees accrue
        _bomb();
        assertGt(stakerV.pendingFeesOf(pepeId), 0, "fees accrued");

        // alice claims her fees manually first — zap's fee leg must then skip
        vm.prank(alice);
        stakerV.claimAllTo(_single(pepeId), alice);

        vm.startPrank(alice);
        stakerV.setApprovalForAll(address(zap), true);
        psp.approve(address(zap), type(uint256).max);
        uint256 mixOut = zap.exit(address(hook), address(stakerV), _single(pepeId), 0, 0, 0);
        vm.stopPrank();

        assertEq(mixOut, 0, "no swap leg");
        assertEq(_staked(pepeId), 0, "unlock still ran");
    }

    // ── deadline gate ──
    function test_B6g_Deadline() public {
        uint256 pepeId = _aliceStakes();
        _bomb();
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vm.expectRevert(PSPGraveZap.Expired.selector);
        zap.exit(address(hook), address(stakerV), _single(pepeId), 0, 0, block.timestamp - 1);
    }

    function _single(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}
