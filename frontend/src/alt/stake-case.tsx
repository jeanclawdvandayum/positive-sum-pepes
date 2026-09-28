// ─────────────────────────────────────────────────────────────────────────────
// stake-case — the refined stake page's per-position "case file" card
// (out/rendered-2/3 + dark 7/8). Art | mono data rows | claim panel, with the
// ACCOMPLICE / SKIPPING TOWN stamps and the six-epoch exit track.
//
// The action set is PepeCard's, carried over unchanged — claim, reinvest
// (with its approvals), request/cancel/withdraw, the PositionTopUp flow and
// PositionNftControls. Only the composition is new. Shared components stay
// untouched; this is the alt presentation of the same contract calls.
// ─────────────────────────────────────────────────────────────────────────────
import { useEffect, useMemo, useRef, useState } from 'react'
import { controllerAbi, erc20Abi, hookAbi, stakerAbi, reinvestorAbi, buildPoolKey } from '../lib/abi'
import { useAccount } from 'wagmi'
import { getAccount } from 'wagmi/actions'
import { ADDRESSES, CHAIN_ID, wagmiConfig } from '../lib/config'
import { fmtAmount, fmtCountdown, fmtPepeId } from '../lib/format'
import { minimumOutput } from '../lib/gameRules'
import { rpcCall } from '../lib/rpc'
import { userFacingRpcError } from '../lib/rpcErrors'
import { useConfirmedWrite } from '../lib/useConfirmedWrite'
import { useNow } from '../phase/PhaseEngine'
import { renderPepeSvg } from '../lib/pepeRender'
import { usePepeDna } from '../lib/usePepeDna'
import { usePepeDnaVersion } from '../lib/usePepeDnaVersion'
import { useEthUsd } from '../lib/useEthUsd'
import { parseTopUpAmount, topUpPosition, type TopUpStep } from '../lib/stakeTopUp'
import { ensureWalletChain } from '../lib/ensureWalletChain'
import PositionTopUp from '../components/PositionTopUp'
import PositionNftControls from '../components/PositionNftControls'
import { useRpcReads } from '../lib/useRpcReads'
import { useNftReinvestment } from '../lib/useNftReinvestment'
import type { NftVersion } from '../lib/nftPermissions'
import type { RoundInfo } from '../lib/useRound'
import type { PepeEntry } from '../components/PepeCards'

function CaseArt({ staker, id }: { staker: `0x${string}` | undefined; id: bigint }) {
  const version = usePepeDnaVersion(staker)
  const { data: dna, isError } = usePepeDna(staker, id)
  const svg = useMemo(() => dna === undefined || version === undefined ? undefined : renderPepeSvg(dna, version), [dna, version])
  return svg
    ? <div role="img" aria-label={`pepe ${id}`} className="stc-art-svg" dangerouslySetInnerHTML={{ __html: svg }} />
    : <div className="stc-art-svg stc-art-loading" role="img" aria-label={`pepe ${id}`}>{isError ? 'pepe image unavailable' : 'loading pepe…'}</div>
}

type CardStep = 'idle' | 'tx' | 'done'

