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
# Avoiding subshells everywhere (not just for 19/20) keeps one runner for all 20 cases instead of
# a second, parallel helper.
#
# CLAUDE_PID PER FIXTURE (RESOLVED): every case passes an explicit CLAUDE_PID value to run_lock —
# live-holder fixtures pass "$$" (this harness's own pid, alive for the whole run), stale
# fixtures pass a killed-and-reaped pid (dead_pid(): a backgrounded `sleep 30`, killed and
# waited on immediately, so its pid is guaranteed dead and not yet recycled). The two fallback
# cases (19, 20) are the only ones that depend on invocation shape instead of an explicit value:
# 19 passes the sentinel "UNSET", routing run_lock through
# `bash -c 'unset CLAUDE_PID; exec "$@"' _ bash harness-lock.sh acquire` (exec keeps the same
# pid, so bin/harness-lock.sh's own $PPID is this file's $$); 20 passes the literal garbage value
# "not-a-pid" through the normal direct-invocation branch.
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
lock_rc=0
lock_out=""
lock_stdout=""
lock_stderr=""
run_lock() {
  local dir="$1" pidval="$2"; shift 2
  local orig; orig="$(pwd)"
  cd "$dir" || { lock_rc=90; lock_out="cd $dir failed"; lock_stdout=""; lock_stderr=""; return; }
  if [ "$pidval" = "UNSET" ]; then
    HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdgcfg" \
      "$bash_bin" -c 'unset CLAUDE_PID; exec "$@"' _ "$bash_bin" "$root/bin/harness-lock.sh" "$@" \
      > "$dir/.lock-out" 2> "$dir/.lock-err"
  else
    HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdgcfg" CLAUDE_PID="$pidval" \
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
__ok=1
__why=""
expect() {
  printf '%s\n' "$lock_out" | grep -qF -- "$1" || { __ok=0; __why="${__why}missing: $1\n"; }
}
expect_absent() {
  printf '%s\n' "$lock_out" | grep -qF -- "$1" && { __ok=0; __why="${__why}unexpected: $1\n"; }
}
expect_out() {
  printf '%s\n' "$lock_stdout" | grep -qF -- "$1" || { __ok=0; __why="${__why}missing on stdout: $1\n"; }
}
expect_err() {
  printf '%s\n' "$lock_stderr" | grep -qF -- "$1" || { __ok=0; __why="${__why}missing on stderr: $1\n"; }
}
expect_absent_out() {
  printf '%s\n' "$lock_stdout" | grep -qF -- "$1" && { __ok=0; __why="${__why}unexpected on stdout: $1\n"; }
}
expect_absent_err() {
  printf '%s\n' "$lock_stderr" | grep -qF -- "$1" && { __ok=0; __why="${__why}unexpected on stderr: $1\n"; }
}
expect_rc() {
  [ "$lock_rc" -eq "$1" ] || { __ok=0; __why="${__why}rc: expected $1, got $lock_rc\n"; }
}
expect_count() {
  local needle="$1" want="$2" got
  got="$(printf '%s\n' "$lock_out" | grep -cF -- "$needle")"
  [ "$got" -eq "$want" ] || { __ok=0; __why="${__why}count: expected $want of '$needle', got $got\n"; }
}
expect_count_err() {
  local needle="$1" want="$2" got
  got="$(printf '%s\n' "$lock_stderr" | grep -cF -- "$needle")"
  [ "$got" -eq "$want" ] || { __ok=0; __why="${__why}count(stderr): expected $want of '$needle', got $got\n"; }
}
expect_last_line_prefix() {
  local last
  last="$(printf '%s\n' "$lock_stdout" | grep -v '^$' | tail -1)"
  case "$last" in
    "$1"*) : ;;
    *) __ok=0; __why="${__why}last line of stdout: expected prefix '$1', got '$last'\n" ;;
  esac
}
run_id_from_out() { printf '%s\n' "$lock_stdout" | sed -n 's/^run-id=//p' | tail -1; }

