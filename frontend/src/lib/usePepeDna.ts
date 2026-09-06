import { useQuery } from '@tanstack/react-query'
import { CHAIN_ID } from './config'
import { rpcCall } from './rpc'
import { stakerAbi } from './abi'

/** Minted art is immutable. Read its assigned DNA, including collision fallbacks. */
export function usePepeDna(staker: `0x${string}` | undefined, tokenId: bigint) {
  return useQuery({
    queryKey: ['pepe-dna', CHAIN_ID, staker, tokenId.toString()],
    enabled: !!staker,
    queryFn: () => rpcCall(staker!, stakerAbi, 'dnaOf', [tokenId]) as Promise<bigint>,
    staleTime: Infinity,
  })
}
