import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useAccount } from 'wagmi'
import { factoryAbi, registryAbi } from '../lib/abi'
import { ADDRESSES, CHAIN_ID } from '../lib/config'
import { fmtAmount } from '../lib/format'
import { referralRewardsVersion } from '../lib/referralRewards'
import { rpcCall } from '../lib/rpc'
import { useConfirmedWrite } from '../lib/useConfirmedWrite'

/** Wallet credit remains visible when the wallet holds zero NFTs. */
export default function ReferralRewards({ roundId, className = '' }: { roundId?: bigint; className?: string }) {
  const { address } = useAccount()
  const { writeContractAsync } = useConfirmedWrite({ referralClaimRoundId: roundId })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<{ account: string; roundId: bigint; message: string }>()
  const rewards = useQuery({
    queryKey: ['referral-rewards', CHAIN_ID, ADDRESSES.factory, roundId?.toString(), address],
    enabled: !!roundId && !!address,
    queryFn: async () => {
      const registry = await rpcCall(ADDRESSES.factory, factoryAbi, 'referralRegistryOf', [roundId!]) as `0x${string}`
      if (/^0x0+$/i.test(registry)) throw new Error('Referral registry unavailable.')
      const version = await referralRewardsVersion(() => rpcCall(registry, registryAbi, 'REFERRAL_REWARDS_VERSION') as Promise<bigint>)
      if (version === 0n) return { registry, supported: false as const }
      if (version !== 1n) throw new Error('This round uses an unsupported referral rewards version.')
      const amount = await rpcCall(registry, registryAbi, 'claimableReferral', [address!]) as bigint
      return { registry, supported: true as const, amount }
    },
    refetchInterval: 6000,
    staleTime: 3000,
    retry: 1,
  })

  if (!address || !roundId || rewards.data?.supported === false || (rewards.isPending && !rewards.isError)) return null
  const amount = rewards.data?.supported ? rewards.data.amount : undefined
  const claimError = error?.account === address && error.roundId === roundId ? error.message : undefined

  async function claim() {
    if (!address || !roundId || !rewards.data?.supported || busy) return
    setBusy(true)
    setError(undefined)
    try {
      await writeContractAsync({ address: rewards.data.registry, abi: registryAbi, functionName: 'claimReferralRewards' })
      await rewards.refetch()
    } catch (cause) {
      setError({ account: address, roundId, message: cause instanceof Error ? cause.message.slice(0, 200) : 'Referral claim failed. Please try again.' })
    } finally { setBusy(false) }
  }

  return <div className={`border-t border-line pt-4 ${className}`} aria-label={`round ${roundId} referral rewards`}>
    <h3 className="font-display text-lg text-text-hi">referral rewards</h3>
    <p className="mt-2 text-xs leading-relaxed text-text-lo">earned mixETH stays with your wallet. claim it here, even after the round ends or your pepe changes hands.</p>
    {rewards.isError ? <p role="status" className="mt-3 text-xs text-phase-critical">referral rewards could not load. retrying…</p>
      : <button type="button" className="tx-action st-btn st-btn-primary mt-3 w-full" disabled={busy || amount === undefined || amount === 0n}
        onClick={() => { void claim() }}>
        {busy ? 'claiming referral rewards…' : `claim ${fmtAmount(amount ?? 0n)} mixETH referral rewards`}
      </button>}
    {claimError && <p role="alert" className="mt-2 break-words text-xs text-phase-critical">{claimError}</p>}
  </div>
}
