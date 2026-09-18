import { useConfirmedWrite } from '../../lib/useConfirmedWrite'
import { useMemo, useState } from 'react'
import { useAccount } from 'wagmi'
import { renderDecorativePepeSvg } from '../../lib/pepeRender'
import { dnaOfId } from '../../components/PepePicker'
import { fmtAmount, wadToExact } from '../../lib/format'
import { LADDER_SHARES } from '../../lib/gameRules'
import { hookAbi } from '../../lib/abi'
import type { BoardTicket } from './useLadderBoard'
import WalletPepeArt from '../../components/WalletPepeArt'
import WalletName from '../../components/WalletName'

// ─────────────────────────────────────────────────────────────────────────────
// PotBoard — the ladder, right of the swap (REDESIGN-B2 §3, CLOCK-REDESIGN
// §2/§6.4/§6.5).
//
// Ten seats, newest ticket → oldest, fed by useLadderBoard's real board(i)
// reads — the shipped dormant keyframes light up: a fresh #1 mounts with
// .pl-enter, the board shifts, the sleeping seats wake one ticket at a time.
// Empty seats keep their designed §8 state (sleeping pepe + zzz) until a
// ticket exists — no fake holders, ever.
//
// Shares mirror the contract 25/18/14/…/3 from NEWEST to OLDEST, renorma-
// lized across the seats actually taken ("nobody gets dusted"); payouts are
// pot × share, exact wei math. LIVE, the pot is potBalance() (fee escrow —
// the clock redesign's pot is no longer the curve reserve) and the header
// reads "your cut if it blows now. everyone wants your seat.". SETTLED (post-round), the
// pot is frozen and rows become claims-forever rows with a claimPot button.
//
// Holder avatars share the header's round-aware NFT/available-wallet identity.
// ─────────────────────────────────────────────────────────────────────────────

// ladder shares, newest → oldest — mirrors the contract split 25/18/14/…
// ("the math, straight"; renormalizes under 10 seated tickets)
const LADDER: readonly number[] = LADDER_SHARES

// sleeping faces — one deterministic LOCAL pepe per seat (same art data the
// contract renders; dimmed + zzz). No chain reads.
const sleepers = new Map<number, string>()
function sleeperFor(seat: number): string {
  let svg = sleepers.get(seat)
  if (svg === undefined) {
    svg = renderDecorativePepeSvg(dnaOfId(2_000_000_000_000n + BigInt(seat)))
    sleepers.set(seat, svg)
  }
  return svg
}

/** renormalized share of seat i across n seated tickets, as a percent */
function sharePct(i: number, n: number): number {
  const sum = LADDER.slice(0, n).reduce((a, b) => a + b, 0)
  return (LADDER[i] / sum) * 100
}

