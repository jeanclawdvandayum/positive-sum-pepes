# Current smart-contract assessment — September 21, 2026

> Follow-up: the subsequent verification work fixed the failing harnesses,
> strengthened accounting tests, and corrected the proof claims. See
> [FORMAL-VERIFICATION](FORMAL-VERIFICATION.md) and the latest GATE-LOG entry.
> The assessment below preserves the state before those changes.

## Decision

**Conditional release assessment for `single-sine-spec` at `38222f7f`.** This review found no new confirmed contract exploit. The previous contract repairs remain in place. However, the current deterministic gate fails, and the formal report overstates its strongest result. Correct the test harness and assurance record before treating this revision as release-ready.

| Category | Result |
| --- | --- |
| New confirmed Critical / High / Medium contract vulnerabilities | 0 / 0 / 0 in this bounded review |
| Known integration risk | Generic routers can strand ladder proceeds |
| Release checks | One reproducible Forge harness failure |
| Formal assurance | Partial checks of the numerical core, not whole-protocol verification |
| Source changes during this review | None |

## Revision and scope

The review started at `32e7ff78`. An external rebase during the review advanced HEAD to `38222f7f`, adding the upstream Halmos profile and gate entry beneath the two Fable commits. Contract, script, and test sources are identical between those revisions. The default Foundry profile is unchanged. The branch matched its remote-tracking reference at the final status check. This assessment does not include a public-chain bytecode check.

`git diff e9a70d44..38222f7f -- src script` is empty. Four newer commits add audit reports, tests, and a Halmos profile. Thus the contract and deployment sources match the revision named by the DinoSAT and Fable reports. The full change contains nine files and 1,628 added lines, with no removed lines.

The review covered the numerical helper, its data and inverse, hook settlement, controller bootstrap and death, staking liabilities, factory lifecycle, referral escrow, and the transaction wrappers. Three bounded parallel review lanes checked custody/lifecycle, numerical proof scope, and periphery. This was not a new full twelve-lens audit. Dependencies, deployed bytecode, production mixETH behavior, and every possible transaction sequence remain outside this review's proof scope.

## What now works

- The single sine curve uses the softened cube root, square-root wavelength, and the 500-gross / 450-net calibration. The tenth wave reaches the intended 1,000-times launch price.
- Price and supply use ordered integer operations and shared cell endpoints. The original adjacent-wei regressions pass in the fresh suite.
- The sell inverse has forced bracket contraction and endpoint/minimality checks. It cannot settle an unresolved Newton estimate.
- The helper pins four data shards by runtime identity. The source contains no data replacement route.
- Bootstrap admission checks the actual genesis calculation and preserves nonzero allocations for positive deposit shares.
- GraveZap checks caller ownership of every selected NFT. Reinvestment checks the round hook and allocates the complete newly bought balance.
- Active ticket cost is the ceiling of accounted pot divided by 10,000, with a one-wei floor. The gross minimum equals that ticket cost. Pre-fee sampling preserves the ticket on an exact-minimum buy.

These conclusions combine source inspection and passing regression tests. They do not establish economic immunity to transaction ordering or coordinated players.

## A1 — The current deterministic gate fails

**Priority: fix before release. This is a test defect, not a contract counterexample.**

The fresh `bash scripts/check-audit.sh` run stopped after Forge: **777 passed, 1 failed, 0 skipped, 95 suites, 778 total**.

`test_check_phaseat_monotone_pos_q4(uint88)` rejects too many generated inputs. Its assumptions accept only a narrow quarter-wave interval inside the much larger uint88 domain. Forge exhausted 65,536 rejected inputs after 252 accepted runs.

The failure reproduces with a fixed seed:

```bash
forge test --match-contract SineV3PriceSymbolicTest \
  --match-test test_check_phaseat_monotone_pos_q4 --fuzz-seed 0x1
```

