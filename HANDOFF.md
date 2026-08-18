# PSP session state — 2026-08-17

## UPDATE 2026-08-19: ALL AUDIT FINDINGS RESOLVED — C-1 AND F-9 BOTH FIXED

**C-1 hook-squat FIXED (fork-verified):** entropy-keyed salts
(`keccak(prevrandao,timestamp,number,controller)` base, counter-offset) + occupied-candidate fall-through (4 candidates, atomic probe-then-create2) in HookDeployer/HookMiner. Pre-squat impossible; same-block front-run needs all 4 candidates re-squatted every retry block; residual = proposer-level grief (defense: private relay + retry). ControllerDeployer EIP-170 headroom (629B) untouched. Gas: honest finalize 8.1M / 1-squat 8.8M (pinned draws). Frontends must READ hook addresses from round state — no longer precomputable (update before republish).

**F-9 flat-window pot FIXED (zero-fee flat window):** CurveHook charges NO swap fee in Flat mode — dying-round trades accrue nothing to pot or stakers, and exits pay exactly pro-rata avg backing (floor-only, no toll). Kills F-9 at the source: no pot accrual → nothing stranded at finalize. No RoundController/ControllerDeployer changes; CurveHook shrank 279B. Flat round trips break exactly even. Commits: `92549eb9` (C-1), `819aa427` (F-9).

**Suite state: 542 green.** The only 4 failures are the adjudicated test-side knowns (B7b/d/e harness bugs + B4j fuzz epsilon), documented in the wave-2 adjudication skill ref.

resume-from-here doc. read this + `git log --oneline -5` to get back up to speed.

## what PSP is
bonding-curve memecoin lab: swaps route through a v4-style pool with CurveHook
(solidity, foundry, mock pool manager for anvil). swap fees split 4.75% -> stakers
/ 0.25% -> side pot (the pot leg accrues in PSP). quote currency is mixETH.
stakers lock PSP for 90d to earn fee share + vote rights.

## the big arc: two-phase carpet bomb (DONE, tested, live-verified)
old behavior was wrong: carpetBomb() flattened then instantly destroyed+drained+spawned
in the same tx, so the exit window closed instantly.

new semantics per scoopy's intent:
- `carpetBomb()`:
  1. pot's PSP auto-sells FIRST via `hook.redeemPotBacking()` at exactly
     `(reserve * psp) / supply` = the flat rate (average backing). pot PSP burned,
     mixETH ring-fenced to factory via `creditSidePot()` for round 2's bonus depth.
     emits `CarpetBombExecuted(potRedemption)`.
  2. mode -> Flat, stamps `flatTime = block.timestamp`. no destroy, no drain, no spawn.
- while `flatTime != 0`: `unlock()` bypasses the 90d expiry (locks force-open),
  `lock()`/relock revert `RoundFlattened`, bomb voting closed (Flat and Destroyed both gate).
- stakers exit by selling through the normal zap: `_handleFlatSell` pays average
  backing minus 5% exit toll. ratio-preserving math: reserve/supply constant no
  matter how many exit, no last-runner advantage. pot redemption uses the same
  formula so it doesn't move the rate either.
- `finalizeCarpet()` — permissionless, callable after `FLAT_EXIT_WINDOW = 3 days`:
  destroys, drains remaining mixETH to factory, spawns round 2. idempotent
  (hook refuses Destroyed -> Destroyed). EIP-170 clean (dropped a redundant
  `roundFinalized` bool to reclaim 17 bytes).

## commits
- `08b1985` flat exit rewiring + finalizeCarpet + test updates
- `859098a5` test proving side-pot auto-sell executes at flat rate

## tests: 350/350 (30 suites)
new `test/unit/FlatExit.t.sol`:
- `test_FlatExit_StakerUnlocksEarlyAndSellsAtAverageBacking` — alice unlocks with
  90d still on the clock; sells at avg backing minus toll (exact-value assert);
  pot redemption == (reserveBefore * potPSPBefore) / supplyBefore; factory balance
  credited exactly; flat rate unchanged by the redemption (assertApproxEqAbs 5 wei).
- `test_FlatExit_UnclaimedBackingInheritsToRound2` — nobody exits during window,
  finalizeCarpet carries full reserve to round 2.
- ~10 older tests updated to bomb -> `skip(3 days + 1)` -> `finalizeCarpet()`.

## frontend (build green, `npm run build` ~6s)
- landing copy fixed: no more "stakers feed the next round". now: bomb opens every
  lock, stake exits at avg backing, only the unclaimed seeds the rebirth.
- `flatTime` wired end to end: `lib/abi.ts` (+ finalizeCarpet, flatTime), `lib/useRound.ts`,
  `components/CarpetBombCard.tsx` (flat state: avg backing price, exit-window countdown,
  finalize button), `components/StakeCard.tsx` (unlock force-enabled when flat,
  "lock force-opened" state).
