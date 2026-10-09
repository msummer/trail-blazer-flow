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

# A CI step env (MUTANT_DRIVER_SINCE, #464; MUTANT_DRIVER_SHARD, #526) inherited through the OUTER
# driver run that runs this very file as a suite would otherwise leak into every nested driver
# invocation this file makes below, silently switching every plain run_driver call into (fallback)
# selection mode or into a shard slice.
unset MUTANT_DRIVER_SINCE
unset MUTANT_DRIVER_SHARD

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

# write_pool_fixture DIR MARKDIR — a target (lib.sh, executable) with three independent tags and a
# suite (dev/pool-suite.sh) whose three cases prove the rolling pool refills a freed slot instead of
# waiting for every running job to finish:
#   case-a:    passes iff TAG_A reads "on".
#   case-b:    if TAG_B reads "mark", touches MARKDIR/b-started and FAILs; if it reads "on", PASSes.
#   case-slow: if TAG_SLOW reads "on", PASSes at once. If it reads "wait", polls for
#              MARKDIR/b-started in 0.1s slices for about 15s: FAILs if the marker appears (proving
#              case-b's mutant ran concurrently, while this case was still waiting), PASSes on
#              timeout (the barrier-wave regression path — see case_pool_refill).
# MARKDIR is an absolute path baked into the suite text at write time (the same unquoted-heredoc
# idiom case_suite_runs_from_copy's own decoy uses for its sentinel path); every other "$" the suite
# itself needs is backslash-escaped so it survives to be the SUITE's own variable, not expanded now.
write_pool_fixture() {
  local dir="$1" markdir="$2"
  cat > "$dir/lib.sh" <<'EOF'
#!/usr/bin/env bash
TAG_SLOW="on"
TAG_A="on"
TAG_B="on"
EOF
  chmod +x "$dir/lib.sh"
  mkdir -p "$dir/dev"
  cat > "$dir/dev/pool-suite.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
froot="\$(cd "\$(dirname "\$0")/.." && pwd)"
filter="\${1:-}"
markdir="$markdir"
pass=0; fail=0
case_ok()  { echo "  PASS  \$1 — \$2"; pass=\$((pass+1)); }
case_bad() { echo "  FAIL  \$1 — \$2"; fail=\$((fail+1)); }

case "case-a" in
  *"\$filter"*)
    if grep -qF -- 'TAG_A="on"' "\$froot/lib.sh"; then
      case_ok "case-a" "TAG_A reads on"
    else
      case_bad "case-a" "TAG_A does not read on"
    fi
    ;;
esac

case "case-b" in
  *"\$filter"*)
    if grep -qF -- 'TAG_B="mark"' "\$froot/lib.sh"; then
      touch "\$markdir/b-started"
      case_bad "case-b" "TAG_B is mark"
    elif grep -qF -- 'TAG_B="on"' "\$froot/lib.sh"; then
      case_ok "case-b" "TAG_B reads on"
    else
      case_bad "case-b" "TAG_B is neither on nor mark"
    fi
    ;;
esac

case "case-slow" in
  *"\$filter"*)
    if grep -qF -- 'TAG_SLOW="on"' "\$froot/lib.sh"; then
      case_ok "case-slow" "TAG_SLOW reads on"
    elif grep -qF -- 'TAG_SLOW="wait"' "\$froot/lib.sh"; then
      waited=0
      bstarted=0
      while [ "\$waited" -lt 150 ]; do
        if [ -e "\$markdir/b-started" ]; then
          bstarted=1
          break
        fi
        sleep 0.1
        waited=\$((waited+1))
      done
      if [ "\$bstarted" -eq 1 ]; then
        case_bad "case-slow" "b started while slow still running"
      else
        case_ok "case-slow" "b never started while slow was waiting"
      fi
    else
      case_bad "case-slow" "TAG_SLOW is neither on nor wait"
    fi
    ;;
esac

echo
echo "== summary: \$pass pass, \$fail fail =="
if [ "\$fail" -gt 0 ]; then exit 1; fi
exit 0
EOF
  chmod +x "$dir/dev/pool-suite.sh"
}

# write_registry DIR JSON — writes JSON (via stdin) as the fixture's one registry file, pointed at
# by MUTANT_DRIVER_REGISTRY_DIR in run_driver below.
write_registry() {
  local dir="$1"
  mkdir -p "$dir/mutants"
  cat > "$dir/mutants/reg.json"
}

# write_named_registry DIR FILE — like write_registry, but writes to $dir/mutants/FILE (stdin).
# Selection cases (#464) need more than one registry file, so a case can select exactly one file's
# own record via its registry-file path.
write_named_registry() {
  local dir="$1" file="$2"
  mkdir -p "$dir/mutants"
  cat > "$dir/mutants/$file"
}

