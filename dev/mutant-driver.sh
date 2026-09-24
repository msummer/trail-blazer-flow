#!/usr/bin/env bash
#
# mutant-driver.sh — checked-in mutant driver for this repo's own dev/*.sh test suites (#359).
#
# Usage: dev/mutant-driver.sh [-j <n>|--serial] [name-filter]
#   -j <n>       run <n> mutants concurrently (a positive integer; an invalid value prints usage
#                on stderr and exits 2).
#   --serial     equivalent to -j 1 — one mutant at a time, in declared order.
#   name-filter  run only the registry records whose "name" contains this substring (a non-zero
#                exit if the filter matches no record).
#   With no -j/--serial, the job count comes from MUTANT_DRIVER_JOBS if set (env var), else from
#   detect_jobs (the host's core count, clamped to at most 16, falling back to 2 if none answers —
#   the identical probe dev/selfcheck-tests.sh's own detect_jobs uses). A command-line -j/--serial
#   always wins over MUTANT_DRIVER_JOBS.
#
# What this does: reads every dev/mutants/*.json registry file (or the directory named by
# MUTANT_DRIVER_REGISTRY_DIR, default dev/mutants — the override a fixture harness uses to point
# this real script at a throwaway registry). Each record names a target file, a suite to run
# against it (name-filtered by the record's own "filter"), one or more exact-text {from,to} edits
# to apply to a SCRATCH COPY of that target (never the tracked tree), and the set of suite case
# names the edited suite is recorded to fail. For each distinct (suite, filter) pair among the
# selected records, a baseline run (no edits) proves the suite is clean before any mutant depending
# on it is trusted; a red baseline short-circuits every dependent mutant to FAIL reason
# baseline-red without running its own suite. Every edit must match its target's current text
# EXACTLY ONCE — zero or multiple matches is a FAIL naming the edit index and the observed count,
# never a silent no-op or an ambiguous rewrite.
#
# Concurrency (the #336 idiom dev/selfcheck-tests.sh established): mutants run in bounded waves of
# up to $jobs children, each a background job that writes its own <idx>.out/<idx>.verdict files
# under one shared mktemp -d root (removed via an EXIT trap), collected back in DECLARED order
# regardless of completion order. A child that dies before writing its verdict is reported as a
# FAIL naming the record and "no-verdict", never silently dropped from the totals. A test-only
# MUTANT_DRIVER_FAULT=die:<name>|slow:<name> hook (harness-internal, read by dispatch()) mirrors
# dev/selfcheck-tests.sh's own SELFCHECK_TESTS_FAULT self-tests.
#
# Output grammar (this script's own — distinct from the "  PASS  <name> — <desc>" grammar the
# dev/*.sh suites it RUNS use):
#   == mutant-driver: <N> jobs ==                   (first line; N is concurrency, not job count)
#   PASS baseline:<suite>:<filter> <total> -        (or FAIL ... <total> <set>, red baseline)
#   PASS <name> <total> <set>                       (<set> is "-" when empty)
#   FAIL <name> <total|-> <set|->
#       expected <set>                              (only on a failing-set mismatch)
#       reason <text>                               (only on a structural/skip failure)
#   == summary: <N> pass, <M> fail ==
# Exit 0 iff every baseline and mutant passed; 1 if any FAILed; 2 on a usage or registry error
# (before any suite ever runs).
#
# Writes only under its own single mktemp -d root (an EXIT trap removes it); the tracked tree is
# never touched — every edit lands on a fresh_copy scratch copy, and the copy's own root (never a
# bare name resolved off $PATH) is what gets invoked, so a same-named decoy elsewhere on $PATH is
# never reached. Reads: registry JSON under dev/mutants/ (or $MUTANT_DRIVER_REGISTRY_DIR), and the
# repo tree it copies from. No network, no gh, no git.
#
# Run this locally before pushing any change to a registry "target", a registry "suite", or the
# registry itself — see CLAUDE.md's Verification section for the CI placement (this script runs
# post-merge/nightly/dispatch only, never per pull request; dev/mutant-driver-tests.sh runs per
# PR).
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "mutant-driver: jq not installed — required to read the registry and drive the edit engine" >&2
  exit 2
