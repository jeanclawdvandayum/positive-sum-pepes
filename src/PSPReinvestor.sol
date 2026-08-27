// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IPSPStaker} from "./interfaces/IPSPStaker.sol";
import {IPSPZapIn} from "./interfaces/IPSPZapIn.sol";

/// @title PSPReinvestor — claim fees and compound them back into the stake
/// @notice For a staked pepe: pulls the position's accrued mixETH fees to
///         this contract, buys PSP on the curve via PSPZapIn.buyWithMix,
///         and stakes the PSP back into the SAME pepe (stakeFor). One tx.
///         Repeats across many pepes via reinvestAll.
///
///         Permissionless and stateless between calls: no custody beyond
///         the in-flight claim, no admin surface. Slippage protection is
///         the caller's (minPspOut + deadline pass through to the zap).
contract PSPReinvestor {
    using SafeERC20 for IERC20;

    IPSPStaker public immutable staker;
    IPSPZapIn public immutable zapIn;
    IERC20 public immutable mix;
    IERC20 public immutable psp;

    error NothingToReinvest();
    error DustStranded(uint256 pspLeft);

    event Reinvested(address indexed owner, uint256 indexed pepeId, uint256 mixIn, uint256 pspStaked);
    event ReinvestedAll(address indexed owner, uint256 count, uint256 mixIn, uint256 pspStaked);

    constructor(IPSPStaker _staker, IPSPZapIn _zapIn, IERC20 _mix, IERC20 _psp) {
        staker = _staker;
        zapIn = _zapIn;
        mix = _mix;
        psp = _psp;
        // standing approvals (immutable counterparties, no race surface:
        // this contract holds no balances at rest)
        mix.forceApprove(address(_zapIn), type(uint256).max);
        psp.forceApprove(address(_staker), type(uint256).max);
    }

    /// @notice Claim one pepe's fees and compound them into the same pepe.
    function reinvest(uint256 pepeId, PoolKey calldata key, uint256 minPspOut, uint256 deadline) external {
        address owner = staker.ownerOf(pepeId);
        // fail fast: stakeFor reverts on a decaying position (RequestActive) —
        // surface that BEFORE the claim+buy legs run
        if (staker.positions(pepeId).requestEpoch != 0) revert NothingToReinvest();

        uint256 mixBefore = mix.balanceOf(address(this));
        staker.claimFeesTo(pepeId, address(this));
        uint256 mixIn = mix.balanceOf(address(this)) - mixBefore;
        if (mixIn == 0) revert NothingToReinvest();

        uint256 pspBefore = psp.balanceOf(address(this));
        zapIn.buyWithMix(key, mixIn, minPspOut, deadline);
        uint256 bought = psp.balanceOf(address(this)) - pspBefore;

        // stake everything back into the caller's pepe. Owner check inside
        // stakeFor guarantees the PSP lands in `owner`'s position; only the
        // owner (or an operator) benefits. Anyone can pay the gas.
        staker.stakeFor(owner, pepeId, bought);

        uint256 left = psp.balanceOf(address(this));
        if (left > pspBefore && left > 1e3) revert DustStranded(left);

        emit Reinvested(owner, pepeId, mixIn, bought);
    }

    /// @notice Multiclaim + compound across pepes in one transaction.
    ///         minPspOut applies to the aggregated buy.
    function reinvestAll(
        uint256[] calldata pepeIds,
        PoolKey calldata key,
        uint256 minPspOut,
        uint256 deadline
    ) external {
        uint256 mixBefore = mix.balanceOf(address(this));
        staker.claimAllTo(pepeIds, address(this));
        uint256 mixIn = mix.balanceOf(address(this)) - mixBefore;
        if (mixIn == 0) revert NothingToReinvest();

        // fail fast on any decaying pepe (stakeFor would revert post-buy)
        // and size the proportional split basis
        uint256 totalShare;
        for (uint256 i; i < pepeIds.length; ++i) {
            IPSPStaker.PositionView memory pos = staker.positions(pepeIds[i]);
            if (pos.requestEpoch != 0) revert NothingToReinvest();
            totalShare += pos.amount;
        }
        if (totalShare == 0) revert NothingToReinvest();

        uint256 pspBefore = psp.balanceOf(address(this));
        zapIn.buyWithMix(key, mixIn, minPspOut, deadline);
        uint256 bought = psp.balanceOf(address(this)) - pspBefore;

        // spread the buy proportionally across the claimed pepes
        for (uint256 i; i < pepeIds.length; ++i) {
            uint256 share = (bought * staker.positions(pepeIds[i]).amount) / totalShare;
            if (share != 0) staker.stakeFor(staker.ownerOf(pepeIds[i]), pepeIds[i], share);
        }

        uint256 left = psp.balanceOf(address(this));
        if (left > pspBefore && left > 1e3) revert DustStranded(left);

        emit ReinvestedAll(staker.ownerOf(pepeIds[0]), pepeIds.length, mixIn, bought);
    }
}
