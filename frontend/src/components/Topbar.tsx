import { ConnectButton } from '@rainbow-me/rainbowkit'
import { NavLink } from 'react-router-dom'

const links = [
  { to: '/', label: 'home' },
  { to: '/trade', label: 'trade' },
  { to: '/stake', label: 'stake' },
]

export default function Topbar() {
  return (
    <header className="sticky top-0 z-20 border-b border-sky-100 bg-white/80 backdrop-blur-md">
      <div className="mx-auto flex w-full max-w-6xl items-center gap-2 px-4 py-3 sm:gap-6 sm:px-6">
        <NavLink to="/" className="flex shrink-0 items-center gap-2">
          <span className="text-2xl">🐸</span>
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
                    ? 'bg-gradient-to-r from-sky-400 to-emerald-400 text-white shadow-md shadow-sky-200'
                    : 'text-slate-500 hover:bg-sky-50 hover:text-psp-deep'
                }`
              }
            >
              {l.label}
            </NavLink>
          ))}
        </nav>
        <div className="shrink-0 scale-90 sm:scale-100">
          <ConnectButton showBalance={false} chainStatus="icon" />
        </div>
      </div>
    </header>
  )
}
