// ─────────────────────────────────────────────────────────────────────────────
// grave-view — the refined graveyard (out/rendered-4 light, 9 dark).
//
// "the graveyard" → per dead round: the final-receipt paper + hall of
// detonations hero, then "your paperwork" as three forms (FORM R-1 redemption,
// FORM L-1 release, FORM D-1 collection). Every action is DeadRoundCard's,
// carried over unchanged — redeem (approve→burn), per-pepe unlock/fee claims,
// the one-tx exit zap, the predeposit claim (hatch FX) and the pot claim
// (victory FX). Only the composition is new.
// ─────────────────────────────────────────────────────────────────────────────
import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAccount } from 'wagmi'
import { erc20Abi, hookAbi, stakerAbi, controllerAbi, graveZapAbi } from '../lib/abi'
import { ADDRESSES } from '../lib/config'
import { fmtAmount, fmtPrice, fmtPepeId } from '../lib/format'
import { rpcBatchCall } from '../lib/rpc'
import { readRoundWinners, type RoundWinner } from '../lib/roundWinners'
import { useWalletPepe } from '../lib/useWalletPepe'
import { usePepeDna } from '../lib/usePepeDna'
import { usePepeDnaVersion } from '../lib/usePepeDnaVersion'
import { renderPepeSvg } from '../lib/pepeRender'
import { useConfirmedWrite } from '../lib/useConfirmedWrite'
import GravePositionDetails from './GravePositionDetails'
import ReferralRewards from '../components/ReferralRewards'
import type { GraveyardRound } from '../pages/play/useGraveyard'

type RedeemStep = 'idle' | 'approve' | 'redeem' | 'done'
type Write = Parameters<ReturnType<typeof useConfirmedWrite>['writeWithApprovals']>[0]

function GraveArt({ staker, id }: { staker: `0x${string}` | undefined; id: bigint }) {
  const version = usePepeDnaVersion(staker)
  const { data: dna, isError } = usePepeDna(staker, id)
  const svg = useMemo(() => dna === undefined || version === undefined ? undefined : renderPepeSvg(dna, version), [dna, version])
  return svg ? <div role="img" aria-label={`pepe ${id}`} className="grv-thumb-art" dangerouslySetInnerHTML={{ __html: svg }} />
    : <div className="grv-thumb-art grv-thumb-loading" role="img" aria-label={`pepe ${id}`}>{isError ? 'no image' : '…'}</div>
}

function WinnerPolaroid({ address, staker, seats }: { address: `0x${string}`; staker: `0x${string}` | undefined; seats: number }) {
  const svg = useWalletPepe(address, staker)
  const caption = seats === 10 ? 'took all ten seats.' : `took ${seats} ${seats === 1 ? 'seat' : 'seats'}.`
  return (
    <figure className="grv-polaroid">
      <div role="img" aria-label={`round winner ${address} pepe`} dangerouslySetInnerHTML={{ __html: svg }} />
      <figcaption>{caption}</figcaption>
    </figure>
  )
}

/// Deterministic faux barcode — decoration only (aria-hidden), seeded by the
/// round so a given receipt always tears off the same strip.
function Barcode({ seed }: { seed: bigint }) {
  const bars = useMemo(() => Array.from({ length: 46 }, (_, i) => 1 + Number((seed * 31n + BigInt(i * 17)) % 4n)), [seed])
  return (
    <svg className="grv-barcode" viewBox="0 0 200 44" preserveAspectRatio="none" aria-hidden="true">
      {bars.map((w, i) => <rect key={i} x={i * 4.3} width={w} height="44" fill="currentColor" />)}
    </svg>
  )
}

// ladder seat weights in percent points — mirrors CurveHook._ladderBps and
// lib/roundWinners.WEIGHTS; only used to print per-seat receipt lines.
const SEAT_WEIGHTS = [25, 18, 14, 10, 8, 7, 6, 5, 4, 3]

