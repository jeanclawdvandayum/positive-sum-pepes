import { formatUnits } from 'viem'

export function fmtAmount(wad: bigint | undefined, maxFrac = 2): string {
  if (wad === undefined) return '…'
  const n = Number(formatUnits(wad, 18))
  if (n === 0) return '0'
  if (n < 0.0001) return '<0.0001'
  if (n >= 1_000_000_000) return (n / 1e9).toFixed(2) + 'B'
  if (n >= 1_000_000) return (n / 1e6).toFixed(2) + 'M'
  if (n >= 10_000) return (n / 1e3).toFixed(1) + 'K'
  return n.toLocaleString('en-US', { maximumFractionDigits: maxFrac })
}

export function fmtPrice(wadPerPsp: bigint | undefined): string {
  if (wadPerPsp === undefined) return '…'
  const n = Number(formatUnits(wadPerPsp, 18))
  if (n === 0) return '0'
  if (n < 0.0001) return n.toExponential(2)
  return n.toLocaleString('en-US', { maximumFractionDigits: n < 1 ? 8 : 4 })
}

export function fmtPct(x: number): string {
  return (x * 100).toFixed(2) + '%'
}

export function fmtCountdown(seconds: number): string {
  if (seconds <= 0) return '0s'
  const d = Math.floor(seconds / 86400)
  const h = Math.floor((seconds % 86400) / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  const s = Math.floor(seconds % 60)
  if (d > 0) return `${d}d ${h}h ${m}m`
  if (h > 0) return `${h}h ${m}m ${s}s`
  if (m > 0) return `${m}m ${s}s`
  return `${s}s`
}

export function parseAmountToWad(input: string): bigint {
  const cleaned = input.trim()
  if (!cleaned) return 0n
  try {
    const [whole, frac = ''] = cleaned.split('.')
    const frac6 = (frac + '0'.repeat(18)).slice(0, 18)
    return BigInt(whole || '0') * 10n ** 18n + BigInt(frac6 || '0')
  } catch {
    return 0n
  }
}

/// Exact decimal string for a wad — NO rounding (scoopy 2026-08-29, fix #2:
/// max-fill used the ROUNDED display string; when display rounding rounded
/// UP the parsed amount exceeded the balance by a few wei and the button
/// greyed out). This is what max buttons must feed the input.
export function wadToExact(wad: bigint | undefined): string {
  if (wad === undefined || wad <= 0n) return '0'
  const whole = wad / 10n ** 18n
  const frac = (wad % 10n ** 18n).toString().padStart(18, '0').replace(/0+$/, '')
  return frac ? `${whole}.${frac}` : `${whole}`
}
