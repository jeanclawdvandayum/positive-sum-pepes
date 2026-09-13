import GravePositionDetails from '../alt/GravePositionDetails'
import { usePepeDnaVersion } from '../lib/usePepeDnaVersion'
import { useConfirmedWrite } from '../lib/useConfirmedWrite'
import { useMemo, useState } from 'react'
import { useAccount } from 'wagmi'
import { erc20Abi, hookAbi, stakerAbi, controllerAbi } from '../lib/abi'
import { fmtAmount, fmtPrice, fmtPepeId } from '../lib/format'
import { useGraveyard, type GraveyardRound } from './play/useGraveyard'
import { PlayStyles } from './play/PlayStyles'
import HallOfDetonations from './graveyard/HallOfDetonations'

import { usePepeDna } from '../lib/usePepeDna'
import { renderPepeSvg } from '../lib/pepeRender'

function GraveyardArt({ staker, id }: { staker?: `0x${string}`; id: bigint }) {
  const version = usePepeDnaVersion(staker)
  const { data: dna, isError } = usePepeDna(staker, id)
  const svg = useMemo(() => dna === undefined || version === undefined ? undefined : renderPepeSvg(dna, version), [dna, version])
  return svg ? <div role="img" aria-label={`pepe ${id}`} className="aspect-square overflow-hidden rounded-lg [&>svg]:h-full [&>svg]:w-full" dangerouslySetInnerHTML={{ __html: svg }} />
    : <div className="flex aspect-square items-center justify-center text-xs text-text-lo">{isError ? 'pepe image unavailable' : 'loading pepe…'}</div>
}

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
      setUnlockErr(amount > 0n ? 'Unlock failed. Please try again.' : 'Fee claim failed. Your fees remain claimable.')
    } finally {
      setUnlocking((s) => { const n = new Set(s); n.delete(key); return n })
    }
  }


  return (
    <div className="rounded-xl border border-line bg-bg-1">
      <div className="flex flex-wrap items-baseline justify-between gap-2 border-b border-line p-5">
        <div className="flex min-w-0 flex-wrap items-center gap-3">
          <h2 className="font-display text-xl text-text-hi">{round.name} · round {round.roundId.toString()}</h2>
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
            burn round-{round.roundId.toString()} PSP for its share of this round’s remaining mixETH. payouts are rounded down; the remainder stays in the reserves.
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
              <p className="text-xs text-text-lo">your wallet holds 0 PSP from this round.</p>
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

        <div className="grave-positions flex min-w-0 flex-col gap-4">
          {[{ title: 'lePSP positions', positions: round.positions.filter(p => p.amount > 0n) },
            { title: 'dead pepe collection', positions: round.positions.filter(p => p.amount === 0n) }].map(group => (
            <Card key={group.title} title={group.title}>
              <p className="mt-1 text-xs text-text-lo">{group.title === 'lePSP positions'
                ? 'unlock your PSP and redeem it above. earned mixETH stays claimable after detonation.'
                : 'unlocked, still yours. these pepes carry the scars of past rounds.'}</p>
              {group.positions.length === 0 ? <p className="mt-4 text-xs text-text-lo">{!isConnected ? 'connect wallet to see your pepes.' : 'your collection is empty for this round.'}</p> : (
                <ul className="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2">
                  {group.positions.map(pos => {
                    const busy = unlocking.has(pos.id.toString())
                    return <li key={pos.id.toString()} className="min-w-0 rounded-lg border border-line bg-bg-2 p-3 text-sm">
                      <GraveyardArt staker={round.staker} id={pos.id} />
                      <p className="mt-2 truncate font-data" title={pos.id.toString()}>pepe #{fmtPepeId(pos.id)}</p>
                      {pos.amount > 0n && <p className="mt-1 text-xs text-text-lo">{fmtAmount(pos.amount)} lePSP</p>}
                      {pos.pendingFees > 0n && <button disabled={busy} onClick={() => unlock(pos.id, 0n)} className="mt-3 w-full rounded-lg border border-line bg-bg-1 px-3 py-2 text-xs font-semibold hover:border-accent disabled:opacity-50">
                        {busy ? 'confirming…' : `claim ${fmtAmount(pos.pendingFees)} mixETH`}
                      </button>}
                      {pos.amount > 0n && <button disabled={busy} onClick={() => unlock(pos.id, pos.amount)} className="mt-2 w-full rounded-lg border border-line bg-bg-1 px-3 py-2 text-xs font-semibold hover:border-accent disabled:opacity-50">
                        {busy ? 'confirming…' : 'unlock PSP'}
                      </button>}
                      <GravePositionDetails round={round} id={pos.id} amount={pos.amount}/>
                    </li>
                  })}
                </ul>
              )}
            </Card>
          ))}
          {unlockErr && <p role="alert" className="text-xs text-phase-critical">{unlockErr}</p>}
        </div>
      </div>

      <p className="border-t border-line px-5 py-3 text-center text-xs text-text-lo">
        take your time. redemption, withdrawals and claims stay open.
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
          even a dead round has receipts. claim ladder winnings, withdraw old stakes, and redeem PSP for its share of that round’s remaining mixETH. payouts are rounded down and can be worth less than you paid.
        </p>
      </div>
      <div className="mt-6 flex flex-col gap-6">
        {error && <p role="alert" className="text-phase-critical">{error}</p>}
        <HallOfDetonations rounds={rounds} checked={checked} connected={isConnected} />
        {checked && rounds.map((r) => <DeadRoundCard key={r.roundId.toString()} round={r} />)}
        {!isConnected && checked && rounds.length > 0 && (
          <p className="text-xs text-text-lo">connect your wallet to see your positions per round.</p>
        )}
      </div>
    </div>
  )
}
