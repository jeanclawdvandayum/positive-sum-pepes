# PSP REDESIGN SPEC v1 — "a machine with a heartbeat"

Source of truth: scoopy's redesign brief (2026-08-31). This document is the
implementation contract. Where the brief and this spec disagree, the brief wins.

## 0. Thesis
Dark-first arcade terminal. Discipline everywhere so the clock can be loud.
The app FEELS the clock: one system — color temperature bound to time
remaining — makes the app alive and gives returning visitors a reason to
check in. Tension (armed machine) + safety ("no rug, ever") is the product.

## 1. Tokens (dark, primary) — swap at :root, single source
```
--bg-0:#0b1424; --bg-1:#101c30; --bg-2:#16253d; --line:#22344f;
--text-hi:#e8f0f7; --text-lo:#8ba3bd;
--phase-calm:#3ddc97; --phase-heat:#ffb347; --phase-critical:#ff4d5e;
--pot-gold:#ffd75e;   /* pot number + pot wins ONLY. never decorative */
--pepe:#58c470;       /* pepe-adjacent UI only */
--accent: <phase color>;  /* THE variable: buttons, focus rings, clock glow,
                             board highlight, link hovers, active nav pill */
```
- No gradients on surfaces/buttons. The ONLY permitted gradient: subtle
  radial phosphor glow behind clock numerals.
- Hairline 1px borders (--line), no soft drop shadows on panels.
- Light theme = same tokens inverted on paper-white, phase system intact,
  clock panel stays dark in both themes (it's the machine's screen).

## 2. Phase engine (the frission core)
- CALM  (>12h):  --accent = --phase-calm.  Glow breathes slow.
- HEAT  (12h–1h): --accent = --phase-heat. Breath rate up slightly.
- CRITICAL (<1h): --accent = --phase-critical. Glow pulses 1×/second, softly.
- Sub-10min: pot number + clock get breathing scale 1.00→1.015 (slow);
  document.title = live countdown.
- Phase also shown as a WORD ("calm / heating / critical") — meaning never
  rides on color alone (WCAG).
- One `PhaseEngine` module owns: remaining-time → phase class on <html>
  (`data-phase="calm|heat|critical"` + `data-sub10`), tab title, and the
  single rAF clock loop. No per-second page re-renders.

## 3. Typography — three roles, never mixed
- DISPLAY: chunky pixel face (Silkscreen), big. Explainer headline
  clamp(64px, 8vw, 96px), tight leading. The visual event of the page.
- NUMERALS: DSEG7 for the countdown ONLY. Tabular mono (IBM Plex Mono,
  font-variant-numeric: tabular-nums) for pot odometer + all live data.
  Numbers never reflow.
- BODY/UI: Inter or IBM Plex Sans, 15–16px / 1.6 / max ~70ch.
  Body copy in pixel fonts is BANNED.
- Keep the lowercase deadpan voice everywhere ("hit zero and trading halts.").

## 4. Motion — ambient motion belongs to the clock ALONE
Everything else moves only in response to data or user. No scroll entrances,
no hover-lift on every card. The five sanctioned moves:
1. HEARTBEAT: clock phosphor glow breathing (phase-scaled rate). The ONE
   ambient animation.
2. ODOMETER: pot digits roll mechanically + brief gold flash on changed
   digits. The pot must visibly grow.
3. TIME INJECTION: whole-PSP buy → clock visibly jumps +5:00, added minutes
   flash in accent, small "+5:00" chip floats off the clock. Feeding the machine.
4. LADDER SHIFT: new ticket → row slides in at #1, others spring down one
   slot, #10 tumbles out.
5. DETONATION set-piece: screen dims, clock slams 00:00:00 with hard glow
   burst, ladder locks + stamps final %payouts, "round archived" card
   assembles. Screenshot-worthy.
Micro: buttons depress 1px; swap confirm fills with accent while pending;
successful buys emit 4–6 pixel particles from BUY (400ms, once).
`prefers-reduced-motion`: all of the above → instant state changes + color
flashes only. No breathing, particles, rolls, tumbles.

