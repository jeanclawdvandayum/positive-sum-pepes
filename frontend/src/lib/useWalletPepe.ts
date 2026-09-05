import { useEffect, useMemo, useState } from 'react'
import { rpcCall } from './rpc'
import { renderPepeSvg } from './pepeRender'
import { addressPepeDna, createWalletPepeReader, walletPepeKey, type WalletPepe } from './walletPepe'

export function useWalletPepe(address: `0x${string}`, staker?: `0x${string}`) {
  const key = walletPepeKey(address, staker)
  const read = useMemo(() => createWalletPepeReader(rpcCall), [])
  const [state, setState] = useState<{ key: string; pepe: WalletPepe }>()

  useEffect(() => {
    let stopped = false
    let timer: ReturnType<typeof setTimeout> | undefined
    let backoff = 0
    async function poll() {
      try {
        const pepe = await read(address, staker)
        if (!stopped) { setState({ key, pepe }); backoff = 0 }
      } catch {
        if (!stopped) {
          setState(undefined)
          backoff = backoff ? Math.min(backoff * 2, 60_000) : 8000
        }
      }
      if (!stopped) timer = setTimeout(poll, backoff || 6000)
    }
    poll()
    return () => { stopped = true; if (timer) clearTimeout(timer) }
  }, [key, address, staker, read])

  // The key guard applies during render, before effects clean up an old account.
  const pepe = state?.key === key ? state.pepe : undefined
  const dna = pepe?.dna ?? addressPepeDna(address)
  return useMemo(() => pepe?.svg ?? renderPepeSvg(dna), [pepe?.svg, dna])
}