export default function PotBoard({
  pot,
  tickets,
  settled = false,
  roundLabel,
  claimable,
  claimHook,
  staker,
  roundId,
  ticketPrice,
}: {
  /** live one-ticket price (v3: pot ÷ 10,000) — undefined while loading */
  ticketPrice?: bigint
  pot: bigint | undefined
  /** board(0..9), newest first; undefined = empty seat (§8) */
  tickets: (BoardTicket | undefined)[]
  settled?: boolean
  roundLabel?: string
  /** your claimable pot (settled mode) */
  claimable?: bigint
  /** the dead hook that pays the pot (settled mode) */
  claimHook?: `0x${string}`
  /** total tickets ever — seat i (newest first) is ticket count−1−i */
  ticketCount?: bigint
  /** the round's staker — for reading seat holders' actual pepe NFTs */
  staker?: `0x${string}`
  roundId?: bigint
}) {
  const { isConnected } = useAccount()
  const { writeContractAsync } = useConfirmedWrite(settled ? { exitRoundId: roundId } : undefined)
  const [claimStep, setClaimStep] = useState<'idle' | 'pending' | 'done'>('idle')
  const [claimErr, setClaimErr] = useState<string | null>(null)

  const seats = useMemo(
    () => Array.from({ length: 10 }, (_, i) => tickets[i] ?? undefined),
    [tickets],
  )
  const seated = seats.filter((s): s is BoardTicket => s !== undefined).length
  // bar scale: the largest share actually seated (renormalization can push
  // a lonely #1 to 100% — 4× the nominal top), else the nominal ladder top
  const top = useMemo(() => {
    if (seated === 0) return LADDER[0]
    return Math.max(...Array.from({ length: seated }, (_, i) => sharePct(i, seated)))
  }, [seated])

  // payout-if-now (live) / frozen payout (settled): pot × renormalized share
  const payoutWad = (i: number): bigint | undefined => {
    if (pot === undefined || i >= seated || seated === 0) return undefined
    const sum = LADDER.slice(0, seated).reduce((a, b) => a + b, 0)
    return (pot * BigInt(LADDER[i])) / BigInt(sum)
  }

  async function claim() {
    if (!claimHook || claimStep !== 'idle') return
    setClaimErr(null)
    setClaimStep('pending')
    try {
      await writeContractAsync({
        address: claimHook,
        abi: hookAbi,
        functionName: 'claimPot',
      })
      setClaimStep('done')
    } catch (e) {
      setClaimErr(e instanceof Error ? e.message.slice(0, 140) : 'claim failed')
      setClaimStep('idle')
    }
  }

  const canClaim =
    settled && !!claimHook && isConnected && (claimable ?? 0n) > 0n && claimStep !== 'done'

  return (
    <div className="flex h-full flex-col rounded-xl border border-line bg-bg-1 p-5 font-body">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="font-display text-xl text-text-hi">
          the ladder{settled && roundLabel ? ` — ${roundLabel}` : ''}
        </h2>
        <p className="text-xs text-text-lo">
          {settled
            ? seated === 0
              ? 'empty ladder. the pot joined the reserves for PSP redemption.'
              : 'the seats are settled. collect your cut whenever you’re ready.'
            : `the last 10 tickets bought hold the seats${ticketPrice !== undefined ? ` · a ticket costs ${wadToExact(ticketPrice)} mixETH right now` : ''}${seated === 0 ? '' : ' · your cut if it blows now'}`}
        </p>
      </div>

      {canClaim && (
        <div className="mt-3 flex flex-wrap items-center justify-between gap-2 rounded-lg border border-line bg-bg-2 px-3 py-2.5">
          <span className="text-sm text-text-lo">
            your claim:{' '}
            <span className="tabular font-data text-pot-gold">{fmtAmount(claimable)} mixETH</span>
          </span>
          <button
            onClick={claim}
            disabled={claimStep === 'pending'}
            data-pending={claimStep === 'pending' || undefined}
            className="tx-action relative overflow-hidden rounded-lg border border-line bg-bg-1 px-4 py-1.5 text-xs font-semibold text-text-hi transition hover:border-accent disabled:cursor-wait"
          >
            <span className="pl-btn-fill" aria-hidden="true" />
            <span className="relative">
              {claimStep === 'pending' ? 'claiming…' : 'claim the pot'}
            </span>
          </button>
        </div>
      )}
      {claimErr && <p className="mt-2 break-words text-xs text-phase-critical">{claimErr}</p>}
      {claimStep === 'done' && (
        <p className="mt-2 text-xs text-text-lo">✓ claimed — all your winning seats paid together.</p>
      )}

      {!settled && (
        <p className="mt-2 text-xs text-text-lo">
          seats pay 25 / 18 / 14 / 10 / 8 / 7 / 6 / 5 / 4 / 3% of the pot, newest first. fewer seats share it all. a new ticket takes #1 and pushes everyone down.
        </p>
      )}
      <ol className="mt-4 flex flex-1 flex-col gap-1.5">
        {seats.map((s, i) => {
          const rank = i + 1
          const isTop = rank === 1
          const payout = payoutWad(i)
          const nominal = s ? sharePct(i, seated) : (LADDER[i] ?? 0)
          const barW = Math.min(100, (nominal / top) * 100)
          return (
            <li
              key={`${s?.addr ?? 'empty'}-${s?.ts ?? 0n}-${i}`}
              className={`pl-seat ${isTop ? 'pl-seat--top' : ''} ${s ? '' : 'pl-seat--empty'} ${s && rank === 1 ? 'pl-enter' : ''}`}
            >
              <div className="pl-seat-bar" style={{ width: `${barW}%` }} aria-hidden="true" />
              <div className={`pl-seat-inner ${isTop ? 'text-base' : 'text-sm'}`}>
                <span className="tabular w-7 shrink-0 font-data text-text-lo" aria-hidden="true">
                  {`#${rank}`}
                </span>
                <span className="relative flex shrink-0">
                  {s ? <WalletPepeArt address={s.addr} staker={staker}
                    className={`pl-pepe ${isTop ? 'h-12 w-12' : 'h-9 w-9'}`} /> : <span
                    className={`pl-pepe pl-pepe--sleep ${isTop ? 'h-12 w-12' : 'h-9 w-9'}`}
                    style={{ imageRendering: 'pixelated' }}
                    dangerouslySetInnerHTML={{ __html: sleeperFor(rank) }}
                  />}
                  {!s && (
                    <span className="pl-zzz" aria-hidden="true">
                      zzz
                    </span>
                  )}
                </span>
                <p className="min-w-0 flex-1 truncate text-text-lo">
                  {s ? (
                    <>
                      <WalletName address={s.addr} className="font-data text-text-hi" /> ·{' '}
                      <span className="tabular font-data text-text-hi">
                        {fmtAmount(s.pspWad)} psp
                      </span>{' '}
                      in
                    </>
                  ) : (
                    <>
                      open seat ·{' '}
                      <span
                        className={`tabular font-data ${isTop ? 'text-pot-gold' : 'text-text-hi'}`}
                      >
                        {LADDER[i] ?? 0}%
                      </span>
                    </>
                  )}
                </p>
                {s && (
                  <span
                    className="tabular shrink-0 font-data text-xs text-text-lo"
                    title="share of the pot, adjusted for the occupied seats"
                  >
                    {nominal % 1 === 0 ? nominal : nominal.toFixed(1)}%
                  </span>
                )}
                {s && (
                  <span className="tabular ml-auto shrink-0 font-data text-text-hi">
                    {payout === undefined ? '…' : fmtAmount(payout)}{' '}
                    <span className="text-xs text-text-lo">mixETH</span>
                  </span>
                )}
              </div>
            </li>
          )
        })}
      </ol>
    </div>
  )
}
