// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RoundController} from "./RoundController.sol";
import {PSPToken} from "./PSPToken.sol";
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

    function deployController(
        PSPToken token,
        IERC20 mixETH,
        CurveMath.CurveConfig memory config,
        address ownerFactory
    ) external returns (RoundController) {
        return new RoundController(token, mixETH, config, ownerFactory);
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
