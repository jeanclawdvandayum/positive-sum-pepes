// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {GameRules} from "../../src/libraries/GameRules.sol";
import {IRoundController} from "../../src/interfaces/IRoundController.sol";
import {PSPReferralRegistry} from "../../src/PSPReferralRegistry.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookRulesRuntime} from "./HookRulesRuntime.sol";

/// @title Storage setup for proofs of unmodified production hook functions
/// @notice These setters exist only in this test contract. They establish the
/// state read by the properties; they do not model deposits or prove reachability.
contract HookRulesHarness is CurveHook {
    constructor(CurveMath.CurveConfig memory config)
        CurveHook(IPoolManager(address(0x1111)), IRoundController(address(0xC0FFEE)),
            PSPReferralRegistry(address(0x2222)), config, address(0x3333)) {}

    function setupTickets(uint256 pot, uint256 genesisPot, bool initialized, bool configured) external {
        potBalance = pot;
        genesisPotBalance = genesisPot;
        poolInitialized = initialized;
        sineConfigured = configured;
    }

    function setupMode(Mode initialMode) external { mode = initialMode; }
}

/// @title Fixed-address deployer for reproducible test-only CREATE2 setup
contract HookRulesTestDeployer {
    function deploy(CurveMath.CurveConfig memory config, bytes32 salt) external returns (HookRulesHarness) {
        return new HookRulesHarness{salt: salt}(config);
    }
}

