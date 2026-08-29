// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {SineMath} from "src/libraries/SineMath.sol";
import {FixedPointMathLib as FPML} from "solady/src/utils/FixedPointMathLib.sol";

/// @dev Hypothetical "eternal 45° sine" (scoopy 2026-08-29): same predeposit
///      leg (cannot vanish — the wave anchors to the ACTUAL raise at launch),
///      same wave formula extended forever, NO linear tail. Prefix integrals
///      beyond cp[12] are recomputed on the fly (pure — no new storage).
library EternalMath {
    error ExpOverflow();

    uint256 internal constant WAD = 1e18;
    uint256 internal constant PI_WAD = 3141592653589793238;
    uint256 internal constant TWO_PI_WAD = 6283185307179586476;
    int256 internal constant MAX_EXP_ARG = 135305999368893231588;

    // GL8 nodes/weights (mirror of SineMath — constants are free in bytecode)
    uint256 internal constant GL8_U0 = 19855071751231912;
    uint256 internal constant GL8_U1 = 101666761293186640;
    uint256 internal constant GL8_U2 = 237233795041835520;
    uint256 internal constant GL8_U3 = 408282678752175040;
    uint256 internal constant GL8_U4 = 591717321247824896;
    uint256 internal constant GL8_U5 = 762766204958164480;
    uint256 internal constant GL8_U6 = 898333238706813312;
    uint256 internal constant GL8_U7 = 980144928248768128;
    uint256 internal constant GL8_W0 = 50614268145188264;
    uint256 internal constant GL8_W1 = 111190517226687232;
    uint256 internal constant GL8_W2 = 156853322938943584;
    uint256 internal constant GL8_W3 = 181341891689180896;

    function priceAt(SineMath.Curve memory c, uint256 R) internal pure returns (uint256) {
        if (R <= c.boot) {
            return FPML.mulWad(c.p0, uint256(FPML.expWad(int256(FPML.mulWad(c.preK, R)))));
        }
        // wave formula, unbounded R — no tail branch
        uint256 u = (R - c.boot) % c.lam;
        int256 sinv = SineMath._sinWad(PI_WAD + FPML.mulWad(u, FPML.divWad(TWO_PI_WAD, c.lam)));
        int256 ampTerm = sinv < 0
            ? -int256(FPML.mulWad(c.amp, uint256(-sinv)))
            : int256(FPML.mulWad(c.amp, uint256(sinv)));
        int256 arg = int256(FPML.mulWad(c.slope, R - c.boot)) + ampTerm;
        if (arg > MAX_EXP_ARG) revert ExpOverflow();
        return FPML.mulWad(c.B, uint256(FPML.expWad(arg)));
    }

    function supplyAt(SineMath.Curve memory c, uint256 R) internal pure returns (uint256) {
        if (R <= c.boot) {
            uint256 expNeg = uint256(FPML.expWad(-int256(FPML.mulWad(c.preK, R))));
            return FPML.divWad(WAD - expNeg, FPML.mulWad(c.preK, c.p0));
        }
        uint256 j = (R - c.boot) / c.segWidth; // unbounded
        uint256 prefix;
        if (j <= 12) {
            prefix = c.cp[j]; // precomputed at materialize (still needed!)
        } else {
            // no stored checkpoints exist beyond the designed waves —
            // recompute every quarter-wave segment from 12 to j, every call
            prefix = c.cp[12];
            for (uint256 k = 12; k < j; k++) {
                prefix += _gl8(c, c.boot + k * c.segWidth, c.boot + (k + 1) * c.segWidth);
            }
        }
        return c.q0 + prefix + _gl8(c, c.boot + j * c.segWidth, R);
    }

    function reserveAt(SineMath.Curve memory c, uint256 qTarget) internal pure returns (uint256) {
        if (qTarget <= c.q0) {
            uint256 x = FPML.mulWad(FPML.mulWad(qTarget, c.preK), c.p0);
            if (x >= WAD) return c.boot;
            return FPML.divWad(uint256(-FPML.lnWad(int256(WAD - x))), c.preK);
        }
        uint256 local = qTarget - c.q0;
        uint256 j = 0;
        uint256 prefix = 0;
        if (local < c.cp[12]) {
            for (uint256 k = 1; k < 12; k++) {
                if (c.cp[k] < local) j = k; else break;
            }
            prefix = c.cp[j];
        } else {
            // extend segment by segment until the target is covered
            j = 12;
            prefix = c.cp[12];
            uint256 guard = 0;
            while (guard < 5000) {
                uint256 segSup = _gl8(c, c.boot + j * c.segWidth, c.boot + (j + 1) * c.segWidth);
                if (segSup == 0 || prefix + segSup >= local) break;
                prefix += segSup;
                j += 1;
                guard += 1;
            }
        }
        uint256 a = c.boot + j * c.segWidth;
        uint256 L = local - prefix;
        uint256 segEnd = _gl8(c, a, a + c.segWidth);
        uint256 R = a + FPML.mulWad(c.segWidth, FPML.divWad(L, segEnd == 0 ? 1 : segEnd));
        for (uint256 it = 0; it < 8; it++) {
            uint256 have = _gl8(c, a, R);
            if (have == L) break;
            int256 step = int256(FPML.mulWad(L > have ? L - have : have - L, priceAt(c, R)));
            if (L > have) R += uint256(step);
            else R = R > uint256(step) ? R - uint256(step) : a;
        }
        uint256 guard2 = 0;
        while (_gl8(c, a, R) > L && guard2 < 256) {
            R -= 1;
            guard2 += 1;
        }
        return R;
    }

    function buyOut(SineMath.Curve memory c, uint256 R, uint256 spend) internal pure returns (uint256) {
        uint256 out = supplyAt(c, R + spend) - supplyAt(c, R);
        if (out <= 1) return 0;
        out -= 1;
        return out * 9999 / 10000;
    }

    function sellOut(SineMath.Curve memory c, uint256 R, uint256 pspIn) internal pure returns (uint256) {
        uint256 qNow = supplyAt(c, R);
        if (pspIn >= qNow) return R;
        uint256 Rn = reserveAt(c, qNow - pspIn);
        return R - Rn;
    }

    function _gl8(SineMath.Curve memory c, uint256 a, uint256 b) internal pure returns (uint256) {
        if (b <= a) return 0;
        uint256 w = b - a;
        uint256 acc = FPML.mulWad(GL8_W0, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U0))))
            + FPML.mulWad(GL8_W1, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U1))))
            + FPML.mulWad(GL8_W2, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U2))))
            + FPML.mulWad(GL8_W3, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U3))))
            + FPML.mulWad(GL8_W3, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U4))))
            + FPML.mulWad(GL8_W2, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U5))))
            + FPML.mulWad(GL8_W1, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U6))))
            + FPML.mulWad(GL8_W0, FPML.divWad(WAD, priceAt(c, a + FPML.mulWad(w, GL8_U7))));
        return FPML.mulWad(w, acc);
    }
}

