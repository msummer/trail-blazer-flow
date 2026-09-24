#!/usr/bin/env bash
#
# mutant-driver-tests.sh — negative-test harness for dev/mutant-driver.sh (#359).
#
# Usage: bash dev/mutant-driver-tests.sh [name-filter]
#   name-filter  run only the cases whose name contains this substring (a non-zero exit if the
#                filter matches nothing).
#
# Contract, one row per case: build a throwaway synthetic "repo" under mktemp -d — a copy of the
# PRISTINE dev/mutant-driver.sh (from this checkout) plus small synthetic target/suite files and a
# registry pointed at by MUTANT_DRIVER_REGISTRY_DIR (ADVISORY Q2) — run the REAL driver against it,
# and assert its stdout/stderr/exit code. Every nested driver invocation below passes --serial (or
# a small fixed -j) so this file's own run never fans out unbounded: when the OUTER driver runs
# THIS file as a suite against dev/mutant-driver.sh's own self-mutants
# (dev/mutants/mutant-driver-tests.json), the outer driver's own concurrency ALREADY multiplies
# against however many mutants run at once, so an inner driver invocation that also auto-detected
# cores would compound that fan-out. Standard grammar: "  PASS  <name> — <desc>" /
# "  FAIL  <name> — <desc>" per case, a "== summary: N pass, M fail ==" footer, exit 0 iff nothing
# failed.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"

if ! command -v jq >/dev/null 2>&1; then
  echo "  FAIL  jq not installed — required by dev/mutant-driver.sh itself"
  exit 1
fi

tmpbase="$(mktemp -d)"
cleanup() {
  if [ -n "$tmpbase" ] && [ -d "$tmpbase" ]; then
    rm -rf "$tmpbase"
  fi
}
trap cleanup EXIT

pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }

# needle_required NAME NEEDLE (#262) — an empty NEEDLE degenerates grep -qF -- "" into an
# unconditional match, so treat it as a harness bug IN THE CASE, not a fact about the driver.
needle_required() {
  if [ -z "$2" ]; then
    __ok=0
    __why="${__why}$1: empty needle (harness bug)\n"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------------------------
# Fixture builders. Each returns (via stdout) the path to a fresh synthetic "repo" root containing
# dev/mutant-driver.sh (a byte-identical copy of THIS checkout's pristine, tracked script — never a
# perturbed one), so that when it runs, its own $root resolves to the fixture root, not this repo.

fresh_driver_root() {
  local dst="$tmpbase/$1"
  mkdir -p "$dst/dev"
  cp "$root/dev/mutant-driver.sh" "$dst/dev/mutant-driver.sh"
  printf '%s' "$dst"
}

# write_generic_fixture DIR — a target (lib.sh, executable) with three independent "on" tags, and
# a suite (dev/fixture-suite.sh) with one case per tag, passing iff that tag reads "on". Used by
# every case that just needs a clean baseline plus a controllable failing set.
write_generic_fixture() {
  local dir="$1"
  cat > "$dir/lib.sh" <<'EOF'
#!/usr/bin/env bash
TAG_ALPHA="on"
TAG_BETA="on"
TAG_GAMMA="on"
EOF
  chmod +x "$dir/lib.sh"
  mkdir -p "$dir/dev"
  cat > "$dir/dev/fixture-suite.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
froot="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"
pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }
check_tag() {
  local name="$1" tag="$2"
  case "$name" in *"$filter"*) : ;; *) return ;; esac
  if grep -qF -- "${tag}=\"on\"" "$froot/lib.sh"; then
    case_ok "$name" "$tag reads on"
  else
    case_bad "$name" "$tag does not read on"
  fi
}
check_tag "case-alpha" "TAG_ALPHA"
check_tag "case-beta"  "TAG_BETA"
check_tag "case-gamma" "TAG_GAMMA"
echo
echo "== summary: $pass pass, $fail fail =="
if [ "$fail" -gt 0 ]; then exit 1; fi
exit 0
EOF
  chmod +x "$dir/dev/fixture-suite.sh"
}

# write_unsorted_fixture DIR — a target with two tags and a suite that runs "alpha" before "Zeta"
# (its own execution/print order), used by case_unsorted_set_order to discriminate true
# LC_ALL=C sorting from mere pass-through: under the C locale, uppercase 'Z' (0x5A) sorts before
# lowercase 'a' (0x61), so the correctly-sorted failing set is "Zeta,alpha" — the REVERSE of the
# suite's own print order — while a driver that joined the observed set without sorting (or with a
# locale-dependent sort) would print "alpha,Zeta" instead.
write_unsorted_fixture() {
  local dir="$1"
  cat > "$dir/lib.sh" <<'EOF'
#!/usr/bin/env bash
TAG_ALPHA="on"
TAG_ZETA="on"
EOF
  chmod +x "$dir/lib.sh"
  mkdir -p "$dir/dev"
  cat > "$dir/dev/unsorted-suite.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
froot="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"
pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }
check_tag() {
  local name="$1" tag="$2"
  case "$name" in *"$filter"*) : ;; *) return ;; esac
  if grep -qF -- "${tag}=\"on\"" "$froot/lib.sh"; then
    case_ok "$name" "$tag reads on"
  else
    case_bad "$name" "$tag does not read on"
  fi
}
check_tag "alpha" "TAG_ALPHA"
check_tag "Zeta" "TAG_ZETA"
echo
echo "== summary: $pass pass, $fail fail =="
if [ "$fail" -gt 0 ]; then exit 1; fi
exit 0
EOF
  chmod +x "$dir/dev/unsorted-suite.sh"
}

