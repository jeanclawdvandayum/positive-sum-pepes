# Chosen predeposit art

Depositors can select the art when claiming their pooled allocation. Selection
uses the same candidate ID and hash preview as `lockWithPepe`. It does not reserve
art while funds are deposited. A claim that loses an art race reverts atomically,
leaving the allocation and fee entitlement available for another choice.

`RoundController.claimPredepositPSPWithPepe(id)` shares the existing claim
calculation and one-claim flag. The controller passes the depositor and share to
`PSPStaker.claimGenesisShareWithPepe`, which requires the controller as caller.
The same internal genesis accounting handles selected and random claims. Only
the ID/DNA selection differs. Existing no-argument claims retain random art.

Selected mints reject ID zero, occupied IDs, and occupied rendered trait
combinations. The existing permanent trait registry handles aliases and keeps
art reserved after transfer or withdrawal. A collision never substitutes a
surprise face for the chosen preview. Claims still work after detonation.

The UI checks `PREDEPOSIT_ART_VERSION == 1` before offering the claim picker,
checks availability again at submission, and uses the contract's race protection
as the final authority. Legacy deployments retain their original claim flow.

Deployment: new controller and staker bytecode requires a fresh factory
deployment. Existing testnet contracts cannot acquire these entry points.

Validation: the final deterministic gate passed 523 Solidity tests in 69 suites,
160 frontend tests, 11 verifier tests, ABI/size/oracle/governance checks and the
production build. A 390px browser fixture verified selection and pending-state
controls. No live deployment was performed in this change.
