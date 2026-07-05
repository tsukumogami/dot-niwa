#!/usr/bin/env bash
set -euo pipefail

# Work-summary return-from-absence hook (Claude Code UserPromptSubmit).
#
# Pure pass-through: all logic (idle-threshold decision, render, sanitizer,
# hook-JSON shaping) lives in the on-PATH `shirabe` binary as `shirabe
# work-summary absence`. The binary reads the raw hook JSON from stdin, extracts
# what it needs itself, always exits 0 (fail-safe), and prints the COMPLETE hook
# JSON to stdout (or nothing when suppressed). This hook only routes stdin/stdout.
#
# Fail-safe: if the shirabe binary is unavailable, do nothing (never abort the
# turn). Because `shirabe work-summary` always exits 0, `exec` is safe under
# `set -e`; stdin flows straight through and the binary's stdout is the hook's
# output.
#
# Exit behavior:
#   exit 0 with no output   -> no-op (binary absent, or binary suppressed)
#   exit 0 with hook JSON    -> whatever the binary emitted, relayed verbatim

# Fail-safe: if the shirabe binary is unavailable, do nothing (never abort the turn).
command -v shirabe >/dev/null 2>&1 || exit 0
exec shirabe work-summary absence
