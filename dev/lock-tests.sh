#!/usr/bin/env bash
#
# lock-tests.sh — fixture-based negative-test harness for bin/harness-lock.sh (#232).
#
# Usage: bash dev/lock-tests.sh [name-filter] — same output contract as dev/cleanup-tests.sh and
# dev/doctor-tests.sh: one PASS/FAIL line per case, a `== summary: N pass, M fail ==` footer,
# exit 0 iff nothing failed; a filter with no match exits 1.
#
# Every write happens under one `mktemp -d` root, removed via an EXIT trap. Each fixture is a
# real, throwaway git repo (mk_repo: one empty commit on a branch renamed to "main"), with its
# own HOME/XDG_CONFIG_HOME. $tmpbase itself is resolved through `pwd -P` right after mktemp — on
# macOS, mktemp -d lives under /var, a symlink to /private/var, and bin/harness-lock.sh's own
# `checkout-path` field and its not-a-git-repo check both resolve paths with `pwd -P` too; without
# this, a fixture path comparison could spuriously fail purely on an unresolved symlink prefix,
# not a real behavior difference (case 13, case 17).
#
# RUNNER SHAPE — deliberately NOT dev/cleanup-tests.sh's run_cleanup idiom
# (`cleanup_out="$(cd "$dir" && … 2>&1)"`, which captures the whole compound command through
# `$(…)`): run_lock() below does a plain `cd "$dir"` statement (not a subshell), invokes
# bin/harness-lock.sh with stdout and stderr redirected straight to two separate files
# (`.lock-out` / `.lock-err`, #232 kickback 1 finding 2 — see the runner's own comment below),
# reads $? into $lock_rc, cds back, then reads those files into $lock_stdout/$lock_stderr (plus
# $lock_out, the two concatenated). Two reasons for the no-subshell shape: (1) the general shape
# matches the RESOLVED runner idiom for this file; (2) bash's own `$$` parameter resolves to the
# INVOKING shell's pid even inside a `( … )` subshell (a subshell's real OS pid is $BASHPID, not
# $$) — so wrapping the invocation in a subshell would fork an extra process whose pid becomes
# bin/harness-lock.sh's own $PPID, which would never equal this file's own top-level $$, breaking
# cases 19/20's fallback-pid assertion (case 19's own comment below records the measured proof).
# Avoiding subshells everywhere (not just for 19/20) keeps one runner for every case that drives
# the script synchronously. The one exception is the reclaim-race cases (#482): they need two
# real `acquire` processes alive at once, held at barriers, so start_contender launches those as
# backgrounded processes instead (see RECLAIM RACE HARNESS below); reclaim-marker-dead stays on
# run_lock.
#
# CLAUDE_PID PER FIXTURE (RESOLVED): every case passes an explicit CLAUDE_PID value to run_lock —
# live-holder fixtures pass "$$" (this harness's own pid, alive for the whole run), stale
# fixtures pass a killed-and-reaped pid (dead_pid(): a backgrounded `sleep 30`, killed and
# waited on immediately, so its pid is guaranteed dead and not yet recycled). The two fallback
# cases (19, 20) are the only ones that depend on invocation shape instead of an explicit value:
# 19 passes the sentinel "UNSET", routing run_lock through
# `bash -c 'unset CLAUDE_PID; exec "$@"' _ bash harness-lock.sh acquire` (exec keeps the same
# pid, so bin/harness-lock.sh's own $PPID is this file's $$); 20 passes the literal garbage value
# "not-a-pid" through the normal direct-invocation branch. The reclaim-race contenders (#482) are
# the other exception: each is launched with its own live owner pid, passed both as CLAUDE_PID and
# as --owner-pid, never this harness's $$.
#
# LIVE PROBE (mandatory per the plan, LESSON 2026-09-01): measured 2026-09-08 in this real
# checkout, from two separate Bash tool invocations. Call 1 printed CLAUDE_PID=99359 (that call's
# own $PPID/$$ were 99359/35146 — different from each other and from call 2's), then
# `bash bin/harness-lock.sh acquire` printed `run-id=run-20260908T002144Z-99359` (rc 0). Call 2
# printed the SAME CLAUDE_PID=99359 (its own $PPID/$$ were 99359/35243 — a fresh shell again),
# then `bash bin/harness-lock.sh acquire` again printed the holder record
# (run-id=run-20260908T002144Z-99359, pid=99359, host=Marks-MacBook-Pro.local, harness-version
# 2.6.1, checkout-path=/Users/kermit/Development/Kermit/trail-blazer-flow) and exited 3 (refused,
# not reclaimed) — the required outcome. `bash bin/harness-lock.sh release --force` then cleared
# it (confirmed via `status` -> state=free immediately after). The recorded pid equalled
# CLAUDE_PID in both calls, confirming the session process (not the per-call shell, whose own
# $$ differed between the two calls: 35146 vs 35243) is what gets recorded.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"

tmpbase="$(mktemp -d)"
tmpbase="$(cd "$tmpbase" && pwd -P)"
cleanup() {
  if [ -n "$tmpbase" ] && [ -d "$tmpbase" ]; then
    rm -rf "$tmpbase"
  fi
}
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1; then
  echo "  FAIL  jq not installed — required by dev/lock-tests.sh's harness-version comparison"
  exit 1
fi

bash_bin="$(command -v bash)"
# Absolute paths of the real binaries the reclaim-race shims forward to, captured before any
# PATH change so a shim can never find itself.
real_mkdir="$(command -v mkdir)"
real_rm="$(command -v rm)"
real_sleep="$(command -v sleep)"

pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------------------------
# Fixture builders.

# mk_repo NAME — a fresh, throwaway git repo under $tmpbase/NAME: one empty commit on a branch
# renamed to "main", local identity + gpgsign off, its own home/xdgcfg dirs. No remote. Prints
# the fixture path (already under the resolved $tmpbase).
mk_repo() {
  local name="$1" dir="$tmpbase/$name"
  mkdir -p "$dir/home" "$dir/xdgcfg"
  (
    cd "$dir" &&
    git init -q &&
    git config user.name "lock-tests" &&
    git config user.email "lock-tests@example.invalid" &&
    git config commit.gpgsign false &&
    git symbolic-ref HEAD refs/heads/main &&
    git commit -q --allow-empty -m init
  )
  printf '%s' "$dir"
}

# dead_pid — a pid guaranteed dead and not yet recycled: backgrounds `sleep 30`, kills it, waits
# on it (reaping it), and prints its pid. Must be called directly (not via `$(…)` from a case
# that also needs job control on the SAME pid later) — command substitution here is fine since
# the background job, kill, and wait all happen inside the one subshell command substitution
# forks, which has its own job table.
dead_pid() {
  sleep 30 &
  local p=$!
  kill "$p" 2>/dev/null
  wait "$p" 2>/dev/null
  printf '%s' "$p"
}

# write_lock DIR RUNID PID HOST STARTED VERSION CHECKOUT — writes a lock directly under
# DIR/.git/trail-blazer/lock (every DIR here is a plain, non-worktree mk_repo fixture, so its
# git-common-dir is always DIR/.git), in the same six-file layout bin/harness-lock.sh itself
# writes — bypassing `acquire` so a malformed/stale record can be constructed directly. Any field
# given as the literal string OMIT is not written at all (cases 6/7 need an incomplete record).
write_lock() {
  local dir="$1" runid="$2" pid="$3" host="$4" started="$5" version="$6" checkout="$7"
  local ld="$dir/.git/trail-blazer/lock"
  mkdir -p "$ld"
  [ "$runid" = "OMIT" ]    || printf '%s' "$runid"    > "$ld/run-id"
  [ "$pid" = "OMIT" ]      || printf '%s' "$pid"      > "$ld/pid"
  [ "$host" = "OMIT" ]     || printf '%s' "$host"     > "$ld/host"
  [ "$started" = "OMIT" ]  || printf '%s' "$started"  > "$ld/started-at"
  [ "$version" = "OMIT" ]  || printf '%s' "$version"  > "$ld/harness-version"
  [ "$checkout" = "OMIT" ] || printf '%s' "$checkout" > "$ld/checkout-path"
}

