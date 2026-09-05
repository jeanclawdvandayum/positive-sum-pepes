// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {SineMath} from "../src/libraries/SineMath.sol";

/// @title SineMathTest — the INDEFINITE tilted-sine curve (2026-09-03)
/// @notice One endless wave past the launch seam: p = B·e^(s·(R−boot)+A·sin),
///         trend anchored so p(targetReserve) = pTarget (on a tread), supply
///         via the decreasing geometric series + one bounded GL8 per call.

/// @dev expectRevert cannot observe reverts from INTERNAL library calls
///      (they fire at the same stack depth as the cheatcode) — route them
///      through an external caller.
contract SineLibCaller {
    function callValidate(SineMath.Params memory p) external pure {
        SineMath.validate(p);
    }

    function callMaterialize(SineMath.Params memory p, uint256 boot) external pure {
        SineMath.materialize(p, boot);
    }
}

contract SineMathTest is Test {
    SineLibCaller caller;
    SineMath.Params p;
    SineMath.Curve c;

    function setUp() public {
        p = SineMath.Params({
            p0: 1e13,                       // 1e-5
            preK: 4_605_170_185_988_092,    // ln(10)/500 → B = 1e-4 at 500 mix
            pTarget: 0.06e18,
            targetReserve: 10_000e18,
            ampBps: 10_000
        });
        c = SineMath.materialize(p, 500e18);
        caller = new SineLibCaller();
    }

    /// The target is a TREAD: price pins to pTarget across ±1 mix.
    function test_TargetTread() public view {
        assertApproxEqRel(SineMath.priceAt(c, 10_000e18), 0.06e18, 1e12, "tread exact");
        assertApproxEqRel(SineMath.priceAt(c, 10_000e18 - 1e18), 0.06e18, 1e12, "tread left");
        assertApproxEqRel(SineMath.priceAt(c, 10_000e18 + 1e18), 0.06e18, 1e12, "tread right");
    }

    /// Monotone everywhere (45° tilt): predeposit ramp + 10 waves sweep.
    function test_PriceMonotone() public view {
        uint256 prev;
        for (uint256 i; i <= 2000; ++i) {
            uint256 R = 40_000e18 * i / 2000;
            uint256 pr = SineMath.priceAt(c, R + 1);
            if (i != 0) assertGe(pr, prev, "price dipped (tilt broken)");
            prev = pr;
        }
    }

    /// Supply is monotone and SATURATES (exponential prices buy less and
    /// less): q(∞) = q0 + W·g/(g−1). NOTE: priceAt overflows expWad beyond
    /// R−boot ≈ 135/s ≈ 200,979 mix — but LIVE TRADES stall far earlier
    /// (buys revert ZeroOutput once a whole-reserve buy mints < 1 wei PSP),
    /// so the deep-tail region is unreachable through the swap path.
    function test_SupplySaturation() public view {
        uint256 qSat = c.q0 + (c.W * c.g) / (c.g - 1e18);
        assertLt(SineMath.supplyAt(c, 40_000e18), qSat, "past saturation?!");
        // monotone supply across the sweep
        assertLt(SineMath.supplyAt(c, 40_000e18), SineMath.supplyAt(c, 45_000e18), "monotone");
    }

    /// Sell round-trip through the far region (the old walk escaped past the
    /// expWad horizon here): reserveAt(supplyAt(R) − 1% of q(R)) converges.
    function test_ReserveAt_DeepSell() public view {
        uint256 R = 10_000e18 + c.lam; // just past the target tread
        uint256 q = SineMath.supplyAt(c, R);
        uint256 pspIn = q / 100; // 1% of everything minted so far
        uint256 Rn = SineMath.reserveAt(c, q - pspIn);
        assertLt(Rn, R, "walked the wrong way");
        assertGt(Rn, c.boot, "clamped to the seam");
        // the sold PSP must equal the supply delta at the returned reserve
        // (relative 1e-12: the integer Newton clamps leave only dust)
        assertApproxEqRel(SineMath.supplyAt(c, Rn), q - pspIn, 1e12, "inversion converged");
    }

    /// reserveAt round-trips supplyAt across a wide grid (incl. the seam,
    /// the target tread, and far past it).
    function test_ReserveAtRoundtrip() public view {
        for (uint256 i = 1; i <= 40; ++i) {
            uint256 R = 30_000e18 * i / 40;
            if (R <= c.boot) continue;
            uint256 q = SineMath.supplyAt(c, R);
            if (q <= c.q0) continue;
            uint256 Rn = SineMath.reserveAt(c, q);
            // within 1e-12 relative (Newton precision, integer clamps)
            assertApproxEqRel(Rn, R, 1e12, "roundtrip drift");
        }
    }

    /// Partition invariance: one bulk buy == the same buy chopped into
    /// pieces (B4j class — endpoint purity must survive the rewrite).
    function test_BuyPartitionInvariance() public view {
        uint256 R = 2_000e18;
        uint256 spend = 300e18;
        uint256 bulk = SineMath.buyOut(c, R, spend);
        uint256 chopped;
        chopped += SineMath.buyOut(c, R, spend / 3);
        chopped += SineMath.buyOut(c, R + spend / 3, spend / 3);
        chopped += SineMath.buyOut(c, R + 2 * (spend / 3), spend - 2 * (spend / 3));
        assertApproxEqRel(chopped, bulk, 1e12, "chopping changed the price");
    }

    /// Sell round-trip: buy then sell the same PSP at the same reserve —
    /// strictly loses (the fee + conservative haircuts).
    function test_RoundTripLoses() public view {
        uint256 R = 1_500e18;
        uint256 out = SineMath.buyOut(c, R, 10e18);
        assertGt(out, 0, "no buy output");
        uint256 back = SineMath.sellOut(c, R + 10e18, out);
        assertLt(back, 10e18, "round trip must lose");
        assertGt(back, 8.5e18, "round trip lost too much");
    }

    /// The 10k target sits on a tread 3 wavelengths out — wave geometry.
    function test_WaveGeometry() public view {
        assertApproxEqAbs(c.lam * 3, 9_500e18, 2, "lam covers seam-to-target");
        assertLe(c.lam * 3, 10_000e18 - 500e18, "tread lands at/inside target");
    }

    /// Validation guards.
    function test_Validate() public {
        SineMath.Params memory bad = p;
        bad.pTarget = 0;
        vm.expectRevert(SineMath.InvalidParams.selector);
        caller.callValidate(bad);
        bad = p;
        bad.targetReserve = 50e18; // below the sanity floor
        vm.expectRevert(SineMath.InvalidParams.selector);
        caller.callValidate(bad);
        bad = p;
        bad.ampBps = 10_001;
        vm.expectRevert(SineMath.InvalidParams.selector);
        caller.callValidate(bad);
    }

    /// Boot past the target cannot anchor (wave would point backwards).
    function test_MaterializeBootBeyondTarget() public {
        vm.expectRevert(SineMath.InvalidParams.selector);
        caller.callMaterialize(p, 20_000e18);
    }

    function test_RejectUnrepresentableCustomCurveBeforeDeposits() public {
        SineMath.Params memory bad = p;
        bad.targetReserve = 1e40; // RS-2: previously accepted, slope became zero
        vm.expectRevert(SineMath.InvalidParams.selector);
        caller.callValidate(bad);
        vm.expectRevert(SineMath.InvalidParams.selector);
        caller.callMaterialize(bad, 90e18);
    }

    function testFuzz_AcceptedCustomDomainLaunchesAndTrades(uint64 seed, uint96 rawBoot, uint16 amp) public pure {
        uint256 price = 10 ** bound(seed % 10, 9, 18);
        uint256 preK = bound(seed, 1e12, 1e16);
        SineMath.Params memory config = SineMath.Params(price, preK, price * 1000,
            bound(uint256(seed) * 1e9, 451e18, 1_000_000e18), uint24(bound(amp, 0, 10_000)));
        SineMath.validate(config);
        uint256 boot = bound(rawBoot, 0.0045e18, 450e18);
        SineMath.Curve memory curve = SineMath.materialize(config, boot);
        assertGt(curve.slope, 0);
        assertGt(curve.g, 1e18);
        uint256 bought = SineMath.buyOut(curve, boot, 0.0045e18);
        assertGt(bought, 0, "minimum net buy is representable");
        assertLe(SineMath.sellOut(curve, boot + 0.0045e18, bought), 0.0045e18);
        uint256 seam = boot + curve.lam;
        assertLe(SineMath.supplyAt(curve, seam - 1), SineMath.supplyAt(curve, seam));
        assertLe(SineMath.supplyAt(curve, seam), SineMath.supplyAt(curve, seam + 1));
    }
}
