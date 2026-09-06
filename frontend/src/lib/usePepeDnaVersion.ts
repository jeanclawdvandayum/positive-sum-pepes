import { useQuery } from '@tanstack/react-query'
import { CHAIN_ID } from './config'
import { rpcCall } from './rpc'
import { stakerAbi } from './abi'

export function usePepeDnaVersion(staker?: `0x${string}`) {
  return useQuery({
    queryKey: ['pepe-dna-version', CHAIN_ID, staker],
    enabled: !!staker,
    queryFn: () => rpcCall(staker!, stakerAbi, 'PEPE_DNA_VERSION') as Promise<bigint>,
    staleTime: Infinity, retry: false,
  }).data
}
