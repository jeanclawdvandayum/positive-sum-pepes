# Formal verification and security checks

This package separates completed symbolic proofs, arithmetic lemmas, concrete checks, and fuzz tests. A timeout, blocked path, empty input domain, or truncated loop does not count as a proof.

No production contract changed in this work. The production source matches `38222f7f`. Existing deployed contracts remain unchanged.

## Reproduce the checks

Use Python 3.12 and Foundry 1.5.1. Install the pinned tools in an isolated environment:

```bash
python3.12 -m venv .venv-formal
.venv-formal/bin/python -m pip install -r scripts/formal/requirements.txt
.venv-formal/bin/python scripts/formal/test_runner.py
.venv-formal/bin/python scripts/formal/prove_arithmetic.py --output /tmp/psp-arithmetic-new
.venv-formal/bin/python scripts/formal/run.py --output /tmp/psp-evm-new
bash scripts/check-audit.sh
```

Use a new empty output directory for each EVM run. The runner refuses to overwrite earlier evidence. It preserves commands, compiler settings, source and artifact hashes, tool versions, raw output, and machine-readable verdicts.

The Halmos profile uses the release settings: Solidity 0.8.26, optimizer enabled with 200 runs, via-IR, Cancun, and no bytecode metadata hash. AST and storage-layout output support the proof tools. Separate cache and output directories prevent interference with the normal build.

The harness compiles inherited production functions with these settings. This is not proof that a public deployment contains those exact artifacts. Release procedures must still check deployed bytecode and wiring.

The audit workflow runs the arithmetic proofs and required EVM checks in a separate job. It uploads evidence even when a check fails. The normal deterministic gate also tests the result parser.

Compiler evidence uses an allowlist of build settings. It excludes explorer keys, RPC endpoints, and other environment credentials.

## Direct contract properties

`HookRulesSymbolic.t.sol` calls the actual inherited hook methods. Test-only setters establish the relevant storage state. Halmos substitutes synthetic CREATE2 addresses, which cannot satisfy V4 hook flags. The symbolic setup therefore installs a generated runtime fixture. A separate Forge test checks that the fixture matches a real constructor deployment byte for byte. The symbolic proofs exclude constructor and address-mining correctness.

| Property | Domain and limit | EVM suite |
| --- | --- | --- |
| Active ticket interval | Every uint256 pot, arbitrary genesis-pot field, initialized sine state | Extended: intractable — see below |
| Positive ticket minimum | Every uint256 pot, minimum exactly equals ticket cost | Required |
| Whole-pot pricing | Every uint256 pot, independent of either genesis-pot value | Required |
| Adjacent ticket order | Every pot below uint256 maximum, next cost increases by at most one wei | Extended: intractable — see below |
| Prelaunch minimum | Empty pot before pool initialization, both configuration flags | Required |
| Legacy minimum | Every uint256 pot, sine disabled | Required |
| Unauthorized mode change | Every caller except the fixed controller, all four initial and destination modes | Required |
| Invalid launch price | Every price outside the supported interval, canonical boot and wavelength | Required |
| Excess reserve | Every reserve above the canonical capacity, including uint256 maximum | Required |
| Exponential scale guard | Every scale above the supported maximum at zero exponent | Required |

The ticket specification uses interval inequalities instead of copying the ceiling-division implementation. It handles uint256 maximum without overflowing the specification itself. Domain checks require the exact `SineV3Domain` error, not any arbitrary revert.

Controller, manager, and registry addresses in the hook harness are fixed noncalling stubs. These proofs cover getters and the first authorization guard. They do not prove token transfers, settlement reachability, or authorized mode transitions.

Concrete seam and domain examples remain separately labeled. They do not become quantified proofs merely because Halmos runs them.

## Arithmetic lemmas

`prove_arithmetic.py` uses Z3 integer arithmetic. Each theorem must have satisfiable assumptions. Its negated conclusion must be UNSAT. The output includes a witness for the assumptions and the exact SMT query.

