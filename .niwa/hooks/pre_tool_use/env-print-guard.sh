#!/bin/bash
# Refuses a Bash command that would print the whole environment.
# Runs as a PreToolUse hook on Bash commands, beside gate-online.sh. Sessions
# carry tokens and API keys in their environment, and a bare env, printenv or
# set writes every one of them into the transcript, so the command is refused
# before it runs.
#
# Exit behavior:
#   exit 0 with no output     → allow (default)
#   exit 0 with JSON decision → deny, or ask when awk can't inspect the command
#
# Requires: jq, awk.
#
# Refused, as any simple command in the line (after | ; & && || or a newline,
# inside ( ), $( ), backticks, or $( ) inside double quotes):
#   - env that runs no command: env alone, or with only options and VAR=value
#     words (env -u VAR, env FOO=1), since it then prints the environment.
#     env -i (or -, --ignore-environment) empties it first and passes, as do
#     --help and --version.
#   - printenv with no name: printenv, printenv -0. --help and --version pass.
#   - set with no arguments at all.
#
# Allowed:
#   - env or printenv piped straight into cut -d= -f1 (the flags in either
#     order, -d= or -d =, -f1 or -f 1, and no file operand), which prints
#     names only. A value holding a newline still prints its later lines
#     through that pipe; the form is allowed anyway, as issue 55 asks.
#   - env with a command to run (env VAR=value cmd, env -u VAR cmd).
#   - printenv NAME.
#   - set with any option or argument (set -e, set -euo pipefail, set -x,
#     set -- a b).
#
# The refusal names the form and the allowed forms, never text from the
# command, so it carries no variable name or value.
#
# How commands are found
#
# The command line is read, never run, by the same scanner gate-online.sh
# uses: text inside quotes, heredoc bodies and comments is data, so a commit
# message that mentions env is not an env command. niwa installs each hook
# script on its own (<instance>/.claude/hooks/pre_tool_use/<name>, and
# <name>.local.sh in every repo) and runs it by path, so a hook can't source a
# shared file. The scanner below is a copy of gate-online.sh's, less the
# unclosed-quote and heredoc-substitution tracking only gate-online's rules
# read, and with one addition: it records which simple command a single |
# feeds, so env | cut -d= -f1 is told apart from env || x. A fix to one copy
# belongs in the other.
#
# Each simple command loses its leading VAR=value words, shell keywords (if,
# then, do, !, {, time) and wrappers (command, builtin, exec, nohup, setsid,
# stdbuf, sudo, nice, timeout, and env when it runs a command), and the word
# left is the command. This is text inspection, not a shell parser: it does
# not expand variables, follow aliases or functions, or look inside text
# handed to another shell (bash -c, eval).
#
# Tests: tests/env-print-guard.test.sh at the repository root.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$COMMAND" ] && exit 0

emit() {
    jq -cn --arg d "$1" --arg r "$2" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
}

