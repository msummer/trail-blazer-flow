#!/usr/bin/env bash
#
# cleanup-tests.sh — fixture-based negative-test harness for bin/cleanup-after-merge.sh, not
# this repo's own gate (that's dev/selfcheck.sh + dev/selfcheck-tests.sh) and not the consumer
# doctor's harness (dev/doctor-tests.sh). Builds throwaway git repos under mktemp, with a stub
# `gh` (and, where needed, a stub `git`) on PATH, and runs the real script (and, for one
# deliberately `--json`-mutated copy, that copy — never `bin/` itself) against each, pinning the
# multi-PR KEEP behaviour (#106, revised by #231) and the best-effort pre-flight (#77, #111,
# #132): a failed `gh repo view` (default-branch lookup), `git branch --show-current`
# (current-branch lookup), `gh pr list`, `gh issue view` (the multi-PR comment-marker lookup,
# #249), or `git pull --ff-only` is reported (WARN) and survived rather than aborting the run
# before any output, that would otherwise only be hand-verified.
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
# Since #248, the stub `gh` also validates `--json` FIELD NAMES against gh's own live-probed
# field set, the same treatment #217 gave dev/planning-tests.sh's stub: `issue list`, `issue
# view`, and `pr list` each reject an unsupported field with gh's own `Unknown JSON field:
# "<name>"` line on stderr and exit 1, so a future cleanup change asking gh for a field it does
# not support turns THIS repo's CI red instead of being silently served a fixture (see
# `validate_json_fields`'s own comment below for the two constants and what stays unvalidated).
# Since #249, a failed or malformed `gh issue view --json comments` (the multi-PR comment-marker
# lookup) no longer falls back to "no marker found" — it WARNs once, naming the failure route,
# and leaves the issue exactly as found (open, `pr-open` still attached) in both `--fix` and
# report-only modes; `build_stub_gh`'s new `VIEW_MODE` parameter (`ok`/`fail`/`malformed`)
# fixtures both routes, and a fifth fixture pins that the cheaper `multi-pr`-label KEEP signal
# still short-circuits before this lookup is ever attempted.
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

