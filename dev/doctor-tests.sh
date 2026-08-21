#!/usr/bin/env bash
#
# doctor-tests.sh — fixture-based negative-test harness for the CONSUMER doctor
# (bin/check-harness.sh) and its scoped-autonomy companion script (bin/check-decision-record.sh),
# not this repo's own gate (that's dev/selfcheck.sh + dev/selfcheck-tests.sh). Builds throwaway
# git repos under mktemp, runs a COPY of the real scripts against each, and pins verdicts that
# were previously only hand-verified: the settings.json block, the template-diff scenarios, the
# ratchet's never-execute guarantee, entry_has's allow/deny distinction, the active verdict's
# no-CI note, default-branch guard coverage, the half-activated remediation's file naming, and
# the scoped-autonomy declarations (the doctor's verdict block and check-decision-record.sh's
# per-element PASS/FAIL report).
#
# Usage: bash dev/doctor-tests.sh [name-filter] — same output contract as
# dev/selfcheck-tests.sh: one PASS/FAIL line per case, a `== summary: N pass, M fail ==` footer,
# exit 0 iff nothing failed; a filter with no match exits 1.
#
# Every write happens under one `mktemp -d` root, removed via an EXIT trap; this repo's own .git
# is never opened. Each fixture gets its OWN copy of bin/check-harness.sh + its template (the
# doctor derives the template path from $0, so "template missing" is otherwise untestable
# against the real tree); every run points HOME/CLAUDE_CONFIG_DIR into the fixture and prepends
# a stub `gh` (offline, deterministic, FAIL-free) to PATH, so a developer's real
# ~/.claude/settings.json or gh session can never leak into a verdict.
#
# Prose coupling: the doctor has no verdict ids, so cases pin short, ASCII-only verdict STEMS
# (stop before its em dashes) plus machine-derived payloads — settings.json is always derived
# from the real template via jq, and the stub gh's labels come from bin/setup-labels.sh via the
# same sed idiom dev/selfcheck.sh's 4.6 uses. The stems themselves are the one hand-typed
# coupling left.
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

if ! command -v jq >/dev/null 2>&1; then
  echo "  FAIL  jq not installed — required to derive fixture settings.json variants from templates/repo-settings.json"
  exit 1
fi

# Captured before any PATH is handed to a fixture run — this process's own PATH is never
# mutated, only passed as an explicit PATHVAL to run_doctor's subprocess.
bash_bin="$(command -v bash)"

pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------------------------
# Fixture builders.

# write_settings DIR MODE — derives DIR/.claude/settings.json from the REAL
# templates/repo-settings.json via jq, so drift/merge payloads stay meaningful (never a
# hand-typed JSON blob that could drift from the template's actual shape).
write_settings() {
  local dir="$1" mode="$2" tmpl="$root/templates/repo-settings.json" out="$1/.claude/settings.json"
  case "$mode" in
    verbatim)
      jq '.' "$tmpl" > "$out" ;;
    unparseable)
      jq '.' "$tmpl" > "$out"
      printf '\nthis line is not valid JSON and breaks the parse\n' >> "$out" ;;
    drift)
      jq '.permissions.allow |= map(select(. != "Bash(git commit:*)")) |
          .permissions.deny  |= map(select(. != "Bash(git -C * clean*)"))' "$tmpl" > "$out" ;;
    merge-deny-lifted)
      jq '.permissions.deny |= map(select(. != "Bash(gh pr merge:*)"))' "$tmpl" > "$out" ;;
    merge-allow-only)
      jq '.permissions.deny  |= map(select(. != "Bash(gh pr merge:*)")) |
          .permissions.allow += ["Bash(gh pr merge:*)"]' "$tmpl" > "$out" ;;
    merge-mention-only)
      jq '.permissions.deny |= map(select(. != "Bash(gh pr merge:*)")) |
          . + {".env.NOTE": "mentions Bash(gh pr merge:*) here only, never in permissions.allow"}' "$tmpl" > "$out" ;;
  esac
}

