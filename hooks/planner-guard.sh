#!/usr/bin/env bash
#
# planner-guard.sh — plugin-shipped PreToolUse hook (#407) that mechanically enforces the planner
# subagent's read-only boundary on Codex, where the sandbox itself does not hold (ADR 0002
# amendment, P2). Reads the hook's stdin JSON; for a recognised planner agent_type, denies (exit
# 2, one stderr line, empty stdout) an `Edit`/`Write`/`apply_patch` call outright, and denies a
# `Bash` call unless every `;`/`|`/`||`/`&&`-separated segment's command word is a member of
# PLANNER_READONLY_COMMANDS below, with extra shape constraints on `git`/`rg`/`sed` (see the
# segment validator further down); every other case — main session (no agent_type), any other
# agent, a tool outside this hook's matcher, malformed stdin, or a non-Bash tool this hook does not
# recognise — is "no opinion" (exit 0, empty stdout, empty stderr), the same convention every
# sibling hook in this directory uses. Unlike every sibling, this hook is an ALLOWLIST: an
# unclassifiable shell command denies (fails closed), never passes silently — the planner needs a
# read-only guarantee, not a denylist tripwire.
#
# On Claude Code, this hook is a documented NO-OP today: agents/planner.md's own `tools:` line
# lists only `Read, Grep, Glob` — the planner is never given Edit/Write/apply_patch/Bash at all, so
# this hook's matcher never fires for it in practice. It exists for Codex, where P2 (the ADR 0002
# amendment) measured that `sandbox_mode = "read-only"` does not hold — the model can still invoke
# `apply_patch`, and P3 measured that a Codex plugin's hook rules apply to every agent regardless of
# its own declared tool grant, so an off-script planner on Codex is not stopped by tool
# configuration alone; this hook is the mechanical rail for that case.
#
# Never executes anything (no git, no gh, no rm, no touch, nothing derived from the untrusted
# command string) other than jq (for JSON extraction) and awk (for the read-only lexer below, the
# same POSIX-awk-only technique hooks/git-c-guard.sh already uses) — see the never-executes
# fixture in dev/hook-tests.sh's plg-* section, which traps exactly git/gh/rm/touch, not awk/jq.
# Never `eval`s, never writes a file. bash + jq + POSIX awk only — no python, no perl, no
# GNU-only flags (this repo's CLAUDE.md portability convention); exercised under Apple's bash 3.2
# by the selfcheck-macos CI job, same as bin/*.sh and this directory's four siblings.
#
# Contract: read the PreToolUse hook JSON on stdin; print nothing and exit 0 ("no opinion") unless
# the call is an Edit/Write/apply_patch/Bash from a recognised planner agent_type that the policy
# below denies, in which case print exactly one reason line to stderr and exit 2 ("deny"); stdout
# is always empty. Wired in hooks/hooks.json via `${CLAUDE_PLUGIN_ROOT}`, with NO "if" gate: the
# "if" field is permission-rule syntax over tool_input constituents only — it cannot see
# agent_type at all, so any "if" here would silence this hook for every call it exists to catch
# (the same reasoning every sibling hook's own registration already gives). Deliberately, there is
# NO `permission_mode: "plan"` skip here, unlike every sibling hook: `permission_mode` cannot be
# relied on under Codex (ADR 0002 amendment, P1), and a read-only role loses nothing from a denial
# during a genuine plan-mode turn — see this repo's approved #407 plan, Open questions.
#
# Documented fail-open classes (same shape as every sibling hook, degrading to silent no-opinion,
# with no prompt and no visible sign): the plugin disabled, `disableAllHooks: true`, no `jq` on
# PATH, an unresolved `${CLAUDE_PLUGIN_ROOT}`, or a Claude Code/Codex that stops sending
# `agent_type` at all. The doctor issue (#410) covers checking for `jq` on a consumer's PATH; this
# hook does not check for itself.
#
# Documented over-blocking classes (deliberate, since this is an allowlist): `2>/dev/null` and
# every other unquoted `$VAR`/redirect/substitution denies, with no carve-out — the model is
# expected to retry after reading the one-line reason, not to be accommodated; a heredoc or any
# other multi-line command denies outright (NR>1 in the lexer below), even one whose extra lines
# are themselves read-only-looking prose; a genuinely read-only command whose own name is not on
# PLANNER_READONLY_COMMANDS (e.g. `find`, `sort`, `uniq`, `awk`, `less`, `xargs`, `cd`) denies —
# see this repo's approved #407 plan, Open questions, for why each was excluded.
#
# Documented under-blocking classes (evasions, named rather than hidden, the same "tripwire, not a
# sandbox" limit every sibling hook in this directory already carries): only `Bash`, `Edit`,
# `Write`, and `apply_patch` are covered — a Codex tool call this repo has not observed (an MCP
# tool, a unified-exec `write_stdin`-style tool, …) is simply outside this hook's matcher and gets
# no opinion either way (see this repo's approved #407 plan, Risks & considerations); an allowlisted
# `git diff`/`show`/`log` can still run a textconv or external-diff driver the repo's OWN git
# config declares (`--ext-diff` itself is denied, but a driver configured via `diff.<driver>.command`
# and invoked through a `diff=<driver>` gitattribute is not distinguishable from an ordinary `git
# diff` by this lexer); the SAME repo config can also declare `core.fsmonitor = <script>`, an
# external filesystem-monitor hook that `status`/`diff` (among others) invoke on every run,
# regardless of any option on the command line — a documented residual, not a code change (see the
# #407 kickback maintainer approval).
set -uo pipefail

