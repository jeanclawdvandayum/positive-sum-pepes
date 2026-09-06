# Current-round UI state

Baseline: `2605bffa`. The reported symptom was a “spawn round 2” button after
round 2 had already been created and launched. This review covers the frontend
state that chooses the spawn controls, ladder and claims; no contracts changed.

## Root cause and search

`Trade.tsx` used `const postRound = detonated || dead.dead`. `useDeadRound`
intentionally finds a previous settled round even after the factory advances.
Thus historical settlement kept selecting the old round's controls and ladder.
The violated rule is that the play page's operational state belongs to the
factory's current round; historical claims belong in the graveyard.

Exact search `postRound && dead.roundId !== undefined` found the one reported
spawn mount. Expanding to `postRound|dead\.dead|setDetonated|justDetonated` found
14 lines in the live page/component source: ten in Trade and four in PostRound.
Repository-wide searches also returned historical GATE-LOG descriptions, which
are records, not live conditions. Searches for spawn/current-round and ladder
state found the lifetime and stale-cache variants below. No failed exact-match
pattern was used to infer a fix. The search remained a bounded frontend review.

## Confirmed issues

| Issue | Severity / confidence | Fix |
|---|---|---|
| Completed spawn remains offered when any previous round is dead | Low / high | Spawn ID derives from current-round settlement; hide during round-read errors and immediately on confirmed completion |
| Old ladder, pot and claim data replace the successor's board | Medium / high | Board always reads the current hook; claim amounts require matching round ID and hook |
| A local detonation flag and completed action state persist into later rounds | Low / high | Record the detonated round ID; key detonate, spawn and pot-claim controls by their round targets |
| Ladder stale-data fallback can carry prior winners into a new hook after a failed read | Medium / high | Scope the cached board by hook; stale data may merge only within that hook |

The existing spawn loop already checks `currentRoundId` before every wallet
write; this limits the original stale card to misleading UI instead of blindly
spawning an extra round. That check remains and now rejects a backwards/mismatched
round read. Its checking phase disables repeat clicks before the first read finishes.

PostRound's four broader matches are not this bug: it is an explicit historical
redemption component whose targets and exit preflight use the supplied dead round.
It currently has no caller. Graveyard reads likewise intentionally enumerate old
rounds and are retained. Their history must not determine current play state.

## Regression guard and release

`frontend/tests/play-round-state.test.mjs` exercises an active round, confirmed
detonation before polling, pending birth, successor predeposit/active, another
detonation, out-of-order readers, wrong hook, unknown state and RPC recovery.
The transition retains both the old dead-round result and local receipt to
reproduce the original bug. The CI guard is included in the standard command:

```sh
node --experimental-strip-types --test frontend/tests/play-round-state.test.mjs
```

This is a frontend fix and works with the existing deployment. See GATE-LOG.md
for final gate counts and browser verification; no deployment or wallet transaction
is required for the change.
