#!/usr/bin/env bash
#
# harness-lock.sh — single-flight lock: at most one active harness cycle per checkout.
#
# Usage:
#   harness-lock.sh acquire [--owner-pid <pid>]
#   harness-lock.sh release <run-id> | release --force
#   harness-lock.sh status
#   harness-lock.sh journal <run-id> stage=<s> issue=<n> outcome=<o> [retries=<k>] [deploy=<d>]
#                           [harness=<v>] [pr=<n>] [branch=<b>] [reason=<r>]
#   harness-lock.sh --help
#
# An atomic `mkdir` of <git-common-dir>/trail-blazer/lock (git rev-parse --git-common-dir, so
# every worktree of one checkout shares a single lock — never inside the tracked tree, never
# committed). The lock directory holds six plain files: run-id, pid, host, started-at,
# harness-version, checkout-path.
#
# EXIT CODES: 0 = success (acquired, released, or a status query in either state); 2 = usage or
# environment error (bad/missing arguments, not inside a git repository, a malformed owner pid, an
# owner that is a Codex app-server daemon); 3 = conflict (the lock is held by someone else, a
# release's run-id doesn't match the current holder, or a stale-lock reclaim is already in
# progress or was interrupted — the reclaim marker below); 1 = a `journal` write failed (the
# `journal` subcommand only — acquire/release/status never exit 1 on a journal failure).
#
# RECLAIM RULE — applied only when `acquire` finds the lock already held:
#   - the stored record is unreadable (pid or host file missing/empty, or pid is not
#     digits-only)  -> REFUSE (never reclaim an unreadable record; remedy: release --force)
#   - stored host != `uname -n`                                    -> REFUSE (different host)
#   - stored host == `uname -n` and the stored pid is still alive  -> REFUSE (live holder)
#   - stored host == `uname -n` and the stored pid is NOT alive    -> RECLAIM, but only while
#     holding the reclaim marker (below): prints one audit line quoting the stale record, then
#     acquires normally
#
# RECLAIM MARKER (#482): two contenders can both judge one holder stale, so a reclaim is
# serialized behind a second atomic `mkdir` of the sibling directory
# <git-common-dir>/trail-blazer/reclaim (never inside lock/, so remove_lock's rmdir is never
# blocked by it). Only the process that creates it may delete the stale record. Under the marker
# the holder's run-id and pid are re-read and compared with what the stale check saw; a changed
# record, or a pid that is alive again, releases the marker and REFUSES (exit 3), deleting
# nothing. An `acquire` that finds the marker already present REFUSES at once (exit 3, naming the
# marker and `release --force`) — it never waits on the marker and never clears it by itself, so
# a marker is only ever removed by the process that took it, or by `release --force`. The marker
# is removed after the critical section on every non-crash path. `status` reports a present
# marker as `reclaim=held` / `reclaim-pid=<pid>` after the other lines; `release --force` clears
# it and prints `reclaim=cleared` / `reclaim-pid=<pid>`.
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
# CLAUDE_CODE_SESSION_ID is deliberately NOT written to the lock — it is recorded in each run
# journal record's `session` field instead (RUN JOURNAL below).
#
# RUN JOURNAL (#251): an append-only, identifiers-only JSONL audit trail at
# <git-common-dir>/trail-blazer/journal/<run-id>.jsonl, one file per run, one line per event.
# `acquire` (fresh or stale-reclaim) creates the run's file with an `acquire` record (a reclaim
# adds `reclaimed_run_id`) and prunes the directory to the newest JOURNAL_KEEP run files; `release`
# and `release --force` append `release`/`release-force`; `journal <run-id> key=value ...` appends
# one `stage` record for the orchestrating skills, only to a file `acquire` already created. Every
# value is held to an explicit character set and length cap, so a record can carry no prose,
# secret, or issue/PR text, and the run id must have the run-id shape before it becomes a file
# name. A symlink or non-regular file/directory at the journal path is refused. A journal failure
# inside acquire/release never changes their exit status, stdout, or lock files (one stderr
# `warning: journal` line); only the `journal` subcommand itself exits 1. `session` is
# CLAUDE_CODE_SESSION_ID only when it matches [A-Za-z0-9-]{1,64}, else "".
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
# A reclaim marker left behind by an `acquire` killed mid-reclaim (SIGKILL, power loss, Ctrl-C)
# blocks every later stale reclaim — a fresh acquire of a free lock is unaffected — until
# `release --force`; there is deliberately no trap and no auto-clearing. `release --force` run
# while a reclaim is live is a human override and can let a second reclaimer in. A fresh
# `mkdir` of the lock directory does not consult the marker: one that lands between a reclaimer's
# remove_lock and its own mkdir wins the lock, and the reclaimer then refuses ("lost the race").
# The run journal is advisory and local-only, not tamper-evident (anything with write access to
# .git can edit it, and the model holds the grant to append false stage records); a missing
# record does not prove nothing happened. Append atomicity assumes a local filesystem, like the
# lock, and a check-then-append window (a symlink swapped in between) remains. The skills' calls
# to `journal` are prompt-enforced, like their acquire/release placement.
#
# Writes only under <git-common-dir>/trail-blazer/ (the lock directory, the reclaim marker, and
# the run journal): never touches the tracked working tree, makes no network call. #233 landed bin/harness-version.sh; this file's own direct `jq .version` read
# below is deliberately retained rather than shelling out to that script — one extra process per
# acquire for a single field isn't worth it, and this file's six-file lock-record layout is
# unaffected either way.
set -uo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

