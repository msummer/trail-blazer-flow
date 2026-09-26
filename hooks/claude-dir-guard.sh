#!/usr/bin/env bash
#
# claude-dir-guard.sh — plugin-shipped PreToolUse hook (#327; apply_patch route, .codex, and the
# Bash apply_patch-shim route added #407, the latter in an approved mid-flight scope amendment)
# that mechanically denies an implementer or verifier subagent's Edit, Write, apply_patch, or (when
# it carries an inline `apply_patch`-shaped patch) Bash call whose target path (a file_path for
# Edit/Write, or every Add/Update/Delete/Move-to header path for apply_patch and for a Bash call
# carrying an inline patch) carries a `.claude` or `.codex` path segment, turning #323's
# orchestrator-prose LESSONS.md dispatch guard (which only detects a subagent's `.claude/
# LESSONS.md` change after the dispatch returns, and only if the orchestrator runs the compare)
# into a rail, and closing that guard's own documented blind spot for a repo whose
# `.claude/LESSONS.md` is still untracked, PLUS (#407) Codex's own `apply_patch` tool call, which
# carries no file_path at all (ADR 0002 amendment, P4), PLUS (#407 amendment) a shell-issued
# `apply_patch <<'EOF' … EOF` heredoc that Codex's own PATH-installed shim runs as an ordinary Bash
# call instead (ADR 0002 amendment 2, S0/#412, Q7). Reads the hook's stdin JSON; for an
# Edit/Write/apply_patch/Bash tool call issued by a recognised implementer/verifier agent_type,
# denies (exit 2, one stderr line, empty stdout) when a target path carries any path segment equal
# to `.claude` or `.codex` case-insensitively, OR when a path cannot be classified as absolute or
# `..`-free (fail-closed per the triage record this issue settled), OR (apply_patch, or Bash
# carrying an inline patch, #407) when the patch itself cannot be parsed into a recognised header
# shape, OR (Bash only, #407 amendment) when the command word is `apply_patch`/`applypatch` but
# carries no inline patch this hook can see at all (e.g. reading the patch from a file); every
# other case — main session (no agent_type), any other agent, `permission_mode: "plan"`, a tool
# other than Edit/Write/apply_patch/Bash, malformed stdin, an absent/empty file_path/command, an
# ordinary Bash call that neither carries an inline patch nor invokes the shim as its command word
# (`apply_patch`/`applypatch` appearing only as an ordinary argument gets no opinion; the walk is
# quote-blind, so a quoted mention right after a segment-break character can still deny -- see
# the documented over-blocks below), or
# an ordinary absolute path outside any `.claude`/`.codex` segment — is "no opinion" (exit 0, empty
# stdout, empty stderr), the same convention every sibling hook in this directory uses.
#
# The classifier is a PURE STRING decision with NO FILESYSTEM ACCESS AT ALL — strictly less than
# hooks/push-guard.sh, which reads cwd-derived `.git` paths to resolve branch/config facts; this
# hook reads nothing but the stdin JSON itself (for apply_patch and the Bash inline-patch route,
# that JSON's own `cwd` field is used to resolve a relative header path — still no filesystem
# access: `cwd` is trusted only as a string to join, never opened, stat'd, or listed). Never
# executes anything (no git, no gh, nothing derived from the untrusted file_path/command string),
# never `eval`s, never writes a file. Both patch routes split the patch text into lines using shell
# builtins only (IFS splitting under `set -f`), never a heredoc, here-string, or external tool; the
# Bash route's own command-word check (is_apply_patch_word) is likewise pure parameter-expansion
# splitting, no execve. bash + jq only — no python, no perl, no GNU-only flags (this repo's
# CLAUDE.md portability convention); exercised under Apple's bash 3.2 by the selfcheck-macos CI
# job, same as bin/*.sh and this directory's four siblings.
#
# Vocabulary cross-reference: AGENT_TYPES_IMPLEMENTER/AGENT_TYPES_VERIFIER below are copied
# byte-identically from hooks/agent-boundary.sh:57-58 -- dev/selfcheck.sh's assertion 4.45 pins the
# two files' declarations identical mechanically (the 4.42 script<->script idiom). See
# hooks/agent-boundary.sh's own header for the full #259/#327 live-probe provenance of this
# vocabulary; only the #327-specific measurements are restated below. GUARDED_TOOLS stays
# "Edit Write" (#407 added apply_patch, and the #407 amendment added Bash, to their own, separate
# PATCH_TOOLS/BASH_TOOLS variables instead of widening GUARDED_TOOLS itself) because
# dev/selfcheck.sh's assertion 4.53 requires every GUARDED_TOOLS member to appear on an
# implementer or verifier `tools:` line, and no role's frontmatter names apply_patch — see that
# assertion's own comment. (Bash IS already on both roles' tools: lines, and already on 4.53's own
# exemption list because hooks/agent-boundary.sh covers its `.claude`-write policy instead; leaving
# BASH_TOOLS separate here simply keeps this hook's own vocabulary self-contained, the same reason
# PATCH_TOOLS is separate.)
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
#     An ORDINARY Bash-issued write into .claude/ (e.g. a redirect, `cp`, `tee`) is still outside
#     THIS hook's own patch-parsing logic -- it carries no apply_patch-shaped patch for the Bash
#     route below to recognise -- but since #340 hooks/agent-boundary.sh's own Bash policy covers
#     part of that route (a `>`-family redirect, tee/cp/mv/cd/pushd, or in-place sed) for the
#     implementer/verifier roles -- see that hook's own header for what it covers and the
#     under-blocking note below for what it still doesn't. Only a Bash call SHAPED like the
#     apply_patch shim (an inline patch, or the shim as the command word) is this hook's own
#     concern (#407 amendment; see the Bash route below).
#
# Codex `apply_patch` probe record, #407 (ADR 0002 amendment, P4; see docs/adr/0002-codex-
# compatibility.md): Codex's file-editing tool call is named `apply_patch`, carries no `file_path`
# at all, and instead carries a `tool_input.command` string holding the WHOLE PATCH TEXT in
# Codex's own patch grammar (`*** Begin Patch` / `*** Add File: <path>` / `*** Update File: <path>`
# / `*** Delete File: <path>` / `*** Move to: <path>` / `*** End of File` / `*** End Patch`, with
# unmarked content lines in between), plus a top-level `cwd` field. Only the `Add File` and
# `Update File` forms were probe-verified directly; `Delete File`, `Move to`, `Begin Patch`, `End
# Patch`, and `End of File` follow Codex's patch grammar as generally known and are not separately
# verified here — an unrecognised `*** ` marker denies fail-closed instead of guessing (see the
# parser below and this repo's approved #407 plan, Open questions).
#
# Codex shell-`apply_patch` shim probe record, #407 amendment (ADR 0002 "Amendment 2026-09-26
# (2)", S0/#412, Q7): Codex puts an `apply_patch` (and `applypatch`) shim on the shell PATH,
# alongside the genuine `apply_patch` tool call above. A shell-issued `apply_patch <<'EOF' … EOF`
# heredoc ran inside the Codex workspace sandbox and WROTE `.claude/settings.local.json`; replayed
# as a `tool_name: "Bash"` payload, both v2.9.0 hooks/agent-boundary.sh and this hook (before this
# amendment) exited 0, closing no gap at all. Whether Codex reports the shell form as `Bash` or
# intercepts it as a genuine `apply_patch` tool call was NOT observed (the probe's usage limit was
# reached first) -- this hook now covers the `Bash` shape either way (see the Bash route below);
# if Codex instead always intercepts it as `apply_patch`, the route above already covers it and the
# Bash route below is simply never reached for that call.
#
# Contract: read the PreToolUse hook JSON on stdin; print nothing and exit 0 ("no opinion") unless
# the call is an Edit/Write/apply_patch/Bash from a recognised implementer/verifier agent_type
# whose target path(s) the policy below denies, or whose patch (apply_patch, or an inline
# Bash-carried patch) cannot be parsed at all, or whose Bash command word is `apply_patch`/
# `applypatch` with no inline patch this hook can see, in which case print exactly one reason line
# to stderr and exit 2 ("deny"); stdout is always empty. Wired in hooks/hooks.json via
# `${CLAUDE_PLUGIN_ROOT}`, with no "if" gate: the "if" field is permission-rule syntax over
# tool_input constituents only -- it cannot see agent_type, it cannot express a case-insensitive/
# nested/".." path-segment rule, and it cannot parse an apply_patch command's own patch-header
# grammar or distinguish a Bash command's own command word from an argument, so any "if" here
# would silence this hook for exactly the spellings it exists to catch (the same reasoning
# hooks/agent-boundary.sh's and hooks/push-guard.sh's own registrations already give).
#
# Documented over-blocking classes (deliberate, measured directly against this script): a path
# carrying a ".." segment with no ".claude"/".codex" anywhere denies (fail-closed, unclassifiable)
# -- measured: "/repo/../etc/passwd" -> rc 2; a non-absolute path denies -- measured: "src/main.rs"
# -> rc 2; a POSIX filename containing a literal backslash is treated as separator-bearing, which
# can manufacture a ".claude"/".codex" segment that was never a real directory boundary -- measured:
# a file_path whose real, single-component filename is "foo\.claude\bar" (backslashes are legal
# filename bytes on POSIX; no ".claude" directory exists) normalises to "/repo/foo/.claude/bar" and
# denies (rc 2) purely from the rewrite; a case-variant spelling denies even on a case-sensitive
# filesystem -- measured: "/repo/.Claude/x" -> rc 2; a test fixture the implementer or verifier must
# write under any `.claude`/`.codex` segment denies -- remedy: create such fixtures from the test
# script's own Bash, as this repo's harnesses (dev/hook-tests.sh included) already do. Since #407,
# ALSO: an apply_patch (or Bash-carried inline patch) `cwd` under a Codex-managed worktree path
# containing `.codex` (e.g. `~/.codex/worktrees/…`) denies every header in that patch, regardless
# of the header path's own spelling; a patch context (unmarked, non-header) line whose TRIMMED text
# happens to start with `*** ` (a coincidental collision with the patch grammar's own marker prefix)
# denies as an unrecognised marker, fail-closed, since this parser has no notion of "inside a hunk"
# versus "between hunks" -- the remedy is the same as every other apply_patch escape below: use
# Bash to read/inspect a suspect patch body instead of trusting this hook to pass it through; a
# Bash command that merely MENTIONS "apply_patch"/"applypatch" as its own command word inside a
# heredoc BODY line (not the shell's own command word) is not distinguished from a genuine
# invocation by is_apply_patch_word()'s segment walk -- fail-closed is the safer direction here too.
#
# Documented under-blocking classes (evasions, named rather than hidden): a Bash-issued write
# (`cat >>`, `tee`, `sed -i`) never reaches an Edit/Write/apply_patch hook by construction; since
# #340, hooks/agent-boundary.sh's own Bash policy denies the redirect/tee/cp/mv/cd-pushd/in-place-
# sed forms of that route for the implementer/verifier roles, and since #387 it also denies an
# interpreter or one-step-writer command word when the same Bash call names a `.claude` segment
# anywhere (see that hook's own header); that Bash-write class was NOT extended to `.codex` by this
# issue (#407's own plan; see its Open questions) -- an ORDINARY Bash-issued write into `.codex/`
# (e.g. `cp x .codex/y`, wholly outside the apply_patch-shim shape this amendment covers) is
# unaffected by hooks/agent-boundary.sh either way. The Bash route's own command-word check
# (is_apply_patch_word, reworked #407 kickback rounds 2/3) recognises `;`/`&`/`|`/`(`/`)`/`{`/`}`/a
# backtick as segment breaks, `<`/`>`/whitespace as word breaks within a segment (skipping a
# redirect target/source and a bare-digits fd immediately before a redirect, so a LEADING
# redirect cannot hide the command word either), matches a path-qualified spelling
# (`./apply_patch`, `/usr/local/bin/apply_patch`) by basename, and skips a leading `NAME=value`
# assignment or a hooks/agent-boundary.sh-vocabulary PREFIX_WORDS member (including
# `bash`/`sh`/`env`/`sudo`/…, so `bash -c apply_patch` now resolves past `bash -c` to `apply_patch`
# and denies) -- still quote-blind and backslash-blind like every other scan in this directory, so
# deliberate obfuscation remains OUT OF SCOPE for this tripwire, not a sandbox: a backslash-quoted
# spelling (`\apply_patch`, `a\pply_patch`, or a backslash-newline splitting the word across two
# physical lines), a quoted or variable-built spelling of the shim's own name (`"apply_patch" <
# x.patch`, `p=apply_patch; $p < x.patch`), a PREFIX_WORDS member's own OPTION that itself takes an
# argument (`nice -n 5 apply_patch`, `sudo -u root apply_patch`, `xargs -a x apply_patch` — the walk
# skips only a bare `-`-leading option after a prefix word, never one with a separate argument
# token, so the argument itself can become the "resolved" word and hide `apply_patch` one position
# further along), the `eval` builtin (`eval apply_patch < x.patch`, not itself a PREFIX_WORDS
# member), a launcher this walk does not recognise as a PREFIX_WORDS member (`uv run apply_patch`,
# `npx apply_patch`), a QUOTED `bash -c "apply_patch < x.patch"` (the whole quoted string is one
# token, `"apply_patch` glued to the rest, never split into its own inner command by this walk),
# or a genuinely different segment separator this walk does not parse (a literal newline INSIDE
# one already-broken-out segment, e.g. inside a nested subshell) can all still evade BOTH the
# belt-and-braces `.claude`/`.codex` raw-text check and the "no inline patch" deny (neither ever
# runs at all when is_apply_patch_word itself returns false) without evading the "carries an
# inline patch" deny (which matches on the patch grammar's own literal text regardless of how the
# shim was invoked, independently of command-word detection). A header line's OWN indentation is
# stripped only of ASCII space and tab (see ltrim()/trim() below) -- a header preceded by Unicode
# whitespace (e.g. U+00A0 NO-BREAK SPACE) is not recognised as a header at all and is silently
# treated as an ordinary content line instead; the belt-and-braces check's own raw-text scan
# catches this residual too WHENEVER is_apply_patch_word succeeds (it does not depend on
# recognising any header at all), so the two residuals above must BOTH apply together (a
# command-word evasion AND a Unicode-hidden header) before this specific gap reopens. Quote-blind
# over-blocking, the opposite direction, on Claude Code too (measured directly against this
# script): a commit message or an `echo` whose own text places `apply_patch`/`applypatch` between
# a matching pair of BACKTICKS denies too, even though the backticks themselves sit inside an
# ENCLOSING pair of ordinary quotes -- measured: `git commit -m "See \`apply_patch\` docs"` -> rc
# 2. Backtick is one of this walk's own segment-break characters (the same set
# hooks/agent-boundary.sh's tokenizer already treats that way); this walk never tracks the
# ENCLOSING `"..."`/`'...'` quote state at all, so it cannot tell a markdown-style code span
# quoted for a commit message apart from a genuine backtick command substitution (`` `apply_patch`
# `` really does invoke apply_patch and substitute its output, which is a correct positive, not an
# over-block) -- the remedy is the same one this repo's own CLAUDE.md and skills already give for
# every over-block a subagent hits: use the Write/Edit tools for file content, or rephrase the
# commit message, rather than relying on this hook to distinguish styling from execution. Plain
# single/double quotes alone do NOT trigger this: `echo "apply_patch is our shim"` remains one
# segment whose own first word is `echo`, so it gets no opinion, only backtick-delimited text
# does. A symlink
# or hard link whose own spelling carries no `.claude`/`.codex` segment
# (this hook performs no filesystem access, so it cannot resolve one); a write tool outside
# GUARDED_TOOLS/PATCH_TOOLS/BASH_TOOLS -- measured: no role's tools: line names MultiEdit or
# NotebookEdit today (agents/implementer.md:9, agents/verifier.md:12; gate 4.53 pins GUARDED_TOOLS
# against both roles' tools: lines, so this stays true only until a role's tools: line changes
# without a matching GUARDED_TOOLS update); any other agent role -- measured: an agent_type of
# "Explore" -> rc 0; a Claude Code that stops sending agent_type at all -- fails open, the same
# documented note hooks/agent-boundary.sh's header already carries for its own vocabulary; the
# plugin disabled, `disableAllHooks: true`, no `jq` on PATH, or an unresolved
# ${CLAUDE_PLUGIN_ROOT} -- every one degrades this hook to silent no-opinion, with no prompt and no
# visible sign, exactly as every sibling hook in this directory already documents.
set -uo pipefail

