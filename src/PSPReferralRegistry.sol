// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title PSPReferralRegistry — permanent, cross-round referral attribution
/// @notice One address, one referrer, forever. Set once at a trader's first
///         attributed action (lazy via the canonical zaps' hookData, or an
///         explicit self-call); never changed, never removed. Rounds come and
///         go — the social graph persists.
///
///         The registry holds NO funds. It is pure attribution + payout
///         math: the CurveHook asks payoutFor(trader) each swap and pays the
///         cuts itself, straight from the taken input.
///
///         Qualification: a referrer must hold >= MIN_STAKE_PSP locked in the
///         CURRENT round's staker at record time (skin in the game). Links are
///         pure frontend (`?ref=0x…`); the chain only enforces attribution.
///
///         Cycle guard: attribution is one-time-set, so the graph is a forest
///         by construction — except the A⇄B case (both unattributed at record
///         time). record() walks the referrer's ancestry (<= MAX_DEPTH hops);
///         if the trader appears, revert. Bounded gas, total guard.
contract PSPReferralRegistry {
    // ─────────────── Errors ───────────────
    error ZeroAddress();
    error SelfReferral();
    error AlreadyReferred();
    error NotQualifiedReferrer(); // referrer below MIN_STAKE_PSP at record time
    error WouldCreateCycle();
    error NotAuthorized();        // msg.sender may not record for this trader
    error NotOwner();

    // ─────────────── Events ───────────────
    event Referred(address indexed trader, address indexed referrer);
    event StakerUpdated(address indexed oldStaker, address indexed newStaker);
    event RecorderAuthorized(address indexed recorder, bool allowed);

    // ─────────────── Constants ───────────────
    uint256 public constant MAX_DEPTH = 5;

    /// @dev Tier weights (bps of the referral carve-out): closest referrer
    ///      >= 80%, then monotonically smaller out to the 5th hop.
    ///      [80%, 12%, 5%, 2%, 1%] — D1 dial in the design doc.
    uint24[5] public TIER_BPS = [8000, 1200, 500, 200, 100];

    /// @dev Minimum locked PSP to be a referrer (D3 dial). 1,000 PSP.
    uint256 public immutable MIN_STAKE_PSP;

    // ─────────────── State ───────────────
    address public owner;
    address public staker; // current round's PSPStaker (min-stake oracle)
    mapping(address => address) public referrerOf;
    mapping(address => bool) public authorizedRecorders; // hooks + zaps of each round

    // ─────────────── Constructor ───────────────
    constructor(uint256 _minStakePSP) {
        if (_minStakePSP == 0) revert ZeroAddress();
        owner = msg.sender;
        MIN_STAKE_PSP = _minStakePSP;
    }

    // ─────────────── Admin (factory) ───────────────
    function setStaker(address _staker) external {
        if (msg.sender != owner) revert NotOwner();
        emit StakerUpdated(staker, _staker);
        staker = _staker;
    }

    function setRecorder(address recorder, bool allowed) external {
        if (msg.sender != owner) revert NotOwner();
        authorizedRecorders[recorder] = allowed;
        emit RecorderAuthorized(recorder, allowed);
    }

    // ─────────────── Attribution ───────────────

    /// @notice Explicit self-registration: "I was referred by `referrer`."
    ///         One shot. The frontend's ?ref= capture ends here on the user's
    ///         first wallet interaction if not recorded lazily by a swap.
    function record(address referrer) external {
        _record(msg.sender, referrer);
    }

    /// @notice Lazy registration by a trusted recorder (canonical zaps via the
    ///         hook's hookData decode). The trader identity is the zap's
    ///         caller — a malicious recorder can burn its own users'
    ///         attribution, but a malicious router can already steal from its
    ///         users; the chain cannot outrun that trust boundary (D6/D7).
    function recordFor(address trader, address referrer) external {
        if (!authorizedRecorders[msg.sender]) revert NotAuthorized();
        _record(trader, referrer);
    }

    function _record(address trader, address referrer) internal {
        if (trader == address(0) || referrer == address(0)) revert ZeroAddress();
        if (trader == referrer) revert SelfReferral();
        if (referrerOf[trader] != address(0)) revert AlreadyReferred();

        // Skin in the game: referrer must currently hold >= MIN_STAKE_PSP locked.
        // Checked at record time only (D4): the chain persists even if the
        // referrer later unlocks — rewriting history would cost more trust
        // than it saves.
        if (!_qualified(referrer)) revert NotQualifiedReferrer();

        // Cycle guard (A⇄B case): walk the referrer's ancestry; the trader
        // must not appear. MAX_DEPTH bounds gas; deeper repeats are
        // unreachable because attribution is one-time-set.
        address node = referrer;
        for (uint256 i = 0; i < MAX_DEPTH; i++) {
            node = referrerOf[node];
            if (node == address(0)) break;
            if (node == trader) revert WouldCreateCycle();
        }

        referrerOf[trader] = referrer;
        emit Referred(trader, referrer);
    }

    function _qualified(address who) internal view returns (bool) {
        if (staker == address(0)) return false;
        (bool ok, bytes memory data) = staker.staticcall(
            abi.encodeWithSelector(bytes4(0x2fe3ea38)) // lockedPSPOf(address)
        );
        return ok && data.length >= 32 && abi.decode(data, (uint256)) >= MIN_STAKE_PSP;
    }

    // ─────────────── Payout view ───────────────

    /// @notice Everything the hook needs to split the referral carve-out:
    ///         up to 5 ancestors (closest first) and their tier weights.
    ///         Zero-padded; missing tiers' weight is NOT paid and flows back
    ///         to stakers by the hook's subtraction accounting (D2).
    function payoutFor(address trader)
        external
        view
        returns (address[5] memory who, uint24[5] memory bps)
    {
        address node = referrerOf[trader];
        for (uint256 i = 0; i < MAX_DEPTH && node != address(0); i++) {
            who[i] = node;
            bps[i] = TIER_BPS[i];
            node = referrerOf[node];
        }
    }

    /// @notice Frontend link-eligibility view.
    function canRefer(address who) external view returns (bool) {
        return _qualified(who);
    }

    /// @notice Full chain for UIs, closest first.
    function chainOf(address trader)
        external
        view
        returns (address[5] memory who, uint256 depth)
    {
        address node = referrerOf[trader];
        for (uint256 i = 0; i < MAX_DEPTH && node != address(0); i++) {
            who[i] = node;
            depth++;
            node = referrerOf[node];
        }
    }
}
