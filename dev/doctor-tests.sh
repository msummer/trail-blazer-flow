#!/usr/bin/env bash
#
# doctor-tests.sh — fixture-based negative-test harness for the CONSUMER doctor
# (bin/check-harness.sh) and its scoped-autonomy companion script (bin/check-decision-record.sh),
# not this repo's own gate (that's dev/selfcheck.sh + dev/selfcheck-tests.sh). Builds throwaway
# git repos under mktemp, runs a COPY of the real scripts against each, and pins verdicts that
# were previously only hand-verified: the settings.json block, the template-diff scenarios, the
# ratchet's never-execute guarantee, entry_has's allow/deny distinction, the active verdict's
# no-CI note, default-branch guard coverage, the half-activated remediation's file naming, the
# scoped-autonomy declarations (the doctor's verdict block and check-decision-record.sh's
# per-element PASS/FAIL report — a fence-aware, depth-aware scan that requires each declared
# heading to be found nested under the record-section heading (strictly deeper, before the next
# same-or-shallower heading outside a fence — a same-depth heading is not nested) AND to have at
# least one non-blank content line in its in-section span, distinguishing "heading absent" from
# "heading found outside the record section" from "heading found, no content under it";
# counting content under a deeper sub-heading or inside a fenced block; requiring whitespace
# after the heading's '#' run; and tracking backtick- and tilde-fences of any matching length,
# indented up to 3 spaces, closing only on a same-character run at least as long followed by
# nothing but whitespace), the
# post-merge-verification declaration-state line (declared
# count / no-fence WARN / not-declared, with the same never-execute guarantee as the ratchet) and
# its allow-entry check (each declared command's first token against the three-file settings
# allow-list union — .claude/settings.json, .claude/settings.local.json, and the user-level
# settings file, so a grant that lives only in .claude/settings.local.json or the user-level file
# still counts as covered — a pure string comparison, WARN never FAIL when a grant is missing),
# the path-qualified verification interpreter's literal-path grant check against that same
# three-file union, the test-suite ratchet's fence-aware, depth-aware section slice and
# fence-delimiter-skipping span hunt (a '#' comment inside the fenced block must not truncate it,
# nor must a bare fence line itself be mistaken for the quoted command), the verification
# baseline's short-SHA-as-prefix compare (an abbreviated recorded commit of 7+ hex characters is
# accepted; fewer is a malformed-value WARN), the disableAllHooks: true WARN across the three
# settings files (#150 — silently disables the plugin's git -C guard hook, and every other hook),
# and the stale-legacy-'-C'-allow-entry WARN on .claude/settings.json (#150 — the entries the
# guard hook now supersedes).
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
    verify-path-grant)
      # Drops the bare "Bash(pytest:*)" template entry and replaces it with a literal-path grant
      # for THIS fixture's own venv interpreter (same $dir the CLAUDE.md fenced block's token is
      # built from — see mk_repo's verify-path-python variant) — deliberate, so the case proves
      # the path grant alone satisfies the Python toolchain check, with no bare-name entry left
      # to pass it by coincidence. This also re-raises the pre-existing allow-drift WARN (a
      # template entry is now missing); that WARN is expected and deliberately unasserted by the
      # cases that use this mode.
      jq --arg e "Bash($dir/.venv/bin/python:*)" \
        '.permissions.allow |= (map(select(. != "Bash(pytest:*)")) + [$e])' "$tmpl" > "$out" ;;
    postdeploy-grant)
      # merge-allow-only plus a grant for the boobytrap command the merge-postdeploy variant's
      # fenced block declares, so the post-merge allow-entry check (#138/#142) finds every
      # declared token covered.
      jq '.permissions.deny  |= map(select(. != "Bash(gh pr merge:*)")) |
          .permissions.allow += ["Bash(gh pr merge:*)", "Bash(tbf-boobytrap:*)"]' "$tmpl" > "$out" ;;
    stale-c-allow)
      # #150 deleted the nine `Bash(git -C * <sub> *)` allow entries from the live template, so
      # this fixture re-adds two of them by hand (necessarily a literal here — $tmpl no longer
      # carries any to copy from) to prove the doctor's stale-entry WARN fires on a repo that
      # never re-synced its settings.json after picking up the guard hook.
      jq '.permissions.allow += ["Bash(git -C * status *)", "Bash(git -C * push *)"]' "$tmpl" > "$out" ;;
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
      ratchet-fenced)
        # Fence-aware-slice + fence-delimiter-skip regression pin (#137/#142,
        # .claude/LESSONS.md 2026-08-21): the "# a comment ..." line sits BETWEEN two data lines
        # inside the fenced block (not a heading, even though it starts with '#'), and the
        # backtick-quoted measurement command comes AFTER the fenced block closes — if it came
        # first, the old non-fence-aware slice would find it too and this case would not be a
        # regression pin.
        cat <<'EOF'