lockdir_of() { printf '%s/.git/trail-blazer/lock' "$1"; }
reclaimdir_of() { printf '%s/.git/trail-blazer/reclaim' "$1"; }

# ---------------------------------------------------------------------------------------------
# Runner + assertion helpers.

# run_lock DIR CLAUDE_PID_VALUE ARGS... — see the header's "RUNNER SHAPE" note. CLAUDE_PID_VALUE
# is either a literal value to export as CLAUDE_PID, or the sentinel "UNSET" (case 19 only) to
# route through the documented `bash -c 'unset CLAUDE_PID; exec "$@"'` idiom instead. stdout and
# stderr are captured to SEPARATE files (`.lock-out` / `.lock-err`, #232 kickback 1 finding 2) so
# a case can assert on one stream specifically — most of bin/harness-lock.sh's diagnostic text
# (usage, refusal messages, the not-a-git-repo message) is written to stderr, while only
# `run-id=`, `state=`/`lock-path=`/the holder record on a clean `status`, `released=`, and the
# `stale reclaim:` audit line are stdout. Of those, only the fresh-acquire `run-id=` line is
# actually asserted per-stream — case_acquire_fresh (#232 kickback 2, see the
# expect_last_line_prefix/run_id_from_out note below) — because it is the only one an acceptance
# criterion in this file names a stream for; `state=`/`lock-path=`, `released=`, and the
# `stale reclaim:` audit line stay asserted only against the merged capture. Leaves
# $lock_rc/$lock_stdout/$lock_stderr set as globals, plus $lock_out — the two streams concatenated
# (stdout then stderr) — kept for the cases that only ever assert presence and don't care which
# stream carries it.
#
# TBF_OWNER_PID CONTROL (#408): run_lock also always exports TBF_OWNER_PID="$lock_tbf_owner" — a
# new global, reset to "" by the runner loop before every case — to BOTH branches below, including
# the UNSET one. An empty value means unset to bin/harness-lock.sh itself (its own check is
# `[ -n "${TBF_OWNER_PID:-}" ]`), so a case that never sets $lock_tbf_owner runs exactly as before
# #408; explicitly assigning it every time (rather than leaving it to inherit) keeps a developer's
# own real TBF_OWNER_PID, if any, from ever leaking into a fixture.
lock_rc=0
lock_out=""
lock_stdout=""
lock_stderr=""
lock_tbf_owner=""
run_lock() {
  local dir="$1" pidval="$2"; shift 2
  local orig; orig="$(pwd)"
  cd "$dir" || { lock_rc=90; lock_out="cd $dir failed"; lock_stdout=""; lock_stderr=""; return; }
  if [ "$pidval" = "UNSET" ]; then
    HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdgcfg" TBF_OWNER_PID="$lock_tbf_owner" \
      "$bash_bin" -c 'unset CLAUDE_PID; exec "$@"' _ "$bash_bin" "$root/bin/harness-lock.sh" "$@" \
      > "$dir/.lock-out" 2> "$dir/.lock-err"
  else
    HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdgcfg" CLAUDE_PID="$pidval" TBF_OWNER_PID="$lock_tbf_owner" \
      "$bash_bin" "$root/bin/harness-lock.sh" "$@" \
      > "$dir/.lock-out" 2> "$dir/.lock-err"
  fi
  lock_rc=$?
  cd "$orig" || true
  lock_stdout="$(cat "$dir/.lock-out" 2>/dev/null)"
  lock_stderr="$(cat "$dir/.lock-err" 2>/dev/null)"
  lock_out="$(cat "$dir/.lock-out" "$dir/.lock-err" 2>/dev/null)"
}

# expect/expect_absent/expect_rc/expect_count — assert against $lock_out (stdout+stderr
# concatenated) /$lock_rc. All set $__ok=0 and append to $__why on failure. ASCII-only short
# stems.
#
# expect_out/expect_err/expect_absent_out/expect_absent_err/expect_count_err — the
# stream-specific siblings (#232 kickback 1 finding 2), asserting against $lock_stdout /
# $lock_stderr alone so a case can pin WHICH stream carries a message, not merely that it
# appears somewhere in the process's total output.
#
# expect_last_line_prefix/run_id_from_out both read $lock_stdout alone too (#232 kickback 2 —
# the only acceptance criterion in this file naming a specific stream, "run-id=<id> as the LAST
# line of stdout", was previously checked against the merged $lock_out, which a mutant moving
# that echo to stderr survived whenever stdout happened to be otherwise empty). case_acquire_fresh
# additionally asserts `expect_out "run-id="` and `expect_absent_err "run-id="` directly, so the
# fresh-acquire acceptance criterion is pinned three ways. run-id= is the ONLY one of the streams
# named in the runner-shape comment above that is asserted per-stream this way; state=/lock-path=,
# released=, and the stale-reclaim audit line are still asserted only against the merged $lock_out
# (see that comment) because no acceptance criterion in this file names a stream for them.
# needle_required NAME NEEDLE (#262) — guards every needle-taking helper below: an empty NEEDLE
# degenerates `grep -qF -- ""`/`grep -cF -- ""` into an unconditional match (and, for
# expect_last_line_prefix, `case "$last" in ""*)` degenerates to the unconditional `*)`), so treat
# an empty needle as a harness bug IN THE CASE, not a fact about the script under test. Sets
# $__ok=0, appends "<NAME>: empty needle (harness bug)\n" to $__why, and returns 1; returns 0 when
# the needle is non-empty. Callers do `needle_required <own-name> "$1" || return 0` — returning 0
# to the CALLER's caller (not 1), so a guarded helper never leaves a stray non-zero exit status
# behind for an `&&`/`||`/`if` chain built on it.
needle_required() {
  if [ -z "$2" ]; then
    __ok=0
    __why="${__why}$1: empty needle (harness bug)\n"
    return 1
  fi
  return 0
}

# All nine needle-taking helpers below are guarded by needle_required (#262). expect/
# expect_absent/expect_out/expect_err/expect_absent_out/expect_absent_err are fed via a
# here-string (`<<<"$lock_out"`/`<<<"$lock_stdout"`/`<<<"$lock_stderr"`, #255) rather than piping a
# `printf '%s\n' ...` writer into `grep`'s quiet mode: that early-exit reader exits on its first
# match, which can send the printf writer SIGPIPE and, under this file's `set -uo pipefail`, turn
# a genuine match into a reported pipeline failure — a here-string has no writer process, so no
# SIGPIPE is possible, and it appends exactly one trailing newline, the same as the piped printf
# did, so grep's fixed-string semantics are unchanged. expect_count/expect_count_err's `-cF`
# counters move to the same here-string idiom for uniformity — they are not early-exit readers, so
# not a SIGPIPE exposure.
expect() {
  needle_required expect "$1" || return 0
  grep -qF -- "$1" <<<"$lock_out" || { __ok=0; __why="${__why}missing: $1\n"; }
}
expect_absent() {
  needle_required expect_absent "$1" || return 0
  grep -qF -- "$1" <<<"$lock_out" && { __ok=0; __why="${__why}unexpected: $1\n"; }
}
expect_out() {
  needle_required expect_out "$1" || return 0
  grep -qF -- "$1" <<<"$lock_stdout" || { __ok=0; __why="${__why}missing on stdout: $1\n"; }
}
expect_err() {
  needle_required expect_err "$1" || return 0
  grep -qF -- "$1" <<<"$lock_stderr" || { __ok=0; __why="${__why}missing on stderr: $1\n"; }
}
expect_absent_out() {
  needle_required expect_absent_out "$1" || return 0
  grep -qF -- "$1" <<<"$lock_stdout" && { __ok=0; __why="${__why}unexpected on stdout: $1\n"; }
}
expect_absent_err() {
  needle_required expect_absent_err "$1" || return 0
  grep -qF -- "$1" <<<"$lock_stderr" && { __ok=0; __why="${__why}unexpected on stderr: $1\n"; }
}
expect_rc() {
  [ "$lock_rc" -eq "$1" ] || { __ok=0; __why="${__why}rc: expected $1, got $lock_rc\n"; }
}
expect_count() {
  local needle="$1" want="$2" got
  needle_required expect_count "$needle" || return 0
  got="$(grep -cF -- "$needle" <<<"$lock_out")"
  [ "$got" -eq "$want" ] || { __ok=0; __why="${__why}count: expected $want of '$needle', got $got\n"; }
}
expect_count_err() {
  local needle="$1" want="$2" got
  needle_required expect_count_err "$needle" || return 0
  got="$(grep -cF -- "$needle" <<<"$lock_stderr")"
  [ "$got" -eq "$want" ] || { __ok=0; __why="${__why}count(stderr): expected $want of '$needle', got $got\n"; }
}
expect_last_line_prefix() {
  needle_required expect_last_line_prefix "$1" || return 0
  local last
  last="$(printf '%s\n' "$lock_stdout" | grep -v '^$' | tail -1)"
  case "$last" in
    "$1"*) : ;;
    *) __ok=0; __why="${__why}last line of stdout: expected prefix '$1', got '$last'\n" ;;
  esac
}
run_id_from_out() { printf '%s\n' "$lock_stdout" | sed -n 's/^run-id=//p' | tail -1; }

