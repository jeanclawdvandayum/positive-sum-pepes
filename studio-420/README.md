# PSP Trait Studio — 420 edition

An alternative copy of the Trait Studio that holds a marijuana-themed "420" edition of the Pepe collection.
It starts from the current release-2 art (`studio/expanded/*.txt`). Nothing under `studio/` changes.

## Open it

```sh
open studio-420/dist/trait-studio-420.html   # the 420 studio (self-test badge bottom-left)
open studio-420/dist/collection.html         # collection inspector
```

Both are single files with no network access, and they open straight from `file://`. The unbundled
sources in `studio-420/src/` also open from `file://`.

The studio saves its work under its own key, `psp-trait-studio-420-v1`, so it never touches the
original studio's autosave.

The collection inspector has four sections:
- every trait of every axis, drawn on the base head and labeled with its DNA id;
- the original next to the 420 version for every changed or added trait;
- the palettes, with new and recolored entries highlighted;
- 72 random pepes. Add `#seed=N` to the URL to repeat a grid, or `#count=N` to show more.

It renders with the studio's own code: `PSPCompiler.resolvePalette`, the same layer order as
`PSPApp.compose`, and the same pixel-fill loop as the studio preview.

## Rebuild

```sh
python3 studio-420/tools/make_defaults.py   # art/*.txt + art/palettes.json -> src/defaults.js, src/original.js,
                                            # art/PepeArtData.sol, art/GOLDEN_SHA256, pins PSP.GOLDEN_SHA
python3 studio-420/tools/build_inline.py    # -> dist/trait-studio-420.html, dist/collection.html
```

`make_defaults.py` recomputes the 420 golden and writes it into `src/app-core.js`. It then compiles
the written `defaults.js` again and checks that the result matches the pin. It also checks that:
- the original art still compiles to `studio/expanded/PepeArtData.sol`;
- the DNA order holds (the two renames stay in place and new traits come after the old ones);
- each axis has at most 16 entries;
- the palettes only grew, apart from the one recolored slot, which no original trait uses.

`compiler.js` is a byte-for-byte copy of `studio/compiler.js`.

## 420 golden

`59397561cfebfd5818e44a62ac7044e7beb719d16834d75ecbf5990c854d52da`

This is the sha256 of `art/PepeArtData.sol`, which is also stored in `art/GOLDEN_SHA256`. It is not
the original golden (`73fff0a5…`) and not the release-2 export hash.

## What changed (DNA order; `*` = changed, `+` = new)

| axis | traits |
|---|---|
| expressions | NEUTRAL SMILE GRIN LAUGH SAD SCARED ANGRY SMIRK CRINGE MEH AMAZING RAGE +MUNCHIES +COTTONMOUTH |
| eyes | \*CLASSIC \*FEELS \*SLEEPY \*DERP \*WIDE \*BAKED \*STARRY \*EYEROLL \*DEAD \*CROSSEYED \*SUS |
| hats | (NONE) CAP TINFOIL CROWN HEADBAND NARUTO TOPHAT FRENCH WIZARD HOODIE FUCKMYSHITUP +RASTA +BUCKET |
| eyewear | (NONE) SHADES MONOCLE GLASSES MOGGED EYEPATCH HEARTGLASSES THREEDIMGLASSES CYBERSHADES COOLSHADES READINGGLASSES UNIBROW (no changes) |
| items | (NONE) \*JOINT (was CIGARETTE) PIPE CHAIN STITCHES NOOSE \*BLUNT (was CIGAR) BONG JARHEAD LOLLIPOP KNIFE +VAPE +LEAFCHAIN +SMOKERINGS |

- **Eyes:** every eye now has a heavy half-closed lid: the dark lid comes down over the white and ends
  in a darker lash line. The whites are bloodshot, with short red veins (`r`), and there are bags
  underneath. Each eye keeps its identity:
  - FEELS keeps its sad brows and gains a tear.
  - DERP has pupils at the outer edges and lids at different heights.
  - WIDE stays wide open and paranoid.
  - STARRY keeps its gold stars.
  - EYEROLL has the pupils rolled up under the lid.
  - DEAD keeps its X eyes and gains drooping brows.
  - CROSSEYED keeps its pupils at the inner corners.
  - SUS keeps its side-eye, now narrower.
  - SLEEPY and BAKED go furthest: SLEEPY is almost shut, and BAKED is a red-rimmed squint.
- **JOINT:** a cone-rolled paper with a filter tip and a twisted pinch at the mouth end. It widens
  toward a glowing cherry with gold ember pixels and has wispy smoke.
- **BLUNT:** a brown leaf wrap with a spiral seam, a grey ash ring and an ember cherry, with thick,
  puffy smoke.
- **VAPE:** a black mouthpiece, an amber oil window, a steel battery with a red light, and a vapor
  cloud.
- **RASTA:** a knit tam with red, gold and green stripes and a black band, with dreadlocks hanging
  on both sides of the head.
- **BUCKET:** a white bucket hat with a stitched brim and a pot-leaf patch.
- **LEAFCHAIN:** the gold chain with a round gold medallion holding a green pot leaf.
- **SMOKERINGS:** three smoke rings that rise from the corner of the mouth and grow as they go up.
- **MUNCHIES:** a dopey grin with the tongue licking the corner of the mouth and snack crumbs on the
  lips and chin.
- **COTTONMOUTH:** a slack, open mouth with cracked dry lips and the tongue hanging out.

## Palette changes (420's own `art/palettes.json`)

- Fixed slot 22 (letter `C`) changed from cream `255,241,192` to leaf green `44,154,64`. No
  release-2 trait uses slot 22, so no existing pixel changes color.
- New entries, all added at the end so existing ids keep their colors:
  - skin 10: **Purp**, a purple ramp;
  - iris 10: **Redeye** (`196,38,48`);
  - backgrounds 10–12: **Haze**, **PurpleHaze** and **Kush**.

The 24 slots and their letters are the compiler's and stay fixed. The only new green is the recolored
slot 22.

## QA

Screenshots are in `qa/`:
- `studio-420-selftest-passed.png`
- `collection-every-trait.png`
- `collection-original-vs-420.png`
- `collection-palettes.png`
- `collection-random-72.png`
- `traits/<axis>-<NAME>.png`: one original-vs-420 pair at 6× for every changed or new trait.
