#!/usr/bin/env bash
#
# codex-scheduled-run.sh — launchd-driven wrapper for one unattended `codex exec` pass of
# `issue-cycle` (I2, #427; ADR 0002 amendment 2026-09-27 (4), decisions 2-4). Never invoked by a
# session — a maintainer's LaunchAgent runs it on a timer (see docs/reference/codex.md
# "Scheduling unattended runs (macOS)" for the plist recipe and the honest limits).
#
# Usage:
#   codex-scheduled-run.sh
#   codex-scheduled-run.sh --help
#
# REFUSES OUTRIGHT, before anything else, when CLAUDE_PID is set (even to an empty string): a
# Claude Code session must never launch a Codex run. This is the FIRST executable check, before
# argument parsing and before any other side effect.
#
# PATH SCRUB (#444), SECOND — right after the CLAUDE_PID guard, before argument parsing and before
# the first external command (dirname, a few lines below): rebuilds PATH from only the entries
# that resolve to a physical path outside /tmp, $TMPDIR, the discovered work-tree root, and any git
# directory. A relative or empty entry is refused outright; an entry that doesn't resolve (doesn't
# exist) is dropped silently; a surviving entry is kept in its PHYSICAL form, never its original
# spelling. If nothing survives, the wrapper exits 2 immediately (no run directory, no record);
# otherwise any refusal is remembered and reported by preflight step 1 below. Builtins only (case,
# parameter expansion, cd, pwd -P, [ -ef ]) — no external command runs before this. See "Honest
# limits" below for what it does not cover.
#
# WHAT IT DOES, IN ORDER:
#   1. Runs a no-model-turn preflight (below). Any failing step stops the chain there.
#   2. Launches exactly:
#        codex exec --cd <repo toplevel> -s workspace-write --json -o <run dir>/last-message.md
#          "<fixed prompt>" < /dev/null > <run dir>/events.jsonl 2> <run dir>/stderr.log
#      in the background, under a wall-clock watchdog. Nothing else is on the argv: no
#      --dangerously-*, --approve-for-me, danger-full-access, --ignore-rules,
#      --ignore-user-config, --ephemeral, and no `resume`/`fork` subcommand. The fixed prompt names
#      trail-blazer-flow:issue-cycle and carries, on its own line, exactly
#      "Harness mode: unattended (codex exec)" — see docs/reference/codex.md's "Unattended runs
#      (`codex exec`)" for what that marker triggers in-session.
#   3. Classifies the result into one of seven outcome tokens (below) and writes a local run
#      record, then prunes old records to the newest 100.
#
# NEVER TOUCHES THE LOCK: this script does not call `harness-lock.sh acquire` or `release`, and
# never removes anything under trail-blazer/lock. A dead same-host holder is left for the launched
# session itself to reclaim (bin/harness-lock.sh's own reclaim rule).
#
# PREFLIGHT (no model turn, no quota spent), each failing step stopping the chain there:
#   1. The PATH scrub above already ran, before any external command. If it refused any entry:
#      preflight-failed, reason=unsafe-path.
#   2. TBF_CODEX_RUN_TIMEOUT (default 14400) and TBF_CODEX_RUN_KILL_GRACE (default 30) — env vars,
#      seconds — must each be digits-only and greater than 0. Otherwise: preflight-failed,
#      reason=bad-timeout.
#   3. `codex`, `gh`, and `jq` must all be on PATH (launchd's own PATH is minimal, and the
#      plugin's hooks fail open without `jq`). Otherwise: preflight-failed,
#      reason=missing-tool:<comma-separated names>.
#   4. The sibling `codex-setup.sh --check`. Exit 1: preflight-failed reason=codex-setup-drift.
#      Any other non-zero exit: preflight-failed reason=codex-setup-error.
#   5. The sibling `harness-stop.sh`. Exit 3: skipped-stop reason=stop. Exit 4: skipped-stop
#      reason=stop-unknown. Exit 0: continue. Anything else: preflight-failed
#      reason=harness-stop-exit-<n>.
#   6. The sibling `harness-lock.sh status`. state=free: continue. state=held, with host equal to
#      `uname -n`, a digits-only pid, and that pid no longer alive: continue (the launched session
#      reclaims the lock itself). Any other state=held: skipped-busy, reason one of
#      live-holder, other-host, or unreadable-holder. A non-zero exit, or no state= line:
#      preflight-failed reason=lock-status-unreadable.
#   Every sibling call's combined output is appended to preflight.log in the run directory.
#
# OWN-DIRECTORY SIBLINGS ONLY: codex-setup.sh, harness-stop.sh and harness-lock.sh are invoked only
# as "$script_dir/<name>.sh" — never resolved off PATH — so a same-named script earlier on
# launchd's PATH is never run. This deliberately differs from bin/harness-status.sh and
# bin/reconcile-ledger.sh, which try PATH first (#408).
#
# WATCHDOG: polls codex's own liveness in 1-second slices (macOS has no `timeout`/`gtimeout`
# binary, and there is deliberately no long killable sleep to begin with — see the watchdog
# function's own comment below for why). After TBF_CODEX_RUN_TIMEOUT seconds without codex exiting
# on its own, it creates <run dir>/watchdog-fired and sends TERM; after up to
# TBF_CODEX_RUN_KILL_GRACE more seconds (still polled) it sends KILL. Timeout granularity is 1
# second. If codex exits first, the watchdog notices on its next poll and returns; at worst, one
# already-started 1-second poll outlives it briefly and ends on its own.
#
# CLASSIFICATION, in order:
#   1. watchdog-fired exists            -> timed-out,     reason=after-<n>s
#   2. exit status > 128                -> died-mid-run,  reason=signal-<status-128>
#   3. any other non-zero exit          -> failed,         reason=exit-<n>
#   4. exit 0 but last-message.md missing or empty -> failed, reason=no-final-message
#   5. exit 0, last-message.md has a line that is EXACTLY "Unattended stop: permission-denied"
#      (a whole-line match on the file, no pipe) -> failed, reason=unattended-stop-permission-denied
#   6. otherwise                        -> completed
#   (a TERM/INT to the wrapper itself, at ANY point, short-circuits all of the above to
#   died-mid-run reason=wrapper-signal-<n> instead — see below. That includes during preflight,
#   before codex is ever launched; died-mid-run there does not imply a launch happened.)
#
# RUN RECORD: created at <abs git-common-dir>/trail-blazer/runs/<YYYYMMDDTHHMMSSZ>-<wrapper pid>/
# (the same `git rev-parse --git-common-dir` -> `cd ... && pwd -P` idiom bin/harness-lock.sh and
# bin/harness-stop.sh use — a sandboxed codex invocation can't create this itself, because .git is
# read-only under workspace-write). Every exit past that point goes through one `finish` function,
# which writes record.txt (outcome=<token> first, then reason=, started-at=, ended-at=,
# exit-status=, timeout-seconds=, harness-version=), prunes old records, runs the failure-tracking
# step below and appends its own tracking=<token> line (plus tracking-issue=<n> when one is
# involved), prints exactly "outcome=<token> reason=<slug> record=<run dir>" as its last stdout
# line, and exits — 0 for completed/skipped-stop/skipped-busy, 1 for
# preflight-failed/failed/died-mid-run/timed-out, 3 when the tracking step itself failed (see
# below, and it overrides 0/1). A run directory that can't be created exits 2 directly, with no
# record and no launch.
#
# FAILURE TRACKING (I3, #428): runs once inside `finish`, after record.txt's first 7 lines are
# written and prune_runs has run — never on an exit-2 path, and never while a session is running.
# `gh` is resolved once, at preflight step 0, to one absolute path (gh_bin), off the PATH already
# scrubbed at startup (#444, see "PATH SCRUB" above) — so a `gh` a sandboxed Codex session could
# have planted in the workspace it controls is never on that PATH to begin with, let alone the one
# this step executes.
#   - completed: nothing happens unless the local state below already says streak=failing, in
#     which case one `gh issue comment` posts a body starting "Recovered: ..." and the state moves
#     to streak=recovered. A completed run with no failing streak makes no GitHub call at all.
#   - preflight-failed / failed / died-mid-run / timed-out: with no tracked issue (or one that
#     can't be read back), one `gh issue create --label needs-human --label no-plan` opens a new
#     issue and records its number with streak=failing (the labels themselves are never created
#     here — see bin/setup-labels.sh). With a tracked issue still OPEN and streak=failing, nothing
#     new is posted (tracking=repeat) — the de-duplication the issue title asks for. With a tracked
#     issue OPEN and streak=recovered (failing again after a recovery), one `gh issue comment`
#     posts on it and streak moves back to failing. With the tracked issue CLOSED, a new issue is
#     opened the same way as the no-state case.
#   State lives at <abs git-common-dir>/trail-blazer/scheduled-failure-issue, written atomically,
#   as exactly two lines, `issue=<n>` and `streak=failing|recovered`. It is never inside runs/, so
#   prune_runs never touches it, and it is never tracked or committed.
#   The issue body and every comment are built only from values this wrapper itself generated —
#   the outcome token, the reason slug, the run id (the run directory's own basename), the
#   started-at/ended-at UTC timestamps, the exit status, and the literal record path
#   trail-blazer/runs/<run id>/record.txt — never stderr.log's or last-message.md's own text, a
#   hostname, or an absolute path. A `usage-limit` hint line is added only when stderr.log exists
#   and contains that phrase (case-insensitive); the phrase itself is never quoted into the body.
#   The only `gh` subcommands this step ever runs are `issue view`, `issue create` and
#   `issue comment`, each with `< /dev/null` on stdin and gh's own stderr going straight to this
#   wrapper's own stderr (the local launchd log) — never `gh pr`, `gh api`, `gh label`,
#   `issue edit` or `issue close`, and no label is ever removed.
#   If `gh` isn't on PATH, or any `gh` call itself fails, record.txt gets one more line,
#   `tracking=failed:<slug>`, and the whole run exits 3 instead of its usual 0/1 — never silently. A
#   line to this wrapper's own stderr names the slug, worded per slug: `create-unparsed` and
#   `state-write-failed` both say GitHub may already have been (or was) updated — a `gh issue
#   create` that succeeds but can't be locally recorded still gets `tracking-issue=<n>` in
#   record.txt when the number was parsed, even though the local state file itself is left
#   untouched (its own atomic write either fully replaces it or leaves it exactly as it was, never
#   partially); every other slug says GitHub was not updated. The next run retries from whatever
#   state was actually persisted.
#
# PRUNING: only entries directly under runs/ whose name matches <8 digits>T<6 digits>Z-<digits>
# count; anything else is never touched. After each run, only the newest 100 (lexical order) are
# kept, the current run always among them. Deletion is bounded — `rm -f` of the known filenames,
# then `rmdir` (never `rm -rf`); a failed `rmdir` is a stderr warning, not forced.
#
# EXIT CODES: 0 = completed/skipped-stop/skipped-busy; 1 = preflight-failed/failed/died-mid-run/
# timed-out; 2 = usage or environment error with no record at all (CLAUDE_PID set, a bad argument,
# no safe PATH entry survived the startup scrub (#444), not inside a git checkout or git missing,
# or the run directory couldn't be created); 3 = the outcome above was recorded, but the
# failure-tracking step (I3, #428) itself could not reach GitHub or persist its own state — see
# FAILURE TRACKING above. 3 always overrides 0/1 for that run.
#
# IF THE WRAPPER ITSELF IS KILLED (TERM or INT — e.g. `launchctl bootout`, an operator, a logout):
# a top-level trap stops the watchdog and gives the launched codex process the same
# TERM-then-poll-then-KILL treatment described above, then reports died-mid-run through the SAME
# single `finish` exit path as every other outcome — never a new eighth token, whether or not a
# launch had happened yet. Without this, codex and the watchdog would both survive the wrapper, and
# the watchdog's own later kill of the stored codex_pid could land on a since-reused pid instead.
# The real `codex` CLI is a Node launcher that forwards SIGTERM to a spawned native binary from a JS
# handler — killing it outright immediately after TERM, with no time to run that handler, would
# orphan the native child, which is exactly why this uses the same poll as the watchdog rather than
# an immediate KILL.
#
# HONEST LIMITS:
#   - SIGKILL (a Unix process can never trap it) still leaves codex and the watchdog running with no
#     record.txt — TERM/INT are the only signals this script can react to at all. Whether a real
#     launchd, on an ordinary `bootout`, sends TERM before ever escalating to KILL is not verified
#     here (I4, #429); if it does not wait, or if the launched codex is itself SIGKILLed some other
#     way, launchd's own default process-group reaping (active whenever a LaunchAgent does not set
#     `AbandonProcessGroup`) is the backstop that would still clean up the process group's other
#     members — also unverified until #429.
#   - Two small windows are not closed: between starting codex and recording `codex_pid=$!`, and
#     between starting the watchdog and recording `wd_pid=$!`. A TERM/INT landing in either leaves
#     that one variable unset, so on_wrapper_signal has nothing to target for that one process — a
#     narrow gap this script does not close.
#   - Whether time spent with the machine asleep counts toward the timeout is not verified.
#   - Two wrapper instances against one checkout (a manual run beside a scheduled one) can both
#     observe state=free; the session-level `acquire` then refuses one of them, after that
#     model turn has already started.
#   - PATH SCRUB (#444) limits: the work-tree root it protects is found by default git discovery
#     from the current directory, so a plist setting GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR is
#     outside this check. Only /tmp, $TMPDIR, that work-tree root, and a git directory are ever
#     treated as protected — any OTHER writable root in the maintainer's own Codex config (for
#     example an added sandbox_workspace_write root) must be kept off the plist PATH by hand. When
#     the wrapper is launched through its shebang (`#!/usr/bin/env bash`), `bash` itself is found
#     through the plist's own PATH before this scrub ever runs — see the plist recipe below for the
#     `/bin/bash` `ProgramArguments` fix.
#   - This script is `forbidden` under the installed Codex rules and denied under Claude Code's own
#     settings (belt-and-braces with the CLAUDE_PID guard above) — see docs/reference/codex.md
#     "Rules" for what each backstop does and does not cover.
#   - `codex exec` and this wrapper's live launchd behaviour are Not supported until the live gate
#     (I4, #429) flips docs/reference/codex.md's support-matrix row.
set -uo pipefail

