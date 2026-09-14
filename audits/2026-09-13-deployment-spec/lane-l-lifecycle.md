# Lane L — Lifecycle & Timing (predeposit window → launch → detonation → successor wiring)
Adversarial audit, deployment-spec pass (branch `deployment-spec` @ `6f18dbd7`, 2026-09-13).

Scope: `src/RoundController.sol` + `src/PSPFactory.sol` timing paths, with read-only verification of the
decode consumers (`CurveHook.sol`, `PSPStaker.sol`, `SineMath.sol`, `CurveMath.sol`, `script/DeploymentSupport.sol`).
Four charter questions: (1) early launch / window-delay griefs / pre-wiring fund recovery, (2) dust-boot
launch reversion vs. pre-launch withdrawal, (3) successor-round birth orderings, (4) 4×64 timing-pack decode.
No changes to `src/` or `test/` were made by this lane.

Severity scale: High / Medium / Low / Info. No High found. One Medium (deploy-gated config hazard),
two Low, rest Info/positive confirmations. Refuted hypotheses are explicit in §R.

---

## Q1 — Early launch, window-delay griefs, pre-wiring recovery

### Entry-point census (the launch gate is single and closed)
The only state path out of `Mode.Predeposit` is `launchPooledBuy` (`RoundController.sol:447-501`):
- `CurveHook.setMode` is controller-only (`CurveHook.sol:827`) and the controller calls it only at
  `:499` (Active, inside `launchPooledBuy`) and `:594` (Flat, inside `detonate`, which itself requires
  Active at `:589`).
- `CurveHook.initializeCurve` is controller-only + `poolInitialized` one-shot (`CurveHook.sol:863-864`),
  called only from `launchPooledBuy:481`.
- The gate itself (`RoundController.sol:448-451`): `hook != 0`, `!predepositClosed`,
  `msg.sender == owner() || _windowOver()`, where `_windowOver()` (`:413-415`) requires
  `block.timestamp >= predepositStartTime + PREDEPOSIT_DURATION` and `predepositStartTime` is set
  exactly once, inside `setHook`, when `hook` was zero (`:227-228`). Zap/router deposits go through
  `predepositFor` → the same internal path; they cannot touch mode or clock.

**L-I1 (Info — refutes "owner bypass is reachable"): the owner early-launch bypass is dead code.**
`owner()` of every controller is the factory *contract* (`Ownable(_factory)`, `RoundController.sol:165`),
and the factory has **no function that calls `controller.launchPooledBuy`** (grep across `src/`: the only
call sites are tests, `DriveAnvil.s.sol`, and the controller itself). The factory owner EOA therefore
cannot launch early either — on the current bytecode, **nobody at all** can launch before
`predepositStartTime + PREDEPOSIT_DURATION`. The docstring at `:445-446` ("controller's existing
factory-only bypass remains") describes unreachable code. Consequence for this lane: the window end is
the *only* launch deadline; for Q2's dust-boot there is no owner-forced exit either (it would hit the
same revert anyway). Cross-lane correction: `lane-f-fees.md` F-L1 sketches "factory owner calls
`controller.setHook(attacker)`" — same reachability error; see §R-R5.

### Window-delay griefs (non-owner): none unbounded
- Birth phases are permissionless (`PSPFactory.sol:309-323`) and idempotent against third-party
  "help": predictions are create2 addresses of the factory's immutable vessels (`_reserve:363-381`);
  a griefer cannot squat them (deployer+salt+initcode all factory-controlled), and canonical early
  deploys are wired as assists (`_birthContracts:422-427`, `_birthPeriphery:466-471`).
- `ReservationStale` (which would strand phases 1-2 until voided) can only be produced by owner state
  churn: `configureSine` / `setDescriptor` / a new `reserveGenesis` — all `onlyOwner`
  (`PSPFactory.sol:85-87, 106-110, 295-298`); the context hash pins curve+timings+descriptor+names
  (`:392`, re-checked at `:416` and `:486`).
