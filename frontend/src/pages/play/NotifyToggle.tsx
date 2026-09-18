import { useEffect, useRef, useState } from 'react'
import { getRemainingMs, subscribeSeconds } from '../../phase/PhaseEngine'
import type { RoundInfo } from '../../lib/useRound'

// ─────────────────────────────────────────────────────────────────────────────
// NotifyToggle — opt-in browser notification when the clock drops under five
// minutes (UX assessment #29). Rides PhaseEngine's existing one-second
// listener set: no new loop, no new reads. Fires once per crossing: a buy
// that pushes the clock back over 5:00 re-arms it. Denied permission and
// unsupported browsers stay silent (the control simply does not render).
// ─────────────────────────────────────────────────────────────────────────────

const KEY = 'psp-notify-5m'
const THRESHOLD_MS = 5 * 60_000

function granted(): boolean {
  return typeof Notification !== 'undefined' && Notification.permission === 'granted'
}

const DEFAULT_CLASS = 'pl-context mt-3 rounded-md border border-[#22344f] px-2.5 py-1 font-data text-[11px] transition hover:border-[#8ba3bd] focus-visible:outline-2 focus-visible:outline-accent disabled:opacity-60'

export default function NotifyToggle({ round, className = DEFAULT_CLASS }: { round: RoundInfo; className?: string }) {
  const supported = typeof window !== 'undefined' && typeof Notification !== 'undefined'
  const [on, setOn] = useState<boolean>(() => {
    try { return supported && granted() && window.localStorage.getItem(KEY) === '1' } catch { return false }
  })
  const [busy, setBusy] = useState(false)
  const armed = useRef(true) // true while the clock sits above the threshold

  useEffect(() => {
    if (!on || !supported || round.mode !== 1) return
    const check = () => {
      const r = getRemainingMs()
      if (r > THRESHOLD_MS) { armed.current = true; return }
      if (armed.current && r > 0 && granted()) {
        armed.current = false
        try {
          new Notification('positive sum pepes', {
            body: 'under five minutes on the clock. the carpet bombers are about to get paid.',
            tag: 'psp-5m',
          })
        } catch { /* notification blocked at the OS level — nothing to do */ }
      }
    }
    check()
    return subscribeSeconds(check)
  }, [on, supported, round.mode])

  if (!supported || round.mode !== 1) return null

  async function toggle() {
    if (busy) return
    if (on) {
      setOn(false)
      try { window.localStorage.setItem(KEY, '0') } catch { /* session only */ }
      return
    }
    setBusy(true)
    try {
      const p = Notification.permission === 'granted' ? 'granted' : await Notification.requestPermission()
      if (p === 'granted') {
        setOn(true)
        try { window.localStorage.setItem(KEY, '1') } catch { /* session only */ }
      }
    } finally {
      setBusy(false)
    }
  }

  return (
    <button
      type="button"
      onClick={() => { void toggle() }}
      disabled={busy}
      aria-pressed={on}
      className={className}
    >
      {on ? 'notifying under 5 minutes ✓' : 'notify me under 5 minutes'}
    </button>
  )
}
