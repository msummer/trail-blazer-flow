#!/usr/bin/env bash
#
# claude-dir-guard.sh — plugin-shipped PreToolUse hook (#327) that mechanically denies an
# implementer or verifier subagent's Edit or Write to any path carrying a `.claude` path segment,
# turning #323's orchestrator-prose LESSONS.md dispatch guard (which only detects a subagent's
# `.claude/LESSONS.md` change after the dispatch returns, and only if the orchestrator runs the
# compare) into a rail, and closing that guard's own documented blind spot for a repo whose
# `.claude/LESSONS.md` is still untracked. Reads the hook's stdin JSON; for an `Edit` or `Write`
# tool call issued by a recognised implementer/verifier agent_type, denies (exit 2, one stderr
# line, empty stdout) when `tool_input.file_path` carries any path segment equal to `.claude`
# case-insensitively, OR when the path cannot be classified as absolute or `..`-free (fail-closed
# per the triage record this issue settled); every other case — main session (no agent_type), any
# other agent, `permission_mode: "plan"`, a tool other than Edit/Write, malformed stdin, an
# absent/empty file_path, or an ordinary absolute path outside any `.claude` segment — is "no
# opinion" (exit 0, empty stdout, empty stderr), the same convention every sibling hook in this
# directory uses.
#
# The classifier is a PURE STRING decision with NO FILESYSTEM ACCESS AT ALL — strictly less than
# hooks/push-guard.sh, which reads cwd-derived `.git` paths to resolve branch/config facts; this
# hook reads nothing but the stdin JSON itself. Never executes anything (no git, no gh, nothing
# derived from the untrusted file_path string), never `eval`s, never writes a file. bash + jq only
# — no python, no perl, no GNU-only flags (this repo's CLAUDE.md portability convention);
# exercised under Apple's bash 3.2 by the selfcheck-macos CI job, same as bin/*.sh and this
# directory's three siblings.
#
# Vocabulary cross-reference: AGENT_TYPES_IMPLEMENTER/AGENT_TYPES_VERIFIER below are copied
# byte-identically from hooks/agent-boundary.sh:57-58 — dev/selfcheck.sh's assertion 4.45 pins the
# two files' declarations identical mechanically (the 4.42 script<->script idiom). See
# hooks/agent-boundary.sh's own header for the full #259/#327 live-probe provenance of this
# vocabulary; only the #327-specific measurements are restated below.
#
# Live-probe record, #327 (orchestrator-measured 2026-09-17 against Claude Code 2.1.274, macOS, a
# temporary logging PreToolUse hook with matcher "Edit|Write" supplied via --settings, this repo
# loaded via --plugin-dir -- one Claude Code version, one platform, one install shape; not
# re-verified across versions, platforms, or install shapes):
#   - A main-session Edit/Write PreToolUse payload carries no agent_type key and no agent_id key
#     at all (M1) -- the same "no opinion, fast path 1" shape hooks/agent-boundary.sh's own record
#     already established for Bash.
#   - An implementer-subagent Write payload carries agent_type = "trail-blazer-flow:implementer"
#     (the namespaced spelling #259 measured for Bash), with tool_input keys {content, file_path}
#     (M2); the same subagent's Edit payload carries the identical agent_type spelling, with
#     tool_input keys {file_path, new_string, old_string, replace_all} (M3).
#   - Across the six payloads captured during this probe, tool_input.file_path was an ABSOLUTE
#     path under the session cwd; one call was requested with the relative path "blocked/rel.txt"
#     and the payload still carried the absolute form (M4). Whether Claude Code or the model
#     itself absolutised it is NOT established -- a relative file_path reaching this hook is
#     therefore unproven either way, not ruled out, which is why the classifier below denies
#     (fails closed) rather than passing a non-absolute path through.
#   - A hook wired {"matcher":"Edit|Write", hooks:[{type:command,...}]} that exits 2 with one
#     stderr line blocked the subagent's Write outright (the file was not created, and the
#     subagent's own transcript showed "PreToolUse:Write hook error: [<command>]: <the stderr
#     line>"); the same hook exiting 0 with empty stdout let the main session's Write through (M5).
#   - A verifier-subagent dispatch given a realistic mutation-probe task on a tracked file (one
#     commit already in the fixture repo) produced an Edit PreToolUse payload carrying agent_type
#     = "trail-blazer-flow:verifier" and an agent_id, tool_input keys {file_path, new_string,
#     old_string, replace_all}, and an absolute file_path -- the logging hook exited 0, the
#     verifier's mutant was killed, and the file was restored before the dispatch returned (M7).
#     So the verifier's Edit spelling is MEASURED, the same way the implementer's is, not inferred
#     from the Bash measurement. agents/verifier.md's tools: line carries no Write tool, so no
#     verifier Write payload exists to measure.
#   - NOT measured: a MultiEdit/NotebookEdit payload (agents/implementer.md:9 and
#     agents/verifier.md:12 list neither tool for either role today, so GUARDED_TOOLS below does
#     not need to cover them; gate 4.53 pins this by comparing GUARDED_TOOLS against both roles'
#     tools: lines, so a future MultiEdit/NotebookEdit grant fails the gate rather than silently
#     reopening this hook's own blind spot); symlink/hard-link/`..`-normalisation resolution
#     (documented below as an under-blocking class instead); whether `cwd` is always the repo root.
#     A Bash-issued write into .claude/ (e.g. a redirect) is still outside an Edit/Write hook's
#     matcher by construction, but since #340 hooks/agent-boundary.sh's own Bash policy now covers
#     part of that route (a `>`-family redirect, tee/cp/mv/cd/pushd, or in-place sed) for the
#     implementer/verifier roles -- see that hook's own header for what it covers and the
#     under-blocking note below for what it still doesn't.
#
# Contract: read the PreToolUse hook JSON on stdin; print nothing and exit 0 ("no opinion") unless
# the call is an Edit/Write from a recognised implementer/verifier agent_type whose file_path the
# policy below denies, in which case print exactly one reason line to stderr and exit 2 ("deny");
# stdout is always empty. Wired in hooks/hooks.json via ${CLAUDE_PLUGIN_ROOT}, with no "if" gate:
# the "if" field is permission-rule syntax over tool_input constituents only -- it cannot see
# agent_type, and it cannot express a case-insensitive/nested/".." path-segment rule, so any "if"
# here would silence this hook for exactly the spellings it exists to catch (the same reasoning
# hooks/agent-boundary.sh's and hooks/push-guard.sh's own registrations already give).
#
# Documented over-blocking classes (deliberate, measured directly against this script): a path
# carrying a ".." segment with no ".claude" anywhere denies (fail-closed, unclassifiable) --
# measured: "/repo/../etc/passwd" -> rc 2; a non-absolute path denies -- measured: "src/main.rs"
# -> rc 2; a POSIX filename containing a literal backslash is treated as separator-bearing, which
# can manufacture a ".claude" segment that was never a real directory boundary -- measured: a
# file_path whose real, single-component filename is "foo\.claude\bar" (backslashes are legal
# filename bytes on POSIX; no ".claude" directory exists) normalises to "/repo/foo/.claude/bar"
# and denies (rc 2) purely from the rewrite; a case-variant spelling denies even on a
# case-sensitive filesystem -- measured: "/repo/.Claude/x" -> rc 2; a test fixture the implementer
# or verifier must write under any `.claude` segment denies -- remedy: create such fixtures from
# the test script's own Bash, as this repo's harnesses (dev/hook-tests.sh included) already do.
#
# Documented under-blocking classes (evasions, named rather than hidden): a Bash-issued write
# (`cat >>`, `tee`, `sed -i`) never reaches an Edit/Write hook by construction; since #340,
# hooks/agent-boundary.sh's own Bash policy denies the redirect/tee/cp/mv/cd-pushd/in-place-sed
# forms of that route for the implementer/verifier roles, but an interpreter write
# (`python3 -c "open('.claude/LESSONS.md','a')…"`, `perl -i`), `install`/`ln`/`touch`/`truncate`/
# `dd of=…`, and a variable-built or glob target still evade it (see that hook's own header for the
# full list, and #340's own filed follow-up for the interpreter/dd/install gap specifically); a
# symlink or hard link whose own spelling carries no `.claude` segment (this hook performs no
# filesystem access, so it cannot resolve one); a write tool outside GUARDED_TOOLS -- measured: no
# role's tools: line names MultiEdit or NotebookEdit today (agents/implementer.md:9,
# agents/verifier.md:12; gate 4.53 pins GUARDED_TOOLS against both roles' tools: lines, so this
# stays true only until a role's tools: line changes without a matching GUARDED_TOOLS update); any
# other agent role -- measured: an
# agent_type of "Explore" -> rc 0; a Claude Code that stops sending agent_type at all -- fails
# open, the same documented note hooks/agent-boundary.sh's header already carries for its own
# vocabulary; the plugin disabled, `disableAllHooks: true`, no `jq` on PATH, or an unresolved
# ${CLAUDE_PLUGIN_ROOT} -- every one degrades this hook to silent no-opinion, with no prompt and
# no visible sign, exactly as every sibling hook in this directory already documents.
set -uo pipefail