fi

# detect_jobs — byte-for-byte the same probe chain as dev/selfcheck-tests.sh's own detect_jobs
# (sysctl -n hw.ncpu / nproc / getconf _NPROCESSORS_ONLN, each command -v-guarded and digits-
# validated), clamped to at most 16, falling back to 2 if none answers.
detect_jobs() {
  local n=""
  if [ -z "$n" ] && command -v sysctl >/dev/null 2>&1; then
    n="$(sysctl -n hw.ncpu 2>/dev/null)"
    case "$n" in ''|*[!0-9]*|0) n="" ;; esac
  fi
  if [ -z "$n" ] && command -v nproc >/dev/null 2>&1; then
    n="$(nproc 2>/dev/null)"
    case "$n" in ''|*[!0-9]*|0) n="" ;; esac
  fi
  if [ -z "$n" ] && command -v getconf >/dev/null 2>&1; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null)"
    case "$n" in ''|*[!0-9]*|0) n="" ;; esac
  fi
  [ -n "$n" ] || n=2
  [ "$n" -le 16 ] || n=16
  printf '%s' "$n"
}

usage_die() {
  echo "usage: dev/mutant-driver.sh [-j <n>|--serial] [name-filter] -- $1" >&2
  exit 2
}

jobs_flag=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      cat <<'EOF'
usage: dev/mutant-driver.sh [-j <n>|--serial] [name-filter]

  -j <n>       run <n> mutants concurrently (a positive integer)
  --serial     equivalent to -j 1 -- one mutant at a time, in declared order
  name-filter  run only the registry records whose name contains this substring

With no name-filter, runs every registry record. MUTANT_DRIVER_JOBS overrides the detected
default when neither -j nor --serial is given. MUTANT_DRIVER_REGISTRY_DIR overrides the registry
directory (default: dev/mutants under this checkout).
EOF
      exit 0
      ;;
    -j)
      shift
      jobs_flag="${1:-}"
      case "$jobs_flag" in
        ''|*[!0-9]*|0) usage_die "-j requires a positive integer, got '${1:-}'" ;;
      esac
      shift
      ;;
    --serial)
      jobs_flag=1
      shift
      ;;
    -*)
      usage_die "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done
filter="${1:-}"

if [ -n "$jobs_flag" ]; then
  jobs="$jobs_flag"
elif [ -n "${MUTANT_DRIVER_JOBS:-}" ]; then
  jobs="$MUTANT_DRIVER_JOBS"
  case "$jobs" in
    ''|*[!0-9]*|0) usage_die "MUTANT_DRIVER_JOBS must be a positive integer, got '$jobs'" ;;
  esac
else
  jobs="$(detect_jobs)"
fi

echo "== mutant-driver: $jobs jobs =="

registry_dir="${MUTANT_DRIVER_REGISTRY_DIR:-$root/dev/mutants}"

# ---------------------------------------------------------------------------------------------
# Registry load + validation. Every violation is collected (not just the first) and reported
# before any suite ever runs — see the header's own exit-2 contract.
reg_errors=()
rec_name=(); rec_target=(); rec_suite=(); rec_filter=(); rec_edits=(); rec_expect=(); rec_file=()

add_err() { reg_errors+=("$1"); }

# name_known NAME — true (rc 0) iff NAME already appears in rec_name[] (cross-file uniqueness).
name_known() {
  local want="$1" have
  [ "${#rec_name[@]}" -gt 0 ] || return 1
  for have in "${rec_name[@]}"; do
    [ "$have" = "$want" ] && return 0
  done
  return 1
}

