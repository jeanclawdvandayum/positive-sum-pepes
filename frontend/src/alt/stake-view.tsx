// ─────────────────────────────────────────────────────────────────────────────
// stake-view — the refined stake page (out/rendered-2/3 light, 7/8 dark).
//
// "put your bags to work." → overview bar (open case files / total lePSP /
// claimable fees + claim-all & reinvest-all) → case-file position cards →
// the optional "choose your accomplice." lineup + deposit slip → referrals
// and the name card → the continuous stat ticker.
//
// Every hook, read, write and FX trigger stays in pages/Stake.tsx; this view
// receives them as a plain model and only composes presentation.
// ─────────────────────────────────────────────────────────────────────────────
import { useEffect, useMemo, useState, type MouseEvent, type ReactNode } from 'react'
import { useAccount } from 'wagmi'
import type { Address } from 'viem'
import { FAUCET_ENABLED } from '../lib/config'
import { fmtAmount, fmtCountdown, fmtPepeId, parseAmountToWad, wadToExact } from '../lib/format'
import { useDisplayName } from '../lib/useDisplayName'
import { renderPepeSvg } from '../lib/pepeRender'
import { usePepeDnaVersion } from '../lib/usePepeDnaVersion'
import AmountSlider from '../components/AmountSlider'
import MixLogo from '../components/MixLogo'
import PepePicker, { dnaOfId } from '../components/PepePicker'
import TickerBar, { type TickerItem } from '../components/TickerBar'
import { useCanRefer, refLinkFor, useReferral } from '../components/ReferralCard'
import ReferralShare from '../components/ReferralShare'
import ReferralRewards from '../components/ReferralRewards'
import { fireFx } from '../lib/actionFx'
import { useRound } from '../lib/useRound'
import { nameNamespace } from '../lib/nameConfig'
import { RandomPepe } from './AltCommon'
import NameRegistrationCard from '../pages/stake/NameRegistrationCard'
import CaseFile from './stake-case'
import type { NftVersion } from '../lib/nftPermissions'
import type { RoundInfo } from '../lib/useRound'
import type { PepeEntry } from '../components/PepeCards'

const ZERO = '0x0000000000000000000000000000000000000000' as const

export interface AltStakeModel {
  round: RoundInfo
  isConnected: boolean
  address: `0x${string}` | undefined
  entries: PepeEntry[]
  pendings: Map<bigint, bigint | undefined>
  earnedOf: Map<bigint, bigint | undefined>
  vest: bigint | undefined
  nftVersion: NftVersion
  reinvestApproved: boolean | undefined
  pspBal: bigint | undefined
  refresh: () => void
  totalStaked: bigint
  sharePct: number | undefined
  totalEarned: bigint | undefined
  totalPending: bigint
  parked: bigint
  multiclaim: () => void
  reinvestAll: () => void
  multiStep: 'idle' | 'tx' | 'done'
  reinvestorReady: boolean
  ticketPrice: bigint | undefined
  reinvestPending: bigint
  stakeableCount: number
  withdrawingCount: number
  withdrawingFees: bigint
  amount: string
  setAmount: (value: string) => void
  busy: boolean
  approved: boolean
  hasPepes: boolean
  canSubmit: boolean
  mainLabel: string
  run: (fn: 'lock' | 'lockWithPepe', needsApproval?: boolean) => void
  hatch: () => void
  step: 'idle' | 'approve' | 'tx' | 'done'
  pickedId: bigint | null
  setPickedId: (id: bigint | null) => void
  pickerSeed: number
  reroll: () => void
  claimable: boolean
  myDep: { mixETHAmount: bigint; claimed: boolean } | undefined
  canChooseGenesis: boolean
  genesisPepe: bigint | null
  setGenesisPepe: (id: bigint | null) => void
  genesisSeed: number
  rerollGenesis: () => void
  claimStep: 'idle' | 'tx' | 'done' | 'err'
  claimGenesis: () => void
  drip: () => void
  dripStep: 'idle' | 'tx' | 'done'
  error: string | null
  tickerItems: TickerItem[]
}

