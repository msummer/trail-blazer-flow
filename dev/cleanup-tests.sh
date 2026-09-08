#!/usr/bin/env bash
#
# cleanup-tests.sh — fixture-based negative-test harness for bin/cleanup-after-merge.sh, not
# this repo's own gate (that's dev/selfcheck.sh + dev/selfcheck-tests.sh) and not the consumer
# doctor's harness (dev/doctor-tests.sh). Builds throwaway git repos under mktemp, with a stub
# `gh` (and, where needed, a stub `git`) on PATH, and runs the REAL bin/cleanup-after-merge.sh
# (no copy — the script has no $0-relative path, unlike bin/check-harness.sh) against each,
# pinning the multi-PR KEEP behaviour (#106, revised by #231) and the best-effort pre-flight
# (#77, #111, #132): a failed `gh repo view` (default-branch lookup), `git branch --show-current`
# (current-branch lookup), `gh pr list`, or `git pull --ff-only` is reported (WARN) and survived
# rather than aborting the run before any output, that would otherwise only be hand-verified.
#
# Since #231, the multi-PR KEEP signal is label-primary and the comment-marker path is
# trust-gated: the `multi-pr` label on the issue itself is the primary KEEP signal (read from
# the same `gh issue list --json number,title,labels` fetch the script already makes); the
# `<!-- harness-multi-pr -->` marker is honoured only in a comment whose `authorAssociation` is
# OWNER/MEMBER/COLLABORATOR (case-insensitively), with a comment carrying no `authorAssociation`
# field treated as untrusted (fail-closed) — an ignored untrusted marker prints exactly one WARN
# line naming the comment's association and url, in both `--fix` and report-only modes; and the
# issue-BODY marker is no longer honoured at all (an issue relying on it now closes on the
# normal path). `build_stub_gh`'s `issue list` arm projects the requested `--json` field list
# (see its own comment below) so a fixture can distinguish "the script requested labels" from
# "the script didn't" — proving the label case can't pass vacuously if the script stops asking
# for `labels`.
#
# Usage: bash dev/cleanup-tests.sh [name-filter] — same output contract as
# dev/selfcheck-tests.sh and dev/doctor-tests.sh: one PASS/FAIL line per case, a
# `== summary: N pass, M fail ==` footer, exit 0 iff nothing failed; a filter with no match
# exits 1.
#
# Every write happens under one `mktemp -d` root, removed via an EXIT trap. Each fixture is a
# real, throwaway git repo (a single empty commit on a branch renamed to "main" before that
# commit, so it matches the stub gh's claimed default branch regardless of the machine's
# init.defaultBranch) with its own HOME/XDG_CONFIG_HOME so a developer's global gitconfig can
# never change behaviour, and its own stub `gh` (offline, deterministic) prepended to PATH — no
# real gh call, no network, ever. The "pull-ok" fixture additionally gets a local `--bare`
# origin pushed once at setup time, so its own fast-forward is exercised for real and stays
# fully offline. The "pull-fail" fixtures have no remote at all, so `git pull --ff-only` fails
# instantly and offline, with no timeout risk. The "current-branch-failure" fixture additionally
# gets a stub `git` (see build_stub_git) that fails only `branch --show-current` and execs the
# real git (captured as $git_bin before any PATH is handed to a fixture) for everything else.
#
# Prose coupling: this repo's own gate compares machine-parsed artifacts only (see CLAUDE.md);
# that rule governs dev/selfcheck.sh, not this fixture harness. Like dev/doctor-tests.sh, this
# file pins short, ASCII-only verdict STEMS (stop before the script's em dashes) plus
# machine-derived payloads — the gh-calls.log this stub gh writes on every issue
# comment/edit/close invocation. That log is the harness's own audit trail, not prose pinning.
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
  echo "  FAIL  jq not installed — required by bin/cleanup-after-merge.sh itself"
  exit 1
fi

bash_bin="$(command -v bash)"
git_bin="$(command -v git)"

pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------------------------
# Fixture builders.

