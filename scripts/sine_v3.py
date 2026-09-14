#!/usr/bin/env python3
"""sine v3 — one continuous tilted-sine curve with softened cube-root growth.

Mathematical specification (2026-09-14 handoff, binding):
    lambda = 955 * sqrt(b / 450)                     (b = actual net backing)
    R_target = b + 10 * lambda
    x(R) = (R - b) / lambda
    s(x) = x - sin(2*pi*x) / (2*pi)
    H(z) = sign(z) * (cbrt(1 + |z|) - 1)
    K = ln(1000) / (cbrt(11) - 1)
    P(R) = P_L * exp(K * H(s(x(R))))                 (P_L = 0.000075 default)
    Q(R) = integral_0^R dr / P(r) = (lambda/P_L) * (F(x(R)) - F(x(0)))
    F(x) = integral_0^x exp(-K*H(s(t))) dt

This script generates:
  src/SineV3Knots.sol     — canonical quarter-wave |F| knots, x in [-16, 64]
                            (321 values, WAD, floored; balanced lookup tree)
  test/SineV3Fixtures.sol — independent verification vectors

Reference method: 70-digit Decimal. Knots integrate each quarter-wave cell
with 16-point Gauss-Legendre cumulatively, certified against split-cell
recomputation. Fixture supplies use tanh-sinh (double-exponential) quadrature — a
different method than the knot-building GL16 — with level-doubling
convergence; fixture prices at wave milestones are closed-form. Nothing here is derived from Solidity output.

--check regenerates both files and verifies byte-for-byte equality.
No third-party dependencies. Run from the repository root.
"""
from decimal import Decimal as D, localcontext, getcontext
import argparse
import math
from pathlib import Path

getcontext().prec = 70

PI = D('3.14159265358979323846264338327950288419716939937510582097494459230781640628620899862803482534211706798')
TWO_PI = 2 * PI
WAD = 10 ** 18
WAD_D = D(WAD)

# spec constants
P_L_WEI = 75_000_000_000_000            # 0.000075 mixETH/PSP
LAM_REF_WEI = 955 * WAD                 # reference wavelength at b = 450 mixETH
B_REF_WEI = 450 * WAD                   # reference net backing
WAVES = 10                              # waves to target
GROWTH_MULT = D(1000)

# canonical table domain (dimensionless waves); prelaunch edge -16 caps net
# boot at ~518,841 mixETH (arithmetic capacity, far above any economic cap),
# postlaunch edge +64 caps price at ~1,927 mixETH/PSP for every round.
XMIN, XMAX = -16, 64
KNOT_COUNT = (XMAX - XMIN) * 4 + 1      # 321
ZERO_INDEX = -XMIN * 4                  # index of x = 0


def cbrt(x: D) -> D:
    if x == 0:
        return D(0)
    g = x ** (D(1) / 3)
    for _ in range(2):
        g = (2 * g + x / (g * g)) / 3
    return g


K_DEC = GROWTH_MULT.ln() / (cbrt(D(1) + WAVES) - 1)
K_WAD = int((K_DEC * WAD_D).to_integral_value(rounding='ROUND_HALF_EVEN'))


def sine(x: D) -> D:
    x = x % TWO_PI
    if x > PI:
        x -= TWO_PI
    term = total = x
    x2 = x * x
    for n in range(1, 90):
        term *= -x2 / D(2 * n * (2 * n + 1))
        total += term
        if abs(term) < D('1e-75'):
            break
    return total


def s_of(x: D) -> D:
    return x - sine(TWO_PI * x) / TWO_PI


def H(z: D) -> D:
    if z == 0:
        return D(0)
    if z > 0:
        return cbrt(D(1) + z) - 1
    return -(cbrt(D(1) - z) - 1)


def density(x: D) -> D:
    return (-K_DEC * H(s_of(x))).exp()


def price_dec(x: D) -> D:
    return (K_DEC * H(s_of(x))).exp()   # multiple of P_L


