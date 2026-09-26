#!/usr/bin/env bash
# Case table for .niwa/hooks/pre_tool_use/gate-online.sh.
#
# Feeds each command to the hook as the JSON a PreToolUse event carries on
# stdin and compares the decision it prints (deny, ask, or allow when it
# prints nothing) with the expected one. Nothing here runs the commands in
# the table; they are only ever strings handed to the hook.
#
# Usage: tests/gate-online.test.sh [path-to-hook]
#   The hook defaults to the copy in this repository. Point it at an
#   installed copy (or an older revision) to check that one instead.
#
# Exit status: 0 when every row matches, 1 when any row mismatches or the
# hook misbehaves (non-zero exit, output that is not a decision).
#
# Requires: jq

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hook=${1:-$here/../.niwa/hooks/pre_tool_use/gate-online.sh}

if [ ! -f "$hook" ]; then
    echo "hook not found: $hook" >&2
    exit 1
fi

pass=0
fail=0

# A PATH whose awk always fails, to check the hook does not allow when it
# cannot inspect a command.
broken=$(mktemp -d)
trap 'rm -rf "$broken"' EXIT
printf '#!/bin/sh\nexit 1\n' > "$broken/awk"
chmod +x "$broken/awk"

# decide COMMAND [broken-awk] -> prints deny|ask|allow, or error:<detail>
decide() {
    local out status path=$PATH
    [ "${2:-}" = broken-awk ] && path=$broken:$PATH
    out=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | PATH=$path bash "$hook")
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "error:exit-$status"
        return
    fi
    if [ -z "$out" ]; then
        echo allow
        return
    fi
    echo "$out" | jq -r '.hookSpecificOutput.permissionDecision // "error:no-decision"' 2>/dev/null ||
        echo "error:bad-json"
}

# row EXPECTED COMMAND [broken-awk]
row() {
    local expected=$1 command=$2 got
    got=$(decide "$command" "${3:-}")
    if [ "$got" = "$expected" ]; then
        pass=$((pass + 1))
        printf 'ok    %-5s  %s\n' "$expected" "$(printf '%q' "$command")"
    else
        fail=$((fail + 1))
        printf 'FAIL  want %-5s got %-12s  %s\n' "$expected" "$got" "$(printf '%q' "$command")"
    fi
}

# --- Plain forms the original hook already caught -------------------------
row allow 'gh pr merge 12'
row deny  'gh pr merge 12 --squash --admin'
row deny  'gh repo delete owner/repo --yes'
row deny  'curl https://example.com'
row deny  'wget https://example.com'
row deny  'nc -l 8080'
row deny  'ncat example.com 80'
row deny  'netcat example.com 80'
row ask   'gh auth switch'
row ask   'gh release create v1.0.0'
row ask   'gh issue close 5'
row ask   'unset GH_TOKEN'

# --- Gated commands that are not at the start of the line -----------------
row deny  'cd repo && gh pr merge 12'
row deny  '(gh pr merge 12)'
row deny  'true; gh pr merge 12'
row deny  'false || gh pr merge 12'
row deny  'git fetch & gh pr merge 12'
row deny  'echo y | gh pr merge 12'
row deny  '{ gh pr merge 12; }'
row deny  $'git status\ngh pr merge 12'
row deny  'if true; then gh pr merge 12; fi'
row deny  'for n in 1 2; do gh pr merge $n; done'
row deny  'x=$(gh pr merge 12)'
row deny  'echo "merged: $(gh pr merge 12)"'
row deny  'echo `gh pr merge 12`'
row deny  'GH_TOKEN=abc gh pr merge 12'
row deny  '/usr/bin/gh pr merge 12'
row deny  'command gh pr merge 12'
row deny  'env GH_TOKEN=abc gh pr merge 12'
row deny  'cd repo && gh repo delete owner/repo --yes'
row deny  'cd /tmp && curl -sL https://example.com'
row deny  'true && wget https://example.com'
row deny  'echo hi | nc example.com 80'
row deny  'timeout 300 curl -sL https://example.com'
row deny  '"gh" pr merge 12'
row deny  'g\h pr merge 12'
row deny  $'cat > notes.md <<\'EOF\'\ntext\nEOF\ngh pr merge 12'
row deny  'diff <(gh pr merge 12) /dev/null'
row ask   'xargs -n1 gh issue close < issues.txt'
row ask   'sudo -u me git push -f origin feature'
row ask   'for n in 1 2; do gh issue close $n; done'
row ask   $'git status\ngh release create v1.0.0'
row ask   'cd repo && gh issue close 5'
row ask   'true; gh release create v1.0.0'
row ask   '(gh auth switch)'
row ask   'export A=1; unset GH_TOKEN'

