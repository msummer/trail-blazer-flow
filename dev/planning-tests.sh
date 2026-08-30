#!/usr/bin/env bash
#
# planning-tests.sh — fixture-based negative-test harness for bin/find-planning-work.sh (#164),
# not this repo's own gate (that's dev/selfcheck.sh + dev/selfcheck-tests.sh) and not the
# consumer doctor's harness (dev/doctor-tests.sh). Builds throwaway fixture directories under
# mktemp, with a stub `gh` on PATH, and runs the REAL bin/find-planning-work.sh against each,
# pinning the trusted-association gate (#164): only a comment whose authorAssociation is OWNER,
# MEMBER, or COLLABORATOR ever puts its issue into needs_revision or is honoured as the latest
# plan comment; everything else (CONTRIBUTOR, NONE, or a comment with no authorAssociation field
# at all — fail-closed) posted after the issue's latest trusted plan (or any such comment, if
# there is no trusted plan yet) is reported in the untrusted_comments output bucket instead of
# being silently dropped or silently trusted, and never shadows a real, trusted plan; one posted
# before that plan is dropped with no bucket entry.
#
# Usage: bash dev/planning-tests.sh [name-filter] — same output contract as
# dev/cleanup-tests.sh, dev/doctor-tests.sh, and dev/selfcheck-tests.sh: one PASS/FAIL line per
# case, a `== summary: N pass, M fail ==` footer, exit 0 iff nothing failed; a filter with no
# match exits 1.
#
# Every write happens under one `mktemp -d` root, removed via an EXIT trap. No git fixture is
# needed — bin/find-planning-work.sh calls only `gh` and `jq` — so each fixture is just a
# directory holding a stub `gh` (offline, deterministic) plus the JSON payloads it serves:
# initial.json (the needs_initial_plan query's response), candidates.txt (the revision
# candidates query's response — one issue number per line, exactly what `gh issue list --jq
# '.[].number'` would print), and one issue-<n>.json per candidate (the `gh issue view --json
# number,title,url,comments` payload; a candidate with no issue-<n>.json file simulates a failed
# `gh issue view`, exercising the fetch-failures path). The real script's two `gh issue list`
# calls are told apart by the presence of `--jq` on the command line (only the candidates query
# passes it) — not by the `-label:`/`label:` search-string prefix, since `-label:plan-proposed`
# contains `label:plan-proposed` as a substring and a prefix-blind match would confuse the two.
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
  echo "  FAIL  jq not installed — required by bin/find-planning-work.sh itself"
  exit 1
fi

bash_bin="$(command -v bash)"

pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------------------------
# Fixture builders.

# mk_fixture NAME — a fresh, throwaway directory under $tmpbase/NAME. Prints the fixture path.
mk_fixture() {
  local name="$1" dir="$tmpbase/$name"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# build_stub_gh DIR — writes an executable DIR/gh (absolute paths to DIR's own initial.json,
# candidates.txt, and issue-<n>.json fixtures baked in via the __DIR__ + sed idiom
# dev/cleanup-tests.sh's build_stub_gh uses). Deterministic and offline:
#   `gh issue list ... --jq ...`      -> cat DIR/candidates.txt (revision candidates, one number
#                                         per line)
#   `gh issue list ...` (no --jq)     -> cat DIR/initial.json (the needs_initial_plan query)
#   `gh issue view <n> --json ...`    -> cat DIR/issue-<n>.json, or exit 1 if that file is
#                                         absent (simulates a failed fetch for that candidate)
#   anything else                     -> exit 1
build_stub_gh() {
  local dir="$1" tmpl="$dir/gh.tmpl"
  {
    printf '#!%s\n' "$bash_bin"
    cat <<'EOF'
case "$1 $2" in
  "issue list")
    case "$*" in
      *"--jq"*)
        cat "__DIR__/candidates.txt"
        exit 0 ;;
      *)
        cat "__DIR__/initial.json"
        exit 0 ;;
    esac
    ;;
  "issue view")
    n="$3"
    if [ -f "__DIR__/issue-$n.json" ]; then
      cat "__DIR__/issue-$n.json"
      exit 0
    else
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac
EOF
  } > "$tmpl"
  sed "s#__DIR__#$dir#g" "$tmpl" > "$dir/gh"
  rm -f "$tmpl"
  chmod +x "$dir/gh"
}

# ---------------------------------------------------------------------------------------------
# Runner + assertion helpers.

