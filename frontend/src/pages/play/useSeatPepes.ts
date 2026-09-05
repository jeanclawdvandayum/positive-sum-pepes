import { useEffect, useState } from 'react'
import { rpcCall } from '../../lib/rpc'
import { stakerAbi } from '../../lib/abi'
import type { BoardTicket } from './useLadderBoard'

// Reads each seated buyer's pepe NFT DNA from the staker.
// Keyed by BUYER ADDRESS (stable across board shifts), not seat index —
// so a board shift never puts the wrong pepe on the wrong row.

// module-level cache: DNAs per address persist across board shifts and
// component re-mounts. Only cleared on page reload.
const dnaCache = new Map<string, bigint>()

export function useSeatPepes(
  staker: `0x${string}` | undefined,
  seats: (BoardTicket | undefined)[],
): Map<string, bigint> {
  // keyed by address — stable across board shifts
  const [dnas, setDnas] = useState<Map<string, bigint>>(() => new Map(dnaCache))

  useEffect(() => {
    if (!staker) return
    const holders = [...new Set(seats.filter((s): s is BoardTicket => s !== undefined).map((s) => s.addr))]
    if (holders.length === 0) return

    // only fetch addresses not already cached
    const uncached = holders.filter((a) => !dnaCache.has(a))
    if (uncached.length === 0) {
      setDnas(new Map(dnaCache))
      return
    }

    let dead = false
    Promise.all(
      uncached.map(async (addr) => {
        try {
          const bal = (await rpcCall(staker, stakerAbi, 'balanceOf', [addr])) as bigint
          if (bal === 0n) return { addr, dna: undefined }
          const pepeId = (await rpcCall(staker, stakerAbi, 'tokenOfOwnerByIndex', [addr, 0n])) as bigint
          const dna = (await rpcCall(staker, stakerAbi, 'dnaOf', [pepeId])) as bigint
          return { addr, dna: dna > 0n ? dna : undefined }
        } catch {
          return { addr, dna: undefined }
        }
      }),
    ).then((results) => {
      if (dead) return
      for (const r of results) {
        if (r.dna !== undefined) dnaCache.set(r.addr, r.dna)
        else dnaCache.set(r.addr, 0n) // cache "no pepe" to avoid re-fetching
      }
      setDnas(new Map(dnaCache))
    })
    return () => { dead = true }
  }, [staker, seats.filter((s): s is BoardTicket => s !== undefined).map((s) => s.addr).join(',')])

  return dnas
}