# The subcommand vocabulary — kept as one grep-extractable line (dev/selfcheck.sh's 4.36
# extracts this exact KEY="value" shape, the same idiom as hooks/git-c-guard.sh's
# GIT_C_SUBCOMMANDS= and bin/reconcile-ledger.sh's STAGES=).
LOCK_SUBCOMMANDS="acquire release status journal"

# Newest run-journal files kept by acquire's prune (one line so fixtures can grep it).
JOURNAL_KEEP=500

usage() {
  cat <<'EOF'
usage: harness-lock.sh acquire [--owner-pid <pid>]
       harness-lock.sh release <run-id> | release --force
       harness-lock.sh status
       harness-lock.sh journal <run-id> stage=<s> issue=<n> outcome=<o> [retries=<k>] [deploy=<d>]
                               [harness=<v>] [pr=<n>] [branch=<b>] [reason=<r>]
       harness-lock.sh --help

Single-flight lock for one harness checkout: an atomic `mkdir` of
<git-common-dir>/trail-blazer/lock (every worktree of one checkout shares it). The lock
directory holds six plain files: run-id, pid, host, started-at, harness-version, checkout-path.

  acquire          Create the lock. Prints `run-id=<id>` as the LAST stdout line on success
                    (exit 0). If already held: refuses (exit 3, prints the holder record) unless
                    the holder is on this same host and its pid is no longer alive, in which case
                    it reclaims (exit 0, one audit line first, then a new run-id) while holding
                    the `reclaim/` marker, and refuses (exit 3) if the record changed under it or
                    the marker is already present (a reclaim in progress, or one interrupted —
                    remedy: `release --force`). Refuses (exit 2, before creating anything) when
                    the resolved owner pid is a Codex app-server daemon — run Codex sessions
                    with `codex --no-daemon` instead.
  release <run-id>  Remove the lock only if its stored run-id matches (exit 0); a mismatch
                    refuses (exit 3, prints the holder record); no lock present -> `released=none`
                    (exit 0).
  release --force   Remove whatever lock is present regardless of owner, printing what was
                    removed (exit 0); no lock present -> `released=none` (exit 0). Also removes a
                    `reclaim/` marker if one exists, printing `reclaim=cleared` and
                    `reclaim-pid=<pid>` first.
  status            Always exits 0. Prints `state=free` or `state=held` plus `lock-path=<path>`,
                    and the holder record when held; then, only when a reclaim marker exists,
                    `reclaim=held` and `reclaim-pid=<pid>`.
  journal <run-id> key=value...
                    Append one identifiers-only `stage` record to the run's journal file
                    <git-common-dir>/trail-blazer/journal/<run-id>.jsonl and print
                    `journal=written` (exit 0). Required keys: stage, issue, outcome; optional:
                    retries, deploy, harness, pr, branch, reason. An unknown/duplicate key, a value
                    outside its character set or length cap, or a malformed run id is a usage error
                    (exit 2, nothing written); a missing run file (only acquire creates it), a
                    symlink, or a failed write exits 1. acquire/release also write lock events to
                    the journal, best effort.
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
Codex app-server daemon owner), 3 = conflict (held, release mismatch, or a reclaim marker),
1 = a `journal` write failed (journal subcommand only).
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

