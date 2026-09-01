import { useMemo, useState } from 'react'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import { NavLink, useLocation, Link } from 'react-router-dom'
import { useAccount, useWriteContract } from 'wagmi'
import { renderPepeSvg, randomDna } from '../lib/pepeRender'
import { ADDRESSES, FAUCET_ENABLED } from '../lib/config'
import { faucetAbi } from '../lib/abi'
import { useRound } from '../lib/useRound'
import Clock from './Clock'
import PepeChip from './PepeChip'
import ThemeSwitcher from './ThemeSwitcher'
import MixLogo from './MixLogo'

// ─────────────────────────────────────────────────────────────────────────────
// app chrome (REDESIGN-B1 §5): nav = explainer/play/stake, active pill takes
// the PHASE accent, mini seven-segment countdown chip on non-play routes
// (click → play), Connect = quiet outlined button / connected = pepe identity
// chip. Hairline borders, no glass-gradient — discipline so the clock is loud.
// ─────────────────────────────────────────────────────────────────────────────

const baseLinks = [
  { to: '/', label: 'explainer' },
  { to: '/play', label: 'play' },
  { to: '/stake', label: 'stake' },
]

export default function Topbar() {
  const round = useRound()
  const { pathname } = useLocation()
  // a random pepe every load — the header IS the art
  const logo = useMemo(() => renderPepeSvg(randomDna()), [])
  /// predeposit page is live while the round is in (or before) its predeposit window;
  /// after launch the page stays reachable by URL for claims.
  const showPredeposit = round.mode === 0 || round.predepositClosed === false
  const links = useMemo(() => {
    if (!showPredeposit) return baseLinks
    return [...baseLinks.slice(0, 2), { to: '/predeposit', label: 'predeposit' }, baseLinks[2]]
  }, [showPredeposit])

  // the countdown chip lives everywhere EXCEPT play (the clock is the page there)
  const onPlay = pathname === '/play' || pathname === '/trade'

  return (
    <header className="sticky top-0 z-20 border-b border-line bg-bg-0/80 font-body backdrop-blur-md">
      <div className="mx-auto flex w-full max-w-6xl items-center gap-2 px-4 py-3 sm:gap-4 sm:px-6">
        <NavLink to="/" className="flex shrink-0 items-center gap-2">
          <span className="block h-8 w-8 shrink-0 overflow-hidden rounded-lg border border-line [&>svg]:h-full [&>svg]:w-full"
            style={{ imageRendering: 'pixelated' }}
            dangerouslySetInnerHTML={{ __html: logo }}
          />
          <span className="hidden font-display text-sm text-text-hi sm:block">
            positive sum pepes
          </span>
        </NavLink>

        <nav className="flex flex-1 items-center justify-center gap-1" aria-label="main">
          {links.map((l) => (
            <NavLink
              key={l.to}
              to={l.to}
              className={({ isActive }) => {
                const active = isActive || (l.to === '/play' && pathname === '/trade')
                return `rounded-full px-3 py-1.5 text-sm transition focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent ${
                  active
                    ? 'bg-accent font-semibold text-bg-0'
                    : 'text-text-lo hover:bg-bg-2 hover:text-text-hi'
                }`
              }}
            >
              {l.label}
            </NavLink>
          ))}
        </nav>

        <div className="flex shrink-0 items-center gap-2 sm:gap-3">
          {!onPlay && (
            <Link
              to="/play"
              aria-label="countdown — go to play"
              className="rounded-md focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
            >
              <Clock variant="mini" />
            </Link>
          )}
          {FAUCET_ENABLED && <FaucetButton />}
          <ThemeSwitcher />
          <Connect />
        </div>
      </div>
    </header>
  )
}