# mk_repo NAME — a fresh, throwaway git repo under $tmpbase/NAME: one empty commit on a branch
# renamed to "main" before that commit (portable regardless of the machine's
# init.defaultBranch), local identity + gpgsign off so CI runners with no global identity work,
# and its own home/ dir for HOME isolation. No remote. Prints the fixture path.
mk_repo() {
  local name="$1" dir="$tmpbase/$name"
  mkdir -p "$dir/home" "$dir/xdgcfg"
  (
    cd "$dir" &&
    git init -q &&
    git config user.name "cleanup-tests" &&
    git config user.email "cleanup-tests@example.invalid" &&
    git config commit.gpgsign false &&
    git symbolic-ref HEAD refs/heads/main &&
    git commit -q --allow-empty -m init
  )
  printf '%s' "$dir"
}

# mk_repo_with_origin NAME — mk_repo, plus a local --bare origin pushed once at setup time, so
# the fixture already has upstream tracking and `git pull --ff-only` succeeds against it —
# fully offline (file:// remote), deterministic (nothing else ever pushes to it).
mk_repo_with_origin() {
  local name="$1" dir bare
  dir="$(mk_repo "$name")"
  bare="$tmpbase/${name}-origin.git"
  git init -q --bare "$bare"
  (cd "$dir" && git remote add origin "$bare" && git push -q -u origin main)
  printf '%s' "$dir"
}

# build_stub_gh DIR [REPO_MODE] [PR_MODE] — writes an executable DIR/gh (absolute paths to DIR's
# own prs.json, issues.json, comments.json baked in) and resets DIR/gh-calls.log empty.
# Deterministic and offline. REPO_MODE (default "ok") composes the `repo)` arm with printf,
# outside the quoted heredoc — exactly the idiom dev/doctor-tests.sh's build_stub_gh uses for its
# `repo)`/`label)` lines: "ok" answers "main" (every fixture's branch is renamed to match; every
# case that doesn't pass this parameter gets that answer), "fail" exits 1 (simulating a
# rate-limited/unauthenticated `gh repo view`). PR_MODE (default "ok", same idiom) composes the
# `pr list)` arm: "ok" cats DIR/prs.json, "fail" exits 1 (simulating a failed `gh pr list`).
# Otherwise: `issue list` cats DIR/issues.json when invoked with the literal `--label pr-open`
# flag pair (the label-hygiene query) and prints `[]` for any other `issue list` invocation
# (the follow-ups query, never exercised by these fixtures since their prs.json carries no
# CLOSED entry) — since #231, the label-hygiene arm additionally PROJECTS the real jq's own
# `with_entries(select(...))` idiom over DIR/issues.json against whatever field list followed a
# literal `--json` token in the invocation, the same document-semantics faithfulness #196 (LESSON
# 2026-09-01(c)) requires: a fixture whose script drops `labels` from its own `--json` list gets
# back objects with no `labels` key at all, not a stub that silently keeps serving it — which is
# what makes the `keep-multi-pr-label` case's mutation proof possible. Field projection is
# applied to the `issue list` arm only (its field list is the one that's load-bearing for a
# fixture verdict); `pr list` and `issue view` stay as-is, and generic field-NAME validation
# (rejecting an unsupported field the way #217 taught `dev/planning-tests.sh` to) is a follow-up,
# not modelled here. `issue view` cats DIR/comments.json (the `--json comments`-shaped payload
# the marker lookup expects); `issue comment|edit|close` append the full `"$*"` line to
# DIR/gh-calls.log and exit 0 — the machine-derived payload every case's assertions read back.
# Anything else exits 1. The `__DIR__` placeholder + sed substitution step stays for the
# fixed part of the script (unchanged from before REPO_MODE/PR_MODE existed).
build_stub_gh() {
  local dir="$1" repo_mode="${2:-ok}" pr_mode="${3:-ok}" tmpl="$dir/gh.tmpl"
  : > "$dir/gh-calls.log"
  {
    printf '#!%s\n' "$bash_bin"
    printf 'case "$1" in\n'
    if [ "$repo_mode" = fail ]; then
      printf '  repo) exit 1 ;;\n'
    else
      printf '  repo) echo main; exit 0 ;;\n'
    fi
    printf '  pr)\n    case "$2" in\n'
    if [ "$pr_mode" = fail ]; then
      printf '      list) exit 1 ;;\n'
    else
      printf '      list) cat "__DIR__/prs.json"; exit 0 ;;\n'
    fi
    cat <<'EOF'
      *) exit 1 ;;
    esac
    ;;
  issue)
    case "$2" in
      list)
        fields=""
        prev=""
        for a in "$@"; do
          if [ "$prev" = "--json" ]; then
            fields="$a"
          fi
          prev="$a"
        done
        case "$*" in
          *"--label pr-open"*)
            if [ -n "$fields" ]; then
              jq -c --arg f "$fields" 'map(with_entries(select(.key as $k | (($f | split(",")) | index($k)) != null)))' "__DIR__/issues.json"
            else
              cat "__DIR__/issues.json"
            fi
            ;;
          *) printf '[]' ;;
        esac
        exit 0 ;;
      view) cat "__DIR__/comments.json"; exit 0 ;;
      comment|edit|close)
        printf '%s\n' "$*" >> "__DIR__/gh-calls.log"
        exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
  } > "$tmpl"
  sed "s#__DIR__#$dir#g" "$tmpl" > "$dir/gh"
  rm -f "$tmpl"
  chmod +x "$dir/gh"
}