load_registry_file() {
  local f="$1" n i rec name target suite filt keys_ok ne ei efrom eto etype
  if ! jq -e 'type=="object" and has("mutants") and (.mutants|type=="array")' "$f" >/dev/null 2>&1; then
    add_err "$f: top-level shape must be {\"mutants\": [...]}"
    return
  fi
  n="$(jq '.mutants | length' "$f")"
  i=0
  while [ "$i" -lt "$n" ]; do
    rec="$(jq -c ".mutants[$i]" "$f")"
    if [ "$(jq -r 'type' <<<"$rec")" != "object" ]; then
      add_err "$f[$i]: record is not an object"
      i=$((i+1)); continue
    fi
    keys_ok="$(jq -r '(keys_unsorted|sort) == ["edits","expect_fail","filter","name","suite","target"]' <<<"$rec")"
    if [ "$keys_ok" != "true" ]; then
      add_err "$f[$i]: record must have exactly the keys name, target, suite, filter, edits, expect_fail"
      i=$((i+1)); continue
    fi
    name="$(jq -r '.name' <<<"$rec")"
    target="$(jq -r '.target' <<<"$rec")"
    suite="$(jq -r '.suite' <<<"$rec")"
    filt="$(jq -r '.filter' <<<"$rec")"

    if ! grep -qE '^[A-Za-z0-9][A-Za-z0-9-]*$' <<<"$name"; then
      add_err "$f[$i]: name '$name' does not match ^[A-Za-z0-9][A-Za-z0-9-]*\$"
    elif name_known "$name"; then
      add_err "$f[$i]: duplicate mutant name '$name'"
    fi

    if [ -z "$target" ] || [ "$target" = "null" ]; then
      add_err "$f[$i] ($name): target is missing or not a string"
    else
      case "$target" in
        /*) add_err "$f[$i] ($name): target '$target' must not be absolute" ;;
      esac
      case "$target" in
        *..*) add_err "$f[$i] ($name): target '$target' must not contain '..'" ;;
      esac
      [ -f "$root/$target" ] || add_err "$f[$i] ($name): target '$target' does not exist"
    fi

    if ! grep -qE '^dev/[A-Za-z0-9._-]+\.sh$' <<<"$suite"; then
      add_err "$f[$i] ($name): suite '$suite' does not match ^dev/[A-Za-z0-9._-]+\\.sh\$"
    elif [ ! -f "$root/$suite" ]; then
      add_err "$f[$i] ($name): suite '$suite' does not exist"
    fi

    if [ "$(jq -r '.filter | type' <<<"$rec")" != "string" ]; then
      add_err "$f[$i] ($name): filter must be a string"
    fi

    etype="$(jq -r '.edits | type' <<<"$rec")"
    if [ "$etype" != "array" ] || [ "$(jq '.edits | length' <<<"$rec")" -eq 0 ]; then
      add_err "$f[$i] ($name): edits must be a non-empty array"
    else
      ne="$(jq '.edits | length' <<<"$rec")"
      ei=0
      while [ "$ei" -lt "$ne" ]; do
        efrom="$(jq -r ".edits[$ei].from // \"\"" <<<"$rec")"
        eto="$(jq -r ".edits[$ei].to // \"\"" <<<"$rec")"
        if [ "$(jq -r ".edits[$ei].from // \"\" | type" <<<"$rec")" != "string" ] || [ -z "$efrom" ]; then
          add_err "$f[$i] ($name): edits[$ei].from must be a non-empty string"
        elif [ "$efrom" = "$eto" ]; then
          add_err "$f[$i] ($name): edits[$ei].from must differ from edits[$ei].to"
        fi
        ei=$((ei+1))
      done
    fi

    etype="$(jq -r '.expect_fail | type' <<<"$rec")"
    if [ "$etype" != "array" ] || [ "$(jq '.expect_fail | length' <<<"$rec")" -eq 0 ]; then
      add_err "$f[$i] ($name): expect_fail must be a non-empty array"
    fi

    rec_name+=("$name")
    rec_target+=("$target")
    rec_suite+=("$suite")
    rec_filter+=("$filt")
    rec_edits+=("$(jq -c '.edits' <<<"$rec")")
    rec_expect+=("$(jq -c '.expect_fail' <<<"$rec")")
    rec_file+=("$f")
    i=$((i+1))
  done
}

reg_files=()
for f in "$registry_dir"/*.json; do
  [ -f "$f" ] || continue
  reg_files+=("$f")
done
if [ "${#reg_files[@]}" -gt 0 ]; then
  sorted_reg_files=()
  while IFS= read -r line; do
    [ -n "$line" ] && sorted_reg_files+=("$line")
  done < <(printf '%s\n' "${reg_files[@]}" | sort)
  for f in "${sorted_reg_files[@]}"; do
    load_registry_file "$f"
  done
fi

if [ "${#reg_errors[@]}" -gt 0 ]; then
  echo "mutant-driver: registry validation failed:" >&2
  for e in "${reg_errors[@]}"; do
    echo "  $e" >&2
  done
  exit 2
fi

# ---------------------------------------------------------------------------------------------
# Filter selection.
sel=()
for ridx in "${!rec_name[@]}"; do
  case "${rec_name[$ridx]}" in
    *"$filter"*) sel+=("$ridx") ;;
  esac
done
if [ "${#sel[@]}" -eq 0 ]; then
  echo "no mutant name contains '$filter'"
  exit 1
fi

# ---------------------------------------------------------------------------------------------
# Scratch root, portable file-mode probe, and the edit engine's own writer (isolated in its own
# function so a self-mutant can retarget exactly this shape — mv drops the exec bit; this writes
# in place).
tmpbase="$(mktemp -d)"
resdir="$tmpbase/results"
mkdir -p "$resdir"
cleanup() {
  wait
  if [ -n "$tmpbase" ] && [ -d "$tmpbase" ]; then
    rm -rf "$tmpbase"
  fi
}
trap cleanup EXIT

# fresh_copy NAME — cp -R of this repo (everything except .git) into $tmpbase/NAME; prints the
# path. One fresh copy per job: never the tracked tree, never shared between jobs.
fresh_copy() {
  local dst="$tmpbase/$1"
  mkdir -p "$dst"
  local e base
  for e in "$root"/* "$root"/.[!.]*; do
    [ -e "$e" ] || continue
    base="$(basename "$e")"
    case "$base" in .git) continue ;; esac
    cp -R "$e" "$dst/"
  done
  printf '%s' "$dst"
}

# file_mode PATH — prints PATH's permission bits, GNU stat first, then BSD stat; empty if neither
# works (treated as "unknown", never a false match).
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}

# write_target PATH — writes stdin to PATH IN PLACE (never via a temp file + mv, which would
# replace PATH's inode with the temp file's own mode and drop the exec bit — LESSON 2026-09-15b).
# (dev/mutants/mutant-driver-tests.json's drv-mv self-mutant retargets this function — see
# dev/mutant-driver-tests.sh's own case_exec_bit_preserved comment.)
write_target() {
  cat > "$1"
}

# count_lines STR — 0 for an empty STR, else its newline-terminated line count.
count_lines() {
  if [ -z "$1" ]; then
    printf '0'
  else
    printf '%s\n' "$1" | wc -l | tr -d ' '
  fi
}

# join_sorted [NAME...] — comma-joined, LC_ALL=C-sorted, de-duplicated list, or "-" when empty.
join_sorted() {
  if [ "$#" -eq 0 ]; then
    printf -- '-'
    return
  fi
  local sorted=() x joined=""
  while IFS= read -r x; do
    [ -n "$x" ] && sorted+=("$x")
  done < <(printf '%s\n' "$@" | LC_ALL=C sort -u)
  if [ "${#sorted[@]}" -eq 0 ]; then
    printf -- '-'
    return
  fi
  for x in "${sorted[@]}"; do
    joined="${joined:+$joined,}$x"
  done
  printf '%s' "$joined"
}

# lines_to_words STR — prints STR's lines space-joined, for feeding join_sorted/count comparisons.
lines_to_words() {
  if [ -z "$1" ]; then
    return
  fi
  printf '%s\n' "$1" | tr '\n' ' '
}

# run_suite_and_parse COPY SUITE FILTER — runs COPY's own SUITE (never a bare name off $PATH),
# filtered by FILTER, and sets the globals: parsed_ok (1/0), parsed_reason (no-summary/
# total-mismatch/empty), parsed_total, parsed_pass_names, parsed_fail_names (each newline-joined,
# possibly empty).
parsed_ok=1; parsed_reason=""; parsed_total="-"; parsed_pass_names=""; parsed_fail_names=""
run_suite_and_parse() {
  local copy="$1" suite="$2" filt="$3" out footer fp fc n_pass n_fail
  out="$(cd "$copy" && bash "$copy/$suite" "$filt" 2>&1)"
  footer="$(printf '%s\n' "$out" | sed -nE 's/^== summary: ([0-9]+) pass, ([0-9]+) fail ==$/\1 \2/p')"
  parsed_pass_names="$(printf '%s\n' "$out" | sed -nE 's/^  PASS  ([^ ]+) .*/\1/p')"
  parsed_fail_names="$(printf '%s\n' "$out" | sed -nE 's/^  FAIL  ([^ ]+) .*/\1/p')"
  # (dev/mutants/mutant-driver-tests.json's drv-total self-mutant deletes this guard — see
  # dev/mutant-driver-tests.sh's own case_suite_no_summary comment.)
  if [ -z "$footer" ]; then
    parsed_ok=0; parsed_reason="no-summary"; parsed_total="-"
    return
  fi
  fp="${footer%% *}"; fc="${footer##* }"
  n_pass="$(count_lines "$parsed_pass_names")"
  n_fail="$(count_lines "$parsed_fail_names")"
  if [ "$((fp + fc))" -ne "$((n_pass + n_fail))" ]; then
    parsed_ok=0; parsed_reason="total-mismatch"; parsed_total="-"
    return
  fi
  parsed_ok=1; parsed_reason=""; parsed_total="$((fp + fc))"
}