# --- vocabulary --------------------------------------------------------------------------------
# Grep-extractable single-line KEY="value" declarations (the 2.5/4.36-4.42 idiom). The two
# AGENT_TYPES_* lines are copied byte-identically from hooks/agent-boundary.sh:57-58 -- see this
# file's header cross-reference and dev/selfcheck.sh's assertion 4.45.
AGENT_TYPES_IMPLEMENTER="implementer trail-blazer-flow:implementer"
AGENT_TYPES_VERIFIER="verifier trail-blazer-flow:verifier"
GUARDED_TOOLS="Edit Write"
GUARDED_SEGMENT=".claude"
CLAUDE_DIR_DENY_STEM="trail-blazer-flow claude-dir guard:"

input="$(cat)"

# --- fast path -----------------------------------------------------------------------------
# Only ONE raw-stdin fast path (unlike hooks/agent-boundary.sh's two): a main-session Edit/Write
# call (no agent_type key in the JSON at all) can never resolve to a recognised role, so skip
# straight to "no opinion" without spawning jq (M1). There is deliberately no second,
# `.claude`-substring fast path: it would not be semantics-preserving the way
# hooks/agent-boundary.sh's second fast path is -- the unclassifiable-path deny class below (a
# non-absolute or `..`-carrying file_path) can deny a path that never contains the literal
# substring "claude" at all, so gating on that substring first would silently exit "no opinion" on
# exactly the fail-closed class this hook exists to catch.
case "$input" in
  *agent_type*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

