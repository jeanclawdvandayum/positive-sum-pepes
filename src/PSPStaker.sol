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
///         point {weight, slope} advanced once per epoch. Weight changes
///         (stake, top-up, request, cancel) register per-epoch deltas that go
///         live at the NEXT epoch boundary, so weight is constant within an
///         epoch and every fee split is exact — no accumulator/debt math.
///         A withdraw request arms a 6-epoch linear decay (veCRV-style bias +
///         slope): full weight through the request epoch, then 5/6, 4/6, … 0.
///         Fees deposited during an epoch sit on that epoch's point and are
///         replayed pro-rata by each position's per-epoch weight on claim.
///         Positions self-anchor (settledW/settledSlope) so settlement never
///         depends on a stored point at its settled epoch, and walkers prefer
///         stored points so direct corrections (mid-decay cancel) propagate.
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

    // ─────────────── Epoch-point core state ───────────────

    /// @dev Global dividend/voting weight, checkpointed lazily. `epoch` is the
    ///      epoch the point describes; a stored point at e is authoritative
    ///      for that epoch (walkers prefer it — corrections propagate).
    struct GlobalPoint {
        uint256 epoch;   // epoch this point describes (0 = virtual/empty)
        uint256 weight;  // total live weight during `epoch`
        uint256 slope;   // per-epoch weight decrease (sum of active decays)
        uint256 fees;    // mixETH credited to `epoch`, split by weight
    }

    struct Position {
        uint256 amount;       // principal PSP
        uint256 startEpoch;   // weight live from startEpoch+1 (0 while minted-in-epoch)
        uint256 requestEpoch; // 0 = indefinite lock; E = decay armed at E (full through E)
        uint256 settledEpoch; // fees settled through this epoch
        uint256 settledW;     // global weight at settledEpoch (self-anchor)
        uint256 settledSlope; // global slope at settledEpoch (self-anchor)
        uint256 feesPaid;     // cumulative fees paid out
        uint256 actionTime;   // last weight-mutating action (vote guard)
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

    uint256 public pendingFeesMixETH; // orphaned (zero-weight) fees
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

    function _lastClosedEpoch() private view returns (uint256) {
        uint256 e = _epoch();
        return e == 0 ? 0 : e - 1;
    }

    // ─────────────── Weight math ───────────────

    /// @notice A position's live dividend/voting weight during epoch e.
    ///         Indefinite locks: full amount from the epoch after staking.
    ///         Decaying: full through the request epoch, then 5/6, 4/6, … 0
    ///         (dust-safe: the base is rounded down to a multiple of 6).
    function weightAt(uint256 pepeId, uint256 e) public view returns (uint256) {
        Position storage pos = positions[pepeId];
        if (pos.amount == 0 || e <= pos.startEpoch) return 0;
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
    ///      Fees are zeroed at each step: they belong to exactly one epoch.
    function _advance(GlobalPoint memory p, uint256 to) private view returns (GlobalPoint memory) {
        for (uint256 e = p.epoch; e < to; ++e) {
            p.slope = p.slope + slopeAdd[e] - slopeSub[e];
            p.weight = p.weight + biasAdd[e] - biasSub[e] - p.slope;
            p.epoch = e + 1;
            p.fees = 0;
            GlobalPoint storage stored = points[e + 1];
            if (stored.epoch != 0) p = stored; // authoritative (with its fees)
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
            return GlobalPoint({epoch: e, weight: 0, slope: 0, fees: 0});
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
            p = GlobalPoint({epoch: e, weight: 0, slope: 0, fees: 0});
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

    // ─────────────── Fee settlement (the replay) ───────────────

    /// @dev Cumulative fees allocated to `pepeId` for epochs (settledEpoch, through],
    ///      replaying the global point from the position's self-anchor.
    ///      Prefers stored points (same as _advance) so corrections propagate.
    function _allocated(uint256 pepeId, uint256 through) private view returns (uint256 alloc, uint256 endW, uint256 endSlope) {
        Position storage pos = positions[pepeId];
        GlobalPoint memory p = GlobalPoint({
            epoch: pos.settledEpoch, weight: pos.settledW, slope: pos.settledSlope, fees: 0
        });
        for (uint256 e = pos.settledEpoch + 1; e <= through; ++e) {
            // advance p from e-1 to e
            uint256 d = e - 1;
            p.slope = p.slope + slopeAdd[d] - slopeSub[d];
            p.weight = p.weight + biasAdd[d] - biasSub[d] - p.slope;
            p.epoch = e;
            p.fees = 0; // fees belong to exactly one epoch
            GlobalPoint storage stored = points[e];
            if (stored.epoch != 0) p = stored;
            if (p.fees != 0 && p.weight != 0) {
                uint256 w = weightAt(pepeId, e);
                if (w != 0) alloc += (p.fees * w) / p.weight;
            }
        }
        return (alloc, p.weight, p.slope);
    }

    /// @dev Settle `pepeId` through the last closed epoch and pay the newly
    ///      allocated fees to `to`. Returns the amount paid.
    function _settleAndPay(uint256 pepeId, address to, bool forfeitOnShortfall) private returns (uint256 paid) {
        uint256 through = _lastClosedEpoch();
        (uint256 alloc, uint256 endW, uint256 endSlope) = _allocated(pepeId, through);
        Position storage pos = positions[pepeId];
        pos.settledEpoch = through;
        pos.settledW = endW;
        pos.settledSlope = endSlope;
        pos.feesPaid += alloc;
        paid = alloc;
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
            GlobalPoint memory p = _anchorNow();
            pos.startEpoch = e;
            pos.settledEpoch = e;
            pos.settledW = p.weight;
            pos.settledSlope = p.slope;
        } else {
            // re-anchor at full weight, live from e+1 (epoch e forfeited —
            // uniform with every other mutation)
            pos.startEpoch = e;
        }
        biasAdd[e] += amount;
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
            // slope partially applied — correct the live point directly and
            // restore the decayed-away weight (+dust) from the next boundary
            GlobalPoint memory p = _checkpoint();
            p.slope -= slope;
            points[p.epoch] = p;
            slopeSub[r + VEST_EPOCHS] -= slope;
            biasAdd[f] += (f - r) * slope + dust;
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
            biasSub[_epoch()] += amount; // flat-path exit: keep the global honest
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
        GlobalPoint memory p = _anchorNow();
        genesis.startEpoch = e; // (re)anchor increments (pre-launch: no fees yet)
        genesis.settledEpoch = e;
        genesis.settledW = p.weight;
        genesis.settledSlope = p.slope;
        biasAdd[e] += amount;
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
        uint256 through = _lastClosedEpoch();
        (uint256 alloc, uint256 endW, uint256 endSlope) = _allocated(0, through);

        uint256 genesisAmount = genesis.amount;
        uint256 shareFees = genesisAmount == 0 ? 0 : (alloc * share) / genesisAmount;
        genesis.settledEpoch = through;
        genesis.settledW = endW;
        genesis.settledSlope = endSlope;
        genesis.feesPaid += shareFees;
        genesis.amount = genesisAmount - share;
        genesis.actionTime = block.timestamp;

        uint256 e = _epoch();
        biasSub[e] += share;

        uint256 id = _mintFresh(user);
        GlobalPoint memory p = _anchorNow();
        Position storage pos = positions[id];
        pos.amount = share;
        pos.startEpoch = e;
        pos.settledEpoch = e;
        pos.settledW = p.weight;
        pos.settledSlope = p.slope;
        pos.actionTime = block.timestamp;
        biasAdd[e] += share;
        // totalLocked unchanged: share moves between positions

        if (shareFees != 0) _payFees(user, shareFees, true);

        emit Locked(user, id, share);
    }

    /// @dev Fee feed — controller forwards hook addFees() here. Fees credit
    ///      the CURRENT epoch's point and split by that epoch's weights.
    function addFees(uint256 mixETHAmount) external {
        if (msg.sender != address(controller)) revert NotController();
        pendingFeesMixETH += mixETHAmount;
        _distribute();
    }

    /// @dev Credit pending fees to the current epoch (orphans wait for weight).
    function _distribute() private {
        if (pendingFeesMixETH == 0) return;
        GlobalPoint memory p = _pointNow();
        if (p.weight == 0) return; // orphaned: distributes once weight exists
        p.fees += pendingFeesMixETH;
        pendingFeesMixETH = 0;
        points[p.epoch] = p;
        lastPointEpoch = p.epoch;
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

    /// @notice Live claimable fees for one pepe — the replay up to the last
    ///         closed epoch (new epochs only; paid epochs are settled away).
    function pendingFeesOf(uint256 pepeId) external view returns (uint256) {
        (uint256 alloc,,) = _allocated(pepeId, _lastClosedEpoch());
        return alloc;
    }

    /// @notice Timestamp when a decayed position becomes withdrawable
    ///         (type(uint).max while locked indefinitely).
    function withdrawableAt(uint256 pepeId) external view returns (uint256) {
        uint256 r = positions[pepeId].requestEpoch;
        return r == 0 ? type(uint256).max : (r + VEST_EPOCHS) * epochSize();
    }

    /// @notice Voting weight at instant `at`: Σ live position power over the
    ///         caller's pepes that existed by `at`. Governance-only view —
    ///         unlike the fee engine (where fresh locks go live at the next
    ///         epoch boundary so per-epoch splits stay exact), a position
    ///         carries FULL voting power from its creation epoch, so a new
    ///         stake can propose and vote immediately. Decay from an armed
    ///         withdraw request mirrors the fee engine step-for-step from the
    ///         request epoch onward (5/6, 4/6, … 0).
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
