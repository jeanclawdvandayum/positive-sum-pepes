// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPSPStaker} from "./interfaces/IPSPStaker.sol";

/// @title PSPReferralRegistry — per-round referral attribution keyed by
///        staking NFT IDs
/// @notice Born fresh with EVERY round (factory births one beside each hook),
///         so the referral graph RESETS at round boundaries: every trader
///         re-attributes each round, last round's links are void.
///
///         Attribution binds to a PSPStaker position NFT ID, not an address:
///         `?ref=<tokenId>` is the link format. Chain edges ride the NFT —
///         transfer a position and its referral subtree (the fees its
///         referraees generate) transfers with it. Payouts resolve to the
///         NFT's CURRENT owner at swap time, live.
///
///         One referrer per trader per round — bound ONLY by the trader's
///         own signature: `record(referrerNftId)` with the trader as
///         msg.sender. Swaps can never create attribution (A-1 fix
///         2026-08-28: V4 hookData is attacker-controlled bytes, so the
///         hook only READS the graph via payoutFor — the one-time lazy
///         bind it used to perform from hookData let any direct
///         poolManager.swap caller poison a victim's attribution).
///         Tier walk: the trader's referrer
///         NFT gets tier 1, that NFT's own referrer NFT tier 2, … out to 5
///         hops [80/12/5/2/1]% of the 50bps carve-out. Dead links (burned
///         NFT, unlocked referrer) truncate the walk — unpaid weight flows
///         back to stakers via the hook's subtraction accounting.
///
///         Qualification: the referrer NFT must be alive and its owner must
///         hold >= MIN_STAKE_PSP locked at record time (skin in the game).
///         Genesis predeposit position is never an NFT → can never refer.
///
///         The registry holds NO funds. It is pure attribution + payout
///         math: the CurveHook asks payoutFor(trader) each swap and pays the
///         cuts itself, straight from the taken fee slice.
///
///         Cycle guard: record() walks the referrer NFT's ancestry
///         (<= MAX_DEPTH hops); if the trader's own NFT appears, revert.
///         The payout walk is depth-bounded anyway, so a cycle could never
///         loop gas — the guard only preserves "no one collects two tiers
///         of their own trade's fee".
contract PSPReferralRegistry {
    // ─────────────── Errors ───────────────
    error ZeroAddress();
    error ZeroNftId();
    error SelfReferral();
    error AlreadyReferred();
    error NotQualifiedReferrer(); // NFT dead or owner below MIN_STAKE_PSP
    error WouldCreateCycle();

    // ─────────────── Events ───────────────
    event Referred(address indexed trader, uint256 indexed traderNftId, uint256 indexed referrerNftId);

    // ─────────────── Constants ───────────────
    uint256 public constant MAX_DEPTH = 5;

    /// @dev Tier weights (bps of the referral carve-out): closest referrer
    ///      >= 80%, then monotonically smaller out to the 5th hop.
    ///      [80%, 12%, 5%, 2%, 1%] — D1 dial in the design doc.
    uint24[5] public TIER_BPS = [8000, 1200, 500, 200, 100];

    /// @dev Minimum locked PSP for a referrer NFT's owner (D3 dial). 1,000 PSP.
    uint256 public immutable MIN_STAKE_PSP;

    // ─────────────── State ───────────────
    IPSPStaker public immutable staker; // this round's staker (min-stake oracle)
    /// @dev NFT → referrer NFT. Chain edges ride the token: transfer the
    ///      position and the subtree follows. Set when the NFT's owner
    ///      records their own attribution while holding it.
    mapping(uint256 => uint256) public nftRefOf;
    /// @dev Trader → referrer NFT for traders holding no NFT at record time.
    ///      Terminal entry: nothing walks THROUGH a trader slot (walks only
    ///      follow nftRefOf), so these edges cannot create cycles.
    mapping(address => uint256) public traderRefNftOf;
    /// @dev One attribution per trader per round — the graph resets by
    ///      rebirth, this flag enforces one record per round.
    mapping(address => bool) public attributed;

    // ─────────────── Constructor ───────────────

    constructor(address _staker, uint256 _minStakePSP) {
        if (_staker == address(0)) revert ZeroAddress();
        if (_minStakePSP == 0) revert ZeroAddress();
        staker = IPSPStaker(_staker);
        MIN_STAKE_PSP = _minStakePSP;
    }

    // ─────────────── Attribution ───────────────

    /// @notice Self-registration: "I was referred by the holder of position
    ///         `referrerNftId`." One shot per round. The frontend's
    ///         ?ref=<tokenId> capture ends here — this is the ONLY way
    ///         attribution is created, and it binds msg.sender directly, so
    ///         no third party (router, direct pool swapper) can ever bind or
    ///         burn a trader's attribution (A-1 fix 2026-08-26).
    function record(uint256 referrerNftId) external {
        _record(msg.sender, referrerNftId);
    }

    function _record(address trader, uint256 referrerNftId) internal {
        if (trader == address(0)) revert ZeroAddress();
        if (referrerNftId == 0) revert ZeroNftId();
        if (attributed[trader]) revert AlreadyReferred();

        // Skin in the game: the referrer NFT must be alive and its owner
        // must hold >= MIN_STAKE_PSP locked. Checked at record time only
        // (D4): the edge persists even if the referrer later unlocks — the
        // NFT burns, the walk truncates, unpaid weight goes to stakers.
        if (!_qualified(referrerNftId)) revert NotQualifiedReferrer();

        // The trader's own position NFT (0 if they stake none yet).
        uint256 traderNftId = staker.tokenOf(trader);
        if (traderNftId == referrerNftId) revert SelfReferral();

        // Cycle guard: walk the referrer NFT's ancestry; the trader's own
        // NFT must not appear. MAX_DEPTH bounds gas.
        uint256 node = referrerNftId;
        for (uint256 i = 0; i < MAX_DEPTH; i++) {
            node = _nextEdge(node);
            if (node == 0) break;
            if (node == traderNftId) revert WouldCreateCycle();
        }

        attributed[trader] = true;
        // Entry edge for payout resolution (always written).
        traderRefNftOf[trader] = referrerNftId;
        // Chain edge when the trader holds a position: whoever walks through
        // this trader's NFT continues to the trader's referrer. Rides the
        // token through transfers.
        if (traderNftId != 0) {
            nftRefOf[traderNftId] = referrerNftId;
        }
        emit Referred(trader, traderNftId, referrerNftId);
    }

    function _qualified(uint256 nftId) internal view returns (bool) {
        address nftOwner = _ownerOf(nftId);
        if (nftOwner == address(0)) return false; // dead/burned NFT
        if (nftOwner == address(staker)) return false; // genesis slot: never a referrer
        return staker.lockedPSPOf(nftOwner) >= MIN_STAKE_PSP;
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
    ///         the walk — missing tiers' weight is NOT paid and flows back
    ///         to stakers by the hook's subtraction accounting (D2).
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
            // at most ONE tier per trade; skipped weight flows to stakers.
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

    /// @dev The trader's entry edge: their position NFT's edge if they hold
    ///      one, else their personal trader-slot edge.
    function _entryOf(address trader) internal view returns (uint256) {
        uint256 traderNftId = staker.tokenOf(trader);
        if (traderNftId != 0) return _nextEdge(traderNftId);
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
