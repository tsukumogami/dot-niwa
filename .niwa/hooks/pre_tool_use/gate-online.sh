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
# Requires: jq, awk, mktemp. niwa is optional: without it every session gets
# the verdict it got before the grant. timeout is used when installed.
#
# How commands are found
#
# The command line is read, never run. One awk pass walks it and keeps track
# of what is code and what is data: text inside quotes, heredoc bodies and
# comments is data, so a commit message or PR body that mentions a gated
# command is not a gated command. The code is split into simple commands at
# newlines, ; & | ( ) and at $( ) and backticks, including those inside double
# quotes, which bash runs. Each simple command loses its leading VAR=value
# words, shell keywords (if, then, do, !, {, repeat) and wrappers, and its
# first words are compared with the rules below. The wrappers are command,
# builtin, exec, env, sudo, doas, nohup, setsid, stdbuf, nice, time (the
# keyword or the program, with its flags), timeout, gtimeout, caffeinate,
# arch, script, watch and xargs, and zsh's precommand modifiers noglob,
# nocorrect and -. A command name written with zsh's leading = (which zsh
# replaces with the program's path) is read without it. find's -exec,
# -execdir, -ok and -okdir actions and fd's -x and -X run a command too, and
# that command is read the same way. env -S splits its value into the command
# it runs, and that is read as well.
#
# The shell turns some words into others before a command sees them, and the
# scanner does the same where it can. A brace list or range is expanded into
# its words. A word holding an unquoted glob (* ? [...], zsh's parenthesized
# groups and alternation, and the extendedglob forms ^ # ~) matches whatever
# its pattern could match: in a place a rule reads a word (a gh subcommand,
# niwa reap, git push and its force flags, the name unset is given), a pattern
# that could be the word the rule wants counts as that word, and a command
# name that is a pattern counts as each gated command it could be. Under
# noglob nothing is a pattern. A word xargs or find fills in at run time can
# be anything: xargs appends words to its command unless given a replace
# string, and each word holding that string, or find's {}, is such a word.
# Such a word is not taken for a git push force flag or +refspec, as a $VAR
# word is not. A match that rests on a pattern or a run-time word never
# takes a grant or the exemption. Wrapper options are read as getopt reads
# them: a cluster or long option that takes a value takes the next word.
# command -v and -V only look a name up, so nothing runs.
#
# A gh command's two subcommand words are found the way gh finds them, past
# any flag before each and the value of -R or --repo, so gh pr -R o/r merge
# 12 is a merge. A gh api
# call's method is its last -X or --method in any spelling and case; only an
# explicit GET makes an endpoint a read, and no method flag counts as a write.
# On the merge endpoint a lowercase GET attached to its flag (-Xget,
# --method=get) still doesn't count, as it didn't before this reading.
#
# This is text inspection, not a shell parser. It does not expand variables,
# follow aliases or functions defined elsewhere, read script files, or see
# what a program does once it runs (a script calling the GitHub API, for
# instance). Where it can tell that it cannot tell, it asks:
#   - text handed to a shell (bash -c, sh -c, eval, a heredoc or here-string
#     fed to a shell, the line piping into a shell that reads its script
#     from standard input, the text watch runs, script -c) that mentions a
#     gated command;
#   - inline code handed to an interpreter (python -c, perl -e, ruby -e,
#     node -e, osascript -e, php -r, lua -e, deno eval, and the code an
#     interpreter reads from a heredoc, here-string or pipe when it is given
#     no script) that mentions a gated command, read with its quotes and
#     punctuation set aside, so a call written as a list of strings counts.
#     Three readings are joined and any one asks. The strict walk goes
#     from program to subcommand past an options object, or flags and their
#     values (one written as interpolation or quoted with blanks too), and
#     takes a force push as git (or a name git was assigned to) followed by
#     push with only git options, or a spread list of them, between them; a
#     gh workflow run there asks unless its selector is a literal .yml or
#     .yaml name. The wide reading, the one the hook used before the strict
#     walk, takes gh followed within a few words by a gated subcommand pair,
#     or niwa by reap, whatever lies between, and git before push on one
#     statement with a force flag or plus sign after it. The denied-pair
#     reading takes the words of a denied command (gh pr merge, gh repo
#     delete, niwa reap) named anywhere in the code in any order. The union
#     asks on some ordinary code (a safe gh or niwa call followed by a
#     printed merge or reap word; printed text holding git, push and a plus
#     sign), and that is accepted: an ordinary line the wide reading asks on
#     can carry a denied call the scanner can't read. An awk program counts
#     when it also runs a command (system, getline or a pipe);
#   - a command name that is itself an expansion ($GH pr merge);
#   - a command name that is a glob pattern which could be several gated
#     commands, or a wrapper running text that mentions one;
#   - a glob pattern whose text mentions a gated command (a zsh glob
#     qualifier can run code);
#   - a brace expansion too large to expand, around a gated command;
#   - a quote, $( or backtick that never closes, around text that mentions a
#     gated command;
#   - a workflow dispatch whose workflow it can't read (below);
#   - a gh api call whose endpoint is wholly an expansion ("$EP") and that
#     carries a method other than GET or a body flag;
#   - a gh api call with a method other than GET or a body flag, one of whose
#     words is a glob pattern or a word filled in at run time.
# These fail closed because the scanner can't normalize them into one
# command: it doesn't run the code, expand the pattern against the disk, or
# know what xargs will read. Code that hides the command from plain reading
# (built from pieces, encoded, read from a file) is out of reach, as a script
# file is.
#
# Rules
#   deny: gh pr merge, gh repo delete, gh api to pulls/<n>/merge or the
#         GraphQL mergePullRequest / enablePullRequestAutoMerge mutations,
#         curl, wget, nc, ncat, netcat, niwa reap
#   ask:  gh auth switch, gh release create, gh issue close, unset GH_TOKEN,
#         git push with --force, --force-with-lease, -f or a +refspec,
#         a release workflow dispatch
#
# niwa reap is denied on a literal niwa with any flags ahead of it: a flag
# takes at most one value, --no-progress takes none, and the first plain word
# no flag could own is the subcommand. Text handed to a shell that holds niwa,
# flags and reap asks, since the hook can't tell whether that text runs as a
# command. A non-literal command name is read as before.
#
# Scratch reap. One reap is allowed: a workspace a check made for itself and
# declared scratch, reaped with exactly
#     cd <root> && niwa [--no-progress] reap [--no-progress|--help|-h]
# as the whole command. <root> is a literal absolute path in
# [A-Za-z0-9._+/-], with no //, . or .. component, and equal to its own
# physical path, which is what `pwd -P` prints in it (on macOS a mktemp path
# is /private/var/..., not /var/...). The declaration is .niwa/scratch-check
# at <root>, a regular file, not a symlink, whose first line is <root>. The
# payload's cwd plays no part. The allowance is refused, and the deny stands
# with its message, when <root>:
#   - is in, above or equal to this hook's own workspace;
#   - holds .niwa/.niwa-snapshot.toml (a config taken from a source), a .git
#     where niwa clones repos, or a .niwa that is a git working tree;
#   - carries an installed copy of this hook, in its config's hooks, at its
#     root or in an instance (a workspace this hook guards is never a scratch
#     made for a check);
#   - holds an entry named niwa, or this hook's PATH has an empty or relative
#     entry.
# Limits: anyone who can write in a workspace can declare it, so a bare
# niwa init workspace with no repo, no snapshot and no hook copy is
# reapable once declared. An allowed reap runs the scratch's own
# [session.on_reap] and [session.before_remove]. The hook checks the path and
# exits before the shell runs the cd, so a swap of the directory in between
# isn't seen. The flag walk reads --no-progress as taking no value; a niwa
# change to its root flags reviews this hook (tests/niwa-flags.test.sh pins
# it).
#
# A release workflow dispatch is gh workflow run, or a gh api call other than
# a GET to repos/<owner>/<repo>/actions/workflows/<selector>/dispatches,
# whose selector is prepare-release.yml, prepare-release.yaml,
# release-prepare.yml, release-prepare.yaml or "Prepare Release" in any case.
# The selector of gh workflow run is the one word left once the flags, and
# the values of -r, --ref, -R, --repo, -f, --raw-field, -F and --field, are
# set aside. A selector that is missing, one of two or more such words,
# digits only (a workflow id), an expansion, or holds any of
# * ? [ ] { } ~ \ % / can't be read, and asks for every session. Any other
# selector is not gated: CI and maintenance workflows dispatch freely. On
# the gh api path, whatever comes before actions/workflows/ (a literal or
# expanded owner and repo, {owner}/{repo}, a host) doesn't matter, the path
# is read in any case, and a path that names workflows and dispatches in any
# other shape (./, ../, extra segments) can't be read either.
#
# The instances named by GATE_MERGE_EXEMPT_INSTANCE may merge: one name, or
# several separated by commas, one merging coordinator per host. The names
# are kept out of this repository; the private overlay sets the var and
# workspace.toml promotes it into every instance's Claude settings, so each
# hook sees the same value. There, for a session niwa didn't dispatch, the
# three merge denials (gh pr merge, the REST merge endpoint, the GraphQL
# merge mutations) are dropped when the command names them literally; every
# other rule still applies. niwa installs this script at
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
# cut-release, which covers a release workflow dispatch as well as gh release
# create. For a command holding one of these (and only when nothing
# else in it is already denied), the hook asks niwa once who the session is:
#
#   niwa authority check --json --session <payload session_id>
#       -C <this script's directory> --point <authority>...
#
# and decides each needed authority by the answer:
#
#   bound, holds it, decider session, author exclusion off   allow
#   bound, lacks it                                          deny
#   bound, holds it, decider dispatcher                      deny
#   bound, holds it, decider person, or author exclusion on  handed on
#   record-unusable, a release needed                        deny
#   record-unusable, otherwise                               as unlisted
#   not-dispatched, or the lookup failed                     as before
#
# "Handed on" is deny for a merge or a release and ask for a close: a
# dispatched session releases only on its grant, as it merges only on its
# grant, and one whose record can't be used is denied a release the same way.
# "As unlisted" is the verdict an instance the exemption list doesn't name
# gets: deny for a merge, ask for a close. "As before" is the
# verdict this hook gave without the lookup, exemption included, so the
# exemption list now matters only to sessions niwa didn't dispatch. Every
# other rule keeps its verdict for every session, and the final verdict is
# the most restrictive of the two: a grant never lifts a deny or an ask that
# came from anything else in the command. A command the scanner can't read
# (text handed to a shell, a command name that is an expansion, an unclosed
# quote, a workflow selector or gh api endpoint it can't read, a match that
# rests on a glob or a word given at run time) never takes a grant or the
# exemption, so $GH pr merge asks even in a listed instance.
#
# A release workflow dispatch gets these verdicts too, so before it a session
# niwa didn't dispatch is asked, as it is before gh release create.
# UNDISPATCHED_RELEASE_DISPATCH, set to allow, gives those sessions back the
# verdict they had before this rule; nothing else changes with it.
#
# The lookup failed when niwa isn't found (command -v niwa, then $NIWA_BIN
# when it names an executable), when the payload carries no lowercase UUID
# session id, when this script's path isn't absolute, when niwa exits
# non-zero or runs past the bound, or when its answer isn't exactly one
# niwa.authority.check/v1 document whose state, authorities, level, deciders
# and author-exclusion values are all in niwa's vocabularies. The bound is 3
# seconds, or NIWA_LOOKUP_SECONDS when that is 1 or 2, so the whole hook
# finishes within 5 seconds even when niwa hangs. niwa's authority guide
# ("A gate on the binding") is the contract this follows. Gating another
# authority means touching rules() (ra), the order list in END, the jq
# authorities list and handed_on(). Gating another command under an
# existing authority needs only rules() and mentions(), as the release
# workflow dispatch does under cut-release.
#
# To remove the exemption, for instance once every merging session is
# dispatched with a grant: delete the case block below and the merge_exempt
# test in gated(), drop GATE_MERGE_EXEMPT_INSTANCE from workspace.toml, drop
# its value from the overlay, and delete the exempt rows in the tests.
#
# Tests: tests/gate-online.test.sh at the repository root.