# build_stub_gh DIR [REPO_MODE] [PR_MODE] [VIEW_MODE] — writes an executable DIR/gh (absolute
# paths to DIR's own prs.json, issues.json, comments.json baked in) and resets DIR/gh-calls.log
# empty. Deterministic and offline. REPO_MODE (default "ok") composes the `repo)` arm with
# printf, outside the quoted heredoc — exactly the idiom dev/doctor-tests.sh's build_stub_gh uses
# for its `repo)`/`label)` lines: "ok" answers "main" (every fixture's branch is renamed to
# match; every case that doesn't pass this parameter gets that answer), "fail" exits 1
# (simulating a rate-limited/unauthenticated `gh repo view`). PR_MODE (default "ok", same idiom)
# composes the `pr list)` arm: "ok" cats DIR/prs.json, "fail" exits 1 (simulating a failed
# `gh pr list`) — `validate_json_fields` (below) runs in BOTH modes, printed before the
# mode-dependent body, so a bad field list is still caught on a fixture that also wants to
# simulate a failed `gh pr list`. VIEW_MODE (#249, default "ok", the same positional idiom as
# REPO_MODE/PR_MODE rather than the marker-file approach #249's issue text sketches — it matches
# the run's overall behaviour, not a per-issue one) composes the `issue view)` arm: "ok" cats
# DIR/comments.json (the `--json comments`-shaped payload the marker lookup expects), "fail"
# exits 1 with no output (simulating a rate-limited/unauthenticated `gh issue view`), "malformed"
# prints a non-JSON line and exits 0 (simulating a response gh itself returned successfully but
# that fails to parse — e.g. a truncated body). Otherwise: `issue list` cats DIR/issues.json when
# invoked with the literal `--label pr-open` flag pair (the label-hygiene query) and prints `[]`
# for any other `issue list` invocation (the follow-ups query, never exercised by these fixtures
# since their prs.json carries no CLOSED entry) — since #231, the label-hygiene arm additionally
# PROJECTS the real jq's own `with_entries(select(...))` idiom over DIR/issues.json against
# whatever field list followed a literal `--json` token in the invocation, the same
# document-semantics faithfulness #196 (LESSON 2026-09-01(c)) requires: a fixture whose script
# drops `labels` from its own `--json` list gets back objects with no `labels` key at all, not a
# stub that silently keeps serving it — which is what makes the `keep-multi-pr-label` case's
# mutation proof possible. `issue comment|edit|close` append the full `"$*"` line to
# DIR/gh-calls.log and exit 0 — the machine-derived payload every case's assertions read back.
# Anything else exits 1. The `__DIR__` placeholder + sed substitution step stays for the
# fixed part of the script (unchanged from before REPO_MODE/PR_MODE existed).
#
# Since #248, the generated stub ALSO carries two live-probed field-set constants and a
# `validate_json_fields` helper (ported from dev/planning-tests.sh's #217 treatment — see that
# function's own comment for the full rationale; not shared as a file, per this repo's
# `dev/` scripts are standalone by design convention) wired as the FIRST statement of the
# `issue) list)`, `issue) view)`, and `pr) list)` arms: a call asking for a field name outside
# the probed set is rejected with gh's own `Unknown JSON field: "<name>"` line on stderr and
# exit 1, before that arm's own dispatch runs at all. `GH_ISSUE_JSON_FIELDS` (27 names) is
# byte-identical to dev/planning-tests.sh's own constant of the same name (both probed against
# gh 2.97.0 (2026-07-31); this file's probe is 2026-09-09, planning-tests.sh's is 2026-09-05); it
# validates BOTH `issue list` and `issue view`, since gh accepts an identical field set for both
# subcommands. `GH_PR_JSON_FIELDS` (46 names) is a DIFFERENT set — `headRefName`, `baseRefName`,
# `mergeStateStatus`, and `reviewDecision` are PR-only, so one constant cannot serve both
# subcommand families; `headRefName` is the only field bin/cleanup-after-merge.sh itself requests
# that discriminates the two (it appears in the PR set, not the issue set), which is what the
# `stub-json-field-sets-are-subcommand-scoped` case exercises. The stub's `repo)` arm and its
# `issue) comment|edit|close)` arm stay UNVALIDATED, deliberately: `repo)` exposes a third field
# set (`gh repo view --json`) that was never live-probed — inventing an unverified constant would
# be worse than disclosing the hole (RESOLVED, #248's plan) — and `comment|edit|close` take no
# `--json` field list at all. Faithfulness note (LESSON 2026-09-01(c)): these two constants
# encode a live probe of ONE gh version; if a future gh renames a field, this harness rejects a
# call real gh would accept (a false red, visible) rather than accept one real gh would reject (a
# false green) — that asymmetry is deliberate. Real gh's fuller rejection shape (`Unknown JSON
# field: "<name>"`, then `Available fields:` plus the listing) is modelled only as far as that
# first line, because bin/cleanup-after-merge.sh reads only gh's exit status — the first line is
# emitted only because THIS harness's own rejection cases assert it via the stderr helper below
# (status alone would pass vacuously).
build_stub_gh() {
  local dir="$1" repo_mode="${2:-ok}" pr_mode="${3:-ok}" view_mode="${4:-ok}" tmpl="$dir/gh.tmpl"
  : > "$dir/gh-calls.log"
  {
    printf '#!%s\n' "$bash_bin"
    cat <<'EOF'
# GH_ISSUE_JSON_FIELDS / GH_PR_JSON_FIELDS (#248) — gh 2.97.0 (2026-07-31), probed 2026-09-09
# against a live repo (transcript: the #248 plan's "Verified facts"); `gh issue list --json` and
# `gh issue view --json` accept an IDENTICAL 27-field set (GH_ISSUE_JSON_FIELDS is
# byte-identical to dev/planning-tests.sh's own constant of the same name, probed there
# 2026-09-05); `gh pr list --json` accepts a DIFFERENT 46-field set (GH_PR_JSON_FIELDS) — the two
# subcommand families' field sets differ, so one constant cannot serve both.
GH_ISSUE_JSON_FIELDS="assignees author blockedBy blocking body closed closedAt closedByPullRequestsReferences comments createdAt id isPinned issueType labels milestone number parent projectCards projectItems reactionGroups state stateReason subIssues subIssuesSummary title updatedAt url"
GH_PR_JSON_FIELDS="additions assignees author autoMergeRequest baseRefName baseRefOid body changedFiles closed closedAt closingIssuesReferences comments commits createdAt deletions files fullDatabaseId headRefName headRefOid headRepository headRepositoryOwner id isCrossRepository isDraft labels latestReviews maintainerCanModify mergeCommit mergeStateStatus mergeable mergedAt mergedBy milestone number potentialMergeCommit projectCards projectItems reactionGroups reviewDecision reviewRequests reviews state statusCheckRollup title updatedAt url"

# validate_json_fields ALLOWED "$@" (#248, ported from dev/planning-tests.sh's #217 treatment) —
# takes the allowed-field string as $1, shifts, then scans the REMAINING argv for a literal
# --json token and takes the NEXT token as gh's own comma-separated field list, rejecting the
# FIRST (leftmost) token not present in ALLOWED with gh's own `Unknown JSON field: "<name>"` line
# on stderr and exit 1. A call with no --json argument at all fails loud with a distinct
# diagnostic (`stub: no --json argument in: gh <argv>`) instead of silently falling through to a
# zero-iteration loop and being served a fixture — every call bin/cleanup-after-merge.sh makes to
# a validated arm carries --json, so this is safe. Deliberately separate from the `issue list`
# arm's own field-projection loop below: this scan takes the FIRST --json occurrence, the
# projector takes the LAST — they differ because no real call passes two, so the difference is
# never observable, but the two loops are not merged. Bash-3.2-portable (assertion 1.4 / the
# macOS CI job): no arrays, no `declare -A`, plain `for tok in $list` word-splitting on a
# function-local `IFS=,`.
validate_json_fields() {
  local allowed="$1"; shift
  local orig="$*"
  local list="" found=0 tok
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--json" ]; then
      shift
      list="${1:-}"
      found=1
      break
    fi
    shift
  done
  if [ "$found" -ne 1 ]; then
    echo "stub: no --json argument in: gh $orig" >&2
    exit 1
  fi
  local IFS=,
  for tok in $list; do
    case " $allowed " in
      *" $tok "*) : ;;
      *)
        echo "Unknown JSON field: \"$tok\"" >&2
        exit 1
        ;;
    esac
  done
}
EOF
    printf 'case "$1" in\n'
    if [ "$repo_mode" = fail ]; then
      printf '  repo) exit 1 ;;\n'
    else
      printf '  repo) echo main; exit 0 ;;\n'
    fi
    printf '  pr)\n    case "$2" in\n'
    printf '      list)\n        validate_json_fields "$GH_PR_JSON_FIELDS" "$@"\n'
    if [ "$pr_mode" = fail ]; then
      printf '        exit 1 ;;\n'
    else
      printf '        cat "__DIR__/prs.json"; exit 0 ;;\n'
    fi
    cat <<'EOF'
      *) exit 1 ;;
    esac
    ;;
  issue)
    case "$2" in
      list)
        validate_json_fields "$GH_ISSUE_JSON_FIELDS" "$@"
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
EOF
    if [ "$view_mode" = fail ]; then
      printf '      view) validate_json_fields "$GH_ISSUE_JSON_FIELDS" "$@"; exit 1 ;;\n'
    elif [ "$view_mode" = malformed ]; then
      printf '      view) validate_json_fields "$GH_ISSUE_JSON_FIELDS" "$@"; printf "not a json document\\n"; exit 0 ;;\n'
    else
      printf '      view) validate_json_fields "$GH_ISSUE_JSON_FIELDS" "$@"; cat "__DIR__/comments.json"; exit 0 ;;\n'
    fi
    cat <<'EOF'
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

