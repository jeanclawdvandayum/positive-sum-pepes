// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Slice of PSPStaker the reinvestor touches (EIP-170: interfaces
///      only — no concrete imports into the reinvestor).
interface IPSPStaker {
    struct PositionView {
        uint256 amount;
        uint256 startEpoch;
        uint256 requestEpoch; // 0 = indefinitely locked (reinvestable)
        uint256 creditCheckpoint;
        uint256 feesPaid;
        uint256 actionTime;
    }

    function ownerOf(uint256 pepeId) external view returns (address);
    function positions(uint256 pepeId) external view returns (PositionView memory);
    function primaryOf(address user) external view returns (uint256);
    function stakedTotalOf(address user) external view returns (uint256);
    function claimFeesTo(uint256 pepeId, address to) external;
    function claimAllTo(uint256[] calldata pepeIds, address to) external;
    function stakeFor(address user, uint256 pepeId, uint256 amount) external;
}