# ---------------------------------------------------------------------------------------------
# Wave scheduler (the #336 idiom): case_no/job_name are global and grow across BOTH phases below;
# wave_idx is reset each wave. flush_wave reads each wave's result files back in the WAVE's
# declared order, never completion order.
case_no=0
job_name=()
wave_n=0
wave_idx=()

flush_wave() {
  wait
  local k=0 idx v out
  while [ "$k" -lt "$wave_n" ]; do
    idx="${wave_idx[$k]}"
    # (dev/mutants/mutant-driver-tests.json's drv-order self-mutant rewrites the loop head above
    # to iterate by completion order instead — see dev/mutant-driver-tests.sh's own
    # case_declared_order comment.)
    v="$(cat "$resdir/$idx.verdict" 2>/dev/null)"
    out="$(cat "$resdir/$idx.out" 2>/dev/null)"
    case "$v" in
      pass)
        pass=$((pass+1))
        [ -n "$out" ] && printf '%s\n' "$out"
        ;;
      fail)
        fail=$((fail+1))
        [ -n "$out" ] && printf '%s\n' "$out"
        ;;
      # (dev/mutants/mutant-driver-tests.json's drv-noverdict self-mutant rewrites this arm to
      # count a missing verdict as a silent pass — see dev/mutant-driver-tests.sh's own
      # case_child_dies comment.)
      *)
        fail=$((fail+1))
        echo "FAIL ${job_name[$idx]} - -"
        echo "    reason no-verdict"
        ;;
    esac
    k=$((k+1))
  done
  wave_n=0
}

