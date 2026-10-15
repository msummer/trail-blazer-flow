#!/usr/bin/env bash
#
# claude-dir-guard.sh — plugin-shipped PreToolUse hook (#327; the apply_patch route, .codex and the Bash
# apply_patch-shim route were added by #407) that mechanically denies an implementer or verifier subagent a
# write to a path under a `.claude` or `.codex` segment through Edit, Write, apply_patch, or a Bash call
# that runs Codex's apply_patch shim. It turns the orchestrator-prose LESSONS.md dispatch guard (which only
# notices a change after the dispatch returns) into a rail.
#
# Contract: read the PreToolUse hook JSON on stdin. Print nothing and exit 0 ("no opinion") unless the call
# is an Edit, Write, apply_patch or Bash call from a recognised implementer or verifier agent_type that the
# policy below denies. A deny prints exactly one reason line to stderr and exits 2; stdout is always empty.
# Denied:
#   - Edit/Write: a file_path with any path segment equal to `.claude` or `.codex`, case-insensitively, or
#     one that cannot be classified (not absolute, or holding a `..` segment: fail closed);
#   - apply_patch, and a Bash call carrying an inline patch: an Add/Update/Delete/Move-to header path with
#     such a segment (a relative header path is joined to the payload cwd), an unclassifiable path, or a
#     patch that cannot be parsed into a recognised header shape (an unknown `*** ` marker, an empty header
#     path, no header at all); an apply_patch call with an absent or empty command also denies;
#   - Bash, the shim route (is_apply_patch_word resolves apply_patch or applypatch, by basename, as a
#     command word): a shim with no inline patch this hook can see (a patch read from a file); a shim whose
#     input is anything but its own inline heredoc while an inline patch also appears elsewhere in the call
#     (a decoy); an unbalanced quote or trailing backslash before the resolved command word in a segment
#     that mentions the shim; more than DBRACKET_MAX standalone `]]` in a segment, or a `]]` cut tail that
#     consumes skip words without resolving one; and a `.claude` or `.codex` mention anywhere in the call
#     text when the shim is a command word;
#   - a call too large for the analysis budget, or over a size cap ("Analysis deadline (#457)" and
#     "Size caps (#457)" below).
# No opinion for everything else: the main session (no agent_type), any other agent, permission_mode
# "plan", a tool other than Edit, Write, apply_patch or Bash, malformed stdin, an Edit/Write call with an
# absent file_path, a Bash call with an absent command, a Bash call that neither carries an inline patch nor runs the shim as a command word (the shim
# name as a plain argument is quiet), and an ordinary absolute path outside any such segment.
#
# No `if` gate in hooks/hooks.json: the `if` field is permission-rule syntax over tool input only. It cannot
# see agent_type, express a case-insensitive nested or `..` path-segment rule, parse an apply_patch patch
# header grammar, or tell a Bash command word from an argument, so any `if` would silence this hook for
# exactly the spellings it exists to catch.
#
# NO FILESYSTEM ACCESS, strictly less than hooks/push-guard.sh, which reads .git paths: the hook reads only
# the stdin JSON, and the payload cwd is trusted only as a string to join, never opened. It executes nothing
# (no git, no gh, nothing derived from the untrusted input), never evals, never writes a file, and runs no
# awk, sed, grep or tr (the booby-trap fixtures in dev/hook-tests.sh trap them): text is split with shell
# builtins only. bash + jq only, no GNU-only flag; exercised under Apple bash 3.2 by the macOS CI job.
#
# Shared with the sibling hooks:
#   - AGENT_TYPES_IMPLEMENTER and AGENT_TYPES_VERIFIER are byte-identical to hooks/agent-boundary.sh, pinned by
#     gate assertion 4.45; that hook's header holds the #259 live-probe record for the vocabulary.
#   - GUARDED_TOOLS stays "Edit Write", pinned by gate assertion 4.53 (every member must appear on an
#     implementer or verifier `tools:` line, and no role names apply_patch). apply_patch and Bash live in their
#     own PATCH_TOOLS and BASH_TOOLS so GUARDED_TOOLS does not widen; Bash is on 4.53's exemption list because
#     hooks/agent-boundary.sh covers its .claude-write policy. A write tool outside GUARDED_TOOLS,
#     PATCH_TOOLS and BASH_TOOLS (MultiEdit, NotebookEdit) is not guarded: no role's tools: line names one
#     today, and the gate fails if one gains it without a matching update.
#   - By convention, unpinned: PREFIX_WORDS (agent-boundary.sh and push-guard.sh are pinned to each other by
#     4.40(c); this copy is not), PREFIX_VALUE_WORDS, PREFIX_INTERP_WORDS, INTERP_VALUE_OPTS, DBRACKET_MAX
#     (counted per segment here, per record in agent-boundary.sh) and cdg_rx_ere (the class of
#     agent-boundary.sh's rx_re). The walk is a pure-bash port of the agent-boundary.sh and push-guard.sh
#     technique, not a byte copy.
#
# Live probe, #327 (measured 2026-09-17 against Claude Code 2.1.274, macOS, a temporary logging PreToolUse
# hook with matcher Edit|Write, this repo loaded via --plugin-dir; one version, one platform, one install):
#   M1  a main-session Edit/Write payload carries no agent_type and no agent_id key (fast path 1).
#   M2/M3  an implementer Write or Edit payload carries agent_type trail-blazer-flow:implementer.
#   M4  file_path was an absolute path under the session cwd in all six captured payloads, even when the call
#       asked for a relative one. Whether Claude Code or the model absolutised it is not established, which is
#       why a non-absolute path denies (fail closed) instead of passing.
#   M5  a hook with matcher Edit|Write that exits 2 with one stderr line blocked the subagent's Write
#       outright; exiting 0 let the main session's Write through. This is the matcher string measured.
#   M7  a verifier Edit payload carries agent_type trail-blazer-flow:verifier, an agent_id and an absolute
#       file_path; the verifier has no Write tool, so no verifier Write payload exists to measure.
# Not measured: MultiEdit or NotebookEdit payloads, symlink and hard-link resolution, whether cwd is always
# the repo root.
# Codex apply_patch probe (#407, ADR 0002 amendment, P4): the tool call is named apply_patch, carries no
# file_path, and holds the whole patch in tool_input.command in Codex's grammar (`*** Begin Patch`, `*** Add
# File:`, `*** Update File:`, `*** Delete File:`, `*** Move to:`, `*** End of File`, `*** End Patch`), plus a
# top-level cwd. Only Add File and Update File were verified directly; an unrecognised `*** ` marker denies
# instead of guessing. Codex shim probe (#407, S0/#412): Codex puts an apply_patch (and applypatch) shim on
# the shell PATH, and a shell-issued `apply_patch <<'EOF'` heredoc wrote .claude/settings.local.json inside
# the sandbox. Whether Codex reports that shape as Bash or as an apply_patch tool call was not observed;
# this hook covers the Bash shape either way.
#
# Analysis deadline (#457). This hook's own analysis (everything after the role and plan-mode exits) is
# bounded by a whole-second wall-clock budget, CDG_ANALYSIS_BUDGET_SECS (5s), sampled from $SECONDS as an
# elapsed difference from cdg_t0 (captured right after `set -uo pipefail`): check_deadline denies with one
# fixed "too large to analyse" reason (deny_too_large, fail closed, naming only the resolved role and tool)
# the first time $SECONDS reaches cdg_deadline, and never resets $SECONDS. Without it a long run of prefix
# words ahead of the shim kept the walk busy for about as long as Claude Code's own 10s hook timeout, and a
# timed-out PreToolUse hook gives no deny, so the shim ran unguarded. The sampling rule binds every future
# addition: call check_deadline as the FIRST statement of EVERY loop whose trip count grows with the input
# (grep this file for check_deadline for the current list), and every $(...) call to a helper that samples
# (ltrim, trim) must propagate a deny with `[ "$?" -eq 0 ] || exit 2`, since a deny raised inside a command
# substitution only exits that subshell. Every sample site is reachable only after the role and plan-mode
# exits, so the deadline deny reaches the implementer and verifier only (unlike hooks/push-guard.sh, which
# has no role scoping). Two test-only knobs are read from the ENVIRONMENT only and can only deny sooner:
# TBF_CLAUDE_DIR_GUARD_BUDGET_SECS lowers the budget (exactly one or two ASCII digits, strictly less than the
# production budget), and TBF_CLAUDE_DIR_GUARD_SAMPLE_CAP denies once that many samples have been taken (1-4
# digits, no leading zero; anything else means off), which pins one sample site independent of host speed.
#
# Size caps (#457). Under Apple bash 3.2 a `${text//pat/repl}` substitution is superlinear in the text's
# length and match count and cannot be sampled from inside bash; a whole-text word-split is linear but
# likewise unsampled. So:
#   - every such substitution runs on ONE physical line at a time (a newline is itself a segment break, so
#     the segments are identical), inside a loop that samples the deadline first;
#   - cdg_prepare_text runs first on BOTH text routes and denies fail closed, BEFORE any split or
#     substitution, when the whole text is longer than CDG_TEXT_MAX_BYTES bytes; it then strips CRs line by
#     line in a sampled loop, and denies a physical line longer than CDG_LINE_MAX_BYTES bytes. On the
#     apply_patch route the line cap applies only to a line that contains a CR (the strip is the only
#     superlinear step a long CR-free content line meets there) or a `*** ` marker (a header line the parser
#     acts on); every other line is bounded by the whole-text cap and the sampled loops. The Bash route caps
#     every line;
#   - a single path (an Edit/Write file_path, or a patch header path joined to cwd) and the stdin cwd field
#     are each denied, before any substitution, when longer than CDG_LINE_MAX_BYTES bytes. Every cap counts
#     BYTES, not characters: the length check runs under a scoped LC_ALL=C, because ${#x} counts characters
#     under a multibyte locale and a text of 4-byte characters would otherwise pass at four times its size.
# Worst-case wall clock for the whole hook, for review: at most max(cdg_budget, T_prefix(L)) + U_max.
# T_prefix is the prefix the deadline cannot sample around: cat, the fast-path globs and the one split-name
# regex pass over the payload, up to five jq calls, the length checks, cdg_prepare_text's CR-presence glob
# and whole-text word-split, the like whole-text splits in is_apply_patch_word, has_exact_begin_patch_line
# and parse_patch_headers (all linear, bounded by CDG_TEXT_MAX_BYTES), and the raw-text .claude/.codex glob.
# U_max is the largest single step the deadline cannot interrupt: one line's substitutions (bounded by
# CDG_LINE_MAX_BYTES; also one character step of cdg_chain_line, which samples per character), one line's or
# segment's split-name regex, one segment's `toks=($seg)` word-split, one `"${toks[@]}"` expansion, one
# walk_window iteration (plus any per-index cost bash 3.2's arrays add; also one token's env -S reading and
# one expansion-word regex), one forked trim or ltrim call up to its first in-subshell sample, or one
# classify_path. Not closed: T_prefix is unsampled (though counted by the wall clock), and the Codex CLI's
# own hook timeout, if any, is UNVERIFIED; the budget is sized against Claude Code's documented 10s
# PreToolUse timeout only.
#
# This is a tripwire against an off-script subagent, not a sandbox. The spellings the hook does not see and
# the harmless calls it denies (with the remedy for each) are listed in docs/reference/safety-model.md,
# under "Known gaps" and "Known over-blocks".
set -uo pipefail
# #457: sampled once, at hook start; see "Analysis deadline (#457)" in this file's header.
cdg_t0=$SECONDS

