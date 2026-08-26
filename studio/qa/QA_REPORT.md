# PSP TRAIT STUDIO — QA REPORT (Agent C, fresh-eyes)

**Date:** 2026-08-20 · **Target:** studio/dist/trait-studio.html (local :8791) + https://oaken-marvel-3e24.here.now/
**Baseline verified pre-test:** node studio/test_compiler.mjs → ALL CHECKS PASSED; golden sha 963b1862…8ce72d matches disk; dist html sha 883aba40…987e1; golden .sol = 8303 bytes on disk (NOT 8299 — see F-bytes note).

## VERDICT: (pending — final at end)

## Findings

### P1-1 (wrong vs spec / major UX): modal action buttons never dismiss the dialog
- Repro: 1) HATS tab → select a trait → Delete → modal appears → click **Delete**. The trait is deleted (state + shift log confirm) but the modal box REMAINS on screen. Same for Move/OK/Cancel/Create/Enter-key on every confirm/prompt dialog (rename, new, move, delete).
- Root cause (source, `PSP.openModal` button wiring): `const r = b.onClick(close, body); if (r === false) return; if (r !== undefined) close(r);` — confirm/prompt handlers are `() => done(true/false)` which return `undefined`, so `close()` is never called. Only ✕, Escape, or backdrop-click dismiss.
- Impact: after every dialog action the user sees a stale dialog ("Swap TINFOIL with CAP?" after the swap already happened). Clicking the stale action button again is a no-op (promise settled) — no double-delete. A second modal opened while one lingers replaces content without decrementing `openModals` → `PSP.modalOpen()` can stay true for the session → all keyboard shortcuts (B/E/G/L/R/I/M/Z) dead until reload (path verified as reachable via topbar buttons + lingering modal; exact leak repro pending Flow 7).
- Evidence: console eval — clicking lingering modal's Delete: `after clicking Delete again: open=true`; after Escape: `open=false, modalOpen()=false`, shortcut L works again.
- Expected (spec): modal closes on action. Actual: lingers until Escape/✕/backdrop.

### P2-1 (polish): dirty-dot tooltip goes stale
- Repro: paint any cell. `#dirty-dot` gets class `dirty` but `title` stays "state matches last export".
- Expected: title should reflect dirty state ("unsaved changes since export" or similar).
- Evidence: `<span id="dirty-dot" title="state matches last export" class="dirty">` (console DOM dump after painting).
- Severity: cosmetic; the visual dot itself toggles correctly.

### Note F-bytes: orchestrator's "file on disk is 8299" is wrong
- `wc -c studio/spec/golden/PepeArtData.sol` = **8303** bytes, sha 963b1862… matches golden constant. The modal reporting "8303" is therefore consistent with the disk golden. Download byte-exactness verified in Flow 6 below.


## Verified-working checklist

### Flow 1 — Load (local :8791)
- [x] Self-test auto-runs on load: badge "✓ self-test passed"; `window.__pspSelfTest()` → `{pass:true, sha:"963b1862…8ce72d"}`
- [x] Layout: 3 columns (grid 248px/612px/380px), top bar 🐸 PSP TRAIT STUDIO, 6 axis tabs with live counts (8/6/5/5/5 + PALETTES), Import…/Export Files/▶ Compile/Self-Test/⋯
- [x] Dark theme (#0e120f body), pepe-green accents, editor canvas 768×768 (16px cells), preview 192×192 (4×)
- [x] Console: ZERO errors/warnings on load
- [x] Trait list: 8 expressions w/ #ids + names, thumbnails 48×48 rendered at 24px
- [x] Palette dock: 14 armed-able swatches, slots 1 & 15 disabled, DNA readout "dna 0 · 0x00000000 · …"

### Flow 2 — Paint (expressions #0 NEUTRAL)
- [x] Pencil: single click sets cell (5,5)→slot 2; drag interpolates Bresenham along path (verified cells 5–8 on row)
- [x] Eraser: sets cell to 0
- [x] Right-click erases from any tool (tested from pencil)
- [x] Fill: enclosed 9×9 box (32 border cells exact) → interior fill = exactly 49 cells; same-slot re-fill no-ops
- [x] Line: (2,40)→(12,44) = exact 11-cell Bresenham diagonal
- [x] Rect: (30,2)→(35,8) = exact 22-cell outline (no fill)
- [x] Eyedropper: click cell with slot 11 → armed becomes 11 (and auto-returns to prev tool)
- [x] Mirror-X: paint (10,44) → both (10,44) and (37,44) painted; center guide dashed line appears
- [x] Undo/redo buttons: enabled after paint, undo restores pre-erase state, redo reapplies
- [x] Undo depth cap = 150 (UNDO_MAX constant, source-verified ≥100 spec)
- [x] Cell-size slider 8–28: canvas resizes 384/768/1344, label tracks, painting still maps to correct cells after resize
- [x] Grid-lines toggle, ghost underlay toggle, ghost opacity slider (40→0.8 alpha), checker/dark bg modes — all flip state + re-render
- [x] Status line: coords + armed slot name + trait name (#id)

### Flow 10 — Keyboard shortcuts
- [x] B/E/G/L/R/I switch tools; M toggles mirror (verified via dispatched keydown, each checked)
- [x] Cmd+Z undo, Cmd+Shift+Z redo, Ctrl+Z, Ctrl+Y all work (mac meta + pc ctrl paths)
- [x] Shortcuts suppressed while typing in inputs / modal open (source: `typing(e) || PSP.modalOpen()` guard)


## Console error log

(pending)
