#!/usr/bin/env bash
# Case table for .niwa/hooks/pre_tool_use/gate-online.sh.
#
# Feeds each command to the hook as the JSON a PreToolUse event carries on
# stdin and compares the decision it prints (deny, ask, or allow when it
# prints nothing) with the expected one. Nothing here runs the commands in
# the table; they are only ever strings handed to the hook.
#
# The hook asks niwa about the session for a merge, a close or a release.
# Every hook run here gets an empty environment and a PATH holding only the
# tools the hook needs, so no niwa or koto installed on the host is ever
# reached: the rows that need niwa put a stub on PATH (or in NIWA_BIN) that
# prints a fixture document, logs its arguments, and can sleep or fail.
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
# The hook as it was before it read the grant, to compare verdicts against:
# a byte-for-byte copy of the hook at commit 2a98f60, kept here because CI
# checks out one commit. Don't edit it.
old_hook=$here/fixtures/gate-online-2a98f60.sh

for f in "$hook" "$old_hook"; do
    if [ ! -f "$f" ]; then
        echo "hook not found: $f" >&2
        exit 1
    fi
done

pass=0
fail=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The tools a hook run may use, and nothing else. A second set leaves out
# timeout, so the hook's other way of bounding the lookup runs too.
tools=$work/tools
tools_nt=$work/tools-no-timeout
mkdir -p "$tools" "$tools_nt"
for t in bash jq awk cat mktemp rm sleep timeout; do
    p=$(command -v "$t") || continue
    ln -s "$p" "$tools/$t"
    [ "$t" = timeout ] || ln -s "$p" "$tools_nt/$t"
done
for t in niwa koto; do
    if [ -e "$tools/$t" ]; then
        echo "the hook's PATH must not hold $t" >&2
        exit 1
    fi
done

# A PATH whose awk always fails, to check the hook does not allow when it
# cannot inspect a command.
broken=$work/broken
mkdir -p "$broken"
printf '#!/bin/sh\nexit 1\n' > "$broken/awk"
chmod +x "$broken/awk"

