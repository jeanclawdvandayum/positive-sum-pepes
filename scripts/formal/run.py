#!/usr/bin/env python3
"""Run a pinned, fail-closed symbolic suite and retain its evidence.

Install requirements.txt in an isolated environment first. Required properties
must finish with successful paths, no blocked paths, and no truncated loops.
Use --extended to attempt the harder, explicitly unresolved curve properties.
Timeouts and unknown results never count as proofs.
"""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
COMPILER_CONFIG_KEYS = ("solc", "optimizer", "optimizer_runs", "via_ir", "evm_version",
                        "bytecode_hash", "ast", "extra_output", "out", "cache_path", "src", "test", "libs")
CORE = [
    ("VerificationSentinels", "check_false_assertion", "counterexample"),
    ("VerificationSentinels", "check_empty_domain", "empty-domain"),
    ("HookRulesSymbolicTest", "check_active_minimum_positive", "proof"),
    ("HookRulesSymbolicTest", "check_ticket_genesis_independent", "proof"),
    ("HookRulesSymbolicTest", "check_prelaunch_minimum", "proof"),
    ("HookRulesSymbolicTest", "check_legacy_minimum", "proof"),
    ("HookRulesSymbolicTest", "check_setMode_unauthorized", "proof"),
    ("SineV3PriceSymbolicTest", "test_check_phaseat_seam_whole", "fixture"),
    ("SineV3PriceSymbolicTest", "test_check_phaseat_seam_quarters", "fixture"),
    ("SineV3PriceSymbolicTest", "check_scaledexp_reverts_huge_scale", "proof"),
    ("SineV3MathSymbolicTest", "check_domain_rejects_invalid_price", "proof"),
    ("SineV3MathSymbolicTest", "check_domain_rejects_excess_reserve", "proof"),
    ("SineV3MathSymbolicTest", "test_check_domain_rejects_above_max", "fixture"),
    ("SineV3MathSymbolicTest", "test_check_domain_admits_boundary", "fixture"),
    ("SineV3MathSymbolicTest", "test_check_domain_rejects_bad_pl", "fixture"),
]
EXTENDED = [
    ("HookRulesSymbolicTest", "check_ticket_interval", "proof"),
    ("HookRulesSymbolicTest", "check_ticket_adjacent", "proof"),
    ("SineV3PriceSymbolicTest", "check_phaseat_monotone_pos_q1", "proof"),
    ("SineV3PriceSymbolicTest", "check_phaseat_monotone_pos_q2", "proof"),
    ("SineV3PriceSymbolicTest", "check_phaseat_monotone_pos_q3", "proof"),
    ("SineV3PriceSymbolicTest", "check_phaseat_monotone_pos_q4", "proof"),
    ("SineV3PriceSymbolicTest", "check_phaseat_monotone_neg", "proof"),
    ("SineV3PriceSymbolicTest", "check_phaseat_odd", "proof"),
    ("SineV3PriceSymbolicTest", "check_scaledexp_monotone", "proof"),
    ("SineV3PrimitiveSymbolicTest", "check_cell_monotone_710", "proof"),
    ("SineV3PrimitiveSymbolicTest", "check_cell_monotone_711", "proof"),
    ("SineV3PrimitiveSymbolicTest", "check_cell_monotone_716", "proof"),
    ("SineV3PrimitiveSymbolicTest", "check_cell_monotone_1000", "proof"),
    ("SineV3MathSymbolicTest", "check_buyout_spot_bound", "proof"),
    ("SineV3MathSymbolicTest", "check_buyout_supply_monotone", "proof"),
]


def classify(payload, function, kind, process_code, contract=None):
    entries = [(key, r) for key, items in (payload.get("test_results") or {}).items() for r in items]
    if len(entries) != 1:
        return "INVALID_RESULT", False
    key, row = entries[0]
    if row.get("name", "").split("(")[0] != function or (contract and key.split(":")[-1] != contract):
        return "INVALID_RESULT", False
    code = row.get("exitcode")
    paths = row.get("num_paths")
    bounded = row.get("num_bounded_loops")
    valid_paths = isinstance(paths, list) and len(paths) == 3 and all(isinstance(n, int) and n >= 0 for n in paths)
    valid_paths = valid_paths and paths[0] >= paths[1] + paths[2]
    if kind == "counterexample":
        ok = code == 1 and (row.get("num_models") or 0) > 0 and process_code != 0
        return ("EXPECTED_COUNTEREXAMPLE" if ok else "NEGATIVE_CONTROL_FAILED"), ok
    if kind == "empty-domain":
        ok = code == 4 and valid_paths and paths[1] == 0 and process_code != 0
        return ("EXPECTED_EMPTY_DOMAIN" if ok else "NEGATIVE_CONTROL_FAILED"), ok
    if (code == 0 and process_code == 0 and valid_paths
            and paths[1] > 0 and paths[2] == 0 and bounded == 0):
        return ("PROVED" if kind == "proof" else "CONCRETE_CHECK_PASSED"), True
    return {1: "COUNTEREXAMPLE", 2: "SOLVER_TIMEOUT", 3: "BLOCKED",
            4: "EMPTY_DOMAIN", 5: "TOOL_ERROR"}.get(code, "INCOMPLETE"), False


def valid_bridge(payload):
    entries = [(key, name, row) for key, suite in payload.items()
               for name, row in suite.get("test_results", {}).items()]
    return (len(entries) == 1 and entries[0][0].split(":")[-1] == "HookRulesSymbolicTest"
            and entries[0][1] == "test_fixture_matches_constructor()"
            and entries[0][2].get("status") == "Success")


