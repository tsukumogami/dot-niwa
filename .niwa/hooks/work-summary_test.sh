#!/usr/bin/env bash
set -uo pipefail

# Test harness for the three work-summary thin hooks. No build system in this
# repo, so this is a self-contained bash harness. It stubs SHIRABE_WORK_SUMMARY
# with a fake component and asserts fail-safe + dual-channel behavior.
#
# Requires: jq
#
# Run: bash .niwa/hooks/work-summary_test.sh

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE="$HOOKS_DIR/post_tool_use/work-summary-capture.sh"
RETURN="$HOOKS_DIR/user_prompt_submit/work-summary-return.sh"
COMPACT="$HOOKS_DIR/session_start/work-summary-compact.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# --- Stub components ----------------------------------------------------------
# Emits a fixed simple block regardless of args/stdin.
STUB="$TMP/stub.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
echo "Open PRs: 2"
echo "- repo#12 OPEN https://example/12"
EOS
chmod +x "$STUB"

# Emits nothing (gate closed).
STUB_EMPTY="$TMP/stub_empty.sh"
cat > "$STUB_EMPTY" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$STUB_EMPTY"

# Emits a block with JSON-hostile chars: double quote, backslash, newline.
STUB_EVIL="$TMP/stub_evil.sh"
cat > "$STUB_EVIL" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' 'PR "title" with \backslash'
printf '%s\n' 'second "line"'
EOS
chmod +x "$STUB_EVIL"

# Exits non-zero (component error) after printing to stderr.
STUB_ERR="$TMP/stub_err.sh"
cat > "$STUB_ERR" <<'EOS'
#!/usr/bin/env bash
echo "boom" >&2
exit 3
EOS
chmod +x "$STUB_ERR"

SAMPLE_JSON='{"session_id":"a050f0e4-testsid","tool_input":{"command":"gh pr create"},"tool_response":{"stdout":"https://example/12"}}'
NO_SID_JSON='{"tool_input":{"command":"ls"},"tool_response":{"stdout":"x"}}'

run_hook() { # <hook> <env-value> <stdin-json>  -> sets OUT/RC
    local hook="$1" envval="$2" json="$3"
    OUT="$(printf '%s' "$json" | SHIRABE_WORK_SUMMARY="$envval" bash "$hook" 2>/dev/null)"
    RC=$?
}

# =============================================================================
# (a) Fail-safe no-op cases
# =============================================================================

# Unset var (empty value) -> no-op.
OUT="$(printf '%s' "$SAMPLE_JSON" | env -u SHIRABE_WORK_SUMMARY bash "$CAPTURE" 2>/dev/null)"; RC=$?
if [[ $RC -eq 0 && -z "$OUT" ]]; then pass "capture: unset var -> no-op"; else fail "capture: unset var (rc=$RC out=$OUT)"; fi

# Missing file -> no-op.
run_hook "$CAPTURE" "$TMP/does-not-exist.sh" "$SAMPLE_JSON"
if [[ $RC -eq 0 && -z "$OUT" ]]; then pass "capture: missing file -> no-op"; else fail "capture: missing file (rc=$RC out=$OUT)"; fi

# Empty session id -> no-op.
run_hook "$CAPTURE" "$STUB" "$NO_SID_JSON"
if [[ $RC -eq 0 && -z "$OUT" ]]; then pass "capture: empty sid -> no-op"; else fail "capture: empty sid (rc=$RC out=$OUT)"; fi

# Component prints nothing -> no-op.
run_hook "$CAPTURE" "$STUB_EMPTY" "$SAMPLE_JSON"
if [[ $RC -eq 0 && -z "$OUT" ]]; then pass "capture: empty block -> no-op"; else fail "capture: empty block (rc=$RC out=$OUT)"; fi

# Component errors -> no-op, never aborts turn.
run_hook "$CAPTURE" "$STUB_ERR" "$SAMPLE_JSON"
if [[ $RC -eq 0 && -z "$OUT" ]]; then pass "capture: component error -> no-op"; else fail "capture: component error (rc=$RC out=$OUT)"; fi