export default function CaseFile({
  round,
  entry,
  pending,
  earned,
  vest,
  approved,
  nftVersion,
  walletBalance,
  alias,
  totalLocked,
  onDone,
}: {
  round: RoundInfo
  entry: PepeEntry
  pending: bigint | undefined
  earned: bigint | undefined
  vest: bigint | undefined
  approved: boolean | undefined
  nftVersion: NftVersion
  walletBalance: bigint | undefined
  alias: string
  totalLocked: bigint | undefined
  onDone: () => void
}) {
  const { address, isConnected } = useAccount()
  const { writeContractAsync, writeWithApprovals, atomicWallet } = useConfirmedWrite()
  const ethUsd = useEthUsd()
  const [step, setStep] = useState<CardStep>('idle')
  const [error, setError] = useState<string | null>(null)
  const [nftBusy, setNftBusy] = useState(false)
  const [nftRefresh, setNftRefresh] = useState(0)
  const [tokenApproved] = useRpcReads([{ to: round.staker, abi: stakerAbi, functionName: 'getApproved', args: [entry.id] }], nftVersion === 1, 6000, nftRefresh)
  const approvedForPepe = approved === true || (typeof tokenApproved === 'string' && tokenApproved.toLowerCase() === ADDRESSES.reinvestor.toLowerCase())
  const nftReinvestment = useNftReinvestment(round.staker, nftVersion)
  const refreshNft = () => { setNftRefresh(key => key + 1); onDone() }
  const [topUpOpen, setTopUpOpen] = useState(false)
  const [topUpAmount, setTopUpAmount] = useState('')
  const [topUpStep, setTopUpStep] = useState<TopUpStep | undefined>()
  const [topUpSuccess, setTopUpSuccess] = useState<string | null>(null)
  const mounted = useRef(true)
  const topUpInFlight = useRef(false)
  useEffect(() => {
    mounted.current = true
    return () => { mounted.current = false }
  }, [])
  /// shared PhaseEngine heartbeat — same cadence as the play clock
  const now = useNow()

  const { id, amount, requestEpoch } = entry
  const epoch = vest ? vest / 6n : undefined // VEST_EPOCHS = 6 in the staker
  const decaying = entry.withdrawing === true
  const vestEnd = decaying && epoch ? Number((requestEpoch + 6n) * epoch) : undefined // (r+6)·epochSize
  const decayed = vestEnd !== undefined && now >= vestEnd
  const epochsDone = !decaying || !epoch ? 0
    : Math.max(0, Math.min(6, Number(BigInt(Math.floor(now / Number(epoch))) - requestEpoch)))
  const nextStepIn = decaying && !decayed && epoch && epochsDone < 6
    ? fmtCountdown(Number((requestEpoch + BigInt(epochsDone) + 1n) * epoch) - now)
    : undefined

  const valueMix = round.marginalPrice ? (amount * round.marginalPrice) / 10n ** 18n : undefined
  const valueUsd = valueMix !== undefined && ethUsd ? (Number(valueMix) / 1e18) * ethUsd : undefined
  const sharePct = totalLocked !== undefined && totalLocked > 0n && amount > 0n
    ? Number((amount * 1_000_000n) / totalLocked) / 10_000
    : undefined

  const isFlat = round.flatTime !== undefined && round.flatTime > 0n
  const busy = step === 'tx' || topUpStep !== undefined || nftBusy
  const canWithdraw = amount > 0n && (isFlat || decayed)
  const canCancel = decaying && amount > 0n
  const canRequest = entry.withdrawing === false && amount > 0n && !isFlat
  const canClaim = isConnected && pending !== undefined && pending > 0n
  const canReinvest = nftVersion !== undefined && canClaim && entry.withdrawing === false && round.reinvestorReady && !isFlat && round.ticketPrice !== undefined
  const topUpBlocked = isFlat || (round.mode !== undefined && round.mode >= 2)
    ? 'This round has ended; top-ups are closed.'
    : decaying ? 'Choose "keep staking" to cancel withdrawal before adding PSP.'
      : entry.withdrawing === undefined || round.mode === undefined || !round.token || !round.controller || !round.hook
        ? 'Loading position…'
        : !isConnected ? 'Connect your wallet to add PSP.'
          : round.rulesCompatible !== true ? 'Waiting for deployment verification…' : undefined

  async function addPsp() {
    if (busy || topUpInFlight.current || topUpBlocked || !address || !round.staker || !round.token || !round.controller || !round.hook) return
    const addition = parseTopUpAmount(topUpAmount)
    if (!addition) return
    const owner = address
    const { staker, token, controller, hook } = round
    topUpInFlight.current = true
    setStep('idle')
    setError(null)
    setTopUpSuccess(null)
    try {
      await ensureWalletChain(owner, CHAIN_ID)
      await topUpPosition({ owner, staker, id, amount: addition }, {
        assertSession: () => {
          const account = getAccount(wagmiConfig)
          if (!mounted.current || account.address?.toLowerCase() !== owner.toLowerCase() || account.chainId !== CHAIN_ID) {
            throw new Error('Wallet, network or round changed. Return to this position and try again.')
          }
        },
        read: async () => {
          const [nftOwner, withdrawing, balance, allowance, mode, flatTime] = await Promise.all([
            rpcCall(staker, stakerAbi, 'ownerOf', [id]),
            rpcCall(staker, stakerAbi, 'isWithdrawing', [id]),
            rpcCall(token, erc20Abi, 'balanceOf', [owner]),
            rpcCall(token, erc20Abi, 'allowance', [owner, staker]),
            rpcCall(hook, hookAbi, 'mode'),
            rpcCall(controller, controllerAbi, 'flatTime'),
          ])
          return { owner: nftOwner as `0x${string}`, withdrawing: withdrawing as boolean, balance: balance as bigint,
            allowance: allowance as bigint, mode: Number(mode), flatTime: flatTime as bigint }
        },
        atomicStake: async () => {
          if (!await atomicWallet()) return false
          await writeWithApprovals({ address: staker, abi: stakerAbi, functionName: 'stakeFor', args: [owner, id, addition] },
            [{ address: token, abi: erc20Abi, functionName: 'approve', args: [staker, addition] }])
          return true
        },
        approve: (spender, value) => writeContractAsync({ address: token, abi: erc20Abi, functionName: 'approve', args: [spender, value] }),
        stake: (user, pepeId, value) => writeContractAsync({ address: staker, abi: stakerAbi, functionName: 'stakeFor', args: [user, pepeId, value] }),
        onStep: next => { if (mounted.current) setTopUpStep(next) },
      })
      if (mounted.current) {
        setTopUpOpen(false)
        setTopUpAmount('')
        setTopUpSuccess(`✓ Added ${fmtAmount(addition, 6)} PSP to pepe #${fmtPepeId(id)}.`)
        onDone()
      }
    } catch (err) {
      const friendly = userFacingRpcError(err)
      if (mounted.current) setError(friendly instanceof Error ? friendly.message.slice(0, 220) : 'Could not add PSP. Try again.')
    } finally {
      topUpInFlight.current = false
      if (mounted.current) setTopUpStep(undefined)
    }
  }

  async function act(fn: 'requestWithdraw' | 'cancelWithdraw' | 'withdraw' | 'claimFees') {
    setError(null)
    try {
      setStep('tx')
      await writeContractAsync({ address: round.staker!, abi: stakerAbi, functionName: fn, args: [id] })
      setStep('done')
      onDone()
      setTimeout(() => setStep('idle'), 2500)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 120) : 'tx failed')
      setStep('idle')
    }
  }

  async function reinvest() {
    setError(null)
    try {
      setStep('tx')
      const approvals = await nftReinvestment.prepare([id])
      setNftRefresh(key => key + 1)
      const key = buildPoolKey(round.mix!, round.token!, round.hook!)
      const fees = await rpcCall(round.staker!, stakerAbi, 'pendingFeesOf', [id]) as bigint
      if (round.ticketPrice === undefined || fees < round.ticketPrice) {
        throw new Error(`Reinvest requires at least one current ticket price (${round.ticketPrice === undefined ? 'unavailable' : `${(Number(round.ticketPrice) / 1e18).toFixed(6)} mixETH`}) in accrued fees.`)
      }
      const quote = await rpcCall(round.hook!, hookAbi, 'getBuyOutput', [fees]) as bigint
      nftReinvestment.assertSession()
      await writeWithApprovals({
        address: ADDRESSES.reinvestor,
        abi: reinvestorAbi,
        functionName: 'reinvest',
        args: [id, key, minimumOutput(quote, 100), BigInt(Math.floor(Date.now() / 1000) + 600)],
      }, approvals)
      setStep('done')
      onDone()
      setTimeout(() => setStep('idle'), 2500)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 120) : 'tx failed')
      setStep('idle')
    }
  }

  const status = isFlat
    ? { text: 'every lock opened', tone: 'warn' as const }
    : decaying
      ? decayed
        ? { text: 'unlocked — withdraw anytime', tone: 'good' as const }
        : { text: `unlocking · epoch ${epochsDone} of 6`, tone: 'warn' as const }
      : { text: 'earning', tone: 'good' as const }
  const stamp = decaying
    ? { text: 'SKIPPING TOWN', tone: 'muted' as const }
    : { text: 'ACCOMPLICE', tone: 'hot' as const }

  return (
    <article className={`stc-card${decaying ? ' stc-withdrawing' : ''}`} aria-label={`lePSP position pepe ${fmtPepeId(id)}`}>
      <div className="stc-art">
        <CaseArt staker={round.staker} id={id} />
        <span className="stc-art-tag">pepe #{fmtPepeId(id)}</span>
      </div>

      <div className="stc-rows">
        <span className="micro-label">case file · lePSP position</span>
        <dl>
          <div className="stc-row"><dt>alias</dt><dd>{alias}</dd></div>
          <div className="stc-row"><dt>locked earning PSP</dt><dd>{fmtAmount(amount)} lePSP</dd></div>
          <div className="stc-row"><dt>value</dt><dd>{valueMix !== undefined ? <>≈ {fmtAmount(valueMix, 4)} mix{valueUsd !== undefined && <span className="stc-usd"> · ≈ ${valueUsd < 1 ? valueUsd.toFixed(4) : valueUsd.toFixed(2)}</span>}</> : '…'}</dd></div>
          <div className="stc-row"><dt>stream share</dt><dd>{sharePct !== undefined ? <>{sharePct < 1 ? sharePct.toFixed(4) : sharePct.toFixed(2)}% of the 60%</> : '…'}</dd></div>
          <div className="stc-row"><dt>fees earned</dt><dd>{earned === undefined ? '…' : <>{fmtAmount(earned, 4)} mixETH total</>}</dd></div>
          <div className="stc-row stc-row-last"><dt>status</dt><dd className={`stc-status stc-${status.tone}`}>{status.text}</dd></div>
        </dl>
        <PositionTopUp id={id} balance={walletBalance} value={topUpAmount} open={topUpOpen} busy={busy}
          step={topUpStep} blockedReason={topUpBlocked} onValue={setTopUpAmount}
          onToggle={() => { setTopUpOpen(!topUpOpen); setTopUpSuccess(null); setError(null) }} onSubmit={addPsp} />
        {topUpSuccess && <p role="status" className="stc-note stc-good">{topUpSuccess}</p>}
        {round.staker && <PositionNftControls staker={round.staker} roundId={round.id} id={id} amount={amount}
          version={nftVersion} approved={tokenApproved as `0x${string}` | undefined} approvedAll={approved}
          disabled={busy} onBusy={setNftBusy} onDone={refreshNft} />}
      </div>

      <div className="stc-claim">
        <div className="stc-claim-head">
          <span className="micro-label">claimable now</span>
          <span className="stc-claim-amt stc-good">{fmtAmount(pending ?? 0n, 4)}</span>
          <span className="micro-label">mixETH</span>
        </div>
        {decaying && !decayed && (
          <div className="stc-vest">
            <span className="micro-label">six-epoch exit · epoch {epochsDone} of 6</span>
            <div className="stc-vest-track" aria-hidden="true">
              {Array.from({ length: 6 }, (_, i) => (
                <span key={i} className={`stc-vest-cell${i < epochsDone ? ' done' : i === epochsDone ? ' now' : ''}`} />
              ))}
            </div>
            <span className="micro-label">{nextStepIn ? `next step unlocks in ~${nextStepIn}` : 'final epoch — withdraw opens at the buzzer'}</span>
          </div>
        )}
        <button type="button" className="stc-btn stc-btn-primary" disabled={busy || !canClaim} onClick={() => act('claimFees')}>
          {step === 'done' ? '✓ claimed' : busy ? 'confirm…' : `claim ${fmtAmount(pending ?? 0n, 4)} mixETH`}
        </button>
        {canRequest && (
          <div className="stc-actions">
            {round.reinvestorReady && (
              <button type="button" className="stc-btn" disabled={busy || !canReinvest} onClick={reinvest}>
                {step === 'done' ? '✓' : busy ? 'confirm…' : approvedForPepe ? '↻ reinvest' : 'approve & reinvest'}
              </button>
            )}
            <button type="button" className="stc-btn" disabled={busy || !canRequest} onClick={() => act('requestWithdraw')}
              title="start this round's withdrawal schedule">
              request unlock
            </button>
          </div>
        )}
        {canCancel && !decayed && (
          <div className="stc-actions">
            <button type="button" className="stc-btn" disabled={busy || !canCancel} onClick={() => act('cancelWithdraw')}
              title="cancel withdrawal and restore full staking weight">
              ↩ keep staking
            </button>
          </div>
        )}
        {canWithdraw && (
          <button type="button" className="stc-btn" disabled={busy || !canWithdraw} onClick={() => act('withdraw')}
            title={isFlat || decayed ? 'withdraw principal' : 'withdrawable after the vest'}>
            withdraw released PSP
          </button>
        )}
        {round.reinvestorReady && !approvedForPepe && canRequest && <p className="stc-note">
          {nftVersion === 1 ? 'Approve this Pepe for reinvestment. Permission covers its transfers and fee claims.'
            : nftVersion === 0 ? 'This older round requires approval for all your Pepes: transfers and fee claims.' : 'Checking approval support…'}
        </p>}
        {error && <p role="alert" className="stc-note stc-crit">{error}</p>}
      </div>

      <div className={`stc-stamp stc-stamp-${stamp.tone}`} aria-hidden="true">{stamp.text}</div>
    </article>
  )
}
