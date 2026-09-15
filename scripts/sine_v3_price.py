#!/usr/bin/env python3
"""Generate and check the monotone price coefficients and independent vectors.

This generator uses 90-digit Decimal arithmetic. It does not import the curve
knots, on-chain output, or the supply approximation. The first quarter uses the
sine Taylor polynomial through degree 17. The second uses the cosine polynomial
through degree 18. Power coefficients convert exactly to Bernstein coefficients
before integer quantization at 1e27. The shared quarter point and half point use
their exact analytic values (the former floored at 1e27).

The alternating Taylor remainder bounds each polynomial error on its quarter.
Replacing an endpoint control changes a Bernstein polynomial by at most that
control's change. Thus twice the Taylor remainder bounds the real approximation
error. Floor control quantization contributes <1e-27. The 18 de Casteljau levels
contribute <18e-27. The final phase floor contributes <1e-18 waves. Total phase
error is <1.5e-14 waves. H has derivative at most1/3, so log-price error from this
phase is <2.9e-14. Exact integer cube-root rounding adds <6e-18 to log-price.

All controls are nondecreasing. Integer interpolation L(a,b,t)=
a+floor((b-a)*t/1e18) is monotone in a, b, and t when a<=b. Adjacent interpolated
controls remain ordered. Induction proves the entire evaluation monotone in t.
Shared endpoints and exact reflection preserve order across every quarter,
wave, and sign boundary.

The exponential uses degree20 positive Taylor coefficients at1e36. For
0<=r<ln2 its remainder is below 2*(ln2)^21/21!, below2e-23. The floored polynomial
is below2 at the upper seam and equals1 at the lower seam. Exact binary scaling
therefore preserves order. For any supported scale<=uint256.max/2 with a
nonzero representable result, |k|<=256, so floor(ln2*1e18) range reduction adds
less than256e-18 relative error. The total price error before the last integer
floor is below4e-14 relative. Tests allow1e-11 relative plus one final price unit.
"""
from decimal import Decimal as D, getcontext
from math import factorial, comb
from pathlib import Path
import argparse
import re

getcontext().prec = 90
WAD = 10**18
CONTROL_SCALE = 10**27
EXP_SCALE = 10**36
PI = D('3.14159265358979323846264338327950288419716939937510582097494459230781640628620899862803482534211706798')
K = D(1000).ln() / (D(11) ** (D(1) / 3) - 1)
ROOT = Path(__file__).resolve().parent.parent


def bernstein(power):
    n = len(power) - 1
    return [sum(power[k] * D(comb(i, k)) / D(comb(n, k)) for k in range(i + 1))
            for i in range(n + 1)]


def coefficients():
    angle = PI / 2
    quarter = D(1) / 4 - D(1) / (2 * PI)
    first = [D(0)] * 18
    for k in range(3, 18, 2):
        first[k] = (-1) ** ((k + 1) // 2) * angle**k / factorial(k) / (2 * PI)
    first = [int(v * CONTROL_SCALE) for v in bernstein(first)]
    first[-1] = int(quarter * CONTROL_SCALE)
    second = [D(0)] * 19
    second[0], second[1] = quarter, D(1) / 4
    for k in range(2, 19, 2):
        second[k] = -(-1) ** (k // 2) * angle**k / factorial(k) / (2 * PI)
    second = [int(v * CONTROL_SCALE) for v in bernstein(second)]
    second[-1] = CONTROL_SCALE // 2
    assert all(a <= b for a, b in zip(first, first[1:]))
    assert all(a <= b for a, b in zip(second, second[1:]))
    assert first[0] == 0 and first[-1] == second[0]
    assert second[-1] == CONTROL_SCALE // 2
    bound = 2 * angle**19 / factorial(19) / (2 * PI) + D('1.00000002e-18')
    assert bound < D('1.5e-14')
    assert 2 * D(2).ln()**21 / factorial(21) < D('2e-23')
    return first, second, [EXP_SCALE // factorial(n) for n in range(21)]


def sine(x):
    term = total = x
    for n in range(1, 90):
        term *= -x * x / D(2 * n * (2 * n + 1))
        total += term
    return total


def reference_price(x_wei, p_l):
    x = D(x_wei) / WAD
    f = x % 1
    s = x - sine(2 * PI * f) / (2 * PI)
    h = (1 + abs(s)) ** (D(1) / 3) - 1
    if s < 0:
        h = -h
    return int(D(p_l) * (K * h).exp())


def fixtures():
    # Includes old numerical failure seams, negative/origin prices, all ten
    # milestones, beyond64, and wide custom-price coverage.
    xs = sorted(set([0, 1, -1, 10**9, -10**9,
                     -int(D('0.471204188481675392') * WAD)] +
                    [i * WAD for i in range(11)] +
                    [int(D(v) * WAD) for v in
                     ['-1000', '-300', '-100', '-64', '-16', '-0.75', '-0.5', '-0.25',
                      '0.125', '0.25', '0.375', '0.5', '0.75', '4.75', '16.5',
                      '64', '100', '128', '500', '1000', '10000']] +
                    [int(D('16.5') * WAD) - 1, int(D('4.75') * WAD) - 1]))
    return [(x, p, reference_price(x, p)) for p in (10**9, 75 * 10**12, 10**18) for x in xs]


def fixture_source():
    rows = fixtures()
    cases = '\n'.join(f'        if (i == {i}) return ({x}, {p}, {value});'
                      for i, (x, p, value) in enumerate(rows))
    return f'''// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Generated by scripts/sine_v3_price.py. Do not edit by hand.
library SineV3PriceFixtures {{
    uint256 internal constant COUNT = {len(rows)};
    function row(uint256 i) internal pure returns (int256 x, uint256 pL, uint256 price) {{
{cases}
        revert("price fixture index");
    }}
}}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    first, second, exp = coefficients()
    source = (ROOT / 'src/SineV3Price.sol').read_text()
    for name, expected in [('_firstQuarter', first + [0]), ('_secondQuarter', second)]:
        body = source.split(f'function {name}', 1)[1].split('return _deCasteljau', 1)[0]
        array = body.split('memory b = [', 1)[1].split('];', 1)[0]
        actual = [int(n) for n in re.findall(r'(?<![A-Za-z])\b\d+\b', array.replace('uint256', ''))]
        assert actual == expected, (name, actual, expected)
    body = source.split('function _expReduced', 1)[1]
    actual = [int(n) for n in re.findall(r'value = (\d+)', body)]
    assert actual == list(reversed(exp)), 'exponential coefficients differ'
    assert f'K_WAD = {int((K * WAD).to_integral_value())};' in source
    assert f'LN2_WAD = {int(D(2).ln() * WAD)};' in source
    fixture_path = ROOT / 'test/SineV3PriceFixtures.sol'
    generated = fixture_source()
    if args.check:
        assert fixture_path.read_text() == generated, 'price fixtures are stale'
    else:
        fixture_path.write_text(generated)
    print(f'Monotone price: coefficients ordered, analytic error bounds pass, {len(fixtures())} independent fixtures match.')


if __name__ == '__main__':
    main()
