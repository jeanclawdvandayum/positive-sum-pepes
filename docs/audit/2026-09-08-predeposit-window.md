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