# The stub niwa. It appends its arguments to STUB_LOG, sleeps STUB_SLEEP
# seconds, prints STUB_DOC and exits STUB_EXIT, each only when set.
stub=$work/stub
mkdir -p "$stub"
cat > "$stub/niwa" <<'EOF'
#!/bin/sh
[ -n "${STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_LOG"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
[ -n "${STUB_DOC:-}" ] && cat "$STUB_DOC"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$stub/niwa"
# A NIWA_BIN that names a file which is not executable.
printf '#!/bin/sh\n' > "$stub/not-executable"

# Copies of the hook where niwa installs them, under three instance names: the
# one GATE_MERGE_EXEMPT_INSTANCE names, an ordinary one, and a name that only
# starts with the exempt one. niwa puts one copy at the instance root and one
# in every repo, named gate-online.local.sh. The instance names are made up.
# The hook from before the grant is installed the same way under old/.
exempt_name=ws+owner_coordinator-00000000
other_name=ws+some_worker-0123abcd
installed() {
    local dir=$work/$1/.claude/hooks/pre_tool_use
    mkdir -p "$dir"
    cp "${3:-$hook}" "$dir/$2"
    echo "$dir/$2"
}
exempt_hook=$(installed "new/$exempt_name" gate-online.sh)
exempt_repo_hook=$(installed "new/$exempt_name/private/vision" gate-online.local.sh)
other_hook=$(installed "new/$other_name" gate-online.sh)
other_repo_hook=$(installed "new/$other_name/private/vision" gate-online.local.sh)
lookalike_hook=$(installed "new/$exempt_name-copy" gate-online.sh)
lookalike_repo_hook=$(installed "new/$exempt_name-copy/private/vision" gate-online.local.sh)
old_exempt_hook=$(installed "old/$exempt_name" gate-online.sh "$old_hook")
old_other_hook=$(installed "old/$other_name" gate-online.sh "$old_hook")

# The session id every payload carries, unless a row changes it.
session_id=0f4c5a8e-3b1d-4e2a-9c7f-1a2b3c4d5e6f

# run HOOK COMMAND [VAR=VALUE...] -> prints "decision<TAB>reason", the
# decision deny|ask|allow, or error:<detail>. The hook runs with an empty
# environment plus PATH=$tools and the assignments given; a later PATH
# replaces the first. RUN_SESSION and RUN_RELATIVE (run the hook by a
# relative path from its own directory) change the payload and the call.
RUN_SESSION=
RUN_RELATIVE=
run() {
    local run=$1 command=$2 out status payload
    shift 2
    payload=$(jq -cn --arg c "$command" --arg s "${RUN_SESSION:-$session_id}" \
        '{session_id:$s,tool_name:"Bash",tool_input:{command:$c}}')
    if [ -n "$RUN_RELATIVE" ]; then
        out=$(cd "${run%/*}" && printf '%s' "$payload" |
            env -i PATH="$tools" "$@" bash "./${run##*/}")
    else
        out=$(printf '%s' "$payload" | env -i PATH="$tools" "$@" bash "$run")
    fi
    status=$?
    if [ "$status" -ne 0 ]; then
        printf 'error:exit-%s\t\n' "$status"
        return
    fi
    if [ -z "$out" ]; then
        printf 'allow\t\n'
        return
    fi
    printf '%s' "$out" | jq -r '.hookSpecificOutput |
        "\(.permissionDecision // "error:no-decision")\t\(.permissionDecisionReason // "")"' 2>/dev/null ||
        printf 'error:bad-json\t\n'
}

# decide COMMAND [MODE] -> prints deny|ask|allow, or error:<detail>
#   broken-awk      the repository copy, with an awk that always fails
#   exempt, other, lookalike (and each with -repo for the per-repo copy)
#                   an installed copy, with GATE_MERGE_EXEMPT_INSTANCE naming
#                   the exempt instance, as every instance's settings do
#   exempt-unset    the exempt instance's copy with the var unset
#   exempt-slash    the exempt instance's copy with a var holding a path
#                   that its own path does end in
# Every other mode runs with the var unset. No niwa is on PATH in any mode,
# so these rows check the verdicts every session got before the grant.
decide() {
    local run=$hook var='' got
    local -a extra=()
    case "${2:-}" in
        broken-awk) extra=(PATH="$broken:$tools") ;;
        exempt) run=$exempt_hook var=$exempt_name ;;
        exempt-repo) run=$exempt_repo_hook var=$exempt_name ;;
        other) run=$other_hook var=$exempt_name ;;
        other-repo) run=$other_repo_hook var=$exempt_name ;;
        lookalike) run=$lookalike_hook var=$exempt_name ;;
        lookalike-repo) run=$lookalike_repo_hook var=$exempt_name ;;
        exempt-unset) run=$exempt_hook ;;
        exempt-slash) run=$exempt_hook var=new/$exempt_name ;;
        exempt-list) run=$exempt_hook var=$other_name,$exempt_name ;;
        other-list) run=$other_hook var=$other_name,$exempt_name ;;
        lookalike-list) run=$lookalike_hook var=$other_name,$exempt_name ;;
        exempt-list-repo) run=$exempt_repo_hook var=$exempt_name,$other_name ;;
        exempt-list-blanks) run=$exempt_hook var=,$exempt_name, ;;
        exempt-list-slash) run=$exempt_hook var=new/$exempt_name,$exempt_name ;;
        other-list-absent) run=$other_hook var=$exempt_name,ws+third_one-deadbeef ;;
    esac
    [ -n "$var" ] && extra+=(GATE_MERGE_EXEMPT_INSTANCE="$var")
    got=$(run "$run" "$1" ${extra[@]+"${extra[@]}"})
    echo "${got%%	*}"
}

# row EXPECTED COMMAND [MODE]   (MODE as for decide)
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
row deny  'gh pr merge 12'
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

# --- The one instance exempt from the merge rule ---------------------------
# Merging is allowed there, in every form the merge rule denies.
row allow 'gh pr merge 12 --squash' exempt
row allow 'gh api -X PUT repos/o/r/pulls/12/merge' exempt
row allow "gh api graphql -f query='mutation { mergePullRequest(input:{pullRequestId:\"x\"}) { clientMutationId } }'" exempt
row allow 'cd repo && gh pr merge 12' exempt
# Every other rule still applies there.
row deny  'curl https://example.com' exempt
row deny  'gh pr merge 12 && curl https://example.com' exempt
row deny  'gh repo delete owner/repo --yes' exempt
row deny  'niwa reap' exempt
row ask   'gh issue close 5' exempt
row ask   'git push --force origin main' exempt
# A command name the scanner can't read takes no exemption: before the grant
# this merge was allowed here, and now it asks.
row ask   '$GH pr merge 12' exempt
row ask   '$GH api -X PUT repos/o/r/pulls/12/merge' exempt
# Installed in any other instance, merging is still denied.
row deny  'gh pr merge 12 --squash' other
row deny  'gh api -X PUT repos/o/r/pulls/12/merge' other
row deny  'gh pr merge 12 --squash' lookalike
# The per-repo copy follows the same rule as the instance-level one.
row allow 'gh pr merge 12 --squash' exempt-repo
row allow 'gh api -X PUT repos/o/r/pulls/12/merge' exempt-repo
row deny  'curl https://example.com' exempt-repo
row deny  'gh pr merge 12 --squash' other-repo
row deny  'gh pr merge 12 --squash' lookalike-repo
# With no instance named, or a value that is not an instance name, nothing is
# exempt.
row deny  'gh pr merge 12 --squash' exempt-unset
row deny  'gh pr merge 12 --squash' exempt-slash

