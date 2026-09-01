// ─────────────────────────────────────────────────────────────────────────────
// Explainer beat diagrams — "one round, five beats" (REDESIGN-B1 §2, spec §4)
//
// CSS-only animated diagrams, one per beat. Every rule is prefixed xd- and
// scoped to this page tree (no shared-file edits). Base styles ARE the static
// frame; keyframes start from offsets and settle INTO base, so
// prefers-reduced-motion (animation: none) leaves a correct still frame.
// No scroll-triggered anything (§10); loops are ambient illustration inside
// the diagram stages only.
// ─────────────────────────────────────────────────────────────────────────────

import type { CSSProperties } from 'react'

export function DiagramStyles() {
  return (
    <style>{`
.xd-stage {
  position: relative;
  flex: none;
  width: 10rem;
  height: 7rem;
  border: 1px solid var(--line);
  border-radius: 0.6rem;
  background: var(--bg-1);
  overflow: hidden;
}
.xd-note {
  position: absolute;
  font-family: var(--font-data);
  font-size: 0.6rem;
  /* audit r1 fix 3: contrast up two steps (text-lo → text-hi) — the beat
     labels ("1 psp = 1 ticket") must read as drawn copy, not placeholder */
  color: var(--text-hi);
  letter-spacing: 0.02em;
}

/* phase-accent focus rings for explainer interactives (spec §9 keyboard) */
.xd-page :is(a, button, input):focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

/* ── arm: the machine's screen + a draining fuse ── */
.xd-screen {
  position: absolute;
  left: 0.9rem;
  right: 0.9rem;
  top: 1.1rem;
  height: 2.1rem;
  background: #0b1424; /* the screen stays dark in both themes, like the clock */
  border: 1px solid #22344f;
  border-radius: 0.4rem;
  display: flex;
  align-items: center;
  justify-content: center;
}
.xd-seg {
  font-family: var(--font-clock);
  font-size: 0.95rem;
  color: var(--lum-hi);
  letter-spacing: 0.05em;
}
.xd-fuse {
  position: absolute;
  left: 0.9rem;
  right: 0.9rem;
  bottom: 1rem;
  height: 0.35rem;
  border-radius: 999px;
  background: var(--bg-2);
  overflow: hidden;
}
.xd-fuse-fill {
  height: 100%;
  width: 78%;
  border-radius: 999px;
  background: var(--accent);
  animation: xd-drain 7s linear infinite;
}
@keyframes xd-drain {
  from { width: 100%; }
  to { width: 22%; }
}

/* ── buy: a ticket slides onto the mini ladder ── */
.xd-ladder {
  position: absolute;
  left: 1.1rem;
  bottom: 1.1rem;
  display: flex;
  flex-direction: column;
  gap: 0.3rem;
}
.xd-rung {
  width: 7.5rem;
  height: 0.55rem;
  /* audit r1 fix 3: ladder stroked in the live phase accent, tinted fill —
     two steps up from the old line/bg-2 placeholder read */
  border: 1px solid var(--accent);
  border-radius: 0.2rem;
  background: color-mix(in srgb, var(--accent) 12%, var(--bg-2));
}
.xd-ticket {
  position: absolute;
  left: 1.1rem;
  bottom: 2.8rem; /* resting on slot #1 (top rung) — the static frame */
  width: 2.6rem;
  height: 0.55rem;
  border-radius: 0.2rem;
  background: var(--accent);
  animation: xd-ticket-in 4.2s ease-in-out infinite;
}
@keyframes xd-ticket-in {
  0% { transform: translate(2.8rem, -1.2rem) rotate(8deg); opacity: 0; }
  16% { opacity: 1; }
  44% { transform: translate(0, 0) rotate(0deg); opacity: 1; }
  82% { transform: translate(0, 0); opacity: 1; }
  100% { transform: translate(0, -0.5rem); opacity: 0; }
}

/* ── climb: the pot fills while fees feed stakers + pot (referral = fixed 0.5% of volume, CurveHook REFERRAL_FEE_BIPS=50) ── */
.xd-jar {
  position: absolute;
  left: 1.2rem;
  bottom: 1rem;
  width: 4.2rem;
  height: 4.4rem;
  border: 1px solid var(--accent); /* audit r1 fix 3: drawn in phase accent */
  border-radius: 0.45rem 0.45rem 0.3rem 0.3rem;
  background: var(--bg-2);
  overflow: hidden;
}
.xd-jar-fill {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  height: 72%;
  background: var(--pot-gold); /* this IS the pot number's color: the pot itself */
  animation: xd-rise 6s ease-in-out infinite alternate;
}
@keyframes xd-rise {
  from { height: 14%; }
  to { height: 72%; }
}
.xd-ticks {
  position: absolute;
  right: 0.9rem;
  top: 50%;
  transform: translateY(-50%);
  display: flex;
  flex-direction: column;
  gap: 0.7rem;
}
.xd-tick {
  display: flex;
  align-items: center;
  gap: 0.35rem;
}
.xd-tick i {
  width: 0.5rem;
  height: 0.5rem;
  border-radius: 0.12rem;
}
.xd-tick span {
  font-family: var(--font-data);
  font-size: 0.62rem;
  color: var(--text-lo);
}

/* ── detonate: zero flashes, the ring bursts ── */
.xd-zero {
  position: absolute;
  left: 50%;
  top: 0.95rem;
  transform: translateX(-50%);
  font-family: var(--font-clock);
  font-size: 0.9rem;
  color: var(--lum-critical);
  animation: xd-blink 1s steps(2, jump-none) infinite;
}
@keyframes xd-blink {
  0% { opacity: 1; }
  50% { opacity: 0.25; }
  100% { opacity: 1; }
}
.xd-bomb {
  position: absolute;
  left: 50%;
  bottom: 1.5rem;
  transform: translateX(-50%);
  width: 1.15rem;
  height: 1.15rem;
  border-radius: 0.18rem;
  background: var(--lum-critical);
}
.xd-ring {
  position: absolute;
  left: 50%;
  bottom: 1.5rem;
  width: 1.15rem;
  height: 1.15rem;
  border: 1px solid var(--lum-critical);
  border-radius: 999px;
  transform: translate(-50%, 0);
  animation: xd-boom 2s ease-out infinite;
}
@keyframes xd-boom {
  from { transform: translate(-50%, 0) scale(1); opacity: 0.9; }
  to { transform: translate(-50%, 0) scale(4.2); opacity: 0; }
}

/* ── claim or redeem: pull-based, two lanes ── */
.xd-lane {
  position: absolute;
  left: 0.9rem;
  right: 0.9rem;
}
.xd-dotted {
  position: absolute;
  inset: 0;
  border-bottom: 1px dotted var(--accent); /* audit r1 fix 3 */
}
.xd-claim {
  position: absolute;
  left: 0;
  top: -0.28rem;
  width: 0.95rem;
  height: 0.55rem;
  border-radius: 0.15rem;
  background: var(--pot-gold); /* a pot win traveling to its claimer */
  animation: xd-slide-right 3.4s ease-in-out infinite;
}
@keyframes xd-slide-right {
  0% { left: 0; opacity: 0; }
  12% { opacity: 1; }
  80% { opacity: 1; }
  100% { left: calc(100% - 0.95rem); opacity: 0.9; }
}
.xd-slot {
  position: absolute;
  right: 0;
  top: -0.55rem;
  width: 0.35rem;
  height: 1.1rem;
  /* audit r1 fix 3: one contrast step up from line/bg-2 (the accent stroke
     belongs to the moving chips and rails, the slot is the receiver) */
  border: 1px solid var(--text-lo);
  border-radius: 0.1rem;
  background: color-mix(in srgb, var(--text-lo) 15%, var(--bg-2));
}
.xd-drop-lane { height: 2.6rem; }
.xd-dotted-v {
  position: absolute;
  left: 2.2rem;
  top: 0;
  bottom: 0;
  width: 0;
  border-bottom: none;
  border-left: 1px dotted var(--accent); /* audit r1 fix 3 */
}
.xd-redeem {
  position: absolute;
  left: 1.78rem;
  top: 0;
  width: 0.95rem;
  height: 0.55rem;
  border-radius: 0.15rem;
  background: var(--accent); /* redemption: always-available backing exit */
  animation: xd-drop 3.4s ease-in-out infinite;
}
@keyframes xd-drop {
  0% { top: 0; opacity: 0; }
  12% { opacity: 1; }
  80% { opacity: 1; }
  100% { top: calc(100% - 0.55rem); opacity: 0.9; }
}
.xd-slot--floor {
  right: auto;
  left: 1.55rem;
  top: auto;
  bottom: -0.62rem;
  height: 0.35rem;
  width: 1.4rem;
}

/* reduced motion: static frames only (spec §4) */
@media (prefers-reduced-motion: reduce) {
  .xd-fuse-fill,
  .xd-ticket,
  .xd-jar-fill,
  .xd-zero,
  .xd-ring,
  .xd-claim,
  .xd-redeem {
    animation: none !important;
  }
  .xd-ring {
    transform: translate(-50%, 0) scale(2);
    opacity: 0.5;
  }
}
`}</style>
  )
}