# ---------------------------------------------------------------------------------------------
# RECLAIM RACE HARNESS (#482). Two real `acquire` processes are held at barriers inside
# bin/harness-lock.sh's stale-reclaim path, so the interleaving is decided by files, never by
# sleeps. A barrier is a PATH shim for `mkdir` or `rm` that, only for the one command the
# script's reclaim path issues (mkdir of .../trail-blazer/reclaim; rm of .../trail-blazer/lock/
# run-id, remove_lock's first argument), writes `arrived-<cmd>-<id>` into $dir/.barrier, then
# waits for `go-<cmd>-<id>` and finally `exec`s the real binary with its argv unchanged. The
# shim only ever delays: every other mkdir/rm call (and a gated one, once released) is the real
# binary. `arrived-mkdir-a` AND `arrived-mkdir-b` both existing proves both contenders passed the
# stale check before either took the marker. Every wait polls in 1s slices against a $SECONDS
# deadline; a timeout fails the case, releases every barrier and reaps every contender and owner.

# mk_barrier_shims DIR — writes DIR/.shims/{mkdir,rm} and DIR/.barrier. Built with printf lines;
# the real binaries' absolute paths are substituted in at build time.
mk_barrier_shims() {
  local dir="$1" cmd real key f
  mkdir -p "$dir/.shims" "$dir/.barrier"
  for cmd in mkdir rm; do
    if [ "$cmd" = mkdir ]; then
      real="$real_mkdir"; key='*/trail-blazer/reclaim'
    else
      real="$real_rm"; key='*/trail-blazer/lock/run-id'
    fi
    f="$dir/.shims/$cmd"
    {
      printf '%s\n' "#!$bash_bin"
      printf '%s\n' 'point="${0##*/}"'
      printf '%s\n' 'gate=0'
      printf '%s\n' 'case " ${LOCK_BARRIER_POINTS:-} " in'
      printf '%s\n' '  *" $point "*)'
      printf '%s\n' '    for a in "$@"; do'
      printf '%s\n' "      case \"\$a\" in $key) gate=1 ;; esac"
      printf '%s\n' '    done ;;'
      printf '%s\n' 'esac'
      printf '%s\n' 'if [ "$gate" -eq 1 ]; then'
      printf '%s\n' '  : > "$LOCK_BARRIER_DIR/arrived-$point-$LOCK_BARRIER_ID"'
      printf '%s\n' '  deadline=$((SECONDS+60))'
      printf '%s\n' '  while [ ! -e "$LOCK_BARRIER_DIR/go-$point-$LOCK_BARRIER_ID" ] && [ "$SECONDS" -lt "$deadline" ]; do'
      printf '%s\n' "    \"$real_sleep\" 1"
      printf '%s\n' '  done'
      printf '%s\n' 'fi'
      printf '%s\n' "exec \"$real\" \"\$@\""
    } > "$f"
    chmod +x "$f"
  done
}

# start_contender DIR ID OWNER POINTS — backgrounds one `acquire --owner-pid OWNER` in DIR behind
# the shims, with LOCK_BARRIER_POINTS naming the barrier commands it stops at. `exec` makes the
# recorded $! the script's own pid. Sets $contender_pid. stdout/stderr go to DIR/.out-ID/.err-ID.
contender_pid=""
start_contender() {
  local dir="$1" id="$2" owner="$3" points="$4"
  ( cd "$dir" && exec env PATH="$dir/.shims:$PATH" HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdgcfg" \
      CLAUDE_PID="$owner" TBF_OWNER_PID="" LOCK_BARRIER_DIR="$dir/.barrier" LOCK_BARRIER_ID="$id" \
      LOCK_BARRIER_POINTS="$points" \
      "$bash_bin" "$root/bin/harness-lock.sh" acquire --owner-pid "$owner" \
      > "$dir/.out-$id" 2> "$dir/.err-$id" ) &
  contender_pid=$!
}

# release_all_barriers DIR — lets every possible barrier through.
release_all_barriers() {
  local dir="$1" c i
  for c in mkdir rm; do
    for i in a b; do
      : > "$dir/.barrier/go-$c-$i"
    done
  done
}

# await_file PATH SECS — polls in 1s slices against a $SECONDS deadline; 1 on timeout.
await_file() {
  local path="$1" deadline=$((SECONDS+$2))
  while [ ! -e "$path" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 1
  done
  return 0
}

# await_exit PID SECS DIR — polls `kill -0` in 1s slices against a $SECONDS deadline, then reaps
# PID and leaves its exit status in $await_rc. On a timeout it fails the case, releases every
# barrier and terminates PID first.
await_rc=0
await_exit() {
  local pid="$1" deadline=$((SECONDS+$2)) dir="$3"
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      __ok=0; __why="${__why}contender pid $pid did not exit within $2s\n"
      release_all_barriers "$dir"
      kill -TERM "$pid" 2>/dev/null
      break
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null
  await_rc=$?
}

# load_capture DIR ID — loads one contender's captured streams into the lock_* globals, so the
# usual expect_* helpers can assert on it.
load_capture() {
  lock_stdout="$(cat "$1/.out-$2" 2>/dev/null)"
  lock_stderr="$(cat "$1/.err-$2" 2>/dev/null)"
  lock_out="$(cat "$1/.out-$2" "$1/.err-$2" 2>/dev/null)"
}

# race_cleanup DIR PA PB OA OB — every path out of a race case: release the barriers, terminate
# and reap any contender still running, then kill and reap the owners. A pid argument is "" once
# it has already been reaped, so a recycled pid is never signalled.
race_cleanup() {
  local dir="$1" p
  release_all_barriers "$dir"
  for p in "$2" "$3"; do
    if [ -n "$p" ]; then
      kill -TERM "$p" 2>/dev/null
      wait "$p" 2>/dev/null
    fi
  done
  for p in "$4" "$5"; do
    if [ -n "$p" ]; then
      kill "$p" 2>/dev/null
      wait "$p" 2>/dev/null
    fi
  done
}

# reclaim_race MODE — the shared body of the three reclaim-race cases. MODE is serial, replaced or
# concurrent (see each case). A stale lock (dead holder, this host) is contended by A and B, each
# with its own live owner process; both are held at the reclaim-marker mkdir.
reclaim_race() {
  local mode="$1" dir host dead oa ob pa pb rca=0 rcb=0 ld rid f pts_a rd
  dir="$(mk_repo "reclaim-race-$mode")"
  ld="$(lockdir_of "$dir")"
  rd="$(reclaimdir_of "$dir")"
  host="$(uname -n)"
  dead="$(dead_pid)"
  write_lock "$dir" "run-old-$dead" "$dead" "$host" "2020-01-01T00:00:00Z" "0.0.0" "/nowhere"
  mk_barrier_shims "$dir"
  sleep 60 &
  oa=$!
  sleep 60 &
  ob=$!
  pts_a="mkdir"
  [ "$mode" = concurrent ] && pts_a="mkdir rm"
  start_contender "$dir" a "$oa" "$pts_a"
  pa="$contender_pid"
  start_contender "$dir" b "$ob" mkdir
  pb="$contender_pid"
  local oa_pid="$oa"

  if ! await_file "$dir/.barrier/arrived-mkdir-a" 20 || ! await_file "$dir/.barrier/arrived-mkdir-b" 20; then
    __ok=0; __why="${__why}a contender never reached the reclaim-marker barrier\n"
    race_cleanup "$dir" "$pa" "$pb" "$oa" "$ob"
    return
  fi

  case "$mode" in
    serial|replaced)
      : > "$dir/.barrier/go-mkdir-a"
      await_exit "$pa" 20 "$dir"; rca=$await_rc; pa=""
      if [ "$mode" = replaced ]; then
        kill "$oa" 2>/dev/null
        wait "$oa" 2>/dev/null
        oa=""
      fi
      : > "$dir/.barrier/go-mkdir-b"
      await_exit "$pb" 20 "$dir"; rcb=$await_rc; pb=""
      ;;
    concurrent)
      : > "$dir/.barrier/go-mkdir-a"
      if ! await_file "$dir/.barrier/arrived-rm-a" 20; then
        __ok=0; __why="${__why}contender a never reached the remove_lock barrier\n"
        race_cleanup "$dir" "$pa" "$pb" "$oa" "$ob"
        return
      fi
      : > "$dir/.barrier/go-mkdir-b"
      await_exit "$pb" 20 "$dir"; rcb=$await_rc; pb=""
      [ "$(cat "$rd/pid" 2>/dev/null)" = "$pa" ] \
        || { __ok=0; __why="${__why}marker not still held by contender a (pid $pa) after b's refusal: '$(cat "$rd/pid" 2>/dev/null)'\n"; }
      : > "$dir/.barrier/go-rm-a"
      await_exit "$pa" 20 "$dir"; rca=$await_rc; pa=""
      ;;
  esac
  race_cleanup "$dir" "$pa" "$pb" "$oa" "$ob"

  [ "$rca" -eq 0 ] || { __ok=0; __why="${__why}contender a rc: expected 0, got $rca\n"; }
  [ "$rcb" -eq 3 ] || { __ok=0; __why="${__why}contender b rc: expected 3, got $rcb\n"; }
  for f in run-id pid host started-at harness-version checkout-path; do
    [ -s "$ld/$f" ] || { __ok=0; __why="${__why}missing/empty record file: $f\n"; }
  done
  [ "$(cat "$ld/pid" 2>/dev/null)" = "$oa_pid" ] \
    || { __ok=0; __why="${__why}recorded pid: expected a's owner $oa_pid, got '$(cat "$ld/pid" 2>/dev/null)'\n"; }
  rid="$(cat "$ld/run-id" 2>/dev/null)"
  case "$rid" in
    *"-$oa_pid") : ;;
    *) __ok=0; __why="${__why}run-id does not end with -$oa_pid: '$rid'\n" ;;
  esac
  [ -e "$rd" ] && { __ok=0; __why="${__why}reclaim marker still present: $rd\n"; }
  load_capture "$dir" a
  expect_last_line_prefix "run-id=$rid"
  load_capture "$dir" b
  expect_absent_out "run-id="
  if [ "$mode" = concurrent ]; then
    expect_err "release --force"
  fi
}

