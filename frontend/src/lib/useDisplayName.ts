import { useQuery } from '@tanstack/react-query'
import { type Address } from 'viem'
import { readVerifiedName, shortAddress } from './weiNames'
import { nameClient, nameNamespace, nameQueryKey } from './nameConfig'

/** Reads on the name network independently of game RPC and wallet chain.
 * Shared queries deduplicate the same person across the header, feed and ladder. */
export function useDisplayName(address: Address) {
  const { data, isError } = useQuery({
    queryKey: [...nameQueryKey, address.toLowerCase()],
    queryFn: async () => ({ name: await readVerifiedName(nameClient, nameNamespace, address) }),
    staleTime: 30_000,
    gcTime: 60_000,
    refetchInterval: 60_000,
    retry: false,
  })
  return (!isError && data?.name) || shortAddress(address)
}
