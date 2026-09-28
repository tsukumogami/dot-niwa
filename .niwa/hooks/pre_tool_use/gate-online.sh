#!/bin/bash
# Gate script for online operations.
# Runs as a PreToolUse hook on Bash commands. Works in bypassPermissions mode
# because hooks are external to the permission system.
#
# Exit behavior:
#   exit 0 with no output    → allow (default)
#   exit 0 with JSON decision → deny or ask per decision
#   exit 2                    → hard block
#
# Requires: jq, awk
#
# How commands are found
#
# The command line is read, never run. One awk pass walks it and keeps track
# of what is code and what is data: text inside quotes, heredoc bodies and
# comments is data, so a commit message or PR body that mentions a gated
# command is not a gated command. The code is split into simple commands at
# newlines, ; & | ( ) and at $( ) and backticks, including those inside double
# quotes, which bash runs. Each simple command loses its leading VAR=value
# words, shell keywords (if, then, do, !, {) and wrappers (command, env, exec,
# sudo, nohup, time, timeout, nice, xargs, stdbuf, setsid), and its first
# words are compared with the rules below.
#
# This is text inspection, not a shell parser. It does not expand variables,
# follow aliases or functions defined elsewhere, read script files, or see
# what a program does once it runs (a script calling the GitHub API, for
# instance). Where it can tell that it cannot tell, it asks:
#   - text handed to a shell (bash -c, sh -c, eval, a heredoc or here-string
#     fed to a shell) that mentions a gated command;
#   - a command name that is itself an expansion ($GH pr merge);
#   - a quote, $( or backtick that never closes, around text that mentions a
#     gated command.
#
# Rules
#   deny: gh pr merge, gh repo delete, gh api to pulls/<n>/merge or the
#         GraphQL mergePullRequest / enablePullRequestAutoMerge mutations,
#         curl, wget, nc, ncat, netcat, niwa reap
#   ask:  gh auth switch, gh release create, gh issue close, unset GH_TOKEN,
#         git push with --force, --force-with-lease, -f or a +refspec
#
# One instance may merge: tsuku+coordinator_session_owner-f05c1900 runs the
# coordinator that lands pull requests while the owner is away. There the
# three merge denials (gh pr merge, the REST merge endpoint, the GraphQL merge
# mutations) are dropped; every other rule still applies. niwa installs this
# script at <instance>/.claude/hooks/pre_tool_use/gate-online.sh and the
# instance's own settings run it by that absolute path, so $0 names the
# instance the session belongs to. A session elsewhere runs its own copy.
#
# Tests: tests/gate-online.test.sh at the repository root.

MERGE_EXEMPT=0
case "$0" in
    */tsuku+coordinator_session_owner-f05c1900/.claude/hooks/pre_tool_use/gate-online.sh) MERGE_EXEMPT=1 ;;
esac

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$COMMAND" ] && exit 0

emit() {
    jq -cn --arg d "$1" --arg r "$2" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
}