# build_stub_git DIR — writes an executable DIR/git that fails ONLY for the exact invocation
# `branch --show-current` (rc 1, no output — simulating a git failure, distinct from the
# legitimate empty-output detached-HEAD case) and execs the real git (its absolute path
# captured once at the top of this harness, in $git_bin, before any PATH is handed to a
# fixture — never a bare "git", which could re-resolve to this very stub) for every other
# invocation, so `git pull`, `git for-each-ref`, `git worktree list`, and `git branch -D`
# inside bin/cleanup-after-merge.sh all behave exactly as the real git.
build_stub_git() {
  local dir="$1" tmpl="$dir/git.tmpl"
  { printf '#!%s\n' "$bash_bin"; cat <<'EOF'
if [ "$#" -eq 2 ] && [ "$1" = branch ] && [ "$2" = --show-current ]; then
  exit 1
fi
exec "__GIT_BIN__" "$@"
EOF
  } > "$tmpl"
  sed "s#__GIT_BIN__#$git_bin#g" "$tmpl" > "$dir/git"
  rm -f "$tmpl"
  chmod +x "$dir/git"
}

# ---------------------------------------------------------------------------------------------
# Runner + assertion helpers.

# run_cleanup DIR [ARGS...] — runs the REAL bin/cleanup-after-merge.sh with cwd, HOME, and
# XDG_CONFIG_HOME set into the fixture and DIR (holding the stub gh) prepended to PATH, leaving
# $cleanup_out/$cleanup_rc/$calls set as globals ($calls is DIR/gh-calls.log's content after the
# run). Deliberately NOT invoked via command substitution itself (same idiom as
# dev/doctor-tests.sh's run_doctor) — call as a plain statement and read the globals after.
cleanup_out=""
cleanup_rc=0
calls=""
run_cleanup() {
  local dir="$1"; shift
  cleanup_out="$(cd "$dir" && HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdgcfg" PATH="$dir:$PATH" "$bash_bin" "$root/bin/cleanup-after-merge.sh" "$@" 2>&1)"
  cleanup_rc=$?
  calls="$(cat "$dir/gh-calls.log" 2>/dev/null || true)"
}

# needle_required NAME NEEDLE (#262) — guards every needle-taking helper below: an empty NEEDLE
# degenerates `grep -qF -- ""`/`grep -cF -- ""` into an unconditional match (expect "" always
# passes, expect_absent "" always fails, expect_count's count becomes a total-line count), so
# treat an empty needle as a harness bug IN THE CASE, not a fact about the script under test.
# Sets $__ok=0, appends "<NAME>: empty needle (harness bug)\n" to $__why, and returns 1; returns 0
# when the needle is non-empty. Callers do `needle_required <own-name> "$1" || return 0` —
# returning 0 to the CALLER's caller (not 1), so a guarded helper never leaves a stray non-zero
# exit status behind for an `&&`/`||`/`if` chain built on it.
needle_required() {
  if [ -z "$2" ]; then
    __ok=0
    __why="${__why}$1: empty needle (harness bug)\n"
    return 1
  fi
  return 0
}