# --- A comma-separated list names one merging instance per host ----------
# Both named instances may merge; a lookalike and an unnamed one may not;
# empty entries and entries holding a slash are skipped, never matched.
row allow 'gh pr merge 12 --squash' exempt-list
row allow 'gh pr merge 12 --squash' other-list
row allow 'gh api -X PUT repos/o/r/pulls/12/merge' exempt-list-repo
row deny  'gh pr merge 12 --squash' lookalike-list
row deny  'gh pr merge 12 --squash' other-list-absent
row allow 'gh pr merge 12 --squash' exempt-list-blanks
row allow 'gh pr merge 12 --squash' exempt-list-slash
row deny  'curl https://example.com' exempt-list
row deny  'niwa reap' other-list

# --- Known limits: the hook reads text, it does not run it ----------------
# These pass because nothing in the command line names a gated command in
# command position. Enforcing policy on the operation itself is niwa#320.
row allow $'python3 - <<\'EOF\'\nimport subprocess\nsubprocess.run(["gh", "pr", "merge", "12"])\nEOF'
row allow "alias m='gh pr merge'"
row allow './scripts/merge-everything.sh'

# ===================================================== the dispatch's grant
#
# The stub answers `niwa authority check` with one of the documents below.
# Each bound document carries a point for all three authorities, with the
# decider and author exclusion it names.

docs=$work/docs
mkdir -p "$docs"

# bound_doc NAME LEVEL HELD DECIDER EXCLUSION   (HELD comma-separated)
bound_doc() {
    jq -n --arg level "$2" --arg held "$3" --arg d "$4" --arg x "$5" '{
        schema: "niwa.authority.check/v1",
        state: "bound",
        binding: "mapping",
        dispatch_id: "3c803591-4c01-486f-a927-f96ec399d6a7",
        grant: [$held | split(",")[] | select(. != "") | {authority: ., sources: ["dispatch"]}],
        level: $level,
        level_source: "workspace",
        grant_ceiling_source: "workspace",
        points: [("merge-pr", "close-issue", "cut-release")
            | {point: ., decider: $d, author_exclusion: $x}]
    }' > "$docs/$1.json"
}
bound_doc bound-all autonomous merge-pr,close-issue,cut-release session off
bound_doc bound-merge-close autonomous merge-pr,close-issue session off
bound_doc bound-merge autonomous merge-pr session off
bound_doc bound-none autonomous "" session off
bound_doc bound-dispatcher supervised merge-pr,close-issue,cut-release dispatcher on
bound_doc bound-dispatcher-merge supervised merge-pr dispatcher on
bound_doc bound-person strict merge-pr,close-issue,cut-release person on
bound_doc bound-exclusion autonomous merge-pr,close-issue,cut-release session on
jq -n '{schema: "niwa.authority.check/v1", state: "record-unusable", reason: "record-missing",
    dispatch_id: "3c803591-4c01-486f-a927-f96ec399d6a7", grant: []}' > "$docs/record-unusable.json"
jq -n '{schema: "niwa.authority.check/v1", state: "not-dispatched", reason: "no-mapping",
    grant: []}' > "$docs/not-dispatched.json"
# Answers the hook must not trust, each built on one that holds everything.
all=$docs/bound-all.json
jq '.schema = "niwa.authority.check/v2"' "$all" > "$docs/bad-schema.json"
jq '.state = "granted"' "$all" > "$docs/bad-state.json"
jq '.grant += [{authority: "deploy", sources: ["dispatch"]}]' "$all" > "$docs/bad-authority.json"
jq '.level = "lenient"' "$all" > "$docs/bad-level.json"
jq '.points[2].decider = "anyone"' "$all" > "$docs/bad-decider.json"
jq '.points[2].author_exclusion = "sometimes"' "$all" > "$docs/bad-exclusion.json"
jq '.points = []' "$all" > "$docs/missing-point.json"
cat "$all" "$all" > "$docs/two-docs.json"
: > "$docs/empty.json"
# What a niwa without the command prints.
printf 'Inspect authority records\n\nUsage:\n  niwa authority [command]\n' > "$docs/no-command.json"

