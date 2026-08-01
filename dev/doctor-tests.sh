#!/usr/bin/env bash
#
# doctor-tests.sh — fixture-based negative-test harness for the CONSUMER doctor
# (bin/check-harness.sh), not this repo's own gate (that's dev/selfcheck.sh +
# dev/selfcheck-tests.sh). Builds throwaway git repos under mktemp, runs a COPY of the real
# doctor against each, and pins verdicts that were previously only hand-verified: the four-way
# settings.json block, the template-diff scenarios, the ratchet's never-execute guarantee,
# entry_has's allow/deny distinction, and the active verdict's no-CI note.
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
  cp "$root/templates/repo-settings.json" "$dir/templates/repo-settings.json"
  {
    printf '# CLAUDE.md\n\n## Verification\n\nRun `true` to verify. (fixture stub)\n'
    case "$variant" in
      merge)   printf '\n## Merge autonomy policy\n\nThe cycle may merge fixture PRs. (fixture stub policy)\n' ;;
      ratchet) printf '\n## Test-suite ratchet policy\n\nMeasure with `tbf-boobytrap --cov`. (fixture stub policy)\n' ;;
    esac
  } > "$dir/CLAUDE.md"
  [ "$mode" = missing ] || write_settings "$dir" "$mode"
  printf '%s' "$dir"
}

# build_stub_gh DIR — a deterministic, offline gh: auth always succeeds; repo view returns the
# fixture's fake nameWithOwner/defaultBranchRef; label list returns the seven lifecycle labels
# (extracted from bin/setup-labels.sh via the same sed idiom dev/selfcheck.sh's 4.6 uses — no
# second hard-coded copy); api (branch protection) succeeds; anything else fails. FAIL-free by
# design — no real network call, no gh-driven FAIL, ever, which is what makes the
# WARN-never-affects-exit pin (drift-missing-entries) meaningful.
build_stub_gh() {
  local dir="$1"
  mkdir -p "$dir"
  sed -nE 's/^create_or_update "([^"]+)".*/\1/p' "$root/bin/setup-labels.sh" | sort -u > "$dir/gh-labels.txt"
  { printf '#!%s\n' "$bash_bin"; cat <<'EOF'
case "$1" in
  auth) exit 0 ;;
  repo) case "$*" in *nameWithOwner*) echo acme/demo ;; *) echo main ;; esac; exit 0 ;;
EOF
  printf '  label) cat "%s/gh-labels.txt"; exit 0 ;;\n' "$dir"
  printf '  api) exit 0 ;;\n  *) exit 1 ;;\nesac\n'
  } > "$dir/gh"
  chmod +x "$dir/gh"
}

# build_exclusive_bin DIR — wrapper scripts (absolute-path exec, baked from this process's own
# real PATH before it's handed to any fixture) for every external command the doctor needs
# besides jq and gh. Used only by settings-nojq, whose PATH is exactly this dir plus the stub-gh
# dir — nothing else — so a real jq on the developer's machine can't leak in and mask that FAIL.
build_exclusive_bin() {
  local dir="$1" t p
  mkdir -p "$dir"
  for t in git awk sed grep find sort tr head wc mkdir chmod cat basename dirname uname; do
    p="$(command -v "$t" 2>/dev/null)"
    if [ -z "$p" ]; then
      echo "  FAIL  doctor-tests.sh setup: command -v $t returned empty while building the exclusive PATH"
      exit 1
    fi
    printf '#!%s\nexec %s "$@"\n' "$bash_bin" "$p" > "$dir/$t"
    chmod +x "$dir/$t"
  done
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
# The 12 cases. Every fixture also emits the LESSONS.md auto-seed line and a no-baseline WARN —
# expected, deliberately unasserted below.

case_settings_missing() {
  local dir; dir="$(mk_repo settings-missing base missing)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 1
  expect "no .claude/settings.json"
  expect "merge autonomy: activation state unknown"
}

case_settings_nojq() {
  local dir; dir="$(mk_repo settings-nojq base verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$exclusive_bin_dir"
  expect_rc 1
  expect "jq not installed"
  expect "skipped the .claude/settings.json permission checks"
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

case_merge_mention_only() {
  local dir; dir="$(mk_repo merge-mention-only merge merge-mention-only)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "no matching allow entry"
  expect_absent "merge autonomy: active"
}

# ---------------------------------------------------------------------------------------------
stub_gh_dir="$tmpbase/stub-gh"
build_stub_gh "$stub_gh_dir"
exclusive_bin_dir="$tmpbase/exclusive-bin"
build_exclusive_bin "$exclusive_bin_dir"

# name|fn|desc
cases=(
  "settings-missing|case_settings_missing|four-way settings block: file missing"
  "settings-nojq|case_settings_nojq|four-way settings block: jq unavailable (exclusive PATH)"
  "settings-unparseable|case_settings_unparseable|four-way settings block: invalid JSON"
  "settings-parsed|case_settings_parsed|four-way settings block: verbatim template (clean control)"
  "drift-missing-entries|case_drift_missing_entries|template-diff: one allow + one deny entry missing"
  "drift-merge-deny-lifted|case_drift_merge_deny_lifted|template-diff: merge deny excluded from drift"
  "template-missing|case_template_missing|template-diff: fixture's own template deleted"
  "ratchet-never-executes|case_ratchet_never_executes|ratchet measurement command is looked up, never executed"
  "merge-allow-only|case_merge_allow_only|entry_has: merge rule in allow only"
  "merge-ci-present|case_merge_ci_present|merge verdict: no-CI note absent when a workflow file exists"
  "merge-deny-only|case_merge_deny_only|entry_has: merge rule in deny only"
  "merge-mention-only|case_merge_mention_only|entry_has: 'only' inside an unrelated JSON string"
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