# --- vocabulary --------------------------------------------------------------------------------
# Grep-extractable single-line KEY="value" declarations (the 2.5/4.36-4.42 idiom). The two AGENT_TYPES_*
# lines are byte-identical to hooks/agent-boundary.sh's, pinned by gate assertion 4.45.
AGENT_TYPES_IMPLEMENTER="implementer trail-blazer-flow:implementer"
AGENT_TYPES_VERIFIER="verifier trail-blazer-flow:verifier"
GUARDED_TOOLS="Edit Write"
PATCH_TOOLS="apply_patch"
BASH_TOOLS="Bash"
GUARDED_SEGMENT=".claude"
GUARDED_SEGMENT_CODEX=".codex"
CLAUDE_DIR_DENY_STEM="trail-blazer-flow claude-dir guard:"
# PREFIX_WORDS: byte-identical to the hooks/agent-boundary.sh and hooks/push-guard.sh copies, by convention
# (4.40(c) pins only those two against each other). Used only by walk_window() to skip a leading shell
# keyword or interpreter-indirection word, then a following dash-led option (or, after repeat, its count
# token), before resolving the command word of a segment.
PREFIX_WORDS="env command builtin exec sudo nohup time nice stdbuf xargs bash sh zsh ksh dash if then elif else do while until ! coproc eval trap noglob nocorrect - repeat"
# PREFIX_VALUE_WORDS (#518): the PREFIX_WORDS members whose dash options can take a SEPARATE value word
# (nice -n 5, sudo -u root). This walk treats env as one too (it has no env arm of its own). Interpreter words
# stay out (see PREFIX_INTERP_WORDS). Byte-identical to the agent-boundary.sh and push-guard.sh copies, by
# convention.
PREFIX_VALUE_WORDS="exec nice stdbuf sudo time xargs"
# PREFIX_INTERP_WORDS / INTERP_VALUE_OPTS (#537): the interpreter members of PREFIX_WORDS, and the long
# options of those interpreters that take a SEPARATE value word (see the #537 block above
# is_apply_patch_word()). Byte-identical to the agent-boundary.sh and push-guard.sh copies, by convention.
PREFIX_INTERP_WORDS="bash dash ksh sh zsh"
INTERP_VALUE_OPTS="--init-file --rcfile -init-file -rcfile"
# DBRACKET_MAX (#437): byte-identical to the agent-boundary.sh and push-guard.sh copies, by convention. It
# counts standalone ]] tokens PER SEGMENT here (agent-boundary.sh counts per record).
DBRACKET_MAX="64"
# CDG_ANALYSIS_BUDGET_SECS (#457): whole-second wall-clock budget; see "Analysis deadline (#457)". Sized well
# under Claude Code's 10s hook timeout, like hooks/push-guard.sh's.
CDG_ANALYSIS_BUDGET_SECS="5"
# CDG_LINE_MAX_BYTES (#457): longest physical line of a Bash command, of a patch (only a CR-bearing or
# `*** ` line), and longest single path or cwd, in BYTES; see "Size caps (#457)".
CDG_LINE_MAX_BYTES="2000"
# CDG_TEXT_MAX_BYTES (#457): longest whole Bash command or patch text, in bytes; see "Size caps (#457)".
CDG_TEXT_MAX_BYTES="1000000"

# #457: cdg_budget defaults to CDG_ANALYSIS_BUDGET_SECS; TBF_CLAUDE_DIR_GUARD_BUDGET_SECS is a test-only,
# environment-only knob that can only LOWER it (see "Analysis deadline (#457)").
cdg_budget="$CDG_ANALYSIS_BUDGET_SECS"
case "${TBF_CLAUDE_DIR_GUARD_BUDGET_SECS:-}" in
  [0-9]|[0-9][0-9]) [ "$TBF_CLAUDE_DIR_GUARD_BUDGET_SECS" -lt "$cdg_budget" ] && cdg_budget="$TBF_CLAUDE_DIR_GUARD_BUDGET_SECS" ;;
esac
cdg_deadline=$((cdg_t0 + cdg_budget))
# #457: TBF_CLAUDE_DIR_GUARD_SAMPLE_CAP is the second test-only, environment-only knob (see "Analysis
# deadline (#457)"); anything other than 1-4 digits with no leading zero means 0, off.
cdg_sample_cap=0
case "${TBF_CLAUDE_DIR_GUARD_SAMPLE_CAP:-}" in
  [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]) cdg_sample_cap="$TBF_CLAUDE_DIR_GUARD_SAMPLE_CAP" ;;
esac
cdg_samples=0

# deny_too_large (#457) -- prints exactly one fixed stderr line (it echoes no part of the input
# beyond the role and tool name this hook itself resolved), then exits 2.
deny_too_large() {
  printf '%s %s role'"'"'s %s call is too large to analyse before the hook'"'"'s time limit (blocked: too large to analyse), and is denied fail-closed — split it into smaller calls\n' \
    "$CLAUDE_DIR_DENY_STEM" "$role" "$tool_name" >&2
  exit 2
}

# count_sample / check_deadline (#457): check_deadline is the first statement of every loop whose trip count
# grows with the input (the sampling rule is in the header). Each is kept on one line so a mutant that
# neuters it has a single, unique `from`. check_deadline is an ALIAS, not a function, on purpose: under Apple
# bash 3.2 a function call is much more expensive while the calling frame holds a large string or array (this
# walk always does), so a function sample at every loop head would slow every benign large command; an alias
# is expanded when each function body below is parsed, so a sample costs two builtin tests and no call.
# Aliases need expand_aliases in a non-interactive shell, and this definition must precede every function
# that uses it.
shopt -s expand_aliases
# cdg_bytes VALUE (#457): sets cdg_n to VALUE's length in BYTES (LC_ALL=C scoped to this call), since ${#x}
# counts characters under a multibyte locale. Not for use inside a hot loop (a function call).
cdg_bytes() { local LC_ALL=C; cdg_n="${#1}"; }
count_sample() { cdg_samples=$((cdg_samples + 1)); [ "$cdg_samples" -lt "$cdg_sample_cap" ] || deny_too_large; }
alias check_deadline='[ "$SECONDS" -lt "$cdg_deadline" ] || deny_too_large; [ "$cdg_sample_cap" -eq 0 ] || count_sample;'

input="$(cat)"

# Fast path 1: a main-session call (no agent_type key in the JSON) can never resolve to a role, so skip jq
# (M1). There is deliberately no .claude/.codex substring fast path: it would not be semantics-preserving,
# because the unclassifiable-path deny (a non-absolute or ..-carrying file_path, an unparseable apply_patch
# command) can deny a call that never holds either literal.
case "$input" in
  *agent_type*) : ;;
  *) exit 0 ;;
esac

# cdg_split_ere (#538): the shim name with any run of backslash, double-quote or apostrophe characters between
# its letters (and an optional underscore), which the shell deletes: apply_"patch", apply\_patch. cdg_q is one
# such run, an ERE bracket expression (a backslash is literal inside it). There is no group and the pattern
# has a fixed length, so one pass over a payload is linear. cdg_split_raw tests the raw payload under a scoped
# C locale (byte-wise); the same pattern is tested per line and per segment in is_apply_patch_word().
cdg_q="[\\\"']*"
cdg_split_ere="a${cdg_q}p${cdg_q}p${cdg_q}l${cdg_q}y${cdg_q}_?${cdg_q}p${cdg_q}a${cdg_q}t${cdg_q}c${cdg_q}h"
cdg_split_raw() { local LC_ALL=C; [[ $input =~ $cdg_split_ere ]]; }