tool_name="$(printf '%s' "$input" | jq -r '.tool_name? // empty' 2>/dev/null)"
case " $GUARDED_TOOLS " in
  *" $tool_name "*) : ;;
  *) exit 0 ;;
esac

# Role resolution: exact string match against space-delimited membership (the sub_allowed idiom
# at hooks/git-c-guard.sh:154-159, reused verbatim by hooks/agent-boundary.sh) -- no match, empty,
# or absent agent_type all resolve to no role, i.e. "no opinion".
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

file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path? // empty' 2>/dev/null)"
[ -n "$file_path" ] || exit 0

# A CRLF-carrying transport can deliver a file_path whose spelling carries a trailing/embedded
# \r; stripping it can only WIDEN which paths match ".claude" below (removing a character can
# only join two fragments into a segment this hook already looks for, never separate an
# already-matching segment apart) -- the same #270 idiom hooks/agent-boundary.sh and
# hooks/push-guard.sh both apply at the identical point in their own tokenizers. Pure parameter
# expansion: no new process, so this hook still executes nothing (see this file's header).
cr=$'\r'
p="${file_path//$cr/}"

# Separator normalisation: a Windows-native or backslash-spelled ".claude" still denies (see
# README's Windows section on Git Bash's own path-form quirks). Documented over-block: a POSIX
# filename containing a literal backslash is treated as separator-bearing (see this file's header).
p="${p//\\//}"

