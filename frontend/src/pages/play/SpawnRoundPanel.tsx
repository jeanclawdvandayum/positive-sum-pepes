import { rpcCall } from '../../lib/rpc'
import { useConfirmedWrite } from '../../lib/useConfirmedWrite'
import { useState } from 'react'

import { factoryAbi } from '../../lib/abi'

/// SpawnRoundPanel — the permissionless rebirth flow for capped chains.
/// Four confirmed transactions: reserveSpawn, then three birthStep calls.
/// Anyone can call either step (the factory cares only about round state).
export default function SpawnRoundPanel({
  factory,
  destroyedRoundId,
}: {
  factory: `0x${string}`
  destroyedRoundId: bigint
}) {
  const { writeContractAsync } = useConfirmedWrite()
  const [step, setStep] = useState<'idle' | 'reserving' | 'birthing' | 'done'>('idle')
  const [err, setErr] = useState<string | null>(null)

  if (!factory || destroyedRoundId === undefined) return null

  async function spawn() {
    if (step !== 'idle') return
    setErr(null)
    try {
      for (let attempt = 0; attempt < 6; attempt++) {
        const current = await rpcCall(factory, factoryAbi, 'currentRoundId') as bigint
        if (current > destroyedRoundId) { setStep('done'); return }
        const active = await rpcCall(factory, factoryAbi, 'reservationActive') as boolean
        const phase = active ? Number(await rpcCall(factory, factoryAbi, 'reservationPhase')) : 0
        setStep(active ? 'birthing' : 'reserving')
        try {
          await writeContractAsync({
            address: factory, abi: factoryAbi,
            functionName: active ? 'birthStep' : 'reserveSpawn',
            args: active ? [] : [destroyedRoundId],
            gas: 12_000_000n,
          })
        } catch (error) {
          // Another caller may have completed this step while our wallet was open.
          const next = await rpcCall(factory, factoryAbi, 'currentRoundId') as bigint
          const nowActive = await rpcCall(factory, factoryAbi, 'reservationActive') as boolean
          const nowPhase = nowActive ? Number(await rpcCall(factory, factoryAbi, 'reservationPhase')) : 0
          if (next > current || active !== nowActive || nowPhase !== phase) continue
          throw error
        }
      }
      const current = await rpcCall(factory, factoryAbi, 'currentRoundId') as bigint
      if (current <= destroyedRoundId) throw new Error('Birth is unfinished. Retry to resume the current step.')
      setStep('done')
    } catch (e) {
      setErr(e instanceof Error ? e.message.slice(0, 160) : 'spawn failed — retry to resume from chain state')
      setStep('idle')
    }
  }

  if (step === 'done') {
    return (
      <div className="flex items-center gap-3 rounded-xl border border-line bg-bg-1 p-5 text-sm">
        <span className="text-text-hi">round {Number(destroyedRoundId) + 1} is ready — its predeposit window is open.</span>
      </div>
    )
  }

  return (
    <section aria-label="spawn next round" className="mt-4">
      <div className="rounded-xl border border-line bg-bg-1 p-5">
        <div className="flex items-baseline gap-3">
          <h2 className="font-display text-xl text-text-hi">another round of frog business · {Number(destroyedRoundId) + 1}</h2>
          <span className="rounded-full border border-line px-2.5 py-0.5 text-xs text-text-lo">
            permissionless
          </span>
        </div>
        <p className="mt-2 max-w-lg text-sm leading-relaxed text-text-lo">
          the detonation flattened round {destroyedRoundId?.toString()} and opened every lock. the successor
          needs a reservation and three birth steps. anyone can complete them; retrying resumes the unfinished step.
        </p>
        {err && <p className="mt-2 break-words text-xs text-phase-critical">{err}</p>}
        <button
          onClick={spawn}
          disabled={step === 'reserving' || step === 'birthing'}
          data-pending={step === 'reserving' || step === 'birthing' || undefined}
          className="relative mt-4 w-full overflow-hidden rounded-xl border border-line bg-bg-2 px-5 py-3 font-semibold text-text-hi transition hover:border-accent disabled:cursor-wait"
        >
          <span className="pl-btn-fill" aria-hidden="true" />
          <span className="relative">
            {step === 'reserving' ? 'reserving the next round…' : step === 'birthing' ? 'creating the next round…' : 'spawn round ' + (Number(destroyedRoundId) + 1)}
          </span>
        </button>
        <p className="mt-2 text-xs text-text-lo">
          each step waits for a successful receipt. failed on-chain transactions still cost gas; a retry resumes from chain state.
        </p>
      </div>
    </section>
  )
}
