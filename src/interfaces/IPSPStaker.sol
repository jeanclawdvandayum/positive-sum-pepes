// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IPSPStaker — the per-round PSP staking vault (ERC-721 positions)
/// @notice Consumed by PSPReferralRegistry (NFT resolution + min-stake gate)
///         and CurveHook (fee routing). Subset of PSPStaker's surface.
interface IPSPStaker {
    function tokenOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function lockedPSPOf(address user) external view returns (uint256);
    function totalLocked() external view returns (uint256);
}