# run_baseline_job SUITE FILTER — prints the baseline's PASS/FAIL line (and an optional reason
# line) to stdout, writes "clean"/"red" to $resdir/$2.basestatus (idx passed via $BASE_IDX, set by
# the caller), and returns 0 (pass) or 1 (fail).
run_baseline_job() {
  local suite="$1" filt="$2" copy
  local name="baseline:$suite:$filt"
  copy="$(fresh_copy "b$case_no")"
  run_suite_and_parse "$copy" "$suite" "$filt"
  if [ "$parsed_ok" -eq 0 ]; then
    echo "red" > "$resdir/$case_no.basestatus"
    echo "FAIL $name - -"
    echo "    reason $parsed_reason"
    return 1
  fi
  if [ -n "$parsed_fail_names" ]; then
    echo "red" > "$resdir/$case_no.basestatus"
    echo "FAIL $name $parsed_total $(join_sorted $(lines_to_words "$parsed_fail_names"))"
    echo "    reason pre-existing-failures"
    return 1
  fi
  echo "clean" > "$resdir/$case_no.basestatus"
  echo "PASS $name $parsed_total -"
  return 0
}

# run_mutant_job RIDX BASESTATUS — RIDX indexes rec_*[]; BASESTATUS is "clean" or "red" for this
# mutant's own (suite, filter) baseline.
run_mutant_job() {
  local ridx="$1" basestatus="$2"
  local name="${rec_name[$ridx]}" target="${rec_target[$ridx]}" suite="${rec_suite[$ridx]}"
  local filt="${rec_filter[$ridx]}" edits_json="${rec_edits[$ridx]}" expect_json="${rec_expect[$ridx]}"

  if [ "$basestatus" != "clean" ]; then
    echo "FAIL $name - -"
    echo "    reason baseline-red"
    return 1
  fi

  local copy tpath mode_before mode_after
  copy="$(fresh_copy "m$case_no")"
  tpath="$copy/$target"
  mode_before="$(file_mode "$tpath")"

  local n_edits ei e efrom result ok matches fail_reason=""
  n_edits="$(jq 'length' <<<"$edits_json")"
  ei=0
  while [ "$ei" -lt "$n_edits" ]; do
    e="$(jq -c ".[$ei]" <<<"$edits_json")"
    # (dev/mutants/mutant-driver-tests.json's drv-once self-mutant widens the jq condition below
    # from "$matches != 1" to "$matches < 1" — see dev/mutant-driver-tests.sh's own
    # case_recipe_multi_match comment.)
    result="$(jq -Rs --argjson e "$e" '
      . as $content
      | ($content | split($e.from) | length - 1) as $matches
      | if $matches != 1 then
          {ok:false, matches:$matches}
        else
          {ok:true, content:($content | split($e.from) | join($e.to))}
        end
    ' "$tpath")"
    ok="$(jq -r '.ok' <<<"$result")"
    if [ "$ok" != "true" ]; then
      matches="$(jq -r '.matches' <<<"$result")"
      fail_reason="edit $ei matched $matches time(s) (expected exactly 1)"
      break
    fi
    jq -j '.content' <<<"$result" | write_target "$tpath"
    ei=$((ei+1))
  done

  if [ -n "$fail_reason" ]; then
    echo "FAIL $name - -"
    echo "    reason $fail_reason"
    return 1
  fi

  mode_after="$(file_mode "$tpath")"
  if [ "$mode_before" != "$mode_after" ]; then
    echo "FAIL $name - -"
    echo "    reason exec-bit-lost"
    return 1
  fi

  run_suite_and_parse "$copy" "$suite" "$filt"
  if [ "$parsed_ok" -eq 0 ]; then
    echo "FAIL $name - -"
    echo "    reason $parsed_reason"
    return 1
  fi

  local expect_names ex unknown="" all_names
  expect_names="$(jq -r '.[]' <<<"$expect_json")"
  all_names="$parsed_pass_names"$'\n'"$parsed_fail_names"
  while IFS= read -r ex; do
    [ -n "$ex" ] || continue
    if ! grep -qxF -- "$ex" <<<"$all_names"; then
      unknown="$ex"
      break
    fi
  done <<<"$expect_names"
  if [ -n "$unknown" ]; then
    echo "FAIL $name $parsed_total -"
    echo "    reason unknown-case:$unknown"
    return 1
  fi

  local expect_set observed_set
  expect_set="$(join_sorted $(lines_to_words "$expect_names"))"
  observed_set="$(join_sorted $(lines_to_words "$parsed_fail_names"))"
  # (dev/mutants/mutant-driver-tests.json's drv-setcmp self-mutant replaces this exact-set
  # compare with a count-only compare — see dev/mutant-driver-tests.sh's own
  # case_fail_swapped_member comment.)
  if [ "$expect_set" = "$observed_set" ]; then
    echo "PASS $name $parsed_total $observed_set"
    return 0
  fi
  echo "FAIL $name $parsed_total $observed_set"
  echo "    expected $expect_set"
  return 1
}

