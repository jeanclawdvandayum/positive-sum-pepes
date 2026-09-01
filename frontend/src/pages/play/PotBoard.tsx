import { useMemo, useState } from 'react'
import { useAccount, useWriteContract } from 'wagmi'
import { renderPepeSvg } from '../../lib/pepeRender'
import { dnaOfId } from '../../components/PepePicker'
import { fmtAmount } from '../../lib/format'
import { hookAbi } from '../../lib/abi'
import type { BoardTicket } from './useLadderBoard'

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
// reads "payout if the bomb dropped this second". SETTLED (post-round), the
// pot is frozen and rows become claims-forever rows with a claimPot button.
//
// Holder avatars are LOCAL derivations — keccak(address) → dna →
// renderPepeSvg, the same identity the tape shows for the same address.
// Zero chain reads beyond the board itself.
// ─────────────────────────────────────────────────────────────────────────────

// ladder shares, newest → oldest — mirrors the contract split 25/18/14/…
// ("the math, straight"; renormalizes under 10 seated tickets)
const LADDER = [25, 18, 14, 10, 8, 7, 6, 5, 4, 3]

function short(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

const avatars = new Map<string, string>()
function avatarFor(addr: string): string {
  let svg = avatars.get(addr)
  if (svg === undefined) {
    svg = renderPepeSvg(dnaOfId(BigInt(addr)))
    if (avatars.size > 64) avatars.clear()
    avatars.set(addr, svg)
  }
  return svg
}

// sleeping faces — one deterministic LOCAL pepe per seat (same art data the
// contract renders; dimmed + zzz). No chain reads.
const sleepers = new Map<number, string>()
function sleeperFor(seat: number): string {
  let svg = sleepers.get(seat)
  if (svg === undefined) {
    svg = renderPepeSvg(dnaOfId(2_000_000_000_000n + BigInt(seat)))
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
}: {
  pot: bigint | undefined
  /** board(0..9), newest first; undefined = empty seat (§8) */
  tickets: (BoardTicket | undefined)[]
  settled?: boolean
  roundLabel?: string
  /** your claimable pot (settled mode) */
  claimable?: bigint
  /** the dead hook that pays the pot (settled mode) */
  claimHook?: `0x${string}`
}) {
  const { isConnected } = useAccount()
  const { writeContractAsync } = useWriteContract()
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
              ? 'nobody was seated — the pot waits, forever.'
              : 'distribution is frozen. claims never expire.'
            : seated === 0
              ? 'last 10 buys hold the ladder — every whole psp bought is a ticket'
              : 'payout if the bomb dropped this second'}
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
            className="relative overflow-hidden rounded-lg border border-line bg-bg-1 px-4 py-1.5 text-xs font-semibold text-text-hi transition hover:border-accent disabled:cursor-wait"
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
        <p className="mt-2 text-xs text-text-lo">✓ claimed — if you held more seats, they paid into the same pull.</p>
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
              key={s ? `${s.addr}-${s.pspWad}-${s.ts}` : `seat-${rank}`}
              className={`pl-seat ${isTop ? 'pl-seat--top' : ''} ${s ? '' : 'pl-seat--empty'} ${s && rank === 1 ? 'pl-enter' : ''}`}
            >
              <div className="pl-seat-bar" style={{ width: `${barW}%` }} aria-hidden="true" />
              <div className={`pl-seat-inner ${isTop ? 'text-base' : 'text-sm'}`}>
                <span className="tabular w-7 shrink-0 font-data text-text-lo" aria-hidden="true">
                  #{rank}
                </span>
                <span className="relative flex shrink-0">
                  <span
                    className={`pl-pepe ${isTop ? 'h-12 w-12' : 'h-9 w-9'} ${
                      s ? '' : 'pl-pepe--sleep'
                    }`}
                    style={{ imageRendering: 'pixelated' }}
                    dangerouslySetInnerHTML={{
                      __html: s ? avatarFor(s.addr) : sleeperFor(rank),
                    }}
                  />
                  {!s && (
                    <span className="pl-zzz" aria-hidden="true">
                      zzz
                    </span>
                  )}
                </span>
                <p className="min-w-0 flex-1 truncate text-text-lo">
                  {s ? (
                    <>
                      <span className="font-data text-text-hi">{short(s.addr)}</span> ·{' '}
                      <span className="tabular font-data text-text-hi">
                        {fmtAmount(s.pspWad)} psp
                      </span>{' '}
                      in
                    </>
                  ) : (
                    <>
                      this seat pays{' '}
                      <span
                        className={`tabular font-data ${isTop ? 'text-pot-gold' : 'text-text-hi'}`}
                      >
                        {LADDER[i] ?? 0}%
                      </span>{' '}
                      — nobody's sitting in it.
                    </>
                  )}
                </p>
                {s && (
                  <span
                    className="tabular shrink-0 font-data text-xs text-text-lo"
                    title="renormalized share of the pot"
                  >
                    {nominal % 1 === 0 ? nominal : nominal.toFixed(1)}%
                  </span>
                )}
                <span className="tabular ml-auto shrink-0 font-data text-text-hi">
                  {payout === undefined ? (s ? '…' : '—') : fmtAmount(payout)}{' '}
                  <span className="text-xs text-text-lo">mixETH</span>
                </span>
              </div>
            </li>
          )
        })}
      </ol>
    </div>
  )
}
