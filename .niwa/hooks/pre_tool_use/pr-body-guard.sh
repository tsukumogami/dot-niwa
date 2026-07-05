#!/usr/bin/env bash
set -uo pipefail

# PR-body guard hook (Claude Code PreToolUse, matcher: Bash).
#
# Pure pass-through: all logic (gh-argv parsing, the PB1-PB3 checks, hook-JSON
# shaping) lives in the on-PATH `shirabe` binary as `shirabe pr-body-hook`. The
# binary reads the raw hook JSON from stdin, extracts the `gh pr create` /
# `gh pr edit` title and body itself, reuses the same `check_pr_body` engine the
# CI `pr-body.yml` gate uses, and prints a PreToolUse decision (a `deny` naming
# the findings, or nothing to allow). It always exits 0.
#
# PreToolUse difference from the work-summary PostToolUse pass-through: a
# non-zero exit from a PreToolUse hook BLOCKS the tool call, and this hook
# matches EVERY Bash command. So it must never let a stale `shirabe` (one that
# predates the `pr-body-hook` subcommand, where clap exits non-zero on an
# unknown subcommand) abort a command. Hence: no `exec`, and the invocation
# falls back to allow (`|| exit 0`) on any non-zero exit. The current binary
# always exits 0, so the guard only ever fires against an outdated install.
#
# Exit behavior:
#   exit 0 with no output     -> allow (binary absent/outdated, or clean body)
#   exit 0 with deny hook JSON -> block, relayed verbatim from the binary

command -v shirabe >/dev/null 2>&1 || exit 0
shirabe pr-body-hook 2>/dev/null || exit 0
exit 0
