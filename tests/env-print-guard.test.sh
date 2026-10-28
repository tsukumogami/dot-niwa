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
    case "$why" in *'secrets included'*|*'lists every variable name'*) ;; *) return 1 ;; esac
    for form in 'env | cut -d= -f1' 'printenv NAME' \
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

# --- Text handed to another shell -----------------------------------------
row deny  'bash -c env'
row deny  "bash -c 'env'"
row deny  'sh -c "printenv"'
row deny  "bash -lc 'set'"
row deny  "bash -e -c 'env | sort'"
row deny  "bash -o pipefail -c 'env | sort'"
row deny  "bash -eo pipefail -c 'true; printenv'"
row deny  "bash --norc -c 'env'"
row deny  "bash -c -- 'env'"
row deny  "zsh -c 'env'"
row deny  "/bin/sh -c 'true && env'"
row deny  "dash -c 'echo \$(env)'"
row deny  "ksh -c 'printenv'"
row deny  "sudo sh -c 'env'"
row deny  "timeout 5 bash -c 'env'"
row deny  "bash -c \"bash -c 'env'\""
row deny  "bash -c 'export -p'"
row deny  'eval env'
row deny  "eval 'printenv'"
row deny  'eval "set"'
row deny  'eval -- env'
row deny  "eval 'echo \$(env)'"
row deny  'eval eval env'
row deny  "eval 'declare -p'"
row deny  $'bash <<\'EOF\'\nenv\nEOF'
row deny  $'sh <<EOF\nprintenv | sort\nEOF'
row deny  $'bash -s <<\'EOF\'\nset\nEOF'
row deny  "bash <<< 'env'"
row deny  'env -S env'
row deny  "env -S 'printenv'"
row deny  'env -Senv'
row deny  "env --split-string='env -u MARKER_NAME'"

# --- Substitutions in an unquoted heredoc body ----------------------------
row deny  $'cat <<EOF\n$(env)\nEOF'
row deny  $'cat <<EOF\n`printenv`\nEOF'
row deny  $'cat <<-EOF\n\tsee $(set)\n\tEOF'
row deny  $'cat <<EOF\n"$(env)"\nEOF'
row deny  $'cat <<EOF\n\'$(env)\'\nEOF'
row deny  $'cat <<EOF\n\\"$(env)\\"\nEOF'
row deny  $'git commit -F - <<EOF\nrun `env` to see them\nEOF'
row deny  $'x=$(cat <<EOF\nnames: $(env | sort)\nEOF\n)'
row deny  $'gh pr create --body "$(cat <<EOF\nuse `export -p`\nEOF\n)"'
row deny  $'cat <<EOF > out.txt\nok\n$(declare -x)\nEOF'
row deny  'cat <<< "$(env)"'
row deny  'cat <<< `printenv`'
row deny  'echo hi > "$(env)"'
row deny  'echo hi 2>$(printenv)'
row allow 'echo hi > "$(date).log"'

# --- Commands run by xargs and find ---------------------------------------
row deny  'xargs env'
row deny  'echo | xargs env'
row deny  'xargs -0 env'
row deny  'xargs -n 1 env'
row deny  'xargs -I {} env'
row deny  'xargs env -u MARKER_NAME'
row deny  'xargs printenv'
row deny  "xargs sh -c 'env'"
row deny  'find . -maxdepth 0 -exec env \;'
row deny  "find . -exec env ';'"
row deny  'find . -execdir printenv \;'
row deny  'find . -ok env \;'
row deny  'find . -okdir env \;'
row deny  'find . -name x -exec env -u MARKER_NAME \;'
row deny  'find . -exec true \; -exec env \;'
row deny  "find . -exec sh -c 'env' \\;"
row deny  'find . -exec /usr/bin/env +'