- Reserve-stage hook mining is bounded (`HOOK_SCAN_CAP = 131_072`, `:244`); exhaustion (~0.03% of
  draws) reverts the deposit-free reserve cheaply and the next block's `prevrandao` re-rolls the salt
  space (`:363`). Not a sustainable delay.
- `voidReservation` is owner-only (`:348-351`). A griefer's `reserveSpawn` (`:273-287`) commits the
  identical reservation the community would want — `_reserve` takes no attacker-chosen parameters.

**L-I2 (Info): "unbounded window delay" is owner-only; and while wiring is incomplete, no public
funds exist.** Public deposits require `hook != address(0)` (`RoundController.sol:319`), and `hook` is
set in the *final* wiring tx, which is the same tx that starts the window (`setHook:228`, called from
`_birthWire` at `PSPFactory.sol:496`). So the ordering is exactly: wiring completes ⇒ window opens ⇒
deposits become possible. "If wiring never completes, can predepositors recover funds?" is vacuous —
there can be no predepositors (the only pre-wire inflows are factory-only `seedCarry`/`potDeposit`,
`:347, :367`). Post-wiring stalls are Q2 territory.

---

## Q2 — `_validateBootstrap` dry-run, dust boot, pre-launch withdrawal

**L-L1 (Low — liveness): a sub-threshold pool makes every `launchPooledBuy` revert, and there is no
pre-launch refund path; recovery is top-up-only.**
- Dry-run asymmetry: `_validateBootstrap` (`RoundController.sol:385-393`) only exercises
  `hook.sineGenesisPSP` when `netBoot >= 450e18`; below that, deposits of *any* size are accepted
  (`_recordPredeposit:396`, and PD-1 comment `:331-332`). Launch then computes
  `initialPSP = hook.sineGenesisPSP(curveBoot)` (`:470-472`) on the identical quantity validated at
  deposit time (`netBoot = totalBoot − mulDiv(totalBoot, 1000, 10000)` == `curveBoot`, `:387` vs
  `:460-461`) — so for pools ≥ 450e18 the deposit-time guarantee is exact (same args, same pure
  function, no unvalidated mutator in between: every public/carry path validates, and direct
  mixETH donations to the controller never enter `totalBoot`).
- For dust pools, `SineMath.materialize` reverts instead of returning 0: `bootActual == 0` →
  `InvalidParams` (`SineMath.sol:117`), `lam` truncation → `:122-123`, and crucially `q0 == 0` →
  `:131`. With validated params (`p0 ∈ [1e9, 1e18]`, `SineMath.sol:104`), the genesis supply integral
  truncates to zero for boots below roughly `p0` — a parameter-dependent band from 1e-9 to 1 mixETH.
  The `initialPSP == 0 → revert ZeroAmount()` branch at `RoundController.sol:473` is **unreachable on
  the sine path** (the hook call reverts first); it is live only for the retired zone flavor
  (`CurveMath.computeBuyOutput`, `:472`). An empty successor (no carry, no deposits) reverts at
  `bootActual == 0`.
- PoC sketch (sine round, p0 default): alice `predeposit(1 wei)` → warp `start + 3 days` →
  `launchPooledBuy()` reverts (bubbled `InvalidParams`); repeat forever. Then anyone
  `predeposit(1e18)` → `launchPooledBuy()` succeeds (deposits never closed — see next bullet).
  Empty-round variant: fresh successor with zero carry, warp past window, launch reverts until the
  first deposit ever arrives.
