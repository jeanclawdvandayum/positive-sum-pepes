// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockMixETH — Simplified ERC-4626 vault for testing
/// @notice Simulates Alchemix mixETH: ETH backing with yield accrual.
///         Exchange rate starts at 1:1 and can be adjusted via setExchangeRate()
///         to simulate yield. totalAssets() returns ETH-equivalent of all shares.
contract MockMixETH is ERC20 {
    uint256 public totalDepositedETH;
    /// @dev Exchange rate: how much ETH one share is worth, scaled by 1e18.
    ///      1e18 = 1:1. 1.1e18 = 1 share redeems for 1.1 ETH.
    uint256 public exchangeRate = 1e18;

    constructor() ERC20("Mock mixETH", "mixETH") {}

    /// @notice Deposit ETH and receive mixETH shares at current exchange rate
    function depositETH() external payable returns (uint256 shares) {
        uint256 ethValue = msg.value;
        require(ethValue > 0, "Zero deposit");

        totalDepositedETH += ethValue;

        // shares = ethValue / exchangeRate (scaled 1e18)
        shares = (ethValue * 1e18) / exchangeRate;
        _mint(msg.sender, shares);
    }

    /// @dev TESTNET FAUCET — free mixETH for demos. The PSP_TESTNET deploy
    ///      path uses this mock on public testnets where wrapping real ETH
    ///      at the 500 mixETH predeposit cap would cost 500 real testnet ETH.
    ///      Never deploy this mock to mainnet.
    function faucet(uint256 amount) external {
        _mint(msg.sender, amount);
    }

    /// @notice Redeem mixETH shares for ETH at current exchange rate
    function redeemETH(uint256 shareAmount) external returns (uint256 ethOut) {
        require(shareAmount > 0, "Zero amount");
        require(balanceOf(msg.sender) >= shareAmount, "Insufficient");

        ethOut = (shareAmount * exchangeRate) / 1e18;
        _burn(msg.sender, shareAmount);
        totalDepositedETH -= ethOut;

        (bool success,) = msg.sender.call{value: ethOut}("");
        require(success, "Transfer failed");
    }

    /// @notice Simulate yield by increasing the exchange rate.
    ///         Sends ETH to backfill, then sets new rate based on total value.
    /// @dev Backward-compatible with old tests that call simulateYield{value:X}(X)
    function simulateYield(uint256 ethAmount) external payable {
        require(msg.value == ethAmount, "Must send ETH");
        require(ethAmount > 0, "Zero yield");

        // totalDepositedETH increases by the yield amount
        totalDepositedETH += ethAmount;

        // Recalculate exchange rate from new total value
        uint256 totalShares = totalSupply();
        if (totalShares > 0) {
            exchangeRate = (totalDepositedETH * 1e18) / totalShares;
        }
    }

    /// @notice Directly set exchange rate (for precise yield control in tests)
    /// @param newRate Must be > current rate
    function setExchangeRate(uint256 newRate) external {
        require(newRate > exchangeRate, "Rate can only increase");
        uint256 newTotalValue = (totalSupply() * newRate) / 1e18;
        require(newTotalValue > totalDepositedETH, "Insufficient backing");
        totalDepositedETH = newTotalValue;
        exchangeRate = newRate;
    }

    /// @notice ERC-4626-style totalAssets: total ETH value of all shares
    function totalAssets() external view returns (uint256) {
        return (totalSupply() * exchangeRate) / 1e18;
    }

    /// @dev Accept ETH (for yield backfill)
    receive() external payable {}
}
