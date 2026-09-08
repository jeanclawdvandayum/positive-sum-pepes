export type TxStage = 'preparing' | 'simulating' | 'wallet' | 'pending' | 'success' | 'failed' | 'unknown'
export type TxToast = { id: number; label: string; chainId: number; account: `0x${string}`; stage: TxStage; hash?: `0x${string}`; detail?: string; updated: number }
let entries: TxToast[] = []
let nextId = 0
const listeners = new Set<() => void>()
const dismissed = new Set<number>()
export const transactionToasts = {
  subscribe(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener) } },
  snapshot: () => entries,
  dismiss(id: number, manual = true) {
    if (manual) dismissed.add(id)
    entries = entries.filter(entry => entry.id !== id)
    listeners.forEach(listener => listener())
  },
}

export function startTransactionToast(label: string, chainId: number, account: `0x${string}`) {
  let entry: TxToast = { id: ++nextId, label, chainId, account, stage: 'preparing', updated: Date.now() }
  const update = (stage: TxStage, hash?: `0x${string}`, detail?: string) => {
    entry = { ...entry, stage, hash: hash ?? entry.hash, detail, updated: Date.now() }
    if (dismissed.has(entry.id)) return
    entries = [...entries.filter(item => item.id !== entry.id), entry]
    listeners.forEach(listener => listener())
  }
  update('preparing')
  return {
    update,
    fail(error: unknown) {
      if (['success', 'failed', 'unknown'].includes(entry.stage)) return
      const detail = error instanceof Error ? ('shortMessage' in error ? String(error.shortMessage) : error.message) : 'Please try again.'
      update(entry.hash ? 'unknown' : 'failed', undefined, detail.slice(0, 200))
    },
  }
}

export function transactionLabel(name: string) {
  return ({ drip: 'mint mixETH', approve: 'token approval', setApprovalForAll: 'Pepe approval',
    buyWithMix: 'buy PSP', sell: 'sell PSP', claim: 'claim fees', claimFees: 'claim fees',
    reinvest: 'reinvest fees', reinvestAll: 'reinvest all', claimMany: 'claim all fees',
    requestWithdraw: 'start withdrawal', cancelWithdraw: 'keep staking', withdraw: 'unlock PSP',
    stakeFor: 'add PSP', lockWithPepe: 'stake PSP', detonate: 'detonate round',
    commit: 'reserve name', register: 'register name',
  } as Record<string, string>)[name] ?? name.replace(/([A-Z])/g, ' $1').toLowerCase()
}
