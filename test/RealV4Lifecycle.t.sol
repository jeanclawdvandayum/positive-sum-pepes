// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {PSPFactory} from "../src/PSPFactory.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {ControllerDeployer} from "../src/ControllerDeployer.sol";
import {RoundController} from "../src/RoundController.sol";
import {PSPToken} from "../src/PSPToken.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {PSPZapIn} from "../src/PSPZapIn.sol";
import {PSPZapOut} from "../src/PSPZapOut.sol";
import {IMixETH} from "../src/interfaces/IMixETH.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {SineMath} from "../src/libraries/SineMath.sol";
import {PSPReinvestor} from "../src/PSPReinvestor.sol";
import {IPSPStaker} from "../src/interfaces/IPSPStaker.sol";
import {IPSPZapIn} from "../src/interfaces/IPSPZapIn.sol";
import {MockMixETH} from "./mocks/MockMixETH.sol";
import {StakerDeployer} from "src/StakerDeployer.sol";


/// @title ZapSwapsTest — the ETH <-> PSP round trip on a real V4
///        PoolManager with real curve pricing. Alice never holds mixETH:
///        she enters with ETH via PSPZapIn and exits to ETH via PSPZapOut.
abstract contract RealV4Base is Test {
    function testTimings() internal pure virtual returns (uint256) { return 0; }
    function createMixETH() internal virtual returns (MockMixETH) { return new MockMixETH(); }
    IPoolManager poolManager;
    MockMixETH mixETH;
    PSPFactory factory;
    PSPZapIn zapIn;
    PSPZapOut zapOut;

    RoundController controller;
    PSPToken pspToken;
    CurveHook hook;
    PoolKey poolKey;

    address alice = makeAddr("psp-zap-alice-x7749"); // ETH-only user
    address bob = makeAddr("psp-zap-bob-x7749"); // mixETH user (bootstraps the round)

    function setUp() public virtual {
        vm.warp(1000 * 7 days);
        poolManager = IPoolManager(address(new PoolManager(address(this))));
        mixETH = createMixETH();
        mixETH.depositETH{value: 100_000e18}();

        factory = new PSPFactory(
            poolManager, IERC20(address(mixETH)), new HookDeployer(), new ControllerDeployer(), new StakerDeployer()
        , testTimings(),
            address(this) // deployerCutTo (CLOCK-REDESIGN §3)
        );
        zapIn = new PSPZapIn(IMixETH(address(mixETH)), poolManager);
        zapOut = new PSPZapOut(IMixETH(address(mixETH)), poolManager);

        factory.configureSine(SineMath.Params(1e13, 4_605_170_185_988_092, 0.06e18, 10_000e18, 10000));
        // Deploy a round
        PSPFactory.RoundParams memory params = PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: CurveMath.singleCurve(0.001e18, 1_000_000e18, 0.0000000046e18, 0.05e18)
        });
        (uint256 roundId,) = factory.deployRound(params);
        PSPFactory.Round memory round = factory.getRound(roundId);
        controller = round.controller;
        pspToken = round.token;
        hook = round.hook;

        // Pool key, sorted like the factory builds it
        Currency c0 = Currency.wrap(address(mixETH));
        Currency c1 = Currency.wrap(address(pspToken));
        if (c0 > c1) (c0, c1) = (c1, c0);
        poolKey = PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: hook});

        // Bob bootstraps: predeposit + launch
        mixETH.transfer(bob, 100e18);
        vm.startPrank(bob);
        mixETH.approve(address(controller), 100e18);
        controller.predeposit(100e18);
        vm.stopPrank();

        vm.prank(address(factory));
        controller.launchPooledBuy();
    }

}

