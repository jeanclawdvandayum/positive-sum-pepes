# REDESIGN PHASE 2a — play page: the command center

Read first: REDESIGN-SPEC.md (§6 play, §8 states, §10), REDESIGN-INVENTORY.md,
and study Phase 0 + Phase 1 output (Clock, PotOdometer, TickerBar, patterns
established on the explainer page).

Working dir: ~/clawd/positive-sum-pepes/frontend. You OWN: the play page
tree only. You may NOT touch: explainer/stake trees, header/footer chrome,
data hooks (useRound/useRpcReads/StatsPanel cadences), SwapCard quote/submit
logic, CurveChart scale math, tailwind config (print requests instead).

1. CLOCK PANEL full-bleed at top: Clock (Phase 0) dominant; the POT moves
   INSIDE the panel as PotOdometer in pot-gold directly beneath the
   numerals — one instrument ("time left / money waiting"). Kill the
   floating "CURRENT POT" box + its dead space. Under the pot one thin
   live-context line: "last time added by [pepe] · Xm ago" (derive from
   existing round data; placeholder state per §8 if unavailable).
2. LAYOUT: swap panel left / pot board right (as now) + NEW live tape:
   slim activity feed under the clock — one-line entries with pepe
   avatars for buys, sells, time injections, stake events. Feed from
   existing poll data (getLogs lane in StatsPanel inventory) — do NOT add
   new chain calls; if the lane gives nothing yet, render the designed
   empty state (§8 voice) not a spinner.
3. POT BOARD hierarchy: #1 visibly larger w/ gold left edge; percentages
   as filled bars behind rows (accent-tinted, pot-gold reserved for #1);
   each row shows live payout in mixETH if detonation happened this
   second (existing math, just surfaced); every row renders the holder's
   ACTUAL pepe (on-chain SVG lane). Ladder-shift animation on new #1
   (slide-in, spring down, #10 tumble; reduced-motion → instant).
   Empty seats: sleeping pepe + "this seat pays 25% — nobody's sitting
   in it."
4. SWAP: keep function/quotes/slippage logic EXACTLY. Restyle to tokens;
   confirm button fills with accent while pending; success → 4–6 pixel
   particles from the BUY button (400ms, once; reduced-motion → none).
   Wire buy success → PhaseEngine.injectTime so the clock jumps +5:00.
5. CURVE: phase-accent stroke, soft glow on current-price point, user
   entry price marked when connected (existing data). Empty state:
   dotted ghost theoretical curve + "no trades yet — the first buy draws
   this for real."
6. BOTTOM STATS: volume / fees to stakers / reserves / price fold into
   the continuous TickerBar (Phase 0 primitive) instead of four cards.

Verify: npm run build green. Print: files changed, token requests,
build status.
