import { rpcCall } from './rpc'
import { controllerAbi, legacyControllerAbi } from './abi'
import { normalizePredepositState, type PredepositStateView } from './predeposit'
import { predepositResult, type PredepositEntry } from './chainResults'
import type { Address } from 'viem'

/// Era-aware reads around predepositState: decode with the ABI the round's
/// era answers in (viem refuses mismatched static arity), then hand every
/// caller the one normalized shape from ./predeposit.

export type { PredepositStateView }

/// Per-controller immutable facts, read once and cached: the rules version
/// plus whichever window immutables that era carries.
export interface ControllerFacts {
  rules: bigint | undefined
  greenSec: bigint | undefined
  openSec: bigint | undefined
  legacySec: bigint | undefined
}

const NO_FACTS: ControllerFacts = { rules: undefined, greenSec: undefined, openSec: undefined, legacySec: undefined }
const factsCache = new Map<string, Promise<ControllerFacts>>()

async function fetchFacts(controller: Address): Promise<ControllerFacts> {
  let rules: bigint | undefined
  try {
    rules = await rpcCall(controller, legacyControllerAbi, 'PREDEPOSIT_RULES_VERSION') as bigint
  } catch {
    rules = undefined // pre-rules controller — try the legacy window below
  }
  if (rules === 3n) {
    try {
      const [greenSec, openSec] = await Promise.all([
        rpcCall(controller, controllerAbi, 'GREEN_DURATION') as Promise<bigint>,
        rpcCall(controller, controllerAbi, 'OPEN_DURATION') as Promise<bigint>,
      ])
      return { rules, greenSec, openSec, legacySec: undefined }
    } catch {
      return NO_FACTS
    }
  }
  try {
    return { rules, greenSec: undefined, openSec: undefined, legacySec: await rpcCall(controller, legacyControllerAbi, 'PREDEPOSIT_DURATION') as bigint }
  } catch {
    return { ...NO_FACTS, rules }
  }
}

export function controllerFacts(controller: Address): Promise<ControllerFacts> {
  let cached = factsCache.get(controller)
  if (!cached) {
    cached = fetchFacts(controller).catch(() => NO_FACTS)
    factsCache.set(controller, cached)
  }
  return cached
}

/// One predepositState read, decoded with the ABI its era answers in.
export async function readPredepositState(controller: Address, version?: bigint): Promise<PredepositStateView | undefined> {
  const decode = async (abi: readonly unknown[]) => normalizePredepositState(await rpcCall(controller, abi, 'predepositState'))
  if (version === 3n) return decode(controllerAbi).catch(() => undefined)
  if (version !== undefined) return decode(legacyControllerAbi).catch(() => undefined)
  for (const abi of [controllerAbi, legacyControllerAbi]) {
    const state = await decode(abi).catch(() => undefined)
    if (state) return state
  }
  return undefined
}

/// Facts + one state read in a single await (the round lane's shape).
export async function readPredepositLane(controller: Address): Promise<{ facts: ControllerFacts; state: PredepositStateView | undefined }> {
  const facts = await controllerFacts(controller)
  const state = await readPredepositState(controller, facts.rules).catch(() => undefined)
  return { facts, state }
}

/** Read one wallet's predeposit entry from any controller era. The ABI is
 *  selected by the controller's PREDEPOSIT_RULES_VERSION (v3 grew the
 *  greenAmount field; older rounds return the 2-tuple) and the result is
 *  normalized through predepositResult — never decoded by hand.
 *  Version per controller is cached for the session. */
const versionCache = new Map<string, bigint>()

export async function readPredeposit(
  controller: `0x${string}`,
  who: `0x${string}`,
): Promise<PredepositEntry> {
  let version = versionCache.get(controller.toLowerCase())
  if (version === undefined) {
    version = await rpcCall(controller, legacyControllerAbi, 'PREDEPOSIT_RULES_VERSION') as bigint
    versionCache.set(controller.toLowerCase(), version)
  }
  const abi = version === 3n ? controllerAbi : legacyControllerAbi
  return predepositResult(await rpcCall(controller, abi, 'predeposits', [who]))
}
