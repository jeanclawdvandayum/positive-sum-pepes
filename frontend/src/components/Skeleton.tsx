// ─────────────────────────────────────────────────────────────────────────────
// Skeleton — loading = shimmer in bg-2, never a dash (REDESIGN-B0 item 5,
// spec §8). Sizing/shape via className (h-4 w-24 etc.). Reduced motion:
// static bg-2 block (tokens.css).
// ─────────────────────────────────────────────────────────────────────────────

import type { HTMLAttributes } from 'react'

export default function Skeleton({ className = '', ...rest }: HTMLAttributes<HTMLDivElement>) {
  return <div className={`skeleton ${className}`} {...rest} />
}