# run_planning DIR — runs the REAL bin/find-planning-work.sh with DIR (holding the stub gh)
# prepended to PATH, leaving $planning_out/$planning_err/$planning_rc set as globals. Stdout and
# stderr are captured to separate files (never combined) so jq assertions on stdout can't be
# confused by a `warn:` line, and vice versa. Deliberately NOT invoked via command substitution
# itself (same idiom as dev/cleanup-tests.sh's run_cleanup) — call as a plain statement and read
# the globals after.
planning_out=""
planning_err=""
planning_rc=0
run_planning() {
  local dir="$1"
  PATH="$dir:$PATH" "$bash_bin" "$root/bin/find-planning-work.sh" >"$dir/.stdout" 2>"$dir/.stderr"
  planning_rc=$?
  planning_out="$(cat "$dir/.stdout" 2>/dev/null || true)"
  planning_err="$(cat "$dir/.stderr" 2>/dev/null || true)"
}

# expect_jq QUERY EXPECTED — compact-JSON-compares a jq query run against $planning_out.
# expect_err/expect_no_err — ASCII-only short-stem substring match against $planning_err.
# expect_rc — exit code. All set $__ok=0 and append to $__why on failure.
__ok=1
__why=""
expect_jq() {
  local query="$1" expected="$2" actual
  actual="$(printf '%s' "$planning_out" | jq -c "$query" 2>&1)"
  [ "$actual" = "$expected" ] || { __ok=0; __why="${__why}jq $query: expected $expected, got $actual\n"; }
}
expect_err() {
  printf '%s\n' "$planning_err" | grep -qF -- "$1" || { __ok=0; __why="${__why}missing stderr: $1\n"; }
}
expect_no_err() {
  printf '%s\n' "$planning_err" | grep -qF -- "$1" && { __ok=0; __why="${__why}unexpected stderr: $1\n"; }
}
expect_rc() {
  [ "$planning_rc" -eq "$1" ] || { __ok=0; __why="${__why}rc: expected $1, got $planning_rc\n"; }
}

# ---------------------------------------------------------------------------------------------
# The cases.

# untrusted-comment-no-revision — plan by OWNER, later comment by NONE: no revision, and the
# NONE comment is reported, never dropped.
case_untrusted_no_revision() {
  local dir; dir="$(mk_fixture untrusted-comment-no-revision)"
  cat > "$dir/initial.json" <<'EOF'
[]
EOF
  printf '1\n' > "$dir/candidates.txt"
  cat > "$dir/issue-1.json" <<'EOF'
{"number":1,"title":"Issue one","url":"https://example.invalid/1","comments":[
  {"body":"<!-- planner-plan -->\nplan v1","createdAt":"2026-01-01T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"},
  {"body":"looks off to me","createdAt":"2026-01-02T00:00:00Z","author":{"login":"outsider"},"authorAssociation":"NONE"}
]}
EOF
  build_stub_gh "$dir"
  run_planning "$dir"
  expect_rc 0
  expect_jq '.counts.revision' '0'
  expect_jq '.needs_revision' '[]'
  expect_jq '.untrusted_comments | length' '1'
  expect_jq '.untrusted_comments[0].comments | length' '1'
  expect_jq '.counts.untrusted_comments' '1'
}

# contributor-comment-no-revision — same as above, association CONTRIBUTOR instead of NONE.
case_contributor_no_revision() {
  local dir; dir="$(mk_fixture contributor-comment-no-revision)"
  cat > "$dir/initial.json" <<'EOF'
[]
EOF
  printf '1\n' > "$dir/candidates.txt"
  cat > "$dir/issue-1.json" <<'EOF'
{"number":1,"title":"Issue one","url":"https://example.invalid/1","comments":[
  {"body":"<!-- planner-plan -->\nplan v1","createdAt":"2026-01-01T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"},
  {"body":"suggestion from a drive-by","createdAt":"2026-01-02T00:00:00Z","author":{"login":"contrib"},"authorAssociation":"CONTRIBUTOR"}
]}
EOF
  build_stub_gh "$dir"
  run_planning "$dir"
  expect_rc 0
  expect_jq '.counts.revision' '0'
  expect_jq '.needs_revision' '[]'
  expect_jq '.untrusted_comments | length' '1'
  expect_jq '.counts.untrusted_comments' '1'
}