# mk_repo NAME VARIANT MODE — builds a fixture under $tmpbase/NAME: a fresh git repo with a
# fake, local-only origin remote, a private copy of the doctor + its template (own bin/ +
# templates/), home/ + claudecfg/ for HOME/CLAUDE_CONFIG_DIR isolation, a CLAUDE.md with a
# Verification heading plus VARIANT's optional policy section (merge|ratchet|none for base), and
# .claude/settings.json via write_settings — unless MODE is "missing". Prints the fixture path.
mk_repo() {
  local name="$1" variant="$2" mode="$3"
  local dir="$tmpbase/$name"
  mkdir -p "$dir/bin" "$dir/templates" "$dir/.claude" "$dir/home" "$dir/claudecfg"
  (cd "$dir" && git init -q && git remote add origin https://example.invalid/acme/demo.git)
  cp "$root/bin/check-harness.sh" "$dir/bin/check-harness.sh"
  chmod +x "$dir/bin/check-harness.sh"
  cp "$root/bin/check-decision-record.sh" "$dir/bin/check-decision-record.sh"
  chmod +x "$dir/bin/check-decision-record.sh"
  cp "$root/templates/repo-settings.json" "$dir/templates/repo-settings.json"
  {
    printf '# CLAUDE.md\n\n## Verification\n\nRun `true` to verify. (fixture stub)\n'
    case "$variant" in
      merge)   printf '\n## Merge autonomy policy\n\nThe cycle may merge fixture PRs. (fixture stub policy)\n' ;;
      ratchet) printf '\n## Test-suite ratchet policy\n\nMeasure with `tbf-boobytrap --cov`. (fixture stub policy)\n' ;;
      merge-postdeploy)
        cat <<'EOF'

## Merge autonomy policy

The cycle may merge fixture PRs. (fixture stub policy)

### Post-merge verification

```
tbf-boobytrap --smoke
```
EOF
        ;;
      scoped)
        cat <<'EOF'

## Autonomy reserve
```
CLAUDE.md
.claude/**
```

## Autonomy decision record
```
grant-label: scoped-autonomy
record-section: Binding decisions
element: Escalation triggers
element: Migration posture
element: Worked example
```
EOF
        ;;
      scoped-record-only)
        cat <<'EOF'

## Autonomy decision record
```
grant-label: scoped-autonomy
record-section: Binding decisions
element: Escalation triggers
element: Migration posture
element: Worked example
```
EOF
        ;;
      record-comment)
        cat <<'EOF'

## Autonomy decision record
```
grant-label: scoped-autonomy
record-section: Binding decisions
element: Escalation triggers
# the two below were added 2026-08
element: Migration posture
element: Rollback plan
```
EOF
        ;;
    esac
  } > "$dir/CLAUDE.md"
  [ "$mode" = missing ] || write_settings "$dir" "$mode"
  printf '%s' "$dir"
}

# build_stub_gh DIR [BRANCH] [EXTRA_LABEL] — a deterministic, offline gh: auth always succeeds;
# repo view returns the fixture's fake nameWithOwner and BRANCH (default "main") as
# defaultBranchRef; label list returns the seven lifecycle labels (extracted from
# bin/setup-labels.sh via the same sed idiom dev/selfcheck.sh's 4.6 uses — no second hard-coded
# copy) plus EXTRA_LABEL, if given (so a fixture repo can "have" a scoped-autonomy grant label);
# issue view returns DIR/gh-issue-body.json verbatim (a case writes that file before calling
# check-decision-record.sh against this stub); api (branch protection) succeeds; anything else
# fails. FAIL-free by design — no real network call, no gh-driven FAIL, ever, which is what makes
# the WARN-never-affects-exit pin (drift-missing-entries) meaningful.
build_stub_gh() {
  local dir="$1" branch="${2:-main}" extra_label="${3:-}"
  mkdir -p "$dir"
  sed -nE 's/^create_or_update "([^"]+)".*/\1/p' "$root/bin/setup-labels.sh" | sort -u > "$dir/gh-labels.txt"
  [ -n "$extra_label" ] && printf '%s\n' "$extra_label" >> "$dir/gh-labels.txt"
  { printf '#!%s\n' "$bash_bin"; cat <<'EOF'
case "$1" in
  auth) exit 0 ;;
EOF
  printf '  repo) case "$*" in *nameWithOwner*) echo acme/demo ;; *) echo %s ;; esac; exit 0 ;;\n' "$branch"
  printf '  label) cat "%s/gh-labels.txt"; exit 0 ;;\n' "$dir"
  printf '  issue) cat "%s/gh-issue-body.json"; exit 0 ;;\n' "$dir"
  printf '  api) exit 0 ;;\n  *) exit 1 ;;\nesac\n'
  } > "$dir/gh"
  chmod +x "$dir/gh"
}