/// @dev Identical external surface for bytecode-size comparison.
contract WrapCurrent {
    function price(SineMath.Curve memory c, uint256 r) external pure returns (uint256) {
        return SineMath.priceAt(c, r);
    }
    function supply(SineMath.Curve memory c, uint256 r) external pure returns (uint256) {
        return SineMath.supplyAt(c, r);
    }
    function reserve(SineMath.Curve memory c, uint256 q) external pure returns (uint256) {
        return SineMath.reserveAt(c, q);
    }
    function buy(SineMath.Curve memory c, uint256 r, uint256 s) external pure returns (uint256) {
        return SineMath.buyOut(c, r, s);
    }
    function sell(SineMath.Curve memory c, uint256 r, uint256 p) external pure returns (uint256) {
        return SineMath.sellOut(c, r, p);
    }
}

contract WrapEternal {
    function price(SineMath.Curve memory c, uint256 r) external pure returns (uint256) {
        return EternalMath.priceAt(c, r);
    }
    function supply(SineMath.Curve memory c, uint256 r) external pure returns (uint256) {
        return EternalMath.supplyAt(c, r);
    }
    function reserve(SineMath.Curve memory c, uint256 q) external pure returns (uint256) {
        return EternalMath.reserveAt(c, q);
    }
    function buy(SineMath.Curve memory c, uint256 r, uint256 s) external pure returns (uint256) {
        return EternalMath.buyOut(c, r, s);
    }
    function sell(SineMath.Curve memory c, uint256 r, uint256 p) external pure returns (uint256) {
        return EternalMath.sellOut(c, r, p);
    }
}