# ---------------------------------------------------------------------------------------------
# The cases. Each is run by the plain-statement runner in run_lock() above (no `$(…)` command
# substitution around the script invocation itself — see the "RUNNER SHAPE" header note; case 19
# below pins that this is load-bearing, not just style). Each case's own comment records a
# measured mutation proof: the single-clause mutant actually applied to bin/harness-lock.sh (or,
# for case 19, to this file's own run_lock), the resulting `bash dev/lock-tests.sh` summary line,
# and the exact set of cases that failed — measured 2026-09-08 in this checkout, one mutant at a
# time: fresh `cp` backup immediately before the edit, `diff`/md5 confirming a byte-identical
# restore immediately after recording the result before moving to the next mutant. Several
# clauses are shared by more than one case, so a mutant can fail more than its own case; a mutant
# migrated into dev/mutants/lock-tests.json carries its measured failing set there, as an
# `expect_fail` list, instead of in prose.

# 1. acquire-fresh (control). Mutant: write_record — drop the `pid` file (delete
# `printf '%s' "$p" > "$lockdir/pid"`), so the recorded pid is never written to disk at all.
#
# Second mutant (#232 kickback 2 finding — the "run-id=<id> as the LAST line of stdout"
# acceptance criterion was only checked against the merged stdout+stderr capture, so a mutant
# moving the fresh-acquire echo to stderr survived): the fresh-acquire
# `echo "run-id=$(cat "$lockdir/run-id")"` -> `... >&2`. Fixed by pointing `expect_last_line_prefix`
# and `run_id_from_out` at $lock_stdout alone (both were reading the merged $lock_out before) and
# adding `expect_out "run-id="` / `expect_absent_err "run-id="` here.
case_acquire_fresh() {
  local dir; dir="$(mk_repo acquire-fresh)"
  run_lock "$dir" "$$" acquire
  expect_rc 0
  expect_last_line_prefix "run-id="
  expect_out "run-id="
  expect_absent_err "run-id="
  local ld; ld="$(lockdir_of "$dir")"
  [ -d "$ld" ] || { __ok=0; __why="${__why}lock dir missing: $ld\n"; }
  local f
  for f in run-id pid host started-at harness-version checkout-path; do
    [ -s "$ld/$f" ] || { __ok=0; __why="${__why}missing/empty file: $f\n"; }
  done
  local recorded_pid; recorded_pid="$(cat "$ld/pid" 2>/dev/null)"
  [ "$recorded_pid" = "$$" ] || { __ok=0; __why="${__why}pid: expected $$, got '$recorded_pid'\n"; }
  local rid; rid="$(cat "$ld/run-id" 2>/dev/null)"
  case "$rid" in
    *"-$$") : ;;
    *) __ok=0; __why="${__why}run-id does not end with -$$: '$rid'\n" ;;
  esac
}

# 2. acquire-twice-refused. Mutant: drop the mkdir-failure (else) branch in cmd_acquire —
# `mkdir "$lockdir"` -> `mkdir -p "$lockdir"`, which never fails on an already-existing lock dir,
# so the entire already-held branch (reclaim rule, refuse-foreign-host, refuse-live-pid,
# refuse-incomplete-record, refuse-unparseable-pid) never runs. Fails this case, and every other
# case that pre-writes or acquires a lock and expects the already-held branch.
case_acquire_twice_refused() {
  local dir; dir="$(mk_repo acquire-twice-refused)"
  local ld; ld="$(lockdir_of "$dir")"
  run_lock "$dir" "$$" acquire
  expect_rc 0
  local first_runid; first_runid="$(cat "$ld/run-id" 2>/dev/null)"
  run_lock "$dir" "$$" acquire
  expect_rc 3
  expect "$first_runid"
  local now_runid; now_runid="$(cat "$ld/run-id" 2>/dev/null)"
  [ "$now_runid" = "$first_runid" ] || { __ok=0; __why="${__why}stored run-id changed\n"; }
}

# 3. reclaim-stale-same-host. Mutant: delete the `stale reclaim: run-id=…` audit-line echo in
# reclaim_stale. Fails exactly: THIS case (no other case asserts the audit line).
case_reclaim_stale_same_host() {
  local dir; dir="$(mk_repo reclaim-stale-same-host)"
  local dead host
  dead="$(dead_pid)"
  host="$(uname -n)"
  write_lock "$dir" "run-old-$dead" "$dead" "$host" "2020-01-01T00:00:00Z" "0.0.0" "/nowhere"
  run_lock "$dir" "$$" acquire
  expect_rc 0
  expect_count "stale reclaim:" 1
  expect "run-old-$dead"
  expect "pid=$dead"
  local last; last="$(printf '%s\n' "$lock_out" | grep -v '^$' | tail -1)"
  case "$last" in
    "run-id=run-old-$dead") __ok=0; __why="${__why}run-id did not change on reclaim\n" ;;
    run-id=*) : ;;
    *) __ok=0; __why="${__why}last line not run-id=...: '$last'\n" ;;
  esac
}