# Fast path 2 (#407, #538): a pre-filter. Every genuine Edit, Write or apply_patch call spells its tool_name
# literally in the raw JSON, so requiring Edit, Write, apply_patch, applypatch (Codex's shim also answers to
# the no-underscore spelling) or the grammar marker "*** Begin Patch" anywhere in the raw stdin never skips a
# real call; the substring can sit anywhere in the payload, so a pass only means "look closer". A Bash call
# that spells none of them can still run the shim when the shell deletes quote or backslash characters inside
# its name, so a second check runs only when the literal check fails and the payload carries a backslash or an
# apostrophe (in raw JSON a double quote arrives as a backslash and a quote, and a backslash as two): one
# regex pass for the split spelling, which spawns no jq. A call that fails both checks gets no opinion. Both
# checks read the raw JSON text as the serializer wrote it, so they assume it writes ASCII letters, the
# underscore and the apostrophe literally rather than as a \u escape.
case "$input" in
  *Edit*|*Write*|*apply_patch*|*applypatch*|*'Begin Patch'*) : ;;
  *\\*|*"'"*) cdg_split_raw || exit 0 ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

tool_name="$(printf '%s' "$input" | jq -r '.tool_name? // empty' 2>/dev/null)"
case " $GUARDED_TOOLS $PATCH_TOOLS $BASH_TOOLS " in
  *" $tool_name "*) : ;;
  *) exit 0 ;;
esac

# Role resolution: exact string match against space-delimited membership. No match, an empty or an absent
# agent_type resolves to no role, i.e. no opinion.
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

# Never opine during a planning turn -- same rationale as every sibling hook: a denial during plan
# mode could read as though the edit had actually been attempted.
pmode="$(printf '%s' "$input" | jq -r '.permission_mode? // empty' 2>/dev/null)"
[ "$pmode" != "plan" ] || exit 0

# Shared constants for both routes. A CRLF-carrying transport can deliver a path or patch text with a trailing
# or embedded \r (#270). Stripping it can only WIDEN which paths match .claude/.codex (removing a character
# can only join two fragments into a segment this hook already looks for, never separate a matching one), so
# the strip can never turn a deny into an allow. Pure parameter expansion: no new process.
cr=$'\r'
lf=$'\n'
tab=$'\t'
# sq/dq (#437): one single-quote and one double-quote character, used by walk_window() to strip quote
# characters from a token before resolving it. Pure parameter expansion, like cr/lf/tab above.
sq="'"
dq='"'
# cdg_rx_ere (#538): a runtime expansion inside a word: a dollar sign followed by a name character, a digit,
# a special parameter or a quote. The class of hooks/agent-boundary.sh's rx_re, by convention unpinned.
cdg_rx_ere="[\$][A-Za-z0-9_@*#?!\$=~^${dq}${sq}-]"

