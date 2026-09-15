import { factoryAbi, controllerAbi, hookAbi } from './abi.ts'
import { assertGameRules, GameRulesMismatch } from './gameRules.ts'
import type { Zone } from './curve'
type Address = `0x${string}`
type Read = (to: Address, abi: readonly unknown[], name: string, args?: readonly unknown[]) => Promise<unknown>

/** Registry entries and hook constructor fields are immutable. Cache only
 * completed reads; an RPC failure must retry, not become a rules mismatch. */
export function createRoundMetadataReader(factory: Address, read: Read) {
  const cache = new Map<bigint, Promise<Awaited<ReturnType<typeof fetchMetadata>>>>()
  async function fetchMetadata(id: bigint) {
    const [entry, mix] = await Promise.all([
      read(factory, factoryAbi, 'rounds', [id]), read(factory, factoryAbi, 'mixETH'),
    ])
    const [token, controller, hook] = entry as [Address, Address, Address]
    // TICKET_RULES_VERSION gates everything else: on v3 the hook's
    // MIN_BUY_INPUT() IS the live ticket price, so it is never fetched or
    // cached here — only immutable capabilities and addresses are. Legacy
    // (v1/v2) hooks keep the immutable 0.005 constant, safe to pin once.
    const [staker, cfg, detWindow, seconds, sineConfigured, ticketRules] = await Promise.all([
      read(controller, controllerAbi, 'staker'), read(hook, hookAbi, 'curveConfig'),
      read(hook, hookAbi, 'detWindow'),
      read(hook, hookAbi, 'TIME_PER_UNIT'), read(hook, hookAbi, 'sineConfigured'),
      read(hook, hookAbi, 'TICKET_RULES_VERSION'),
    ])
    let rulesCompatible = true
    try {
      if (ticketRules === 3n) {
        // v3 compat rests on immutable facts only (clock seconds). The
        // dynamic minimum is read live per tick and never enters this cache.
        assertGameRules(1n, seconds as bigint, 3n)
      } else {
        const minimum = await read(hook, hookAbi, 'MIN_BUY_INPUT') as bigint
        assertGameRules(minimum, seconds as bigint, ticketRules as bigint)
      }
    }
    catch (error) { if (!(error instanceof GameRulesMismatch)) throw error; rulesCompatible = false }
    const zones = sineConfigured ? [] : await read(hook, hookAbi, 'getCurveZones') as Zone[]
    return { token, controller, hook, mix: mix as Address, staker: staker as Address,
      cfg: cfg as [bigint, bigint], detWindow: detWindow as bigint, zones, rulesCompatible,
      ticketRules: ticketRules as bigint }
  }
  return (id: bigint) => {
    let promise = cache.get(id)
    if (!promise) {
      promise = fetchMetadata(id)
      cache.set(id, promise)
      promise.catch(() => cache.delete(id))
    }
    return promise
  }
}
