import { useEffect } from 'react'
import { WagmiProvider } from 'wagmi'
import { RainbowKitProvider, lightTheme, darkTheme } from '@rainbow-me/rainbowkit'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { HashRouter, Routes, Route } from 'react-router-dom'
import { wagmiConfig, ADDRESSES } from './lib/config'
import { ThemeProvider, useTheme } from './lib/theme'
import { usePhase, setDeadline, type Phase } from './phase/PhaseEngine'
import { useRound } from './lib/useRound'
import Topbar from './components/Topbar'
import ScanlineOverlay from './components/ScanlineOverlay' // dark-theme CRT, inert otherwise (B0)
import Landing from './pages/Landing'
import Trade from './pages/Trade'
import Stake from './pages/Stake'
import Predeposit from './pages/Predeposit'

const queryClient = new QueryClient()

// rainbowkit modal follows the phase system (spec §1 --accent; red-line #9:
// keep the modal in sync with the skin). PhaseEngine idles prelaunch = calm.
const RK_ACCENT_DARK: Record<Phase, string> = {
  calm: '#3ddc97',
  heat: '#ffb347',
  critical: '#ff4d5e',
}
const RK_ACCENT_LIGHT: Record<Phase, string> = {
  calm: '#0d8a5f',
  heat: '#9a5b00',
  critical: '#cf2438',
}

/// footer = tagline + contract address + round number + "made of pixels
/// and math" (B1 §5). Round number is live from the shared singleton.
function Footer() {
  const round = useRound()
  const factory = ADDRESSES.factory
  const hasFactory = factory && factory !== '0x' && factory.length > 2
  return (
    <footer className="border-t border-line font-body text-xs text-text-lo">
      <div className="mx-auto flex w-full max-w-6xl flex-wrap items-center gap-x-3 gap-y-1 px-4 pb-8 pt-6 sm:px-6">
        <span>positive sum pepes — the game that pays you to stay</span>
        {hasFactory && (
          <>
            <span aria-hidden="true">·</span>
            <span className="tabular font-data" title={factory}>
              {factory.slice(0, 10)}…{factory.slice(-8)}
            </span>
          </>
        )}
        <span aria-hidden="true">·</span>
        <span className="tabular font-data">round {round.id.toString()}</span>
        <span aria-hidden="true">·</span>
        <span>made of pixels and math</span>
      </div>
    </footer>
  )
}

/// CLOCK-REDESIGN §6.1 — the ONE caller of PhaseEngine.setDeadline (the
/// engine fetches nothing; red-line). detonationAt rides useRound's shared
/// 4s lane (useRound adds the read); seconds → ms here. A round that left
/// Active (flat = post-detonation, destroyed, predeposit) disarms the clock
/// so it retires to its idle frame instead of freezing at 00:00:00.
function DeadlineWire() {
  const round = useRound()
  const armed = round.mode === 1 && round.detonationAt !== undefined && round.detonationAt > 0n
  useEffect(() => {
    setDeadline(armed && round.detonationAt !== undefined ? Number(round.detonationAt) * 1000 : undefined)
  }, [armed, round.detonationAt])
  return null
}

function Shell() {
  const { resolved } = useTheme()
  const { phase } = usePhase()
  const accent = (resolved === 'dark' ? RK_ACCENT_DARK : RK_ACCENT_LIGHT)[phase]

  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          theme={
            resolved === 'dark'
              ? darkTheme({
                  accentColor: accent,
                  accentColorForeground: '#06101d',
                  borderRadius: 'large',
                  overlayBlur: 'small',
                })
              : lightTheme({
                  accentColor: accent,
                  accentColorForeground: 'white',
                  borderRadius: 'large',
                  overlayBlur: 'small',
                })
          }
          modalSize="compact"
        >
          <HashRouter>
            {/* bg-0 in both themes — the old wrapper was a light-only gradient
                (inventory red-line #14); scanlines ride above, pointer-dead */}
            <div className="min-h-dvh bg-bg-0">
              <DeadlineWire />
              <Topbar />
              <ScanlineOverlay />
              <main className="mx-auto w-full max-w-6xl px-4 pb-16 pt-4 sm:px-6">
                <Routes>
                  <Route path="/" element={<Landing />} />
                  <Route path="/play" element={<Trade />} />
                  {/* /trade alias until B2 consolidates the play tree */}
                  <Route path="/trade" element={<Trade />} />
                  <Route path="/stake" element={<Stake />} />
                  <Route path="/predeposit" element={<Predeposit />} />
                </Routes>
              </main>
              <Footer />
            </div>
          </HashRouter>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  )
}

export default function App() {
  return (
    <ThemeProvider>
      <Shell />
    </ThemeProvider>
  )
}