# run_cleanup_at DIR SCRIPT [ARGS...] — runs an arbitrary SCRIPT path (the real
# bin/cleanup-after-merge.sh, or, for the one end-to-end #248 case, a deliberately
# `--json`-mutated COPY of it — never bin/ itself) with cwd, HOME, and XDG_CONFIG_HOME set into
# the fixture and DIR (holding the stub gh) prepended to PATH, leaving $cleanup_out/$cleanup_rc/
# $calls set as globals ($calls is DIR/gh-calls.log's content after the run). The `2>&1` capture
# into $cleanup_out stays MERGED, unchanged from before this refactor — every line
# bin/cleanup-after-merge.sh itself prints is `echo` to stdout, and no criterion anywhere in this
# file names a stream for the SCRIPT under test (only the stub's own `Unknown JSON field:`
# claims, asserted via run_stub_gh below, name a stream). Deliberately NOT invoked via command
# substitution itself (same idiom as dev/doctor-tests.sh's run_doctor) — call as a plain
# statement and read the globals after.
# run_cleanup DIR [ARGS...] — delegates to run_cleanup_at with the real
# bin/cleanup-after-merge.sh; every pre-#248 case that runs the script (17 of them —
# empty-needle-guard is the one pre-#248 case that invokes no runner at all) calls this exact
# form, untouched by the refactor.
cleanup_out=""
cleanup_err=""
cleanup_rc=0
calls=""
run_cleanup_at() {
  local dir="$1" script="$2"; shift 2
  cleanup_out="$(cd "$dir" && HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdgcfg" PATH="$dir:$PATH" "$bash_bin" "$script" "$@" 2>&1)"
  cleanup_rc=$?
  calls="$(cat "$dir/gh-calls.log" 2>/dev/null || true)"
}
run_cleanup() {
  local dir="$1"; shift
  run_cleanup_at "$dir" "$root/bin/cleanup-after-merge.sh" "$@"
}