/// @dev Gas race: current 3-leg curve vs the hypothetical eternal wave.
contract SineEternalBench is Test {
    // deployment-shaped params: boot 500 mix, span 6000 (12 segments), top at 6500
    SineMath.Curve c;

    function setUp() public {
        SineMath.Params memory p = SineMath.Params({
            p0: 1e10,                       // predeposit start price
            preK: 18420680743952368,        // e^(preK·500) = 1e4 → B = 1e14 (launch 0.0001)
            magM: 12e18,                    // span = 12 × boot
            lnTop: 6396929655216456000,     // ln(600) → pTop = 0.06
            ampBps: 10000                   // 45°
        });
        c = SineMath.materialize(p, 500e18);
    }

    /// @dev shims reproduce the wave formula exactly — must match SineMath
    ///      bit-for-bit inside the designed region.
    function test_shims_match_in_wave_region() public view {
        uint256[4] memory rs = [uint256(250e18), uint256(3500e18), uint256(5000e18), uint256(6499e18)];
        for (uint256 i = 0; i < rs.length; i++) {
            assertEq(EternalMath.priceAt(c, rs[i]), SineMath.priceAt(c, rs[i]), "priceAt mismatch");
            assertEq(EternalMath.supplyAt(c, rs[i]), SineMath.supplyAt(c, rs[i]), "supplyAt mismatch");
        }
    }

    function test_gas_priceAt() public view {
        uint256 g0;
        uint256 v;
        g0 = gasleft(); v = SineMath.priceAt(c, 250e18); console2.log("priceAt current  predeposit :", g0 - gasleft()); v;
        g0 = gasleft(); v = SineMath.priceAt(c, 3500e18); console2.log("priceAt current  wave       :", g0 - gasleft()); v;
        g0 = gasleft(); v = SineMath.priceAt(c, 21500e18); console2.log("priceAt current  tail +30seg:", g0 - gasleft()); v;
        g0 = gasleft(); v = EternalMath.priceAt(c, 21500e18); console2.log("priceAt eternal  tail +30seg:", g0 - gasleft()); v;
    }

    function test_gas_buyOut() public view {
        uint256 g0;
        uint256 v;
        uint256 spend = 100e18;
        g0 = gasleft(); v = SineMath.buyOut(c, 3500e18, spend); console2.log("buy current  wave           :", g0 - gasleft()); v;
        g0 = gasleft(); v = SineMath.buyOut(c, 7000e18, spend); console2.log("buy current  tail +1seg     :", g0 - gasleft()); v;
        g0 = gasleft(); v = SineMath.buyOut(c, 21500e18, spend); console2.log("buy current  tail +30seg    :", g0 - gasleft()); v;
        g0 = gasleft(); v = SineMath.buyOut(c, 36500e18, spend); console2.log("buy current  tail +60seg    :", g0 - gasleft()); v;
        g0 = gasleft(); v = EternalMath.buyOut(c, 7000e18, spend); console2.log("buy eternal  +1seg past top :", g0 - gasleft()); v;
        g0 = gasleft(); v = EternalMath.buyOut(c, 9000e18, spend); console2.log("buy eternal  +5seg          :", g0 - gasleft()); v;
        g0 = gasleft(); v = EternalMath.buyOut(c, 21500e18, spend); console2.log("buy eternal  +30seg         :", g0 - gasleft()); v;
        g0 = gasleft(); v = EternalMath.buyOut(c, 36500e18, spend); console2.log("buy eternal  +60seg         :", g0 - gasleft()); v;
    }

    function test_gas_sellOut() public view {
        uint256 g0;
        uint256 v;
        // sell sizes chosen so reserve moves back ~100 mix at each point
        uint256 psp1 = SineMath.supplyAt(c, 9000e18) - SineMath.supplyAt(c, 8900e18);
        uint256 psp30 = SineMath.supplyAt(c, 21500e18) - SineMath.supplyAt(c, 21400e18);
        g0 = gasleft(); v = SineMath.sellOut(c, 9000e18, psp1); console2.log("sell current tail +1seg     :", g0 - gasleft()); v;
        g0 = gasleft(); v = SineMath.sellOut(c, 21500e18, psp30); console2.log("sell current tail +30seg    :", g0 - gasleft()); v;
        uint256 eps1 = EternalMath.supplyAt(c, 9000e18) - EternalMath.supplyAt(c, 8900e18);
        uint256 eps30 = EternalMath.supplyAt(c, 21500e18) - EternalMath.supplyAt(c, 21400e18);
        g0 = gasleft(); v = EternalMath.sellOut(c, 9000e18, eps1); console2.log("sell eternal +5seg          :", g0 - gasleft()); v;
        g0 = gasleft(); v = EternalMath.sellOut(c, 21500e18, eps30); console2.log("sell eternal +30seg         :", g0 - gasleft()); v;
    }

    /// @dev the supply ceiling: beyond the designed waves the eternal wave's
    ///      exponential trend makes ∫dR/p CONVERGE — total mintable supply
    ///      past the top approaches a finite limit. (+40 vs +200 segments:
    ///      eternal has already flatlined; the tail keeps issuing.)
    function test_eternal_supply_ceiling() public view {
        uint256 qTop = EternalMath.supplyAt(c, 6500e18);
        uint256 q40 = EternalMath.supplyAt(c, 26500e18);   // +40 segments
        uint256 q80 = EternalMath.supplyAt(c, 46500e18);   // +80 segments
        console2.log("eternal supply @ top        (PSP):", qTop / 1e18);
        console2.log("eternal supply @ top+40seg  (PSP):", q40 / 1e18);
        console2.log("eternal supply @ top+80seg  (PSP):", q80 / 1e18);
        console2.log("eternal ceiling gain beyond +40seg:", (q80 - q40) / 1e18, "PSP");
        console2.log("current tail supply @ +40seg      :", SineMath.supplyAt(c, 26500e18) / 1e18);
        console2.log("current tail supply @ +80seg     :", SineMath.supplyAt(c, 46500e18) / 1e18);
    }

    /// @dev heat death: expWad's domain caps the wave's argument — beyond
    ///      ~135 in ln-units the eternal wave cannot produce a price at all.
    ///      (routed through WrapEternal so the revert happens at call depth)
    function test_eternal_heat_death() public {
        WrapEternal w = new WrapEternal();
        vm.expectRevert(EternalMath.ExpOverflow.selector);
        w.price(c, c.boot + 130_000e18);
    }
}