# expect/expect_absent/expect_rc — assert against $cleanup_out/$cleanup_rc.
# expect_call/expect_no_call/expect_calls_empty — assert against $calls (the gh-calls.log
# payload). All set $__ok=0 and append to $__why on failure. ASCII-only short stems: stop
# before the script's em dashes. expect/expect_absent/expect_call/expect_no_call/expect_count are
# guarded by needle_required (#262). Fed via a here-string (`<<<"$cleanup_out"`/`<<<"$calls"`,
# #255) rather than piping a `printf '%s\n' ...` writer into `grep`'s quiet mode: that early-exit
# reader exits on its first match, which can send the printf writer SIGPIPE and, under this file's
# `set -uo pipefail`, turn a genuine match into a reported pipeline failure — a here-string has no
# writer process, so no SIGPIPE is possible, and it appends exactly one trailing newline, the same
# as the piped printf did, so grep's fixed-string/count semantics are unchanged.
__ok=1
__why=""
expect() {
  needle_required expect "$1" || return 0
  grep -qF -- "$1" <<<"$cleanup_out" || { __ok=0; __why="${__why}missing: $1\n"; }
}
expect_absent() {
  needle_required expect_absent "$1" || return 0
  grep -qF -- "$1" <<<"$cleanup_out" && { __ok=0; __why="${__why}unexpected: $1\n"; }
}
expect_rc() {
  [ "$cleanup_rc" -eq "$1" ] || { __ok=0; __why="${__why}rc: expected $1, got $cleanup_rc\n"; }
}
expect_call() {
  needle_required expect_call "$1" || return 0
  grep -qF -- "$1" <<<"$calls" || { __ok=0; __why="${__why}missing gh call: $1\n"; }
}
expect_no_call() {
  needle_required expect_no_call "$1" || return 0
  grep -qF -- "$1" <<<"$calls" && { __ok=0; __why="${__why}unexpected gh call: $1\n"; }
}
expect_calls_empty() {
  [ -z "$calls" ] || { __ok=0; __why="${__why}expected no gh mutation calls, got: $calls\n"; }
}
# expect_count NEEDLE N — asserts $cleanup_out contains exactly N lines matching NEEDLE
# (fixed-string, grep -cF), mechanically pinning "exactly one WARN" rather than mere presence.
expect_count() {
  local needle="$1" want="$2" got
  needle_required expect_count "$needle" || return 0
  got="$(grep -cF -- "$needle" <<<"$cleanup_out")"
  [ "$got" -eq "$want" ] || { __ok=0; __why="${__why}count: expected $want of '$needle', got $got\n"; }
}

# ---------------------------------------------------------------------------------------------
# The cases.

# keep-part-of — merged claude/7-* PR body says "Part of #7" / "PR 1 of 3", no sibling: no
# close, KEEP line present, pr-open removed (re-queues). The acceptance criterion #106 names
# explicitly.
case_keep_part_of() {
  local dir; dir="$(mk_repo keep-part-of)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-slice1","body":"Part of #7\n\nPR 1 of 3"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Multi-PR thing","body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "KEEP  #7 (Multi-PR thing): PR #12 merged as part of a multi-PR issue"
  expect_no_call "issue close"
  expect_call "remove-label pr-open"
}

# keep-open-sibling — merged PR #12 (the highest-numbered, so it is the one the script matches)
# carries a valid Closes #7, but a lower-numbered OPEN claude/7-* PR #11 is still open: no
# close, and no label edit at all (the log must not contain remove-label — repeated pre-flights
# must not spam the issue while the sibling is still in review).
case_keep_open_sibling() {
  local dir; dir="$(mk_repo keep-open-sibling)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":11,"state":"OPEN","headRefName":"claude/7-a","body":""},
 {"number":12,"state":"MERGED","headRefName":"claude/7-b","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Multi-PR thing","body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "KEEP  #7 (Multi-PR thing): PR #12 merged as part of a multi-PR issue"
  expect_no_call "issue close"
  expect_no_call "remove-label"
  expect_no_call "issue comment"
}