if [ -n "${CLAUDE_PID+set}" ]; then echo "codex-scheduled-run.sh: refusing: CLAUDE_PID is set — a Claude Code session must never launch a Codex run" >&2; exit 2; fi

# --- PATH scrub (#444) -----------------------------------------------------------------------
#
# Runs before argument parsing and before the first external command this script would otherwise
# run (dirname, below): rebuilds PATH from only the entries a sandboxed Codex session could not
# have planted an executable into. Builtins only (case, parameter expansion, cd, pwd -P, [ -ef ]).

# slash_tmp — the literal path this script treats as "the world-writable /tmp". A plain assignment
# that never reads the environment, so no environment variable can widen or narrow what it
# protects. dev/doctor-tests.sh rewrites this EXACT line, in its own copy of this script, to point
# at a fixture-private stand-in instead of the real /tmp, so a fixture's own stub tree (itself
# created under a real mktemp root) is not wrongly refused; that rewrite is the only thing that
# ever changes this line's value.
slash_tmp=/tmp

# path_dir_protected DIR — true when DIR is, by IDENTITY (-ef, never a text compare — the same
# case/firmlink reasoning the old gh_path_safe documented), $slash_tmp, $TMPDIR (when set and
# non-empty), the discovered work-tree root ($path_top, below), or a git directory (a HEAD file
# plus objects/ and refs/ directories — this catches the git common dir without ever running git).
path_dir_protected() {
  local p
  for p in "$slash_tmp" "${TMPDIR:-}" "$path_top"; do [ -n "$p" ] || continue; [ "$1" -ef "$p" ] && return 0; done
  [ -f "$1/HEAD" ] && [ -d "$1/objects" ] && [ -d "$1/refs" ] && return 0
  return 1
}

