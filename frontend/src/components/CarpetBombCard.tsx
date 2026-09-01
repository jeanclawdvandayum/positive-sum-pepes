import { useEffect, useMemo, useState } from 'react'
import { useAccount, useWriteContract } from 'wagmi'
import { useRpcReads } from '../lib/useRpcReads'
import { controllerAbi, stakerAbi } from '../lib/abi'
import { useNow } from '../phase/PhaseEngine'
import { rpcCall } from '../lib/rpc'
import { useRound } from '../lib/useRound'
import { fmtAmount, fmtCountdown } from '../lib/format'
import { PixelIcon } from './PixelIcon'

type Step = 'idle' | 'tx' | 'done'

/// one pepe of the connected wallet, with its vote state
interface Pepe {
  id: bigint
  weight: bigint          // pepeVoteWeight now (0 while unstaking)
  staked: bigint          // principal
  unstaking: boolean      // withdraw request armed
  voted: boolean          // already voted this proposal
}

export default function CarpetBombCard() {
  const round = useRound()
  const { address, isConnected } = useAccount()
  const [step, setStep] = useState<Step>('idle')
  const [error, setError] = useState<string | null>(null)
  /// shared PhaseEngine heartbeat (B0 refactor — was its own 1s setInterval)
  const now = useNow()
  const { writeContractAsync } = useWriteContract()

  /// selected pepes for the vote (id-KEYED — indices reshuffle when the
  /// list reorders on mint/transfer, ids never do; shaggoth finding 1)
  const [pepes, setPepes] = useState<Pepe[] | undefined>(undefined)
  const [selected, setSelected] = useState<Set<string>>(new Set())

  /// poll: proposal + my pepes + per-pepe vote state + live denominator
  const ZERO = '0x0000000000000000000000000000000000000000' as const
  const reads = useRpcReads(
    [
      { to: round.controller, abi: controllerAbi, functionName: 'getCarpetBombState' },
      { to: round.controller, abi: controllerAbi, functionName: 'VOTE_DURATION' },
      { to: round.controller, abi: controllerAbi, functionName: 'FLAT_EXIT_WINDOW' },
      { to: round.controller, abi: controllerAbi, functionName: 'QUORUM_BIPS' },
      { to: round.controller, abi: controllerAbi, functionName: 'MAJORITY_BIPS' },
      { to: round.controller, abi: controllerAbi, functionName: 'proposalCount' },
      { to: round.staker, abi: stakerAbi, functionName: 'totalVotableWeight' },
      { to: round.staker, abi: stakerAbi, functionName: 'stakedTotalOf', args: [address ?? ZERO] },
    ],
    !!round.controller,
  )

  const stArr = reads[0] as [string, bigint, bigint, bigint, boolean, boolean] | undefined
  const st = stArr
    ? { proposer: stArr[0], proposeTime: stArr[1], yesVotes: stArr[2], noVotes: stArr[3], executed: stArr[4], canExecute: stArr[5] }
    : undefined
  const voteDuration = Number(reads[1] ?? 3n * 86400n)
  const exitWindow = Number(reads[2] ?? 3n * 86400n)
  const quorumBips = Number(reads[3] ?? 6900n)
  const majorityBips = Number(reads[4] ?? 5001n)
  const proposalCount = reads[5] as bigint | undefined
  /// LIVE denominator (scoopy 2026-08-29): Σ locked PSP not awaiting the
  /// withdraw cooldown — quorum tracks the round's live staking set.
  const denominator = reads[6] as bigint | undefined
  const stakedTotal = reads[7] as bigint | undefined

  const voting = st !== undefined && st.proposeTime !== 0n && !st.executed
    && now < Number(st.proposeTime) + voteDuration

  /// my pepes + their vote state (only while a vote could matter)
  useEffect(() => {
    if (!round.staker || !address || !round.controller) return
    let dead = false
    async function tick() {
      try {
        const n = Number(await rpcCall(round.staker!, stakerAbi, 'balanceOf', [address!]) as bigint)
        const out: Pepe[] = []
        for (let i = 0; i < n; ++i) {
          const id = await rpcCall(round.staker!, stakerAbi, 'tokenOfOwnerByIndex', [address!, BigInt(i)]) as bigint
          const pos = await rpcCall(round.staker!, stakerAbi, 'positions', [id]) as [bigint, bigint, bigint, bigint, bigint, bigint]
          const w = await rpcCall(round.staker!, stakerAbi, 'pepeVoteWeight', [id, BigInt(Math.floor(Date.now() / 1000))]) as bigint
          const lastVoted = proposalCount !== undefined
            ? await rpcCall(round.controller!, controllerAbi, 'lastVotedPepeOn', [id]) as bigint
            : 0n
          out.push({
            id,
            staked: pos[0],
            unstaking: pos[2] !== 0n,
            weight: w,
            voted: proposalCount !== undefined && lastVoted === proposalCount,
          })
        }
        if (!dead) {
          setPepes(out)
          // default selection: every votable, unvoted pepe (keep explicit
          // user toggles across refreshes — keyed by id, survives reorder)
          setSelected((prev) => {
            const fresh = new Set<string>()
            const firstLoad = prev.size === 0
            out.forEach((p) => {
              const key = p.id.toString()
              if (p.weight > 0n && !p.voted && (firstLoad || prev.has(key))) fresh.add(key)
            })
            return fresh
          })
        }
      } catch {
        /* keep last */
      }
    }
    tick()
    const iv = setInterval(tick, 5000)
    return () => { dead = true; clearInterval(iv) }
  }, [round.staker, round.controller, address, proposalCount, voting])

  const selectedIds = useMemo(() => {
    if (!pepes) return []
    return pepes.filter((p) => selected.has(p.id.toString())).map((p) => p.id)
  }, [pepes, selected])
  const selectedWeight = useMemo(() => {
    if (!pepes) return 0n
    return pepes.filter((p) => selected.has(p.id.toString())).reduce((acc, p) => acc + p.weight, 0n)
  }, [pepes, selected])
  const votableCount = pepes?.filter((p) => p.weight > 0n && !p.voted).length ?? 0

  const derived = useMemo(() => {
    if (!st || st.proposeTime === 0n)
      return { phase: 'none' as const }
    const endsAt = Number(st.proposeTime) + voteDuration
    const isVoting = now < endsAt
    const totalVotes = st.yesVotes + st.noVotes
    const denom = denominator !== undefined && denominator > 0n ? denominator : undefined
    const quorumPct = denom
      ? Math.min(999, Number((totalVotes * 10000n) / denom) / 100)
      : 0
    const quorumTarget = quorumBips / 100
    const quorumMet = denom ? totalVotes * 10000n >= denom * BigInt(quorumBips) : false
    const majorityMet = totalVotes > 0n && st.yesVotes * 10000n > totalVotes * BigInt(majorityBips)
    if (st.executed) return { phase: 'executed' as const }
    if (isVoting) return { phase: 'voting' as const, endsAt, totalVotes, quorumPct, quorumTarget, quorumMet, majorityMet }
    if (quorumMet && majorityMet) return { phase: 'executable' as const, totalVotes, quorumPct, quorumTarget }
    return { phase: 'failed' as const, totalVotes, quorumPct, quorumTarget }
  }, [st, denominator, now, voteDuration, quorumBips, majorityBips])

  const canVote = voting && isConnected && votableCount > 0 && selectedWeight > 0n && selectedIds.length > 0

  async function run(
    fn: 'proposeCarpetBomb' | 'voteCarpetBomb' | 'carpetBomb' | 'finalizeCarpet',
    support = true,
  ) {
    setError(null)
    try {
      setStep('tx')
      if (fn === 'voteCarpetBomb') {
        await writeContractAsync({
          address: round.controller!,
          abi: controllerAbi,
          functionName: 'voteCarpetBomb',
          args: [selectedIds, support],
        })
      } else {
        await writeContractAsync({
          address: round.controller!,
          abi: controllerAbi,
          functionName: fn,
        })
      }
      setStep('done')
      setTimeout(() => setStep('idle'), 2500)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
      setStep('idle')
    }
  }

  const busy = step === 'tx'

  function togglePepe(id: bigint, p: Pepe) {
    if (p.weight === 0n || p.voted) return
    const key = id.toString()
    setSelected((prev) => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }

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
              measured against locked PSP not currently unstaking (69%),
              majority of cast votes (50%+).
            </div>
            <button
              className="btn-primary mt-4 w-full"
              disabled={!isConnected || !stakedTotal || stakedTotal === 0n || busy}
              onClick={() => run('proposeCarpetBomb')}
            >
              {isConnected && (!stakedTotal || stakedTotal === 0n)
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

            {/* quorum — LIVE votable denominator */}
            <div className="mt-4">
              <div className="mb-1 flex justify-between text-xs font-bold text-slate-400">
                <span>
                  quorum {derived.quorumPct.toFixed(1)}% / {derived.quorumTarget}%{' '}
                  {derived.quorumMet ? '✅' : ''}
                </span>
                <span>{fmtAmount(denominator)} PSP votable (live)</span>
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
              <div className="mt-1 text-[11px] font-bold text-slate-400">
                unstaking PSP leaves the quorum pool · new stakes join it and can vote
              </div>
            </div>

            {derived.phase === 'voting' && (
              <>
                {/* pepe selector — vote with specific NFTs (scoopy 2026-08-29) */}
                {isConnected && (
                  <div className="mt-4 rounded-2xl border border-sky-100 bg-sky-50/50 p-3">
                    <div className="mb-2 flex items-center justify-between text-xs font-bold text-slate-400">
                      <span>vote with which pepes?</span>
                      <span>{fmtAmount(selectedWeight)} PSP selected</span>
                    </div>
                    {pepes === undefined ? (
                      <div className="text-xs font-bold text-slate-400">loading your pepes…</div>
                    ) : pepes.length === 0 ? (
                      <div className="text-xs font-bold text-slate-400">no pepes — stake PSP to vote</div>
                    ) : (
                      <div className="flex flex-wrap gap-2">
                        {pepes.map((p) => {
                          const disabled = p.weight === 0n || p.voted
                          const on = selected.has(p.id.toString())
                          return (
                            <button
                              key={p.id.toString()}
                              type="button"
                              disabled={disabled}
                              onClick={() => togglePepe(p.id, p)}
                              title={
                                p.voted ? 'already voted this proposal'
                                  : p.unstaking ? 'unstaking — cancel the withdraw to restore its vote'
                                  : `${fmtAmount(p.staked)} PSP`
                              }
                              className={`rounded-xl px-3 py-2 text-xs font-black transition ${
                                p.voted
                                  ? 'bg-slate-100 text-slate-400'
                                  : p.unstaking
                                    ? 'bg-amber-50 text-amber-400'
                                    : on
                                      ? 'bg-gradient-to-r from-sky-400 to-emerald-400 text-[#fff] shadow'
                                      : 'bg-white text-slate-600 shadow-sm'
                              }`}
                            >
                              #{p.id.toString()}
                              {p.voted ? ' ✓voted' : p.unstaking ? ' ⏳unstaking' : ` · ${fmtAmount(p.staked)}`}
                            </button>
                          )
                        })}
                      </div>
                    )}
                  </div>
                )}

                <div className="mt-4 grid grid-cols-2 gap-2">
                  <button
                    className="rounded-2xl bg-emerald-400 px-4 py-3 font-black text-[#fff] shadow-md shadow-emerald-200 transition active:scale-[0.98] disabled:opacity-40"
                    disabled={!canVote || busy}
                    onClick={() => run('voteCarpetBomb', true)}
                  >
                    vote yes{selectedIds.length > 0 ? ` (${selectedIds.length})` : ''}
                  </button>
                  <button
                    className="rounded-2xl bg-rose-400 px-4 py-3 font-black text-[#fff] shadow-md shadow-rose-200 transition active:scale-[0.98] disabled:opacity-40"
                    disabled={!canVote || busy}
                    onClick={() => run('voteCarpetBomb', false)}
                  >
                    vote no{selectedIds.length > 0 ? ` (${selectedIds.length})` : ''}
                  </button>
                </div>
                {isConnected && pepes !== undefined && pepes.some((p) => p.unstaking && !p.voted) && (
                  <div className="mt-2 text-center text-xs font-bold text-amber-500">
                    ⏳ = unstaking (no vote) — cancel the withdraw on the stake page to restore it
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
              <div className="mt-3">
                <div className="text-xs font-bold text-slate-400">
                  vote failed or expired without quorum — a new proposal can replace it.
                </div>
                <button
                  className="btn-primary mt-3 w-full"
                  disabled={!isConnected || !stakedTotal || stakedTotal === 0n || busy}
                  onClick={() => run('proposeCarpetBomb')}
                >
                  {isConnected && (!stakedTotal || stakedTotal === 0n)
                    ? 'stake PSP to propose'
                    : '🔄 propose again'}
                </button>
                <p className="mt-2 text-[11px] font-bold text-slate-400">
                  votes are cast per-pepe — unstaking pepes sit out (cancel to rejoin),
                  fresh stakes vote at full power immediately.
                </p>
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
              mixETH per PSP). buying is disabled until the next round.
            </div>
            {now < Number(round.flatTime) + exitWindow ? (
              <div className="text-xs font-bold text-[#fff]/60">
                exit window open · finalize in{' '}
                {fmtCountdown(Number(round.flatTime) + exitWindow - now)} · whatever remains seeds
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