# run_stub_gh DIR [ARGS...] (#248) — invokes DIR's own stub `gh` directly (built by
# build_stub_gh) instead of bin/cleanup-after-merge.sh, so a case can pin the stub's own --json
# field-list validation without going through the script at all — mirroring
# dev/planning-tests.sh:841-851's identical-purpose runner. Captures stdout and stderr to
# SEPARATE files (LESSON 2026-09-08(b): a merged `2>&1` capture cannot pin a claim that names a
# stream), setting $cleanup_out (stdout only), $cleanup_err (stderr only, new — the merged
# run_cleanup_at/run_cleanup pair above never populates this), $cleanup_rc, and re-reading $calls
# from DIR/gh-calls.log (empty for every direct-stub case — none of them invoke
# comment/edit/close). The stub's `Unknown JSON field:`/`stub: no --json argument` diagnostics are
# asserted on $cleanup_err via expect_err below, never $cleanup_out.
run_stub_gh() {
  local dir="$1"; shift
  PATH="$dir:$PATH" "$dir/gh" "$@" >"$dir/.stdout" 2>"$dir/.stderr"
  cleanup_rc=$?
  cleanup_out="$(cat "$dir/.stdout" 2>/dev/null || true)"
  cleanup_err="$(cat "$dir/.stderr" 2>/dev/null || true)"
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
# payload). expect_err/expect_empty_out (#248) — assert against $cleanup_err/$cleanup_out, only
# ever populated by run_stub_gh's split-stream capture (LESSON 2026-09-08(b)); no criterion
# anywhere in this file names a stream for bin/cleanup-after-merge.sh's own output, only for the
# stub's own rejection diagnostics. All set $__ok=0 and append to $__why on failure. ASCII-only
# short stems: stop before the script's em dashes. expect/expect_absent/expect_call/
# expect_no_call/expect_count/expect_err are guarded by needle_required (#262). Fed via a
# here-string (`<<<"$cleanup_out"`/`<<<"$calls"`/`<<<"$cleanup_err"`, #255) rather than piping a
# `printf '%s\n' ...` writer into `grep`'s quiet mode: that early-exit reader exits on its first
# match, which can send the printf writer SIGPIPE and, under this file's `set -uo pipefail`, turn
# a genuine match into a reported pipeline failure — a here-string has no writer process, so no
# SIGPIPE is possible, and it appends exactly one trailing newline, the same as the piped printf
# did, so grep's fixed-string/count semantics are unchanged.
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
# expect_err NEEDLE (#248) — asserts $cleanup_err (populated only by run_stub_gh, never by
# run_cleanup/run_cleanup_at) contains NEEDLE, fixed-string, needle-guarded (#262) and fed via a
# here-string (#255) exactly like expect/expect_absent above. No criterion in this file names a
# stream for bin/cleanup-after-merge.sh's OWN output (it's all `echo` to stdout) — this helper
# exists only for the stub's own `Unknown JSON field:`/`stub: no --json argument` diagnostics.
expect_err() {
  needle_required expect_err "$1" || return 0
  grep -qF -- "$1" <<<"$cleanup_err" || { __ok=0; __why="${__why}missing stderr: $1\n"; }
}
# expect_empty_out (#248) — asserts $cleanup_out is exactly empty, for a rejection case where the
# stub must produce no stdout at all (the rejected arm never reaches its own cat/printf).
expect_empty_out() {
  [ -z "$cleanup_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: $cleanup_out\n"; }
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
# keep-marker-body case, inverted expectations. Mutation proof (step 13(d), RE-MEASURED
# 2026-09-09 against the 30-case suite #248/#249 grew this file to): restoring ONLY the deleted
# body-marker `elif` (re-adding `issue_body=$(printf '%s' "$issue" | jq -r '.body // ""'...)`
# plus the elif reading it) left this fixture PASSING (measured: 30 pass, 0 fail) — a surviving
# mutant, because `--json number,title,labels` no longer requests `body` at all, so the stub's
# own field projection (see build_stub_gh above) strips the key and `issue_body` reads empty
# regardless of the elif's presence; a real `gh` would behave identically. The meaningful,
# measured mutant instead restores the whole removed code path together — the elif AND `body`
# back in the `--json` field list (`--json number,title,labels,body`) — which makes this
# fixture, and only this fixture, FAIL (measured: 29 pass, 1 fail): the issue reports KEEP and
# "issue close" is never called. (Both figures move in lockstep with the suite's case count, not
# with this fixture's own behaviour — re-run, never assumed, per LESSON 2026-09-07.)
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
# needed. Mutation proof (step 13(a), RE-MEASURED 2026-09-09 against the 30-case suite):
# dropping `labels` from bin/cleanup-after-merge.sh's `gh issue list --json` field list (the
# stub's field projection then serves an issue object with no labels key at all, so
# has_multi_pr_label reads false) makes `bash dev/cleanup-tests.sh` go from 30 pass, 0 fail to
# 28 pass, 2 fail, failing EXACTLY this fixture AND keep-multi-pr-label-view-failure-short-
# circuits (#249, added by this diff — it depends on the identical has_multi_pr_label signal) —
# a WIDER failing set than the pre-#249 measurement named, confirmed by re-running rather than
# assumed (LESSON 2026-09-07).
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
# Mutation proof (step 13(b), RE-MEASURED 2026-09-09 against the 30-case suite): deleting the
# trusted `select` clause from the `trusted_hits` jq filter (so ANY marker-carrying comment
# counts as trusted, regardless of authorAssociation) makes `bash dev/cleanup-tests.sh` go from
# 30 pass, 0 fail to 28 pass, 2 fail, failing EXACTLY this fixture AND
# close-missing-association-marker (below — its comment has no authorAssociation key at all,
# which this mutation also treats as trusted): both KEEP instead of closing. Re-run rather than
# assumed (LESSON 2026-09-07) — the failing set is two fixtures, not one.
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
# --fix). Mutation proof (RE-MEASURED 2026-09-09 against the 30-case suite): wrapping the
# untrusted-marker WARN `echo` in `if $FIX; then ... fi` makes `bash dev/cleanup-tests.sh` go
# from 30 pass, 0 fail to 29 pass, 1 fail, failing EXACTLY this fixture — the "ignoring a
# harness-multi-pr marker" WARN line disappears (count 0, not 1) when the run is report-only.
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
# RE-MEASURED 2026-09-09 against the 30-case suite): deleting the whole untrusted `select`/WARN
# `if`/`while` block (the `if [[ -n "$untrusted_marker_lines" ]]; then ... fi` around the
# `echo "WARN ... ignoring a harness-multi-pr marker"` line) makes `bash dev/cleanup-tests.sh` go
# from 30 pass, 0 fail to 27 pass, 3 fail, failing EXACTLY this fixture,
# close-untrusted-comment-marker, and warn-untrusted-marker-no-fix (every fixture that asserts
# the "ignoring a harness-multi-pr marker" WARN line, not just this one — the WARN line
# disappears, count 0, not 1, for all three). Re-run rather than assumed (LESSON 2026-09-07).
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
# other fixture distinguishes): still trusted, still KEEP. Mutation proof (step 13(e),
# RE-MEASURED 2026-09-09 against the 30-case suite): deleting `ascii_upcase` from the
# `trusted_hits` jq filter makes `bash dev/cleanup-tests.sh` go from 30 pass, 0 fail to 29 pass,
# 1 fail, failing EXACTLY this fixture — the lowercase association no longer matches the
# uppercase TRUSTED_ASSOCIATIONS list, so the marker is treated as untrusted and the issue
# closes instead of KEEPing.
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

# empty-needle-guard (#262-1, extended by #248) — exercises every guarded helper in this file
# (expect, expect_absent, expect_call, expect_no_call, expect_count, expect_err) with an empty
# needle, and asserts the guard fired for each: sets $cleanup_out/$calls/$cleanup_err to fixed
# non-empty values first (so a non-guarded regression couldn't pass vacuously against empty
# captured output), calls all six with "", then checks the ACCUMULATED __ok/__why saved off
# before this case's own __ok/__why are reset by the runner loop.
# Measured mutants (re-measured against the 30-case suite after #248/#249's cases were added):
#   - delete `needle_required expect_count "$needle" || return 0` from expect_count only —
#     `bash dev/cleanup-tests.sh` goes from 30 pass, 0 fail to 29 pass, 1 fail, failing exactly:
#     empty-needle-guard (saved_why no longer names "expect_count:").
#   - delete `needle_required expect_err "$1" || return 0` from expect_err only — 30 pass, 0 fail
#     to 29 pass, 1 fail, failing exactly: empty-needle-guard (saved_why no longer names
#     "expect_err:").
case_empty_needle_guard() {
  local saved_ok saved_why
  cleanup_out="fixture output for the empty-needle guard (#262)"
  calls="fixture gh call for the empty-needle guard (#262)"
  cleanup_err="fixture stderr for the empty-needle guard (#248)"
  __ok=1; __why=""
  expect ""
  expect_absent ""
  expect_call ""
  expect_no_call ""
  expect_count "" 0
  expect_err ""
  saved_ok="$__ok"
  saved_why="$__why"
  __ok=1; __why=""
  if [ "$saved_ok" -ne 0 ]; then
    __ok=0; __why="${__why}empty-needle guard never fired (saved_ok=$saved_ok)\n"
  fi
  local helper
  for helper in expect expect_absent expect_call expect_no_call expect_count expect_err; do
    case "$saved_why" in
      *"$helper: empty needle"*) : ;;
      *) __ok=0; __why="${__why}$helper's empty-needle guard did not name itself: '$saved_why'\n" ;;
    esac
  done
}