# path_refuse ENTRY — records ENTRY as unsafe (path_unsafe, read by preflight step 1 below) and
# names it, %q-quoted so a hostile entry can't inject control characters into the terminal, on
# stderr.
path_refuse() {
  path_unsafe=true
  printf 'codex-scheduled-run.sh: refusing PATH entry %q: relative, or at/inside the repo, a git directory, /tmp or $TMPDIR\n' "$1" >&2
}

# path_top — the work-tree root discovered upward from the CURRENT directory, without ever running
# git (git's own first call is still a few lines below, after this whole scrub). Left empty only
# when pwd -P itself fails. When no ancestor up to / holds a .git entry, path_top stays at its
# initial value — the current directory itself — so a plist WorkingDirectory outside any git
# checkout still protects itself (though nothing above it), rather than protecting nothing at all.
path_top="$(pwd -P 2>/dev/null)"; path_walk="$path_top"
while [ -n "$path_walk" ]; do
  if [ -e "$path_walk/.git" ]; then path_top="$path_walk"; break; fi
  [ "$path_walk" = / ] && break
  path_walk="${path_walk%/*}"; [ -n "$path_walk" ] || path_walk=/
done

# The scrub loop. Split PATH explicitly rather than word-splitting on IFS/`for`, which would
# silently drop a trailing empty field and glob an unquoted entry. `last` is checked at the TOP of
# the loop (not right after handling each entry), so every `continue` below — including the
# missing-entry drop, which never sets path_unsafe — is safe even on the final field: the next
# pass around simply sees `last` already true and stops, rather than an empty path_rest being
# mistaken for one more (bogus) entry.
path_unsafe=false; path_safe=""; path_rest="${PATH-}"; last=false
while :; do
  $last && break
  case "$path_rest" in
    *:*) e="${path_rest%%:*}"; path_rest="${path_rest#*:}" ;;
    *) e="$path_rest"; last=true ;;
  esac
  case "$e" in
    /*) : ;;
    *) path_refuse "$e"; continue ;;
  esac
  d="$(cd -P "$e" 2>/dev/null && pwd -P)"
  [ -n "$d" ] || continue
  walk="$d"
  entry_unsafe=false
  while :; do
    path_dir_protected "$walk" && { entry_unsafe=true; break; }
    [ "$walk" = / ] && break
    walk="${walk%/*}"; [ -n "$walk" ] || walk=/
  done
  if $entry_unsafe; then
    path_refuse "$e"
  else
    path_safe="${path_safe:+$path_safe:}$d"
  fi
done

[ -n "$path_safe" ] || { echo "codex-scheduled-run.sh: refusing: no safe PATH entry survived the scrub — nothing left to run codex/gh/jq from" >&2; exit 2; }
PATH="$path_safe"

usage() {
  cat <<'EOF'
usage: codex-scheduled-run.sh
       codex-scheduled-run.sh --help

Launchd-driven wrapper for one unattended `codex exec` pass of `issue-cycle` (#427). Never run
this from inside a Claude Code or Codex session — it refuses outright when CLAUDE_PID is set, and
is `forbidden`/denied under both hosts' own installed rules. See docs/reference/codex.md
"Scheduling unattended runs (macOS)" for the LaunchAgent recipe.

Env vars:
  TBF_CODEX_RUN_TIMEOUT      Wall-clock seconds before the watchdog sends TERM (default 14400).
  TBF_CODEX_RUN_KILL_GRACE   Seconds after TERM before the watchdog sends KILL (default 30).

Outcome tokens (first line of the run record's record.txt, and this script's last stdout line):
  completed  skipped-stop  skipped-busy  preflight-failed  failed  died-mid-run  timed-out

Exit codes: 0 = completed/skipped-stop/skipped-busy, 1 = preflight-failed/failed/died-mid-run/
timed-out, 2 = usage or environment error with no run record at all (CLAUDE_PID set, a bad
argument, no safe PATH entry survived the startup scrub, not inside a git checkout, git missing, or
the run directory couldn't be created), 3 = the outcome was recorded but the GitHub
failure-tracking step (I3, #428) itself failed; 3 overrides 0/1.
EOF
}

case "$#" in
  0) : ;;
  1)
    case "$1" in
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
  *) usage >&2; exit 2 ;;
esac

script_dir="$(cd "$(dirname "$0")" && pwd)"

if ! command -v git >/dev/null 2>&1; then
  echo "codex-scheduled-run.sh: git not found on PATH" >&2
  exit 2
fi

toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$toplevel" ]; then
  echo "codex-scheduled-run.sh: not inside a git repository (git rev-parse --show-toplevel failed)" >&2
  exit 2
fi
common="$(git rev-parse --git-common-dir 2>/dev/null)"
if [ -z "$common" ]; then
  echo "codex-scheduled-run.sh: not inside a git repository (git rev-parse --git-common-dir failed)" >&2
  exit 2
fi
common_abs="$(cd "$common" 2>/dev/null && pwd -P)"
if [ -z "$common_abs" ]; then
  echo "codex-scheduled-run.sh: could not resolve the git common dir to an absolute path: $common" >&2
  exit 2
fi
cd "$toplevel" || { echo "codex-scheduled-run.sh: could not cd to $toplevel" >&2; exit 2; }

# state_file — the failure-tracking step's own local state (I3, #428): exactly two lines,
# issue=<n> and streak=failing|recovered. Sits beside runs/ and lock/, never inside runs/ (so
# prune_runs never sees it), and is never tracked or committed.
state_file="$common_abs/trail-blazer/scheduled-failure-issue"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
runs_root="$common_abs/trail-blazer/runs"
if ! mkdir -p "$runs_root" 2>/dev/null; then
  echo "codex-scheduled-run.sh: cannot create $runs_root (unwritable git dir?)" >&2
  exit 2
fi
run_dir="$runs_root/$stamp-$$"
if ! mkdir "$run_dir" 2>/dev/null; then
  echo "codex-scheduled-run.sh: cannot create run directory $run_dir" >&2
  exit 2
fi

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
timeout="${TBF_CODEX_RUN_TIMEOUT:-14400}"
grace="${TBF_CODEX_RUN_KILL_GRACE:-30}"
rc=""
ended_at=""

# Failure-tracking globals (I3, #428) — st_issue/st_streak are read_track_state's own output;
# tracking/tracking_issue are track_outcome's own output, read back by finish. gh_bin is
# pre-declared here, empty, BEFORE the TERM/INT traps are installed below: preflight step 0 is what
# actually resolves it, off the PATH already scrubbed at startup (#444), but a signal landing in
# the window between the traps going live and step 0 running would otherwise reach track_outcome
# with gh_bin unbound under `set -u`, killing the wrapper with rc 127 and no record/summary line at
# all instead of the ordinary died-mid-run path.
st_issue=""
st_streak=""
tracking=""
tracking_issue=""
TRACK_TITLE="Scheduled Codex runs are failing"
gh_bin=""

version="unknown"
if command -v jq >/dev/null 2>&1; then
  v="$(jq -r '.version // "unknown"' "$script_dir/../.claude-plugin/plugin.json" 2>/dev/null || true)"
  [ -n "$v" ] && [ "$v" != "null" ] && version="$v"
fi

# pid_alive PID — liveness on THIS host: kill -0 first, ps -p as a fallback (the EPERM case),
# failing CLOSED (treated as alive) when neither can answer — a copy of bin/harness-lock.sh's own
# (its header lines 138-148).
pid_alive() {
  local p="$1"
  if kill -0 "$p" 2>/dev/null; then
    return 0
  fi
  if command -v ps >/dev/null 2>&1; then
    ps -p "$p" >/dev/null 2>&1
    return $?
  fi
  return 0
}

# prune_runs — deletes the oldest entries under runs_root beyond the newest 100, bounded: rm -f of
# the known filenames then rmdir, never rm -rf. Only names matching the stamp-and-pid shape count;
# everything else (a stray file, an unrelated directory) is never touched. The current run is
# never removed.
prune_runs() {
  local d name suffix runs=()
  for d in "$runs_root"/*; do
    [ -d "$d" ] || continue
    name="${d##*/}"
    case "$name" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-*)
        suffix="${name##*-}"
        case "$suffix" in
          ''|*[!0-9]*) continue ;;
        esac
        runs+=("$name")
        ;;
    esac
  done
  local total="${#runs[@]}"
  [ "$total" -gt 100 ] || return 0
  local excess=$((total - 100)) removed=0 old current
  current="${run_dir##*/}"
  while IFS= read -r old; do
    [ "$removed" -lt "$excess" ] || break
    [ -n "$old" ] || continue
    [ "$old" = "$current" ] && continue
    rm -f "$runs_root/$old/record.txt" "$runs_root/$old/argv.txt" "$runs_root/$old/preflight.log" \
          "$runs_root/$old/last-message.md" "$runs_root/$old/events.jsonl" \
          "$runs_root/$old/stderr.log" "$runs_root/$old/watchdog-fired"
    if ! rmdir "$runs_root/$old" 2>/dev/null; then
      echo "codex-scheduled-run.sh: warning: rmdir $runs_root/$old failed — an unexpected file may remain inside it" >&2
    fi
    removed=$((removed + 1))
  done <<EOF
