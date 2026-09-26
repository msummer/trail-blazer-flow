#!/usr/bin/env bash
#
# harness-lock.sh — single-flight lock: at most one active harness cycle per checkout.
#
# Usage:
#   harness-lock.sh acquire [--owner-pid <pid>]
#   harness-lock.sh release <run-id> | release --force
#   harness-lock.sh status
#   harness-lock.sh --help
#
# An atomic `mkdir` of <git-common-dir>/trail-blazer/lock (git rev-parse --git-common-dir, so
# every worktree of one checkout shares a single lock — never inside the tracked tree, never
# committed). The lock directory holds six plain files: run-id, pid, host, started-at,
# harness-version, checkout-path.
#
# EXIT CODES: 0 = success (acquired, released, or a status query in either state); 2 = usage or
# environment error (bad/missing arguments, not inside a git repository, a malformed owner pid, an
# owner that is a Codex app-server daemon); 3 = conflict (the lock is held by someone else, or a
# release's run-id doesn't match the current holder).
#
# RECLAIM RULE — applied only when `acquire` finds the lock already held:
#   - the stored record is unreadable (pid or host file missing/empty, or pid is not
#     digits-only)  -> REFUSE (never reclaim an unreadable record; remedy: release --force)
#   - stored host != `uname -n`                                    -> REFUSE (different host)
#   - stored host == `uname -n` and the stored pid is still alive  -> REFUSE (live holder)
#   - stored host == `uname -n` and the stored pid is NOT alive    -> RECLAIM (prints one audit
#     line quoting the stale record, then acquires normally)
#
# RECORDED-PID RULE (RESOLVED, measured live 2026-09-08; extended #408): the recorded pid's
# precedence is `--owner-pid <pid>` (highest) > `TBF_OWNER_PID` > `${CLAUDE_PID:-$PPID}` (lowest,
# the original rule). Under Claude Code, every Bash tool call runs in a FRESH shell whose pid is
# already dead by the time the next tool call starts (measured: one call saw $PPID=19328 /
# $$=19330; from the very next call, both were dead, while the ancestor `claude` session process
# was still alive and exported as CLAUDE_PID). Recording the invoking shell's bare $PPID would
# therefore make the very next `acquire` see a dead pid and reclaim its own lock — an inert
# guard. CLAUDE_PID is the Claude Code SESSION process, which outlives individual tool calls, so
# it is used when present; $PPID (the invoking shell's own parent) is the fallback for a human
# running this script by hand from an interactive shell. A non-empty CLAUDE_PID that is not
# digits-only is ignored (falls back to $PPID) and prints one `note=` line naming the ignored
# value. `--owner-pid`/`TBF_OWNER_PID` have no such fallback: a present-but-not-digits-only value
# is a usage error (exit 2), never silently ignored, because a caller that names an owner
# explicitly (the Codex contract below) gets an explicit failure rather than a silently wrong one.
# The run id is `run-<YYYYMMDDTHHMMSSZ>-<recorded pid>`, using that same pid.
# CLAUDE_CODE_SESSION_ID is deliberately NOT written to the lock — it belongs to the (future)
# JSONL run-journal follow-up, not this lock.
#
# CODEX CALLER CONTRACT (#408): Codex sets neither CLAUDE_PID nor TBF_OWNER_PID, and under
# `codex exec`/`codex --no-daemon` the session's own native `codex` process is every shell call's
# $PPID for the whole session (ADR 0002 P6) — so bare $PPID already works there. A harness session
# started under the DEFAULT Codex TUI instead runs inside a shared, long-lived `app-server`
# daemon, whose pid would never die and so would never let a later acquire reclaim; run Codex
# sessions with `codex --no-daemon`, and pass the session's own pid explicitly with
# `harness-lock.sh acquire --owner-pid "$PPID"` for a caller that can't rely on this script's
# fallback order. `acquire` also refuses outright (exit 2, before creating anything) when the
# resolved owner's own command line names `app-server` — see the DAEMON REFUSAL paragraph below.
#
# DAEMON REFUSAL (#408): before creating any lock file, `acquire` reads the resolved owner pid's
# own command line (`ps -o command= -p <pid>`, read-only, capture-then-test — never piped into
# `grep -q`). A command line containing `app-server` names a Codex managed app-server daemon
# (ADR 0002 amendment 2026-09-26(2), Q2): such an owner outlives every session it serves, so a
# lock recorded against it could never be reclaimed by a dead-pid check. `acquire` refuses (exit 2,
# stderr names `codex --no-daemon`) rather than record it. When `ps` can't answer (its output is
# empty — e.g. Git-Bash's `ps` has no `-o`), this check fails OPEN (proceeds) rather than refuse on
# a guess; see HONEST LIMITS below.
#
# HONEST LIMITS: advisory, not a kernel mutex — `mkdir` atomicity holds on a local filesystem
# only, not a synced/shared network volume, where the host-equality assumption also breaks down.
# Same-host only: a lock held on a different machine is never inspected for liveness, only
# refused. Pid reuse (a dead pid recycled by an unrelated process before this script re-checks
# it) fails CLOSED — such a lock refuses, never silently reclaims; the remedy is always
# `release --force`. A run interrupted (Ctrl-C, crash) inside a still-live Claude Code session
# leaves its lock held until that session exits or a human runs `release --force` — the recorded
# pid (the session) outlives the interrupted run. The daemon refusal above fails OPEN, not closed,
# when `ps` can't answer: a daemon owner that slips through only ever produces a
# never-reclaimed lock, with the same `release --force` remedy as any other unreclaimable lock.
#
# Read-only except its own lock directory: never touches the tracked working tree, makes no
# network call. #233 landed bin/harness-version.sh; this file's own direct `jq .version` read
# below is deliberately retained rather than shelling out to that script — one extra process per
# acquire for a single field isn't worth it, and this file's six-file lock-record layout is
# unaffected either way.
set -uo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

