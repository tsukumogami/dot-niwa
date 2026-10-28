#!/usr/bin/env bash
# Case table for .niwa/hooks/pre_tool_use/env-print-guard.sh.
#
# Feeds each command to the hook as the JSON a PreToolUse event carries on
# stdin and compares the decision it prints (deny, ask, or allow when it
# prints nothing) with the expected one. Nothing here runs the commands in
# the table; they are only ever strings handed to the hook. Every deny is
# also checked for its wording: it says why, names the allowed forms, and
# carries no text from the command (the rows use the made-up MARKER_NAME and
# marker-value so a leak would show).
#
# Usage: tests/env-print-guard.test.sh [path-to-hook]
#   The hook defaults to the copy in this repository. Point it at an
#   installed copy to check that one instead.
#
# Exit status: 0 when every row matches, 1 when any row mismatches or the
# hook misbehaves (non-zero exit, output that is not a decision).
#
# Requires: jq

# The rows are commands kept as text, so an unexpanded $( ) in single quotes
# is what they mean.
# shellcheck disable=SC2016

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hook=${1:-$here/../.niwa/hooks/pre_tool_use/env-print-guard.sh}

if [ ! -f "$hook" ]; then
    echo "hook not found: $hook" >&2
    exit 1
fi

pass=0
fail=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Nothing here calls koto, and every hook run gets an empty environment. A
# run on a workstation still drops koto's session variables and points HOME
# at the scratch directory first, so no part of it can reach a real store.
unset "${!KOTO_SESSION@}"
export HOME=$work/home
mkdir -p "$HOME"

# The tools a hook run may use, and nothing else.
tools=$work/tools
mkdir -p "$tools"
for t in bash jq awk cat; do
    p=$(command -v "$t") || continue
    ln -s "$p" "$tools/$t"
done

# A PATH whose awk always fails, to check the hook does not allow when it
# cannot inspect a command.
broken=$work/broken
mkdir -p "$broken"
printf '#!/bin/sh\nexit 1\n' > "$broken/awk"
chmod +x "$broken/awk"

# decide COMMAND [MODE] -> prints "decision<TAB>reason", the decision
# deny|ask|allow, or error:<detail>. The hook runs with an empty environment
# plus PATH=$tools. MODE broken-awk puts the failing awk first on PATH; MODE
# raw hands COMMAND to the hook as the whole payload instead of a command.
decide() {
    local command=$1 path=$tools out status payload
    case "${2:-}" in
        broken-awk) path=$broken:$tools ;;
    esac
    if [ "${2:-}" = raw ]; then
        payload=$command
    else
        payload=$(jq -cn --arg c "$command" '{tool_name:"Bash",tool_input:{command:$c}}')
    fi
    out=$(printf '%s' "$payload" | env -i PATH="$path" bash "$hook")
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

# A deny must say why and name every allowed form, and must not quote the
# command: no made-up marker, and nothing but the fixed text.
wording_ok() {
    local why=$1 form
    case "$why" in
        "Blocked by env-print-guard hook: "*) ;;
        *) return 1 ;;
    esac
    case "$why" in *MARKER*|*marker*) return 1 ;; esac
    for form in 'secrets included' 'env | cut -d= -f1' 'printenv NAME' \
        'env VAR=value cmd' 'env -u VAR cmd' 'set -e' 'set -euo pipefail' 'set -x' 'set -- a b'; do
        case "$why" in *"$form"*) ;; *) return 1 ;; esac
    done
}