# remove_reclaim — bounded deletion of the reclaim marker (#482): rm -f the one known file, then
# rmdir (never rm -rf, and never anywhere outside $reclaimdir). An rmdir failure is reported, not
# forced.
remove_reclaim() {
  rm -f "$reclaimdir/pid"
  if ! rmdir "$reclaimdir" 2>/dev/null; then
    echo "harness-lock.sh: warning: rmdir $reclaimdir failed — an unexpected file may remain inside it" >&2
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

# --- run journal (#251) --------------------------------------------------------------------------
# Explicit character lists throughout (never ranges): bash 3.2 `case` ranges follow the locale.

# journal_runid_ok ID — the run-id shape: run-<8 digits>T<6 digits>Z-<1-10 digits>.
journal_runid_ok() {
  local id="$1" suffix
  case "$id" in
    run-[0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789]T[0123456789][0123456789][0123456789][0123456789][0123456789][0123456789]Z-*) ;;
    *) return 1 ;;
  esac
  suffix="${id#run-????????T??????Z-}"
  case "$suffix" in
    ''|*[!0123456789]*) return 1 ;;
  esac
  [ "${#suffix}" -le 10 ]
}

# journal_value_ok KIND VALUE — KIND is slug | harness | num | retries | branch.
journal_value_ok() {
  local kind="$1" v="$2"
  case "$kind" in
    slug)
      case "$v" in ''|-*|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;; esac
      [ "${#v}" -le 40 ]
      ;;
    harness)
      case "$v" in ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.+-]*) return 1 ;; esac
      [ "${#v}" -le 32 ]
      ;;
    num)
      case "$v" in ''|0*|*[!0123456789]*) return 1 ;; esac
      [ "${#v}" -le 10 ]
      ;;
    retries)
      case "$v" in ''|*[!0123456789]*) return 1 ;; esac
      case "$v" in 0?*) return 1 ;; esac
      [ "${#v}" -le 3 ]
      ;;
    branch)
      case "$v" in ''|-*|/*|*..*|*//*|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._/-]*) return 1 ;; esac
      [ "${#v}" -le 100 ]
      ;;
    *) return 1 ;;
  esac
}

# journal_session — prints CLAUDE_CODE_SESSION_ID only when it is wholly [A-Za-z0-9-]{1,64};
# otherwise prints nothing (the empty string), never a sanitized fragment.
journal_session() {
  local s="${CLAUDE_CODE_SESSION_ID:-}"
  case "$s" in
    ''|*[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-]*) return 0 ;;
  esac
  [ "${#s}" -le 64 ] && printf '%s' "$s"
  return 0
}

# journal_append FILE LINE — one append, refusing a symlink or non-regular file/directory at the
# journal path. Writes nothing to stdout; on failure one stderr `warning: journal` line, return 1.
journal_append() {
  local file="$1" line="$2"
  if [ -L "$journaldir" ] || { [ -e "$journaldir" ] && [ ! -d "$journaldir" ]; }; then
    echo "harness-lock.sh: warning: journal directory $journaldir is a symlink or not a directory — not written" >&2
    return 1
  fi
  if [ -L "$file" ] || { [ -e "$file" ] && [ ! -f "$file" ]; }; then
    echo "harness-lock.sh: warning: journal file $file is a symlink or not a regular file — not written" >&2
    return 1
  fi
  if ! mkdir -p "$journaldir" 2>/dev/null; then
    echo "harness-lock.sh: warning: journal directory $journaldir could not be created — not written" >&2
    return 1
  fi
  if ! { printf '%s\n' "$line" >> "$file"; } 2>/dev/null; then
    echo "harness-lock.sh: warning: journal append to $file failed — not written" >&2
    return 1
  fi
  return 0
}

# journal_lock_event EVENT RUNID [RECLAIMED_RUNID] — the script's own acquire/release/release-force
# record. Best effort: always returns 0, so the caller's exit status and stdout are untouched.
journal_lock_event() {
  local event="$1" rid="$2" reclaimed="${3:-}" ts rec host hv pid
  journal_runid_ok "$rid" || return 0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  rec='{"v":1,"ts":"'"$ts"'","run_id":"'"$rid"'","event":"'"$event"'","session":"'"$(journal_session)"'"'
  if [ "$event" = "acquire" ]; then
    host="$(uname -n 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
    [ -n "$host" ] || host="unknown"
    hv="$(printf '%s' "$version" | LC_ALL=C tr -cd 'A-Za-z0-9.+-' | cut -c1-32)"
    pid="$(cat "$lockdir/pid" 2>/dev/null || true)"
    case "$pid" in ''|*[!0123456789]*) pid="" ;; esac
    pid="$(printf '%s' "$pid" | cut -c1-10)"
    rec="$rec"',"host":"'"$host"'","pid":"'"$pid"'","harness_version":"'"$hv"'"'
    if [ -n "$reclaimed" ] && journal_runid_ok "$reclaimed"; then
      rec="$rec"',"reclaimed_run_id":"'"$reclaimed"'"'
    fi
  fi
  rec="$rec}"
  journal_append "$journaldir/$rid.jsonl" "$rec" || true
  return 0
}

# prune_journal CURRENT_ID — keep the newest JOURNAL_KEEP run-shaped files directly under the
# journal directory (lexical order = chronological). Never removes the current run's file, never
# touches a non-matching name, and deletes with one `rm -f` per file (never a recursive delete).
# Always returns 0.
prune_journal() {
  local current="$1.jsonl" f name names="" total=0 excess old
  { [ -d "$journaldir" ] && [ ! -L "$journaldir" ]; } || return 0
  for f in "$journaldir"/run-*.jsonl; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    name="${f##*/}"
    journal_runid_ok "${name%.jsonl}" || continue
    names="$names$name