# classify_path TOOL RAW_PATH -- the classifier both routes call: pure builtins, no filesystem access.
# Order matters: the more specific ".claude"/".codex" message wins over the generic "unclassifiable" one.
# Prints the reason line and exits 2 on any deny; returns (no output, no exit) when RAW_PATH is benign.
classify_path() {
  local tool="$1" raw="$2" p p_disp
  # #457: a path longer than the per-line cap denies BEFORE the whole-string substitutions below, which are
  # superlinear under bash 3.2.
  cdg_bytes "$raw"
  [ "$cdg_n" -le "$CDG_LINE_MAX_BYTES" ] || deny_too_large

  # Separator normalisation: a backslash-spelled .claude/.codex still denies. A POSIX filename that really
  # holds a backslash is treated as separator-bearing, which can manufacture a segment that was never a
  # directory boundary.
  p="${raw//$cr/}"
  p="${p//\\//}"

  # A literal LF in the path would print as a second stderr line, breaking the exactly-one-line contract.
  # Build a PRINT-ONLY copy by pure parameter expansion (each LF becomes the two characters backslash and
  # n); the classifier keeps matching against $p itself.
  p_disp="${p//$lf/\\n}"

  # ".claude" segment: matched against "/$p/" (a leading AND a trailing slash appended), so the one pattern
  # catches a nested segment, a final segment with nothing after it, and a relative path whose very FIRST
  # segment is ".claude". The bracket classes are the case-insensitive idiom hooks/push-guard.sh uses for
  # config keys.
  case "/$p/" in
    */.[Cc][Ll][Aa][Uu][Dd][Ee]/*)
      printf '%s %s role may not %s a path under a %s segment: %s — record it in your report'"'"'s Reviewer notes instead; see agents/%s.md\n' \
        "$CLAUDE_DIR_DENY_STEM" "$role" "$tool" "$GUARDED_SEGMENT" "$p_disp" "$role" >&2
      exit 2
      ;;
  esac

  # ".codex" segment (#407) -- identical shape and rationale as the ".claude" arm above.
  case "/$p/" in
    */.[Cc][Oo][Dd][Ee][Xx]/*)
      printf '%s %s role may not %s a path under a %s segment: %s — record it in your report'"'"'s Reviewer notes instead; see agents/%s.md\n' \
        "$CLAUDE_DIR_DENY_STEM" "$role" "$tool" "$GUARDED_SEGMENT_CODEX" "$p_disp" "$role" >&2
      exit 2
      ;;
  esac

  # Absoluteness: /... or a Windows or Git Bash drive-letter form (the same [A-Za-z]:/ prefix class as
  # hooks/git-c-guard.sh's PATH_ERE). Anything else cannot be classified and is denied fail closed (see M4).
  case "$p" in
    /*) ;;
    [A-Za-z]:/*) ;;
    *)
      printf '%s %s role'"'"'s %s file_path could not be classified as absolute or normalised, and is denied fail-closed: %s\n' \
        "$CLAUDE_DIR_DENY_STEM" "$role" "$tool" "$p_disp" >&2
      exit 2
      ;;
  esac

  # A ".." segment anywhere is also denied fail closed: a path that is not already normalised must not
  # silently escape a ".claude"/".codex" check that only looks at the literal path string.
  case "$p/" in
    */../*)
      printf '%s %s role'"'"'s %s file_path could not be classified as absolute or normalised, and is denied fail-closed: %s\n' \
        "$CLAUDE_DIR_DENY_STEM" "$role" "$tool" "$p_disp" >&2
      exit 2
      ;;
  esac
}

# deny_patch_unparseable REASON (#407): the apply_patch route's fail-closed exit for a patch this parser
# cannot make sense of (as opposed to a parsed header whose path classify_path denies). Always exits 2.
deny_patch_unparseable() {
  printf '%s %s role'"'"'s apply_patch could not be parsed (%s), and is denied fail-closed\n' \
    "$CLAUDE_DIR_DENY_STEM" "$role" "$1" >&2
  exit 2
}

# ltrim/trim S (#407): strip leading (ltrim) or leading and trailing (trim) spaces and tabs by parameter
# expansion only. The header line loop LEFT-trims only, so a header with nothing after its "<marker>: "
# prefix still matches that marker's case pattern with an empty path and is denied as such, not as an
# unrecognised marker; the extracted path is then full-trimmed. Both sample the deadline, so a $(...) caller
# must propagate a deny. Only ASCII space and tab are stripped: a header preceded by Unicode whitespace
# (U+00A0) is not recognised as a header and is treated as a content line.
ltrim() {
  local s="$1"
  while case "$s" in " "*|"$tab"*) true ;; *) false ;; esac; do
    check_deadline
    case "$s" in
      " "*) s="${s# }" ;;
      "$tab"*) s="${s#"$tab"}" ;;
    esac
  done
  printf '%s' "$s"
}
trim() {
  local s
  s="$(ltrim "$1")"
  [ "$?" -eq 0 ] || exit 2
  while case "$s" in *" "|*"$tab") true ;; *) false ;; esac; do
    check_deadline
    case "$s" in
      *" ") s="${s% }" ;;
      *"$tab") s="${s%"$tab"}" ;;
    esac
  done
  printf '%s' "$s"
}

# parse_patch_headers TOOL PATCH_TEXT CWD (#407): shared by the apply_patch route and the Bash shim route.
# Splits PATCH_TEXT into lines with builtins only (IFS splitting under set -f, so a line starting with the
# grammar literal *** is never globbed), calls classify_path on every Add/Update/Delete/Move-to header path
# (joined to CWD when relative), and fails closed via deny_patch_unparseable on an empty header path, an
# unrecognised *** marker, or zero headers.
parse_patch_headers() {
  local ptool="$1" patch="$2" pcwd="$3" headers=0 oldifs raw_line line hdr_path p
  set -f
  oldifs="$IFS"
  IFS="$lf"
  for raw_line in $patch; do
    check_deadline
    IFS="$oldifs"
    line="$(ltrim "$raw_line")"
    [ "$?" -eq 0 ] || exit 2
    case "$line" in
      "*** Begin Patch"|"*** End Patch"|"*** End of File")
        : # structural marker, not a header; ignored
        ;;
      "*** Add File: "*|"*** Update File: "*|"*** Delete File: "*|"*** Move to: "*)
        hdr_path="$(trim "${line#*: }")"
        [ "$?" -eq 0 ] || exit 2
        [ -n "$hdr_path" ] || { set +f; deny_patch_unparseable "empty header path"; }
        headers=$((headers + 1))
        hdr_path="${hdr_path//\\//}"
        case "$hdr_path" in
          /*|[A-Za-z]:/*) p="$hdr_path" ;;
          *)
            if [ -n "$pcwd" ]; then
              p="$pcwd/$hdr_path"
            else
              p="$hdr_path"
            fi
            ;;
        esac
        classify_path "$ptool" "$p"
        ;;
      "*** "*)
        set +f
        deny_patch_unparseable "unrecognised marker: $line"
        ;;
      *)
        : # content line, ignored
        ;;
    esac
    IFS="$lf"
  done
  set +f
  IFS="$oldifs"
  [ "$headers" -gt 0 ] || deny_patch_unparseable "no file header"
}

# quote_parity_check START END (#455): fail-closed deny when any token toks[START..END] (inclusive, the
# CALLER's toks array through dynamic scope) carries an odd count of single quotes or of double quotes, or
# ends in a backslash. The walk splits a segment on whitespace BEFORE it strips quotes, so a quoted value
# with a space (X='a b') or an escaped one (X=a\ b) arrives as two tokens, and the second would be resolved
# as the command word and hide the shim. It runs only in a segment that mentions the shim and carries a quote
# or backslash (seg_qflag), over tokens the window already walked; no subshell.
quote_parity_check() {
  local j="$1" qraw qa qb
  while [ "$j" -le "$2" ]; do
    check_deadline
    qraw="${toks[$j]:-}"
    qa="${qraw//$sq/}"
    qb="${qa//$dq/}"
    if [ $(( ((${#qraw} - ${#qa}) | (${#qa} - ${#qb})) & 1 )) -eq 1 ]; then
      set +f
      deny_patch_unparseable "command word cannot be resolved: an unbalanced quote precedes it in a segment that mentions apply_patch/applypatch"
    fi
    # A trailing backslash escapes the following space (`X=a\ b`), splitting one word in two just
    # like a quoted space does, and carries no quote for the parity test above to see.
    if [ "${qraw%\\}" != "$qraw" ]; then
      set +f
      deny_patch_unparseable "command word cannot be resolved: an unbalanced quote or a trailing backslash precedes it in a segment that mentions apply_patch/applypatch"
    fi
    j=$((j + 1))
  done
}

# scan_shim_input START STOP (#455): one linear pass over the CALLER's toks[START..STOP) (the tokens after the
# shim word in its own segment), recording in the global iapw_unsafe the first reason the shim's input is NOT
# only an inline << heredoc. Safe: a heredoc operator run (exactly two <, no >) plus its delimiter, an output
# redirect run plus its target, and a bare-digits fd right before an output redirect. Unsafe: a file
# argument, <, <<<, <> (the LAST stdin redirect wins), an fd-numbered input such as 3<<, a heredoc operator
# with no delimiter token (process substitution), and a segment with no heredoc at all (a pipe into a bare
# shim). A heredoc delimiter with a quote or backslash is literal; any other sets iapw_unquoted.
scan_shim_input() {
  local j="$1" k nin nout saw_hd=0 d
  while [ "$j" -lt "$2" ]; do
    check_deadline
    d="${toks[$j]}"
    if [ "$d" = "$mark_in" ] || [ "$d" = "$mark_out" ]; then
      nin=0
      nout=0
      k="$j"
      while [ "$k" -lt "$2" ]; do
        check_deadline
        case "${toks[$k]}" in
          "$mark_in") nin=$((nin + 1)) ;;
          "$mark_out") nout=$((nout + 1)) ;;
          *) break ;;
        esac
        k=$((k + 1))
      done
      if [ "$nin" -eq 2 ] && [ "$nout" -eq 0 ]; then
        if [ "$k" -ge "$2" ]; then
          iapw_unsafe="from a process substitution, or a heredoc operator with no delimiter"
          return 0
        fi
        case "${toks[$k]}" in
          *"$sq"*|*"$dq"*|*\\*) ;;
          *) iapw_unquoted=1 ;;
        esac
        saw_hd=1
      elif [ "$nin" -gt 0 ]; then
        iapw_unsafe="from an input redirect or here-string"
        return 0
      fi
      j=$((k + 1))
      continue
    fi
    if [[ "$d" =~ $digits_ere ]]; then
      case "${toks[$((j + 1))]:-}" in
        "$mark_out") j=$((j + 1)); continue ;;
      esac
    fi
    iapw_unsafe="from an argument"
    return 0
  done
  if [ "$saw_hd" -eq 0 ]; then
    iapw_unsafe="from its standard input, with no heredoc on its own command"
  fi
  return 0
}

# walk_window START STOP (#437): resolves ONE window toks[START..STOP) of the CALLER's local `toks` array,
# read through bash's dynamic scope: it takes no toks parameter and must only be called from
# is_apply_patch_word, which declares toks, mark_in, mark_out, assign_ere, digits_ere, seg_shim_at, seg_qflag
# and seg_mflag in its own scope first. Shared by the base walk (the whole segment) and each ]] tail. It
# records in seg_shim_at the smallest resolved shim index and, in a segment flagged seg_qflag, runs
# quote_parity_check over the tokens it walked (which can exit 2); otherwise it never prints or exits. Two
# globals, not local, are read by the caller:
#   - ww_word: the resolved token with quotes and backslashes stripped, or empty if the window is exhausted
#     first. It is also the first shim-named token found by the #518 or #537 scan, or the shim itself when an
#     env -S string names it (#538).
#   - ww_skipped: 1 when at least one token was consumed by a skip (redirect or fd, assignment, PREFIX_WORDS
#     member with its repeat count, expansion word, dash option after a prefix word, interpreter option with
#     its value); a token left empty by the quote strip does not set it. Only the cut-tail walk reads it, and
#     only when ww_word is empty, to tell "the window held nothing" (benign) from "only skip words, never a
#     real one" (a cut tail, denied fail closed).
#
# #538 fail-closed: a shim name split by quote or backslash characters, a runtime expansion before it, or an
# env -S string. The shell deletes quote and backslash characters inside a word, so apply_"patch" and
# apply\_patch run the shim; a runtime-expansion word may expand to nothing, so `$X apply_patch` runs it; and
# env -S'apply_patch' splits its string into words. (1) Every shim-name comparison deletes backslashes as
# well as quotes (a token that carried one marks its window, ww_alt), and fast path 2, the #503 chain gate and
# the #455 and #518 segment flags all count a split spelling as a mention of the shim, by cdg_split_ere
# (tested on a line only when it carries a quote or a backslash and not the plain name, and on a segment only
# inside a line that names the shim). (2) A token whose basename holds a dollar sign followed by a name
# character, a digit, a special parameter or a quote is skipped like a prefix word, in a segment that mentions
# the shim or carries a quote: a dash-led one opens no context, any other opens the value context (#518) and
# the env context. The skip sits after the dash arm, so `nice -$X 5 apply_patch` still starts the #518 scan.
# (3) After an env word (or a skipped expansion word) an option token is read the way env -S reads its
# string, each backslash-underscore a space, then quotes and backslashes deleted: a space-separated word that
# is the shim, or a first word that is an option glued to the shim name (-Sapply_patch), resolves it, and a
# bare -S or --split-string reads the NEXT token the same way. The reading sits before the #518 scan, so it
# never reads past the token the string is in. (4) A shim resolved through a backslash strip, an expansion
# skip or an env -S string, in a segment flagged for the parity check, runs the #455 check over the WHOLE
# window. Cost: per line at most one regex, per segment at most one, per walked token one backslash
# substitution, one glob and, for a token holding a dollar sign, one regex, and per dash token after an env
# word two single-token reads: no loop grows with the input.
walk_window() {
  local i n tok nxt saw_prefix vp vp_done j vt hit ve ww_alt er
  local ip=0 ipb ipk ipw ipj ipt iph
  i="$1"
  n="$2"
  ww_word=""
  ww_skipped=0
  saw_prefix=0
  vp=0
  ve=0
  ww_alt=0
  vp_done=0
  while [ "$i" -lt "$n" ]; do
    check_deadline
    tok="${toks[$i]}"
    if [ "$tok" = "$mark_in" ] || [ "$tok" = "$mark_out" ]; then
      # A run of operators (>>, <>, <<<) is one redirect: skip every marker in the run, then the single
      # target or source token after it.
      i=$((i + 1))
      while [ "$i" -lt "$n" ] && { [ "${toks[$i]}" = "$mark_in" ] || [ "${toks[$i]}" = "$mark_out" ]; }; do
        check_deadline
        i=$((i + 1))
      done
      i=$((i + 1))
      ww_skipped=1
      continue
    fi
    if [[ "$tok" =~ $digits_ere ]]; then
      nxt="${toks[$((i + 1))]:-}"
      if [ "$nxt" = "$mark_in" ] || [ "$nxt" = "$mark_out" ]; then
        i=$((i + 1))
        ww_skipped=1
        continue
      fi
    fi
    if [[ "$tok" =~ $assign_ere ]]; then
      i=$((i + 1))
      ww_skipped=1
      continue
    fi
    # #437, #538: quote characters and backslashes are stripped from the token before it is matched against
    # PREFIX_WORDS or resolved (a token that carried a backslash marks the window, ww_alt); a token that strips
    # to nothing is skipped without setting ww_skipped.
    tok="${tok//$sq/}"
    tok="${tok//$dq/}"
    case "$tok" in *\\*) tok="${tok//\\/}"; ww_alt=1 ;; esac
    if [ -z "$tok" ]; then
      i=$((i + 1))
      continue
    fi
    case " $PREFIX_WORDS " in
      *" $tok "*)
        saw_prefix=1
        # #518: the value context follows the most recent prefix word (a bare `-` leaves it alone)
        case " $PREFIX_VALUE_WORDS env " in
          *" $tok "*) vp=1 ;;
          *) [ "$tok" = "-" ] || vp=0 ;;
        esac
        # #538: the env context follows the most recent prefix word too (a bare `-` leaves it alone)
        case "$tok" in env) ve=1 ;; -) ;; *) ve=0 ;; esac
        # #537: the interpreter context follows the most recent prefix word too (a bare `-` leaves it alone)
        case " $PREFIX_INTERP_WORDS " in
          *" $tok "*) ip=1 ;;
          *) [ "$tok" = "-" ] || ip=0 ;;
        esac
        [ "$tok" = repeat ] && i=$((i + 1))
        i=$((i + 1))
        continue
        ;;
    esac
    # #537: an option of an interpreter prefix word, classified with globs only (no function call per token;
    # see the #537 block above is_apply_patch_word()). A value option is skipped with its plain value word, a
    # flag alone; anything else triggers ONE scan per window (vp_done, shared with #518) after the next word.
    if [ "$ip" -eq 1 ] && [ "$vp" -eq 0 ] && [ "$ve" -eq 0 ]; then
      case "$tok" in
        --|*/*) ;;
        [-+]?*)
          ipw=""
          [ $((i + 1)) -lt "$n" ] && ipw="${toks[$((i + 1))]}"
          ipk=u
          case "$tok" in
            *\$*) ;;
            *)
              case " $INTERP_VALUE_OPTS " in
                *" $tok "*) ipk=v ;;
                *)
                  ipb="${tok#?}"
                  case "$ipb" in
                    *[!A-Za-z]*) ;;
                    *[oO]*) case "${ipb%?}" in *[oO]*) ;; *) ipk=v ;; esac ;;
                    *) ipk=f ;;
                  esac
                  ;;
              esac
              ;;
          esac
          if [ "$ipk" = f ]; then
            i=$((i + 1)); ww_skipped=1; continue
          fi
          if [ "$ipk" = v ]; then
            case "$ipw" in
              ""|-*|+*|*"$sq"*|*"$dq"*|*\\*|*\$*) ;;
              apply_patch|applypatch|*/apply_patch|*/applypatch|"$mark_in"|"$mark_out") ;;
              *)
                case " $PREFIX_WORDS " in
                  *" $ipw "*) ;;
                  *)
                    if [[ ! $ipw =~ $assign_ere ]]; then
                      i=$((i + 2)); ww_skipped=1; continue
                    fi
                    ;;
                esac
                ;;
            esac
          fi
          if [ "$vp_done" -eq 0 ] && [ "$seg_mflag" -eq 1 ] && [ -n "$ipw" ]; then
            ipt="${ipw//$sq/}"
            ipt="${ipt//$dq/}"
            ipt="${ipt//\\/}"
            case "$ipt" in
              apply_patch|applypatch|*/apply_patch|*/applypatch|""|-*|"$mark_in"|"$mark_out") ;;
              *)
                vp_done=1
                iph=0
                ipj=$((i + 2))
                while [ "$ipj" -lt "$n" ]; do
                  check_deadline
                  ipt="${toks[$ipj]}"
                  if [ "$ipt" != "$mark_in" ] && [ "$ipt" != "$mark_out" ]; then
                    ipt="${ipt//$sq/}"
                    ipt="${ipt//$dq/}"
                    ipt="${ipt//\\/}"
                    case "$ipt" in
                      -*apply_patch|-*applypatch) ipt=apply_patch; iph=1; break ;;
                      apply_patch|applypatch|*/apply_patch|*/applypatch) iph=1; break ;;
                    esac
                  fi
                  ipj=$((ipj + 1))
                done
                if [ "$iph" -eq 1 ]; then
                  # the walk never reached the option's next word or the tokens after it up to the hit;
                  # any of those (a backslash-stripped prefix word, an expansion word, an env -S string)
                  # would have marked the window for the whole-window check, so run it here
                  if [ "$seg_qflag" -eq 1 ]; then
                    quote_parity_check "$1" $((n - 1))
                  fi
                  ww_word="$ipt"
                  i="$ipj"
                  break
                fi
                ;;
            esac
          fi
          case "$tok" in
            *\$*) ;;
            *) i=$((i + 1)); ww_skipped=1; continue ;;
          esac
          ;;
      esac
    fi
    if [ "$saw_prefix" -eq 1 ]; then
      case "$tok" in
        -*)
          # #538: after an env word, an option that reads as an env -S string names the shim (see the #538
          # block above walk_window()). At most two single-token reads, before the #518 scan below so the
          # scan never reads past the token the string sits in.
          if [ "$ve" -eq 1 ] && [ "$seg_mflag" -eq 1 ]; then
            er="${toks[$i]//\\_/ }"
            er="${er//$sq/}"
            er="${er//$dq/}"
            er="${er//\\/}"
            case " $er " in
              *" apply_patch "*|*" applypatch "*|*/apply_patch" "*|*/applypatch" "*) ww_alt=1; ww_word=apply_patch; break ;;
            esac
            case "${er%% *}" in
              -*apply_patch|-*applypatch) ww_alt=1; ww_word=apply_patch; break ;;
            esac
            if { [ "$tok" = "-S" ] || [ "$tok" = "--split-string" ]; } && [ $((i + 1)) -lt "$n" ]; then
              er="${toks[$((i + 1))]//\\_/ }"
              er="${er//$sq/}"
              er="${er//$dq/}"
              er="${er//\\/}"
              case " $er " in
                *" apply_patch "*|*" applypatch "*|*/apply_patch" "*|*/applypatch" "*) ww_alt=1; ww_word=apply_patch; i=$((i + 1)); break ;;
              esac
            fi
          fi
          # #518: a dash token in the value context followed by a non-option word W: W may be that
          # option's value, so look for a shim-named word AFTER W (never W itself: when W names the
          # shim the walk resolves W below, at the smaller index). At most one scan per window.
          if [ "$vp" -eq 1 ] && [ "$vp_done" -eq 0 ] && [ "$seg_mflag" -eq 1 ] && [ $((i + 1)) -lt "$n" ]; then
            vt="${toks[$((i + 1))]}"
            vt="${vt//$sq/}"
            vt="${vt//$dq/}"
            vt="${vt//\\/}"
            case "$vt" in
              ""|-*|"$mark_in"|"$mark_out"|apply_patch|applypatch|*/apply_patch|*/applypatch) ;;
              *)
                vp_done=1
                hit=0
                j=$((i + 2))
                while [ "$j" -lt "$n" ]; do
                  check_deadline
                  vt="${toks[$j]}"
                  if [ "$vt" != "$mark_in" ] && [ "$vt" != "$mark_out" ]; then
                    vt="${vt//$sq/}"
                    vt="${vt//$dq/}"
                    vt="${vt//\\/}"
                    case "$vt" in
                      apply_patch|applypatch|*/apply_patch|*/applypatch) hit=1; break ;;
                      -*apply_patch|-*applypatch) vt=apply_patch; hit=1; break ;;
                    esac
                  fi
                  j=$((j + 1))
                done
                if [ "$hit" -eq 1 ]; then
                  # the hit is past tokens the walk never checked; check every token before it (a
                  # superset of the base check), fail closed
                  if [ "$seg_qflag" -eq 1 ]; then
                    quote_parity_check "$1" $((j - 1))
                  fi
                  ww_word="$vt"
                  i="$j"
                  break
                fi
                ;;
            esac
          fi
          i=$((i + 1)); ww_skipped=1; continue ;;
      esac
    fi
    # #538: a runtime expansion in command position may expand to nothing (hooks/agent-boundary.sh's
    # #508 rule): a token whose basename holds a dollar sign followed by a name character, a digit, a
    # special parameter or a quote is skipped like a prefix word, so the shim behind it still
    # resolves. It opens the value context and the env context (a dash-led one opens neither), and
    # sits AFTER the dash arm above so `nice -$X 5 apply_patch` still starts the #518 scan.
    if [ "$seg_mflag" -eq 1 ]; then
      case "${toks[$i]}" in
        *'$'*)
          if [[ ${toks[$i]##*/} =~ $cdg_rx_ere ]]; then
            ww_alt=1
            saw_prefix=1
            case "${toks[$i]}" in
              -*) ;;
              *) vp=1; ve=1 ;;
            esac
            i=$((i + 1))
            continue
          fi
          ;;
      esac
    fi
    ww_word="$tok"
    break
  done
  [ "$saw_prefix" -eq 1 ] && ww_skipped=1
  # Bookkeeping after the per-token loop. A window that resolved the shim records the SMALLEST resolved index
  # in the caller's seg_shim_at (the input scan starts from the earliest). Any other window, in a segment
  # flagged seg_qflag, runs the unbalanced-quote check over its own already-walked tokens, start through the
  # resolved word (through the window's last token when nothing resolved).
  case "${ww_word##*/}" in
    apply_patch|applypatch)
      # #538: a shim resolved through a backslash strip, an expansion skip or an env -S string runs the
      # unbalanced-quote check over the WHOLE window (a superset of the walk's own check on those routes)
      if [ "$ww_alt" -eq 1 ] && [ "$seg_qflag" -eq 1 ]; then quote_parity_check "$1" $((n - 1)); fi
      if [ "$seg_shim_at" -lt 0 ] || [ "$i" -lt "$seg_shim_at" ]; then
        seg_shim_at="$i"
      fi
      ;;
    *)
      if [ "$seg_qflag" -eq 1 ]; then
        if [ -n "$ww_word" ]; then
          quote_parity_check "$1" "$i"
        else
          quote_parity_check "$1" $((n - 1))
        fi
      fi
      ;;
  esac
}