# What a session niwa didn't dispatch (or whose lookup failed) gets for a
# release workflow dispatch: ask, or allow for the verdict it had before the
# release dispatch rule. Every other session state and rule is unaffected.
UNDISPATCHED_RELEASE_DISPATCH=ask

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

VERDICT=$(printf '%s' "$COMMAND" | LC_ALL=C awk -v merge_exempt="$MERGE_EXEMPT" \
    -v undispatched_release_dispatch="$UNDISPATCHED_RELEASE_DISPATCH" '
BEGIN { RS = "\001" }
{ src = (NR == 1) ? $0 : src "\001" $0 }

# ---------------------------------------------------------------- scanning
# env-print-guard.sh beside this hook carries a copy of this scanner that has
# diverged from it: the copy lacks the character mask, brace expansion and zsh
# glob groups below. Bringing it level is a follow-up; until then, a fix to
# the part both still share belongs in both.
#
# Beside each word the scanner keeps a mask, one letter per character: "a"
# for a character the shell acts on (unquoted, so it can be a glob or a
# brace), "l" for one it takes literally (quoted, escaped, or the result of
# an expansion). segm[s, k] holds it for word k of segment s.

function rep(ch, n,   r) {
    r = ""
    while (n > 0) { if (n % 2) r = r ch; ch = ch ch; n = int(n / 2) }
    return r
}

function lit(t) { word = word t; wmask = wmask rep("l", length(t)) }

function pushword(w, mk) {
    segn[seg]++
    segw[seg, segn[seg]] = w
    segd[seg, segn[seg]] = wdyn
    segm[seg, segn[seg]] = mk
    # The command word of the segment, for telling a zsh glob group after it from
    # a subshell.
    if (seghd[seg] == "" && w !~ /^(!|\{|\}|if|then|else|elif|fi|do|done|while|until|time|coproc)$/ &&
        w !~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) seghd[seg] = w
}

function addword(   b) {
    if (!wany) return
    if (redir_next) {
        redir_next = 0
    } else if (herestr_next) {
        body[seg] = body[seg] "\n" word
        herestr_next = 0
    } else if (index(wmask, "a") && index(word, "{")) {
        braces(word, wmask)
        for (b = 1; b <= nbr; b++) pushword(brw[b], brm[b])
    } else pushword(word, wmask)
    word = ""; wmask = ""; wany = 0; wdyn = 0
}

# Finds the first brace group in w (mask mk) the shell expands: unquoted
# braces around a top-level comma or a range. Sets bj and bk to its braces
# and returns 1, with bc[1..nbc] its top-level commas (none for a range).
function bgroup(w, mk,   L, j, k, d, c) {
    L = length(w)
    for (j = 1; j <= L; j++) {
        if (substr(w, j, 1) != "{" || substr(mk, j, 1) != "a") continue
        d = 0; nbc = 0
        for (k = j + 1; k <= L; k++) {
            if (substr(mk, k, 1) != "a") continue
            c = substr(w, k, 1)
            if (c == "{") d++
            else if (c == "}") { if (d == 0) break; d-- }
            else if (c == "," && d == 0) bc[++nbc] = k
        }
        if (k > L) continue
        bj = j; bk = k
        if (nbc > 0) return 1
        c = substr(w, j + 1, k - j - 1)
        if (substr(mk, j + 1, k - j - 1) !~ /l/ &&
            (c ~ /^-?[0-9]+\.\.-?[0-9]+(\.\.-?[0-9]+)?$/ || c ~ /^[A-Za-z]\.\.[A-Za-z](\.\.-?[0-9]+)?$/)) return 1
    }
    return 0
}

# Brace expansion of w (mask mk), in the order the shell uses, into
# brw[1..nbr] and brm[1..nbr]. Words that expand to nothing are dropped.
# Past a cap of 256 words braceover is set.
function braces(w, mk,   sp, x, xm, pre, prm, suf, sum, k, r, lo, hi, step, n, alts, cs, p, q) {
    nbr = 0; sp = 1; stw[1] = w; stm[1] = mk; n = 0
    while (sp > 0) {
        x = stw[sp]; xm = stm[sp]; sp--
        if (!bgroup(x, xm)) {
            if (x != "") { nbr++; brw[nbr] = x; brm[nbr] = xm }
            continue
        }
        pre = substr(x, 1, bj - 1); prm = substr(xm, 1, bj - 1)
        suf = substr(x, bk + 1); sum = substr(xm, bk + 1)
        # The alternatives, first to last, pushed back in reverse so the
        # first is expanded first.
        alts = 0
        if (nbc > 0) {
            bc[0] = bj; bc[nbc + 1] = bk
            for (k = 0; k <= nbc; k++) {
                alts++
                altw[alts] = substr(x, bc[k] + 1, bc[k + 1] - bc[k] - 1)
                altm[alts] = substr(xm, bc[k] + 1, bc[k + 1] - bc[k] - 1)
            }
        } else {
            r = substr(x, bj + 1, bk - bj - 1)
            split(r, p, /\.\./)
            step = (p[3] == "") ? 1 : p[3] + 0
            if (step < 0) step = -step
            if (step == 0) step = 1
            cs = "ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz"
            if (p[1] ~ /^[A-Za-z]$/) { lo = index(cs, p[1]); hi = index(cs, p[2]) }
            else { lo = p[1] + 0; hi = p[2] + 0 }
            for (q = lo; (lo <= hi) ? (q <= hi) : (q >= hi); q += (lo <= hi) ? step : -step) {
                if (++alts > 256) break
                altw[alts] = (p[1] ~ /^[A-Za-z]$/) ? substr(cs, q, 1) : q ""
                altm[alts] = rep("a", length(altw[alts]))
            }
        }
        n += alts
        if (n > 256 || sp + alts > 256) {
            # Past the cap: the words expanded so far stay, and the rest are
            # kept as they stand.
            braceover = 1
            nbr++; brw[nbr] = x; brm[nbr] = xm
            for (; sp > 0; sp--) { nbr++; brw[nbr] = stw[sp]; brm[nbr] = stm[sp] }
            return
        }
        for (k = alts; k >= 1; k--) {
            sp++; stw[sp] = pre altw[k] suf; stm[sp] = prm altm[k] sum
        }
    }
}

# A word made only of digits right before < or > is a file descriptor.
function addword_fd() {
    if (wany && word ~ /^[0-9]+$/) { word = ""; wmask = ""; wany = 0; wdyn = 0; return }
    addword()
}

function newseg() {
    addword()
    seg = ++nseg
    segn[seg] = 0
}

# A pending redirection or here-string waits for the word the substitution
# is part of, not for the first word inside it.
function push(type) {
    fsp++
    ftype[fsp] = type; fmode[fsp] = mode; fseg[fsp] = seg
    fword[fsp] = word; fwmask[fsp] = wmask; fwany[fsp] = wany; fwdyn[fsp] = wdyn; fdepth[fsp] = 0
    fredir[fsp] = redir_next; fherestr[fsp] = herestr_next
    word = ""; wmask = ""; wany = 0; wdyn = 0; redir_next = 0; herestr_next = 0
    mode = "c"
    seg = ++nseg
    segn[seg] = 0
}

function pop() {
    addword()
    seg = fseg[fsp]; mode = fmode[fsp]
    word = fword[fsp] "$(...)"; wmask = fwmask[fsp] "llllll"; wany = 1; wdyn = 1
    redir_next = fredir[fsp]; herestr_next = fherestr[fsp]
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
        lit(substr(rest, 1, j)); wany = 1; wdyn = 1
        i += j
    } else if (nx != "" && index("?#@*!$-0123456789", nx)) {
        # A special parameter: $? is a status, not a glob.
        lit("$" nx); wany = 1; wdyn = 1
        i += 2
    } else {
        lit("$"); wany = 1; wdyn = 1
        i++
    }
}

