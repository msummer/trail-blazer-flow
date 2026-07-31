#!/usr/bin/env bash
#
# selfcheck-tests.sh — negative-test harness for dev/selfcheck.sh (the gate).
#
# Usage: bash dev/selfcheck-tests.sh [name-filter]
#   With no argument, runs every case. With an argument, runs only the cases whose name
#   contains that substring (a non-zero exit if the filter matches nothing).
#
# Contract, one row per case: apply ONE documented perturbation to a throwaway copy of this
# repo, run the PRISTINE gate (dev/selfcheck.sh, from this checkout — never the copy's own,
# perturbed version of it) against that copy, and assert that the gate's failing-assertion-id
# set exactly equals the case's declared expected set, that at least one of those ids' "  FAIL
# <id> " lines is present verbatim, and that the exit code is 1 (0 for the declared control
# cases, whose expected set is empty and which exist to prove a perturbation is NOT falsely
# flagged). Same output contract as the gate: one PASS/FAIL line per case, a
# `== summary: N pass, M fail ==` footer, exit 0 iff nothing failed.
#
# This is the only script under dev/ that writes files (the consumer doctor bin/check-harness.sh
# also seeds .claude/LESSONS.md when absent). Every write here happens under a single
# `mktemp -d` root, removed via a trap on EXIT; nothing outside that root is ever touched. By
# convention (CLAUDE.md), no perturbation helper here uses `sed -i` either — plain `sed` writing
# to a sibling temp file, same idiom as the rest of this repo.
#
# Case coverage policy: a case is required for any assertion that parses structure out of a
# file, compares two extracted sets, or exercises script behavior; fixed-string and
# numeric-threshold assertions are exempt (one reason each): 1.2 (two fixed-string comparisons
# per file), 1.3 (single fixed-string grep), 2.2 (one regex over one jq scalar — the 2.1 case
# proves the jq read), 2.3 (equality of two jq scalars; 2.1's expected set already includes it),
# 3.1 (frontmatter_text is exercised by 4.2-empty-desc; 3.1's own clauses are key-presence
# greps), 3.7 (fence_lines is exercised by the 3.4 case; 3.7 itself is a fixed-string grep
# inside the slice), 4.1, 4.5, 4.7, 4.8, 4.9 (fixed-string presence checks).
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"

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

# ---------------------------------------------------------------------------------------------
# Portable helpers. No sed -i anywhere (see header note above).

# fresh_copy NAME — copies this repo (everything except .git) into $tmpbase/NAME; prints the
# path. A fresh copy per case, so perturbations never accumulate across cases.
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

