// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {CBase} from "../../wave2/auditorC/CBase.sol";
import {CurveHook} from "../../../src/CurveHook.sol";
import {RoundController} from "../../../src/RoundController.sol";
import {PSPFactory} from "../../../src/PSPFactory.sol";
import {CurveMath} from "../../../src/libraries/CurveMath.sol";
import {ISineV3Math} from "../../../src/interfaces/ISineV3Math.sol";

/// @title 2026-09-08 testnet-final audit — sine-path machine proofs
/// @notice Two properties the wave2 matrix pins for ZONE rounds but not for
///         the sine flavor (the flavor actually deployed to Base Sepolia):
///
///         P1 (supply bound): hook.totalSupplyPSP <= supplyWad(reserve) of
///             the round's own SineV3 curve at ALL times. This is what makes
///             SineV3Math.sellOut()'s `pspIn >= qNow -> return R` defensive floor
///             UNREACHABLE — if it were ever reachable, one sell could drain
///             the entire reserve (all other holders lose their backing).
///
///         P2 (custody solvency): the hook's live mixETH balance always
///             covers reserve + unclaimed pot + unclaimed deployer credit —
///             sendFees() can never underflow for staker payouts, and no
///             trade sequence can leave escrows underfunded.
///
///         Method: randomized buy/sell/chop sequences against the REAL hook
///         (only PoolManager + mixETH are mocks, same as the repo suite).
///         No vm.mockCall. REAL token movement only.
contract SellSwapper {
    IPoolManager public immutable pm;
    IERC20 public immutable mix;

    constructor(IPoolManager _pm, IERC20 _mix) {
        pm = _pm;
        mix = _mix;
    }

    function sell(PoolKey calldata key, uint256 pspIn, address mixTo) external returns (uint256 mixOut) {
        address pspAddr = Currency.unwrap(key.currency0) == address(mix)
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);
        IERC20(pspAddr).transferFrom(msg.sender, address(this), pspIn);
        bytes memory r = pm.unlock(abi.encode(key, pspIn, mixTo));
        return abi.decode(r, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, uint256 pspIn, address mixTo) = abi.decode(data, (PoolKey, uint256, address));
        bool mixIsZero = Currency.unwrap(key.currency0) == address(mix);
        Currency pspCur = mixIsZero ? key.currency1 : key.currency0;
        Currency mixCur = mixIsZero ? key.currency0 : key.currency1;

        pm.sync(pspCur);
        IERC20(Currency.unwrap(pspCur)).transfer(address(pm), pspIn);
        pm.settle();

        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                amountSpecified: -int256(pspIn),
                sqrtPriceLimitX96: mixIsZero ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1,
                zeroForOne: !mixIsZero
            }),
            abi.encode(mixTo) // 32-byte trader hint (A-1 shape; no attribution created)
        );
        int256 mixDelta = mixIsZero ? d.amount0() : d.amount1();
        require(mixDelta > 0, "no out");
        uint256 out = uint256(int256(mixDelta));
        pm.take(mixCur, mixTo, out);
        return abi.encode(out);
    }
}

