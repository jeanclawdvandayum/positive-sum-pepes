// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICurveHook} from "./interfaces/ICurveHook.sol";
import {IRoundController} from "./interfaces/IRoundController.sol";

/// @dev Minimal descriptor slice (EIP-170 budget): metadata + SVG from DNA.
interface IPepeDescriptor {
    function tokenURI(uint256 dna) external pure returns (string memory);
}

/// @title PSPStaker — ERC-721 staking positions, indefinite locks, ve-style decay
/// @notice Every position is a pepe NFT (users may hold many). Locks are
///         INDEFINITE; `requestWithdraw(id)` starts a VEST_DURATION linear
///         decay (default 6 weeks) of BOTH dividend share and voting power:
///         1000 PSP staked → 5/6 weight after 1 week, 1/2 after 3, 0 after 6,
///         then `withdraw(id)` returns principal. `cancelWithdraw(id)` aborts
///         a decay and restores full power (the "extend" analog).
///
///         Fee accounting is dual-leg (see docs/VESTING-DESIGN.md): a classic
///         Synthetix accumulator over live total weight serves non-decaying
///         positions in O(1); decaying positions accrue from per-day buckets
///         at day-boundary weight (≤ VEST_DAYS iterations, bounded).
///
///         Hand-rolled minimal ERC-721 with enumeration (no OZ): creation
///         code embeds in RoundController — every byte counts against
///         EIP-170. Genesis virtual position lives at tokenId 0 (never
///         minted, never decays). tokenId 0 predates user pepe ids (which
///         start at 1), so the sentinel cannot collide.
contract PSPStaker {
    using SafeERC20 for IERC20;

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

    // ─────────────── Events (ERC-721) ───────────────
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    // ─────────────── Events (staking) ───────────────
    event Locked(address indexed user, uint256 indexed pepeId, uint256 amount);
    event WithdrawRequested(address indexed user, uint256 indexed pepeId);
    event WithdrawCancelled(address indexed user, uint256 indexed pepeId);
    event Withdrawn(address indexed user, uint256 indexed pepeId, uint256 amount);
    event FeesClaimed(address indexed user, uint256 indexed pepeId, uint256 amount);
    event FeesForfeited(address indexed user, uint256 mixETHAmount);

    // ─────────────── Immutables ───────────────
    IERC20 public immutable psp;
    IRoundController public immutable controller;
    uint256 public constant PRECISION = 1e18;

    // ─────────────── Staking state ───────────────
    struct Position {
        uint256 amount;       // principal PSP
        uint256 rewardDebt;   // classic-leg checkpoint (non-decaying)
        uint256 requestTime;  // 0 = indefinite lock (full power)
        uint256 actionTime;   // last weight-mutating action (vote guard)
        uint256 dayCursor;    // next unclaimed bucket day (decaying leg)
    }
    /// @dev pepeId-keyed: one position per NFT, many NFTs per user.
    ///      tokenId 0 = the genesis virtual position (predeposit pool).
    mapping(uint256 => Position) public positions;
    uint256 public totalLocked;             // Σ amount (principal, all positions)
    uint256 public accFeePerShareMixETH;    // classic leg, per full-weight PSP
    uint256 public pendingFeesMixETH;       // orphaned (zero weight) fees

    // decaying-set aggregate (O(1) exact bias via slope integral):
    // decayingBias(t) = _biasSnap - _slopeSum * (t - _snapTs)
    uint256 private _biasSnap;
    uint256 private _slopeSum;
    uint256 private _snapTs;
    uint256 public decayingPrincipal; // Σ amount of decaying positions
    /// @dev day => Σ (fee_i * PRECISION / totalWeight(t_i)) over the day's
    ///      fee events. Decaying positions read it at their day-boundary
    ///      bias; non-decaying positions never touch it.
    mapping(uint256 => uint256) public dayFeeAcc;

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

    // ─────────────── Weight math ───────────────

    /// @notice A position's live dividend/voting weight. Full amount while
    ///         indefinitely locked; linear decay after a withdraw request;
    ///         zero once the vest has run out.
    function biasOf(uint256 pepeId, uint256 at) public view returns (uint256) {
        Position storage pos = positions[pepeId];
        uint256 t = pos.requestTime;
        if (t == 0 || at <= t) return pos.amount;
        uint256 elapsed = at - t;
        uint256 vest = controller.VEST_DURATION();
        if (elapsed >= vest || pos.amount == 0) return 0;
        return pos.amount - (pos.amount * elapsed) / vest;
    }

    /// @notice Total live weight across all positions (full amounts of
    ///         non-decaying positions + decaying biases). Exact at `now`.
    function totalWeight() public view returns (uint256) {
        return totalLocked - decayingPrincipal + _decayingBiasNow();
    }

    function _decayingBiasNow() private view returns (uint256) {
        uint256 elapsed = block.timestamp - _snapTs;
        return _biasSnap > _slopeSum * elapsed ? _biasSnap - _slopeSum * elapsed : 0;
    }

    /// @dev Refresh the aggregate snapshot to now (O(1), exact).
    function _snap() private {
        _biasSnap = _decayingBiasNow();
        _snapTs = block.timestamp;
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

    /// @dev shared stake body. Reverts RequestActive on a decaying position:
    ///      one slope per position keeps the bias math exact (cancel first).
    function _stake(address user, uint256 pepeId, uint256 amount) private {
        _updateAccumulator();
        Position storage pos = positions[pepeId];
        if (pos.requestTime != 0) revert RequestActive();
        if (pos.amount > 0) _claimClassic(pepeId, msg.sender, true);

        psp.safeTransferFrom(msg.sender, address(this), amount);

        pos.amount += amount;
        pos.rewardDebt = (pos.amount * accFeePerShareMixETH) / PRECISION;
        pos.actionTime = block.timestamp;
        totalLocked += amount;

        emit Locked(user, pepeId, amount);
    }

    /// @notice Start the 6-week linear decay (dividends + votes). Claims the
    ///         classic fee leg first; bucket accrual starts the NEXT day
    ///         (conservative: today's post-request events are not paid twice).
    function requestWithdraw(uint256 pepeId) external {
        _requireOwner(pepeId);
        Position storage pos = positions[pepeId];
        if (pos.amount == 0) revert NotLocker();
        if (pos.requestTime != 0) revert RequestActive();

        _updateAccumulator();
        // state first (CEI): a reentrant addFees mid-payout must see the
        // decaying position already switched to the bucket leg.
        pos.requestTime = block.timestamp;
        pos.actionTime = block.timestamp;
        pos.dayCursor = _day(block.timestamp) + 1;
        _snap();
        _biasSnap += pos.amount;
        _slopeSum += pos.amount / controller.VEST_DURATION();
        decayingPrincipal += pos.amount;
        pos.rewardDebt = 0; // classic leg settled below

        _claimClassic(pepeId, msg.sender, true); // pays pos.amount*acc - 0 (pre-request)

        emit WithdrawRequested(msg.sender, pepeId);
    }

    /// @notice Abort a decay — restores full power immediately. Bucket-leg
    ///         fees earned while decaying are paid, then the position
    ///         rejoins the classic accumulator.
    function cancelWithdraw(uint256 pepeId) external {
        _requireOwner(pepeId);
        Position storage pos = positions[pepeId];
        if (pos.requestTime == 0) revert NotDecaying();

        _updateAccumulator();
        _removeFromDecayingSet(pepeId);
        pos.requestTime = 0;
        pos.actionTime = block.timestamp;
        pos.rewardDebt = (pos.amount * accFeePerShareMixETH) / PRECISION;

        _claimBucket(pepeId, msg.sender, true);

        emit WithdrawCancelled(msg.sender, pepeId);
    }

    /// @notice Withdraw principal after the decay completed (or any time
    ///         once the round is flat — carpet-bomb opens all locks). The
    ///         NFT survives as a husk: the pepe stays with its owner
    ///         forever, re-stakeable.
    function withdraw(uint256 pepeId) external {
        _requireOwner(pepeId);
        Position storage pos = positions[pepeId];
        if (pos.amount == 0) revert NotLocker();
        bool flat = controller.flatTime() != 0;
        if (pos.requestTime == 0) {
            if (!flat) revert NotDecaying(); // must request first
        } else if (!flat && block.timestamp < pos.requestTime + controller.VEST_DURATION()) {
            revert VestNotComplete();
        }

        _updateAccumulator();

        // settle fee legs BEFORE the position dies (forfeit-on-shortfall:
        // a fee leg must never block or eat principal)
        if (pos.requestTime != 0) {
            _claimBucket(pepeId, msg.sender, true);
        } else {
            _claimClassic(pepeId, msg.sender, true);
        }

        uint256 amount = pos.amount;
        if (pos.requestTime != 0) _removeFromDecayingSet(pepeId);
        totalLocked -= amount;
        delete positions[pepeId];

        psp.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, pepeId, amount);
    }

    /// @notice Claim accrued fees on one pepe. Pays mixETH via the hook to
    ///         the caller (or `to` — the reinvestor path). Owner or an
    ///         approved-for-all operator may call (the reinvestor flow:
    ///         approve it once, it claims straight into itself and compounds).
    function claimFees(uint256 pepeId) external {
        claimFeesTo(pepeId, msg.sender);
    }

    function claimFeesTo(uint256 pepeId, address to) public {
        if (to == address(0)) revert ZeroAddress();
        _requireAuthorized(pepeId);
        _updateAccumulator();
        Position storage pos = positions[pepeId];
        uint256 paid;
        if (pos.requestTime == 0) {
            paid = _claimClassic(pepeId, to, false); // strict: explicit intent
        } else {
            paid = _claimBucket(pepeId, to, false);
        }
        if (paid == 0) revert NothingToClaim();
        emit FeesClaimed(_ownerOf[pepeId], pepeId, paid);
    }

    /// @notice Multiclaim across pepes in one transaction, paying `to`.
    function claimAllTo(uint256[] calldata pepeIds, address to) public {
        if (to == address(0)) revert ZeroAddress();
        _updateAccumulator();
        uint256 totalPaid;
        for (uint256 i; i < pepeIds.length; ++i) {
            uint256 pepeId = pepeIds[i];
            _requireAuthorized(pepeId);
            Position storage pos = positions[pepeId];
            uint256 paid =
                pos.requestTime == 0 ? _claimClassic(pepeId, to, true) : _claimBucket(pepeId, to, true);
            totalPaid += paid;
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
        genesis.amount += amount;
        genesis.rewardDebt = (genesis.amount * accFeePerShareMixETH) / PRECISION;
        genesis.actionTime = block.timestamp;
        totalLocked += amount;
    }

    /// @dev Predeposit share claim: move `share` out of the genesis
    ///      position into a FRESH sequential pepe minted to `user`, paying
    ///      the share's accrued fees alongside (forfeit-on-shortfall).
    function claimGenesisShare(address user, uint256 share) external {
        if (msg.sender != address(controller)) revert NotController();

        _updateAccumulator();

        Position storage genesis = positions[0];

        uint256 accruedOnShare = (share * accFeePerShareMixETH) / PRECISION;
        if (accruedOnShare > 0) {
            _payFees(user, accruedOnShare, true);
        }

        genesis.amount -= share;
        genesis.rewardDebt = (genesis.amount * accFeePerShareMixETH) / PRECISION;

        uint256 id = _mintFresh(user);
        Position storage pos = positions[id];
        pos.amount = share;
        pos.rewardDebt = (share * accFeePerShareMixETH) / PRECISION;
        pos.actionTime = block.timestamp;
        // totalLocked unchanged: share moves between positions

        emit Locked(user, id, share);
    }

    /// @dev Fee accumulator feed — controller forwards hook addFees() here.
    function addFees(uint256 mixETHAmount) external {
        if (msg.sender != address(controller)) revert NotController();
        pendingFeesMixETH += mixETHAmount;
        _updateAccumulator();
    }

    // ─────────────── Fee internals ───────────────

    function _day(uint256 ts) private pure returns (uint256) {
        return ts / 1 days;
    }

    /// @dev Classic leg (non-decaying). Returns the amount paid to `to`.
    function _claimClassic(uint256 pepeId, address to, bool forfeitOnShortfall) private returns (uint256) {
        Position storage pos = positions[pepeId];
        uint256 pending = (pos.amount * accFeePerShareMixETH) / PRECISION - pos.rewardDebt;
        if (pending == 0) return 0;
        pos.rewardDebt = (pos.amount * accFeePerShareMixETH) / PRECISION;
        _payFees(to, pending, forfeitOnShortfall);
        return pending;
    }

    /// @dev Bucket leg (decaying): Σ dayFeeAcc[d] × bias(day start) / P for
    ///      unclaimed days. bias hits zero at vest end — loop is bounded by
    ///      VEST_DAYS regardless of claim latency. Pays `to`.
    function _claimBucket(uint256 pepeId, address to, bool forfeitOnShortfall) private returns (uint256) {
        Position storage pos = positions[pepeId];
        if (pos.requestTime == 0) return 0;
        uint256 d = pos.dayCursor;
        if (d == 0) return 0;
        uint256 end = _day(block.timestamp);
        uint256 vestEndDay = _day(pos.requestTime + controller.VEST_DURATION());
        if (end > vestEndDay) end = vestEndDay;
        uint256 total;
        while (d <= end) {
            uint256 delta = dayFeeAcc[d];
            if (delta != 0) {
                // bias at the day's start (pure per position)
                uint256 w = biasOf(pepeId, d * 1 days);
                if (w != 0) total += (delta * w) / PRECISION;
            }
            ++d;
        }
        pos.dayCursor = d;
        if (total == 0) return 0;
        _payFees(to, total, forfeitOnShortfall);
        return total;
    }

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

    /// @dev Distribute pending fees across the live total weight. Both legs
    ///      read the SAME per-token delta: non-decaying positions via the
    ///      classic accumulator, decaying positions via the day bucket.
    function _updateAccumulator() private {
        if (pendingFeesMixETH == 0) return;
        uint256 w = totalWeight();
        if (w == 0) return; // orphaned: distributes once weight exists
        uint256 delta = (pendingFeesMixETH * PRECISION) / w;
        accFeePerShareMixETH += delta;
        dayFeeAcc[_day(block.timestamp)] += delta;
        pendingFeesMixETH = 0;
    }

    function _requireOwner(uint256 pepeId) private view {
        if (_ownerOf[pepeId] != msg.sender) revert NotNftOwner();
    }

    /// @dev owner OR approved-for-all operator (the reinvestor flow).
    function _requireAuthorized(uint256 pepeId) private view {
        address owner = _ownerOf[pepeId];
        if (owner != msg.sender && !_operator[owner][msg.sender]) revert NotNftOwner();
    }

    /// @dev Remove a position from the decaying-set aggregate (snap first).
    function _removeFromDecayingSet(uint256 pepeId) private {
        Position storage pos = positions[pepeId];
        _snap();
        _biasSnap -= biasOf(pepeId, block.timestamp);
        _slopeSum -= pos.amount / controller.VEST_DURATION();
        decayingPrincipal -= pos.amount;
    }

    // ─────────────── Registry oracle views ───────────────

    /// @notice First pepe of `user` (0 if none) — the referral chain's
    ///         per-user identity (edges bind there, so cycle detection
    ///         stays complete in the multi-NFT world).
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

    /// @notice Live claimable fees for one pepe (classic or bucket leg —
    ///         whichever the position is on). View-side mirror of the claim
    ///         math; the frontend's "[claim – X mixETH]" label.
    function pendingFeesOf(uint256 pepeId) external view returns (uint256) {
        Position storage pos = positions[pepeId];
        if (pos.requestTime == 0) {
            return (pos.amount * accFeePerShareMixETH) / PRECISION - pos.rewardDebt;
        }
        if (pos.dayCursor == 0) return 0;
        uint256 d = pos.dayCursor;
        uint256 end = _day(block.timestamp);
        uint256 vestEndDay = _day(pos.requestTime + controller.VEST_DURATION());
        if (end > vestEndDay) end = vestEndDay;
        uint256 total;
        while (d <= end) {
            uint256 delta = dayFeeAcc[d];
            if (delta != 0) {
                uint256 w = biasOf(pepeId, d * 1 days);
                if (w != 0) total += (delta * w) / PRECISION;
            }
            ++d;
        }
        return total;
    }

    /// @notice Voting weight at a past instant `at` (propose snapshot):
    ///         Σ bias(id, at) over the caller's pepes whose last weight
    ///         mutation predates `at` (finding-29 guard: post-propose
    ///         lock/top-up/request/cancel actions sit the vote out).
    function voteWeight(address user, uint256 at) external view returns (uint256) {
        uint256[] storage ids = _owned[user];
        uint256 total;
        for (uint256 i; i < ids.length; ++i) {
            Position storage pos = positions[ids[i]];
            if (pos.actionTime < at) total += biasOf(ids[i], at);
        }
        return total;
    }
}