# --- Merging through the API ----------------------------------------------
row deny  'gh api -X PUT repos/owner/repo/pulls/12/merge'
row deny  'gh api --method PUT /repos/owner/repo/pulls/12/merge -f merge_method=squash'
row deny  'cd repo && gh api -X PUT repos/{owner}/{repo}/pulls/12/merge'
row deny  "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"X\"}) { clientMutationId } }'"
row allow 'gh api repos/owner/repo/pulls/12'
row allow 'gh api -X GET repos/owner/repo/pulls/12/merge'

# --- niwa reap, and the targeted destroy that stays allowed ---------------
row deny  'niwa reap'
row deny  'niwa reap --yes'
row deny  'cd .. && niwa reap'
row allow 'niwa destroy my-instance'
row allow 'niwa destroy my-instance --force'
row allow 'niwa list'

# --- Force-push asks ------------------------------------------------------
row ask   'git push --force'
row ask   'git push -f origin feature'
row ask   'git push --force-with-lease origin feature'
row ask   'git push --force-with-lease=feature:abc123 origin feature'
row ask   'git push -uf origin feature'
row ask   'git push origin +feature'
row ask   'git -C repo push --force origin feature'
row ask   'cd repo && git push --force origin feature'
row allow 'git push origin feature'
row allow 'git push -u origin feature'
row allow 'git fetch --force'

# --- Text about the commands: must not be gated ---------------------------
row allow 'git commit -m "fix: stop gh pr merge from slipping past the gate"'
row allow "git commit -m 'curl and wget are denied; niwa reap too'"
row allow 'echo "never run gh pr merge yourself"'
row allow "echo 'git push --force is gated'"
row allow $'git commit -F - <<\'EOF\'\nfix: gate gh pr merge anywhere\n\ncurl, wget and niwa reap are denied.\nEOF'
row allow $'gh pr create --title "fix: gate" --body "$(cat <<\'EOF\'\nThe hook now denies gh pr merge in any command position.\nniwa reap is denied; git push --force asks.\nEOF\n)"'
row allow $'cat > notes.md <<\'EOF\'\ngh pr merge 12\ncurl https://example.com\nEOF'
row allow 'grep -rn "gh pr merge" docs/'
row allow 'rg "curl|wget" .'
row allow '# gh pr merge 12'
row allow 'git status  # then gh pr merge 12 by hand'
row allow 'git status  # done; gh pr merge 12 is next'
row allow $'# don\'t run gh pr merge here\ngit status'
row allow 'gh pr view 12 --json mergeable'
row allow 'gh pr create --title "merge helper" --body "adds a merge helper"'
row allow 'ls merge/'
row allow 'echo niwa reap'
row allow 'git log --grep="force-push"'

# Backticks inside double quotes are command substitution: bash runs them.
row deny  'gh pr comment 12 --body "next: `gh pr merge 12`"'

# --- Ambiguous: text handed to a shell, or a command name we cannot see ----
row ask   "bash -c 'gh pr merge 12'"
row ask   'sh -c "cd repo && gh pr merge 12"'
row ask   'eval "gh pr merge 12"'
row ask   $'bash <<\'EOF\'\ngh pr merge 12\nEOF'
row ask   '$GH pr merge 12'
row ask   $'cat <<EOF\n$(gh pr merge 12)\nEOF'
row ask   'echo "unclosed gh pr merge 12'
row ask   $'bash -s <<\'EOF\'\ngit push --force origin feature\nEOF'
row allow $'bash -s <<\'EOF\'\ngit push -u origin HEAD 2>/dev/null\nrm -rf build\nEOF'
row allow "bash -c 'go test ./...'"
row allow 'eval "$(ssh-agent -s)"'
row allow $'cat <<EOF\nrun gh pr merge 12 by hand, in $HOME\nEOF'

# --- The scanner itself fails: ask rather than allow ----------------------
row ask   'git status' broken-awk

# --- Known limits: the hook reads text, it does not run it ----------------
# These pass because nothing in the command line names a gated command in
# command position. Enforcing policy on the operation itself is niwa#320.
row allow $'python3 - <<\'EOF\'\nimport subprocess\nsubprocess.run(["gh", "pr", "merge", "12"])\nEOF'
row allow "alias m='gh pr merge'"
row allow './scripts/merge-everything.sh'

echo
echo "$pass passed, $fail failed"

# Every row in this file must have run: a table that stopped early, or one
# whose rows stopped being counted, must not read as a pass.
declared=$(grep -c '^row ' "${BASH_SOURCE[0]}")
if [ $((pass + fail)) -ne "$declared" ] || [ "$declared" -eq 0 ]; then
    echo "ran $((pass + fail)) rows, file declares $declared" >&2
    exit 1
fi
[ "$fail" -eq 0 ]
