// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RoundController} from "./RoundController.sol";
import {PSPToken} from "./PSPToken.sol";
import {CurveMath} from "./libraries/CurveMath.sol";

/// @title ControllerDeployer — deploys the per-round RoundController + PSPToken
/// @notice EIP-170 companion to HookDeployer: the factory embedding
///         RoundController's (~14KB) and PSPToken's (~3.5KB) creation code on
///         top of everything else pushed it past the 24,576-byte deploy limit.
///         Pure vessel — every argument (including the owning factory) is
///         passed through, nothing is verified here beyond deploy success.
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

    function deployToken(
        string memory name,
        string memory symbol,
        address admin
    ) external returns (PSPToken) {
        return new PSPToken(name, symbol, admin);
    }
}