$(printf '%s\n' "${runs[@]}" | sort)
EOF
}

# finish OUTCOME REASON — the SINGLE exit path once the run directory exists: writes record.txt
# (outcome first), prunes old records, runs the failure-tracking step (I3, #428) and appends its
# own tracking=<token> line, prints the one-line summary, and exits with the outcome's mapped code
# (3 when tracking itself failed, overriding 0/1). Never call `exit` directly past this point.
# Disables the TERM/INT trap as its own first action: this run's own outcome is already decided by
# the time finish is called, so a second signal arriving while finish is still writing record.txt,
# pruning, or tracking must not re-enter on_wrapper_signal and overwrite the outcome or the exit
# code with a signal-death — this bracket protects committing the decision, not the decision
# itself.
finish() {
  trap '' TERM INT
  local outcome="$1" reason="$2" code
  ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf 'outcome=%s\n' "$outcome"
    printf 'reason=%s\n' "$reason"
    printf 'started-at=%s\n' "$started_at"
    printf 'ended-at=%s\n' "$ended_at"
    printf 'exit-status=%s\n' "${rc:-}"
    printf 'timeout-seconds=%s\n' "${timeout:-}"
    printf 'harness-version=%s\n' "$version"
  } > "$run_dir/record.txt"
  prune_runs
  track_outcome "$outcome" "$reason"
  {
    printf 'tracking=%s\n' "$tracking"
    [ -n "$tracking_issue" ] && printf 'tracking-issue=%s\n' "$tracking_issue"
  } >> "$run_dir/record.txt"
  case "$outcome" in
    completed|skipped-stop|skipped-busy) code=0 ;;
    *) code=1 ;;
  esac
  case "$tracking" in
    failed:*) code=3 ;;
  esac
  case "$tracking" in
    failed:state-write-failed)
      echo "codex-scheduled-run.sh: tracking failed (state-write-failed): GitHub WAS updated, but the local tracking state could not be saved; the run record is kept at $run_dir" >&2
      ;;
    failed:create-unparsed)
      echo "codex-scheduled-run.sh: tracking failed (create-unparsed): an issue may already have been created on GitHub, but its number could not be parsed; the run record is kept at $run_dir" >&2
      ;;
    failed:*)
      echo "codex-scheduled-run.sh: tracking failed (${tracking#failed:}): GitHub was not updated; the run record is kept at $run_dir" >&2
      ;;
  esac
  echo "outcome=$outcome reason=$reason record=$run_dir"
  exit "$code"
}

