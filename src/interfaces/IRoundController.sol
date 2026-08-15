// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CurveMath} from "../libraries/CurveMath.sol";

interface IRoundController {
    // ── Token refs ──
    function getPSP() external view returns (address);
    function getMixETH() external view returns (Currency);

    // ── Price conversion ──
    function mixETHToETH(uint256 mixETHAmount) external view returns (uint256);
    function ethToMixETH(uint256 ethAmount) external view returns (uint256);

    // ── Swap support (called by hook) ──
    function mintPSPForSwap(uint256 amount) external;
    function burnPSPForSwap(uint256 amount) external;
    function addFees(uint256 ethAmount) external;

    // ── Curve params ──
    function getCurveConfig() external view returns (CurveMath.CurveConfig memory);
}