# 4. refuse-foreign-host — pins the host conjunct. Mutant: `if [ "$held_host" != "$this_host" ]`
# -> `if false`. Fails exactly: THIS case.
case_refuse_foreign_host() {
  local dir; dir="$(mk_repo refuse-foreign-host)"
  local dead; dead="$(dead_pid)"
  write_lock "$dir" "run-foreign" "$dead" "other.invalid" "2020-01-01T00:00:00Z" "0.0.0" "/nowhere"
  run_lock "$dir" "$$" acquire
  expect_rc 3
  expect "run-foreign"
  local ld rid; ld="$(lockdir_of "$dir")"; rid="$(cat "$ld/run-id" 2>/dev/null)"
  [ "$rid" = "run-foreign" ] || { __ok=0; __why="${__why}lock was touched: run-id now '$rid'\n"; }
}

# 5. refuse-live-pid-same-host — pins the liveness conjunct. Mutant: pid_alive() body replaced
# with `return 1` unconditionally (never alive). Fails
# acquire-twice-refused, refuse-live-pid-same-host (this case), worktree-shares-lock (all three
# depend on a live-pid refusal).
case_refuse_live_pid_same_host() {
  local dir; dir="$(mk_repo refuse-live-pid-same-host)"
  local host; host="$(uname -n)"
  write_lock "$dir" "run-live" "$$" "$host" "2020-01-01T00:00:00Z" "0.0.0" "/nowhere"
  run_lock "$dir" "$$" acquire
  expect_rc 3
  expect "run-live"
}

# 6. refuse-incomplete-record — pins the empty-pid detection. The standalone
# `[ -n "$held_pid" ] || bad_record=true` check and the case statement's own `''` alternative are
# redundant with each other (either alone still catches an empty pid file), so isolating this
# case requires disabling both together: delete the standalone check line AND drop the `''|`
# alternative from `case "$held_pid" in ''|*[!0-9]*) …`. Fails exactly: THIS case.
case_refuse_incomplete_record() {
  local dir; dir="$(mk_repo refuse-incomplete-record)"
  write_lock "$dir" "run-incomplete" OMIT "$(uname -n)" "2020-01-01T00:00:00Z" "0.0.0" "/nowhere"
  run_lock "$dir" "$$" acquire
  expect_rc 3
  expect "release --force"
  local ld rid; ld="$(lockdir_of "$dir")"; rid="$(cat "$ld/run-id" 2>/dev/null)"
  [ "$rid" = "run-incomplete" ] || { __ok=0; __why="${__why}lock was touched\n"; }
}

# 7. refuse-unparseable-pid — pins the *[!0-9]* arm. Mutant: delete
# `case "$held_pid" in ''|*[!0-9]*) bad_record=true ;; esac` entirely (the standalone
# `[ -n "$held_pid" ]`/`[ -n "$held_host" ]` checks stay, so this isolates the non-digits arm from
# case 6's empty-pid guard). Fails exactly: THIS case.
case_refuse_unparseable_pid() {
  local dir; dir="$(mk_repo refuse-unparseable-pid)"
  write_lock "$dir" "run-unparseable" "not-a-pid" "$(uname -n)" "2020-01-01T00:00:00Z" "0.0.0" "/nowhere"
  run_lock "$dir" "$$" acquire
  expect_rc 3
  expect "release --force"
  local ld rid; ld="$(lockdir_of "$dir")"; rid="$(cat "$ld/run-id" 2>/dev/null)"
  [ "$rid" = "run-unparseable" ] || { __ok=0; __why="${__why}lock was touched\n"; }
}

# 8. release-own-run-id. Mutant: remove_lock — drop the `rmdir "$lockdir"` call (and its warning
# branch), so the lock dir's six files are removed but the now-empty directory itself is left
# behind. A reclaim's own `mkdir "$lockdir"` after remove_lock then loses to the leftover empty
# dir, so every case that reclaims fails too, alongside this case and release-force.
case_release_own_run_id() {
  local dir; dir="$(mk_repo release-own-run-id)"
  run_lock "$dir" "$$" acquire
  expect_rc 0
  local rid; rid="$(run_id_from_out)"
  run_lock "$dir" "$$" release "$rid"
  expect_rc 0
  [ -d "$(lockdir_of "$dir")" ] && { __ok=0; __why="${__why}lock dir still present\n"; }
}

# 9. release-wrong-run-id. Mutant: cmd_release's `if [ "$stored" = "$arg" ]; then` -> `if true;
# then` (mismatch is never detected). Fails exactly: THIS case.
case_release_wrong_run_id() {
  local dir; dir="$(mk_repo release-wrong-run-id)"
  run_lock "$dir" "$$" acquire
  expect_rc 0
  local rid; rid="$(run_id_from_out)"
  run_lock "$dir" "$$" release "not-the-real-id"
  expect_rc 3
  expect "$rid"
  local ld now; ld="$(lockdir_of "$dir")"
  [ -d "$ld" ] || { __ok=0; __why="${__why}lock dir missing after mismatch\n"; }
  now="$(cat "$ld/run-id" 2>/dev/null)"
  [ "$now" = "$rid" ] || { __ok=0; __why="${__why}run-id changed on mismatch\n"; }
}

# 10. release-force. Same mutant as case 8 (remove_lock's `rmdir` dropped).
case_release_force() {
  local dir; dir="$(mk_repo release-force)"
  run_lock "$dir" "$$" acquire
  expect_rc 0
  local rid; rid="$(run_id_from_out)"
  run_lock "$dir" "$$" release --force
  expect_rc 0
  expect "$rid"
  [ -d "$(lockdir_of "$dir")" ] && { __ok=0; __why="${__why}lock dir still present after --force\n"; }
}

# 11. release-no-lock. Mutant: cmd_release — delete the `if [ ! -d "$lockdir" ]; then echo
# "released=none"; exit 0; fi` shortcut entirely. Fails exactly: THIS case.
case_release_no_lock() {
  local dir; dir="$(mk_repo release-no-lock)"
  run_lock "$dir" "$$" release some-run-id
  expect_rc 0
  expect "released=none"
}

# 12. release-missing-argument — usage on stderr, not stdout (#232 kickback 1 finding 2: the
# runner now captures the two streams separately, so this and case 16 can pin which stream). Mutant:
# cmd_release's own `usage >&2` call site -> `usage` (case 16's dispatch call site is untouched).
# Fails exactly: THIS case.
case_release_missing_argument() {
  local dir; dir="$(mk_repo release-missing-argument)"
  run_lock "$dir" "$$" release
  expect_rc 2
  expect_err "usage"
  expect_absent_out "usage"
}

# 13. worktree-shares-lock. Mutant: --git-common-dir -> --git-dir. Fails exactly: THIS case.
case_worktree_shares_lock() {
  local dir; dir="$(mk_repo worktree-shares-lock)"
  local wt="$tmpbase/worktree-shares-lock-wt"
  ( cd "$dir" && git worktree add -q -b wt-branch "$wt" ) >/dev/null 2>&1
  mkdir -p "$wt/home" "$wt/xdgcfg"
  run_lock "$dir" "$$" acquire
  expect_rc 0
  run_lock "$wt" "$$" acquire
  expect_rc 3
  expect "$dir"
}

# 14. status-free-and-held — the safety pin that no case can touch this repo's own .git. Mutant:
# cmd_status — delete the free-branch's `echo "lock-path=$lockdir"` line. Fails exactly: THIS
# case.
case_status_free_and_held() {
  local dir; dir="$(mk_repo status-free-and-held)"
  run_lock "$dir" "$$" status
  expect_rc 0
  expect "state=free"
  expect "lock-path=$(lockdir_of "$dir")"
  case "$lock_out" in
    *"$root/.git"*) __ok=0; __why="${__why}status leaked this repo's own .git path\n" ;;
  esac
  run_lock "$dir" "$$" acquire
  expect_rc 0
  local rid; rid="$(run_id_from_out)"
  run_lock "$dir" "$$" status
  expect_rc 0
  expect "state=held"
  expect "$rid"
}

# 15. help-exit-0. Mutant: usage()'s heredoc — delete the "Recorded pid precedence: `--owner-pid
# <pid>` > `TBF_OWNER_PID` > `${CLAUDE_PID:-$PPID}` …" paragraph (the only place `CLAUDE_PID` or
# `--owner-pid` appears in the help text). Fails exactly: THIS case.
case_help_exit_0() {
  local dir; dir="$(mk_repo help-exit-0)"
  run_lock "$dir" "$$" --help
  expect_rc 0
  expect "acquire"
  expect "release"
  expect "status"
  expect "CLAUDE_PID"
  expect "--owner-pid"
  expect "TBF_OWNER_PID"
}