# ---------------------------------------------------------------------------------------------
# Part 2 cases (#248): these invoke the stub `gh` DIRECTLY via run_stub_gh, never through
# bin/cleanup-after-merge.sh — pinning the stub's own --json field-list validation in isolation
# from the script under test. mk_repo's git repo is unused by these cases (the fixture dir is
# only a place to hold gh-calls.log/prs.json/issues.json/comments.json and the generated stub) —
# reused only because it's the cheapest way to get a throwaway directory with those globals set
# up consistently with every other case in this file. Each rejection case asserts the stderr
# line itself (expect_err), not exit status alone: an ABSENT fixture file also exits 1 (e.g. a
# typo'd path), so rc alone can't distinguish "the validator rejected this" from "the fixture is
# broken".

# stub-json-unknown-field-rejected-issue-list — issue) list) rejects a field outside
# GH_ISSUE_JSON_FIELDS. Mutation proof: delete `validate_json_fields "$GH_ISSUE_JSON_FIELDS" "$@"`
# from the issue) list) arm only — see the measured-mutant block after case 12 below (deletion
# (a)) for the actual re-run figures.
case_stub_json_unknown_field_rejected_issue_list() {
  local dir; dir="$(mk_repo stub-json-unknown-field-rejected-issue-list)"
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"T","labels":[]}]
EOF
  build_stub_gh "$dir"
  run_stub_gh "$dir" issue list --label pr-open --state open --json number,title,bogusField --limit 100
  expect_rc 1
  expect_empty_out
  expect_err 'Unknown JSON field: "bogusField"'
}

# stub-json-unknown-field-rejected-issue-view — issue) view) rejects a field outside
# GH_ISSUE_JSON_FIELDS. Mutation proof: deletion (b) below (the issue) view) arm's own call).
case_stub_json_unknown_field_rejected_issue_view() {
  local dir; dir="$(mk_repo stub-json-unknown-field-rejected-issue-view)"
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  run_stub_gh "$dir" issue view 7 --json comments,bogusField
  expect_rc 1
  expect_empty_out
  expect_err 'Unknown JSON field: "bogusField"'
}

# stub-json-unknown-field-rejected-pr-list — pr) list) rejects a field outside
# GH_PR_JSON_FIELDS. Mutation proof: deletion (c) below (the pr) list) arm's own call).
case_stub_json_unknown_field_rejected_pr_list() {
  local dir; dir="$(mk_repo stub-json-unknown-field-rejected-pr-list)"
  cat > "$dir/prs.json" <<'EOF'
[]
EOF
  build_stub_gh "$dir"
  run_stub_gh "$dir" pr list --state all --limit 200 --json number,state,bogusField
  expect_rc 1
  expect_empty_out
  expect_err 'Unknown JSON field: "bogusField"'
}

# stub-json-field-sets-are-subcommand-scoped — the only case that fails if either constant is
# used on the wrong subcommand: headRefName is a PR-only field (present in GH_PR_JSON_FIELDS,
# absent from GH_ISSUE_JSON_FIELDS) and the only field bin/cleanup-after-merge.sh itself requests
# that discriminates the two sets. `pr list` accepts and SERVES it; `issue list` and `issue view`
# both reject it. Mutation proof: swap (d)/(e) below (GH_PR_JSON_FIELDS <-> GH_ISSUE_JSON_FIELDS
# on the wrong arms).
case_stub_json_field_sets_are_subcommand_scoped() {
  local dir; dir="$(mk_repo stub-json-field-sets-are-subcommand-scoped)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":1,"state":"OPEN","headRefName":"claude/1-x","body":""}]
EOF
  build_stub_gh "$dir"
  run_stub_gh "$dir" pr list --state all --limit 200 --json number,state,headRefName,body
  expect_rc 0
  expect '"headRefName":"claude/1-x"'
  run_stub_gh "$dir" issue list --label pr-open --state open --json number,title,headRefName --limit 100
  expect_rc 1
  expect_err 'Unknown JSON field: "headRefName"'
  run_stub_gh "$dir" issue view 7 --json comments,headRefName
  expect_rc 1
  expect_err 'Unknown JSON field: "headRefName"'
}

