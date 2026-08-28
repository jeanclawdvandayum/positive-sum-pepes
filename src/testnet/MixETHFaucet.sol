// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The mock mixETH mints freely on testnet (see SepoliaMixETH.mint).
interface IMintableMix {
    function mint(address to, uint256 amount) external;
}

/// @title MixETHFaucet — free, unlimited mixETH for PSP playtests
/// @notice 2026-08-28 rewrite: the faucet used to sell 100 mixETH per
///         0.0001 testnet ETH out of a pre-seeded inventory. That made
///         faucet-bought mixETH unbacked by any ETH while the zap routers
///         still redeemed mixETH -> ETH — every "sell PSP for ETH" reverted.
///         Testnet mixETH is now pure playtest scrip: drip() mints any
///         requested amount for free, straight from the token. No ETH, no
///         inventory, no price, nothing to run out of.
///
///         No owner, no per-address limit, no pause — a testnet convenience
///         with zero attack surface worth guarding.
contract MixETHFaucet {
    /// @dev mixETH mock with a public mint.
    IMintableMix public immutable mixETH;

    error ZeroAmount();

    event Dripped(address indexed to, uint256 amount);

    constructor(IERC20 _mixETH) {
        mixETH = IMintableMix(address(_mixETH));
    }

    /// @notice Mint mixETH to yourself, free, in any amount.
    /// @param amount mixETH (wei) to mint — playtest scrip, take what you need
    function drip(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        emit Dripped(msg.sender, amount);
        mixETH.mint(msg.sender, amount);
    }
}