# 16. unknown-subcommand — usage on stderr, not stdout (see case 12's note on the runner's split
# streams). Mutant: the dispatch's own `usage >&2` call site -> `usage` (`*) usage >&2; exit 2
# ;;`; case 12's cmd_release call site is untouched). Fails exactly: THIS case.
case_unknown_subcommand() {
  local dir; dir="$(mk_repo unknown-subcommand)"
  run_lock "$dir" "$$" frobnicate
  expect_rc 2
  expect_err "usage"
  expect_absent_out "usage"
  [ -e "$dir/.git/trail-blazer" ] && { __ok=0; __why="${__why}lock dir created despite unknown subcommand\n"; }
}

# 17. not-a-git-repo — the exit-2 message names the cause, on stderr. Mutant: blank the "not
# inside a git repository (git rev-parse --git-common-dir failed)" message text down to
# "harness-lock.sh: error". Fails exactly: THIS case.
case_not_a_git_repo() {
  local dir="$tmpbase/not-a-git-repo"
  mkdir -p "$dir/home" "$dir/xdgcfg"
  local orig; orig="$(pwd)"
  cd "$dir" || { __ok=0; __why="${__why}cd failed\n"; return; }
  GIT_CEILING_DIRECTORIES="$tmpbase" HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdgcfg" CLAUDE_PID="$$" \
    "$bash_bin" "$root/bin/harness-lock.sh" acquire > "$dir/.lock-out" 2> "$dir/.lock-err"
  lock_rc=$?
  cd "$orig" || true
  lock_stdout="$(cat "$dir/.lock-out" 2>/dev/null)"
  lock_stderr="$(cat "$dir/.lock-err" 2>/dev/null)"
  lock_out="$(cat "$dir/.lock-out" "$dir/.lock-err" 2>/dev/null)"
  expect_rc 2
  expect_err "not inside a git repository"
  [ -e "$dir/.git" ] && { __ok=0; __why="${__why}.git unexpectedly created\n"; }
  [ -e "$dir/trail-blazer" ] && { __ok=0; __why="${__why}trail-blazer dir unexpectedly created\n"; }
}

# 18. harness-version-recorded. Mutant: `[ -n "$v" ] && [ "$v" != "null" ] && version="$v"` ->
# `false && version="$v"`, so `version` stays "unknown" regardless of plugin.json (whose real
# version, 2.6.1, is neither empty nor "unknown"). Fails exactly: THIS case.
case_harness_version_recorded() {
  local dir; dir="$(mk_repo harness-version-recorded)"
  run_lock "$dir" "$$" acquire
  expect_rc 0
  local want got
  want="$(jq -r '.version // "unknown"' "$root/.claude-plugin/plugin.json" 2>/dev/null)"
  [ -n "$want" ] || want="unknown"
  got="$(cat "$(lockdir_of "$dir")/harness-version" 2>/dev/null)"
  [ "$got" = "$want" ] || { __ok=0; __why="${__why}harness-version: expected '$want', got '$got'\n"; }
}

# 19. fallback-ppid-when-unset — pins step 9's no-command-substitution rule; the one case that
# depends on the runner invoking the script directly. Mutant applied to THIS FILE's own run_lock
# (not bin/harness-lock.sh): the UNSET branch's invocation rewrapped in a `$(…)` command
# substitution instead of a plain redirected statement — the exact thing the "RUNNER SHAPE"
# header note says must not happen, since a forked subshell's real OS pid differs from this
# file's own top-level $$, which resolved_pid()'s $PPID fallback then records instead of $$.
# Fails exactly: THIS case.
case_fallback_ppid_when_unset() {
  local dir; dir="$(mk_repo fallback-ppid-when-unset)"
  run_lock "$dir" UNSET acquire
  expect_rc 0
  expect_absent_err "note="
  local got; got="$(cat "$(lockdir_of "$dir")/pid" 2>/dev/null)"
  [ "$got" = "$$" ] || { __ok=0; __why="${__why}pid: expected \$\$ ($$), got '$got'\n"; }
}

# 20. fallback-ppid-when-garbage — pins the read AND write arms of the digits-only guard on the
# CLAUDE_PID value itself (cases 6/7 pin the same guard on the STORED record's pid instead). The
# `note=` line is on stderr (resolved_pid's non-digits arm), asserted there. Mutant: resolved_pid's
# `*[!0-9]*)` case-arm pattern changed to `*ZZZNEVERMATCHZZZ*)` so it never matches (falls through
# to the catch-all `*)` arm, which prints the garbage value as-is instead of falling back to
# $PPID). Fails exactly: THIS case.
case_fallback_ppid_when_garbage() {
  local dir; dir="$(mk_repo fallback-ppid-when-garbage)"
  run_lock "$dir" "not-a-pid" acquire
  expect_rc 0
  expect_count_err "note=" 1
  expect_err "not-a-pid"
  local got; got="$(cat "$(lockdir_of "$dir")/pid" 2>/dev/null)"
  [ "$got" = "$$" ] || { __ok=0; __why="${__why}pid: expected \$\$ ($$), got '$got'\n"; }
}

# 21. empty-needle-guard (#262-1) — exercises every guarded helper in this file (expect,
# expect_absent, expect_out, expect_err, expect_absent_out, expect_absent_err, expect_count,
# expect_count_err, expect_last_line_prefix) with an empty needle, and asserts the guard fired for
# each: sets $lock_out/$lock_stdout/$lock_stderr to fixed non-empty values first (so a
# non-guarded regression couldn't pass vacuously against empty captured output), calls all nine
# with "", then checks the ACCUMULATED __ok/__why saved off before this case's own __ok/__why are
# reset by the runner loop. Mutant: delete `needle_required expect_last_line_prefix "$1"
# || return 0` from expect_last_line_prefix only — fails exactly: empty-needle-guard (saved_why no
# longer names "expect_last_line_prefix:").
case_empty_needle_guard() {
  local saved_ok saved_why
  lock_out="fixture output for the empty-needle guard (#262)"
  lock_stdout="fixture stdout for the empty-needle guard (#262)"
  lock_stderr="fixture stderr for the empty-needle guard (#262)"
  __ok=1; __why=""
  expect ""
  expect_absent ""
  expect_out ""
  expect_err ""
  expect_absent_out ""
  expect_absent_err ""
  expect_count "" 0
  expect_count_err "" 0
  expect_last_line_prefix ""
  saved_ok="$__ok"
  saved_why="$__why"
  __ok=1; __why=""
  if [ "$saved_ok" -ne 0 ]; then
    __ok=0; __why="${__why}empty-needle guard never fired (saved_ok=$saved_ok)\n"
  fi
  local helper
  for helper in expect expect_absent expect_out expect_err expect_absent_out expect_absent_err \
                expect_count expect_count_err expect_last_line_prefix; do
    case "$saved_why" in
      *"$helper: empty needle"*) : ;;
      *) __ok=0; __why="${__why}$helper's empty-needle guard did not name itself: '$saved_why'\n" ;;
    esac
  done
}

# 22. owner-pid-flag (#408) — --owner-pid outranks CLAUDE_PID: CLAUDE_PID is set to a dead pid
# (which would be recorded if the flag weren't honored), --owner-pid $$ is live. Expect rc 0,
# recorded pid == $$, run-id ending -$$.
# mutant:408-lock-flag-ignored — bypasses the --owner-pid resolution branch in
#   bin/harness-lock.sh's cmd_acquire, falling through to TBF_OWNER_PID/CLAUDE_PID instead.
case_owner_pid_flag() {
  local dir; dir="$(mk_repo owner-pid-flag)"
  local dead; dead="$(dead_pid)"
  run_lock "$dir" "$dead" acquire --owner-pid "$$"
  expect_rc 0
  local got; got="$(cat "$(lockdir_of "$dir")/pid" 2>/dev/null)"
  [ "$got" = "$$" ] || { __ok=0; __why="${__why}pid: expected \$\$ ($$), got '$got'\n"; }
  local rid; rid="$(run_id_from_out)"
  case "$rid" in
    *"-$$") : ;;
    *) __ok=0; __why="${__why}run-id does not end with -$$: '$rid'\n" ;;
  esac
}