Twelve lemmas cover:

- Joint monotonicity of rounded interpolation in its endpoints and fraction.
- Interpolation range, exact endpoints, preservation of ordered rows, and uint256 output range.
- Monotone scaling from the cumulative primitive into supply.
- The inverse's exact ceiling transformation.
- Positive genesis allocation and the budget for split allocations.
- Strict contraction of a bisection bracket.
- Ticket interval, representable range, and adjacent order across the uint256 pot domain.

The central interpolation operation is:

```text
L(a,b,t,D) = a + floor((b-a)*t/D)
```

For ordered endpoints and `0 <= t <= D`, the output stays within the endpoints. If both endpoints and the fraction increase, the output cannot decrease. Applying the ordered-row lemma to each row preserves the premise for the next row. Induction therefore supplies the mathematical argument for arbitrary-degree ordered interpolation.

The source uses this operation in `SineV3Price._deCasteljau` and `SineV3Primitive._atReserveWithSlope`. The latter uses full-precision multiplication and division. The all-cell validator checks the actual deterministic coefficient sets. Shared knots supply the join between cells.

**Refinement limit:** these are machine-checked arithmetic lemmas with a documented connection to source. They do not mechanically prove the complete EVM loops, library implementation, compiler, or coefficient generator. The induction and mapping from source remain review obligations. Pinned hashes in `model-bindings.json` make relevant source changes fail the arithmetic gate until someone reviews that mapping. The hashes do not themselves prove it.

The inverse lemma proves:

```text
floor(lambda*n/p) >= q  iff  n >= ceil(q*p/lambda)
```

This establishes the rounding transformation used by the inverse. It does not by itself prove every branch of the EVM search. The direct production inverse tests separately check endpoint minimality and conservative payouts in a stated bounded domain.

Two deliberately wrong arithmetic models must produce counterexamples: subtracting the interpolation term, and flooring the inverse target. A failure to detect either model makes the arithmetic run fail.

## Harness repairs and stronger execution tests

Parameterized symbolic entry points use `check_*`. Forge calls bounded `test_*` wrappers with the same assertions. This preserves symbolic assumptions without starving Forge's input generator. No rejection limit was raised and no property was removed to turn the gate green.

The full gate also exposed the same input-rejection defect in the older `CurveMathTest` suite. Its generators now preserve the original ranges directly. Unexpected zero or dust output fails an assertion instead of being discarded. A fixed-seed campaign passed all 29 tests with 2,000 runs per fuzz property.

Coverage now includes all four phase quarters, explicit edges, every sampled primitive cell, and a reachable negative cell. Every stored knot must be nondecreasing. Selected nonconstant cells must increase strictly. The terminal cell is explicitly a plateau because its stored endpoints are equal.

The real-V4 lifecycle campaign now counts all unpaid staking fees as liabilities: `totalFeesReceived - totalFeesPaid`. This includes earned credits and retained rounding dust. Pending distributions and whole claimable fees must fit within that budget. The campaign also checks position ownership, principal custody, global weight, detonation, and individual exits. Its capacity test requires the exact wrapped `ZeroOutput` error.

## Result-gate safeguards

The EVM runner requires the exact requested function to appear once in the result. A successful proof needs successful execution paths, no blocked paths, and no truncated loops. Missing output, unknown results, tool errors, panics, and process failure cannot pass.

One sentinel contains a deliberately false assertion. Another has contradictory assumptions. The runner must report the first as a counterexample and the second as an empty domain. These controls test failure detection and vacuity handling. They do not prove that every other property has useful assumptions.

Source changes during a run invalidate its summary. Each run has per-property wall and solver deadlines. A timeout remains unresolved. The runner terminates the timed-out process group instead of leaving solver processes behind.

## Unresolved scope

The full nonconstant curve, exponential stack, and settlement inverse do not yet have completed end-to-end symbolic proofs. The old campaign timed out or encountered unsupported symbolic code access on these paths.

