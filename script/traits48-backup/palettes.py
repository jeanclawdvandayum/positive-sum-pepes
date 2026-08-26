# PSP pepe palettes — colors for skin / iris / background axes.
# RGB tuples. Slots each axis recolors:
#   skin -> slots 2 (base), 3 (light shade), 4 (dark shade), 10 (nostril)
#           + DERIVED high-contrast ramp: 16 bright, 17 deep, 18 glint,
#             19 mid-shadow (computed below from 2/3/4 — do not hand-set)
#   iris -> slot 6 (pupils + brows + eye bags)
#   bg   -> slot 15 (background)
# FIXED slots below are shared by every skin — edit with care, they recolor
# ALL pepes (5 white, 7 lips-rose, 8 lips-dark, 9 red, 11 gold, 12 gold-dark,
# 13 cookie, 14 shades-black, 20 steel-light, 21 steel-dark, 22 cream,
# 23 umber).
# DNA id = list index. Reordering changes existing DNA!

_BASE_RAMPS = {
    # slot 2 base / 3 light / 4 dark / 10 nostril — the hand-set core.
    # Classic + Gold + Zombie + Diamond are MEASURED from pepe_ref.jpg /
    # user-approved (Aug 24). Night authored. Grey/Orange/Green given real
    # ramps at 69px (v5) — they previously copy-pasted Night's shades.
    "Classic":  {2: (0x62, 0xC8, 0x75), 3: (0x8B, 0xD0, 0x7C),
                 4: (0x2D, 0x50, 0x34), 10: (0x24, 0x42, 0x29)},
    "Gold":     {2: (0xD4, 0xAF, 0x37), 3: (0xF0, 0xDA, 0x7B),
                 4: (0xA8, 0x84, 0x2B), 10: (0x6B, 0x50, 0x2A)},
    "Zombie":   {2: (0xB9, 0xC4, 0xB0), 3: (0xD6, 0xDE, 0xD0),
                 4: (0x6E, 0x7A, 0x66), 10: (0x4A, 0x3E, 0x36)},
    "Diamond":  {2: (0x5F, 0xE3, 0xD0), 3: (0xA9, 0xF4, 0xE8),
                 4: (0x35, 0xB5, 0xA4), 10: (0x2E, 0x6E, 0x74)},
    "Night":    {2: (0x3B, 0x4C, 0x6B), 3: (0x5A, 0x6F, 0x94),
                 4: (0x25, 0x31, 0x4A), 10: (0x2E, 0x2A, 0x3A)},
    "Grey":     {2: (0xB0, 0xB0, 0xB0), 3: (0xD9, 0xD9, 0xD9),
                 4: (0x6E, 0x6E, 0x6E), 10: (0x4E, 0x4E, 0x4E)},
    "Orange":   {2: (0xFF, 0x95, 0x00), 3: (0xFF, 0xBE, 0x5C),
                 4: (0xB3, 0x64, 0x00), 10: (0x7A, 0x44, 0x00)},
    "Green":    {2: (0x13, 0x70, 0x00), 3: (0x46, 0xA0, 0x2E),
                 4: (0x0C, 0x4A, 0x00), 10: (0x08, 0x34, 0x00)},
}


def _mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def _lighten(c, t):
    return _mix(c, (0xFF, 0xFF, 0xFF), t)


def _darken(c, t):
    return _mix(c, (0x00, 0x00, 0x00), t)


def _extend(ramp):
    """Derive the 4 high-contrast skin slots for accessories:
    16 bright (pop highlight), 17 deep (near-outline shadow),
    18 glint (near-white tinted), 19 mid-shadow (base->dark mid)."""
    out = dict(ramp)
    out[16] = _lighten(ramp[3], 0.32)
    out[17] = _darken(ramp[4], 0.42)
    out[18] = _lighten(ramp[3], 0.62)
    out[19] = _darken(_mix(ramp[2], ramp[4], 0.5), 0.10)
    return out


SKINS = [(name, _extend(ramp)) for name, ramp in _BASE_RAMPS.items()]

FIXED = {
    5:  (0xFE, 0xFE, 0xFE),   # eye white
    6:  (0x3F, 0x57, 0x5B),   # pupil slate (iris 0 default)
    7:  (0xC8, 0x62, 0x6D),   # lips rose
    8:  (0x43, 0x21, 0x22),   # mouth dark
    9:  (0xD0, 0x48, 0x3E),   # accent red (cap / ember)
    11: (0xE8, 0xB9, 0x3E),   # gold
    12: (0x8C, 0x6A, 0x1D),   # gold dark
    13: (0x00, 0x1E, 0xFF),   # cookie gold
    14: (0x23, 0x28, 0x2D),   # shades black
    20: (0xC2, 0xC8, 0xD4),   # steel light (metal highlight)
    21: (0x5C, 0x62, 0x70),   # steel dark (metal shadow)
    22: (0xFF, 0xF1, 0xC0),   # cream (warm soft highlight)
    23: (0x6E, 0x45, 0x24),   # umber (leather / wood midtone)
}

IRISES = [
    ("Slate",   (0x3F, 0x57, 0x5B)),
    ("Sky",     (0x54, 0x9E, 0xC7)),
    ("Amber",   (0xC8, 0x87, 0x2B)),
    ("Emerald", (0x2E, 0x8B, 0x57)),
    ("Crimson", (0x9E, 0x2B, 0x2B)),
    ("Onyx",    (0x14, 0x14, 0x16)),
    ("BASE",    (0x11, 0x00, 0xFF)),
]

BACKGROUNDS = [
    ("Sky",     (0x74, 0xC0, 0xDA)),
    ("Mint",    (0xB5, 0xE8, 0xC9)),
    ("Peach",   (0xF5, 0xC8, 0xA8)),
    ("Lavender",(0xC9, 0xB8, 0xE8)),
    ("Sunset",  (0xF0, 0x9A, 0x66)),
    ("Crimson", (0x8E, 0x2F, 0x3C)),
    ("Midnight",(0x18, 0x21, 0x38)),
    ("Void",    (0x0A, 0x0A, 0x0D)),
    ("Yellow",  (0xFF, 0xF8, 0x24)),
    ("MAGENTA", (0xFF, 0x0A, 0xF7)),
]