- The escape valve is real but implicit: `_predepositFor` checks only `predepositClosed`
  (`RoundController.sol:320`), which is flipped exclusively by a *successful* launch (`:451` — a
  reverting launch rolls it back). There is **no window-end check on deposits** and **no
  pre-launch withdrawal function anywhere** (the round's only mixETH exit is `sweep`, which is
  `ProtectedToken` while `!predepositClosed`, `:645`). So dust-booted predepositors are not bricked,
  but their only exit is: someone (anyone, including themselves, from any wallet — the pool is
  uncapped) adds capital past the dust band, the round launches, they claim PSP
  (`claimPredepositPSP:517`) and exit via redemption/sale. The round cannot be aborted and mixETH
  cannot be reclaimed as mixETH. Severity Low, not Medium: self-rescue costs ~p0 (dust), the rescuer
  is compensated pro-rata like everyone else, and no third party can extract the stuck principal.
- Adjacent-known (not re-flagged, snapshot at `audits/2026-09-08-testnet-final.md`): L-4 `ZeroShare`
  — a depositor whose `genesisPSPSnapshot·dep/totalPredepositMixETH` truncates to 0
  (`RoundController.sol:549-550`) can never claim: both numerator and denominator freeze at launch,
  so the "retry later if a larger share ever applies" comment is optimistic — the share is a launch-
  time constant. Per-depositor dust loss, flag never set, principal stays in the virtual genesis lock.

---

## Q3 — Detonation tolerance and successor birth orderings

### Refuted orderings (each verified impossible on current code)
- **n+1 born with a closed window:** `predepositClosed` is fresh-false per controller and is set only
  by that controller's own successful `launchPooledBuy` (`RoundController.sol:451`). Nothing in birth
  or spawn touches it. *Refuted.*
- **wrong `predepositStartTime`:** set exactly once, when `hook` goes 0→nonzero, inside the successor's
  own `setHook` (`:227-228`), called only from `_birthWire` (`PSPFactory.sol:496`) on the fresh
  controller. Re-setHook cannot move it (the `address(hook) == address(0)` condition is spent), and no
  factory code path calls `setHook` on an already-wired controller (see §R-R5). A wire-tx revert rolls
  the write back atomically — there is no state where `hook` is set but the round is unrecorded
  (record + `reservation.active = false` are later in the same tx, `PSPFactory.sol:532-549`).
  *Refuted.*
- **window open early relative to its own wiring:** deposits revert `NotPredeposit` until `hook != 0`
  (`RoundController.sol:319`), and `hook != 0` happens only in the wire tx. Composed spawn
  (`detonate` → `spawnNextRound`) births n+1 and starts its window in the same tx — window start ==
  wiring, never earlier. Staged path (`reserveSpawn` + 3× `birthStep`) starts the window at the
  *phase-3* tx, which is the wiring. *Refuted.*
- **mid-flight config swap:** context hash re-checked before the first create *and* at wire time
  (`PSPFactory.sol:416, 486`); hook `configureSine` is factory-contract-only and pre-init guarded
  (`CurveHook.sol:886-887`), and the factory calls it only during `_birthPeriphery` (`:475`), so a
  wired round's `sineConfigured` is frozen for the deposit window — launch and `_validateBootstrap`
  always see the same flavor. *Refuted.*
- **spawn partial state:** `spawnNextRound` is atomic (any internal revert → whole call reverts →
  `okSpawn = false` in `detonate`, `RoundController.sol:619-622`), and `markDestroyed` is committed in
  a *prior*, separately-successful call (`:600-601`) so a bouncing spawn cannot un-destroy the round.
  *Refuted.*

### Confirmed-sound behaviors (positive)
- Detonation ordering: flatten → `flatTime` → mark → (gas-gated) spawn → event
  (`RoundController.sol:594-625`). A failed/tolerated spawn leaves the round Flat, locks open,
  destroyed, and redeemable; the successor is finishable permissionlessly
  (`reserveSpawn` + `birthStep`). AUD-3's 100k retained gas and the 30M attempt gate are coherent.
- Chain-forward integrity against attackers: `markDestroyed` is controller-of-that-round-only
  (`PSPFactory.sol:605`), `reserveSpawn`/`spawnNextRound` require destroyed + latest
  (`:276-277, 563-564`). A griefer cannot fork the round chain.