# write_selection_fixture DIR (#464) — two independent mutants, each in its own registry file, each
# suite mapped in dev/mutants/suite-deps.txt to a dependency file distinct from its own
# target/suite/registry file, so a selection case can discriminate "matched via the map" from
# "matched via target/suite/registry-file equality":
#   mutants/a.json: m-beta (lib.sh / dev/fixture-suite.sh, TAG_BETA on->off, expect case-beta)
#   mutants/b.json: m-step (step.sh / dev/step-suite.sh, STEP zero->one, expect case-step)
#   mutants/suite-deps.txt: dev/fixture-suite.sh -> fixture-data.txt; dev/step-suite.sh ->
#     step-data.txt
write_selection_fixture() {
  local dir="$1"
  write_generic_fixture "$dir"
  write_multiedit_fixture "$dir"
  printf 'fixture data\n' > "$dir/fixture-data.txt"
  printf 'step data\n' > "$dir/step-data.txt"
  write_named_registry "$dir" "a.json" <<'EOF'
{"mutants":[
  {"name":"m-beta","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  write_named_registry "$dir" "b.json" <<'EOF'
{"mutants":[
  {"name":"m-step","target":"step.sh","suite":"dev/step-suite.sh","filter":"",
   "edits":[{"from":"STEP=\"zero\"","to":"STEP=\"one\""}],
   "expect_fail":["case-step"]}
]}
EOF
  cat > "$dir/mutants/suite-deps.txt" <<'EOF'
dev/fixture-suite.sh fixture-data.txt
dev/step-suite.sh    step-data.txt
EOF
}

# git_fixture_home — one throwaway HOME/XDG_CONFIG_HOME for every git-backed selection fixture
# below (#464), so a fixture's own `git init`/commit never reads the developer's or CI runner's
# real global git config (the same isolation dev/hook-tests.sh's own run_push_guard uses).
git_fixture_home="$tmpbase/git-fixture-home"
mkdir -p "$git_fixture_home"

# run_fixture_git DIR ARGS... — runs `git ARGS...` inside DIR with HOME/XDG_CONFIG_HOME isolated
# under $git_fixture_home and GIT_CONFIG_NOSYSTEM=1; stdout/stderr discarded. rc is the git
# invocation's own.
run_fixture_git() {
  local dir="$1"
  shift
  (cd "$dir" && HOME="$git_fixture_home" XDG_CONFIG_HOME="$git_fixture_home/.config" \
    GIT_CONFIG_NOSYSTEM=1 git "$@" >/dev/null 2>&1)
}

# fixture_git_out DIR ARGS... — like run_fixture_git, but prints stdout (stderr discarded).
fixture_git_out() {
  local dir="$1"
  shift
  (cd "$dir" && HOME="$git_fixture_home" XDG_CONFIG_HOME="$git_fixture_home/.config" \
    GIT_CONFIG_NOSYSTEM=1 git "$@" 2>/dev/null)
}

# git_fixture_commit DIR MSG — `git add -A` then `git commit -qm MSG` inside DIR, with the identity
# and signing passed on the command line (never read from any config file).
git_fixture_commit() {
  local dir="$1" msg="$2"
  run_fixture_git "$dir" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false add -A
  run_fixture_git "$dir" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm "$msg"
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
# bash dev/mutant-driver.sh. Makes the driver's own reap_slots print each job (via collect_job) the
# moment IT is reaped — completion order — instead of leaving printing to print_ready's own
# declared-order walk, so a slow: FAULT-delayed first-declared mutant would print out of sequence.
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

# mutant:drv-barrier — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Inserts a guard as fill_slots' own first statement that refuses to
# launch anything while any job is still running — barrier-wave behavior — so a slot freed by a
# finished job sits idle instead of being refilled right away.
case_pool_refill() {
  local dir; dir="$(fresh_driver_root pool-refill)"
  local markdir; markdir="$(mktemp -d "$tmpbase/pool-mark-XXXXXX")"
  write_pool_fixture "$dir" "$markdir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-slow","target":"lib.sh","suite":"dev/pool-suite.sh","filter":"",
   "edits":[{"from":"TAG_SLOW=\"on\"","to":"TAG_SLOW=\"wait\""}],
   "expect_fail":["case-slow"]},
  {"name":"m-a","target":"lib.sh","suite":"dev/pool-suite.sh","filter":"",
   "edits":[{"from":"TAG_A=\"on\"","to":"TAG_A=\"off\""}],
   "expect_fail":["case-a"]},
  {"name":"m-b","target":"lib.sh","suite":"dev/pool-suite.sh","filter":"",
   "edits":[{"from":"TAG_B=\"on\"","to":"TAG_B=\"mark\""}],
   "expect_fail":["case-b"]}
]}
EOF
  run_driver "$dir" -j 2
  expect_rc 0
  expect_out "PASS m-slow 3 case-slow"
  expect_out "PASS m-a 3 case-a"
  expect_out "PASS m-b 3 case-b"
}

# mutant:drv-nodep — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Replaces the driver's own job_ready dependency-state test with an
# unconditional true, so a mutant could launch — and read its own .basestatus — before its own
# baseline job has actually finished.
case_baseline_gates_dependents() {
  local dir; dir="$(fresh_driver_root baseline-gates-dependents)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-beta","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_FAULT="slow:baseline:dev/fixture-suite.sh:" bash "$dir/dev/mutant-driver.sh" -j 2 2>&1)"
  driver_rc=$?
  expect_rc 0
  expect_out "PASS baseline:dev/fixture-suite.sh: 3 -"
  expect_out "PASS m-beta 3 case-beta"
  expect_not_out "reason baseline-red"
}

# mutant:drv-basefallback — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh. Changes the driver's own basestatus_for fail-closed fallback from "red"
# to "clean", so a baseline that died before ever writing its own .basestatus would let its
# dependent mutant run as though the baseline had been proven clean. (Also killed by drv-noverdict:
# with a dead baseline counted as a silent pass, its own FAIL/no-verdict line disappears from this
# case's expected output too.)
case_baseline_dies() {
  local dir; dir="$(fresh_driver_root baseline-dies)"
  write_generic_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-beta","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_FAULT="die:baseline:dev/fixture-suite.sh:" bash "$dir/dev/mutant-driver.sh" -j 2 2>&1)"
  driver_rc=$?
  expect_rc 1
  expect_out "FAIL baseline:dev/fixture-suite.sh: - -"
  expect_out "    reason no-verdict"
  expect_out "FAIL m-beta - -"
  expect_out "    reason baseline-red"
  expect_out "== summary: 0 pass, 2 fail =="
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
# Change-based selection (#464): one case per selection/fail-safe/validation rule in
# dev/mutant-driver.sh's new change-based selection block and its suite-deps.txt loader.

# mutant:drv-sel-target — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Deletes the driver's own record_selected target-equality clause,
# so a changed path equal to a record's OWN target would no longer select it.
case_sel_target() {
  local dir; dir="$(fresh_driver_root sel-target)"
  write_selection_fixture "$dir"
  printf 'lib.sh\n' > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt"
  expect_rc 0
  expect_out "selected 1 of 2 records"
  expect_out "PASS m-beta 3 case-beta"
  expect_not_out "m-step"
}

# mutant:drv-sel-suite — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Deletes the driver's own record_selected suite-equality clause,
# so a changed path equal to a record's OWN suite would no longer select it.
case_sel_suite() {
  local dir; dir="$(fresh_driver_root sel-suite)"
  write_selection_fixture "$dir"
  printf 'dev/step-suite.sh\n' > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt"
  expect_rc 0
  expect_out "selected 1 of 2 records"
  expect_out "PASS m-step 1 case-step"
  expect_not_out "m-beta"
}

# mutant:drv-sel-registry — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Deletes the driver's own record_selected registry-file-equality
# clause, so a changed path equal to a record's OWN registry file would no longer select it.
case_sel_registry() {
  local dir; dir="$(fresh_driver_root sel-registry)"
  write_selection_fixture "$dir"
  printf 'mutants/b.json\n' > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt"
  expect_rc 0
  expect_out "selected 1 of 2 records"
  expect_out "PASS m-step 1 case-step"
  expect_not_out "m-beta"
}

# mutant:drv-sel-deps — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Deletes the driver's own record_selected map-pattern clause, so a
# changed path matching only a suite-deps.txt pattern (never the target/suite/registry file itself)
# no longer selects that pattern's suite.
case_sel_dependency() {
  local dir; dir="$(fresh_driver_root sel-dependency)"
  write_selection_fixture "$dir"
  printf 'step-data.txt\n' > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt"
  expect_rc 0
  expect_out "selected 1 of 2 records"
  expect_out "PASS m-step 1 case-step"
  expect_not_out "m-beta"
}

# mutant:drv-sel-zero — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Rewrites the driver's own zero-selected branch to exit 1 instead
# of printing the summary footer and exiting 0, so this clean no-op selection would wrongly FAIL.
case_sel_none() {
  local dir; dir="$(fresh_driver_root sel-none)"
  write_selection_fixture "$dir"
  printf 'README.md\n' > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt"
  expect_rc 0
  expect_out "selected 0 of 2 records"
  expect_out "== summary: 0 pass, 0 fail =="
  expect_not_out "baseline:"
}

# mutant:drv-sel-unclaimed — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Widens the driver's own watched-prefix case pattern
# (bin/*|hooks/*|templates/*|agents/*|skills/*|dev/*) so it never matches, so an unclaimed path
# under one of those prefixes would no longer force a full run.
case_sel_unclaimed() {
  local dir; dir="$(fresh_driver_root sel-unclaimed)"
  write_selection_fixture "$dir"
  printf 'dev/helper-lib.sh\n' > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt"
  expect_rc 0
  expect_out "full run (reason: unclaimed path dev/helper-lib.sh)"
  expect_out "PASS m-beta"
  expect_out "PASS m-step"
  expect_out "== summary: 4 pass, 0 fail =="
}

# mutant:drv-sel-driver — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Deletes the driver's own driver-changed trigger, so a change to
# dev/mutant-driver.sh itself would fall through to the (also-firing) unclaimed-path fallback
# instead of naming its own distinct reason — this fixture's dev/mutant-driver.sh is itself
# unclaimed, so only asserting the EXACT reason text tells the two fallbacks apart.
case_sel_driver() {
  local dir; dir="$(fresh_driver_root sel-driver)"
  write_selection_fixture "$dir"
  printf 'dev/mutant-driver.sh\n' > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt"
  expect_rc 0
  expect_out "full run (reason: driver changed)"
}

# mutant:drv-sel-unmapped — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Rewrites the driver's own record_selected fail-safe so an
# unmapped suite (no suite-deps.txt lines) is treated as matching nothing instead of any change.
case_sel_unmapped_suite() {
  local dir; dir="$(fresh_driver_root sel-unmapped-suite)"
  write_selection_fixture "$dir"
  printf 'dev/fixture-suite.sh fixture-data.txt\n' > "$dir/mutants/suite-deps.txt"
  printf 'README.md\n' > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt"
  expect_rc 0
  expect_out "selected 1 of 2 records"
  expect_out "PASS m-step 1 case-step"
  expect_not_out "m-beta"
}

# mutant:drv-sel-starclaim — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Drops the driver's own bare-"*" exclusion from path_claimed, so a
# suite-deps.txt line of a bare "*" would wrongly CLAIM every path instead of only selecting.
case_sel_star_no_claim() {
  local dir; dir="$(fresh_driver_root sel-star-no-claim)"
  write_selection_fixture "$dir"
  printf 'dev/fixture-suite.sh fixture-data.txt\ndev/step-suite.sh *\n' > "$dir/mutants/suite-deps.txt"
  printf 'dev/helper-lib.sh\n' > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt"
  expect_rc 0
  expect_out "full run (reason: unclaimed path dev/helper-lib.sh)"
  expect_not_out "selected"
}

# mutant:drv-sel-default — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Flips the driver's own sel_mode=0 initializer to 1, so a plain run
# with no --changed-from and no MUTANT_DRIVER_SINCE would wrongly enter selection mode with an
# empty change list instead of running every record unchanged.
case_sel_full_unchanged() {
  local dir; dir="$(fresh_driver_root sel-full-unchanged)"
  write_selection_fixture "$dir"
  run_driver "$dir" --serial
  expect_rc 0
  expect_not_out "selected"
  expect_not_out "full run"
  expect_out "== summary: 4 pass, 0 fail =="

  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_SINCE= bash "$dir/dev/mutant-driver.sh" --serial 2>&1)"
  driver_rc=$?
  expect_rc 0
  expect_not_out "selected"
  expect_not_out "full run"
  expect_out "== summary: 4 pass, 0 fail =="
}