# A literal LF byte embedded in file_path (distinct from the \r stripped above) would otherwise
# print as a second physical line inside either deny message below, breaking this hook's own
# "exactly one stderr line" contract (#327 round-1 kickback: measured, an unfixed build printed 2
# stderr lines for both "/repo/.claude/a<LF>b.md" and "src/a<LF>b.rs"). Build a PRINT-ONLY copy via
# pure parameter expansion (no new process, so this hook still executes nothing) -- the classifier
# immediately below keeps matching against $p itself, unmodified, so the deny DECISION is
# unaffected; only the printed wording folds each LF into the two-character "\n" so it renders on
# one line.
lf=$'\n'
p_disp="${p//$lf/\\n}"

# --- the classifier, pure builtins, no filesystem access at all --------------------------------
# Order matters: the more specific ".claude" message wins over the generic "unclassifiable"
# message whenever both could apply (e.g. a relative ".claude/..." path, or an absolute path
# carrying both a ".." segment and a ".claude" segment).
#
# ".claude" segment: matched against "/$p/" (both a LEADING and the plan's own documented
# TRAILING slash appended) so the same one pattern catches a nested segment, a final segment with
# nothing after it, AND a relative path whose very FIRST segment is ".claude" (e.g.
# ".claude/LESSONS.md" itself carries no leading "/" for a "*/" wildcard to anchor against without
# the prepended one) -- measured directly against this exact pattern; see the case-row table in
# dev/hook-tests.sh's cdg-* section for every shape checked. The bracket classes are the
# case-insensitive idiom hooks/push-guard.sh already uses for config keys.
case "/$p/" in
  */.[Cc][Ll][Aa][Uu][Dd][Ee]/*)
    printf '%s %s role may not %s a path under a %s segment: %s — record it in your report'"'"'s Reviewer notes instead; see agents/%s.md\n' \
      "$CLAUDE_DIR_DENY_STEM" "$role" "$tool_name" "$GUARDED_SEGMENT" "$p_disp" "$role" >&2
    exit 2
    ;;
esac

# Absoluteness: /... or a Windows/Git-Bash drive-letter form (README's "Git Bash accepts
# C:/Users/... and /c/Users/..." note; hooks/git-c-guard.sh's own PATH_ERE uses the identical
# [A-Za-z]:/ prefix class). Anything else cannot be classified and is denied fail-closed, per the
# triage record this issue settled (see this file's header "Live-probe record" note on M4).
case "$p" in
  /*) ;;
  [A-Za-z]:/*) ;;
  *)
    printf '%s %s role'"'"'s %s file_path could not be classified as absolute or normalised, and is denied fail-closed: %s\n' \
      "$CLAUDE_DIR_DENY_STEM" "$role" "$tool_name" "$p_disp" >&2
    exit 2
    ;;
esac

# A ".." segment anywhere: also denied fail-closed (the same triage record) -- a future Claude
# Code payload whose file_path is not already normalised must not silently escape a ".claude"
# check that only ever looks at the literal path string.
case "$p/" in
  */../*)
    printf '%s %s role'"'"'s %s file_path could not be classified as absolute or normalised, and is denied fail-closed: %s\n' \
      "$CLAUDE_DIR_DENY_STEM" "$role" "$tool_name" "$p_disp" >&2
    exit 2
    ;;
esac

exit 0
