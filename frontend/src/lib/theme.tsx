import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'

export type ThemeMode = 'system' | 'light' | 'dark'
type Resolved = 'light' | 'dark'

const STORAGE_KEY = 'psp-theme'

interface ThemeCtxValue {
  mode: ThemeMode
  resolved: Resolved
  setMode: (m: ThemeMode) => void
}

const ThemeCtx = createContext<ThemeCtxValue>({
  mode: 'system',
  resolved: 'light',
  setMode: () => {},
})

function systemPrefersDark(): boolean {
  return typeof window !== 'undefined' && window.matchMedia('(prefers-color-scheme: dark)').matches
}

function readStoredMode(): ThemeMode {
  if (typeof window === 'undefined') return 'system'
  const saved = window.localStorage.getItem(STORAGE_KEY)
  return saved === 'light' || saved === 'dark' || saved === 'system' ? saved : 'system'
}

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [mode, setModeState] = useState<ThemeMode>(readStoredMode)
  const [resolved, setResolved] = useState<Resolved>(() =>
    mode === 'system' ? (systemPrefersDark() ? 'dark' : 'light') : mode,
  )

  useEffect(() => {
    const apply = () => {
      const next: Resolved = mode === 'system' ? (systemPrefersDark() ? 'dark' : 'light') : mode
      setResolved(next)
      document.documentElement.classList.toggle('dark', next === 'dark')
    }
    apply()
    if (mode === 'system') {
      const mq = window.matchMedia('(prefers-color-scheme: dark)')
      mq.addEventListener('change', apply)
      return () => mq.removeEventListener('change', apply)
    }
  }, [mode])

  const setMode = (m: ThemeMode) => {
    try {
      window.localStorage.setItem(STORAGE_KEY, m)
    } catch {
      /* private mode etc — session-only theme */
    }
    setModeState(m)
  }

  return <ThemeCtx.Provider value={{ mode, resolved, setMode }}>{children}</ThemeCtx.Provider>
}

export function useTheme() {
  return useContext(ThemeCtx)
}
