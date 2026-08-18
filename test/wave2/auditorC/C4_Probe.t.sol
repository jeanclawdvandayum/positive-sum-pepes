// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CBase} from "./CBase.sol";
import {PSPFactory} from "../../../src/PSPFactory.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";

/// Determinism probe: pin the exact vessel-nonce mechanics the C-1 prediction
/// relies on (which create increments which nonce, and in what order).
contract C4_Probe is CBase {
    function test_C4_VesselNonceMechanics() public {
        // setUp deployed round 1 through the factory
        uint256 n0 = vm.getNonce(address(controllerDeployer));
        emit log_named_uint("vessel nonce after round 1", n0);

        // token of round 1 must sit at nonce n0-2, controller at n0-1
        assertTrue(address(psp1) == vm.computeCreateAddress(address(controllerDeployer), n0 - 2), "token slot");
        assertTrue(address(controller1) == vm.computeCreateAddress(address(controllerDeployer), n0 - 1), "controller slot");

        // spawn round 2 through the full lifecycle and check both slots again
        _launchRound1();
        _bombRound1();
        _warpPastFlatWindow();
        address predicted = _predictedNextController();
        controller1.finalizeCarpet();

        uint256 n1 = vm.getNonce(address(controllerDeployer));
        emit log_named_uint("vessel nonce after round 2", n1);
        assertEq(n1, n0 + 2, "each round consumes exactly two vessel nonces");
        assertTrue(address(factory.getRound(2).controller) == predicted, "prediction exact");
        assertTrue(address(factory.getRound(2).token) == vm.computeCreateAddress(address(controllerDeployer), n1 - 2), "round-2 token slot");
    }
}
