// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SineV3Math} from "../src/SineV3Math.sol";
import {RealV4Base} from "./RealV4Lifecycle.t.sol";
import {TicketSwapper} from "./UncappedCapacity.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @title SineV3Economics — conservation and endpoint-purity through real V4
/// @notice The v3 economic core: buy/sell round trips never extract mixETH
///         through numerical error (fees and haircuts accounted separately),
///         supply telescopes exactly under trade chopping, settlement work
///         does not grow with waves crossed, and sells never overpay.
contract SineV3EconomicsTest is RealV4Base {
    SineV3Math math = new SineV3Math();
    TicketSwapper swapper;
    address trader = makeAddr("round-trip-trader");

    function setUp() public override {
        super.setUp();
        swapper = new TicketSwapper(poolManager, IERC20(address(mixETH)));
        mixETH.depositETH{value: 1_000_000e18}(); // the mock mints 1:1 against ETH
        mixETH.transfer(trader, 1_000_000e18);
        vm.startPrank(trader);
        mixETH.approve(address(swapper), type(uint256).max);
        IERC20(address(pspToken)).approve(address(this), type(uint256).max);
        vm.stopPrank();
    }

    function _key() internal view returns (PoolKey memory) {
        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(address(pspToken));
        if (c0 > c1) (c0, c1) = (c1, c0);
        return PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: hook});
    }

    function _buy(uint256 amt) internal returns (uint256) {
        vm.prank(trader);
        return swapper.buy(_key(), amt, trader, trader);
    }

    /// Buy x then sell EVERYTHING back: mixETH received < x strictly, at
    /// every depth — boot region, mid waves, past the target, deep range.
    function testFuzz_BuySellRoundTripNeverWins(uint8 depth, uint88 amt) public {
        uint256 mixBefore = mixETH.balanceOf(trader); // BEFORE any depth spends
        // walk the reserve to a varied depth first
        for (uint256 i; i < depth % 5; ++i) _buy(300e18);
        // sample the spend bound AFTER the walk: each buy's fee legs grow
        // the pot and reprice the one-spot minimum upward
        uint256 spend = bound(uint256(amt), hook.ticketPrice() * 5, 500e18);
        uint256 got = _buy(spend);
        assertGt(got, 0);
        // sell ALL accumulated PSP back through the real pool (fee legs
        // included): the trader must end strictly below where they began
        uint256 back = _sellAll();
        assertGt(back, 0);
        assertLt(mixETH.balanceOf(trader), mixBefore, "net mixETH out: full cycle strictly losing");
    }

    /// Same property, helper-level with fees separated: the CURVE legs alone
    /// (no swap fee) are strictly conservative — haircuts dominate error.
    function test_HelperCurveLegsConservative() public view {
        uint256 boot = 450e18;
        uint256 lam = 955e18;
        // pre-boot, mid, target, past target, deep (all inside the 64-wave edge)
        uint256[8] memory depths = [
            uint256(0), 50e18, 450e18, 2_000e18, 9_550e18, 20_000e18, 40_000e18, 55_000e18
        ];
        for (uint256 i; i < depths.length; ++i) {
            uint256 R = boot + depths[i];
            uint256 spend = 100e18;
            uint256 out = math.buyOut(R, boot, lam, 75e12, spend);
            assertGt(out, 0, "out positive");
            // sell from the post-buy reserve through the SAME point
            uint256 back = math.sellOut(R + spend, boot, lam, 75e12, out);
            assertLt(back, spend, "curve legs strictly conservative");
            // spot clamp: sell payout bounded by start-spot valuation
            assertLe(back, out * math.priceWad(R + spend, boot, lam, 75e12) / 1e18 + 1);
        }
    }

    /// Endpoint purity: supply differences telescope exactly in integers —
    /// Q(R+a+b) - Q(R) == [Q(R+a+b) - Q(R+a)] + [Q(R+a) - Q(R)].
    function test_TelescopingExactness() public view {
        uint256 boot = 90e18;
        uint256 lam = math.lamAt(boot);
        uint256 pL = 75e12;
        uint256[5] memory rs = [uint256(0), 1, boot / 2, boot, boot + 7 * lam / 3];
        for (uint256 i; i < rs.length; ++i) {
            for (uint256 d = 1; d < 6; ++d) {
                uint256 R = rs[i] + d * 123457e12;
                uint256 a = 7919e15;
                uint256 b = 104729e15;
                uint256 total = math.supplyWad(R + a + b, boot, lam, pL) - math.supplyWad(R, boot, lam, pL);
                uint256 left = math.supplyWad(R + a + b, boot, lam, pL) - math.supplyWad(R + a, boot, lam, pL);
                uint256 right = math.supplyWad(R + a, boot, lam, pL) - math.supplyWad(R, boot, lam, pL);
                assertEq(total, left + right, "integer telescoping");
            }
        }
    }

    /// Settlement work is O(1)-ish in waves crossed: a buy spanning ~30
    /// waves costs the same order as a one-quarter-wave buy (no per-wave
    /// loop anywhere in the settlement path).
    function test_MultiWaveGasIsFlat() public {
        // this round boots at 90 mix (lambda ~427 mix): the 64-wave edge is
        // ~27,418 mix of reserve depth — span most of it. Warm the pool
        // first so the dust buy is not paying first-swap storage costs.
        _buy(1e18);
        uint256 gasSmall = _buyGas(1e16);              // dust of a wave
        uint256 gasMany = _buyGas(20_000e18);          // ~46 waves
        assertGt(gasMany, gasSmall, "bigger buys do more, but bounded");
        assertLt(gasMany, gasSmall + 400_000, "no per-wave gas growth");
        // headroom to the ABSOLUTE 64-wave edge (boot + 64*lam), bought 95% deep
        (uint256 boot, uint256 lam,, ) = hook.sineV3();
        uint256 edge = boot + 64 * lam;
        uint256 gasDeep = _buyGas((edge - hook.reserveMixETH()) * 95 / 100);
        assertLt(gasDeep, gasSmall + 600_000, "domain-edge buys stay bounded");
    }

    /// Selling deep and wide: the inverse terminates quickly everywhere in
    /// the supported domain (bracketed Newton, never a per-wei walk).
    function test_InverseGasBounded() public {
        _buy(20_000e18); // deep reserve (~46 waves)
        uint256 psp = IERC20(address(pspToken)).balanceOf(trader);
        uint256 gas = gasleft();
        vm.prank(trader);
        hook.getSellOutput(psp / 3);
        uint256 used = gas - gasleft();
        assertLt(used, 4_000_000, "inverse gas bounded");
    }

    /// Failure at the domain boundary leaves balances, supply, reserve,
    /// tickets, and fee liabilities unchanged.
    function test_DomainFailureLeavesStateUntouched() public {
        (uint256 boot, uint256 lam,,) = hook.sineV3();
        (,, uint256 target,) = hook.sineV3();
        uint256 spend = target + 64 * lam + 1 - hook.reserveMixETH();
        uint256 mixBefore = mixETH.balanceOf(trader);
        uint256 reserve = hook.reserveMixETH();
        uint256 supply = hook.totalSupplyPSP();
        uint256 tickets = hook.ticketCount();
        vm.prank(trader);
        try swapper.buy(_key(), spend, trader, trader) {
            fail("domain-crossing buy must revert");
        } catch (bytes memory reason) {
            // V4 wraps the hook's SineV3Domain — any revert shape is fine
            // as long as NOTHING changed
            assertGt(reason.length, 0);
        }
        assertEq(mixETH.balanceOf(trader), mixBefore);
        assertEq(hook.reserveMixETH(), reserve);
        assertEq(hook.totalSupplyPSP(), supply);
        assertEq(hook.ticketCount(), tickets);
    }

    // ─────────────── helpers ───────────────

    function _sellAll() internal returns (uint256) {
        uint256 bal = IERC20(address(pspToken)).balanceOf(trader);
        vm.prank(trader);
        IERC20(address(pspToken)).transfer(address(this), bal);
        // direct pool swap through the unlocked manager via hook callback
        SellRouter r = new SellRouter(poolManager, IERC20(address(mixETH)));
        IERC20(address(pspToken)).approve(address(r), type(uint256).max);
        return r.sell(_key(), bal, trader);
    }

    function _buyGas(uint256 amt) internal returns (uint256) {
        uint256 g = gasleft();
        _buy(amt);
        return g - gasleft();
    }
}

