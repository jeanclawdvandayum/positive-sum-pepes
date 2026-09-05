# Current amendment — 2026-09-05

Follow-up: earned fees survive vesting and payout failures. Use the explicit
`isWithdrawing` flag for epoch-zero correctness; fees integrate earning-time
weights via sparse epoch checkpoints. Custom sine inputs have a supported
bounded domain. See `docs/audit/FEE-ACCOUNTING.md` and `READINESS.md`. The current
keeper is disabled; the testnet embedded HTML is a read-only deployment record.


Read `docs/audit/READINESS.md` before editing. It supersedes the historical
rules below: 0.005 mixETH minimum gross buy/public predeposit and per ticket;
4m20s per purchase unit; actual-seconds TimeAdded payload; independent
Decimal/Simpson oracle; owner/operator reinvestment; resumable three-step birth.
`bash scripts/check-audit.sh` is the deterministic gate. Counts come from the
latest GATE-LOG entry, not the historical baseline below. Existing deployments
remain unchanged until redeployed. Timing packing is four 64-bit fields.

# AGENTS.md — Positive Sum Pepes (PSP), `sigma-testnet`

## What this is

A bonding-curve memecoin game on Uniswap V4 hooks, rebuilt around a **detonation
clock** (the "SigmaBF" redesign, 2026-08-31 — `CLOCK-REDESIGN.md` is the binding
spec). Each round: PSP mints/burns along a **tilted-sine bonding curve** inside
`CurveHook` (quote currency: mixETH). A 72-hour countdown arms at launch; buys
add +5 min per whole PSP bought. When the clock strikes zero, trading halts and
anyone can `detonate()`: the fee pot pays out to a last-10-buyers ladder, the
curve flattens, every staked lock opens instantly, and the next round's
predeposit window is born in the same tx. After detonation, PSP redeems against
the dead curve's reserves **forever** (payout frozen at death). There is **no
governance** — the clock is the only death authority, enforced by a grep gate.

Repo state: `forge test` = **362 tests / 46 suites, all green** (verified at tip
`2985a957`). README's "612 tests" is stale — the removed governance suites are
parked, not deleted (see Testing).

Four projects share this repo — don't mix their toolchains:

| Path | What | Toolchain |
|---|---|---|
| `src/`, `test/`, `script/` | Solidity contracts, tests, deploy scripts | Foundry (solc 0.8.26 pinned, cancun, `via_ir = true`) |
| root `package.json` + `scripts/` | Yield-reinvest keeper bot (`Keeper.ts`) | pnpm + tsx + viem |
| `frontend/` | React 19 + wagmi/viem + Tailwind 4 dapp | npm + Vite |
| `studio/` | Zero-dependency vanilla-JS trait editor | python inline-compiler, no build system |

## Commands

### Contracts (repo root)

```bash
forge build
forge test                          # full suite (make test also sources .env)
forge test --match-contract <Name> -vvv
make slither                        # static analysis (filters test/,script/,lib/)
bash scripts/check-no-governance.sh # MUST pass: proposeCarpetBomb|voteCarpetBomb|castWeightOn|QUORUM_BIPS must not exist in live files (fails closed)
bash scripts/anvil-e2e.sh           # full-lifecycle e2e on local anvil: deploy → detonate → reserve → birth → round-2 alive, every receipt status-checked
node studio/test_compiler.mjs       # art compiler referee (see Art pipeline)
```

- Suite state is gate-logged in `GATE-LOG.md` (append an entry when you move
  the gates). `vesting-migration-pending/` holds the ~250 retired suites
  (governance/zone-curve/fork/exploit tests) awaiting migration to the
  clock/sine world — they are NOT run by `forge test`.
- Fork tests that survive live in `test/integration/` (mainnet RPC via
  `MAINNET_RPC_URL` / `make test-fork`).
- `[profile.base_sepolia]` + `base_sepolia` etherscan entry exist in
  foundry.toml (Etherscan V2: one key verifies on 84532/Basescan). Invariant
  tuning nests under `[profile.default.invariant]` — a top-level
  `[profile.invariant]` table is a phantom profile whose keys silently no-op.

### Deploy

```bash
cp example.env .env   # Base-Sepolia-first: PRIVATE_KEY, BASE_SEPOLIA_RPC_URL, ETHERSCAN_API_KEY
source .env
# free fork dry-run first (PSP_FORK=1 vm.deals fake ETH — dry-run ONLY, never real deploys):
PSP_FORK=1 PSP_TESTNET=1 PSP_PM=0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408 \
  forge script script/DeployPSP.s.sol --fork-url $BASE_SEPOLIA_RPC_URL --private-key 0x…01
# real deploy (always --slow; hook mining sends many txs, parallel sends have failed):
forge script script/DeployPSP.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --slow
# SECOND PASS, required: the reinvestor needs the REAL staged addresses:
forge script script/DeployReinvestor.s.sol …
```

