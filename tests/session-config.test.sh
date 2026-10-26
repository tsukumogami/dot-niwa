#!/usr/bin/env bash
# Checks for the [session] tables in .niwa/workspace.toml.
#
# The on-reap command is shell text inside TOML, so a quoting slip changes
# what niwa runs without any load error. The first check parses the file with
# a TOML parser and compares the command with the expected text byte for
# byte, along with the timeout and both dispatch_env lists. The rest run the
# parsed command under sh -c, the way niwa does, with only the variables niwa
# passes it (PATH, HOME, NIWA_REAP_KEY, NIWA_SESSION_ID), against stubs in a
# scratch HOME: no koto or shirabe installed on the host is ever reached.
#
# Usage: tests/session-config.test.sh [path-to-workspace.toml]
#
# Exit status: 0 when every check passes, 1 otherwise.
#
# Requires: python3 3.11 or later (tomllib)

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
toml=${1:-$here/../.niwa/workspace.toml}

if [ ! -f "$toml" ]; then
    echo "workspace.toml not found: $toml" >&2
    exit 1
fi

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The expected command, as two steps joined by "; ". Quoted heredocs, so
# nothing here is expanded or unescaped.
step1=$(cat <<'EOF'
[ -n "$NIWA_REAP_KEY" ] && command -v koto >/dev/null 2>&1 && koto session anchor close --help >/dev/null 2>&1 && koto session anchor close --key="$NIWA_REAP_KEY" --harness-session="$NIWA_SESSION_ID"
EOF
)
step2=$(cat <<'EOF'
v=$(ls "$HOME/.claude/plugins/cache/shirabe/shirabe" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1); s="$HOME/.claude/plugins/cache/shirabe/shirabe/$v/skills/coordinate/scripts/unit-removed.sh"; [ -n "$v" ] && [ -O "$s" ] && [ -x "$s" ] && "$s" record >/dev/null 2>&1 || true
EOF
)
printf '%s; %s' "$step1" "$step2" >"$work/expected"

# Parse the file and write out what the checks need. -I keeps python from
# importing anything from this directory or the caller's.
if ! python3 -I - "$toml" "$work" <<'EOF'
import json, sys, tomllib
toml_path, out = sys.argv[1], sys.argv[2]
with open(toml_path, "rb") as f:
    doc = tomllib.load(f)
session = doc.get("session", {})
on_reap = session.get("on_reap", {})
with open(out + "/command", "w", encoding="utf-8", newline="") as f:
    f.write(on_reap.get("command", ""))
with open(out + "/shape.json", "w", encoding="utf-8") as f:
    json.dump({
        "session_keys": sorted(session),
        "on_reap_keys": sorted(on_reap),
        "timeout": on_reap.get("timeout"),
        "dispatch_env": session.get("dispatch_env"),
    }, f, sort_keys=True)
EOF
then
    echo "could not parse $toml" >&2
    exit 1
fi

if cmp -s "$work/expected" "$work/command"; then
    ok "on_reap.command equals the expected text byte for byte"
else
    bad "on_reap.command differs from the expected text"
    diff <(cat "$work/expected"; echo) <(cat "$work/command"; echo) | sed 's/^/     /'
fi

shape=$(cat "$work/shape.json")
want='{"dispatch_env": {"passthrough": ["KOTO_DISPATCHER_ANCHOR"], "unset": ["KOTO_ANCHOR"]}, "on_reap_keys": ["command", "timeout"], "session_keys": ["dispatch_env", "on_reap"], "timeout": "20s"}'
if [ "$shape" = "$want" ]; then
    ok "timeout, dispatch_env lists and [session] keys are exactly as declared"
else
    bad "[session] shape: got $shape"
fi

# --- Running the command ---

# The tools the command may use, and nothing else; koto is added per case.
base=$work/base
mkdir -p "$base"
for t in sh ls grep sort tail; do
    p=$(command -v "$t") || { echo "missing tool: $t" >&2; exit 1; }
    ln -s "$p" "$base/$t"
done

# A koto stub that logs its arguments, and a newer shirabe version whose
# unit-removed.sh does the same, beside an older one that must not run.
withkoto=$work/with-koto
mkdir -p "$withkoto"
cp -P "$base"/* "$withkoto"/
cat >"$withkoto/koto" <<EOF
#!$(command -v sh)
echo "\$*" >>"$work/koto.log"
EOF
chmod +x "$withkoto/koto"

home=$work/home
cache=$home/.claude/plugins/cache/shirabe/shirabe
for v in 0.9.0 0.10.0 0.10.1-dev; do
    d=$cache/$v/skills/coordinate/scripts
    mkdir -p "$d"
    cat >"$d/unit-removed.sh" <<EOF
#!$(command -v sh)
echo "$v \$*" >>"$work/removed.log"
EOF
    chmod +x "$d/unit-removed.sh"
done

# run <PATH> <HOME> <reap-key>: the command under sh -c with niwa's fixed
# environment. Prints the exit status, then anything the command wrote.
run() {
    : >"$work/koto.log"; : >"$work/removed.log"
    env -i PATH="$1" HOME="$2" NIWA_REAP_KEY="$3" NIWA_SESSION_ID=sess-1 \
        "$base/sh" -c "$(cat "$work/command")" >"$work/out" 2>&1
    echo "$?"
}

rc=$(run "$withkoto" "$home" key-1)
if [ "$rc" = 0 ] && [ ! -s "$work/out" ] \
    && [ "$(cat "$work/koto.log")" = "session anchor close --help
session anchor close --key=key-1 --harness-session=sess-1" ] \
    && [ "$(cat "$work/removed.log")" = "0.10.0 record" ]; then
    ok "with koto: closes the anchor by key and session, then records through the newest release"
else
    bad "with koto: rc=$rc koto=[$(cat "$work/koto.log")] removed=[$(cat "$work/removed.log")] out=[$(cat "$work/out")]"
fi

rc=$(run "$withkoto" "$home" "")
if [ "$rc" = 0 ] && [ ! -s "$work/koto.log" ] && [ "$(cat "$work/removed.log")" = "0.10.0 record" ]; then
    ok "no reap key: koto is never called, the removal is still recorded"
else
    bad "no reap key: rc=$rc koto=[$(cat "$work/koto.log")] removed=[$(cat "$work/removed.log")]"
fi

rc=$(run "$base" "$home" key-1)
if [ "$rc" = 0 ] && [ ! -s "$work/out" ] && [ "$(cat "$work/removed.log")" = "0.10.0 record" ]; then
    ok "no koto on PATH: exits 0 quietly"
else
    bad "no koto on PATH: rc=$rc out=[$(cat "$work/out")]"
fi

rc=$(run "$withkoto" "$work/empty-home" key-1)
if [ "$rc" = 0 ] && [ ! -s "$work/out" ] && [ ! -s "$work/removed.log" ]; then
    ok "no shirabe installed: exits 0 quietly"
else
    bad "no shirabe installed: rc=$rc out=[$(cat "$work/out")]"
fi

chmod -x "$cache/0.10.0/skills/coordinate/scripts/unit-removed.sh"
rc=$(run "$withkoto" "$home" key-1)
if [ "$rc" = 0 ] && [ ! -s "$work/removed.log" ]; then
    ok "newest script not executable: nothing else runs in its place"
else
    bad "newest script not executable: rc=$rc removed=[$(cat "$work/removed.log")]"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