# owner-comment-revision (control) — plan by OWNER, later comment by OWNER: revision flagged,
# nothing reported as untrusted.
case_owner_revision() {
  local dir; dir="$(mk_fixture owner-comment-revision)"
  cat > "$dir/initial.json" <<'EOF'
[]
EOF
  printf '1\n' > "$dir/candidates.txt"
  cat > "$dir/issue-1.json" <<'EOF'
{"number":1,"title":"Issue one","url":"https://example.invalid/1","comments":[
  {"body":"<!-- planner-plan -->\nplan v1","createdAt":"2026-01-01T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"},
  {"body":"please change X","createdAt":"2026-01-02T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"}
]}
EOF
  build_stub_gh "$dir"
  run_planning "$dir"
  expect_rc 0
  expect_jq '.counts.revision' '1'
  expect_jq '.needs_revision | length' '1'
  expect_jq '.untrusted_comments' '[]'
}

# member-comment-revision (control) — plan by OWNER, feedback by MEMBER still triggers revision.
case_member_revision() {
  local dir; dir="$(mk_fixture member-comment-revision)"
  cat > "$dir/initial.json" <<'EOF'
[]
EOF
  printf '1\n' > "$dir/candidates.txt"
  cat > "$dir/issue-1.json" <<'EOF'
{"number":1,"title":"Issue one","url":"https://example.invalid/1","comments":[
  {"body":"<!-- planner-plan -->\nplan v1","createdAt":"2026-01-01T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"},
  {"body":"please change Y","createdAt":"2026-01-02T00:00:00Z","author":{"login":"teammate"},"authorAssociation":"MEMBER"}
]}
EOF
  build_stub_gh "$dir"
  run_planning "$dir"
  expect_rc 0
  expect_jq '.counts.revision' '1'
  expect_jq '.untrusted_comments' '[]'
}

# collaborator-comment-revision (control) — plan by OWNER, feedback by COLLABORATOR still
# triggers revision.
case_collaborator_revision() {
  local dir; dir="$(mk_fixture collaborator-comment-revision)"
  cat > "$dir/initial.json" <<'EOF'
[]
EOF
  printf '1\n' > "$dir/candidates.txt"
  cat > "$dir/issue-1.json" <<'EOF'
{"number":1,"title":"Issue one","url":"https://example.invalid/1","comments":[
  {"body":"<!-- planner-plan -->\nplan v1","createdAt":"2026-01-01T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"},
  {"body":"please change Z","createdAt":"2026-01-02T00:00:00Z","author":{"login":"helper"},"authorAssociation":"COLLABORATOR"}
]}
EOF
  build_stub_gh "$dir"
  run_planning "$dir"
  expect_rc 0
  expect_jq '.counts.revision' '1'
  expect_jq '.untrusted_comments' '[]'
}

# lowercase-association-still-trusted — plan by OWNER, feedback carries a lowercase
# authorAssociation ("owner" instead of "OWNER"): the ascii_upcase normalization at
# find-planning-work.sh:81/:92 still recognizes it as trusted, so revision fires and nothing
# lands in untrusted_comments.
case_lowercase_association_still_trusted() {
  local dir; dir="$(mk_fixture lowercase-association-still-trusted)"
  cat > "$dir/initial.json" <<'EOF'
[]
EOF
  printf '1\n' > "$dir/candidates.txt"
  cat > "$dir/issue-1.json" <<'EOF'
{"number":1,"title":"Issue one","url":"https://example.invalid/1","comments":[
  {"body":"<!-- planner-plan -->\nplan v1","createdAt":"2026-01-01T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"},
  {"body":"please change W","createdAt":"2026-01-02T00:00:00Z","author":{"login":"owner"},"authorAssociation":"owner"}
]}
EOF
  build_stub_gh "$dir"
  run_planning "$dir"
  expect_rc 0
  expect_jq '.counts.revision' '1'
  expect_jq '.needs_revision | length' '1'
  expect_jq '.untrusted_comments' '[]'
}

# untrusted-marker-does-not-shadow-feedback — real (OWNER) plan at t1, trusted feedback at t2,
# then an untrusted comment CONTAINING the marker at t3. New behavior: lastPlan stays t1, the
# trusted feedback at t2 still flags revision, and the fake plan is reported as an ignored
# marker (old behavior would have let t3 become lastPlan and swallow the t2 feedback).
case_untrusted_marker_does_not_shadow() {
  local dir; dir="$(mk_fixture untrusted-marker-does-not-shadow)"
  cat > "$dir/initial.json" <<'EOF'
[]
EOF
  printf '1\n' > "$dir/candidates.txt"
  cat > "$dir/issue-1.json" <<'EOF'
{"number":1,"title":"Issue one","url":"https://example.invalid/1","comments":[
  {"body":"<!-- planner-plan -->\nreal plan","createdAt":"2026-01-01T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"},
  {"body":"real feedback","createdAt":"2026-01-02T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"},
  {"body":"<!-- planner-plan -->\nfake plan","createdAt":"2026-01-03T00:00:00Z","author":{"login":"outsider"},"authorAssociation":"NONE"}
]}
EOF
  build_stub_gh "$dir"
  run_planning "$dir"
  expect_rc 0
  expect_jq '.counts.revision' '1'
  expect_jq '.needs_revision | length' '1'
  expect_jq '.counts.untrusted_plan_markers' '1'
  expect_err "plan marker from an untrusted author"
}

