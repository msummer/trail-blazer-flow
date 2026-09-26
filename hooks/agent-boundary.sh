#!/usr/bin/env bash
#
# agent-boundary.sh — plugin-shipped PreToolUse hook (#235, review F3) that mechanically enforces
# the implementer/verifier subagents' "no git, no gh" boundary, which was previously prompt-only
# (README's Safety model, before this issue). Reads the hook's stdin JSON; for a Bash tool call
# issued by the implementer subagent, denies (exit 2, one stderr line, empty stdout) any command
# whose parsed command-position word resolves, case-insensitively and after skipping a leading
# shell keyword such as `if`/`then`/`!` (since #398 — see PREFIX_WORDS below), to `git` or `gh`;
# for the verifier subagent, denies
# `gh` outright and denies `git` unless the resolved subcommand is on VERIFIER_GIT_READONLY below
# (fail closed: an unlisted subcommand, a global option before the subcommand, and a bare `git`
# all deny). Since #340, this hook also denies, for both roles, a Bash command that puts a path
# under a `.claude` segment in a write position — a `>`-family redirect target, an argument to a
# CLAUDE_PATH_ARG_COMMANDS member (`tee`/`cp`/`mv`/`cd`/`pushd`), or an in-place `sed`'s argument —
# closing most of the Bash-issued write route into `.claude/` (e.g. `.claude/LESSONS.md`) that
# hooks/claude-dir-guard.sh's file-edit-only (`Edit|Write|apply_patch`) matcher cannot see (an
# ORDINARY Bash-issued write, as opposed to an apply_patch-shaped one, which #407 gave that hook
# its own separate Bash route for). Since #387, both roles ALSO deny a
# command whose command word (anywhere in tool_input.command, across every line) resolves to a
# CLAUDE_CMDLINE_WRITE_COMMANDS member — an interpreter (`python3`, `perl`, …) or a one-step writer
# (`dd`, `install`, …) — when that same command text names a `.claude` path segment anywhere,
# closing the interpreter/one-step-writer gap #340 left open (e.g.
# `python3 -c "open('.claude/LESSONS.md','a')…"`, `perl -i`, `dd of=…`, `install …`); see the
# role-policy comment below and the "#340/#387 .claude Bash-write class" paragraph further down for
# the concrete over-/under-blocking this adds. Every other case — main session (no agent_type), any other agent,
# `permission_mode: "plan"`, malformed stdin, another tool, or `tool_input.command` absent — is
# "no opinion" (exit 0, empty stdout, empty stderr), the same convention hooks/git-c-guard.sh
# already uses. Never executes anything (no git, no gh, nothing derived from the untrusted command
# string), never `eval`s, never writes a file. bash + jq + POSIX awk only — no python, no perl, no
# GNU-only flags (this repo's CLAUDE.md portability convention); exercised under Apple's bash 3.2
# by the selfcheck-macos CI job, same as bin/*.sh and hooks/git-c-guard.sh.
#
# Tokenizer cross-reference (#260): hooks/push-guard.sh inlines a near-twin of "the scan" below
# (same segment-break characters, same normalize(), same repeat-until-exhausted PREFIX_WORDS
# skip, and, since #398, the same tolower() fold applied to the command word and to prefix-word
# matching) for its own, different emitter, and, since #270, the same bash-native carriage-return
# strip of $cmd applied immediately after the jq extraction and before this script's own
# `[ -n "$cmd" ]` guard (see that same point in each file). A future fix to the shared behaviour
# (segment breaking, normalize(), the prefix-word skip, the command-word case fold, the CR strip)
# must be applied to BOTH files — dev/selfcheck.sh's assertion 4.40 clause (c) mechanically pins
# the two scripts' PREFIX_WORDS vocabulary stays byte-identical; since #398, PREFIX_WORDS also
# includes shell reserved words (`if`/`then`/`elif`/`else`/`do`/`while`/`until`/`!`/`coproc`) that
# can directly precede a command in the same segment, alongside the pre-existing interpreter-
# indirection words.
#
# Live-probe record, #259 (maintainer-measured 2026-09-08 against Claude Code 2.1.263, plugin
# 2.7.0 from the marketplace cache -- one Claude Code version, one platform (macOS), one install
# shape; not re-verified across versions, platforms, or install shapes):
#   - The `agent_type` string a trail-blazer-flow plugin subagent sends in PreToolUse stdin is the
#     namespaced `trail-blazer-flow:<agent-name>` form, captured live via a temporary logging
#     PreToolUse hook on the maintainer's session. Both the namespaced and bare spellings are
#     still matched below -- the bare form is insurance against a future de-namespacing (the
#     maintainer's decision on #259), not a hedge against an unknown live value. A Claude Code
#     that ever sends neither spelling leaves this hook inert, removing no permission it would
#     otherwise have removed (see the README's Safety model and the fail-open note there).
#   - This hook's exit 2 does outrank hooks/git-c-guard.sh's "allow" for the same Bash call:
#     replaying one identical `git -C <worktree> status --porcelain` call through both installed
#     hooks, the guard emitted allow (rc 0) and this hook exited 2 (deny); Claude Code's composed
#     verdict was a block for the implementer -- the call never ran -- while the verifier's
#     identical read-only call ran (see hooks/hooks.json's description for why this handler
#     carries no "if" gate). dev/hook-tests.sh's `git -C <wt> push`/`git -C <wt> commit` cases
#     still pin this hook's OWN verdict independent of that composition.
#
# Contract: read the PreToolUse hook JSON on stdin; print nothing and exit 0 ("no opinion") unless
# the call is a Bash command from a recognised implementer/verifier agent_type that the role policy
# denies — a git/gh command the role's BLOCKED_COMMANDS policy denies, OR (since #340) a command
# that writes a path under a `.claude` segment, OR (since #387) a command whose command word names a
# CLAUDE_CMDLINE_WRITE_COMMANDS member while the same command text merely NAMES a `.claude` segment
# anywhere — in which case print exactly one reason line to
# stderr and exit 2 ("deny"); stdout is always empty. Wired in hooks/hooks.json via
# `${CLAUDE_PLUGIN_ROOT}`, with no `if` gate (the `if` field is permission-rule syntax over tool
# input only — it cannot see `agent_type`, so any `if` here would silence the boundary for exactly
# the commands it exists to block).
#
# Documented over-blocking / under-blocking (the #340/#387 `.claude` Bash-write class). Newly
# denied for implementer/verifier since #340: quoted prose containing a `.claude` write shape (e.g.
# `echo "tip: append with >> .claude/LESSONS.md"`); a heredoc body line with `> .claude/…`, or one
# starting with `tee`/`cp`/`mv`/`cd` plus a `.claude` path — the remedy is the Write tool, the same
# remedy this header already gives for a git/gh heredoc body line; a `sed -i` whose SCRIPT TEXT
# spells a `.claude` segment (e.g. `sed -i.bak 's/\.claude/.config/' README.md`) — skipping the
# script argument would need `-e`/`-f` parsing, not attempted; a copy or move OUT OF `.claude`
# (`cp .claude/settings.json /tmp/s.bak`); a `cd` into any `.claude` directory, including a
# read-only look at the installed plugin cache; a consumer workflow that logs into `.claude`
# (`npm test > .claude/test.log`); any user-level `~/.claude/...` write (intentional — the same
# location-independence hooks/claude-dir-guard.sh's own classifier already has); an INPUT redirect
# from `.claude` into a vocabulary or in-place-`sed` command (`tee /tmp/x < .claude/LESSONS.md`) —
# the scan turns `<` into a separator, so the input path reads as that command's argument.
#
# Newly denied since #387 — a CLAUDE_CMDLINE_WRITE_COMMANDS command word sharing a Bash call with
# any `.claude` mention ANYWHERE in tool_input.command (every line, heredoc bodies included), even
# when that command only READS the path: `python3 -c "json.load(open('.claude/settings.json'))"`,
# `awk 'NR<5' .claude/LESSONS.md`, `dd if=.claude/x of=/tmp/y`, `tar -czf /tmp/b.tgz .claude`,
# `rsync .claude/ /tmp/b/`; an interpreter one-liner whose program text merely MENTIONS `.claude`,
# e.g. `grep -n '\.claude' f | awk -F: '{print $1}'`; an unrelated vocabulary command sharing the
# call, e.g. `cat .claude/BASELINE.md && python3 -m pytest`; any checkout or worktree whose absolute
# path has a `.claude` segment (e.g. Claude Code's own `.claude/worktrees/` isolation — this
# harness's own worktrees are `../<repo>-wt-<n>`, unaffected); and any `~/.claude/...` mention. The
# remedy is the Read/Grep tools, or splitting the vocabulary command into its own separate Bash
# call. This rule is agent-boundary-only: it is not part of the tokenizer behaviour shared with
# hooks/push-guard.sh (see the cross-reference above), so no mirror edit was made there.
#
# Newly denied since #398 (the shell-keyword skip and the command-word case fold, both new
# over-block classes, all new denies): any line of a multi-line command or heredoc body (quote-blind
# per line, the same class the scan's own comment documents) whose first word is a keyword followed
# by `git`/`gh` (e.g. a heredoc writing a shell script with `  then git push`); any line or
# quote-blind segment whose first word case-folds to `git`/`gh`/a vocabulary member (a heredoc prose
# line starting `Git …`, `GH …`, `Then gh …`; `echo "a; Git push"`); a case-variant vocabulary
# command sharing a call with `.claude` (`CP`, `Tee`, `Sed -i`, `Python3`); a genuinely distinct
# program named `GIT`/`GH`/etc. on a case-sensitive filesystem; and an uppercase non-keyword such as
# `THEN git push`, which would fail in a real shell anyway. The remedy is the same as the existing
# heredoc remedy above: use the Write/Edit tools.
#
# Still possible (under-blocking, not closed): a writer outside CLAUDE_CMDLINE_WRITE_COMMANDS
# (`sort -o`, `split`, `unzip -d`, `scp`, `cpio`, `vim -es`, `sed`'s `w` command); a launcher that
# becomes the resolved command word instead of the vocabulary member (`uv run python`, `npx`,
# `poetry run`), and `sudo -u x python3` (the same PREFIX_WORDS limit this header's known-evasions
# paragraph already names); a script file whose own CONTENTS name the `.claude` path rather than the
# command line itself (`python3 /tmp/w.py`, including a script written in an earlier call); a
# spelling split by quote or backslash at the command-text level (`.cl"au"de`, `.cl\aude`), or built
# from variables, globs, or string concatenation
# (`d=.cla; python3 -c "open(f'{d}ude/L.md','a')"`); a symlink made earlier via `ln` whose own name
# has no `.claude` segment; a quoted redirect target containing a space (`> "a b/.claude/c"`). Since
# #398: a `!` glued to the following word (`!git push`) — not a reserved word in that glued form, so
# a non-interactive shell treats it as a command literally named `!git`, which does not exist; zsh's
# precommand modifiers `noglob`/`nocorrect`/`repeat N`; and the `eval` builtin (`eval git push`). A
# case-variant git subcommand (`git STATUS`) is NOT an evasion: the subcommand is never case-folded
# (see the scan's emit_segment() comment below), so the verifier's VERIFIER_GIT_READONLY match stays
# exact and fails closed (denies). Like the rest of this hook, this is a tripwire against an
# off-script subagent, not a sandbox.
set -uo pipefail