# on_wrapper_signal SIGNUM — installed for TERM and INT: if something kills this wrapper process
# itself (launchd unloading the job, an operator, a logout), its own children would otherwise
# survive it — the watchdog and the launched codex process — and the watchdog's own later kill of
# $codex_pid could then land on a since-reused pid. Stops the watchdog, then gives codex the same
# TERM-then-poll-then-KILL treatment the watchdog itself uses: the real `codex` CLI is a Node
# launcher that spawns the native binary and forwards SIGTERM to it from a JS handler, so a KILL
# arriving immediately after TERM can kill the launcher before it forwards, orphaning the native
# child — polling for up to $grace seconds (1-second slices, same granularity as the watchdog)
# gives that handler time to run. Reports through the SAME single `finish` exit path as every other
# outcome — died-mid-run, never a new eighth token, whether or not a launch had actually happened
# yet. Installed only once finish's own dependencies (run_dir, started_at, timeout, version)
# already exist; a signal earlier than that has nothing to clean up (nothing forked yet).
on_wrapper_signal() {
  local signum="$1"
  [ -n "${wd_pid:-}" ] && kill -TERM "$wd_pid" 2>/dev/null
  if [ -n "${codex_pid:-}" ]; then
    kill -TERM "$codex_pid" 2>/dev/null
    local deadline=$((SECONDS + grace))
    while [ "$SECONDS" -lt "$deadline" ] && kill -0 "$codex_pid" 2>/dev/null; do
      sleep 1
    done
    kill -0 "$codex_pid" 2>/dev/null && kill -KILL "$codex_pid" 2>/dev/null  # on_wrapper_signal's own post-grace escalation
  fi
  rc=$((128 + signum))
  finish died-mid-run "wrapper-signal-$signum"
}
trap 'on_wrapper_signal 15' TERM
trap 'on_wrapper_signal 2' INT

