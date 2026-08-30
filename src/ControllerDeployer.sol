// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RoundController} from "./RoundController.sol";
import {PSPToken} from "./PSPToken.sol";
import {PSPReferralRegistry} from "./PSPReferralRegistry.sol";
import {StakerDeployer} from "./StakerDeployer.sol";
import {CurveMath} from "./libraries/CurveMath.sol";

/// @title ControllerDeployer — deploys the per-round RoundController
/// @notice EIP-170 companion to HookDeployer: the factory embedding
///         RoundController's creation code on top of everything else
///         pushed it past the 24,576-byte deploy limit. Pure vessel —
///         every argument (including the owning factory) is passed
///         through, nothing is verified here beyond deploy success.
///         PSPToken deployment lives in TokenDeployer (below) since the
///         combined embeds overflowed this contract (2026-08-18).
contract ControllerDeployer {
    error DeployFailed();

    /// @dev EIP-170 shrink (2026-08-19, wave2b): deployController's ABI
    ///      signature is type-for-type identical to RoundController's
    ///      constructor argument list, so the calldata following the
    ///      selector is BYTE-IDENTICAL to the encoded constructor args.
    ///      The body therefore skips Solidity's struct decode + constructor
    ///      re-encode + `new` scaffolding: append the raw calldata to the
    ///      embedded creation program and CREATE directly. Address
    ///      derivation (plain CREATE off the vessel nonce) and the
    ///      external API are unchanged; wrapper runtime shrank ~370B,
    ///      pulling the vessel back under the 24,000 internal budget
    ///      (was 24,152). Creation blob embed unchanged.
        // `payable` (2026-08-20): drops solc's implicit msg.value gate (~10
        // bytes toward the 24,000 budget). Value forwarded to the CREATE
        // endowment can never be lost — RoundController's constructor is
        // non-payable, so an endowment reverts the create and bubbles.
    function deployController(
        PSPToken token,
        IERC20 mixETH,
        CurveMath.CurveConfig calldata config,
        address ownerFactory,
        address descriptor,
        StakerDeployer stakerDeployer
    ) external payable returns (RoundController controller) {
        // EIP-170 shrink (2026-08-19, wave2b): the five params are ABI-
        // decoded on the wire but never touched by the body — the calldata
        // tail after the selector IS the constructor arg blob (signatures
        // are type-for-type identical). Params are `calldata` so solc emits
        // no memory decoder; the body appends raw calldata to the embedded
        // creation program and CREATEs directly.
        bytes memory initCode = type(RoundController).creationCode;
        assembly ("memory-safe") {
            // append calldata (args) after the creation program, patch length
            let len := mload(initCode)
            let n := sub(calldatasize(), 4)
            calldatacopy(add(add(initCode, 0x20), len), 4, n)
            len := add(len, n)
            mstore(initCode, len)
            controller := create(callvalue(), add(initCode, 0x20), len)
        }
        // 2026-08-20: propagate the CONSTRUCTOR's revert verbatim when present
        // (e.g. TimingsIncomplete from a half-packed profile — pinned by
        // TimingProfile.t.sol); DeployFailed() remains the fallback for
        // empty-revert failures (OOG). This matches the old `new` bubbling
        // behavior exactly while keeping the decoded-calldata shrink.
        if (address(controller) == address(0)) {
            assembly ("memory-safe") {
                if returndatasize() {
                    // bubble the constructor's revert verbatim from scratch
                    // space (solc itself reverts no-arg errors from 0x00)
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
            }
            revert DeployFailed();
        }
    }

    // ─────────────── staged spawn (2026-08-30) ───────────────
    // Salted CREATE2 twin of deployController plus pure address prediction,
    // so the factory can know the controller's address (and, through the
    // controller → staker → registry → hook constructor-arg chain, every
    // round contract's address) BEFORE deploying anything. Same raw-calldata
    // trick: the tail after (selector + salt) is byte-identical to the
    // encoded constructor args.

    function deployControllerAt(
        bytes32 salt,
        PSPToken token,
        IERC20 mixETH,
        CurveMath.CurveConfig calldata config,
        address ownerFactory,
        address descriptor,
        StakerDeployer stakerDeployer
    ) external payable returns (RoundController controller) {
        // Re-encode from scratch — NOT the raw-calldata trick: a leading
        // static salt word shifts every dynamic-type head offset by 32,
        // so appending this call's calldata tail verbatim would hand the
        // constructor mis-pointed args (pinned by DebugControllerAt,
        // 2026-08-30). A fresh abi.encode is correct by construction and
        // bit-identical to predictController's initCode hash.
        bytes memory initCode = bytes.concat(
            type(RoundController).creationCode,
            abi.encode(token, mixETH, config, ownerFactory, descriptor, stakerDeployer)
        );
        assembly ("memory-safe") {
            controller := create2(callvalue(), add(initCode, 0x20), mload(initCode), salt)
        }
        if (address(controller) == address(0)) {
            assembly ("memory-safe") {
                if returndatasize() {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
            }
            revert DeployFailed();
        }
    }

    /// @dev NOTE: `config` is declared calldata here but the abi.encode
    ///      below reproduces the exact wire encoding deployControllerAt
    ///      forwards — the standard encoder is used on both sides, so
    ///      predicted == deployed for identical arguments.
    function predictController(
        bytes32 salt,
        PSPToken token,
        IERC20 mixETH,
        CurveMath.CurveConfig calldata config,
        address ownerFactory,
        address descriptor,
        StakerDeployer stakerDeployer
    ) external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(abi.encodePacked(
                type(RoundController).creationCode,
                abi.encode(token, mixETH, config, ownerFactory, descriptor, stakerDeployer)
            ))
        )))));
    }

    // ─────────────── per-round referral registry (moved from HookDeployer,
    //                2026-08-30, for EIP-170 headroom) ───────────────
    // The graph resets at every round boundary — a fresh registry is born
    // beside each hook, keyed by staker position NFT IDs. Fully
    // permissionless since the A-1 fix (2026-08-26): no owner, no
    // authorized recorders — attribution binds only via the user-signed
    // record(); no mining needed — the registry has no permissioned
    // surface worth squatting.

    function deployRegistry(address staker, uint256 minStakePSP)
        external
        returns (address registry)
    {
        registry = address(new PSPReferralRegistry(staker, minStakePSP));
    }

    function deployRegistryAt(bytes32 salt, address staker, uint256 minStakePSP)
        external
        returns (address registry)
    {
        registry = address(new PSPReferralRegistry{salt: salt}(staker, minStakePSP));
    }

    function predictRegistry(bytes32 salt, address staker, uint256 minStakePSP)
        external
        view
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(abi.encodePacked(
                type(PSPReferralRegistry).creationCode,
                abi.encode(staker, minStakePSP)
            ))
        )))));
    }
}

/// @dev Sibling vessel holding ONLY PSPToken's creation code. Split out of
///      ControllerDeployer to stay under EIP-170 once RoundController's
///      creation grew (timing-profile decode). One instance lives in the
///      factory from construction — shared across all rounds (the old
///      fresh-per-round `new TokenDeployer()` cost 1.07M gas of throwaway
///      wrapper per round and made token addresses nonce-derived).
contract TokenDeployer {
    function deployToken(
        string memory name,
        string memory symbol,
        address admin
    ) external returns (PSPToken) {
        return new PSPToken(name, symbol, admin);
    }

    // ─────────────── staged spawn (2026-08-30) ───────────────

    function deployTokenAt(
        bytes32 salt,
        string memory name,
        string memory symbol,
        address admin
    ) external returns (PSPToken token) {
        token = new PSPToken{salt: salt}(name, symbol, admin);
    }

    function predictToken(
        bytes32 salt,
        string memory name,
        string memory symbol,
        address admin
    ) external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(abi.encodePacked(
                type(PSPToken).creationCode,
                abi.encode(name, symbol, admin)
            ))
        )))));
    }
}
