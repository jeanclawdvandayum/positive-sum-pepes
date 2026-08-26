# Independent security audit — factory, deployment & round lifecycle

You are an independent smart-contract security auditor. You have NO prior context on this codebase; form your own judgments from the code alone. This is a pre-deployment review.

## Repo
`/Users/clawdbot/clawd/positive-sum-pepes` — Foundry project, Solidity 0.8.26. Run all forge commands from that directory.

## Your scope (read these completely, first)
- `src/PSPFactory.sol` (primary — you own this file's review)
- `src/ControllerDeployer.sol`, `src/HookDeployer.sol`
- `src/PSPToken.sol` lifecycle wiring (mint/burn authority, controller handoff)
- Cross-contract round lifecycle: factory ↔ RoundController ↔ CurveHook interactions (read `src/RoundController.sol` and `src/CurveHook.sol` for the surfaces they expose to each other and to the factory, even though another auditor owns their internals)

## Protocol mechanism (neutral brief — verify against code, do not trust it)
- A factory deploys rounds: each round gets a fresh PSP token, a RoundController, and a CurveHook on a Uniswap V4 pool, deterministically.
- Rounds chain: when a round finalizes, leftover mixETH ("carry") and a "side pot" flow into spawning the next round. The factory mediates this handoff and tracks the current round.
- Deployers use CREATE2-style patterns and must satisfy Uniswap V4's hook-address flag rules (flags encoded in the hook contract address bits).
- Contract size limits (EIP-170, 24 KiB) matter for at least one deployer-embedded contract.

## Your mandate
Threat-model the deployment and lifecycle layer: address-mining griefing or collisions, init/initialize front-running or re-initialization, factory-only paths actually enforced, carry/pot handoff losing or duplicating value across rounds, round chaining corruption (two live rounds, zombie rounds), deployer bytecode assumptions (initcode hashes, embedded creation code, EIP-170 headroom), token authority escalation, unhandled low-level call failures, reentrancy across the finalize→spawn boundary.

For EVERY suspected issue:
1. Write a minimal Foundry PoC test under `test/wave2/auditorC/` (create the dir). Mock what you need; crib harness patterns from existing tests only for mock mechanics, not for expected behavior.
2. Run `forge test --match-path "test/wave2/auditorC/*" -vv` and keep only findings that actually reproduce.
3. Rate: severity (CRIT/HIGH/MED/LOW/INFO) x your confidence (0-100%).

## Hard rules
- NEVER modify anything outside `test/wave2/auditorC/`. src/, lib/, existing tests, foundry.toml are READ-ONLY. No git commits.
- The existing test suite being green proves nothing — do not anchor on it.
- A finding without a reproducing PoC is a hypothesis: label it as such with your confidence.
- Fork tests only if a unit PoC is truly impossible; note that the repo has a working mainnet-fork harness pattern you can crib env from.

## Deliverable (REQUIRED — your run is judged on this file existing and being complete)
Write `/Users/clawdbot/clawd/positive-sum-pepes/audits/wave2-20260818/auditorC.md` containing:
1. Executive summary (what you reviewed, overall assessment)
2. Findings: for each — ID, title, severity, confidence %, file:line, description, exploit scenario, PoC path + test result
3. Verified-safe: areas you attacked and why they held
4. Could-not-verify: anything you couldn't conclude on and why

Work thoroughly. End by re-reading your deliverable to confirm it is complete.
