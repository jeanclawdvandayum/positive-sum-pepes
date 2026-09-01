// ─────────────────────────────────────────────────────────────────────────────
// PostRound — the redemption portal (CLOCK-REDESIGN §5, §6.4).
//
// Lives after the boom: the dead hook custodies backing + pot forever, so
// this panel is PULL-based and deadline-free. Three moves, each one-click,
// each silent when it doesn't apply:
//   · redeem — your round PSP → mixETH at the frozen payout
//     (approve if needed, then hook.redeemBacking(balance); PSP is burned,
//     payout per PSP never moves post-detonation)
//   · unlock — staked positions: at Flat the lock is open, withdraw skips
//     the vest entirely; the PSP lands in the wallet, redeemable above
//   · claim — the pot: lives on the settled ladder (PotBoard), claimPot()
//     pulls every seat you own, forever
// Data rides useDeadRound's 6s lane; the writes are plain wagmi sends.
// ─────────────────────────────────────────────────────────────────────────────

import { useState } from 'react'
import { useAccount, useWriteContract } from 'wagmi'
import { erc20Abi, hookAbi, stakerAbi } from '../../lib/abi'
import { fmtAmount, fmtPrice } from '../../lib/format'
import type { DeadRoundState } from './useDeadRound'
import { PixelIcon } from '../../components/PixelIcon'

type RedeemStep = 'idle' | 'approve' | 'redeem' | 'done'

function Card({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col rounded-xl border border-line bg-bg-1 p-5">
      <h3 className="font-display text-lg text-text-hi">{title}</h3>
      {children}
    </div>
  )
}

