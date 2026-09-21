#!/usr/bin/env python3
"""Prove integer arithmetic lemmas, not the complete EVM implementation.

Each theorem requires satisfiable assumptions and an UNSAT negated conclusion.
Queries, witnesses, source hashes, and verdicts remain available for inspection.
The induction connecting the interpolation lemma to the loops is documented
in docs/audit/FORMAL-VERIFICATION.md. It is not a machine-checked EVM refinement.
"""
import argparse
import hashlib
import json
from pathlib import Path
import time

import z3

ROOT = Path(__file__).resolve().parents[2]


def properties():
    a, b, c, e, t, u, d = z3.Ints("a b c e t u d")
    lerp = lambda x, y, f: x + (y - x) * f / d
    domain = [0 <= a, a <= b, 0 <= c, c <= e,
              a <= c, b <= e, d > 0, 0 <= t, t <= u, u <= d]
    yield "ordered_interpolation", domain, lerp(a, b, t) <= lerp(c, e, u)
    yield "interpolation_range", [0 <= a, a <= b, d > 0, 0 <= t, t <= d], z3.And(
        a <= lerp(a, b, t), lerp(a, b, t) <= b)
    yield "interpolation_endpoints", [0 <= a, a <= b, d > 0], z3.And(
        lerp(a, b, 0) == a, lerp(a, b, d) == b)
    # Same fraction applied to three ordered controls preserves row order.
    yield "ordered_next_row", [0 <= a, a <= b, b <= c, d > 0, 0 <= t, t <= d], (
        lerp(a, b, t) <= lerp(b, c, t))
    maximum = 2**256 - 1
    yield "interpolation_uint256_range", [0 <= a, a <= b, b <= maximum,
                                           d > 0, 0 <= t, t <= d], z3.And(
        0 <= lerp(a, b, t), lerp(a, b, t) <= maximum)

    n, m, lam, price, q = z3.Ints("n m lam price q")
    yield "supply_scaling_order", [0 <= n, n <= m, lam > 0, price > 0], (
        lam * n / price <= lam * m / price)
    yield "inverse_ceil_equivalence", [n >= 0, q >= 0, lam > 0, price > 0], (
        (lam * n / price >= q) == (n >= (q * price + lam - 1) / lam))

    shares, deposit, supply = z3.Ints("shares deposit supply")
    yield "positive_genesis_allocation", [1 <= deposit, deposit <= shares,
                                           shares <= supply], z3.And(
        supply * deposit / shares >= deposit,
        supply * deposit / shares <= supply)
    yield "split_allocation_budget", [shares > 0, supply >= 0,
                                       deposit >= 0, deposit <= shares], (
        supply * deposit / shares + supply * (shares - deposit) / shares <= supply)

    lo, hi = z3.Ints("lo hi")
    mid = lo + (hi - lo) / 2
    yield "bisection_contracts", [0 <= lo, lo + 1 < hi], z3.And(
        lo < mid, mid < hi,
        mid - lo <= (hi - lo + 1) / 2,
        hi - mid <= (hi - lo + 1) / 2)

    pot = z3.Int("pot")
    ticket = lambda p: z3.If(p == 0, 1, p / 10000 + z3.If(p % 10000 == 0, 0, 1))
    cost = ticket(pot)
    yield "ticket_interval_and_range", [0 <= pot, pot <= maximum], z3.And(
        cost >= 1, cost <= maximum / z3.IntVal(10000) + 1,
        z3.If(pot == 0, cost == 1,
              z3.And((cost-1)*10000 < pot, pot - (cost-1)*10000 <= 10000)))
    yield "ticket_adjacent_order", [0 <= pot, pot < maximum], z3.And(
        ticket(pot) <= ticket(pot+1), ticket(pot+1) <= ticket(pot)+1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout-ms", type=int, default=30000)
    args = parser.parse_args()
    if args.timeout_ms <= 0:
        parser.error("Timeout must be positive")
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("Output directory must be empty")
    if z3.get_version_string() != "4.12.6":
        raise SystemExit("Install the pinned z3-solver requirement")
    bindings = json.loads((ROOT / "scripts/formal/model-bindings.json").read_text())
    for path, expected in bindings.items():
        if hashlib.sha256((ROOT/path).read_bytes()).hexdigest() != expected:
            raise SystemExit(f"Source changed: review the lemma mapping before updating model-bindings.json: {path}")
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    for name, assumptions, conclusion in properties():
        start = time.monotonic()
        solver = z3.Solver()
        solver.set(timeout=args.timeout_ms)
        solver.add(*assumptions)
        feasible = solver.check()
        witness = str(solver.model()) if feasible == z3.sat else None
        solver.add(z3.Not(conclusion))
        (args.output / f"{name}.smt2").write_text(solver.to_smt2())
        verdict = solver.check()
        result = {"name": name, "assumptions": str(feasible),
                  "witness": witness, "negated_property": str(verdict),
                  "pass": feasible == z3.sat and verdict == z3.unsat,
                  "seconds": round(time.monotonic() - start, 4)}
        if verdict == z3.sat:
            result["counterexample"] = str(solver.model())
        if verdict == z3.unknown:
            result["reason"] = solver.reason_unknown()
        results.append(result)
        print(f"{name}: {'PASS' if result['pass'] else 'FAIL'}", flush=True)

    # Negative controls: known defects must have a concrete counterexample.
    a, b, t, u, d = z3.Ints("a b t u d")
    n, q, lam, price = z3.Ints("n q lam price")
    mutants = [
        ("subtract_interpolation", [0 <= a, a < b, d > 0, 0 <= t, t < u, u <= d],
         a - (b-a)*t/d <= a - (b-a)*u/d),
        ("floor_inverse_target", [n >= 0, q > 0, lam > 0, price > 0],
         (lam*n/price >= q) == (n >= q*price/lam)),
    ]
    for name, assumptions, wrong_property in mutants:
        solver = z3.Solver()
        solver.set(timeout=args.timeout_ms)
        solver.add(*assumptions, z3.Not(wrong_property))
        verdict = solver.check()
        (args.output / f"negative_{name}.smt2").write_text(solver.to_smt2())
        results.append({"name": name, "kind": "negative-control",
                        "counterexample_search": str(verdict), "pass": verdict == z3.sat,
                        "counterexample": str(solver.model()) if verdict == z3.sat else None})
        print(f"negative control {name}: {verdict}", flush=True)

    sources = list(bindings) + ["scripts/formal/prove_arithmetic.py", "scripts/formal/model-bindings.json"]
    report = {"scope": "unbounded integer lemmas; no EVM refinement claim",
              "z3": z3.get_version_string(),
              "source_sha256": {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources},
              "results": results}
    (args.output / "arithmetic.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if all(row["pass"] for row in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
