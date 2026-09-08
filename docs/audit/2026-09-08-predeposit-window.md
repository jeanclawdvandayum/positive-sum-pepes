# Predeposit window starts at completed birth

The user approved a fresh deployment on September 8 after round 2's delayed
staged birth exposed an expired window. Its controller was created at timestamp
1788797910; the final RoundDeployed transaction completed at 1788839736. The old
immutable constructor timestamp consumed the two-hour window before users could
access the completed round.

The new controller records `predepositStartTime` on its first nonzero `setHook`
call. The factory makes that call in the final, atomic wiring transaction.
Failed wiring rolls the timestamp back. Repeated wiring cannot reset it, and
a zero hook is rejected. Public deposits and pooled launch reject before wiring;
`windowOver` remains false while the hook is unset. Duration, caps, and launch
eligibility after wiring retain their existing rules.

The delayed-genesis regression pauses 24 hours between creation and wiring and
checks the complete window and exact expiry boundary. The staged-successor test
also pauses 24 hours and checks its new start time. Existing deployments retain
their original code and timing. Assets are not migrated by this release.

## Deployed result

Factory: `0xa3958145ab9a87e01a10ca3f3c404f5898f41a2f`.
`predepositStartTime` and final birth timestamp both equal **1788843992**.
The window is 7,200 seconds. Local and production UI settings point to all
new game contracts, with the existing Ethereum registrar preserved.

Validation: 514 Solidity tests / 68 suites, 154 frontend tests, 11 verifier
tests, complete deterministic gate, successful deployment rehearsal, 17
successful deployment receipts, two on-fork release lifecycle tests, and
17/17 source/runtime matches. The new remote eligibility gate also has a
creation/runtime match. Existing names remain registered; old pending
commitments need renewal after the eligibility-gate rotation.
