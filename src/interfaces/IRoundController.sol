// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {CurveMath} from "../libraries/CurveMath.sol";

interface IRoundController {
    // ── Token refs ──
    function getPSP() external view returns (address);
    function getMixETH() external view returns (Currency);

    // ── Price conversion ──
    function mixETHToETH(uint256 mixETHAmount) external view returns (uint256);

    // ── Swap support (called by hook) ──
    function mintPSPForSwap(uint256 amount) external;
    function burnPSPForSwap(uint256 amount) external;
    function addFees(uint256 mixETHAmount) external;

    // ── Staker wiring (PSPStaker reads these through this interface) ──
    function stakerAddress() external view returns (address);
    function hookAddress() external view returns (address);
    function flatTime() external view returns (uint256);
    function VEST_DURATION() external view returns (uint256);

    // ── Curve params ──
    function getCurveConfig() external view returns (CurveMath.CurveConfig memory);
}
