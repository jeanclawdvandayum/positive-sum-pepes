#!/usr/bin/env python3
"""Check every primitive cell against independent analytic Decimal density.

The finite-domain check covers every canonical cell and 81 fractions per cell.
It checks integer coefficient assembly and signed arithmetic bounds. This is
numerical evidence, not a formal interpolation bound between sample points.
Run after `python3 scripts/sine_v3.py --check`. No third-party Python package is
required; the analytic oracle does not use the integer implementation below.
"""
import json
import math
from decimal import Decimal as D

import sine_v3 as oracle

WAD = 10**18
MATRIX_SCALE = 10**27


def integer_cbrt(value):
    result = 1 << ((value.bit_length() + 2) // 3)
    while True:
        next_result = (2*result + value//(result*result)) // 3
        if next_result >= result:
            return result
        result = next_result


def integer_exp(exponent, scale):
    shift, remainder = divmod(exponent, 693147180559945309)
    value = 10**36 // math.factorial(20)
    for n in range(19, -1, -1):
        value = 10**36 // math.factorial(n) + value*remainder//WAD
    if shift >= 0:
        return (scale << shift)*value//10**36
    return (scale*value//10**36) >> -shift


def integer_density(phase, scale):
    root = integer_cbrt((WAD+abs(phase))*10**36)
    exponent = oracle.K_WAD*(root-WAD)//WAD
    if phase < 0:
        exponent = -exponent
    return integer_exp(-exponent, scale)


def bernstein_value(controls, fraction):
    values = controls[:]
    for count in range(len(values)-1, 0, -1):
        for j in range(count):
            values[j] += (values[j+1]-values[j])*fraction
    return values[0]


def canonical_phases(nodes):
    phases = []
    for kind in range(7):
        offsets = []
        for t in nodes:
            if kind == 0:
                fraction = t
            elif kind < 3:
                fraction = (kind-1+t)/2
            else:
                fraction = (kind-3+t)/4
            offsets.append(round(oracle.s_of(fraction)*WAD))
        phases.append(offsets)
    return phases


def main():
    nodes, matrix = oracle.bernstein_matrix()
    matrix = [[round(x*MATRIX_SCALE) for x in row] for row in matrix]
    phases = canonical_phases(nodes)
    fractions = sorted(set([D(j)/64 for j in range(65)]
                           + [(a+b)/2 for a, b in zip(nodes, nodes[1:])]))
    rule = oracle.legendre_gauss(32)
    worst = D(0)
    worst_at = None
    smallest_ratio = D(1)
    largest_signed_sum = 0
    largest_span = D(0)
    for i, (a, b) in enumerate(zip(oracle.PRIMITIVE_XS, oracle.PRIMITIVE_XS[1:])):
        width = b-a
        base = math.floor(a)
        fraction4 = int((a-base)*4)
        kind = 0 if width == 1 else (1+fraction4//2 if width == D('.5') else 3+fraction4)
        scale = 10**36 if a < 0 else 10**54
        samples = [integer_density(base*WAD+s, scale) for s in phases[kind]]
        coefficients = []
        for row in matrix:
            terms = [abs(weight)*sample//MATRIX_SCALE for weight, sample in zip(row, samples)]
            coefficient = sum(-term if weight < 0 else term for weight, term in zip(row, terms))
            largest_signed_sum = max(largest_signed_sum, sum(terms))
            if coefficient <= 0:
                raise SystemExit(f'nonpositive coefficient in cell {i} at {a}')
            coefficients.append(D(coefficient)/scale)
        smallest_ratio = min(smallest_ratio, min(coefficients)/max(coefficients))
        integral = oracle.gl(rule, a, b, oracle.density)
        largest_span = max(largest_span, integral*10**36)
        factor = integral/(width*sum(coefficients)/17)
        controls = [x*factor for x in coefficients]
        for fraction in fractions:
            reference = oracle.density(a+width*fraction)
            error = abs(bernstein_value(controls, fraction)/reference-1)
            if error > worst:
                worst, worst_at = error, [i, str(a), str(fraction)]
    if worst > D('1e-10'):
        raise SystemExit(f'density error exceeds the 1e-10 validation margin: {worst} at {worst_at}')
    if largest_signed_sum >= 2**255:
        raise SystemExit('signed coefficient sum exceeds int256')
    if largest_span >= D('1.1e54'):
        raise SystemExit('cell span exceeds the reserve-fraction rounding bound')
    print(json.dumps({
        'cells': len(oracle.PRIMITIVE_XS)-1,
        'samples_per_cell': len(fractions),
        'worst_relative_density': str(worst),
        'worst_at': worst_at,
        'minimum_coefficient_ratio': str(smallest_ratio),
        'largest_absolute_signed_sum': str(largest_signed_sum),
        'largest_cell_span_f36': str(largest_span),
    }, indent=2))


if __name__ == '__main__':
    main()
