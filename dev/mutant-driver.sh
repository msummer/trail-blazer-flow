#!/usr/bin/env bash
#
# mutant-driver.sh — checked-in mutant driver for this repo's own dev/*.sh test suites (#359).
#
# Usage: dev/mutant-driver.sh [-j <n>|--serial] [--changed-from <file>] [--shard <i>/<n>] [name-filter]
#   -j <n>       run <n> mutants concurrently (a positive integer; an invalid value prints usage
#                on stderr and exits 2).
#   --serial     equivalent to -j 1 — one mutant at a time, in declared order.
#   --changed-from <file>
#                select only the registry records a change can affect, from a file of
#                repo-relative changed paths (one per line; blank lines ignored; a trailing \r is
#                stripped). Wins over MUTANT_DRIVER_SINCE. A file that doesn't exist, or a missing
#                argument, exits 2 with usage on stderr before any suite runs.
#   --shard <i>/<n>
#                run only slice i of n (1 <= i <= n, plain digits, no leading zero). The env form is
#                MUTANT_DRIVER_SHARD=<i>/<n>; an empty or unset value means no sharding, and the
#                flag wins when both are given. A malformed spec, or a --shard with no argument,
#                exits 2 with usage on stderr before any suite runs.
#   name-filter  run only the registry records whose "name" contains this substring (a non-zero
#                exit if the filter matches no record).
#   With no -j/--serial, the job count comes from MUTANT_DRIVER_JOBS if set (env var), else from
#   detect_jobs (the host's core count, clamped to at most 16, falling back to 2 if none answers —
#   the identical probe dev/selfcheck-tests.sh's own detect_jobs uses). A command-line -j/--serial
#   always wins over MUTANT_DRIVER_JOBS.
#
#   Change-based selection (#464): with neither --changed-from nor a non-empty
#   MUTANT_DRIVER_SINCE, every registry record runs (after any name-filter) and this script's
#   output is byte-identical to before #464. Set MUTANT_DRIVER_SINCE=<rev> to select instead, by
#   `git -C <root> diff --no-renames --name-only <rev> HEAD --`: a record is selected iff a
#   changed path equals its target, its suite, or its registry file, or matches a
#   dev/mutants/suite-deps.txt pattern its suite declares — a suite with no map line matches any
#   change. A changed path under bin/, hooks/, templates/, agents/, skills/ or dev/ that no record
#   or map pattern (other than a bare "*") claims, or any change to this script itself, forces a
#   full run instead — so does an unusable MUTANT_DRIVER_SINCE (a leading "-", an all-zero or
#   unknown commit, or any other git-diff failure).
#
#   Sharding: a shard spec partitions whatever set the run would otherwise run — after the
#   name-filter and any change-based selection. The set is grouped by (suite, filter) pair, the
#   same pairs that get one baseline each, in order of first appearance; each whole group goes to
#   the shard with the fewest records so far (ties to the lowest index), so a baseline is never
#   run by two shards and every record lands in exactly one shard. A shard left with no record
#   prints the zero-record footer and exits 0.
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
# Concurrency: a rolling pool of up to $jobs background children, each a background job that
# writes its own <idx>.out/<idx>.verdict files under one shared mktemp -d root (removed via an EXIT
# trap). A new job starts whenever any running one finishes, and a mutant is never started before
# its own (suite, filter) baseline job has finished — other baselines may still be running; there
# is no global baseline barrier. Completion is polled in short slices (a verdict file, or a dead
# pid via kill -0; bash 3.2 has no wait -n). Results are collected back in DECLARED order
# regardless of completion order. A child that dies before writing its verdict is reported as a
# FAIL naming the record and "no-verdict", never silently dropped from the totals. A test-only
# MUTANT_DRIVER_FAULT=die:<name>|slow:<name> hook (harness-internal, read by dispatch()) mirrors
# dev/selfcheck-tests.sh's own SELFCHECK_TESTS_FAULT self-tests.
#
# Output grammar (this script's own — distinct from the "  PASS  <name> — <desc>" grammar the
# dev/*.sh suites it RUNS use):
#   == mutant-driver: <N> jobs ==                   (first line; N is concurrency, not job count)
#   == mutant-driver: selected <N> of <M> records ==  (change-based selection only; #464)
#   == mutant-driver: full run (reason: <text>) ==    (change-based selection fell back; #464)
#   == mutant-driver: shard <i>/<n>: <K> of <N> records ==  (sharded runs only; N is the set left
#                                                    after the name-filter and any selection)
#   PASS baseline:<suite>:<filter> <total> -        (or FAIL ... <total> <set>, red baseline)
#   PASS <name> <total> <set>                       (<set> is "-" when empty)
#   FAIL <name> <total|-> <set|->
#       expected <set>                              (only on a failing-set mismatch)
#       reason <text>                               (only on a structural/skip failure)
#   == summary: <N> pass, <M> fail ==
# Exit 0 iff every baseline and mutant passed; 1 if any FAILed; 2 on a usage or registry error
# (before any suite ever runs). With neither --changed-from nor a non-empty MUTANT_DRIVER_SINCE,
# neither selection line ever prints and every registry record runs — byte-identical to before
# #464; with no shard spec either, no shard line ever prints. Zero records selected is itself a PASS: the "selected 0 of <M>" line, then the summary
# footer, exit 0, no suite ever runs.
#
# Writes only under its own single mktemp -d root (an EXIT trap removes it); the tracked tree is
# never touched — every edit lands on a fresh_copy scratch copy, and the copy's own root (never a
# bare name resolved off $PATH) is what gets invoked, so a same-named decoy elsewhere on $PATH is
# never reached. Reads: registry JSON under dev/mutants/ (or $MUTANT_DRIVER_REGISTRY_DIR), that
# directory's own suite-deps.txt dependency map, the repo tree it copies from, and (when given) the
# --changed-from file. No network, no gh; git only when MUTANT_DRIVER_SINCE is set, and then only
# `git diff --no-renames --name-only` to list changed paths.
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
  echo "usage: dev/mutant-driver.sh [-j <n>|--serial] [--changed-from <file>] [--shard <i>/<n>] [name-filter] -- $1" >&2
  exit 2
}

