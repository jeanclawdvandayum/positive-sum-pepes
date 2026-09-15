// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPSPStaker} from "./interfaces/IPSPStaker.sol";
import {IRoundController} from "./interfaces/IRoundController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @dev Read-only wiring; avoids importing concrete contracts into the registry.
interface IReferralStaker { function controller() external view returns (IRoundController); }
interface IReferralHook {
    function poolManager() external view returns (IPoolManager);
    function referralRegistry() external view returns (address);
}


/// @title PSPReferralRegistry — per-round referral attribution keyed by
///        staking NFT IDs
/// @notice Born fresh with EVERY round (factory births one beside each hook),
///         so the referral graph RESETS at round boundaries: every trader
///         re-attributes each round, last round's links are void.
///
///         Attribution binds to a PSPStaker position NFT ID, not an address:
///         Links carry ref=<tokenId>, refRegistry and refChain. Chain edges ride the NFT —
///         transfer a position and its referral subtree (the fees its
///         referees generate) transfers with it. Payouts resolve to the
///         NFT's CURRENT owner at swap time. Earned mixETH stays claimable
///         by that wallet after NFT transfers and after the round ends.
///
///         AUD-15: a buyer can record the link and buy PSP in ONE signed
///         buyWithMix transaction. Both paths bind msg.sender only. Raw V4
///         hookData remains a payout hint and cannot create attribution.
///         A recorded wallet entry takes precedence over acquired NFTs for
///         the entire round. NFT ancestry is written once; payouts follow
///         current NFT owners across up to five deduplicated tiers.
///
///         Purchases transfer mixETH directly from the caller to V4 and take
///         PSP directly to the caller. Only credited referral rewards remain
///         in the registry; purchase principal passes directly to V4.
///         An invalid/ineligible link is skipped; a failed purchase rolls back
///         new attribution, fees and token movements together.
contract PSPReferralRegistry is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;
    // ─────────────── Errors ───────────────
    error ZeroAddress();
    error ZeroNftId();
    error SelfReferral();
    error AlreadyReferred();
    error NotQualifiedReferrer(); // NFT dead or owner below MIN_STAKE_PSP
    error WouldCreateCycle();
    error BadPool();
    error BadAmount();
    error Expired();
    error InsufficientOutput();
    error UnauthorizedCallback();
    error UnauthorizedRewardCredit();
    error UnbackedRewards();
    error NothingToClaim();

    // ─────────────── Events ───────────────
    event Referred(address indexed trader, uint256 indexed traderNftId, uint256 indexed referrerNftId);

    event ReferralSkipped(address indexed trader, uint256 indexed referrerNftId, bytes4 reason);
    event ReferralRewardsCredited(address indexed recipient, uint256 amount);
    event ReferralRewardsClaimed(address indexed recipient, uint256 amount);

    // ─────────────── Constants ───────────────
    uint256 public constant MAX_DEPTH = 5;
    /// @notice Atomic purchase binding and immutable wallet-entry semantics.
    uint256 public constant PURCHASE_REFERRAL_VERSION = 1;
    /// @notice Referral rewards accrue here and are claimed separately from lePSP fees.
    uint256 public constant REFERRAL_REWARDS_VERSION = 1;

    struct Purchase {
        PoolKey key;
        uint256 mixIn;
        uint256 minPspOut;
        address buyer;
        bool mixIsZero;
        uint256 maxTicketPrice; // v3 ticket-intent guard; 0 = unguarded
    }
    address private activeManager;
    bytes32 private activePurchase;

    /// @dev Tier weights (bps of the referral carve-out): closest referrer
    ///      >= 80%, then monotonically smaller out to the 5th hop.
    ///      [80%, 12%, 5%, 2%, 1%] — D1 dial in the design doc.
    uint24[5] public TIER_BPS = [8000, 1200, 500, 200, 100];

    /// @dev Minimum locked PSP for a referrer NFT's owner (D3 dial). 1,000 PSP.
    uint256 public immutable MIN_STAKE_PSP;

    // ─────────────── State ───────────────
    IPSPStaker public immutable staker; // this round's staker (min-stake oracle)
    /// @dev NFT → referrer NFT, written once. Chain edges ride the token: transfer the
    ///      position and the subtree follows. Set when the NFT's owner
    ///      records their own attribution while holding it.
    mapping(uint256 => uint256) public nftRefOf;
    /// @dev Trader → immutable referrer NFT, whether or not the trader holds an NFT.
    ///      Also provides ancestry for later-minted NFTs until a token edge
    ///      exists. Both record-time checks and payout walks are depth-bounded.
    mapping(address => uint256) public traderRefNftOf;
    /// @dev One attribution per trader per round — the graph resets by
    ///      rebirth, this flag enforces one record per round.
    mapping(address => bool) public attributed;
    /// @notice Earned mixETH belongs to the wallet that owned the referral NFT at accrual.
    mapping(address => uint256) public claimableReferral;
    /// @notice Sum of all unpaid referral balances, backed by this registry's mixETH.
    uint256 public totalReferralOutstanding;

    // ─────────────── Constructor ───────────────

    constructor(address _staker, uint256 _minStakePSP) {
        if (_staker == address(0)) revert ZeroAddress();
        if (_minStakePSP == 0) revert ZeroAddress();
        staker = IPSPStaker(_staker);
        MIN_STAKE_PSP = _minStakePSP;
    }

    // ─────────────── Referral rewards ───────────────

    /// @notice Credit funded tier rewards. Only this round's hook can allocate them.
    /// @dev The hook transfers the aggregate mixETH before this call. This callback
    ///      also runs inside buyWithMix while its nonReentrant guard is held, so it
    ///      uses hook authentication instead of taking that guard a second time.
    function creditReferralRewards(address[5] calldata recipients, uint256[5] calldata amounts) external {
        IRoundController ctl = IReferralStaker(address(staker)).controller();
        if (msg.sender != ctl.hookAddress()) revert UnauthorizedRewardCredit();
        uint256 total;
        for (uint256 i; i < MAX_DEPTH; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            if (recipients[i] == address(0)) revert ZeroAddress();
            total += amount;
            claimableReferral[recipients[i]] += amount;
            emit ReferralRewardsCredited(recipients[i], amount);
        }
        totalReferralOutstanding += total;
        if (IERC20(Currency.unwrap(ctl.getMixETH())).balanceOf(address(this)) < totalReferralOutstanding) {
            revert UnbackedRewards();
        }
    }

    /// @notice Claim all of your earned referral mixETH. Claims stay open after detonation.
    /// @dev Effects precede transfer. A failed payout reverts the balance changes.
    function claimReferralRewards() external nonReentrant {
        uint256 amount = claimableReferral[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimableReferral[msg.sender] = 0;
        totalReferralOutstanding -= amount;
        IRoundController ctl = IReferralStaker(address(staker)).controller();
        IERC20(Currency.unwrap(ctl.getMixETH())).safeTransfer(msg.sender, amount);
        emit ReferralRewardsClaimed(msg.sender, amount);
    }

    // ─────────────── Attribution ───────────────

    /// @notice Optional direct self-registration. Purchases can bind the
    ///         same entry atomically through buyWithMix instead.
    function record(uint256 referrerNftId) external nonReentrant {
        bytes4 reason = _referralError(msg.sender, referrerNftId);
        if (reason != bytes4(0)) {
            assembly ("memory-safe") { mstore(0, reason) revert(0, 4) }
        }
        _record(msg.sender, referrerNftId);
    }

    /// @notice Buy PSP and bind an eligible referral with the buyer's single
    ///         purchase signature. Zero skips attribution; an existing entry wins.
    /// @param referrerNftId The referring pepe in THIS registry's round, or zero.
    /// @dev AUD-15: no trader argument, delegated recorder, tx.origin or trusted
    ///      hookData. Only msg.sender's funds and attribution are affected.
    function buyWithMix(
        PoolKey calldata key, uint256 mixIn, uint256 minPspOut,
        uint256 deadline, uint256 referrerNftId
    ) external nonReentrant returns (uint256 pspOut) {
        return _buyWithMix(key, mixIn, minPspOut, deadline, referrerNftId, 0);
    }

    /// @notice Guarded referral purchase: also reverts (TicketPriceMoved,
    ///         wrapped by V4) if the round's ticket price rose past the
    ///         quoted bound — the ticket count a quote showed stays honest.
    function buyWithMixGuarded(
        PoolKey calldata key, uint256 mixIn, uint256 minPspOut,
        uint256 deadline, uint256 referrerNftId, uint256 maxTicketPrice
    ) external nonReentrant returns (uint256 pspOut) {
        return _buyWithMix(key, mixIn, minPspOut, deadline, referrerNftId, maxTicketPrice);
    }

    function _buyWithMix(
        PoolKey calldata key, uint256 mixIn, uint256 minPspOut,
        uint256 deadline, uint256 referrerNftId, uint256 maxTicketPrice
    ) internal returns (uint256 pspOut) {
        if (mixIn == 0 || mixIn > uint256(uint128(type(int128).max))) revert BadAmount();
        if (deadline != 0 && block.timestamp > deadline) revert Expired();
        IRoundController ctl = IReferralStaker(address(staker)).controller();
        address mix = Currency.unwrap(ctl.getMixETH());
        address psp = ctl.getPSP();
        bool mixIsZero = Currency.unwrap(key.currency0) == mix;
        if (address(key.hooks) != ctl.hookAddress() ||
            IReferralHook(address(key.hooks)).referralRegistry() != address(this) ||
            Currency.unwrap(mixIsZero ? key.currency1 : key.currency0) != psp ||
            Currency.unwrap(mixIsZero ? key.currency0 : key.currency1) != mix ||
            key.fee != 0x800000 || key.tickSpacing != 60) revert BadPool();

        if (referrerNftId != 0 && !attributed[msg.sender]) {
            bytes4 reason = _referralError(msg.sender, referrerNftId);
            if (reason == bytes4(0)) _record(msg.sender, referrerNftId);
            else emit ReferralSkipped(msg.sender, referrerNftId, reason);
        }
        IPoolManager manager = IReferralHook(address(key.hooks)).poolManager();
        bytes memory data = abi.encode(Purchase(key, mixIn, minPspOut, msg.sender, mixIsZero, maxTicketPrice));
        activeManager = address(manager);
        activePurchase = keccak256(data);
        pspOut = abi.decode(manager.unlock(data), (uint256));
        activeManager = address(0);
        activePurchase = bytes32(0);
    }

    /// @notice V4 callback, accepted only for the purchase currently in flight.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != activeManager || activePurchase == bytes32(0) ||
            keccak256(data) != activePurchase) revert UnauthorizedCallback();
        activePurchase = bytes32(0); // consume before external token calls
        Purchase memory p = abi.decode(data, (Purchase));
        IPoolManager manager = IPoolManager(msg.sender);
        Currency mix = p.mixIsZero ? p.key.currency0 : p.key.currency1;
        manager.sync(mix);
        IERC20(Currency.unwrap(mix)).safeTransferFrom(p.buyer, msg.sender, p.mixIn);
        manager.settle();
        BalanceDelta delta = manager.swap(p.key, SwapParams({
            amountSpecified: -int256(p.mixIn),
            sqrtPriceLimitX96: p.mixIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            zeroForOne: p.mixIsZero
        }), p.maxTicketPrice != 0 ? abi.encode(p.buyer, p.maxTicketPrice) : abi.encode(p.buyer));
        int256 output = p.mixIsZero ? delta.amount1() : delta.amount0();
        if (output <= 0 || uint256(output) < p.minPspOut) revert InsufficientOutput();
        manager.take(p.mixIsZero ? p.key.currency1 : p.key.currency0, p.buyer, uint256(output));
        return abi.encode(uint256(output));
    }

    function _referralError(address trader, uint256 referrerNftId) internal view returns (bytes4) {
        if (referrerNftId == 0) return ZeroNftId.selector;
        if (attributed[trader]) return AlreadyReferred.selector;
        if (!_qualified(referrerNftId)) return NotQualifiedReferrer.selector;
        // All NFTs owned by the buyer are self-referrals, including non-primary ones.
        if (_ownerOf(referrerNftId) == trader) return SelfReferral.selector;
        uint256 node = referrerNftId;
        for (uint256 i = 0; i < MAX_DEPTH; i++) {
            node = _nextEdge(node);
            if (node == 0) break;
            if (_ownerOf(node) == trader) return WouldCreateCycle.selector;
        }
        return bytes4(0);
    }

    function _record(address trader, uint256 referrerNftId) internal {
        uint256 traderNftId = staker.primaryOf(trader);
        attributed[trader] = true;
        traderRefNftOf[trader] = referrerNftId;
        // A transferred NFT retains its original ancestry. A new owner's
        // personal entry must never overwrite another wallet's token edge.
        if (traderNftId != 0 && nftRefOf[traderNftId] == 0) nftRefOf[traderNftId] = referrerNftId;
        emit Referred(trader, traderNftId, referrerNftId);
    }

    function _qualified(uint256 nftId) internal view returns (bool) {
        address nftOwner = _ownerOf(nftId);
        if (nftOwner == address(0)) return false; // dead/burned NFT
        if (nftOwner == address(staker)) return false; // genesis slot: never a referrer
        return staker.stakedTotalOf(nftOwner) >= MIN_STAKE_PSP;
    }

    function _ownerOf(uint256 nftId) internal view returns (address) {
        (bool ok, bytes memory data) =
            address(staker).staticcall(abi.encodeWithSignature("ownerOf(uint256)", nftId));
        if (!ok || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    // ─────────────── Payout view ───────────────

    /// @notice Everything the hook needs to split the referral carve-out:
    ///         up to 5 tiers, each the CURRENT owner of an NFT in the
    ///         trader's referrer chain (closest first), with tier weights.
    ///         Zero-padded; a dead NFT (burned after attribution) truncates
    ///         the walk. The hook routes the unpaid part of the referral leg
    ///         through its pot/deployer fee accounting.
    function payoutFor(address trader)
        external
        view
        returns (address[5] memory who, uint24[5] memory bps)
    {
        uint256 node = _entryOf(trader);
        for (uint256 i = 0; i < MAX_DEPTH && node != 0; i++) {
            address nodeOwner = _ownerOf(node);
            if (nodeOwner == address(0)) break; // NFT burned since attribution
            // Owner dedupe (fixed 2026-08-19): a transferred NFT can make the
            // trader (or anyone) own multiple nodes of their own chain —
            // without this check one address stacked ALL five tier weights
            // (the walk self-looped ownerOf→same owner). Each address collects
            // at most ONE tier per trade; skipped weight flows to the pot.
            bool seen;
            for (uint256 j = 0; j < i; j++) {
                if (who[j] == nodeOwner) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                who[i] = nodeOwner;
                bps[i] = TIER_BPS[i];
            }
            node = _nextEdge(node);
        }
    }

    /// @dev Edge resolution, node → next referrer NFT. Token-carried edge
    ///      first (set when the owner attributed while holding this NFT —
    ///      rides the token through transfers); else the CURRENT owner's
    ///      personal attribution. The fallback is what makes chains built
    ///      "buy-then-lock" (the natural flow: attribution fires on the
    ///      first trade, the referrer stakes afterwards) resolve to full
    ///      depth instead of dying at tier 1.
    function _nextEdge(uint256 nftId) internal view returns (uint256) {
        uint256 edge = nftRefOf[nftId];
        if (edge != 0) return edge;
        return traderRefNftOf[_ownerOf(nftId)];
    }

    /// @dev AUD-15: the signed wallet entry is authoritative for this round.
    ///      Buying/transferring/changing a primary NFT cannot replace it or
    ///      silently attribute a wallet that has never recorded a referral.
    function _entryOf(address trader) internal view returns (uint256) {
        return traderRefNftOf[trader];
    }

    // ─────────────── Frontend views ───────────────

    /// @notice Link-eligibility view: is position `nftId` a valid referrer
    ///         target right now? (`?ref=<tokenId>` gating is client-side.)
    function canReferNft(uint256 nftId) external view returns (bool) {
        return _qualified(nftId);
    }

    /// @notice Full chain for UIs, closest first, as NFT IDs.
    function chainOf(address trader)
        external
        view
        returns (uint256[5] memory nfts, uint256 depth)
    {
        uint256 node = _entryOf(trader);
        for (uint256 i = 0; i < MAX_DEPTH && node != 0; i++) {
            nfts[i] = node;
            depth++;
            node = _nextEdge(node);
        }
    }
}