case_sel_changed_from_missing() {
  local dir; dir="$(fresh_driver_root sel-changed-from-missing)"
  write_selection_fixture "$dir"
  run_driver "$dir" --serial --changed-from "$dir/nope.txt"
  expect_rc 2
  expect_out "usage: dev/mutant-driver.sh"
  expect_not_out "PASS"

  # --changed-from as the LAST argv, with no value following it: the same usage-and-exit-2
  # contract as a missing file, never a silent empty changed_from.
  run_driver "$dir" --serial --changed-from
  expect_rc 2
  expect_out "usage: dev/mutant-driver.sh"
  expect_not_out "PASS"
}

# mutant:drv-since-diff — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Diffs HEAD against HEAD instead of "$since" against HEAD, so a
# real change since the recorded base would no longer show up as a changed path.
case_sel_since_range() {
  local dir; dir="$(fresh_driver_root sel-since-range)"
  write_selection_fixture "$dir"
  run_fixture_git "$dir" init -q
  git_fixture_commit "$dir" "base"
  local base_sha; base_sha="$(fixture_git_out "$dir" rev-parse HEAD)"
  printf '# touched\n' >> "$dir/lib.sh"
  git_fixture_commit "$dir" "second"
  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_SINCE="$base_sha" bash "$dir/dev/mutant-driver.sh" --serial 2>&1)"
  driver_rc=$?
  expect_rc 0
  expect_out "selected 1 of 2 records"
  expect_out "PASS m-beta 3 case-beta"
  expect_not_out "m-step"
}

