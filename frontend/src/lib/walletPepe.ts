import { keccak256, toHex } from 'viem'
import { stakerAbi } from './abi.ts'

type Address = `0x${string}`
type Read = (to: Address, abi: readonly unknown[], name: string, args?: readonly unknown[]) => Promise<unknown>
export interface WalletPepe { dna: bigint; tokenId?: bigint; svg?: string }

/** Stable placeholder while round art is loading, or for legacy deployments.
 * Genesis previews and owned NFTs use the DNA returned by their staker. */
export function addressPepeDna(address: Address): bigint {
  return BigInt(keccak256(toHex(BigInt(address), { size: 32 })))
}

export const walletPepeKey = (address: Address, staker?: Address) =>
  `${staker?.toLowerCase() ?? ''}:${address.toLowerCase()}`

/** Recheck ownership every poll; cache only immutable art for the same renderer
 * and DNA. Failed reads are retried instead of becoming a permanent "no NFT". */
export function createWalletPepeReader(read: Read) {
  return async (address: Address, staker?: Address): Promise<WalletPepe> => {
    const fallback = { dna: addressPepeDna(address) }
    if (!staker || /^0x0*$/.test(staker)) return fallback
    const tokenId = await read(staker, stakerAbi, 'primaryOf', [address]) as bigint
    if (tokenId === 0n) {
      // The staker previews its round-seeded art and resolves used combinations.
      // Legacy rounds have no preview getter; keep their stable address avatar.
      try { return { dna: await read(staker, stakerAbi, 'genesisPepeDna', [address]) as bigint } }
      catch { return fallback }
    }
    const [owner, dna] = await Promise.all([
      read(staker, stakerAbi, 'ownerOf', [tokenId]) as Promise<Address>,
      read(staker, stakerAbi, 'dnaOf', [tokenId]) as Promise<bigint>,
    ])
    // A transfer between the primary lookup and the ownership read invalidates it.
    if (owner.toLowerCase() !== address.toLowerCase()) return fallback
    // The chain is the source of truth for the DNA only; the pepe image is
    // rendered locally from the bundled art data (no descriptor/renderSVG
    // RPC per NFT) — useWalletPepe resolves the art by the round's version.
    return { tokenId, dna }
  }
}
