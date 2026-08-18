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
    error FactoryMarkFailed();
    error FactorySpawnFailed();
    error ProposalExists();
    error VotingEnded();
    error AlreadyVoted();
    error QuorumNotReached();
    error MajorityNotReached();
    error AlreadyExecuted();
    error LockNotExpired();
    error TooEarlyToRelock();
    error RoundDestroyed();
    error RoundFlattened();
    error NotFlattened();
    error ExitWindowOpen();
    error VoteLockedAfterPropose();
    error ProtectedToken(); // L-3: sweep() protection has its own error, not ZeroAddress
    error ZeroShare(); // L-4: predeposit share rounded to 0 — claim refused, flag not set
    error PredepositOpen(); // window still live and cap not reached — only owner may launch early
    error CapExceeded(); // public predeposit would push total past PREDEPOSIT_CAP
    error NotFactory(); // carry seeding is factory-only

    // ─────────────── Events ───────────────
    event Predeposited(address indexed user, uint256 ethAmount, uint256 mixETHAmount);
    event CarrySeeded(uint256 mixETHAmount);
    event Launched(uint256 totalMixETH, uint256 totalPSP);
    event Locked(address indexed user, uint256 amount);
    event Unlocked(address indexed user, uint256 amount);
    event Relocked(address indexed user, uint256 newUnlockTime);
    event FeesClaimed(address indexed user, uint256 amount);
    event FeesForfeited(address indexed user, uint256 mixETHAmount);
    event CarpetBombProposed(address indexed proposer);
    event Voted(address indexed voter, bool support, uint256 weight);
    event CarpetBombExecuted(uint256 potRedemption);
    event RoundFinalized(uint256 mixETHCarried);
    event FeesAdded(uint256 mixETHAmount);
    event PotPSPCredited(uint256 pspAmount); // side pot PSP accrued (swap cuts + launch share)
    event PotDeposited(uint256 mixETHAmount); // factory side-pot funding received
    event PotRedeemed(uint256 pspAmount, uint256 mixETHOut); // carpet-bomb exit at average backing

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

    /// @dev Predeposit window: opens at deployment, closes at cap or expiry.
    ///      Anyone may launch once the cap is reached or the week elapses;
    ///      the owner (factory) may also launch early. Carry seeding from a
    ///      previous round's destruction is exempt from the cap — it IS the
    ///      bootstrap, and if it alone reaches the cap the round is instantly
    ///      launchable by anyone.
    uint256 public constant PREDEPOSIT_DURATION = 7 days;
    uint256 public constant PREDEPOSIT_CAP = 500e18; // 500 mixETH
    uint256 public immutable predepositStartTime;

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

    /// @dev bomb time — nonzero means the round is flat and every lock is
    ///      open for immediate exit at average backing. (No separate
    ///      finalized flag: setMode(Destroyed) makes finalizeCarpet
    ///      idempotently reverting on its own.)
    uint256 public flatTime;

    uint256 public accFeePerShareMixETH; // accumulated fees per share, mixETH (1e18 scaled)
    uint256 public pendingFeesMixETH;    // total unallocated fees (mixETH)

    // ─────────────── Side pot (protocol reserve) ───────────────
    /// @dev PSP accumulated by the 25bps pot fee (buy mints + sell skims)
    ///      plus the pot's share of the genesis mint. Held UNLOCKED at this
    ///      contract for the round's entire life: never staked (no fee claim,
    ///      no vote weight), never sold. Its only exit is carpetBomb(), which
    ///      redeems it at average backing into mixETH for the factory's side
    ///      pot — the next round's users get that backing as a thicker curve,
    ///      not as predeposit shares.
    uint256 public potPSPBalance;
    /// @dev mixETH the factory forwarded via potDeposit() — joins the curve
    ///      reserve at launch ON TOP of the 500-mixETH public predeposit cap.
    uint256 public totalPotMixETH;
    /// @dev Genesis mint minus the pot's share — the claimable pool behind
    ///      claimPredepositPSP(). Snapshot at launch, never mutates.
    uint256 public genesisPSPSnapshot;

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
    uint256 public constant FLAT_EXIT_WINDOW = 3 days;
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
        // Validate here (not the factory): CurveMath.validate inlines the
        // entire curve engine into the caller — the factory blew past EIP-170's
        // 24KB limit. The controller needs CurveMath anyway for launch pricing.
        CurveMath.validate(_config);
        curveConfig = _config;
        factory = _factory;
        predepositStartTime = block.timestamp;
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

    /// @notice Mint the side pot's PSP (buy-path fee cut) — hook-only
    /// @dev Minted fresh through the curve with its own mixETH backing; held
    ///      here unlocked. Never enters the lock ledger.
    ///      H-1 fix: the PSP must be REAL. The hook's supply ledger counts
    ///      potPSP (totalSupplyPSP += pspOut + potPSP) and carpetBomb()
    ///      burns potPSPBalance from this wallet — a ledger-only credit left
    ///      the wallet short of totalLocked by exactly the phantom amount,
    ///      bricking the last staker(s) to unlock (ERC20InsufficientBalance,
    ///      permanent). Invariant after this fix:
    ///        psp.balanceOf(controller) == totalLocked + potPSPBalance
    function mintPotPSP(uint256 amount) external onlyHook {
        potPSPBalance += amount;
        pspToken.mint(address(this), amount);
        emit PotPSPCredited(amount);
    }

    /// @notice Credit side-pot PSP already transferred here (sell-path fee
    ///         cut — skimmed off the burn, backing stays in the reserve)
    function creditPotPSP(uint256 amount) external onlyHook {
        potPSPBalance += amount;
        emit PotPSPCredited(amount);
    }

    /// @notice Everything a UI needs about the side pot.
    function potState() external view returns (uint256 pspBalance, uint256 mixETHFunded) {
        return (potPSPBalance, totalPotMixETH);
    }

    // ─────────────── Predeposit ───────────────

    function predeposit(uint256 mixETHAmount) external nonReentrant {
        _predepositFor(msg.sender, mixETHAmount);
    }

    /// @notice Deposit on behalf of a beneficiary (e.g. the ETH zap router:
    ///         it wraps ETH into mixETH and deposits, but the PSP must be
    ///         credited to the human, not the router).
    /// @dev Identical accounting to predeposit(); permissionless by design
    ///      (same as ERC-4626 depositFor — depositing FOR someone can only
    ///      credit them, never debit).
    function predepositFor(address beneficiary, uint256 mixETHAmount) external nonReentrant {
        _predepositFor(beneficiary, mixETHAmount);
    }

    function _predepositFor(address beneficiary, uint256 mixETHAmount) internal {
        if (predepositClosed) revert PredepositClosed();
        if (mixETHAmount == 0) revert ZeroAmount();
        // Public deposits are capped: hitting the cap exactly ends the window
        // (anyone may then launch). A deposit that would overshoot reverts —
        // the depositor retries with the remaining headroom.
        if (totalPredepositMixETH + mixETHAmount > PREDEPOSIT_CAP) revert CapExceeded();

        // Use balanceBefore/After to support fee-on-transfer tokens safely
        uint256 balBefore = mixETH.balanceOf(address(this));
        mixETH.safeTransferFrom(msg.sender, address(this), mixETHAmount);
        uint256 balAfter = mixETH.balanceOf(address(this));
        uint256 actualAmount = balAfter - balBefore;
        if (actualAmount == 0) revert ZeroAmount();

        _recordPredeposit(beneficiary, actualAmount);
    }

    /// @notice Factory-only carry seeding from a destroyed previous round.
    /// @dev Exempt from PREDEPOSIT_CAP: the carry IS the bootstrap. If the
    ///      carry alone reaches the cap, the round is instantly launchable
    ///      by anyone. Not subject to the window either — the window exists
    ///      to give the public time to join, and the carry joined first.
    function seedCarry(uint256 mixETHAmount) external nonReentrant {
        if (msg.sender != factory) revert NotFactory();
        if (mixETHAmount == 0) revert ZeroAmount();

        uint256 balBefore = mixETH.balanceOf(address(this));
        mixETH.safeTransferFrom(msg.sender, address(this), mixETHAmount);
        uint256 balAfter = mixETH.balanceOf(address(this));
        uint256 actualAmount = balAfter - balBefore;
        if (actualAmount == 0) revert ZeroAmount();

        _recordPredeposit(msg.sender, actualAmount);
        emit CarrySeeded(actualAmount);
    }

    /// @notice Receive side-pot mixETH from the factory (previous round's pot
    ///         redemption). Cap-exempt like carry, but ring-fenced: it buys NO
    ///         predeposit shares — it thickens the curve for everyone at launch.
    function potDeposit(uint256 mixETHAmount) external nonReentrant {
        if (msg.sender != factory) revert NotFactory();
        if (mixETHAmount == 0) revert ZeroAmount();

        uint256 balBefore = mixETH.balanceOf(address(this));
        mixETH.safeTransferFrom(msg.sender, address(this), mixETHAmount);
        uint256 actualAmount = mixETH.balanceOf(address(this)) - balBefore;
        if (actualAmount == 0) revert ZeroAmount();

        totalPotMixETH += actualAmount;
        emit PotDeposited(actualAmount);
    }

    function _recordPredeposit(address depositor, uint256 amount) internal {
        if (predeposits[depositor].mixETHAmount == 0) {
            totalPredepositors++;
        }
        predeposits[depositor].mixETHAmount += amount;
        totalPredepositMixETH += amount;

        // Predeposited.ethAmount is display-only (current rate) — accounting
        // is purely mixETH-denominated
        emit Predeposited(depositor, mixETHToETH(amount), amount);
    }

    /// @dev Window state, shared by launchPooledBuy and the UI.
    function _capReached() internal view returns (bool) {
        return totalPredepositMixETH >= PREDEPOSIT_CAP;
    }

    function _windowOver() internal view returns (bool) {
        return block.timestamp >= predepositStartTime + PREDEPOSIT_DURATION;
    }

    /// @notice Everything a front-end needs about the predeposit phase.
    function predepositState()
        external
        view
        returns (
            uint256 total,
            uint256 cap,
            uint256 startTime,
            bool closed,
            bool capReached,
            bool windowOver,
            bool launchable
        )
    {
        capReached = _capReached();
        windowOver = _windowOver();
        return (
            totalPredepositMixETH,
            PREDEPOSIT_CAP,
            predepositStartTime,
            predepositClosed,
            capReached,
            windowOver,
            (capReached || windowOver) && !predepositClosed
        );
    }

    /// @notice Launch the bonding curve with the pooled predeposit.
    /// @dev Permissionless: anyone may call once the cap is reached OR the
    ///      7-day window has elapsed. The owner (factory) may also launch
    ///      early — the window is a floor for public participation, not a
    ///      constraint on the protocol itself.
    function launchPooledBuy() external nonReentrant {
        if (predepositClosed) revert PredepositClosed();
        if (msg.sender != owner() && !_capReached() && !_windowOver()) revert PredepositOpen();
        predepositClosed = true;

        // Boot pool = public predeposit + side-pot funding. The pot's mixETH
        // rides the same genesis buy but buys NO claim shares (see split below).
        uint256 totalBoot = totalPredepositMixETH + totalPotMixETH;

        // Transfer boot mixETH to hook (hook holds all curve reserves + fees)
        mixETH.safeTransfer(address(hook), totalBoot);

        // NK24 fix: the curve's unit of account is mixETH — the genesis buy is
        // computed directly from the boot amount.
        uint256 initialPSP = CurveMath.computeBuyOutput(totalBoot, 0, curveConfig);
        if (initialPSP == 0) revert ZeroAmount();

        // Snapshot for proportional claims (prevents donation attacks)
        totalInitialPSP = initialPSP;

        // Split the genesis mint: the pot contributed pot/totalBoot of the
        // input, so it takes the same fraction of the output PSP — held
        // UNLOCKED (no genesis lock, no fees, no votes). Everything else is
        // the predepositors' claimable pool.
        uint256 potSharePSP = totalPotMixETH > 0 ? (initialPSP * totalPotMixETH) / totalBoot : 0;
        potPSPBalance += potSharePSP;
        uint256 genesisPSP = initialPSP - potSharePSP;
        genesisPSPSnapshot = genesisPSP;

        // Initialize the hook's curve state with the full boot amount
        hook.initializeCurve(totalBoot, initialPSP);

        // Mint PSP to all depositors proportionally
        _distributeInitialPSP(initialPSP);

        // NK24 genesis-lock fix: the controller itself locks ALL claimable
        // initial PSP in this same transaction as the genesis buy. totalLocked
        // therefore covers the entire claimable supply from the very first
        // post-launch block, so swap fees distribute pro-rata across all
        // predepositors — the first-locker solo window (98.8% fee capture
        // PoC) cannot exist. Predepositors claim out of this virtual lock
        // lazily via claimPredepositPSP(), which also pays out the fees their
        // share has accrued since launch. O(1) gas: no depositor loop.
        // (The pot's share is deliberately EXCLUDED — it never locks, never
        // earns fees, never votes; quorum measures locked + curve supply.)
        locks[address(this)] = LockInfo({
            amount: genesisPSP,
            rewardDebt: 0, // accFeePerShareMixETH is 0 at launch (no swaps pre-Active)
            lockTime: block.timestamp,
            unlockTime: block.timestamp + LOCK_DURATION
        });
        totalLocked += genesisPSP;

        // Activate the hook
        hook.setMode(CurveHook.Mode.Active);

        emit Launched(totalBoot, initialPSP);
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
        // Denominator is the predeposit pool; numerator is the claimable
        // genesis pool (pot's slice already excluded).
        uint256 share = (genesisPSPSnapshot * dep.mixETHAmount) / totalPredepositMixETH;
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
        if (address(hook) != address(0)
            && (hook.mode() == CurveHook.Mode.Destroyed || hook.mode() == CurveHook.Mode.Flat)) {
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
        // Flat round: every lock is open — exit at average backing instead of
        // watching the window close on dead PSP
        if (flatTime == 0 && block.timestamp < userLock.unlockTime) revert LockNotExpired();

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
        // No relocking a flat round — its only future is exit or inheritance
        if (flatTime != 0) revert RoundFlattened();
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
        if (address(hook) != address(0)
            && (hook.mode() == CurveHook.Mode.Destroyed || hook.mode() == CurveHook.Mode.Flat)) {
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

        // ── Side pot exit ──
        // The pot's PSP (swap fee cuts + genesis share) is redeemed at average
        // backing — reserve/supply pro-rata — into mixETH, then burned. This
        // is the pot's ONLY exit: it never sold a token during the round.
        // Funds go to the factory's ring-fenced side pot (next round's bonus
        // curve depth, cap-exempt, share-less). If the ledger call somehow
        // fails, the tokens are still at the factory — they ride the generic
        // carry instead (allocation shift, never a loss).
        uint256 potRedemption;
        if (potPSPBalance > 0) {
            potRedemption = hook.redeemPotBacking(potPSPBalance);
            pspToken.burn(address(this), potPSPBalance);
            emit PotRedeemed(potPSPBalance, potRedemption);
            potPSPBalance = 0;

            if (potRedemption > 0) {
                mixETH.safeTransfer(factory, potRedemption);
                // Ledger credit; on failure the funds ride the generic carry
                // (allocation shift, never a loss) — see comment above.
                // EIP-170: precomputed selector for creditSidePot(uint256)
                // (encodeWithSignature embeds the string + keccak per call)
                factory.call(abi.encodeWithSelector(bytes4(0xada2e425), potRedemption));
            }
        }

        // ── Flatten and open the exit window ──
        // The round is NOT destroyed here. Every staker lock opens
        // immediately (unlock() bypasses the 90-day expiry while flat) and
        // the flat curve pays average backing (reserve/supply) on every
        // sell. Stakers feed themselves, not round 2: whatever they leave
        // on the table is what the next round inherits.
        hook.setMode(CurveHook.Mode.Flat);
        flatTime = block.timestamp;

        emit CarpetBombExecuted(potRedemption);
    }

    /// @notice Close the exit window: destroy the round, drain the
    ///         remainder, and birth the next one.
    /// @dev Permissionless once FLAT_EXIT_WINDOW has elapsed; idempotently
    ///      reverting afterwards (the hook refuses Destroyed → Destroyed).
    ///      The carry is the backing of unredeemed PSP — holders who chose
    ///      to keep playing — plus any dust. If the spawn fails for any
    ///      reason the entire tx reverts atomically, so this can never
    ///      leave a half-destroyed round behind.
    function finalizeCarpet() external nonReentrant {
        if (flatTime == 0) revert NotFlattened();
        if (block.timestamp <= flatTime + FLAT_EXIT_WINDOW) revert ExitWindowOpen();

        // Mark destroyed
        hook.setMode(CurveHook.Mode.Destroyed);

        // Drain ALL remaining mixETH (unredeemed backing) to the factory
        uint256 mixETHCarried = hook.drainAll(factory);

        // Notify factory that this round is destroyed
        // EIP-170: precomputed selector for markDestroyed(uint256)
        (bool ok,) = factory.call(abi.encodeWithSelector(bytes4(0x723c5612), factoryRoundId));
        if (!ok) revert FactoryMarkFailed();

        // Birth the next iteration, seeded with the carry as its opening
        // predeposit offer — death, inheritance, rebirth in one
        // permissionless call.
        // EIP-170: precomputed selector for spawnNextRound(uint256)
        (bool okSpawn,) =
            factory.call(abi.encodeWithSelector(bytes4(0x1c9424dc), factoryRoundId));
        if (!okSpawn) revert FactorySpawnFailed();

        emit RoundFinalized(mixETHCarried);
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
