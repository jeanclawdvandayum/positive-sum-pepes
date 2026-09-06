import { keccak256, toHex } from 'viem'
import { descriptorAbi, stakerAbi } from './abi.ts'

type Address = `0x${string}`
type Read = (to: Address, abi: readonly unknown[], name: string, args?: readonly unknown[]) => Promise<unknown>
export interface WalletPepe { dna: bigint; tokenId?: bigint; svg?: string }

/** Same address mapping used by the ladder: hash the zero-padded address.
 * Address casing, browser sessions and round changes cannot change this DNA. */
export function addressPepeDna(address: Address): bigint {
  return BigInt(keccak256(toHex(BigInt(address), { size: 32 })))
}

export const walletPepeKey = (address: Address, staker?: Address) =>
  `${staker?.toLowerCase() ?? ''}:${address.toLowerCase()}`

/** Recheck ownership every poll; cache only immutable art for the same renderer
 * and DNA. Failed reads are retried instead of becoming a permanent "no NFT". */
export function createWalletPepeReader(read: Read) {
  let art: { key: string; svg: string } | undefined
  return async (address: Address, staker?: Address): Promise<WalletPepe> => {
    const fallback = { dna: addressPepeDna(address) }
    if (!staker || /^0x0*$/.test(staker)) return fallback
    const tokenId = await read(staker, stakerAbi, 'primaryOf', [address]) as bigint
    if (tokenId === 0n) {
      // New rounds resolve already-used wallet art to an available combination.
      // Legacy rounds have no preview getter; keep their stable address avatar.
      try { return { dna: await read(staker, stakerAbi, 'genesisPepeDna', [address]) as bigint } }
      catch { return fallback }
    }
    const [owner, dna, descriptor] = await Promise.all([
      read(staker, stakerAbi, 'ownerOf', [tokenId]) as Promise<Address>,
      read(staker, stakerAbi, 'dnaOf', [tokenId]) as Promise<bigint>,
      (read(staker, stakerAbi, 'descriptor') as Promise<Address>).catch(() => undefined),
    ])
    // A transfer between the primary lookup and the ownership read invalidates it.
    if (owner.toLowerCase() !== address.toLowerCase()) return fallback
    const nft = { tokenId, dna }
    if (!descriptor || /^0x0*$/.test(descriptor)) return nft
    const key = `${staker.toLowerCase()}:${descriptor.toLowerCase()}:${dna}`
    if (art?.key === key) return { ...nft, svg: art.svg }
    try {
      const svg = await read(descriptor, descriptorAbi, 'renderSVG', [dna]) as string
      art = { key, svg }
      return { ...nft, svg }
    } catch {
      // Keep the owned NFT's DNA when the renderer is temporarily unavailable.
      return nft
    }
  }
}