# --- vocabulary --------------------------------------------------------------------------------
# Grep-extractable single-line KEY="value" declarations (the 2.5/4.36-4.42 idiom). The two
# AGENT_TYPES_* lines are copied byte-identically from hooks/agent-boundary.sh:57-58 -- see this
# file's header cross-reference and dev/selfcheck.sh's assertion 4.45.
AGENT_TYPES_IMPLEMENTER="implementer trail-blazer-flow:implementer"
AGENT_TYPES_VERIFIER="verifier trail-blazer-flow:verifier"
GUARDED_TOOLS="Edit Write"
PATCH_TOOLS="apply_patch"
BASH_TOOLS="Bash"
GUARDED_SEGMENT=".claude"
GUARDED_SEGMENT_CODEX=".codex"
CLAUDE_DIR_DENY_STEM="trail-blazer-flow claude-dir guard:"
# PREFIX_WORDS (#407 kickback finding 2) -- copied byte-identically from
# hooks/agent-boundary.sh:148 (no gate pin added; "reuse it" per the #407 kickback approval, the
# same choice hooks/push-guard.sh's own copy already makes without a pin either). Used only by
# is_apply_patch_word() below to skip a leading shell-keyword/interpreter-indirection word (and,
# once one is seen, a following "-"-leading option) before resolving a Bash segment's own command
# word -- see that function's own comment for why this hook needs the identical vocabulary.
PREFIX_WORDS="env command builtin exec sudo nohup time nice stdbuf xargs bash sh zsh ksh dash if then elif else do while until ! coproc"

