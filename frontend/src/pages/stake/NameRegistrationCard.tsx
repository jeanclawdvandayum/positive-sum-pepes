import { useEffect, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useAccount, useSwitchChain, useWriteContract } from 'wagmi'
import { getAccount } from '@wagmi/core'
import { toHex } from 'viem'
import { ADDRESSES, CHAIN_ID, wagmiConfig } from '../../lib/config'
import { nameClient, nameNamespace as ns, nameQueryKey } from '../../lib/nameConfig'
import { assertNameFeeQuote, isNameLabel, nameCommitment, nameRegistrarAbi, normalizeNameLabel, parseNamePlan,
  readNameRegistration, type NamePlan } from '../../lib/nameRegistration'
import { wnsAbi } from '../../lib/weiNames'
import { confirmTransaction } from '../../lib/transactions'
import { isRpcUnavailable } from '../../lib/rpcErrors'

function errorMessage(error: unknown) {
  if (isRpcUnavailable(error)) return 'The name network is taking longer than usual. Check your wallet’s transaction history before retrying.'
  if (error instanceof Error) {
    return ('shortMessage' in error && typeof error.shortMessage === 'string' ? error.shortMessage : error.message).slice(0, 200)
  }
  return 'The name request failed. Please try again.'
}

export default function NameRegistrationCard() {
  const { address, chainId } = useAccount()
  const { switchChainAsync } = useSwitchChain()
  const { writeContractAsync } = useWriteContract()
  const queries = useQueryClient()
  const [label, setLabel] = useState('')
  const [planState, setPlanState] = useState<{ key: string; plan?: NamePlan }>()
  const [activity, setActivity] = useState<{ key: string; busy?: boolean; error?: string; done?: string }>()
  const key = `psp-name-commit:${ns.chainId}:${ns.registrar}:${ns.parentId}:${address?.toLowerCase()}`
  const plan = planState?.key === key ? planState.plan : undefined
  const status = activity?.key === key ? activity : undefined
  // A same-chain gate cannot read Base Sepolia from Ethereum. Cross-chain
  // registration stays disabled until its trust model and adapter are approved.
  const ready = !!ns.registrar && ns.chainId === CHAIN_ID
  const queryKey = ['name-registration', key, ADDRESSES.factory]
  const query = useQuery({
    queryKey,
    enabled: ready && !!address,
    queryFn: ({ signal }) => readNameRegistration(nameClient, ns, ADDRESSES.factory, address!, signal),
    refetchInterval: 15_000, staleTime: 10_000, retry: false,
  })
  useEffect(() => {
    try {
      const saved = parseNamePlan(localStorage.getItem(key))
      setPlanState({ key, plan: saved })
      setLabel(saved?.label ?? '')
    }
    catch { setPlanState({ key }) }
  }, [key])
  const state = query.isError ? undefined : query.data
  const matches = !!plan && !!address && !!state && state.commitment[0] === nameCommitment(ns, address, plan)
    && state.commitment[2] === state.epoch && state.commitment[3] === state.gateVersion
  const expires = state && matches ? state.commitment[1] + state.maxAge : 0n
  const reveal = !!state && matches && state.timestamp <= expires
  const wait = state && reveal ? Number(state.commitment[1] + state.minAge - state.timestamp) : 0
  const validLabel = isNameLabel(label)

  async function registerName() {
    if (!address || !ready || !ns.registrar || status?.busy) return
    setActivity({ key, busy: true })
    try {
      const expectedAccount = address
      const assertWallet = () => {
        const wallet = getAccount(wagmiConfig)
        if (wallet.address?.toLowerCase() !== expectedAccount.toLowerCase() || wallet.chainId !== ns.chainId) {
          throw Error('The wallet account or network changed. Try again with the intended wallet.')
        }
      }
      assertWallet()
      const fresh = await readNameRegistration(nameClient, ns, ADDRESSES.factory, address)
      const canReveal = plan && fresh.commitment[0] === nameCommitment(ns, address, plan)
        && fresh.commitment[2] === fresh.epoch && fresh.commitment[3] === fresh.gateVersion
        && fresh.timestamp <= fresh.commitment[1] + fresh.maxAge
      queries.setQueryData(queryKey, fresh)
      if (reveal && !canReveal) throw Error('The reservation expired or its configuration changed. Reserve the name again.')
      if (canReveal) assertNameFeeQuote(state?.price, fresh.price)
      if (canReveal && fresh.timestamp < fresh.commitment[1] + fresh.minAge) throw Error('The reservation is warming up. Registration opens after 60 seconds.')
      const next = canReveal ? plan : { label, salt: toHex(crypto.getRandomValues(new Uint8Array(32))) }
      if (!isNameLabel(next.label)) throw Error('Use 1–32 letters, numbers or hyphens, with a letter or number at each end.')
      const available = await nameClient.readContract({ address: ns.names, abi: wnsAbi, functionName: 'isAvailable',
        args: [next.label, ns.parentId], blockNumber: fresh.blockNumber })
      if (!available) throw Error('That name has an owner. Pick another alias.')
      if (!canReveal) {
        // Persist the secret before submitting. Reloads and wallet rejections
        // cannot leave a paid transaction dependent on a lost in-memory salt.
        localStorage.setItem(key, JSON.stringify(next))
        setPlanState({ key, plan: next })
      }
      const params = canReveal
        ? { address: ns.registrar, abi: nameRegistrarAbi, functionName: 'register' as const,
            args: [next.label, next.salt, fresh.proof] as const, value: fresh.price }
        : { address: ns.registrar, abi: nameRegistrarAbi, functionName: 'commit' as const,
            args: [nameCommitment(ns, address, next)] as const }
      await confirmTransaction({
        simulate: p => { assertWallet(); return nameClient.simulateContract({ ...p, account: address } as never) },
        submit: p => {
          assertWallet()
          return p.functionName === 'register'
            ? writeContractAsync({ ...p, account: address, chainId: CHAIN_ID })
            : writeContractAsync({ ...p, account: address, chainId: CHAIN_ID })
        },
        wait: async hash => {
          let replacementReason: string | undefined
          const receipt = await nameClient.waitForTransactionReceipt({ hash, timeout: 180_000,
            onReplaced: r => { if (r.reason !== 'repriced') replacementReason = r.reason } })
          return { ...receipt, replacementReason }
        },
      }, params)
      if (canReveal) {
        try { localStorage.removeItem(key) } catch { /* the confirmed registration remains successful */ }
        setPlanState({ key })
        setActivity({ key, done: `${next.label}.${ns.parentLabel}.wei` })
        await queries.invalidateQueries({ queryKey: nameQueryKey })
      } else setActivity({ key })
      await queries.invalidateQueries({ queryKey })
    } catch (error) {
      setActivity({ key, error: errorMessage(error) })
      await queries.invalidateQueries({ queryKey })
    }
  }

  return <section className="min-w-0 rounded-2xl border border-line bg-bg-2 p-4" aria-label="pepe name registration">
    <h2 className="text-sm font-semibold">put a name on that face</h2>
    <p className="mt-1 text-xs leading-relaxed text-text-lo">
      yourname.{ns.parentLabel}.wei · own a pepe holding PSP and registration is free.
      everyone else pays 0.0005 ETH. gas is paid separately.
    </p>
    {!ready ? <p className="mt-3 text-xs leading-relaxed text-text-lo">
      {ns.parentLabel}.wei lives on Ethereum. Registration is being prepared for this PSP deployment.
    </p> : <>
      <label className="mt-4 block text-xs text-text-lo" htmlFor="pepe-name">your alias</label>
      <div className="mt-2 flex min-w-0 flex-wrap items-center gap-2 rounded-lg border border-line bg-bg-1 p-3">
        <input id="pepe-name" className="min-w-0 flex-1 bg-transparent font-data text-text-hi outline-none"
          autoComplete="off" autoCapitalize="none" spellCheck={false} maxLength={32} placeholder="absolute-unit"
          value={reveal && plan ? plan.label : label} disabled={status?.busy || reveal}
          onChange={event => setLabel(normalizeNameLabel(event.target.value))} />
        <span className="shrink-0 font-data text-xs text-text-lo">.{ns.parentLabel}.wei</span>
      </div>
      <p className="mt-2 text-xs text-text-lo">1–32 letters, numbers or hyphens. Reserve, wait 60 seconds, then register.</p>
      {state && <p className="mt-2 text-sm text-text-hi">
        {state.price === 0n ? 'your funded pepe covers the registration fee.' : 'registration: 0.0005 ETH.'} plus network gas.
        {reveal && wait > 0 ? ` ready in about ${wait}s.` : ''}
      </p>}
      {query.isError && <p className="mt-2 break-words text-xs text-phase-critical">{errorMessage(query.error)}</p>}
      {address && chainId !== CHAIN_ID ? <button type="button" onClick={() => switchChainAsync({ chainId: CHAIN_ID }).catch(error => setActivity({ key, error: errorMessage(error) }))}
        className="mt-3 rounded-lg border border-line px-4 py-2 text-sm">switch to the registration network</button> :
        <button type="button" onClick={registerName} disabled={!address || !state || status?.busy || (reveal ? wait > 0 : !validLabel)}
          className="mt-3 w-full rounded-lg bg-accent px-4 py-3 text-sm font-semibold text-black disabled:opacity-40">
          {!address ? 'connect your wallet to register' : status?.busy ? 'waiting for confirmation…' : reveal ? 'register your name' : 'reserve your name'}
        </button>}
      {reveal && !status?.busy && <button type="button" className="mt-2 text-xs text-text-lo underline" onClick={() => {
        try { localStorage.removeItem(key) } catch { /* a new commit replaces the old one */ }
        setPlanState({ key }); setLabel('')
      }}>choose another name</button>}
    </>}
    {status?.error && <p className="mt-2 break-words text-xs text-phase-critical">{status.error}</p>}
    {status?.done && <p className="mt-2 break-words text-sm text-phase-calm">{status.done} is yours. Your name follows you around PSP.</p>}
    <p className="mt-3 text-xs leading-relaxed text-text-lo">names stay with their WNS wallet owner and depend on the parent domain’s renewal. The domain admin can recover the parent and reassign subdomains.</p>
  </section>
}