# stub-json-script-field-lists-accepted — the non-vacuity control: all four field lists
# bin/cleanup-after-merge.sh really requests are accepted AND SERVED (the payload is asserted,
# not just rc 0) — a validator that rejects everything, or a constant missing a field the script
# really asks for, would turn the whole harness into a false alarm. Mutation proof: (f) collapse
# the membership case to an unconditional accept survives this case (expected — it's the control
# for over-rejection, not under-rejection) but the deletion mutants above still fail without a
# validator call at all; (g) delete `labels` from GH_ISSUE_JSON_FIELDS below, which fails this
# case specifically (the second call below would then be rejected).
case_stub_json_script_field_lists_accepted() {
  local dir; dir="$(mk_repo stub-json-script-field-lists-accepted)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"T","labels":[]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  run_stub_gh "$dir" pr list --state all --limit 200 --json number,state,headRefName,body
  expect_rc 0
  expect '"headRefName":"claude/7-x"'
  run_stub_gh "$dir" issue list --label pr-open --state open --json number,title,labels --limit 100
  expect_rc 0
  expect '"title":"T"'
  run_stub_gh "$dir" issue list --search "is:open is:issue -label:no-plan -label:pr-open" --json number,title,body --limit 200
  expect_rc 0
  [ "$cleanup_out" = "[]" ] || { __ok=0; __why="${__why}expected [] from the follow-up candidates query, got: $cleanup_out\n"; }
  run_stub_gh "$dir" issue view 7 --json comments
  expect_rc 0
  expect '"comments":[]'
}

# stub-json-missing-json-argument-fails-loud — a validated arm called with NO --json argument at
# all fails loud with a distinct diagnostic instead of silently falling through to a
# zero-iteration loop and being served a fixture. Mutation proof: (h) `if [ "$found" -ne 1 ]` ->
# `if false` below.
case_stub_json_missing_json_argument_fails_loud() {
  local dir; dir="$(mk_repo stub-json-missing-json-argument-fails-loud)"
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"T","labels":[]}]
EOF
  build_stub_gh "$dir"
  run_stub_gh "$dir" issue list --label pr-open --state open --limit 100
  expect_rc 1
  expect_empty_out
  expect_err 'stub: no --json argument'
}

# ---------------------------------------------------------------------------------------------
# Part 3 case (#248 + #249), end-to-end: a `--json`-mutated COPY of bin/cleanup-after-merge.sh
# (never bin/ itself), run through run_cleanup_at with the stub `gh` on PATH — the only case that
# proves the rejection actually reaches the SCRIPT (not just the stub's own dispatch), and the
# only one that exercises #248 and #249 together: it reproduces the exact user-visible failure
# #248's issue names (a future cleanup change that asks gh for a field it doesn't accept) and
# shows the #249 remedy (WARN-and-keep instead of a silent close). The `sed` substitution is
# GLOBAL on the line it matches, so it would also rewrite any occurrence inside a comment in the
# copy — harmless, since only the one LIVE call site (`--json comments`, line ~238) is
# load-bearing; "--json comments" occurs exactly once in the real script today, so this mutation
# has exactly one live target. Guarded by `cmp -s` so a future spelling change in the script's
# `--json comments` call fails this CASE ("mutation did not apply") instead of silently passing
# with the mutation never having applied. Mutation proof: (b) delete `validate_json_fields
# "$GH_ISSUE_JSON_FIELDS" "$@"` from the `issue) view)` arm below; also (f) collapse the
# membership case to an unconditional accept below (either lets the stub serve the mutated
# `comments,bogusField` list instead of rejecting it); also (i) restore
# bin/cleanup-after-merge.sh's fetch-failure swallow below (the sed copy is taken from the
# working tree at case-run time, so this mutation carries into the freshly generated mutant.sh
# too and the script falls back to "no marker" instead of taking the #249 WARN-and-keep branch).
case_script_unknown_json_field_warns_and_keeps() {
  local dir; dir="$(mk_repo script-unknown-json-field-warns-and-keeps)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Ordinary issue","labels":[],"body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  sed 's/--json comments/--json comments,bogusField/' "$root/bin/cleanup-after-merge.sh" > "$dir/mutant.sh"
  if cmp -s "$root/bin/cleanup-after-merge.sh" "$dir/mutant.sh"; then
    __ok=0
    __why="${__why}mutation did not apply — the script's --json comments invocation shape changed\n"
    return
  fi
  build_stub_gh "$dir"
  run_cleanup_at "$dir" "$dir/mutant.sh" --fix
  expect_rc 0
  expect_count "the multi-PR comment-marker lookup failed" 1
  expect "(gh issue view failed - rate limit, auth, or network?)"
  expect_no_call "issue close"
}

# ---------------------------------------------------------------------------------------------
# Part 4 cases (#249): a failed or malformed `gh issue view --json comments` (the multi-PR
# comment-marker lookup) WARNs once, naming the failure route, and leaves the issue exactly as
# found in BOTH --fix and report-only modes — never a silent fall-back to "no marker found". One
# fixture per mode per route (LESSON 2026-09-08), plus a fifth pinning that the cheaper
# `multi-pr`-label KEEP signal still short-circuits before this lookup is ever attempted.

# view-failure-warns-and-keeps — a failed `gh issue view`, run with --fix: WARN counted exactly
# once, the fetch route phrase present, no gh mutation call at all, and the ordinary close-path
# "FIXED #7" line absent. Mutation proof: (i) restore `|| echo '{"comments":[]}'` below.
case_view_failure_warns_and_keeps() {
  local dir; dir="$(mk_repo view-failure-warns-and-keeps)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Ordinary issue","labels":[],"body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir" ok ok fail
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_count "the multi-PR comment-marker lookup failed" 1
  expect "(gh issue view failed - rate limit, auth, or network?)"
  expect_absent "FIXED #7"
  expect_calls_empty
}

