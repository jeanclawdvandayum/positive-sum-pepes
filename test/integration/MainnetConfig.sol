// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MainnetConfig - Deployed contract addresses for fork testing
/// @notice All addresses are Ethereum mainnet (chainId 1).
///         Update MIXETH_ADDRESS if needed - ask scoopy to confirm.
library MainnetConfig {
    // ── Uniswap V4 ──────────────────────────────────────────
    /// @notice V4 PoolManager singleton on mainnet
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    /// @notice CREATE2 deployer proxy (for hook address mining)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Universal Router (for swap routing if needed)
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    // ── Tokens ──────────────────────────────────────────────
    /// @notice WETH on mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice USDC on mainnet (6 decimals)
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // ── Alchemix V3 ─────────────────────────────────────────
    /// @notice USDC Alchemist V3 (for reference / testing)
    address constant USDC_ALCHEMIST = 0xeB83112d925268BeDe86654C13D423a987587e3E;

    /// @notice alETH token on mainnet
    address constant AL_ETH = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;

    /// @notice alUSD token on mainnet
    address constant AL_USD = 0xBC6DA0FE9aD5f3b0d58160288917AA56653660E9;

    /// @notice Alchemix V3 ETH vault (mixETH / MYT vault for ETH)
    /// @dev VaultV2 contract that wraps WETH into a yield-bearing share token.
    address constant MIXETH_VAULT = 0x29bcfeD246ce37319d94eBa107db90C453D4c43D;

    // ── Chainlink ───────────────────────────────────────────
    /// @notice ETH/USD price feed (for reference)
    address constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
}
