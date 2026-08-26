// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SepoliaMixETH — dumb 1:1 ETH wrapper for PSP testnet playtests
/// @notice The real mixETH is an Alchemix yield vault. For playtests this is
///         a HARDCODED 1:1 wrapper: 1 wei ETH = 1 wei mixETH, forever. No
///         yield, no rate variable, no owner, no admin surface — the
///         sharesToAssets rate is always exactly 1e18 by construction.
///
///         Born with SUPPLY (10,000,000 mixETH) minted to the deployer; the
///         deploy script seeds the MixETHFaucet with all of it (testers pay
///         0.0001 testnet ETH for 100 mixETH — Sepolia ETH is scarce, the
///         game's mixETH unit is not).
///
///         NEVER deploy to mainnet: the supply is not backed 1:1 by ETH.
contract SepoliaMixETH is ERC20 {
    /// @dev Faucet inventory: 10M mixETH = 100,000 full-rate drips.
    uint256 public constant SUPPLY = 10_000_000 ether;

    constructor() ERC20("Sepolia mixETH (PSP test)", "mixETH") {
        _mint(msg.sender, SUPPLY);
    }

    /// @notice Wrap ETH at the hardcoded 1:1 rate — exactly msg.value shares.
    function depositETH() external payable returns (uint256 shares) {
        require(msg.value > 0, "Zero deposit");
        shares = msg.value;
        _mint(msg.sender, shares);
    }

    /// @notice Unwrap at the hardcoded 1:1 rate. CEI: burn before the ETH
    ///         call. Force-sent ETH (receive/selfdestruct) is redeemable by
    ///         depositors first-come — acceptable on a testnet wrapper.
    function redeemETH(uint256 shareAmount) external returns (uint256 ethOut) {
        require(shareAmount > 0, "Zero amount");
        ethOut = shareAmount; // hardcoded 1:1
        _burn(msg.sender, shareAmount);
        (bool ok,) = msg.sender.call{value: ethOut}("");
        require(ok, "ETH transfer failed");
    }

    /// @notice ERC-4626-style view; at 1:1 this is just totalSupply().
    function totalAssets() external view returns (uint256) {
        return totalSupply();
    }

    /// @dev Accept stray ETH (refunds, accidental sends).
    receive() external payable {}
}
