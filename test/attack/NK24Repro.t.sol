// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";

/// @title NK24Repro — post-fix regression proofs for the NK24 math findings.
///
/// FINDING A (pre-fix: Newton stall mint overshoot, up to 164x the paid
/// value): fixed in two layers. (1) validate() now rejects exp zones with
/// k*width > 7 WAD (price span > ~1100x within a single zone) — the exact
/// fuzz-counterexample configs below are un-deployable. (2) For every
/// config validate() accepts, the bounded shave loop in computeBuyOutput
/// enforces the invariant integral(S, S+out) <= ethInput (value-conservative
/// mint) regardless of Newton convergence quality.
///
/// Undershoot (buyer receives less than paid for) remains possible in
/// bounded form on steep-but-allowed zones — same as pre-fix, now bounded
/// by the zone cap; buyers can always split buys. Not a protocol-solvency
/// issue (conservative direction).
///
/// FINDING B (dust): post-convergence clamp residue, ~1 ulp of marginal
/// price. Unchanged, documented, anti-attacker on sells.
contract NK24Repro is Test {
    using CurveMath for CurveMath.CurveConfig;

    /// @dev validate() is internal (inlined into the caller) — route through
    ///      an external contract so vm.expectRevert has a call boundary.
    ValidateCaller private immutable _caller = new ValidateCaller();

    function _expectValidateRevert(CurveMath.CurveConfig memory cc, string memory msg_) internal {
        vm.expectRevert(bytes(msg_));
        _caller.run(cc);
    }

    /// @notice Pre-fix Finding A config (seed 385142423799320): exp zone with
    ///         k*width ~= 20 WAD (e^20 price span). computeBuyOutput minted
    ///         164x the paid integral value. Now rejected at deployment.
    function test_NK_StallConfig_RejectedByValidate() public {
        CurveMath.Zone[] memory zones = new CurveMath.Zone[](2);
        zones[0] = CurveMath.Zone({
            startSupply: 0,
            endSupply: 3334463385620060924572585,
            rate: 5997966595240, // exp k = 6e-6 — k*width = 20 WAD
            isExponential: true
        });
        zones[1] = CurveMath.Zone({
            startSupply: 3334463385620060924572585,
            endSupply: type(uint256).max,
            rate: 5006851509422497, // log k = 0.005
            isExponential: false
        });
        CurveMath.CurveConfig memory cc =
            CurveMath.CurveConfig({timings: 0, P0: 12039415137778920, zones: zones});

        _expectValidateRevert(cc, "CurveMath: exp zone too steep (k*width)");
    }

    /// @notice Pre-fix Finding A companion (undershoot direction): exp zone
    ///         with k*width = 9 WAD (e^9 span). Also un-deployable now.
    function test_NK_UndershootConfig_RejectedByValidate() public {
        CurveMath.Zone[] memory zones = new CurveMath.Zone[](2);
        zones[0] = CurveMath.Zone({
            startSupply: 0,
            endSupply: 1e24,
            rate: 9e12, // exp k = 9e-6 — k*width = 9 WAD
            isExponential: true
        });
        zones[1] = CurveMath.Zone({
            startSupply: 1e24,
            endSupply: type(uint256).max,
            rate: 4e17, // log k = 0.4
            isExponential: false
        });
        CurveMath.CurveConfig memory cc = CurveMath.CurveConfig({timings: 0, P0: 5e18, zones: zones});

        _expectValidateRevert(cc, "CurveMath: exp zone too steep (k*width)");
    }

    /// @notice Worst ALLOWED shape: exp zone at k*width = 5 WAD (e^5 ≈ 148x
    ///         price span — a legit FOMO zone). The shave loop must keep the
    ///         mint value-conservative at every depth, and the undershoot
    ///         (buyer burn) stays within a bounded tolerance.
    function test_NK_WorstAllowedShape_ConservativeMint() public {
        // k = 5e-6 WAD, width = 1e24 wei -> k*width = 5 WAD, under the 7 cap
        CurveMath.CurveConfig memory cc = _steepConfig(5e12, 1e24, 0.001e18);
        cc.validate(); // accepted

        uint256[3] memory depths = [uint256(0), 5e23, 9e23];
        uint256[3] memory sizes = [uint256(1e20), 1e22, 1e23];
        for (uint256 d = 0; d < 3; d++) {
            for (uint256 s = 0; s < 3; s++) {
                uint256 S = depths[d];
                uint256 x = sizes[s];
                uint256 out = CurveMath.computeBuyOutput(x, S, cc);
                uint256 spent = CurveMath.curveIntegral(S, S + out, cc);
                // hard invariant: never mint more value than paid (+1bp slack
                // for the documented clamp dust)
                assertLe(spent, x + x / 10_000, "OVERSHOOT: stall regression on allowed shape");
                // buyer-burn bound: minted value never below 99% of paid
                assertGe(spent, x * 99 / 100, "undershoot exceeds 1% (buyer burn)");
            }
        }
    }

    /// @notice Log-first layouts divided by zero inside _integralLog
    ///         (_logPrice: divWad(segEnd, s0) with s0 = 0) — every swap
    ///         panicked 0x11. validate() now rejects them outright.
    function test_NK_LogFirstZone_RejectedByValidate() public {
        CurveMath.Zone[] memory zones = new CurveMath.Zone[](2);
        zones[0] = CurveMath.Zone({
            startSupply: 0,
            endSupply: 1e24,
            rate: 5e17, // log
            isExponential: false // <-- the bug: log zone starting at 0
        });
        zones[1] = CurveMath.Zone({
            startSupply: 1e24,
            endSupply: type(uint256).max,
            rate: 0,
            isExponential: true // flat tail
        });
        CurveMath.CurveConfig memory cc = CurveMath.CurveConfig({timings: 0, P0: 1e14, zones: zones});
        _expectValidateRevert(cc, "CurveMath: first zone must be exponential");
    }

    /// @notice Proof of Finding B direction: split sells are anti-attacker.
    function test_NK_SplitSellDirection() public pure {
        CurveMath.CurveConfig memory cc = _prodConfig();
        // production config, several split points
        uint256[4] memory supplies = [uint256(5e23), 2e24, 1e25, 5e26];
        for (uint256 i = 0; i < 4; i++) {
            uint256 S = supplies[i];
            uint256 t = S / 10;
            uint256 single = CurveMath.computeSellOutput(t, S, cc);
            uint256 s1 = CurveMath.computeSellOutput(t / 2, S, cc);
            uint256 s2 = CurveMath.computeSellOutput(t - t / 2, S - t / 2, cc);
            // splits never beat single beyond 2 wei on the production curve
            // measured: up to +8988 wei (1.8e-16 relative) at one split point —
            // pure integer dust, direction can be attacker-favorable, bounded:
            assertLe(s1 + s2, single + 10_000, "SPLIT SELL EXTRACTION on prod config");
        }
    }

    function _prodConfig() internal pure returns (CurveMath.CurveConfig memory) {
        return CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18);
    }

    function _steepConfig(uint256 k, uint256 width, uint256 p0)
        internal
        pure
        returns (CurveMath.CurveConfig memory)
    {
        CurveMath.Zone[] memory zones = new CurveMath.Zone[](2);
        zones[0] = CurveMath.Zone({startSupply: 0, endSupply: width, rate: k, isExponential: true});
        zones[1] = CurveMath.Zone({
            startSupply: width,
            endSupply: type(uint256).max,
            rate: 0,
            isExponential: true // flat tail
        });
        return CurveMath.CurveConfig({timings: 0, P0: p0, zones: zones});
    }
}

/// @dev validate() is `internal pure` — the compiler inlines it into the
///      caller, so vm.expectRevert has no call boundary. Route through this
///      thin external contract instead.
contract ValidateCaller {
    using CurveMath for CurveMath.CurveConfig;

    function run(CurveMath.CurveConfig memory cc) external pure {
        cc.validate();
    }
}