# Called with i on "(" in code. In zsh a parenthesized group inside a word,
# or as an argument after the command word, is a glob group: read it into
# the word, its parentheses and | active, and return 1. Anything else (a
# subshell, a function definition, an array assignment, a group that never
# closes on its line or holds only blanks) returns 0 and is read as before.
function globparen(   k, d, ch, t, tm, q, j) {
    if (substr(src, i + 1, 1) == ")") return 0
    if (wany) { if (word ~ /=$/ || word == "!") return 0 }
    else if (seghd[seg] == "" || seghd[seg] ~ /^(for|select|case|foreach|function|repeat|\[\[|\[|test|coproc)$/) return 0
    k = i; d = 0; t = ""; tm = ""
    while (k <= n) {
        ch = substr(src, k, 1)
        if (ch == "\n") break
        if (ch == "\047") {
            q = substr(src, k + 1); j = index(q, "\047")
            if (!j) break
            t = t substr(q, 1, j - 1); tm = tm rep("l", j - 1); k += j + 1
            continue
        }
        if (ch == "\"") {
            for (j = k + 1; j <= n && substr(src, j, 1) != "\""; j++)
                if (substr(src, j, 1) == "\\") j++
            if (j > n) break
            t = t substr(src, k + 1, j - k - 1); tm = tm rep("l", j - k - 1); k = j + 1
            continue
        }
        if (ch == "\\") { t = t substr(src, k + 1, 1); tm = tm "l"; k += 2; continue }
        t = t ch; tm = tm "a"; k++
        if (ch == "(") d++
        else if (ch == ")" && --d == 0) break
    }
    if (d != 0 || t ~ /^\([ \t]*\)$/) return 0
    word = word t; wmask = wmask tm; wany = 1
    i = k
    return 1
}

function scan(   c, nx, rest, j, k) {
    n = length(src)
    mode = "c"; fsp = 0; nph = 0; nseg = 0; unclosed = 0
    seg = ++nseg; segn[seg] = 0
    word = ""; wmask = ""; wany = 0; wdyn = 0
    i = 1
    while (i <= n) {
        c = substr(src, i, 1)
        if (mode == "d") {
            if (c == "\"") { mode = "c"; i++ }
            else if (c == "\\") {
                nx = substr(src, i + 1, 1)
                if (nx == "\n") i += 2
                else if (nx ~ /[$`"\\]/) { word = word nx; wmask = wmask "l"; i += 2 }
                else { word = word c; wmask = wmask "l"; i++ }
            }
            else if (c == "`") { push("tick"); i++ }
            else if (c == "$") dollar()
            else { word = word c; wmask = wmask "l"; i++ }
            continue
        }
        # code
        if (c == "\\") {
            nx = substr(src, i + 1, 1)
            if (nx != "\n") { lit(nx); wany = 1 }
            i += 2
        } else if (c == "\047") {
            rest = substr(src, i + 1)
            j = index(rest, "\047")
            if (!j) { lit(rest); wany = 1; unclosed = 1; i = n + 1 }
            else { lit(substr(rest, 1, j - 1)); wany = 1; i += j + 1 }
        } else if (c == "\"") {
            mode = "d"; wany = 1; i++
        } else if (c == "$" && substr(src, i + 1, 1) == "\047") {
            # $'...' : backslash escapes, ends at an unescaped quote
            k = i + 2
            while (k <= n && substr(src, k, 1) != "\047") k += (substr(src, k, 1) == "\\") ? 2 : 1
            if (k > n) unclosed = 1
            lit(substr(src, i + 2, k - i - 2)); wany = 1
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
            if (globparen()) continue
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
            word = word c; wmask = wmask "a"; wany = 1; i++
        }
    }
    addword()
    if (fsp > 0 || mode == "d") unclosed = 1
}

# ---------------------------------------------------------------- rules

function mentions(t) {
    return gmentions(t) ||
           t ~ /push[ \t]([^\n;&|]*[ \t])?(--force|-[A-Za-z]*f[A-Za-z]*([ \t\n;&|]|$)|\+)/
}

# Whether text t holds niwa, then flags, then the whole word reap, where a flag
# may have one value after it. --no-progress takes no value, so it is removed
# first, from this copy of t: an alternation could not stop that word from
# matching as a flag with the next word as its value.
function flagreap(t) {
    while (gsub(/(^|[ \t\n])--no-progress([ \t\n]|$)/, " ", t) > 0) { }
    return t ~ /niwa[ \t\n]+(-[^ \t\n;&|]*[ \t\n]+([^- \t\n;&|][^ \t\n;&|]*[ \t\n]+)?)*reap([^-A-Za-z0-9_.\/=:+]|$)/
}

# mentions() less its force push reading, which each caller adds its own way.
function gmentions(t) {
    return t ~ /gh[ \t\n]+(pr[ \t\n]+merge|repo[ \t\n]+delete|auth[ \t\n]+switch|release[ \t\n]+create|issue[ \t\n]+close)/ ||
           t ~ /pulls\/[^\/ \t\n]+\/merge|mergePullRequest|enablePullRequestAutoMerge/ ||
           t ~ /niwa[ \t\n]+reap|unset[ \t\n]+GH_TOKEN/ || flagreap(t) ||
           tolower(t) ~ /prepare-release|release-prepare|prepare[ \t]+release/ ||
           t ~ /actions\/workflows\/[^ \t\n]*\/dispatches/ ||
           t ~ /(^|[^A-Za-z0-9_.-])(curl|wget|nc|ncat|netcat)([ \t\n]|$)/
}

# Code with its quotes and punctuation turned into blanks, so a call written
# as a list of strings reads as the command it names. With keep, the
# statement separators ; & and | stay.
function loosen(t, keep) {
    if (keep) gsub(/[^A-Za-z0-9_.\/+=\n;&|-]/, " ", t)
    else gsub(/[^A-Za-z0-9_.\/+=\n-]/, " ", t)
    return t
}

# Whether inline interpreter code t mentions a gated command. First the
# patterns mentions() uses, on the code as it is and with its punctuation set
# aside. Then four shapes over the words of the code (split at blanks,
# quotes, brackets, parentheses and commas, so a quoted option value holding
# ; & or | stays one word):
#   - git (or a name git was assigned to earlier in the code), then push
#     with only git options between them: flags, a spread or splat of a
#     list (...opts, *opts), a string prefix such as f or rb before a flag,
#     and the value of an option that takes one (see valend(), so a value
#     built from interpolated or joined pieces, or a quoted value holding
#     blanks, still counts). There is no cap on how many options there are.
#     An options object between git and its arguments counts too: when an
#     args, argv or cmd key comes within 48 words of git with no push or
#     statement separator before it, the same walk starts again after the
#     key. Then a force flag (alone, in a cluster, or -fo) or a +refspec
#     later on the same line as push. Any other word before push means no
#     push, so ordinary code that names git and later pushes onto an array
#     is left alone.
#   - gh, then within its next 24 words one of its gated subcommand pairs,
#     with only flags between the two words, and after -R or --repo its
#     value read the same way.
#   - gh, then workflow and run the same way, then a selector, the first
#     word after run that is not a flag or the value of -r, --ref, -R,
#     --repo, -f, --raw-field, -F or --field, that is not a literal file
#     name ending .yml or .yaml: a variable, a workflow id or a missing one
#     cannot be read, as on the shell path.
#   - niwa followed by reap past any flags (and the value of -C), or an
#     args, argv or cmd key followed by reap that way with niwa at most 24
#     words before the key.
# A flag here is a word starting - or -- and then a letter, so a lone -, --
# or -> in code is no flag; between gh pair words, or between niwa and reap,
# a -- counts only after a flag (alone it asked on ordinary text such as
# "release --" before "create"). A flag ending = (--git-dir=)
# takes the next word as its value. These windows are bounded, but this
# strict walk is not the whole check: interp() also asks when the wide
# reading, wmentions(), or the denied-pair reading, comention(), finds a
# gated command, so the inline check is the union of the three. Code that
# spreads a command beyond all three, or over several lines (a force flag on
# the line after push), is out of reach, as
# code that builds the command from pieces is. Shell text is not read this
# way: it goes through mentions().
function imentions(t,   n, i, j, k, x, y, np, pw, q, lim, gv) {
    if (gmentions(t) || gmentions(loosen(t))) return 1
    n = iwords(t)
    np = split("pr merge repo delete auth switch release create issue close", pw, " ")
    for (i = 1; i <= n; i++) {
        x = iw[i]; sub(/.*\//, "", x)
        # git assigned to a name: the name stands for git from there on.
        if (x == "git" && ia[i] && i > 1) { y = iw[i - 1]; sub(/:?=$/, "", y); if (y != "") gv[y] = 1 }
        if ((x == "git" || (iw[i] in gv)) && forcepush(i, n)) return 1
        if (x == "niwa" && reach(i + 1, n, "reap")) return 1
        if (iw[i] ~ /^(args|argv|cmd)[:=]*$/ && reach(i + 1, n, "reap"))
            for (j = i - 1; j >= 1 && j >= i - 24; j--) {
                y = iw[j]; sub(/.*\//, "", y)
                if (y == "niwa") return 1
            }
        if (x == "gh") {
            lim = i + 24
            if (lim > n - 1) lim = n - 1
            for (j = i + 1; j <= lim; j++) {
                for (q = 1; q < np; q += 2)
                    if (iw[j] == pw[q] && reach(j + 1, n, pw[q + 1])) return 1
                if (iw[j] == "workflow" && (k = reach(j + 1, n, "run"))) {
                    for (k++; k <= n && isflag(iw[k]); k++)
                        if (iw[k] ~ /^(-r|--ref|-R|--repo|-f|--raw-field|-F|--field)$/) k++
                    if (k > n || iw[k] !~ /^[A-Za-z0-9_.-]+\.ya?ml$/) return 1
                }
            }
        }
    }
    return 0
}

# The denied pairs failing closed: the words of u (code with its punctuation
# set aside, a path before a word dropped) name gh, pr and merge, gh, repo
# and delete, or niwa and reap, anywhere, in any order. A loop or a later
# statement can name the subcommand before the call, which neither ordered
# reading (the strict walk in imentions(), the wide one in wmentions())
# sees. Only the denied pairs (gh pr merge, gh repo delete, niwa reap) are
# read this way;
# the asked ones are not.
function comention(u,   w, n, i, x, s) {
    n = split(u, w, /[ \t\n]+/)
    for (i = 1; i <= n; i++) { x = w[i]; sub(/.*\//, "", x); s[x] = 1 }
    return (("gh" in s) && ("pr" in s) && ("merge" in s)) ||
           (("gh" in s) && ("repo" in s) && ("delete" in s)) ||
           (("niwa" in s) && ("reap" in s))
}

# The wide reading of inline code, the one the hook used before the strict
# walk in imentions(), kept beside it unchanged so the inline check never
# allows what this reading asked on. wmentions() asks when the code, as it
# is or with its punctuation set aside, holds a gated command as mentions()
# reads one; when git comes before push with any words but a statement
# separator between them and a force flag or a plus sign follows push on that line (gitpush(),
# read once on the code as it is and once with only the separators kept);
# or when, among the words of the code with its punctuation set aside, gh is
# followed within twelve words by one of its gated subcommand pairs in order,
# or niwa by reap (spaced()). Order is all spaced() looks at, so a gh or
# niwa call whose subcommand words sit in a dict, a split string, a joined
# list, a comprehension or a later extend counts here though the strict walk
# does not step over them. The strict walk adds shapes this reading misses:
# a long run of git options, a git name assigned earlier, an options object,
# a gh workflow run selector. The denied-pair reading, comention(), adds the
# denied subcommands named before their call.
#
# Ordinary code this reading asks on is accepted: a safe gh or niwa call
# followed by a printed merge or reap word, or printed text holding git,
# push and a plus sign. Such a line can carry a denied call the scanner
# cannot read (built from character codes, say) beside the words this
# reading finds, and allowing it would let that call through.
function wmentions(t,   u) {
    u = loosen(t)
    return gmentions(t) || gmentions(u) || gitpush(t) || gitpush(loosen(t, 1)) || spaced(u)
}

function gitpush(t) {
    return t ~ /(^|[^A-Za-z0-9_.-])git[ \t\n]+([^ \t\n;&|]+[ \t\n]+)*push[ \t]([^\n;&|]*[ \t])?(--force|-[A-Za-z]*f[A-Za-z]*([ \t\n;&|]|$)|\+)/
}

function spaced(u,   w, n, i, p, q, np, pw, lim) {
    n = split(u, w, /[ \t\n]+/)
    np = split("pr merge repo delete auth switch release create issue close", pw, " ")
    for (i = 1; i <= n; i++) {
        lim = i + 12
        if (lim > n) lim = n
        if (w[i] == "niwa" && near(w, lim, i, "reap")) return 1
        if (w[i] != "gh") continue
        for (q = 1; q < np; q += 2)
            if ((p = near(w, lim, i, pw[q])) && near(w, lim, p, pw[q + 1])) return 1
    }
    return 0
}

# The position of the first word x among w[i + 1 .. lim], or 0.
function near(w, lim, i, x,   j) {
    for (j = i + 1; j <= lim; j++) if (w[j] == x) return j
    return 0
}

# Whether word x is a flag in inline code: - or -- and then a letter.
function isflag(x) {
    return x ~ /^--?[A-Za-z]/
}

# The index of word want when it comes from iw[k] on past flags only, else
# 0. The value of -R or --repo (gh), -C (niwa) or a flag ending = is stepped
# over as valend() reads it. A -- is stepped over too once a flag has been:
# right after a subcommand word it is ordinary text ("release --").
function reach(k, n, want,   f) {
    while (k <= n && iw[k] != want && (isflag(iw[k]) || (f && iw[k] == "--"))) {
        if ((iw[k] ~ /^(-R|--repo|-C)$/ || iw[k] ~ /^--?[A-Za-z][A-Za-z-]*=$/) && k < n)
            k = valend(k + 1, n, want, 0)
        else k++
        f = 1
    }
    return (k <= n && iw[k] == want) ? k : 0
}

# The index of the first word past an option value that starts at iw[v]:
# the first word always, then up to five more words on its line, up to want.
# When the first word followed a quote, a word no quote separates from the
# one before it is the rest of that quoted string (a blank or a leading -
# inside it, as in "ssh -i k"). Any other word continues the value (pieces
# of an interpolated or joined value) while no statement separator comes
# before it, it does not start with -, and, with git set, it is not a git
# subcommand name.
function valend(v, n, want, git,   k) {
    for (k = v + 1; k - v <= 5 && k <= n && il[k] == il[v] && iw[k] != want; k++) {
        if (iq[v] && !iq[k]) continue
        if (is[k] || iw[k] ~ /^-/ || (git && gitsub(iw[k]))) break
    }
    return k
}

# Splits inline code t into words iw[1..n], the line of each in il[]: words
# end at blanks, quotes, backslashes, brackets, parentheses, braces and
# commas, and lose any ; & or | at their ends. A word left as only : or =
# (after a quoted key such as "args":) is dropped, so a value that was only
# a separator leaves nothing behind. A + right before { (an interpolated
# refspec) keeps a word, read as +_. For each word it also records in is[]
# whether a statement separator (; & or | standing alone or ending the word
# before) came before it on its line, in iq[] whether a quote came before
# it, and in ia[] whether it follows an assignment (a lone = or :=, or a
# word ending = but not ==, <=, >= or !=). Returns n. The checks after it
# read these arrays, so iwords() runs first.
function iwords(t,   L, nl, s, i, n, x, d, sep, ld, tr, dq, eq, D) {
    delete iw; delete il; delete is; delete iq; delete ia
    D = "[] \t\r\"\047`,()[{}\\\\]+"
    nl = split(t, L, "\n"); n = 0
    for (i = 1; i <= nl; i++) {
        s = L[i]
        gsub(/\+\{/, "+_{", s)
        sep = 0; dq = 0; eq = 0
        while (s != "") {
            if (match(s, D) && RSTART == 1) {
                d = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
                if (d ~ /["\047`]/) dq = 1
                continue
            }
            if (match(s, D)) { x = substr(s, 1, RSTART - 1); s = substr(s, RSTART) }
            else { x = s; s = "" }
            ld = (x ~ /^[;&|]/); tr = (x ~ /[;&|]$/)
            gsub(/^[;&|]+|[;&|]+$/, "", x)
            if (x != "" && x !~ /^[:=]+$/) {
                iw[++n] = x; il[n] = i; is[n] = sep; iq[n] = dq
                ia[n] = eq || (n > 1 && il[n - 1] == i && iw[n - 1] ~ /(^|[^=!<>:])=$|:=$/ && !is[n])
                sep = tr; dq = 0; eq = 0
            } else {
                if (ld || tr) sep = 1
                eq = (x ~ /^:?=$/)
            }
        }
    }
    return n
}

# Whether git at iw[i] reaches push through git options only (or through an
# options object holding an args, argv or cmd key), and a force flag (alone,
# in a cluster, or -fo) or a +refspec follows push on its line. See
# imentions() for the shape. The stop list holds the common subcommands, not
# all of them: a value word that is a missing name can only make the check
# ask more, never miss a push.
function forcepush(i, n,   j, p, k) {
    p = gitwalk(i + 1, n)
    if (!p)
        for (k = i + 1; k <= n && k <= i + 48; k++) {
            if (iw[k] == "push" || is[k]) break
            if (iw[k] ~ /^(args|argv|cmd)[:=]*$/) { p = gitwalk(k + 1, n); break }
        }
    if (!p) return 0
    for (j = p + 1; j <= n && il[j] == il[p]; j++)
        if (iw[j] ~ /^(-[uqvn46d]*f[uqvn46d]*o?|--force|--force-with-lease(=.*)?|--force-if-includes)$/ || iw[j] ~ /^\+[A-Za-z0-9_.\/@:$%]/) return 1
    return 0
}

# The index of push when the words from iw[j] on reach it through git
# options only, else 0: flags, a spread or splat (...opts, *opts, **kw), and
# a string prefix (f, r, b, u, rb, br, fr, rf) right before a flag. After an
# option gitvalue() names, or a flag ending =, its value runs as valend()
# reads it, unless the next word is push itself (the value was only a
# separator, which iwords() dropped).
function gitwalk(j, n) {
    while (j <= n && iw[j] != "push") {
        if (iw[j] ~ /^(f|r|b|u|rb|br|fr|rf)$/ && iw[j + 1] ~ /^-/) { j++; continue }
        if (!isflag(iw[j]) && iw[j] !~ /^(\.\.\.|\*\*?)[A-Za-z_]/) return 0
        if ((gitvalue(iw[j]) || iw[j] ~ /^--?[A-Za-z][A-Za-z-]*=$/) && j < n && iw[j + 1] != "push")
            j = valend(j + 1, n, "push", 1)
        else j++
    }
    return j <= n ? j : 0
}

# Whether x names a common git subcommand other than push.
function gitsub(x) {
    return x ~ /^(add|am|apply|archive|bisect|blame|branch|bundle|cat-file|checkout|cherry|cherry-pick|clean|clone|commit|config|count-objects|describe|diff|diff-index|diff-tree|difftool|fetch|for-each-ref|format-patch|fsck|gc|grep|hash-object|help|init|log|ls-files|ls-remote|ls-tree|merge|merge-base|mergetool|mv|name-rev|notes|pull|range-diff|rebase|reflog|remote|repack|replace|reset|restore|rev-list|rev-parse|revert|rm|shortlog|show|show-ref|sparse-checkout|stash|status|submodule|switch|symbolic-ref|tag|update-index|update-ref|var|verify-commit|version|whatchanged|worktree|write-tree)$/
}

# Whether x is a git global option whose value is the next word. The push
# rule and the inline-code check both read the git options through this one
# list; the second pass of the push rule reads it with --attr-source set
# aside.
function gitvalue(x) {
    return x ~ /^(-C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--config-env|--attr-source)$/
}

function esc(c) {
    if (c ~ /[.[*+?(){}|$]/) return "[" c "]"
    if (c == "\\") return "[\\\\]"
    if (c == "^") return "\\^"
    return c
}

# The glob in word w (mask mk) as an anchored regular expression matching at
# least what the glob could match. Sets gglob to 1 when w holds an active
# glob at all; a word without one is a plain word. Forms read: * ? [...]
# (read as any one character, POSIX classes in it included), zsh groups
# with | (an empty branch read as .?), and the extendedglob forms x# (read
# as .*), ^ negation (read as anything up to the next / ) or |),
# a~b (read as a) and (#...) flags (read as anything).
function gre(w, mk,   L, j, c, out, d, e, cl, k, kd) {
    L = length(w); out = ""; d = 0; gglob = 0
    for (j = 1; j <= L; j++) {
        c = substr(w, j, 1)
        if (substr(mk, j, 1) != "a") { out = out esc(c); continue }
        if (c == "*") { out = out ".*"; gglob = 1 }
        else if (c == "?") { out = out "."; gglob = 1 }
        else if (c == "#") { out = out ".*"; gglob = 1 }
        else if (c == "[") {
            e = j + 1
            if (substr(w, e, 1) == "!" || substr(w, e, 1) == "^") e++
            if (substr(w, e, 1) == "]") e++
            # A class [:alpha:], an equivalence class [=a=] or a collating
            # symbol [.a.] inside the brackets is passed over whole.
            while (e <= L && substr(w, e, 1) != "]") {
                cl = substr(w, e + 1, 1)
                if (substr(w, e, 1) == "[" && (cl == ":" || cl == "=" || cl == ".") && (k = index(substr(w, e + 2), cl "]")) > 0) e += k + 3
                else e++
            }
            if (e > L) { out = out esc(c); continue }
            # Any one character: wider than the set, and never a malformed
            # expression.
            out = out "."; gglob = 1; j = e
        }
        else if (c == "(") {
            if (substr(w, j + 1, 1) == "#") { gglob = 1; return "^.*$" }
            out = out "("; d++; gglob = 1
        }
        else if (c == ")" && d > 0) { if (out ~ /[(|]$/) out = out ".?"; out = out ")"; d-- }
        else if (c == "|" && d > 0) { if (out ~ /[(|]$/) out = out ".?"; out = out "|" }
        else if (c == "^" && (j == 1 || substr(w, j - 1, 1) ~ /[\/(|]/)) {
            out = out ".*"; gglob = 1; kd = 0
            for (k = j + 1; k <= L; k++) {
                if (substr(w, k, 1) == "/" && kd == 0) break
                if (substr(mk, k, 1) != "a") continue
                if (substr(w, k, 1) == "(") kd++
                else if (substr(w, k, 1) == ")") { if (kd == 0) break; kd-- }
                else if (substr(w, k, 1) == "|" && kd == 0) break
            }
            j = k - 1
        }
        else if (c == "~" && j > 1) { gglob = 1; break }
        else out = out esc(c)
    }
    for (; d > 0; d--) { if (out ~ /[(|]$/) out = out ".?"; out = out ")" }
    return "^" out "$"
}

# Whether word k of segment s is a glob pattern (never under noglob, nor on
# the strict path a command name that is an expansion takes).
function isglob(s, k) {
    if (strict || noglob || !index(segm[s, k], "a")) return 0
    gre(segw[s, k], segm[s, k])
    return gglob
}

# Whether word k of segment s can be the word lt: 1 when it is, 2 when it
# could be (a glob that could match it, or a word filled in at run time), 0
# when it cannot. On the strict path only the word itself counts.
function kw(s, k, lt,   re) {
    if (segx[s, k]) return strict ? 0 : 2
    if (segw[s, k] == lt) return 1
    if (strict || noglob || !index(segm[s, k], "a")) return 0
    re = gre(segw[s, k], segm[s, k])
    return (gglob && lt ~ re) ? 2 : 0
}

# Words i1 and i2 (each at most m) can be l1 and l2; sets guessed when
# either only could be.
function pair(s, i1, l1, i2, l2, m,   r1, r2) {
    if (i1 > m || i2 > m) return 0
    if (!(r1 = kw(s, i1, l1))) return 0
    if (!(r2 = kw(s, i2, l2))) return 0
    if (r1 == 2 || r2 == 2) guessed = 1
    return 1
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
    if (undispatched_release_dispatch == "allow" && rrelease) return
    if (rank[d] > rank[today]) { today = d; todayr = r }
}

# The positions of the two subcommand words of a gh command in segw[s, a..m],
# read as gh reads them: flags before either word are skipped, and so is the
# value of -R or --repo given as its own word, so gh pr -R o/r merge is a
# merge. Sets g1 and g2, each m + 1 when there is no such word.
function ghsub(s, a, m,   k, found) {
    g1 = m + 1; g2 = m + 1; found = 0
    for (k = a; k <= m; k++) {
        if (segw[s, k] ~ /^(-R|--repo)$/) { k++; continue }
        if (segw[s, k] ~ /^-/) continue
        if (++found == 1) g1 = k
        else { g2 = k; return }
    }
}

# The method of a gh api call whose arguments are segw[s, a..m]: the last
# -X or --method in any spelling (-X GET, -XGET, --method GET,
# --method=GET), upper-cased, or "" when none is given. Only an explicit GET
# makes an endpoint a read; with no method flag gh may send a write.
# Sets methold to 1 when the hook before this reading would also have taken
# the last method for a GET: the value in its own word in any case, or
# attached as exactly -XGET or --method=GET. The merge endpoint rule needs
# both, so a lowercase -Xget, which that hook denied, is never allowed now.
# The value of another flag that takes one (-q -XGET) is not a method.
function ghmethod(s, a, m,   k, x, meth) {
    meth = ""; methold = 0
    for (k = a; k <= m; k++) {
        x = segw[s, k]
        if (x ~ /^(-f|-F|--raw-field|--field|--input|-H|--header|-q|--jq|-t|--template|--cache|-p|--preview|--hostname)$/) k++
        else if (x ~ /^(-X|--method)$/) { meth = (k < m) ? segw[s, k + 1] : ""; methold = 1; k++ }
        else if (x ~ /^--method=/) { meth = substr(x, 10); methold = (meth == "GET") }
        else if (x ~ /^-X/) { meth = substr(x, 3); methold = (meth == "GET") }
    }
    return toupper(meth)
}

# A workflow selector that names a release workflow: the workflow every repo
# in this workspace calls the shirabe reusable release workflow from. A repo
# that names its release workflow otherwise adds the name here.
function release_name(w) {
    w = tolower(w)
    return w == "prepare-release.yml" || w == "prepare-release.yaml" ||
        w == "release-prepare.yml" || w == "release-prepare.yaml" ||
        w == "prepare release"
}

# A workflow selector this hook cannot read: digits only (a workflow id), an
# expansion, or a character bash would expand or GitHub would decode before
# matching it (a glob, a brace, a tilde, a backslash, a percent sign, a slash).
function unreadable(w, dyn,   cs, k) {
    if (dyn || w ~ /\$/ || w ~ /^[0-9]+$/) return 1
    cs = "*?[]{}~\\%/"
    for (k = 1; k <= length(cs); k++) if (index(w, substr(cs, k, 1))) return 1
    return 0
}

# Sets rd, rr and ra for a dispatch of the workflow named by selector w, and
# rrelease to 1 when it is a release workflow dispatch.
function dispatch(w, dyn) {
    if (unreadable(w, dyn)) { rd = "ask"; rr = "workflow dispatch whose workflow can\047t be read"; ra = ""; rrelease = 0 }
    else if (release_name(w)) { rd = "ask"; rr = "release workflow dispatch"; ra = "cut-release"; rrelease = 1 }
}

# Rules for command head h whose arguments are segw[s, a..m].
# Sets rd, rr and ra (the authority a grant would need, or ""), and rrelease
# for a release workflow dispatch; returns 1 on a match.
function rules(s, h, a, m,   x, k, meth, t, n, w, wd, merge, ep, writes, lx, r, mp, pat, pass) {
    rd = ""; rr = ""; ra = ""; rrelease = 0
    if (h ~ /^(curl|wget|nc|ncat|netcat)$/) { rd = "deny"; rr = h; return 1 }
    if (h == "gh") {
        # Each subcommand word is compared through kw(): a glob that could
        # be the word, or a word given at run time, counts (and sets
        # guessed).
        ghsub(s, a, m)
        if (pair(s, g1, "pr", g2, "merge", m))        { rd = "deny"; rr = "gh pr merge"; ra = "merge-pr" }
        else if (pair(s, g1, "repo", g2, "delete", m)) { rd = "deny"; rr = "gh repo delete" }
        else if (pair(s, g1, "auth", g2, "switch", m)) { rd = "ask";  rr = "gh auth switch" }
        else if (pair(s, g1, "release", g2, "create", m)) { rd = "ask"; rr = "gh release create"; ra = "cut-release" }
        else if (pair(s, g1, "issue", g2, "close", m)) { rd = "ask";  rr = "gh issue close"; ra = "close-issue" }
        else if (pair(s, g1, "workflow", g2, "run", m)) {
            # The selector is the one word left after the flags and the
            # values of the flags that take one; none, or two or more, can
            # not be read, nor can a glob or a word given at run time.
            n = 0
            for (k = g2 + 1; k <= m; k++) {
                x = segw[s, k]
                if (x ~ /^(-r|--ref|-R|--repo|-f|--raw-field|-F|--field)$/) { k++; continue }
                if (x ~ /^-/) continue
                n++; w = x; wd = segd[s, k] || (!strict && segx[s, k]) || isglob(s, k)
            }
            if (n != 1) { rd = "ask"; rr = "workflow dispatch whose workflow can\047t be read" }
            else dispatch(w, wd)
        }
        else if (g1 <= m && (r = kw(s, g1, "api"))) {
            if (r == 2) guessed = 1
            meth = ghmethod(s, g1 + 1, m)
            merge = ""
            for (k = g1 + 1; k <= m; k++) {
                x = segw[s, k]
                if (x ~ /mergePullRequest|enablePullRequestAutoMerge/) merge = "gh api merge mutation"
                else if (!(meth == "GET" && methold) && x ~ /pulls\/[^\/]+\/merge([\/?]|$)/) merge = "gh api pull request merge endpoint"
                else if (meth != "GET" && !(rd == "ask" && ra == "") && tolower(x) ~ /workflows.*dispatches/) {
                    lx = tolower(x)
                    # Whatever comes before it (repos/o/r, {owner}, an
                    # expansion, a host), the selector is the one segment
                    # between actions/workflows/ and /dispatches; it is
                    # compared in any case, as GitHub matches the path. A
                    # path naming both in any other shape (./, ../, extra
                    # segments) can not be read.
                    if (match(lx, /(^|\/)actions\/workflows\/[^\/]+\/dispatches([\/?#]|$)/)) {
                        w = substr(lx, RSTART, RLENGTH)
                        sub(/.*actions\/workflows\//, "", w)
                        sub(/\/dispatches.*/, "", w)
                        # Only an expansion in the selector itself, which
                        # leaves a $ in it, hides the workflow.
                        dispatch(w, 0)
                    } else dispatch("", 1)
                }
            }
            if (merge != "" && rd != "") {
                # A merge and a dispatch in one call: gh takes one endpoint,
                # so this can not be read, and the merge keeps it denied.
                rd = "deny"; rr = "gh api names a merge and a workflow dispatch"; ra = ""
            } else if (merge != "") {
                rd = "deny"; rr = merge; ra = "merge-pr"
            } else if (rd == "" && meth != "GET") {
                # An endpoint that is wholly an expansion can not be read: a
                # call that may write through it asks.
                writes = 0; ep = 0
                for (k = g1 + 1; k <= m; k++) {
                    x = segw[s, k]
                    if (x ~ /^(-f|-F|--raw-field|--field|--input)$/ || x ~ /^(-[fF].|--raw-field=|--field=|--input=)/) writes = 1
                    if (x ~ /^(-X|--method|-f|-F|--raw-field|--field|--input|-H|--header|-q|--jq|-t|--template|--cache|-p|--preview|--hostname)$/) { k++; continue }
                    if (x ~ /^-/) continue
                    if (!ep) ep = k
                }
                if (ep && segd[s, ep] && segw[s, ep] ~ /^\$(\{[^}]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9@*]|\(\.\.\.\))$/ && (meth != "" || writes)) {
                    rd = "ask"; rr = "gh api write to an endpoint that can\047t be read"
                }
                # A call that may write, one of whose words is a glob or a
                # word given at run time, could name any endpoint.
                pat = 0
                for (k = g1 + 1; k <= m; k++) if ((!strict && segx[s, k]) || isglob(s, k)) pat = 1
                if (rd == "" && pat && (meth != "" || writes)) {
                    rd = "ask"; rr = "gh api write whose arguments hold a glob or a word given at run time"
                }
            }
        }
        return rd != ""
    }
    if (h == "niwa") {
        # The widened reading runs only for a command name that is literally
        # niwa. A non-literal name reaches this branch as a strict trial, and
        # an ordinary script run through a variable must not read as a reap.
        if (!strict) {
            # A flag takes zero or one values, so reap can only be the
            # subcommand in place of a flag or just after one. The first plain
            # word no flag could own is the subcommand, and that word is not
            # reap; its arguments run no reap. --no-progress takes no value.
            # x: the word before was a flag that may take one.
            x = 0
            for (k = a; k <= m; k++) {
                if (segw[s, k] == "reap") { rd = "deny"; rr = "niwa reap"; return 1 }
                if (segd[s, k] || segw[s, k] ~ /[{}*?[(]|[@?*+!]$/) { guessed = 1; rd = "deny"; rr = "niwa reap"; return 1 }
                if (segw[s, k] == "--no-progress") x = 0
                else if (segw[s, k] ~ /^-/) x = 1
                else if (x) x = 0
                else break
            }
            # No subcommand word at all: what follows may supply it.
            for (k = a; k <= m; k++) if (segw[s, k] !~ /^-/) break
            if (k > m && src ~ /niwa[ \t]+[^;&|\n]*reap/) { rd = "deny"; rr = "niwa reap"; return 1 }
        }
        for (k = a; k <= m; k++) if (segw[s, k] !~ /^-/) break
        if (k <= m && (r = kw(s, k, "reap"))) {
            if (r == 2) guessed = 1
            rd = "deny"; rr = "niwa reap"; return 1
        }
        return 0
    }
    if (h == "git") {
        # Two passes over the options, asking if either finds a force push.
        # Real git takes a value after --attr-source, which the first pass
        # skips as the value of that option; the second reads the word after
        # it as the subcommand, as the hook did before that option joined
        # the gitvalue() list. It over-asks on purpose, so a line the
        # earlier reading caught stays caught.
        for (pass = 0; pass < 2; pass++) {
            for (k = a; k <= m; k++) {
                x = segw[s, k]
                if (gitvalue(x) && (pass == 0 || x != "--attr-source")) k++
                else if (x !~ /^-/) break
            }
            if (k > m || !(r = kw(s, k, "push"))) continue
            for (k++; k <= m; k++) {
                x = segw[s, k]
                if (x ~ /^--force/ || x ~ /^-[A-Za-z]*f[A-Za-z]*$/ || x ~ /^\+/) {
                    if (r == 2) guessed = 1
                    rd = "ask"; rr = "git push --force"; return 1
                }
                # A pattern that could be a force flag or a +refspec, or
                # starts with a glob (so could be any name on disk). A word
                # filled in at run time (by xargs or find) does not count, as
                # a $VAR word does not: only a force the line spells out asks.
                if (isglob(s, k) && (substr(segm[s, k], 1, 1) == "a" && x ~ /^[*?[(^#]/ ||
                    x ~ /^-[^-]/ || "-f" ~ gre(x, segm[s, k]) || "--force" ~ gre(x, segm[s, k]) ||
                    "--force-with-lease" ~ gre(x, segm[s, k]))) {
                    guessed = 1
                    rd = "ask"; rr = "git push --force"; return 1
                }
            }
        }
        return 0
    }
    if (h == "unset") {
        mp = 0
        for (k = a; k <= m; k++) {
            x = segw[s, k]
            if (x == "-m") { mp = 1; continue }
            if (x ~ /^GH_TOKEN/) { rd = "ask"; rr = "unset GH_TOKEN"; return 1 }
            # zsh unset -m takes patterns, quoted or not.
            if ((!strict && segx[s, k]) || (mp && "GH_TOKEN" ~ gre(x, rep("a", length(x)))) ||
                (isglob(s, k) && "GH_TOKEN" ~ gre(x, segm[s, k]))) {
                guessed = 1
                rd = "ask"; rr = "unset GH_TOKEN"; return 1
            }
        }
        return 0
    }
    if (h ~ /^(bash|sh|zsh|dash|ksh|mksh|fish|csh|tcsh|pwsh|eval)$/) {
        t = body[s]
        for (k = a; k <= m; k++) t = t " " segw[s, k]
        if (h != "eval" && body[s] == "" && readsin(s, a, m)) t = t " " src   # reads the script from a pipe
        if (mentions(t)) { rd = "ask"; rr = "text handed to " h " mentions a gated command"; return 1 }
        return 0
    }
    return interp(s, h, a, m)
}

# Whether a shell given the words segw[s, a..m] reads its script from
# standard input: no -c, and either -s (its words are then arguments) or no
# script file among its words. The values of -o and -O (or +o, +O),
# --rcfile and --init-file are not a script file.
function readsin(s, a, m,   k, x, sf) {
    sf = 0
    for (k = a; k <= m; k++) {
        x = segw[s, k]
        if (x == "--" || x == "-") return sf || k == m
        if (x ~ /^--/) { if (x ~ /^--(rcfile|init-file)$/) k++; continue }
        if (x !~ /^[-+]/) return sf
        if (x ~ /^-[A-Za-z]*c/) return 0
        if (x ~ /^-[A-Za-z]*s/) sf = 1
        if (x ~ /^[-+][A-Za-z]*[oO]$/) k++
    }
    return 1
}

# Inline code handed to an interpreter: the code after its inline flag (the
# rest of the words are taken with it), or, given no inline flag and no
# script, what it reads from a heredoc, here-string or pipe. A script file
# is not read. Asks when the code mentions a gated command, plain or with
# its punctuation set aside; awk only when the program also runs a command.
function interp(s, h, a, m,   f, k, x, t, inl, pos, fileprog) {
    if (h ~ /^(python[0-9.]*|pypy[0-9.]*)$/) f = "py"
    else if (h ~ /^(perl[0-9.]*|ruby[0-9.]*)$/) f = "pe"
    else if (h ~ /^(node|nodejs|bun)$/) f = "js"
    else if (h == "deno") f = "deno"
    else if (h == "osascript") f = "osa"
    else if (h ~ /^php[0-9.]*$/) f = "php"
    else if (h ~ /^(lua[0-9.]*|luajit|Rscript)$/) f = "lua"
    else if (h ~ /^(awk|gawk|mawk|nawk)$/) f = "awk"
    else return 0
    inl = 0; pos = 0; fileprog = 0; t = ""
    for (k = a; k <= m; k++) {
        x = segw[s, k]
        t = t " " x
        if (f == "py" && x ~ /^-[A-Za-z]*c/) inl = 1
        else if (f == "pe" && x ~ /^-[A-Za-z0-9]*[eE]/) inl = 1
        else if (f == "js" && x ~ /^(-[A-Za-z]*[ep]|--eval|--print)/) inl = 1
        else if (f == "deno" && k == a && x == "eval") inl = 1
        else if (f == "osa" && x == "-e") inl = 1
        else if (f == "php" && x ~ /^-[A-Za-z]*r/) inl = 1
        else if (f == "lua" && x == "-e") inl = 1
        else if (f == "awk" && x ~ /^(-f|--file)/) fileprog = 1
        else if ((f == "py" && x ~ /^-[WX]$/) || (f == "js" && x ~ /^(-r|--require|--import|--loader)$/) ||
            (f == "awk" && x ~ /^-[Fv]$/)) { k++; if (k <= m) t = t " " segw[s, k] }
        else if (x !~ /^-/) pos = 1
    }
    if (f == "awk") {
        if (fileprog || !pos) return 0
        if (t !~ /system|getline|\|/) return 0
    } else if (!inl) {
        if (pos) return 0
        t = (body[s] != "") ? body[s] : src
    }
    # Three readings side by side, any one of which asks: the strict walk,
    # the wide reading, and the denied-pair reading.
    if (imentions(t) || wmentions(t) || comention(loosen(t))) {
        rd = "ask"; rr = "inline code handed to " h " mentions a gated command"; return 1
    }
    return 0
}

# A copy of words a..m of segment s as a segment of its own, for a command
# a wrapper runs; its name is never a number, so END does not read it again.
function synth(s, a, m,   ns, k, n) {
    ns = "x" (++nsyn); n = 0
    for (k = a; k <= m; k++) {
        n++
        segw[ns, n] = segw[s, k]; segd[ns, n] = segd[s, k]
        segm[ns, n] = segm[s, k]; segx[ns, n] = segx[s, k]
    }
    segn[ns] = n; body[ns] = body[s]
    return ns
}

# Reads the short option cluster x (-abc) of a command whose letters in sv
# take a value, as getopt does: sets ovl to the first such letter in x (""
# when none) and ova to the rest of x after it, which is its value when not
# empty. Returns 1 when the value is the next word instead.
function cluster(x, sv,   j, c) {
    ovl = ""; ova = ""
    for (j = 2; j <= length(x); j++) {
        c = substr(x, j, 1)
        if (index(sv, c)) { ovl = c; ova = substr(x, j + 1); return ova == "" }
    }
    return 0
}

# The first word from k on in segment s that is not an option of a wrapper,
# or m + 1. Short options come in clusters, the letters in sv taking a value
# (cluster() above); a long option matching lv takes the next word unless
# it is written with =; -- ends the options.
function optskip(s, k, m, sv, lv,   x) {
    for (; k <= m; k++) {
        x = segw[s, k]
        if (x == "--") return k + 1
        if (x !~ /^-/) return k
        if (x ~ /^--/) { if (lv != "" && x !~ /=/ && x ~ lv) k++; continue }
        if (cluster(x, sv)) k++
    }
    return k
}

# Adds a word filled in at run time to the end of segment ns.
function runword(ns,   n) {
    n = ++segn[ns]
    segw[ns, n] = ""; segd[ns, n] = 0; segm[ns, n] = ""; segx[ns, n] = 1
}

# The command name in word k of segment s: its last path part, less a
# leading = (zsh replaces =name with the path of the program). Sets hm to its
# mask.
function headname(s, k,   x, mk) {
    x = segw[s, k]; mk = segm[s, k]
    if (substr(x, 1, 1) == "=" && substr(mk, 1, 1) == "a") { x = substr(x, 2); mk = substr(mk, 2) }
    if (match(x, /.*\//)) { x = substr(x, RLENGTH + 1); mk = substr(mk, RLENGTH + 1) }
    hm = mk
    return x
}

function evalseg(s,   m, k) {
    noglob = 0
    m = segn[s]
    # A zsh glob qualifier can run code: a glob group whose text mentions a
    # gated command asks.
    for (k = 1; k <= m; k++)
        if (actin(segw[s, k], segm[s, k], "(") && mentions(segw[s, k]))
            verdict("ask", "glob pattern mentions a gated command")
    evalcmd(s, 1, m)
}

# Whether w (mask mk) holds an active character c.
function actin(w, mk, c,   j) {
    for (j = index(w, c); j > 0 && j <= length(w); j++)
        if (substr(w, j, 1) == c && substr(mk, j, 1) == "a") return 1
    return 0
}

# Text a wrapper hands to a shell.
function shelltext(name, t) {
    if (mentions(t)) verdict("ask", "text handed to " name " mentions a gated command")
}

# Reads the command in words k..m of segment s.
function evalcmd(s, k, m,   x, h, g, j, e, t, ns, n, rs, ng, ph, c, v, sp) {
    while (k <= m) {
        if (segx[s, k]) break
        x = segw[s, k]
        if (x ~ /^(!|\{|\}|if|then|else|elif|fi|do|done|while|until|coproc)$/) { k++; continue }
        if (x ~ /^(for|select|case|\[\[|\[|test)$/) return
        if (x == "function" || x == "repeat") { k += 2; continue }
        if (x ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) { k++; continue }
        h = headname(s, k)
        # Each wrapper skips its options through optskip(), the letters and
        # long options given to it taking a value.
        if (h ~ /^(command|builtin|exec|nohup|setsid|nocorrect|-)$/) {
            # command -v or -V only looks the name up, as type does.
            if (h == "command")
                for (j = k + 1; j <= m && segw[s, j] ~ /^-./ && segw[s, j] != "--"; j++)
                    if (segw[s, j] ~ /^-[A-Za-z]*[vV]/) return
            k = optskip(s, k + 1, m, "a", "")
            continue
        }
        if (h == "noglob") { noglob = 1; k++; continue }
        if (h == "stdbuf") { k = optskip(s, k + 1, m, "ioe", "^--(input|output|error)$"); continue }
        if (h == "env") {
            for (k++; k <= m && (segw[s, k] ~ /^-/ || segw[s, k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/); k++) {
                x = segw[s, k]
                if (x !~ /^-/ || x == "--") continue
                sp = 0
                if (x ~ /^--split-string=/) { t = substr(x, 16); sp = 1 }
                else if (x == "--split-string") { t = (k < m) ? segw[s, k + 1] : ""; k++; sp = 1 }
                else if (x ~ /^--/) { if (x ~ /^--(unset|chdir)$/) k++ }
                else if (cluster(x, "uCPLUS")) {
                    if (ovl == "S") { t = (k < m) ? segw[s, k + 1] : ""; sp = 1 }
                    k++
                }
                else if (ovl == "S") { t = ova; sp = 1 }
                if (sp) {
                    # The value is split at blanks into the command and its
                    # first words; the words after it follow. Unlike synth(),
                    # the split words are new: each is taken literally (env
                    # does its own quoting in the value, not modeled here), so
                    # none is a glob or a brace, and only a $ marks one an
                    # expansion.
                    ns = "x" (++nsyn); n = 0
                    while (match(t, /[^ \t\n]+/)) {
                        n++
                        segw[ns, n] = substr(t, RSTART, RLENGTH); segd[ns, n] = (segw[ns, n] ~ /\$/)
                        segm[ns, n] = rep("l", RLENGTH); segx[ns, n] = 0
                        t = substr(t, RSTART + RLENGTH)
                    }
                    for (k++; k <= m; k++) {
                        n++
                        segw[ns, n] = segw[s, k]; segd[ns, n] = segd[s, k]
                        segm[ns, n] = segm[s, k]; segx[ns, n] = segx[s, k]
                    }
                    segn[ns] = n; body[ns] = body[s]
                    evalcmd(ns, 1, n)
                    return
                }
            }
            continue
        }
        if (h == "sudo") {
            k = optskip(s, k + 1, m, "ugCDhprtUTR",
                "^--(user|group|close-from|chdir|host|prompt|role|type|other-user|command-timeout|chroot)$")
            continue
        }
        if (h == "doas") { k = optskip(s, k + 1, m, "auC", ""); continue }
        if (h == "nice") { k = optskip(s, k + 1, m, "n", "^--adjustment$"); continue }
        if (h == "timeout" || h == "gtimeout") {
            # The duration follows the options.
            k = optskip(s, k + 1, m, "sk", "^--(signal|kill-after)$") + 1
            continue
        }
        if (h == "time") { k = optskip(s, k + 1, m, "of", "^--(output|format)$"); continue }
        if (h == "caffeinate") { k = optskip(s, k + 1, m, "tw", ""); continue }
        if (h == "arch") {
            for (k++; k <= m && segw[s, k] ~ /^-/; k++) if (segw[s, k] ~ /^(-arch|-e|-d)$/) k++
            continue
        }
        if (h == "script") {
            # -c (Linux) hands its value to a shell; otherwise the words
            # after the flags are the typescript file, then the command
            # (macOS).
            for (k++; k <= m && segw[s, k] ~ /^-/; k++) {
                x = segw[s, k]
                if (x ~ /^-[A-Za-z]*c$/ || x == "--command") { shelltext("script", (k < m) ? segw[s, k + 1] : ""); return }
                if (x ~ /^--command=/) { shelltext("script", substr(x, 11)); return }
                if (x ~ /^-[tTIOBEo]$/ || x ~ /^--(log-in|log-out|log-io|log-timing|echo|output-limit|logging-format)$/) k++
            }
            k++
            continue
        }
        if (h == "watch") {
            # The words after the flags are joined and handed to sh -c.
            k = optskip(s, k + 1, m, "nq", "^--(interval|equexit)$")
            t = ""
            for (j = k; j <= m; j++) t = t " " segw[s, j]
            shelltext("watch", t)
            continue
        }
        if (h == "xargs") {
            # Options as optskip() reads them, but -I and -J (and -i, whose
            # value can only be attached) set the replace string, and GNU -e
            # and -l, and --eof, --max-lines and --replace, take a value only
            # attached.
            rs = ""
            for (k++; k <= m && segw[s, k] ~ /^-/; k++) {
                x = segw[s, k]
                if (x == "--") { k++; break }
                if (x ~ /^--/) {
                    if (x ~ /^--replace=/) rs = substr(x, 11)
                    else if (x == "--replace") rs = "{}"
                    else if (x ~ /^--(arg-file|delimiter|max-args|max-procs|max-chars|process-slot-var)$/) k++
                    continue
                }
                for (j = 2; j <= length(x); j++) {
                    c = substr(x, j, 1); v = substr(x, j + 1)
                    if (index("IJaEdLnPsRS", c)) {
                        if (v == "") { v = (k < m) ? segw[s, k + 1] : ""; k++ }
                        if (c == "I" || c == "J") rs = v
                        break
                    }
                    if (c == "i") { rs = (v == "") ? "{}" : v; break }
                    if (c == "e" || c == "l") break
                }
            }
            if (k > m) return
            # Read from input at run time: words holding the replace string,
            # or, without one, words appended to the command.
            ns = synth(s, k, m)
            if (rs != "") { for (j = 1; j <= segn[ns]; j++) if (index(segw[ns, j], rs)) segx[ns, j] = 1 }
            else { runword(ns); runword(ns) }
            evalcmd(ns, 1, segn[ns])
            return
        }
        break
    }
    if (k > m) return
    x = segw[s, k]
    h = headname(s, k)
    if (segx[s, k] || (segd[s, k] && x ~ /\$/)) {
        # The command name is an expansion: ask if a gated command would fit.
        # No grant and no exemption reaches a command the scanner cannot read.
        split("gh niwa git", g, " ")
        # Strict: globs and run-time words count for nothing here, since the
        # reading PR #66 reverted asked on ordinary lines run through a path
        # held in a variable.
        strict = 1
        for (j = 1; j <= 3; j++)
            if (rules(s, g[j], k + 1, m)) { strict = 0; verdict("ask", "command name is not literal; would be " rr); return }
        strict = 0
        return
    }
    if (h == "find" || h == "fd" || h == "fdfind") {
        # The -exec, -execdir, -ok and -okdir actions of find run the words up to ; or +,
        # with {} filled in. The -x and -X of fd run the rest, up to ;, with its
        # placeholders filled in, or the path appended when there is none.
        for (j = k + 1; j <= m; j++) {
            if (h == "find" && segw[s, j] !~ /^-(exec|execdir|ok|okdir)$/) continue
            if (h != "find" && segw[s, j] !~ /^(-x|--exec|-X|--exec-batch)$/) continue
            for (e = j + 1; e <= m && segw[s, e] != ";" && (h != "find" || segw[s, e] != "+"); e++) { }
            ns = synth(s, j + 1, e - 1); ph = 0
            for (n = 1; n <= segn[ns]; n++)
                if (segw[ns, n] ~ /[{](\/|\/\/|\.|\/\.)?[}]/) { segx[ns, n] = 1; ph = 1 }
            if (h != "find" && !ph) runword(ns)
            ng = noglob; evalcmd(ns, 1, segn[ns]); noglob = ng
            j = e
        }
        return
    }
    if (!noglob && index(hm, "a")) {
        gre(h, hm)
        if (gglob) { globhead(s, k, m, gre(h, hm)); return }
    }
    guessed = 0
    if (rules(s, h, k + 1, m)) {
        # A match through a pattern or a run-time word goes through verdict(),
        # so it never takes a grant or the exemption.
        if (guessed) verdict(rd, rr ", by a glob or a word given at run time")
        else if (ra != "") gated(rd, rr, ra)
        else verdict(rd, rr)
    }
}

# A command name that is a glob pattern: it counts as each gated command,
# shell or interpreter it could be. One such command gets its verdict;
# several are at most asked. A wrapper it could be asks when the words after
# it mention a gated command.
function globhead(s, k, m, re,   c, nc, j, t, nm, d, r) {
    nc = split("curl wget nc ncat netcat gh niwa git unset bash sh zsh dash ksh mksh fish csh tcsh pwsh eval python python3 pypy3 perl ruby node nodejs bun deno osascript php lua luajit Rscript awk gawk mawk nawk", c, " ")
    nm = 0; d = ""; r = ""
    for (j = 1; j <= nc; j++) {
        if (c[j] !~ re) continue
        nm++
        if (rules(s, c[j], k + 1, m) && rank[rd] > rank[d]) { d = rd; r = rr }
    }
    if (d != "") verdict((nm == 1) ? d : "ask", "command name is a glob pattern; could be " r)
    nc = split("command builtin exec nohup setsid nocorrect noglob stdbuf env sudo doas nice timeout gtimeout time caffeinate arch script watch xargs find fd", c, " ")
    for (j = 1; j <= nc; j++) {
        if (c[j] !~ re) continue
        t = ""
        for (k++; k <= m; k++) t = t " " segw[s, k]
        if (mentions(t)) verdict("ask", "command name is a glob pattern; could be " c[j] " running a gated command")
        return
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
    if (braceover && mentions(src))
        verdict("ask", "brace expansion too large to read, around a gated command")
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

# A tab is IFS whitespace, so read would merge an empty field into the next;
# END prints a placeholder ("-", or "allow" for a verdict) instead of an
# empty field. An empty NEEDS therefore means awk printed nothing at all.
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

# ---------------------------------------------------------------- scratch reap

# physical DIR: prints DIR with every symlink resolved, or fails, as it does
# for a resolved path holding a control character. The x keeps command
# substitution from stripping a trailing newline that is part of the path.
physical() {
    local p
    [ -n "$1" ] || return 1
    p=$(CDPATH= cd -P -- "$1" >/dev/null 2>&1 && pwd -P && printf x) || return 1
    p=${p%$'\n'x}
    case "$p" in *[[:cntrl:]]*) return 1 ;; esac
    printf '%s\n' "$p"
}

# within A B: succeeds when A is B or lies under it, compared by file
# identity. A path that can't be resolved counts as within, so the caller
# refuses.
within() {
    local a
    a=$(physical "$1") || return 0
    while :; do
        [ "${a:-/}" -ef "$2" ] && return 0
        [ -n "$a" ] || return 1
        a=${a%/*}
    done
}

# own_of DIR: prints the outermost directory at or above DIR, walking DIR as
# written, that holds a workspace config or an instance record, or fails.
own_of() {
    local d=$1 own=
    while :; do
        if [ -e "$d/.niwa/workspace.toml" ] || [ -e "$d/.niwa/instance.json" ] ||
            [ -e "$d/.niwa.prev/workspace.toml" ]; then
            own=${d:-/}
        fi
        [ -n "$d" ] || break
        d=${d%/*}
    done
    [ -n "$own" ] || return 1
    printf '%s\n' "$own"
}

# scratch_own_clear PATH: PATH is neither in this hook's own workspace nor
# holds it, with the workspace found from this script both as written and
# resolved. Finding none either way means no allowance.
scratch_own_clear() {
    local d o found=
    case "$0" in /*) ;; *) return 1 ;; esac
    case "$0" in *//* | */./* | */../* | *[[:cntrl:]]*) return 1 ;; esac
    for d in "${0%/*}" "$(physical "${0%/*}")"; do
        [ -n "$d" ] || continue
        o=$(own_of "$d") || continue
        found=1
        within "$1" "$o" && return 1
        within "$o" "$1" && return 1
    done
    [ -n "$found" ]
}

# scratch_guard_prov ROOT: ROOT's config is not a snapshot taken from a source.
# niwa init --from and apply leave .niwa/.niwa-snapshot.toml; bare niwa init
# writes none. Any file type counts, a symlink included.
scratch_guard_prov() {
    [ ! -e "$1/.niwa/.niwa-snapshot.toml" ] && [ ! -L "$1/.niwa/.niwa-snapshot.toml" ]
}

# scratch_none PATTERN...: no path matches any PATTERN, where * also matches
# a name that starts with a dot (a repo named .github, say), which a plain
# glob skips. Any file type counts, a symlink included. dotglob is restored
# as it was.
scratch_none() {
    local g had=0 r=0
    shopt -q dotglob && had=1
    shopt -s dotglob
    for g in "$@"; do
        if [ -e "$g" ] || [ -L "$g" ]; then r=1; break; fi
    done
    [ "$had" = 1 ] || shopt -u dotglob
    return "$r"
}

# scratch_guard_repo ROOT: ROOT holds no .git where niwa clones repos, at
# <root>/<instance>/<group>/<repo>, or one level up for a root that is its own
# instance. Any file type counts, a symlink included, and so does a name that
# starts with a dot.
scratch_guard_repo() {
    scratch_none "$1"/*/*/.git "$1"/*/*/*/.git
}

# scratch_guard_path ROOT: after the cd, nothing at ROOT can stand in for niwa:
# ROOT holds no entry named niwa, and this hook's own PATH has no empty or
# relative entry. The session's shell may carry another PATH; this is only
# the one the hook was given.
scratch_guard_path() {
    [ ! -e "$1/niwa" ] && [ ! -L "$1/niwa" ] || return 1
    case ":${PATH-}:" in *::* | *:[!/]*) return 1 ;; esac
    return 0
}

# scratch_guard_legacy ROOT: ROOT's .niwa is not a git working tree of a config
# source, the legacy shape niwa converts on apply. Any file type counts.
scratch_guard_legacy() {
    [ ! -e "$1/.niwa/.git" ] && [ ! -L "$1/.niwa/.git" ]
}

# scratch_guard_hook ROOT: ROOT carries no installed copy of this hook: none
# in its config's hooks, at its root, or at an instance's root, where niwa
# installs gate-online.sh (and gate-online.local.sh in each repo, which the
# repo check already refuses). A workspace this hook guards is not a scratch
# made for a check. Any file type counts, a symlink included, and so does an
# instance whose name starts with a dot.
scratch_guard_hook() {
    scratch_none "$1"/.niwa/hooks/pre_tool_use/gate-online*.sh \
        "$1"/.claude/hooks/pre_tool_use/gate-online*.sh \
        "$1"/*/.claude/hooks/pre_tool_use/gate-online*.sh
}

# scratch_target ROOT: ROOT, already its own resolved path, is a real
# workspace root, declared scratch, and not this workspace.
scratch_target() {
    [ "$1" != / ] || return 1
    [ -d "$1/.niwa" ] && [ ! -L "$1/.niwa" ] || return 1
    [ -f "$1/.niwa/workspace.toml" ] && [ ! -L "$1/.niwa/workspace.toml" ] || return 1
    scratch_declares "$1" || return 1
    scratch_guard_prov "$1" || return 1
    scratch_guard_repo "$1" || return 1
    scratch_guard_path "$1" || return 1
    scratch_guard_legacy "$1" || return 1
    scratch_guard_hook "$1" || return 1
    scratch_own_clear "$1"
}

# scratch_declares ROOT: .niwa/scratch-check is a regular file, not a symlink,
# whose first line is ROOT.
scratch_declares() {
    local line
    [ -f "$1/.niwa/scratch-check" ] && [ ! -L "$1/.niwa/scratch-check" ] || return 1
    IFS= read -r -n 4096 line < "$1/.niwa/scratch-check" || [ -n "$line" ] || return 1
    [ "$line" = "$1" ]
}

# scratch_literal_ok PATH: PATH came from the command text, in the safe
# character set. It has no . or .. component and is its own resolved path, so
# no symlink component and no other spelling of it, and it is the declared
# root. The payload's cwd plays no part.
scratch_literal_ok() {
    case "$1/" in *//* | */./* | */../*) return 1 ;; esac
    [ "$(physical "$1")" = "$1" ] || return 1
    scratch_target "$1"
}

# niwa reap as the whole command, with only the flags niwa takes there, after
# one cd to a literal absolute path that is the root of a workspace declared
# scratch: the reap deny is lifted. The path set holds no quote, expansion,
# glob or space.
SCRATCH_CD_FORM='^cd +(/[A-Za-z0-9._+/-]+) +&& +niwa( +--no-progress)? +reap( +(--no-progress|--help|-h))*$'
if [ "$TODAY" = deny ] && [ "$TODAY_WHY" = "niwa reap" ] && [ "$NEEDS" = "-" ]; then
    if [[ $COMMAND =~ $SCRATCH_CD_FORM ]]; then
        scratch_literal_ok "${BASH_REMATCH[1]}" && exit 0
    fi
fi

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
        # it gets what an instance off the exemption list gets, except that
        # a release is denied: a dispatched session releases only on its
        # grant, and this one's can't be read.
        case ",$NEEDS," in
            *,cut-release,*)
                if [ "$NONEX" != deny ]; then
                    NONEX=deny
                    NONEX_WHY="cut-release can't be confirmed"
                fi
                ;;
        esac
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

# handed_on AUTHORITY: the verdict for a held authority whose decision is
# handed on. For a merge or a close it is what an instance off the exemption
# list gets; a release is denied, as a merge is.
handed_on() {
    case "$1" in merge-pr | cut-release) echo deny ;; *) echo ask ;; esac
}

# lookup()'s answer, one value per line: $1 bound, $2 the level, $3 the
# authorities held, then one <authority>:<decider>:<exclusion> per need.
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
                raise "$(handed_on "$AUTHORITY")" "session level $LEVEL; $AUTHORITY settled by person"
            elif [ "$EXCLUSION" = on ]; then
                raise "$(handed_on "$AUTHORITY")" "author exclusion on for $AUTHORITY"
            fi
            ;;
        *)
            raise deny "session holds $HELD; needs $AUTHORITY"
            ;;
    esac
done

decide "$FINAL" "$FINAL_WHY"
exit 0