# ---------------------------------------------------------------------------------------------
# Runner + assertion helpers.

# run_doctor DIR PATHVAL — runs the fixture's OWN copy of the doctor with HOME/CLAUDE_CONFIG_DIR
# pointed into the fixture and PATH set to PATHVAL, leaving $doctor_out/$doctor_rc set as
# globals. Deliberately NOT invoked via command substitution itself (same idiom as
# dev/selfcheck-tests.sh's run_gate) — call as a plain statement and read the globals after.
doctor_out=""
doctor_rc=0
run_doctor() {
  local dir="$1" pathval="$2"
  doctor_out="$(cd "$dir" && HOME="$dir/home" CLAUDE_CONFIG_DIR="$dir/claudecfg" PATH="$pathval" "$bash_bin" "$dir/bin/check-harness.sh" 2>&1)"
  doctor_rc=$?
}

# run_record_check DIR PATHVAL ISSUE — same idiom as run_doctor (a plain statement, never a
# command substitution), running the fixture's own copy of bin/check-decision-record.sh against
# ISSUE; leaves $doctor_out/$doctor_rc set, so the same expect/expect_rc/expect_absent helpers
# apply unchanged.
run_record_check() {
  local dir="$1" pathval="$2" issue="$3"
  doctor_out="$(cd "$dir" && HOME="$dir/home" CLAUDE_CONFIG_DIR="$dir/claudecfg" PATH="$pathval" "$bash_bin" "$dir/bin/check-decision-record.sh" "$issue" 2>&1)"
  doctor_rc=$?
}

# expect/expect_absent/expect_rc/expect_no_file — assert against $doctor_out/$doctor_rc, setting
# $__ok=0 and appending to $__why on failure. ASCII-only short stems: stop before the doctor's
# em dashes.
__ok=1
__why=""
expect() {
  printf '%s\n' "$doctor_out" | grep -qF -- "$1" || { __ok=0; __why="${__why}missing: $1\n"; }
}
expect_absent() {
  printf '%s\n' "$doctor_out" | grep -qF -- "$1" && { __ok=0; __why="${__why}unexpected: $1\n"; }
}
expect_rc() {
  [ "$doctor_rc" -eq "$1" ] || { __ok=0; __why="${__why}rc: expected $1, got $doctor_rc\n"; }
}
expect_no_file() {
  [ ! -e "$1" ] || { __ok=0; __why="${__why}unexpected file present: $1\n"; }
}

# ---------------------------------------------------------------------------------------------
# The 20 cases. Every fixture also emits the LESSONS.md auto-seed line and a no-baseline WARN —
# expected, deliberately unasserted below.

case_settings_missing() {
  local dir; dir="$(mk_repo settings-missing base missing)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 1
  expect "no .claude/settings.json"
  expect "merge autonomy: activation state unknown"
}

case_settings_unparseable() {
  local dir; dir="$(mk_repo settings-unparseable base unparseable)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 1
  expect "does not parse as JSON"
  expect "merge autonomy: activation state unknown"
}

case_settings_parsed() {
  local dir; dir="$(mk_repo settings-parsed base verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "permissions match the plugin's template"
  expect "merge autonomy: off"
  expect "scoped autonomy: off"
}

case_drift_missing_entries() {
  local dir; dir="$(mk_repo drift-missing-entries base drift)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "Bash(git commit:*)"
  expect "Bash(git -C * clean*)"
}

case_drift_merge_deny_lifted() {
  local dir; dir="$(mk_repo drift-merge-deny-lifted base merge-deny-lifted)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect_absent "deny-list missing"
  expect "permissions match the plugin's template"
}

case_template_missing() {
  local dir; dir="$(mk_repo template-missing base verbatim)"
  rm -f "$dir/templates/repo-settings.json"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "could not read the plugin's templates/repo-settings.json"
  expect_absent "deny-list missing"
  expect_absent "allow-list missing"
}

case_ratchet_never_executes() {
  local dir; dir="$(mk_repo ratchet-never-executes ratchet verbatim)"
  local trapdir="$dir/boobytrap-bin" sentinel="$dir/sentinel-touched"
  mkdir -p "$trapdir"
  { printf '#!%s\n' "$bash_bin"; printf 'touch %s\n' "$sentinel"; } > "$trapdir/tbf-boobytrap"
  chmod +x "$trapdir/tbf-boobytrap"
  run_doctor "$dir" "$stub_gh_dir:$trapdir:$PATH"
  expect_rc 0
  expect_no_file "$sentinel"
  expect "tbf-boobytrap"
}