# 23. owner-pid-env (#408) — TBF_OWNER_PID outranks CLAUDE_PID with no --owner-pid flag given:
# same dead-CLAUDE_PID setup as owner-pid-flag. Expect rc 0, recorded pid == $$.
# mutant:408-lock-env-ignored — bypasses the TBF_OWNER_PID resolution branch in
#   bin/harness-lock.sh's cmd_acquire, falling through to CLAUDE_PID instead.
case_owner_pid_env() {
  local dir; dir="$(mk_repo owner-pid-env)"
  local dead; dead="$(dead_pid)"
  lock_tbf_owner="$$"
  run_lock "$dir" "$dead" acquire
  expect_rc 0
  local got; got="$(cat "$(lockdir_of "$dir")/pid" 2>/dev/null)"
  [ "$got" = "$$" ] || { __ok=0; __why="${__why}pid: expected \$\$ ($$), got '$got'\n"; }
}

# 24. owner-pid-flag-beats-env (#408) — pins the flag-over-env precedence directly: TBF_OWNER_PID
# names a LIVE background sleep (never $$), and --owner-pid $$ must still win. Expect pid == $$;
# the background sleep is killed and reaped afterward.
case_owner_pid_flag_beats_env() {
  local dir; dir="$(mk_repo owner-pid-flag-beats-env)"
  sleep 30 &
  local live=$!
  lock_tbf_owner="$live"
  run_lock "$dir" "$$" acquire --owner-pid "$$"
  expect_rc 0
  local got; got="$(cat "$(lockdir_of "$dir")/pid" 2>/dev/null)"
  [ "$got" = "$$" ] || { __ok=0; __why="${__why}pid: expected \$\$ ($$), got '$got'\n"; }
  kill "$live" 2>/dev/null
  wait "$live" 2>/dev/null
}

# 25. owner-pid-nondigits (#408) — a non-digits --owner-pid value, and a bare --owner-pid with no
# following value: both rc 2, no lock directory created; the first names the bad value on
# stderr, the second prints usage.
# mutant:408-lock-owner-digits — neutralises the digits-only case-arm on the --owner-pid value in
#   bin/harness-lock.sh's cmd_acquire, so a non-digits value is accepted instead of refused.
case_owner_pid_nondigits() {
  local dir; dir="$(mk_repo owner-pid-nondigits)"
  run_lock "$dir" "$$" acquire --owner-pid abc
  expect_rc 2
  expect_err "abc"
  [ -e "$dir/.git/trail-blazer" ] && { __ok=0; __why="${__why}lock dir created for a non-digits --owner-pid value\n"; }
  run_lock "$dir" "$$" acquire --owner-pid
  expect_rc 2
  expect_err "usage"
  [ -e "$dir/.git/trail-blazer" ] && { __ok=0; __why="${__why}lock dir created for a bare --owner-pid with no value\n"; }
}

# 26. owner-pid-env-nondigits (#408) — TBF_OWNER_PID=abc: rc 2, no lock directory created. Same
# digits-only guard as owner-pid-nondigits, applied to the env var instead of the flag.
case_owner_pid_env_nondigits() {
  local dir; dir="$(mk_repo owner-pid-env-nondigits)"
  lock_tbf_owner="abc"
  run_lock "$dir" "$$" acquire
  expect_rc 2
  expect_err "abc"
  [ -e "$dir/.git/trail-blazer" ] && { __ok=0; __why="${__why}lock dir created for a non-digits TBF_OWNER_PID\n"; }
}

# 27. owner-daemon-refused (#408) — a background process whose own command line contains
# "app-server" (a Codex managed app-server daemon's own tell): --owner-pid names it. Expect rc 2,
# stderr naming `codex --no-daemon`, and no lock directory created. The trailing `:` after
# `sleep 30` stops bash from exec-optimising the sleep into its own argv slot, so the extra
# "tbf-fake-app-server" argv element (itself containing "app-server" as a substring) stays visible
# to `ps -o command=`.
# mutant:408-lock-daemon-check — neutralises the "app-server" case-arm match in
#   bin/harness-lock.sh's cmd_acquire, so a daemon owner is never refused.
case_owner_daemon_refused() {
  local dir; dir="$(mk_repo owner-daemon-refused)"
  "$bash_bin" -c 'sleep 30; :' tbf-fake-app-server &
  local fake=$!
  run_lock "$dir" "$$" acquire --owner-pid "$fake"
  expect_rc 2
  expect_err "codex --no-daemon"
  [ -e "$dir/.git/trail-blazer" ] && { __ok=0; __why="${__why}lock dir created for a daemon owner\n"; }
  kill "$fake" 2>/dev/null
  wait "$fake" 2>/dev/null
}

# 28. owner-unknown-flag (#408) — an unrecognised acquire flag: rc 2, usage on stderr, no lock
# directory created.
case_owner_unknown_flag() {
  local dir; dir="$(mk_repo owner-unknown-flag)"
  run_lock "$dir" "$$" acquire --bogus
  expect_rc 2
  expect_err "usage"
  [ -e "$dir/.git/trail-blazer" ] && { __ok=0; __why="${__why}lock dir created for an unknown flag\n"; }
}

# 29. reclaim-race-serial (#482) — the issue's acceptance scenario. Two contenders, each with its
# own live owner, both judged the same stale holder stale (both are stopped at the marker mkdir,
# which comes after the stale check). A is released and runs to completion, then B. A must win
# (rc 0, the record names A's owner) and B must refuse (rc 3, no `run-id=` on its stdout) instead
# of deleting A's live record; no marker remains.
# mutant:482-lock-reread-skipped — neutralises both the record re-read comparison and the liveness
#   re-check in reclaim_stale, so B deletes A's live record and takes the lock itself.
# mutant:482-lock-marker-leaked — drops the remove_reclaim call after reclaim_stale in
#   cmd_acquire, so a finished reclaim leaves the marker behind (the marker-absent assertion).
case_reclaim_race_serial() {
  reclaim_race serial
}

# 30. reclaim-race-replaced (#482) — as reclaim-race-serial, but A's owner is killed and reaped
# before B is released, so under the marker B finds a dead pid in a record that is no longer the
# one it judged stale: only the run-id/pid re-read stops it (the liveness re-check alone would
# let B through).
# mutant:482-lock-ident-unchecked — neutralises only the record re-read comparison in
#   reclaim_stale; with A's owner dead, B then reclaims A's record.
case_reclaim_race_replaced() {
  reclaim_race replaced
}

# 31. reclaim-race-concurrent (#482) — A holds the marker, paused at remove_lock's rm; B is
# released meanwhile. B must refuse at once (rc 3, stderr names `release --force`) without
# touching the marker or the lock; A then finishes (rc 0) and its record stands.
# mutant:482-lock-arbiter-bypassed — turns the marker's `mkdir` into `mkdir -p`, which succeeds on
#   an existing directory, so B enters the critical section beside A.
case_reclaim_race_concurrent() {
  reclaim_race concurrent
}

