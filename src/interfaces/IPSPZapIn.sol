// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev Slice of PSPZapIn the reinvestor touches.
interface IPSPZapIn {
    function buyWithMix(PoolKey calldata key, uint256 mixIn, uint256 minPspOut, uint256 deadline)
        external
        returns (uint256 pspOut);
}
