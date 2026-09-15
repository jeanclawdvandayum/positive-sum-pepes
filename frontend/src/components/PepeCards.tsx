import { usePepeDnaVersion } from '../lib/usePepeDnaVersion'
import { ensureWalletChain } from '../lib/ensureWalletChain'
import { rpcCall } from '../lib/rpc'
import { minimumOutput } from '../lib/gameRules'
import { useConfirmedWrite } from '../lib/useConfirmedWrite'
import { useEffect, useMemo, useRef, useState } from 'react'
import { useAccount } from 'wagmi'
import { getAccount } from 'wagmi/actions'
import { ADDRESSES, CHAIN_ID, wagmiConfig } from '../lib/config'
import { controllerAbi, erc20Abi, hookAbi, stakerAbi, reinvestorAbi, buildPoolKey } from '../lib/abi'
import { fmtAmount, fmtCountdown, fmtPepeId } from '../lib/format'
import { useNow } from '../phase/PhaseEngine'
import { renderPepeSvg } from '../lib/pepeRender'
import { usePepeDna } from '../lib/usePepeDna'
import MixLogo from './MixLogo'
import type { RoundInfo } from '../lib/useRound'
import { useEthUsd } from '../lib/useEthUsd'
import { parseTopUpAmount, topUpPosition, type TopUpStep } from '../lib/stakeTopUp'
import { userFacingRpcError } from '../lib/rpcErrors'
import PositionTopUp from './PositionTopUp'
import PositionNftControls from './PositionNftControls'
import { useRpcReads } from '../lib/useRpcReads'
import { useNftReinvestment } from '../lib/useNftReinvestment'
import type { NftVersion } from '../lib/nftPermissions'

/// One card per staked pepe. Rows: art · amount + value · unlock state ·
/// [cancel-request|withdraw] · [claim – X mixETH] [reinvest].

export interface PepeEntry {
  id: bigint
  amount: bigint
  requestEpoch: bigint
  withdrawing: boolean | undefined
}

type CardStep = 'idle' | 'tx' | 'done'

function Art({ id, staker }: { id: bigint; staker?: `0x${string}` }) {
  const version = usePepeDnaVersion(staker)
  const { data: dna, isError } = usePepeDna(staker, id)
  const svg = useMemo(() => dna === undefined || version === undefined ? undefined : renderPepeSvg(dna, version), [dna, version])
  if (!svg) return <div className="flex h-32 items-center justify-center rounded-xl bg-bg-2 text-xs text-text-lo">
    {isError ? 'pepe image unavailable' : 'loading pepe…'}
  </div>
  return (
    <div
      className="flex h-32 items-center justify-center rounded-xl bg-bg-2 [&>svg]:h-28 [&>svg]:w-28"
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  )
}