# --- vocabulary --------------------------------------------------------------------------------
# Grep-extractable single-line KEY="value" declarations (the 2.5/4.36-4.42 idiom).
AGENT_TYPES_PLANNER="planner trail-blazer-flow:planner"
PLANNER_EDIT_TOOLS="Edit Write apply_patch"
# Deliberately excludes find/sort/uniq/awk/less/xargs/cd (can write, run other commands, or leave
# the checkout, per the #407 plan's Open questions) and, for git specifically, "restore" (it
# writes the working tree) — see PLANNER_GIT_READONLY below, not this list.
PLANNER_READONLY_COMMANDS="cat head tail ls pwd wc grep rg nl sed git echo printf true diff cmp stat basename dirname jq cut tr"
# "grep" is deliberately NOT a member (#407 kickback finding 1): real git accepts abbreviated
# long options (`--open=rm`) and bundled short options (`-lOrm`, i.e. `-l -O rm`, where `-O`'s
# pager argument is glued on), so `git grep` can be steered into `-O`/`--open-files-in-pager`
# (opens each matching file in an arbitrary pager program) in a shape this token-based check
# cannot reliably catch. The planner already has the `rg` and `grep` TOOLS for searching, so `git
# grep` is not missed.
PLANNER_GIT_READONLY="status diff log show rev-parse ls-files merge-base blame"
PLANNER_DENY_STEM="trail-blazer-flow planner guard:"
# The sed range-address ERE this hook accepts: "<N|$>[,<N|$>]p", anchored full-string (the ONLY
# sed invocation this hook allows is a read-only line-range print). Kept in a variable so `[[ =~ ]]`
# stays bash-3.2-safe (the literal is never inlined at the match site).
PLANNER_SED_RANGE_ERE='^([0-9]+|\$)(,([0-9]+|\$))?p$'

input="$(cat)"

# --- fast paths ----------------------------------------------------------------------------
# Fast path 1: a main-session call (no agent_type key in the JSON at all) can never resolve to the
# planner role, so skip straight to "no opinion" without spawning jq. Fast path 2: neither
# recognised agent_type spelling can appear in the raw JSON without the substring "planner", so
# skip the same way for any other subagent (implementer, verifier, Explore, …). Both are pure
# performance optimisations: a miss on either always means "this call is out of scope", the same
# conclusion the slower checks below it would reach.
case "$input" in
  *agent_type*) : ;;
  *) exit 0 ;;
esac
case "$input" in
  *planner*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

# Role resolution: exact string match against space-delimited membership (the sub_allowed idiom
# at hooks/git-c-guard.sh:154-159, reused by every sibling hook in this directory) — no match,
# empty, or absent agent_type resolves to no role, i.e. "no opinion". Deliberately NO
# `permission_mode: "plan"` skip here — see this file's header.
agent_type="$(printf '%s' "$input" | jq -r '.agent_type? // empty' 2>/dev/null)"
role=""
if [ -n "$agent_type" ]; then
  case " $AGENT_TYPES_PLANNER " in
    *" $agent_type "*) role="planner" ;;
  esac
fi
[ -n "$role" ] || exit 0