# fixture NAME: sets FX to the assignments a hook run gets for that niwa,
# and RUN_SESSION when the payload's session id changes.
fixture() {
    RUN_SESSION=
    case "$1" in
        no-niwa) FX=() ;;
        niwa-bin) FX=(NIWA_BIN="$stub/niwa" STUB_DOC="$docs/bound-merge.json") ;;
        niwa-bin-missing) FX=(NIWA_BIN="$work/nowhere/niwa") ;;
        niwa-bin-not-executable) FX=(NIWA_BIN="$stub/not-executable") ;;
        exit-1) FX=(PATH="$stub:$tools" STUB_DOC="$all" STUB_EXIT=1) ;;
        sleep) FX=(PATH="$stub:$tools" STUB_DOC="$all" STUB_SLEEP=30) ;;
        sleep-no-timeout) FX=(PATH="$stub:$tools_nt" STUB_DOC="$all" STUB_SLEEP=30) ;;
        no-timeout) FX=(PATH="$stub:$tools_nt" STUB_DOC="$docs/bound-merge.json") ;;
        bad-session) FX=(PATH="$stub:$tools" STUB_DOC="$all") RUN_SESSION=not-a-uuid ;;
        *)
            # A misspelt fixture would make the stub print nothing, which
            # reads as a failed lookup and passes every today's-verdict row.
            if [ ! -f "$docs/$1.json" ]; then
                echo "no fixture document: $1" >&2
                exit 1
            fi
            FX=(PATH="$stub:$tools" STUB_DOC="$docs/$1.json")
            ;;
    esac
}

# where NAME: sets HOOK, OLD (the same instance's copy of the hook from
# before the grant) and EXEMPT (the GATE_MERGE_EXEMPT_INSTANCE value).
#   listed     the instance the var names
#   unlisted   another instance, the var naming the first
#   unset      the first instance, the var unset ("names no instance")
#   relative   as unset, with the hook run by a relative path
where() {
    RUN_RELATIVE=
    case "$1" in
        listed) HOOK=$exempt_hook OLD=$old_exempt_hook EXEMPT=$exempt_name ;;
        unlisted) HOOK=$other_hook OLD=$old_other_hook EXEMPT=$exempt_name ;;
        unset) HOOK=$exempt_hook OLD=$old_exempt_hook EXEMPT= ;;
        relative) HOOK=$exempt_hook OLD=$old_exempt_hook EXEMPT='' RUN_RELATIVE=1 ;;
    esac
}

# run_at FIXTURE WHERE COMMAND [VAR=VALUE...]: run's output for the new hook.
run_at() {
    local name=$1 at=$2 command=$3
    shift 3
    fixture "$name"
    where "$at"
    run "$HOOK" "$command" ${FX[@]+"${FX[@]}"} ${EXEMPT:+GATE_MERGE_EXEMPT_INSTANCE=$EXEMPT} "$@"
}

report() {
    if [ "$1" = ok ]; then
        pass=$((pass + 1))
        printf 'ok    %s\n' "$2"
    else
        fail=$((fail + 1))
        printf 'FAIL  %s\n' "$2"
    fi
}

# grant EXPECTED FIXTURE WHERE COMMAND [TEXT...]
#   the decision, and each TEXT the reason must contain
grant() {
    local expected=$1 name=$2 at=$3 command=$4 got decision reason text result=ok
    shift 4
    got=$(run_at "$name" "$at" "$command")
    decision=${got%%	*}
    reason=${got#*	}
    [ "$decision" = "$expected" ] || result=FAIL
    for text in "$@"; do
        case "$reason" in *"$text"*) ;; *) result=FAIL ;; esac
    done
    report "$result" "$(printf '%-5s %-24s %-8s %s' "$expected" "$name" "$at" "$(printf '%q' "$command")")$(
        if [ "$result" != ok ]; then printf '  got %s: %s' "$decision" "$reason"
        elif [ -n "$reason" ]; then printf '  (%s)' "$reason"
        fi)"
}

