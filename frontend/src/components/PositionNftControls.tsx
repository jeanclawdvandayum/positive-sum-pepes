import { useState } from 'react'
import { useAccount } from 'wagmi'
import { zeroAddress } from 'viem'
import { ADDRESSES } from '../lib/config'
import { stakerAbi } from '../lib/abi'
import { useConfirmedWrite } from '../lib/useConfirmedWrite'
import { nftRecipient, type NftVersion } from '../lib/nftPermissions'
import { fmtAmount } from '../lib/format'
import { userFacingRpcError } from '../lib/rpcErrors'

export default function PositionNftControls({ staker, roundId, id, amount, version, approved, approvedAll, disabled, onBusy, onDone }: {
  staker: `0x${string}`; roundId: bigint; id: bigint; amount: bigint; version: NftVersion
  approved: `0x${string}` | undefined; approvedAll: boolean | undefined; disabled: boolean
  onBusy: (busy: boolean) => void; onDone: () => void
}) {
  const { address } = useAccount()
  const { writeContractAsync } = useConfirmedWrite({ nftRoundId: roundId })
  const [recipient, setRecipient] = useState('')
  const [review, setReview] = useState<`0x${string}` | undefined>()
  const [error, setError] = useState('')
  const [status, setStatus] = useState('')
  const hasApproval = approved !== undefined && approved.toLowerCase() !== zeroAddress
  function reviewTransfer() {
    setError(''); setStatus('')
    if (!address) { setError('Connect your wallet to transfer this Pepe.'); return }
    try { setReview(nftRecipient(recipient, address, staker)) }
    catch (e) { setError((e as Error).message) }
  }
  async function act(action: 'transfer' | 'revoke' | 'revokeAll') {
    if (disabled || !address) return
    onBusy(true); setError(''); setStatus('')
    try {
      if (action === 'transfer') {
        if (!review) return
        await writeContractAsync({ address: staker, abi: stakerAbi, functionName: 'safeTransferFrom', args: [address, review, id] })
        setReview(undefined); setRecipient(''); setStatus('Pepe transferred.')
      } else if (action === 'revoke') {
        await writeContractAsync({ address: staker, abi: stakerAbi, functionName: 'approve', args: [zeroAddress, id] })
        setStatus('Individual approval revoked.')
      } else {
        await writeContractAsync({ address: staker, abi: stakerAbi, functionName: 'setApprovalForAll', args: [ADDRESSES.reinvestor, false] })
        setStatus('Reinvestor collection approval revoked. Individual approvals remain separate.')
      }
      onDone()
    } catch (e) {
      const friendly = userFacingRpcError(e)
      setError(friendly instanceof Error ? friendly.message.slice(0, 220) : 'Transaction failed. Try again.')
    } finally { onBusy(false) }
  }
  return <details className="rounded-xl border border-line p-3 text-xs">
    <summary className="cursor-pointer font-semibold text-text-hi">manage pepe NFT</summary>
    <div className="mt-3 space-y-3">
      {version === 1 ? <>
        <p className="text-text-lo">Transfer this Pepe with its {fmtAmount(amount)} PSP, earned fees and withdrawal timer. Contract recipients must accept ERC-721 transfers.</p>
        <label className="block text-text-lo" htmlFor={`recipient-${id}`}>recipient address</label>
        <input id={`recipient-${id}`} className="w-full min-w-0 rounded-lg border border-line bg-bg-0 p-3 font-data text-xs" value={recipient}
          disabled={disabled} placeholder="0x…" autoComplete="off" spellCheck={false}
          onChange={e => { setRecipient(e.target.value); setReview(undefined); setError('') }} />
        {review ? <div className="space-y-2 rounded-lg bg-bg-2 p-3">
          <p className="break-all">Send pepe #{id.toString()} and its entire position to:</p>
          <p className="break-all font-data">{review}</p>
          <button className="st-btn w-full text-xs" disabled={disabled} onClick={() => act('transfer')}>confirm transfer</button>
        </div> : <button className="st-btn w-full text-xs" disabled={disabled || !recipient.trim()} onClick={reviewTransfer}>review transfer</button>}
        <div className="border-t border-line pt-3 text-text-lo">
          <p>Individual approval allows transfers and fee claims for this Pepe. It clears when the NFT transfers.</p>
          <p className="mt-2 break-all font-data">{approved === undefined ? 'loading approval…' : hasApproval ? approved : 'individual approval: none'}</p>
          {hasApproval && <button className="st-btn mt-2 w-full text-xs" disabled={disabled} onClick={() => act('revoke')}>revoke this Pepe’s approval</button>}
        </div>
      </> : <p className="text-text-lo">{version === 0 ? 'This round uses the original NFT contract. Safe transfers and individual approvals arrive with the upgraded deployment.' : 'Checking NFT support…'}</p>}
      {approvedAll && <div className="space-y-2 border-t border-line pt-3">
        <p className="text-text-lo">The reinvestor has transfer and fee-claim permission for all your Pepes in this round.</p>
        <button className="st-btn w-full text-xs" disabled={disabled} onClick={() => act('revokeAll')}>revoke collection approval</button>
      </div>}
      {status && <p role="status" className="text-pepe">{status}</p>}
      {error && <p role="alert" className="break-words text-phase-critical">{error}</p>}
    </div>
  </details>
}
