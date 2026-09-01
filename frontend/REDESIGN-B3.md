# REDESIGN PHASE 2b — stake page: the den ("your pepe works here")

Read first: REDESIGN-SPEC.md (§6 stake, §8 states, §10), REDESIGN-INVENTORY.md,
and study Phase 0 + Phase 1 output (primitives, patterns).

Working dir: ~/clawd/positive-sum-pepes/frontend. You OWN: the stake page
tree only. You may NOT touch: explainer/play trees, chrome, data hooks,
stake form submit logic, pepeRender.ts/pepeArt.json, tailwind config
(print requests instead).

1. IDENTITY PANEL (lead, large): the user's pepe rendered big (pixelated,
   integer scale) or the random preview when disconnected; name/.wei;
   beneath: staked amount, share of the 60% stream, and FEES EARNED THIS
   ROUND as a live-ticking accumulator (derive per-block/4s cadence from
   existing data; smooth-interpolate between updates — this counter is the
   page's emotional core and the strongest revisit reason; build it well).
2. PEPE PICKER: compact horizontal strip under the identity panel with the
   refresh/roll action — not a 2×3 grid. Keep local-roll behavior exactly.
3. STAKE FORM below, function unchanged; keep the "0.0 — or nothing, just
   the pepe" placeholder verbatim.
4. RIGHT COLUMN: referrals card (link generator + plain statement of the
   0.5% mechanic; empty state: "connect a wallet and your link pays you
   0.5% of every trade it brings.") → .wei registry notice restyled as a
   proper info banner → ROUND HISTORY "hall of detonations": list of past
   detonations (pot size, winner pepes, your result) from existing round
   data / local record; designed empty state if no rounds have fired yet
   ("no detonations yet — the first archive seat is open.").
5. Bottom stat cards fold into the same TickerBar component as play.
6. Kill the right-column void: the hall fills it with mythology.

Verify: npm run build green. Print: files changed, token requests,
build status.