# write_dup_fixture DIR — a target with a DUPLICATED line (recipe-multi-match: an edit's "from"
# text must match this line exactly twice), reusing the generic suite's case-alpha (matched against
# a fourth, unrelated tag so the duplicate line itself never changes any case's own verdict).
write_dup_fixture() {
  local dir="$1"
  write_generic_fixture "$dir"
  cat >> "$dir/lib.sh" <<'EOF'
DUP_LINE="x"
DUP_LINE="x"
EOF
}

# write_multiedit_fixture DIR — a target with one STEP value and a suite with one case, passing
# iff STEP is "zero". Two sequential edits (zero -> one -> two) prove edits apply IN ORDER against
# each other's own output, not all against the pristine original: an edit applied against the
# pristine text would never find "STEP=\"one\"" (the intermediate state only the first edit
# produces) and would FAIL with a zero-match reason instead of flipping the case cleanly.
write_multiedit_fixture() {
  local dir="$1"
  cat > "$dir/step.sh" <<'EOF'
STEP="zero"
EOF
  mkdir -p "$dir/dev"
  cat > "$dir/dev/step-suite.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
froot="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"
pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }
case "case-step" in
  *"$filter"*)
    if grep -qF -- 'STEP="zero"' "$froot/step.sh"; then
      case_ok "case-step" "STEP is zero"
    else
      case_bad "case-step" "STEP is not zero"
    fi
    ;;
esac
echo
echo "== summary: $pass pass, $fail fail =="
if [ "$fail" -gt 0 ]; then exit 1; fi
exit 0
EOF
  chmod +x "$dir/dev/step-suite.sh"
}

# write_multiline_fixture DIR — a target with a two-line block and a suite with one case, passing
# iff BOTH lines read their original text. A single multi-line edit (embedded newline in both
# "from" and "to") replaces the whole block at once.
write_multiline_fixture() {
  local dir="$1"
  cat > "$dir/block.txt" <<'EOF'
BLOCK_START
line-one
line-two
BLOCK_END
EOF
  mkdir -p "$dir/dev"
  cat > "$dir/dev/block-suite.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
froot="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"
pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }
case "case-multiline" in
  *"$filter"*)
    if grep -qF -- 'line-one' "$froot/block.txt" && grep -qF -- 'line-two' "$froot/block.txt"; then
      case_ok "case-multiline" "both original lines present"
    else
      case_bad "case-multiline" "original lines missing"
    fi
    ;;
esac
echo
echo "== summary: $pass pass, $fail fail =="
if [ "$fail" -gt 0 ]; then exit 1; fi
exit 0
EOF
  chmod +x "$dir/dev/block-suite.sh"
}

# write_alwaysfail_fixture DIR — a target (irrelevant content) and a suite with one case that
# fails UNCONDITIONALLY, so the very baseline run (no edits at all) is already red.
write_alwaysfail_fixture() {
  local dir="$1"
  printf 'X="y"\n' > "$dir/never.sh"
  mkdir -p "$dir/dev"
  cat > "$dir/dev/alwaysfail-suite.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
filter="${1:-}"
pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }
case "case-always-fail" in
  *"$filter"*) case_bad "case-always-fail" "fails unconditionally" ;;
esac
echo
echo "== summary: $pass pass, $fail fail =="
if [ "$fail" -gt 0 ]; then exit 1; fi
exit 0
EOF
  chmod +x "$dir/dev/alwaysfail-suite.sh"
}

# write_flaky_fixture DIR — a target holding one STATE value and a suite whose OWN output shape
# depends on that value: "normal" prints one case (passing) plus a correct footer; "omit-footer"
# prints the same case line but no footer at all; "bad-total" prints the case line plus a footer
# whose own numbers disagree with the number of case lines actually printed. A baseline (STATE
# stays "normal") is therefore always clean; only a mutant that edits STATE reaches the broken
# shapes.
write_flaky_fixture() {
  local dir="$1"
  printf 'STATE="normal"\n' > "$dir/state.sh"
  mkdir -p "$dir/dev"
  cat > "$dir/dev/flaky-suite.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
froot="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"
state="normal"
if grep -qF -- 'STATE="omit-footer"' "$froot/state.sh"; then
  state="omit-footer"
elif grep -qF -- 'STATE="bad-total"' "$froot/state.sh"; then
  state="bad-total"
fi
pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }
case "case-x" in
  *"$filter"*) case_ok "case-x" "state is $state" ;;
esac
case "$state" in
  omit-footer)
    exit 0
    ;;
  bad-total)
    echo "== summary: 9 pass, 9 fail =="
    exit 0
    ;;
  *)
    echo
    echo "== summary: $pass pass, $fail fail =="
    if [ "$fail" -gt 0 ]; then exit 1; fi
    exit 0
    ;;
esac
EOF
  chmod +x "$dir/dev/flaky-suite.sh"
}