# cdg_chain_line LINE (#503): the additive chain pass for one physical line of the Bash command. The base
# segmenter in is_apply_patch_word() cuts a line at every break character before it looks at quoting, so a
# break character inside a quote or a command substitution leaves the shim in a segment whose first word is
# junk (X='a;b c' apply_patch < x.patch), and the parity check never sees the opening quote. This function
# lexes the line sequentially (single and double quotes, dollar-single-quote, backslash escapes, an unquoted
# # at a word start outside any substitution, which ends the lexing, and a stack of dollar-paren,
# dollar-brace and backtick frames), classifies every break character as a head break (a real command
# break), a literal break (quoted or escaped, which joins the chain) or a frame open or close, and prints,
# into the global cdg_chain_out, one text per chain that joins two or more segments. The caller appends those
# texts to its segment list, so the unchanged walk, ]] pass, parity check and shim input scan judge each as
# a segment. In a chain text a token that ends at a quoted or escaped separator or at a literal break
# carries a trailing backslash (the cut marker, which the parity check reads as a quoted span split here),
# and a substitution is the expansion word dollar-underscore when glued to a word and the inert word
# underscore when it starts a word. Quote state never crosses a physical line, so a heredoc body or prose
# line is not poisoned by an earlier line. The caller gates it to a line that names the shim, carries a
# quote, backslash, backtick, $( or ${, and holds a break character. Cost: one deadline sample per character
# on a line capped at CDG_LINE_MAX_BYTES (scoped LC_ALL=C, so indexing is by byte), O(line) iterations plus
# O(line squared) byte copies at most; only gated lines pay it.
cdg_chain_out=""
cdg_chain_line() {
  local ln="$1" LC_ALL=C
  local n="${#ln}" i=0 c nx lq=0 ld=0 pd=0 cur="" mul=0 qd act last ph
  local -a stx smu fk fsv fcn
  cdg_chain_out=""
  while [ "$n" -gt "$i" ]; do
    check_deadline
    c="${ln:$i:1}"
    i=$((i + 1))
    qd=0
    act=plain
    case "$lq" in
      0)
        case "$c" in
          "$sq") if [ "$pd" -eq 1 ]; then lq=3; else lq=1; fi; cur="$cur$c"; pd=0; continue ;;
          "$dq") lq=2; cur="$cur$c"; pd=0; continue ;;
          '\') cur="$cur$c"; pd=0
               if [ "$i" -lt "$n" ]; then c="${ln:$i:1}"; i=$((i + 1)); qd=2; else continue; fi ;;
          '$') cur="$cur$c"; pd=1; continue ;;
          '#') last="${cur: -1}"
               if [ "$ld" -eq 0 ] && { [ -z "$cur" ] || [ "$last" = " " ] || [ "$last" = "$tab" ] || [ "$last" = "<" ] || [ "$last" = ">" ]; }; then break; fi ;;
        esac ;;
      1)
        case "$c" in
          "$sq") lq=0; cur="$cur$c"; pd=0; continue ;;
          *) qd=1 ;;
        esac ;;
      2)
        case "$c" in
          "$dq") lq=0; cur="$cur$c"; pd=0; continue ;;
          '\') cur="$cur$c"; pd=0
               nx="${ln:$i:1}"
               if [ "$i" -lt "$n" ] && { [ "$nx" = '$' ] || [ "$nx" = '`' ] || [ "$nx" = "$dq" ] || [ "$nx" = '\' ]; }; then
                 c="$nx"; i=$((i + 1)); qd=2
               else continue; fi ;;
          '$') cur="$cur$c"; pd=1; continue ;;
          '`') ;;
          '('|'{') if [ "$pd" -eq 0 ]; then qd=1; fi ;;
          *) qd=1 ;;
        esac ;;
      3)
        case "$c" in
          "$sq") lq=0; cur="$cur$c"; pd=0; continue ;;
          '\') cur="$cur$c"; pd=0
               if [ "$i" -lt "$n" ]; then c="${ln:$i:1}"; i=$((i + 1)); qd=2; else continue; fi ;;
          *) qd=1 ;;
        esac ;;
    esac
    # classify the character
    case "$c" in
      ' '|"$tab") if [ "$qd" -eq 0 ]; then act=sep; else act=qsep; fi ;;
      '<'|'>') if [ "$qd" -eq 0 ]; then act=sep; else act=qsep; fi ;;
      ';'|'&'|'|') if [ "$qd" -eq 0 ]; then act=head; else act=lit; fi ;;
      '(')
        if [ "$qd" -ne 0 ]; then act=lit
        elif [ "$pd" -eq 1 ]; then act=openp
        else
          if [ "$ld" -gt 0 ] && [ "${fk[$ld]}" = P ]; then fcn[$ld]=$(( ${fcn[$ld]} + 1 )); fi
          act=head
        fi ;;
      ')')
        if [ "$qd" -ne 0 ]; then act=lit
        elif [ "$ld" -gt 0 ] && [ "${fk[$ld]}" = P ]; then
          if [ "${fcn[$ld]}" -gt 0 ]; then fcn[$ld]=$(( ${fcn[$ld]} - 1 )); act=head; else act=close; fi
        else act=head; fi ;;
      '{')
        if [ "$qd" -ne 0 ]; then act=lit
        elif [ "$pd" -eq 1 ]; then act=openb
        else
          if [ "$ld" -gt 0 ] && [ "${fk[$ld]}" = B ]; then fcn[$ld]=$(( ${fcn[$ld]} + 1 )); fi
          act=head
        fi ;;
      '}')
        if [ "$qd" -ne 0 ]; then act=lit
        elif [ "$ld" -gt 0 ] && [ "${fk[$ld]}" = B ]; then
          if [ "${fcn[$ld]}" -gt 0 ]; then fcn[$ld]=$(( ${fcn[$ld]} - 1 )); act=head; else act=close; fi
        else act=head; fi ;;
      '`')
        if [ "$qd" -ne 0 ]; then act=lit
        elif [ "$lq" -eq 0 ] && [ "$ld" -gt 0 ] && [ "${fk[$ld]}" = T ]; then act=close
        else act=opent; fi ;;
    esac
    case "$act" in
      plain) cur="$cur$c"; pd=0 ;;
      sep) cur="$cur$c"; pd=0 ;;
      qsep)
        case "$c" in
          ' '|"$tab") ph="$c" ;;
          *) ph=" " ;;
        esac
        last="${cur: -1}"
        if [ "$qd" -eq 2 ]; then cur="$cur$ph"
        else
          case "$last" in
            ''|' '|"$tab"|'<'|'>') ;;
            *) cur="$cur\\$ph" ;;
          esac
        fi
        pd=0 ;;
      lit)
        mul=1
        last="${cur: -1}"
        if [ "$qd" -eq 2 ]; then cur="$cur "
        else
          case "$last" in
            ''|' '|"$tab"|'<'|'>') ;;
            *) cur="$cur\\ " ;;
          esac
        fi
        pd=0 ;;
      head)
        if [ "$mul" -eq 1 ] && [ -n "$cur" ]; then cdg_chain_out="$cdg_chain_out$cur$lf"; fi
        cur=""; mul=0; pd=0 ;;
      openp|openb|opent)
        if [ "$act" != opent ]; then cur="${cur%?}"; fi
        last="${cur: -1}"
        if [ -z "$cur" ] || [ "$last" = " " ] || [ "$last" = "$tab" ] || [ "$last" = "<" ] || [ "$last" = ">" ]; then ph="_"; else ph='$_'; fi
        cur="$cur$ph"
        ld=$((ld + 1))
        stx[$ld]="$cur"; smu[$ld]=1; fsv[$ld]="$lq"; fcn[$ld]=0
        case "$act" in
          openp) fk[$ld]=P ;;
          openb) fk[$ld]=B ;;
          *) fk[$ld]=T ;;
        esac
        cur=""; mul=0; lq=0; pd=0 ;;
      close)
        if [ "$mul" -eq 1 ] && [ -n "$cur" ]; then cdg_chain_out="$cdg_chain_out$cur$lf"; fi
        cur="${stx[$ld]}"; mul="${smu[$ld]}"; lq="${fsv[$ld]}"
        ld=$((ld - 1)); pd=0 ;;
    esac
  done
  # unwinding the open frames takes at most one pass per frame, and frames are bounded by the line
  # (CDG_LINE_MAX_BYTES), so this loop needs no deadline sample of its own
  while :; do
    if [ "$mul" -eq 1 ] && [ -n "$cur" ]; then cdg_chain_out="$cdg_chain_out$cur$lf"; fi
    [ "$ld" -gt 0 ] || break
    cur="${stx[$ld]}"; mul="${smu[$ld]}"
    ld=$((ld - 1))
  done
}

