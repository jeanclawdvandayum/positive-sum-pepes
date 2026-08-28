// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICurveHook} from "./interfaces/ICurveHook.sol";
import {IRoundController} from "./interfaces/IRoundController.sol";

/// @dev Minimal descriptor slice (EIP-170 budget): metadata + SVG from DNA.
interface IPepeDescriptor {
    function tokenURI(uint256 dna) external pure returns (string memory);
}

/// @title PSPStaker — epoch-point staking with InfiniFi-style linear unwinding.
/// @notice Design (after InfiniFi-Labs/infinifi-protocol `UnwindingModule`):
///         All dividend/voting weight lives in a lazily-checkpointed global
///         point {weight, slope}. UPWARD weight changes (stake, top-up,
///         cancel, genesis lock) land INSTANTLY via direct point correction
///         (scoopy 2026-08-28b: a fresh stake earns on the subsequent trade —
///         no next-epoch activation wait). DOWNWARD changes stay epoch-
///         aligned: a withdraw request arms a 6-epoch linear decay (veCRV
///         bias + slope) — full weight through the request epoch, then
///         5/6, 4/6, … 0 at each boundary — implemented as per-epoch slope
///         deltas. Accepted trade: front-running a known fee event with
///         stake capital (JIT-LP style) earns that event's pro-rata share;
///         governance is unaffected (voteWeight ignores post-snapshot
///         actionTime).
///
///         Fee credits are NOT epoch-based (2026-08-28 redesign, scoopy's
///         must-fix): a single monotonic `creditPerWeight` accumulator is
///         advanced the instant fees arrive — `delta = fees * 1e30 /
///         totalWeight` — and every position claims `weightNow * (credit -
///         checkpoint) / 1e30` live, with no epoch walk and no boundary wait.
///         Each feed splits at the total weight live at that instant, so
///         same-instant weight/fee interleavings are exact; positions settle
///         before any weight mutation, so nothing is credited retroactively.
///         The one approximation (explicitly accepted): a DECAYING position
///         that skips claims while its vest steps down has fees earned at
///         earlier, higher weights settled at its current, lower weight — it
///         under-credits only, never over-credits, and a position that
///         reaches zero weight with unclaimed credit forfeits it (claim
///         before your vest runs out).
contract PSPStaker {
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
    error RequestActive();   // stake/top-up while decaying — cancel first
    error NotDecaying();     // cancel/withdraw without an active request
    error VestNotComplete(); // withdraw before the decay ran out
    error BadOwnerIndex();   // enumeration out of range

    // ─────────────── Events ───────────────
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    event Locked(address indexed user, uint256 indexed pepeId, uint256 amount);
    event WithdrawRequested(address indexed user, uint256 indexed pepeId);
    event WithdrawCancelled(address indexed user, uint256 indexed pepeId);
    event Withdrawn(address indexed user, uint256 indexed pepeId, uint256 amount);
    event FeesClaimed(address indexed user, uint256 indexed pepeId, uint256 amount);
    event FeesForfeited(address indexed user, uint256 mixETHAmount);
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
        uint256 startEpoch;      // weight live from startEpoch+1 (0 while minted-in-epoch)
        uint256 requestEpoch;    // 0 = indefinite lock; E = decay armed at E (full through E)
        uint256 creditCheckpoint; // creditPerWeight at last settle (claims are O(1) deltas)
        uint256 feesPaid;        // cumulative fees paid out
        uint256 actionTime;      // last weight-mutating action (vote guard)
    }

    /// @dev pepeId-keyed: one position per NFT, many NFTs per user.
    ///      tokenId 0 = the genesis virtual position (predeposit pool).
    mapping(uint256 => Position) public positions;

    mapping(uint256 => GlobalPoint) public points; // epoch => point
    uint256 public lastPointEpoch;                 // latest stored point

    // per-epoch deltas, applied when advancing epoch e -> e+1:
    mapping(uint256 => uint256) public biasAdd;  // +weight (stakes, cancels)
    mapping(uint256 => uint256) public biasSub;  // -weight (withdraws, dust)
    mapping(uint256 => uint256) public slopeAdd; // +slope (requests)
    mapping(uint256 => uint256) public slopeSub; // -slope (decay completion)

    // ─────────────── Fee credit accumulator ───────────────
    /// @dev Masterchef-style monotonic accumulator, advanced on every addFees
    ///      by `fees * CREDIT_PRECISION / totalWeight`. Claims are O(1):
    ///      `weightNow * (creditPerWeight - checkpoint) / CREDIT_PRECISION`.
    uint256 public creditPerWeight;
    uint256 public constant CREDIT_PRECISION = 1e30;

    uint256 public pendingFeesMixETH; // orphaned (zero-weight) fees + rolling remainder
    uint256 public totalLocked;       // Σ principal (display)

    /// @dev decay steps per vest window: weight(e) = base - k·slope, k = e - requestEpoch
    uint256 public constant VEST_EPOCHS = 6;

    // ─────────────── Immutables ───────────────
    IERC20 public immutable psp;
    IRoundController public immutable controller;

    /// @dev epoch length = VEST_DURATION / 6 (mainnet 42d → 7d, testnet 6h → 1h).
    ///      Read lazily from the controller — the staker is deployed during
    ///      the controller's OWN constructor (finding 47: counterparty has no
    ///      code yet), so no eager VEST_DURATION read at construction.
    function epochSize() public view returns (uint256) {
        return controller.VEST_DURATION() / VEST_EPOCHS;
    }

    // ─────────────── ERC-721 state ───────────────
    string public constant name = "Positive Sum Pepe Position";
    string public constant symbol = "PSPP";
    uint256 public nextTokenId = 1;
    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256[]) private _owned;
    mapping(uint256 => uint256) private _ownedIndex; // id => position in _owned
    mapping(address => mapping(address => bool)) private _operator;

    // ─────────────── Pepe art state ───────────────
    /// @dev PepeDescriptor (SVG + metadata), wired at construction via the
    ///      factory. Zero = this round carries no art (tokenURI is empty).
    address public immutable descriptor;

    constructor(IERC20 _psp, IRoundController _controller, address descriptor_) {
        if (address(_psp) == address(0)) revert ZeroAddress();
        if (address(_controller) == address(0)) revert ZeroAddress();
        psp = _psp;
        controller = _controller;
        descriptor = descriptor_;
    }

    // ─────────────── ERC-165 / ERC-721 surface ───────────────

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x80ac58cd || id == 0x01ffc9a7; // ERC-721, ERC-165
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _ownerOf[tokenId];
        if (o == address(0)) revert NotNftOwner();
        return o;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _owned[owner].length;
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        uint256[] storage ids = _owned[owner];
        if (index >= ids.length) revert BadOwnerIndex();
        return ids[index];
    }

    /// @notice deterministic per-token generative DNA (full word; the
    ///         descriptor clamps every axis — any dna renders). Pure view.
    function dnaOf(uint256 tokenId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(tokenId)));
    }

    function _mint(address to, uint256 id) internal {
        _ownerOf[id] = to;
        _ownedIndex[id] = _owned[to].length;
        _owned[to].push(id);
        emit Transfer(address(0), to, id);
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_ownerOf[tokenId] == address(0)) revert NotNftOwner();
        return IPepeDescriptor(descriptor).tokenURI(dnaOf(tokenId));
    }

    /// @dev per-token approvals dropped (EIP-170): operator approvals remain
    ///      — the only path marketplaces (Seaport) use.
    function setApprovalForAll(address operator, bool approved) external {
        _operator[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operator[owner][operator];
    }

    /// @notice Transfer a pepe NFT — moves principal + fee state + decay
    ///         clock together. Multi-position: no recipient constraints.
    function transferFrom(address from, address to, uint256 tokenId) external {
        if (to == address(0) || to == address(this)) revert BadNftTransfer();
        address o = _ownerOf[tokenId];
        if (o == address(0) || o != from) revert NotNftOwner();
        if (msg.sender != from && !_operator[from][msg.sender]) revert NotAuthorizedNft();

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
        if (pos.requestEpoch == 0 || e <= pos.requestEpoch) return pos.amount;
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
        for (uint256 e = p.epoch; e < to; ++e) {
            p.slope = p.slope + slopeAdd[e] - slopeSub[e];
            p.weight = p.weight + biasAdd[e] - biasSub[e] - p.slope;
            p.epoch = e + 1;
            GlobalPoint storage stored = points[e + 1];
            if (stored.epoch != 0) p = stored; // authoritative
        }
        return p;
    }

    /// @dev The global point at the current epoch (lazy extrapolation).
    function _pointNow() private view returns (GlobalPoint memory) {
        uint256 e = _epoch();
        if (lastPointEpoch == 0) {
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
        if (lastPointEpoch == 0) {
            p = GlobalPoint({epoch: e, weight: 0, slope: 0});
            points[e] = p;
            lastPointEpoch = e;
            return p;
        }
        return _pointNow();
    }

    /// @dev Checkpoint the global point at the current epoch.
    function _checkpoint() private returns (GlobalPoint memory p) {
        p = _pointNow();
        points[p.epoch] = p;
        lastPointEpoch = p.epoch;
    }

    // ─────────────── Fee settlement (O(1) accumulator delta) ───────────────

    /// @dev Live unclaimed credit for `pepeId` — fees are assigned the moment
    ///      they land, so this reads the CURRENT epoch's (frozen) weight times
    ///      the accumulator growth since the position's last settle. For a
    ///      decaying position claimed epochs after earning, the growth is
    ///      scaled at the current (lower) weight — under-credits only.
    function _liveCredit(uint256 pepeId) private view returns (uint256) {
        Position storage pos = positions[pepeId];
        return (weightAt(pepeId, _epoch()) * (creditPerWeight - pos.creditCheckpoint)) / CREDIT_PRECISION;
    }

    /// @dev Settle `pepeId` to the current accumulator and pay the newly
    ///      credited fees to `to`. Returns the amount paid.
    function _settleAndPay(uint256 pepeId, address to, bool forfeitOnShortfall) private returns (uint256 paid) {
        Position storage pos = positions[pepeId];
        uint256 due = _liveCredit(pepeId);
        pos.creditCheckpoint = creditPerWeight;
        pos.feesPaid += due;
        paid = due;
        if (paid != 0) _payFees(to, paid, forfeitOnShortfall);
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
    function lock(uint256 amount) external {
        _requireAlive();
        uint256 id = _mintFresh(msg.sender);
        if (amount != 0) _stake(msg.sender, id, amount);
    }

    /// @notice Lock with a CHOSEN pepe (art picked off-chain from
    ///         dnaOf candidates). amount == 0 hatches unstaked.
    function lockWithPepe(uint256 amount, uint256 pepeId) external {
        _requireAlive();
        if (pepeId == 0 || _ownerOf[pepeId] != address(0)) revert BadPepeId();
        _mint(msg.sender, pepeId);
        if (amount != 0) _stake(msg.sender, pepeId, amount);
    }

    /// @notice Top up an owned pepe — or stake FOR someone (permissionless:
    ///         the reinvestor path; PSP is pulled from msg.sender into
    ///         user's position; only the owner's address benefits).
    function stakeFor(address user, uint256 pepeId, uint256 amount) external {
        _requireAlive();
        if (amount == 0) revert ZeroAmount();
        if (_ownerOf[pepeId] != user) revert NotNftOwner();
        _stake(user, pepeId, amount);
    }

    function _mintFresh(address to) private returns (uint256 id) {
        while (_ownerOf[nextTokenId] != address(0)) ++nextTokenId;
        id = nextTokenId++;
        _mint(to, id);
    }

    /// @dev shared stake body. Weight goes live at the next epoch boundary
    ///      (InfiniFi semantics: no retroactive claim on this epoch's fees).
    ///      Reverts RequestActive on a decaying position — cancel first.
    function _stake(address user, uint256 pepeId, uint256 amount) private {
        Position storage pos = positions[pepeId];
        if (pos.requestEpoch != 0) revert RequestActive();
        if (pos.amount != 0) _settleAndPay(pepeId, msg.sender, true); // pay what's due pre-topup

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
        pos.actionTime = block.timestamp;
        totalLocked += amount;

        emit Locked(user, pepeId, amount);
    }

    /// @notice Arm the 6-epoch linear decay (dividends + votes). Weight stays
    ///         full through the request epoch, then steps down each boundary:
    ///         5/6 after one week, 1/2 after three, 0 after six (mainnet).
    function requestWithdraw(uint256 pepeId) external {
        _requireOwner(pepeId);
        Position storage pos = positions[pepeId];
        if (pos.amount == 0) revert NotLocker();
        if (pos.requestEpoch != 0) revert RequestActive();

        _settleAndPay(pepeId, msg.sender, true); // state-then-pay below is safe: request changes no balances

        uint256 e = _epoch();
        (uint256 base, uint256 slope) = _decay(pos);
        pos.requestEpoch = e;
        pos.actionTime = block.timestamp;
        slopeAdd[e] += slope;              // decay starts at the next boundary
        slopeSub[e + VEST_EPOCHS] += slope; // slope retires after the final step
        if (base != pos.amount) biasSub[e] += pos.amount - base; // dust now, exact zero later

        emit WithdrawRequested(msg.sender, pepeId);
    }

    /// @notice Abort a decay — restores full power from the next boundary.
    ///         Fees earned while decaying are settled and paid first.
    function cancelWithdraw(uint256 pepeId) external {
        _requireOwner(pepeId);
        Position storage pos = positions[pepeId];
        if (pos.requestEpoch == 0) revert NotDecaying();

        _settleAndPay(pepeId, msg.sender, true);

        uint256 f = _epoch();
        uint256 r = pos.requestEpoch;
        (uint256 base, uint256 slope) = _decay(pos);
        uint256 dust = pos.amount - base;

        if (f == r) {
            // nothing materialized yet — cancel the pending deltas
            slopeAdd[r] -= slope;
            slopeSub[r + VEST_EPOCHS] -= slope;
            if (dust != 0) biasSub[r] -= dust;
        } else {
            // slope partially applied — correct the live point directly:
            // remove the slope AND restore the decayed-away weight + dust now
            GlobalPoint memory p = _checkpoint();
            p.slope -= slope;
            p.weight += (f - r) * slope + dust;
            points[p.epoch] = p;
            slopeSub[r + VEST_EPOCHS] -= slope;
        }

        pos.requestEpoch = 0;
        pos.startEpoch = f; // re-anchor at full amount, live from f+1
        pos.actionTime = block.timestamp;

        emit WithdrawCancelled(msg.sender, pepeId);
    }

    /// @notice Withdraw principal after the decay ran out (or any time once
    ///         the round is flat — carpet-bomb opens all locks). The NFT
    ///         survives as a husk: the pepe stays with its owner forever,
    ///         re-stakeable.
    function withdraw(uint256 pepeId) external {
        _requireOwner(pepeId);
        Position storage pos = positions[pepeId];
        if (pos.amount == 0) revert NotLocker();
        bool flat = controller.flatTime() != 0;
        if (pos.requestEpoch == 0) {
            if (!flat) revert NotDecaying(); // must request first
        } else if (!flat && _epoch() < pos.requestEpoch + VEST_EPOCHS) {
            revert VestNotComplete();
        }

        _settleAndPay(pepeId, msg.sender, true);

        uint256 amount = pos.amount;
        if (pos.requestEpoch != 0) {
            // slope retires at r+6 via slopeSub (lazy) — no correction needed;
            // the position's weight is already zero by construction.
        } else {
            // flat-path exit: keep the global honest, instantly
            GlobalPoint memory p = _checkpoint();
            p.weight -= amount;
            points[p.epoch] = p;
        }
        totalLocked -= amount;
        delete positions[pepeId];

        psp.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, pepeId, amount);
    }

    // ─────────────── Claims ───────────────

    /// @notice Claim accrued fees on one pepe. Pays mixETH via the hook to
    ///         the caller (or `to` — the reinvestor path). Owner or an
    ///         approved-for-all operator may call.
    function claimFees(uint256 pepeId) external {
        claimFeesTo(pepeId, msg.sender);
    }

    function claimFeesTo(uint256 pepeId, address to) public {
        if (to == address(0)) revert ZeroAddress();
        _requireAuthorized(pepeId);
        uint256 paid = _settleAndPay(pepeId, to, false); // strict: explicit intent
        if (paid == 0) revert NothingToClaim();
        emit FeesClaimed(_ownerOf[pepeId], pepeId, paid);
    }

    /// @notice Multiclaim across pepes in one transaction, paying `to`.
    function claimAllTo(uint256[] calldata pepeIds, address to) public {
        if (to == address(0)) revert ZeroAddress();
        uint256 totalPaid;
        for (uint256 i; i < pepeIds.length; ++i) {
            uint256 pepeId = pepeIds[i];
            _requireAuthorized(pepeId);
            totalPaid += _settleAndPay(pepeId, to, true);
        }
        if (totalPaid == 0) revert NothingToClaim();
        emit FeesClaimed(msg.sender, 0, totalPaid);
    }

    // ─────────────── Controller entry points ───────────────

    /// @dev Genesis virtual lock — the whole claimable predeposit pool,
    ///      locked at launch (kills the first-locker fee-capture window).
    ///      tokenId 0, never an NFT, never decays.
    function lockGenesis(uint256 amount) external {
        if (msg.sender != address(controller)) revert NotController();
        if (amount == 0) revert ZeroAmount();
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
        genesis.actionTime = block.timestamp;
        totalLocked += amount;
    }

    /// @dev Predeposit share claim: move `share` out of the genesis position
    ///      into a FRESH sequential pepe minted to `user`, paying the share's
    ///      accrued fees alongside (forfeit-on-shortfall).
    function claimGenesisShare(address user, uint256 share) external {
        if (msg.sender != address(controller)) revert NotController();

        Position storage genesis = positions[0];
        uint256 genesisDue = _liveCredit(0);
        uint256 genesisAmount = genesis.amount;
        uint256 shareFees = genesisAmount == 0 ? 0 : (genesisDue * share) / genesisAmount;
        genesis.creditCheckpoint = creditPerWeight;
        genesis.feesPaid += shareFees;
        genesis.amount = genesisAmount - share;
        genesis.actionTime = block.timestamp;

        uint256 e = _epoch();
        // weight moves between positions (genesis → fresh pepe), both live
        // immediately via their amounts — the global total is unchanged, so
        // no deltas or corrections are needed here.

        uint256 id = _mintFresh(user);
        Position storage pos = positions[id];
        pos.amount = share;
        pos.startEpoch = e;
        pos.creditCheckpoint = creditPerWeight;
        pos.actionTime = block.timestamp;

        if (shareFees != 0) _payFees(user, shareFees, true);

        emit Locked(user, id, share);
    }

    /// @dev Fee feed — controller forwards hook addFees() here. Fees credit
    ///      the accumulator IMMEDIATELY (scoopy 2026-08-28: never epoch-gated);
    ///      zero-weight rounds park them in pending until weight exists.
    function addFees(uint256 mixETHAmount) external {
        if (msg.sender != address(controller)) revert NotController();
        pendingFeesMixETH += mixETHAmount;
        _distribute();
    }

    /// @dev Credit pending fees at the current (epoch-frozen) weight.
    ///      Rolling remainder (A-F3): only the distributed part leaves
    ///      `pendingFeesMixETH`, so sub-precision dust accumulates until it
    ///      crosses one credit unit instead of being stranded forever.
    function _distribute() private {
        if (pendingFeesMixETH == 0) return;
        uint256 w = _pointNow().weight;
        if (w == 0) return; // orphaned: distributes once weight exists
        uint256 delta = (pendingFeesMixETH * CREDIT_PRECISION) / w;
        if (delta == 0) return; // sub-precision: keep rolling in pending
        uint256 distributed = (delta * w) / CREDIT_PRECISION; // ≤ pendingFeesMixETH
        creditPerWeight += delta;
        pendingFeesMixETH -= distributed;
        emit FeesCredited(distributed, creditPerWeight);
    }

    // ─────────────── Fee payout ───────────────

    /// @dev M-2: on the forfeit path a hook surplus shortfall burns the fees
    ///      rather than reverting — a fee leg must never trap PSP principal.
    function _payFees(address user, uint256 amount, bool forfeitOnShortfall) private {
        address hook = controller.hookAddress();
        if (forfeitOnShortfall) {
            try ICurveHook(hook).sendFees(user, amount) {}
            catch {
                emit FeesForfeited(user, amount);
            }
        } else {
            ICurveHook(hook).sendFees(user, amount);
        }
    }

    function _requireOwner(uint256 pepeId) private view {
        if (_ownerOf[pepeId] != msg.sender) revert NotNftOwner();
    }

    /// @dev owner OR approved-for-all operator (the reinvestor flow).
    function _requireAuthorized(uint256 pepeId) private view {
        address owner = _ownerOf[pepeId];
        if (owner != msg.sender && !_operator[owner][msg.sender]) revert NotNftOwner();
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
        uint256[] storage ids = _owned[user];
        uint256 total;
        for (uint256 i; i < ids.length; ++i) {
            total += positions[ids[i]].amount;
        }
        return total;
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
        return r == 0 ? type(uint256).max : (r + VEST_EPOCHS) * epochSize();
    }

    /// @notice Voting weight at instant `at`: Σ live position power over the
    ///         caller's pepes that existed by `at`. Governance-only view —
    ///         a position carries FULL voting power from its creation
    ///         instant, but `actionTime` excludes anything staked after the
    ///         snapshot, so flash-governance is impossible. Decay from an
    ///         armed withdraw request mirrors the fee engine step-for-step
    ///         from the request epoch onward (5/6, 4/6, … 0).
    function voteWeight(address user, uint256 at) external view returns (uint256) {
        uint256 e = at / epochSize();
        uint256[] storage ids = _owned[user];
        uint256 total;
        for (uint256 i; i < ids.length; ++i) {
            Position storage pos = positions[ids[i]];
            if (pos.actionTime > at || e < pos.startEpoch) continue;
            if (pos.requestEpoch == 0 || e <= pos.requestEpoch) {
                total += pos.amount;
            } else {
                uint256 k = e - pos.requestEpoch;
                if (k >= VEST_EPOCHS) continue; // fully decayed
                uint256 base = pos.amount - (pos.amount % VEST_EPOCHS);
                total += base - k * (base / VEST_EPOCHS);
            }
        }
        return total;
    }
}
