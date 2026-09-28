// Test-only write-blocker for the fixture harness — aliased in place of
// `lib/useConfirmedWrite` by vite.fixture.config. Same exported hook name,
// but the confirmed write always fails closed before touching a wallet
// client: the harness cannot sign or send, even with a real wallet connected.
type FixtureWriteArgs = Record<string, unknown> & { functionName?: string }

export interface ConfirmedWriteApi {
  writeContractAsync: (parameters: FixtureWriteArgs, validateOnly?: boolean) => Promise<`0x${string}` | undefined>
}

const FAIL = async (): Promise<never> => {
  throw new Error('fixture harness is read-only — writes are disabled')
}

export function useConfirmedWrite(..._args: unknown[]): ConfirmedWriteApi {
  return { writeContractAsync: FAIL }
}