case_merge_allow_only() {
  local dir; dir="$(mk_repo merge-allow-only merge merge-allow-only)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "merge autonomy: active"
  expect_absent "half-activated"
  expect "no checks configured"
}

case_merge_postdeploy() {
  local dir; dir="$(mk_repo merge-postdeploy merge-postdeploy merge-allow-only)"
  local trapdir="$dir/boobytrap-bin" sentinel="$dir/sentinel-touched"
  mkdir -p "$trapdir"
  { printf '#!%s\n' "$bash_bin"; printf 'touch %s\n' "$sentinel"; } > "$trapdir/tbf-boobytrap"
  chmod +x "$trapdir/tbf-boobytrap"
  run_doctor "$dir" "$stub_gh_dir:$trapdir:$PATH"
  expect_rc 0
  expect "merge autonomy: active"
  expect_absent "half-activated"
  expect_no_file "$sentinel"
}

case_merge_ci_present() {
  local dir; dir="$(mk_repo merge-ci-present merge merge-allow-only)"
  mkdir -p "$dir/.github/workflows"
  printf 'name: ci\non: [pull_request]\njobs: {}\n' > "$dir/.github/workflows/ci.yml"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "merge autonomy: active"
  expect_absent "no checks configured"
}

case_merge_deny_only() {
  local dir; dir="$(mk_repo merge-deny-only merge verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "half-activated"
  expect_absent "merge autonomy: active"
}

case_merge_deny_local_only() {
  local dir; dir="$(mk_repo merge-deny-local-only merge merge-deny-lifted)"
  local label=".claude/settings.local.json"
  jq '{permissions: {deny: [.permissions.deny[] | select(. == "Bash(gh pr merge:*)")]}}' \
    "$dir/templates/repo-settings.json" > "$dir/$label"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "half-activated"
  expect "permissions.deny in $label"
}

case_merge_mention_only() {
  local dir; dir="$(mk_repo merge-mention-only merge merge-mention-only)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "no matching allow entry"
  expect_absent "merge autonomy: active"
}

case_guard_coverage_offbranch() {
  local dir; dir="$(mk_repo guard-coverage-offbranch base verbatim)"
  run_doctor "$dir" "$stub_gh_alt_dir:$PATH"
  expect_rc 0
  expect "default-branch guard coverage: '$alt_branch' is missing deny entries:"
  while IFS= read -r op; do
    [ -n "$op" ] || continue
    expect "Bash(git $op $alt_branch:*)"
    expect "Bash(git -C * $op $alt_branch*)"
  done <<EOF
$tmpl_branch_ops
EOF
}

# record_body TEXT_LINES — writes a synthetic issue body to $tmpbase/<caller-provided path> via
# jq -Rs '{body: .}', never a hand-escaped JSON literal (see the header's fixture contract note).
# Callers pass the destination gh-stub directory; this writes DIR/gh-issue-body.json.
write_record_body() {
  local ghdir="$1" text="$2"
  printf '%s\n' "$text" > "$tmpbase/record-body-src.txt"
  jq -Rs '{body: .}' "$tmpbase/record-body-src.txt" > "$ghdir/gh-issue-body.json"
}

case_record_complete() {
  local dir; dir="$(mk_repo record-complete scoped verbatim)"
  local ghdir="$tmpbase/record-complete-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Migration posture
text

### Worked example
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 0
  expect "PASS  section: Binding decisions"
  expect "PASS  element: Escalation triggers"
  expect "PASS  element: Migration posture"
  expect "PASS  element: Worked example"
  expect_absent "FAIL"
}

case_record_missing_element() {
  local dir; dir="$(mk_repo record-missing-element scoped verbatim)"
  local ghdir="$tmpbase/record-missing-element-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Worked example
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "PASS  element: Escalation triggers"
  expect "FAIL  element: Migration posture"
  expect "PASS  element: Worked example"
}

case_record_no_declaration() {
  local dir; dir="$(mk_repo record-no-declaration base verbatim)"
  local ghdir="$tmpbase/record-no-declaration-gh"
  build_stub_gh "$ghdir"
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 2
  expect_absent "PASS  element:"
  expect_absent "FAIL  element:"
}

