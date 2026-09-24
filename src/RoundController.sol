// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
    error PredepositCapacityExceeded();
    error ZeroAmount();
    error ZeroAddress();
    error FactoryMarkFailed();
    // FactorySpawnFailed removed (2026-09-03): detonate() now TOLERATES a
    // failed spawn leg — on per-tx-capped chains the composed successor
    // birth can exceed the cap, and the round must still flatten, open
    // every lock and mark itself destroyed. The rebirth is then finished
    // permissionlessly via factory.reserveSpawn + 3× birthStep; Detonated
    // carries nextRound = address(0) for that case.
    error TimingsIncomplete(); // 2026-08-19: packed profile must fill every timing slot
    error ProtectedToken(); // L-3: sweep() protection has its own error, not ZeroAddress
    error ZeroShare(); // L-4: predeposit share rounded to 0 — claim refused, flag not set
    error PredepositOpen(); // window still live and cap not reached — only owner may launch early
    error CapExceeded(); // public predeposit would push total past PREDEPOSIT_CAP
    error NotGreenlisted(); // green-phase deposit without membership (root or prev-round PSP)
    error GreenCapExceeded(); // green-phase deposit past 500/N per wallet
    error WrongPhase(); // deposit outside its phase's window
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
        uint256 greenAmount; // greenlist tranche (first genesis buy)
        bool claimed;
    }
    mapping(address => DepositInfo) public predeposits;
    uint256 public totalPredepositMixETH;
    uint256 public totalGreenMixETH; // green tranche pool (first genesis buy)
    uint256 public greenDepositors;
    uint256 public totalPredepositors;
    uint256 public totalInitialPSP; // snapshot of PSP minted at launch
    bool public predepositClosed;

    /// @dev Greenlist-IBCO (rules v3, scoopy 2026-09-25): the window splits
    ///      into GREEN (csv root ∪ previous-round PSP holders, per-wallet
    ///      500/N) then OPEN (everyone, OPEN_PER_WALLET each), sharing the
    ///      1000 mixETH PREDEPOSIT_CAP. Unused green capacity rolls forward.
    ///      Genesis launch executes two consecutive curve buys — green pool
    ///      first, open pool second, both inside launchPooledBuy (atomic, so
    ///      nobody can frontrun between them).
    uint256 public immutable GREEN_DURATION; // default 1 day
    uint256 public immutable OPEN_DURATION; // default 1 day
    /// @notice Keccak Merkle root of the csv greenlist (empty = zero root).
    bytes32 public immutable GREEN_ROOT;
    /// @notice Green-phase per-wallet cap: 500 mixETH / N, N = csv entries ∪
    ///         prevToken.holderCount() at birth. 0 disables the green phase.
    uint256 public immutable GREEN_PER_WALLET;
    /// @notice Open-phase per-wallet cap (default 10 mixETH — whale friction).
    uint256 public immutable OPEN_PER_WALLET;
    /// @notice Previous round's PSP token — its frozen holder map is the
    ///         trustless auto-greenlist (held PSP at THAT round's detonation).
    PSPToken public immutable PREV_TOKEN;
    /// @notice Total pooled IBCO cap for public deposits. Factory carry is
    ///         exempt from the check but counts toward the total.
    uint256 public constant PREDEPOSIT_CAP = 1000 ether;
    /// @notice Version 2 accepts any positive pooled deposit within the caps.
    uint256 public constant PREDEPOSIT_RULES_VERSION = 3;
    /// @dev Genesis pooled buy routes this share of the boot into the hook's
    ///      ladder pot at launch (mirrors the sine pre-wave fee). The rest
    ///      seeds the curve; predepositors claim their pro-rata of the PSP
    ///      that 90% bought.
    uint256 public constant GENESIS_POT_FEE_BPS = 1000; // 10%
    /// @dev Per-wallet predeposit cap, WHOLE mixETH from the 3rd packed
    ///      timing slot (scoopy 2026-08-29: "10 mixETH per wallet — can be
    ///      sybilled but at least that adds some friction"). 0 = uncapped
    ///      (mainnet default). Applies to the PUBLIC path only (predeposit /
    ///      predepositFor, guarding the BENEFICIARY); the factory carry
    ///      (seedCarry) is exempt — it IS the bootstrap.
    uint256 public immutable PREDEPOSIT_CAP_PER_WALLET; // 0 = off
    uint256 public predepositStartTime;

    // ─────────────── Locking (vlCVX-style) ───────────────
    // (2026-08-19) the lock ledger, accumulator, and fee claims moved to
    // PSPStaker (ERC-721 positions). The controller keeps the timing
    // immutables — the staker reads them through IRoundController.
    uint256 public immutable VEST_DURATION; // 4 weeks (six-epoch decay horizon)
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
    /// @dev Per-tranche PSP at launch: green depositors share greenPSPSnapshot
    ///      pro-rata, open depositors share the remainder (second buy).
    uint256 public greenPSPSnapshot;
    uint256 public openPSPSnapshot;

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
    /// @dev `_config.timings == 0` → defaults (3d/28d, uncapped).
    ///      Non-zero: four TIMINGS_WIDTH-bit slots decode verbatim
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
        StakerDeployer _stakerDeployer,
        uint64 _greenSec,
        uint64 _openSec,
        bytes32 _greenRoot,
        uint256 _csvCount,
        uint256 _openPerWalletWad,
        PSPToken _prevToken
    ) Ownable(_factory) {
        // Packed profile decode — `_config.timings == 0` → mainnet defaults.
        // Branch form (not per-field fallbacks) keeps the creation code —
        // embedded inside ControllerDeployer — under EIP-170's 24.5kB cap.
        uint256 t = _config.timings;
        if (t == 0) {
            GREEN_DURATION = 1 days;
            OPEN_DURATION = 1 days;
            VEST_DURATION = 28 days;
            PREDEPOSIT_CAP_PER_WALLET = 0; // uncapped (mainnet)
        } else {
            // Widths DERIVED in CurveMath (TIMINGS_COUNT=4, TIMINGS_WIDTH=64):
            // [0] predeposit, [1] vest, [2] detonation window (hook-owned),
            // [3] wallet cap (whole mixETH). The layout guard + roundtrip
            // test pin the packing (LESSONS 2026-08-24 / 2026-08-18).
            GREEN_DURATION = t & CurveMath.TIMINGS_MASK; // slot [0] = green
            OPEN_DURATION = _openSec == 0 ? 1 days : _openSec;
            VEST_DURATION = (t >> CurveMath.TIMINGS_WIDTH) & CurveMath.TIMINGS_MASK;
            // 4th slot (2026-09-03): per-wallet predeposit cap, whole mixETH
            // (the det window moved to slot [2], consumed by CurveHook)
            PREDEPOSIT_CAP_PER_WALLET =
                ((t >> (3 * CurveMath.TIMINGS_WIDTH)) & CurveMath.TIMINGS_MASK) * 1e18;
            // 2026-08-19 tripwire: a truncated slot deployed silently once —
            // never again. (Wallet cap exempt: zero = uncapped is legal.)
            // 2026-09-13 (audit L-M1): vest < 6 also reverts — epochSize()
            // = VEST_DURATION / 6 truncates to 0 below six seconds and every
            // epoch path panics 0x11 (division by zero), first inside
            // launchPooledBuy, stranding the predeposit pool with no abort.
            if (GREEN_DURATION == 0 || OPEN_DURATION == 0 || VEST_DURATION < 6) {
                revert TimingsIncomplete();
            }
        }
        // Greenlist sizing: N = csv entries + previous-round holders (frozen
        // holderCount of the round that just died). N = 0 → no green phase.
        uint256 n = _csvCount;
        if (address(_prevToken) != address(0)) n += _prevToken.holderCount();
        GREEN_ROOT = _greenRoot;
        GREEN_PER_WALLET = n == 0 ? 0 : 500 ether / n;
        OPEN_PER_WALLET = _openPerWalletWad == 0 ? 10 ether : _openPerWalletWad;
        PREV_TOKEN = _prevToken;
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
        // The final factory wiring step starts the public window.
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
        if (address(_hook) == address(0)) revert ZeroAddress();
        // Start once, in the final birth transaction. Retries cannot reset it.
        if (address(hook) == address(0)) predepositStartTime = block.timestamp;
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
        return Math.mulDiv(mixETHAmount, totalAssets, totalSupply);
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

    /// @notice The depositor's fixed art choice, shared by all their deposits.
    mapping(address => uint256) public predepositPepe;

    /// @notice Deposit and reserve the exact Pepe that the later claim will mint.
    function predepositWithPepe(uint256 mixETHAmount, uint256 pepeId) external nonReentrant {
        uint256 selected = predepositPepe[msg.sender];
        if (selected != 0 && selected != pepeId) revert PredepositClosed();
        _predepositFor(msg.sender, mixETHAmount, false, new bytes32[](0));
        if (selected == 0) {
            staker.reserveGenesisPepe(msg.sender, pepeId);
            predepositPepe[msg.sender] = pepeId;
        }
    }

    /// @notice Open-phase deposit (rules v3; the legacy name routes here).
    function predeposit(uint256 mixETHAmount) external nonReentrant {
        _predepositFor(msg.sender, mixETHAmount, false, new bytes32[](0));
    }

    /// @notice Deposit on behalf of a beneficiary (e.g. the ETH zap router:
    ///         it wraps ETH into mixETH and deposits, but the PSP must be
    ///         credited to the human, not the router).
    /// @dev Identical accounting to predeposit(); permissionless by design
    ///      (same as ERC-4626 depositFor — depositing FOR someone can only
    ///      credit them, never debit).
    function predepositFor(address beneficiary, uint256 mixETHAmount) external nonReentrant {
        _predepositFor(beneficiary, mixETHAmount, false, new bytes32[](0));
    }

    /// @notice Greenlist phase deposit (rules v3): csv Merkle proof or
    ///         previous-round PSP holder (frozen at that round's detonation).
    function predepositGreen(uint256 mixETHAmount, bytes32[] calldata proof) external nonReentrant {
        _predepositFor(msg.sender, mixETHAmount, true, proof);
    }

    /// @notice Greenlist deposit reserving a chosen pepe (art version 2+).
    function predepositGreenWithPepe(uint256 mixETHAmount, uint256 pepeId, bytes32[] calldata proof)
        external
        nonReentrant
    {
        uint256 selected = predepositPepe[msg.sender];
        if (selected != 0 && selected != pepeId) revert PredepositClosed();
        _predepositFor(msg.sender, mixETHAmount, true, proof);
        if (selected == 0) {
            staker.reserveGenesisPepe(msg.sender, pepeId);
            predepositPepe[msg.sender] = pepeId;
        }
    }

    function _predepositFor(address beneficiary, uint256 mixETHAmount, bool green, bytes32[] memory proof)
        internal
    {
        if (address(hook) == address(0)) revert NotPredeposit();
        if (predepositClosed) revert PredepositClosed();
        if (mixETHAmount == 0) revert ZeroAmount();
        uint8 ph = phase();
        if (green) {
            if (ph != 0) revert WrongPhase();
            if (!_greenlisted(beneficiary, proof)) revert NotGreenlisted();
            if (predeposits[beneficiary].greenAmount + mixETHAmount > GREEN_PER_WALLET) {
                revert GreenCapExceeded();
            }
        } else {
            if (ph == 0 && GREEN_PER_WALLET != 0) revert WrongPhase();
            if (ph == 2) revert WrongPhase();
            // The 2026-09-03 packed wallet-cap slot retires into the
            // open-phase cap (10 mixETH default; whale friction, not sybil
            // resistance).
            uint256 openCap = OPEN_PER_WALLET;
            if (openCap != 0
                && predeposits[beneficiary].mixETHAmount - predeposits[beneficiary].greenAmount
                    + mixETHAmount > openCap
            ) {
                revert WalletCapExceeded();
            }
        }
        if (totalPredepositMixETH + mixETHAmount > PREDEPOSIT_CAP) revert CapExceeded();

        // PD-1: predeposit accepts every positive amount. The minimum gross
        // purchase applies to active curve buys, not pooled predeposits.

        // Use balanceBefore/After to support fee-on-transfer tokens safely
        uint256 balBefore = mixETH.balanceOf(address(this));
        mixETH.safeTransferFrom(msg.sender, address(this), mixETHAmount);
        uint256 balAfter = mixETH.balanceOf(address(this));
        uint256 actualAmount = balAfter - balBefore;
        if (actualAmount == 0) revert ZeroAmount();

        _recordPredeposit(beneficiary, actualAmount, green);
    }

    /// @notice Factory-only carry seeding from the factory's own balance.
    /// @dev Carry joins the pooled buy. It does not shorten the public window.
    function seedCarry(uint256 mixETHAmount) external nonReentrant {
        if (msg.sender != factory) revert NotFactory();
        if (mixETHAmount == 0) revert ZeroAmount();

        uint256 balBefore = mixETH.balanceOf(address(this));
        mixETH.safeTransferFrom(msg.sender, address(this), mixETHAmount);
        uint256 balAfter = mixETH.balanceOf(address(this));
        uint256 actualAmount = balAfter - balBefore;
        if (actualAmount == 0) revert ZeroAmount();

        _recordPredeposit(msg.sender, actualAmount, false);
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
        uint256 oldBoot = totalPredepositMixETH + carryBonusMixETH;
        if (actualAmount > type(uint256).max - oldBoot) revert PredepositCapacityExceeded();
        _validateBootstrap(oldBoot + actualAmount, totalPredepositMixETH);
        carryBonusMixETH += actualAmount;
    }

    /// @dev mixETH held here outside predeposit shares (old pot deposits) —
    ///      joins totalBoot at launch, thickening the curve for everyone.
    uint256 public carryBonusMixETH;

    /// @dev AUD-V3-3: the immutable helper checks price and integral capacity.
    ///      Genesis minting, staking and allocation use uint256, not V4's
    ///      signed128 swap deltas. Re-run the exact genesis calculation that
    ///      launch and hook initialization use; reject a zero allocation.
    ///      Requiring Q >= the share denominator also proves that every
    ///      positive contribution receives at least one PSP wei. A later
    ///      deposit or bonus must preserve that property for earlier users.
    ///      `shareDenominator` includes seedCarry shares, but excludes the
    ///      legacy potDeposit bonus, which creates no predeposit shares.
    function _validateBootstrap(uint256 totalBoot, uint256 shareDenominator) private view {
        if (!hook.sineConfigured()) return;
        uint256 netBoot = totalBoot - Math.mulDiv(totalBoot, GENESIS_POT_FEE_BPS, 10000);
        try hook.sineGenesisPSP(netBoot) returns (uint256 genesisPSP) {
            if (genesisPSP == 0 || genesisPSP < shareDenominator) revert PredepositCapacityExceeded();
        } catch {
            revert PredepositCapacityExceeded();
        }
    }

    function _recordPredeposit(address depositor, uint256 amount, bool greenTranche) internal {
        uint256 oldBoot = totalPredepositMixETH + carryBonusMixETH;
        if (amount > type(uint256).max - oldBoot) revert PredepositCapacityExceeded();
        uint256 sharesAfter = totalPredepositMixETH + amount;
        _validateBootstrap(oldBoot + amount, sharesAfter);
        if (predeposits[depositor].mixETHAmount == 0) {
            totalPredepositors++;
            if (greenTranche) greenDepositors++;
        }
        if (greenTranche) {
            predeposits[depositor].greenAmount += amount;
            totalGreenMixETH += amount;
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

    /// @notice IBCO phase: 0 = green, 1 = open, 2 = over.
    function phase() public view returns (uint8) {
        if (address(hook) == address(0)) return 0;
        if (GREEN_PER_WALLET == 0) {
            // No greenlist members: the whole window is open.
            return block.timestamp < predepositStartTime + OPEN_DURATION ? 1 : 2;
        }
        if (block.timestamp < predepositStartTime + GREEN_DURATION) return 0;
        if (block.timestamp < predepositStartTime + GREEN_DURATION + OPEN_DURATION) return 1;
        return 2;
    }

    /// @dev Greenlist membership: previous round's frozen holder map, or a
    ///      Merkle proof against GREEN_ROOT (the csv). Round 1: csv only.
    function _greenlisted(address who, bytes32[] memory proof) internal view returns (bool) {
        if (address(PREV_TOKEN) != address(0) && PREV_TOKEN.holder(who)) return true;
        if (GREEN_ROOT == bytes32(0) || proof.length == 0) return false;
        bytes32 leaf = keccak256(abi.encodePacked(who));
        for (uint256 i; i < proof.length; ++i) {
            leaf = leaf < proof[i]
                ? keccak256(abi.encodePacked(leaf, proof[i]))
                : keccak256(abi.encodePacked(proof[i], leaf));
        }
        return leaf == GREEN_ROOT;
    }

    function _windowOver() internal view returns (bool) {
        return address(hook) != address(0) && phase() == 2;
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
            bool launchable,
            uint8 phaseNow,
            uint256 greenTotal,
            uint256 greenPerWallet,
            uint256 openPerWallet
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
            (capReached || windowOver) && !predepositClosed,
            phase(),
            totalGreenMixETH,
            GREEN_PER_WALLET,
            OPEN_PER_WALLET
        );
    }

    /// @notice Launch the bonding curve with the pooled predeposit.
    /// @dev Anyone may launch after the window (or constructor override) or
    ///      once the total cap is reached. The owner may launch early.
    function launchPooledBuy() external nonReentrant {
        if (address(hook) == address(0)) revert NotPredeposit();
        if (predepositClosed) revert PredepositClosed();
        if (msg.sender != owner() && !_windowOver() && !_capReached()) revert PredepositOpen();
        predepositClosed = true;

        // Boot pool = public predeposit + any carry bonus (old-pot deposits).
        uint256 totalBoot = totalPredepositMixETH + carryBonusMixETH;

        // TWO CONSECUTIVE GENESIS BUYS (greenlist-IBCO, same tx — nobody can
        // frontrun between them): buy #1 = the green tranche pool, buy #2 =
        // the open tranche. Each tranche pays the 10% pre-wave pot fee on its
        // own boot; the PSP split is the exact curve-integral segmentation
        // F(greenBoot) then F(totalBoot) − F(greenBoot).
        uint256 greenBootRaw = totalGreenMixETH + _greenCarry();
        uint256 greenCurveBoot =
            greenBootRaw - Math.mulDiv(greenBootRaw, GENESIS_POT_FEE_BPS, 10000);
        uint256 potFee = Math.mulDiv(totalBoot, GENESIS_POT_FEE_BPS, 10000);
        uint256 curveBoot = totalBoot - potFee;

        // Transfer boot mixETH to hook (hook holds all curve reserves + fees)
        mixETH.safeTransfer(address(hook), totalBoot);

        // NK24 fix: the curve's unit of account is mixETH — the genesis buy is
        // computed directly from the boot amount. Sine flavor: genesis supply
        // is the wave's predeposit integral (closed form, no Newton); the hook
        // materializes the identical curve in initializeCurve below.
        uint256 initialPSP = hook.sineConfigured()
            ? hook.sineGenesisPSP(curveBoot)
            : CurveMath.computeBuyOutput(curveBoot, 0, curveConfig);
        if (initialPSP == 0) revert ZeroAmount();

        // Buy #1's PSP: the integral up to the green tranche's curve boot.
        // Buy #2's: the remainder. Each tranche's depositors share their own
        // segment pro-rata (see _claimPredepositPSP).
        greenPSPSnapshot = greenCurveBoot == 0
            ? 0
            : (hook.sineConfigured()
                ? hook.sineGenesisPSP(greenCurveBoot)
                : CurveMath.computeBuyOutput(greenCurveBoot, 0, curveConfig));
        openPSPSnapshot = initialPSP - greenPSPSnapshot;

        // Snapshot for proportional claims (prevents donation attacks)
        totalInitialPSP = initialPSP;
        genesisPSPSnapshot = initialPSP;

        // Initialize the hook's curve state with the post-fee boot, and
        // route the genesis fee into the ladder pot
        hook.initializeCurve(curveBoot, initialPSP, potFee);

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
        IERC20(address(pspToken)).safeTransfer(address(staker), initialPSP);
        staker.lockGenesis(initialPSP);

        // Activate the hook
        hook.setMode(CurveHook.Mode.Active);

        emit Launched(totalBoot, initialPSP);
    }

    /// @dev Carry joins the OPEN tranche (factory dust is not a greenlist
    ///      deposit) — unless the open pool is empty, when it rides buy #1 so
    ///      a carry-only round still launches.
    function _greenCarry() internal view returns (uint256) {
        return totalPredepositMixETH == totalGreenMixETH ? carryBonusMixETH : 0;
    }

    function _distributeInitialPSP(uint256 initialPSP) internal {
        // Mint all PSP to this contract, then distribute
        pspToken.mint(address(this), initialPSP);

        // For simplicity and gas, depositors claim manually
        // Alternatively, do a loop (gas-expensive for many depositors)
        // For now, depositors call claimPredepositPSP()
    }

    /// @notice Claim predeposit PSP with reserved art, or automatic art if none was selected.
    /// @dev The share and its accrued fees move out of the virtual genesis
    ///      position into a fresh NFT. PSP stays in the staker; the normal
    ///      withdrawal-request rules apply, and detonation opens the lock.
    function claimPredepositPSP() external nonReentrant {
        _claimPredepositPSP(0, false);
    }

    /// @notice Version 2 reserves art during deposit and honors it on every claim route.
    uint256 public constant PREDEPOSIT_ART_VERSION = 2;

    /// @notice Claim into the exact unminted Pepe selected from the art picker.
    /// @dev A taken ID or trait combination reverts the entire claim, preserving
    ///      the depositor's allocation and accrued fees for another selection.
    function claimPredepositPSPWithPepe(uint256 pepeId) external nonReentrant {
        _claimPredepositPSP(pepeId, true);
    }

    function _claimPredepositPSP(uint256 pepeId, bool chosen) private {
        uint256 reserved = predepositPepe[msg.sender];
        if (reserved != 0) {
            if (chosen && pepeId != reserved) revert PredepositClosed();
            pepeId = reserved;
            chosen = true;
        }
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
        // Rules v3: each depositor owns their tranche's segment — green
        // depositors the first buy's PSP, open depositors the second's.
        uint256 share;
        if (dep.greenAmount > 0) {
            share += Math.mulDiv(greenPSPSnapshot, dep.greenAmount, totalGreenMixETH);
        }
        uint256 openAmount = dep.mixETHAmount - dep.greenAmount;
        if (openAmount > 0) {
            share += Math.mulDiv(
                openPSPSnapshot, openAmount, totalPredepositMixETH - totalGreenMixETH
            );
        }
        if (share == 0) revert ZeroShare();

        dep.claimed = true;

        // Move the share (and its accrued fees) from the staker's genesis
        // lock into a fresh NFT. Accrued-fee accounting and
        // deferred-payout handling live in the staker.
        if (chosen) staker.claimGenesisShareWithPepe(msg.sender, share, pepeId);
        else staker.claimGenesisShare(msg.sender, share);
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

        // 0. Freeze the PSP holder map: this round's holders become the next
        //    round's trustless greenlist (greenlist-IBCO rules v3).
        pspToken.freezeHolders();

        // 1+2. flatten — the pot freezes with the mode change (snapshot for
        // the event before it does)
        h.setMode(CurveHook.Mode.Flat);
        uint256 pot = h.potBalance();
        flatTime = block.timestamp;

        // 3. mark destroyed on the factory (the spawn chain needs the flag;
        //    EIP-170: precomputed selector for markDestroyed(uint256))
        (bool okMark,) = factory.call(abi.encodeWithSelector(bytes4(0x723c5612), factoryRoundId));
        if (!okMark) revert FactoryMarkFailed();

        // 4. birth the successor: the factory's composed reserve+birth shim
        //    (EIP-170: precomputed selector for spawnNextRound(uint256)).
        //    On chains with a per-tx gas cap (Base Sepolia ≈2^24) the
        //    composed spawn can exceed the cap — that failure is TOLERATED:
        //    this tx still flattens, freezes the pot, opens every lock and
        //    marks the round destroyed, and ANYONE finishes the rebirth
        //    permissionlessly via factory.reserveSpawn + 3× birthStep (the
        //    factory cares only about round state, not the caller). The
        //    Detonated event carries nextRound = address(0) when the
        //    successor still needs birthing — the UI's "round is spawning"
        //    signal.
        address nextRound;
        // AUD-3: do not burn a capped transaction's gas attempting a birth
        // that cannot fit. Always retain gas to complete settlement/events.
        // Low-gas callers finish rebirth through the permissionless stages.
        if (gasleft() > 30_000_000) {
            (bool okSpawn, bytes memory spawned) = factory.call{gas: gasleft() - 100_000}(
                abi.encodeWithSelector(bytes4(0x1c9424dc), factoryRoundId)
            );
            if (okSpawn) (, nextRound) = abi.decode(spawned, (uint256, address));
        }

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