# write_registry DIR JSON — writes JSON (via stdin) as the fixture's one registry file, pointed at
# by MUTANT_DRIVER_REGISTRY_DIR in run_driver below.
write_registry() {
  local dir="$1"
  mkdir -p "$dir/mutants"
  cat > "$dir/mutants/reg.json"
}

# run_driver DIR [ARGS...] — invokes DIR's own copy of the driver (never this checkout's), with
# MUTANT_DRIVER_REGISTRY_DIR pointed at DIR/mutants (ADVISORY Q2). Sets $driver_out (combined
# stdout+stderr) and $driver_rc. Deliberately not run via "$(...)" for the exit-code capture (same
# reason dev/selfcheck-tests.sh's run_gate documents) — called as a plain statement, globals read
# after.
driver_out=""
driver_rc=0
run_driver() {
  local dir="$1"
  shift
  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" bash "$dir/dev/mutant-driver.sh" "$@" 2>&1)"
  driver_rc=$?
}

# ---------------------------------------------------------------------------------------------
__ok=1
__why=""

expect_out() {
  needle_required expect_out "$1" || return 0
  grep -qF -- "$1" <<<"$driver_out" || { __ok=0; __why="${__why}missing output: $1\n"; }
}
expect_not_out() {
  needle_required expect_not_out "$1" || return 0
  grep -qF -- "$1" <<<"$driver_out" && { __ok=0; __why="${__why}unexpected output: $1\n"; }
}
expect_rc() {
  [ "$driver_rc" -eq "$1" ] || { __ok=0; __why="${__why}rc: expected $1, got $driver_rc\n"; }
}

# ---------------------------------------------------------------------------------------------
# Cases.

case_pass_exact() {
  local dir; dir="$(fresh_driver_root pass-exact)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-beta","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 0
  expect_out "PASS m-beta 3 case-beta"
  expect_out "PASS baseline:dev/fixture-suite.sh: 3 -"
  expect_out "== summary: 2 pass, 0 fail =="
}

case_fail_extra_joiner() {
  local dir; dir="$(fresh_driver_root fail-extra-joiner)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-two","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""},
            {"from":"TAG_GAMMA=\"on\"","to":"TAG_GAMMA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 1
  expect_out "FAIL m-two 3 case-beta,case-gamma"
  expect_out "    expected case-beta"
}

case_fail_missing_member() {
  local dir; dir="$(fresh_driver_root fail-missing-member)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-one","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta","case-gamma"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 1
  expect_out "FAIL m-one 3 case-beta"
  expect_out "    expected case-beta,case-gamma"
}

# mutant:drv-setcmp — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Replaces the driver's exact-set compare with a count-only compare, so
# this same-cardinality/different-member case would wrongly PASS.
case_fail_swapped_member() {
  local dir; dir="$(fresh_driver_root fail-swapped-member)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-swap","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-alpha"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 1
  expect_out "FAIL m-swap 3 case-beta"
  expect_out "    expected case-alpha"
}

case_recipe_zero_match() {
  local dir; dir="$(fresh_driver_root recipe-zero-match)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-zero","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_DOES_NOT_EXIST","to":"x"}],
   "expect_fail":["case-alpha"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 1
  expect_out "FAIL m-zero - -"
  expect_out "    reason edit 0 matched 0 time(s) (expected exactly 1)"
}

# mutant:drv-once — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Widens the driver's own exactly-once edit-match check to accept one
# OR MORE matches, so this two-match case would wrongly apply the edit instead of FAILing.
case_recipe_multi_match() {
  local dir; dir="$(fresh_driver_root recipe-multi-match)"
  write_dup_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-dup","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"DUP_LINE=\"x\"","to":"DUP_LINE=\"y\""}],
   "expect_fail":["case-alpha"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 1
  expect_out "FAIL m-dup - -"
  expect_out "    reason edit 0 matched 2 time(s) (expected exactly 1)"
}