That run exhausted the rejection limit after 207 accepted runs. See `test/dinosat/SineV3PriceSymbolic.t.sol:54`. Commit `0f08c032` introduced this harness.

Keep symbolic assumptions for the solver. Give Forge bounded-input wrappers for all affected branches, or separate symbolic-only entry points from the default Forge suite. Do not delete the assertions or raise rejection limits as the sole fix. The existing wrappers do not cover each positive quarter separately.

## A2 — The strongest reported symbolic success proves a plateau

**Priority: correct the assurance claim before release. No production defect follows from this result.**

The report calls terminal cell 4936 a real proof of within-cell monotonicity. Its two stored endpoints are equal:

```text
knot(4936) = knot(4937) = 806044833904933035529253658260054526
```

`SineV3Primitive._prepare` returns immediately when this span is zero (`src/SineV3Primitive.sol:123`). The controls remain zero. Therefore the successful check proves monotonicity of a constant output. It does not exercise the nonconstant Bernstein interpolation whose proof attempts timed out.

The same report lists cell 4936 under strict knot ordering. However, the test loop uses `k < cells.length - 1`, so it skips that final listed cell (`test/dinosat/SineV3PrimitiveSymbolic.t.sol:135`). The plateau is valid rounded behavior. A truthful test should distinguish nondecreasing knots from strictly increasing selected cells.

Correct `audits/DINOSAT-REPORT.md:16`, `:32`, and `:34`. Label the terminal result as a plateau proof. Do not imply that it establishes the active nonconstant interpolation.

## What the formal campaign establishes

| Evidence | Actual scope |
| --- | --- |
| Terminal-cell symbolic PASS | Constant plateau at the canonical fixture |
| Negative-cell PASS results | Out-of-cell saturation for the selected launch fixture, already labeled vacuous in the report |
| Wavelength identities | Three concrete launch amounts, not all admitted amounts |
| Domain and seam checks | Selected concrete boundary cases |
| Cells 711, 716, 1000 | No symbolic verdict after the recorded long runs |
| Price monotonicity and exponential checks | Key attempts timed out and rely on fuzz evidence |
| Buy supply properties | Symbolic execution blocked on EXTCODECOPY, with fuzz fallback |
| Sell inverse | No dedicated symbolic property in the committed DinoSAT suite |
| Full protocol custody and access control | Not covered by this numerical-core symbolic campaign |

The report's **37/37** is the Forge test count, including fuzz wrappers. It is not 37 completed symbolic proofs. This review did not rerun Halmos or Z3. The committed report describes earlier solver results, but temporary log paths are not durable proof artifacts. The new Halmos profile disables optimization, while the release profile enables it. A run using that profile does not directly prove the optimized release bytecode.

The structural monotonicity argument remains useful. The all-cell coefficient validator and independent high-precision oracles also add evidence. The validator explicitly samples 81 fractions per cell. It does not prove a uniform approximation-error bound between those samples.

## Fable campaign: useful evidence with limits

All six Fable integration tests and fourteen adversarial tests passed in the fresh suite. They use a real local V4 PoolManager. The full-exit campaign checks that participants can claim fees, unlock positions, redeem PSP, and drain referral escrow after sampled transaction sequences.

Two assertions deserve stronger coverage:

1. `test/FableBreakAttempts.t.sol:90` counts `pendingFeesMixETH()` in hook liabilities. That field excludes fees already distributed into position credits but not yet paid. Include the full outstanding fee liability, with rounding accounted for. The final exit checks partly cover this gap on sampled paths.
2. The capacity test at `test/FableBreakAttempts.t.sol:338` accepts any nonempty buy revert. Check the expected error selector so an unrelated regression cannot satisfy the test.

These are test-strength gaps. Neither establishes an insolvency or exit failure in the contracts.

## Known integration and trust constraints