# view-failure-warns-no-fix — the same fixture WITHOUT --fix: the same single WARN still prints,
# and the report-only "close manually" WARN does NOT print for this issue. Mutation proof:
# (k) wrap the new decision branch in `if $FIX; then ... fi` below.
case_view_failure_warns_no_fix() {
  local dir; dir="$(mk_repo view-failure-warns-no-fix)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Ordinary issue","labels":[],"body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir" ok ok fail
  run_cleanup "$dir"
  expect_rc 0
  expect_count "the multi-PR comment-marker lookup failed" 1
  expect "(gh issue view failed - rate limit, auth, or network?)"
  expect_absent "close manually"
  expect_calls_empty
}

# view-malformed-warns-and-keeps — `gh issue view` SUCCEEDS but returns a non-JSON document, run
# with --fix: same WARN discipline, distinguishing route phrase. Mutation proof: (j) drop the
# malformed-document `elif` branch below (fold it back into the failed-fetch route only).
case_view_malformed_warns_and_keeps() {
  local dir; dir="$(mk_repo view-malformed-warns-and-keeps)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Ordinary issue","labels":[],"body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir" ok ok malformed
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_count "the multi-PR comment-marker lookup failed" 1
  expect "(the comments response was not valid JSON)"
  expect_absent "FIXED #7"
  expect_calls_empty
}

# view-malformed-warns-no-fix — the same malformed fixture WITHOUT --fix. Mutation proof: (j)
# drop the malformed-document `elif` branch below; also (k) wrap the new decision branch in
# `if $FIX; then ... fi` below — this is the one case both mutants' failing sets name (LESSON
# 2026-09-08: it is the only fixture that is both malformed-route AND report-only).
case_view_malformed_warns_no_fix() {
  local dir; dir="$(mk_repo view-malformed-warns-no-fix)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Ordinary issue","labels":[],"body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir" ok ok malformed
  run_cleanup "$dir"
  expect_rc 0
  expect_count "the multi-PR comment-marker lookup failed" 1
  expect "(the comments response was not valid JSON)"
  expect_absent "close manually"
  expect_calls_empty
}

# keep-multi-pr-label-view-failure-short-circuits — the primary `multi-pr`-label KEEP signal is
# still evaluated BEFORE the comment-marker lookup: a labelled issue KEEPs exactly as it does
# today even when the view arm is failing, and prints NO lookup WARN at all (a rate-limit window
# on the fallback lookup must not spuriously touch an issue the label already decided). Mutation
# proof: (l) delete the `has_multi_pr_label` elif (or move it below the lookup) in
# bin/cleanup-after-merge.sh.
case_keep_multi_pr_label_view_failure_short_circuits() {
  local dir; dir="$(mk_repo keep-multi-pr-label-view-failure-short-circuits)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Labelled split","labels":[{"name":"multi-pr"}],"body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir" ok ok fail
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "KEEP  #7 (Labelled split): PR #12 merged as part of a multi-PR issue (the issue carries the multi-pr label)"
  expect_count "the multi-PR comment-marker lookup failed" 0
  expect_no_call "issue close"
  expect_call "remove-label pr-open"
}