# mutant:drv-nobreak — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Deletes the driver's own break after a failed edit, so the loop keeps
# running against the now-corrupted scratch copy (jq's own "null" for the missing .content field)
# and the reported FAIL reason names the LAST failing edit index instead of the FIRST.
case_recipe_first_edit_fails() {
  local dir; dir="$(fresh_driver_root recipe-first-edit-fails)"
  write_multiedit_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-firstfails","target":"step.sh","suite":"dev/step-suite.sh","filter":"",
   "edits":[{"from":"STEP=\"nonexistent\"","to":"STEP=\"other\""},
            {"from":"STEP=\"zero\"","to":"STEP=\"one\""}],
   "expect_fail":["case-step"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 1
  expect_out "FAIL m-firstfails - -"
  expect_out "    reason edit 0 matched 0 time(s) (expected exactly 1)"
  expect_not_out "edit 1"
}

case_multi_edit_sequential() {
  local dir; dir="$(fresh_driver_root multi-edit-sequential)"
  write_multiedit_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-step","target":"step.sh","suite":"dev/step-suite.sh","filter":"",
   "edits":[{"from":"STEP=\"zero\"","to":"STEP=\"one\""},
            {"from":"STEP=\"one\"","to":"STEP=\"two\""}],
   "expect_fail":["case-step"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 0
  expect_out "PASS m-step 1 case-step"
}

case_byte_exact_multiline() {
  local dir; dir="$(fresh_driver_root byte-exact-multiline)"
  write_multiline_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-block","target":"block.txt","suite":"dev/block-suite.sh","filter":"",
   "edits":[{"from":"line-one\nline-two","to":"line-A\nline-B"}],
   "expect_fail":["case-multiline"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 0
  expect_out "PASS m-block 1 case-multiline"
}

# mutant:drv-mv — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Rewrites the driver's own write_target to write through a temp file
# and mv it over the target, dropping the temp file's own non-executable mode onto this fixture's
# executable target — this case's own PASS (and its exec-bit-lost absence) would flip to FAIL.
case_exec_bit_preserved() {
  local dir; dir="$(fresh_driver_root exec-bit-preserved)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-exec","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 0
  expect_out "PASS m-exec 3 case-beta"
  expect_not_out "exec-bit-lost"
}

case_tracked_tree_untouched() {
  local dir; dir="$(fresh_driver_root tracked-tree-untouched)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-beta","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  # A name-only "find | sort" listing would still be identical if a driver bug edited
  # dev/fixture-suite.sh's tracked "TAG_BETA" line IN PLACE (e.g. a mutated run_mutant_job that
  # operates on the fixture root itself instead of a fresh_copy scratch copy) — same file names,
  # different bytes. Fold each file's own cksum into the comparison so a same-name, changed-content
  # tree is caught too, not just an added/removed/renamed file.
  local before after
  before="$(find "$dir" -type f | LC_ALL=C sort | xargs cksum)"
  run_driver "$dir" --serial
  after="$(find "$dir" -type f | LC_ALL=C sort | xargs cksum)"
  expect_rc 0
  if [ "$before" != "$after" ]; then
    __ok=0
    __why="${__why}fixture tree listing changed:\nbefore:\n$before\nafter:\n$after\n"
  fi
}

case_suite_runs_from_copy() {
  local dir; dir="$(fresh_driver_root suite-runs-from-copy)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-beta","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  local decoy_dir sentinel
  decoy_dir="$tmpbase/decoy-bin-$$"
  mkdir -p "$decoy_dir"
  sentinel="$tmpbase/decoy-ran"
  cat > "$decoy_dir/fixture-suite.sh" <<EOF
#!/usr/bin/env bash
touch "$sentinel"
echo "  PASS  case-alpha — decoy"
echo "  PASS  case-beta — decoy"
echo "  PASS  case-gamma — decoy"
echo
echo "== summary: 3 pass, 0 fail =="
EOF
  chmod +x "$decoy_dir/fixture-suite.sh"
  rm -f "$sentinel"
  driver_out="$(PATH="$decoy_dir:$PATH" MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" bash "$dir/dev/mutant-driver.sh" --serial 2>&1)"
  driver_rc=$?
  expect_rc 0
  expect_out "PASS m-beta 3 case-beta"
  if [ -e "$sentinel" ]; then
    __ok=0
    __why="${__why}the decoy on \$PATH was executed — the driver must invoke the copy's own suite by full path, never a bare name\n"
  fi
}

# mutant:drv-noverdict — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Rewrites the driver's own no-verdict catch-all to count a missing
# verdict file as a silent pass, so this dead-child case's expected FAIL/reason lines would
# disappear.
case_child_dies() {
  local dir; dir="$(fresh_driver_root child-dies)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-beta","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_FAULT="die:m-beta" bash "$dir/dev/mutant-driver.sh" --serial 2>&1)"
  driver_rc=$?
  expect_rc 1
  expect_out "FAIL m-beta - -"
  expect_out "    reason no-verdict"
}

# mutant:drv-order — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Rewrites the driver's own flush_wave to collect results by completion
# (mtime) order instead of declared order, so a slow: FAULT-delayed first-declared mutant would
# print out of sequence.
case_declared_order() {
  local dir; dir="$(fresh_driver_root declared-order)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-first","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]},
  {"name":"m-second","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_GAMMA=\"on\"","to":"TAG_GAMMA=\"off\""}],
   "expect_fail":["case-gamma"]}
]}
EOF
  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_FAULT="slow:m-first" bash "$dir/dev/mutant-driver.sh" -j 2 2>&1)"
  driver_rc=$?
  expect_rc 0
  local seq
  seq="$(sed -nE 's/^(PASS|FAIL) ([^ ]+) .*/\2/p' <<<"$driver_out" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  local expected_seq="baseline:dev/fixture-suite.sh: m-first m-second"
  if [ "$seq" != "$expected_seq" ]; then
    __ok=0
    __why="${__why}declared-order sequence: expected '$expected_seq', got '$seq'\n"
  fi
}

