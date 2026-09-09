#!/usr/bin/env bash
#
# agent-boundary.sh — plugin-shipped PreToolUse hook (#235, review F3) that mechanically enforces
# the implementer/verifier subagents' "no git, no gh" boundary, which was previously prompt-only
# (README's Safety model, before this issue). Reads the hook's stdin JSON; for a Bash tool call
# issued by the implementer subagent, denies (exit 2, one stderr line, empty stdout) any command
# whose parsed command-position word resolves to `git` or `gh`; for the verifier subagent, denies
# `gh` outright and denies `git` unless the resolved subcommand is on VERIFIER_GIT_READONLY below
# (fail closed: an unlisted subcommand, a global option before the subcommand, and a bare `git`
# all deny). Every other case — main session (no agent_type), any other agent, `permission_mode:
# "plan"`, malformed stdin, another tool, or `tool_input.command` absent — is "no opinion" (exit
# 0, empty stdout, empty stderr), the same convention hooks/git-c-guard.sh already uses. Never
# executes anything (no git, no gh, nothing derived from the untrusted command string), never
# `eval`s, never writes a file. bash + jq + POSIX awk only — no python, no perl, no GNU-only
# flags (this repo's CLAUDE.md portability convention); exercised under Apple's bash 3.2 by the
# selfcheck-macos CI job, same as bin/*.sh and hooks/git-c-guard.sh.
#
# Tokenizer cross-reference (#260): hooks/push-guard.sh inlines a near-twin of "the scan" below
# (same segment-break characters, same normalize(), same repeat-until-exhausted PREFIX_WORDS
# skip) for its own, different emitter. A future fix to the shared behaviour must be applied to
# BOTH files — dev/selfcheck.sh's assertion 4.40 clause (c) mechanically pins the two scripts'
# PREFIX_WORDS vocabulary stays byte-identical.
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
# denies, in which case print exactly one reason line to stderr and exit 2 ("deny"); stdout is
# always empty. Wired in hooks/hooks.json via `${CLAUDE_PLUGIN_ROOT}`, with no `if` gate (the `if`
# field is permission-rule syntax over tool input only — it cannot see `agent_type`, so any `if`
# here would silence the boundary for exactly the commands it exists to block).
set -uo pipefail

# --- vocabulary --------------------------------------------------------------------------------
# Grep-extractable single-line KEY="value" declarations (the 2.5/4.36/4.37/4.38 idiom) — kept on
# their own lines with this exact shape so dev/selfcheck.sh's assertion 4.39 can extract the two
# AGENT_TYPES_* lines mechanically.
AGENT_TYPES_IMPLEMENTER="implementer trail-blazer-flow:implementer"
AGENT_TYPES_VERIFIER="verifier trail-blazer-flow:verifier"
VERIFIER_GIT_READONLY="status diff log show rev-parse ls-files merge-base blame grep restore"
BLOCKED_COMMANDS="git gh"
PREFIX_WORDS="env command builtin exec sudo nohup time nice stdbuf xargs bash sh zsh ksh dash"
DENY_STEM="trail-blazer-flow agent boundary:"

input="$(cat)"

# --- fast paths ----------------------------------------------------------------------------
# Both are pure performance optimisations, each semantics-preserving with the check it stands in
# for below EXCEPT for a command word split by quote or backslash characters (see fast path 2's
# own note) — a documented limit of the same tripwire class as the scan's other quote-blind
# behaviour, not a security boundary by itself. A miss on either fast path always means "this call
# is out of scope for this hook", which is also what the slower checks below it would conclude.
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

# Fast path 2: this hook only ever denies a command whose command-position word is literally
# "git" or "gh" — if neither substring appears anywhere in the raw stdin at all, no segment of
# tool_input.command could possibly resolve to either, so skip the jq/awk spawn. Semantics-
# preserving except for a command word split by quote or backslash characters: normalize() (below)
# strips those characters before comparing, so e.g. `g"i"t push` normalises to "git" while the raw
# stdin substring "git" never appears — this fast path exits silently where the slower scan would
# have denied. Documented, not fixed, for the same "tripwire, not a sandbox" reason as the scan's
# other quote-blind behaviour.
case "$input" in
  *git*|*gh*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

