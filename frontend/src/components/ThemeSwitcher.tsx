import type { ReactNode } from 'react'
import { useTheme, type ThemeMode } from '../lib/theme'

const OPTIONS: { key: ThemeMode; label: string; icon: ReactNode }[] = [
  {
    key: 'system',
    label: 'system theme',
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" className="h-3.5 w-3.5">
        <rect x="2" y="3" width="20" height="14" rx="2" />
        <path d="M8 21h8M12 17v4" />
      </svg>
    ),
  },
  {
    key: 'light',
    label: 'light theme',
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" className="h-3.5 w-3.5">
        <circle cx="12" cy="12" r="4" />
        <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" />
      </svg>
    ),
  },
  {
    key: 'dark',
    label: 'dark theme',
    icon: (
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" className="h-3.5 w-3.5">
        <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
      </svg>
    ),
  },
]

export default function ThemeSwitcher() {
  const { mode, setMode } = useTheme()

  return (
    <div
      role="group"
      aria-label="theme"
      className="flex items-center gap-0.5 rounded-full border border-line bg-bg-1/70 p-0.5"
    >
      {OPTIONS.map((o) => (
        <button
          key={o.key}
          type="button"
          title={o.label}
          aria-label={o.label}
          aria-pressed={mode === o.key}
          onClick={() => setMode(o.key)}
          className={`grid h-7 w-7 place-items-center rounded-full transition focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent ${
            mode === o.key
              ? 'bg-accent text-bg-0'
              : 'text-text-lo hover:bg-bg-2 hover:text-text-hi'
          }`}
        >
          {o.icon}
        </button>
      ))}
    </div>
  )
}