# mutant:drv-since-fallback — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Rewrites the driver's own git-diff-failed fallback to enter
# selection mode with an empty change list instead of printing the unusable-base line and leaving
# $sel untouched, so an unusable base would wrongly select zero records instead of forcing a full
# run.
#
# mutant:drv-since-dash — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Deletes the driver's own leading-"-" guard, so a
# MUTANT_DRIVER_SINCE value shaped like a git option (e.g. "--output=...") would reach git's own
# argv instead of being rejected before git ever runs.
case_sel_since_unusable() {
  local dir; dir="$(fresh_driver_root sel-since-unusable)"
  write_selection_fixture "$dir"
  run_fixture_git "$dir" init -q
  git_fixture_commit "$dir" "base"

  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_SINCE="0000000000000000000000000000000000000000" bash "$dir/dev/mutant-driver.sh" --serial 2>&1)"
  driver_rc=$?
  expect_rc 0
  expect_out "full run (reason: unusable base 0000000000000000000000000000000000000000)"
  expect_out "PASS m-beta"
  expect_out "PASS m-step"

  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_SINCE="1111111111111111111111111111111111111111" bash "$dir/dev/mutant-driver.sh" --serial 2>&1)"
  driver_rc=$?
  expect_rc 0
  expect_out "full run (reason: unusable base 1111111111111111111111111111111111111111)"

  local leak="$tmpbase/since-leak"
  rm -f "$leak"
  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_SINCE="--output=$leak" bash "$dir/dev/mutant-driver.sh" --serial 2>&1)"
  driver_rc=$?
  expect_rc 0
  expect_out "full run (reason: unusable base --output=$leak)"
  if [ -e "$leak" ]; then
    __ok=0
    __why="${__why}the leading-'-' MUTANT_DRIVER_SINCE value reached git's argv -- $leak was created\n"
  fi
}

