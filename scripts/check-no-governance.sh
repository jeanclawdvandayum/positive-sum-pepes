#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# check-no-governance.sh — the CLOCK-REDESIGN §7 grep gate
#
# The carpet-bomb governance surface must stay DEAD. If any of the stripped
# identifiers survives in src/, script/, test/, or scripts/ (outside git
# history — deleted lines in `git log -p` are fine, live files are not),
# this gate FAILS. Run it from anywhere — it cds to the repo root:
#
#   bash scripts/check-no-governance.sh
#
# Wired identifiers (CLOCK-REDESIGN §4, scoopy directive 2026-08-31/09-01):
#   proposeCarpetBomb / voteCarpetBomb  — the governance kill (replaced by
#                                         the detonation clock + detonate())
#   castWeightOn                        — prisoner's-dilemma bookkeeping
#   QUORUM_BIPS                         — quorum constant (no quorum left)
# Deliberately NOT gated (prose/history references only): carpetBomb as a
# word in comments, MAJORITY_BIPS, VOTE_DURATION / FLAT_EXIT_WINDOW.
#
# Exit codes: 0 = clean, 1 = governance survived, 2 = gate itself broken
# (fail-closed: a broken gate must never read as clean).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.."

PATTERNS='proposeCarpetBomb|voteCarpetBomb|castWeightOn|QUORUM_BIPS'

# -I skip binaries, --untracked include new files, options BEFORE the pattern.
# The gate file itself is excluded (it must name what it hunts).
set +e
matches=$(git grep -nIE --untracked -e "$PATTERNS" -- src script test scripts ':(exclude)scripts/check-no-governance.sh' 2>/tmp/gng-err.log)
status=$?
set -e

case $status in
  1) # no matches anywhere — the gate holds
    echo "✓ no-governance gate: clean (proposeCarpetBomb|voteCarpetBomb|castWeightOn|QUORUM_BIPS all dead)"
    ;;
  0) # matches found in live files
    echo "✗ GOVERNANCE SURVIVED — stripped identifiers found in live files:"
    echo "$matches"
    echo "  The clock is the only death authority (CLOCK-REDESIGN §4). Kill them."
    exit 1
    ;;
  *) # git grep itself broke — fail closed
    echo "✗ no-governance gate BROKEN (git grep exit $status) — not adjudicating:"
    cat /tmp/gng-err.log
    exit 2
    ;;
esac
