#!/usr/bin/env python3
"""Authored vector traits — smooth Bezier art, NOT pixel traces.

Every trait is drawn in FINAL 480-canvas coordinates (grid x10) with a
consistent drawing language:
  - strokes   = capsule chains with round caps (organic linework)
  - fills     = cubic/quad silhouettes, ellipses, rounded rects
  - rings     = outer + reversed inner subpaths (nonzero-winding hole)
  - sparkles  = 4-point stars, hearts, teardrops as closed cubics

Slots match the pixel palette semantics exactly (5 white, 6 iris, 7 rose,
8 mouth-dark, 9 accent red, 11 gold, 12 gold-dark, 13 blue, 14 black,
3 light-green, 4 dark-green).

AUTHORED[(axis, name)] -> [(slot, d)] | None-to-fallback.
"""
import math

# ── formatting ────────────────────────────────────────────────────────


def _f(v):
    s = f'{float(v):.1f}'
    return s[:-2] if s.endswith('.0') else s


def _pt(p):
    return f'{_f(p[0])} {_f(p[1])}'


# ── primitives ────────────────────────────────────────────────────────

def capsule(p0, p1, w):
    """filled line segment with round caps (exact, 2 arcs)"""
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    ln = math.hypot(dx, dy) or 1e-9
    nx, ny = -dy / ln * w, dx / ln * w
    return (f'M{_pt((p0[0] + nx, p0[1] + ny))}L{_pt((p1[0] + nx, p1[1] + ny))}'
            f'A{_f(w)} {_f(w)} 0 0 1 {_pt((p1[0] - nx, p1[1] - ny))}'
            f'L{_pt((p0[0] - nx, p0[1] - ny))}'
            f'A{_f(w)} {_f(w)} 0 0 1 {_pt((p0[0] + nx, p0[1] + ny))}z')


def _catmull(pts, samples):
    """Catmull-Rom spline through pts -> sampled polyline"""
    p = [list(pts[0])] + [list(q) for q in pts] + [list(pts[-1])]
    out = []
    for i in range(1, len(p) - 2):
        p0, p1, p2, p3 = p[i - 1], p[i], p[i + 1], p[i + 2]
        for j in range(samples):
            t = j / samples
            t2, t3 = t * t, t * t * t
            x = (0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t
                        + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2
                        + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3))
            y = (0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t
                        + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2
                        + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3))
            out.append((x, y))
    out.append(tuple(pts[-1]))
    return out


def stroke(pts, w, samples=10):
    """smooth curved stroke = chained capsules along a Catmull-Rom spline"""
    sm = _catmull(pts, samples)
    return ' '.join(capsule(sm[i], sm[i + 1], w) for i in range(len(sm) - 1))


def ellipse(cx, cy, rx, ry, rot=0.0):
    """filled ellipse (2 arcs); rot in degrees CCW"""
    t = math.radians(rot)
    c, s = math.cos(t), math.sin(t)
    ex, ey = rx * c, rx * s
    return (f'M{_f(cx + ex)} {_f(cy + ey)}'
            f'A{_f(rx)} {_f(ry)} {_f(rot)} 0 1 {_f(cx - ex)} {_f(cy - ey)}'
            f'A{_f(rx)} {_f(ry)} {_f(rot)} 0 1 {_f(cx + ex)} {_f(cy + ey)}z')


def circle(cx, cy, r):
    return ellipse(cx, cy, r, r)


