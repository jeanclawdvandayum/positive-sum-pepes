# Expanded Pepe art, release 2

Source preparation, September 10, 2026. This release has **not been deployed**.
The current September 9 testnet remains on art version 1.

The Studio export in `studio/expanded` adds Amazing and Rage expressions, Sus
eyes, Fuck My Shit Up hair, Reading Glasses, Unibrow, and Knife. Counts in DNA
order are **12 / 11 / 11 / 12 / 11 / 10 / 10 / 10**, giving **191,664,000 trait
combinations**. Headband, Hoodie and six eyewear stamps also have pixel edits
in this export. The base and palettes match the legacy release.

## Storage and compatibility

`PepeExpandedDescriptor` stores its pixels and metadata names in an immutable
SSTORE2 bytecode contract. Its renderer runtime is 9,470 bytes, initcode is
23,781 bytes, and the STOP-prefixed data contract is 11,731 bytes. Runtime
headroom is 15,106 bytes for the renderer and 12,845 bytes for the current data
store. The generator fails if the data exceeds EIP-170. The standard size gate
also checks renderer runtime and initcode.

The eight 4-bit fields remain unchanged. Each new staker snapshots the
renderer’s `ART_VERSION()` as `PEPE_DNA_VERSION`: legacy descriptors use 1,
expanded descriptors use 2. Canonical keys, fallback art and reservations all
use that version's counts. Distinct IDs with the same normalized trait tuple
revert. Reservations and minted combinations remain occupied after claiming
and transferring the NFT.

The old descriptor, old art library, Studio compiler/golden files and old UI
art JSON remain unchanged. The UI queries each round's staker version, so old
collections and new collections use their own matching pixel data. The
reservation API's `PREDEPOSIT_ART_VERSION == 2` is a separate version from the
renderer version.

**Deploy a fresh factory with the updated staker creation code.** Do not set
this descriptor on a previously deployed factory that still embeds the
version-1-only staker. Its collision codec would disagree with the renderer.
`DeployPSP.s.sol` now deploys the expanded descriptor. The deployment manifest
checks both renderer bytecode and the exact stored art bytes, and source
verification selects the matching descriptor.

## Reproduce

```sh
node script/gen_expanded_art.mjs
node script/expanded-art-fixtures.mjs
forge test --match-contract ExpandedPepeArtTest
bash scripts/check-audit.sh
```

The generator recompiles the text grids with the frozen Studio compiler and
requires exact equality with the exported Solidity. It validates counts,
metadata names, storage size, base and palette compatibility, then writes the
expanded Solidity data and browser JSON. `--check` verifies generated files
without writing. Browser SVG hashes are pinned in the fixture JSON and checked
against both Solidity renderers.

After release 2 is deployed, freeze its inputs and generated outputs. Future
changes need a new art version and retained browser data for prior rounds.
There are 4, 5, 5, 4 and 5 unused slots in the five stamp axes respectively.
The palette axes have six slots each, but expanding them also requires an
updated palette export path. More than 16 entries on an axis requires a new
DNA field layout rather than silently overflowing the current fields.