## Test-suite ratchet policy

Example measurement output:

```
lines 100
# a comment between two data lines
lines 200
```

Measure with `tbf-boobytrap --cov`. (fixture stub policy)
EOF
        ;;
      merge-postdeploy)
        # The fenced block's "# comment" line between two commands is the fence-awareness pin
        # .claude/LESSONS.md requires: a non-fence-aware section slice would read it as a
        # heading-shaped line and truncate before "tbf-boobytrap --health", undercounting the
        # declared-state line's non-blank-line count (3, not 2).
        cat <<'EOF'

## Merge autonomy policy

The cycle may merge fixture PRs. (fixture stub policy)

### Post-merge verification

```
tbf-boobytrap --smoke
# comment
tbf-boobytrap --health
```
EOF
        ;;
      merge-postdeploy-nofence)
        cat <<'EOF'

## Merge autonomy policy

The cycle may merge fixture PRs. (fixture stub policy)

### Post-merge verification

Prose only — a fenced block was never added.
EOF
        ;;
      verify-path-python)
        # No heading of its own: lands inside the base "## Verification" section above. The
        # interpreter token is built from $dir with printf, not a quoted heredoc, so it expands
        # (a quoted heredoc would emit the literal string "$dir"). The "# comment" line between
        # "pytest -q" and the path-qualified interpreter is the same fence-awareness pin as
        # merge-postdeploy's, for the verification-scope slice.
        printf '\n```\npytest -q\n# comment\n%s/.venv/bin/python -m pytest\n```\n' "$dir"
        ;;
      verify-bare-python)
        printf '\n```\npytest -q\n```\n'
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

# seed_commit DIR — records a local identity with gpgsign off (same idiom as
# dev/cleanup-tests.sh:66-78, so CI runners with no global git identity work), forces the branch
# name to "main" before the first commit (portable regardless of the machine's
# init.defaultBranch — a no-op on later calls, since HEAD already points there), and creates one
# empty commit. May be called more than once per fixture to build a short history. Prints the new
# HEAD SHA.
seed_commit() {
  local dir="$1"
  (
    cd "$dir" &&
    git config user.name "doctor-tests" &&
    git config user.email "doctor-tests@example.invalid" &&
    git config commit.gpgsign false &&
    git symbolic-ref HEAD refs/heads/main &&
    git commit -q --allow-empty -m "fixture commit"
  ) >/dev/null
  (cd "$dir" && git rev-parse HEAD)
}

# point_origin_ref DIR SHA — makes `git rev-parse origin/main` resolve entirely offline by
# writing the remote-tracking ref directly. No bare clone, push, or fetch is needed: mk_repo's
# origin URL (https://example.invalid/acme/demo.git) is deliberately unreachable, and this never
# touches it.
point_origin_ref() {
  local dir="$1" sha="$2"
  (cd "$dir" && git update-ref refs/remotes/origin/main "$sha")
}

