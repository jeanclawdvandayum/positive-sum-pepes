// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IWeiNames} from "../interfaces/IWeiNames.sol";

/// @title PSPNameCustody
/// @notice Holds one WNS parent for a registrar. The owner can renew, manage
/// parent records and recover the parent NFT. Child NFTs belong to their users.
/// WNS parent ownership also permits reclaiming children; recovery retains that power.
abstract contract PSPNameCustody is Ownable2Step, ReentrancyGuard, IERC721Receiver {
    IWeiNames public immutable names;
    uint256 public immutable parentId;
    uint64 public parentEpoch;
    bool public registrationEnabled;

    error InvalidParent();
    error WrongPayment();
    error RegistrationClosed();
    error UnexpectedNFT();
    error InvalidRecipient();
    error OwnershipRequired();

    event RegistrationEnabled(bool enabled, uint64 parentEpoch);
    event ParentRecovered(address indexed recipient);
    event ParentRenewed(uint256 fee);

    constructor(IWeiNames names_, uint256 parentId_, address admin) Ownable(admin) {
        if (address(names_).code.length == 0 || parentId_ == 0) revert InvalidParent();
        names = names_;
        parentId = parentId_;
        (string memory label, uint256 parent,, uint64 epoch,) = names_.records(parentId_);
        if (parent != 0 || epoch == 0 || bytes(label).length == 0) revert InvalidParent();
    }

    /// @notice Accept only this registrar's parent NFT from the current admin.
    /// Custody alone never enables public registration.
    function onERC721Received(address, address from, uint256 id, bytes calldata)
        external view returns (bytes4)
    {
        if (msg.sender != address(names) || id != parentId || from != owner()
            || names.ownerOf(id) != address(this)) revert UnexpectedNFT();
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Enable registration after the parent has been transferred here,
    /// or pause new registrations while keeping existing names with their owners.
    function setRegistrationEnabled(bool enabled) external onlyOwner nonReentrant {
        if (enabled) {
            if (names.ownerOf(parentId) != address(this) || names.resolve(parentId) == address(0)) {
                revert InvalidParent();
            }
            (,,, uint64 epoch,) = names.records(parentId);
            parentEpoch = epoch;
        }
        registrationEnabled = enabled;
        emit RegistrationEnabled(enabled, parentEpoch);
    }

    /// @notice Return domain custody to the admin's chosen address. In the WNS
    /// expiry grace period, renew the parent before attempting a transfer.
    function recoverParent(address to) external onlyOwner nonReentrant {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        registrationEnabled = false;
        emit RegistrationEnabled(false, parentEpoch);
        names.safeTransferFrom(address(this), to, parentId);
        emit ParentRecovered(to);
    }

    /// @notice Renew using fresh ETH supplied by the admin, separate from
    /// registration fees. Exact payment avoids a WNS refund callback.
    function renewParent() external payable onlyOwner nonReentrant {
        (string memory label,,,,) = names.records(parentId);
        uint256 fee = names.getFee(bytes(label).length);
        if (msg.value != fee) revert WrongPayment();
        names.renew{value: fee}(parentId);
        emit ParentRenewed(fee);
    }

    /// @notice Manage the parent domain's ETH resolution record.
    function setParentAddress(address account) external onlyOwner nonReentrant {
        names.setAddr(parentId, account);
    }

    /// @notice Manage the parent domain's chain-specific address record.
    function setParentCoinAddress(uint256 coinType, bytes calldata account) external onlyOwner nonReentrant {
        names.setAddrForCoin(parentId, coinType, account);
    }

    /// @notice Manage the parent domain's text records.
    function setParentText(string calldata key, string calldata value) external onlyOwner nonReentrant {
        names.setText(parentId, key, value);
    }

    /// @notice Manage the parent domain's content pointer.
    function setParentContenthash(bytes calldata contenthash) external onlyOwner nonReentrant {
        names.setContenthash(parentId, contenthash);
    }

    /// @notice Domain recovery requires an admin; use the two-step ownership
    /// transfer to rotate keys or move administration to a multisig.
    function renounceOwnership() public view override onlyOwner { revert OwnershipRequired(); }

    function _requireActiveParent() internal view {
        if (!registrationEnabled || names.ownerOf(parentId) != address(this)
            || names.resolve(parentId) == address(0)) revert RegistrationClosed();
        (,,, uint64 epoch,) = names.records(parentId);
        if (epoch != parentEpoch) revert RegistrationClosed();
    }
}