# close-marker-body-only (#231) — Closes #7 present, no sibling, and the issue BODY carries
# <!-- harness-multi-pr -->: the body marker is no longer a KEEP signal (the maintainer-agreed
# Decision replaced it with the multi-pr label, since cleanup has no author-association lookup
# for the issue itself), so this now takes the ordinary close path — same fixture as the old
# keep-marker-body case, inverted expectations. Mutation proof (step 13(d)): restoring ONLY the
# deleted body-marker `elif` (re-adding `issue_body=$(printf '%s' "$issue" | jq -r '.body //
# ""'...)` plus the elif reading it) left this fixture PASSING (measured: 17 pass, 0 fail) — a
# surviving mutant, because `--json number,title,labels` no longer requests `body` at all, so
# the stub's own field projection (see build_stub_gh above) strips the key and `issue_body`
# reads empty regardless of the elif's presence; a real `gh` would behave identically. The
# meaningful, measured mutant instead restores the whole removed code path together — the elif
# AND `body` back in the `--json` field list (`--json number,title,labels,body`) — which makes
# this fixture, and only this fixture, FAIL (measured: 16 pass, 1 fail): the issue reports KEEP
# and "issue close" is never called. (Both figures re-measured against the 17-case suite after
# #231's warn-untrusted-marker-no-fix case was added; the case totals here move in lockstep with
# the suite's case count, not with this fixture's own behaviour.)
case_close_marker_body_only() {
  local dir; dir="$(mk_repo close-marker-body-only)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Planned split","labels":[],"body":"Splitting this on purpose.\n<!-- harness-multi-pr -->\n"}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "FIXED #7 (Planned split): PR #12 merged"
  expect_call "issue close"
}

# keep-marker-comment (#231: gains a trusted association) — Closes #7 present, no sibling, no
# multi-pr label, but a comment from an OWNER carries <!-- harness-multi-pr -->: no close. The
# only case that needs the marker to be found via the extra `gh issue view` call rather than a
# cheaper signal, and the first of the trust-gate cases (an OWNER comment IS honoured).
case_keep_marker_comment() {
  local dir; dir="$(mk_repo keep-marker-comment)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Planned split","labels":[],"body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[{"body":"Heads up, splitting this one.\n<!-- harness-multi-pr -->\n","authorAssociation":"OWNER","url":"https://example.invalid/7#issuecomment-9001"}]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "KEEP  #7 (Planned split): PR #12 merged as part of a multi-PR issue"
  expect_no_call "issue close"
}

# keep-multi-pr-label (#231) — the issue itself carries the multi-pr label (gh's real
# {"name": "..."} label-element shape), Closes #7 present, no sibling, no comment marker at
# all: no close. The primary signal — proves the label alone is sufficient, no comment fetch
# needed. Mutation proof (step 13(a), measured against this diff): dropping `labels` from
# bin/cleanup-after-merge.sh's `gh issue list --json` field list makes this fixture FAIL (the
# stub's field projection then serves an issue object with no labels key at all, so
# has_multi_pr_label reads false and the issue closes instead of KEEPing).
case_keep_multi_pr_label() {
  local dir; dir="$(mk_repo keep-multi-pr-label)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Labelled split","labels":[{"name":"multi-pr"}],"body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "KEEP  #7 (Labelled split): PR #12 merged as part of a multi-PR issue (the issue carries the multi-pr label)"
  expect_no_call "issue close"
}

# close-untrusted-comment-marker (#231) — a comment carries <!-- harness-multi-pr --> but its
# authorAssociation is NONE: the marker is ignored (not a KEEP signal) and the issue closes on
# the normal path, plus exactly one WARN line naming the comment's association and url.
# Mutation proof (step 13(b), measured against this diff): deleting the trusted `select`
# clause (so ANY marker-carrying comment counts as trusted) makes this fixture FAIL — the issue
# KEEPs instead of closing.
case_close_untrusted_comment_marker() {
  local dir; dir="$(mk_repo close-untrusted-comment-marker)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Forged split","labels":[],"body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[{"body":"Heads up, splitting this one.\n<!-- harness-multi-pr -->\n","authorAssociation":"NONE","url":"https://example.invalid/7#issuecomment-9002"}]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "FIXED #7 (Forged split): PR #12 merged"
  expect_call "issue close"
  expect_count "ignoring a harness-multi-pr marker from an untrusted comment author" 1
  expect "(NONE) at https://example.invalid/7#issuecomment-9002"
}