# calls COUNT FIXTURE COMMAND [ARGS]: the stub ran COUNT times for COMMAND in
# an unlisted instance, and when ARGS is given, its one call had exactly
# those arguments.
calls() {
    local count=$1 name=$2 command=$3 log=$work/calls.log got result=ok
    : > "$log"
    run_at "$name" unlisted "$command" STUB_LOG="$log" >/dev/null
    got=$(wc -l < "$log" | tr -d ' ')
    [ "$got" = "$count" ] || result=FAIL
    if [ $# -ge 4 ] && [ "$(cat "$log")" != "$4" ]; then result=FAIL; fi
    report "$result" "$(printf 'calls %-3s %-18s %s' "$count" "$name" "$(printf '%q' "$command")")$(
        [ "$result" = ok ] || printf '  got %s: %s' "$got" "$(cat "$log")")"
}

# timed SECONDS EXPECTED FIXTURE COMMAND: as grant in an unlisted instance,
# and the hook run took less than SECONDS.
timed() {
    local limit=$1 expected=$2 name=$3 command=$4 got start elapsed result=ok
    start=$(now)
    got=$(run_at "$name" unlisted "$command")
    elapsed=$(( $(now) - start ))
    [ "${got%%	*}" = "$expected" ] || result=FAIL
    [ "$elapsed" -lt $((limit * 1000)) ] || result=FAIL
    report "$result" "$(printf '%-5s %-24s %sms, under %ss  %s' "$expected" "$name" "$elapsed" "$limit" \
        "$(printf '%q' "$command")")"
}

