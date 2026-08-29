#!/usr/bin/env python3
"""SineMath oracle — float64/WAD mirror of the Solidity library, certified
against a fine Simpson reference, emitting test vectors as Solidity.

Run:  python3 scripts/sine_oracle.py   →  writes test/SineVectors.sol
NEVER hand-edit the generated file (deploy-library convention).
"""
import math

WAD = 10**18
PI_WAD = 3141592653589793238
TWO_PI_WAD = 6283185307179586476
HALF_PI_WAD = 1570796326794896619

GL8_U = [19855071751231912, 101666761293186640, 237233795041835520, 408282678752175040,
         591717321247824896, 762766204958164480, 898333238706813312, 980144928248768128]
GL8_W = [50614268145188264, 111190517226687232, 156853322938943584, 181341891689180896,
         181341891689180896, 156853322938943584, 111190517226687232, 50614268145188264]

def mulWad(a, b): return a * b // WAD
def divWad(a, b): return a * WAD // b
def expWad(x: int) -> int:   # x in WAD (may be negative) — float approximation of solady
    v = math.exp(x / WAD)
    if v > 1e18 * 1.9e18: raise OverflowError
    return int(v * WAD)
def lnWad(x: int) -> int:
    return int(math.log(x / WAD) * WAD)

def sin_wad(x: int) -> int:
    if x >= TWO_PI_WAD: x -= TWO_PI_WAD
    if x > PI_WAD:
        y = x - PI_WAD
        return -sin_wad(y if y <= HALF_PI_WAD else PI_WAD - y)
    if x > HALF_PI_WAD: x = PI_WAD - x
    t = mulWad(x, x)
    s = WAD
    term = mulWad(WAD, mulWad(t, 166666666666666667))  # /6 — matches solidity constant
    s -= term
    for d in (20, 42, 72, 110, 156, 210, 272, 342, 420):
        term = mulWad(term, mulWad(t, WAD // d))
        s += term if d in (20, 72, 156, 272, 420) else -term  # even terms +, odd −
    return mulWad(x, s)

class C:  # curve mirror
    p0: int; preK: int; boot: int; span: int; segWidth: int; lam: int
    B: int; slope: int; amp: int; pTop: int; tailSlope: int; q0: int; qTop: int
    cp: list

def materialize(p0, preK, magM, lnTop, ampBps, boot):
    c = C()
    c.p0, c.preK, c.boot = p0, preK, boot
    c.span = mulWad(magM, boot); c.segWidth = c.span // 12; c.lam = c.segWidth * 4
    preArg = mulWad(preK, boot)
    c.B = mulWad(p0, expWad(preArg))
    c.slope = divWad(lnTop, c.span)
    c.amp = mulWad(ampBps * 10**14, divWad(mulWad(c.slope, c.lam), TWO_PI_WAD))
    c.pTop = mulWad(c.B, expWad(lnTop))
    c.tailSlope = mulWad(c.slope, c.pTop)
    c.q0 = divWad(WAD - expWad(-preArg), mulWad(preK, p0))
    c.cp = [0] * 13
    acc = 0
    for j in range(1, 13):
        a = c.boot + (j - 1) * c.segWidth; b = c.boot + j * c.segWidth
        acc += gl8(c, a, b); c.cp[j] = acc
    c.qTop = c.q0 + c.cp[12]
    return c

def price_at(c, R):
    if R <= c.boot:
        return mulWad(c.p0, expWad(mulWad(c.preK, R)))
    top = c.boot + c.span
    if R <= top:
        u = (R - c.boot) % c.lam
        sinv = sin_wad(PI_WAD + mulWad(u, divWad(TWO_PI_WAD, c.lam)))
        ampTerm = -mulWad(c.amp, -sinv) if sinv < 0 else mulWad(c.amp, sinv)
        arg = mulWad(c.slope, R - c.boot) + ampTerm
        return mulWad(c.B, expWad(arg))
    return c.pTop + mulWad(c.tailSlope, R - top)

def gl8(c, a, b):
    if b <= a: return 0
    w = b - a
    acc = 0
    for i in range(8):
        acc += mulWad(GL8_W[i], divWad(WAD, price_at(c, a + mulWad(w, GL8_U[i]))))
    return mulWad(w, acc)

def supply_at(c, R):
    if R <= c.boot:
        return divWad(WAD - expWad(-mulWad(c.preK, R)), mulWad(c.preK, c.p0))
    if R >= c.boot + c.span:
        delta = R - (c.boot + c.span)
        lnArg = WAD + divWad(mulWad(c.tailSlope, delta), c.pTop)
        return c.qTop + divWad(lnWad(lnArg), c.tailSlope)
    j = (R - c.boot) // c.segWidth
    a = c.boot + j * c.segWidth
    return c.q0 + c.cp[j] + gl8(c, a, R)

def reserve_at(c, qT):
    if qT <= c.q0:
        x = mulWad(mulWad(qT, c.preK), c.p0)
        if x >= WAD: return c.boot
        return divWad(-lnWad(WAD - x), c.preK)
    if qT >= c.qTop:
        dq = qT - c.qTop
        eu = expWad(mulWad(c.tailSlope, dq))
        return c.boot + c.span + divWad(mulWad(c.pTop, eu - WAD), c.tailSlope)
    local = qT - c.q0
    j = 0
    for k in range(1, 13):
        if c.cp[k] < local: j = k
        else: break
    a = c.boot + j * c.segWidth
    L = local - c.cp[j]
    segSup = c.cp[j + 1] - c.cp[j]
    R = a + mulWad(c.segWidth, divWad(L, segSup if segSup else 1))
    for _ in range(8):
        have = gl8(c, a, R)
        if have == L: break
        step = mulWad(abs(L - have), price_at(c, R))
        if L > have: R += step
        else: R = R - step if R > step else a
    guard = 0
    while gl8(c, a, R) > L and guard < 256:
        R -= 1; guard += 1
    return R

def buy_out(c, R, spend):
    out = supply_at(c, R + spend) - supply_at(c, R)
    if out <= 1: return 0
    out -= 1
    return out * 9999 // 10000

def sell_out(c, R, psp):
    q = supply_at(c, R)
    if psp >= q: return R
    return R - reserve_at(c, q - psp)

# ─────────────── certification: GL8 vs fine Simpson ───────────────
def simpson_fine(c, a, b, n=20000):
    h = (b - a) / n
    s = 0.0
    Ra = a
    for i in range(n + 1):
        w = 1 if i in (0, n) else (4 if i % 2 else 2)
        s += w * (1.0 / (price_at(c, int(Ra + i * h)) / WAD))
    return s * h / 3 / WAD  # PSP WAD

def certify(c):
    worst = 0.0
    for j in range(12):
        a = c.boot + j * c.segWidth; b = a + c.segWidth
        g = gl8(c, a, b) / WAD
        f = simpson_fine(c, a, b)
        worst = max(worst, abs(g - f) / f)
    return worst

# ─────────────── vector generation ───────────────
P0 = 10_000_000_000_000            # 1e-5
PREK = int(math.log(10) / 500 * WAD)   # B = 1e-4 exactly at boot=500
MAGM = 20 * WAD
LNTOP = int(math.log(600) * WAD)   # pTop = B·600 = 0.06
AMPBPS = 10_000
BOOT = 500 * WAD

c = materialize(P0, PREK, MAGM, LNTOP, AMPBPS, BOOT)
worst = certify(c)
print(f"GL8 vs Simpson(20k) worst rel err: {worst:.2e}")
assert worst < 1e-9, "quadrature not certified"

span = c.span
Rs = [0, 50 * WAD, 250 * WAD, BOOT, BOOT + 1,
      BOOT + span // 12, BOOT + span // 6, BOOT + span // 4,
      BOOT + span // 3, BOOT + span // 2, BOOT + 2 * span // 3,
      BOOT + 3 * span // 4, BOOT + 5 * span // 6, BOOT + span - 1,
      BOOT + span, BOOT + span + 100 * WAD, BOOT + span + 1000 * WAD]
prices = [price_at(c, R) for R in Rs]
supplies = [supply_at(c, R) for R in Rs]

buy_cases = []
for R in (BOOT, BOOT + span // 6, BOOT + span // 2):
    for sp in (WAD, 10 * WAD, 100 * WAD, 1000 * WAD):
        buy_cases.append((R, sp, buy_out(c, R, sp)))

sell_cases = []
for R in (BOOT + span // 6, BOOT + span // 2):
    qloc = supply_at(c, R)
    for frac in (0, 1, 10):
        psp = (qloc * frac) // 1000
        if psp > 0:
            sell_cases.append((R, psp, sell_out(c, R, psp)))

sin_table = []
for k in range(32):
    ang = int(2 * math.pi * k / 32 * WAD) % TWO_PI_WAD
    sin_table.append((ang, int(round(math.sin(ang / WAD) * WAD))))

def fmt_u(x): return str(int(x))
lines = []
A = lines.append
A("// SPDX-License-Identifier: MIT")
A("pragma solidity 0.8.26;")
A("")
A("/// @title SineVectors — GENERATED by scripts/sine_oracle.py. Do not edit.")
A("library SineVectors {")
A("    uint256 internal constant P0 = " + fmt_u(P0) + ";")
A("    uint256 internal constant PREK = " + fmt_u(PREK) + ";")
A("    uint256 internal constant MAGM = " + fmt_u(MAGM) + ";")
A("    uint256 internal constant LNTOP = " + fmt_u(LNTOP) + ";")
A("    uint256 internal constant AMPBPS = " + str(AMPBPS) + ";")
A("    uint256 internal constant BOOT = " + fmt_u(BOOT) + ";")
A(f"    // materialized: B={c.B} pTop={c.pTop} q0={c.q0} qTop={c.qTop} span={c.span}")
A("    uint256 internal constant EXP_B = " + fmt_u(c.B) + ";")
A("    uint256 internal constant EXP_PTOP = " + fmt_u(c.pTop) + ";")
A("    uint256 internal constant EXP_Q0 = " + fmt_u(c.q0) + ";")
A("    uint256 internal constant EXP_QTOP = " + fmt_u(c.qTop) + ";")
A("    function EXP_CP() internal pure returns (uint256[13] memory r) {")
for i, v in enumerate(c.cp):
    A(f"        r[{i}] = {fmt_u(v)};")
A("    }")
A("    function GRID_R() internal pure returns (uint256[] memory r) { r = new uint256[](" + str(len(Rs)) + "); " +
  " ".join(f"r[{i}] = {fmt_u(v)};" for i, v in enumerate(Rs)) + " }")
A("    function GRID_P() internal pure returns (uint256[] memory r) { r = new uint256[](" + str(len(prices)) + "); " +
  " ".join(f"r[{i}] = {fmt_u(v)};" for i, v in enumerate(prices)) + " }")
A("    function GRID_Q() internal pure returns (uint256[] memory r) { r = new uint256[](" + str(len(supplies)) + "); " +
  " ".join(f"r[{i}] = {fmt_u(v)};" for i, v in enumerate(supplies)) + " }")
A("    // buy: [R, spend, out]")
A("    function BUY_R() internal pure returns (uint256[] memory r) { r = new uint256[](" + str(len(buy_cases)) + "); " +
  " ".join(f"r[{i}] = {fmt_u(b[0])};" for i, b in enumerate(buy_cases)) + " }")
A("    function BUY_SPEND() internal pure returns (uint256[] memory r) { r = new uint256[](" + str(len(buy_cases)) + "); " +
  " ".join(f"r[{i}] = {fmt_u(b[1])};" for i, b in enumerate(buy_cases)) + " }")
A("    function BUY_OUT() internal pure returns (uint256[] memory r) { r = new uint256[](" + str(len(buy_cases)) + "); " +
  " ".join(f"r[{i}] = {fmt_u(b[2])};" for i, b in enumerate(buy_cases)) + " }")
A("    // sell: [R, pspIn, mixETHOut]")
A("    function SELL_R() internal pure returns (uint256[] memory r) { r = new uint256[](" + str(len(sell_cases)) + "); " +
  " ".join(f"r[{i}] = {fmt_u(s[0])};" for i, s in enumerate(sell_cases)) + " }")
A("    function SELL_IN() internal pure returns (uint256[] memory r) { r = new uint256[](" + str(len(sell_cases)) + "); " +
  " ".join(f"r[{i}] = {fmt_u(s[1])};" for i, s in enumerate(sell_cases)) + " }")
A("    function SELL_OUT() internal pure returns (uint256[] memory r) { r = new uint256[](" + str(len(sell_cases)) + "); " +
  " ".join(f"r[{i}] = {fmt_u(s[2])};" for i, s in enumerate(sell_cases)) + " }")
A("    // sinWad: expected = float sin (±1e15 rel)")
A("    function SIN_X() internal pure returns (uint256[] memory r) { r = new uint256[](32); " +
  " ".join(f"r[{i}] = {fmt_u(s[0])};" for i, s in enumerate(sin_table)) + " }")
A("    function SIN_Y() internal pure returns (int256[] memory r) { r = new int256[](32); " +
  " ".join(f"r[{i}] = int256({fmt_u(s[1])});" for i, s in enumerate(sin_table)) + " }")
A("}")
open("test/SineVectors.sol", "w").write("\n".join(lines) + "\n")

print(f"B={c.B/WAD:.10f} pTop={c.pTop/WAD:.10f} q0={c.q0/WAD:.6f} qTop={c.qTop/WAD:.6f}")
print(f"checkpoints(PSP): {[round(v/WAD, 1) for v in c.cp]}")
print(f"price grid head: {[f'{p/WAD:.3e}' for p in prices[:5]]}")
print(f"buy cases: {len(buy_cases)}, sell cases: {len(sell_cases)}")
print("wrote test/SineVectors.sol")
