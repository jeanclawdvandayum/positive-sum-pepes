// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {RoundController} from "../../src/RoundController.sol";
import {CurveHook} from "../../src/CurveHook.sol";
import {PSPStaker} from "../../src/PSPStaker.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../src/PSPZapOut.sol";
import {PSPReinvestor} from "../../src/PSPReinvestor.sol";
import {PSPReferralRegistry} from "../../src/PSPReferralRegistry.sol";
import {PepeDna} from "../../src/libraries/PepeDna.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface IFreeMix { function mint(address to, uint256 amount) external; }

/// @dev Local-fork recipient exercises the actual deployed ERC-721 callback.
contract ReleasePepeReceiver is IERC721Receiver {
    address public receivedOperator;
    address public receivedFrom;
    uint256 public receivedId;
    bytes32 public receivedDataHash;

    function onERC721Received(address operator, address from, uint256 id, bytes calldata data)
        external returns (bytes4)
    {
        receivedOperator = operator;
        receivedFrom = from;
        receivedId = id;
        receivedDataHash = keccak256(data);
        return IERC721Receiver.onERC721Received.selector;
    }

    function sendBack(PSPStaker staker, address recipient, uint256 id) external {
        staker.safeTransferFrom(address(this), recipient, id);
    }
}

contract ReleaseNonReceiver {}

