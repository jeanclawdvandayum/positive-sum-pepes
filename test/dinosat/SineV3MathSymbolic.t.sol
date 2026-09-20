// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SineV3Math} from "../../src/SineV3Math.sol";
import {SineV3Data} from "../../src/SineV3Data.sol";

/// @title DinoSAT symbolic tests — SineV3Math settlement surface
/// @notice Domain fail-closedness, the lamAt floored-sqrt identity, and
///         the buyOut conservation bound at the canonical fixture row.
contract SineV3MathSymbolicTest is Test, SineV3Math {
    uint256 constant BOOT = 450e18;
    uint256 constant LAM = 955e18;
    uint256 constant PL = 75e12; // default launch price (WAD)

    constructor() SineV3Math(SineV3Data.deploy()) {}

    // ════════════════════════════════════════════════
    // DM-1 (lamAt is the floored sqrt): lam^2 <= LAM_REF^2*boot/B_REF
    // < (lam+1)^2 at enumerated boots. Inline product: LAM_REF^2*boot
    // <= 9.12e38 * 6.82e26 = 6.2e65 < uint256 max (1.16e77). Fits.
    // Technique: T4 inline + T3 enumerate. Classification: INLINE.
    // ════════════════════════════════════════════════

    function test_check_lamat_floorsqrt_boot450() public pure {
        uint256 boot = 450e18;
        uint256 lam = SineV3Math.lamAt(boot);
        uint256 scaled = 955e18 * 955e18 * boot / 450e18; // fits: 9.12e38*4.5e20
        assert(lam * lam <= scaled && scaled < (lam + 1) * (lam + 1));
    }

    function test_check_lamat_floorsqrt_boot90() public pure {
        uint256 boot = 90e18;
        uint256 lam = SineV3Math.lamAt(boot);
        uint256 scaled = 955e18 * 955e18 * boot / 450e18;
        assert(lam * lam <= scaled && scaled < (lam + 1) * (lam + 1));
    }

    function test_check_lamat_floorsqrt_boot600k() public pure {
        uint256 boot = 600_000e18;
        uint256 lam = SineV3Math.lamAt(boot);
        uint256 scaled = 955e18 * 955e18 * boot / 450e18; // 6.1e44, fits
        assert(lam * lam <= scaled && scaled < (lam + 1) * (lam + 1));
    }

    // ════════════════════════════════════════════════
    // DM-2 (domain fail-closed): beyond boot + POST_WAVES*lam the
    // settlement surface reverts. try/catch pattern (expectRevert is
    // unsupported in halmos). Technique: T3 concrete; Classification: DIRECT.
    // ════════════════════════════════════════════════

    /// @notice maxReserve is the boundary; priceWad one past it reverts.
    function test_check_domain_rejects_above_max() public {
        uint256 maxR = BOOT + POST_WAVES * LAM;
        try this.priceWad(maxR + 1, BOOT, LAM, PL) {
            assert(false);
        } catch {
            assert(true);
        }
    }

    /// @notice The boundary itself is admitted (off-by-one guard check).
    function test_check_domain_admits_boundary() public {
        uint256 maxR = BOOT + POST_WAVES * LAM;
        try this.priceWad(maxR, BOOT, LAM, PL) {
            assert(true);
        } catch {
            assert(false);
        }
    }

    /// @notice Bad pL (outside [1e9, 1e18]) is rejected.
    function test_check_domain_rejects_bad_pl() public {
        try this.priceWad(BOOT, BOOT, LAM, 1e18 + 1) {
            assert(false);
        } catch {
            assert(true);
        }
    }

    // ════════════════════════════════════════════════
    // DM-3 (buyOut conservation at the canonical row): for buys confined
    // to the zero-anchored cell [boot, boot + lam/2), out never exceeds
    // the starting-spot bound (spend / price(boot)), and the supply delta
    // is non-negative. spotBound inline: spend*WAD/PL with spend < 1e24,
    // WAD=1e18 -> product 1e42 fits. price(boot) = scaledExp(0, PL) = PL.
    // Technique: T2 boundary (R fixed at the cell edge — the price there
    // is concrete and minimal on the segment, so the spot bound is the
    // loosest/worst case). Classification: BOUNDARY + INLINE.
    // ════════════════════════════════════════════════

    /// @notice out <= spend * WAD / PL (no free PSP above spot).
    function test_check_buyout_spot_bound(uint112 spend) public view {
        // Justification: buys confined to cell 711: width = 2*lam/4 = 477.5e18
        vm.assume(spend >= 1 && spend < 477e18);
        uint256 out = this.buyOut(BOOT, BOOT, LAM, PL, spend);
        // 2026-09-18 adjudication: the assert math must widen to uint256 —
        // `spend * 1e18` in uint112 overflows above ~5.2e15 (fuzz-tier panic 0x11
        // at spend=2.0497e19 was in the TEST arithmetic, not the contract:
        // direct probe returns out=273259989976651329931848, bound holds).
        assert(out <= uint256(spend) * 1e18 / PL);
    }

    /// @notice Supply never decreases across a buy (monotone primitive).
    function test_check_buyout_supply_monotone(uint112 spend) public view {
        vm.assume(spend >= 1 && spend < 477e18);
        uint256 q0 = this.supplyWad(BOOT, BOOT, LAM, PL);
        uint256 q1 = this.supplyWad(BOOT + spend, BOOT, LAM, PL);
        assert(q1 >= q0);
    }

    // ════════════════════════════════════════════════
    // FUZZ WRAPPERS (T17)
    // ════════════════════════════════════════════════

    function test_fuzz_buyout_spot_bound(uint256 raw) public view {
        uint256 spend = bound(raw, 1, 477e18 - 1);
        uint256 out = this.buyOut(BOOT, BOOT, LAM, PL, spend);
        assert(out <= spend * 1e18 / PL);
    }

    function test_fuzz_buyout_supply_monotone(uint256 raw) public view {
        uint256 spend = bound(raw, 1, 477e18 - 1);
        uint256 q0 = this.supplyWad(BOOT, BOOT, LAM, PL);
        uint256 q1 = this.supplyWad(BOOT + spend, BOOT, LAM, PL);
        assert(q1 >= q0);
    }
}
