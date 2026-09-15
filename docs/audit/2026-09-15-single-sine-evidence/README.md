# Local review evidence

These files record a disposable local Anvil run on chain 31337. They are
not public deployment records or addresses for a frontend configuration.

- `receipts.json`: 46 actions, including 39 successes and seven expected
  reverts. It also records eighteen successful deployment receipts and
  twenty-seven runtime/data checks.
- `curves.json`: the two rounds' materialized v3 values.
- `commands.txt`: commands executed with the public Anvil test key.
- `runtime-checks.log`: the creation/runtime check result.
- `numerical-review.md`: detailed settlement findings and regression inputs.

The run used port 18545, an 80-million block gas limit, and these explicit
settings: predeposit 259,200 seconds, vesting 2,419,200 seconds, maximum clock
248,660 seconds, no wallet cap, and launch price 75,000,000,000,000 wei.
`PSP_ANVIL=1` selected the mock tokens and PoolManager. The embedded HTML
was `script/testnet-status.html`. No environment file was sourced.

`FOUNDRY_BROADCAST` pointed into a temporary directory. The lifecycle runner
used `PSP_ANVIL_BROADCAST`, `PSP_ANVIL_RECEIPTS`, and `PSP_ANVIL_CURVES` to
keep its outputs separate. The owned Anvil process stopped after the checks.

The largest action used 9,797,172 gas. The funded inverse test separately
uses the real Uniswap v4 implementation. See the
[main review](../2026-09-15-single-sine-review.md) for open release blockers
and the final gate result.