export default function PostRound({
  dead,
  justDetonated,
}: {
  dead: DeadRoundState
  justDetonated: boolean
}) {
  const { address, isConnected } = useAccount()
  const { writeContractAsync } = useWriteContract()
  const [redeemStep, setRedeemStep] = useState<RedeemStep>('idle')
  const [redeemErr, setRedeemErr] = useState<string | null>(null)
  const [unlocking, setUnlocking] = useState<Set<string>>(new Set())
  const [unlockErr, setUnlockErr] = useState<string | null>(null)

  // the lane hasn't confirmed the corpse yet (the click landed; the factory
  // lane still turns over) — hold the page's hand for the second it takes
  if (!dead.dead) {
    return justDetonated ? (
      <section
        aria-label="redemption portal"
        className="mt-4 flex items-center gap-3 rounded-xl border border-line bg-bg-1 p-5 text-sm text-text-lo"
      >
        <PixelIcon name="bomb" size={18} />
        <span>detonation accepted — the dust is settling. the portal opens the second the round flattens.</span>
      </section>
    ) : null
  }

  const perPsp =
    dead.reserve !== undefined && dead.supply !== undefined && dead.supply > 0n
      ? (dead.reserve * 10n ** 18n) / dead.supply
      : undefined
  const estOut =
    dead.pspBal !== undefined && dead.reserve !== undefined && dead.supply !== undefined && dead.supply > 0n
      ? (dead.pspBal * dead.reserve) / dead.supply
      : undefined
  const redeemable = (dead.pspBal ?? 0n) > 0n
  const needsAllowance = redeemable && (dead.pspAllowance ?? 0n) < (dead.pspBal ?? 0n)

  async function redeem() {
    if (!dead.token || !dead.hook || !address || (dead.pspBal ?? 0n) <= 0n) return
    setRedeemErr(null)
    try {
      if (needsAllowance) {
        setRedeemStep('approve')
        await writeContractAsync({
          address: dead.token,
          abi: erc20Abi,
          functionName: 'approve',
          args: [dead.hook, dead.pspBal!],
        })
      }
      setRedeemStep('redeem')
      await writeContractAsync({
        address: dead.hook,
        abi: hookAbi,
        functionName: 'redeemBacking',
        args: [dead.pspBal!],
      })
      setRedeemStep('done')
    } catch (e) {
      setRedeemErr(e instanceof Error ? e.message.slice(0, 140) : 'redemption failed')
      setRedeemStep('idle')
    }
  }

  async function unlock(pepeId: bigint) {
    if (!dead.staker) return
    const key = pepeId.toString()
    setUnlockErr(null)
    setUnlocking((s) => new Set(s).add(key))
    try {
      await writeContractAsync({
        address: dead.staker,
        abi: stakerAbi,
        functionName: 'withdraw',
        args: [pepeId],
      })
    } catch (e) {
      setUnlockErr(e instanceof Error ? e.message.slice(0, 140) : 'unlock failed')
    } finally {
      setUnlocking((s) => {
        const n = new Set(s)
        n.delete(key)
        return n
      })
    }
  }

  const modeWord = dead.mode === 3 ? 'destroyed' : 'flat'

  return (
    <section aria-label="redemption portal" className="mt-4">
      <div className="rounded-xl border border-line bg-bg-1">
        <div className="flex flex-wrap items-baseline justify-between gap-2 border-b border-line p-5">
          <div className="flex items-baseline gap-3">
            <h2 className="font-display text-xl text-text-hi">redemption portal</h2>
            <span className="rounded-full border border-line px-2.5 py-0.5 text-xs text-text-lo">
              round {dead.roundId?.toString() ?? '…'} {dead.name ? `· ${dead.name} ` : ''}— {modeWord}
            </span>
          </div>
          <p className="text-xs text-text-lo">frozen payout: <span className="tabular font-data text-text-hi">{fmtPrice(perPsp)}</span> mix / psp</p>
        </div>

        <div className="grid grid-cols-1 gap-4 p-5 md:grid-cols-2">
          {/* ── redeem PSP → mixETH ─────────────────────────────────────── */}
          <Card title="redeem your psp">
            <p className="mt-1 text-xs text-text-lo">
              burn round-{dead.roundId?.toString()} PSP for its pro-rata mixETH. the payout froze at
              detonation — it does not move, ever.
            </p>
            <div className="mt-3 flex items-baseline justify-between text-sm">
              <span className="text-text-lo">your balance</span>
              <span className="tabular font-data text-text-hi">
                {dead.pspBal === undefined ? '…' : `${fmtAmount(dead.pspBal)} PSP`}
              </span>
            </div>
            <div className="mt-1 flex items-baseline justify-between text-sm">
              <span className="text-text-lo">redeems for</span>
              <span className="tabular font-data text-text-hi">
                {estOut === undefined ? '…' : `${fmtAmount(estOut)} mixETH`}
              </span>
            </div>
            <div className="mt-auto pt-4">
              {!isConnected ? (
                <p className="text-xs text-text-lo">connect wallet to redeem.</p>
              ) : !redeemable ? (
                <p className="text-xs text-text-lo">no psp from this round in your wallet.</p>
              ) : (
                <button
                  onClick={redeem}
                  disabled={redeemStep !== 'idle' && redeemStep !== 'done'}
                  data-pending={(redeemStep === 'approve' || redeemStep === 'redeem') || undefined}
                  className="relative w-full overflow-hidden rounded-xl border border-line bg-bg-2 px-5 py-2.5 font-semibold text-text-hi transition hover:border-accent disabled:cursor-wait"
                >
                  <span className="pl-btn-fill" aria-hidden="true" />
                  <span className="relative">
                    {redeemStep === 'approve'
                      ? 'approving…'
                      : redeemStep === 'redeem'
                        ? 'redeeming…'
                        : redeemStep === 'done'
                          ? '✓ redeemed'
                          : needsAllowance
                            ? `approve ${fmtAmount(dead.pspBal)} PSP`
                            : `redeem ${fmtAmount(dead.pspBal)} PSP for mixETH`}
                  </span>
                </button>
              )}
              {redeemErr && <p className="mt-2 break-words text-xs text-phase-critical">{redeemErr}</p>}
            </div>
          </Card>

          {/* ── immediate unlock of staked positions ────────────────────── */}
          <Card title="staked positions">
            <p className="mt-1 text-xs text-text-lo">
              detonation opened every lock — withdrawing skips the vest entirely. unlocked PSP lands
              in your wallet; redeem it above if you want the mix.
            </p>
            {dead.positions.length === 0 ? (
              <p className="mt-auto pt-4 text-xs text-text-lo">
                {!isConnected ? 'connect wallet to check your positions.' : 'nothing staked from this round.'}
              </p>
            ) : (
              <ul className="mt-3 flex flex-col gap-2">
                {dead.positions.map((p) => {
                  const busy = unlocking.has(p.id.toString())
                  return (
                    <li
                      key={p.id.toString()}
                      className="flex items-center justify-between gap-3 rounded-lg border border-line bg-bg-2 px-3 py-2 text-sm"
                    >
                      <span className="min-w-0 truncate text-text-lo">
                        pepe <span className="font-data text-text-hi">#{p.id.toString()}</span> ·{' '}
                        <span className="tabular font-data text-text-hi">{fmtAmount(p.amount)} psp</span> staked
                      </span>
                      <button
                        onClick={() => unlock(p.id)}
                        disabled={busy}
                        data-pending={busy || undefined}
                        className="relative shrink-0 overflow-hidden rounded-lg border border-line bg-bg-1 px-3 py-1.5 text-xs font-semibold text-text-hi transition hover:border-accent disabled:cursor-wait"
                      >
                        <span className="pl-btn-fill" aria-hidden="true" />
                        <span className="relative">{busy ? 'unlocking…' : 'unlock'}</span>
                      </button>
                    </li>
                  )
                })}
                {dead.positions.length >= 8 && (
                  <li className="text-xs text-text-lo">showing the first 8 — the stake page lists the rest.</li>
                )}
              </ul>
            )}
            {unlockErr && <p className="mt-2 break-words text-xs text-phase-critical">{unlockErr}</p>}
          </Card>
        </div>

        <p className="border-t border-line px-5 py-3 text-center text-xs text-text-lo">
          no deadline. the portal stays open forever — redeem, unlock, and claim whenever.
        </p>
      </div>
    </section>
  )
}