/// @dev Minimal real-V4 seller (PSP in, mixETH out, real sync/settle/take).
contract SellRouter {
    IPoolManager public immutable pm;
    IERC20 public immutable mix;

    constructor(IPoolManager _pm, IERC20 _mix) {
        pm = _pm;
        mix = _mix;
    }

    function sell(PoolKey calldata key, uint256 pspIn, address to) external returns (uint256) {
        IERC20(Currency.unwrap(key.currency1 == Currency.wrap(address(mix)) ? key.currency0 : key.currency1))
            .transferFrom(msg.sender, address(this), pspIn);
        bytes memory r = pm.unlock(abi.encode(key, pspIn, to));
        return abi.decode(r, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, uint256 pspIn, address to) = abi.decode(data, (PoolKey, uint256, address));
        bool mixIsZero = key.currency0 == Currency.wrap(address(mix));
        Currency pspCur = mixIsZero ? key.currency1 : key.currency0;
        pm.sync(pspCur);
        IERC20(Currency.unwrap(pspCur)).transfer(address(pm), pspIn);
        pm.settle();
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                amountSpecified: -int256(pspIn),
                sqrtPriceLimitX96: mixIsZero ? 1461446703485210103287273052203988822378723970341 : 4295128749,
                zeroForOne: !mixIsZero
            }),
            abi.encode(to)
        );
        int256 mixDelta = mixIsZero ? d.amount0() : d.amount1();
        require(mixDelta > 0, "no out");
        uint256 amt = uint256(int256(mixDelta));
        pm.take(mixIsZero ? key.currency0 : key.currency1, to, amt);
        return abi.encode(amt);
    }
}
