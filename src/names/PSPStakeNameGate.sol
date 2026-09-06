// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPSPStaker} from "../interfaces/IPSPStaker.sol";

/// @title INameEligibility
/// @notice Registration qualification, separate from WNS custody and PSP accounting.
interface INameEligibility {
    function isEligible(address account, bytes calldata proof) external view returns (bool);
}

interface INameGateFactory {
    function rounds(uint256 id) external view returns (address token, address controller, address hook,
        bool destroyed, string memory name, string memory symbol);
}
interface INameGateController { function staker() external view returns (address); }

/// @title PSPStakeNameGate
/// @notice SAME-CHAIN qualification only. Ownership plus positive PSP principal
/// in any registered round qualifies, including a position awaiting withdrawal.
/// This contract cannot read a PSP factory on another network.
contract PSPStakeNameGate is INameEligibility {
    INameGateFactory public immutable factory;
    error InvalidFactory();

    constructor(INameGateFactory factory_) {
        if (address(factory_).code.length == 0) revert InvalidFactory();
        factory = factory_;
    }

    /// @notice proof = abi.encode(roundId, pepeId). Empty proof opts into paid
    /// registration. Operators qualify only for positions that they own.
    function isEligible(address account, bytes calldata proof) external view returns (bool) {
        if (account == address(0) || proof.length == 0) return false;
        if (proof.length != 64) return false;
        (uint256 roundId, uint256 pepeId) = abi.decode(proof, (uint256, uint256));
        (address token, address controller,,,,) = factory.rounds(roundId);
        if (token == address(0) || controller == address(0)) return false;
        address stakerAddress = INameGateController(controller).staker();
        if (stakerAddress == address(0)) return false;
        IPSPStaker staker = IPSPStaker(stakerAddress);
        // A nonexistent NFT is ineligible; a broken factory/controller is an
        // integration error and must not silently quote a fee to a staker.
        try staker.ownerOf(pepeId) returns (address holder) {
            return holder == account && staker.positions(pepeId).amount > 0;
        } catch { return false; }
    }
}