**L-I3 (Info — owner-only ordering hazards, both tolerated by design, worth spec text):**
1. *Active genesis reservation at detonation time:* `reserveGenesis` does not check live-round state
   (`PSPFactory.sol:295-298`), so an owner reservation created while round n is alive makes n's
   composed spawn revert `ReservationActive` → spawn bounce → `Detonated.nextRound = address(0)` until
   the owner `voidReservation`s and someone `reserveSpawn`s. Owner-caused successor delay only.
2. *Out-of-band `deployRound` while round n is live:* `deployRound` (`:179-190`) also ignores
   live-round state; birthing n+1 early advances `currentRoundId`, after which n's detonation spawn
   reverts `NotLatestRound` forever (tolerated bounce). Round n still flattens/destroys/redeems; its
   carry simply never seeds a successor (it waits at the factory for whatever round next wires with
   `fromRoundId != 0`... in practice stranded until an owner-initiated chain, since `reserveSpawn`
   can only chain from the latest round). No attacker path (`deployRound` is `onlyOwner`).
3. On chains whose block gas limit is ≤ 30M, `gasleft() > 30_000_000` (`RoundController.sol:618`) is
   never satisfiable — the composed spawn is never attempted and `Detonated.nextRound = address(0)`
   is the *expected* mainnet shape, not an anomaly. UI/spec should treat it as the normal staged path.
4. Orphan debris from owner `voidReservation` after phases 1-2 (token+controller born, sine armed on a
   hook that never wires): no funds can exist there (deposits need `hook != 0`), purely address-space
   litter. Same-block re-reserve re-derives identical salts and completes idempotently (entropy is
   `prevrandao/timestamp/number/newRoundId`, `:363`; same-block ⇒ same predictions ⇒ "helped" path).

---

## Q4 — Timing pack (4×64) decode dangers

Layout (`CurveMath.sol:541-543`): `[0]` predeposit window (s), `[1]` vest (s), `[2]` detonation window
(s, hook), `[3]` wallet cap (whole mixETH). `timings == 0` → defaults 3d/28d/uncapped/69h04m20s, and
both consumers (`RoundController.sol:170-188`, `CurveHook.sol:235-236`) agree on the word
(`roundTimings` is threaded through the reservation and pinned by `contextHash`, so controller and
hook can never decode different slots). Compile-time layout guard (`CurveMath.sol:550`) and
`TimingsOverflow` on pack (`:560-561, 578-579`) close the historic spill/truncation holes.

**L-M1 (Medium — deploy-gated config hazard): slot [1] values 1..5 seconds pass every on-chain guard
and permanently strand the entire predeposit pool — launch itself becomes impossible.**
- The constructor tripwire only catches *zero* slots (`RoundController.sol:187`,
  `TimingsIncomplete`). But `PSPStaker.epochSize() = VEST_DURATION / 6` (`PSPStaker.sol:158-160`)
  truncates to 0 for `VEST_DURATION ∈ [1,5]`, and `_epoch() = block.timestamp / epochSize()`
  (`:406-408`) then panics 0x11 (division by zero) on every epoch-touching path. The first one to
  fire is `launchPooledBuy` itself: the tx calls `staker.lockGenesis(initialPSP)`
  (`RoundController.sol:496`), which reads `_epoch()` (`PSPStaker.sol:788`) and `_checkpoint()`
  (`:793`) before anything else. So the round **never reaches Active** — every launch attempt
  reverts, and because the vest slot is immutable, no amount of topping up (the L-L1 escape) can
  ever fix it: with no abort and no refund path, all predeposit mixETH is locked in the controller
  forever (`sweep` is `ProtectedToken` while `!predepositClosed`, `RoundController.sol:645`, and
  `predepositClosed` only flips on a successful launch). Had a round somehow launched, the same
  panic would brick every staker exit — including the post-detonation shortcut (`withdraw` bypasses
  the decay guard at `PSPStaker.sol:705-707` but still settles and checkpoints at `:712, :715`) —
  but that state is unreachable on this code path; the mixETH stranding is the live consequence.
