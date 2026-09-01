// ─────────────────────────────────────────────────────────────────────────────
// PlayStyles — scoped CSS for the play page tree (REDESIGN-B2).
//
// Same pattern as explainer/diagrams.tsx: every rule prefixed pl- and scoped
// to .pl-page; no shared-file edits (token requests go to the phase log, not
// into tokens.css). Base styles ARE the static frame; keyframes settle INTO
// base so prefers-reduced-motion (animation:none) leaves correct stills.
// No ambient motion outside the clock (spec §4) — everything here fires on
// data or user events only.
// ─────────────────────────────────────────────────────────────────────────────

export function PlayStyles() {
  return (
    <style>{`
/* phase-accent focus rings for play interactives (spec §9 keyboard) */
.pl-page :is(a, button, input):focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

/* ── clock band (B2 §1) — dark in BOTH themes: the machine's screen ─────── */
.pl-clockband {
  background: #0b1424;
  border-bottom: 1px solid #22344f;
}
/* the pot odometer lives on the dark screen → ride the luminous constants,
   not the paper-theme remap (same rule as the clock numerals) */
.pl-clockband .odo {
  color: var(--lum-gold);
}
.pl-clockband .odo-unit {
  color: rgba(232, 240, 247, 0.55);
}
.pl-context {
  color: #8ba3bd;
  letter-spacing: 0.02em;
}

/* ── live tape (B2 §2) ────────────────────────────────────────────────────── */
.pl-tape-row {
  animation: pl-in 0.3s ease-out; /* new log = data event, not ambient */
}
.pl-dot {
  width: 5px;
  height: 5px;
  flex: none;
  background: var(--text-lo);
}
.pl-dot--buy {
  background: var(--accent);
}
@keyframes pl-in {
  from { opacity: 0; transform: translateY(-4px); }
  to { opacity: 1; transform: none; }
}

/* ── pot board (B2 §3) — ladder seats with payout bars behind rows ───────── */
.pl-seat {
  position: relative;
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: 0.5rem;
}
.pl-seat--top {
  border-left: 3px solid var(--pot-gold); /* pot-gold reserved for #1 (§1) */
}
.pl-seat-bar {
  position: absolute;
  inset-block: 0;
  left: 0;
  background: color-mix(in srgb, var(--accent) 14%, transparent);
  border-right: 1px solid color-mix(in srgb, var(--accent) 30%, transparent);
}
.pl-seat--top .pl-seat-bar {
  background: color-mix(in srgb, var(--pot-gold) 16%, transparent);
  border-right-color: color-mix(in srgb, var(--pot-gold) 38%, transparent);
}
.pl-seat--empty .pl-seat-bar {
  opacity: 0.5; /* the ladder shape shows; nobody's claiming it */
}
.pl-seat-inner {
  position: relative;
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.45rem 0.75rem;
}
.pl-seat--top .pl-seat-inner {
  padding: 0.8rem 0.9rem;
}
.pl-pepe {
  display: block;
  overflow: hidden;
  border-radius: 0.35rem;
  border: 1px solid var(--line);
}
.pl-pepe > svg {
  width: 100%;
  height: 100%;
}
.pl-pepe--sleep {
  opacity: 0.55;
  filter: saturate(0.8);
}
.pl-zzz {
  position: absolute;
  top: -5px;
  right: -10px;
  font-family: var(--font-data);
  font-size: 9px;
  color: var(--text-lo);
  letter-spacing: 0.08em;
}

/* ladder shift (spec §4.4) — dormant until the ticket lane lands: the new
   #1 mounts with .pl-enter (slide in + spring settle), the evicted #10 gets
   .pl-evict before removal. Data-driven only; reduced-motion → instant. */
.pl-enter {
  animation: pl-slide-in 0.5s cubic-bezier(0.2, 0.85, 0.3, 1.15);
}
@keyframes pl-slide-in {
  from { transform: translateY(-70%); opacity: 0; }
  to { transform: none; opacity: 1; }
}
.pl-evict {
  animation: pl-tumble 0.45s ease-in forwards;
}
@keyframes pl-tumble {
  to { transform: translateY(60%) rotate(6deg); opacity: 0; }
}

/* ── swap confirm: fills with accent while pending (B2 §4, spec §4 micro) ── */
.pl-btn-fill {
  position: absolute;
  inset: 0;
  background: #fff;
  opacity: 0.16;
  transform: scaleX(0);
  transform-origin: left;
  pointer-events: none;
}
[data-pending] .pl-btn-fill {
  animation: pl-fill 2.6s ease-out infinite;
}
@keyframes pl-fill {
  from { transform: scaleX(0); }
  to { transform: scaleX(1); }
}

/* ── buy particles (B2 §4, spec §4 micro): 4–6 pixels, 400ms, once ──────── */
.pl-burst {
  position: absolute;
  left: 50%;
  top: 8px;
  width: 0;
  height: 0;
  pointer-events: none;
  z-index: 5;
}
.pl-burst-px {
  position: absolute;
  width: 4px;
  height: 4px;
  background: var(--accent);
  animation: pl-pop 0.4s ease-out forwards;
}
@keyframes pl-pop {
  from { transform: translate(0, 0); opacity: 1; }
  to { transform: translate(var(--dx), var(--dy)); opacity: 0; }
}

/* ── reduced motion (spec §4/§9): instant states + color flashes only ────── */
@media (prefers-reduced-motion: reduce) {
  .pl-tape-row,
  .pl-enter,
  .pl-evict,
  .pl-burst-px {
    animation: none !important;
  }
  .pl-burst-px {
    display: none;
  }
  [data-pending] .pl-btn-fill {
    animation: none !important;
    transform: scaleX(1);
    opacity: 0.1;
  }
}
`}</style>
  )
}