# mutant:drv-sel-crlf — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Deletes the driver's own trailing-\r strip on each --changed-from
# line, so a CRLF-terminated changed path would carry a trailing \r and no longer equal the
# record's own target/suite/registry-file string.
case_sel_changed_from_crlf() {
  local dir; dir="$(fresh_driver_root sel-changed-from-crlf)"
  write_selection_fixture "$dir"
  printf 'lib.sh\r\n' > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt"
  expect_rc 0
  expect_out "selected 1 of 2 records"
  expect_out "PASS m-beta 3 case-beta"
  expect_not_out "m-step"
}

# mutant:drv-sel-blank — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Makes the driver's own changed+=() append unconditional, so a
# blank --changed-from line would add an empty-string "change", wrongly making changed[] non-empty
# and selecting an unmapped suite that no real changed path touches.
case_sel_changed_from_blank() {
  local dir; dir="$(fresh_driver_root sel-changed-from-blank)"
  write_selection_fixture "$dir"
  printf 'dev/fixture-suite.sh fixture-data.txt\n' > "$dir/mutants/suite-deps.txt"
  printf '\n\n' > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt"
  expect_rc 0
  expect_out "selected 0 of 2 records"
  expect_out "== summary: 0 pass, 0 fail =="
}

# mutant:drv-sel-emptychange — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Drops the driver's own "changed[] is non-empty" guard from
# record_selected's unmapped-suite fail-safe, so an unmapped suite would be selected even when the
# change list is genuinely empty.
case_sel_unmapped_empty() {
  local dir; dir="$(fresh_driver_root sel-unmapped-empty)"
  write_selection_fixture "$dir"
  printf 'dev/fixture-suite.sh fixture-data.txt\n' > "$dir/mutants/suite-deps.txt"
  : > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt"
  expect_rc 0
  expect_out "selected 0 of 2 records"
  expect_out "== summary: 0 pass, 0 fail =="
}

# mutant:drv-sel-watchclaim — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Makes path_claimed's own pattern-match loop never match, so a
# watched-prefix path a real (non-"*") suite-deps.txt pattern claims would wrongly be treated as
# unclaimed and force a full run.
case_sel_watched_claim() {
  local dir; dir="$(fresh_driver_root sel-watched-claim)"
  write_selection_fixture "$dir"
  printf 'dev/fixture-suite.sh fixture-data.txt\ndev/step-suite.sh dev/step-*.txt\n' > "$dir/mutants/suite-deps.txt"
  printf 'x\n' > "$dir/dev/step-data.txt"
  printf 'dev/step-data.txt\n' > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt"
  expect_rc 0
  expect_out "selected 1 of 2 records"
  expect_out "PASS m-step 1 case-step"
  expect_not_out "m-beta"
  expect_not_out "full run"
}

# mutant:drv-sel-filtercount — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh sel-. Replaces the driver's own "of ${#sel[@]} records" denominator
# with the total record count, so M would count every registry record instead of only the ones
# left after the name-filter.
case_sel_filtered_count() {
  local dir; dir="$(fresh_driver_root sel-filtered-count)"
  write_selection_fixture "$dir"
  printf 'lib.sh\n' > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt" m-beta
  expect_rc 0
  expect_out "selected 1 of 1 records"
  expect_out "PASS m-beta 3 case-beta"
}

# mutant:drv-deps-malformed — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh reg-deps-. Widens the driver's own suite-deps.txt two-field guard to
# "if false" so it never trips, so a map line missing its pattern field would wrongly pass
# validation instead of FAILing with "expected '<suite> <pattern>'".
case_reg_deps_malformed() {
  local dir; dir="$(fresh_driver_root reg-deps-malformed)"
  local sentinel="$tmpbase/sentinel-deps-malformed"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-beta","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  cat > "$dir/mutants/suite-deps.txt" <<'EOF'
dev/fixture-suite.sh
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "expected '<suite> <pattern>'"
}

# mutant:drv-deps-literal — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh reg-deps-. Widens the driver's own glob-free-literal-exists guard to
# "if false" so it never trips, so a map pattern naming no real file would wrongly pass validation
# instead of FAILing with "names no existing file".
case_reg_deps_missing_literal() {
  local dir; dir="$(fresh_driver_root reg-deps-missing-literal)"
  local sentinel="$tmpbase/sentinel-deps-missing-literal"
  rm -f "$sentinel"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-beta","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],
   "expect_fail":["case-beta"]}
]}
EOF
  cat > "$dir/mutants/suite-deps.txt" <<'EOF'