# edit FILE SCRIPT — a sed edit without -i: write to a sibling temp file, then move it over
# FILE. SCRIPT is plain (basic-regex) sed, matching how the rest of this repo writes sed.
edit() {
  sed "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# drop FILE ERE — remove every line matching ERE.
drop() {
  grep -vE "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# append FILE — appends stdin to FILE.
append() {
  cat >> "$1"
}

# run_gate DIR — runs THIS checkout's pristine gate against DIR, leaving $gate_out (combined
# stdout+stderr) and $gate_rc (exit code) set as globals. Deliberately NOT invoked via command
# substitution ("$(run_gate ...)") — that would fork a subshell, and the $? capture inside would
# never make it back to the caller. Call it as a plain statement and read the globals after.
gate_out=""
gate_rc=0
run_gate() {
  gate_out="$(bash "$root/dev/selfcheck.sh" "$1" 2>&1)"
  gate_rc=$?
}

# fail_ids OUTPUT — the sorted, de-duplicated, space-joined set of assertion ids from OUTPUT's
# "  FAIL  <id> " lines.
fail_ids() {
  printf '%s\n' "$1" | sed -n 's/^  FAIL  \([0-9][0-9]*\.[0-9][0-9]*\) .*/\1/p' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# normalize_ids STR — whitespace-collapsed, sorted, de-duplicated, space-joined id set, so an
# expected-set literal and an observed-set extraction compare equal regardless of spacing/order.
normalize_ids() {
  printf '%s\n' "$1" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------------------------
# Perturbation functions. Each takes the copy's root directory as $1 and mutates only inside it.

p_1_1()            { printf 'if [\n' | append "$1/bin/harness-status.sh"; }
p_1_1_dev()         { printf 'if [\n' | append "$1/dev/selfcheck-tests.sh"; }
p_1_4_mapfile()    { printf 'mapfile -t x < /dev/null\n' | append "$1/bin/harness-status.sh"; }
p_1_4_comment() {
  printf '# mentions mapfile, readarray, sed -i, grep -P, readlink -f, declare -A here\n' \
    | append "$1/bin/harness-status.sh"
}
p_1_5()               { printf 'git branch -D "$stale" >/dev/null\n' | append "$1/bin/harness-status.sh"; }
p_1_5_guarded()        { printf 'git branch -D "$stale" || true\n' | append "$1/bin/harness-status.sh"; }
p_2_1() {
  # PREPEND the stray '{' (not append): jq streams top-level values, so appending garbage
  # after an already-complete, valid document still lets '.plugins[0].name' resolve from that
  # first value — only corrupting the document before/around the value being read actually
  # blanks the jq read, which is what forces 2.3 to fail alongside 2.1 (see the case's comment
  # in the table below; this was checked with a throwaway jq probe, not assumed).
  local f="$1/.claude-plugin/marketplace.json"
  { printf '{\n'; cat "$f"; } > "$f.tmp" && mv "$f.tmp" "$f"
}
p_2_4_missing_grant() { drop "$1/templates/repo-settings.json" '"Bash\(harness-status\.sh:\*\)"'; }
p_2_4_orphan_grant() {
  local f="$1/templates/repo-settings.json"
  awk '{print} /"Bash\(harness-status\.sh:\*\)",/ && !done {print "      \"Bash(nonexistent.sh:*)\","; done=1}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
p_2_5_missing_bare()  { drop "$1/templates/repo-settings.json" '"Bash\(git commit:\*\)"'; }
p_2_6()               { drop "$1/templates/repo-settings.json" '"Bash\(git -C \* clean\*\)"'; }
p_2_7_template()       { edit "$1/templates/repo-settings.json" 's/ main:\*)/ trunk:*)/; s/ main\*)/ trunk*)/'; }
p_2_7_doctor()         { edit "$1/bin/check-harness.sh" 's/^tmpl_guarded_branch=/tmpl_renamed_branch=/'; }
p_3_4()               { edit "$1/agents/planner.md" 's/retries=<k>/retries=<kk>/'; }
p_4_2_empty_desc() {
  local f="$1/skills/project-kickoff/SKILL.md"
  awk '
    /^description: >$/ { print; skip=1; next }
    skip && /^---$/ { skip=0; print; next }
    skip { next }
    { print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
p_4_6()               { drop "$1/bin/setup-labels.sh" '^create_or_update "plan-proposed"'; }
p_4_11()              { printf 'grep -q "Bash(gh pr merge" "$settings"\n' | append "$1/bin/check-harness.sh"; }
p_4_13_script()       { edit "$1/bin/reconcile-ledger.sh" 's/^STAGES="seed planner implementer verifier merge"$/STAGES="seed planner implementer verifier merge docs"/'; }
p_4_13_skill()        { edit "$1/skills/issue-implementer/SKILL.md" 's/stage=<planner|implementer|verifier|merge>/stage=<planner|implementer|verifier|merge|docs>/'; }
p_4_13_outcome()      { edit "$1/agents/verifier.md" 's/outcome=<pass|fail|incomplete|died>/outcome=<pass|fail|incomplete|died|bogus-outcome>/'; }
p_4_13_extraction()   { edit "$1/bin/reconcile-ledger.sh" 's/STAGES/STAGE_LIST/g'; }
p_4_14_oversize() {
  local i=0
  { while [ "$i" -lt 300 ]; do echo "filler line $i"; i=$((i+1)); done; } | append "$1/skills/harness-setup/SKILL.md"
}
p_4_15()              { printf 'x=$(echo hi)\n' | append "$1/skills/harness-setup/SKILL.md"; }
p_5_1()               { edit "$1/bin/reconcile-ledger.sh" 's/blocked incomplete died/blocked incomplete/'; }
p_5_2()               { edit "$1/bin/reconcile-ledger.sh" 's/stage-skipped issue/stage_skipped issue/'; }

# ---------------------------------------------------------------------------------------------
# Case table: name|expected-ids (space-separated, empty for a control case)|perturb function
# name ("none" for no perturbation)|one-line description. Every id not listed here is on the
# coverage-exemption list in the header comment above.
cases=(
  "control-clean||none|pristine copy, no perturbation: the gate must be all-green"
  "1.1|1.1|p_1_1|append a stray 'if [' to bin/harness-status.sh (syntax error)"
  "1.1-dev|1.1|p_1_1_dev|append a stray 'if [' to dev/selfcheck-tests.sh itself (syntax error)"
  "1.4-mapfile|1.4|p_1_4_mapfile|append a bare 'mapfile' invocation to bin/harness-status.sh"
  "1.4-mentions||p_1_4_comment|control: a single #-comment naming all five constructs"
  "1.5|1.5|p_1_5|append a bare, unchecked 'git branch -D' to bin/harness-status.sh"
  "1.5-guarded||p_1_5_guarded|control: the same delete with a '|| true' fallback is not flagged"
  "2.1|2.1 2.3|p_2_1|prepend a stray '{' to marketplace.json (invalid JSON; blanks 2.3's jq read too)"
  "2.4-missing-grant|2.4|p_2_4_missing_grant|drop the Bash(harness-status.sh:*) allow entry"
  "2.4-orphan-grant|2.4|p_2_4_orphan_grant|add an allow entry for a bin/ script that doesn't exist"
  "2.5-missing-bare|2.5|p_2_5_missing_bare|drop the Bash(git commit:*) allow entry"
  "2.6|2.6|p_2_6|drop the Bash(git -C * clean*) deny entry"
  "2.7-template|2.7|p_2_7_template|retarget the template's branch-scoped denies from main to trunk"
  "2.7-doctor|2.7|p_2_7_doctor|rename check-harness.sh's tmpl_guarded_branch= line so the gate's extraction comes back empty"
  "3.4|3.4|p_3_4|agents/planner.md's harness-status line: retries=<k> becomes retries=<kk>"
  "4.2-empty-desc|4.2|p_4_2_empty_desc|delete project-kickoff/SKILL.md's folded description body"
  "4.6|4.6|p_4_6|drop a label bin/setup-labels.sh creates from the doctor's required list"
  "4.11|4.11|p_4_11|reintroduce a raw grep of \"\$settings\" in bin/check-harness.sh"
  "4.13-script|4.13|p_4_13_script|add a 'docs' stage to reconcile-ledger.sh's STAGES= list only"
  "4.13-skill|4.13|p_4_13_skill|add a 'docs' alternative to issue-implementer/SKILL.md's status-line stage grammar only"
  "4.13-outcome|4.13|p_4_13_outcome|add an undocumented outcome alternative to agents/verifier.md's status line"
  "4.13-extraction|4.13|p_4_13_extraction|rename reconcile-ledger.sh's STAGES= line so the gate's extraction comes back empty"
  "4.14|4.14|p_4_14_oversize|append 300 filler lines to skills/harness-setup/SKILL.md"
  "4.15|4.15|p_4_15|append a real dollar-paren command to skills/harness-setup/SKILL.md"
  "5.1|5.1|p_5_1|drop 'died' from reconcile-ledger.sh's implementer outcome vocabulary"
  "5.2|5.2|p_5_2|rename reconcile-ledger.sh's 'stage-skipped' emit to 'stage_skipped'"
)

# ---------------------------------------------------------------------------------------------
run_case() {
  local name="$1" expected="$2" perturb="$3" desc="$4"
  local dir out observed exp_norm obs_norm literal_ok eid
  dir="$(fresh_copy "$name")"
  if [ "$perturb" != "none" ]; then
    "$perturb" "$dir"
  fi
  run_gate "$dir"
  out="$gate_out"
  observed="$(fail_ids "$out")"
  exp_norm="$(normalize_ids "$expected")"
  obs_norm="$(normalize_ids "$observed")"

  local ok=1
  [ "$exp_norm" = "$obs_norm" ] || ok=0
  if [ -z "$exp_norm" ]; then
    [ "$gate_rc" -eq 0 ] || ok=0
  else
    [ "$gate_rc" -eq 1 ] || ok=0
    literal_ok=0
    for eid in $exp_norm; do
      printf '%s\n' "$out" | grep -qE "^  FAIL  ${eid} " && { literal_ok=1; break; }
    done
    [ "$literal_ok" -eq 1 ] || ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    case_ok "$name" "$desc"
  else
    case_bad "$name" "$desc"
    echo "    expected: {$exp_norm}  observed: {$obs_norm}  rc=$gate_rc"
    printf '%s\n' "$out" | grep '^  FAIL  ' | sed 's/^/    /'
  fi
}

run_headercount_case() {
  local header_n out n_lines
  header_n="$(grep -m1 -oE '[0-9]+ assertions total' "$root/dev/selfcheck.sh" | grep -oE '^[0-9]+')"
  out="$(bash "$root/dev/selfcheck.sh" "$root" 2>&1)"
  n_lines="$(printf '%s\n' "$out" | grep -cE '^  (PASS|FAIL)  ')"
  if [ "$header_n" = "$n_lines" ]; then
    case_ok "header-count" "dev/selfcheck.sh's header 'N assertions total' matches a clean run's PASS+FAIL line count"
  else
    case_bad "header-count" "dev/selfcheck.sh's header 'N assertions total' matches a clean run's PASS+FAIL line count"
    echo "    header says $header_n, clean run printed $n_lines PASS/FAIL lines"
  fi
}

# ---------------------------------------------------------------------------------------------
meta_names="header-count"
matched=0

for row in "${cases[@]}"; do
  name="${row%%|*}"
  case "$name" in
    *"$filter"*) : ;;
    *) continue ;;
  esac
  matched=$((matched+1))
  rest="${row#*|}"
  expected="${rest%%|*}"
  rest="${rest#*|}"
  perturb="${rest%%|*}"
  desc="${rest#*|}"
  run_case "$name" "$expected" "$perturb" "$desc"
done

for name in $meta_names; do
  case "$name" in
    *"$filter"*) : ;;
    *) continue ;;
  esac
  matched=$((matched+1))
  case "$name" in
    header-count)  run_headercount_case ;;
  esac
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