# MEASURED MUTANTS (2026-09-09), applied one at a time to the working tree and reverted
# byte-identically immediately after each measurement (backup refreshed immediately before each
# mutation, restore verified with a full `diff`, per LESSON 2026-09-07), full suite
# (`bash dev/cleanup-tests.sh`) re-run after each, against this file's final 30-case registry:
#   (a) delete `validate_json_fields "$GH_ISSUE_JSON_FIELDS" "$@"` from the `issue) list)` arm
#       only: 27 pass, 3 fail, failing EXACTLY stub-json-unknown-field-rejected-issue-list,
#       stub-json-field-sets-are-subcommand-scoped, stub-json-missing-json-argument-fails-loud.
#   (b) delete the same call from the `issue) view)` arm only: 27 pass, 3 fail, failing EXACTLY
#       stub-json-unknown-field-rejected-issue-view, stub-json-field-sets-are-subcommand-scoped,
#       script-unknown-json-field-warns-and-keeps.
#   (c) delete `validate_json_fields "$GH_PR_JSON_FIELDS" "$@"` from the `pr) list)` arm only:
#       29 pass, 1 fail, failing EXACTLY stub-json-unknown-field-rejected-pr-list.
#   (d) swap GH_PR_JSON_FIELDS -> GH_ISSUE_JSON_FIELDS on the `pr) list)` arm: 8 pass, 22 fail —
#       a wide cascade (bin/cleanup-after-merge.sh's own `pr list --json
#       number,state,headRefName,body` call is rejected, so almost every fixture that depends on
#       the PR list loses it), including but not limited to stub-json-field-sets-are-subcommand-
#       scoped and stub-json-script-field-lists-accepted — re-run confirmed rather than assumed
#       (LESSON 2026-09-07), passing set: pull-ok, current-branch-failure-continues,
#       pr-list-failure-continues, empty-needle-guard, stub-json-unknown-field-rejected-
#       issue-list, stub-json-unknown-field-rejected-issue-view, stub-json-unknown-field-
#       rejected-pr-list, stub-json-missing-json-argument-fails-loud.
#   (e) swap GH_ISSUE_JSON_FIELDS -> GH_PR_JSON_FIELDS on BOTH issue arms: 29 pass, 1 fail,
#       failing EXACTLY stub-json-field-sets-are-subcommand-scoped (GH_PR_JSON_FIELDS is a
#       superset of every OTHER field any fixture's issue calls request, so only the
#       subcommand-scoping case, which specifically expects headRefName to be REJECTED on
#       issue list/view, notices).
#   (f) collapse the membership `case " $allowed " in *" $tok "*) : ;; ...` to an unconditional
#       accept (`*) : ;;` as the first arm): 25 pass, 5 fail, failing EXACTLY
#       stub-json-unknown-field-rejected-issue-list, stub-json-unknown-field-rejected-issue-view,
#       stub-json-unknown-field-rejected-pr-list, stub-json-field-sets-are-subcommand-scoped,
#       script-unknown-json-field-warns-and-keeps (stub-json-missing-json-argument-fails-loud is
#       untouched — that contract is checked before the membership loop runs at all).
#   (g) delete `labels` from GH_ISSUE_JSON_FIELDS: 9 pass, 21 fail — the control's mutant, a wide
#       cascade (bin/cleanup-after-merge.sh's OWN `issue list --json number,title,labels` call is
#       now rejected, so almost every issue-list-dependent fixture fails), passing set: pull-ok,
#       current-branch-failure-continues, pr-list-failure-continues, empty-needle-guard,
#       stub-json-unknown-field-rejected-issue-list, stub-json-unknown-field-rejected-issue-view,
#       stub-json-unknown-field-rejected-pr-list, stub-json-field-sets-are-subcommand-scoped,
#       stub-json-missing-json-argument-fails-loud.
#   (h) `if [ "$found" -ne 1 ]` -> `if false`: 29 pass, 1 fail, failing EXACTLY
#       stub-json-missing-json-argument-fails-loud.
#   (i) restore bin/cleanup-after-merge.sh's `issue_comments_doc="$(gh issue view "$n" --json
#       comments 2>/dev/null || echo '{"comments":[]}')"` swallow for the FETCH-FAILURE route
#       only (keeping the malformed-document check): 27 pass, 3 fail, failing EXACTLY
#       script-unknown-json-field-warns-and-keeps, view-failure-warns-and-keeps,
#       view-failure-warns-no-fix.
#   (j) drop the malformed-document `elif` branch in bin/cleanup-after-merge.sh (folding it back
#       so only a hard fetch failure sets comments_ok=false): 28 pass, 2 fail, failing EXACTLY
#       view-malformed-warns-and-keeps, view-malformed-warns-no-fix.
#   (k) wrap the new `elif ! $comments_ok; then ... fi` decision branch in `if $FIX; then ... fi`
#       in bin/cleanup-after-merge.sh: 28 pass, 2 fail, failing EXACTLY view-failure-warns-no-fix,
#       view-malformed-warns-no-fix (LESSON 2026-09-08 — the --fix-only fixtures in this set
#       cannot see this mutant; only the report-only pair does).
#   (l) delete the `elif [[ "$has_multi_pr_label" == "true" ]]; then keep_reason=...` arm from
#       bin/cleanup-after-merge.sh's KEEP chain: 28 pass, 2 fail, failing EXACTLY
#       keep-multi-pr-label, keep-multi-pr-label-view-failure-short-circuits.

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
  "empty-needle-guard|case_empty_needle_guard|#262/#248: expect/expect_absent/expect_call/expect_no_call/expect_count/expect_err all refuse an empty needle"
  "stub-json-unknown-field-rejected-issue-list|case_stub_json_unknown_field_rejected_issue_list|#248: issue list rejects a field outside GH_ISSUE_JSON_FIELDS"
  "stub-json-unknown-field-rejected-issue-view|case_stub_json_unknown_field_rejected_issue_view|#248: issue view rejects a field outside GH_ISSUE_JSON_FIELDS"
  "stub-json-unknown-field-rejected-pr-list|case_stub_json_unknown_field_rejected_pr_list|#248: pr list rejects a field outside GH_PR_JSON_FIELDS"
  "stub-json-field-sets-are-subcommand-scoped|case_stub_json_field_sets_are_subcommand_scoped|#248: headRefName accepted on pr list, rejected on issue list and issue view"
  "stub-json-script-field-lists-accepted|case_stub_json_script_field_lists_accepted|#248: non-vacuity control — every field list the real script requests is accepted and served"
  "stub-json-missing-json-argument-fails-loud|case_stub_json_missing_json_argument_fails_loud|#248: a validated arm called with no --json argument fails loud instead of being served"
  "script-unknown-json-field-warns-and-keeps|case_script_unknown_json_field_warns_and_keeps|#248+#249 end-to-end: a --json-mutated copy of the real script hits the stub's rejection and takes the #249 WARN-and-keep path"
  "view-failure-warns-and-keeps|case_view_failure_warns_and_keeps|#249: a failed gh issue view WARNs once and keeps the issue open, with --fix"
  "view-failure-warns-no-fix|case_view_failure_warns_no_fix|#249: the same failed-view fixture without --fix — same WARN, no 'close manually' line"
  "view-malformed-warns-and-keeps|case_view_malformed_warns_and_keeps|#249: a malformed (non-JSON) gh issue view response WARNs once and keeps the issue open, with --fix"
  "view-malformed-warns-no-fix|case_view_malformed_warns_no_fix|#249: the same malformed-view fixture without --fix — same WARN, no 'close manually' line"
  "keep-multi-pr-label-view-failure-short-circuits|case_keep_multi_pr_label_view_failure_short_circuits|#249: the multi-pr label KEEP signal still short-circuits before a failing view lookup — no lookup WARN"
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