**Generic router seats:** empty hookData credits the router address. The router must support recovery of ladder proceeds. The Fable report says the funds remain in hook escrow, but `claimPotFor(router)` is permissionless. Anyone can move the proceeds into the router, where they can remain inaccessible. Canonical routes supply the intended trader. Document this for other integrators.

**Ticket intent:** the maximum-ticket-price guard is optional. Use a guarded route when a transaction promises a ticket quantity. PSP output slippage alone does not protect ladder-seat count.

**Factory owner:** the owner can start a new genesis while the old round remains active. This changes the current round pointer but does not remove the old round's exits. Treat this as an explicit operational power.

**Referral self-rebate:** NFT custody or multiple wallets can recapture part of the referral fee. The system does not enforce one-person-one-wallet economics.

**Tiny launches:** valid dust launches can have little usable trade capacity. Numeric validity does not promise a useful game.

**Deployment identity:** compatibility checks do not establish deployed bytecode identity. GraveZap also requires separate deployment and configuration if the interface advertises a one-transaction exit.

## Change impact and history

There are zero changed production functions since `e9a70d44`, so these audit commits introduce no production call-graph changes. The newly failing harness affects the deterministic release gate. The proof-report error affects claims about numerical settlement assurance.

Earlier numerical changes reach the hook's buy/sell settlement and controller bootstrap through the shared helper. Their failures could affect every new v3 round. This review checked those paths and the retained regression suite. It did not compute a line-coverage percentage or claim full dependency coverage.

## Release record conflicts

`docs/audit/READINESS.md:3` still says the old monotonicity defects block release. The September 15 repair report still contains pending validation fields. Later GATE-LOG entries say those defects were fixed and the block was lifted.

Preserve the historical failures, but add an unambiguous current status and exact revision. Include the new harness failure. Reconcile the gate counts: the current suite contains 778 tests. The Fable entry lists 741 without DinoSAT, while the newly merged DinoSAT entry lists 758 without Fable.

## Fresh checks and limits

- Contract gate: 777 pass / 1 harness failure / 0 skipped.
- Fixed-seed reproduction: same rejection-limit failure.
- Fable tests: 20/20 pass within the contract run.
- Runtime/data size gate: 50 production artifacts pass. CurveHook runtime 20,379 bytes. SineV3Math runtime 14,182 bytes.
- Art fixtures and no-governance check: pass.
- Legacy independent sine oracle: pass.
- Remaining gate stages, run separately after Forge stopped: all pass. Generated v3 data, price bounds and 117 fixtures, 150 independent small-reserve fixtures, all-cell numerical validation, ABI, 211 frontend tests, 11 name tests, TypeScript, and the Vite production build passed. Vite retains its large-chunk advisory.
- `git diff --check`: pass before report creation.
- No new Slither, symbolic-solver, public-fork, deployment, or public source-verification result is claimed.

The full gate excludes `test/integration/*`. Local real-V4 tests are useful, but they do not substitute for a deployment rehearsal against the selected production chain and token.

## Recommended next work

1. Fix the symbolic/Forge harness separation and obtain one complete green deterministic gate.
2. Correct the plateau and proof-count claims. Commit reproducible solver commands, configuration, and durable verdict logs.
3. Strengthen the fee-liability and capacity-revert assertions.
4. Reconcile READINESS and the repair report with the current revision and test counts.
5. Rehearse the exact release deployment and check bytecode, wiring, and gas against its manifest.

The source is substantially stronger than the original single-sine implementation. The evidence supports continued testing toward release. It does not support an unqualified whole-protocol formal-verification claim.

Fresh logs are in `2026-09-21-current-state-evidence/`: the failed full gate, fixed-seed reproduction at each reviewed HEAD, and successful remaining gate stages. The contract run began at `32e7ff78`. The final fixed-seed reproduction ran at `38222f7f`. Their contract and test sources and default compiler settings match.

Prose lint: final report score 1.18 findings per 100 words. This is a writing check, not a security result.