- Reachability: `packTimings` enforces `vest % 6 == 0` (`CurveMath.sol:563`) and the deploy script
  packs via `packTimingsCapped` (`DeploymentSupport.sol:39-44`) — but `PSPFactory`'s constructor takes
  the raw `_timings` word with no divisibility or minimum check (`PSPFactory.sol:139, 154`), so the
  guard is pack-time-only. This is exactly the class the 2026-08-19 lesson guards against (a slot once
  truncated silently in a hand-assembled word). A one-line on-chain hardening — `VEST_DURATION < 6 →
  TimingsIncomplete` next to the `== 0` check — closes it. Until then, spec must mandate
  `packTimingsCapped` as the only legal constructor input path.
- PoC sketch (no test added per charter): deploy factory with hand-assembled
  `roundTimings = 3 days | (uint256(3) << 64)`; birth a round; deposit past the dust band; warp past
  the window; every `launchPooledBuy()` reverts Panic 0x11 at `lockGenesis`; round permanently
  Predeposit; deposited mixETH irrecoverable (no abort, `sweep` blocked, immutability of the slot).

**L-I4 (Info — remaining decode dangers, all deploy-gated, no attacker input):**
- *Tiny nonzero slot [2]:* `detWindow` decodes verbatim (`CurveHook.sol:235-236`, 0 → 69h04m20s
  default) and arms at the Active transition (`:847-849`). A 1-second detWindow means the round is
  detonatable one block after launch — the ladder pays whoever bought in that block, every lock opens,
  successor spawns. No lower bound exists on-chain; only `packTimingsCapped` discipline (or a spec
  minimum) prevents it.
- *Tiny nonzero slot [0]:* window over at wiring+ε ⇒ permissionless launch essentially immediately
  (and, since L-I1, nothing can launch *before* that). Same class, spec-gated.
- *`vest % 6 != 0` (raw word):* benign — `epochSize` floors, decay completes at `6·floor(v/6) < v`,
  i.e. the vest silently *shortens* by the remainder; blocked at pack time anyway.
- *Slot [3] wallet cap ×1e18* (`RoundController.sol:183-184`): max ≈ 1.8e37, no overflow risk; the
  comparison `predeposits[b] + amount > CAP` (`:324-329`) is sound.
- *Window arithmetic:* `predepositStartTime + PREDEPOSIT_DURATION` (`:414`) cannot overflow
  (2^64-1 ≈ 1.8e19 + 1.7e9 ≪ 2^256). Window end is inclusive (`>=`), matching
  `PredepositWindow.t.sol:183-186`.

**L-L2 (Low — semantics): the deposit side of the window never closes until launch executes.**
`_windowOver` gates only the launcher (`RoundController.sol:450`); deposits stay open past the window
end until a successful `launchPooledBuy` flips `predepositClosed`. This is the mechanism behind the
"dust pools can grow into a representable launch" comment (`:382-384`) and the Q2 escape valve —
but it also means the effective deposit deadline is *launch time*, not window end: a whale can deposit
into the pool in the same block as (front-running) the launch tx and receive pro-rata genesis PSP on
equal terms. Inherent to an uncapped pooled IBCO (no auction/floor), not a new hole introduced by the
window-end asymmetry — but the deployment spec's UI language ("3-day predeposit window") overstates
the finality of the deadline, and indexers pricing "fair share" should treat
`predepositState().windowOver` as launch-eligibility, not deposit closure (`:418-442` reports both).

---

## R — Refuted hypotheses (explicit)
- **R1: "someone can launch before the window ends."** No. Single gate (`:450`), hook arming is
  controller-only and only reachable through it (see Q1 census); even the owner branch is dead code
  (L-I1). A tiny-packed slot [0] shortens the window itself, but that is deploy-chosen and still
  respects `windowOver`.
