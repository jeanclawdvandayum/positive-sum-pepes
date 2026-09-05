import { useConfirmedWrite } from '../lib/useConfirmedWrite'
import { useState } from 'react'
import { useAccount } from 'wagmi'
import { erc20Abi, hookAbi, stakerAbi, controllerAbi } from '../lib/abi'
import { fmtAmount, fmtPrice } from '../lib/format'
import { useGraveyard, type GraveyardRound } from './play/useGraveyard'
import { PlayStyles } from './play/PlayStyles'

type RedeemStep = 'idle' | 'approve' | 'redeem' | 'done'

function Card({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col rounded-xl border border-line bg-bg-1 p-5">
      <h3 className="font-display text-lg text-text-hi">{title}</h3>
      {children}
    </div>
  )
}

function DeadRoundCard({ round }: { round: GraveyardRound }) {
  const { address, isConnected } = useAccount()
  const { writeContractAsync } = useConfirmedWrite({ exitRoundId: round.roundId })
  const [claiming, setClaiming] = useState(false)
  const [redeemStep, setRedeemStep] = useState<RedeemStep>('idle')
  const [redeemErr, setRedeemErr] = useState<string | null>(null)
  const [unlocking, setUnlocking] = useState<Set<string>>(new Set())
  const [unlockErr, setUnlockErr] = useState<string | null>(null)

  const perPsp =
    round.reserve !== 0n && round.supply !== 0n
      ? (round.reserve * 10n ** 18n) / round.supply
      : undefined
  const estOut =
    round.pspBal > 0n && round.supply > 0n
      ? (round.pspBal * round.reserve) / round.supply
      : undefined
  const redeemable = round.pspBal > 0n
  const needsAllowance = redeemable && round.pspAllowance < round.pspBal

  async function redeem() {
    if (!round.hook || !address || round.pspBal <= 0n) return
    setRedeemErr(null)
    try {
      if (needsAllowance) {
        setRedeemStep('approve')
        await writeContractAsync({
          address: round.token, abi: erc20Abi, functionName: 'approve',
          args: [round.hook, round.pspBal],
        })
      }
      setRedeemStep('redeem')
      await writeContractAsync({
        address: round.hook, abi: hookAbi, functionName: 'redeemBacking',
        args: [round.pspBal],
      })
      setRedeemStep('done')
    } catch (e) {
      setRedeemErr(e instanceof Error ? e.message.slice(0, 140) : 'redemption failed')
      setRedeemStep('idle')
    }
  }

  async function unlock(pepeId: bigint, amount: bigint) {
    if (!round.staker) return
    const key = pepeId.toString()
    setUnlockErr(null)
    setUnlocking((s) => new Set(s).add(key))
    try {
      await writeContractAsync({
        address: round.staker, abi: stakerAbi, functionName: amount > 0n ? 'withdraw' : 'claimFees', args: [pepeId],
      })
    } catch {
      setUnlockErr('unlock failed')
    } finally {
      setUnlocking((s) => { const n = new Set(s); n.delete(key); return n })
    }
  }

  const modeWord = round.mode === 3 ? 'destroyed' : 'flat'

  return (
    <div className="rounded-xl border border-line bg-bg-1">
      <div className="flex flex-wrap items-baseline justify-between gap-2 border-b border-line p-5">
        <div className="flex items-baseline gap-3">
          <h2 className="font-display text-xl text-text-hi">{round.name}</h2>
          <span className="rounded-full border border-line px-2.5 py-0.5 text-xs text-text-lo">
            round {round.roundId.toString()} — {modeWord}
          </span>
        </div>
        {perPsp !== undefined && (
          <p className="text-xs text-text-lo">
            backing per PSP: <span className="tabular font-data text-text-hi">{fmtPrice(perPsp)}</span> mix / psp
          </p>
        )}
      </div>

      {round.unclaimedPredeposit && (
        <button className="m-4 rounded border border-line px-4 py-2" disabled={claiming} onClick={async () => {
          setClaiming(true); setRedeemErr(null)
          try { await writeContractAsync({ address: round.controller, abi: controllerAbi, functionName: 'claimPredepositPSP' }) }
          catch (e) { setRedeemErr(e instanceof Error ? e.message : 'Predeposit claim failed') }
          finally { setClaiming(false) }
        }}>{claiming ? 'claiming…' : 'claim your predeposit position, then unlock below'}</button>
      )}
      {round.claimablePot > 0n && (
        <button className="m-4 rounded border border-line px-4 py-2" disabled={claiming} onClick={async () => {
          setClaiming(true); setRedeemErr(null)
          try { await writeContractAsync({ address: round.hook, abi: hookAbi, functionName: 'claimPot' }) }
          catch (e) { setRedeemErr(e instanceof Error ? e.message : 'Pot claim failed') }
          finally { setClaiming(false) }
        }}>{claiming ? 'claiming…' : `claim ${fmtAmount(round.claimablePot)} mixETH ladder winnings`}</button>
      )}
      <div className="grid grid-cols-1 gap-4 p-5 md:grid-cols-2">
        <Card title="redeem your psp">
          <p className="mt-1 text-xs text-text-lo">
            burn round-{round.roundId.toString()} PSP for its frozen pro-rata backing. rounding dust remains in backing for later redemptions.
          </p>
          <div className="mt-3 flex items-baseline justify-between text-sm">
            <span className="text-text-lo">your balance</span>
            <span className="tabular font-data text-text-hi">
              {round.pspBal === 0n ? '—' : `${fmtAmount(round.pspBal)} PSP`}
            </span>
          </div>
          <div className="mt-1 flex items-baseline justify-between text-sm">
            <span className="text-text-lo">redeems for</span>
            <span className="tabular font-data text-text-hi">
              {estOut === undefined ? '—' : `${fmtAmount(estOut)} mixETH`}
            </span>
          </div>
          <div className="mt-auto pt-4">
            {!isConnected ? (
              <p className="text-xs text-text-lo">connect wallet to check.</p>
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
                  {redeemStep === 'approve' ? 'approving…' : redeemStep === 'redeem' ? 'redeeming…' : redeemStep === 'done' ? '✓ redeemed' : needsAllowance ? `approve ${fmtAmount(round.pspBal)} PSP` : `redeem ${fmtAmount(round.pspBal)} PSP`}
                </span>
              </button>
            )}
            {redeemErr && <p className="mt-2 break-words text-xs text-phase-critical">{redeemErr}</p>}
          </div>
        </Card>

        <Card title="staked positions">
          <p className="mt-1 text-xs text-text-lo">
            detonation opened every lock — withdrawing skips the vest entirely. the psp lands in your
            wallet; redeem it above.
          </p>
          {round.positions.length === 0 ? (
            <p className="mt-auto pt-4 text-xs text-text-lo">
              {!isConnected ? 'connect wallet to check.' : 'nothing staked from this round.'}
            </p>
          ) : (
            <ul className="mt-3 flex flex-col gap-2">
              {round.positions.map((pos) => {
                const key = pos.id.toString()
                const busy = unlocking.has(key)
                return (
                  <li key={key} className="flex items-center justify-between gap-3 rounded-lg border border-line bg-bg-2 px-3 py-2 text-sm">
                    <span className="min-w-0 truncate text-text-lo">
                      pepe <span className="font-data text-text-hi">#{pos.id.toString()}</span> ·{' '}
                      <span className="tabular font-data text-text-hi">{fmtAmount(pos.amount)} psp</span> staked
                    </span>
                    <button
                      onClick={() => unlock(pos.id, pos.amount)}
                      disabled={busy}
                      data-pending={busy || undefined}
                      className="relative shrink-0 overflow-hidden rounded-lg border border-line bg-bg-1 px-3 py-1.5 text-xs font-semibold text-text-hi transition hover:border-accent disabled:cursor-wait"
                    >
                      <span className="pl-btn-fill" aria-hidden="true" />
                      <span className="relative">{busy ? 'confirming…' : pos.amount > 0n ? 'unlock' : `claim ${fmtAmount(pos.pendingFees)} mixETH fees`}</span>
                    </button>
                  </li>
                )
              })}
            </ul>
          )}
          {unlockErr && <p className="mt-2 text-xs text-phase-critical">{unlockErr}</p>}
        </Card>
      </div>

      <p className="border-t border-line px-5 py-3 text-center text-xs text-text-lo">
        no deadline. redeem, unlock, and claim whenever — the portal stays open forever.
      </p>
    </div>
  )
}