# The subcommand vocabulary — kept as one grep-extractable line (dev/selfcheck.sh's 4.36
# extracts this exact KEY="value" shape, the same idiom as hooks/git-c-guard.sh's
# GIT_C_SUBCOMMANDS= and bin/reconcile-ledger.sh's STAGES=).
LOCK_SUBCOMMANDS="acquire release status"

usage() {
  cat <<'EOF'
usage: harness-lock.sh acquire [--owner-pid <pid>]
       harness-lock.sh release <run-id> | release --force
       harness-lock.sh status
       harness-lock.sh --help

Single-flight lock for one harness checkout: an atomic `mkdir` of
<git-common-dir>/trail-blazer/lock (every worktree of one checkout shares it). The lock
directory holds six plain files: run-id, pid, host, started-at, harness-version, checkout-path.

  acquire          Create the lock. Prints `run-id=<id>` as the LAST stdout line on success
                    (exit 0). If already held: refuses (exit 3, prints the holder record) unless
                    the holder is on this same host and its pid is no longer alive, in which case
                    it reclaims (exit 0, one audit line first, then a new run-id). Refuses (exit 2,
                    before creating anything) when the resolved owner pid is a Codex app-server
                    daemon — run Codex sessions with `codex --no-daemon` instead.
  release <run-id>  Remove the lock only if its stored run-id matches (exit 0); a mismatch
                    refuses (exit 3, prints the holder record); no lock present -> `released=none`
                    (exit 0).
  release --force   Remove whatever lock is present regardless of owner, printing what was
                    removed (exit 0); no lock present -> `released=none` (exit 0).
  status            Always exits 0. Prints `state=free` or `state=held` plus `lock-path=<path>`,
                    and the holder record when held.
  -h, --help        This text (exit 0).

Recorded pid precedence: `--owner-pid <pid>` > `TBF_OWNER_PID` > `${CLAUDE_PID:-$PPID}`. Under
Claude Code, CLAUDE_PID is the long-lived session process (exported to every Bash tool call); a
Claude Code Bash tool call itself runs in a fresh shell whose own pid is already dead by the next
call, so recording bare $PPID there would make the very next acquire reclaim its own lock. $PPID
(the invoking shell's parent) is the fallback for a human running this script by hand. A
non-digits CLAUDE_PID is ignored (one `note=` line) and falls back to $PPID too; a
non-digits-only `--owner-pid`/`TBF_OWNER_PID` value is a usage error instead (exit 2), not
silently ignored. On Codex, pass the session's own pid explicitly: `harness-lock.sh acquire
--owner-pid "$PPID"`.

Exit codes: 0 = success, 2 = usage/environment error (including a malformed owner pid or a
Codex app-server daemon owner), 3 = conflict (held, or release mismatch).
EOF
}

# --- small helpers -----------------------------------------------------------------------------

# pid_alive PID — liveness on THIS host: `kill -0` first (0 = alive); on failure, fall back to
# `ps -p` (covers the EPERM case, where kill -0 fails even though the process exists and is
# owned by someone else). If ps itself isn't available to decide either, fail CLOSED (treat as
# alive) rather than reclaim on a guess.
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

# print_holder — the six-field record at $lockdir, one "key=value" line each, missing files
# reading as empty. Never fails even on a partial/unreadable record.
print_holder() {
  echo "run-id=$(cat "$lockdir/run-id" 2>/dev/null)"
  echo "pid=$(cat "$lockdir/pid" 2>/dev/null)"
  echo "host=$(cat "$lockdir/host" 2>/dev/null)"
  echo "started-at=$(cat "$lockdir/started-at" 2>/dev/null)"
  echo "harness-version=$(cat "$lockdir/harness-version" 2>/dev/null)"
  echo "checkout-path=$(cat "$lockdir/checkout-path" 2>/dev/null)"
}

# remove_lock — bounded deletion: rm -f only the six known filenames, then rmdir (never rm -rf,
# and never anywhere outside $lockdir). An rmdir failure (an unexpected extra file inside) is
# reported, not forced.
remove_lock() {
  rm -f "$lockdir/run-id" "$lockdir/pid" "$lockdir/host" "$lockdir/started-at" \
        "$lockdir/harness-version" "$lockdir/checkout-path"
  if ! rmdir "$lockdir" 2>/dev/null; then
    echo "harness-lock.sh: warning: rmdir $lockdir failed — an unexpected file may remain inside it" >&2
  fi
}

# write_record PID — writes all six files for a newly (re)acquired lock, using PID as the
# recorded pid.
write_record() {
  local p="$1" id
  id="run-$(date -u +%Y%m%dT%H%M%SZ)-${p}"
  printf '%s' "$id" > "$lockdir/run-id"
  printf '%s' "$p" > "$lockdir/pid"
  printf '%s' "$(uname -n)" > "$lockdir/host"
  printf '%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lockdir/started-at"
  printf '%s' "$version" > "$lockdir/harness-version"
  printf '%s' "$(pwd -P)" > "$lockdir/checkout-path"
}

# resolved_pid — computes ${CLAUDE_PID:-$PPID} per the header's RECORDED-PID RULE, printing one
# `note=` line (stderr) first when a present-but-non-digits CLAUDE_PID is ignored.
resolved_pid() {
  local raw="${CLAUDE_PID:-}"
  case "$raw" in
    '') printf '%s' "$PPID" ;;
    *[!0-9]*)
      echo "note=ignored non-digits CLAUDE_PID '$raw' — using \$PPID ($PPID) instead" >&2
      printf '%s' "$PPID"
      ;;
    *) printf '%s' "$raw" ;;
  esac
}

# --- subcommands ---------------------------------------------------------------------------

cmd_acquire() {
  # --- argument parsing (#408) --------------------------------------------------------------
  # `--owner-pid <pid>` only; anything else (an unknown flag, a bare `--owner-pid` with no
  # value, or a stray positional argument) is a usage error. This runs in the MAIN shell, never
  # inside a `$(…)` command substitution, so a validation failure's `exit 2` actually aborts —
  # the same reason the owner-pid resolution and the daemon check below never run inside one.
  local owner_flag="" owner_flag_set=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --owner-pid)
        shift
        if [ "$#" -eq 0 ]; then
          usage >&2
          exit 2
        fi
        owner_flag="$1"
        owner_flag_set=true
        shift
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done

  # --- owner resolution (#408) --------------------------------------------------------------
  # Precedence: --owner-pid > TBF_OWNER_PID > ${CLAUDE_PID:-$PPID} (resolved_pid's existing
  # rule, note= fallback and all). The flag and the env var each get their OWN digits-only check
  # here — unlike CLAUDE_PID, a malformed explicit owner is a usage error, not a silent fallback.
  local used_pid
  if $owner_flag_set; then
    case "$owner_flag" in
      ''|*[!0-9]*)
        echo "harness-lock.sh: --owner-pid value must be digits-only, got '$owner_flag'" >&2
        exit 2
        ;;
      *) used_pid="$owner_flag" ;;
    esac
  elif [ -n "${TBF_OWNER_PID:-}" ]; then
    case "$TBF_OWNER_PID" in
      *[!0-9]*)
        echo "harness-lock.sh: TBF_OWNER_PID value must be digits-only, got '$TBF_OWNER_PID'" >&2
        exit 2
        ;;
      *) used_pid="$TBF_OWNER_PID" ;;
    esac
  else
    used_pid="$(resolved_pid)"
  fi

  # --- daemon refusal (#408) ----------------------------------------------------------------
  # Read-only: the resolved owner's own command line, capture-then-test (never piped into
  # `grep -q` — CLAUDE.md's grep-quiet-mode class, #255). A command line naming "app-server"
  # is a Codex managed app-server daemon (ADR 0002 amendment 2026-09-26(2)) — such an owner
  # outlives every session it serves, so a lock recorded against it could never be reclaimed.
  # When `ps` can't answer (empty output — e.g. Git-Bash's `ps` has no `-o`), this fails OPEN
  # (proceeds) rather than refuse on a guess; see the header's HONEST LIMITS.
  local owner_cmd
  owner_cmd="$(ps -o command= -p "$used_pid" 2>/dev/null || true)"
  case "$owner_cmd" in
    *app-server*)
      echo "harness-lock.sh: owner pid $used_pid is a Codex app-server daemon (command: $owner_cmd) — a daemon outlives every session it serves, so its lock would never be reclaimed; run the harness with codex --no-daemon instead" >&2
      exit 2
      ;;
  esac

  if ! mkdir -p "$lockroot" 2>/dev/null; then
    echo "harness-lock.sh: cannot create $lockroot (unwritable git dir?) — out of scope, see header" >&2
    exit 2
  fi

  if mkdir "$lockdir" 2>/dev/null; then
    write_record "$used_pid"
    echo "run-id=$(cat "$lockdir/run-id")"
    exit 0
  fi

  # Lock already held — apply the reclaim rule.
  local held_pid held_host this_host bad_record
  held_pid="$(cat "$lockdir/pid" 2>/dev/null || true)"
  held_host="$(cat "$lockdir/host" 2>/dev/null || true)"
  this_host="$(uname -n)"

  bad_record=false
  [ -n "$held_pid" ] || bad_record=true
  [ -n "$held_host" ] || bad_record=true
  case "$held_pid" in ''|*[!0-9]*) bad_record=true ;; esac

  if $bad_record; then
    echo "harness-lock.sh: lock held with an unreadable record — refusing to reclaim it" >&2
    print_holder >&2
    echo "remedy: harness-lock.sh release --force" >&2
    exit 3
  fi

  if [ "$held_host" != "$this_host" ]; then
    echo "harness-lock.sh: lock held by a different host ('$held_host') — refusing" >&2
    print_holder >&2
    echo "remedy: harness-lock.sh release --force" >&2
    exit 3
  fi

  if pid_alive "$held_pid"; then
    echo "harness-lock.sh: lock held by a live process (pid $held_pid) on this host — refusing" >&2
    print_holder >&2
    echo "remedy: harness-lock.sh release --force" >&2
    exit 3
  fi

  # Same host, pid not alive -> stale. Print exactly one audit line quoting the stale record,
  # then reclaim.
  echo "stale reclaim: run-id=$(cat "$lockdir/run-id" 2>/dev/null) pid=$held_pid host=$held_host started-at=$(cat "$lockdir/started-at" 2>/dev/null) harness-version=$(cat "$lockdir/harness-version" 2>/dev/null) checkout-path=$(cat "$lockdir/checkout-path" 2>/dev/null)"
  remove_lock
  if ! mkdir "$lockdir" 2>/dev/null; then
    echo "harness-lock.sh: lost the race reclaiming the lock — refusing" >&2
    exit 3
  fi
  write_record "$used_pid"
  echo "run-id=$(cat "$lockdir/run-id")"
  exit 0
}

cmd_release() {
  local arg="${1:-}"

  if [ "$arg" != "--force" ] && [ -z "$arg" ]; then
    usage >&2
    exit 2
  fi

  if [ ! -d "$lockdir" ]; then
    echo "released=none"
    exit 0
  fi

  if [ "$arg" = "--force" ]; then
    print_holder
    remove_lock
    exit 0
  fi

  local stored
  stored="$(cat "$lockdir/run-id" 2>/dev/null || true)"
  if [ "$stored" = "$arg" ]; then
    remove_lock
    exit 0
  fi

  echo "harness-lock.sh: run-id mismatch — refusing to release a lock this run did not acquire" >&2
  print_holder >&2
  echo "remedy: harness-lock.sh release --force" >&2
  exit 3
}

cmd_status() {
  if [ -d "$lockdir" ]; then
    echo "state=held"
    echo "lock-path=$lockdir"
    print_holder
  else
    echo "state=free"
    echo "lock-path=$lockdir"
  fi
  exit 0
}

# --- dispatch ------------------------------------------------------------------------------

sub="${1:-}"
case "$sub" in
  -h|--help) usage; exit 0 ;;
esac
case " $LOCK_SUBCOMMANDS " in
  *" $sub "*) : ;;
  *) usage >&2; exit 2 ;;
esac
shift

common="$(git rev-parse --git-common-dir 2>/dev/null)"
if [ -z "$common" ]; then
  echo "harness-lock.sh: not inside a git repository (git rev-parse --git-common-dir failed)" >&2
  exit 2
fi
common_abs="$(cd "$common" 2>/dev/null && pwd -P)"
if [ -z "$common_abs" ]; then
  echo "harness-lock.sh: could not resolve the git common dir to an absolute path: $common" >&2
  exit 2
fi
lockroot="$common_abs/trail-blazer"
lockdir="$lockroot/lock"

version="unknown"
if command -v jq >/dev/null 2>&1; then
  v="$(jq -r '.version // "unknown"' "$script_dir/../.claude-plugin/plugin.json" 2>/dev/null || true)"
  [ -n "$v" ] && [ "$v" != "null" ] && version="$v"
fi

case "$sub" in
  acquire) cmd_acquire "$@" ;;
  release) cmd_release "$@" ;;
  status)  cmd_status "$@" ;;
esac