export function PepeCard({
  round,
  entry,
  vest,
  pending,
  isFlat,
  approved,
  nftVersion,
  walletBalance,
  onDone,
}: {
  round: RoundInfo
  entry: PepeEntry
  vest: bigint | undefined
  pending: bigint | undefined
  isFlat: boolean
  approved: boolean | undefined
  nftVersion: NftVersion
  walletBalance: bigint | undefined
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
  /// shared PhaseEngine heartbeat (B0 refactor — was its own 1s setInterval)
  const now = useNow()

  const { id, amount, requestEpoch } = entry
  const epoch = vest ? vest / 6n : undefined // VEST_EPOCHS = 6 in the staker
  const decaying = entry.withdrawing === true
  const vestEnd = decaying && epoch ? Number((requestEpoch + 6n) * epoch) : undefined // (r+6)·epochSize
  const decayed = vestEnd !== undefined && now >= vestEnd
  // stepped power mirror: weight(k) = base - k·slope, k = epochs past request
  const powerLeft = !decaying || !epoch ? undefined : now >= vestEnd! ? 0 : (() => {
    const k = BigInt(Math.floor(now / Number(epoch))) - requestEpoch
    if (k >= 6n) return 0
    const base = amount - (amount % 6n)
    const slope = base / 6n
    const w = base - k * slope
    return Number((w * 10000n) / amount) / 100
  })()

  const valueMix = round.marginalPrice ? (amount * round.marginalPrice) / 10n ** 18n : undefined
  const valueUsd = valueMix !== undefined && ethUsd ? (Number(valueMix) / 1e18) * ethUsd : undefined

  const busy = step === 'tx' || topUpStep !== undefined || nftBusy
  const canWithdraw = amount > 0n && (isFlat || decayed)
  const canCancel = decaying && amount > 0n
  const canRequest = entry.withdrawing === false && amount > 0n && !isFlat
  const canClaim = isConnected && pending !== undefined && pending > 0n
  const canReinvest = nftVersion !== undefined && canClaim && entry.withdrawing === false && round.reinvestorReady && !isFlat && round.ticketPrice !== undefined
  const topUpBlocked = isFlat || (round.mode !== undefined && round.mode >= 2)
    ? 'This round has ended; top-ups are closed.'
    : decaying ? 'Choose “keep staking” to cancel withdrawal before adding PSP.'
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
    } catch (error) {
      const friendly = userFacingRpcError(error)
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

  const dateStr = (ts: number) => new Date(ts * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })

  return (
    <div className="flex min-w-0 flex-col gap-3 rounded-2xl border border-line bg-bg-1 p-4">
      <div className="flex items-center justify-between">
        <span title={id.toString()} className="font-data text-xs text-text-lo">pepe #{fmtPepeId(id)}</span>
        {amount === 0n && <span className="text-[10px] text-text-lo">unstaked pepe</span>}
        {decaying && !decayed && (
          <span className="text-[10px] font-semibold text-phase-heat">{powerLeft !== undefined ? `${powerLeft}% power` : 'decaying'}</span>
        )}
        {decayed && <span className="text-[10px] font-semibold text-pepe">fully unlocked</span>}
      </div>

      <Art id={id} staker={round.staker} />

      <div className="grid grid-cols-2 gap-2 text-sm">
        <div>
          <div className="text-[10px] text-text-lo">lePSP</div>
          <div className="font-data text-text-hi">{fmtAmount(amount)}</div>
        </div>
        <div className="text-right">
          <div className="text-[10px] text-text-lo">value</div>
          <div className="font-data text-text-hi">
            {valueMix !== undefined ? (
              <>
                ≈{fmtAmount(valueMix, 4)} <MixLogo />
              </>
            ) : (
              '…'
            )}
          </div>
          {valueUsd !== undefined && (
            <div className="text-[10px] text-text-lo">≈ ${valueUsd < 1 ? valueUsd.toFixed(4) : valueUsd.toFixed(2)}</div>
          )}
        </div>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 rounded-lg bg-bg-2 px-3 py-2 text-xs">
        <span className="text-text-lo">
          {isFlat ? 'bomb opened all locks' : decaying ? (decayed ? 'unlocked' : 'unlocks (vesting)') : 'indefinite lock'}
        </span>
        <span className="font-semibold text-accent">
          {isFlat
            ? 'withdraw anytime'
            : decaying
              ? decayed
                ? 'withdraw anytime'
                : vestEnd
                  ? `${fmtCountdown(vestEnd - now)} · ${dateStr(vestEnd)}`
                  : '…'
              : 'request withdrawal to start exit'}
        </span>
      </div>

      <PositionTopUp id={id} balance={walletBalance} value={topUpAmount} open={topUpOpen} busy={busy}
        step={topUpStep} blockedReason={topUpBlocked} onValue={setTopUpAmount}
        onToggle={() => { setTopUpOpen(!topUpOpen); setTopUpSuccess(null); setError(null) }} onSubmit={addPsp} />
      {topUpSuccess && <p role="status" className="text-xs text-pepe">{topUpSuccess}</p>}

      <div className="grid grid-cols-2 gap-2">
        <button
          className="st-btn text-xs"
          disabled={busy || (decaying ? !canCancel : !canRequest)}
          onClick={() => act(decaying ? 'cancelWithdraw' : 'requestWithdraw')}
          title={decaying ? 'cancel withdrawal and restore full staking weight' : 'start this round’s withdrawal schedule'}
        >
          {decaying ? '↩ keep staking' : 'request withdraw'}
        </button>
        <button
          className="st-btn text-xs"
          disabled={busy || !canWithdraw}
          onClick={() => act('withdraw')}
          title={decaying ? (decayed || isFlat ? 'withdraw principal' : 'withdrawable after the vest') : 'request a withdraw first'}
        >
          <span className={canWithdraw ? '' : 'opacity-50'}>withdraw</span>
        </button>
      </div>

      <div className="grid grid-cols-2 gap-2">
        <button className="st-btn st-btn-primary text-xs" disabled={busy || !canClaim} onClick={() => act('claimFees')}>
          {step === 'done' ? '✓ claimed' : `claim — ${fmtAmount(pending, 4) || '0'} mixETH`}
        </button>
        {round.reinvestorReady && (
          <button className="st-btn text-xs" disabled={busy || !canReinvest} onClick={reinvest}>
            {step === 'done' ? '✓' : busy ? 'confirm…' : approvedForPepe ? '↻ reinvest' : 'approve & reinvest'}
          </button>
        )}
      </div>

      {round.reinvestorReady && !approvedForPepe && <p className="text-[10px] text-text-lo">
        {nftVersion === 1 ? 'Approve this Pepe for reinvestment. Permission covers its transfers and fee claims.'
          : nftVersion === 0 ? 'This older round requires approval for all your Pepes: transfers and fee claims.' : 'Checking approval support…'}
      </p>}
      {round.staker && <PositionNftControls staker={round.staker} roundId={round.id} id={id} amount={amount}
        version={nftVersion} approved={tokenApproved as `0x${string}` | undefined} approvedAll={approved}
        disabled={busy} onBusy={setNftBusy} onDone={refreshNft} />}

      {error && <div className="break-words text-[10px] text-phase-critical">{error}</div>}
    </div>
  )
}

export default function PepeCards({
  round,
  entries,
  pendings,
  vest,
  approved,
  nftVersion,
  walletBalance,
  onDone,
}: {
  round: RoundInfo
  entries: PepeEntry[]
  pendings: Map<bigint, bigint | undefined>
  vest: bigint | undefined
  approved: boolean | undefined
  nftVersion: NftVersion
  walletBalance: bigint | undefined
  onDone: () => void
}) {
  const isFlat = round.flatTime !== undefined && round.flatTime > 0n
  const { address } = useAccount()
  return (
    <div className="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2">
      {entries.map((e) => (
        <PepeCard
          key={`${address}:${round.staker}:${e.id}`}
          round={round}
          entry={e}
          vest={vest}
          pending={pendings.get(e.id)}
          isFlat={isFlat}
          approved={approved}
          nftVersion={nftVersion}
          walletBalance={walletBalance}
          onDone={onDone}
        />
      ))}
    </div>
  )
}
