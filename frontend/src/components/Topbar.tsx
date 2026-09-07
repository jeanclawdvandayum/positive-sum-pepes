import { useConfirmedWrite } from '../lib/useConfirmedWrite'
import { useEffect, useId, useMemo, useRef, useState } from 'react'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import { NavLink, useLocation, Link } from 'react-router-dom'
import { useAccount } from 'wagmi'
import { renderPepeSvg, randomDna } from '../lib/pepeRender'
import { ADDRESSES, FAUCET_ENABLED } from '../lib/config'
import { faucetAbi } from '../lib/abi'
import { useRound } from '../lib/useRound'
import Clock from './Clock'
import WalletAccountButton from './WalletAccountButton'
import { useWalletPepe } from '../lib/useWalletPepe'
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
  { to: '/graveyard', label: 'graveyard' },
]

export default function Topbar() {
  const round = useRound()
  const { pathname } = useLocation()
  const [menuOpen, setMenuOpen] = useState(false)
  const headerRef = useRef<HTMLElement>(null)
  const menuButtonRef = useRef<HTMLButtonElement>(null)
  const menuId = useId()
  // a random pepe every load — the header IS the art
  const logo = useMemo(() => renderPepeSvg(randomDna()), [])
  /// predeposit page is live while the round is in (or before) its predeposit window;
  /// after launch the page stays reachable by URL for claims.
  const showPredeposit = round.mode === 0 || round.predepositClosed === false
  const links = useMemo(() => {
    if (!showPredeposit) return baseLinks
    return [...baseLinks.slice(0, 2), { to: '/predeposit', label: 'predeposit' }, ...baseLinks.slice(2)]
  }, [showPredeposit])

  useEffect(() => { setMenuOpen(false) }, [pathname])

  // This is a navigation disclosure, not a modal. Leave page scrolling and
  // wallet dialogs alone, and remove the hidden links from the tab order.
  useEffect(() => {
    if (!menuOpen) return
    function onPointerDown(event: PointerEvent) {
      if (event.target instanceof Node && !headerRef.current?.contains(event.target)) setMenuOpen(false)
    }
    function onKeyDown(event: KeyboardEvent) {
      if (event.key !== 'Escape') return
      event.preventDefault()
      setMenuOpen(false)
      menuButtonRef.current?.focus()
    }
    const desktop = window.matchMedia('(min-width: 1280px)')
    function onResize() { if (desktop.matches) setMenuOpen(false) }
    document.addEventListener('pointerdown', onPointerDown)
    document.addEventListener('keydown', onKeyDown)
    desktop.addEventListener('change', onResize)
    return () => {
      document.removeEventListener('pointerdown', onPointerDown)
      document.removeEventListener('keydown', onKeyDown)
      desktop.removeEventListener('change', onResize)
    }
  }, [menuOpen])

  // the countdown chip lives everywhere EXCEPT play (the clock is the page there)
  const onPlay = pathname === '/play' || pathname === '/trade'

  return (
    <header ref={headerRef}
      onBlur={(event) => {
        if (event.relatedTarget instanceof Node && !event.currentTarget.contains(event.relatedTarget)) setMenuOpen(false)
      }}
      className="sticky top-0 z-20 border-b border-line bg-bg-0/95 font-body backdrop-blur-md">
      <div className="mx-auto flex w-full max-w-7xl items-center gap-2 px-4 py-2 sm:gap-4 sm:px-6 xl:py-3">
        <NavLink to="/" aria-label="positive sum pepes home" onClick={() => setMenuOpen(false)}
          className="flex min-h-11 shrink-0 items-center gap-2 rounded-lg focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent">
          <span className="block h-8 w-8 shrink-0 overflow-hidden rounded-lg border border-line [&>svg]:h-full [&>svg]:w-full"
            style={{ imageRendering: 'pixelated' }}
            dangerouslySetInnerHTML={{ __html: logo }}
          />
          <span className="hidden font-display text-sm text-text-hi sm:block">
            positive sum pepes
          </span>
        </NavLink>

        <nav className="hidden min-w-0 flex-1 items-center justify-center gap-1 xl:flex" aria-label="main">
          {links.map((l) => (
            <NavLink
              key={l.to}
              to={l.to}
              className={({ isActive }) => {
                const active = isActive || (l.to === '/play' && pathname === '/trade')
                return `whitespace-nowrap rounded-full px-3 py-1.5 text-sm transition focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent ${
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

        <div className="ml-auto flex min-w-0 items-center gap-2 xl:ml-0 xl:gap-3">
          <div className="hidden shrink-0 items-center gap-3 xl:flex">
            {!onPlay && (
              <Link to="/play" aria-label="countdown, go to play"
                className="rounded-md focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent">
                <Clock variant="mini" />
              </Link>
            )}
            {FAUCET_ENABLED && <FaucetButton />}
            <ThemeSwitcher />
          </div>
          <Connect onOpen={() => setMenuOpen(false)} />
          <button ref={menuButtonRef} type="button" aria-label={menuOpen ? 'close menu' : 'open menu'}
            aria-expanded={menuOpen} aria-controls={menuId}
            onClick={() => setMenuOpen(open => !open)}
            className="grid h-11 w-11 shrink-0 place-items-center rounded-lg border border-line text-text-hi hover:border-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent xl:hidden">
            <svg viewBox="0 0 24 24" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
              <path d={menuOpen ? 'M6 6L18 18M6 18L18 6' : 'M4 6H20M4 12H20M4 18H20'} />
            </svg>
          </button>
        </div>
      </div>

      <div id={menuId} hidden={!menuOpen} className="max-h-[calc(100dvh-4rem)] overflow-y-auto overscroll-contain border-t border-line bg-bg-0 xl:hidden">
        <div className="mx-auto w-full max-w-7xl px-4 pt-3 pb-5 sm:px-6">
          <nav aria-label="mobile main" className="grid grid-cols-2 gap-2">
            {links.map(link => (
              <NavLink key={link.to} to={link.to} onClick={() => setMenuOpen(false)}
                className={({ isActive }) => `flex min-h-11 min-w-0 items-center rounded-lg px-3 py-3 text-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent ${
                  isActive || (link.to === '/play' && pathname === '/trade')
                    ? 'bg-accent font-semibold text-bg-0'
                    : 'bg-bg-1 text-text-hi hover:bg-bg-2'
                }`}>
                {link.label}
              </NavLink>
            ))}
          </nav>
          {!onPlay && (
            <Link to="/play" onClick={() => setMenuOpen(false)} aria-label="countdown, go to play"
              className="mt-4 flex min-h-11 flex-wrap items-center justify-between gap-2 rounded-lg border-t border-line pt-4 text-sm text-text-lo focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent">
              <span>round clock</span>
              <Clock variant="mini" />
            </Link>
          )}
          <div className="mt-4 flex flex-wrap items-center justify-between gap-3 border-t border-line pt-4">
            <span className="text-sm text-text-lo">theme</span>
            <ThemeSwitcher large />
          </div>
          {FAUCET_ENABLED && (
            <div className="mt-4 flex flex-wrap items-center justify-between gap-3 border-t border-line pt-4">
              <span className="text-sm text-text-lo">practice mixETH</span>
              <FaucetButton menu />
            </div>
          )}
        </div>
      </div>
    </header>
  )
}

/// quiet outlined connect; connected = pepe identity chip (spec §7).
/// Connected identity uses the current-round NFT or genesis preview, with an address fallback.
function Connect({ onOpen }: { onOpen: () => void }) {
  return (
    <ConnectButton.Custom>
      {({ account, chain, openAccountModal, openChainModal, openConnectModal, authenticationStatus, mounted }) => {
        const ready = mounted && authenticationStatus !== 'loading'
        if (!ready) return <div className="h-8 w-24" aria-hidden="true" />
        if (!account) {
          return (
            <button
              type="button"
              onClick={() => { onOpen(); openConnectModal() }}
              className="min-h-11 rounded-full border border-line px-4 py-1.5 text-sm text-text-hi transition hover:border-accent hover:text-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent xl:min-h-0"
            >
              connect
            </button>
          )
        }
        if (chain?.unsupported) {
          return (
            <button
              type="button"
              onClick={() => { onOpen(); openChainModal() }}
              className="min-h-11 rounded-full border px-4 py-1.5 text-sm transition focus-visible:outline focus-visible:outline-2 xl:min-h-0"
              style={{ borderColor: 'var(--phase-critical)', color: 'var(--phase-critical)' }}
            >
              wrong network
            </button>
          )
        }
        return (
          <ConnectedWallet address={account.address as `0x${string}`} onClick={() => { onOpen(); openAccountModal() }} />
        )
      }}
    </ConnectButton.Custom>
  )
}

function ConnectedWallet({ address, onClick }: { address: `0x${string}`; onClick: () => void }) {
  const round = useRound()
  const svg = useWalletPepe(address, round.staker)
  return <WalletAccountButton address={address} svg={svg} onClick={onClick} />
}

/// compact testnet faucet: mixETH is free playtest scrip — click to mint
/// 1000, or pass an amount. `full` renders the input-card variant used on
/// the Predeposit page (kept exactly as-is — that tree is not ours).
const QUICK_MINT = 1000n * 10n ** 18n

export function FaucetButton({ full = false, menu = false }: { full?: boolean; menu?: boolean }) {
  const { isConnected } = useAccount()
  const [step, setStep] = useState<'idle' | 'tx' | 'done'>('idle')
  const [mintAmount, setMintAmount] = useState('1000')
  const [error, setError] = useState<string | null>(null)
  const { writeContractAsync } = useConfirmedWrite()

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
    setError(null)
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
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 180) : 'Mint failed. Please try again.')
      setStep('idle')
    }
  }

  if (full) {
    return (
      <div className="flex flex-wrap gap-2">
        <input
          className="input-amount w-32 text-right"
          placeholder="1000"
          value={mintAmount}
          inputMode="decimal"
          onChange={(e) => setMintAmount(e.target.value.replace(/[^0-9.]/g, ''))}
        />
        <button
          type="button"
          disabled={!isConnected || !amountWad() || step === 'tx'}
          onClick={drip}
          className={`btn-ghost flex-1 ${step === 'done' ? 'border-emerald-200 text-emerald-600' : ''}`}
        >
          {step === 'done'
            ? '✅ minted'
            : step === 'tx'
              ? 'confirm in wallet…'
              : 'faucet: mint mixETH (free)'}
        </button>
        {error && <p role="alert" className="w-full text-sm text-red-400">{error}</p>}
      </div>
    )
  }

  return (
    <button
      type="button"
      title={error || "faucet · free mixETH"}
      disabled={!isConnected || step === 'tx'}
      onClick={drip}
      className={`inline-flex ${menu ? 'h-11 px-4' : 'h-7 px-2.5'} items-center gap-1 rounded-full border border-line bg-bg-1 font-body text-xs text-text-hi transition hover:border-accent active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-40 focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent ${
        step === 'done' ? 'text-emerald-600' : ''
      }`}
    >
      {step === 'done' ? '✅' : step === 'tx' ? <><MixLogo px={14} />…</> : <MixLogo px={14} />}
      <span className={menu ? '' : 'hidden lg:inline'}>{step === 'done' ? 'minted' : step === 'tx' ? 'minting' : 'faucet'}</span>
      {error && <span role="alert" className="max-w-64 whitespace-normal text-red-400">{error}</span>}
    </button>
  )
}
