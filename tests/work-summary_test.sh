#!/usr/bin/env bash
set -uo pipefail

# Test harness for the three work-summary thin pass-through hooks. No build
# system in this repo, so this is a self-contained bash harness.
#
# The hooks are pure pass-throughs to the on-PATH `shirabe` binary
# (`shirabe work-summary <mode>`); all JSON/nonce/fence shaping now lives in the
# binary and is tested there. This harness asserts only the thin contract:
#   (a) each hook no-ops (exit 0, no output) when `shirabe` is not on PATH;
#   (b) when a stub `shirabe` on PATH emits a known JSON blob, each hook relays
#       that stdout verbatim and exits 0;
#   (c) `capture` forwards stdin to the stub unmodified.
#
# Run: bash tests/work-summary_test.sh

# This harness lives outside .niwa/ so niwa does not auto-discover it as a hook
# script. Resolve the hooks directory from the repo root (this script's parent).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.niwa/hooks"
CAPTURE="$HOOKS_DIR/post_tool_use/work-summary-capture.sh"
RETURN="$HOOKS_DIR/user_prompt_submit/work-summary-return.sh"
COMPACT="$HOOKS_DIR/session_start/work-summary-compact.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# --- Stub `shirabe` binary ----------------------------------------------------
# A stub named exactly `shirabe`, placed on a scrubbed PATH via its directory.
# It records the subcommand it was invoked with and the stdin it received, then
# emits a known JSON blob on stdout. This mirrors the real binary's contract:
# read raw hook JSON on stdin, print the complete hook JSON to stdout, exit 0.
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
STUB="$STUB_DIR/shirabe"
cat > "$STUB" <<EOS
#!/usr/bin/env bash
# args: "work-summary" "<mode>"; record the mode and the raw stdin for assertions.
printf '%s\n' "\$2" > "$TMP/last-mode"
cat > "$TMP/last-stdin"
printf '%s\n' '{"systemMessage":"Open PRs: 2","hookSpecificOutput":{"hookEventName":"STUB","additionalContext":"stub-context"}}'
EOS
chmod +x "$STUB"

# Minimal PATH that still resolves coreutils but does NOT contain the stub.
BASE_PATH="/usr/bin:/bin"
# PATH that additionally contains the stub `shirabe`.
STUB_PATH="$STUB_DIR:$BASE_PATH"

SAMPLE_JSON='{"session_id":"a050f0e4-testsid","tool_input":{"command":"gh pr create"},"tool_response":{"stdout":"https://example/12"}}'

# =============================================================================
# (a) Fail-safe no-op when `shirabe` is not on PATH
# =============================================================================
for pair in "capture:$CAPTURE" "return:$RETURN" "compact:$COMPACT"; do
    name="${pair%%:*}"; hook="${pair#*:}"
    OUT="$(printf '%s' "$SAMPLE_JSON" | PATH="$BASE_PATH" bash "$hook" 2>/dev/null)"; RC=$?
    if [[ $RC -eq 0 && -z "$OUT" ]]; then
        pass "$name: shirabe absent -> no-op (exit 0, no output)"
    else
        fail "$name: shirabe absent (rc=$RC out=$OUT)"
    fi
done

# =============================================================================
# (b) With a stub `shirabe` on PATH, each hook relays the stub's stdout verbatim
# =============================================================================
EXPECTED='{"systemMessage":"Open PRs: 2","hookSpecificOutput":{"hookEventName":"STUB","additionalContext":"stub-context"}}'
for pair in "capture:$CAPTURE:capture" "return:$RETURN:absence" "compact:$COMPACT:compact"; do
    name="${pair%%:*}"; rest="${pair#*:}"; hook="${rest%%:*}"; mode="${rest#*:}"
    OUT="$(printf '%s' "$SAMPLE_JSON" | PATH="$STUB_PATH" bash "$hook" 2>/dev/null)"; RC=$?
    if [[ $RC -ne 0 ]]; then fail "$name: stub present rc=$RC"; continue; fi
    if [[ "$OUT" == "$EXPECTED" ]]; then
        pass "$name: relays stub stdout verbatim"
    else
        fail "$name: stdout not relayed verbatim (out=$OUT)"
    fi
    # The hook must invoke the correct subcommand.
    got_mode="$(cat "$TMP/last-mode" 2>/dev/null)"
    if [[ "$got_mode" == "$mode" ]]; then
        pass "$name: invoked 'shirabe work-summary $mode'"
    else
        fail "$name: wrong subcommand (got=$got_mode want=$mode)"
    fi
done

# =============================================================================
# (c) capture forwards stdin to the stub unmodified
# =============================================================================
printf '%s' "$SAMPLE_JSON" | PATH="$STUB_PATH" bash "$CAPTURE" >/dev/null 2>&1
got_stdin="$(cat "$TMP/last-stdin" 2>/dev/null)"
if [[ "$got_stdin" == "$SAMPLE_JSON" ]]; then
    pass "capture: stdin forwarded to stub unmodified"
else
    fail "capture: stdin altered (got=$got_stdin)"
fi

# =============================================================================
echo "---"
if [[ $fails -eq 0 ]]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "$fails TEST(S) FAILED"
    exit 1
fi
