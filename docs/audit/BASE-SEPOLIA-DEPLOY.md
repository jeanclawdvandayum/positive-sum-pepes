# Fresh Base Sepolia deployment

Run from the repository root with Node 22, Foundry (`forge`, `cast`, `anvil`),
Python 3.11+, and the installed root/frontend dependencies. Chain ID is **84532**.
The runner pins the canonical PoolManager to
`0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`.

The September 7 live release completed from `c724d124`. See
[the current playtest](TESTNET-PLAYTEST.md) for its addresses and verification.
Use this procedure for future releases. Actual results belong in `GATE-LOG.md`
and the run's output files.

## Profile and rehearsal

[example.env](../../example.env) contains the deployment settings. Preserve an
existing `.env` and review its values before exporting them into your shell:

```sh
cp -n example.env .env
# Edit .env locally.
set -a
source .env
set +a
node scripts/deployment/base-sepolia.mjs --dry-run
```

| Setting | Default |
|---|---|
| Predeposit window | 7,200 seconds, two hours |
| Withdrawal vest | 3,600 seconds, six ten-minute epochs |
| Clock window/cap | 7,200 seconds, two hours |
| Per-wallet predeposit cap | `0`, uncapped |
| Global predeposit cap | 500 mixETH |
| Minimum public predeposit | One wei, within the caps |
| Minimum active gross buy / ladder ticket | 0.005 mixETH |
| Time per complete purchase unit | Up to 260 seconds |

Sine parameters also come from `example.env`. Timing fields use seconds, the
wallet cap uses whole mixETH, and the sine price/reserve inputs use wei/WAD.
`PSP_DEPLOYER_CUT_TO` optionally sets the immutable fee recipient. Its default
is the broadcaster.

The default command, including when `--dry-run` is omitted, creates a disposable
local Anvil fork of Base Sepolia. It runs the audit gate, deploys the factory and
staged genesis locally, deploys the reinvestor in a second pass, inspects the
result, and runs the release lifecycle tests. The local node stops when the
runner exits. Rehearsal addresses and its loopback frontend env are temporary.

## Live release

Review and commit the release inputs before broadcasting. The runner rejects
dirty source, while excluding historical `broadcast/` records. Preserve unrelated
work rather than adding it to a release commit to satisfy this check.

Import a dedicated testnet wallet into an encrypted Foundry keystore and fund
its address with Base Sepolia ETH for gas. Keep its key out of env files:

```sh
cast wallet import psp-testnet --interactive
# Set PSP_DEPLOYER in .env to that wallet's address, then export it.
node scripts/deployment/base-sepolia.mjs --broadcast \
  --account psp-testnet --sender "$PSP_DEPLOYER" --verify
```

`--broadcast` is the explicit live switch. The runner uses the named keystore,
`--slow`, confirmed receipts, and separate broadcast records. It creates fresh
mixETH/faucet, deployers, descriptor, factory, round contracts and routers.
`DeployReinvestor.s.sol` then reads the completed round from the actual chain.
Factory-derived addresses take precedence over simulation predictions.

`--verify` submits public source/build inputs to Sourcify and requires creation
and runtime matches. It uses no explorer API key. The factory's embedded HTML
is the read-only deployment record from `script/testnet-status.html`. The current
keeper remains disabled.

## Outputs and switching the UI

Each run writes a new `out/releases/base-sepolia-<mode>-<timestamp>/` directory.
`--out DIRECTORY` can select another fresh directory outside the repository or
inside an ignored path. Existing output directories are preserved.

- `plan.json`: revision, profile, network snapshot and rehearsal status.
- `broadcast/`, `core-receipts.json`, `reinvestor-receipts.json`: execution records.
- `build-info/`: compiler inputs for source verification.
- `cache/`: isolated Foundry compilation and script recovery cache.
- `anvil-state.json`: saved local rehearsal state for diagnosing failures.
- `manifest.json`: pinned addresses, code hashes, artifact matches, wiring,
  feature versions, rules and the confirmed factory creation block.
- `frontend.env`: separate settings for review. Live exports use public Base
  Sepolia RPCs and derive history's start block from the factory CREATE receipt.
- `audit.log`, `manifest.log`, `release-tests.log`: checks and failure details.
- `verification.json` and `verification.log`: live `--verify` results.
- `result.json`: written when the complete run succeeds.

The runner leaves active frontend env files in place. When ready to switch the
built preview, back up the current frontend settings, review the generated live
export, and copy it into the production override:

```sh
# Set PSP_RELEASE_DIR to the successful live run's directory.
cp "$PSP_RELEASE_DIR/frontend.env" frontend/.env.production.local
npm --prefix frontend run build
```

Review shell `VITE_*` overrides as they take precedence over env files. For Vite
dev mode, apply the same reviewed settings to `.env.local`. Reload the browser
after rebuilding. Old contracts, balances and NFTs remain at their old addresses.

The export leaves `VITE_WC_PROJECT_ID` empty, which enables injected browser
wallets. Add a real WalletConnect project ID to the frontend override to enable
remote/mobile wallet connections. Deployment credentials belong outside the
frontend env and bundle.

Naming has a separate Ethereum release and custody step. This export leaves
`VITE_NAME_REGISTRAR` empty. The remote name gate binds its PSP factory immutably,
so a fresh game factory requires a matching fresh gate and verifier configuration
before registration is enabled. Follow [NAMES.md](NAMES.md) for the gate,
registrar, parent custody and public verifier setup.

## Recovering an interrupted live run

Keep the failed run's receipts and read the factory's current round and reservation
phase from chain state. Running the fresh-release command again creates another
factory. Use the completion scripts when retaining the partial deployment.
Genesis reservation has an explicit 15-million-gas call allowance because its
block-dependent hook mining can differ from simulation. An unlucky block can
still exhaust the bounded search. In that case, keep the factory and retry its
unfinished reservation/completion in a later block.

After the factory, descriptor and sine configuration have landed:

- `CompleteGenesis.s.sol` completes only the unfinished genesis steps. It keeps
  an existing reservation and uses the factory's deployed timing profile.
- `CompleteBaseDeploy.s.sol` also fills missing HTML and router deployment steps.
  Supply confirmed `PSP_ZAPIN` and `PSP_ZAPOUT` addresses to reuse existing routers.
  Omitted router addresses cause new instances to be deployed.

Export `PSP_FACTORY` from its successful CREATE receipt and preserve recovery
receipts in a separate directory. Use the same testnet profile and owner wallet:

```sh
export PSP_TESTNET=true PSP_ANVIL=false PSP_FORK=false
export FOUNDRY_BROADCAST="$PSP_RELEASE_DIR/recovery-broadcast"
export FOUNDRY_CACHE_PATH="$PSP_RELEASE_DIR/recovery-cache"
forge script script/CompleteGenesis.s.sol:CompleteGenesis \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" --chain 84532 \
  --account psp-testnet --sender "$PSP_DEPLOYER" --broadcast --slow \
  --gas-estimate-multiplier 110
```

Use `CompleteBaseDeploy.s.sol:CompleteBaseDeploy` in that command when HTML or
routers also need completion. Read the successful router receipts, then run
`DeployReinvestor.s.sol:DeployReinvestor` separately with `PSP_FACTORY`,
`PSP_ZAPIN`, and `PSP_ROUND=1` set from the completed deployment.

Once all required receipts have succeeded, regenerate the read-only manifest
and frontend export at new output paths:

```sh
export PSP_RPC_URL="$BASE_SEPOLIA_RPC_URL"
# Export PSP_FACTORY_CREATION_TX, PSP_ZAPIN, PSP_ZAPOUT, PSP_FAUCET and
# PSP_REINVESTOR from the successful original/recovery receipts.
node --experimental-strip-types frontend/scripts/deployment-manifest.mjs \
  "$PSP_FACTORY" "$PSP_RELEASE_DIR/recovered-manifest.json" \
  "$PSP_RELEASE_DIR/recovered-frontend.env"
```

Complete deployed-code lifecycle testing and source verification against these
recovered addresses before switching the frontend:

```sh
PSP_RELEASE_TESTNET=true PSP_RELEASE_FRESH=true forge test \
  --match-contract BaseSepoliaReleaseTest --fork-url "$BASE_SEPOLIA_RPC_URL" -vv
node frontend/scripts/verify-sourcify.mjs \
  "$PSP_RELEASE_DIR/recovered-manifest.json" "$PSP_RELEASE_DIR/build-info" \
  "$PSP_RELEASE_DIR/recovered-verification.json"
```

The fresh-feature canary requires untouched round-one predeposits. Its state
changes happen in Forge's local fork. If factory setup failed before
the descriptor or sine configuration landed, inspect that earlier step first.
The completion scripts require that configuration and preserve reserved births.