# now: milliseconds, from bash 5's EPOCHREALTIME, else whole seconds.
now() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        local t=${EPOCHREALTIME/[.,]/}
        echo $((10#$t / 1000))
    else
        echo $(($(date +%s) * 1000))
    fi
}

graphql_merge="gh api graphql -f query='mutation { mergePullRequest(input:{pullRequestId:\"x\"}) { clientMutationId } }'"
graphql_auto="gh api graphql -f query='mutation { enablePullRequestAutoMerge(input:{pullRequestId:\"x\"}) { clientMutationId } }'"

# --- A coordinator holding merge-pr and close-issue, no instance named -----
grant allow bound-merge-close unset 'gh pr merge 12'
grant allow bound-merge-close unset 'gh issue close 34'
grant ask   bound-merge-close unset 'gh release create v1' \
    'holds merge-pr,close-issue; needs cut-release'

# --- Holding all three, as a workspace whose ceiling holds all three -------
grant allow bound-all unset 'gh pr merge 12'
grant allow bound-all unset 'gh issue close 34'
grant allow bound-all unset 'gh release create v1'
grant allow bound-all unset 'gh pr merge 12 && gh issue close 34 && gh release create v1'

# --- Every merge form, for a holder of merge-pr ---------------------------
grant allow bound-merge unset 'gh pr merge 12 --squash'
grant allow bound-merge unset 'gh pr merge 12 --auto'
grant allow bound-merge unset 'gh api -X PUT repos/o/r/pulls/12/merge'
grant allow bound-merge unset "$graphql_merge"
grant allow bound-merge unset "$graphql_auto"
grant allow bound-merge unset 'cd repo && gh pr merge 12'

# --- Lacking the authority: merge and close are denied, release asks ------
grant deny  bound-none unset 'gh pr merge 12' 'holds none' 'needs merge-pr'
grant deny  bound-none unset 'gh issue close 34' 'holds none' 'needs close-issue'
grant ask   bound-none unset 'gh release create v1' 'holds none' 'needs cut-release'
grant deny  bound-merge unset 'gh issue close 34' 'holds merge-pr' 'needs close-issue'
grant ask   bound-merge unset 'gh release create v1' 'holds merge-pr' 'needs cut-release'
# The exemption list plays no part for a bound session.
grant deny  bound-none listed 'gh pr merge 12' 'holds none' 'needs merge-pr'
grant deny  bound-merge listed 'gh issue close 34' 'holds merge-pr' 'needs close-issue'

# --- Held, but the level hands the decision to someone else ---------------
grant deny  bound-dispatcher unset 'gh pr merge 12' 'level supervised' 'merge-pr settled by dispatcher'
grant deny  bound-dispatcher unset 'gh issue close 34' 'level supervised' 'close-issue settled by dispatcher'
grant deny  bound-dispatcher unset 'gh release create v1' 'level supervised' 'cut-release settled by dispatcher'
grant deny  bound-dispatcher listed 'gh pr merge 12' 'level supervised' 'settled by dispatcher'
# Lacking cut-release at the same level keeps today's ask.
grant ask   bound-dispatcher-merge unset 'gh release create v1' 'holds merge-pr' 'needs cut-release'
grant deny  bound-person unset 'gh pr merge 12' 'level strict' 'merge-pr settled by person'
grant ask   bound-person unset 'gh issue close 34' 'level strict' 'close-issue settled by person'
grant ask   bound-person unset 'gh release create v1' 'level strict' 'cut-release settled by person'
grant deny  bound-person listed 'gh pr merge 12' 'level strict' 'settled by person'
grant deny  bound-exclusion unset 'gh pr merge 12' 'author exclusion' 'merge-pr'
grant ask   bound-exclusion unset 'gh issue close 34' 'author exclusion' 'close-issue'
grant ask   bound-exclusion unset 'gh release create v1' 'author exclusion' 'cut-release'
grant deny  bound-exclusion listed 'gh pr merge 12' 'author exclusion' 'merge-pr'

# --- A grant never lifts what something else in the command earned -------
grant deny  bound-merge unset 'gh pr merge 12; curl x'
grant deny  bound-merge unset 'gh pr merge 12 && gh issue close 34' 'needs close-issue'
grant ask   bound-all unset 'gh pr merge 12 && git push --force origin main' 'git push --force'
grant ask   bound-all unset 'gh issue close 34; gh auth switch' 'gh auth switch'
grant deny  bound-all unset 'gh release create v1 && gh repo delete o/r --yes' 'gh repo delete'

# --- A dispatched session whose record can't be used: never exempt -------
grant deny  record-unusable listed 'gh pr merge 12'
grant ask   record-unusable listed 'gh issue close 34'
grant ask   record-unusable listed 'gh release create v1'
grant deny  record-unusable unlisted 'gh pr merge 12'

# --- A session niwa didn't dispatch: today's verdict, exemption included --
grant allow not-dispatched listed 'gh pr merge 12'
grant deny  not-dispatched unlisted 'gh pr merge 12'
grant ask   not-dispatched listed 'gh issue close 34'
grant ask   not-dispatched listed 'gh release create v1'
grant ask   not-dispatched unlisted 'gh issue close 34'
grant ask   not-dispatched unlisted 'gh release create v1'

# --- A failed lookup: today's verdict, though the stub would grant all ----
# In an unlisted instance today's verdict is deny for a merge and ask for a
# close or a release; a lookup that wrongly counted would allow all three.
failures=(no-niwa niwa-bin-missing niwa-bin-not-executable exit-1 no-command
    bad-schema bad-state bad-authority bad-level bad-decider bad-exclusion
    missing-point two-docs empty bad-session)
for failure in "${failures[@]}"; do
    grant deny  "$failure" unlisted 'gh pr merge 12'
    grant ask   "$failure" unlisted 'gh issue close 34'
    grant ask   "$failure" unlisted 'gh release create v1'
    grant allow "$failure" listed 'gh pr merge 12'
done
# A hook run by a relative path can't anchor the lookup.
grant deny  bound-all relative 'gh pr merge 12'
grant ask   bound-all relative 'gh issue close 34'

# --- A niwa that hangs: the bound holds, today's verdict stands -----------
timed 5 deny sleep 'gh pr merge 12'
timed 5 deny sleep-no-timeout 'gh pr merge 12'
# Without timeout installed, an answer that comes back in time still counts.
grant allow no-timeout unset 'gh pr merge 12'
grant deny  no-timeout unset 'gh issue close 34' 'holds merge-pr' 'needs close-issue'

# --- Finding niwa through NIWA_BIN, with no niwa on PATH ------------------
grant allow niwa-bin unset 'gh pr merge 12'
grant deny  niwa-bin unset 'gh issue close 34' 'holds merge-pr' 'needs close-issue'

# --- niwa runs only for a merge, a close or a release, once at most -------
calls 0 bound-all 'git status'
calls 0 bound-all 'gh pr view 12'
calls 0 bound-all 'curl https://example.com'
calls 0 bound-all 'gh pr merge 12; curl https://example.com'
calls 0 bad-session 'gh pr merge 12'
calls 1 bound-all 'gh pr merge 12 && gh issue close 34' \
    "authority check --json --session $session_id -C ${other_hook%/*} --point merge-pr --point close-issue"
calls 1 bound-all 'gh release create v1; gh pr merge 12; gh pr merge 13' \
    "authority check --json --session $session_id -C ${other_hook%/*} --point merge-pr --point cut-release"

# --- Rules no grant covers, for a session holding everything -------------
grant deny  bound-all listed 'curl https://example.com'
grant deny  bound-all listed 'wget https://example.com'
grant deny  bound-all listed 'nc -l 8080'
grant deny  bound-all listed 'gh repo delete owner/repo --yes'
grant deny  bound-all listed 'niwa reap'
grant ask   bound-all listed 'gh auth switch'
grant ask   bound-all listed 'unset GH_TOKEN'
grant ask   bound-all listed 'git push --force origin main'
grant ask   bound-all listed "bash -c 'gh pr merge 12'"
grant ask   bound-all listed 'echo "unclosed gh pr merge 12'
grant ask   bound-all listed '$GH pr merge 12'
grant ask   not-dispatched listed '$GH pr merge 12'
grant ask   no-niwa listed '$GH pr merge 12'

# --- Never more permissive than before the grant -------------------------
# Every command below runs through the new hook under every fixture, in a
# listed and an unlisted instance, and through the hook from before the
# grant (vendored at tests/fixtures/gate-online-2a98f60.sh) in the same
# instance. Each entry is NEEDS|BASE|COMMAND. NEEDS is the authorities a
# grant would need, "-" for none, or "!" for the one deliberate change ($GH
# pr merge, which now asks everywhere). BASE is the verdict the rest of the
# command earns from the rules no grant covers. The rules:
#   NEEDS "-": the same verdict as before, for every session.
#   NEEDS "!": ask, for every session.
#   not-dispatched and every failed lookup: the same verdict as before.
#   record-unusable: the verdict an unlisted instance got before.
#   bound, the grant allowing none of NEEDS: never more permissive than
#   before.
#   bound, the grant allowing all of NEEDS: BASE.
#   bound, the grant allowing some: no more permissive than BASE, deny for a
#   merge it doesn't allow, and at least ask for a close or a release it
#   doesn't allow (a missing close-issue is denied, but a person decider
#   asks; the rows above pin each exact verdict).
compare_cmds=(
    '-|-|curl https://example.com'
    '-|-|wget https://example.com'
    '-|-|nc -l 8080'
    '-|-|ncat example.com 80'
    '-|-|netcat example.com 80'
    '-|-|gh repo delete owner/repo --yes'
    '-|-|niwa reap'
    '-|-|gh auth switch'
    '-|-|unset GH_TOKEN'
    '-|-|git push --force origin feature'
    '-|-|git push --force-with-lease origin feature'
    '-|-|git push -f origin feature'
    '-|-|git push origin +feature'
    "-|-|bash -c 'gh pr merge 12'"
    '-|-|sh -c "gh issue close 34"'
    "-|-|eval 'gh release create v1'"
    $'-|-|bash <<\'EOF\'\ngh pr merge 12\nEOF'
    $'-|-|cat <<EOF\n$(gh pr merge 12)\nEOF'
    '-|-|echo "unclosed gh pr merge 12'
    "-|-|echo 'unclosed gh issue close 34"
    '-|-|$GH issue close 34'
    '-|-|git status'
    '-|-|gh pr view 12'
    '-|-|git commit -m "gh pr merge 12"'
    '!|-|$GH pr merge 12'
    '!|-|$GH api -X PUT repos/o/r/pulls/12/merge'
    'merge-pr|allow|gh pr merge 12'
    'merge-pr|allow|gh pr merge 12 --squash'
    'merge-pr|allow|gh pr merge 12 --auto'
    'merge-pr|allow|gh api -X PUT repos/o/r/pulls/12/merge'
    "merge-pr|allow|$graphql_merge"
    "merge-pr|allow|$graphql_auto"
    'merge-pr|allow|cd repo && gh pr merge 12'
    'merge-pr|allow|x=$(gh pr merge 12)'
    'merge-pr|deny|gh pr merge 12; curl x'
    'merge-pr|ask|gh pr merge 12 && gh auth switch'
    'close-issue|allow|gh issue close 34'
    'close-issue|ask|gh issue close 34 && git push --force'
    'cut-release|allow|gh release create v1'
    'merge-pr,close-issue|allow|gh pr merge 12 && gh issue close 34'
    'merge-pr,cut-release|allow|gh pr merge 12; gh release create v1'
    'merge-pr,close-issue,cut-release|allow|gh pr merge 1; gh issue close 2; gh release create v3'
)
# Every session state, and a few of the failed lookups (each kind of failure
# has its own rows above).
compare_fixtures=(
    bound-all bound-merge-close bound-merge bound-none bound-dispatcher
    bound-dispatcher-merge bound-person bound-exclusion record-unusable
    not-dispatched no-niwa exit-1 no-command bad-decider bad-session
)

# allows FIXTURE: the authorities that fixture's grant lets the session use.
allows() {
    case "$1" in
        bound-all) echo merge-pr,close-issue,cut-release ;;
        bound-merge-close) echo merge-pr,close-issue ;;
        bound-merge) echo merge-pr ;;
        *) echo ;;
    esac
}