input="$(cat)"

# --- fast paths ------------------------------------------------------------------------------
# Fast path 1: a main-session Edit/Write/apply_patch/Bash call (no agent_type key in the JSON at
# all) can never resolve to a recognised role, so skip straight to "no opinion" without spawning
# jq (M1). There is deliberately no ".claude"/".codex"-substring fast path here: it would not be
# semantics-preserving the way hooks/agent-boundary.sh's second fast path is -- the unclassifiable-
# path deny class below (a non-absolute or `..`-carrying file_path, or an unparseable apply_patch
# command) can deny a call that never contains either literal substring at all, so gating on those
# substrings first would silently exit "no opinion" on exactly the fail-closed class this hook
# exists to catch.
case "$input" in
  *agent_type*) : ;;
  *) exit 0 ;;
esac

# Fast path 2 (#407 amendment A1) -- true for every call this hook could possibly act on, false
# for the overwhelming majority of ordinary Bash calls (the class #407 added a Bash route for):
# every genuine Edit/Write/apply_patch tool call's own tool_name VALUE already spells one of
# "Edit"/"Write"/"apply_patch" literally in this raw JSON, so requiring one of those three, OR
# "applypatch" (Codex's shim also answers to the no-underscore spelling), OR the patch grammar's
# own "*** Begin Patch" marker, to appear ANYWHERE in the raw stdin is safe for every route below:
# it can only ever skip a Bash call that mentions NONE of them -- which cannot possibly invoke
# apply_patch/applypatch as its command word or carry an inline "*** Begin Patch" patch either, so
# "no opinion" is the correct verdict regardless -- and it never skips a real Edit, Write, or
# apply_patch call, whose own tool_name field supplies the matching substring unconditionally.
# This is what keeps an ordinary implementer/verifier Bash call (a `git`/`gh` command, an
# ordinary read, …) from spawning jq at all now that Bash is in scope.
case "$input" in
  *Edit*|*Write*|*apply_patch*|*applypatch*|*'Begin Patch'*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

