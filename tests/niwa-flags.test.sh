#!/usr/bin/env bash
# Pins niwa's --no-progress as a flag that takes no value.
#
# gate-online.sh reads a literal niwa command by walking its flags to find the
# subcommand. Every flag but one is assumed to take a value, so a word after
# it can't be the subcommand, which only ever widens the deny. The exception
# is --no-progress: the walk reads it as taking no value, and the scratch-reap
# form allows it ahead of reap. If niwa ever gave it a value,
# `niwa --no-progress create reap` would really reap while the walk reads
# create as the subcommand. That fails open, so this test fails first.
#
# A test of the hook alone can't see niwa's flag types, so this one asks niwa:
# the --no-progress line of the root and reap help must show no value type,
# and `niwa --no-progress --version` must print the version, which it doesn't
# if --no-progress takes --version as its value. Nothing here touches a
# workspace.
#
# Usage: tests/niwa-flags.test.sh [path-to-niwa]
#   The default is the niwa found on PATH.
#
# Exit status: 0 when every check passes, 1 otherwise.

set -uo pipefail

niwa=${1:-$(command -v niwa || true)}
if [ -z "$niwa" ] || [ ! -x "$niwa" ]; then
    echo "niwa not found: ${1:-niwa on PATH}" >&2
    exit 1
fi

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

echo "niwa: $("$niwa" --version 2>&1 | head -1)"

# check_help LABEL ARGS...: the help output has exactly one --no-progress
# line, and it shows no value. Cobra prints a bool as
#       --no-progress   <description>
# and a flag that takes a value with its type after one space, as in
#       --no-progress string   <description>
check_help() {
    local label=$1 out lines line
    shift
    if ! out=$("$niwa" "$@" 2>&1); then
        bad "$label: niwa $* exited non-zero"
        return
    fi
    lines=$(printf '%s\n' "$out" | grep -E '^ +(-[A-Za-z], )?--no-progress([ =]|$)')
    if [ -z "$lines" ]; then
        bad "$label: no --no-progress line in niwa $*"
        return
    fi
    if [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" != 1 ]; then
        bad "$label: more than one --no-progress line in niwa $*"
        return
    fi
    line=$lines
    if printf '%s\n' "$line" | grep -Eq -- '--no-progress( {2,}[^ ]|$)'; then
        ok "$label: --no-progress shows no value"
    else
        bad "$label: --no-progress shows a value: $line"
    fi
}

check_help "root help" --help
check_help "reap help" reap --help

# --version after --no-progress: a bool leaves it alone, a value flag eats it.
if out=$("$niwa" --no-progress --version 2>&1) && printf '%s\n' "$out" | grep -q '^niwa version '; then
    ok "--no-progress --version prints the version"
else
    bad "--no-progress --version: $(printf '%s\n' "$out" | head -1)"
fi

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
