// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Read-only v3 curve settlement surface (SineV3Math helper).
///         One deployed instance per factory; every round's hook calls it
///         statically. The table is the code — no configuration exists.
interface ISineV3Math {
    /// @notice Wavelength from actual net backing (WAD mixETH).
    function lamAt(uint256 bootWei) external pure returns (uint256);

    /// @notice Tenth-wave reserve target: boot + 10*lam.
    function targetAt(uint256 bootWei, uint256 lamWei) external pure returns (uint256);

    /// @notice Marginal price at reserve R (WAD mixETH per PSP).
    function priceWad(uint256 R, uint256 boot, uint256 lam, uint256 pL)
        external
        pure
        returns (uint256);

    /// @notice Cumulative supply Q(R) from reserve zero (WAD PSP).
    function supplyWad(uint256 R, uint256 boot, uint256 lam, uint256 pL)
        external
        pure
        returns (uint256);

    /// @notice Genesis supply Q(b) on the same curve.
    function genesisQ(uint256 boot, uint256 lam, uint256 pL)
        external
        pure
        returns (uint256);

    /// @notice Conservative PSP out for a curve spend at reserve R.
    function buyOut(uint256 R, uint256 boot, uint256 lam, uint256 pL, uint256 spend)
        external
        pure
        returns (uint256);

    /// @notice Conservative mixETH out for burning pspIn at reserve R.
    function sellOut(uint256 R, uint256 boot, uint256 lam, uint256 pL, uint256 pspIn)
        external
        pure
        returns (uint256);
}