tool_name="$(printf '%s' "$input" | jq -r '.tool_name? // empty' 2>/dev/null)"
case " $GUARDED_TOOLS $PATCH_TOOLS $BASH_TOOLS " in
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

# Shared constants for both routes below: a CRLF-carrying transport can deliver a path or patch
# text whose spelling carries a trailing/embedded \r; stripping it can only WIDEN which paths
# match ".claude"/".codex" below (removing a character can only join two fragments into a segment
# this hook already looks for, never separate an already-matching segment apart) -- the same #270
# idiom hooks/agent-boundary.sh and hooks/push-guard.sh both apply at the identical point in their
# own tokenizers. Pure parameter expansion: no new process, so this hook still executes nothing
# (see this file's header).
cr=$'\r'
lf=$'\n'
tab=$'\t'

# classify_path TOOL RAW_PATH -- the shared classifier both routes call, pure builtins, no
# filesystem access at all. Order matters: the more specific ".claude"/".codex" message wins over
# the generic "unclassifiable" message whenever both could apply (e.g. a relative ".claude/..."
# path, or an absolute path carrying both a ".." segment and a ".claude" segment). Prints the
# reason line and exits 2 on any deny; returns (no output, no exit) when RAW_PATH is benign.
classify_path() {
  local tool="$1" raw="$2" p p_disp

  # Separator normalisation: a Windows-native or backslash-spelled ".claude"/".codex" still
  # denies (see README's Windows section on Git Bash's own path-form quirks). Documented
  # over-block: a POSIX filename containing a literal backslash is treated as separator-bearing
  # (see this file's header).
  p="${raw//$cr/}"
  p="${p//\\//}"

  # A literal LF byte embedded in the path (distinct from the \r stripped above) would otherwise
  # print as a second physical line inside a deny message, breaking this hook's own "exactly one
  # stderr line" contract (#327 round-1 kickback: measured, an unfixed build printed 2 stderr
  # lines). Build a PRINT-ONLY copy via pure parameter expansion (no new process) -- the
  # classifier below keeps matching against $p itself, unmodified; only the printed wording folds
  # each LF into the two-character "\n" so it renders on one line.
  p_disp="${p//$lf/\\n}"

  # ".claude" segment: matched against "/$p/" (both a LEADING and a TRAILING slash appended) so
  # the same one pattern catches a nested segment, a final segment with nothing after it, AND a
  # relative path whose very FIRST segment is ".claude" -- measured directly against this exact
  # pattern; see the case-row table in dev/hook-tests.sh's cdg-* section for every shape checked.
  # The bracket classes are the case-insensitive idiom hooks/push-guard.sh already uses for config
  # keys.
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

  # Absoluteness: /... or a Windows/Git-Bash drive-letter form (README's "Git Bash accepts
  # C:/Users/... and /c/Users/..." note; hooks/git-c-guard.sh's own PATH_ERE uses the identical
  # [A-Za-z]:/ prefix class). Anything else cannot be classified and is denied fail-closed, per the
  # triage record this issue settled (see this file's header "Live-probe record" note on M4).
  case "$p" in
    /*) ;;
    [A-Za-z]:/*) ;;
    *)
      printf '%s %s role'"'"'s %s file_path could not be classified as absolute or normalised, and is denied fail-closed: %s\n' \
        "$CLAUDE_DIR_DENY_STEM" "$role" "$tool" "$p_disp" >&2
      exit 2
      ;;
  esac

  # A ".." segment anywhere: also denied fail-closed (the same triage record) -- a future payload
  # whose path is not already normalised must not silently escape a ".claude"/".codex" check that
  # only ever looks at the literal path string.
  case "$p/" in
    */../*)
      printf '%s %s role'"'"'s %s file_path could not be classified as absolute or normalised, and is denied fail-closed: %s\n' \
        "$CLAUDE_DIR_DENY_STEM" "$role" "$tool" "$p_disp" >&2
      exit 2
      ;;
  esac
}

# deny_patch_unparseable REASON (#407) -- the apply_patch route's own fail-closed exit for a patch
# this parser cannot make sense of at all (as opposed to a parsed header whose path classify_path
# above denies). Always exits 2; the pinned phrase is "could not be parsed".
deny_patch_unparseable() {
  printf '%s %s role'"'"'s apply_patch could not be parsed (%s), and is denied fail-closed\n' \
    "$CLAUDE_DIR_DENY_STEM" "$role" "$1" >&2
  exit 2
}

# ltrim/trim S (#407) -- strip leading (ltrim) or leading+trailing (trim) spaces and tabs via
# parameter expansion only (no tr/sed, never executes anything; see this file's header). $tab is
# declared above, alongside $cr/$lf. The line loop below LEFT-trims only (indentation tolerance,
# e.g. "  *** Add File: x"), deliberately leaving any trailing whitespace on the whole line alone,
# so a header with NOTHING after its "<marker>: " prefix (e.g. "*** Add File: ", trailing space,
# nothing else) still matches that marker's own case pattern (its own trailing space plus an
# empty match for the wildcard after it) and yields an EMPTY extracted path -- denied as such,
# rather than falling through to the generic "unrecognised marker" arm. The extracted header-path
# substring itself is then full-trimmed (trim) to drop any real trailing whitespace after a
# genuine filename.
ltrim() {
  local s="$1"
  while :; do
    case "$s" in
      " "*) s="${s# }" ;;
      "$tab"*) s="${s#"$tab"}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$s"
}
trim() {
  local s
  s="$(ltrim "$1")"
  while :; do
    case "$s" in
      *" ") s="${s% }" ;;
      *"$tab") s="${s%"$tab"}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$s"
}

# parse_patch_headers TOOL PATCH_TEXT CWD (#407) -- shared by the apply_patch route and the Bash
# apply_patch-shim route below: splits PATCH_TEXT into lines (builtins only, IFS splitting under
# `set -f`/noglob, so a line beginning with the patch grammar's own literal "***" is never
# expanded as a filesystem glob -- this hook performs no filesystem access at all, see this file's
# header), calls classify_path on every Add/Update/Delete/Move-to header path (resolved against
# CWD when the header path itself is relative), and fails closed via deny_patch_unparseable on an
# empty header path, an unrecognised "*** " marker line, or zero headers found in the whole text.
# Returns normally (no output, no exit) only when every header in PATCH_TEXT is benign. The line
# loop LEFT-trims only (ltrim, indentation tolerance, e.g. "  *** Add File: x"), deliberately
# leaving any trailing whitespace on the whole line alone, so a header with NOTHING after its
# "<marker>: " prefix (e.g. "*** Add File: ", trailing space, nothing else) still matches that
# marker's own case pattern (its own trailing space plus an empty match for the wildcard after it)
# and yields an EMPTY extracted path -- denied as such, rather than falling through to the generic
# "unrecognised marker" arm. The extracted header-path substring itself is then full-trimmed
# (trim) to drop any real trailing whitespace after a genuine filename.
parse_patch_headers() {
  local ptool="$1" patch="$2" pcwd="$3" headers=0 oldifs raw_line line hdr_path p
  set -f
  oldifs="$IFS"
  IFS="$lf"
  for raw_line in $patch; do
    IFS="$oldifs"
    line="$(ltrim "$raw_line")"
    case "$line" in
      "*** Begin Patch"|"*** End Patch"|"*** End of File")
        : # structural marker, not a header; ignored
        ;;
      "*** Add File: "*|"*** Update File: "*|"*** Delete File: "*|"*** Move to: "*)
        hdr_path="$(trim "${line#*: }")"
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

# is_apply_patch_word TEXT (#407 amendment A1; reworked #407 kickback rounds 2/3) -- true iff TEXT
# (a whole tool_input.command, possibly multi-line) has a segment whose RESOLVED command word is
# exactly "apply_patch"/"applypatch", OR a path-qualified spelling of either (`./apply_patch`,
# `/usr/local/bin/apply_patch`) matched by BASENAME -- distinguishing the Bash COMMAND WORD from
# the same text appearing only as an argument (`rg apply_patch hooks/`) or inside quotes
# (`grep -n "apply_patch" x`), neither of which this walk ever treats as a leading token. Pure
# builtins: parameter-expansion substitution splits segments and words, `[[ =~ ]]` matches an
# assignment prefix or a bare-digits fd, no execve.
#
# Segment breaks (reset the assignment/PREFIX_WORDS skip at the start of every new command
# position, the same set hooks/agent-boundary.sh's own tokenizer treats as segment breaks): `;`
# `&` `|` `(` `)` `{` `}` and a backtick. Word breaks WITHIN a segment: whitespace (via ordinary
# word-splitting below) plus `<` and `>`, each replaced by a padded, near-uncollidable sentinel
# word (not a bare space) so the walk below can still see WHERE a redirect operator was -- a
# redirect never starts a new segment, but it DOES separate a command word from a glued redirect
# target or source (`apply_patch<x.patch`), and (#407 kickback round 2, finding D) a LEADING
# redirect must not let the token AFTER it (the redirect's own target/source) or a bare-digits fd
# token immediately BEFORE it (`2>/dev/null apply_patch`) be mistaken for, or hide, the command
# word: both the fd and the marker-plus-target are skipped as a unit. Within each segment, the walk
# then skips a `NAME=value` assignment prefix, then a PREFIX_WORDS member (repeat-until-exhausted,
# so `if true; then apply_patch < x.patch; fi` resolves past `then`), then — once a PREFIX_WORDS
# member has been seen — a further "-"-leading option (an option to the prefix word itself, e.g.
# `env -i apply_patch`); the first token surviving every skip is the segment's resolved command
# word, compared both in full and by basename (finding E).
is_apply_patch_word() {
  local text="$1" flat seg tok resolved base saw_prefix oldifs found=1
  local mark_in=$'\x01LT\x01' mark_out=$'\x01GT\x01'
  local assign_ere='^[A-Za-z_][A-Za-z0-9_]*='
  local digits_ere='^[0-9]+$'

  # NOTE: a literal "{"/"}" inside a `${var//[...]/...}` bracket expression confuses bash's own
  # parser (it can misread the inner "}" as closing the "${" construct itself, corrupting both the
  # pattern and everything after it -- measured directly against this exact construct under both
  # bash 5 and Apple's bash 3.2), so "{"/"}" are substituted in their own separate statements
  # rather than folded into the bracket expression below.
  # An fd duplication (`>&2`, `2>&1`, `<&0`, `>&-`) keeps its `&` as part of the redirect rather
  # than letting it act as a segment break below (#407 kickback round 3).
  text="${text//>&/>}"
  text="${text//<&/<}"
  # `>|` (noclobber override) is one redirect operator too; its `|` must not split the segment.
  text="${text//>|/>}"
  flat="${text//[;\&\|()\`]/$lf}"
  flat="${flat//\{/$lf}"
  flat="${flat//\}/$lf}"
  flat="${flat//</ $mark_in }"
  flat="${flat//>/ $mark_out }"

  oldifs="$IFS"
  set -f
  IFS="$lf"
  for seg in $flat; do
    IFS="$oldifs"
    local -a toks
    toks=($seg)
    local n="${#toks[@]}" i=0 nxt
    resolved=""
    saw_prefix=0
    while [ "$i" -lt "$n" ]; do
      tok="${toks[$i]}"
      if [ "$tok" = "$mark_in" ] || [ "$tok" = "$mark_out" ]; then
        # A run of operators (`>>`, `<>`, `<<<`) is one redirect: skip every marker in the run, then
        # the single target/source token after it (#407 kickback round 3).
        i=$((i + 1))
        while [ "$i" -lt "$n" ] && { [ "${toks[$i]}" = "$mark_in" ] || [ "${toks[$i]}" = "$mark_out" ]; }; do
          i=$((i + 1))
        done
        i=$((i + 1))
        continue
      fi
      if [[ "$tok" =~ $digits_ere ]]; then
        nxt="${toks[$((i + 1))]:-}"
        if [ "$nxt" = "$mark_in" ] || [ "$nxt" = "$mark_out" ]; then
          i=$((i + 1))
          continue
        fi
      fi
      if [[ "$tok" =~ $assign_ere ]]; then
        i=$((i + 1))
        continue
      fi
      case " $PREFIX_WORDS " in
        *" $tok "*) saw_prefix=1; i=$((i + 1)); continue ;;
      esac
      if [ "$saw_prefix" -eq 1 ]; then
        case "$tok" in
          -*) i=$((i + 1)); continue ;;
        esac
      fi
      resolved="$tok"
      break
    done
    base="${resolved##*/}"
    case "$base" in
      apply_patch|applypatch) found=0 ;;
    esac
    IFS="$lf"
  done
  set +f
  IFS="$oldifs"
  return "$found"
}

