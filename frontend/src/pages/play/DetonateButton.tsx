import { useConfirmedWrite } from '../../lib/useConfirmedWrite'
// ─────────────────────────────────────────────────────────────────────────────
// DetonateButton — the zero-hour trigger (CLOCK-REDESIGN §4, §6.3).
//
// Hidden while the clock lives (now < detonationAt — the engine's `zero`
// flag is false). Appears the second remaining hits 0, CRITICAL-phase
// styling off var(--phase-critical) (the phase system owns every accent).
// One click → detonate(): permissionless on-chain, gated
// block.timestamp >= detonationAt, idempotent via mode check. Success
// flips the play page into post-round mode via onDetonated (Trade owns
// that state); the button also self-hides the moment the round lane
// reports the round no longer Active.
//
// No ambient motion in the original UI (spec §4): the only animation is the
// existing pending fill, and prefers-reduced-motion already degrades it to a
// static tint. variant="alt" (alt UI only, styles in public/alt/detonation.css)
// adds decorative spans — hazard-stripe crawl, fuse spark, bottom-edge fuse —
// and a data-state hook (armed|pending|done). The FX itself ('detonate') is
// fired by useConfirmedWrite on write success; never fired here.
// ─────────────────────────────────────────────────────────────────────────────

import { useState } from 'react'

import { controllerAbi } from '../../lib/abi'
import { usePhase } from '../../phase/PhaseEngine'
import type { RoundInfo } from '../../lib/useRound'
import { PixelIcon } from '../../components/PixelIcon'

type Step = 'idle' | 'pending' | 'done'

export default function DetonateButton({
  round,
  onDetonated,
  variant,
}: {
  round: RoundInfo
  onDetonated: () => void
  variant?: 'alt'
}) {
  const { zero } = usePhase()
  const [step, setStep] = useState<Step>('idle')
  const [error, setError] = useState<string | null>(null)
  const { writeContractAsync } = useConfirmedWrite()

  // the clock still lives, or the round already left Active (detonated by
  // someone else / flattened) — nothing to press
  if (!zero || round.mode !== 1 || !round.controller) return null

  async function detonate() {
    if (!round.controller || step !== 'idle') return
    setError(null)
    setStep('pending')
    try {
      await writeContractAsync({
        address: round.controller,
        abi: controllerAbi,
        functionName: 'detonate',
        gas: 1_000_000n, // settlement only; successor uses resumable birth steps
      })
      setStep('done')
      onDetonated()
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'detonation failed')
      setStep('idle')
    }
  }

  const alt = variant === 'alt'
  const label = step === 'pending' ? 'detonating…' : step === 'done' ? 'detonated ✓' : 'detonate'

  return (
    <div className="mt-6 flex flex-col items-center gap-1.5">
      <button
        onClick={detonate}
        disabled={step !== 'idle'}
        data-pending={step === 'pending' || undefined}
        data-state={alt ? (step === 'idle' ? 'armed' : step) : undefined}
        aria-label="detonate — settle the round"
        className={`tx-action relative flex items-center gap-2.5 overflow-hidden rounded-xl border border-phase-critical/60 bg-phase-critical/10 px-8 py-3 font-display text-xl text-phase-critical transition hover:bg-phase-critical/20 active:translate-y-[1px] disabled:cursor-wait disabled:opacity-80${alt ? ' alt-detonate' : ''}`}
      >
        <span className="pl-btn-fill" aria-hidden="true" />
        {alt && <span className="dtn-stripes" aria-hidden="true" />}
        {alt ? (
          <span className="dtn-bomb">
            <PixelIcon name="bomb" size={26} />
            <span className="dtn-spark" aria-hidden="true" />
          </span>
        ) : (
          <PixelIcon name="bomb" size={20} />
        )}
        <span className="relative">{label}</span>
        {alt && <span className="dtn-fuse" aria-hidden="true" />}
      </button>
      {error ? (
        <p className="max-w-md break-words text-center text-xs text-phase-critical">{error}</p>
      ) : (
        <p className="pl-context font-data text-xs">
          big red button. anyone can press it. the ladder decides who gets paid.
        </p>
      )}
    </div>
  )
}