# 32. reclaim-marker-dead (#482) — a stale lock plus a reclaim marker whose pid is dead (an
# acquire killed mid-reclaim): acquire refuses (rc 3, names `release --force`) and changes
# neither; status reports the marker; `release --force` clears lock and marker and prints what it
# cleared; the next acquire succeeds. A marker with no lock directory is cleared by
# `release --force` too.
# mutant:482-lock-force-keeps-marker — drops the marker's remove_reclaim call from cmd_release's
#   --force branch, so `release --force` reports the marker cleared but leaves it behind.
case_reclaim_marker_dead() {
  local dir; dir="$(mk_repo reclaim-marker-dead)"
  local dead dead2 host ld rd
  dead="$(dead_pid)"
  dead2="$(dead_pid)"
  host="$(uname -n)"
  ld="$(lockdir_of "$dir")"
  rd="$(reclaimdir_of "$dir")"
  write_lock "$dir" "run-old-$dead" "$dead" "$host" "2020-01-01T00:00:00Z" "0.0.0" "/nowhere"
  mkdir -p "$rd"
  printf '%s' "$dead2" > "$rd/pid"

  run_lock "$dir" "$$" acquire
  expect_rc 3
  expect_err "release --force"
  expect_err "reclaim"
  expect_absent_out "run-id=run-"
  [ "$(cat "$ld/run-id" 2>/dev/null)" = "run-old-$dead" ] || { __ok=0; __why="${__why}lock run-id changed\n"; }
  [ "$(cat "$rd/pid" 2>/dev/null)" = "$dead2" ] || { __ok=0; __why="${__why}marker pid changed\n"; }

  run_lock "$dir" "$$" status
  expect_rc 0
  expect_out "reclaim=held"
  expect_out "reclaim-pid=$dead2"

  run_lock "$dir" "$$" release --force
  expect_rc 0
  expect_out "reclaim=cleared"
  expect_out "reclaim-pid=$dead2"
  [ -d "$ld" ] && { __ok=0; __why="${__why}lock dir still present after --force\n"; }
  [ -d "$rd" ] && { __ok=0; __why="${__why}marker still present after --force\n"; }

  run_lock "$dir" "$$" status
  expect_rc 0
  expect_absent "reclaim="

  run_lock "$dir" "$$" acquire
  expect_rc 0
  expect_out "run-id="

  # A marker with no lock directory at all.
  run_lock "$dir" "$$" release --force
  expect_rc 0
  mkdir -p "$rd"
  printf '%s' "$dead2" > "$rd/pid"
  run_lock "$dir" "$$" release --force
  expect_rc 0
  expect_out "reclaim=cleared"
  expect_out "released=none"
  [ -d "$rd" ] && { __ok=0; __why="${__why}marker-only fixture: marker still present after --force\n"; }
}

# ---------------------------------------------------------------------------------------------
# name|fn|desc
cases=(
  "acquire-fresh|case_acquire_fresh|control: rc 0, run-id= last line, all six files written, pid == fixture's CLAUDE_PID"
  "acquire-twice-refused|case_acquire_twice_refused|second acquire with the same live CLAUDE_PID=\$\$: rc 3, holder record printed, stored run-id unchanged"
  "reclaim-stale-same-host|case_reclaim_stale_same_host|pre-written lock, same host, killed-and-reaped pid: rc 0, one audit line, new run-id"
  "refuse-foreign-host|case_refuse_foreign_host|same fixture but host=other.invalid, pid dead: rc 3, lock untouched"
  "refuse-live-pid-same-host|case_refuse_live_pid_same_host|host from uname -n, pid=\$\$: rc 3"
  "refuse-incomplete-record|case_refuse_incomplete_record|lock dir with no pid file: rc 3, names release --force"
  "refuse-unparseable-pid|case_refuse_unparseable_pid|pid file contains not-a-pid: rc 3, never a reclaim"
  "release-own-run-id|case_release_own_run_id|acquire, release with the printed id: rc 0, lock gone"
  "release-wrong-run-id|case_release_wrong_run_id|rc 3, holder record printed, lock still present with the original run-id"
  "release-force|case_release_force|rc 0, prints the removed record, lock gone"
  "release-no-lock|case_release_no_lock|rc 0, prints released=none"
  "release-missing-argument|case_release_missing_argument|rc 2, usage on stderr"
  "worktree-shares-lock|case_worktree_shares_lock|git worktree add a sibling; acquire in main, then from the worktree: rc 3, holder's checkout-path names the main checkout"
  "status-free-and-held|case_status_free_and_held|before acquire: state=free; after: state=held + record; lock-path never this repo's own .git"
  "help-exit-0|case_help_exit_0|--help rc 0, output names acquire, release, status, CLAUDE_PID, --owner-pid, and TBF_OWNER_PID"
  "unknown-subcommand|case_unknown_subcommand|rc 2, usage on stderr, no lock created"
  "not-a-git-repo|case_not_a_git_repo|run under GIT_CEILING_DIRECTORIES with no .git present: rc 2, message names the cause, nothing written"
  "harness-version-recorded|case_harness_version_recorded|after acquire, harness-version equals jq -r .version of .claude-plugin/plugin.json"
  "fallback-ppid-when-unset|case_fallback_ppid_when_unset|acquire with CLAUDE_PID unset via bash -c 'unset …; exec \"\$@\"': rc 0, recorded pid == this harness's own \$\$"
  "fallback-ppid-when-garbage|case_fallback_ppid_when_garbage|CLAUDE_PID=not-a-pid: rc 0, recorded pid == this harness's own \$\$, exactly one note= line"
  "empty-needle-guard|case_empty_needle_guard|#262: all nine needle-taking helpers refuse an empty needle"
  "owner-pid-flag|case_owner_pid_flag|#408: --owner-pid \$\$ outranks a dead CLAUDE_PID: rc 0, recorded pid == \$\$"
  "owner-pid-env|case_owner_pid_env|#408: TBF_OWNER_PID=\$\$ outranks a dead CLAUDE_PID with no flag: rc 0, recorded pid == \$\$"
  "owner-pid-flag-beats-env|case_owner_pid_flag_beats_env|#408: --owner-pid \$\$ outranks a live TBF_OWNER_PID: rc 0, recorded pid == \$\$"
  "owner-pid-nondigits|case_owner_pid_nondigits|#408: --owner-pid abc and a bare --owner-pid both rc 2, no lock dir created"
  "owner-pid-env-nondigits|case_owner_pid_env_nondigits|#408: TBF_OWNER_PID=abc: rc 2, no lock dir created"
  "owner-daemon-refused|case_owner_daemon_refused|#408: --owner-pid names a process whose command line contains app-server: rc 2, stderr names codex --no-daemon, no lock dir created"
  "owner-unknown-flag|case_owner_unknown_flag|#408: acquire --bogus: rc 2, usage on stderr, no lock created"
  "reclaim-race-serial|case_reclaim_race_serial|#482: two contenders both judged one holder stale; A reclaims, then B is released: A rc 0, B rc 3 with no run-id= on stdout, record names A's owner, no marker left"
  "reclaim-race-replaced|case_reclaim_race_replaced|#482: as serial, but A's owner dies before B is released: B still rc 3 (only the record re-read stops it), record still A's"
  "reclaim-race-concurrent|case_reclaim_race_concurrent|#482: B is released while A holds the marker paused inside remove_lock: B rc 3 naming release --force, marker untouched, then A rc 0"
  "reclaim-marker-dead|case_reclaim_marker_dead|#482: stale lock plus a marker with a dead pid: acquire rc 3, status shows reclaim=held, release --force clears both, next acquire rc 0; a marker-only fixture is cleared too"
)

matched=0
for row in "${cases[@]}"; do
  name="${row%%|*}"
  case "$name" in
    *"$filter"*) : ;;
    *) continue ;;
  esac
  matched=$((matched+1))
  rest="${row#*|}"
  fn="${rest%%|*}"
  desc="${rest#*|}"
  __ok=1; __why=""
  lock_tbf_owner=""
  # mutant:383-fn-lock — renames a cases=() row's target function in a scratch copy of this
  #   suite; this declare -F guard must report that row FAIL naming the missing function, instead
  #   of a silent PASS the row would otherwise get by falling through with $__ok unchanged.
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn"
  else
    __ok=0; __why="${__why}case function '$fn' is not defined (deleted or renamed?) — this row never ran\n"
  fi
  if [ "$__ok" -eq 1 ]; then
    case_ok "$name" "$desc"
  else
    case_bad "$name" "$desc"
    printf '%b' "$__why" | sed 's/^/    /'
    # #255 — bounded diagnostics: surface bin/harness-lock.sh's own captured stderr (never a
    # full-consumption `head`) so a shell-level diagnostic that leaked there isn't silently
    # discarded.
    if [ -n "$lock_stderr" ]; then
      printf '%s\n' "$lock_stderr" | sed -n '1,40p' | sed 's/^/    | /'
    fi
  fi
done

if [ "$matched" -eq 0 ]; then
  echo "no case name contains '$filter'"
  exit 1
fi

echo
echo "== summary: $pass pass, $fail fail =="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
