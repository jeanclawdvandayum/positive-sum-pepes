// Shared primitives for the per-action FX components (PLAN Feature 3).
// Every visual node is absolutely positioned inside the fixed .fx-layer;
// animations only touch transform/opacity/filter and live in public/alt/fx.css.
// Under prefers-reduced-motion the CSS hides all motion nodes and plays the
// .fx-flash color pulse instead — components only shorten their timers.

import { useEffect, type CSSProperties, type ReactNode } from 'react'
import type { FxEvent } from '../../lib/actionFx'

export interface FxProps { event: FxEvent; onDone: () => void }

/** Queried per effect so a mid-session preference change is respected. */
export const reducedMotion = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches

export function center(rect?: DOMRect): { x: number; y: number } {
  if (!rect || (rect.width === 0 && rect.height === 0)) return { x: window.innerWidth / 2, y: window.innerHeight / 2 }
  return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 }
}

/** Selector → live rect, resolved at effect time. */
export function queryRect(selector: string): DOMRect | undefined {
  const el = document.querySelector(selector)
  return el?.isConnected ? el.getBoundingClientRect() : undefined
}

/** Full-viewport rect for page-wide washes (ignition warm, polaroid flash). */
export function viewportRect(): DOMRect {
  return { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight } as DOMRect
}

/** The clock on the play page (.alt-clock) or in the header (.mini-clock),
 *  preferring one that is on screen so a scrolled page still sees the chip. */
export function clockRect(): DOMRect | undefined {
  const rects = [queryRect('.alt-clock'), queryRect('.mini-clock')].filter((r): r is DOMRect => !!r && r.width > 0 && r.height > 0)
  return rects.find(r => r.bottom > 0 && r.top < window.innerHeight) ?? rects[0]
}

/** The pepe/position card containing (or nearest to) an anchor rect, element included. */
export function ownerCard(rect?: DOMRect): { el: Element; rect: DOMRect } | undefined {
  if (!rect) return undefined
  const x = rect.left + rect.width / 2
  const y = rect.top + rect.height / 2
  let best: { distance: number; el: Element; rect: DOMRect } | undefined
  for (const el of document.querySelectorAll('.rounded-2xl, .card')) {
    const candidate = el.getBoundingClientRect()
    if (candidate.width === 0 && candidate.height === 0) continue
    const distance = Math.hypot(candidate.left + candidate.width / 2 - x, candidate.top + candidate.height / 2 - y)
    if (!best || distance < best.distance) best = { distance, el, rect: candidate }
  }
  return best
}

/** Effects that feed a pepe card fall back to the bare anchor when no card is near. */
export function feedCard(rect?: DOMRect): { el: Element | undefined; rect: DOMRect } {
  return ownerCard(rect) ?? { el: undefined, rect: rect ?? new DOMRect() }
}

/** Timed self-removal; reduced motion shortens every effect to the flash beat. */
export function useTimedDone(onDone: () => void, ms: number): void {
  useEffect(() => {
    const timer = setTimeout(onDone, reducedMotion() ? Math.min(ms, 450) : ms)
    return () => clearTimeout(timer)
  }, [onDone, ms])
}

/** One-shot WAAPI nudge on a live page element; suppressed under reduced motion. */
export function nudge(el: Element | null | undefined, keyframes: Keyframe[], options: KeyframeAnimationOptions): void {
  if (!el || reducedMotion()) return
  try { el.animate(keyframes, options) } catch { /* engines without WAAPI simply stay still */ }
}

/**
 * Reduced-motion stand-in: invisible during normal playback (the real effect
 * plays). Under prefers-reduced-motion fx.css shows `.fx-flash-ring` — a tone
 * ring hugging the anchor rect — instead of any motion. `extra` may add a
 * normal-motion treatment.
 */
export function Flash({ at, rect, tone, extra }: { at: { x: number; y: number }; rect?: DOMRect; tone?: 'amber' | 'red'; extra?: string }) {
  const toneClass = tone ? ` fx-flash-${tone}` : ''
  const extraClass = extra ? ` ${extra}` : ''
  return <>
    <span className={`fx-flash${toneClass}${extraClass}`} style={{ left: at.x, top: at.y }} />
    <Over rect={rect} className={`fx-flash-ring${toneClass}`} />
  </>
}

/** Fixed overlay exactly covering a rect (shutters, washes, pulses over UI). */
export function Over({ rect, className, style, children }: { rect?: DOMRect; className?: string; style?: CSSProperties; children?: ReactNode }) {
  if (!rect || (rect.width === 0 && rect.height === 0)) return null
  const cls = className ? ` ${className}` : ''
  return (
    <span className={`fx-over${cls}`} style={{ ...style, left: rect.left, top: rect.top, width: rect.width, height: rect.height }}>
      {children}
    </span>
  )
}

/** Keep a glyph of half-extent `half` fully inside the viewport (390px screens). */
export function clampX(x: number, half: number): number {
  return Math.min(Math.max(x, half + 6), window.innerWidth - half - 6)
}

/** React rejects custom properties in style objects without this cast. */
export const withVars = (style: CSSProperties, vars: Record<string, string>): CSSProperties =>
  ({ ...style, ...vars }) as CSSProperties