# write_baseline DIR SHA_TEXT — writes DIR/.claude/BASELINE.md in harness-setup's documented
# shape (skills/harness-setup/SKILL.md), with the '- commit:' line carrying trailing prose after
# the SHA text (the real-world #141 report showed exactly this shape, and the doctor's `sed`
# extraction is tolerant of it), and appends .claude/BASELINE.md to DIR/.gitignore so the
# fixture also takes the gitignored-PASS branch instead of the unrelated "not gitignored" WARN.
write_baseline() {
  local dir="$1" sha_text="$2"
  cat > "$dir/.claude/BASELINE.md" <<EOF
# Verification baseline (harness-maintained)

The last known-green run of the project's verification commands on the default branch,
on THIS machine. Written by harness-setup; refreshed automatically by the
issue-implementer / issue-cycle pre-flight whenever the default branch moves past the
recorded commit. Machine-local — keep it gitignored. Do not edit by hand.

- commit: $sha_text (fixture stub)
- branch: main
- date: 2026-01-01
- results:
  - \`true\`: pass
EOF
  printf '.claude/BASELINE.md\n' >> "$dir/.gitignore"
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
# The 47 cases. Every fixture also emits the LESSONS.md auto-seed line — expected, deliberately
# unasserted below. Every fixture except the three baseline-* ones also emits a no-baseline WARN
# (also unasserted); the baseline-* fixtures write their own .claude/BASELINE.md instead, via
# seed_commit/point_origin_ref/write_baseline, so they exercise the baseline compare itself.

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
  # #150 controls: a verbatim-template fixture trips neither new WARN.
  expect_absent "disableAllHooks: true"
  expect_absent "legacy 'Bash(git -C ...)' entries"
}

# hooks-disabled (#150) — disableAllHooks: true in .claude/settings.local.json (a file the
# doctor already reads for the merge-autonomy scan) silently disables the plugin's git -C guard
# hook, and every other hook; WARN, never FAIL.
case_hooks_disabled() {
  local dir; dir="$(mk_repo hooks-disabled base verbatim)"
  printf '{"disableAllHooks": true}' > "$dir/.claude/settings.local.json"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "disableAllHooks: true in .claude/settings.local.json"
}

# stale-c-allows (#150) — .claude/settings.json still carries legacy `Bash(git -C * ...)` allow
# entries the guard hook now supersedes: WARN naming them, never FAIL (the rules still work,
# they're just noisy and superseded — see the startup wildcard warning they trip).
case_stale_c_allows() {
  local dir; dir="$(mk_repo stale-c-allows base stale-c-allow)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "legacy 'Bash(git -C ...)' entries"
  expect "Bash(git -C * status *)"
  expect "Bash(git -C * push *)"
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
  # This fixture's variant is "ratchet" — no "Merge autonomy policy" section at all — so the
  # post-merge-verification declaration-state line (#132/#125) must not print; it would tell a
  # merge-autonomy-off consumer to add a sub-heading under a section they don't have.
  expect_absent "post-merge verification"
}

case_merge_allow_only() {
  local dir; dir="$(mk_repo merge-allow-only merge merge-allow-only)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "merge autonomy: active"
  expect_absent "half-activated"
  expect "no checks configured"
}

# This fixture's settings mode (merge-allow-only) grants no allow entry for "tbf-boobytrap", so
# the post-merge allow-entry check (#138/#142) also fires its missing-grant WARN here — expected
# and deliberately unasserted, same idiom as write_settings's verify-path-grant mode note above.
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
  expect "post-merge verification: declared (3 command line(s))"
}

# postdeploy-no-fence (#132/#125) — "Post-merge verification" heading present with prose only,
# no fenced block: WARN, not a FAIL — the cycle silently skips deploy verification, which is
# exactly the failure this check exists to surface.
case_postdeploy_no_fence() {
  local dir; dir="$(mk_repo postdeploy-no-fence merge-postdeploy-nofence merge-allow-only)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "post-merge verification: heading present but no fenced commands"
}

# postdeploy-absent (#132/#125) — "Merge autonomy policy" present, no "Post-merge verification"
# sub-heading at all: informational PASS, silent-by-design (no extra step, no deploy= field).
case_postdeploy_absent() {
  local dir; dir="$(mk_repo postdeploy-absent merge merge-allow-only)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "post-merge verification: not declared"
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

# verify-path-grant-missing (#132/#128) — the verification section names a path-qualified
# interpreter (<dir>/.venv/bin/python) and settings.json carries the template's bare
# "Bash(pytest:*)" only: WARN naming the exact literal-path entry to add, and the reassuring
# "covers the detected toolchain(s)" PASS is suppressed even though the marker-based Python
# check (pyproject.toml present, bare pytest entry present) would otherwise pass on its own.
case_verify_path_grant_missing() {
  local dir; dir="$(mk_repo verify-path-grant-missing verify-path-python verbatim)"
  : > "$dir/pyproject.toml"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "path-qualified verification interpreter '$dir/.venv/bin/python' has no matching allow entry"
  expect "Bash($dir/.venv/bin/python:*)"
  expect_absent "covers the detected toolchain(s)"
}

# verify-path-grant-present (#132/#128) — same CLAUDE.md, but settings.json carries a
# literal-path grant for that exact interpreter and NO bare-name entry (write_settings's
# verify-path-grant mode drops "Bash(pytest:*)" deliberately): PASS, and the pre-existing Python
# toolchain WARN (pyproject.toml present, no bare pytest/python/uv/poetry entry) does not fire
# even though there is no bare-name entry to satisfy it on its own.
case_verify_path_grant_present() {
  local dir; dir="$(mk_repo verify-path-grant-present verify-path-python verify-path-grant)"
  : > "$dir/pyproject.toml"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "path-qualified verification interpreter '$dir/.venv/bin/python' is covered by a literal-path allow entry"
  expect "covers the detected toolchain(s)"
  expect_absent "Python project files found but no pytest/python/uv/poetry"
}

# verify-path-grant-local-only (#147) — the literal-path grant for the interpreter lives ONLY in
# .claude/settings.local.json, not in the checked-in .claude/settings.json (write_settings's
# verbatim mode leaves only the template's bare "Bash(pytest:*)" entry there): PASS, covered by
# the literal-path allow entry. Pins the three-file union the interpreter probe now reads instead
# of .claude/settings.json alone.
case_verify_path_grant_local_only() {
  local dir; dir="$(mk_repo verify-path-grant-local-only verify-path-python verbatim)"
  jq -n --arg e "Bash($dir/.venv/bin/python:*)" '{permissions:{allow:[$e]}}' > "$dir/.claude/settings.local.json"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "path-qualified verification interpreter '$dir/.venv/bin/python' is covered by a literal-path allow entry"
  expect_absent "has no matching allow entry"
}

# verify-bare-command (#132/#128, control) — the verification section names only a bare
# "pytest -q" (no path-qualified token anywhere), verbatim template settings: unchanged
# behaviour — neither new stem prints, and the pre-existing bare-name PASS still does.
case_verify_bare_command() {
  local dir; dir="$(mk_repo verify-bare-command verify-bare-python verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "covers the detected toolchain(s)"
  expect_absent "path-qualified verification interpreter"
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

# record-fenced-body (#162) — the whole record (section + all three elements) lives only inside
# one fenced code block; the unrelated "## Overview" heading sits outside it. A fence-blind scan
# would find every heading anyway; the fence-aware scan must find none of them.
case_record_fenced_body() {
  local dir; dir="$(mk_repo record-fenced-body scoped verbatim)"
  local ghdir="$tmpbase/record-fenced-body-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Overview

Overview text, outside the fence.

```
## Binding decisions

### Escalation triggers
text

### Migration posture
text

### Worked example
text
```'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "FAIL  section: Binding decisions (no heading found)"
  expect "FAIL  element: Escalation triggers (no heading found)"
  expect "FAIL  element: Migration posture (no heading found)"
  expect "FAIL  element: Worked example (no heading found)"
  expect_absent "PASS  element:"
}

# record-empty-element (#162) — happy body except "### Migration posture" has nothing before the
# next heading: heading found, but no content, must FAIL distinguishably from "heading absent".
case_record_empty_element() {
  local dir; dir="$(mk_repo record-empty-element scoped verbatim)"
  local ghdir="$tmpbase/record-empty-element-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Migration posture

### Worked example
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "PASS  element: Escalation triggers"
  expect "FAIL  element: Migration posture (heading found, no content under it)"
  expect "PASS  element: Worked example"
}

# record-nested-content (#162) — "### Migration posture" is immediately followed by a deeper
# "#### Details" sub-heading, then prose: the prose counts toward the parent element's span.
case_record_nested_content() {
  local dir; dir="$(mk_repo record-nested-content scoped verbatim)"
  local ghdir="$tmpbase/record-nested-content-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Migration posture
#### Details
prose under the sub-heading

### Worked example
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 0
  expect "PASS  element: Migration posture"
  expect_absent "no content under it"
}

# record-fenced-content (#162) — "### Worked example"'s only content is a fenced block whose
# first line looks like a heading ("# not a heading"): the fenced block's inner line counts as
# content (the delimiter lines do not), and the in-fence "#" line must not be read as a heading
# (it stays invisible to the heading scan).
case_record_fenced_content() {
  local dir; dir="$(mk_repo record-fenced-content scoped verbatim)"
  local ghdir="$tmpbase/record-fenced-content-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Migration posture
text

### Worked example
```
# not a heading
fenced content line
```'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 0
  expect "PASS  element: Worked example"
  expect_absent "no content under it"
}

# record-no-space-heading (#162) — the complete record written with no whitespace after the '#'
# run ("#Binding decisions", "###Escalation triggers", ...): none of it counts as a heading,
# matching claude_md_block/claude_md_section's own whitespace-required rule.
case_record_no_space_heading() {
  local dir; dir="$(mk_repo record-no-space-heading scoped verbatim)"
  local ghdir="$tmpbase/record-no-space-heading-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '#Binding decisions

###Escalation triggers
text

###Migration posture
text

###Worked example
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "FAIL  section: Binding decisions (no heading found)"
  expect_absent "PASS  element:"
}

# record-element-outside-section (#177) — "### Worked example" is a real, filled heading, but it
# sits under an unrelated later "## Appendix" section instead of nested under "## Binding
# decisions": it must FAIL distinguishably from both "no heading found" and "no content under
# it". Non-vacuity: method (a) — under the pre-#177 script (no nesting requirement), "Worked
# example" is found anywhere in the body and has content, so it PASSes and the whole check exits
# 0; observed pre-change verdict: rc 0, "PASS  element: Worked example", no FAIL lines at all.
case_record_element_outside_section() {
  local dir; dir="$(mk_repo record-element-outside-section scoped verbatim)"
  local ghdir="$tmpbase/record-element-outside-section-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Migration posture
text

## Appendix

### Worked example
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "PASS  element: Escalation triggers"
  expect "PASS  element: Migration posture"
  expect "FAIL  element: Worked example (heading found outside the record section)"
}

# record-element-sibling-depth (#177) — "## Worked example" is a direct same-depth sibling of
# "## Binding decisions" (no intervening section), pinning the documented "same depth is not
# nested" consequence: the record-section span closes as soon as a same-or-shallower heading is
# seen outside a fence, so a same-depth heading never counts as inside it. Non-vacuity: method
# (a) — the pre-#177 script has no nesting requirement at all, so "Worked example" PASSes;
# observed pre-change verdict: rc 0, "PASS  element: Worked example", no FAIL lines at all.
case_record_element_sibling_depth() {
  local dir; dir="$(mk_repo record-element-sibling-depth scoped verbatim)"
  local ghdir="$tmpbase/record-element-sibling-depth-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Migration posture
text

## Worked example
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "PASS  element: Escalation triggers"
  expect "PASS  element: Migration posture"
  expect "FAIL  element: Worked example (heading found outside the record section)"
}

# record-tilde-fence (#177) — the whole record (section + all three filled elements) lives only
# inside a '~~~' block; the unrelated "## Overview" heading sits outside it. The pre-#177 fence
# tracker only recognises backtick runs, so a '~~~' fence is invisible to it and every heading
# inside leaks through as if it were outside any fence. Non-vacuity: method (a) — observed
# pre-change verdict: rc 0, every heading (section + all three elements) PASSes, no FAIL lines.
case_record_tilde_fence() {
  local dir; dir="$(mk_repo record-tilde-fence scoped verbatim)"
  local ghdir="$tmpbase/record-tilde-fence-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Overview

Overview text, outside the fence.

~~~
## Binding decisions

### Escalation triggers
text

### Migration posture
text

### Worked example
text
~~~'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "FAIL  section: Binding decisions (no heading found)"
  expect "FAIL  element: Escalation triggers (no heading found)"
  expect "FAIL  element: Migration posture (no heading found)"
  expect "FAIL  element: Worked example (no heading found)"
  expect_absent "PASS  element:"
}

# record-nested-fence (#177) — a four-backtick-opened block (info string "markdown") whose
# content includes an inner, unmatched three-backtick line before the record and another right
# after it, before the real four-backtick closer; the record itself lives between them. The
# pre-#177 tracker toggles on ANY run of 3+ backticks regardless of length, so the inner
# three-backtick line right after the opener flips it back to "outside a fence" — leaking the
# whole record's headings through — and the second inner three-backtick line flips it "inside"
# again just before the real closer. The new fence-length-aware tracker requires a closer at
# least as long as the four-backtick opener, so neither inner three-backtick line closes it and
# the record stays hidden throughout. Non-vacuity: method (a) — observed pre-change verdict: rc
# 0, every heading (section + all three elements) PASSes, no FAIL lines.
case_record_nested_fence() {
  local dir; dir="$(mk_repo record-nested-fence scoped verbatim)"
  local ghdir="$tmpbase/record-nested-fence-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Overview

Overview text, outside the fence.

````markdown
```
## Binding decisions

### Escalation triggers
text

### Migration posture
text

### Worked example
text
```
````'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "FAIL  section: Binding decisions (no heading found)"
  expect "FAIL  element: Escalation triggers (no heading found)"
  expect "FAIL  element: Migration posture (no heading found)"
  expect "FAIL  element: Worked example (no heading found)"
  expect_absent "PASS  element:"
}

# record-indented-fence (#177) — the whole record lives inside a 2-space-indented '```' fence
# (opener and closer both indented; the record's own headings sit at column 0 inside it). The
# leading spaces on the fence lines are load-bearing source text, not formatting — do not
# reindent this heredoc. The pre-#177 tracker requires the fence delimiter at column 0
# (`/^```/`), so an indented delimiter is never recognised as a fence at all, and the scan runs
# the whole body as if it were never fenced — every heading (inside the "fence" and out) is found
# and, since it has following text or a nested heading, filled. Non-vacuity: method (a) —
# observed pre-change verdict: rc 0, every heading PASSes, no FAIL lines.
case_record_indented_fence() {
  local dir; dir="$(mk_repo record-indented-fence scoped verbatim)"
  local ghdir="$tmpbase/record-indented-fence-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Overview

- a list item

  ```
## Binding decisions

### Escalation triggers
text

### Migration posture
text

### Worked example
text
  ```'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "FAIL  section: Binding decisions (no heading found)"
  expect "FAIL  element: Escalation triggers (no heading found)"
  expect "FAIL  element: Migration posture (no heading found)"
  expect "FAIL  element: Worked example (no heading found)"
  expect_absent "PASS  element:"
}

# record-fence-close-rules (#177) — control case, all PASS: pins that the stricter closing rule
# genuinely closes (a broken closer would swallow every later element as "no heading found") and
# that a wrong-character run and an info-string run never close a fence early. "Escalation
# triggers"'s content is a '```' block containing a same-char, same-length run followed by an
# info string ("```js", must not close) and a wrong-character run ("~~~ still inside", must not
# close), then a real closer. "Migration posture"'s content is a '~~~' block containing a
# wrong-character run ("``` still inside", must not close), then a real closer. "Worked example"
# has plain text, no fence at all. Non-vacuity: method (a) — the pre-#177 tracker toggles on
# every 3+-backtick run regardless of character or trailing text ('~~~' runs never toggle it,
# only tilde-prefixed lines were ever invisible to it in other fixtures above), so "```js" inside
# "Escalation triggers"'s block toggles it back "outside" mid-block, the block's own closing
# "```" toggles it "inside" again, and "### Migration posture" is then read while "inside" — its
# heading pattern is gated on being outside a fence, so the line is swallowed as ordinary content
# instead of recorded as a heading at all, and the heading text "Migration posture" never enters
# the pre-#177 script's heading list. "Migration posture"'s own '~~~'-delimited block never
# toggles the backtick-only tracker, so its inner "``` still inside" line toggles it "outside"
# again in time for "### Worked example" to be read correctly. Observed pre-change verdict: rc 1,
# "PASS  element: Escalation triggers", "FAIL  element: Migration posture (no heading found)",
# "PASS  element: Worked example" — the new script's PASS for Migration posture is exactly what
# the old script's toggle-count coincidence gets wrong.
case_record_fence_close_rules() {
  local dir; dir="$(mk_repo record-fence-close-rules scoped verbatim)"
  local ghdir="$tmpbase/record-fence-close-rules-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
```
```js
still inside
~~~ still inside
```

### Migration posture
~~~
``` still inside
~~~

### Worked example
plain text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 0
  expect "PASS  element: Escalation triggers"
  expect "PASS  element: Migration posture"
  expect "PASS  element: Worked example"
  expect_absent "FAIL"
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

# ratchet-fence-comment (#137/#142) — a '#' comment BETWEEN two data lines inside the ratchet
# section's fenced block must not truncate the section slice, and a bare ``` fence-delimiter
# line must not itself be mistaken for the backtick-quoted measurement command: the real command
# (after the fence) is still found, never executed (sentinel absent).
case_ratchet_fence_comment() {
  local dir; dir="$(mk_repo ratchet-fence-comment ratchet-fenced verbatim)"
  local trapdir="$dir/boobytrap-bin" sentinel="$dir/sentinel-touched"
  mkdir -p "$trapdir"
  { printf '#!%s\n' "$bash_bin"; printf 'touch %s\n' "$sentinel"; } > "$trapdir/tbf-boobytrap"
  chmod +x "$trapdir/tbf-boobytrap"
  run_doctor "$dir" "$stub_gh_dir:$trapdir:$PATH"
  expect_rc 0
  expect "tbf-boobytrap --cov"
  expect_absent "names no backtick-quoted measurement command"
  expect_no_file "$sentinel"
}

# postdeploy-grant-missing (#138/#142) — a declared post-merge command with no matching allow
# entry in .claude/settings.json: WARN naming the exact token and the literal
# "Bash(<token>:*)" entry to add, never a FAIL.
case_postdeploy_grant_missing() {
  local dir; dir="$(mk_repo postdeploy-grant-missing merge-postdeploy merge-allow-only)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "post-merge verification: declared command(s) with no matching allow entry: tbf-boobytrap"
  expect "Bash(tbf-boobytrap:*)"
  expect_absent "post-merge verification: every declared command has a matching allow entry"
}

# postdeploy-grant-present (#138/#142) — every declared command's first token has a matching
# allow entry: PASS, no missing-grant WARN, and the check never executes the command it found a
# grant for (sentinel absent) — the never-execute guarantee applies to the present-grant branch
# too, not just the missing-grant one. The pre-existing declared-count line is unchanged (the
# '#' comment line is still counted there, while being skipped by the grant check itself).
case_postdeploy_grant_present() {
  local dir; dir="$(mk_repo postdeploy-grant-present merge-postdeploy postdeploy-grant)"
  local trapdir="$dir/boobytrap-bin" sentinel="$dir/sentinel-touched"
  mkdir -p "$trapdir"
  { printf '#!%s\n' "$bash_bin"; printf 'touch %s\n' "$sentinel"; } > "$trapdir/tbf-boobytrap"
  chmod +x "$trapdir/tbf-boobytrap"
  run_doctor "$dir" "$stub_gh_dir:$trapdir:$PATH"
  expect_rc 0
  expect "post-merge verification: every declared command has a matching allow entry"
  expect_absent "no matching allow entry"
  expect_no_file "$sentinel"
  expect "post-merge verification: declared (3 command line(s))"
}

# postdeploy-grant-local-only (#147) — the grant for the declared post-merge command lives ONLY
# in .claude/settings.local.json (the documented, machine-specific place for it), not in the
# checked-in .claude/settings.json: PASS, every declared command covered, no missing-grant WARN.
# Pins the three-file union the post-merge allow-entry check now reads instead of
# .claude/settings.json alone.
case_postdeploy_grant_local_only() {
  local dir; dir="$(mk_repo postdeploy-grant-local-only merge-postdeploy merge-allow-only)"
  printf '{"permissions":{"allow":["Bash(tbf-boobytrap:*)"]}}' > "$dir/.claude/settings.local.json"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "post-merge verification: every declared command has a matching allow entry"
  expect_absent "no matching allow entry"
}

# postdeploy-grant-user-only (#147) — same as postdeploy-grant-local-only, but the grant lives
# only in the user-level settings file. run_doctor already points CLAUDE_CONFIG_DIR at
# $dir/claudecfg, so this resolves to $dir/claudecfg/settings.json — hermetic, never the
# developer's real ~/.claude/settings.json.
case_postdeploy_grant_user_only() {
  local dir; dir="$(mk_repo postdeploy-grant-user-only merge-postdeploy merge-allow-only)"
  printf '{"permissions":{"allow":["Bash(tbf-boobytrap:*)"]}}' > "$dir/claudecfg/settings.json"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "post-merge verification: every declared command has a matching allow entry"
  expect_absent "no matching allow entry"
}

# baseline-short-sha (#141/#142) — a recorded '- commit:' value of exactly 7 hex characters that
# is a genuine prefix of origin/main's tip: treated as identifying that commit, not "behind".
case_baseline_short_sha() {
  local dir; dir="$(mk_repo baseline-short-sha base verbatim)"
  local sha; sha="$(seed_commit "$dir")"
  point_origin_ref "$dir" "$sha"
  write_baseline "$dir" "${sha:0:7}"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "verification baseline recorded (BASELINE.md at"
  expect_absent "verification baseline is behind"
}

# baseline-behind (#141/#142) — a 7-hex-char recorded value that is NOT a prefix of origin/main's
# current tip (the branch moved on): the prefix compare must still catch a genuinely stale
# baseline, not over-permissively pass every short value.
case_baseline_behind() {
  local dir; dir="$(mk_repo baseline-behind base verbatim)"
  local c1 c2
  c1="$(seed_commit "$dir")"
  c2="$(seed_commit "$dir")"
  point_origin_ref "$dir" "$c2"
  write_baseline "$dir" "${c1:0:7}"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "verification baseline is behind origin/main"
  expect_absent "verification baseline recorded (BASELINE.md at"
}

# baseline-too-short (#141/#142) — a recorded value under 7 hex characters cannot reliably
# identify a commit: WARN as malformed, not a silent PASS and not the "behind" wording (a 3-char
# value would otherwise glob-prefix-match almost anything).
case_baseline_too_short() {
  local dir; dir="$(mk_repo baseline-too-short base verbatim)"
  local sha; sha="$(seed_commit "$dir")"
  point_origin_ref "$dir" "$sha"
  write_baseline "$dir" "${sha:0:3}"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "BASELINE.md's '- commit:' value"
  expect_absent "verification baseline is behind"
  expect_absent "verification baseline recorded (BASELINE.md at"
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
  "merge-postdeploy|case_merge_postdeploy|post-merge verification sub-block: identical merge-autonomy verdict, declared command never executed, declared-state count correct across a fence-internal comment"
  "postdeploy-no-fence|case_postdeploy_no_fence|post-merge verification: heading present but no fenced commands -> WARN"
  "postdeploy-absent|case_postdeploy_absent|post-merge verification: no sub-heading at all -> informational PASS, not declared"
  "merge-ci-present|case_merge_ci_present|merge verdict: no-CI note absent when a workflow file exists"
  "merge-deny-only|case_merge_deny_only|entry_has: merge rule in deny only"
  "merge-deny-local-only|case_merge_deny_local_only|merge verdict: half-activated remediation names the file holding the deny (settings.local.json)"
  "merge-mention-only|case_merge_mention_only|entry_has: 'only' inside an unrelated JSON string"
  "guard-coverage-offbranch|case_guard_coverage_offbranch|default-branch guard coverage: WARN when the repo's default branch is one the template doesn't guard"
  "verify-path-grant-missing|case_verify_path_grant_missing|path-qualified verification interpreter with no literal-path grant -> WARN, reassuring PASS suppressed"
  "verify-path-grant-present|case_verify_path_grant_present|path-qualified verification interpreter with a literal-path grant -> PASS, Python toolchain WARN suppressed with no bare-name entry"
  "verify-path-grant-local-only|case_verify_path_grant_local_only|path-qualified verification interpreter: literal-path grant lives only in .claude/settings.local.json -> PASS, three-file union covers it"
  "verify-bare-command|case_verify_bare_command|control: bare-name-only verification command -> unchanged behaviour, neither new stem prints"
  "record-complete|case_record_complete|check-decision-record.sh: every declared element present, rc 0"
  "record-missing-element|case_record_missing_element|check-decision-record.sh: one declared element missing, rc 1, named"
  "record-no-declaration|case_record_no_declaration|check-decision-record.sh: no 'Autonomy decision record' section, rc 2"
  "record-comment-preserved|case_record_comment_preserved|check-decision-record.sh: a '#' comment inside the fenced block does not truncate it, later elements still checked"
  "record-fenced-body|case_record_fenced_body|check-decision-record.sh: record lives only inside a fenced code block -> every heading FAILs as absent"
  "record-empty-element|case_record_empty_element|check-decision-record.sh: element heading present but no content under it -> FAIL, distinct message from heading-absent"
  "record-nested-content|case_record_nested_content|check-decision-record.sh: content under a deeper sub-heading counts toward the parent element's span -> PASS"
  "record-fenced-content|case_record_fenced_content|check-decision-record.sh: content inside a fenced block counts, and an in-fence '#' line is not read as a heading -> PASS"
  "record-no-space-heading|case_record_no_space_heading|check-decision-record.sh: no whitespace after the '#' run means no heading, matching claude_md_block/claude_md_section"
  "record-element-outside-section|case_record_element_outside_section|check-decision-record.sh: element heading found only outside the record section's span -> distinct FAIL, other elements still PASS"
  "record-element-sibling-depth|case_record_element_sibling_depth|check-decision-record.sh: element heading as a same-depth sibling of the record section -> not nested, same distinct FAIL"
  "record-tilde-fence|case_record_tilde_fence|check-decision-record.sh: whole record inside a '~~~' block -> every heading FAILs as absent"
  "record-nested-fence|case_record_nested_fence|check-decision-record.sh: whole record inside a four-backtick block flanked by unmatched inner three-backtick lines -> every heading FAILs as absent"
  "record-indented-fence|case_record_indented_fence|check-decision-record.sh: whole record inside a 2-space-indented fence -> every heading FAILs as absent"
  "record-fence-close-rules|case_record_fence_close_rules|control: an info-string run and a wrong-character run never close a fence early -> all three elements PASS"
  "scoped-declared|case_scoped_declared|scoped autonomy: declared PASS when both declarations and the grant label exist"
  "scoped-reserve-missing|case_scoped_reserve_missing|scoped autonomy: WARN when the reserve declaration is missing, rc still 0"
  "ratchet-fence-comment|case_ratchet_fence_comment|test-suite ratchet: fence-aware section slice + fence-delimiter-skip span hunt find the command past an in-fence comment"
  "postdeploy-grant-missing|case_postdeploy_grant_missing|post-merge verification: declared command with no matching allow entry -> WARN naming the entry to add"
  "postdeploy-grant-present|case_postdeploy_grant_present|post-merge verification: every declared command has a matching allow entry -> PASS, never executed"
  "postdeploy-grant-local-only|case_postdeploy_grant_local_only|post-merge verification: grant lives only in .claude/settings.local.json -> PASS, three-file union covers it"
  "postdeploy-grant-user-only|case_postdeploy_grant_user_only|post-merge verification: grant lives only in the user-level settings file -> PASS, three-file union covers it"
  "baseline-short-sha|case_baseline_short_sha|verification baseline: 7-hex-char recorded value that prefixes the remote tip -> recorded, not behind"
  "baseline-behind|case_baseline_behind|verification baseline: 7-hex-char recorded value that does NOT prefix the remote tip -> still behind"
  "baseline-too-short|case_baseline_too_short|verification baseline: recorded value under 7 hex characters -> malformed WARN, not recorded, not behind"
  "hooks-disabled|case_hooks_disabled|disableAllHooks: true in settings.local.json -> WARN naming the file and the guard-hook consequence"
  "stale-c-allows|case_stale_c_allows|legacy Bash(git -C * ...) allow entries still present -> WARN naming them and the guard hook that supersedes them"
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
