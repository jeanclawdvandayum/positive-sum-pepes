# CLOCK REDESIGN — PSP goes full SigmaBF (scoopy directive 2026-08-31)

"The sigmabf version. No governance for carpetBomb — the countdown timer
controls it. Once the clock strikes 0, no subsequent buys can push it past
that. Hard-enforced by a timestamp. After zero the UI disables buying/selling
automatically and displays a detonate button under the clock (hidden until
activatable) which processes the distribution of the pot, the flattening of
the curve, and the start of the next predeposit window. After it is pressed,
the redemption portal goes live: redeem PSP for the mixETH reserves in the
bonding curve, and immediate withdrawal from staked PSP positions."

This doc is the single source of truth for both lanes (src/ contracts,
frontend/). ABI shapes below are BINDING for the frontend child.

## 1. The clock (CurveHook)

- `uint256 public detonationAt;` — ms? NO: SECONDS, block.timestamp domain.
- Armed at Active-mode transition: `detonationAt = block.timestamp + 72h`.
- Buy path (curve mode only): BEFORE anything else,
  `if (block.timestamp >= detonationAt) revert TradingHalted();`
- Time injection: DISCRETE +5 minutes per WHOLE PSP bought
  (`floor(pspOut / 1e18)` whole units), i.e.
  `detonationAt += 5 minutes * wholePSP` — only applied while the clock is
  still alive at tx start (`block.timestamp < detonationAt` at tx start; a
  tx that starts after zero can NEVER resurrect the clock, even if it's the
  buy that would have extended it — the halt check runs first).
- Cap: remaining time may never exceed 72h
  (`detonationAt = min(detonationAt + add, block.timestamp + 72h)`).
- Sells (curve mode): same `TradingHalted` gate at zero. (After detonation,
  curve selling is replaced entirely by redemption at average backing.)
- Event: `event TimeAdded(address indexed buyer, uint256 wholePsp, uint256 newDetonationAt);`
  — the tape + "last time added by X · Ym ago" line run off this.
- View for the UI clock: `detonationAt` itself (frontend computes remaining).
- Predeposit/genesis buys do NOT touch the clock (unchanged rule).

## 2. Tickets + ladder (CurveHook or a lean LadderHolder — implementer picks,
   but the READ surface below is binding)

- Every curve buy = ONE ticket (one seat per buy tx, no dedup — the same
  address can hold multiple seats, matching SigmaBF "7.6 psp = top 7").
- Rolling last-10 board. Storage: circular buffer of 10
  `(address buyer, uint256 pspAmount, uint256 mixPaid, uint256 ts)` +
  `uint256 ticketCount` total.
- At detonation the pot distributes 25/18/14/10/8/7/6/5/4/3% from NEWEST
  ticket to OLDEST. Fewer than 10 tickets → renormalize to 100% (nobody
  gets dusted). More than 10 → only the newest 10 hold claims.
- PULL-BASED, forever, no deadline, no sweep:
  `function claimPot() external` — caller claims every seat they own across
  the distribution. Claims stay open after the round dies (claims-forever).
- View: `function board(uint256 i) external view returns (address, uint256, uint256, uint256)`
  and `function potBalance() external view returns (uint256)` +
  `function claimablePot(address) external view returns (uint256)`.

## 3. The pot + fee routing (REVISED by scoopy 2026-08-31, same day — this
   supersedes the earlier 60-pot/40-staker-of-net draft)

- Fee stays the sliding sine fee: 10% pre-wave → linear → 2.5% at/above wave.
- Split is OF THE FEE, in bps of the fee amount, self-scaling with the sine:
  - **WITH referral attribution** (any tier of the chain attributable):
    60% stakers / 35% pot / 5% referrer chain (the 5% leg pays the
    attribution chain per its existing tier weights — payoutFor's
    who[5]/bps[5]; do not invent new tier math).
  - **WITHOUT any attribution**: 60% stakers / 35% pot / 4% pot / 1%
    deployer — i.e. pot effectively 39%, deployer 1%.
- The 2026-08-19 fixed-50bps-of-volume referral is RETIRED by this
  directive: referral returns to a fee-slice basis (5% of fee). Scoopy
  knows the wave-top tradeoff; the deployer rake on unattributed flow is
  the deliberate design.
