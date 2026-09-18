# UX assessment — first-time visitor lens (2026-09-18)

Branch `single-sine-fable-pass`. Method: full read of every page and component in
`frontend/src`, headless-Chrome screenshots at 1280px and 390px of `/`, `/play`,
`/stake`, `/predeposit`, `/graveyard` against the Sept-10 Base Sepolia deployment
(no wallet, partial RPC data in headless), and `REDESIGN-SPEC.md` for intent.
The baseline is strong: one phase system, a real clock, real pepes, deadpan voice,
honest states. The gaps below are almost all *comprehension* gaps, not craft gaps.

## The one-paragraph diagnosis

A first-time visitor is never told the game loop in one breath. The landing hero
sells the grievance ("same insiders, same bullshit"), the play page's headline uses
insider slang ("carpet bombing"), and the swap card describes a trade, not a move
in a game. The mechanics are all *documented* (the rules table is excellent) but
nothing on the two pages people actually land on says, plainly: **every buy takes a
ticket, resets the clock a little, and puts you at the top of a 10-seat ladder; when
the clock hits zero the last 10 buyers split the pot; afterwards every PSP redeems
for its share of the backing.** Add that sentence, make the swap card speak in those
terms, give the connected user a personal "your seat / your payout / tickets until
you're bumped" strip, and the app becomes intuitable in one visit and worth checking
back on every hour.

## Findings, ordered by impact

### A. Vocabulary drift (all pages) — highest leverage, zero risk
The same object has four names: *ticket* (rules, clock band), *seat* (ladder,
swap card), *spot* (landing, "buy 1 ladder spot"), *unit* (code). "Carpet bomb"
survives from the retired governance vote. "Flat" is a contract mode, not a word a
player knows. "IBCO", "lePSP", "epoch", "six-epoch exit", "wave", "softened
cube-root growth" appear on first contact with no gloss.