"
    total=$((total + 1))
  done
  [ "$total" -gt "$JOURNAL_KEEP" ] || return 0
  excess=$((total - JOURNAL_KEEP))
  while IFS= read -r old; do
    [ "$excess" -gt 0 ] || break
    [ -n "$old" ] || continue
    [ "$old" = "$current" ] && continue
    rm -f "$journaldir/$old"
    excess=$((excess - 1))
  done <<EOF
$(printf '%s' "$names" | LC_ALL=C sort)
EOF
  return 0
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

# reclaim_stale OBS_IDENT OWNER_PID — the critical section of a stale-lock reclaim (#482). The
# caller already holds the reclaim marker (it created $reclaimdir) and releases it afterwards, on
# every path. OBS_IDENT is "<run-id>:<pid>" as the stale check saw it. Returns 0 (acquired, the
# new run-id printed) or 3 (refused); never calls `exit`, and runs in the main shell, never inside
# a `$(…)`. Nothing is deleted unless the holder record is still exactly the one the stale check
# judged stale.
reclaim_stale() {
  local obs_ident="$1" owner="$2" now_pid now_ident
  now_pid="$(cat "$lockdir/pid" 2>/dev/null || true)"
  now_ident="$(cat "$lockdir/run-id" 2>/dev/null || true):$now_pid"
  if [ "$now_ident" != "$obs_ident" ]; then
    echo "harness-lock.sh: lock record changed since the stale check — refusing" >&2
    print_holder >&2
    echo "remedy: harness-lock.sh release --force" >&2
    return 3
  fi
  # Guards only the pid-reuse window (the identical record, its pid alive again); no fixture can
  # construct that, so this re-check is deliberately unpinned by dev/lock-tests.sh.
  if pid_alive "$now_pid"; then
    echo "harness-lock.sh: lock held by a live process (pid $now_pid) on this host — refusing" >&2
    print_holder >&2
    echo "remedy: harness-lock.sh release --force" >&2
    return 3
  fi
  # Same host, pid not alive -> stale. Print exactly one audit line quoting the stale record,
  # then reclaim.
  echo "stale reclaim: run-id=$(cat "$lockdir/run-id" 2>/dev/null) pid=$now_pid host=$(cat "$lockdir/host" 2>/dev/null) started-at=$(cat "$lockdir/started-at" 2>/dev/null) harness-version=$(cat "$lockdir/harness-version" 2>/dev/null) checkout-path=$(cat "$lockdir/checkout-path" 2>/dev/null)"
  remove_lock
  if ! mkdir "$lockdir" 2>/dev/null; then
    echo "harness-lock.sh: lost the race reclaiming the lock — refusing" >&2
    return 3
  fi
  write_record "$owner"
  journal_lock_event acquire "$(cat "$lockdir/run-id")" "${obs_ident%:*}"
  prune_journal "$(cat "$lockdir/run-id")"
  echo "run-id=$(cat "$lockdir/run-id")"
  return 0
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
    journal_lock_event acquire "$(cat "$lockdir/run-id")"
    prune_journal "$(cat "$lockdir/run-id")"
    echo "run-id=$(cat "$lockdir/run-id")"
    exit 0
  fi

  # Lock already held — apply the reclaim rule.
  local held_pid held_host held_runid this_host bad_record
  held_runid="$(cat "$lockdir/run-id" 2>/dev/null || true)"
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

  # Same host, pid not alive -> stale. Two contenders can both reach this point for one holder, so
  # the reclaim is serialized behind a second atomic mkdir (the marker, see the header's RECLAIM
  # MARKER). A marker already present means a reclaim is in progress or was interrupted: refuse
  # at once — never wait on it, never clear it here.
  if ! mkdir "$reclaimdir" 2>/dev/null; then
    echo "harness-lock.sh: a stale-lock reclaim is already in progress or was interrupted (marker $reclaimdir, pid $(cat "$reclaimdir/pid" 2>/dev/null)) — refusing" >&2
    print_holder >&2
    echo "remedy: harness-lock.sh release --force" >&2
    exit 3
  fi
  printf '%s' "$$" > "$reclaimdir/pid"
  local rc
  reclaim_stale "$held_runid:$held_pid" "$used_pid"; rc=$?
  remove_reclaim
  exit "$rc"
}

