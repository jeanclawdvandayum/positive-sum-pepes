// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CurveMath} from "./libraries/CurveMath.sol";
import {SineMath} from "./libraries/SineMath.sol";
import {IRoundController} from "./interfaces/IRoundController.sol";
import {PSPReferralRegistry} from "./PSPReferralRegistry.sol";

/// @title CurveHook - V4 hook implementing S-curve bonding curve for PSP
/// @notice Handles pricing, minting/burning PSP, and fee extraction.
///         Curve, reserve, and fees are all denominated in mixETH — the vault's
///         exchange rate is NEVER read in the settlement path (NK24 rate-short
///         fix: buys used to credit the reserve at the buy-time rate while
///         sells converted an ETH integral at the live rate, leaving the
///         reserve short a depeg put with only a 1bps haircut as cushion;
///         any rate drop > haircut extracted other holders' backing).
///         mixETH yield/losses now accrue pro-rata to all PSP holders.
///         Fees stay in hook balance (over the reserve), claimable via sendFees().
contract CurveHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurveMath for CurveMath.CurveConfig;
    using SafeERC20 for IERC20;

    // ─────────────── Errors ───────────────
    error NotActive();
    error NotController();
    error InvalidMode();
    error BuyingDisabled(); // Flat mode is a one-way exit (scoopy 2026-08-29) — no buys into a dying round
    error BuyZeroAmount();
    error SellExceedsSupply();
    error InsufficientFees();
    error SwapTooSmall(); // C-1 fix: blocks dust-scale precision arb on the curve
    error ZeroOutput(); // a swap must deliver a nonzero user output — never absorb input silently
    error WrongPoolCurrencies(); // L-2 fix: pool-key gate on initialization
    error WrongPoolParams(); // NK24: canonical fee/tickSpacing gate — no decoy pools
    error ZeroDeployerCut(); // CLOCK-REDESIGN §3: deployerCutTo must be a real address
    error TradingHalted(); // CLOCK-REDESIGN §1: block.timestamp >= detonationAt — the round is dead
    error NotDetonated(); // claims open only once the clock struck zero and detonate() ran
    error BadSeatIndex(); // board(i) out of the seated window
    error NothingToClaim(); // claimPot/claimDeployerCredit with an empty purse

    // ─────────────── Types ───────────────
    enum Mode { Predeposit, Active, Flat, Destroyed }

    // ─────────────── Immutables ───────────────
    IRoundController public immutable controller;
    CurveMath.CurveConfig public curveConfig;
    /// @dev Permanent cross-round referral graph — attribution + tier weights.
    PSPReferralRegistry public immutable referralRegistry;
    /// @dev Cached at construction (staker is born in the controller's
    ///      constructor, so it exists before this hook does). sendFees is
    ///      callable by the controller and the staker it birthed.
    /// @dev lazy cache — the hook may be deployed against a PREDICTED
    /// (still codeless) controller, so the constructor must never call it
    address public stakerClaimant;
    uint24 public constant SWAP_FEE_BIPS = 500; // 5% flat swap fee — ZONE-curve rounds (sine rounds slide, see swapFeeBps)

    /// @dev Sliding fee (scoopy 2026-08-30), sine rounds only, anchored to the
    ///      wave's reserve domain [0, boot | boot, top | > top]:
    ///        R ≤ boot          → 10%   (pre-wave raise — the early game)
    ///        boot < R < top     → linear decay 10% → 2.5% across the wave
    ///        R ≥ top            → 2.5%  (above the sine — deep reserve)
    ///      Zone-curve rounds keep the flat 5% (SWAP_FEE_BIPS).
    uint24 public constant FEE_BPS_PRE_WAVE = 1000;
    uint24 public constant FEE_BPS_ABOVE_WAVE = 250;

    /// @notice The swap fee this round charges right now, in bps.
    function swapFeeBps() public view returns (uint24) {
        if (!sineActive) return SWAP_FEE_BIPS;
        uint256 boot = sineCurve.boot;
        uint256 span = sineCurve.span;
        uint256 r = reserveMixETH;
        if (r <= boot) return FEE_BPS_PRE_WAVE;
        if (r >= boot + span) return FEE_BPS_ABOVE_WAVE;
        // floor → the fee slice rounds UP in the reserve's favor
        return uint24(FEE_BPS_PRE_WAVE - ((FEE_BPS_PRE_WAVE - FEE_BPS_ABOVE_WAVE) * (r - boot)) / span);
    }
    /// @dev Referral leg of the swap fee (CLOCK-REDESIGN §3 REVISED
    ///      2026-09-01): referral attribution pays 5% OF THE FEE, tier-split
    ///      across the trader's chain by the registry's existing tier
    ///      weights (payoutFor's who[5]/bps[5] — no new tier math). The
    ///      2026-08-19 fixed-50bps-of-VOLUME referral is RETIRED. Unpaid
    ///      tier weight (short chains) and every rounding remainder fall to
    ///      the pot escrow — one deterministic destination.
    uint24 public constant REFERRAL_LEG_BPS = 500; // 5% OF THE FEE
    /// @dev Canonical V4 pool parameters — the only pool this hook serves.
    ///      0x800000 = dynamic-fee flag (hook-priced; fee field unused).
    uint24 public constant CANONICAL_FEE = 0x800000;
    int24 public constant CANONICAL_TICK_SPACING = 60;
    /// @dev C-1 fix: minimum swap input. Below ~1e12 wei, curveIntegral
    ///      fixed-point truncation (pStart/k rounding) can exceed the 1 bps
    ///      conservative haircut, making dust round-trips profitable in wei
    /// terms. Economically nil, but the invariant violation is real — block it.
    uint256 public constant MIN_SWAP_INPUT = 1e12; // 0.000001 tokens

    // ─────────────── Detonation clock (CLOCK-REDESIGN §1) ───────────────
    /// @dev Armed at the Active transition: detonationAt = now + DET_WINDOW.
    ///      Buys add TIME_PER_PSP per WHOLE PSP out (discrete), capped so
    ///      remaining never exceeds DET_WINDOW. At zero the round is DEAD —
    ///      buys AND sells revert TradingHalted; nothing resurrects the clock.
    uint256 public constant DET_WINDOW = 72 hours;
    uint256 public constant TIME_PER_PSP = 5 minutes;

    /// @dev Fee split, in bps OF THE FEE amount (CLOCK-REDESIGN §3 REVISED
    ///      2026-09-01 — supersedes the same-day 60-pot/40-staker-of-net
    ///      draft): 60% stakers / 35% pot / 5% referrer chain when
    ///      attributed; with NO attribution the 5% leg re-splits 4% pot /
    ///      1% deployer (pull-based deployerCredit). Every remainder
    ///      (cross-leg rounding, unpaid tier weight) lands in the pot
    ///      escrow deterministically.
    uint24 public constant STAKER_BPS = 6000; // 60% of the fee → staker accumulator
    uint24 public constant POT_BPS = 3500; // 35% of the fee → ladder pot escrow
    uint24 public constant DEPLOYER_BPS = 100; // 1% of the fee → deployerCredit (unattributed flow only)

    // ─────────────── State ───────────────
    Mode public mode = Mode.Predeposit;
    uint256 public reserveMixETH;   // mixETH backing circulating PSP (excludes fees)
    uint256 public totalSupplyPSP;  // total PSP minted by curve
    bool public poolInitialized;

    // ─────────────── Sine flavor (2026-08-29, scoopy round-2 ruling) ───────────────
    // Factory-configured BEFORE pool init; materialized at initializeCurve from
    // the ACTUAL predeposit raise, so every wave boundary is boot-invariant.
    // When sineActive, buy/sell price off SineMath (reserve-parametrized);
    // the zone path below remains for legacy/gallery rounds.
    SineMath.Params public sineParams;
    bool public sineConfigured;
    SineMath.Curve public sineCurve;   // NOTE: auto-getter omits cp[] — use getSineCheckpoints()
    bool public sineActive;

    // ─────────────── Clock + tickets + pot (CLOCK-REDESIGN §1-3) ───────────────
    /// @dev The detonation clock, in SECONDS (block.timestamp domain). Zero
    ///      while Predeposit; armed at the Active transition.
    uint256 public detonationAt;

    /// @dev One seat per curve BUY tx (no dedup — a wallet can hold many).
    ///      Circular buffer: seat t lives at tickets[t % 10]; only the newest
    ///      10 seats exist once ticketCount passes 10.
    struct Ticket {
        address buyer;     // refTrader when attributed, else the swap sender
        uint64 ts;         // buy timestamp
        uint128 pspAmount; // PSP out of that buy (1e18 precision)
        uint128 mixPaid;   // mixETH volume in
    }
    Ticket[10] public tickets;
    uint256 public ticketCount; // total buys ever — absolute seat numbering
    mapping(uint256 => bool) public seatClaimed; // seat => paid (claims-forever bookkeeping)

    /// @dev Ladder pot escrow, mixETH. Accrues the pot legs of the fee split
    ///      during Active; FROZEN at detonation — it is the distribution base
    ///      forever, never mutated afterwards. potPaid tracks what claims
    ///      have drained.
    uint256 public potBalance;
    uint256 public potPaid;

    // ─────────────── Deployer credit (CLOCK-REDESIGN §3 REVISED) ───────────────
    /// @dev Recipient of the 1% unattributed rake — set once at deploy
    ///      (testnet: the throwaway deployer; mainnet: scoopy's address).
    address public immutable deployerCutTo;
    /// @dev Accrued 1% legs of unattributed fees, mixETH. PULL-based claim,
    ///      no deadline, no sweep — deployerCreditPaid tracks the drain.
    uint256 public deployerCredit;
    uint256 public deployerCreditPaid;

    /// @dev Ladder weights (bps) from NEWEST seat to OLDEST: 25/18/14/10/8/7/6/5/4/3.
    ///      Fewer than 10 seats → renormalized to 100% (nobody gets dusted).
    function _ladderBps(uint256 age) internal pure returns (uint256) {
        if (age == 0) return 2500;
        if (age == 1) return 1800;
        if (age == 2) return 1400;
        if (age == 3) return 1000;
        if (age == 4) return 800;
        if (age == 5) return 700;
        if (age == 6) return 600;
        if (age == 7) return 500;
        if (age == 8) return 400;
        return 300;
    }

    // ─────────────── Events ───────────────
    // All value fields mixETH-denominated (curve unit of account).
    event Buy(address indexed buyer, uint256 mixETHIn, uint256 pspOut, uint256 newSupply, uint256 newReserveMixETH);
    event Sell(address indexed seller, uint256 pspIn, uint256 mixETHOut, uint256 newSupply, uint256 newReserveMixETH);
    event ModeChanged(Mode newMode);
    event PoolInitialized();
    event FeesSent(address indexed to, uint256 mixETHAmount);
    event ReferralPaid(address indexed trader, address indexed referrer, uint256 tier, uint256 mixETHAmount);
    event TimeAdded(address indexed buyer, uint256 wholePsp, uint256 newDetonationAt); // the tape
    event PotClaimed(address indexed who, uint256 mixETHAmount);
    event DeployerCreditClaimed(address indexed who, uint256 mixETHAmount);

    // ─────────────── Constructor ───────────────
    constructor(IPoolManager _poolManager, IRoundController _controller, PSPReferralRegistry _referralRegistry, CurveMath.CurveConfig memory _config, address _deployerCutTo)
        BaseHook(_poolManager)
    {
        if (_deployerCutTo == address(0)) revert ZeroDeployerCut(); // CLOCK-REDESIGN §3: the 1% rake needs a home
        controller = _controller;
        curveConfig = _config;
        referralRegistry = _referralRegistry;
        deployerCutTo = _deployerCutTo;
    }

    /// @dev resolves the staker on first privileged use; cached thereafter
    function _stakerClaimant() internal returns (address) {
        if (stakerClaimant == address(0)) {
            stakerClaimant = controller.stakerAddress();
        }
        return stakerClaimant;
    }

    // ─────────────── Settlement Helpers ───────────────

    function _settleCurrency(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        // V4 pattern: sync FIRST (snapshot old balance), then transfer, then settle.
        // If transfer happens before sync, settle sees no delta and reverts with CurrencyNotSettled.
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    // ─────────────── Dynamic Reserve ───────────────

    /// @notice ETH-denominated value of the curve reserve (excludes accumulated fees)
    /// @dev DISPLAY ONLY — never used in settlement math. Computed dynamically
    ///      from reserveMixETH at the current exchange rate for UIs/events-free
    ///      consumption. The swap path itself never reads the vault rate (NK24).
    function totalReserveETH() public view returns (uint256) {
        return controller.mixETHToETH(reserveMixETH);
    }

    // ─────────────── Hook Permissions ───────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // L-2: gate pool init to the canonical pair
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────── Hook Callbacks ───────────────

    /// @dev L-2 fix: this hook must only ever serve the canonical
    ///      {mixETH, PSP} pool created by PSPFactory. Without the gate anyone
    ///      could initialize decoy pools keyed to this hook's address; the
    ///      hook's PSP/mixETH custody can never square against such a pool's
    ///      currencies, so decoy pools are permanent dead liquidity traps.
    ///      Order-independent: either sort orientation of the pair is accepted.
    ///      NK24: currency-gating alone still allowed decoy pools at other fee
    ///      tiers / tick spacings — accounting-safe (state is shared) but a
    ///      pure phishing surface. Gate the canonical parameters too.
    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal
        view
        override
        returns (bytes4)
    {
        Currency mixETH = controller.getMixETH();
        Currency psp = Currency.wrap(address(controller.getPSP()));

        bool isCanonical =
            (key.currency0 == mixETH && key.currency1 == psp)
                || (key.currency0 == psp && key.currency1 == mixETH);
        if (!isCanonical) revert WrongPoolCurrencies();

        if (key.fee != CANONICAL_FEE || key.tickSpacing != CANONICAL_TICK_SPACING) {
            revert WrongPoolParams();
        }

        return IHooks.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal pure override returns (bytes4)
    { revert("NoStandardLiquidity"); }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal pure override returns (bytes4)
    { revert("NoStandardLiquidity"); }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (mode != Mode.Active && mode != Mode.Flat) revert NotActive();

        // CLOCK-REDESIGN §1: at zero the round is DEAD — both directions
        // halt BEFORE anything else (a tx that starts after zero can never
        // resurrect the clock, even a buy that would have extended it).
        // Predeposit never gets here (NotActive above); Flat only via
        // detonate(), whose exits are flat sells / redemption, not curve.
        if (mode == Mode.Active && block.timestamp >= detonationAt) revert TradingHalted();

        Currency mixETH = controller.getMixETH();
        Currency psp = Currency.wrap(address(controller.getPSP()));

        // Determine direction: negative amountSpecified = exact-input.
        // mixETH in = BUY (PSP out); PSP in = SELL (mixETH out).
        bool isBuy;
        {
            Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
            isBuy = inputCurrency == mixETH;
        }

        if (params.amountSpecified >= 0) revert("ExactOutNotSupported");

        uint256 inputAmount = uint256(int256(-params.amountSpecified));

        // C-1 fix: reject dust swaps — below this size the curve math's
        // fixed-point precision can make round-trips profitable (in wei terms)
        if (inputAmount < MIN_SWAP_INPUT) revert SwapTooSmall();

        // Referral payout identity (A-1 fix 2026-08-26): canonical zaps
        // forward the TRADER address through hookData so payouts resolve
        // against the registry's RECORDED attribution. hookData can never
        // CREATE attribution — V4 hookData is attacker-controlled bytes
        // (any direct poolManager.swap caller forges it; the pre-fix lazy
        // bind let such a caller poison a victim's one-time attribution),
        // so attribution binds exclusively via the user-signed
        // registry.record(refNft). Exactly 32 bytes decodes; anything else
        // (router-direct swaps, empty) trades unattributed — the 5%-of-fee
        // referral leg then re-splits 4% pot / 1% deployerCredit (§3 REVISED).
        address refTrader;
        if (hookData.length == 32) {
            refTrader = abi.decode(hookData, (address));
        }

        if (isBuy) {
            return _handleBuy(sender, key, params, inputAmount, mixETH, psp, refTrader);
        } else {
            return _handleSell(key, params, inputAmount, mixETH, psp, refTrader);
        }
    }

    // ─────────────── Referral payouts ───────────────

    /// @dev Live tier payouts on the trader's RECORDED attribution, paid out
    ///      of the 5% referral LEG of the fee (§3 REVISED 2026-09-01 — the
    ///      2026-08-19 fixed-50bps-of-volume carve-out is RETIRED). Tier
    ///      cuts use the registry's existing tier weights UNCHANGED
    ///      (payoutFor's who[5]/bps[5] — no new tier math); the caller sweeps
    ///      the unpaid remainder (short chains, rounding) into the pot
    ///      escrow. Returns 0 for unattributed traders (empty walk) — the
    ///      caller then re-splits the leg 4% pot / 1% deployerCredit.
    ///      No recording ever happens in this path (A-1 fix).
    function _payReferrals(
        address trader,
        uint256 legMixETH,
        Currency mixETH
    )
        internal
        returns (uint256 paid)
    {
        if (trader == address(0) || legMixETH == 0) return 0;
        PSPReferralRegistry reg = referralRegistry;

        (address[5] memory who, uint24[5] memory bps) = reg.payoutFor(trader);
        if (who[0] == address(0)) return 0; // unattributed — caller re-splits
        IERC20 mix = IERC20(Currency.unwrap(mixETH));
        for (uint256 i = 0; i < 5; i++) {
            if (who[i] == address(0)) break;
            uint256 cut = (legMixETH * bps[i]) / 10000;
            if (cut > 0) {
                mix.safeTransfer(who[i], cut);
                paid += cut;
                emit ReferralPaid(trader, who[i], i, cut);
            }
        }
    }

    /// @dev §3 REVISED fee router — splits ONE fee (already sliced off the
    ///      trade by swapFeeBps()) into its legs, bps of the exact fee:
    ///        stakers 6000 / pot 3500 / referral leg ~500 (the subtraction
    ///        remainder, so cross-leg rounding dust rides it deterministically)
    ///      attributed   → the leg pays the chain per tier weights; unpaid
    ///                     tier weight + rounding → pot escrow
    ///      unattributed → 1% (100bps) accrues to deployerCredit, the rest of
    ///                     the leg (4% + dust) → pot escrow
    ///      Returns the staker leg for the accumulator feed. Invariant:
    ///      stakerLeg + potΔ + deployerCreditΔ + referralPaid == feeMixETH.
    function _splitFee(address trader, uint256 feeMixETH, Currency mixETH) internal returns (uint256 stakerLeg) {
        stakerLeg = (feeMixETH * STAKER_BPS) / 10000;
        uint256 potLeg = (feeMixETH * POT_BPS) / 10000;
        uint256 refLeg = feeMixETH - stakerLeg - potLeg; // ~5% + rounding dust

        uint256 paid = _payReferrals(trader, refLeg, mixETH);
        if (paid != 0) {
            potBalance += potLeg + (refLeg - paid); // unpaid tier weight + dust → pot
        } else {
            uint256 deployerLeg = (feeMixETH * DEPLOYER_BPS) / 10000;
            deployerCredit += deployerLeg;
            potBalance += potLeg + (refLeg - deployerLeg); // 4% + dust → pot
        }
    }

    // ─────────────── Buy Logic ───────────────

    function _handleBuy(address sender, PoolKey calldata key, SwapParams calldata params, uint256 mixETHInput,
        Currency mixETH, Currency psp, address refTrader)
        internal returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (mode == Mode.Flat) {
            // scoopy 2026-08-29: once the curve flattens, BUYING is disabled —
            // the flat window is a settlement/exit at average backing, not a
            // live market. Nobody should buy into a dying round; the sell
            // path (_handleFlatSell) stays open until Destroyed.
            revert BuyingDisabled();
        }

        // NK24 fix: mixETH is the unit of account — the curve is solved
        // directly in mixETH. No vault-rate read anywhere in this path.
        //
        // Fee split (CLOCK-REDESIGN §3 REVISED): swapFeeBps() slice (10%
        // pre-wave → 2.5% above on sine rounds, flat 5% on zone rounds)
        // routed by _splitFee — 60% stakers / 35% pot / 5% referral chain
        // (attributed) or 4% pot / 1% deployerCredit (unattributed);
        // remainders → pot escrow.
        uint256 feeMixETH = (mixETHInput * swapFeeBps()) / 10000;
        uint256 curveMixETH = mixETHInput - feeMixETH;

        uint256 pspOut = sineActive
            ? SineMath.buyOut(sineCurve, reserveMixETH, curveMixETH)
            : CurveMath.computeBuyOutput(curveMixETH, totalSupplyPSP, curveConfig);
        if (pspOut == 0) revert ZeroOutput();

        // CEI: update state before external calls
        reserveMixETH += curveMixETH;
        totalSupplyPSP += pspOut;

        // ── the clock eats time, discrete (CLOCK-REDESIGN §1) ──
        // +TIME_PER_PSP per WHOLE PSP out, floored. The halt gate above
        // guarantees the clock was alive at tx start. Cap: remaining time
        // may never exceed DET_WINDOW.
        uint256 wholePSP = pspOut / 1e18;
        if (wholePSP != 0) {
            uint256 newDet = detonationAt + TIME_PER_PSP * wholePSP;
            uint256 cap = block.timestamp + DET_WINDOW;
            detonationAt = newDet > cap ? cap : newDet;
            emit TimeAdded(sender, wholePSP, detonationAt);
        }

        // ── one ticket per buy tx, no dedup (CLOCK-REDESIGN §2) ──
        // Seat identity: the attributed trader when the zap forwarded one,
        // else the swap sender. Same wallet buying twice holds two seats.
        address buyer = refTrader != address(0) ? refTrader : sender;
        uint256 seat = ticketCount; // absolute seat number
        tickets[seat % 10] = Ticket({
            buyer: buyer,
            ts: uint64(block.timestamp),
            pspAmount: uint128(pspOut),
            mixPaid: uint128(mixETHInput)
        });
        ticketCount = seat + 1;

        emit Buy(msg.sender, mixETHInput, pspOut, totalSupplyPSP, reserveMixETH);

        // Take mixETH from PoolManager to hook custody
        poolManager.take(mixETH, address(this), mixETHInput);

        // Mint PSP for the buyer
        controller.mintPSPForSwap(pspOut);

        // §3 REVISED fee routing (referral chain leaves custody live; the
        // staker accumulator feeds; the pot escrows; remainders → pot).
        uint256 stakerFeeMixETH = _splitFee(refTrader, feeMixETH, mixETH);
        if (stakerFeeMixETH > 0) {
            controller.addFees(stakerFeeMixETH);
        }

        // Settle PSP to PoolManager
        _settleCurrency(psp, pspOut);

        // V4 BeforeSwapDelta convention:
        // specified positive = hook PROVIDES specified currency (reduces AMM amount to 0)
        // unspecified negative = hook PROVIDES unspecified output (consumes it from pool)
        BeforeSwapDelta hookDelta = toBeforeSwapDelta(
            int128(int256(mixETHInput)),   // +input: hook handles the specified input
            int128(-int256(pspOut))         // -output: hook provides the unspecified output
        );

        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    // ─────────────── Sell Logic ───────────────

    function _handleSell(PoolKey calldata key, SwapParams calldata params, uint256 pspInputAmount,
        Currency mixETH, Currency psp, address refTrader)
        internal returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (pspInputAmount == 0) revert BuyZeroAmount();
        if (pspInputAmount >= totalSupplyPSP) revert SellExceedsSupply();

        if (mode == Mode.Flat) {
            return _handleFlatSell(key, params, pspInputAmount, mixETH, psp);
        }

        // NK24 fix: compute the sell integral natively in mixETH. The reserve
        // is debited exactly what the curve says, in the same unit it is
        // denominated in — a vault-rate move can no longer make the debit
        // exceed the corresponding buy credits (the old code converted an
        // ETH integral at the LIVE rate, so a >1bps rate drop between buy and
        // sell extracted other holders' backing; a 95% drop underflowed the
        // reserve and bricked every sell).
        uint256 mixETHOut = sineActive
            ? SineMath.sellOut(sineCurve, reserveMixETH, pspInputAmount)
            : CurveMath.computeSellOutput(pspInputAmount, totalSupplyPSP, curveConfig);

        // Fee split (CLOCK-REDESIGN §3 REVISED): swapFeeBps() of the
        // out-value, routed by _splitFee — 60/35/5 (or 60/39/1) of THE FEE.
        // The ENTIRE sold PSP is burned — backing stays clean. Sells mint
        // NO ticket and add NO time (only buys do); they only pass the
        // halt gate at zero.
        uint256 feeMixETH = (mixETHOut * swapFeeBps()) / 10000;
        uint256 mixETHToUser = mixETHOut - feeMixETH;
        if (mixETHToUser == 0) revert ZeroOutput();

        // CEI: full out-value leaves the reserve (user + fees + referrals all
        // draw from it); supply drops by the FULL burned input.
        reserveMixETH -= mixETHOut;
        totalSupplyPSP -= pspInputAmount;

        emit Sell(msg.sender, pspInputAmount, mixETHToUser, totalSupplyPSP, reserveMixETH);

        // Take PSP from PoolManager to hook custody (pre-funded by router)
        poolManager.take(psp, address(this), pspInputAmount);

        // Burn the user's PSP — all of it
        controller.burnPSPForSwap(pspInputAmount);

        // Send mixETH to user via PoolManager
        _settleCurrency(mixETH, mixETHToUser);

        // §3 REVISED fee routing (sell side — same legs as buys)
        uint256 stakerFeeMixETH = _splitFee(refTrader, feeMixETH, mixETH);
        if (stakerFeeMixETH > 0) {
            controller.addFees(stakerFeeMixETH);
        }

        // V4 BeforeSwapDelta: specified positive = hook handles input, unspecified negative = hook provides output
        BeforeSwapDelta hookDelta = toBeforeSwapDelta(
            int128(int256(pspInputAmount)),  // +input: hook handles the specified PSP input
            int128(-int256(mixETHToUser))    // -output: hook provides the unspecified mixETH output
        );

        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    // ─────────────── Flat Mode (Destruction) ───────────────

    // (_handleFlatBuy deleted 2026-08-29, scoopy: flat mode is a one-way
    // exit — buys revert BuyingDisabled in _handleBuy. Only _handleFlatSell
    // remains: pro-rata PSP→mixETH settlement, fee-free (F-9).)

    function _handleFlatSell(PoolKey calldata, SwapParams calldata, uint256 pspInputAmount,
        Currency mixETH, Currency psp)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (totalSupplyPSP == 0) revert NotActive();

        // Direct computation to avoid divide-before-multiply rounding
        // flatPrice = reserveMixETH / totalSupplyPSP (in 1e18)
        // totalMixETHOut = pspInputAmount * flatPrice / 1e18
        //   = pspInputAmount * reserveMixETH / totalSupplyPSP
        uint256 totalMixETHOut = (pspInputAmount * reserveMixETH) / totalSupplyPSP;
        // F-9 fix (2026-08-19): NO fee in Flat — exits pay exactly pro-rata
        // avg backing, floor-only. (The previous A7/L-3 ceils guarded the
        // fee slices that no longer exist in this mode; the Active curve
        // paths keep their own fee math. out = floor(in*R/S) keeps
        // R1*S >= R*S1 exactly — no user dust in either direction.)
        uint256 mixETHToUser = totalMixETHOut;
        if (mixETHToUser == 0) revert ZeroOutput();

        reserveMixETH -= totalMixETHOut;
        totalSupplyPSP -= pspInputAmount;

        emit Sell(msg.sender, pspInputAmount, mixETHToUser, totalSupplyPSP, reserveMixETH);

        // Take PSP from PoolManager to hook custody (pre-funded by router)
        poolManager.take(psp, address(this), pspInputAmount);

        controller.burnPSPForSwap(pspInputAmount);
        _settleCurrency(mixETH, mixETHToUser);

        BeforeSwapDelta hookDelta = toBeforeSwapDelta(
            int128(int256(pspInputAmount)),  // +input: hook handles specified input
            int128(-int256(mixETHToUser))    // -output: hook provides unspecified output
        );
        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    // ─────────────── Fee Distribution ───────────────

    /// @notice Send accumulated fees to a position holder (called by the
    ///         staker during claims, or the controller in legacy paths)
    /// @dev Available fees = hook's mixETH balance - reserveMixETH - the
    ///      unclaimed ladder pot - the unclaimed deployer credit. The pot
    ///      and the deployer leg are escrowed (CLOCK-REDESIGN §2/§3) and
    ///      must never leak into staker payouts: invariant
    ///      balanceOf(hook) = reserveMixETH + (potBalance - potPaid)
    ///      + (deployerCredit - deployerCreditPaid) + availableFees.
    function sendFees(address to, uint256 mixETHAmount) external {
        // 2026-08-19: fee claims moved to PSPStaker — it pulls payouts for
        // its positions directly. Controller retains access (genesis share
        // payouts ride the same path).
        if (msg.sender != address(controller) && msg.sender != _stakerClaimant()) revert NotController();

        address mixETHAddr = Currency.unwrap(controller.getMixETH());
        uint256 balance = IERC20(mixETHAddr).balanceOf(address(this));
        // Solidity 0.8 reverts on underflow if escrows exceed the balance
        uint256 available = balance - reserveMixETH - (potBalance - potPaid) - (deployerCredit - deployerCreditPaid);
        if (mixETHAmount > available) revert InsufficientFees();

        IERC20(mixETHAddr).safeTransfer(to, mixETHAmount);

        emit FeesSent(to, mixETHAmount);
    }

    // ─────────────── Destruction Support ───────────────

    // (redeemPotBacking removed 2026-08-19 with the side pot — the pot no
    // longer exists; carpetBomb flattens straight to the exit window.)
    //
    // (drainAll removed 2026-08-30, scoopy: "people should always be able to
    // come back to retrieve it" — redemption is INDEFINITE. The dead hook
    // custodies the backing of unredeemed PSP forever; finalizeCarpet no
    // longer drains anything, and death no longer endows the next round: the
    // factory's carry is whatever actually sits on the factory (normally
    // zero). Abandoned value doesn't evaporate or roll — it waits.)

    event Redeemed(address indexed who, uint256 pspIn, uint256 mixETHOut);

    /// @notice Burn PSP for its pro-rata reserve backing — INDEFINITELY.
    ///         Available from the carpet bomb onward, in Flat AND Destroyed
    ///         modes: a holder who returns a year later can still redeem.
    ///         Fee-free (same F-9 principle as flat exits): this is not a
    ///         trade, it's retrieving what's yours.
    /// @dev Same floor math as _handleFlatSell (out = floor(in·R/S)) — the
    ///      invariant R/S is preserved across redemptions, so the payout
    ///      per PSP never changes after death. CEI: state before externals.
    function redeemBacking(uint256 pspAmount) external returns (uint256 mixETHOut) {
        if (mode != Mode.Flat && mode != Mode.Destroyed) revert NotActive();
        if (pspAmount == 0) revert BuyZeroAmount();
        if (pspAmount > totalSupplyPSP) revert SellExceedsSupply();

        mixETHOut = (pspAmount * reserveMixETH) / totalSupplyPSP;
        reserveMixETH -= mixETHOut;
        totalSupplyPSP -= pspAmount;

        emit Redeemed(msg.sender, pspAmount, mixETHOut);

        IERC20(address(controller.getPSP())).safeTransferFrom(msg.sender, address(this), pspAmount);
        controller.burnPSPForSwap(pspAmount);
        if (mixETHOut > 0) {
            IERC20(Currency.unwrap(controller.getMixETH())).safeTransfer(msg.sender, mixETHOut);
        }
    }

    // ─────────────── Ladder board + pot claims (CLOCK-REDESIGN §2) ───────────────

    /// @notice Seats currently on the board (≤ 10).
    function seatedCount() public view returns (uint256) {
        return ticketCount < 10 ? ticketCount : 10;
    }

    /// @notice The rolling last-10 ticket board.
    /// @param i seat age, 0 = NEWEST (the top ladder rung) … seatedCount()-1 = OLDEST
    /// @return (buyer, pspAmount, mixPaid, ts) of that buy tx
    function board(uint256 i) external view returns (address, uint256, uint256, uint256) {
        if (i >= seatedCount()) revert BadSeatIndex();
        uint256 seat = ticketCount - 1 - i;
        Ticket storage t = tickets[seat % 10];
        return (t.buyer, t.pspAmount, t.mixPaid, t.ts);
    }

    /// @dev Distribution denominator for a board of `n` seated tickets:
    ///      the partial ladder sum (renormalizes to 100% when n < 10).
    function _ladderDenom(uint256 n) internal pure returns (uint256 denom) {
        for (uint256 a; a < n; ++a) {
            denom += _ladderBps(a);
        }
    }

    /// @notice Everything `who` can claim right now: every unclaimed seat they
    ///         hold across the frozen distribution. Exact floor math off the
    ///      frozen potBalance, independent of other claimants' ordering.
    function claimablePot(address who) public view returns (uint256 amount) {
        uint256 n = seatedCount();
        if (n == 0 || mode == Mode.Predeposit || mode == Mode.Active) return 0;
        uint256 denom = _ladderDenom(n);
        for (uint256 i; i < n; ++i) {
            uint256 seat = ticketCount - 1 - i;
            if (tickets[seat % 10].buyer == who && !seatClaimed[seat]) {
                amount += (potBalance * _ladderBps(i)) / denom;
            }
        }
    }

    /// @notice Claim every seat the caller owns on the frozen board. PULL-based,
    ///         forever: no deadline, no sweep — a claimant returning a year
    ///         (or a century) later is still paid in full.
    function claimPot() external {
        if (mode == Mode.Predeposit || mode == Mode.Active) revert NotDetonated();

        uint256 n = seatedCount();
        uint256 denom = _ladderDenom(n);
        uint256 amount;
        for (uint256 i; i < n; ++i) {
            uint256 seat = ticketCount - 1 - i;
            if (tickets[seat % 10].buyer == msg.sender && !seatClaimed[seat]) {
                seatClaimed[seat] = true;
                amount += (potBalance * _ladderBps(i)) / denom;
            }
        }
        if (amount == 0) revert NothingToClaim();

        // CEI: books updated before the transfer; potBalance stays FROZEN as
        // the distribution base — potPaid tracks the drain.
        potPaid += amount;
        IERC20(Currency.unwrap(controller.getMixETH())).safeTransfer(msg.sender, amount);

        emit PotClaimed(msg.sender, amount);
    }

    /// @notice Claim the accrued deployer rake (1% legs of unattributed
    ///         fees). PULL-based, forever: no deadline, no sweep.
    function claimDeployerCredit() external {
        uint256 outstanding = deployerCredit - deployerCreditPaid;
        if (outstanding == 0) revert NothingToClaim();

        // CEI: books updated before the transfer; deployerCredit stays as
        // the gross accrual record — deployerCreditPaid tracks the drain.
        deployerCreditPaid += outstanding;
        IERC20(Currency.unwrap(controller.getMixETH())).safeTransfer(deployerCutTo, outstanding);

        emit DeployerCreditClaimed(deployerCutTo, outstanding);
    }

    // ─────────────── Mode Management ───────────────

    function setMode(Mode newMode) external {
        if (msg.sender != address(controller)) revert NotController();

        // Enforce valid transitions
        if (mode == Mode.Predeposit && newMode != Mode.Active) revert InvalidMode();
        if (mode == Mode.Active && newMode != Mode.Flat) revert InvalidMode();
        if (mode == Mode.Flat && newMode != Mode.Destroyed) revert InvalidMode();
        if (mode == Mode.Destroyed) revert InvalidMode();

        mode = newMode;

        // CLOCK-REDESIGN §1: the clock is ARMED at the Active transition —
        // the launch buy that flips the round live starts the 72h countdown.
        // Predeposit never touches it; the Active→Flat transition (detonate)
        // leaves detonationAt as the frozen historical zero point.
        if (newMode == Mode.Active) {
            detonationAt = block.timestamp + DET_WINDOW;
        }

        emit ModeChanged(newMode);
    }

    /// @notice Initialize curve state with pooled predeposit buy
    /// @param _reserveMixETH The actual mixETH amount transferred to this hook
    function initializeCurve(uint256 _reserveMixETH, uint256 _initialSupply) external {
        if (msg.sender != address(controller)) revert NotController();
        if (poolInitialized) revert InvalidMode();

        // Sine flavor: materialize the wave from the ACTUAL boot raised —
        // anchors, tread positions and the top price are invariant to it.
        if (sineConfigured) {
            sineCurve = SineMath.materialize(sineParams, _reserveMixETH);
            sineActive = true;
        }

        reserveMixETH = _reserveMixETH;
        totalSupplyPSP = _initialSupply;
        poolInitialized = true;

        emit PoolInitialized();
    }

    /// @notice Factory-only: arm the tilted-sine curve for this round. Must be
    ///         called before launch (pool init); params validated (ampBps ≤
    ///         10000 = the 45° tilt cap ⇒ monotone wave by construction).
    function configureSine(SineMath.Params calldata p) external {
        if (msg.sender != controller.factory()) revert NotController();
        if (poolInitialized || sineConfigured) revert InvalidMode();
        SineMath.validate(p);
        sineParams = p;
        sineConfigured = true;
    }

    /// @notice Genesis PSP the sine curve mints for the actual boot (view —
    ///         the controller reads this at launch; initializeCurve re-runs
    ///         the same pure computation to store the curve).
    function sineGenesisPSP(uint256 bootActual) external view returns (uint256) {
        return SineMath.materialize(sineParams, bootActual).q0;
    }

    /// @notice Marginal price at cumulative reserve R (mixETH per PSP) — UI view.
    function sinePriceAt(uint256 R) external view returns (uint256) {
        return SineMath.priceAt(sineCurve, R);
    }

    /// @notice Quarter-wave checkpoint supplies (auto-getter omits fixed arrays).
    function getSineCheckpoints() external view returns (uint256[13] memory) {
        return sineCurve.cp;
    }

    // ─────────────── View Functions ───────────────

    /// @notice Full curve zones (auto-getter omits arrays)
    function getCurveZones() external view returns (CurveMath.Zone[] memory) {
        return curveConfig.zones;
    }

    /// @return mixETH-denominated marginal price (curve unit of account)
    function getMarginalPrice() external view returns (uint256) {
        return CurveMath.marginalPrice(totalSupplyPSP, curveConfig);
    }

    /// @return mixETH-denominated flat-mode price (NK24: no ETH conversion)
    function getFlatPrice() external view returns (uint256) {
        if (totalSupplyPSP == 0) return 0;
        return (reserveMixETH * 1e18) / totalSupplyPSP;
    }

    /// @param mixETHInput mixETH to spend on the curve
    /// @return PSP output for a mixETH input (curve unit of account)
    function getBuyOutput(uint256 mixETHInput) external view returns (uint256) {
        // B7b catch (2026-08-19): the view must mirror execution — the curve
        // only ever sees the POST-FEE input. Flat mode has NO buys at all
        // (scoopy 2026-08-29) — the view reverts like the swap path.
        // Sine-aware + sliding-fee-aware (2026-08-30): this used to quote the
        // ZONE math on sine rounds — wrong curve, wrong fee. CLOCK-REDESIGN:
        // at zero the view reverts TradingHalted exactly like the swap path.
        if (mode == Mode.Flat) revert BuyingDisabled();
        if (block.timestamp >= detonationAt) revert TradingHalted();
        uint256 fee = (mixETHInput * swapFeeBps()) / 10000;
        uint256 curveMix = mixETHInput - fee;
        return sineActive
            ? SineMath.buyOut(sineCurve, reserveMixETH, curveMix)
            : CurveMath.computeBuyOutput(curveMix, totalSupplyPSP, curveConfig);
    }

    /// @return mixETH output for a PSP sell (curve unit of account)
    function getSellOutput(uint256 pspInput) external view returns (uint256) {
        // Mirror execution (the B7b principle, sell side): sellers receive
        // mixETHOut MINUS the fee slice; sine-aware since 2026-08-30. Flat
        // exits are fee-free pro-rata (F-9) and stay open forever. Curve
        // sells halt at zero exactly like the swap path (CLOCK-REDESIGN §1).
        if (mode == Mode.Flat) {
            return (pspInput * reserveMixETH) / totalSupplyPSP;
        }
        if (block.timestamp >= detonationAt) revert TradingHalted();
        uint256 out = sineActive
            ? SineMath.sellOut(sineCurve, reserveMixETH, pspInput)
            : CurveMath.computeSellOutput(pspInput, totalSupplyPSP, curveConfig);
        return out - (out * swapFeeBps()) / 10000;
    }
}
