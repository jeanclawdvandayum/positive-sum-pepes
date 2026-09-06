// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IWeiNames} from "../interfaces/IWeiNames.sol";
import {PSPNameCustody} from "./PSPNameCustody.sol";
import {INameEligibility} from "./PSPStakeNameGate.sol";

/// @title PSPNameRegistrar
/// @notice Registers WNS children to their users: free with a qualifying PSP
/// position, otherwise 0.0005 native ETH. Gas is separate in both cases.
/// Registration is not round-scoped; the latest registered/selected name is the
/// wallet's PSP display name, subject to WNS ownership, resolution and expiry.
contract PSPNameRegistrar is PSPNameCustody {
    uint256 public constant REGISTRAR_VERSION = 2;
    uint256 public constant REGISTRATION_FEE = 0.0005 ether;
    uint256 public constant MIN_COMMIT_AGE = 60;
    uint256 public constant MAX_COMMIT_AGE = 1 days;
    INameEligibility public eligibilityGate;
    uint256 public gateVersion = 1;

    struct Commitment { bytes32 hash; uint64 createdAt; uint64 epoch; uint256 gateVersion; }
    mapping(address => Commitment) public commitments;
    // Monotonic even when the same hash is committed twice in one block.
    // Remote fee permits cannot survive consumption or a replacement commit.
    mapping(address => uint256) public commitNonce;
    mapping(address => uint256) public primaryName;

    error InvalidGate();
    error InvalidLabel();
    error InvalidCommitment();
    error CommitmentTooYoung();
    error CommitmentExpired();
    error NameUnavailable();
    error NameOwnershipMismatch();
    error ETHTransferFailed();

    event NameCommitted(address indexed account, bytes32 commitment);
    event NameRegistered(address indexed account, uint256 indexed nameId, string label, uint256 fee);
    event PrimaryNameSelected(address indexed account, uint256 indexed nameId);
    event EligibilityGateChanged(address indexed gate, uint256 version);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor(IWeiNames names_, uint256 parentId_, address admin, INameEligibility gate_)
        PSPNameCustody(names_, parentId_, admin)
    {
        if (address(gate_).code.length == 0) revert InvalidGate();
        eligibilityGate = gate_;
    }

    /// @notice Rotate the eligibility integration. Registration pauses and
    /// pending commitments must be renewed under the new gate configuration.
    function setEligibilityGate(INameEligibility gate) external onlyOwner nonReentrant {
        if (address(gate).code.length == 0) revert InvalidGate();
        eligibilityGate = gate;
        ++gateVersion;
        registrationEnabled = false;
        emit RegistrationEnabled(false, parentEpoch);
        emit EligibilityGateChanged(address(gate), gateVersion);
    }

    /// @notice Compute a private-label commitment, bound to this deployment,
    /// network and wallet. Use a fresh cryptographically random 32-byte salt.
    function makeCommitment(address account, string calldata label, bytes32 salt) public view returns (bytes32) {
        _checkLabel(label);
        return keccak256(abi.encode(address(this), block.chainid, parentId, account, keccak256(bytes(label)), salt));
    }

    /// @notice First step: hide the label before revealing it in the mempool.
    function commit(bytes32 hash) external nonReentrant {
        _requireActiveParent();
        if (hash == bytes32(0)) revert InvalidCommitment();
        ++commitNonce[msg.sender];
        commitments[msg.sender] = Commitment(hash, uint64(block.timestamp), parentEpoch, gateVersion);
        emit NameCommitted(msg.sender, hash);
    }

    /// @notice Price for this wallet and eligibility proof, in native ETH.
    /// Qualification is checked again in register(), at execution time.
    function registrationPrice(address account, bytes calldata proof) public view returns (uint256) {
        return eligibilityGate.isEligible(account, proof) ? 0 : REGISTRATION_FEE;
    }

    /// @notice Reveal after 60 seconds and within 24 hours. The caller receives
    /// their WNS NFT and PSP display mapping in this transaction.
    function register(string calldata label, bytes32 salt, bytes calldata proof)
        external payable nonReentrant returns (uint256 id)
    {
        _requireActiveParent();
        Commitment memory c = commitments[msg.sender];
        if (c.hash != makeCommitment(msg.sender, label, salt) || c.epoch != parentEpoch
            || c.gateVersion != gateVersion) revert InvalidCommitment();
        if (block.timestamp < uint256(c.createdAt) + MIN_COMMIT_AGE) revert CommitmentTooYoung();
        if (block.timestamp > uint256(c.createdAt) + MAX_COMMIT_AGE) revert CommitmentExpired();
        // WNS itself permits the parent owner to overwrite an existing child.
        // Public registrants must never inherit that administrative power.
        if (!names.isAvailable(label, parentId)) revert NameUnavailable();
        uint256 price = registrationPrice(msg.sender, proof);
        if (msg.value != price) revert WrongPayment();
        delete commitments[msg.sender];
        id = names.registerSubdomainFor(label, parentId, msg.sender);
        uint256 expected = uint256(keccak256(abi.encodePacked(bytes32(parentId), keccak256(bytes(label)))));
        // Reject a receiver that transfers/redirects the just-minted NFT during
        // its callback, before recording the wallet's display identity.
        if (id != expected || names.ownerOf(id) != msg.sender || names.resolve(id) != msg.sender) {
            revert NameOwnershipMismatch();
        }
        primaryName[msg.sender] = id;
        emit NameRegistered(msg.sender, id, label, price);
        emit PrimaryNameSelected(msg.sender, id);
    }

    /// @notice Pick another owned child as the PSP display name, or clear it
    /// with id zero. Existing WNS reverse records remain user-controlled.
    function selectPrimaryName(uint256 id) external nonReentrant {
        if (id != 0) {
            (, uint256 parent,,,) = names.records(id);
            if (parent != parentId || names.ownerOf(id) != msg.sender || names.resolve(id) != msg.sender) {
                revert NameOwnershipMismatch();
            }
        }
        primaryName[msg.sender] = id;
        emit PrimaryNameSelected(msg.sender, id);
    }

    /// @notice Withdraw registration revenue and incidental ETH. The registrar
    /// holds no user deposits, PSP backing or staking rewards.
    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        uint256 amount = address(this).balance;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ETHTransferFailed();
        emit FeesWithdrawn(to, amount);
    }

    function _checkLabel(string calldata label) private pure {
        bytes calldata b = bytes(label);
        if (b.length == 0 || b.length > 32 || b[0] == "-" || b[b.length - 1] == "-") revert InvalidLabel();
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (!(c >= "a" && c <= "z") && !(c >= "0" && c <= "9") && c != "-") revert InvalidLabel();
        }
    }
}