**September 22 escalation (see [the escalation report](2026-09-22-formal-escalation.md)):** the two direct EVM ticket properties were re-attempted at 20× wall budget, 10–15× solver budget, with z3 (serial and 8-thread), bitwuzla, cvc5 and yices, with a re-engineered addition-form specification, and in an isolated minimal-implementation diagnostic. They remain open at the bitvector tier: the compiled queries require relational reasoning over 256-bit division and remainder that no tested engine decides. The old specification's subtraction-under-comparison additionally compiled (via-IR) into a division with a symbolic divisor — the single monster query per property. The composition closure for both properties now rests on the full-domain integer-tier lemmas, the no-overflow bridge, an exhaustive concrete check of the top 10,000 pots, and full-domain fuzz. No engine produced a counterexample at any budget.

To attempt these properties without relabeling them:

```bash
.venv-formal/bin/python scripts/formal/run.py --extended --output /tmp/psp-extended-new
```

A focused attempt is also available through `--only PROPERTY_NAME`. Failed extended checks make that run exit nonzero. They never become successful proofs through a fuzz fallback.

The density validator samples 81 fractions in each cell. It does not establish a uniform approximation-error bound between samples. The solver lemmas do not remove this limitation.

The direct EVM ticket-interval and adjacent-order attempts each exceeded a 90-second wall deadline. They remain in the extended suite and the full-domain Forge wrappers. Their arithmetic models pass, but no EVM proof is claimed for these two properties.

A fresh first-quarter phase-monotonicity attempt also exceeded its 60-second deadline with the release compiler settings. Its unchanged-source manifest and failed verdict remain in `extended-phase.tar.gz`. No passing verdict is claimed for this attempt.

These checks also do not formally prove the complete staking state machine, referral graph, arbitrary transaction sequences, external mixETH behavior, production deployment, or economic resistance to coordinated players.

## Current results

The required run completed with **8 quantified EVM properties proved**, **5 concrete boundary checks passed**, and **2 negative controls detected**. All **12 integer lemmas** returned UNSAT for their negated conclusions, with satisfiable assumptions. Both arithmetic mutation controls produced counterexamples. These counts refer to distinct assurance categories and must not be added into a single formal-proof count.

The [evidence directory](2026-09-21-formal-evidence/) contains readable JSON summaries and compressed raw logs, commands, compiler settings, hashes, and SMT queries for the arithmetic lemmas. `evm-core.tar.gz` holds the final passing run. `initial-evm-attempt.tar.gz` preserves the earlier incomplete attempt, including the two ticket timeouts and the subsequently corrected identity-test filter. It is not release proof evidence.

Final deterministic command outcomes are recorded in the September 21 GATE-LOG entry. The historical [DinoSAT report](../../audits/DINOSAT-REPORT.md) remains available with corrected proof scope.

## Runtime fixture maintenance

The symbolic runner requires exactly one passing real-constructor identity test before it starts any proofs. A zero-test Forge result fails this prerequisite.

If an intentional source or compiler change invalidates the fixture, review the change before regenerating it:

```bash
forge test --match-contract HookRulesSymbolicTest --match-test test_export_runtime_fixture
python3 scripts/formal/generate_hook_fixture.py
forge test --match-contract HookRulesSymbolicTest --match-test test_fixture_matches_constructor
```

The generator checks the compiler template and all five immutable values. Changes to initcode can also require a new test-only CREATE2 salt. Never remove the address-flag or byte-identity assertions to bypass a stale fixture.

## Tool references

The harness separates symbolic `check_*` properties from Forge tests as supported by [Halmos](https://github.com/a16z/halmos). The runner uses the pinned tool's result schema and rejects incomplete results. The selected proof tools are Halmos 0.3.3 and Z3 4.12.6.

Prose lint: report score 1.18 findings per 100 words before the final result note. This checks writing, not security.