def ring(cx, cy, rx, ry, w, rot=0.0):
    """annulus: outer clockwise, inner counter-clockwise (nonzero hole)"""
    t = math.radians(rot)
    c, s = math.cos(t), math.sin(t)
    ex, ey = rx * c, rx * s
    ix, iy = (rx - w) * c, (rx - w) * s
    return (f'M{_f(cx + ex)} {_f(cy + ey)}'
            f'A{_f(rx)} {_f(ry)} {_f(rot)} 0 1 {_f(cx - ex)} {_f(cy - ey)}'
            f'A{_f(rx)} {_f(ry)} {_f(rot)} 0 1 {_f(cx + ex)} {_f(cy + ey)}z'
            f'M{_f(cx + ix)} {_f(cy + iy)}'
            f'A{_f(rx - w)} {_f(ry - w)} {_f(rot)} 0 0 {_f(cx - ix)} {_f(cy - iy)}'
            f'A{_f(rx - w)} {_f(ry - w)} {_f(rot)} 0 0 {_f(cx + ix)} {_f(cy + iy)}z')


def rrect(x, y, w, h, r):
    return (f'M{_f(x + r)} {_f(y)}L{_f(x + w - r)} {_f(y)}'
            f'Q{_f(x + w)} {_f(y)} {_f(x + w)} {_f(y + r)}'
            f'L{_f(x + w)} {_f(y + h - r)}'
            f'Q{_f(x + w)} {_f(y + h)} {_f(x + w - r)} {_f(y + h)}'
            f'L{_f(x + r)} {_f(y + h)}'
            f'Q{_f(x)} {_f(y + h)} {_f(x)} {_f(y + h - r)}'
            f'L{_f(x)} {_f(y + r)}'
            f'Q{_f(x)} {_f(y)} {_f(x + r)} {_f(y)}z')


def heart(cx, cy, s):
    return (f'M{_f(cx)} {_f(cy + 0.75 * s)}'
            f'C{_f(cx - 1.15 * s)} {_f(cy + 0.15 * s)} '
            f'{_f(cx - 0.9 * s)} {_f(cy - 0.55 * s)} {_f(cx)} {_f(cy - 0.12 * s)}'
            f'C{_f(cx + 0.9 * s)} {_f(cy - 0.55 * s)} '
            f'{_f(cx + 1.15 * s)} {_f(cy + 0.15 * s)} {_f(cx)} {_f(cy + 0.75 * s)}z')


def star4(cx, cy, r):
    return (f'M{_f(cx)} {_f(cy - r)}Q{_f(cx)} {_f(cy)} {_f(cx + r)} {_f(cy)}'
            f'Q{_f(cx)} {_f(cy)} {_f(cx)} {_f(cy + r)}'
            f'Q{_f(cx)} {_f(cy)} {_f(cx - r)} {_f(cy)}'
            f'Q{_f(cx)} {_f(cy)} {_f(cx)} {_f(cy - r)}z')


def teardrop(cx, cy, s):
    return (f'M{_f(cx)} {_f(cy - s)}'
            f'C{_f(cx + 0.55 * s)} {_f(cy - 0.1 * s)} '
            f'{_f(cx + 0.5 * s)} {_f(cy + 0.35 * s)} {_f(cx)} {_f(cy + 0.45 * s)}'
            f'C{_f(cx - 0.5 * s)} {_f(cy + 0.35 * s)} '
            f'{_f(cx - 0.55 * s)} {_f(cy - 0.1 * s)} {_f(cx)} {_f(cy - s)}z')


def spiral(cx, cy, r0, r1, turns, w):
    pts = []
    n = 26
    for i in range(n + 1):
        th = i / n * turns * 2 * math.pi
        r = r0 + (r1 - r0) * i / n
        pts.append((cx + r * math.cos(th), cy + r * math.sin(th)))
    return stroke(pts, w, samples=4)


