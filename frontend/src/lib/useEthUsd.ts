import { useEffect, useState } from 'react'

/// ETH/USD spot for the "$ value" rows. mixETH tracks ETH 1:1-ish; this is a
/// display-only estimate, never transaction math. 5-min module cache, null
/// when offline (UI then shows mixETH only — never a fake number).
let cache: { usd: number | null; at: number } | null = null

export function useEthUsd(): number | null {
  const [usd, setUsd] = useState<number | null>(
    () => (cache && Date.now() - cache.at < 300_000 ? cache.usd : null),
  )
  useEffect(() => {
    if (cache && Date.now() - cache.at < 300_000) {
      setUsd(cache.usd)
      return
    }
    let dead = false
    fetch('https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd')
      .then((r) => r.json())
      .then((j) => {
        const v = typeof j?.ethereum?.usd === 'number' ? j.ethereum.usd : null
        cache = { usd: v, at: Date.now() }
        if (!dead) setUsd(v)
      })
      .catch(() => {})
    return () => {
      dead = true
    }
  }, [])
  return usd
}
