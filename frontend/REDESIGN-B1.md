# REDESIGN PHASE 1 — explainer page + shared chrome

Read first: REDESIGN-SPEC.md (§6 explainer, §7 chrome, §8 states, §10 banned),
REDESIGN-INVENTORY.md, and study the Phase 0 output (tokens.css, PhaseEngine,
Clock, primitives) — you are the first consumer; establish the page patterns.

Working dir: ~/clawd/positive-sum-pepes/frontend. You OWN: the explainer
page tree, the app header/nav/footer chrome. You may NOT touch: play/stake
page trees, data hooks, tailwind config (if you need a token, print a
request comment in your final output instead).

Explainer — kill the card wall, build the narrative:
1. HERO: display-size GeistPixel headline "a bomb, a clock, and a pot that
   only grows" (clamp ~64–96px desktop, tight leading) on bg-0; the REAL
   Clock embedded live (miniature scale via its size prop) — first thing a
   visitor sees is the countdown running; ONE greeter pepe beside it
   (PepeChip-style render, pixelated, integer scaling); ONE CTA "buy psp"
   in the phase accent. Keep the existing FOMO3D-lineage subhead copy
   verbatim (rug already removed). Keep current mainnet/testnet copy as-is
   (drift decision is scoopy's, not ours — flag it in output, don't fix).
2. "one round, five beats" — stepped timeline: arm (72:00:00) → buy
   (+5:00 per whole psp, ticket enters ladder) → climb (fees 60/35/5, pot
   grows) → detonate (anyone pushes) → claim or redeem (pull-based claims
   forever; redemption always available). Each beat: one sentence of
   existing copy + a small animated diagram (CSS only; e.g. buy beat =
   ticket sliding onto a mini ladder; reduced-motion → static frames).
3. "the math, straight" — quiet definition table on bg-1 (ladder
   25/18/14/10/8/7/6/5/4/3, renormalization, bonding curve, fee routing;
   keep contract-mirroring claims verbatim per inventory §5) + interactive
   slider: "if the bomb dropped now with a pot of X" → per-position
   payout. Pure client math.
4. "no rug, ever" — full-width closing statement at display scale: worst
   case you redeem, best case you win the pot. Then the sign-off footer
   line: "the game that pays you to stay."
5. CHROME (you own it): nav = explainer/play/stake, active pill takes the
   PHASE accent (not fixed mint); mini seven-segment countdown chip in
   header on non-play routes (click → play); Connect = quiet outlined
   button, connected = PepeChip identity. Footer = tagline + contract
   address + round number + "made of pixels and math". Scanline overlay
   mounted on the app root (dark theme only).

Verify: npm run build green; app still routes; no data-layer edits.
Print: files changed, the token requests (if any), the mainnet/testnet
copy-drift flag, and build status.