export default function Graveyard() {
  const { rounds, checked, error } = useGraveyard()
  const { isConnected } = useAccount()

  return (
    <div className="pl-page font-body text-text-hi">
      <PlayStyles />
      <div className="mt-4">
        <h1 className="font-display text-3xl text-text-hi">the graveyard</h1>
        <p className="mt-2 max-w-xl text-sm leading-relaxed text-text-lo">
          every round that ever died, and everything you left behind. redemption is
          indefinite — each PSP redeems against its round’s remaining backing, with floor rounding.
        </p>
      </div>
      <div className="mt-6 flex flex-col gap-6">
        {error && <p role="alert" className="text-phase-critical">{error}</p>}
      {!checked ? (
          <p className="text-sm text-text-lo">checking the graveyard…</p>
        ) : rounds.length === 0 ? (
          <div className="flex items-center gap-3 rounded-xl border border-line bg-bg-1 p-5 text-sm text-text-lo">
            <span>no dead rounds yet — the first detonation fills this page.</span>
          </div>
        ) : (
          rounds.map((r) => <DeadRoundCard key={r.roundId.toString()} round={r} />)
        )}
        {!isConnected && checked && rounds.length > 0 && (
          <p className="text-xs text-text-lo">connect your wallet to see your positions per round.</p>
        )}
      </div>
    </div>
  )
}