# ---------------------------------------------------------------------------------------------
# dispatch KIND IDX ... — always invoked as `dispatch ... &`, even at jobs=1. FIRST statement:
# `trap - EXIT` (see dev/selfcheck-tests.sh's own dispatch_case for why this insurance line stays
# even though it is not required for correctness). Then the harness-internal
# MUTANT_DRIVER_FAULT=die:<name>|slow:<name> hook (never a registry perturbation).
dispatch() {
  trap - EXIT
  local kind="$1" idx="$2" name="$3"
  local fault="${MUTANT_DRIVER_FAULT:-}"
  case "$fault" in
    "die:$name") exit 9 ;;
    "slow:$name") sleep 2 ;;
  esac
  if [ "$kind" = "baseline" ]; then
    run_baseline_job "$4" "$5" > "$resdir/$idx.out" 2> "$resdir/$idx.err"
  else
    run_mutant_job "$4" "$5" > "$resdir/$idx.out" 2> "$resdir/$idx.err"
  fi
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'pass' > "$resdir/$idx.verdict"
  else
    printf 'fail' > "$resdir/$idx.verdict"
  fi
}

pass=0; fail=0

# ---------------------------------------------------------------------------------------------
# Phase 1: one baseline per distinct (suite, filter) pair among the selected records, in order of
# first appearance. Fully flushed before any mutant runs (see the header's own ordering note).
base_suite=(); base_filter=(); base_idx=()
for ridx in "${sel[@]}"; do
  s="${rec_suite[$ridx]}"; ft="${rec_filter[$ridx]}"
  found=0
  for bk in "${!base_suite[@]}"; do
    if [ "${base_suite[$bk]}" = "$s" ] && [ "${base_filter[$bk]}" = "$ft" ]; then
      found=1
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    base_suite+=("$s")
    base_filter+=("$ft")
  fi