function shortAddr(address: `0x${string}`) {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

function AltDeadRound({ round, connected }: { round: GraveyardRound; connected: boolean }) {
  const { address, isConnected } = useAccount()
  const { writeContractAsync, writeWithApprovals } = useConfirmedWrite({ exitRoundId: round.roundId })
  // A late claim hatches in the dead round's staker; the alt FX reveals that mint.
  const dnaVersion = usePepeDnaVersion(round.staker)
  const hatchFx = round.staker && dnaVersion !== undefined ? { hatch: { staker: round.staker, dnaVersion } } : {}
  const [claiming, setClaiming] = useState(false)
  const [redeemStep, setRedeemStep] = useState<RedeemStep>('idle')
  const [redeemErr, setRedeemErr] = useState<string | null>(null)
  const [unlocking, setUnlocking] = useState<Set<string>>(new Set())
  const [unlockErr, setUnlockErr] = useState<string | null>(null)

  // the settled hook keeps the final ladder — one read per round
  const [finalLadder, setFinalLadder] = useState<{ hook: string; winners: RoundWinner[]; seats: number }>()
  useEffect(() => {
    let stopped = false
    setFinalLadder(undefined)
    readRoundWinners(rpcBatchCall, round.hook)
      .then(result => { if (!stopped) setFinalLadder({ hook: round.hook, ...result }) })
      .catch(() => { if (!stopped) setFinalLadder({ hook: round.hook, winners: [], seats: -1 }) })
    return () => { stopped = true }
  }, [round.hook])
  const ladderReady = finalLadder?.hook === round.hook && finalLadder.seats >= 0

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

  const winners = finalLadder?.hook === round.hook ? finalLadder.winners : undefined
  const seats = winners?.flatMap(w => w.ranks.map(rank => ({ rank, wallet: w }))) ?? []
  const seatDenom = seats.reduce((sum, s) => sum + SEAT_WEIGHTS[s.rank - 1], 0)
  const top = winners?.[0]

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

  // ── one-tx exit (PSPGraveZap): pot claim + fee claim + unlock + fee-free
  //    redemption, all in a single transaction. Hidden until the zap is
  //    deployed (VITE_GRAVE_ZAP) and there is something to exit.
  const GZ = ADDRESSES.graveZap
  const staked = round.positions.filter(p => p.amount > 0n)
  const unlockY = staked.reduce((s, p) => s + p.amount, 0n)
  const feesDue = staked.reduce((s, p) => s + p.pendingFees, 0n)
  const claimX = round.claimablePot + feesDue
  const convertP = unlockY + round.pspBal
  const mixZ = convertP > 0n && round.supply > 0n
    ? (convertP * round.reserve) / round.supply
    : 0n
  const exitLine = [
    ...(claimX > 0n ? [`claim ${fmtAmount(claimX)} mixETH`] : []),
    ...(unlockY > 0n ? [`unlock ${fmtAmount(unlockY)} PSP`] : []),
    ...(convertP > 0n ? [`convert ${fmtAmount(convertP)} PSP → ${fmtAmount(mixZ)} mixETH`] : []),
  ].join(' · ')
  const exitReady = GZ !== '0x' && !!round.staker && !!round.hook && isConnected && (claimX > 0n || unlockY > 0n)
  const [exitStep, setExitStep] = useState<'idle' | 'sign' | 'done'>('idle')
  const [exitErr, setExitErr] = useState<string | null>(null)

  async function exitRound() {
    if (!round.staker || !round.hook || !exitReady) return
    setExitErr(null); setExitStep('sign')
    try {
      const action: Write = {
        address: GZ, abi: graveZapAbi, functionName: 'exit',
        args: [round.hook, round.staker, staked.map(p => p.id), convertP, mixZ,
               BigInt(Math.floor(Date.now() / 1000) + 600)],
      }
      const approvals: Write[] = [
        { address: round.staker, abi: stakerAbi, functionName: 'setApprovalForAll', args: [GZ, true] },
        ...(convertP > 0n ? [{ address: round.token, abi: erc20Abi, functionName: 'approve', args: [GZ, convertP] } as Write] : []),
      ]
      await writeWithApprovals(action, approvals)
      setExitStep('done')
    } catch (e) {
      setExitErr(e instanceof Error ? e.message.slice(0, 160) : 'exit failed. your positions are unchanged.')
      setExitStep('idle')
    }
  }

  const stakedPositions = round.positions.filter(p => p.amount > 0n)
  const deadPositions = round.positions.filter(p => p.amount === 0n)

  return (
    <div className="grv-round">
      <section className="grv-hero" aria-label={`round ${round.roundId.toString()} final receipt`}>
        <div className="grv-receipt">
          <div className="grv-receipt-paper">
            <span className="grv-receipt-title">round {round.roundId.toString()} · final receipt</span>
            <span className="micro-label grv-center">{round.name} · pot settled at detonation</span>
            <hr className="grv-dash" />
            {!ladderReady ? (
              <p role="status" className="grv-seat grv-seat-loading">{winners === undefined ? 'printing the final ladder…' : 'the final ladder is unavailable.'}</p>
            ) : seats.length === 0 ? (
              <p className="grv-seat grv-seat-loading">the ladder finished empty. the pot joined this round's PSP redemption reserves.</p>
            ) : (
              seats.map(seat => (
                <div key={seat.rank} className="grv-seat">
                  <span className="grv-seat-rank">#{String(seat.rank).padStart(2, '0')}</span>
                  <span className="micro-label">{shortAddr(seat.wallet.address)} · {Math.round(SEAT_WEIGHTS[seat.rank - 1] * 1000 / seatDenom) / 10}%</span>
                  <span className="grv-seat-amt">{round.pot !== undefined ? fmtAmount(round.pot * BigInt(SEAT_WEIGHTS[seat.rank - 1]) / BigInt(seatDenom), 4) : '…'}</span>
                </div>
              ))
            )}
            <hr className="grv-dash" />
            <div className="grv-total"><span>total pot</span><span>{round.pot === undefined ? '—' : fmtAmount(round.pot, 4)}</span></div>
            <div className="grv-receipt-meta"><span>winners</span><span>{winners === undefined ? '…' : `${winners.length} ${winners.length === 1 ? 'wallet' : 'wallets'} · ${seats.length} ${seats.length === 1 ? 'seat' : 'seats'}`}</span></div>
            <div className="grv-receipt-meta"><span>backing per PSP</span><span>{perPsp === undefined ? '—' : `${fmtPrice(perPsp)} mix`}</span></div>
            <Barcode seed={round.roundId} />
          </div>
          <div className="grv-receipt-teeth" aria-hidden="true" />
          <div className="grv-stamp" aria-hidden="true">DETONATED</div>
        </div>

        <div className="grv-hall">
          <div className="grv-hall-head">
            <h2>hall of detonations</h2>
            <span className="grv-hall-sub">every boom gets a paper trail.</span>
          </div>
          {!ladderReady ? <p role="status" className="grv-hall-note">reading the final ladder…</p> : !top ? (
            <p className="grv-hall-note">the ladder finished empty — the pot joined this round's redemption reserves.</p>
          ) : (
            <div className="grv-hall-row">
              <WinnerPolaroid address={top.address} staker={round.staker} seats={top.ranks.length} />
              <div className="grv-hall-info">
                <span className="micro-label">round {round.roundId.toString()} winner</span>
                <span className="grv-winner-addr">{shortAddr(top.address)}</span>
                <span className="grv-winner-pot">{fmtAmount(top.payout, 4)}</span>
                <span className="grv-winner-sub">mixETH · {Number.isInteger(top.sharePercent) ? top.sharePercent : top.sharePercent.toFixed(2)}% of the pot</span>
                {connected && round.claimablePot > 0n ? (
                  <button type="button" className="stc-btn stc-btn-primary" disabled={claiming} onClick={async () => {
                    setClaiming(true); setRedeemErr(null)
                    try { await writeContractAsync({ address: round.hook, abi: hookAbi, functionName: 'claimPot' }, false, { victory: { roundId: round.roundId, roundName: round.name, staker: round.staker } }) }
                    catch (e) { setRedeemErr(e instanceof Error ? e.message : 'Pot claim failed') }
                    finally { setClaiming(false) }
                  }}>
                    {claiming ? 'claiming…' : `claim ${fmtAmount(round.claimablePot)} mixETH ladder winnings`}
                  </button>
                ) : <span className="grv-hall-note">{connected ? '' : 'connect your wallet to claim winnings.'}</span>}
              </div>
            </div>
          )}
        </div>
      </section>

      {round.unclaimedPredeposit && (
        <button type="button" className="stc-btn grv-banner" disabled={claiming} onClick={async () => {
          setClaiming(true); setRedeemErr(null)
          try { await writeContractAsync({ address: round.controller, abi: controllerAbi, functionName: 'claimPredepositPSP' }, false, hatchFx) }
          catch (e) { setRedeemErr(e instanceof Error ? e.message : 'Predeposit claim failed') }
          finally { setClaiming(false) }
        }}>{claiming ? 'claiming…' : 'claim your predeposit position, then unlock below'}</button>
      )}
      {exitReady && (
        <div className="grv-exit">
          <p className="stv-copy">
            {exitLine} — all in one transaction. approvals are bundled: atomic wallets sign once.
          </p>
          <button type="button" className="stc-btn" disabled={exitStep === 'sign'} data-pending={exitStep === 'sign' || undefined} onClick={() => { void exitRound() }}>
            {exitStep === 'sign' ? 'exiting…' : exitStep === 'done' ? '✓ exited' : 'exit round — one transaction'}
          </button>
          {exitErr && <p role="alert" className="stc-note stc-crit">{exitErr}</p>}
        </div>
      )}
      <ReferralRewards roundId={round.roundId} className="grv-referrals" />

      <section className="grv-paperwork" aria-label={`your paperwork for round ${round.roundId.toString()}`}>
        <div className="grv-paperwork-head">
          <h2>your paperwork · round {round.roundId.toString()}</h2>
          <span className="stv-copy">take your time. redemption, withdrawals and claims stay open.</span>
        </div>
        <div className="grv-forms">
          <article className="grv-form">
            <div className="grv-form-head"><span>FORM R-{round.roundId.toString()}</span><span>redemption</span></div>
            <div className="grv-form-body">
              <h3>redeem your psp</h3>
              <p className="stv-copy">burn round-{round.roundId.toString()} PSP for its share of this round's remaining mixETH. payouts are rounded down; the remainder stays in the reserves.</p>
              <div className="grv-form-rows">
                <div className="grv-form-row"><span>your balance</span><span>{round.pspBal === 0n ? '—' : `${fmtAmount(round.pspBal)} PSP`}</span></div>
                <div className="grv-form-row"><span>redeems for</span><span>{estOut === undefined ? '—' : `${fmtAmount(estOut)} mixETH`}</span></div>
              </div>
              <div className="grv-form-actions">
                {!isConnected ? (
                  <p className="stv-copy">connect wallet to check.</p>
                ) : !redeemable ? (
                  <p className="stv-copy">your wallet holds 0 PSP from this round.</p>
                ) : (
                  <button type="button" className="stc-btn stc-btn-primary" onClick={redeem}
                    disabled={redeemStep !== 'idle' && redeemStep !== 'done'}
                    data-pending={(redeemStep === 'approve' || redeemStep === 'redeem') || undefined}>
                    {redeemStep === 'approve' ? 'approving…' : redeemStep === 'redeem' ? 'redeeming…' : redeemStep === 'done' ? '✓ redeemed' : needsAllowance ? `approve ${fmtAmount(round.pspBal)} PSP` : `redeem ${fmtAmount(round.pspBal)} PSP`}
                  </button>
                )}
                {redeemErr && <p role="alert" className="stc-note stc-crit">{redeemErr}</p>}
              </div>
            </div>
          </article>

          <article className="grv-form">
            <div className="grv-form-head"><span>FORM L-{round.roundId.toString()}</span><span>release</span></div>
            <div className="grv-form-body">
              <h3>lePSP positions</h3>
              <p className="stv-copy">detonation opened every lock. unlock your PSP and redeem it above. earned mixETH stays claimable after detonation.</p>
              {stakedPositions.length === 0 ? (
                <p className="stv-copy">{!isConnected ? 'connect wallet to see your pepes.' : 'no locked positions for this round.'}</p>
              ) : (
                <ul className="grv-pos-list">
                  {stakedPositions.map(pos => {
                    const busy = unlocking.has(pos.id.toString())
                    return (
                      <li key={pos.id.toString()} className="grv-pos">
                        <GraveArt staker={round.staker} id={pos.id} />
                        <div className="grv-pos-info">
                          <p className="grv-pos-id" title={pos.id.toString()}>pepe #{fmtPepeId(pos.id)}</p>
                          <p className="micro-label">{fmtAmount(pos.amount)} lePSP</p>
                        </div>
                        <div className="grv-pos-actions">
                          {pos.pendingFees > 0n && (
                            <button type="button" className="stc-btn" disabled={busy} onClick={() => unlock(pos.id, 0n)}>
                              {busy ? 'confirming…' : `claim ${fmtAmount(pos.pendingFees, 4)} mixETH`}
                            </button>
                          )}
                          <button type="button" className="stc-btn" disabled={busy} onClick={() => unlock(pos.id, pos.amount)}>
                            {busy ? 'confirming…' : 'unlock PSP'}
                          </button>
                        </div>
                        <GravePositionDetails round={round} id={pos.id} amount={pos.amount} />
                      </li>
                    )
                  })}
                </ul>
              )}
            </div>
          </article>

          <article className="grv-form">
            <div className="grv-form-head"><span>FORM D-{round.roundId.toString()}</span><span>collection</span></div>
            <div className="grv-form-body">
              <h3>dead pepe collection</h3>
              <p className="stv-copy">unlocked, still yours. these pepes carry the scars of past rounds.</p>
              {deadPositions.length === 0 ? (
                <p className="stv-copy">{!isConnected ? 'connect wallet to see your collection.' : 'your collection is empty for this round.'}</p>
              ) : (
                <ul className="grv-dead-list">
                  {deadPositions.map(pos => {
                    const busy = unlocking.has(pos.id.toString())
                    return (
                      <li key={pos.id.toString()} className="grv-dead">
                        <div className="grv-dead-art">
                          <GraveArt staker={round.staker} id={pos.id} />
                          <span className="grv-dead-tag" aria-hidden="true">r{round.roundId.toString()} ✝</span>
                        </div>
                        <div className="grv-pos-actions">
                          {pos.pendingFees > 0n && (
                            <button type="button" className="stc-btn" disabled={busy} onClick={() => unlock(pos.id, 0n)}>
                              {busy ? 'confirming…' : `claim ${fmtAmount(pos.pendingFees, 4)} mixETH`}
                            </button>
                          )}
                          <GravePositionDetails round={round} id={pos.id} amount={pos.amount} />
                        </div>
                      </li>
                    )
                  })}
                </ul>
              )}
            </div>
          </article>
        </div>
        {unlockErr && <p role="alert" className="stc-note stc-crit">{unlockErr}</p>}
      </section>
    </div>
  )
}

export default function AltGraveyardView({ rounds, checked, error, connected }: {
  rounds: GraveyardRound[]
  checked: boolean
  error: string | null
  connected: boolean
}) {
  const nextRound = rounds.reduce((max, r) => (r.roundId > max ? r.roundId : max), 0n) + 1n
  return (
    <div className="grv-page">
      <header className="ref-pageref grv-head">
        <div>
          <h1>the graveyard</h1>
          <p className="ref-serif">even a dead round has receipts.</p>
        </div>
        <p className="grv-head-copy">claim ladder winnings, withdraw old stakes, and redeem PSP for its share of that round's remaining mixETH. payouts are rounded down and can be worth less than you paid.</p>
      </header>

      {error && <p role="alert" className="stc-note stc-crit">{error}</p>}

      {!checked ? (
        <p role="status" className="grv-status">checking the graveyard…</p>
      ) : rounds.length === 0 ? (
        <section className="grv-empty" aria-label="empty graveyard">
          <div className="grv-empty-pepe" aria-hidden="true" />
          <div>
            <p>the graveyard is waiting for its first customer.</p>
            <p className="stv-copy">past rounds and their pots appear here. unlock positions, claim winnings, and redeem below.</p>
          </div>
        </section>
      ) : (
        <>
          {rounds.map(round => <AltDeadRound key={`${round.hook}:${round.roundId}`} round={round} connected={connected} />)}
          <Link className="grv-next" to="/play">
            <span className="grv-next-label">round {nextRound.toString()} · receipt not printed yet</span>
            <span className="grv-next-cta">sign its birth certificate ↗</span>
          </Link>
          {!connected && <p className="grv-status">connect your wallet to see your positions per round.</p>}
        </>
      )}
    </div>
  )
}