# ---------------------------------------------------------------------------------------------
# The cases. Each is run by the plain-statement runner in run_lock() above (no `$(…)` command
# substitution around the script invocation itself — see the "RUNNER SHAPE" header note; case 19
# below pins that this is load-bearing, not just style). Each case's own comment records a
# measured mutation proof: the single-clause mutant actually applied to bin/harness-lock.sh (or,
# for case 19, to this file's own run_lock), the resulting `bash dev/lock-tests.sh` summary line,
# and the exact set of cases that failed — measured 2026-09-08 in this checkout, one mutant at a
# time: fresh `cp` backup immediately before the edit, `diff`/md5 confirming a byte-identical
# restore immediately after recording the result before moving to the next mutant. Several
# clauses are shared by more than one case (the mkdir-failure branch gates all seven
# already-held-lock cases; pid_alive gates three; remove_lock's rmdir gates three) — each such
# case's comment states the full measured failing set, not just itself, per the plan's own
# instruction to "record the measured set honestly" when a mutant fails several cases.

# 1. acquire-fresh (control). Mutant: write_record — drop the `pid` file (delete
# `printf '%s' "$p" > "$lockdir/pid"`). Measured 2026-09-08 (re-measured after the #232 kickback 2
# stdout-only helper change below — figure unchanged): 17 pass, 3 fail — acquire-fresh (this case,
# via the missing/empty pid file and the pid==$$ check), fallback-ppid-when-unset,
# fallback-ppid-when-garbage (both check the pid file's content too).
#
# Second mutant (#232 kickback 2 finding — the "run-id=<id> as the LAST line of stdout"
# acceptance criterion was only checked against the merged stdout+stderr capture, so a mutant
# moving the fresh-acquire echo to stderr survived): line 178's
# `echo "run-id=$(cat "$lockdir/run-id")"` -> `... >&2`. Fixed by pointing `expect_last_line_prefix`
# and `run_id_from_out` at $lock_stdout alone (both were reading the merged $lock_out before) and
# adding `expect_out "run-id="` / `expect_absent_err "run-id="` here. Measured 2026-09-08: 17
# pass, 3 fail — acquire-fresh (this case, all three of the new/repointed assertions), plus
# release-own-run-id and release-wrong-run-id (both call run_id_from_out right after this same
# fresh-acquire path; with run-id no longer on stdout, run_id_from_out now returns empty for them
# too — release-own-run-id then releases with an empty argument (usage triggers, rc 2 instead of
# 0); release-wrong-run-id's own trailing "$now" = "$rid" check now sees $rid="" against the real
# stored id and fails "run-id changed on mismatch"). release-force stays green despite the same
# empty $rid: `expect "$rid"` degenerates to `grep -qF -- ""`, which matches unconditionally, and
# release-force's --force path never uses $rid as an argument the way release-own-run-id does.
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
# refuse-incomplete-record, refuse-unparseable-pid) never runs. Measured: 13 pass, 7 fail —
# acquire-twice-refused (this case), reclaim-stale-same-host, refuse-foreign-host,
# refuse-live-pid-same-host, refuse-incomplete-record, refuse-unparseable-pid,
# worktree-shares-lock (all seven already-held-lock cases).
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
# cmd_acquire's reclaim branch. Measured: 19 pass, 1 fail — failing exactly: THIS case.
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
# -> `if false`. Measured: 19 pass, 1 fail — failing exactly: THIS case.
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
# with `return 1` unconditionally (never alive). Measured: 17 pass, 3 fail —
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
# alternative from `case "$held_pid" in ''|*[!0-9]*) …`. Measured: 19 pass, 1 fail — failing
# exactly: THIS case.
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
# case 6's empty-pid guard). Measured: 19 pass, 1 fail — failing exactly: THIS case.
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
# behind. Measured: 17 pass, 3 fail — reclaim-stale-same-host (its second `mkdir "$lockdir"` after
# remove_lock now loses the race against the leftover empty dir), release-own-run-id (this case),
# release-force (same leftover-dir check as this case).
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
# then` (mismatch is never detected). Measured: 19 pass, 1 fail — failing exactly: THIS case.
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

# 10. release-force. Same mutant as case 8 (remove_lock's `rmdir` dropped). Measured: 17 pass, 3
# fail — reclaim-stale-same-host, release-own-run-id, release-force (this case) — see case 8's
# comment; recorded once there in full, not restated per-run here.
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
# "released=none"; exit 0; fi` shortcut entirely. Measured: 19 pass, 1 fail — failing exactly:
# THIS case.
case_release_no_lock() {
  local dir; dir="$(mk_repo release-no-lock)"
  run_lock "$dir" "$$" release some-run-id
  expect_rc 0
  expect "released=none"
}