# warn-untrusted-marker-no-fix (#231) — the close-untrusted-comment-marker fixture, run WITHOUT
# --fix: the same untrusted-marker WARN still prints exactly once, naming the comment's
# association and url, and no gh mutation call is made at all — proving the WARN is not gated
# behind --fix (RESOLVED: the untrusted-marker WARN prints in report-only mode as well as
# --fix). Mutation proof (measured against this diff): wrapping the WARN echo at
# bin/cleanup-after-merge.sh:239 in `if $FIX; then ... fi` makes this fixture, and only this
# fixture, FAIL (measured: 16 pass, 1 fail) — the "ignoring a harness-multi-pr marker" WARN line
# disappears (count 0, not 1) when the run is report-only.
case_warn_untrusted_marker_no_fix() {
  local dir; dir="$(mk_repo warn-untrusted-marker-no-fix)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Forged split","labels":[],"body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[{"body":"Heads up, splitting this one.\n<!-- harness-multi-pr -->\n","authorAssociation":"NONE","url":"https://example.invalid/7#issuecomment-9002"}]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir"
  expect_rc 0
  expect_count "ignoring a harness-multi-pr marker from an untrusted comment author" 1
  expect "(NONE) at https://example.invalid/7#issuecomment-9002"
  expect_calls_empty
}

# close-missing-association-marker (#231) — same as close-untrusted-comment-marker, but the
# comment object has NO authorAssociation key at all: fail-closed the same way (same rule as
# both discovery scripts), one WARN naming the MISSING sentinel. Mutation proof (step 13(c),
# measured against this diff): deleting the untrusted `select`/WARN loop makes this fixture
# FAIL — the "ignoring a harness-multi-pr marker" WARN line disappears (count 0, not 1).
case_close_missing_association_marker() {
  local dir; dir="$(mk_repo close-missing-association-marker)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"No association","labels":[],"body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[{"body":"Heads up, splitting this one.\n<!-- harness-multi-pr -->\n","url":"https://example.invalid/7#issuecomment-9003"}]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "FIXED #7 (No association): PR #12 merged"
  expect_call "issue close"
  expect_count "ignoring a harness-multi-pr marker from an untrusted comment author" 1
  expect "(MISSING) at https://example.invalid/7#issuecomment-9003"
}

# keep-marker-comment-lowercase-assoc (#231) — a comment's authorAssociation is "owner"
# (lowercase, as GitHub never actually sends it, but pins the ascii_upcase normalisation no
# other fixture distinguishes): still trusted, still KEEP. Mutation proof (step 13(e), measured
# against this diff): deleting `ascii_upcase` from the trust check makes this fixture FAIL — the
# lowercase association no longer matches the uppercase TRUSTED_ASSOCIATIONS list, so the
# marker is treated as untrusted and the issue closes instead of KEEPing.
case_keep_marker_comment_lowercase_assoc() {
  local dir; dir="$(mk_repo keep-marker-comment-lowercase-assoc)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Lowercase assoc","labels":[],"body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[{"body":"Heads up, splitting this one.\n<!-- harness-multi-pr -->\n","authorAssociation":"owner","url":"https://example.invalid/7#issuecomment-9004"}]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "KEEP  #7 (Lowercase assoc): PR #12 merged as part of a multi-PR issue"
  expect_no_call "issue close"
}

# keep-wrong-issue-number — the PR body says "Closes #70" while the issue being evaluated is
# #7: no close. Proves the number boundary in the regex, the likeliest silent bug — a
# substring match would let #70 satisfy #7.
case_keep_wrong_issue_number() {
  local dir; dir="$(mk_repo keep-wrong-issue-number)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #70"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Not #70","body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "KEEP  #7 (Not #70): PR #12 merged as part of a multi-PR issue"
  expect_no_call "issue close"
}

