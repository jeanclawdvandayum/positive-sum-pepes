// ─────────────────────────────────────────────────────────────────────────────
// ScanlineOverlay — 2–3% CRT scanlines (REDESIGN-B0 item 6, spec §9).
// Fixed, pointer-transparent, pure CSS (tokens.css). Gated there to
// dark-theme-only and killed under prefers-reduced-motion: mounted but
// inert until the page phases adopt the dark skin.
// ─────────────────────────────────────────────────────────────────────────────

export default function ScanlineOverlay() {
  return <div className="scanlines" aria-hidden="true" />
}