jobs_flag=""
changed_from=""
shard_flag=""
shard_flag_set=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      cat <<'EOF'
usage: dev/mutant-driver.sh [-j <n>|--serial] [--changed-from <file>] [--shard <i>/<n>] [name-filter]

  -j <n>            run <n> mutants concurrently (a positive integer)
  --serial          equivalent to -j 1 -- one mutant at a time, in declared order
  --changed-from <file>
                    select only the registry records a change can affect, from a file of
                    repo-relative changed paths (one per line; blank lines ignored; a trailing
                    \r is stripped). Wins over MUTANT_DRIVER_SINCE.
  --shard <i>/<n>   run only slice i of n (whole (suite, filter) groups, balanced by record
                    count); MUTANT_DRIVER_SHARD is the env form; the flag wins
  name-filter       run only the registry records whose name contains this substring

With no name-filter, runs every selected registry record (every record, when neither selection
nor a shard spec is in effect). MUTANT_DRIVER_JOBS overrides the detected default when neither -j nor --serial is given.
MUTANT_DRIVER_REGISTRY_DIR overrides the registry directory (default: dev/mutants under this
checkout). With neither --changed-from nor a non-empty MUTANT_DRIVER_SINCE, every registry record
runs -- unchanged from before change-based selection landed. MUTANT_DRIVER_SINCE=<rev> selects
instead by `git diff --no-renames --name-only <rev> HEAD` against this checkout and
dev/mutants/suite-deps.txt; an unusable base (a leading "-", an all-zero or unknown commit, or any
other git-diff failure) forces a full run instead.
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
    --changed-from)
      shift
      changed_from="${1:-}"
      [ -n "$changed_from" ] || usage_die "--changed-from requires a file argument"
      shift
      ;;
    --shard)
      shift
      shard_flag="${1:-}"
      shard_flag_set=1
      [ -n "$shard_flag" ] || usage_die "--shard requires <i>/<n>"
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

if [ -n "$changed_from" ] && [ ! -f "$changed_from" ]; then
  usage_die "--changed-from file '$changed_from' does not exist"
fi

