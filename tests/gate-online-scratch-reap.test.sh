#!/usr/bin/env bash
# Case table for the one niwa reap that .niwa/hooks/pre_tool_use/gate-online.sh
# allows: a reap run from a workspace a check declared scratch for itself.
#
# Each row feeds the hook the JSON a PreToolUse event carries on stdin, with
# the cwd Claude Code sends, and compares the whole decision and reason the
# hook prints, so a denied reap is checked for the same message as before.
# Nothing here runs niwa. The hook gets an empty environment and a PATH that
# holds no niwa, and the workspaces below are directories holding the files
# niwa and the hook read, not workspaces niwa made.
#
# The host workspace is a stand-in for this one: a root holding
# .niwa/workspace.toml, an instance holding .niwa/instance.json, and the
# hook copies niwa installs in that instance, at its root and in a repo that
# carries a .niwa/workspace.toml of its own, as dot-niwa does.
#
# Usage: tests/gate-online-scratch-reap.test.sh [path-to-hook]
#
# Exit status: 0 when every row matches, 1 otherwise.
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

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The tools a hook run may use, and nothing else: no niwa, no koto.
tools=$work/tools
mkdir -p "$tools"
for t in bash jq awk cat mktemp rm sleep timeout; do
    p=$(command -v "$t") || continue
    ln -s "$p" "$tools/$t"
done

# installed DIR NAME: copies the hook to DIR/.claude/hooks/pre_tool_use/NAME
# under $work, where niwa installs it, and prints the copy's path.
installed() {
    local dir=$work/$1/.claude/hooks/pre_tool_use
    mkdir -p "$dir"
    cp "$hook" "$dir/$2"
    echo "$dir/$2"
}

# The host workspace and its instance.
host=$work/host
inst=$host/inst
repo=$inst/public/dot-niwa
mkdir -p "$host/.niwa" "$inst/.niwa" "$repo/.niwa"
: > "$host/.niwa/workspace.toml"
: > "$inst/.niwa/instance.json"
: > "$repo/.niwa/workspace.toml"
inst_hook=$(installed host/inst gate-online.sh)
repo_hook=$(installed host/inst/public/dot-niwa gate-online.local.sh)
# A copy with no workspace anywhere above it.
lone_hook=$(installed lone gate-online.sh)

# mkscratch DIR: a workspace at DIR, declared scratch the way a check does,
# by writing its resolved path into .niwa/scratch-check.
mkscratch() {
    mkdir -p "$1/.niwa"
    : > "$1/.niwa/workspace.toml"
    (cd "$1" && pwd -P) > "$1/.niwa/scratch-check"
}

# physical DIR: DIR with its symlinks resolved.
physical() {
    (cd -P "$1" && pwd -P)
}