# Same guards on the other two hooks (spot-check unset).
for pair in "return:$RETURN" "compact:$COMPACT"; do
    name="${pair%%:*}"; hook="${pair#*:}"
    OUT="$(printf '%s' "$SAMPLE_JSON" | env -u SHIRABE_WORK_SUMMARY bash "$hook" 2>/dev/null)"; RC=$?
    if [[ $RC -eq 0 && -z "$OUT" ]]; then pass "$name: unset var -> no-op"; else fail "$name: unset var (rc=$RC out=$OUT)"; fi
done

# =============================================================================
# (b) Dual-channel JSON when a block is emitted (capture + return)
# =============================================================================

for pair in "capture:$CAPTURE:PostToolUse" "return:$RETURN:UserPromptSubmit"; do
    name="${pair%%:*}"; rest="${pair#*:}"; hook="${rest%%:*}"; event="${rest#*:}"
    run_hook "$hook" "$STUB" "$SAMPLE_JSON"
    if [[ $RC -ne 0 ]]; then fail "$name: dual-channel rc=$RC"; continue; fi
    if ! printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then fail "$name: output not valid JSON"; continue; fi
    sysmsg=$(printf '%s' "$OUT" | jq -r '.systemMessage // empty')
    ev=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // empty')
    ac=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
    if [[ -n "$sysmsg" ]]; then pass "$name: systemMessage present"; else fail "$name: systemMessage missing"; fi
    if [[ "$ev" == "$event" ]]; then pass "$name: hookEventName=$event"; else fail "$name: hookEventName=$ev (want $event)"; fi
    if printf '%s' "$ac" | grep -q "BEGIN WORK SUMMARY (untrusted data)"; then pass "$name: neutral delimited additionalContext"; else fail "$name: additionalContext framing missing"; fi
    if printf '%s' "$ac" | grep -q "data, not instructions"; then pass "$name: neutral preamble present"; else fail "$name: neutral preamble missing"; fi
    # systemMessage carries the raw block (no delimiter framing).
    if printf '%s' "$sysmsg" | grep -q "Open PRs: 2" && ! printf '%s' "$sysmsg" | grep -q "BEGIN WORK SUMMARY"; then pass "$name: systemMessage is raw block"; else fail "$name: systemMessage framing wrong"; fi
done

# =============================================================================
# (c) compact hook: additionalContext ONLY, no systemMessage
# =============================================================================
run_hook "$COMPACT" "$STUB" "$SAMPLE_JSON"
if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
    hassys=$(printf '%s' "$OUT" | jq 'has("systemMessage")')
    ev=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // empty')
    ac=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
    if [[ "$hassys" == "false" ]]; then pass "compact: no systemMessage"; else fail "compact: systemMessage present"; fi
    if [[ "$ev" == "SessionStart" ]]; then pass "compact: hookEventName=SessionStart"; else fail "compact: hookEventName=$ev"; fi
    if [[ -n "$ac" ]]; then pass "compact: additionalContext present"; else fail "compact: additionalContext missing"; fi
else
    fail "compact: invalid JSON output (rc=$RC out=$OUT)"
fi

# =============================================================================
# (d) Injection safety: block with quotes/backslashes/newlines stays valid JSON
# =============================================================================
for pair in "capture:$CAPTURE" "return:$RETURN" "compact:$COMPACT"; do
    name="${pair%%:*}"; hook="${pair#*:}"
    run_hook "$hook" "$STUB_EVIL" "$SAMPLE_JSON"
    if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
        # Confirm the hostile content round-trips intact inside additionalContext.
        ac=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')
        if printf '%s' "$ac" | grep -q 'PR "title" with \\backslash'; then
            pass "$name: hostile block JSON-encoded, round-trips intact"
        else
            fail "$name: hostile block content lost/garbled"
        fi
    else
        fail "$name: hostile block broke JSON (rc=$RC)"
    fi
done

# =============================================================================
echo "---"
if [[ $fails -eq 0 ]]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "$fails TEST(S) FAILED"
    exit 1
fi