rank() {
    case "$1" in allow) echo 0 ;; ask) echo 1 ;; deny) echo 2 ;; *) echo 9 ;; esac
}

# Before the grant, per instance: the decision for each command.
old_listed=()
old_unlisted=()
for i in "${!compare_cmds[@]}"; do
    command=${compare_cmds[$i]#*|*|}
    where listed
    got=$(run "$OLD" "$command" GATE_MERGE_EXEMPT_INSTANCE="$EXEMPT")
    old_listed[$i]=${got%%	*}
    where unlisted
    got=$(run "$OLD" "$command" GATE_MERGE_EXEMPT_INSTANCE="$EXEMPT")
    old_unlisted[$i]=${got%%	*}
done

for name in "${compare_fixtures[@]}"; do
    granted=$(allows "$name")
    bad=0
    for at in listed unlisted; do
        for i in "${!compare_cmds[@]}"; do
            needs=${compare_cmds[$i]%%|*}
            base=${compare_cmds[$i]#*|}
            base=${base%%|*}
            command=${compare_cmds[$i]#*|*|}
            if [ "$at" = listed ]; then before=${old_listed[$i]}; else before=${old_unlisted[$i]}; fi
            got=$(run_at "$name" "$at" "$command")
            got=${got%%	*}
            # How many of NEEDS the grant allows, and the least verdict the
            # rest leaves: BASE, raised by each needed authority not allowed.
            allowed=0
            total=0
            floor=$base
            if [ "$needs" != - ] && [ "$needs" != '!' ]; then
                for a in ${needs//,/ }; do
                    total=$((total + 1))
                    case ",$granted," in
                        *",$a,"*) allowed=$((allowed + 1)) ;;
                        *)
                            if [ "$a" = merge-pr ]; then floor=deny
                            elif [ "$floor" = allow ]; then floor=ask
                            fi
                            ;;
                    esac
                done
            fi
            if [ "$needs" = '!' ]; then
                want="ask"
                ok=$([ "$got" = ask ] && echo 1)
            elif [ "$needs" = - ]; then
                want="$before (as before)"
                ok=$([ "$got" = "$before" ] && echo 1)
            else
                case "$name" in
                    bound-*)
                        if [ "$allowed" -eq 0 ]; then
                            want="$before or stricter"
                            ok=$([ "$(rank "$got")" -ne 9 ] && [ "$(rank "$got")" -ge "$(rank "$before")" ] && echo 1)
                        elif [ "$allowed" -eq "$total" ]; then
                            want="$base (the grant allows every gated action)"
                            ok=$([ "$got" = "$base" ] && echo 1)
                        else
                            want="$floor or stricter (the grant allows some)"
                            ok=$([ "$(rank "$got")" -ne 9 ] && [ "$(rank "$got")" -ge "$(rank "$floor")" ] && echo 1)
                        fi
                        ;;
                    record-unusable)
                        want="${old_unlisted[$i]} (as an unlisted instance before)"
                        ok=$([ "$got" = "${old_unlisted[$i]}" ] && echo 1)
                        ;;
                    *)
                        want="$before (as before)"
                        ok=$([ "$got" = "$before" ] && echo 1)
                        ;;
                esac
            fi
            if [ -n "$ok" ]; then
                pass=$((pass + 1))
            else
                fail=$((fail + 1))
                bad=$((bad + 1))
                printf 'FAIL  compare %-24s %-8s want %s, got %s: %s\n' "$name" "$at" "$want" "$got" \
                    "$(printf '%q' "$command")"
            fi
        done
    done
    printf '%-5s compare %-24s %d commands x 2 instances, %d off\n' \
        "$([ "$bad" -eq 0 ] && echo ok || echo FAIL)" "$name" "${#compare_cmds[@]}" "$bad"
done

echo
echo "$pass passed, $fail failed"

# Every row in this file must have run: a table that stopped early, or one
# whose rows stopped being counted, must not read as a pass. The failure
# loop's four grant rows run once per failure fixture, and the comparison
# runs once per fixture, instance and command.
declared=$(grep -cE '^ *(row|grant|calls|timed) [a-z0-9]' "${BASH_SOURCE[0]}")
expected=$((declared + 4 * (${#failures[@]} - 1) + ${#compare_fixtures[@]} * 2 * ${#compare_cmds[@]}))
if [ $((pass + fail)) -ne "$expected" ] || [ "$declared" -eq 0 ]; then
    echo "ran $((pass + fail)) rows, file declares $expected" >&2
    exit 1
fi
[ "$fail" -eq 0 ]