cmd_release() {
  local arg="${1:-}"

  if [ "$arg" != "--force" ] && [ -z "$arg" ]; then
    usage >&2
    exit 2
  fi

  # --force also clears a reclaim marker (#482), whether or not the lock directory exists;
  # `release <run-id>` never touches it.
  if [ "$arg" = "--force" ] && [ -d "$reclaimdir" ]; then
    echo "reclaim=cleared"
    echo "reclaim-pid=$(cat "$reclaimdir/pid" 2>/dev/null)"
    remove_reclaim
  fi

  if [ ! -d "$lockdir" ]; then
    echo "released=none"
    exit 0
  fi

  if [ "$arg" = "--force" ]; then
    print_holder
    local forced_id
    forced_id="$(cat "$lockdir/run-id" 2>/dev/null || true)"
    remove_lock
    journal_lock_event release-force "$forced_id"
    exit 0
  fi

  local stored
  stored="$(cat "$lockdir/run-id" 2>/dev/null || true)"
  if [ "$stored" = "$arg" ]; then
    remove_lock
    journal_lock_event release "$stored"
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
  # After the holder record, and never starting with pid=/host=/state= (bin/codex-scheduled-run.sh
  # parses those with `sed -n 's/^pid=//p' | head -1`).
  if [ -d "$reclaimdir" ]; then
    echo "reclaim=held"
    echo "reclaim-pid=$(cat "$reclaimdir/pid" 2>/dev/null)"
  fi
  exit 0
}

