# Validation record

Source baseline: `926e4b46`. Final production source hash:
`7279ecbaa4cbf13648cc68faa3a1561fab50a4ef69cd54d9836a103224f75a4d`.
Hash algorithm: sorted src/**/*.sol relative path, NUL, file contents (37 files).

## Deterministic gate

`bash scripts/check-audit.sh` completed with exit 0:

- **437 Solidity tests / 60 suites**, zero failures/skips; suite time 26.43s.
- **68 frontend tests**, zero failures.
- **111 ABI declarations**, including exact PoolKey encoding.
- **32 production size checks**.
- Independent Decimal/Simpson oracle vectors and no-governance gate.
- TypeScript and Vite build; Vite completed in 8.39s. Existing bundle/annotation
  warnings remain; no frontend source or deployment configuration changed.

The first complete run passed 436 tests after a 533.51s Solidity compilation.
A final partial-genesis/owner-accounting regression was then included in the
final 437-test run (incremental compilation 5.61s). No source fixes followed
the final gate.

## Additional accounting campaign

```sh
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 \
  forge test --match-contract MultiOwnerStatefulTest -vv
```

Passed 256 runs / **32,768 handler calls / zero reverts**, plus the deterministic
interleaved-actions test, in 52.39s. The campaign now independently sums each
owner's position principal and compares it with stakedTotalOf, in addition to
backing/fee/pot solvency, global weight, token supply and complete exits.
Handler calls can intentionally be no-ops when their action is inapplicable;
the deterministic sequence separately asserts all nine financial action types
were exercised. Call count is not a claim that every call executed a trade.

## Before/after evidence

before-test-results.txt preserves the failing regression outputs for AUD-16
through AUD-21. Eleven new tests are included in the final gate:

- SkillCallbackReview: two payout pins plus a five-tier ownership fuzz model.
- SkillLifecycleReview: two staged-birth liveness/security cases on real V4.
- SkillStakingReview: epoch zero, crowded genesis mint, unsolicited-NFT
  qualification gas, partial genesis/transfer/top-up/exit accounting,
  independent fresh-ID fuzz, and uint256-edge chosen IDs.

Both new fuzz properties passed 256 cases. Gas limits on the two crowding
tests apply to the victim call; setup costs are separate. The cold-chain cost
of funding thousands of nuisance NFTs is not claimed to be free of gas costs.

## Deployment sizes

| Contract | Runtime bytes | Initcode bytes, before constructor args |
| --- | ---: | ---: |
| CurveHook | 23,243 | 24,829 |
| PSPFactory | 20,442 | 27,384 |
| PSPStaker | 12,001 | 12,362 |
| StakerDeployer | 13,220 | 13,246 |
| ControllerDeployer | 22,622 | 22,648 |

Existing EIP-170 gate exclusion for the undeployable experimental
VectorPepeDescriptor remains explicit. Production staged-birth gas tests pass;
the new real-V4 cases constrain each birthStep to 12,000,000 gas. No live
deployment or new external RPC fork run was performed.

## Static checks and logs

Fresh Slither build and ERC20/ERC721 interface checks are recorded in
STATIC-ANALYSIS.md. Static analysis returned flags and was manually triaged;
it is not counted as a clean detector gate. git diff --check passes for the
reviewed source, tests and audit packet.

Local raw logs:

- /tmp/psp-skills-final-gate.log
- /tmp/psp-skills-long-invariant.log
- /tmp/psp-skills-before.log
- /tmp/psp-skills-staking-before.log
- /tmp/psp-skills-qualification-before.log
- /tmp/psp-skills-production-build.log
- /tmp/psp-skills-slither-20260906.json
- /tmp/psp-skills-erc20.log
- /tmp/psp-skills-erc721.log

These temporary paths are conveniences; the source tests, saved failure
excerpts, static inventory and commands are retained in the repository.