tool_name="$(printf '%s' "$input" | jq -r '.tool_name? // empty' 2>/dev/null)"
[ "$tool_name" = "Bash" ] || exit 0

# Role resolution: exact string match against space-delimited membership (the sub_allowed idiom
# at hooks/git-c-guard.sh:149-154) — no match, empty, or absent agent_type all resolve to no role,
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
# Per line: every one of `; & | ( ) { } `` (the eight segment-break characters) starts a new
# segment; `<`/`>` are ordinary token separators (not segment breaks) — a Bash redirection never
# starts a new command. Within each segment, tokens are walked from the start:
#   - a token matching ^[A-Za-z_][A-Za-z0-9_]*= (an assignment prefix, e.g. FOO=1) is skipped;
#   - a token whose normalised form (quote/backslash characters stripped; basename taken after the
#     last '/') is a member of PREFIX_WORDS is skipped, and a "saw prefix" flag is set;
#   - once that flag is set, a further token starting with '-' is also skipped (an option to the
#     prefix word, e.g. `bash -c`, `xargs -I{}`);
#   - the first token that survives all three skips is the segment's command word, emitted in its
#     normalised form. If it is exactly "git", the token(s) after it are walked once more to
#     resolve the subcommand: a "-C" token is skipped together with the token right after it (a
#     worktree path); any OTHER token starting with '-' seen before a subcommand is found emits
#     the sentinel "-globalopt-" (fail-closed for the verifier: an unrecognised global option
#     could be anything, including one that mutates); no subcommand at all emits "-none-" (a bare
#     `git`, also fail-closed for the verifier). "git <subcommand>" is emitted for a git command
#     word, or the bare command word otherwise. A segment with no surviving token (blank, or only
#     assignments/prefix words) emits nothing.
scan_out="$(printf '%s\n' "$cmd" | awk -v prefix_words="$PREFIX_WORDS" '
BEGIN {
  sq = sprintf("%c", 39)
  n = split(prefix_words, pwarr, " ")
  for (i = 1; i <= n; i++) prefix_set[pwarr[i]] = 1
}
function normalize(tok,    t, parts, np) {
  t = tok
  gsub(sq, "", t)
  gsub(/"/, "", t)
  gsub(/\\/, "", t)
  np = split(t, parts, "/")
  return parts[np]
}
function emit_segment(seg,    ntok, toks, idx, tok, norm, saw_prefix, cmdword, j, gitsub) {
  ntok = split(seg, toks, /[ \t]+/)
  idx = 1
  saw_prefix = 0
  cmdword = ""
  while (idx <= ntok) {
    tok = toks[idx]
    if (tok == "") { idx++; continue }
    if (match(tok, /^[A-Za-z_][A-Za-z0-9_]*=/) == 1) { idx++; continue }
    norm = normalize(tok)
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
  }
}
{
  line = $0
  gsub(/[;&|(){}`]/, "\n", line)
  gsub(/[<>]/, " ", line)
  nseg = split(line, segs, /\n/)
  for (s = 1; s <= nseg; s++) emit_segment(segs[s])
}
')"

# --- role policy -----------------------------------------------------------------------------
# Implementer: deny on ANY segment whose command word is git or gh, regardless of git subcommand
# (the implementer needs neither — see the Decision this issue implements). Verifier: deny on gh
# outright; for git, deny unless the resolved subcommand is a member of VERIFIER_GIT_READONLY —
# so "-globalopt-", "-none-", and any subcommand not on that list all deny (fail closed). The
# first offending segment (scan order) decides; stdout stays empty on every path.
deny_cmd=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
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
  if [ "$role" = "implementer" ]; then
    printf '%s implementer role may not run any of: %s (blocked: %s) — see agents/implementer.md\n' \
      "$DENY_STEM" "$BLOCKED_COMMANDS" "$deny_cmd" >&2
  else
    printf '%s verifier role may only run read-only git (%s), never gh (blocked: %s) — see agents/verifier.md\n' \
      "$DENY_STEM" "$VERIFIER_GIT_READONLY" "$deny_cmd" >&2
  fi
  exit 2
fi

exit 0