case_baseline_red() {
  local dir; dir="$(fresh_driver_root baseline-red)"
  write_alwaysfail_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-doomed","target":"never.sh","suite":"dev/alwaysfail-suite.sh","filter":"",
   "edits":[{"from":"X=\"y\"","to":"X=\"z\""}],
   "expect_fail":["case-always-fail"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 1
  expect_out "FAIL baseline:dev/alwaysfail-suite.sh: 1 case-always-fail"
  expect_out "FAIL m-doomed - -"
  expect_out "    reason baseline-red"
}

case_unknown_case() {
  local dir; dir="$(fresh_driver_root unknown-case)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-ghost","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-nonexistent"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 1
  expect_out "FAIL m-ghost 3 -"
  expect_out "    reason unknown-case:case-nonexistent"
}

# mutant:drv-unknownexact — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Rewrites the driver's own unknown-case lookup from a whole-line match
# (grep -qxF) to a substring match (grep -qF), so an expect_fail name that is only a strict prefix
# of a real case name (case-alph against the generic fixture's case-alpha) would be wrongly treated
# as known, falling through to a plain set-mismatch report instead of reason unknown-case:case-alph.
case_unknown_case_prefix() {
  local dir; dir="$(fresh_driver_root unknown-case-prefix)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-ghost2","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-alph"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 1
  expect_out "FAIL m-ghost2 3 -"
  expect_out "    reason unknown-case:case-alph"
  expect_not_out "    expected"
}

# mutant:drv-total — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Deletes the driver's own no-footer guard, so this footer-less suite
# run would be silently treated as zero-total instead of FAILing with reason no-summary.
case_suite_no_summary() {
  local dir; dir="$(fresh_driver_root suite-no-summary)"
  write_flaky_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-nofoot","target":"state.sh","suite":"dev/flaky-suite.sh","filter":"",
   "edits":[{"from":"STATE=\"normal\"","to":"STATE=\"omit-footer\""}],
   "expect_fail":["case-x"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 1
  expect_out "FAIL m-nofoot - -"
  expect_out "    reason no-summary"
}

case_total_mismatch() {
  local dir; dir="$(fresh_driver_root total-mismatch)"
  write_flaky_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-badtotal","target":"state.sh","suite":"dev/flaky-suite.sh","filter":"",
   "edits":[{"from":"STATE=\"normal\"","to":"STATE=\"bad-total\""}],
   "expect_fail":["case-x"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 1
  expect_out "FAIL m-badtotal - -"
  expect_out "    reason total-mismatch"
}

# ---------------------------------------------------------------------------------------------
# Sixteen registry-validation cases — one per validation rule in dev/mutant-driver.sh's
# load_registry_file, so every add_err message has a fixture that trips ONLY that rule (never one
# a different rule would already catch). Each fixture uses a suite that touches a sentinel file
# (outside the fixture root) so a case can prove no suite ever ran once the registry itself is
# rejected.

write_sentinel_fixture() {
  local dir="$1" sentinel="$2"
  write_generic_fixture "$dir"
  cat > "$dir/dev/fixture-suite.sh" <<EOF
#!/usr/bin/env bash
touch "$sentinel"
echo "  PASS  case-alpha — sentinel"
echo
echo "== summary: 1 pass, 0 fail =="
EOF
  chmod +x "$dir/dev/fixture-suite.sh"
}

assert_registry_rejected() {
  local sentinel="$1"
  expect_rc 2
  if [ -e "$sentinel" ]; then
    __ok=0
    __why="${__why}sentinel file exists — a suite ran despite the invalid registry\n"
  fi
}

case_reg_bad_name() {
  local dir; dir="$(fresh_driver_root reg-bad-name)"
  local sentinel="$tmpbase/sentinel-bad-name"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"-bad name!","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "does not match ^[A-Za-z0-9][A-Za-z0-9-]*\$"
  expect_not_out "duplicate mutant name"
}

case_reg_duplicate_name() {
  local dir; dir="$(fresh_driver_root reg-duplicate-name)"
  local sentinel="$tmpbase/sentinel-dup-name"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"dup-one","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]},
  {"name":"dup-one","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_GAMMA=\"on\"","to":"TAG_GAMMA=\"off\""}],
   "expect_fail":["case-gamma"]}
]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "duplicate mutant name"
  expect_not_out "does not match ^[A-Za-z0-9][A-Za-z0-9-]*\$"
}

# These two targets are chosen so they RESOLVE to a file that exists (once the shell/filesystem
# collapses the leading "//" or the "dev/../dev" hop), so the separate "does not exist" check
# (driver:205) can never be the one rejecting them — only the absolute-path check (driver:200) or
# the ".." check (driver:203) can. A target that also fails to exist (e.g. /etc/passwd or
# ../outside.sh, this suite's own prior fixtures) leaves both cases unable to discriminate their
# own named check from the exists check: deleting either `add_err` line alone would still be
# caught by the exists check, so the case would stay green regardless (#359 kickback round 2).
#
# mutant:drv-abs — recorded in dev/mutants/mutant-driver-tests.json; run bash dev/mutant-driver.sh.
# Widens the driver's own absolute-target case pattern so it never matches, so an absolute target
# would wrongly pass registry validation instead of FAILing with "must not be absolute".
case_reg_absolute_target() {
  local dir; dir="$(fresh_driver_root reg-absolute-target)"
  local sentinel="$tmpbase/sentinel-abs-target"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-abs","target":"/dev/fixture-suite.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "must not be absolute"
  expect_not_out "does not exist"
}

# mutant:drv-dotdot — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Widens the driver's own ".."-target case pattern so it never matches,
# so a target containing ".." would wrongly pass registry validation instead of FAILing with
# "must not contain '..'".
case_reg_dotdot_target() {
  local dir; dir="$(fresh_driver_root reg-dotdot-target)"
  local sentinel="$tmpbase/sentinel-dotdot-target"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-dotdot","target":"dev/../dev/fixture-suite.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "must not contain '..'"
  expect_not_out "does not exist"
}