# --- vocabulary --------------------------------------------------------------------------------
# Grep-extractable single-line KEY="value" declarations (the 2.5/4.36/4.37/4.38 idiom) — kept on
# their own lines with this exact shape so dev/selfcheck.sh's assertion 4.39 can extract the two
# AGENT_TYPES_* lines mechanically.
AGENT_TYPES_IMPLEMENTER="implementer trail-blazer-flow:implementer"
AGENT_TYPES_VERIFIER="verifier trail-blazer-flow:verifier"
VERIFIER_GIT_READONLY="status diff log show rev-parse ls-files merge-base blame grep restore"
BLOCKED_COMMANDS="git gh"
# Since #398, the trailing words above `dash` are shell reserved words that can directly precede a
# command in the same segment (`if true; then git push; fi`, `! gh issue close 5`, `while … do git
# push; done`) — `time`, itself a bash reserved word, was already here for the identical reason.
# `{`/`}`/`(`/`)` need no entry: gsub() already turns them into segment breaks (see "the scan"
# below), never a prefix word. `for`/`select`/`case`/`function`/`in`/`fi`/`done`/`esac`/`[[` are
# deliberately omitted: none of them runs the NEXT word as a command in the same segment. Keywords
# share the ordinary prefix-word skip below, including its dash-token skip after a prefix word —
# harmless here because no valid keyword is ever followed by a `-`-leading command.
PREFIX_WORDS="env command builtin exec sudo nohup time nice stdbuf xargs bash sh zsh ksh dash if then elif else do while until ! coproc"
# CLAUDE_PATH_ARG_COMMANDS (#340) — command words whose FIRST argument carrying a `.claude` path
# segment is a one-step write: `tee` (named in the issue), `cp`/`mv` (the other one-step ways to
# land text at a path), and `cd`/`pushd` (stops `cd .claude && cat >> LESSONS.md` from defeating
# the redirect check below by moving the write out of the redirect target entirely). See
# emit_segment()'s arg_set walk further down.
CLAUDE_PATH_ARG_COMMANDS="tee cp mv cd pushd"
# CLAUDE_CMDLINE_WRITE_COMMANDS (#387) — unversioned interpreter/one-step-writer basenames whose
# command word, anywhere in tool_input.command, closes the interpreter/one-step-writer gap #340
# left open (see claude_seg_in_text() and the END block further down): when one of these is a
# segment's command word AND the same command text names a `.claude` segment anywhere (any line,
# heredoc bodies included), the call is denied — even for a read, since neither the interpreter's
# program text nor the one-step writer's argument list is walked per-token here. Membership is
# tested after stripping a trailing `[0-9.]+` version suffix, so `python3`, `python3.12`,
# `perl5.34` all match `python`/`perl`. tee/cp/mv/cd/pushd/sed stay in the per-segment rules above —
# not repeated here.
CLAUDE_CMDLINE_WRITE_COMMANDS="python perl ruby node nodejs deno bun php lua awk gawk ed ex dd install ln touch truncate rsync tar patch curl wget"
DENY_STEM="trail-blazer-flow agent boundary:"