- **R2: "wiring griefs can delay the window unboundedly."** No non-owner vector: phases are
  permissionless and un-squattable, staleness needs owner state churn, mine exhaustion re-rolls per
  block. Unbounded delay requires the owner (I3.1/I3.2 or simply never wiring) — and pre-wiring there
  are provably no public deposits (L-I2).
- **R3: "predepositors lose funds if wiring never completes."** Vacuously false — deposits are
  impossible until the wire tx that starts the window (`:319` + `:228`). The real fund-exposure gap is
  post-wiring dust-boot with no refund path (L-L1).
- **R4: "a deposit sequence can make launch *always* revert with depositors permanently stuck."**
  Half-refuted: dust/empty pools do make every launch revert (exact region ≈ boot < p0, plus the
  ≥450e18 domain failures the dry-run already blocks at deposit time), but since deposits never close,
  any wallet can top the pool past the band and launch; the round has no abort, and no one else can
  extract the principal. Liveness caveat (Low), not a brick.
- **R5: "the factory owner can re-point `hook` mid-round / call `setHook(attacker)`" (also sketched in
  lane-f F-L1).** Unreachable as written: `setHook` is `onlyOwner` with owner = the factory *contract*
  (`RoundController.sol:165, 225`), the factory's only `setHook` call site is `_birthWire`
  (`PSPFactory.sol:496`) against the fresh reservation's predicted hook, and the factory exposes no
  generic call-forwarding or controller-ownership transfer. The known-open L-1 from
  2026-09-08 therefore downgrades to defense-in-depth on current bytecode (it would matter if the
  factory ever grew a forwarding path — it cannot, being deployed code). Same reasoning neuters
  `setFactoryRoundId` re-pointing (`:232-234`).
- **R6: "successor can be born with a closed window / wrong start time / early-open window /
  unlaunchable-by-ordering state."** Refuted one-by-one in Q3; the only "unlaunchable successor"
  is the Q2/R4 dust-or-empty pool (economic, order-independent), and the only spawn-chain breaks are
  owner-initiated (I3.1/I3.2) and tolerated without fund loss.
- **R7: "mid-window flavor flip (zone↔sine) desynchronizes the dry-run from launch."** Refuted:
  `configureSine` is factory-contract-only + pre-init/pre-configured guarded (`CurveHook.sol:886-887`)
  and the factory only calls it during phase 2; `sineConfigured` is frozen for the whole deposit
  window. (Residual: a *zone* round gets no `_validateBootstrap` dry-run at all — `:386` returns
  early — but zone curves are retired and the zone launch failure mode is the same fail-closed
  ZeroAmount/panic class audited as B-3/B-4; noted for completeness only.)

---

## Verdict
The lifecycle's timing spine is sound: the predeposit window opens atomically with final wiring and
cannot be opened early, moved, or closed by anyone (the advertised owner early-launch is dead code —
a doc bug, not a hole); non-owner wiring griefs are bounded to per-block retry noise; detonation's
mark-then-tolerated-spawn ordering leaves no partial-success state and every successor is born with a
fresh, correctly-timed window regardless of the staged path taken; and the 4×64 pack's historic
truncation holes are closed at compile and pack time. The two items that deserve spec action before
mainnet are L-M1 — a hand-assembled `roundTimings` with slot [1] in 1..5 seconds passes the on-chain
`TimingsIncomplete` tripwire, makes every `launchPooledBuy` panic at `lockGenesis`, and so
permanently strands the whole predeposit pool with no abort (one-line fix: reject
`VEST_DURATION < 6`) — and documenting L-L1/L-L2's design facts that the IBCO has no abort and its
deposit side stays open until launch actually executes (dust-boot recovery depends on it, and
"window over" means "launchable", not "deposits closed"). Everything else in the charter's threat
model — early launch, unbounded grief delay, successor mis-birth, window/wiring reordering — is
refuted on this branch with the citations above.
