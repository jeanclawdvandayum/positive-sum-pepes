import { useEffect, useRef } from 'react'
import { useAccount } from 'wagmi'
import { getAccount } from 'wagmi/actions'
import { ADDRESSES, CHAIN_ID, wagmiConfig } from './config'
import { stakerAbi } from './abi'
import { rpcCall } from './rpc'
import { prepareNftReinvestment, type NftVersion } from './nftPermissions'
import { useConfirmedWrite } from './useConfirmedWrite'

export function useNftReinvestment(staker: `0x${string}` | undefined, version: NftVersion) {
  const { address } = useAccount()
  const { writeContractAsync } = useConfirmedWrite()
  const session = `${address}:${staker}`
  const latest = useRef(session)
  latest.current = session
  const mounted = useRef(true)
  useEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])
  const assertSession = () => {
    const account = getAccount(wagmiConfig)
    if (!mounted.current || latest.current !== session || account.address?.toLowerCase() !== address?.toLowerCase() || account.chainId !== CHAIN_ID) {
      throw new Error('Wallet, network or round changed. Refresh and try again.')
    }
  }
  const prepare = async (ids: readonly bigint[]) => {
    if (!address || !staker) throw new Error('Connect your wallet and wait for the position to load.')
    await prepareNftReinvestment(address, ADDRESSES.reinvestor, ids, version, {
      assertSession,
      ownerOf: id => rpcCall(staker, stakerAbi, 'ownerOf', [id]) as Promise<`0x${string}`>,
      isApprovedForAll: () => rpcCall(staker, stakerAbi, 'isApprovedForAll', [address, ADDRESSES.reinvestor]) as Promise<boolean>,
      getApproved: id => rpcCall(staker, stakerAbi, 'getApproved', [id]) as Promise<`0x${string}`>,
      approve: id => writeContractAsync({ address: staker, abi: stakerAbi, functionName: 'approve', args: [ADDRESSES.reinvestor, id] }),
      approveAll: () => writeContractAsync({ address: staker, abi: stakerAbi, functionName: 'setApprovalForAll', args: [ADDRESSES.reinvestor, true] }),
    })
  }
  return { prepare, assertSession }
}
