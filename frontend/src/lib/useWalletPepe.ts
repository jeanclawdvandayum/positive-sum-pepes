import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { CHAIN_ID } from './config'
import { rpcCall } from './rpc'
import { renderPepeSvg } from './pepeRender'
import { addressPepeDna, createWalletPepeReader, walletPepeKey } from './walletPepe'

export function useWalletPepe(address: `0x${string}`, staker?: `0x${string}`) {
  const key = walletPepeKey(address, staker)
  const read = useMemo(() => createWalletPepeReader(rpcCall), [])
  // Header, feed and repeated ladder seats share a single identity query.
  // Scope it to this chain/round/wallet; recheck mints and transfers every poll.
  const query = useQuery({
    queryKey: ['wallet-pepe', CHAIN_ID, key],
    queryFn: () => read(address, staker),
    staleTime: 4000, refetchInterval: 6000,
  })
  const pepe = query.isError ? undefined : query.data
  const dna = pepe?.dna ?? addressPepeDna(address)
  return useMemo(() => pepe?.svg ?? renderPepeSvg(dna), [pepe?.svg, dna])
}
