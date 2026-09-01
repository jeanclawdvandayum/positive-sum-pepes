// ─────────────────────────────────────────────────────────────────────────────
// PhaseEngine — THE single module owning time → phase (REDESIGN-SPEC §2, B0 item 2)
//
// Phase boundaries on the round clock:
//   CALM  remaining > 12h          → --accent = --phase-calm, glow breathes slow
//   HEAT  12h ≥ remaining > 1h     → --accent = --phase-heat, breath rate up
//   CRITICAL remaining ≤ 1h        → --accent = --phase-critical, 1×/s pulse
//   sub10 remaining < 10min        → data-sub10 (breathing scale on clock + pot)
//
// Responsibilities (and nothing else's):
//   · data-phase / data-sub10 attributes on <html> (drive --accent + CSS)
//   · document.title = live countdown while sub10
//   · the ONE rAF loop for the live clock value (imperative writes, no re-render)
//   · one coarse ≤250ms heartbeat that fires whole-second flips — this replaces
//     every per-component 1s setInterval countdown in the app
//   · injectTime(+5min): whole-PSP buys push the detonation out (spec §4.3)
//
// Deadline source: the engine does NOT own data fetching (red-line: polling
// stays centralized in useRound/useRpcReads). Whoever knows THE round
// detonation time calls setDeadline(msEpoch). Phase 0 ships the engine with
// no caller — the current contract exposes no round timer yet, so the engine
// idles (no attrs, no title writes) until a phase wires it.
// ─────────────────────────────────────────────────────────────────────────────

import { useSyncExternalStore } from 'react'

export type Phase = 'calm' | 'heat' | 'critical'

export interface PhaseSnapshot {
  phase: Phase
  sub10: boolean
  hasDeadline: boolean
  /** clock at exactly 0:00 — trading halted, detonation live (spec §1) */
  zero: boolean
}

const HEAT_AT_MS = 12 * 3_600_000 // ≤ 12h enters HEAT
const CRITICAL_AT_MS = 1 * 3_600_000 // < 1h enters CRITICAL
const SUB10_AT_MS = 10 * 60_000 // < 10min arms sub10

let deadlineMs: number | undefined // THE round detonation time (ms epoch)
let injectedMs = 0 // client-side minutes bought (spec §4.3) — display truth between polls
let snapshot: PhaseSnapshot = { phase: 'calm', sub10: false, hasDeadline: false, zero: false }
let lastSec = Math.floor(Date.now() / 1000)
let rafId = 0
let secTimer: ReturnType<typeof setInterval> | undefined
let baseTitle: string | null = null

const phaseListeners = new Set<() => void>()
const secondListeners = new Set<() => void>() // fire on whole-second flips
const frameListeners = new Set<(nowMs: number) => void>() // rAF — the Clock only
const injectionListeners = new Set<(addedMs: number) => void>()

function effectiveDeadline(): number | undefined {
  return deadlineMs === undefined ? undefined : deadlineMs + injectedMs
}

/** ms remaining on the effective clock (deadline + injections − now); 0 when idle */
export function getRemainingMs(): number {
  const eff = effectiveDeadline()
  return eff === undefined ? 0 : Math.max(0, eff - Date.now())
}

export function getPhaseSnapshot(): PhaseSnapshot {
  return snapshot
}

function computeSnapshot(): PhaseSnapshot {
  const eff = effectiveDeadline()
  if (eff === undefined) return { phase: 'calm', sub10: false, hasDeadline: false, zero: false }
  const r = Math.max(0, eff - Date.now())
  return {
    phase: r < CRITICAL_AT_MS ? 'critical' : r <= HEAT_AT_MS ? 'heat' : 'calm',
    sub10: r > 0 && r < SUB10_AT_MS,
    hasDeadline: true,
    zero: r === 0,
  }
}

function fmtTitle(ms: number): string {
  const t = Math.max(0, Math.floor(ms / 1000))
  const m = Math.floor(t / 60)
  const s = t % 60
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')} · ${baseTitle}`
}

function applyHtml(next: PhaseSnapshot) {
  if (typeof document === 'undefined') return
  const el = document.documentElement
  if (!next.hasDeadline) {
    el.removeAttribute('data-phase')
    el.removeAttribute('data-sub10')
  } else {
    el.setAttribute('data-phase', next.phase)
    if (next.sub10) el.setAttribute('data-sub10', '')
    else el.removeAttribute('data-sub10')
  }
  // spec §2: sub-10 → document.title = live countdown (restored on exit)
  if (next.sub10) {
    if (baseTitle === null) baseTitle = document.title
    document.title = fmtTitle(getRemainingMs())
  } else if (baseTitle !== null) {
    document.title = baseTitle
    baseTitle = null
  }
}