## 5. Pepes
- Connected user's pepe = identity chip in header (replaces wallet blob).
- Pot board renders each holder's ACTUAL pepe.
- Empty states use pepes as characters (sleeping pepe, zzz overlay).
- Explainer: ONE large greeter pepe beside hero. Nothing else decorative.
- Crisp: image-rendering: pixelated; integer multiples of source resolution.

## 6. Pages
### Explainer — narrative, not card wall
Hero: huge pixel headline "a bomb, a clock, and a pot that only grows" +
LIVE miniature of the real clock embedded + one greeter pepe + ONE CTA
("buy PSP") in phase accent. Subhead keeps FOMO3D one-liner, rug removed.
"one round, five beats": stepped timeline arm→buy→climb→detonate→claim,
each beat = one sentence of existing copy + small animated diagram
(e.g. ticket sliding onto mini ladder).
"the math, straight": quiet definition table on --bg-1 (ladder %, curve,
fee routing, renormalization) + interactive "if the bomb dropped now"
pot→payout slider per ladder position.
"no rug, ever": full-width display-size closing statement. Then sign-off:
"the game that pays you to stay."
### Play — command center
Clock panel full-bleed; POT as gold odometer INSIDE the panel under the
numerals (one instrument: time left / money waiting). Kill floating pot
box + dead space. Under pot: "last time added by [pepe] · 2m ago".
Swap left / pot board right + NEW live tape under clock streaming buys,
sells, injections, stake events as one-liners with pepe avatars.
Board rows: #1 visibly larger with gold left edge; % as filled bars behind
rows; live mixETH payout-if-now shown prominently.
Curve: phase accent, glow on current price, user entry marked when connected.
Stat strip (volume/fees/reserves/price) = one continuous ticker bar.
### Stake — the den ("your pepe works here")
Lead panel: user's pepe large + name/.wei + staked, share of 60% stream,
fees-earned accumulator TICKING live (the strongest revisit reason — build it).
Pepe picker = compact horizontal strip w/ refresh (not 2×3 grid).
Stake form below, unchanged function; keep "0.0 — or nothing, just the pepe".
Right col: referrals card (0.5% mechanic stated plainly) → .wei registry
info banner → round history "hall of detonations" (pot size, winner pepes,
your result). Stats fold into the same ticker bar as play.

## 7. Header / nav / footer
- Active nav pill takes PHASE accent.
- Off-play pages: mini seven-segment countdown chip in header (phase color),
  click → play.
- Connect = quiet outlined button; connected = pepe identity chip.
- Footer: tagline + contract address + round number + "made of pixels and math".

## 8. States & liveness (no dashes, ever)
- Pre-launch: 72:00:00 dimmed + "armed the moment the round launches."
- Empty board seat: sleeping pepe + "this seat pays 25% — nobody's sitting in it."
- Empty curve: dotted ghost theoretical curve + "no trades yet — the first
  buy draws this for real."
- Empty referrals: "connect a wallet and your link pays you 0.5% of every
  trade it brings."
- Errors: state what failed + the action ("transaction reverted — slippage
  too tight. raise it and retry."). Never bare "something went wrong".
- Loading: skeleton shimmer in --bg-2. Never an em dash.

## 9. Quality floor (gate before any merge)
- [ ] 360px: clock scales, never wraps; swap/board stack; rows compress to
      avatar + rank + % + payout.
- [ ] WCAG AA on --bg-0/1; phase word label present.
- [ ] prefers-reduced-motion honored everywhere (§4).
- [ ] Keyboard: visible phase-accent focus rings; swap flow fully operable.
- [ ] Scanline overlay + glows pure CSS; pepe sprites small PNGs; ONE rAF
      loop for clock.
- [ ] Scanline/grain 2–3% opacity — imperceptible in screenshots; disabled
      under reduced-motion + light theme.

## 10. Banned
Identical rounded cards w/ soft grey shadows. Decorative gradients.
Scroll-triggered entrances. All-caps tracked labels above headings.
Softening the game. Body copy in pixel fonts. Emoji (standing rule — pixel
markers only).