contract RealV4LifecycleTest is RealV4Base {
    // ═══════════════════════════════════════════════════════════════
    //  Zap in: ETH -> mixETH -> curve swap -> PSP
    // ═══════════════════════════════════════════════════════════════

    function test_LocalV4_ZapInBuyETHToPSP() public {
        vm.deal(alice, 5e18);
        vm.prank(alice);
        uint256 pspOut = zapIn.zapInBuy{value: 5e18}(poolKey, 1, 0);

        assertGt(pspOut, 0, "PSP out");
        assertEq(pspToken.balanceOf(alice), pspOut, "alice holds the PSP");
        assertEq(pspToken.balanceOf(address(zapIn)), 0, "zap holds no PSP");
        assertEq(mixETH.balanceOf(address(zapIn)), 0, "zap holds no mixETH");
        assertEq(alice.balance, 0, "all ETH spent");
    }

    function test_LocalV4_ZapInBuySlippageReverts() public {
        vm.deal(alice, 5e18);
        vm.prank(alice);
        vm.expectRevert(PSPZapIn.InsufficientOutput.selector);
        zapIn.zapInBuy{value: 5e18}(poolKey, type(uint256).max, 0);
    }

    function test_LocalV4_ZapInBuyDeadlineReverts() public {
        vm.deal(alice, 5e18);
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vm.expectRevert(PSPZapIn.Expired.selector);
        zapIn.zapInBuy{value: 5e18}(poolKey, 1, block.timestamp - 1);
    }

    function test_LocalV4_ZapInBuyBadPoolReverts() public {
        // mixETH on both sides
        PoolKey memory bad = PoolKey({
            currency0: Currency.wrap(address(mixETH)),
            currency1: Currency.wrap(address(mixETH)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: hook
        });
        vm.deal(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(PSPZapIn.BadPool.selector);
        zapIn.zapInBuy{value: 1e18}(bad, 1, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Zap out: PSP -> curve swap -> mixETH -> redeem -> ETH
    // ═══════════════════════════════════════════════════════════════

    function test_LocalV4_ZapOutPSPToETH() public {
        // Alice enters with ETH...
        vm.deal(alice, 5e18);
        vm.prank(alice);
        uint256 pspOut = zapIn.zapInBuy{value: 5e18}(poolKey, 1, 0);
        assertGt(pspOut, 0, "setup: bought PSP");

        // ...and exits to ETH in one call
        vm.startPrank(alice);
        pspToken.approve(address(zapOut), pspOut);
        uint256 ethOut = zapOut.zapOut(poolKey, pspOut, 1, 0);
        vm.stopPrank();

        assertGt(ethOut, 0, "ETH out");
        assertGt(alice.balance, 0, "alice got ETH back");
        assertLt(alice.balance, 5e18, "round trip pays the spread");
        assertEq(pspToken.balanceOf(alice), 0, "alice sold everything");
        assertEq(mixETH.balanceOf(address(zapOut)), 0, "zap holds no mixETH");
        assertEq(address(zapOut).balance, 0, "zap holds no ETH");
    }

    function test_LocalV4_ZapOutSlippageReverts() public {
        vm.deal(alice, 5e18);
        vm.prank(alice);
        uint256 pspOut = zapIn.zapInBuy{value: 5e18}(poolKey, 1, 0);

        vm.startPrank(alice);
        pspToken.approve(address(zapOut), pspOut);
        vm.expectRevert(PSPZapOut.InsufficientOutput.selector);
        zapOut.zapOut(poolKey, pspOut, type(uint256).max, 0);
        vm.stopPrank();

        // Reverted call rolled the whole tx back: alice keeps her PSP,
        // the zap holds nothing (nothing ever left her in a committed state)
        assertEq(pspToken.balanceOf(alice), pspOut, "PSP unchanged by revert");
        assertEq(pspToken.balanceOf(address(zapOut)), 0, "zap holds no PSP");
        assertEq(address(zapOut).balance, 0, "no ETH stuck");
    }

    function test_LocalV4_ZapOutDeadlineReverts() public {
        vm.deal(alice, 5e18);
        vm.prank(alice);
        uint256 pspOut = zapIn.zapInBuy{value: 5e18}(poolKey, 1, 0);

        vm.warp(block.timestamp + 1);
        vm.startPrank(alice);
        pspToken.approve(address(zapOut), pspOut);
        vm.expectRevert(PSPZapOut.Expired.selector);
        zapOut.zapOut(poolKey, pspOut, 1, block.timestamp - 1);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Raw mixETH legs (no ETH involved)
    // ═══════════════════════════════════════════════════════════════

    function test_LocalV4_BuyWithMixAndSellToMix() public {
        // bob predeposited everything in setUp; refresh his mixETH
        mixETH.transfer(bob, 10e18);

        // bob buys PSP straight from his mixETH balance
        vm.startPrank(bob);
        mixETH.approve(address(zapIn), 5e18);
        uint256 pspOut = zapIn.buyWithMix(poolKey, 5e18, 1, 0);
        vm.stopPrank();

        assertGt(pspOut, 0, "bob got PSP");
        assertEq(pspToken.balanceOf(bob), pspOut, "PSP with bob");
        assertEq(pspToken.balanceOf(address(zapIn)), 0, "zapIn clean");
        uint256 bobMixAfterBuy = mixETH.balanceOf(bob);

        // ...and sells it back to mixETH in one call
        vm.startPrank(bob);
        pspToken.approve(address(zapOut), pspOut);
        uint256 mixOut = zapOut.sellToMix(poolKey, pspOut, 1, 0);
        vm.stopPrank();

        assertGt(mixOut, 0, "mix out");
        assertEq(mixETH.balanceOf(bob), bobMixAfterBuy + mixOut, "mix credited to bob");
        assertEq(pspToken.balanceOf(bob), 0, "bob sold all PSP");
        assertEq(mixETH.balanceOf(address(zapOut)), 0, "zapOut clean");
        assertEq(address(zapOut).balance, 0, "no ETH involved");
    }

    function test_LocalV4_SellToMixSlippageReverts() public {
        mixETH.transfer(bob, 10e18);
        vm.startPrank(bob);
        mixETH.approve(address(zapIn), 5e18);
        uint256 pspOut = zapIn.buyWithMix(poolKey, 5e18, 1, 0);

        pspToken.approve(address(zapOut), pspOut);
        vm.expectRevert(PSPZapOut.InsufficientOutput.selector);
        zapOut.sellToMix(poolKey, pspOut, type(uint256).max, 0);
        vm.stopPrank();

        // revert rolled everything back
        assertEq(pspToken.balanceOf(bob), pspOut, "PSP unchanged");
        assertEq(mixETH.balanceOf(address(zapOut)), 0, "zapOut clean");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Access control on the callback
    // ═══════════════════════════════════════════════════════════════

    function test_LocalV4_UnlockCallbackOnlyPoolManager() public {
        vm.expectRevert(PSPZapIn.NotPoolManager.selector);
        zapIn.unlockCallback("");

        vm.expectRevert(PSPZapOut.NotPoolManager.selector);
        zapOut.unlockCallback("");
    }

    function test_LocalV4_MinimumAndSeatsAtDifferentPrices() public {
        vm.deal(alice, 100e18);
        uint256 reserveBefore = hook.reserveMixETH();
        vm.prank(alice);
        vm.expectRevert(); // real V4 wraps the hook's SwapTooSmall error
        zapIn.zapInBuy{value: 0.005e18 - 1}(poolKey, 1, 0);
        assertEq(hook.reserveMixETH(), reserveBefore);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 hours);
        uint256 deadline = hook.detonationAt();
        vm.prank(alice);
        zapIn.zapInBuy{value: 0.005e18}(poolKey, 1, 0);
        assertEq(hook.ticketCount(), 1);
        assertEq(hook.detonationAt(), deadline + 69);
        uint256 tenTickets = hook.ticketPrice() * 10;
        vm.prank(alice);
        zapIn.zapInBuy{value: tenTickets}(poolKey, 1, 0);
        assertEq(hook.ticketCount(), 11);
        for (uint256 i; i < 10; i++) {
            (address who,,,)=hook.board(i);
            assertEq(who, alice);
        }
    }

    function test_LocalV4_StagedRebirthAndOldRoundClaims() public {
        vm.deal(alice, 1e18);
        vm.prank(alice);
        uint256 bag = zapIn.zapInBuy{value: 0.01e18}(poolKey, 1, 0);
        vm.warp(hook.detonationAt());
        vm.prank(alice);
        controller.detonate{gas: 1_000_000}();
        assertEq(uint256(hook.mode()), 2);
        assertEq(factory.currentRoundId(), 1);
        factory.reserveSpawn(1);
        for (uint256 i; i < 3; ++i) factory.birthStep{gas: 12_000_000}();
        assertEq(factory.currentRoundId(), 2);
        PSPFactory.Round memory next = factory.getRound(2);
        mixETH.approve(address(next.controller), 1e18);
        next.controller.predeposit(1e18);
        vm.prank(address(factory));
        next.controller.launchPooledBuy();
        Currency c0=Currency.wrap(address(mixETH));
        Currency c1=Currency.wrap(address(next.token));
        if(c0>c1)(c0,c1)=(c1,c0);
        PoolKey memory nextKey=PoolKey(c0,c1,0x800000,60,next.hook);
        vm.prank(alice);
        zapIn.zapInBuy{value: 0.005e18}(nextKey,1,0);
        assertEq(next.hook.ticketCount(),1);
        vm.startPrank(alice);
        hook.claimPot();
        pspToken.approve(address(hook),bag);
        uint256 expected=bag*hook.reserveMixETH()/hook.totalSupplyPSP();
        assertEq(hook.redeemBacking(bag),expected);
        vm.stopPrank();
        assertEq(pspToken.balanceOf(alice),0);
    }

    function test_LocalV4_EmptyBoardReturnsGenesisPotToBacking() public {
        uint256 backing = hook.reserveMixETH();
        uint256 pot = hook.potBalance();
        vm.warp(hook.detonationAt());
        controller.detonate{gas: 1_000_000}();
        assertEq(hook.reserveMixETH(),backing+pot);
        assertEq(hook.potBalance(),0);
    }

    function test_LocalV4_ReinvestOwnerSucceedsStrangerFails() public {
        vm.prank(bob);
        controller.claimPredepositPSP();
        uint256 id=controller.staker().primaryOf(bob);
        PSPReinvestor reinvestor=new PSPReinvestor(IPSPStaker(address(controller.staker())),IPSPZapIn(address(zapIn)),IERC20(address(mixETH)),IERC20(address(pspToken)));
        address stakerAddress = address(controller.staker());
        vm.prank(bob);
        IPSPApproval(stakerAddress).setApprovalForAll(address(reinvestor),true);
        vm.deal(alice,10e18);
        vm.prank(alice);
        zapIn.zapInBuy{value: 1e18}(poolKey,1,0);
        vm.prank(alice);
        vm.expectRevert(PSPReinvestor.Unauthorized.selector);
        reinvestor.reinvest(id,poolKey,0,0);
        (uint256 before,,,,)=controller.staker().positions(id);
        vm.prank(bob);
        reinvestor.reinvest(id,poolKey,1,block.timestamp+600);
        (uint256 afterAmount,,,,)=controller.staker().positions(id);
        assertGt(afterAmount,before);
        (address creditedBuyer,,,) = hook.board(0);
        assertEq(creditedBuyer, bob, "AUD-14: reinvestment seats belong to the NFT owner");
    }

    function test_LocalV4_ReinvestRejectsDuplicateAndForeignPositions() public {
        vm.prank(bob);
        controller.claimPredepositPSP();
        address stakeAddress = address(controller.staker());
        uint256 bobId = controller.staker().primaryOf(bob);
        vm.deal(alice, 1e18);
        vm.prank(alice);
        uint256 bought = zapIn.zapInBuy{value: 0.005e18}(poolKey, 1, 0);
        vm.startPrank(alice);
        pspToken.approve(stakeAddress, bought);
        IPSPStake(stakeAddress).lockWithPepe(bought, 777);
        vm.stopPrank();
        PSPReinvestor reinvestor = new PSPReinvestor(IPSPStaker(stakeAddress), IPSPZapIn(address(zapIn)), IERC20(address(mixETH)), IERC20(address(pspToken)));
        uint256[] memory ids = new uint256[](2);
        ids[0] = bobId;
        ids[1] = bobId;
        vm.prank(bob);
        vm.expectRevert(PSPReinvestor.InvalidBatch.selector);
        reinvestor.reinvestAll(ids, poolKey, 1, 0);
        ids[1] = 777;
        vm.prank(bob);
        vm.expectRevert(PSPReinvestor.Unauthorized.selector);
        reinvestor.reinvestAll(ids, poolKey, 1, 0);
    }

    function test_LocalV4_DonationCannotPoisonNextLaunch() public {
        vm.warp(hook.detonationAt());
        controller.detonate{gas: 1_000_000}();
        mixETH.transfer(address(factory),50_000e18);
        factory.reserveSpawn(1);
        for(uint256 i;i<3;++i)factory.birthStep{gas:12_000_000}();
        RoundController next=factory.getRound(2).controller;
        assertEq(next.totalPredepositMixETH(),50_000e18);
        vm.expectRevert(RoundController.PredepositOpen.selector);
        next.launchPooledBuy();
        skip(next.PREDEPOSIT_DURATION());
        next.launchPooledBuy();
        assertEq(uint256(factory.getRound(2).hook.mode()),1);
        assertEq(mixETH.balanceOf(address(factory)),0);
        (,,, uint256 target,,,,,,,) = factory.getRound(2).hook.sineCurve();
        assertApproxEqAbs(target, 1_000_000e18, 3);
    }
}

interface IPSPApproval { function setApprovalForAll(address operator, bool approved) external; }

interface IPSPStake { function lockWithPepe(uint256 amount, uint256 pepeId) external; }