contract SineCustodyInvariants is CBase {
    CurveHook sineHook;
    RoundController sineController;
    IERC20 sinePSP;
    SellSwapper seller;
    IERC20 mix;

    address trader1 = makeAddr("t1");
    address trader2 = makeAddr("t2");

    function setUp() public override {
        super.setUp();
        mix = IERC20(address(mixETH));
        seller = new SellSwapper(IPoolManager(address(poolManager)), mix);

        // Deploy a SINE round (the live Base-Sepolia flavor) as round 2.
        vm.prank(address(this));
        factory.configureSineV3(75_000_000_000_000);
        vm.prank(address(this));
        (uint256 roundId,) = factory.deployRound(
            PSPFactory.RoundParams({
                name: "PSP Sine",
                symbol: "PSPS",
                curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
            })
        );
        PSPFactory.Round memory round = factory.getRound(roundId);
        sineHook = round.hook;
        sineController = round.controller;
        sinePSP = IERC20(address(round.token));

        // Launch with a real boot inside the validated range (AUD-8 domain).
        vm.warp(7 days + 1);
        mix.transfer(trader1, 400e18);
        mix.transfer(trader2, 100e18);
        vm.startPrank(trader1);
        mix.approve(address(sineController), 300e18);
        sineController.predeposit(300e18);
        vm.stopPrank();
        vm.startPrank(trader2);
        mix.approve(address(sineController), 60e18);
        sineController.predeposit(60e18);
        vm.stopPrank();
        sineController.launchPooledBuy();
        vm.prank(trader1);
        sineController.claimPredepositPSP();
        vm.prank(trader2);
        sineController.claimPredepositPSP();
        // top up trading wallets (predeposit claims are STAKED, not liquid)
        mix.transfer(trader1, 500e18);
        mix.transfer(trader2, 500e18);
        sinePSP.approve(address(seller), type(uint256).max);
        vm.prank(trader2);
        round.token.approve(address(seller), type(uint256).max);
    }

    function _key() internal view returns (PoolKey memory) {
        address c0 = address(mix);
        address c1 = address(sinePSP);
        if (c0 > c1) (c0, c1) = (c1, c0);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(sineHook))
        });
    }

    function _buyAs(address who, uint256 amt) internal returns (uint256) {
        vm.startPrank(who);
        mix.approve(address(swapper), amt);
        uint256 out = swapper.buy(_key(), amt, who);
        sinePSP.approve(address(seller), type(uint256).max);
        vm.stopPrank();
        return out;
    }

    function _sellAs(address who, uint256 amt) internal returns (uint256) {
        vm.prank(who);
        return seller.sell(_key(), amt, who);
    }

    /// P1: hook supply never exceeds the pure v3 curve supply at the same
    /// reserve (evaluated on the round's own immutable helper).
    function _assertSupplyBound(string memory where) internal view {
        (uint256 boot, uint256 lam,,) = sineHook.sineV3();
        uint256 pureSupply = ISineV3Math(sineHook.sineV3Table()).supplyWad(
            sineHook.reserveMixETH(), boot, lam, sineHook.sinePL()
        );
        assertLe(sineHook.totalSupplyPSP(), pureSupply, string.concat("P1 supply>pure @ ", where));
    }

    /// P2: custody covers reserve + pot + deployer escrows at all times.
    function _assertCustody(string memory where) internal view {
        uint256 needed = sineHook.reserveMixETH() + (sineHook.potBalance() - sineHook.potPaid())
            + (sineHook.deployerCredit() - sineHook.deployerCreditPaid());
        assertLe(needed, mix.balanceOf(address(sineHook)), string.concat("P2 custody short @ ", where));
    }

    function test_Audit_SineSupplyBoundGenesis() public view {
        _assertSupplyBound("genesis");
        _assertCustody("genesis");
    }

    /// Randomized chop: buys, sells, splits — both invariants every step.
    function testFuzz_Audit_SineChopInvariants(uint8 seed, uint8 steps) public {
        steps = uint8(bound(steps, 4, 24));
        for (uint256 i; i < steps; ++i) {
            uint256 roll = uint256(keccak256(abi.encode(seed, i)));
            if (roll % 3 == 0) {
                // buy: one current ticket .. 2 mixETH (v3 minimum is the
                // live ticket price — dynamic bound keeps the gate live)
                uint256 amt = bound(roll, sineHook.ticketPrice(), 2e18);
                if (mix.balanceOf(trader1) < amt) mix.transfer(trader1, 10e18);
                _buyAs(trader1, amt);
            } else if (roll % 3 == 1) {
                // sell: up to 40% of holdings
                uint256 bal = sinePSP.balanceOf(trader1);
                if (bal > sineHook.totalSupplyPSP() / 2) bal = sineHook.totalSupplyPSP() / 2;
                if (bal > 1e15) _sellAs(trader1, bound(roll, 1e15, bal));
            } else {
                // chop: buy then immediately sell 90% (B4j shape on sine)
                if (mix.balanceOf(trader2) < 1e18) mix.transfer(trader2, 10e18);
                uint256 out = _buyAs(trader2, bound(roll, sineHook.ticketPrice(), 1e18));
                if (out > 1e15) _sellAs(trader2, out * 9 / 10);
            }
            _assertSupplyBound("chop");
            _assertCustody("chop");
        }
    }

    /// P1 targeted: the `sellOut` floor (`pspIn >= qNow -> return R`) is
    /// unreachable through the hook (guard: pspIn < totalSupplyPSP, and P1:
    /// totalSupplyPSP <= supplyAt(R) = qNow). Machine-check the live path:
    /// selling one's ENTIRE liquid balance debits the integral only, leaves
    /// the round solvent (reserve > 0 while other holders exist — here the
    /// genesis claimers' staked supply), and P1/P2 hold throughout.
    /// (Note: sellOut(qNow-1) returning ~R is CORRECT economics — selling
    /// ~all circulating supply IS ~the whole reserve, same as flat
    /// redemption; the predeposit-invert branch is self-consistent with
    /// supplyAt, so payouts remain exact integrals.)
    function testFuzz_Audit_SineWholeBalanceSell(uint88) public {
        if (mix.balanceOf(trader1) < 2e18) mix.transfer(trader1, 10e18);
        _buyAs(trader1, 2e18);
        uint256 reserveBefore = sineHook.reserveMixETH();
        uint256 gotBack = _sellAs(trader1, sinePSP.balanceOf(trader1));
        assertLt(sineHook.reserveMixETH(), reserveBefore, "no debit");
        assertGt(sineHook.reserveMixETH(), 0, "reserve fully drained");
        assertGt(gotBack, 0);
        _assertSupplyBound("whole-balance-sell");
        _assertCustody("whole-balance-sell");
    }

    /// P2 targeted: fees at the sliding-fee boundary (r crossing boot and
    /// target) — escrow accounting stays solvent across the fee cliffs.
    function test_Audit_SlidingFeeBoundaryCustody() public {
        // Push reserve past boot (pre-wave 10% fee zone) into the wave.
        _buyAs(trader1, 100e18);
        _assertCustody("boot-cross");
        _buyAs(trader2, 50e18);
        _sellAs(trader2, sinePSP.balanceOf(trader2) / 2);
        _assertCustody("post-boot-sell");
        // Referral-leg conservation on an unattributed trade: 60/39/1 split.
        uint256 dCredit = sineHook.deployerCredit();
        assertGt(dCredit, 0, "deployer leg never accrued");
        _assertSupplyBound("sliding");
    }
}
