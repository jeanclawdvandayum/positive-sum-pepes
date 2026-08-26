// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RoundController} from "./RoundController.sol";
import {PSPToken} from "./PSPToken.sol";
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
}

/// @dev Sibling vessel holding ONLY PSPToken's creation code. Split out of
///      ControllerDeployer to stay under EIP-170 once RoundController's
///      creation grew (timing-profile decode). Same trust model: the PSPFactory
///      deploys one per round and passes straight through.
contract TokenDeployer {
    function deployToken(
        string memory name,
        string memory symbol,
        address admin
    ) external returns (PSPToken) {
        return new PSPToken(name, symbol, admin);
    }
}
