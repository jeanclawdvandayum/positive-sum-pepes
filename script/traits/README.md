# PSP trait files — hand-editable art source

These text files are **the source of truth for all pepe trait pixels**.
`script/gen_pepe_art.py` reads them and emits `src/PepeArtData.sol`
(generated — never edit the .sol by hand).

## Files

- `expressions.txt` — 8 mouth stamps (full-canvas grids)
- `eyes.txt` — 6 eye stamps (full-canvas grids)
- `hats.txt` — cap / tinfoil / crown / headband (small letter tables)
- `eyewear.txt` — shades / monocle / glasses / visor
- `items.txt` — cigarette / snack / pipe / chain
- `palettes.py` — skin ramps, iris + background colors, fixed slots

## Workflow after editing

```bash
python3 script/gen_pepe_art.py          # regen PepeArtData.sol + previews
forge test --match-contract "PepeDescriptorTest|ArtDump"
```

Previews land in `/tmp/psp-art/` (per-axis PNGs + ascii dump). If you
moved pixels on purpose, pixel probes in `test/unit/PepeDescriptor.t.sol`
may need updating to the new geometry — the failure messages name the
exact rect/probe.

## Full-canvas format (`expressions.txt`, `eyes.txt`)

```
# name: SMILE
# y: 26            <- first row's index on the 48x48 canvas
........48 chars........
........48 chars........
```

- Every data row is **exactly 48 chars** (full canvas width).
- Columns are absolute: col 25-26 = nose bridge zone, mouth lives ~cols
  14-40, rows 26-34.
- `.` = transparent (base head shows through).

## Letter-table format (`hats.txt`, `eyewear.txt`, `items.txt`)

```
# name: CAP
# dx: 12           <- left edge on canvas
# dy: 9            <- top edge on canvas
....rows of uniform width....
```

- id 0 is always implicit `NONE` (no block); file blocks get ids 1..N.
- Rows must be uniform width; `.` = transparent.

## Letter legend (palette slots — same in every file)

- `.` transparent | `#` outline(1, unused)
- `G` base skin(2) | `L` light skin(3) | `D` dark skin(4) — **recolor with skin**
- `W` eye white(5) | `P` pupil/iris(6) — **recolors with iris**
- `r` lips rose(7) | `R` lips dark(8) | `c` accent red(9) | `n` nostril(10)
- `g` gold(11) | `d` gold-dark(12) | `k` cookie(13) | `s` shades-black(14)
- `b` background(15, unused in stamps)

Slots 2/3/4/10 recolor per skin, slot 6 per iris — use those letters
(`G L D P n`) for anything that should follow skin/eye color.

## Rules enforced by tests

- **DNA id = file order.** Reordering/renaming blocks changes what
  existing DNA renders — append new traits at the end.
- Frogs have **no teeth**: no white (W) inside any mouth.
- Cigarette stays **uniform 2px width** end-to-end.
- Mouth stamps own rows 27-35; nostrils live in the BASE at rows 26-27
  (cols 22-23, 27-28) — don't paint over them with `.`-holes, but rose
  overlapping them is fine.
- The base head itself is *traced* from `script/assets/pepe_ref.jpg` —
  not in these files. Changing head geometry means editing the trace
  code in `gen_pepe_art.py` (`_trace`/`_base`).

## Palette editing (`palettes.py`)

Skins recolor 4 slots each (base/light/dark/nostril). Keep dark <
light in brightness so shading still reads. FIXED slots are shared by
all skins — changing `7` (rose) recolors every mouth on every pepe.
