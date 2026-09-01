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
import {PSPStaker} from "./PSPStaker.sol";
import {StakerDeployer} from "./StakerDeployer.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {IRoundController} from "./interfaces/IRoundController.sol";

/// @title RoundController — Lifecycle management for one PSP round
/// @notice Handles predeposit, locking, fee distribution, yield reinvestment, and detonation.
///         Staking itself lives in PSPStaker (ERC-721 positions) — born in
///         this contract's constructor, fed by addFees. Death is the clock's
///         (CLOCK-REDESIGN §4): at detonationAt zero, detonate() is the one
///         permissionless kill switch — governance is gone.
contract RoundController is IRoundController, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using CurveMath for CurveMath.CurveConfig;

    // ─────────────── Errors ───────────────
    error NotHook();
    error NotActive();
    error ClockStillLive(); // CLOCK-REDESIGN §4: detonate() before the clock struck zero
    error NotPredeposit();
    error PredepositClosed();
    error ZeroAmount();
    error ZeroAddress();
    error FactoryMarkFailed();
    error FactorySpawnFailed();
    error TimingsIncomplete(); // 2026-08-19: packed profile must fill every timing slot
    error ProtectedToken(); // L-3: sweep() protection has its own error, not ZeroAddress
    error ZeroShare(); // L-4: predeposit share rounded to 0 — claim refused, flag not set
    error PredepositOpen(); // window still live and cap not reached — only owner may launch early
    error CapExceeded(); // public predeposit would push total past PREDEPOSIT_CAP
    error WalletCapExceeded(); // per-wallet predeposit cap (scoopy 2026-08-29 — sybil friction)
    error NotFactory(); // carry seeding is factory-only

    // ─────────────── Events ───────────────
    event Predeposited(address indexed user, uint256 ethAmount, uint256 mixETHAmount);
    event CarrySeeded(uint256 mixETHAmount);
    event Launched(uint256 totalMixETH, uint256 totalPSP);
    // Locked/Unlocked/Relocked/FeesClaimed/FeesForfeited moved to PSPStaker
    // (2026-08-19) with the position NFTs. Pot events removed with the pot.
    //
    // CLOCK-REDESIGN §4 (2026-09-01): the carpet-bomb governance events
    // (CarpetBombProposed/Voted/CarpetBombExecuted/RoundFinalized) died with
    // the vote — the detonation clock replaced them. Detonated is the one
    // death event now.
    event Detonated(address indexed by, uint256 potDistributed, address nextRound);
    event FeesAdded(uint256 mixETHAmount);

    // ─────────────── Immutables ───────────────
    PSPToken public immutable pspToken;
    IERC20 public immutable mixETH;
    CurveMath.CurveConfig public curveConfig;
    address public immutable factory;

    // ─────────────── Staker (ERC-721 positions) ───────────────
    /// @dev Born in the constructor: PSPStaker is the position ledger, the
    ///      fee accumulator, and the NFT. Fee claims pull from the hook via
    ///      sendFees (hook whitelists it as stakerClaimant). The referral
    ///      registry reads it for the min-stake gate.
    PSPStaker public immutable staker;

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
    // ─────────────── Timing profile ───────────────
    // Constants → constructor-set immutables (2026-08-18): packed `_timings`
    // arg allows a fast testnet profile; 0 (mainnet default) keeps the
    // original values. CLOCK-REDESIGN §4 (2026-09-01) repacked the profile
    // WITHOUT the vote slot (governance is dead) and WITHOUT the flat-exit
    // slot (redemption is indefinite): THREE slots now — [0] predeposit,
    // [85] vest, [170] per-wallet cap — each TIMINGS_WIDTH = 256/3 = 85
    // bits, widths DERIVED from the field count in CurveMath (LESSONS
    // 2026-08-24/2026-08-18: hand-set widths drift from data reality).
    uint256 public immutable PREDEPOSIT_DURATION; // default 7 days
    uint256 public constant PREDEPOSIT_CAP = 500e18; // 500 mixETH
    /// @dev Per-wallet predeposit cap, WHOLE mixETH from the 3rd packed
    ///      timing slot (scoopy 2026-08-29: "10 mixETH per wallet — can be
    ///      sybilled but at least that adds some friction"). 0 = uncapped
    ///      (mainnet default). Applies to the PUBLIC path only (predeposit /
    ///      predepositFor, guarding the BENEFICIARY); the factory carry
    ///      (seedCarry) is exempt — it IS the bootstrap.
    uint256 public immutable PREDEPOSIT_CAP_PER_WALLET; // 0 = off
    uint256 public immutable predepositStartTime;

    // ─────────────── Locking (vlCVX-style) ───────────────
    // (2026-08-19) the lock ledger, accumulator, and fee claims moved to
    // PSPStaker (ERC-721 positions). The controller keeps the timing
    // immutables — the staker reads them through IRoundController.
    uint256 public immutable VEST_DURATION; // 6 weeks (decay horizon)
    uint256 public constant PRECISION = 1e18;

    /// @dev detonation time — nonzero means the round is flat and every
    ///      lock is open for immediate exit at average backing. Set by
    ///      detonate(); STAYS as the analytics anchor (exit-window
    ///      reporting) now that the 3d FLAT_EXIT_WINDOW concept is
    ///      superseded by indefinite redemption (CLOCK-REDESIGN §4).
    uint256 public flatTime;

    // ─────────────── (side pot removed 2026-08-19) ───────────────
    /// @dev Genesis mint — the claimable pool behind claimPredepositPSP().
    ///      Snapshot at launch, never mutates. The referral system replaced
    ///      the pot: its carve-out pays out live in mixETH, nothing
    ///      accumulates here.
    uint256 public genesisPSPSnapshot;

    // ─────────────── Factory round tracking ───────────────
    uint256 public factoryRoundId;

    // ─────────────── Governance — REMOVED (CLOCK-REDESIGN §4, 2026-09-01) ───────────────
    // The propose/vote/execute kill trio, the proposal bookkeeping (struct,
    // epoch counter, per-pepe and per-wallet vote maps), and the vote /
    // flat-exit timing slots + quorum/majority constants all died here
    // (names deliberately unrepeatable — the no-governance grep gate hunts
    // them). The detonation clock (CurveHook.detonationAt) is the ONLY
    // death authority: at zero, detonate() flattens the round, opens every
    // lock, and births the successor. No quorum, no votes, no window.

    // ─────────────── Constructor ───────────────
    /// @dev `_config.timings == 0` → mainnet defaults (7d/42d, uncapped).
    ///      Non-zero: three TIMINGS_WIDTH-bit slots decode verbatim
    ///      (CurveMath.packTimings / packTimingsCapped) and both timing
    ///      fields must be non-zero — a zero slot reverts
    ///      TimingsIncomplete (2026-08-19 lesson: the pre-guard 5x64 layout
    ///      let a slot truncate to zero silently). The wallet-cap slot is
    ///      exempt: 0 = uncapped is a legal (mainnet) value.
    constructor(
        PSPToken _pspToken,
        IERC20 _mixETH,
        CurveMath.CurveConfig memory _config,
        address _factory,
        address _descriptor,
        StakerDeployer _stakerDeployer
    ) Ownable(_factory) {
        // Packed profile decode — `_config.timings == 0` → mainnet defaults.
        // Branch form (not per-field fallbacks) keeps the creation code —
        // embedded inside ControllerDeployer — under EIP-170's 24.5kB cap.
        uint256 t = _config.timings;
        if (t == 0) {
            PREDEPOSIT_DURATION = 7 days;
            VEST_DURATION = 42 days;
            PREDEPOSIT_CAP_PER_WALLET = 0; // uncapped (mainnet)
        } else {
            // Widths DERIVED in CurveMath (TIMINGS_COUNT=3, TIMINGS_WIDTH=85):
            // [0] predeposit, [1] vest, [2] wallet cap (whole mixETH). The
            // layout guard + roundtrip test pin the packing (LESSONS
            // 2026-08-24 / 2026-08-18).
            PREDEPOSIT_DURATION = t & CurveMath.TIMINGS_MASK;
            VEST_DURATION = (t >> CurveMath.TIMINGS_WIDTH) & CurveMath.TIMINGS_MASK;
            // 3rd slot (2026-08-29): per-wallet predeposit cap, whole mixETH
            PREDEPOSIT_CAP_PER_WALLET =
                ((t >> (2 * CurveMath.TIMINGS_WIDTH)) & CurveMath.TIMINGS_MASK) * 1e18;
            // 2026-08-19 tripwire: a truncated slot deployed silently once —
            // never again. (Wallet cap exempt: zero = uncapped is legal.)
            if (PREDEPOSIT_DURATION == 0 || VEST_DURATION == 0) revert TimingsIncomplete();
        }
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
        // Birth the staker: ERC-721 position ledger + fee accumulator. Born
        // here (not factory) so `staker` is immutable and the hook can cache
        // it as stakerClaimant at its own construction. Deployed through the
        // StakerDeployer vessel (EIP-170, 2026-08-23): PSPStaker's creation
        // code no longer embeds in this contract's creation program.
        // Salted create2 (2026-08-30): the salt derives from this
        // controller's own address, which is itself create2-predicted by
        // the factory — the whole round's address set (token, controller,
        // staker, registry, hook) is computable before anything deploys.
        staker = _stakerDeployer.deployStakerAt(
            keccak256(abi.encode(address(this), "psp-staker")),
            IERC20(address(_pspToken)),
            IRoundController(address(this)),
            _descriptor
        );
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
    /// @dev 2026-08-19: forwards to PSPStaker's accumulator (hook → controller
    ///      → staker chain; the staker validates both hops).
    function addFees(uint256 mixETHAmount) external onlyHook {
        staker.addFees(mixETHAmount);
        emit FeesAdded(mixETHAmount);
    }

    /// @dev IRoundController views for PSPStaker/CurveHook wiring.
    function stakerAddress() external view returns (address) { return address(staker); }
    function hookAddress() external view returns (address) { return address(hook); }

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
        // Per-wallet friction (scoopy 2026-08-29): optional cap (testnet packs
        // 10 mixETH) per beneficiary across the whole window. Sybil-able by
        // design — the point is friction, not prevention. 0 = uncapped.
        if (
            PREDEPOSIT_CAP_PER_WALLET != 0
                && predeposits[beneficiary].mixETHAmount + mixETHAmount > PREDEPOSIT_CAP_PER_WALLET
        ) {
            revert WalletCapExceeded();
        }

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
    /// @dev DEAD (2026-08-19): the side pot is gone. Kept as a no-op so old
    ///      finalizeCarpet replays can't brick — funds sent here ride the
    ///      generic carry at finalize instead.
    function potDeposit(uint256 mixETHAmount) external nonReentrant {
        if (msg.sender != factory) revert NotFactory();
        if (mixETHAmount == 0) revert ZeroAmount();
        // accept and hold: joins the curve at launch via totalBoot accounting
        uint256 balBefore = mixETH.balanceOf(address(this));
        mixETH.safeTransferFrom(msg.sender, address(this), mixETHAmount);
        uint256 actualAmount = mixETH.balanceOf(address(this)) - balBefore;
        if (actualAmount == 0) revert ZeroAmount();
        carryBonusMixETH += actualAmount;
    }

    /// @dev mixETH held here outside predeposit shares (old pot deposits) —
    ///      joins totalBoot at launch, thickening the curve for everyone.
    uint256 public carryBonusMixETH;

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

        // Boot pool = public predeposit + any carry bonus (old-pot deposits).
        uint256 totalBoot = totalPredepositMixETH + carryBonusMixETH;

        // Transfer boot mixETH to hook (hook holds all curve reserves + fees)
        mixETH.safeTransfer(address(hook), totalBoot);

        // NK24 fix: the curve's unit of account is mixETH — the genesis buy is
        // computed directly from the boot amount. Sine flavor: genesis supply
        // is the wave's predeposit integral (closed form, no Newton); the hook
        // materializes the identical curve in initializeCurve below.
        uint256 initialPSP = hook.sineConfigured()
            ? hook.sineGenesisPSP(totalBoot)
            : CurveMath.computeBuyOutput(totalBoot, 0, curveConfig);
        if (initialPSP == 0) revert ZeroAmount();

        // Snapshot for proportional claims (prevents donation attacks)
        totalInitialPSP = initialPSP;
        genesisPSPSnapshot = initialPSP;

        // Initialize the hook's curve state with the full boot amount
        hook.initializeCurve(totalBoot, initialPSP);

        // Mint PSP to this contract, then move the whole claimable pool into
        // the staker's genesis lock
        _distributeInitialPSP(initialPSP);

        // NK24 genesis-lock fix: the controller locks ALL claimable initial
        // PSP in this same transaction as the genesis buy — totalLocked
        // covers the entire claimable supply from the first post-launch
        // block, so swap fees distribute pro-rata across all predepositors;
        // the first-locker solo fee-capture window cannot exist. The lock
        // lives at the staker's own address (virtual position: never an NFT,
        // never transferable); predepositors claim out of it lazily via
        // claimPredepositPSP() → staker.claimGenesisShare().
        pspToken.transfer(address(staker), initialPSP);
        staker.lockGenesis(initialPSP);

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

        // Move the share (and its accrued fees) from the staker's genesis
        // lock into the user's position — minting their position NFT if it's
        // their first. Accrued-fee math and M-2 forfeit semantics live in
        // the staker.
        staker.claimGenesisShare(msg.sender, share);
    }

    // ─────────────── Locking (moved to PSPStaker, 2026-08-19) ───────────────
    // lock/unlock/relock/claimFees now live on the PSPStaker ERC-721 contract
    // born in this controller's constructor. This contract no longer touches
    // PSP after moving the genesis pool to the staker at launch.

    // ─────────────── Detonation (CLOCK-REDESIGN §4 — replaces governance) ───────────────

    /// @notice Kill the round at zero: flatten, open every lock, birth the
    ///         successor. PERMISSIONLESS, one tx, no quorum — the clock is
    ///         the only authority.
    /// @dev Gated by the hook's detonation clock and idempotent via the
    ///      mode check (after detonation the hook is Flat, so a second call
    ///      reverts at setMode's transition guard — nothing double-spends).
    ///      In one tx:
    ///        1. pot frozen — the mode leaves Active (curve trades already
    ///           halted at zero by the hook; Flat sells are fee-free), so
    ///           potBalance becomes the final distribution base forever;
    ///        2. hook.setMode(Flat) — the curve flattens to average backing;
    ///        3. flatTime set — every staker lock opens immediately (the
    ///           staker's withdraw bypasses the vest decay while flat);
    ///        4. factory markDestroyed + spawnNextRound — the next round's
    ///           predeposit window is live before the tx ends (the hook
    ///           itself stays Flat forever: redemption is indefinite).
    ///      If the spawn bounces on the ~0.03% reserve-mine tail the whole
    ///      tx reverts atomically — retry next block with fresh entropy;
    ///      the clock never un-strikes zero.
    function detonate() external nonReentrant {
        CurveHook h = hook;
        if (address(h) == address(0) || h.mode() != CurveHook.Mode.Active) revert NotActive();
        if (block.timestamp < h.detonationAt()) revert ClockStillLive();

        // 1+2. flatten — the pot freezes with the mode change (snapshot for
        // the event before it does)
        uint256 pot = h.potBalance();
        h.setMode(CurveHook.Mode.Flat);
        flatTime = block.timestamp;

        // 3. mark destroyed on the factory (the spawn chain needs the flag;
        //    EIP-170: precomputed selector for markDestroyed(uint256))
        (bool okMark,) = factory.call(abi.encodeWithSelector(bytes4(0x723c5612), factoryRoundId));
        if (!okMark) revert FactoryMarkFailed();

        // 4. birth the successor: the factory's composed reserve+birth shim
        //    (EIP-170: precomputed selector for spawnNextRound(uint256)).
        //    Returns (newRoundId, nextHook) — the event carries the live
        //    successor hook, the address the next game trades against.
        (bool okSpawn, bytes memory spawned) =
            factory.call(abi.encodeWithSelector(bytes4(0x1c9424dc), factoryRoundId));
        if (!okSpawn) revert FactorySpawnFailed();
        (, address nextRound) = abi.decode(spawned, (uint256, address));

        emit Detonated(msg.sender, pot, nextRound);
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
