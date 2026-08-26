#!/usr/bin/env python3
"""Extract the art constants from src/PepeArtData.sol into
frontend/src/lib/pepeArt.json — the client-side fallback renderer's data.

Same bytes the contract renders: RLE stamps, skin ramps, fixed slots,
iris + bg colors. Run after gen_pepe_art.py whenever the art changes:

    python3 script/gen_pepe_art.py && python3 script/gen_frontend_art.py
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOL = ROOT / "src" / "PepeArtData.sol"
OUT = ROOT / "frontend" / "src" / "lib" / "pepeArt.json"

src = SOL.read_text()


def const(name: str) -> str:
    m = re.search(rf'{name} = hex"([0-9A-F]+)"', src)
    if not m:
        raise SystemExit(f"constant not found: {name}")
    return m.group(1)


def count(name: str) -> int:
    m = re.search(rf"{name} = (\d+);", src)
    if not m:
        raise SystemExit(f"count not found: {name}")
    return int(m.group(1))


def series(prefix: str, n: int, none_at_zero: bool) -> list:
    out = []
    for i in range(n):
        if none_at_zero and i == 0:
            out.append(None)
        else:
            out.append(const(f"{prefix}_{i}") if False else None)
    return out


def named_series(names: list) -> list:
    return [const(n) for n in names]


EXPR = ["NEUTRAL", "SMILE", "GRIN", "LAUGH", "SAD", "SCARED", "ANGRY",
        "SMIRK", "CRINGE", "MEH"]
EYE = ["CLASSIC", "FEELS", "SLEEPY", "DERP", "WIDE", "BAKED", "STARRY",
       "EYEROLL", "DEAD", "CROSSEYED"]
HAT = ["CAP", "TINFOIL", "CROWN", "HEADBAND", "NARUTO", "TOPHAT",
       "FRENCH", "WIZARD", "HOODIE"]
WEAR = ["SHADES", "MONOCLE", "GLASSES", "MOGGED", "EYEPATCH",
        "HEARTGLASSES", "THREEDIMGLASSES", "CYBERSHADES", "COOLSHADES"]
ITEM = ["CIGARETTE", "PIPE", "CHAIN", "STITCHES", "NOOSE", "CIGAR",
        "BONG", "JARHEAD", "LOLLIPOP"]

data = {
    # codec v2: 4 bits per axis, in this order (see PepeDescriptor.decode)
    "axisBits": [4, 4, 4, 4, 4, 4, 4, 4],
    "counts": {
        "expr": count("EXPR_COUNT"),
        "eye": count("EYE_COUNT"),
        "hat": count("HAT_COUNT"),
        "wear": count("WEAR_COUNT"),
        "item": count("ITEM_COUNT"),
        "skin": count("SKIN_COUNT"),
        "iris": count("IRIS_COUNT"),
        "bg": count("BG_COUNT"),
    },
    "base": const("SPRITE_BASE"),
    "expr": named_series([f"EXPR_{n}" for n in EXPR]),
    "eye": named_series([f"EYE_{n}" for n in EYE]),
    "hat": [None] + named_series([f"HAT_{n}" for n in HAT]),
    "wear": [None] + named_series([f"WEAR_{n}" for n in WEAR]),
    "item": [None] + named_series([f"ITEM_{n}" for n in ITEM]),
    # palette assembly (mirrors PepeArtData.palette)
    "skinSlots": [2, 3, 4, 10, 16, 17, 18, 19],
    "fixedSlots": [5, 7, 8, 9, 11, 12, 13, 14, 20, 21, 22, 23],
    "skins": const("SKIN_RAMPS"),
    "fixed": const("FIXED_SLOTS"),
    "irises": const("IRIS_COLORS"),
    "bgs": const("BG_COLORS"),
}

# sanity: series lengths match counts
assert len(data["expr"]) == data["counts"]["expr"]
assert len(data["eye"]) == data["counts"]["eye"]
assert len(data["hat"]) == data["counts"]["hat"]
assert len(data["wear"]) == data["counts"]["wear"]
assert len(data["item"]) == data["counts"]["item"]
assert len(data["skins"]) == data["counts"]["skin"] * 24 * 2
assert len(data["fixed"]) == 12 * 3 * 2
assert len(data["irises"]) == data["counts"]["iris"] * 3 * 2
assert len(data["bgs"]) == data["counts"]["bg"] * 3 * 2

OUT.write_text(json.dumps(data, separators=(",", ":")))
print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")