# --- Builtins that print variables ----------------------------------------
row deny  'export'
row deny  'export -p'
row deny  'export -fp'
row deny  'export -p MARKER_NAME'
row deny  'declare'
row deny  'declare -p'
row deny  'declare -x'
row deny  'declare -px'
row deny  'declare -r'
row deny  'declare --'
row deny  'typeset'
row deny  'typeset -p'
row deny  'typeset -x'
row deny  'compgen -e'
row deny  'compgen -v'
row deny  'compgen -ev'
row deny  'compgen -ce'
row deny  'compgen -A export'
row deny  'compgen -A variable'
row deny  'compgen -Avariable'
row deny  'compgen -e MARKER'
row deny  'compgen -W "a b" -v'
row deny  'builtin declare -p'
row deny  'command export -p'
row deny  'declare -p | grep MARKER_NAME'
row deny  'export -p | cut -d= -f1'
row deny  'true && declare -x'
row deny  'echo $(compgen -v)'

# --- Ordinary commands near the new forms ---------------------------------
row allow "bash -c 'echo env'"
row allow "bash -c 'env | cut -d= -f1'"
row allow "bash -c 'printenv HOME'"
row allow "bash -c 'set -e; make test'"
row allow "sh -c 'git status'"
row allow "bash -c 'echo \"\$1\"' _ env"
row allow "bash -c 'echo \"\\\$(env)\"'"
row allow 'bash script.sh'
row allow 'bash -n env.sh'
row allow 'bash tests/env-print-guard.test.sh'
row allow 'bash'
row allow $'bash <<\'EOF\'\necho env\nEOF'
row allow $'bash script.sh <<EOF\nenv\nEOF'
row allow 'grep -rn "bash -c env" .'
row allow 'eval "$(ssh-agent -s)"'
row allow 'eval set -- a b'
row allow "eval 'export MARKER_NAME=marker-value'"
row allow $'cat <<EOF\nenv\nprintenv\nset\nexport -p\nEOF'
row allow $'cat <<EOF\n$(date) env\nEOF'
row allow $'cat <<EOF\n$(env | cut -d= -f1)\nEOF'
row allow $'cat <<\'EOF\'\n$(env)\nEOF'
row allow $'cat <<"EOF"\n`env`\nEOF'
row allow $'cat <<\\EOF\n$(env)\nEOF'
row allow $'cat <<EOF\n\\$(env) and \\`env\\`\nEOF'
row allow $'git commit -F - <<\'EOF\'\nfix: refuse `env` in heredocs\nEOF'
row allow $'cat <<EOF\n${MARKER_NAME:-env}\nEOF'
row allow 'cat <<< "env"'
row allow 'xargs echo env'
row allow 'xargs env make'
row allow 'xargs -I {} env {}'
row allow 'xargs printenv HOME'
row allow 'xargs grep -l printenv'
row allow 'find . -name env'
row allow 'find env -type f'
row allow "find . -name '*.env' -delete"
row allow 'find . -exec grep -l env {} \;'
row allow 'find . -exec env {} \;'
row allow 'find . -exec env -u MARKER_NAME ls {} +'
row allow 'export MARKER_NAME'
row allow 'export -n MARKER_NAME'
row allow 'export -f myfunc'
row allow 'export -- MARKER_NAME=marker-value'
row allow 'declare -p MARKER_NAME'
row allow 'declare -x MARKER_NAME=marker-value'
row allow 'declare -a list'
row allow 'declare -F'
row allow 'declare -f'
row allow 'typeset -p MARKER_NAME'
row allow 'compgen -c'
row allow 'compgen -f src/'
row allow 'compgen -W "e v" -- e'
row allow 'compgen -A function'
row allow 'compgen -o default -c'
row allow "grep -rn 'export -p' ."
row allow 'echo declare -p compgen -e'
row allow 'git commit -m "refuse export -p, declare -x and compgen -e"'
row allow 'cat /etc/environment'
row allow 'ls ~/.config/exports'

# --- Known gaps, listed in the hook's header: these pass ------------------
row allow 'bash -c "$MARKER_NAME"'
row allow 'eval "$MARKER_NAME"'
row allow "\$SHELL -c 'env'"
row allow "printf 'env\\n' | bash"
row allow 'source ./print-all.sh'
row allow "watch -n 5 env"

# --- More text to hand on than the hook reads -----------------------------
row ask   "$(printf 'eval %.0s' {1..70})true"
row deny  "$(printf 'eval %.0s' {1..60})env"

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
