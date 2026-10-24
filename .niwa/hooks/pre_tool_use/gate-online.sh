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
# The instances named by GATE_MERGE_EXEMPT_INSTANCE may merge: one name, or
# several separated by commas, one merging coordinator per host. The names
# are kept out of this repository; the private overlay sets the var and
# workspace.toml promotes it into every instance's Claude settings, so each
# hook sees the same value. There the three merge denials (gh pr merge, the
# REST merge endpoint, the GraphQL merge mutations) are dropped; every other
# rule still applies. niwa installs this script at
# <instance>/.claude/hooks/pre_tool_use/gate-online.sh, and a copy in every
# repo at <instance>/<group>/<repo>/.claude/hooks/pre_tool_use/
# gate-online.local.sh. Each settings file runs its copy by that absolute
# path, so $0 names the instance the session belongs to. Every instance gets
# the same var; only the one whose own path matches it is exempt.
#
# The grant of a dispatched session
#
# Merging, closing an issue and creating a release each need a named
# authority niwa can grant a session it dispatches: merge-pr, close-issue and
# cut-release. For a command holding one of these (and only when nothing
# else in it is already denied), the hook asks niwa once who the session is:
#
#   niwa authority check --json --session <payload session_id>
#       -C <this script's directory> --point <authority>...
#
# and decides each needed authority by the answer:
#
#   bound, holds it, decider session, author exclusion off   allow
#   bound, lacks merge-pr or close-issue                     deny
#   bound, lacks cut-release                                 ask
#   bound, holds it, decider dispatcher                      deny
#   bound, holds it, decider person, or author exclusion on  as unlisted
#   record-unusable                                          as unlisted
#   not-dispatched, or the lookup failed                     as before
#
# "As unlisted" is the verdict an instance the exemption list doesn't name
# gets: deny for a merge, ask for a close or a release. "As before" is the
# verdict this hook gave without the lookup, exemption included, so the
# exemption list now matters only to sessions niwa didn't dispatch. Every
# other rule keeps its verdict for every session, and the final verdict is
# the most restrictive of the two: a grant never lifts a deny or an ask that
# came from anything else in the command. A command the scanner can't read
# (text handed to a shell, a command name that is an expansion, an unclosed
# quote) never takes a grant or the exemption, so $GH pr merge asks even in
# a listed instance.
#
# The lookup failed when niwa isn't found (command -v niwa, then $NIWA_BIN
# when it names an executable), when the payload carries no lowercase UUID
# session id, when this script's path isn't absolute, when niwa exits
# non-zero or runs past the bound, or when its answer isn't exactly one
# niwa.authority.check/v1 document whose state, authorities, level, deciders
# and author-exclusion values are all in niwa's vocabularies. The bound is 3
# seconds, or NIWA_LOOKUP_SECONDS when that is 1 or 2, so the whole hook
# finishes within 5 seconds even when niwa hangs. niwa's authority guide
# ("A gate on the binding") is the contract this follows.
#
# To remove the exemption, for instance once every merging session is
# dispatched with a grant: delete the case block below and the merge_exempt
# test in gated(), drop GATE_MERGE_EXEMPT_INSTANCE from workspace.toml, drop
# its value from the overlay, and delete the exempt rows in the tests.
#
# Tests: tests/gate-online.test.sh at the repository root.