- Modes: `PSP_TESTNET=1` (SepoliaMixETH + free MixETHFaucet, fast env-tunable
  timings: `PSP_PREDEPOSIT_SEC`/`PSP_VEST_SEC`, wallet cap
  `PSP_WALLET_CAP_MIX`), `PSP_ANVIL=1` (MockMixETH+MockPoolManager local e2e,
  then `DRIVE_FACTORY`/`DRIVE_ZAPIN` for `DriveAnvil.s.sol`), Base mainnet
  default (canonical v4 PM `0x000000000004444c5dc75cB358380D2e3dE08A90` — the
  old `0x498581fF…` constant had no code).
- **DeployPSP's console no longer prints round addresses** (staged spawn +
  entropy salts): read them from the factory post-broadcast
  (`currentRoundId()`, `rounds(id)`), never from logs or sim output.
- Testnet chain decision: **Base Sepolia (84532)**, PM
  `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`. ETH Sepolia enforces a 2^24
  per-tx gas cap (~16.78M); measured staged birth of a 34-zone curve is 16.57M
  — it fits, but zone curves are retired anyway (sine-only, see below).

### Keeper / frontend / studio

```bash
pnpm run keeper            # or keeper:dry (root; flags: --rpc --key --controller …)
cd frontend && npm install && npm run build   # tsc -b && vite build; dev: npm run dev
python3 studio/tools/build_inline.py          # rebuild studio/dist after editing studio/src/
python3 -m http.server 8777 studio/src       # serve modular studio while editing
```

Frontend env: `VITE_CHAIN_ID` (84532 = Base Sepolia), `VITE_RPC_URL`,
`VITE_FACTORY`, `VITE_ZAP_IN`, `VITE_ZAP_OUT`, `VITE_MIX`, `VITE_FAUCET` —
the faucet card stays **hidden** without BOTH `VITE_MIX` + `VITE_FAUCET`;
`VITE_REINVESTOR` gates the reinvest buttons. Testnet UI is **mixETH-only**
(no ETH zap legs); Base Sepolia ETH is still needed for gas (Coinbase faucet
link is automatic on 84532).

## Architecture

Deployed per round by `PSPFactory` (fresh contracts each round):

- **`PSPFactory`** — round registry, sine curve params, **staged spawn**:
  `reserveSpawn(fromRoundId)` (permissionless, commits entropy-salted CREATE2
  salts, bounded mine, cheap-fail) then `birthRound()` (all CREATE2s, zero gas
  variance). `spawnNextRound` = composed one-tx shim; `deployRound` = genesis
  shim. `RoundDeployed` fires at birth; `SpawnReserved` at reserve.
- **`RoundController`** — predeposit (wallet-capped) → `launchPooledBuy` →
  Active; fee forwarding; **`detonate()`**: gated `block.timestamp >=
  hook.detonationAt()`, one tx = pot frozen → `setMode(Flat)` → `flatTime` set
  (opens every lock) → factory `markDestroyed` + `spawnNextRound` (precomputed
  selectors, EIP-170). Idempotent via mode check; spawn bounce reverts
  atomically (retry next block). Governance surface is gone.
- **`CurveHook`** — the V4 hook and the game:
  - **Clock**: `detonationAt` = now + 72h at Active; each curve buy adds
    `5 min × floor(pspOut/1e18)`, capped at now+72h, emits `TimeAdded` (the
    tape). At zero, buys AND sells revert `TradingHalted`; predeposit/genesis
    buys never touch the clock; a post-zero tx can't resurrect it (halt check
    runs before time-add).
  - **Ladder**: every curve buy = one ticket seat (rolling last-10 circular
    buffer + `ticketCount`). Distribution 25/18/14/10/8/7/6/5/4/3% newest→
    oldest; <10 seats renormalize to 100%. Pull-based `claimPot()`, claims
    open forever after detonation (`NotDetonated` until then). Views:
    `board(i)`, `potBalance()`, `claimablePot(addr)`.
  - **Fee routing** (sine rounds): sliding fee — 10% pre-wave (R ≤ boot) →
    linear decay → 2.5% at/above wave top; zone rounds keep flat 5%. Split OF
    THE FEE: 60% stakers / 35% pot / 5% referral leg if attributed; if
    unattributed, that leg becomes 4% pot + 1% `deployerCredit` (pull-based
    `claimDeployerCredit()`, `deployerCutTo` immutable ctor arg, zero-address
    reverts). Rounding dust → pot escrow. Invariant asserted in tests:
    `stakerLeg + potΔ + deployerCreditΔ + referralPaid == fee`.
  - **Modes**: `Predeposit / Active / Flat / Destroyed`. Flat buys revert
    `BuyingDisabled`; flat sells are fee-free pro-rata at average backing.
  - **Redemption**: after detonation `redeemBacking(psp)` pays floor pro-rata
    at the payout-per-PSP **frozen at death**, burns PSP, forever, no deadline.
    The dead hook custodies unredeemed backing indefinitely — death no longer
    endows the next round (carry = only mixETH actually on the factory).