/// quiet outlined connect; connected = pepe identity chip (spec §7).
/// Identity art is the base-pepe fallback until the on-chain primary-pepe
/// lane + .wei registry land (VITE_WEI_REGISTRY pending) — the address is
/// the real identity; no new chain reads here.
function Connect() {
  return (
    <ConnectButton.Custom>
      {({ account, chain, openAccountModal, openChainModal, openConnectModal, authenticationStatus, mounted }) => {
        const ready = mounted && authenticationStatus !== 'loading'
        if (!ready) return <div className="h-8 w-24" aria-hidden="true" />
        if (!account) {
          return (
            <button
              type="button"
              onClick={openConnectModal}
              className="rounded-full border border-line px-4 py-1.5 text-sm text-text-hi transition hover:border-accent hover:text-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
            >
              connect
            </button>
          )
        }
        if (chain?.unsupported) {
          return (
            <button
              type="button"
              onClick={openChainModal}
              className="rounded-full border px-4 py-1.5 text-sm transition focus-visible:outline focus-visible:outline-2"
              style={{ borderColor: 'var(--phase-critical)', color: 'var(--phase-critical)' }}
            >
              wrong network
            </button>
          )
        }
        const addr = account.address as `0x${string}`
        return (
          <button
            type="button"
            onClick={openAccountModal}
            title={account.address}
            className="rounded-full border border-line py-1 pl-1 pr-3 transition hover:border-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
          >
            <PepeChip name={`${addr.slice(0, 6)}…${addr.slice(-4)}`} />
          </button>
        )
      }}
    </ConnectButton.Custom>
  )
}

/// compact testnet faucet: mixETH is free playtest scrip — click to mint
/// 1000, or pass an amount. `full` renders the input-card variant used on
/// the Predeposit page (kept exactly as-is — that tree is not ours).
const QUICK_MINT = 1000n * 10n ** 18n

export function FaucetButton({ full = false }: { full?: boolean }) {
  const { isConnected } = useAccount()
  const [step, setStep] = useState<'idle' | 'tx' | 'done'>('idle')
  const [mintAmount, setMintAmount] = useState('1000')
  const { writeContractAsync } = useWriteContract()

  function amountWad(): bigint | null {
    const n = Number(mintAmount)
    if (!Number.isFinite(n) || n <= 0) return null
    try {
      return BigInt(Math.round(n * 1e6)) * 10n ** 12n
    } catch {
      return null
    }
  }

  async function drip() {
    const amt = full ? amountWad() : QUICK_MINT
    if (!amt) return
    try {
      setStep('tx')
      await writeContractAsync({
        address: ADDRESSES.faucet,
        abi: faucetAbi,
        functionName: 'drip',
        args: [amt],
      })
      setStep('done')
      setTimeout(() => setStep('idle'), 2500)
    } catch {
      setStep('idle')
    }
  }

  if (full) {
    return (
      <div className="flex gap-2">
        <input
          className="input-amount w-32 text-right"
          placeholder="1000"
          value={mintAmount}
          inputMode="decimal"
          onChange={(e) => setMintAmount(e.target.value.replace(/[^0-9.]/g, ''))}
        />
        <button
          type="button"
          disabled={!isConnected || !amountWad()}
          onClick={drip}
          className={`btn-ghost flex-1 ${step === 'done' ? 'border-emerald-200 text-emerald-600' : ''}`}
        >
          {step === 'done'
            ? '✅ minted'
            : step === 'tx'
              ? 'confirm in wallet…'
              : 'faucet: mint mixETH (free)'}
        </button>
      </div>
    )
  }

  return (
    <button
      type="button"
      title="faucet · free mixETH"
      disabled={!isConnected}
      onClick={drip}
      className={`inline-flex h-7 items-center gap-1 rounded-full border border-line bg-bg-1 px-2.5 font-body text-xs text-text-hi transition hover:border-accent active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-40 focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent ${
        step === 'done' ? 'text-emerald-600' : ''
      }`}
    >
      {step === 'done' ? '✅' : step === 'tx' ? <><MixLogo px={14} />…</> : <MixLogo px={14} />}
      <span className="hidden lg:inline">{step === 'done' ? 'minted' : step === 'tx' ? 'minting' : 'faucet'}</span>
    </button>
  )
}
