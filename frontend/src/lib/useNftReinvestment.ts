import { ensureWalletChain } from './ensureWalletChain'
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
  const { writeContractAsync, atomicWallet } = useConfirmedWrite()
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
  const prepare = async (ids: readonly bigint[], collectionApproval = false) => {
    if (!address || !staker) throw new Error('Connect your wallet and wait for the position to load.')
    await ensureWalletChain(address, CHAIN_ID)
    const deferred = Boolean(await atomicWallet())
    const approvals: Parameters<typeof writeContractAsync>[0][] = []
    const approve = async (call: Parameters<typeof writeContractAsync>[0]) => {
      if (deferred) approvals.push(call)
      else await writeContractAsync(call)
    }
    await prepareNftReinvestment(address, ADDRESSES.reinvestor, ids, version, {
      assertSession,
      ownerOf: id => rpcCall(staker, stakerAbi, 'ownerOf', [id]) as Promise<`0x${string}`>,
      isApprovedForAll: () => rpcCall(staker, stakerAbi, 'isApprovedForAll', [address, ADDRESSES.reinvestor]) as Promise<boolean>,
      getApproved: id => rpcCall(staker, stakerAbi, 'getApproved', [id]) as Promise<`0x${string}`>,
      approve: id => approve({ address: staker, abi: stakerAbi, functionName: 'approve', args: [ADDRESSES.reinvestor, id] }),
      approveAll: () => approve({ address: staker, abi: stakerAbi, functionName: 'setApprovalForAll', args: [ADDRESSES.reinvestor, true] }),
    }, collectionApproval, deferred)
    return approvals
  }
  return { prepare, assertSession }
}