case_record_comment_preserved() {
  local dir; dir="$(mk_repo record-comment-preserved record-comment verbatim)"
  local ghdir="$tmpbase/record-comment-preserved-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Migration posture
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "PASS  element: Escalation triggers"
  expect "PASS  element: Migration posture"
  expect "FAIL  element: Rollback plan"
}

case_scoped_declared() {
  local dir; dir="$(mk_repo scoped-declared scoped verbatim)"
  run_doctor "$dir" "$stub_gh_scoped_dir:$PATH"
  expect_rc 0
  expect "scoped autonomy: declared"
  expect_absent "scoped autonomy: off"
  expect_absent "no 'Autonomy reserve' section"
  expect_absent "no 'Autonomy decision record' section"
}

case_scoped_reserve_missing() {
  local dir; dir="$(mk_repo scoped-reserve-missing scoped-record-only verbatim)"
  run_doctor "$dir" "$stub_gh_scoped_dir:$PATH"
  expect_rc 0
  expect "no 'Autonomy reserve' section"
  expect_absent "scoped autonomy: off"
}

# ---------------------------------------------------------------------------------------------
stub_gh_dir="$tmpbase/stub-gh"
build_stub_gh "$stub_gh_dir"

# Third stub gh that additionally reports the "scoped-autonomy" grant label as existing, for the
# scoped-* cases above.
stub_gh_scoped_dir="$tmpbase/stub-gh-scoped"
build_stub_gh "$stub_gh_scoped_dir" "main" "scoped-autonomy"

# Second stub gh reporting a default branch the template does NOT guard, for
# guard-coverage-offbranch — trunk, which must differ from the branch the template's
# branch-scoped denies name (main).
alt_branch="trunk"
stub_gh_alt_dir="$tmpbase/stub-gh-alt"
build_stub_gh "$stub_gh_alt_dir" "$alt_branch"

# The operations templates/repo-settings.json's branch-scoped bare deny entries guard for
# "main" — same jq-then-sed idiom build_stub_gh uses for labels — so guard-coverage-offbranch's
# expectations are derived from the real template, never a second hard-coded copy.
tmpl_branch_ops="$(jq -r '.permissions.deny[]? // empty' "$root/templates/repo-settings.json" \
  | sed -n 's/^Bash(git \(.*\) main:\*)$/\1/p' | sort -u)"

# name|fn|desc
cases=(
  "settings-missing|case_settings_missing|settings block: file missing"
  "settings-unparseable|case_settings_unparseable|settings block: invalid JSON"
  "settings-parsed|case_settings_parsed|settings block: verbatim template (clean control)"
  "drift-missing-entries|case_drift_missing_entries|template-diff: one allow + one deny entry missing"
  "drift-merge-deny-lifted|case_drift_merge_deny_lifted|template-diff: merge deny excluded from drift"
  "template-missing|case_template_missing|template-diff: fixture's own template deleted"
  "ratchet-never-executes|case_ratchet_never_executes|ratchet measurement command is looked up, never executed"
  "merge-allow-only|case_merge_allow_only|entry_has: merge rule in allow only"
  "merge-postdeploy|case_merge_postdeploy|post-merge verification sub-block: identical merge-autonomy verdict, declared command never executed"
  "merge-ci-present|case_merge_ci_present|merge verdict: no-CI note absent when a workflow file exists"
  "merge-deny-only|case_merge_deny_only|entry_has: merge rule in deny only"
  "merge-deny-local-only|case_merge_deny_local_only|merge verdict: half-activated remediation names the file holding the deny (settings.local.json)"
  "merge-mention-only|case_merge_mention_only|entry_has: 'only' inside an unrelated JSON string"
  "guard-coverage-offbranch|case_guard_coverage_offbranch|default-branch guard coverage: WARN when the repo's default branch is one the template doesn't guard"
  "record-complete|case_record_complete|check-decision-record.sh: every declared element present, rc 0"
  "record-missing-element|case_record_missing_element|check-decision-record.sh: one declared element missing, rc 1, named"
  "record-no-declaration|case_record_no_declaration|check-decision-record.sh: no 'Autonomy decision record' section, rc 2"
  "record-comment-preserved|case_record_comment_preserved|check-decision-record.sh: a '#' comment inside the fenced block does not truncate it, later elements still checked"
  "scoped-declared|case_scoped_declared|scoped autonomy: declared PASS when both declarations and the grant label exist"
  "scoped-reserve-missing|case_scoped_reserve_missing|scoped autonomy: WARN when the reserve declaration is missing, rc still 0"
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