VERDICT=$(printf '%s' "$COMMAND" | LC_ALL=C awk -v merge_exempt="$MERGE_EXEMPT" '
BEGIN { RS = "\001" }
{ src = (NR == 1) ? $0 : src "\001" $0 }

# ---------------------------------------------------------------- scanning

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
        if (!phquoted[k] && text ~ /\$\(|`/) ambiguous = ambiguous "\n" text
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

function scan(   c, nx, rest, j, k) {
    n = length(src)
    mode = "c"; fsp = 0; nph = 0; nseg = 0; unclosed = 0
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
            if (!j) { word = word rest; wany = 1; unclosed = 1; i = n + 1 }
            else { word = word substr(rest, 1, j - 1); wany = 1; i += j + 1 }
        } else if (c == "\"") {
            mode = "d"; wany = 1; i++
        } else if (c == "$" && substr(src, i + 1, 1) == "\047") {
            # $'...' : backslash escapes, ends at an unescaped quote
            k = i + 2
            while (k <= n && substr(src, k, 1) != "\047") k += (substr(src, k, 1) == "\\") ? 2 : 1
            if (k > n) unclosed = 1
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
            newseg(); i++
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
    if (fsp > 0 || mode == "d") unclosed = 1
}

# ---------------------------------------------------------------- rules

function mentions(t) {
    return t ~ /gh[ \t\n]+(pr[ \t\n]+merge|repo[ \t\n]+delete|auth[ \t\n]+switch|release[ \t\n]+create|issue[ \t\n]+close)/ ||
           t ~ /pulls\/[^\/ \t\n]+\/merge|mergePullRequest|enablePullRequestAutoMerge/ ||
           t ~ /niwa[ \t\n]+reap|unset[ \t\n]+GH_TOKEN/ ||
           t ~ /(^|[^A-Za-z0-9_.-])(curl|wget|nc|ncat|netcat)([ \t\n]|$)/ ||
           t ~ /push[ \t]([^\n;&|]*[ \t])?(--force|-[A-Za-z]*f[A-Za-z]*([ \t\n;&|]|$)|\+)/
}

function verdict(d, r) {
    if (rank[d] > rank[best]) { best = d; reason = r }
}

# Rules for command head h whose arguments are segw[s, a..m].
# Sets rd and rr; returns 1 on a match.
function rules(s, h, a, m,   x, k, sub1, sub2, get, t) {
    rd = ""; rr = ""
    if (h ~ /^(curl|wget|nc|ncat|netcat)$/) { rd = "deny"; rr = h; return 1 }
    if (h == "gh") {
        sub1 = segw[s, a]; sub2 = segw[s, a + 1]
        if (sub1 == "pr" && sub2 == "merge")        { rd = "deny"; rr = "gh pr merge" }
        else if (sub1 == "repo" && sub2 == "delete") { rd = "deny"; rr = "gh repo delete" }
        else if (sub1 == "auth" && sub2 == "switch") { rd = "ask";  rr = "gh auth switch" }
        else if (sub1 == "release" && sub2 == "create") { rd = "ask"; rr = "gh release create" }
        else if (sub1 == "issue" && sub2 == "close") { rd = "ask";  rr = "gh issue close" }
        else if (sub1 == "api") {
            get = 0
            for (k = a + 1; k <= m; k++) {
                x = segw[s, k]
                if (x ~ /^(-X|--method)$/ && toupper(segw[s, k + 1]) == "GET") get = 1
                if (x ~ /^(-XGET|--method=GET)$/) get = 1
            }
            for (k = a + 1; k <= m; k++) {
                x = segw[s, k]
                if (x ~ /mergePullRequest|enablePullRequestAutoMerge/) { rd = "deny"; rr = "gh api merge mutation" }
                else if (!get && x ~ /pulls\/[^\/]+\/merge([\/?]|$)/) { rd = "deny"; rr = "gh api pull request merge endpoint" }
            }
        }
        if (merge_exempt && rr ~ /^gh (pr merge|api merge mutation|api pull request merge endpoint)$/) { rd = ""; rr = "" }
        return rd != ""
    }
    if (h == "niwa") {
        for (k = a; k <= m; k++) if (segw[s, k] !~ /^-/) break
        if (k <= m && segw[s, k] == "reap") { rd = "deny"; rr = "niwa reap"; return 1 }
        return 0
    }
    if (h == "git") {
        for (k = a; k <= m; k++) {
            x = segw[s, k]
            if (x ~ /^(-C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env)$/) k++
            else if (x !~ /^-/) break
        }
        if (k > m || segw[s, k] != "push") return 0
        for (k++; k <= m; k++) {
            x = segw[s, k]
            if (x ~ /^--force/ || x ~ /^-[A-Za-z]*f[A-Za-z]*$/ || x ~ /^\+/) {
                rd = "ask"; rr = "git push --force"; return 1
            }
        }
        return 0
    }
    if (h == "unset") {
        for (k = a; k <= m; k++) if (segw[s, k] ~ /^GH_TOKEN/) { rd = "ask"; rr = "unset GH_TOKEN"; return 1 }
        return 0
    }
    if (h ~ /^(bash|sh|zsh|dash|ksh|eval)$/) {
        t = body[s]
        for (k = a; k <= m; k++) t = t " " segw[s, k]
        if (h != "eval" && a > m && body[s] == "") t = src   # reads the script from a pipe
        if (mentions(t)) { rd = "ask"; rr = "text handed to " h " mentions a gated command"; return 1 }
    }
    return 0
}

function evalseg(s,   m, k, x, h, g) {
    m = segn[s]
    k = 1
    while (k <= m) {
        x = segw[s, k]
        if (x ~ /^(!|\{|\}|if|then|else|elif|fi|do|done|while|until|time|coproc)$/) { k++; continue }
        if (x ~ /^(for|select|case|\[\[|\[|test)$/) return
        if (x == "function") { k += 2; continue }
        if (x ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) { k++; continue }
        h = x; sub(/.*\//, "", h)
        if (h ~ /^(command|builtin|exec|nohup|setsid|stdbuf)$/) {
            for (k++; k <= m && segw[s, k] ~ /^-/; k++) if (segw[s, k] == "-a") k++
            continue
        }
        if (h == "env") {
            for (k++; k <= m && (segw[s, k] ~ /^-/ || segw[s, k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/); k++)
                if (segw[s, k] ~ /^(-u|-C|--unset|--chdir)$/) k++
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
        if (h == "xargs") {
            for (k++; k <= m && segw[s, k] ~ /^-/; k++) if (segw[s, k] ~ /^-[aEdILnPs]$/) k++
            continue
        }
        break
    }
    if (k > m) return
    x = segw[s, k]
    h = x; sub(/.*\//, "", h)
    if (segd[s, k] && x ~ /\$/) {
        # The command name is an expansion: ask if a gated command would fit.
        split("gh niwa git", g, " ")
        for (x = 1; x <= 3; x++)
            if (rules(s, g[x], k + 1, m)) { verdict("ask", "command name is not literal; would be " rr); return }
        return
    }
    if (rules(s, h, k + 1, m)) verdict(rd, rr)
}

END {
    rank[""] = 0; rank["ask"] = 1; rank["deny"] = 2
    best = ""; reason = ""; ambiguous = ""
    scan()
    for (s = 1; s <= nseg; s++) evalseg(s)
    if (ambiguous != "" && mentions(ambiguous))
        verdict("ask", "heredoc with command substitution mentions a gated command")
    if (unclosed && mentions(src))
        verdict("ask", "unclosed quote or substitution around a gated command")
    if (best == "") print "allow"
    else print best "\t" reason
}
')
STATUS=$?

if [ "$STATUS" -ne 0 ] || [ -z "$VERDICT" ]; then
    emit ask "gate-online hook could not inspect the command"
    exit 0
fi

case "$VERDICT" in
    deny*) emit deny "Blocked by gate-online hook: ${VERDICT#*	}" ;;
    ask*)  emit ask "Online operation requires confirmation: ${VERDICT#*	}" ;;
esac

# Everything else: allow
exit 0