dev/fixture-suite.sh no-such-file.txt
EOF
  run_driver "$dir" --serial
  assert_registry_rejected "$sentinel"
  expect_out "names no existing file"
  expect_not_out "expected '<suite>"
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
# Sharding (#526).

# write_shard_fixture DIR — one registry (mutants/reg.json) of six records whose (suite, filter)
# groups are deliberately uneven, in declared order:
#   m-a1, m-a2, m-a3  fixture-suite, filter ""            (group 1, three records)
#   m-b1              fixture-suite, filter case-beta     (group 2)
#   m-s1              step-suite,    filter ""            (group 3)
#   m-c1              fixture-suite, filter case-gamma    (group 4)
write_shard_fixture() {
  local dir="$1"
  write_generic_fixture "$dir"
  write_multiedit_fixture "$dir"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-a1","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_ALPHA=\"on\"","to":"TAG_ALPHA=\"off\""}],"expect_fail":["case-alpha"]},
  {"name":"m-a2","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],"expect_fail":["case-beta"]},
  {"name":"m-a3","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_GAMMA=\"on\"","to":"TAG_GAMMA=\"off\""}],"expect_fail":["case-gamma"]},
  {"name":"m-b1","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"case-beta",
   "edits":[{"from":"TAG_BETA=\"on\"","to":"TAG_BETA=\"off\""}],"expect_fail":["case-beta"]},
  {"name":"m-s1","target":"step.sh","suite":"dev/step-suite.sh","filter":"",
   "edits":[{"from":"STEP=\"zero\"","to":"STEP=\"one\""}],"expect_fail":["case-step"]},
  {"name":"m-c1","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"case-gamma",
   "edits":[{"from":"TAG_GAMMA=\"on\"","to":"TAG_GAMMA=\"off\""}],"expect_fail":["case-gamma"]}
]}
EOF
}

# driver_mutant_names — the mutant (not baseline) names in $driver_out's result lines, one per line.
driver_mutant_names() {
  grep -E '^(PASS|FAIL) m-' <<<"$driver_out" | awk '{print $2}' | LC_ALL=C sort
}

# driver_baseline_count — how many baseline result lines $driver_out holds.
driver_baseline_count() {
  grep -cE '^(PASS|FAIL) baseline:' <<<"$driver_out"
}

# mutant:drv-shard-group — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh shard-. Assigns each record to a shard by its own position instead of
# by its (suite, filter) group, so one group's records straddle two shards: the baseline count
# across shards then exceeds the group count and the shards' unions stop being a clean partition.
case_shard_partition() {
  local dir; dir="$(fresh_driver_root shard-partition)"
  write_shard_fixture "$dir"
  local want; want="$(jq -r '.mutants[].name' "$dir/mutants/reg.json" | LC_ALL=C sort)"
  local n i got bases
  for n in 1 2 3 5; do
    got=""; bases=0
    for i in $(seq 1 "$n"); do
      run_driver "$dir" --serial --shard "$i/$n"
      expect_rc 0
      got="${got}$(driver_mutant_names)
"
      bases=$((bases + $(driver_baseline_count)))
      if [ "$n" -eq 5 ] && [ "$i" -eq 5 ]; then
        expect_out "shard 5/5: 0 of 6 records"
        expect_out "== summary: 0 pass, 0 fail =="
        expect_not_out "baseline:"
      fi
    done
    got="$(printf '%s' "$got" | sed '/^$/d' | LC_ALL=C sort)"
    if [ "$got" != "$want" ]; then
      __ok=0; __why="${__why}n=$n: union of shards is not the registry record set exactly once\n"
    fi
    if [ "$bases" -ne 4 ]; then
      __ok=0; __why="${__why}n=$n: baselines across shards were $bases, expected 4 (a group was split or repeated)\n"
    fi
  done
}

# mutant:drv-shard-greedy — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh shard-. Replaces the driver's least-loaded group pick with a
# round-robin over groups: the lone-record groups then alternate shards instead of piling onto the
# shard that has fewer records, so m-s1 lands in shard 1 instead of shard 2.
case_shard_balance() {
  local dir; dir="$(fresh_driver_root shard-balance)"
  write_shard_fixture "$dir"
  run_driver "$dir" --serial --shard 1/2
  expect_rc 0
  expect_out "== mutant-driver: shard 1/2: 3 of 6 records =="
  [ "$(driver_mutant_names | tr '\n' ' ')" = "m-a1 m-a2 m-a3 " ] || { __ok=0; __why="${__why}shard 1/2 members are not exactly m-a1 m-a2 m-a3\n"; }
  run_driver "$dir" --serial --shard 2/2
  expect_rc 0
  expect_out "== mutant-driver: shard 2/2: 3 of 6 records =="
  [ "$(driver_mutant_names | tr '\n' ' ')" = "m-b1 m-c1 m-s1 " ] || { __ok=0; __why="${__why}shard 2/2 members are not exactly m-b1 m-c1 m-s1\n"; }
}

