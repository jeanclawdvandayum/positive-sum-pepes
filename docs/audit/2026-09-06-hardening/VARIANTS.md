# Variant review

Baseline: `926e4b46`; six fixes documented in REVIEW.md.

| Search step | Pattern / scope | Matches and disposition |
| --- | --- | --- |
| Exact sparse payout stop | `if (who[i] == address(0)) break;` in src | One confirmed consumer bug, AUD-16 |
| Expand to other break conditions | Registry, Hook, then all src break statements | Registry stops on genuinely absent nodes or finishes duplicate search; numerical loops stop at endpoints/convergence. No second sparse payout consumer found. |
| Exact epoch sentinel | `return r == 0 ?` in Staker | One residual view bug, AUD-20 |
| Expand to requestEpoch / isWithdrawing users | Staker, tests, frontend | Financial mutators and frontend use the explicit flag. Correcting the view does not alter the vesting schedule. |
| Exact CREATE2 dependency | deployStakerAt call in Controller constructor | One unconditionally recreated dependency, AUD-17 |
| Expand to salted deployers and their factory callers | Token, controller, registry, hook, staker | Four factory creation sites already check code presence; staker constructor dependency lacked that check. Early pool initialization is the separate consumed-resource variant AUD-18. |
| Exact user-grown allocation scan | while ownerOf[nextTokenId] exists | One shared allocator reaches lock and genesis claims, AUD-19 |
| Expand to loops over owner arrays | Staker._owned and registry qualification | stakedTotalOf is used synchronously in referral eligibility: AUD-21. Enumeration for UI and caller-selected multiclaim work remain visible scope limits. |

Broad searches for all `break`, zero-valued fields or loops produced many
legitimate matches; they were inspected by purpose rather than treated as
findings. Zero padding is safe to terminate only when the producer guarantees
that later entries cannot be populated. An occupied CREATE2 address is safe to
reuse here only because its exact creation program and arguments are committed
in the address; arbitrary user-supplied contract adoption is not equivalent.

Regression guard: `bash scripts/check-audit.sh` includes SkillCallbackReview,
SkillLifecycleReview and SkillStakingReview. Their desired-output assertions
detect these root causes directly, including the gas properties; a blanket
regex banning zero checks or loops would produce false positives.