# has_exact_begin_patch_line TEXT (#407 kickback finding 3) -- true iff some line of TEXT, after
# full-trimming (leading AND trailing spaces/tabs), equals EXACTLY "*** Begin Patch". A substring
# match alone (the #407-amendment original) denied a benign command that merely MENTIONS the
# marker (`grep -rn '*** Begin Patch' hooks/`, a commit message) -- requiring an exact, whole,
# trimmed line closes that over-block. Pure builtins, same IFS-splitting idiom as
# parse_patch_headers above; never executes anything.
has_exact_begin_patch_line() {
  local text="$1" oldifs raw_line line found=1
  set -f
  oldifs="$IFS"
  IFS="$lf"
  for raw_line in $text; do
    IFS="$oldifs"
    line="$(trim "$raw_line")"
    [ "$line" = "*** Begin Patch" ] && found=0
    IFS="$lf"
  done
  set +f
  IFS="$oldifs"
  return "$found"
}

if [ "$tool_name" = "apply_patch" ]; then
  # --- apply_patch route (#407) -----------------------------------------------------------------
  # Codex's file-editing tool call: tool_input.command holds the WHOLE patch text (Codex's own
  # patch grammar), and there is no file_path at all -- see this file's header "Codex apply_patch
  # probe record".
  patch_cmd="$(printf '%s' "$input" | jq -r '.tool_input.command? // empty' 2>/dev/null)"
  [ -n "$patch_cmd" ] || deny_patch_unparseable "no command"

  cwd="$(printf '%s' "$input" | jq -r '.cwd? // empty' 2>/dev/null)"
  cwd="${cwd//$cr/}"
  cwd="${cwd//\\//}"

  # Strip every CR from the whole patch up front (#270 idiom; see the shared cr/lf/tab note
  # above) -- every line handled below is then CR-free.
  patch="${patch_cmd//$cr/}"
  parse_patch_headers "apply_patch" "$patch" "$cwd"
