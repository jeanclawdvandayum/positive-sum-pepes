import { useMemo, useState } from 'react'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import { NavLink } from 'react-router-dom'
import { useAccount, useWriteContract } from 'wagmi'
import { parseEther } from 'viem'
import { renderPepeSvg, randomDna } from '../lib/pepeRender'
import { ADDRESSES, FAUCET_ENABLED } from '../lib/config'
import { faucetAbi } from '../lib/abi'
import ThemeSwitcher from './ThemeSwitcher'

const links = [
  { to: '/', label: 'home' },
  { to: '/trade', label: 'trade' },
  { to: '/stake', label: 'stake' },
]

export default function Topbar() {
  // a random pepe every load — the header IS the art
  const logo = useMemo(() => renderPepeSvg(randomDna()), [])
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

/// compact testnet faucet: one drip per click — pay 0.0001 ETH, receive 100 mixETH
function FaucetButton() {
  const { isConnected } = useAccount()
  const [step, setStep] = useState<'idle' | 'tx' | 'done'>('idle')
  const { writeContractAsync } = useWriteContract()

  async function drip() {
    try {
      setStep('tx')
      await writeContractAsync({
        address: ADDRESSES.faucet,
        abi: faucetAbi,
        functionName: 'drip',
        value: parseEther('0.0001'),
      })
      setStep('done')
      setTimeout(() => setStep('idle'), 2500)
    } catch {
      setStep('idle')
    }
  }

  return (
    <button
      type="button"
      title="faucet · 100 mixETH per 0.0001 ETH"
      disabled={!isConnected}
      onClick={drip}
      className={`inline-flex h-7 items-center gap-1 rounded-full border border-emerald-200 bg-white px-2.5 text-xs font-bold text-psp-deep transition active:scale-[0.98] hover:bg-sky-50 disabled:cursor-not-allowed disabled:opacity-40 ${
        step === 'done' ? 'text-emerald-600' : ''
      }`}
    >
      {step === 'done' ? '✅' : step === 'tx' ? '💧…' : '💧'}
      <span className="hidden lg:inline">{step === 'done' ? 'dripped' : step === 'tx' ? 'confirming' : 'faucet'}</span>
    </button>
  )
}