# Shard spec: the flag wins over MUTANT_DRIVER_SHARD; empty means no sharding. Both halves must be
# plain digits with no leading zero (so bash arithmetic never reads one as octal) and i <= n.
shard_spec=""
shard_where="MUTANT_DRIVER_SHARD must be"
if [ "$shard_flag_set" -eq 1 ]; then
  shard_spec="$shard_flag"
  shard_where="--shard expects"
elif [ -n "${MUTANT_DRIVER_SHARD:-}" ]; then
  shard_spec="$MUTANT_DRIVER_SHARD"
fi
shard_i=""; shard_n=""
if [ -n "$shard_spec" ]; then
  case "$shard_spec" in
    */*/*) usage_die "$shard_where <i>/<n> with 1 <= i <= n, got '$shard_spec'" ;;
    */*) ;;
    *) usage_die "$shard_where <i>/<n> with 1 <= i <= n, got '$shard_spec'" ;;
  esac
  shard_i="${shard_spec%%/*}"
  shard_n="${shard_spec#*/}"
  case "$shard_i" in
    ''|*[!0-9]*|0*) usage_die "$shard_where <i>/<n> with 1 <= i <= n, got '$shard_spec'" ;;
  esac
  case "$shard_n" in
    ''|*[!0-9]*|0*) usage_die "$shard_where <i>/<n> with 1 <= i <= n, got '$shard_spec'" ;;
  esac
  if [ "$shard_i" -gt "$shard_n" ]; then
    usage_die "$shard_where <i>/<n> with 1 <= i <= n, got '$shard_spec'"
  fi
fi

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

# ---------------------------------------------------------------------------------------------
# Change-based selection's dependency map (#464): dev/mutants/suite-deps.txt, an optional
# plain-text "<suite> <pattern>" list — see that file's own header for the format and semantics.
# A missing map file is not an error: every suite is then unmapped (matches any change). Folded
# into reg_errors so a malformed map is reported, and blocks every suite run, exactly like a
# malformed registry record.
dep_suite=(); dep_pat=()
deps_file="$registry_dir/suite-deps.txt"
if [ -f "$deps_file" ]; then
  dep_lineno=0
  while IFS= read -r dep_line || [ -n "$dep_line" ]; do
    dep_lineno=$((dep_lineno+1))
    dep_line="${dep_line%$'\r'}"
    dep_trimmed="$(printf '%s' "$dep_line" | sed -E 's/^[[:space:]]+//')"
    case "$dep_trimmed" in
      ''|'#'*) continue ;;
    esac
    d_suite=""; d_pat=""; d_rest=""
    read -r d_suite d_pat d_rest <<<"$dep_line"
    if [ -z "$d_pat" ] || [ -n "$d_rest" ]; then
      add_err "$deps_file:$dep_lineno: expected '<suite> <pattern>'"
      continue
    fi
    case "$d_pat" in
      *'*'*|*'?'*|*'['*) has_glob=1 ;;
      *) has_glob=0 ;;
    esac
    if [ "$has_glob" -eq 0 ] && [ ! -e "$root/$d_pat" ]; then
      add_err "$deps_file:$dep_lineno: pattern '$d_pat' names no existing file"
      continue
    fi
    dep_suite+=("$d_suite")
    dep_pat+=("$d_pat")
  done < "$deps_file"
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
# Change-based selection (#464). With neither --changed-from nor a non-empty
# MUTANT_DRIVER_SINCE, sel_mode never leaves 0 and this whole block is a no-op — $sel, and this
# script's output, stay exactly what they were before #464.
sel_mode=0
changed=()

if [ -n "$changed_from" ]; then
  sel_mode=1
  while IFS= read -r cf_line || [ -n "$cf_line" ]; do
    cf_line="${cf_line%$'\r'}"
    [ -n "$cf_line" ] && changed+=("$cf_line")
  done < "$changed_from"