# is_apply_patch_word TEXT (#407, #437): true iff TEXT (a whole tool_input.command, possibly multi-line) has
# a segment whose RESOLVED command word is exactly apply_patch or applypatch, or a path-qualified spelling
# matched by basename. It tells the command word from the same text as an argument (rg apply_patch hooks/)
# or inside quotes, neither of which this walk treats as a leading token. Pure builtins (parameter-expansion
# substitution splits segments and words; [[ =~ ]] matches an assignment prefix or a bare-digits fd), no
# execve. It memoises its verdict (iapw_memo) and fills the globals iapw_unsafe and iapw_unquoted.
#
# Segments and words. Segment breaks (the set hooks/agent-boundary.sh uses): ; & | ( ) { } and a backtick; a
# gated line's segment list also carries the chain texts of cdg_chain_line() (#503). Word breaks within a
# segment: whitespace plus < and >, each replaced by a padded sentinel word (mark_in, mark_out) so
# walk_window still sees WHERE a redirect was: a redirect never starts a segment, but it separates a command
# word from a glued target (apply_patch<x.patch), and a LEADING redirect or a bare-digits fd right before one
# (2>/dev/null apply_patch) is skipped as a unit and cannot hide the command word. walk_window skips, in
# order: a NAME=value assignment; a PREFIX_WORDS member (repeated, so `if true; then apply_patch < x.patch;
# fi` resolves past then; repeat also skips its count token); then, once a prefix word was seen, a dash-led
# option of that word (refined by the #518, #537 and #538 rules below); a runtime-expansion word (#538). The
# first token surviving every skip is the resolved word, compared in full and by basename.
#
# ]] pass (#437). A segment whose raw text carries a literal ]] is ALSO walked one more way, in pure bash:
# every standalone ]] splits the segment into disjoint tails, so the zsh short form `if [[ cond ]]
# apply_patch < x.patch` resolves the text after each ]] as its own candidate command word. Tails end at the
# NEXT standalone ]] (or the segment's end), so their combined cost is bounded by the segment's token count.
# A segment with more than DBRACKET_MAX standalone ]] denies unconditionally as soon as the excess one is
# seen. A CUT tail (one ended by a following ]], never the final tail) that consumes a skip token without
# resolving a word (ww_skipped=1, empty ww_word) also denies, fail closed (env -u ]] -i apply_patch). A cut
# tail that DOES resolve the shim just marks it found: the checks in the Bash route below all read the WHOLE
# command text, so cutting the command-word search hides nothing they use.
#
# #455 shim input. The input scan (scan_shim_input) starts after the smallest shim index any window resolved
# and runs once per segment to its end, stopping at the first unsafe token. An unquoted heredoc delimiter
# (iapw_unquoted) is judged once at the end against the whole text: $, a backtick or a backslash anywhere
# makes it unsafe, since the shell expands the body first. quote_parity_check runs in a segment that mentions
# the shim and carries a quote or backslash.
#
# #518 fail-closed: a value-taking option of a prefix word. A dash option of a PREFIX_VALUE_WORDS member, or
# of env (this walk models no env option grammar beyond the -S string of #538), may take the NEXT word as its
# value (nice -n 5 apply_patch < x.patch), so the walk, which skipped the option but not the value, resolved
# the value instead. While the most recent prefix word is in that set, a dash token followed by a word that is
# not an option, not a redirect marker and not itself shim-named triggers ONE scan per window (vp_done) of the
# tokens after that word, in a segment that mentions the shim or carries a quote (seg_mflag): the first
# shim-named token (quote- and backslash-stripped, compared by basename; a dash token ending in the shim name
# counts too) becomes the resolved word. A value word that itself names the shim is excluded from the
# trigger: the walk resolves it at the smaller index, so the scan never moves seg_shim_at later. A scan hit
# in a flagged segment (seg_qflag) first runs the #455 parity check over every token before the hit. Cost: at
# most one scan per window, so the base window and the disjoint ]] tails scan at most twice the segment's
# tokens, each token costing one deadline sample, two quote strips, one backslash strip and one glob.
#
# #537 fail-closed: an option of an interpreter prefix word. Interpreters stay out of PREFIX_VALUE_WORDS (the
# value of bash -c IS the command string, and scanning past it would deny `bash -e -o pipefail -c echo
# apply_patch`), so their options are classified, with case globs only (no function call per token: bash 3.2
# makes a call expensive while this walk's frame is large). While the most recent prefix word is in
# PREFIX_INTERP_WORDS (a bare - leaves it alone), a token that starts with a dash or plus, is longer than one
# character, is not -- and holds no slash is one of three kinds. A VALUE option is a member of
# INTERP_VALUE_OPTS, or a dash or plus followed by letters of which exactly one is o or O and it is the last
# (-o, +O, -eo): it is skipped together with the NEXT word, but only when that word is plain (not empty, not
# dash- or plus-led, no quote, backslash or dollar sign, not a redirect marker, not shim-named, not an
# assignment, not a PREFIX_WORDS member). A FLAG is a dash or plus followed by letters with no o or O (-e, -c,
# -lc, +e), skipped alone. Anything else is UNCLASSIFIED (two value letters, a value letter that is not last,
# an unlisted long option, a non-letter, or a value option whose next word failed the test): when the next
# word is no option, no redirect marker and not shim-named, ONE scan per window (vp_done, shared with the
# #518 scan) looks for a shim-named token after that word, in a segment flagged seg_mflag; a hit runs the
# #455 parity check over the WHOLE window (the walk never reached the tokens up to the hit, and any
# backslash-stripped prefix word, expansion word or env -S string among them would have marked the window on
# its own), and the option is then skipped alone. A next word that names the shim is never skipped and never
# scanned past. A token holding a dollar sign is never skipped by this rule, a token with a slash or the bare
# -- keeps the walk it had (`bash +/apply_patch < x.patch` still resolves by basename), and an expansion word
# that reopened the value or env context after the interpreter leaves the option to the dash arm, which
# scans. A word is skipped only when the old walk, which took it for the resolved word, could not have
# resolved the shim through it, so no deny turns into an allow. Cost: a constant number of case globs and
# two #? / %? strips per option token; at most one scan per window.
#
# Memoised (#437): both call sites in the Bash route below pass the identical text, so the global iapw_memo
# (empty until the first call in this process) short-circuits the second call.
iapw_memo=""
# Globals is_apply_patch_word fills while it walks (not local, so the Bash route reads them after the call,
# including on a memoised return): iapw_unsafe holds the first reason a shim segment's input is not only an
# inline heredoc (empty when every shim segment is safe), and iapw_unquoted is 1 once any shim heredoc has an
# unquoted delimiter.
iapw_unsafe=""
iapw_unquoted=0
is_apply_patch_word() {
  local text="$1" ln flat seg base oldifs found=1
  local mark_in=$'\x01LT\x01' mark_out=$'\x01GT\x01'
  local assign_ere='^[A-Za-z_][A-Za-z0-9_]*='
  local digits_ere='^[0-9]+$'
  local db_n k prev t
  local ln_m=0
  local seg_shim_at=-1 seg_qflag=0 seg_mflag=0

  if [ -n "$iapw_memo" ]; then
    return "$iapw_memo"
  fi

  # NOTE: a literal "{" or "}" inside a ${var//[...]/...} bracket expression confuses bash's own parser (it
  # can misread the inner "}" as closing the "${" construct itself, corrupting the pattern and everything
  # after it, measured under both bash 5 and Apple bash 3.2), so "{" and "}" are substituted in their own
  # separate statements rather than folded into the bracket expression below.
  # Every substitution below runs on ONE physical line at a time, never on the whole command text (bash
  # 3.2's ${x//pat/repl} is superlinear in the text's length and match count, and a newline is itself a
  # segment break, so line by line gives the identical segments). Each line is at most CDG_LINE_MAX_BYTES
  # bytes (cdg_prepare_text, run on the command first, denies a longer one), and the loop below samples the
  # deadline before every line.
  oldifs="$IFS"
  set -f
  IFS="$lf"
  for ln in $text; do
    check_deadline
    # An fd duplication (`>&2`, `2>&1`, `<&0`, `>&-`) keeps its `&` as part of the redirect instead of
    # acting as a segment break below.
    ln="${ln//>&/>}"
    ln="${ln//<&/<}"
    # `>|` (noclobber override) is one redirect operator too; its `|` must not split the segment.
    ln="${ln//>|/>}"
    flat="${ln//[;\&\|()\`]/$lf}"
    flat="${flat//\{/$lf}"
    flat="${flat//\}/$lf}"
    # Does the line name the shim (#538): ln_m is 1 for the plain spelling, 2 for a split one (quote or
    # backslash characters inside the name, one regex over the line), 0 otherwise.
    ln_m=0
    case "$ln" in
      *applypatch*|*apply_patch*)
        ln_m=1
        ;;
      *"$sq"*|*"$dq"*|*\\*)
        [[ $ln =~ $cdg_split_ere ]] && ln_m=2
        ;;
    esac
    # The additive chain pass (#503): only a line that names the shim, carries a quote, a backslash, a
    # backtick or a dollar-paren / dollar-brace, and holds a break character is lexed. Its chain texts join
    # the segment list, so the unchanged loop below judges each like a segment.
    case "$ln_m" in
      1|2)
        case "$ln" in
          *"$sq"*|*"$dq"*|*\\*|*\`*|*'$('*|*'${'*)
            case "$ln" in
              *[\;\&\|\(\)\`]*|*\{*|*\}*)
                cdg_chain_line "$ln"
                flat="$flat$lf$cdg_chain_out"
                ;;
            esac
            ;;
        esac
        ;;
    esac
    flat="${flat//</ $mark_in }"
    flat="${flat//>/ $mark_out }"
    # The segment loop's body below keeps its old indentation on purpose: the mutant registry's from texts
    # match it.
    IFS="$lf"
    for seg in $flat; do
    check_deadline
    IFS="$oldifs"
    local -a toks
    toks=($seg)
    local n="${#toks[@]}"
    seg_shim_at=-1
    seg_qflag=0
    seg_mflag=0
    case "$seg" in
      *apply_patch*|*applypatch*)
        seg_mflag=1
        case "$seg" in
          *"$sq"*|*"$dq"*|*\\*) seg_qflag=1 ;;
        esac
        ;;
      *"$sq"*|*"$dq"*) seg_mflag=1 ;;
    esac
    # A segment of a line that names the shim which itself spells the shim split by quote or backslash
    # characters (and not plainly) is flagged like one that mentions it: the parity check and, for a
    # backslash-only spelling, the value scan (quoted ones are scanned already).
    if [ "$ln_m" -ne 0 ] && [ "$seg_qflag" -eq 0 ]; then
      case "$seg" in
        *applypatch*|*apply_patch*) ;;
        *"$sq"*|*"$dq"*|*\\*)
          if [[ $seg =~ $cdg_split_ere ]]; then
            seg_qflag=1
            case "$seg" in
              *"$sq"*|*"$dq"*) ;;
              *) seg_mflag=1 ;;
            esac
          fi
          ;;
      esac
    fi

    walk_window 0 "$n"
    base="${ww_word##*/}"
    case "$base" in
      apply_patch|applypatch) found=0 ;;
    esac

    # The additive ]]-cut pass (#437), gated so a segment without a literal ]] costs what it cost before:
    # toks is walked once, by the base walk above, and never re-walked.
    case "$seg" in
      *']]'*)
        db_n=0
        prev=-1
        k=0
        for t in "${toks[@]}"; do
          check_deadline
          if [ "$t" = "]]" ]; then
            db_n=$((db_n + 1))
            if [ "$db_n" -gt "$DBRACKET_MAX" ]; then
              set +f
              IFS="$oldifs"
              deny_patch_unparseable "too many standalone ]] tokens to analyse"
            fi
            if [ "$prev" -ge 0 ]; then
              walk_window $((prev + 1)) "$k"
              base="${ww_word##*/}"
              case "$base" in
                apply_patch|applypatch) found=0 ;;
              esac
              if [ -z "$ww_word" ] && [ "$ww_skipped" -eq 1 ]; then
                set +f
                IFS="$oldifs"
                deny_patch_unparseable "command word split by ]] cannot be resolved"
              fi
            fi
            prev="$k"
          fi
          k=$((k + 1))
        done
        if [ "$prev" -ge 0 ]; then
          walk_window $((prev + 1)) "$n"
          base="${ww_word##*/}"
          case "$base" in
            apply_patch|applypatch) found=0 ;;
          esac
        fi
        ;;
    esac
    # The shim's own segment (#455): scan its input once, from the smallest resolved shim index, unless an
    # earlier segment already recorded an unsafe input.
    if [ "$seg_shim_at" -ge 0 ] && [ -z "$iapw_unsafe" ]; then
      scan_shim_input $((seg_shim_at + 1)) "$n"
    fi
    IFS="$lf"
    done
  done
  set +f
  IFS="$oldifs"
  # An unquoted heredoc delimiter lets the shell expand the body before the shim reads it, so the patch the
  # hook parsed is not the patch the shim applies whenever the command carries anything expandable.
  if [ -z "$iapw_unsafe" ] && [ "$iapw_unquoted" -eq 1 ]; then
    case "$text" in
      *'$'*|*'`'*|*\\*) iapw_unsafe="through an unquoted heredoc delimiter, whose body the shell expands first" ;;
    esac
  fi
  iapw_memo="$found"
  return "$found"
}

