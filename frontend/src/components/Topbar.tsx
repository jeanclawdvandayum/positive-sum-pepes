import { useMemo, useState } from 'react'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import { NavLink } from 'react-router-dom'
import { useAccount, useWriteContract } from 'wagmi'
import { renderPepeSvg, randomDna } from '../lib/pepeRender'
import { ADDRESSES, FAUCET_ENABLED } from '../lib/config'
import { faucetAbi } from '../lib/abi'
import { useRound } from '../lib/useRound'
import ThemeSwitcher from './ThemeSwitcher'
import MixLogo from './MixLogo'

const baseLinks = [
  { to: '/', label: 'home' },
  { to: '/trade', label: 'trade' },
  { to: '/stake', label: 'stake' },
]

export default function Topbar() {
  const round = useRound()
  // a random pepe every load — the header IS the art
  const logo = useMemo(() => renderPepeSvg(randomDna()), [])
  /// predeposit page is live while the round is in (or before) its predeposit window;
  /// after launch the page stays reachable by URL for claims.
  const showPredeposit = round.mode === 0 || round.predepositClosed === false
  const links = useMemo(() => {
    if (!showPredeposit) return baseLinks
    return [...baseLinks.slice(0, 2), { to: '/predeposit', label: 'predeposit' }, baseLinks[2]]
  }, [showPredeposit])
  return (
    <header className="sticky top-0 z-20 border-b border-sky-100 bg-white/80 backdrop-blur-md">
      <div className="mx-auto flex w-full max-w-6xl items-center gap-2 px-4 py-3 sm:gap-6 sm:px-6">
        <NavLink to="/" className="flex shrink-0 items-center gap-2">
          <span className="block h-8 w-8 shrink-0 overflow-hidden rounded-lg border border-sky-200 shadow-sm">
            <span className="block h-full w-full [&>svg]:h-full [&>svg]:w-full" dangerouslySetInnerHTML={{ __html: logo }} />
          </span>
          <span className="hidden text-lg font-black tracking-tight text-psp-deep sm:block">
            positive sum pepes
          </span>
        </NavLink>
        <nav className="flex flex-1 items-center justify-center gap-1 sm:gap-2">
          {links.map((l) => (
            <NavLink
              key={l.to}
              to={l.to}
              className={({ isActive }) =>
                `rounded-full px-3 py-1.5 text-sm font-bold transition sm:px-4 ${
                  isActive
                    ? 'bg-gradient-to-r from-sky-400 to-emerald-400 text-[#fff] shadow-md shadow-sky-200'
                    : 'text-slate-500 hover:bg-sky-50 hover:text-psp-deep'
                }`
              }
            >
              {l.label}
            </NavLink>
          ))}
        </nav>
        <div className="flex shrink-0 items-center gap-2 sm:gap-3">
          {FAUCET_ENABLED && <FaucetButton />}
          <ThemeSwitcher />
          <div className="scale-90 sm:scale-100">
            <ConnectButton showBalance={false} chainStatus="icon" />
          </div>
        </div>
      </div>
    </header>
  )
}

/// compact testnet faucet: mixETH is free playtest scrip — click to mint
/// 1000, or pass an amount. `full` renders the input-card variant used on
/// the Predeposit page.
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
      className={`inline-flex h-7 items-center gap-1 rounded-full border border-emerald-200 bg-white px-2.5 text-xs font-bold text-psp-deep transition active:scale-[0.98] hover:bg-sky-50 disabled:cursor-not-allowed disabled:opacity-40 ${
        step === 'done' ? 'text-emerald-600' : ''
      }`}
    >
      {step === 'done' ? '✅' : step === 'tx' ? <><MixLogo px={14} />…</> : <MixLogo px={14} />}
      <span className="hidden lg:inline">{step === 'done' ? 'minted' : step === 'tx' ? 'minting' : 'faucet'}</span>
    </button>
  )
}
