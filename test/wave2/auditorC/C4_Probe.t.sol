// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CBase} from "./CBase.sol";
import {PSPFactory} from "../../../src/PSPFactory.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";

/// Determinism probe: pin the exact vessel-nonce mechanics the C-1 prediction
/// relies on (which create increments which nonce, and in what order).
///
/// POST-SPLIT (2026-08-18) topology — EIP-170 TokenDeployer split:
///   vessel  : deploys ONLY the RoundController (one nonce per round)
///   factory : one plain CREATE per round — a fresh TokenDeployer
///   token   : first CREATE of that round's TokenDeployer (nonce 1)
/// The controller prediction is unchanged in strength: (vessel, next-nonce)
/// is public. The token gains one indirection hop (factory nonce →
/// TokenDeployer address → its nonce 1), equally computable off-chain.
contract C4_Probe is CBase {
    function test_C4_VesselNonceMechanics() public {
        // setUp deployed round 1 through the factory
        uint256 n0 = vm.getNonce(address(controllerDeployer));
        emit log_named_uint("vessel nonce after round 1", n0);

        // controller of round 1 sits at the vessel's previous nonce
        assertTrue(address(controller1) == vm.computeCreateAddress(address(controllerDeployer), n0 - 1), "controller slot");

        // token of round 1 rode the factory's TokenDeployer CREATE
        uint256 f0 = vm.getNonce(address(factory));
        address round1TokenDeployer = vm.computeCreateAddress(address(factory), f0 - 1);
        assertTrue(address(psp1) == vm.computeCreateAddress(round1TokenDeployer, 1), "token via per-round TokenDeployer");

        // spawn round 2 through the full lifecycle and check both slots again
        _launchRound1();
        _bombRound1();
        _warpPastFlatWindow();
        address predicted = _predictedNextController();
        controller1.finalizeCarpet();

        uint256 n1 = vm.getNonce(address(controllerDeployer));
        emit log_named_uint("vessel nonce after round 2", n1);
        assertEq(n1, n0 + 1, "one vessel nonce per round (controller)");
        assertTrue(address(factory.getRound(2).controller) == predicted, "prediction exact");

        uint256 f1 = vm.getNonce(address(factory));
        address round2TokenDeployer = vm.computeCreateAddress(address(factory), f1 - 1);
        assertTrue(
            address(factory.getRound(2).token) == vm.computeCreateAddress(round2TokenDeployer, 1),
            "round-2 token via fresh TokenDeployer"
        );
    }
}