- **`PSPStaker`** — ERC-721 pepe positions with **chosen DNA ids**
  (`lockWithPepe`/`stakeFor(pepeId)`), transferable, husk survives withdraw.
  InfiniFi-style epoch-point weight engine (bias/slope GlobalPoints). Locks are
  indefinite; exit = `requestWithdraw` → 6-epoch linear vest decay →
  `withdraw`; `cancelWithdraw` restores instantly. Fees: live
  `creditPerWeight` accumulator — claims settle O(1) in real time; fresh
  stakes earn from the next epoch boundary (anti-sandwich kept). At Flat,
  `withdraw` bypasses the vest entirely. Epoch-0 anchor bug (sentinel
  collision) is fixed with an explicit `anchored` flag — don't reintroduce.
- **`PSPReinvestor`** — stateless, permissionless compounder: claim a pepe's
  fees → `buyWithMix` → restake into the same pepe. Deployed as a second-pass
  script (`DeployReinvestor.s.sol`) reading the REAL chain.
- **EIP-170 shims**: `HookDeployer` / `ControllerDeployer` / `StakerDeployer`
  hold creation code so the factory stays under 24,576 bytes. All hook
  addresses are CREATE2 with **entropy-keyed salts** — never precompute,
  always read from round state / broadcast receipts.
- **`CurveMath`** + `src/curves/` (zone integrals, Newton solver, conservative
  shave loop) — still used by the stashed zone curves; **`SineMath`** is the
  live path: price = f(reserve raised): exp predeposit ramp → 3-wave tilted
  sine anchored to the actual boot raise (materialized at launch) → linear
  tail. Supply = pure function of the reserve endpoint (13 checkpoints + fixed
  GL8 quadrature) so buy/sell integrals telescope exactly under order
  chopping. `scripts/sine_oracle.py` is the python oracle twin for
  cross-checking. Zone curves (ladder/Curve1-3Zones/LinearZonesLean) are
  STASHED — `src/curves/CURVES-STASH.md` — not deployed; `PSP_CURVE` is
  retired (only a stale comment label remains). Sine shape tunes via env:
  `PSP_SINE_P0` / `PSP_SINE_PREK` / `PSP_SINE_MAGM` / `PSP_SINE_LNTOP` /
  `PSP_SINE_AMPBPS` (defaults = dial-lab verified 45° tilt).
- **Testnet**: `src/testnet/SepoliaMixETH` (dumb 1:1, public free mint) +
  `MixETHFaucet` (stateless free drip, 0.0001 ETH → 100 mix). The old
  unbacked-faucet + `zapOut.redeemETH` combo is why the testnet UI dropped
  ETH zap legs.
- On-chain UI: the whole frontend ships in `factory.html()`
  (`script/app.html`); `script/serve.sh <factory>` fetches it.

## Art pipeline (don't hand-edit generated files)

- Source of truth: `script/traits/*.txt` (10 stamps per axis incl. `head.txt`)
  + `script/traits/palettes.py` → `script/gen_pepe_art.py` →
  `src/PepeArtData.sol`. Codec v2: all 8 axes 4-bit (older 3-bit axes would
  alias ids ≥ 8), 100,000,000 combos, 24-slot palette.
- `studio/compiler.js` is the byte-identical JS port, pinned to golden sha
  `73fff0a5d6c0…d364` by `studio/test_compiler.mjs` AND the studio's in-app
  self-test. Do NOT edit `compiler.js`, `test_compiler.mjs`, `studio/spec/**`.
  After any art change the golden sha gets re-pinned in all three places.
- Renderers: `PepeDescriptor` (on-chain, NUL-packed name tables — it was once
  62 bytes OVER EIP-170 after an art pass; `forge test` cannot see deploy
  size, only a broadcast catches it) plus newer `PepeDescriptor8Bit` and the
  Vector SVG system (`VectorTraitArt/2`, `VectorBaseArt`,
  `VectorPepeDescriptor`, 480px canvas from the 48-grid). `script/traits69/`
  is 69px exploratory work.