# mutant:drv-suiteshape — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Disables the driver's own suite-path shape check (the
# ^dev/....\.sh$ regex) so an out-of-shape suite path that happens to resolve to a real file
# would wrongly pass registry validation instead of FAILing with "does not match".
#
# The suite file this fixture points at MUST exist on disk (a copy of the sentinel-touching
# suite, placed outside dev/) so only the shape check — never the separate "does not exist"
# check — can be the one rejecting this record (#359 kickback: a suite path that also fails to
# exist leaves both checks unable to discriminate, so deleting either add_err line alone would
# still be caught by the other, and the case would stay green regardless).
case_reg_bad_suite_path() {
  local dir; dir="$(fresh_driver_root reg-bad-suite-path)"
  local sentinel="$tmpbase/sentinel-bad-suite"
  rm -f "$sentinel"
  write_generic_fixture "$dir"
  mkdir -p "$dir/scripts"
  cat > "$dir/scripts/fixture-suite.sh" <<EOF
#!/usr/bin/env bash
touch "$sentinel"
echo "  PASS  case-alpha — sentinel"
echo
echo "== summary: 1 pass, 0 fail =="
EOF
  chmod +x "$dir/scripts/fixture-suite.sh"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-badsuite","target":"lib.sh","suite":"scripts/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "does not match"
  expect_not_out "does not exist"
}

case_reg_empty_edits() {
  local dir; dir="$(fresh_driver_root reg-empty-edits)"
  local sentinel="$tmpbase/sentinel-empty-edits"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-noedits","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "edits must be a non-empty array"
  expect_not_out "expect_fail must be a non-empty array"
}

case_reg_empty_expect_fail() {
  local dir; dir="$(fresh_driver_root reg-empty-expect-fail)"
  local sentinel="$tmpbase/sentinel-empty-expect"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-noexpect","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":[]}
]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "expect_fail must be a non-empty array"
  expect_not_out "edits must be a non-empty array"
}

# mutant:drv-toplevel — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Replaces the driver's own top-level-shape jq predicate with a literal
# "true" so the guard never trips, so a registry file whose top level isn't {"mutants": [...]}
# would wrongly pass registry validation instead of FAILing with "top-level shape must be".
case_reg_bad_top_level() {
  local dir; dir="$(fresh_driver_root reg-bad-top-level)"
  local sentinel="$tmpbase/sentinel-bad-top-level"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants": {}}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "top-level shape must be"
}

# mutant:drv-recobj — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Widens the driver's own record-is-an-object guard to "if false" so it
# never trips, so a non-object array element would wrongly pass registry validation instead of
# FAILing with "record is not an object".
case_reg_record_not_object() {
  local dir; dir="$(fresh_driver_root reg-record-not-object)"
  local sentinel="$tmpbase/sentinel-record-not-object"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants": ["not-an-object"]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "record is not an object"
}

# mutant:drv-keys — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Widens the driver's own exact-keys guard to "if false" so it never
# trips, so a record carrying an extra key would wrongly pass registry validation instead of
# FAILing with "must have exactly the keys".
case_reg_bad_keys() {
  local dir; dir="$(fresh_driver_root reg-bad-keys)"
  local sentinel="$tmpbase/sentinel-bad-keys"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-badkeys","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"],
   "extra":"nope"}
]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "must have exactly the keys"
}

# mutant:drv-targettype — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Widens the driver's own target-missing/not-a-string guard to "if
# false" so it never trips, so a null target would wrongly pass registry validation instead of
# FAILing with "target is missing or not a string".
case_reg_target_not_string() {
  local dir; dir="$(fresh_driver_root reg-target-not-string)"
  local sentinel="$tmpbase/sentinel-target-not-string"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-targetnull","target":null,"suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "target is missing or not a string"
}

# mutant:drv-targetexists — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Replaces the driver's own target-exists guard's "[ -f ... ] ||" with
# "true ||" so it never trips, so a repo-relative target that does not exist would wrongly pass
# registry validation instead of FAILing with "does not exist". This target is neither absolute
# nor ".."-carrying, so only the exists check (driver:205) can be the one rejecting it.
case_reg_missing_target() {
  local dir; dir="$(fresh_driver_root reg-missing-target)"
  local sentinel="$tmpbase/sentinel-missing-target"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-missingtarget","target":"dev/does-not-exist.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "does not exist"
}

# mutant:drv-suiteexists — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Widens the driver's own suite-exists guard to "elif false" so it never
# trips, so a suite path matching the ^dev/....\.sh$ shape but naming no real file would wrongly
# pass registry validation instead of FAILing with "does not exist".
case_reg_suite_missing() {
  local dir; dir="$(fresh_driver_root reg-suite-missing)"
  local sentinel="$tmpbase/sentinel-suite-missing"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-suitemissing","target":"lib.sh","suite":"dev/does-not-exist-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "suite 'dev/does-not-exist-suite.sh' does not exist"
}

# mutant:drv-filtertype — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Widens the driver's own filter-is-a-string guard to "if false" so it
# never trips, so a numeric filter would wrongly pass registry validation instead of FAILing with
# "filter must be a string".
case_reg_bad_filter_type() {
  local dir; dir="$(fresh_driver_root reg-bad-filter-type)"
  local sentinel="$tmpbase/sentinel-bad-filter-type"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-filtertype","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":5,
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "filter must be a string"
}

