// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MixETHFaucet — subsidized mixETH for PSP playtests
/// @notice Pay 0.0001 testnet ETH, receive 100 mixETH. Multiples work:
///         drips = msg.value / 0.0001 ETH; dust below one unit is kept
///         (≤ 0.0001 ETH per call, negligible). Holds a pre-seeded mixETH
///         inventory (the SepoliaMixETH constructor supply, transferred in
///         by the deploy script).
///
///         No owner, no per-address limit, no pause — a testnet convenience
///         with zero attack surface worth guarding. Collected ETH stays in
///         the contract (nothing to steal, nothing to admin).
contract MixETHFaucet {
    using SafeERC20 for IERC20;

    /// @dev Price of one drip unit.
    uint256 public constant DRIP_PRICE = 0.0001 ether; // 1e14 wei
    /// @dev mixETH per drip unit.
    uint256 public constant DRIP_AMOUNT = 100 ether;

    IERC20 public immutable mixETH;

    error TooLittle();
    error FaucetEmpty();

    event Dripped(address indexed to, uint256 ethPaid, uint256 mixOut);

    constructor(IERC20 _mixETH) {
        mixETH = _mixETH;
    }

    /// @notice Buy mixETH at the subsidized playtest rate (per 0.0001 ETH).
    function drip() external payable {
        uint256 units = msg.value / DRIP_PRICE;
        if (units == 0) revert TooLittle();
        uint256 out = units * DRIP_AMOUNT;
        if (mixETH.balanceOf(address(this)) < out) revert FaucetEmpty();
        emit Dripped(msg.sender, msg.value, out);
        mixETH.safeTransfer(msg.sender, out);
    }

    /// @dev Accept accidental sends; like drip revenue, not recoverable.
    receive() external payable {}
}
