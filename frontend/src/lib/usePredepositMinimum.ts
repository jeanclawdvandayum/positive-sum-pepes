import { useQuery } from '@tanstack/react-query'
import { CHAIN_ID } from './config'
import { controllerAbi } from './abi'
import { rpcCall } from './rpc'
import { predepositMinimum } from './predeposit'

/** Immutable capability, separately queried so a legacy controller's missing
 * selector cannot break its existing state reads. Keys isolate round changes. */
export function usePredepositMinimum(controller?: `0x${string}`) {
  const result = useQuery({
    queryKey: ['predeposit-rules', CHAIN_ID, controller],
    enabled: !!controller,
    queryFn: () => rpcCall(controller!, controllerAbi, 'PREDEPOSIT_RULES_VERSION'),
    staleTime: Infinity, retry: false,
  })
  return predepositMinimum(result.data)
}
