2026-08-26 00:05 +08 — forge test (Aug-24 state, pre-69px work): 611/611 PASS, 0 failed (69 suites). Clears 4-night gate-unknown. Aug-24 cached fuzz failure not reproducible.
2026-08-26 12:2x +08 — forge test (v5: 69px art, 24-slot palette, byte-pair RLE, migrated pins + new slot-width test): 612/612 PASS, 0 failed (69 suites). Descriptor 19/19 incl. re-pinned pixels + palette width + reachability.
2026-08-26 ~15:10 +08 — head editing shipped: head.txt (source of truth, byte-stable), compiler/referee/make_defaults carry it (ALL CHECKS PASSED, golden sha UNCHANGED 2f41f45a…9229 — no contract change, forge 612/612 carries over). Studio HEAD tab browser-verified: paint→preview→undo→compile-identical, zero JS errors. Live: fancy-comet-qdpg.here.now.
2026-08-27 ~00:40 +08 — scoopy studio pass v3 integrated (two zips, v2==v3 duplicate): 6 trait files + palettes + compiled .sol. Axes 8/9/8/8/8/7 -> 10 across the board (41->47 stamps + skins 8->10, irises 7->10). Repo regen BYTE-IDENTICAL to his compile after pinning 7 hand-set slot-19 mid-shadows in palettes.py (_extend now setdefault — hand-set wins). Golden sha 2f41f45a…9229 -> 73fff0a5…d364; referee ALL CHECKS PASSED (sha re-pinned in test_compiler + app-core badge + make_defaults). DESCRIPTOR CODEC v2: all axes 4 bits (old 3-bit expr/skin/iris would alias ids 8/9 -> wrong traits); COMBOS 25,804,800 -> 100,000,000; name tables rewritten (CRINGE/MEH/CROSSEYED/3D/Cyber/Cool shades/CIGAR/BONG/LOLLIPOP/JARHEAD/TOAD/SICK/Magenta/NeonGreen/Grey; HOMER->HOODIE; TATTOO/MUSTACHE/MAGNIFYING dropped — item/wear ids shifted, pre-launch so DNA impact moot). Item file order: JARHEAD=8, LOLLIPOP=9. Tests re-pinned from measured compose (23 edits): no-teeth invariant now exempts CRINGE id 8 (deliberate gritted teeth, human-approved); brows skin-deep #1A2E1E; bridge row 29 glint #D3EDCD; smirk band LIPSDARK; cigarette filter 44-47/ember 60-62; bong water #0055FF. Descriptor suite 19/19. ArtDump v5: 80 axis SVGs + 16 highlights + 16 randoms from real renderer. Contact sheet shipped to scoopy for eyeball verdict. Studio republished: fancy-comet-qdpg.here.now (verified serving new build). Frontend needs no change (fully on-chain driven; new bytecode picked up on next deploy).
2026-08-27 ~01:0x +08 — FULL SUITE after pass-v3 integration: 612/612 PASS, 0 failed (69 suites, incl. descriptor 19/19 re-pinned + ArtDump v5). Gate closed; commit follows.
2026-08-27 ~02:5x +08 [timestamp as-written last session; machine date was 2026-08-26] — SEPOLIA-READY: (1) PepeDescriptor was 24638B — 62 over EIP-170 after v3 art (forge test CANNOT see deploy size; only forge script's broadcast check catches it). Fixed: 80 trait names NUL-packed into bytes constant + BE-u16 offset table + slice getter (ABI wrappers kept, metadata byte-identical, descriptor 19/19 + ArtDump green). (2) PSP_FORK=1 vm.deal dry-run hook + [profile.sepolia] + etherscan wiring in foundry.toml. (3) example.env rewritten Sepolia-first (PK/RPC/Etherscan/PSP_TESTNET/PSP_PM/PSP_CURVE + VITE half + fork section). (4) FORK DRY-RUN VIA publicnode: full testnet path against canonical Sepolia v4 PM 0xE03A…3543 — SIMULATION COMPLETE, all addrs logged, 64M gas (~0.12 ETH). (5) Repo PUBLIC: github.com/jeanclawdvandayum/positive-sum-pepes = orphan public-main branch (228 files, real submodules, README); local full history on main + local-history. EXCLUDED from public: audits/, PoisonedAttribution PoC (A-1 OPEN HIGH — referral attribution poisoning via forged hookData, unfixed), HANDOFF/GATE-LOG, broadcast receipts, .herenow, node_modules, dist. Push flow: work on main → replay onto public-main for future pushes.
2026-08-26 21:3x +08 — A-1 FIXED (HIGH, audit 2026-08-23: referral attribution poisoning via forged hookData): attribution now binds ONLY via user-signed registry.record() (msg.sender). CurveHook hookData slims to 32-byte (trader) payout hint — lazy recordFor path deleted, forged 64-byte payloads are length-mismatched → ignored. Registry fully permissionless (recordFor/setRecorder/authorizedRecorders/owner/NotAuthorized/NotOwner/RecorderAuthorized/dead StakerUpdated deleted; ctor (staker,minStake); runtime 2,431B). Zaps drop referrerNftId param (zapInBuy/buyWithMix/zapOut/sellToMix — frontend never referenced it; 2026-08-19 always-carry-trader fix preserved). Factory setRecorder wiring deleted; HookDeployer.deployRegistry(staker,minStake). UX: binding order-insensitive (record any time; trades before record pay stakers — nothing consumed). GATES: forge 612/612 PASS (69 suites) incl. flipped PoC test_PoC_ForgedHookDataCannotStealAttribution (byte-identical attack replay: binds nothing, attacker earns 0, victim binds intended referrer post-attack) + Referral R1/R2/R6 rewritten to explicit record(); slither delta vs reverted baseline: 0 NEW detectors, −2 gone (reentrancy-events _payReferrals, immutable-states); EIP-170 all deployables legal (registry 2431B, HookDeployer 18715B, descriptor 22685B); Sepolia fork dry-run PSP_FORK=1 via cross-network Alchemy key: FULL PATH SIMULATION COMPLETE, 66.58M gas, exit 0 (changed registry ctor deploys clean). 62 zap callsites swept (paren-balanced codemod) + DriveAnvil.s.sol. A-1 regression UN-excluded from public repo (attack is dead; PoC file is now a hijack-blocked death proof). Replay → public-main follows this commit.
2026-08-26 22:0x +08 — BRANCH sepolia (Friday playtest kit, off main @45e6f63a; NOT on main): (1) src/testnet/SepoliaMixETH.sol — dumb 1:1 wrapper (hardcoded rate, no yield/no owner/no free faucet; ctor mints 10M to deployer; replaces MockMixETH in the PSP_TESTNET deploy path — the old mock had a FREE-UNLIMITED faucet() + yield knobs, wrong for a group playtest). (2) src/testnet/MixETHFaucet.sol — drip: 0.0001 ETH → 100 mixETH (multiples ok, sub-unit dust kept, TooLittle/FaucetEmpty reverts, no owner). (3) DeployPSP PSP_TESTNET path deploys both + seeds faucet with full 10M supply; timings lock 3d → 2d: packTimings(1d predeposit, 2d lock, +1d extend, 1d relock window, 1d vote). (4) test/testnet/SepoliaTestnet.t.sol 8/8: 1:1 wrap/unwrap, rate-never-moves (30d skip), exact drip rate, multiples+dust, TooLittle, FaucetEmpty w/ ETH refund, playtest-timing readback through a REAL factory round (1d/2d/+1d/1d/1d all five immutables). GATES: SepoliaTestnetTest 8/8; fork dry-run PSP_FORK=1 SIMULATION COMPLETE 66.16M gas (~0.143 ETH) with mix+faucet in the broadcast (EIP-170 CREATE check included); full suite pending → see next entry. Deploy for Friday FROM THIS BRANCH.
2026-08-29 53ce383b forge test 33/33 suites ok (Vesting 13/13 exact); sizes staker 10609/ctl 13576/reinv 4060/reg 2429B — EIP-170 legal; vite green
2026-08-27 17:31 +08 — SEPOLIA TIMINGS 2d VEST (scoopy): _testnetTimings 6h → 2d unstake vest (172800 % 6 = 0 → passes VestNotEpochal; decay = 6 × 8h epochs; predeposit 1d / vote 1d / flat exit 3d unchanged). Faucet verified spec-exact: MixETHFaucet DRIP_PRICE 1e14 / DRIP_AMOUNT 100e18 = 0.0001 ETH → 100 mixETH, deploy path seeds full 10M supply (SepoliaMixETH ctor → faucet). Docs synced: TODO-SEPOLIA cheat-sheet (retired lock/extend/relock → vest), VESTING-DESIGN epochs (testnet 2d → 8h; lazy genesis anchor wording), DeployPSP header. Frontend zero-change (epoch = vest/6n read on-chain, auto-adapts). GATES: forge build green; fork dry-run via publicnode PSP_FORK=1 full testnet path SIMULATION COMPLETE, 65.76M gas (~0.137 ETH), mix+faucet+factory+round1+hook+zaps+reinvestor all CREATE'd legal (ve-decay staker included). Pushed origin/sepolia (53ce383b + this).
2026-08-27 10:32 +08 [machine clock skew vs entry above; work order is append order] — SEPOLIA ONBOARDING (scoopy): (1) /predeposit page — countdown (startTime+PREDEPOSIT_DURATION), fill bar vs 500-mix cap, depositors + own-deposit tiles, mix (approve→predeposit) AND ETH (zapInPredeposit one-tx) paths, launchPooledBuy + claimPredepositPSP cards; Topbar nav link gated on open window, page reachable by URL post-launch for claims. (2) Faucets: FaucetButton full variant on-page (0.0001 ETH → 100 mix) + external sepolia-ETH PoW faucet link (sepolia-faucet.pk910.de) on chain 11155111. (3) Referrals: ReferralCard (staked-pepe picker → #/predeposit?ref=<id> copy-link, canReferNft ineligibility warning) + RefBanner visitor flow (?ref= capture → localStorage → URL strip; bind via registry.record(ref) when connected+unattributed+eligible; bound/quiet/dismiss states) on Predeposit + Trade; registry discovered on-chain via factory.referralRegistryOf(roundId). (4) Timing knobs env-driven IN SECONDS: PSP_PREDEPOSIT_SEC / PSP_VEST_SEC / PSP_VOTE_SEC (defaults 86400/172800/86400; vest % 6 == 0 documented) through _testnetTimings + example.env. Landing lifecycle copy de-hardcoded ("7d window" was wrong on testnet). GATES: forge build green; vite green 12.3s; knob-override fork dry-run (600/3600/120s) SIMULATION COMPLETE — env plumbing proven, not just defaults. Built by flash subagent (timed out at final wiring) — orchestrator finished App/Trade/Landing wiring + audited every seam (DepositInfo {uint256,bool} tuple match, fmtCountdown/parseAmountToWad existence, stakerAbi ERC721 entries, FaucetButton export).
2026-08-27 11:0x +08 — CARPET-VOTE FIXES (scoopy Sepolia findings): (1) QUORUM = STAKED PSP — _quorumDenominator()'s NK24 supply floor (max(stakedWeight, totalSupplyPSP)) retired; lockedAtPropose now snapshots staker.totalWeight() alone. The floor made quorum unreachable whenever staked was a minority of supply — frozen carpet governance on testnet. Thin-lock counter-forces (documented in-code): execution only after the FULL vote window (honest stakers counter-vote) + the bomber's own locked value is damaged proportionally by the flatten. (2) VOTES EVALUATED LIVE — voteCarpetBomb reads voteWeight(msg.sender, block.timestamp) instead of proposeTime (finding-29/M-1 sit-out rule superseded): stakes made after a proposal count; new lockers can defend/oppose an active bomb. Quorum stays anchored to the propose-time snapshot (G-1), so late locks widen participation without diluting it. (3) PSPStaker.voteWeight rewritten as a governance-only view: full power from the CREATION epoch (fee engine still epoch-gates for exact splits), decay mirrors the engine step-for-step (5/6→0), actionTime guard is existence-only (actionTime > at). CarpetBombCard copy synced ("quorum measured against total staked PSP at proposal time"; stale 3-day-window text dropped). GATES: new B8_CarpetVote 4/4 (quorum-vs-staked with supply>staked precondition + denominator equality pin; post-propose SAME-EPOCH stake votes at exact full power; fresh-stake same-epoch propose; decay 5/6→3/6→0 exact) — first run caught my own `actionTime >= at` guard eating same-block stakes (flipped to >), second "failure" was the via-ir CSE warp bug AGAIN, now on repeated SUBEXPRESSIONS (ts/E shared between two warp expressions — second warp one epoch short); t0-anchored absolute warps fixed it, LESSONS + evm-cortex finding 58 broadened. Full forge 34/34 suites 277/277 PASS; vite green 8.4s; sizes ctl 13442 (−134) / staker 10717 (+108) EIP-170 legal. NOTE: an earlier jq size read printed 29.5KB — deployedBytecode in artifacts is an OBJECT (.object holds the hex); measure with .deployedBytecode.object.
2026-08-29 ~02:0x +08 — PLAYTEST WAVE 2 (sepolia-fixes branch, on top of scoopy's 8038c017): (1) flat buys DEAD — CurveHook._handleBuy reverts BuyingDisabled in Flat (view mirrors; _handleFlatBuy deleted). (2) per-NFT voting: voteCarpetBomb(uint256[] pepeIds, bool), per-pepe dedup lastVotedPepeOn, ownerOf-checked; unstaking pepes hard-excluded (pepeVoteWeight=0 while requestEpoch≠0), cancel restores instantly. (3) LIVE quorum: staker.totalVotable (incremental Σ of request-free principals, genesis included) replaces the G-1 lockedAtPropose snapshot at execute AND at the failed-proposal replace check — mid-vote stakes widen the denominator AND can vote (trade accepted in-code). (4) per-wallet predeposit cap = 5th packed timing slot, whole-mix units, 0=uncapped (mainnet + all legacy tests unchanged); testnet packs 10 (PSP_WALLET_CAP_MIX). (5) factory UI views: currentRound/pspRoundToken/roundPool/roundInfo; rebirth loop already existed (test_Rebirth proves round 2 = "PSP2" from ITS predeposit with carry). (6) Frontend: exact max-fill (wadToExact — the stake-max grey-out was Number(bal)/1e18 float rounding UP), max chips on swap/predeposit/stake, buy tab locked in flat, CarpetBombCard rewritten (pepe selector + live denominator + per-pepe voted/unstaking states), per-wallet cap display. GATES: forge 306/306 (38 suites) — B8 rewritten to new semantics 8/8, PlaytestFixes2 6/6 (cap + views + rebirth), Vesting 13/13 (VoteWeightSnapshot re-pinned to hard-exclusion + cancel-restore), B1e re-pinned to pre-fee integral via CurveMath (getSellOutput went post-fee in 8038c017 — test had drifted). EIP-170: factory 15134 / ctl 14093 / staker 10017 / hook 12153. vite+tsc green. NOTE: BBase now warps to epoch 1000 (foundry ts=1 = epoch 0 collides with lastPointEpoch==0 sentinel → totalWeight()=0 in pure-genesis rounds; the OLD quorum-vs-0 passed vacuously — surfaced by totalVotableWeight asserts, not a new bug).

2026-09-03 — BASE SEPOLIA DEPLOY-READY (sigma-testnet, prep for scoopy deploy): example.env rewritten 84532-first — BASE_SEPOLIA_RPC_URL (alchemy/publicnode/sepolia.base.org), PSP_PM=0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408 (canonical Base Sepolia v4 PM), Coinbase+Alchemy native-ETH faucet links, PSP_DEPLOYER_CUT_TO doc line, full VITE_ half incl. VITE_MIX/VITE_FAUCET (env-gated faucet UI) + VITE_REINVESTOR; RETIRED knobs deleted from the template: PSP_VOTE_SEC (governance dead — detonation clock replaced it) and PSP_CURVE (sine-only since 77a528d4; live knobs PSP_PREDEPOSIT_SEC/PSP_VEST_SEC/PSP_WALLET_CAP_MIX, fast-playtest defaults 2h/1h/10). foundry.toml: +[profile.base_sepolia], +base_sepolia etherscan entry (Etherscan V2 one-key, chain=84532), dropped unknown verify=false profile keys; FIXED pre-existing phantom-profile bug: [profile.invariant] was a NEW profile, not [profile.default.invariant] — the documented 64×32 + fail_on_revert=true silently never applied (foundry warned "unknown config for profile invariant" on every invocation); now correctly nested and LIVE. Makefile: test-v4/test-destroy targets removed (their suites no longer exist). frontend/.env.basesepolia.example added (84532; Coinbase faucet link already in config.ts). README quickstart → Base Sepolia + required DeployReinvestor second pass. GATES: forge config parses warning-free; no-governance grep gate CLEAN; FORK DRY-RUN via https://sepolia.base.org, chain 84532, PSP_FORK=1 PSP_TESTNET=1 PSP_PM=0x05E73354…: FULL TESTNET PATH SIMULATION COMPLETE — 73,089,541 gas, ~0.000804 ETH @ 0.011 gwei (factory 0xc5ddf67e… simulated; sim addresses are entropy-salted fiction, chain receipts only after broadcast); invariants 5/5 under the NOW-APPLIED fail_on_revert=true; full suite 362/362 PASS (46 suites). Remaining manual step: fill example.env (PRIVATE_KEY, BASE_SEPOLIA_RPC_URL, ETHERSCAN_API_KEY).

2026-09-03 — BASE SEPOLIA DEPLOY BLOCKED AT GENESIS (sigma-testnet): DeployPSP broadcast landed 9/13 legs (mix 0x1FBe93FE…, faucet 0xF3ceB0FD…, factory 0xb46130fc…, descriptor+sine wired; zapIn/zapOut from console are SIM FICTION — never broadcast). Genesis deployRound CANNOT FIT: fork-sim consumes 21.04M gas (trace-verified success), real txs revert at ~16.35-16.49M — the hook salt-mine bound (131,072 iters × ~33 gas + ~12M constant) — and Base Sepolia enforces a ~16.78M (2^24) per-tx cap at the OPERATOR level (probe: 16M ACCEPTED, 20M rejected on both alchemy and sepolia.base.org; 15M rejected transiently). Even the luckiest mine draw cannot fit. TODO-SEPOLIA's "16.57M fits" measurement (dcea9a09 era) PRE-DATES the clock redesign (2985a957/10020d75, 2026-09-01) which grew CurveHook creation code ~23.3KB — post-redesign genesis is a regression past the cap. 5 attempts total (3 mined-reverts ~0.00018 ETH each, 2 send-rejections); state rolled back clean each time; currentRoundId still 0. Completion tooling shipped for when this unblocks: script/CompleteBaseDeploy.s.sol (idempotent: skips round if live, publishes UI, deploys zaps), script/PrintBirthCalldata.s.sol (raw calldata for explicit-gas cast send). UNBLOCK OPTIONS: (a) split genesis reserve/birth in PSPFactory (staged spawn for round 0 — reserve is cheap, birth must still fit 16.78M — needs measuring, may also be over), (b) slim CurveHook creation code back under the pre-redesign envelope, (c) deploy to Base MAINNET (no per-tx cap) — not a testnet action. NOT FIXED BY: RPC choice, --slow, gas-limit tuning, retries (entropy re-roll) — 3 independent real blocks all exhausted the mine bound.

2026-09-03 — GAS-CAP FIX SHIPPED + BASE SEPOLIA DEPLOYED (sigma-testnet): PSPFactory genesis split into multi-tx staged flow — reserveGenesis(RoundParams) owner-only commits gameCurve + entropy-salted addresses ( SpawnReservation now carries name/symbol/phase; getter helpers reservationActive()/reservationPhase()); birthStep() permissionless executes the NEXT unfinished phase: 1 CONTRACTS (token + controller + staker-in-ctor ≈7.96M) · 2 PERIPHERY (registry + hook ≈7.97M) · 3 WIRE (contextHash re-check fail-closed + wiring + sine arm + pool init ≈0.53M). Composed paths preserved: deployRound/spawnNextRound unchanged semantics for uncapped chains; birthRound() = composed loop over birthStep. RoundController.detonate() now TOLERATES a failed spawn leg (FactorySpawnFailed error retired — C3_Lifecycle updated to the new semantics): on capped chains detonate still flattens/freezes/opens locks/marks destroyed and emits Detonated(nextRound=0); anyone finishes via reserveSpawn + 3× birthStep. DeployPSP switched to staged genesis (reserveGenesis + 3 birthStep broadcast segments); CompleteBaseDeploy updated likewise; PrintBirthCalldata.s.sol deleted (obsolete). GATES: forge 369/369 PASS (47 suites, incl. 7 new test/unit/StagedGenesis.t.sol: full flow, permissionless legs, gas bounds, guards, stale-context fail-closed ×2, split rebirth w/ carry, composed compat); no-governance gate clean; FORK DRY-RUN on real Base Sepolia state: reserveGenesis 4.52M · birthStep 7.96M/7.97M/0.53M · setHtml 10.37M — ALL under the ≈16.78M operator cap with ≥8.8M headroom. REAL DEPLOY LANDED (Base Sepolia 84532, ONCHAIN EXECUTION COMPLETE & SUCCESSFUL): factory 0x8CD05a831fA7505C24eeb8eDC410283d9042aaF5 · mixETH 0x9FA57CCF074dA42B9FC8dd3c44bB44ec018d1aBa (free public mint) · faucet 0xF9eD09f7117098759bbC9d78296E7b08a4B4C532 · zapIn 0x8A2d2dAbC8c506c1447c7145a22fF45481b02002 · zapOut 0x00f5EF7045bFbE0A1BEFf326a7Ef3B0699D8Ed9E · reinvestor 0x5D82381aEA8431e0B8c6fa0bAE0F2F42cA6Be6D2 (second pass) · round 1 LIVE: token 0xc0E2efA7062FA68D4F35c0C14aB84Fd978f3bae2 · controller 0xa1b5345BEdA4A1484aD25cc90831c9AE854391d3 · hook 0x18e5dc1A9E225810C08e04cE9F94731E052ceA88 · staker 0x8B3aD041bE10141099FD07dEE4546dF30D184377 · registry 0xf01182D5B5Ec194fb59605fe4800145F265BDEf1 · timings 2h predeposit / 1h vest / 10-mix wallet cap · on-chain UI 15,766 bytes via factory.html(). Frontend built from the artifact addresses (frontend/.env.local) and serving locally at http://127.0.0.1:4173 (vite preview). NOTE: sources NOT verified on Basescan (deployer opted out). Chain-level note for future rounds: on Base Sepolia, detonate()'s composed spawn leg may exceed the cap — it now degrades gracefully (nextRound=0; finish with reserveSpawn + 3× birthStep).

2026-09-03 (II) — PLAYTEST FIX ROUND + REDEPLOY III (Base Sepolia, uncapped, 2h clock): three playtest reports triaged. (1) "genesis pepe nothing staked / no flows" = UI ABI BUG: lib/abi.ts declared a phantom 6th `actionTime` output on positions() (the field died with governance in the clock redesign) — decode failed, the stake page dropped every position. On-chain was healthy (deployer pepe held the full stake + 28.98 mix pending at inspection). ABI fixed to the real 5 outputs; rebuilt. (2) "only one ladder slot per multi-PSP buy" = SEMANTIC CHANGE (scoopy): ladder seats are now per WHOLE PSP bought (min(wholePSP, 10) — board is 10 wide, overflow evicts it anyway; fractional remainders earn nothing; per-seat amounts = buy/wholePSP). (3) "timer over 72h" = fixed 72h DET_WINDOW + a curve minting millions of whole PSP per buy re-capped the clock to its ceiling on EVERY trade — the countdown never moved. DET_WINDOW is now TUNABLE: timing pack is 4x64-bit ([0] predeposit, [1] vest, [2] det window seconds, [3] wallet cap; cap slot moved 170→192) — hook decodes slot [2] at construction, 0 = 72h default; PSP_DET_SEC env knob (testnet default 2h). PLUS: genesis pooled buy now routes a 10% pre-wave fee INTO THE LADDER POT (GENESIS_POT_FEE_BPS; hook.creditGenesisPot folded into initializeCurve's 3rd arg for EIP-170 bytes; boot 90% seeds the curve; initialPSP computed post-fee). CHART FIX: useRound's live price fell back to the LEGACY ZONE getMarginalPrice on any sine-load hiccup — on sine rounds that number is ~11,000x the wave price and dragged the you-are-here marker off-scale; the zone view is REMOVED from the hook, live price now reads sinePriceAt(reserve) directly. UI: clock panel shows the REAL pot (potBalance) with a separate curve-reserves line; you-are-here marker rides sinePriceAt. GATES: forge 374/375 — the 1 failure is test_B4a_buyBoundedByIntegral_fuzz, a PRE-EXISTING latent CurveMath shave-loop edge (verified failing on the untouched pre-change tree via git stash; persisted counterexample: P0=1.745e14, in=2.593e12, supply=3.92e14 → +1.14% over the +20bps bound) — NOT from this round's changes; flagged for a numerics pass. EIP-170: HookInitCode back under the 500B margin after the additions. no-governance gate clean. REDEPLOY III LANDED (Base Sepolia, ONCHAIN EXECUTION COMPLETE & SUCCESSFUL): factory 0x01B4A9de95f1D83d8059161BC2b67FD45De1EEa9 · mixETH 0xE863fBB04AB1cBc4eC1095153AbB7F6C51bbc5b0 · faucet 0xa503D1fCa6c607c1C10ab995D4ff7508Ce207448 · zapIn 0x40851c37A32dA513f06ebee63e62c7FdF7867ce7 · zapOut 0x10CefA92a691B6587539bDF7F54614FC4EaEFAAd · reinvestor 0x6cBE065C48d94eF9da440ae5FA7915535D84149b · round 1: PREDEPOSIT mode, detWindow=7200s (2h) VERIFIED on-chain, PREDEPOSIT_CAP_PER_WALLET=0 (uncapped) VERIFIED. UI rebuilt from the artifact addresses, serving http://127.0.0.1:4173 (hard-refresh — bundle hash changed).

2026-09-03 (IV) — UI PLAYTEST-FIX ROUND (frontend only, no contract changes): (1) CHART FIXED — lib/sine.ts rewritten for the indefinite sine: the old sampler read the retired 12-field sineCurve getter + getSineCheckpoints (both gone) → loadSineCurve always failed → sine: null → the chart fell back to the STASHED ZONE curve shape ("looks like the old curves") and the you-are-here marker never drew ("no trades yet" after trades). New sampler: reads the 11-field getter, samples sinePriceAt over ~110 points across [0, target + one wavelength], landmarks at boot + every wave seam + the target tread; supply via trapezoid ∫dR/P anchored q0 at boot. abi.ts sineCurve getter updated to the 11-field shape, getSineCheckpoints dropped. (2) "NO TRADES YET" GATE FIXED — hasTrades was tape.count > 0 and the getLogs lane was returning zero rows on the public RPC; now ALSO true when ticketCount > 0 (useLadderBoard reads hook.ticketCount per poll — buys and the chart can never disagree again). (3) LADDER SEAT LABELS — per-whole-PSP seats put ~10 near-identical rows per buy and the old React key (addr-pspWad-ts) COLLIDED across seats minted in the same tx+second (duplicate keys → React rendered repeated/garbled rows, the "1,2,3,…,7,8,9,7,8,9…" sequence). Keys now unique per seat index; each row labels its ABSOLUTE ticket number (ticketCount − depth) instead of a repeating #rank, so multi-seat buys read as the distinct tickets they are. (4) FEES "EARNED THIS ROUND" MADE HONEST — FeeAccumulator's extrapolated drip (windowed rate × capped elapsed) ticked ABOVE the chain's real pending, so a claim paid less than the number on screen; the counter now shows the LAST REAL pendingFeesOf reading and moves only when the chain moves (claims reset it; no invented liveness). The multiclaim button and the counter now read the same Σ pendingFeesOf source. (5) "AVERAGE FEE" ADDED — the trade page shows the sliding sine fee at the live reserve (trade fee: X.XX% — 10% pre-wave → 2.5% past the target), read from swapFeeBps in the 4s lane; split breakdown in the tooltip. ALSO: useRound dropped the dead getMarginalPrice read (zone view removed from the hook); example.env documents PSP_DET_SEC. GATES: pnpm build green (tsc + vite); bundle verified: deploy-IV factory address present, sinePriceAt + swapFeeBps present, getSineCheckpoints/actionTime absent; preview serving http://127.0.0.1:4173. Forge suite state carried from (II): 374/375 (B4a pre-existing documented).

2026-09-03 (V) — DETONATE-BUTTON MISWIRING FIXED + REDEPLOY TRIGGERED: the play page's DetonateButton called detonate() on the HOOK (0xb03f…aa88) — the function lives on the CONTROLLER (0x69cab9…AEa19); the hook has no such function → the tx burned 22,531 gas reverting at entry (tx 0x368fee…e6ac). Root cause: hookAbi carried a stale detonate() entry and DetonateButton wired round.hook. FIXES: DetonateButton → round.controller + controllerAbi; controllerAbi rebuilt (detonate + Detonated event added; the retired governance surface — proposeCarpetBomb/voteCarpetBomb/carpetBomb/finalizeCarpet/getCarpetBombState/currentProposal/lastVotedPepeOn/VOTE_DURATION/FLAT_EXIT_WINDOW/QUORUM_BIPS/MAJORITY_BIPS + the three governance events — dropped from the ABI; CarpetBombCard.tsx deleted, no consumers); hookAbi detonate entry removed. ALSO in this round: lib/sine.ts rewritten for the indefinite sine (the old sampler read the retired getter + checkpoints → sine: null → the chart fell back to the stashed zone curve and "no trades yet" persisted after trades); hasTrades now ALSO rides hook.ticketCount (the getLogs tape was returning zero rows on public RPC); ladder seat keys made unique per seat index and rows label their ABSOLUTE ticket number (ticketCount − depth) — per-whole-PSP seats had collided the old addr-amount-ts React keys into duplicates; FeeAccumulator made HONEST (the extrapolated drip ticked above real pending — a claim paid less than on screen; now shows the last real pendingFeesOf reading, moves only when the chain moves); "trade fee: X.XX%" line added under the chart (sliding sine fee, live from swapFeeBps). GATES: pnpm build green; bundle verified (deploy-IV factory ✓ sinePriceAt ✓ swapFeeBps ✓ getSineCheckpoints gone ✓ actionTime gone ✓ hook-detonate gone ✓); live replay CONFIRMS detonate() SUCCEEDS on the controller (clock past zero, mode Active). CONTROLLER DETONATION PENDING — awaiting scoopy's re-click on the refreshed UI.

2026-09-03 (VI) — LADDER BOARD STABILITY + UI POLISH: useLadderBoard rewritten with stale-while-revalidate (a failed seat read now keeps the previous data instead of flashing empty; the board never goes blank between polls). useSeatPepes rewritten with a module-level address-keyed DNA cache — pepe avatars are keyed by buyer ADDRESS (stable across board shifts), not seat index (which shifted and put the wrong pepe on the wrong row). PotBoard seat keys now include the seat index to guarantee uniqueness. ALSO: DetonateButton gas hardcoded at 14M (Base Sepolia's operator cap is ≈16.78M and the wallet's default estimate exceeded it — the user had to manually lower gas to get the detonate through). SpawnRoundPanel mounted on the play page (post-detonation): fires reserveSpawn + birthRound as two under-cap txs for the permissionless rebirth. PostRound moved off the play page to the Graveyard route (#/graveyard) with a nav link — the play page now redirects there post-detonation. GATES: forge 367/367 (50 suites); pnpm build green; preview serving.

2026-09-03 (VII) — INDEFINITE SINE LAUNCHED ON BASE SEPOLIA (deploy V): the most critical fix was the lnArg cap — MAX_EXP_ARG (1.353e38 = 135.3 real) was mistakenly applied to ln(pTarget/B) = ln(600) = 6.4 (a LOG RATIO, not an EXP argument), which rejected the entire 600× design trend. The cap was removed (lnWad handles any positive input). Deploy V: factory 0x190B91d6… · round 1 Predeposit · detWindow 7200 (2h) · wallet cap 0 (uncapped) · genesis birthSteps completed via CompleteGenesis.s.sol after the deploy script's broadcast stopped at 9/16 (the reserveGenesis struct call was too complex for the cast encoder — completed manually via a dedicated script). All UI reads verified: p(10k) = 0.06 ✓ detWindow = 7200 ✓ walletCap = 0 ✓. Deployed addresses: mixETH 0x3D550C46… · faucet 0xb691f2A1… · zapIn 0xb96B52A8… · zapOut 0xfca5Ca43… · reinvestor not yet deployed for this factory. UI serving at 4173 with deploy-V addresses.


## 2026-09-05 — mixETH ladder units and audit hardening (testnet scope)

User-approved rules: minimum gross buy/public predeposit 0.005 mixETH; one
ladder ticket and 260 seconds (4m20s) per whole purchase unit, with the existing
clock cap. Only the last ten units remain seated. No deployment or broadcast
was performed by this work; pre-existing dirty work and deployment artifacts
were preserved. Existing contracts require a fresh deployment to receive fixes.

Final verified gates on the working tree:

- `forge test --no-match-path 'test/integration/*'`: **384 passed, 0 failed,
  0 skipped, 53 suites**. solc 0.8.26 / Cancun / via-IR / optimizer 200;
  Foundry 1.5.1. Stateful real-V4 handler: **64 runs / 2,048 calls / 0 reverts**.
- Added independent Decimal/Simpson vectors and curve inverse / roundtrip /
  wave and cell boundary properties, real V4 two-round settlement/rebirth,
  donation/empty-ladder cases, reinvest authorization/batches, exact initcode
  shard identity, fee-dust conservation and unauthorized top-up theft/forfeit pins.
- `python3 scripts/sine_oracle.py --check`: independent 90-vector artifact matches.
- Governance grep: pass. Frontend ABI gate: **102 functions/events**, including
  decoded event field names and exact PoolKey encoding. Frontend: **9 tests pass**;
  `tsc -b` and Vite production build pass (existing large-chunk/dependency warnings).
- Runtime/initcode sizes: CurveHook **22,961 / 24,547** bytes; PSPFactory
  **20,324 / 27,266**; HookDeployer **2,183 / 28,174**; HookInitCode **876 / 25,864**.
  All **32 production artifacts** pass the size gate. Experimental
  VectorPepeDescriptor remains excluded and nondeployable at 181,095 runtime bytes.
  Constructor arguments still require deployment-level size checks.
- Fresh production-only Slither snapshot: **233 findings** (9 High / 48 Medium /
  65 Low / 109 Informational / 2 Optimization), inventoried and triaged in
  `docs/audit/STATIC-ANALYSIS.md`; this is not a clean static-analysis certification.
- `git diff --check`: pass. Authenticated mainnet fork check previously returned
  HTTP 401 and is deferred per the user's instruction to stay on testnet.

Audit packet: `docs/audit/READINESS.md`. Notable source fixes include conservative
sine inversion and continuous wave endpoints, bounded legacy over-mint fallback,
ceil-budgeted staker fee credits (AUD-12), paying NFT owners rather than donors
on permissionless top-ups and protecting against forced forfeiture (AUD-13),
reinvestor authorization/reentrancy, capped-gas detonation, immutable initcode
shards, confirmed transaction handling, old-round enumeration/claims, and deployed
rule compatibility checks. Human review and a fresh verified testnet deployment
remain required before treating the updated application as a released build.

## 2026-09-05 — approved testnet readiness follow-up

- Earned staking fees now survive vesting and failed payouts; genesis claims
  preserve remaining owners' credit. Sparse fee-epoch index, fractional carry,
  explicit epoch-zero withdrawal flag, shared reentrancy guard, bounded global
  catch-up, mature cancellation and early-flat schedule cleanup have regressions.
- Supported custom sine inputs are bounded; zero derived slope/growth/supply is
  rejected. Existing defaults and the 90-vector independent oracle are unchanged.
- Old-round UI exits validate their own registry entry and targets. Unclaimed
  genesis positions and fee-bearing withdrawn husks remain accessible.
- Deterministic gate: **397 Solidity tests / 55 suites**, 0 failed, 0 skipped;
  **12 frontend tests**, ABI **102** declarations, oracle/governance/TypeScript/Vite
  pass. Both real-V4 handlers passed 64 runs × 32 calls, zero reverts.
- Extended MultiOwnerStateful campaign: **256 runs × 128 = 32,768 calls**, zero
  reverts, with all positions withdrawn and all supply redeemed after each run.
  Guarded no-ops are included; the deterministic action sequence separately
  requires each action counter to be nonzero.
- Sizes: CurveHook runtime/init **23,117 / 24,703**; PSPFactory **20,442 / 27,384**;
  HookDeployer **2,183 / 28,330**; HookInitCode **876 / 26,020**. All **32** production
  artifacts pass; the existing experimental VectorPepeDescriptor remains excluded.
- Fresh isolated Slither compilation: **234 classifications** (9 High, 53 Medium,
  60 Low, 110 Informational, 2 Optimization), manually triaged in STATIC-ANALYSIS.md.
  Contract-source SHA256: `044015bd5b1cf380460b62472c6460a954e1098e8337d8ff33b6900eacbaeffd`.
- Base Sepolia fork deployment dry-run passed against the canonical real V4 PM,
  staged birth, current descriptor and read-only on-chain testnet record. Estimated
  total gas 67,509,357 across transactions; estimated cost 0.000742602927 test ETH.
- Economic scenarios record reward recapture and profitable unchallenged pot
  takeover; see TESTNET-PLAYTEST.md. No economic/MEV immunity is claimed.
- Legacy keeper commands now fail closed. Mainnet fork remains deferred by user
  direction. Live deployment/source verification evidence is recorded separately.

Release packaging follow-up: fresh npm lockfile/install, ABI 102 / frontend 12 /
TypeScript / Vite rechecked. Patched axios/ws/uuid dependencies; npm advisory
scan has zero high/critical findings and 16 moderate propagated entries from one
remaining decoder advisory (DEPENDENCIES.md). Reinvestor controls check the
wrapper's staker against the current round before approval or compounding. No
Solidity source changed after the contract-source hash above.

## 2026-09-05 — Fresh Base Sepolia release and browser handoff

- Final `bash scripts/check-audit.sh`: **397 Solidity tests / 55 suites**,
  zero failed/skipped; **17 frontend tests**, zero failed/cancelled; **103 ABI
  declarations**, **32** production size checks, **90** independent oracle
  vectors, no-governance, TypeScript and Vite all pass.
- Deployed factory **0xc79b74dacf99a82f1b1e847948338f9263913a59** on chain
  **84532**. Deployment **16/16** receipts succeeded; second-pass reinvestor
  **1/1** succeeded. Largest deployment receipt: **8,500,463 gas**. Public receipt
  records, pinned manifest and source-verification responses are under
  `docs/audit/deployments/base-sepolia-2026-09-05*`.
- Source verification: **17/17** creation/runtime matches through Sourcify v2.
  The build uses `bytecodeHash=none`; these are `match`, not metadata-backed
  `exact_match`. Manifest construction verifies the immutable hook data shards
  concatenate to the local CurveHook creation artifact byte-for-byte.
- `BaseSepoliaReleaseTest` passes at pinned block **46412314**, using the actual
  deployed contracts and real canonical V4 PoolManager. Two-wallet predeposit,
  launch, partial genesis claims, buy/sell, retained vesting fees, actual deployed
  reinvestor, capped detonation, three-step successor birth, minimum-size round-2
  launch, and old-round withdrawals/redemptions/pot claims all pass. **1 test**,
  zero failures/skips; aggregate test gas **26,183,543** (many transactions, not
  a single transaction's required gas). Execution is local fork only.
- Complete exit leaves **one wei of unallocated genesis PSP** in the two-wallet
  case. User-owned positions all exit; this bounded pro-rata rounding residue
  and its tiny fee/backing share are documented in FEE-ACCOUNTING.md.
- Browser checks: correct fresh factory/round, two-hour pre-launch clock,
  predeposit/faucet onboarding, browser-wallet selector, staking and empty
  graveyard. Fixed getter tuple decoding, inactive sine cache, stale ladder/
  referral/vesting copy, prelaunch legacy chart fallback, and account-change
  read clearing. No wallet connection, signature or live user play transaction
  was performed. Browser account/chain switches and transaction rejection remain
  explicitly assigned to the user playtest.
- Publicnode throttling was observed during concurrent fork/browser checks.
  The frontend now uses Base's public Sepolia endpoint with batched/deduplicated
  reads, capped batch size and request timeouts. Reversed-response, per-item
  revert and stalled-request regressions pass; public endpoint availability is
  still an external dependency.
- Protocol source hash remains
  `044015bd5b1cf380460b62472c6460a954e1098e8337d8ff33b6900eacbaeffd`.
  The manifest pins `a35228a3`; later changes affect frontend, tests and release
  records only. Historical broadcast files remain preserved outside the source
  commit. Testnet only; mainnet fork/deployment remains deferred by user direction.

## 2026-09-05 — Live playtest RPC overload and chart recovery

- Reproduced the user's post-launch failure: public Base Sepolia RPC responses
  reported `over rate limit`. Direct reads confirmed minimum **0.005 mixETH**,
  time unit **260 seconds**, Active mode and valid materialized sine geometry.
  The approval simulation succeeded when the node responded.
- Removed the chart's 100+ per-point RPC calls and repeated failed scans. Display
  geometry now uses locally sampled on-chain coefficients; corrected the old
  post-boot supply WAD/unit error. Quotes and minOut still use contract views.
- Cached immutable registry/constructor data per round, retrying failed reads.
  RPC failures no longer turn into cached game-rule mismatches. Real mismatches
  still reject; fresh pinned-block validation and simulation remain before writes.
- View reads aggregate through Multicall3. JSON-RPC batching, bounded timeouts,
  concurrent deduplication and a second public provider support reads and
  simulations. Activity logs start at factory creation, advance in <=1000-block
  pages, retain a 12-block reorg overlap, and avoid overlapping full-history polls.
- Browser: active curve renders, no rules-error banner, and a **0.005 mixETH**
  input quotes **56.646 PSP**, one seat and **4m20s**. Read-only live verification
  at block **46415448** passed the pinned preflight and approval simulation. Four
  concurrent live view reads used **one HTTP/RPC call**. No transaction was sent.
- `bash scripts/check-audit.sh`: **397 Solidity tests / 55 suites**, **26 frontend
  tests**, **103 ABI declarations**, **32** production size checks, oracle and
  no-governance gates, TypeScript and Vite all pass. New regressions cover metadata
  recovery/caching, real mismatches, error classification, chart supply/price,
  bounded/reorg-safe log reads, Multicall3 response mapping and provider fallback.
- Deployed contracts and addresses are unchanged. Refresh previously open wallet
  browser tabs to load the new build. Public RPC availability remains external;
  wallet-signed buying is left to the user's playtest.

## 2026-09-05 — Add PSP to an existing NFT position

- Each current-round pepe card now has an expandable **+ add PSP** form with
  wallet balance, exact-decimal Max and amount validation. Uses the deployed
  `stakeFor(owner, pepeId, amount)` path, retaining the NFT and its existing stake.
  Zero-stake owned pepes can also be funded; no purchase minimum applies to PSP
  staking. Deployed contracts and addresses are unchanged.
- Fresh ownership, balance, allowance, withdrawal and round-state checks run
  before approval and again after its successful receipt. Approval is limited
  to the entered PSP amount and the round's staker. Wallet/network changes or
  an unmounted position stop the second step. Shared simulation, deployment-rule
  verification and confirmed-receipt handling apply to both writes.
- Position reads use the explicit `isWithdrawing` getter, including epoch-zero
  requests. Withdrawal must be cancelled before a top-up; dead rounds reject it.
  Confirmed actions refresh wallet/position reads immediately without clearing
  the cards during that refresh. Duplicate top-up clicks are guarded.
- `bash scripts/check-audit.sh`: **397 Solidity tests / 55 suites**, **34 frontend
  tests**, **104 ABI declarations**, **32** production size checks, independent
  oracle and no-governance gates, TypeScript and Vite all pass. Eight new frontend
  tests cover exact amounts, approval sequencing, stale state/session changes,
  failure propagation and rejected inputs. Existing Solidity top-up fee-entitlement,
  donor fee-theft protection and withdrawal-request regressions remain green.
- Browser: the actual form component was exercised in an isolated local fixture
  at a 300px card width. Exact Max fill/submission, over-balance and negative-input
  rejection, and a disabled withdrawing position behaved correctly. The rebuilt
  real staking page loads. No wallet signature or on-chain top-up was performed;
  that remains in the user's testnet playtest sequence.

## 2026-09-05 — Curve guide cleanup and trade fee estimates

- Removed wave-marker vertical dashes/labels and the hover crosshair. The live
  reserve marker is the only dotted vertical guide; hover points/tooltips, axis
  grids and the user's horizontal entry-price marker remain.
- Buy/sell cards show an estimated trade fee in mixETH and percent, with explicit
  after-fee receive amounts and separate network-gas copy. Quote, fee rate and
  mode read through one Multicall3 snapshot. Input/direction changes invalidate
  the previous display; polling cannot overlap itself and backs off on failures.
- Buy fees use exact integer gross-input math. Sell estimates reconstruct fees
  from the net contract quote, with an upper rounding error of one wei across
  250–1000 bps; no second fee is deducted from output or minOut. Flat sells read
  the contract's pro-rata quote and show zero trade fees.
- Browser checks caught the previously missing `swapFeeBps()` frontend ABI
  declaration, which also hid the rate footer. Added it and normalized the uint24
  result. Snapshot tests now use the production ABI. The footer appears only in
  Active mode and accounts for unattributed referral/deployer routing.
- Live read-only browser checks: **0.005 mixETH buy → 13.7014 PSP**, estimated
  **0.000428 mixETH** fee at **8.56%**; **100 PSP sell → 0.0305 mixETH** after fees,
  estimated **0.00285601 mixETH** fee. Inspected the cleaned chart and fee panel;
  no browser warnings/errors. Quotes are examples at the checked live state,
  not fixed prices. No wallet write was submitted.
- `bash scripts/check-audit.sh`: **397 Solidity tests / 55 suites**, **40 frontend
  tests**, **105 ABI declarations**, **32** production size checks, independent
  oracle and no-governance gates, TypeScript and Vite pass. Six new regressions
  cover buy/sell fee math, flat/inactive states and complete quote snapshots.
  Final footer copy also passes TypeScript/Vite. No contracts were changed.

## 2026-09-05 — AUD-14 reinvestment buyer attribution, source validation

- Confirmed live at Base Sepolia block **46416798**: all ten ladder seats named
  the old reinvestor `0x7328d580df5d234f5d904f1b0fb1d631f26213f6`. Restaking itself
  credited the correct NFT, but `buyWithMix` forwarded its contract caller into
  hookData. This also misattributed Buy/TimeAdded and skipped the NFT owner's
  recorded referral chain. Pot claims on those seats belong to the immutable old
  wrapper, which has no forwarding claim method. Existing seats cannot be edited.
- Added `PSPZapIn.buyWithMixFor`: the caller pays and receives PSP, while an
  explicit beneficiary receives seats/events and recorded referral payouts.
  Reinvestor passes the NFT owner on single and aggregate buys, including operator
  calls; batch restaking also remains bound to that original owner. No tx.origin
  dependency, new referral binding, victim allowance use, or administrative powers.
- Frontend checks `ATTRIBUTION_VERSION == 1` and current-round staker wiring before
  enabling or approving/calling a reinvestor. Old wrappers fail closed. Rebuilt
  the local UI with this guard during the repair.
- `bash scripts/check-audit.sh`: **404 Solidity tests / 56 suites**, **41 frontend
  tests**, **106 ABI declarations**, **32** production size checks, oracle,
  no-governance, TypeScript and Vite pass. Seven new real-V4 tests cover single/batch
  owner/operator attribution, referral payment, all owned seat payouts, exact caller
  funding, zero beneficiary and preserved slippage/deadline checks. An older
  reinvestment regression now also asserts the seat owner.
- `ReinvestRepairTest` passes on a local fork of block **46416798**, attaching
  the live factory, hook, tokens, staker and canonical V4 PoolManager. Fresh local
  replacement routers support operator single/batch reinvestment and the NFT
  owner's post-detonation pot claim. No transaction is broadcast by this test.
- Fresh production Slither run: **234 findings / 156 contracts / 102 detectors**,
  unchanged detector/severity/confidence counts. Manual delta review and new CSV
  are in STATIC-ANALYSIS.md. Runtime: ZapIn **4032 bytes**, Reinvestor **4687 bytes**.
- Testnet replacement script `RepairReinvestor.s.sol` simulates successfully and
  deploys only those two wrappers. It verifies chain 84532 and the expected current
  round; existing round state and assets stay in their existing contracts. Actual
  replacement addresses and broadcast verification are recorded separately below.

## 2026-09-05 — AUD-14 replacement deployed on Base Sepolia

- Reviewed source revision **796222cd**. Two `--slow` deployment receipts
  succeeded: new ZapIn **0xfbaedab9e2e3ad26827c3cec712520cd56e5d842** at block
  **46416990** (**925,504 gas**); new Reinvestor
  **0x7e5a814b4c7c7d788b20eb90fd7340fa4929f9ae** at block **46416991**
  (**1,151,879 gas**). Factory and round 1 remain unchanged.
- Current manifest at block **46417019** is
  `docs/audit/deployments/base-sepolia-2026-09-05-reinvest-repair.json`. Only those
  two addresses changed; all retained contract code hashes match the original
  manifest. Immutable wiring and stored hook creation code were checked again.
  Companion files record the incident, successful creations and verification.
- Sourcify reports **17/17** creation/runtime matches across the current release,
  including both replacement contracts; `bytecodeHash=none` still means `match`
  rather than metadata-backed `exact_match`.
- The post-deploy **ReinvestRepairTest** passes on the actual deployed code at
  block **46416991**: operator single and batch compounding, NFT-owner ladder
  attribution, unchanged NFT ownership, and owner pot claims after detonation.
  **1 test passed**, zero failures/skips, local fork only. No user's NFT approval,
  reinvestment, buy, or pot claim was broadcast during repair.
- Updated the ignored local frontend configuration to the verified replacement
  addresses and rebuilt successfully. Fresh approvals are required; old tabs must
  refresh. Existing wrong seats and historical events are unchanged. Later buys
  can evict them, but no retrospective claim/seat reassignment exists in old code.
- Read-only frontend preflight at block **46417135** accepts the new wrapper's
  staker/version and rejects the old wrapper. Reloaded the rebuilt staking page;
  live round 1 data loads with no browser warning/error logs. Wallet-signed
  approval/reinvestment remains the user's playtest.

## 2026-09-05 — Stake layout, referral landing and graveyard history

- Moved Hall of Detonations from Stake to Graveyard. It shares the existing
  dead-round enumeration and reads each hook's frozen `potBalance`; it no longer
  treats initial round-id loading as a detonation or displays reserve backing as
  the pot. Old browser-local records remain untouched and are no longer displayed.
  Archive amount failures show unavailable without blocking existing exit reads.
- Referral links now open the explainer. The explainer captures the referral
  hint before navigation; the existing entry-page banner still requires an
  explicit user-signed registry bind. No contract writes were added.
- The six Pepe candidates form two rows of three at all widths. Selection has
  accessible labels/pressed state; refreshing clears selection and rolls six new
  candidates. Sleeping-Pepe styles moved with the archive to the graveyard.
- `bash scripts/check-audit.sh` passes: **404 Solidity tests / 56 suites**,
  **41 frontend tests**, **106 ABI declarations**, **32** production size checks,
  independent oracle, no-governance, TypeScript and Vite. Existing large-chunk
  build warnings remain. No contracts or deployment configuration changed.
- Browser checks confirm the grid, selection, refresh, absence of history on
  Stake, and the correct empty archive on Graveyard for live round 1. An isolated
  preview origin verifies explainer referral capture and the same referral hint
  on Play and Predeposit after navigation; no browser warning/error logs there.
  Populated dead-round history and wallet-signed actions were not browser-tested.

## 2026-09-05 — Animated curve explainer and settlement alignment

- Added an explanatory card after the five beats. Its two repeating S-shaped
  stretches use the normalized default-amplitude tilted-sine formula from
  SineMath, with explicitly labeled illustrative/log-price axes. Green flatter
  zones and amber steeper zones explain percentage-price sensitivity to equal
  mixETH reserve changes. The copy distinguishes relative stability from a fixed
  price and explains that the pattern repeats.
- CSS animation moves a marker through equal reserve increments in equal time,
  then reverses for sells. Pause/play works; reduced-motion CSS leaves a useful
  static frame. No new rAF loop, RPC polling or transaction path was introduced.
- Left-aligned the settlement label, heading and copy. Corrected the buy diagram
  to `0.005 mixETH = 1 ticket` and allowed beat copy to shrink within narrow rows.
- `bash scripts/check-audit.sh` passes: **404 Solidity tests / 56 suites**,
  **41 frontend tests**, **106 ABI declarations**, **32** production size checks,
  independent oracle, no-governance, TypeScript and Vite. Existing bundle-size
  warnings remain; no contract or deployment changes.
- Browser inspection at 1280px and the user's 678px viewport confirms the new
  card, pause/play and left-aligned settlement; every main section fits its
  container at 678px. No browser warning/error logs. Temporary viewport reset.
  Separate pre-existing issue observed: the header's clock/faucet/theme/connect
  group extends beyond the 678px viewport; this change does not alter the header.

## 2026-09-05 — Matching swap/ladder heights and purchase shortcuts

- Removed the swap column's self-start override so SwapCard and PotBoard stretch
  to the same grid-row height when side by side. The submit action remains at
  the bottom; stacked layouts keep their natural content heights.
- The arrow is now a keyboard-accessible buy/sell button. Both tabs and the
  arrow share direction-change behavior that clears the prior token amount,
  quote and error. Pending transactions lock direction, amount and balance-fill
  controls; predeposit, flat and halted mode restrictions also apply to the arrow.
- Added `buy 1 ladder spot`, visible during an active round. It selects Buy and
  fills `wadToExact(MIN_BUY_INPUT)` (0.005 mixETH); it never submits a transaction.
  Existing quotes, fee estimates, slippage, allowance and confirmed-write flows
  remain in use. The one-ticket caption now correctly reads `1 seat`.
- `bash scripts/check-audit.sh` passes: **404 Solidity tests / 56 suites**,
  **41 frontend tests**, **106 ABI declarations**, **32** production size checks,
  independent oracle and no-governance. TypeScript/Vite pass again after the final
  singular/plural copy adjustment. Existing bundle-size warnings remain.
- At the user's 1266px viewport, both populated panels measured **699.328125px**
  tall with identical top/bottom bounds after the one-seat quote loaded. Browser
  checks cover the exact 0.005 input, 1 seat/+4:20, fee/minimum-output estimates,
  mouse and Enter direction switches, and switching a filled Sell form to the
  one-seat Buy preset. No browser warning/error logs; viewport restored. No
  wallet-signed transactions or contract/deployment changes in this update.

## 2026-09-05 — Compact staking page composition

- Grouped the identity/fee overview and referrals/.wei on the left, with the
  six-Pepe picker and staking form together on the right. CSS grid lets the
  creation flow span both overview/support rows; it no longer leaves most of
  the right column empty. Existing owned positions span the page below both
  columns, retaining all top-up, claim, reinvest and withdrawal controls.
- Mobile retains source order: overview, picker/form, referrals, then owned
  positions. Added min-width constraints for the columns and amount input.
  No staking, approval, ownership, read or transaction logic changed.
- `bash scripts/check-audit.sh` passes: **404 Solidity tests / 56 suites**,
  **41 frontend tests**, **106 ABI declarations**, **32** production size checks,
  independent oracle, no-governance, TypeScript and Vite. Existing bundle-size
  warnings remain.
- Browser checked the compact two-column composition at **1266px** and the
  single-column order at **678px**. Pepe selection remains connected to the
  staking form across responsive changes; no browser warning/error logs.
  Viewport restored. Connected-wallet position actions were not browser-tested
  for this layout-only change; no contract or deployment update was needed.

## 2026-09-05 — Wallet Pepe identity and avatar containment

- Connected wallet buttons now resolve the current-round primary NFT, verify
  ownership, and display its on-chain artwork. Wallets without a position use
  the same deterministic address-to-DNA mapping as the ladder; casing, reloads
  and rounds do not change fallback DNA. Account/round keys and effect cleanup
  prevent a previous identity from appearing after the wallet changes.
- Recheck ownership every six seconds, with bounded backoff on RPC failures.
  Cache only renderer/DNA artwork; newly minted/transferred positions are picked
  up by subsequent reads. Renderer failures retain the owned DNA and retry.
- Set the account button to 36px high with a centered, clipped 24px avatar.
  The existing wallet account-modal callback remains in use.
- `bash scripts/check-audit.sh` passes: **404 Solidity tests / 56 suites**,
  **47 frontend tests**, **106 ABI declarations**, **32** production size checks,
  independent oracle and no-governance. All 47 frontend tests and TypeScript/Vite
  pass again after the final presentation cleanup. Existing bundle-size warnings
  remain. Six new tests cover deterministic identity, NFT precedence, transfers,
  cache separation and RPC retries. No contracts or deployments changed.
- Read-only Base Sepolia validation resolves wallet `0x1d52…d88A` to its owned
  NFT #1 and renderer SVG. Browser inspection of the actual button component,
  rendered in a temporary fixture with that artwork and two address fallbacks,
  confirms each 24×24 SVG stays inside its 36px button. Fixture removed afterward;
  connected-wallet modal interaction was not exercised in this check.

## 2026-09-05 — Swap spacing, aligned token marks and expanding curve range

- Token badges use flex alignment so mixETH and PSP icons share the text's
  vertical center in both swap directions. Enlarged pay/receive panels and
  amount typography; the panels absorb spare card height while the action and
  fee/slippage details follow directly below. Swap/ladder still match heights.
- Cache the immutable sine coefficients, extending local samples when reserves
  approach the existing endpoint. Keep at least one wavelength, 1,000 mixETH or
  10% of reserve ahead, rounded to a whole wave. Sampling is bounded to 8,192
  post-boot steps; extension requires no new RPC calls. The chart's existing
  linear/log and price/supply scales consume the expanded geometry.
- Log ticks stay bounded and retain the highest tick; scientific notation
  keeps large price labels inside the chart. The live marker remains the only
  dotted vertical guide. No quote, transaction, contract or deployment changes.
- `bash scripts/check-audit.sh` passes: **404 Solidity tests / 56 suites**,
  **50 frontend tests**, **106 ABI declarations**, **32** production size checks,
  independent oracle and no-governance. All 50 frontend tests and TypeScript/Vite
  pass again after final tick/label adjustments. Existing bundle warnings remain.
  New regressions cover range growth at 10,001/20,000/50,000/100,000 mixETH,
  preservation of earlier geometry/supply, and bounded ordered axis ticks.
- Browser checks at 1266px: token/text center offsets are exactly zero in Buy
  and Sell; unfilled Swap and Ladder both measure 687.109375px high, with pay
  and receive panels measuring 192px and 189.609375px. The 0.005 one-seat shortcut,
  fee/minimum-output quote and stacked 678px layout remain usable.
- A temporary interactive fixture of the actual chart component checked 20,000
  and 100,000 mixETH ranges, including log/linear and supply views. Paths remain
  finite and live marker centers stay inside the plot. Fixture/server removed;
  viewport restored. These were simulated chart reserves, not testnet purchases.

## 2026-09-05 — Pepe identity in the wallet account modal

- Registered `WalletPepeAvatar` through RainbowKitProvider's supported `avatar`
  prop. The modal shares the header's `useWalletPepe` NFT/owner lookup and stable
  address fallback; it replaces RainbowKit's default emoji avatar. Existing
  clipping styles respect the size supplied by RainbowKit.
- `bash scripts/check-audit.sh` passes: **404 Solidity tests / 56 suites**,
  **50 frontend tests**, **106 ABI declarations**, **32** production size checks,
  independent oracle, no-governance, TypeScript and Vite. Existing bundle-size
  warnings remain; no contract or deployment changes.
- Browser verification used the actual RainbowKit account modal in a temporary
  fixture with a mock connection and live read-only NFT lookup for `0x1d52…d88A`.
  The header and modal contain identical NFT SVG artwork, sized 24px and 74px
  respectively, with matching SVG bounds and circular clipping. Close works;
  balance, copy-address and disconnect controls remain present. No wallet was
  signed or connected on the user's behalf. Fixture and server removed.

## 2026-09-05 — Fee counter right padding

- FeeAccumulator sizes its number against the actual column width and formatted
  character count, capped at 36px. It retains all displayed digits and reserves
  8px right padding; the loading skeleton is also constrained to the column.
  Fee values, formatting precision and claim/reinvest behavior are unchanged.
- Browser checked the actual counter component at 186px, 300px and 560px content
  widths with `0.00076112`, `123.456789` and `1,234,567.123456`. Every number fits;
  the screenshot's value leaves 16.640625px after its last digit at 186px, inside
  the card's existing padding. Temporary preview files/server removed.
- `bash scripts/check-audit.sh` passes: **404 Solidity tests / 56 suites**,
  **50 frontend tests**, **106 ABI declarations**, **32** production size checks,
  independent oracle, no-governance, TypeScript and Vite. Existing bundle-size
  warnings remain. No contract or deployment changes.

## 2026-09-05 — External mixETH yield explainer beat

- Added `01 · backed by mixETH` ahead of launch and renumbered the narrative to
  `one round, six beats`. The copy explains Alchemix's ETH ERC-4626 vault token
  and how external strategy yield can increase ETH backing per mixETH share;
  PSP accounting remains in mixETH. The testnet row explicitly identifies mock
  mixETH as having no real yield, with a link to Alchemix's documentation.
- Added a matching CSS diagram using the existing mixETH token mark, yield
  particle and rising ETH-per-share backing indicator. Reduced-motion users
  receive a static frame; no new JavaScript animation loop or chain reads.
- Source checks: Alchemix's [documentation](https://docs.alchemix.fi/?fallback=true)
  describes yield accruing in MYT redemption value; its
  [v3 introduction](https://alchemixfi.medium.com/introducing-alchemix-v3-d55f86d35b49)
  identifies the Morpho V2 / ERC-4626 implementation. Testnet behavior follows
  `src/testnet/SepoliaMixETH.sol` and the readiness packet.
- `bash scripts/check-audit.sh` passes: **404 Solidity tests / 56 suites**,
  **50 frontend tests**, **106 ABI declarations**, **32** production size checks,
  independent oracle, no-governance, TypeScript and Vite. Existing bundle-size
  warnings remain. Browser inspection confirms the six rows, diagram, copy,
  source link and testnet note at 1266px and 678px; viewport restored.
  No contract or deployment changes.


## 2026-09-05 — Current testnet frontend hosted on here.now

- Installed the official `heredotnow/skill` here-now skill globally for Codex.
  Local npm/npx failed before installation; the skill-installer git method
  succeeded. Reviewed the current here.now docs and bundled publishing script.
- Published frontend revision `f208da28` to
  <https://devoted-truffle-ydjx.here.now/> with SPA routing: 208 static assets,
  6,180,068 bytes. The finalize response identifies anonymous hosting, initially
  expiring 2026-09-06 at 12:08:17 UTC; claiming the site can make it permanent.
  Claim credentials remain in ignored local state and the publishing conversation.
- The bundle retains Base Sepolia 84532, the existing factory, the AUD-14 repaired
  ZapIn/Reinvestor, and both public RPC endpoints. Only `frontend/dist` was
  uploaded; no environment files, private keys, broadcast files or source maps.
  See `docs/audit/deployments/herenow-2026-09-05.json` for source/version/hash data.
- `bash scripts/check-audit.sh` passes: **404 Solidity tests / 56 suites**,
  **50 frontend tests**, **106 ABI declarations**, **32** production size checks,
  independent oracle, no-governance, TypeScript and Vite. Existing bundle warnings
  remain. Hosted entry JavaScript and CSS match local SHA-256 hashes; here.now
  adds only social preview metadata to the HTML.
- Browser verified live round 1, ladder, curve and reserves; the 0.005 mixETH
  preset produces a one-seat / +4:20 quote with fee and minimum-output estimates.
  Wallet connection modal, staking artwork and the six-beat explainer render.
  This was a disconnected-browser check; no wallet signing or chain writes.


## 2026-09-05 — Plain-language explainer copy

- Rewrote the hero, six explanatory rows, curve description, fee/payout table,
  slider labels and redemption section in direct everyday language. The page
  leads with the last ten tickets sharing the pot, and uses concrete 0.005 / 0.05
  mixETH examples for seats and capped clock additions.
- Preserved the fee split, smaller-ladder weighting, mixETH accounting, external
  yield explanation, 0% yield practice-token note and redemption-value caveat.
  Copy replaces negation, rhetorical questions and contract/API jargon with
  affirmative descriptions. Animation, pricing and transaction logic are unchanged.
- `bash scripts/check-audit.sh` passes: **404 Solidity tests / 56 suites**,
  **50 frontend tests**, **106 ABI declarations**, **32** production size checks,
  independent oracle, no-governance, TypeScript and Vite. Existing bundle warnings
  remain. Browser reviewed the rendered copy at 1280px and 678px; a scoped text
  check finds none of the removed negation/jargon phrases. Viewport restored.
- Rebuild is available locally. The update to existing here.now site
  `devoted-truffle-ydjx` was rejected before upload with `Unauthorized. Use
  Authorization: Bearer <apiKey>`. The user chose to keep this as a temporary local
  UI update. The hosting manifest describes the earlier published revision.


## 2026-09-05 — Memetic explainer headline

- Replaced the explainer headline with “get in, loser. we’re taking the pot.”
  The supporting game explanation and redemption-value disclosure remain intact.
  The rebuilt local preview displays the headline correctly at desktop width.
- `bash scripts/check-audit.sh` passes: **404 Solidity tests / 56 suites**,
  **50 frontend tests**, **106 ABI declarations**, **32** production size checks,
  independent oracle, no-governance, TypeScript and Vite. Existing bundle warnings
  remain. This is a local UI update per the current publishing preference.


## 2026-09-05 — Site-wide copy with a little edge

- Extended the explainer's voice through play, staking, referrals, predeposit,
  graveyard and footer copy. Examples include “choose your accomplice”, “the tape
  keeps receipts” and “the graveyard is waiting for its first customer”. Financial
  amounts, fee estimates, action eligibility and transaction behavior are unchanged.
- Corrected stale descriptions of testnet reserve yield, empty-ladder pot routing,
  remaining-reserve redemption, genesis staking and carried-forward staking fees.
  The rewards counter now says “unclaimed trading fees”, matching its actual chain
  reading and claim resets. An already-recorded referral no longer displays an
  incoming link's pepe ID as if it were the wallet's existing referrer.
- `bash scripts/check-audit.sh` passes: **404 Solidity tests / 56 suites**,
  **50 frontend tests**, **106 ABI declarations**, **32** production size checks,
  independent oracle, no-governance, TypeScript and Vite. Final wording and picker
  wrapping refinements also pass TypeScript/Vite and `git diff --check`.
  Existing bundle warnings remain.
- Browser reviewed the local explainer, loaded play ladder, staking, predeposit
  and empty graveyard; staking copy also checked at 678px. Conditional claim,
  withdrawal and post-round text was checked against source. Viewport restored;
  no wallet transactions. The rebuilt preview is local only; the existing here.now
  publication and contracts remain unchanged.


## 2026-09-06 — Atomic purchase referrals and immutable round attribution (AUD-15)

- Added per-round registry `buyWithMix(key, mixIn, minPspOut, deadline, referrerNftId)`.
  The caller's signed purchase records an eligible incoming referral before fee
  routing, pays it on that first purchase and credits the buyer with output/seats.
  The callback transfers input straight to V4 and output straight to the buyer;
  a context hash, PoolManager check and reentrancy guard protect standing allowances.
  Failed buys roll back attribution. Invalid/self/cyclic links emit ReferralSkipped
  and keep the slot open while the purchase proceeds. No delegated recorder was added.
- Fixed payout entry resolution: a wallet's recorded referral wins over acquired or
  changed primary NFTs. Receiving a referred NFT cannot silently attribute a wallet;
  a new owner cannot rewrite an existing NFT ancestry edge. Referring-NFT transfers
  still carry income to the new owner. Direct V4 beneficiary hints remain untrusted,
  cannot bind victims, and are not a claim of identity enforcement across all routers.
- Frontend captures scoped links at the router root, persists by chain/registry,
  passes the referral in the purchase, checks compatibility before approvals/writes,
  and removes the separate confirm-referral transaction. A fresh allowance read
  targets the actual purchase spender. Legacy, stale-round and unreadable referral
  targets fail closed; ordinary legacy zap buys remain available without a pending
  referral. Link sharing is disabled for legacy registries. See
  docs/audit/REFERRALS.md for UX and deployment details.
- `bash scripts/check-audit.sh` passes: **426 Solidity tests / 57 suites**,
  **60 frontend tests**, **110 ABI declarations**, **32** production size checks,
  independent oracle, no-governance, TypeScript and Vite. Added **22 real-V4 referral
  tests**, including a 256-run immutability fuzz, and **10 frontend referral tests**.
  Registry runtime: **5,990 bytes**; ControllerDeployer: **22,622 bytes**.
  Existing bundle warnings remain. Final source-only comment clarifications and
  audit documentation do not change the tested executable logic. Final frontend
  compatibility and request-state refinements also pass all 60 frontend tests and
  TypeScript/Vite.
- The first full gate exposed an obsolete combined-birth gas assumption in the
  34-zone canary: composed rebirth now costs **17,499,292 gas**. The release has
  required three birthStep transactions since AUD-3. The canary retains the composed
  measurement, restores the same reservation and proves each split call under a
  stricter **12M gas** cap: **8,454,668 / 8,829,672 / 212,591 gas**. The test does not
  increase the old per-transaction limit; it verifies the actual release path.
- Browser checked explainer-to-play capture and reload persistence on the isolated
  localhost preview origin; the legacy deployment notice appears and there is no
  referral confirmation button. No wallet transactions or live deployments were
  performed. Existing Base Sepolia contracts are immutable, including the registry
  creation code used by that factory's future rounds. This feature needs a fresh
  factory/round deployment; current balances, NFTs and recorded referrals are intact.


## 2026-09-06 — Graveyard winners accordion

- Each round in the hall of detonations now expands into its final winners list.
  Rows group a wallet's winning seats and show its Pepe, seat ranks, share and
  total mixETH prize. Each avatar reads that round's staker and current primary
  NFT; wallets without one use the existing deterministic address Pepe. The UI
  labels this as current artwork, rather than a snapshot of NFT ownership at death.
- Read the settled hook's frozen pot and occupied final board on expansion.
  Amounts include prizes already claimed and sum individually floored seat payouts,
  matching claimPot. Failed or partial reads offer retry and cannot become a false
  empty/renormalized winners list. Existing exit controls remain independently usable.
- Added eight frontend regressions covering canonical shares, repeated wallets,
  per-seat rounding, short/empty ladders, bounded final-ten reads, failed reads,
  active-round rejection and separation between round hooks.
- `bash scripts/check-audit.sh` passes: **426 Solidity tests / 57 suites**,
  **68 frontend tests**, **111 ABI declarations**, **32** production size checks,
  independent oracle, no-governance, TypeScript and Vite. Existing bundle warnings
  remain. `git diff --check` passes.
- Browser checked the real Base Sepolia round-1 winner with on-chain Pepe artwork,
  accordion open/close, and 320px, 390px, 678px and desktop layouts. Its ten-seat
  prize of 126.526653601617144074 mixETH matches claimablePot at the read snapshot.
  Viewport restored. Local preview rebuilt; no wallet transactions or contract
  deployments are required for this UI change.

## 2026-09-06 — Skill-guided security hardening (AUD-16 through AUD-21)

- Baseline `926e4b46`. Used the installed Pashov/Simao accounting and contract
  review references with Trail of Bits differential, variant, token integration
  and property-testing methods. Review scope, incomplete delegated passes and
  human-audit limits are explicit in `docs/audit/2026-09-06-hardening/REVIEW.md`.
- Reproduced and fixed sparse referral payout truncation, early canonical
  staker CREATE2 interference, premature canonical pool initialization,
  unbounded fresh-ID scans, epoch-zero withdrawal view inconsistency, and
  owner-wide referral qualification scans vulnerable to unsolicited empty NFTs.
- Added eleven tests: real-V4 birth/payout regressions, randomized five-tier
  ownership, independent occupied-ID modeling, bounded gas, uint256 edge IDs,
  epoch-zero exits and partial genesis/top-up/transfer/withdrawal accounting.
  Extended the existing multi-owner invariant with independent owner-principal sums.
- Final `bash scripts/check-audit.sh`: **437 Solidity tests / 60 suites**,
  **68 frontend tests**, **111 ABI declarations**, **32 production size checks**,
  independent oracle, no-governance, TypeScript and Vite; all pass. Existing
  bundle warnings remain. `git diff --check` passes for reviewed changes.
- Extended three-wallet campaign: **256 runs / 32,768 handler calls / zero
  reverts**, with complete exits and the updated accounting invariant. Calls
  include permitted no-ops; the deterministic companion exercises every action.
- Fresh isolated production build and Slither 0.11.6: 158 contracts / 102
  detectors / 242 flags (10 High, 52 Medium, 63 Low, 115 Informational,
  2 Optimization). Flags are triaged rather than claimed as vulnerabilities.
  Source SHA-256: `7279ecbaa4cbf13648cc68faa3a1561fab50a4ef69cd54d9836a103224f75a4d`.
  ERC method/event checks also confirm incomplete position-NFT standard support.
- Game rules, economics and current frontend flow remain unchanged. Full ERC-721
  safe-transfer and individual-approval support is a separate proposal awaiting
  the user's decision. No contracts were deployed and no wallet transactions
  were sent. Existing deployments require fresh contracts to receive these fixes;
  their balances, NFTs, history and creation code remain unchanged.

## 2026-09-06 — Approved NFT safe transfers and individual approvals

- Implements the user's explicit approval of NFT-INTERFACE-PROPOSAL: both safe
  transfer overloads, approve/getApproved/Approval, metadata interface, zero-owner
  balance rejection and per-token approval clearing on all transfers. Position
  principal, accrued fees and withdrawal state follow the owner. OpenZeppelin
  receiver checks execute after state changes under the shared financial guard.
- Individual approvals also authorize fee claims and scoped reinvestor calls.
  Every batched NFT requires the same owner and caller authorization. Withdrawal
  management stays owner-only; approval-for-all remains available; no NFT burn or
  safe-mint change. Unknown IDs revert; descriptor-free NFTs return an empty URI.
- UI single/batch reinvestment uses individual permissions on upgraded stakers,
  verifies each receipt and rechecks wallet/ownership/approvals between prompts.
  Position controls offer safe transfer with recipient review and individual or
  reinvestor collection revocation. Capability failures stay disabled; legacy
  rounds retain their explicitly labeled approval-for-all flow. NFT management
  binds to a registered round independently of current trade rules.
- `bash scripts/check-audit.sh`: **450/450 Solidity tests, 61 suites**;
  **77/77 frontend tests**, **119 ABI declarations**, **32 production size checks**;
  oracle, governance, TypeScript/Vite all pass. New 256-case transfer fuzz executes
  32 transfers/approvals per case with independent ownership and principal totals.
  Existing real-V4 stateful campaigns pass with 64 runs / 2,048 calls and zero reverts.
- Initial gate failures resolved: a new test had sampled fees before the automatic
  payout in requestWithdraw; reordered the actual actions to generate fees during
  withdrawal and prove they follow transfer. Historical composed-birth gas canary
  now records 12,623,711 / 12,616,411 gas and validates the supported split path
  under the unchanged stricter 12M per-call cap: 6,155,471 / 6,276,997 / 189,213 gas.
  Variance/reservation checks remain. No production gas cap was raised.
- Production-only static build: Slither 0.11.6, 160 contracts, 102 detectors;
  **243 flags** (10 High / 52 Medium / 64 Low / 115 Info / 2 Opt). The sole added
  low flag is the <=64-item reinvestment permission read loop; manually reviewed.
  ERC-721 checker passes every required function and event/index check. Staker
  runtime **13,133**, StakerDeployer **14,352**, Reinvestor **4,786** bytes; other
  production budgets remain green. See docs/audit/2026-09-06-nft-interface/REVIEW.md.
- Browser checked new transfer review and revocation controls with a local mock
  wallet fixture, plus the legacy notice; rebuilt local stake page remains usable.
  Temporary fixture removed and TypeScript/Vite rebuilt. No live signatures,
  transactions or deployment occurred. Requires new factory/deployers and a
  second-pass reinvestor; the existing testnet NFTs remain unchanged.
- Source SHA-256 (sorted src/**/*.sol path + NUL + contents):
  `8f27c8742190b1a86456e62fd1f5a373dd2b7ef26c2d71214530056e4b5d44a9`.

## 2026-09-06 — WNS naming source and local-fork rehearsal

- Baseline `8523fb44`. Added `PSPNameRegistrar`, parent custody/recovery/record
  management, and a same-chain factory/NFT/principal eligibility gate. Free
  registration for positive-principal NFT owners; otherwise exactly 0.0005 native
  ETH. Names persist across rounds and are user-owned WNS NFTs. Additional
  one-name/one-free-NFT-claim restrictions remain a pending user policy choice.
- Commit/reveal hides labels for at least 60 seconds; commitments bind wallet,
  destination, parent, label and secret, and expire after 24 hours. Availability
  checks prevent public use of WNS's parent overwrite power. Gate/parent changes,
  callback reentry, receiver forwarding and exact fees have regression coverage.
- UI persists commitment secrets before submission, finds funded NFTs across all
  rounds, validates deployment/fee/custody at one block, checks receipts, and
  requires fee review if qualification changes. Header, tape and ladder use
  forward-verified owned WNS names, bounded typography and address fallbacks.
- Final `bash scripts/check-audit.sh`: **472 Solidity tests / 64 suites**,
  **94 frontend tests**, **144 ABI declarations**, **34 production size checks**;
  independent oracle, governance, TypeScript and Vite pass. The full via-IR rebuild
  took 792.45 seconds. Existing dependency-annotation and bundle-size warnings
  remain. An initial property test exceeded Foundry's uint64 chain-ID cheatcode
  domain; its generator was corrected to uint64 and the complete property passes.
- Four canonical WNS fork tests pass at Ethereum block **25,915,356**, runtime hash
  `0x5b791c832d4373a8d4f977c37d6973a5dbe0924c6d287a2effaa549be31c0221`.
  They cover approval-only rejection, actual free/paid name registration, automatic
  app mapping, resolution, renewal and recovery through parent expiry. Publicnode
  denied a later archive read; the full pinned run passed through eth.drpc.org.
  Real WNS parent custody remains with the user; no mainnet transaction was sent.
- Slither 0.11.6: 104 contracts / 102 detectors / **252 flags** (10 High, 58 Medium,
  66 Low, 116 Informational, 2 Optimization). The nine new entries are triaged in
  docs/audit/2026-09-06-names/REVIEW.md. Runtime/initcode bytes:
  **PSPNameRegistrar 8,499 / 9,438**; **PSPStakeNameGate 1,200 / 1,354**.
- Browser checked the rebuilt stake card and a transaction-disabled long-name
  fixture on desktop and 390px mobile. Header/feed/ladder names remain contained;
  mobile content width is 390px, account button 174px. Temporary fixture/server
  removed and viewport restored. No injected-wallet name transaction was tested.
- Real hybrid registration remains disabled. WNS is on Ethereum while current PSP
  is on Base Sepolia; an owner-run permit verifier requires the user's trust-model
  decision and further implementation/review. The deployed game is unchanged.
  DeployNames is explicitly a 31337 fork-rehearsal script and leaves custody with
  the admin until a separate transfer. See docs/audit/NAMES.md for admin calls,
  source/API observations, the two parent manifests and remaining release work.
- Source SHA-256 (sorted src/**/*.sol path + NUL + contents):
  `82ec707f2f2a86a1ba5700b40d9272a549ace78e71138a35cee3d98744af8340`.

## 2026-09-06 — Approved remote WNS eligibility verifier

- Baseline `35c53afd`. User approved the owner-run verifier; retain the original
  funded-NFT rule without adding per-wallet/per-NFT free-name caps. Added
  PSPRemoteNameGate, EIP-712 permits, dedicated signer/rotation, registrar version
  2 with monotonic commit nonce, bounded Node HTTP service, source/destination UI
  separation, deployment script and local two-fork end-to-end rehearsal.
- Permits bind source chain/factory, destination chain/gate/registrar, wallet,
  name commitment/nonce, parent/gate/signer epochs, round/NFT and finalized source
  block/hash. Maximum 180 seconds. Finalized and latest NFT ownership/principal
  must agree; stale/reorganized blocks fail issuance. Invalid proof reverts rather
  than changing a free transaction into a paid one. Requests require no additional
  user wallet signature beyond the existing on-chain commitment.
- Final `bash scripts/check-audit.sh`: **482 Solidity tests / 65 suites**,
  **98 frontend tests**, **11 verifier tests**, **151 ABI declarations**,
  **35 production size checks**; independent oracle, governance, TypeScript/Vite
  pass. Verifier tests are now included in the deterministic gate.
- Four canonical WNS fork tests pass. Full HTTP/two-fork rehearsal uses actual PSP
  factory/staker storage at Base Sepolia **46,417,019** and canonical Ethereum WNS
  at **25,915,356**; local mining supplies simulated fresh/finalized blocks.
  Free and exact 0.0005-ETH mints, verified display, consumed-permit rejection and
  parent recovery pass. Gas: free **258,923**, paid **247,073**. An initial live
  read correctly quoted paid because the test wallet's positions currently hold
  no principal; the free rehearsal uses the older funded snapshot, not altered
  eligibility or live balances.
- Focused Slither naming closure: **28 contracts / 102 detectors / 13 flags**
  (8 Medium, 4 Low, 1 Informational). Four added flags are deliberate timestamp
  expiry, zero-signer revocation and ignored diagnostics/commit-age projection;
  triaged in docs/audit/2026-09-06-remote-names/REVIEW.md. Missing build-info blocked
  an initial cached run; an isolated naming-only build succeeded without cleaning
  shared artifacts. This is not a new whole-game static campaign.
- Runtime/initcode bytes: registrar **8,588 / 9,527**; remote gate **3,977 / 4,789**.
  Full source SHA-256 (sorted path + NUL + contents):
  `77848d96cb74f958c49d803e00a1852557c7b804a28d5d9aeaff4ffc0afe9e42`.
- A dedicated, unfunded permit signer was generated outside the repo; only its
  public address appears in preparation records. Ethereum deployment simulation
  passed: **3,922,741** estimated gas at the sampled price (about **0.000658 ETH**,
  excluding parent transfer/activation). No live transaction was broadcast, and
  neither real domain moved. Mainnet deployment/custody activation and service
  startup remain required before enabling the name UI. Current PSP contracts,
  balances and unrelated broadcast files are preserved.

## 2026-09-06 — Exact predeposit amounts and removal of its minimum

- Baseline `ae9bc79e`. User explicitly removed the individual predeposit minimum.
  Public direct/on-behalf deposits now accept any positive amount within the
  existing global and beneficiary wallet caps; active curve buys still require
  0.005 mixETH. Cap overshoots revert without partial acceptance. New controller
  capability version 1 lets the frontend retain the actual floor on old rounds.
- Both predeposit forms display exact totals and remaining headroom. MAX respects
  balance and both caps with bigint arithmetic. Expiry permits further top-ups
  until launch, matching existing contract behavior. Read-only simulation of the
  current deployed controller confirmed its 100,000,000-wei remainder is rejected
  with `PurchaseTooSmall()`. Fresh factory/controllers are required for the fix.
- `bash scripts/check-audit.sh`: **491 Solidity tests / 66 suites**, **104 frontend
  tests**, **11 verifier tests**, **152 ABI declarations**, **35 production size
  checks**. Independent oracle, governance and TypeScript/Vite pass. Stateful
  invariants retain 64 runs / 2,048 calls with zero reverts. Existing compiler,
  dependency-annotation and bundle-size warnings remain.
- Nine added Solidity tests cover positive sub-minimum amounts, zero rejection,
  global/wallet dust completion, on-behalf/ETH-zap deposits and pooled claims with
  real V4 and production sine parameters. Six frontend tests cover exact decimal
  round-tripping, both caps/balance, legacy capability and 512 small boundaries.
  A whole one-wei pool is numerically unrepresentable: launch reverts atomically,
  stays open, and a post-window top-up permits launch. Existing math guards stay.
- Browser checked the rebuilt predeposit and play routes against the actual near-
  full round: `499.9999999999 / 500`, `0.0000000001 mixETH remaining`. Exact labels
  fit a 390px viewport; existing navigation overflow remains outside this patch.
  No wallet-signed transaction or live deployment was performed. See
  `docs/audit/2026-09-06-predeposit.md` for root cause, variants and release boundary.
- Source SHA-256 (sorted src/**/*.sol path + NUL + contents):
  `c1d8fe5ab84e7ba670b31b4dc964324a8cbdbd2dd6e9437769e9dab99b581b20`.

## 2026-09-06 — Wallet-derived genesis art and per-round DNA uniqueness

- Baseline `8808f3fb`. User requested wallet-matched predeposit NFTs and explicitly
  required unique DNA within each round. Genesis claims now prefer the padded
  wallet-address hash used by the wallet avatar. Every mint reserves the canonical
  eight-trait v2 combination, including high-bit/modulo aliases. Chosen duplicates
  revert; automatic/genesis collisions receive the first free combination through
  a bounded occupied-run allocator. Art and its reservation survive transfers,
  top-ups, reinvestment and withdrawal. Exhaustion of all 100M combinations reverts.
- `bash scripts/check-audit.sh`: **502 Solidity tests / 67 suites**, **107 frontend
  tests**, **11 verifier tests**, **155 ABI declarations**, **36 production size
  checks**. Independent oracle, governance, TypeScript and Vite pass. Existing
  compiler, dependency-annotation and bundle-size warnings remain. Final log:
  `/tmp/psp-wallet-dna-audit-gate-final.log` (exit 0).
- Eleven added Solidity tests cover matching frontend hash vectors, claim order
  across rounds, real collision IDs 4046/5249, preferred-ID squatting, zero DNA,
  transfer/withdrawal retention, bounded collision lookup, automatic fallback,
  independent production-decoder agreement, mixed-mint uniqueness and an
  independent occupied-set model. Existing accounting tests now resolve actual
  genesis NFT IDs instead of assuming sequential IDs. Three added frontend tests
  pin the hashes, collision-preview/owned-DNA transition and compact ID labels.
- The initial complete gate passed 500 tests and failed the stale composed-birth
  14M gas canary (minimum sample 14,570,501). The release script already uses three
  birth transactions. The revised canary checks those calls under explicit
  10M / 10M / 2M gas budgets and retains 30M composed containment. Production gas
  limits are unchanged. NFT-ID/art-run claim tests now allow 450K instead of 300K
  for added art-reservation writes. Runtime/initcode bytes: PSPStaker
  **14,243 / 14,609**, StakerDeployer **15,467 / 15,493**.
- Picker availability checks reject occupied art before approval; minted position
  cards read assigned DNA. Wallet, feed and ladder art share queries scoped by
  chain/staker/wallet and poll ownership. Long NFT IDs use compact labels while
  transaction/referral values retain full precision. Browser smoke-checked the
  rebuilt disconnected stake picker and play route against the existing testnet;
  this does not exercise fresh-contract claims or a wallet-signed transaction.
- Fresh factory/staker deployment is required, including for future rounds:
  existing factories embed the old creation code. Current testnet balances, NFTs,
  contracts and unrelated broadcast files are unchanged. No live transaction or
  domain operation was performed. Scope, codec limits and collision behavior:
  `docs/audit/2026-09-06-wallet-dna.md`.
- Source SHA-256 (sorted src/**/*.sol path + NUL + contents):
  `0175b88cf9ad42c52c6ccc6e08b52b28ac78bb2568f33d8393c9c6aa3f762021`.

## 2026-09-06 — Prominent predeposit countdown

- Replaced the small header chip with a full-width countdown panel using the
  existing seven-segment font, up to 104px digits. Separate time-unit labels,
  optional days and an elapsed-window label retain the actual predeposit timing
  and shared PhaseEngine heartbeat. Contract and transaction logic are unchanged.
- Deterministic gate passes: **502 Solidity tests / 67 suites**, **107 frontend
  tests**, **11 verifier tests**, **155 ABI declarations**, **36 production size
  checks**, oracle/governance and TypeScript/Vite. Final responsive font adjustment
  also passes TypeScript/Vite. No new tests were added for this presentation change.
- Browser checked desktop and 390px/320px widths against the current elapsed
  predeposit window. Final 320px timer width/scrollWidth both measure 220px;
  digits fit their 68px columns. Viewport override restored. Existing mobile
  navigation overflow remains outside this change. No wallet transaction occurred.

## 2026-09-06 — Spawn visibility and current-round play state

- Baseline `2605bffa`. The play page treated any historical dead round as current
  settlement. It kept offering to spawn round 2 after round 2 existed and selected
  round 1's ladder beside round 2's clock. Current-round ID/hook now determine
  settlement, spawn eligibility, the board and claim data. A completed local spawn
  hides immediately; stale round-read errors suppress the action until recovery.
- The local detonation receipt is scoped by round ID. Detonate, spawn and claim
  controls reset with their contract/round targets. Board stale-data merging is
  restricted to the same hook. The existing pre-write factory check remains;
  checking disables repeat clicks and a backwards round mismatch stops the flow.
  Partial births retain the existing reservation/three-step resume behavior.
- `bash scripts/check-audit.sh`: **502 Solidity tests / 67 suites**, **112 frontend
  tests**, **11 verifier tests**, **155 ABI declarations**, **36 production size
  checks**, oracle/governance and TypeScript/Vite pass. Five new frontend tests
  cover successor predeposit/active, subsequent detonation, delayed readers,
  matching claim targets, unknown state and RPC recovery. Existing warnings remain.
- Browser verified the rebuilt localhost play page on the actual active round 2:
  no spawn panel or stale round-1 banner, current live ladder/payouts match the
  55.25-mixETH pot. No wallet transaction or contract deployment occurred. This
  frontend fix works with the current testnet. Review and bounded variant search:
  `docs/audit/2026-09-06-round-ui-state.md`.

## 2026-09-06 — Landing manifesto and matching illustrations

- Rebuilt the explainer around the user's approved anti-meme copy: public pooled
  entry, the sine curve, staking fees, clock/ladder competition, NFT positions,
  external mixETH yield, settlement and permissionless respawn. Removed the
  rejected loss-value sentence. Kept the explicit practice-mixETH / 0% testnet
  yield note, exact ticket/time/fee rules, payout slider and rounding description.
- Eight CSS/SVG illustrations follow those sections in a responsive two-column
  layout. The detailed curve opens below the rules and reuses the same normalized
  sine geometry as the story thumbnail. A shared pause control and reduced-motion
  static frames cover all illustrations. The real clock still uses PhaseEngine.
- `bash scripts/check-audit.sh` passes: **502 Solidity tests / 67 suites**, **112
  frontend tests**, **11 verifier tests**, **155 ABI declarations**, **36 production
  size checks**, oracle/governance and TypeScript/Vite. A final copy/accessibility
  cleanup also passes TypeScript/Vite. Existing bundle-size warnings remain.
- Browser checked eight story sections at 1266px, 390px and 320px, with no story
  or landing-content horizontal overflow. Verified animation pause and the
  expandable curve. At 320px the landing client/scroll widths both equal 288px.
  Restored the viewport override. No new tests for this presentation-only change.
- Updated the local preview build only. Game contracts, transaction behavior,
  deployment configuration, hosted here.now sites and broadcast files are untouched.

## 2026-09-06 — Pepe resurrection and landing copy refinements

- Applied the requested "anti memecoin, memecoin" headline and exact new intro,
  including italic emphasis on "new". Added continued public settlement/respawn
  copy scoped to immutable deployed round code, with existing factory controls
  for future curves/art, stored UI and pending reservations stated in the rules.
- Replaced the respawn chart with a CSS sequence using the existing rendered pepe:
  fall/grayscale, rising ghost, RIP grave, then revival. The shared pause control
  covers it. Reduced motion shows the grave and living pepe together with an arrow.
- Deterministic gate passes: **502 Solidity tests / 67 suites**, **112 frontend
  tests**, **11 verifier tests**, **155 ABI declarations**, **36 production size
  checks**, oracle/governance and TypeScript/Vite. Final wording adjustment also
  passes TypeScript/Vite. Existing bundle-size warnings remain.
- Browser inspected grave/ghost and revival frames and the longer headline at
  826px and 320px. Narrow landing and headline client/scroll widths both equal
  288px. Viewport override restored and the local preview rebuilt. No new tests
  for this presentation change. No contract, transaction or hosted-site changes.

## 2026-09-06 — Mobile header and navigation

- Replaced the crowded header below 1280px with a burger disclosure. Wallet access
  stays visible; navigation, the round clock, theme choices and testnet faucet
  move into a height-bounded scrollable menu. Expanded state/controls, Escape
  focus restoration, outside-pointer/focus dismissal, route closing and desktop
  resize closing are implemented. Hidden navigation is removed from keyboard flow.
- Mobile controls have 44px touch targets. Connected wallet names are bounded and
  truncated within the pepe button. The desktop header has enough room for its
  controls, and the predeposit link now preserves the graveyard link as well.
- Browser found an additional 8px play-page overflow in the slippage presets and
  custom input. That group now wraps; quote, slippage and transaction logic are
  unchanged. No page-wide overflow clipping was added.
- Deterministic gate passes: **502 Solidity tests / 67 suites**, **112 frontend
  tests**, **11 verifier tests**, **155 ABI declarations**, **36 production size
  checks**, oracle/governance and TypeScript/Vite. The final one-line swap layout
  adjustment also passes TypeScript/Vite. Existing bundle warnings remain.
- Browser checked the five routes at 320px with document width equal to viewport
  width, plus menu open/closed, navigation dismissal, outside dismissal, wallet
  chooser access and resize to the desktop header. Landing/play headers and
  documents measure 1280px at the desktop breakpoint. Viewport override restored.
  Connected-account and wrong-network states were reviewed in code, not exercised
  with a signed-in wallet. No wallet transaction, deployment or hosted-site update.

## 2026-09-06 — Random respawn pepes and PSP gravestone

- Replaced the grave's cross with PSP beneath RIP. Respawn starts with independent
  random artwork and rerolls between the ghost fading and the next pepe rising.
  The NFT illustration also gets its own random pepe instead of sharing the hero.
- Rerolls follow the existing CSS animation cycle, including its pause and reduced
  motion rules. No extra timer or animation-frame loop was introduced.
- Deterministic gate passes: **502 Solidity tests / 67 suites**, **112 frontend
  tests**, **11 verifier tests**, **155 ABI declarations**, **36 production size
  checks**, oracle/governance and TypeScript/Vite. Existing bundle warnings remain.
- Browser verified RIP / PSP, changing respawn artwork across cycles, and stable
  artwork while paused. Local preview rebuilt. No new tests for this presentation
  change, contract changes or hosted-site update.

## 2026-09-06 — Remove illustration playback toggle

- Removed the landing page pause/play button, its React state and unused pause
  styles. Illustrations play automatically; system reduced-motion support remains.
- Deterministic gate passes: **502 Solidity tests / 67 suites**, **112 frontend
  tests**, **11 verifier tests**, **155 ABI declarations**, **36 production size
  checks**, oracle/governance and TypeScript/Vite. Existing bundle warnings remain.
- Rebuilt and refreshed the local preview. Browser confirms the toggle is absent
  and the respawn animation is running. No new tests for this presentation change.

## 2026-09-06 — Carpet-bomb countdown title

- Added a pixel-font heading above the play clock. Active rounds identify the
  latest buyer from the existing ladder's first seat, using the shared verified
  subdomain lookup with an "anon pepe" fallback. "carpet bombing" is emphasized.
  The identity uses the clock's green, yellow or red phase with a subtle glow.
- Predeposit and settled states say "awaiting arming of carpet bomb". Long names
  can wrap, and no extra game polling or animation loop was introduced.
- Deterministic gate passes: **502 Solidity tests / 67 suites**, **112 frontend
  tests**, **11 verifier tests**, **155 ABI declarations**, **36 production size
  checks**, oracle/governance and TypeScript/Vite. Existing bundle warnings remain.
- Browser checked the current settled round at regular and 320px widths. The
  heading uses Geist Pixel, and page width equals viewport width on mobile.
  Active identity and phase branches were reviewed in source; no live round was
  spawned for this UI check. Local preview rebuilt and viewport restored.