input="$(cat)"

# --- fast paths ----------------------------------------------------------------------------
# Both are pure performance optimisations, each semantics-preserving with the check it stands in
# for below EXCEPT for a command word split by quote, backslash, or carriage-return characters
# (see fast path 2's own note) — a documented limit of the same tripwire class as the scan's other
# quote-blind behaviour, not a security boundary by itself. A miss on either fast path always means
# "this call is out of scope for this hook", which is also what the slower checks below it would
# conclude.
#
# Fast path 1: a main-session Bash call (no agent_type key in the JSON at all) can never resolve
# to a recognised role, so skip straight to "no opinion" without spawning jq. A raw substring hit
# here does NOT mean the role check below will match — it only means the JSON has an agent_type
# key worth asking jq about. Note a subagent's `cwd` (e.g. `/Users/x/github/some-project`) can
# also make this pattern match by coincidence; that's harmless, since the role-resolution check
# further down still requires an exact match against AGENT_TYPES_IMPLEMENTER/AGENT_TYPES_VERIFIER.
case "$input" in
  *agent_type*) : ;;
  *) exit 0 ;;
esac

# Fast path 2: this hook only ever denies a command whose command-position word resolves,
# case-insensitively (since #398), to "git" or "gh", OR (since #340) a command that writes a path
# under a `.claude` segment, OR (since #387) a vocabulary command word sharing the call with a
# `.claude` mention — if none of "git", "gh", or "claude" (all three case-insensitively — see
# below) appears anywhere in the raw stdin at all, no segment of tool_input.command could possibly
# resolve to a git/gh command word or carry a `.claude` path, so skip the jq/awk spawn.
# Semantics-preserving except for a command word split by
# quote, backslash, or carriage-return characters: normalize() (below) strips quote/backslash
# characters before comparing, and the #270 CR strip (applied to $cmd after the jq extraction,
# before the scan) removes an actual \r byte, so e.g. `g"i"t push` normalises to "git" while the
# raw stdin substring "git" never appears — this fast path exits silently where the slower scan
# would have denied. The CR case is narrower still: a CR *inside* this raw-stdin literal (e.g.
# `g<CR>it push`, escaped by any conforming JSON writer as the two characters `\`+`r`, never a
# literal CR byte) also exits here, before the #270 strip ever runs — the resulting command cannot
# execute as a real `git`/`gh` invocation either, so this is documented, not fixed, for the same
# "tripwire, not a sandbox" reason as the scan's other quote-blind behaviour. The same class
# applies to the new "claude" arm: a `.claude` segment split by a quote/backslash character inside
# THIS raw-stdin literal (not the awk scan's own per-token has_claude_seg(), which does strip
# those) can miss this fast path the same way; also, per this repo's CLAUDE.md portability
# convention, `[Cc][Ll][Aa][Uu][Dd][Ee]` is the POSIX-glob case-fold idiom (no bash-only
# `shopt -s nocasematch` or `,,`/`^^` expansion) — since #398, the same `[Gg][Ii][Tt]`/`[Gg][Hh]`
# idiom case-folds the "git"/"gh" arms too, so this fast path stays bash-3.2-safe under the
# selfcheck-macos CI job. Live Bash payloads issued by a subagent call likely always carry a
# "claude" substring somewhere (the plugin's own `${CLAUDE_PLUGIN_ROOT}`-derived paths, an
# `agent_type` value, or similar) — this is UNVERIFIED in this repo (see the #340 plan's Open
# questions), and if true this fast path rarely short-circuits a subagent call any more; that is a
# performance cost only (one extra jq/awk spawn per implementer/verifier Bash call), not a
# semantics change — the main session is unaffected either way (fast path 1 above already excludes
# it).
case "$input" in
  *[Gg][Ii][Tt]*|*[Gg][Hh]*|*[Cc][Ll][Aa][Uu][Dd][Ee]*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