# --- failure tracking on GitHub (I3, #428) --------------------------------------------------
#
# Everything below is called only from `finish`, after record.txt already has its outcome
# committed to disk. Every `gh` call is a bare `"$gh_bin" ... < /dev/null`, never piped, with gh's
# own stderr going straight to this wrapper's stderr — never captured into a value this script
# then reuses.

# read_track_state — sets the globals st_issue/st_streak from $state_file, both left empty when
# the file is absent OR unreadable (a non-digit issue=, an unknown streak=, or a missing key). An
# unreadable (but present) file also gets a stderr warning; a merely absent file does not, since
# "no tracked issue yet" is the ordinary first-failure case, not a problem.
read_track_state() {
  st_issue=""
  st_streak=""
  [ -f "$state_file" ] || return 0
  local line issue="" streak=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      issue=*)
        issue="${line#issue=}"
        case "$issue" in
          ''|*[!0-9]*) issue="" ;;
        esac
        ;;
      streak=*)
        streak="${line#streak=}"
        case "$streak" in
          failing|recovered) : ;;
          *) streak="" ;;
        esac
        ;;
    esac
  done < "$state_file"
  if [ -n "$issue" ] && [ -n "$streak" ]; then
    st_issue="$issue"
    st_streak="$streak"
  else
    echo "codex-scheduled-run.sh: warning: unreadable tracking state file $state_file — treating as absent" >&2
  fi
}

# write_track_state N STREAK — writes $state_file atomically (a per-process temp file, then `mv
# -f`), returning 1 on any failure so the caller can report tracking=failed:state-write-failed
# rather than silently leaving the on-disk state stale.
write_track_state() {
  local n="$1" streak="$2" tmp
  mkdir -p "$common_abs/trail-blazer" 2>/dev/null
  tmp="$state_file.tmp.$$"
  if { printf 'issue=%s\n' "$n"; printf 'streak=%s\n' "$streak"; } > "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$state_file" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# track_body OUTCOME REASON [LEAD] — prints the issue/comment body, built only from values this
# wrapper itself generated: $outcome, $reason, the run id (${run_dir##*/}, never the full
# $run_dir), $started_at, $ended_at, ${rc:-none}, and the literal path
# trail-blazer/runs/<run id>/record.txt. Never reads stderr.log's or last-message.md's own text
# into the body (only a boolean grep on stderr.log, below), never calls uname, and never
# interpolates $run_dir/$toplevel/$common_abs themselves.
track_body() {
  local outcome="$1" reason="$2" lead="${3:-}" id
  id="${run_dir##*/}"
  [ -n "$lead" ] && printf '%s\n\n' "$lead"
  printf 'A scheduled `codex exec` run (bin/codex-scheduled-run.sh) did not complete.\n\n'
  printf -- '- Outcome: `%s`\n' "$outcome"
  printf -- '- Reason: `%s`\n' "$reason"
  printf -- '- Run id: `%s`\n' "$id"
  printf -- '- Started (UTC): %s\n' "$started_at"
  printf -- '- Ended (UTC): %s\n' "$ended_at"
  printf -- '- Exit status: `%s`\n' "${rc:-none}"
  printf -- '- Record: `trail-blazer/runs/%s/record.txt` under `git rev-parse --git-common-dir` on the machine that ran it.\n' "$id"
  if [ -f "$run_dir/stderr.log" ] && grep -qiF -- 'usage limit' "$run_dir/stderr.log"; then
    printf '\nHint: `usage-limit` — the run'"'"'s stderr mentions a usage limit; check the Codex quota and sign-in.\n'
  fi
  printf '\nClose this issue once handled; the next failure after a success opens or reuses one.\n'
}

# track_create OUTCOME REASON — opens a new tracking issue and records it with streak=failing.
# Parses the created issue's number off the LAST stdout line matching */issues/<digits> (a `while
# read` plus `case`, no pipe into anything). A create that succeeds but can't be parsed, or a
# failed state write after it, is reported distinctly so the maintainer isn't left thinking no
# issue exists when one may already have been created.
track_create() {
  local outcome="$1" reason="$2" out gh_rc n line
  out="$("$gh_bin" issue create --title "$TRACK_TITLE" --body "$(track_body "$outcome" "$reason")" \
      --label needs-human --label no-plan < /dev/null)"
  gh_rc=$?
  if [ "$gh_rc" -ne 0 ]; then
    tracking="failed:create-failed"
    echo "codex-scheduled-run.sh: tracking: gh issue create failed — check that the needs-human/no-plan labels exist (bin/setup-labels.sh)" >&2
    return
  fi
  n=""
  while IFS= read -r line; do
    case "$line" in
      */issues/*[0-9])
        n="${line##*/issues/}"
        case "$n" in
          ''|*[!0-9]*) n="" ;;
        esac
        ;;
    esac
  done <<EOF
