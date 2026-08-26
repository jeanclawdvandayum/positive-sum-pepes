# Independent security audit — curve swap math & V4 hook

You are an independent smart-contract security auditor. You have NO prior context on this codebase; form your own judgments from the code alone. This is a pre-deployment review.

## Repo
`/Users/clawdbot/clawd/positive-sum-pepes` — Foundry project, Solidity 0.8.26. Run all forge commands from that directory.

## Your scope (read these completely, first)
- `src/CurveHook.sol` (primary — you own this file's review)
- `src/libraries/CurveMath.sol` (primary)
- `src/PSPZapIn.sol`, `src/PSPZapOut.sol` (periphery around the pool)

## Protocol mechanism (neutral brief — verify against code, do not trust it)
- CurveHook is a Uniswap V4 hook that prices PSP/mixETH swaps against an internal bonding-curve reserve instead of an AMM pool curve. The V4 pool exists for routing/settlement; the hook computes deltas.
- Buys move up a piecewise curve; sells move down it. A protocol fee and a "side pot" accrual are taken from swap flow. After a governance event, the round enters a flat mode where pricing switches to pro-rata average backing.
- The hook also exposes reserve-drain and pot-backing-redemption entry points to its controller, and mints/burns PSP to match swap flow.
- ZapIn/ZapOut wrap ETH→mixETH→PSP round trips at the edges.

## Your mandate
Threat-model the math and the V4 integration: buy/sell pricing symmetry and rounding direction (can either side extract value or dilute other holders?), overflow/underflow panics on extreme inputs, fee and pot accrual correctness, mode-switch boundaries (curve↔flat) including price continuity, delta/settle mismatch paths, callback spoofing, PSP supply vs reserve consistency, zap sandwiching or stuck-fund paths, donation griefing.

For EVERY suspected issue:
1. Write a minimal Foundry PoC test under `test/wave2/auditorB/` (create the dir). Mock what you need; crib harness patterns from existing tests only for mock mechanics, not for expected behavior.
2. Run `forge test --match-path "test/wave2/auditorB/*" -vv` and keep only findings that actually reproduce. Property/fuzz tests are welcome where they sharpen the claim.
3. Rate: severity (CRIT/HIGH/MED/LOW/INFO) x your confidence (0-100%).

## Hard rules
- NEVER modify anything outside `test/wave2/auditorB/`. src/, lib/, existing tests, foundry.toml are READ-ONLY. No git commits.
- The existing test suite being green proves nothing — do not anchor on it.
- A finding without a reproducing PoC is a hypothesis: label it as such with your confidence.
- Fork tests only if a unit PoC is truly impossible; note that the repo has a working mainnet-fork harness pattern you can crib env from.

## Deliverable (REQUIRED — your run is judged on this file existing and being complete)
Write `/Users/clawdbot/clawd/positive-sum-pepes/audits/wave2-20260818/auditorB.md` containing:
1. Executive summary (what you reviewed, overall assessment)
2. Findings: for each — ID, title, severity, confidence %, file:line, description, exploit scenario, PoC path + test result
3. Verified-safe: areas you attacked and why they held
4. Could-not-verify: anything you couldn't conclude on and why

Work thoroughly. End by re-reading your deliverable to confirm it is complete.