# mutant:drv-shard-range — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh shard-. Deletes the driver's own i <= n check, so 3/2 would be
# accepted (selecting no group) instead of exiting 2 with usage before any suite runs.
case_shard_bad_spec() {
  local dir; dir="$(fresh_driver_root shard-bad-spec)"
  local sentinel="$tmpbase/sentinel-shard-bad-spec"
  write_sentinel_fixture "$dir" "$sentinel"
  write_registry "$dir" <<'EOF'
{"mutants":[
  {"name":"m-a1","target":"lib.sh","suite":"dev/fixture-suite.sh","filter":"",
   "edits":[{"from":"TAG_ALPHA=\"on\"","to":"TAG_ALPHA=\"off\""}],"expect_fail":["case-alpha"]}
]}
EOF
  local spec
  for spec in 0/2 3/2 1/0 a/2 12 1/2/3 01/2 /2 1/ 1/02 -1/2; do
    rm -f "$sentinel"
    run_driver "$dir" --serial --shard "$spec"
    assert_registry_rejected "$sentinel"
    expect_out "usage: dev/mutant-driver.sh"
  done
  rm -f "$sentinel"
  run_driver "$dir" --serial --shard
  assert_registry_rejected "$sentinel"
  expect_out "usage: dev/mutant-driver.sh"
  rm -f "$sentinel"
  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_SHARD=3/2 bash "$dir/dev/mutant-driver.sh" --serial 2>&1)"
  driver_rc=$?
  assert_registry_rejected "$sentinel"
  expect_out "usage: dev/mutant-driver.sh"
}

# mutant:drv-shard-presel — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh shard-. Makes the driver's own shard block group and pick from every
# registry record instead of the set left after change-based selection, so the shard's membership
# ignores the selection (this fixture's shard 1/2 would then hold m-beta, not m-step).
case_shard_after_selection() {
  local dir; dir="$(fresh_driver_root shard-after-selection)"
  write_selection_fixture "$dir"
  printf 'step.sh\n' > "$dir/changed.txt"
  run_driver "$dir" --serial --changed-from "$dir/changed.txt" --shard 1/2
  expect_rc 0
  expect_out "selected 1 of 2 records"
  expect_out "shard 1/2: 1 of 1 records"
  expect_out "PASS m-step"
  expect_not_out "m-beta"
  printf 'lib.sh\nstep.sh\n' > "$dir/changed.txt"
  local got="" i
  for i in 1 2; do
    run_driver "$dir" --serial --changed-from "$dir/changed.txt" --shard "$i/2"
    expect_rc 0
    expect_out "shard $i/2: 1 of 2 records"
    got="${got}$(driver_mutant_names)
"
  done
  got="$(printf '%s' "$got" | sed '/^$/d' | tr '\n' ' ')"
  [ "$got" = "m-beta m-step " ] || { __ok=0; __why="${__why}selected records across shards were '$got', expected m-beta m-step once each\n"; }
}

# mutant:drv-shard-default — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh shard-. Makes an empty shard spec behave as 1/1, so a plain run would
# print a shard line (and an empty MUTANT_DRIVER_SHARD would not mean "off").
case_shard_unset_unchanged() {
  local dir; dir="$(fresh_driver_root shard-unset)"
  write_shard_fixture "$dir"
  run_driver "$dir" --serial
  expect_rc 0
  expect_not_out "shard"
  expect_out "PASS m-c1"
  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_SHARD= bash "$dir/dev/mutant-driver.sh" --serial 2>&1)"
  driver_rc=$?
  expect_rc 0
  expect_not_out "shard"
  expect_out "PASS m-c1"
}