tool_name="$(printf '%s' "$input" | jq -r '.tool_name? // empty' 2>/dev/null)"

case " $PLANNER_EDIT_TOOLS " in
  *" $tool_name "*)
    printf '%s planner role is read-only and may not use %s — return the plan as your final message instead; see agents/planner.md\n' \
      "$PLANNER_DENY_STEM" "$tool_name" >&2
    exit 2
    ;;
esac

[ "$tool_name" = "Bash" ] || exit 0

# A CRLF-carrying transport can deliver a command whose tokens carry a trailing \r; every
# comparison below is an exact match, so an unstripped \r would make a real command word fail to
# match its own PLANNER_READONLY_COMMANDS/PLANNER_GIT_READONLY entry (#270, the same idiom every
# sibling hook applies at the identical point in its own tokenizer).
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command? // empty' 2>/dev/null)"
cr=$'\r'
lf=$'\n'
cmd="${cmd//$cr/}"

# An absent/empty tool_input.command is denied fail-closed here — unlike every sibling hook (which
# treats it as "no opinion"), this hook is an allowlist: there is nothing to classify as read-only,
# so there is nothing to allow.
if [ -z "$cmd" ]; then
  printf '%s planner role'"'"'s shell command is empty, and is denied fail-closed\n' \
    "$PLANNER_DENY_STEM" >&2
  exit 2
fi
cmd_disp="${cmd//$lf/\\n}"

# --- the lexer -------------------------------------------------------------------------------
# A copy of hooks/git-c-guard.sh:75-142's awk lexer (see that script's own header for the full
# state-machine description), changed for this hook's allowlist policy:
#   - the reject set drops `; | * ? [ ] ~ #` (each now either a segment separator below, or — for
#     `* ? [ ] ~ #` — an ORDINARY character: a glob, a bracket-expression byte, or a comment marker
#     is not itself unsafe for a command this hook will go on to classify token-by-token) and keeps
#     only `$ ` (backtick) `\ < > ( ) { } !`;
#   - `;`, a single `|`, `||`, and `&&` each emit "S" (a segment break) rather than rejecting outright
#     — git-c-guard's own lexer rejects `;`/`|` unconditionally because IT never opines past a
#     reject; this hook instead validates each segment on its own;
#   - a lone `&` (not doubled) is still rejected outright — this also covers `|&`, since the
#     preceding `|` is already consumed as its own single-pipe segment break by the time the lone
#     `&` is reached;
#   - double-quoted `$`/backtick/backslash, any control character, an embedded newline (NR>1, awk's
#     default per-line RS — the ONLY signal this lexer needs to reject a multi-line command), and
#     an unterminated quote at end of input are all still rejected, unchanged from git-c-guard.
# UNLIKE git-c-guard (whose caller discards the lexer's output on ANY rejection and falls back to
# "no opinion"), a rejection here means DENY, fail-closed — see the check on $lex_rc below.
lex_out="$(printf '%s' "$cmd" | awk '
BEGIN {
  sq = sprintf("%c", 39)
  reject = "$`" "\\" "<>(){}!"
  ctrl = ""
  for (k = 1; k < 32; k++) {
    if (k == 9) continue
    ctrl = ctrl sprintf("%c", k)
  }
  ctrl = ctrl sprintf("%c", 127)
  state = "plain"
  token = ""
  havetoken = 0
  ok = 1
}
{
  n = length($0)
  i = 1
  while (i <= n) {
    if (!ok) break
    c = substr($0, i, 1)
    if (state == "plain") {
      if (c == sq) { state = "squote"; havetoken = 1; i++; continue }
      if (c == "\"") { state = "dquote"; havetoken = 1; i++; continue }
      if (c == " " || c == "\t") {
        if (havetoken) { print "T" token; token = ""; havetoken = 0 }
        i++; continue
      }
      if (c == ";") {
        if (havetoken) { print "T" token; token = ""; havetoken = 0 }
        print "S"
        i++; continue
      }
      if (c == "|") {
        nc = (i < n) ? substr($0, i + 1, 1) : ""
        if (havetoken) { print "T" token; token = ""; havetoken = 0 }
        print "S"
        i += (nc == "|") ? 2 : 1
        continue
      }
      if (c == "&") {
        nc = (i < n) ? substr($0, i + 1, 1) : ""
        if (nc == "&") {
          if (havetoken) { print "T" token; token = ""; havetoken = 0 }
          print "S"
          i += 2
          continue
        }
        ok = 0; break
      }
      if (index(reject, c) > 0) { ok = 0; break }
      if (index(ctrl, c) > 0) { ok = 0; break }
      token = token c
      havetoken = 1
      i++
      continue
    }
    if (state == "squote") {
      if (c == sq) { state = "plain"; i++; continue }
      token = token c
      i++
      continue
    }
    if (state == "dquote") {
      if (c == "\"") { state = "plain"; i++; continue }
      if (c == "$" || c == "`" || c == "\\") { ok = 0; break }
      token = token c
      i++
      continue
    }
  }
}
END {
  if (NR > 1) ok = 0
  if (!ok) exit 1
  if (state != "plain") exit 1
  if (havetoken) print "T" token
  exit 0
}
')"
lex_rc=$?
if [ "$lex_rc" -ne 0 ]; then
  printf '%s planner role'"'"'s shell command could not be classified as read-only (an unquoted shell metacharacter, an unterminated quote, or an embedded newline), and is denied fail-closed: %s\n' \
    "$PLANNER_DENY_STEM" "$cmd_disp" >&2
  exit 2