def legendre_gauss(n: int):
    nodes, weights = [], []
    for i in range(1, n + 1):
        x = D(math.cos(math.pi * (i - 0.25) / (n + 0.5)))
        dp = D(1)
        for _ in range(100):
            p0, p1 = D(1), x
            for k in range(2, n + 1):
                p0, p1 = p1, ((2 * k - 1) * x * p1 - (k - 1) * p0) / k
            dp = n * (x * p1 - p0) / (x * x - 1)
            dx = p1 / dp
            x -= dx
            if abs(dx) < D('1e-75'):
                break
        nodes.append(x)
        weights.append(2 / ((1 - x * x) * dp * dp))
    nodes = [(1 + v) / 2 for v in nodes]
    weights = [w / 2 for w in weights]
    pairs = sorted(zip(nodes, weights))
    return [p[0] for p in pairs], [p[1] for p in pairs]


GL16 = legendre_gauss(16)


def gl(rule, a: D, b: D, fn) -> D:
    nodes, weights = rule
    h = b - a
    total = D(0)
    for u, w in zip(nodes, weights):
        total += w * fn(a + h * u)
    return h * total


QUART = D(1) / 4


def build_knots():
    """Cumulative GL16 |F| at quarter-wave knots; split-cell certified.

    Returns list of INTEGER WAD values (floored), index 0..320, x = (i-64)/4.
    """
    frac = {}
    frac[0] = D(0)
    cert_worst = D(0)
    for k in range(0, XMAX * 4):
        a = D(k) * QUART
        whole = gl(GL16, a, a + QUART, density)
        h1 = gl(GL16, a, a + QUART / 2, density)
        h2 = gl(GL16, a + QUART / 2, a + QUART, density)
        err = abs(whole - (h1 + h2))
        if err > abs(whole) * D('1e-27') + D('1e-54'):
            raise SystemExit(f'GL16 not converged on cell {k}: {err:.2e}')
        cert_worst = max(cert_worst, err / (abs(whole) + D('1e-60')))
        frac[k + 1] = frac[k] + whole
    for k in range(0, XMIN * 4 - 1, -1):
        a = D(k) * QUART
        whole = gl(GL16, a, a + QUART, density)
        h1 = gl(GL16, a, a + QUART / 2, density)
        h2 = gl(GL16, a + QUART / 2, a + QUART, density)
        err = abs(whole - (h1 + h2))
        if err > abs(whole) * D('1e-27') + D('1e-54'):
            raise SystemExit(f'GL16 not converged on cell {k}: {err:.2e}')
        cert_worst = max(cert_worst, err / (abs(whole) + D('1e-60')))
        frac[k] = frac[k + 1] - whole
    assert frac[0] == 0
    knots = []
    for i in range(KNOT_COUNT):
        qi = i - ZERO_INDEX
        v = frac[qi]
        if v >= 0:
            knots.append(int(v * WAD_D))            # floor toward zero
        else:
            # negative side: store |F|; floor of |F| == ceil of F (toward zero)
            knots.append(int(-v * WAD_D))
    # invariants the Solidity side relies on: |F| is V-shaped around x = 0
    # (F itself is strictly increasing; stored magnitudes shrink toward the
    # zero index, then grow). No flat steps exist in-domain.
    for i in range(ZERO_INDEX):
        assert knots[i + 1] <= knots[i], f'|F| not shrinking toward 0 at {i}'
    for i in range(ZERO_INDEX, KNOT_COUNT - 1):
        assert knots[i + 1] > knots[i], f'|F| not strictly growing at {i}'
    assert knots[ZERO_INDEX] == 0
    return knots, cert_worst