# close-normal (control) — Closes #7, no sibling, no marker anywhere: the issue IS closed. Pins
# that the KEEP conditions didn't disable the legitimate, still-common close path.
case_close_normal() {
  local dir; dir="$(mk_repo close-normal)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Ordinary issue","body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "FIXED #7 (Ordinary issue): PR #12 merged"
  expect_call "issue close"
  expect_call "remove-label pr-open"
}

# keep-no-fix — the keep-part-of fixture, run WITHOUT --fix: no gh mutation call at all (the
# call log stays empty), and the KEEP line is still printed.
case_keep_no_fix() {
  local dir; dir="$(mk_repo keep-no-fix)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-slice1","body":"Part of #7\n\nPR 1 of 3"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Multi-PR thing","body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir"
  expect_rc 0
  expect "KEEP  #7 (Multi-PR thing): PR #12 merged as part of a multi-PR issue"
  expect_calls_empty
}

# pull-failure-continues (#77) — no remote at all, so `git pull --ff-only` fails instantly and
# offline: rc 0, "could not fast-forward" printed, and the pr-open label hygiene section's
# output still present, proving the run reaches label repair instead of aborting.
case_pull_failure_continues() {
  local dir; dir="$(mk_repo pull-failure-continues)"
  cat > "$dir/prs.json" <<'EOF'
[]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "could not fast-forward"
  expect "== local claude/* branches =="
  expect "== pr-open label hygiene =="
  expect "no open issues labelled pr-open"
}

# pull-ok (control) — a local bare origin with upstream already set: rc 0 and "could not
# fast-forward" absent, proving the warning isn't printed on the happy path.
case_pull_ok() {
  local dir; dir="$(mk_repo_with_origin pull-ok)"
  cat > "$dir/prs.json" <<'EOF'
[]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_absent "could not fast-forward"
  expect_absent "could not determine the default branch"
}

# repo-view-failure-continues (#132/#111) — the stub gh's very first call (`gh repo view`, the
# pre-flight's own default-branch lookup) fails: rc 0, the WARN stem printed, the fast-forward
# WARN absent (the sync step is skipped outright, not attempted and failed), and the run still
# reaches label hygiene — proving the failure is reported and survived, not fatal before any
# output.
case_repo_view_failure_continues() {
  local dir; dir="$(mk_repo repo-view-failure-continues)"
  cat > "$dir/prs.json" <<'EOF'
[]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir" fail
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "could not determine the default branch"
  expect "== pr-open label hygiene =="
  expect "no open issues labelled pr-open"
  expect_absent "could not fast-forward"
}

# current-branch-failure-continues (#132/#111) — a stub git that fails only for
# `branch --show-current` (distinct from a legitimate empty detached-HEAD result): rc 0, the
# WARN stem printed, and the run still reaches label hygiene.
case_current_branch_failure_continues() {
  local dir; dir="$(mk_repo current-branch-failure-continues)"
  cat > "$dir/prs.json" <<'EOF'
[]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  build_stub_git "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "could not determine the current branch"
  expect "== pr-open label hygiene =="
}

# pr-list-failure-continues (#132/#111, Q1) — the stub gh's `gh pr list` call fails: rc 0, the
# WARN stem printed, and the script still reaches its closing Reminder line, proving it runs to
# completion instead of dying at the third gh call in a rate-limit window.
case_pr_list_failure_continues() {
  local dir; dir="$(mk_repo pr-list-failure-continues)"
  cat > "$dir/prs.json" <<'EOF'
[]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir" ok fail
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "could not fetch the PR list"
  expect "Reminder:"
}

