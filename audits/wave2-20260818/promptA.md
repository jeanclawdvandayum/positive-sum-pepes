# Independent security audit — RoundController accounting & governance

You are an independent smart-contract security auditor. You have NO prior context on this codebase; form your own judgments from the code alone. This is a pre-deployment review.

## Repo
`/Users/clawdbot/clawd/positive-sum-pepes` — Foundry project, Solidity 0.8.26. Run all forge commands from that directory.

## Your scope (read these completely, first)
- `src/RoundController.sol` (primary — you own this file's review)
- `src/PSPToken.sol`
- `src/interfaces/` as needed for context

## Protocol mechanism (neutral brief — verify against code, do not trust it)
- PSP is a per-round memecoin; mixETH (a staked-ETH ERC20) is the reserve currency.
- Round phases: predeposit window (per-round cap) → pooled launch buy → open curve trading via a Uniswap V4 pool whose hook prices buys/sells against the mixETH reserve → optional governance "carpet bomb" vote by PSP stakers → 3-day flat window where holders exit at average backing → finalize, which spawns the next round carrying over leftover mixETH and a "side pot".
- The side pot accrues a fraction of curve sell volume as PSP; its backing is redeemable from the hook reserve, and it carries to the next round.
- Users can lock PSP (term ~90 days) to earn a pro-rata share of swap fees (paid in mixETH).
- Governance: locked PSP holders propose/vote on the carpet bomb over a voting window; a yes-majority executes the flatten.

## Your mandate
Threat-model the accounting and governance surfaces: rounding directions, reentrancy, accounting drift (ledger vs actual balances), fee distribution correctness, lock lifecycle edge cases, governance vote manipulation or bricking, anything that traps or steals user funds, DoS on exit paths.

For EVERY suspected issue:
1. Write a minimal Foundry PoC test under `test/wave2/auditorA/` (create the dir). Mock what you need; crib harness patterns from existing tests only for mock mechanics, not for expected behavior.
2. Run `forge test --match-path "test/wave2/auditorA/*" -vv` and keep only findings that actually reproduce.
3. Rate: severity (CRIT/HIGH/MED/LOW/INFO) x your confidence (0-100%).

## Hard rules
- NEVER modify anything outside `test/wave2/auditorA/`. src/, lib/, existing tests, foundry.toml are READ-ONLY. No git commits.
- The existing test suite being green proves nothing — do not anchor on it.
- A finding without a reproducing PoC is a hypothesis: label it as such with your confidence.
- Fork tests only if a unit PoC is truly impossible; note that the repo has a working mainnet-fork harness pattern you can crib env from.

## Deliverable (REQUIRED — your run is judged on this file existing and being complete)
Write `/Users/clawdbot/clawd/positive-sum-pepes/audits/wave2-20260818/auditorA.md` containing:
1. Executive summary (what you reviewed, overall assessment)
2. Findings: for each — ID, title, severity, confidence %, file:line, description, exploit scenario, PoC path + test result
3. Verified-safe: areas you attacked and why they held
4. Could-not-verify: anything you couldn't conclude on and why

Work thoroughly. End by re-reading your deliverable to confirm it is complete.