fi

# --- segment validation ------------------------------------------------------------------------
# A segment is the token run between "S" markers (the flush_segment idiom at
# hooks/git-c-guard.sh:161-196). An empty segment (two separators back to back, or a leading/
# trailing separator) is SKIPPED, not validated — it names no command at all. Zero non-empty
# segments overall means deny: a command that lexes cleanly but names nothing to run is not a
# read-only command, so it is not allowed either.
validate_segment() {
  local t0="$1" t1="${2:-}"
  case " $PLANNER_READONLY_COMMANDS " in
    *" $t0 "*) : ;;
    *) return 1 ;;
  esac
  case "$t0" in
    git)
      case " $PLANNER_GIT_READONLY " in
        *" $t1 "*) : ;;
        *) return 1 ;;
      esac
      shift 2
      local tok
      # -O/--open-files-in-pager (a git-grep-only option in real git that opens matches in an
      # arbitrary pager program) is dropped from this check (#407 kickback finding 4/1): "grep" is
      # no longer a PLANNER_GIT_READONLY member at all (see that declaration's own comment), so no
      # subcommand that reaches this loop ever took that option to begin with. --output (writes
      # the result to a file instead of stdout) and --ext-diff (runs a configured external-diff
      # driver) remain relevant to diff/log/show and stay denied.
      for tok in "$@"; do
        case "$tok" in
          --output*|--ext-diff) return 1 ;;
        esac
      done
      ;;
    rg)
      shift 1
      local tok
      for tok in "$@"; do
        case "$tok" in
          # --hostname-bin=<cmd> (#407 kickback finding 1) runs <cmd> to resolve the hostname for
          # a hyperlink-format substitution -- an arbitrary-program-execution option, the same
          # class --pre already covers.
          --pre*|--hostname-bin*) return 1 ;;
        esac
      done
      ;;
    sed)
      local t2="${3:-}" tok
      [ "$t1" = "-n" ] || return 1
      [[ "$t2" =~ $PLANNER_SED_RANGE_ERE ]] || return 1
      shift 3
      for tok in "$@"; do
        case "$tok" in
          -*) return 1 ;;
        esac
      done
      ;;
  esac
  return 0
}

deny_policy() {
  local blocked="$1"
  printf '%s planner role may only run read-only commands (%s; git %s) (blocked: %s) — see agents/planner.md\n' \
    "$PLANNER_DENY_STEM" "$PLANNER_READONLY_COMMANDS" "$PLANNER_GIT_READONLY" "$blocked" >&2
  exit 2
}

seg=()
seg_count=0
flush_segment() {
  if [ "${#seg[@]}" -gt 0 ]; then
    seg_count=$((seg_count + 1))
    if ! validate_segment "${seg[@]}"; then
      local blocked="${seg[0]}"
      [ "${#seg[@]}" -ge 2 ] && blocked="${seg[0]} ${seg[1]}"
      deny_policy "$blocked"
    fi
    seg=()
  fi
}
while IFS= read -r line; do
  case "$line" in
    S) flush_segment ;;
    T*) seg+=("${line#T}") ;;
  esac
done <<EOF
$lex_out
EOF
flush_segment

[ "$seg_count" -ge 1 ] || deny_policy "(empty command)"

exit 0