tool_name="$(printf '%s' "$input" | jq -r '.tool_name? // empty' 2>/dev/null)"
[ "$tool_name" = "Bash" ] || exit 0

# Role resolution: exact string match against space-delimited membership (the sub_allowed idiom
# at hooks/git-c-guard.sh:154-159) — no match, empty, or absent agent_type all resolve to no role,
# i.e. "no opinion".
agent_type="$(printf '%s' "$input" | jq -r '.agent_type? // empty' 2>/dev/null)"
role=""
if [ -n "$agent_type" ]; then
  case " $AGENT_TYPES_IMPLEMENTER " in
    *" $agent_type "*) role="implementer" ;;
  esac
  if [ -z "$role" ]; then
    case " $AGENT_TYPES_VERIFIER " in
      *" $agent_type "*) role="verifier" ;;
    esac
  fi
fi
[ -n "$role" ] || exit 0

# Never opine during a planning turn — same rationale as git-c-guard.sh's identical check: a
# denial during plan mode could read as though the command had actually been attempted.
pmode="$(printf '%s' "$input" | jq -r '.permission_mode? // empty' 2>/dev/null)"
[ "$pmode" != "plan" ] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command? // empty' 2>/dev/null)"

# A CRLF-carrying transport (Git Bash, a CRLF-translating layer) can deliver a command whose
# tokens carry a trailing \r; every comparison below is an exact match, so an unstripped \r
# made `git\r push`/`gh\r ...` resolve to a command word this hook never matches (#270). Stripped
# here, once, before the tokenizer — the same shared behaviour hooks/push-guard.sh applies at the
# identical point in its own tokenizer (see this file's header cross-reference). Pure parameter
# expansion: no new process, so this hook still executes nothing (see this file's header).
cr=$'\r'
cmd="${cmd//$cr/}"