# has_exact_begin_patch_line TEXT (#407): true iff some line of TEXT, full-trimmed, equals EXACTLY
# "*** Begin Patch". A substring match alone would deny a benign command that merely MENTIONS the marker
# (grep -rn '*** Begin Patch' hooks/, a commit message). Pure builtins, the same IFS-splitting idiom as
# parse_patch_headers; never executes anything.
has_exact_begin_patch_line() {
  local text="$1" oldifs raw_line line found=1
  set -f
  oldifs="$IFS"
  IFS="$lf"
  for raw_line in $text; do
    check_deadline
    IFS="$oldifs"
    line="$(trim "$raw_line")"
    [ "$?" -eq 0 ] || exit 2
    [ "$line" = "*** Begin Patch" ] && found=0
    IFS="$lf"
  done
  set +f
  IFS="$oldifs"
  return "$found"
}

# cdg_prepare_text TEXT [MODE] (#457): run once on the Bash route's command (MODE "all", the default) AND on
# the apply_patch route's patch text (MODE "native"), before any substitution on either, under a scoped
# LC_ALL=C so every length is a BYTE count. It denies (deny_too_large) a text longer than CDG_TEXT_MAX_BYTES
# before any split, and a physical line longer than CDG_LINE_MAX_BYTES (in MODE "native" only a line holding
# a CR or a `*** ` marker; any other line is bounded by the whole-text cap), and sets the global cdg_text to
# TEXT with every CR stripped LINE BY LINE (a whole-text ${x//$cr/} is superlinear in the CR count under bash
# 3.2; blank lines are dropped only when a CR was present, which no later consumer distinguishes, since each
# reads its text with IFS-splitting on LF). The loop samples the deadline before every line.
cdg_text=""
cdg_prepare_text() {
  local text="$1" mode="${2:-all}" ln lmax oldifs="$IFS" hascr=0 out=""
  local LC_ALL=C
  [ "${#text}" -le "$CDG_TEXT_MAX_BYTES" ] || deny_too_large
  case "$text" in
    *"$cr"*) hascr=1 ;;
  esac
  set -f
  IFS="$lf"
  for ln in $text; do
    check_deadline
    lmax="$CDG_LINE_MAX_BYTES"
    if [ "$mode" = native ]; then
      case "$ln" in
        *"$cr"*|*"*** "*) ;;
        *) lmax="$CDG_TEXT_MAX_BYTES" ;;
      esac
    fi
    [ "${#ln}" -le "$lmax" ] || deny_too_large
    if [ "$hascr" -eq 1 ]; then
      ln="${ln//$cr/}"
      out="$out$ln$lf"
    fi
  done
  set +f
  IFS="$oldifs"
  if [ "$hascr" -eq 0 ]; then
    cdg_text="$text"
  else
    cdg_text="$out"
  fi
}