def bead_chain(p0, p1, ctrl, n, r):
    """n circles along a quadratic bezier"""
    out = []
    for i in range(n):
        t = i / (n - 1)
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * ctrl[0] + t ** 2 * p1[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * ctrl[1] + t ** 2 * p1[1]
        out.append(circle(x, y, r))
    return ' '.join(out)


# ── shared eye geometry (48-grid, x10 at build) ───────────────────────
# left eye white centre (19.6, 21.7), right (31.4, 21.7); brow band rows
# 17-18.5; nose bridge light strip col 25.7

def _eye_frame(brow_w, brow_y=18.4, bridge=True):
    out = [(4, stroke([(144, brow_y * 10 + 6), (257, brow_y * 10 - 8),
                       (370, brow_y * 10 + 6)], brow_w))]
    if bridge:
        out.append((3, capsule((257, 176), (257, 246), 8)))
    return out


def _whites(cx_l=19.6, cx_r=31.4, cy=21.7, rx=5.4, ry=3.0):
    return (5, ellipse(cx_l * 10, cy * 10, rx * 10, ry * 10)
            + ellipse(cx_r * 10, cy * 10, rx * 10, ry * 10))


AUTHORED = {}

# ── EYES ──────────────────────────────────────────────────────────────

AUTHORED[('eyes', 'CLASSIC')] = (
    _eye_frame(19)
    + [_whites(),
       (6, ellipse(214, 219, 17, 20.5) + ellipse(332, 219, 17, 20.5)),
       (5, circle(203, 209, 5) + circle(321, 209, 5))])

AUTHORED[('eyes', 'FEELS')] = (
    _eye_frame(30)
    + [(4, stroke([(150, 156), (196, 146), (242, 156)], 9) +
        stroke([(298, 156), (344, 146), (390, 156)], 9)),
       _whites(cy=22.6, ry=2.3),
       (6, ellipse(214, 228, 18, 19.5) + ellipse(332, 228, 18, 19.5)),
       (5, teardrop(150, 268, 12) + teardrop(364, 268, 12))])

AUTHORED[('eyes', 'SLEEPY')] = (
    _eye_frame(30, bridge=False)
    + [(3, capsule((257, 176), (257, 226), 8)),
       _whites(cy=23.5, ry=1.35),
       (6, ellipse(214, 235, 17, 13.5) + ellipse(332, 235, 17, 13.5)),
       (4, stroke([(146, 253), (247, 253)], 8)
          + stroke([(273, 253), (374, 253)], 8))])

AUTHORED[('eyes', 'DERP')] = (
    _eye_frame(19)
    + [_whites(),
       (6, ellipse(166, 219, 17, 20.5) + ellipse(344, 219, 17, 20.5)),
       (5, circle(157, 209, 5) + circle(353, 209, 5))])

AUTHORED[('eyes', 'WIDE')] = (
    [(4, stroke([(138, 164), (196, 148), (252, 164)], 8)
          + stroke([(298, 164), (344, 148), (402, 164)], 8))]
    + _eye_frame(11)
    + [_whites(ry=3.5),
       (6, circle(196, 215, 11.5) + circle(314, 215, 11.5))])

AUTHORED[('eyes', 'BAKED')] = (
    [(4, stroke([(145, 202), (257, 192), (369, 202)], 20)),
       _whites(cy=23.5, ry=1.6),
       (6, circle(196, 235, 14.5) + circle(314, 235, 14.5)),
       (7, capsule((162, 220), (160, 232), 7)
          + capsule((208, 218), (206, 230), 7)
          + capsule((304, 218), (306, 230), 7)
          + capsule((350, 220), (352, 232), 7)),
       (4, stroke([(149, 257), (196, 265), (244, 257)], 7)
          + stroke([(296, 257), (344, 265), (391, 257)], 7))])

AUTHORED[('eyes', 'STARRY')] = (
    _eye_frame(19)
    + [_whites(),
       (11, star4(214, 218, 24) + star4(332, 218, 24)),
       (11, circle(240, 192, 5) + circle(356, 196, 4))])

AUTHORED[('eyes', 'EYEROLL')] = (
    _eye_frame(19)
    + [_whites(),
       (6, ellipse(214, 201, 17, 19) + ellipse(332, 201, 17, 19)),
       (4, stroke([(146, 247), (247, 247)], 8)
          + stroke([(273, 247), (374, 247)], 8))])

AUTHORED[('eyes', 'DEAD')] = [
    (14, capsule((166, 196), (226, 238), 6)
        + capsule((226, 196), (166, 238), 6)
        + capsule((284, 196), (344, 238), 6)
        + capsule((344, 196), (284, 238), 6))]

# ── EXPRESSIONS (mouth centre x275) ───────────────────────────────────

AUTHORED[('expr', 'NEUTRAL')] = [
    (7, stroke([(178, 301), (275, 307), (372, 301)], 12)),
    (7, stroke([(186, 315), (275, 325), (364, 315)], 15)),
    (8, stroke([(182, 309), (275, 312), (368, 309)], 8))]

AUTHORED[('expr', 'SMILE')] = [
    (7, f'M{_f(156)} {_f(288)}Q{_f(275)} {_f(348)} {_f(394)} {_f(288)}'
        f'Q{_f(275)} {_f(306)} {_f(156)} {_f(288)}z'),
    (14, stroke([(160, 290), (275, 336), (390, 290)], 9)),
    (14, circle(159, 289, 8.5) + circle(391, 289, 8.5))]

AUTHORED[('expr', 'GRIN')] = [
    (14, stroke([(166, 292), (275, 334), (384, 292)], 9)),
    (5, f'M{_f(168)} {_f(290)}Q{_f(275)} {_f(278)} {_f(382)} {_f(290)}'
        f'L{_f(372)} {_f(322)}Q{_f(275)} {_f(334)} {_f(178)} {_f(322)}z'),
    (8, capsule((226, 286), (224, 322), 5.5)
        + capsule((275, 282), (275, 328), 5.5)
        + capsule((324, 286), (326, 322), 5.5)),
    (7, stroke([(180, 332), (275, 346), (370, 332)], 16))]

AUTHORED[('expr', 'LAUGH')] = [
    (7, stroke([(174, 287), (275, 293), (376, 287)], 14)),
    (8, ellipse(275, 318, 97, 43)),
    (9, f'M{_f(221)} {_f(333)}Q{_f(275)} {_f(372)} {_f(329)} {_f(333)}'
        f'Q{_f(275)} {_f(349)} {_f(221)} {_f(333)}z'),
    (8, capsule((275, 340), (275, 352), 6))]

AUTHORED[('expr', 'SAD')] = [
    (7, stroke([(180, 296), (275, 290), (370, 296)], 11)),
    (7, stroke([(188, 310), (275, 304), (362, 310)], 13)),
    (14, stroke([(164, 328), (275, 303), (386, 328)], 9)),
    (14, teardrop(150, 342, 12))]

AUTHORED[('expr', 'SCARED')] = [
    (7, ring(275, 307, 39, 31, 13)),
    (8, ellipse(275, 307, 27, 20))]

AUTHORED[('expr', 'ANGRY')] = [
    (8, stroke([(179, 307), (275, 307), (371, 307)], 15)),
    (5, rrect(182, 293, 190, 28, 8)),
    (8, capsule((225, 294), (225, 319), 6)
        + capsule((275, 294), (275, 319), 6)
        + capsule((325, 294), (325, 319), 6)),
    (14, capsule((172, 290), (162, 319), 8)
        + capsule((378, 290), (388, 319), 8))]

AUTHORED[('expr', 'SMIRK')] = [
    (7, f'M{_f(206)} {_f(308)}Q{_f(275)} {_f(338)} {_f(362)} {_f(284)}'
        f'Q{_f(275)} {_f(305)} {_f(206)} {_f(308)}z'),
    (14, stroke([(206, 309), (275, 326), (360, 287)], 9)),
    (14, circle(363, 284, 9))]

# ── HATS ──────────────────────────────────────────────────────────────

AUTHORED[('hat', 'CAP')] = [
    (9, f'M{_f(142)} {_f(140)}Q{_f(142)} {_f(68)} {_f(224)} {_f(68)}'
        f'Q{_f(306)} {_f(68)} {_f(306)} {_f(140)}z'),
    (14, stroke([(224, 70), (184, 139)], 7) + stroke([(224, 70), (264, 139)], 7)),
    (11, circle(224, 69, 7)),
    (8, stroke([(136, 142), (280, 138), (440, 146)], 23))]

AUTHORED[('hat', 'TINFOIL')] = [
    (5, f'M{_f(150)} {_f(144)}Q{_f(134)} {_f(108)} {_f(172)} {_f(92)}'
        f'Q{_f(166)} {_f(66)} {_f(196)} {_f(54)}Q{_f(204)} {_f(28)} {_f(234)} {_f(36)}'
        f'Q{_f(270)} {_f(24)} {_f(282)} {_f(52)}Q{_f(316)} {_f(56)} {_f(308)} {_f(84)}'
        f'Q{_f(334)} {_f(96)} {_f(316)} {_f(122)}Q{_f(330)} {_f(138)} {_f(304)} {_f(144)}z'),
    (14, stroke([(158, 138), (176, 106), (196, 96)], 5.5)
        + stroke([(236, 40), (244, 70), (262, 88)], 5.5)
        + stroke([(296, 84), (282, 110), (290, 136)], 5.5))]

AUTHORED[('hat', 'CROWN')] = [
    (11, f'M{_f(168)} {_f(120)}L{_f(168)} {_f(96)}L{_f(172)} {_f(74)}'
        f'L{_f(206)} {_f(96)}L{_f(240)} {_f(56)}L{_f(274)} {_f(96)}'
        f'L{_f(308)} {_f(74)}L{_f(312)} {_f(96)}L{_f(312)} {_f(120)}z'),
    (12, rrect(168, 120, 144, 18, 5)),
    (11, circle(172, 70, 5.5) + circle(240, 52, 5.5) + circle(308, 70, 5.5)),
    (9, circle(204, 109, 4.5) + circle(276, 109, 4.5))]

AUTHORED[('hat', 'HEADBAND')] = [
    (7, stroke([(40, 140), (200, 132), (356, 140)], 24)),
    (7, circle(46, 141, 17)),
    (7, stroke([(46, 140), (28, 166), (44, 188)], 13)
        + stroke([(52, 144), (64, 172), (50, 204)], 13))]

AUTHORED[('hat', 'NARUTO')] = [
    (14, stroke([(92, 118), (200, 112), (350, 120)], 27)),
    (5, rrect(158, 104, 132, 44, 10)),
    (14, spiral(224, 126, 4, 17, 1.5, 5)),
    (14, circle(165, 110, 3.5) + circle(283, 110, 3.5)
        + circle(165, 142, 3.5) + circle(283, 142, 3.5))]

AUTHORED[('hat', 'TOPHAT')] = [
    (14, f'M{_f(158)} {_f(130)}L{_f(163)} {_f(26)}Q{_f(163)} {_f(19)} {_f(170)} {_f(19)}'
        f'L{_f(310)} {_f(19)}Q{_f(317)} {_f(19)} {_f(317)} {_f(26)}L{_f(322)} {_f(130)}z'),
    (11, stroke([(166, 112), (314, 112)], 36)),
    (14, ellipse(240, 140, 150, 11))]

AUTHORED[('hat', 'FRENCH')] = [
    (13, f'M{_f(112)} {_f(120)}Q{_f(116)} {_f(88)} {_f(152)} {_f(77)}'
        f'Q{_f(210)} {_f(60)} {_f(268)} {_f(72)}Q{_f(322)} {_f(82)} {_f(378)} {_f(112)}'
        f'Q{_f(380)} {_f(122)} {_f(368)} {_f(122)}L{_f(122)} {_f(122)}'
        f'Q{_f(112)} {_f(122)} {_f(112)} {_f(120)}z'),
    (5, f'M{_f(118)} {_f(104)}Q{_f(240)} {_f(82)} {_f(372)} {_f(102)}'
        f'L{_f(374)} {_f(114)}Q{_f(240)} {_f(94)} {_f(118)} {_f(114)}z'),
    (9, f'M{_f(120)} {_f(114)}Q{_f(240)} {_f(94)} {_f(374)} {_f(114)}'
        f'L{_f(376)} {_f(122)}L{_f(122)} {_f(122)}z'),
    (14, capsule((240, 64), (240, 74), 14))]

AUTHORED[('hat', 'WIZARD')] = [
    (14, f'M{_f(200)} {_f(166)}Q{_f(186)} {_f(118)} {_f(214)} {_f(82)}'
        f'Q{_f(238)} {_f(48)} {_f(280)} {_f(24)}Q{_f(272)} {_f(54)} {_f(260)} {_f(84)}'
        f'Q{_f(288)} {_f(96)} {_f(264)} {_f(128)}Q{_f(280)} {_f(148)} {_f(280)} {_f(166)}z'),
    (14, ellipse(240, 168, 192, 13)),
    (11, stroke([(194, 150), (286, 150)], 42)),
    (12, ' '.join(capsule((x, 146), (x, 154), 8) for x in range(205, 280, 14))),
    (11, star4(238, 108, 6) + star4(256, 134, 4.2) + star4(220, 88, 3))]

AUTHORED[('hat', 'HOMER')] = [
    (14, stroke([(170, 106), (167, 96), (172, 88), (181, 91)], 9)
        + stroke([(186, 106), (183, 94), (190, 86), (199, 91)], 9)),
    (14, ' '.join(circle(x, y, 5.5) for x, y in
                  [(108, 196), (115, 204), (105, 212),
                   (372, 196), (365, 204), (375, 212)]))]

# ── WEAR ──────────────────────────────────────────────────────────────

AUTHORED[('wear', 'SHADES')] = [
    (14, rrect(74, 176, 144, 72, 14) + rrect(262, 176, 144, 72, 14)),
    (14, capsule((218, 186), (262, 186), 15)),
    (14, capsule((74, 182), (56, 190), 22) + capsule((406, 182), (424, 190), 22)),
    (5, stroke([(88, 192), (122, 228)], 13) + stroke([(96, 186), (116, 206)], 13)
        + stroke([(276, 192), (310, 228)], 13)
        + stroke([(284, 186), (304, 206)], 13))]

AUTHORED[('wear', 'MONOCLE')] = [
    (11, ring(314, 212, 56, 56, 7)),
    (5, stroke([(282, 176), (306, 204)], 10)),
    (11, ' '.join(circle(x, y, 9) for x, y in
                  [(368, 272), (372, 286), (376, 300), (380, 314)]))]

AUTHORED[('wear', 'GLASSES')] = [
    (14, ring(165, 212, 60, 60, 6.5) + ring(315, 212, 60, 60, 6.5)),
    (14, capsule((225, 206), (255, 206), 25)),
    (14, capsule((107, 204), (86, 197), 21) + capsule((373, 204), (394, 197), 21)),
    (5, stroke([(138, 182), (160, 208)], 11) + stroke([(288, 182), (310, 208)], 11))]

AUTHORED[('wear', 'MOGGED')] = [
    (14, stroke([(104, 170), (94, 198), (108, 234), (152, 258), (206, 272),
                 (240, 274), (274, 272), (328, 258), (372, 234), (386, 198),
                 (376, 170)], 9)),
    (11, stroke([(104, 170), (94, 198), (108, 234), (152, 258), (206, 272),
                 (240, 274), (274, 272), (328, 258), (372, 234), (386, 198),
                 (376, 170)], 6.4)),
    (14, capsule((238, 254), (243, 271), 22)),
    (14, capsule((120, 214), (134, 222), 11) + capsule((360, 214), (346, 222), 11)
        + capsule((150, 246), (162, 254), 11)
        + capsule((330, 246), (318, 254), 11))]

AUTHORED[('wear', 'MAGNIFYING')] = [
    (14, ring(310, 188, 86, 86, 10)),
    (5, stroke([(268, 138), (300, 172)], 24) + stroke([(288, 124), (312, 150)], 14)),
    (14, stroke([(240, 260), (186, 308), (122, 352)], 45)),
    (11, capsule((150, 334), (116, 352), 57))]

AUTHORED[('wear', 'EYEPATCH')] = [
    (14, stroke([(112, 168), (190, 157), (310, 157), (368, 171)], 25)),
    (14, ellipse(212, 218, 72, 46))]

AUTHORED[('wear', 'HEARTGLASSES')] = [
    (9, heart(196, 212, 58) + heart(314, 212, 58)),
    (14, heart(196, 215, 38) + heart(314, 215, 38)),
    (9, capsule((234, 204), (246, 204), 40)),
    (5, circle(184, 198, 12) + circle(302, 198, 12))]

# ── ITEMS ─────────────────────────────────────────────────────────────

AUTHORED[('item', 'CIGARETTE')] = [
    (5, stroke([(436, 182), (446, 194), (438, 208), (448, 222)], 7.5)
        + stroke([(428, 176), (421, 190), (430, 202)], 7.5)
        + stroke([(448, 166), (443, 176)], 7.5)),
    (5, capsule((374, 300), (452, 294), 10)),
    (12, capsule((374, 300), (394, 298), 10)),
    (8, capsule((394, 298), (401, 297), 10)),
    (9, capsule((448, 295), (458, 293), 10))]

AUTHORED[('item', 'PIPE')] = [
    (5, stroke([(226, 300), (235, 285), (226, 270), (237, 254)], 8)
        + stroke([(244, 296), (251, 284), (245, 272)], 7)),
    (14, stroke([(132, 332), (180, 326), (214, 332)], 30)),
    (14, f'M{_f(212)} {_f(318)}L{_f(248)} {_f(318)}Q{_f(254)} {_f(318)} {_f(254)} {_f(326)}'
        f'L{_f(252)} {_f(347)}Q{_f(252)} {_f(355)} {_f(244)} {_f(355)}'
        f'L{_f(216)} {_f(355)}Q{_f(209)} {_f(355)} {_f(209)} {_f(347)}'
        f'L{_f(208)} {_f(326)}Q{_f(208)} {_f(318)} {_f(214)} {_f(318)}z'),
    (5, capsule((211, 318), (251, 318), 12))]

AUTHORED[('item', 'CHAIN')] = [
    (11, bead_chain((120, 392), (360, 392), (240, 462), 13, 11)),
    (11, f'M{_f(240)} {_f(446)}L{_f(258)} {_f(470)}L{_f(240)} {_f(496)}'
        f'L{_f(222)} {_f(470)}z'),
    (12, stroke([(240, 446), (258, 470), (240, 496), (222, 470), (240, 446)], 7)),
    (14, circle(240, 471, 20))]

AUTHORED[('item', 'STITCHES')] = [
    (8, stroke([(124, 268), (147, 299)], 6, samples=2)),
    (8, capsule((132, 272), (120, 280), 7) + capsule((138, 280), (126, 288), 7)
        + capsule((144, 288), (132, 296), 7)
        + capsule((150, 296), (138, 304), 7))]

AUTHORED[('item', 'TATTOO')] = [
    (14, heart(153, 290, 16))]

AUTHORED[('item', 'MUSTACHE')] = [
    (14, stroke([(198, 262), (240, 257), (282, 262)], 32)),
    (14, stroke([(196, 263), (176, 252), (163, 257), (160, 270), (169, 278)], 30)),
    (14, stroke([(284, 263), (304, 252), (317, 257), (320, 270), (311, 278)], 30))]

AUTHORED[('item', 'NOOSE')] = [
    (12, capsule((137, 0), (137, 344), 11)),
    (12, ring(238, 374, 104, 40, 22, rot=-8)),
    (12, circle(137, 347, 20) + circle(143, 361, 14)),
    (12, capsule((330, 400), (370, 432), 11)),
    (12, capsule((368, 428), (378, 438), 6)
        + capsule((364, 432), (370, 446), 6))]
