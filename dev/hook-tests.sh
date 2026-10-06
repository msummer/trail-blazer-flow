#!/usr/bin/env bash
#
# hook-tests.sh — fixture-based negative-test harness for the five plugin-shipped PreToolUse
# hooks, in the style of dev/doctor-tests.sh: feeds fixture stdin JSON straight into the real
# script and pins its verdict. Since #407, this includes Codex-shaped payload fixtures (bare
# agent_type, plus agent_id for subagents, neither for the main session — see ADR 0002's amendment)
# for all five hooks, and the new hooks/planner-guard.sh itself.
#
# Per-PR history of what this harness pins: CHANGELOG.md (archive, #363). Each hook's own header
# and each case's own comment state its mechanism.
#
# Usage: bash dev/hook-tests.sh [name-filter] — same output contract as dev/selfcheck-tests.sh
# and dev/doctor-tests.sh: one PASS/FAIL line per case, a `== summary: N pass, M fail ==`
# footer, exit 0 iff nothing failed; a filter with no match exits 1.
#
# Every write happens under one `mktemp -d` root, removed via an EXIT trap; this repo's own
# hooks/git-c-guard.sh, hooks/agent-boundary.sh, hooks/push-guard.sh, hooks/claude-dir-guard.sh, and
# hooks/planner-guard.sh are read-only here — each script is run directly, never copied or edited
# (push-guard.sh's own fixture-repo builder below writes ONLY under that same mktemp root, never
# inside this checkout).
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"
guard="$root/hooks/git-c-guard.sh"
boundary="$root/hooks/agent-boundary.sh"
push_guard="$root/hooks/push-guard.sh"
claude_dir_guard="$root/hooks/claude-dir-guard.sh"
planner_guard="$root/hooks/planner-guard.sh"

tmpbase="$(mktemp -d)"
cleanup() {
  if [ -n "$tmpbase" ] && [ -d "$tmpbase" ]; then
    rm -rf "$tmpbase"
  fi
}
trap cleanup EXIT

# #290: a neutral, empty HOME for every push-guard fixture (see run_push_guard below) — created
# once, up front, so hooks/push-guard.sh's new $HOME/$XDG_CONFIG_HOME/$GIT_CONFIG_GLOBAL reads
# never see the developer's or CI runner's real global git config.
neutral_home="$tmpbase/neutral-home"
mkdir -p "$neutral_home"

# #304/#305: a neutral, empty sysroot for every push-guard fixture (see run_push_guard below) —
# created once, up front, so hooks/push-guard.sh's new TBF_PUSH_GUARD_SYSCONFIG_ROOT-prefixed
# static system-config reads never see the host's own real /etc/gitconfig or similar.
neutral_sysroot="$tmpbase/neutral-sysroot"
mkdir -p "$neutral_sysroot"

if ! command -v jq >/dev/null 2>&1; then
  echo "  FAIL  jq not installed — required to build fixture stdin JSON and to parse the guard's output"
  exit 1
fi

bash_bin="$(command -v bash)"

pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------------------------
# Fixture builders. jq -n --arg builds the JSON so a command string containing quotes, '#', or
# '(' '/' ')' is never hand-escaped.

mk_cmd() { jq -n --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'; }
mk_cmd_mode() { jq -n --arg cmd "$1" --arg mode "$2" '{tool_name: "Bash", tool_input: {command: $cmd}, permission_mode: $mode}'; }
mk_tool() { jq -n --arg tool "$1" --arg cmd "$2" '{tool_name: $tool, tool_input: {command: $cmd}}'; }

# _kt_descendants ROOT SNAPSHOT (#463) — prints every pid in SNAPSHOT (the "pid ppid" lines a
# `ps -A -o pid= -o ppid=` call produced) descended from ROOT, space-delimited and space-flanked, by
# repeatedly scanning SNAPSHOT until a full pass adds nothing new (a child can precede its own
# parent in `ps`'s own unordered output). No associative arrays, no pipe into grep: membership is
# tested with `case " $root$set" in *" $ppid "*` (bash-3.2-safe, the same shape
# dev/doctor-tests.sh's own copy uses — no shared dev library exists).
_kt_descendants() {
  local root="$1" snapshot="$2" set=" " pid ppid found
  found=true
  while $found; do
    found=false
    while read -r pid ppid; do
      [ -z "${pid:-}" ] && continue
      case "$set" in *" $pid "*) continue ;; esac
      # mutant:463-hook-deadline-root-only — this arm (the only place a found descendant is ever
      #   added to $set) becomes a no-op: every call returns nothing, so kill_tree below only ever
      #   signals ROOT itself, and case_deadline_kill_tree's own TERM-ignoring child survives it.
      case " $root$set" in
        *" $ppid "*) set="$set$pid "; found=true ;;
      esac
    done <<EOF
$snapshot
EOF
  done
  printf '%s' "$set"
}

# kill_tree ROOT (#463) — TERM then KILL the whole process tree rooted at ROOT (ROOT itself plus
# every live descendant _kt_descendants finds), by walking a single `ps -A -o pid= -o ppid=`
# snapshot rather than /proc, so it stays portable to BSD/macOS and procps Linux alike. TERMs the
# collected set, polls in 0.1s slices for up to 2s for every pid to die, then — only if ROOT is
# STILL alive — re-snapshots and re-collects (a TERM-ignoring descendant may have spawned a further
# child during the grace poll) before KILLing every pid still alive from either walk. If `ps` itself
# fails, falls back to signalling ROOT alone.
kill_tree() {
  local root="$1" snapshot desc1 desc2 p deadline alive
  if ! snapshot="$(ps -A -o pid= -o ppid= 2>/dev/null)"; then
    kill -TERM "$root" 2>/dev/null
    sleep 0.2
    kill -KILL "$root" 2>/dev/null
    return
  fi
  desc1="$(_kt_descendants "$root" "$snapshot")"
  for p in "$root" $desc1; do
    kill -TERM "$p" 2>/dev/null
  done
  deadline=$((SECONDS + 2))
  while [ "$SECONDS" -lt "$deadline" ]; do
    alive=false
    for p in "$root" $desc1; do
      kill -0 "$p" 2>/dev/null && alive=true
    done
    $alive || break
    sleep 0.1
  done
  desc2=""
  if kill -0 "$root" 2>/dev/null; then
    snapshot="$(ps -A -o pid= -o ppid= 2>/dev/null)"
    [ -n "$snapshot" ] && desc2="$(_kt_descendants "$root" "$snapshot")"
  fi
  for p in "$root" $desc1 $desc2; do
    kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
  done
}

# wait_deadline PID SECS (#463) — the active-poll deadline every deadline-carrying hook-tests.sh
# fixture launch goes through, replacing the old pattern of running a fixture to completion and only
# THEN comparing elapsed time to a limit: polls PID (a background job of THIS shell) in 0.1s slices
# against a $SECONDS deadline SECS seconds out. If PID is still alive once the deadline passes, fails
# the enclosing case ($__ok=0, $__why names the overrun) and kills PID's whole process tree via
# kill_tree, instead of letting the case block on PID's own natural lifetime. Always reaps PID with
# a plain `wait` before returning either way, leaving $deadline_rc set to its exit status and
# $deadline_overran set to true/false for the caller to branch on.
# mutant:463-hook-deadline-no-kill — the `kill_tree "$pid"` call below becomes `:`: an overrun is
#   still detected and the case still fails, but nothing is ever killed, so the reap that follows
#   waits out case_deadline_kill_tree's own 15s child instead of returning in under 8s.
deadline_overran=false
deadline_rc=0
wait_deadline() {
  local pid="$1" secs="$2" deadline
  deadline_overran=false
  deadline=$((SECONDS + secs))
  while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    deadline_overran=true
    __ok=0
    __why="${__why}run overran its ${secs}s deadline — killed its process tree\n"
    kill_tree "$pid"
  fi
  wait "$pid" 2>/dev/null
  deadline_rc=$?
}

# _ms_from_timeformat STR (#470) — pure parser for one bash `time`-keyword TIMEFORMAT=%3R report
# line (e.g. "0.089", "12.000", or a comma-locale "0,089"): accepts only the shape
# <digits><.|,><exactly 3 digits> — a `case` pattern pins the separator and the three sub-second
# digits, and a second `case` rejects a whole-seconds half that is empty or holds any non-digit —
# splits on the separator, then evaluates the joined digits under a `10#` base-10 prefix so a leading zero in the sub-second half is never
# misread as octal ($((0089)) errors in plain bash arithmetic). The evaluation runs inside a
# command substitution specifically so that a malformed base-10 value (e.g. under the mutant below,
# which drops the `10#` prefix) fails as a contained, empty result in THIS function alone, instead
# of a fatal arithmetic-expansion error unwinding bash's own jump_to_top_level all the way out of
# the case dispatch loop that calls this — verified directly against this exact shape (#470). Sets
# $parsed_ms, or "" when STR doesn't match the shape or the arithmetic itself failed (the group's
# own 2>/dev/null keeps that failure's diagnostic off the suite's stderr). Builtins
# only — no grep, no pipe into a reader.
# mutant:470-hook-ms-octal — the `10#` prefix dropped from the arithmetic: a leading-zero
#   sub-second value like "0.089" then evaluates as invalid octal instead of decimal 89, caught by
#   case_deadline_calibrate's own 0.089 assertion.
# mutant:470-hook-ms-shape — the whole-seconds digit check deleted: a report like "1+2.345" then
#   evaluates as arithmetic instead of coming back empty, caught by case_deadline_calibrate's own
#   1+2.345 assertion.
parsed_ms=""
_ms_from_timeformat() {
  local str="$1" whole sub
  case "$str" in
    [0-9]*.[0-9][0-9][0-9]) whole="${str%.*}"; sub="${str##*.}" ;;
    [0-9]*,[0-9][0-9][0-9]) whole="${str%,*}"; sub="${str##*,}" ;;
    *) parsed_ms=""; return ;;
  esac
  case "$whole" in ''|*[!0-9]*) parsed_ms=""; return ;; esac
  parsed_ms="$({ echo $((10#${whole}${sub})); } 2>/dev/null)"
}

# measure_ms CMD [ARGS...] (#470) — runs CMD in the CURRENT shell (never a subshell or command
# substitution, so a called bash function can still set caller-visible globals, e.g. run_boundary's
# own $boundary_out) timed by bash's own `time` keyword under a local TIMEFORMAT=%3R, capturing the
# report to a file under $tmpbase (never /tmp) rather than parsing it off a pipe. Reads the file's
# last non-empty line, hands it to _ms_from_timeformat, and sets $measured_ms to the parsed value or
# "" when the report couldn't be parsed. Always removes the report file before returning.
measured_ms=""
measure_ms() {
  local file="$tmpbase/measure-ms" line last=""
  local TIMEFORMAT='%3R'
  { time "$@" ; } 2>"$file"
  while IFS= read -r line; do
    [ -n "$line" ] && last="$line"
  done < "$file"
  rm -f "$file"
  _ms_from_timeformat "$last"
  measured_ms="$parsed_ms"
}

# calibrated_deadline FLOOR K MS (#470) — sets $calibrated_secs to max(FLOOR, ceil(K * MS / 1000)),
# integer arithmetic only (bash 3.2 has no floating point): the ceiling is computed as
# (K*MS + 999) / 1000 via truncating integer division, then raised to FLOOR if that came out lower.
calibrated_secs=0
calibrated_deadline() {
  local floor="$1" k="$2" ms="$3" secs
  secs=$(( (k * ms + 999) / 1000 ))
  if [ "$secs" -lt "$floor" ]; then
    calibrated_secs="$floor"
  else
    calibrated_secs="$secs"
  fi
}

# calibrated_site_budget MS MAX (#476) — sets $site_budget_secs, the whole-second analysis-budget
# knob a site-proving push-dl fixture runs its timed payload under, from MS, the wall time of the
# same payload's knob-0 control. The hook compares a whole-second $SECONDS against its deadline, so
# a budget of B guarantees only about B-1 seconds before its first sample can fire: a site-proving
# budget is therefore never 1. B is 1 plus calibrated_deadline's own ceil(4 * MS / 1000) (floored at
# 1, so B is at least 2; K=4 absorbs a load swing between two back-to-back runs), clamped to MAX,
# the largest knob the hook adopts, which keeps every site case invariant under 435-dl-knob-raise
# and its timed deny well inside the harness deadline.
# mutant:476-hook-site-budget-window — drops the whole-second window, so a fast control yields
#   budget 1 again (the #476 flake shape); caught by case_deadline_site_budget's own 0ms assertion.
# mutant:476-hook-site-budget-cap — deletes the MAX clamp, so a slow control yields a knob the hook
#   ignores (and 435-dl-knob-raise would adopt); caught by case_deadline_site_budget's own 751ms and
#   5000ms assertions.
site_budget_secs=0
calibrated_site_budget() {
  local ms="$1" max="$2"
  calibrated_deadline 1 4 "$ms"
  site_budget_secs=$((calibrated_secs + 1))
  [ "$site_budget_secs" -le "$max" ] || site_budget_secs="$max"
}

# case_deadline_site_budget (#476) — pins calibrated_site_budget's whole-second window, K-scaling
# and MAX clamp arithmetic with MAX=4, without a live clock: 0ms and 250ms give 2 (the window keeps
# a fast control off budget 1), 251ms gives 3, 750ms and 751ms give 4 (751ms is the first value the
# clamp has to cut), and 5000ms stays at 4.
case_deadline_site_budget() {
  local pair ms want
  for pair in 0:2 250:2 251:3 750:4 751:4 5000:4; do
    ms="${pair%%:*}"; want="${pair##*:}"
    calibrated_site_budget "$ms" 4
    [ "$site_budget_secs" -eq "$want" ] || { __ok=0; __why="${__why}calibrated_site_budget ${ms} 4: expected ${want}, got ${site_budget_secs}\n"; }
  done
}

# calibrated_flood_tokens CTL_MS CTL_N TARGET_MS MIN MAX (#507) — sets $flood_tokens to the
# control-scaled linear size clamp(CTL_N * TARGET_MS / max(CTL_MS, 1), MIN, MAX): a control that ran
# CTL_N tokens in CTL_MS predicts a linear cost of CTL_MS / CTL_N per token, so this is the token
# count whose predicted cost is TARGET_MS, never below MIN (the smallest size the kill still
# needs) nor above MAX (the proven full size). Integer arithmetic only. The CTL_MS < 1 guard has no
# registry mutant: deleting it makes a 0ms control a bash division-by-zero expansion error that
# aborts the dispatch loop instead of failing one case (the containment concern
# _ms_from_timeformat's comment documents).
# mutant:507-hook-flood-tokens-min — deletes the MIN clamp, so a slow control yields a token count
#   below the smallest size the kill needs; caught by case_deadline_flood_tokens' own 1143ms
#   assertion.
# mutant:507-hook-flood-tokens-max — deletes the MAX clamp, so a fast control yields a token count
#   above the proven full size; caught by case_deadline_flood_tokens' own 79ms and 0ms assertions.
flood_tokens=0
calibrated_flood_tokens() {
  local ms="$1" n="$2" target="$3" min="$4" max="$5"
  [ "$ms" -ge 1 ] || ms=1
  flood_tokens=$(( n * target / ms ))
  [ "$flood_tokens" -ge "$min" ] || flood_tokens="$min"
  [ "$flood_tokens" -le "$max" ] || flood_tokens="$max"
}

# case_deadline_flood_tokens (#507) — pins calibrated_flood_tokens' control scaling and MIN/MAX
# clamps with N=1000, TARGET=800, MIN=700, MAX=10000, without a live clock: 0ms, 79ms and 80ms all
# land on MAX (80ms is the first value that scales to exactly MAX), 1000ms gives 800, 1142ms gives
# exactly MIN, and 1143ms and 5000ms are the values the MIN clamp has to raise.
case_deadline_flood_tokens() {
  local pair ms want
  for pair in 0:10000 79:10000 80:10000 1000:800 1142:700 1143:700 5000:700; do
    ms="${pair%%:*}"; want="${pair##*:}"
    calibrated_flood_tokens "$ms" 1000 800 700 10000
    [ "$flood_tokens" -eq "$want" ] || { __ok=0; __why="${__why}calibrated_flood_tokens ${ms} 1000 800 700 10000: expected ${want}, got ${flood_tokens}\n"; }
  done
}

# case_deadline_kill_tree (#463) — pins the shared wait_deadline/kill_tree mechanism directly,
# independent of any hook fixture: builds a synthetic TERM-ignoring process tree (a root script plus
# one real "sleep 15" child), runs it through wait_deadline with a 2s deadline, and asserts the
# overrun was detected, the case was failed and told why, the call returned quickly rather than
# waiting out the child's own 15s lifetime, and both pids are actually dead afterwards — not merely
# that the case's own bookkeeping says so.
case_deadline_kill_tree() {
  local dir="$tmpbase/deadline-kill-tree" real_sleep script
  mkdir -p "$dir"
  real_sleep="$(command -v sleep)"
  script="$dir/tree.sh"
  {
    printf '#!%s\n' "$bash_bin"
    printf 'dir=%q\n' "$dir"
    printf 'real_sleep=%q\n' "$real_sleep"
    cat <<'TREEEOF'
trap '' TERM
"$real_sleep" 15 &
printf '%s' "$!" > "$dir/child.pid"
wait
TREEEOF
  } > "$script"
  chmod +x "$script"

  "$bash_bin" "$script" < /dev/null > "$dir/out" 2> "$dir/err" &
  local root_pid=$!

  local waited=0
  while [ ! -s "$dir/child.pid" ] && [ "$waited" -lt 5000 ] && kill -0 "$root_pid" 2>/dev/null; do
    sleep 0.05
    waited=$((waited + 50))
  done
  local child_pid
  child_pid="$(cat "$dir/child.pid" 2>/dev/null)"
  if [ -z "$child_pid" ]; then
    __ok=0; __why="${__why}the synthetic tree's own child never started — can't exercise kill_tree\n"
    kill -9 "$root_pid" 2>/dev/null
    return
  fi

  local saved_ok="$__ok" saved_why="$__why"
  __ok=1; __why=""
  local t0=$SECONDS
  wait_deadline "$root_pid" 2
  local elapsed=$((SECONDS - t0)) sub_overran="$deadline_overran" sub_ok="$__ok" sub_why="$__why"
  __ok="$saved_ok"; __why="$saved_why"

  if [ "$sub_overran" != true ]; then
    __ok=0; __why="${__why}wait_deadline did not detect the 2s overrun (deadline_overran=$sub_overran)\n"
  fi
  if [ "$sub_ok" -ne 0 ]; then
    __ok=0; __why="${__why}wait_deadline did not fail the case over the overrun (sub __ok=$sub_ok)\n"
  fi
  case "$sub_why" in
    *"deadline"*) : ;;
    *) __ok=0; __why="${__why}wait_deadline's own __why did not name the deadline: '$sub_why'\n" ;;
  esac
  if [ "$elapsed" -ge 8 ]; then
    __ok=0; __why="${__why}wait_deadline took ${elapsed}s to return — should kill and return well under the child's own 15s lifetime\n"
  fi

  local survive_waited=0 root_alive="" child_alive=""
  while [ "$survive_waited" -lt 2000 ]; do
    root_alive=""; child_alive=""
    kill -0 "$root_pid" 2>/dev/null && root_alive="$root_pid"
    kill -0 "$child_pid" 2>/dev/null && child_alive="$child_pid"
    [ -z "$root_alive" ] && [ -z "$child_alive" ] && break
    sleep 0.1
    survive_waited=$((survive_waited + 100))
  done
  if [ -n "$root_alive" ] || [ -n "$child_alive" ]; then
    __ok=0; __why="${__why}still alive after wait_deadline: root=$root_alive child=$child_alive\n"
    kill -9 "$root_pid" "$child_pid" 2>/dev/null
  fi
}

# case_deadline_calibrate (#470) — pins calibrated_deadline's own floor/scale/round-up arithmetic
# and _ms_from_timeformat's own shape parsing without touching a live clock, except one bounded
# check of measure_ms itself with a lower bound only, so host load can never flip it:
#   - calibrated_deadline: the floor wins below it, K*ms wins above it, and a non-integer result
#     rounds up rather than truncates.
#   - _ms_from_timeformat: a leading-zero sub-second value and a comma decimal separator parse the
#     same as a dot; unparseable input yields "" rather than a stale or garbage value.
#   - measure_ms: `sleep 0.3` reports at least 250ms (real elapsed always exceeds the requested
#     sleep by some scheduling overhead) — never an upper bound, so load can't make this flaky.
# mutant:470-hook-calib-floor-only — calibrated_deadline's scale-up branch deleted, so it always
#   returns FLOOR: caught by the 4000ms assertion below (K*ms=24 > floor=15, so the mutant wrongly
#   returns 15 instead of 24).
# mutant:470-hook-calib-no-ceil — the "+999" round-up term dropped from the ceiling arithmetic:
#   caught by the 2501ms assertion below (16.005s truncates to 15 instead of rounding up to 16).
case_deadline_calibrate() {
  calibrated_deadline 15 6 1000
  [ "$calibrated_secs" -eq 15 ] || { __ok=0; __why="${__why}calibrated_deadline 15 6 1000: expected 15 (floor), got $calibrated_secs\n"; }

  calibrated_deadline 15 6 4000
  [ "$calibrated_secs" -eq 24 ] || { __ok=0; __why="${__why}calibrated_deadline 15 6 4000: expected 24 (K*ms), got $calibrated_secs\n"; }

  calibrated_deadline 15 6 2501
  [ "$calibrated_secs" -eq 16 ] || { __ok=0; __why="${__why}calibrated_deadline 15 6 2501: expected 16 (rounds up), got $calibrated_secs\n"; }

  calibrated_deadline 15 6 2500
  [ "$calibrated_secs" -eq 15 ] || { __ok=0; __why="${__why}calibrated_deadline 15 6 2500: expected 15 (exact), got $calibrated_secs\n"; }

  _ms_from_timeformat "0.089"
  [ "$parsed_ms" -eq 89 ] 2>/dev/null || { __ok=0; __why="${__why}_ms_from_timeformat '0.089': expected 89, got '$parsed_ms'\n"; }

  _ms_from_timeformat "1.234"
  [ "$parsed_ms" -eq 1234 ] 2>/dev/null || { __ok=0; __why="${__why}_ms_from_timeformat '1.234': expected 1234, got '$parsed_ms'\n"; }

  _ms_from_timeformat "12.000"
  [ "$parsed_ms" -eq 12000 ] 2>/dev/null || { __ok=0; __why="${__why}_ms_from_timeformat '12.000': expected 12000, got '$parsed_ms'\n"; }

  _ms_from_timeformat "0,089"
  [ "$parsed_ms" -eq 89 ] 2>/dev/null || { __ok=0; __why="${__why}_ms_from_timeformat '0,089': expected 89, got '$parsed_ms'\n"; }

  _ms_from_timeformat "garbage"
  [ -z "$parsed_ms" ] || { __ok=0; __why="${__why}_ms_from_timeformat 'garbage': expected empty, got '$parsed_ms'\n"; }

  _ms_from_timeformat ""
  [ -z "$parsed_ms" ] || { __ok=0; __why="${__why}_ms_from_timeformat '': expected empty, got '$parsed_ms'\n"; }

  _ms_from_timeformat "1+2.345"
  [ -z "$parsed_ms" ] || { __ok=0; __why="${__why}_ms_from_timeformat '1+2.345': expected empty, got '$parsed_ms'\n"; }

  measure_ms sleep 0.3
  if [ -z "$measured_ms" ]; then
    __ok=0; __why="${__why}measure_ms sleep 0.3: could not parse a timing report\n"
  elif [ "$measured_ms" -lt 250 ]; then
    __ok=0; __why="${__why}measure_ms sleep 0.3: expected >=250ms, got ${measured_ms}ms\n"
  fi
}

# run_hook JSON [PATHVAL] — runs the real guard script against JSON on stdin, with PATH set to
# PATHVAL (defaults to this process's own PATH), leaving $hook_out (stdout only)/$hook_rc set as
# globals. Deliberately NOT invoked via command substitution itself (same idiom as
# dev/doctor-tests.sh's run_doctor and dev/selfcheck-tests.sh's run_gate) — call as a plain
# statement and read the globals after.
hook_out=""
hook_rc=0
run_hook() {
  local json="$1" pathval="${2:-$PATH}"
  hook_out="$(printf '%s' "$json" | PATH="$pathval" "$bash_bin" "$guard" 2>/dev/null)"
  hook_rc=$?
}

# expect_allow/expect_silent/expect_rc — assert against $hook_out/$hook_rc, setting $__ok=0 and
# appending to $__why on failure.
__ok=1
__why=""
expect_allow() {
  if ! printf '%s' "$hook_out" | jq -e . >/dev/null 2>&1; then
    __ok=0; __why="${__why}stdout is not valid JSON: '$hook_out'\n"; return
  fi
  local pd
  pd="$(printf '%s' "$hook_out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
  [ "$pd" = "allow" ] || { __ok=0; __why="${__why}permissionDecision is '$pd', expected 'allow'\n"; }
}
expect_silent() {
  [ -z "$hook_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$hook_out'\n"; }
}
expect_rc() {
  [ "$hook_rc" -eq "$1" ] || { __ok=0; __why="${__why}rc: expected $1, got $hook_rc\n"; }
}

# ---------------------------------------------------------------------------------------------
# hooks/agent-boundary.sh (#235) fixture builders and assertions. Documented vs. assumed stdin
# field names (LESSON 2026-09-01c): tool_name, tool_input.command, agent_id, agent_type, and
# permission_mode are all documented PreToolUse hook input fields; this harness never invents an
# undocumented field. agent_type, agent_id, tool_name: "Bash", and permission_mode: "auto" were
# also observed together in a live capture on 2026-09-08 (Claude Code 2.1.263, #259), with the
# observed agent_type being the namespaced form, which the fixtures below exercise alongside the
# bare form.

mk_agent_cmd() { jq -n --arg agent "$1" --arg cmd "$2" '{tool_name: "Bash", agent_type: $agent, tool_input: {command: $cmd}}'; }
mk_agent_cmd_mode() { jq -n --arg agent "$1" --arg cmd "$2" --arg mode "$3" '{tool_name: "Bash", agent_type: $agent, tool_input: {command: $cmd}, permission_mode: $mode}'; }
mk_agent_tool() { jq -n --arg agent "$1" --arg tool "$2" --arg cmd "$3" '{tool_name: $tool, agent_type: $agent, tool_input: {command: $cmd}}'; }
mk_agent_id_only() { jq -n --arg id "$1" --arg cmd "$2" '{tool_name: "Bash", agent_id: $id, tool_input: {command: $cmd}}'; }

# run_boundary JSON [PATHVAL] — runs the real boundary script against JSON on stdin, with PATH
# set to PATHVAL (defaults to this process's own PATH), leaving $boundary_out (stdout)/
# $boundary_err (stderr, read back from a file under $tmpbase)/$boundary_rc set as globals. Same
# "call as a plain statement, read the globals after" idiom as run_hook above — the existing
# run_hook discards stderr entirely (2>/dev/null), which cannot pin a "reason on stderr"
# criterion (LESSON 2026-09-08b), hence this separate runner with its own stderr capture file.
# $boundary_deadline_override (#463) is an opt-in override, the same shape as run_push_guard's own
# ninth override below (push_deadline_override): unset by default (the foreground path this runner
# has always used), and when a case sets it immediately before calling run_boundary, the script
# instead runs backgrounded under wait_deadline at that many seconds, killing its whole process tree
# on overrun instead of letting the case block on it. Cleared after every call either way.
boundary_out=""
boundary_err=""
boundary_rc=0
boundary_deadline_override=""
run_boundary() {
  local json="$1" pathval="${2:-$PATH}" errfile="$tmpbase/boundary-stderr"
  if [ -n "$boundary_deadline_override" ]; then
    local stdin_file="$tmpbase/boundary-stdin" out_file="$tmpbase/boundary-out" bpid
    printf '%s' "$json" > "$stdin_file"
    ( export PATH="$pathval"; exec "$bash_bin" "$boundary" ) < "$stdin_file" > "$out_file" 2> "$errfile" &
    bpid=$!
    wait_deadline "$bpid" "$boundary_deadline_override"
    boundary_rc=$deadline_rc
    boundary_out="$(cat "$out_file" 2>/dev/null)"
    rm -f "$out_file" "$stdin_file"
  else
    boundary_out="$(printf '%s' "$json" | PATH="$pathval" "$bash_bin" "$boundary" 2>"$errfile")"
    boundary_rc=$?
  fi
  boundary_err="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
  boundary_deadline_override=""
}

# expect_deny/expect_no_opinion — assert against $boundary_out/$boundary_err/$boundary_rc.
# DENY_STEM's literal text is hand-typed here (not extracted from the script), matching this
# repo's convention of pinning a script's own defined literal against an independent surface
# (e.g. dev/doctor-tests.sh hand-types bin/check-harness.sh's WARN stems, per 4.38's comment).
expect_deny() {
  [ "$boundary_rc" -eq 2 ] || { __ok=0; __why="${__why}rc: expected 2, got $boundary_rc\n"; }
  [ -z "$boundary_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$boundary_out'\n"; }
  local err_lines
  err_lines="$(printf '%s\n' "$boundary_err" | grep -c '[^[:space:]]')"
  [ "$err_lines" -eq 1 ] || { __ok=0; __why="${__why}expected exactly 1 non-blank stderr line, got $err_lines: '$boundary_err'\n"; }
  case "$boundary_err" in
    *"trail-blazer-flow agent boundary:"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain the DENY_STEM literal 'trail-blazer-flow agent boundary:': '$boundary_err'\n" ;;
  esac
}
expect_no_opinion() {
  [ "$boundary_rc" -eq 0 ] || { __ok=0; __why="${__why}rc: expected 0, got $boundary_rc\n"; }
  [ -z "$boundary_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$boundary_out'\n"; }
  [ -z "$boundary_err" ] || { __ok=0; __why="${__why}expected empty stderr, got: '$boundary_err'\n"; }
}
# expect_ab_deny_claude (#340) — the .claude-write deny class's own assertion: rc 2, empty stdout,
# exactly one non-blank stderr line, containing BOTH the DENY_STEM literal (hand-typed here, same
# convention as expect_deny above) and the fixed "a path under a .claude segment" phrase
# hooks/agent-boundary.sh's role-policy printf emits for this deny kind specifically (distinguishing
# it from a git/gh deny, which expect_deny alone cannot). Both literals are hand-typed inline, not
# extracted from the script, so no needle parameter and no needle_required guard is needed.
expect_ab_deny_claude() {
  [ "$boundary_rc" -eq 2 ] || { __ok=0; __why="${__why}rc: expected 2, got $boundary_rc\n"; }
  [ -z "$boundary_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$boundary_out'\n"; }
  local err_lines
  err_lines="$(printf '%s\n' "$boundary_err" | grep -c '[^[:space:]]')"
  [ "$err_lines" -eq 1 ] || { __ok=0; __why="${__why}expected exactly 1 non-blank stderr line, got $err_lines: '$boundary_err'\n"; }
  case "$boundary_err" in
    *"trail-blazer-flow agent boundary:"*"a path under a .claude segment"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain both the DENY_STEM literal and 'a path under a .claude segment': '$boundary_err'\n" ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Allow cases — every one of the ten `-C` forms worktree-parallel mode issues, plus quoting,
# path-shape, and composite variants.

case_status_rel()          { run_hook "$(mk_cmd 'git -C ../demo-wt-3 status --porcelain')"; expect_rc 0; expect_allow; }
case_status_abs()          { run_hook "$(mk_cmd 'git -C /Users/x/proj/demo-wt-3 status --porcelain')"; expect_rc 0; expect_allow; }
case_status_quoted()       { run_hook "$(mk_cmd 'git -C "../demo-wt-3" status --porcelain')"; expect_rc 0; expect_allow; }
case_path_windows()        { run_hook "$(mk_cmd 'git -C C:/Users/x/proj/demo-wt-12 diff main...HEAD --stat')"; expect_rc 0; expect_allow; }
case_path_trailing_slash() { run_hook "$(mk_cmd 'git -C ../demo-wt-3/ rev-parse HEAD')"; expect_rc 0; expect_allow; }
case_checkpoint_composite() {
  # probe row (d): the double-quoted '#', '(', ')', ':' in the WIP commit message must survive
  # the lexer (worktree-mode.md:35-37, 156-157).
  run_hook "$(mk_cmd 'git -C ../demo-wt-1 add -A && git -C ../demo-wt-1 commit -m "wip: checkpoint verifier (#12)"')"
  expect_rc 0
  expect_allow
}
case_reset_soft()   { run_hook "$(mk_cmd 'git -C ../demo-wt-1 reset --soft 0123abc')"; expect_rc 0; expect_allow; }
case_merge_base()   { run_hook "$(mk_cmd 'git -C ../demo-wt-1 merge-base main HEAD')"; expect_rc 0; expect_allow; }
case_restore()      { run_hook "$(mk_cmd 'git -C ../demo-wt-1 restore file.txt')"; expect_rc 0; expect_allow; }
case_push_upstream() { run_hook "$(mk_cmd 'git -C ../demo-wt-1 push -u origin "claude/17-a"')"; expect_rc 0; expect_allow; }
case_diff_name_only() { run_hook "$(mk_cmd 'git -C ../demo-wt-1 diff --name-only')"; expect_rc 0; expect_allow; }
case_log() { run_hook "$(mk_cmd 'git -C ../demo-wt-1 log main..HEAD --format=%s')"; expect_rc 0; expect_allow; }

# never-executes-git — a conforming command run with a booby-trapped git (and rm) earlier on
# PATH that touches a sentinel file: expect allow AND no sentinel. This is the guard's central
# safety property (never touch the filesystem via the untrusted -C path), pinned mechanically
# rather than by a text grep of the script.
case_never_executes_git() {
  local trapdir="$tmpbase/trapbin" sentinel="$tmpbase/sentinel-touched"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  {
    printf '#!%s\n' "$bash_bin"
    printf 'touch "%s"\n' "$sentinel"
    printf 'exit 1\n'
  } > "$trapdir/git"
  chmod +x "$trapdir/git"
  {
    printf '#!%s\n' "$bash_bin"
    printf 'touch "%s"\n' "$sentinel"
    printf 'exit 1\n'
  } > "$trapdir/rm"
  chmod +x "$trapdir/rm"
  run_hook "$(mk_cmd 'git -C ../demo-wt-1 status --porcelain')" "$trapdir:$PATH"
  expect_rc 0
  expect_allow
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — the guard invoked something on the booby-trapped PATH\n"; }
}

# ---------------------------------------------------------------------------------------------
# No-opinion cases — expect empty stdout, rc 0.

case_inject_config()      { run_hook "$(mk_cmd 'git -C ../demo-wt-1 -c core.pager=cat status')"; expect_rc 0; expect_silent; }
case_inject_execpath()    { run_hook "$(mk_cmd 'git -C ../demo-wt-1 --exec-path=/tmp/evil status')"; expect_rc 0; expect_silent; }
case_attached_c()         { run_hook "$(mk_cmd 'git -C../demo-wt-1 status')"; expect_rc 0; expect_silent; }
case_double_c()           { run_hook "$(mk_cmd 'git -C ../demo-wt-1 -C /etc status')"; expect_rc 0; expect_silent; }
case_token1_not_c() {
  # Isolates the "token 1 must be exactly -C" comparison (git-c-guard.sh's validate_segment)
  # from every other check: this first segment has 4+ tokens, a conforming worktree path at
  # position 2, and a conforming subcommand at position 3 — only the exact "-C" match rejects
  # it. attached-C/double-C above don't reach that comparison at all (they're rejected earlier,
  # by the token-count floor and by sub_allowed respectively), so a deleted exact-match check
  # would leave --exec-path= (arbitrary git helper-lookup injection) silently approved whenever
  # it rides along with a second, genuinely conforming `git -C` segment. That second segment is
  # required here for another reason too: only a literal 'git -C' substring anywhere in $cmd
  # clears the script's raw-stdin fast path before jq is ever invoked (hooks/git-c-guard.sh:26-29).
  run_hook "$(mk_cmd 'git --exec-path=/tmp/evil ../demo-wt-1 status && git -C ../demo-wt-1 status')"
  expect_rc 0
  expect_silent
}
case_attached_c_4tok() {
  # Companion to the above from the other side: the attached -C<path> form, but with 4+ tokens
  # and an otherwise-conforming path/subcommand pair at positions 2/3 — so only the exact "-C"
  # comparison (not the token-count floor that catches the shorter attached-C case above)
  # rejects it. Carries a second, genuinely conforming `git -C` segment for the same fast-path
  # reason as case_token1_not_c.
  run_hook "$(mk_cmd 'git -C../demo-wt-1 ../demo-wt-2 status && git -C ../demo-wt-1 status')"
  expect_rc 0
  expect_silent
}
case_path_not_worktree()  { run_hook "$(mk_cmd 'git -C /etc status')"; expect_rc 0; expect_silent; }
case_path_glob()          { run_hook "$(mk_cmd 'git -C ../*-wt-1 status')"; expect_rc 0; expect_silent; }
case_unknown_sub()        { run_hook "$(mk_cmd 'git -C ../demo-wt-1 clean -fd')"; expect_rc 0; expect_silent; }
case_reset_hard() {
  # probe row (c)'s static half — the deny mirror is what actually blocks this live; the hook
  # itself must have no opinion (reset without --soft is not one of the ten forms).
  run_hook "$(mk_cmd 'git -C ../demo-wt-1 reset --hard HEAD')"
  expect_rc 0
  expect_silent
}
case_composite_nongit()   { run_hook "$(mk_cmd 'git -C ../demo-wt-1 status && curl https://evil.example')"; expect_rc 0; expect_silent; }
case_composite_one_bad()  { run_hook "$(mk_cmd 'git -C ../demo-wt-1 status && git -C ../demo-wt-1 -c x=y status')"; expect_rc 0; expect_silent; }
case_substitution_dollar()   { run_hook "$(mk_cmd 'git -C ../demo-wt-1 commit -m "wip $(id)"')"; expect_rc 0; expect_silent; }
case_substitution_backtick() { run_hook "$(mk_cmd 'git -C ../demo-wt-1 commit -m "wip `id`"')"; expect_rc 0; expect_silent; }
case_semicolon()  { run_hook "$(mk_cmd 'git -C ../demo-wt-1 status; rm -rf /tmp/x')"; expect_rc 0; expect_silent; }
case_redirect()   { run_hook "$(mk_cmd 'git -C ../demo-wt-1 status > /tmp/out')"; expect_rc 0; expect_silent; }
case_pipe() {
  # No git -C command the harness issues is ever piped (dev/hook-tests.sh's sibling docs sweep
  # confirms this — see the plan's Verified facts), so an unquoted '|' is always rejected.
  run_hook "$(mk_cmd 'git -C ../demo-wt-1 status | tee /tmp/out')"
  expect_rc 0
  expect_silent
}
case_unterminated_quote() { run_hook "$(mk_cmd 'git -C "../demo-wt-1 status')"; expect_rc 0; expect_silent; }
case_wrong_tool()     { run_hook "$(mk_tool 'Read' 'git -C ../demo-wt-1 status')"; expect_rc 0; expect_silent; }
case_malformed_json() {
  # Deliberately contains the literal substring 'git -C' so this exercises jq's own parse
  # failure (a fixture with no 'git -C' substring at all would instead be caught by the
  # fast-path check before ever reaching jq — see that check above — which would make this case
  # pass vacuously without ever touching the code path its name claims to pin).
  run_hook 'not json at all, but mentions git -C anyway'
  expect_rc 0
  expect_silent
}
case_missing_command() { run_hook '{"tool_name":"Bash","tool_input":{}}'; expect_rc 0; expect_silent; }
case_plan_mode() {
  run_hook "$(mk_cmd_mode 'git -C ../demo-wt-1 status --porcelain' 'plan')"
  expect_rc 0
  expect_silent
}

# ---------------------------------------------------------------------------------------------
# hooks/agent-boundary.sh (#235) cases. Grouped by verdict/role, counts as shipped (not the
# approved plan's original enumeration, which this comment previously — and wrongly — cited
# verbatim; see LESSON 2026-09-06): implementer deny (16), implementer no opinion (5), verifier
# no opinion (7), verifier deny (14), role-agnostic no opinion (8), never-executes (2) = 52
# total (#270 added one CRLF case to each of implementer-deny, verifier-no-opinion, and
# verifier-deny). Both agent_type spellings ("implementer"/"trail-blazer-flow:implementer",
# "verifier"/"trail-blazer-flow:verifier") are exercised across each role's case set (LESSON
# 2026-09-08).

# --- implementer, deny ------------------------------------------------------------------------
case_ib_push_bare()   { run_boundary "$(mk_agent_cmd 'implementer' 'git push')"; expect_deny; }
case_ib_push_ns()     { run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' 'git push')"; expect_deny; }
case_ib_gh_pr_bare()  { run_boundary "$(mk_agent_cmd 'implementer' 'gh pr create')"; expect_deny; }
case_ib_gh_pr_ns()    { run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' 'gh pr create')"; expect_deny; }
case_ib_gh_issue_edit() { run_boundary "$(mk_agent_cmd 'implementer' 'gh issue edit 1 --add-label plan-approved')"; expect_deny; }
case_ib_git_c_push() {
  # The exact git -C <worktree> push form hooks/git-c-guard.sh's own allow cases approve
  # (dev/hook-tests.sh's case_push_upstream above) — this hook must deny it. Composition with
  # that other hook was separately measured live on 2026-09-08 (deny beat allow — see
  # hooks/agent-boundary.sh's header); this fixture pins THIS hook's own verdict independently.
  run_boundary "$(mk_agent_cmd 'implementer' 'git -C ../demo-wt-1 push -u origin claude/1-x')"
  expect_deny
}
case_ib_composite_and() { run_boundary "$(mk_agent_cmd 'implementer' 'pytest && git push')"; expect_deny; }
case_ib_assignment()    { run_boundary "$(mk_agent_cmd 'implementer' 'FOO=1 git push')"; expect_deny; }
case_ib_command_prefix() { run_boundary "$(mk_agent_cmd 'implementer' 'command git push')"; expect_deny; }
case_ib_abs_path()      { run_boundary "$(mk_agent_cmd 'implementer' '/usr/bin/git push')"; expect_deny; }
case_ib_bash_c()        { run_boundary "$(mk_agent_cmd 'implementer' 'bash -c "git push"')"; expect_deny; }
case_ib_semicolon()     { run_boundary "$(mk_agent_cmd 'implementer' 'echo hi; gh pr create')"; expect_deny; }
case_ib_subshell()      { run_boundary "$(mk_agent_cmd 'implementer' '(cd x && git push)')"; expect_deny; }
case_ib_readonly_subcommand() {
  # Isolates the implementer/verifier role-policy split itself: "git status" is on
  # VERIFIER_GIT_READONLY (see case_vn_status's no-opinion verdict for the identical command
  # under agent_type: verifier), but the implementer denies ANY git subcommand, read-only or
  # not — a mutant that swapped the implementer onto the verifier's read-only membership test
  # would flip only this case (every other impl-deny-* fixture above uses a non-readonly
  # subcommand, so it would keep denying under either policy and this mutant would slip past
  # unnoticed).
  run_boundary "$(mk_agent_cmd 'implementer' 'git status --porcelain')"
  expect_deny
}
case_ib_chained_prefix() {
  # Regression fixture for the round-1 kickback finding: TWO chained PREFIX_WORDS tokens
  # ("sudo" then "bash") in front of the command word. hooks/agent-boundary.sh:167 originally
  # read `if (!saw_prefix && (norm in prefix_set))`, which stops skipping after the FIRST
  # recognised prefix word, so the second one ("bash") became the wrongly-resolved command word
  # and this command denied nothing. impl-deny-command-prefix and impl-deny-bash-c above each
  # carry only ONE prefix word, so neither isolates this clause.
  run_boundary "$(mk_agent_cmd 'implementer' 'sudo bash -c "git push"')"
  expect_deny
}
case_ib_crlf_cmdword() {
  # #270: CR on the command word -- the only place a CR actually evades this hook (a CR elsewhere,
  # e.g. `git push<CR>`, still resolves cmdword to a clean "git" and already denies). Raw stdin
  # carries "agent_type" (via mk_agent_cmd) and "git" before the escaped \r, satisfying both
  # fast paths.
  run_boundary "$(mk_agent_cmd 'implementer' "git${CR} push")"
  expect_deny
}

# --- implementer, no opinion -------------------------------------------------------------------
case_in_npm_test()  { run_boundary "$(mk_agent_cmd 'implementer' 'npm test')"; expect_no_opinion; }
case_in_pytest()    { run_boundary "$(mk_agent_cmd 'implementer' 'pytest -q')"; expect_no_opinion; }
case_in_selfcheck() { run_boundary "$(mk_agent_cmd 'implementer' 'bash dev/selfcheck.sh')"; expect_no_opinion; }
case_in_grep_arg() {
  # Control proving the command-position rule: 'git' appears only as grep's own argument, never
  # as a command word.
  run_boundary "$(mk_agent_cmd 'implementer' 'grep -rn "git push" .')"
  expect_no_opinion
}
case_in_git_c_guard_script() {
  # Control proving exact-match, not substring-match: the command word's basename is
  # "git-c-guard.sh", which CONTAINS "git" but does not EQUAL it.
  run_boundary "$(mk_agent_cmd 'implementer' 'bash hooks/git-c-guard.sh')"
  expect_no_opinion
}

# --- verifier, no opinion -----------------------------------------------------------------------
case_vn_diff()      { run_boundary "$(mk_agent_cmd 'verifier' 'git diff main...HEAD --stat')"; expect_no_opinion; }
case_vn_log()       { run_boundary "$(mk_agent_cmd 'verifier' 'git log main..HEAD --format=%s')"; expect_no_opinion; }
case_vn_status()    { run_boundary "$(mk_agent_cmd 'verifier' 'git status --porcelain')"; expect_no_opinion; }
case_vn_restore()   { run_boundary "$(mk_agent_cmd 'verifier' 'git restore api/x.py')"; expect_no_opinion; }
case_vn_c_log()     { run_boundary "$(mk_agent_cmd 'verifier' 'git -C ../demo-wt-1 log main..HEAD --format=%s')"; expect_no_opinion; }
case_vn_show_ns()   { run_boundary "$(mk_agent_cmd 'trail-blazer-flow:verifier' 'git show HEAD')"; expect_no_opinion; }
case_vn_crlf_status() {
  # #270: verifier, git status<CR> -- pins the subcommand-resolution side of the strip. Before the
  # fix this DENIES (fail-closed: "status<CR>" is not an exact VERIFIER_GIT_READONLY member,
  # unlike case_vn_status's clean "status --porcelain"); after the fix it is no opinion. The only
  # new case whose pre-fix failure is a deny rather than a no-opinion, which is why it is worth
  # having: it proves the fix is not a blanket widening of denials. Raw stdin carries "agent_type"
  # and "git" before the escaped \r.
  run_boundary "$(mk_agent_cmd 'verifier' "git status${CR}")"
  expect_no_opinion
}

# --- verifier, deny ------------------------------------------------------------------------------
case_vd_commit()      { run_boundary "$(mk_agent_cmd 'verifier' 'git commit -m x')"; expect_deny; }
case_vd_stash()       { run_boundary "$(mk_agent_cmd 'verifier' 'git stash')"; expect_deny; }
case_vd_checkout()    { run_boundary "$(mk_agent_cmd 'verifier' 'git checkout -- api/x.py')"; expect_deny; }
case_vd_gh_comment_bare() { run_boundary "$(mk_agent_cmd 'verifier' 'gh issue comment 1 -b x')"; expect_deny; }
case_vd_gh_comment_ns()   { run_boundary "$(mk_agent_cmd 'trail-blazer-flow:verifier' 'gh issue comment 1 -b x')"; expect_deny; }
case_vd_inject_config()   { run_boundary "$(mk_agent_cmd 'verifier' 'git -c core.pager=cat log')"; expect_deny; }
case_vd_no_pager_log() {
  # Isolates the "-globalopt-" sentinel from every other verifier-deny case above: --no-pager
  # takes no value, so a scan that merely SKIPPED an unrecognised dashed token (instead of
  # sentinel-and-stop) would land on "log" — itself a genuine VERIFIER_GIT_READONLY member — and
  # wrongly allow. Every other injected-option fixture here (-c core.pager=cat, --git-dir=...)
  # happens to have its very next token also be non-readonly, so a naive "skip past" mutant would
  # still deny them for the wrong reason; only this fixture's outcome flips.
  run_boundary "$(mk_agent_cmd 'verifier' 'git --no-pager log')"
  expect_deny
}
case_vd_git_dir()         { run_boundary "$(mk_agent_cmd 'verifier' 'git --git-dir=/tmp/x push')"; expect_deny; }
case_vd_c_commit()        { run_boundary "$(mk_agent_cmd 'verifier' 'git -C ../demo-wt-1 commit -m x')"; expect_deny; }
case_vd_clean()            { run_boundary "$(mk_agent_cmd 'verifier' 'git clean -fd')"; expect_deny; }
case_vd_bare_git()         { run_boundary "$(mk_agent_cmd 'verifier' 'git')"; expect_deny; }
case_vd_composite()        { run_boundary "$(mk_agent_cmd 'verifier' 'pytest && git commit -m x')"; expect_deny; }
case_vd_chained_prefix() {
  # Verifier-side sibling of impl-deny-chained-prefix — same regression, two chained
  # PREFIX_WORDS tokens ("env" then "sudo") in front of the command word.
  run_boundary "$(mk_agent_cmd 'verifier' 'env sudo git commit -m x')"
  expect_deny
}
case_vd_crlf_gh() {
  # #270: verifier, gh<CR> ... -- the gh branch, whose role policy compares the printed command
  # word exactly ("gh" vs. the scan's emitted cmdword). Raw stdin carries "agent_type" and "gh"
  # before the escaped \r.
  run_boundary "$(mk_agent_cmd 'verifier' "gh${CR} issue comment 1 -b x")"
  expect_deny
}

# --- role-agnostic, no opinion -------------------------------------------------------------------
mk_plain_cmd() { jq -n --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'; }
# mk_agent_missing_command AGENT — tool_input.command absent, but the raw JSON still contains
# both the literal 'agent_type' and a 'git' substring (in an unrelated field) so this case
# actually reaches the "cmd empty" check (step 7) instead of passing vacuously via fast path 2
# (LESSON 2026-08-26's analogue — see the plan's step 10).
mk_agent_missing_command() { jq -n --arg agent "$1" --arg note "was going to run git push" '{tool_name: "Bash", agent_type: $agent, tool_input: {}, note: $note}'; }

case_ra_no_agent_type_key() {
  # No 'agent_type' substring anywhere in the raw stdin at all — reaches only fast path 1 (the
  # main session issuing a Bash call never carries this key), never spawns jq.
  run_boundary "$(mk_plain_cmd 'git push')"
  expect_no_opinion
}
case_ra_explore()        { run_boundary "$(mk_agent_cmd 'Explore' 'git push')"; expect_no_opinion; }
case_ra_empty_agent_type() { run_boundary "$(mk_agent_cmd '' 'git push')"; expect_no_opinion; }
case_ra_agent_id_only() {
  # agent_id present (so this IS inside a subagent call) but no agent_type key at all — same
  # "no agent_type substring" fast-path-1 exit as the no-agent-type-key case above.
  run_boundary "$(mk_agent_id_only 'agent-123' 'git push')"
  expect_no_opinion
}
case_ra_plan_mode() { run_boundary "$(mk_agent_cmd_mode 'implementer' 'git push' 'plan')"; expect_no_opinion; }
case_ra_wrong_tool() {
  # Contains 'agent_type' AND 'git' (the real command word), so this reaches the .tool_name
  # check (step 4) rather than passing vacuously via either fast path.
  run_boundary "$(mk_agent_tool 'implementer' 'Read' 'git push')"
  expect_no_opinion
}
case_ra_malformed_json() {
  # Deliberately contains both literal substrings 'agent_type' and 'git' so this exercises jq's
  # own parse failure (step 3's jq spawn, then a failed .tool_name read) rather than passing
  # vacuously via either fast path.
  run_boundary 'not json at all, but mentions agent_type and git push anyway'
  expect_no_opinion
}
case_ra_missing_command() {
  run_boundary "$(mk_agent_missing_command 'implementer')"
  expect_no_opinion
}

# --- never-executes --------------------------------------------------------------------------
# Same booby-trapped-PATH idiom as case_never_executes_git above (git-c-guard.sh), applied to
# this hook on both the deny path and the no-opinion path: the boundary never invokes git, gh,
# or rm on the untrusted command string it is scanning — it only ever reads it as text.
case_boundary_never_executes_deny() {
  local trapdir="$tmpbase/trapbin-boundary-deny" sentinel="$tmpbase/sentinel-boundary-deny"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_boundary "$(mk_agent_cmd 'implementer' 'git push')" "$trapdir:$PATH"
  expect_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — the boundary invoked something on the booby-trapped PATH\n"; }
}
case_boundary_never_executes_noop() {
  local trapdir="$tmpbase/trapbin-boundary-noop" sentinel="$tmpbase/sentinel-boundary-noop"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_boundary "$(mk_agent_cmd 'verifier' 'git status --porcelain')" "$trapdir:$PATH"
  expect_no_opinion
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — the boundary invoked something on the booby-trapped PATH\n"; }
}

# --- hooks/agent-boundary.sh: the #340 `.claude` Bash-write deny class -----------------------
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter
# "ab-claude-"), re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table.
# mutant:340-fastpath — deletes the widened fast path 2's `*[Cc]…[Ee]*` alternative, so every
#   deny fixture below whose raw stdin carries no "git"/"gh" substring exits silently before ever
#   reaching the scan.
# mutant:340-fastpath-case — narrows that same alternative to the literal `*claude*` (no case
#   fold), isolating ab-claude-deny-case-variant's `.Claude` spelling as the one fixture that
#   depends on the fast path's OWN case-insensitivity (the scan's tolower() still runs regardless).
# mutant:340-redirect-pass — disables the redirect pass's own `print`, so a bare `>`/`>>` target
#   carrying a `.claude` segment is never emitted, even though the scan still runs.
# mutant:340-arg-vocab — empties CLAUDE_PATH_ARG_COMMANDS, so `tee`/`cp`/`cd` writing into
#   `.claude` via a plain argument (not a redirect) is never checked.
# mutant:340-sed-short — makes the `^-[A-Za-z]*i` in-place-flag regex unmatchable, isolating the
#   short `sed -i`/`-i.bak` spelling from the long `--in-place` one.
# mutant:340-sed-long — makes the `--in-place` regex unmatchable, the long-spelling mirror of
#   340-sed-short.
# mutant:340-segment-exact — widens has_claude_seg()'s `index("/" u "/", "/.claude/")` exact-
#   segment check to a bare substring test, so `.claude-backup` would start matching too.
# mutant:340-tolower — removes has_claude_seg()'s `tolower()`, so a case-variant segment like
#   `.Claude` no longer matches.
# mutant:340-backslash — removes has_claude_seg()'s backslash-to-slash `gsub`, so a
#   backslash-separated path never normalises to a `.claude` segment.
# mutant:340-input-redirect — widens the redirect pass's `>` to `[<>]`, so an input redirect
#   (`wc -l < .claude/LESSONS.md`) starts wrongly denying.
# mutant:340-quote-strip-dq — turns has_claude_seg()'s double-quote strip into a no-op, so a double
#   quote directly adjacent to the segment (`".claude/…`) hides it.
# mutant:340-quote-strip-sq — the single-quote mirror of 340-quote-strip-dq (`'.claude/…`).
# mutant:340-sed-combined — narrows the short in-place regex to a bare `-i`, so a combined flag
#   cluster such as `-Ei` is no longer recognised as in-place.
# mutant:340-arg-gate — applies the vocabulary walk to every command word, not only tee/cp/mv/cd/
#   pushd, so reading a `.claude` path with `cat` starts wrongly denying.
# mutant:340-inplace-gate — applies the sed `.claude` walk without an in-place flag, so a read-only
#   `sed -n` on a `.claude` path starts wrongly denying.
# mutant:340-policy-arm — makes the role-policy loop's `"-claude-write- "*)` arm unmatchable, so
#   a `-claude-write-` line the scan emits is never turned into a deny at all.
case_ab_claude_deny_append_redirect() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' "printf '%s\n' '- 2026-09-24: always do X' >> .claude/LESSONS.md")"
  expect_ab_deny_claude
}
case_ab_claude_deny_redirect_nospace_quoted() {
  run_boundary "$(mk_agent_cmd 'verifier' 'echo x >"/Users/x/proj/.claude/LESSONS.md"')"
  expect_ab_deny_claude
}
case_ab_claude_deny_heredoc() {
  run_boundary "$(mk_agent_cmd 'implementer' "cat >> /repo/.claude/LESSONS.md <<'EOF'${LF}- lesson${LF}EOF")"
  expect_ab_deny_claude
}
case_ab_claude_deny_case_variant() {
  run_boundary "$(mk_agent_cmd 'implementer' 'echo x >> .Claude/LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_claude_deny_backslash() {
  run_boundary "$(mk_agent_cmd 'implementer' "echo x >> 'C:\\repo\\.claude\\LESSONS.md'")"
  expect_ab_deny_claude
}
case_ab_claude_deny_tee() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:verifier' 'cat notes.txt | tee -a .claude/LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_claude_deny_cp() {
  run_boundary "$(mk_agent_cmd 'implementer' 'cp /tmp/lesson.md .claude/LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_claude_deny_cd() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' 'cd .claude && cat /tmp/l >> LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_claude_deny_sed_short() {
  run_boundary "$(mk_agent_cmd 'implementer' "sed -i.bak '\$a x' .claude/LESSONS.md")"
  expect_ab_deny_claude
}
case_ab_claude_deny_sed_long() {
  run_boundary "$(mk_agent_cmd 'verifier' "sed --in-place '\$a x' .claude/LESSONS.md")"
  expect_ab_deny_claude
}
case_ab_claude_deny_quoted_double() {
  run_boundary "$(mk_agent_cmd 'implementer' 'echo x >> ".claude/LESSONS.md"')"
  expect_ab_deny_claude
}
case_ab_claude_deny_quoted_single() {
  run_boundary "$(mk_agent_cmd 'verifier' "cat notes.txt | tee -a '.claude/LESSONS.md'")"
  expect_ab_deny_claude
}
case_ab_claude_deny_sed_combined() {
  run_boundary "$(mk_agent_cmd 'implementer' "sed -Ei 's/a/b/' .claude/LESSONS.md")"
  expect_ab_deny_claude
}
case_ab_claude_deny_never_writes() {
  local trapdir="$tmpbase/trapbin-ab-claude-never-writes" sentinel="$tmpbase/sentinel-ab-claude-never-writes"
  local target_dir="$tmpbase/ab-claude-tree/.claude"
  local target_file="$target_dir/LESSONS.md"
  mkdir -p "$trapdir" "$target_dir"
  rm -f "$sentinel"
  for bin in git gh rm; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  # Run from inside the fixture tree with a RELATIVE target: the scanned command text then carries no
  # random mktemp characters, which could otherwise contain "gh" and defeat the 340-fastpath mutant.
  local oldpwd="$PWD"
  cd "$tmpbase/ab-claude-tree" || { __ok=0; __why="${__why}cannot cd into the fixture tree\n"; return; }
  run_boundary "$(mk_agent_cmd 'implementer' 'echo x >> .claude/LESSONS.md')" "$trapdir:$PATH"
  cd "$oldpwd" || { __ok=0; __why="${__why}cannot cd back to $oldpwd\n"; return; }
  expect_ab_deny_claude
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — the boundary invoked something on the booby-trapped PATH\n"; }
  [ ! -e "$target_file" ] || { __ok=0; __why="${__why}target file present — the boundary performed the redirect it was scanning\n"; }
}
case_ab_claude_noop_input_redirect() {
  run_boundary "$(mk_agent_cmd 'implementer' 'wc -l < .claude/LESSONS.md')"
  expect_no_opinion
}
case_ab_claude_noop_tee_elsewhere() {
  run_boundary "$(mk_agent_cmd 'implementer' 'cat .claude/LESSONS.md | tee /tmp/out.txt')"
  expect_no_opinion
}
case_ab_claude_noop_sed_no_inplace() {
  run_boundary "$(mk_agent_cmd 'verifier' "sed -n '1,5p' .claude/LESSONS.md")"
  expect_no_opinion
}
case_ab_claude_noop_near_miss() {
  run_boundary "$(mk_agent_cmd 'implementer' 'echo x >> .claude-backup/notes.md')"
  expect_no_opinion
}
case_ab_claude_noop_main_session() {
  run_boundary "$(mk_plain_cmd 'echo x >> .claude/LESSONS.md')"
  expect_no_opinion
}

# --- hooks/agent-boundary.sh: the #387 .claude command-level interpreter/writer class -----------
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter
# "ab-cwrite-"), re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table.
# mutant:387-vocab-empty — empties CLAUDE_CMDLINE_WRITE_COMMANDS, so no command word is ever a
#   member and the command-level rule never fires at all.
# mutant:387-version-strip — makes the trailing-version-suffix strip a no-op, isolating a versioned
#   command word (e.g. python3.12) from an unversioned one.
# mutant:387-cross-line — resets cw_word/cw_tok at the start of every record instead of letting them
#   accumulate across the whole tool_input.command, isolating the heredoc-fed case whose command
#   word and .claude mention are on different lines.
# mutant:387-word-gate — drops the END block's cw_word != "" condition, so a .claude mention alone
#   (with no vocabulary command word anywhere) starts wrongly denying.
# mutant:387-tok-gate — drops the END block's cw_tok != "" condition, so a vocabulary command word
#   alone (with no .claude mention anywhere) starts wrongly denying.
# mutant:387-boundary-lead — widens claude_seg_in_text()'s LEADING boundary class to match any
#   character, so a near-miss segment like "my.claude" starts wrongly matching.
# mutant:387-boundary-trail — widens claude_seg_in_text()'s TRAILING boundary class to match any
#   character, so a near-miss segment like ".claude-plugin" starts wrongly matching.
# mutant:387-tolower — removes claude_seg_in_text()'s tolower(), so a case-variant segment like
#   ".Claude" no longer matches.
case_ab_cwrite_deny_python_c() {
  run_boundary "$(mk_agent_cmd 'implementer' "python3 -c \"open('.claude/LESSONS.md','a').write('- lesson')\"")"
  expect_ab_deny_claude
}
case_ab_cwrite_deny_python_heredoc() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' "python3 - <<'EOF'${LF}open('.claude/LESSONS.md','a').write('- lesson')${LF}EOF")"
  expect_ab_deny_claude
}
case_ab_cwrite_deny_perl_i() {
  run_boundary "$(mk_agent_cmd 'verifier' "perl -i.bak -pe 's/a/b/' .claude/LESSONS.md")"
  expect_ab_deny_claude
}
case_ab_cwrite_deny_dd() {
  run_boundary "$(mk_agent_cmd 'implementer' 'dd if=/tmp/lesson.md of=.claude/LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_cwrite_deny_install() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:verifier' 'install -m 644 /tmp/lesson.md .claude/LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_cwrite_deny_versioned_abs() {
  run_boundary "$(mk_agent_cmd 'implementer' "/usr/local/bin/python3.12 -c \"open('.claude/LESSONS.md','a')\"")"
  expect_ab_deny_claude
}
case_ab_cwrite_deny_case_variant() {
  run_boundary "$(mk_agent_cmd 'implementer' 'install -m 644 /tmp/lesson.md .Claude/LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_cwrite_deny_never_writes() {
  local trapdir="$tmpbase/trapbin-ab-cwrite-never-writes" sentinel="$tmpbase/sentinel-ab-cwrite-never-writes"
  local target_dir="$tmpbase/ab-cwrite-tree/.claude"
  local target_file="$target_dir/LESSONS.md"
  mkdir -p "$trapdir" "$target_dir"
  rm -f "$sentinel"
  for bin in git gh rm; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  # Run from inside the fixture tree with a RELATIVE target: the scanned command text then carries no
  # random mktemp characters, which could otherwise contain "gh" and defeat the 340-fastpath mutant.
  local oldpwd="$PWD"
  cd "$tmpbase/ab-cwrite-tree" || { __ok=0; __why="${__why}cannot cd into the fixture tree\n"; return; }
  run_boundary "$(mk_agent_cmd 'implementer' "python3 -c \"open('.claude/LESSONS.md','a').write('x')\"")" "$trapdir:$PATH"
  cd "$oldpwd" || { __ok=0; __why="${__why}cannot cd back to $oldpwd\n"; return; }
  expect_ab_deny_claude
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — the boundary invoked something on the booby-trapped PATH\n"; }
  [ ! -e "$target_file" ] || { __ok=0; __why="${__why}target file present — the boundary performed the write it was scanning\n"; }
}
case_ab_cwrite_noop_reader() {
  run_boundary "$(mk_agent_cmd 'implementer' 'npm install && grep -n lesson .claude/LESSONS.md && cat .claude/BASELINE.md')"
  expect_no_opinion
}
case_ab_cwrite_noop_no_claude_seg() {
  run_boundary "$(mk_agent_cmd 'implementer' 'python3 -m pytest tests/test_claude_client.py')"
  expect_no_opinion
}
case_ab_cwrite_noop_claude_plugin() {
  run_boundary "$(mk_agent_cmd 'verifier' "python3 -c \"import json; json.load(open('.claude-plugin/plugin.json'))\"")"
  expect_no_opinion
}
case_ab_cwrite_noop_my_claude() {
  run_boundary "$(mk_agent_cmd 'implementer' 'touch build/my.claude')"
  expect_no_opinion
}
case_ab_cwrite_noop_main_session() {
  run_boundary "$(mk_plain_cmd "python3 -c \"open('.claude/LESSONS.md','a').write('- lesson')\"")"
  expect_no_opinion
}

# --- hooks/agent-boundary.sh: the #398 shell-keyword / case-fold class -------------------------
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter "ab-kw-"),
# re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table.
# mutant:398-ab-kw-vocab — drops only the shell-keyword words (if/then/elif/else/do/while/until/!/
#   coproc) from PREFIX_WORDS, leaving the #403 eval/trap/zsh-modifier words in place, so every
#   fixture below whose command relies on skipping a leading keyword no longer resolves git/gh as
#   the command word.
# mutant:398-ab-case-fold — removes emit_segment()'s tolower() around normalize(tok), so an
#   upper/mixed-case command word no longer resolves to "git"/"gh"/a vocabulary member.
# mutant:398-ab-fastpath-case — narrows fast path 2's widened `*[Gg][Ii][Tt]*|*[Gg][Hh]*`
#   alternative back to the plain `*git*|*gh*` (no case fold), isolating a fixture whose raw stdin
#   carries no case-insensitive git/gh/claude substring at all.
case_ab_kw_deny_if_then() {
  # The issue's own headline shape.
  run_boundary "$(mk_agent_cmd 'implementer' 'if true; then git push; fi')"
  expect_deny
}
case_ab_kw_deny_bang_gh() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' '! gh issue close 5')"
  expect_deny
}
case_ab_kw_deny_while_do() {
  run_boundary "$(mk_agent_cmd 'implementer' 'while true; do git push; done')"
  expect_deny
}
case_ab_kw_deny_while_cond() {
  # 'while' directly in front of the command word (the condition list runs it) — the only fixture
  # that pins 'while' itself; case_ab_kw_deny_while_do above rests on 'do' alone.
  run_boundary "$(mk_agent_cmd 'implementer' 'while git push; do break; done')"
  expect_deny
}
case_ab_kw_deny_until() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' 'until git push; do sleep 1; done')"
  expect_deny
}
case_ab_kw_deny_if_cond() {
  # The keyword sits in the CONDITION position, not the body — 'if' is the segment's own prefix
  # word regardless of which clause the git/gh command sits in.
  run_boundary "$(mk_agent_cmd 'implementer' 'if gh pr list; then echo x; fi')"
  expect_deny
}
case_ab_kw_deny_else() {
  run_boundary "$(mk_agent_cmd 'implementer' 'if false; then :; else git push; fi')"
  expect_deny
}
case_ab_kw_deny_elif() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' 'if false; then :; elif git push; then :; fi')"
  expect_deny
}
case_ab_kw_deny_coproc() {
  run_boundary "$(mk_agent_cmd 'implementer' 'coproc git push')"
  expect_deny
}
case_ab_kw_deny_chained() {
  # Two chained keywords ('if' then '!') in front of the command word — the repeat-until-exhausted
  # PREFIX_WORDS skip's 0/1/2+ boundary, the keyword-class sibling of case_ib_chained_prefix above.
  run_boundary "$(mk_agent_cmd 'implementer' 'if ! git push; then :; fi')"
  expect_deny
}
case_ab_kw_deny_verifier_then() {
  run_boundary "$(mk_agent_cmd 'verifier' 'if true; then git push; fi')"
  expect_deny
}
case_ab_kw_deny_verifier_bang() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:verifier' '! gh issue close 5')"
  expect_deny
}
case_ab_kw_deny_upper_git() {
  run_boundary "$(mk_agent_cmd 'implementer' 'GIT push')"
  expect_deny
}
case_ab_kw_deny_mixed_gh() {
  run_boundary "$(mk_agent_cmd 'verifier' 'Gh issue close 5')"
  expect_deny
}
case_ab_kw_deny_upper_abs() {
  run_boundary "$(mk_agent_cmd 'implementer' '/usr/bin/GIT push')"
  expect_deny
}
case_ab_kw_deny_upper_prefix() {
  # tolower() runs before the prefix-word membership test, so an upper-case prefix word ("ENV")
  # is skipped too, not only an upper-case command word.
  run_boundary "$(mk_agent_cmd 'implementer' 'ENV git push')"
  expect_deny
}
case_ab_kw_deny_upper_python() {
  run_boundary "$(mk_agent_cmd 'implementer' "PYTHON3 -c \"open('.claude/LESSONS.md','a')\"")"
  expect_ab_deny_claude
}
case_ab_kw_deny_upper_tee() {
  # The arg-vocabulary path (CLAUDE_PATH_ARG_COMMANDS), not the command-level #387 rule: "TEE"
  # case-folds to the "tee" member.
  run_boundary "$(mk_agent_cmd 'implementer' 'echo x | TEE -a .claude/LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_kw_deny_upper_touch() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' 'Touch .claude/LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_kw_deny_kw_python() {
  # Combines both #398 classes with the #387 command-level rule: a keyword-skipped, upper-case
  # command word that case-folds to a CLAUDE_CMDLINE_WRITE_COMMANDS member.
  run_boundary "$(mk_agent_cmd 'implementer' "if true; then PYTHON3 -c \"open('.claude/LESSONS.md','a')\"; fi")"
  expect_ab_deny_claude
}
case_ab_kw_deny_verifier_upper_sub() {
  # RESOLVED Q4: the git SUBCOMMAND is never case-folded, so a case-variant read-only subcommand is
  # not on the verifier's VERIFIER_GIT_READONLY list and denies (fail closed).
  # mutant:398-ab-gitsub-exact — case-folds gitsub in emit_segment(), so "STATUS" matches the
  #   read-only "status" entry and the verifier is let through.
  run_boundary "$(mk_agent_cmd 'verifier' 'git STATUS')"
  expect_deny
}
case_ab_kw_noop_keyword_arg() {
  # Control: proves the keyword skip applies only in COMMAND position. 'then' here is echo's
  # own argument, not a segment-leading token, so it must not be treated as a prefix word; the raw
  # stdin still contains "git", so the scan genuinely runs.
  run_boundary "$(mk_agent_cmd 'implementer' 'echo then git push')"
  expect_no_opinion
}
case_ab_kw_noop_verifier_if_diff() {
  # Release-blocker control: the keyword skip must not widen the verifier's read-only git allowance.
  run_boundary "$(mk_agent_cmd 'verifier' 'if git diff --quiet; then echo same; fi')"
  expect_no_opinion
}

# --- hooks/agent-boundary.sh: the #403 eval/trap/zsh-precommand-modifier class -------------------
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter "ab-pc-"),
# re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table.
# mutant:403-ab-pc-vocab — reverts PREFIX_WORDS to its pre-#403 (#398) value (drops eval/trap/
#   noglob/nocorrect/-/repeat), so every fixture below whose command relies on skipping one of
#   those words no longer resolves git/gh as the command word.
# mutant:403-ab-pc-repeat — removes the `repeat`-count skip, so a `repeat N` prefix leaves the
#   count token itself as the resolved command word instead of the real command.
# mutant:403-ab-pc-dbracket — disables the additive `]]` pass entirely (db_rest set to empty), so a
#   zsh short `if [[ cond ]] cmd` form never resumes command position at `cmd`, whether the `]]` is
#   mid-line, opens a second physical line, or is tab-bounded.
# mutant:403-ab-pc-dbracket-truncate — reverts the MAIN segment split to the pre-fix truncating
#   form (turning `]]` into a newline on that same pass), so a base command word with a literal `]]`
#   token AFTER it in the same segment (e.g. `tee ]] .claude/LESSONS.md`) loses everything past the
#   `]]` from ITS OWN segment, even though the separate additive pass still resumes `]]`'s own short
#   -if handling correctly.
# mutant:403-ab-pc-dbracket-nopad — removes the space-padding around the additive pass's own copy of
#   the record, so a `]]` sitting at the very start of a physical line (nothing of its own before
#   it, e.g. the second line of a multi-line command) is no longer bounded and never resolved.
# mutant:403-ab-pc-dbracket-spaceonly — narrows the additive pass's boundary character class from
#   `[ \t]` to `[ ]` (space only), so a `]]` bounded by a TAB rather than a space is no longer
#   recognised.
# mutant:403-ab-pc-empty-tok — deletes the empty-normalised-token skip, so a token that normalises
#   to empty (e.g. a lone `"` left by a leading space inside a quoted `eval` argument) ends the
#   walk with an empty command word instead of being skipped.
case_ab_pc_deny_eval_git() {
  run_boundary "$(mk_agent_cmd 'implementer' 'eval git push')"
  expect_deny
  case "$boundary_err" in
    *"(blocked: git push)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: git push)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_deny_eval_quoted_gh() {
  # The issue's own headline shape: eval reading a quoted string as the command.
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' 'eval "gh issue close 5"')"
  expect_deny
  case "$boundary_err" in
    *"(blocked: gh)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: gh)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_deny_eval_lead_space() {
  run_boundary "$(mk_agent_cmd 'implementer' 'eval " gh issue close 5"')"
  expect_deny
  case "$boundary_err" in
    *"(blocked: gh)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: gh)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_deny_trap_gh() {
  run_boundary "$(mk_agent_cmd 'implementer' "trap 'gh issue close 5' EXIT")"
  expect_deny
  case "$boundary_err" in
    *"(blocked: gh)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: gh)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_deny_noglob() {
  run_boundary "$(mk_agent_cmd 'implementer' 'noglob git push')"
  expect_deny
  case "$boundary_err" in
    *"(blocked: git push)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: git push)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_deny_nocorrect() {
  run_boundary "$(mk_agent_cmd 'implementer' 'nocorrect gh pr merge 5')"
  expect_deny
  case "$boundary_err" in
    *"(blocked: gh)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: gh)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_deny_dash() {
  run_boundary "$(mk_agent_cmd 'implementer' '- git push')"
  expect_deny
  case "$boundary_err" in
    *"(blocked: git push)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: git push)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_deny_repeat() {
  run_boundary "$(mk_agent_cmd 'implementer' 'repeat 3 git push')"
  expect_deny
  case "$boundary_err" in
    *"(blocked: git push)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: git push)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_deny_short_if() {
  run_boundary "$(mk_agent_cmd 'implementer' 'if [[ 1 ]] git push')"
  expect_deny
  case "$boundary_err" in
    *"(blocked: git push)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: git push)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_deny_short_if_and() {
  # Pins that '&&' inside the [[ ]] condition cannot hide the tail: '&' is itself a segment-break
  # character, but the real command still resolves in its own segment after the closing ']]'.
  run_boundary "$(mk_agent_cmd 'implementer' 'if [[ -n a && -n b ]] gh issue close 5')"
  expect_deny
  case "$boundary_err" in
    *"(blocked: gh)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: gh)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_deny_verifier_eval() {
  run_boundary "$(mk_agent_cmd 'verifier' 'eval git push')"
  expect_deny
  case "$boundary_err" in
    *"(blocked: git push)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: git push)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_noop_verifier_eval_status() {
  # Release-blocker control: the new eval/trap/zsh-modifier skip must not narrow the verifier's
  # read-only git allowance.
  run_boundary "$(mk_agent_cmd 'verifier' 'eval git status')"
  expect_no_opinion
}
case_ab_pc_noop_bash_dbracket() {
  # Ordinary bash '[[ ]] &&' (not zsh's short-if form) is not over-blocked: '[[' resolves as its
  # own (non-git/gh) command word in its own segment, and the '&&'-joined 'echo git' segment's own
  # command word is 'echo', not 'git'.
  run_boundary "$(mk_agent_cmd 'implementer' '[[ -n x ]] && echo git')"
  expect_no_opinion
}
# --- hooks/agent-boundary.sh: the additive `]]` handling must never truncate an existing deny ------
# A base (pre-#403) deny whose command word sits BEFORE a later, literal `]]` token in the same
# segment (e.g. `tee`'s own CLAUDE_PATH_ARG_COMMANDS argument walk finding `.claude/LESSONS.md`
# past a `]]` token) must still fire: the segments the main split produces are untouched by the
# additive `]]` pass, which only ADDS further segments, never truncates existing ones.
case_ab_pc_deny_dbracket_tee_claude() {
  run_boundary "$(mk_agent_cmd 'implementer' 'tee ]] .claude/LESSONS.md')"
  expect_ab_deny_claude
}
# Boundary variants of the additive `]]` handling itself: a `]]` at the very start of a physical
# line (a multi-line command, `]]` opening the SECOND line with nothing of its own before it) and a
# `]]` bounded by a TAB rather than a space must both still resume command position.
case_ab_pc_deny_dbracket_multiline() {
  run_boundary "$(mk_agent_cmd 'implementer' "if [[ -n a${LF}]] git push")"
  expect_deny
  case "$boundary_err" in
    *"(blocked: git push)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: git push)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_deny_dbracket_tab() {
  run_boundary "$(mk_agent_cmd 'implementer' "if [[ 1 ]]${DBTAB}git push")"
  expect_deny
  case "$boundary_err" in
    *"(blocked: git push)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: git push)': '$boundary_err'\n" ;;
  esac
}
# --- hooks/agent-boundary.sh: bounded, disjoint additive `]]` work ---------------------------------
# mutant:403-ab-pc-dbracket-once — changes the additive loop's `while` to `if`, so only the FIRST
#   standalone `]]` in a record is ever handled; a later `]]` whose own tail carries the deciding
#   git/gh command is never reached.
# mutant:403-ab-pc-dbracket-cap — removes the `db_n >= dbracket_max` check, so a record with more
#   standalone `]]` than DBRACKET_MAX is analysed in full instead of failing closed.
case_ab_pc_deny_dbracket_second() {
  # The deciding `]]` is the SECOND one in the record, not the first -- proves the additive loop
  # keeps advancing past a `]]` whose own tail resolves to nothing (`true`).
  run_boundary "$(mk_agent_cmd 'implementer' 'if [[ 1 ]] true; if [[ 1 ]] git push')"
  expect_deny
  case "$boundary_err" in
    *"(blocked: git push)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: git push)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_deny_dbracket_second_gh() {
  run_boundary "$(mk_agent_cmd 'implementer' 'if [[ 1 ]] true; if [[ 1 ]] gh issue close 5')"
  expect_deny
  case "$boundary_err" in
    *"(blocked: gh)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: gh)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_deny_dbracket_flood() {
  # A flood of standalone `]]` (more than DBRACKET_MAX) followed by a REAL `;`-separated `git push`
  # segment: the deny comes from the untouched MAIN split, unaffected by the additive cap or by how
  # the additive tails are cut. This case checks only the VERDICT; it does not measure elapsed time
  # -- see case_ab_pc_deny_dbracket_timing below for the dedicated wall-clock proof that the additive
  # loop stays bounded rather than growing with how many `]]` a record carries.
  local flood="" i
  for i in $(seq 1 70); do flood="${flood} ]]"; done
  run_boundary "$(mk_agent_cmd 'implementer' "echo${flood}; git push")"
  expect_deny
  case "$boundary_err" in
    *"(blocked: git push)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: git push)': '$boundary_err'\n" ;;
  esac
}
case_ab_pc_deny_dbracket_cap() {
  # Exactly DBRACKET_MAX + 1 standalone `]]`, no git/gh in COMMAND position anywhere: the main pass
  # never denies (its own command word is `echo`), and none of the 65 additive tails ever resolves
  # to git/gh either -- only the cap's own fail-closed sentinel can deny this record at all. The
  # literal "git" after "echo" is a harmless ARGUMENT (never a resolved command word in any
  # segment); it exists only so the raw-stdin fast path lets this record reach the scan at all.
  local flood="" i
  for i in $(seq 1 65); do flood="${flood} ]]"; done
  run_boundary "$(mk_agent_cmd 'implementer' "echo git${flood}")"
  expect_deny
  case "$boundary_err" in
    *"(blocked: too many ]] tokens to analyse)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: too many ]] tokens to analyse)': '$boundary_err'\n" ;;
  esac
}
# mutant:403-ab-pc-dbracket-overlap — restores overlapping tails (drops the standalone-`]]`
#   alternative from the disjoint cut regex), so a tail that should have been cut at the NEXT `]]`
#   instead runs to the next real break, re-finding a `.claude` target on the far side of that `]]`
#   directly (the ordinary reason) instead of failing closed on the CUT tail (the new reason), and
#   overruns case_ab_pc_deny_dbracket_timing below's own calibrated deadline.
case_ab_pc_deny_dbracket_disjoint() {
  # Disjoint tails alone would lose this deny: an overlapping tail after the first `]]` runs all the
  # way to `.claude/LESSONS.md` and finds it directly (the ordinary ".claude segment" reason). Under
  # disjoint tails, that same tail is cut at the SECOND `]]`, leaving only `tee` with nothing after it
  # -- resolved as CUT (see emit_segment()'s own arg_set handling), which fails closed with its own
  # distinct reason instead. Pins that the cut-claude-write fail-closed rule, not an accidental full
  # scan, is what still denies this.
  run_boundary "$(mk_agent_cmd 'implementer' 'if [[ 1 ]] tee ]] .claude/LESSONS.md')"
  expect_deny
  case "$boundary_err" in
    *"cannot verify whether this write reaches a .claude segment"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'cannot verify whether this write reaches a .claude segment': '$boundary_err'\n" ;;
  esac
}
# ab_pc_dbracket_timing_filler (#463) — case_ab_pc_deny_dbracket_timing's own filler count depends
# on which awk hooks/agent-boundary.sh's `awk` call actually spawns: this harness runs the hook
# with no PATH override for this case, so it resolves the same `awk` this probe does. A BSD/
# one-true-awk regex `split()` costs superlinearly in record length, where a gawk/mawk split is
# linear, so on BSD awk even the unmutated walk grows faster than linearly with the filler; it
# needs a far smaller filler to keep the unmutated walk's own calibrated margin wide (#470), while
# the 403-ab-pc-dbracket-overlap mutant's repeated re-splits still overrun it. Detected from `awk --version`'s
# own banner via a builtin-safe capture-then-case (never a writer piped into grep -q, per
# CLAUDE.md); stdin is redirected from /dev/null so an awk that doesn't recognise the flag can
# never block reading it. An awk whose banner doesn't match is treated as linear-cost (the
# conservative, larger-filler choice).
ab_pc_dbracket_timing_filler() {
  local v
  v="$(awk --version </dev/null 2>&1)"
  case "$v" in
    "awk version"*) printf '%s' 160000; return ;;
  esac
  printf '%s' 350000
}
case_ab_pc_deny_dbracket_timing() {
  # Wall-clock proof: an overlapping tail re-split()s almost the whole remaining record once per
  # earlier `]]`, so the mutated (overlap-restored) walk pays one near-whole-record split per each of
  # the flood's fixed 64 `]]` occurrences, where disjoint tails bound each emit_segment() walk to its
  # own cut segment; so this large, 64-`]]` shape resolves well under the deadline calibrated below
  # (#470 — boundary_deadline_override, not a passive post-hoc measurement, and no longer one fixed
  # constant: see the control payload and calibrated_deadline call below). This suite's own other
  # flood cases (dbracket-cap/-flood/-disjoint/-sed-cut/-sed-inplace-cut) are ALSO CPU-bound awk
  # work, so a mutant-driver run with many concurrent full `ab-pc-` suites can genuinely contend
  # for the host's cores — which is exactly the load a same-run calibrated deadline, rather than a
  # fixed one, absorbs. The filler count comes from ab_pc_dbracket_timing_filler above, sized
  # per-awk rather than fixed: a BSD/one-true-awk split() is superlinear in record length while a
  # gawk/mawk split is linear, so one filler size for every awk either leaves a linear awk's
  # mutated run too close to its own calibrated margin or pushes a BSD awk's unmutated run too
  # close to its own — sizing per-awk keeps both margins wide on either awk. The command reaches jq
  # on stdin (printf is a builtin), never as a --arg: Linux refuses any single exec argument over its
  # per-argument limit, which this command exceeds, so mk_agent_cmd would build an empty payload
  # there and the hook would see no command at all.
  local flood="x" i
  for i in $(seq 1 64); do flood="${flood} ]] tee"; done
  local filler
  filler="$(printf ' a%.0s' $(seq 1 "$(ab_pc_dbracket_timing_filler)"))"
  local payload
  payload="$(printf '%s\ngit push' "${flood}${filler}" \
    | jq -Rs '{tool_name: "Bash", agent_type: "implementer", tool_input: {command: .}}')"

  # Control payload (#470): same byte length as the timed payload above, but only the FIRST
  # ` ]] tee` segment keeps its `]]`; the other 63 become same-length, breaker-free text with no
  # `]]` (` zz tee`), so exactly one standalone `]]` remains and no second one exists for an
  # overlapping tail to re-split from. That makes this control invariant under
  # 403-ab-pc-dbracket-overlap: its own cost tracks the UNMUTATED walk's cost as load scales, never
  # the mutated walk's, which is what lets it calibrate a same-run deadline below rather than a
  # fixed constant.
  local ctl_flood="x" ctl_i
  for ctl_i in $(seq 1 64); do
    if [ "$ctl_i" -eq 1 ]; then ctl_flood="${ctl_flood} ]] tee"; else ctl_flood="${ctl_flood} zz tee"; fi
  done
  local ctl_payload
  ctl_payload="$(printf '%s\ngit push' "${ctl_flood}${filler}" \
    | jq -Rs '{tool_name: "Bash", agent_type: "implementer", tool_input: {command: .}}')"
  measure_ms run_boundary "$ctl_payload"
  if [ -z "$measured_ms" ]; then
    __ok=0; __why="${__why}control run's own timing report could not be parsed — can't calibrate a deadline\n"
    return
  fi

  # FLOOR/K (#470; calibrated_deadline's own arithmetic is pinned by case_deadline_calibrate, not
  # here, so these two figures stay in code, never a measured ratio): K sits strictly between the
  # unmutated/control cost ratio and the mutated/control cost ratio, with at least a 2x margin on
  # each side, so a transient load swing between the control run just above and the timed run just
  # below can't flip the verdict either way; FLOOR keeps today's idle-host behaviour, where the
  # control itself is too fast for K*control alone to leave headroom.
  local floor=15 k=6
  calibrated_deadline "$floor" "$k" "$measured_ms"
  boundary_deadline_override="$calibrated_secs"
  run_boundary "$payload"
  # mutant:463-hook-boundary-override-leaks — run_boundary's own trailing
  #   `boundary_deadline_override=""` reset deleted: this assertion is the only thing that would
  #   catch the override surviving into the NEXT case, since a leaked value here still happens to
  #   equal what this case itself just set.
  [ -z "$boundary_deadline_override" ] || { __ok=0; __why="${__why}boundary_deadline_override not cleared after run_boundary: '$boundary_deadline_override'\n"; }
  if [ "$deadline_overran" = true ]; then
    __why="${__why}control ${measured_ms}ms -> deadline ${calibrated_secs}s\n"
  fi
  expect_deny
}
# mutant:403-ab-pc-dbracket-sed-noninplace — deletes the `else if (cut_flag) { print
#   "-cut-claude-write-" }` arm for a NON-in-place `sed`, so a `sed` tail with no in-place flag among
#   its own available tokens, cut short by a following `]]`, silently resolves no opinion instead of
#   failing closed.
case_ab_pc_deny_dbracket_sed_cut() {
  # `sed s/a/b/` (no `-i` visible) cut short by the SECOND `]]`: this hook cannot rule out an `-i`
  # flag and a `.claude` target on the far side of that `]]`, so it fails closed even though nothing
  # in the available tokens looks in-place. `git diff` alone is verifier-read-only, so any deny here
  # must come from the cut-sed arm, not from the main pass.
  run_boundary "$(mk_agent_cmd 'verifier' 'x ]] sed s/a/b/ ]] y; git diff')"
  expect_deny
  case "$boundary_err" in
    *"cannot verify whether this write reaches a .claude segment"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'cannot verify whether this write reaches a .claude segment': '$boundary_err'\n" ;;
  esac
}
# mutant:403-ab-pc-dbracket-sed-inplace — deletes the in-place `if (!found_claude && cut_flag) print
#   "-cut-claude-write-"` arm, so an in-place `sed` tail with no `.claude` target among its own
#   available tokens, cut short by a following `]]`, silently resolves no opinion instead of failing
#   closed.
case_ab_pc_deny_dbracket_sed_inplace_cut() {
  # `sed -i s/a/b/` cut short by the SECOND `]]`: the in-place flag IS visible, but no `.claude`
  # target is among the available tokens -- this hook cannot rule one out on the far side of that
  # `]]`, so it fails closed. `git diff` alone is verifier-read-only, so any deny here must come from
  # the cut-sed arm, not from the main pass.
  run_boundary "$(mk_agent_cmd 'verifier' 'x ]] sed -i s/a/b/ ]] y; git diff')"
  expect_deny
  case "$boundary_err" in
    *"cannot verify whether this write reaches a .claude segment"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'cannot verify whether this write reaches a .claude segment': '$boundary_err'\n" ;;
  esac
}

# --- hooks/agent-boundary.sh: a runtime expansion in command position (#508) ----------------------
# A word whose basename holds a dollar sign followed by a name character, a digit, a special
# parameter or a quote may expand to nothing, so the real command word behind it must still resolve.
# A git reached past one emits the fail-closed "-expansion-" subcommand, and an env -S string that
# names git or gh behind an expansion denies. Every payload names git, gh or claude, or the raw-stdin
# fast path would pass it vacuously.
# abx_deny ROLE BLOCKED CMD... — each CMD denies, naming (blocked: BLOCKED).
abx_deny() {
  local role="$1" blocked="$2" c w0
  shift 2
  for c in "$@"; do
    w0="$__why"; __why=""
    run_boundary "$(mk_agent_cmd "$role" "$c")"
    expect_deny
    case "$boundary_err" in
      *"(blocked: $blocked)"*) ;;
      *) __ok=0; __why="${__why}stderr missing '(blocked: $blocked)': '$boundary_err'\n" ;;
    esac
    if [ -n "$__why" ]; then __why="${w0}[$c] ${__why}"; else __why="$w0"; fi
  done
}
# abx_noop ROLE CMD... — each CMD gets no opinion.
abx_noop() {
  local role="$1" c w0
  shift
  for c in "$@"; do
    w0="$__why"; __why=""
    run_boundary "$(mk_agent_cmd "$role" "$c")"
    expect_no_opinion
    if [ -n "$__why" ]; then __why="${w0}[$c] ${__why}"; else __why="$w0"; fi
  done
}
# mutant:508-ab-rx-skip-off — drops the skip of an expansion word, so it ends the walk as the
#   command word and the real git or gh behind it never resolves.
# mutant:508-ab-rx-re-zsh — drops the zsh expansion characters (equals, tilde, caret) from the
#   expansion predicate, so $=X gh is no expansion.
case_ab_rtexp_deny_impl_gh() {
  abx_deny implementer gh '$X gh pr merge 5' '$=X gh pr merge 5' '$~X gh pr merge 5' '$^X gh pr merge 5'
}
case_ab_rtexp_deny_impl_git() {
  abx_deny implementer 'git -expansion-' '$X git push origin feature/x' '$X git commit -m m'
}
# mutant:508-ab-rx-re-sq — drops the apostrophe from the expansion predicate, so an ANSI-C quoted
#   word is no expansion.
# mutant:508-ab-rx-skip-no-prefix — drops the prefix flag from the expansion skip, so an option word
#   after the expansion becomes the command word.
case_ab_rtexp_deny_option_word_gh() {
  # The skipped expansion still counts as a prefix word, so the option after it is skipped too.
  abx_deny implementer gh '$X -rf gh pr merge 5'
}
case_ab_rtexp_deny_env_s_record_wide() {
  # The env -S check is record-wide: an expansion-bearing -S string denies when the record names
  # git or gh anywhere as an exact word.
  abx_deny implementer gh "env -S'\$X' true; echo gh"
  abx_deny verifier 'git -expansion-' "env -S'\$X' true; git status"
}
case_ab_rtexp_deny_env_ansi_c_gh() {
  abx_deny implementer gh "env \$'A=b' gh pr merge 5"
}
# mutant:508-ab-rx-re-special — drops digits and special parameters from the expansion predicate.
case_ab_rtexp_deny_positional_gh() {
  abx_deny implementer gh '$1 gh pr merge 5'
}
# mutant:508-ab-rx-git-sentinel — drops the fail-closed subcommand for a git reached past an
#   expansion, so the verifier read-only rule sees the real subcommand.
case_ab_rtexp_deny_verifier_git_status() {
  abx_deny verifier 'git -expansion-' '$X git status'
}
# mutant:508-ab-rx-assign-prefix — drops the flag for an expansion in an assignment after a prefix
#   word.
case_ab_rtexp_deny_verifier_env_assign() {
  abx_deny verifier 'git -expansion-' 'env X=$Y git status'
}
case_ab_rtexp_deny_verifier_gh() {
  abx_deny verifier gh '"$X" gh issue list'
}
case_ab_rtexp_deny_claude_tee() {
  run_boundary "$(mk_agent_cmd 'implementer' '$X tee -a .claude/LESSONS.md')"
  expect_ab_deny_claude
}
# mutant:508-ab-rx-envs-off — never runs the env -S check, so an expansion-bearing split string
#   naming gh is skipped as an option.
case_ab_rtexp_deny_env_s_brace_gh() {
  abx_deny implementer gh 'env -S'"'"'${X}gh\_pr\_merge\_5'"'"
}
# mutant:508-ab-rx-envs-unescape — stops reading the backslash-underscore separator as a space, so a
#   name glued to it is no exact word.
case_ab_rtexp_deny_env_s_escaped_gh() {
  abx_deny implementer gh 'env -S'"'"'$X\_gh\_pr\_merge\_5'"'"
  # the segment-cut form: the record-level check alone reads it, the split string's own tokens do not
  abx_deny implementer gh 'env -S'"'"'${X}\_gh\_pr\_merge\_5'"'"
}
# mutant:508-ab-rx-basename — tests the whole token instead of its basename, so an expansion in a
#   directory part hides the command word.
case_ab_rtexp_deny_dir_expansion_gh() {
  abx_deny implementer gh '$X/usr/bin/gh pr merge 5'
}
case_ab_rtexp_deny_codex_impl_gh() {
  run_boundary "$(mk_codex_shell 'implementer' '$X gh pr merge 5')"
  expect_deny
  case "$boundary_err" in
    *"(blocked: gh)"*) ;;
    *) __ok=0; __why="${__why}stderr missing '(blocked: gh)': '$boundary_err'\n" ;;
  esac
}
case_ab_rtexp_deny_verifier_git_slot() {
  # Already denied before this change (the expansion is the subcommand); pinned so it stays so.
  abx_deny verifier 'git $X' 'git $X status'
}
# mutant:508-ab-rx-lone-dollar — treats any dollar sign as an expansion, so a lone prompt dollar is
#   skipped and the gh behind it denies.
# mutant:508-ab-rx-in-env-any — tracks every prefix word as env, so a sudo -S option with an
#   expansion runs the env -S check.
case_ab_rtexp_noop_sudo_s() {
  # -S belongs to sudo here, not env, so the env -S check never applies.
  abx_noop implementer "sudo -S'\$X' true && echo gh"
}
case_ab_rtexp_noop_prompt_dollar() {
  abx_noop implementer "$(printf 'cat <<EOF\n$ gh pr merge 5\nEOF\nls')"
}
# mutant:508-ab-rx-envs-word — matches git and gh as substrings instead of exact words, so github in
#   a later segment trips the check.
case_ab_rtexp_noop_env_s_no_names() {
  abx_noop implementer 'env -S'"'"'${X}ls\_-la'"'"' && echo github'
}
# mutant:508-ab-rx-bare-assign — drops the prefix-word condition, so a bare assignment, which is
#   never word-split, also sets the flag.
case_ab_rtexp_noop_verifier_bare_assign() {
  abx_noop verifier 'X=$Y git status'
}
case_ab_rtexp_noop_controls() {
  # Expansion text outside command position stays quiet, and so does the harness's own env PATH
  # prefix shape (its trailing echo names github only so the raw-stdin fast path reads the payload).
  abx_noop implementer '$X ls && echo gh' 'echo $X gh pr merge 5' \
    'env PATH=/bin:$PATH bash dev/hook-tests.sh && echo github'
}
# ab_rx_flood_cmd N — an env line of N expansion-bearing -S options, then a line naming github so the
# raw-stdin fast path reads the payload. ab_rx_flood_twin_cmd N keeps the same layout and byte length
# but only the FIRST -S option carries an expansion.
ab_rx_flood_cmd() {
  printf 'env%s true\necho github' "$(printf " -S'\$X'%.0s" $(seq 1 "$1"))"
}
ab_rx_flood_twin_cmd() {
  local m=$(( $1 - 1 ))
  printf "env -S'\$X'%s true\necho github" "$(printf " -S'ab'%.0s" $(seq 1 "$m"))"
}
ab_rx_payload() {
  printf '%s' "$1" | jq -Rs '{tool_name: "Bash", agent_type: "implementer", tool_input: {command: .}}'
}
# mutant:508-ab-rx-rescan — rescans the whole record at every expansion-bearing -S option instead of
#   using the per-record result, so the flood turns quadratic and overruns its calibrated deadline.
case_ab_rtexpscan_noop_flood() {
  # FLOOD + TIMING, sized and bounded by cost RATIO from a same-run control, never by absolute speed:
  # the twin (one expansion-bearing -S option) is timed with no deadline, the flood's token count is
  # scaled from it, and the flood runs under an active deadline of K times the predicted linear cost.
  # The command reaches jq on stdin, never as a --arg.
  local ctl_n=1000 min_n=700 max_n=10000 floor=2 k=8
  local target_ms=$(( DL_KNOB_MAX * 200 )) ctl_ms pred_ms
  measure_ms run_boundary "$(ab_rx_payload "$(ab_rx_flood_twin_cmd "$ctl_n")")"
  ctl_ms="$measured_ms"
  if [ -z "$ctl_ms" ]; then
    __ok=0; __why="${__why}control run's own timing report could not be parsed — can't size the flood\n"
    return
  fi
  expect_no_opinion
  if [ "$__ok" -eq 0 ]; then
    __why="${__why}twin control did not return no opinion\n"
    return
  fi
  calibrated_flood_tokens "$ctl_ms" "$ctl_n" "$target_ms" "$min_n" "$max_n"
  pred_ms=$(( ctl_ms * flood_tokens / ctl_n ))
  calibrated_deadline "$floor" "$k" "$pred_ms"
  boundary_deadline_override="$calibrated_secs"
  measure_ms run_boundary "$(ab_rx_payload "$(ab_rx_flood_cmd "$flood_tokens")")"
  expect_no_opinion
  if [ "$__ok" -eq 0 ]; then
    __why="${__why}control ${ctl_ms}ms at ${ctl_n} -> ${flood_tokens} tokens, predicted ${pred_ms}ms -> deadline ${calibrated_secs}s, flood ${measured_ms}ms\n"
  fi
}

# --- hooks/agent-boundary.sh: a command prefix the scan cannot follow (#505) ----------------------
# An env option that takes a value, or an assignment whose quoted or escaped value holds a space,
# leaves a bogus word in command position. The walk follows env's -u/--unset values, and a trigger
# (an assignment with unbalanced quotes, an env option outside the allowlist, a quote-bearing option
# or assignment after a prefix word) reads the rest of the segment once for an exact word git or gh,
# or a .claude path segment. A hit prints gh, the fixed sentinel "git -prefix-", or the .claude
# write line; no hit keeps the old walk. Every payload names git, gh, github or claude, or the
# raw-stdin fast path would pass it vacuously. abx_deny and abx_noop are defined above.
# mutant:505-ab-env-u-consume — makes the detached env -u value skip one token instead of two, so
#   the value stays a command word and the real command behind it is no longer read.
case_ab_lost_deny_env_u_gh() {
  abx_deny implementer gh 'env -u X gh pr merge 5' 'env --unset X gh pr merge 5'
}
case_ab_lost_deny_env_u_git() {
  abx_deny implementer 'git commit' 'env -u X git commit -m m'
}
# mutant:505-ab-env-u-value-check — drops the unbalanced-quote check on the detached env -u value,
#   so a value split at a space leaves its tail as the command word.
# mutant:505-ab-env-u-attached-quote — drops the same check on the attached -u token.
case_ab_lost_deny_env_u_quoted() {
  abx_deny implementer gh 'env -u "A B" gh pr merge 5' 'env -u"A B" gh pr merge 5'
}
# mutant:505-ab-env-opt-off — drops the fail-closed read for an env option outside the allowlist.
# mutant:505-ab-scan-reset — never resets the once-per-segment memo at a segment start, so a no-hit
#   scan in an earlier segment or line silences the scan of every later one. The multi-segment and
#   two-line commands below carry a no-hit trigger first.
case_ab_lost_deny_env_opt() {
  abx_deny implementer gh 'env -C /tmp gh pr merge 5' 'if [[ -n x ]] env -C /tmp gh pr merge 5' \
    'env -C /tmp ls; env -C /tmp gh pr merge 5' 'X="a b" ls && X="a b" gh pr merge 5' \
    $'env -C /tmp ls\nenv -C /tmp gh pr merge 5'
}
# mutant:505-ab-word-lead-off — drops the rule that reads an option with an attached value (-Sgh),
#   so a split string glued to its option is no exact word.
case_ab_lost_deny_env_split_string() {
  abx_deny implementer gh "env -S'gh pr merge 5'" 'env -S"X=1 gh pr merge 5"' "env --split-string='gh pr merge 5'"
}
# mutant:505-ab-word-unescape — stops reading the backslash-underscore separator as a space.
case_ab_lost_deny_env_split_string_escaped() {
  abx_deny implementer gh "env -S'gh\\_pr\\_merge\\_5'"
}
# mutant:505-ab-git-sentinel — makes the git hit print a read-only git subcommand instead of the
#   fixed sentinel, so the verifier no longer denies it and the implementer's blocked text changes.
# mutant:505-ab-word-lower — stops case-folding the scanned token, so an upper-case GIT or GH word
#   (which runs on a case-insensitive filesystem) is no exact word.
case_ab_lost_deny_env_split_string_git() {
  abx_deny implementer 'git -prefix-' "env -S'git commit -m m'" 'env -S"X=1 git commit -m m"' \
    'env -C /tmp GIT push'
}
# mutant:505-ab-unbalanced-off — never fires the assignment trigger.
# mutant:505-ab-unbalanced-dq — drops the odd double-quote arm of quote_unbalanced().
# mutant:505-ab-word-strip-sq — stops deleting single quotes from a scanned word, so g'h' is no gh.
# mutant:505-ab-word-strip-dq — stops deleting double quotes from a scanned word, so g"h" is no gh.
# mutant:505-ab-word-strip-bs — stops deleting backslashes from a scanned word, so g\h is no gh.
#   The quote-split commands end in a gh-notes comment word: it is no exact word, and only keeps the
#   raw-stdin fast path from passing the payload vacuously.
case_ab_lost_deny_assign_dquote() {
  abx_deny implementer gh 'X="a b" gh pr merge 5' 'env X="a b" gh pr merge 5' 'X="a b" GH pr merge 5' \
    "X=\"a b\" g'h' pr merge 5 # gh-notes" 'X="a b" g"h" pr merge 5 # gh-notes' \
    'X="a b" g\h pr merge 5 # gh-notes'
}
# mutant:505-ab-unbalanced-sq — drops the odd single-quote arm of quote_unbalanced().
case_ab_lost_deny_assign_squote() {
  abx_deny implementer gh "X='a b' gh pr merge 5" "X=\$'a b' gh pr merge 5"
}
# mutant:505-ab-unbalanced-bs — drops the trailing-backslash arm of quote_unbalanced().
case_ab_lost_deny_assign_backslash() {
  abx_deny implementer gh 'X=a\ b gh pr merge 5'
}
# mutant:505-ab-prefix-quoted-shape — never fires the trigger for a quote-bearing option or
#   assignment after a prefix word.
case_ab_lost_deny_prefix_quoted() {
  abx_deny implementer gh 'env "X=a b" gh pr merge 5' 'env "-Sgh pr merge 5"' 'bash -c "X=1 gh pr merge 5"'
}
# mutant:505-ab-quote-bearing-sq — drops the single-quote arm of quote_bearing().
# mutant:505-ab-strip-bs — stops deleting backslashes in strip_quotes(), so an escaped option still
#   starts with its backslash and the shape test of the prefix trigger no longer sees a dash.
# mutant:505-ab-quote-bearing-bs — drops the backslash arm of quote_bearing(), so an escaped option
#   (its first character is no dash) is no trigger.
case_ab_lost_deny_prefix_squoted_opt() {
  abx_deny implementer gh "env '-C' /tmp gh pr merge 5" 'env \-C /tmp gh pr merge 5'
}
case_ab_lost_deny_verifier_git() {
  abx_deny verifier 'git -prefix-' 'GIT_PAGER="less -R" git log' 'env -C /tmp git status' "env -S'git status'"
}
# mutant:505-ab-env-arm-prefix-guard — keeps a word whose basename is a prefix word (a directory
#   named env, a lone dash) out of the env option arm.
case_ab_lost_deny_verifier_env_arm_basename() {
  abx_deny verifier 'git -prefix-' 'env --chdir=../env git status' 'env - git status'
}
# mutant:505-ab-env-u-rx — drops the expansion flag for a detached env -u value.
# mutant:505-ab-env-u-attached-rx — drops the expansion flag for an attached env -u token.
case_ab_lost_deny_verifier_env_u_expansion() {
  abx_deny verifier 'git -expansion-' 'env -u $X git status' 'env -u$X git status'
}
# mutant:505-ab-claude-arm — drops the .claude path arm of the lost-prefix scan. The first two
#   commands deny through the scan (an assignment trigger, an env option trigger); the third through
#   the env -u value walk, which resolves tee as the command word for the ordinary .claude walk.
case_ab_lost_deny_claude() {
  abx_deny implementer '.claude/LESSONS.md' 'X="a b" tee -a .claude/LESSONS.md' \
    'env -C . tee -a .claude/LESSONS.md' 'env -u X tee -a .claude/LESSONS.md'
}
case_ab_lost_noop_env_u_consumes() {
  abx_noop implementer 'env -u gh pr merge 5' 'env --unset git status'
}
# mutant:505-ab-env-novalue-vocab — empties the allowlist of no-value env options.
# mutant:505-ab-env-u-attached — drops the attached -uNAME arm, so it reads as an unsupported option.
case_ab_lost_noop_verifier_env_allowlist() {
  abx_noop verifier 'env -i git status' 'env -uX git status' 'env --unset=X git status' \
    'git -C "../demo-wt-5" status --porcelain' 'git -C "../demo-wt-5" diff main...HEAD --stat'
}
# mutant:505-ab-env-context — tracks every prefix word as env, so an option of sudo reads as one.
case_ab_lost_noop_verifier_nonenv_opt() {
  abx_noop verifier 'sudo -E git status'
}
# mutant:505-ab-word-exact — matches git and gh as substrings instead of exact words.
# mutant:505-ab-scan-lead — applies the attached-value rule to every scanned token.
case_ab_lost_noop_scan_precision() {
  abx_noop implementer 'env -C /tmp cat gh-notes.md && echo ok' 'env -C /tmp ls -lgh && echo ok'
}
# mutant:505-ab-shape-gate — drops the option-or-assignment shape test of the prefix trigger.
case_ab_lost_noop_candidate_exempt() {
  abx_noop implementer $'cat > notes.md <<\'EOF\'\n- "Fix" the gh merge flow\nEOF'
}
# mutant:505-ab-word-ungated — makes every read report gh, so a trigger always denies.
case_ab_lost_noop_controls() {
  abx_noop implementer 'env -C /tmp ls && echo github' 'X="a b" ls && echo github' \
    'X="a b" tee -a notes.md && echo github' \
    'PATH=/bin:$PATH bash dev/selfcheck.sh && echo github' \
    $'cat > notes.md <<\'EOF\'\nDon\'t let gh merge it\nX="a b" is quoted\nEOF'
}
# ab_lost_flood_cmd N — three triggering lines of N tokens each (an unbalanced assignment, an env
# option outside the allowlist, a quoted option after a prefix word), then a line naming github so the
# raw-stdin fast path reads the payload. ab_lost_flood_twin_cmd N keeps the same layout and per-token
# byte length but only the FIRST token of each line is a trigger.
ab_lost_flood_cmd() {
  printf '%s true\nenv%s true\nnice%s true\necho github' \
    "$(printf ' X="a%.0s' $(seq 1 "$1"))" "$(printf ' -Z%.0s' $(seq 1 "$1"))" "$(printf ' "-x"%.0s' $(seq 1 "$1"))"
}
ab_lost_flood_twin_cmd() {
  local m=$(( $1 - 1 ))
  printf ' X="a%s true\nenv -Z%s true\nnice "-x"%s true\necho github' \
    "$(printf ' X=ab%.0s' $(seq 1 "$m"))" "$(printf ' -i%.0s' $(seq 1 "$m"))" "$(printf ' -xyz%.0s' $(seq 1 "$m"))"
}
# mutant:505-ab-scan-once — drops the once-per-segment memo, so every trigger rescans the rest of its
#   segment, the flood turns quadratic and overruns its calibrated deadline.
case_ab_lostscan_noop_flood() {
  # FLOOD + TIMING, sized and bounded by cost RATIO from a same-run control, never by absolute speed:
  # the twin (one trigger per record) is timed with no deadline, the flood's token count is scaled
  # from it, and the flood runs under an active deadline of K times the predicted linear cost. The
  # command reaches jq on stdin, never as a --arg.
  local ctl_n=1000 min_n=700 max_n=10000 floor=2 k=8
  local target_ms=$(( DL_KNOB_MAX * 200 )) ctl_ms pred_ms
  measure_ms run_boundary "$(ab_rx_payload "$(ab_lost_flood_twin_cmd "$ctl_n")")"
  ctl_ms="$measured_ms"
  if [ -z "$ctl_ms" ]; then
    __ok=0; __why="${__why}control run's own timing report could not be parsed — can't size the flood\n"
    return
  fi
  expect_no_opinion
  if [ "$__ok" -eq 0 ]; then
    __why="${__why}twin control did not return no opinion\n"
    return
  fi
  calibrated_flood_tokens "$ctl_ms" "$ctl_n" "$target_ms" "$min_n" "$max_n"
  pred_ms=$(( ctl_ms * flood_tokens / ctl_n ))
  calibrated_deadline "$floor" "$k" "$pred_ms"
  boundary_deadline_override="$calibrated_secs"
  measure_ms run_boundary "$(ab_rx_payload "$(ab_lost_flood_cmd "$flood_tokens")")"
  expect_no_opinion
  if [ "$__ok" -eq 0 ]; then
    __why="${__why}control ${ctl_ms}ms at ${ctl_n} -> ${flood_tokens} tokens, predicted ${pred_ms}ms -> deadline ${calibrated_secs}s, flood ${measured_ms}ms\n"
  fi
}

# ---------------------------------------------------------------------------------------------
# hooks/push-guard.sh (#260) fixture builders, runner, and assertions.

mk_push_cmd() { jq -n --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'; }
mk_push_cmd_cwd() { jq -n --arg cmd "$1" --arg cwd "$2" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}'; }
mk_push_cmd_mode() { jq -n --arg cmd "$1" --arg mode "$2" '{tool_name: "Bash", tool_input: {command: $cmd}, permission_mode: $mode}'; }
mk_push_tool() { jq -n --arg tool "$1" --arg cmd "$2" '{tool_name: $tool, tool_input: {command: $cmd}}'; }
# mk_push_missing_command — tool_input.command absent, but the raw JSON still contains both the
# literal 'push' and 'git' substrings (in an unrelated field) so this case actually reaches the
# "cmd empty" check instead of passing vacuously via the raw-stdin git fast path (LESSON
# 2026-08-26's analogue, mirroring mk_agent_missing_command above).
mk_push_missing_command() { jq -n --arg note 'was going to run git push origin main' '{tool_name: "Bash", tool_input: {}, note: $note}'; }

CR=$'\r'   # one literal carriage return — the #270 CRLF fixtures below (jq --arg escapes it into
           # the JSON as \r, so no raw CR byte ever passes through command substitution). Shared
           # by both the push-guard and agent-boundary CRLF cases below.

LF=$'\n'   # one literal line feed — the #327 round-1 kickback's embedded-LF claude-dir-guard.sh
           # fixtures below (jq --arg escapes it into the JSON as \n, so no raw LF byte ever passes
           # through command substitution).

DBTAB=$'\t'   # one literal tab — the #403 tab-bounded "]]" fixtures below (jq --arg escapes it into
              # the JSON as \t, so no raw tab byte ever passes through command substitution).

# mk_fixture_repo DIR DEFAULT_BRANCH CURRENT — builds an ordinary (non-worktree) .git directory
# under DIR: refs/remotes/origin/HEAD names DEFAULT_BRANCH; HEAD names CURRENT, unless CURRENT is
# "detached" (a raw 40-hex SHA, no symref — an unresolvable current branch) or "unreadable" (no
# HEAD file at all). Writes only under DIR, which every caller places under $tmpbase.
mk_fixture_repo() {
  local dir="$1" default_branch="$2" current="$3"
  mkdir -p "$dir/.git/refs/remotes/origin"
  printf 'ref: refs/remotes/origin/%s\n' "$default_branch" > "$dir/.git/refs/remotes/origin/HEAD"
  case "$current" in
    detached) printf '0123456789abcdef0123456789abcdef01234567\n' > "$dir/.git/HEAD" ;;
    unreadable) : ;;
    *) printf 'ref: refs/heads/%s\n' "$current" > "$dir/.git/HEAD" ;;
  esac
}

# mk_fixture_worktree MAINDIR WTDIR DEFAULT_BRANCH WT_BRANCH — builds a main checkout under
# MAINDIR (refs/remotes/origin/HEAD only) and a worktree pointer file at WTDIR/.git
# (gitdir: MAINDIR/.git/worktrees/wt1) whose own HEAD names WT_BRANCH — the same worktree-pointer
# shape hooks/git-c-guard.sh's own `-C <worktree>` forms navigate into.
mk_fixture_worktree() {
  local main="$1" wt="$2" default_branch="$3" wt_branch="$4"
  mkdir -p "$main/.git/refs/remotes/origin" "$main/.git/worktrees/wt1"
  printf 'ref: refs/remotes/origin/%s\n' "$default_branch" > "$main/.git/refs/remotes/origin/HEAD"
  mkdir -p "$wt"
  printf 'gitdir: %s/.git/worktrees/wt1\n' "$main" > "$wt/.git"
  printf 'ref: refs/heads/%s\n' "$wt_branch" > "$main/.git/worktrees/wt1/HEAD"
}

# mk_fixture_config DIR BODY (#268) — writes BODY (already newline-terminated by the caller's own
# heredoc/printf, or not, per case) to DIR/.git/config. DIR is the directory that HOLDS .git — for
# a worktree fixture that is the MAIN dir (mk_fixture_worktree's first argument), never the
# pointer dir, mirroring where hooks/push-guard.sh itself reads (the common dir, not the resolved
# gitdir). AMBIENT-$PWD RULE: every push fixture below that builds a config has n <= 1 non-option
# tokens (a bare `git push` or `git push <remote>`), because the push routes are consulted ONLY in
# that branch — and since #448 every non-push git segment is an alias candidate whose alias lookup
# reads config too (so a no-cwd fixture with a bare git log reads the developer's own checkout; a
# push-capable alias there named like a built-in would flip it, which is why the fixtures that matter
# pass a cwd) — so every one of them MUST pass an explicit cwd via mk_push_cmd_cwd, or push-guard.sh
# resolves the developer's own checkout and reads THAT machine's real .git/config (today, before
# this builder existed, no such flake was possible: every no-cwd push fixture in this file has
# n >= 2 — see this file's push mutation table header). Since #269, the SAME rule also binds any
# fixture whose command carries a predicate-matching (PATH_ERE-shaped) "-C" path: a relative one
# is joined to resolve_cwd (the session's own cwd, or $PWD with none passed), so a "-C ../<name>
# -wt-<n>" fixture with no explicit cwd resolves against the developer's own checkout's sibling
# directory, not a fixture the test built — every "-C"-carrying config fixture below passes an
# explicit cwd for this reason too. AMBIENT-$HOME ANALOGUE (#290): hooks/push-guard.sh now also
# reads $HOME/$XDG_CONFIG_HOME/$GIT_CONFIG_GLOBAL — run_push_guard below isolates all three for
# EVERY push fixture (a neutral, empty $HOME under $tmpbase by default), so no fixture in this
# file can ever read the developer's or CI runner's real global git config; a fixture that wants a
# GLOBAL route present sets $push_home_override/$push_xdg_home/$push_git_config_global immediately
# before calling run_push_guard instead (see mk_fixture_global_config below). AMBIENT-SYSTEM
# ANALOGUE (#304/#305): hooks/push-guard.sh now also reads $GIT_CONFIG_SYSTEM, three static
# system paths, and the Apple CLT path, all governed by $GIT_CONFIG_NOSYSTEM — run_push_guard
# below isolates all of this too (GIT_CONFIG_SYSTEM/GIT_CONFIG_NOSYSTEM unset, and the static
# paths prefixed with a neutral, empty sysroot under $tmpbase by default), so no fixture in this
# file can ever read the host's own real system git config; a fixture that wants a SYSTEM route
# present sets $push_sysroot_override/$push_git_config_system/$push_git_config_nosystem
# immediately before calling run_push_guard instead.
mk_fixture_config() {
  local dir="$1" body="$2"
  mkdir -p "$dir/.git"
  printf '%s' "$body" > "$dir/.git/config"
}

# mk_fixture_global_config PATH BODY (#290) — writes BODY to PATH, creating parent directories as
# needed, for a GLOBAL config candidate ($GIT_CONFIG_GLOBAL's own target, $HOME/.gitconfig, or
# $XDG_CONFIG_HOME/git/config) — the analogue of mk_fixture_config above for the global routes
# #290 added. Never writes anywhere but under PATH, which every caller places under $tmpbase.
mk_fixture_global_config() {
  local path="$1" body="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s' "$body" > "$path"
}

# push_guard_exec PATHVAL (#463) — the env block every run_push_guard call execs into: unsets
# XDG_CONFIG_HOME/GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM/GIT_CONFIG_NOSYSTEM/TBF_PUSH_GUARD_BUDGET_SECS
# (#290/#304/#305/#435), then exports HOME and TBF_PUSH_GUARD_SYSCONFIG_ROOT unconditionally and
# re-exports whichever of the five unset names a fixture asked for, reading run_push_guard's own
# home_val/sysroot_val locals — visible here under bash's own dynamic scoping of function locals (a
# function sees its caller's still-in-scope locals regardless of a subshell fork, never lexical
# scoping), never as a bare command substitution the harness's own shell could fall through to —
# then PATH=PATHVAL and `exec "$bash_bin" "$push_guard"`. MUST be called only inside an explicit
# "( … )": run in the harness's own shell it would leak every one of these exports and PATH, and its
# own `exec` would replace the harness process itself.
push_guard_exec() {
  local pathval="$1"
  unset XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM TBF_PUSH_GUARD_BUDGET_SECS
  export HOME="$home_val"
  export TBF_PUSH_GUARD_SYSCONFIG_ROOT="$sysroot_val"
  [ -z "$push_xdg_home" ] || export XDG_CONFIG_HOME="$push_xdg_home"
  [ -z "$push_git_config_global" ] || export GIT_CONFIG_GLOBAL="$push_git_config_global"
  [ -z "$push_git_config_system" ] || export GIT_CONFIG_SYSTEM="$push_git_config_system"
  [ -z "$push_git_config_nosystem" ] || export GIT_CONFIG_NOSYSTEM="$push_git_config_nosystem"
  [ -z "$push_budget_override" ] || export TBF_PUSH_GUARD_BUDGET_SECS="$push_budget_override"
  export PATH="$pathval"
  exec "$bash_bin" "$push_guard"
}

# run_push_guard JSON [PATHVAL] — runs the real push-guard script against JSON on stdin, with
# PATH set to PATHVAL (defaults to this process's own PATH), leaving $push_out (stdout)/
# $push_err (stderr, read back from a file under $tmpbase)/$push_rc set as globals. Same "call as
# a plain statement, read the globals after" idiom as run_boundary above.
#
# #290/#304/#305: hooks/push-guard.sh now reads $HOME/$XDG_CONFIG_HOME/$GIT_CONFIG_GLOBAL and
# $GIT_CONFIG_SYSTEM/$GIT_CONFIG_NOSYSTEM/three static system paths/the Apple CLT path, so this
# runner ISOLATES all of it for EVERY call: a neutral, empty fixture HOME under $tmpbase by
# default (never the developer's or CI runner's real one), with XDG_CONFIG_HOME, GIT_CONFIG_GLOBAL,
# GIT_CONFIG_SYSTEM and GIT_CONFIG_NOSYSTEM unset unless a fixture sets
# $push_home_override/$push_xdg_home/$push_git_config_global/$push_git_config_system/
# $push_git_config_nosystem immediately before calling run_push_guard, and
# TBF_PUSH_GUARD_SYSCONFIG_ROOT exported to a neutral, empty per-run sysroot under $tmpbase unless
# a fixture sets $push_sysroot_override (every one of these six cleared again right after the
# call, so a later fixture that asks for none of them never inherits a prior fixture's values).
# $push_home_empty (#304/#305) is a SEVENTH override: set to "1", it exports HOME as the
# empty string for that one call instead of the neutral fixture HOME — the only way to fixture the
# "~/… with HOME empty" residual, since $push_home_override always names a real directory.
# $push_budget_override (#435) is an EIGHTH override: hooks/push-guard.sh's own
# TBF_PUSH_GUARD_BUDGET_SECS knob is unset for every call by default (so no fixture accidentally
# inherits a lowered analysis budget from an earlier one), and exported only when a fixture sets
# this global immediately before calling run_push_guard. $push_deadline_override (#463) is a NINTH
# override: unset by default (the foreground path below, unchanged in shape from before), and when a
# case sets it immediately before calling run_push_guard, push_guard_exec instead runs backgrounded
# under wait_deadline at that many seconds, killing its whole process tree on overrun instead of
# letting the case block on it. Every one of these nine is cleared again right after the call. The
# environment mutation always happens inside an explicit "( push_guard_exec … )" subshell — a
# portable, bash-3.2/Git-Bash-safe idiom (this file's own convention prefers it to `env -u`, which is
# not obviously safe across Git-Bash) — so it can never leak into this harness's own environment or
# any later call. run_hook above is deliberately UNCHANGED: hooks/git-c-guard.sh reads none of these
# variables.
push_out=""
push_err=""
push_rc=0
push_home_override=""
push_xdg_home=""
push_git_config_global=""
push_sysroot_override=""
push_git_config_system=""
push_git_config_nosystem=""
push_home_empty=""
push_budget_override=""
push_deadline_override=""
run_push_guard() {
  local json="$1" pathval="${2:-$PATH}" errfile="$tmpbase/push-guard-stderr"
  local home_val="${push_home_override:-$neutral_home}"
  local sysroot_val="${push_sysroot_override:-$neutral_sysroot}"
  [ "$push_home_empty" != "1" ] || home_val=""
  if [ -n "$push_deadline_override" ]; then
    local stdin_file="$tmpbase/push-guard-stdin" out_file="$tmpbase/push-guard-out" pgpid
    printf '%s' "$json" > "$stdin_file"
    ( push_guard_exec "$pathval" ) < "$stdin_file" > "$out_file" 2> "$errfile" &
    pgpid=$!
    wait_deadline "$pgpid" "$push_deadline_override"
    push_rc=$deadline_rc
    push_out="$(cat "$out_file" 2>/dev/null)"
    rm -f "$out_file" "$stdin_file"
  else
    push_out="$( printf '%s' "$json" | ( push_guard_exec "$pathval" ) 2>"$errfile" )"
    push_rc=$?
  fi
  push_err="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
  push_home_override=""
  push_xdg_home=""
  push_git_config_global=""
  push_sysroot_override=""
  push_git_config_system=""
  push_git_config_nosystem=""
  push_home_empty=""
  push_budget_override=""
  push_deadline_override=""
}

# expect_push_deny/expect_push_no_opinion — assert against $push_out/$push_err/$push_rc.
# PUSH_DENY_STEM's literal text is hand-typed here (not extracted from the script), the same
# convention expect_deny above uses for agent-boundary.sh's DENY_STEM.
expect_push_deny() {
  [ "$push_rc" -eq 2 ] || { __ok=0; __why="${__why}rc: expected 2, got $push_rc\n"; }
  [ -z "$push_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$push_out'\n"; }
  local err_lines
  err_lines="$(printf '%s\n' "$push_err" | grep -c '[^[:space:]]')"
  [ "$err_lines" -eq 1 ] || { __ok=0; __why="${__why}expected exactly 1 non-blank stderr line, got $err_lines: '$push_err'\n"; }
  case "$push_err" in
    *"trail-blazer-flow push guard:"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain the PUSH_DENY_STEM literal 'trail-blazer-flow push guard:': '$push_err'\n" ;;
  esac
}
expect_push_no_opinion() {
  [ "$push_rc" -eq 0 ] || { __ok=0; __why="${__why}rc: expected 0, got $push_rc\n"; }
  [ -z "$push_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$push_out'\n"; }
  [ -z "$push_err" ] || { __ok=0; __why="${__why}expected empty stderr, got: '$push_err'\n"; }
}

# mk_push_cmd_big CMD CWD (#435) — like mk_push_cmd_cwd, but CMD reaches jq on stdin (never a
# --arg): the flood payloads the push-dl-* cases below build can exceed the per-argument exec limit
# an --arg would hit (see case_ab_pc_deny_dbracket_timing above for the identical reasoning and the
# Linux limit it names). Only the short CWD goes as a jq --arg.
mk_push_cmd_big() {
  printf '%s' "$1" | jq -Rs --arg cwd "$2" '{tool_name: "Bash", tool_input: {command: .}, cwd: $cwd}'
}

# expect_push_deny_exact LINE (#435) — expect_push_deny, plus an exact-string assertion against the
# WHOLE stderr line (never a substring), for the two hand-typed #435 deny texts
# (DL_DEADLINE_LINE/DL_CONFIGLINE_LINE below), where the whole line is the contract, not just a
# fragment of it. Refuses an empty LINE outright (CLAUDE.md's empty-needle convention): an empty
# LINE here would only "match" a push-guard.sh that denied with a genuinely empty stderr line, which
# is itself a bug expect_push_deny above already treats as a failure — accepting an empty LINE here
# would silently turn that same bug into a false pass instead.
expect_push_deny_exact() {
  local want="$1"
  if [ -z "$want" ]; then
    __ok=0; __why="${__why}expect_push_deny_exact called with an empty LINE (needle_required)\n"
    return
  fi
  expect_push_deny
  [ "$push_err" = "$want" ] || { __ok=0; __why="${__why}stderr: expected exactly '$want', got '$push_err'\n"; }
}

# DL_DEADLINE_LINE/DL_CONFIGLINE_LINE (#435) — the two fixed deny lines hooks/push-guard.sh's
# deny_too_large() prints, hand-typed here exactly as in that function (the same convention
# PUSH_DENY_STEM's literal text above already uses), so a drift between the two is a visible test
# diff, never a silent pass.
DL_DEADLINE_LINE="trail-blazer-flow push guard: denies this command: too large to analyse before the hook's time limit (blocked: command too large to analyse) — split it into smaller Bash calls; see README.md's Safety model"
DL_CONFIGLINE_LINE="trail-blazer-flow push guard: denies this push: a git config file it reads has a line too long to analyse (blocked: config line too long to analyse) — shorten that line, or run the push from a terminal; see README.md's Safety model"

# DL_TOPLEVEL_MAX_LINE_CHARS (#435) — the same hand-typed-literal convention as the two lines
# above, mirroring hooks/push-guard.sh's own CFG_TOPLEVEL_MAX_LINE_CHARS value, for the two
# push-dl-deny-toplevel-{over,at}-cap boundary fixtures below.
DL_TOPLEVEL_MAX_LINE_CHARS=2048

# DL_KNOB_MAX (#476) — the largest analysis-budget knob hooks/push-guard.sh adopts: the knob is
# honoured only when strictly less than its PUSH_ANALYSIS_BUDGET_SECS (5), hand-typed here as that
# value minus one, the same mirror convention as the constant above.
DL_KNOB_MAX=4

# dl_site_run PAYLOAD (#476) — runs one site-proving push-dl payload twice. First a control: the
# identical payload at knob 0, which denies at the hook's very first deadline sample (right after
# the tokenizer), so its measured wall time is exactly the unsampled prefix (process start, cat, jq,
# the awk tokenizer) that races the deadline in the timed run. No site mutant touches anything up
# to that first sample, so the control is invariant under each of them; wait_deadline's 0.1s polling
# can only over-measure it, which moves the budget in the safe direction. Then the timed run, at the
# budget calibrated_site_budget derives from that measurement. A control that cannot be timed, or
# that does not deny with the deadline reason, fails the case and returns without the timed run,
# which keeps the check-off mutant (no deadline deny at all) bounded.
dl_site_run() {
  local payload="$1"
  push_budget_override="0"
  push_deadline_override=9
  measure_ms run_push_guard "$payload"
  if [ -z "$measured_ms" ]; then
    __ok=0; __why="${__why}knob-0 control's timing report could not be parsed -- can't calibrate a budget\n"
    return
  fi
  expect_push_deny_exact "$DL_DEADLINE_LINE"
  if [ "$__ok" -eq 0 ]; then
    __why="${__why}knob-0 control did not deny at the first sample\n"
    return
  fi
  calibrated_site_budget "$measured_ms" "$DL_KNOB_MAX"
  push_budget_override="$site_budget_secs"
  push_deadline_override=9
  run_push_guard "$payload"
  expect_push_deny_exact "$DL_DEADLINE_LINE"
  if [ "$__ok" -eq 0 ]; then
    __why="${__why}control ${measured_ms}ms -> budget ${site_budget_secs}s\n"
  fi
}

# --- deny: plain command and refspec-parsing clauses, derived from the parser's boundaries
# (LESSON 2026-09-04), not from happy paths -------------------------------------------------------
case_pd_origin_main()       { run_push_guard "$(mk_push_cmd 'git push origin main')"; expect_push_deny; }
case_pd_head_colon_main()   { run_push_guard "$(mk_push_cmd 'git push origin HEAD:main')"; expect_push_deny; }
case_pd_plus_head_refs()    { run_push_guard "$(mk_push_cmd 'git push origin +HEAD:refs/heads/main')"; expect_push_deny; }
case_pd_nonorigin_remote()  { run_push_guard "$(mk_push_cmd 'git push upstream HEAD:main')"; expect_push_deny; }
case_pd_url_remote_colon()  { run_push_guard "$(mk_push_cmd 'git push git@github.com:o/r.git HEAD:main')"; expect_push_deny; }
case_pd_refspec_full()      { run_push_guard "$(mk_push_cmd 'git push origin refs/heads/x:refs/heads/main')"; expect_push_deny; }
case_pd_colon_main()        { run_push_guard "$(mk_push_cmd 'git push origin :main')"; expect_push_deny; }
case_pd_plus_main_no_colon() {
  # Isolates the leading-'+' strip from the colon-split: a colon-BEARING token like
  # "+HEAD:refs/heads/main" still resolves correctly even without stripping '+' first, because
  # the colon-split alone discards everything before and including the first ':'. Only a
  # colon-LESS forced refspec like "+main" needs the strip on its own.
  run_push_guard "$(mk_push_cmd 'git push origin +main')"
  expect_push_deny
}
case_pd_delete_main()       { run_push_guard "$(mk_push_cmd 'git push origin --delete main')"; expect_push_deny; }
case_pd_opt_before_remote() { run_push_guard "$(mk_push_cmd 'git push --force origin main')"; expect_push_deny; }
case_pd_opt_after_refspec() { run_push_guard "$(mk_push_cmd 'git push origin main --force')"; expect_push_deny; }
case_pd_o_one()              { run_push_guard "$(mk_push_cmd 'git push -o ci.skip origin main')"; expect_push_deny; }
case_pd_o_two()              { run_push_guard "$(mk_push_cmd 'git push -o a -o b origin main')"; expect_push_deny; }
case_pd_all()                { run_push_guard "$(mk_push_cmd 'git push --all origin')"; expect_push_deny; }
case_pd_mirror()             { run_push_guard "$(mk_push_cmd 'git push --mirror origin')"; expect_push_deny; }
case_pd_c_worktree()         { run_push_guard "$(mk_push_cmd 'git -C ../demo-wt-1 push origin main')"; expect_push_deny; }
case_pd_composite_and()      { run_push_guard "$(mk_push_cmd 'pytest && git push origin main')"; expect_push_deny; }
case_pd_prefix_one()         { run_push_guard "$(mk_push_cmd 'env git push origin main')"; expect_push_deny; }
case_pd_prefix_two() {
  # TWO chained PREFIX_WORDS tokens (sudo, then bash) — the M23-class regression
  # hooks/agent-boundary.sh's own fixtures pin for its twin tokenizer; push-guard.sh's scan must
  # not regress the same way (0/1/2+ occurrences of a skipped class — LESSON 2026-09-08d).
  run_push_guard "$(mk_push_cmd 'sudo bash -c "git push origin main"')"
  expect_push_deny
}
case_pd_assignment()         { run_push_guard "$(mk_push_cmd 'FOO=1 git push origin main')"; expect_push_deny; }
case_pd_abs_path()           { run_push_guard "$(mk_push_cmd '/usr/bin/git push origin main')"; expect_push_deny; }
case_pd_global_opt_value()   { run_push_guard "$(mk_push_cmd 'git -c core.pager=cat push origin main')"; expect_push_deny; }
case_pd_global_opt_two() {
  # TWO chained GIT_GLOBAL_OPTS_WITH_VALUE tokens (-c <value>, then -C <value>) before the
  # subcommand — the 0/1/2+ boundary LESSON 2026-09-08(d) asks for on this skipped class too.
  run_push_guard "$(mk_push_cmd 'git -c core.pager=cat -C ../demo-wt-1 push origin main')"
  expect_push_deny
}
case_pd_origin_master()      { run_push_guard "$(mk_push_cmd 'git push origin master')"; expect_push_deny; }
case_pd_n1_refspec() {
  # A single non-option argument after "push" is evaluated BOTH as the current branch AND,
  # defensively, as a refspec destination in its own right (a remote literally named "main" is
  # treated as if it might be a branch — see the hook's own header). Isolates that second
  # evaluation from the first with an explicit fixture repo whose CURRENT branch is feature/x (a
  # real, resolvable, non-deny-set value, not an ambient/unresolvable one) — only the
  # refspec-as-destination check on "main" itself can explain this deny.
  local dir="$tmpbase/repo-n1-refspec"
  mk_fixture_repo "$dir" main feature/x
  run_push_guard "$(mk_push_cmd_cwd 'git push main' "$dir")"
  expect_push_deny
}
case_pd_crlf_dest() {
  # #270: the exact command the issue measured. Isolates the destination compare, which goes
  # through strip_quotes() + is_deny_member (NOT normalize() — push destinations never pass
  # through it, see the hook's own header). Raw stdin carries the required fast-path substring
  # ("git") ahead of the escaped \r, so this reaches the tokenizer.
  run_push_guard "$(mk_push_cmd "git push origin main${CR}")"
  expect_push_deny
}
case_pd_crlf_interior() {
  # #270 round-2 kickback: three CRs, with the verdict-bearing one (the second) NEITHER the
  # command's first NOR its final byte — the original two-CR fixture's verdict-bearing CR was
  # its FIRST, so a once-only ("strip the first \r found") mutant happened to strip it too and
  # survived the whole suite undetected; this shape kills both a trailing-only strip (the first
  # two CRs, including the verdict-bearing one, are untouched) AND a once-only strip (the
  # verdict-bearing CR is the SECOND, not the one a once-only strip removes) — see M23/M24/M25
  # below. Raw stdin carries the fast-path substring ("git") intact after the first
  # escaped \r — the fast path is a whole-string substring test, so position is irrelevant here
  # (unlike case_pd_crlf_cmdword, where the "g","i","t" run must survive ahead of the escape).
  run_push_guard "$(mk_push_cmd "echo a${CR} && git push origin main${CR} && echo b${CR}")"
  expect_push_deny
}
case_pd_crlf_cmdword() {
  # #270: isolates normalize() on the command word — the site the issue's filed shape ("strip in
  # both tokenizers' normalize()") names, and which alone is insufficient to fix the issue's own
  # measured case (see case_pd_crlf_dest). Raw stdin carries "push" (unescaped, later in the
  # string) and the three literal characters "g","i","t" before the escaped \r, satisfying both
  # fast paths.
  run_push_guard "$(mk_push_cmd "git${CR} push origin main")"
  expect_push_deny
}
case_pn_crlf_feature() {
  # #270: the strip must not widen the deny set — exact match is still required against a
  # non-default destination. Raw stdin carries the fast-path substring.
  run_push_guard "$(mk_push_cmd "git push origin feature/x${CR}")"
  expect_push_no_opinion
}

# --- deny: default-branch symref resolution against fixture repos --------------------------------
case_pd_trunk_base() {
  local dir="$tmpbase/repo-trunk-base"
  mk_fixture_repo "$dir" trunk main
  run_push_guard "$(mk_push_cmd_cwd 'git push origin trunk' "$dir")"
  expect_push_deny
}
case_pd_trunk_subdir() {
  local dir="$tmpbase/repo-trunk-subdir"
  mk_fixture_repo "$dir" trunk main
  mkdir -p "$dir/sub"
  run_push_guard "$(mk_push_cmd_cwd 'git push origin trunk' "$dir/sub")"
  expect_push_deny
}
case_pd_trunk_worktree() {
  local main="$tmpbase/repo-trunk-wt-main" wt="$tmpbase/repo-trunk-wt-pointer"
  mk_fixture_worktree "$main" "$wt" trunk "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'git push origin trunk' "$wt")"
  expect_push_deny
}
case_pd_head_on_main() {
  local dir="$tmpbase/repo-head-main"
  mk_fixture_repo "$dir" main main
  run_push_guard "$(mk_push_cmd_cwd 'git push origin HEAD' "$dir")"
  expect_push_deny
}
case_pd_bare_on_main() {
  local dir="$tmpbase/repo-bare-main"
  mk_fixture_repo "$dir" main main
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_no_cwd_fallback() {
  # No 'cwd' key at all in stdin (mk_push_cmd emits none): must still deny via the unconditional
  # PUSH_DEFAULT_BRANCH_FALLBACK, regardless of what $PWD resolves to.
  run_push_guard "$(mk_push_cmd 'git push origin main')"
  expect_push_deny
}

# --- no opinion: the shapes this harness itself issues, and every other non-default destination --
case_pn_push_upstream_claude()   { run_push_guard "$(mk_push_cmd 'git push -u origin "claude/17-a"')"; expect_push_no_opinion; }
case_pn_c_push_upstream_claude() { run_push_guard "$(mk_push_cmd 'git -C ../demo-wt-1 push -u origin "claude/17-a"')"; expect_push_no_opinion; }
case_pn_release_branch()         { run_push_guard "$(mk_push_cmd 'git push origin release/v2.7.1')"; expect_push_no_opinion; }
case_pn_tag_shaped_version()     { run_push_guard "$(mk_push_cmd 'git push origin v2.7.0')"; expect_push_no_opinion; }
case_pn_feature_branch()         { run_push_guard "$(mk_push_cmd 'git push origin feature/x')"; expect_push_no_opinion; }
case_pn_main_ish() {
  # Exact-match, not prefix — mirroring the "mainline" concern bin/check-harness.sh:585 documents
  # for its own default-branch literal.
  run_push_guard "$(mk_push_cmd 'git push origin main-ish')"
  expect_push_no_opinion
}
case_pn_refs_tags() { run_push_guard "$(mk_push_cmd 'git push origin refs/tags/v1.0')"; expect_push_no_opinion; }
case_pn_head_on_claude() {
  local dir="$tmpbase/repo-head-claude"
  mk_fixture_repo "$dir" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'git push origin HEAD' "$dir")"
  expect_push_no_opinion
}
case_pn_bare_on_claude() {
  local dir="$tmpbase/repo-bare-claude"
  mk_fixture_repo "$dir" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_bare_detached() {
  local dir="$tmpbase/repo-detached"
  mk_fixture_repo "$dir" main detached
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_trunk_no_repo() {
  local dir="$tmpbase/norepo"
  mkdir -p "$dir"
  run_push_guard "$(mk_push_cmd_cwd 'git push origin trunk' "$dir")"
  expect_push_no_opinion
}
case_pn_grep_arg() {
  # Control proving the command-position rule: 'git'/'push' appear only inside grep's own
  # argument, never as a command word/subcommand.
  run_push_guard "$(mk_push_cmd 'grep -rn "git push origin main" .')"
  expect_push_no_opinion
}
case_pn_bash_script() {
  # Control proving exact-match, not substring-match: the command word after the "bash" prefix
  # skip is "hooks/push-guard.sh" (basename "push-guard.sh"), which CONTAINS "push" but is not
  # "git". The trailing shell comment supplies a literal "git" token so the raw stdin JSON
  # contains "git" (LESSON — a fixture whose raw JSON is missing that literal exits at the raw-stdin
  # fast path above and never reaches the tokenizer, which would make this case's own claim about
  # normalize()'s basename step vacuous); the comment
  # text itself is never reached by emit_segment, since cmdword already resolves (to
  # "push-guard.sh") from the tokens before it.
  run_push_guard "$(mk_push_cmd 'bash hooks/push-guard.sh # not a git push')"
  expect_push_no_opinion
}
case_pn_o_value_two_token_remote() {
  # Isolates PUSH_OPTS_WITH_VALUE's pair semantics: "-o v" must be skipped as EXACTLY two tokens,
  # so "main" lands at position 0 of the remaining tokens — the remote, per step 8, which is
  # NEVER itself evaluated as a destination (it may be a URL containing a colon) — leaving only
  # "other" evaluated, which isn't a deny-set member. A skip that consumed only one token would
  # instead treat "v" as the remote and evaluate BOTH "main" and "other" as candidate refspecs,
  # wrongly denying on "main".
  run_push_guard "$(mk_push_cmd 'git push -o v main other')"
  expect_push_no_opinion
}

# --- #269: "-C <path>" resolution, only when the path satisfies the shared PATH_ERE predicate --
# Every fixture below passes an explicit cwd (mk_fixture_config's AMBIENT-$PWD rule, extended by
# #269, applies here too: a relative "-C" value would otherwise resolve against the developer's
# own $PWD). "…-wt-<n>" directory names are the predicate-matching shape; a bare "…-wt-<n>" with
# no cwd anywhere in this file (e.g. the pre-existing push-deny-c-worktree/push-noop-c-upstream-
# claude/push-deny-global-opt-two fixtures' "../demo-wt-1") never exists on disk beside this
# script's own checkout, so those three pre-existing fixtures degrade under #269 exactly as they
# did before it (see this file's header for the ambient-$PWD flake class this predicate widens).
case_pd_c_sibling_wt_bare_on_default() {
  # A1: session default develop, HEAD claude/17-a; sibling worktree ALSO on develop; a bare push
  # in the worktree. Isolates the n<=1 current-branch check (evaluate_segment's own check, not a
  # refspec) on the RESOLVED checkout's current branch. Measured pre-#269 (main's script, before
  # this issue): no opinion (rc 0) -- the "-C" value was never read at all, so the segment was
  # judged only against the SESSION's own current branch, claude/17-a, which is not a deny member.
  local main="$tmpbase/repo-c-a1" wt="$tmpbase/repo-c-a1-wt-1"
  mk_fixture_worktree "$main" "$wt" develop develop
  printf 'ref: refs/heads/claude/17-a\n' > "$main/.git/HEAD"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../repo-c-a1-wt-1 push' "$main")"
  expect_push_deny
}
case_pd_c_other_repo_explicit_develop() {
  # A2: the issue's own headline shape. Session default main/HEAD claude/17-a; a SEPARATE repo
  # (not a worktree of the session) whose own default is develop; an explicit refspec destination.
  # Measured pre-#269 (main's script): no opinion (rc 0) -- the "-C" value was never read, so
  # "develop" was judged only against the session's own deny set (fallback ∪ main), of which it
  # is not a member.
  local main="$tmpbase/repo-c-a2" other="$tmpbase/other-checkout-wt-1"
  mk_fixture_repo "$main" main "claude/17-a"
  mk_fixture_repo "$other" develop "feature/x"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../other-checkout-wt-1 push origin develop' "$main")"
  expect_push_deny
}
case_pd_c_sibling_wt_head_refspec() {
  # A3: as A1, but the refspec is "HEAD" rather than a bare push -- isolates refspec_dest()'s HEAD
  # substitution (n==1, evaluated as an explicit refspec) from A1's separate n<=1 current-branch
  # check. Measured pre-#269 (main's script): no opinion (rc 0) -- same reason as A1 (the "-C"
  # value was never read, so "HEAD" resolved against the SESSION's own current branch,
  # claude/17-a, not a deny member).
  local main="$tmpbase/repo-c-a3" wt="$tmpbase/repo-c-a3-wt-1"
  mk_fixture_worktree "$main" "$wt" develop develop
  printf 'ref: refs/heads/claude/17-a\n' > "$main/.git/HEAD"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../repo-c-a3-wt-1 push origin HEAD' "$main")"
  expect_push_deny
}
case_pd_c_other_repo_config_route() {
  # A4: target (absolute-path "-C" form, covering the "/*" join branch) has a config denying via
  # remote.origin.push=HEAD:main; the SESSION has no config at all -- isolates the resolved
  # checkout's own config being applied, not the session's (which has none to fall back on).
  # Measured pre-#269 (main's script): no opinion (rc 0) -- the "-C" value was never read, so the
  # target's config was never consulted at all. This is the one fixture in this suite using the
  # absolute-path join branch ("$target" is already `$tmpbase/target-wt-1`, an absolute path) --
  # if $TMPDIR itself ever contained a character outside PATH_ERE's class, is_c_target_path would
  # reject the whole absolute path and the segment would deny as UNRESOLVED instead (a
  # non-session-equivalent absolute path) -- expect_push_deny alone could not tell that apart from
  # this fixture's OWN intended deny route; the inline assertion below (stderr contains "via
  # remote.origin.push") is what catches that silently-wrong-reason case, FAILING LOUDLY instead of
  # passing vacuously.
  local main="$tmpbase/repo-c-a4" target="$tmpbase/target-wt-1"
  mk_fixture_repo "$main" develop "claude/17-a"
  mk_fixture_repo "$target" main "feature/x"
  mk_fixture_config "$target" $'[remote "origin"]\n\tpush = HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd "git -C $target push" "$main")"
  expect_push_deny
  case "$push_err" in
    *"via remote.origin.push"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'via remote.origin.push': '$push_err'\n" ;;
  esac
}
case_pn_c_other_repo_ignores_session_config() {
  # A5 (documented narrowing): the SESSION's own config would deny (push=HEAD:main, HEAD
  # feature/x), but the resolved segment must ignore it -- the target has its OWN default (trunk)
  # and no config of its own. Measured pre-#269: deny (rc 2, via the session's remote.origin.push
  # route) -- this fixture's whole point is that #269 removes that inherited deny.
  local main="$tmpbase/repo-c-a5" target="$tmpbase/target-a5-wt-1"
  mk_fixture_repo "$main" main "feature/x"
  mk_fixture_config "$main" $'[remote "origin"]\n\tpush = HEAD:main\n'
  mk_fixture_repo "$target" trunk "feature/y"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../target-a5-wt-1 push' "$main")"
  expect_push_no_opinion
}
case_pd_c_unresolvable_degrades() {
  # B4: the "-C" value matches PATH_ERE's shape but nothing exists there -- resolve_repo("…", 1)
  # never finds a gitdir, so the segment must DEGRADE to exactly the session's own facts, not
  # clear them (M52's own discriminator). A BARE push, with the session's own HEAD ON its own
  # default branch (develop) -- not an explicit refspec, which never reads current_branch at all
  # and so cannot tell "degrade" from "clear" apart: current_branch is exactly what a "clear"
  # (leaving it blank after the failed resolve_repo() call) would silently drop.
  local main="$tmpbase/repo-c-b4"
  mk_fixture_repo "$main" develop develop
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../missing-wt-9 push' "$main")"
  expect_push_deny
}
case_pn_c_sibling_wt_session_on_default() {
  # B5 (documented narrowing): worktree-parallel mode's REAL shape -- the session checkout itself
  # sits on its own default branch (main) while a sibling worktree sits on claude/17-a; a bare
  # push in that worktree. Measured pre-#269: deny (rc 2, via the SESSION's current branch, which
  # happens to equal its own default) -- this is the false-positive #269 is meant to remove.
  local main="$tmpbase/repo-c-b5" wt="$tmpbase/repo-c-b5-wt-1"
  mk_fixture_worktree "$main" "$wt" main "claude/17-a"
  printf 'ref: refs/heads/main\n' > "$main/.git/HEAD"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../repo-c-b5-wt-1 push' "$main")"
  expect_push_no_opinion
}
case_pd_c_session_default_union() {
  # B6: the RESOLVED (2) union clause's own discriminator. Session default develop; target's OWN
  # default is trunk (and no config); explicit refspec destination "develop". Measured pre-#269:
  # this ALREADY denies (rc 2) via the session's own deny set alone (develop is the session's
  # default, and #269's tokenizer/driver changes do not touch the plain refspec-parsing path a
  # segment with no resolvable "-C" already had) -- so this fixture's value is as the M53
  # discriminator (below), not as a Today-vs-After widening: under M53 (the union narrowed to
  # fallback ∪ resolved only), "develop" drops out of the deny set and this flips to no opinion.
  local main="$tmpbase/repo-c-b6" target="$tmpbase/target-b6-wt-1"
  mk_fixture_repo "$main" develop "feature/z"
  mk_fixture_repo "$target" trunk "feature/x"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../target-b6-wt-1 push origin develop' "$main")"
  expect_push_deny
}
case_pd_c_never_executes() {
  # C1: the safety property on the NEW "-C" resolution route specifically -- A2's shape, run with
  # the booby-trapped git/gh/rm/dirname PATH, asserting deny AND byte-identical file listings of
  # BOTH the session repo and the resolved "-C" target (never just the session repo, which the
  # pre-existing push-never-executes-* cases already cover). "dirname" was added to the trap set
  # in the #269 round-2 kickback (finding: the depth-1 ascent guard at resolve_repo()'s
  # `[ "$((depth + 1))" -lt "$2" ] || break` line was otherwise unpinned) -- measured: this
  # fixture's own "-C" target resolves a gitdir at depth 0 (mk_fixture_repo writes .git directly
  # at other-c1-wt-1), so dirname is never reached here regardless of that guard, in EITHER the
  # shipped script or under the guard-deleted mutant (both measured: sentinel absent, rc 2); the
  # dirname trap is harmless here, and the guard itself is pinned by push-deny-c-unresolvable-
  # never-executes (C2) below instead, whose "-C" target does NOT resolve at depth 0. This hook
  # otherwise legitimately spawns jq/awk/grep (and dirname when a SESSION checkout resolution
  # requires upward ascent -- not exercised by this fixture's own cwd, which already has ".git").
  # Measured pre-#269 (main's script): no opinion (rc 0) -- the "-C" route (and so this whole
  # safety property on it) did not exist yet; the pre-#269 script never read the "-C" value at
  # all, so it could not have executed anything derived from it either.
  local main="$tmpbase/repo-c-c1" other="$tmpbase/other-c1-wt-1"
  mk_fixture_repo "$main" main "claude/17-a"
  mk_fixture_repo "$other" develop "feature/x"
  local trapdir="$tmpbase/trapbin-c-c1" sentinel="$tmpbase/sentinel-c-c1"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before_main after_main before_other after_other
  before_main="$(find "$main" -type f -exec ls -la {} \; | sort)"
  before_other="$(find "$other" -type f -exec ls -la {} \; | sort)"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../other-c1-wt-1 push origin develop' "$main")" "$trapdir:$PATH"
  after_main="$(find "$main" -type f -exec ls -la {} \; | sort)"
  after_other="$(find "$other" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH while resolving a -C target\n"; }
  [ "$before_main" = "$after_main" ] || { __ok=0; __why="${__why}session repo's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
  [ "$before_other" = "$after_other" ] || { __ok=0; __why="${__why}resolved -C target's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
}
case_pd_c_unresolvable_never_executes() {
  # C2 (#269 round-2 kickback): pins resolve_repo()'s depth-1 ascent guard specifically -- unlike
  # C1 (whose "-C" target resolves a gitdir at depth 0 and so never reaches the ascent code at
  # all, measured), this fixture's "-C" target does NOT exist on disk (B4's own shape), so
  # resolve_repo() falls through both "[ -d ... ]"/"[ -f ... ]" checks to the ascent guard itself.
  # Booby-traps git/gh/rm/dirname; measured: shipped script -- sentinel absent, rc 2 (degrades to
  # the session's own facts, exactly as B4). With the guard deleted (M57 below), dirname IS
  # invoked (sentinel present) even though the verdict itself (rc 2) is unaffected -- the
  # resolve-then-degrade path still lands on the session's facts either way, so this fixture pins
  # the SAFETY property (never executes/never reaches an argv), not the verdict, the same
  # division of labor B4 (verdict) and C1 (safety, on the resolving route) already have.
  local main="$tmpbase/repo-c-c2"
  mk_fixture_repo "$main" develop develop
  local trapdir="$tmpbase/trapbin-c-c2" sentinel="$tmpbase/sentinel-c-c2"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before_main after_main
  before_main="$(find "$main" -type f -exec ls -la {} \; | sort)"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../missing-c2-wt-9 push' "$main")" "$trapdir:$PATH"
  after_main="$(find "$main" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH (dirname, on the unresolvable -C ascent path) while resolving a -C target\n"; }
  [ "$before_main" = "$after_main" ] || { __ok=0; __why="${__why}session repo's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
}
case_pd_c_per_segment_session_reset() {
  # D1 (#269 round-2 kickback finding): acceptance criterion 4 ("per push segment ... no leakage
  # between iterations") had NO fixture with more than one push segment -- every A/B/C fixture
  # above is single-segment, so hoisting apply_session_repo() out of the driver loop (called once
  # before the loop instead of once per segment) passed the whole committed suite. TWO push
  # segments: the FIRST carries a resolving "-C" (a separate repo, own default trunk, no config);
  # the SECOND is a bare "git push" with no "-C" at all and must be judged by the SESSION's own
  # facts, not by whatever the first segment's "-C" target left behind. Session config denies via
  # remote.origin.push=HEAD:main (main is always a PUSH_DEFAULT_BRANCH_FALLBACK member regardless
  # of the session's own default, develop) -- the sharpest shape, per the reviewing finding,
  # because a per-segment reset failure silently DROPS a real deny rather than merely mis-scoping
  # one. Measured directly against this exact fixture: shipped script -- rc 2 (deny, via
  # remote.origin.push in the SESSION's own .git/config); with apply_session_repo() hoisted above
  # the loop (the exact mutation named below as M56) -- rc 0 (deny silently lost: the second
  # segment inherits the resolved -C target's cfg_push_lines, empty, and its current_branch,
  # never resets to the session's own).
  local main="$tmpbase/repo-c-d1" other="$tmpbase/other-d1-wt-1"
  mk_fixture_repo "$main" develop "feature/x"
  mk_fixture_config "$main" $'[remote "origin"]\n\tpush = HEAD:main\n'
  mk_fixture_repo "$other" trunk "feature/y"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../other-d1-wt-1 push origin claude/99-z && git push' "$main")"
  expect_push_deny
}

# --- unresolvable push target: fail closed (#292) ---------------------------------------------
# mutant:292-pg-c-nonwt -- drops the driver's own "-C path outside the worktree shape" reason
#   assignment, so a non-PATH_ERE, non-session "-C" value silently falls through to
#   apply_c_target's existing no-op (judged against the session) instead of denying.
# mutant:292-pg-attached-c -- drops the tokenizer's attached "-C<path>" detection.
# mutant:292-pg-multi-c -- drops the tokenizer's "ccount >= 2" ("more than one -C") reason.
# mutant:292-pg-repo-opts-attached -- drops the "<member>=" prefix arm for GIT_REPO_OPTS, so an
#   attached "--git-dir=<path>"/"--work-tree=<path>" is no longer flagged.
# mutant:292-pg-repo-opts-detached -- drops the exact-token arm for GIT_REPO_OPTS, so a detached
#   "--git-dir <path>"/"--work-tree <path>" is no longer flagged.
# mutant:292-pg-repo-opts-vocab -- narrows GIT_REPO_OPTS to "--git-dir" only, so "--work-tree" in
#   either form is no longer flagged.
# mutant:292-pg-env-vocab -- empties GIT_REPO_ENV_VARS, so no environment-variable redirect is
#   ever flagged.
# mutant:292-pg-env-exact -- widens the env-assignment check from exact GIT_REPO_ENV_VARS
#   membership to any "GIT_"-prefixed name, so an unrelated assignment like GIT_TRACE=1 is wrongly
#   flagged too.
# mutant:292-pg-session-equiv -- makes is_session_checkout_path() always return false, so a
#   session-equivalent "-C" value (".", the session cwd, the session root) is wrongly denied as
#   unresolved.
# mutant:292-pg-session-root -- drops is_session_checkout_path()'s $session_root comparison, so a
#   "-C" value naming the session's own root, checked from a SUBDIRECTORY cwd, is wrongly denied.
# mutant:292-pg-trailing-slash -- drops is_session_checkout_path()'s trailing-"/" strip on its own
#   PATH argument, so a "-C" value carrying one trailing "/" no longer matches the session cwd.
#
# B1/B2/B3's shapes (a non-wt "-C", the attached "-C<path>" form, and two "-C" tokens) each deny as
# unresolved below, reusing the same fixture dirs and command lines B1/B2/B3 (deleted from the
# #269 section above) once used for their own no-opinion verdict. Every fixture below passes an
# explicit cwd built with mk_fixture_repo, except the two controls at the very end
# (push-unres-noop-env-unrelated, push-unres-noop-global-opt-feature), whose destination
# (feature/x) never depends on cwd resolution at all.
case_pu_deny_c_nonsibling_path() {
  # B1's shape: no "-wt-<n>" suffix at all, and not lexically the session checkout -- denies as
  # unresolved.
  local main="$tmpbase/repo-c-b1" other="$tmpbase/other-checkout"
  mk_fixture_repo "$main" main "claude/17-a"
  mk_fixture_repo "$other" develop "feature/x"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../other-checkout push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(-C path outside the <name>-wt-<n> worktree shape)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(-C path outside the <name>-wt-<n> worktree shape)': '$push_err'\n" ;;
  esac
}
case_pu_deny_c_attached_form() {
  # B2's shape: the ATTACHED "-C<path>" form -- denies as unresolved.
  local main="$tmpbase/repo-c-b2" other="$tmpbase/other-checkout-b2-wt-1"
  mk_fixture_repo "$main" main "claude/17-a"
  mk_fixture_repo "$other" develop "feature/x"
  run_push_guard "$(mk_push_cmd_cwd 'git -C../other-checkout-b2-wt-1 push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(attached -C<path>)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(attached -C<path>)': '$push_err'\n" ;;
  esac
}
case_pu_deny_c_double_c() {
  # B3's shape: TWO "-C" tokens in one segment -- denies as unresolved.
  local main="$tmpbase/repo-c-b3" benign="$tmpbase/benign-wt-1" other="$tmpbase/other-checkout-b3-wt-1"
  mk_fixture_repo "$main" main "claude/17-a"
  mk_fixture_repo "$benign" main "feature/w"
  mk_fixture_repo "$other" develop "feature/x"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../benign-wt-1 -C ../other-checkout-b3-wt-1 push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(more than one -C)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(more than one -C)': '$push_err'\n" ;;
  esac
}
case_pu_deny_git_dir_attached() {
  local main="$tmpbase/repo-pu-gd-attached"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'git --git-dir=../other-u4/.git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(--git-dir)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(--git-dir)': '$push_err'\n" ;;
  esac
}
case_pu_deny_git_dir_detached() {
  local main="$tmpbase/repo-pu-gd-detached"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'git --git-dir ../other-u5/.git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(--git-dir)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(--git-dir)': '$push_err'\n" ;;
  esac
}
case_pu_deny_work_tree_attached() {
  local main="$tmpbase/repo-pu-wt-attached"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'git --work-tree=../other-u6 push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(--work-tree)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(--work-tree)': '$push_err'\n" ;;
  esac
}
case_pu_deny_work_tree_detached() {
  local main="$tmpbase/repo-pu-wt-detached"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'git --work-tree ../other-u7 push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(--work-tree)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(--work-tree)': '$push_err'\n" ;;
  esac
}
case_pu_deny_env_git_dir() {
  local main="$tmpbase/repo-pu-env-gd"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'GIT_DIR=../other-u8/.git git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(GIT_DIR=)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(GIT_DIR=)': '$push_err'\n" ;;
  esac
}
case_pu_deny_env_prefix_work_tree() {
  local main="$tmpbase/repo-pu-env-wt"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'env GIT_WORK_TREE=../other-u9 git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(GIT_WORK_TREE=)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(GIT_WORK_TREE=)': '$push_err'\n" ;;
  esac
}
case_pu_deny_env_common_dir() {
  local main="$tmpbase/repo-pu-env-cd"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'GIT_COMMON_DIR=../other-u10/.git git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(GIT_COMMON_DIR=)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(GIT_COMMON_DIR=)': '$push_err'\n" ;;
  esac
}
case_pu_deny_never_executes() {
  # Safety property on the new unresolved-target route: shape of push-unres-deny-c-nonsibling-path,
  # its own dirs, booby-trapped PATH (the C1/C2 idiom) -- deny, sentinel absent, and BOTH the
  # session repo's and the other checkout's file listings byte-identical before/after.
  local main="$tmpbase/repo-pu-never-executes" other="$tmpbase/other-pu-never-executes"
  mk_fixture_repo "$main" main "claude/17-a"
  mk_fixture_repo "$other" develop "feature/x"
  local trapdir="$tmpbase/trapbin-pu-never-executes" sentinel="$tmpbase/sentinel-pu-never-executes"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before_main after_main before_other after_other
  before_main="$(find "$main" -type f -exec ls -la {} \; | sort)"
  before_other="$(find "$other" -type f -exec ls -la {} \; | sort)"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../other-pu-never-executes push origin develop' "$main")" "$trapdir:$PATH"
  after_main="$(find "$main" -type f -exec ls -la {} \; | sort)"
  after_other="$(find "$other" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(-C path outside the <name>-wt-<n> worktree shape)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(-C path outside the <name>-wt-<n> worktree shape)': '$push_err'\n" ;;
  esac
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH while denying an unresolvable -C target\n"; }
  [ "$before_main" = "$after_main" ] || { __ok=0; __why="${__why}session repo's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
  [ "$before_other" = "$after_other" ] || { __ok=0; __why="${__why}other checkout's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
}
case_pu_deny_codex_main_session() {
  # Documented Codex payload shape (mk_codex_shell, main session -- no agent_type/agent_id).
  local main="$tmpbase/repo-pu-codex"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_codex_shell '' 'git -C ../other-checkout-u12 push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(-C path outside the <name>-wt-<n> worktree shape)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(-C path outside the <name>-wt-<n> worktree shape)': '$push_err'\n" ;;
  esac
}
case_pu_deny_c_dot_session_default() {
  # A session-equivalent "-C" value (".") is NOT judged as unresolved -- it still reaches the
  # ordinary "resolves to the default branch" route, against the session's own default (develop).
  local main="$tmpbase/repo-pu-dot-default"
  mk_fixture_repo "$main" develop "feature/z"
  run_push_guard "$(mk_push_cmd_cwd 'git -C . push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"resolves to the default branch: develop"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'resolves to the default branch: develop': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"cannot resolve which repository"*)
      __ok=0; __why="${__why}stderr unexpectedly contains 'cannot resolve which repository' -- a session-equivalent -C value must not be judged as unresolved: '$push_err'\n"
      ;;
    *) ;;
  esac
}
case_pu_noop_c_dot() {
  local main="$tmpbase/repo-pu-noop-dot"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'git -C . push origin feature/x' "$main")"
  expect_push_no_opinion
}
case_pu_noop_c_session_cwd() {
  # "-C $main/" (one trailing slash) from cwd "$main" (none) -- pins is_session_checkout_path()'s
  # own trailing-slash strip.
  local main="$tmpbase/repo-pu-noop-session-cwd"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd "git -C $main/ push -u origin \"claude/17-a\"" "$main")"
  expect_push_no_opinion
}
case_pu_noop_c_session_root() {
  # cwd is a SUBDIRECTORY of the session checkout; "-C" names the session ROOT (not the cwd) --
  # pins is_session_checkout_path()'s own $session_root comparison, distinct from $resolve_cwd.
  local main="$tmpbase/repo-pu-noop-session-root"
  mk_fixture_repo "$main" main "claude/17-a"
  mkdir -p "$main/sub"
  run_push_guard "$(mk_push_cmd_cwd "git -C $main push -u origin \"claude/17-a\"" "$main/sub")"
  expect_push_no_opinion
}
case_pu_noop_c_nonpush_segment() {
  # Only PUSH segments are affected: a non-wt "-C" on a non-push segment, followed by a benign
  # push, must stay no opinion.
  local main="$tmpbase/repo-pu-noop-nonpush"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../other-checkout-u19 status && git push origin feature/x' "$main")"
  expect_push_no_opinion
}
case_pu_noop_env_unrelated() {
  run_push_guard "$(mk_push_cmd 'GIT_TRACE=1 git push origin feature/x')"
  expect_push_no_opinion
}
case_pu_noop_global_opt_feature() {
  # #439 re-point: "-c core.pager=cat" now denies via the command-line-config route (see the
  # push-cmdcfg- section below), so this control moved to "--namespace", a
  # GIT_GLOBAL_OPTS_WITH_VALUE member that is neither a repo option (GIT_REPO_OPTS) nor a
  # command-line-config option (GIT_CMDCFG_OPTS) -- an ordinary global option with a value stays
  # unaffected.
  run_push_guard "$(mk_push_cmd 'git --namespace foo push origin feature/x')"
  expect_push_no_opinion
}

# --- command-line git config (#439) -------------------------------------------------------------
# mutant:439-pg-cmdcfg-sentinel — drops the "-cmdline-config-" sentinel print entirely, so a real
#   push segment carrying command-line config is never denied on this route.
# mutant:439-pg-cmdcfg-env-arm — drops the whole leading-assignment cmdcfg check, so no
#   GIT_CONFIG_* environment assignment is ever flagged.
# mutant:439-pg-cmdcfg-env-vocab — empties GIT_CMDCFG_ENV_VARS, so no exact-name env assignment
#   (GIT_CONFIG_COUNT/GIT_CONFIG_PARAMETERS/GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM) is ever flagged.
# mutant:439-pg-cmdcfg-env-prefixes — empties GIT_CMDCFG_ENV_PREFIXES, so no
#   GIT_CONFIG_KEY_<n>/GIT_CONFIG_VALUE_<n> assignment is ever flagged.
# mutant:439-pg-cmdcfg-env-exact — widens the env membership test from exact GIT_CMDCFG_ENV_VARS
#   membership to any "GIT_CONFIG_"-prefixed name, so an unrelated assignment like
#   GIT_CONFIG_NOSYSTEM=1 is wrongly flagged too.
# mutant:439-pg-cmdcfg-opt-exact — disables the detached-option exact-membership check, so a
#   detached "--config-env <k=V>" is no longer flagged (a bare "-c" is still caught by the
#   attached-"-c" arm below it).
# mutant:439-pg-cmdcfg-opt-attached — drops the attached-option "=" prefix-match loop, so an
#   attached "--config-env=<k=V>" is no longer flagged.
# mutant:439-pg-cmdcfg-c-attached — drops the attached "-c<k=v>" substr check, so that one form is
#   no longer flagged (a detached "-c" is still caught by the exact-membership arm above it).
# mutant:439-pg-cmdcfg-opts-vocab — narrows GIT_CMDCFG_OPTS to "-c" only, so neither
#   "--config-env" spelling is ever flagged.
# mutant:439-pg-cmdcfg-push-only — moves the sentinel print ahead of the "subcmd != push" check,
#   so a NON-push segment carrying command-line config is wrongly denied too.
# mutant:439-pg-cmdcfg-leak — removes "cmdcfg" from emit_segment()'s own local-variable list (and
#   its own reset), turning it into an awk global that leaks across segments/calls instead of
#   starting fresh for each one.
# mutant:439-pg-cmdcfg-order — lets a #292 unresolved-target reason in the same segment win over
#   the command-line-config reason (the sentinel only fires when nothing else is unresolved).
#
# Every deny fixture below also asserts that stderr contains the fixed substring "git config
# supplied on the command line", and never an input-derived value (the -c key/value text, or a
# matched GIT_CONFIG_KEY_<suffix>/GIT_CONFIG_VALUE_<suffix> name) -- see the cmdcfg) message arm in
# hooks/push-guard.sh, which prints PUSH_DENY_STEM alone with no %s for input.
case_push_cmdcfg_deny_c_remote_push() {
  local dir="$tmpbase/repo-cmdcfg-c-remote-push"
  mk_fixture_repo "$dir" main feature/x
  run_push_guard "$(mk_push_cmd_cwd 'git -c remote.origin.push=HEAD:main push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"remote.origin.push"*) __ok=0; __why="${__why}stderr echoes the -c key 'remote.origin.push': '$push_err'\n" ;;
    *) ;;
  esac
  case "$push_err" in
    *"HEAD:main"*) __ok=0; __why="${__why}stderr echoes the -c value 'HEAD:main': '$push_err'\n" ;;
    *) ;;
  esac
}
case_push_cmdcfg_deny_c_benign_key() {
  # The deny doesn't depend on the key or the destination (a non-default branch, benign key).
  run_push_guard "$(mk_push_cmd 'git -c core.pager=cat push origin feature/x')"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_push_cmdcfg_deny_c_attached() {
  run_push_guard "$(mk_push_cmd 'git -cremote.origin.push=HEAD:main push origin feature/x')"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_push_cmdcfg_deny_config_env_attached() {
  local dir="$tmpbase/repo-cmdcfg-config-env-attached"
  mk_fixture_repo "$dir" main feature/x
  run_push_guard "$(mk_push_cmd_cwd 'git --config-env=remote.origin.push=VAR push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_push_cmdcfg_deny_config_env_detached() {
  run_push_guard "$(mk_push_cmd 'git --config-env remote.origin.push=VAR push origin feature/x')"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_push_cmdcfg_deny_env_count() {
  run_push_guard "$(mk_push_cmd 'GIT_CONFIG_COUNT=1 git push origin feature/x')"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_push_cmdcfg_deny_env_key() {
  # A prefix-matched name is stored as a boolean only, never echoed.
  run_push_guard "$(mk_push_cmd 'GIT_CONFIG_KEY_7zq=remote.origin.push git push origin feature/x')"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"7zq"*) __ok=0; __why="${__why}stderr echoes the matched name suffix '7zq': '$push_err'\n" ;;
    *) ;;
  esac
}
case_push_cmdcfg_deny_env_value() {
  run_push_guard "$(mk_push_cmd 'GIT_CONFIG_VALUE_0=HEAD:main git push origin feature/x')"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_push_cmdcfg_deny_env_count_triple() {
  # The issue's own row-2 shape, verbatim.
  local dir="$tmpbase/repo-cmdcfg-env-count-triple"
  mk_fixture_repo "$dir" main feature/x
  run_push_guard "$(mk_push_cmd_cwd 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.push GIT_CONFIG_VALUE_0=HEAD:main git push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_push_cmdcfg_deny_env_parameters() {
  local dir="$tmpbase/repo-cmdcfg-env-parameters"
  mk_fixture_repo "$dir" main feature/x
  # Double-quoted bash string so the inner single quotes (git's own GIT_CONFIG_PARAMETERS
  # quoting) survive verbatim into mk_push_cmd_cwd's jq --arg.
  run_push_guard "$(mk_push_cmd_cwd "GIT_CONFIG_PARAMETERS=\"'remote.origin.push'='HEAD:main'\" git push" "$dir")"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_push_cmdcfg_deny_env_prefix() {
  # The same triple assignment, behind an "env" prefix word.
  run_push_guard "$(mk_push_cmd 'env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.push GIT_CONFIG_VALUE_0=HEAD:main git push origin feature/x')"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_push_cmdcfg_deny_env_global() {
  run_push_guard "$(mk_push_cmd 'GIT_CONFIG_GLOBAL=/nonexistent/x git push origin feature/x')"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_push_cmdcfg_deny_env_system() {
  run_push_guard "$(mk_push_cmd 'GIT_CONFIG_SYSTEM=/nonexistent/x git push origin feature/x')"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_push_cmdcfg_deny_never_executes() {
  # Safety property on the new command-line-config route, the same C1/C2 booby-trapped-PATH idiom
  # as case_pu_deny_never_executes: deny, sentinel absent, and the fixture repo's file listing
  # byte-identical before/after.
  local dir="$tmpbase/repo-cmdcfg-never-executes"
  mk_fixture_repo "$dir" main feature/x
  local trapdir="$tmpbase/trapbin-cmdcfg-never-executes" sentinel="$tmpbase/sentinel-cmdcfg-never-executes"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before after
  before="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  run_push_guard "$(mk_push_cmd_cwd 'git -c remote.origin.push=HEAD:main push' "$dir")" "$trapdir:$PATH"
  after="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH while denying command-line config\n"; }
  [ "$before" = "$after" ] || { __ok=0; __why="${__why}fixture repo's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
}
case_push_cmdcfg_deny_codex_main_session() {
  # Documented Codex payload shape (mk_codex_shell, main session -- no agent_type/agent_id).
  local dir="$tmpbase/repo-cmdcfg-codex"
  mk_fixture_repo "$dir" main feature/x
  run_push_guard "$(mk_codex_shell '' 'git -c remote.origin.push=HEAD:main push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_push_cmdcfg_noop_nonpush_segment() {
  # Only push segments are judged, and the flag doesn't leak across segments.
  local dir="$tmpbase/repo-cmdcfg-noop-nonpush"
  mk_fixture_repo "$dir" main feature/x
  run_push_guard "$(mk_push_cmd_cwd 'git -c core.pager=cat log && git push origin feature/x' "$dir")"
  expect_push_no_opinion
}
case_push_cmdcfg_noop_env_nosystem() {
  # Exact vocabulary, not every "GIT_CONFIG_"-prefixed name.
  run_push_guard "$(mk_push_cmd 'GIT_CONFIG_NOSYSTEM=1 git push origin feature/x')"
  expect_push_no_opinion
}
case_push_cmdcfg_deny_precedence() {
  # One segment carrying both a #292 unresolved-target assignment (GIT_DIR=) and command-line
  # config: the command-line-config reason is the one reported (ADVISORY Q5).
  run_push_guard "$(mk_push_cmd 'GIT_DIR=x GIT_CONFIG_COUNT=1 git push origin feature/x')"
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}

# --- a push segment the tokenizer cannot follow: a quoted or escaped git option, a quote or escape
# in the command prefix, or an env option it cannot read (#449, absorbing #451) ---------------------
# Every deny fixture builds the same fixture checkout (default branch main, current branch
# feature/x) and asserts the ONE fixed #292 "unresolved" line naming the fixed reason; every
# no-opinion fixture also passes that checkout as cwd (the AMBIENT-$PWD rule) and its raw payload
# holds both "push" and "git", so the raw-stdin fast path cannot pass it vacuously. Every reason is
# a fixed string -- no deny line echoes command text.
# mutant:449-pg-obscured-off — drops the quoted-or-escaped-git-option trigger in the subcommand
#   walk, so the option is judged as before (normalised into the subcommand slot, segment dropped).
# mutant:449-pg-obscured-normalize — tests normalize(tok) instead of strip_quotes(tok) in that
#   trigger, so "--git-dir=../other/.git" (basename .git) no longer reads as an option.
# mutant:449-pg-unbalanced-off — drops the assignment-branch unbalanced-quote trigger.
# mutant:449-pg-unbalanced-dq — drops the double-quote parity arm of quote_unbalanced().
# mutant:449-pg-unbalanced-sq — drops the single-quote parity arm of quote_unbalanced().
# mutant:449-pg-unbalanced-bs — drops the trailing-backslash arm of quote_unbalanced().
# mutant:449-pg-prefix-quoted-shape — drops the trigger for a quote-bearing option or assignment
#   after a prefix word.
# mutant:449-pg-env-u-consume — makes -u/--unset skip only themselves, not their value token.
# mutant:449-pg-env-u-value-check — drops the unbalanced-value check on the token consumed by a
#   detached -u/--unset.
# mutant:449-pg-env-u-attached-quote — drops the unbalanced check on an attached -uNAME /
#   --unset=NAME token.
# mutant:449-pg-env-u-attached — drops the attached -uNAME / --unset=NAME arm.
# mutant:449-pg-env-lost-off — drops the unsupported-env-option trigger.
# mutant:449-pg-env-novalue-vocab — empties PUSH_ENV_NOVALUE_OPTS, so -i is an unsupported option.
# mutant:449-pg-env-context — sets the env-context flag for any prefix word, not only env.
# mutant:449-pg-lost-ungated — makes lost_push() always true, so a segment that cannot be a push
#   denies too.
# mutant:449-pg-lost-unarmed — makes any later push substring count, not only one after a git word.
# mutant:449-pg-lost-same-token — drops the single-token git-and-push check in lost_push().
# mutant:449-pg-lost-unres-precedence — lets the new reason win over an earlier #292 reason
#   (GIT_DIR=) in emit_lost().
# mutant:449-pg-lost-precedence — lets the new reason win over command-line git config in
#   emit_lost().
# mutant:449-pg-lost-gopt-skip — drops the global-option value skip in lost_push(), so the value
#   of -C is read as a word that disarms the walk before push.
# mutant:449-pg-lost-gopt-skip-armed1 — limits that value skip to the prefix triggers' unarmed
#   scan (armed 0), so the quoted-option trigger's armed-1 scan reads the -C value as a word,
#   disarms, and a quoted git option followed by -C <dir> push gets no opinion.
# mutant:449-pg-env-arm-prefix-guard — keeps the env arm from seeing an option whose basename is a
#   prefix word (--chdir=../env, a lone -).
# mutant:449-pg-quote-bearing-sq — drops the single-quote arm of quote_bearing().
# mutant:449-pg-gopt-value-off — drops the unbalanced-value check for a global option other than -C.
# mutant:449-pg-gopt-attached-off — drops the unbalanced attached-option check in the subcommand walk.
# mutant:449-pg-lost-mode2-skip — restores the option-value skip in the split-value walk, so a
#   split value last fragment that looks like an option (-c") swallows the real push.
# mutant:449-pg-lost-mode2 — makes the split-value walk disarm on a non-option word like the others.
# mutant:449-pg-gopt-c-exempt — removes the -C exemption from the value check.
# mutant:449-pg-scan-once — removes both per-segment memos, so lost_push() re-scans the segment
#   once per trigger token and a long segment goes quadratic (filter "push-lostscan-").
pp_run() {
  local dir="$tmpbase/repo-pp"
  mk_fixture_repo "$dir" main feature/x
  run_push_guard "$(mk_push_cmd_cwd "$1" "$dir")"
}
# pp_expect_unres REASON — the #292 unresolved line, naming the fixed REASON in parentheses.
pp_expect_unres() {
  if [ -z "$1" ]; then __ok=0; __why="${__why}pp_expect_unres called with an empty REASON (needle_required)\n"; return; fi
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*"($1)"*) ;;
    *) __ok=0; __why="${__why}stderr missing the unresolved line naming '($1)': '$push_err'\n" ;;
  esac
}
PP_R_OPT="quoted or escaped git option"
PP_R_PFX="quote or escape in the command prefix"
PP_R_ENV="unsupported env option"
case_pp_deny_quoted_c() {
  pp_run 'git "-c" remote.origin.push=HEAD:main push'
  pp_expect_unres "$PP_R_OPT"
}
case_pp_deny_escaped_c() {
  pp_run 'git \-c remote.origin.push=HEAD:main push'
  pp_expect_unres "$PP_R_OPT"
}
case_pp_deny_quoted_git_dir() {
  # Destination develop, so only the new rule can deny it.
  pp_run 'git "--git-dir=../other/.git" push origin develop'
  pp_expect_unres "$PP_R_OPT"
}
case_pp_deny_glued_quote_c() {
  pp_run 'git -"c" remote.origin.push=HEAD:main push'
  pp_expect_unres "$PP_R_OPT"
}
case_pp_noop_quoted_opt_nonpush() {
  pp_run 'git "-c" core.pager=cat log && git push origin feature/x'
  expect_push_no_opinion
}
case_pp_noop_quoted_opt_push_word() {
  # A "push" word that is the --grep value of a non-push git command must not count.
  pp_run 'git "--no-pager" log --grep push && git push origin feature/x'
  expect_push_no_opinion
}
case_pp_deny_assign_dquote_space() {
  # Destination main: the deny must be the new reason, not the ordinary default-branch route.
  pp_run 'X="a b" git push origin main'
  pp_expect_unres "$PP_R_PFX"
  case "$push_err" in
    *"resolves to the default branch"*) __ok=0; __why="${__why}denied via the default-branch route, not the prefix rule: '$push_err'\n" ;;
  esac
}
case_pp_deny_assign_squote_space() {
  pp_run "X='a b' git push origin feature/x"
  pp_expect_unres "$PP_R_PFX"
}
case_pp_deny_assign_backslash_space() {
  pp_run 'X=a\ b git push origin feature/x'
  pp_expect_unres "$PP_R_PFX"
}
case_pp_deny_git_dir_space() {
  # An earlier #292 reason keeps precedence over the new one.
  pp_run 'GIT_DIR="../a b/.git" git push origin feature/x'
  pp_expect_unres "GIT_DIR="
}
case_pp_deny_env_quoted_assign() {
  pp_run 'env "X=a" git push origin feature/x'
  pp_expect_unres "$PP_R_PFX"
}
case_pp_deny_env_quoted_opt() {
  pp_run 'env "-C" ../other git push origin feature/x'
  pp_expect_unres "$PP_R_PFX"
}
case_pp_deny_env_u_quoted_value() {
  pp_run 'env -u "A B" git push origin feature/x'
  pp_expect_unres "$PP_R_PFX"
}
case_pp_noop_assign_space_nonpush() {
  pp_run 'X="a b" git status && git push origin feature/x'
  expect_push_no_opinion
}
case_pp_noop_assign_space_commit() {
  # "push" inside a commit message after a git word must not count: git is followed by commit, which
  # disarms the walk.
  pp_run 'GIT_AUTHOR_NAME="A B" git commit -m "fix push" && git push origin feature/x'
  expect_push_no_opinion
}
case_pp_noop_heredoc_apostrophe() {
  # The command-word candidate is never a trigger: a heredoc prose line starting Don't is scanned as
  # its own segment and must stay silent.
  pp_run "git commit -F - <<EOF${LF}Don't let git push skip the guard${LF}EOF${LF}git push -u origin \"claude/17-a\""
  expect_push_no_opinion
}
case_pp_deny_env_u_main() {
  # -u consumes FOO, so git is the command word and the ordinary default-branch route denies.
  pp_run 'env -u FOO git push origin main'
  expect_push_deny
  case "$push_err" in
    *"resolves to the default branch"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'resolves to the default branch': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"cannot resolve"*) __ok=0; __why="${__why}denied as unresolved, not via the default-branch route: '$push_err'\n" ;;
  esac
}
case_pp_noop_env_u_feature() {
  pp_run 'env -u FOO git push origin feature/x'
  expect_push_no_opinion
}
case_pp_noop_env_unset_attached() {
  pp_run 'env --unset=FOO -uBAR git push origin feature/x'
  expect_push_no_opinion
}
case_pp_deny_env_u_attached_unbalanced() {
  pp_run 'env -u"A B" git push origin feature/x'
  pp_expect_unres "$PP_R_PFX"
}
case_pp_deny_env_u_git_dir() {
  pp_run 'env -u FOO GIT_DIR=../x/.git git push origin feature/x'
  pp_expect_unres "GIT_DIR="
}
case_pp_deny_env_c() {
  pp_run 'env -C ../other git push origin main'
  pp_expect_unres "$PP_R_ENV"
}
case_pp_deny_env_chdir() {
  pp_run 'env --chdir=../other git push origin feature/x'
  pp_expect_unres "$PP_R_ENV"
}
case_pp_deny_env_s() {
  pp_run "env -S 'git push origin feature/x'"
  pp_expect_unres "$PP_R_ENV"
}
case_pp_deny_env_s_attached() {
  # Literal backslash-t inside the attached -S body.
  pp_run 'env -S"git\tpush origin feature/x"'
  pp_expect_unres "$PP_R_ENV"
}
case_pp_noop_env_c_nonpush() {
  pp_run 'env -C ../other git status && git push origin feature/x'
  expect_push_no_opinion
}
case_pp_noop_env_i_feature() {
  pp_run 'env -i git push origin feature/x'
  expect_push_no_opinion
}
case_pp_noop_sudo_opt_feature() {
  # A dash option after a non-env prefix word is still skipped alone.
  pp_run 'sudo -E git push origin feature/x'
  expect_push_no_opinion
}
case_pp_deny_lost_cmdcfg() {
  # Command-line git config keeps its own message over the new reason.
  pp_run 'GIT_CONFIG_COUNT=1 X="a b" git push origin feature/x'
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_pp_deny_never_executes() {
  # Safety property on the new route: deny, sentinel absent, and the fixture repo listing
  # byte-identical (the case_push_cmdcfg_deny_never_executes idiom).
  local dir="$tmpbase/repo-pp-never-executes"
  mk_fixture_repo "$dir" main feature/x
  local trapdir="$tmpbase/trapbin-pp-never-executes" sentinel="$tmpbase/sentinel-pp-never-executes"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before after
  before="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  run_push_guard "$(mk_push_cmd_cwd 'git "-c" remote.origin.push=HEAD:main push' "$dir")" "$trapdir:$PATH"
  after="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  pp_expect_unres "$PP_R_OPT"
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH while denying a lost push segment\n"; }
  [ "$before" = "$after" ] || { __ok=0; __why="${__why}fixture repo's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
}
case_pp_deny_codex_main_session() {
  local dir="$tmpbase/repo-pp-codex"
  mk_fixture_repo "$dir" main feature/x
  run_push_guard "$(mk_codex_shell '' 'env -C ../other git push origin main' "$dir")"
  pp_expect_unres "$PP_R_ENV"
}
case_pp_noop_c_quoted_value() {
  # The harness own worktree shape: a quoted -C VALUE is consumed with its option and is never an
  # option-slot token, so it stays no-opinion (mirrors push-noop-c-upstream-claude).
  local dir="$tmpbase/repo-pp-c-quoted"
  mk_fixture_repo "$dir" main feature/x
  run_push_guard "$(mk_push_cmd_cwd 'git -C "../demo-wt-1" push -u origin "claude/17-a"' "$dir")"
  expect_push_no_opinion
}
case_pp_deny_gopt_value_c() {
  # The quoted VALUE of -c splits at its space and a later fragment would become the subcommand.
  pp_run 'git -c "user.name=A B" push origin feature/x'
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_pp_deny_gopt_value_sshcommand() {
  pp_run 'git -c "core.sshCommand=ssh -i k" push origin main'
  expect_push_deny
}
case_pp_deny_gopt_value_namespace() {
  pp_run 'git --namespace "a b" push origin feature/x'
  pp_expect_unres "$PP_R_OPT"
}
case_pp_deny_gopt_value_trailing_option() {
  # The split value last fragment (-c") looks like an option; the split-value walk must not apply
  # the option-value skip to it, or it swallows the real push.
  pp_run 'git -c "user.name=A b -c" push origin main'
  expect_push_deny
}
case_pp_deny_gopt_value_attached_trailing_option() {
  pp_run 'git -c k="a b -c" push origin main'
  expect_push_deny
}
case_pp_deny_gopt_value_trailing_namespace() {
  pp_run 'git --namespace "a X --exec-path" push origin main'
  pp_expect_unres "$PP_R_OPT"
}
case_pp_deny_gopt_attached_value() {
  pp_run 'git --exec-path="a b" push origin feature/x'
  pp_expect_unres "$PP_R_OPT"
}
case_pp_deny_quoted_c_split_value() {
  pp_run 'git "-c" "a b" push origin feature/x'
  pp_expect_unres "$PP_R_OPT"
}
case_pp_noop_gopt_value_nonpush() {
  pp_run 'git -c "user.name=A B" commit -m x && git push origin feature/x'
  expect_push_no_opinion
}
case_pp_noop_c_space_value() {
  # The approved -C residual: a quoted -C value containing a space is exempt from the new value
  # check, because the harness own worktree paths may hold a space.
  pp_run 'git -C "../demo wt-1" push origin feature/x'
  expect_push_no_opinion
}
case_pp_deny_squote_c() {
  pp_run "git '-c' remote.origin.push=HEAD:main push"
  pp_expect_unres "$PP_R_OPT"
}
case_pp_deny_prefix_gopt_value() {
  # The armed walk must skip a git global option VALUE (-C ../other), or push is never reached.
  pp_run 'X="a b" git -C ../other push origin feature/x'
  pp_expect_unres "$PP_R_PFX"
}
case_pp_deny_quoted_opt_gopt_value() {
  # The quoted-option trigger's armed scan must also skip a git global option VALUE (-C ../other).
  pp_run 'git "--no-pager" -C ../other push origin feature/x'
  pp_expect_unres "$PP_R_OPT"
}
case_pp_deny_env_chdir_prefix_basename() {
  # The option value basename is a PREFIX_WORDS member; the env arm must still see the option.
  pp_run 'env --chdir=../env git push origin feature/x'
  pp_expect_unres "$PP_R_ENV"
}
case_pp_deny_env_lone_dash() {
  pp_run 'env - git push origin feature/x'
  pp_expect_unres "$PP_R_ENV"
}
# pp_flood_cmd N — the six-record flood shape at N tokens per record: one record per trigger, then
# a real push so the hook reaches check_deadline after the tokenizer.
pp_flood_cmd() {
  local n="$1" r1 r2 r3 r4 r5
  r1="$(printf ' X="a%.0s' $(seq 1 "$n"))"
  r2="git$(printf ' -"x"%.0s' $(seq 1 "$n")) status"
  r3="env$(printf ' -Z%.0s' $(seq 1 "$n")) true"
  r4="env$(printf ' -u X%.0s' $(seq 1 "$n"))$(printf ' Y="b"%.0s' $(seq 1 "$n")) true"
  r5="git$(printf ' -c "a%.0s' $(seq 1 "$n")) status"
  printf '%s\n%s\n%s\n%s\n%s\ngit push origin feature/x' "$r1" "$r2" "$r3" "$r4" "$r5"
}
# pp_flood_twin_cmd N (#507) — the mutant-invariant twin of pp_flood_cmd N: the same six-line
# layout, the same token count per line and the same byte length per token, but records 1, 2, 3
# and 5 carry exactly ONE trigger token (the first) followed by N-1 tokens that trigger nothing
# (X=ab, -xyz, -i, -c ab). lost_push() therefore runs at most once per record whether or not the
# per-segment memos exist, so the twin's cost tracks the unmutated flood and is the same under
# 449-pg-scan-once, as #470's ab-pc control is under its overlap mutant. Record 4 and the final
# push line are copied verbatim. Requires N >= 2 (BSD seq counts down when first > last).
pp_flood_twin_cmd() {
  local n="$1" r1 r2 r3 r4 r5 m=$(( $1 - 1 ))
  r1=' X="a'"$(printf ' X=ab%.0s' $(seq 1 "$m"))"
  r2='git -"x"'"$(printf ' -xyz%.0s' $(seq 1 "$m"))"' status'
  r3='env -Z'"$(printf ' -i%.0s' $(seq 1 "$m"))"' true'
  r4="env$(printf ' -u X%.0s' $(seq 1 "$n"))$(printf ' Y="b"%.0s' $(seq 1 "$n")) true"
  r5='git -c "a'"$(printf ' -c ab%.0s' $(seq 1 "$m"))"' status'
  printf '%s\n%s\n%s\n%s\n%s\ngit push origin feature/x' "$r1" "$r2" "$r3" "$r4" "$r5"
}
case_push_lostscan_noop_flood() {
  # FLOOD + TIMING, sized and bounded by cost RATIO from a same-run control, never by absolute
  # speed. The control is pp_flood_twin_cmd (the flood's token count and byte lengths, one trigger
  # per trigger record, so linear under 449-pg-scan-once too), timed in the foreground with no
  # deadline override. calibrated_flood_tokens scales the flood's token count so the PREDICTED
  # linear cost is TARGET, a fifth of the hook's effective whole-second budget (DL_KNOB_MAX), so a
  # load swing of up to about 5x between control and flood still leaves the unmutated flood under
  # the production budget; MAX keeps the full proven size on a fast host and MIN the smallest size
  # the kill still needs. The flood then runs under an active deadline of K times that prediction
  # (FLOOR absorbs the whole-second granularity): K sits between the unmutated flood-to-prediction
  # ratio (1 plus the load swing) and the scan-once flood's ratio, whose per-trigger re-scans grow
  # with the token count while the twin stays linear. A fail-open of the >128 KB input route is
  # covered by push-dl-deny-production-budget.
  local dir="$tmpbase/repo-pp-flood" ctl_n=1000 min_n=700 max_n=10000 floor=2 k=8
  local target_ms=$(( DL_KNOB_MAX * 200 )) ctl_ms pred_ms
  mk_fixture_repo "$dir" main feature/x
  measure_ms run_push_guard "$(mk_push_cmd_big "$(pp_flood_twin_cmd "$ctl_n")" "$dir")"
  ctl_ms="$measured_ms"
  if [ -z "$ctl_ms" ]; then
    __ok=0; __why="${__why}control run's own timing report could not be parsed — can't size the flood\n"
    return
  fi
  expect_push_no_opinion
  if [ "$__ok" -eq 0 ]; then
    __why="${__why}twin control did not return no opinion\n"
    return
  fi
  calibrated_flood_tokens "$ctl_ms" "$ctl_n" "$target_ms" "$min_n" "$max_n"
  pred_ms=$(( ctl_ms * flood_tokens / ctl_n ))
  calibrated_deadline "$floor" "$k" "$pred_ms"
  push_deadline_override="$calibrated_secs"
  measure_ms run_push_guard "$(mk_push_cmd_big "$(pp_flood_cmd "$flood_tokens")" "$dir")"
  expect_push_no_opinion
  if [ "$__ok" -eq 0 ]; then
    __why="${__why}control ${ctl_ms}ms at ${ctl_n} -> ${flood_tokens} tokens, predicted ${pred_ms}ms -> deadline ${calibrated_secs}s, flood ${measured_ms}ms\n"
  fi
}

# --- runtime expansion in the command prefix or the git options (#508) ----------------------------
# A word in command position whose basename holds a dollar sign followed by a name character, a digit,
# a special parameter or a quote may expand to nothing, so the real command word behind it must still
# resolve, and the segment fails closed when it could still be a push. Every fixture passes an
# explicit cwd (pp_run), and every deny pins the fixed reason in parentheses and that no deny line
# echoes input. Case names avoid the substrings other registry filters match.
PP_R_RXP="runtime expansion in the command prefix"
PP_R_RXG="runtime expansion in the git options"
# rtx_deny REASON CMD... — each CMD denies with the unresolved line naming REASON, echoing no input.
rtx_deny() {
  local reason="$1" c w0
  shift
  for c in "$@"; do
    w0="$__why"; __why=""
    pp_run "$c"
    pp_expect_unres "$reason"
    al_expect_no_echo '$'
    if [ -n "$__why" ]; then __why="${w0}[$c] ${__why}"; else __why="$w0"; fi
  done
}
# rtx_noop CMD... — each CMD gets no opinion.
rtx_noop() {
  local c w0
  for c in "$@"; do
    w0="$__why"; __why=""
    pp_run "$c"
    expect_push_no_opinion
    if [ -n "$__why" ]; then __why="${w0}[$c] ${__why}"; else __why="$w0"; fi
  done
}
# mutant:508-pg-rx-prefix-off — never fires the command-prefix gate after the walk, so an expansion
#   word in front of a push is skipped and the push resolves as if nothing were there.
case_push_rtexp_deny_dollar_name() {
  rtx_deny "$PP_R_RXP" '$X git push origin main' '$X git push origin feature/x' '"$X" git push origin feature/x' \
    'a$X git push origin feature/x' 'env $X git push origin feature/x' 'sudo -$X git push origin feature/x'
}
# mutant:508-pg-rx-re-special — drops digits and special parameters from the expansion predicate, so
#   a positional or all-arguments expansion is no expansion.
# mutant:508-pg-rx-re-zsh — drops the zsh expansion characters (equals, tilde, caret) from the
#   expansion predicate, so $=X, $~X and $^X are no expansion.
case_push_rtexp_deny_special() {
  rtx_deny "$PP_R_RXP" '$1 git push origin feature/x' '$@ git push origin feature/x' \
    '$=X git push origin main' '$~X git push origin main' '$^X git push origin main'
}
# mutant:508-pg-rx-re-sq — drops the apostrophe from the expansion predicate, so an ANSI-C quoted
#   word is no expansion.
# mutant:508-pg-rx-re-dq — drops the double quote from the expansion predicate, so a locale-quoted
#   word is no expansion.
case_push_rtexp_deny_quote_expansion() {
  rtx_deny "$PP_R_RXP" "\$'' git push origin feature/x" '$"" git push origin feature/x' \
    "env \$'A=b' git push origin main"
}
# mutant:508-pg-rx-assign-prefix — drops the trigger for an assignment after a prefix word, which
#   the shell word-splits.
case_push_rtexp_deny_env_assign() {
  rtx_deny "$PP_R_RXP" 'env X=$Y git push origin feature/x'
}
# mutant:508-pg-rx-env-u-value — drops the trigger for an expansion as the value of env -u.
case_push_rtexp_deny_env_u_value() {
  rtx_deny "$PP_R_RXP" 'env -u $X git push origin feature/x'
}
# mutant:508-pg-rx-env-u-attached — drops the trigger for an expansion attached to env -u.
case_push_rtexp_deny_env_u_attached() {
  rtx_deny "$PP_R_RXP" 'env -u$X git push origin feature/x'
}
# mutant:508-pg-rx-armed — starts the prefix gate scan unarmed, so a push word that follows a pure-
#   expansion command word with no git word before it is missed.
# mutant:508-pg-fastpath-dollar — drops the dollar-and-push arm of the raw-stdin fast path, so a
#   runtime-built command word with no git text exits before the tokenizer.
case_push_rtexp_deny_built_command_word() {
  # No git text anywhere in the raw stdin: only the dollar-and-push fast-path arm lets it through.
  local cmd='$G push origin main' payload dir="$tmpbase/repo-pp"
  mk_fixture_repo "$dir" main feature/x
  payload="$(mk_push_cmd_cwd "$cmd" "$dir")"
  case "$(printf '%s' "$payload" | tr '[:upper:]' '[:lower:]')" in
    *git*) __ok=0; __why="${__why}fixture payload names git, so the fast path is not the gate under test\n"; return ;;
  esac
  run_push_guard "$payload"
  pp_expect_unres "$PP_R_RXP"
}
# mutant:508-pg-rx-git-off — never fires the git-option-slot gate, so an expansion between git and
#   push gets no opinion.
case_push_rtexp_deny_git_slot() {
  rtx_deny "$PP_R_RXG" 'git $X push origin main' 'git -$X push origin feature/x' 'git $=X push origin main' \
    'git $X core.pager=cat push origin feature/x'
}
# mutant:508-pg-rx-git-armed2 — scans the git-slot tail with the option-value skip enabled, so an
#   option-looking token swallows the push behind it.
case_push_rtexp_deny_git_slot_ansi_c_opt() {
  rtx_deny "$PP_R_RXG" "git \$'-c' core.pager=cat push origin feature/x"
}
# mutant:508-pg-rx-git-self — drops the check that the git-slot expansion word itself names push.
case_push_rtexp_deny_git_slot_push_text() {
  rtx_deny "$PP_R_RXG" "git \$X'push' origin main"
}
# mutant:508-pg-rx-ansic-literal — stops reading a plain ANSI-C literal in the git slot as the word
#   it spells, so its alias is never looked up.
# mutant:508-pg-rx-ansic-locale — stops treating a dollar sign with a double quote as a segment
#   opener in the git slot, so locale spellings are never read as their name.
# mutant:508-pg-rx-ansic-backslash — drops the unconditional git-options deny that the fail-closed
#   flag drives, so an unreadable slot word only denies when push text follows.
case_push_rtexp_deny_git_slot_ansi_c_literal() {
  # A plain ANSI-C literal is the word it spells: $'push' is push, $'zqp' looks up the alias zqp, and
  # one with a backslash in its body fails closed under the git-options reason.
  local dir="$tmpbase/repo-rtx-alias"
  pp_run "git \$'push' origin main"
  expect_push_deny
  case "$push_err" in
    *"resolves to the default branch"*) ;;
    *) __ok=0; __why="${__why}git \$'push' origin main: stderr missing the default-branch reason: '$push_err'\n" ;;
  esac
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = push')"
  al_run "git \$'zqp' origin main" "$dir"
  al_expect_alias ".git/config"
  al_run 'git $"zqp" origin main' "$dir"
  al_expect_alias ".git/config"
  rtx_deny "$PP_R_RXG" "git \$'z\\x71p' origin main" "git -\$X \$'push' origin feature/x" 'git -$X $"push" origin feature/x'
}
# mutant:508-pg-rx-git-nondash — takes the first skipped expansion word as the candidate subcommand
#   even when it is dash-led, so the alias scan stops short of the options after it and a cut push
#   loses its sentinel.
# mutant:508-pg-rx-git-wholeslot — scans for alias and include text only up to the candidate
#   subcommand, so a trailing option value after the skipped words is never read.
# mutant:508-pg-rx-ansic-failclosed — drops the unconditional deny for a git-slot word that holds a
#   dollar sign and a quote but is not exactly one plain segment, so concatenated, mixed-quote and
#   backslash spellings fall through to the push-text check only.
# mutant:508-pg-rx-ansic-unpaired — drops the closing-quote check in whole_lit(), so an unterminated
#   segment ($'pu) is read as a truncated name instead of failing closed.
case_push_rtexp_deny_git_slot_ansi_c_concat() {
  # Any git-slot word holding a dollar sign and a quote that is not exactly one plain segment fails closed
  # under the git-options reason, push or not: concatenations, mixed quote kinds, backslashes, attached
  # option values. A whole-word plain literal is read as its name, so $'status' stays no opinion.
  rtx_deny "$PP_R_RXG" "git p\$'ush' origin main" "git \$'p'\$'ush' origin main" "git pu\$'sh' origin main" \
    "git --no-pager p\$'ush' origin main" 'git p$"ush" origin main' 'git $"p"$'"'ush'"' origin main' \
    "git \"p\"\$'ush' origin main" "git p\$'u'\"sh\" origin main" "git p\\u\$'sh' origin main" "git \\p\$'ush' origin main" \
    "git p\$'us'\\h origin main" "git \$'p'\\u\$'sh' origin main" "git \"p\"\$'\\x75sh' origin main" \
    "git \"z\"\$'qp' origin main" "git \$'z'\"q\"p origin main" "git z\\q\$'p' origin main" \
    "git p\$'\\x75sh' origin main" "git pu\$'s\\x68' origin feature/x" \
    'git -$X p$'"'ush'"' origin feature/x' "git -\$X \$'p'\$'ush' origin feature/x" "git \$X p\$'ush' origin feature/x" \
    "git \$'-c' core.pager=cat p\$'ush' origin feature/x" \
    "git st\$'atus'" 'git st$"atus"' "git --namespace=\$'a b' status" "git \$'a b' status" "git \$'pu status"
  # An attached option holding a space-bearing segment is a deliberate over-block, whichever reason names it.
  pp_run "git --git-dir=\$'/tmp/a b/.git' status"
  expect_push_deny
  rtx_noop "git \$'status'"
}
case_push_rtexp_deny_git_slot_dash_led() {
  # The candidate subcommand is the first skipped word that does not start with a dash, and the alias
  # and relocation scan covers the whole option slot, so an option after a dash-led expansion is seen.
  local c w0
  for c in 'git -$A --config-env=alias.p=V $B' 'git -$X -c alias.zqp=status "$X"' \
    "GIT_CONFIG_PARAMETERS=x git -\$X -c include.path=/x \$'p'" 'git $A -c include.path=/tmp/x $B' \
    'git $A --config-env=alias.p=V $B' 'git -$A -C . -c include.path=/tmp/x $B' 'git $A -c include.path=/tmp/x' \
    "git --no-pager -\$A -c include.path=/tmp/x \"\$B\""; do
    w0="$__why"; __why=""
    pp_run "$c"
    expect_push_deny
    al_expect_no_echo '$'
    if [ -n "$__why" ]; then __why="${w0}[$c] ${__why}"; else __why="$w0"; fi
  done
  # Every skipped word dash-led: no subcommand, so a push cut by the closing bracket still denies.
  pp_run '[[ a ]] git -$X ]] push origin main'
  expect_push_deny
}
# mutant:508-pg-rx-git-trailing — drops the fallback that makes a skipped expansion word the
#   candidate subcommand when no subcommand follows it, so the alias and relocation checks never
#   run.
case_push_rtexp_deny_git_slot_trailing() {
  # The skipped expansion word is the last word of the option slot, so no subcommand follows it: it
  # stays the alias candidate it was before the skip, and config this hook cannot read still denies.
  local c w0
  for c in "git -c alias.p=push \$'p'" 'git -c alias.p=push $X' 'HOME=/x git $X' 'env HOME=/x git $X' \
    'git --config-env=alias.p=V $X' 'git -c include.path=/x $X' \
    "git -c alias.p=push -c remote.origin.push=HEAD:main \$'p'"; do
    w0="$__why"; __why=""
    pp_run "$c"
    expect_push_deny
    al_expect_no_echo '$'
    if [ -n "$__why" ]; then __why="${w0}[$c] ${__why}"; else __why="$w0"; fi
  done
}
# rtx_alias_run CMD — CMD against a repo whose config defines a push alias, expecting the alias deny.
rtx_alias_run() {
  local dir="$tmpbase/repo-rtx-alias"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = push')"
  al_run "$1" "$dir"
  al_expect_alias ".git/config"
  al_expect_no_echo '$X'
}
# mutant:508-pg-rx-git-skip-off — drops the git-slot skip, so the expansion word becomes the
#   subcommand and the real alias behind it is never looked up.
case_push_rtexp_deny_git_slot_alias() {
  rtx_alias_run 'git $X zqp origin main'
}
case_push_rtexp_deny_prefix_alias() {
  rtx_alias_run '$X git zqp origin main'
}
# mutant:508-pg-rx-skip-off — drops the skip of an expansion word, so the walk ends on it as the
#   command word and a cd or git alias behind it never resolves.
case_push_rtexp_deny_prefix_cd() {
  pp_run '$X cd ../other && git push origin feature/x'
  expect_push_deny
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing the cd/pushd/popd reason: '$push_err'\n" ;;
  esac
}
# mutant:508-pg-rec-lost-off — drops the record-level fallback of the unsupported-env-option
#   trigger, so an env -S string the segmenter cut at an expansion is judged without its tail.
case_push_rtexp_deny_env_s_brace() {
  rtx_deny "$PP_R_ENV" 'env -S'"'"'${X}git\_push\_origin\_main'"'"
}
case_push_rtexp_deny_env_s_cmdsubst() {
  rtx_deny "$PP_R_ENV" 'env -S"$(true)git\_push\_origin\_main"'
}
case_push_rtexp_deny_env_c_brace() {
  rtx_deny "$PP_R_ENV" 'env -C ${D} git push origin feature/x'
}
case_push_rtexp_deny_codex_shaped() {
  # A main-session Codex payload: the new reason, not the #494 workdir reason, names the deny.
  local dir="$tmpbase/repo-pp"
  mk_fixture_repo "$dir" main feature/x
  run_push_guard "$(mk_codex_shell '' '$X git push origin feature/x' "$dir")"
  pp_expect_unres "$PP_R_RXP"
}
# mutant:508-pg-rx-ungated — drops the push-reachability condition of the prefix gate, so every
#   expansion prefix denies.
case_push_rtexp_noop_status() {
  rtx_noop '$X git status && git push origin feature/x'
}
case_push_rtexp_noop_editor() {
  rtx_noop '$EDITOR README.md && git push origin feature/x'
}
# mutant:508-pg-rx-git-ungated — drops the push-reachability condition of the git-slot gate, so
#   every expansion in the git slot denies.
case_push_rtexp_noop_git_slot_status() {
  rtx_noop 'git $X status && git push origin feature/x'
}
# mutant:508-pg-rx-bare-assign — drops the prefix-word condition, so a bare assignment, which is
#   never word-split, also triggers.
case_push_rtexp_noop_bare_assign() {
  rtx_noop 'X=$Y git push origin feature/x'
}
# mutant:508-pg-rx-lone-dollar — treats any dollar sign as an expansion, so a lone prompt dollar is
#   skipped and the push behind it is judged.
case_push_rtexp_noop_prompt_dollar() {
  # A heredoc body line whose first word is a lone dollar sign is not an expansion.
  rtx_noop "$(printf 'cat <<EOF\n$ git push origin main\nEOF\ngit push origin feature/x')"
}
# mutant:508-pg-rx-basename — tests the whole token instead of its basename, so an expansion in a
#   directory part counts as an expansion word.
case_push_rtexp_noop_dir_expansion() {
  rtx_noop '$HOME/bin/deploy push-docs && git push origin feature/x'
}
# mutant:508-pg-rec-cut-gate — drops the cut-character condition of that fallback, so every record
#   naming env is scanned whole.
# mutant:508-pg-rec-lost-always — makes the record-level fallback unconditional instead of push-
#   reachability gated, so an unsupported env option in a cut record denies even when no push can
#   follow.
case_push_rtexp_noop_env_c_status() {
  # An unsupported env option in a cut record denies only when a push can follow.
  rtx_noop 'env -C ${D} git status'
}
case_push_rtexp_noop_env_s_uncut() {
  rtx_noop 'env -S'"'"'echo hi'"'"' true; git push origin feature/x'
}
case_push_rtexp_noop_controls() {
  # Expansion text outside command position stays quiet, as does the skills' own worktree push shape.
  rtx_noop 'echo $X git push origin main && git push origin feature/x' \
    'git commit -m "$X git push origin main" && git push origin feature/x' \
    "$(printf 'cat <<EOF\nNote: $X git push origin main\nEOF\ngit push origin feature/x')" \
    'git -C "../demo-wt-1" push -u origin "claude/17-a"'
}
# pp_rx_flood_cmd N — one record per trigger shape at N tokens, then a real push so the hook reaches
# check_deadline after the tokenizer. pp_rx_flood_twin_cmd N is its mutant-invariant twin: the same
# layout, token count and byte length per token, but only the FIRST token of each record triggers.
pp_rx_flood_cmd() {
  local n="$1" r1 r2 r3 r4
  r1="sudo$(printf ' -$X%.0s' $(seq 1 "$n")) true"
  r2="git$(printf ' -$X%.0s' $(seq 1 "$n")) status"
  r3="env$(printf ' X=$Y%.0s' $(seq 1 "$n")) true"
  r4="$(printf '$X %.0s' $(seq 1 "$n"))true"
  printf '%s\n%s\n%s\n%s\ngit push origin feature/x' "$r1" "$r2" "$r3" "$r4"
}
pp_rx_flood_twin_cmd() {
  local n="$1" r1 r2 r3 r4 m=$(( $1 - 1 ))
  r1='sudo -$X'"$(printf ' -ab%.0s' $(seq 1 "$m"))"' true'
  r2='git -$X'"$(printf ' -ab%.0s' $(seq 1 "$m"))"' status'
  r3='env X=$Y'"$(printf ' X=ab%.0s' $(seq 1 "$m"))"' true'
  r4='$X '"$(printf 'ab %.0s' $(seq 1 "$m"))"'true'
  printf '%s\n%s\n%s\n%s\ngit push origin feature/x' "$r1" "$r2" "$r3" "$r4"
}
# mutant:508-pg-rx-scan-per-token — scans the rest of the segment at every detection site instead of
#   once after the walk, so the flood turns quadratic and overruns its calibrated deadline.
case_push_rtexpscan_noop_flood() {
  # FLOOD + TIMING, sized and bounded by cost RATIO from a same-run control, never by absolute speed,
  # exactly as case_push_lostscan_noop_flood does: the twin (one trigger per record) is timed with no
  # deadline, the flood's token count is scaled from it, and the flood runs under an active deadline
  # of K times the predicted linear cost.
  local dir="$tmpbase/repo-pp-flood" ctl_n=1000 min_n=700 max_n=10000 floor=2 k=8
  local target_ms=$(( DL_KNOB_MAX * 200 )) ctl_ms pred_ms
  mk_fixture_repo "$dir" main feature/x
  measure_ms run_push_guard "$(mk_push_cmd_big "$(pp_rx_flood_twin_cmd "$ctl_n")" "$dir")"
  ctl_ms="$measured_ms"
  if [ -z "$ctl_ms" ]; then
    __ok=0; __why="${__why}control run's own timing report could not be parsed — can't size the flood\n"
    return
  fi
  expect_push_no_opinion
  if [ "$__ok" -eq 0 ]; then
    __why="${__why}twin control did not return no opinion\n"
    return
  fi
  calibrated_flood_tokens "$ctl_ms" "$ctl_n" "$target_ms" "$min_n" "$max_n"
  pred_ms=$(( ctl_ms * flood_tokens / ctl_n ))
  calibrated_deadline "$floor" "$k" "$pred_ms"
  push_deadline_override="$calibrated_secs"
  measure_ms run_push_guard "$(mk_push_cmd_big "$(pp_rx_flood_cmd "$flood_tokens")" "$dir")"
  expect_push_no_opinion
  if [ "$__ok" -eq 0 ]; then
    __why="${__why}control ${ctl_ms}ms at ${ctl_n} -> ${flood_tokens} tokens, predicted ${pred_ms}ms -> deadline ${calibrated_secs}s, flood ${measured_ms}ms\n"
  fi
}

# --- git aliases and config relocation (#448, absorbs #450) ----------------------------------------
# Every non-push git segment is an alias candidate: the hook looks `alias.<subcmd>` up in the config it
# already reads and denies when the expansion could push (first word push, a `!` shell alias, an
# option, another defined alias, or a trailing-backslash continuation). Config it cannot read (inline
# or exported HOME=/XDG_CONFIG_HOME=/GIT_CONFIG_*, a -c/--config-env value naming alias or include)
# denies the candidate outright. Every fixture passes an explicit cwd (AMBIENT-$PWD RULE above), and
# the raw stdin of the config-file cases never contains the word push, so a re-added push fast path
# cannot hide them. Suffixes sit before -wt-<n>.
# mutant:448-pg-fastpath-push -- re-inserts the raw-stdin push fast path ahead of the git one, so a
#   config-file alias (no push literal anywhere in the command text) exits before the tokenizer.
# mutant:448-pg-fastpath-crlf -- same re-inserted fast path, killed by the carriage-return fixture.
# mutant:448-pg-alias-early-exit -- drops the ALIAS pattern from the pre-deadline early exit, so an
#   alias candidate never reaches the driver loop.
# mutant:448-pg-alias-emit -- blanks the ALIAS line the tokenizer prints for a non-push git segment.
# mutant:448-pg-alias-section -- makes the [alias] section header arm unmatchable, so no alias key is
#   ever recorded.
# mutant:448-pg-alias-shell -- drops the leading-! test from the alias classifier.
# mutant:448-pg-alias-dash -- drops the leading-dash test from the alias classifier.
# mutant:448-pg-alias-chain -- drops the names-another-defined-alias test from the alias classifier.
# mutant:448-pg-alias-fold -- drops the lowercase fold of the alias key.
# mutant:448-pg-alias-continuation -- drops the trailing-backslash test from the alias classifier.
# mutant:448-pg-alias-word-strip -- drops the quote and backslash strip of the expansion first word.
# mutant:448-pg-alias-c-target -- drops the resolved-checkout alias assignment in apply_c_target().
# mutant:448-pg-alias-session-restore -- drops the alias restore in apply_session_repo().
# mutant:448-pg-alias-cmdline -- stops treating a command-line alias or include as unreadable config.
# mutant:448-pg-alias-reloc-nonpush -- stops treating a relocation assignment on a non-push git
#   segment as unreadable config.
# mutant:448-pg-alias-xcfg -- drops the cross-segment config flag from the ALIAS arm of the driver.
# mutant:448-pg-alias-cmdline-text -- treats any command-line config as alias-bearing.
# mutant:448-pg-alias-name-match -- matches an alias record whatever its key is.
# mutant:448-pg-alias-classify-open -- makes every matching alias record deny.
# mutant:448-pg-alias-lost-prefix -- drops the alias lookup for a segment lost to a quoted prefix
#   assignment.
# mutant:448-pg-alias-lost-option -- drops the alias lookup for a segment lost to a quoted option.
# mutant:448-pg-alias-lost-reloc -- drops the relocation test for a lost segment.
# mutant:448-pg-alias-lost-needgit -- drops the names-git gate for a loss in the command prefix, so a
#   quote-split assignment in front of a command that never names git is treated as an alias candidate.
# mutant:448-pg-alias-subsection -- makes the [alias "<name>"] subsection header arm unmatchable, so a
#   command key under it is never recorded.
# mutant:448-pg-alias-escape -- drops the git-config whitespace escapes (backslash t, n, b) as word
#   breaks, so push followed by an escaped TAB or LF fuses into one word.
# mutant:448-pg-alias-cr-mid -- drops the interior-CR marker on an [alias] value, so a CR strictly
#   inside the line fuses the words around it.
# mutant:448-pg-alias-lost-quoted-reloc -- drops the quoted relocation or command-line-config
#   assignment test from emit_alias_lost().
# mutant:448-pg-alias-xcfg-export-cfg -- drops the GIT_CONFIG_* test from the exported-name arm of the
#   cross-segment config flag.
# mutant:448-pg-alias-xcfg-bare-cfg -- drops the GIT_CONFIG_* test from the bare-assignment arm of the
#   cross-segment config flag.
# mutant:448-pg-alias-dollar -- drops the dollar-sign test on command-line config of an alias candidate.
# mutant:448-pg-alias-subcmd-fold -- drops the lowercase fold of the subcommand in the ALIAS line.
# mutant:448-pg-alias-reset -- drops the alias-record reset in resolve_repo(), so the session records
#   leak into a resolved -C target.
# mutant:448-pg-alias-subsection-name -- reads a subsection alias only under a matching name, so a
#   subsection alias no longer denies every alias candidate of its checkout.
# mutant:448-pg-alias-subsection-space -- drops the blank-run alternative of the subsection header.
# mutant:448-pg-alias-subsection-tab -- drops the TAB alternative of the subsection header.
# mutant:448-pg-alias-subsection-dot -- drops the dotted alias header alternative.
# mutant:448-pg-alias-lost-quoted-cfg -- drops the GIT_CONFIG_* name tests from the embedded
#   assignment scan of a lost segment.
# mutant:448-pg-alias-lost-trigger-git -- drops the trigger token from the names-git gate of a lost
#   segment, so a relocation packed with git into one env -S token (backslash-underscore separators) is
#   not treated as an alias candidate.
# mutant:448-pg-alias-lost-substring -- makes the embedded assignment scan prefix-only, so an
#   assignment inside an env -S string no longer counts.
# mutant:448-pg-alias-backtick -- drops the backtick test on command-line config of an alias candidate.
# mutant:448-pg-alias-dollar-env -- drops the dollar-sign test on GIT_CONFIG_* assignment values.
# mutant:448-pg-alias-cr-mid-subsection -- drops the interior-CR marker on a subsection alias value.
al_cfg_body() { printf '[alias]\n\t%s\n' "$1"; }
al_run() { run_push_guard "$(mk_push_cmd_cwd "$1" "$2")"; }
al_expect_alias() {
  local src="$1"
  expect_push_deny
  case "$push_err" in
    *"(blocked: git alias may push)"*) ;;
    *) __ok=0; __why="${__why}stderr missing '(blocked: git alias may push)': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"$src"*) ;;
    *) __ok=0; __why="${__why}stderr does not name the source '$src': '$push_err'\n" ;;
  esac
}
al_expect_aliascfg() {
  expect_push_deny
  case "$push_err" in
    *"(blocked: unreadable git config may define an alias)"*) ;;
    *) __ok=0; __why="${__why}stderr missing '(blocked: unreadable git config may define an alias)': '$push_err'\n" ;;
  esac
}
# al_expect_no_echo TOKEN -- the deny line must never echo a command token, alias name or alias value.
al_expect_no_echo() {
  [ -n "$1" ] || { __ok=0; __why="${__why}al_expect_no_echo called with an empty TOKEN (needle_required)\n"; return; }
  case "$push_err" in
    *"$1"*) __ok=0; __why="${__why}stderr echoes '$1': '$push_err'\n" ;;
  esac
}
case_al_deny_repo_config() {
  local dir="$tmpbase/repo-al-repo"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = push')"
  al_run 'git zqp origin main' "$dir"
  al_expect_alias ".git/config"
  al_expect_no_echo "zqp"
}
case_al_deny_feature_dest() {
  local dir="$tmpbase/repo-al-feature"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'p = push')"
  al_run 'git p origin feature/x' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_global_config() {
  local dir="$tmpbase/repo-al-global" home="$tmpbase/home-al-global"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$home/.gitconfig" "$(al_cfg_body 'zqp = push')"
  push_home_override="$home"
  al_run 'git zqp origin main' "$dir"
  al_expect_alias "your global git config"
}
case_al_deny_xdg_config() {
  local dir="$tmpbase/repo-al-xdg" xdg="$tmpbase/xdg-al-xdg"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$xdg/git/config" "$(al_cfg_body 'zqp = push')"
  push_xdg_home="$xdg"
  al_run 'git zqp origin main' "$dir"
  al_expect_alias "your global git config"
}
case_al_deny_include() {
  local dir="$tmpbase/repo-al-include" inc="$tmpbase/inc-al-include.cfg"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$inc" "$(al_cfg_body 'zqp = push')"
  mk_fixture_config "$dir" "$(printf '[include]\n\tpath = %s\n' "$inc")"
  al_run 'git zqp origin main' "$dir"
  al_expect_alias ".git/config (via include)"
}
case_al_deny_shell() {
  local dir="$tmpbase/repo-al-shell"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = !git push origin main')"
  al_run 'git zqp' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_option_first() {
  local dir="$tmpbase/repo-al-option"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = --no-pager push')"
  al_run 'git zqp origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_chain() {
  local dir="$tmpbase/repo-al-chain"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(printf '[alias]\n\ta = b\n\tb = push\n')"
  al_run 'git a origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_case_fold() {
  local dir="$tmpbase/repo-al-fold"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(printf '[ALIAS]\n\tZp = PUSH\n')"
  al_run 'git zp origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_continuation() {
  # alias.p is pu, a backslash, a newline, then sh: the line parser never joins the continuation.
  local dir="$tmpbase/repo-al-continuation"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(printf '[alias]\n\tzqp = pu\\\n\tsh\n')"
  al_run 'git zqp origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_quoted_word() {
  local dir="$tmpbase/repo-al-quoted"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = "pu\"s\"h"')"
  al_run 'git zqp origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_c_target() {
  # The alias lives only in the resolved -C worktree, never in the session checkout.
  local dir="$tmpbase/repo-al-ctarget" wt="$tmpbase/alctarget-wt-1"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_repo "$wt" main feature/x
  mk_fixture_config "$wt" "$(al_cfg_body 'zqp = push')"
  al_run 'git -C ../alctarget-wt-1 zqp origin feature/x' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_session_after_c_target() {
  # An earlier -C segment resolves a checkout with no alias; the session alias must be restored for
  # the next segment.
  local dir="$tmpbase/repo-al-session" wt="$tmpbase/alsession-wt-1"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_repo "$wt" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = push')"
  al_run 'git -C ../alsession-wt-1 status; git zqp origin feature/x' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_cmdline_c() {
  local dir="$tmpbase/repo-al-cmdline"
  mk_fixture_repo "$dir" main feature/x
  al_run 'git -c alias.p=push p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_cmdline_include() {
  local dir="$tmpbase/repo-al-cmdline-include"
  mk_fixture_repo "$dir" main feature/x
  al_run 'git -c include.path=/x p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_config_env() {
  local dir="$tmpbase/repo-al-config-env"
  mk_fixture_repo "$dir" main feature/x
  al_run 'git --config-env=alias.p=PV p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_env_key() {
  local dir="$tmpbase/repo-al-env-key"
  mk_fixture_repo "$dir" main feature/x
  al_run 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.p GIT_CONFIG_VALUE_0=push git p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_home_nonpush() {
  local dir="$tmpbase/repo-al-home-nonpush"
  mk_fixture_repo "$dir" main feature/x
  al_run "HOME=$tmpbase/home-al-nonpush git p origin main" "$dir"
  al_expect_aliascfg
}
case_al_deny_env_xdg_nonpush() {
  local dir="$tmpbase/repo-al-xdg-nonpush"
  mk_fixture_repo "$dir" main feature/x
  al_run 'env XDG_CONFIG_HOME=/x git p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_global_env_nonpush() {
  local dir="$tmpbase/repo-al-global-nonpush"
  mk_fixture_repo "$dir" main feature/x
  al_run 'GIT_CONFIG_GLOBAL=/x git p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_xcfg_export_home() {
  local dir="$tmpbase/repo-al-xcfg-export"
  mk_fixture_repo "$dir" main feature/x
  al_run 'export HOME=/x; git p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_xcfg_bare_xdg() {
  local dir="$tmpbase/repo-al-xcfg-bare"
  mk_fixture_repo "$dir" main feature/x
  al_run 'XDG_CONFIG_HOME=/x; git p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_quoted_option() {
  # #449 interplay: the quoted -c option is lost to the tokenizer; the push word in its value makes
  # it a lost push segment, denied through #449's own fixed reason.
  local dir="$tmpbase/repo-al-quoted-option"
  mk_fixture_repo "$dir" main feature/x
  al_run 'git "-c" alias.p=push p origin main' "$dir"
  expect_push_deny
}
case_al_deny_quoted_space_assign() {
  # #449 interplay: the quoted assignment splits at its space, so the real command word is lost. The
  # HOME relocation it carries makes the rest of the segment an alias candidate that denies.
  local dir="$tmpbase/repo-al-quoted-assign"
  mk_fixture_repo "$dir" main feature/x
  al_run 'HOME="/tmp/a b" git p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_lost_prefix_config() {
  # #449 interplay: X="a b" leaves a bogus command word; the alias is still looked up for every later
  # token, so a config-file alias behind it denies.
  local dir="$tmpbase/repo-al-lost-prefix"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = push')"
  al_run 'X="a b" git zqp origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_lost_option_config() {
  # #449 interplay: a quoted option the tokenizer cannot follow must not hide the alias behind it.
  local dir="$tmpbase/repo-al-lost-option"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = push')"
  al_run 'git "--no-pager" zqp origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_lost_value_config() {
  # #449 interplay: a quoted -c value split at its space leaves junk fragments; the real subcommand
  # after them is still looked up.
  local dir="$tmpbase/repo-al-lost-value"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = push')"
  al_run 'git -c "user.name=A B" zqp origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_lost_reloc_prefix() {
  # #449 interplay: a quoted relocation assignment in front of a lost segment that names git.
  local dir="$tmpbase/repo-al-lost-reloc"
  mk_fixture_repo "$dir" main feature/x
  al_run 'env XDG_CONFIG_HOME="/a b" git p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_codex_shaped() {
  # Not suffixed -deny-codex-main-session: 494-pg-wd-precedence filters on that substring.
  local dir="$tmpbase/repo-al-codex"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = push')"
  run_push_guard "$(mk_codex_shell '' 'git zqp origin main' "$dir")"
  al_expect_alias ".git/config"
}
case_al_deny_never_executes() {
  local dir="$tmpbase/repo-al-never-executes"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = push')"
  local trapdir="$tmpbase/trapbin-al-never-executes" sentinel="$tmpbase/sentinel-al-never-executes"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before after
  before="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  run_push_guard "$(mk_push_cmd_cwd 'git zqp origin main' "$dir")" "$trapdir:$PATH"
  after="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  al_expect_alias ".git/config"
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH while denying an alias\n"; }
  [ "$before" = "$after" ] || { __ok=0; __why="${__why}fixture repo's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
}
case_al_noop_nonpush_alias() {
  local dir="$tmpbase/repo-al-noop-nonpush"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'st = status')"
  al_run 'git st' "$dir"
  expect_push_no_opinion
}
case_al_noop_builtins_with_push_alias() {
  local dir="$tmpbase/repo-al-noop-builtins"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'p = push')"
  al_run 'git status && git log --oneline -5 && git diff' "$dir"
  expect_push_no_opinion
}
case_al_noop_undefined_subcommand() {
  local dir="$tmpbase/repo-al-noop-undefined"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'p = push')"
  al_run 'git lfs pull' "$dir"
  expect_push_no_opinion
}
case_al_noop_other_alias_word() {
  local dir="$tmpbase/repo-al-noop-other"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(printf '[alias]\n\tco = checkout\n\tp = push\n')"
  al_run 'git co main' "$dir"
  expect_push_no_opinion
}
case_al_noop_c_benign() {
  local dir="$tmpbase/repo-al-noop-c-benign"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'st = status')"
  al_run 'git -c core.pager=cat st' "$dir"
  expect_push_no_opinion
}
case_al_noop_env_nosystem() {
  local dir="$tmpbase/repo-al-noop-nosystem"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'st = status')"
  al_run 'GIT_CONFIG_NOSYSTEM=1 git st' "$dir"
  expect_push_no_opinion
}
case_al_noop_scoped_home() {
  # The HOME assignment belongs to the ls segment only; the git segment is judged on its own.
  local dir="$tmpbase/repo-al-noop-scoped"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'st = status')"
  al_run 'HOME=/x ls; git st' "$dir"
  expect_push_no_opinion
}
case_al_noop_harness_shapes() {
  local dir="$tmpbase/repo-al-noop-harness"
  mk_fixture_repo "$dir" main claude/17-a
  mk_fixture_config "$dir" "$(printf '[alias]\n\tp = push\n\tup = !git pull\n')"
  al_run 'git add -A && git commit -m "x" && git push -u origin "claude/17-a"' "$dir"
  expect_push_no_opinion
}
case_al_noop_quoted_prefix_nonalias() {
  # A quoted-space assignment before an ordinary built-in stays no opinion, alias config present.
  local dir="$tmpbase/repo-al-noop-quoted-prefix"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'p = push')"
  al_run 'X="a b" git status' "$dir"
  expect_push_no_opinion
}
case_al_noop_quoted_option_nonalias() {
  local dir="$tmpbase/repo-al-noop-quoted-option"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'p = push')"
  al_run 'git "--no-pager" log -5' "$dir"
  expect_push_no_opinion
}
case_al_noop_lost_no_git() {
  # A quote-split assignment in front of a command that never names git, mentioning alias text: with
  # no later git token the lost segment is not an alias candidate. The fixture directory name carries
  # the git literal the raw-stdin fast path needs.
  local dir="$tmpbase/repo-al-lost-no-git-gitdir"
  mk_fixture_repo "$dir" main feature/x
  al_run 'X="a b" echo alias include' "$dir"
  expect_push_no_opinion
}
case_al_deny_subsection_repo() {
  local dir="$tmpbase/repo-al-subsection"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(printf '[alias "zqp"]\n\tcommand = push\n')"
  al_run 'git zqp origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_subsection_global() {
  local dir="$tmpbase/repo-al-subsection-global" home="$tmpbase/home-al-subsection"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$home/.gitconfig" "$(printf '[alias "zqp"]\n\tcommand = push\n')"
  push_home_override="$home"
  al_run 'git zqp origin main' "$dir"
  al_expect_alias "your global git config"
}
case_al_noop_subsection() {
  local dir="$tmpbase/repo-al-noop-subsection"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(printf '[alias "st"]\n\tcommand = status\n\n[alias "zqp"]\n\tother = push\n')"
  al_run 'git st && git zqp' "$dir"
  expect_push_no_opinion
}
case_al_deny_escape_tab() {
  # git-config escapes the TAB as backslash t, and git splits the alias at whitespace: the first word is push.
  local dir="$tmpbase/repo-al-escape-tab"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = push\torigin')"
  al_run 'git zqp main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_escape_newline() {
  local dir="$tmpbase/repo-al-escape-newline"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = push\norigin')"
  al_run 'git zqp main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_cr_mid() {
  # A raw CR strictly inside the line is stripped by the line reader, which would fuse push and origin.
  local dir="$tmpbase/repo-al-cr-mid"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body "zqp = push${CR}origin")"
  al_run 'git zqp main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_cr_mid_subsection() {
  local dir="$tmpbase/repo-al-cr-mid-sub"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(printf '[alias "zqp"]\n\tcommand = push%sorigin\n' "$CR")"
  al_run 'git zqp main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_env_quoted_home() {
  local dir="$tmpbase/repo-al-env-qhome"
  mk_fixture_repo "$dir" main feature/x
  al_run "env \"HOME=$tmpbase/home-al-qhome\" git p origin main" "$dir"
  al_expect_aliascfg
}
case_al_deny_env_squoted_xdg() {
  local dir="$tmpbase/repo-al-env-qxdg"
  mk_fixture_repo "$dir" main feature/x
  al_run "env 'XDG_CONFIG_HOME=/x' git p origin main" "$dir"
  al_expect_aliascfg
}
case_al_deny_command_env_quoted() {
  local dir="$tmpbase/repo-al-command-env"
  mk_fixture_repo "$dir" main feature/x
  al_run "command env \"HOME=$tmpbase/home-al-cenv\" git p origin main" "$dir"
  al_expect_aliascfg
}
case_al_deny_env_s_reloc() {
  local dir="$tmpbase/repo-al-env-s"
  mk_fixture_repo "$dir" main feature/x
  al_run "env -S \"HOME=$tmpbase/home-al-envs git p origin main\"" "$dir"
  al_expect_aliascfg
}
case_al_deny_xcfg_export_gitconfig() {
  local dir="$tmpbase/repo-al-xcfg-export-cfg"
  mk_fixture_repo "$dir" main feature/x
  al_run 'export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.p GIT_CONFIG_VALUE_0=push; git p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_xcfg_export_parameters() {
  local dir="$tmpbase/repo-al-xcfg-export-params"
  mk_fixture_repo "$dir" main feature/x
  al_run 'export GIT_CONFIG_PARAMETERS=x; git p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_xcfg_bare_gitconfig() {
  local dir="$tmpbase/repo-al-xcfg-bare-cfg"
  mk_fixture_repo "$dir" main feature/x
  al_run 'GIT_CONFIG_COUNT=1; git p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_dollar_c() {
  # A variable builds the config key at run time, which the hook cannot expand.
  local dir="$tmpbase/repo-al-dollar-c"
  mk_fixture_repo "$dir" main feature/x
  al_run 'K=alias.p; git -c $K=push p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_dollar_env_key() {
  local dir="$tmpbase/repo-al-dollar-env"
  mk_fixture_repo "$dir" main feature/x
  al_run 'K=alias.p; GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=$K GIT_CONFIG_VALUE_0=push git p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_dollar_parameters() {
  local dir="$tmpbase/repo-al-dollar-params"
  mk_fixture_repo "$dir" main feature/x
  al_run 'GIT_CONFIG_PARAMETERS=$X git p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_dollar_subst() {
  # The command substitution splits the segment, so the subcommand is never reached in it.
  local dir="$tmpbase/repo-al-dollar-subst"
  mk_fixture_repo "$dir" main feature/x
  al_run 'git -c "$(echo alias.p)=push" p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_subcmd_fold() {
  # git matches an alias key case-insensitively.
  local dir="$tmpbase/repo-al-subcmd-fold"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = push')"
  al_run 'git ZQP origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_noop_c_target_clean() {
  # The session defines a push alias; the resolved -C checkout defines none, so its own records decide.
  local dir="$tmpbase/repo-al-clean-session" wt="$tmpbase/alclean-wt-1"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_repo "$wt" main feature/x
  mk_fixture_config "$dir" "$(al_cfg_body 'zqp = push')"
  al_run 'git -C ../alclean-wt-1 zqp origin feature/x' "$dir"
  expect_push_no_opinion
}
case_al_deny_subsection_spaces() {
  local dir="$tmpbase/repo-al-sub-spaces"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(printf '[alias   "zqp"]\n\tcommand = push\n')"
  al_run 'git zqp origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_subsection_tab() {
  local dir="$tmpbase/repo-al-sub-tab"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(printf '[alias\t"zqp"]\n\tcommand = push\n')"
  al_run 'git zqp origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_subsection_dotted() {
  local dir="$tmpbase/repo-al-sub-dotted"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(printf '[alias.zqp]\n\tcommand = push\n')"
  al_run 'git zqp origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_subsection_escaped_name() {
  # The name is a backslash then p, which git reads as p: the name is never read here, so it cannot be misread.
  local dir="$tmpbase/repo-al-sub-escaped"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(printf '[alias "\\zqp"]\n\tcommand = push\n')"
  al_run 'git zqp origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_subsection_odd_name() {
  # A name holding a blank (run as a quoted subcommand) and a name holding a slash.
  local dir="$tmpbase/repo-al-sub-odd"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(printf '[alias "p q"]\n\tcommand = push\n')"
  al_run 'git "p q" origin main' "$dir"
  al_expect_alias ".git/config"
  mk_fixture_config "$dir" "$(printf '[alias "a/p"]\n\tcommand = push\n')"
  al_run 'git a/p origin main' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_subsection_any_subcommand() {
  # Over-block, deliberate: a push-ish subsection alias makes every alias candidate of the checkout deny.
  local dir="$tmpbase/repo-al-sub-any"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(printf '[alias "zqp"]\n\tcommand = push\n')"
  al_run 'git status' "$dir"
  al_expect_alias ".git/config"
}
case_al_deny_env_s_attached() {
  local dir="$tmpbase/repo-al-env-s-att"
  mk_fixture_repo "$dir" main feature/x
  al_run 'env -S"HOME=/x git p origin main"' "$dir"
  al_expect_aliascfg
}
case_al_deny_env_s_squoted() {
  local dir="$tmpbase/repo-al-env-s-sq"
  mk_fixture_repo "$dir" main feature/x
  al_run "env -S'XDG_CONFIG_HOME=/x git p origin main'" "$dir"
  al_expect_aliascfg
}
case_al_deny_env_split_string() {
  local dir="$tmpbase/repo-al-env-split"
  mk_fixture_repo "$dir" main feature/x
  al_run 'env --split-string="HOME=/x git p origin main"' "$dir"
  al_expect_aliascfg
}
case_al_deny_env_s_underscore_all() {
  local dir="$tmpbase/repo-al-env-s-us-all"
  mk_fixture_repo "$dir" main feature/x
  al_run 'env -S"HOME=/x\_git\_p\_origin\_main"' "$dir"
  al_expect_aliascfg
}
case_al_deny_env_s_underscore_git() {
  local dir="$tmpbase/repo-al-env-s-us-git"
  mk_fixture_repo "$dir" main feature/x
  al_run 'env -S"HOME=/x\_git" p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_env_quoted_gitconfig() {
  local dir="$tmpbase/repo-al-env-qcfg"
  mk_fixture_repo "$dir" main feature/x
  al_run 'env "GIT_CONFIG_PARAMETERS=$X" git p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_backtick_quoted() {
  # The backtick cuts the segment inside the quoted key, so the -c value is never seen whole.
  local dir="$tmpbase/repo-al-bt-quoted"
  mk_fixture_repo "$dir" main feature/x
  al_run 'git -c "`echo alias.p`=push" p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_backtick_bare() {
  local dir="$tmpbase/repo-al-bt-bare"
  mk_fixture_repo "$dir" main feature/x
  al_run 'git -c `echo alias.p`=push p origin main' "$dir"
  al_expect_aliascfg
}
case_al_deny_backtick_config_env() {
  local dir="$tmpbase/repo-al-bt-cenv"
  mk_fixture_repo "$dir" main feature/x
  al_run 'git --config-env "`echo alias.p`=PV" p origin main' "$dir"
  al_expect_aliascfg
}
case_al_noop_dollar_not_config() {
  # A dollar sign outside the config VALUE tokens is no reason to deny.
  local dir="$tmpbase/repo-al-dollar-noop"
  mk_fixture_repo "$dir" main feature/x
  al_run 'git -c color.ui=false -C "$WT" status' "$dir"
  expect_push_no_opinion
  al_run 'X=$Y GIT_CONFIG_COUNT=0 git log' "$dir"
  expect_push_no_opinion
}
case_al_deny_flood() {
  # mutant:448-pg-aliasdl-check-off -- FLOOD + TIMING, calibrated by dl_site_run's same-run knob-0
  # control. 3000 alias candidates that each resolve cleanly (st = status), then one that denies as
  # a push alias: only the driver loop's own per-line check_deadline can stop the flood, so the line
  # printed is the deadline one, never the alias one. With the sample neutered the knob-0 control
  # cannot print the deadline line and the case fails there.
  # The candidate count is sized from a same-run per-candidate cost, measured on a small flood as the
  # wall time of an unbudgeted run minus its knob-0 control (the unsampled prefix), so the work clearly
  # exceeds the largest knob (DL_KNOB_MAX seconds) by a factor of three on any host and shell.
  local dir="$tmpbase/repo-al-flood" flood payload small t0 ms0 c_us n
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" "$(printf '[alias]\n\tst = status\n\tp = push\n')"
  small="$(mk_push_cmd_big "$(printf 'git st;%.0s' $(seq 1 300))git p origin main" "$dir")"
  push_deadline_override=9
  measure_ms run_push_guard "$small"
  t0="$measured_ms"
  push_budget_override="0"
  push_deadline_override=9
  measure_ms run_push_guard "$small"
  ms0="$measured_ms"
  if [ -z "$t0" ] || [ -z "$ms0" ]; then
    __ok=0; __why="${__why}per-candidate cost control's timing report could not be parsed\n"
    return
  fi
  c_us=$(( (t0 - ms0) * 1000 / 300 ))
  [ "$c_us" -ge 100 ] || c_us=100
  n=$(( DL_KNOB_MAX * 3000000 / c_us ))
  [ "$n" -ge 3000 ] || n=3000
  [ "$n" -le 40000 ] || n=40000
  flood="$(printf 'git st;%.0s' $(seq 1 "$n"))"
  payload="$(mk_push_cmd_big "${flood}git p origin main" "$dir")"
  dl_site_run "$payload"
}
case_al_deny_budget_zero() {
  # mutant:448-pg-alias-early-exit -- an alias candidate reaches the deadline sample: a bare
  # git log is no push, yet at knob 0 it must deny with the deadline line, because the early exit no
  # longer hides a command that could still run an alias.
  local dir="$tmpbase/repo-al-budget-zero"
  mk_fixture_repo "$dir" main feature/x
  push_budget_override="0"
  run_push_guard "$(mk_push_cmd_big 'git log' "$dir")"
  expect_push_deny_exact "$DL_DEADLINE_LINE"
}
# --- #450: an inline HOME=/XDG_CONFIG_HOME= relocation on a push segment -----------------------
# mutant:448-pg-reloc-vocab -- empties the relocation vocabulary, so no assignment is ever flagged.
# mutant:448-pg-reloc-push-sentinel -- deletes the push-segment relocation deny.
# mutant:448-pg-reloc-xseg -- deletes the HOME/XDG cross-segment block.
# mutant:448-pg-reloc-exact -- widens relocation membership to any name containing HOME.
# mutant:448-pg-reloc-scoped -- drops the command-word-empty guard from the bare-assignment arm of the
#   HOME/XDG cross-segment rule, so a HOME assignment scoped to another command flags the whole command.
# mutant:448-pg-alias-xcfg-scoped -- drops the same guard from the cross-segment config flag, so a HOME
#   assignment scoped to an ls segment makes a later alias candidate deny.
al_expect_reloc() {
  expect_push_deny
  case "$push_err" in
    *"git config supplied on the command line"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'git config supplied on the command line': '$push_err'\n" ;;
  esac
}
case_rl_deny_home_inline() {
  # The orchestrator's shape: HOME names a directory whose .gitconfig carries a push route to main.
  local dir="$tmpbase/repo-rl-home" home="$tmpbase/home-rl-inline"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$home/.gitconfig" "$(printf '[remote "origin"]\n\tpush = HEAD:main\n')"
  al_run "HOME=$home git push" "$dir"
  al_expect_reloc
}
case_rl_deny_xdg_inline() {
  local dir="$tmpbase/repo-rl-xdg"
  mk_fixture_repo "$dir" main feature/x
  al_run 'XDG_CONFIG_HOME=/nonexistent git push origin feature/x' "$dir"
  al_expect_reloc
}
case_rl_deny_env_home() {
  local dir="$tmpbase/repo-rl-env"
  mk_fixture_repo "$dir" main feature/x
  al_run 'env HOME=/nonexistent git push origin feature/x' "$dir"
  al_expect_reloc
}
case_rl_deny_xseg_export_home() {
  local dir="$tmpbase/repo-rl-xseg-export"
  mk_fixture_repo "$dir" main feature/x
  al_run 'export HOME=/x; git push origin feature/x' "$dir"
  expect_push_deny
  case "$push_err" in
    *"(HOME or XDG_CONFIG_HOME set earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing '(HOME or XDG_CONFIG_HOME set earlier in this command)': '$push_err'\n" ;;
  esac
}
case_rl_deny_xseg_bare_xdg() {
  local dir="$tmpbase/repo-rl-xseg-bare"
  mk_fixture_repo "$dir" main feature/x
  al_run 'XDG_CONFIG_HOME=/x; git push origin feature/x' "$dir"
  expect_push_deny
  case "$push_err" in
    *"(HOME or XDG_CONFIG_HOME set earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing '(HOME or XDG_CONFIG_HOME set earlier in this command)': '$push_err'\n" ;;
  esac
}
case_rl_noop_similar_name() {
  local dir="$tmpbase/repo-rl-similar"
  mk_fixture_repo "$dir" main feature/x
  al_run 'HOMEBREW_NO_AUTO_UPDATE=1 git push origin feature/x' "$dir"
  expect_push_no_opinion
}
case_rl_noop_scoped() {
  local dir="$tmpbase/repo-rl-scoped"
  mk_fixture_repo "$dir" main feature/x
  al_run 'HOME=/x ls; git push origin feature/x' "$dir"
  expect_push_no_opinion
}
case_pd_crlf_push_literal() {
  # A carriage return inside the push subcommand literal: the #270 strip runs after the jq
  # extraction, so with no raw-stdin push fast path the command now reaches the tokenizer as git
  # push origin main and denies.
  run_push_guard "$(mk_push_cmd "git pu${CR}sh origin main")"
  expect_push_deny
}

# --- cross-segment ("xseg"): a cd/pushd/popd/chdir or a GIT_DIR-family export/assignment in
# another segment of the same push command denies as unresolved (#433) ------------------------
# mutant:433-pg-dir-vocab -- empties PUSH_DIR_CHANGE_WORDS, so no cd/pushd/popd/chdir segment is
#   ever flagged.
# mutant:433-pg-export-vocab -- empties PUSH_EXPORT_WORDS, so no export-family segment is ever
#   flagged.
# mutant:433-pg-export-exact -- widens the export-arm's own membership check from exact
#   GIT_REPO_ENV_VARS membership to any nonempty name, so an unrelated export like GIT_TRACE=1 is
#   wrongly flagged too (and, since the arm now stops at the FIRST nonempty token, an option token
#   like "-gx"/"-x" between the export word and the real assignment is wrongly captured instead).
# mutant:433-pg-bare-assign -- disables the bare-assignment-only-segment arm, so a segment made
#   only of a GIT_REPO_ENV_VARS assignment (e.g. "GIT_DIR=../x/.git;") is no longer flagged.
# mutant:433-pg-per-record-reset -- resets xseg to "" at the head of every awk record, so a flag
#   set on an earlier LINE of a multiline command is lost by the time the push line's own record
#   runs.
# mutant:433-pg-fallback-drop -- disables the driver's post-loop xseg fallback outright, so no
#   cross-segment deny ever fires.
# mutant:433-pg-export-quotes -- stops stripping quotes from the export arm's own tokens, so a
#   quoted `export "GIT_DIR=…"` is no longer recognised as naming GIT_DIR.
# mutant:433-pg-cfg-export -- disables the export arm for #439's GIT_CONFIG_* names, so an
#   exported GIT_CONFIG_COUNT/GIT_CONFIG_KEY_<n> in another segment is no longer flagged.
# mutant:433-pg-cfg-bare -- disables the bare-assignment arm for #439's GIT_CONFIG_* names.
# mutant:433-pg-cfg-prefix -- drops the GIT_CONFIG_KEY_/GIT_CONFIG_VALUE_ prefix match, so only
#   the exact GIT_CMDCFG_ENV_VARS names are recognised.
# mutant:433-pg-cfg-exact -- widens the exact-name test to any GIT_CONFIG_-prefixed name, so an
#   unrelated export like GIT_CONFIG_NOSYSTEM=1 is wrongly flagged.
# mutant:433-pg-cfg-strip -- stops stripping "=value" from an exported token before the name test,
#   so an exact-name export with a value (GIT_CONFIG_GLOBAL=…) is no longer recognised.
# mutant:433-pg-cfg-bare-only -- drops the "bare segment only" limit of the GIT_CONFIG_* assignment
#   arm, so a GIT_CONFIG_* assignment scoped to another command (GIT_CONFIG_COUNT=1 git log) wrongly
#   flags a later push too.
#
# The fallback's own "$deny_dest already set" guard (an in-segment reason must keep precedence,
# pinned by push-xseg-deny-inseg-precedence below) has no dedicated mutant record: the "-xseg-"
# marker is always the LAST line of scan_out (awk's END runs only after every per-record print),
# so by construction any earlier break out of the driver loop (an in-segment deny of any kind)
# already happens before that line is ever read, leaving xseg_reason empty whenever deny_dest is
# already set -- no edit to that one guard alone can ever change an observed verdict. It stays in
# the driver as forward-proofing for any future deny_dest producer that runs outside this loop.
#
# Every deny fixture below builds its session with mk_fixture_repo (default branch "main", current
# branch "claude/17-a") and passes an explicit cwd via mk_push_cmd_cwd; the destination is
# "develop" (or a bare "git push"), which gets no opinion without this change.
case_px_deny_cd_and() {
  local main="$tmpbase/repo-px-1"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'cd ../other-x1 && git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(cd/pushd/popd earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_cd_bare_push() {
  local main="$tmpbase/repo-px-2"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'cd ../other-x2; git push' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(cd/pushd/popd earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_pushd() {
  local main="$tmpbase/repo-px-3"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'pushd ../other-x3 && git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(cd/pushd/popd earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_popd() {
  local main="$tmpbase/repo-px-4"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'popd; git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(cd/pushd/popd earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_chdir() {
  local main="$tmpbase/repo-px-5"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'chdir ../other-x5; git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(cd/pushd/popd earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_subshell() {
  local main="$tmpbase/repo-px-6"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd '( cd ../other-x6; git push origin develop )' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(cd/pushd/popd earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_builtin_cd() {
  local main="$tmpbase/repo-px-7"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'builtin cd ../other-x7 && git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(cd/pushd/popd earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_bash_c() {
  local main="$tmpbase/repo-px-8"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd "bash -c 'cd ../other-x8 && git push origin develop'" "$main")"
  expect_push_deny
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(cd/pushd/popd earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_eval() {
  local main="$tmpbase/repo-px-9"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd "eval 'cd ../other-x9; git push origin develop'" "$main")"
  expect_push_deny
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(cd/pushd/popd earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_multiline() {
  # Carries the xseg flag across TWO awk records (the cd line, then the push line) -- pins the
  # per-command, never-per-record, global flag design (mutant:433-pg-per-record-reset).
  local main="$tmpbase/repo-px-10"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd "cd ../other-x10${LF}git push origin develop" "$main")"
  expect_push_deny
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(cd/pushd/popd earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_dbracket_tail() {
  # The "cd" is seen only by the additive "]]" pass, AFTER the push line above it is already
  # emitted -- pins the order-independent END-marker design (a follows-only check applied at
  # emission time would miss exactly this zsh short "if [[ ... ]] cmd" tail).
  local main="$tmpbase/repo-px-11"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'if [[ -d ../other-x11 ]] cd ../other-x11; git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(cd/pushd/popd earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_push_before_cd() {
  # The push segment comes BEFORE the cd segment -- pins the chosen order-independence (the same
  # END-marker mechanism the dbracket-tail fixture above pins from the other direction).
  local main="$tmpbase/repo-px-12"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'git push origin develop && cd ..' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(cd/pushd/popd earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_export_git_dir() {
  local main="$tmpbase/repo-px-13"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'export GIT_DIR=../other-x13/.git; git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(GIT_DIR set earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(GIT_DIR set earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_export_name_only() {
  local main="$tmpbase/repo-px-14"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'export GIT_DIR && git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(GIT_DIR set earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(GIT_DIR set earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_export_quoted() {
  local main="$tmpbase/repo-px-export-quoted"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'export "GIT_DIR=../other-xq/.git"; git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(GIT_DIR set earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(GIT_DIR set earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_export_git_config() {
  local main="$tmpbase/repo-px-export-cfg"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.push GIT_CONFIG_VALUE_0=HEAD:main; git push' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(GIT_CONFIG_* set earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(GIT_CONFIG_* set earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_export_git_config_key() {
  local main="$tmpbase/repo-px-export-cfg-key"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'export GIT_CONFIG_KEY_9zq=remote.origin.push; git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(GIT_CONFIG_* set earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(GIT_CONFIG_* set earlier in this command)': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *9zq*) __ok=0; __why="${__why}stderr echoes the input-derived name suffix: '$push_err'\n" ;;
  esac
}
case_px_deny_export_git_config_exact() {
  local main="$tmpbase/repo-px-export-cfg-exact"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'export GIT_CONFIG_GLOBAL=../other-xg/cfg; git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(GIT_CONFIG_* set earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(GIT_CONFIG_* set earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_noop_git_config_scoped() {
  # A GIT_CONFIG_* assignment scoped to another command's own environment never reaches the push.
  local dir="$tmpbase/repo-px-git-config-scoped"
  mk_fixture_repo "$dir" main feature/x
  run_push_guard "$(mk_push_cmd_cwd 'GIT_CONFIG_COUNT=1 git log; git push origin feature/x' "$dir")"
  expect_push_no_opinion
}
case_px_deny_bare_git_config() {
  local main="$tmpbase/repo-px-bare-cfg"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'GIT_CONFIG_COUNT=1; git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(GIT_CONFIG_* set earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(GIT_CONFIG_* set earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_noop_export_git_config_nosystem() {
  # GIT_CONFIG_NOSYSTEM only removes a config source; it is not in #439's vocabulary.
  run_push_guard "$(mk_push_cmd 'export GIT_CONFIG_NOSYSTEM=1; git push origin feature/x')"
  expect_push_no_opinion
}
case_px_deny_declare_gx_work_tree() {
  local main="$tmpbase/repo-px-15"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'declare -gx GIT_WORK_TREE=../other-x15; git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(GIT_WORK_TREE set earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(GIT_WORK_TREE set earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_typeset_common_dir() {
  local main="$tmpbase/repo-px-16"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'typeset -x GIT_COMMON_DIR=../other-x16/.git; git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(GIT_COMMON_DIR set earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(GIT_COMMON_DIR set earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_bare_assign() {
  # A segment made of ONLY a GIT_REPO_ENV_VARS assignment, no "git"/command word at all in that
  # segment -- pins the third ("cmdword == \"\" && unres != \"\"") arm.
  local main="$tmpbase/repo-px-17"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'GIT_DIR=../other-x17/.git; git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(GIT_DIR set earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(GIT_DIR set earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_inseg_precedence() {
  # The push segment's OWN in-segment reason (#292's "--git-dir") keeps precedence over the
  # cross-segment fallback below it -- see the section header above for why the driver's own
  # "$deny_dest already set" guard has no dedicated mutant record of its own.
  local main="$tmpbase/repo-px-18"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'cd ../other-x18 && git --git-dir=../other-x18/.git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(--git-dir)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(--git-dir)': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"cd/pushd/popd"*)
      __ok=0; __why="${__why}stderr unexpectedly contains 'cd/pushd/popd' -- the push segment's own in-segment reason must keep precedence: '$push_err'\n"
      ;;
    *) ;;
  esac
}
case_px_deny_codex_main_session() {
  local main="$tmpbase/repo-px-19"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_codex_shell '' 'cd ../other-x19 && git push origin develop' "$main")"
  expect_push_deny
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(cd/pushd/popd earlier in this command)': '$push_err'\n" ;;
  esac
}
case_px_deny_never_executes() {
  # Safety property on the new cross-segment ("xseg") route: the cd-and shape, its own dirs, a
  # booby-trapped PATH (the same C1/C2 idiom case_pu_deny_never_executes above uses) -- deny,
  # sentinel absent, and BOTH the session repo's and the other checkout's file listings byte-
  # identical before/after.
  local main="$tmpbase/repo-px-never-executes" other="$tmpbase/other-px-never-executes"
  mk_fixture_repo "$main" main "claude/17-a"
  mk_fixture_repo "$other" develop "feature/x"
  local trapdir="$tmpbase/trapbin-px-never-executes" sentinel="$tmpbase/sentinel-px-never-executes"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before_main after_main before_other after_other
  before_main="$(find "$main" -type f -exec ls -la {} \; | sort)"
  before_other="$(find "$other" -type f -exec ls -la {} \; | sort)"
  run_push_guard "$(mk_push_cmd_cwd 'cd ../other-px-never-executes && git push origin develop' "$main")" "$trapdir:$PATH"
  after_main="$(find "$main" -type f -exec ls -la {} \; | sort)"
  after_other="$(find "$other" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(cd/pushd/popd earlier in this command)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '(cd/pushd/popd earlier in this command)': '$push_err'\n" ;;
  esac
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH while denying a cross-segment cd\n"; }
  [ "$before_main" = "$after_main" ] || { __ok=0; __why="${__why}session repo's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
  [ "$before_other" = "$after_other" ] || { __ok=0; __why="${__why}other checkout's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
}
case_px_noop_cd_no_push() {
  # Contains "push" and "git" but has no PUSH segment at all. Since #448 its git log segment is an
  # alias candidate (an ALIAS line), so the scan passes the pre-deadline early exit with #433's
  # cross-segment marker still in it, and only the driver's own "saw_push" guard keeps the cd from
  # denying a command that has no push segment.
  # mutant:448-pg-xseg-saw-push -- drops the saw_push condition from the driver's cross-segment
  #   fallback, so the cd marker denies this push-free command.
  local main="$tmpbase/repo-px-y1"
  mk_fixture_repo "$main" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'cd ../other-y1 && git log --grep=push' "$main")"
  expect_push_no_opinion
}
case_px_noop_cd_as_argument() {
  # "cd" here is an ARGUMENT to "echo", never a resolved command word -- the xseg vocabulary is
  # only ever checked against $cmdword.
  run_push_guard "$(mk_push_cmd 'echo cd && git push origin feature/x')"
  expect_push_no_opinion
}
case_px_noop_export_unrelated() {
  # An export naming a variable OUTSIDE GIT_REPO_ENV_VARS never sets xseg -- pins the export arm's
  # exact-membership check (mutant:433-pg-export-exact).
  run_push_guard "$(mk_push_cmd 'export GIT_TRACE=1; git push origin feature/x')"
  expect_push_no_opinion
}

# --- Codex shell workdir (#494): a push run through a Codex shell tool's own `workdir` ----------
# A Codex PreToolUse payload never carries the shell tool's `workdir` (ADR 0002 U9), so a Codex-
# shaped payload (non-empty turn_id) whose push would otherwise get no opinion is judged against
# EVERY model tool-call record in the last PUSH_TRANSCRIPT_TAIL_BYTES of the rollout file its
# transcript_path names, completed or not (a code-mode cell can yield its output record and keep
# running): every occurrence of a workdir key must be a plain string literal lexically equal to the
# session checkout, or null; anything else, a line in the window that does not parse but mentions a
# key, an unparseable first line of at least half the window, an unreadable transcript, or a
# window with no call record at all, denies. Rollout records are built by the wd_rec_* helpers below
# (the real Codex 0.156.1 shapes: a response_item whose payload is a custom_tool_call carrying
# code-mode JS in `input`, a function_call carrying a JSON string in `arguments`, or a
# local_shell_call carrying an `action`; each usually followed by a *_output record bearing the same
# call_id, which proves nothing about whether the call is still running). Mutation proof lives in
# dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter "push-wd-" unless noted).
# mutant:494-pg-wd-gate — the Codex gate (a non-empty turn_id) never fires, so no Codex push is
#   ever judged against its transcript.
# mutant:494-pg-wd-gate-claude — the gate always fires, so a Claude-shaped payload (no turn_id) is
#   judged against a transcript too.
# mutant:494-pg-wd-missing — a missing transcript leaves no deny reason.
# mutant:494-pg-wd-not-regular — drops the regular-file test, so a directory named as the transcript
#   is read like a file and denies with the wrong reason.
# mutant:494-pg-wd-unreadable — drops the readable-file test, so an unreadable transcript denies
#   with the wrong reason.
# mutant:494-pg-wd-no-call — a window holding no tool-call record leaves no deny reason.
# mutant:494-pg-wd-no-pending-filter — re-introduces the completed-call filter, so a call whose
#   *_output record exists is no longer scanned (a yielded cell's workdir is then never seen).
# mutant:494-pg-wd-literal-tail — drops the requirement that a string literal be followed by a
#   comma or closing brace, so a literal continued by a concatenation reads as a plain literal.
# mutant:494-pg-wd-null-terminator — drops the comma-or-brace requirement after `null`, so an
#   identifier that merely starts with null reads as no workdir.
# mutant:494-pg-wd-session-compare — skips the lexical session-equivalence test, so every plain
#   literal is allowed.
# mutant:494-pg-wd-null-arm — removes the null arm, so an explicit null workdir is not recognised
#   as no workdir.
# mutant:494-pg-wd-undefined-bad — accepts `undefined` as no workdir, though JS lets that identifier
#   be shadowed.
# mutant:494-pg-wd-working-directory — removes working_directory from the key list, so a
#   local_shell_call action's working_directory is never scanned.
# mutant:494-pg-wd-bad-allow — a line the classifier marked BAD no longer sets a deny reason.
# mutant:494-pg-wd-every-occurrence — scans only the first occurrence of a workdir key in a call's
#   text, so a second, foreign occurrence is never seen.
# mutant:494-pg-wd-fragment-key-bad — an unparseable line that mentions a workdir key no longer
#   counts as a non-literal workdir.
# mutant:494-pg-wd-edge — the unparseable-first-line limit never fires, so a record larger than the
#   window is silently dropped.
# mutant:494-pg-wd-edge-fraction — the unparseable-first-line limit drops to zero, so any
#   unparseable first line denies.
# mutant:494-pg-wd-flatten — stops flattening a newline inside the text after a workdir key, so
#   a literal followed by a newline reads as a stray extra line.
# mutant:494-pg-wd-precedence — lets the workdir block run even after an earlier reason was set,
#   so it overwrites that reason (filter -deny-codex-main-session).

# wd_rec_custom ID INPUT -- one rollout line: a code-mode custom_tool_call record (the U9 shape).
# An empty ID omits call_id entirely.
wd_rec_custom() {
  jq -nc --arg id "$1" --arg input "$2" '
    {timestamp: "2026-10-04T16:25:05.861Z", type: "response_item",
     payload: ({type: "custom_tool_call", status: "completed", name: "exec", input: $input}
               + (if $id != "" then {call_id: $id} else {} end))}'
}
# wd_rec_custom_file ID FILE -- the same record with its `input` read from FILE (an input too large
# for an argv word, which a Linux kernel caps per argument).
wd_rec_custom_file() {
  jq -nc --arg id "$1" --rawfile input "$2" '
    {timestamp: "2026-10-04T16:25:05.861Z", type: "response_item",
     payload: ({type: "custom_tool_call", status: "completed", name: "exec", input: $input}
               + (if $id != "" then {call_id: $id} else {} end))}'
}
# wd_rec_function ID ARGS [NAME] -- a function_call record whose `arguments` is a JSON string.
wd_rec_function() {
  jq -nc --arg id "$1" --arg args "$2" --arg name "${3:-exec_command}" '
    {timestamp: "2026-10-04T16:25:05.861Z", type: "response_item",
     payload: ({type: "function_call", name: $name, arguments: $args}
               + (if $id != "" then {call_id: $id} else {} end))}'
}
# wd_rec_local_shell ID WD -- a local_shell_call record whose action carries working_directory WD.
wd_rec_local_shell() {
  jq -nc --arg id "$1" --arg wd "$2" '
    {timestamp: "2026-10-04T16:25:05.861Z", type: "response_item",
     payload: ({type: "local_shell_call", status: "completed",
                action: {type: "exec", command: ["git", "push"], working_directory: $wd}}
               + (if $id != "" then {call_id: $id} else {} end))}'
}
# wd_rec_output TYPE ID [TEXT] -- the answering *_output record; an empty ID omits call_id entirely.
wd_rec_output() {
  jq -nc --arg type "$1" --arg id "$2" --arg text "${3:-done}" '
    {timestamp: "2026-10-04T16:25:06.024Z", type: "response_item",
     payload: ({type: $type, output: [{type: "input_text", text: $text}]}
               + (if $id != "" then {call_id: $id} else {} end))}'
}
wd_rec_noise() { printf '%s\n' '{"timestamp":"2026-10-04T16:25:06.025Z","type":"event_msg","payload":{"type":"token_count"}}'; }
# mk_wd_rollout FILE LINE... -- writes one JSONL line per argument.
mk_wd_rollout() { local f="$1"; shift; printf '%s\n' "$@" > "$f"; }
# wd_js FRAG -- code-mode JS for one exec_command call; FRAG (empty, or a leading-comma property
# such as ,workdir:"/x") is spliced in after cmd. The closing brace sits on its own line, so a
# literal is followed by a newline before its brace.
wd_js() { printf 'const r = await tools.exec_command({\n  cmd:"git push origin claude/17-a"%s\n}); text(r.output);\n' "$1"; }
# wd_setup NAME -- builds the session repo (default main, current claude/17-a) and the other
# repo (default trunk), and names the rollout; sets wd_s, wd_o, wd_r.
wd_setup() {
  wd_s="$tmpbase/repo-wd-$1"
  wd_o="$tmpbase/other-wd-$1"
  wd_r="$tmpbase/rollout-wd-$1.jsonl"
  mk_fixture_repo "$wd_s" main "claude/17-a"
  mk_fixture_repo "$wd_o" trunk "feature/x"
}
# wd_run [CMD] -- runs the hook on a Codex-shaped payload against the session repo and rollout.
wd_run() { run_push_guard "$(mk_codex_shell '' "${1:-git push origin claude/17-a}" "$wd_s" "$wd_r")" "${2:-$PATH}"; }
# expect_wd_deny REASON -- the standard deny plus the family phrase and the exact fixed reason.
expect_wd_deny() {
  expect_push_deny
  case "$push_err" in
    *"cannot resolve which repository"*) ;;
    *) __ok=0; __why="${__why}stderr missing 'cannot resolve which repository': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"($1)"*) ;;
    *) __ok=0; __why="${__why}stderr missing reason '($1)': '$push_err'\n" ;;
  esac
}

case_wd_allow_no_workdir() {
  wd_setup allow-none
  mk_wd_rollout "$wd_r" "$(wd_rec_custom c1 "$(wd_js '')")"
  wd_run
  expect_push_no_opinion
}
case_wd_allow_literal_session() {
  wd_setup allow-lit
  mk_wd_rollout "$wd_r" \
    "$(wd_rec_custom c1 "$(wd_js ",workdir:\"$wd_s\"")")"
  wd_run
  expect_push_no_opinion
}
case_wd_allow_literal_dot() {
  wd_setup allow-dot
  mk_wd_rollout "$wd_r" "$(wd_rec_custom c1 "$(wd_js ',workdir:"."')")"
  wd_run
  expect_push_no_opinion
}
case_wd_allow_function_call_dot() {
  wd_setup allow-fn-dot
  mk_wd_rollout "$wd_r" "$(wd_rec_function c1 '{"cmd":"git push origin claude/17-a","workdir":"."}')"
  wd_run
  expect_push_no_opinion
}
case_wd_allow_function_call_null() {
  wd_setup allow-fn-null
  mk_wd_rollout "$wd_r" "$(wd_rec_function c1 '{"cmd":"git push origin claude/17-a","workdir":null}')"
  wd_run
  expect_push_no_opinion
}
case_wd_allow_short_fragment() {
  # Control for the window-edge limit: an unparseable first line that mentions no workdir key and is
  # far shorter than half the window (a record cut by the window start, in practice) is skipped.
  wd_setup allow-short-frag
  mk_wd_rollout "$wd_r" \
    'ol_call","status":"completed","name":"exec"}}' \
    "$(wd_rec_custom c1 "$(wd_js '')")"
  wd_run
  expect_push_no_opinion
}
case_wd_deny_completed_foreign() {
  # A call whose *_output record exists is still scanned (a code-mode cell can yield its output and
  # keep running): the earlier call names another checkout, the later one carries no workdir.
  wd_setup deny-done
  mk_wd_rollout "$wd_r" \
    "$(wd_rec_custom c1 "$(wd_js ",workdir:\"$wd_o\"")")" \
    "$(wd_rec_output custom_tool_call_output c1)" \
    "$(wd_rec_noise)" \
    "$(wd_rec_custom c2 "$(wd_js '')")"
  wd_run
  expect_wd_deny "Codex shell workdir names another directory"
}
case_wd_deny_yielded_cell() {
  # The yielded-cell shape: an exec cell whose output record says it is still running, carrying the
  # U9 push with a foreign workdir, then a pending `wait` call with no workdir at all.
  wd_setup deny-yield
  local wait_args='{"cell_id":"42","yield_time_ms":10000}'
  mk_wd_rollout "$wd_r" \
    "$(wd_rec_custom c1 "$(wd_js ",workdir:\"$wd_o\"")")" \
    "$(wd_rec_output custom_tool_call_output c1 'Script running with cell ID 42')" \
    "$(wd_rec_function c2 "$wait_args" wait)"
  wd_run 'git push origin HEAD:trunk'
  expect_wd_deny "Codex shell workdir names another directory"
}
case_wd_deny_other_checkout() {
  # The U9 reproduction: command HEAD:trunk (trunk is not the session's own default branch, so
  # nothing earlier in the hook denies), the code-mode call names another checkout.
  wd_setup deny-other
  mk_wd_rollout "$wd_r" \
    "$(wd_rec_custom c1 "$(wd_js '')")" \
    "$(wd_rec_output custom_tool_call_output c1)" \
    "$(wd_rec_noise)" \
    "$(wd_rec_custom c2 "$(wd_js ",workdir:\"$wd_o\"")")"
  wd_run 'git push origin HEAD:trunk'
  expect_wd_deny "Codex shell workdir names another directory"
}
case_wd_deny_computed() {
  wd_setup deny-computed
  mk_wd_rollout "$wd_r" "$(wd_rec_custom c1 "const d = \"$wd_s\"; $(wd_js ',workdir: d')")"
  wd_run
  expect_wd_deny "Codex shell workdir is not a plain string literal"
}
case_wd_deny_null_ident() {
  # An identifier that merely starts with null is not the null literal.
  wd_setup deny-nullident
  mk_wd_rollout "$wd_r" "$(wd_rec_custom c1 "const nullDir = \"$wd_o\"; $(wd_js ',workdir: nullDir')")"
  wd_run
  expect_wd_deny "Codex shell workdir is not a plain string literal"
}
case_wd_deny_undefined() {
  # `undefined` is not accepted as no workdir: JS lets that identifier be shadowed.
  wd_setup deny-undef
  mk_wd_rollout "$wd_r" "$(wd_rec_custom c1 "$(wd_js ',workdir: undefined')")"
  wd_run
  expect_wd_deny "Codex shell workdir is not a plain string literal"
}
case_wd_deny_undefined_shadowed() {
  wd_setup deny-undef-shadow
  mk_wd_rollout "$wd_r" "$(wd_rec_custom c1 "const undefined = \"$wd_o\"; $(wd_js ',workdir: undefined')")"
  wd_run 'git push origin HEAD:trunk'
  expect_wd_deny "Codex shell workdir is not a plain string literal"
}
case_wd_deny_concat() {
  wd_setup deny-concat
  mk_wd_rollout "$wd_r" "$(wd_rec_custom c1 "$(wd_js ",workdir:\"$wd_s\" + \"/sub\"")")"
  wd_run
  expect_wd_deny "Codex shell workdir is not a plain string literal"
}
case_wd_deny_duplicate_key() {
  # Every occurrence is judged, not only the first: the first names the session, the second another
  # checkout.
  wd_setup deny-dupkey
  mk_wd_rollout "$wd_r" "$(wd_rec_custom c1 "$(wd_js ",workdir:\"$wd_s\",workdir:\"$wd_o\"")")"
  wd_run
  expect_wd_deny "Codex shell workdir names another directory"
}
case_wd_deny_function_call_other() {
  wd_setup deny-fn-other
  # The JSON arguments go through a variable: bash 3.2 brace-expands a `{a,b}` word written inside
  # a nested double-quoted command substitution.
  local args="{\"cmd\":\"git push origin claude/17-a\",\"workdir\":\"$wd_o\"}"
  mk_wd_rollout "$wd_r" "$(wd_rec_function c1 "$args")"
  wd_run
  expect_wd_deny "Codex shell workdir names another directory"
}
case_wd_deny_local_shell_other() {
  wd_setup deny-ls-other
  mk_wd_rollout "$wd_r" "$(wd_rec_local_shell c1 "$wd_o")"
  wd_run
  expect_wd_deny "Codex shell workdir names another directory"
}
case_wd_deny_fragment_key() {
  # A record cut by the window start leaves an unparseable first line; if it still mentions a
  # workdir key it counts as a non-literal workdir, even with a clean call after it.
  wd_setup deny-fragkey
  local line
  line="$(wd_rec_custom c1 "$(wd_js ",workdir:\"$wd_o\"")")"
  mk_wd_rollout "$wd_r" "${line:140}" "$(wd_rec_custom c2 "$(wd_js '')")"
  wd_run
  expect_wd_deny "Codex shell workdir is not a plain string literal"
}
case_wd_deny_straddle() {
  # A push record larger than the whole window (workdir at its start, then padding), followed by a
  # small call with no workdir: the window holds only an unparseable fragment of the push record,
  # at least half the window long, which must deny rather than be dropped.
  wd_setup deny-straddle
  local big="$tmpbase/wd-straddle-input.txt" bigrec="$tmpbase/wd-straddle-rec.jsonl"
  {
    wd_js ",workdir:\"$wd_o\""
    printf '// '
    head -c 1100000 /dev/zero | tr '\0' 'x'
    printf '\n'
  } > "$big"
  wd_rec_custom_file c1 "$big" > "$bigrec"
  { cat "$bigrec"; wd_rec_custom c2 "$(wd_js '')"; } > "$wd_r"
  wd_run 'git push origin HEAD:trunk'
  expect_wd_deny "Codex transcript record exceeds the hook's read window"
}
case_wd_deny_missing_transcript() {
  # mk_codex_shell's default transcript_path names a file that is never created.
  wd_setup deny-missing
  run_push_guard "$(mk_codex_shell '' 'git push origin claude/17-a' "$wd_s")"
  expect_wd_deny "Codex transcript missing or unreadable"
}
case_wd_deny_empty_transcript_path() {
  wd_setup deny-emptypath
  run_push_guard "$(mk_codex_shell '' 'git push origin claude/17-a' "$wd_s" | jq -c '.transcript_path = ""')"
  expect_wd_deny "Codex transcript missing or unreadable"
}
case_wd_deny_transcript_directory() {
  # A directory is not a regular file: it must deny as unreadable, not be read as an empty file.
  wd_setup deny-dir
  mkdir -p "$wd_r"
  wd_run
  expect_wd_deny "Codex transcript missing or unreadable"
}
case_wd_deny_transcript_unreadable() {
  # A mode-000 rollout; under root it stays readable, so (like the include-permission fixtures
  # above) the proof assumes a non-root runner and the assertions are skipped there.
  wd_setup deny-noperm
  mk_wd_rollout "$wd_r" "$(wd_rec_custom c1 "$(wd_js '')")"
  chmod 000 "$wd_r"
  wd_run
  if [ ! -r "$wd_r" ]; then
    expect_wd_deny "Codex transcript missing or unreadable"
  fi
  chmod 600 "$wd_r"
}
case_wd_deny_no_call() {
  # No call record at all in the window: only an output record, a garbage line (no workdir key) and
  # noise.
  wd_setup deny-nocall
  mk_wd_rollout "$wd_r" \
    "$(wd_rec_output custom_tool_call_output c1)" \
    'not json' \
    "$(wd_rec_noise)"
  wd_run
  expect_wd_deny "no Codex tool call in its transcript"
}
case_wd_deny_never_executes() {
  # Safety property on the new route: the U9-shape deny with a booby-trapped PATH -- sentinel
  # absent, and the session repo, the other checkout and the rollout file all byte-identical
  # before/after (the hook only reads them).
  wd_setup never-exec
  mk_wd_rollout "$wd_r" "$(wd_rec_custom c1 "$(wd_js ",workdir:\"$wd_o\"")")"
  local trapdir="$tmpbase/trapbin-wd-never-exec" sentinel="$tmpbase/sentinel-wd-never-exec"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before_s after_s before_o after_o before_r after_r
  before_s="$(find "$wd_s" -type f -exec ls -la {} \; | sort)"
  before_o="$(find "$wd_o" -type f -exec ls -la {} \; | sort)"
  before_r="$(ls -la "$wd_r"; cat "$wd_r")"
  wd_run 'git push origin HEAD:trunk' "$trapdir:$PATH"
  after_s="$(find "$wd_s" -type f -exec ls -la {} \; | sort)"
  after_o="$(find "$wd_o" -type f -exec ls -la {} \; | sort)"
  after_r="$(ls -la "$wd_r"; cat "$wd_r")"
  expect_wd_deny "Codex shell workdir names another directory"
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH while denying a Codex workdir push\n"; }
  [ "$before_s" = "$after_s" ] || { __ok=0; __why="${__why}session repo's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
  [ "$before_o" = "$after_o" ] || { __ok=0; __why="${__why}other checkout's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
  [ "$before_r" = "$after_r" ] || { __ok=0; __why="${__why}rollout file changed — push-guard.sh wrote to or altered a file it should only read\n"; }
  case "$push_err" in
    *"$wd_o"*|*"$wd_r"*|*claude/17-a*) __ok=0; __why="${__why}deny message echoed transcript or command content: '$push_err'\n" ;;
  esac
}
case_wd_claude_unchanged() {
  # A Claude-shaped payload has no turn_id, so a transcript_path naming a missing file changes
  # nothing: the allowed push stays a no-opinion.
  wd_setup claude
  run_push_guard "$(jq -n --arg cwd "$wd_s" --arg tp "$tmpbase/claude-transcript-absent.jsonl" \
    '{tool_name: "Bash", tool_input: {command: "git push origin claude/17-a"}, cwd: $cwd, transcript_path: $tp}')"
  expect_push_no_opinion
}

# --- deny/no-opinion: #268 config-derived push routes (remote.<name>.push / push.default) -----
# Unless stated, the fixture repo has default branch main, current branch feature/x, and the
# command is a bare "git push" against an explicit cwd (see mk_fixture_config's ambient-$PWD
# comment above for why every one of these MUST pass cwd).
case_pd_config_remote_push_bare() {
  local dir="$tmpbase/repo-cfg-remote-push-bare"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_remote_push_named_remote() {
  local dir="$tmpbase/repo-cfg-remote-push-named"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push origin' "$dir")"
  expect_push_deny
}
case_pd_config_remote_push_second_line() {
  # Two "push =" lines under one remote; only the SECOND is offending -- the 0/1/2+ boundary
  # (LESSON 2026-09-08d) for a config record set, and reuse of refspec_dest()'s own
  # refs/heads/ strip on the destination side.
  local dir="$tmpbase/repo-cfg-remote-push-2nd"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:refs/heads/feature/y\n\tpush = HEAD:refs/heads/main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_no_space_assign() {
  # key=value with NO surrounding spaces (the acceptance criterion's own "key=value without
  # spaces" clause, #268 kickback finding 1) -- the *=*) split guard must recognise this form,
  # not only the "key = value" spacing every other fixture in this table happens to use.
  local dir="$tmpbase/repo-cfg-no-space-assign"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\npush=HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_push_default_upstream() {
  local dir="$tmpbase/repo-cfg-push-default-upstream"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = upstream\n[branch "feature/x"]\n\tremote = origin\n\tmerge = refs/heads/main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_push_default_tracking() {
  # "tracking" is git's documented synonym for "upstream".
  local dir="$tmpbase/repo-cfg-push-default-tracking"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = tracking\n[branch "feature/x"]\n\tremote = origin\n\tmerge = refs/heads/main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_push_default_matching() {
  # push.default = matching pushes every branch that exists on both ends -- including the
  # default branch in essentially every real repo -- so this denies unconditionally, the same
  # reasoning as --all/--mirror (Q2's default). No branch section is needed: this route never
  # consults branch.<n>.merge.
  local dir="$tmpbase/repo-cfg-push-default-matching"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = matching\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_union_benign_refspec_plus_upstream() {
  # RESOLVED Q1 union semantics (#268 kickback finding 2): a remote.origin.push refspec that
  # resolves to a NON-denying destination must not suppress the push.default route -- this hook
  # deliberately does NOT model git's own precedence (push.default consulted only when the
  # applicable remote has no push refspec); both routes are evaluated unconditionally, so a
  # config carrying a benign remote.<name>.push record AND a denying push.default still denies.
  local dir="$tmpbase/repo-cfg-union-benign-plus-upstream"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:refs/heads/feature/x\n[push]\n\tdefault = upstream\n[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_union_other_remote_bare() {
  # #268 kickback 2 finding (RESOLVED Q1's CROSS-REMOTE union, distinct from
  # push-deny-config-union-benign-refspec-plus-upstream above, which pins the union across
  # ROUTES on the SAME remote): a bare push considers EVERY configured remote's push refspecs,
  # not just the remote git's own precedence would pick (origin, absent
  # remote.pushDefault/branch.<n>.pushRemote/branch.<n>.remote). Config here carries only a
  # NON-origin remote's denying push refspec, plus a benign origin section with no push key at
  # all -- this is the fixture that makes the scope gate's "n==0 -> every remote" reading
  # observable and distinguishes it from "n==0 -> only git's own default remote".
  local dir="$tmpbase/repo-cfg-union-other-remote"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "backup"]\n\tpush = HEAD:main\n[remote "origin"]\n\turl = https://example.invalid/r.git\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_wildcard_refspec() {
  # A configured destination containing "*" pushes every matching branch; deny unconditionally
  # (Q3's default), the same reasoning as push.default=matching above.
  local dir="$tmpbase/repo-cfg-wildcard"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = refs/heads/*:refs/heads/*\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_crlf_line() {
  # #270's class, in the NEW config reader: every config line carries a CRLF ending.
  local dir="$tmpbase/repo-cfg-crlf"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\r\n\tpush = HEAD:main\r\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_crlf_interior() {
  # #268 kickback finding 3: an INTERIOR CR (not a line-ending one) inside the refspec value
  # itself -- "HEAD:ma<CR>in" -- denies via the cfg_cr strip specifically; push-deny-config-crlf-line
  # (above)'s CR is line-ending, already masked by cfg_trim()'s own [[:space:]] handling regardless
  # of cfg_cr, so it cannot distinguish "the CR strip runs" from "it doesn't" -- this fixture is
  # the one M35 (below) actually flips, making that mutant non-inert.
  local dir="$tmpbase/repo-cfg-crlf-interior"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:ma\rin\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_worktree_commondir() {
  # Config lives in the MAIN checkout's .git/config (mk_fixture_worktree's first argument), never
  # the worktree pointer dir's own gitdir -- the same common-dir rule the origin-HEAD symref read
  # already uses.
  local main="$tmpbase/repo-cfg-wt-main" wt="$tmpbase/repo-cfg-wt-pointer"
  mk_fixture_worktree "$main" "$wt" main "claude/17-a"
  mk_fixture_config "$main" $'[remote "origin"]\n\tpush = HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$wt")"
  expect_push_deny
}
case_pd_config_no_trailing_newline() {
  # The final (only) config line has no trailing newline -- the read ... || [ -n "$line" ]
  # rescue this file's while-loop needs, mirroring the idiom used elsewhere in this hook.
  local dir="$tmpbase/repo-cfg-no-trailing-nl"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:main'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_mixed_case() {
  # Section keyword and key name are both mixed-case; git treats both case-insensitively (a
  # quoted subsection name, "origin" here, stays case-sensitive and is unaffected).
  local dir="$tmpbase/repo-cfg-mixed-case"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[Remote "origin"]\n\tPush = HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_never_executes() {
  # Combines the never-executes-anything guarantee (booby-trapped git/gh/rm) AND the
  # byte-identical-file-listing property, both on the CONFIG deny route specifically (the
  # existing push-never-executes-* / push-never-executes-reads-only cases exercise only the
  # plain refspec-parsing routes, never the config reader added by this issue).
  local dir="$tmpbase/repo-cfg-never-executes"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:main\n'
  local trapdir="$tmpbase/trapbin-cfg-deny" sentinel="$tmpbase/sentinel-cfg-deny"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before after
  before="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")" "$trapdir:$PATH"
  after="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH while evaluating a config route\n"; }
  [ "$before" = "$after" ] || { __ok=0; __why="${__why}fixture repo's file listing changed — push-guard.sh wrote to or altered a file it should only read (config route)\n"; }
}
case_pd_config_tab_in_value() {
  # #290 kickback finding F4: cfg_push_lines records are "src<TAB>sub<TAB>refspec" (source FIRST,
  # a bounded field; the configured value is the record's UNBOUNDED tail) so a "push =" value
  # containing a literal TAB byte cannot truncate at that TAB and leak its own remainder into
  # config_deny()'s source-label field. A wildcard destination denies regardless of what follows
  # the embedded TAB, so this fixture stays a DENY either way (pre-F4-fix or post) -- what this
  # case pins is whether $src stays exactly one of the two literal labels (measured pre-fix, with
  # the OLD "sub<TAB>val<TAB>src" record order: still denies, rc 2, but stderr names
  # "junklabel<TAB>.git/config" -- neither declared literal -- instead of ".git/config").
  local dir="$tmpbase/repo-cfg-tab-in-value"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = refs/heads/*:refs/heads/*\tjunklabel\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
  # "junklabel" is the DENIED destination's own text too (the full, untruncated wildcard refspec
  # -- correct: git itself would treat the whole value as one refspec), so these assertions pin
  # the SOURCE-LABEL field specifically ("in <source>)", the printf format's own trailing clause),
  # never a plain substring test against the whole message.
  case "$push_err" in
    *"in .git/config)"*) ;;
    *) __ok=0; __why="${__why}stderr's source-label field is not exactly '.git/config': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"in junklabel"*) __ok=0; __why="${__why}stderr's source-label field is corrupted by the TAB-carrying value's own remainder: '$push_err'\n" ;;
    *) ;;
  esac
}
case_pn_config_neither_key() {
  # The decision's required control: a config file that sets NEITHER remote.<name>.push nor
  # push.default at all must stay no opinion.
  local dir="$tmpbase/repo-cfg-neither-key"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[core]\n\tbare = false\n[remote "origin"]\n\turl = https://example.invalid/o/r.git\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_config_remote_push_other_dest() {
  # A configured refspec that resolves to a destination other than the default branch.
  local dir="$tmpbase/repo-cfg-other-dest"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:refs/heads/feature/x\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_config_other_remote_named() {
  # n==1 exact remote scoping: "origin"'s push route must not apply to a "git push backup".
  local dir="$tmpbase/repo-cfg-other-remote"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push backup' "$dir")"
  expect_push_no_opinion
}
case_pn_config_explicit_refspec() {
  # The harness's own shape (n >= 2): config routes are NEVER consulted for a segment carrying
  # an explicit refspec -- a deny here would be a release blocker.
  local dir="$tmpbase/repo-cfg-explicit-refspec"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push -u origin "claude/17-a"' "$dir")"
  expect_push_no_opinion
}
case_pn_config_branch_other() {
  # push.default=upstream, but the [branch] section names a DIFFERENT branch than the current
  # one -- current-branch scoping on the merge lookup.
  local dir="$tmpbase/repo-cfg-branch-other"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = upstream\n[branch "other"]\n\tmerge = refs/heads/main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_config_commented_out() {
  # Comment/whitespace handling: a "#"-commented push line, a ";"-commented push.default line,
  # odd leading whitespace on the one REAL (harmless) key, none of which may be mistaken for an
  # active directive.
  local dir="$tmpbase/repo-cfg-commented-out"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n  # push = HEAD:main\n     push = feature/x\n[push]\n  ; default = matching\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_config_push_default_current() {
  # git's own default mode since 2.x: "current" is never resolved by this hook's push.default
  # route at all (only "upstream"/"tracking"/"matching" are) -- the sharp form of the clause,
  # since a branch section for the current branch IS present and WOULD deny if this mode were
  # mistaken for "upstream".
  local dir="$tmpbase/repo-cfg-default-current"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = current\n[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_config_push_default_simple() {
  local dir="$tmpbase/repo-cfg-default-simple"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = simple\n[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}

# --- #290: GLOBAL git config candidates ($GIT_CONFIG_GLOBAL, $XDG_CONFIG_HOME/git/config or its
# $HOME/.config/git/config default, $HOME/.gitconfig), unioned with the repo-local config #268
# already reads -- every fixture below passes an explicit cwd (mk_fixture_config's AMBIENT-$PWD
# rule) and sets $push_home_override (and, where noted, $push_xdg_home/$push_git_config_global)
# immediately before its own run_push_guard call, so its own global route is visible ONLY to that
# call -- run_push_guard clears all three right after every call, so no fixture below can leak its
# global config into a sibling fixture.
case_pd_global_gitconfig_upstream() {
  # Per-path coverage 1/4: $HOME/.gitconfig. Repo carries only a [branch] merge record (no
  # push.default of its own); the GLOBAL push.default=upstream is what denies. Also asserts
  # inline that stderr names the GLOBAL source label, not ".git/config".
  local dir="$tmpbase/repo-global-gitconfig-upstream" home="$tmpbase/home-global-gitconfig-upstream"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$home/.gitconfig" $'[push]\n\tdefault = upstream\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *"your global git config"*) ;;
    *) __ok=0; __why="${__why}stderr does not name the global source label 'your global git config': '$push_err'\n" ;;
  esac
}
case_pd_global_xdg_upstream() {
  # Per-path coverage 2/4: explicit $XDG_CONFIG_HOME/git/config, with a neutral (no-.gitconfig)
  # HOME override so the OTHER two global paths are absent for this fixture.
  local dir="$tmpbase/repo-global-xdg-upstream" home="$tmpbase/home-global-xdg-upstream"
  local xdg="$tmpbase/xdg-global-xdg-upstream"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$xdg/git/config" $'[push]\n\tdefault = upstream\n'
  push_home_override="$home"
  push_xdg_home="$xdg"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_xdg_home_default_upstream() {
  # Per-path coverage 3/4: $XDG_CONFIG_HOME UNSET -- pins the default-path branch,
  # $HOME/.config/git/config, distinct from case_pd_global_xdg_upstream's explicit-XDG branch.
  local dir="$tmpbase/repo-global-xdg-home-default-upstream"
  local home="$tmpbase/home-global-xdg-home-default-upstream"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$home/.config/git/config" $'[push]\n\tdefault = upstream\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_env_var_upstream() {
  # Per-path coverage 4/4: $GIT_CONFIG_GLOBAL pointing at a fixture file OUTSIDE HOME entirely --
  # the neutral HOME (no override) has no .gitconfig, so only the env-var route can deny here.
  local dir="$tmpbase/repo-global-env-var-upstream"
  local gcg="$tmpbase/gcg-global-env-var-upstream/customconfig"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$gcg" $'[push]\n\tdefault = upstream\n'
  push_git_config_global="$gcg"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_remote_push_refspec() {
  # Route coverage: remote.<name>.push via a GLOBAL file; the repo has NO config file at all.
  local dir="$tmpbase/repo-global-remote-push-refspec"
  local home="$tmpbase/home-global-remote-push-refspec"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$home/.gitconfig" $'[remote "origin"]\n\tpush = HEAD:main\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_default_matching() {
  # Route coverage: push.default=matching via a GLOBAL file, unconditional -- no [branch] section
  # anywhere (this route never consults branch.<n>.merge).
  local dir="$tmpbase/repo-global-default-matching"
  local home="$tmpbase/home-global-default-matching"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$home/.gitconfig" $'[push]\n\tdefault = matching\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_benign_does_not_mask_repo_route() {
  # Union/precedence: a benign GLOBAL push.default (current) must not mask a denying REPO
  # push.default (upstream) -- the mutation-discriminating case for "evaluate every value, not
  # just the first". Also asserts inline that stderr names the REPO source label, ".git/config".
  local dir="$tmpbase/repo-global-benign-mask" home="$tmpbase/home-global-benign-mask"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = upstream\n[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$home/.gitconfig" $'[push]\n\tdefault = current\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *".git/config"*) ;;
    *) __ok=0; __why="${__why}stderr does not name the repo-local source label '.git/config': '$push_err'\n" ;;
  esac
}
case_pd_global_overrides_benign_repo_route() {
  # Union/precedence, the other direction: a denying GLOBAL push.default (upstream) must still
  # deny even though the REPO's own push.default (current) is benign -- the documented over-block
  # (git itself would honour the repo's "current" and never consult the global value at all).
  local dir="$tmpbase/repo-global-overrides-benign" home="$tmpbase/home-global-overrides-benign"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = current\n[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$home/.gitconfig" $'[push]\n\tdefault = upstream\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_env_var_union_not_replace() {
  # Union-not-replace over-block: $GIT_CONFIG_GLOBAL is set to a BENIGN file, and $HOME/.gitconfig
  # (which real git would never consult once $GIT_CONFIG_GLOBAL is set) still supplies the deny --
  # also the "denier read LAST" half of the 2+ boundary, with the XDG candidate absent in between.
  local dir="$tmpbase/repo-global-union-not-replace" home="$tmpbase/home-global-union-not-replace"
  local gcg="$tmpbase/gcg-global-union-not-replace/customconfig"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$gcg" $'[core]\n\teditor = vi\n'
  mk_fixture_global_config "$home/.gitconfig" $'[remote "origin"]\n\tpush = HEAD:main\n'
  push_home_override="$home"
  push_git_config_global="$gcg"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_two_files_first_denies() {
  # The "denier read FIRST" half of the 2+ boundary: $GIT_CONFIG_GLOBAL (read first) denies,
  # $HOME/.gitconfig (read after it) is benign.
  local dir="$tmpbase/repo-global-two-files-first-denies"
  local home="$tmpbase/home-global-two-files-first-denies"
  local gcg="$tmpbase/gcg-global-two-files-first-denies/customconfig"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$gcg" $'[remote "origin"]\n\tpush = HEAD:main\n'
  mk_fixture_global_config "$home/.gitconfig" $'[core]\n\teditor = vi\n'
  push_home_override="$home"
  push_git_config_global="$gcg"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_two_defaults_one_file() {
  # #290 kickback finding F1: TWO "[push] default = ..." lines inside ONE file (global here) are
  # BOTH accumulated by cfg_push_defaults' list and evaluated in file-order -- so the FIRST value
  # denies even though git itself (last-wins WITHIN one file -- this hook's own pre-#290 scalar
  # behaviour) resolves that file's own push.default to the SECOND, benign value and would not
  # deny. Repo carries only a [branch] merge record (no push.default of its own). Also asserts
  # inline that the deny is attributed to the FIRST ("upstream") record's own via/source, not the
  # second.
  local dir="$tmpbase/repo-global-two-defaults-one-file"
  local home="$tmpbase/home-global-two-defaults-one-file"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$home/.gitconfig" $'[push]\n\tdefault = upstream\n\tdefault = current\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *"push.default=upstream in your global git config"*) ;;
    *) __ok=0; __why="${__why}stderr does not name push.default=upstream via the global source label: '$push_err'\n" ;;
  esac
}
case_pd_c_target_global_route() {
  # Cross-feature: a resolved "-C" segment sees the GLOBAL routes (read from the environment, the
  # same for every segment, never derived from the "-C" value itself) INDEPENDENTLY of the
  # session's own facts. The SESSION's own cwd resolves to NO repo at all (mkdir only, no
  # mk_fixture_repo call) -- RESOLVED decision: global routes are consulted only when a repo
  # actually resolves, so the SESSION's own resolve_repo() call never attempts the global-config
  # read at all here. This isolates that the deny comes SOLELY from the "-C" TARGET's own
  # resolution reading the same global files -- a session that itself also resolved a real repo
  # would independently pick up the identical global route and mask this discriminator (measured:
  # an earlier draft of this fixture, with the session resolving an ordinary repo, was NOT flipped
  # by apply_c_target()'s own body-replaced-with-":" mutant, M46, because the session's own
  # apply_session_repo() facts already carried the same deny).
  local main="$tmpbase/repo-c-g1" target="$tmpbase/target-g1-wt-1"
  local home="$tmpbase/home-c-g1"
  mkdir -p "$main"
  mk_fixture_repo "$target" trunk "feature/y"
  mk_fixture_global_config "$home/.gitconfig" $'[remote "origin"]\n\tpush = HEAD:main\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../target-g1-wt-1 push' "$main")"
  expect_push_deny
}
case_pd_global_never_executes() {
  # Safety: the never-executes/reads-only guarantee on the GLOBAL route specifically -- booby-traps
  # git/gh/rm/dirname and asserts byte-identical listings of BOTH the fixture repo AND the fixture
  # HOME tree (never just the repo, which the pre-existing never-executes cases already cover).
  local dir="$tmpbase/repo-global-never-executes" home="$tmpbase/home-global-never-executes"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$home/.gitconfig" $'[push]\n\tdefault = upstream\n'
  local trapdir="$tmpbase/trapbin-global-deny" sentinel="$tmpbase/sentinel-global-deny"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before_repo after_repo before_home after_home
  before_repo="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  before_home="$(find "$home" -type f -exec ls -la {} \; | sort)"
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")" "$trapdir:$PATH"
  after_repo="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  after_home="$(find "$home" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH while evaluating a global config route\n"; }
  [ "$before_repo" = "$after_repo" ] || { __ok=0; __why="${__why}fixture repo's file listing changed — push-guard.sh wrote to or altered a file it should only read (global config route)\n"; }
  [ "$before_home" = "$after_home" ] || { __ok=0; __why="${__why}fixture HOME's file listing changed — push-guard.sh wrote to or altered a file it should only read (global config route)\n"; }
}
case_pn_global_upstream_no_tracking() {
  # Negative control / honest scope: global push.default=upstream, current branch claude/17-a, NO
  # [branch] section ANYWHERE -- refspec_dest() of an empty merge value resolves to no destination.
  local dir="$tmpbase/repo-global-upstream-no-tracking"
  local home="$tmpbase/home-global-upstream-no-tracking"
  mk_fixture_repo "$dir" main "claude/17-a"
  mk_fixture_global_config "$home/.gitconfig" $'[push]\n\tdefault = upstream\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_global_explicit_refspec() {
  # Release-blocker control: the harness's OWN bare-C-less push -u origin "claude/<n>-<slug>"
  # shape against a GLOBAL config carrying BOTH a denying remote.origin.push AND
  # push.default=matching -- config is NEVER consulted for an explicit-refspec segment (n>=2),
  # global or repo-local.
  local dir="$tmpbase/repo-global-explicit-refspec"
  local home="$tmpbase/home-global-explicit-refspec"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$home/.gitconfig" $'[remote "origin"]\n\tpush = HEAD:main\n[push]\n\tdefault = matching\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push -u origin "claude/17-a"' "$dir")"
  expect_push_no_opinion
}
case_pn_global_explicit_refspec_c() {
  # Release-blocker control, the "-C" variant: the harness's OWN "-C <wt>"-prefixed explicit-
  # refspec push shape, against the SAME denying GLOBAL config as case_pn_global_explicit_refspec.
  local main="$tmpbase/repo-global-explicit-refspec-c" target="$tmpbase/target-g2-wt-1"
  local home="$tmpbase/home-global-explicit-refspec-c"
  mk_fixture_repo "$main" main feature/x
  mk_fixture_repo "$target" trunk feature/y
  mk_fixture_global_config "$home/.gitconfig" $'[remote "origin"]\n\tpush = HEAD:main\n[push]\n\tdefault = matching\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../target-g2-wt-1 push -u origin "claude/17-a"' "$main")"
  expect_push_no_opinion
}
case_pn_global_none_present() {
  # The "none present" boundary AND the isolation positive control: a dedicated, empty fixture
  # HOME with no .gitconfig and no .config/git/config, XDG_CONFIG_HOME and GIT_CONFIG_GLOBAL both
  # unset, repo config absent -- must stay no opinion (proves this file's own isolation actually
  # works: without it, the developer's or CI runner's real global config could flip this).
  local dir="$tmpbase/repo-global-none-present" home="$tmpbase/home-global-none-present"
  mkdir -p "$home"
  mk_fixture_repo "$dir" main "claude/17-a"
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}

# --- role-agnostic no-opinion edges ----------------------------------------------------------------
case_pr_plan_mode()      { run_push_guard "$(mk_push_cmd_mode 'git push origin main' 'plan')"; expect_push_no_opinion; }
case_pr_wrong_tool()     { run_push_guard "$(mk_push_tool 'Read' 'git push origin main')"; expect_push_no_opinion; }
case_pr_malformed_json() {
  # Deliberately contains both literal substrings 'push' and 'git' so this exercises jq's own
  # parse failure rather than passing vacuously via the raw-stdin fast path.
  run_push_guard 'not json at all, but mentions push and git anyway'
  expect_push_no_opinion
}
case_pr_missing_command() { run_push_guard "$(mk_push_missing_command)"; expect_push_no_opinion; }

# --- never-executes / reads-only --------------------------------------------------------------
case_push_never_executes_deny() {
  local trapdir="$tmpbase/trapbin-push-deny" sentinel="$tmpbase/sentinel-push-deny"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_push_guard "$(mk_push_cmd 'git push origin main')" "$trapdir:$PATH"
  expect_push_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH\n"; }
}
case_push_never_executes_noop() {
  local trapdir="$tmpbase/trapbin-push-noop" sentinel="$tmpbase/sentinel-push-noop"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_push_guard "$(mk_push_cmd 'git push origin feature/x')" "$trapdir:$PATH"
  expect_push_no_opinion
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH\n"; }
}
case_push_reads_only() {
  # This is the first hook in this repo that reads the filesystem (git-c-guard.sh and
  # agent-boundary.sh never do) — pin that it only reads: a fixture repo's recursive file listing
  # must be byte-identical before and after a run, deny path included. No portable, reliably
  # non-hanging FIFO fixture was added for the [ -f ] guard itself (the plan's optional case) —
  # the guard is exercised implicitly by every fixture-repo case above, all of which read ordinary
  # regular files.
  local dir="$tmpbase/repo-reads-only"
  mk_fixture_repo "$dir" main feature/x
  local before after
  before="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  run_push_guard "$(mk_push_cmd_cwd 'git push origin main' "$dir")"
  after="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  [ "$before" = "$after" ] || { __ok=0; __why="${__why}fixture repo's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
}

# --- #398: the shell-keyword / case-fold class -------------------------------------------------
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter
# "push-kw-"), re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table.
# mutant:398-pg-kw-vocab — drops only the shell-keyword words (if/then/elif/else/do/while/until/!/
#   coproc) from PREFIX_WORDS, leaving the #403 eval/trap/zsh-modifier words in place, so a fixture
#   below whose command relies on skipping a leading keyword no longer resolves git as the command
#   word.
# mutant:398-pg-case-fold — removes emit_segment()'s tolower() around normalize(tok), so an
#   upper-case command word no longer resolves to "git".
# mutant:398-pg-fastpath-case — narrows the widened `*[Gg][Ii][Tt]*` fast path back to the plain
#   `*git*` (no case fold), isolating a fixture whose raw stdin carries no case-insensitive "git"
#   substring at all. No `cwd` is passed for any fixture below: each carries n >= 2 refspec
#   tokens, so the unconditional PUSH_DEFAULT_BRANCH_FALLBACK ("main"/"master") decides without
#   needing a resolved repo.
case_push_kw_deny_then() {
  run_push_guard "$(mk_push_cmd 'if true; then git push origin main; fi')"
  expect_push_deny
}
case_push_kw_deny_bang() {
  run_push_guard "$(mk_push_cmd '! git push origin main')"
  expect_push_deny
}
case_push_kw_deny_upper_git() {
  run_push_guard "$(mk_push_cmd 'GIT push origin main')"
  expect_push_deny
}
case_push_kw_noop_then_feature() {
  # Control: the keyword skip must not widen the destination rule — a non-default-branch
  # destination behind a keyword still gets no opinion.
  run_push_guard "$(mk_push_cmd 'if true; then git push origin feature/x; fi')"
  expect_push_no_opinion
}

# --- #304/#305: system git config candidates and include/includeIf ----------------------------
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filters
# "push-sysconf-" and "push-include-"), re-run by dev/mutant-driver.sh — the #359 registry idiom.
# mutant:304-sys-env-var — drops the $GIT_CONFIG_SYSTEM record from the system candidate list.
# mutant:304-sys-etc — removes "/etc/gitconfig" from PUSH_SYSTEM_CONFIG_PATHS.
# mutant:304-sys-homebrew-arm — removes "/opt/homebrew/etc/gitconfig" from PUSH_SYSTEM_CONFIG_PATHS.
# mutant:304-sys-homebrew-intel — removes "/usr/local/etc/gitconfig" from PUSH_SYSTEM_CONFIG_PATHS.
# mutant:304-sys-clt — drops the Apple CLT record from the system candidate list.
# mutant:304-nosystem-ignored — makes the GIT_CONFIG_NOSYSTEM truthy arm unmatchable, so no value
#   ever disables the system read.
# mutant:304-nosystem-word — narrows the truthy arm to "1" only, dropping true/yes/on.
# mutant:304-nosystem-any-value — makes ANY non-empty GIT_CONFIG_NOSYSTEM value count as true
#   (not just the canonical ones), so a non-canonical value like "0" wrongly disables the read.
# mutant:304-nosystem-covers-clt — moves the Apple CLT record OUTSIDE the $nosys guard, so it is
#   read even when GIT_CONFIG_NOSYSTEM holds a canonical true value (undoing the amendment that
#   put it inside the guard after a live NOSYSTEM probe on this Mac).
# mutant:304-sys-order — emits the system candidate records AFTER .git/config instead of before,
#   so a repo-local/system conflict on the last-wins branch.<current>.merge scalar resolves
#   backwards.
# mutant:304-sys-label — mislabels the $GIT_CONFIG_SYSTEM record as "your global git config".
# mutant:304-sys-clt-label — mislabels the Apple CLT record as "your global git config".
# mutant:304-inc-section — makes the plain "[include]" section header unmatchable.
# mutant:304-incif-section — makes the "[includeIf ...]" section header unmatchable.
# mutant:304-inc-key-case — narrows the include "path" key match to the exact lower-case spelling.
# mutant:304-inc-relative — the generic relative-path arm uses $cfg_val unjoined, instead of
#   joining it onto the including file's own directory.
# mutant:304-inc-tilde — removes the "~/" resolution arm.
# mutant:304-inc-tilde-user — drops "\~*" from the skip arm, so "~user/…" falls through to the
#   generic relative-path arm instead of being silently skipped.
# mutant:304-inc-regular-file — widens cfg_parse_file()'s own "[ -f" guard to "[ -e", so a
#   directory target is opened for reading instead of silently skipped.
# mutant:304-inc-tilde-empty-home — drops the "[ -n "${HOME:-}" ]" guard on the "~/" arm, so it
#   resolves against an empty $HOME instead of silently skipping.
# mutant:304-inc-drive-letter — narrows the absolute-path arm from "/*|[A-Za-z]:/*" to "/*", so an
#   "X:/…" value falls through to the generic relative-path (joined) arm instead of being used
#   as-is.
# mutant:304-inc-prefix-skip — removes the "%(prefix)/" skip arm, so it falls through to the
#   generic relative-path arm instead of being silently skipped.
# mutant:304-inc-depth-lo — lowers CFG_INCLUDE_MAX_DEPTH to 9.
# mutant:304-inc-depth-hi — raises CFG_INCLUDE_MAX_DEPTH to 11.
# mutant:304-inc-section-local — drops cfg_section/cfg_subsection from cfg_parse_file()'s own
#   `local` declaration, so a nested include call clobbers the includer's own section state.
# mutant:304-inc-label — drops the " (via include)" suffix entirely.
# mutant:304-inc-seen-global — reverts cfg_parse_file()'s own $cfg_seen guard to a
#   whole-resolve_repo()-call history (drops the save-on-entry/restore-on-return pair), so a path
#   already read via one top-level candidate's own include is wrongly treated as "already seen" by
#   a later, unrelated top-level candidate (or a sibling include) that names the identical path —
#   under-blocking exactly the push-include-deny-repo-config-reincluded shape.
# mutant:304-inc-follow-budget — drops the "$cfg_inc_budget -gt 0" check entirely, so every include
#   is followed unconditionally regardless of how many have already run.
# mutant:304-inc-follow-budget-off-by-one — narrows the budget boundary from "-gt 0" to "-ge 0", so
#   one include past the budget is still followed.
# mutant:304-inc-line-budget — drops the budget check itself (the "-gt 0" test and its "|| break"),
#   so an included file is read to its own end regardless of how many lines have already been read.
# mutant:304-inc-line-budget-off-by-one — narrows the line-budget boundary from "-gt 0" to "-ge 0",
#   so one line past the budget is still read.
# mutant:304-inc-line-budget-depth0 — drops the "depth >= 1" guard, so the line budget also applies
#   to a depth-0 top-level candidate, which can then be truncated mid-file.
# mutant:304-inc-line-chars — drops the CFG_INCLUDE_MAX_LINE_CHARS length check entirely, so a line
#   of any length reaches comment-strip and trim regardless of how long it is. Its registry filter
#   names push-include-noop-over-line-chars alone (#476): with the check gone, the oversized filler
#   line in push-include-noop-over-char-budget is also parsed, and whether that parse finishes inside
#   the hook's analysis budget depends on host speed, so that case's verdict under this mutant is
#   load-dependent and must not be part of the recorded set.
# mutant:304-inc-line-chars-off-by-one — narrows the length-cap boundary from "-le" to "-lt", so a
#   line exactly at the cap is skipped one character too early.
# mutant:304-inc-char-budget — drops the CFG_INCLUDE_MAX_CHARS check entirely, so a line is always
#   processed regardless of how many characters have already been charged.
# mutant:304-inc-char-budget-off-by-one — narrows the character-budget boundary from "-ge 0" to
#   "-gt 0", so a line landing exactly on the budget's own last character is refused one character
#   too early.
# mutant:304-inc-follow-budget-reset — changes cfg_inc_budget's own reset from an unconditional
#   assignment to a "set only if unset/empty" default (":=$"), so a SECOND resolve_repo() call in
#   the same hook invocation (a resolved "-C" target) inherits the session's own already-decremented
#   value instead of starting fresh.
# mutant:304-inc-line-budget-reset — the same "set only if unset/empty" change to
#   cfg_inc_line_budget's own reset.
# mutant:304-inc-char-budget-reset — the same "set only if unset/empty" change to
#   cfg_inc_char_budget's own reset.
# mutant:304-inc-follow-gate — drops the new line-budget/char-budget conjuncts from the include
#   arm's own follow condition, so a follow is gated on CFG_INCLUDE_MAX_FOLLOWS alone: once the
#   line or character budget is exhausted but follows remain, each further include is still OPENED
#   and its first line read in full before the per-line checks inside it can break.
# mutant:304-inc-line-follow-gate — drops only the "$cfg_inc_line_budget -gt 0" conjunct from the
#   include arm's own follow condition, leaving the character-budget conjunct in place: a follow
#   is still correctly refused once characters run out, but NOT once only the line-count budget has
#   -- with characters still to spare, a further include is still OPENED once the line budget alone
#   is exhausted.
# mutant:304-cfg-trim-tab — narrows cfg_trim()'s own trailing-trim class from every [:space:]
#   character to a literal space only, so a trailing TAB in a config value is never stripped.
case_push_cfg_deny_trailing_tab_default() {
  # Pins that cfg_trim()'s fork-free rewrite still strips a trailing TAB (not just trailing
  # spaces) from a config value -- [:space:] includes tab, and the mutant above narrows the
  # trailing-trim class to spaces only, proving this fixture actually depends on that.
  local dir="$tmpbase/repo-cfg-trailing-tab"
  mk_fixture_repo "$dir" main feature/x
  printf '[push]\n\tdefault = matching\t\n' > "$dir/.git/config"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_sysconf_deny_etc() {
  local dir="$tmpbase/repo-sysconf-etc" sysroot="$tmpbase/sysroot-etc"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$sysroot/etc/gitconfig" $'[remote "origin"]\n\tpush = HEAD:main\n'
  push_sysroot_override="$sysroot"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_sysconf_deny_homebrew_arm() {
  local dir="$tmpbase/repo-sysconf-homebrew-arm" sysroot="$tmpbase/sysroot-homebrew-arm"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$sysroot/opt/homebrew/etc/gitconfig" $'[push]\n\tdefault = upstream\n'
  push_sysroot_override="$sysroot"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_sysconf_deny_homebrew_intel() {
  local dir="$tmpbase/repo-sysconf-homebrew-intel" sysroot="$tmpbase/sysroot-homebrew-intel"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$sysroot/usr/local/etc/gitconfig" $'[push]\n\tdefault = matching\n'
  push_sysroot_override="$sysroot"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_sysconf_deny_apple_clt() {
  local dir="$tmpbase/repo-sysconf-apple-clt" sysroot="$tmpbase/sysroot-apple-clt"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config \
    "$sysroot/Library/Developer/CommandLineTools/usr/share/git-core/gitconfig" \
    $'[push]\n\tdefault = matching\n'
  push_sysroot_override="$sysroot"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *"in your system git config"*) ;;
    *) __ok=0; __why="${__why}stderr does not name the system source label 'in your system git config': '$push_err'\n" ;;
  esac
}
case_push_sysconf_deny_env_var() {
  local dir="$tmpbase/repo-sysconf-env-var" sysroot="$tmpbase/sysroot-env-var"
  local gcs="$tmpbase/gcs-env-var/sysconfig"
  mk_fixture_repo "$dir" main feature/x
  mkdir -p "$sysroot"
  mk_fixture_global_config "$gcs" $'[remote "origin"]\n\tpush = HEAD:main\n'
  push_sysroot_override="$sysroot"
  push_git_config_system="$gcs"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *"in your system git config"*) ;;
    *) __ok=0; __why="${__why}stderr does not name the system source label 'in your system git config': '$push_err'\n" ;;
  esac
}
case_push_sysconf_deny_env_var_union_not_replace() {
  local dir="$tmpbase/repo-sysconf-union" sysroot="$tmpbase/sysroot-union"
  local gcs="$tmpbase/gcs-union/sysconfig"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$gcs" $'[core]\n\teditor = vi\n'
  mk_fixture_global_config "$sysroot/etc/gitconfig" $'[remote "origin"]\n\tpush = HEAD:main\n'
  push_sysroot_override="$sysroot"
  push_git_config_system="$gcs"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_sysconf_noop_nosystem_one() {
  local dir="$tmpbase/repo-sysconf-nosystem-one" sysroot="$tmpbase/sysroot-nosystem-one"
  local gcs="$tmpbase/gcs-nosystem-one/sysconfig"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$gcs" $'[push]\n\tdefault = matching\n'
  mk_fixture_global_config "$sysroot/etc/gitconfig" $'[push]\n\tdefault = matching\n'
  push_sysroot_override="$sysroot"
  push_git_config_system="$gcs"
  push_git_config_nosystem="1"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_sysconf_noop_nosystem_word() {
  local dir="$tmpbase/repo-sysconf-nosystem-word" sysroot="$tmpbase/sysroot-nosystem-word"
  local gcs="$tmpbase/gcs-nosystem-word/sysconfig"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$gcs" $'[push]\n\tdefault = matching\n'
  mk_fixture_global_config "$sysroot/etc/gitconfig" $'[push]\n\tdefault = matching\n'
  push_sysroot_override="$sysroot"
  push_git_config_system="$gcs"
  push_git_config_nosystem="Yes"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_sysconf_deny_nosystem_false() {
  local dir="$tmpbase/repo-sysconf-nosystem-false" sysroot="$tmpbase/sysroot-nosystem-false"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$sysroot/etc/gitconfig" $'[push]\n\tdefault = matching\n'
  push_sysroot_override="$sysroot"
  push_git_config_nosystem="0"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_sysconf_noop_clt_nosystem() {
  # Amendment A1 (orchestrator-verified live on this Mac): GIT_CONFIG_NOSYSTEM=1 drops the CLT
  # file's own scope from real git's own `--show-scope` output too, so it belongs INSIDE the
  # $nosys guard, not outside it — the reverse of this fixture's pre-amendment name and verdict.
  local dir="$tmpbase/repo-sysconf-clt-nosystem" sysroot="$tmpbase/sysroot-clt-nosystem"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config \
    "$sysroot/Library/Developer/CommandLineTools/usr/share/git-core/gitconfig" \
    $'[push]\n\tdefault = matching\n'
  push_sysroot_override="$sysroot"
  push_git_config_nosystem="1"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_sysconf_deny_repo_merge_last() {
  local dir="$tmpbase/repo-sysconf-merge-last" sysroot="$tmpbase/sysroot-merge-last"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$sysroot/etc/gitconfig" \
    $'[push]\n\tdefault = upstream\n[branch "feature/x"]\n\tmerge = refs/heads/feature/x\n'
  push_sysroot_override="$sysroot"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_sysconf_deny_c_target() {
  local main="$tmpbase/repo-sysc" target="$tmpbase/target-s12-wt-1" sysroot="$tmpbase/sysroot-c-target"
  mkdir -p "$main"
  mk_fixture_repo "$target" trunk feature/y
  mk_fixture_global_config "$sysroot/etc/gitconfig" $'[remote "origin"]\n\tpush = HEAD:main\n'
  push_sysroot_override="$sysroot"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../target-s12-wt-1 push' "$main")"
  expect_push_deny
}
case_push_sysconf_noop_explicit_refspec() {
  local dir="$tmpbase/repo-sysconf-explicit-refspec" sysroot="$tmpbase/sysroot-explicit-refspec"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$sysroot/etc/gitconfig" \
    $'[remote "origin"]\n\tpush = HEAD:main\n[push]\n\tdefault = matching\n'
  push_sysroot_override="$sysroot"
  run_push_guard "$(mk_push_cmd_cwd 'git push -u origin "claude/17-a"' "$dir")"
  expect_push_no_opinion
}
case_push_sysconf_deny_never_executes() {
  local dir="$tmpbase/repo-sysconf-never-executes" sysroot="$tmpbase/sysroot-never-executes"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$sysroot/etc/gitconfig" $'[push]\n\tdefault = matching\n'
  local trapdir="$tmpbase/trapbin-sysconf-deny" sentinel="$tmpbase/sentinel-sysconf-deny"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before_repo after_repo before_sysroot after_sysroot
  before_repo="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  before_sysroot="$(find "$sysroot" -type f -exec ls -la {} \; | sort)"
  push_sysroot_override="$sysroot"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")" "$trapdir:$PATH"
  after_repo="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  after_sysroot="$(find "$sysroot" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH while evaluating a system config route\n"; }
  [ "$before_repo" = "$after_repo" ] || { __ok=0; __why="${__why}fixture repo's file listing changed — push-guard.sh wrote to or altered a file it should only read (system config route)\n"; }
  [ "$before_sysroot" = "$after_sysroot" ] || { __ok=0; __why="${__why}fixture sysroot's file listing changed — push-guard.sh wrote to or altered a file it should only read (system config route)\n"; }
}
case_push_include_deny_relative_from_repo() {
  local dir="$tmpbase/repo-include-relative"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = extra.inc\n'
  printf '[remote "origin"]\n\tpush = HEAD:main\n' > "$dir/.git/extra.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *"in .git/config (via include)"*) ;;
    *) __ok=0; __why="${__why}stderr does not name the include source label 'in .git/config (via include)': '$push_err'\n" ;;
  esac
}
case_push_include_deny_absolute_from_global() {
  local dir="$tmpbase/repo-include-absolute" home="$tmpbase/home-include-absolute"
  local body
  mk_fixture_repo "$dir" main feature/x
  body="$(printf '[include]\n\tpath = %s/inc-abs/abs.inc\n' "$tmpbase")"
  mk_fixture_global_config "$home/.gitconfig" "$body"
  mk_fixture_global_config "$tmpbase/inc-abs/abs.inc" $'[remote "origin"]\n\tpush = HEAD:main\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_include_deny_tilde() {
  local dir="$tmpbase/repo-include-tilde" home="$tmpbase/home-include-tilde"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$home/.gitconfig" $'[include]\n\tpath = ~/inc/push.inc\n'
  mk_fixture_global_config "$home/inc/push.inc" $'[remote "origin"]\n\tpush = HEAD:main\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_include_deny_includeif_unmatched_condition() {
  local dir="$tmpbase/repo-include-includeif"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[includeIf "gitdir:/nonexistent-304/"]\n\tpath = extra.inc\n'
  printf '[remote "origin"]\n\tpush = HEAD:main\n' > "$dir/.git/extra.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_include_deny_mixed_case() {
  local dir="$tmpbase/repo-include-mixed-case"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[Include]\n\tPATH = extra.inc\n'
  printf '[remote "origin"]\n\tpush = HEAD:main\n' > "$dir/.git/extra.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_include_deny_nested_system_relative() {
  local dir="$tmpbase/repo-include-nested-system" sysroot="$tmpbase/sysroot-include-nested"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$sysroot/etc/gitconfig" $'[include]\n\tpath = a.inc\n'
  mk_fixture_global_config "$sysroot/etc/a.inc" $'[include]\n\tpath = b.inc\n'
  mk_fixture_global_config "$sysroot/etc/b.inc" $'[remote "origin"]\n\tpush = HEAD:main\n'
  push_sysroot_override="$sysroot"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *"your system git config (via include)"*) ;;
    *) __ok=0; __why="${__why}stderr does not name the nested include source label 'your system git config (via include)': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"(via include) (via include)"*) __ok=0; __why="${__why}stderr doubles the include suffix: '$push_err'\n" ;;
    *) ;;
  esac
}
case_push_include_deny_at_depth_cap() {
  local dir="$tmpbase/repo-include-depth-cap" i j
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = c1.inc\n'
  for i in 1 2 3 4 5 6 7 8 9; do
    j=$((i + 1))
    printf '[include]\n\tpath = c%d.inc\n' "$j" > "$dir/.git/c${i}.inc"
  done
  printf '[remote "origin"]\n\tpush = HEAD:main\n' > "$dir/.git/c10.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_include_noop_beyond_depth_cap() {
  local dir="$tmpbase/repo-include-beyond-depth-cap" i j
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = c1.inc\n'
  for i in 1 2 3 4 5 6 7 8 9 10; do
    j=$((i + 1))
    printf '[include]\n\tpath = c%d.inc\n' "$j" > "$dir/.git/c${i}.inc"
  done
  printf '[remote "origin"]\n\tpush = HEAD:main\n' > "$dir/.git/c11.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_include_deny_second_path_after_return() {
  local dir="$tmpbase/repo-include-second-path"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = a.inc\n\tpath = b.inc\n'
  printf '[push]\n\tdefault = current\n' > "$dir/.git/a.inc"
  printf '[remote "origin"]\n\tpush = HEAD:main\n' > "$dir/.git/b.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_include_deny_mutual_cycle() {
  local dir="$tmpbase/repo-include-mutual-cycle"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = a.inc\n'
  printf '[include]\n\tpath = config\n[push]\n\tdefault = matching\n' > "$dir/.git/a.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_include_noop_self_cycle() {
  local dir="$tmpbase/repo-include-self-cycle"
  mk_fixture_repo "$dir" main "claude/17-a"
  mk_fixture_config "$dir" $'[include]\n\tpath = config\n\tpath = config\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_include_noop_missing_target() {
  local dir="$tmpbase/repo-include-missing-target"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = missing.inc\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_include_noop_prefix_form() {
  local dir="$tmpbase/repo-include-prefix-form"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = %(prefix)/etc/extra.inc\n'
  mkdir -p "$dir/.git/%(prefix)/etc"
  printf '[remote "origin"]\n\tpush = HEAD:main\n' > "$dir/.git/%(prefix)/etc/extra.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_include_deny_repo_config_reincluded() {
  # Pins that the seen-list is ANCESTOR-ONLY, never a whole resolve_repo()-call history. Repo
  # .git/config sets push.default=upstream and branch.merge=refs/heads/main; a GLOBAL candidate's
  # own [include] pulls in an ABSOLUTE copy of that SAME .git/config path (setting the identical
  # two values transiently), then the global file's own NEXT line overwrites merge to
  # refs/heads/feature/x. Real git still reads the repo's own LOCAL scope, on its own, LAST — its
  # merge=refs/heads/main value wins the race. A whole-call seen-list would wrongly treat the
  # repo-local top-level candidate's own later, mandatory re-read of that identical absolute path
  # as "already seen" (from the global include) and skip it, leaving branch.merge at "feature/x"
  # (not a deny-set member) instead of "main" — an under-block: no opinion where real git denies.
  local dir="$tmpbase/repo-include-reincluded" home="$tmpbase/home-include-reincluded"
  local body
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = upstream\n[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  body="$(printf '[include]\n\tpath = %s/.git/config\n[branch "feature/x"]\n\tmerge = refs/heads/feature/x\n' "$dir")"
  mk_fixture_global_config "$home/.gitconfig" "$body"
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_include_noop_tilde_user() {
  # Unpinned clause: "~user/…" is never followed (falls to the bare "\~*" skip arm, tried before
  # the generic relative-path fallback) — even when a file exists at that literal path.
  local dir="$tmpbase/repo-include-tilde-user"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = ~user/x.inc\n'
  mkdir -p "$dir/.git/~user"
  printf '[remote "origin"]\n\tpush = HEAD:main\n' > "$dir/.git/~user/x.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_include_noop_directory_target() {
  # Unpinned clause: a non-regular include target (a directory, never a FIFO — portable and never
  # hangs) is never opened; expect_push_no_opinion's own empty-stderr check backstops this too.
  local dir="$tmpbase/repo-include-directory-target"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = d.inc\n'
  mkdir -p "$dir/.git/d.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_include_noop_tilde_empty_home() {
  # Unpinned clause: "~/…" is never followed when $HOME is empty (set, but the empty string) —
  # $push_home_empty exports HOME= for this one call; the denying target exists on disk at its own
  # absolute path, proving the miss is the empty-HOME guard, not a missing file.
  local dir="$tmpbase/repo-include-tilde-empty-home"
  local target="$tmpbase/tilde-empty-home-target/deny.inc"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$target" $'[remote "origin"]\n\tpush = HEAD:main\n'
  mk_fixture_config "$dir" "$(printf '[include]\n\tpath = ~%s\n' "$target")"
  push_home_empty=1
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_include_noop_drive_letter() {
  # Unpinned clause: an "X:/…" value is used AS-IS (never joined to the including file's own
  # directory), so it resolves against the hook's own cwd, not $dir/.git — the denying file placed
  # at $dir/.git/C:/x.inc is never the one checked, and stays missing from the hook's own cwd.
  local dir="$tmpbase/repo-include-drive-letter"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = C:/x.inc\n'
  mkdir -p "$dir/.git/C:"
  printf '[remote "origin"]\n\tpush = HEAD:main\n' > "$dir/.git/C:/x.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_include_deny_fanout_toplevel_route() {
  # A config tree that repeats the SAME include path K times per level fans out to about K^depth
  # follow operations (the ancestor-only seen-list's own re-read-every-sibling stance, applied
  # recursively). The deny route here lives in .git/config ITSELF, after the fan-out's own
  # [include] block -- a depth-0 top-level read, never budgeted by line count (since #435, its own
  # single-line LENGTH is capped, but this short line is nowhere near that cap) -- so
  # it must still be found once CFG_INCLUDE_MAX_FOLLOWS and CFG_INCLUDE_MAX_LINES together bound
  # the fan-out's own recursion.
  local dir="$tmpbase/repo-include-fanout-toplevel" k=3 depth=7 lvl next i
  mk_fixture_repo "$dir" main feature/x
  {
    printf '[include]\n'
    i=0
    while [ "$i" -lt "$k" ]; do
      printf '\tpath = l1.inc\n'
      i=$((i + 1))
    done
    printf '[push]\n\tdefault = matching\n'
  } > "$dir/.git/config"
  lvl=1
  while [ "$lvl" -lt "$depth" ]; do
    next=$((lvl + 1))
    {
      printf '[include]\n'
      i=0
      while [ "$i" -lt "$k" ]; do
        printf '\tpath = l%d.inc\n' "$next"
        i=$((i + 1))
      done
    } > "$dir/.git/l${lvl}.inc"
    lvl=$next
  done
  printf '[core]\n\teditor = vi\n' > "$dir/.git/l${depth}.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_include_noop_over_budget() {
  # The follow-budget is DETERMINISTICALLY testable without relying on wall-clock timing. 65
  # DISTINCT includes (never a repeated sibling, so this is not itself a fan-out) exhaust
  # CFG_INCLUDE_MAX_FOLLOWS=64 on the first 64 (all benign); the 65th, and only denying, include is
  # never followed -- proving the budget's own boundary is exact.
  local dir="$tmpbase/repo-include-over-budget" i
  mk_fixture_repo "$dir" main feature/x
  printf '[include]\n' > "$dir/.git/config"
  i=1
  while [ "$i" -le 65 ]; do
    printf '\tpath = i%02d.inc\n' "$i" >> "$dir/.git/config"
    i=$((i + 1))
  done
  i=1
  while [ "$i" -le 64 ]; do
    printf '[core]\n\teditor = vi\n' > "$dir/.git/i$(printf '%02d' "$i").inc"
    i=$((i + 1))
  done
  printf '[push]\n\tdefault = matching\n' > "$dir/.git/i65.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_include_noop_over_line_budget() {
  # CFG_INCLUDE_MAX_LINES bounds total lines read from included files (depth >= 1), shared for the
  # whole resolve_repo() call, never reset per file -- one included file's own [push] header (line
  # 1) plus CFG_INCLUDE_MAX_LINES-1 harmless comment-only filler lines exhaust the budget exactly;
  # its own denying key line, one line past the budget, is never read (the comment-strip already
  # reduces each filler line to empty before the section/key dispatch ever sees it, so it changes
  # no parser state of its own -- only the [push] section set on line 1 persists).
  local dir="$tmpbase/repo-include-over-line-budget" n=2048 i
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = big.inc\n'
  printf '[push]\n' > "$dir/.git/big.inc"
  i=2
  while [ "$i" -le "$n" ]; do
    printf '; filler\n' >> "$dir/.git/big.inc"
    i=$((i + 1))
  done
  printf '\tdefault = matching\n' >> "$dir/.git/big.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_include_deny_within_line_budget() {
  # The exact same shape as push-include-noop-over-line-budget with ONE FEWER filler line, so the
  # denying key line lands AT the budget boundary (still read) rather than one line past it.
  local dir="$tmpbase/repo-include-within-line-budget" n=2048 i
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = big.inc\n'
  printf '[push]\n' > "$dir/.git/big.inc"
  i=2
  while [ "$i" -le $((n - 1)) ]; do
    printf '; filler\n' >> "$dir/.git/big.inc"
    i=$((i + 1))
  done
  printf '\tdefault = matching\n' >> "$dir/.git/big.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_include_deny_longline_toplevel_route() {
  # A single, very long included line (well past CFG_INCLUDE_MAX_LINE_CHARS) must be skipped
  # cheaply -- checked with ${#cfgline} alone, never reaching cfg_trim's own pattern matching,
  # whose cost is NOT linear in a long trailing whitespace run (see cfg_trim()'s own header
  # comment) -- so the denying route in .git/config ITSELF, after the include, is still found, and
  # found FAST.
  local dir="$tmpbase/repo-include-longline-toplevel" astr spstr
  mk_fixture_repo "$dir" main feature/x
  astr="a"
  while [ "${#astr}" -lt 10000 ]; do astr="$astr$astr"; done
  astr="${astr:0:10000}"
  spstr=" "
  while [ "${#spstr}" -lt 10000 ]; do spstr="$spstr$spstr"; done
  spstr="${spstr:0:10000}"
  mk_fixture_config "$dir" $'[include]\n\tpath = big.inc\n'
  printf '[core]\n\tx = %s%s\n' "$astr" "$spstr" > "$dir/.git/big.inc"
  printf '[push]\n\tdefault = matching\n' >> "$dir/.git/config"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_include_noop_over_line_chars() {
  # Boundary: a route line padded to CFG_INCLUDE_MAX_LINE_CHARS+1 characters is skipped for length
  # before comment-strip or trim ever run -- the padding is a trailing comment (stripped before
  # dispatch on a line that IS processed, but this line never reaches that step at all), so the
  # padded length is exactly what decides the outcome, not the padding's own content.
  local dir="$tmpbase/repo-include-over-line-chars" base pad line
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = big.inc\n'
  base=$'\tdefault = matching ; '
  pad="x"
  while [ "${#pad}" -lt 600 ]; do pad="$pad$pad"; done
  pad="${pad:0:$((513 - ${#base}))}"
  line="${base}${pad}"
  printf '[push]\n%s\n' "$line" > "$dir/.git/big.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_include_deny_within_line_chars() {
  # The exact same shape as push-include-noop-over-line-chars, padded to exactly
  # CFG_INCLUDE_MAX_LINE_CHARS characters (one fewer) instead of one past it -- still processed.
  local dir="$tmpbase/repo-include-within-line-chars" base pad line
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = big.inc\n'
  base=$'\tdefault = matching ; '
  pad="x"
  while [ "${#pad}" -lt 600 ]; do pad="$pad$pad"; done
  pad="${pad:0:$((512 - ${#base}))}"
  line="${base}${pad}"
  printf '[push]\n%s\n' "$line" > "$dir/.git/big.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_include_noop_over_char_budget() {
  # Boundary: CFG_INCLUDE_MAX_CHARS is charged "${#cfgline}+1" per depth>=1 line, BEFORE the
  # line-length cap is even checked, and a line over-length is still charged before it is skipped
  # for length -- so ONE oversized filler line can precisely exhaust the shared character budget. A
  # [push] header (charge 7) plus one 65509-character filler line (charge 65510) leaves the budget
  # at -1 by the time the final denying key line (charge 20) would need it -- never read.
  local dir="$tmpbase/repo-include-over-char-budget" filler
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = big.inc\n'
  filler="x"
  while [ "${#filler}" -lt 65509 ]; do filler="$filler$filler"; done
  filler="${filler:0:65509}"
  {
    printf '[push]\n'
    printf '%s\n' "$filler"
    printf '\tdefault = matching\n'
  } > "$dir/.git/big.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_include_deny_within_char_budget() {
  # The exact same shape as push-include-noop-over-char-budget with the filler line ONE FEWER
  # character (65508, charge 65509), so the budget lands at exactly 0 -- not negative -- by the
  # time the denying key line's own charge (20) is needed, and it is still read.
  local dir="$tmpbase/repo-include-within-char-budget" filler
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = big.inc\n'
  filler="x"
  while [ "${#filler}" -lt 65508 ]; do filler="$filler$filler"; done
  filler="${filler:0:65508}"
  {
    printf '[push]\n'
    printf '%s\n' "$filler"
    printf '\tdefault = matching\n'
  } > "$dir/.git/big.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_include_deny_long_toplevel_route() {
  # Depth-0 (top-level) candidates never consult the line budget: a .git/config file with far more
  # than CFG_INCLUDE_MAX_LINES lines, with its own denying route at the very end, must still be
  # found in full -- proving a long TOP-LEVEL file is never truncated the way an included file is.
  local dir="$tmpbase/repo-include-long-toplevel" i
  mk_fixture_repo "$dir" main feature/x
  printf '[push]\n' > "$dir/.git/config"
  i=1
  while [ "$i" -le 2100 ]; do
    printf '; filler\n' >> "$dir/.git/config"
    i=$((i + 1))
  done
  printf '\tdefault = matching\n' >> "$dir/.git/config"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_push_include_deny_c_target_fresh_budget() {
  # All three include budgets (follow, line-count, character) reset per resolve_repo() call
  # (session and "-C" alike): the SESSION's own config exhausts all three at the SAME time -- 64
  # includes (using up every follow -- the follow-gate itself only refuses a follow still to come,
  # so every one of the 64 must actually succeed for the follow budget to reach zero), each with
  # exactly 32 UNIFORM comment-only lines of exactly 31 characters (a 32-character charge per line,
  # and 64*32 lines == CFG_INCLUDE_MAX_LINES and 64*32*32 characters == CFG_INCLUDE_MAX_CHARS,
  # both exactly), none of it denying (each line strips to empty and is skipped). The resolved "-C"
  # target's only route lives behind ONE include of its own, which must still be followed under
  # its own fresh budgets, independent of the session's own exhausted ones.
  local main="$tmpbase/repo-include-fresh-budget" target="$tmpbase/target-fb-wt-1" i j body content31
  mk_fixture_repo "$main" main feature/x
  printf '[include]\n' > "$main/.git/config"
  content31=";000000000000000000000000000000"
  i=1
  while [ "$i" -le 64 ]; do
    printf '\tpath = s%02d.inc\n' "$i" >> "$main/.git/config"
    body=""
    j=1
    while [ "$j" -le 32 ]; do
      body="${body}${content31}"$'\n'
      j=$((j + 1))
    done
    printf '%s' "$body" > "$main/.git/$(printf 's%02d' "$i").inc"
    i=$((i + 1))
  done
  mk_fixture_repo "$target" trunk feature/y
  mk_fixture_config "$target" $'[include]\n\tpath = t.inc\n'
  printf '[remote "origin"]\n\tpush = HEAD:main\n' > "$target/.git/t.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../target-fb-wt-1 push' "$main")"
  expect_push_deny
}
case_push_include_noop_budget_gates_follow() {
  # The FIRST include (big.inc) exhausts CFG_INCLUDE_MAX_CHARS in one oversized line; the SECOND
  # include names a real, existing, permission-denied (mode 000) file. The follow-gate (the include
  # arm's own line-budget/char-budget conjuncts) must refuse to open the SECOND include at all --
  # not even [ -f ] -- once budget is empty. Without the gate, bash's own failed redirect
  # (permission denied on the read) leaks an OS-level error line onto stderr, which
  # expect_push_no_opinion rejects; that stderr line is the only thing this proof observes. It
  # assumes a non-root runner: root ignores the mode bits, opens the file, and the per-line budget
  # checks stop before its first line is parsed, so with or without the gate the verdict is no
  # opinion with empty stderr, and the proof is vacuous under root. The file's route
  # (`push.default = matching`) is never reached either way.
  local dir="$tmpbase/repo-include-budget-gates-follow" filler
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = big.inc\n\tpath = noperm.inc\n'
  filler="x"
  while [ "${#filler}" -lt 65600 ]; do filler="$filler$filler"; done
  filler="${filler:0:65600}"
  printf '%s\n' "$filler" > "$dir/.git/big.inc"
  printf '[push]\n\tdefault = matching\n' > "$dir/.git/noperm.inc"
  chmod 000 "$dir/.git/noperm.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_include_noop_line_budget_gates_follow() {
  # The sibling of push-include-noop-budget-gates-follow, isolating the LINE-budget conjunct
  # specifically: the FIRST include (manylines.inc) is exactly CFG_INCLUDE_MAX_LINES one-character
  # lines, exhausting the line budget to precisely zero while charging only a small fraction of the
  # character budget (each line is cheap) and only one of CFG_INCLUDE_MAX_FOLLOWS follows. The
  # SECOND include names a real, existing, permission-denied (mode 000) file. With follows and
  # characters both still comfortably positive, only the line-budget conjunct can be what refuses
  # to open the SECOND include; as above, the proof observes only the non-root permission-denied
  # stderr line, so it assumes a non-root runner and is vacuous under root.
  local dir="$tmpbase/repo-include-line-budget-gates-follow" body j
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = manylines.inc\n\tpath = noperm2.inc\n'
  body=""
  j=1
  while [ "$j" -le 2048 ]; do
    body="${body};"$'\n'
    j=$((j + 1))
  done
  printf '%s' "$body" > "$dir/.git/manylines.inc"
  printf '[push]\n\tdefault = matching\n' > "$dir/.git/noperm2.inc"
  chmod 000 "$dir/.git/noperm2.inc"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_push_include_deny_never_executes() {
  local dir="$tmpbase/repo-include-never-executes" home="$tmpbase/home-include-never-executes"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[include]\n\tpath = extra.inc\n'
  printf '[remote "origin"]\n\tpush = HEAD:main\n' > "$dir/.git/extra.inc"
  mk_fixture_global_config "$home/.gitconfig" $'[include]\n\tpath = ~/x.inc\n'
  mk_fixture_global_config "$home/x.inc" $'[core]\n\teditor = vi\n'
  local trapdir="$tmpbase/trapbin-include-deny" sentinel="$tmpbase/sentinel-include-deny"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before_repo after_repo before_home after_home
  before_repo="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  before_home="$(find "$home" -type f -exec ls -la {} \; | sort)"
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")" "$trapdir:$PATH"
  after_repo="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  after_home="$(find "$home" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH while following an include\n"; }
  [ "$before_repo" = "$after_repo" ] || { __ok=0; __why="${__why}fixture repo's file listing changed — push-guard.sh wrote to or altered a file it should only read (include route)\n"; }
  [ "$before_home" = "$after_home" ] || { __ok=0; __why="${__why}fixture HOME's file listing changed — push-guard.sh wrote to or altered a file it should only read (include route)\n"; }
}

# --- #510: a config key on its section header's line, and the header spellings git accepts -------
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter
# "push-hdrkey-"), re-run by dev/mutant-driver.sh. Every fixture is a scratch repo on feature/x (or
# featx) with default branch main, an explicit cwd, and the neutral HOME run_push_guard isolates.
# mutant:510-pg-hdr-rest-off — the text after a header's closing bracket never reaches the key split,
#   so a key written on its header's line is never read.
# mutant:510-pg-hdr-raw — drops the re-derivation of the header from the raw line, so the comment
#   strip cuts a subsection name or an includeIf condition holding # or ; short again.
# mutant:510-pg-hdr-quoted-end — a quoted header's remainder starts after the first bracket even when
#   that bracket sits inside the quoted name.
# mutant:510-pg-hdr-simple-end — a plain header's remainder starts after the last bracket on the line,
#   so a bracket inside a same-line value swallows the key.
# mutant:510-pg-hdr-rest-nostrip — the remainder after a header keeps its trailing comment.
# mutant:510-pg-hdr-chain-off — drops the deny for a second header in the remainder, which is then
#   split as a key and silently ignored.
# mutant:510-pg-hdr-escape-off — drops the deny for a closing quote that follows a backslash.
# mutant:510-pg-hdr-escape-strict — denies a name ending in a backslash even when only the closing
#   bracket follows it.
# mutant:510-pg-hdr-after-quote-off — drops the deny for text after the closing quote that is not the
#   closing bracket.
# mutant:510-pg-hdr-namepart-off — drops the deny for junk between the section name and the quote.
# mutant:510-pg-hdr-canon-off — drops the rewrite to the canonical `[name "sub"]` text, so the TAB,
#   blank-run and any-spacing spellings fall to the generic section.
# mutant:510-pg-hdr-dotted-off — a dotted header is never read as a subsection.
# mutant:510-pg-hdr-ws-space-only — the blank run before the quote accepts a space only, so a TAB
#   there denies as junk.
# mutant:510-pg-hdr-backslash-off — drops the deny for a backslash in a remote or branch subsection.
# mutant:510-pg-hdr-dotted-upper-off — drops the deny for an uppercase letter in a dotted subsection.
# mutant:510-pg-hdr-dotted-scope — records the whole dotted text, section name included, as the
#   subsection.
# mutant:510-pg-hdr-reason — the unclassifiable-header deny prints the over-long-line reason.
# mutant:510-pg-hdr-mixed-off — a mixed header (`[branch.v1 "2"]`) is rewritten with the quoted part
#   alone as the subsection, dropping the dotted part git joins to it.
# mutant:510-pg-hdr-mixed-upper-off — drops the deny for an uppercase letter in the dotted part of a
#   mixed header.
# mutant:510-pg-hdr-quoted-upper — applies the dotted-subsection uppercase deny to quoted
#   subsections too, so `[remote "Upstream"]` (a quoted name keeps its case) denies.
# mutant:510-pg-hdr-bom-off — never strips the byte-order mark from a file's first line.
# HK_CONFIGHDR_LINE is hand-typed from hooks/push-guard.sh's deny_too_large confighdr arm, so a
# drift between the two is a visible test diff; the line carries no input text.
HK_CONFIGHDR_LINE="trail-blazer-flow push guard: denies this git command: a git config file it reads has a section header line it cannot split the way git does (blocked: unparseable config header line) — put that section header on a line of its own, or run the command from a terminal; see README.md's Safety model"
HK_TAB=$'\t'
hk_inc=""
# hk_run TAG BODY CMD [BRANCH] — builds the repo (an optional $hk_inc body becomes .git/extra.inc,
# cleared after) and runs push-guard on CMD from it. The helpers below tag any failure with TAG, so
# a case holding several shapes names the one that broke.
hk_run() {
  local tag="$1" body="$2" cmd="$3" br="${4:-feature/x}"
  hk_dir="$tmpbase/repo-hdrkey-$tag"
  rm -rf "$hk_dir"
  mk_fixture_repo "$hk_dir" main "$br"
  mk_fixture_config "$hk_dir" "$body"
  if [ -n "$hk_inc" ]; then printf '%s' "$hk_inc" > "$hk_dir/.git/extra.inc"; fi
  hk_inc=""
  run_push_guard "$(mk_push_cmd_cwd "$cmd" "$hk_dir")"
}
hk_tag() { [ "$__why" = "$1" ] || __why="${__why}  ^ fixture $2\n"; }
# hk_cdeny — a deny through the config route, naming .git/config.
hk_cdeny() {
  local w="$__why"
  hk_run "$@"
  expect_push_deny
  case "$push_err" in
    *"denies pushing to"*"in .git/config"*|*"pushes every matching branch"*"in .git/config"*) ;;
    *) __ok=0; __why="${__why}stderr is not the config-route line naming .git/config: '$push_err'\n" ;;
  esac
  hk_tag "$w" "$1"
}
# hk_hdr — the fixed confighdr deny line, exactly.
hk_hdr() {
  local w="$__why"
  hk_run "$@"
  expect_push_deny_exact "$HK_CONFIGHDR_LINE"
  hk_tag "$w" "$1"
}
hk_noop() {
  local w="$__why"
  hk_run "$@"
  expect_push_no_opinion
  hk_tag "$w" "$1"
}
# hk_alias — an alias deny naming SRC, never echoing the alias name.
hk_alias() {
  local w="$__why" src="$4"
  hk_run "$1" "$2" "$3"
  al_expect_alias "$src"
  al_expect_no_echo "zqp"
  hk_tag "$w" "$1"
}
hk_pad() { printf '%*s' "$1" ''; }

case_push_hdrkey_deny_remote_same_line() {
  hk_cdeny bare '[remote "origin"] push = HEAD:main
' 'git push'
  hk_cdeny named '[remote "origin"] push = HEAD:main
' 'git push origin'
  hk_cdeny nospace '[remote "origin"]push=HEAD:main
' 'git push'
  hk_cdeny crlf "[remote \"origin\"]push=HEAD:main${CR}
" 'git push'
  hk_cdeny note '[remote "origin"] push = HEAD:main # note
' 'git push'
}
case_push_hdrkey_deny_remote_name_chars() {
  hk_cdeny bracket '[remote "a]b"] push = HEAD:main
' 'git push'
  hk_cdeny semicolon '[remote "back;up"] push = HEAD:main
' 'git push'
  hk_cdeny hash-next-line '[remote "back#up"]
	push = HEAD:main
' 'git push'
}
case_push_hdrkey_deny_sections_same_line() {
  hk_cdeny push-default '[push] default = matching
' 'git push'
  hk_cdeny branch-merge '[push]
	default = upstream
[branch "feature/x"] merge = refs/heads/main
' 'git push'
  hk_inc='[remote "origin"]
	push = HEAD:main
'
  hk_cdeny include '[include] path = extra.inc
' 'git push'
  hk_inc='[remote "origin"]
	push = HEAD:main
'
  hk_cdeny includeif '[includeIf "gitdir:/nonexistent-510/"] path = extra.inc
' 'git push'
  hk_inc='[remote "origin"]
	push = HEAD:main
'
  hk_cdeny includeif-hash '[includeIf "gitdir:/x#y/"]
	path = extra.inc
' 'git push'
}
case_push_hdrkey_deny_in_included_file() {
  hk_inc='[remote "origin"] push = HEAD:main
'
  hk_cdeny same-line '[include]
	path = extra.inc
' 'git push'
  hk_inc='[remote.origin]
	push = HEAD:main
'
  hk_cdeny dotted '[include]
	path = extra.inc
' 'git push origin'
  hk_inc="[remote${HK_TAB}\"origin\"]
	push = HEAD:main
"
  hk_cdeny tab '[include]
	path = extra.inc
' 'git push origin'
}
case_push_hdrkey_deny_cap_length_header() {
  # A depth-0 header line of exactly CFG_TOPLEVEL_MAX_LINE_CHARS characters, ending in a same-line push
  # key, is within the cap: it reads as a route, and does not deny as an over-cap line.
  local head='[remote "origin"]' tail='push = HEAD:main' n
  n=$((DL_TOPLEVEL_MAX_LINE_CHARS - ${#head} - ${#tail}))
  hk_cdeny cap-header "$head$(hk_pad "$n")$tail
" 'git push'
}
case_push_hdrkey_deny_alias_same_line() {
  hk_alias alias '[alias] zqp = push
' 'git zqp origin main' ".git/config"
  hk_alias sub '[alias "zqp"] command = push
' 'git zqp origin main' ".git/config"
  hk_alias sub-tab "[alias${HK_TAB}\"zqp\"] command = push
" 'git zqp origin main' ".git/config"
  hk_alias dotted '[alias.zqp] command = push
' 'git zqp origin main' ".git/config"
  hk_alias semicolon-in-name '[alias "zq;p"] command = push
' 'git zqp origin main' ".git/config"
  hk_alias bracket-in-value '[alias] zqp = "!f() { [ -n x ]; git push; }; f"
' 'git zqp origin main' ".git/config"
  local home="$tmpbase/home-hdrkey-alias"
  mk_fixture_global_config "$home/.gitconfig" '[alias] zqp = push
'
  push_home_override="$home"
  hk_alias global '' 'git zqp origin main' "your global git config"
}
case_push_hdrkey_deny_new_spellings() {
  hk_cdeny remote-dotted '[remote.origin]
	push = HEAD:main
' 'git push origin'
  hk_cdeny remote-tab "[remote${HK_TAB}\"origin\"]
	push = HEAD:main
" 'git push origin'
  hk_cdeny remote-two-blanks '[remote  "origin"]
	push = HEAD:main
' 'git push origin'
  hk_cdeny remote-mixed-case '[Remote.origin]
	push = HEAD:main
' 'git push origin'
  hk_cdeny dotted-same-line '[remote.origin] push = HEAD:main
' 'git push origin'
  hk_cdeny branch-dotted '[push]
	default = upstream
[branch.featx]
	merge = refs/heads/main
' 'git push' featx
  hk_cdeny branch-tab "[push]
	default = upstream
[branch${HK_TAB}\"feature/x\"]
	merge = refs/heads/main
" 'git push'
  hk_inc='[remote "origin"]
	push = HEAD:main
'
  hk_cdeny includeif-tab "[includeIf${HK_TAB}\"gitdir:/nonexistent-510/\"]
	path = extra.inc
" 'git push'
}
case_push_hdrkey_deny_mixed_spellings() {
  # A dotted section part followed by a quoted subsection: git joins them (branch.v1 + "2" is the
  # branch v1.2, remote.my + "fork" the remote my.fork).
  hk_cdeny branch-mixed '[push]
	default = upstream
[branch.v1 "2"]
	merge = refs/heads/main
' 'git push' v1.2
  hk_cdeny remote-mixed '[remote.my "fork"]
	push = HEAD:main
' 'git push my.fork'
  hk_inc='[remote.my "fork"]
	push = HEAD:main
'
  hk_cdeny remote-mixed-in-include '[include]
	path = extra.inc
' 'git push my.fork'
  hk_alias alias-mixed '[alias.x "y"] command = push
' 'git zqp origin main' ".git/config"
}
case_push_hdrkey_deny_confighdr_mixed_upper() {
  # git lowercases the dotted part of a mixed header, which this hook cannot do: it denies.
  hk_hdr branch-mixed-upper '[push]
	default = upstream
[Branch.V1 "2"]
	merge = refs/heads/main
' 'git push' v1.2
}
case_push_hdrkey_deny_bom() {
  # git skips a UTF-8 byte-order mark at the start of a config file, so the first header still counts.
  local bom=$'\357\273\277' home="$tmpbase/home-hdrkey-bom"
  hk_cdeny bom-depth0 "$bom"'[remote "origin"]
	push = HEAD:main
' 'git push'
  hk_inc="$bom"'[remote "origin"]
	push = HEAD:main
'
  hk_cdeny bom-in-include '[include]
	path = extra.inc
' 'git push'
  mk_fixture_global_config "$home/.gitconfig" "$bom"'[remote "origin"]
	push = HEAD:main
'
  push_home_override="$home"
  hk_run bom-global '' 'git push'
  expect_push_deny
  case "$push_err" in
    *"your global git config"*) ;;
    *) __ok=0; __why="${__why}bom-global: stderr does not name the global config: '$push_err'\n" ;;
  esac
}
case_push_hdrkey_deny_confighdr_chained() {
  hk_hdr chained '[core] [remote "origin"] push = HEAD:main
' 'git push'
  hk_hdr chained-next-line '[core] [remote "origin"]
	push = HEAD:main
' 'git push'
  hk_inc='[core] [remote "origin"]
'
  hk_hdr in-include '[include]
	path = extra.inc
' 'git push'
  hk_hdr feature-push '[core] [user]
' 'git push origin feature/x'
  hk_hdr non-push '[core] [user]
' 'git status'
}
case_push_hdrkey_deny_confighdr_quote_shapes() {
  hk_hdr escaped-close-quote '[remote "a\"] push = HEAD:main"]
' 'git push'
  hk_hdr escaped-backslash-name '[alias "zqp\\"] command = push
' 'git zqp origin main'
  hk_hdr space-before-bracket '[remote "origin" ] push = HEAD:main
' 'git push'
  hk_hdr name-junk '[remote x "origin"]
	push = HEAD:main
' 'git push'
}
case_push_hdrkey_deny_confighdr_backslash() {
  hk_hdr remote '[remote "or\igin"]
	push = HEAD:main
' 'git push origin'
  hk_hdr branch '[push]
	default = upstream
[branch "feature\/x"]
	merge = refs/heads/main
' 'git push'
  hk_inc='[remote "or\igin"]
	push = HEAD:main
'
  hk_hdr in-include '[include]
	path = extra.inc
' 'git push origin'
}
case_push_hdrkey_deny_confighdr_dotted_upper() {
  hk_hdr remote-dotted-upper '[remote.Origin]
	push = HEAD:main
' 'git push origin'
}
case_push_hdrkey_deny_never_executes() {
  # The confighdr route runs nothing from a booby-trapped PATH, and writes nothing under the fixture.
  local dir="$tmpbase/repo-hdrkey-never-executes"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[core] [remote "origin"] push = HEAD:main\n'
  local trapdir="$tmpbase/trapbin-hdrkey" sentinel="$tmpbase/sentinel-hdrkey"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before after
  before="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")" "$trapdir:$PATH"
  after="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  expect_push_deny_exact "$HK_CONFIGHDR_LINE"
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH on the confighdr route\n"; }
  [ "$before" = "$after" ] || { __ok=0; __why="${__why}fixture repo's file listing changed — push-guard.sh wrote to a file it should only read (confighdr route)\n"; }
}
case_push_hdrkey_noop_controls() {
  hk_noop remote-url '[remote "origin"] url = https://example.invalid/r.git
' 'git push'
  hk_noop comment-after-header '[remote "origin"] # push = HEAD:main
' 'git push'
  hk_noop comment-bracket '[core] # see [remote "origin"] push = HEAD:main
' 'git push'
  hk_noop alias-nonpush '[alias] st = status
' 'git st'
  hk_noop other-dest '[remote "origin"] push = HEAD:refs/heads/feature/x
' 'git push'
  hk_noop explicit-refspec '[remote "origin"] push = HEAD:main
' 'git push -u origin "claude/17-a"'
  # A quoted subsection keeps its case: this is the remote Upstream, not origin.
  hk_noop remote-quoted-upper '[remote "Upstream"]
	push = HEAD:main
' 'git push origin'
  # A dotted section for another remote, and a subsection-less [remote], never apply to origin.
  hk_noop dotted-other-remote '[remote.backup]
	push = HEAD:main
' 'git push origin'
  hk_noop remote-no-subsection '[remote]
	push = HEAD:main
' 'git push origin'
}
case_push_hdrkey_noop_escaped_name() {
  # A subsection name ending in a backslash pair, with nothing after the closing bracket, is
  # readable: it is not the escaped-quote shape, so it does not deny.
  hk_noop escaped-name-alone '[includeIf "gitdir:/x\\"]
' 'git push'
}

# --- #403: the eval/trap/zsh-precommand-modifier class ------------------------------------------
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter
# "push-pc-"), re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table.
# mutant:403-pg-pc-vocab — reverts PREFIX_WORDS to its pre-#403 (#398) value (drops eval/trap/
#   noglob/nocorrect/-/repeat), so every fixture below whose command relies on skipping one of
#   those words no longer resolves git as the command word.
# mutant:403-pg-pc-repeat — removes the `repeat`-count skip, so a `repeat N` prefix leaves the
#   count token itself as the resolved command word instead of the real command.
# mutant:403-pg-pc-dbracket — disables the additive `]]` pass entirely (db_rest set to empty), so a
#   zsh short `if [[ cond ]] cmd` form never resumes command position at `cmd`, whether the `]]` is
#   mid-line, opens a second physical line, or is tab-bounded. Since #435, this also flips
#   push-pc-deny-dbracket-timing's own reason: with the additive pass disabled outright, that
#   fixture's flood+filler record never produces the CUT-push verdict the baseline asserts (the
#   record's own trailing "git push origin main" denies via the ordinary default-branch route
#   instead, fast) -- caught as a second, independent way this mutant fails that case, alongside the
#   dbracket-specific cases below.
# mutant:403-pg-pc-dbracket-truncate — reverts the MAIN segment split to the pre-fix truncating
#   form (turning `]]` into a newline on that same pass), so a push segment whose own refspec/option
#   tokens have a literal `]]` token among them (e.g. `git push origin ]] main`, `git push ]] --all`)
#   loses the tokens past the `]]` from ITS OWN "PUSH" token list, even though the separate additive
#   pass still resumes `]]`'s own short-if handling correctly.
# mutant:403-pg-pc-dbracket-nopad — removes the space-padding around the additive pass's own copy of
#   the record, so a `]]` sitting at the very start of a physical line (nothing of its own before
#   it, e.g. the second line of a multi-line command) is no longer bounded and never resolved.
# mutant:403-pg-pc-dbracket-spaceonly — narrows the additive pass's boundary character class from
#   `[ \t]` to `[ ]` (space only), so a `]]` bounded by a TAB rather than a space is no longer
#   recognised.
# mutant:403-pg-pc-empty-tok — deletes the empty-normalised-token skip in the command-word walk,
#   so a token that normalises to empty ends the walk with an empty command word instead of being
#   skipped.
# mutant:403-pg-pc-empty-sub — deletes the empty-normalised-token skip in the subcommand search, so
#   a lone leftover quote token there is mistaken for the subcommand instead of being skipped past.
# No `cwd` is passed for any fixture below: each carries n >= 2 refspec tokens, so the
# unconditional PUSH_DEFAULT_BRANCH_FALLBACK ("main"/"master") decides without needing a resolved
# repo.
case_push_pc_deny_eval() {
  run_push_guard "$(mk_push_cmd 'eval git push origin main')"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
case_push_pc_deny_eval_quoted() {
  run_push_guard "$(mk_push_cmd "eval 'git push origin main'")"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
case_push_pc_deny_eval_lead_space() {
  run_push_guard "$(mk_push_cmd 'eval " git push origin main"')"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
case_push_pc_deny_eval_split() {
  # The quoted string splits "git" from "push" across two tokens; the leftover closing-quote
  # token in between must be skipped, not mistaken for the subcommand.
  run_push_guard "$(mk_push_cmd 'eval "git " push origin main')"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
case_push_pc_deny_trap() {
  run_push_guard "$(mk_push_cmd "trap 'git push origin main' EXIT")"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
case_push_pc_deny_noglob() {
  run_push_guard "$(mk_push_cmd 'noglob git push origin main')"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
case_push_pc_deny_nocorrect() {
  run_push_guard "$(mk_push_cmd 'nocorrect git push origin main')"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
case_push_pc_deny_dash() {
  run_push_guard "$(mk_push_cmd '- git push origin main')"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
case_push_pc_deny_repeat() {
  run_push_guard "$(mk_push_cmd 'repeat 2 git push origin main')"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
case_push_pc_deny_short_if() {
  run_push_guard "$(mk_push_cmd 'if [[ 1 ]] git push origin main')"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
case_push_pc_noop_eval_feature() {
  run_push_guard "$(mk_push_cmd 'eval git push origin feature/x')"
  expect_push_no_opinion
}
# --- hooks/push-guard.sh: the additive `]]` handling must never truncate an existing deny ----------
# A base (pre-#403) push-guard deny whose own refspec-evaluation loop finds a denying destination
# AFTER a literal `]]` token among the push's other tokens must still fire: the segment (and its
# full "PUSH\t...\trest" token list) the main split produces is untouched by the additive `]]`
# pass, which only ADDS further segments, never truncates existing ones.
case_push_pc_deny_dbracket_refspec() {
  run_push_guard "$(mk_push_cmd 'git push origin ]] main')"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
case_push_pc_deny_dbracket_all() {
  run_push_guard "$(mk_push_cmd 'git push ]] --all')"
  expect_push_deny
  case "$push_err" in
    *'denies "--all"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies \"--all\"': '$push_err'\n" ;;
  esac
}
# Boundary variants of the additive `]]` handling itself (see the identical agent-boundary.sh
# fixtures above): a `]]` opening a second physical line with nothing of its own before it, and a
# `]]` bounded by a TAB rather than a space, must both still resume command position.
case_push_pc_deny_dbracket_multiline() {
  run_push_guard "$(mk_push_cmd "if [[ 1${LF}]] git push origin main")"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
case_push_pc_deny_dbracket_tab() {
  run_push_guard "$(mk_push_cmd "if [[ 1 ]]${DBTAB}git push origin main")"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
# --- hooks/push-guard.sh: bounded, disjoint additive `]]` work --------------------------------------
# mutant:403-pg-pc-dbracket-once — changes the additive loop's `while` to `if`, so only the FIRST
#   standalone `]]` in a record is ever handled; a later `]]` whose own tail carries the deciding
#   push is never reached.
# mutant:403-pg-pc-dbracket-cap — removes the `db_n >= dbracket_max` check, so a record with more
#   standalone `]]` than DBRACKET_MAX is analysed in full instead of failing closed.
case_push_pc_deny_dbracket_second() {
  # The deciding `]]` is the SECOND one in the record, not the first.
  run_push_guard "$(mk_push_cmd 'if [[ 1 ]] true; if [[ 1 ]] git push origin main')"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
case_push_pc_deny_dbracket_flood() {
  # A flood of standalone `]]` (more than DBRACKET_MAX) followed by a REAL `;`-separated
  # `git push origin main` segment: the deny comes from the untouched MAIN split, unaffected by the
  # additive cap or by how the additive tails are cut. This case checks only the VERDICT; it does
  # not measure elapsed time -- see case_push_pc_deny_dbracket_timing below for the dedicated
  # wall-clock proof that the additive loop stays bounded rather than growing with how many `]]` a
  # record carries.
  local flood="" i
  for i in $(seq 1 70); do flood="${flood} ]]"; done
  run_push_guard "$(mk_push_cmd "${flood}; git push origin main")"
  expect_push_deny
  case "$push_err" in
    *'denies pushing to "main"'*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'denies pushing to \"main\"': '$push_err'\n" ;;
  esac
}
case_push_pc_deny_dbracket_cap() {
  # Exactly DBRACKET_MAX + 1 standalone `]]`, then a push to a NON-default branch: without the cap,
  # the additive loop would eventually reach this "git push origin feature/x" tail and correctly
  # find no opinion (not a deny destination) -- WITH the cap, the loop fails closed before ever
  # reaching that tail, so only the cap's own sentinel can deny this record at all.
  local flood="" i
  for i in $(seq 1 65); do flood="${flood}]] "; done
  run_push_guard "$(mk_push_cmd "${flood}git push origin feature/x")"
  expect_push_deny
  case "$push_err" in
    *"(blocked: too many ]] tokens to analyse)"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(blocked: too many ]] tokens to analyse)': '$push_err'\n" ;;
  esac
}
# mutant:403-pg-pc-dbracket-overlap — restores overlapping tails (drops the standalone-`]]`
#   alternative from the disjoint cut regex), so `if [[ a ]] git push origin ]] main`'s tail runs
#   past the second `]]` and resolves the ordinary default-branch reason directly instead of failing
#   closed on the CUT tail (the new reason). On case_push_pc_deny_dbracket_timing below's larger
#   (~1.4KB) shape, the CORRECT (disjoint-tail) baseline itself denies via the CUT-push reason (the
#   first standalone `]]`'s own cut tail is just "git push", which resolves and cuts closed before
#   ever reaching the trailing "git push origin main" record) -- that case now asserts this reason.
#   With the overlap mutant restored, each of the 64 tails re-scans almost the whole remaining
#   record as its own PUSH line, whose own REST is that same near-full text; evaluate_segment()'s
#   refspec loop then forks a real refspec_dest() subshell per remaining token, once per tail. Since
#   #435, check_deadline() is sampled inside that very refspec loop, so it is this SAMPLED,
#   per-token fork cost (not the tokenizer's own unsampled awk pass) that the next check_deadline()
#   call catches once it crosses the budget, denying with the deadline's own fixed reason instead --
#   either way the mutant is still caught by reason, not only by the 5s wall-clock bound.
case_push_pc_deny_dbracket_split_push() {
  # Disjoint tails alone would lose this deny: the tail after the first `]]` is cut at the SECOND
  # `]]`, leaving "git push origin" with no destination -- resolved as a CUT push (see
  # emit_segment()'s own subcmd handling), which fails closed with its own distinct reason instead of
  # the default-branch one evaluate_segment() never gets a chance to compute. Pins that the cut-push
  # fail-closed rule, not an accidental full scan, is what still denies this.
  run_push_guard "$(mk_push_cmd 'if [[ a ]] git push origin ]] main')"
  expect_push_deny
  case "$push_err" in
    *"(cannot analyse a push split by ]])"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(cannot analyse a push split by ]])': '$push_err'\n" ;;
  esac
}
# mutant:403-pg-pc-dbracket-subcmd-open — drops the subcommand-still-open fail-closed check (reverts
#   to a bare `if (subcmd != "push") return`), so a cut tail whose subcommand search never concludes
#   (stopped mid-value, consuming a global option with no value token left in the cut segment) is
#   silently treated as no opinion instead of failing closed.
case_push_pc_deny_dbracket_split_subcmd() {
  # The tail after the first `]]` is cut at the SECOND `]]`, leaving "git -C" -- the subcommand
  # search then tries to consume "-C"'s own value token, finds none within this cut segment, and
  # never resolves an actual subcommand. Without the subcommand-still-open check, this silently
  # returns no opinion instead of failing closed.
  run_push_guard "$(mk_push_cmd 'if [[ a ]] git -C ]] push origin main')"
  expect_push_deny
  case "$push_err" in
    *"(cannot analyse a push split by ]])"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(cannot analyse a push split by ]])': '$push_err'\n" ;;
  esac
}
case_push_pc_deny_dbracket_timing() {
  # Wall-clock proof: an overlapping tail forks a refspec_dest subshell per refspec on EVERY tail,
  # over almost the whole remaining record each time; disjoint tails bound each emit_segment() walk
  # to its own cut segment instead, so this ~1.4KB shape (`x` + ` ]] git push`x64 + ` a`x300, a real
  # newline, then `git push origin main`) resolves in well under the 5s bound below (measured via
  # bash SECONDS, timing only the hook invocation itself, not payload construction).
  local flood="x" i
  for i in $(seq 1 64); do flood="${flood} ]] git push"; done
  local filler
  filler="$(printf ' a%.0s' $(seq 1 300))"
  local payload
  payload="$(mk_push_cmd "${flood}${filler}
git push origin main")"
  local start=$SECONDS elapsed
  run_push_guard "$payload"
  elapsed=$((SECONDS - start))
  expect_push_deny
  # #435: asserts the reason too, not only rc/timing -- the correct, disjoint-tail baseline denies
  # via the CUT-push reason, the SAME one case_push_pc_deny_dbracket_split_push above asserts (the
  # first standalone `]]`'s own cut tail resolves to a bare "git push" with no destination, cut
  # closed before the driver loop ever reaches the trailing "git push origin main" record). With the
  # 403-pg-pc-dbracket-overlap mutant restored (see that mutant's own comment above for the
  # refspec_dest()-fork mechanism), the resulting real wall-clock cost is instead what the analysis
  # deadline's own next check_deadline() call catches -- a DIFFERENT fixed reason -- so the mutant
  # is still caught by this reason check even if a future, looser timing bound would otherwise let
  # it slip through on wall clock alone.
  case "$push_err" in
    *"(cannot analyse a push split by ]])"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain '(cannot analyse a push split by ]])': '$push_err'\n" ;;
  esac
  [ "$elapsed" -lt 5 ] || { __ok=0; __why="${__why}took ${elapsed}s (SECONDS-granularity), expected under 5s\n"; }
}

# --- hooks/push-guard.sh: analysis deadline (#435) --------------------------------------------
# Cases pinning check_deadline()'s call sites, the early scan_out exit, and the depth-0
# config-line-length cap. Every payload below is built with mk_push_cmd_big (jq on stdin, never
# --arg), and every fixture passes an explicit cwd, the same AMBIENT-$PWD/AMBIENT-$HOME rules the
# rest of this file's push fixtures already follow. Unless noted, the command's final segment is a
# default-branch push, so a sample site that is REMOVED (rather than merely neutered) still lets
# the flood run to completion and deny via that ordinary route instead -- most of these cases are
# killed by REASON (DL_DEADLINE_LINE/DL_CONFIGLINE_LINE vs. an ordinary deny message), not by wall
# clock alone.
case_push_dl_deny_budget_zero() {
  # mutant:435-dl-check-off -- neuters check_deadline()'s body to a no-op; with the knob at 0,
  # push_deadline == push_t0, so the very first sample (right after the tokenizer, well before this
  # non-default push would otherwise reach a "no opinion" verdict) must deny -- with check_deadline
  # neutered, this ordinary feature/x push has no opinion instead.
  local dir="$tmpbase/repo-dl-budget-zero"
  mk_fixture_repo "$dir" main feature/x
  push_budget_override="0"
  run_push_guard "$(mk_push_cmd_big 'git push origin feature/x' "$dir")"
  expect_push_deny_exact "$DL_DEADLINE_LINE"
}
case_push_dl_noop_budget_zero_no_push() {
  # mutant:435-dl-scan-empty-exit -- deletes the pre-deadline early exit; a command with no push
  # segment and no git alias candidate at all must stay "no opinion" even at knob 0 -- without the
  # early exit, control falls straight into the very next statement, check_deadline itself, which
  # denies immediately at budget 0. The command word is echo, not git: since #448 a bare git log is
  # an alias candidate, which the early exit deliberately lets through to the config lookup.
  push_budget_override="0"
  run_push_guard "$(mk_push_cmd_big 'echo git log --grep=push' "$tmpbase")"
  expect_push_no_opinion
}
case_push_dl_noop_budget_zero_xseg_no_push() {
  # mutant:435-dl-xseg-early-exit -- makes the early exit fire only on an EMPTY scan again; a command
  # with a cd (so #433's "-xseg-" marker line is emitted) but no push segment and no git alias
  # candidate (the command word of the second segment is echo, #448) must still stay "no opinion" at
  # knob 0, since that marker alone never denies.
  push_budget_override="0"
  run_push_guard "$(mk_push_cmd_big 'cd x && echo git log --grep=push' "$tmpbase")"
  expect_push_no_opinion
}
case_push_dl_deny_production_budget() {
  # mutant:435-dl-check-off; mutant:435-dl-knob-raise -- FLOOD + TIMING (route 1: a flood of push
  # segments). Knob 99 is two ASCII digits but not less than the production budget (5s), so it must
  # be IGNORED -- 10000 harmless "git push o a a a a a;" segments each cost five
  # refspec_dest() forks in evaluate_segment()'s n>=2 loop but never deny (remote "o" is skipped,
  # and a bare "a" refspec never resolves to a deny member), so only check_deadline (sampled once
  # per driver-loop iteration, and again inside each of evaluate_segment()'s own loops) can stop
  # this well before the flood ever reaches the final "git push origin main" segment. With
  # check-off, the knob-0 control below can never print the deadline line, so the case fails there
  # and returns before the timed run. With knob-raise adopting the ignored 99s budget, the timed
  # flood instead runs past the calibrated active deadline below (#463) and this case's own
  # kill_tree ends it, or completes and denies via that final segment's ordinary reason.
  local dir="$tmpbase/repo-dl-production-budget"
  mk_fixture_repo "$dir" main feature/x
  push_budget_override="99"
  local flood
  flood="$(printf 'git push o a a a a a;%.0s' $(seq 1 10000))"
  local payload
  payload="$(mk_push_cmd_big "${flood}git push origin main" "$dir")"
  # Same-run control (#476's design rule): the identical payload at knob 0 denies at the hook's
  # first sample, so its wall time is the unsampled prefix (jq over the large payload plus the awk
  # tokenizer over every segment) that eats into the production budget. The active deadline for the
  # timed run is the production budget (hand-typed 5, the hook's PUSH_ANALYSIS_BUDGET_SECS) plus one
  # whole-second sample window plus a K-scaled multiple of that prefix, capped well below the time
  # the unsampled flood needs, so the knob-raise mutant's timed flood still runs past it.
  push_budget_override="0"
  push_deadline_override=15
  measure_ms run_push_guard "$payload"
  if [ -z "$measured_ms" ]; then
    __ok=0; __why="${__why}knob-0 control's timing report could not be parsed -- can't calibrate a deadline\n"
    return
  fi
  expect_push_deny_exact "$DL_DEADLINE_LINE"
  if [ "$__ok" -eq 0 ]; then
    __why="${__why}knob-0 control did not deny at the first sample\n"
    return
  fi
  calibrated_deadline 3 4 "$measured_ms"
  local active_deadline=$((5 + 1 + calibrated_secs))
  [ "$active_deadline" -le 20 ] || active_deadline=20
  push_budget_override="99"
  push_deadline_override="$active_deadline"
  run_push_guard "$payload"
  # mutant:463-hook-push-override-leaks — run_push_guard's own trailing
  #   `push_deadline_override=""` reset deleted: this assertion is the only thing that would catch
  #   the override surviving into the NEXT case, since a leaked value here still happens to equal
  #   what this case itself just set.
  [ -z "$push_deadline_override" ] || { __ok=0; __why="${__why}push_deadline_override not cleared after run_push_guard: '$push_deadline_override'\n"; }
  expect_push_deny_exact "$DL_DEADLINE_LINE"
}
case_push_dl_deny_driver_site() {
  # mutant:435-dl-check-off; mutant:435-dl-driver-site -- a bare `-C` push (n == 0) runs ZERO
  # iterations of every evaluate_segment() loop (word-splitting an empty REST yields no tokens), the
  # resolved lane carries no config of its own (so cfg_parse_file()'s read loop never runs), and
  # config_deny's lists are empty. The samples reachable are the post-tokenizer one (the one
  # dl_site_run's knob-0 control measures; the calibrated budget keeps it from firing first) and,
  # once the loop starts, the driver loop's own check_deadline call, sampled once per PUSH line
  # dequeued. 3000 resolved "-C" targets (route 3: many resolved -C lanes), each a fresh
  # resolve_repo() call, then a final bare session push -- without the driver-loop sample, the flood
  # runs past the 9s harness deadline or the final push denies via the session's own current branch
  # instead.
  local main="$tmpbase/repo-dl-drv" wt="$tmpbase/dl-drv-wt-1"
  mk_fixture_repo "$main" main main
  mk_fixture_repo "$wt" trunk feature/x
  local flood payload
  flood="$(printf 'git -C ../dl-drv-wt-1 push;%.0s' $(seq 1 3000))"
  payload="$(mk_push_cmd_big "${flood}git push" "$main")"
  dl_site_run "$payload"
}
case_push_dl_deny_evaluate_sites() {
  # mutant:435-dl-check-off; mutant:435-dl-evaluate-sites -- ONE push segment whose own refspec list
  # is huge (10000 harmless "a" tokens, then "main"): before evaluate_segment() runs, only the
  # post-tokenizer sample (the one dl_site_run's knob-0 control measures) and the driver loop's
  # single sample for this one segment are reachable, so without evaluate_segment()'s own four
  # internal samples, its refspec loop (idx 1..n-1) runs to completion in one shot and finds "main"
  # as the last refspec, denying via that ordinary dest reason instead. The cwd is a fixture repo
  # so the session resolves at depth 0: a non-git cwd made resolve_repo walk dirname upward
  # through a host-dependent TMPDIR depth, between those two samples, where the control cannot
  # see it. "main" is a deny member through the session default.
  local dir="$tmpbase/repo-dl-evaluate-sites"
  mk_fixture_repo "$dir" main feature/x
  local filler payload
  filler="$(printf ' a%.0s' $(seq 1 10000))"
  payload="$(mk_push_cmd_big "git push origin${filler} main" "$dir")"
  dl_site_run "$payload"
}
case_push_dl_deny_config_lines() {
  # mutant:435-dl-check-off; mutant:435-dl-cfgline-site -- a bare `-C` push (n == 0, so no
  # evaluate_segment() loop ever iterates -- see case_push_dl_deny_driver_site above) resolves a
  # lane whose depth-0 config is M harmless "[core]" lines, each safely UNDER the new
  # CFG_TOPLEVEL_MAX_LINE_CHARS cap (so the length cap never fires): once past the post-tokenizer
  # sample (the one dl_site_run's knob-0 control measures) and the driver loop's single sample,
  # both before the parse, only cfg_parse_file()'s own read-loop sample can stop this mid-parse.
  # Without it, the whole file is read and trimmed in full, then the lane's OWN current branch
  # (main) gives an ordinary dest deny with no sampled loop ever having run. The S-only work here
  # is the lane's config file, not the payload, so M can grow without raising the control's cost;
  # it is sized for timed budgets up to DL_KNOB_MAX, not a fixed 1s knob. The session's fixture
  # repo has no config.
  local main="$tmpbase/repo-dl-cfg" wt="$tmpbase/dl-cfg-wt-1"
  mk_fixture_repo "$main" trunk feature/x
  mk_fixture_repo "$wt" main main
  local sp line_lit body
  sp="$(printf ' %.0s' $(seq 1 400))"
  # $(...) strips printf's own trailing newline, so it is re-added outside the substitution; the
  # printf '%.0s' idiom below (mirroring case_ab_pc_deny_dbracket_timing/mk_push_cmd_big's own
  # flood builders) then repeats this one already-newline-terminated line M times without ever
  # building the whole body via O(n^2) bash string concatenation.
  line_lit="$(printf '\tx = y%s' "$sp")"$'\n'
  body="[core]"$'\n'"$(printf "${line_lit}%.0s" $(seq 1 6000))"
  mk_fixture_config "$wt" "$body"
  dl_site_run "$(mk_push_cmd_big 'git -C ../dl-cfg-wt-1 push' "$main")"
}
case_push_dl_deny_c_lane_flood() {
  # mutant:435-dl-check-off -- FLOOD (route 3: many resolved -C lanes). Many resolved "-C" targets,
  # each with an [include] pointing at a 2000-line, all-comment big.inc (no route, cheap per line,
  # but real per-line and per-resolution overhead across that many separate resolve_repo() calls
  # adds up -- sized, per the approved sizing rule, so the check-off run comfortably clears the
  # required multiple of the knob), then a final bare session push to "main" -- without
  # check_deadline (sampled both in the driver loop, once per segment, and inside
  # cfg_parse_file()'s own read loop, once per include line), the flood completes and the final
  # segment denies via the ordinary fallback route instead.
  local main="$tmpbase/repo-dl-inc" wt="$tmpbase/dl-inc-wt-1"
  mk_fixture_repo "$main" trunk feature/y
  mk_fixture_repo "$wt" trunk feature/z
  mk_fixture_config "$wt" $'[include]\n\tpath = big.inc\n'
  printf ';c\n%.0s' $(seq 1 2000) > "$wt/.git/big.inc"
  push_budget_override="1"
  push_deadline_override=9
  local flood
  flood="$(printf 'git -C ../dl-inc-wt-1 push origin feature/x;%.0s' $(seq 1 120))"
  run_push_guard "$(mk_push_cmd_big "${flood}git push origin main" "$main")"
  expect_push_deny_exact "$DL_DEADLINE_LINE"
}
case_push_dl_deny_toplevel_longline() {
  # mutant:435-dl-toplevel-cap -- TIMING (route 2: one long whitespace-run line in a depth-0
  # config). Production budget (no knob): the resolved lane's LAST (and only consequential) config
  # line is "\tx = a" plus 20000 trailing spaces, well over the cap -- caught instantly by
  # `${#cfgline}` before cfg_trim() ever runs on it. Without the cap, this single line's whole-line
  # and value trims each cost real seconds against bash's own glob engine (see cfg_trim()'s own
  # header comment), there is no LATER line left for the read-loop's check_deadline sample to catch
  # (this is the last line in the file), and the lane's own current branch (main) then gives an
  # ordinary dest deny -- running past the 9s active deadline below (#463) instead.
  local main="$tmpbase/repo-dl-longline" wt="$tmpbase/dl-long-wt-1"
  mk_fixture_repo "$main" trunk feature/x
  mk_fixture_repo "$wt" main main
  local sp
  sp="$(printf ' %.0s' $(seq 1 20000))"
  mk_fixture_config "$wt" "[core]"$'\n\tx = a'"${sp}"$'\n'
  push_deadline_override=9
  run_push_guard "$(mk_push_cmd_big 'git -C ../dl-long-wt-1 push' "$main")"
  expect_push_deny_exact "$DL_CONFIGLINE_LINE"
}
case_push_dl_deny_toplevel_over_cap() {
  # mutant:435-dl-toplevel-cap -- the session's OWN config carries a denying
  # "remote.origin.push = HEAD:main" route, but padded with a trailing, unquoted ";"-comment of 'x'
  # characters to exactly ONE character past CFG_TOPLEVEL_MAX_LINE_CHARS. The raw line's own length
  # (checked BEFORE comment-strip) is what must deny here, with the DIFFERENT (configline) reason --
  # not the ordinary remote.origin.push route the comment-stripped, short remainder would otherwise
  # still reach. Without the cap, the trailing 'x' run is cheap (comment-strip removes it before
  # cfg_trim ever sees it), so this denies via the ordinary route instead.
  local dir="$tmpbase/repo-dl-over-cap"
  mk_fixture_repo "$dir" trunk feature/x
  local prefix pad
  prefix=$'\tpush = HEAD:main ;'
  pad="$(printf 'x%.0s' $(seq 1 $((DL_TOPLEVEL_MAX_LINE_CHARS + 1 - ${#prefix}))))"
  mk_fixture_config "$dir" '[remote "origin"]'$'\n'"${prefix}${pad}"$'\n'
  run_push_guard "$(mk_push_cmd_big 'git push' "$dir")"
  expect_push_deny_exact "$DL_CONFIGLINE_LINE"
}
case_push_dl_deny_toplevel_at_cap() {
  # mutant:435-dl-toplevel-cap-off-by-one -- the identical shape as
  # case_push_dl_deny_toplevel_over_cap, padded to EXACTLY CFG_TOPLEVEL_MAX_LINE_CHARS: a line this
  # long must still be parsed normally (Acceptance criteria), reaching the ordinary
  # remote.origin.push route. An off-by-one cap (`-lt` instead of `-le`) instead denies this
  # boundary-length line outright, with the wrong (configline) reason.
  local dir="$tmpbase/repo-dl-at-cap"
  mk_fixture_repo "$dir" trunk feature/x
  local prefix pad
  prefix=$'\tpush = HEAD:main ;'
  pad="$(printf 'x%.0s' $(seq 1 $((DL_TOPLEVEL_MAX_LINE_CHARS - ${#prefix}))))"
  mk_fixture_config "$dir" '[remote "origin"]'$'\n'"${prefix}${pad}"$'\n'
  run_push_guard "$(mk_push_cmd_big 'git push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *"via remote.origin.push in .git/config"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'via remote.origin.push in .git/config': '$push_err'\n" ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# hooks/claude-dir-guard.sh (#327; apply_patch/.codex/Bash-shim routes added #407 — see the
# separate cdg-patch-*/cdg-codexseg-* section further down for those) fixture builders, runner,
# and assertions for the ORIGINAL Edit/Write, ".claude"-only surface. This hook has three
# verdicts — deny via the ".claude" segment class (exit 2, empty stdout, one stderr line naming
# the role, the tool, and the blocked path), deny via the unclassifiable/fail-closed class (exit
# 2, empty stdout, one stderr line with DISTINCT wording naming the path), or no opinion (exit 0,
# empty stdout, empty stderr) — for every case listed in the approved #327 plan's "Testing
# approach": the ".claude" segment class across both tools (Edit/Write), both roles
# (implementer/verifier), and all four agent_type spellings distributed across those combinations;
# a nested segment; a user-level path entirely outside any repo checkout (pins deliberate
# location-independence — the file_path route this section exercises reads no cwd/repo-root at
# all; the apply_patch and Bash routes #407 added DO read the stdin JSON's own cwd field to resolve
# a relative header path, still with no filesystem access — see the cdg-patch-*/cdg-codexseg-*
# section's own header); a case-variant spelling; the
# Windows drive-letter and backslash-spelled forms; ".claude" as the path's final segment; a
# CR-carrying spelling; a relative path that IS ".claude/..." (still denies via the ".claude"
# message, discriminated from a relative PLAIN path via the unclassifiable message by
# cdg-deny-rel-claude/cdg-deny-rel-plain below); a ".."-carrying path with ".claude" present
# (still the ".claude" message, since that class is checked first) and one without (the
# unclassifiable message); every documented no-opinion shape, including the two release-blocker
# controls (a main-session Write to .claude/LESSONS.md, the orchestrator's own lesson-append path,
# and a verifier-role Edit of a tracked source file, the mutation probe's own shape); and the same
# booby-trapped git/gh/rm/dirname/tr/awk/grep/sed PATH idiom plus a byte-identical fixture-tree
# listing proving this hook — which performs NO filesystem access at all, stricter than either
# hooks/agent-boundary.sh or hooks/push-guard.sh — never executes or writes anything.

mk_cdg_agent_path() { jq -n --arg agent "$1" --arg tool "$2" --arg fp "$3" '{tool_name: $tool, agent_type: $agent, tool_input: {file_path: $fp}}'; }
mk_cdg_agent_path_mode() { jq -n --arg agent "$1" --arg tool "$2" --arg fp "$3" --arg mode "$4" '{tool_name: $tool, agent_type: $agent, tool_input: {file_path: $fp}, permission_mode: $mode}'; }
# mk_cdg_missing_file_path AGENT TOOL — tool_input.file_path absent, but the raw JSON still
# contains the literal 'agent_type' substring (via the agent_type field itself) so this case
# actually reaches the "file_path empty" check instead of passing vacuously via the fast path
# (LESSON 2026-08-26's analogue, mirroring mk_agent_missing_command/mk_push_missing_command above).
mk_cdg_missing_file_path() { jq -n --arg agent "$1" --arg tool "$2" '{tool_name: $tool, agent_type: $agent, tool_input: {}}'; }
# mk_cdg_main_session TOOL FILE_PATH — no agent_type key at all (the main-session shape, M1).
mk_cdg_main_session() { jq -n --arg tool "$1" --arg fp "$2" '{tool_name: $tool, tool_input: {file_path: $fp}}'; }

# mk_cdg_dl_bash AGENT MODE / mk_cdg_dl_patch AGENT (#457) — payload builders for the analysis-
# deadline fixtures: the Bash command (or the apply_patch patch text) is read from STDIN via jq -Rs,
# never a --arg, since a flood payload can pass the byte budget a single --arg value carries. cwd is
# "/repo". AGENT "" omits agent_type (the main-session shape); MODE "" omits permission_mode.
mk_cdg_dl_bash() {
  jq -Rs --arg agent "$1" --arg mode "$2" '
    {tool_name: "Bash", cwd: "/repo", tool_input: {command: .}}
    + (if $agent != "" then {agent_type: $agent} else {} end)
    + (if $mode != "" then {permission_mode: $mode} else {} end)'
}
mk_cdg_dl_patch() {
  jq -Rs --arg agent "$1" '
    {tool_name: "apply_patch", cwd: "/repo", tool_input: {command: .}}
    + (if $agent != "" then {agent_type: $agent} else {} end)'
}

# run_claude_guard JSON [PATHVAL] — runs the real claude-dir-guard.sh script against JSON on
# stdin, with PATH set to PATHVAL (defaults to this process's own PATH), leaving $cdg_out
# (stdout)/$cdg_err (stderr, read back from a file under $tmpbase)/$cdg_rc set as globals. Same
# separate-stdout/stderr-capture idiom as run_boundary/run_push_guard above (LESSON 2026-09-08b) —
# a merged capture cannot pin "exactly one line on stderr, nothing on stdout". $cdg_deadline_override
# (#463) is an opt-in override, the same shape as run_boundary's own: unset by default (the
# foreground path below), and when a case sets it immediately
# before calling run_claude_guard, this runner instead runs the script backgrounded under
# wait_deadline at that many seconds, killing its whole process tree on overrun instead of letting
# the case block on it. Cleared after every call either way. #457: both paths now run the script
# through ( cdg_exec … ), which unsets the hook's two test-only knobs
# (TBF_CLAUDE_DIR_GUARD_BUDGET_SECS, TBF_CLAUDE_DIR_GUARD_SAMPLE_CAP) so an exported value in the
# harness's own environment never reaches a fixture, then re-exports each only from the two
# override globals below ($cdg_budget_override, $cdg_cap_override), both cleared after every call
# like $cdg_deadline_override.
cdg_out=""
cdg_err=""
cdg_rc=0
cdg_deadline_override=""
cdg_budget_override=""
cdg_cap_override=""
cdg_locale_override=""
# cdg_exec PATHVAL (#457) — the env block every run_claude_guard call execs into; mirrors
# push_guard_exec. MUST be called only inside an explicit "( … )": run in the harness's own shell
# it would leak its exports and PATH, and its own `exec` would replace the harness process itself.
cdg_exec() {
  local pathval="$1"
  unset TBF_CLAUDE_DIR_GUARD_BUDGET_SECS TBF_CLAUDE_DIR_GUARD_SAMPLE_CAP
  [ -z "$cdg_budget_override" ] || export TBF_CLAUDE_DIR_GUARD_BUDGET_SECS="$cdg_budget_override"
  [ -z "$cdg_cap_override" ] || export TBF_CLAUDE_DIR_GUARD_SAMPLE_CAP="$cdg_cap_override"
  [ -z "$cdg_locale_override" ] || export LC_ALL="$cdg_locale_override"
  export PATH="$pathval"
  exec "$bash_bin" "$claude_dir_guard"
}
run_claude_guard() {
  local json="$1" pathval="${2:-$PATH}" errfile="$tmpbase/cdg-stderr"
  if [ -n "$cdg_deadline_override" ]; then
    local stdin_file="$tmpbase/cdg-stdin" out_file="$tmpbase/cdg-out" cpid
    printf '%s' "$json" > "$stdin_file"
    ( cdg_exec "$pathval" ) < "$stdin_file" > "$out_file" 2> "$errfile" &
    cpid=$!
    wait_deadline "$cpid" "$cdg_deadline_override"
    cdg_rc=$deadline_rc
    cdg_out="$(cat "$out_file" 2>/dev/null)"
    rm -f "$out_file" "$stdin_file"
  else
    cdg_out="$(printf '%s' "$json" | ( cdg_exec "$pathval" ) 2>"$errfile")"
    cdg_rc=$?
  fi
  cdg_err="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
  cdg_deadline_override=""
  cdg_budget_override=""
  cdg_cap_override=""
  cdg_locale_override=""
}

# expect_cdg_deny_claude/expect_cdg_deny_unclassifiable/expect_cdg_no_opinion — assert against
# $cdg_out/$cdg_err/$cdg_rc. Each deny helper hand-types its own literal stem/phrase inline rather
# than taking a needle parameter — this file's own substring tests do this throughout, with one
# exception, `expect_push_deny_exact` (#435), which does take a needle and guards it against being
# empty (see CLAUDE.md's empty-needle bullet).
expect_cdg_deny_claude() {
  [ "$cdg_rc" -eq 2 ] || { __ok=0; __why="${__why}rc: expected 2, got $cdg_rc\n"; }
  [ -z "$cdg_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$cdg_out'\n"; }
  local err_lines
  err_lines="$(printf '%s\n' "$cdg_err" | grep -c '[^[:space:]]')"
  [ "$err_lines" -eq 1 ] || { __ok=0; __why="${__why}expected exactly 1 non-blank stderr line, got $err_lines: '$cdg_err'\n"; }
  case "$cdg_err" in
    *"trail-blazer-flow claude-dir guard:"*"a path under a .claude segment"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the .claude-segment deny stem/phrase: '$cdg_err'\n" ;;
  esac
}
expect_cdg_deny_unclassifiable() {
  [ "$cdg_rc" -eq 2 ] || { __ok=0; __why="${__why}rc: expected 2, got $cdg_rc\n"; }
  [ -z "$cdg_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$cdg_out'\n"; }
  local err_lines
  err_lines="$(printf '%s\n' "$cdg_err" | grep -c '[^[:space:]]')"
  [ "$err_lines" -eq 1 ] || { __ok=0; __why="${__why}expected exactly 1 non-blank stderr line, got $err_lines: '$cdg_err'\n"; }
  case "$cdg_err" in
    *"trail-blazer-flow claude-dir guard:"*"could not be classified as absolute or normalised"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the unclassifiable deny stem/phrase: '$cdg_err'\n" ;;
  esac
}
expect_cdg_no_opinion() {
  [ "$cdg_rc" -eq 0 ] || { __ok=0; __why="${__why}rc: expected 0, got $cdg_rc\n"; }
  [ -z "$cdg_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$cdg_out'\n"; }
  [ -z "$cdg_err" ] || { __ok=0; __why="${__why}expected empty stderr, got: '$cdg_err'\n"; }
}

# expect_cdg_deny_too_large ROLE TOOL (#457) — the analysis-deadline deny: rc 2, empty stdout, and
# the WHOLE stderr equal to the one fixed line, hand-typed here with ROLE and TOOL spliced in.
# Refuses an empty ROLE or TOOL (see CLAUDE.md's empty-needle bullet).
expect_cdg_deny_too_large() {
  local r="$1" t="$2" want
  if [ -z "$r" ] || [ -z "$t" ]; then
    __ok=0; __why="${__why}expect_cdg_deny_too_large: needle_required (empty role or tool)\n"
    return
  fi
  want="trail-blazer-flow claude-dir guard: ${r} role's ${t} call is too large to analyse before the hook's time limit (blocked: too large to analyse), and is denied fail-closed — split it into smaller calls"
  [ "$cdg_rc" -eq 2 ] || { __ok=0; __why="${__why}rc: expected 2, got $cdg_rc\n"; }
  [ -z "$cdg_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$cdg_out'\n"; }
  [ "$cdg_err" = "$want" ] || { __ok=0; __why="${__why}stderr is not exactly the too-large line: '$cdg_err'\n"; }
}

# --- deny: ".claude" segment ---------------------------------------------------------------
# The four agent_type spellings distributed across both tools and both roles (LESSON 2026-09-08:
# both spellings exercised per role).
case_cdg_deny_impl_write_bare() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Write' '/repo/.claude/settings.json')"; expect_cdg_deny_claude; }
case_cdg_deny_impl_edit_ns()    { run_claude_guard "$(mk_cdg_agent_path 'trail-blazer-flow:implementer' 'Edit' '/repo/.claude/foo.md')"; expect_cdg_deny_claude; }
case_cdg_deny_verif_write_ns()  { run_claude_guard "$(mk_cdg_agent_path 'trail-blazer-flow:verifier' 'Write' '/repo/.claude/bar.json')"; expect_cdg_deny_claude; }
case_cdg_deny_verif_edit_bare() { run_claude_guard "$(mk_cdg_agent_path 'verifier' 'Edit' '/repo/.claude/baz.md')"; expect_cdg_deny_claude; }
case_cdg_deny_nested() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Write' '/Users/x/proj/.claude/settings.json')"; expect_cdg_deny_claude; }
case_cdg_deny_user_level() {
  # Deliberate location-independence: this path is OUTSIDE any repo checkout entirely (not even
  # shaped like one), and the hook still denies it — the classifier judges the string alone, with
  # no cwd/repo-root notion at all.
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/Users/x/.claude/settings.json')"
  expect_cdg_deny_claude
}
case_cdg_deny_case_variant() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/.Claude/x')"; expect_cdg_deny_claude; }
case_cdg_deny_drive_letter() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' 'C:/Users/x/.claude/foo')"; expect_cdg_deny_claude; }
case_cdg_deny_backslash()    { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' 'C:\Users\x\.claude\foo')"; expect_cdg_deny_claude; }
case_cdg_deny_final_segment() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/foo/.claude')"; expect_cdg_deny_claude; }
case_cdg_deny_crlf() {
  # A CR embedded inside the ".claude" spelling itself ($CR, declared above alongside the
  # push-guard/agent-boundary CRLF fixtures) — the strip can only WIDEN toward deny (see the
  # hook's own header), so this must still deny via the SAME ".claude" message.
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' "/repo/.clau${CR}de/foo")"
  expect_cdg_deny_claude
}
case_cdg_deny_rel_claude() {
  # A relative path whose very FIRST segment is ".claude" — no leading "/" for a naive
  # "*/.claude/*" pattern to anchor against; still denies via the ".claude" message (see the
  # hook's own header note on why the classifier checks "/$p/", not "$p/" alone).
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '.claude/LESSONS.md')"
  expect_cdg_deny_claude
}
case_cdg_deny_dotdot_claude() {
  # A ".."-carrying ABSOLUTE path that also carries a real ".claude" segment: the MORE SPECIFIC
  # ".claude" message wins (checked first), never the unclassifiable one.
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/Users/x/../.claude/y')"
  expect_cdg_deny_claude
}
case_cdg_deny_lf_claude() {
  # #327 round-1 kickback (K1): an embedded LF elsewhere in an otherwise-denying ".claude" path
  # must still print exactly ONE stderr line, not two — pre-fix, this printed 2 (measured). The
  # classifier still matches the raw $p (with the LF intact); only the PRINTED copy folds it.
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Write' "/repo/.claude/a${LF}b.md")"
  expect_cdg_deny_claude
}

# --- deny: unclassifiable (fail-closed) -----------------------------------------------------
case_cdg_deny_rel_plain() {
  # Discriminates the two deny classes against case_cdg_deny_rel_claude above: the identical
  # "relative, no leading slash" shape, but with NO ".claude" segment anywhere -> the OTHER,
  # distinctly-worded deny message.
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' 'src/main.rs')"
  expect_cdg_deny_unclassifiable
}
case_cdg_deny_dotdot_no_claude() {
  # A ".."-carrying ABSOLUTE path with no ".claude" segment anywhere: denies fail-closed, per the
  # triage record, even though it never mentions ".claude" at all.
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/Users/x/../etc/passwd')"
  expect_cdg_deny_unclassifiable
}
case_cdg_deny_lf_unclassifiable() {
  # #327 round-1 kickback (K1), the unclassifiable class's own copy of case_cdg_deny_lf_claude
  # above: an embedded LF in a relative, no-".claude" path (K1's own example) must still print
  # exactly ONE stderr line via the DISTINCT unclassifiable message.
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' "src/a${LF}b.rs")"
  expect_cdg_deny_unclassifiable
}

# --- no opinion --------------------------------------------------------------------------------
case_cdg_noop_ordinary_abs() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/src/main.rs')"; expect_cdg_no_opinion; }
case_cdg_noop_claude_backup() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/.claude-backup/x')"; expect_cdg_no_opinion; }
case_cdg_noop_my_claude() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/my.claude/x')"; expect_cdg_no_opinion; }
case_cdg_noop_main_session_lessons() {
  # Release-blocker control: the orchestrator's own main-session lesson append (no agent_type key
  # at all — reaches only this hook's fast path, never spawns jq) must keep working.
  run_claude_guard "$(mk_cdg_main_session 'Write' '/repo/.claude/LESSONS.md')"
  expect_cdg_no_opinion
}
case_cdg_noop_unrecognised_agent() { run_claude_guard "$(mk_cdg_agent_path 'Explore' 'Edit' '/repo/.claude/x')"; expect_cdg_no_opinion; }
case_cdg_noop_empty_agent() { run_claude_guard "$(mk_cdg_agent_path '' 'Edit' '/repo/.claude/x')"; expect_cdg_no_opinion; }
case_cdg_noop_plan_mode() { run_claude_guard "$(mk_cdg_agent_path_mode 'implementer' 'Edit' '/repo/.claude/x' 'plan')"; expect_cdg_no_opinion; }
case_cdg_noop_wrong_tool() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Read' '/repo/.claude/x')"; expect_cdg_no_opinion; }
case_cdg_noop_malformed_json() {
  # Deliberately contains both literal substrings 'agent_type' and '.claude' so this exercises
  # jq's own parse failure rather than passing vacuously via the raw-stdin fast path.
  run_claude_guard 'not json at all, but mentions agent_type and .claude anyway'
  expect_cdg_no_opinion
}
case_cdg_noop_missing_file_path() { run_claude_guard "$(mk_cdg_missing_file_path 'implementer' 'Edit')"; expect_cdg_no_opinion; }
case_cdg_noop_verifier_mutation_probe() {
  # Release-blocker control: the verifier's transient mutation-probe Edit of a tracked source file
  # (agents/verifier.md's only durable-looking write, restored before the dispatch returns) must
  # keep working.
  run_claude_guard "$(mk_cdg_agent_path 'verifier' 'Edit' '/repo/bin/find-planning-work.sh')"
  expect_cdg_no_opinion
}

# --- never-executes / writes-nothing ----------------------------------------------------------
# Same booby-trapped-PATH idiom as the two siblings above, widened to the full trap set the #327
# plan's acceptance criteria name (git, gh, rm, dirname, tr, awk, grep, sed) — this hook's own
# header claims it uses NONE of these, so every one is a valid trap.
case_cdg_never_executes_deny() {
  local trapdir="$tmpbase/trapbin-cdg-deny" sentinel="$tmpbase/sentinel-cdg-deny"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname tr awk grep sed; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/.claude/x')" "$trapdir:$PATH"
  expect_cdg_deny_claude
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — claude-dir-guard.sh invoked something on the booby-trapped PATH\n"; }
}
case_cdg_never_executes_noop() {
  local trapdir="$tmpbase/trapbin-cdg-noop" sentinel="$tmpbase/sentinel-cdg-noop"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname tr awk grep sed; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/src/main.rs')" "$trapdir:$PATH"
  expect_cdg_no_opinion
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — claude-dir-guard.sh invoked something on the booby-trapped PATH\n"; }
}
case_cdg_writes_nothing() {
  # This hook performs NO filesystem access at all (stricter than either agent-boundary.sh or
  # push-guard.sh) — pin that a fixture tree containing .claude/LESSONS.md is byte-identical
  # before and after a deny run.
  local dir="$tmpbase/cdg-fixture-tree"
  mkdir -p "$dir/.claude"
  printf '# lessons\n' > "$dir/.claude/LESSONS.md"
  local before after
  before="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' "$dir/.claude/LESSONS.md")"
  after="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  expect_cdg_deny_claude
  [ "$before" = "$after" ] || { __ok=0; __why="${__why}fixture tree's file listing changed — claude-dir-guard.sh wrote to or altered a file it should only judge by its path string\n"; }
}

# ---------------------------------------------------------------------------------------------
# Codex payload shapes (#407): fixture builders, runners, and assertions for hooks/planner-guard.sh
# (new), claude-dir-guard.sh's new apply_patch/.codex/Bash-shim routes, every existing hook fed a
# Codex-shaped payload, and the gh --version canary. A Codex PreToolUse payload's DOCUMENTED key
# set (ADR 0002 amendment, P1/P4) is session_id, turn_id, cwd, hook_event_name, model,
# permission_mode, tool_name, tool_use_id, transcript_path, and tool_input -- plus agent_type and
# agent_id for a subagent, neither for the main session (the same M1 shape every Claude-shaped
# fixture above already exercises for its own hook).

# mk_codex_shell AGENT CMD [CWD] [TRANSCRIPT] -- a Codex Bash payload. CWD defaults to "/repo".
# AGENT "" omits agent_type/agent_id entirely (the main-session shape); non-empty adds both.
# TRANSCRIPT is the transcript_path; it defaults to a file under $tmpbase that is never created
# (since #494 push-guard reads the rollout a Codex payload names, so a fixture that wants the push
# judged against a real rollout passes one, and every other fixture gets a path that is absent).
mk_codex_shell() {
  local agent="$1" cmd="$2" cwd="${3:-/repo}" transcript="${4:-$tmpbase/codex-transcript-absent.jsonl}"
  jq -n --arg agent "$agent" --arg cmd "$cmd" --arg cwd "$cwd" --arg tp "$transcript" '
    {
      session_id: "codex-sess-1", turn_id: "codex-turn-1", cwd: $cwd,
      hook_event_name: "PreToolUse", model: "codex-x", permission_mode: "bypassPermissions",
      tool_name: "Bash", tool_use_id: "codex-tu-1", transcript_path: $tp,
      tool_input: {command: $cmd}
    } + (if $agent != "" then {agent_type: $agent, agent_id: "codex-agent-1"} else {} end)'
}
# mk_codex_patch AGENT PATCH [CWD|-none-] -- a Codex apply_patch payload (no file_path at all).
# "-none-" for CWD omits the cwd field entirely; anything else (including the default "/repo")
# sets it.
mk_codex_patch() {
  local agent="$1" patch="$2" cwd="${3:-/repo}"
  if [ "$cwd" = "-none-" ]; then
    jq -n --arg agent "$agent" --arg patch "$patch" '
      {
        session_id: "codex-sess-1", turn_id: "codex-turn-1",
        hook_event_name: "PreToolUse", model: "codex-x", permission_mode: "bypassPermissions",
        tool_name: "apply_patch", tool_use_id: "codex-tu-1", transcript_path: "/tmp/codex-transcript",
        tool_input: {command: $patch}
      } + (if $agent != "" then {agent_type: $agent, agent_id: "codex-agent-1"} else {} end)'
  else
    jq -n --arg agent "$agent" --arg patch "$patch" --arg cwd "$cwd" '
      {
        session_id: "codex-sess-1", turn_id: "codex-turn-1", cwd: $cwd,
        hook_event_name: "PreToolUse", model: "codex-x", permission_mode: "bypassPermissions",
        tool_name: "apply_patch", tool_use_id: "codex-tu-1", transcript_path: "/tmp/codex-transcript",
        tool_input: {command: $patch}
      } + (if $agent != "" then {agent_type: $agent, agent_id: "codex-agent-1"} else {} end)'
  fi
}

# run_planner_guard -- same separate stdout/stderr capture idiom as run_claude_guard/run_boundary
# above.
plg_out=""
plg_err=""
plg_rc=0
run_planner_guard() {
  local json="$1" pathval="${2:-$PATH}" errfile="$tmpbase/plg-stderr"
  plg_out="$(printf '%s' "$json" | PATH="$pathval" "$bash_bin" "$planner_guard" 2>"$errfile")"
  plg_rc=$?
  plg_err="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
}
# expect_plg_deny/expect_plg_no_opinion -- hand-typed DENY_STEM literal, same convention as
# expect_deny/expect_cdg_deny_claude above.
expect_plg_deny() {
  [ "$plg_rc" -eq 2 ] || { __ok=0; __why="${__why}rc: expected 2, got $plg_rc\n"; }
  [ -z "$plg_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$plg_out'\n"; }
  local err_lines
  err_lines="$(printf '%s\n' "$plg_err" | grep -c '[^[:space:]]')"
  [ "$err_lines" -eq 1 ] || { __ok=0; __why="${__why}expected exactly 1 non-blank stderr line, got $err_lines: '$plg_err'\n"; }
  case "$plg_err" in
    *"trail-blazer-flow planner guard:"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain the DENY_STEM literal 'trail-blazer-flow planner guard:': '$plg_err'\n" ;;
  esac
}
expect_plg_no_opinion() {
  [ "$plg_rc" -eq 0 ] || { __ok=0; __why="${__why}rc: expected 0, got $plg_rc\n"; }
  [ -z "$plg_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$plg_out'\n"; }
  [ -z "$plg_err" ] || { __ok=0; __why="${__why}expected empty stderr, got: '$plg_err'\n"; }
}
# expect_cdg_deny_codex/expect_cdg_deny_unparseable -- the same hand-typed-phrase convention as
# expect_cdg_deny_claude/expect_cdg_deny_unclassifiable above, against claude-dir-guard.sh's own
# .codex-segment and apply_patch-unparseable deny messages (#407).
expect_cdg_deny_codex() {
  [ "$cdg_rc" -eq 2 ] || { __ok=0; __why="${__why}rc: expected 2, got $cdg_rc\n"; }
  [ -z "$cdg_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$cdg_out'\n"; }
  local err_lines
  err_lines="$(printf '%s\n' "$cdg_err" | grep -c '[^[:space:]]')"
  [ "$err_lines" -eq 1 ] || { __ok=0; __why="${__why}expected exactly 1 non-blank stderr line, got $err_lines: '$cdg_err'\n"; }
  case "$cdg_err" in
    *"trail-blazer-flow claude-dir guard:"*"a path under a .codex segment"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the .codex-segment deny stem/phrase: '$cdg_err'\n" ;;
  esac
}
expect_cdg_deny_unparseable() {
  [ "$cdg_rc" -eq 2 ] || { __ok=0; __why="${__why}rc: expected 2, got $cdg_rc\n"; }
  [ -z "$cdg_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$cdg_out'\n"; }
  local err_lines
  err_lines="$(printf '%s\n' "$cdg_err" | grep -c '[^[:space:]]')"
  [ "$err_lines" -eq 1 ] || { __ok=0; __why="${__why}expected exactly 1 non-blank stderr line, got $err_lines: '$cdg_err'\n"; }
  case "$cdg_err" in
    *"trail-blazer-flow claude-dir guard:"*"could not be parsed"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the 'could not be parsed' deny stem/phrase: '$cdg_err'\n" ;;
  esac
}

# --- hooks/planner-guard.sh (#407) cases --------------------------------------------------------
# The default shape is Codex with bare "planner" (mk_codex_shell ""|"planner" ...). Deny verdicts
# split into two classes with distinct messages: an Edit/Write/apply_patch call (always deny, no
# classification needed) and a Bash call whose shell command the allowlist/lexer rejects.
#
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter "plg-"
# unless noted), re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table.
# mutant:407-plg-fastpath — widens the `*planner*` fast path 2 to an unmatchable string, so every
#   plg-deny-* fixture exits silently before jq is ever spawned.
# mutant:407-plg-edit-tools — empties PLANNER_EDIT_TOOLS, so Edit/Write/apply_patch are no longer
#   denied outright.
# mutant:407-plg-git-restore — adds "restore" to PLANNER_GIT_READONLY, so `git restore` is no
#   longer denied.
# mutant:407-plg-git-opts — drops the `--output*` arm from the git option-denial list.
# mutant:407-plg-git-grep-readded (#407 kickback finding 1) — adds "grep" back to
#   PLANNER_GIT_READONLY, so `git grep`'s own abbreviated-long-option/bundled-short-option
#   evasions of the (grep-only, in real git) `-O`/`--open-files-in-pager` option are no longer
#   denied by the plain subcommand-membership check.
# mutant:407-plg-rg-hostname-bin (#407 kickback finding 1) — drops the `--hostname-bin*` arm from
#   the rg option-denial list, so `rg --hostname-bin=<cmd> …` is no longer denied.
# mutant:407-plg-redirect — drops `>` from the lexer's reject set, so a redirect is no longer
#   rejected outright.
# mutant:407-plg-backtick — drops the backtick from the lexer's reject set.
# mutant:407-plg-dquote-dollar — drops the double-quoted `$` rejection inside the lexer's dquote
#   state.
# mutant:407-plg-multiline — widens the lexer's NR>1 rejection threshold so an embedded newline no
#   longer trips it (the command still ends up denied via the allowlist itself, since the two
#   lines concatenate into one unallowlisted token — the fixture pins the SPECIFIC lexer-rejection
#   wording, not just any deny).
# mutant:407-plg-lone-amp — treats a lone `&` as a segment separator instead of rejecting it.
# mutant:407-plg-sed-shape — replaces the whole `sed)` validation arm with a no-op, so neither the
#   `-n` gate nor the range-address shape is checked at all.
# mutant:407-plg-rg-pre — renames the `--pre*` arm so it can never match.
# mutant:407-plg-empty-command — changes the empty-command deny to `exit 0`.
# mutant:407-plg-plan-skip — inserts a sibling-style `permission_mode == "plan"` skip after role
#   resolution, which this hook deliberately does not have.
# mutant:407-canary-plg-gh (filter "canary-") — adds "gh" to PLANNER_READONLY_COMMANDS, so the
#   `gh --version` canary is no longer denied for the planner role.

case_plg_deny_edit_ns()   { run_planner_guard "$(mk_cdg_agent_path 'trail-blazer-flow:planner' 'Edit' '/repo/x')"; expect_plg_deny; }
case_plg_deny_write_bare() { run_planner_guard "$(mk_cdg_agent_path 'planner' 'Write' '/repo/x')"; expect_plg_deny; }
case_plg_deny_apply_patch() {
  run_planner_guard "$(mk_codex_patch 'planner' '*** Begin Patch
*** Add File: allowed.txt
+hello
*** End Patch')"
  expect_plg_deny
}
case_plg_deny_touch()            { run_planner_guard "$(mk_codex_shell 'planner' 'touch ro_test.txt && echo touched')"; expect_plg_deny; }
case_plg_deny_gh()                { run_planner_guard "$(mk_codex_shell 'planner' 'gh issue list')"; expect_plg_deny; }
case_plg_deny_git_commit()        { run_planner_guard "$(mk_codex_shell 'planner' 'git commit -am x')"; expect_plg_deny; }
case_plg_deny_git_restore()       { run_planner_guard "$(mk_codex_shell 'planner' 'git restore x')"; expect_plg_deny; }
case_plg_deny_git_global_opt()    { run_planner_guard "$(mk_codex_shell 'planner' 'git -c core.pager=sh log')"; expect_plg_deny; }
case_plg_deny_git_diff_output()   { run_planner_guard "$(mk_codex_shell 'planner' 'git diff --output=/tmp/x')"; expect_plg_deny; }
case_plg_deny_git_ext_diff()      { run_planner_guard "$(mk_codex_shell 'planner' 'git diff --ext-diff')"; expect_plg_deny; }
# #407 kickback finding 1: real git accepts abbreviated long options and bundled short options, so
# "git grep" could be steered into -O/--open-files-in-pager (an arbitrary-pager-program option) in
# a shape the old per-token check never caught. "grep" is no longer a PLANNER_GIT_READONLY member
# at all, so both deny via the plain subcommand-membership check now.
case_plg_deny_git_grep()          { run_planner_guard "$(mk_codex_shell 'planner' 'git grep -lOrm .')"; expect_plg_deny; }
case_plg_deny_git_grep_abbrev()   { run_planner_guard "$(mk_codex_shell 'planner' 'git grep --open=rm -l .')"; expect_plg_deny; }
case_plg_deny_rg_hostname_bin()   { run_planner_guard "$(mk_codex_shell 'planner' 'rg --hostname-bin=x foo')"; expect_plg_deny; }
case_plg_deny_redirect()          { run_planner_guard "$(mk_codex_shell 'planner' 'cat a > b')"; expect_plg_deny; }
case_plg_deny_stderr_devnull()    { run_planner_guard "$(mk_codex_shell 'planner' 'ls 2>/dev/null')"; expect_plg_deny; }
case_plg_deny_dollar_paren()      { run_planner_guard "$(mk_codex_shell 'planner' 'cat $(ls)')"; expect_plg_deny; }
case_plg_deny_backtick()          { run_planner_guard "$(mk_codex_shell 'planner' 'cat `ls`')"; expect_plg_deny; }
case_plg_deny_dquote_subst()      { run_planner_guard "$(mk_codex_shell 'planner' 'rg "$(id)" .')"; expect_plg_deny; }
case_plg_deny_process_subst()     { run_planner_guard "$(mk_codex_shell 'planner' 'diff <(ls) b')"; expect_plg_deny; }
case_plg_deny_subshell()          { run_planner_guard "$(mk_codex_shell 'planner' '(ls)')"; expect_plg_deny; }
case_plg_deny_background()        { run_planner_guard "$(mk_codex_shell 'planner' 'ls &')"; expect_plg_deny; }
case_plg_deny_chain_rm()          { run_planner_guard "$(mk_codex_shell 'planner' 'ls && rm -rf x')"; expect_plg_deny; }
case_plg_deny_pipe_tee()          { run_planner_guard "$(mk_codex_shell 'planner' 'cat a | tee b')"; expect_plg_deny; }
case_plg_deny_assignment()        { run_planner_guard "$(mk_codex_shell 'planner' 'PAGER=sh git log')"; expect_plg_deny; }
case_plg_deny_abs_path()          { run_planner_guard "$(mk_codex_shell 'planner' '/bin/cat x')"; expect_plg_deny; }
case_plg_deny_bash_c()            { run_planner_guard "$(mk_codex_shell 'planner' 'bash -c ls')"; expect_plg_deny; }
case_plg_deny_multiline() {
  run_planner_guard "$(mk_codex_shell 'planner' "ls${LF}rm x")"
  expect_plg_deny
  # mutant:407-plg-multiline — without this phrase check, disabling the lexer's NR>1 rejection
  # still denies (the two lines concatenate into one unallowlisted token, "lsrm", via the
  # allowlist's OWN deny_policy() path), so a bare rc==2 check alone would not notice; this pins
  # the SPECIFIC lexer-rejection wording, not just "some deny happened".
  case "$plg_err" in
    *"could not be classified as read-only"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the lexer-rejection phrase 'could not be classified as read-only': '$plg_err'\n" ;;
  esac
}
case_plg_deny_unterminated()      { run_planner_guard "$(mk_codex_shell 'planner' "rg 'foo")"; expect_plg_deny; }
# #407 kickback finding 6: three more lexer-rejection shapes.
case_plg_deny_backslash()         { run_planner_guard "$(mk_codex_shell 'planner' "cat \\'; rm -rf x; \\'")"; expect_plg_deny; }
case_plg_deny_brace() {
  run_planner_guard "$(mk_codex_shell 'planner' '{ ls; }')"
  expect_plg_deny
  # A bare rc==2 check alone does not pin the LEXER's own rejection of "{"/"}": with those two
  # characters dropped from the reject set, "{"/"}" become ordinary tokens, and "{"/"}" as t0 is
  # STILL denied by the allowlist-membership check below -- a different, redundant layer. Pin the
  # specific lexer-rejection phrase so this fixture proves what its own description claims.
  case "$plg_err" in
    *"could not be classified as read-only"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the lexer-rejection phrase 'could not be classified as read-only': '$plg_err'\n" ;;
  esac
}
case_plg_deny_bang() {
  run_planner_guard "$(mk_codex_shell 'planner' '! ls')"
  expect_plg_deny
  # Same reasoning as case_plg_deny_brace above: "!" as t0 is also denied by the allowlist
  # check alone, redundantly with the lexer.
  case "$plg_err" in
    *"could not be classified as read-only"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the lexer-rejection phrase 'could not be classified as read-only': '$plg_err'\n" ;;
  esac
}
case_plg_deny_sed_inplace()       { run_planner_guard "$(mk_codex_shell 'planner' 'sed -i.bak s/a/b/ f')"; expect_plg_deny; }
case_plg_deny_sed_w()              { run_planner_guard "$(mk_codex_shell 'planner' "sed -n 'w /tmp/x' f")"; expect_plg_deny; }
# #407 kickback finding 5: two more sed shapes that must stay denied.
case_plg_deny_sed_trailing_opt()   { run_planner_guard "$(mk_codex_shell 'planner' 'sed -n 1p f -i')"; expect_plg_deny; }
case_plg_deny_sed_range_suffix()   { run_planner_guard "$(mk_codex_shell 'planner' "sed -n '1p;w /tmp/x' f")"; expect_plg_deny; }
case_plg_deny_rg_pre()             { run_planner_guard "$(mk_codex_shell 'planner' 'rg --pre=sh foo')"; expect_plg_deny; }
case_plg_deny_find()               { run_planner_guard "$(mk_codex_shell 'planner' 'find . -delete')"; expect_plg_deny; }
case_plg_deny_empty_command()     { run_planner_guard "$(jq -n --arg a "planner" '{tool_name:"Bash", agent_type:$a, tool_input:{}}')"; expect_plg_deny; }
case_plg_deny_plan_mode() {
  run_planner_guard "$(jq -n '{tool_name:"Bash", agent_type:"planner", permission_mode:"plan", tool_input:{command:"touch x"}}')"
  expect_plg_deny
}
case_plg_deny_apply_patch_heredoc() {
  # #407 amendment A3: a planner shell apply_patch heredoc is denied by planner-guard (multi-line
  # -> NR>1 in the lexer), even though claude-dir-guard.sh's own matcher covers Bash too now --
  # this is the planner's OWN allowlist doing the denying, not claude-dir-guard.sh.
  run_planner_guard "$(mk_codex_shell 'planner' "apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Add File: .claude/x${LF}*** End Patch${LF}EOF")"
  expect_plg_deny
}

case_plg_noop_rg()          { run_planner_guard "$(mk_codex_shell 'planner' 'rg -n "foo" src')"; expect_plg_no_opinion; }
case_plg_noop_sed_print()   { run_planner_guard "$(mk_codex_shell 'planner' "sed -n '1,120p' README.md")"; expect_plg_no_opinion; }
case_plg_noop_pipe()        { run_planner_guard "$(mk_codex_shell 'planner' 'git log --oneline -5 | head -3')"; expect_plg_no_opinion; }
case_plg_noop_chain()       { run_planner_guard "$(mk_codex_shell 'planner' 'ls docs && cat README.md; wc -l CLAUDE.md')"; expect_plg_no_opinion; }
case_plg_noop_git_show_ns() { run_planner_guard "$(mk_agent_cmd 'trail-blazer-flow:planner' 'git show HEAD')"; expect_plg_no_opinion; }
case_plg_noop_quoted_meta() { run_planner_guard "$(mk_codex_shell 'planner' "rg 'a|b>c\$(x)' docs")"; expect_plg_no_opinion; }
case_plg_noop_glob()        { run_planner_guard "$(mk_codex_shell 'planner' 'ls docs/*.md')"; expect_plg_no_opinion; }
case_plg_noop_main_session() { run_planner_guard "$(mk_codex_shell '' 'touch x')"; expect_plg_no_opinion; }
case_plg_noop_implementer() { run_planner_guard "$(mk_codex_shell 'implementer' 'touch x')"; expect_plg_no_opinion; }
case_plg_noop_explore_edit() { run_planner_guard "$(mk_cdg_agent_path 'Explore' 'Edit' '/repo/x')"; expect_plg_no_opinion; }
case_plg_noop_read_tool()   { run_planner_guard "$(mk_cdg_agent_path 'planner' 'Read' '/repo/x')"; expect_plg_no_opinion; }
case_plg_noop_malformed_json() {
  run_planner_guard 'not json at all, but mentions agent_type and planner anyway'
  expect_plg_no_opinion
}

case_plg_never_executes_deny() {
  local trapdir="$tmpbase/trapbin-plg-deny" sentinel="$tmpbase/sentinel-plg-deny"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm touch; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_planner_guard "$(mk_codex_shell 'planner' 'touch ro_test.txt')" "$trapdir:$PATH"
  expect_plg_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — planner-guard.sh invoked something on the booby-trapped PATH\n"; }
}
case_plg_never_executes_noop() {
  local trapdir="$tmpbase/trapbin-plg-noop" sentinel="$tmpbase/sentinel-plg-noop"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm touch; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_planner_guard "$(mk_codex_shell 'planner' 'ls -la')" "$trapdir:$PATH"
  expect_plg_no_opinion
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — planner-guard.sh invoked something on the booby-trapped PATH\n"; }
}

# --- hooks/claude-dir-guard.sh apply_patch route (#407) cases -----------------------------------
# Default cwd is "/repo" (mk_codex_patch's own default). Every header in a patch is checked, not
# only the first (cdg-patch-deny-second-file/-move-to below).
#
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter
# "cdg-patch-" unless noted), re-run by dev/mutant-driver.sh — the #359 registry idiom, not a
# prose table.
# mutant:407-cdg-patch-tools — empties PATCH_TOOLS, so no apply_patch call reaches the tool gate
#   at all.
# mutant:407-cdg-codex-arm (filter "cdg-") — makes the `.codex` segment pattern unmatchable, so
#   neither the apply_patch route nor the file_path route (cdg-codexseg-* below) recognises it.
# mutant:407-cdg-codex-exact (filter "cdg-") — widens the same pattern to a bare substring match,
#   so a near-miss spelling like `.codex-backup` also denies.
# mutant:407-cdg-cwd-join — drops the `$pcwd/` prefix when resolving a relative header path, so
#   every relative path becomes unclassifiable (denied fail-closed) instead of resolving against
#   cwd.
# mutant:407-cdg-all-headers — `break`s the line loop right after the first header, so a second
#   header in the same patch is never reached.
# mutant:407-cdg-unknown-marker — turns the unrecognised-marker deny into a no-op (the fixture
#   pins the SPECIFIC "unrecognised marker" reason text, not just the generic "could not be
#   parsed" phrase the "no file header" fallback shares).
# mutant:407-cdg-no-header — widens the zero-header deny's comparison so it can never trigger.
# mutant:407-cdg-trim — disables the line loop's leading-whitespace trim, so an indented header
#   line no longer matches its own marker pattern.
# mutant:407-cdg-patch-cr — disables the whole-patch CR strip, so a CRLF-terminated patch's own
#   structural markers ("*** Begin Patch\r", …) stop matching their exact-text case arms.
# mutant:407-cdg-empty-command — changes the absent-command deny to `exit 0`.

case_cdg_patch_deny_add_claude()   { run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Add File: .claude/settings.local.json
+{}
*** End Patch')"; expect_cdg_deny_claude; }
case_cdg_patch_deny_update_ns()    { run_claude_guard "$(mk_codex_patch 'trail-blazer-flow:implementer' '*** Begin Patch
*** Update File: .claude/LESSONS.md
+x
*** End Patch')"; expect_cdg_deny_claude; }
case_cdg_patch_deny_verifier()     { run_claude_guard "$(mk_codex_patch 'verifier' '*** Begin Patch
*** Add File: .claude/x
*** End Patch')"; expect_cdg_deny_claude; }
case_cdg_patch_deny_delete()       { run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Delete File: .claude/x
*** End Patch')"; expect_cdg_deny_claude; }
case_cdg_patch_deny_move_to()      { run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Update File: src/a.txt
*** Move to: .claude/a.txt
*** End Patch')"; expect_cdg_deny_claude; }
case_cdg_patch_deny_second_file()  { run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Add File: src/a.txt
+x
*** Add File: .claude/a.txt
+y
*** End Patch')"; expect_cdg_deny_claude; }
case_cdg_patch_deny_case_variant() { run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Add File: .Claude/x
*** End Patch')"; expect_cdg_deny_claude; }
case_cdg_patch_deny_abs_header()   { run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Add File: /Users/x/.claude/settings.json
*** End Patch')"; expect_cdg_deny_claude; }
case_cdg_patch_deny_indented_header() { run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
  *** Add File: .claude/x
*** End Patch')"; expect_cdg_deny_claude; }

case_cdg_patch_deny_codex()      { run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Add File: .codex/config.toml
*** End Patch')"; expect_cdg_deny_codex; }
case_cdg_patch_deny_codex_case() { run_claude_guard "$(mk_codex_patch 'verifier' '*** Begin Patch
*** Add File: .CODEX/agents/x.toml
*** End Patch')"; expect_cdg_deny_codex; }

case_cdg_patch_deny_dotdot() { run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Add File: ../escape/x
*** End Patch')"; expect_cdg_deny_unclassifiable; }
case_cdg_patch_deny_no_cwd() { run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Add File: src/a.txt
*** End Patch' '-none-')"; expect_cdg_deny_unclassifiable; }

case_cdg_patch_deny_no_header()     { run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** End Patch')"; expect_cdg_deny_unparseable; }
case_cdg_patch_deny_unknown_header() {
  run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Copy File: .claude/x
*** End Patch')"
  expect_cdg_deny_unparseable
  # mutant:407-cdg-unknown-marker — the generic "could not be parsed" phrase alone does not
  # distinguish this deny from the "no file header" fallback that fires when the unknown marker
  # is silently ignored (headers stays 0); pin the SPECIFIC reason text too.
  case "$cdg_err" in
    *"unrecognised marker"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the specific 'unrecognised marker' reason: '$cdg_err'\n" ;;
  esac
}
case_cdg_patch_deny_empty_path()    { run_claude_guard "$(mk_codex_patch 'implementer' "$(printf '*** Begin Patch\n*** Add File: \n*** End Patch')")"; expect_cdg_deny_unparseable; }
case_cdg_patch_deny_empty_command() { run_claude_guard "$(jq -n --arg a 'implementer' '{tool_name:"apply_patch", agent_type:$a, cwd:"/repo", tool_input:{}}')"; expect_cdg_deny_unparseable; }

case_cdg_patch_noop_add_src()      { run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Add File: src/new.rs
+fn main() {}
*** End Patch')"; expect_cdg_no_opinion; }
case_cdg_patch_noop_update_readme() { run_claude_guard "$(mk_codex_patch 'verifier' '*** Begin Patch
*** Update File: README.md
@@
-old
+new
*** End Patch')"; expect_cdg_no_opinion; }
case_cdg_patch_noop_content_mentions() {
  run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Update File: README.md
@@
+see .claude/LESSONS.md
+*** Add File: .claude/x
*** End Patch')"
  expect_cdg_no_opinion
}
case_cdg_patch_noop_crlf() {
  local patch
  patch="$(printf '*** Begin Patch\r\n*** Update File: README.md\r\n@@\r\n-old\r\n+new\r\n*** End Patch\r\n')"
  run_claude_guard "$(mk_codex_patch 'verifier' "$patch")"
  expect_cdg_no_opinion
}
case_cdg_patch_noop_main_session() { run_claude_guard "$(mk_codex_patch '' '*** Begin Patch
*** Add File: .claude/LESSONS.md
+x
*** End Patch')"; expect_cdg_no_opinion; }
case_cdg_patch_noop_planner() { run_claude_guard "$(mk_codex_patch 'planner' '*** Begin Patch
*** Add File: .claude/x
*** End Patch')"; expect_cdg_no_opinion; }
case_cdg_patch_noop_near_miss() { run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Add File: .codex-backup/x
*** End Patch')"; expect_cdg_no_opinion; }

case_cdg_patch_never_executes() {
  local trapdir="$tmpbase/trapbin-cdg-patch" sentinel="$tmpbase/sentinel-cdg-patch"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname tr awk grep sed; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_claude_guard "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Add File: .claude/x
*** End Patch')" "$trapdir:$PATH"
  expect_cdg_deny_claude
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — claude-dir-guard.sh invoked something on the booby-trapped PATH\n"; }
}

# --- hooks/claude-dir-guard.sh file_path route, .codex segment (#407) cases ---------------------
case_cdg_codexseg_deny_write()        { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Write' '/repo/.codex/config.toml')"; expect_cdg_deny_codex; }
case_cdg_codexseg_deny_verifier_edit_ns() { run_claude_guard "$(mk_cdg_agent_path 'trail-blazer-flow:verifier' 'Edit' '/repo/.codex/x')"; expect_cdg_deny_codex; }
case_cdg_codexseg_noop_backup()       { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/.codex-backup/x')"; expect_cdg_no_opinion; }
case_cdg_codexseg_noop_my_codex()     { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/my.codex/x')"; expect_cdg_no_opinion; }

# --- hooks/claude-dir-guard.sh Bash apply_patch-shim route (#407 amendment A1/A3) cases ----------
# The S0 spike (#412, Q7) payload: a shell-issued apply_patch heredoc reaches this hook as an
# ordinary Bash call.
#
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter
# "cdg-bash-"), re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table.
# mutant:407-cdg-bash-trigger — makes the `*** Begin Patch` case-selector pattern unmatchable, so
#   every heredoc payload (including the benign src-only one) falls into the "no inline patch"
#   arm instead, which denies unconditionally once the command word is `apply_patch`.
# mutant:407-cdg-bash-no-inline-patch — short-circuits the `is_apply_patch_word` check with
#   `false &&`, so `apply_patch < x.patch` is no longer denied.
# mutant:407-cdg-bash-decoy-claude-mention — widens the belt-and-braces `.claude`/`.codex`
#   case arm's own bracket classes so they can never match, isolating the ANSI-C-quoted decoy
#   fixture's own dependency on that specific check from the generic "no inline patch" fallback.
# mutant:407-cdg-bash-belt-braces-order (#407 kickback round 2, finding A) — disables the
#   belt-and-braces check's own guard with `false &&`, so it can never run at all, isolating every
#   fixture whose deny depends on it running UNCONDITIONALLY/FIRST (both decoys, plus the two
#   genuine-structure fixtures whose message text names the belt-and-braces reason specifically).
# mutant:407-cdg-bash-parens (#407 kickback round 2, finding B) — drops `(`/`)` from the segment-
#   break bracket expression, so a subshell or command substitution hides the command word.
# mutant:407-cdg-bash-gt-break (#407 kickback round 2, finding C) — disables the `>` word-break
#   substitution entirely, so a glued `>` redirect hides the command word.
# mutant:407-cdg-bash-indented-trigger-trim (#407 kickback round 2, finding C) — replaces
#   has_exact_begin_patch_line's own full trim with a no-op, so an INDENTED "*** Begin Patch" line
#   no longer matches the exact-line trigger.
case_cdg_bash_deny_heredoc_claude() {
  # #407 kickback round 2, finding A: the belt-and-braces raw-text check now runs FIRST and
  # unconditionally, before the structured parse gets a chance to emit the more specific
  # classify_path message -- this payload denies via the belt-and-braces reason now, not via
  # expect_cdg_deny_claude's own phrase.
  run_claude_guard "$(mk_codex_shell 'implementer' "apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Add File: .claude/settings.local.json${LF}+{}${LF}*** End Patch${LF}EOF")"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"mentioning a .claude/.codex path"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the specific belt-and-braces reason: '$cdg_err'\n" ;;
  esac
}
case_cdg_bash_deny_heredoc_codex() {
  run_claude_guard "$(mk_codex_shell 'verifier' "apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Add File: .codex/x${LF}*** End Patch${LF}EOF")"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"mentioning a .claude/.codex path"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the specific belt-and-braces reason: '$cdg_err'\n" ;;
  esac
}
case_cdg_bash_noop_heredoc_src() {
  run_claude_guard "$(mk_codex_shell 'implementer' "apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Add File: src/a.txt${LF}*** End Patch${LF}EOF")"
  expect_cdg_no_opinion
}
# #407 kickback round 3: the belt-and-braces check matches a `.claude`/`.codex` SEGMENT (leading
# dot), not the bare word -- a benign patch to CLAUDE.md, a body mentioning Claude Code, or a path
# containing "codex" gets no opinion.
# mutant:407-cdg-bash-segment-dot — dropping the leading dot from the belt-and-braces pattern makes
#   a bare "claude"/"codex" substring deny.
case_cdg_bash_noop_heredoc_claude_md() {
  run_claude_guard "$(mk_codex_shell 'implementer' "apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Update File: CLAUDE.md${LF}@@${LF}-Claude Code${LF}+Claude Code 2${LF}*** End Patch${LF}EOF")"
  expect_cdg_no_opinion
}
case_cdg_bash_noop_heredoc_codex_name() {
  run_claude_guard "$(mk_codex_shell 'implementer' "apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Add File: src/codex_client.py${LF}+x${LF}*** End Patch${LF}EOF")"
  expect_cdg_no_opinion
}
case_cdg_bash_deny_no_inline_patch() {
  run_claude_guard "$(mk_codex_shell 'implementer' 'apply_patch < x.patch')"
  expect_cdg_deny_unparseable
}
# #407 kickback finding 2: the command-word detection missed common positions -- glued to a
# redirect with no space, inside a brace group, past a shell keyword, and past an assignment
# prefix. Each denies via the SAME "no inline patch" reason as case_cdg_bash_deny_no_inline_patch.
case_cdg_bash_deny_no_inline_patch_glued()     { run_claude_guard "$(mk_codex_shell 'implementer' 'apply_patch<x.patch')"; expect_cdg_deny_unparseable; }
case_cdg_bash_deny_no_inline_patch_brace()     { run_claude_guard "$(mk_codex_shell 'implementer' '{ apply_patch < x.patch; }')"; expect_cdg_deny_unparseable; }
case_cdg_bash_deny_no_inline_patch_keyword()   { run_claude_guard "$(mk_codex_shell 'implementer' 'if true; then apply_patch < x.patch; fi')"; expect_cdg_deny_unparseable; }
case_cdg_bash_deny_no_inline_patch_assignment() { run_claude_guard "$(mk_codex_shell 'implementer' 'FOO=1 apply_patch < x.patch')"; expect_cdg_deny_unparseable; }
case_cdg_bash_deny_no_inline_patch_chain()     { run_claude_guard "$(mk_codex_shell 'implementer' 'cd src && applypatch < x.patch')"; expect_cdg_deny_unparseable; }
case_cdg_bash_deny_no_inline_patch_pipe()      { run_claude_guard "$(mk_codex_shell 'implementer' 'cat x.patch | apply_patch')"; expect_cdg_deny_unparseable; }
# #407 kickback finding 2's "belt and braces": an ANSI-C-quoted ($'...') decoy whose "\n"
# sequences are literal backslash+n bytes, not real newlines, so has_exact_begin_patch_line never
# fires on it (there is no genuine line break) -- the raw-text .claude mention still denies.
case_cdg_bash_deny_decoy_dollar_quote() {
  # The decoy itself is one physical line (its "\n"s are the two literal characters
  # backslash+n, never a real line break); a genuine SECOND, real line follows with an ordinary
  # benign header, proving the deny isn't an artifact of the decoy being the only content -- the
  # command still denies via the belt-and-braces raw-text check, not the (never-triggered)
  # structured parse.
  run_claude_guard "$(mk_codex_shell 'implementer' "apply_patch \$'*** Begin Patch\\n*** Add File: .claude/x\\n+x\\n*** End Patch'${LF}*** Add File: src/ok.txt")"
  expect_cdg_deny_unparseable
  # mutant:407-cdg-bash-decoy-claude-mention — the generic "could not be parsed" phrase alone does
  # not distinguish the belt-and-braces reason from the "no inline patch text" fallback; pin the
  # SPECIFIC reason text too.
  case "$cdg_err" in
    *"mentioning a .claude/.codex path"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the specific belt-and-braces reason: '$cdg_err'\n" ;;
  esac
}
# #407 kickback round 2, finding A's second decoy: the FIRST header is preceded by U+00A0
# NO-BREAK SPACE (ltrim() strips only ASCII space/tab, never Unicode whitespace -- the header
# hides from the structured parse as an ordinary content line, per this file's own header
# residual note), sitting next to a SECOND, genuinely benign header -- if the belt-and-braces
# check were not unconditional/first, the structured parse alone would see only the benign header
# and return no opinion despite the raw text plainly mentioning ".claude".
case_cdg_bash_deny_decoy_nbsp_header() {
  local nbsp
  nbsp="$(printf '\xc2\xa0')"
  run_claude_guard "$(mk_codex_shell 'implementer' "apply_patch <<'EOF'${LF}*** Begin Patch${LF}${nbsp}*** Add File: .claude/x${LF}*** Add File: src/ok.txt${LF}*** End Patch${LF}EOF")"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"mentioning a .claude/.codex path"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the specific belt-and-braces reason: '$cdg_err'\n" ;;
  esac
}
# #407 kickback round 2, finding B: "(" and ")" were already segment breaks -- pin it.
case_cdg_bash_deny_no_inline_patch_subshell()      { run_claude_guard "$(mk_codex_shell 'implementer' '(apply_patch < x.patch)')"; expect_cdg_deny_unparseable; }
case_cdg_bash_deny_no_inline_patch_cmdsubst()      { run_claude_guard "$(mk_codex_shell 'implementer' 'echo $(apply_patch < x.patch)')"; expect_cdg_deny_unparseable; }
# #407 kickback round 2, finding C: the ">" word break, and has_exact_begin_patch_line's OWN full
# trim (not is_apply_patch_word's command-word detection -- the leading "\" defeats that, so this
# denies via the STRUCTURED parse's classify_path message instead).
case_cdg_bash_deny_no_inline_patch_gt()            { run_claude_guard "$(mk_codex_shell 'implementer' 'apply_patch>out.txt')"; expect_cdg_deny_unparseable; }
case_cdg_bash_deny_backslash_indented_begin_patch() {
  run_claude_guard "$(mk_codex_shell 'implementer' "\\apply_patch <<'EOF'${LF}  *** Begin Patch${LF}  *** Add File: .claude/x${LF}  *** End Patch${LF}EOF")"
  expect_cdg_deny_claude
}
# #407 kickback round 2, finding D: a leading redirect (with or without a bare-digits fd) must not
# hide the command word that follows it.
case_cdg_bash_deny_leading_redirect()    { run_claude_guard "$(mk_codex_shell 'implementer' '< x.patch apply_patch')"; expect_cdg_deny_unparseable; }
case_cdg_bash_deny_leading_redirect_fd() { run_claude_guard "$(mk_codex_shell 'implementer' '2>/dev/null apply_patch < x')"; expect_cdg_deny_unparseable; }
# #407 kickback round 3: a run of redirect operators (`>>`) is one redirect, and an fd duplication
# (`>&2`, `2>&1`) keeps its `&` -- neither may hide the command word.
# mutant:407-cdg-bash-redirect-run — skipping only one marker of a `>>` run makes the redirect
#   target the resolved word.
case_cdg_bash_deny_leading_redirect_append() { run_claude_guard "$(mk_codex_shell 'implementer' '>> log apply_patch < x.patch')"; expect_cdg_deny_unparseable; }
case_cdg_bash_deny_leading_redirect_fd_append() { run_claude_guard "$(mk_codex_shell 'implementer' '2>>err apply_patch < x')"; expect_cdg_deny_unparseable; }
# mutant:407-cdg-bash-fd-dup — letting `>&` split the segment leaves the fd as the resolved word.
case_cdg_bash_deny_leading_redirect_fd_dup() { run_claude_guard "$(mk_codex_shell 'implementer' '>&2 apply_patch < x.patch')"; expect_cdg_deny_unparseable; }
case_cdg_bash_deny_leading_redirect_fd_dup2() { run_claude_guard "$(mk_codex_shell 'implementer' '2>&1 apply_patch < x.patch')"; expect_cdg_deny_unparseable; }
# mutant:407-cdg-bash-clobber — letting `>|` split the segment makes the redirect target the
#   resolved word.
case_cdg_bash_deny_leading_redirect_clobber() { run_claude_guard "$(mk_codex_shell 'implementer' '>| log apply_patch < x.patch')"; expect_cdg_deny_unparseable; }
# mutant:407-cdg-bash-in-dup — letting `<&` split the segment leaves the fd as the resolved word.
case_cdg_bash_deny_leading_redirect_in_dup() { run_claude_guard "$(mk_codex_shell 'implementer' '<&0 apply_patch')"; expect_cdg_deny_unparseable; }
# A quoted mention after ordinary words is an argument: no opinion (documented over-block boundary).
case_cdg_bash_noop_quoted_mention() { run_claude_guard "$(mk_codex_shell 'implementer' 'git commit -m "the apply_patch shim"')"; expect_cdg_no_opinion; }
# #407 kickback round 2, finding E: a path-qualified spelling still counts, matched by basename.
case_cdg_bash_deny_path_qualified() { run_claude_guard "$(mk_codex_shell 'implementer' './apply_patch < x')"; expect_cdg_deny_unparseable; }
# #407 kickback finding 3: the "*** Begin Patch" trigger was a raw substring match, so a benign
# command that merely MENTIONS the marker denied too. Requiring an exact, fully-trimmed line
# closes it -- neither of these carries a genuine patch-grammar line break.
case_cdg_bash_noop_begin_patch_mention_grep()   { run_claude_guard "$(mk_codex_shell 'implementer' "grep -rn '*** Begin Patch' hooks/")"; expect_cdg_no_opinion; }
case_cdg_bash_noop_begin_patch_mention_commit() { run_claude_guard "$(mk_codex_shell 'implementer' 'git commit -m "docs: mention *** Begin Patch marker"')"; expect_cdg_no_opinion; }
case_cdg_bash_noop_arg_only() { run_claude_guard "$(mk_codex_shell 'implementer' 'rg apply_patch hooks/')"; expect_cdg_no_opinion; }
case_cdg_bash_noop_quoted()   { run_claude_guard "$(mk_codex_shell 'implementer' 'grep -n "apply_patch" x')"; expect_cdg_no_opinion; }
case_cdg_bash_noop_main_session() {
  run_claude_guard "$(mk_codex_shell '' "apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Add File: .claude/x${LF}*** End Patch${LF}EOF")"
  expect_cdg_no_opinion
}
case_cdg_bash_noop_ab_fixture_reuse() {
  # #407 amendment reviewer emphasis: the new Bash route must not deny an existing ab-*/pg-*
  # fixture's own command for these roles unless it carries a patch -- reuse an actual
  # agent-boundary.sh deny fixture's command text (git push) against THIS hook and expect no
  # opinion (it carries no apply_patch-shaped patch at all).
  run_claude_guard "$(mk_agent_cmd 'implementer' 'git push origin main')"
  expect_cdg_no_opinion
}
case_cdg_bash_never_executes() {
  local trapdir="$tmpbase/trapbin-cdg-bash" sentinel="$tmpbase/sentinel-cdg-bash"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname tr awk grep sed; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_claude_guard "$(mk_codex_shell 'implementer' "apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Add File: .claude/x${LF}*** End Patch${LF}EOF")" "$trapdir:$PATH"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"mentioning a .claude/.codex path"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the specific belt-and-braces reason: '$cdg_err'\n" ;;
  esac
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — claude-dir-guard.sh invoked something on the booby-trapped PATH\n"; }
}
# #407 kickback round 2, finding H: a SECOND never-executes fixture specifically for the
# is_apply_patch_word "no inline patch" route (the belt-and-braces check above mentions no
# .claude/.codex, so THIS is the route that actually denies here), proving that route also never
# executes anything on the booby-trapped PATH.
case_cdg_bash_never_executes_no_inline_patch() {
  local trapdir="$tmpbase/trapbin-cdg-bash-nip" sentinel="$tmpbase/sentinel-cdg-bash-nip"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname tr awk grep sed; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_claude_guard "$(mk_codex_shell 'implementer' 'apply_patch < x.patch')" "$trapdir:$PATH"
  expect_cdg_deny_unparseable
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — claude-dir-guard.sh invoked something on the booby-trapped PATH\n"; }
}

# --- hooks/claude-dir-guard.sh: the #403 eval/noglob/dash/repeat prefix-word class ---------------
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter "cdg-pc-"),
# re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table. This hook's own
# PREFIX_WORDS copy gains the same eval/trap/noglob/nocorrect/-/repeat vocabulary and the `repeat`
# count skip; the `]]` segment break and quote stripping #437 added are exercised separately by the
# `cdg-dbq-*` fixtures right below — so only the unquoted, no-`]]` forms are exercised here.
# mutant:403-cdg-pc-vocab — reverts this hook's PREFIX_WORDS copy to its pre-#403 (#398) value, so
#   every fixture below no longer resolves past its own prefix word to "apply_patch".
# mutant:403-cdg-pc-repeat — removes the `repeat`-count skip from is_apply_patch_word, so a
#   `repeat N` prefix leaves the count token itself as the resolved word instead of "apply_patch".
case_cdg_pc_deny_eval_shim() {
  run_claude_guard "$(mk_codex_shell 'implementer' 'eval apply_patch < x.patch')"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}
case_cdg_pc_deny_noglob_shim() {
  run_claude_guard "$(mk_codex_shell 'implementer' 'noglob apply_patch < x.patch')"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}
case_cdg_pc_deny_dash_shim() {
  run_claude_guard "$(mk_codex_shell 'implementer' '- apply_patch < x.patch')"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}
case_cdg_pc_deny_repeat_shim() {
  run_claude_guard "$(mk_codex_shell 'implementer' 'repeat 2 apply_patch < x.patch')"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}

# --- hooks/claude-dir-guard.sh: the #437 ]]-cut / quote-stripping class -------------------------
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter "cdg-dbq-"),
# re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table. Ports #403's
# agent-boundary.sh/push-guard.sh disjoint-`]]`-tail and quote-stripping techniques into this
# hook's own pure-bash walk_window()/is_apply_patch_word() (no awk — this hook's own booby-trap
# fixtures trap it).
# mutant:437-cdg-dbq-tails — breaks the `]]`-token equality test, so no standalone `]]` is ever
#   recognised and the whole additive pass never runs for any segment.
# mutant:437-cdg-dbq-last-tail — deletes the post-loop walk of the LAST (uncut) tail, so a `]]`
#   with nothing after it in the loop never resolves the command word that follows the final `]]`.
# mutant:437-cdg-dbq-cut-shim — deletes the in-loop basename check for a CUT tail, so a cut tail
#   that DOES resolve to the shim is never marked found.
# mutant:437-cdg-dbq-cut — deletes the cut-tail fail-closed deny, so a cut tail that consumes a
#   skip token without ever resolving a word is silently treated as no opinion instead.
# mutant:437-cdg-dbq-cut-resolved — drops the cut deny's own "no word resolved" condition, so a cut
#   tail that consumed a skip token but DID resolve a word (`env echo … ]]`) wrongly denies too.
# mutant:437-cdg-dbq-overlap — widens the in-loop tail's own stop bound from the next `]]` to the
#   segment's end, so tails overlap instead of staying disjoint, hiding the cut-tail deny behind an
#   ordinary resolve on the far side of the next `]]`.
# mutant:437-cdg-dbq-cap — disables the DBRACKET_MAX comparison outright, so a flood of standalone
#   `]]` is analysed in full instead of failing closed.
# mutant:437-cdg-dbq-cap-exact — loosens the cap comparison by one (`-gt` to `-ge`), so exactly
#   DBRACKET_MAX standalone `]]` already denies instead of getting no opinion.
# mutant:437-cdg-dbq-cap-per-segment — removes the per-segment db_n reset, so the count accumulates
#   across every segment of one call instead of resetting per segment.
# mutant:437-cdg-dbq-quote-sq — deletes the single-quote strip, so a single-quoted spelling of the
#   shim's own name (or a single-quoted PREFIX_WORDS member) no longer resolves.
# mutant:437-cdg-dbq-quote-dq — deletes the double-quote strip, so a double-quoted spelling no
#   longer resolves.
# mutant:437-cdg-dbq-empty-tok — deletes the empty-token-after-strip skip, so a lone quote
#   character glued to nothing becomes the walk's own "resolved" word, hiding the real word right
#   after it.
case_cdg_dbq_deny_short_if() {
  run_claude_guard "$(mk_codex_shell 'implementer' 'if [[ -n x ]] apply_patch < x.patch')"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}
case_cdg_dbq_deny_short_if_multiline() {
  # The "]]" that closes the `[[ ... ` test opens the SECOND physical line — this walk treats each
  # real newline as its own segment boundary already, so the "]]" sits in a DIFFERENT segment from
  # its own "[[", proving the additive pass does not depend on both ends sharing one segment.
  run_claude_guard "$(mk_codex_shell 'implementer' "if [[ -n x${LF}]] apply_patch < x.patch")"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}
case_cdg_dbq_deny_cut_shim() {
  # The deciding tail is CUT by a later "]]" (not the last one) — proves the in-loop cut-tail
  # basename check, not only the post-loop last-tail one, finds the shim.
  run_claude_guard "$(mk_codex_shell 'implementer' 'if [[ -n x ]] apply_patch < x.patch ]] y')"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}
case_cdg_dbq_deny_cut_unresolved() {
  # The tail between the two "]]" ("env -u") consumes a PREFIX_WORDS token and a dash-option
  # without ever resolving a word — fails closed on the CUT itself, distinct from the ordinary
  # "no inline patch text" reason.
  run_claude_guard "$(mk_codex_shell 'implementer' 'if [[ -n x ]] env -u ]] -i apply_patch < x.patch')"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"split by ]]"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'split by ]]': '$cdg_err'\n" ;;
  esac
}
case_cdg_dbq_deny_flood_cap() {
  # More than DBRACKET_MAX (64) standalone "]]" in one segment denies unconditionally, before any
  # tail is ever walked.
  local flood="" i
  for i in $(seq 1 65); do flood="${flood} ]]"; done
  run_claude_guard "$(mk_codex_shell 'implementer' "echo apply_patch${flood}")"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"too many standalone ]] tokens"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'too many standalone ]] tokens': '$cdg_err'\n" ;;
  esac
}
case_cdg_dbq_deny_eval_sq() {
  run_claude_guard "$(mk_codex_shell 'implementer' "eval 'apply_patch < x.patch'")"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}
case_cdg_dbq_deny_eval_dq() {
  run_claude_guard "$(mk_codex_shell 'implementer' 'eval "apply_patch < x.patch"')"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}
case_cdg_dbq_deny_eval_lead_space() {
  # A real space right after the opening double quote splits into its own lone-quote token — proves
  # the empty-token-after-strip skip, not just the strip itself, is needed to reach "apply_patch".
  run_claude_guard "$(mk_codex_shell 'implementer' 'eval " apply_patch < x.patch"')"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}
case_cdg_dbq_deny_trap_sq() {
  run_claude_guard "$(mk_codex_shell 'verifier' "trap 'apply_patch < x.patch' EXIT")"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}
case_cdg_dbq_deny_bash_c_dq() {
  run_claude_guard "$(mk_codex_shell 'implementer' 'bash -c "apply_patch < x.patch"')"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}
case_cdg_dbq_deny_quoted_name() {
  run_claude_guard "$(mk_codex_shell 'implementer' '"apply_patch" < x.patch')"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}
case_cdg_dbq_deny_quoted_prefix() {
  # The PREFIX_WORDS match itself uses the STRIPPED token: "'noglob" strips to "noglob", a genuine
  # member, so the walk keeps going past it to "apply_patch".
  run_claude_guard "$(mk_codex_shell 'implementer' "bash -c 'noglob apply_patch < x.patch'")"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}
case_cdg_dbq_deny_timing() {
  # Flood shape: the filler goes BEFORE the 64 standalone "]]" so their own tail windows start at
  # higher indices than the base walk's. Runs under a 15s active deadline (#463 --
  # cdg_deadline_override, not a passive post-hoc SECONDS comparison). Since #457 the hook denies a
  # Bash command with a physical line longer than CDG_LINE_MAX_BYTES as "too large to analyse"
  # before any walk, so the flood line (filler included) is sized to stay under that cap and reach
  # the "no inline patch" reason this case expects; the cdg-dl-* cases pin the over-cap and
  # deadline denies themselves. The command reaches jq on stdin (printf is a builtin), never as a
  # --arg.
  local filler
  filler="$(printf ' a%.0s' $(seq 1 700))"
  local flood="x${filler}" i
  for i in $(seq 1 64); do flood="${flood} ]] true"; done
  local payload
  payload="$(printf '%s\napply_patch < x.patch' "$flood" \
    | jq -Rs '{tool_name: "Bash", agent_type: "implementer", cwd: "/repo", tool_input: {command: .}}')"
  cdg_deadline_override=15
  run_claude_guard "$payload"
  # mutant:463-hook-cdg-override-leaks — run_claude_guard's own trailing
  #   `cdg_deadline_override=""` reset deleted: this assertion is the only thing that would catch
  #   the override surviving into the NEXT case, since a leaked value here still happens to equal
  #   what this case itself just set.
  [ -z "$cdg_deadline_override" ] || { __ok=0; __why="${__why}cdg_deadline_override not cleared after run_claude_guard: '$cdg_deadline_override'\n"; }
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
}
case_cdg_dbq_noop_flood_at_cap() {
  # Exactly DBRACKET_MAX (64) standalone "]]": the cap never trips, and "apply_patch" is never
  # reached by any window (it sits as an ARGUMENT to "echo", the base walk's own resolved word,
  # before the first "]]" even starts) — no opinion either way.
  local flood="" i
  for i in $(seq 1 64); do flood="${flood} ]]"; done
  run_claude_guard "$(mk_codex_shell 'implementer' "echo apply_patch${flood}")"
  expect_cdg_no_opinion
}
case_cdg_dbq_noop_cap_per_segment() {
  # 65 lines, each carrying exactly ONE standalone "]]" ("&&" is itself a segment break, so each
  # line becomes two segments) — proves DBRACKET_MAX is counted PER SEGMENT: 65 well-under-cap
  # segments must not accumulate into a false cap deny.
  local body="cat <<'EOF' > t.sh" i
  for i in $(seq 1 65); do body="${body}${LF}[[ -n x ]] && echo apply_patch"; done
  body="${body}${LF}EOF"
  run_claude_guard "$(mk_codex_shell 'implementer' "$body")"
  expect_cdg_no_opinion
}
case_cdg_dbq_noop_bash_dbracket() {
  run_claude_guard "$(mk_codex_shell 'implementer' '[[ -n x ]] && echo apply_patch')"
  expect_cdg_no_opinion
}
case_cdg_dbq_noop_cut_resolved() {
  # A cut tail that consumes a skip word ("env") and then resolves ("echo") is not the cut-deny
  # shape: only a cut tail that never resolves a word denies.
  run_claude_guard "$(mk_codex_shell 'implementer' 'if [[ -n x ]] env echo apply_patch ]] y')"
  expect_cdg_no_opinion
}
case_cdg_dbq_noop_short_if_other() {
  # The tail after "]]" resolves to "echo", not "apply_patch" — "apply_patch" is merely echo's own
  # argument, the same "resolved word stops the walk" rule the base walk already follows.
  run_claude_guard "$(mk_codex_shell 'implementer' 'if [[ -n x ]] echo apply_patch')"
  expect_cdg_no_opinion
}
case_cdg_dbq_noop_short_if_benign_heredoc() {
  # The shim IS resolved as the command word via the additive pass, but the heredoc carries a
  # genuine, benign "*** Begin Patch" block — the EXISTING structured-parse route (unchanged by
  # #437) takes over and finds nothing to deny.
  run_claude_guard "$(mk_codex_shell 'implementer' "if [[ -n x ]] apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Add File: src/a.txt${LF}+x${LF}*** End Patch${LF}EOF")"
  expect_cdg_no_opinion
}
case_cdg_dbq_never_executes() {
  local trapdir="$tmpbase/trapbin-cdg-dbq" sentinel="$tmpbase/sentinel-cdg-dbq"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname tr awk grep sed; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_claude_guard "$(mk_codex_shell 'implementer' 'if [[ -n x ]] apply_patch < x.patch')" "$trapdir:$PATH"
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"with no inline patch text"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'with no inline patch text': '$cdg_err'\n" ;;
  esac
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — claude-dir-guard.sh invoked something on the booby-trapped PATH\n"; }
}

# --- hooks/claude-dir-guard.sh: analysis deadline (#457) ---------------------------------------
# Per-site kills use the sample-count cap (cdg_cap_override), not wall time: each cap fixture floods
# exactly ONE sample site with about 100 iterations under cap 50, while every other source
# contributes only a handful of samples, so the verdict never depends on host speed. Time-path kills
# use budget 0, where the very first sample denies. Fixture tails are `echo apply_patch`, never the
# shim itself. Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh).
# mutant:457-cdg-dl-check-off — check_deadline's `$SECONDS` comparison becomes a no-op, so a zero
#   budget and the production-size flood no longer deny.
# mutant:457-cdg-dl-knob-raise — the budget knob's `strictly less than` guard dropped, so a
#   two-digit knob raises the budget instead of being ignored.
# mutant:457-cdg-dl-before-role — a sample before the role exit, so a non-role call denies.
# mutant:457-cdg-dl-before-plan — a sample before the plan-mode exit, so a plan-mode call denies.
# mutant:457-cdg-dl-seg-site — is_apply_patch_word's segment loop loses its sample.
# mutant:457-cdg-dl-ww-site — walk_window's outer loop loses its sample.
# mutant:457-cdg-dl-redir-site — walk_window's redirect-run loop loses its sample.
# mutant:457-cdg-dl-db-site — the `]]` pass loses its sample.
# mutant:457-cdg-dl-bpl-site — has_exact_begin_patch_line's line loop loses its sample.
# mutant:457-cdg-dl-ph-site — parse_patch_headers' line loop loses its sample.
# mutant:457-cdg-dl-ltrim-site — ltrim's strip loop loses its sample.
# mutant:457-cdg-dl-trim-site — trim's trailing strip loop loses its sample.
# mutant:457-cdg-dl-ph-ltrim-propagate — parse_patch_headers stops propagating a deny out of its
#   ltrim command substitution.
# mutant:457-cdg-dl-ph-trim-propagate — parse_patch_headers stops propagating a deny out of its
#   header-path trim command substitution.
# mutant:457-cdg-dl-trim-ltrim-propagate — trim stops propagating a deny out of its nested ltrim.
# mutant:457-cdg-dl-bpl-trim-propagate — has_exact_begin_patch_line stops propagating a deny out of
#   its trim command substitution.
# mutant:457-cdg-dl-line-cap-off — the per-line size cap check becomes a no-op, so an over-cap line
#   reaches the unsampled substitutions instead of denying at the cap.
# mutant:457-cdg-dl-line-cap-offbyone — the cap comparison becomes strict, so a line of exactly the
#   cap's length denies.
# mutant:457-cdg-dl-line-cap-before-role — a size check before the role exit, so an over-cap line
#   from a non-role agent denies.
# mutant:457-cdg-dl-prepare-site — cdg_prepare_text's line loop loses its sample.
# mutant:457-cdg-dl-path-cap-off — classify_path's length check becomes a no-op, so a 200000-CR
#   Edit file_path reaches the whole-string substitutions instead of denying at the cap.
# mutant:457-cdg-dl-cwd-cap-off — the apply_patch route's cwd length check becomes a no-op, so a
#   200000-CR cwd reaches the whole-string substitutions.
# mutant:457-cdg-dl-cwd-cap-bash-off — the same for the Bash route's inline-patch cwd check.
# mutant:457-cdg-dl-patch-marker-uncapped — the native route stops line-capping a `*** ` marker
#   line, so an over-cap header line reaches the parser.
# mutant:457-cdg-dl-bytes-off-prepare — cdg_prepare_text measures characters, not bytes.
# mutant:457-cdg-dl-bytes-late-prepare — cdg_prepare_text measures the whole text before scoping
#   LC_ALL=C, so the whole-text cap counts characters.
# mutant:457-cdg-dl-cwd-chars — the apply_patch route measures cwd in characters.
# mutant:457-cdg-dl-cwd-chars-bash — the Bash route measures cwd in characters.
# mutant:457-cdg-dl-bytes-off-fn — cdg_bytes measures characters, not bytes.
# mutant:457-cdg-dl-text-cap-off — the whole-text size check becomes a no-op, so an over-cap native
#   patch reaches the parser, which denies at its unrecognised-marker probe line instead of the
#   too-large line.
# mutant:457-cdg-dl-text-cap-offbyone — the whole-text comparison becomes strict, so a text of
#   exactly the cap denies as too large instead of reaching the parser (filter "cdgtextcap-").
# mutant:457-cdg-dl-native-cr-uncapped — the native route stops line-capping a CR-bearing line.
# mutant:457-cdg-dl-bash-cr-strip-off — the Bash route keeps its unstripped command text.
# mutant:457-cdg-dl-path-cap-offbyone — classify_path's comparison becomes strict, so a path of
#   exactly the cap denies.
# mutant:457-cdg-dl-patch-prepare-off — the apply_patch route stops running cdg_prepare_text, so an
#   over-cap patch line reaches the whole-text work instead of denying at the cap.
# mutant:457-cdg-dl-iapw-line-site — is_apply_patch_word's per-line loop loses its sample.
# mutant:457-cdg-dl-qpc-site — quote_parity_check's loop loses its sample.
# mutant:457-cdg-dl-scan-outer-site — scan_shim_input's outer loop loses its sample.
# mutant:457-cdg-dl-scan-inner-site — scan_shim_input's redirect-run loop loses its sample.
# mutant:457-hook-cdg-budget-override-leaks — run_claude_guard's own trailing budget-override reset
#   deleted: the post-call emptiness assertion is the only thing that catches it.
# mutant:457-hook-cdg-cap-override-leaks — the same for the cap-override reset.
case_cdg_dl_deny_budget_zero() {
  cdg_budget_override=0
  run_claude_guard "$(printf '%s' 'echo apply_patch' | mk_cdg_dl_bash implementer '')"
  [ -z "$cdg_budget_override" ] || { __ok=0; __why="${__why}cdg_budget_override not cleared after run_claude_guard: '$cdg_budget_override'\n"; }
  expect_cdg_deny_too_large implementer Bash
}
case_cdg_dl_deny_budget_zero_patch() {
  local patch="*** Begin Patch${LF}*** Add File: /repo/a${LF}+x${LF}*** End Patch"
  cdg_budget_override=0
  run_claude_guard "$(printf '%s' "$patch" | mk_cdg_dl_patch verifier)"
  expect_cdg_deny_too_large verifier apply_patch
}
case_cdg_dl_never_executes() {
  local trapdir="$tmpbase/trapbin-cdg-dl" sentinel="$tmpbase/sentinel-cdg-dl" bin
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname tr awk grep sed; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  cdg_budget_override=0
  run_claude_guard "$(printf '%s' 'echo apply_patch' | mk_cdg_dl_bash implementer '')" "$trapdir:$PATH"
  expect_cdg_deny_too_large implementer Bash
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — claude-dir-guard.sh invoked something on the booby-trapped PATH\n"; }
}
# cdg_dl_line_cap — the CDG_LINE_MAX_BYTES value, extracted from the hook's own vocabulary line.
cdg_dl_line_cap() {
  sed -n 's/^CDG_LINE_MAX_BYTES="\([0-9][0-9]*\)"$/\1/p' "$claude_dir_guard"
}
# cdg_dl_text_cap — the CDG_TEXT_MAX_BYTES value, extracted from the hook's own vocabulary line.
cdg_dl_text_cap() {
  sed -n 's/^CDG_TEXT_MAX_BYTES="\([0-9][0-9]*\)"$/\1/p' "$claude_dir_guard"
}
# cdg_dl_fill N — N ASCII x characters (N >= 1), built by doubling a string rather than by a
# million-argument printf, which is expensive on the harness side under bash 3.2.
cdg_dl_fill() {
  local n="$1" s=x
  while [ "${#s}" -lt "$n" ]; do s="$s$s"; done
  printf '%s' "${s:0:$n}"
}
# CDG_TEXTCAP_PROBE — the first line of the whole-text-cap payloads. The native route caps a "*** "
# line at CDG_LINE_MAX_BYTES (this one is short) and never line-caps a CR-free content line, and
# parse_patch_headers denies an unrecognised "*** " marker on the first line it reads. So a payload
# that reaches the parser is denied at this line with the parser's own line, and the filler line
# after it is only scanned by cdg_prepare_text and the whole-text splits, never trimmed or matched.
CDG_TEXTCAP_PROBE="*** Text Cap Probe"
# cdg_textcap_patch LEN — the probe line, then one CR-free content line of x characters: exactly LEN
# ASCII bytes, no CR, no trailing LF.
cdg_textcap_patch() {
  local len="$1"
  printf '%s%s+%s' "$CDG_TEXTCAP_PROBE" "$LF" "$(cdg_dl_fill $((len - ${#CDG_TEXTCAP_PROBE} - 2)))"
}
# cdg_dl_pad_cmd LEN — a benign one-line command of exactly LEN characters.
cdg_dl_pad_cmd() {
  local len="$1" cmd="echo apply_patch"
  while [ "${#cmd}" -lt "$len" ]; do cmd="${cmd} a"; done
  printf '%s' "${cmd:0:$len}"
}
case_cdg_dl_deny_line_400k() {
  # Regression pin (no registry mutant: uncapped, the run denies via a sample on bash 5 but only via
  # the deadline overrun on bash 3.2; line-cap-off is killed by the just-over-cap fixture instead).
  # The 400KB whitespace-plus-`<` single-line command that used to outlast the hook timeout inside
  # is_apply_patch_word's own unsampled substitution: it now denies at the per-line size cap,
  # before any substitution, well inside a 15s active deadline.
  local sp
  sp="$(printf ' %.0s' $(seq 1 400000))"
  cdg_deadline_override=15
  run_claude_guard "$(printf 'apply_patch < x.patch%s' "$sp" | mk_cdg_dl_bash implementer '')"
  expect_cdg_deny_too_large implementer Bash
}
case_cdg_dl_deny_line_just_over_cap() {
  local cap cmd
  cap="$(cdg_dl_line_cap)"
  if [ -z "$cap" ]; then __ok=0; __why="${__why}could not extract CDG_LINE_MAX_BYTES from the hook\n"; return; fi
  cmd="$(cdg_dl_pad_cmd $((cap + 1)))"
  [ "${#cmd}" -eq $((cap + 1)) ] || { __ok=0; __why="${__why}fixture bug: line is ${#cmd} chars, wanted $((cap + 1))\n"; return; }
  run_claude_guard "$(printf '%s' "$cmd" | mk_cdg_dl_bash implementer '')"
  expect_cdg_deny_too_large implementer Bash
}
case_cdg_dl_noop_line_at_cap() {
  local cap cmd
  cap="$(cdg_dl_line_cap)"
  if [ -z "$cap" ]; then __ok=0; __why="${__why}could not extract CDG_LINE_MAX_BYTES from the hook\n"; return; fi
  cmd="$(cdg_dl_pad_cmd "$cap")"
  [ "${#cmd}" -eq "$cap" ] || { __ok=0; __why="${__why}fixture bug: line is ${#cmd} chars, wanted $cap\n"; return; }
  run_claude_guard "$(printf '%s' "$cmd" | mk_cdg_dl_bash implementer '')"
  expect_cdg_no_opinion
}
case_cdg_dl_noop_line_over_cap_main_session() {
  run_claude_guard "$(cdg_dl_pad_cmd 5000 | mk_cdg_dl_bash '' '')"
  expect_cdg_no_opinion
}
case_cdg_dl_noop_line_over_cap_other_agent() {
  run_claude_guard "$(cdg_dl_pad_cmd 5000 | mk_cdg_dl_bash Explore '')"
  expect_cdg_no_opinion
}
# cdg_dl_big_patch_cmd PATH — a shell-issued inline heredoc patch of 100 ordinary-length lines
# (well over any single-line cap in total, but each line short), adding the file PATH. Sized so the
# per-line forked trims it costs stay far inside the hook's 5s analysis budget on a loaded host.
cdg_dl_big_patch_cmd() {
  local body="" i
  for i in $(seq 1 100); do body="${body}+line ${i} of the added file, ordinary prose here${LF}"; done
  printf "apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Add File: %s${LF}%s*** End Patch${LF}EOF" "$1" "$body"
}
case_cdg_dl_noop_big_patch() {
  # A realistic large heredoc patch (many ordinary-length lines, a benign path) is not capped by
  # total size: no opinion, well inside a 15s active deadline.
  cdg_deadline_override=15
  run_claude_guard "$(cdg_dl_big_patch_cmd /repo/big.txt | mk_cdg_dl_bash implementer '')"
  expect_cdg_no_opinion
}
case_cdg_dl_deny_big_patch_claude() {
  cdg_deadline_override=15
  run_claude_guard "$(cdg_dl_big_patch_cmd /repo/.claude/big.txt | mk_cdg_dl_bash implementer '')"
  expect_cdg_deny_unparseable
}
case_cdg_dl_deny_patch_cr_line() {
  # A native apply_patch whose one content line is 400KB of CRs: the CR strip used to be a whole-text
  # substitution that never finished within the hook timeout. It now denies at the per-line cap,
  # before any strip, well inside a 15s active deadline.
  local crs patch
  crs="$(printf '\r%.0s' $(seq 1 400000))"
  patch="*** Begin Patch${LF}*** Add File: /repo/a${LF}+${crs}${LF}*** End Patch"
  cdg_deadline_override=15
  run_claude_guard "$(printf '%s' "$patch" | mk_cdg_dl_patch implementer)"
  expect_cdg_deny_too_large implementer apply_patch
}
case_cdg_dl_deny_path_cr() {
  # An Edit whose file_path is 200000 CRs: the whole-string CR strip in classify_path used to run
  # past the hook timeout. It now denies at the per-line cap, inside a 15s active deadline.
  local crs
  crs="$(printf '\r%.0s' $(seq 1 200000))"
  cdg_deadline_override=15
  run_claude_guard "$(printf '%s' "/repo/a${crs}" | jq -Rs '{tool_name: "Edit", agent_type: "implementer", tool_input: {file_path: .}}')"
  expect_cdg_deny_too_large implementer Edit
}
case_cdg_dl_deny_cwd_cr() {
  # Regression pin (no registry mutant: whether an uncapped run times out or merely denies later
  # depends on the bash; the just-over-cap cwd fixtures carry the kill).
  local crs
  crs="$(printf '\r%.0s' $(seq 1 200000))"
  cdg_deadline_override=15
  run_claude_guard "$(printf '%s' "/repo${crs}" | jq -Rs --arg p "$CDG_P" '{tool_name: "apply_patch", agent_type: "implementer", cwd: ., tool_input: {command: $p}}')"
  expect_cdg_deny_too_large implementer apply_patch
}
case_cdg_dl_deny_cwd_cr_bash() {
  # Regression pin, as case_cdg_dl_deny_cwd_cr.
  local crs cmd
  crs="$(printf '\r%.0s' $(seq 1 200000))"
  cmd="apply_patch <<'EOF'${LF}${CDG_P}${LF}EOF"
  cdg_deadline_override=15
  run_claude_guard "$(printf '%s' "/repo${crs}" | jq -Rs --arg p "$cmd" '{tool_name: "Bash", agent_type: "implementer", cwd: ., tool_input: {command: $p}}')"
  expect_cdg_deny_too_large implementer Bash
}
case_cdg_dl_deny_patch_cr_just_over_cap() {
  # A native content line of exactly cap+1 bytes made of a leading `+` and CRs: over the line cap by
  # its CR alone, so it denies at the cap; uncapped, the 2000 CRs strip in a blink and the patch
  # parses as a benign path (no opinion), so the verdict differs on any host and bash.
  local cap crs patch
  cap="$(cdg_dl_line_cap)"
  if [ -z "$cap" ]; then __ok=0; __why="${__why}could not extract CDG_LINE_MAX_BYTES from the hook\n"; return; fi
  crs="$(printf '\r%.0s' $(seq 1 "$cap"))"
  patch="*** Begin Patch${LF}*** Add File: /repo/a${LF}+${crs}${LF}*** End Patch"
  run_claude_guard "$(printf '%s' "$patch" | mk_cdg_dl_patch implementer)"
  expect_cdg_deny_too_large implementer apply_patch
}
case_cdg_dl_noop_patch_cr_many() {
  # A many-line patch with a CR on every line, adding a benign path: CRs are stripped per line, the
  # patch parses as before, no opinion, inside a 15s active deadline.
  local patch i
  patch="*** Begin Patch${CR}${LF}*** Add File: /repo/a${CR}${LF}"
  for i in $(seq 1 250); do patch="${patch}+line ${i} of the added file, ordinary prose${CR}${LF}"; done
  patch="${patch}*** End Patch${CR}${LF}"
  cdg_deadline_override=15
  run_claude_guard "$(printf '%s' "$patch" | mk_cdg_dl_patch implementer)"
  expect_cdg_no_opinion
}
case_cdg_dl_deny_production_budget() {
  # The production deadline, deterministically on any host and bash: a native apply_patch whose one
  # CR-free content line is 500000 spaces (under the whole-text cap, and not line-capped on this
  # route), which ltrim's strip loop eats one character at a time -- quadratic in the run, so far
  # past the 5s budget on any host. The deadline sample inside that loop denies once the budget is
  # spent. Budget knob 99 must be ignored (the knob only lowers); the run sits under a 15s active
  # deadline. The payload reaches jq on stdin, never as a --arg.
  local sp patch
  sp="$(printf ' %.0s' $(seq 1 500000))"
  patch="*** Begin Patch${LF}*** Add File: /repo/a${LF}${sp}${LF}*** End Patch"
  cdg_budget_override=99
  cdg_deadline_override=15
  run_claude_guard "$(printf '%s' "$patch" | mk_cdg_dl_patch implementer)"
  expect_cdg_deny_too_large implementer apply_patch
}
case_cdg_dl_deny_patch_marker_line() {
  # A native patch whose first line is an unrecognised `*** ` marker one byte over the line cap,
  # padded with non-whitespace (no CR, no trailing whitespace): over the cap by its `*** ` marker
  # alone, so it denies at the cap with the too-large line. Uncapped, the parser reaches line 1 and
  # denies with its unrecognised-marker line at once, a different verdict with no trim loop, so the
  # kill does not depend on host load. (Not a long path: classify_path's own cap would also print
  # the too-large line.)
  local cap patch
  cap="$(cdg_dl_line_cap)"
  if [ -z "$cap" ]; then __ok=0; __why="${__why}could not extract CDG_LINE_MAX_BYTES from the hook\n"; return; fi
  patch="${CDG_TEXTCAP_PROBE}$(cdg_dl_fill $((cap + 1 - ${#CDG_TEXTCAP_PROBE})))"
  [ "${#patch}" -eq $((cap + 1)) ] || { __ok=0; __why="${__why}fixture bug: line is ${#patch} chars, wanted $((cap + 1))\n"; return; }
  run_claude_guard "$(printf '%s' "$patch" | mk_cdg_dl_patch implementer)"
  expect_cdg_deny_too_large implementer apply_patch
}
case_cdg_dl_deny_cwd_just_over_cap() {
  local cap c
  cap="$(cdg_dl_line_cap)"
  if [ -z "$cap" ]; then __ok=0; __why="${__why}could not extract CDG_LINE_MAX_BYTES from the hook\n"; return; fi
  c="/repo/$(printf 'c%.0s' $(seq 1 $((cap - 5))))"
  [ "${#c}" -eq $((cap + 1)) ] || { __ok=0; __why="${__why}fixture bug: cwd is ${#c} chars, wanted $((cap + 1))\n"; return; }
  run_claude_guard "$(printf '%s' "$c" | jq -Rs --arg p "$CDG_P" '{tool_name: "apply_patch", agent_type: "implementer", cwd: ., tool_input: {command: $p}}')"
  expect_cdg_deny_too_large implementer apply_patch
}
case_cdg_dl_deny_cwd_just_over_cap_bash() {
  local cap c cmd
  cap="$(cdg_dl_line_cap)"
  if [ -z "$cap" ]; then __ok=0; __why="${__why}could not extract CDG_LINE_MAX_BYTES from the hook\n"; return; fi
  c="/repo/$(printf 'c%.0s' $(seq 1 $((cap - 5))))"
  cmd="apply_patch <<'EOF'${LF}${CDG_P}${LF}EOF"
  run_claude_guard "$(printf '%s' "$c" | jq -Rs --arg p "$cmd" '{tool_name: "Bash", agent_type: "implementer", cwd: ., tool_input: {command: $p}}')"
  expect_cdg_deny_too_large implementer Bash
}
# cdg_utf8_locale — sets cdg_utf8 to a UTF-8 locale this host's bash really honours (a 4-byte
# character measures 1 under it, with nothing written to stderr), probing C.UTF-8, then
# en_US.UTF-8, then every UTF-8 name `locale -a` lists; empty when none works. Probed once, with
# the same bash the hook runs under.
cdg_utf8=""
cdg_utf8_probed=0
cdg_utf8_locale() {
  [ "$cdg_utf8_probed" -eq 0 ] || return 0
  cdg_utf8_probed=1
  local cand cands="C.UTF-8 en_US.UTF-8" all line
  all="$(locale -a 2>/dev/null)"
  while IFS= read -r line; do
    case "$line" in
      *[Uu][Tt][Ff]-8|*[Uu][Tt][Ff]8) cands="$cands $line" ;;
    esac
  done <<CDG_LOCALES_EOF
$all
CDG_LOCALES_EOF
  for cand in $cands; do
    if [ "$(LC_ALL="$cand" "$bash_bin" -c 'x=$(printf "\360\237\230\200"); echo "${#x}"' 2>&1)" = "1" ]; then
      cdg_utf8="$cand"
      return 0
    fi
  done
  return 0
}
# cdg_need_utf8 — for the multibyte cases: sets cdg_locale_override to a verified UTF-8 locale, or
# fails the case with a clear message (never a silent pass) when the host has none.
cdg_need_utf8() {
  cdg_utf8_locale
  if [ -z "$cdg_utf8" ]; then
    __ok=0; __why="${__why}no working UTF-8 locale on this host (tried C.UTF-8, en_US.UTF-8, and locale -a): the multibyte cases cannot run\n"
    return 1
  fi
  cdg_locale_override="$cdg_utf8"
  return 0
}
case_cdg_dl_deny_line_multibyte() {
  # 600 four-byte characters (2400 bytes, 600 characters): over the byte cap, under it in
  # characters -- the hook measures bytes. The harness pins a UTF-8 locale for the run.
  local mb
  mb="$(printf '\360\237\230\200%.0s' $(seq 1 600))"
  cdg_need_utf8 || return
  run_claude_guard "$(printf 'echo apply_patch %s' "$mb" | mk_cdg_dl_bash implementer '')"
  expect_cdg_deny_too_large implementer Bash
}
case_cdg_dl_deny_path_multibyte() {
  local mb
  mb="$(printf '\360\237\230\200%.0s' $(seq 1 600))"
  cdg_need_utf8 || return
  run_claude_guard "$(printf '%s' "/repo/${mb}" | jq -Rs '{tool_name: "Edit", agent_type: "implementer", tool_input: {file_path: .}}')"
  expect_cdg_deny_too_large implementer Edit
}
case_cdg_dl_deny_text_multibyte() {
  # A native patch whose first line is the unrecognised-marker probe, then two CR-free content lines
  # of 150000 four-byte characters each (about 1.2MB, 300000 characters): over the whole-text byte
  # cap, under it in characters. The native route does not line-cap an ordinary content line, so
  # only the whole-text check can see the size; a mutant that loses the check reaches the parser,
  # which denies at the probe line at once, so the kill does not depend on host load.
  local mb patch
  mb="$(printf '\360\237\230\200%.0s' $(seq 1 150000))"
  patch="${CDG_TEXTCAP_PROBE}${LF}+${mb}${LF}+${mb}"
  cdg_need_utf8 || return
  cdg_deadline_override=15
  run_claude_guard "$(printf '%s' "$patch" | mk_cdg_dl_patch implementer)"
  expect_cdg_deny_too_large implementer apply_patch
}
case_cdg_dl_pin_bash_text_wide() {
  # Regression pin with no registry mutant: 540 lines cost one forked trim each, so a mutant that
  # loses the whole-text check has to finish a full analysis under the 5s budget to differ, which
  # depends on host load; the native cdg-dl-deny-text-multibyte carries the kills.
  # The Bash-route twin: 540 lines of 475 four-byte characters (1900 bytes each, under the line cap):
  # about 1.03MB, only 256500 characters.
  local mb cmd i
  mb="$(printf '\360\237\230\200%.0s' $(seq 1 475))"
  cmd="echo apply_patch"
  for i in $(seq 1 540); do cmd="${cmd}${LF}${mb}"; done
  cdg_need_utf8 || return
  cdg_deadline_override=15
  run_claude_guard "$(printf '%s' "$cmd" | mk_cdg_dl_bash implementer '')"
  expect_cdg_deny_too_large implementer Bash
}
case_cdg_dl_deny_cwd_multibyte() {
  local mb
  mb="$(printf '\360\237\230\200%.0s' $(seq 1 600))"
  cdg_need_utf8 || return
  run_claude_guard "$(printf '%s' "/repo/${mb}" | jq -Rs --arg p "$CDG_P" '{tool_name: "apply_patch", agent_type: "implementer", cwd: ., tool_input: {command: $p}}')"
  expect_cdg_deny_too_large implementer apply_patch
}
case_cdg_dl_deny_cwd_multibyte_bash() {
  local mb cmd
  mb="$(printf '\360\237\230\200%.0s' $(seq 1 600))"
  cmd="apply_patch <<'EOF'${LF}${CDG_P}${LF}EOF"
  cdg_need_utf8 || return
  run_claude_guard "$(printf '%s' "/repo/${mb}" | jq -Rs --arg p "$cmd" '{tool_name: "Bash", agent_type: "implementer", cwd: ., tool_input: {command: $p}}')"
  expect_cdg_deny_too_large implementer Bash
}
case_cdg_dl_noop_native_long_line() {
  # A native patch whose CR-free content line is 3700 characters (longer than the line cap) adding
  # a benign path: an ordinary long line is not capped on the native route -- no opinion.
  local x patch
  x="$(printf 'x%.0s' $(seq 1 3700))"
  patch="*** Begin Patch${LF}*** Add File: /repo/a${LF}+${x}${LF}*** End Patch"
  run_claude_guard "$(printf '%s' "$patch" | mk_cdg_dl_patch implementer)"
  expect_cdg_no_opinion
}
case_cdg_dl_deny_text_over_cap() {
  # The one-byte twin of cdgtextcap-deny-parse-at-cap: the same marker-first payload, one byte over
  # the whole-text cap, denies at the whole-text check before any split, inside a 15s active
  # deadline. (The one long line is not line-capped on this route, so only the whole-text cap can
  # fire.) A mutant that drops or bypasses the check (457-cdg-dl-text-cap-off,
  # 457-cdg-dl-patch-prepare-off) reaches the parser and is denied by its unrecognised-marker line,
  # a different verdict on any host.
  local cap patch
  cap="$(cdg_dl_text_cap)"
  if [ -z "$cap" ]; then __ok=0; __why="${__why}could not extract CDG_TEXT_MAX_BYTES from the hook\n"; return; fi
  patch="$(cdg_textcap_patch $((cap + 1)))"
  [ "${#patch}" -eq $((cap + 1)) ] || { __ok=0; __why="${__why}fixture bug: text is ${#patch} chars, wanted $((cap + 1))\n"; return; }
  cdg_deadline_override=15
  run_claude_guard "$(printf '%s' "$patch" | mk_cdg_dl_patch implementer)"
  expect_cdg_deny_too_large implementer apply_patch
}
case_cdgtextcap_deny_parse_at_cap() {
  # A native patch of exactly the whole-text cap whose first line is an unrecognised marker. The
  # parser's unrecognised-marker line proves the text cap did not fire at exactly the cap (the cap
  # is an upper bound), without needing a full 1MB analysis inside the 5s production budget: the
  # parser stops at line 1, and a strict comparison would print the too-large line instead.
  # LC_ALL=C: the payload is ASCII, so its byte boundary is locale-independent, and C keeps
  # multibyte pattern matching out of the unsampled prefix. The case has its own cdgtextcap- prefix
  # so only the one registry record that needs it runs it. The residual cost is the floor every
  # at-cap call pays: reading the 1MB, the jq calls and one split before the parser's first sample.
  local cap patch json want
  cap="$(cdg_dl_text_cap)"
  if [ -z "$cap" ]; then __ok=0; __why="${__why}could not extract CDG_TEXT_MAX_BYTES from the hook\n"; return; fi
  patch="$(cdg_textcap_patch "$cap")"
  [ "${#patch}" -eq "$cap" ] || { __ok=0; __why="${__why}fixture bug: text is ${#patch} chars, wanted $cap\n"; return; }
  json="$(printf '%s' "$patch" | mk_cdg_dl_patch implementer)"
  want="trail-blazer-flow claude-dir guard: implementer role's apply_patch could not be parsed (unrecognised marker: *** Text Cap Probe), and is denied fail-closed"
  cdg_locale_override=C
  cdg_deadline_override=15
  measure_ms run_claude_guard "$json"
  if [ "$cdg_rc" != "2" ] || [ -n "$cdg_out" ] || [ "$cdg_err" != "$want" ]; then
    __ok=0
    __why="${__why}expected rc 2, empty stdout and the parser's unrecognised-marker line; got rc=${cdg_rc} stdout=[${cdg_out}] stderr=[${cdg_err}]; hook run ${measured_ms}ms\n"
    case "$cdg_err" in
      *"too large to analyse"*) __why="${__why}the too-large line means the cap comparison is strict, a native line cap hit the CR-free content line, or the pre-parser 1MB work outran the budget on this host\n" ;;
    esac
  fi
}
case_cdg_dl_deny_bash_cr_word() {
  # A CR glued to the shim word (`apply_patch<CR> < x.patch`): only the Bash route's CR strip lets
  # the walk recognise the command word, after which the no-inline-patch deny fires. Losing the
  # strip leaves a token the walk does not recognise, so the call would pass.
  run_claude_guard "$(printf 'apply_patch\r < x.patch' | mk_cdg_dl_bash implementer '')"
  expect_cdg_deny_unparseable
}
case_cdg_dl_noop_path_at_cap() {
  local cap p
  cap="$(cdg_dl_line_cap)"
  if [ -z "$cap" ]; then __ok=0; __why="${__why}could not extract CDG_LINE_MAX_BYTES from the hook\n"; return; fi
  p="/repo/$(printf 'a%.0s' $(seq 1 $((cap - 6))))"
  [ "${#p}" -eq "$cap" ] || { __ok=0; __why="${__why}fixture bug: path is ${#p} chars, wanted $cap\n"; return; }
  run_claude_guard "$(mk_cdg_agent_path implementer Edit "$p")"
  expect_cdg_no_opinion
}
case_cdg_dl_deny_path_just_over_cap() {
  local cap p
  cap="$(cdg_dl_line_cap)"
  if [ -z "$cap" ]; then __ok=0; __why="${__why}could not extract CDG_LINE_MAX_BYTES from the hook\n"; return; fi
  p="/repo/$(printf 'a%.0s' $(seq 1 $((cap - 5))))"
  [ "${#p}" -eq $((cap + 1)) ] || { __ok=0; __why="${__why}fixture bug: path is ${#p} chars, wanted $((cap + 1))\n"; return; }
  run_claude_guard "$(mk_cdg_agent_path implementer Edit "$p")"
  expect_cdg_deny_too_large implementer Edit
}
case_cdg_dl_noop_budget_zero_edit() {
  cdg_budget_override=0
  cdg_cap_override=1
  run_claude_guard "$(mk_cdg_agent_path implementer Edit /repo/src/a.rs)"
  expect_cdg_no_opinion
}
case_cdg_dl_noop_main_session() {
  # Fast path 1 (no agent_type) excludes this call before any sample site, so this is a contract
  # pin with no mutant of its own.
  cdg_budget_override=0
  cdg_cap_override=1
  run_claude_guard "$(printf '%s' 'echo apply_patch' | mk_cdg_dl_bash '' '')"
  expect_cdg_no_opinion
}
case_cdg_dl_noop_other_agent() {
  cdg_budget_override=0
  cdg_cap_override=1
  run_claude_guard "$(printf '%s' 'echo apply_patch' | mk_cdg_dl_bash Explore '')"
  expect_cdg_no_opinion
}
case_cdg_dl_noop_plan_mode() {
  cdg_budget_override=0
  cdg_cap_override=1
  run_claude_guard "$(printf '%s' 'echo apply_patch' | mk_cdg_dl_bash implementer plan)"
  expect_cdg_no_opinion
}
# cdg_dl_cap_check_bash CMD — run CMD as an implementer Bash call under cap 50, expect the deny,
# and assert the cap override was cleared.
cdg_dl_cap_check_bash() {
  cdg_cap_override="${2:-50}"
  run_claude_guard "$(printf '%s' "$1" | mk_cdg_dl_bash implementer '')"
  [ -z "$cdg_cap_override" ] || { __ok=0; __why="${__why}cdg_cap_override not cleared after run_claude_guard: '$cdg_cap_override'\n"; }
  expect_cdg_deny_too_large implementer Bash
}
cdg_dl_cap_check_patch() {
  cdg_cap_override="${2:-50}"
  run_claude_guard "$(printf '%s' "$1" | mk_cdg_dl_patch implementer)"
  expect_cdg_deny_too_large implementer apply_patch
}
case_cdg_dl_cap_seg() {
  local cmd="" i
  for i in $(seq 1 100); do cmd="${cmd}; "; done
  cdg_dl_cap_check_bash "${cmd}echo apply_patch"
}
case_cdg_dl_cap_ww() {
  local cmd="" i
  for i in $(seq 1 100); do cmd="${cmd}env "; done
  cdg_dl_cap_check_bash "${cmd}echo apply_patch"
}
case_cdg_dl_cap_redir() {
  local cmd="" i
  for i in $(seq 1 100); do cmd="${cmd}>"; done
  cdg_dl_cap_check_bash "${cmd}x echo apply_patch"
}
case_cdg_dl_cap_db() {
  local cmd="echo apply_patch ]] " i
  for i in $(seq 1 100); do cmd="${cmd}a "; done
  cdg_dl_cap_check_bash "$cmd"
}
case_cdg_dl_cap_lines() {
  # A `;`-only line makes no segment, but it is a line: three loops (the line prepass, the
  # per-line segment builder, and the begin-patch scan) each sample once per line, so the cap
  # (250) is reached only when all three sample.
  local cmd="echo apply_patch" i
  for i in $(seq 1 100); do cmd="${cmd}${LF};"; done
  cdg_dl_cap_check_bash "$cmd" 250
}
case_cdg_dl_cap_qpc() {
  # 100 prefix words before the resolved word, in a segment that mentions the shim and carries a
  # quote: the walk and the parity pass each sample once per token, so the cap (150) is reached
  # only when the parity pass samples too.
  local cmd="" i
  for i in $(seq 1 100); do cmd="${cmd}env "; done
  cdg_dl_cap_check_bash "${cmd}echo apply_patch \"\"" 150
}
case_cdg_dl_cap_scan_shim() {
  # A heredoc shim followed by 100 safe output redirects: the input scan's outer loop samples once
  # per redirect and its redirect-run loop twice, so the cap (270) is reached only when both
  # sample.
  local cmd="apply_patch <<'EOF'" i
  for i in $(seq 1 100); do cmd="${cmd} >x"; done
  cdg_dl_cap_check_bash "${cmd}${LF}${CDG_P}${LF}EOF" 270
}
case_cdg_dl_cap_ph() {
  local patch="*** Begin Patch${LF}*** Add File: /repo/a" i
  for i in $(seq 1 100); do patch="${patch}${LF}+x"; done
  # The patch route's line prepass (cdg_prepare_text) samples once per line too, so the cap (150)
  # is reached only when the header loop samples as well.
  cdg_dl_cap_check_patch "${patch}${LF}*** End Patch" 150
}
case_cdg_dl_cap_ltrim() {
  local sp
  sp="$(printf ' %.0s' $(seq 1 100))"
  cdg_dl_cap_check_patch "*** Begin Patch${LF}${sp}*** Add File: /repo/a${LF}*** End Patch"
}
case_cdg_dl_cap_trim_header() {
  local sp
  sp="$(printf ' %.0s' $(seq 1 100))"
  cdg_dl_cap_check_patch "*** Begin Patch${LF}*** Add File: /repo/a${sp}${LF}*** End Patch"
}
case_cdg_dl_cap_trim_nested() {
  local sp
  sp="$(printf ' %.0s' $(seq 1 100))"
  cdg_dl_cap_check_patch "*** Begin Patch${LF}*** Add File: ${sp}/repo/a${LF}*** End Patch"
}
case_cdg_dl_cap_trim_bash() {
  local sp
  sp="$(printf ' %.0s' $(seq 1 100))"
  cdg_dl_cap_check_bash "echo apply_patch${sp}"
}

# --- claude-dir-guard.sh decoy inline patch (#455) -------------------------------------------
# When the shim's own segment takes its input from anything but its own inline `<<` heredoc, the
# Bash route denies before the structured parse can be satisfied by an unrelated benign inline
# patch elsewhere in the command. Safe set: a heredoc, an output redirect, a bare-digits fd before
# an output redirect. An unquoted heredoc delimiter on a command carrying `$`, a backtick or a
# backslash also denies (the shell expands the body first). Shared fixture text: CDG_P is the
# issue's benign patch, CDG_DECOY an unrelated heredoc feeding it to `cat`.
#
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter "cdg-dec-").
# mutant:455-cdg-dec-route — the Bash route's new decoy deny is switched off, so a benign inline
#   patch next to an unsafe shim input is judged by the structured parse alone again.
# mutant:455-cdg-dec-shim-record — the shim's resolved index is never recorded, so no segment's
#   input is ever scanned.
# mutant:455-cdg-dec-min — the smallest-index rule is dropped, so a later tail's shim index
#   overwrites an earlier one and the scan skips the unsafe argument between them.
# mutant:455-cdg-dec-in-redirect — a stdin redirect after a heredoc is no longer unsafe.
# mutant:455-cdg-dec-heredoc-exact — the heredoc test accepts three or more `<`, so a here-string
#   is read as a heredoc.
# mutant:455-cdg-dec-delim-required — the missing-delimiter guard is dropped, so a process
#   substitution's bare `< <` run is read as a heredoc.
# mutant:455-cdg-dec-arg — a non-redirect token after the shim is skipped instead of unsafe.
# mutant:455-cdg-dec-no-heredoc — a shim segment with no heredoc at all is no longer unsafe.
# mutant:455-cdg-dec-fd-out — the fd-before-output-redirect skip is removed, so `2>&1` reads as an
#   argument.
# mutant:455-cdg-dec-out-target — the output redirect's target is no longer skipped, so
#   `>/dev/null` reads as an argument.
# mutant:455-cdg-dec-unquoted-flag — an unquoted delimiter never sets iapw_unquoted.
# mutant:455-cdg-dec-delim-sq — a single-quote in the delimiter no longer counts as quoted.
# mutant:455-cdg-dec-delim-dq — a double-quote in the delimiter no longer counts as quoted.
# mutant:455-cdg-dec-delim-bs — a backslash in the delimiter no longer counts as quoted.
# mutant:455-cdg-dec-text-dollar — `$` no longer makes an unquoted-delimiter command unsafe.
# mutant:455-cdg-dec-text-backtick — a backtick no longer does.
# mutant:455-cdg-dec-text-backslash — a backslash no longer does.
CDG_P="*** Begin Patch${LF}*** Add File: /repo/ok${LF}+x${LF}*** End Patch"
CDG_DECOY="cat >/dev/null <<'EOF'${LF}${CDG_P}${LF}EOF"
expect_cdg_dec_deny() {
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"not from an inline heredoc"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'not from an inline heredoc': '$cdg_err'\n" ;;
  esac
}
cdg_dec_run() { run_claude_guard "$(mk_codex_shell 'implementer' "$1")"; }
case_cdg_dec_deny_redirect_file() { cdg_dec_run "${CDG_DECOY}${LF}apply_patch < evil.patch"; expect_cdg_dec_deny; }
case_cdg_dec_deny_redirect_first() { cdg_dec_run "apply_patch < evil.patch${LF}${CDG_DECOY}"; expect_cdg_dec_deny; }
case_cdg_dec_deny_applypatch() { cdg_dec_run "${CDG_DECOY}${LF}applypatch < evil.patch"; expect_cdg_dec_deny; }
case_cdg_dec_deny_pipe() { cdg_dec_run "${CDG_DECOY}${LF}cat evil.patch | apply_patch"; expect_cdg_dec_deny; }
case_cdg_dec_deny_herestring() { cdg_dec_run "${CDG_DECOY}${LF}apply_patch <<< \"\$p\""; expect_cdg_dec_deny; }
case_cdg_dec_deny_heredoc_then_redirect() { cdg_dec_run "apply_patch <<'EOF' < evil.patch${LF}${CDG_P}${LF}EOF"; expect_cdg_dec_deny; }
case_cdg_dec_deny_heredoc_then_herestring() { cdg_dec_run "apply_patch <<'EOF' <<< \"\$p\"${LF}${CDG_P}${LF}EOF"; expect_cdg_dec_deny; }
case_cdg_dec_deny_heredoc_then_rw() { cdg_dec_run "apply_patch <<'EOF' <> evil.patch${LF}${CDG_P}${LF}EOF"; expect_cdg_dec_deny; }
case_cdg_dec_deny_file_arg() { cdg_dec_run "apply_patch evil.patch <<'EOF'${LF}${CDG_P}${LF}EOF"; expect_cdg_dec_deny; }
case_cdg_dec_deny_fd_heredoc() { cdg_dec_run "cat evil.patch | apply_patch 3<<'EOF'${LF}${CDG_P}${LF}EOF"; expect_cdg_dec_deny; }
case_cdg_dec_deny_procsubst() { cdg_dec_run "${CDG_DECOY}${LF}apply_patch < <(cat evil.patch)"; expect_cdg_dec_deny; }
case_cdg_dec_deny_second_shim() {
  cdg_dec_run "apply_patch <<'EOF'${LF}${CDG_P}${LF}EOF${LF}apply_patch < evil.patch"
  expect_cdg_dec_deny
}
case_cdg_dec_deny_two_tails() {
  # The first tail's shim has a file argument; the second tail's shim is a legitimate heredoc. The
  # scan must start from the FIRST resolved shim index.
  cdg_dec_run "if [[ -n x ]] apply_patch evil.patch ]] apply_patch <<'EOF'${LF}${CDG_P}${LF}EOF"
  expect_cdg_dec_deny
}
case_cdg_dec_deny_unquoted_dollar() {
  cdg_dec_run "D=.cla\"\"ude; apply_patch <<EOF${LF}*** Begin Patch${LF}*** Add File: "'$D'"/settings.local.json${LF}+x${LF}*** End Patch${LF}EOF"
  expect_cdg_dec_deny
}
case_cdg_dec_deny_unquoted_backtick() {
  cdg_dec_run "apply_patch <<EOF${LF}*** Begin Patch${LF}*** Add File: src/"'`printf x`'"/y${LF}+x${LF}*** End Patch${LF}EOF"
  expect_cdg_dec_deny
}
case_cdg_dec_deny_unquoted_backslash() {
  # The shell's backslash-newline joins `.cla\` and `ude/...` into `.claude/...` inside an
  # unquoted heredoc body.
  local bs='\'
  cdg_dec_run "apply_patch <<EOF${LF}*** Begin Patch${LF}*** Add File: .cla${bs}${LF}ude/settings.local.json${LF}+x${LF}*** End Patch${LF}EOF"
  expect_cdg_dec_deny
}
case_cdg_dec_deny_body_codespan() {
  # Documented over-block: a body line whose first word is a code span of the shim name is its own
  # walk segment, a bare shim with no heredoc.
  cdg_dec_run "apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Update File: src/a.txt${LF}+See "'`apply_patch`'" docs${LF}*** End Patch${LF}EOF"
  expect_cdg_dec_deny
}
case_cdg_dec_deny_heredoc_dotdot() {
  # The legitimate heredoc shape still reaches the structured parse, which judges its headers.
  cdg_dec_run "apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Add File: ../etc/x${LF}+x${LF}*** End Patch${LF}EOF"
  expect_cdg_deny_unclassifiable
}
case_cdg_dec_noop_heredoc_sq_dollar() {
  cdg_dec_run "apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Add File: src/a.txt${LF}+echo "'$HOME'"${LF}*** End Patch${LF}EOF"
  expect_cdg_no_opinion
}
case_cdg_dec_noop_heredoc_dq_dollar() {
  cdg_dec_run "apply_patch <<\"EOF\"${LF}*** Begin Patch${LF}*** Add File: src/a.txt${LF}+echo "'$HOME'"${LF}*** End Patch${LF}EOF"
  expect_cdg_no_opinion
}
case_cdg_dec_noop_heredoc_bs_dollar() {
  cdg_dec_run "apply_patch <<\\EOF${LF}*** Begin Patch${LF}*** Add File: src/a.txt${LF}+echo "'$HOME'"${LF}*** End Patch${LF}EOF"
  expect_cdg_no_opinion
}
case_cdg_dec_noop_heredoc_dash() {
  local t=$'\t'
  cdg_dec_run "apply_patch <<-'EOF'${LF}${t}*** Begin Patch${LF}${t}*** Add File: src/a.txt${LF}${t}+x${LF}${t}*** End Patch${LF}${t}EOF"
  expect_cdg_no_opinion
}
case_cdg_dec_noop_heredoc_out_redirects() {
  cdg_dec_run "apply_patch <<'EOF' >/dev/null 2>&1${LF}*** Begin Patch${LF}*** Add File: src/a.txt${LF}+x${LF}*** End Patch${LF}EOF"
  expect_cdg_no_opinion
}
case_cdg_dec_noop_heredoc_chain() {
  cdg_dec_run "cd src && apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Add File: src/a.txt${LF}+x${LF}*** End Patch${LF}EOF"
  expect_cdg_no_opinion
}
case_cdg_dec_noop_unquoted_plain() {
  cdg_dec_run "apply_patch <<EOF${LF}*** Begin Patch${LF}*** Add File: src/a.txt${LF}+x${LF}*** End Patch${LF}EOF"
  expect_cdg_no_opinion
}
case_cdg_dec_noop_two_shims() {
  local one="apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Add File: src/a.txt${LF}+x${LF}*** End Patch${LF}EOF"
  cdg_dec_run "${one}${LF}${one}"
  expect_cdg_no_opinion
}
cdg_trap_path() {
  # cdg_trap_path NAME -- build a booby-trapped bin dir; sets cdg_trapdir and cdg_sentinel.
  cdg_trapdir="$tmpbase/trapbin-$1"
  cdg_sentinel="$tmpbase/sentinel-$1"
  mkdir -p "$cdg_trapdir"
  rm -f "$cdg_sentinel"
  local bin
  for bin in git gh rm dirname tr awk grep sed; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$cdg_sentinel"
      printf 'exit 1\n'
    } > "$cdg_trapdir/$bin"
    chmod +x "$cdg_trapdir/$bin"
  done
}
case_cdg_dec_never_executes() {
  cdg_trap_path cdg-dec
  run_claude_guard "$(mk_codex_shell 'implementer' "${CDG_DECOY}${LF}apply_patch < evil.patch")" "$cdg_trapdir:$PATH"
  expect_cdg_dec_deny
  [ ! -e "$cdg_sentinel" ] || { __ok=0; __why="${__why}sentinel file present — claude-dir-guard.sh invoked something on the booby-trapped PATH\n"; }
}
case_cdg_dec_deny_flood_timing() {
  # A long run of safe output redirects before an unsafe argument: the scan must walk the whole
  # run and still deny. Under a 15s active deadline (#463); the command reaches jq on stdin, as in
  # cdg-dbq-deny-timing (killed by 455-cdg-dec-arg: the scan reaches the trailing argument). The
  # run length is bounded because this shape's cost is superlinear in pre-existing code outside
  # this change (main overruns the deadline at larger sizes; the cause is not isolated here), and,
  # since #457, because the run sits on ONE physical line, which must stay under CDG_LINE_MAX_BYTES
  # or the hook denies it as too large before the scan runs at all.
  local flood payload
  flood="$(printf ' >o%.0s' $(seq 1 600))"
  payload="$(printf '%s' "apply_patch${flood} <<'EOF' x${LF}${CDG_P}${LF}EOF" \
    | jq -Rs '{tool_name: "Bash", agent_type: "implementer", cwd: "/repo", tool_input: {command: .}}')"
  cdg_deadline_override=15
  run_claude_guard "$payload"
  expect_cdg_dec_deny
}

# --- claude-dir-guard.sh quoted assignment value (#455, absorbing #456) ----------------------
# A token carrying an odd count of `'` or `"`, or ending in a backslash, between a walk window's
# start and its resolved non-shim command word, in a segment that mentions the shim, denies: the
# whitespace split happens before quotes are stripped, so `X='a b'` leaves `b'` to resolve as the
# command word and hide the shim.
#
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter "cdg-qa-"
# unless noted).
# mutant:455-cdg-qa-check — the parity test never fires.
# mutant:455-cdg-qa-sq — only double quotes are counted.
# mutant:455-cdg-qa-dq — only single quotes are counted.
# mutant:455-cdg-qa-backslash — the trailing-backslash arm never fires.
# mutant:455-cdg-qa-range-start — the check covers only the resolved token, not the tokens
#   before it.
# mutant:455-cdg-qa-range-end — the check runs through the window's end, past the resolved word.
# mutant:455-cdg-qa-resolved-inclusive — the check stops one token short of the resolved word.
# mutant:455-cdg-qa-scope — the check runs in every segment, not only those mentioning the shim.
# mutant:455-cdg-qa-scope-applypatch — the segment scope drops the `applypatch` spelling, so a
#   quoted-assignment prefix before `applypatch` is never checked.
# mutant:455-cdg-qa-shim-exempt — the check also runs when the resolved word IS the shim (filter
#   "cdg-dbq-").
expect_cdg_qa_deny() {
  expect_cdg_deny_unparseable
  case "$cdg_err" in
    *"unbalanced quote"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain 'unbalanced quote': '$cdg_err'\n" ;;
  esac
}
case_cdg_qa_deny_sq_space() { cdg_dec_run "X='a b' apply_patch < x.patch"; expect_cdg_qa_deny; }
case_cdg_qa_deny_applypatch() { cdg_dec_run "X='a b' applypatch < x.patch"; expect_cdg_qa_deny; }
case_cdg_qa_deny_dq_space() { cdg_dec_run "X=\"a b\" apply_patch < x.patch"; expect_cdg_qa_deny; }
case_cdg_qa_deny_sq_many_spaces() { cdg_dec_run "X='a b c d' apply_patch < x.patch"; expect_cdg_qa_deny; }
case_cdg_qa_deny_dq_many_spaces() { cdg_dec_run "X=\"a b  c\" apply_patch < x.patch"; expect_cdg_qa_deny; }
case_cdg_qa_deny_env_assign() { cdg_dec_run "env X='a b' apply_patch < x.patch"; expect_cdg_qa_deny; }
case_cdg_qa_deny_env_quoted_assign() { cdg_dec_run "env 'X=a b' apply_patch < x.patch"; expect_cdg_qa_deny; }
case_cdg_qa_deny_redirect_target() { cdg_dec_run "< 'a b c' apply_patch"; expect_cdg_qa_deny; }
case_cdg_qa_deny_two_assigns() { cdg_dec_run "X='a b' Y='c d' apply_patch < x.patch"; expect_cdg_qa_deny; }
case_cdg_qa_deny_heredoc() { cdg_dec_run "X='a b' apply_patch <<'EOF'${LF}${CDG_P}${LF}EOF"; expect_cdg_qa_deny; }
case_cdg_qa_deny_cut_tail() { cdg_dec_run "if [[ -n x ]] X='a b' apply_patch < x.patch"; expect_cdg_qa_deny; }
case_cdg_qa_deny_backslash_space() { cdg_dec_run 'X=a\ b apply_patch < x.patch'; expect_cdg_qa_deny; }
case_cdg_qa_deny_body_possessive() {
  # Documented over-block: a context line whose first word carries an apostrophe and which
  # mentions the shim.
  cdg_dec_run "apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Update File: src/a.txt${LF} Codex's apply_patch shim${LF}*** End Patch${LF}EOF"
  expect_cdg_qa_deny
}
case_cdg_qa_noop_quoted_arg() { cdg_dec_run "echo 'a b' apply_patch"; expect_cdg_no_opinion; }
case_cdg_qa_noop_other_segment() { cdg_dec_run "X='a b' echo hi; rg apply_patch hooks/"; expect_cdg_no_opinion; }
case_cdg_qa_noop_balanced_assign() {
  cdg_dec_run "X='ab' apply_patch <<'EOF'${LF}*** Begin Patch${LF}*** Add File: src/a.txt${LF}+x${LF}*** End Patch${LF}EOF"
  expect_cdg_no_opinion
}
case_cdg_qa_never_executes() {
  cdg_trap_path cdg-qa
  run_claude_guard "$(mk_codex_shell 'implementer' "X='a b' apply_patch < x.patch")" "$cdg_trapdir:$PATH"
  expect_cdg_qa_deny
  [ ! -e "$cdg_sentinel" ] || { __ok=0; __why="${__why}sentinel file present — claude-dir-guard.sh invoked something on the booby-trapped PATH\n"; }
}
case_cdg_qa_noop_flood_timing() {
  # Many balanced quoted tokens before the resolved word, on one physical line (which must stay
  # under CDG_LINE_MAX_BYTES, #457): pins that balanced quotes never trip the parity check, so a
  # segment whose resolved word is not the shim (here `x`, with apply_patch only its argument) gets
  # no opinion. It no longer pins linearity: the line is too short for that, which the
  # cdg-dl-cap-qpc sample fixture covers.
  local flood payload
  flood="$(printf "'env' %.0s" $(seq 1 250))"
  payload="$(printf '%s' "${flood}x apply_patch" \
    | jq -Rs '{tool_name: "Bash", agent_type: "implementer", cwd: "/repo", tool_input: {command: .}}')"
  cdg_deadline_override=15
  run_claude_guard "$payload"
  expect_cdg_no_opinion
}

# --- existing hooks, Codex payload shape (#407) cases ---------------------------------------
# These exercise EXISTING logic under a new payload shape (the full documented Codex key set --
# session_id, turn_id, cwd, hook_event_name, model, permission_mode, tool_name, tool_use_id,
# transcript_path -- plus agent_type/agent_id for a subagent), pinning shape-compatibility: no new
# code path of their own, except codex-pg-impl-push-claude, which since #494 also exercises the
# Codex workdir route (its mutation proof is the push-wd-* section's, not a record of its own).

case_codex_gcg_main_status() { run_hook "$(mk_codex_shell '' 'git -C ../demo-wt-1 status --porcelain')"; expect_rc 0; expect_allow; }
case_codex_gcg_apply_patch() {
  hook_out="$(printf '%s' "$(mk_codex_patch '' '*** Begin Patch
*** Add File: x
*** End Patch')" | PATH="$PATH" "$bash_bin" "$guard" 2>/dev/null)"
  hook_rc=$?
  expect_rc 0
  expect_silent
}

case_codex_ab_impl_push()  { run_boundary "$(mk_codex_shell 'implementer' 'git push origin main')"; expect_deny; }
case_codex_ab_verif_commit() { run_boundary "$(mk_codex_shell 'verifier' 'git commit -am x')"; expect_deny; }
case_codex_ab_verif_status() { run_boundary "$(mk_codex_shell 'verifier' 'git status')"; expect_no_opinion; }
case_codex_ab_impl_python_claude() {
  run_boundary "$(mk_codex_shell 'implementer' "python3 -c \"open('.claude/settings.local.json','w').write('{}')\"")"
  expect_ab_deny_claude
}
case_codex_ab_main_push()  { run_boundary "$(mk_codex_shell '' 'git push origin main')"; expect_no_opinion; }
case_codex_ab_impl_apply_patch() {
  local errfile="$tmpbase/codex-ab-apply-patch-stderr"
  boundary_out="$(printf '%s' "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Add File: .claude/x
*** End Patch')" | PATH="$PATH" "$bash_bin" "$boundary" 2>"$errfile")"
  boundary_rc=$?
  boundary_err="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
  expect_no_opinion
}

case_codex_pg_main_push_main() {
  local badcwd="$tmpbase/codex-pg-nonexistent"
  run_push_guard "$(mk_codex_shell '' 'git push origin main' "$badcwd")"
  expect_push_deny
}
case_codex_pg_impl_push_claude() {
  # Since #494 a Codex-shaped push is judged against its rollout: one code-mode call, no
  # workdir.
  local rollout="$tmpbase/rollout-codex-pg-impl.jsonl"
  mk_wd_rollout "$rollout" "$(wd_rec_custom c1 'const r = await tools.exec_command({cmd:"git push -u origin \"claude/17-a\""}); text(r.output);')"
  run_push_guard "$(mk_codex_shell 'implementer' 'git push -u origin "claude/17-a"' '/repo' "$rollout")"
  expect_push_no_opinion
}
case_codex_pg_apply_patch() {
  local errfile="$tmpbase/codex-pg-apply-patch-stderr"
  push_out="$(printf '%s' "$(mk_codex_patch 'implementer' '*** Begin Patch
*** Add File: x
*** End Patch')" | PATH="$PATH" "$bash_bin" "$push_guard" 2>"$errfile")"
  push_rc=$?
  push_err="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
  expect_push_no_opinion
}

# --- hook canary (#407): gh --version, documented in docs/reference/safety-model.md -------------
# Harmless if it runs; a denial for implementer/verifier/planner proves each hook is loaded,
# trusted, and firing. The main session must see no opinion from any of the five hooks.
#
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter
# "canary-"), re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table.
# mutant:407-canary-ab-gh (target hooks/agent-boundary.sh) — makes the role-policy loop's `gh)`
#   arm unmatchable, so the canary is no longer denied for the implementer or verifier role.
# mutant:407-canary-plg-gh (target hooks/planner-guard.sh) — see the plg-* section above.
case_canary_implementer()    { run_boundary "$(mk_codex_shell 'implementer' 'gh --version')"; expect_deny; }
case_canary_implementer_ns() { run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' 'gh --version')"; expect_deny; }
case_canary_verifier()       { run_boundary "$(mk_codex_shell 'verifier' 'gh --version')"; expect_deny; }
case_canary_verifier_ns()    { run_boundary "$(mk_agent_cmd 'trail-blazer-flow:verifier' 'gh --version')"; expect_deny; }
case_canary_planner()        { run_planner_guard "$(mk_codex_shell 'planner' 'gh --version')"; expect_plg_deny; }
case_canary_planner_ns()     { run_planner_guard "$(mk_agent_cmd 'trail-blazer-flow:planner' 'gh --version')"; expect_plg_deny; }
case_canary_main_session() {
  local payload
  payload="$(mk_codex_shell '' 'gh --version')"
  hook_out="$(printf '%s' "$payload" | PATH="$PATH" "$bash_bin" "$guard" 2>/dev/null)"
  hook_rc=$?
  expect_silent
  run_boundary "$payload"
  expect_no_opinion
  run_push_guard "$payload"
  expect_push_no_opinion
  run_claude_guard "$payload"
  expect_cdg_no_opinion
  run_planner_guard "$payload"
  expect_plg_no_opinion
}

# ---------------------------------------------------------------------------------------------
# name|fn|desc
cases=(
  "status-rel|case_status_rel|allow: relative sibling path, status"
  "status-abs|case_status_abs|allow: absolute path, status"
  "deadline-kill-tree|case_deadline_kill_tree|#463: wait_deadline/kill_tree's shared mechanism against a synthetic TERM-ignoring root+child tree -> overrun detected, case failed and told why, returns in under 8s (not the child's own 15s lifetime), both pids dead afterwards"
  "deadline-site-budget|case_deadline_site_budget|#476: calibrated_site_budget's whole-second window, K-scaling and MAX clamp arithmetic -- no live clock"
  "deadline-flood-tokens|case_deadline_flood_tokens|#507: calibrated_flood_tokens' control scaling and MIN/MAX clamps -- no live clock"
  "deadline-calibrate|case_deadline_calibrate|#470: calibrated_deadline's floor/scale/round-up arithmetic and _ms_from_timeformat's shape parsing (leading-zero sub-second digits, comma decimal separator, unparseable input) -- plus a real sleep 0.3 through measure_ms, lower bound only"
  "status-quoted|case_status_quoted|allow: double-quoted path, status"
  "path-windows|case_path_windows|allow: Windows drive-letter path, diff"
  "path-trailing-slash|case_path_trailing_slash|allow: trailing slash on the worktree path, rev-parse"
  "checkpoint-composite|case_checkpoint_composite|allow: add -A && commit composite, quoted '#'/'('/')'/'':'' survive the lexer (probe row d)"
  "reset-soft|case_reset_soft|allow: reset --soft with a literal SHA"
  "merge-base|case_merge_base|allow: merge-base"
  "restore|case_restore|allow: restore"
  "push-upstream|case_push_upstream|allow: push -u origin with a quoted branch name"
  "diff-name-only|case_diff_name_only|allow: diff --name-only"
  "log|case_log|allow: log with a <default-branch>..HEAD range and --format=%s (probe row g)"
  "never-executes-git|case_never_executes_git|allow, AND the guard never invokes git (or rm) on the untrusted PATH — sentinel absent"
  "inject-config|case_inject_config|no opinion: -c core.pager=cat inserted before the subcommand (probe row b)"
  "inject-execpath|case_inject_execpath|no opinion: --exec-path= inserted before the subcommand"
  "attached-C|case_attached_c|no opinion: -C<path> attached form"
  "double-C|case_double_c|no opinion: a second -C"
  "token1-not-C|case_token1_not_c|no opinion: --exec-path= at token 1 with an otherwise-conforming path/subcommand and a second git -C segment (isolates the exact -C match)"
  "attached-C-4tok|case_attached_c_4tok|no opinion: attached -C<path> with 4+ tokens, an otherwise-conforming path/subcommand, and a second git -C segment"
  "path-not-worktree|case_path_not_worktree|no opinion: path is not <name>-wt-<n>"
  "path-glob|case_path_glob|no opinion: unquoted glob in the path"
  "unknown-sub|case_unknown_sub|no opinion: subcommand not in the ten (clean)"
  "reset-hard|case_reset_hard|no opinion: reset --hard is not reset --soft (probe row c's static half)"
  "composite-nongit|case_composite_nongit|no opinion: composite with a non-git constituent"
  "composite-one-bad|case_composite_one_bad|no opinion: composite where one constituent injects -c"
  "substitution-dollar|case_substitution_dollar|no opinion: \$(...) inside the double-quoted commit message"
  "substitution-backtick|case_substitution_backtick|no opinion: backtick substitution inside the double-quoted commit message"
  "semicolon|case_semicolon|no opinion: unquoted ';'"
  "redirect|case_redirect|no opinion: unquoted '>'"
  "pipe|case_pipe|no opinion: unquoted '|'"
  "unterminated-quote|case_unterminated_quote|no opinion: unterminated double quote"
  "wrong-tool|case_wrong_tool|no opinion: tool_name is not Bash"
  "malformed-json|case_malformed_json|no opinion: unparseable stdin"
  "missing-command|case_missing_command|no opinion: tool_input.command absent"
  "plan-mode|case_plan_mode|no opinion: permission_mode is exactly 'plan'"
  # --- hooks/agent-boundary.sh (#235) cases -----------------------------------------------------
  # Mutation-proof table (LESSON 2026-09-01, LESSON 2026-09-07(b)): each row below cites one of
  # the single-clause mutants actually applied to hooks/agent-boundary.sh via a `cp` backup
  # refreshed immediately before every mutation, with the observed `bash dev/hook-tests.sh`
  # pass/fail delta measured against this file's case set AT THE TIME of that mutation, then
  # restored and verified with a full `diff` before the next mutation. M1-M22 were measured
  # against the round-1 47-case/82-total addition; M23 was added by the round-2 kickback
  # that fixed hooks/agent-boundary.sh:167's chained-PREFIX_WORDS bug and was measured against
  # the 49-case/84-total addition — M1-M22's own numbers were NOT re-measured against
  # the 84-total baseline (LESSON 2026-09-06 asks only for bookkeeping, i.e. count words, to be
  # reconciled after the last case is added; re-running 22 already-verified mutants is out of
  # scope for this fix). M24 (below) was added by #270's CRLF-strip fix and was measured
  # (whole-file convention — bash dev/hook-tests.sh with no filter) against the then-current
  # 143-case file (agent-boundary's own addition 52 cases; push-guard's own addition then 56
  # cases — a DIFFERENT, larger figure, 60, was the `push`-name-filtered measurement unit the push
  # mutation table below used at that point: the 56 push-section rows plus four rows from the
  # OTHER two sections whose names happen to contain the substring "push" (push-upstream,
  # impl-deny-push-bare, impl-deny-push-ns, impl-deny-git-c-push) — M1-M23's own numbers were NOT
  # re-measured against that 143-case total: the 82/84-case figures above predate #260's
  # push-guard section entirely (it did not exist yet when M1-M22 were measured, and held 52
  # cases, not 56, immediately before #270 added four CRLF fixtures to it). M25 (below) was also
  # added by the #270 round-2 kickback, probing this file for the same trailing-vs-once-only gap
  # the push table's M24/M25 close for hooks/push-guard.sh — see M25's own entry for why no
  # fixture here closes it (a boundary interior-CR fixture is not added: not required unless
  # judged necessary to make a table sentence true, and none currently claims that coverage).
  # M1-M25 (this section) were NOT re-run for #268 — that issue added twenty push-* fixtures
  # (below), growing the whole-file total from 143 to 163 and the push-filtered unit from 60 to
  # 80; the #268 round-2 kickback then added three more push-* fixtures, growing the whole-file
  # total to 166 and the push-filtered unit to 83; the #268 round-3 kickback then added one more
  # push-* fixture, growing the whole-file total to 167 and the push-filtered unit to 84; #269
  # (below) then added twelve more push-* fixtures, growing the whole-file total to 179 and the
  # push-filtered unit to 96; the #269 round-2 kickback then added two more push-* fixtures,
  # growing the whole-file total to 181 and the push-filtered unit to 98; #290 then added sixteen
  # more push-* fixtures, growing the whole-file total to 197 and the push-filtered unit to 114;
  # the #290 ROUND-2 KICKBACK then added two more push-* fixtures, growing the whole-file total to
  # 199 and the push-filtered unit to 116 — none of the seven rounds touched
  # agent-boundary.sh vocabulary or behaviour, so none of this section's own historical
  # "143-case"/"140 pass"/"143 pass" figures were re-measured. #327 then added 29 cdg-* fixtures
  # (none containing the substring "push"), growing the whole-file total to 228; the #327 round-1
  # kickback then added two more cdg-* fixtures (also push-free), growing the whole-file total to
  # the then-current 230 while leaving the push-filtered unit at 116 — see hooks/claude-dir-guard.sh's
  # own header for the fourth hook's own paragraph, and the cdg-* section's own mutation-proof
  # table further below for its 14 mutants.
  # M1/M2 (the two raw-stdin fast paths) are
  # coarse — breaking either silences the WHOLE hook, so they only distinguish a deny-verdict
  # case from everything else, never one deny case from another:
  #   M1  fast path 1 pattern corrupted (*agent_type* -> *agentXtype*)      -> 55 pass, 27 fail
  #   M2  fast path 2 pattern corrupted (*git*|*gh* -> *gitX*|*ghX*)        -> 55 pass, 27 fail
  #       (M1 and M2 fail the identical 27-case set: every impl-deny-*/verif-deny-* case plus
  #       boundary-never-executes-deny — i.e. every case whose correct verdict is "deny", from
  #       the round-1 82-case set; the round-2 chained-prefix cases were not yet added.)
  #   M3  the .tool_name == "Bash" check disabled                          -> 81 pass,  1 fail
  #   M4  AGENT_TYPES_IMPLEMENTER's bare spelling renamed (-> implementerX) -> 69 pass, 13 fail
  #   M5  AGENT_TYPES_VERIFIER's bare spelling renamed (-> verifierX)      -> 71 pass, 11 fail
  #   M6  the permission_mode == "plan" check disabled                     -> 81 pass,  1 fail
  #   M7  the PREFIX_WORDS membership skip disabled                        -> 80 pass,  2 fail
  #   M8  the assignment-prefix regex made unmatchable                     -> 81 pass,  1 fail
  #   M9  normalize()'s basename-after-last-/ step removed                 -> 81 pass,  1 fail
  #   M10 normalize()'s double-quote strip disabled                        -> 81 pass,  1 fail
  #   M11 the "-C" skip-with-its-argument step disabled                    -> 81 pass,  1 fail
  #   M12 the "-globalopt-" sentinel replaced with skip-and-keep-scanning  -> 81 pass,  1 fail
  #   M13 "log" dropped from VERIFIER_GIT_READONLY                         -> 80 pass,  2 fail
  #   M13b "status" dropped from VERIFIER_GIT_READONLY                     -> 80 pass,  2 fail
  #   M13c "diff" dropped from VERIFIER_GIT_READONLY                       -> 81 pass,  1 fail
  #   M13d "restore" dropped from VERIFIER_GIT_READONLY                    -> 81 pass,  1 fail
  #   M13e "show" dropped from VERIFIER_GIT_READONLY                       -> 81 pass,  1 fail
  #   M14 implementer's deny branch gated on an unmatchable role string    -> 81 pass,  1 fail
  #   M15 the resolved-role empty-guard ([ -n "$role" ] || exit 0) removed -> 80 pass,  2 fail
  #   (M16, M17, M19 were retired during drafting — no mutant was ever run under those numbers;
  #   left unused rather than renumbered, so every table row's M-number always matches the
  #   case-row citation that names it.)
  #   M18 tool_input.command's jq default changed from empty to "git push" -> 81 pass,  1 fail
  #   M20 the awk cmdword=="git" exact match widened to a substring test   -> 81 pass,  1 fail
  #   M21 command-position broken: a later exact "git"/"gh" token in the   -> 81 pass,  1 fail
  #       same segment overrides an already-resolved, non-git command word
  #   M22 "-C" exact match widened to also match lowercase "-c"            -> 81 pass,  1 fail
  #   M23 hooks/agent-boundary.sh:167's saw_prefix once-only guard restored -> 82 pass,  2 fail
  #       (!saw_prefix && (norm in prefix_set)), so only the FIRST recognised PREFIX_WORDS token
  #       in a segment is skipped instead of every one — measured against the then-current
  #       49-case/84-total addition (#235 round 2); not re-run for #270 (the two new
  #       chained-prefix fixtures were the only cases that flipped then)
  #   M24 the two #270 CR-strip lines deleted (cr=$'\r'; cmd="${cmd//$cr/}") -> 140 pass,  3 fail
  #       (whole-file convention, measured against the then-current 143-case file — the three new
  #       #270 boundary CRLF fixtures, impl-deny-crlf-cmdword/verif-deny-crlf-gh/
  #       verif-noop-crlf-status, are the only cases that flip; NOT re-measured against the
  #       167-case file that stood after #268 (round 1), its round-2 kickback, or its round-3
  #       kickback (grown to 181 by #269 below and its own round-2 kickback, then to 197 by #290,
  #       then to 199 by #290's own round-2 kickback, then to the then-current 230 by #327's cdg-*
  #       section and its round-1 kickback, none of which touched agent-boundary.sh either) — see
  #       this section's header note above)
  #   M25 the shipped global strip narrowed to once-only                    -> 143 pass,  0 fail
  #       (cmd="${cmd//$cr/}" -> cmd="${cmd/$cr/}"; #270 round-2 kickback probe, whole-file
  #       convention) -- NOT flipped by any fixture in this file: each of the three #270
  #       boundary CRLF fixtures carries exactly one CR, so removing "the first" is identical
  #       to removing "every" for all three — a real gap in this table's own coverage (the push
  #       table's analogous M24/M25 close the same gap for hooks/push-guard.sh because
  #       push-deny-crlf-interior carries a second, non-edge CR that none of these three
  #       boundary fixtures do); left open here rather than papered over, since adding a
  #       boundary interior-CR fixture is not required unless judged necessary to make a table
  #       sentence true, and no sentence in this table claims this coverage
  # Six fixtures (impl-noop-npm-test/pytest/selfcheck, role-noop-no-agent-type,
  # role-noop-agent-id-only, and role-noop-malformed-json) are, verified by direct measurement,
  # NOT flipped by any of M1-M25: their raw JSON never contains the literal substring their
  # governing fast path requires (fast path 1's `agent_type` for the two role-agnostic fixtures,
  # fast path 2's `git`/`gh` for the three implementer no-opinion commands), or — for the
  # malformed-JSON fixture — jq's own parse failure independently yields an empty extraction no
  # matter which downstream check is broken. Widening either fast path's pattern to let them
  # through (checked directly, not merely inferred) still leaves them correctly "no opinion",
  # because the checks below re-derive the identical answer from the same absent/unparseable
  # data — the redundancy the header's fast-path comment describes (semantics-preserving except
  # for a command word split by quote/backslash characters, which none of these six fixtures'
  # commands are) is holding for them, not a coverage gap. Their comment below says so instead of
  # citing a mutant that was never observed to fail them.
  # #327: the cdg-* section further below runs ONLY hooks/claude-dir-guard.sh, via its own
  # run_claude_guard — no mutant M1-M25 in THIS table edits that file, so this table's recorded
  # failing sets are unchanged by that addition, and its whole-file PASS figures above all predate
  # it. Made non-vacuous, not just reasoned by inspection (LESSON 2026-09-15): M1 (fast path 1
  # pattern corrupted) re-run against the then-current 230-case file (re-measured after the #327
  # round-1 kickback's two new cdg-* fixtures) still fails exactly its own 31-case set (199 pass,
  # 31 fail) with NO cdg-* case among them.
  "impl-deny-push-bare|case_ib_push_bare|implementer deny: git push (agent_type: implementer) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-push-ns|case_ib_push_ns|implementer deny: git push (agent_type: trail-blazer-flow:implementer) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-gh-pr-bare|case_ib_gh_pr_bare|implementer deny: gh pr create (agent_type: implementer) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-gh-pr-ns|case_ib_gh_pr_ns|implementer deny: gh pr create (agent_type: trail-blazer-flow:implementer) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-gh-issue-edit|case_ib_gh_issue_edit|implementer deny: gh issue edit --add-label plan-approved -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-git-c-push|case_ib_git_c_push|implementer deny: git -C <worktree> push (the form git-c-guard.sh's own allow cases approve) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-composite-and|case_ib_composite_and|implementer deny: pytest && git push (second segment) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-assignment|case_ib_assignment|implementer deny: FOO=1 git push (assignment-prefix skip) -- measured: M8, 81 pass 1 fail"
  "impl-deny-command-prefix|case_ib_command_prefix|implementer deny: command git push (PREFIX_WORDS skip) -- measured: M7, 80 pass 2 fail (with impl-deny-bash-c)"
  "impl-deny-abs-path|case_ib_abs_path|implementer deny: /usr/bin/git push (basename normalisation) -- measured: M9, 81 pass 1 fail"
  "impl-deny-bash-c|case_ib_bash_c|implementer deny: bash -c \"git push\" (PREFIX_WORDS + quote-strip) -- measured: M10, 81 pass 1 fail (also M7, 80 pass 2 fail, with impl-deny-command-prefix)"
  "impl-deny-semicolon|case_ib_semicolon|implementer deny: echo hi; gh pr create (second segment) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-subshell|case_ib_subshell|implementer deny: (cd x && git push) (paren segment breaks) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-readonly-subcommand|case_ib_readonly_subcommand|implementer deny: git status --porcelain (implementer denies even a VERIFIER_GIT_READONLY subcommand -- isolates the role-policy split) -- measured: M14, 81 pass 1 fail"
  "impl-deny-chained-prefix|case_ib_chained_prefix|implementer deny: sudo bash -c \"git push\" (TWO chained PREFIX_WORDS tokens) -- measured: M23, 82 pass 2 fail (with verif-deny-chained-prefix)"
  "impl-deny-crlf-cmdword|case_ib_crlf_cmdword|implementer deny: git<CR> push (#270, CR on the command word -- the only place a CR evades this hook) -- measured: M24, 140 pass 3 fail (with verif-deny-crlf-gh and verif-noop-crlf-status)"
  "impl-noop-npm-test|case_in_npm_test|implementer no opinion: npm test -- measured: not flipped by M1-M24 (no git/gh substring anywhere in the raw stdin -- fast path 2 alone already excludes it; see the table header note above)"
  "impl-noop-pytest|case_in_pytest|implementer no opinion: pytest -q -- measured: not flipped by M1-M24 (same as impl-noop-npm-test)"
  "impl-noop-selfcheck|case_in_selfcheck|implementer no opinion: bash dev/selfcheck.sh -- measured: not flipped by M1-M24 (same as impl-noop-npm-test)"
  "impl-noop-grep-arg|case_in_grep_arg|implementer no opinion: grep -rn \"git push\" . (git as argument, not command word) -- measured: M21, 81 pass 1 fail"
  "impl-noop-git-c-guard-script|case_in_git_c_guard_script|implementer no opinion: bash hooks/git-c-guard.sh (basename contains, but isn't, \"git\") -- measured: M20, 81 pass 1 fail"
  "verif-noop-diff|case_vn_diff|verifier no opinion: git diff <default>...HEAD --stat -- measured: M13c, 81 pass 1 fail"
  "verif-noop-log|case_vn_log|verifier no opinion: git log <default>..HEAD --format=%s -- measured: M13, 80 pass 2 fail (with verif-noop-c-log)"
  "verif-noop-status|case_vn_status|verifier no opinion: git status --porcelain -- measured: M13b, 80 pass 2 fail (with boundary-never-executes-noop)"
  "verif-noop-restore|case_vn_restore|verifier no opinion: git restore <file> -- measured: M13d, 81 pass 1 fail"
  "verif-noop-c-log|case_vn_c_log|verifier no opinion: git -C <worktree> log <default>..HEAD --format=%s -- measured: M11, 81 pass 1 fail (also M13, 80 pass 2 fail, with verif-noop-log)"
  "verif-noop-show-ns|case_vn_show_ns|verifier no opinion: git show HEAD (agent_type: trail-blazer-flow:verifier) -- measured: M13e, 81 pass 1 fail"
  "verif-noop-crlf-status|case_vn_crlf_status|verifier no opinion: git status<CR> (#270 -- pre-fix this DENIES, fail-closed; the only new case whose pre-fix failure is a deny, proving the fix is not a blanket widening) -- measured: M24, 140 pass 3 fail (with impl-deny-crlf-cmdword and verif-deny-crlf-gh)"
  "verif-deny-commit|case_vd_commit|verifier deny: git commit -m x -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-stash|case_vd_stash|verifier deny: git stash -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-checkout|case_vd_checkout|verifier deny: git checkout -- <file> -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-gh-comment-bare|case_vd_gh_comment_bare|verifier deny: gh issue comment (agent_type: verifier) -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-gh-comment-ns|case_vd_gh_comment_ns|verifier deny: gh issue comment (agent_type: trail-blazer-flow:verifier) -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-inject-config|case_vd_inject_config|verifier deny: git -c core.pager=cat log (unrecognised global option -> -globalopt-) -- measured: M22, 81 pass 1 fail"
  "verif-deny-no-pager-log|case_vd_no_pager_log|verifier deny: git --no-pager log (no-argument global option before a genuinely readonly subcommand -- isolates the -globalopt- sentinel) -- measured: M12, 81 pass 1 fail"
  "verif-deny-git-dir|case_vd_git_dir|verifier deny: git --git-dir=... push (unrecognised global option -> -globalopt-) -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-c-commit|case_vd_c_commit|verifier deny: git -C <worktree> commit -m x -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-clean|case_vd_clean|verifier deny: git clean -fd (unlisted subcommand, fail-closed) -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-bare-git|case_vd_bare_git|verifier deny: bare git (-none-, fail-closed) -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-composite|case_vd_composite|verifier deny: pytest && git commit -m x (second segment) -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-chained-prefix|case_vd_chained_prefix|verifier deny: env sudo git commit -m x (TWO chained PREFIX_WORDS tokens) -- measured: M23, 82 pass 2 fail (with impl-deny-chained-prefix)"
  "verif-deny-crlf-gh|case_vd_crlf_gh|verifier deny: gh<CR> issue comment 1 -b x (#270, the gh branch's exact command-word compare) -- measured: M24, 140 pass 3 fail (with impl-deny-crlf-cmdword and verif-noop-crlf-status)"
  "role-noop-no-agent-type|case_ra_no_agent_type_key|role-agnostic no opinion: no agent_type key at all (main session), git push -- measured: not flipped by M1-M24 (no 'agent_type' substring anywhere in the raw stdin -- fast path 1 alone already excludes it, and independently the jq .agent_type extraction below would also come back empty; see the table header note above)"
  "role-noop-explore|case_ra_explore|role-agnostic no opinion: agent_type is \"Explore\" (unrecognised role) -- measured: M15 ([ -n \"\$role\" ] || exit 0 removed), 80 pass 2 fail (with role-noop-empty-agent-type)"
  "role-noop-empty-agent-type|case_ra_empty_agent_type|role-agnostic no opinion: agent_type is the empty string -- measured: M15, 80 pass 2 fail (with role-noop-explore)"
  "role-noop-agent-id-only|case_ra_agent_id_only|role-agnostic no opinion: agent_id present, no agent_type key -- measured: not flipped by M1-M24 (same reason as role-noop-no-agent-type -- 'agent_id' does not contain the substring 'agent_type')"
  "role-noop-plan-mode|case_ra_plan_mode|role-agnostic no opinion: implementer git push under permission_mode: \"plan\" -- measured: M6, 81 pass 1 fail"
  "role-noop-wrong-tool|case_ra_wrong_tool|role-agnostic no opinion: tool_name is \"Read\", not \"Bash\" -- measured: M3, 81 pass 1 fail"
  "role-noop-malformed-json|case_ra_malformed_json|role-agnostic no opinion: unparseable stdin (carries both agent_type and git substrings) -- measured: not flipped by M1-M24, including M3 (jq's own parse failure independently yields an empty .tool_name/.agent_type extraction regardless of which downstream check runs)"
  "role-noop-missing-command|case_ra_missing_command|role-agnostic no opinion: tool_input.command absent -- measured: M18, 81 pass 1 fail"
  "boundary-never-executes-deny|case_boundary_never_executes_deny|deny, AND the boundary never invokes git/gh/rm on the booby-trapped PATH — sentinel absent -- measured: M1/M2, 55 pass 27 fail"
  "boundary-never-executes-noop|case_boundary_never_executes_noop|no opinion, AND the boundary never invokes git/gh/rm on the booby-trapped PATH — sentinel absent -- measured: M13b, 80 pass 2 fail (with verif-noop-status)"
  # --- hooks/agent-boundary.sh: the #340 `.claude` Bash-write deny class -----------------------
  "ab-claude-deny-append-redirect|case_ab_claude_deny_append_redirect|.claude deny: implementer, printf appended via >> .claude/LESSONS.md (the exact shape the issue names) -- mutation proof: dev/mutants/hook-tests.json (340-fastpath)"
  "ab-claude-deny-redirect-nospace-quoted|case_ab_claude_deny_redirect_nospace_quoted|.claude deny: verifier, echo x >\"...\" (no space after >, quoted, absolute path) -- mutation proof: dev/mutants/hook-tests.json (340-fastpath)"
  "ab-claude-deny-heredoc|case_ab_claude_deny_heredoc|.claude deny: implementer, a multi-line heredoc whose first line redirects into .claude/LESSONS.md -- mutation proof: dev/mutants/hook-tests.json (340-fastpath)"
  "ab-claude-deny-case-variant|case_ab_claude_deny_case_variant|.claude deny: implementer, echo x >> .Claude/LESSONS.md (case-variant segment) -- mutation proof: dev/mutants/hook-tests.json (340-fastpath-case, 340-tolower)"
  "ab-claude-deny-backslash|case_ab_claude_deny_backslash|.claude deny: implementer, echo x >> 'C:\\repo\\.claude\\LESSONS.md' (backslash-separated path) -- mutation proof: dev/mutants/hook-tests.json (340-backslash)"
  "ab-claude-deny-tee|case_ab_claude_deny_tee|.claude deny: trail-blazer-flow:verifier, cat notes.txt piped into tee -a .claude/LESSONS.md (the vocabulary walk, not a redirect target) -- mutation proof: dev/mutants/hook-tests.json (340-arg-vocab)"
  "ab-claude-deny-cp|case_ab_claude_deny_cp|.claude deny: implementer, cp /tmp/lesson.md .claude/LESSONS.md (a plain-argument write, not a redirect) -- mutation proof: dev/mutants/hook-tests.json (340-arg-vocab)"
  "ab-claude-deny-cd|case_ab_claude_deny_cd|.claude deny: trail-blazer-flow:implementer, cd .claude && cat /tmp/l >> LESSONS.md (cd defeats the redirect target check on its own; the arg-vocab walk catches it instead) -- mutation proof: dev/mutants/hook-tests.json (340-arg-vocab)"
  "ab-claude-deny-sed-short|case_ab_claude_deny_sed_short|.claude deny: implementer, sed -i.bak '\$a x' .claude/LESSONS.md (short in-place flag) -- mutation proof: dev/mutants/hook-tests.json (340-sed-short)"
  "ab-claude-deny-sed-long|case_ab_claude_deny_sed_long|.claude deny: verifier, sed --in-place '\$a x' .claude/LESSONS.md (long in-place flag) -- mutation proof: dev/mutants/hook-tests.json (340-sed-long)"
  "ab-claude-deny-quoted-double|case_ab_claude_deny_quoted_double|.claude deny: implementer, echo x >> \".claude/LESSONS.md\" (a double quote directly adjacent to the segment) -- mutation proof: dev/mutants/hook-tests.json (340-quote-strip-dq)"
  "ab-claude-deny-quoted-single|case_ab_claude_deny_quoted_single|.claude deny: verifier, tee -a '.claude/LESSONS.md' (a single quote directly adjacent to the segment, via the vocabulary walk) -- mutation proof: dev/mutants/hook-tests.json (340-quote-strip-sq)"
  "ab-claude-deny-sed-combined|case_ab_claude_deny_sed_combined|.claude deny: implementer, sed -Ei (in-place flag combined with another short flag) -- mutation proof: dev/mutants/hook-tests.json (340-sed-combined)"
  "ab-claude-deny-never-writes|case_ab_claude_deny_never_writes|.claude deny, AND the boundary never invokes git/gh/rm on the booby-trapped PATH, AND the redirect target file is never actually created — sentinel absent, target file absent -- mutation proof: dev/mutants/hook-tests.json (340-policy-arm)"
  "ab-claude-noop-input-redirect|case_ab_claude_noop_input_redirect|.claude no opinion: implementer, wc -l < .claude/LESSONS.md (an input redirect, never a write position) -- mutation proof: dev/mutants/hook-tests.json (340-input-redirect)"
  "ab-claude-noop-tee-elsewhere|case_ab_claude_noop_tee_elsewhere|.claude no opinion: implementer, cat .claude/LESSONS.md piped into tee /tmp/out.txt (the READ is under .claude, tee's own target isn't) -- mutation proof: dev/mutants/hook-tests.json (340-arg-gate)"
  "ab-claude-noop-sed-no-inplace|case_ab_claude_noop_sed_no_inplace|.claude no opinion: verifier, sed -n '1,5p' .claude/LESSONS.md (no in-place flag) -- mutation proof: dev/mutants/hook-tests.json (340-inplace-gate)"
  "ab-claude-noop-near-miss|case_ab_claude_noop_near_miss|.claude no opinion: implementer, echo x >> .claude-backup/notes.md (a near-miss segment, not an exact .claude match) -- mutation proof: dev/mutants/hook-tests.json (340-segment-exact)"
  "ab-claude-noop-main-session|case_ab_claude_noop_main_session|.claude no opinion: main session (no agent_type key), echo x >> .claude/LESSONS.md (blocking this would stop a release -- the orchestrator's own lesson append) -- release-blocker control, not part of the mutation-proof registry"
  # --- hooks/agent-boundary.sh: the #387 .claude command-level interpreter/writer class -----------
  "ab-cwrite-deny-python-c|case_ab_cwrite_deny_python_c|.claude command-level deny: implementer, python3 -c \"open('.claude/LESSONS.md','a').write('- lesson')\" (the issue's exact shape) -- mutation proof: dev/mutants/hook-tests.json (387-vocab-empty)"
  "ab-cwrite-deny-python-heredoc|case_ab_cwrite_deny_python_heredoc|.claude command-level deny: trail-blazer-flow:implementer, a heredoc whose command word (python3) and .claude mention are on DIFFERENT lines -- mutation proof: dev/mutants/hook-tests.json (387-cross-line)"
  "ab-cwrite-deny-perl-i|case_ab_cwrite_deny_perl_i|.claude command-level deny: verifier, perl -i.bak -pe 's/a/b/' .claude/LESSONS.md -- mutation proof: dev/mutants/hook-tests.json (387-vocab-empty)"
  "ab-cwrite-deny-dd|case_ab_cwrite_deny_dd|.claude command-level deny: implementer, dd if=/tmp/lesson.md of=.claude/LESSONS.md (segment bounded by =) -- mutation proof: dev/mutants/hook-tests.json (387-vocab-empty)"
  "ab-cwrite-deny-install|case_ab_cwrite_deny_install|.claude command-level deny: trail-blazer-flow:verifier, install -m 644 /tmp/lesson.md .claude/LESSONS.md -- mutation proof: dev/mutants/hook-tests.json (387-vocab-empty)"
  "ab-cwrite-deny-versioned-abs|case_ab_cwrite_deny_versioned_abs|.claude command-level deny: implementer, /usr/local/bin/python3.12 -c \"open('.claude/LESSONS.md','a')\" (versioned basename after path stripping) -- mutation proof: dev/mutants/hook-tests.json (387-version-strip)"
  "ab-cwrite-deny-case-variant|case_ab_cwrite_deny_case_variant|.claude command-level deny: implementer, install -m 644 /tmp/lesson.md .Claude/LESSONS.md (case-variant segment) -- mutation proof: dev/mutants/hook-tests.json (387-tolower)"
  "ab-cwrite-deny-never-writes|case_ab_cwrite_deny_never_writes|.claude command-level deny, AND the boundary never invokes git/gh/rm on the booby-trapped PATH, AND the target file is never actually created -- sentinel absent, target file absent -- mutation proof: dev/mutants/hook-tests.json (387-vocab-empty)"
  "ab-cwrite-noop-reader|case_ab_cwrite_noop_reader|.claude command-level no opinion: implementer, npm install && grep -n lesson .claude/LESSONS.md && cat .claude/BASELINE.md (install appears only as an argument, never a command word) -- mutation proof: dev/mutants/hook-tests.json (387-word-gate)"
  "ab-cwrite-noop-no-claude-seg|case_ab_cwrite_noop_no_claude_seg|.claude command-level no opinion: implementer, python3 -m pytest tests/test_claude_client.py (a vocabulary command word, no .claude segment anywhere) -- mutation proof: dev/mutants/hook-tests.json (387-tok-gate)"
  "ab-cwrite-noop-claude-plugin|case_ab_cwrite_noop_claude_plugin|.claude command-level no opinion: verifier, python3 -c \"import json; json.load(open('.claude-plugin/plugin.json'))\" (trailing-boundary near-miss) -- mutation proof: dev/mutants/hook-tests.json (387-boundary-trail)"
  "ab-cwrite-noop-my-claude|case_ab_cwrite_noop_my_claude|.claude command-level no opinion: implementer, touch build/my.claude (leading-boundary near-miss) -- mutation proof: dev/mutants/hook-tests.json (387-boundary-lead)"
  "ab-cwrite-noop-main-session|case_ab_cwrite_noop_main_session|.claude command-level no opinion: main session (no agent_type key), the D1 command (blocking this would stop a release -- the orchestrator's own lesson append) -- release-blocker control, not part of the mutation-proof registry"
  "ab-kw-deny-if-then|case_ab_kw_deny_if_then|shell-keyword deny: implementer, if true; then git push; fi (the issue's own shape) -- mutation proof: dev/mutants/hook-tests.json (398-ab-kw-vocab)"
  "ab-kw-deny-bang-gh|case_ab_kw_deny_bang_gh|shell-keyword deny: trail-blazer-flow:implementer, ! gh issue close 5 -- mutation proof: dev/mutants/hook-tests.json (398-ab-kw-vocab)"
  "ab-kw-deny-while-do|case_ab_kw_deny_while_do|shell-keyword deny: implementer, while true; do git push; done -- mutation proof: dev/mutants/hook-tests.json (398-ab-kw-vocab)"
  "ab-kw-deny-while-cond|case_ab_kw_deny_while_cond|shell-keyword deny: implementer, while git push; do break; done ('while' itself, not 'do') -- mutation proof: dev/mutants/hook-tests.json (398-ab-kw-vocab)"
  "ab-kw-deny-until|case_ab_kw_deny_until|shell-keyword deny: trail-blazer-flow:implementer, until git push; do sleep 1; done -- mutation proof: dev/mutants/hook-tests.json (398-ab-kw-vocab)"
  "ab-kw-deny-if-cond|case_ab_kw_deny_if_cond|shell-keyword deny: implementer, if gh pr list; then echo x; fi (keyword in the condition, not the body) -- mutation proof: dev/mutants/hook-tests.json (398-ab-kw-vocab)"
  "ab-kw-deny-else|case_ab_kw_deny_else|shell-keyword deny: implementer, if false; then :; else git push; fi -- mutation proof: dev/mutants/hook-tests.json (398-ab-kw-vocab)"
  "ab-kw-deny-elif|case_ab_kw_deny_elif|shell-keyword deny: trail-blazer-flow:implementer, if false; then :; elif git push; then :; fi -- mutation proof: dev/mutants/hook-tests.json (398-ab-kw-vocab)"
  "ab-kw-deny-coproc|case_ab_kw_deny_coproc|shell-keyword deny: implementer, coproc git push -- mutation proof: dev/mutants/hook-tests.json (398-ab-kw-vocab)"
  "ab-kw-deny-chained|case_ab_kw_deny_chained|shell-keyword deny: implementer, if ! git push; then :; fi (two chained keywords, the 0/1/2+ prefix-skip boundary) -- mutation proof: dev/mutants/hook-tests.json (398-ab-kw-vocab)"
  "ab-kw-deny-verifier-then|case_ab_kw_deny_verifier_then|shell-keyword deny: verifier, if true; then git push; fi -- mutation proof: dev/mutants/hook-tests.json (398-ab-kw-vocab)"
  "ab-kw-deny-verifier-bang|case_ab_kw_deny_verifier_bang|shell-keyword deny: trail-blazer-flow:verifier, ! gh issue close 5 -- mutation proof: dev/mutants/hook-tests.json (398-ab-kw-vocab)"
  "ab-kw-deny-upper-git|case_ab_kw_deny_upper_git|case-fold deny: implementer, GIT push -- mutation proof: dev/mutants/hook-tests.json (398-ab-case-fold, 398-ab-fastpath-case)"
  "ab-kw-deny-mixed-gh|case_ab_kw_deny_mixed_gh|case-fold deny: verifier, Gh issue close 5 -- mutation proof: dev/mutants/hook-tests.json (398-ab-case-fold, 398-ab-fastpath-case)"
  "ab-kw-deny-upper-abs|case_ab_kw_deny_upper_abs|case-fold deny: implementer, /usr/bin/GIT push (case fold after basename normalisation) -- mutation proof: dev/mutants/hook-tests.json (398-ab-case-fold, 398-ab-fastpath-case)"
  "ab-kw-deny-upper-prefix|case_ab_kw_deny_upper_prefix|case-fold deny: implementer, ENV git push (tolower runs before the prefix-word match too) -- mutation proof: dev/mutants/hook-tests.json (398-ab-case-fold)"
  "ab-kw-deny-upper-python|case_ab_kw_deny_upper_python|case-fold deny: implementer, PYTHON3 -c \"open('.claude/LESSONS.md','a')\" (the #387 command-level rule via a case-folded command word) -- mutation proof: dev/mutants/hook-tests.json (398-ab-case-fold)"
  "ab-kw-deny-upper-tee|case_ab_kw_deny_upper_tee|case-fold deny: implementer, echo x \| TEE -a .claude/LESSONS.md (the arg-vocabulary path via a case-folded command word) -- mutation proof: dev/mutants/hook-tests.json (398-ab-case-fold)"
  "ab-kw-deny-upper-touch|case_ab_kw_deny_upper_touch|case-fold deny: trail-blazer-flow:implementer, Touch .claude/LESSONS.md -- mutation proof: dev/mutants/hook-tests.json (398-ab-case-fold)"
  "ab-kw-deny-kw-python|case_ab_kw_deny_kw_python|shell-keyword + case fold combined: implementer, if true; then PYTHON3 -c \"open('.claude/LESSONS.md','a')\"; fi -- mutation proof: dev/mutants/hook-tests.json (398-ab-kw-vocab, 398-ab-case-fold)"
  "ab-kw-deny-verifier-upper-sub|case_ab_kw_deny_verifier_upper_sub|case-variant git subcommand: verifier, git STATUS denies (subcommand never case-folded) -- mutation proof: dev/mutants/hook-tests.json (398-ab-gitsub-exact)"
  "ab-kw-noop-keyword-arg|case_ab_kw_noop_keyword_arg|shell-keyword no opinion: implementer, echo then git push (the skip applies only in command position; the raw stdin still contains \"git\") -- control, not part of the mutation-proof registry"
  "ab-kw-noop-verifier-if-diff|case_ab_kw_noop_verifier_if_diff|shell-keyword no opinion: verifier, if git diff --quiet; then echo same; fi (release-blocker control: the keyword skip must not widen the verifier's read-only git allowance) -- control, not part of the mutation-proof registry"
  "ab-pc-deny-eval-git|case_ab_pc_deny_eval_git|eval deny: implementer, eval git push -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-vocab)"
  "ab-pc-deny-eval-quoted-gh|case_ab_pc_deny_eval_quoted_gh|eval-quoted deny: trail-blazer-flow:implementer, eval \"gh issue close 5\" (the issue's own shape) -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-vocab)"
  "ab-pc-deny-eval-lead-space|case_ab_pc_deny_eval_lead_space|eval-quoted deny with a leading space: implementer, eval \" gh issue close 5\" -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-vocab, 403-ab-pc-empty-tok)"
  "ab-pc-deny-trap-gh|case_ab_pc_deny_trap_gh|trap deny: implementer, trap 'gh issue close 5' EXIT -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-vocab)"
  "ab-pc-deny-noglob|case_ab_pc_deny_noglob|zsh precommand modifier deny: implementer, noglob git push -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-vocab)"
  "ab-pc-deny-nocorrect|case_ab_pc_deny_nocorrect|zsh precommand modifier deny: implementer, nocorrect gh pr merge 5 -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-vocab)"
  "ab-pc-deny-dash|case_ab_pc_deny_dash|zsh precommand modifier deny: implementer, - git push -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-vocab)"
  "ab-pc-deny-repeat|case_ab_pc_deny_repeat|zsh repeat deny: implementer, repeat 3 git push -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-vocab, 403-ab-pc-repeat)"
  "ab-pc-deny-short-if|case_ab_pc_deny_short_if|zsh short-if deny: implementer, if [[ 1 ]] git push -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-dbracket)"
  "ab-pc-deny-short-if-and|case_ab_pc_deny_short_if_and|zsh short-if deny with an && condition: implementer, if [[ -n a && -n b ]] gh issue close 5 (the && inside the condition cannot hide the tail) -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-dbracket)"
  "ab-pc-deny-verifier-eval|case_ab_pc_deny_verifier_eval|eval deny: verifier, eval git push -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-vocab)"
  "ab-pc-noop-verifier-eval-status|case_ab_pc_noop_verifier_eval_status|eval no opinion: verifier, eval git status (release-blocker control: the new skip must not narrow the verifier's read-only git) -- control, not part of the mutation-proof registry"
  "ab-pc-noop-bash-dbracket|case_ab_pc_noop_bash_dbracket|ordinary bash no opinion: implementer, [[ -n x ]] && echo git (not zsh's short-if form) -- control, not part of the mutation-proof registry"
  "ab-pc-deny-dbracket-tee-claude|case_ab_pc_deny_dbracket_tee_claude|additive-]] regression proof: implementer, tee ]] .claude/LESSONS.md -- the pre-existing arg-vocab deny must survive the ]] pass -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-dbracket-truncate)"
  "ab-pc-deny-dbracket-multiline|case_ab_pc_deny_dbracket_multiline|additive-]] boundary: implementer, if [[ -n a<LF>]] git push (]] opens the second physical line) -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-dbracket, 403-ab-pc-dbracket-nopad)"
  "ab-pc-deny-dbracket-tab|case_ab_pc_deny_dbracket_tab|additive-]] boundary: implementer, if [[ 1 ]]<TAB>git push (]] bounded by a tab, not a space) -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-dbracket, 403-ab-pc-dbracket-spaceonly)"
  "ab-pc-deny-dbracket-second|case_ab_pc_deny_dbracket_second|additive-]] second-match proof: implementer, if [[ 1 ]] true; if [[ 1 ]] git push (the deciding ]] is the second one) -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-dbracket-once)"
  "ab-pc-deny-dbracket-second-gh|case_ab_pc_deny_dbracket_second_gh|additive-]] second-match proof: implementer, if [[ 1 ]] true; if [[ 1 ]] gh issue close 5 -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-dbracket-once)"
  "ab-pc-deny-dbracket-flood|case_ab_pc_deny_dbracket_flood|verdict-only proof: implementer, echo + 70x ]] + ; git push (deny via the untouched main split, unaffected by the cap or by tail-cutting) -- control, not part of the mutation-proof registry"
  "ab-pc-deny-dbracket-cap|case_ab_pc_deny_dbracket_cap|additive-]] cap proof: implementer, echo + 65x ]] with no git/gh at all -- only the DBRACKET_MAX fail-closed sentinel can deny this record -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-dbracket-cap)"
  "ab-pc-deny-dbracket-disjoint|case_ab_pc_deny_dbracket_disjoint|disjoint-tail proof: implementer, if [[ 1 ]] tee ]] .claude/LESSONS.md -- a tee cut short by the SECOND ]] fails closed on its own distinct reason -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-dbracket-overlap)"
  "ab-pc-deny-dbracket-timing|case_ab_pc_deny_dbracket_timing|wall-clock proof: implementer, a tee/]] flood sized per-awk by ab_pc_dbracket_timing_filler -- deny under a deadline calibrated (#470) from a same-run, same-length, single-]] control measurement (a floor, else a multiple of the control) -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-dbracket-overlap, 463-hook-boundary-override-leaks)"
  "ab-pc-deny-dbracket-sed-cut|case_ab_pc_deny_dbracket_sed_cut|cut-sed proof: verifier, x ]] sed s/a/b/ ]] y; git diff -- a non-in-place sed cut short by the SECOND ]] fails closed -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-dbracket-sed-noninplace)"
  "ab-pc-deny-dbracket-sed-inplace-cut|case_ab_pc_deny_dbracket_sed_inplace_cut|cut-sed proof: verifier, x ]] sed -i s/a/b/ ]] y; git diff -- an in-place sed cut short by the SECOND ]] fails closed -- mutation proof: dev/mutants/hook-tests.json (403-ab-pc-dbracket-sed-inplace)"
  "ab-rtexp-deny-impl-gh|case_ab_rtexp_deny_impl_gh|\$X gh pr merge 5 denies for the implementer -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-skip-off, 508-ab-rx-re-zsh)"
  "ab-rtexp-deny-impl-git|case_ab_rtexp_deny_impl_git|\$X git push / \$X git commit deny for the implementer as git -expansion- -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-skip-off, 508-ab-rx-git-sentinel)"
  "ab-rtexp-deny-option-word-gh|case_ab_rtexp_deny_option_word_gh|\$X -rf gh pr merge 5 denies: the skipped expansion is a prefix word -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-skip-off, 508-ab-rx-skip-no-prefix)"
  "ab-rtexp-deny-env-s-record-wide|case_ab_rtexp_deny_env_s_record_wide|the env -S check is record-wide for both roles -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-envs-off)"
  "ab-rtexp-deny-env-ansi-c-gh|case_ab_rtexp_deny_env_ansi_c_gh|env \$'A=b' gh pr merge 5 denies for the implementer -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-skip-off, 508-ab-rx-re-sq)"
  "ab-rtexp-deny-positional-gh|case_ab_rtexp_deny_positional_gh|\$1 gh pr merge 5 denies for the implementer -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-skip-off, 508-ab-rx-re-special)"
  "ab-rtexp-deny-verifier-git-status|case_ab_rtexp_deny_verifier_git_status|\$X git status denies for the verifier as git -expansion- -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-skip-off, 508-ab-rx-git-sentinel)"
  "ab-rtexp-deny-verifier-env-assign|case_ab_rtexp_deny_verifier_env_assign|env X=\$Y git status denies for the verifier -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-git-sentinel, 508-ab-rx-assign-prefix)"
  "ab-rtexp-deny-verifier-gh|case_ab_rtexp_deny_verifier_gh|\"\$X\" gh issue list denies for the verifier -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-skip-off)"
  "ab-rtexp-deny-claude-tee|case_ab_rtexp_deny_claude_tee|\$X tee -a .claude/LESSONS.md denies with the .claude reason -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-skip-off)"
  "ab-rtexp-deny-env-s-brace-gh|case_ab_rtexp_deny_env_s_brace_gh|env -S with a brace expansion naming gh denies -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-envs-off)"
  "ab-rtexp-deny-env-s-escaped-gh|case_ab_rtexp_deny_env_s_escaped_gh|env -S with an expansion and escaped separators naming gh denies -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-envs-off, 508-ab-rx-envs-unescape)"
  "ab-rtexp-deny-dir-expansion-gh|case_ab_rtexp_deny_dir_expansion_gh|\$X/usr/bin/gh still resolves by its basename -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-lone-dollar, 508-ab-rx-basename)"
  "ab-rtexp-deny-codex-impl-gh|case_ab_rtexp_deny_codex_impl_gh|a Codex-shaped implementer \$X gh pr merge 5 denies -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-skip-off)"
  "ab-rtexp-deny-verifier-git-slot|case_ab_rtexp_deny_verifier_git_slot|control: git \$X status already denies for the verifier -- control, not part of the mutation-proof registry"
  "ab-rtexp-noop-sudo-s|case_ab_rtexp_noop_sudo_s|no opinion: sudo -S with an expansion is not env -S -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-in-env-any)"
  "ab-rtexp-noop-prompt-dollar|case_ab_rtexp_noop_prompt_dollar|no opinion: a heredoc line starting with a lone dollar sign -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-lone-dollar)"
  "ab-rtexp-noop-env-s-no-names|case_ab_rtexp_noop_env_s_no_names|no opinion: env -S with an expansion that names neither git nor gh -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-envs-word)"
  "ab-rtexp-noop-verifier-bare-assign|case_ab_rtexp_noop_verifier_bare_assign|no opinion: a bare assignment with an expansion value before git status -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-bare-assign)"
  "ab-rtexp-noop-controls|case_ab_rtexp_noop_controls|no opinion: expansion text outside command position and the env PATH prefix shape -- control, not part of the mutation-proof registry"
  "ab-rtexpscan-noop-flood|case_ab_rtexpscan_noop_flood|FLOOD+TIMING: an env line of expansion-bearing -S options, no opinion; token count sized from a same-run, mutant-invariant twin control, deadline a multiple of the predicted linear cost -- mutation proof: dev/mutants/hook-tests.json (508-ab-rx-rescan)"
  "ab-lost-deny-env-u-gh|case_ab_lost_deny_env_u_gh|env -u/--unset consumes its value, so the next word is the command; gh denies -- mutation proof: dev/mutants/hook-tests.json (505-ab-env-u-consume)"
  "ab-lost-deny-env-u-git|case_ab_lost_deny_env_u_git|env -u X git commit denies for the implementer -- mutation proof: dev/mutants/hook-tests.json (505-ab-env-u-consume)"
  "ab-lost-deny-env-u-quoted|case_ab_lost_deny_env_u_quoted|an env -u value split at a space, detached or attached, still reaches gh -- mutation proof: dev/mutants/hook-tests.json (505-ab-env-u-attached-quote, 505-ab-env-u-value-check, 505-ab-unbalanced-dq)"
  "ab-lost-deny-env-opt|case_ab_lost_deny_env_opt|an env option outside the allowlist (-C) before gh denies, also after an additive ]] -- mutation proof: dev/mutants/hook-tests.json (505-ab-env-opt-off, 505-ab-scan-reset, 505-ab-unbalanced-dq, 505-ab-unbalanced-off)"
  "ab-lost-deny-env-split-string|case_ab_lost_deny_env_split_string|env -S and --split-string with a quoted string naming gh deny -- mutation proof: dev/mutants/hook-tests.json (505-ab-word-lead-off)"
  "ab-lost-deny-env-split-string-escaped|case_ab_lost_deny_env_split_string_escaped|env -S with backslash-underscore separators naming gh denies -- mutation proof: dev/mutants/hook-tests.json (505-ab-word-lead-off, 505-ab-word-unescape)"
  "ab-lost-deny-env-split-string-git|case_ab_lost_deny_env_split_string_git|env -S naming git denies as the fixed git -prefix- sentinel -- mutation proof: dev/mutants/hook-tests.json (505-ab-env-opt-off, 505-ab-git-sentinel, 505-ab-word-lead-off, 505-ab-word-lower, 505-ab-word-ungated)"
  "ab-lost-deny-assign-dquote|case_ab_lost_deny_assign_dquote|an assignment with a double-quoted value holding a space before gh denies -- mutation proof: dev/mutants/hook-tests.json (505-ab-unbalanced-dq, 505-ab-unbalanced-off, 505-ab-word-lower, 505-ab-word-strip-bs, 505-ab-word-strip-dq, 505-ab-word-strip-sq)"
  "ab-lost-deny-assign-squote|case_ab_lost_deny_assign_squote|an assignment with a single-quoted or ANSI-C value holding a space before gh denies -- mutation proof: dev/mutants/hook-tests.json (505-ab-unbalanced-off, 505-ab-unbalanced-sq)"
  "ab-lost-deny-assign-backslash|case_ab_lost_deny_assign_backslash|an assignment with a backslash-escaped space before gh denies -- mutation proof: dev/mutants/hook-tests.json (505-ab-unbalanced-bs, 505-ab-unbalanced-off)"
  "ab-lost-deny-prefix-quoted|case_ab_lost_deny_prefix_quoted|a quoted assignment or option after a prefix word before gh denies -- mutation proof: dev/mutants/hook-tests.json (505-ab-prefix-quoted-shape, 505-ab-word-lead-off)"
  "ab-lost-deny-prefix-squoted-opt|case_ab_lost_deny_prefix_squoted_opt|a single-quoted env option before gh denies -- mutation proof: dev/mutants/hook-tests.json (505-ab-prefix-quoted-shape, 505-ab-quote-bearing-bs, 505-ab-quote-bearing-sq, 505-ab-strip-bs)"
  "ab-lost-deny-verifier-git|case_ab_lost_deny_verifier_git|the verifier denies read-only git behind a lost prefix as git -prefix- -- mutation proof: dev/mutants/hook-tests.json (505-ab-env-opt-off, 505-ab-git-sentinel, 505-ab-unbalanced-dq, 505-ab-unbalanced-off, 505-ab-word-lead-off, 505-ab-word-ungated)"
  "ab-lost-deny-verifier-env-arm-basename|case_ab_lost_deny_verifier_env_arm_basename|the env option arm reads a word whose basename is a prefix word -- mutation proof: dev/mutants/hook-tests.json (505-ab-env-arm-prefix-guard, 505-ab-env-opt-off, 505-ab-git-sentinel, 505-ab-word-ungated)"
  "ab-lost-deny-verifier-env-u-expansion|case_ab_lost_deny_verifier_env_u_expansion|an expansion as the env -u value keeps the git -expansion- verdict -- mutation proof: dev/mutants/hook-tests.json (505-ab-env-u-attached, 505-ab-env-u-attached-rx, 505-ab-env-u-rx)"
  "ab-lost-deny-claude|case_ab_lost_deny_claude|a .claude write behind a lost prefix denies with the .claude reason -- mutation proof: dev/mutants/hook-tests.json (505-ab-claude-arm, 505-ab-env-opt-off, 505-ab-env-u-consume, 505-ab-unbalanced-dq, 505-ab-unbalanced-off, 505-ab-word-ungated)"
  "ab-lost-noop-env-u-consumes|case_ab_lost_noop_env_u_consumes|no opinion: env -u gh pr merge 5 runs pr, the value is consumed -- mutation proof: dev/mutants/hook-tests.json (505-ab-env-u-consume)"
  "ab-lost-noop-verifier-env-allowlist|case_ab_lost_noop_verifier_env_allowlist|no opinion: allowlisted env options and the harness git -C shapes -- mutation proof: dev/mutants/hook-tests.json (505-ab-env-novalue-vocab, 505-ab-env-u-attached)"
  "ab-lost-noop-verifier-nonenv-opt|case_ab_lost_noop_verifier_nonenv_opt|no opinion: an option of sudo is not an env option -- mutation proof: dev/mutants/hook-tests.json (505-ab-env-context)"
  "ab-lost-noop-scan-precision|case_ab_lost_noop_scan_precision|no opinion: the scan reads exact words, not substrings or option suffixes -- mutation proof: dev/mutants/hook-tests.json (505-ab-scan-lead, 505-ab-word-exact, 505-ab-word-ungated)"
  "ab-lost-noop-candidate-exempt|case_ab_lost_noop_candidate_exempt|no opinion: a heredoc bullet line with a quoted word is no option or assignment -- mutation proof: dev/mutants/hook-tests.json (505-ab-shape-gate)"
  "ab-lost-noop-controls|case_ab_lost_noop_controls|no opinion: a trigger with no gh, git or claude word after it -- mutation proof: dev/mutants/hook-tests.json (505-ab-word-ungated)"
  "ab-lostscan-noop-flood|case_ab_lostscan_noop_flood|FLOOD+TIMING: three records of triggering tokens, no opinion; token count sized from a same-run twin holding one trigger per record, deadline a multiple of the predicted linear cost -- mutation proof: dev/mutants/hook-tests.json (505-ab-scan-once)"
  # --- hooks/push-guard.sh (#260) cases -----------------------------------------------------------
  # Mutation-proof table (LESSON 2026-09-01, LESSON 2026-09-07(b)): each row below cites one of
  # the mutants actually applied to hooks/push-guard.sh via a Python literal-string replace
  # asserting exactly one occurrence (never a regex, to avoid a silent no-op substitution), with
  # the observed `bash dev/hook-tests.sh push` pass/fail delta measured against this file's
  # 56-case push-* set AS IT STOOD AT #260, then restored and verified with a full `diff` before
  # the next mutation. M1-M22 were NOT re-run for #270 — only M23-M25 were measured against the
  # 60-case push-* set (the #260 56-case baseline plus the four new #270 CRLF fixtures). M1-M25
  # were NOT re-run for #268 — only M26-M42 were measured against the then-current 80-case
  # push-* set (the #270 60-case baseline plus the twenty new #268 config-route fixtures). M26-M42
  # were NOT re-run for the #268 round-2 kickback — only M43/M44 (below), plus a re-measurement of
  # M35, were measured against the then-current 83-case push-* set (the 80-case baseline plus three
  # more fixtures: a no-space key=value assignment, a benign-refspec-plus-upstream union probe, and
  # an interior-CR refspec value). M26-M44 were NOT re-run for the #268 round-3 kickback — only
  # M45 (below) was measured against the then-current 84-case push-* set (the 83-case baseline
  # plus one more fixture: a cross-remote union bare-push probe). #269 adds the "-C <path>"
  # resolution mutants M46-M55 (below), each FIRST measured against the then-current 96-case
  # push-* set (the 84-case baseline plus the twelve new #269 fixtures); #269 ALSO re-points and
  # re-measures, against that same then-current 96-case set, every existing mutant whose recipe
  # names a line that moved into the new resolve_repo() function — M14, M15, M17, M18, M26, M28,
  # M33, M34, M35, M36, M37, M38, and M43 — each entry above carries its historical figure
  # (measured at its own baseline) followed by its RE-POINTED/RE-MEASURED figure against that
  # 96-case set; several (M14, M15, M17, M26) gained NEW failing cases beyond their historical
  # set, since resolve_repo() is now called for both the session checkout and any resolved "-C"
  # target, so a mutation to its shared body can now also decide a "-C" fixture's verdict, not
  # only a session-only one. No other mutant in M1-M45 (M46-M55's own predecessors) names code
  # that moved. The #269 ROUND-2 KICKBACK (a verifier finding that the per-segment reset had no
  # multi-segment fixture, plus a Note that the depth-1 ascent guard had no fixture at all) adds
  # TWO more fixtures — push-deny-c-unresolvable-never-executes (C2) and
  # push-deny-c-per-segment-session-reset (D1) — growing the push-* set to 98 cases (114 after
  # #290 below, then 116 after #290's own round-2 kickback), and TWO more mutants, M56 and M57
  # (below M55). Re-running M46-M55 plus the
  # thirteen RE-POINTED mutants above against that then-current 98-case set changes only the PASS
  # count (+2 throughout, from the two new passing fixtures) for every one of them EXCEPT four,
  # which each gain exactly one more failing case purely because C2/D1 happen to share a code path
  # an UNCHANGED existing mutant already covered (no code moved this round — this is a
  # new-fixture-matches-an-old-mutant event, not a re-pointing event): M14 and M15 (current_branch
  # / default_branch forced empty) and M52 (unresolvable "-C" target clears instead of degrading)
  # each gain C2, since C2 shares B4's exact verdict mechanism (a bare push judged by the
  # SESSION's own current/default branch after a failed "-C" resolution restores them); M26 (the
  # config-read guard disabled) gains D1, since D1's second segment shares
  # push-deny-config-remote-push-bare's exact mechanism (a bare push denied via the SESSION's own
  # remote.origin.push config). Every other M1-M55 entry's failing SET is unchanged by this
  # kickback (verified directly, not assumed — each of M17, M18, M28, M33, M34, M35, M36, M37,
  # M38, M43, M46, M47, M48, M49, M50, M51, M53, M54, M55 was re-run against that then-current
  # 98-case set and produces the identical failing-case list, +2 pass).
  # #290 adds SIXTEEN more push-* fixtures (the global-config candidates: $GIT_CONFIG_GLOBAL,
  # $XDG_CONFIG_HOME/git/config or its $HOME/.config/git/config default, and $HOME/.gitconfig,
  # unioned with the repo-local routes #268 already reads), growing the push-* set to 114 cases
  # (116 after #290's own round-2 kickback below), and TWELVE more mutants, M58-M69 (below M57).
  # Per the mandate accompanying this issue, EVERY existing mutant whose recipe names code inside
  # resolve_repo()'s config block or config_deny() is RE-MEASURED (not reasoned about) against
  # this 114-case set (the CURRENT 116-case set is covered below, in the round-2 kickback
  # paragraph), not merely
  # the fourteen #269 already re-pointed: M14, M15, M17, M18 (current/default-branch resolution and
  # the common-dir/upward-walk derivations, all upstream of the config candidate list), M26-M45
  # (the whole #268 config-parsing and config_deny() surface, including M27/M29-M32/M39-M42/M44/M45,
  # which #269 never touched since none of their recipes named code that moved into
  # resolve_repo() at that time), and M54 (the resolved-config-not-applied mutant, whose recipe
  # names cfg_push_lines/cfg_push_defaults/cfg_branch_merge by name and so needed re-pointing for
  # #290's cfg_push_default -> cfg_push_defaults rename regardless of #269). Round-1 of this issue
  # incorrectly claimed M46, M47, M48, M49, M50, M51, M52, M53, M55, M56, and M57 were ALL NOT
  # re-measured for #290, reasoning (not measuring) that none of their recipes touches the
  # config-candidate list or the push.default list #290 added. A verifier kickback (finding F3)
  # measured every one of these directly against the #290 114-case push-* set and found the claim false
  # for M46 and M47 specifically: each newly discriminates push-deny-c-target-global-route (#290's
  # own fixture, whose SESSION deliberately resolves NO repo at all — see the dated
  # .claude/LESSONS.md entry — so the "-C" TARGET's own resolution, which both M46
  # (apply_c_target()'s body) and M47 (the tokenizer's "-C" field) each disable by a different
  # route, becomes the ONLY path to this fixture's deny). M48, M49, M50, M51, M52, M53, M55, M56,
  # and M57 ARE genuinely unaffected — each individually re-measured (not reasoned about) and
  # confirmed to keep its EXACT pre-#290 failing set; their own "CURRENT 98-case" figures below are
  # relabeled "the 98-case set" (no longer current, but still an accurate historical measurement)
  # rather than re-run again. Of the TWENTY-SEVEN RE-MEASURED EXISTING mutants (M14, M15, M17, M18,
  # M26-M45, M46, M47, M54 — M46/M47 newly added to this set by the kickback correction above),
  # every one's PASS count grows by exactly +16 (from the sixteen new #290 passing fixtures) EXCEPT
  # NINE, which each gain additional failing cases from #290's own fixtures — M14 (+7: every #290
  # fixture whose deny resolves push.default=upstream/tracking through a real [branch] section),
  # M26 (+12: every #290 DENY fixture, since disabling the whole per-file read loop removes every
  # route regardless of source), M29 (+2), M31 (+1), M39 (+2: both #290 release-blocker "-C"
  # controls, alongside the pre-existing push-noop-config-explicit-refspec), M42 (+9), M46 (+7,
  # corrected as above), M47 (+7, corrected as above), and M54 (+1: the one #290 "-C" fixture whose
  # SESSION deliberately resolves no repo at all, unlike every #269 "-C" fixture's session) — each
  # entry below states its own gained set; the other eighteen (M15, M17, M18, M27, M28, M30, M32,
  # M33, M34, M35, M36, M37, M38, M40, M41, M43, M44, M45) keep their EXACT pre-#290 failing sets
  # (verified directly, not assumed), +16 pass each. The TWELVE NEW mutants, M58-M69 (below M57),
  # are each measured fresh against this 114-case set — see their own entries (and the round-2
  # kickback paragraph immediately below) for what each discriminates against the CURRENT 116-case
  # set.
  # The #290 ROUND-2 KICKBACK (verifier findings F1-F4) adds TWO more push-* fixtures:
  # push-deny-global-two-defaults-one-file (F1 — TWO "[push] default = ..." lines inside ONE file,
  # both accumulated and evaluated rather than the file's own last value winning) and
  # push-deny-config-tab-in-value (F4 — a literal TAB byte inside a configured
  # "remote.<name>.push" value, pinning that it stays in the record's own UNBOUNDED tail rather
  # than corrupting the source label), growing the push-* set to the CURRENT 116 cases, and ONE
  # more mutant, M70 (below M69, reverts F4's field-order fix). M33's own recipe is RESTATED (not
  # re-pointed to different code) for F4's field-order change — the mutation's INTENT (only the
  # FIRST remote.<name>.push record survives) and its figure are unaffected. EVERY mutant in this
  # table, M14 through M70, is RE-MEASURED (not reasoned about) against this CURRENT 116-case set.
  # ELEVEN gain a new failing case beyond their already-recorded 114-case figure: M14 (+1:
  # push-deny-global-two-defaults-one-file, the same push.default=upstream-through-a-real-
  # [branch]-section mechanism M14's own 114-case gain already documents), M26 (+2: BOTH new
  # fixtures, since disabling the whole per-file read loop removes every route regardless of
  # source), M32 (+1: push-deny-config-tab-in-value — the wildcard-destination check M32 disables
  # is exactly what lets this fixture's embedded-TAB value still deny), M42 (+1:
  # push-deny-global-two-defaults-one-file, the same push.default-disabled-entirely mechanism
  # M42's own 114-case gain already documents), M58 (+1: push-deny-global-two-defaults-one-file —
  # its ONLY route is global), M60 (+1: push-deny-global-two-defaults-one-file — its denying record
  # lives in $HOME/.gitconfig specifically), M63 (+2: BOTH new fixtures, corrected below per
  # finding F2b), M64 (+1: push-deny-global-two-defaults-one-file — read as the first EXISTING
  # candidate, so the break-after-first-existing-candidate mutant loses $common/config's own
  # branch.merge before this fixture's "upstream" record can resolve a destination), M65 (+1:
  # push-deny-global-two-defaults-one-file, per finding F1's own fixture design), M67 (+1:
  # push-deny-global-two-defaults-one-file — its inline source-label assertion, not its rc, is what
  # this mutant flips), and M68 (+1: push-deny-config-tab-in-value — likewise its inline
  # source-label assertion). Every other mutant (M15, M17, M18, M27, M28, M29, M30, M31, M33, M34,
  # M35, M36, M37, M38, M39, M40, M41, M43, M44, M45, M46, M47, M48, M49, M50, M51, M52, M53, M54,
  # M55, M56, M57, M59, M61, M62, M66, M69) keeps its EXACT pre-kickback failing set, +2 pass each.
  # M2 (the raw-stdin git fast path) is coarse — breaking it silences the WHOLE hook, so it only
  # distinguishes a deny-verdict case from everything else, never one deny case from another (M1,
  # the push fast path's own pattern, no longer exists since #448 removed that fast path):
  #   M2  fast path 2 pattern corrupted (*git* -> *gitX*)                  -> 23 pass, 33 fail
  #       (fails every push-deny-* case plus push-never-executes-deny and
  #       push-never-executes-reads-only, measured against the #260 56-case baseline — the four
  #       new #270 push-deny-crlf-* / push-noop-crlf-feature fixtures did not exist yet)
  #   M3  the .tool_name == "Bash" check disabled                         -> 55 pass,  1 fail
  #   M4  the .permission_mode == "plan" check disabled                   -> 55 pass,  1 fail
  #   M5  PREFIX_WORDS emptied                                            -> 54 pass,  2 fail
  #   M6  GIT_GLOBAL_OPTS_WITH_VALUE skip changed from j+=2 to j+=1       -> 53 pass,  3 fail
  #   M7  PREFIX_WORDS once-only regression (the agent-boundary.sh M23    -> 55 pass,  1 fail
  #       class: !saw_prefix && (norm in prefix_set), so only the FIRST
  #       recognised token in a segment is skipped instead of every one)
  #   M8  PUSH_ALL_REFS_OPTS emptied                                      -> 54 pass,  2 fail
  #   M9  PUSH_OPTS_WITH_VALUE skip changed from idx+=2 to idx+=1         -> 55 pass,  1 fail
  #   M10 the leading-'+' strip removed                                   -> 55 pass,  1 fail
  #   M11 the colon-split removed (dest always = the whole token)         -> 50 pass,  6 fail
  #   M12 the HEAD/@ -> current-branch substitution removed               -> 55 pass,  1 fail
  #   M13 the refs/heads/ prefix-strip removed                            -> 54 pass,  2 fail
  #   M14 current_branch resolution forced empty                         -> 54 pass,  2 fail
  #       (kills push-deny-head-on-main, push-deny-bare-on-main. #269 RE-POINTED: this line now
  #       lives inside the shared resolve_repo() function, called once for the session and, per
  #       resolved "-C" segment, once more; RE-MEASURED against the then-current 96-case push-* set:
  #       -> 88 pass, 8 fail — the same two historical cases plus six the shared function now also
  #       decides: push-deny-c-sibling-wt-bare-on-default, push-deny-c-sibling-wt-head-refspec,
  #       push-deny-c-unresolvable-degrades, push-deny-config-push-default-upstream,
  #       push-deny-config-push-default-tracking, push-deny-config-union-benign-refspec-plus-
  #       upstream — the last three because branch.<current>.merge is captured only under
  #       cfg_subsection==current_branch, and current_branch is now empty on every call, not just
  #       the session's. RE-MEASURED again for the #269 round-2 kickback against the then-current
  #       98-case push-* set: -> 89 pass, 9 fail — the same eight cases plus
  #       push-deny-c-unresolvable-never-executes (C2), which shares push-deny-c-unresolvable-
  #       degrades' (B4's) exact mechanism: a bare push judged by the SESSION's own current_branch
  #       after a failed "-C" resolution restores it — no code moved for this addition, C2 simply
  #       exercises the identical existing dependency. RE-MEASURED again for #290 against the
  #       114-case push-* set: -> 98 pass, 16 fail — the same nine cases plus SEVEN of the
  #       sixteen new #290 fixtures: push-deny-global-gitconfig-upstream, push-deny-global-xdg-
  #       upstream, push-deny-global-xdg-home-default-upstream, push-deny-global-env-var-upstream,
  #       push-deny-global-benign-does-not-mask-repo-route, push-deny-global-overrides-benign-repo-
  #       route, and push-deny-global-never-executes — every #290 fixture whose deny resolves
  #       push.default=upstream through a REAL [branch] section (the identical
  #       cfg_subsection==current_branch dependency); the other nine #290 fixtures either use a
  #       remote.<name>.push route, push.default=matching (never consults current_branch), or are
  #       no-opinion controls. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT
  #       116-case push-* set: -> 99 pass, 17 fail — the same sixteen cases plus
  #       push-deny-global-two-defaults-one-file (F1), the identical mechanism: its denying record
  #       also resolves push.default=upstream through a real [branch] section; push-deny-config-
  #       tab-in-value (F4) is unaffected, since its route is remote.<name>.push, never
  #       push.default)
  #   M15 default_branch resolution forced empty                         -> 53 pass,  3 fail
  #       (kills push-deny-trunk-base, push-deny-trunk-subdir, push-deny-trunk-worktree. #269
  #       RE-POINTED (same shared resolve_repo() function) and RE-MEASURED against the then-current
  #       96-case push-* set: -> 87 pass, 9 fail — the three historical cases plus six more:
  #       push-deny-c-sibling-wt-bare-on-default, push-deny-c-other-repo-explicit-develop,
  #       push-deny-c-sibling-wt-head-refspec, push-deny-c-unresolvable-degrades, push-deny-c-
  #       session-default-union, push-deny-c-never-executes — every "-C" deny fixture whose verdict
  #       depends on SOME default branch resolving, session's or the resolved target's; the two
  #       fixtures that deny via CONFIG rather than a default-branch match
  #       (push-deny-c-other-repo-config-route, push-noop-c-other-repo-ignores-session-config) are
  #       unaffected. RE-MEASURED again for the #269 round-2 kickback against the then-current
  #       98-case push-* set: -> 88 pass, 10 fail — the same nine cases plus
  #       push-deny-c-unresolvable-never-executes (C2), for the identical reason M14 above gained
  #       it: C2 mirrors B4's dependency on the session's own default_branch too. RE-MEASURED again
  #       for #290 against the 114-case push-* set: -> 104 pass, 10 fail — UNCHANGED failing
  #       set, +16 pass; none of the sixteen new #290 fixtures denies via a NON-fallback default
  #       branch value — every #290 deny route resolves either through PUSH_DEFAULT_BRANCH_FALLBACK's
  #       unconditional "main"/"master" members or through a remote.<name>.push/matching route that
  #       never reads default_branch at all. RE-MEASURED again for the #290 ROUND-2 KICKBACK against
  #       the CURRENT 116-case push-* set: -> 106 pass, 10 fail — UNCHANGED failing set, +2 pass;
  #       neither new kickback fixture denies via a non-fallback default branch value either)
  #   M16 PUSH_DEFAULT_BRANCH_FALLBACK emptied                            -> 55 pass,  1 fail
  #   M17 the worktree common-dir derivation broken (never strips        -> 55 pass,  1 fail
  #       /worktrees/* from gitdir)
  #       (kills only push-deny-trunk-worktree. #269 RE-POINTED (shared resolve_repo()) and
  #       RE-MEASURED against the then-current 96-case push-* set: -> 94 pass, 2 fail — the
  #       historical case plus push-deny-config-worktree-commondir, #268's own worktree-config
  #       fixture, which depends on the identical common-dir derivation. RE-MEASURED again for the
  #       #269 round-2 kickback against the then-current 98-case push-* set: -> 96 pass, 2 fail —
  #       unchanged failing set, +2 pass from the two new #269-round-2 fixtures, neither a
  #       worktree. RE-MEASURED again for #290 against the 114-case push-* set: -> 112
  #       pass, 2 fail — UNCHANGED failing set, +16 pass; none of the sixteen new #290 fixtures is
  #       a worktree either. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT
  #       116-case push-* set: -> 114 pass, 2 fail — UNCHANGED failing set, +2 pass; neither new
  #       kickback fixture is a worktree either)
  #   M18 the upward .git walk disabled (dir="$parent" -> dir="$dir",     -> 55 pass,  1 fail
  #       so it never leaves the starting directory)
  #       (kills only push-deny-trunk-subdir. #269 RE-POINTED (shared resolve_repo()) and
  #       RE-MEASURED against the then-current 96-case push-* set: -> 95 pass, 1 fail — unchanged
  #       failing set; no #268/#269 fixture depends on a multi-level upward walk. RE-MEASURED
  #       again for the #269 round-2 kickback against the then-current 98-case push-* set: -> 97
  #       pass, 1 fail — unchanged failing set, +2 pass; neither new fixture depends on a
  #       multi-level upward walk either. RE-MEASURED again for #290 against the 114-case
  #       push-* set: -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass; no #290 fixture
  #       depends on a multi-level upward walk either. RE-MEASURED again for the #290 ROUND-2
  #       KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED failing
  #       set, +2 pass; neither new kickback fixture depends on a multi-level upward walk either)
  #   M19 is_deny_member widened from an exact word match to a per-      -> 55 pass,  1 fail
  #       member PREFIX match (main* matches "main-ish")
  #   M20 the "refs/* (a tag, a note) -> skip" clause changed to a       -> 56 pass,  0 fail
  #       no-op (dest left unchanged) -- NOT flipped: confirms
  #       push-noop-refs-tags is unaffected because this implementation
  #       only ever strips the "refs/heads/" prefix specifically, so an
  #       un-skipped tag ref's full literal path can never coincidentally
  #       equal a plain branch name in the deny set
  #   M21 normalize()'s basename-after-last-/ step removed                -> 55 pass,  1 fail
  #   M22 tool_input.command's jq default changed from empty to a real   -> 55 pass,  1 fail
  #       command string
  #   M23 the two #270 CR-strip lines deleted (cr=$'\r'; cmd="${cmd//$cr/}") -> 57 pass,  3 fail
  #       (measured against the then-current 60-case push-* set — the three new #270 push-deny-crlf-*
  #       fixtures are the only cases that flip; push-noop-crlf-feature is NOT flipped, see below.
  #       Re-measured after the #270 round-2 kickback rewrote push-deny-crlf-interior's raw
  #       command from two CRs to three — the figures and failing set are unchanged from the
  #       original two-CR fixture)
  #   M24 the shipped global strip narrowed to trailing-only                -> 58 pass,  2 fail
  #       (cmd="${cmd//$cr/}" -> cmd="${cmd%$cr}"; #270 round-2 kickback, added because M23 alone
  #       cannot distinguish "strips every \r" from "strips only a trailing \r" — measured against
  #       the then-current 60-case push-* set: kills push-deny-crlf-interior and push-deny-crlf-cmdword,
  #       neither of whose verdict-bearing CR is the command's final byte; does NOT kill
  #       push-deny-crlf-dest, whose single CR IS the final byte)
  #   M25 the shipped global strip narrowed to once-only                    -> 59 pass,  1 fail
  #       (cmd="${cmd//$cr/}" -> cmd="${cmd/$cr/}"; #270 round-2 kickback finding — the original
  #       two-CR push-deny-crlf-interior fixture's verdict-bearing CR happened to be its FIRST, so
  #       this mutant survived the whole 60-case set undetected until the fixture was rewritten to
  #       a three-CR command whose verdict-bearing CR is the SECOND, not the first — measured
  #       against the then-current 60-case push-* set: kills only push-deny-crlf-interior; does NOT
  #       kill push-deny-crlf-dest or push-deny-crlf-cmdword, each of whose single CR IS the first
  #       (and only) one)
  # #268's config-route mutants (M26-M42), measured against the then-current 80-case push-* set
  # (NOT re-run for the #268 round-2 kickback below — see this section's header note above); each
  # applied via a Python literal-string replace asserting exactly one occurrence, restored and
  # verified with a full `diff` + sha256 before the next mutation:
  #   M26 the config read guard disabled (if [ -f "$cfgf" ]; then -> if false           -> 68 pass,
  #       && [ -f "$cfgf" ]; then)                                                       12 fail
  #       (fails all twelve push-deny-config-* cases: remote-push-bare, remote-push-named-remote,
  #       remote-push-second-line, push-default-upstream, push-default-tracking,
  #       push-default-matching, wildcard-refspec, crlf-line, worktree-commondir,
  #       no-trailing-newline, mixed-case, and never-executes -- config is never read at all, so
  #       none of the twelve config-derived deny routes fire. #269 RE-POINTED: this line now lives
  #       inside the shared resolve_repo() function, so the guard is disabled for the "-C" target
  #       call too; RE-MEASURED against the then-current 96-case push-* set: -> 79 pass, 17 fail --
  #       every one of the SIXTEEN push-deny-config-* fixtures now in the suite (the original
  #       twelve plus the four #268 round-2/round-3 additions: no-space-assign, union-benign-
  #       refspec-plus-upstream, union-other-remote-bare, crlf-interior) plus the new #269
  #       push-deny-c-other-repo-config-route (A4), whose deny is likewise decided entirely by a
  #       resolved checkout's config. RE-MEASURED again for the #269 round-2 kickback against the
  #       then-current 98-case push-* set: -> 80 pass, 18 fail — the same seventeen cases plus
  #       push-deny-c-per-segment-session-reset (D1), whose SECOND segment shares
  #       push-deny-config-remote-push-bare's exact mechanism: a bare push denied via the
  #       SESSION's own remote.origin.push config, disabled here for the SESSION-scope
  #       resolve_repo() call too, not just the "-C" one -- this is the same shared-function
  #       dependency, not new code. #290 RE-POINTED: this line now lives inside the per-candidate-
  #       file loop (`[ -f "$cfgf" ] || continue` -> `continue` unconditionally), so EVERY
  #       candidate file -- global or repo-local -- is skipped, not just the repo-local one;
  #       RE-MEASURED against the 114-case push-* set: -> 84 pass, 30 fail — the same
  #       eighteen cases plus TWELVE of the sixteen new #290 fixtures (every #290 DENY fixture; the
  #       four #290 no-opinion fixtures are unaffected, since disabling every config read can only
  #       ever remove a route, never add one). RE-MEASURED again for the #290 ROUND-2 KICKBACK
  #       against the CURRENT 116-case push-* set: -> 84 pass, 32 fail — the same thirty cases plus
  #       BOTH new #290 kickback fixtures, push-deny-global-two-defaults-one-file (F1) and
  #       push-deny-config-tab-in-value (F4) -- each a DENY fixture whose only route is a config
  #       read this mutant disables entirely, the identical mechanism as the other twelve)
  #   M27 the n==1 exact-remote-scoping guard disabled (if [ -n "$scope" ] &&             -> 79 pass,
  #       [ "$sub" != "$scope" ]; then -> if false && ...)                                 1 fail
  #       (kills only push-noop-config-other-remote-named -- "origin"'s own push route wrongly
  #       applies to a "git push backup". NOT RE-POINTED by #269 (no code moved); #290
  #       RE-MEASURED for the first time since this #268 round-1 80-case baseline, against the
  #       114-case push-* set: -> 113 pass, 1 fail — UNCHANGED failing set, +34 pass; none
  #       of the #269/#290 fixtures added since names a non-origin remote in this shape.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture names
  #       a non-origin remote in this shape either)
  #   M28 the [branch "<current>"] scoping guard disabled (if [ "$cfg_subsection" =       -> 79 pass,
  #       "$current_branch" ]; then -> if true || ...)                                     1 fail
  #       (kills only push-noop-config-branch-other -- a DIFFERENT branch's merge value wrongly
  #       applies to the current branch. #269 RE-POINTED (shared resolve_repo()) and RE-MEASURED
  #       against the then-current 96-case push-* set: -> 95 pass, 1 fail — unchanged failing set;
  #       no #269 fixture depends on this guard, since none of the twelve new fixtures configures a
  #       [branch] section at all. RE-MEASURED again for the #269 round-2 kickback against the
  #       then-current 98-case push-* set: -> 97 pass, 1 fail — unchanged failing set, +2 pass;
  #       neither new fixture configures a [branch] section either. RE-MEASURED again for #290
  #       against the 114-case push-* set: -> 113 pass, 1 fail — UNCHANGED failing set,
  #       +16 pass; none of the sixteen new #290 fixtures configures a [branch] section either.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; push-deny-global-two-defaults-
  #       one-file's own [branch "feature/x"] section already equals its current branch, so this
  #       guard's absence changes nothing for it, and push-deny-config-tab-in-value configures no
  #       [branch] section at all)
  #   M29 the push.default mode-check pattern widened to match every value               -> 77 pass,
  #       ([Uu][Pp][Ss][Tt][Rr][Ee][Aa][Mm]|[Tt][Rr][Aa][Cc][Kk][Ii][Nn][Gg]) -> *))         3 fail
  #       (kills push-noop-config-push-default-current and push-noop-config-push-default-simple,
  #       whose branch sections WOULD deny if their mode were mistaken for upstream; also kills
  #       push-deny-config-push-default-matching as a side effect -- the "matching" case arm
  #       becomes unreachable once "*)" matches everything first, so that fixture's config, which
  #       has no branch section, resolves to no destination at all instead of denying. NOT
  #       RE-POINTED by #269; #290 RE-MEASURED for the first time since this #268 round-1 80-case
  #       baseline, against the 114-case push-* set: -> 109 pass, 5 fail — the same three
  #       cases plus TWO of the sixteen new #290 fixtures, as a side effect: push-deny-global-
  #       default-matching (its "matching" case arm becomes unreachable too) and
  #       push-deny-global-benign-does-not-mask-repo-route -- NOT because its deny is masked
  #       (measured, correcting a verifier-round-1 finding, F2a: this fixture STILL denies, rc 2,
  #       under this mutant); its benign GLOBAL "current" record is evaluated FIRST in
  #       cfg_push_defaults' accumulation order and NOW ALSO matches the widened "*)" arm, so this
  #       mutant denies via that GLOBAL record's own push.default=current -- resolving "main" from
  #       cfg_branch_merge exactly as the "upstream" arm normally would -- and only the fixture's
  #       OWN inline source-label assertion fails, since the deny is attributed to "your global git
  #       config" (correct for THIS mutant's own record) rather than the REPO's ".git/config" label
  #       the fixture's assertion expects. RE-MEASURED again for the #290 ROUND-2 KICKBACK against
  #       the CURRENT 116-case push-* set: -> 111 pass, 5 fail — UNCHANGED failing set, +2 pass;
  #       neither new kickback fixture's FIRST-accumulated push.default record is a value this
  #       mutant's widened arm newly reaches ahead of a genuine deny (push-deny-global-two-
  #       defaults-one-file's own first record, "upstream", already matched this arm before the
  #       mutation, so widening it changes nothing for that fixture; push-deny-config-tab-in-value
  #       uses remote.<name>.push, never push.default, at all))
  #   M30 "tracking" dropped from the upstream/tracking pattern (...[Mm]|[Tt]...[Gg])      -> 79 pass,
  #       -> [Uu][Pp][Ss][Tt][Rr][Ee][Aa][Mm]))                                              1 fail
  #       (kills only push-deny-config-push-default-tracking. NOT RE-POINTED by #269; #290
  #       RE-MEASURED for the first time since this #268 round-1 80-case baseline, against the
  #       114-case push-* set: -> 113 pass, 1 fail — UNCHANGED failing set, +34 pass; none
  #       of the sixteen new #290 fixtures uses push.default=tracking. RE-MEASURED again for the
  #       #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail —
  #       UNCHANGED failing set, +2 pass; neither new kickback fixture uses push.default=tracking
  #       either)
  #   M31 the push.default=matching deny arm's body replaced with a no-op (:              -> 79 pass,
  #       instead of __deny_dest=.../__deny_kind=.../__deny_via=...)                        1 fail
  #       (kills only push-deny-config-push-default-matching. NOT RE-POINTED by #269; #290
  #       RE-MEASURED for the first time since this #268 round-1 80-case baseline, against the
  #       114-case push-* set: -> 112 pass, 2 fail — the same case plus ONE of the sixteen
  #       new #290 fixtures, push-deny-global-default-matching, whose deny depends entirely on this
  #       same arm's body. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT
  #       116-case push-* set: -> 114 pass, 2 fail — UNCHANGED failing set, +2 pass; neither new
  #       kickback fixture's deny depends on this arm)
  #   M32 the wildcard-destination ("*") deny check removed from config_deny()'s          -> 79 pass,
  #       per-record loop (the case "$dest" in *'*'*) ... esac block deleted)               1 fail
  #       (kills only push-deny-config-wildcard-refspec -- its resolved destination, a literal
  #       "*", falls through to an ordinary is_deny_member compare and does not match. NOT
  #       RE-POINTED by #269; #290 RE-MEASURED for the first time since this #268 round-1 80-case
  #       baseline, against the 114-case push-* set: -> 113 pass, 1 fail — UNCHANGED
  #       failing set, +34 pass; no #290 fixture's config carries a wildcard destination.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 114 pass, 2 fail — the same case plus push-deny-config-tab-in-value (F4): that
  #       fixture's own wildcard destination ("refs/heads/*:refs/heads/*<TAB>junklabel") relies on
  #       this exact check to deny; removing it falls through to the same is_deny_member compare,
  #       which does not match either)
  #   M33 only the FIRST remote.<name>.push record is ever kept (F4's field-reorder            -> 79 pass,
  #       kickback restates this recipe: [ -n "$cfg_push_lines" ] || cfg_push_lines=...           1 fail
  #       guard added before the append, now writing "${cfg_src}${cfg_tab}${cfg_subsection}
  #       ${cfg_tab}${cfg_val}" -- the field ORDER changed by finding F4, the mutation's INTENT
  #       and figure did not)
  #       (kills only push-deny-config-remote-push-second-line -- the fixture's first, harmless
  #       push= line wins and the second, offending one is never seen. #269 RE-POINTED (shared
  #       resolve_repo()) and RE-MEASURED against the then-current 96-case push-* set: -> 95 pass,
  #       1 fail — unchanged failing set; no #269 fixture's config carries two push= lines under
  #       one remote. RE-MEASURED again for the #269 round-2 kickback against the then-current
  #       98-case push-* set: -> 97 pass, 1 fail — unchanged failing set, +2 pass; neither new
  #       fixture's config carries two push= lines under one remote either. RE-MEASURED again for
  #       #290 against the 114-case push-* set: -> 113 pass, 1 fail — UNCHANGED failing
  #       set, +16 pass; no #290 fixture's config carries two push= lines under one remote either.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK, with the recipe restated for F4's field
  #       reorder as noted above, against the CURRENT 116-case push-* set: -> 115 pass, 1 fail —
  #       UNCHANGED failing set, +2 pass; neither new kickback fixture's config carries two push=
  #       lines under one remote either)
  #   M34 the comment-stripping assignment disabled (if [ "${#cfg_h}" -le               -> 80 pass,
  #       "${#cfg_s}" ]; then cfgline="$cfg_h"; else cfgline="$cfg_s"; fi -> :)             0 fail
  #       -- NOT flipped: every "#"/";"-commented directive in this table's fixtures keeps its
  #       comment marker as a literal, non-whitespace prefix character on the key (e.g. "# push"
  #       or "; default"), which the exact case patterns below ([Pp][Uu][Ss][Hh],
  #       [Dd][Ee][Ff][Aa][Uu][Ll][Tt]) can never match regardless of whether the comment is
  #       stripped -- confirms push-noop-config-commented-out's comment lines are harmless for a
  #       DIFFERENT, more fundamental reason than the strip itself (exact-key matching), a
  #       genuine measured finding, not an assumption (see M40 below for the mutant that DOES
  #       exercise that fixture). #269 RE-POINTED (shared resolve_repo()) and RE-MEASURED against
  #       the then-current 96-case push-* set: -> 96 pass, 0 fail — still NOT flipped, same reason
  #       (no #269 fixture's config carries a "#"/";"-commented directive either). RE-MEASURED
  #       again for the #269 round-2 kickback against the then-current 98-case push-* set: -> 98
  #       pass, 0 fail — still NOT flipped, same reason (neither new fixture's config carries a
  #       "#"/";"-commented directive either). RE-MEASURED again for #290 against the
  #       114-case push-* set: -> 114 pass, 0 fail — still NOT flipped, same reason (no #290
  #       fixture's config carries a "#"/";"-commented directive either). RE-MEASURED again for the
  #       #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 116 pass, 0 fail —
  #       still NOT flipped, same reason (neither new kickback fixture's config carries a
  #       "#"/";"-commented directive either))
  #   M35 the config-line CR strip disabled (cfgline="${cfgline//$cfg_cr/}" -> :) -- FIRST
  #       measured (then-current 80-case push-* set, #268 round 1): -> 80 pass, 0 fail (not
  #       flipped). RE-MEASURED for the #268 round-2 kickback (finding 3), after
  #       push-deny-config-crlf-interior (below) was added, against the then-current 83-case
  #       push-* set: -> 82 pass, 1 fail. NOT re-run for the #268 round-3 kickback.
  #       -- push-deny-config-crlf-line is STILL not flipped: cfg_trim()'s [[:space:]]
  #       bracket-class strip (applied to every line regardless) already removes a trailing CR as
  #       an incidental side effect, since a carriage return is itself classified as [:space:],
  #       and that fixture's line-ending CR is at the very end of the line, already covered by
  #       cfg_trim's existing whitespace strip -- a genuine measured finding (defense in depth,
  #       not a coverage gap), not an assumption. push-deny-config-crlf-interior IS flipped: its
  #       CR sits in the MIDDLE of the refspec value ("HEAD:ma<CR>in"), a position cfg_trim's
  #       leading/trailing-only strip never reaches, so removing cfg_cr's own strip leaves the CR
  #       in the parsed destination, which then fails the exact is_deny_member compare -- this is
  #       the fixture that makes M35 non-inert. #269 RE-POINTED (shared resolve_repo()) and
  #       RE-MEASURED against the then-current 96-case push-* set: -> 95 pass, 1 fail — unchanged
  #       failing set (push-deny-config-crlf-interior only); no #269 fixture's config carries a CR.
  #       RE-MEASURED again for the #269 round-2 kickback against the then-current 98-case push-*
  #       set: -> 97 pass, 1 fail — unchanged failing set, +2 pass; neither new fixture's config
  #       carries a CR either. RE-MEASURED again for #290 against the 114-case push-* set:
  #       -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass; no #290 fixture's config carries a
  #       CR either. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case
  #       push-* set: -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; neither new kickback
  #       fixture's config carries a CR either.
  #   M36 the config path changed from "$common/config" to "$gitdir/config"               -> 79 pass,
  #                                                                                          1 fail
  #       (kills only push-deny-config-worktree-commondir -- the worktree pointer's own gitdir
  #       has no config file at all, so [ -f ] fails and config is silently never read; every
  #       non-worktree fixture has $gitdir == $common already, so this mutant is inert for them.
  #       #269 RE-POINTED (shared resolve_repo()) and RE-MEASURED against the then-current 96-case
  #       push-* set: -> 95 pass, 1 fail — unchanged failing set; every #269 "-C" target fixture is
  #       an ordinary checkout, not a worktree, so $gitdir == $common for all of them too.
  #       RE-MEASURED again for the #269 round-2 kickback against the then-current 98-case push-*
  #       set: -> 97 pass, 1 fail — unchanged failing set, +2 pass; C2/D1's checkouts are likewise
  #       ordinary, not worktrees. #290 RE-POINTED: this line now lives in the config-CANDIDATE
  #       heredoc's own repo-local line ($common/config -> $gitdir/config), the same effect one
  #       level up; RE-MEASURED against the 114-case push-* set: -> 113 pass, 1 fail —
  #       UNCHANGED failing set, +16 pass; every #290 fixture's own checkout (session or "-C"
  #       target) is likewise an ordinary checkout, not a worktree. RE-MEASURED again for the #290
  #       ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED
  #       failing set, +2 pass; neither new kickback fixture's own checkout is a worktree either)
  #   M37 the last-line-without-a-trailing-newline read rescue removed (while             -> 79 pass,
  #       IFS= read -r cfgline || [ -n "$cfgline" ] -> while IFS= read -r cfgline)          1 fail
  #       (kills only push-deny-config-no-trailing-newline -- its one and only config line, which
  #       has no trailing newline, is silently dropped by `read`'s own EOF behaviour. #269
  #       RE-POINTED (shared resolve_repo()) and RE-MEASURED against the then-current 96-case
  #       push-* set: -> 95 pass, 1 fail — unchanged failing set; every #269 fixture's config,
  #       where one is written at all, ends in a trailing newline. RE-MEASURED again for the #269
  #       round-2 kickback against the then-current 98-case push-* set: -> 97 pass, 1 fail —
  #       unchanged failing set, +2 pass; D1's config (the only new fixture with one) also ends in
  #       a trailing newline. RE-MEASURED again for #290 against the 114-case push-* set:
  #       -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass; every #290 fixture's config, where
  #       one is written at all, also ends in a trailing newline. RE-MEASURED again for the #290
  #       ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED
  #       failing set, +2 pass; both new kickback fixtures' configs also end in a trailing newline)
  #   M38 the [remote "<name>"] section-header pattern narrowed to lowercase-only         -> 79 pass,
  #       ([Rr][Ee][Mm][Oo][Tt][Ee] -> remote)                                              1 fail
  #       (kills only push-deny-config-mixed-case -- "[Remote ...]" no longer matches the section
  #       pattern at all and falls through to the catch-all "other" section, so its "Push = ..."
  #       key is never captured. #269 RE-POINTED (shared resolve_repo()) and RE-MEASURED against
  #       the then-current 96-case push-* set: -> 95 pass, 1 fail — unchanged failing set; no #269
  #       fixture's config uses mixed-case section/key names. RE-MEASURED again for the #269
  #       round-2 kickback against the then-current 98-case push-* set: -> 97 pass, 1 fail —
  #       unchanged failing set, +2 pass; neither new fixture's config uses mixed-case section/key
  #       names either. RE-MEASURED again for #290 against the 114-case push-* set: -> 113
  #       pass, 1 fail — UNCHANGED failing set, +16 pass; no #290 fixture's config uses mixed-case
  #       section/key names either. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the
  #       CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; neither
  #       new kickback fixture's config uses mixed-case section/key names either)
  #   M39 the n<=1 gate removed (config_deny is also called after the n>=2 refspec        -> 79 pass,
  #       loop, using nonopt[0] as scope)                                                   1 fail
  #       (kills only push-noop-config-explicit-refspec -- the harness's own
  #       `git push -u origin "claude/17-a"` shape wrongly denies via the fixture's
  #       remote.origin.push=HEAD:main config; a release-blocker regression if this ever shipped.
  #       NOT RE-POINTED by #269; #290 RE-MEASURED for the first time since this #268 round-1
  #       80-case baseline, against the 114-case push-* set: -> 111 pass, 3 fail — the same
  #       case plus BOTH #290 release-blocker "-C" controls, push-noop-global-explicit-refspec and
  #       push-noop-global-explicit-refspec-c — the release-blocker class this gate exists for.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 113 pass, 3 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture
  #       carries an explicit refspec)
  #   M40 a matched remote.<name>.push record denies unconditionally, regardless          -> 78 pass,
  #       of its resolved destination (the is_deny_member "$dest" compare after the         2 fail
  #       wildcard check is removed)
  #       (kills push-noop-config-remote-push-other-dest, whose configured refspec resolves to a
  #       non-default destination, and push-noop-config-commented-out, whose one REAL harmless
  #       key -- "push = feature/x" -- is a genuine, correctly-parsed remote.origin.push record
  #       that must NOT deny on its own; this is the mutant that actually exercises
  #       push-noop-config-commented-out's parsing, not M34 above. NOT RE-POINTED by #269; #290
  #       RE-MEASURED for the first time since this #268 round-1 80-case baseline, against the
  #       114-case push-* set: -> 112 pass, 2 fail — UNCHANGED failing set, +34 pass; no
  #       #290 fixture's benign remote.<name>.push record resolves to a non-default destination.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 114 pass, 2 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture's
  #       route resolves to a non-default destination either)
  #   M41 the n==1 config route removed ([ -n "$__deny_dest" ] || config_deny             -> 79 pass,
  #       "$scope_remote" -> ... || [ "$n" -eq 1 ] || config_deny "$scope_remote")          1 fail
  #       (kills only push-deny-config-remote-push-named-remote -- the n==1 positive control for
  #       exact-remote scoping. NOT RE-POINTED by #269; #290 RE-MEASURED for the first time since
  #       this #268 round-1 80-case baseline, against the 114-case push-* set: -> 113 pass,
  #       1 fail — UNCHANGED failing set, +34 pass; no #290 fixture exercises the n==1 config route.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture
  #       exercises the n==1 config route either)
  #   M42 the push.default LIST evaluation disabled entirely (if [ -n                    -> 102 pass,
  #       "$cfg_push_defaults" ]; then -> if [ -n "" ]; then)                              12 fail
  #       (HISTORICAL RECIPE, #268 round 1: "case "$cfg_push_default" in -> case "" in", against a
  #       scalar `case` statement that no longer exists after #290 turned cfg_push_default into the
  #       cfg_push_defaults LIST evaluated by a `while` loop -- restated above against the CURRENT
  #       code shape, same intent (disable the whole push.default route unconditionally); historical
  #       figure at the #268 round-1 80-case baseline: 77 pass, 3 fail, killing
  #       push-deny-config-push-default-upstream, push-deny-config-push-default-tracking, and
  #       push-deny-config-push-default-matching -- the only three deny fixtures whose config
  #       carries no remote.<name>.push record at all, so denying depends entirely on this route.
  #       NOT RE-POINTED by #269; #290 RE-MEASURED (with the restated recipe) against the CURRENT
  #       114-case push-* set: -> 102 pass, 12 fail — the same three historical cases plus NINE
  #       more: EIGHT of the sixteen new #290 fixtures whose deny depends on the push.default route
  #       with no remote.<name>.push record of its own (push-deny-global-gitconfig-upstream,
  #       push-deny-global-xdg-upstream, push-deny-global-xdg-home-default-upstream,
  #       push-deny-global-env-var-upstream, push-deny-global-default-matching,
  #       push-deny-global-benign-does-not-mask-repo-route,
  #       push-deny-global-overrides-benign-repo-route, push-deny-global-never-executes), plus ONE
  #       PRE-#290 fixture that also newly flips, push-deny-config-union-benign-refspec-plus-
  #       upstream: its remote.origin.push record resolves to a benign, non-denying destination, so
  #       its deny ALSO depends entirely on this route, same as the three historical cases -- an
  #       existing dependency this restated recipe now surfaces explicitly that the #268 round-1
  #       recipe's own citation never named. RE-MEASURED again for the #290 ROUND-2 KICKBACK
  #       against the CURRENT 116-case push-* set: -> 103 pass, 13 fail — the same twelve cases plus
  #       push-deny-global-two-defaults-one-file (F1): its deny depends entirely on the push.default
  #       route too (a global file, no remote.<name>.push record at all); push-deny-config-tab-in-
  #       value (F4) is unaffected, since its route is remote.<name>.push, never push.default)
  # #268 round-2 kickback mutants (M43-M44), measured against the then-current 83-case push-* set
  # (the 80-case baseline plus push-deny-config-no-space-assign, push-deny-config-union-benign-
  # refspec-plus-upstream, and push-deny-config-crlf-interior):
  #   M43 the *=*) split guard narrowed to require spaces around the "="              -> 82 pass,
  #       (*=*) -> *" = "*))                                                             1 fail
  #       (kills only push-deny-config-no-space-assign -- a "key=value" record with no
  #       surrounding spaces no longer matches the split guard at all and falls through to the
  #       "continue" arm, so the key/value pair is silently never parsed. #269 RE-POINTED (shared
  #       resolve_repo()) and RE-MEASURED against the then-current 96-case push-* set: -> 95 pass,
  #       1 fail — unchanged failing set; no #269 fixture's config omits the spaces around "=".
  #       RE-MEASURED again for the #269 round-2 kickback against the then-current 98-case push-*
  #       set: -> 97 pass, 1 fail — unchanged failing set, +2 pass; D1's config also keeps the
  #       spaces around "=". RE-MEASURED again for #290 against the 114-case push-* set:
  #       -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass; no #290 fixture's config omits the
  #       spaces around "=" either. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the
  #       CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; neither
  #       new kickback fixture's config omits the spaces around "=" either)
  #   M44 the push.default route gated on git's OWN precedence instead of the RESOLVED    -> 113 pass,
  #       union (if [ -n "$cfg_push_defaults" ]; then -> if [ -z "$cfg_push_lines" ] &&      1 fail
  #       [ -n "$cfg_push_defaults" ]; then)
  #       (HISTORICAL RECIPE, #268 round-2 kickback: "case "$cfg_push_default" in -> if [ -z
  #       "$cfg_push_lines" ]; then case "$cfg_push_default" in ... esac; fi", against a scalar
  #       `case` statement that no longer exists after #290's cfg_push_defaults LIST rename --
  #       restated above against the CURRENT code shape, same intent (gate the whole push.default
  #       route on git's own precedence -- consulted only when the remote has no push refspec --
  #       instead of the RESOLVED union both routes are meant to get); historical figure at the
  #       then-current 83-case baseline: 82 pass, 1 fail, killing only
  #       push-deny-config-union-benign-refspec-plus-upstream -- its remote.origin.push record
  #       resolves to a NON-denying destination (feature/x), so $cfg_push_lines is non-empty and
  #       this mutant's precedence gate skips the push.default resolution entirely, even though
  #       push.default=upstream alone denies; every other push-default-* deny fixture has NO
  #       remote.<name>.push record at all, so $cfg_push_lines is empty for them and this mutant is
  #       inert. NOT RE-POINTED by #269; #290 RE-MEASURED (with the restated recipe) against the
  #       114-case push-* set: -> 113 pass, 1 fail — UNCHANGED failing set, +31 pass; none
  #       of the sixteen new #290 fixtures pairs a non-denying remote.<name>.push record with a
  #       denying push.default record on the SAME checkout. RE-MEASURED again for the #290 ROUND-2
  #       KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED failing
  #       set, +2 pass; neither new kickback fixture pairs a non-denying remote.<name>.push record
  #       with a denying push.default record on the same checkout either)
  # #268 round-3 kickback mutant (M45), measured against the then-current 84-case push-* set (the
  # 83-case baseline plus one more fixture, push-deny-config-union-other-remote-bare; grown to 98
  # by #269 below and its own round-2 kickback, then to 114 by #290, then to the CURRENT 116 by
  # #290's own round-2 kickback):
  #   M45 the n==1/n==0 scope gate narrowed from "every configured remote at n==0"       -> 83 pass,
  #       to "git's own default remote" (if [ -n "$scope" ] && [ "$sub" != "$scope" ];      1 fail
  #       then -> if [ "$sub" != "${scope:-origin}" ]; then)
  #       (kills only push-deny-config-union-other-remote-bare -- its config carries a denying
  #       remote.<name>.push record ONLY under a non-origin remote name ("backup"), plus a benign
  #       origin section with no push key at all; the shipped scope gate considers every remote's
  #       records at n==0 and denies, while this mutant narrows the n==0 scope to only the
  #       "origin" record, whose absence leaves nothing to deny on -- every other config deny
  #       fixture names "origin" as its offending remote, so this mutant is inert for them. NOT
  #       RE-POINTED by #269; #290 RE-MEASURED for the first time since this #268 round-3
  #       84-case baseline, against the 114-case push-* set: -> 113 pass, 1 fail —
  #       UNCHANGED failing set, +30 pass; no #290 fixture's config carries a denying
  #       remote.<name>.push record under a non-origin remote name. RE-MEASURED again for the #290
  #       ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED
  #       failing set, +2 pass; neither new kickback fixture's config carries a denying
  #       remote.<name>.push record under a non-origin remote name either)
  # #269's "-C <path>" resolution mutants (M46-M55), FIRST measured against the then-current
  # 96-case push-* set (the 84-case #268-round-3 baseline plus the twelve new #269 fixtures
  # directly below); each RE-MEASURED again for the #269 round-2 kickback against the then-current
  # 98-case push-* set (the 96-case baseline plus C2 and D1, added by that kickback — see M56/M57
  # below). Round-1 of this issue incorrectly claimed M46-M53, M55, M56, and M57 were ALL NOT
  # re-measured for #290, reasoning that none of their recipes touches the config-candidate list or
  # the push.default list #290 added. A verifier kickback (finding F3) measured every one of these
  # directly and found this false for M46 and M47 specifically — see their own entries below for
  # the corrected figures and mechanism. M48, M49, M50, M51, M52, M53, M55, M56, and M57 ARE
  # genuinely unaffected — each individually re-measured (not reasoned about) and confirmed to keep
  # its EXACT pre-#290 failing set — so their own "CURRENT 98-case" wording below is downgraded to
  # "the 98-case set" — an accurate historical label, not a current one, now that #290 and its own
  # round-2 kickback have grown the push-* set to the CURRENT 116:
  #   M46 apply_c_target()'s entire body replaced with ":" (the "-C" route never applies         -> 89 pass,
  #       anything, regardless of predicate or resolution)                                        7 fail
  #       (kills push-deny-c-sibling-wt-bare-on-default, push-deny-c-other-repo-explicit-develop,
  #       push-deny-c-sibling-wt-head-refspec, push-deny-c-other-repo-config-route,
  #       push-noop-c-other-repo-ignores-session-config, push-noop-c-sibling-wt-session-on-default,
  #       and push-deny-c-never-executes -- every fixture whose verdict actually depends on the
  #       "-C" target resolving to something; the four fixtures that never resolve in the first
  #       place (B1-B4) and the one whose deny is already fully explained by the session's own
  #       facts alone (B6) are unaffected. RE-MEASURED for the round-2 kickback: -> 91 pass,
  #       7 fail — unchanged failing set, +2 pass; neither C2 nor D1 depends on the "-C" target
  #       actually resolving to something -- C2 never resolves at all (B4's shape) and D1's own
  #       deny comes from its SECOND, "-C"-less segment. CORRECTED (verifier finding F3): round-1 of
  #       #290 wrongly claimed this recipe was unaffected by the config-candidate list without
  #       measuring it; RE-MEASURED against the #290 114-case push-* set: -> 106 pass, 8 fail — the
  #       same seven cases plus push-deny-c-target-global-route: that fixture's SESSION deliberately
  #       resolves NO repo at all (see the dated .claude/LESSONS.md entry), so the "-C" TARGET's own
  #       resolution -- which this mutant disables entirely -- is the ONLY path to its deny.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 108 pass, 8 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture uses
  #       "-C" at all)
  #   M47 the tokenizer's emitted "-C" field forced empty unconditionally -- a different code site
  #       than M46 (the awk tokenizer rather than the bash resolution function), with the same
  #       observable effect: apply_c_target() never receives a real value to resolve.
  #   M48-M50 (the is_c_target_path() predicate call removed from apply_c_target(); the tokenizer's
  #       "-C" match widened to also capture the ATTACHED "-C<path>" form; the tokenizer's
  #       exactly-one-"-C" guard widened to "one or more") each killed a push-noop-c-* fixture that
  #       #292 replaced with a DENY fixture of the same shape (push-noop-c-nonsibling-path/
  #       -attached-form/-double-c -> push-unres-deny-c-nonsibling-path/-c-attached-form/-c-double-c);
  #       their mechanism is now pinned instead by the dev/mutants/hook-tests.json
  #       292-pg-c-nonwt/292-pg-attached-c/292-pg-multi-c records (run via dev/mutant-driver.sh, the
  #       #359 registry idiom, not this prose table).
  #   M51 the resolved current branch not applied (current_branch="$resolved_current" ->          -> 93 pass,
  #       current_branch="$session_current_branch")                                                3 fail
  #       (kills push-deny-c-sibling-wt-bare-on-default (the n<=1 current-branch check reads the
  #       SESSION's claude/17-a instead of the resolved worktree's own develop), push-deny-c-
  #       sibling-wt-head-refspec (the same substitution feeding refspec_dest()'s HEAD case), and
  #       push-noop-c-sibling-wt-session-on-default (the session's own main, which IS its own
  #       default, wrongly denies instead of the worktree's non-default claude/17-a); does NOT
  #       kill push-deny-c-other-repo-explicit-develop or push-deny-c-never-executes, whose denial
  #       comes from an EXPLICIT refspec destination, never current_branch. RE-MEASURED for the
  #       round-2 kickback: -> 95 pass, 3 fail — unchanged failing set, +2 pass; C2 never reaches
  #       this mutated line at all (its "-C" target never resolves a gitdir, so apply_c_target()
  #       returns before reaching it) and D1's own deny doesn't depend on current_branch either.
  #       RE-MEASURED against the #290 114-case push-* set: -> 111 pass, 3 fail — UNCHANGED failing
  #       set, +16 pass. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT
  #       116-case push-* set: -> 113 pass, 3 fail — UNCHANGED failing set, +2 pass; neither new
  #       kickback fixture uses "-C" at all)
  #   M52 an unresolvable "-C" target clears the session's facts instead of degrading             -> 95 pass,
  #       ([ -n "$gitdir" ] || { apply_session_repo; return 0; } -> [ -n "$gitdir" ] || return 0)   1 fail
  #       (kills only push-deny-c-unresolvable-degrades -- resolve_repo()'s own internal reset
  #       already blanks current_branch/cfg_* unconditionally before this check runs, so skipping
  #       the restore silently drops the SESSION's own current branch, a bare push's only
  #       remaining deny route, for a target that was never actually resolved; deny_set itself is
  #       untouched by this mutant either way, so a fixture depending on an EXPLICIT refspec
  #       destination rather than current_branch cannot discriminate it -- why this fixture is a
  #       bare push, not push origin <branch>. RE-MEASURED for the round-2 kickback: -> 96 pass,
  #       2 fail — GAINS push-deny-c-unresolvable-never-executes (C2), the #269 round-2 kickback's
  #       own B4-shaped fixture: C2 shares this exact mechanism, a bare push whose only deny route
  #       is the SESSION's own current_branch after a failed "-C" resolution, so this pre-existing
  #       mutant discriminates it identically to B4, with no code having moved for this addition.
  #       RE-MEASURED against the #290 114-case push-* set: -> 112 pass, 2 fail — UNCHANGED failing
  #       set, +16 pass. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT
  #       116-case push-* set: -> 114 pass, 2 fail — UNCHANGED failing set, +2 pass; neither new
  #       kickback fixture uses "-C" at all)
  #   M53 the deny-set union narrowed to fallback ∪ resolved only (the session's own default       -> 95 pass,
  #       branch line dropped from the union)                                                      1 fail
  #       (kills only push-deny-c-session-default-union -- the fixture whose deny is explained
  #       SOLELY by the session's own default branch staying in the union; every other deny
  #       fixture's session default either equals the resolved default already (A1/A3/B4) or is
  #       not what explains the deny at all (A2/A4/C1, decided by the RESOLVED default or config).
  #       RE-MEASURED for the round-2 kickback: -> 97 pass, 1 fail — unchanged failing set, +2
  #       pass; C2 never reaches this mutated line (its "-C" target never resolves) and D1's deny
  #       comes from its config-driven second segment, not this union. RE-MEASURED against the #290
  #       114-case push-* set: -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass. RE-MEASURED
  #       again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass,
  #       1 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture uses "-C" at all)
  #   M54 the resolved config not applied (the three cfg_push_lines/cfg_push_defaults/            -> 94 pass,
  #       cfg_branch_merge assignments re-pointed at the session_* copies instead of the            2 fail
  #       resolved_* locals -- #290 RE-POINTED: the middle assignment's variable name itself
  #       renamed, cfg_push_default -> cfg_push_defaults, same mutation intent)
  #       (kills push-deny-c-other-repo-config-route and push-noop-c-other-repo-ignores-session-
  #       config -- the only two fixtures whose verdict is decided by which checkout's config
  #       applies. RE-MEASURED for the round-2 kickback: -> 96 pass, 2 fail — unchanged failing
  #       set, +2 pass; neither C2 (no config at all) nor D1's second segment (cpath empty, an
  #       early return well before this mutated line) reaches this code. RE-MEASURED again for
  #       #290 (with the renamed variable) against the 114-case push-* set: -> 111 pass,
  #       3 fail — the same two historical cases plus ONE of the sixteen new #290 fixtures,
  #       push-deny-c-target-global-route, whose SESSION deliberately resolves to NO repo at all
  #       (so session_cfg_push_lines is empty), unlike every #269 "-C" deny fixture's session,
  #       which always resolves some repo of its own -- this is the one #290 fixture whose verdict
  #       genuinely depends on which checkout's config is applied at this assignment site, not
  #       merely on whether a repo resolved at all. RE-MEASURED again for the #290 ROUND-2 KICKBACK
  #       against the CURRENT 116-case push-* set: -> 113 pass, 3 fail — UNCHANGED failing set, +2
  #       pass; neither new kickback fixture uses "-C" at all)
  #   M55 the resolved default branch omitted from the deny-set union (the                        -> 94 pass,
  #       "[ -n "$resolved_default" ] && deny_set=..." line deleted)                                2 fail
  #       (kills push-deny-c-other-repo-explicit-develop and push-deny-c-never-executes -- the two
  #       fixtures whose deny depends on the RESOLVED checkout's own default branch, "develop",
  #       entering the union; A1/A3/B4's resolved default already equals the session's own, so
  #       dropping it changes nothing for them. RE-MEASURED for the round-2 kickback: -> 96 pass,
  #       2 fail — unchanged failing set, +2 pass; C2 never resolves a default at all and D1's
  #       first segment never denies regardless of this union, see M46 above. RE-MEASURED against
  #       the #290 114-case push-* set: -> 112 pass, 2 fail — UNCHANGED failing set, +16 pass.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 114 pass, 2 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture uses
  #       "-C" at all)
  # #269 round-2 kickback mutants (M56-M57), measured against the 98-case push-* set (the 96-case
  # #269 baseline plus push-deny-c-unresolvable-never-executes (C2) and
  # push-deny-c-per-segment-session-reset (D1), the two fixtures this kickback adds; per finding
  # F3, individually RE-MEASURED (not reasoned about) against both the #290 114-case push-* set and
  # the CURRENT 116-case push-* set, and confirmed genuinely unaffected by every fixture #290 and
  # its own round-2 kickback added):
  #   M56 apply_session_repo() hoisted from inside the driver loop (called once, per segment) to   -> 97 pass,
  #       immediately before the loop (called once, before ANY segment) -- verifier finding: the      1 fail
  #       per-segment reset (acceptance criterion 4, "no leakage between iterations") had no
  #       fixture with more than one push segment
  #       (kills only push-deny-c-per-segment-session-reset (D1) -- its SECOND segment (a bare
  #       "git push", no "-C") must be judged by the SESSION's own config, restored by a FRESH
  #       apply_session_repo() call for that segment; under this mutant, that call never happens
  #       again after the first segment's own "-C" target resolution left current_branch/cfg_*
  #       pointed at the FIRST segment's resolved (config-less) target, so the second segment's
  #       real deny -- via the session's own remote.origin.push=HEAD:main -- is silently lost (rc
  #       2 -> rc 0). No other fixture in this suite has more than one push segment, so D1 is the
  #       only case that can discriminate this mutant. RE-MEASURED against the #290 114-case push-*
  #       set: -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass. RE-MEASURED again for the #290
  #       ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED
  #       failing set, +2 pass; neither new kickback fixture has more than one push segment)
  #   M57 resolve_repo()'s depth-1 ascent guard deleted (the                                       -> 97 pass,
  #       "[ "$((depth + 1))" -lt "$2" ] || break" line removed) -- Note from the #269 round-1        1 fail
  #       verifier: this guard is what keeps the untrusted "-C" path from ever reaching dirname's
  #       argv, and it had no fixture pinning it at all
  #       (kills only push-deny-c-unresolvable-never-executes (C2) -- its "-C" target does not
  #       exist, so resolve_repo() falls through both the "[ -d ... ]" and "[ -f ... ]" checks to
  #       this guard; with the guard intact (MAX_DEPTH=1, depth=0), the loop breaks before ever
  #       calling dirname; with it deleted, dirname IS invoked (measured: C2's booby-trapped
  #       sentinel fires). Does NOT flip C1 (push-deny-c-never-executes), whose "-C" target DOES
  #       exist and resolves a gitdir at depth 0, so C1 never reaches this guard at all regardless
  #       of the mutation -- measured directly: C1 stays sentinel-absent/rc-2 both with the guard
  #       intact and with it deleted. Nor does this mutant change C2's own VERDICT (rc 2 either
  #       way, since the degrade-to-session-facts path is unaffected) -- it pins the SAFETY
  #       property (never reaches an argv), not the verdict, the same division of labor B4/C1
  #       already have for the "-C" route generally. RE-MEASURED against the #290 114-case push-*
  #       set: -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass. RE-MEASURED again for the #290
  #       ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED
  #       failing set, +2 pass; neither new kickback fixture's "-C" target is unresolvable)
  # #290's global-config-candidate mutants (M58-M69), each FIRST measured against the #290
  # 114-case push-* set (the 98-case #269-round-2 baseline plus the sixteen new #290 fixtures
  # directly below); each RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT
  # 116-case push-* set (the 114-case baseline plus push-deny-global-two-defaults-one-file (F1) and
  # push-deny-config-tab-in-value (F4), the two fixtures that kickback adds):
  #   M58 the whole global contribution removed (the config-candidate heredoc's                    -> 103 pass,
  #       $GIT_CONFIG_GLOBAL/$xdg_cfg/$home_cfg lines all deleted, leaving only                      11 fail
  #       $common/config)
  #       (kills ELEVEN of the sixteen new #290 fixtures -- every one whose deny depends on SOME
  #       global candidate resolving: push-deny-global-gitconfig-upstream, push-deny-global-xdg-
  #       upstream, push-deny-global-xdg-home-default-upstream, push-deny-global-env-var-upstream,
  #       push-deny-global-remote-push-refspec, push-deny-global-default-matching, push-deny-
  #       global-overrides-benign-repo-route, push-deny-global-env-var-union-not-replace, push-
  #       deny-global-two-files-first-denies, push-deny-c-target-global-route, and push-deny-
  #       global-never-executes; does NOT kill push-deny-global-benign-does-not-mask-repo-route
  #       (its deny comes from the REPO route alone) or any of the four no-opinion #290 controls.
  #       RE-MEASURED for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 104 pass, 12 fail — the same eleven cases plus push-deny-global-two-defaults-one-file
  #       (F1): its ONLY route is global too; push-deny-config-tab-in-value (F4) is unaffected,
  #       since its route is repo-local)
  #   M59 the $GIT_CONFIG_GLOBAL candidate branch removed (the heredoc's                            -> 112 pass,
  #       "${GIT_CONFIG_GLOBAL:-}" line deleted)                                                      2 fail
  #       (kills push-deny-global-env-var-upstream, whose ONLY denying route is
  #       $GIT_CONFIG_GLOBAL itself (HOME has no .gitconfig), and push-deny-global-two-files-
  #       first-denies, whose $GIT_CONFIG_GLOBAL-pointed file is the denier read FIRST.
  #       RE-MEASURED for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 114 pass, 2 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture uses
  #       $GIT_CONFIG_GLOBAL)
  #   M60 the $HOME/.gitconfig candidate branch removed (the heredoc's "$home_cfg"                  -> 107 pass,
  #       line deleted)                                                                               7 fail
  #       (kills every #290 fixture whose ONLY or FIRST-READ denying route lives at
  #       $HOME/.gitconfig specifically: push-deny-global-gitconfig-upstream, push-deny-global-
  #       remote-push-refspec, push-deny-global-default-matching, push-deny-global-overrides-
  #       benign-repo-route, push-deny-global-env-var-union-not-replace (the "denier read LAST"
  #       fixture -- its denying route lives at $HOME/.gitconfig), push-deny-c-target-global-route,
  #       and push-deny-global-never-executes; does NOT kill push-deny-global-two-files-first-
  #       denies, whose denier is $GIT_CONFIG_GLOBAL, read first and unaffected by this mutant.
  #       RE-MEASURED for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 108 pass, 8 fail — the same seven cases plus push-deny-global-two-defaults-one-file
  #       (F1): its denying record lives at $HOME/.gitconfig specifically too)
  #   M61 the XDG git config candidate branch removed entirely (the heredoc's                       -> 112 pass,
  #       "$xdg_cfg" line deleted)                                                                    2 fail
  #       (kills push-deny-global-xdg-upstream and push-deny-global-xdg-home-default-upstream --
  #       the two fixtures whose ONLY denying route is the XDG candidate, explicit and default-path
  #       respectively. RE-MEASURED for the #290 ROUND-2 KICKBACK against the CURRENT 116-case
  #       push-* set: -> 114 pass, 2 fail — UNCHANGED failing set, +2 pass; neither new kickback
  #       fixture uses the XDG candidate)
  #   M62 the XDG-unset default path removed (the "elif [ -n \"${HOME:-}\" ]; then                  -> 113 pass,
  #       xdg_cfg=\"$HOME/.config/git/config\"; fi" branch deleted)                                   1 fail
  #       (kills only push-deny-global-xdg-home-default-upstream -- the fixture that leaves
  #       $XDG_CONFIG_HOME unset specifically to pin this default-path branch; does NOT kill
  #       push-deny-global-xdg-upstream, which sets $XDG_CONFIG_HOME explicitly and so never
  #       reaches this branch at all. RE-MEASURED for the #290 ROUND-2 KICKBACK against the CURRENT
  #       116-case push-* set: -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; neither new
  #       kickback fixture uses the XDG candidate either)
  #   M63 the per-file loop stopping at the FIRST missing candidate (the "[ -f              -> 85 pass,
  #       \"$cfgf\" ] || continue" line changed to "|| break")                               29 fail
  #       (CORRECTED, verifier finding F2b: round-1 of #290 claimed this mutant kills "every
  #       push-deny-config-* fixture (repo-local routes) plus every push-deny-global-* deny fixture
  #       except push-deny-global-benign-does-not-mask-repo-route" -- measured (not reasoned about)
  #       against the #290 114-case push-* set, the ACTUAL twenty-nine-case failing set is: every
  #       push-deny-config-* fixture (repo-local routes: remote-push-bare, remote-push-named-remote,
  #       remote-push-second-line, push-default-upstream, push-default-tracking, push-default-
  #       matching, wildcard-refspec, crlf-line, crlf-interior, worktree-commondir, no-space-assign,
  #       no-trailing-newline, mixed-case, never-executes, union-benign-refspec-plus-upstream,
  #       union-other-remote-bare -- SIXTEEN total), every push-deny-global-* deny fixture except
  #       push-deny-global-two-files-first-denies (TEN: gitconfig-upstream, xdg-upstream, xdg-
  #       home-default-upstream, env-var-upstream, remote-push-refspec, default-matching, benign-
  #       does-not-mask-repo-route, overrides-benign-repo-route, env-var-union-not-replace, and
  #       never-executes), and THREE push-deny-c-*
  #       fixtures the round-1 claim omitted entirely: push-deny-c-other-repo-config-route,
  #       push-deny-c-per-segment-session-reset, and push-deny-c-target-global-route (each denies
  #       via a config route this mutant's break can also strand, whether on the SESSION's own
  #       resolve_repo() call or a resolved "-C" target's). The actual EXCEPTION is
  #       push-deny-global-two-files-first-denies, not push-deny-global-benign-does-not-mask-repo-
  #       route: with the default fixture HOME (no override) empty, the FIRST non-blank candidate
  #       most fixtures reach is $HOME/.config/git/config (the XDG default path), which does not
  #       exist there, so the loop breaks before ever reaching $HOME/.gitconfig or $common/config
  #       -- a single missing candidate silently disables every LATER candidate in the list,
  #       including the repo-local one; this is exactly the coarse, near-M26-sized failure this
  #       mutant is meant to demonstrate. push-deny-global-two-files-first-denies is spared only
  #       because its $GIT_CONFIG_GLOBAL candidate -- the FIRST non-blank one in the list -- is
  #       itself the denier and already exists, so it is read in full BEFORE the break (at the
  #       next, missing candidate) ever fires; push-deny-global-benign-does-not-mask-repo-route is
  #       NOT spared, since its own denying record lives in the REPO-local $common/config, the
  #       LAST candidate, never reached once the break fires at the second candidate. RE-MEASURED
  #       for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 85 pass, 31
  #       fail — the same twenty-nine cases plus BOTH new kickback fixtures, push-deny-global-two-
  #       defaults-one-file (F1, a global deny fixture reached only past the break point) and
  #       push-deny-config-tab-in-value (F4, a repo-local deny fixture reached only past the break
  #       point too))
  #   M64 the per-file loop stopping AFTER the first EXISTING candidate (an                          -> 106 pass,
  #       unconditional "break" added immediately after "done < \"$cfgf\"")                            8 fail
  #       (kills EIGHT of the sixteen new #290 fixtures, in two mechanically distinct groups sharing
  #       one root cause -- once ANY candidate exists and is read, this mutant stops before reading
  #       every LATER candidate, silently dropping whatever route a later file would have supplied:
  #       (1) FIVE fixtures whose denying push.default=upstream route lives in the SAME single
  #       global file this mutant reads first, but whose DESTINATION resolution also needs
  #       branch.<current>.merge, which lives only in the REPO-local $common/config, always the
  #       LAST candidate and so never reached: push-deny-global-gitconfig-upstream, push-deny-
  #       global-xdg-upstream, push-deny-global-xdg-home-default-upstream, push-deny-global-env-
  #       var-upstream, and push-deny-global-overrides-benign-repo-route (the GLOBAL upstream
  #       record denies, but its branch.merge lives in the repo config, never reached); (2) THREE
  #       fixtures whose FIRST EXISTING candidate is a BENIGN file, with the actual denying route
  #       in a LATER candidate this mutant never reaches: push-deny-global-benign-does-not-mask-
  #       repo-route (the GLOBAL file read first is benign "current"; the REPO's own denying
  #       "upstream" in $common/config, read last, is never reached), push-deny-global-env-var-
  #       union-not-replace ($GIT_CONFIG_GLOBAL, read first, is benign; $HOME/.gitconfig's denying
  #       remote route is never reached), and push-deny-global-never-executes (same class as group
  #       1 -- listed separately only because its own case also pins the never-executes property).
  #       Does NOT kill push-deny-global-remote-push-refspec or push-deny-global-default-matching
  #       (each fixture's ONE route is fully self-contained in the single file this mutant DOES
  #       read -- neither remote.<name>.push nor push.default=matching ever consults
  #       branch.<current>.merge), push-deny-global-two-files-first-denies (its denying
  #       $GIT_CONFIG_GLOBAL file IS the first existing candidate, already fully read before the
  #       break fires), or push-deny-c-target-global-route (the "-C" TARGET's own resolve_repo()
  #       call finds its one denying $HOME/.gitconfig record as the first existing candidate,
  #       already fully read; its target has no local config of its own to lose). RE-MEASURED for
  #       the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 107 pass, 9 fail —
  #       the same eight cases plus push-deny-global-two-defaults-one-file (F1): its denying record
  #       is read as the first EXISTING candidate ($HOME/.gitconfig), so this mutant's break fires
  #       immediately after it, before ever reaching $common/config for cfg_branch_merge -- group
  #       (1)'s exact mechanism; push-deny-config-tab-in-value (F4) is unaffected, since it is
  #       repo-local and never reaches a global candidate at all)
  #   M65 cfg_push_defaults collapsed to a last-wins SCALAR (the accumulating                        -> 113 pass,
  #       "cfg_push_defaults=\"${cfg_push_defaults}...\"" assignment narrowed to a plain              1 fail
  #       overwrite, "cfg_push_defaults=\"${cfg_src}...\"", dropping the leading
  #       "${cfg_push_defaults}" so only the LAST "[push] default = ..." line parsed survives)
  #       (kills only push-deny-global-overrides-benign-repo-route -- its LAST-parsed push.default
  #       record (the REPO's own, benign "current", read after the GLOBAL's denying "upstream" in
  #       file-list order) silently overwrites the denying one under this mutant; does NOT kill
  #       push-deny-global-benign-does-not-mask-repo-route, whose LAST-parsed record (the REPO's
  #       own denying "upstream") already IS the one that must survive, so a last-wins collapse is
  #       inert for it. RE-MEASURED for the #290 ROUND-2 KICKBACK against the CURRENT 116-case
  #       push-* set: -> 114 pass, 2 fail — the same case plus push-deny-global-two-defaults-
  #       one-file (F1, finding F1's own discriminating mutant): its FIRST-accumulated record (the
  #       GLOBAL file's own "upstream", read before that SAME file's later "current" line) is what
  #       must survive to deny; under a last-wins collapse, only the LAST line parsed overall
  #       survives, which (no OTHER push.default record exists in this fixture) is that same file's
  #       own "current" -- silently losing the deny. push-deny-config-tab-in-value (F4) is
  #       unaffected, since it uses remote.<name>.push, never push.default, at all)
  #   M66 config_deny()'s push-default loop evaluating only the FIRST value (an                      -> 113 pass,
  #       unconditional "break" added at the end of the while loop's body, right                       1 fail
  #       before "done <<CFGEOF")
  #       (kills only push-deny-global-benign-does-not-mask-repo-route -- its FIRST-accumulated
  #       record (the GLOBAL's benign "current") is evaluated and the loop stops there, never
  #       reaching the REPO's own denying "upstream" record that follows it; does NOT kill push-
  #       deny-global-overrides-benign-repo-route, whose FIRST-accumulated record (the GLOBAL's
  #       denying "upstream") already denies on its own, so stopping after it changes nothing.
  #       RE-MEASURED for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; push-deny-global-two-defaults-
  #       one-file's own FIRST-accumulated record ("upstream") already denies on its own, so
  #       stopping after it (as this mutant does) changes nothing for that fixture either -- the
  #       same reason push-deny-global-overrides-benign-repo-route is unaffected)
  #   M67 __deny_src forced to ".git/config" unconditionally (the case "$cfgf"                       -> 113 pass,
  #       in ... esac source-label arms both assign ".git/config")                                    1 fail
  #       (kills only push-deny-global-gitconfig-upstream -- the fixture whose inline assertion
  #       checks the deny message names the GLOBAL label, "your global git config"; every other
  #       fixture either asserts no source label at all or (push-deny-global-benign-does-not-mask-
  #       repo-route) asserts ".git/config", which this mutant does not disturb. RE-MEASURED for
  #       the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 114 pass, 2 fail —
  #       the same case plus push-deny-global-two-defaults-one-file (F1): its own inline assertion
  #       likewise checks the GLOBAL label, "your global git config", which this mutant never
  #       produces)
  #   M68 __deny_src forced to "your global git config" unconditionally (the case                    -> 113 pass,
  #       "$cfgf" in ... esac source-label arms both assign "your global git config")                 1 fail
  #       (kills only push-deny-global-benign-does-not-mask-repo-route -- the fixture whose inline
  #       assertion checks the deny message names the REPO label, ".git/config"; does NOT kill
  #       push-deny-global-gitconfig-upstream, whose own inline assertion checks the GLOBAL label,
  #       which this mutant still produces. RE-MEASURED for the #290 ROUND-2 KICKBACK against the
  #       CURRENT 116-case push-* set: -> 114 pass, 2 fail — the same case plus push-deny-config-
  #       tab-in-value (F4): its own inline assertion checks the REPO-LOCAL label, ".git/config",
  #       which this mutant never produces; push-deny-global-two-defaults-one-file (F1) is
  #       unaffected, since its own inline assertion checks the GLOBAL label, which this mutant
  #       still produces)
  #   M69 the global candidates dropped for a resolved "-C" segment specifically                     -> 113 pass,
  #       (immediately after computing $home_cfg, "if [ \"$2\" = \"1\" ]; then                        1 fail
  #       GIT_CONFIG_GLOBAL=\"\"; xdg_cfg=\"\"; home_cfg=\"\"; fi" -- MAX_DEPTH is exactly
  #       "1" only on the per-"-C"-segment resolve_repo() call, never the session's own
  #       MAX_DEPTH-64 call)
  #       (kills only push-deny-c-target-global-route -- the one #290 fixture whose SESSION
  #       deliberately resolves to NO repo at all (so it independently reads no global config of
  #       its own), isolating that the deny comes SOLELY from the "-C" TARGET's own resolution
  #       reading the same global files; every other #290 fixture's session DOES resolve an
  #       ordinary repo, so it would independently pick up the identical global route regardless of
  #       this mutant, which is exactly why this fixture's session was deliberately built with no
  #       repo at all -- see this fixture's own case_pd_c_target_global_route() comment. RE-MEASURED
  #       for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1
  #       fail — UNCHANGED failing set, +2 pass; neither new kickback fixture uses "-C" at all)
  # M70 (below, the #290 ROUND-2 KICKBACK's own new mutant, finding F4) reverts BOTH sites of the
  # F4 field-order fix together -- the cfg_push_lines record write (back to
  # "${cfg_subsection}${cfg_tab}${cfg_val}${cfg_tab}${cfg_src}") and config_deny()'s split (back to
  # reading sub/refspec/src in that order, with refspec bounded and src the unbounded tail) -- since
  # reverting only one site while the other still reads/writes the NEW order would misinterpret
  # every field, not just corrupt the source label the way the original defect did:
  #   M70 F4's field-order fix reverted (cfg_push_lines record back to                               -> 115 pass,
  #       "sub<TAB>val<TAB>src", both the write in the "remote" case arm and the read              1 fail
  #       in config_deny(), together)
  #       (kills only push-deny-config-tab-in-value (F4) -- with src back on the record's UNBOUNDED
  #       tail, the value's own embedded TAB byte again truncates the BOUNDED refspec field at that
  #       TAB and leaks its own remainder ("junklabel") into the source-label field, exactly the
  #       pre-fix defect finding F4 named; no other fixture's config value contains a literal TAB
  #       byte, so this mutant is inert for every one of them)
  # Nine fixtures (measured against the #260 56-case baseline) are, verified by direct measurement,
  # NOT flipped by any of M1-M22: their
  # destination never coincides with a deny-set member under any of these mutants (the two
  # release-blocker positive controls this harness itself issues, an ordinary feature/release/tag
  # branch, a fixture repo whose current branch is a non-default claude/<n>-<slug> branch, a
  # detached HEAD, cwd resolving to no repo at all, and the malformed-JSON control, whose failure
  # mode is jq's own parse error regardless of which downstream check runs); their comment below
  # says so instead of citing a mutant that was never observed to fail them. push-noop-crlf-feature
  # (#270) is a TENTH no-opinion fixture, measured only against M23-M25 (it did not exist when
  # M1-M22 were run): under each of those three mutants the destination stays a non-deny-set value
  # ("feature/x<CR>" under M23, "feature/x" under M24/M25), so "no opinion" is the verdict either
  # way. push-noop-config-neither-key (#268) is an ELEVENTH no-opinion fixture never flipped by
  # any mutant in this table, measured against M26-M45 (the #268 round-2 kickback's M43/M44 and
  # the round-3 kickback's M45 included -- none of the three appeared in its governing mutant's
  # one-case failing set, measured directly): its config sets neither remote.<name>.push nor
  # push.default at all, so every one of those twenty mutants changes behaviour only inside code
  # this fixture's own config never reaches; its row states this instead of citing a mutant that
  # was never observed to fail it.
  # #327: the cdg-* section further below runs ONLY hooks/claude-dir-guard.sh, via its own
  # run_claude_guard -- no mutant M1-M70 in THIS table edits that file, so this table's recorded
  # failing sets are unchanged by that addition, and its whole-file PASS figures above all predate
  # it. Made non-vacuous, not just reasoned by inspection (LESSON 2026-09-15): M16
  # (PUSH_DEFAULT_BRANCH_FALLBACK emptied) re-run against the then-current 230-case file (re-measured
  # after the #327 round-1 kickback's two new cdg-* fixtures) still fails exactly
  # push-deny-origin-master/push-deny-c-per-segment-session-reset/push-deny-c-target-global-route
  # (227 pass, 3 fail) with NO cdg-* case among them.
  "push-deny-origin-main|case_pd_origin_main|deny: git push origin main (the plain form) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-head-colon-main|case_pd_head_colon_main|deny: git push origin HEAD:main (HEAD substituted via the current branch, then the dest side of the colon read directly) -- measured: M1/M2, 23 pass 33 fail (also M11, 50 pass 6 fail)"
  "push-deny-plus-head-refs-main|case_pd_plus_head_refs|deny: git push origin +HEAD:refs/heads/main (leading + stripped, refs/heads/ prefix stripped) -- measured: M1/M2, 23 pass 33 fail (also M11 and M13, each 50/54 pass)"
  "push-deny-nonorigin-remote|case_pd_nonorigin_remote|deny: git push upstream HEAD:main (remote other than origin is never itself evaluated as a destination) -- measured: M1/M2, 23 pass 33 fail (also M11, 50 pass 6 fail)"
  "push-deny-url-remote-colon|case_pd_url_remote_colon|deny: git push git@github.com:o/r.git HEAD:main (a URL remote containing a colon is skipped as tokens[0], never evaluated as a destination) -- measured: M1/M2, 23 pass 33 fail (also M11, 50 pass 6 fail)"
  "push-deny-refspec-full|case_pd_refspec_full|deny: git push origin refs/heads/x:refs/heads/main (full src:dst refspec, dst read after the FIRST colon) -- measured: M1/M2, 23 pass 33 fail (also M11 and M13, each 50/54 pass)"
  "push-deny-colon-main|case_pd_colon_main|deny: git push origin :main (empty source, dest read after the colon) -- measured: M1/M2, 23 pass 33 fail (also M11, 50 pass 6 fail)"
  "push-deny-delete-main|case_pd_delete_main|deny: git push origin --delete main (--delete is skipped as an ordinary dashed option) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-opt-before-remote|case_pd_opt_before_remote|deny: git push --force origin main (option BEFORE the remote) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-opt-after-refspec|case_pd_opt_after_refspec|deny: git push origin main --force (option AFTER the refspec) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-o-one|case_pd_o_one|deny: git push -o ci.skip origin main (ONE -o value occurrence, skipped as a pair) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-o-two|case_pd_o_two|deny: git push -o a -o b origin main (TWO -o value occurrences, the 0/1/2+ boundary -- LESSON 2026-09-08d) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-all|case_pd_all|deny: git push --all origin (unconditional -- pushes every ref, including the default branch) -- measured: M1/M2, 23 pass 33 fail (also M8, 54 pass 2 fail)"
  "push-deny-mirror|case_pd_mirror|deny: git push --mirror origin (unconditional, same reason as --all) -- measured: M1/M2, 23 pass 33 fail (also M8, 54 pass 2 fail)"
  "push-deny-c-worktree|case_pd_c_worktree|deny: git -C ../demo-wt-1 push origin main (the exact form hooks/git-c-guard.sh's own allow cases approve -- composition with that hook's allow was NOT re-measured, see hooks/hooks.json's .description) -- measured: M1/M2, 23 pass 33 fail (also M6, 53 pass 3 fail)"
  "push-deny-composite-and|case_pd_composite_and|deny: pytest && git push origin main (second && segment) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-prefix-one|case_pd_prefix_one|deny: env git push origin main (ONE PREFIX_WORDS token) -- measured: M1/M2, 23 pass 33 fail (also M5, 54 pass 2 fail)"
  "push-deny-prefix-two|case_pd_prefix_two|deny: sudo bash -c \"git push origin main\" (TWO chained PREFIX_WORDS tokens -- the M23 class) -- measured: M1/M2, 23 pass 33 fail (also M5, 54 pass 2 fail; also M7, 55 pass 1 fail)"
  "push-deny-assignment|case_pd_assignment|deny: FOO=1 git push origin main (assignment-prefix skip) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-abs-path|case_pd_abs_path|deny: /usr/bin/git push origin main (basename normalisation) -- measured: M1/M2, 23 pass 33 fail (also M21, 55 pass 1 fail)"
  "push-deny-global-opt-value|case_pd_global_opt_value|deny: git -c core.pager=cat push origin main (ONE git global option with a separate value before the subcommand) -- measured: M1/M2, 23 pass 33 fail (also M6, 53 pass 3 fail)"
  "push-deny-global-opt-two|case_pd_global_opt_two|deny: git -c core.pager=cat -C ../demo-wt-1 push origin main (TWO chained global-option-with-value pairs, the 0/1/2+ boundary -- LESSON 2026-09-08d) -- measured: M1/M2, 23 pass 33 fail (also M6, 53 pass 3 fail)"
  "push-deny-origin-master|case_pd_origin_master|deny: git push origin master (the second PUSH_DEFAULT_BRANCH_FALLBACK member) -- measured: M1/M2, 23 pass 33 fail (also M16, 55 pass 1 fail)"
  "push-deny-n1-refspec|case_pd_n1_refspec|deny: git push main against a fixture repo whose current branch is feature/x (n==1 -- the single argument is ALSO evaluated as a refspec destination, isolated from a real, non-denying current branch) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-crlf-dest|case_pd_crlf_dest|deny: git push origin main<CR> (#270, the exact command the issue measured -- isolates the destination compare, which goes through strip_quotes()+is_deny_member, not normalize()) -- measured: M23, 57 pass 3 fail (with push-deny-crlf-interior and push-deny-crlf-cmdword); NOT flipped by M24 or M25 (its one CR is both the first and the last, so either a trailing-only or a once-only strip removes it too)"
  "push-deny-crlf-interior|case_pd_crlf_interior|deny: echo a<CR> && git push origin main<CR> && echo b<CR> (#270, three CRs, the verdict-bearing one (second) neither first nor last -- distinguishes a global strip from both a trailing-only AND a once-only strip) -- measured: M23, 57 pass 3 fail (with push-deny-crlf-dest and push-deny-crlf-cmdword); M24 (trailing-only), 58 pass 2 fail (with push-deny-crlf-cmdword); M25 (once-only), 59 pass 1 fail (this case alone)"
  "push-deny-crlf-cmdword|case_pd_crlf_cmdword|deny: git<CR> push origin main (#270, isolates normalize() on the command word -- the site the issue's filed shape names, and which alone would not fix the issue's own measured command) -- measured: M23, 57 pass 3 fail (with push-deny-crlf-dest and push-deny-crlf-interior); also M24 (trailing-only), 58 pass 2 fail (with push-deny-crlf-interior) -- its one CR is not the command's final byte, so a trailing-only strip leaves it in place; NOT flipped by M25 (its one CR is also the only/first one, so a once-only strip removes it too)"
  "push-deny-trunk-base|case_pd_trunk_base|deny: git push origin trunk against a fixture repo whose refs/remotes/origin/HEAD symref names trunk (default-branch resolution, base cwd) -- measured: M1/M2, 23 pass 33 fail (also M15, 53 pass 3 fail)"
  "push-deny-trunk-subdir|case_pd_trunk_subdir|deny: same trunk fixture repo, cwd a SUBDIRECTORY of it (the upward .git walk) -- measured: M1/M2, 23 pass 33 fail (also M15, 53 pass 3 fail; also M18, 55 pass 1 fail)"
  "push-deny-trunk-worktree|case_pd_trunk_worktree|deny: same trunk default branch, cwd a WORKTREE POINTER FILE (gitdir: ... resolution, common-dir derivation) -- measured: M1/M2, 23 pass 33 fail (also M15, 53 pass 3 fail; also M17, 55 pass 1 fail)"
  "push-deny-head-on-main|case_pd_head_on_main|deny: git push origin HEAD against a fixture repo whose HEAD is main (current-branch resolution, HEAD substitution) -- measured: M1/M2, 23 pass 33 fail (also M12, 55 pass 1 fail; also M14, 54 pass 2 fail)"
  "push-deny-bare-on-main|case_pd_bare_on_main|deny: bare git push against the same HEAD-is-main fixture repo (n==0, destination is the current branch) -- measured: M1/M2, 23 pass 33 fail (also M14, 54 pass 2 fail)"
  "push-deny-no-cwd-fallback|case_pd_no_cwd_fallback|deny: git push origin main with NO cwd key at all in stdin (must still deny via the unconditional fallback) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-plus-main-no-colon|case_pd_plus_main_no_colon|deny: git push origin +main (colon-LESS forced refspec -- isolates the leading-+ strip from the colon-split) -- measured: M1/M2, 23 pass 33 fail (also M10, 55 pass 1 fail)"
  "push-noop-upstream-claude|case_pn_push_upstream_claude|no opinion: git push -u origin \"claude/17-a\" (the exact shape skills/issue-implementer/SKILL.md:527 issues -- a deny here is a release blocker) -- measured: not flipped by M1-M22 (destination \"claude/17-a\" never coincides with a deny-set member under any of these mutants)"
  "push-noop-c-upstream-claude|case_pn_c_push_upstream_claude|no opinion: git -C ../demo-wt-1 push -u origin \"claude/17-a\" (the exact shape worktree-mode.md:201 issues -- a deny here is a release blocker) -- measured: not flipped by M1-M22, same reason as push-noop-upstream-claude"
  "push-noop-release-branch|case_pn_release_branch|no opinion: git push origin release/v2.7.1 (this repo's own release-ritual branch shape) -- measured: not flipped by M1-M22 (destination never coincides with a deny-set member under any of these mutants)"
  "push-noop-tag-shaped-version|case_pn_tag_shaped_version|no opinion: git push origin v2.7.0 (a tag-shaped destination, not the default branch) -- measured: not flipped by M1-M22, same reason as push-noop-release-branch"
  "push-noop-feature-branch|case_pn_feature_branch|no opinion: git push origin feature/x (an ordinary feature branch) -- measured: not flipped by M1-M22, same reason as push-noop-release-branch"
  "push-noop-main-ish|case_pn_main_ish|no opinion: git push origin main-ish (exact match required, not a prefix match) -- measured: M19, 55 pass 1 fail"
  "push-noop-refs-tags|case_pn_refs_tags|no opinion: git push origin refs/tags/v1.0 (a tag ref is skipped, never a branch destination) -- measured: M20, 56 pass 0 fail (NOT flipped -- see the table header note on M20)"
  "push-noop-head-on-claude|case_pn_head_on_claude|no opinion: git push origin HEAD against a fixture repo whose HEAD is claude/17-a (current branch resolves, but isn't in the deny set) -- measured: not flipped by M1-M22 (the resolved destination \"claude/17-a\" never coincides with a deny-set member under any of these mutants, including M12/M14's HEAD-substitution mutants, which only affect the SEPARATE push-deny-head-on-main fixture's fixture repo)"
  "push-noop-bare-on-claude|case_pn_bare_on_claude|no opinion: bare git push against the same claude/17-a fixture repo -- measured: not flipped by M1-M22, same reason as push-noop-head-on-claude"
  "push-noop-bare-detached|case_pn_bare_detached|no opinion: bare git push against a fixture repo with a DETACHED HEAD (current branch unresolvable -- a documented limit, not denied) -- measured: not flipped by M1-M22 (current_branch is already empty by construction here, so M14's force-empty mutant changes nothing observable)"
  "push-noop-trunk-no-repo|case_pn_trunk_no_repo|no opinion: git push origin trunk with cwd resolving to NO repo at all (the 64-level upward walk finds nothing; falls back to the fallback set alone, which trunk isn't in) -- measured: not flipped by M1-M22 (no .git is ever found here, so M15/M17/M18's resolution mutants change nothing observable)"
  "push-noop-grep-arg|case_pn_grep_arg|no opinion: grep -rn \"git push origin main\" . (git/push as grep's own argument, never a command word) -- measured: not flipped by M1-M22 (the command-word AND subcommand checks both independently require an exact \"git\"/\"push\" resolution; no single-clause mutant here defeats both layers at once)"
  "push-noop-bash-script|case_pn_bash_script|no opinion: bash hooks/push-guard.sh # not a git push (basename contains, but isn't, \"git\"; the trailing comment supplies the raw-stdin \"git\" literal so this case actually reaches the tokenizer) -- measured: not flipped by M1-M22, including M21 (removing the basename step here still leaves the FULL path \"hooks/push-guard.sh\", not \"git\") and M5/M7 (PREFIX_WORDS emptied or made once-only still leaves the resolved command word as \"bash\" or \"push-guard.sh\", neither \"git\")"
  "push-noop-plan-mode|case_pr_plan_mode|role-agnostic no opinion: git push origin main under permission_mode: \"plan\" -- measured: M4, 55 pass 1 fail"
  "push-noop-wrong-tool|case_pr_wrong_tool|role-agnostic no opinion: tool_name is \"Read\", not \"Bash\" -- measured: M3, 55 pass 1 fail"
  "push-noop-malformed-json|case_pr_malformed_json|role-agnostic no opinion: unparseable stdin (carries both push and git substrings) -- measured: not flipped by M1-M22, including M3/M4 (jq's own parse failure independently yields empty extractions regardless of which downstream check runs)"
  "push-noop-missing-command|case_pr_missing_command|role-agnostic no opinion: tool_input.command absent -- measured: M22, 55 pass 1 fail"
  "push-never-executes-deny|case_push_never_executes_deny|deny, AND push-guard.sh never invokes git/gh/rm on the booby-trapped PATH — sentinel absent -- measured: M1/M2, 23 pass 33 fail"
  "push-never-executes-noop|case_push_never_executes_noop|no opinion, AND push-guard.sh never invokes git/gh/rm on the booby-trapped PATH — sentinel absent -- measured: not flipped by M1-M22 (its command's destination, feature/x, never coincides with a deny-set member under any of these mutants)"
  "push-never-executes-reads-only|case_push_reads_only|deny, AND a fixture repo's recursive file listing is byte-identical before/after — this hook reads the filesystem but never writes to it -- measured: M1/M2, 23 pass 33 fail"
  "push-noop-o-value-two-token-remote|case_pn_o_value_two_token_remote|no opinion: git push -o v main other (isolates PUSH_OPTS_WITH_VALUE's two-token skip: main lands as the never-evaluated remote, not a refspec) -- measured: M9, 55 pass 1 fail"
  "push-noop-crlf-feature|case_pn_crlf_feature|no opinion: git push origin feature/x<CR> (#270 -- the strip does not widen the deny set; exact match still required) -- measured: not flipped by M23, 57 pass 3 fail; also not flipped by M24, 58 pass 2 fail, or M25, 59 pass 1 fail (destination stays feature/x<CR> or feature/x under every one of these mutants, still not a deny-set member, so no opinion either way)"
  # --- #269: "git -C <path> push" resolution, gated on the shared PATH_ERE predicate -----------
  "push-deny-c-sibling-wt-bare-on-default|case_pd_c_sibling_wt_bare_on_default|deny: git -C ../<repo>-wt-1 push, session default develop/HEAD claude/17-a, sibling worktree ALSO on develop (A1 -- isolates the n<=1 current-branch check on the RESOLVED checkout) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M51, 93 pass 3 fail)"
  "push-deny-c-other-repo-explicit-develop|case_pd_c_other_repo_explicit_develop|deny: git -C ../other-checkout-wt-1 push origin develop, session default main/HEAD claude/17-a, a SEPARATE repo's own default is develop (A2, the issue's own headline shape) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M55, 94 pass 2 fail)"
  "push-deny-c-sibling-wt-head-refspec|case_pd_c_sibling_wt_head_refspec|deny: as A1 but push origin HEAD (A3 -- isolates refspec_dest()'s HEAD substitution on the RESOLVED checkout's current branch) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M51, 93 pass 3 fail)"
  "push-deny-c-other-repo-config-route|case_pd_c_other_repo_config_route|deny: git -C <abs>/target-wt-1 push (absolute-path form), target's config denies via remote.origin.push=HEAD:main, SESSION has no config at all (A4) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M54, 94 pass 2 fail)"
  "push-noop-c-other-repo-ignores-session-config|case_pn_c_other_repo_ignores_session_config|no opinion: git -C ../target-a5-wt-1 push, SESSION config denies via push=HEAD:main but the resolved segment must ignore it (A5, documented narrowing -- measured pre-#269: deny) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M54, 94 pass 2 fail)"
  "push-deny-c-unresolvable-degrades|case_pd_c_unresolvable_degrades|deny: git -C ../missing-wt-9 push (bare), path matches the shape but nothing exists there, session HEAD ON its own default (develop) -- degrades to the session's own facts, never clears them (B4, unchanged verdict) -- measured: M52, 95 pass 1 fail"
  "push-noop-c-sibling-wt-session-on-default|case_pn_c_sibling_wt_session_on_default|no opinion: git -C ../repo-c-b5-wt-1 push, session ITSELF on its own default (main), sibling worktree on claude/17-a (B5, documented narrowing, worktree-parallel mode's real shape -- measured pre-#269: deny) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M51, 93 pass 3 fail)"
  "push-deny-c-session-default-union|case_pd_c_session_default_union|deny: git -C ../target-b6-wt-1 push origin develop, session default develop, target's OWN default is trunk (B6 -- measured pre-#269: ALREADY denies via the session's own deny set alone; this fixture's value is as the M53 discriminator, not a Today-vs-After widening) -- measured: M53, 95 pass 1 fail"
  "push-deny-c-never-executes|case_pd_c_never_executes|deny via the -C resolution route, AND push-guard.sh never invokes git/gh/rm/dirname on the booby-trapped PATH, AND BOTH the session repo's and the resolved -C target's file listings are byte-identical before/after (C1, A2's shape; \"dirname\" added to the trap in the #269 round-2 kickback, harmless here since this fixture's -C target resolves at depth 0 -- see M57 below and C2) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M55, 94 pass 2 fail); NOT flipped by M57 (measured: 97 pass 1 fail against the 98-case set, not re-measured for #290 -- this fixture's -C target resolves at depth 0 and never reaches the ascent guard M57 removes; see C2 below, which does)"
  "push-deny-c-unresolvable-never-executes|case_pd_c_unresolvable_never_executes|deny (degrades to the session's own facts, B4's shape) via the -C resolution route, AND push-guard.sh never invokes git/gh/rm/dirname on the booby-trapped PATH (C2, #269 round-2 kickback -- pins the depth-1 ascent guard resolve_repo() would otherwise call dirname past, unlike C1 whose target resolves at depth 0 and never reaches that code) -- measured: M57, 97 pass 1 fail (also M14, 89 pass 9 fail; M15, 88 pass 10 fail; M52, 96 pass 2 fail -- all four discriminate this fixture, mirroring B4's exact dependency on the session's own current_branch/default_branch after a failed -C resolution)"
  "push-deny-c-per-segment-session-reset|case_pd_c_per_segment_session_reset|deny: TWO push segments -- git -C ../other-d1-wt-1 push origin claude/99-z (resolves, no opinion on its own) && git push (bare, no -C) -- the SECOND segment must be judged by the SESSION's own config (push=HEAD:main), not by whatever the first segment's -C target left behind (D1, #269 round-2 kickback -- acceptance criterion 4's per-segment reset had no multi-segment fixture) -- measured: M56, 97 pass 1 fail (also M26, 80 pass 18 fail -- the SAME session-config mechanism push-deny-config-remote-push-bare uses, see M26's own table entry)"
  # --- unresolvable push target (#292) -----------------------------------------------------------
  "push-unres-deny-c-nonsibling-path|case_pu_deny_c_nonsibling_path|deny: git -C ../other-checkout push origin develop, no -wt-<n> suffix at all -- B1's shape, denied as unresolved -- mutation proof: dev/mutants/hook-tests.json (292-pg-c-nonwt)"
  "push-unres-deny-c-attached-form|case_pu_deny_c_attached_form|deny: git -C../other-checkout-b2-wt-1 push origin develop, the ATTACHED -C<path> form -- B2's shape, denied as unresolved -- mutation proof: dev/mutants/hook-tests.json (292-pg-attached-c)"
  "push-unres-deny-c-double-c|case_pu_deny_c_double_c|deny: git -C ../benign-wt-1 -C ../other-checkout-b3-wt-1 push origin develop, TWO -C tokens -- B3's shape, denied as unresolved -- mutation proof: dev/mutants/hook-tests.json (292-pg-multi-c)"
  "push-unres-deny-git-dir-attached|case_pu_deny_git_dir_attached|deny: git --git-dir=../other-u4/.git push origin develop -- mutation proof: dev/mutants/hook-tests.json (292-pg-repo-opts-attached, 292-pg-repo-opts-vocab)"
  "push-unres-deny-git-dir-detached|case_pu_deny_git_dir_detached|deny: git --git-dir ../other-u5/.git push origin develop -- mutation proof: dev/mutants/hook-tests.json (292-pg-repo-opts-detached, 292-pg-repo-opts-vocab)"
  "push-unres-deny-work-tree-attached|case_pu_deny_work_tree_attached|deny: git --work-tree=../other-u6 push origin develop -- mutation proof: dev/mutants/hook-tests.json (292-pg-repo-opts-attached, 292-pg-repo-opts-vocab)"
  "push-unres-deny-work-tree-detached|case_pu_deny_work_tree_detached|deny: git --work-tree ../other-u7 push origin develop -- mutation proof: dev/mutants/hook-tests.json (292-pg-repo-opts-detached, 292-pg-repo-opts-vocab)"
  "push-unres-deny-env-git-dir|case_pu_deny_env_git_dir|deny: GIT_DIR=../other-u8/.git git push origin develop -- mutation proof: dev/mutants/hook-tests.json (292-pg-env-vocab)"
  "push-unres-deny-env-prefix-work-tree|case_pu_deny_env_prefix_work_tree|deny: env GIT_WORK_TREE=../other-u9 git push origin develop -- mutation proof: dev/mutants/hook-tests.json (292-pg-env-vocab)"
  "push-unres-deny-env-common-dir|case_pu_deny_env_common_dir|deny: GIT_COMMON_DIR=../other-u10/.git git push origin develop -- mutation proof: dev/mutants/hook-tests.json (292-pg-env-vocab)"
  "push-unres-deny-never-executes|case_pu_deny_never_executes|deny via the unresolved-target route, AND push-guard.sh never invokes git/gh/rm/dirname on the booby-trapped PATH, AND BOTH the session repo's and the other checkout's file listings are byte-identical before/after -- mutation proof: dev/mutants/hook-tests.json (292-pg-c-nonwt)"
  "push-unres-deny-codex-main-session|case_pu_deny_codex_main_session|deny: a Codex-shaped main-session payload (mk_codex_shell '') with a non-wt -C push -- mutation proof: dev/mutants/hook-tests.json (292-pg-c-nonwt)"
  "push-unres-deny-c-dot-session-default|case_pu_deny_c_dot_session_default|deny: git -C . push origin develop against a develop-default session -- a session-equivalent -C value still reaches the ordinary default-branch route, never the unresolved one -- mutation proof: dev/mutants/hook-tests.json (292-pg-session-equiv)"
  "push-unres-noop-c-dot|case_pu_noop_c_dot|no opinion: git -C . push origin feature/x -- session-equivalent -C value control -- mutation proof: dev/mutants/hook-tests.json (292-pg-session-equiv)"
  "push-unres-noop-c-session-cwd|case_pu_noop_c_session_cwd|no opinion: git -C \$main/ push -u origin \"claude/17-a\", cwd \$main (one trailing slash on the -C value only) -- mutation proof: dev/mutants/hook-tests.json (292-pg-session-equiv, 292-pg-trailing-slash)"
  "push-unres-noop-c-session-root|case_pu_noop_c_session_root|no opinion: cwd a SUBDIRECTORY of the session checkout, -C names the session ROOT -- pins \$session_root, distinct from \$resolve_cwd -- mutation proof: dev/mutants/hook-tests.json (292-pg-session-equiv, 292-pg-session-root)"
  "push-unres-noop-c-nonpush-segment|case_pu_noop_c_nonpush_segment|no opinion: git -C ../other-checkout-u19 status && git push origin feature/x -- only push segments are affected -- control, not part of the mutation-proof registry"
  "push-unres-noop-env-unrelated|case_pu_noop_env_unrelated|no opinion: GIT_TRACE=1 git push origin feature/x -- an unrelated GIT_ env var is never flagged -- mutation proof: dev/mutants/hook-tests.json (292-pg-env-exact)"
  "push-unres-noop-global-opt-feature|case_pu_noop_global_opt_feature|no opinion: git --namespace foo push origin feature/x -- an ordinary global option with a value is unaffected (#439 re-point: -c core.pager=cat now denies via the command-line-config route) -- control, not part of the mutation-proof registry"
  # --- cross-segment ("xseg"): cd/pushd/popd/chdir or a GIT_DIR-family export/assignment in
  # another segment of the same push command (#433) ---------------------------------------------
  "push-xseg-deny-cd-and|case_px_deny_cd_and|deny: cd ../other-x1 && git push origin develop -- a cd in an earlier segment of the same command -- mutation proof: dev/mutants/hook-tests.json (433-pg-dir-vocab, 433-pg-fallback-drop)"
  "push-xseg-deny-cd-bare-push|case_px_deny_cd_bare_push|deny: cd ../other-x2; git push (bare push, no explicit destination) -- mutation proof: dev/mutants/hook-tests.json (433-pg-dir-vocab, 433-pg-fallback-drop)"
  "push-xseg-deny-pushd|case_px_deny_pushd|deny: pushd ../other-x3 && git push origin develop -- mutation proof: dev/mutants/hook-tests.json (433-pg-dir-vocab, 433-pg-fallback-drop)"
  "push-xseg-deny-popd|case_px_deny_popd|deny: popd; git push origin develop -- mutation proof: dev/mutants/hook-tests.json (433-pg-dir-vocab, 433-pg-fallback-drop)"
  "push-xseg-deny-chdir|case_px_deny_chdir|deny: chdir ../other-x5; git push origin develop -- mutation proof: dev/mutants/hook-tests.json (433-pg-dir-vocab, 433-pg-fallback-drop)"
  "push-xseg-deny-subshell|case_px_deny_subshell|deny: ( cd ../other-x6; git push origin develop ) -- a cd inside a subshell whose own directory change never actually reaches the push -- mutation proof: dev/mutants/hook-tests.json (433-pg-dir-vocab, 433-pg-fallback-drop)"
  "push-xseg-deny-builtin-cd|case_px_deny_builtin_cd|deny: builtin cd ../other-x7 && git push origin develop -- \"builtin\" is a PREFIX_WORDS member, so cd still resolves as the command word -- mutation proof: dev/mutants/hook-tests.json (433-pg-dir-vocab, 433-pg-fallback-drop)"
  "push-xseg-deny-bash-c|case_px_deny_bash_c|deny: bash -c 'cd ../other-x8 && git push origin develop' -- quote-blind: the inner && still segment-breaks the outer command string -- mutation proof: dev/mutants/hook-tests.json (433-pg-dir-vocab, 433-pg-fallback-drop)"
  "push-xseg-deny-eval|case_px_deny_eval|deny: eval 'cd ../other-x9; git push origin develop' -- mutation proof: dev/mutants/hook-tests.json (433-pg-dir-vocab, 433-pg-fallback-drop)"
  "push-xseg-deny-multiline|case_px_deny_multiline|deny: a cd on one line, the push on the next -- xseg is a per-command, never-per-record, global flag -- mutation proof: dev/mutants/hook-tests.json (433-pg-dir-vocab, 433-pg-per-record-reset, 433-pg-fallback-drop)"
  "push-xseg-deny-dbracket-tail|case_px_deny_dbracket_tail|deny: if [[ -d ../other-x11 ]] cd ../other-x11; git push origin develop -- the cd is seen only by the additive ]] pass, AFTER the push line is emitted -- pins the order-independent END-marker design -- mutation proof: dev/mutants/hook-tests.json (433-pg-dir-vocab, 433-pg-fallback-drop)"
  "push-xseg-deny-push-before-cd|case_px_deny_push_before_cd|deny: git push origin develop && cd .. -- the push segment comes BEFORE the cd segment -- pins the chosen order-independence -- mutation proof: dev/mutants/hook-tests.json (433-pg-dir-vocab, 433-pg-fallback-drop)"
  "push-xseg-deny-export-git-dir|case_px_deny_export_git_dir|deny: export GIT_DIR=../other-x13/.git; git push origin develop -- mutation proof: dev/mutants/hook-tests.json (433-pg-export-vocab, 433-pg-fallback-drop)"
  "push-xseg-deny-export-name-only|case_px_deny_export_name_only|deny: export GIT_DIR && git push origin develop (bare name, no value) -- mutation proof: dev/mutants/hook-tests.json (433-pg-export-vocab, 433-pg-fallback-drop)"
  "push-xseg-deny-export-quoted|case_px_deny_export_quoted|deny: export \"GIT_DIR=../other-xq/.git\"; git push origin develop (a quoted export argument) -- mutation proof: dev/mutants/hook-tests.json (433-pg-export-vocab, 433-pg-fallback-drop, 433-pg-export-quotes)"
  "push-xseg-deny-export-git-config|case_px_deny_export_git_config|deny: export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.push GIT_CONFIG_VALUE_0=HEAD:main; git push -- #439's command-line-config names exported in another segment -- mutation proof: dev/mutants/hook-tests.json (433-pg-export-vocab, 433-pg-export-exact, 433-pg-fallback-drop, 433-pg-cfg-export)"
  "push-xseg-deny-export-git-config-key|case_px_deny_export_git_config_key|deny: export GIT_CONFIG_KEY_9zq=remote.origin.push; git push origin develop -- prefix-matched name, never echoed -- mutation proof: dev/mutants/hook-tests.json (433-pg-export-vocab, 433-pg-export-exact, 433-pg-fallback-drop, 433-pg-cfg-export, 433-pg-cfg-prefix)"
  "push-xseg-deny-export-git-config-exact|case_px_deny_export_git_config_exact|deny: export GIT_CONFIG_GLOBAL=../other-xg/cfg; git push origin develop -- an exact #439 name exported WITH a value -- mutation proof: dev/mutants/hook-tests.json (433-pg-export-vocab, 433-pg-export-exact, 433-pg-fallback-drop, 433-pg-cfg-export, 433-pg-cfg-strip)"
  "push-xseg-noop-git-config-scoped|case_px_noop_git_config_scoped|no opinion: GIT_CONFIG_COUNT=1 git log; git push origin feature/x -- an assignment scoped to another command -- mutation proof: dev/mutants/hook-tests.json (433-pg-cfg-bare-only)"
  "push-xseg-deny-bare-git-config|case_px_deny_bare_git_config|deny: GIT_CONFIG_COUNT=1; git push origin develop -- a bare GIT_CONFIG_* assignment segment -- mutation proof: dev/mutants/hook-tests.json (433-pg-fallback-drop, 433-pg-cfg-bare)"
  "push-xseg-noop-export-git-config-nosystem|case_px_noop_export_git_config_nosystem|no opinion: export GIT_CONFIG_NOSYSTEM=1; git push origin feature/x -- exact vocabulary -- mutation proof: dev/mutants/hook-tests.json (433-pg-export-exact, 433-pg-cfg-exact)"
  "push-xseg-deny-declare-gx-work-tree|case_px_deny_declare_gx_work_tree|deny: declare -gx GIT_WORK_TREE=../other-x15; git push origin develop -- an option token (-gx) between the export-family word and the assignment is skipped -- mutation proof: dev/mutants/hook-tests.json (433-pg-export-vocab, 433-pg-export-exact, 433-pg-fallback-drop)"
  "push-xseg-deny-typeset-common-dir|case_px_deny_typeset_common_dir|deny: typeset -x GIT_COMMON_DIR=../other-x16/.git; git push origin develop -- mutation proof: dev/mutants/hook-tests.json (433-pg-export-vocab, 433-pg-export-exact, 433-pg-fallback-drop)"
  "push-xseg-deny-bare-assign|case_px_deny_bare_assign|deny: GIT_DIR=../other-x17/.git; git push origin develop -- a segment made of ONLY a GIT_REPO_ENV_VARS assignment, no git/command word at all in that segment -- mutation proof: dev/mutants/hook-tests.json (433-pg-bare-assign, 433-pg-fallback-drop)"
  "push-xseg-deny-inseg-precedence|case_px_deny_inseg_precedence|deny: cd ../other-x18 && git --git-dir=../other-x18/.git push origin develop -- the push segment's OWN in-segment reason (#292's --git-dir) keeps precedence over the cross-segment fallback -- control, not part of the mutation-proof registry (see the section header above for why)"
  "push-xseg-deny-codex-main-session|case_px_deny_codex_main_session|deny: a Codex-shaped main-session payload (mk_codex_shell '') with cd ../other-x19 && git push origin develop -- mutation proof: dev/mutants/hook-tests.json (433-pg-dir-vocab, 433-pg-fallback-drop)"
  "push-xseg-deny-never-executes|case_px_deny_never_executes|deny via the cross-segment route, AND push-guard.sh never invokes git/gh/rm/dirname on the booby-trapped PATH, AND BOTH the session repo's and the other checkout's file listings are byte-identical before/after -- mutation proof: dev/mutants/hook-tests.json (433-pg-dir-vocab, 433-pg-fallback-drop)"
  "push-xseg-noop-cd-no-push|case_px_noop_cd_no_push|no opinion: cd ../other-y1 && git log --grep=push -- contains \"push\" and \"git\" but has no PUSH segment at all, so the driver's saw_push guard alone keeps the cd marker from denying -- mutation proof: dev/mutants/hook-tests.json (448-pg-xseg-saw-push)"
  "push-xseg-noop-cd-as-argument|case_px_noop_cd_as_argument|no opinion: echo cd && git push origin feature/x -- \"cd\" here is an argument, never the resolved command word -- control, not part of the mutation-proof registry"
  "push-xseg-noop-export-unrelated|case_px_noop_export_unrelated|no opinion: export GIT_TRACE=1; git push origin feature/x -- an unrelated exported variable is never flagged -- mutation proof: dev/mutants/hook-tests.json (433-pg-export-exact)"
  "push-wd-allow-no-workdir|case_wd_allow_no_workdir|no opinion: a Codex payload whose code-mode call carries no workdir -- control, not part of the mutation-proof registry"
  "push-wd-allow-literal-session|case_wd_allow_literal_session|no opinion: the call's workdir is a plain string literal equal to the session cwd, followed by a newline before the closing brace -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-flatten)"
  "push-wd-allow-literal-dot|case_wd_allow_literal_dot|no opinion: the call's workdir is the plain literal \".\" -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-flatten)"
  "push-wd-allow-function-call-dot|case_wd_allow_function_call_dot|no opinion: a function_call record with \"workdir\":\".\" in its JSON arguments -- control, not part of the mutation-proof registry"
  "push-wd-allow-function-call-null|case_wd_allow_function_call_null|no opinion: a function_call record with \"workdir\":null -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-null-arm)"
  "push-wd-allow-short-fragment|case_wd_allow_short_fragment|no opinion: an unparseable first line with no workdir key, far shorter than half the window, then a call with none -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-edge-fraction)"
  "push-wd-deny-completed-foreign|case_wd_deny_completed_foreign|deny: a call whose output record exists, with a foreign workdir, then a later call with none (every call record is scanned, completed or not) -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-no-pending-filter)"
  "push-wd-deny-yielded-cell|case_wd_deny_yielded_cell|deny: an exec cell whose output says Script running with cell ID and whose push names another checkout, then a pending wait call with no workdir -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-no-pending-filter)"
  "push-wd-deny-other-checkout|case_wd_deny_other_checkout|deny: the U9 shape -- git push origin HEAD:trunk, the code-mode call names another checkout -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-gate, 494-pg-wd-session-compare)"
  "push-wd-deny-computed|case_wd_deny_computed|deny: the call's workdir is an identifier, not a plain string literal -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-bad-allow)"
  "push-wd-deny-null-ident|case_wd_deny_null_ident|deny: the call's workdir is an identifier that merely starts with null -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-null-terminator)"
  "push-wd-deny-undefined|case_wd_deny_undefined|deny: the call's workdir is the identifier undefined, which is not accepted as no workdir -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-undefined-bad)"
  "push-wd-deny-undefined-shadowed|case_wd_deny_undefined_shadowed|deny: undefined shadowed by a const naming another checkout, used as the workdir -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-undefined-bad)"
  "push-wd-deny-concat|case_wd_deny_concat|deny: the call's workdir literal is followed by a concatenation -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-literal-tail, 494-pg-wd-bad-allow)"
  "push-wd-deny-duplicate-key|case_wd_deny_duplicate_key|deny: the same call names the session checkout and then another checkout (every occurrence of the key is judged) -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-every-occurrence)"
  "push-wd-deny-function-call-other|case_wd_deny_function_call_other|deny: a function_call record whose JSON arguments name another checkout -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-gate)"
  "push-wd-deny-local-shell-other|case_wd_deny_local_shell_other|deny: a local_shell_call record whose action.working_directory names another checkout -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-working-directory)"
  "push-wd-deny-fragment-key|case_wd_deny_fragment_key|deny: an unparseable first line (a cut record) that still mentions a workdir key, then a clean call -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-fragment-key-bad)"
  "push-wd-deny-straddle|case_wd_deny_straddle|deny: a push record larger than the whole window, then a small call with no workdir; the window holds only an unparseable fragment of at least half its size -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-edge)"
  "push-wd-deny-missing-transcript|case_wd_deny_missing_transcript|deny: the payload's transcript_path names a file that does not exist -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-missing)"
  "push-wd-deny-empty-transcript-path|case_wd_deny_empty_transcript_path|deny: the payload's transcript_path is the empty string -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-missing)"
  "push-wd-deny-transcript-directory|case_wd_deny_transcript_directory|deny: the payload's transcript_path names a directory, not a regular file -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-not-regular)"
  "push-wd-deny-transcript-unreadable|case_wd_deny_transcript_unreadable|deny: the payload's transcript_path names a mode-000 file (assertions skipped under root) -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-unreadable)"
  "push-wd-deny-no-call|case_wd_deny_no_call|deny: the rollout holds no call record at all, only an output record, a garbage line and noise -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-no-call)"
  "push-wd-deny-never-executes|case_wd_deny_never_executes|deny via the Codex workdir route, AND push-guard.sh never invokes git/gh/rm/dirname on the booby-trapped PATH, AND the session repo, the other checkout and the rollout are byte-identical before/after, AND the message echoes none of their content -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-gate)"
  "push-wd-claude-unchanged|case_wd_claude_unchanged|no opinion: a Claude-shaped payload (no turn_id) whose transcript_path names a missing file -- mutation proof: dev/mutants/hook-tests.json (494-pg-wd-gate-claude)"
  "push-deny-config-remote-push-bare|case_pd_config_remote_push_bare|deny: git push against a repo whose config carries [remote \"origin\"] push = HEAD:main (#268, the issue's own shape) -- measured: M26, 68 pass 12 fail"
  "push-deny-config-remote-push-named-remote|case_pd_config_remote_push_named_remote|deny: git push origin against the same config (n==1, the positive side of the exact-remote-scoping clause) -- measured: M26, 68 pass 12 fail (also M41, 79 pass 1 fail)"
  "push-deny-config-remote-push-second-line|case_pd_config_remote_push_second_line|deny: two push = lines under [remote \"origin\"], only the SECOND offending (0/1/2+ boundary) -- measured: M26, 68 pass 12 fail (also M33, 79 pass 1 fail)"
  "push-deny-config-no-space-assign|case_pd_config_no_space_assign|deny: push=HEAD:main with NO surrounding spaces (#268 kickback finding 1 -- the *=*) split guard must accept this form) -- measured: M43, 82 pass 1 fail"
  "push-deny-config-push-default-upstream|case_pd_config_push_default_upstream|deny: [push] default = upstream + [branch \"feature/x\"] merge = refs/heads/main -- measured: M26, 68 pass 12 fail (also M42, 77 pass 3 fail)"
  "push-deny-config-push-default-tracking|case_pd_config_push_default_tracking|deny: [push] default = tracking (git's documented synonym for upstream) -- measured: M26, 68 pass 12 fail (also M30, 79 pass 1 fail; also M42, 77 pass 3 fail)"
  "push-deny-config-push-default-matching|case_pd_config_push_default_matching|deny: [push] default = matching (Q2, unconditional, same reasoning as --all/--mirror) -- measured: M26, 68 pass 12 fail (also M29, 77 pass 3 fail, as a side effect; also M31, 79 pass 1 fail; also M42, 77 pass 3 fail)"
  "push-deny-config-union-benign-refspec-plus-upstream|case_pd_config_union_benign_refspec_plus_upstream|deny: [remote \"origin\"] push = HEAD:refs/heads/feature/x (a NON-denying refspec) alongside [push] default = upstream + [branch \"feature/x\"] merge = refs/heads/main (#268 kickback finding 2 -- the RESOLVED Q1 union, not git's own precedence) -- measured: M44, 82 pass 1 fail"
  "push-deny-config-union-other-remote-bare|case_pd_config_union_other_remote_bare|deny: bare git push against a config carrying ONLY [remote \"backup\"] push = HEAD:main plus a benign origin section with no push key (#268 kickback 2 finding -- RESOLVED Q1's CROSS-REMOTE union at n==0: every configured remote's push refspecs, not just git's own default-remote pick) -- measured: M45, 83 pass 1 fail"
  "push-deny-config-wildcard-refspec|case_pd_config_wildcard_refspec|deny: [remote \"origin\"] push = refs/heads/*:refs/heads/* (Q3, unconditional wildcard destination) -- measured: M26, 68 pass 12 fail (also M32, 79 pass 1 fail)"
  "push-deny-config-crlf-line|case_pd_config_crlf_line|deny: the config FILE carries CRLF line endings (#270's class, in the new config reader) -- measured: M26, 68 pass 12 fail; NOT flipped by M35 (re-measured, #268 kickback finding 3), 82 pass 1 fail -- only push-deny-config-crlf-interior fails (its line-ending CR is already stripped by cfg_trim's own [[:space:]] handling -- a genuine measured finding, not a coverage gap)"
  "push-deny-config-crlf-interior|case_pd_config_crlf_interior|deny: an INTERIOR CR inside the refspec value itself, HEAD:ma<CR>in (#268 kickback finding 3 -- distinct from push-deny-config-crlf-line's line-ending CR, and the fixture that makes M35 non-inert) -- measured: M35, 82 pass 1 fail"
  "push-deny-config-worktree-commondir|case_pd_config_worktree_commondir|deny: config lives in the MAIN checkout's .git/config, cwd is the worktree POINTER dir (the common-dir derivation, not \$gitdir) -- measured: M26, 68 pass 12 fail (also M36, 79 pass 1 fail)"
  "push-deny-config-no-trailing-newline|case_pd_config_no_trailing_newline|deny: the config file's last (only) line has no trailing newline (the read rescue) -- measured: M26, 68 pass 12 fail (also M37, 79 pass 1 fail)"
  "push-deny-config-mixed-case|case_pd_config_mixed_case|deny: [Remote \"origin\"] / Push = HEAD:main (Q4, case-insensitive section keyword and key name) -- measured: M26, 68 pass 12 fail (also M38, 79 pass 1 fail)"
  "push-deny-config-never-executes|case_pd_config_never_executes|deny via the CONFIG route, AND push-guard.sh never invokes git/gh/rm on the booby-trapped PATH, AND the fixture repo's file listing is byte-identical before/after -- measured: M26, 68 pass 12 fail"
  "push-deny-config-tab-in-value|case_pd_config_tab_in_value|deny: [remote \"origin\"] push = refs/heads/*:refs/heads/*<TAB>junklabel (#290 kickback finding F4 -- a literal TAB byte inside a configured value must not corrupt the two-literal source label) -- measured: M70, 115 pass 1 fail (also M32, 114 pass 2 fail; also M63, 85 pass 31 fail; also M68, 114 pass 2 fail, the inline source-label assertion)"
  "push-noop-config-neither-key|case_pn_config_neither_key|no opinion: config sets NEITHER remote.<name>.push nor push.default at all (the decision's required control) -- measured: not flipped by M26-M45 (this fixture's config never reaches any of the twenty mutated clauses)"
  "push-noop-config-remote-push-other-dest|case_pn_config_remote_push_other_dest|no opinion: [remote \"origin\"] push = HEAD:refs/heads/feature/x (a configured refspec whose destination is not the default branch) -- measured: M40, 78 pass 2 fail (with push-noop-config-commented-out)"
  "push-noop-config-other-remote-named|case_pn_config_other_remote_named|no opinion: [remote \"origin\"] push = HEAD:main, command git push backup (n==1 exact remote scoping -- a DIFFERENT remote's own push route must not apply) -- measured: M27, 79 pass 1 fail"
  "push-noop-config-explicit-refspec|case_pn_config_explicit_refspec|no opinion: git push -u origin \"claude/17-a\" against a repo whose config carries push = HEAD:main (n>=2 -- config routes are NEVER consulted here; a deny would be a release blocker) -- measured: M39, 79 pass 1 fail"
  "push-noop-config-branch-other|case_pn_config_branch_other|no opinion: push.default=upstream but [branch \"other\"] merge=refs/heads/main -- current branch (feature/x) has no section of its own -- measured: M28, 79 pass 1 fail"
  "push-noop-config-commented-out|case_pn_config_commented_out|no opinion: a #-commented push line, a ;-commented push.default line, and odd leading whitespace on the one real harmless key -- measured: M40, 78 pass 2 fail (with push-noop-config-remote-push-other-dest); NOT flipped by M34, 80 pass 0 fail (the comment strip's absence is masked by exact-key matching -- see M34's own table entry)"
  "push-noop-config-push-default-current|case_pn_config_push_default_current|no opinion: [push] default = current + a branch section that WOULD deny if this mode were mistaken for upstream (the sharp form of the mode-check clause) -- measured: M29, 77 pass 3 fail (with push-noop-config-push-default-simple)"
  "push-noop-config-push-default-simple|case_pn_config_push_default_simple|no opinion: [push] default = simple, git's own default mode, same branch-section trap as push-default-current -- measured: M29, 77 pass 3 fail (with push-noop-config-push-default-current)"
  "push-deny-global-gitconfig-upstream|case_pd_global_gitconfig_upstream|deny: GLOBAL \$HOME/.gitconfig carries [push] default = upstream, repo config carries only a [branch] merge record (per-path 1/4); also asserts inline the deny message names the GLOBAL source label -- measured: M58, 103 pass 11 fail (also M67, 113 pass 1 fail, the inline source-label assertion)"
  "push-deny-global-xdg-upstream|case_pd_global_xdg_upstream|deny: explicit \$XDG_CONFIG_HOME/git/config carries [push] default = upstream, neutral HOME (per-path 2/4) -- measured: M58, 103 pass 11 fail (also M61, 112 pass 2 fail)"
  "push-deny-global-xdg-home-default-upstream|case_pd_global_xdg_home_default_upstream|deny: \$XDG_CONFIG_HOME UNSET, [push] default = upstream at the DEFAULT \$HOME/.config/git/config path (per-path 3/4) -- measured: M62, 113 pass 1 fail (also M58, 103 pass 11 fail; also M61, 112 pass 2 fail)"
  "push-deny-global-env-var-upstream|case_pd_global_env_var_upstream|deny: \$GIT_CONFIG_GLOBAL points at a fixture file OUTSIDE HOME, [push] default = upstream (per-path 4/4) -- measured: M59, 112 pass 2 fail (also M58, 103 pass 11 fail)"
  "push-deny-global-remote-push-refspec|case_pd_global_remote_push_refspec|deny: GLOBAL [remote \"origin\"] push = HEAD:main, repo has NO config file at all -- measured: M58, 103 pass 11 fail (also M60, 107 pass 7 fail; also M26, 84 pass 30 fail)"
  "push-deny-global-default-matching|case_pd_global_default_matching|deny: GLOBAL [push] default = matching, unconditional, no [branch] section anywhere -- measured: M58, 103 pass 11 fail (also M60, 107 pass 7 fail; also M29, 109 pass 5 fail; also M31, 112 pass 2 fail)"
  "push-deny-global-benign-does-not-mask-repo-route|case_pd_global_benign_does_not_mask_repo_route|deny: a benign GLOBAL push.default=current must not mask a denying REPO push.default=upstream (the \"evaluate every value\" discriminator); also asserts inline the deny message names the REPO source label -- measured: M66, 115 pass 1 fail (also M68, 114 pass 2 fail, the inline source-label assertion; also M29, 111 pass 5 fail -- this fixture still denies under M29, via the GLOBAL record, and fails only its own inline source-label assertion, see M29's own table entry)"
  "push-deny-global-two-defaults-one-file|case_pd_global_two_defaults_one_file|deny: [push] default = upstream THEN, on the next line, default = current, both inside the SAME global file (#290 kickback finding F1 -- git's own last-wins-within-a-file resolves this to \"current\" and would not deny; this hook evaluates every line and denies via the FIRST, \"upstream\"); also asserts inline the deny message names push.default=upstream via the global source label -- measured: M65, 114 pass 2 fail (also M14, 99 pass 17 fail; also M26, 84 pass 32 fail; also M42, 103 pass 13 fail; also M58, 104 pass 12 fail; also M60, 108 pass 8 fail; also M63, 85 pass 31 fail; also M64, 107 pass 9 fail; also M67, 114 pass 2 fail, the inline source-label assertion)"
  "push-deny-global-overrides-benign-repo-route|case_pd_global_overrides_benign_repo_route|deny: a denying GLOBAL push.default=upstream still denies over a benign REPO push.default=current (documented over-block -- real git would honour the repo's \"current\" alone) -- measured: M65, 113 pass 1 fail (also M58, 103 pass 11 fail; also M60, 107 pass 7 fail)"
  "push-deny-global-env-var-union-not-replace|case_pd_global_env_var_union_not_replace|deny: \$GIT_CONFIG_GLOBAL set to a BENIGN file, \$HOME/.gitconfig (real git would never consult it once \$GIT_CONFIG_GLOBAL is set) still denies -- union-not-replace over-block, denier read LAST -- measured: M60, 107 pass 7 fail (also M58, 103 pass 11 fail)"
  "push-deny-global-two-files-first-denies|case_pd_global_two_files_first_denies|deny: \$GIT_CONFIG_GLOBAL (read first) denies, \$HOME/.gitconfig (read after it) is benign -- denier read FIRST, the 2+ boundary's other half -- measured: M59, 112 pass 2 fail (also M58, 103 pass 11 fail)"
  "push-deny-c-target-global-route|case_pd_c_target_global_route|deny: a resolved \"-C\" segment still sees the GLOBAL routes (session resolves NO repo at all; the \"-C\" target has its own default and no config of its own) -- measured: M69, 113 pass 1 fail (also M58, 103 pass 11 fail; also M60, 107 pass 7 fail; also M54, 111 pass 3 fail -- the only #290 fixture that mutant discriminates)"
  "push-deny-global-never-executes|case_pd_global_never_executes|deny via a GLOBAL route, AND push-guard.sh never invokes git/gh/rm/dirname on the booby-trapped PATH, AND BOTH the fixture repo's and the fixture HOME's file listings are byte-identical before/after -- measured: M58, 103 pass 11 fail (also M26, 84 pass 30 fail)"
  "push-noop-global-upstream-no-tracking|case_pn_global_upstream_no_tracking|no opinion: GLOBAL [push] default = upstream, current branch claude/17-a, NO [branch] section anywhere (honest-scope control) -- measured: not flipped by M14-M69 (this fixture's [branch] section is absent everywhere, so refspec_dest() of an empty branch.merge always yields no destination regardless of how push.default is parsed or which file supplies it)"
  "push-noop-global-explicit-refspec|case_pn_global_explicit_refspec|no opinion: git push -u origin \"claude/17-a\" (release-blocker control, bare) against a GLOBAL config carrying BOTH a denying remote.origin.push AND push.default=matching -- config is never consulted for an explicit refspec -- measured: M39, 111 pass 3 fail (with push-noop-config-explicit-refspec and push-noop-global-explicit-refspec-c)"
  "push-noop-global-explicit-refspec-c|case_pn_global_explicit_refspec_c|no opinion: git -C <wt> push -u origin \"claude/17-a\" (release-blocker control, the \"-C\" variant) against the SAME denying GLOBAL config -- measured: M39, 111 pass 3 fail (with push-noop-config-explicit-refspec and push-noop-global-explicit-refspec)"
  "push-noop-global-none-present|case_pn_global_none_present|no opinion: a dedicated, empty fixture HOME with no .gitconfig/.config/git/config, XDG_CONFIG_HOME and GIT_CONFIG_GLOBAL both unset, repo config absent (the \"none present\" boundary AND this file's own isolation positive control) -- measured: not flipped by M14-M69 (this fixture's dedicated HOME has no candidate file at all, so no mutant in this table -- none of which invents a route from a file that does not exist -- can produce a deny here)"
  "push-kw-deny-then|case_push_kw_deny_then|shell-keyword deny: if true; then git push origin main; fi -- mutation proof: dev/mutants/hook-tests.json (398-pg-kw-vocab)"
  "push-kw-deny-bang|case_push_kw_deny_bang|shell-keyword deny: ! git push origin main -- mutation proof: dev/mutants/hook-tests.json (398-pg-kw-vocab)"
  "push-kw-deny-upper-git|case_push_kw_deny_upper_git|case-fold deny: GIT push origin main -- mutation proof: dev/mutants/hook-tests.json (398-pg-case-fold, 398-pg-fastpath-case)"
  "push-kw-noop-then-feature|case_push_kw_noop_then_feature|shell-keyword no opinion: if true; then git push origin feature/x; fi (control: the keyword skip must not widen the destination rule) -- control, not part of the mutation-proof registry"
  # --- #304/#305: system git config candidates cases ------------------------------------------
  "push-cfg-deny-trailing-tab-default|case_push_cfg_deny_trailing_tab_default|deny: [push] default = matching<TAB> in .git/config -- pins that cfg_trim's fork-free rewrite still strips a trailing TAB, not just trailing spaces -- mutation proof: dev/mutants/hook-tests.json (304-cfg-trim-tab)"
  "push-sysconf-deny-etc|case_push_sysconf_deny_etc|deny: bare push, remote.origin.push=HEAD:main in \$sysroot/etc/gitconfig -- mutation proof: dev/mutants/hook-tests.json (304-sys-etc)"
  "push-sysconf-deny-homebrew-arm|case_push_sysconf_deny_homebrew_arm|deny: bare push, push.default=upstream in \$sysroot/opt/homebrew/etc/gitconfig, resolved via a repo branch.merge -- mutation proof: dev/mutants/hook-tests.json (304-sys-homebrew-arm)"
  "push-sysconf-deny-homebrew-intel|case_push_sysconf_deny_homebrew_intel|deny: bare push, push.default=matching in \$sysroot/usr/local/etc/gitconfig -- mutation proof: dev/mutants/hook-tests.json (304-sys-homebrew-intel)"
  "push-sysconf-deny-apple-clt|case_push_sysconf_deny_apple_clt|deny: bare push, push.default=matching in the Apple CLT candidate, no NOSYSTEM set, plus an inline assert that stderr names 'in your system git config' -- mutation proof: dev/mutants/hook-tests.json (304-sys-clt, 304-sys-clt-label)"
  "push-sysconf-deny-env-var|case_push_sysconf_deny_env_var|deny: bare push, \$GIT_CONFIG_SYSTEM pointed at a denying file outside the sysroot, plus an inline assert that stderr names 'in your system git config' -- mutation proof: dev/mutants/hook-tests.json (304-sys-env-var, 304-sys-label)"
  "push-sysconf-deny-env-var-union-not-replace|case_push_sysconf_deny_env_var_union_not_replace|deny: a BENIGN \$GIT_CONFIG_SYSTEM file does not replace \$sysroot/etc/gitconfig, which still denies -- mutation proof: dev/mutants/hook-tests.json (304-sys-etc)"
  "push-sysconf-noop-nosystem-one|case_push_sysconf_noop_nosystem_one|no opinion: GIT_CONFIG_NOSYSTEM=1 skips both \$GIT_CONFIG_SYSTEM and \$sysroot/etc/gitconfig, each independently denying -- mutation proof: dev/mutants/hook-tests.json (304-nosystem-ignored)"
  "push-sysconf-noop-nosystem-word|case_push_sysconf_noop_nosystem_word|no opinion: GIT_CONFIG_NOSYSTEM=Yes (case-insensitive word form) skips the same two candidates -- mutation proof: dev/mutants/hook-tests.json (304-nosystem-ignored, 304-nosystem-word)"
  "push-sysconf-deny-nosystem-false|case_push_sysconf_deny_nosystem_false|deny: GIT_CONFIG_NOSYSTEM=0 (a non-canonical/false-looking value) does NOT disable the system read -- mutation proof: dev/mutants/hook-tests.json (304-nosystem-any-value)"
  "push-sysconf-noop-clt-nosystem|case_push_sysconf_noop_clt_nosystem|no opinion (amendment A1): GIT_CONFIG_NOSYSTEM=1 also skips the Apple CLT candidate, which sits INSIDE the same \$nosys guard as the three static paths -- mutation proof: dev/mutants/hook-tests.json (304-nosystem-ignored, 304-nosystem-covers-clt)"
  "push-sysconf-deny-repo-merge-last|case_push_sysconf_deny_repo_merge_last|deny: system push.default=upstream plus a conflicting branch.merge in BOTH \$sysroot/etc/gitconfig and the repo -- the repo's own value, read LAST, wins -- mutation proof: dev/mutants/hook-tests.json (304-sys-etc, 304-sys-order)"
  "push-sysconf-deny-c-target|case_push_sysconf_deny_c_target|deny: a resolved -C target sees the SAME system candidates the session would, independently re-derived -- mutation proof: dev/mutants/hook-tests.json (304-sys-etc)"
  "push-sysconf-noop-explicit-refspec|case_push_sysconf_noop_explicit_refspec|no opinion: the harness's own explicit-refspec push -u origin \"claude/17-a\" never consults config, system or otherwise, even with denying system routes present -- control, not part of the mutation-proof registry"
  "push-sysconf-deny-never-executes|case_push_sysconf_deny_never_executes|deny, AND push-guard.sh never invokes git/gh/rm/dirname on the booby-trapped PATH while evaluating the system route, AND the fixture repo's and sysroot's own file listings stay byte-identical -- mutation proof: dev/mutants/hook-tests.json (304-sys-etc)"
  # --- #304/#305: include/includeIf cases -------------------------------------------------------
  "push-include-deny-relative-from-repo|case_push_include_deny_relative_from_repo|deny: repo config includes a relative extra.inc (resolved against .git/), plus an inline assert that stderr names 'in .git/config (via include)' -- mutation proof: dev/mutants/hook-tests.json (304-inc-section, 304-inc-relative, 304-inc-label)"
  "push-include-deny-absolute-from-global|case_push_include_deny_absolute_from_global|deny: a global .gitconfig includes an ABSOLUTE path elsewhere under \$tmpbase -- mutation proof: dev/mutants/hook-tests.json (304-inc-section)"
  "push-include-deny-tilde|case_push_include_deny_tilde|deny: a global .gitconfig includes '~/inc/push.inc', resolved against the fixture HOME -- mutation proof: dev/mutants/hook-tests.json (304-inc-section, 304-inc-tilde)"
  "push-include-deny-includeif-unmatched-condition|case_push_include_deny_includeif_unmatched_condition|deny (the pinned over-block): an includeIf gitdir: condition that could never match this checkout is still followed unconditionally -- mutation proof: dev/mutants/hook-tests.json (304-incif-section, 304-inc-relative)"
  "push-include-deny-mixed-case|case_push_include_deny_mixed_case|deny: repo config spells the section/key '[Include]'/'PATH' in mixed case -- mutation proof: dev/mutants/hook-tests.json (304-inc-section, 304-inc-key-case, 304-inc-relative)"
  "push-include-deny-nested-system-relative|case_push_include_deny_nested_system_relative|deny: a system candidate includes a.inc, which includes b.inc, two levels of relative resolution; inline asserts that stderr names 'your system git config (via include)' exactly once, never doubled -- mutation proof: dev/mutants/hook-tests.json (304-inc-section, 304-inc-relative, 304-inc-label)"
  "push-include-deny-at-depth-cap|case_push_include_deny_at_depth_cap|deny: a repo config include chain ten hops deep (c1..c10, top-level = depth 0), the denying route only in c10 -- mutation proof: dev/mutants/hook-tests.json (304-inc-section, 304-inc-relative, 304-inc-depth-lo)"
  "push-include-noop-beyond-depth-cap|case_push_include_noop_beyond_depth_cap|no opinion: the same chain one hop longer, the denying route only in c11 (depth 11), never followed -- mutation proof: dev/mutants/hook-tests.json (304-inc-depth-hi)"
  "push-include-deny-second-path-after-return|case_push_include_deny_second_path_after_return|deny: repo config's own [include] section carries TWO path keys (a.inc then b.inc); parsing must resume in the includer's own section after a.inc returns, to reach b.inc's own denying route -- mutation proof: dev/mutants/hook-tests.json (304-inc-section, 304-inc-relative, 304-inc-section-local)"
  "push-include-deny-mutual-cycle|case_push_include_deny_mutual_cycle|deny, and it terminates: repo config includes a.inc, which includes the repo's OWN config right back -- mutation proof: dev/mutants/hook-tests.json (304-inc-section, 304-inc-relative)"
  "push-include-noop-self-cycle|case_push_include_noop_self_cycle|no opinion, and it terminates: repo config includes its own 'config' path twice in a row -- control, not part of the mutation-proof registry"
  "push-include-noop-missing-target|case_push_include_noop_missing_target|no opinion: repo config includes a target that does not exist on disk -- control, not part of the mutation-proof registry"
  "push-include-noop-prefix-form|case_push_include_noop_prefix_form|no opinion: repo config includes a literal '%(prefix)/etc/extra.inc' path, even though a file exists at that literal on-disk location -- proves the value is never treated as relative -- mutation proof: dev/mutants/hook-tests.json (304-inc-prefix-skip)"
  "push-include-deny-repo-config-reincluded|case_push_include_deny_repo_config_reincluded|deny: a GLOBAL include re-reads the repo's OWN .git/config by absolute path, then the global file overwrites branch.merge -- the repo-local top-level candidate's own later, mandatory re-read must still run and win last, proving the seen-list is ANCESTOR-ONLY, not a whole-resolve_repo()-call history -- mutation proof: dev/mutants/hook-tests.json (304-inc-seen-global)"
  "push-include-noop-tilde-user|case_push_include_noop_tilde_user|no opinion: repo config includes '~user/x.inc', even though a file exists at that literal on-disk location -- mutation proof: dev/mutants/hook-tests.json (304-inc-tilde-user)"
  "push-include-noop-directory-target|case_push_include_noop_directory_target|no opinion: repo config includes a target that is a DIRECTORY, not a regular file -- mutation proof: dev/mutants/hook-tests.json (304-inc-regular-file)"
  "push-include-noop-tilde-empty-home|case_push_include_noop_tilde_empty_home|no opinion: repo config includes '~/<abs-path>' with HOME exported empty for this call, even though the denying target exists on disk at its own absolute path -- mutation proof: dev/mutants/hook-tests.json (304-inc-tilde-empty-home)"
  "push-include-noop-drive-letter|case_push_include_noop_drive_letter|no opinion: repo config includes 'C:/x.inc' (used as-is, never joined to the including file's own directory), so it resolves against the hook's own cwd and stays missing -- mutation proof: dev/mutants/hook-tests.json (304-inc-drive-letter)"
  "push-include-deny-fanout-toplevel-route|case_push_include_deny_fanout_toplevel_route|deny: a 3-way, depth-7 fan-out include tree, with the denying route in .git/config ITSELF (never budgeted) -- finishes fast once the follow-budget and line-budget together bound the fan-out's own recursion -- control, not part of the mutation-proof registry (see push-include-noop-over-budget and push-include-noop-over-line-budget for the deterministic budget-boundary proofs)"
  "push-include-noop-over-budget|case_push_include_noop_over_budget|no opinion: 65 distinct includes exhaust CFG_INCLUDE_MAX_FOLLOWS=64 on the first 64 (benign); the 65th, and only denying, include is never followed -- mutation proof: dev/mutants/hook-tests.json (304-inc-follow-budget, 304-inc-follow-budget-off-by-one)"
  "push-include-noop-over-line-budget|case_push_include_noop_over_line_budget|no opinion: an included file whose own denying key line sits exactly one line past CFG_INCLUDE_MAX_LINES -- mutation proof: dev/mutants/hook-tests.json (304-inc-line-budget, 304-inc-line-budget-off-by-one)"
  "push-include-deny-within-line-budget|case_push_include_deny_within_line_budget|deny: the same shape with one fewer filler line, so the denying key line lands AT the CFG_INCLUDE_MAX_LINES boundary, still read -- mutation proof: dev/mutants/hook-tests.json (304-inc-section, 304-inc-relative, 304-inc-line-budget-off-by-one, 304-inc-line-budget-depth0)"
  "push-include-deny-longline-toplevel-route|case_push_include_deny_longline_toplevel_route|deny: a single 20KB included line is skipped for length cheaply, so the top-level route after it is still found fast -- control, not part of the mutation-proof registry"
  "push-include-noop-over-line-chars|case_push_include_noop_over_line_chars|no opinion: an included route line padded to CFG_INCLUDE_MAX_LINE_CHARS+1 characters is skipped for length before comment-strip or trim ever run -- mutation proof: dev/mutants/hook-tests.json (304-inc-line-chars)"
  "push-include-deny-within-line-chars|case_push_include_deny_within_line_chars|deny: the same shape padded to exactly CFG_INCLUDE_MAX_LINE_CHARS characters, one fewer, still processed -- mutation proof: dev/mutants/hook-tests.json (304-inc-section, 304-inc-relative, 304-inc-line-chars-off-by-one)"
  "push-include-noop-over-char-budget|case_push_include_noop_over_char_budget|no opinion: one oversized filler line's own charge leaves the shared character budget at exactly -1 by the time the denying key line is reached -- mutation proof: dev/mutants/hook-tests.json (304-inc-char-budget)"
  "push-include-deny-within-char-budget|case_push_include_deny_within_char_budget|deny: the same shape with the filler line one character shorter, so the character budget lands at exactly 0 (not negative) and the denying key line is still read -- mutation proof: dev/mutants/hook-tests.json (304-inc-section, 304-inc-relative, 304-inc-char-budget-off-by-one, 304-inc-line-budget-depth0)"
  "push-include-deny-long-toplevel-route|case_push_include_deny_long_toplevel_route|deny: a .git/config file far longer than CFG_INCLUDE_MAX_LINES, with its own route at the very end -- proves depth-0 top-level candidates never consult the line budget -- mutation proof: dev/mutants/hook-tests.json (304-inc-line-budget-depth0)"
  "push-include-deny-c-target-fresh-budget|case_push_include_deny_c_target_fresh_budget|deny: the session's own config exhausts the follow, line-count and character budgets all at once; a resolved -C target's only route, behind one include, is still found under its own independently-reset budgets -- mutation proof: dev/mutants/hook-tests.json (304-inc-section, 304-inc-relative, 304-inc-follow-budget-reset, 304-inc-line-budget-reset, 304-inc-char-budget-reset)"
  "push-include-noop-budget-gates-follow|case_push_include_noop_budget_gates_follow|no opinion: a SECOND include, of a real, permission-denied (mode 000) file that DOES carry its own deny route (push.default = matching), is never opened once the character budget is already exhausted by the first (observed via the permission-denied stderr line, so it assumes a non-root runner) -- deterministic, no timing involved -- mutation proof: dev/mutants/hook-tests.json (304-inc-follow-gate)"
  "push-include-noop-line-budget-gates-follow|case_push_include_noop_line_budget_gates_follow|no opinion: the LINE-budget sibling of push-include-noop-budget-gates-follow -- CFG_INCLUDE_MAX_LINES one-character lines exhaust only the line budget, leaving follows and characters both still positive, and a SECOND include naming a real, permission-denied (mode 000) file carrying its own deny route is still never opened (assumes a non-root runner, as its sibling does) -- mutation proof: dev/mutants/hook-tests.json (304-inc-follow-gate, 304-inc-line-follow-gate)"
  "push-include-deny-never-executes|case_push_include_deny_never_executes|deny, AND push-guard.sh never invokes git/gh/rm/dirname on the booby-trapped PATH while following an include, AND the fixture repo's and HOME's own file listings stay byte-identical -- mutation proof: dev/mutants/hook-tests.json (304-inc-section, 304-inc-relative)"
  "push-hdrkey-deny-remote-same-line|case_push_hdrkey_deny_remote_same_line|a push key on the same line as its [remote \"origin\"] header: bare and named push, no blank, CRLF, and a trailing comment -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-rest-off, 510-pg-hdr-rest-nostrip)"
  "push-hdrkey-deny-remote-name-chars|case_push_hdrkey_deny_remote_name_chars|a remote subsection name holding ], ; or # still reads as one section -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-rest-off, 510-pg-hdr-raw, 510-pg-hdr-quoted-end)"
  "push-hdrkey-deny-sections-same-line|case_push_hdrkey_deny_sections_same_line|a same-line key under [push], [branch], [include] and [includeIf], the last also with a # in its condition -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-rest-off, 510-pg-hdr-raw)"
  "push-hdrkey-deny-in-included-file|case_push_hdrkey_deny_in_included_file|a same-line key, and the dotted and tab spellings, inside an included file -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-rest-off, 510-pg-hdr-canon-off, 510-pg-hdr-dotted-off, 510-pg-hdr-ws-space-only, 510-pg-hdr-dotted-scope)"
  "push-hdrkey-deny-cap-length-header|case_push_hdrkey_deny_cap_length_header|a header line of exactly the depth-0 line cap, ending in a same-line push key, denies through the config route rather than the configline reason -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-rest-off)"
  "push-hdrkey-deny-alias-same-line|case_push_hdrkey_deny_alias_same_line|a push alias written on its section header's line, in every alias spelling, repo and global, never echoing the alias name -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-rest-off, 510-pg-hdr-raw, 510-pg-hdr-simple-end, 510-pg-hdr-ws-space-only)"
  "push-hdrkey-deny-new-spellings|case_push_hdrkey_deny_new_spellings|the dotted, TAB and blank-run remote, branch and includeIf header spellings git accepts -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-rest-off, 510-pg-hdr-canon-off, 510-pg-hdr-dotted-off, 510-pg-hdr-ws-space-only, 510-pg-hdr-dotted-scope)"
  "push-hdrkey-deny-mixed-spellings|case_push_hdrkey_deny_mixed_spellings|a dotted section part followed by a quoted subsection (branch.v1 \"2\", remote.my \"fork\", alias.x \"y\") reads as git reads it, at depth 0 and in an include -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-rest-off, 510-pg-hdr-canon-off, 510-pg-hdr-mixed-off)"
  "push-hdrkey-deny-confighdr-mixed-upper|case_push_hdrkey_deny_confighdr_mixed_upper|an uppercase letter in the dotted part of a mixed header denies with the fixed confighdr line -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-mixed-upper-off)"
  "push-hdrkey-deny-bom|case_push_hdrkey_deny_bom|a UTF-8 byte-order mark before the first header of the repo config, an included file and the global config does not hide it -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-bom-off)"
  "push-hdrkey-deny-confighdr-chained|case_push_hdrkey_deny_confighdr_chained|a chained header denies with the fixed confighdr line, in the config, in an include, and for a feature push and a non-push command -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-simple-end, 510-pg-hdr-chain-off, 510-pg-hdr-reason)"
  "push-hdrkey-deny-confighdr-quote-shapes|case_push_hdrkey_deny_confighdr_quote_shapes|an escaped closing quote, a backslash-pair alias name, text before the closing bracket and junk before the quote deny with the fixed confighdr line -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-escape-off, 510-pg-hdr-after-quote-off, 510-pg-hdr-namepart-off)"
  "push-hdrkey-deny-confighdr-backslash|case_push_hdrkey_deny_confighdr_backslash|a backslash in a remote or branch subsection, also in an include, denies with the fixed confighdr line -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-backslash-off)"
  "push-hdrkey-deny-confighdr-dotted-upper|case_push_hdrkey_deny_confighdr_dotted_upper|an uppercase letter in a dotted remote subsection denies with the fixed confighdr line -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-dotted-off, 510-pg-hdr-dotted-upper-off)"
  "push-hdrkey-deny-never-executes|case_push_hdrkey_deny_never_executes|the confighdr deny runs nothing on a booby-trapped PATH and leaves the fixture tree byte-identical -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-simple-end, 510-pg-hdr-chain-off, 510-pg-hdr-reason)"
  "push-hdrkey-noop-controls|case_push_hdrkey_noop_controls|no opinion: a same-line url, a commented key, a bracket inside a comment, a non-push alias, another destination, an explicit refspec, a quoted remote name keeping its case, a dotted section for another remote and a subsection-less [remote] -- mutation proof for the quoted-case control: dev/mutants/hook-tests.json (510-pg-hdr-quoted-upper); the other shapes pin that the reader does not over-deny"
  "push-hdrkey-noop-escaped-name|case_push_hdrkey_noop_escaped_name|no opinion: a subsection name ending in a backslash pair with nothing after the closing bracket -- mutation proof: dev/mutants/hook-tests.json (510-pg-hdr-escape-strict)"
  "push-pc-deny-eval|case_push_pc_deny_eval|eval deny: eval git push origin main -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-vocab)"
  "push-pc-deny-eval-quoted|case_push_pc_deny_eval_quoted|eval-quoted deny: eval 'git push origin main' -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-vocab)"
  "push-pc-deny-eval-lead-space|case_push_pc_deny_eval_lead_space|eval-quoted deny with a leading space: eval \" git push origin main\" -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-vocab, 403-pg-pc-empty-tok)"
  "push-pc-deny-eval-split|case_push_pc_deny_eval_split|eval-quoted deny split across tokens: eval \"git \" push origin main -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-vocab, 403-pg-pc-empty-sub)"
  "push-pc-deny-trap|case_push_pc_deny_trap|trap deny: trap 'git push origin main' EXIT -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-vocab)"
  "push-pc-deny-noglob|case_push_pc_deny_noglob|zsh precommand modifier deny: noglob git push origin main -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-vocab)"
  "push-pc-deny-nocorrect|case_push_pc_deny_nocorrect|zsh precommand modifier deny: nocorrect git push origin main -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-vocab)"
  "push-pc-deny-dash|case_push_pc_deny_dash|zsh precommand modifier deny: - git push origin main -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-vocab)"
  "push-pc-deny-repeat|case_push_pc_deny_repeat|zsh repeat deny: repeat 2 git push origin main -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-vocab, 403-pg-pc-repeat)"
  "push-pc-deny-short-if|case_push_pc_deny_short_if|zsh short-if deny: if [[ 1 ]] git push origin main -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-dbracket)"
  "push-pc-noop-eval-feature|case_push_pc_noop_eval_feature|eval no opinion: eval git push origin feature/x (control: a non-default-branch destination behind eval still gets no opinion) -- control, not part of the mutation-proof registry"
  "push-pc-deny-dbracket-refspec|case_push_pc_deny_dbracket_refspec|additive-]] regression proof: git push origin ]] main -- the pre-existing refspec-loop deny must survive the ]] pass -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-dbracket-truncate)"
  "push-pc-deny-dbracket-all|case_push_pc_deny_dbracket_all|additive-]] regression proof: git push ]] --all -- the pre-existing --all deny must survive the ]] pass -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-dbracket-truncate)"
  "push-pc-deny-dbracket-multiline|case_push_pc_deny_dbracket_multiline|additive-]] boundary: if [[ 1<LF>]] git push origin main (]] opens the second physical line) -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-dbracket, 403-pg-pc-dbracket-nopad)"
  "push-pc-deny-dbracket-tab|case_push_pc_deny_dbracket_tab|additive-]] boundary: if [[ 1 ]]<TAB>git push origin main (]] bounded by a tab, not a space) -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-dbracket, 403-pg-pc-dbracket-spaceonly)"
  "push-pc-deny-dbracket-second|case_push_pc_deny_dbracket_second|additive-]] second-match proof: if [[ 1 ]] true; if [[ 1 ]] git push origin main (the deciding ]] is the second one) -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-dbracket-once)"
  "push-pc-deny-dbracket-flood|case_push_pc_deny_dbracket_flood|verdict-only proof: 70x ]] + ; git push origin main (deny via the untouched main split, unaffected by the cap or by tail-cutting) -- control, not part of the mutation-proof registry"
  "push-pc-deny-dbracket-cap|case_push_pc_deny_dbracket_cap|additive-]] cap proof: 65x ]] then git push origin feature/x (a non-default branch) -- without the cap this would correctly resolve to no opinion, so only the DBRACKET_MAX fail-closed sentinel can deny this record -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-dbracket-cap)"
  "push-pc-deny-dbracket-split-push|case_push_pc_deny_dbracket_split_push|disjoint-tail proof: if [[ a ]] git push origin ]] main -- a push cut short by the SECOND ]] fails closed on its own distinct reason -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-dbracket-overlap)"
  "push-pc-deny-dbracket-split-subcmd|case_push_pc_deny_dbracket_split_subcmd|disjoint-tail proof: if [[ a ]] git -C ]] push origin main -- a subcommand search cut mid-value fails closed instead of silently resolving no opinion -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-dbracket-subcmd-open)"
  "push-pc-deny-dbracket-timing|case_push_pc_deny_dbracket_timing|wall-clock proof: a ~1.4KB (x + ]] git push x64 + a x300, newline, git push origin main) shape -- deny AND elapsed time under 5s -- mutation proof: dev/mutants/hook-tests.json (403-pg-pc-dbracket-overlap)"
  "push-cmdcfg-deny-c-remote-push|case_push_cmdcfg_deny_c_remote_push|deny: git -c remote.origin.push=HEAD:main push (the issue's own row-1 shape) -- stderr echoes neither the key nor the value -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel)"
  "push-cmdcfg-deny-c-benign-key|case_push_cmdcfg_deny_c_benign_key|deny: git -c core.pager=cat push origin feature/x -- the deny doesn't depend on the key or the destination -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel)"
  "push-cmdcfg-deny-c-attached|case_push_cmdcfg_deny_c_attached|deny: git -cremote.origin.push=HEAD:main push origin feature/x (attached -c<k=v>) -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel, 439-pg-cmdcfg-c-attached)"
  "push-cmdcfg-deny-config-env-attached|case_push_cmdcfg_deny_config_env_attached|deny: git --config-env=remote.origin.push=VAR push (attached --config-env=<k=V>) -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel, 439-pg-cmdcfg-opt-attached, 439-pg-cmdcfg-opts-vocab)"
  "push-cmdcfg-deny-config-env-detached|case_push_cmdcfg_deny_config_env_detached|deny: git --config-env remote.origin.push=VAR push origin feature/x (detached --config-env <k=V>) -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel, 439-pg-cmdcfg-opt-exact, 439-pg-cmdcfg-opts-vocab)"
  "push-cmdcfg-deny-env-count|case_push_cmdcfg_deny_env_count|deny: GIT_CONFIG_COUNT=1 git push origin feature/x -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel, 439-pg-cmdcfg-env-arm, 439-pg-cmdcfg-env-vocab)"
  "push-cmdcfg-deny-env-key|case_push_cmdcfg_deny_env_key|deny: GIT_CONFIG_KEY_7zq=remote.origin.push git push origin feature/x -- stderr never echoes the matched name suffix -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel, 439-pg-cmdcfg-env-arm, 439-pg-cmdcfg-env-prefixes)"
  "push-cmdcfg-deny-env-value|case_push_cmdcfg_deny_env_value|deny: GIT_CONFIG_VALUE_0=HEAD:main git push origin feature/x -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel, 439-pg-cmdcfg-env-arm, 439-pg-cmdcfg-env-prefixes)"
  "push-cmdcfg-deny-env-count-triple|case_push_cmdcfg_deny_env_count_triple|deny: the issue's own row-2 shape verbatim (GIT_CONFIG_COUNT/KEY_0/VALUE_0, bare push) -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel, 439-pg-cmdcfg-env-arm)"
  "push-cmdcfg-deny-env-parameters|case_push_cmdcfg_deny_env_parameters|deny: GIT_CONFIG_PARAMETERS=\"'remote.origin.push'='HEAD:main'\" git push (the issue's own row-3 shape) -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel, 439-pg-cmdcfg-env-arm, 439-pg-cmdcfg-env-vocab)"
  "push-cmdcfg-deny-env-prefix|case_push_cmdcfg_deny_env_prefix|deny: the same GIT_CONFIG_COUNT/KEY_0/VALUE_0 triple behind an \"env\" prefix word -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel, 439-pg-cmdcfg-env-arm)"
  "push-cmdcfg-deny-env-global|case_push_cmdcfg_deny_env_global|deny: GIT_CONFIG_GLOBAL=/nonexistent/x git push origin feature/x -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel, 439-pg-cmdcfg-env-arm, 439-pg-cmdcfg-env-vocab)"
  "push-cmdcfg-deny-env-system|case_push_cmdcfg_deny_env_system|deny: GIT_CONFIG_SYSTEM=/nonexistent/x git push origin feature/x -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel, 439-pg-cmdcfg-env-arm, 439-pg-cmdcfg-env-vocab)"
  "push-cmdcfg-deny-never-executes|case_push_cmdcfg_deny_never_executes|deny via the command-line-config route, AND push-guard.sh never invokes git/gh/rm/dirname on the booby-trapped PATH, AND the fixture repo's file listing is byte-identical before/after -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel)"
  "push-cmdcfg-deny-codex-main-session|case_push_cmdcfg_deny_codex_main_session|deny: a Codex-shaped main-session payload (mk_codex_shell '') with git -c remote.origin.push=HEAD:main push -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel)"
  "push-cmdcfg-noop-nonpush-segment|case_push_cmdcfg_noop_nonpush_segment|no opinion: git -c core.pager=cat log && git push origin feature/x -- only push segments are judged, and the flag doesn't leak across segments -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-push-only, 439-pg-cmdcfg-leak)"
  "push-cmdcfg-noop-env-nosystem|case_push_cmdcfg_noop_env_nosystem|no opinion: GIT_CONFIG_NOSYSTEM=1 git push origin feature/x -- exact vocabulary, not every GIT_CONFIG_-prefixed name -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-env-exact)"
  "push-cmdcfg-deny-precedence|case_push_cmdcfg_deny_precedence|deny: GIT_DIR=x GIT_CONFIG_COUNT=1 git push origin feature/x -- the command-line-config reason wins over a #292 unresolved target in the same segment -- mutation proof: dev/mutants/hook-tests.json (439-pg-cmdcfg-sentinel, 439-pg-cmdcfg-env-arm, 439-pg-cmdcfg-env-vocab, 439-pg-cmdcfg-order)"
  "push-parse-deny-quoted-c|case_pp_deny_quoted_c|deny: git \"-c\" remote.origin.push=HEAD:main push (quoted option in the option slot) -- mutation proof: dev/mutants/hook-tests.json (449-pg-obscured-off)"
  "push-parse-deny-escaped-c|case_pp_deny_escaped_c|deny: git \\-c remote.origin.push=HEAD:main push (backslash-escaped option) -- mutation proof: dev/mutants/hook-tests.json (449-pg-obscured-off)"
  "push-parse-deny-quoted-git-dir|case_pp_deny_quoted_git_dir|deny: git \"--git-dir=../other/.git\" push origin develop (only the new rule can deny it) -- mutation proof: dev/mutants/hook-tests.json (449-pg-obscured-off, 449-pg-obscured-normalize)"
  "push-parse-deny-glued-quote-c|case_pp_deny_glued_quote_c|deny: git -\"c\" remote.origin.push=HEAD:main push (quote glued inside the option) -- mutation proof: dev/mutants/hook-tests.json (449-pg-obscured-off)"
  "push-parse-noop-quoted-opt-nonpush|case_pp_noop_quoted_opt_nonpush|no opinion: a quoted option on a non-push git command, then a feature push -- mutation proof: dev/mutants/hook-tests.json (449-pg-lost-ungated)"
  "push-parse-noop-quoted-opt-push-word|case_pp_noop_quoted_opt_push_word|no opinion: git \"--no-pager\" log --grep push, then a feature push -- mutation proof: dev/mutants/hook-tests.json (449-pg-lost-ungated, 449-pg-lost-unarmed)"
  "push-parse-deny-assign-dquote-space|case_pp_deny_assign_dquote_space|deny: X=\"a b\" git push origin main as an unresolved target, not via the default-branch route -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-off, 449-pg-unbalanced-dq)"
  "push-parse-deny-assign-squote-space|case_pp_deny_assign_squote_space|deny: X='a b' git push origin feature/x -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-off, 449-pg-unbalanced-sq)"
  "push-parse-deny-assign-backslash-space|case_pp_deny_assign_backslash_space|deny: X=a\\ b git push origin feature/x -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-off, 449-pg-unbalanced-bs)"
  "push-parse-deny-git-dir-space|case_pp_deny_git_dir_space|deny: GIT_DIR=\"../a b/.git\" git push origin feature/x keeps the earlier #292 reason GIT_DIR= -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-off, 449-pg-unbalanced-dq, 449-pg-lost-unres-precedence)"
  "push-parse-deny-env-quoted-assign|case_pp_deny_env_quoted_assign|deny: env \"X=a\" git push origin feature/x (quoted assignment after a prefix word) -- mutation proof: dev/mutants/hook-tests.json (449-pg-prefix-quoted-shape)"
  "push-parse-deny-env-quoted-opt|case_pp_deny_env_quoted_opt|deny: env \"-C\" ../other git push origin feature/x (quoted option after a prefix word) -- mutation proof: dev/mutants/hook-tests.json (449-pg-prefix-quoted-shape)"
  "push-parse-deny-env-u-quoted-value|case_pp_deny_env_u_quoted_value|deny: env -u \"A B\" git push origin feature/x (unbalanced value of -u) -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-dq, 449-pg-env-u-value-check)"
  "push-parse-noop-assign-space-nonpush|case_pp_noop_assign_space_nonpush|no opinion: X=\"a b\" git status, then a feature push -- mutation proof: dev/mutants/hook-tests.json (449-pg-lost-ungated)"
  "push-parse-noop-assign-space-commit|case_pp_noop_assign_space_commit|no opinion: GIT_AUTHOR_NAME=\"A B\" git commit -m \"fix push\", then a feature push -- mutation proof: dev/mutants/hook-tests.json (449-pg-lost-ungated, 449-pg-lost-unarmed)"
  "push-parse-noop-heredoc-apostrophe|case_pp_noop_heredoc_apostrophe|no opinion: a heredoc commit whose body line starts Don't, then the harness's own push -- control, not part of the mutation-proof registry"
  "push-parse-deny-env-u-main|case_pp_deny_env_u_main|deny: env -u FOO git push origin main via the default-branch route (-u consumes FOO) -- mutation proof: dev/mutants/hook-tests.json (449-pg-env-u-consume)"
  "push-parse-noop-env-u-feature|case_pp_noop_env_u_feature|no opinion: env -u FOO git push origin feature/x -- control, not part of the mutation-proof registry"
  "push-parse-noop-env-unset-attached|case_pp_noop_env_unset_attached|no opinion: env --unset=FOO -uBAR git push origin feature/x (attached forms) -- mutation proof: dev/mutants/hook-tests.json (449-pg-env-u-attached)"
  "push-parse-deny-env-u-attached-unbalanced|case_pp_deny_env_u_attached_unbalanced|deny: env -u\"A B\" git push origin feature/x (unbalanced attached -u value) -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-dq, 449-pg-env-u-attached, 449-pg-env-u-attached-quote)"
  "push-parse-deny-gopt-value-c|case_pp_deny_gopt_value_c|deny: git -c \"user.name=A B\" push origin feature/x -- the quoted -c value splits -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-dq, 449-pg-lost-precedence, 449-pg-gopt-value-off, 449-pg-lost-mode2)"
  "push-parse-deny-gopt-value-sshcommand|case_pp_deny_gopt_value_sshcommand|deny: git -c \"core.sshCommand=ssh -i k\" push origin main -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-dq, 449-pg-gopt-value-off, 449-pg-lost-mode2)"
  "push-parse-deny-gopt-value-namespace|case_pp_deny_gopt_value_namespace|deny: git --namespace \"a b\" push origin feature/x -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-dq, 449-pg-gopt-value-off, 449-pg-lost-mode2)"
  "push-parse-deny-gopt-value-trailing-option|case_pp_deny_gopt_value_trailing_option|deny: git -c \"user.name=A b -c\" push origin main -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-dq, 449-pg-lost-mode2-skip, 449-pg-gopt-value-off, 449-pg-lost-mode2)"
  "push-parse-deny-gopt-value-attached-trailing-option|case_pp_deny_gopt_value_attached_trailing_option|deny: git -c k=\"a b -c\" push origin main -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-dq, 449-pg-lost-mode2-skip, 449-pg-gopt-value-off, 449-pg-lost-mode2)"
  "push-parse-deny-gopt-value-trailing-namespace|case_pp_deny_gopt_value_trailing_namespace|deny: git --namespace \"a X --exec-path\" push origin main -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-dq, 449-pg-lost-mode2-skip, 449-pg-gopt-value-off, 449-pg-lost-mode2)"
  "push-parse-deny-gopt-attached-value|case_pp_deny_gopt_attached_value|deny: git --exec-path=\"a b\" push origin feature/x -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-dq, 449-pg-gopt-attached-off, 449-pg-lost-mode2)"
  "push-parse-deny-quoted-c-split-value|case_pp_deny_quoted_c_split_value|deny: git \"-c\" \"a b\" push origin feature/x -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-dq, 449-pg-gopt-value-off, 449-pg-lost-mode2)"
  "push-parse-noop-gopt-value-nonpush|case_pp_noop_gopt_value_nonpush|no opinion: git -c \"user.name=A B\" commit -m x, then a feature push -- mutation proof: dev/mutants/hook-tests.json (449-pg-lost-ungated)"
  "push-parse-noop-c-space-value|case_pp_noop_c_space_value|no opinion: git -C \"../demo wt-1\" push origin feature/x (the approved quoted -C residual) -- mutation proof: dev/mutants/hook-tests.json (449-pg-gopt-c-exempt)"
  "push-parse-deny-squote-c|case_pp_deny_squote_c|deny: git '-c' remote.origin.push=HEAD:main push (single-quoted option) -- mutation proof: dev/mutants/hook-tests.json (449-pg-obscured-off, 449-pg-quote-bearing-sq)"
  "push-parse-deny-prefix-gopt-value|case_pp_deny_prefix_gopt_value|deny: X=\"a b\" git -C ../other push origin feature/x -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-off, 449-pg-unbalanced-dq, 449-pg-lost-gopt-skip)"
  "push-parse-deny-quoted-opt-gopt-value|case_pp_deny_quoted_opt_gopt_value|deny: git \"--no-pager\" -C ../other push origin feature/x -- mutation proof: dev/mutants/hook-tests.json (449-pg-obscured-off, 449-pg-lost-gopt-skip, 449-pg-lost-gopt-skip-armed1)"
  "push-parse-deny-env-chdir-prefix-basename|case_pp_deny_env_chdir_prefix_basename|deny: env --chdir=../env git push origin feature/x -- mutation proof: dev/mutants/hook-tests.json (449-pg-env-lost-off, 449-pg-env-arm-prefix-guard)"
  "push-parse-deny-env-lone-dash|case_pp_deny_env_lone_dash|deny: env - git push origin feature/x -- mutation proof: dev/mutants/hook-tests.json (449-pg-env-lost-off, 449-pg-env-arm-prefix-guard)"
  "push-parse-deny-env-u-git-dir|case_pp_deny_env_u_git_dir|deny: env -u FOO GIT_DIR=../x/.git git push origin feature/x (-u value consumed, GIT_DIR= reason) -- mutation proof: dev/mutants/hook-tests.json (449-pg-env-u-consume)"
  "push-parse-deny-env-c|case_pp_deny_env_c|deny: env -C ../other git push origin main as an unsupported env option -- mutation proof: dev/mutants/hook-tests.json (449-pg-env-lost-off)"
  "push-parse-deny-env-chdir|case_pp_deny_env_chdir|deny: env --chdir=../other git push origin feature/x as an unsupported env option -- mutation proof: dev/mutants/hook-tests.json (449-pg-env-lost-off)"
  "push-parse-deny-env-s|case_pp_deny_env_s|deny: env -S 'git push origin feature/x' as an unsupported env option -- mutation proof: dev/mutants/hook-tests.json (449-pg-env-lost-off)"
  "push-parse-deny-env-s-attached|case_pp_deny_env_s_attached|deny: env -S\"git\\tpush origin feature/x\" (attached body, literal backslash-t) as an unsupported env option -- mutation proof: dev/mutants/hook-tests.json (449-pg-env-lost-off, 449-pg-lost-same-token)"
  "push-parse-noop-env-c-nonpush|case_pp_noop_env_c_nonpush|no opinion: env -C ../other git status, then a feature push -- mutation proof: dev/mutants/hook-tests.json (449-pg-lost-ungated)"
  "push-parse-noop-env-i-feature|case_pp_noop_env_i_feature|no opinion: env -i git push origin feature/x -- mutation proof: dev/mutants/hook-tests.json (449-pg-env-novalue-vocab)"
  "push-parse-noop-sudo-opt-feature|case_pp_noop_sudo_opt_feature|no opinion: sudo -E git push origin feature/x (a dash option after a non-env prefix word) -- mutation proof: dev/mutants/hook-tests.json (449-pg-env-context)"
  "push-parse-deny-lost-cmdcfg|case_pp_deny_lost_cmdcfg|deny: GIT_CONFIG_COUNT=1 X=\"a b\" git push origin feature/x with the command-line-config message -- mutation proof: dev/mutants/hook-tests.json (449-pg-unbalanced-off, 449-pg-unbalanced-dq, 449-pg-lost-precedence)"
  "push-parse-deny-never-executes|case_pp_deny_never_executes|deny via the new route, AND push-guard.sh never invokes git/gh/rm/dirname on the booby-trapped PATH, AND the fixture repo's file listing is byte-identical -- mutation proof: dev/mutants/hook-tests.json (449-pg-obscured-off)"
  "push-parse-deny-codex-main-session|case_pp_deny_codex_main_session|deny: a Codex-shaped main-session payload with env -C ../other git push origin main -- mutation proof: dev/mutants/hook-tests.json (449-pg-env-lost-off, 494-pg-wd-precedence)"
  "push-parse-noop-c-quoted-value|case_pp_noop_c_quoted_value|no opinion: git -C \"../demo-wt-1\" push -u origin \"claude/17-a\" (the harness's own worktree shape) -- control, not part of the mutation-proof registry"
  "push-lostscan-noop-flood|case_push_lostscan_noop_flood|FLOOD+TIMING: large records, one per trigger, then a feature push -- no opinion; token count sized from a same-run, mutant-invariant twin control, deadline a multiple of the predicted linear cost (#507) -- mutation proof: dev/mutants/hook-tests.json (449-pg-scan-once)"
  "push-rtexp-deny-dollar-name|case_push_rtexp_deny_dollar_name|deny: \$X (and \"\$X\", a\$X, env \$X, sudo -\$X) before a push, naming the command-prefix reason and never echoing input -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-prefix-off)"
  "push-rtexp-deny-special|case_push_rtexp_deny_special|deny: \$1 and \$@ in command position -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-prefix-off, 508-pg-rx-re-special, 508-pg-rx-re-zsh)"
  "push-rtexp-deny-quote-expansion|case_push_rtexp_deny_quote_expansion|deny: \$'' , \$\"\" and env \$'A=b' in command position -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-prefix-off, 508-pg-rx-re-sq, 508-pg-rx-re-dq)"
  "push-rtexp-deny-env-assign|case_push_rtexp_deny_env_assign|deny: an env assignment whose value holds an expansion -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-prefix-off, 508-pg-rx-assign-prefix)"
  "push-rtexp-deny-env-u-value|case_push_rtexp_deny_env_u_value|deny: env -u with an expansion value -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-prefix-off, 508-pg-rx-env-u-value)"
  "push-rtexp-deny-env-u-attached|case_push_rtexp_deny_env_u_attached|deny: env -u<expansion> attached -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-prefix-off, 508-pg-rx-env-u-attached)"
  "push-rtexp-deny-built-command-word|case_push_rtexp_deny_built_command_word|deny: \$G push origin main with no git text in the raw stdin -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-prefix-off, 508-pg-rx-armed, 508-pg-fastpath-dollar)"
  "push-rtexp-deny-git-slot|case_push_rtexp_deny_git_slot|deny: an expansion in the git option slot, naming the git-options reason -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-git-off, 508-pg-rx-git-armed2, 508-pg-rx-re-zsh)"
  "push-rtexp-deny-git-slot-ansi-c-opt|case_push_rtexp_deny_git_slot_ansi_c_opt|deny: git \$'-c' core.pager=cat push -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-git-off)"
  "push-rtexp-deny-git-slot-push-text|case_push_rtexp_deny_git_slot_push_text|deny: git \$X'push' origin main -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-git-off, 508-pg-rx-git-self)"
  "push-rtexp-deny-git-slot-ansi-c-literal|case_push_rtexp_deny_git_slot_ansi_c_literal|deny: a whole-word plain ANSI-C or locale literal in the git slot is the name it spells -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-git-off, 508-pg-rx-ansic-literal, 508-pg-rx-ansic-failclosed, 508-pg-rx-ansic-locale, 508-pg-rx-ansic-backslash)"
  "push-rtexp-deny-git-slot-ansi-c-concat|case_push_rtexp_deny_git_slot_ansi_c_concat|deny: any git-slot word holding a dollar sign and a quote that is not exactly one plain segment fails closed (concatenations, mixed quotes, backslashes, attached values); \$'status' stays no opinion -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-git-off, 508-pg-rx-git-skip-off, 508-pg-rx-ansic-literal, 508-pg-rx-ansic-failclosed, 508-pg-rx-ansic-locale, 508-pg-rx-ansic-backslash)"
  "push-rtexp-deny-git-slot-dash-led|case_push_rtexp_deny_git_slot_dash_led|deny: a dash-led expansion first in the git slot keeps base subcommand choice and a whole-slot scan -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-git-skip-off, 508-pg-rx-git-trailing, 508-pg-rx-git-nondash, 508-pg-rx-git-wholeslot)"
  "push-rtexp-deny-git-slot-trailing|case_push_rtexp_deny_git_slot_trailing|deny: an expansion as the last word of the git option slot keeps the alias and relocation checks -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-git-trailing)"
  "push-rtexp-deny-git-slot-alias|case_push_rtexp_deny_git_slot_alias|deny: git \$X zqp with a push alias in .git/config -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-git-skip-off, 508-pg-rx-git-ungated)"
  "push-rtexp-deny-prefix-alias|case_push_rtexp_deny_prefix_alias|deny: \$X git zqp with a push alias in .git/config -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-skip-off, 508-pg-rx-ungated)"
  "push-rtexp-deny-prefix-cd|case_push_rtexp_deny_prefix_cd|deny: \$X cd ../other then a push resolves cd as the command word -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-skip-off, 508-pg-rx-ungated)"
  "push-rtexp-deny-env-s-brace|case_push_rtexp_deny_env_s_brace|deny: env -S with a brace expansion cut by the segmenter -- mutation proof: dev/mutants/hook-tests.json (508-pg-rec-lost-off)"
  "push-rtexp-deny-env-s-cmdsubst|case_push_rtexp_deny_env_s_cmdsubst|deny: env -S with a command substitution cut by the segmenter -- mutation proof: dev/mutants/hook-tests.json (508-pg-rec-lost-off)"
  "push-rtexp-deny-env-c-brace|case_push_rtexp_deny_env_c_brace|deny: env -C \${D} before a push -- mutation proof: dev/mutants/hook-tests.json (508-pg-rec-lost-off)"
  "push-rtexp-deny-codex-shaped|case_push_rtexp_deny_codex_shaped|deny: a Codex-shaped main-session payload names the new reason -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-prefix-off)"
  "push-rtexp-noop-status|case_push_rtexp_noop_status|no opinion: \$X before a git status, then a feature push -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-ungated)"
  "push-rtexp-noop-editor|case_push_rtexp_noop_editor|no opinion: \$EDITOR README.md, then a feature push -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-ungated)"
  "push-rtexp-noop-git-slot-status|case_push_rtexp_noop_git_slot_status|no opinion: an expansion in the git slot of a git status, then a feature push -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-git-ungated)"
  "push-rtexp-noop-bare-assign|case_push_rtexp_noop_bare_assign|no opinion: a bare assignment with an expansion value before a feature push -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-bare-assign)"
  "push-rtexp-noop-prompt-dollar|case_push_rtexp_noop_prompt_dollar|no opinion: a heredoc line starting with a lone dollar sign -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-lone-dollar)"
  "push-rtexp-noop-dir-expansion|case_push_rtexp_noop_dir_expansion|no opinion: an expansion only in the directory part of a command word -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-lone-dollar, 508-pg-rx-basename)"
  "push-rtexp-noop-env-s-uncut|case_push_rtexp_noop_env_s_uncut|no opinion: env -S with no expansion in an uncut record -- mutation proof: dev/mutants/hook-tests.json (508-pg-rec-cut-gate)"
  "push-rtexp-noop-env-c-status|case_push_rtexp_noop_env_c_status|no opinion: env -C \${D} git status (no push can follow) -- mutation proof: dev/mutants/hook-tests.json (508-pg-rec-lost-always)"
  "push-rtexp-noop-controls|case_push_rtexp_noop_controls|no opinion: expansion text outside command position, and the skills' own worktree push shape -- control, not part of the mutation-proof registry"
  "push-rtexpscan-noop-flood|case_push_rtexpscan_noop_flood|FLOOD+TIMING: one record per expansion trigger shape, then a feature push -- no opinion; token count sized from a same-run, mutant-invariant twin control, deadline a multiple of the predicted linear cost -- mutation proof: dev/mutants/hook-tests.json (508-pg-rx-scan-per-token)"
  "push-alias-deny-repo-config|case_al_deny_repo_config|a config-file alias (zqp = push) in .git/config denies git zqp origin main with the alias line naming .git/config and never echoing the alias name, and the raw stdin carries no push literal -- mutation proof: dev/mutants/hook-tests.json (448-pg-fastpath-push, 448-pg-alias-early-exit, 448-pg-alias-emit, 448-pg-alias-section)"
  "push-alias-deny-feature-dest|case_al_deny_feature_dest|a push alias denies even when the destination is a feature branch -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-emit)"
  "push-alias-deny-global-config|case_al_deny_global_config|an alias in \$HOME/.gitconfig denies and names your global git config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-section)"
  "push-alias-deny-xdg-config|case_al_deny_xdg_config|an alias in \$XDG_CONFIG_HOME/git/config denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-section)"
  "push-alias-deny-include|case_al_deny_include|an alias in an included file denies, naming the source with (via include) -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-section)"
  "push-alias-deny-shell|case_al_deny_shell|a ! shell alias denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-shell)"
  "push-alias-deny-option-first|case_al_deny_option_first|an alias whose expansion starts with a git option (--no-pager push) denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-dash)"
  "push-alias-deny-chain|case_al_deny_chain|an alias naming another defined alias (a = b, b = push) denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-chain)"
  "push-alias-deny-case-fold|case_al_deny_case_fold|[ALIAS] with Zp = PUSH run as git zp denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-fold)"
  "push-alias-deny-continuation|case_al_deny_continuation|an alias value ending in a backslash continuation denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-continuation)"
  "push-alias-deny-quoted-word|case_al_deny_quoted_word|an alias whose first word is the quoted and escaped spelling of push denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-word-strip)"
  "push-alias-deny-c-target|case_al_deny_c_target|an alias defined only in a resolved -C worktree denies a segment run there -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-c-target)"
  "push-alias-deny-session-after-c-target|case_al_deny_session_after_c_target|the session alias still denies after an earlier -C segment resolved another checkout -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-session-restore)"
  "push-alias-deny-cmdline-c|case_al_deny_cmdline_c|git -c alias.p=push p denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-cmdline)"
  "push-alias-deny-cmdline-include|case_al_deny_cmdline_include|git -c include.path=/x p denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-cmdline)"
  "push-alias-deny-config-env|case_al_deny_config_env|git --config-env=alias.p=PV p denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-cmdline)"
  "push-alias-deny-env-key|case_al_deny_env_key|GIT_CONFIG_COUNT/KEY/VALUE naming an alias denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-cmdline)"
  "push-alias-deny-home-nonpush|case_al_deny_home_nonpush|an inline HOME= on a non-push git segment denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-reloc-nonpush)"
  "push-alias-deny-env-xdg-nonpush|case_al_deny_env_xdg_nonpush|env XDG_CONFIG_HOME= on a non-push git segment denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-reloc-nonpush)"
  "push-alias-deny-global-env-nonpush|case_al_deny_global_env_nonpush|an inline GIT_CONFIG_GLOBAL= on a non-push git segment denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-reloc-nonpush)"
  "push-alias-deny-xcfg-export-home|case_al_deny_xcfg_export_home|export HOME=/x in an earlier segment makes a later alias candidate deny -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-xcfg)"
  "push-alias-deny-xcfg-bare-xdg|case_al_deny_xcfg_bare_xdg|a bare XDG_CONFIG_HOME= segment makes a later alias candidate deny -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-xcfg)"
  "push-alias-deny-quoted-option|case_al_deny_quoted_option|git \"-c\" alias.p=push p origin main denies (#449 interplay) -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-option)"
  "push-alias-deny-quoted-space-assign|case_al_deny_quoted_space_assign|HOME=\"/tmp/a b\" git p origin main denies as unreadable config (#449 interplay) -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-prefix, 448-pg-alias-lost-reloc)"
  "push-alias-deny-lost-prefix-config|case_al_deny_lost_prefix_config|X=\"a b\" git zqp denies via the config-file alias (#449 interplay) -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-prefix)"
  "push-alias-deny-lost-option-config|case_al_deny_lost_option_config|git \"--no-pager\" zqp denies via the config-file alias (#449 interplay) -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-option)"
  "push-alias-deny-lost-value-config|case_al_deny_lost_value_config|git -c \"user.name=A B\" zqp denies via the config-file alias (#449 interplay) -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-option)"
  "push-alias-deny-lost-reloc-prefix|case_al_deny_lost_reloc_prefix|env XDG_CONFIG_HOME=\"/a b\" git p denies as unreadable config (#449 interplay) -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-reloc)"
  "push-alias-deny-codex-shaped|case_al_deny_codex_shaped|a Codex-shaped main-session payload with a repo alias denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-emit)"
  "push-alias-deny-never-executes|case_al_deny_never_executes|the alias route never invokes git/gh/rm/dirname on a booby-trapped PATH and leaves the fixture tree byte-identical -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-emit)"
  "push-alias-noop-nonpush-alias|case_al_noop_nonpush_alias|git st with st = status is no opinion -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-classify-open)"
  "push-alias-noop-builtins-with-push-alias|case_al_noop_builtins_with_push_alias|built-in subcommands stay no opinion while p = push is configured -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-name-match)"
  "push-alias-noop-undefined-subcommand|case_al_noop_undefined_subcommand|git lfs pull (no alias.lfs) is no opinion -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-name-match)"
  "push-alias-noop-other-alias-word|case_al_noop_other_alias_word|git co main with co = checkout and p = push is no opinion -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-classify-open)"
  "push-alias-noop-c-benign|case_al_noop_c_benign|git -c core.pager=cat st is no opinion -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-cmdline-text)"
  "push-alias-noop-env-nosystem|case_al_noop_env_nosystem|GIT_CONFIG_NOSYSTEM=1 git st is no opinion -- control, not part of the mutation-proof registry"
  "push-alias-noop-scoped-home|case_al_noop_scoped_home|HOME=/x scoped to an ls segment leaves a later git st no opinion -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-xcfg-scoped)"
  "push-alias-noop-harness-shapes|case_al_noop_harness_shapes|the harness own add/commit/push shape is no opinion with p = push and up = !git pull configured -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-name-match)"
  "push-alias-noop-quoted-prefix-nonalias|case_al_noop_quoted_prefix_nonalias|X=\"a b\" git status stays no opinion with a push alias configured -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-classify-open)"
  "push-alias-noop-quoted-option-nonalias|case_al_noop_quoted_option_nonalias|git \"--no-pager\" log -5 stays no opinion with a push alias configured -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-classify-open)"
  "push-alias-noop-lost-no-git|case_al_noop_lost_no_git|a quote-split assignment before a command that never names git stays no opinion even with alias text in it -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-needgit)"
  "push-alias-deny-subsection-repo|case_al_deny_subsection_repo|[alias \"zqp\"] command = push in .git/config denies git zqp -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-subsection)"
  "push-alias-deny-subsection-global|case_al_deny_subsection_global|[alias \"zqp\"] command = push in the global config denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-subsection)"
  "push-alias-noop-subsection|case_al_noop_subsection|a subsection alias to status, and a subsection key other than command, stay no opinion -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-classify-open)"
  "push-alias-deny-escape-tab|case_al_deny_escape_tab|an alias value push, backslash t, origin denies (the escape is a word break) -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-escape)"
  "push-alias-deny-escape-newline|case_al_deny_escape_newline|an alias value push, backslash n, origin denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-escape)"
  "push-alias-deny-cr-mid|case_al_deny_cr_mid|a raw CR inside an alias value denies instead of fusing the words around it -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-cr-mid)"
  "push-alias-deny-cr-mid-subsection|case_al_deny_cr_mid_subsection|a raw CR inside a subsection alias value denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-cr-mid-subsection)"
  "push-alias-deny-env-quoted-home|case_al_deny_env_quoted_home|env \"HOME=<d>\" git p denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-quoted-reloc)"
  "push-alias-deny-env-squoted-xdg|case_al_deny_env_squoted_xdg|env single-quoted XDG_CONFIG_HOME=/x git p denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-quoted-reloc)"
  "push-alias-deny-command-env-quoted|case_al_deny_command_env_quoted|command env \"HOME=<d>\" git p denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-quoted-reloc)"
  "push-alias-deny-env-s-reloc|case_al_deny_env_s_reloc|env -S \"HOME=<d> git p origin main\" denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-quoted-reloc)"
  "push-alias-deny-xcfg-export-gitconfig|case_al_deny_xcfg_export_gitconfig|an exported GIT_CONFIG_COUNT/KEY/VALUE triple makes a later alias candidate deny -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-xcfg-export-cfg)"
  "push-alias-deny-xcfg-export-parameters|case_al_deny_xcfg_export_parameters|an exported GIT_CONFIG_PARAMETERS makes a later alias candidate deny -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-xcfg-export-cfg)"
  "push-alias-deny-xcfg-bare-gitconfig|case_al_deny_xcfg_bare_gitconfig|a bare GIT_CONFIG_COUNT= segment makes a later alias candidate deny -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-xcfg-bare-cfg)"
  "push-alias-deny-dollar-c|case_al_deny_dollar_c|git -c \$K=push p (a variable-built key) denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-dollar)"
  "push-alias-deny-dollar-env-key|case_al_deny_dollar_env_key|GIT_CONFIG_KEY_0=\$K on an alias candidate denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-dollar)"
  "push-alias-deny-dollar-parameters|case_al_deny_dollar_parameters|GIT_CONFIG_PARAMETERS=\$X on an alias candidate denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-dollar)"
  "push-alias-deny-dollar-subst|case_al_deny_dollar_subst|git -c with a command substitution in the key denies even though it splits the segment -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-dollar)"
  "push-alias-deny-subcmd-fold|case_al_deny_subcmd_fold|git ZQP with zqp = push denies (alias keys match case-insensitively) -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-subcmd-fold)"
  "push-alias-noop-c-target-clean|case_al_noop_c_target_clean|a push alias in the session does not leak into a resolved -C checkout that defines none -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-reset)"
  "push-alias-deny-subsection-spaces|case_al_deny_subsection_spaces|[alias   \"zqp\"] (several blanks) command = push denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-subsection-space)"
  "push-alias-deny-subsection-tab|case_al_deny_subsection_tab|[alias<TAB>\"zqp\"] command = push denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-subsection-tab)"
  "push-alias-deny-subsection-dotted|case_al_deny_subsection_dotted|the deprecated [alias.zqp] command = push denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-subsection-dot)"
  "push-alias-deny-subsection-escaped-name|case_al_deny_subsection_escaped_name|a backslash-escaped subsection name denies (the name is never read) -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-subsection-name)"
  "push-alias-deny-subsection-odd-name|case_al_deny_subsection_odd_name|subsection names holding a blank or a slash deny -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-subsection-name)"
  "push-alias-deny-subsection-any-subcommand|case_al_deny_subsection_any_subcommand|a push-ish subsection alias makes every alias candidate of that checkout deny (deliberate over-block) -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-subsection-name)"
  "push-alias-deny-env-s-attached|case_al_deny_env_s_attached|env -S\"HOME=/x git p ...\" (attached string) denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-substring)"
  "push-alias-deny-env-s-squoted|case_al_deny_env_s_squoted|env -S single-quoted XDG_CONFIG_HOME string denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-substring)"
  "push-alias-deny-env-split-string|case_al_deny_env_split_string|env --split-string=\"HOME=/x git p ...\" denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-substring)"
  "push-alias-deny-env-s-underscore-all|case_al_deny_env_s_underscore_all|env -S with HOME and git packed into one token by backslash-underscore separators denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-trigger-git)"
  "push-alias-deny-env-s-underscore-git|case_al_deny_env_s_underscore_git|env -S with HOME and git in the trigger token, the rest as plain words, denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-trigger-git)"
  "push-alias-deny-env-quoted-gitconfig|case_al_deny_env_quoted_gitconfig|env \"GIT_CONFIG_PARAMETERS=\$X\" git p denies as unreadable config -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-lost-quoted-cfg)"
  "push-alias-deny-backtick-quoted|case_al_deny_backtick_quoted|a backtick substitution inside a quoted -c key on an alias candidate denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-backtick)"
  "push-alias-deny-backtick-bare|case_al_deny_backtick_bare|a backtick substitution as the -c key on an alias candidate denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-backtick)"
  "push-alias-deny-backtick-config-env|case_al_deny_backtick_config_env|a backtick substitution in a --config-env key on an alias candidate denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-backtick)"
  "push-alias-noop-dollar-not-config|case_al_noop_dollar_not_config|a dollar sign outside the config value tokens (-C \"\$WT\", X=\$Y) stays no opinion -- control, not part of the mutation-proof registry"
  "push-aliasdl-deny-flood|case_al_deny_flood|FLOOD+TIMING: a flood of clean alias candidates, sized from a same-run per-candidate cost, then a push alias denies with the deadline line, calibrated from a same-run knob-0 control (#476) -- mutation proof: dev/mutants/hook-tests.json (448-pg-aliasdl-check-off)"
  "push-aliasdl-deny-budget-zero|case_al_deny_budget_zero|a bare git log at knob 0 reaches the deadline sample instead of the early exit -- mutation proof: dev/mutants/hook-tests.json (448-pg-alias-early-exit)"
  "push-reloc-deny-home-inline|case_rl_deny_home_inline|HOME=<d> git push with a push route in <d>/.gitconfig denies with the command-line-config message -- mutation proof: dev/mutants/hook-tests.json (448-pg-reloc-vocab, 448-pg-reloc-push-sentinel)"
  "push-reloc-deny-xdg-inline|case_rl_deny_xdg_inline|XDG_CONFIG_HOME=/nonexistent git push denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-reloc-vocab, 448-pg-reloc-push-sentinel)"
  "push-reloc-deny-env-home|case_rl_deny_env_home|env HOME=/nonexistent git push denies -- mutation proof: dev/mutants/hook-tests.json (448-pg-reloc-vocab, 448-pg-reloc-push-sentinel)"
  "push-reloc-deny-xseg-export-home|case_rl_deny_xseg_export_home|export HOME=/x then a push denies with the HOME/XDG reason -- mutation proof: dev/mutants/hook-tests.json (448-pg-reloc-xseg)"
  "push-reloc-deny-xseg-bare-xdg|case_rl_deny_xseg_bare_xdg|a bare XDG_CONFIG_HOME= then a push denies with the HOME/XDG reason -- mutation proof: dev/mutants/hook-tests.json (448-pg-reloc-xseg)"
  "push-reloc-noop-similar-name|case_rl_noop_similar_name|HOMEBREW_NO_AUTO_UPDATE=1 git push origin feature/x is no opinion -- mutation proof: dev/mutants/hook-tests.json (448-pg-reloc-exact)"
  "push-reloc-noop-scoped|case_rl_noop_scoped|HOME=/x scoped to ls then a feature push is no opinion -- mutation proof: dev/mutants/hook-tests.json (448-pg-reloc-scoped)"
  "push-deny-crlf-push-literal|case_pd_crlf_push_literal|git pu<CR>sh origin main denies once the raw-stdin push fast path is gone -- mutation proof: dev/mutants/hook-tests.json (448-pg-fastpath-crlf)"
  # --- hooks/push-guard.sh: analysis deadline (#435) cases ----------------------------------------
  "push-dl-deny-budget-zero|case_push_dl_deny_budget_zero|knob 0 denies the very first sample even for an ordinary feature/x push -- mutation proof: dev/mutants/hook-tests.json (435-dl-check-off)"
  "push-dl-noop-budget-zero-no-push|case_push_dl_noop_budget_zero_no_push|no push segment stays no-opinion even at knob 0, via the pre-deadline scan_out exit -- mutation proof: dev/mutants/hook-tests.json (435-dl-scan-empty-exit)"
  "push-dl-noop-budget-zero-xseg-no-push|case_push_dl_noop_budget_zero_xseg_no_push|a cd with no push segment (only #433's marker line in the scan) stays no-opinion even at knob 0 -- mutation proof: dev/mutants/hook-tests.json (435-dl-scan-empty-exit, 435-dl-xseg-early-exit)"
  "push-dl-deny-production-budget|case_push_dl_deny_production_budget|FLOOD+TIMING route 1: 10000x harmless push segments, knob 99 ignored (not less than the 5s production budget) -- deny under an active deadline calibrated from a same-run knob-0 control (#463, #476) -- mutation proof: dev/mutants/hook-tests.json (435-dl-check-off, 435-dl-knob-raise)"
  "push-dl-deny-driver-site|case_push_dl_deny_driver_site|FLOOD route 3: 3000x bare -C push (zero evaluate_segment loop iterations, no lane config), once the driver loop starts only its own sample can stop it; budget calibrated from a same-run knob-0 control (#476) -- mutation proof: dev/mutants/hook-tests.json (435-dl-check-off, 435-dl-driver-site)"
  "push-dl-deny-evaluate-sites|case_push_dl_deny_evaluate_sites|one push segment with a 10000-token refspec list -- only evaluate_segment()'s own internal samples can stop its refspec loop before it reaches the trailing main; budget calibrated from a same-run knob-0 control (#476) -- mutation proof: dev/mutants/hook-tests.json (435-dl-check-off, 435-dl-evaluate-sites)"
  "push-dl-deny-config-lines|case_push_dl_deny_config_lines|bare -C push resolving a lane with a many-line, under-cap depth-0 config -- only cfg_parse_file()'s read-loop sample can stop the parse mid-file; budget calibrated from a same-run knob-0 control (#476) -- mutation proof: dev/mutants/hook-tests.json (435-dl-check-off, 435-dl-cfgline-site)"
  "push-dl-deny-c-lane-flood|case_push_dl_deny_c_lane_flood|FLOOD route 3: 120x resolved -C lanes each including a 2000-line all-comment file -- mutation proof: dev/mutants/hook-tests.json (435-dl-check-off)"
  "push-dl-deny-toplevel-longline|case_push_dl_deny_toplevel_longline|TIMING route 2: a depth-0 line padded with 20000 trailing spaces denies instantly via the length cap; without it, no later line exists for the read-loop sample to catch, so the quadratic trim runs past a 9s active deadline (#463) -- mutation proof: dev/mutants/hook-tests.json (435-dl-toplevel-cap)"
  "push-dl-deny-toplevel-over-cap|case_push_dl_deny_toplevel_over_cap|a depth-0 line one character past the cap denies via the length check (checked before comment-strip), not the ordinary route its comment-stripped remainder would otherwise still reach -- mutation proof: dev/mutants/hook-tests.json (435-dl-toplevel-cap)"
  "push-dl-deny-toplevel-at-cap|case_push_dl_deny_toplevel_at_cap|a depth-0 line at EXACTLY the cap is still parsed normally, reaching the ordinary remote.origin.push route -- mutation proof: dev/mutants/hook-tests.json (435-dl-toplevel-cap-off-by-one)"
  # --- hooks/claude-dir-guard.sh (#327) cases -----------------------------------------------------
  # Mutation-proof table (LESSON 2026-09-01/2026-09-07(b), one mutant per classifier clause,
  # applied in place with an immediately-refreshed backup and a full `diff` verify after every
  # restore -- LESSON 2026-09-07), each measured against this section's own case set embedded in
  # the then-current whole file (a fresh mktemp copy of hooks/claude-dir-guard.sh, never `mv`-ed
  # over -- LESSON 2026-09-15b's exec-bit concern does not apply here, since run_claude_guard
  # always invokes the script through an explicit `bash <path>`, never by PATH lookup); M1-M13
  # were re-measured for the #327 round-1 kickback (LESSON 2026-09-15 -- reasoning by inspection
  # undercounted M10's own kill set). Pass/fail totals and kill-set enumerations are not recorded
  # here: both shift every time a fixture is added to this file (#407 added many), so a stale
  # figure or a stale enumeration would silently stop meaning anything (this repo's CLAUDE.md
  # convention) -- each entry instead states the code mutation and the shape of fixture it
  # affects; the row that cites each mutant ID (below) is the durable link.
  #   M1  role resolution forced to "implementer" regardless of match
  #       (role="" -> role="implementer", unconditionally)
  #       (an unrecognised or empty agent_type no longer exits "no opinion" early; every
  #       already-matching implementer/verifier fixture is unaffected, since role only ever
  #       changes the DENY MESSAGE text, never the policy itself)
  #   M2  fast path deleted (*agent_type*) widened to *) so it always matches
  #       NOT FLIPPED (a measured finding, not an oversight): every payload that reaches jq via
  #       the fast path already re-derives the identical "no opinion" from an empty/absent
  #       .agent_type extraction, exactly the redundancy hooks/agent-boundary.sh's own fast paths
  #       do NOT have (there, breaking a fast path is coarse and flips every deny fixture, since
  #       jq is never reached to re-derive the verdict another way)
  #   M3  the GUARDED_TOOLS membership check disabled (always matches)
  #       (a tool other than Edit/Write now also reaches the classifier)
  #   M4  the permission_mode == "plan" check disabled
  #       (a plan-mode call is no longer skipped)
  #   M5  the CR strip disabled (p="${raw//$cr/}" -> p="$raw", inside classify_path())
  #       (a CR-carrying spelling no longer widens toward .claude)
  #   M6  the backslash-to-slash separator normalisation disabled (p="${p//\\//}" -> p="$p")
  #       (a backslash-spelled .claude segment is no longer recognised)
  #   M7  the case-insensitive bracket classes narrowed to a bare lowercase literal
  #       (*/.[Cc][Ll][Aa][Uu][Dd][Ee]/* -> */.claude/*)
  #       (a case-varied spelling is no longer recognised)
  #   M8  the classifier's leading+trailing slash boundary wrap removed
  #       (case "/$p/" in -> case "$p" in)
  #       (a path whose own string has no PRE-EXISTING "/" immediately before ".claude" -- a
  #       final segment with nothing after it, or a relative path whose FIRST segment is
  #       ".claude" -- is no longer recognised; a path that already contains a naturally-occurring
  #       "/.claude/" substring is unaffected)
  #   M9  the segment match widened to a bare substring test
  #       (*/.[Cc][Ll][Aa][Uu][Dd][Ee]/* -> *[Cc][Ll][Aa][Uu][Dd][Ee]*)
  #       (a near-miss segment spelling that merely CONTAINS, rather than EQUALS, ".claude" now
  #       also denies)
  #  M10  the absoluteness check's deny arm disabled (the trailing "*)" case becomes a no-op)
  #       (a relative path with no ".claude" segment anywhere no longer denies via the
  #       unclassifiable message; re-measured for the round-1 kickback -- an embedded-LF path of
  #       the same shape is affected too, a widening reasoning-by-inspection alone would have
  #       missed)
  #  M11  the ".." segment check's deny arm disabled (the trailing "*)" case becomes a no-op)
  #       (an absolute ".."-carrying path with no ".claude" segment anywhere no longer denies via
  #       the unclassifiable message; a path that also carries a real ".claude" segment denies
  #       earlier, via that class, and never reaches this clause at all)
  #  M12  every "exit 2" in the classifier changed to "exit 0"
  #       (coarse -- like hooks/agent-boundary.sh's own M1/M2, this silences EVERY deny verdict at
  #       once, so it only distinguishes an intended-deny fixture from everything else, never one
  #       deny fixture from another)
  #  M13  the AGENT_TYPES_VERIFIER="..." line deleted entirely
  #       (the verifier-role fixtures no longer resolve a role at all; referencing
  #       $AGENT_TYPES_VERIFIER for ANY non-empty, IMPLEMENTER-non-matching agent_type -- not just
  #       a genuine "verifier" spelling -- trips this script's own `set -uo pipefail` "unbound
  #       variable" abort; an EMPTY agent_type is unaffected, since it never enters the
  #       `[ -n "$agent_type" ]` block that references the deleted variable at all)
  #  M14  the print-only LF-fold reverted (p_disp="${p//$lf/\\n}" -> p_disp="$p") (#327 round-1
  #       kickback K1)
  #       (the deny verdict itself is unaffected -- the classifier still matches $p, unchanged by
  #       this mutant -- but the printed message reverts to embedding the raw LF byte, so the
  #       "exactly 1 non-blank stderr line" assertion now sees 2)
  # A path with no ".claude"/".." segment and no unrecognised shape survives every mutant in this
  # table, since none of M1-M14 makes an ordinary path deny; a payload carrying no `agent_type`
  # substring at all never reaches past the fast path regardless of which downstream check M1-M14
  # breaks; an unparseable stdin's failure mode is jq's own parse error, independent of which check
  # runs afterward; and an absent file_path exits before the classifier itself ever runs, on every
  # mutant in this table (none of M1-M14 touches the `[ -n "$file_path" ] || exit 0` gate). Each
  # such row's own comment states this instead of citing a mutant that was never observed to fail
  # it.
  "cdg-deny-impl-write-bare|case_cdg_deny_impl_write_bare|.claude deny: implementer (bare), Write, /repo/.claude/settings.json -- mutation proof: M12 (above)"
  "cdg-deny-impl-edit-ns|case_cdg_deny_impl_edit_ns|.claude deny: trail-blazer-flow:implementer (namespaced), Edit, /repo/.claude/foo.md -- mutation proof: M12 (above)"
  "cdg-deny-verif-write-ns|case_cdg_deny_verif_write_ns|.claude deny: trail-blazer-flow:verifier (namespaced), Write, /repo/.claude/bar.json -- mutation proof: M13 (also M12; above)"
  "cdg-deny-verif-edit-bare|case_cdg_deny_verif_edit_bare|.claude deny: verifier (bare), Edit, /repo/.claude/baz.md -- mutation proof: M13 (also M12; above)"
  "cdg-deny-nested|case_cdg_deny_nested|.claude deny: a nested segment, /Users/x/proj/.claude/settings.json -- mutation proof: M12 (above)"
  "cdg-deny-user-level|case_cdg_deny_user_level|.claude deny: a path entirely outside any repo checkout, /Users/x/.claude/settings.json (pins deliberate location-independence -- the file_path route reads no cwd/repo-root at all) -- mutation proof: M12 (above)"
  "cdg-deny-case-variant|case_cdg_deny_case_variant|.claude deny: case-varied spelling, /repo/.Claude/x -- mutation proof: M7 (also M12; above)"
  "cdg-deny-drive-letter|case_cdg_deny_drive_letter|.claude deny: Windows drive-letter absolute form, C:/Users/x/.claude/foo -- mutation proof: M12 (above)"
  "cdg-deny-backslash|case_cdg_deny_backslash|.claude deny: backslash-spelled form, C:\Users\x\.claude\foo (separator normalisation) -- mutation proof: M6 (also M12; above)"
  "cdg-deny-final-segment|case_cdg_deny_final_segment|.claude deny: .claude as the path's FINAL segment, /repo/foo/.claude -- mutation proof: M8 (also M12; above)"
  "cdg-deny-crlf|case_cdg_deny_crlf|.claude deny: a CR embedded inside the spelling itself, /repo/.clau<CR>de/foo (the strip can only widen toward deny) -- mutation proof: M5 (also M12; above)"
  "cdg-deny-rel-claude|case_cdg_deny_rel_claude|.claude deny: a RELATIVE path whose first segment is .claude, .claude/LESSONS.md (discriminated from cdg-deny-rel-plain below) -- mutation proof: M8 (also M12; above)"
  "cdg-deny-dotdot-claude|case_cdg_deny_dotdot_claude|.claude deny: a \"..\"-carrying ABSOLUTE path that also carries a real .claude segment, /Users/x/../.claude/y (the more specific message wins) -- mutation proof: M12 (above)"
  "cdg-deny-lf-claude|case_cdg_deny_lf_claude|.claude deny: an embedded LF elsewhere in the path, /repo/.claude/a<LF>b.md (#327 round-1 kickback K1 -- pre-fix this printed 2 stderr lines) -- mutation proof: M14 (also M12; above)"
  "cdg-deny-rel-plain|case_cdg_deny_rel_plain|unclassifiable deny: the SAME relative, no-leading-slash shape as cdg-deny-rel-claude, but no .claude segment anywhere, src/main.rs (discriminates the two deny classes) -- mutation proof: M10 (also M12; above)"
  "cdg-deny-dotdot-no-claude|case_cdg_deny_dotdot_no_claude|unclassifiable deny: a \"..\"-carrying ABSOLUTE path with no .claude segment anywhere, /Users/x/../etc/passwd -- mutation proof: M11 (also M12; above)"
  "cdg-deny-lf-unclassifiable|case_cdg_deny_lf_unclassifiable|unclassifiable deny: an embedded LF in a relative, no-.claude path, src/a<LF>b.rs (#327 round-1 kickback K1's own second example -- pre-fix this printed 2 stderr lines) -- mutation proof: M10 (a kill-set widening found only by re-measuring, not by inspection; also M14, also M12; above)"
  "cdg-noop-ordinary-abs|case_cdg_noop_ordinary_abs|no opinion: an ordinary absolute path with no .claude segment, /repo/src/main.rs -- not flipped by M1-M14 (an ordinary absolute path never denies under any of these mutants)"
  "cdg-noop-claude-backup|case_cdg_noop_claude_backup|no opinion: near-miss segment spelling, /repo/.claude-backup/x (pins exact-segment matching) -- mutation proof: M9 (above)"
  "cdg-noop-my-claude|case_cdg_noop_my_claude|no opinion: near-miss segment spelling, /repo/my.claude/x (pins exact-segment matching) -- mutation proof: M9 (above)"
  "cdg-noop-main-session-lessons|case_cdg_noop_main_session_lessons|no opinion: main session (no agent_type key), Write, /repo/.claude/LESSONS.md (release-blocker control -- the orchestrator's own lesson append) -- not flipped by M1-M14 (no agent_type key anywhere in the raw stdin -- the fast path alone already excludes it)"
  "cdg-noop-unrecognised-agent|case_cdg_noop_unrecognised_agent|no opinion: agent_type is \"Explore\" (unrecognised role) -- mutation proof: M1 (also M13; above)"
  "cdg-noop-empty-agent|case_cdg_noop_empty_agent|no opinion: agent_type is the empty string -- mutation proof: M1 (above)"
  "cdg-noop-plan-mode|case_cdg_noop_plan_mode|no opinion: implementer Edit of /repo/.claude/x under permission_mode: \"plan\" -- mutation proof: M4 (above)"
  "cdg-noop-wrong-tool|case_cdg_noop_wrong_tool|no opinion: tool_name is \"Read\", not Edit/Write -- mutation proof: M3 (above)"
  "cdg-noop-malformed-json|case_cdg_noop_malformed_json|no opinion: unparseable stdin (carries both agent_type and .claude substrings) -- not flipped by M1-M14 (jq's own parse failure independently yields an empty extraction regardless of which downstream check runs)"
  "cdg-noop-missing-file-path|case_cdg_noop_missing_file_path|no opinion: tool_input.file_path absent -- not flipped by M1-M14 (an empty file_path exits before the classifier itself ever runs, on every mutant in this table)"
  "cdg-noop-verifier-mutation-probe|case_cdg_noop_verifier_mutation_probe|no opinion: verifier Edit of a tracked source file, /repo/bin/find-planning-work.sh (release-blocker control -- the mutation probe) -- mutation proof: M13 (above)"
  "cdg-never-executes-deny|case_cdg_never_executes_deny|deny, AND claude-dir-guard.sh never invokes git/gh/rm/dirname/tr/awk/grep/sed on the booby-trapped PATH — sentinel absent -- mutation proof: M12 (above)"
  "cdg-never-executes-noop|case_cdg_never_executes_noop|no opinion, AND claude-dir-guard.sh never invokes git/gh/rm/dirname/tr/awk/grep/sed on the booby-trapped PATH — sentinel absent -- not flipped by M1-M14 (the identical \"ordinary absolute path\" shape as cdg-noop-ordinary-abs, plus a booby-trapped PATH none of these mutants ever reads)"
  "cdg-writes-nothing|case_cdg_writes_nothing|deny, AND a fixture tree containing .claude/LESSONS.md has a byte-identical recursive file listing before/after — this hook performs no filesystem access at all -- mutation proof: M12 (above)"
  # --- hooks/planner-guard.sh (#407) cases --------------------------------------------------------
  "plg-deny-edit-ns|case_plg_deny_edit_ns|deny: Claude-shaped trail-blazer-flow:planner, Edit"
  "plg-deny-write-bare|case_plg_deny_write_bare|deny: bare planner, Write"
  "plg-deny-apply-patch|case_plg_deny_apply_patch|deny: Codex apply_patch, planner (the ADR's Add File: allowed.txt patch) -- the planner is read-only regardless of tool"
  "plg-deny-touch|case_plg_deny_touch|deny: touch ro_test.txt && echo touched"
  "plg-deny-gh|case_plg_deny_gh|deny: gh issue list"
  "plg-deny-git-commit|case_plg_deny_git_commit|deny: git commit -am x"
  "plg-deny-git-restore|case_plg_deny_git_restore|deny: git restore x (restore writes the working tree, deliberately excluded from PLANNER_GIT_READONLY)"
  "plg-deny-git-global-opt|case_plg_deny_git_global_opt|deny: git -c core.pager=sh log (a global option in subcommand position)"
  "plg-deny-git-diff-output|case_plg_deny_git_diff_output|deny: git diff --output=/tmp/x"
  "plg-deny-git-ext-diff|case_plg_deny_git_ext_diff|deny (#407 kickback finding 4): git diff --ext-diff"
  "plg-deny-git-grep|case_plg_deny_git_grep|deny (#407 kickback finding 1): git grep -lOrm . (a bundled short-option cluster real git accepts, steering -O's arbitrary pager program)"
  "plg-deny-git-grep-abbrev|case_plg_deny_git_grep_abbrev|deny (#407 kickback finding 1): git grep --open=rm -l . (real git accepts abbreviated long options)"
  "plg-deny-rg-hostname-bin|case_plg_deny_rg_hostname_bin|deny (#407 kickback finding 1): rg --hostname-bin=x foo (runs an arbitrary program to resolve the hostname)"
  "plg-deny-redirect|case_plg_deny_redirect|deny: cat a > b (lexer rejection)"
  "plg-deny-stderr-devnull|case_plg_deny_stderr_devnull|deny: ls 2>/dev/null (no carve-out, per the approved plan)"
  "plg-deny-dollar-paren|case_plg_deny_dollar_paren|deny: cat \$(ls) (lexer rejection)"
  "plg-deny-backtick|case_plg_deny_backtick|deny: cat \`ls\` (lexer rejection)"
  "plg-deny-dquote-subst|case_plg_deny_dquote_subst|deny: rg \"\$(id)\" . (double-quoted \$ rejected)"
  "plg-deny-process-subst|case_plg_deny_process_subst|deny: diff <(ls) b (lexer rejection)"
  "plg-deny-subshell|case_plg_deny_subshell|deny: (ls) (lexer rejection)"
  "plg-deny-background|case_plg_deny_background|deny: ls & (a lone & rejects)"
  "plg-deny-chain-rm|case_plg_deny_chain_rm|deny: ls && rm -rf x (second segment's command word not allowlisted)"
  "plg-deny-pipe-tee|case_plg_deny_pipe_tee|deny: cat a | tee b (a single pipe is a segment break; tee is not allowlisted)"
  "plg-deny-assignment|case_plg_deny_assignment|deny: PAGER=sh git log (the assignment token itself is the segment's t0, not allowlisted)"
  "plg-deny-abs-path|case_plg_deny_abs_path|deny: /bin/cat x (an absolute command word is not an exact PLANNER_READONLY_COMMANDS member)"
  "plg-deny-bash-c|case_plg_deny_bash_c|deny: bash -c ls (no PREFIX_WORDS skip in this hook at all)"
  "plg-deny-multiline|case_plg_deny_multiline|deny: ls<LF>rm x (NR>1 in the lexer)"
  "plg-deny-backslash|case_plg_deny_backslash|deny (#407 kickback finding 6): cat \\'; rm -rf x; \\' (lexer rejection)"
  "plg-deny-brace|case_plg_deny_brace|deny (#407 kickback finding 6): { ls; } (lexer rejection)"
  "plg-deny-bang|case_plg_deny_bang|deny (#407 kickback finding 6): ! ls (lexer rejection)"
  "plg-deny-unterminated|case_plg_deny_unterminated|deny: rg 'foo (unterminated quote)"
  "plg-deny-sed-inplace|case_plg_deny_sed_inplace|deny: sed -i.bak s/a/b/ f (t1 != -n)"
  "plg-deny-sed-w|case_plg_deny_sed_w|deny: sed -n 'w /tmp/x' f (t2 does not match the read-only range shape)"
  "plg-deny-sed-trailing-opt|case_plg_deny_sed_trailing_opt|deny (#407 kickback finding 5): sed -n 1p f -i (a trailing option after the range)"
  "plg-deny-sed-range-suffix|case_plg_deny_sed_range_suffix|deny (#407 kickback finding 5): sed -n '1p;w /tmp/x' f (t2 carries a trailing w command, not just the range)"
  "plg-deny-rg-pre|case_plg_deny_rg_pre|deny: rg --pre=sh foo"
  "plg-deny-find|case_plg_deny_find|deny: find . -delete (find excluded, per the approved plan's Open questions)"
  "plg-deny-empty-command|case_plg_deny_empty_command|deny: tool_input: {} (absent command denies fail-closed, unlike every sibling hook)"
  "plg-deny-plan-mode|case_plg_deny_plan_mode|deny: touch x under permission_mode: \"plan\" -- deliberately NO plan-mode skip in this hook"
  "plg-deny-apply-patch-heredoc|case_plg_deny_apply_patch_heredoc|deny (#407 amendment A3): a planner shell apply_patch heredoc denies via the multi-line/NR>1 lexer rejection, independent of claude-dir-guard.sh's own Bash route"
  "plg-noop-rg|case_plg_noop_rg|no opinion: rg -n \"foo\" src"
  "plg-noop-sed-print|case_plg_noop_sed_print|no opinion: sed -n '1,120p' README.md"
  "plg-noop-pipe|case_plg_noop_pipe|no opinion: git log --oneline -5 | head -3"
  "plg-noop-chain|case_plg_noop_chain|no opinion: ls docs && cat README.md; wc -l CLAUDE.md"
  "plg-noop-git-show-ns|case_plg_noop_git_show_ns|no opinion: Claude-shaped trail-blazer-flow:planner, git show HEAD"
  "plg-noop-quoted-meta|case_plg_noop_quoted_meta|no opinion: rg 'a|b>c\$(x)' docs (every metacharacter is inside single quotes)"
  "plg-noop-glob|case_plg_noop_glob|no opinion: ls docs/*.md (glob characters are ordinary tokens now, not rejected)"
  "plg-noop-main-session|case_plg_noop_main_session|no opinion: Codex main session (no agent_type), touch x"
  "plg-noop-implementer|case_plg_noop_implementer|no opinion: implementer role, touch x (not this hook's role)"
  "plg-noop-explore-edit|case_plg_noop_explore_edit|no opinion: agent_type Explore, Edit"
  "plg-noop-read-tool|case_plg_noop_read_tool|no opinion: planner role, Read tool (outside PLANNER_EDIT_TOOLS and not Bash)"
  "plg-noop-malformed-json|case_plg_noop_malformed_json|no opinion: unparseable stdin (carries both agent_type and planner substrings)"
  "plg-never-executes-deny|case_plg_never_executes_deny|deny, AND planner-guard.sh never invokes git/gh/rm/touch on the booby-trapped PATH — sentinel absent"
  "plg-never-executes-noop|case_plg_never_executes_noop|no opinion, AND planner-guard.sh never invokes git/gh/rm/touch on the booby-trapped PATH — sentinel absent"
  # --- hooks/claude-dir-guard.sh apply_patch route (#407) cases -----------------------------------
  "cdg-patch-deny-add-claude|case_cdg_patch_deny_add_claude|.claude deny: implementer (bare), Add File: .claude/settings.local.json (the S0/P5 escape itself)"
  "cdg-patch-deny-update-ns|case_cdg_patch_deny_update_ns|.claude deny: trail-blazer-flow:implementer (namespaced), Update File: .claude/LESSONS.md"
  "cdg-patch-deny-verifier|case_cdg_patch_deny_verifier|.claude deny: verifier (bare), Add File: .claude/x"
  "cdg-patch-deny-delete|case_cdg_patch_deny_delete|.claude deny: Delete File: .claude/x"
  "cdg-patch-deny-move-to|case_cdg_patch_deny_move_to|.claude deny: Update File: src/a.txt then Move to: .claude/a.txt"
  "cdg-patch-deny-second-file|case_cdg_patch_deny_second_file|.claude deny: a benign first header then a .claude second header -- every header is checked, not only the first"
  "cdg-patch-deny-case-variant|case_cdg_patch_deny_case_variant|.claude deny: case-varied spelling, Add File: .Claude/x"
  "cdg-patch-deny-abs-header|case_cdg_patch_deny_abs_header|.claude deny: an absolute header path, Add File: /Users/x/.claude/settings.json"
  "cdg-patch-deny-indented-header|case_cdg_patch_deny_indented_header|.claude deny: an indented header line, '  *** Add File: .claude/x' (left-trim tolerance)"
  "cdg-patch-deny-codex|case_cdg_patch_deny_codex|.codex deny: Add File: .codex/config.toml"
  "cdg-patch-deny-codex-case|case_cdg_patch_deny_codex_case|.codex deny: case-varied spelling, Add File: .CODEX/agents/x.toml"
  "cdg-patch-deny-dotdot|case_cdg_patch_deny_dotdot|unclassifiable deny: Add File: ../escape/x"
  "cdg-patch-deny-no-cwd|case_cdg_patch_deny_no_cwd|unclassifiable deny: Add File: src/a.txt with no cwd field at all -- a relative header path with nothing to resolve against"
  "cdg-patch-deny-no-header|case_cdg_patch_deny_no_header|unparseable deny: a patch with Begin/End Patch but zero file headers"
  "cdg-patch-deny-unknown-header|case_cdg_patch_deny_unknown_header|unparseable deny: an unrecognised marker, *** Copy File: .claude/x"
  "cdg-patch-deny-empty-path|case_cdg_patch_deny_empty_path|unparseable deny: Add File: with nothing after the marker (an empty header path)"
  "cdg-patch-deny-empty-command|case_cdg_patch_deny_empty_command|unparseable deny: tool_input.command absent"
  "cdg-patch-noop-add-src|case_cdg_patch_noop_add_src|no opinion: implementer, Add File: src/new.rs (release-blocker control)"
  "cdg-patch-noop-update-readme|case_cdg_patch_noop_update_readme|no opinion: verifier, the benign Update File: README.md form"
  "cdg-patch-noop-content-mentions|case_cdg_patch_noop_content_mentions|no opinion: content lines merely MENTIONING .claude/LESSONS.md and *** Add File: .claude/x, under a benign Update File: README.md header"
  "cdg-patch-noop-crlf|case_cdg_patch_noop_crlf|no opinion: the benign Update File: README.md form with CRLF line endings throughout"
  "cdg-patch-noop-main-session|case_cdg_patch_noop_main_session|no opinion: main session (no agent_type), Add File: .claude/LESSONS.md"
  "cdg-patch-noop-planner|case_cdg_patch_noop_planner|no opinion: planner role, Add File: .claude/x (planner is not this hook's role -- planner-guard.sh's own read-only policy covers it instead)"
  "cdg-patch-noop-near-miss|case_cdg_patch_noop_near_miss|no opinion: near-miss segment spelling, Add File: .codex-backup/x"
  "cdg-patch-never-executes|case_cdg_patch_never_executes|deny, AND the apply_patch route never invokes git/gh/rm/dirname/tr/awk/grep/sed on the booby-trapped PATH — sentinel absent"
  # --- hooks/claude-dir-guard.sh file_path route, .codex segment (#407) cases ---------------------
  "cdg-codexseg-deny-write|case_cdg_codexseg_deny_write|.codex deny: implementer (bare), Write, /repo/.codex/config.toml"
  "cdg-codexseg-deny-verifier-edit-ns|case_cdg_codexseg_deny_verifier_edit_ns|.codex deny: trail-blazer-flow:verifier (namespaced), Edit, /repo/.codex/x"
  "cdg-codexseg-noop-backup|case_cdg_codexseg_noop_backup|no opinion: near-miss segment spelling, /repo/.codex-backup/x"
  "cdg-codexseg-noop-my-codex|case_cdg_codexseg_noop_my_codex|no opinion: near-miss segment spelling, /repo/my.codex/x"
  # --- hooks/claude-dir-guard.sh Bash apply_patch-shim route (#407 amendment A1/A3) cases ----------
  "cdg-bash-deny-heredoc-claude|case_cdg_bash_deny_heredoc_claude|.claude deny: the S0/#412 Q7 payload -- an implementer shell-issued apply_patch heredoc adding .claude/settings.local.json, replayed as tool_name: \"Bash\""
  "cdg-bash-deny-heredoc-codex|case_cdg_bash_deny_heredoc_codex|.codex deny: a verifier shell-issued apply_patch heredoc adding .codex/x"
  "cdg-bash-noop-heredoc-src|case_cdg_bash_noop_heredoc_src|no opinion: an implementer shell-issued apply_patch heredoc adding src/a.txt (resolved against cwd, no .claude/.codex segment)"
  "cdg-bash-deny-no-inline-patch|case_cdg_bash_deny_no_inline_patch|unparseable deny: apply_patch < x.patch -- the shim is the command word but no inline patch text is visible to this hook"
  "cdg-bash-deny-no-inline-patch-glued|case_cdg_bash_deny_no_inline_patch_glued|unparseable deny (#407 kickback finding 2): apply_patch<x.patch -- no space before the redirect"
  "cdg-bash-deny-no-inline-patch-brace|case_cdg_bash_deny_no_inline_patch_brace|unparseable deny (#407 kickback finding 2): { apply_patch < x.patch; } -- a brace group"
  "cdg-bash-deny-no-inline-patch-keyword|case_cdg_bash_deny_no_inline_patch_keyword|unparseable deny (#407 kickback finding 2): if true; then apply_patch < x.patch; fi -- past a shell keyword"
  "cdg-bash-deny-no-inline-patch-assignment|case_cdg_bash_deny_no_inline_patch_assignment|unparseable deny (#407 kickback finding 2): FOO=1 apply_patch < x.patch -- past an assignment prefix"
  "cdg-bash-deny-no-inline-patch-chain|case_cdg_bash_deny_no_inline_patch_chain|unparseable deny (#407 kickback finding 2/7): cd src && applypatch < x.patch -- a && chain, the no-underscore spelling"
  "cdg-bash-deny-no-inline-patch-pipe|case_cdg_bash_deny_no_inline_patch_pipe|unparseable deny (#407 kickback finding 2/7): cat x.patch | apply_patch -- a pipe"
  "cdg-bash-deny-decoy-dollar-quote|case_cdg_bash_deny_decoy_dollar_quote|unparseable deny (#407 kickback finding 2, belt and braces): an ANSI-C-quoted (\$'...') decoy whose \\n sequences are literal backslash+n bytes, not real newlines -- the raw-text .claude mention still denies"
  "cdg-bash-deny-decoy-nbsp-header|case_cdg_bash_deny_decoy_nbsp_header|unparseable deny (#407 kickback round 2, finding A): a U+00A0-indented .claude header next to a genuinely benign one -- the belt-and-braces check catches it even though the structured parse alone would have missed it"
  "cdg-bash-deny-no-inline-patch-subshell|case_cdg_bash_deny_no_inline_patch_subshell|unparseable deny (#407 kickback round 2, finding B): (apply_patch < x.patch) -- a subshell"
  "cdg-bash-deny-no-inline-patch-cmdsubst|case_cdg_bash_deny_no_inline_patch_cmdsubst|unparseable deny (#407 kickback round 2, finding B): echo \$(apply_patch < x.patch) -- a command substitution"
  "cdg-bash-deny-no-inline-patch-gt|case_cdg_bash_deny_no_inline_patch_gt|unparseable deny (#407 kickback round 2, finding C): apply_patch>out.txt -- the \">\" word break"
  "cdg-bash-deny-backslash-indented-begin-patch|case_cdg_bash_deny_backslash_indented_begin_patch|.claude deny (#407 kickback round 2, finding C): \\apply_patch heredoc with an INDENTED exact Begin Patch/Add File line -- has_exact_begin_patch_line's own full trim is what denies here, not command-word detection (the leading backslash defeats that)"
  "cdg-bash-deny-leading-redirect|case_cdg_bash_deny_leading_redirect|unparseable deny (#407 kickback round 2, finding D): < x.patch apply_patch -- a leading redirect must not hide the command word that follows it"
  "cdg-bash-deny-leading-redirect-fd|case_cdg_bash_deny_leading_redirect_fd|unparseable deny (#407 kickback round 2, finding D): 2>/dev/null apply_patch < x -- a bare-digits fd immediately before a redirect operator"
  "cdg-bash-deny-leading-redirect-append|case_cdg_bash_deny_leading_redirect_append|unparseable deny (#407 kickback round 3): >> log apply_patch < x.patch -- a >> run is one redirect"
  "cdg-bash-deny-leading-redirect-fd-append|case_cdg_bash_deny_leading_redirect_fd_append|unparseable deny (#407 kickback round 3): 2>>err apply_patch < x"
  "cdg-bash-deny-leading-redirect-fd-dup|case_cdg_bash_deny_leading_redirect_fd_dup|unparseable deny (#407 kickback round 3): >&2 apply_patch < x.patch -- an fd duplication keeps its &"
  "cdg-bash-deny-leading-redirect-fd-dup2|case_cdg_bash_deny_leading_redirect_fd_dup2|unparseable deny (#407 kickback round 3): 2>&1 apply_patch < x.patch"
  "cdg-bash-deny-leading-redirect-clobber|case_cdg_bash_deny_leading_redirect_clobber|unparseable deny (#407 kickback round 4): >| log apply_patch < x.patch -- >| is one redirect"
  "cdg-bash-deny-leading-redirect-in-dup|case_cdg_bash_deny_leading_redirect_in_dup|unparseable deny (#407 kickback round 4): <&0 apply_patch -- an input fd duplication keeps its &"
  "cdg-bash-noop-quoted-mention|case_cdg_bash_noop_quoted_mention|no opinion (#407 kickback round 4): git commit -m \"the apply_patch shim\" -- a quoted mention after ordinary words"
  "cdg-bash-noop-heredoc-claude-md|case_cdg_bash_noop_heredoc_claude_md|no opinion (#407 kickback round 3): a heredoc patch updating CLAUDE.md with Claude Code in its body"
  "cdg-bash-noop-heredoc-codex-name|case_cdg_bash_noop_heredoc_codex_name|no opinion (#407 kickback round 3): a heredoc patch adding src/codex_client.py"
  "cdg-bash-deny-path-qualified|case_cdg_bash_deny_path_qualified|unparseable deny (#407 kickback round 2, finding E): ./apply_patch < x -- matched by basename"
  "cdg-bash-noop-begin-patch-mention-grep|case_cdg_bash_noop_begin_patch_mention_grep|no opinion (#407 kickback finding 3): grep -rn '*** Begin Patch' hooks/ -- mentions the marker but carries no genuine patch-grammar line"
  "cdg-bash-noop-begin-patch-mention-commit|case_cdg_bash_noop_begin_patch_mention_commit|no opinion (#407 kickback finding 3): a commit message mentioning the marker"
  "cdg-bash-noop-arg-only|case_cdg_bash_noop_arg_only|no opinion: rg apply_patch hooks/ -- \"apply_patch\" is an argument, not the command word"
  "cdg-bash-noop-quoted|case_cdg_bash_noop_quoted|no opinion: grep -n \"apply_patch\" x -- \"apply_patch\" appears only inside quoted text"
  "cdg-bash-noop-main-session|case_cdg_bash_noop_main_session|no opinion: main session (no agent_type), the identical apply_patch heredoc adding .claude/x"
  "cdg-bash-noop-ab-fixture-reuse|case_cdg_bash_noop_ab_fixture_reuse|no opinion: an existing hooks/agent-boundary.sh deny fixture's own command (git push origin main) replayed against THIS hook -- the new Bash route must not deny a command that carries no apply_patch-shaped patch"
  "cdg-bash-never-executes|case_cdg_bash_never_executes|deny, AND the Bash route never invokes git/gh/rm/dirname/tr/awk/grep/sed on the booby-trapped PATH — sentinel absent"
  "cdg-bash-never-executes-no-inline-patch|case_cdg_bash_never_executes_no_inline_patch|deny via the is_apply_patch_word \"no inline patch\" route specifically, AND it never invokes git/gh/rm/dirname/tr/awk/grep/sed on the booby-trapped PATH — sentinel absent"
  "cdg-pc-deny-eval-shim|case_cdg_pc_deny_eval_shim|eval deny: implementer, eval apply_patch < x.patch -- mutation proof: dev/mutants/hook-tests.json (403-cdg-pc-vocab)"
  "cdg-pc-deny-noglob-shim|case_cdg_pc_deny_noglob_shim|zsh precommand modifier deny: implementer, noglob apply_patch < x.patch -- mutation proof: dev/mutants/hook-tests.json (403-cdg-pc-vocab)"
  "cdg-pc-deny-dash-shim|case_cdg_pc_deny_dash_shim|zsh precommand modifier deny: implementer, - apply_patch < x.patch -- mutation proof: dev/mutants/hook-tests.json (403-cdg-pc-vocab)"
  "cdg-pc-deny-repeat-shim|case_cdg_pc_deny_repeat_shim|zsh repeat deny: implementer, repeat 2 apply_patch < x.patch -- mutation proof: dev/mutants/hook-tests.json (403-cdg-pc-vocab, 403-cdg-pc-repeat)"
  "cdg-dbq-deny-short-if|case_cdg_dbq_deny_short_if|unparseable deny (#437): if [[ -n x ]] apply_patch < x.patch -- zsh's short-if form, resolved via the last (uncut) ]]-tail -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-tails, 437-cdg-dbq-last-tail)"
  "cdg-dbq-deny-short-if-multiline|case_cdg_dbq_deny_short_if_multiline|unparseable deny (#437): the closing ]] opens the SECOND physical line, a different segment from its own [[ -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-tails, 437-cdg-dbq-last-tail)"
  "cdg-dbq-deny-cut-shim|case_cdg_dbq_deny_cut_shim|unparseable deny (#437): if [[ -n x ]] apply_patch < x.patch ]] y -- the deciding tail is CUT and is not the last one -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-cut-shim)"
  "cdg-dbq-deny-cut-unresolved|case_cdg_dbq_deny_cut_unresolved|unparseable deny (#437): if [[ -n x ]] env -u ]] -i apply_patch < x.patch -- a cut tail that consumes skip tokens without ever resolving a word -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-cut, 437-cdg-dbq-overlap)"
  "cdg-dbq-deny-flood-cap|case_cdg_dbq_deny_flood_cap|unparseable deny (#437): more than DBRACKET_MAX (64) standalone ]] in one segment denies unconditionally -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-tails, 437-cdg-dbq-cap)"
  "cdg-dbq-deny-eval-sq|case_cdg_dbq_deny_eval_sq|unparseable deny (#437): eval 'apply_patch < x.patch' -- a single-quoted eval argument -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-quote-sq)"
  "cdg-dbq-deny-eval-dq|case_cdg_dbq_deny_eval_dq|unparseable deny (#437): eval \"apply_patch < x.patch\" -- a double-quoted eval argument -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-quote-dq)"
  "cdg-dbq-deny-eval-lead-space|case_cdg_dbq_deny_eval_lead_space|unparseable deny (#437): eval \" apply_patch < x.patch\" -- a lone quote token stripped to empty must be skipped, not resolved -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-quote-dq, 437-cdg-dbq-empty-tok)"
  "cdg-dbq-deny-trap-sq|case_cdg_dbq_deny_trap_sq|unparseable deny (#437): verifier, trap 'apply_patch < x.patch' EXIT -- a single-quoted trap argument -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-quote-sq)"
  "cdg-dbq-deny-bash-c-dq|case_cdg_dbq_deny_bash_c_dq|unparseable deny (#437): bash -c \"apply_patch < x.patch\" -- a double-quoted bash -c argument -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-quote-dq)"
  "cdg-dbq-deny-quoted-name|case_cdg_dbq_deny_quoted_name|unparseable deny (#437): \"apply_patch\" < x.patch -- a quoted shim spelling as the command word itself -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-quote-dq)"
  "cdg-dbq-deny-quoted-prefix|case_cdg_dbq_deny_quoted_prefix|unparseable deny (#437): bash -c 'noglob apply_patch < x.patch' -- the PREFIX_WORDS match itself uses the stripped token -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-quote-sq)"
  "cdg-dbq-deny-timing|case_cdg_dbq_deny_timing|flood shape (#437): a flood line just under the per-line size cap (x + 700x' a' filler, then 64x' ]] true', then a newline, then apply_patch < x.patch) -- deny under a 15s active deadline (#463) -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-cap-exact, 463-hook-cdg-override-leaks)"
  "cdg-dbq-noop-flood-at-cap|case_cdg_dbq_noop_flood_at_cap|no opinion (#437): exactly DBRACKET_MAX (64) standalone ]] -- the cap never trips -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-cap-exact)"
  "cdg-dbq-noop-cap-per-segment|case_cdg_dbq_noop_cap_per_segment|no opinion (#437): 65 heredoc lines, each with exactly one standalone ]] in its own segment -- DBRACKET_MAX resets per segment -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-cap-per-segment)"
  "cdg-dbq-noop-bash-dbracket|case_cdg_dbq_noop_bash_dbracket|no opinion (#437): [[ -n x ]] && echo apply_patch -- an ordinary && conditional, not the short-if form"
  "cdg-dbq-noop-cut-resolved|case_cdg_dbq_noop_cut_resolved|no opinion (#437): if [[ -n x ]] env echo apply_patch ]] y -- a cut tail that consumed a skip word but resolved one is not denied -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-cut-resolved)"
  "cdg-dbq-noop-short-if-other|case_cdg_dbq_noop_short_if_other|no opinion (#437): if [[ -n x ]] echo apply_patch -- the tail resolves to echo, apply_patch is only its argument"
  "cdg-dbq-noop-short-if-benign-heredoc|case_cdg_dbq_noop_short_if_benign_heredoc|no opinion (#437): if [[ -n x ]] apply_patch <<'EOF' carrying a benign src/a.txt patch -- the existing structured-parse route is unaffected by the additive ]] pass"
  "cdg-dbq-never-executes|case_cdg_dbq_never_executes|deny via the short-if ]]-tail route specifically, AND it never invokes git/gh/rm/dirname/tr/awk/grep/sed on the booby-trapped PATH — sentinel absent -- mutation proof: dev/mutants/hook-tests.json (437-cdg-dbq-tails, 437-cdg-dbq-last-tail)"
  "cdg-dl-deny-budget-zero|case_cdg_dl_deny_budget_zero|deny (#457): implementer Bash echo apply_patch under budget knob 0 -- the first sample denies with the exact too-large line, and the budget override is cleared after the call"
  "cdg-dl-deny-budget-zero-patch|case_cdg_dl_deny_budget_zero_patch|deny (#457): verifier apply_patch with a benign patch under budget knob 0 -- exact too-large line naming verifier and apply_patch"
  "cdg-dl-never-executes|case_cdg_dl_never_executes|deny (#457): the budget-zero deny never invokes git/gh/rm/dirname/tr/awk/grep/sed on the booby-trapped PATH -- sentinel absent"
  "cdg-dl-deny-line-400k|case_cdg_dl_deny_line_400k|deny (#457): apply_patch < x.patch followed on the same line by 400000 spaces -- over the per-line size cap, exact too-large line under a 15s active deadline, before any substitution runs"
  "cdg-dl-deny-line-just-over-cap|case_cdg_dl_deny_line_just_over_cap|deny (#457): a benign one-line command exactly one character over the per-line size cap -- exact too-large line"
  "cdg-dl-noop-line-at-cap|case_cdg_dl_noop_line_at_cap|no opinion (#457): a benign one-line command of exactly the per-line size cap's length -- the cap is an upper bound, not a strict one"
  "cdg-dl-noop-line-over-cap-main-session|case_cdg_dl_noop_line_over_cap_main_session|no opinion (#457): an over-cap line with no agent_type -- fast path 1 excludes it before the cap (contract pin)"
  "cdg-dl-noop-line-over-cap-other-agent|case_cdg_dl_noop_line_over_cap_other_agent|no opinion (#457): an over-cap line from an Explore agent -- the role exit precedes the cap"
  "cdg-dl-noop-big-patch|case_cdg_dl_noop_big_patch|no opinion (#457): a heredoc patch over 100 ordinary lines adding a benign path -- not capped by total size, finishes inside a 15s active deadline"
  "cdg-dl-deny-big-patch-claude|case_cdg_dl_deny_big_patch_claude|deny (#457): the same 100-line heredoc patch adding a path under .claude -- still denied, finishes inside a 15s active deadline"
  "cdg-dl-deny-patch-cr-line|case_cdg_dl_deny_patch_cr_line|deny (#457): a native apply_patch with a 400000-CR content line -- over the per-line size cap on the patch route, exact too-large line under a 15s active deadline, before any CR strip runs"
  "cdg-dl-deny-path-cr|case_cdg_dl_deny_path_cr|deny (#457): an Edit with a 200000-CR file_path -- over the per-line cap in classify_path, exact too-large line under a 15s active deadline"
  "cdg-dl-deny-cwd-cr|case_cdg_dl_deny_cwd_cr|deny (#457): an apply_patch whose cwd is 200000 CRs -- over the per-line cap, exact too-large line under a 15s active deadline"
  "cdg-dl-deny-cwd-cr-bash|case_cdg_dl_deny_cwd_cr_bash|deny (#457): a Bash inline-patch call whose cwd is 200000 CRs -- over the per-line cap, exact too-large line under a 15s active deadline"
  "cdg-dl-deny-patch-cr-just-over-cap|case_cdg_dl_deny_patch_cr_just_over_cap|deny (#457): a native content line of a plus sign and per-line-cap CRs (one byte over the cap) -- over the line cap by its CR alone, exact too-large line"
  "cdg-dl-noop-patch-cr-many|case_cdg_dl_noop_patch_cr_many|no opinion (#457): a 250-line native apply_patch with a CR on every line adding a benign path -- CRs stripped per line, same verdict as before, inside a 15s active deadline"
  "cdg-dl-deny-production-budget|case_cdg_dl_deny_production_budget|wall-clock proof (#457): a native apply_patch with a 500000-space CR-free content line, budget knob 99 ignored -- ltrim's sampled loop denies, exact too-large line under a 15s active deadline"
  "cdg-dl-deny-patch-marker-line|case_cdg_dl_deny_patch_marker_line|deny (#457): a native patch whose first line is an unrecognised *** marker one byte over the line cap, padded with non-whitespace -- over the line cap through its *** marker alone, exact too-large line (uncapped, the parser denies at line 1 instead)"
  "cdg-dl-deny-cwd-just-over-cap|case_cdg_dl_deny_cwd_just_over_cap|deny (#457): a native apply_patch whose cwd is one character over the per-line cap -- exact too-large line"
  "cdg-dl-deny-cwd-just-over-cap-bash|case_cdg_dl_deny_cwd_just_over_cap_bash|deny (#457): a Bash inline-patch call whose cwd is one character over the per-line cap -- exact too-large line"
  "cdg-dl-deny-line-multibyte|case_cdg_dl_deny_line_multibyte|deny (#457): a Bash line of 600 four-byte characters (over the cap in bytes, under it in characters) -- the cap is measured in bytes"
  "cdg-dl-deny-path-multibyte|case_cdg_dl_deny_path_multibyte|deny (#457): an Edit path of 600 four-byte characters -- the path cap is measured in bytes"
  "cdg-dl-pin-bash-text-wide|case_cdg_dl_pin_bash_text_wide|deny (#457): a Bash command of 540 lines of four-byte characters (over the whole-text cap in bytes, under it in characters; each line under the line cap) -- exact too-large line under a 15s active deadline"
  "cdg-dl-deny-cwd-multibyte|case_cdg_dl_deny_cwd_multibyte|deny (#457): a native apply_patch whose cwd is 600 four-byte characters (over the cap in bytes, under it in characters) -- the cwd cap is measured in bytes"
  "cdg-dl-deny-cwd-multibyte-bash|case_cdg_dl_deny_cwd_multibyte_bash|deny (#457): a Bash inline-patch call whose cwd is 600 four-byte characters -- the cwd cap is measured in bytes"
  "cdg-dl-deny-text-multibyte|case_cdg_dl_deny_text_multibyte|deny (#457): a native patch whose first line is an unrecognised marker, then two content lines of 150000 four-byte characters (over the whole-text cap in bytes, under it in characters) -- exact too-large line under a 15s active deadline"
  "cdg-dl-noop-native-long-line|case_cdg_dl_noop_native_long_line|no opinion (#457): a native apply_patch with a 3700-character CR-free content line adding a benign path -- an ordinary long line is not capped on the native route"
  "cdg-dl-deny-text-over-cap|case_cdg_dl_deny_text_over_cap|deny (#457): a native apply_patch whose whole text (an unrecognised-marker first line, then one long content line) is one character over the whole-text cap -- exact too-large line before any split, under a 15s active deadline"
  "cdgtextcap-deny-parse-at-cap|case_cdgtextcap_deny_parse_at_cap|deny (#457, #512): a native apply_patch of exactly the whole-text cap whose first line is an unrecognised marker -- the parser's unrecognised-marker line, never the too-large line, so the cap is an upper bound; the parser stops at line 1, so no full analysis is needed; C locale -- mutation proof: dev/mutants/hook-tests.json (457-cdg-dl-text-cap-offbyone)"
  "cdg-dl-deny-bash-cr-word|case_cdg_dl_deny_bash_cr_word|deny (#457): apply_patch followed by a CR as the command word -- only the Bash route's CR strip lets the walk see the shim, so the no-inline-patch deny fires"
  "cdg-dl-noop-path-at-cap|case_cdg_dl_noop_path_at_cap|no opinion (#457): an Edit of a benign path of exactly the per-line cap's length -- the path cap is an upper bound, not a strict one"
  "cdg-dl-deny-path-just-over-cap|case_cdg_dl_deny_path_just_over_cap|deny (#457): an Edit of a benign path one character over the per-line cap -- exact too-large line"
  "cdg-dl-noop-budget-zero-edit|case_cdg_dl_noop_budget_zero_edit|no opinion (#457): implementer Edit of a benign path under budget 0 and cap 1 -- the Edit/Write route has no sampled loop"
  "cdg-dl-noop-main-session|case_cdg_dl_noop_main_session|no opinion (#457): main session under budget 0 and cap 1 -- fast path 1 excludes it before any sample (contract pin, no mutant)"
  "cdg-dl-noop-other-agent|case_cdg_dl_noop_other_agent|no opinion (#457): Explore agent under budget 0 and cap 1 -- no sample site precedes the role exit"
  "cdg-dl-noop-plan-mode|case_cdg_dl_noop_plan_mode|no opinion (#457): implementer in plan mode under budget 0 and cap 1 -- no sample site precedes the plan-mode exit"
  "cdg-dl-cap-seg|case_cdg_dl_cap_seg|deny (#457): 100 empty segments under cap 50 -- only is_apply_patch_word's segment loop samples that many times; the cap override is cleared after the call"
  "cdg-dl-cap-ww|case_cdg_dl_cap_ww|deny (#457): 100 env prefix words under cap 50 -- only walk_window's outer loop samples that many times"
  "cdg-dl-cap-redir|case_cdg_dl_cap_redir|deny (#457): a 100-operator redirect run under cap 50 -- only walk_window's redirect-run loop samples that many times"
  "cdg-dl-cap-db|case_cdg_dl_cap_db|deny (#457): echo apply_patch then a standalone ]] and 100 more words under cap 50 -- only the ]] pass samples that many times"
  "cdg-dl-cap-lines|case_cdg_dl_cap_lines|deny (#457): 100 semicolon-only lines under cap 250 -- only the three per-line loops together (prepass, per-line segment builder, begin-patch scan) sample that many times"
  "cdg-dl-cap-qpc|case_cdg_dl_cap_qpc|deny (#457): 100 prefix words before the resolved word in a quoted shim-mentioning segment under cap 150 -- only the walk plus the parity pass sample that many times"
  "cdg-dl-cap-scan-shim|case_cdg_dl_cap_scan_shim|deny (#457): a heredoc shim with 100 output redirects under cap 270 -- only the input scan's two loops together sample that many times"
  "cdg-dl-cap-ph|case_cdg_dl_cap_ph|deny (#457): an apply_patch with 100 content lines under cap 150 -- only parse_patch_headers' line loop samples that many times"
  "cdg-dl-cap-ltrim|case_cdg_dl_cap_ltrim|deny (#457): a header indented by 100 spaces under cap 50 -- only ltrim's strip loop, in its command substitution, samples that many times"
  "cdg-dl-cap-trim-header|case_cdg_dl_cap_trim_header|deny (#457): a header with 100 trailing spaces under cap 50 -- only trim's trailing loop samples that many times"
  "cdg-dl-cap-trim-nested|case_cdg_dl_cap_trim_nested|deny (#457): a header path with 100 leading spaces under cap 50 -- only the ltrim nested inside trim samples that many times"
  "cdg-dl-cap-trim-bash|case_cdg_dl_cap_trim_bash|deny (#457): a Bash command with 100 trailing spaces under cap 50 -- only the trim inside has_exact_begin_patch_line samples that many times"
  "cdg-dec-deny-redirect-file|case_cdg_dec_deny_redirect_file|deny: decoy / shim input (#455), deny-redirect-file"
  "cdg-dec-deny-redirect-first|case_cdg_dec_deny_redirect_first|deny: decoy / shim input (#455), deny-redirect-first"
  "cdg-dec-deny-applypatch|case_cdg_dec_deny_applypatch|deny: decoy / shim input (#455), deny-applypatch"
  "cdg-dec-deny-pipe|case_cdg_dec_deny_pipe|deny: decoy / shim input (#455), deny-pipe"
  "cdg-dec-deny-herestring|case_cdg_dec_deny_herestring|deny: decoy / shim input (#455), deny-herestring"
  "cdg-dec-deny-heredoc-then-redirect|case_cdg_dec_deny_heredoc_then_redirect|deny: decoy / shim input (#455), deny-heredoc-then-redirect"
  "cdg-dec-deny-heredoc-then-herestring|case_cdg_dec_deny_heredoc_then_herestring|deny: decoy / shim input (#455), deny-heredoc-then-herestring"
  "cdg-dec-deny-heredoc-then-rw|case_cdg_dec_deny_heredoc_then_rw|deny: decoy / shim input (#455), deny-heredoc-then-rw"
  "cdg-dec-deny-file-arg|case_cdg_dec_deny_file_arg|deny: decoy / shim input (#455), deny-file-arg"
  "cdg-dec-deny-fd-heredoc|case_cdg_dec_deny_fd_heredoc|deny: decoy / shim input (#455), deny-fd-heredoc"
  "cdg-dec-deny-procsubst|case_cdg_dec_deny_procsubst|deny: decoy / shim input (#455), deny-procsubst"
  "cdg-dec-deny-second-shim|case_cdg_dec_deny_second_shim|deny: decoy / shim input (#455), deny-second-shim"
  "cdg-dec-deny-two-tails|case_cdg_dec_deny_two_tails|deny: decoy / shim input (#455), deny-two-tails"
  "cdg-dec-deny-unquoted-dollar|case_cdg_dec_deny_unquoted_dollar|deny: decoy / shim input (#455), deny-unquoted-dollar"
  "cdg-dec-deny-unquoted-backtick|case_cdg_dec_deny_unquoted_backtick|deny: decoy / shim input (#455), deny-unquoted-backtick"
  "cdg-dec-deny-unquoted-backslash|case_cdg_dec_deny_unquoted_backslash|deny: decoy / shim input (#455), deny-unquoted-backslash"
  "cdg-dec-deny-body-codespan|case_cdg_dec_deny_body_codespan|deny: decoy / shim input (#455), deny-body-codespan"
  "cdg-dec-deny-heredoc-dotdot|case_cdg_dec_deny_heredoc_dotdot|deny: decoy / shim input (#455), deny-heredoc-dotdot"
  "cdg-dec-noop-heredoc-sq-dollar|case_cdg_dec_noop_heredoc_sq_dollar|no opinion: decoy / shim input (#455), noop-heredoc-sq-dollar"
  "cdg-dec-noop-heredoc-dq-dollar|case_cdg_dec_noop_heredoc_dq_dollar|no opinion: decoy / shim input (#455), noop-heredoc-dq-dollar"
  "cdg-dec-noop-heredoc-bs-dollar|case_cdg_dec_noop_heredoc_bs_dollar|no opinion: decoy / shim input (#455), noop-heredoc-bs-dollar"
  "cdg-dec-noop-heredoc-dash|case_cdg_dec_noop_heredoc_dash|no opinion: decoy / shim input (#455), noop-heredoc-dash"
  "cdg-dec-noop-heredoc-out-redirects|case_cdg_dec_noop_heredoc_out_redirects|no opinion: decoy / shim input (#455), noop-heredoc-out-redirects"
  "cdg-dec-noop-heredoc-chain|case_cdg_dec_noop_heredoc_chain|no opinion: decoy / shim input (#455), noop-heredoc-chain"
  "cdg-dec-noop-unquoted-plain|case_cdg_dec_noop_unquoted_plain|no opinion: decoy / shim input (#455), noop-unquoted-plain"
  "cdg-dec-noop-two-shims|case_cdg_dec_noop_two_shims|no opinion: decoy / shim input (#455), noop-two-shims"
  "cdg-dec-never-executes|case_cdg_dec_never_executes|deny, sentinel absent on a booby-trapped PATH: decoy / shim input (#455), never-executes"
  "cdg-dec-deny-flood-timing|case_cdg_dec_deny_flood_timing|wall-clock proof under a 15s active deadline: decoy / shim input (#455), deny-flood-timing"
  "cdg-qa-deny-sq-space|case_cdg_qa_deny_sq_space|deny: quoted assignment (#455, absorbing #456), deny-sq-space"
  "cdg-qa-deny-applypatch|case_cdg_qa_deny_applypatch|deny: quoted assignment before the applypatch spelling (#455, absorbing #456)"
  "cdg-qa-deny-dq-space|case_cdg_qa_deny_dq_space|deny: quoted assignment (#455, absorbing #456), deny-dq-space"
  "cdg-qa-deny-sq-many-spaces|case_cdg_qa_deny_sq_many_spaces|deny: quoted assignment (#455, absorbing #456), deny-sq-many-spaces"
  "cdg-qa-deny-dq-many-spaces|case_cdg_qa_deny_dq_many_spaces|deny: quoted assignment (#455, absorbing #456), deny-dq-many-spaces"
  "cdg-qa-deny-env-assign|case_cdg_qa_deny_env_assign|deny: quoted assignment (#455, absorbing #456), deny-env-assign"
  "cdg-qa-deny-env-quoted-assign|case_cdg_qa_deny_env_quoted_assign|deny: quoted assignment (#455, absorbing #456), deny-env-quoted-assign"
  "cdg-qa-deny-redirect-target|case_cdg_qa_deny_redirect_target|deny: quoted assignment (#455, absorbing #456), deny-redirect-target"
  "cdg-qa-deny-two-assigns|case_cdg_qa_deny_two_assigns|deny: quoted assignment (#455, absorbing #456), deny-two-assigns"
  "cdg-qa-deny-heredoc|case_cdg_qa_deny_heredoc|deny: quoted assignment (#455, absorbing #456), deny-heredoc"
  "cdg-qa-deny-cut-tail|case_cdg_qa_deny_cut_tail|deny: quoted assignment (#455, absorbing #456), deny-cut-tail"
  "cdg-qa-deny-backslash-space|case_cdg_qa_deny_backslash_space|deny: quoted assignment (#455, absorbing #456), deny-backslash-space"
  "cdg-qa-deny-body-possessive|case_cdg_qa_deny_body_possessive|deny: quoted assignment (#455, absorbing #456), deny-body-possessive"
  "cdg-qa-noop-quoted-arg|case_cdg_qa_noop_quoted_arg|no opinion: quoted assignment (#455, absorbing #456), noop-quoted-arg"
  "cdg-qa-noop-other-segment|case_cdg_qa_noop_other_segment|no opinion: quoted assignment (#455, absorbing #456), noop-other-segment"
  "cdg-qa-noop-balanced-assign|case_cdg_qa_noop_balanced_assign|no opinion: quoted assignment (#455, absorbing #456), noop-balanced-assign"
  "cdg-qa-never-executes|case_cdg_qa_never_executes|deny, sentinel absent on a booby-trapped PATH: quoted assignment (#455, absorbing #456), never-executes"
  "cdg-qa-noop-flood-timing|case_cdg_qa_noop_flood_timing|wall-clock proof under a 15s active deadline: quoted assignment (#455, absorbing #456), noop-flood-timing"
  # --- existing hooks, Codex payload shape (#407) cases ---------------------------------------
  "codex-gcg-main-status|case_codex_gcg_main_status|allow: git-c-guard.sh under a Codex-shaped main-session payload, git -C ../demo-wt-1 status --porcelain (pins the unchanged verdict -- Codex ignores this hook's if gate, but the script itself never reads it)"
  "codex-gcg-apply-patch|case_codex_gcg_apply_patch|silent: a Codex apply_patch payload (tool_name != Bash)"
  "codex-ab-impl-push|case_codex_ab_impl_push|deny: agent-boundary.sh under Codex, bare implementer, git push origin main"
  "codex-ab-verif-commit|case_codex_ab_verif_commit|deny: agent-boundary.sh under Codex, verifier, git commit -am x"
  "codex-ab-verif-status|case_codex_ab_verif_status|no opinion: agent-boundary.sh under Codex, verifier, git status"
  "codex-ab-impl-python-claude|case_codex_ab_impl_python_claude|deny (#387 replay under Codex): implementer, python3 -c \"open('.claude/settings.local.json','w').write('{}')\""
  "codex-ab-main-push|case_codex_ab_main_push|no opinion: agent-boundary.sh under Codex, main session, git push origin main"
  "codex-ab-impl-apply-patch|case_codex_ab_impl_apply_patch|no opinion: agent-boundary.sh under Codex, implementer, apply_patch (Bash-only hook -- tool_name gate excludes it regardless of command content)"
  "codex-pg-main-push-main|case_codex_pg_main_push_main|deny: push-guard.sh under Codex, main session, git push origin main, cwd a nonexistent path (deny through the default-branch fallback)"
  "codex-pg-impl-push-claude|case_codex_pg_impl_push_claude|no opinion: push-guard.sh under Codex, implementer, git push -u origin \"claude/17-a\""
  "codex-pg-apply-patch|case_codex_pg_apply_patch|no opinion: push-guard.sh under Codex, implementer, apply_patch (Bash-only hook)"
  # --- hook canary (#407) cases -----------------------------------------------------------------
  "canary-implementer|case_canary_implementer|deny: gh --version, Codex-shaped bare implementer, through hooks/agent-boundary.sh"
  "canary-implementer-ns|case_canary_implementer_ns|deny: gh --version, Claude-shaped namespaced implementer, through hooks/agent-boundary.sh"
  "canary-verifier|case_canary_verifier|deny: gh --version, Codex-shaped bare verifier, through hooks/agent-boundary.sh"
  "canary-verifier-ns|case_canary_verifier_ns|deny: gh --version, Claude-shaped namespaced verifier, through hooks/agent-boundary.sh"
  "canary-planner|case_canary_planner|deny: gh --version, Codex-shaped bare planner, through hooks/planner-guard.sh"
  "canary-planner-ns|case_canary_planner_ns|deny: gh --version, Claude-shaped namespaced planner, through hooks/planner-guard.sh"
  "canary-main-session|case_canary_main_session|gh --version, Codex-shaped main session, through all five runners: git-c-guard.sh silent, agent-boundary.sh/push-guard.sh/claude-dir-guard.sh/planner-guard.sh all no opinion"
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
  # mutant:383-fn-hook — renames a cases=() row's target function in a scratch copy of this
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
