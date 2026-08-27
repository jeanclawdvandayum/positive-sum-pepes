import { useEffect, useMemo, useState } from 'react'
import { useAccount, useReadContracts, useWriteContract } from 'wagmi'
import { controllerAbi, stakerAbi } from '../lib/abi'
import { useRound } from '../lib/useRound'
import { fmtAmount, fmtCountdown } from '../lib/format'
import { PixelIcon } from './PixelIcon'

type Step = 'idle' | 'tx' | 'done'

export default function CarpetBombCard() {
  const round = useRound()
  const { address, isConnected } = useAccount()
  const [step, setStep] = useState<Step>('idle')
  const [error, setError] = useState<string | null>(null)
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000))
  const { writeContractAsync } = useWriteContract()

  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000)
    return () => clearInterval(t)
  }, [])

  const ZERO = '0x0000000000000000000000000000000000000000' as const
  const reads = useReadContracts({
    contracts: [
      { address: round.controller ?? ZERO, abi: controllerAbi, functionName: 'getCarpetBombState' },
      { address: round.controller ?? ZERO, abi: controllerAbi, functionName: 'currentProposal' },
      { address: round.staker ?? ZERO, abi: stakerAbi, functionName: 'lockedPSPOf', args: [address ?? ZERO] },
      { address: round.controller ?? ZERO, abi: controllerAbi, functionName: 'VOTE_DURATION' },
      { address: round.controller ?? ZERO, abi: controllerAbi, functionName: 'QUORUM_BIPS' },
      { address: round.controller ?? ZERO, abi: controllerAbi, functionName: 'MAJORITY_BIPS' },
      { address: round.controller ?? ZERO, abi: controllerAbi, functionName: 'lastVotedOn', args: [address ?? ZERO] },
      { address: round.controller ?? ZERO, abi: controllerAbi, functionName: 'proposalCount' },
    ],
    query: { enabled: !!round.controller },
  })

  const stArr = reads.data?.[0]?.result as [string, bigint, bigint, bigint, boolean, boolean] | undefined
  const st = stArr
    ? { proposer: stArr[0], proposeTime: stArr[1], yesVotes: stArr[2], noVotes: stArr[3], executed: stArr[4], canExecute: stArr[5] }
    : undefined
  const propArr = reads.data?.[1]?.result as [string, bigint, bigint, bigint, bigint, boolean] | undefined
  const prop = propArr
    ? { proposer: propArr[0], proposeTime: propArr[1], yesVotes: propArr[2], noVotes: propArr[3], lockedAtPropose: propArr[4], executed: propArr[5] }
    : undefined
  const lockAmount = reads.data?.[2]?.result as bigint | undefined
  const lock = lockAmount !== undefined ? { amount: lockAmount } : undefined
  const voteDuration = Number(reads.data?.[3]?.result ?? 3n * 86400n)
  const quorumBips = Number(reads.data?.[4]?.result ?? 6900n)
  const majorityBips = Number(reads.data?.[5]?.result ?? 5001n)
  const lastVotedOn = reads.data?.[6]?.result as bigint | undefined
  const proposalCount = reads.data?.[7]?.result as bigint | undefined

  const derived = useMemo(() => {
    if (!st || st.proposeTime === 0n)
      return { phase: 'none' as const }
    const endsAt = Number(st.proposeTime) + voteDuration
    const voting = now < endsAt
    const totalVotes = st.yesVotes + st.noVotes
    const quorumPct = prop && prop.lockedAtPropose > 0n
      ? Math.min(999, Number((totalVotes * 10000n) / prop.lockedAtPropose) / 100)
      : 0
    const quorumTarget = quorumBips / 100
    const quorumMet = prop && prop.lockedAtPropose > 0n
      ? totalVotes * 10000n >= prop.lockedAtPropose * BigInt(quorumBips)
      : false
    const majorityMet = totalVotes > 0n && st.yesVotes * 10000n > totalVotes * BigInt(majorityBips)
    if (st.executed) return { phase: 'executed' as const }
    if (voting) return { phase: 'voting' as const, endsAt, totalVotes, quorumPct, quorumTarget, quorumMet, majorityMet }
    if (quorumMet && majorityMet) return { phase: 'executable' as const, totalVotes, quorumPct, quorumTarget }
    return { phase: 'failed' as const, totalVotes, quorumPct, quorumTarget }
  }, [st, prop, now, voteDuration, quorumBips, majorityBips])

  const canVote =
    derived.phase === 'voting' &&
    isConnected &&
    !!lock &&
    lock.amount > 0n &&
    lastVotedOn !== proposalCount
  const alreadyVoted = lastVotedOn !== undefined && proposalCount !== undefined && lastVotedOn === proposalCount

  async function run(
    fn: 'proposeCarpetBomb' | 'voteCarpetBomb' | 'carpetBomb' | 'finalizeCarpet',
    support = true,
  ) {
    setError(null)
    try {
      setStep('tx')
      await writeContractAsync({
        address: round.controller!,
        abi: controllerAbi,
        functionName: fn,
        ...(fn === 'voteCarpetBomb' ? { args: [support] } : {}),
      })
      setStep('done')
      setTimeout(() => setStep('idle'), 2500)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
      setStep('idle')
    }
  }

  const busy = step === 'tx'

  return (
    <div className="card overflow-hidden p-0">
      <div className="bg-gradient-to-r from-amber-400 via-orange-400 to-rose-400 px-5 py-3">
        <h2 className="flex items-center gap-1.5 text-lg font-black text-[#fff]">
          <PixelIcon name="bomb" size={20} /> carpet bomb
        </h2>
        <p className="text-xs font-bold text-[#fff]/80">
          stakers vote to end the round · treasury inherits into the next
        </p>
      </div>

      <div className="p-5">
        {derived.phase === 'none' && (
          <div>
            <div className="rounded-2xl bg-amber-50 p-4 text-sm font-bold text-amber-700">
              no active proposal. initiating a vote requires staked PSP — quorum is
              measured against max(total staked, total supply) at proposal time
              (69%), majority of cast votes (50%+), 3-day window.
            </div>
            <button
              className="btn-primary mt-4 w-full"
              disabled={!isConnected || !lock || lock.amount === 0n || busy}
              onClick={() => run('proposeCarpetBomb')}
            >
              {isConnected && (!lock || lock.amount === 0n)
                ? 'stake PSP to propose'
                : ' initiate vote'}
            </button>
          </div>
        )}

        {(derived.phase === 'voting' || derived.phase === 'executable' || derived.phase === 'failed') && st && (
          <div>
            <div className="flex items-center justify-between">
              <span
                className={`chip ${
                  derived.phase === 'voting'
                    ? 'bg-sky-100 text-sky-700'
                    : derived.phase === 'executable'
                      ? 'bg-emerald-100 text-emerald-700'
                      : 'bg-rose-100 text-rose-600'
                }`}
              >
                {derived.phase === 'voting' ? '🗳️ voting open' : derived.phase === 'executable' ? '✅ passed — executable' : '❌ failed'}
              </span>
              {derived.phase === 'voting' && (
                <span className="font-black text-psp-deep">
                  ⏳ {fmtCountdown(derived.endsAt - now)}
                </span>
              )}
            </div>

            {/* tallies */}
            <div className="mt-4 grid grid-cols-2 gap-3 text-center">
              <div className="rounded-2xl bg-emerald-50 p-3">
                <div className="text-[11px] font-black uppercase text-emerald-500">yes</div>
                <div className="text-lg font-black text-emerald-700">{fmtAmount(st.yesVotes)}</div>
              </div>
              <div className="rounded-2xl bg-rose-50 p-3">
                <div className="text-[11px] font-black uppercase text-rose-400">no</div>
                <div className="text-lg font-black text-rose-600">{fmtAmount(st.noVotes)}</div>
              </div>
            </div>

            {/* quorum */}
            <div className="mt-4">
              <div className="mb-1 flex justify-between text-xs font-bold text-slate-400">
                <span>
                  quorum {derived.quorumPct.toFixed(1)}% / {derived.quorumTarget}%{' '}
                  {derived.quorumMet ? '✅' : ''}
                </span>
                <span>{fmtAmount(prop?.lockedAtPropose)} PSP denominator</span>
              </div>
              <div className="h-3 overflow-hidden rounded-full bg-slate-100">
                <div
                  className={`h-full rounded-full ${
                    derived.quorumMet
                      ? 'bg-gradient-to-r from-emerald-400 to-emerald-500'
                      : 'bg-gradient-to-r from-amber-400 to-orange-400'
                  }`}
                  style={{ width: `${Math.min(100, (derived.quorumPct / derived.quorumTarget) * 100)}%` }}
                />
              </div>
            </div>

            {derived.phase === 'voting' && (
              <>
                <div className="mt-4 grid grid-cols-2 gap-2">
                  <button
                    className="rounded-2xl bg-emerald-400 px-4 py-3 font-black text-[#fff] shadow-md shadow-emerald-200 transition active:scale-[0.98] disabled:opacity-40"
                    disabled={!canVote || busy}
                    onClick={() => run('voteCarpetBomb', true)}
                  >
                    vote yes
                  </button>
                  <button
                    className="rounded-2xl bg-rose-400 px-4 py-3 font-black text-[#fff] shadow-md shadow-rose-200 transition active:scale-[0.98] disabled:opacity-40"
                    disabled={!canVote || busy}
                    onClick={() => run('voteCarpetBomb', false)}
                  >
                    vote no
                  </button>
                </div>
                <button
                  className="mt-2 w-full rounded-2xl border border-slate-200 bg-white px-4 py-2 text-sm font-bold text-slate-400"
                  disabled
                  title="abstaining = simply not voting"
                >
                  abstain (sit out)
                </button>
                {alreadyVoted && (
                  <div className="mt-2 text-center text-xs font-bold text-slate-400">
                    you already voted on this proposal
                  </div>
                )}
                {!isConnected && (
                  <div className="mt-2 text-center text-xs font-bold text-slate-400">
                    connect wallet + stake to vote
                  </div>
                )}
              </>
            )}

            {derived.phase === 'executable' && (
              <>
                <button className="btn-primary mt-4 w-full" disabled={busy} onClick={() => run('carpetBomb')}>
                  {busy ? 'confirm…' : '💥 execute carpet bomb'}
                </button>
              </>
            )}
            {derived.phase === 'failed' && (
              <div className="mt-3 text-xs font-bold text-slate-400">
                vote failed or expired without quorum — a new proposal can replace it.
              </div>
            )}
          </div>
        )}

        {derived.phase === 'executed' && round.mode === 2 && round.flatTime !== undefined && (
          <div className="space-y-3">
            <div className="rounded-2xl bg-gradient-to-r from-orange-100 to-amber-50 p-4 text-sm font-bold text-amber-700">
              💥 boom. the curve is flat — <span className="text-amber-900">every lock is open</span>.
              unstake and sell at average backing (
              {round.supply && round.supply > 0n && round.reserve
                ? fmtAmount((round.reserve * 10n ** 18n) / round.supply)
                : '…'}{' '}
              mixETH per PSP).
            </div>
            {now < Number(round.flatTime) + 259_200 ? (
              <div className="text-xs font-bold text-[#fff]/60">
                exit window open · finalize in{' '}
                {fmtCountdown(Number(round.flatTime) + 259_200 - now)} · whatever remains seeds
                round n+1
              </div>
            ) : (
              <button
                className="btn-primary w-full"
                disabled={busy}
                onClick={() => run('finalizeCarpet')}
              >
                {busy ? 'finalizing…' : '🪦 close the round — carry the remainder to round n+1'}
              </button>
            )}
          </div>
        )}

        {derived.phase === 'executed' && round.mode === 3 && (
          <div className="rounded-2xl bg-gradient-to-r from-orange-100 to-amber-50 p-4 text-sm font-bold text-amber-700">
            💥 boom. this round was closed — reserves carried into the next round.
            head to trade for round n+1.
          </div>
        )}

        {error && <div className="mt-2 break-words text-xs text-rose-500">{error}</div>}
      </div>
    </div>
  )
}
