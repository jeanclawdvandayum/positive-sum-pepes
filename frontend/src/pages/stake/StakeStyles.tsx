// ─────────────────────────────────────────────────────────────────────────────
// Stake page scoped styles (REDESIGN-B3). Follows the explainer's DiagramStyles
// pattern: every rule is prefixed st- and scoped under .st-page, so the shared
// tokens.css / index.css (tailwind "config" territory) stay untouched.
// Reduced-motion: the only ambient motion here is the hall's zzz float —
// everything else is data movement, which keeps ticking.
// ─────────────────────────────────────────────────────────────────────────────

export default function StakeStyles() {
  return (
    <style>{`
/* phase-accent focus rings for every interactive on the page (spec §9) */
.st-page :is(a, button, input, select):focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

/* amount input — the old .input-amount lives in shared css; this is ours */
.st-input {
  width: 100%;
  background: var(--bg-2);
  border: 1px solid var(--line);
  border-radius: 0.75rem;
  padding: 0.7rem 0.9rem;
  color: var(--text-hi);
  font-family: var(--font-data);
  font-variant-numeric: tabular-nums;
  font-size: 1.05rem;
  outline: none;
  transition: border-color 0.15s;
}
.st-input:focus { border-color: var(--accent); }
.st-input::placeholder { color: var(--text-lo); opacity: 0.65; }

/* select (referral pepe picker) */
.st-select {
  width: 100%;
  background: var(--bg-2);
  border: 1px solid var(--line);
  border-radius: 0.75rem;
  padding: 0.55rem 0.8rem;
  color: var(--text-hi);
  font-family: var(--font-data);
  font-size: 0.85rem;
  outline: none;
  transition: border-color 0.15s;
}
.st-select:focus { border-color: var(--accent); }
.st-select option { background: var(--bg-1); color: var(--text-hi); }

/* button system — hairline ghost + solid accent primary (spec §1/§4 micro) */
.st-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 0.5rem;
  border-radius: 0.75rem;
  border: 1px solid var(--line);
  padding: 0.6rem 0.95rem;
  color: var(--text-hi);
  background: transparent;
  font-size: 0.9rem;
  transition: background 0.15s, border-color 0.15s;
}
.st-btn:hover:not(:disabled) { background: var(--bg-2); border-color: var(--text-lo); }
.st-btn:active:not(:disabled) { transform: translateY(1px); }
.st-btn:disabled { opacity: 0.45; cursor: not-allowed; }
.st-btn-primary {
  border-color: var(--accent);
  background: var(--accent);
  color: var(--bg-0);
  font-weight: 600;
}
.st-btn-primary:hover:not(:disabled) {
  background: var(--accent);
  filter: brightness(1.1);
}

/* the fee accumulator — the page's emotional core (B3 item 1).
   pepe green (NOT pot-gold: gold is the pot + pot wins only, spec §1),
   tabular data face so the ticking never reflows. */
.st-accum {
  font-family: var(--font-data);
  font-variant-numeric: tabular-nums;
  color: var(--pepe);
  line-height: 1;
  letter-spacing: -0.01em;
}

/* referral link box */
.st-linkbox {
  font-family: var(--font-data);
  font-size: 0.72rem;
  line-height: 1.5;
  color: var(--text-lo);
  background: var(--bg-2);
  border: 1px solid var(--line);
  border-radius: 0.6rem;
  padding: 0.6rem 0.7rem;
  word-break: break-all;
}

/* hall of detonations — sleeping pepe zzz (the one ambient move, reduced-motion safe) */
.st-zzz {
  position: absolute;
  top: 0.2rem;
  right: 1.1rem;
  font-family: var(--font-data);
  color: var(--text-lo);
  line-height: 1;
  pointer-events: none;
}
.st-zzz span { display: inline-block; animation: st-zzz-float 3.4s ease-in-out infinite; }
.st-zzz span:nth-child(2) { animation-delay: 0.7s; font-size: 1.25em; }
.st-zzz span:nth-child(3) { animation-delay: 1.4s; font-size: 1.55em; }
@keyframes st-zzz-float {
  0%, 100% { transform: translateY(0); opacity: 0.3; }
  50% { transform: translateY(-5px); opacity: 0.85; }
}
@media (prefers-reduced-motion: reduce) {
  .st-zzz span { animation: none !important; opacity: 0.6; }
}
`}</style>
  )
}