Proposed canon (use everywhere, gloss once per page on first use):
| say | not |
|---|---|
| ticket (a buy of ≥ 1 ticket takes seat #1) | spot, unit |
| seat #1…#10 (positions on the ladder) | rung, slot |
| **carpet bombing** stays (it is the meme lampooning the rug pull); gloss it once per page: "holding the top seats when the clock hits zero" | — |
| the round is **over** / **settled** | flat |
| **opening buy** (the pooled predeposit) | IBCO |
| lePSP = *locked PSP that earns fees* (gloss every first use) | bare lePSP |
| **cooldown** (28 days, 6 steps) | six-epoch exit, vest |
| **prize pot** | total pot |
| **backing** (what 1 PSP redeems for) | curve reserves |

### B. Landing page (`/`) — sells attitude before it teaches the loop
1. Hero has no game sentence. The spec's own headline ("a bomb, a clock, and a pot
   that only grows") explained the loop in nine words; the shipped one explains a
   grievance. Keep the attitude line as the subhead; make the H1 (or the first line
   under it) the loop.
2. "buy psp" CTA appears before the reader knows what a buy does. Pair it with a
   secondary "how it works · 30 seconds" anchor.
3. Eight story beats in a 2-column grid: reading order is ambiguous and the core
   loop (join → buy/ticket → clock → detonate → claim) is interleaved with
   peripheral beats (NFT art, mixETH yield, curve math). Curve math is beat #2;
   the actual hook (clock + pot) is beat #4.
4. The `PayoutSlider` is the single most intuitive element on the site and it is
   buried at the bottom of the rules table. It is also missing the half that makes
   the ratio land: at that pot, **a ticket costs pot ÷ 10,000**, so "#1 pays 25%
   for a 0.01% buy". Show ticket cost next to the pot on the slider.
5. Rules table is written for auditors ("rounded up to wei, with a one-wei
   floor"). Right content, wrong altitude for first contact: precede it with a
   five-line plain version; keep the exact table behind it.
6. Header mini-clock renders `--:--:-- loading` when there is no live round (and
   while RPC is slow). To a newcomer that reads as broken. It needs a state word:
   "no live round", "opening buy open", "settled", "connecting…".
7. The dev-facing line "new deployment rules · existing rounds keep their original
   curve and ticket rules." is the first text on the page. Move to the footer.

### C. Play page (`/play`) — the machine is loud, the rules are silent
8. Headline: "*X* is carpet bombing for *Y* mixETH in: 00:00:00". Decision (scoopy,
   2026-09-18): the phrase stays, it is the meme. Add the causal gloss under the
   clock instead: "the carpet bombers on the ladder split the pot at zero."
9. Nothing under the clock says what zero means for *me*. One line: "at zero,
   trading stops · the last 10 buyers split the pot · every PSP redeems for its
   backing."
10. The swap card describes a token swap. The move it actually makes is the
    product. Lead the card with the consequence, computed from reads that already
    exist (`ticketPrice`, board, `detWindow`): "**this buy → 2 tickets · seat #1 ·
    +2:18 on the clock · pays 25% (≈ 1.4 mixETH) if it ends now**". Today this is a
    10px grey line that only appears after typing, phrased as "minimum X · N seats
    · +Xm before the clock cap · estimated at the current ticket price…".
11. **Copy bug:** empty-ladder text says "each 0.005 mixETH purchased earns one
    ticket" (`PotBoard.tsx`, hardcoded). On v3 rounds a ticket is `pot ÷ 10,000`
    and changes every trade. Use `round.ticketPrice`.
12. Ten identical "open seat · N% with a full ladder. prime frog real estate."
    rows are noise. Say it once above the list; rows show `#n · N% · — mixETH`.
    At 390px the row text truncates to "open seat · 2…" and the % is lost (see
    mobile screenshot).
13. Pot band shows "total pot" and "curve reserves" side by side with no cue that
    one is the prize and the other is the backing. Rename per the canon; add a
    "≈ $" next to the pot (USD hook exists on the stake page via `useEthUsd`).
14. No personal stake on the page. For a connected wallet, add a strip: "**you hold
    seat #3 · pays 14% = 0.83 mixETH if it ends now · 2 more tickets bump you off**"
    (board is already read; "tickets until bumped" = your oldest seat index). This
    is the revisit hook the spec asked for and the thing that makes the page
    addictive rather than informative.
15. Phase word ("calm / heating up / critical") is required by spec §2 (meaning
    never rides on color alone) and is not visible next to the full clock.
16. Curve chart with linear/log + price/supply toggles is an analyst instrument
    sitting between the ladder and the ticker. For a newcomer the chart answers a
    question they haven't asked. Fold it into a collapsed "the curve" section (or
    a sparkline with price-now and your-entry) and move the fee line ("trade fee
    X% · 60% to stakers…") up next to the swap where the fee is paid.
17. Slippage presets (0.5–10%) are exposed by default. Keep them, behind
    "advanced". The ticket guard already protects the thing people care about.
18. Post-detonation copy: "round N is flat — redeem your psp from the graveyard"
    → "round N is over — collect winnings and redeem PSP in the graveyard".
19. RPC failure surfaces as a small orange line at the very bottom while the clock
    band shows `88:88:88 loading`. Put the connectivity state in the band.

### D. Stake page (`/stake`)
20. Page opens with "lePSP position(s)" and "choose your accomplice" before the
    reader knows why they would stake. Lead with the payoff in one line: "lock PSP
    → earn 60% of every trade's fee, pro-rata, paid in mixETH, claim any time.
    leaving takes a 28-day cooldown unless the round ends first."
21. "six-epoch exit", "0 = pepe only", "hatch" are internal nouns. Keep "hatch" as
    flavor with a gloss ("mint the NFT with nothing in it").
22. Referral copy says "share 5% of trading fees" — correct but easy to read as 5%
    of volume. Say "5% of the fee (about 0.1–0.5% of what they trade)".
23. The `.wei` name registration card is a full section on first visit. Collapse
    it to one line with a disclosure; it is a nice-to-have for a returning user.
24. "stream share … of the 60%" → "your share of staker fees".

### E. Predeposit page (`/predeposit`)
25. Visual system mismatch: this page still uses `text-slate-*`, `bg-sky-50`,
    white cards with shadows and a pastel gradient button (all banned in spec §10)
    while every other page runs on the redesign tokens. It reads as a different
    product. At 1280px the left column is empty when the picker is absent.
26. The page says "join the pooled first buy" but not what the user gets and why
    it is fair: "everyone in the opening buy pays the same price, nobody can
    front-run it, your share arrives already staked as lePSP the moment the round
    launches, and 10% of the pool seeds the prize pot." That last fact will
    surprise people if it is not said.

### F. Graveyard (`/graveyard`)
27. "backing per PSP: 5.67e-5 mix / psp" — scientific notation for the one
    number a returning holder needs. Format as 0.0000567.
28. Otherwise the clearest page in the app; the one-transaction exit line is
    exactly the right shape ("claim X · unlock Y · convert P → Z").

### G. Habit loop (why someone comes back)
29. The revisit hooks exist (phase colour, odometer, tape) but they are ambient.
    The personal strip (#14) is the missing active hook. Two cheap additions on
    top of it: an opt-in browser notification at critical phase ("tell me under 5
    minutes"), and a share line for the seat holder ("I'm #1 on the ladder for X
    mixETH — 00:41:12 left") reusing `ReferralShare`.
30. Default to the dark theme on first visit. The spec's whole thesis is the
    arcade screen; the light theme is the system default in a fresh browser and
    it is the weaker first impression.

## What shipped (2026-09-18, commits c52fd191 → 4905a0ca on this branch)

All five phases of the prompt below were implemented, except the carpet-bomb
headline, which stays by decision. Gate after every phase: 211 frontend tests,
`tsc -b`, `vite build`. No new RPC reads, no cadence changes, transaction paths
untouched, `alt/` UI untouched.

- **Phase 1** — canon vocabulary across pages (ticket / seat / opening buy / over /
  prize pot / backing / cooldown; lePSP glossed); clock band gained the zero
  gloss, the phase word, a USD estimate on the pot and an in-band
  "reconnecting" state; ladder copy now uses the live ticket price (the
  hardcoded 0.005 is gone) and explains the seats once; fee line sits under the
  swap; header clock shows state words; no scientific notation anywhere.
- **Phase 2** — the swap card leads with the move: tickets · seat · +time on the
  clock (cap-aware, same arithmetic as the hook) · payout if it ends now; slippage
  lives behind "advanced".
- **Phase 3** — `YourSeats` strip for connected wallets (seats held, payout if it
  ends now, tickets until bumped, post-to-X) and `NotifyToggle` (opt-in browser
  notification under five minutes, one-second listener, re-arms after a buy
  pushes the clock back).
- **Phase 4** — landing teaches the loop first: loop sentence under the hero, two
  CTAs, loop-first single-column beats, five plain rules, ticket cost on the
  payout slider, exact rules after.
- **Phase 5** — predeposit page on the redesign tokens with a "what you get" card
  and the 10% pot-seed fact; stake payoff line and canon words; .wei card
  collapsed; referral fee framing; dark theme on first visit.

Verification caveat: headless screenshots ran without a wallet and with the
public RPC partially unreachable, so the connected-wallet strip, the move block
with a live ticket price and the notification were verified by type-check,
tests and code review rather than on screen. Check them on the next testnet
round with a real wallet.

## What not to touch
- PhaseEngine as the one rAF loop, HashRouter with `?ref=` capture, no invented
  chain reads, ABI shapes from `CLOCK-REDESIGN.md` §6 (red lines).
- Every existing read cadence (4s round, 6s board, per-block tape).
- The transaction flows (approvals bundling, ticket guard, fresh min-out).

---

# Implementation prompt

Copy from here to the end into a fresh Claude Code session on branch
`single-sine-fable-pass`.

```
You are improving the PSP frontend (frontend/, React 19 + wagmi + Tailwind 4) for
first-time comprehension and daily revisit. Read frontend/UX-ASSESSMENT-2026-09-18.md
first; it is the brief. Then read REDESIGN-SPEC.md (tokens, motion, banned list)
and CLOCK-REDESIGN.md §6 (frontend red lines). Work on branch
single-sine-fable-pass, one PR-sized commit per numbered phase below, and run
`npm test && npx tsc -b && npx vite build` (211 tests must stay green) before
each commit. Do not add chain reads that do not already exist in useRound,
useLadderBoard, useTradeTape or useDeadRound; do not change any polling cadence;
do not touch the transaction paths (SwapCard.run, useConfirmedWrite, approvals,
ticket guard). Keep the lowercase deadpan voice. No emoji, no gradients, no
soft shadows, no scroll-triggered motion.

Phase 1 — vocabulary and copy (no layout changes).
1. Apply the canon table from the assessment across src/pages and src/components:
   ticket (never spot/unit), seat #n, carpet bombing kept as the meme,
   over/settled (never flat in UI copy), opening buy (never IBCO in UI copy),
   prize pot / backing (never total pot / curve reserves), cooldown (never
   six-epoch exit). lePSP stays but the first use on every page reads
   "lePSP (locked PSP that earns fees)". Grep for each banned word and fix every
   user-visible string; leave code identifiers and comments alone.
2. ClockPanel headline stays ("{name} is carpet bombing for {prize} mixETH in:").
   Add one line under the pot: "at zero: trading stops · the last 10 buyers split the pot · every PSP
   redeems for its backing." Add the phase word (calm / heating up / critical)
   beside the full clock, driven by usePhase().
3. PotBoard: replace the hardcoded "each 0.005 mixETH purchased earns one
   ticket" with the live round.ticketPrice ("a ticket costs {ticketPrice} mixETH
   right now"); explain the ladder once above the list; empty rows read
   "#n · N% · —". Verify no truncation at 390px.
4. Trade page: post-round banner "round N is over — collect winnings and redeem
   PSP in the graveyard". Move the fee line from under the chart to directly
   under the swap card. Landing: move the "new deployment rules" line to the
   footer. Graveyard: format backing-per-PSP with fmtPrice-style decimals, never
   scientific notation.

Phase 2 — the swap card speaks in moves.
5. In SwapCard (buy side, Active mode), render a consequence block above the
   submit button using existing values (round.ticketPrice, quotedTicketPrice,
   purchaseUnits, TIME_PER_UNIT, round.detonationAt, round.detWindow, the board
   prop, board.pot): "this buy → {n} tickets · seat #1 · +{m:ss} on the clock ·
   pays {pct}% ({amount} mixETH) if it ends now". Time added must respect the
   detWindow cap exactly as the contract does. Show "1 ticket minimum =
   {ticketPrice} mixETH" when the amount is below the minimum. Keep the existing
   small print but shorten it to one sentence.
6. Move slippage presets and custom input behind a collapsed "advanced" row
   (default 1%). The fresh-quote and ticket-guard logic is unchanged.

Phase 3 — the personal strip (the revisit hook).
7. On /play, when a wallet is connected and the round is Active, render a strip
   between the tape and the swap/ladder grid: "you hold seat #{k} · pays {pct}% =
   {amount} mixETH if it ends now · {t} more tickets bump you off" (t = the
   number of new tickets that would push your oldest seat past #10; if you hold
   several seats, sum payouts and use your oldest seat). When the wallet holds
   no seat: "you're not on the ladder · 1 ticket ({ticketPrice} mixETH) takes
   seat #1". Data comes only from useLadderBoard and useAccount.
8. Add a share button on that strip that reuses ReferralShare with the text
   "i'm #{k} on the ladder for {amount} mixETH · {hh:mm:ss} left" and the
   wallet's referral link when it has one.
9. Add an opt-in browser notification at the critical phase: a small
   "notify me under 5 minutes" toggle in the clock band; on grant, PhaseEngine
   emits once when remaining crosses 5:00 (one new subscriber, no new loop).
   Respect prefers-reduced-motion and denied permissions silently.

Phase 4 — landing rewrite for the loop.
10. Hero: keep "the anti memecoin, memecoin." as the display line; the first
    sentence under it becomes the loop: "every buy takes a ticket and resets the
    clock. when it hits zero, the last ten buyers split the pot. then every PSP
    redeems for its backing." Keep the grievance copy after it. Two CTAs:
    "buy psp" (accent) and "how it works · 30 seconds" (anchor to the beats).
11. Reorder the beats into the loop order and mark the core four: opening buy →
    buy a ticket (clock + ladder) → stake to earn → detonate and claim; then the
    four peripheral beats (curve, NFT, yield, respawn) under a "the rest of the
    machine" subhead. Single column on every width so reading order is
    unambiguous.
12. Promote PayoutSlider above the rules table and add the ticket cost next to
    the pot ("a ticket costs {pot/10000} mixETH · seat #1 pays {pot*0.25}"),
    computed client-side. Precede the rules table with a five-line plain summary
    (buy in, clock, zero, payouts, cash out); keep the exact table beneath a
    "the exact rules" disclosure, open by default on desktop.
13. Header mini-clock: replace "loading" with a state word from useRound: "no
    live round", "opening buy open", "settled", "connecting…"; on RPC error show
    "reconnecting…" in the clock band instead of only the footer line.

Phase 5 — predeposit and stake alignment.
14. Restyle Predeposit.tsx onto the redesign tokens (bg-bg-1, border-line,
    text-text-hi/lo, st-btn / btn classes used elsewhere). Remove slate/sky
    classes, shadows and the gradient button. Fill the empty desktop column when
    the picker is absent. Add the fairness paragraph from the assessment (#26),
    including the 10% pot seed.
15. Stake page: add the one-line payoff at the top of IdentityPanel; replace
    "stream share … of the 60%" with "your share of staker fees"; gloss "hatch";
    collapse NameRegistrationCard behind a one-line disclosure; referral copy
    "5% of the fee (about 0.1–0.5% of what they trade)".
16. Default the theme to dark on first visit (ThemeProvider: when no saved
    preference, resolve dark); the switcher still honours a saved choice.

Acceptance for every phase: npm test, tsc and vite build green; screenshots at
1280 and 390 of /, /play (no wallet and with a wallet holding a seat), /stake,
/predeposit, /graveyard attached to the commit message or a qa/ note; no new RPC
reads; grep for the banned words returns no user-visible hits; the six red lines
in CLOCK-REDESIGN.md §6 are untouched.
```