def run_process(command, env, logfile, timeout):
    with logfile.open("w") as log:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--extended", action="store_true")
    parser.add_argument("--only", help="Exact property name for focused investigation")
    parser.add_argument("--timeout", type=int, default=90, help="Wall seconds per property")
    parser.add_argument("--solver-timeout", type=int, default=30, help="Seconds per assertion query")
    args = parser.parse_args()
    if args.timeout <= 0 or args.solver_timeout <= 0:
        parser.error("Timeouts must be positive")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("Output directory must be empty to preserve prior evidence")
    out.mkdir(parents=True, exist_ok=True)
    versions = {p: importlib.metadata.version(p) for p in ("halmos", "z3-solver")}
    if versions != {"halmos": "0.3.3", "z3-solver": "4.12.6.0"}:
        raise SystemExit(f"Install the pinned requirements: found {versions}")
    env = dict(os.environ, FOUNDRY_PROFILE="halmos")
    # z3's executable is installed alongside this virtual environment's Python.
    env["PATH"] = str(Path(sys.executable).parent) + os.pathsep + env.get("PATH", "")
    config = subprocess.check_output(["forge", "config", "--json"], cwd=ROOT, env=env, text=True)
    cfg = json.loads(config)
    if not (cfg["optimizer"] and cfg["optimizer_runs"] == 200 and cfg["via_ir"]
            and cfg["evm_version"] == "cancun" and "0.8.26" in cfg["solc"]):
        raise SystemExit("Formal compiler settings differ from the release settings")
    # Foundry config can resolve private RPC credentials or explorer API keys.
    # Evidence needs only compiler/build settings, never the full environment.
    (out / "forge-config.json").write_text(json.dumps(
        {key: cfg.get(key) for key in COMPILER_CONFIG_KEYS}, indent=2) + "\n")
    build = ["forge", "build", "--ast", "--extra-output", "storageLayout", "metadata"]
    if run_process(build, env, out / "build.log", 600) != 0:
        raise SystemExit("Formal build failed; see build.log")
    bridge = ["forge", "test", "--match-contract", "HookRulesSymbolicTest",
              "--match-test", r"^test_fixture_matches_constructor\(", "--json"]
    bridge_log = out / "runtime-identity.json"
    bridge_code = run_process(bridge, env, bridge_log, 120)
    try:
        bridge_pass = bridge_code == 0 and valid_bridge(json.loads(bridge_log.read_text()))
    except (OSError, ValueError, TypeError):
        bridge_pass = False
    if not bridge_pass:
        raise SystemExit("Missing, failing, or mismatched hook runtime identity test; see runtime-identity.json")

    selected = CORE + (EXTENDED if args.extended else [])
    if args.only:
        selected = [p for p in CORE + EXTENDED if p[1] == args.only]
        if len(selected) != 1:
            parser.error("Unknown or ambiguous --only property")
    paths = sorted(set(ROOT.glob("src/**/*.sol")) | set(ROOT.glob("test/dinosat/*.sol"))
                   | set(ROOT.glob("scripts/formal/*.py")) | set(ROOT.glob("scripts/formal/*.json"))
                   | {ROOT / "foundry.toml", ROOT / "scripts/formal/requirements.txt"})
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    artifact_paths = [p for p in (ROOT / "out-halmos").glob("*/*.json")
                      if p.parent.name in {"CurveHook.sol", "SineV3Math.sol", "SineV3Price.sol", "SineV3Primitive.sol"}
                      or p.parent.name.endswith("Symbolic.t.sol") or p.parent.name == "VerificationSentinels.t.sol"]
    report = {"revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "versions": versions, "source_sha256": hashes,
              "artifact_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in artifact_paths},
              "submodules": subprocess.check_output(["git", "submodule", "status", "--recursive"], cwd=ROOT, text=True),
              "suite": "focused" if args.only else ("extended" if args.extended else "core"),
              "forge_version": subprocess.check_output(["forge", "--version"], text=True).strip(),
              "results": []}
    for contract, function, kind in selected:
        slug = f"{contract}.{function}"
        result_path = out / f"{slug}.json"
        command = [sys.executable, "-m", "halmos", "--contract", contract,
                   "--match-test", "^" + re.escape(function) + r"\(",
                   "--forge-build-out", "out-halmos", "--loop", "64",
                   "--solver", "z3", "--solver-threads", "1",
                   "--solver-timeout-assertion", f"{args.solver_timeout}s",
                   "--panic-error-codes", "*", "--no-status",
                   "--json-output", str(result_path)]
        start = time.monotonic()
        code = run_process(command, env, out / f"{slug}.log", args.timeout)
        status, passed = "WALL_TIMEOUT", False
        if code is not None:
            try:
                status, passed = classify(json.loads(result_path.read_text()), function, kind, code, contract)
            except (OSError, ValueError, TypeError):
                status = "MISSING_OR_INVALID_RESULT"
        report["results"].append({"contract": contract, "function": function, "kind": kind,
                                  "status": status, "passed": passed, "command": command,
                                  "process_exit": code, "seconds": round(time.monotonic()-start, 3)})
        (out / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"{slug}: {status}", flush=True)
    changed = [p for p, h in hashes.items() if hashlib.sha256((ROOT/p).read_bytes()).hexdigest() != h]
    report["changed_during_run"] = changed
    report["passed"] = not changed and all(r["passed"] for r in report["results"])
    (out / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