/// The deposit slip's left pane — the picked candidate's face, rendered from
/// the same DNA the picker previewed (unminted art is derived, never stored).
function SlipPreview({ round, picked }: { round: RoundInfo; picked: bigint | null }) {
  const version = usePepeDnaVersion(round.staker)
  const svg = useMemo(
    () => picked === null || version === undefined ? undefined : renderPepeSvg(dnaOfId(picked), version),
    [picked, version],
  )
  if (picked === null) return (
    <div className="stv-slip-preview stv-slip-empty" aria-hidden="true">
      <span>?</span>
    </div>
  )
  return (
    <div className="stv-slip-preview" role="img" aria-label={`picked pepe ${picked}`}
      dangerouslySetInnerHTML={{ __html: svg ?? '<svg viewBox="0 0 69 69" />' }} />
  )
}

/// The referral column's chain illustration + link row (mockup F-2/3, G-7/8):
/// their trade → you · 80% → upline · 20%. State is ReferralsCard's — same
/// useReferral/useCanRefer reads, same clipboard + refLink FX on copy.
function ReferralPanel() {
  const round = useRound()
  const { isConnected } = useAccount()
  const { pepeIds, registry, version } = useReferral()
  const [selected, setSelected] = useState<bigint | null>(null)
  const [copied, setCopied] = useState(false)
  const ids = useMemo(() => [...pepeIds].sort((a, b) => (a < b ? -1 : 1)), [pepeIds])
  const active = selected !== null && ids.includes(selected) ? selected : (ids[0] ?? null)
  const canRefer = useCanRefer(registry, active)
  const link = active !== null && registry && version === 1n ? refLinkFor(active, registry) : ''

  useEffect(() => {
    if (!copied) return
    const t = setTimeout(() => setCopied(false), 2000)
    return () => clearTimeout(t)
  }, [copied])

  async function copyLink(event: MouseEvent<HTMLButtonElement>) {
    const anchor = event.currentTarget
    try {
      await navigator.clipboard.writeText(link)
      fireFx('refLink', { anchor })
      setCopied(true)
    } catch {
      window.prompt('copy your referral link', link)
      setCopied(true)
    }
  }

  return (
    <div className="stv-ref" aria-label="referrals">
      {version === 0n && <p className="stv-copy">referral links open with the next testnet deployment.</p>}
      <p className="stv-copy">
        connect your wallet to share your pepe's referral link. referral chains share 5% of trading fees from referred wallets.
        an eligible referral is included in their purchase and stays locked for the round. the closest referrer gets 80% of the referral share; the other tiers split the rest.
      </p>

      <div className="stv-refchart" aria-hidden="true">
        <svg className="stv-ref-path" viewBox="0 0 560 180" preserveAspectRatio="none"><path d="M110 70 L280 50 L450 80" /></svg>
        <div className="stv-ref-chip their"><RandomPepe /><span>their trade</span></div>
        <div className="stv-ref-chip you"><RandomPepe /><span>you · 80%</span></div>
        <div className="stv-ref-chip upline"><RandomPepe /><span>upline · 20%</span></div>
      </div>

      <div className="stv-reflink">
        <span className="stv-reflink-box">{link || '[your-link]/r/yourname'}</span>
        <button type="button" className="stc-btn stc-btn-primary" disabled={!link || canRefer !== true} onClick={copyLink}>
          {copied ? 'copied ✓' : 'copy link'}
        </button>
      </div>

      {isConnected && ids.length > 1 && (
        <label className="stv-ref-pick">
          <span className="micro-label">which pepe's link</span>
          <select className="stv-ref-select" value={active !== null ? active.toString() : ''} onChange={(e) => setSelected(BigInt(e.target.value))}>
            {ids.map(id => <option key={id.toString()} value={id.toString()}>pepe #{fmtPepeId(id)}</option>)}
          </select>
        </label>
      )}
      {isConnected && ids.length === 0 && <p className="stv-copy">stake a pepe to unlock referral links.</p>}
      {canRefer === false && (
        <p className="stc-note stc-crit">pepe #{active === null ? '…' : fmtPepeId(active)} needs referral eligibility before purchases can record its referral.</p>
      )}

      <ReferralShare tokenId={active} link={link} enabled={canRefer === true} />
      <p className="stv-copy">the closest referrer gets 80% of the referral share. the other tiers split the rest. each referred trade pays the chain.</p>
      <ReferralRewards roundId={round.id} className="stv-ref-rewards" />
    </div>
  )
}

/// The 'HELLO my name is' tag (mockup F-2/3, G-7/8) — shows the wallet's
/// verified name when one exists, the placeholder until then.
function NameTag() {
  const { address } = useAccount()
  const name = useDisplayName((address ?? ZERO) as Address, '')
  const suffix = `.${nameNamespace.parentLabel}.wei`
  const registered = name.endsWith(suffix) && name.length > suffix.length
  const label = registered ? name.slice(0, -suffix.length) : name || 'yourname'
  return (
    <div className="stv-nametag" aria-label="your pepe name tag">
      <div className="stv-nametag-top">
        <span className="stv-nametag-hello">HELLO</span>
        <span className="stv-nametag-my">my name is</span>
      </div>
      <div className="stv-nametag-body">
        <span className="stv-nametag-name">{label}</span>
        <span className="stv-nametag-suffix">{suffix}</span>
      </div>
    </div>
  )
}

export default function AltStakeView({ model }: { model: AltStakeModel }) {
  const [creating, setCreating] = useState(false)
  const open = !model.hasPepes || creating
  const { address } = useAccount()
  const alias = useDisplayName((address ?? ZERO) as Address, 'unnamed')
  const amountWad = parseAmountToWad(model.amount)
  const multiBusy = model.multiStep === 'tx'
  const reinvestBlocked = !model.isConnected || model.ticketPrice === undefined || model.reinvestPending < model.ticketPrice || model.stakeableCount === 0 || multiBusy || model.nftVersion === undefined

  const genesis: ReactNode = model.claimable && (
    <section className="stv-genesis" aria-label="your first bag is waiting">
      <h2>your first bag is waiting</h2>
      <p className="stv-copy">
        your {fmtAmount(model.myDep!.mixETHAmount)} mixETH predeposit bought a share of the launch PSP.
        claim it into a fresh pepe NFT. your lePSP stays locked, and you keep your share of the fees earned before claiming.
      </p>
      {model.canChooseGenesis && (
        <div className="stv-genesis-picker">
          <p className="stv-copy">pick your first frog. the art is yours when the claim lands.</p>
          <PepePicker round={model.round} selected={model.genesisPepe} onSelect={model.setGenesisPepe} disabled={model.claimStep === 'tx'} actionLabel="claim"
            seed={model.genesisSeed} onReroll={model.rerollGenesis} />
          {model.genesisPepe !== null && <button type="button" className="stc-btn mt-2 w-full text-xs" disabled={model.claimStep === 'tx'} onClick={() => model.setGenesisPepe(null)}>surprise me instead</button>}
        </div>
      )}
      <button type="button" className="stc-btn stc-btn-primary" disabled={model.claimStep === 'tx' || model.busy} onClick={model.claimGenesis}>
        {model.claimStep === 'done' ? '✓ claimed' : model.claimStep === 'tx' ? 'confirm in wallet…' : model.canChooseGenesis ? (model.genesisPepe === null ? 'claim with a surprise pepe' : 'claim with this pepe') : 'claim your genesis PSP'}
      </button>
    </section>
  )

  return (
    <div className="stv-page alt-stake">
      <header className="ref-pageref stv-head">
        <h1>put your bags to work.</h1>
        <p>your pepes. your lePSP. your share of the fees.</p>
      </header>

      <div className="stv-body">
        {genesis}

        <section className="stv-overview" aria-label="your staking overview">
          <div className="stv-stats">
            <div className="stv-stat">
              <span className="micro-label">open case files</span>
              <span className="stv-stat-num">{model.entries.length}</span>
            </div>
            <div className="stv-stat">
              <span className="micro-label">total lePSP</span>
              <span className="stv-stat-num">{fmtAmount(model.totalStaked)}</span>
            </div>
            <div className="stv-stat">
              <span className="micro-label">claimable fees</span>
              <span className="stv-stat-num stc-good">{fmtAmount(model.totalPending, 4)} mixETH</span>
            </div>
          </div>
          {model.hasPepes && (
            <div className="stv-overview-actions">
              <button type="button" className="stc-btn stc-btn-primary" disabled={!model.isConnected || model.totalPending === 0n || multiBusy} onClick={model.multiclaim}>
                {model.multiStep === 'done' ? '✓ claimed' : multiBusy ? 'confirm…' : 'claim all'}
              </button>
              {model.reinvestorReady && (
                <button type="button" className="stc-btn" disabled={reinvestBlocked} onClick={model.reinvestAll}>
                  {model.multiStep === 'done' ? '✓' : multiBusy ? 'confirm…' : model.reinvestApproved ? '↻ reinvest all' : 'approve & reinvest all'}
                </button>
              )}
              <button type="button" className="stc-btn stc-btn-dark" aria-expanded={creating} onClick={() => setCreating(v => !v)}>
                {creating ? 'close ✕' : '+ make new lePSP position'}
              </button>
            </div>
          )}
        </section>

        {model.hasPepes && (
          <div className="stv-cases">
            {model.entries.map(entry => (
              <CaseFile
                key={entry.id.toString()}
                round={model.round}
                entry={entry}
                pending={model.pendings.get(entry.id)}
                earned={model.earnedOf.get(entry.id)}
                vest={model.vest}
                approved={model.reinvestApproved}
                nftVersion={model.nftVersion}
                walletBalance={model.pspBal}
                alias={alias}
                totalLocked={model.round.totalLocked}
                onDone={model.refresh}
              />
            ))}
          </div>
        )}

        {model.hasPepes && (
          <p className="stv-footnote">
            reinvest locks claimed fees back into the same pepe as lePSP.
            {model.vest !== undefined ? ` requesting an unlock starts this round's six-epoch exit (about ${fmtCountdown(Number(model.vest))} for all six steps);` : ' requesting an unlock starts this round\'s six-epoch exit;'}
            {' '}detonation opens every lock early.
          </p>
        )}

        {(model.reinvestorReady && model.hasPepes) && (model.ticketPrice !== undefined && model.reinvestPending < model.ticketPrice) && (
          <p className="stv-footnote">
            reinvest needs one current ticket price of combined fees ({model.ticketPrice === undefined ? '' : `${fmtAmount(model.ticketPrice, 4)} mixETH · `}you have {fmtAmount(model.reinvestPending, 4)}) · withdrawing positions are claim-only.
          </p>
        )}
        {!model.reinvestApproved && model.reinvestorReady && model.hasPepes && model.stakeableCount > 0 && (
          <p className="stv-footnote">
            collection approval + batch reinvest · combined when your wallet supports it · permits transfers and fee claims for all Pepes in this round
          </p>
        )}
        {model.withdrawingCount > 0 && (
          <p className="stv-footnote">
            multiclaim covers all {model.entries.length} pepes. {model.withdrawingCount} {model.withdrawingCount === 1 ? 'pepe is' : 'pepes are'} withdrawing with {fmtAmount(model.withdrawingFees, 4)} mixETH in claimable fees.
            {' '}reinvest covers the other {model.stakeableCount}. cancel the withdrawal on the position to include it again.
          </p>
        )}
        {model.parked > 0n && (
          <p className="stv-footnote">{fmtAmount(model.parked, 4)} mixETH in fees is parked until this round has staked weight — the next trade attaches it.</p>
        )}

        {open && (
          <section className="stv-new" aria-label="make a new lePSP position">
            <div className="stv-lineup">
              <PepePicker
                round={model.round}
                selected={model.pickedId}
                onSelect={model.setPickedId}
                seed={model.pickerSeed}
                onReroll={model.reroll}
              />
            </div>

            <div className="stv-sliprow">
              <form className="stv-slip" aria-label="stake psp" onSubmit={e => { e.preventDefault(); if (model.canSubmit) model.run(model.pickedId !== null ? 'lockWithPepe' : 'lock', !model.approved) }}>
                <div className="stv-slip-side">
                  <SlipPreview round={model.round} picked={model.pickedId} />
                  <span className="stv-slip-caption">
                    {model.pickedId !== null ? <>pepe #{fmtPepeId(model.pickedId)} · your pick</> : 'no suspect picked yet'}
                  </span>
                </div>
                <div className="stv-slip-main">
                  <div className="stv-slip-head">
                    <h2>deposit slip</h2>
                    {!model.hasPepes && amountWad === 0n && <span className="stv-slip-badge stc-good">0 = pepe only</span>}
                  </div>
                  <div className="stv-slip-body">
                    <label className="stv-copy" htmlFor="stv-amount">
                      lock PSP with your pepe as lePSP, locked earning PSP. it earns trading fees. requesting withdrawal starts this round's six-epoch exit{model.vest !== undefined ? `, up to ${fmtCountdown(Number(model.vest))}` : ''}.
                    </label>
                    <div className="stv-amountline">
                      <input
                        id="stv-amount"
                        className="stv-input"
                        placeholder={model.hasPepes ? '0.0 — new pepe' : '0.0 — zero gets you the pepe'}
                        value={model.amount}
                        inputMode="decimal"
                        autoComplete="off"
                        onChange={(e) => model.setAmount(e.target.value.replace(/[^0-9.]/g, ''))}
                      />
                      <button type="button" className="stv-max" disabled={model.busy || model.pspBal === undefined} onClick={() => model.setAmount(wadToExact(model.pspBal))}>
                        max
                      </button>
                    </div>
                    <div className="stv-balance">
                      <button type="button" className="stv-balance-btn" title="Use full PSP balance" disabled={model.busy || model.pspBal === undefined} onClick={() => model.setAmount(wadToExact(model.pspBal))}>
                        balance {model.pspBal === undefined ? '…' : fmtAmount(model.pspBal)} · max
                      </button>
                    </div>
                    <AmountSlider amount={model.amount} maximum={model.pspBal} onChange={model.setAmount} disabled={model.busy} label="share of your PSP to stake" />
                    <button type="submit" className="stc-btn stc-btn-primary stv-submit" disabled={!model.canSubmit}>
                      {model.mainLabel}
                    </button>
                    {model.hasPepes && (
                      <button type="button" className="stc-btn" disabled={!model.isConnected || model.busy} onClick={model.hatch}>
                        {model.step === 'tx' ? 'confirm…' : 'hatch another pepe (stake 0)'}
                      </button>
                    )}
                    {!model.hasPepes && model.pickedId === null && !model.busy && model.step !== 'done' && (
                      <p className="stv-copy stv-hint">↑ pick a pepe above to enable staking</p>
                    )}
                    {model.error && <p role="alert" className="stc-note stc-crit">{model.error}</p>}
                  </div>
                </div>
              </form>

              {FAUCET_ENABLED && (
                <div className="stv-coupon">
                  <svg className="stv-coupon-cut" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true"><circle cx="6" cy="6" r="3" /><circle cx="6" cy="18" r="3" /><line x1="20" y1="4" x2="8.12" y2="15.88" /><line x1="14.47" y1="14.48" x2="20" y2="20" /><line x1="8.12" y1="8.12" x2="12" y2="12" /></svg>
                  <div className="stv-coupon-copy">
                    <span className="stv-coupon-title"><MixLogo className="stv-coupon-logo" /> faucet coupon</span>
                    <span className="micro-label">good for 1000 mixETH per click</span>
                  </div>
                  <button type="button" className="stc-btn" disabled={!model.isConnected || model.busy} onClick={model.drip}>
                    {model.dripStep === 'done' ? '✓' : model.dripStep === 'tx' ? 'confirm…' : 'get mixETH'}
                  </button>
                </div>
              )}
            </div>
          </section>
        )}

        <section className="stv-idrow" aria-label="referrals and names">
          <div className="stv-idcol">
            <h2>invite the usual suspects.</h2>
            <ReferralPanel />
          </div>
          <div className="stv-idcol">
            <h2>put a name on that face.</h2>
            <NameTag />
            <NameRegistrationCard />
          </div>
        </section>

        <div className="stv-ticker">
          <TickerBar items={model.tickerItems} />
        </div>
      </div>
    </div>
  )
}