export type BeatKind = 'arm' | 'buy' | 'climb' | 'detonate' | 'claim'

export function BeatDiagram({ kind }: { kind: BeatKind }) {
  return (
    <div className="xd-stage" aria-hidden="true">
      {kind === 'arm' && (
        <>
          <div className="xd-screen">
            <span className="xd-seg">72:00:00</span>
          </div>
          <div className="xd-fuse">
            <div className="xd-fuse-fill" />
          </div>
        </>
      )}

      {kind === 'buy' && (
        <>
          <span className="xd-note" style={{ right: '0.8rem', top: '0.7rem' }}>
            1 psp = 1 ticket
          </span>
          <div className="xd-ladder">
            <div className="xd-rung" />
            <div className="xd-rung" />
            <div className="xd-rung" />
          </div>
          <div className="xd-ticket" />
        </>
      )}

      {kind === 'climb' && (
        <>
          <div className="xd-jar">
            <div className="xd-jar-fill" />
          </div>
          <div className="xd-ticks">
            <div className="xd-tick">
              <i style={{ background: 'var(--accent)' }} />
              <span>60</span>
            </div>
            <div className="xd-tick">
              <i style={{ background: 'var(--pot-gold)' }} />
              <span>35</span>
            </div>
            <div className="xd-tick">
              <i style={{ background: 'var(--text-lo)' }} />
              <span>5</span>
            </div>
          </div>
        </>
      )}

      {kind === 'detonate' && (
        <>
          <span className="xd-zero">00:00:00</span>
          <div className="xd-ring" />
          <div className="xd-bomb" />
        </>
      )}

      {kind === 'claim' && (
        <>
          <span className="xd-note" style={{ left: '0.9rem', top: '0.45rem' }}>
            claim
          </span>
          <div className="xd-lane" style={{ top: '1.35rem' } as CSSProperties}>
            <i className="xd-dotted" />
            <i className="xd-claim" />
            <i className="xd-slot" />
          </div>
          <span className="xd-note" style={{ left: '0.9rem', top: '2.6rem' }}>
            redeem
          </span>
          <div className="xd-lane xd-drop-lane" style={{ top: '3.6rem' } as CSSProperties}>
            <i className="xd-dotted-v" />
            <i className="xd-redeem" />
            <i className="xd-slot xd-slot--floor" />
          </div>
        </>
      )}
    </div>
  )
}
