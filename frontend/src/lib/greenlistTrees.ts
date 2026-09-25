import { parseGreenlistTree, type GreenlistTree } from './greenlist'
import type { Address, Hash } from 'viem'

/// Build-time-imported greenlist trees, keyed by FACTORY address (one csv
/// tree per deployment): drop `frontend/src/greenlists/<factory>.json` next
/// to this file — the deploy tooling writes it when the operator stages a
/// csv. A bundled tree is only used while its root still matches the live
/// round's GREEN_ROOT, so a stale file can never forge membership.

type GreenlistFile = { root: string; count: number; proofs: Record<string, string[]> }

const bundled = import.meta.glob('/src/greenlists/*.json', { import: 'default', eager: true }) as Record<string, GreenlistFile>

const byFactory = new Map<string, GreenlistTree>()
for (const [path, file] of Object.entries(bundled)) {
  const name = /\/([^/]+)\.json$/.exec(path)?.[1]
  if (name && /^0x[0-9a-fA-F]{40}$/.test(name)) {
    try { byFactory.set(name.toLowerCase(), parseGreenlistTree(file)) } catch { /* a malformed bundle is skipped, never fatal */ }
  }
}

/** The tree this frontend build shipped for a factory, if any. */
export function bundledGreenlist(factory: Address | undefined): GreenlistTree | undefined {
  return factory ? byFactory.get(factory.toLowerCase()) : undefined
}

/** A tree (bundled or uploaded) counts only while its root is the live one. */
export function treeMatchesRoot(tree: GreenlistTree | undefined, root: Hash | undefined): tree is GreenlistTree {
  return tree !== undefined && root !== undefined && tree.root.toLowerCase() === root.toLowerCase()
}