elif [ "$tool_name" = "Bash" ]; then
  # --- Bash apply_patch-shim route (#407 amendment A1) ------------------------------------------
  # Codex also puts an `apply_patch`/`applypatch` shim on the shell PATH; a shell-issued
  # `apply_patch <<'EOF' … EOF` heredoc (or a bare `apply_patch < x.patch`) reaches THIS hook as an
  # ordinary Bash call, with the whole heredoc body (if any) inlined into tool_input.command --
  # see the ADR 0002 amendment's S0 spike (#412, Q7): a shell-issued heredoc wrote
  # .claude/settings.local.json in the Codex sandbox while both v2.9.0 hooks/agent-boundary.sh and
  # this hook (pre-#407-amendment) exited 0 on the Bash-shaped payload.
  bash_cmd="$(printf '%s' "$input" | jq -r '.tool_input.command? // empty' 2>/dev/null)"
  [ -n "$bash_cmd" ] || exit 0
  bash_cmd="${bash_cmd//$cr/}"

  # Belt and braces (#407 kickback round 2, finding A): evaluated FIRST and UNCONDITIONALLY,
  # before either branch below, whenever apply_patch/applypatch is the resolved command word
  # anywhere in the text -- not only inside the `elif` this originally lived in. A decoy can
  # defeat has_exact_begin_patch_line (an ANSI-C-quoted ($'...') line whose "\n"s are the two
  # literal characters backslash+n, never a real line break; or a genuine SECOND real line with a
  # benign header sitting next to a first header hidden behind Unicode whitespace ltrim() never
  # strips) while still mentioning `.claude`/`.codex` in the raw text -- this catch-all does not
  # depend on the structured parse recognising anything at all.
  if is_apply_patch_word "$bash_cmd"; then
    case "$bash_cmd" in
      *.[Cc][Ll][Aa][Uu][Dd][Ee]*|*.[Cc][Oo][Dd][Ee][Xx]*)
        deny_patch_unparseable "apply_patch/applypatch invoked via Bash mentioning a .claude/.codex path anywhere in the raw command text"
        ;;
    esac
  fi

  if has_exact_begin_patch_line "$bash_cmd"; then
    # The command text carries an inline patch: parse it exactly like the apply_patch route,
    # resolved against the SAME top-level `cwd` field -- this gives the precise ".claude"/".codex"
    # segment message (via classify_path) whenever the structured patch itself names one AND the
    # belt-and-braces check above did not already deny.
    cwd="$(printf '%s' "$input" | jq -r '.cwd? // empty' 2>/dev/null)"
    cwd="${cwd//$cr/}"
    cwd="${cwd//\\//}"
    parse_patch_headers "Bash" "$bash_cmd" "$cwd"
  elif is_apply_patch_word "$bash_cmd"; then
    # The shim was invoked as the command word, but no line's trimmed text was EXACTLY
    # "*** Begin Patch", so the structured parse above never ran, and the belt-and-braces check
    # above found no .claude/.codex mention either: the shim was invoked with no inline patch text
    # this hook can see at all (e.g. `apply_patch < x.patch`, reading the patch from a file this
    # hook never opens) -- the hook cannot verify what it writes, so it denies fail-closed rather
    # than guess.
    deny_patch_unparseable "apply_patch/applypatch invoked via Bash with no inline patch text"
  fi
  # else: "apply_patch"/"applypatch" appears only as an argument or inside quoted text (e.g.
  # `rg apply_patch hooks/`, `grep -n "apply_patch" x`) -- no opinion; not this hook's concern.
else
  # --- Edit/Write route (unchanged behaviour) ---------------------------------------------------
  file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path? // empty' 2>/dev/null)"
  [ -n "$file_path" ] || exit 0
  classify_path "$tool_name" "$file_path"
fi

exit 0