done

for bk in "${!base_suite[@]}"; do
  case_no=$((case_no+1))
  job_name[$case_no]="baseline:${base_suite[$bk]}:${base_filter[$bk]}"
  base_idx+=("$case_no")
  wave_idx[$wave_n]="$case_no"
  dispatch baseline "$case_no" "${job_name[$case_no]}" "${base_suite[$bk]}" "${base_filter[$bk]}" &
  wave_n=$((wave_n+1))
  if [ "$wave_n" -ge "$jobs" ]; then
    flush_wave
  fi
done
flush_wave

# basestatus_for SUITE FILTER — prints "clean"/"red" for the matching baseline, "red" if somehow
# absent (fail closed).
basestatus_for() {
  local s="$1" ft="$2" bk
  for bk in "${!base_suite[@]}"; do
    if [ "${base_suite[$bk]}" = "$s" ] && [ "${base_filter[$bk]}" = "$ft" ]; then
      cat "$resdir/${base_idx[$bk]}.basestatus" 2>/dev/null || echo "red"
      return
    fi
  done
  echo "red"
}

# ---------------------------------------------------------------------------------------------
# Phase 2: every selected mutant, in registry-declared order.
for ridx in "${sel[@]}"; do
  case_no=$((case_no+1))
  job_name[$case_no]="${rec_name[$ridx]}"
  bstatus="$(basestatus_for "${rec_suite[$ridx]}" "${rec_filter[$ridx]}")"
  wave_idx[$wave_n]="$case_no"
  dispatch mutant "$case_no" "${job_name[$case_no]}" "$ridx" "$bstatus" &
  wave_n=$((wave_n+1))
  if [ "$wave_n" -ge "$jobs" ]; then
    flush_wave
  fi
done
flush_wave

echo
echo "== summary: $pass pass, $fail fail =="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