[ -n "$cmd" ] || exit 0

# --- the scan ------------------------------------------------------------------------------
# A POSIX-awk tokenizer that never REJECTS (unlike git-c-guard.sh's lexer, which rejects on any
# unquoted metacharacter — that behaviour would be a bypass here: rejecting outright would leave
# this hook silent, i.e. no opinion, for the exact composite/injected forms it exists to catch).
# Quote-blind by design (strips quote characters rather than tracking quote state) — see the
# header's false-positive-class note below for the cost.
#
# Processes $cmd one input line (awk record) at a time, so an EMBEDDED NEWLINE inside
# tool_input.command — e.g. a heredoc line that happens to start with `git`/`gh` while writing a
# fixture file's contents — is scanned as its own independent segment start, exactly like any
# other line. This is a deliberate false-positive class, not a bug: the remedy is to write file
# content through the Write/Edit tools rather than a Bash heredoc (this repo's own CLAUDE.md and
# skills already say so for other reasons). A quote-aware or newline-aware lexer that instead
# risked mis-tracking an unterminated quote or a multi-line construct and letting a real `git
# push` through would be the worse failure mode for a control whose only job is to fail closed.
#
# Since #270, every `\r` in $cmd has already been stripped (see the bash-native strip right after
# the jq extraction above) before this scan ever runs — normalize() below only ever strips quote
# and backslash characters because a carriage return can no longer reach it.
#
# Per line: BEFORE segments are broken out, a separate redirect pass (since #340) walks a copy of
# the raw line looking for every `>`-family redirect (`>`, `>>`, `>|`, `>&`) and, for each one,
# extracts its target token and emits "-claude-write- <target>" if that target carries a `.claude`
# path segment (has_claude_seg() below) — this is what catches a redirect target the later
# command-word walk would never see, since a redirect argument is never itself a command word. `<`
# is never matched by this pass, so an input redirect (e.g. `wc -l < .claude/LESSONS.md`) is
# ignored, and `>&2`/`2>&1` yield the target "2"/"1" (or no match at all), never a `.claude` hit.
# THEN, exactly as before #340: every one of `; & | ( ) { } `` (the eight segment-break characters)
# starts a new segment; `<`/`>` are ordinary token separators for THIS pass (not segment breaks) —
# a Bash redirection never starts a new command — the redirect pass above already read `>` targets
# before this gsub blanks them out. Within each segment, tokens are walked from the start:
#   - a token matching ^[A-Za-z_][A-Za-z0-9_]*= (an assignment prefix, e.g. FOO=1) is skipped;
#   - a token whose normalised, lower-cased form (quote/backslash characters stripped; basename
#     taken after the last '/'; case-folded, since #398) is a member of PREFIX_WORDS is skipped,
#     and a "saw prefix" flag is set — PREFIX_WORDS itself now also includes the shell reserved
#     words listed at its declaration above (`if`/`then`/`elif`/`else`/`do`/`while`/`until`/`!`/
#     `coproc`), so a keyword directly preceding a command in the same segment is skipped exactly
#     like an interpreter-indirection word;
#   - once that flag is set, a further token starting with '-' is also skipped (an option to the
#     prefix word, e.g. `bash -c`, `xargs -I{}`);
#   - the first token that survives all three skips is the segment's command word, emitted in its
#     normalised, lower-cased form (since #398 — only the command word and prefix-word matching are
#     case-folded; the git subcommand below, redirect targets, and other arguments are not). If it
#     is exactly "git" (already case-folded), the token(s) after it are walked once more to
#     resolve the subcommand: a "-C" token is skipped together with the token right after it (a
#     worktree path); any OTHER token starting with '-' seen before a subcommand is found emits
#     the sentinel "-globalopt-" (fail-closed for the verifier: an unrecognised global option
#     could be anything, including one that mutates); no subcommand at all emits "-none-" (a bare
#     `git`, also fail-closed for the verifier). "git <subcommand>" is emitted for a git command
#     word, or the bare command word otherwise. If it is a member of CLAUDE_PATH_ARG_COMMANDS
#     (since #340), the token(s) after it are walked once more, emitting
#     "-claude-write- <token>" for the FIRST one carrying a `.claude` segment — this catches
#     `tee`/`cp`/`mv`/`cd`/`pushd` writing or moving into (or navigating into) a `.claude`
#     directory via a plain argument, not a redirect. If it is exactly "sed" (since #340), those
#     same tokens are first scanned for an in-place flag (`-i`, `-i.bak`, or `--in-place`); only
#     when one is found does the identical `.claude`-segment token walk run — `sed -n` (no
#     in-place flag) never triggers it, even when a `.claude` path is its argument, since that
#     invocation only reads. A segment with no surviving token (blank, or only assignments/prefix
#     words) emits nothing.
#
# Command-level, since #387: emit_segment() additionally captures, into the GLOBAL cw_word, the
# first segment's command word (in its case-folded since #398, non-version-stripped form) found
# anywhere across
# every record whose version-stripped basename is a CLAUDE_CMDLINE_WRITE_COMMANDS member — this
# check runs regardless of CLAUDE_PATH_ARG_COMMANDS/"sed" membership, so a plain `python3 -c …`
# segment is captured too. Separately, the per-record block below the segment loop calls
# claude_seg_in_text() (below normalize()/has_claude_seg()) against the RAW, un-broken record text
# ($0, before the `(`/`)`/`;`/… segment-break gsub runs) — this is what links an interpreter's
# command word to a `.claude` mention BURIED inside a parenthesised argument list the segment walk
# itself would have split apart (e.g. `open('.claude/LESSONS.md','a')`); on a hit, it splits $0 on
# whitespace and records the first whitespace-delimited token containing a `.claude` segment into
# the GLOBAL cw_tok. Both globals accumulate across every record (every line of tool_input.command),
# so a heredoc-fed interpreter whose command word is on one line and whose `.claude` mention is on a
# later line (a body line) still sets both. A final END block (after the closing `'"'"'` below)
# emits the same "-claude-write- <target>" sentinel the redirect/arg-vocab/in-place-sed passes above
# already use, joining both captures, whenever BOTH cw_word and cw_tok are non-empty — so the
# existing role-policy `"-claude-write- "*)` arm and deny printf need no #387-specific change.
scan_out="$(printf '%s\n' "$cmd" | awk -v prefix_words="$PREFIX_WORDS" -v arg_cmds="$CLAUDE_PATH_ARG_COMMANDS" -v cw_cmds="$CLAUDE_CMDLINE_WRITE_COMMANDS" '
BEGIN {
  sq = sprintf("%c", 39)
  n = split(prefix_words, pwarr, " ")
  for (i = 1; i <= n; i++) prefix_set[pwarr[i]] = 1
  na = split(arg_cmds, acarr, " ")
  for (i = 1; i <= na; i++) arg_set[acarr[i]] = 1
  ncw = split(cw_cmds, cwarr, " ")
  for (i = 1; i <= ncw; i++) cw_set[cwarr[i]] = 1
}
function normalize(tok,    t, parts, np) {
  t = tok
  gsub(sq, "", t)
  gsub(/"/, "", t)
  gsub(/\\/, "", t)
  np = split(t, parts, "/")
  return parts[np]
}
# has_claude_seg (#340) — TRUE iff tok, after stripping quote characters and normalising a
# backslash to a forward slash, case-folded, has an EXACT ".claude" path segment (not merely a
# ".claude"-containing substring like ".claude-backup", and not a bare basename match — this is
# deliberately NOT normalize(), which takes the basename after the last "/" and would miss a
# ".claude" segment that is not the final path component). The leading/trailing "/" wrap turns
# both a leading and a trailing segment into an interior one for the index() search.
function has_claude_seg(tok,    u) {
  u = tok
  gsub(sq, "", u)
  gsub(/"/, "", u)
  gsub(/\\/, "/", u)
  u = tolower(u)
  return index("/" u "/", "/.claude/") > 0
}
# claude_seg_in_text (#387) — TRUE iff s, case-folded and wrapped with a leading/trailing space,
# contains an EXACT ".claude" path segment bounded by any non-filename character on each side (not
# the quote/backslash-stripped single-token form has_claude_seg() itself uses — s here is a whole
# raw record or a whitespace-split token straight off it, so no stripping is done before the
# bracket-expression boundary check runs). Deliberately checked against the UN-BROKEN record text so
# a `.claude` mention inside a parenthesised interpreter argument list (which the segment-break gsub
# would have split apart) is still found.
function claude_seg_in_text(s,    v) {
  v = tolower(" " s " ")
  return match(v, /[^a-z0-9_.-]\.claude[^a-z0-9_.-]/) > 0
}
function emit_segment(seg,    ntok, toks, idx, tok, norm, saw_prefix, cmdword, j, gitsub, inplace, lw) {
  ntok = split(seg, toks, /[ \t]+/)
  idx = 1
  saw_prefix = 0
  cmdword = ""
  while (idx <= ntok) {
    tok = toks[idx]
    if (tok == "") { idx++; continue }
    if (match(tok, /^[A-Za-z_][A-Za-z0-9_]*=/) == 1) { idx++; continue }
    norm = tolower(normalize(tok))
    if (norm in prefix_set) { saw_prefix = 1; idx++; continue }
    if (saw_prefix && substr(tok, 1, 1) == "-") { idx++; continue }
    cmdword = norm
    idx++
    break
  }
  if (cmdword == "") return
  if (cmdword == "git") {
    gitsub = ""
    j = idx
    while (j <= ntok) {
      tok = toks[j]
      if (tok == "") { j++; continue }
      if (tok == "-C") { j += 2; continue }
      if (substr(tok, 1, 1) == "-") { gitsub = "-globalopt-"; break }
      gitsub = normalize(tok)
      break
    }
    if (gitsub == "") gitsub = "-none-"
    print "git " gitsub
  } else {
    print cmdword
    lw = cmdword
    sub(/[0-9.]+$/, "", lw)
    if ((lw in cw_set) && cw_word == "") cw_word = cmdword
    if (cmdword in arg_set) {
      for (j = idx; j <= ntok; j++) {
        if (has_claude_seg(toks[j])) { print "-claude-write- " toks[j]; break }
      }
    } else if (cmdword == "sed") {
      inplace = 0
      for (j = idx; j <= ntok; j++) {
        if (match(toks[j], /^-[A-Za-z]*i/) == 1) { inplace = 1; break }
        if (match(toks[j], /^--in-place/) == 1) { inplace = 1; break }
      }
      if (inplace) {
        for (j = idx; j <= ntok; j++) {
          if (has_claude_seg(toks[j])) { print "-claude-write- " toks[j]; break }
        }
      }
    }
  }
}
{
  rd_rest = $0
  while (match(rd_rest, />[>|&]?[ \t]*[^ \t;&|(){}`<>]+/)) {
    rd_tgt = substr(rd_rest, RSTART, RLENGTH)
    sub(/^>[>|&]?[ \t]*/, "", rd_tgt)
    if (has_claude_seg(rd_tgt)) print "-claude-write- " rd_tgt
    rd_rest = substr(rd_rest, RSTART + RLENGTH)
  }
  line = $0
  gsub(/[;&|(){}`]/, "\n", line)
  gsub(/[<>]/, " ", line)
  nseg = split(line, segs, /\n/)
  for (s = 1; s <= nseg; s++) emit_segment(segs[s])
  if (cw_tok == "" && claude_seg_in_text($0)) {
    cw_ntok = split($0, cw_toks, /[ \t]+/)
    for (cw_j = 1; cw_j <= cw_ntok; cw_j++) {
      if (claude_seg_in_text(cw_toks[cw_j])) { cw_tok = cw_toks[cw_j]; break }
    }
  }
}
END { if (cw_word != "" && cw_tok != "") print "-claude-write- " cw_word " with " cw_tok }
')"

# --- role policy -----------------------------------------------------------------------------
# Implementer: deny on ANY segment whose command word is git or gh, regardless of git subcommand
# (the implementer needs neither — see the Decision this issue implements). Verifier: deny on gh
# outright; for git, deny unless the resolved subcommand is a member of VERIFIER_GIT_READONLY —
# so "-globalopt-", "-none-", and any subcommand not on that list all deny (fail closed). Since
# #340, BOTH roles also deny on a "-claude-write- <target>" line emitted by the awk scan's redirect
# pass, CLAUDE_PATH_ARG_COMMANDS vocabulary walk, or in-place-sed walk above — a `.claude`-segment
# write is denied for the implementer AND the verifier alike, unlike the git/gh policy's per-role
# split (the verifier's own writes are meant to be transient mutation-probe edits restored before
# it returns, per agents/verifier.md — a `.claude` write from Bash is never one of those). Since
# #387, the identical sentinel is ALSO emitted by the awk scan's END block (the
# CLAUDE_CMDLINE_WRITE_COMMANDS command-level rule) — this role-policy arm needed no change to pick
# that up. The first offending line (scan order) decides; stdout stays empty on every path.
deny_cmd=""
deny_kind="git"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    "-claude-write- "*)
      deny_kind="claude"
      deny_cmd="${line#-claude-write- }"
      break
      ;;
    "git "*)
      if [ "$role" = "implementer" ]; then
        deny_cmd="$line"
        break
      fi
      sub="${line#git }"
      case " $VERIFIER_GIT_READONLY " in
        *" $sub "*) ;;
        *) deny_cmd="$line"; break ;;
      esac
      ;;
    gh)
      deny_cmd="gh"
      break
      ;;
  esac
done <<EOF
$scan_out
EOF

if [ -n "$deny_cmd" ]; then
  if [ "$deny_kind" = "claude" ]; then
    printf '%s %s role may not write a path under a .claude segment from Bash (blocked: %s) — record it in your report'"'"'s Reviewer notes instead; see agents/%s.md\n' \
      "$DENY_STEM" "$role" "$deny_cmd" "$role" >&2
  elif [ "$role" = "implementer" ]; then
    printf '%s implementer role may not run any of: %s (blocked: %s) — see agents/implementer.md\n' \
      "$DENY_STEM" "$BLOCKED_COMMANDS" "$deny_cmd" >&2
  else
    printf '%s verifier role may only run read-only git (%s), never gh (blocked: %s) — see agents/verifier.md\n' \
      "$DENY_STEM" "$VERIFIER_GIT_READONLY" "$deny_cmd" >&2
  fi
  exit 2
fi

exit 0
