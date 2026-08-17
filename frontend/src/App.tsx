import { WagmiProvider } from 'wagmi'
import { RainbowKitProvider, lightTheme } from '@rainbow-me/rainbowkit'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { HashRouter, Routes, Route } from 'react-router-dom'
import { wagmiConfig } from './lib/config'
import Topbar from './components/Topbar'
import Landing from './pages/Landing'
import Trade from './pages/Trade'
import Stake from './pages/Stake'

const queryClient = new QueryClient()

export default function App() {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          theme={lightTheme({
            accentColor: '#38bdf8',
            accentColorForeground: 'white',
            borderRadius: 'large',
            overlayBlur: 'small',
          })}
          modalSize="compact"
        >
          <HashRouter>
            <div className="min-h-dvh bg-gradient-to-b from-sky-50 via-white to-emerald-50">
              <Topbar />
              <main className="mx-auto w-full max-w-6xl px-4 pb-16 pt-4 sm:px-6">
                <Routes>
                  <Route path="/" element={<Landing />} />
                  <Route path="/trade" element={<Trade />} />
                  <Route path="/stake" element={<Stake />} />
                </Routes>
              </main>
              <footer className="pb-8 text-center text-xs text-slate-400">
                positive sum pepes — the game that pays you to stay
              </footer>
            </div>
          </HashRouter>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  )
}
