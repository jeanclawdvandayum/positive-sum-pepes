// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal interfaces — keeps the router standalone and its bytecode tiny.
interface GraveHook {
    function claimablePot(address who) external view returns (uint256);
    function claimPotFor(address who) external;
    function redeemBacking(uint256 pspAmount) external returns (uint256 mixETHOut);
}

interface GraveStaker {
    function psp() external view returns (address);
    function ownerOf(uint256 pepeId) external view returns (address);
    function pendingFeesOf(uint256 pepeId) external view returns (uint256);
    function claimAllTo(uint256[] calldata pepeIds, address to) external;
    function withdrawFor(uint256 pepeId) external;
}

/// @title PSPGraveZap — one-transaction graveyard exit.
/// @notice After detonation a holder's full exit is: ladder pot claim, fee
///         claim, lock withdrawal, PSP redemption against the dead curve.
///         This router performs all four legs in ONE call:
///           1. `hook.claimPotFor(user)`  — pot mixETH straight to the user
///              (never through the zap; a malicious zap cannot intercept),
///           2. `staker.claimAllTo(ids, user)` — accrued fees to the user,
///              skipped when zero,
///           3. `staker.withdrawFor(id)` per pepe — principal PSP to the
///              user (operator path; pays the owner, never the caller),
///           4. `hook.redeemBacking(pspIn)` on PSP pulled from the user via
///              allowance — the fee-free pro-rata backing exit — with the
///              proceeds forwarded to the user.
///         Holds no funds between transactions. Fail-loud by design: an
///         unstaked pepe id reverts the whole exit (the UI filters ids);
///         nothing is silently skipped except the two zero-guarded claims.
contract PSPGraveZap {
    using SafeERC20 for IERC20;

    error Expired();
    error InsufficientOutput();
    error NotNftOwner();

    /// @dev The mix token claims and redemptions pay out. One zap deployment
    ///      per mixETH deployment, mirroring PSPZapOut's constructor pin.
    address public immutable mixETH;

    constructor(address _mixETH) {
        mixETH = _mixETH;
    }

    /// @param hookAddr   the round's CurveHook (settled)
    /// @param staker     the round's PSPStaker
    /// @param pepeIds    staked pepe ids to unlock (unstaked ids revert — UI filters)
    /// @param pspIn      PSP to redeem after unlocking (user allowance to this
    ///                   zap required; pass 0 to skip the redemption leg)
    /// @param minMixOut  revert if redemption yields fewer mixETH shares
    /// @param deadline   revert if executed after this timestamp (0 = off)
    /// @return mixOut    mixETH forwarded to the caller from redemption
    function exit(
        address hookAddr,
        address staker,
        uint256[] calldata pepeIds,
        uint256 pspIn,
        uint256 minMixOut,
        uint256 deadline
    ) external returns (uint256 mixOut) {
        if (deadline != 0 && block.timestamp > deadline) revert Expired();
        // V3-INT-1: approval grants the zap access, not arbitrary callers.
        // Each position must belong to the caller before any exit leg runs.
        for (uint256 i; i < pepeIds.length; ++i) {
            if (GraveStaker(staker).ownerOf(pepeIds[i]) != msg.sender) revert NotNftOwner();
        }
        GraveHook hook = GraveHook(hookAddr);

        // Leg 1 — ladder pot, user-direct.
        if (hook.claimablePot(msg.sender) != 0) {
            hook.claimPotFor(msg.sender);
        }

        // Leg 2 — accrued fees, user-direct; zero-guarded (claimAllTo reverts
        // NothingToClaim on an empty purse — a clean wallet is not an error).
        uint256 fees;
        for (uint256 i; i < pepeIds.length; ++i) {
            fees += GraveStaker(staker).pendingFeesOf(pepeIds[i]);
        }
        if (fees != 0) {
            GraveStaker(staker).claimAllTo(pepeIds, msg.sender);
        }

        // Leg 3 — unlock: principal PSP lands in the OWNER's wallet.
        for (uint256 i; i < pepeIds.length; ++i) {
            GraveStaker(staker).withdrawFor(pepeIds[i]);
        }

        // Leg 4 — fee-free pro-rata redemption of the user's PSP.
        if (pspIn == 0) return 0;

        IERC20 psp = IERC20(GraveStaker(staker).psp());
        psp.safeTransferFrom(msg.sender, address(this), pspIn);
        psp.forceApprove(hookAddr, pspIn);
        mixOut = hook.redeemBacking(pspIn);
        if (mixOut < minMixOut) revert InsufficientOutput();

        // Forward everything from this redemption — no balances held.
        IERC20(mixETH).safeTransfer(msg.sender, mixOut);
    }
}