# mutant:drv-fromtype — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Widens the driver's own from-is-a-non-empty-string guard to "if false"
# so it never trips, so an empty "from" would wrongly pass registry validation instead of FAILing
# with "must be a non-empty string".
case_reg_empty_from() {
  local dir; dir="$(fresh_driver_root reg-empty-from)"
  local sentinel="$tmpbase/sentinel-empty-from"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-emptyfrom","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "must be a non-empty string"
}

# mutant:drv-fromto — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Widens the driver's own from-differs-from-to guard to "elif false" so
# it never trips, so an edit whose "from" equals its "to" would wrongly pass registry validation
# instead of FAILing with "must differ from".
case_reg_from_equals_to() {
  local dir; dir="$(fresh_driver_root reg-from-equals-to)"
  local sentinel="$tmpbase/sentinel-from-equals-to"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-fromequalsto","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"on\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "must differ from"
}

# ---------------------------------------------------------------------------------------------

case_filter_no_match() {
  local dir; dir="$(fresh_driver_root filter-no-match)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-beta","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial "zzz-nonexistent"
  expect_rc 1
  expect_out "no mutant name contains 'zzz-nonexistent'"
}

case_jobs_line() {
  local dir; dir="$(fresh_driver_root jobs-line)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-beta","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" -j 3
  expect_rc 0
  expect_out "== mutant-driver: 3 jobs =="

  run_driver "$dir" --serial
  expect_rc 0
  expect_out "== mutant-driver: 1 jobs =="

  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_JOBS=4 bash "$dir/dev/mutant-driver.sh" 2>&1)"
  driver_rc=$?
  expect_rc 0
  expect_out "== mutant-driver: 4 jobs =="

  # mutant:drv-precedence — recorded in dev/mutants/mutant-driver-tests.json; run
  # bash dev/mutant-driver.sh. Swaps the driver's own if/elif order so MUTANT_DRIVER_JOBS is
  # checked before jobs_flag, so -j/--serial no longer wins when MUTANT_DRIVER_JOBS is ALSO set —
  # precedence, not just each source in isolation above.
  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_JOBS=4 bash "$dir/dev/mutant-driver.sh" -j 3 2>&1)"
  driver_rc=$?
  expect_rc 0
  expect_out "== mutant-driver: 3 jobs =="

  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_JOBS=4 bash "$dir/dev/mutant-driver.sh" --serial 2>&1)"
  driver_rc=$?
  expect_rc 0
  expect_out "== mutant-driver: 1 jobs =="

  run_driver "$dir" -j abc
  expect_rc 2
  expect_out "usage: dev/mutant-driver.sh"
}

case_footer_format() {
  local dir; dir="$(fresh_driver_root footer-format)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-beta","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 0
  expect_out "== summary: 2 pass, 0 fail =="
}

# mutant:drv-unsorted — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Replaces join_sorted's own `LC_ALL=C sort -u` with `cat`, so the
# printed `<set>` reflects each side's own input order instead of a true C-locale sort. Every
# other case's registry `expect_fail` order already happens to equal the suite's own alphabetical
# print order, so a pass-through `cat` would still print the identical string there; only this
# case's deliberately reversed pair (suite prints "alpha" before "Zeta"; C-locale sort orders them
# "Zeta,alpha") tells the two apart.
case_unsorted_set_order() {
  local dir; dir="$(fresh_driver_root unsorted-set-order)"
  write_unsorted_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-unsorted","target":"lib.sh","suite":"dev/unsorted-suite.sh","filter":"",
   "edits":[{"from":"TAG_ALPHA=\"on\"","to":"TAG_ALPHA=\"off\""},
            {"from":"TAG_ZETA=\"on\"","to":"TAG_ZETA=\"off\""}],
   "expect_fail":["alpha","Zeta"]}
]}
EOF
  run_driver "$dir" --serial
  expect_rc 0
  expect_out "PASS m-unsorted 2 Zeta,alpha"
}

case_empty_needle_guard() {
  local saved_ok=1 saved_why=""
  expect_out ""
  if [ "$__ok" -ne 0 ]; then
    saved_ok=0
  fi
  saved_why="$__why"
  __ok=1; __why=""
  expect_not_out ""
  if [ "$__ok" -ne 0 ]; then
    saved_ok=0
  fi
  saved_why="$saved_why$__why"
  __ok=1; __why=""
  if [ "$saved_ok" -eq 0 ]; then
    __ok=0
    __why="empty-needle guard never fired\n"
  else
    case "$saved_why" in
      *"expect_out: empty needle"*"expect_not_out: empty needle"*) : ;;
      *) __ok=0; __why="empty-needle guard did not name both helpers: '$saved_why'\n" ;;
    esac
  fi
}