elif [ -n "${MUTANT_DRIVER_SINCE:-}" ]; then
  since="$MUTANT_DRIVER_SINCE"
  case "$since" in
    -*)
      # A leading '-' never reaches git's argv as an option (e.g. "--output=...") — this value is
      # simply unusable, full stop.
      echo "== mutant-driver: full run (reason: unusable base $since) =="
      ;;
    *)
      if since_diff="$(git -C "$root" diff --no-renames --name-only "$since" HEAD -- 2>/dev/null)"; then
        sel_mode=1
        while IFS= read -r sd_line; do
          [ -n "$sd_line" ] && changed+=("$sd_line")
        done <<<"$since_diff"
      else
        echo "== mutant-driver: full run (reason: unusable base $since) =="
      fi
      ;;
  esac
fi

# path_claimed PATH — true (rc 0) iff PATH equals some record's own target, suite, or relative
# registry file, or matches (unquoted `case`) a dep_pat that isn't a bare "*" — a bare "*" selects
# its suite but never claims a path (dev/mutants/suite-deps.txt's own header).
path_claimed() {
  local p="$1" pc_idx dp_idx dp
  for pc_idx in "${!rec_name[@]}"; do
    if [ "$p" = "${rec_target[$pc_idx]}" ] || [ "$p" = "${rec_suite[$pc_idx]}" ] \
      || [ "$p" = "${rec_file[$pc_idx]#"$root"/}" ]; then
      return 0
    fi
  done
  for dp_idx in "${!dep_pat[@]}"; do
    dp="${dep_pat[$dp_idx]}"
    [ "$dp" = "*" ] && continue
    case "$p" in
      $dp) return 0 ;;
    esac
  done
  return 1
}

# record_selected RIDX — true (rc 0) iff some changed[] path equals RIDX's own target, suite, or
# relative registry file; or, when RIDX's suite has one or more suite-deps.txt lines, some changed
# path matches one of them; or, when it has none (unmapped), changed[] is non-empty — the
# fail-safe default: an unmapped suite matches any change.
record_selected() {
  local ridx="$1" rs_target rs_suite rs_regfile rs_has_map=0 c_idx p dp_idx
  rs_target="${rec_target[$ridx]}"
  rs_suite="${rec_suite[$ridx]}"
  rs_regfile="${rec_file[$ridx]#"$root"/}"
  for c_idx in "${!changed[@]}"; do
    p="${changed[$c_idx]}"
    if [ "$p" = "$rs_target" ] || [ "$p" = "$rs_suite" ] || [ "$p" = "$rs_regfile" ]; then
      return 0
    fi
  done
  for dp_idx in "${!dep_suite[@]}"; do
    [ "${dep_suite[$dp_idx]}" = "$rs_suite" ] || continue
    rs_has_map=1
    for c_idx in "${!changed[@]}"; do
      p="${changed[$c_idx]}"
      case "$p" in
        ${dep_pat[$dp_idx]}) return 0 ;;
      esac
    done
  done
  if [ "$rs_has_map" -eq 0 ] && [ "${#changed[@]}" -gt 0 ]; then
    return 0
  fi
  return 1
}