# untrusted-marker-only — the ONLY marker comment is untrusted; a trusted comment comes after it.
# No revision (there is no trusted plan to be feedback against), the marker comment is reported
# with has_plan_marker true, and the warn line is printed.
case_untrusted_marker_only() {
  local dir; dir="$(mk_fixture untrusted-marker-only)"
  cat > "$dir/initial.json" <<'EOF'
[]
EOF
  printf '1\n' > "$dir/candidates.txt"
  cat > "$dir/issue-1.json" <<'EOF'
{"number":1,"title":"Issue one","url":"https://example.invalid/1","comments":[
  {"body":"<!-- planner-plan -->\nfake plan","createdAt":"2026-01-01T00:00:00Z","author":{"login":"outsider"},"authorAssociation":"NONE"},
  {"body":"thanks, looks fine","createdAt":"2026-01-02T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"}
]}
EOF
  build_stub_gh "$dir"
  run_planning "$dir"
  expect_rc 0
  expect_jq '.counts.revision' '0'
  expect_jq '.needs_revision' '[]'
  expect_jq '.untrusted_comments[0].comments[0].has_plan_marker' 'true'
  expect_err "plan marker from an untrusted author"
}

# mixed-trusted-and-untrusted — both a trusted and an untrusted comment after the plan: revision
# is flagged AND the untrusted one is reported, not dropped by being "outnumbered".
case_mixed_trusted_and_untrusted() {
  local dir; dir="$(mk_fixture mixed-trusted-and-untrusted)"
  cat > "$dir/initial.json" <<'EOF'
[]
EOF
  printf '1\n' > "$dir/candidates.txt"
  cat > "$dir/issue-1.json" <<'EOF'
{"number":1,"title":"Issue one","url":"https://example.invalid/1","comments":[
  {"body":"<!-- planner-plan -->\nplan v1","createdAt":"2026-01-01T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"},
  {"body":"trusted feedback","createdAt":"2026-01-02T00:00:00Z","author":{"login":"teammate"},"authorAssociation":"MEMBER"},
  {"body":"drive-by comment","createdAt":"2026-01-03T00:00:00Z","author":{"login":"outsider"},"authorAssociation":"NONE"}
]}
EOF
  build_stub_gh "$dir"
  run_planning "$dir"
  expect_rc 0
  expect_jq '.counts.revision' '1'
  expect_jq '.untrusted_comments | length' '1'
  expect_jq '.counts.untrusted_comments' '1'
}

# missing-association-warns — a comment JSON object with no authorAssociation key at all: treated
# as untrusted (fail-closed), counted, and warned about (never crashes, never silently trusted).
case_missing_association_warns() {
  local dir; dir="$(mk_fixture missing-association-warns)"
  cat > "$dir/initial.json" <<'EOF'
[]
EOF
  printf '1\n' > "$dir/candidates.txt"
  cat > "$dir/issue-1.json" <<'EOF'
{"number":1,"title":"Issue one","url":"https://example.invalid/1","comments":[
  {"body":"<!-- planner-plan -->\nplan v1","createdAt":"2026-01-01T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"},
  {"body":"no association field on me","createdAt":"2026-01-02T00:00:00Z","author":{"login":"ghost"}}
]}
EOF
  build_stub_gh "$dir"
  run_planning "$dir"
  expect_rc 0
  expect_jq '.counts.revision' '0'
  expect_jq '.counts.missing_association' '1'
  expect_err "have no authorAssociation field"
}