# empty-needle-guard (#262-1) — exercises every guarded helper in this file (expect, expect_absent,
# expect_call, expect_no_call, expect_count) with an empty needle, and asserts the guard fired for
# each: sets $cleanup_out/$calls to fixed non-empty values first (so a non-guarded regression
# couldn't pass vacuously against empty captured output), calls all five with "", then checks the
# ACCUMULATED __ok/__why saved off before this case's own __ok/__why are reset by the runner loop.
# Measured mutant: delete `needle_required expect_count "$needle" || return 0` from expect_count
# only — `bash dev/cleanup-tests.sh` goes from 18 pass, 0 fail to 17 pass, 1 fail, failing exactly:
# empty-needle-guard (saved_why no longer names "expect_count:").
case_empty_needle_guard() {
  local saved_ok saved_why
  cleanup_out="fixture output for the empty-needle guard (#262)"
  calls="fixture gh call for the empty-needle guard (#262)"
  __ok=1; __why=""
  expect ""
  expect_absent ""
  expect_call ""
  expect_no_call ""
  expect_count "" 0
  saved_ok="$__ok"
  saved_why="$__why"
  __ok=1; __why=""
  if [ "$saved_ok" -ne 0 ]; then
    __ok=0; __why="${__why}empty-needle guard never fired (saved_ok=$saved_ok)\n"
  fi
  local helper
  for helper in expect expect_absent expect_call expect_no_call expect_count; do
    case "$saved_why" in
      *"$helper: empty needle"*) : ;;
      *) __ok=0; __why="${__why}$helper's empty-needle guard did not name itself: '$saved_why'\n" ;;
    esac
  done
}

# ---------------------------------------------------------------------------------------------
# name|fn|desc
cases=(
  "keep-part-of|case_keep_part_of|MERGED PR body says Part of #n: issue left open, pr-open removed to re-queue"
  "keep-open-sibling|case_keep_open_sibling|a lower-numbered OPEN sibling PR: issue left open, no label edit at all"
  "close-marker-body-only|case_close_marker_body_only|<!-- harness-multi-pr --> in the issue body only (no longer honoured): issue closed on the normal path"
  "keep-marker-comment|case_keep_marker_comment|<!-- harness-multi-pr --> in a comment from an OWNER: trusted, issue left open"
  "keep-multi-pr-label|case_keep_multi_pr_label|the multi-pr label on the issue: primary signal, issue left open, no comment fetch"
  "close-untrusted-comment-marker|case_close_untrusted_comment_marker|<!-- harness-multi-pr --> from a NONE-association comment: ignored, issue closed, exactly one WARN naming the comment"
  "warn-untrusted-marker-no-fix|case_warn_untrusted_marker_no_fix|the untrusted-marker fixture run WITHOUT --fix: the same WARN still prints once, no gh mutation call"
  "close-missing-association-marker|case_close_missing_association_marker|<!-- harness-multi-pr --> from a comment with no authorAssociation field: fail-closed untrusted, same as NONE"
  "keep-marker-comment-lowercase-assoc|case_keep_marker_comment_lowercase_assoc|<!-- harness-multi-pr --> from a lowercase 'owner' association: still trusted (ascii_upcase), issue left open"
  "keep-wrong-issue-number|case_keep_wrong_issue_number|Closes #70 does not satisfy issue #7: issue left open"
  "close-normal|case_close_normal|control: Closes #7, no sibling, no marker: issue closed"
  "keep-no-fix|case_keep_no_fix|KEEP fixture run without --fix: no gh mutation call, KEEP line still printed"
  "pull-failure-continues|case_pull_failure_continues|no remote: pull fails, script warns and continues into label hygiene"
  "pull-ok|case_pull_ok|control: bare origin with upstream set, no fast-forward warning"
  "repo-view-failure-continues|case_repo_view_failure_continues|gh repo view fails: rc 0, WARN, sync skipped, run reaches label hygiene"
  "current-branch-failure-continues|case_current_branch_failure_continues|git branch --show-current fails: rc 0, WARN, sync skipped, run continues"
  "pr-list-failure-continues|case_pr_list_failure_continues|gh pr list fails: rc 0, WARN, run still reaches the closing reminder"
  "empty-needle-guard|case_empty_needle_guard|#262: expect/expect_absent/expect_call/expect_no_call/expect_count all refuse an empty needle"
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
    # #255 — bounded diagnostics: surface bin/cleanup-after-merge.sh's own captured output (never
    # a full-consumption `head`) so a shell-level diagnostic that leaked into $cleanup_out isn't
    # silently discarded.
    if [ -n "$cleanup_out" ]; then
      printf '%s\n' "$cleanup_out" | sed -n '1,40p' | sed 's/^/    | /'
    fi
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