- Deleting/moving traits **shifts on-chain DNA ids** — studio warns; re-audit
  old dna values after such a change.

## Testing notes

- Harness conventions: `forge-std` (`vm.prank`, `deal`, `bound`), exact-value
  asserts where math allows. Governance tests were REPLACED by timer tests
  (`test/unit/ClockDetonation.t.sol`), not deleted into silence; the
  no-governance grep gate proves the surface is dead.
- Test baselines warp to epoch 1000 (`BBase`): foundry's ts=1 is epoch 0,
  which collides with the staker's genesis sentinel.
- `fail_on_revert = true` on invariants; fuzz runs 256.

## Gotchas (do not relearn these)

- **`skip(x)` to advance time, never `vm.warp(block.timestamp + x)`** (stale
  contract timestamp). Worse: the **via-ir CSE warp bug** — two warps sharing
  a subexpression make the second warp one epoch short; use t0-anchored
  absolute warps.
- **cast tuple args**: tuple + each scalar as SEPARATE shell words; the
  single-string form dies with "encode length mismatch".
- **PoolKey.fee is uint24** (dynamic-fee flag `0x800000`); a wider width in an
  ABI signature = wrong selector = bare revert with zero subcalls.
- **Entropy-salted CREATE2 addresses ≠ simulation**: a forge script's sim
  state differs from its broadcast. Round-dependent ctor args (reinvestor)
  MUST come from a second pass reading the real chain. Never trust deploy
  console logs for addresses.
- **EIP-170 sizing**: `forge test` cannot catch deploy-size overflow — only a
  broadcast CREATE check does. Measure with `.deployedBytecode.object`
  (deployedBytecode in artifacts is an OBJECT, not a hex string).
- **Root `package.json` is `type: module`** → UMD `studio/compiler.js`
  attaches to `globalThis.PSPCompiler` under node ESM, not `module.exports`.
- **Package managers differ**: root/keeper = pnpm, `frontend/` = npm.
- **Nonce races / partial deploys**: always `--slow` on real broadcasts; if a
  broadcast dies midway, don't assume the factory is fine — check
  `currentRoundId()` and redeploy clean.
- **Frontend reads are raw batched `eth_call`** (no wagmi polling); a stale
  factory address renders as eternal "loading" — check env first.
- **Referral attribution binds ONLY via user-signed `registry.record()`**
  (A-1 fix): hookData is an untrusted 32-byte trader hint; forged payloads
  are inert. Don't reintroduce lazy attribution from hookData.
- Anvil default account 0: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`.

## Conventions

- Exact-pinned `pragma solidity 0.8.26`; explicit imports; errors declared in
  a block at the contract top; natspec `@title`/`@notice` everywhere;
  `Ownable2Step` admin; `SafeERC20` throughout; fixes annotated inline with
  finding ids (`A-1`, `C-1`, `F-9`, `NK24`, `M-1`, …).
- Timing fields pack via `CurveMath.packTimings` / `packTimingsCapped` —
  3 × 85-bit derived-width fields ([0] predeposit window, [1] unstake vest,
  [2] per-wallet predeposit cap in whole mixETH; 0 = mainnet defaults). The
  vote slot died with governance; never hand-roll packing (a previous
  hand-rolled 5×64 packing silently zeroed a field).
- mixETH is the **sole unit of account** — the vault's 4626 rate is never
  read in settlement (NK24 F1).
- Frontend red lines (CLOCK-REDESIGN §6): PhaseEngine is the ONE rAF loop;
  HashRouter with `?ref=` capture; no invented reads — ABI shapes in that doc
  are binding for the frontend.

## Context docs (read before touching the area)

- `CLOCK-REDESIGN.md` — the binding clock/ladder/fee/redemption spec (both lanes).
- `TODO-SEPOLIA.md` — deploy checklist + playtest-wave decision log (read
  top-down: newest decisions supersede older ones).
- `GATE-LOG.md` — every suite/size/fork-dry-run gate with dates; append, don't rewrite.
- `HANDOFF.md`, `NK24-REMEDIATION.md`, `SECURITY-REVIEW*.md`,
  `audits/2026-08-23-multiagent-audit.md` — history; `docs/VESTING-DESIGN.md`
  for the staker engine; `frontend/REDESIGN-*.md` for the UI redesign.
- Branch topology: remote `main` is an orphan public squash (no merge base);
  real history lives on `sigma-testnet` (and `sepolia`/`sepolia-fixes`).