if [ "$sel_mode" -eq 1 ]; then
  full_reason=""
  if [ "${#changed[@]}" -gt 0 ]; then
    for chk_idx in "${!changed[@]}"; do
      p="${changed[$chk_idx]}"
      if [ "$p" = "dev/mutant-driver.sh" ]; then
        full_reason="driver changed"
        break
      fi
      case "$p" in
        bin/*|hooks/*|templates/*|agents/*|skills/*|dev/*)
          path_claimed "$p" || { full_reason="unclaimed path $p"; break; }
          ;;
      esac
    done
  fi
  if [ -n "$full_reason" ]; then
    echo "== mutant-driver: full run (reason: $full_reason) =="
  else
    new_sel=()
    for ridx in "${sel[@]}"; do
      record_selected "$ridx" && new_sel+=("$ridx")
    done
    echo "== mutant-driver: selected ${#new_sel[@]} of ${#sel[@]} records =="
    if [ "${#new_sel[@]}" -eq 0 ]; then
      echo
      echo "== summary: 0 pass, 0 fail =="
      exit 0
    fi
    sel=("${new_sel[@]}")
  fi
fi

# ---------------------------------------------------------------------------------------------
# Sharding. With no shard spec this block is a no-op. Otherwise it partitions the set left after
# the name filter and change-based selection: records are grouped by (suite, filter) pair in order
# of first appearance, and each whole group goes to the shard with the fewest records so far
# (strict < keeps ties on the lowest index). Indexed arrays only — bash 3.2 has no declare -A.
if [ -n "$shard_n" ]; then
  sh_gsuite=(); sh_gfilter=(); sh_gcount=(); sh_rgroup=()
  for sh_pos in "${!sel[@]}"; do
    sh_ridx="${sel[$sh_pos]}"
    sh_found=-1
    for sh_g in "${!sh_gsuite[@]}"; do
      if [ "${sh_gsuite[$sh_g]}" = "${rec_suite[$sh_ridx]}" ] && [ "${sh_gfilter[$sh_g]}" = "${rec_filter[$sh_ridx]}" ]; then
        sh_found="$sh_g"
        break
      fi
    done
    if [ "$sh_found" -lt 0 ]; then
      sh_gsuite+=("${rec_suite[$sh_ridx]}")
      sh_gfilter+=("${rec_filter[$sh_ridx]}")
      sh_gcount+=(0)
      sh_found=$(( ${#sh_gsuite[@]} - 1 ))
    fi
    sh_gcount[$sh_found]=$(( ${sh_gcount[$sh_found]} + 1 ))
    sh_rgroup[$sh_pos]="$sh_found"
  done
  sh_load=()
  sh_k=1
  while [ "$sh_k" -le "$shard_n" ]; do
    sh_load[$sh_k]=0
    sh_k=$((sh_k+1))
  done
  sh_gshard=()
  for sh_g in "${!sh_gsuite[@]}"; do
    sh_best=1
    sh_k=2
    while [ "$sh_k" -le "$shard_n" ]; do
      if [ "${sh_load[$sh_k]}" -lt "${sh_load[$sh_best]}" ]; then
        sh_best="$sh_k"
      fi
      sh_k=$((sh_k+1))
    done
    sh_gshard[$sh_g]="$sh_best"
    sh_load[$sh_best]=$(( ${sh_load[$sh_best]} + ${sh_gcount[$sh_g]} ))
  done
  shard_sel=()
  for sh_pos in "${!sel[@]}"; do
    if [ "${sh_gshard[${sh_rgroup[$sh_pos]}]}" = "$shard_i" ]; then
      shard_sel+=("${sel[$sh_pos]}")
    fi
  done
  echo "== mutant-driver: shard ${shard_i}/${shard_n}: ${#shard_sel[@]} of ${#sel[@]} records =="
  if [ "${#shard_sel[@]}" = 0 ]; then
    echo
    echo "== summary: 0 pass, 0 fail =="
    exit 0
  fi
  sel=("${shard_sel[@]}")
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
# Rolling-pool scheduler. case_no/job_name are global and grow across BOTH phases below. Every job
# (baseline or mutant) is enqueued into the job_* arrays first (indexed 1..n_jobs, in declared
# order); run_pool then launches and reaps them through a pool of at most $jobs concurrent
# children, printing results back in DECLARED order via next_print regardless of completion order.
#
# job_kind[idx]   "baseline" or "mutant"
# job_a[idx]      baseline: suite path        mutant: index into rec_*[] (ridx)
# job_b[idx]      baseline: filter            mutant: "" (unused)
# job_dep[idx]    mutant: the case_no of its own (suite, filter) baseline job; "" for a baseline
#                 (a baseline has no dependency: it is always ready)
# job_state[idx]  "pending" -> "running" -> "done"
case_no=0
job_name=()
job_kind=()
job_a=()
job_b=()
job_dep=()
job_state=()

n_jobs=0
next_scan=1
next_print=1
running=0
reaped=0
slot_idx=()
slot_pid=()

# collect_job IDX — prints IDX's PASS/FAIL line (and reads its .out for any reason/expected lines),
# and tallies it into $pass/$fail. Called only from print_ready, and only once IDX's job_state is
# "done" — i.e. only after reap_slots has already wait'ed on its child, so its .verdict file (the
# child's LAST write, see dispatch()) is always complete by the time this reads it, never seen
# mid-write.
collect_job() {
  local idx="$1" v out
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
}

# job_ready IDX — true (rc 0) iff IDX has no dependency, or its dependency's own job_state is
# "done". A baseline's job_dep is always "", so a baseline is always ready; a mutant is ready only
# once its own baseline job has finished (its baseline may have passed or failed — a red baseline
# is handled by run_mutant_job's own baseline-red short-circuit, not by readiness).
job_ready() {
  local idx="$1" dep="${job_dep[$1]}"
  [ -n "$dep" ] || return 0
  # (dev/mutants/mutant-driver-tests.json's drv-nodep self-mutant replaces this test with an
  # unconditional true — see dev/mutant-driver-tests.sh's own case_baseline_gates_dependents
  # comment.)
  [ "${job_state[$dep]}" = "done" ]
}

# launch_job IDX SLOT — sets case_no="$IDX" before forking, so run_baseline_job/run_mutant_job
# (which both read the global $case_no for their own scratch-copy name and .basestatus path) name
# their files after this job's own index, not whatever case_no last happened to be. A mutant's own
# baseline status is computed here, at launch time, from basestatus_for (below) — never cached at
# enqueue time, so it always reflects the baseline's actual outcome.
launch_job() {
  local idx="$1" slot="$2" bstatus
  case_no="$idx"
  if [ "${job_kind[$idx]}" = "baseline" ]; then
    dispatch baseline "$idx" "${job_name[$idx]}" "${job_a[$idx]}" "${job_b[$idx]}" &
  else
    bstatus="$(basestatus_for "${rec_suite[${job_a[$idx]}]}" "${rec_filter[${job_a[$idx]}]}")"
    dispatch mutant "$idx" "${job_name[$idx]}" "${job_a[$idx]}" "$bstatus" &
  fi
  slot_pid[$slot]="$!"
  slot_idx[$slot]="$idx"
  job_state[$idx]="running"
  running=$((running+1))
}

# fill_slots — for each free slot, advances next_scan past every no-longer-pending job (it never
# needs revisiting), then scans forward from next_scan for the first job that is both pending and
# job_ready, and launches it into that slot. Leaves a slot free when no job is ready yet (a later
# pass may find one once a dependency finishes).
# (dev/mutants/mutant-driver-tests.json's drv-barrier self-mutant inserts a guard right after the
# opening brace below that refuses to launch anything while any job is still running — that is
# barrier-wave behavior — see dev/mutant-driver-tests.sh's own case_pool_refill comment.)
fill_slots() {
  local s idx found
  s=0
  while [ "$s" -lt "$jobs" ]; do
    if [ -z "${slot_idx[$s]:-}" ]; then
      while [ "$next_scan" -le "$n_jobs" ] && [ "${job_state[$next_scan]}" != "pending" ]; do
        next_scan=$((next_scan+1))
      done
      found=""
      idx="$next_scan"
      while [ "$idx" -le "$n_jobs" ]; do
        if [ "${job_state[$idx]}" = "pending" ] && job_ready "$idx"; then
          found="$idx"
          break
        fi
        idx=$((idx+1))
      done
      [ -n "$found" ] && launch_job "$found" "$s"
    fi
    s=$((s+1))
  done
}

# reap_slots — a busy slot is finished once its .verdict file exists (the child's last write) or
# its pid is no longer alive (kill -0 fails — a dead child with no verdict). Either way, wait reaps
# it (returns at once; the process has already exited or is about to), the slot frees up, and
# job_state flips to "done" so fill_slots and print_ready can both see it. Sets $reaped so run_pool
# knows whether this pass made progress.
reap_slots() {
  local s idx pid
  reaped=0
  s=0
  while [ "$s" -lt "$jobs" ]; do
    idx="${slot_idx[$s]:-}"
    if [ -n "$idx" ]; then
      pid="${slot_pid[$s]}"
      if [ -e "$resdir/$idx.verdict" ] || ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null
        # (dev/mutants/mutant-driver-tests.json's drv-order self-mutant appends a call to
        # collect_job right here, printing each job as soon as IT is reaped — completion order —
        # instead of leaving printing to print_ready's own declared-order walk below. See
        # dev/mutant-driver-tests.sh's own case_declared_order comment.)
        job_state[$idx]=done
        slot_idx[$s]=""
        slot_pid[$s]=""
        running=$((running-1))
        reaped=1
      fi
    fi
    s=$((s+1))
  done
}

# print_ready — collects and prints every already-done job starting at next_print, in declared
# order, stopping at the first index that isn't done yet (or past the end).
print_ready() {
  while [ "$next_print" -le "$n_jobs" ] && [ "${job_state[$next_print]}" = "done" ]; do
    # (dev/mutants/mutant-driver-tests.json's drv-order self-mutant replaces this call with a
    # no-op, paired with the reap_slots edit above, so printing happens once, at reap time, in
    # completion order.)
    collect_job "$next_print"
    next_print=$((next_print+1))
  done
}

# run_pool — drives the pool until every job has been printed. No explicit deadlock guard is
# needed: a baseline is always ready and every baseline is declared before its own dependents (see
# the Phase 1/Phase 2 enqueue order below), so every dependency a job could ever wait on is always
# already enqueued and eligible to be picked up by fill_slots.
run_pool() {
  while [ "$next_print" -le "$n_jobs" ]; do
    fill_slots
    reap_slots
    print_ready
    [ "$reaped" -eq 0 ] && sleep 0.1
  done
}

# run_baseline_job SUITE FILTER — prints the baseline's PASS/FAIL line (and an optional reason
# line) to stdout, writes "clean"/"red" to $resdir/$case_no.basestatus (case_no is set to this
# job's own index by launch_job, above, before it forks — run_mutant_job below reads the same
# global the same way), and returns 0 (pass) or 1 (fail).
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
# first appearance.
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

# Enqueue one baseline job per distinct pair above, in the same first-appearance order. Nothing is
# dispatched here — run_pool (below basestatus_for) does all the actual scheduling.
for bk in "${!base_suite[@]}"; do
  case_no=$((case_no+1))
  job_name[$case_no]="baseline:${base_suite[$bk]}:${base_filter[$bk]}"
  base_idx+=("$case_no")
  job_kind[$case_no]="baseline"
  job_a[$case_no]="${base_suite[$bk]}"
  job_b[$case_no]="${base_filter[$bk]}"
  job_dep[$case_no]=""
  job_state[$case_no]="pending"
done

# basestatus_for SUITE FILTER — prints "clean"/"red" for the matching baseline, "red" if somehow
# absent (fail closed).
basestatus_for() {
  local s="$1" ft="$2" bk
  for bk in "${!base_suite[@]}"; do
    if [ "${base_suite[$bk]}" = "$s" ] && [ "${base_filter[$bk]}" = "$ft" ]; then
      # (dev/mutants/mutant-driver-tests.json's drv-basefallback self-mutant changes this fallback
      # to "clean" instead — see dev/mutant-driver-tests.sh's own case_baseline_dies comment.)
      cat "$resdir/${base_idx[$bk]}.basestatus" 2>/dev/null || echo "red"
      return
    fi
  done
  echo "red"
}

# ---------------------------------------------------------------------------------------------
# Phase 2: enqueue every selected mutant, in registry-declared order, recording each one's own
# baseline job (found by the same (suite, filter) lookup basestatus_for uses above) as its
# job_dep — the pool never starts a mutant before that job_dep's own job_state is "done". Nothing
# is dispatched here either; run_pool (below) does all the actual scheduling.
for ridx in "${sel[@]}"; do
  case_no=$((case_no+1))
  job_name[$case_no]="${rec_name[$ridx]}"
  job_kind[$case_no]="mutant"
  job_a[$case_no]="$ridx"
  job_b[$case_no]=""
  job_dep[$case_no]=""
  for bk in "${!base_suite[@]}"; do
    if [ "${base_suite[$bk]}" = "${rec_suite[$ridx]}" ] && [ "${base_filter[$bk]}" = "${rec_filter[$ridx]}" ]; then
      job_dep[$case_no]="${base_idx[$bk]}"
      break
    fi
  done
  job_state[$case_no]="pending"
done

n_jobs="$case_no"
run_pool

echo
echo "== summary: $pass pass, $fail fail =="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