# 12. release-missing-argument — usage on stderr, not stdout (#232 kickback 1 finding 2: the
# runner now captures the two streams separately, so this and case 16 can pin which stream). Mutant:
# cmd_release's own `usage >&2` call site -> `usage` (case 16's dispatch call site is untouched).
# Measured: 19 pass, 1 fail — failing exactly: THIS case.
case_release_missing_argument() {
  local dir; dir="$(mk_repo release-missing-argument)"
  run_lock "$dir" "$$" release
  expect_rc 2
  expect_err "usage"
  expect_absent_out "usage"
}

# 13. worktree-shares-lock. Mutant: --git-common-dir -> --git-dir. Measured: 19 pass, 1 fail —
# failing exactly: THIS case.
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
# cmd_status — delete the free-branch's `echo "lock-path=$lockdir"` line. Measured: 19 pass, 1
# fail — failing exactly: THIS case.
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

# 15. help-exit-0. Mutant: usage()'s heredoc — delete the "Recorded pid: ${CLAUDE_PID:-$PPID} —
# under Claude Code, CLAUDE_PID is …" paragraph (the only place `CLAUDE_PID` appears in the help
# text). Measured: 19 pass, 1 fail — failing exactly: THIS case.
case_help_exit_0() {
  local dir; dir="$(mk_repo help-exit-0)"
  run_lock "$dir" "$$" --help
  expect_rc 0
  expect "acquire"
  expect "release"
  expect "status"
  expect "CLAUDE_PID"
}

# 16. unknown-subcommand — usage on stderr, not stdout (see case 12's note on the runner's split
# streams). Mutant: the dispatch's own `usage >&2` call site -> `usage` (`*) usage >&2; exit 2
# ;;`; case 12's cmd_release call site is untouched). Measured: 19 pass, 1 fail — failing exactly:
# THIS case.
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
# "harness-lock.sh: error". Measured: 19 pass, 1 fail — failing exactly: THIS case.
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
# version, 2.6.1, is neither empty nor "unknown"). Measured: 19 pass, 1 fail — failing exactly:
# THIS case.
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
# Measured: 19 pass, 1 fail — failing exactly: THIS case.
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
# $PPID). Measured: 19 pass, 1 fail — failing exactly: THIS case.
case_fallback_ppid_when_garbage() {
  local dir; dir="$(mk_repo fallback-ppid-when-garbage)"
  run_lock "$dir" "not-a-pid" acquire
  expect_rc 0
  expect_count_err "note=" 1
  expect_err "not-a-pid"
  local got; got="$(cat "$(lockdir_of "$dir")/pid" 2>/dev/null)"
  [ "$got" = "$$" ] || { __ok=0; __why="${__why}pid: expected \$\$ ($$), got '$got'\n"; }
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
  "help-exit-0|case_help_exit_0|--help rc 0, output names acquire, release, status, and CLAUDE_PID"
  "unknown-subcommand|case_unknown_subcommand|rc 2, usage on stderr, no lock created"
  "not-a-git-repo|case_not_a_git_repo|run under GIT_CEILING_DIRECTORIES with no .git present: rc 2, message names the cause, nothing written"
  "harness-version-recorded|case_harness_version_recorded|after acquire, harness-version equals jq -r .version of .claude-plugin/plugin.json"
  "fallback-ppid-when-unset|case_fallback_ppid_when_unset|acquire with CLAUDE_PID unset via bash -c 'unset …; exec \"\$@\"': rc 0, recorded pid == this harness's own \$\$"
  "fallback-ppid-when-garbage|case_fallback_ppid_when_garbage|CLAUDE_PID=not-a-pid: rc 0, recorded pid == this harness's own \$\$, exactly one note= line"
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
  "$fn"
  if [ "$__ok" -eq 1 ]; then
    case_ok "$name" "$desc"
  else
    case_bad "$name" "$desc"
    printf '%b' "$__why" | sed 's/^/    /'
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