function recompute(notify = true) {
  const next = computeSnapshot()
  applyHtml(next)
  const discrete =
    next.phase !== snapshot.phase ||
    next.sub10 !== snapshot.sub10 ||
    next.hasDeadline !== snapshot.hasDeadline ||
    next.zero !== snapshot.zero
  if (discrete) {
    snapshot = next
    if (notify) phaseListeners.forEach((l) => l())
  }
  ensureSecTimer()
}

/** fires on whole-second flips (≤250ms late) — the app's single coarse heartbeat */
function tickSeconds() {
  const s = Math.floor(Date.now() / 1000)
  if (s === lastSec) return
  lastSec = s
  if (deadlineMs !== undefined) recompute(false) // phase transitions + title
  secondListeners.forEach((l) => l())
}

/** while a deadline is registered (or anyone wants seconds), self-tick at 250ms */
function ensureSecTimer() {
  const needed = secondListeners.size > 0 || deadlineMs !== undefined
  if (needed && secTimer === undefined) {
    secTimer = setInterval(tickSeconds, 250)
  } else if (!needed && secTimer !== undefined) {
    clearInterval(secTimer)
    secTimer = undefined
  }
}

/** the ONE rAF loop — runs only while a frame consumer (the Clock) is mounted */
function ensureRaf() {
  if (typeof requestAnimationFrame === 'undefined') return
  if (frameListeners.size > 0 && rafId === 0) {
    const step = () => {
      rafId = 0
      if (frameListeners.size === 0) return
      const nowMs = Date.now()
      frameListeners.forEach((f) => f(nowMs))
      tickSeconds()
      rafId = requestAnimationFrame(step)
    }
    rafId = requestAnimationFrame(step)
  } else if (frameListeners.size === 0 && rafId !== 0) {
    cancelAnimationFrame(rafId)
    rafId = 0
  }
}

// ── public API ──────────────────────────────────────────────────────────────

/** register THE round detonation time (ms epoch); undefined = clock disarmed */
export function setDeadline(msEpoch: number | undefined) {
  const next =
    msEpoch === undefined || !Number.isFinite(msEpoch) ? undefined : Math.max(0, msEpoch)
  if (next === undefined) {
    injectedMs = 0 // clock disarmed (flat/destroyed) — optimism book closes
  } else if (deadlineMs !== undefined && next > deadlineMs && injectedMs > 0) {
    // the polled truth moved forward by `next - deadlineMs`; drop that much
    // from the optimism book (txs the chain already absorbed) — over-shoot
    // (other buyers' time) zeroes the book too.
    injectedMs = Math.max(0, injectedMs - (next - deadlineMs))
  }
  deadlineMs = next
  recompute()
  const s = Math.floor(Date.now() / 1000)
  if (s !== lastSec) {
    lastSec = s
    secondListeners.forEach((l) => l())
  }
}

/**
 * whole-PSP buy → the clock visibly jumps forward (spec §4.3).
 * Pushes the effective detonation out by `addedMs` and notifies injection
 * subscribers (Clock flashes changed digits + floats the "+5:00" chip).
 */
export function injectTime(addedMs: number) {
  if (!Number.isFinite(addedMs) || addedMs <= 0) return
  injectedMs += Math.round(addedMs)
  recompute()
  injectionListeners.forEach((l) => l(addedMs))
}

export function subscribePhase(cb: () => void): () => void {
  phaseListeners.add(cb)
  return () => {
    phaseListeners.delete(cb)
  }
}

export function subscribeSeconds(cb: () => void): () => void {
  secondListeners.add(cb)
  ensureSecTimer()
  return () => {
    secondListeners.delete(cb)
    ensureSecTimer()
  }
}

export function subscribeFrames(cb: (nowMs: number) => void): () => void {
  frameListeners.add(cb)
  ensureRaf()
  return () => {
    frameListeners.delete(cb)
    ensureRaf()
  }
}

export function subscribeInjections(cb: (addedMs: number) => void): () => void {
  injectionListeners.add(cb)
  return () => {
    injectionListeners.delete(cb)
  }
}

// ── hooks ───────────────────────────────────────────────────────────────────

/** discrete phase state — re-renders ONLY on phase/sub10 changes, never per second */
export function usePhase(): PhaseSnapshot {
  return useSyncExternalStore(subscribePhase, getPhaseSnapshot, getPhaseSnapshot)
}

function getNowSec(): number {
  return lastSec
}

/** integer unix seconds ticking on the shared heartbeat (replaces 1s setIntervals) */
export function useNow(): number {
  return useSyncExternalStore(subscribeSeconds, getNowSec, getNowSec)
}

/** whole seconds remaining to an arbitrary deadline (floor, ≥0); undefined if none */
export function useCountdown(toSec?: number): number | undefined {
  const now = useNow()
  return toSec === undefined ? undefined : Math.max(0, toSec - now)
}
