// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MaliciousMixETH — Simulates attack vectors from DeFiHackLabs
/// @notice Implements multiple malicious behaviors toggleable by flags,
///         inspired by real exploits:
///         - Fee-on-transfer (DIP hack 2026-06-16)
///         - Reentrancy on transfer (Cream Finance, multiple)
///         - Reentrancy on totalAssets (read-only reentrancy: Curve LlamaLend)
///         - Balance manipulation (bankroll exploits)
contract MaliciousMixETH is ERC20 {
    uint256 public totalDepositedETH;
    uint256 public feeBps = 0;          // fee-on-transfer simulation
    bool public reenterOnTransfer;      // reentrancy on transfer
    bool public reenterOnTotalAssets;   // read-only reentrancy
    address public reenterTarget;
    bytes public reenterCallData;

    constructor() ERC20("Malicious mixETH", "BADmix") {}

    function depositETH() external payable returns (uint256 shares) {
        totalDepositedETH += msg.value;
        shares = msg.value;
        _mint(msg.sender, shares);
    }

    function totalAssets() external returns (uint256) {
        if (reenterOnTotalAssets) {
            // Read-only reentrancy: call back into controller during view function
            (bool success,) = reenterTarget.call(reenterCallData);
            require(success, "reenter failed");
        }
        return totalDepositedETH;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (reenterOnTransfer && reenterTarget != address(0)) {
            // Reenter before state update
            (bool success,) = reenterTarget.call(reenterCallData);
            require(success, "reenter failed");
        }
        uint256 fee = amount * feeBps / 10000;
        uint256 actualAmount = amount - fee;
        return super.transfer(to, actualAmount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount * feeBps / 10000;
        uint256 actualAmount = amount - fee;
        return super.transferFrom(from, to, actualAmount);
    }

    /// @dev Set fee-on-transfer
    function setFee(uint256 _feeBps) external {
        feeBps = _feeBps;
    }

    /// @dev Configure reentrancy
    function setReenterOnTransfer(bool _val, address _target, bytes calldata _data) external {
        reenterOnTransfer = _val;
        reenterTarget = _target;
        reenterCallData = _data;
    }

    function setReenterOnTotalAssets(bool _val, address _target, bytes calldata _data) external {
        reenterOnTotalAssets = _val;
        reenterTarget = _target;
        reenterCallData = _data;
    }

    /// @dev Simulate yield accrual
    function simulateYield(uint256 ethAmount) external payable {
        totalDepositedETH += ethAmount;
    }

    /// @dev Direct balance manipulation (donation attack)
    function donateETH() external payable {
        totalDepositedETH += msg.value;
    }

    receive() external payable {
        totalDepositedETH += msg.value;
    }
}