- `.env.local` points at the live anvil ensemble (below).

## live anvil ensemble (http://127.0.0.1:8545, verified full cycle)
- factory: 0x51A1ceB83B83F1985a81C295d1fF28Afef186E02
- round 1 controller: 0xf3a0988dcdfddf56861be7413ce85db4402bdc82
- hook: 0x26f15c14a54f3cf39f3873ea73ea95e6a5912a88
- psp token: 0xd6ccb4cfb12893d8090acf4205fedda604b50691
- mixETH: 0x2E2Ed0Cfd3AD2f1d34481277b3204d807Ca2F8c2
- zapIn: 0x0355B7B8cb128fA5692729Ab3AAa199C1753f726
- zapOut: 0x202CCe504e04bEd6fC0521238dDf04Bc9E8E15aB
- driven state: round 2 is live now. history: 60 mix predeposit -> launch ->
  1.616M PSP staked (key0) -> 20 mix zap buy -> pot 342.618 PSP -> bomb:
  CarpetBombExecuted 0.015483 mixETH == 342.618 * (79.05/1.749M) EXACT ->
  mode Flat, flatTime set, reserve 79.03451697844478 == 79.05 - 0.015483 ->
  finalizeCarpet -> round 2 born.
- loose end: the live early-unlock send no-op'd silently (totalLocked unchanged).
  suite proves the behavior; re-verify on round 2 if demoing live.

## RESOLVED 2026-08-18: UI live + curve graph fixed

- **curve-graph root cause:** `.env.local` pointed at a pre-C-1 deploy's factory
  (stale addresses after HookDeployer bytecode change). every read reverted;
  `useRound`'s silent catch → EMPTY → "loading curve…" forever. fix = fresh
  deploy + env rewrite. NOTE: deploy console-logs print SIMULATION addresses —
  entropy salts (C-1) make broadcast addresses differ. trust `factory.rounds(id)`
  / broadcast receipts only.
- **live demo:** https://rosy-palm-vzxv.here.now (claimed, permanent slug).
  https pages can't fetch http://127.0.0.1 → anvil is exposed via cloudflared
  quick tunnel: VITE_RPC_URL=https://tobacco-pipe-quarters-equally.trycloudflare.com.
  chain: anvil localnet, factory 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9,
  hook 0x320ad0e24abfa0eb7008540339f26f5ba3b06a88, round 1 Active,
  supply ~3.15M PSP, reserve ~563.8 mixETH.
- **restart sequence if the mac bounces:**
  1. anvil (bg) 2. `PSP_ANVIL=1 forge script script/DeployPSP.s.sol --rpc-url
  http://localhost:8545 --broadcast --slow --sender 0xf39F…92266 --unlocked`
  3. DriveAnvil same flags + DRIVE_FACTORY/DRIVE_ZAPIN env (real addrs from
  broadcast dir!) 4. cloudflared tunnel --url http://localhost:8545 (NEW url →
  update .env.local VITE_RPC_URL) 5. npm run build 6. republish
  `--slug rosy-palm-vzxv` 7. verify chart path via DOM probe.
- F-9 copy fixes: Landing ("exits toll-free at exact average backing"),
  SwapCard flat-mode banner (was "trading paused" — WRONG post-fix, now shows
  toll-free exit message).

## gotchas (do not relearn these)
- cast with tuple args: tuple + each scalar as SEPARATE shell words:
  `cast send $Z "buyWithMix((address,address,uint24,int24,address),uint256,...)" "($MIX,$TOK,0x800000,60,$HOOK)" 20000000000000000000 0 0`
  single-string form dies with "encode length mismatch".
- PoolKey.fee is uint24 with dynamic-fee flag 0x800000. passing uint256 width in
  the signature = wrong selector = bare revert, zero subcalls (looks like a guard
  hit but isn't). verify selectors against deployed bytecode with `cast code | grep`.
- foundry: use `skip()`, never `vm.warp(block.timestamp + x)` — vm.warp reads a
  stale contract timestamp and time-travels backwards.
- anvil impersonation doesn't survive some operations: re-run
  `anvil_impersonateAccount $F` + `anvil_setBalance` before factory-only calls
  (launchPooledBuy) after each forge-script redeploy.
- `deployRound` bare-reverts while a round is live — don't stack rounds manually,
  redeploy the whole ensemble with `PSP_ANVIL=1 forge script script/DeployPSP.s.sol
  --rpc-url http://127.0.0.1:8545 --broadcast --sender 0xf39F...2266 --unlocked`.
- `potState()` = (potPSP, potMixFunded); potMix is PRE-LAUNCH funding, not bomb
  redemption. bomb redemption goes to `factory.creditSidePot()` — assert via
  CarpetBombExecuted event data or factory mixETH balance delta.
- key0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, pk
  0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 (anvil default).