MERGE_EXEMPT=0
# The var names one instance, or several separated by commas (one merging
# coordinator per host). Each name is matched whole against this script's own
# path; a name holding a slash or nothing is skipped, never matched.
exempt_rest=${GATE_MERGE_EXEMPT_INSTANCE:-}
while [ -n "$exempt_rest" ]; do
    exempt_name=${exempt_rest%%,*}
    if [ "$exempt_name" = "$exempt_rest" ]; then exempt_rest=; else exempt_rest=${exempt_rest#*,}; fi
    case "$exempt_name" in
        "" | */*) continue ;;
    esac
    case "$0" in
        */"$exempt_name"/.claude/hooks/pre_tool_use/gate-online.sh) MERGE_EXEMPT=1 ;;
        */"$exempt_name"/*/.claude/hooks/pre_tool_use/gate-online.local.sh) MERGE_EXEMPT=1 ;;
    esac
done
unset exempt_rest exempt_name

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

# Three verdicts are kept, each the most restrictive seen so far, first
# reason wins a tie: today (every rule, the exemption applied to merges),
# nonex (every rule, no exemption) and base (only the rules no grant covers).
function verdict(d, r) {
    if (rank[d] > rank[today]) { today = d; todayr = r }
    if (rank[d] > rank[nonex]) { nonex = d; nonexr = r }
    if (rank[d] > rank[base])  { base = d;  baser = r }
}

# A rule a grant can decide, needing authority au.
function gated(d, r, au) {
    needs[au] = 1
    if (rank[d] > rank[nonex]) { nonex = d; nonexr = r }
    if (merge_exempt && au == "merge-pr") return
    if (rank[d] > rank[today]) { today = d; todayr = r }
}

# Rules for command head h whose arguments are segw[s, a..m].
# Sets rd, rr and ra (the authority a grant would need, or ""); returns 1 on
# a match.
function rules(s, h, a, m,   x, k, sub1, sub2, get, t) {
    rd = ""; rr = ""; ra = ""
    if (h ~ /^(curl|wget|nc|ncat|netcat)$/) { rd = "deny"; rr = h; return 1 }
    if (h == "gh") {
        sub1 = segw[s, a]; sub2 = segw[s, a + 1]
        if (sub1 == "pr" && sub2 == "merge")        { rd = "deny"; rr = "gh pr merge"; ra = "merge-pr" }
        else if (sub1 == "repo" && sub2 == "delete") { rd = "deny"; rr = "gh repo delete" }
        else if (sub1 == "auth" && sub2 == "switch") { rd = "ask";  rr = "gh auth switch" }
        else if (sub1 == "release" && sub2 == "create") { rd = "ask"; rr = "gh release create"; ra = "cut-release" }
        else if (sub1 == "issue" && sub2 == "close") { rd = "ask";  rr = "gh issue close"; ra = "close-issue" }
        else if (sub1 == "api") {
            get = 0
            for (k = a + 1; k <= m; k++) {
                x = segw[s, k]
                if (x ~ /^(-X|--method)$/ && toupper(segw[s, k + 1]) == "GET") get = 1
                if (x ~ /^(-XGET|--method=GET)$/) get = 1
            }
            for (k = a + 1; k <= m; k++) {
                x = segw[s, k]
                if (x ~ /mergePullRequest|enablePullRequestAutoMerge/) { rd = "deny"; rr = "gh api merge mutation"; ra = "merge-pr" }
                else if (!get && x ~ /pulls\/[^\/]+\/merge([\/?]|$)/) { rd = "deny"; rr = "gh api pull request merge endpoint"; ra = "merge-pr" }
            }
        }
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
        # No grant and no exemption reaches a command the scanner cannot read.
        split("gh niwa git", g, " ")
        for (x = 1; x <= 3; x++)
            if (rules(s, g[x], k + 1, m)) { verdict("ask", "command name is not literal; would be " rr); return }
        return
    }
    if (rules(s, h, k + 1, m)) {
        if (ra != "") gated(rd, rr, ra)
        else verdict(rd, rr)
    }
}

function field(v, empty) { return v == "" ? empty : v }

END {
    rank[""] = 0; rank["ask"] = 1; rank["deny"] = 2
    today = ""; todayr = ""; nonex = ""; nonexr = ""; base = ""; baser = ""
    ambiguous = ""
    scan()
    for (s = 1; s <= nseg; s++) evalseg(s)
    if (ambiguous != "" && mentions(ambiguous))
        verdict("ask", "heredoc with command substitution mentions a gated command")
    if (unclosed && mentions(src))
        verdict("ask", "unclosed quote or substitution around a gated command")
    # The authorities, in the order niwa lists them.
    list = ""
    split("merge-pr close-issue cut-release", order, " ")
    for (k = 1; k <= 3; k++)
        if (order[k] in needs) list = list (list == "" ? "" : ",") order[k]
    # One line, tab-separated, no field empty: verdict and reason for today,
    # nonex and base, then the needed authorities.
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", field(today, "allow"), field(todayr, "-"),
        field(nonex, "allow"), field(nonexr, "-"), field(base, "allow"), field(baser, "-"),
        field(list, "-")
}
')
STATUS=$?

IFS='	' read -r TODAY TODAY_WHY NONEX NONEX_WHY BASE BASE_WHY NEEDS <<EOF
$VERDICT
EOF

if [ "$STATUS" -ne 0 ] || [ -z "$NEEDS" ]; then
    emit ask "gate-online hook could not inspect the command"
    exit 0
fi

# decide VERDICT REASON: prints the decision; allow prints nothing.
decide() {
    case "$1" in
        deny) emit deny "Blocked by gate-online hook: $2" ;;
        ask)  emit ask "Online operation requires confirmation: $2" ;;
    esac
}

# Nothing a grant decides, or something already denied that no grant lifts:
# today's verdict, with no lookup.
if [ "$NEEDS" = "-" ] || [ "$BASE" = "deny" ]; then
    decide "$TODAY" "$TODAY_WHY"
    exit 0
fi

# ---------------------------------------------------------------- the grant

# lookup: runs niwa authority check for the needed authorities and prints
# its validated answer, one value per line:
#   bound, level, the authorities held ("none" when it holds none), then
#   <authority>:<decider>:<author exclusion> for each needed authority
# or only the state for record-unusable and not-dispatched. Returns non-zero
# when the lookup failed, which leaves today's verdict.
lookup() {
    local niwa session anchor secs doc rc pid watcher answer
    local uuid='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    # Only an absolute path counts: a relative NIWA_BIN would resolve
    # against the session's working directory, and a name command -v
    # returns without a slash is an alias or function, not a program.
    niwa=$(command -v niwa 2>/dev/null)
    case "$niwa" in /*) ;; *) niwa= ;; esac
    if [ -z "$niwa" ]; then
        case "${NIWA_BIN:-}" in /*) ;; *) return 1 ;; esac
        [ -f "$NIWA_BIN" ] && [ -x "$NIWA_BIN" ] || return 1
        niwa=$NIWA_BIN
    fi

    session=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
    [[ "$session" =~ $uuid ]] || return 1

    # The instance is the one this copy was installed into, never the
    # payload's cwd.
    anchor=${0%/*}
    case "$anchor" in /*) ;; *) return 1 ;; esac

    case "${NIWA_LOOKUP_SECONDS:-}" in
        1 | 2) secs=$NIWA_LOOKUP_SECONDS ;;
        *) secs=3 ;;
    esac

    # niwa writes to a file, not a pipe, so a killed lookup can't hold the
    # hook open. The bound sends KILL, which nothing can ignore, so the
    # hook never outlives it waiting on a niwa that traps TERM.
    doc=$(mktemp "${TMPDIR:-/tmp}/gate-online.XXXXXX" 2>/dev/null) || return 1
    # NEEDS holds only names from the list in END, so it splits safely.
    set -- authority check --json --session "$session" -C "$anchor" --point ${NEEDS//,/ --point }
    if command -v timeout >/dev/null 2>&1; then
        timeout -s KILL "$secs" "$niwa" "$@" </dev/null >"$doc" 2>/dev/null
        rc=$?
    else
        "$niwa" "$@" </dev/null >"$doc" 2>/dev/null &
        pid=$!
        (sleep "$secs"; kill -KILL "$pid") </dev/null >/dev/null 2>&1 &
        watcher=$!
        wait "$pid" 2>/dev/null
        rc=$?
        kill "$watcher" 2>/dev/null
    fi
    if [ "$rc" -ne 0 ]; then
        rm -f "$doc"
        return 1
    fi

    # Exactly one document, and every value in it from niwa's vocabularies,
    # not only the needed points': an answer holding something unknown is
    # from a niwa this hook doesn't understand, and none of it is trusted.
    answer=$(jq -r -s --arg needs "$NEEDS" '
        def oneof($set): . as $v | any($set[]; . == $v);
        def authorities: ["merge-pr", "close-issue", "cut-release"];
        if length != 1 then error("not one document") else .[0] end
        | if type != "object" or .schema != "niwa.authority.check/v1" then error("schema") else . end
        | if (.state | oneof(["bound", "record-unusable", "not-dispatched"])) then . else error("state") end
        | if .state != "bound" then .state
          else
            (.grant | if type == "array" then map(.authority) else error("grant") end) as $held
            | if ($held | all(.[]; oneof(authorities))) then . else error("authority") end
            | if (.level | oneof(["autonomous", "supervised", "strict"])) then . else error("level") end
            | (.points | if type == "array" then . else error("points") end) as $points
            | if all($points[]; type == "object"
                    and (.decider | oneof(["session", "dispatcher", "person"]))
                    and (.author_exclusion | oneof(["on", "off"])))
              then . else error("point") end
            | "bound",
              .level,
              ([authorities[] | select(. as $a | $held | any(.[]; . == $a))]
                | if length == 0 then "none" else join(",") end),
              ($needs | split(",")[] as $a
                | ([$points[] | select(.point == $a)] | .[0]) as $p
                | if $p == null then error("point")
                  else "\($a):\($p.decider):\($p.author_exclusion)" end)
          end' "$doc" 2>/dev/null)
    rc=$?
    rm -f "$doc"
    [ "$rc" -eq 0 ] && [ -n "$answer" ] || return 1
    printf '%s\n' "$answer"
}

ANSWER=$(lookup) || ANSWER=
STATE=${ANSWER%%
*}

case "$STATE" in
    bound) ;;
    record-unusable)
        # The session is the dispatch's own, but its record can't be read:
        # it gets what an instance off the exemption list gets.
        decide "$NONEX" "$NONEX_WHY (the session's dispatch record can't be used)"
        exit 0
        ;;
    *)
        # not-dispatched, or the lookup failed.
        decide "$TODAY" "$TODAY_WHY"
        exit 0
        ;;
esac

# Bound: start from the rules no grant covers, then add each needed
# authority's verdict; the most restrictive wins, the first reason a tie.
FINAL=$BASE
FINAL_WHY=$BASE_WHY
raise() {
    local now new
    case "$FINAL" in deny) now=2 ;; ask) now=1 ;; *) now=0 ;; esac
    case "$1" in deny) new=2 ;; ask) new=1 ;; *) new=0 ;; esac
    if [ "$new" -gt "$now" ]; then
        FINAL=$1
        FINAL_WHY=$2
    fi
}

# unlisted AUTHORITY: what an instance off the exemption list gets.
unlisted() {
    case "$1" in merge-pr) echo deny ;; *) echo ask ;; esac
}

set -f
OLD_IFS=$IFS
IFS='
'
set -- $ANSWER
IFS=$OLD_IFS
set +f
LEVEL=$2
HELD=$3
shift 3
for POINT in "$@"; do
    AUTHORITY=${POINT%%:*}
    REST=${POINT#*:}
    DECIDER=${REST%%:*}
    EXCLUSION=${REST#*:}
    case ",$HELD," in
        *",$AUTHORITY,"*)
            if [ "$DECIDER" = dispatcher ]; then
                raise deny "session level $LEVEL; $AUTHORITY settled by dispatcher"
            elif [ "$DECIDER" = person ]; then
                raise "$(unlisted "$AUTHORITY")" "session level $LEVEL; $AUTHORITY settled by person"
            elif [ "$EXCLUSION" = on ]; then
                raise "$(unlisted "$AUTHORITY")" "author exclusion on for $AUTHORITY"
            fi
            ;;
        *)
            # A missing cut-release keeps today's ask; a missing merge-pr or
            # close-issue is denied.
            if [ "$AUTHORITY" = cut-release ]; then
                raise ask "session holds $HELD; needs $AUTHORITY"
            else
                raise deny "session holds $HELD; needs $AUTHORITY"
            fi
            ;;
    esac
done

decide "$FINAL" "$FINAL_WHY"
exit 0