/// @title BaseSepoliaReleaseTest
/// @notice Fork-only validation of actual deployed code; never broadcasts transactions.
contract BaseSepoliaReleaseTest is Test {
    struct ReleaseContext {
        PSPFactory factory;
        PSPFactory.Round r;
        PSPStaker staker;
        PSPReferralRegistry registry;
        PSPReinvestor reinvestor;
        IERC20 mix;
        PoolKey key;
        address a;
        address b;
        uint256 idA;
        uint256 idB;
    }

    /// @notice Opt-in source-release checks. Start from a freshly completed
    /// genesis deployment before public deposits/launch. Historical deployments
    /// can continue using the separate accounting canary without this flag.
    function test_FreshReleaseFeaturesAndRoundReset() public {
        if (!vm.envOr("PSP_RELEASE_FRESH", false)) { vm.skip(true); return; }
        assertEq(block.chainid, 84532, "testnet only");
        ReleaseContext memory c;
        c.factory = PSPFactory(vm.envAddress("PSP_FACTORY"));
        c.reinvestor = PSPReinvestor(vm.envAddress("PSP_REINVESTOR"));
        c.r = c.factory.getRound(1);
        c.staker = c.r.controller.staker();
        c.registry = PSPReferralRegistry(c.factory.referralRegistryOf(1));
        c.mix = c.factory.mixETH();
        c.a = makeAddr("fresh-release-alice");
        c.b = makeAddr("fresh-release-bob");

        _assertFreshWiring(c);
        IFreeMix(address(c.mix)).mint(c.a, 1000e18);
        IFreeMix(address(c.mix)).mint(c.b, 1000e18);
        IFreeMix(address(c.mix)).mint(address(this), 1000e18);
        (c.idA, c.idB) = _freshGenesis(c);
        c.key = _poolKey(c.mix, c.r);

        assertTrue(c.registry.canReferNft(c.idA));
        assertTrue(c.registry.canReferNft(c.idB));
        c.mix.approve(address(c.registry), type(uint256).max);
        // A failed purchase must roll back its newly proposed referral too.
        vm.expectRevert(PSPReferralRegistry.InsufficientOutput.selector);
        c.registry.buyWithMix(c.key, 2e18, type(uint256).max, block.timestamp, c.idB);
        assertFalse(c.registry.attributed(address(this)));
        uint256 beforeB = c.mix.balanceOf(c.b);
        uint256 bought = c.registry.buyWithMix(c.key, 2e18, 1, block.timestamp, c.idB);
        assertGt(bought, 0);
        assertEq(c.r.token.balanceOf(address(this)), bought);
        assertEq(c.registry.traderRefNftOf(address(this)), c.idB);
        assertGt(c.mix.balanceOf(c.b), beforeB, "first buy pays its referral");
        assertEq(c.r.hook.ticketCount(), 400);
        (address leader,,,) = c.r.hook.board(0);
        assertEq(leader, address(this), "registry buy credits the purchaser");
        c.registry.buyWithMix(c.key, 0.005e18, 1, block.timestamp, c.idA);
        assertEq(c.registry.traderRefNftOf(address(this)), c.idB, "later hints cannot replace entry");
        vm.expectRevert(PSPReferralRegistry.AlreadyReferred.selector);
        c.registry.record(c.idA);
        assertEq(c.mix.balanceOf(address(c.registry)), 0);
        assertEq(c.r.token.balanceOf(address(c.registry)), 0);

        _individualReinvestAndSafeTransfer(c);
        _freshReferralReset(c);
    }

    function _assertFreshWiring(ReleaseContext memory c) internal view {
        assertEq(c.factory.currentRoundId(), 1, "fresh genesis required");
        assertFalse(c.factory.reservationActive(), "all three birth steps completed");
        assertEq(uint8(c.r.hook.mode()), uint8(CurveHook.Mode.Predeposit));
        assertEq(c.r.controller.totalPredepositMixETH(), 0, "pristine release required");
        assertEq(c.r.controller.factoryRoundId(), 1);
        assertEq(address(c.r.controller.hook()), address(c.r.hook));
        assertEq(address(c.r.hook.referralRegistry()), address(c.registry));
        assertEq(address(c.staker.controller()), address(c.r.controller));
        assertEq(address(c.registry.staker()), address(c.staker));
        assertEq(address(c.reinvestor.staker()), address(c.staker));
        assertEq(address(c.reinvestor.psp()), address(c.r.token));
        assertEq(address(c.reinvestor.mix()), address(c.factory.mixETH()));
        assertEq(address(c.reinvestor.zapIn()), vm.envAddress("PSP_ZAPIN"));
        assertEq(c.r.hook.MIN_BUY_INPUT(), 0.005e18);
        assertEq(c.r.hook.TIME_PER_UNIT(), 260);
        assertEq(c.r.hook.FEE_BPS_PRE_WAVE(), 1000);
        assertEq(c.r.hook.FEE_BPS_ABOVE_WAVE(), 250);
        assertEq(c.r.hook.STAKER_BPS(), 6000);
        assertEq(c.r.hook.POT_BPS(), 3500);
        assertEq(c.r.controller.PREDEPOSIT_RULES_VERSION(), 1);
        assertEq(c.staker.PEPE_DNA_VERSION(), 1);
        assertEq(c.registry.PURCHASE_REFERRAL_VERSION(), 1);
        assertEq(c.reinvestor.ATTRIBUTION_VERSION(), 1);
        assertTrue(c.staker.supportsInterface(0x80ac58cd));
        assertEq(c.r.controller.PREDEPOSIT_CAP(), 500e18);
        assertEq(c.r.controller.PREDEPOSIT_CAP_PER_WALLET(), vm.envOr("PSP_WALLET_CAP_MIX", uint256(0)) * 1e18);
        assertEq(c.r.controller.PREDEPOSIT_DURATION(), vm.envOr("PSP_PREDEPOSIT_SEC", uint256(7200)));
        assertEq(c.r.controller.VEST_DURATION(), vm.envOr("PSP_VEST_SEC", uint256(3600)));
        assertEq(c.r.hook.detWindow(), vm.envOr("PSP_DET_SEC", uint256(7200)));
    }

    function _freshGenesis(ReleaseContext memory c) internal returns (uint256 idA, uint256 idB) {
        // These distinct IDs are a pinned collision in the production v2 art
        // decoder. Mint before genesis claims so seeded art cannot occupy them.
        assertTrue(c.staker.isPepeAvailable(4046));
        c.staker.lockWithPepe(0, 4046);
        assertFalse(c.staker.isPepeAvailable(5249));
        vm.expectRevert(PSPStaker.PepeDnaTaken.selector);
        c.staker.lockWithPepe(0, 5249);

        uint256 preview = c.staker.genesisPepeDna(c.a);
        assertTrue(preview != uint256(keccak256(abi.encode(uint256(uint160(c.a))))), "round seed changes address art");
        uint256 deposit = _releaseDeposit(c.r.controller);
        vm.startPrank(c.a);
        c.mix.approve(address(c.r.controller), deposit);
        c.r.controller.predeposit(1);
        (uint256 dustDeposit,) = c.r.controller.predeposits(c.a);
        assertEq(dustDeposit, 1, "public predeposit accepts one wei");
        c.r.controller.predeposit(deposit - 1);
        vm.stopPrank();
        vm.startPrank(c.b);
        c.mix.approve(address(c.r.controller), deposit);
        c.r.controller.predeposit(deposit);
        vm.stopPrank();
        skip(c.r.controller.PREDEPOSIT_DURATION());
        assertEq(c.staker.genesisPepeDna(c.a), preview, "claim delay keeps available preview stable");
        c.r.controller.launchPooledBuy();
        vm.prank(c.a); c.r.controller.claimPredepositPSP();
        idA = c.staker.primaryOf(c.a);
        assertEq(idA, uint256(uint160(c.a)));
        assertEq(c.staker.dnaOf(idA), preview);
        uint256 previewB = c.staker.genesisPepeDna(c.b);
        vm.prank(c.b); c.r.controller.claimPredepositPSP();
        idB = c.staker.primaryOf(c.b);
        assertEq(c.staker.dnaOf(idB), previewB);
        assertTrue(PepeDna.key(preview) != PepeDna.key(previewB), "genesis art stays unique");
        assertTrue(PepeDna.key(preview) != PepeDna.key(c.staker.dnaOf(4046)), "all mint paths share reservations");
        assertEq(uint8(c.r.hook.mode()), uint8(CurveHook.Mode.Active));
    }

    function _individualReinvestAndSafeTransfer(ReleaseContext memory c) internal {
        assertGe(c.staker.pendingFeesOf(c.idA), 0.005e18);
        (uint256 principalBefore,,,,) = c.staker.positions(c.idA);
        uint256 dna = c.staker.dnaOf(c.idA);
        vm.prank(c.a); c.staker.approve(address(c.reinvestor), c.idA);
        assertEq(c.staker.getApproved(c.idA), address(c.reinvestor));
        assertFalse(c.staker.isApprovedForAll(c.a, address(c.reinvestor)));
        vm.expectRevert(PSPReinvestor.Unauthorized.selector);
        c.reinvestor.reinvest(c.idA, c.key, 1, block.timestamp);
        vm.prank(c.a); c.reinvestor.reinvest(c.idA, c.key, 1, block.timestamp);
        (uint256 principalAfter,,,,) = c.staker.positions(c.idA);
        assertGt(principalAfter, principalBefore, "individual approval supports compounding");
        (address leader,,,) = c.r.hook.board(0);
        assertEq(leader, c.a, "compound seats belong to NFT owner");

        ReleaseNonReceiver rejector = new ReleaseNonReceiver();
        vm.prank(c.a);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(rejector)));
        c.staker.safeTransferFrom(c.a, address(rejector), c.idA);
        assertEq(c.staker.ownerOf(c.idA), c.a);
        assertEq(c.staker.getApproved(c.idA), address(c.reinvestor), "rejected transfer preserves approval");
        ReleasePepeReceiver receiver = new ReleasePepeReceiver();
        bytes memory data = abi.encode("fresh release recipient", c.idA);
        vm.prank(c.a); c.staker.safeTransferFrom(c.a, address(receiver), c.idA, data);
        assertEq(c.staker.ownerOf(c.idA), address(receiver));
        assertEq(c.staker.getApproved(c.idA), address(0));
        assertEq(receiver.receivedOperator(), c.a);
        assertEq(receiver.receivedFrom(), c.a);
        assertEq(receiver.receivedId(), c.idA);
        assertEq(receiver.receivedDataHash(), keccak256(data));
        assertEq(c.staker.stakedTotalOf(address(receiver)), principalAfter);
        assertEq(c.staker.stakedTotalOf(c.a), 0);
        receiver.sendBack(c.staker, c.a, c.idA);
        assertEq(c.staker.ownerOf(c.idA), c.a);
        assertEq(c.staker.dnaOf(c.idA), dna, "transfers and reinvestment preserve minted art");
    }

    function _freshReferralReset(ReleaseContext memory c) internal {
        skip(c.r.hook.detonationAt() - block.timestamp);
        c.r.controller.detonate{gas: 1_000_000}();
        c.factory.reserveSpawn(1);
        for (uint256 i; i < 3; ++i) c.factory.birthStep{gas: 12_000_000}();
        assertEq(c.factory.currentRoundId(), 2);
        assertFalse(c.factory.reservationActive());
        PSPFactory.Round memory next = c.factory.getRound(2);
        PSPStaker nextStaker = next.controller.staker();
        PSPReferralRegistry nextRegistry = PSPReferralRegistry(c.factory.referralRegistryOf(2));
        assertTrue(address(nextRegistry) != address(c.registry));
        assertEq(nextRegistry.traderRefNftOf(address(this)), 0, "fresh round clears wallet attribution");
        assertFalse(nextRegistry.attributed(address(this)));
        vm.startPrank(c.b);
        c.mix.approve(address(next.controller), _releaseDeposit(next.controller));
        next.controller.predeposit(_releaseDeposit(next.controller));
        vm.stopPrank();
        skip(next.controller.PREDEPOSIT_DURATION());
        next.controller.launchPooledBuy();
        uint256 preview = nextStaker.genesisPepeDna(c.b);
        vm.prank(c.b); next.controller.claimPredepositPSP();
        uint256 nextIdB = nextStaker.primaryOf(c.b);
        assertEq(nextStaker.dnaOf(nextIdB), preview);
        assertTrue(preview != c.staker.dnaOf(c.idB), "new round has a new art seed");
        c.mix.approve(address(nextRegistry), 0.005e18);
        nextRegistry.buyWithMix(_poolKey(c.mix, next), 0.005e18, 1, block.timestamp, nextIdB);
        assertEq(nextRegistry.traderRefNftOf(address(this)), nextIdB, "next round can bind afresh");
        assertEq(c.registry.traderRefNftOf(address(this)), c.idB, "old round entry stays immutable");
    }

    function _releaseDeposit(RoundController controller) internal view returns (uint256) {
        uint256 cap = controller.PREDEPOSIT_CAP_PER_WALLET();
        return cap == 0 || cap > 50e18 ? 50e18 : cap;
    }

    function _releaseDelay(CurveHook hook) internal view returns (uint256) {
        uint256 halfClock = (hook.detonationAt() - block.timestamp) / 2;
        return halfClock < 30 minutes ? halfClock : 30 minutes;
    }

    function _withdrawAndAssertFees(PSPStaker staker, IERC20 mix, address owner, uint256 id) internal {
        uint256 before = mix.balanceOf(owner);
        vm.prank(owner); staker.withdraw(id);
        assertGt(mix.balanceOf(owner), before, "earned fees paid on withdrawal");
    }

    function _poolKey(IERC20 mix, PSPFactory.Round memory r) internal pure returns (PoolKey memory) {
        Currency c0 = Currency.wrap(address(mix)); Currency c1 = Currency.wrap(address(r.token));
        if (c0 > c1) (c0, c1) = (c1, c0);
        return PoolKey(c0, c1, 0x800000, 60, r.hook);
    }

    function test_DeployedReleaseTwoRoundsAndOldExits() public {
        if (!vm.envOr("PSP_RELEASE_TESTNET", false)) { vm.skip(true); return; }
        assertEq(block.chainid, 84532, "testnet only");
        PSPFactory factory = PSPFactory(vm.envAddress("PSP_FACTORY"));
        PSPZapIn zapIn = PSPZapIn(vm.envAddress("PSP_ZAPIN"));
        PSPZapOut zapOut = PSPZapOut(payable(vm.envAddress("PSP_ZAPOUT")));
        PSPReinvestor reinvestor = PSPReinvestor(vm.envAddress("PSP_REINVESTOR"));
        PSPFactory.Round memory r = factory.getRound(1);
        PSPStaker staker = r.controller.staker();
        IERC20 mix = factory.mixETH();
        address a = makeAddr("release-alice");
        address b = makeAddr("release-bob");
        assertEq(r.hook.MIN_BUY_INPUT(), 0.005e18);
        assertEq(r.hook.TIME_PER_UNIT(), 260);
        assertEq(address(reinvestor.staker()), address(staker));

        IFreeMix(address(mix)).mint(a, 50e18);
        IFreeMix(address(mix)).mint(b, 50e18);
        IFreeMix(address(mix)).mint(address(this), 100e18);
        vm.startPrank(a);
        mix.approve(address(r.controller), _releaseDeposit(r.controller));
        r.controller.predeposit(_releaseDeposit(r.controller));
        vm.stopPrank();
        vm.startPrank(b);
        mix.approve(address(r.controller), _releaseDeposit(r.controller));
        r.controller.predeposit(_releaseDeposit(r.controller));
        vm.stopPrank();
        skip(r.controller.PREDEPOSIT_DURATION());
        r.controller.launchPooledBuy();
        vm.prank(a); r.controller.claimPredepositPSP();
        uint256 idA = staker.primaryOf(a);
        Currency c0 = Currency.wrap(address(mix)); Currency c1 = Currency.wrap(address(r.token));
        if(c0 > c1) (c0,c1)=(c1,c0);
        PoolKey memory key = PoolKey(c0,c1,0x800000,60,r.hook);
        mix.approve(address(zapIn), type(uint256).max);
        uint256 bought = zapIn.buyWithMix(key, 2e18, r.hook.getBuyOutput(2e18), block.timestamp);
        r.token.approve(address(zapOut), bought);
        zapOut.sellToMix(key, bought / 2, 1, block.timestamp);
        assertEq(r.hook.ticketCount(), 400);
        assertGt(staker.pendingFeesOf(0), 0, "unclaimed genesis share keeps fees");
        vm.prank(b); r.controller.claimPredepositPSP();
        uint256 idB = staker.primaryOf(b);
        vm.prank(a); staker.requestWithdraw(idA);
        zapIn.buyWithMix(key, 1e18, 1, block.timestamp);
        uint256 earned = staker.pendingFeesOf(idA);
        assertGt(earned, 0);
        skip(_releaseDelay(r.hook));
        assertEq(staker.pendingFeesOf(idA), earned, "earned credit does not decay");
        vm.startPrank(b);
        staker.setApprovalForAll(address(reinvestor), true);
        reinvestor.reinvest(idB, key, 1, block.timestamp);
        vm.stopPrank();
        skip(r.hook.detonationAt() - block.timestamp);
        r.controller.detonate{gas: 1_000_000}();
        _withdrawAndAssertFees(staker, mix, a, idA);

        factory.reserveSpawn(1);
        for (uint256 i; i < 3; ++i) factory.birthStep{gas: 12_000_000}();
        assertEq(factory.currentRoundId(), 2);
        PSPFactory.Round memory next = factory.getRound(2);
        mix.approve(address(next.controller), 0.005e18);
        next.controller.predeposit(0.005e18);
        skip(next.controller.PREDEPOSIT_DURATION());
        next.controller.launchPooledBuy();
        assertEq(uint8(next.hook.mode()), uint8(CurveHook.Mode.Active));
        assertEq(next.hook.TIME_PER_UNIT(), 260);

        // The new round is active before the old round's final exits.
        vm.prank(b); staker.withdraw(idB);
        address[3] memory holders = [a,b,address(this)];
        for(uint256 i; i < 3; ++i){
            vm.startPrank(holders[i]);
            uint256 balance = r.token.balanceOf(holders[i]);
            r.token.approve(address(r.hook), balance);
            if(balance > 0)r.hook.redeemBacking(balance);
            if(r.hook.claimablePot(holders[i]) > 0)r.hook.claimPot();
            vm.stopPrank();
        }
        // Each public allocation floors its genesis share. Two depositors
        // can leave at most one PSP wei in the unowned virtual position.
        (uint256 genesisDust,,,,) = staker.positions(0);
        assertLe(genesisDust, 1);
        assertEq(staker.totalLocked(), genesisDust);
        assertEq(r.token.totalSupply(), genesisDust);
        if (genesisDust == 0) assertEq(r.hook.reserveMixETH(), 0);
        assertEq(uint8(next.hook.mode()), uint8(CurveHook.Mode.Active));
    }
}
