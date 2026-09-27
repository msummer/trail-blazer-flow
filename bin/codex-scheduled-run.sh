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
#   1. TBF_CODEX_RUN_TIMEOUT (default 14400) and TBF_CODEX_RUN_KILL_GRACE (default 30) — env vars,
#      seconds — must each be digits-only and greater than 0. Otherwise: preflight-failed,
#      reason=bad-timeout.
#   2. `codex`, `gh`, and `jq` must all be on PATH (launchd's own PATH is minimal, and the
#      plugin's hooks fail open without `jq`). Otherwise: preflight-failed,
#      reason=missing-tool:<comma-separated names>.
#   3. The sibling `codex-setup.sh --check`. Exit 1: preflight-failed reason=codex-setup-drift.
#      Any other non-zero exit: preflight-failed reason=codex-setup-error.
#   4. The sibling `harness-stop.sh`. Exit 3: skipped-stop reason=stop. Exit 4: skipped-stop
#      reason=stop-unknown. Exit 0: continue. Anything else: preflight-failed
#      reason=harness-stop-exit-<n>.
#   5. The sibling `harness-lock.sh status`. state=free: continue. state=held, with host equal to
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
# exit-status=, timeout-seconds=, harness-version=), prunes old records, prints exactly
# "outcome=<token> reason=<slug> record=<run dir>" as its last stdout line, and exits — 0 for
# completed/skipped-stop/skipped-busy, 1 for preflight-failed/failed/died-mid-run/timed-out. A run
# directory that can't be created exits 2 directly, with no record and no launch. record.txt's
# first line is the stable seam a durable tracking mechanism reads (I3, #428) — this script itself
# makes no GitHub call.
#
# PRUNING: only entries directly under runs/ whose name matches <8 digits>T<6 digits>Z-<digits>
# count; anything else is never touched. After each run, only the newest 100 (lexical order) are
# kept, the current run always among them. Deletion is bounded — `rm -f` of the known filenames,
# then `rmdir` (never `rm -rf`); a failed `rmdir` is a stderr warning, not forced.
#
# EXIT CODES: 0 = completed/skipped-stop/skipped-busy; 1 = preflight-failed/failed/died-mid-run/
# timed-out; 2 = usage or environment error with no record at all (CLAUDE_PID set, a bad argument,
# not inside a git checkout or git missing, or the run directory couldn't be created).
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
#   - This script is `forbidden` under the installed Codex rules and denied under Claude Code's own
#     settings (belt-and-braces with the CLAUDE_PID guard above) — see docs/reference/codex.md
#     "Rules" for what each backstop does and does not cover.
#   - `codex exec` and this wrapper's live launchd behaviour are Not supported until the live gate
#     (I4, #429) flips docs/reference/codex.md's support-matrix row.
set -uo pipefail

if [ -n "${CLAUDE_PID+set}" ]; then echo "codex-scheduled-run.sh: refusing: CLAUDE_PID is set — a Claude Code session must never launch a Codex run" >&2; exit 2; fi

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
argument, not inside a git checkout, git missing, or the run directory couldn't be created).
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
# (outcome first), prunes old records, prints the one-line summary, and exits with the outcome's
# mapped code. Never call `exit` directly past this point. Disables the TERM/INT trap as its own
# first action: #428 reads record.txt's first line, so a second signal arriving while finish is
# still writing it or pruning must not re-enter on_wrapper_signal and overwrite the outcome or the
# exit code with a signal-death — this run's own outcome is already decided by the time finish is
# called, and this bracket protects committing it, not the decision itself.
finish() {
  trap '' TERM INT
  local outcome="$1" reason="$2" ended code
  ended="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf 'outcome=%s\n' "$outcome"
    printf 'reason=%s\n' "$reason"
    printf 'started-at=%s\n' "$started_at"
    printf 'ended-at=%s\n' "$ended"
    printf 'exit-status=%s\n' "${rc:-}"
    printf 'timeout-seconds=%s\n' "${timeout:-}"
    printf 'harness-version=%s\n' "$version"
  } > "$run_dir/record.txt"
  prune_runs
  case "$outcome" in
    completed|skipped-stop|skipped-busy) code=0 ;;
    *) code=1 ;;
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

# --- preflight -----------------------------------------------------------------------------

# 1. TBF_CODEX_RUN_TIMEOUT / TBF_CODEX_RUN_KILL_GRACE — digits-only and > 0.
case "$timeout" in
  ''|*[!0-9]*) finish preflight-failed bad-timeout ;;
esac
[ "$timeout" -gt 0 ] || finish preflight-failed bad-timeout
case "$grace" in
  ''|*[!0-9]*) finish preflight-failed bad-timeout ;;
esac
[ "$grace" -gt 0 ] || finish preflight-failed bad-timeout

# 2. codex, gh, jq must all be on PATH.
missing=""
for t in codex gh jq; do
  command -v "$t" >/dev/null 2>&1 || missing="${missing:+$missing,}$t"
done
[ -z "$missing" ] || finish preflight-failed "missing-tool:$missing"

# 3. the sibling codex-setup.sh --check.
setup_out="$("$script_dir/codex-setup.sh" --check 2>&1)"
setup_rc=$?
printf '%s\n' "$setup_out" >> "$run_dir/preflight.log"
case "$setup_rc" in
  0) : ;;
  1) finish preflight-failed codex-setup-drift ;;
  *) finish preflight-failed codex-setup-error ;;
esac

# 4. the sibling harness-stop.sh.
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

# 5. the sibling harness-lock.sh status.
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
