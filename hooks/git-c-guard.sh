#!/usr/bin/env bash
#
# git-c-guard.sh — plugin-shipped PreToolUse guard hook (#150). Approves, without a prompt,
# ONLY the exact `git -C <worktree-path> <subcommand>` forms worktree-parallel mode issues (see
# skills/issue-implementer/references/worktree-mode.md) — the ten `git -C <worktree> <subcommand>`
# forms it issues: the nine the template's now-deleted `Bash(git -C * <sub> *)` allow entries used
# to cover, plus the verifier's read-only `log` (#155). Says nothing (exit 0, empty stdout — "no
# opinion") about everything else, so the normal permission flow applies: a prompt in default
# mode, or the matching `-C` deny mirror in templates/repo-settings.json, which always wins over
# this hook's decision regardless. Never emits "deny" or "ask" — a bug here
# degrades to a prompt, never to a bypass. Never invokes `git` (or anything else that would touch
# the untrusted path), never `eval`s, never writes a file. bash + jq + POSIX awk only — no
# python, no perl, no GNU-only flags (this repo's CLAUDE.md portability convention); exercised
# under Apple's bash 3.2 by the selfcheck-macos CI job, same as bin/*.sh.
#
# Contract: read the PreToolUse hook JSON on stdin; print a single allow-decision JSON object on
# stdout and exit 0 when every `git -C` invocation in tool_input.command conforms; otherwise
# print nothing and exit 0. Wired in hooks/hooks.json via `${CLAUDE_PLUGIN_ROOT}`.
set -uo pipefail

input="$(cat)"

# Fast path: skip the jq spawn for the overwhelming majority of Bash calls that never mention
# `git -C` at all — see the plan's "Every-Bash-call cost" risk. hooks/hooks.json's handler now
# carries `"if": "Bash(git -C *)"` (Claude Code 2.1.85+), which filters most non-`git -C` Bash
# calls upstream so this script is never even spawned for them; this raw-stdin check is the
# backstop for everything else (a Claude Code below the `if` floor, or any call the `if` match
# still lets through). A raw substring miss (e.g. a double space between `-C` and the path) just
# leaves this hook silent for that one call; the normal permission flow still applies, so a miss
# here is never unsafe, only a missed convenience.
case "$input" in
  *'git -C'*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

tool_name="$(printf '%s' "$input" | jq -r '.tool_name? // empty' 2>/dev/null)"
[ "$tool_name" = "Bash" ] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command? // empty' 2>/dev/null)"
[ -n "$cmd" ] || exit 0

# Never opine during a planning turn: a hook allow could otherwise approve a mutating git command
# while the user believes nothing is being executed yet. The exact spelling of this field's value
# is otherwise unverified — if it isn't literally "plan", this check is simply inert, never
# dangerous, because everything below stays exactly as conservative either way.
pmode="$(printf '%s' "$input" | jq -r '.permission_mode? // empty' 2>/dev/null)"
[ "$pmode" != "plan" ] || exit 0

# The ten forms worktree-parallel mode issues, and no more — kept as one grep-extractable line
# (dev/selfcheck.sh 2.5 extracts this list mechanically; keep the exact `KEY="value"` shape).
GIT_C_SUBCOMMANDS="status add commit push restore diff rev-parse merge-base reset log"

# Relative sibling (`../<name>-wt-<n>`), POSIX absolute, Git-Bash (`/c/Users/...`), and Windows
# drive-letter (`C:/Users/...`) forms — see worktree-mode.md:83 and README's Windows section.
PATH_ERE='^([A-Za-z]:/|/|\.\./)([A-Za-z0-9._ +-]+/)*[A-Za-z0-9._+-]+-wt-[0-9]+/?$'

# --- the lexer -------------------------------------------------------------------------------
# Walks $cmd one character at a time (plain / single-quoted / double-quoted state), emitting one
# line per completed token ("T<text>", quotes stripped, quoted spans concatenated with adjacent
# bare text) or unquoted "&&" ("S"). Rejects (nonzero exit; the caller then discards all output
# as unusable) on: any unquoted shell metacharacter from the set $ ` \ ; | < > ( ) { } [ ] * ? !
# ~ #, a lone unquoted "&", a double-quoted "$"/backtick/backslash, an unterminated quote at end
# of input, any control character, or an embedded newline (default awk RS, so an embedded newline
# inside $cmd always yields NR > 1 — the ONLY signal this script needs to reject a multi-line
# command without ever treating "\n" as an ordinary character). This is the ONLY place $cmd's raw
# bytes are inspected; the guard never executes it. POSIX awk only — no gensub, no
# length(array), no GNU extensions.
lex_out="$(printf '%s' "$cmd" | awk '
BEGIN {
  sq = sprintf("%c", 39)
  reject = "$`" "\\" ";|<>(){}[]*?!~#"
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
[ "$lex_rc" -eq 0 ] || exit 0

# --- segment validation ------------------------------------------------------------------------
# A segment is the token run between "S" markers. A segment conforms iff it has at least 4
# tokens and: t0 == "git"; t1 == "-C" exactly (rejects the attached -C<path> form and a second
# -C); t2 matches the worktree-path shape; t3 is one of the ten subcommands above, and — when
# t3 == "reset" — t4 == "--soft". Everything after the subcommand is unconstrained: it is that
# subcommand's own option surface, and the lexer has already guaranteed it holds no unquoted
# metacharacter and no substitution — the same exposure the bare `Bash(git <sub>:*)` rules
# already accept. Zero segments, or any non-conforming segment, means no opinion.
sub_allowed() {
  case " $GIT_C_SUBCOMMANDS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_segment() {
  [ "$#" -ge 4 ] || return 1
  [ "$1" = "git" ] || return 1
  [ "$2" = "-C" ] || return 1
  printf '%s\n' "$3" | grep -qE "$PATH_ERE" || return 1
  sub_allowed "$4" || return 1
  if [ "$4" = "reset" ]; then
    [ "${5:-}" = "--soft" ] || return 1
  fi
  return 0
}

seg=()
seg_count=0
all_ok=1
flush_segment() {
  if [ "${#seg[@]}" -gt 0 ]; then
    seg_count=$((seg_count + 1))
    validate_segment "${seg[@]}" || all_ok=0
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

if [ "$all_ok" -eq 1 ] && [ "$seg_count" -ge 1 ]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"trail-blazer-flow: worktree-parallel git -C <worktree> <subcommand> form"}}'
fi
exit 0