- Deployer cut: `address public immutable deployerCutTo;` set at deploy
  (constructor arg from the deploy script — testnet: the throwaway
  deployer; mainnet: scoopy's address). Accrues to a
  `deployerCredit` accumulator inside the hook — PULL-BASED claim
  (`claimDeployerCredit()`), no deadline, no sweep. Zero-address
  constructor arg reverts.
- Rounding/dust: compute each leg in bps of the exact fee; any remainder
  (dust) goes to the pot escrow. Deterministic destination, asserted in
  tests to the wei.
- Kill the "factory generic carry" fee destination on live rounds; the only
  things that leave at round end are: pot (ladder claims, forever) and
  backing (redemption, forever).

## 4. Detonation (replaces governance entirely)

- `function detonate() external` — permissionless, gated
  `block.timestamp >= detonationAt`, idempotent via mode check.
  In ONE tx:
  1. snapshot the board + freeze potBalance (no more fee accrual — mode
     leaves Active);
  2. `hook.setMode(Flat)` — curve flattens (existing flat machinery);
  3. staked positions: all locks open immediately (unlock bypasses vest —
     same carve carpetBomb already had, now unconditional at flat);
  4. birth the next round's predeposit window (compose the existing staged
     spawn: reserve + birth, or the spawnNextRound shim — machinery exists).
- STRIP: proposeCarpetBomb, voteCarpetBomb, carpetBomb (governance one),
  QUORUM_BIPS/MAJORITY_BIPS, VOTE_DURATION, castWeightOn, proposalCount,
  totalVotableWeight's vote role (staker keeps the weight views it needs for
  FEES only). PSPStaker: remove vote-related weight bookkeeping that exists
  solely for quorum. Repack timings WITHOUT the vote slot — derive widths,
  add the compile-time width assert + full-axis roundtrip test per LESSONS
  2026-08-24/2026-08-18. Keep wallet-cap slot.
- flatTime stays (exit-window analytics); FLAT_EXIT_WINDOW: the 3d window
  concept is SUPERSEDED — redemption is indefinite. finalizeCarpet's drain
  role dies; the dead hook custodies backing forever (2026-08-30 II rule).
- Events: `event Detonated(address indexed by, uint256 potDistributed, address nextRound);`

## 5. Redemption portal (mostly exists — verify + wire)

- `hook.redeemBacking(psp)` — floor pro-rata R/S invariant, payout per PSP
  frozen at detonation (2026-08-30 II semantics). PSP BURNED on redeem.
- Immediate staked withdrawal: at Flat, `unlock()` skips the vest decay
  entirely (staker receives staked PSP + accrued fees; the PSP then redeems
  via the portal if desired).
- No deadline, ever. The UI portal scans dead rounds for redeemable PSP.

## 6. Frontend (builds against this spec; ABI section above is binding)

1. PhaseEngine: wire `setDeadline(detonationAt * 1000)` off the round lane
   (poll cadence: piggyback the existing useRound/useRpcReads cadences —
   no new aggressive polling).
2. At zero (`remaining <= 0`): buy + sell tabs hard-disabled with the
   deadpan halt state ("the clock struck zero. no more moves." — voice pass
   at build).
3. DETONATE button under the clock panel: hidden while
   `now < detonationAt`; appears at zero (phase=CRITICAL styling), one
   click → detonate() → tx pending → success flips the page into the
   post-round state.
4. Post-round state: redemption portal panel (your PSP → mixETH at frozen
   payout, one click; plus "unlock staked position" immediate flow) + the
   ladder board settles to its final distribution + claims-forever rows.
5. Ladder board: real ticket lane off TimeAdded/board reads (the shipped
   dormant LadderHolder keyframes light up).
6. Tape: TimeAdded events → "X bought N psp · +5:00" entries; the
   "last time added" line goes live.
7. Red-line rules unchanged: no invented reads, HashRouter/?ref= capture,
   RainbowKit, pepeArt.json, pepeRender.ts, CurveChart scale math, PixelIcon
   grids, cadences. PhaseEngine stays the ONE rAF loop.

## 7. Test matrix (contracts child must prove — REAL behavior, no vm.mockCall
   on token-movers)

- clock arms at 72h at Active; buy of 2.49 psp adds +10:00 (2 whole);
- extension cap: cannot exceed now+72h remaining;
- zero is DEAD: warp past detonationAt, buy reverts TradingHalted even
  though it would add time; sell reverts too;
- board: 12 buyers → only newest 10 seated; same address twice = 2 seats;
- distribution: exact bps math on a 10-seat and a 3-seat (renormalized)
  board; dust tolerance asserted;
- claimPot forever: claim → warp a year → second claimant still paid;
- fee split (§3 REVISED): with attribution — exact 60/35/5 of fee to the wei
  (5% leg across the chain per tier weights); with NO attribution —
  60/35 + 4% pot / 1% deployerCredit, deployer claim pays pull-based;
  dust lands in pot escrow deterministically;
- detonate: one tx → flat + locks open (staker withdraws instantly with no
  decay loss) + next round birthed + predeposit window open + pot frozen;
- redemption: post-detonation payout per PSP frozen (later trades in the
  NEXT round don't change it), PSP burned;
- governance fully dead: proposeCarpetBomb/voteCarpetBomb gone (build fails
  if any reference survives — add a grep gate to the test script);
- timings repack roundtrip (widths derived + asserted);
- full existing suite still green (carpet-bomb governance tests REPLACED by
  timer tests, not deleted into silence).