/// @title Direct production ticket and access-control properties
/// @notice The uint256 ticket properties include values above feasible token
/// supply. Controller/manager/registry addresses are fixed noncalling stubs.
/// These proofs cover getters and the first setMode authorization guard only;
/// they do not prove settlement, token backing, or authorized transitions.
contract HookRulesSymbolicTest is Test {
    HookRulesHarness internal hook;

    function setUp() public {
        // Halmos 0.3.3 models CREATE2 hashes with synthetic addresses whose
        // flags cannot satisfy BaseHook. Etch the exact runtime instead.
        // test_fixture_matches_constructor proves byte identity in Forge;
        // constructor/address mining are explicitly outside the symbolic proof.
        address target = address(0x12a88);
        vm.etch(target, HookRulesRuntime.code());
        hook = HookRulesHarness(target);
    }

    function _deployRealHook() internal returns (HookRulesHarness) {
        CurveMath.CurveConfig memory config;
        config.zones = new CurveMath.Zone[](0);
        address deployer = address(0xF00D);
        vm.etch(deployer, type(HookRulesTestDeployer).runtimeCode);
        bytes32 initHash = keccak256(abi.encodePacked(type(HookRulesHarness).creationCode, abi.encode(config)));
        // BaseHook validates real address flags and does not permit an override.
        // Salt mined with solc 0.8.26, optimizer 200, via IR, Cancun. Changes to
        // initcode require mining a new salt; fail here rather than bypassing
        // production address validation. No mining loop runs in the proof.
        uint256 salt = 24_570;
        address candidate = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), deployer, bytes32(salt), initHash
        )))));
        assert((uint160(candidate) & 0x3fff) == 0x2a88);
        return HookRulesTestDeployer(deployer).deploy(config, bytes32(salt));
    }

    /// @notice Forge-only bridge from the compiled constructor to the runtime
    /// used by the symbolic proof. A stale fixture must fail this check.
    function test_fixture_matches_constructor() public {
        HookRulesHarness actual = _deployRealHook();
        assertEq(address(actual).code, HookRulesRuntime.code());
        assertEq(address(actual.controller()), address(0xC0FFEE));
        assertEq(address(actual.poolManager()), address(0x1111));
        assertEq(address(actual.referralRegistry()), address(0x2222));
        assertEq(actual.deployerCutTo(), address(0x3333));
        assertEq(actual.detWindow(), 248_660);
    }

    /// @notice Export the real runtime before regenerating the Solidity fixture.
    /// Writes only a build artifact; scripts/formal/generate_hook_fixture.py
    /// checks the compiler template and every immutable before accepting it.
    function test_export_runtime_fixture() public {
        HookRulesHarness actual = _deployRealHook();
        vm.writeFile("out/hook-rules-runtime.hex", vm.toString(address(actual).code));
    }

    /// @notice The returned spot is the unique positive integer whose
    /// 10,000-wide bucket contains the pot. No ceiling-division copy is used.
    /// @dev 2026-09-22 solver note: `pot - lower <= 10_000` compiles (via-IR,
    ///      solc 0.8.26) into a comparison lowered through a DIVISION WITH A
    ///      SYMBOLIC DIVISOR — SMT-intractable for z3, z3-parallel, bitwuzla
    ///      and cvc5 alike at 300-1800s/query (receipts: campaign logs). The
    ///      addition form `pot <= lower + 10_000` lowers additively but can
    ///      wrap for the top ~10,000 pots; those are excluded here and pinned
    ///      exhaustively by test_ticket_interval_top_region below.
    function check_ticket_interval(uint256 pot, uint256 unrelatedGenesisPot) public {
        hook.setupTickets(pot, unrelatedGenesisPot, true, true);
        uint256 q = hook.ticketPrice();
        assert(q >= 1);
        assert(q <= type(uint256).max / 10_000 + 1);
        assert(hook.MIN_BUY_INPUT() == q);
        if (pot == 0) {
            assert(q == 1);
        } else {
            // The preceding bound makes this multiplication safe, including
            // pot == type(uint256).max; q * 10,000 need not fit.
            uint256 lower = (q - 1) * 10_000;
            assert(lower < pot);
            // unchecked: the wrapping addition is the defined bitvector
            // semantics; outside the top 10,000 pots no wrap occurs and this
            // is the exact bucket ceiling.
            bool inBucket;
            unchecked { inBucket = pot <= lower + 10_000; }
            assert(inBucket || pot > type(uint256).max - 10_000);
        }
    }

    /// @notice Every active sine pot has a positive minimum equal to one spot.
    function check_active_minimum_positive(uint256 pot) public {
        hook.setupTickets(pot, 0, true, true);
        uint256 price = hook.ticketPrice();
        assert(price > 0);
        assert(hook.MIN_BUY_INPUT() == price);
    }

    /// @notice Genesis pot changes cannot alter active whole-pot ticket cost.
    function check_ticket_genesis_independent(uint256 pot, uint256 genesisA, uint256 genesisB) public {
        hook.setupTickets(pot, genesisA, true, true);
        uint256 price = hook.ticketPrice();
        hook.setupTickets(pot, genesisB, true, true);
        assert(hook.ticketPrice() == price);
    }

    /// @notice Across every adjacent representable pot, a spot cannot fall
    /// and can increase by at most one wei. The maximum has no successor.
    /// @dev 2026-09-22 solver note: addition-form comparison; the subtraction
    ///      form `afterPrice - beforePrice <= 1` lowers (via-IR) through a
    ///      symbolic-divisor division and is SMT-intractable. beforePrice is
    ///      bounded by max/10,000 + 1, so the +1 cannot wrap.
    function check_ticket_adjacent(uint256 pot) public {
        vm.assume(pot < type(uint256).max);
        hook.setupTickets(pot, 0, true, true);
        uint256 beforePrice = hook.ticketPrice();
        hook.setupTickets(pot + 1, 0, true, true);
        uint256 afterPrice = hook.ticketPrice();
        assert(afterPrice >= beforePrice);
        assert(afterPrice <= beforePrice + 1);
    }

    /// @notice Before launch, the accounted pot and genesis baseline are
    /// both zero. Merely arming sine must not switch to the one-wei minimum.
    function check_prelaunch_minimum(bool configured) public {
        hook.setupTickets(0, 0, false, configured);
        assert(hook.ticketPrice() == GameRules.MIN_BUY);
        assert(hook.MIN_BUY_INPUT() == GameRules.MIN_BUY);
    }

    /// @notice Legacy minimum remains fixed for every pot and initialization
    /// state. This does not assert that legacy ticket prices are fixed.
    function check_legacy_minimum(uint256 pot, bool initialized) public {
        hook.setupTickets(pot, 0, initialized, false);
        assert(hook.MIN_BUY_INPUT() == GameRules.MIN_BUY);
    }

    /// @notice Any caller other than the immutable controller is rejected
    /// before any mode transition, for all four source and destination modes.
    function check_setMode_unauthorized(address caller, uint8 initialMode, uint8 targetMode) public {
        vm.assume(caller != address(0xC0FFEE));
        vm.assume(initialMode < 4 && targetMode < 4);
        hook.setupMode(CurveHook.Mode(initialMode));
        vm.prank(caller);
        (bool ok, bytes memory reason) = address(hook).call(
            abi.encodeCall(CurveHook.setMode, (CurveHook.Mode(targetMode)))
        );
        assert(!ok);
        assert(reason.length == 4);
        assert(bytes4(reason) == CurveHook.NotController.selector);
        assert(uint8(hook.mode()) == initialMode);
    }

    function testFuzz_ticket_interval(uint256 pot, uint256 genesisPot) public {
        check_ticket_interval(pot, genesisPot);
    }

    function testFuzz_active_minimum_positive(uint256 pot) public { check_active_minimum_positive(pot); }

    function testFuzz_ticket_genesis_independent(uint256 pot, uint256 genesisA, uint256 genesisB) public {
        check_ticket_genesis_independent(pot, genesisA, genesisB);
    }

    function testFuzz_ticket_adjacent(uint256 pot) public {
        check_ticket_adjacent(bound(pot, 0, type(uint256).max - 1));
    }

    function testFuzz_prelaunch_minimum(bool configured) public { check_prelaunch_minimum(configured); }

    function testFuzz_legacy_minimum(uint256 pot, bool initialized) public {
        check_legacy_minimum(pot, initialized);
    }

    function testFuzz_setMode_unauthorized(address caller, uint8 initialMode, uint8 targetMode) public {
        if (caller == address(0xC0FFEE)) caller = address(0xBAD);
        check_setMode_unauthorized(caller, initialMode % 4, targetMode % 4);
    }

    function test_ticket_boundary_examples() public {
        check_ticket_interval(0, 0);
        check_ticket_interval(1, 0);
        check_ticket_interval(9_999, 0);
        check_ticket_interval(10_000, 0);
        check_ticket_interval(10_001, 0);
        check_ticket_interval(type(uint256).max, type(uint256).max);
    }

    /// @notice Exhaustive concrete check of the ORIGINAL subtraction-form
    /// bucket property over the wrap-risk zone the symbolic proof excludes:
    /// every pot in (max - 10,000, max]. 10,003 staticcalls on the real
    /// etched runtime; the subtraction form is exact here (no wrap: the
    /// bucket floor never exceeds the pot).
    function test_ticket_interval_top_region_exhaustive() public {
        uint256 start = type(uint256).max - 10_002;
        for (uint256 pot = start; pot <= type(uint256).max; ++pot) {
            hook.setupTickets(pot, 0, true, true);
            uint256 q = hook.ticketPrice();
            assert(q >= 1);
            assert(hook.MIN_BUY_INPUT() == q);
            uint256 lower = (q - 1) * 10_000;
            assert(lower < pot);
            assert(pot - lower <= 10_000);
            if (pot == type(uint256).max) break; // ++pot would wrap
        }
        // the boundary seam between symbolic and exhaustive regions
        check_ticket_interval(type(uint256).max - 10_003, 0);
    }
}
