# PSP Trait Studio

A zero-dependency browser editor for Pepe trait grids. Edit 48×48 slot-grid
traits, compose live previews, and export **byte-exact** artifacts for the
repo (`script/traits/*.txt`, `script/traits/palettes.py`, `src/PepeArtData.sol`).

## Run it

Easiest — open the pre-built single file:

    open studio/dist/trait-studio.html        # works from file://, no server

Or serve the modular sources (picks up edits without rebuilding):

    python3 -m http.server 8777 studio/src    # then http://localhost:8777

Rebuild the single-file dist after changing anything in `src/`:

    python3 studio/tools/build_inline.py      # → studio/dist/trait-studio.html

## Layout

- `studio/src/index.html` + `app.css` — shell + dark/pepe-green theme
- `app-core.js` — state, localStorage autosave (`psp-trait-studio-v1`), undo/redo
  (150 steps, per trait), trait ops with DNA-shift warnings, validation, modals,
  DNA codec (3/3/4/4/4/3/3/4 bits), compose, Web-Crypto self-test
- `app-canvas.js` — 48×48 editor: pencil/eraser/fill/line/rect/eyedropper,
  mirror-X, ghost base-head underlay (α slider), grid toggle, cell-size slider,
  checker/dark canvas backgrounds
- `app-panels.js` — axis tabs, trait list (add/dup/rename/delete/move), palette
  dock (16 resolved slots), live preview (1×/2×/4×/10×, skin/iris/bg, RANDOM,
  PNG download), validation panel, status bar
- `app-dialogs.js` — Compile modal (sha256 vs `GOLDEN_SHA`), PALETTES editor,
  Import (`.txt` + `palettes.json`), Export Files, session restore
- `app-boot.js` — keyboard shortcuts + init
- `../compiler.js`, `defaults.js` — shared byte-exact compiler (DO NOT EDIT —
  pinned to golden sha `963b1862…8ce72d` by `test_compiler.mjs`)

## Daily loop

1. Pick an axis tab, pick (or + New / Duplicate) a trait.
2. Paint on the full 48×48 grid — the compiler auto-crops on export, so
   position art where it composites correctly (use the ghost underlay).
3. Watch LIVE PREVIEW; RANDOM to sanity-check combos across the palette set.
4. **Export Files** → drop the generated `traits/*.txt` + `palettes.py` into
   `script/` (or compile → copy `PepeArtData.sol` into `src/`).
5. **▶ Compile** shows the sha; green ✓ = identical to the repo golden build.

Edits autosave to localStorage (per browser). On load you'll be offered
*Restore* (continue editing) or *Use defaults* (discard). ⋯ menu → wipe saved
state.

## Shortcuts

`B` pencil · `E` eraser · `G` fill · `L` line · `R` rect · `I` eyedropper ·
`M` mirror-X · `Cmd/Ctrl+Z` undo · `Shift+Z` / `Y` redo · `Esc` close modal ·
double-click trait row to rename. Tool keys are ignored while typing in inputs.

## Guarantees

- The **Self-Test** button (and auto-run at load, badge in the status bar)
  compiles the embedded defaults through the same compiler chain and compares
  sha256 to the golden `PepeArtData.sol`. Badge must read `✓ self-test passed`.
- `node studio/test_compiler.mjs` is the CLI referee — run it after touching
  anything compiler-adjacent.
- Deleting/moving traits shifts on-chain DNA ids; the validation panel warns
  and the export log lists every id shift so you can re-audit old dna values.

## What NOT to edit

`compiler.js`, `test_compiler.mjs`, `spec/**` — they are the contract.
The app is vanilla JS/CSS with no build step, no network, no frameworks.