$out
EOF
  if [ -z "$n" ]; then
    tracking="failed:create-unparsed"
    echo "codex-scheduled-run.sh: tracking: could not parse the created issue number from gh's own output — an issue may already have been created" >&2
    return
  fi
  echo "codex-scheduled-run.sh: tracking: created issue #$n (needs-human)" >&2
  if write_track_state "$n" failing; then
    tracking="created"
    tracking_issue="$n"
  else
    tracking="failed:state-write-failed"
    tracking_issue="$n"
    echo "codex-scheduled-run.sh: tracking: issue #$n was created on GitHub, but the local tracking state could not be saved — the next run will not know about it and may create another" >&2
  fi
}

# track_outcome OUTCOME REASON — the failure-tracking step itself (I3, #428). Sets the globals
# $tracking and $tracking_issue, read back by `finish`. Every branch that can call `gh` checks the
# gh guard (empty gh_bin — the startup PATH scrub, #444, means an unresolved `gh` is now the only
# way this guard can fire) first and returns without executing anything when it fails — the
# OPEN)/transition-if/streak=recovered-write/exit-code lines below are each kept on their own line,
# on purpose, so a mutant touching any one of them stays textually distinct from the others.
track_outcome() {
  local outcome="$1" reason="$2"
  tracking=none
  tracking_issue=""
  case "$outcome" in
    skipped-stop|skipped-busy)
      return
      ;;
    completed)
      read_track_state
      if [ "$st_streak" != failing ]; then
        return
      fi
      if [ -z "$gh_bin" ]; then
        tracking="failed:gh-not-found"
        return
      fi
      local body gh_rc
      body="Recovered: scheduled Codex run \`${run_dir##*/}\` completed (started $started_at, ended $ended_at UTC); record \`trail-blazer/runs/${run_dir##*/}/record.txt\`."
      "$gh_bin" issue comment "$st_issue" --body "$body" >/dev/null < /dev/null
      gh_rc=$?
      if [ "$gh_rc" -ne 0 ]; then
        tracking="failed:comment-failed"
        return
      fi
      if write_track_state "$st_issue" recovered; then
        tracking="recovered"
        tracking_issue="$st_issue"
      else
        tracking="failed:state-write-failed"
        tracking_issue="$st_issue"
        echo "codex-scheduled-run.sh: tracking: the recovery comment was posted on issue #$st_issue, but the local tracking state could not be saved" >&2
      fi
      return
      ;;
    preflight-failed|failed|died-mid-run|timed-out)
      : ;;
    *)
      return
      ;;
  esac

  if [ -z "$gh_bin" ]; then
    tracking="failed:gh-not-found"
    return
  fi

  read_track_state
  if [ -z "$st_issue" ] || [ -z "$st_streak" ]; then
    track_create "$outcome" "$reason"
    return
  fi

  local st gh_rc
  st="$("$gh_bin" issue view "$st_issue" --json state --jq .state < /dev/null)"
  gh_rc=$?
  if [ "$gh_rc" -ne 0 ]; then
    tracking="failed:view-failed"
    return
  fi
  case "$st" in
    OPEN)
      if [ "$st_streak" = failing ]; then
        tracking="repeat"
        return
      fi
      local gh_rc2
      "$gh_bin" issue comment "$st_issue" --body "$(track_body "$outcome" "$reason" 'Failing again after a recovery.')" >/dev/null < /dev/null
      gh_rc2=$?
      if [ "$gh_rc2" -ne 0 ]; then
        tracking="failed:comment-failed"
        return
      fi
      if write_track_state "$st_issue" failing; then
        tracking="commented"
        tracking_issue="$st_issue"
      else
        tracking="failed:state-write-failed"
        tracking_issue="$st_issue"
        echo "codex-scheduled-run.sh: tracking: the comment was posted on issue #$st_issue, but the local tracking state could not be saved" >&2
      fi
      ;;
    CLOSED)
      track_create "$outcome" "$reason"
      ;;
    *)
      tracking="failed:view-unexpected"
      ;;
  esac
}

# --- preflight -----------------------------------------------------------------------------

# 0. Resolve `gh` for the failure-tracking step (I3, #428), before any session exists, off the PATH
# already scrubbed at startup (#444) — a `gh` a sandboxed Codex session could have planted is never
# on this PATH to begin with, so no further check is needed here.
gh_bin="$(command -v gh 2>/dev/null || true)"

# 1. The PATH scrub above already ran, before any external command. Report it here if it refused
# any entry.
$path_unsafe && finish preflight-failed unsafe-path

# 2. TBF_CODEX_RUN_TIMEOUT / TBF_CODEX_RUN_KILL_GRACE — digits-only and > 0.
case "$timeout" in
  ''|*[!0-9]*) finish preflight-failed bad-timeout ;;
esac
[ "$timeout" -gt 0 ] || finish preflight-failed bad-timeout
case "$grace" in
  ''|*[!0-9]*) finish preflight-failed bad-timeout ;;
esac
[ "$grace" -gt 0 ] || finish preflight-failed bad-timeout

# 3. codex, gh, jq must all be on PATH.
missing=""
for t in codex gh jq; do
  command -v "$t" >/dev/null 2>&1 || missing="${missing:+$missing,}$t"
done
[ -z "$missing" ] || finish preflight-failed "missing-tool:$missing"

# 4. the sibling codex-setup.sh --check.
setup_out="$("$script_dir/codex-setup.sh" --check 2>&1)"
setup_rc=$?
printf '%s\n' "$setup_out" >> "$run_dir/preflight.log"
case "$setup_rc" in
  0) : ;;
  1) finish preflight-failed codex-setup-drift ;;
  *) finish preflight-failed codex-setup-error ;;
