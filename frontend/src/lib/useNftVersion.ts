import { useEffect, useState } from 'react'
import { stakerAbi } from './abi'
import { rpcCall } from './rpc'
import type { NftVersion } from './nftPermissions'

/** Legacy stakers advertise ERC-721 despite missing methods. Their metadata
 * support is false; upgraded stakers also expose an explicit capability version.
 * Bind the result to its staker during render, so a round switch cannot briefly
 * reuse a legacy result and request collection approval for an upgraded round. */
export function useNftVersion(staker: `0x${string}` | undefined): NftVersion {
  const [result, setResult] = useState<{ staker: string; version: NftVersion }>()
  useEffect(() => {
    if (!staker) return
    let dead = false
    let timer: ReturnType<typeof setTimeout> | undefined
    async function load() {
      try {
        const metadata = await rpcCall(staker!, stakerAbi, 'supportsInterface', ['0x5b5e139f'])
        const version = metadata === false ? 0 : metadata === true &&
          await rpcCall(staker!, stakerAbi, 'NFT_INTERFACE_VERSION') === 1n ? 1 : undefined
        if (!dead) setResult({ staker: staker!, version })
      } catch {
        if (!dead) {
          setResult({ staker: staker!, version: undefined })
          timer = setTimeout(load, 8000)
        }
      }
    }
    void load()
    return () => { dead = true; if (timer) clearTimeout(timer) }
  }, [staker])
  return result?.staker === staker ? result?.version : undefined
}
