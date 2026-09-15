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

This script generates immutable cumulative anchors, authenticated shard
metadata, fixed-node Bernstein coefficients, and independent oracle fixtures.
The grid uses full waves outside +/-128, half waves inside that interval,
and quarter waves from -1 through +1. Its domain is [-580.5, 4096].

Anchors use 70-digit Decimal GL32 quadrature, checked against split cells.
Fixture supplies use a different method: tanh-sinh quadrature with successive
step refinement. Prices use the analytic sine, cube root, and exponential.
No fixture is derived from Solidity output. The separate primitive validator
checks integer density coefficients against the analytic function in every cell.

--check regenerates all files and requires byte-for-byte equality.
No third-party Python dependencies. Run from the repository root; cast is
required to hash the immutable data contracts.
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


def gl(rule, a: D, b: D, fn) -> D:
    nodes, weights = rule
    h = b - a
    total = D(0)
    for u, w in zip(nodes, weights):
        total += w * fn(a + h * u)
    return h * total


QUART = D(1) / 4


def lam_wei(b_wei: int) -> int:
    """lambdaWei = floorSqrt(fullMulDiv((955e18)^2, bWei, 450e18))."""
    return math.isqrt((LAM_REF_WEI ** 2) * b_wei // B_REF_WEI)


def _dequad(a: D, b: D) -> D:
    """Tanh-sinh (double-exponential) quadrature of density over [a, b].

    Handles the C^5 kink of H(s(t)) at t = 0 sitting on cell boundaries —
    node clustering at the endpoints makes the kink harmless. Independent
    of both the on-chain Bernstein interpolation and the GL32 anchors.
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


def q_reference_decimal(b_wei: int, lam_w: int, R_wei: int) -> D:
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
    return D(lam_w) * total * WAD / D(P_L_WEI)   # PSP-wei


def Q_ref(b_wei: int, lam_w: int, R_wei: int) -> int:
    return int(q_reference_decimal(b_wei, lam_w, R_wei))


def price_wei(b_wei: int, lam_w: int, R_wei: int) -> int:
    x = (D(R_wei) - D(b_wei)) / D(lam_w)
    return int(price_dec(x) * D(P_L_WEI))


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
    lines.append("// on-chain Bernstein interpolation and GL32 anchors). Row: (boot, lam, R, priceWad, supplyPSPWei).")
    lines.append('// supplyPSPWei == 0 marks a price-only row.')
    lines.append('library SineV3Fixtures {')
    lines.append(f'    struct Row {{ uint256 boot; uint256 lam; uint256 R; uint256 price; uint256 supply; }}')
    lines.append(f'    function rows() internal pure returns (Row[{len(rows)}] memory r) {{')
    for i, (bb, ll, rr, pp, qq) in enumerate(rows):
        lines.append(f'        r[{i}] = Row({bb}, {ll}, {rr}, {pp}, {qq});')
    lines.append('    }')
    lines.append('}')
    return '\n'.join(lines) + '\n', rows


def gen_sell_fixtures_sol():
    # Invert a local tanh-sinh integral, retaining the fractional cumulative
    # supply until the comparison. No on-chain primitive or table is used.
    rows = []
    cases = [(158_000_000*WAD, None, WAD, 10**35),
             (10**12, 32, None, 10**12), (10**12, 63, None, 10**12)]
    for boot, wave, reserve, sold in cases:
        lam = lam_wei(boot)
        reserve = reserve if reserve is not None else boot+wave*lam
        q = q_reference_decimal(boot, lam, reserve)
        target = int(q)-sold
        x = (D(reserve)-boot)/lam
        low = 0
        high = min(reserve, math.ceil(D(sold+1)*price_dec(x)*P_L_WEI/WAD)+1)
        while high-low > 1:
            out = (low+high)//2
            dq = D(lam)*_dequad((D(reserve-out)-boot)/lam, x)*WAD/P_L_WEI
            if int(q-dq) < target:
                high = out
            else:
                low = out
        rows.append((boot, lam, reserve, sold, int(q), low))
    lines = ['// SPDX-License-Identifier: MIT', 'pragma solidity 0.8.26;', '',
             '// Generated by scripts/sine_v3.py. Do not edit by hand.',
             '// Independent tanh-sinh cumulative supply and local inverse.',
             'library SineV3SellFixtures {',
             '    struct Row { uint256 boot; uint256 lam; uint256 reserve; uint256 sold; uint256 supply; uint256 grossOut; }',
             '    function rows() internal pure returns (Row[3] memory r) {']
    for i, row in enumerate(rows):
        lines.append(f'        r[{i}] = Row('+', '.join(map(str, row))+');')
    lines += ['    }', '}']
    return '\n'.join(lines)+'\n'


# Monotone v3 cumulative primitive. Query interpolation uses canonical nodes,
# not nodes whose positions change with the queried reserve endpoint.
PRIMITIVE_SCALE = 10 ** 36
BERNSTEIN_DEGREE = 16
MATRIX_SCALE = 10 ** 27
PRIMITIVE_XS = ([D('-580.5')] + [D(n) for n in range(-580, -127)]
                + [D(n) / 2 for n in range(-255, -1)]
                + [D(n) / 4 for n in range(-3, 5)]
                + [D(n) / 2 for n in range(3, 257)]
                + [D(n) for n in range(129, 4097)])
PRIMITIVE_ZERO = PRIMITIVE_XS.index(D(0))


def invert_decimal(matrix):
    n = len(matrix)
    a = [row[:] + [D(i == j) for j in range(n)] for i, row in enumerate(matrix)]
    for col in range(n):
        pivot = max(range(col, n), key=lambda i: abs(a[i][col]))
        a[col], a[pivot] = a[pivot], a[col]
        divisor = a[col][col]
        a[col] = [x / divisor for x in a[col]]
        for i in range(n):
            if i != col:
                factor = a[i][col]
                a[i] = [a[i][j] - factor * a[col][j] for j in range(2 * n)]
    return [row[n:] for row in a]


def bernstein_matrix():
    n = BERNSTEIN_DEGREE
    nodes = [(1 - sine(PI / 2 + PI * D(i) / n)) / 2 for i in range(n + 1)]
    nodes[0], nodes[-1] = D(0), D(1)
    matrix = []
    for t in nodes:
        if t == 0 or t == 1:
            matrix.append([D(j == (0 if t == 0 else n)) for j in range(n + 1)])
        else:
            matrix.append([D(math.comb(n, j)) * t**j * (1-t)**(n-j) for j in range(n+1)])
    return nodes, invert_decimal(matrix)


def gen_bernstein_sol():
    nodes, matrix = bernstein_matrix()
    # Reflection symmetry halves the constant matrix. Runtime rows 9..16
    # reverse both the row index and the density sample index.
    values = [int((x * MATRIX_SCALE).to_integral_value(rounding='ROUND_HALF_EVEN'))
              for row in matrix[:9] for x in row]
    packed = b''.join(v.to_bytes(16, 'big', signed=True) for v in values).hex()
    phases = []
    for kind in range(7):
        for t in nodes:
            frac = t if kind == 0 else (t / 2 if kind == 1 else ((1+t)/2 if kind == 2 else (kind-3+t)/4))
            phases.append(int((s_of(frac)*WAD_D).to_integral_value(rounding='ROUND_HALF_EVEN')))
    phase_hex = b''.join(v.to_bytes(8, 'big') for v in phases).hex()
    return f'''// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Generated by scripts/sine_v3.py. Do not edit by hand.
// Inverse Bernstein interpolation matrix at 17 Chebyshev-Lobatto nodes.
// Matrix entries use signed 128-bit integers at 1e27 precision.
library SineV3Bernstein {{
    uint256 internal constant DEGREE = 16;
    uint256 internal constant MATRIX_SCALE = 1e27;
    bytes internal constant MATRIX = hex"{packed}";
    // Canonical s offsets: one whole-wave, two half-wave, four quarter-wave sets.
    bytes internal constant PHASES = hex"{phase_hex}";

    function matrix() internal pure returns (bytes memory) {{ return MATRIX; }}
    function phases() internal pure returns (bytes memory) {{ return PHASES; }}
}}
'''


def build_primitive_anchors():
    # GL32 handles a complete wave. Splitting the interval independently
    # checks convergence; neither step copies on-chain interpolation.
    rule = legendre_gauss(32)
    cells = []
    worst = D(0)
    for i, (a, b) in enumerate(zip(PRIMITIVE_XS, PRIMITIVE_XS[1:])):
        whole = gl(rule, a, b, density)
        mid = (a+b)/2
        split = gl(rule, a, mid, density) + gl(rule, mid, b, density)
        err = abs(whole-split)
        rel = err / max(abs(split), D('1e-100'))
        # Integral error is far below the required 1e-9 supply goal.
        # Use the split result for the canonical cumulative anchors.
        if rel > D('1e-24'):
            raise SystemExit(f'primitive quadrature not converged in cell {i}: {rel}')
        worst = max(worst, rel)
        cells.append(split)
        if i and i % 512 == 0:
            print(f'primitive anchors: {i}/{len(PRIMITIVE_XS)-1}', flush=True)
    f = [D(0)] * len(PRIMITIVE_XS)
    for i in range(PRIMITIVE_ZERO, len(cells)):
        f[i+1] = f[i] + cells[i]
    for i in range(PRIMITIVE_ZERO-1, -1, -1):
        f[i] = f[i+1] - cells[i]
    values = [int(abs(x) * PRIMITIVE_SCALE) for x in f]
    signed = [-v if i < PRIMITIVE_ZERO else v for i, v in enumerate(values)]
    if not all(a <= b for a, b in zip(signed, signed[1:])):
        raise SystemExit('primitive anchors are not monotone')
    print(f'primitive anchors: {len(values)}, split-cell relative error {worst:.3e}', flush=True)
    return values


def gen_primitive_data(values):
    import subprocess
    import json
    records = [v.to_bytes(24 if i < PRIMITIVE_ZERO else 16, 'big') for i, v in enumerate(values)]
    shards, starts, cursor = [], [], 0
    for record in records:
        if not shards or len(shards[-1]) + len(record) > 22000:
            shards.append(bytearray())
            starts.append(cursor)
        shards[-1].extend(record)
        cursor += len(record)
    if len(shards) != 4:
        raise SystemExit(f'expected four data shards, got {len(shards)}')
    hashes = [subprocess.check_output(['cast', 'keccak', '0x00'+bytes(x).hex()], text=True).strip() for x in shards]
    contracts = ['// SPDX-License-Identifier: MIT', 'pragma solidity 0.8.26;', '',
                 '// Generated by scripts/sine_v3.py. Do not edit by hand.',
                 '// Each constructor returns immutable STOP-prefixed primitive data.']
    for i, blob in enumerate(shards):
        contracts += [f'contract SineV3Data{i} {{', '    constructor() {',
                      f'        bytes memory data = hex"00{bytes(blob).hex()}";',
                      '        assembly ("memory-safe") { return(add(data, 32), mload(data)) }', '    }', '}', '']
    contracts += ['/// @notice Deployment utility for scripts and tests only.',
                  '/// Do not link this utility into production constructor code.',
                  'library SineV3Data {', '    function deploy() internal returns (address[4] memory shards) {']
    for i in range(4):
        contracts.append(f'        shards[{i}] = address(new SineV3Data{i}());')
    contracts += ['    }', '}']
    info = ['// SPDX-License-Identifier: MIT', 'pragma solidity 0.8.26;', '',
            '// Generated by scripts/sine_v3.py. Do not edit by hand.',
            'library SineV3DataInfo {', f'    uint256 internal constant COUNT = {len(values)};',
            f'    uint256 internal constant ZERO_INDEX = {PRIMITIVE_ZERO};',
            f'    uint256 internal constant FIRST_HALF_INDEX = {PRIMITIVE_XS.index(D(-128))};',
            f'    uint256 internal constant FIRST_QUARTER_INDEX = {PRIMITIVE_XS.index(D(-1))};',
            f'    uint256 internal constant LAST_QUARTER_INDEX = {PRIMITIVE_XS.index(D(1))};',
            f'    uint256 internal constant LAST_HALF_INDEX = {PRIMITIVE_XS.index(D(128))};',
            f'    uint256 internal constant NEGATIVE_BYTES = {PRIMITIVE_ZERO*24};']
    for i in range(4):
        info += [f'    bytes32 internal constant HASH{i} = {hashes[i]};',
                 f'    uint256 internal constant START{i} = {starts[i]};',
                 f'    uint256 internal constant BYTES{i} = {len(shards[i])+1};']
    info += ['}']
    metadata = {'scale': str(PRIMITIVE_SCALE), 'knots': len(values),
                'minimumPhase': '-580.5', 'maximumPhase': '4096',
                'shards': [{'contract': f'SineV3Data{i}', 'hash': hashes[i], 'bytes': len(shards[i])+1}
                           for i in range(4)]}
    return '\n'.join(contracts)+'\n', '\n'.join(info)+'\n', json.dumps(metadata, indent=2)+'\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--print-k', action='store_true')
    ap.add_argument('--primitive-only', action='store_true')
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    with localcontext() as ctx:
        ctx.prec = 70
        if args.print_k:
            print('K_WAD =', K_WAD)
            return
        fixtures_sol = None
        sell_fixtures_sol = None
        if not args.primitive_only:
            fixtures_sol, _ = gen_fixtures_sol()
            sell_fixtures_sol = gen_sell_fixtures_sol()
        primitive_values = build_primitive_anchors()
        data_sol, data_info_sol, metadata = gen_primitive_data(primitive_values)
        bernstein_sol = gen_bernstein_sol()
    targets = {
        root / 'test/SineV3Fixtures.sol': fixtures_sol,
        root / 'test/SineV3SellFixtures.sol': sell_fixtures_sol,
        root / 'src/SineV3Data.sol': data_sol,
        root / 'src/SineV3DataInfo.sol': data_info_sol,
        root / 'src/SineV3Bernstein.sol': bernstein_sol,
        root / 'scripts/sine_v3_data.json': metadata,
    }
    targets = {path: want for path, want in targets.items() if want is not None}
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