esac

# 5. the sibling harness-stop.sh.
stop_out="$("$script_dir/harness-stop.sh" 2>&1)"
stop_rc=$?
printf '%s\n' "$stop_out" >> "$run_dir/preflight.log"
stop_reason=""
[ "$stop_rc" -eq 3 ] && stop_reason=stop
[ "$stop_rc" -eq 4 ] && stop_reason=stop-unknown
case "$stop_rc" in
  0) : ;;
  3|4) finish skipped-stop "$stop_reason" ;;
  *) finish preflight-failed "harness-stop-exit-$stop_rc" ;;
esac

# 6. the sibling harness-lock.sh status.
lock_out="$("$script_dir/harness-lock.sh" status 2>&1)"
lock_rc=$?
printf '%s\n' "$lock_out" >> "$run_dir/preflight.log"
[ "$lock_rc" -eq 0 ] || finish preflight-failed lock-status-unreadable
lock_state="$(printf '%s\n' "$lock_out" | sed -n 's/^state=//p' | head -1)"
case "$lock_state" in
  free)
    :
    ;;
  held)
    held_host="$(printf '%s\n' "$lock_out" | sed -n 's/^host=//p' | head -1)"
    held_pid="$(printf '%s\n' "$lock_out" | sed -n 's/^pid=//p' | head -1)"
    this_host="$(uname -n)"
    lock_reason=""
    if [ "$held_host" != "$this_host" ]; then
      lock_reason=other-host
    else
      case "$held_pid" in
        ''|*[!0-9]*) lock_reason=unreadable-holder ;;
        *)
          if pid_alive "$held_pid"; then
            lock_reason=live-holder
          fi
          ;;
      esac
    fi
    # Same host, digits-only pid, not alive: fall through — the launched session reclaims the
    # lock itself (bin/harness-lock.sh's own reclaim rule). This wrapper never acquires it.
    [ -n "$lock_reason" ] && finish skipped-busy "$lock_reason"
    ;;
  *)
    finish preflight-failed lock-status-unreadable
    ;;
esac

# --- launch ----------------------------------------------------------------------------------

PROMPT="$(cat <<'PROMPT_EOF'
Run the trail-blazer-flow:issue-cycle skill for one bounded pass, then stop.
Harness mode: unattended (codex exec)
No human is watching this session and nobody can answer an approval prompt; follow docs/reference/codex.md "Unattended runs (`codex exec`)".
PROMPT_EOF
)"

{
  printf '%q\n' codex exec --cd "$toplevel" -s workspace-write --json -o "$run_dir/last-message.md" "$PROMPT"
} > "$run_dir/argv.txt"

codex exec --cd "$toplevel" -s workspace-write --json -o "$run_dir/last-message.md" "$PROMPT" < /dev/null > "$run_dir/events.jsonl" 2> "$run_dir/stderr.log" &
codex_pid=$!

# watchdog — plain-bash wall-clock timer (macOS has no timeout/gtimeout binary): polls codex's own
# liveness in 1-second slices, rather than blocking in one long killable sleep. There is deliberately
# no signal trap here at all: if the watchdog process itself is killed (by the top-level handler
# below, or anything else) while it is inside a `sleep 1` call, that one call is a plain foreground
# child — it becomes an orphan for at most one second and then exits on its own, nothing to clean up.
# A single long background `sleep` killed from a trap is not used: a signal that reaches the bash
# child between its fork and its exec into `sleep` is swallowed by the inherited trap, so the sleep
# outlives the watchdog. Polling leaves no long sleep to kill. The loops also do not count `sleep 1`
# iterations, because each slice's own fork/exec/timer overhead accumulates past the budget: both
# loops below compute a deadline once from bash's own $SECONDS (available since bash 3.2) and compare
# against it directly, so the overshoot is bounded by at most one in-flight slice, matching the
# 1-second granularity documented above.
watchdog() {
  local deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ] && kill -0 "$codex_pid" 2>/dev/null; do
    sleep 1
  done
  kill -0 "$codex_pid" 2>/dev/null || return 0
  : > "$run_dir/watchdog-fired"
  kill -TERM "$codex_pid" 2>/dev/null
  deadline=$((SECONDS + grace))
  while [ "$SECONDS" -lt "$deadline" ] && kill -0 "$codex_pid" 2>/dev/null; do
    sleep 1
  done
  kill -0 "$codex_pid" 2>/dev/null && kill -KILL "$codex_pid" 2>/dev/null  # watchdog's own post-grace escalation
}
watchdog >/dev/null 2>&1 &
wd_pid=$!

# 2>/dev/null: when the watchdog kills codex on a timeout, bash's own job-control notice
# ("Terminated: 15") would otherwise land in launchd's error log; the redirect only silences that
# diagnostic, not the exit status, which $? still captures correctly on the next line.
wait "$codex_pid" 2>/dev/null
rc=$?
kill -TERM "$wd_pid" 2>/dev/null
wait "$wd_pid" 2>/dev/null

# --- classification ----------------------------------------------------------------------------

if [ -f "$run_dir/watchdog-fired" ]; then
  finish timed-out "after-${timeout}s"
fi
if [ "$rc" -gt 128 ]; then
  finish died-mid-run "signal-$((rc - 128))"
fi
if [ "$rc" -ne 0 ]; then
  finish failed "exit-$rc"
fi
if [ ! -s "$run_dir/last-message.md" ]; then
  finish failed no-final-message
fi
if grep -qxF -- 'Unattended stop: permission-denied' "$run_dir/last-message.md"; then
  finish failed unattended-stop-permission-denied
fi
finish completed ""