# no-comments (control) — a plan comment with nothing posted after it: no revision, nothing
# untrusted, clean exit.
case_no_comments() {
  local dir; dir="$(mk_fixture no-comments)"
  cat > "$dir/initial.json" <<'EOF'
[]
EOF
  printf '1\n' > "$dir/candidates.txt"
  cat > "$dir/issue-1.json" <<'EOF'
{"number":1,"title":"Issue one","url":"https://example.invalid/1","comments":[
  {"body":"<!-- planner-plan -->\nplan v1","createdAt":"2026-01-01T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"}
]}
EOF
  build_stub_gh "$dir"
  run_planning "$dir"
  expect_rc 0
  expect_jq '.counts.revision' '0'
  expect_jq '.counts.untrusted_comments' '0'
  expect_jq '.untrusted_comments' '[]'
}

# fetch-failure-survives (regression control) — the stub gh fails `issue view` for candidate #1
# (no issue-1.json file); candidate #2 must still be evaluated correctly.
case_fetch_failure_survives() {
  local dir; dir="$(mk_fixture fetch-failure-survives)"
  cat > "$dir/initial.json" <<'EOF'
[]
EOF
  printf '1\n2\n' > "$dir/candidates.txt"
  # deliberately no issue-1.json — simulates `gh issue view 1` failing
  cat > "$dir/issue-2.json" <<'EOF'
{"number":2,"title":"Issue two","url":"https://example.invalid/2","comments":[
  {"body":"<!-- planner-plan -->\nplan v1","createdAt":"2026-01-01T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"},
  {"body":"please change X","createdAt":"2026-01-02T00:00:00Z","author":{"login":"owner"},"authorAssociation":"OWNER"}
]}
EOF
  build_stub_gh "$dir"
  run_planning "$dir"
  expect_rc 0
  expect_jq '.counts.fetch_failures' '1'
  expect_jq '.counts.revision' '1'
  expect_jq '.needs_revision[0].number' '2'
  expect_err "could not fetch issue #1"
}

# output-shape — every existing top-level key and counts field is still present with its current
# name (protects bin/harness-status.sh, which reads .needs_initial_plan and .needs_revision).
case_output_shape() {
  local dir; dir="$(mk_fixture output-shape)"
  cat > "$dir/initial.json" <<'EOF'
[]
EOF
  printf '' > "$dir/candidates.txt"
  build_stub_gh "$dir"
  run_planning "$dir"
  expect_rc 0
  expect_jq 'has("needs_initial_plan")' 'true'
  expect_jq 'has("needs_revision")' 'true'
  expect_jq 'has("untrusted_comments")' 'true'
  expect_jq '.counts | has("initial")' 'true'
  expect_jq '.counts | has("revision")' 'true'
  expect_jq '.counts | has("fetch_failures")' 'true'
  expect_jq '.counts | has("truncated")' 'true'
  expect_jq '.counts | has("untrusted_comments")' 'true'
  expect_jq '.counts | has("untrusted_plan_markers")' 'true'
  expect_jq '.counts | has("missing_association")' 'true'
}

# ---------------------------------------------------------------------------------------------
# name|fn|desc
cases=(
  "untrusted-comment-no-revision|case_untrusted_no_revision|NONE comment after the plan: no revision, reported in untrusted_comments"
  "contributor-comment-no-revision|case_contributor_no_revision|CONTRIBUTOR comment after the plan: no revision, reported"
  "owner-comment-revision|case_owner_revision|control: OWNER feedback after an OWNER plan still triggers revision"
  "member-comment-revision|case_member_revision|control: MEMBER feedback after an OWNER plan still triggers revision"
  "collaborator-comment-revision|case_collaborator_revision|control: COLLABORATOR feedback after an OWNER plan still triggers revision"
  "lowercase-association-still-trusted|case_lowercase_association_still_trusted|lowercase authorAssociation ('owner') is still normalized to trusted (ascii_upcase)"
  "untrusted-marker-does-not-shadow|case_untrusted_marker_does_not_shadow|a later untrusted marker comment does not shadow earlier trusted feedback"
  "untrusted-marker-only|case_untrusted_marker_only|the only marker comment is untrusted: no revision, marker reported, warn printed"
  "mixed-trusted-and-untrusted|case_mixed_trusted_and_untrusted|trusted AND untrusted comments after the plan: revision flagged, untrusted reported"
  "missing-association-warns|case_missing_association_warns|a comment with no authorAssociation field: fail-closed untrusted, counted, warned"
  "no-comments|case_no_comments|control: plan only, nothing posted after it: no revision, nothing untrusted"
  "fetch-failure-survives|case_fetch_failure_survives|one candidate's gh issue view fails: fetch_failures counted, other candidates still evaluated"
  "output-shape|case_output_shape|every existing top-level key and counts field is still present with its current name"
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