def lam_wei(b_wei: int) -> int:
    """lambdaWei = floorSqrt(fullMulDiv((955e18)^2, bWei, 450e18))."""
    return math.isqrt((LAM_REF_WEI ** 2) * b_wei // B_REF_WEI)


def _dequad(a: D, b: D) -> D:
    """Tanh-sinh (double-exponential) quadrature of density over [a, b].

    Handles the C^5 kink of H(s(t)) at t = 0 sitting on cell boundaries —
    node clustering at the endpoints makes the kink harmless. Independent
    of both the on-chain GL8 and the knot-building GL16.
    """
    if b <= a:
        return D(0)
    half = (b - a) / 2
    mid = (a + b) / 2
    half_pi = PI / 2
    prev = None
    h = D('0.2')
    for _ in range(6):
        total = D(0)
        k = 0
        while True:
            if k == 0:
                w = half * half_pi * h          # cosh(0)=1, sinh(0)=0
                total += w * density(mid)
                k = 1
                continue
            t = D(k) * h
            et = t.exp()
            sinh_t = (et - 1 / et) / 2
            u = half_pi * sinh_t
            eu = u.exp()
            cosh_u = (eu + 1 / eu) / 2
            denom = cosh_u * cosh_u
            if denom == 0:
                break
            w = half * half_pi * h * ((et + 1 / et) / 2) / denom
            if w < D('1e-52'):
                break
            tanh_u = (eu - 1 / eu) / (eu + 1 / eu)
            total += w * (density(mid + half * tanh_u) + density(mid - half * tanh_u))
            k += 1
            if k > 2000:
                raise SystemExit('dequad node overflow')
        if prev is not None and abs(total - prev) <= abs(total) * D('1e-34') + D('1e-44'):
            return total
        prev = total
        h = h / 2
    raise SystemExit(f'dequad did not converge on [{a}, {b}]')


def Q_ref(b_wei: int, lam_w: int, R_wei: int) -> int:
    """Cumulative supply in PSP-wei via the tanh-sinh path (independent)."""
    x0 = -D(b_wei) / D(lam_w)
    xR = (D(R_wei) - D(b_wei)) / D(lam_w)
    total = D(0)
    cur = x0
    while cur < xR:
        # next quarter boundary above cur (floor, so cells never straddle t=0)
        nxt = (D(math.floor(cur * 4)) + 1) * QUART
        if nxt <= cur or nxt > xR:
            nxt = xR
        total += _dequad(cur, nxt)
        cur = nxt
    q = D(lam_w) * total * WAD / D(P_L_WEI)   # PSP-wei
    return int(q)


def price_wei(b_wei: int, lam_w: int, R_wei: int) -> int:
    x = (D(R_wei) - D(b_wei)) / D(lam_w)
    return int(price_dec(x) * D(P_L_WEI))


def gen_knots_sol(knots) -> str:
    lines = []
    lines.append('// SPDX-License-Identifier: MIT')
    lines.append('pragma solidity 0.8.26;')
    lines.append('')
    lines.append('// Generated by scripts/sine_v3.py — DO NOT HAND-EDIT.')
    lines.append('// Canonical quarter-wave knots of F(x) = int_0^x exp(-K*H(s(t))) dt,')
    lines.append('// K = ln(1000)/(cbrt(11)-1). Domain x in [-16, +64] waves, 321 knots.')
    lines.append('// Entry i is |F((i - 64)/4)| in WAD, floored: F(x) = x >= 0 ? +v : -v.')
    lines.append('// Reference: 70-digit Decimal, cumulative 16-point Gauss-Legendre,')
    lines.append('// split-cell certified below 1e-27 relative. F(0) = 0 at index 64.')
    lines.append('library SineV3Knots {')
    lines.append(f'    uint256 internal constant COUNT = {KNOT_COUNT};')
    lines.append(f'    uint256 internal constant ZERO_INDEX = {ZERO_INDEX};')
    lines.append(f'    /// @dev K = ln(1000)/(cbrt(11)-1) = 5.64368271363719722487..., WAD, round-half-even.')
    lines.append(f'    uint256 internal constant K_WAD = {K_WAD};')
    lines.append('')
    lines.append('    /// @dev |F| at x = (i - 64)/4, WAD. Balanced dispatch keeps reads O(log n).')
    lines.append('    function knot(uint256 i) internal pure returns (uint256) {')
    lines.extend(_tree(knots, 0, KNOT_COUNT, 2))
    lines.append('    }')
    lines.append('}')
    return '\n'.join(lines) + '\n'


def _tree(knots, lo, hi, indent) -> list:
    """Balanced if-tree over [lo, hi)."""
    pad = ' ' * indent
    if hi - lo == 1:
        return [f'{pad}return {knots[lo]};']
    mid = (lo + hi) // 2
    out = [f'{pad}if (i < {mid}) {{']
    out.extend(_tree(knots, lo, mid, indent + 4))
    out.append(f'{pad}}} else {{')
    out.extend(_tree(knots, mid, hi, indent + 4))
    out.append(f'{pad}}}')
    return out


def gen_fixtures_sol() -> str:
    rows = []
    # (boot_wei, lam_wei, R_wei, price_wei, supply_wei)
    def add(b, R, with_q=True):
        lam = lam_wei(b)
        p = price_wei(b, lam, R)
        q = Q_ref(b, lam, R) if with_q else 0
        rows.append((b, lam, R, p, q))

    # 11 baseline milestones + P(0)
    b = 450 * WAD
    lam = lam_wei(b)
    assert lam == 955 * WAD
    for n in range(11):
        add(b, b + n * lam)
    add(b, 0)
    # edge/cell samples at baseline
    add(b, b + lam // 4)
    add(b, b + lam // 4 + 1)
    add(b, b + lam // 4 - 1)
    add(b, b + 10 * lam + 12345)
    # small pools
    add(1, 0)
    add(1, 1)
    add(90 * WAD, 0)
    add(90 * WAD, 90 * WAD)
    add(90 * WAD, 90 * WAD + lam_wei(90 * WAD) * 3)
    # mid/large
    add(5_000 * WAD, 5_000 * WAD)
    add(100_000 * WAD, 100_000 * WAD)
    add(100_000 * WAD, 100_000 * WAD + 7 * lam_wei(100_000 * WAD))

    lines = []
    lines.append('// SPDX-License-Identifier: MIT')
    lines.append('pragma solidity 0.8.26;')
    lines.append('')
    lines.append('// Generated by scripts/sine_v3.py — DO NOT HAND-EDIT.')
    lines.append('// Independent Decimal reference vectors for the v3 curve.')
    lines.append('// Prices: closed form at the sample reserves. Supplies: composite')
    lines.append('// tanh-sinh double-exponential quadrature (method-independent from the')
    lines.append("// on-chain GL8 + knot table). Row: (boot, lam, R, priceWad, supplyPSPWei).")
    lines.append('// supplyPSPWei == 0 marks a price-only row.')
    lines.append('library SineV3Fixtures {')
    lines.append(f'    struct Row {{ uint256 boot; uint256 lam; uint256 R; uint256 price; uint256 supply; }}')
    lines.append(f'    function rows() internal pure returns (Row[{len(rows)}] memory r) {{')
    for i, (bb, ll, rr, pp, qq) in enumerate(rows):
        lines.append(f'        r[{i}] = Row({bb}, {ll}, {rr}, {pp}, {qq});')
    lines.append('    }')
    lines.append('}')
    return '\n'.join(lines) + '\n', rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--print-k', action='store_true')
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    with localcontext() as ctx:
        ctx.prec = 70
        knots, cert = build_knots()
        if args.print_k:
            print('K_WAD =', K_WAD)
            print('worst split-cell cert:', f'{cert:.2e}')
            print('knots:', len(knots), 'last |F| wad:', knots[-1])
            return
        knots_sol = gen_knots_sol(knots)
        fixtures_sol, _ = gen_fixtures_sol()
    targets = {
        root / 'src/SineV3Knots.sol': knots_sol,
        root / 'test/SineV3Fixtures.sol': fixtures_sol,
    }
    if args.check:
        for path, want in targets.items():
            if not path.exists() or path.read_text() != want:
                raise SystemExit(f'{path.name} stale; run scripts/sine_v3.py')
        print('sine v3 generated files match.')
    else:
        for path, want in targets.items():
            path.write_text(want)
            print(f'Wrote {path}')


if __name__ == '__main__':
    main()