# row EXPECTED COMMAND [MODE]   (MODE as for decide)
row() {
    local expected=$1 command=$2 got decision why
    got=$(decide "$command" "${3:-}")
    decision=${got%%	*}
    why=${got#*	}
    if [ "$decision" = "$expected" ] && { [ "$decision" != deny ] || wording_ok "$why"; }; then
        pass=$((pass + 1))
        printf 'ok    %-5s  %s\n' "$expected" "$(printf '%q' "$command")"
    else
        fail=$((fail + 1))
        printf 'FAIL  want %-5s got %-12s  %s\n' "$expected" "$decision" "$(printf '%q' "$command")"
        [ "$decision" = deny ] && printf '      reason: %s\n' "$why"
    fi
}

# --- The bare forms -------------------------------------------------------
row deny  'env'
row deny  'printenv'
row deny  'set'

# --- Inside pipelines, chains and substitutions ---------------------------
row deny  'env | sort'
row deny  'env | grep -i path'
row deny  'printenv | sort'
row deny  'set | head -50'
row deny  'cat notes.txt | env'
row deny  'true; env'
row deny  'env; true'
row deny  'true && printenv'
row deny  'env && true'
row deny  'false || set'
row deny  'env || true'
row deny  'git status & env'
row deny  $'git status\nenv'
row deny  'echo $(env)'
row deny  'x=$(printenv)'
row deny  'echo "$(set)"'
row deny  'echo `env`'
row deny  'diff <(env) /dev/null'
row deny  '(env)'
row deny  '{ env; }'
row deny  'if true; then env; fi'
row deny  'for f in a b; do printenv; done'
row deny  'cd repo && env | sort'

# --- Spellings and wrappers -----------------------------------------------
row deny  '/usr/bin/env'
row deny  '"env"'
row deny  "'printenv'"
row deny  'e\nv'
row deny  'command env'
row deny  'builtin set'
row deny  'exec env'
row deny  'nohup printenv'
row deny  'sudo env'
row deny  'timeout 5 env'
row deny  'time env'
row deny  'time -p env'
row deny  'command -p env'
row deny  '! env'
row deny  'env > out.txt'
row deny  'env 2>&1'
row deny  'MARKER_NAME=marker-value env'

# --- env with options or assignments but no command still prints ---------
row deny  'env -u MARKER_NAME'
row deny  'env --unset=MARKER_NAME'
row deny  'env MARKER_NAME=marker-value'
row deny  'env -0'
row deny  'env --'
row deny  'printenv -0'

# --- Pipes that are not straight into cut -d= -f1 -------------------------
row deny  'env | cut -d= -f2'
row deny  'env | cut -d: -f1'
row deny  'env | cut -d= -f1-'
row deny  'env | cut -d= -f1 names.txt'
row deny  'env | sort | cut -d= -f1'
row deny  'env || cut -d= -f1'
row deny  'env |& cut -d= -f1'
row deny  'env | (cut -d= -f1)'
row deny  'set | cut -d= -f1'

# --- Names only -----------------------------------------------------------
row allow 'env | cut -d= -f1'
row allow 'env|cut -d= -f1'
row allow "env | cut -d '=' -f 1"
row allow 'env | cut -d"=" -f1'
row allow 'env | cut -f1 -d='
row allow 'env | /usr/bin/cut -d= -f1'
row allow 'env | cut -d= -f1 | sort'
row allow 'env | cut -d= -f1 | grep -E ^KOTO'
row allow 'env | cut -d= -f1 > names.txt'
row allow 'printenv | cut -d= -f1'
row allow 'echo hi | env | cut -d= -f1'
row allow 'x=$(env | cut -d= -f1)'

# --- env running a command ------------------------------------------------
row allow 'env MARKER_NAME=marker-value make test'
row allow 'env -u MARKER_NAME git status'
row allow 'env -u MARKER_NAME -u OTHER_NAME bash tests/run.sh'
row allow 'env --unset=MARKER_NAME git status'
row allow 'env -i PATH=/usr/bin bash script.sh'
row allow 'env -C /tmp ls'
row allow 'env -- ls'
row allow 'env -i'
row allow 'env -i MARKER_NAME=marker-value'
row allow 'env --help'
row allow 'env -S "printf %s\n hi"'
row allow '/usr/bin/env python3 script.py'
row allow 'MARKER_NAME=marker-value env make'

# --- printenv with a name -------------------------------------------------
row allow 'printenv HOME'
row allow 'printenv HOME PATH'
row allow 'printenv -0 HOME'
row allow 'printenv HOME >/dev/null && echo set'
row allow 'printenv --help'

# --- set with options or arguments ----------------------------------------
row allow 'set -e'
row allow 'set -u'
row allow 'set -x'
row allow 'set +x'
row allow 'set -o pipefail'
row allow 'set -euo pipefail'
row allow 'set -- a b'
row allow 'set -o'
row allow 'set -e; make test'
row allow 'true && set -x'

# --- Ordinary commands that mention env -----------------------------------
row allow 'ls /usr/bin/env'
row allow 'command -v env'
row allow 'command -V printenv'
row allow 'cat .local.env'
row allow 'grep env README.md'
row allow 'grep -rn printenv .'
row allow 'echo env'
row allow 'echo printenv set'
row allow 'git commit -m "run env to list the names"'
row allow "git commit -m 'set'"
row allow 'echo "$(echo env)"'
row allow $'cat > notes.md <<\'EOF\'\nenv\nprintenv\nset\nEOF'
row allow 'true # env'
row allow 'source ./env.sh'
row allow 'cd env && ls'
row allow 'docker run --env MARKER_NAME=marker-value image'
row allow 'export MARKER_NAME=marker-value'
row allow 'git status'

# --- Payloads with nothing to inspect, and a failing scanner --------------
row allow ''
row allow '{"tool_name":"Bash","tool_input":{}}' raw
row allow 'not json' raw
row ask   'env' broken-awk
row ask   'git status' broken-awk

echo
echo "$pass passed, $fail failed"

# Every row in this file must have run: a table that stopped early must not
# read as a pass.
declared=$(grep -cE '^row [a-z]' "${BASH_SOURCE[0]}")
if [ $((pass + fail)) -ne "$declared" ] || [ "$declared" -eq 0 ]; then
    echo "ran $((pass + fail)) rows, file declares $declared" >&2
    exit 1
fi
[ "$fail" -eq 0 ]