VERDICT=$(printf '%s' "$COMMAND" | LC_ALL=C awk '
BEGIN { RS = "\001" }
{ src = (NR == 1) ? $0 : src "\001" $0 }

# ---------------------------------------------------------------- scanning
# A copy of gate-online.sh: keep the two in step.

function addword() {
    if (!wany) return
    if (redir_next) {
        redir_next = 0
    } else if (herestr_next) {
        body[seg] = body[seg] "\n" word
        herestr_next = 0
    } else {
        segn[seg]++
        segw[seg, segn[seg]] = word
        segd[seg, segn[seg]] = wdyn
    }
    word = ""; wany = 0; wdyn = 0
}

# A word made only of digits right before < or > is a file descriptor.
function addword_fd() {
    if (wany && word ~ /^[0-9]+$/) { word = ""; wany = 0; wdyn = 0; return }
    addword()
}

function newseg() {
    addword()
    seg = ++nseg
    segn[seg] = 0
}

function push(type) {
    fsp++
    ftype[fsp] = type; fmode[fsp] = mode; fseg[fsp] = seg
    fword[fsp] = word; fwany[fsp] = wany; fwdyn[fsp] = wdyn; fdepth[fsp] = 0
    word = ""; wany = 0; wdyn = 0
    mode = "c"
    seg = ++nseg
    segn[seg] = 0
}

function pop() {
    addword()
    seg = fseg[fsp]; mode = fmode[fsp]
    word = fword[fsp] "$(...)"; wany = 1; wdyn = 1
    fsp--
}

# Called with i on a newline in code: read the bodies of pending heredocs.
function heredocs(   k, pos, rest, e, line, cmp, text) {
    pos = i + 1
    for (k = 1; k <= nph; k++) {
        text = ""
        while (pos <= n) {
            rest = substr(src, pos)
            e = index(rest, "\n")
            line = e ? substr(rest, 1, e - 1) : rest
            pos = e ? pos + e : n + 1
            cmp = line
            if (phstrip[k]) sub(/^\t+/, "", cmp)
            if (cmp == phdelim[k]) break
            text = text line "\n"
        }
        body[phseg[k]] = body[phseg[k]] "\n" text
    }
    nph = 0
    i = pos
}

# Called with i just past << or <<-: read the delimiter word.
function heredoc_start(   strip, delim, quoted, ch, q, j) {
    strip = 0; delim = ""; quoted = 0
    if (substr(src, i, 1) == "-") { strip = 1; i++ }
    while (substr(src, i, 1) == " " || substr(src, i, 1) == "\t") i++
    while (i <= n) {
        ch = substr(src, i, 1)
        if (ch ~ /[ \t\n;&|()<>]/) break
        if (ch == "\047" || ch == "\"") {
            quoted = 1
            q = substr(src, i + 1)
            j = index(q, ch)
            if (!j) { delim = delim q; i = n + 1; break }
            delim = delim substr(q, 1, j - 1)
            i += j + 1
        } else if (ch == "\\") {
            quoted = 1
            delim = delim substr(src, i + 1, 1)
            i += 2
        } else {
            delim = delim ch
            i++
        }
    }
    nph++
    phdelim[nph] = delim; phstrip[nph] = strip; phquoted[nph] = quoted; phseg[nph] = seg
}

# Called with i on "$" in code or in double quotes.
function dollar(   nx, rest, j) {
    nx = substr(src, i + 1, 1)
    if (nx == "(") {
        push("paren"); i += 2
    } else if (nx == "{") {
        rest = substr(src, i)
        j = index(rest, "}")
        if (!j) j = length(rest)
        word = word substr(rest, 1, j); wany = 1; wdyn = 1
        i += j
    } else {
        word = word "$"; wany = 1; wdyn = 1
        i++
    }
}

function scan(   c, nx, rest, j, k, from) {
    n = length(src)
    mode = "c"; fsp = 0; nph = 0; nseg = 0
    seg = ++nseg; segn[seg] = 0
    word = ""; wany = 0; wdyn = 0
    i = 1
    while (i <= n) {
        c = substr(src, i, 1)
        if (mode == "d") {
            if (c == "\"") { mode = "c"; i++ }
            else if (c == "\\") {
                nx = substr(src, i + 1, 1)
                if (nx == "\n") i += 2
                else if (nx ~ /[$`"\\]/) { word = word nx; i += 2 }
                else { word = word c; i++ }
            }
            else if (c == "`") { push("tick"); i++ }
            else if (c == "$") dollar()
            else { word = word c; i++ }
            continue
        }
        # code
        if (c == "\\") {
            nx = substr(src, i + 1, 1)
            if (nx != "\n") { word = word nx; wany = 1 }
            i += 2
        } else if (c == "\047") {
            rest = substr(src, i + 1)
            j = index(rest, "\047")
            if (!j) { word = word rest; wany = 1; i = n + 1 }
            else { word = word substr(rest, 1, j - 1); wany = 1; i += j + 1 }
        } else if (c == "\"") {
            mode = "d"; wany = 1; i++
        } else if (c == "$" && substr(src, i + 1, 1) == "\047") {
            # $'...' : backslash escapes, ends at an unescaped quote
            k = i + 2
            while (k <= n && substr(src, k, 1) != "\047") k += (substr(src, k, 1) == "\\") ? 2 : 1
            word = word substr(src, i + 2, k - i - 2); wany = 1
            i = k + 1
        } else if (c == "$") {
            dollar()
        } else if (c == "`") {
            if (fsp > 0 && ftype[fsp] == "tick") pop()
            else push("tick")
            i++
        } else if (c == "#" && !wany) {
            rest = substr(src, i)
            j = index(rest, "\n")
            i = j ? i + j - 1 : n + 1
        } else if (c == " " || c == "\t") {
            addword(); i++
        } else if (c == "\n") {
            newseg()
            if (nph > 0) heredocs(); else i++
        } else if (c == ";" || c == "|") {
            # The one addition to the copy: a single | (not || or |&)
            # records the simple command it feeds.
            if (c == "|" && substr(src, i + 1, 1) !~ /[|&]/ && substr(src, i - 1, 1) != "|") {
                from = seg; newseg(); pipeto[from] = seg
            } else newseg()
            i++
        } else if (c == "&") {
            if (substr(src, i + 1, 1) == ">") {
                addword(); i += 2
                if (substr(src, i, 1) == ">") i++
                redir_next = 1
            } else { newseg(); i++ }
        } else if (c == "(") {
            newseg()
            if (fsp > 0 && ftype[fsp] == "paren") fdepth[fsp]++
            i++
        } else if (c == ")") {
            if (fsp > 0 && ftype[fsp] == "paren") {
                if (fdepth[fsp] > 0) { fdepth[fsp]--; newseg() }
                else pop()
            } else newseg()
            i++
        } else if (c == "<" || c == ">") {
            nx = substr(src, i + 1, 1)
            if (nx == "(") {
                addword(); push("paren"); i += 2
            } else if (c == "<" && substr(src, i, 3) == "<<<") {
                addword_fd(); herestr_next = 1; i += 3
            } else if (c == "<" && nx == "<") {
                addword_fd(); i += 2; heredoc_start()
            } else {
                addword_fd(); i++
                while (substr(src, i, 1) ~ /[<>&|]/) i++
                redir_next = 1
            }
        } else {
            word = word c; wany = 1; i++
        }
    }
    addword()
}

# ---------------------------------------------------------------- rules

# What simple command s prints the environment as, or "" when it does not:
# "env" (env that runs no command), "printenv" (printenv with no name) or
# "set" (set with no arguments).
function prints(s,   m, k, x, h, empty) {
    m = segn[s]
    k = 1
    while (k <= m) {
        x = segw[s, k]
        if (x ~ /^(!|\{|\}|if|then|else|elif|fi|do|done|while|until|coproc)$/) { k++; continue }
        if (x == "time") {
            for (k++; k <= m && segw[s, k] ~ /^-/; k++) ;
            continue
        }
        if (x ~ /^(for|select|case|\[\[|\[|test)$/) return ""
        if (x == "function") { k += 2; continue }
        if (x ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) { k++; continue }
        h = x; sub(/.*\//, "", h)
        if (h ~ /^(command|builtin|exec|nohup|setsid|stdbuf)$/) {
            for (k++; k <= m && segw[s, k] ~ /^-/; k++) {
                # command -v and -V name the command instead of running it.
                if (h == "command" && segw[s, k] ~ /^-[pvV]*[vV]/) return ""
                if (segw[s, k] == "-a") k++
            }
            continue
        }
        if (h == "sudo") {
            for (k++; k <= m && segw[s, k] ~ /^-/; k++) if (segw[s, k] ~ /^-[ugCDhprtUT]$/) k++
            continue
        }
        if (h == "nice") {
            for (k++; k <= m && segw[s, k] ~ /^-/; k++) if (segw[s, k] == "-n") k++
            continue
        }
        if (h == "timeout") {
            for (k++; k <= m && segw[s, k] ~ /^-/; k++) if (segw[s, k] ~ /^(-s|-k)$/) k++
            k++
            continue
        }
        if (h == "env") {
            # Past the options and VAR=value words: a word left is the
            # command env runs; none left means env prints the environment.
            empty = 0
            for (k++; k <= m; k++) {
                x = segw[s, k]
                if (x ~ /^(--help|--version)$/) return ""
                if (x ~ /^(-S|--split-string)/) return ""
                if (x == "-" || x == "--ignore-environment" || x ~ /^-[0iv]*i[0iv]*$/) empty = 1
                else if (x ~ /^(-u|-C|--unset|--chdir)$/) k++
                else if (x !~ /^-/ && x !~ /^[A-Za-z_][A-Za-z0-9_]*=/) break
            }
            if (k > m) return empty ? "" : "env"
            continue
        }
        break
    }
    if (k > m) return ""
    h = segw[s, k]; sub(/.*\//, "", h)
    if (h == "printenv") {
        for (k++; k <= m; k++) {
            x = segw[s, k]
            if (x ~ /^(--help|--version)$/ || x !~ /^-/) return ""
        }
        return "printenv"
    }
    if (h == "set" && k == m) return "set"
    return ""
}

# Whether simple command t is exactly cut -d= -f1 in one of its spellings.
function names_only(t,   m, k, x, d, f) {
    m = segn[t]
    if (m < 1) return 0
    x = segw[t, 1]; sub(/.*\//, "", x)
    if (x != "cut") return 0
    d = 0; f = 0
    for (k = 2; k <= m; k++) {
        x = segw[t, k]
        if (x == "-d=") d = 1
        else if (x == "-d" && k < m && segw[t, k + 1] == "=") { d = 1; k++ }
        else if (x == "-f1") f = 1
        else if (x == "-f" && k < m && segw[t, k + 1] == "1") { f = 1; k++ }
        else return 0
    }
    return d && f
}

END {
    scan()
    found = ""
    for (s = 1; s <= nseg && found == ""; s++) {
        form = prints(s)
        if (form == "") continue
        if (form != "set" && (s in pipeto) && names_only(pipeto[s])) continue
        found = form
    }
    print (found == "" ? "allow" : "deny\t" found)
}
')
STATUS=$?

if [ "$STATUS" -ne 0 ] || [ -z "$VERDICT" ]; then
    emit ask "env-print-guard hook could not inspect the command"
    exit 0
fi

case "$VERDICT" in
    allow) exit 0 ;;
esac

case "${VERDICT#*	}" in
    env) WHAT="env with no command to run" ;;
    printenv) WHAT="printenv with no variable name" ;;
    *) WHAT="set with no arguments" ;;
esac

emit deny "Blocked by env-print-guard hook: $WHAT prints every environment variable, secrets included, into the transcript. Allowed instead: env | cut -d= -f1 to list names only, printenv NAME for one variable, env VAR=value cmd or env -u VAR cmd to run a command with a changed environment, and set with options or arguments (set -e, set -euo pipefail, set -x, set -- a b)."
exit 0
