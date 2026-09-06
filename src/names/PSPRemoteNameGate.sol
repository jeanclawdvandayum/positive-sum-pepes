// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {INameEligibility} from "./PSPStakeNameGate.sol";
import {PSPNameRegistrar} from "./PSPNameRegistrar.sol";

/// @title PSPRemoteNameGate
/// @notice An admin-selected signer attests to funded NFT ownership on another
/// chain. This is a trusted fee waiver, not an on-chain cross-chain state proof.
/// The signer cannot mint names, bypass commitments or move the parent domain.
contract PSPRemoteNameGate is INameEligibility, Ownable2Step, EIP712 {
    uint256 public constant GATE_VERSION = 1;
    uint256 public constant MAX_PERMIT_AGE = 180;
    uint256 public immutable sourceChainId;
    address public immutable factory;
    address public signer;
    uint256 public signerEpoch = 1;

    struct Permit {
        address registrar;
        address account;
        bytes32 commitment;
        uint256 nonce;
        uint256 parentEpoch;
        uint256 gateVersion;
        uint256 signerEpoch;
        uint256 roundId;
        uint256 pepeId;
        uint256 sourceBlock;
        bytes32 sourceBlockHash;
        uint256 issuedAt;
        uint256 deadline;
    }

    bytes32 public constant PERMIT_TYPEHASH = keccak256(
        "NamePermit(uint256 sourceChainId,address factory,address registrar,address account,bytes32 commitment,uint256 nonce,uint256 parentEpoch,uint256 gateVersion,uint256 signerEpoch,uint256 roundId,uint256 pepeId,uint256 sourceBlock,bytes32 sourceBlockHash,uint256 issuedAt,uint256 deadline)"
    );
    error InvalidConfiguration();
    error InvalidPermit();
    error KeepRecoveryAdmin();
    event SignerChanged(address indexed signer, uint256 epoch);

    constructor(address admin, address signer_, uint256 sourceChainId_, address factory_)
        Ownable(admin) EIP712("PSPRemoteNameGate", "1")
    {
        // The factory lives remotely: extcodesize here would be meaningless.
        if (signer_ == address(0) || factory_ == address(0) || sourceChainId_ == 0) revert InvalidConfiguration();
        signer = signer_;
        sourceChainId = sourceChainId_;
        factory = factory_;
    }

    /// @notice Rotate/revoke permits immediately. Zero disables fee waivers;
    /// empty-proof paid registrations and parent recovery stay available.
    function setSigner(address next) external onlyOwner {
        signer = next;
        ++signerEpoch;
        emit SignerChanged(next, signerEpoch);
    }

    function renounceOwnership() public override onlyOwner { revert KeepRecoveryAdmin(); }

    /// @notice EIP-712 digest, bound to this gate and destination chain as well
    /// as the immutable source chain/factory and every permit field.
    function permitDigest(Permit memory p) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(PERMIT_TYPEHASH, sourceChainId, factory, p)));
    }

    /// @notice Empty proof explicitly selects the fixed paid path. An invalid
    /// nonempty permit reverts rather than silently changing a free quote.
    function isEligible(address account, bytes calldata proof) external view returns (bool) {
        if (proof.length == 0) return false;
        if (proof.length != 16 * 32) revert InvalidPermit();
        (Permit memory p, uint8 v, bytes32 r, bytes32 s) = abi.decode(proof, (Permit, uint8, bytes32, bytes32));
        if (signer == address(0) || p.signerEpoch != signerEpoch || account == address(0)
            || p.account != account || p.registrar != msg.sender || p.commitment == bytes32(0)
            || p.roundId == 0 || p.sourceBlock == 0 || p.sourceBlockHash == bytes32(0)
            || p.issuedAt > block.timestamp || p.deadline < block.timestamp || p.deadline < p.issuedAt
            || p.deadline - p.issuedAt > MAX_PERMIT_AGE) revert InvalidPermit();
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(permitDigest(p), v, r, s);
        if (err != ECDSA.RecoverError.NoError || recovered != signer) revert InvalidPermit();
        PSPNameRegistrar registrar = PSPNameRegistrar(p.registrar);
        (bytes32 hash,, uint64 epoch, uint256 version) = registrar.commitments(account);
        if (hash != p.commitment || registrar.commitNonce(account) != p.nonce
            || epoch != p.parentEpoch || version != p.gateVersion
            || registrar.parentEpoch() != p.parentEpoch || registrar.gateVersion() != p.gateVersion
            || address(registrar.eligibilityGate()) != address(this)) revert InvalidPermit();
        return true;
    }
}
