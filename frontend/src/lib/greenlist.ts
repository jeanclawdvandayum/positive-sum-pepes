import { keccak256, concat, type Address, type Hash } from 'viem'

/// Greenlist-IBCO (rules v3) csv merkle tree — EXACTLY the controller's
/// format (RoundController._greenlisted):
///   leaf   = keccak256(abi.encodePacked(address))   — the 20 raw bytes
///   parent = keccak256(abi.encodePacked(left, right)) with left < right
///   odd level duplicates its last leaf
/// proofs carry the sibling hashes per level; the contract re-sorts each
/// step, so sibling order inside the proof never matters.

export type GreenlistTree = {
  root: Hash
  count: number
  proofs: Record<string, readonly Hash[]>
}

const ADDRESS = /^0x[0-9a-fA-F]{40}$/


/** keccak of the raw 20 address bytes — the on-chain leaf. */
export function greenLeaf(address: string): Hash {
  return keccak256(address.toLowerCase() as Address)
}

/** Sorted-pair parent; comparison is plain hex order (= bytes order). */
export function hashGreenPair(a: Hash, b: Hash): Hash {
  return a < b ? keccak256(concat([a, b])) : keccak256(concat([b, a]))
}

/** Normalize + dedupe a csv column of addresses; throws on a bad row.
 *  Each line contributes its first address-looking cell (bare lists work
 *  too); blank lines and `#` comments are skipped. */
export function parseGreenlistCsv(text: string): string[] {
  const rows: string[] = []
  text.split(/\r?\n/).forEach((line, i) => {
    const trimmed = line.trim()
    if (trimmed === '' || trimmed.startsWith('#')) return
    const hit = trimmed.split(',').find((cell) => ADDRESS.test(cell.trim().replace(/^0X/, '0x')))
    if (!hit) throw new Error(`greenlist row ${i + 1} has no address: ${trimmed.slice(0, 72)}`)
    rows.push(hit.trim().replace(/^0X/, '0x').toLowerCase())
  })
  return [...new Set(rows)]
}

/** Build the tree; leaves are sorted so the root is reproducible. */
export function buildGreenlist(addresses: Iterable<string>): GreenlistTree {
  const leaves = [...new Set([...addresses].map((a) => a.toLowerCase()))]
  for (const leaf of leaves) if (!ADDRESS.test(leaf)) throw new Error(`not an address: ${leaf}`)
  leaves.sort()
  const levels: Hash[][] = [leaves.map(greenLeaf)]
  while (levels[levels.length - 1].length > 1) {
    const level = [...levels[levels.length - 1]]
    if (level.length % 2) level.push(level[level.length - 1])
    levels.push(Array.from({ length: level.length / 2 }, (_, i) => hashGreenPair(level[2 * i], level[2 * i + 1])))
  }
  const proofs: Record<string, readonly Hash[]> = {}
  leaves.forEach((address, index) => {
    const proof: Hash[] = []
    let at = index
    for (const level of levels.slice(0, -1)) {
      const sibling = at % 2 ? at - 1 : at + 1
      proof.push(level[Math.min(sibling, level.length - 1)])
      at = Math.floor(at / 2)
    }
    proofs[address] = proof
  })
  if (leaves.length === 0) throw new Error('greenlist is empty')
  return { root: levels[levels.length - 1][0], count: leaves.length, proofs }
}


/** Mirrors the contract's verification loop — same result on a valid proof. */
export function verifyGreenProof(address: string, proof: readonly `0x${string}`[], root: Hash): boolean {
  let leaf = greenLeaf(address)
  for (const step of proof) leaf = leaf < step ? keccak256(concat([leaf, step])) : keccak256(concat([step, leaf]))
  return leaf === root
}

/** Validate a parsed tree JSON (bundled asset or manual upload). */
export function parseGreenlistTree(value: unknown): GreenlistTree {
  if (!value || typeof value !== 'object') throw new Error('greenlist file: not a JSON object')
  const { root, count, proofs } = value as Record<string, unknown>
  if (typeof root !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(root)) throw new Error('greenlist file: missing root')
  if (typeof count !== 'number' || !Number.isInteger(count) || count < 0) throw new Error('greenlist file: missing count')
  if (!proofs || typeof proofs !== 'object' || Array.isArray(proofs)) throw new Error('greenlist file: missing proofs')
  const checked: Record<string, readonly Hash[]> = {}
  for (const [address, proof] of Object.entries(proofs)) {
    if (!ADDRESS.test(address)) throw new Error(`greenlist file: bad address key ${address.slice(0, 12)}…`)
    if (!Array.isArray(proof) || !proof.every((step) => typeof step === 'string' && /^0x[0-9a-fA-F]{64}$/.test(step)))
      throw new Error(`greenlist file: bad proof for ${address.slice(0, 12)}…`)
    checked[address.toLowerCase()] = proof as Hash[]
  }
  return { root: root as Hash, count, proofs: checked }
}