if [ "$tool_name" = "apply_patch" ]; then
  # Codex's file-editing tool call: tool_input.command holds the WHOLE patch text (Codex's own patch
  # grammar), and there is no file_path at all (see the Codex apply_patch probe in the header).
  patch_cmd="$(printf '%s' "$input" | jq -r '.tool_input.command? // empty' 2>/dev/null)"
  [ -n "$patch_cmd" ] || deny_patch_unparseable "no command"

  cwd="$(printf '%s' "$input" | jq -r '.cwd? // empty' 2>/dev/null)"
  cdg_bytes "$cwd"
  [ "$cdg_n" -le "$CDG_LINE_MAX_BYTES" ] || deny_too_large
  cwd="${cwd//$cr/}"
  cwd="${cwd//\\//}"

  # Strip every CR from the patch up front (#270 idiom; see the shared cr/lf/tab note above) --
  # every line handled below is then CR-free. #457: line by line, after the per-line size cap, in a
  # sampled loop (cdg_prepare_text, MODE native), never as one whole-text substitution.
  cdg_prepare_text "$patch_cmd" native
  patch="$cdg_text"
  parse_patch_headers "apply_patch" "$patch" "$cwd"
elif [ "$tool_name" = "Bash" ]; then
  # --- Bash apply_patch-shim route (#407 amendment A1) ------------------------------------------
  # Codex also puts an apply_patch/applypatch shim on the shell PATH; a shell-issued `apply_patch <<'EOF'`
  # heredoc (or a bare `apply_patch < x.patch`) reaches THIS hook as an ordinary Bash call, with the whole
  # heredoc body (if any) inlined into tool_input.command (see the Codex shim probe in the header).
  bash_cmd="$(printf '%s' "$input" | jq -r '.tool_input.command? // empty' 2>/dev/null)"
  [ -n "$bash_cmd" ] || exit 0
  # The per-line size cap and the per-line CR strip (#457), BEFORE any other substitution on the command text.
  cdg_prepare_text "$bash_cmd"
  bash_cmd="$cdg_text"

  # Belt and braces: evaluated FIRST and UNCONDITIONALLY, before either branch below, whenever
  # apply_patch/applypatch is the resolved command word anywhere in the text. A decoy can defeat
  # has_exact_begin_patch_line (an ANSI-C-quoted line whose "\n"s are the two literal characters backslash
  # and n, never a real line break; or a genuine SECOND real line with a benign header next to a first
  # header hidden behind Unicode whitespace ltrim() never strips) while still mentioning .claude or .codex
  # in the raw text; this catch-all does not depend on the structured parse recognising anything.
  if is_apply_patch_word "$bash_cmd"; then
    case "$bash_cmd" in
      *.[Cc][Ll][Aa][Uu][Dd][Ee]*|*.[Cc][Oo][Dd][Ee][Xx]*)
        deny_patch_unparseable "apply_patch/applypatch invoked via Bash mentioning a .claude/.codex path anywhere in the raw command text"
        ;;
    esac
  fi

  if has_exact_begin_patch_line "$bash_cmd"; then
    # The command text carries an inline patch. When the shim is invoked with an input that is not only its
    # own inline heredoc (a file, a redirect, a pipe, a here-string, an unquoted delimiter on an expandable
    # command; #455), the inline patch found here may be an unrelated decoy while the shim applies something
    # this hook never sees, so deny BEFORE the structured parse trusts it. Otherwise parse the inline patch
    # exactly like the apply_patch route, resolved against the SAME top-level cwd field; this gives the
    # precise .claude/.codex message whenever the structured patch itself names one and the belt-and-braces
    # check above did not already deny.
    if is_apply_patch_word "$bash_cmd" && [ -n "$iapw_unsafe" ]; then
      deny_patch_unparseable "apply_patch/applypatch invoked via Bash takes its patch $iapw_unsafe, not from an inline heredoc this hook parsed"
    fi
    cwd="$(printf '%s' "$input" | jq -r '.cwd? // empty' 2>/dev/null)"
    cdg_bytes "$cwd"
    [ "$cdg_n" -le "$CDG_LINE_MAX_BYTES" ] || deny_too_large
    cwd="${cwd//$cr/}"
    cwd="${cwd//\\//}"
    parse_patch_headers "Bash" "$bash_cmd" "$cwd"
  elif is_apply_patch_word "$bash_cmd"; then
    # The shim was invoked as the command word, but no line's trimmed text was EXACTLY "*** Begin Patch", so
    # the structured parse never ran, and the belt-and-braces check found no .claude/.codex mention either:
    # the shim was invoked with no inline patch text this hook can see (e.g. `apply_patch < x.patch`, reading
    # a file this hook never opens). The hook cannot verify what it writes, so it denies fail closed.
    deny_patch_unparseable "apply_patch/applypatch invoked via Bash with no inline patch text"
  fi
  # else: apply_patch/applypatch appears only as an argument or inside quoted text (e.g. `rg apply_patch
  # hooks/`) -- no opinion; not this hook's concern.
else
  # --- Edit/Write route (unchanged behaviour) ---------------------------------------------------
  file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path? // empty' 2>/dev/null)"
  [ -n "$file_path" ] || exit 0
  classify_path "$tool_name" "$file_path"
fi

exit 0
