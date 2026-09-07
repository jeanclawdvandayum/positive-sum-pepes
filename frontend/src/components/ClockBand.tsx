import type { ReactNode } from 'react'

/** Shared full-width stage for the play and predeposit countdowns. */
export default function ClockBand({ children, label, className = '' }: {
  children: ReactNode
  label: string
  className?: string
}) {
  return <section aria-label={label} className={`relative left-1/2 w-screen -translate-x-1/2 border-b border-[#22344f] bg-[#0b1424] ${className}`}>
    <div className="mx-auto flex w-full max-w-6xl flex-col items-center px-4 pb-7 pt-6 sm:pb-9 sm:pt-8">
      {children}
    </div>
  </section>
}