# run HOOK CWD COMMAND [VAR=VALUE...] -> prints "decision<TAB>reason", the
# decision deny|ask|allow, or error:<detail>. An empty CWD leaves .cwd out of
# the payload. RUN_RELATIVE runs the hook by a relative path from its own
# directory.
RUN_RELATIVE=
run() {
    local run=$1 cwd=$2 command=$3 out status payload
    shift 3
    payload=$(jq -cn --arg c "$command" --arg w "$cwd" \
        '{session_id:"0f4c5a8e-3b1d-4e2a-9c7f-1a2b3c4d5e6f",tool_name:"Bash",
          tool_input:{command:$c}} | if $w != "" then .cwd = $w else . end')
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

tally() {
    local result=$1 label=$2 want=$3 got=$4
    if [ "$result" = ok ]; then
        pass=$((pass + 1))
        printf 'ok    %s\n' "$label"
    else
        fail=$((fail + 1))
        printf 'FAIL  %s\n      want %s\n      got  %s\n' "$label" "$want" "$got"
    fi
}

allowed=$(printf 'allow\t')
denied=$(printf 'deny\tBlocked by gate-online hook: niwa reap')

# reap allow|deny CWD COMMAND [HOOK [VAR=VALUE...]]: the whole decision and
# reason must be allowed (nothing printed) or the reap deny, word for word.
reap() {
    local expected=$1 cwd=$2 command=$3 run=${4:-$inst_hook} want got
    shift 3
    [ $# -gt 0 ] && shift
    if [ "$expected" = allow ]; then want=$allowed; else want=$denied; fi
    got=$(run "$run" "$cwd" "$command" "$@")
    tally "$([ "$got" = "$want" ] && echo ok || echo FAIL)" \
        "$(printf '%-5s %q in %s by %s%s' "$expected" "$command" "${cwd#"$work"/}" \
            "${RUN_RELATIVE:+./}" "${run#"$work"/}")" \
        "$(printf '%q' "$want")" "$(printf '%q' "$got")"
}

# unchanged CWD COMMAND: the verdict in CWD is the one the command gets with
# no cwd at all, so the scratch workspace changes nothing for it.
unchanged() {
    local cwd=$1 command=$2 want got
    want=$(run "$inst_hook" "" "$command")
    got=$(run "$inst_hook" "$cwd" "$command")
    tally "$([ "$got" = "$want" ] && echo ok || echo FAIL)" \
        "$(printf 'same  %q in %s' "$command" "${cwd#"$work"/}")" \
        "$(printf '%q' "$want")" "$(printf '%q' "$got")"
}

# asks CWD COMMAND: the decision is ask, whatever the reason.
asks() {
    local cwd=$1 command=$2 got
    got=$(run "$inst_hook" "$cwd" "$command")
    tally "$([ "${got%%	*}" = ask ] && echo ok || echo FAIL)" \
        "$(printf 'ask   %q in %s' "$command" "${cwd#"$work"/}")" ask "$(printf '%q' "$got")"
}

# Rows run in order and some write state (a declaration, a workspace.toml)
# that later rows read, so a row repeated further down checks a different
# rule than its first run did.

# --- Today's reap deny, with no cwd and in the host ---------------------
reap deny  ''         'niwa reap'
reap deny  "$host"    'niwa reap'
reap deny  "$inst"    'niwa reap'
reap deny  "$inst"    'niwa reap --help'
reap deny  "$repo"    'niwa reap'

# --- The scratch workspace a check declares -----------------------------
ws=$work/scratch/ws
mkscratch "$ws"
mkdir -p "$ws/sub/deeper"
ln -s "$ws" "$work/scratch/ws-link"

reap allow "$ws"                 'niwa reap'
reap allow "$ws"                 'niwa reap --help'
reap allow "$ws"                 'niwa reap -h'
reap allow "$ws"                 'niwa --no-progress reap'
reap allow "$ws"                 'niwa reap --no-progress'
reap allow "$ws"                 'niwa  reap'
reap allow "$work/scratch/ws-link" 'niwa reap'
reap allow "$(physical "$ws")"   'niwa reap'
reap allow "$ws"                 'niwa reap' "$repo_hook"
# Only from the root itself: below it, the shell may know the directory by
# another name whose walk up niwa would take somewhere else.
reap deny  "$ws/sub/deeper"      'niwa reap'
reap deny  "$ws/sub"             'niwa reap'
# An instance the check created in its scratch workspace is below the root
# too: the check reaps from the root.
mkdir -p "$ws/scratch-1/.niwa"
: > "$ws/scratch-1/.niwa/instance.json"
reap deny  "$ws/scratch-1"       'niwa reap'
reap allow "$ws"                 'niwa reap'

# Other rules keep their verdicts in the scratch workspace.
unchanged "$ws" 'curl https://example.com'
unchanged "$ws" 'gh pr merge 12'
unchanged "$ws" 'git push --force'
unchanged "$ws" 'niwa list'
unchanged "$ws" 'niwa destroy my-instance'

# --- A reap only as a command of its own --------------------------------
for c in \
    'cd /tmp && niwa reap' \
    'niwa reap; ls' \
    'niwa reap && ls' \
    'ls || niwa reap' \
    'VAR=1 niwa reap' \
    'env niwa reap' \
    'command niwa reap' \
    'exec niwa reap' \
    'sudo niwa reap' \
    'timeout 5 niwa reap' \
    'nohup niwa reap' \
    '/usr/local/bin/niwa reap' \
    './niwa reap' \
    'niwa reap > out' \
    'niwa reap 2>&1' \
    'niwa reap | cat' \
    'niwa reap $(echo)' \
    'niwa reap `echo`' \
    'niwa reap &' \
    "niwa 'reap'" \
    'niwa "reap"' \
    'niwa re\ap' \
    'niwa reap -C /x' \
    'niwa reap --yes' \
    'niwa -v reap' \
    'niwa reap --dry-run' \
    'niwa -Cfoo reap' \
    'niwa -C -x reap' \
    'niwa --help reap' \
    'niwa reap extra' \
    'niwa reap --no-progress=false' \
    'niwa reap --x=/y' \
    $'niwa reap\nniwa reap' \
    $'niwa\treap' \
    ' niwa reap' \
    'niwa reap ' \
    '(niwa reap)' \
    '{ niwa reap; }'
do
    reap deny "$ws" "$c"
done
unchanged "$ws" 'bash -c "niwa reap"'
# Text handed to a shell asks when a reap appears in it, after flags too.
asks "$ws" 'bash -c "niwa reap"'
asks "$ws" 'sh -c "niwa -C .. reap"'
asks ""    'bash -c "niwa --no-progress reap"'
asks ""    'eval "niwa -C /x reap"'

# --- A reap the line doesn't spell out ---------------------------------
# niwa's own flags take no value, but where the subcommand sits after one
# that might can't be told from the line, and a word the shell expands up to
# the subcommand may become reap, so these are denied everywhere.
for c in \
    'niwa -C .. reap' \
    'niwa -C ../x reap' \
    'niwa -C x/.. reap' \
    'niwa -C . reap' \
    'niwa --no-progress -C .. reap' \
    'niwa --dir .. reap' \
    'niwa -C '"$host"' reap' \
    'niwa -C '"$inst"' reap --yes' \
    'niwa destroy reap' \
    'niwa {reap,--no-progress}' \
    'niwa re{a,}p' \
    'niwa rea?' \
    'niwa rea[p]' \
    'niwa @(reap)' \
    'niwa +(reap)' \
    'niwa (reap)' \
    'niwa --no-progress (reap)' \
    'niwa *' \
    'x=reap; niwa $x' \
    'niwa "$x"' \
    'niwa --no-progress $x' \
    'niwa ${x:-reap}' \
    'niwa $(echo reap)' \
    'niwa `echo reap`'
do
    reap deny "$ws" "$c"
    reap deny "$inst" "$c"
    reap deny "" "$c"
done
unchanged "$ws" 'sh -c "niwa reap"'
# An expanded word after the subcommand is only an argument to it.
reap allow ""    'niwa dispatch "$task" --name x'
reap allow "$ws" 'niwa dispatch "$(cat brief.md)" --name x'
reap allow ""    'niwa destroy $name'
reap allow ""    'niwa --no-progress list *'

# --- The cwd must be absolute and clean ---------------------------------
reap deny  "scratch/ws"          'niwa reap'
reap deny  "$ws/"                'niwa reap'
reap deny  "$ws/sub/.."          'niwa reap'
reap deny  "$ws/./sub"           'niwa reap'
reap deny  "$work/scratch//ws"   'niwa reap'
reap deny  "$ws/missing"         'niwa reap'
# A cwd that is the scratch path plus a trailing newline is another
# directory, here a symlink into the host; command substitution would strip
# the newline and check the scratch instead.
ln -s "$inst" "$ws"$'\n'
reap deny  "$ws"$'\n'            'niwa reap'
reap deny  "$ws"$'\n\n'          'niwa reap'
# A cwd that resolves to a directory whose name ends in a newline, next to a
# declared workspace with the same name without it.
mkdir -p "$work/scratch/nl"$'\n'/.niwa
: > "$work/scratch/nl"$'\n'/.niwa/workspace.toml
mkscratch "$work/scratch/nl"
ln -s "$work/scratch/nl"$'\n' "$work/scratch/to-nl"
reap deny  "$work/scratch/to-nl"  'niwa reap'
reap allow "$work/scratch/nl"     'niwa reap'

# --- Declarations that don't count --------------------------------------
# A copy of another workspace's declaration names that workspace's path.
mkdir -p "$work/scratch/copied/.niwa"
: > "$work/scratch/copied/.niwa/workspace.toml"
cp "$ws/.niwa/scratch-check" "$work/scratch/copied/.niwa/scratch-check"
reap deny  "$work/scratch/copied" 'niwa reap'

# A declaration that is a symlink, even to a file naming the right path.
d=$work/scratch/linked-file
mkdir -p "$d/.niwa"
: > "$d/.niwa/workspace.toml"
physical "$d" > "$work/scratch/linked-file-target"
ln -s "$work/scratch/linked-file-target" "$d/.niwa/scratch-check"
reap deny  "$d" 'niwa reap'

# A .niwa that is a symlink to a directory holding a right declaration.
d=$work/scratch/linked-dir
mkdir -p "$d" "$work/scratch/linked-dir-target"
: > "$work/scratch/linked-dir-target/workspace.toml"
physical "$d" > "$work/scratch/linked-dir-target/scratch-check"
ln -s "$work/scratch/linked-dir-target" "$d/.niwa"
reap deny  "$d" 'niwa reap'

# A workspace.toml that is a symlink to the host's, so niwa would run the
# host's reap commands, with a right declaration beside it.
d=$work/scratch/linked-config
mkdir -p "$d/.niwa"
ln -s "$host/.niwa/workspace.toml" "$d/.niwa/workspace.toml"
physical "$d" > "$d/.niwa/scratch-check"
reap deny  "$d" 'niwa reap'

# A declaration that is a directory.
d=$work/scratch/dir-decl
mkdir -p "$d/.niwa/scratch-check"
: > "$d/.niwa/workspace.toml"
reap deny  "$d" 'niwa reap'

# No declaration, an empty one, one naming the path with a trailing slash,
# and one whose right path is only on its second line.
d=$work/scratch/undeclared
mkdir -p "$d/.niwa"
: > "$d/.niwa/workspace.toml"
reap deny  "$d" 'niwa reap'
: > "$d/.niwa/scratch-check"
reap deny  "$d" 'niwa reap'
printf '%s/\n' "$(physical "$d")" > "$d/.niwa/scratch-check"
reap deny  "$d" 'niwa reap'
printf 'scratch\n%s\n' "$(physical "$d")" > "$d/.niwa/scratch-check"
reap deny  "$d" 'niwa reap'

# A root niwa would take from .niwa.prev, with a declaration but no
# .niwa/workspace.toml.
d=$work/scratch/prev-only
mkdir -p "$d/.niwa" "$d/.niwa.prev"
: > "$d/.niwa.prev/workspace.toml"
physical "$d" > "$d/.niwa/scratch-check"
reap deny  "$d" 'niwa reap'

# A symlink inside a declared workspace that leads into the host: niwa's
# walk up from the resolved path reaches the host, not the scratch.
ln -s "$inst" "$ws/into-host"
reap deny  "$ws/into-host" 'niwa reap'
ln -s "$inst" "$work/scratch/host-link"
reap deny  "$work/scratch/host-link" 'niwa reap'

# --- The host can't declare itself --------------------------------------
# A declaration written into the host root, its instance, or the repo that
# carries a workspace.toml of its own, each naming its own resolved path.
physical "$host" > "$host/.niwa/scratch-check"
reap deny  "$host" 'niwa reap'
reap deny  "$host" 'niwa reap' "$repo_hook"
physical "$repo" > "$repo/.niwa/scratch-check"
reap deny  "$repo" 'niwa reap'
reap deny  "$repo" 'niwa reap' "$repo_hook"
: > "$inst/.niwa/workspace.toml"
physical "$inst" > "$inst/.niwa/scratch-check"
reap deny  "$inst" 'niwa reap'
reap deny  "$inst" 'niwa reap' "$repo_hook"
reap deny  "$ws/into-host" 'niwa reap'

# The host spelled in another case, with declarations that spell it the same
# way. On a case-insensitive filesystem (macOS) the paths name the host and
# a resolved path keeps the case it was typed in; elsewhere they name nothing.
host_uc=$(printf '%s' "$host" | tr '[:lower:]' '[:upper:]')
inst_uc=$host_uc/INST
if p=$(physical "$host_uc" 2>/dev/null); then
    printf '%s\n' "$p" > "$host/.niwa/scratch-check"
fi
if p=$(physical "$inst_uc" 2>/dev/null); then
    printf '%s\n' "$p" > "$inst/.niwa/scratch-check"
fi
reap deny  "$host_uc" 'niwa reap'
reap deny  "$inst_uc" 'niwa reap'
reap deny  "$inst_uc" 'niwa reap' "$repo_hook"

# A scratch workspace made inside the host, or inside the instance.
mkscratch "$host/tmp/ws"
reap deny  "$host/tmp/ws" 'niwa reap'
mkscratch "$inst/tmp/ws"
reap deny  "$inst/tmp/ws" 'niwa reap'
reap deny  "$inst/tmp/ws" 'niwa reap' "$repo_hook"

# A declared workspace that holds a workspace with the hook installed in it.
outer=$work/outer
mkscratch "$outer"
mkdir -p "$outer/inner/.niwa"
: > "$outer/inner/.niwa/workspace.toml"
outer_hook=$(installed outer/inner gate-online.sh)
reap deny  "$outer" 'niwa reap' "$outer_hook"
reap deny  "$outer/inner" 'niwa reap' "$outer_hook"

# An environment that names the scratch workspace changes nothing.
reap deny  "$inst" 'niwa reap' "$inst_hook" PWD="$ws" HOME="$ws" \
    CLAUDE_PROJECT_DIR="$ws" NIWA_WORKSPACE="$ws" OLDPWD="$ws"
reap allow "$ws"   'niwa reap' "$inst_hook" PWD="$inst" HOME="$host" \
    CLAUDE_PROJECT_DIR="$inst"

# --- A hook that can't tell where its own workspace is ------------------
reap deny  "$ws" 'niwa reap' "$lone_hook"
RUN_RELATIVE=1
reap deny  "$ws" 'niwa reap'
reap deny  "$ws" 'niwa reap' "$repo_hook"
RUN_RELATIVE=
# A symlink to the host's hook, from outside the host or from inside the
# scratch, finds its workspace from where the link is, so it allows nothing.
ln -s "$inst_hook" "$work/linked-hook.sh"
reap deny  "$ws" 'niwa reap' "$work/linked-hook.sh"
mkdir -p "$ws/.claude/hooks"
ln -s "$inst_hook" "$ws/.claude/hooks/gate-online.sh"
reap deny  "$ws" 'niwa reap' "$ws/.claude/hooks/gate-online.sh"
# A symlinked directory leading to the host's hook resolves to the host.
ln -s "${inst_hook%/*}" "$work/linked-hook-dir"
reap allow "$ws" 'niwa reap' "$work/linked-hook-dir/gate-online.sh"
reap deny  "$inst" 'niwa reap' "$work/linked-hook-dir/gate-online.sh"
# An instance whose .claude is a symlink into another workspace: the hook's
# path as written still finds the host, so the host stays protected.
mkdir -p "$host/inst2/.niwa" "$work/elsewhere/.niwa"
: > "$host/inst2/.niwa/instance.json"
: > "$work/elsewhere/.niwa/workspace.toml"
installed elsewhere gate-online.sh > /dev/null
ln -s "$work/elsewhere/.claude" "$host/inst2/.claude"
physical "$host" > "$host/.niwa/scratch-check"
reap deny  "$host" 'niwa reap' "$host/inst2/.claude/hooks/pre_tool_use/gate-online.sh"
reap allow "$ws"   'niwa reap' "$host/inst2/.claude/hooks/pre_tool_use/gate-online.sh"

echo
echo "$pass passed, $fail failed"

# Every row must have run: each row outside a loop once, and each loop's
# rows once per command it lists (the first loop runs one row per command,
# the second three).
declared=$(grep -cE '^(reap|unchanged|asks) ' "${BASH_SOURCE[0]}")
read -r first second < <(awk '/^for c in/ { n++; on = 1; next } /^do$/ { on = 0 }
    on && /^    [\047$"]/ { c[n]++ } END { print c[1] + 0, c[2] + 0 }' "${BASH_SOURCE[0]}")
expected=$((declared + first + 3 * second))
if [ $((pass + fail)) -ne "$expected" ] || [ "$declared" -eq 0 ]; then
    echo "ran $((pass + fail)) rows, file declares $expected" \
        "($declared single rows, $first commands in the first loop, $second in the second)" >&2
    exit 1
fi
[ "$fail" -eq 0 ]
