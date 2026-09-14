// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Utils} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Utils.sol";

import {ICurveHook} from "./interfaces/ICurveHook.sol";
import {IRoundController} from "./interfaces/IRoundController.sol";
import {PepeDna} from "./libraries/PepeDna.sol";

/// @dev Minimal descriptor slice (EIP-170 budget): metadata + SVG from DNA.
interface IPepeDescriptor {
    function tokenURI(uint256 dna) external pure returns (string memory);
}

/// @title PSPStaker — epoch-point staking with InfiniFi-style linear unwinding.
/// @notice Design (after InfiniFi-Labs/infinifi-protocol `UnwindingModule`):
///         All dividend weight lives in a lazily-checkpointed global
///         point {weight, slope}. UPWARD weight changes (stake, top-up,
///         cancel, genesis lock) land INSTANTLY via direct point correction
///         (scoopy 2026-08-28b: a fresh stake earns on the subsequent trade —
///         no next-epoch activation wait). DOWNWARD changes stay epoch-
///         aligned: a withdraw request arms a 6-epoch linear decay (veCRV
///         bias + slope) — full weight through the request epoch, then
///         5/6, 4/6, … 0 at each boundary — implemented as per-epoch slope
///         deltas. Accepted trade: front-running a known fee event with
///         stake capital (JIT-LP style) earns that event's pro-rata share.
///         (The vote-weight overlay died with governance — CLOCK-REDESIGN
///         §4, 2026-09-01; this is a pure fee engine now.)
///
///         Fee credits are NOT epoch-based (2026-08-28 redesign, scoopy's
///         must-fix): a single monotonic `creditPerWeight` accumulator is
///         advanced the instant fees arrive — `delta = fees * 1e30 /
///         totalWeight` — and positions claim their integral of weight times credit
///         increments live, without waiting for an epoch boundary.
///         Each feed splits at the total weight live at that instant, so
///         same-instant weight/fee interleavings are exact; positions settle
///         before any weight mutation, so nothing is credited retroactively.
///         RS-1: sparse fee-epoch checkpoints preserve earned fees during
///         withdrawal. Static positions settle in O(1); decaying positions
///         read at most six epoch intervals. Claims are never epoch-gated.
contract PSPStaker is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────── Interfaces ───────────────

    // ─────────────── Errors ───────────────
    error ZeroAmount();
    error NotLocker();
    error RoundDead();
    error NothingToClaim();
    error NotNftOwner();
    error NotAuthorizedNft();
    error ZeroAddress();
    error NotController();
    error BadNftTransfer();
    error BadPepeId();       // chosen-id path: zero or already owned
    error PepeDnaTaken();    // another NFT already has this v2 trait combination
    error PepeArtExhausted();
    error UnsupportedArtVersion();
    error RequestActive();   // stake/top-up while decaying — cancel first
    error NotDecaying();     // cancel/withdraw without an active request
    error VestNotComplete(); // withdraw before the decay ran out
    error BadOwnerIndex();   // enumeration out of range

    // ─────────────── Events ───────────────
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    event Locked(address indexed user, uint256 indexed pepeId, uint256 amount);
    event WithdrawRequested(address indexed user, uint256 indexed pepeId);
    event WithdrawCancelled(address indexed user, uint256 indexed pepeId);
    event Withdrawn(address indexed user, uint256 indexed pepeId, uint256 amount);
    event FeesClaimed(address indexed user, uint256 indexed pepeId, uint256 amount);
    event FeesDeferred(address indexed user, uint256 indexed pepeId, uint256 mixETHAmount);
    event FeesCredited(uint256 amount, uint256 creditPerWeightAfter);

    // ─────────────── Epoch-point core state ───────────────

    /// @dev Global dividend/voting weight, checkpointed lazily. `epoch` is the
    ///      epoch the point describes; a stored point at e is authoritative
    ///      for that epoch (walkers prefer it — corrections propagate).
    struct GlobalPoint {
        uint256 epoch;   // epoch this point describes (0 = virtual/empty)
        uint256 weight;  // total live weight during `epoch`
        uint256 slope;   // per-epoch weight decrease (sum of active decays)
    }

    struct Position {
        uint256 amount;          // principal PSP
        uint256 startEpoch;      // weight live immediately from this epoch
        uint256 requestEpoch;    // decay armed at E; isWithdrawing distinguishes epoch zero from no request
        uint256 creditCheckpoint; // creditPerWeight at last settle (claims are O(1) deltas)
        uint256 feesPaid;        // cumulative fees paid out
    }

    /// @dev pepeId-keyed: one position per NFT, many NFTs per user.
    ///      tokenId 0 = the genesis virtual position (predeposit pool).
    mapping(uint256 => Position) public positions;
    // Explicit flag: epoch zero is a valid withdrawal-request epoch.
    mapping(uint256 => bool) public isWithdrawing;

    mapping(uint256 => GlobalPoint) public points; // epoch => point
    uint256 public lastPointEpoch;                 // latest stored point
    /// @dev disambiguates the anchor state: epoch 0 is a REAL epoch (any
    ///      block with ts < epochSize — foundry ts≈1, a fresh chain's first
    ///      days), so `lastPointEpoch == 0` alone cannot signal "never
    ///      anchored" (2026-08-30 fix: an epoch-0 first write used to leave
    ///      the sentinel armed, and the next write-side call re-anchored at
    ///      the CURRENT epoch with weight 0 — silently wiping all staked
    ///      weight and panicking later flat-path withdraws).
    bool public anchored;

    // per-epoch deltas, applied when advancing epoch e -> e+1:
    mapping(uint256 => uint256) public biasAdd;  // +weight (stakes, cancels)
    mapping(uint256 => uint256) public biasSub;  // -weight (withdraws, dust)
    mapping(uint256 => uint256) public slopeAdd; // +slope (requests)
    mapping(uint256 => uint256) public slopeSub; // -slope (decay completion)

    // ─────────────── Fee credit accumulator ───────────────
    /// @dev Live accumulator. Sparse epoch boundaries preserve the historical
    ///      weight applied to each fee increment without delaying claims.
    uint256 public creditPerWeight;
    uint256 public constant CREDIT_PRECISION = 1e30;

    uint256 public pendingFeesMixETH; // orphaned (zero-weight) fees + rolling remainder
    uint256 public totalLocked;       // Σ principal (display)

    struct FeeEpoch { uint256 epoch; uint256 creditBefore; }
    FeeEpoch[] private feeEpochs;
    mapping(uint256 => uint256) public accruedFees;
    mapping(uint256 => uint256) private feeRemainder;
    uint256 public totalFeesReceived;
    uint256 public totalFeesPaid;

    /// @dev decay steps per vest window: weight(e) = base - k·slope, k = e - requestEpoch
    uint256 public constant VEST_EPOCHS = 6;

    // ─────────────── Governance weight — REMOVED (CLOCK-REDESIGN §4) ───────────────
    // totalVotable / totalVotableWeight / voteWeight / pepeVoteWeight /
    // _votableAt / Position.actionTime died with the carpet vote: they
    // existed solely for quorum + the prisoner's-dilemma commitment, and
    // the detonation clock needs none of them. The staker keeps the weight
    // views FEES need (weightAt / biasOf / totalWeight / pendingFeesOf).

    // ─────────────── Immutables ───────────────
    IERC20 public immutable psp;
    IRoundController public immutable controller;

    /// @dev epoch length = VEST_DURATION / 6 (default 28d → 4d 16h; playtests can shorten it).
    ///      Read lazily from the controller — the staker is deployed during
    ///      the controller's OWN constructor (finding 47: counterparty has no
    ///      code yet), so no eager VEST_DURATION read at construction.
    function epochSize() public view returns (uint256) {
        return controller.VEST_DURATION() / VEST_EPOCHS;
    }

    // ─────────────── ERC-721 state ───────────────
    string public constant name = "Positive Sum Pepe Position";
    string public constant symbol = "PSPP";
    /// @notice Full safe-transfer and individual transfer/fee approval support.
    uint256 public constant NFT_INTERFACE_VERSION = 1;
    uint256 public nextTokenId = 1;
    mapping(uint256 => address) private _ownerOf;
    // AUD-19: contiguous minted runs store end at start and start at end.
    // NFTs never burn, so merging neighboring runs needs two boundary reads
    // and writes. Fresh IDs stay sequential without an owner-controlled scan.
    mapping(uint256 => uint256) private _mintedRunBoundary;
    mapping(address => uint256[]) private _owned;
    // AUD-21: referral qualification must not scan unsolicited empty NFTs.
    // Principal follows ownership; virtual genesis is credited only on claim.
    mapping(address => uint256) private _stakedByOwner;
    mapping(uint256 => uint256) private _ownedIndex; // id => position in _owned
    mapping(address => mapping(address => bool)) private _operator;
    mapping(uint256 => address) private _tokenApproval;

    // ─────────────── Pepe art state ───────────────
    /// @dev PepeDescriptor (SVG + metadata), wired at construction via the
    ///      factory. Zero = this round carries no art (tokenURI is empty).
    address public immutable descriptor;

    // PD-2: immutable art per NFT. A hash's unused bits and modulo aliases
    // cannot mint duplicate v2 trait combinations. Transfers/withdrawals never
    // release art. Contiguous used-art runs maintain the first free key in
    // constant storage work, so collisions cannot force a claim to scan mints.
    mapping(uint256 => uint256) private _mintedDna;
    mapping(uint256 => uint256) private _artToken;
    mapping(uint256 => address) public reservedPepeOwner;
    mapping(uint256 => uint256) private _artRunBoundary;
    uint256 private _nextArtKey = 1;
    uint256 public immutable PEPE_DNA_VERSION;
    uint256 private immutable _artCombinations;
    /// @dev Cosmetic pseudorandomness, frozen per round so waiting to claim
    /// cannot reroll art. Block producers/deployers can influence this seed;
    /// it never controls principal, fee weights or rewards.
    bytes32 private immutable _genesisArtSeed;

    constructor(IERC20 _psp, IRoundController _controller, address descriptor_) {
        if (address(_psp) == address(0)) revert ZeroAddress();
        if (address(_controller) == address(0)) revert ZeroAddress();
        psp = _psp;
        controller = _controller;
        descriptor = descriptor_;
        // A round freezes its renderer and matching collision codec together.
        // Legacy descriptors have no version getter. Unknown versions fail closed.
        (bool ok, bytes memory data) = descriptor_.staticcall(abi.encodeWithSignature("ART_VERSION()"));
        uint256 version = ok && data.length == 32 ? abi.decode(data, (uint256)) : 1;
        if (version != 1 && version != 2) revert UnsupportedArtVersion();
        PEPE_DNA_VERSION = version;
        _artCombinations = PepeDna.combinations(version);
        _genesisArtSeed = keccak256(abi.encode(
            blockhash(block.number == 0 ? 0 : block.number - 1), block.chainid, address(this)
        ));
    }

    // ─────────────── ERC-165 / ERC-721 surface ───────────────

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x80ac58cd || id == 0x01ffc9a7 || id == 0x5b5e139f; // ERC-721, ERC-165, metadata
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _ownerOf[tokenId];
        if (o == address(0)) revert NotNftOwner();
        return o;
    }

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert ZeroAddress();
        return _owned[owner].length;
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        uint256[] storage ids = _owned[owner];
        if (index >= ids.length) revert BadOwnerIndex();
        return ids[index];
    }

    /// @notice Immutable NFT DNA; an unminted ID returns its chosen-art preview.
    function dnaOf(uint256 tokenId) public view returns (uint256) {
        return _ownerOf[tokenId] == address(0) ? _hashDna(tokenId) : _mintedDna[tokenId];
    }

    function _hashDna(uint256 seed) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed)));
    }

    /// @notice Whether this exact chosen ID and its previewed art can be minted.
    function isPepeAvailable(uint256 id) external view returns (bool) {
        return id != 0 && _ownerOf[id] == address(0) && _artToken[PepeDna.key(_hashDna(id), PEPE_DNA_VERSION)] == 0;
    }

    /// @notice Pseudorandom art used by a genesis claim at the current state.
    /// An occupied combination gets the first free one. Another mint can change
    /// this preview before the claim confirms; the minted DNA is then immutable.
    function genesisPepeDna(address wallet) external view returns (uint256) {
        if (wallet == address(0)) revert ZeroAddress();
        return _availableDna(_genesisDna(wallet));
    }

    function _genesisDna(address wallet) private view returns (uint256) {
        return uint256(keccak256(abi.encode(_genesisArtSeed, wallet)));
    }

    function _availableDna(uint256 preferred) private view returns (uint256) {
        if (_artToken[PepeDna.key(preferred, PEPE_DNA_VERSION)] == 0) return preferred;
        if (_nextArtKey > _artCombinations) revert PepeArtExhausted();
        return PepeDna.fromKey(_nextArtKey, PEPE_DNA_VERSION);
    }

    /// @notice Reserve a depositor's exact ID and rendered art until their claim.
    /// @dev Only the controller can reserve, atomically with a funded deposit.
    function reserveGenesisPepe(address user, uint256 id) external {
        if (msg.sender != address(controller)) revert NotController();
        if (user == address(0)) revert ZeroAddress();
        if (id == 0 || _ownerOf[id] != address(0) || reservedPepeOwner[id] != address(0)) revert BadPepeId();
        _reserveArt(id, _hashDna(id));
        _reserveId(id);
        reservedPepeOwner[id] = user;
    }

    function _reserveArt(uint256 id, uint256 dna) private {
        uint256 artKey = PepeDna.key(dna, PEPE_DNA_VERSION);
        if (_artToken[artKey] != 0) revert PepeDnaTaken();
        uint256 artStart = artKey;
        uint256 artEnd = artKey;
        if (artKey > 1 && _artToken[artKey - 1] != 0) artStart = _artRunBoundary[artKey - 1];
        if (artKey < _artCombinations && _artToken[artKey + 1] != 0) artEnd = _artRunBoundary[artKey + 1];
        _artRunBoundary[artStart] = artEnd;
        _artRunBoundary[artEnd] = artStart;
        if (artKey == _nextArtKey) _nextArtKey = artEnd + 1;
        _artToken[artKey] = id;

    }

    function _reserveId(uint256 id) private {
        uint256 start = id;
        uint256 end = id;
        if (id > 1 && (_ownerOf[id - 1] != address(0) || reservedPepeOwner[id - 1] != address(0))) start = _mintedRunBoundary[id - 1];
        if (id < type(uint256).max && (_ownerOf[id + 1] != address(0) || reservedPepeOwner[id + 1] != address(0))) end = _mintedRunBoundary[id + 1];
        _mintedRunBoundary[start] = end;
        _mintedRunBoundary[end] = start;
        if (id == nextTokenId) nextTokenId = end + 1;
    }

    function _mint(address to, uint256 id, uint256 dna) internal {
        if (reservedPepeOwner[id] != address(0)) revert BadPepeId();
        _reserveArt(id, dna);
        _reserveId(id);
        _finishMint(to, id, dna);
    }

    function _finishMint(address to, uint256 id, uint256 dna) private {
        _mintedDna[id] = dna;
        _ownerOf[id] = to;
        _ownedIndex[id] = _owned[to].length;
        _owned[to].push(id);
        emit Transfer(address(0), to, id);
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_ownerOf[tokenId] == address(0)) revert NotNftOwner();
        if (descriptor == address(0)) return "";
        return IPepeDescriptor(descriptor).tokenURI(dnaOf(tokenId));
    }

    /// @notice Approve transfers and fee claims for one Pepe; zero revokes.
    /// @dev An individually approved account cannot delegate its permission.
    function approve(address approved, uint256 tokenId) external {
        address owner = _ownerOf[tokenId];
        if (owner == address(0)) revert NotNftOwner();
        if (msg.sender != owner && !_operator[owner][msg.sender]) revert NotAuthorizedNft();
        _tokenApproval[tokenId] = approved;
        emit Approval(owner, approved, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        if (_ownerOf[tokenId] == address(0)) revert NotNftOwner();
        return _tokenApproval[tokenId];
    }

    /// @notice Approve transfers and fee claims across all the owner's Pepes.
    function setApprovalForAll(address operator, bool approved) external {
        _operator[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operator[owner][operator];
    }

    /// @notice Transfer a pepe NFT — moves principal + fee state + decay
    ///         clock together. Multi-position: no recipient constraints.
    function transferFrom(address from, address to, uint256 tokenId) external nonReentrant {
        _transfer(from, to, tokenId);
    }

    /// @notice Transfer a position only if a contract recipient accepts ERC-721s.
    function safeTransferFrom(address from, address to, uint256 tokenId) external nonReentrant {
        _transfer(from, to, tokenId);
        ERC721Utils.checkOnERC721Received(msg.sender, from, to, tokenId, "");
    }

    /// @notice Safe transfer with recipient callback data.
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external nonReentrant {
        _transfer(from, to, tokenId);
        ERC721Utils.checkOnERC721Received(msg.sender, from, to, tokenId, data);
    }

    /// @dev Complete ownership, enumeration and approval effects before any
    /// receiver callback. The shared guard prevents nested financial/transfer
    /// writes; rejection rolls back all effects, including approval clearing.
    function _transfer(address from, address to, uint256 tokenId) private {
        if (to == address(0) || to == address(this)) revert BadNftTransfer();
        address o = _ownerOf[tokenId];
        if (o == address(0) || o != from) revert NotNftOwner();
        if (msg.sender != from && !_operator[from][msg.sender] && _tokenApproval[tokenId] != msg.sender) {
            revert NotAuthorizedNft();
        }
        delete _tokenApproval[tokenId];

        uint256 principal = positions[tokenId].amount;
        _stakedByOwner[from] -= principal;
        _stakedByOwner[to] += principal;

        // swap-and-pop from sender's list, append to recipient's
        uint256[] storage fromIds = _owned[from];
        uint256 i = _ownedIndex[tokenId];
        uint256 lastId = fromIds[fromIds.length - 1];
        fromIds[i] = lastId;
        _ownedIndex[lastId] = i;
        fromIds.pop();
        _ownerOf[tokenId] = to;
        _ownedIndex[tokenId] = _owned[to].length;
        _owned[to].push(tokenId);

        emit Transfer(from, to, tokenId);
    }

    // ─────────────── Epoch helpers ───────────────

    function _epoch() private view returns (uint256) {
        return block.timestamp / epochSize();
    }

    // ─────────────── Weight math ───────────────

    /// @notice A position's live dividend/voting weight during epoch e.
    ///         Upward changes (fresh stake, top-up, cancel, genesis) land
    ///         INSTANTLY — weightAt(stakeEpoch) is already the full amount, so
    ///         the trade right after a stake confirms credits it.
    ///         Decaying: full through the request epoch, then 5/6, 4/6, … 0 at
    ///         each boundary after (dust-safe: base rounds down to ×6).
    function weightAt(uint256 pepeId, uint256 e) public view returns (uint256) {
        Position storage pos = positions[pepeId];
        if (pos.amount == 0 || e < pos.startEpoch) return 0;
        if (!isWithdrawing[pepeId] || e <= pos.requestEpoch) return pos.amount;
        uint256 k = e - pos.requestEpoch;
        if (k >= VEST_EPOCHS) return 0;
        uint256 base = pos.amount - (pos.amount % VEST_EPOCHS);
        return base - k * (base / VEST_EPOCHS);
    }

    /// @notice A position's live weight at instant `at` (epoch containing at).
    function biasOf(uint256 pepeId, uint256 at) public view returns (uint256) {
        return weightAt(pepeId, at / epochSize());
    }

    /// @notice Total live weight across all positions (extrapolated to now).
    function totalWeight() public view returns (uint256) {
        return _pointNow().weight;
    }

    /// @dev decay parameters for an armed position: (base, slope)
    function _decay(Position storage pos) private view returns (uint256 base, uint256 slope) {
        base = pos.amount - (pos.amount % VEST_EPOCHS);
        slope = base / VEST_EPOCHS;
    }

    // ─────────────── Global point machinery ───────────────

    /// @dev Advance a point from its epoch to `to`, applying stored deltas and
    ///      preferring stored points along the way (corrections propagate).
    function _advance(GlobalPoint memory p, uint256 to) private view returns (GlobalPoint memory) {
        // RS-4: every schedule writer checkpoints first. All outstanding
        // decays therefore finish within seven transitions of this point.
        uint256 end = to < p.epoch + VEST_EPOCHS + 1 ? to : p.epoch + VEST_EPOCHS + 1;
        for (uint256 e = p.epoch; e < end; ++e) {
            p.slope = p.slope + slopeAdd[e] - slopeSub[e];
            p.weight = p.weight + biasAdd[e] - biasSub[e] - p.slope;
            p.epoch = e + 1;
            GlobalPoint storage stored = points[e + 1];
            if (stored.epoch != 0) p = stored; // authoritative
        }
        p.epoch = to;
        return p;
    }

    /// @dev The global point at the current epoch (lazy extrapolation).
    function _pointNow() private view returns (GlobalPoint memory) {
        uint256 e = _epoch();
        if (!anchored) {
            // no write-side use yet: nothing is staked, weight is honestly 0.
            // Deltas cannot predate the first _anchorNow (every delta-writer
            // runs through an anchor path or a storing path first).
            return GlobalPoint({epoch: e, weight: 0, slope: 0});
        }
        GlobalPoint memory p = points[lastPointEpoch];
        return _advance(p, e);
    }

    /// @dev Write-side point access: the first call ever STORES the anchor at
    ///      the current epoch (zeros — no deltas can predate it), so later
    ///      extrapolations apply every registered delta correctly.
    function _anchorNow() private returns (GlobalPoint memory p) {
        uint256 e = _epoch();
        if (!anchored) {
            p = GlobalPoint({epoch: e, weight: 0, slope: 0});
            points[e] = p;
            lastPointEpoch = e;
            anchored = true;
            return p;
        }
        return _pointNow();
    }

    /// @dev Checkpoint the global point at the current epoch.
    function _checkpoint() private returns (GlobalPoint memory p) {
        p = _pointNow();
        points[p.epoch] = p;
        lastPointEpoch = p.epoch;
        anchored = true; // storing path anchors too (genesis locks arrive here)
    }

    // ─────────────── Fee settlement (O(1) accumulator delta) ───────────────

    /// @dev Accumulator immediately before the first fee in `epoch` or later.
    function _creditBeforeEpoch(uint256 epoch) private view returns (uint256) {
        uint256 lo;
        uint256 hi = feeEpochs.length;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            if (feeEpochs[mid].epoch < epoch) lo = mid + 1;
            else hi = mid;
        }
        return lo == feeEpochs.length ? creditPerWeight : feeEpochs[lo].creditBefore;
    }

    function _feeSlice(uint256 weight, uint256 delta, uint256 remainder)
        private pure returns (uint256 whole, uint256 nextRemainder)
    {
        whole = Math.mulDiv(weight, delta, CREDIT_PRECISION);
        nextRemainder = mulmod(weight, delta, CREDIT_PRECISION) + remainder;
        if (nextRemainder >= CREDIT_PRECISION) { ++whole; nextRemainder -= CREDIT_PRECISION; }
    }

    /// @dev RS-1: at most six fixed-weight intervals; claim frequency does
    /// not destroy fractional entitlements or previously earned whole fees.
    function _earnedFees(uint256 pepeId) private view returns (uint256 earned, uint256 remainder) {
        Position storage pos = positions[pepeId];
        remainder = feeRemainder[pepeId];
        if (pos.amount == 0) return (0, remainder);
        if (!isWithdrawing[pepeId]) {
            return _feeSlice(pos.amount, creditPerWeight - pos.creditCheckpoint, remainder);
        }
        uint256 start = _creditBeforeEpoch(pos.requestEpoch);
        for (uint256 k; k < VEST_EPOCHS; ++k) {
            uint256 end = _creditBeforeEpoch(pos.requestEpoch + k + 1);
            uint256 from = start > pos.creditCheckpoint ? start : pos.creditCheckpoint;
            if (end > from) {
                uint256 whole;
                (whole, remainder) = _feeSlice(weightAt(pepeId, pos.requestEpoch + k), end - from, remainder);
                earned += whole;
            }
            start = end;
        }
    }

    function _liveCredit(uint256 pepeId) private view returns (uint256) {
        (uint256 earned,) = _earnedFees(pepeId);
        return accruedFees[pepeId] + earned;
    }

    function _accrue(uint256 pepeId) private {
        (uint256 earned, uint256 remainder) = _earnedFees(pepeId);
        accruedFees[pepeId] += earned;
        feeRemainder[pepeId] = remainder;
        positions[pepeId].creditCheckpoint = creditPerWeight;
    }

    /// @dev A failed payout may defer fees while allowing principal to exit.
    /// The entitlement stays attached to the NFT and can be claimed later.
    function _settleAndPay(uint256 pepeId, address to, bool deferOnShortfall) private returns (uint256 paid) {
        _accrue(pepeId);
        paid = accruedFees[pepeId];
        if (paid == 0) return 0;
        accruedFees[pepeId] = 0;
        if (deferOnShortfall) {
            try ICurveHook(controller.hookAddress()).sendFees(to, paid) {}
            catch {
                accruedFees[pepeId] = paid;
                emit FeesDeferred(to, pepeId, paid);
                return 0;
            }
        } else {
            ICurveHook(controller.hookAddress()).sendFees(to, paid);
        }
        positions[pepeId].feesPaid += paid;
        totalFeesPaid += paid;
    }

    // ─────────────── Staking ───────────────

    /// @dev Z-1: no locking into a dying/dead round.
    function _requireAlive() internal view {
        if (controller.flatTime() != 0) revert RoundDead();
        address hook = controller.hookAddress();
        // Mode order: Predeposit < Active < Flat < Destroyed — the two
        // dead modes are exactly mode() >= Flat.
        if (hook != address(0) && ICurveHook(hook).mode() >= ICurveHook.Mode.Flat) revert RoundDead();
    }

    /// @notice Lock PSP into a FRESH sequential pepe (art is a surprise).
    ///         amount == 0 hatches the pepe unstaked.
    function lock(uint256 amount) external nonReentrant {
        _requireAlive();
        uint256 id = _mintFresh(msg.sender);
        if (amount != 0) _stake(msg.sender, id, amount);
    }

    /// @notice Lock with a CHOSEN pepe (art picked off-chain from
    ///         dnaOf candidates). amount == 0 hatches unstaked.
    function lockWithPepe(uint256 amount, uint256 pepeId) external nonReentrant {
        _requireAlive();
        if (pepeId == 0 || _ownerOf[pepeId] != address(0)) revert BadPepeId();
        _mint(msg.sender, pepeId, _hashDna(pepeId));
        if (amount != 0) _stake(msg.sender, pepeId, amount);
    }

    /// @notice Top up an owned pepe — or stake FOR someone (permissionless:
    ///         the reinvestor path; PSP is pulled from msg.sender into
    ///         user's position; only the owner's address benefits).
    function stakeFor(address user, uint256 pepeId, uint256 amount) external nonReentrant {
        _requireAlive();
        if (amount == 0) revert ZeroAmount();
        if (_ownerOf[pepeId] != user) revert NotNftOwner();
        _stake(user, pepeId, amount);
    }

    function _mintFresh(address to) private returns (uint256 id) {
        id = nextTokenId;
        _mint(to, id, _availableDna(_hashDna(id)));
    }

    /// @dev Shared stake body. New weight goes live after pre-topup fees
    ///      are settled; it never earns fees from before the deposit.
    ///      Reverts RequestActive on a decaying position — cancel first.
    function _stake(address user, uint256 pepeId, uint256 amount) private {
        Position storage pos = positions[pepeId];
        if (isWithdrawing[pepeId]) revert RequestActive();
        // AUD-13: permissionless stakeFor donors never receive the owner's
        // accrued fees. Settle to the beneficiary; only an owner-initiated
        // top-up may defer a payout on shortfall without erasing it.
        if (pos.amount != 0) _settleAndPay(pepeId, user, msg.sender == user);

        psp.safeTransferFrom(msg.sender, address(this), amount);

        uint256 e = _epoch();
        if (pos.amount == 0) {
            pos.startEpoch = e;
            pos.creditCheckpoint = creditPerWeight;
        } else {
            pos.startEpoch = e; // re-anchor (credit already settled above)
        }
        // Weight goes live INSTANTLY (scoopy 2026-08-28b: a fresh stake earns
        // on the subsequent trade): correct the stored point directly — a
        // biasAdd[e] delta would double-apply at e+1 on top of this. The
        // settle above paid everything accrued at the OLD weight, so crediting
        // restarts at the new weight with zero retroactivity.
        GlobalPoint memory p = _checkpoint();
        p.weight += amount;
        points[p.epoch] = p;
        pos.amount += amount;
        totalLocked += amount;
        _stakedByOwner[user] += amount;

        emit Locked(user, pepeId, amount);
    }

    /// @notice Arm the 6-epoch linear decay (dividends). Weight stays
    ///         full through the request epoch, then steps down each boundary:
    ///         5/6 after one week, 1/2 after three, 0 after six (mainnet).
    function requestWithdraw(uint256 pepeId) external nonReentrant {
        _requireOwner(pepeId);
        Position storage pos = positions[pepeId];
        if (pos.amount == 0) revert NotLocker();
        if (isWithdrawing[pepeId]) revert RequestActive();

        _settleAndPay(pepeId, msg.sender, true); // state-then-pay below is safe: request changes no balances

        uint256 e = _checkpoint().epoch;
        (uint256 base, uint256 slope) = _decay(pos);
        pos.requestEpoch = e;
        isWithdrawing[pepeId] = true;
        slopeAdd[e] += slope;              // decay starts at the next boundary
        slopeSub[e + VEST_EPOCHS] += slope; // slope retires after the final step
        if (base != pos.amount) biasSub[e] += pos.amount - base; // dust now, exact zero later

        emit WithdrawRequested(msg.sender, pepeId);
    }

    /// @notice Abort a decay — restores full weight immediately.
    ///         Fees earned while decaying are settled and paid first.
    function cancelWithdraw(uint256 pepeId) external nonReentrant {
        _requireOwner(pepeId);
        Position storage pos = positions[pepeId];
        if (!isWithdrawing[pepeId]) revert NotDecaying();

        _settleAndPay(pepeId, msg.sender, true);

        GlobalPoint memory p = _checkpoint();
        uint256 currentWeight = weightAt(pepeId, p.epoch);
        p = _unscheduleDecay(pos, p);
        p.weight += pos.amount - currentWeight;
        points[p.epoch] = p;
        pos.requestEpoch = 0;
        isWithdrawing[pepeId] = false;
        pos.startEpoch = p.epoch;

        emit WithdrawCancelled(msg.sender, pepeId);
    }

    /// @notice Withdraw principal after the decay ran out (or any time once
    ///         the round is flat — detonation opens all locks). The NFT
    ///         survives as a husk: the pepe stays with its owner forever,
    ///         re-stakeable.
    function withdraw(uint256 pepeId) external nonReentrant {
        _requireOwner(pepeId);
        Position storage pos = positions[pepeId];
        if (pos.amount == 0) revert NotLocker();
        bool flat = controller.flatTime() != 0;
        if (!isWithdrawing[pepeId]) {
            if (!flat) revert NotDecaying(); // must request first
        } else if (!flat && _epoch() < pos.requestEpoch + VEST_EPOCHS) {
            revert VestNotComplete();
        }

        _settleAndPay(pepeId, msg.sender, true);

        uint256 amount = pos.amount;
        GlobalPoint memory p = _checkpoint();
        uint256 currentWeight = weightAt(pepeId, p.epoch);
        if (isWithdrawing[pepeId]) p = _unscheduleDecay(pos, p);
        p.weight -= currentWeight;
        points[p.epoch] = p;
        totalLocked -= amount;
        _stakedByOwner[msg.sender] -= amount;
        // Keep deferred fees and fractional credits on the surviving NFT.
        delete positions[pepeId];
        delete isWithdrawing[pepeId];

        psp.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, pepeId, amount);
    }

    /// @notice Operator path for principal withdrawal (grave-zap unlock leg,
    ///         2026-09-14): an authorized operator — per-id approval or
    ///         collection approval — may withdraw on the owner's behalf, with
    ///         principal AND settled fees paid to the OWNER, never the caller.
    ///         Post-Flat this opens the lock in one tx inside a zap. Operators
    ///         already hold strictly more power (NFT transfer moves the whole
    ///         position), so this adds no new theft surface.
    function withdrawFor(uint256 pepeId) external nonReentrant {
        _requireAuthorized(pepeId);
        address owner = _ownerOf[pepeId];
        Position storage pos = positions[pepeId];
        if (pos.amount == 0) revert NotLocker();
        bool flat = controller.flatTime() != 0;
        if (!isWithdrawing[pepeId]) {
            if (!flat) revert NotDecaying(); // must request first
        } else if (!flat && _epoch() < pos.requestEpoch + VEST_EPOCHS) {
            revert VestNotComplete();
        }

        _settleAndPay(pepeId, owner, true); // fees to the owner, not the operator

        uint256 amount = pos.amount;
        GlobalPoint memory p = _checkpoint();
        uint256 currentWeight = weightAt(pepeId, p.epoch);
        if (isWithdrawing[pepeId]) p = _unscheduleDecay(pos, p);
        p.weight -= currentWeight;
        points[p.epoch] = p;
        totalLocked -= amount;
        _stakedByOwner[owner] -= amount;
        // Keep deferred fees and fractional credits on the surviving NFT.
        delete positions[pepeId];
        delete isWithdrawing[pepeId];

        psp.safeTransfer(owner, amount);

        emit Withdrawn(owner, pepeId, amount);
    }

    /// @dev Remove only this position's pending/active decay schedule.
    function _unscheduleDecay(Position storage pos, GlobalPoint memory p)
        private returns (GlobalPoint memory)
    {
        uint256 r = pos.requestEpoch;
        (uint256 base, uint256 slope) = _decay(pos);
        if (p.epoch == r) {
            slopeAdd[r] -= slope;
            biasSub[r] -= pos.amount - base;
            slopeSub[r + VEST_EPOCHS] -= slope;
        } else if (p.epoch <= r + VEST_EPOCHS) {
            p.slope -= slope;
            slopeSub[r + VEST_EPOCHS] -= slope;
        }
        return p;
    }

    // ─────────────── Claims ───────────────

    /// @notice Claim accrued fees on one pepe. Pays mixETH via the hook to
    ///         the caller (or `to` — the reinvestor path). Owner or an
    ///         approved-for-all operator may call.
    function claimFees(uint256 pepeId) external {
        claimFeesTo(pepeId, msg.sender);
    }

    function claimFeesTo(uint256 pepeId, address to) public nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _requireAuthorized(pepeId);
        uint256 paid = _settleAndPay(pepeId, to, false); // strict: explicit intent
        if (paid == 0) revert NothingToClaim();
        emit FeesClaimed(_ownerOf[pepeId], pepeId, paid);
    }

    /// @notice Multiclaim across pepes in one transaction, paying `to`.
    function claimAllTo(uint256[] calldata pepeIds, address to) public nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 totalPaid;
        for (uint256 i; i < pepeIds.length; ++i) {
            uint256 pepeId = pepeIds[i];
            _requireAuthorized(pepeId);
            totalPaid += _settleAndPay(pepeId, to, false);
        }
        if (totalPaid == 0) revert NothingToClaim();
        emit FeesClaimed(msg.sender, 0, totalPaid);
    }

    // ─────────────── Controller entry points ───────────────

    /// @dev Genesis virtual lock — the whole claimable predeposit pool,
    ///      locked at launch (kills the first-locker fee-capture window).
    ///      tokenId 0, never an NFT, never decays.
    function lockGenesis(uint256 amount) external nonReentrant {
        if (msg.sender != address(controller)) revert NotController();
        if (amount == 0) revert ZeroAmount();
        _accrue(0);
        Position storage genesis = positions[0];
        uint256 e = _epoch();
        genesis.startEpoch = e; // (re)anchor increments (pre-launch: no fees yet)
        genesis.creditCheckpoint = creditPerWeight;
        // live from the first post-launch trade — the whole predeposit pool
        // backs the curve's earliest fees, so no first-locker capture window
        GlobalPoint memory p = _checkpoint(); // anchors on the first write ever
        p.weight += amount;
        points[p.epoch] = p;
        genesis.amount += amount;
        totalLocked += amount;
    }

    /// @dev Predeposit share claim: move `share` out of the genesis position
    ///      into a fresh pseudorandom pepe minted to `user`, paying the
    ///      share's accrued fees alongside (deferred if payout is unavailable).
    function claimGenesisShare(address user, uint256 share) external nonReentrant {
        _claimGenesisShare(user, share, 0, false);
    }

    /// @notice Controller-only genesis claim with exact selected ID and art.
    /// @dev Uses the same permanent trait reservation as every other mint.
    function claimGenesisShareWithPepe(address user, uint256 share, uint256 pepeId) external nonReentrant {
        _claimGenesisShare(user, share, pepeId, true);
    }

    function _claimGenesisShare(address user, uint256 share, uint256 pepeId, bool chosen) private {
        if (msg.sender != address(controller)) revert NotController();

        if (user == address(0)) revert ZeroAddress();
        Position storage genesis = positions[0];
        _accrue(0);
        uint256 genesisAmount = genesis.amount;
        if (share == 0 || share > genesisAmount) revert ZeroAmount();
        uint256 shareFees = Math.mulDiv(accruedFees[0], share, genesisAmount);
        uint256 shareRemainder = Math.mulDiv(feeRemainder[0], share, genesisAmount);
        accruedFees[0] -= shareFees;
        feeRemainder[0] -= shareRemainder;
        genesis.amount -= share;

        // PD-3: the round's frozen block-hash seed chooses art for this wallet.
        // PD-2: keep the preferred address ID and resolve ID/art collisions
        // independently, preserving existing NFTs and round art uniqueness.
        uint256 id;
        uint256 dna;
        if (chosen) {
            if (pepeId == 0 || _ownerOf[pepeId] != address(0)) revert BadPepeId();
            id = pepeId;
            dna = _hashDna(id);
        } else {
            id = uint256(uint160(user));
            dna = _availableDna(_genesisDna(user));
            if (_ownerOf[id] != address(0) || reservedPepeOwner[id] != address(0)) id = nextTokenId;
        }
        if (chosen && reservedPepeOwner[id] == user) {
            delete reservedPepeOwner[id];
            _finishMint(user, id, dna);
        } else {
            _mint(user, id, dna);
        }
        Position storage pos = positions[id];
        pos.amount = share;
        _stakedByOwner[user] += share;
        pos.startEpoch = _epoch();
        pos.creditCheckpoint = creditPerWeight;
        accruedFees[id] = shareFees;
        feeRemainder[id] = shareRemainder;
        _settleAndPay(id, user, true);

        emit Locked(user, id, share);
    }

    /// @dev Fee feed — controller forwards hook addFees() here. Fees credit
    ///      the accumulator IMMEDIATELY (scoopy 2026-08-28: never epoch-gated);
    ///      zero-weight rounds park them in pending until weight exists.
    function addFees(uint256 mixETHAmount) external nonReentrant {
        if (msg.sender != address(controller)) revert NotController();
        totalFeesReceived += mixETHAmount;
        pendingFeesMixETH += mixETHAmount;
        _distribute();
    }

    /// @dev Credit pending fees at the current (epoch-frozen) weight.
    ///      Rolling remainder (A-F3/AUD-12): the ceiling of allocated credit leaves
    ///      `pendingFeesMixETH`, so sub-precision dust accumulates until it
    ///      crosses one credit unit instead of being stranded forever.
    function _distribute() private {
        if (pendingFeesMixETH == 0) return;
        uint256 w = _pointNow().weight;
        if (w == 0) return; // orphaned: distributes once weight exists
        uint256 delta = Math.mulDiv(pendingFeesMixETH, CREDIT_PRECISION, w);
        if (delta == 0) return; // sub-precision: keep rolling in pending
        // AUD-12: creditPerWeight retains fractional entitlements between
        // feeds. Debit their CEILING from pending so that fraction cannot
        // also be allocated again as a rolling remainder on the next feed.
        uint256 distributed = Math.mulDiv(delta, w, CREDIT_PRECISION, Math.Rounding.Ceil);
        uint256 epoch = _epoch();
        if (feeEpochs.length == 0 || feeEpochs[feeEpochs.length - 1].epoch != epoch) {
            feeEpochs.push(FeeEpoch(epoch, creditPerWeight));
        }
        creditPerWeight += delta;
        pendingFeesMixETH -= distributed;
        emit FeesCredited(distributed, creditPerWeight);
    }

    function _requireOwner(uint256 pepeId) private view {
        if (_ownerOf[pepeId] != msg.sender) revert NotNftOwner();
    }

    /// @dev Individual and collection operators can transfer or claim fees.
    /// Withdrawal requests, cancellation and principal withdrawal stay owner-only.
    function _requireAuthorized(uint256 pepeId) private view {
        address owner = _ownerOf[pepeId];
        if (owner == address(0) ||
            (owner != msg.sender && !_operator[owner][msg.sender] && _tokenApproval[pepeId] != msg.sender)) {
            revert NotNftOwner();
        }
    }

    // ─────────────── Registry oracle views ───────────────

    /// @notice First pepe of `user` (0 if none) — the referral chain's
    ///         per-user identity.
    function primaryOf(address user) external view returns (uint256) {
        uint256[] storage ids = _owned[user];
        return ids.length == 0 ? 0 : ids[0];
    }

    /// @notice Σ staked PSP across all of `user`'s pepes (principal).
    function stakedTotalOf(address user) external view returns (uint256) {
        return _stakedByOwner[user];
    }

    // ─────────────── UI views ───────────────

    /// @notice Live claimable fees for one pepe — fees are assigned the moment
    ///         they land, so this is real-time: it ticks up on every trade.
    function pendingFeesOf(uint256 pepeId) external view returns (uint256) {
        return _liveCredit(pepeId);
    }

    /// @notice Timestamp when a decayed position becomes withdrawable
    ///         (type(uint).max while locked indefinitely).
    function withdrawableAt(uint256 pepeId) external view returns (uint256) {
        uint256 r = positions[pepeId].requestEpoch;
        // AUD-20: epoch zero can contain an active withdrawal request.
        return isWithdrawing[pepeId] ? (r + VEST_EPOCHS) * epochSize() : type(uint256).max;
    }

    // ─────────────── Vote views — REMOVED (CLOCK-REDESIGN §4, 2026-09-01) ───────────────
    // voteWeight / pepeVoteWeight / totalVotableWeight served the carpet
    // vote's quorum + the prisoner's-dilemma commitment exclusively. With
    // governance dead there is no reader; the detonation clock needs no
    // stake-weighted anything. Fee-weight views (weightAt / biasOf /
    // totalWeight / pendingFeesOf) remain above, untouched.
}