# ---------------------------------------------------------------------------------------------
# name|fn|desc
cases=(
  "pass-exact|case_pass_exact|an edit's failing set matches expect_fail exactly: PASS"
  "fail-extra-joiner|case_fail_extra_joiner|the observed failing set has a member expect_fail does not: FAIL, expected line shows the recorded set"
  "fail-missing-member|case_fail_missing_member|expect_fail names a member the observed failing set does not have: FAIL"
  "fail-swapped-member|case_fail_swapped_member|same cardinality, different member (kills drv-setcmp: a count-only compare would wrongly PASS)"
  "recipe-zero-match|case_recipe_zero_match|an edit's 'from' matches zero times: FAIL naming the edit index and the count"
  "recipe-multi-match|case_recipe_multi_match|an edit's 'from' matches twice: FAIL naming the edit index and the count (kills drv-once)"
  "recipe-first-edit-fails|case_recipe_first_edit_fails|a two-edit recipe whose FIRST edit matches zero times: FAIL reason names edit 0, not edit 1 (kills drv-nobreak)"
  "multi-edit-sequential|case_multi_edit_sequential|a second edit's 'from' text exists only after the first edit applies: proves edits run in order"
  "byte-exact-multiline|case_byte_exact_multiline|an edit whose from/to each span two lines matches and rewrites both lines together"
  "exec-bit-preserved|case_exec_bit_preserved|the target's executable bit survives the edit (kills drv-mv, which would drop it)"
  "tracked-tree-untouched|case_tracked_tree_untouched|a byte-identical find listing of the fixture tree before and after a driver run"
  "suite-runs-from-copy|case_suite_runs_from_copy|a same-named decoy earlier on PATH is never invoked; the copy's own suite runs by full path"
  "child-dies|case_child_dies|MUTANT_DRIVER_FAULT=die:<name>: a dead child is reported as FAIL ... reason no-verdict (kills drv-noverdict)"
  "declared-order|case_declared_order|MUTANT_DRIVER_FAULT=slow:<name> delays the first-declared mutant past its wave-mate: output order is unaffected (kills drv-order)"
  "baseline-red|case_baseline_red|a suite with an unconditionally failing case makes its own baseline red, and short-circuits its dependent mutant to reason baseline-red"
  "unknown-case|case_unknown_case|an expect_fail name the suite never ran: FAIL reason unknown-case:<name>"
  "unknown-case-prefix|case_unknown_case_prefix|an expect_fail name that is a strict prefix of a real case name: FAIL reason unknown-case:<name>, not a set mismatch (kills drv-unknownexact)"
  "suite-no-summary|case_suite_no_summary|a suite run with no '== summary: ...' footer: FAIL reason no-summary (kills drv-total)"
  "total-mismatch|case_total_mismatch|a suite footer whose own pass+fail disagrees with its case-line count: FAIL reason total-mismatch"
  "reg-bad-name|case_reg_bad_name|a name violating ^[A-Za-z0-9][A-Za-z0-9-]*\$: exit 2, no suite ever ran"
  "reg-duplicate-name|case_reg_duplicate_name|two records sharing one name: exit 2, no suite ever ran"
  "reg-absolute-target|case_reg_absolute_target|an absolute target path: exit 2, no suite ever ran"
  "reg-dotdot-target|case_reg_dotdot_target|a target path containing '..': exit 2, no suite ever ran"
  "reg-bad-suite-path|case_reg_bad_suite_path|a suite path outside dev/ that resolves to a real file: exit 2, no suite ever ran (kills drv-suiteshape)"
  "reg-empty-edits|case_reg_empty_edits|an empty edits array: exit 2, no suite ever ran"
  "reg-empty-expect-fail|case_reg_empty_expect_fail|an empty expect_fail array: exit 2, no suite ever ran"
  "reg-bad-top-level|case_reg_bad_top_level|a top level that isn't {\"mutants\": [...]}: exit 2, no suite ever ran (kills drv-toplevel)"
  "reg-record-not-object|case_reg_record_not_object|a mutants[] element that isn't an object: exit 2, no suite ever ran (kills drv-recobj)"
  "reg-bad-keys|case_reg_bad_keys|a record with an extra key: exit 2, no suite ever ran (kills drv-keys)"
  "reg-target-not-string|case_reg_target_not_string|a null target: exit 2, no suite ever ran (kills drv-targettype)"
  "reg-missing-target|case_reg_missing_target|a repo-relative, non-absolute, '..'-free target that does not exist: exit 2, no suite ever ran (kills drv-targetexists)"
  "reg-suite-missing|case_reg_suite_missing|a suite path matching the dev/....sh shape that names no real file: exit 2, no suite ever ran (kills drv-suiteexists)"
  "reg-bad-filter-type|case_reg_bad_filter_type|a numeric filter: exit 2, no suite ever ran (kills drv-filtertype)"
  "reg-empty-from|case_reg_empty_from|an edit with an empty 'from': exit 2, no suite ever ran (kills drv-fromtype)"
  "reg-from-equals-to|case_reg_from_equals_to|an edit whose 'from' equals its 'to': exit 2, no suite ever ran (kills drv-fromto)"
  "filter-no-match|case_filter_no_match|a name-filter matching no registry record: message + exit 1"
  "jobs-line|case_jobs_line|the first stdout line's job count: -j 3, --serial, MUTANT_DRIVER_JOBS=4, MUTANT_DRIVER_JOBS with -j/--serial together (-j/--serial wins), and an invalid -j value (exit 2)"
  "footer-format|case_footer_format|the exact '== summary: N pass, M fail ==' footer wording"
  "unsorted-set-order|case_unsorted_set_order|the printed <set> is true LC_ALL=C-sorted, not merely the suite's own print order (kills drv-unsorted)"
  "empty-needle-guard|case_empty_needle_guard|expect_out/expect_not_out with an empty needle fail the CASE, not the driver, and name themselves"
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
