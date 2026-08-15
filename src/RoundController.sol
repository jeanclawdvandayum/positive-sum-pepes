// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {PSPToken} from "./PSPToken.sol";
import {CurveHook} from "./CurveHook.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {IRoundController} from "./interfaces/IRoundController.sol";

/// @title RoundController — Lifecycle management for one PSP round
/// @notice Handles predeposit, locking, fee distribution, yield reinvestment, and destruction governance.
contract RoundController is IRoundController, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using CurveMath for CurveMath.CurveConfig;

    // ─────────────── Errors ───────────────
    error NotHook();
    error NotActive();
    error NotPredeposit();
    error PredepositClosed();
    error ZeroAmount();
    error ZeroAddress();
    error NothingToClaim();
    error NotLocker();
    error ProposalExists();
    error VotingEnded();
    error AlreadyVoted();
    error QuorumNotReached();
    error MajorityNotReached();
    error AlreadyExecuted();
    error LockNotExpired();
    error TooEarlyToRelock();
    error RoundDestroyed();
    error VoteLockedAfterPropose();
    error ProtectedToken(); // L-3: sweep() protection has its own error, not ZeroAddress
    error ZeroShare(); // L-4: predeposit share rounded to 0 — claim refused, flag not set

    // ─────────────── Events ───────────────
    event Predeposited(address indexed user, uint256 ethAmount, uint256 mixETHAmount);
    event Launched(uint256 totalMixETH, uint256 totalPSP);
    event Locked(address indexed user, uint256 amount);
    event Unlocked(address indexed user, uint256 amount);
    event Relocked(address indexed user, uint256 newUnlockTime);
    event FeesClaimed(address indexed user, uint256 amount);
    event FeesForfeited(address indexed user, uint256 mixETHAmount);
    event CarpetBombProposed(address indexed proposer);
    event Voted(address indexed voter, bool support, uint256 weight);
    event CarpetBombExecuted(uint256 mixETHCarried);
    event FeesAdded(uint256 mixETHAmount);

    // ─────────────── Immutables ───────────────
    PSPToken public immutable pspToken;
    IERC20 public immutable mixETH;
    CurveMath.CurveConfig public curveConfig;
    address public immutable factory;

    // ─────────────── Hook ref ───────────────
    CurveHook public hook;

    // ─────────────── Predeposit ───────────────
    struct DepositInfo {
        uint256 mixETHAmount;
        bool claimed;
    }
    mapping(address => DepositInfo) public predeposits;
    uint256 public totalPredepositMixETH;
    uint256 public totalPredepositors;
    uint256 public totalInitialPSP; // snapshot of PSP minted at launch
    bool public predepositClosed;

    // ─────────────── Locking (vlCVX-style) ───────────────
    uint256 public constant LOCK_DURATION = 90 days;   // 3 months
    uint256 public constant RELOCK_WINDOW = 7 days;     // last week before expiry
    uint256 public constant PRECISION = 1e18;

    struct LockInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lockTime;
        uint256 unlockTime; // block.timestamp + LOCK_DURATION
    }
    mapping(address => LockInfo) public locks;
    uint256 public totalLocked;

    uint256 public accFeePerShareMixETH; // accumulated fees per share, mixETH (1e18 scaled)
    uint256 public pendingFeesMixETH;    // total unallocated fees (mixETH)

    // ─────────────── Factory round tracking ───────────────
    uint256 public factoryRoundId;

    // ─────────────── Governance ───────────────
    struct CarpetBombProposal {
        address proposer;
        uint256 proposeTime;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 lockedAtPropose; // G-1 fix: quorum snapshot — mid-vote locks can't inflate denominator
        bool executed;
    }
    CarpetBombProposal public currentProposal;
    /// @dev G-3 fix: epoch per proposal. Voters compare lastVotedOn == proposalCount,
    ///      so a new proposal re-enfranchises everyone without iterating a mapping.
    uint256 public proposalCount;
    mapping(address => uint256) public lastVotedOn;
    uint256 public constant VOTE_DURATION = 3 days;
    uint256 public constant QUORUM_BIPS = 6900;  // 69% of locked PSP (nice)
    uint256 public constant MAJORITY_BIPS = 5001; // >50% of cast votes

    // ─────────────── Constructor ───────────────
    constructor(
        PSPToken _pspToken,
        IERC20 _mixETH,
        CurveMath.CurveConfig memory _config,
        address _factory
    ) Ownable(_factory) {
        if (address(_pspToken) == address(0)) revert ZeroAddress();
        if (address(_mixETH) == address(0)) revert ZeroAddress();
        if (_factory == address(0)) revert ZeroAddress();
        pspToken = _pspToken;
        mixETH = _mixETH;
        curveConfig = _config;
        factory = _factory;
    }

    // ─────────────── Modifiers ───────────────
    modifier onlyHook() {
        if (msg.sender != address(hook)) revert NotHook();
        _;
    }

    // ─────────────── Hook Setup ───────────────
    function setHook(CurveHook _hook) external onlyOwner {
        hook = _hook;
    }

    function setFactoryRoundId(uint256 _roundId) external onlyOwner {
        factoryRoundId = _roundId;
    }

    // ─────────────── IRoundController Implementation ───────────────

    function getPSP() external view returns (address) { return address(pspToken); }
    function getMixETH() external view returns (Currency) { return Currency.wrap(address(mixETH)); }
    function getCurveConfig() external view returns (CurveMath.CurveConfig memory) { return curveConfig; }

    /// @dev DISPLAY ONLY — NK24 F1: mixETH is the sole unit of account.
    ///      This view exists solely for the Predeposited event field and
    ///      CurveHook.totalReserveETH(). Never call it in any settlement,
    ///      mint, burn, fee, or accounting path.
    function mixETHToETH(uint256 mixETHAmount) public view returns (uint256) {
        if (mixETHAmount == 0) return 0;
        // ERC-4626: assets = shares * totalAssets / totalSupply
        uint256 totalAssets = _getTotalAssets();
        uint256 totalSupply = mixETH.totalSupply();
        if (totalSupply == 0) return mixETHAmount; // 1:1 if no supply yet
        return (mixETHAmount * totalAssets) / totalSupply;
    }

    function _getTotalAssets() internal view returns (uint256) {
        // Try standard ERC-4626 totalAssets, fallback to balance
        (bool success, bytes memory data) = address(mixETH).staticcall(
            abi.encodeWithSelector(0x01e1d114) // totalAssets()
        );
        if (success && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        return mixETH.balanceOf(address(this));
    }

    // ── Swap support (called by hook) ──

    function mintPSPForSwap(uint256 amount) external onlyHook {
        pspToken.mint(address(hook), amount);
    }

    function burnPSPForSwap(uint256 amount) external onlyHook {
        pspToken.burn(address(hook), amount);
    }

    /// @notice Add swap fees to the accumulator (mixETH-denominated — NK24 unit fix)
    function addFees(uint256 mixETHAmount) external onlyHook {
        pendingFeesMixETH += mixETHAmount;
        _updateAccumulator();
        emit FeesAdded(mixETHAmount);
    }

    // ─────────────── Predeposit ───────────────

    function predeposit(uint256 mixETHAmount) external nonReentrant {
        if (predepositClosed) revert PredepositClosed();
        if (mixETHAmount == 0) revert ZeroAmount();

        // Use balanceBefore/After to support fee-on-transfer tokens safely
        uint256 balBefore = mixETH.balanceOf(address(this));
        mixETH.safeTransferFrom(msg.sender, address(this), mixETHAmount);
        uint256 balAfter = mixETH.balanceOf(address(this));
        uint256 actualAmount = balAfter - balBefore;
        if (actualAmount == 0) revert ZeroAmount();

        if (predeposits[msg.sender].mixETHAmount == 0) {
            totalPredepositors++;
        }
        predeposits[msg.sender].mixETHAmount += actualAmount;
        totalPredepositMixETH += actualAmount;

        // Predeposited.ethAmount is display-only (current rate) — accounting
        // is purely mixETH-denominated
        emit Predeposited(msg.sender, mixETHToETH(actualAmount), actualAmount);
    }

    function launchPooledBuy() external onlyOwner nonReentrant {
        if (predepositClosed) revert PredepositClosed();
        predepositClosed = true;

        // Transfer predeposit mixETH to hook (hook holds all curve reserves + fees)
        mixETH.safeTransfer(address(hook), totalPredepositMixETH);

        // NK24 fix: the curve's unit of account is mixETH — the genesis buy is
        // computed directly from the predeposit amount. (The old code converted
        // through the vault rate, making initial supply rate-dependent.)
        uint256 initialPSP = CurveMath.computeBuyOutput(totalPredepositMixETH, 0, curveConfig);
        if (initialPSP == 0) revert ZeroAmount();

        // Snapshot for proportional claims (prevents donation attacks)
        totalInitialPSP = initialPSP;

        // Initialize the hook's curve state with actual mixETH amount
        hook.initializeCurve(totalPredepositMixETH, initialPSP);

        // Mint PSP to all depositors proportionally
        _distributeInitialPSP(initialPSP);

        // NK24 genesis-lock fix: the controller itself locks ALL initial PSP in
        // this same transaction as the genesis buy. totalLocked therefore
        // covers the entire initial supply from the very first post-launch
        // block, so swap fees distribute pro-rata across all predepositors —
        // the first-locker solo window (98.8% fee capture PoC) cannot exist.
        // Predepositors claim out of this virtual lock lazily via
        // claimPredepositPSP(), which also pays out the fees their share has
        // accrued since launch. O(1) gas: no depositor loop, so launch can
        // never outgrow the block gas limit.
        locks[address(this)] = LockInfo({
            amount: initialPSP,
            rewardDebt: 0, // accFeePerShareMixETH is 0 at launch (no swaps pre-Active)
            lockTime: block.timestamp,
            unlockTime: block.timestamp + LOCK_DURATION
        });
        totalLocked += initialPSP;

        // Activate the hook
        hook.setMode(CurveHook.Mode.Active);

        emit Launched(totalPredepositMixETH, initialPSP);
    }

    function _distributeInitialPSP(uint256 initialPSP) internal {
        // Mint all PSP to this contract, then distribute
        pspToken.mint(address(this), initialPSP);

        // For simplicity and gas, depositors claim manually
        // Alternatively, do a loop (gas-expensive for many depositors)
        // For now, depositors call claimPredepositPSP()
    }

    /// @notice Claim predeposit PSP — auto-locked for 90 days (vlCVX-style)
    /// @dev All initial bonding curve PSP must be locked. PSP stays at controller,
    ///      just credits the user's lock position. The share (and every fee it
    ///      accrued since the genesis lock) is moved out of the controller's
    ///      virtual lock (see launchPooledBuy) — claiming late costs nothing.
    function claimPredepositPSP() external nonReentrant {
        DepositInfo storage dep = predeposits[msg.sender];
        if (dep.claimed) revert PredepositClosed();
        if (dep.mixETHAmount == 0) revert ZeroAmount();

        // L-4: compute and validate the share BEFORE flipping the claimed
        // flag — a dust depositor whose share truncates to 0 must not be
        // irreversibly marked claimed (and stuck with a 0-amount lock that
        // sets lockTime). Reverting here leaves dep.claimed = false, so the
        // claim can be retried later if a larger share ever applies.
        uint256 share = (totalInitialPSP * dep.mixETHAmount) / totalPredepositMixETH;
        if (share == 0) revert ZeroShare();

        dep.claimed = true;

        _updateAccumulator();

        LockInfo storage userLock = locks[msg.sender];
        LockInfo storage genesisLock = locks[address(this)];

        // Claim pending fees on an existing lock (L-5: unified with every
        // other principal path — forfeit on shortfall)
        if (userLock.amount > 0) {
            _claimPendingFees(true);
        }

        // Fees accrued by this share since launch (genesis rewardDebt was 0):
        // they belong to the claimer, paid straight out of the hook's fee
        // surplus. Forfeit on shortfall, same M-2 semantics as every other
        // path — a fee leg must never block PSP principal.
        uint256 accruedOnShare = (share * accFeePerShareMixETH) / PRECISION;
        if (accruedOnShare > 0) {
            try hook.sendFees(msg.sender, accruedOnShare) {}
            catch {
                emit FeesForfeited(msg.sender, accruedOnShare);
            }
        }

        // Move the share from the genesis virtual lock to the user's lock
        genesisLock.amount -= share;
        genesisLock.rewardDebt = (genesisLock.amount * accFeePerShareMixETH) / PRECISION;

        userLock.amount += share;
        userLock.rewardDebt = (userLock.amount * accFeePerShareMixETH) / PRECISION;
        userLock.lockTime = block.timestamp;
        userLock.unlockTime = block.timestamp + LOCK_DURATION;
        // totalLocked unchanged: the share moves between lock positions

        emit Locked(msg.sender, share);
    }

    // ─────────────── Locking (vlCVX-style) ───────────────

    /// @notice Lock PSP for 90 days. Earns fee share via accumulator.
    ///         Adding to an existing lock resets the timer.
    function lock(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Z-1 fix: no locking into a destroyed round — the hook is drained,
        // fees will never accrue again, PSP would sit dead for 90 days
        if (address(hook) != address(0) && hook.mode() == CurveHook.Mode.Destroyed) {
            revert RoundDestroyed();
        }

        _updateAccumulator();

        LockInfo storage userLock = locks[msg.sender];

        // Claim pending fees first (forfeit on shortfall: a short surplus
        // must not block locking — Z-1/M-2 interaction)
        if (userLock.amount > 0) {
            _claimPendingFees(true);
        }

        IERC20(address(pspToken)).safeTransferFrom(msg.sender, address(this), amount);

        userLock.amount += amount;
        userLock.rewardDebt = (userLock.amount * accFeePerShareMixETH) / PRECISION;
        userLock.lockTime = block.timestamp;
        userLock.unlockTime = block.timestamp + LOCK_DURATION;
        totalLocked += amount;

        emit Locked(msg.sender, amount);
    }

    /// @notice Withdraw PSP after lock expires
    function unlock() external nonReentrant {
        LockInfo storage userLock = locks[msg.sender];
        if (userLock.amount == 0) revert NotLocker();
        if (block.timestamp < userLock.unlockTime) revert LockNotExpired();

        _updateAccumulator();

        // Claim pending fees (M-2: forfeit on shortfall — PSP principal must
        // never be trapped by an unpayable fee leg, e.g. post-carpet drain)
        _claimPendingFees(true);

        uint256 amount = userLock.amount;
        totalLocked -= amount;
        userLock.amount = 0;
        userLock.rewardDebt = 0;

        IERC20(address(pspToken)).safeTransfer(msg.sender, amount);

        emit Unlocked(msg.sender, amount);
    }

    /// @notice Extend lock for another 90 days. Only callable in the last 7 days.
    function relock() external nonReentrant {
        LockInfo storage userLock = locks[msg.sender];
        if (userLock.amount == 0) revert NotLocker();
        if (userLock.unlockTime == 0) revert NotLocker();
        // Only in the relock window (last 7 days before expiry)
        if (block.timestamp < userLock.unlockTime - RELOCK_WINDOW) revert TooEarlyToRelock();

        // Claim pending fees before resetting (H-1 rewardDebt refresh +
        // M-2 forfeit-on-shortfall, unified in _claimPendingFees)
        _updateAccumulator();
        _claimPendingFees(true);

        userLock.unlockTime = block.timestamp + LOCK_DURATION;
        userLock.lockTime = block.timestamp;

        emit Relocked(msg.sender, userLock.unlockTime);
    }

    function claimFees() external nonReentrant {
        LockInfo storage userLock = locks[msg.sender];
        if (userLock.amount == 0) revert NotLocker();

        _updateAccumulator();

        uint256 pending = _pendingFees(msg.sender);
        if (pending == 0) revert NothingToClaim();

        // Strict: caller's explicit intent is to receive fees — a surplus
        // shortfall reverts InsufficientFees (informative) rather than
        // silently forfeiting. Principal remains recoverable via unlock().
        _claimPendingFees(false);

        emit FeesClaimed(msg.sender, pending);
    }

    function _pendingFees(address user) internal view returns (uint256) {
        LockInfo storage userLock = locks[user];
        return (userLock.amount * accFeePerShareMixETH) / PRECISION - userLock.rewardDebt;
    }

    /// @dev Unified fee-claim leg (H-1 + M-2). ALWAYS refreshes rewardDebt
    ///      before paying (double-claim fix), and optionally forfeits when the
    ///      hook's fee surplus can't cover the pending amount instead of
    ///      reverting — a reverted fee leg must never trap PSP principal
    ///      (post-carpet drain).
    ///      Forfeit paths: unlock/relock/lock-top-up (principal > fees).
    ///      Strict path: claimFees (caller's explicit intent is to receive
    ///      fees; a shortfall reverts informatively rather than silently
    ///      burning them).
    ///      NK24: pendings are mixETH-denominated natively — no vault-rate
    ///      conversion anywhere in this path.
    function _claimPendingFees(bool forfeitOnShortfall) internal {
        uint256 pending = _pendingFees(msg.sender);
        if (pending == 0) return;

        LockInfo storage userLock = locks[msg.sender];
        userLock.rewardDebt = (userLock.amount * accFeePerShareMixETH) / PRECISION;

        if (forfeitOnShortfall) {
            try hook.sendFees(msg.sender, pending) {}
            catch {
                // M-2: hook surplus short (InsufficientFees). Forfeit the
                // fees, release the principal path.
                emit FeesForfeited(msg.sender, pending);
            }
        } else {
            hook.sendFees(msg.sender, pending);
        }
    }

    function _updateAccumulator() internal {
        if (totalLocked == 0) {
            return;
        }
        if (pendingFeesMixETH == 0) return;

        accFeePerShareMixETH += (pendingFeesMixETH * PRECISION) / totalLocked;
        pendingFeesMixETH = 0;
    }

    // ─────────────── Destruction Governance ───────────────

    function proposeCarpetBomb() external nonReentrant {
        if (locks[msg.sender].amount == 0) revert NotLocker();

        // No governance theater on a destroyed round
        if (address(hook) != address(0) && hook.mode() == CurveHook.Mode.Destroyed) {
            revert RoundDestroyed();
        }

        // G-2 fix: a proposal only blocks new ones during its live voting window.
        // After the window passes unexecuted, the next propose replaces it —
        // governance can never be permanently bricked by a dead proposal.
        //
        // G-4 fix: BUT a PASSING proposal (quorum + majority met) must be
        // EXECUTED, not replaced — otherwise an attacker front-runs the
        // execute tx with propose() to wipe the votes and force endless
        // re-vote cycles. Only FAILED proposals are replaceable.
        if (currentProposal.proposeTime != 0 && !currentProposal.executed) {
            if (block.timestamp <= currentProposal.proposeTime + VOTE_DURATION) {
                revert ProposalExists();
            }
            // Window closed, unexecuted: replaceable only if it failed
            uint256 totalVotes = currentProposal.yesVotes + currentProposal.noVotes;
            bool quorumPassed = totalVotes * 10000 >= currentProposal.lockedAtPropose * QUORUM_BIPS;
            bool majorityPassed = currentProposal.yesVotes * 10000 > totalVotes * MAJORITY_BIPS;
            if (quorumPassed && majorityPassed) {
                revert ProposalExists(); // passing — go execute it (permissionless)
            }
        }

        proposalCount++;
        currentProposal = CarpetBombProposal({
            proposer: msg.sender,
            proposeTime: block.timestamp,
            yesVotes: 0,
            noVotes: 0,
            // NK24 thin-lock fix: quorum is measured against the larger of
            // totalLocked and the hook's total PSP supply. Against a bare
            // totalLocked snapshot, an attacker could buy a large bag on the
            // curve (unminting nothing), lock it, propose when honest lock
            // participation is thin, and self-vote past quorum+majority to
            // bomb the round out from under unlocked holders. With the supply
            // floor, they must lock QUORUM% of EVERYTHING outstanding — the
            // bomb damages their own position proportionally, killing the
            // economics. Supply only shrinks via curve sells (burns), so the
            // denominator can't be thinned either.
            lockedAtPropose: _quorumDenominator(),
            executed: false
        });

        emit CarpetBombProposed(msg.sender);
    }

    /// @dev Quorum denominator: max(locked, total PSP supply) — see proposeCarpetBomb
    function _quorumDenominator() internal view returns (uint256) {
        uint256 supply = address(hook) != address(0) ? hook.totalSupplyPSP() : 0;
        return totalLocked > supply ? totalLocked : supply;
    }

    function voteCarpetBomb(bool support) external nonReentrant {
        LockInfo storage userLock = locks[msg.sender];
        if (userLock.amount == 0) revert NotLocker();
        if (currentProposal.proposeTime == 0) revert ProposalExists();
        if (block.timestamp > currentProposal.proposeTime + VOTE_DURATION) revert VotingEnded();
        // G-3 fix: per-proposal epoch — voters from previous proposals can vote again
        if (lastVotedOn[msg.sender] == proposalCount) revert AlreadyVoted();

        lastVotedOn[msg.sender] = proposalCount;

        // M-1 fix: vote weight must come from locks that existed at propose
        // time. Any lock(), top-up, or relock after proposeTime resets
        // lockTime — such users sit this proposal out. Since amounts can only
        // DECREASE after propose (unlock) and any increase resets lockTime,
        // totalVotes is structurally capped at lockedAtPropose. Kills the
        // post-snapshot lock-capture vector (lock 2M after propose, outvote
        // a thin snapshot).
        if (userLock.lockTime >= currentProposal.proposeTime) revert VoteLockedAfterPropose();

        if (support) {
            currentProposal.yesVotes += userLock.amount;
        } else {
            currentProposal.noVotes += userLock.amount;
        }

        emit Voted(msg.sender, support, userLock.amount);
    }

    function carpetBomb() external nonReentrant {
        CarpetBombProposal storage prop = currentProposal;
        if (prop.proposeTime == 0) revert ProposalExists();
        if (prop.executed) revert AlreadyExecuted();
        if (block.timestamp <= prop.proposeTime + VOTE_DURATION) revert VotingEnded();

        // Check quorum against the SNAPSHOT taken at proposal time (G-1 fix):
        // locking PSP mid-vote can no longer dilute participation below quorum
        uint256 totalVotes = prop.yesVotes + prop.noVotes;
        if (totalVotes * 10000 < prop.lockedAtPropose * QUORUM_BIPS) revert QuorumNotReached();

        // Check majority
        if (prop.yesVotes * 10000 <= totalVotes * MAJORITY_BIPS) revert MajorityNotReached();

        prop.executed = true;

        // Flatten the curve
        hook.setMode(CurveHook.Mode.Flat);

        // Mark destroyed
        hook.setMode(CurveHook.Mode.Destroyed);

        // Drain ALL mixETH from hook to factory for next round
        uint256 mixETHCarried = hook.drainAll(factory);

        // Notify factory that this round is destroyed
        (bool ok,) = factory.call(abi.encodeWithSignature("markDestroyed(uint256)", factoryRoundId));
        require(ok, "FactoryMarkFailed");

        emit CarpetBombExecuted(mixETHCarried);
    }

    function getCarpetBombState() external view returns (
        address proposer,
        uint256 proposeTime,
        uint256 yesVotes,
        uint256 noVotes,
        bool executed,
        bool canExecute
    ) {
        CarpetBombProposal storage prop = currentProposal;
        proposer = prop.proposer;
        proposeTime = prop.proposeTime;
        yesVotes = prop.yesVotes;
        noVotes = prop.noVotes;
        executed = prop.executed;
        canExecute = prop.proposeTime != 0
            && !prop.executed
            && block.timestamp > prop.proposeTime + VOTE_DURATION;
    }

    // ─────────────── Safety ───────────────

    // L-3: emergencyPause() removed. It was a no-op behind onlyOwner — a name
    // promising a pause that does not exist (dead code, misleading surface).

    function sweep(address token) external onlyOwner {
        // L-3: ZeroAddress is reserved for the actual zero-address case;
        // protected tokens revert with their own error.
        if (token == address(0)) revert ZeroAddress();
        // PSP is permanently protected: it is user principal (locked PSP
        // and unclaimed predeposit allocations) custodied here forever.
        if (token == address(pspToken)) revert ProtectedToken();
        // mixETH is protected only until launch (I-1): pre-launch the
        // controller custodies accounted predeposits; launchPooledBuy then
        // transfers exactly totalPredepositMixETH to the hook, leaving the
        // accounted balance at zero. Any mixETH still here afterwards is
        // stray (donations, misroutes) with no user claim on it — rescuable.
        if (token == address(mixETH) && !predepositClosed) revert ProtectedToken();
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(owner(), balance);
    }
}