# mutant:drv-shard-precedence — recorded in dev/mutants/mutant-driver-tests.json; run
# bash dev/mutant-driver.sh shard-. Lets MUTANT_DRIVER_SHARD win over --shard when both are set,
# the reverse of the documented flag-wins precedence.
case_shard_precedence() {
  local dir; dir="$(fresh_driver_root shard-precedence)"
  write_shard_fixture "$dir"
  driver_out="$(MUTANT_DRIVER_REGISTRY_DIR="$dir/mutants" MUTANT_DRIVER_SHARD=2/2 bash "$dir/dev/mutant-driver.sh" --serial --shard 1/2 2>&1)"
  driver_rc=$?
  expect_rc 0
  expect_out "shard 1/2:"
  expect_not_out "shard 2/2:"
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
  "declared-order|case_declared_order|MUTANT_DRIVER_FAULT=slow:<name> delays the first-declared mutant past a later-declared mutant running beside it: output order is unaffected (kills drv-order)"
  "pool-refill|case_pool_refill|a slow job's freed slot is refilled by a later-declared job instead of waiting for the whole batch to drain, proven by a marker-file overlap, not a clock (kills drv-barrier)"
  "baseline-gates-dependents|case_baseline_gates_dependents|a mutant never reads its own .basestatus before its baseline job has finished, even while other baselines/mutants keep running (kills drv-nodep)"
  "baseline-dies|case_baseline_dies|a dead baseline reports FAIL ... reason no-verdict, and its dependent mutant fails closed with reason baseline-red, with no deadlock (kills drv-basefallback)"
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
  "sel-target|case_sel_target|a changed path equal to a record's own target selects it (kills drv-sel-target)"
  "sel-suite|case_sel_suite|a changed path equal to a record's own suite selects it (kills drv-sel-suite)"
  "sel-registry|case_sel_registry|a changed path equal to a record's own registry file selects it (kills drv-sel-registry)"
  "sel-dependency|case_sel_dependency|a changed path matching only a suite-deps.txt pattern selects that pattern's suite (kills drv-sel-deps)"
  "sel-none|case_sel_none|a changed path matching no record: selected 0 of <M>, summary 0 pass 0 fail, no baseline ever runs (kills drv-sel-zero)"
  "sel-unclaimed|case_sel_unclaimed|an unclaimed changed path under a watched prefix forces a full run (kills drv-sel-unclaimed)"
  "sel-driver|case_sel_driver|a changed dev/mutant-driver.sh forces a full run naming its own reason, not the also-firing unclaimed fallback (kills drv-sel-driver)"
  "sel-unmapped-suite|case_sel_unmapped_suite|an unmapped suite matches any change (kills drv-sel-unmapped)"
  "sel-star-no-claim|case_sel_star_no_claim|a bare '*' map line selects its suite but never claims a path (kills drv-sel-starclaim)"
  "sel-full-unchanged|case_sel_full_unchanged|no --changed-from and no (or empty) MUTANT_DRIVER_SINCE: no selected/full-run line, output unchanged (kills drv-sel-default)"
  "sel-changed-from-missing|case_sel_changed_from_missing|a --changed-from file that doesn't exist: usage + exit 2, no suite ever ran"
  "sel-since-range|case_sel_since_range|MUTANT_DRIVER_SINCE=<ancestor> selects by git diff --name-only against that ancestor (kills drv-since-diff)"
  "sel-since-unusable|case_sel_since_unusable|an all-zero, unknown, or option-shaped MUTANT_DRIVER_SINCE forces a full run and never reaches git's argv as an option (kills drv-since-fallback, drv-since-dash)"
  "sel-changed-from-crlf|case_sel_changed_from_crlf|a CRLF-terminated --changed-from line still selects, the trailing \\r stripped (kills drv-sel-crlf)"
  "sel-changed-from-blank|case_sel_changed_from_blank|a --changed-from file of only blank lines leaves an unmapped suite unselected (kills drv-sel-blank)"
  "sel-unmapped-empty|case_sel_unmapped_empty|a genuinely empty --changed-from file leaves an unmapped suite unselected (kills drv-sel-emptychange)"
  "sel-watched-claim|case_sel_watched_claim|a watched-prefix path matching a real (non-'*') suite-deps.txt pattern is claimed: selected, no full run (kills drv-sel-watchclaim)"
  "sel-filtered-count|case_sel_filtered_count|selection combined with a name-filter: M counts only the filtered records (kills drv-sel-filtercount)"
  "reg-deps-malformed|case_reg_deps_malformed|a suite-deps.txt line with no pattern field: exit 2, no suite ever ran (kills drv-deps-malformed)"
  "reg-deps-missing-literal|case_reg_deps_missing_literal|a glob-free suite-deps.txt pattern naming no real file: exit 2, no suite ever ran (kills drv-deps-literal)"
  "filter-no-match|case_filter_no_match|a name-filter matching no registry record: message + exit 1"
  "jobs-line|case_jobs_line|the first stdout line's job count: -j 3, --serial, MUTANT_DRIVER_JOBS=4, MUTANT_DRIVER_JOBS with -j/--serial together (-j/--serial wins), and an invalid -j value (exit 2)"
  "footer-format|case_footer_format|the exact '== summary: N pass, M fail ==' footer wording"
  "unsorted-set-order|case_unsorted_set_order|the printed <set> is true LC_ALL=C-sorted, not merely the suite's own print order (kills drv-unsorted)"
  "empty-needle-guard|case_empty_needle_guard|expect_out/expect_not_out with an empty needle fail the CASE, not the driver, and name themselves"
  "shard-partition|case_shard_partition|for n in 1, 2, 3, 5 the shards' mutant lines hold every record exactly once and no (suite, filter) group is split across shards; an excess shard runs nothing and exits 0 (kills drv-shard-group)"
  "shard-balance|case_shard_balance|groups go to the shard with the fewest records so far, ties to the lowest index: exact membership a round-robin would fail (kills drv-shard-greedy)"
  "shard-bad-spec|case_shard_bad_spec|a malformed or out-of-range spec, flag or env form, exits 2 with usage before any suite runs (kills drv-shard-range)"
  "shard-after-selection|case_shard_after_selection|the shard partitions the set left after change-based selection, not the whole registry (kills drv-shard-presel)"
  "shard-unset-unchanged|case_shard_unset_unchanged|no spec, or an empty MUTANT_DRIVER_SHARD: no shard line and every record runs (kills drv-shard-default)"
  "shard-precedence|case_shard_precedence|--shard wins over MUTANT_DRIVER_SHARD (kills drv-shard-precedence)"
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
  # mutant:383-fn-mutant-driver-tests — renames a cases=() row's target function in a scratch copy
  #   of this suite; this declare -F guard must report that row FAIL naming the missing function,
  #   instead of a silent PASS the row would otherwise get by falling through with $__ok unchanged.
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
exit 0