cmd_journal() {
  if [ "$#" -lt 4 ]; then
    usage >&2
    exit 2
  fi
  local rid="$1" a k v
  shift
  if ! journal_runid_ok "$rid"; then
    echo "harness-lock.sh: journal: run id must look like run-<YYYYMMDD>T<HHMMSS>Z-<pid>, got '$rid'" >&2
    exit 2
  fi
  local f_stage="" f_issue="" f_outcome="" f_retries="" f_deploy="" f_harness="" f_pr="" f_branch="" f_reason=""
  for a in "$@"; do
    case "$a" in
      *=*) ;;
      *) echo "harness-lock.sh: journal: expected key=value, got '$a'" >&2; exit 2 ;;
    esac
    k="${a%%=*}"
    v="${a#*=}"
    case "$k" in
      stage)
        [ -z "$f_stage" ] || { echo "harness-lock.sh: journal: duplicate key '$k'" >&2; exit 2; }
        journal_value_ok slug "$v" || { echo "harness-lock.sh: journal: bad value for '$k'" >&2; exit 2; }
        f_stage="$v"
        ;;
      issue)
        [ -z "$f_issue" ] || { echo "harness-lock.sh: journal: duplicate key '$k'" >&2; exit 2; }
        journal_value_ok num "$v" || { echo "harness-lock.sh: journal: bad value for '$k'" >&2; exit 2; }
        f_issue="$v"
        ;;
      outcome)
        [ -z "$f_outcome" ] || { echo "harness-lock.sh: journal: duplicate key '$k'" >&2; exit 2; }
        journal_value_ok slug "$v" || { echo "harness-lock.sh: journal: bad value for '$k'" >&2; exit 2; }
        f_outcome="$v"
        ;;
      retries)
        [ -z "$f_retries" ] || { echo "harness-lock.sh: journal: duplicate key '$k'" >&2; exit 2; }
        journal_value_ok retries "$v" || { echo "harness-lock.sh: journal: bad value for '$k'" >&2; exit 2; }
        f_retries="$v"
        ;;
      deploy)
        [ -z "$f_deploy" ] || { echo "harness-lock.sh: journal: duplicate key '$k'" >&2; exit 2; }
        journal_value_ok slug "$v" || { echo "harness-lock.sh: journal: bad value for '$k'" >&2; exit 2; }
        f_deploy="$v"
        ;;
      harness)
        [ -z "$f_harness" ] || { echo "harness-lock.sh: journal: duplicate key '$k'" >&2; exit 2; }
        journal_value_ok harness "$v" || { echo "harness-lock.sh: journal: bad value for '$k'" >&2; exit 2; }
        f_harness="$v"
        ;;
      pr)
        [ -z "$f_pr" ] || { echo "harness-lock.sh: journal: duplicate key '$k'" >&2; exit 2; }
        journal_value_ok num "$v" || { echo "harness-lock.sh: journal: bad value for '$k'" >&2; exit 2; }
        f_pr="$v"
        ;;
      branch)
        [ -z "$f_branch" ] || { echo "harness-lock.sh: journal: duplicate key '$k'" >&2; exit 2; }
        journal_value_ok branch "$v" || { echo "harness-lock.sh: journal: bad value for '$k'" >&2; exit 2; }
        f_branch="$v"
        ;;
      reason)
        [ -z "$f_reason" ] || { echo "harness-lock.sh: journal: duplicate key '$k'" >&2; exit 2; }
        journal_value_ok slug "$v" || { echo "harness-lock.sh: journal: bad value for '$k'" >&2; exit 2; }
        f_reason="$v"
        ;;
      *)
        echo "harness-lock.sh: journal: unknown key '$k'" >&2
        exit 2
        ;;
    esac
  done
  if [ -z "$f_stage" ] || [ -z "$f_issue" ] || [ -z "$f_outcome" ]; then
    echo "harness-lock.sh: journal: stage, issue and outcome are required" >&2
    exit 2
  fi

  local file="$journaldir/$rid.jsonl"
  if [ -L "$journaldir" ] || { [ -e "$journaldir" ] && [ ! -d "$journaldir" ]; } \
     || [ -L "$file" ] || [ ! -f "$file" ]; then
    echo "harness-lock.sh: journal: no regular journal file for $rid — mistyped run id, or acquire's record failed (or the path is a symlink)" >&2
    exit 1
  fi

  local rec
  rec='{"v":1,"ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","run_id":"'"$rid"'","event":"stage","session":"'"$(journal_session)"'","stage":"'"$f_stage"'","issue":'"$f_issue"',"outcome":"'"$f_outcome"'"'
  [ -z "$f_retries" ] || rec="$rec"',"retries":'"$f_retries"
  [ -z "$f_deploy" ]  || rec="$rec"',"deploy":"'"$f_deploy"'"'
  [ -z "$f_harness" ] || rec="$rec"',"harness":"'"$f_harness"'"'
  [ -z "$f_pr" ]      || rec="$rec"',"pr":'"$f_pr"
  [ -z "$f_branch" ]  || rec="$rec"',"branch":"'"$f_branch"'"'
  [ -z "$f_reason" ]  || rec="$rec"',"reason":"'"$f_reason"'"'
  rec="$rec}"
  if journal_append "$file" "$rec"; then
    echo "journal=written"
    exit 0
  fi
  exit 1
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
reclaimdir="$lockroot/reclaim"
journaldir="$lockroot/journal"

version="unknown"
if command -v jq >/dev/null 2>&1; then
  v="$(jq -r '.version // "unknown"' "$script_dir/../.claude-plugin/plugin.json" 2>/dev/null || true)"
  [ -n "$v" ] && [ "$v" != "null" ] && version="$v"
fi

case "$sub" in
  acquire) cmd_acquire "$@" ;;
  release) cmd_release "$@" ;;
  status)  cmd_status "$@" ;;
  journal) cmd_journal "$@" ;;
esac
