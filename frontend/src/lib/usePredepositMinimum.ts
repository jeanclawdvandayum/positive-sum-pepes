import { useQuery } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { CHAIN_ID } from './config'
import { controllerAbi } from './abi'
import { rpcCall } from './rpc'
import { predepositMinimum } from './predeposit'
import { controllerFacts, readPredepositState, type ControllerFacts, type PredepositStateView } from './predepositState'

/** Immutable capability, separately queried so a legacy controller's missing
 * selector cannot break its existing state reads. Keys isolate round changes. */
export function usePredepositRules(controller?: `0x${string}`) {
  const result = useQuery({
    queryKey: ['predeposit-rules', CHAIN_ID, controller],
    enabled: !!controller,
    queryFn: () => rpcCall(controller!, controllerAbi, 'PREDEPOSIT_RULES_VERSION'),
    staleTime: Infinity, retry: false,
  })
  return { version: result.data, minimum: predepositMinimum(result.data) }
}

export function usePredepositMinimum(controller?: `0x${string}`) {
  return usePredepositRules(controller).minimum
}

/** Era-aware predepositState + window facts for one controller, polled like
 * every other read in this app (raw eth_call; see useRound's header note).
 * Legacy rounds decode the 7-tuple, rules-v3 the 11-tuple — callers see one
 * normalized shape with phase/green fields undefined on legacy rounds. */
export function usePredepositState(controller: `0x${string}` | undefined, intervalMs = 4000, refreshKey = 0) {
  const [state, setState] = useState<PredepositStateView | undefined>(undefined)
  const [facts, setFacts] = useState<ControllerFacts | undefined>(undefined)
  useEffect(() => {
    setState(undefined)
    setFacts(undefined)
    if (!controller) return
    let dead = false
    async function tick() {
      const f = await controllerFacts(controller!)
      const s = await readPredepositState(controller!, f.rules)
      if (dead) return
      setFacts(f)
      if (s) setState(s)
    }
    tick()
    const iv = setInterval(tick, intervalMs)
    return () => { dead = true; clearInterval(iv) }
  }, [controller, intervalMs, refreshKey])
  return { state, facts }
}
