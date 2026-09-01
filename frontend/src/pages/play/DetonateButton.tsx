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
// No ambient motion (spec §4): the only animation is the existing pending
// fill, and prefers-reduced-motion already degrades it to a static tint.
// ─────────────────────────────────────────────────────────────────────────────

import { useState } from 'react'
import { useWriteContract } from 'wagmi'
import { hookAbi } from '../../lib/abi'
import { usePhase } from '../../phase/PhaseEngine'
import type { RoundInfo } from '../../lib/useRound'
import { PixelIcon } from '../../components/PixelIcon'

type Step = 'idle' | 'pending' | 'done'

export default function DetonateButton({
  round,
  onDetonated,
}: {
  round: RoundInfo
  onDetonated: () => void
}) {
  const { zero } = usePhase()
  const [step, setStep] = useState<Step>('idle')
  const [error, setError] = useState<string | null>(null)
  const { writeContractAsync } = useWriteContract()

  // the clock still lives, or the round already left Active (detonated by
  // someone else / flattened) — nothing to press
  if (!zero || round.mode !== 1 || !round.hook) return null

  async function detonate() {
    if (!round.hook || step !== 'idle') return
    setError(null)
    setStep('pending')
    try {
      await writeContractAsync({
        address: round.hook,
        abi: hookAbi,
        functionName: 'detonate',
      })
      setStep('done')
      onDetonated()
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'detonation failed')
      setStep('idle')
    }
  }

  return (
    <div className="mt-6 flex flex-col items-center gap-1.5">
      <button
        onClick={detonate}
        disabled={step !== 'idle'}
        data-pending={step === 'pending' || undefined}
        aria-label="detonate — settle the round"
        className="relative flex items-center gap-2.5 overflow-hidden rounded-xl border border-phase-critical/60 bg-phase-critical/10 px-8 py-3 font-display text-xl text-phase-critical transition hover:bg-phase-critical/20 active:translate-y-[1px] disabled:cursor-wait disabled:opacity-80"
      >
        <span className="pl-btn-fill" aria-hidden="true" />
        <PixelIcon name="bomb" size={20} />
        <span className="relative">
          {step === 'pending' ? 'detonating…' : step === 'done' ? 'detonated ✓' : 'detonate'}
        </span>
      </button>
      {error ? (
        <p className="max-w-md break-words text-center text-xs text-phase-critical">{error}</p>
      ) : (
        <p className="pl-context font-data text-xs">
          permissionless — anyone can press it. the pot settles the same either way.
        </p>
      )}
    </div>
  )
}
