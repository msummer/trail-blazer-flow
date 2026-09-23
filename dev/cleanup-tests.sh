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
# Per-PR history of what this harness pins: CHANGELOG.md (archive, #363). Each fixture's own
# comment states its mechanism.
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
# comment/edit/close invocation, whether or not that call goes on to fail (since #355, a logged
# line means the write was ATTEMPTED, not that it succeeded — see build_stub_gh's own comment).
# That log is the harness's own audit trail, not prose pinning.
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
# paths to DIR's own prs.json, issues.json, comments.json, and, since #370, closed-pr-open.json
# baked in) and resets DIR/gh-calls.log and (#370 kickback round 3) DIR/gh-list-calls.log empty.
# Deterministic and offline. REPO_MODE (default
# "ok") composes the `repo)` arm with
# printf, outside the quoted heredoc — exactly the idiom dev/doctor-tests.sh's build_stub_gh uses
# for its `repo)`/`label)` lines: "ok" answers "main" (every fixture's branch is renamed to
# match; every case that doesn't pass this parameter gets that answer), "fail" exits 1
# (simulating a rate-limited/unauthenticated `gh repo view`). PR_MODE (default "ok", same idiom)
# composes the `pr list)` arm: "ok" cats DIR/prs.json, "fail" exits 1 (simulating a failed
# `gh pr list`) — `validate_json_fields` (below) runs in BOTH modes, printed before the
# mode-dependent body, so a bad field list is still caught on a fixture that also wants to
# simulate a failed `gh pr list`. VIEW_MODE (#249, default "ok", the same positional idiom as
# REPO_MODE/PR_MODE rather than the marker-file approach #249's issue text sketches — it matches
# the run's overall behaviour, not a per-issue one) composes the `issue view)` arm: in its default
# "ok" mode, it cats DIR/comments-$3.json (`$3` is the issue number the `gh issue view <n> --json
# comments` call names) when that file exists, falling back to DIR/comments.json otherwise —
# letting one fixture give two different follow-up issues distinct comment state (#334, the
# `followup-notice-per-issue-state` case); "fail" exits 1 with no output (simulating a
# rate-limited/unauthenticated `gh issue view`, uniformly for every issue number — no per-issue
# override in this mode), "malformed" prints a non-JSON line and exits 0 (simulating a response gh
# itself returned successfully but that fails to parse — e.g. a truncated body), also uniform.
# Otherwise: since #370, `issue list` checks for the literal `--label pr-open --state closed`
# substring FIRST (a bash `case` takes the first matching pattern, and this substring is a
# superstring of the open query's own `--label pr-open` pattern below it, so it must come first
# to be reachable at all) — since #370 kickback round 3, entering this arm FIRST appends the
# call's own full `"$*"` to `DIR/gh-list-calls.log` (a separate log from the mutation-only
# `gh-calls.log` below, read into `$list_calls`/asserted via `expect_list_call`), regardless of
# how the call goes on to exit, so a fixture can observe the query's own literal argument list —
# a `reject-closed-list` marker file in DIR fails that call the same
# stderr+exit-1 shape as the write-rejection markers below; a `malformed-closed-list` marker file
# (checked next, mutually exclusive with `reject-closed-list` by fixture convention) instead
# prints a non-JSON line and exits 0 — gh itself answering successfully with a body that fails to
# parse, the identical VIEW_MODE=malformed shape above but call-scoped via a marker file rather
# than a build_stub_gh positional, since this query has no MODE parameter of its own — and
# otherwise it cats
# DIR/closed-pr-open.json when present, or prints `[]` when absent (which is what keeps every
# pre-#370 fixture byte-identical: none of them creates that file). THEN, `issue list` cats
# DIR/issues.json when invoked with the literal `--label pr-open` flag pair (the OPEN label-
# hygiene query) — gated the identical way by a `reject-open-list` marker, checked before the cat
# — since #334, it also cats DIR/followups.json, when that file
# exists, when invoked with the literal `is:open is:issue -label:pr-open` search predicate (the
# follow-up candidate query) — an exact-substring match, not a generic `--search` match, so a
# mutant that reintroduces the old query's `-label:no-plan` token breaks the match and falls
# through to the catch-all `[]` below — and prints `[]` for any other `issue list` invocation, or
# when DIR/followups.json is absent (which is what keeps the pre-#334 fixtures byte-identical:
# none of them creates that file, and most never reach the follow-up query at all because their
# prs.json carries no CLOSED entry). Since #231, the label-hygiene arm additionally PROJECTS the
# real jq's own `with_entries(select(...))` idiom over DIR/issues.json against whatever field list
# followed a literal `--json` token in the invocation, the same document-semantics faithfulness
# #196 (LESSON 2026-09-01(c)) requires: a fixture whose script drops `labels` from its own `--json`
# list gets back objects with no `labels` key at all, not a stub that silently keeps serving it —
# which is what makes the `keep-multi-pr-label` case's mutation proof possible; since #334, the
# follow-up arm projects DIR/followups.json the identical way, and since #370, the closed-issue
# arm projects DIR/closed-pr-open.json the identical way too — see
# `stub-json-script-field-lists-accepted`'s extension for the case that proves it.
# `issue comment|edit|close` always
# append the full `"$*"` line to DIR/gh-calls.log FIRST — so, since #355, a logged line means the
# write was ATTEMPTED, not that it succeeded — then, since #355, check for a failure-injection
# marker file in DIR before deciding how to exit: `reject-$2-once` (consumed with `rm -f`, one
# stderr diagnostic, exit 1) is checked before the permanent `reject-$2` (same diagnostic, exit
# 1, never consumed), mirroring `dev/planning-tests.sh`'s `reject-X(-once)` one-shot-then-permanent
# contract (never both present in one fixture, by the same convention). `$2` is literally
# `comment`/`edit`/`close`, so the three marker families are `reject-comment`, `reject-edit`, and
# `reject-close` (+ their `-once` twins) — `reject-edit` fires for EVERY `gh issue edit`
# invocation regardless of which flag it carries, so it covers both `--remove-label pr-open` and
# `--add-label no-plan` alike; a fixture that needs to fail only one of the two `edit` calls in an
# arm needs its own discriminator (none of the thirteen #355 fixtures below needs that). With no
# marker file present, the call exits 0 exactly as before #355. Anything else exits 1. The
# `__DIR__` placeholder + sed substitution step stays for the fixed part of the script (unchanged
# from before REPO_MODE/PR_MODE existed).
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
  : > "$dir/gh-list-calls.log"
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
          *"--label pr-open --state closed"*)
            printf '%s\n' "$*" >> "__DIR__/gh-list-calls.log"
            if [ -f "__DIR__/reject-closed-list" ]; then
              echo "stub: simulated gh issue list --state closed failure (rate limit, auth, or network?)" >&2
              exit 1
            fi
            if [ -f "__DIR__/malformed-closed-list" ]; then
              printf 'not a json document\n'
              exit 0
            fi
            if [ -f "__DIR__/closed-pr-open.json" ]; then
              if [ -n "$fields" ]; then
                jq -c --arg f "$fields" 'map(with_entries(select(.key as $k | (($f | split(",")) | index($k)) != null)))' "__DIR__/closed-pr-open.json"
              else
                cat "__DIR__/closed-pr-open.json"
              fi
            else
              printf '[]'
            fi
            ;;
          *"--label pr-open"*)
            if [ -f "__DIR__/reject-open-list" ]; then
              echo "stub: simulated gh issue list --state open failure (rate limit, auth, or network?)" >&2
              exit 1
            fi
            if [ -n "$fields" ]; then
              jq -c --arg f "$fields" 'map(with_entries(select(.key as $k | (($f | split(",")) | index($k)) != null)))' "__DIR__/issues.json"
            else
              cat "__DIR__/issues.json"
            fi
            ;;
          *"is:open is:issue -label:pr-open"*)
            if [ -f "__DIR__/followups.json" ]; then
              if [ -n "$fields" ]; then
                jq -c --arg f "$fields" 'map(with_entries(select(.key as $k | (($f | split(",")) | index($k)) != null)))' "__DIR__/followups.json"
              else
                cat "__DIR__/followups.json"
              fi
            else
              printf '[]'
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
      printf '      view)\n'
      printf '        validate_json_fields "$GH_ISSUE_JSON_FIELDS" "$@"\n'
      printf '        if [ -f "__DIR__/comments-$3.json" ]; then cat "__DIR__/comments-$3.json"; else cat "__DIR__/comments.json"; fi\n'
      printf '        exit 0 ;;\n'
    fi
    cat <<'EOF'
      comment|edit|close)
        printf '%s\n' "$*" >> "__DIR__/gh-calls.log"
        if [ -f "__DIR__/reject-$2-once" ]; then
          rm -f "__DIR__/reject-$2-once"
          echo "stub: simulated gh issue $2 failure (rate limit, auth, or network?)" >&2
          exit 1
        fi
        if [ -f "__DIR__/reject-$2" ]; then
          echo "stub: simulated gh issue $2 failure (rate limit, auth, or network?)" >&2
          exit 1
        fi
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
# $calls/$list_calls set as globals ($calls is DIR/gh-calls.log's content after the run;
# $list_calls, #370 kickback round 3, is DIR/gh-list-calls.log's content). The `2>&1` capture
# into $cleanup_out stays MERGED, unchanged from before this refactor — every line
# bin/cleanup-after-merge.sh itself prints is `echo` to stdout, and no criterion anywhere in this
# file names a stream for the SCRIPT under test (only the stub's own `Unknown JSON field:`
# claims, asserted via run_stub_gh below, name a stream). Since #355, this same merged capture is
# also what the `write-failure-gh-stderr-not-swallowed` case reads: a failed write's own stub
# diagnostic (`stub: simulated gh issue … failure …`, emitted on the STUB's stderr by
# build_stub_gh's reject-$2(-once) branches) lands in $cleanup_out too, so that case's claim is
# worded as "gh's own diagnostic is not swallowed", never "on stderr" — a stream-specific claim
# would need run_stub_gh's split capture instead (LESSON 2026-09-08(b)), which this runner
# deliberately doesn't provide. Deliberately NOT invoked via command
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
list_calls=""
run_cleanup_at() {
  local dir="$1" script="$2"; shift 2
  cleanup_out="$(cd "$dir" && HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdgcfg" PATH="$dir:$PATH" "$bash_bin" "$script" "$@" 2>&1)"
  cleanup_rc=$?
  calls="$(cat "$dir/gh-calls.log" 2>/dev/null || true)"
  list_calls="$(cat "$dir/gh-list-calls.log" 2>/dev/null || true)"
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
# payload). expect_list_call (#370 kickback round 3) — assert against $list_calls (the separate
# gh-list-calls.log payload, written only by the stub's closed-issue query arm), so it can never
# change what expect_calls_empty means for the mutation-only $calls log. expect_err/
# expect_empty_out (#248) — assert against $cleanup_err/$cleanup_out, only
# ever populated by run_stub_gh's split-stream capture (LESSON 2026-09-08(b)); no criterion
# anywhere in this file names a stream for bin/cleanup-after-merge.sh's own output, only for the
# stub's own rejection diagnostics. All set $__ok=0 and append to $__why on failure. ASCII-only
# short stems: stop before the script's em dashes. expect/expect_absent/expect_call/
# expect_no_call/expect_count/expect_err/expect_list_call are guarded by needle_required (#262).
# Fed via a
# here-string (`<<<"$cleanup_out"`/`<<<"$calls"`/`<<<"$cleanup_err"`/`<<<"$list_calls"`, #255)
# rather than piping a
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
# expect_list_call NEEDLE (#370 kickback round 3) — asserts $list_calls (DIR/gh-list-calls.log,
# populated only by the stub's closed-issue `gh issue list --label pr-open --state closed` arm,
# never by the mutation-only gh-calls.log expect_call/expect_calls_empty read) contains NEEDLE,
# fixed-string and needle-guarded (#262) exactly like expect_call above — a separate log and a
# separate helper so no existing expect_calls_empty assertion changes meaning.
expect_list_call() {
  needle_required expect_list_call "$1" || return 0
  grep -qF -- "$1" <<<"$list_calls" || { __ok=0; __why="${__why}missing gh list call: $1\n"; }
}
# expect_count NEEDLE N — asserts $cleanup_out contains exactly N lines matching NEEDLE
# (fixed-string, grep -cF), mechanically pinning "exactly one WARN" rather than mere presence.
expect_count() {
  local needle="$1" want="$2" got
  needle_required expect_count "$needle" || return 0
  got="$(grep -cF -- "$needle" <<<"$cleanup_out")"
  [ "$got" -eq "$want" ] || { __ok=0; __why="${__why}count: expected $want of '$needle', got $got\n"; }
}
# expect_section_order NEEDLE... (#370 kickback round 4) — asserts each NEEDLE is the literal
# start of some line in $cleanup_out (fixed-string `index($0, n) == 1`, one awk pass per needle
# fed a here-string, #255: no writer piped into grep's/awk's own quiet mode — a here-string has no
# writer process, so no SIGPIPE is possible) AND that their first-occurrence line numbers strictly
# increase in the order given, so one fixture can pin a section's POSITION relative to its
# neighbours, not merely its presence (each of which `expect` already covers). Needle-guarded
# (#262) exactly like every other needle-taking helper above.
expect_section_order() {
  local prev=0 ln needle
  for needle in "$@"; do
    needle_required expect_section_order "$needle" || return 0
    ln="$(awk -v n="$needle" 'index($0, n) == 1 { print NR; exit }' <<<"$cleanup_out")"
    if [ -z "$ln" ]; then
      __ok=0; __why="${__why}section order: missing '$needle'\n"
      return 0
    fi
    if [ "$ln" -le "$prev" ]; then
      __ok=0; __why="${__why}section order: '$needle' at line $ln is not after the previous section (line $prev)\n"
      return 0
    fi
    prev="$ln"
  done
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
# 2026-09-21, kickback K1, on a `tar --exclude=.git` scratch copy of the final tree, against the
# 46-case registry #248/#249/#334/kickback-K1 grew this file to; RE-MEASURED AGAIN 2026-09-23
# against this file's then-final 59-case registry; and RE-MEASURED A THIRD TIME 2026-09-23 (#370),
# by directly editing the tracked working copy in place then restoring it, against this file's
# then-final 69-case registry): restoring ONLY the deleted
# body-marker `elif` (re-adding `issue_body=$(printf '%s' "$issue" | jq -r '.body //
# ""'...)` plus the elif reading it) left this fixture PASSING all three times (46 pass, 0 fail;
# then 59 pass, 0 fail; then 69 pass, 0 fail) — a
# surviving mutant, because `--json number,title,labels` no longer requests `body` at all, so the
# stub's own field projection (see build_stub_gh above) strips the key and `issue_body` reads
# empty regardless of the elif's presence; a real `gh` would behave identically. The meaningful,
# measured mutant instead restores the whole removed code path together — the elif AND `body`
# back in the `--json` field list (`--json number,title,labels,body`) — which makes this
# fixture, and only this fixture, FAIL all three times (45 pass, 1 fail; then 58 pass, 1 fail; then
# RE-MEASURED 2026-09-23 (#370): 68 pass, 1 fail, still failing EXACTLY this fixture, unaffected by
# any of the ten new closed-sweep-* fixtures): the issue reports KEEP and
# "issue close" is never called. (All three figures move in lockstep with the suite's case count,
# not with this fixture's own behaviour — re-run, never assumed, per LESSON 2026-09-07.) Restated
# (#370 kickback round 1, 2026-09-23, mechanism-only per the growth-chain note's kickback-round
# paragraph — this mutant only reaches the multi-PR KEEP chain, which the eleventh #370 fixture's
# empty `issues.json` never exercises): 69 pass, 1 fail, still failing EXACTLY this fixture.
# Restated further (#370 kickback round 2, 2026-09-23, mechanism-only per the growth-chain note's
# kickback-round-2 paragraph — the twelfth #370 fixture's empty `issues.json` never exercises this
# chain either): 70 pass, 1 fail, still failing EXACTLY this fixture.
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
# needed. Mutation proof (step 13(a), RE-MEASURED 2026-09-21, kickback K1; RE-MEASURED AGAIN
# 2026-09-23 (#355) against this file's then-final 59-case registry; and RE-MEASURED A THIRD TIME
# 2026-09-23 (#370), in place on the tracked working copy, against this file's then-final 69-case
# registry):
# dropping `labels` from bin/cleanup-after-merge.sh's `gh issue list --json` field list (the
# stub's field projection then serves an issue object with no labels key at all, so
# has_multi_pr_label reads false) makes `bash dev/cleanup-tests.sh` go from 69 pass, 0 fail to
# 67 pass, 2 fail, failing EXACTLY this fixture AND keep-multi-pr-label-view-failure-short-
# circuits (#249, added by this diff — it depends on the identical has_multi_pr_label signal) —
# a WIDER failing set than the pre-#249 measurement named, confirmed by re-running rather than
# assumed (LESSON 2026-09-07); unchanged by #355's own thirteen new fixtures or #370's own ten new
# fixtures, none of which touches the multi-pr label signal. Restated (#370 kickback round 1,
# 2026-09-23, mechanism-only per the growth-chain note's kickback-round paragraph): 68 pass, 2
# fail, identical failing set — the eleventh #370 fixture's empty `issues.json` never touches the
# multi-pr label signal either. Restated further (#370 kickback round 2, 2026-09-23,
# mechanism-only per the growth-chain note's kickback-round-2 paragraph): 69 pass, 2 fail,
# identical failing set — the twelfth #370 fixture's empty `issues.json` never touches the
# multi-pr label signal either.
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
# Mutation proof (step 13(b), RE-MEASURED 2026-09-21, kickback K1; RE-MEASURED AGAIN 2026-09-23
# (#355) against this file's then-final 59-case registry; and RE-MEASURED A THIRD TIME 2026-09-23
# (#370), in place on the tracked working copy, against this file's then-final 69-case registry):
# deleting the
# trusted `select` clause from the `trusted_hits` jq filter (so ANY marker-carrying comment
# counts as trusted, regardless of authorAssociation) makes `bash dev/cleanup-tests.sh` go from
# 69 pass, 0 fail to 67 pass, 2 fail, failing EXACTLY this fixture AND
# close-missing-association-marker (below — its comment has no authorAssociation key at all,
# which this mutation also treats as trusted): both KEEP instead of closing. Re-run rather than
# assumed (LESSON 2026-09-07) — the failing set is two fixtures, not one; unchanged by #355 or
# #370. Restated (#370 kickback round 1, 2026-09-23, mechanism-only per the growth-chain note's
# kickback-round paragraph): 68 pass, 2 fail, identical failing set. Restated further (#370
# kickback round 2, 2026-09-23, mechanism-only per the growth-chain note's kickback-round-2
# paragraph): 69 pass, 2 fail, identical failing set.
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
# --fix). Mutation proof (RE-MEASURED 2026-09-21, kickback K1; RE-MEASURED AGAIN 2026-09-23 (#355)
# against this file's then-final 59-case registry; and RE-MEASURED A THIRD TIME 2026-09-23 (#370),
# in place on the tracked working copy, against this file's then-final 69-case registry): wrapping
# the
# untrusted-marker WARN `echo` in `if $FIX; then ... fi` makes `bash dev/cleanup-tests.sh` go
# from 69 pass, 0 fail to 68 pass, 1 fail, failing EXACTLY this fixture (unchanged by #355 or
# #370) — the "ignoring a
# harness-multi-pr marker" WARN line disappears (count 0, not 1) when the run is report-only.
# Restated (#370 kickback round 1, 2026-09-23, mechanism-only per the growth-chain note's
# kickback-round paragraph): 69 pass, 1 fail, identical failing set. Restated further (#370
# kickback round 2, 2026-09-23, mechanism-only per the growth-chain note's kickback-round-2
# paragraph): 70 pass, 1 fail, identical failing set.
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
# RE-MEASURED 2026-09-21, kickback K1; RE-MEASURED AGAIN 2026-09-23 (#355) against this
# file's then-final 59-case registry; and RE-MEASURED A THIRD TIME 2026-09-23 (#370), in place on
# the tracked working copy, against this file's then-final 69-case registry):
# deleting the whole untrusted `select`/WARN
# `if`/`while` block (the `if [[ -n "$untrusted_marker_lines" ]]; then ... fi` around the
# `echo "WARN ... ignoring a harness-multi-pr marker"` line) makes `bash dev/cleanup-tests.sh` go
# from 69 pass, 0 fail to 66 pass, 3 fail, failing EXACTLY this fixture,
# close-untrusted-comment-marker, and warn-untrusted-marker-no-fix (every fixture that asserts
# the "ignoring a harness-multi-pr marker" WARN line, not just this one — the WARN line
# disappears, count 0, not 1, for all three). Re-run rather than assumed (LESSON 2026-09-07);
# unchanged by #355 or #370. Restated (#370 kickback round 1, 2026-09-23, mechanism-only per the
# growth-chain note's kickback-round paragraph): 67 pass, 3 fail, identical failing set. Restated
# further (#370 kickback round 2, 2026-09-23, mechanism-only per the growth-chain note's
# kickback-round-2 paragraph): 68 pass, 3 fail, identical failing set.
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
# RE-MEASURED 2026-09-21, kickback K1; RE-MEASURED AGAIN 2026-09-23 (#355) against this
# file's then-final 59-case registry; and RE-MEASURED A THIRD TIME 2026-09-23 (#370), in place on
# the tracked working copy, against this file's then-final 69-case registry):
# deleting `ascii_upcase` from the
# `trusted_hits` jq filter makes `bash dev/cleanup-tests.sh` go from 69 pass, 0 fail to 68 pass,
# 1 fail, failing EXACTLY this fixture (unchanged by #355 or #370) — the lowercase association no
# longer matches the
# uppercase TRUSTED_ASSOCIATIONS list, so the marker is treated as untrusted and the issue
# closes instead of KEEPing. Restated (#370 kickback round 1, 2026-09-23, mechanism-only per the
# growth-chain note's kickback-round paragraph): 69 pass, 1 fail, identical failing set. Restated
# further (#370 kickback round 2, 2026-09-23, mechanism-only per the growth-chain note's
# kickback-round-2 paragraph): 70 pass, 1 fail, identical failing set.
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
# Measured mutants (re-measured 2026-09-21, kickback K1, on a `tar --exclude=.git` scratch copy
# of the final tree, against the then-46-case registry after #248/#249/#334/kickback-K1's
# cases were added; RE-MEASURED AGAIN 2026-09-23 (#355) against this file's then-final 59-case
# registry; and RE-MEASURED A THIRD TIME 2026-09-23 (#370), in place on the tracked working copy,
# against this file's then-final 69-case registry):
#   - delete `needle_required expect_count "$needle" || return 0` from expect_count only —
#     `bash dev/cleanup-tests.sh` goes from 69 pass, 0 fail to 68 pass, 1 fail, failing exactly:
#     empty-needle-guard (saved_why no longer names "expect_count:"), unchanged by #355 or #370.
#     Restated (#370 kickback round 1, 2026-09-23, mechanism-only per the growth-chain note's
#     kickback-round paragraph): 69 pass, 1 fail, identical failing set. Restated further (#370
#     kickback round 2, 2026-09-23, mechanism-only per the growth-chain note's kickback-round-2
#     paragraph): 70 pass, 1 fail, identical failing set.
#   - delete `needle_required expect_err "$1" || return 0` from expect_err only — 69 pass, 0 fail
#     to 68 pass, 1 fail, failing exactly: empty-needle-guard (saved_why no longer names
#     "expect_err:"), unchanged by #355 or #370. Restated (#370 kickback round 1, 2026-09-23,
#     mechanism-only per the growth-chain note's kickback-round paragraph): 69 pass, 1 fail,
#     identical failing set. Restated further (#370 kickback round 2, 2026-09-23, mechanism-only
#     per the growth-chain note's kickback-round-2 paragraph): 70 pass, 1 fail, identical failing
#     set.
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

# stub-json-script-field-lists-accepted — the non-vacuity control: all five field lists
# bin/cleanup-after-merge.sh really requests are accepted AND SERVED (the payload is asserted,
# not just rc 0) — a validator that rejects everything, or a constant missing a field the script
# really asks for, would turn the whole harness into a false alarm. Mutation proof: (f) collapse
# the membership case to an unconditional accept survives this case (expected — it's the control
# for over-rejection, not under-rejection) but the deletion mutants above still fail without a
# validator call at all; (g) delete `labels` from GH_ISSUE_JSON_FIELDS below, which fails this
# case specifically (the second call below would then be rejected). Since #370, the fifth probe
# (the closed-issue sweep's own `--json number,title` query) also proves the new arm's own field
# projection — `closed-pr-open.json` carries a `labels` key the script never requests, and
# `expect_absent '"labels"'` fails if that key leaks through unprojected. Mutation proof
# (MEASURED, 2026-09-23): (C13) deletes the closed arm's own jq projection call in the stub
# (always `cat`s closed-pr-open.json unprojected) — 69 pass, 1 fail, failing EXACTLY this case
# (RE-MEASURED against the 70-case registry, #370 kickback, 2026-09-23 — the malformed-closed-
# list marker this fixture doesn't set short-circuits (C13)'s mutated arm before it is ever
# reached, so the failing set is unchanged).
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
  cat > "$dir/closed-pr-open.json" <<'EOF'
[{"number":9,"title":"C","labels":[]}]
EOF
  build_stub_gh "$dir"
  run_stub_gh "$dir" pr list --state all --limit 200 --json number,state,headRefName,body
  expect_rc 0
  expect '"headRefName":"claude/7-x"'
  run_stub_gh "$dir" issue list --label pr-open --state open --json number,title,labels --limit 100
  expect_rc 0
  expect '"title":"T"'
  run_stub_gh "$dir" issue list --search "is:open is:issue -label:pr-open" --json number,title,body,labels --limit 200
  expect_rc 0
  [ "$cleanup_out" = "[]" ] || { __ok=0; __why="${__why}expected [] from the follow-up candidates query, got: $cleanup_out\n"; }
  run_stub_gh "$dir" issue view 7 --json comments
  expect_rc 0
  expect '"comments":[]'
  run_stub_gh "$dir" issue list --label pr-open --state closed --json number,title --limit 100
  expect_rc 0
  expect '"title":"C"'
  expect_absent '"labels"'
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

# ---------------------------------------------------------------------------------------------
# Part 5 cases (#334, extended to sixteen by kickback K1): the follow-up orphan-notice
# quarantine. All sixteen fixtures share the
# same base shape unless noted — one CLOSED, claude/50-x-headed PR (#12), an empty issues.json
# (so the pr-open section never calls `issue view` itself and can't interfere with these
# fixtures' own view-mode parameter), and a followups.json entry (issue #50) whose body carries
# <!-- harness-follow-up: PR #12 -->. Comment urls use the real
# https://example.invalid/<issue>#issuecomment-<id> shape (#220).

# followup-notice-first-run — --fix, the follow-up already carries no-plan (the #308 shape, the
# regression #334 fixes), comments empty (not yet noticed): one issue comment call whose body
# carries both marker lines, no add-label call (no-plan is already present), FIXED line present.
# Mutation proof: (m), (t), (u), (v) — see the #334 MEASURED MUTANTS block below.
case_followup_notice_first_run() {
  local dir; dir="$(mk_repo followup-notice-first-run)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_call "issue comment 50"
  expect_call "<!-- harness-audit -->"
  expect_call "<!-- harness-orphan-notice: PR #12 -->"
  expect_no_call "add-label"
  expect "FIXED #50 (Deferred later): follow-up from PR #12, closed without merge — commented"
}

# followup-notice-idempotent-second-run — --fix, comments seeded with a trusted (OWNER) comment
# already carrying <!-- harness-orphan-notice: PR #12 -->: expect_calls_empty, no FIXED, no
# STALE — the idempotence guarantee, second run. Mutation proof: (v).
case_followup_notice_idempotent_second_run() {
  local dir; dir="$(mk_repo followup-notice-idempotent-second-run)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[{"body":"Already handled.\n<!-- harness-orphan-notice: PR #12 -->\n","authorAssociation":"OWNER","url":"https://example.invalid/50#issuecomment-9101"}]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_calls_empty
  expect_absent "FIXED #50"
  expect_absent "STALE #50"
}

# followup-notice-report-only — the first-run fixture, without --fix: one STALE line,
# expect_calls_empty. Mutation proof: (m).
case_followup_notice_report_only() {
  local dir; dir="$(mk_repo followup-notice-report-only)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir"
  expect_rc 0
  expect "STALE #50 (Deferred later): filed as a follow-up from PR #12, which was closed without merging"
  expect_calls_empty
}

# followup-notice-idempotent-report-only — the idempotent-second-run fixture, without --fix
# (LESSON 2026-09-08: the criterion names both modes): no STALE line, no calls.
# Mutation proof: (v).
case_followup_notice_idempotent_report_only() {
  local dir; dir="$(mk_repo followup-notice-idempotent-report-only)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[{"body":"Already handled.\n<!-- harness-orphan-notice: PR #12 -->\n","authorAssociation":"OWNER","url":"https://example.invalid/50#issuecomment-9101"}]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir"
  expect_rc 0
  expect_absent "STALE #50"
  expect_calls_empty
}

# followup-notice-adds-no-plan-when-absent — --fix, "labels":[] (the older-harness shape, before
# #308 born every follow-up with no-plan already attached): comment call AND
# issue edit 50 --add-label no-plan. Mutation proof: (m).
case_followup_notice_adds_no_plan_when_absent() {
  local dir; dir="$(mk_repo followup-notice-adds-no-plan-when-absent)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_call "issue comment 50"
  expect_call "issue edit 50 --add-label no-plan"
  expect "FIXED #50 (Deferred later): follow-up from PR #12, closed without merge — commented, labelled no-plan"
}

# followup-notice-untrusted-marker-ignored — --fix, the orphan-notice marker is present but its
# comment's authorAssociation is NONE: the marker is ignored (not a suppression signal) and the
# notice is still posted, plus exactly one WARN naming the comment's association and url.
# Mutation proof: (m), (n), (p), (v).
case_followup_notice_untrusted_marker_ignored() {
  local dir; dir="$(mk_repo followup-notice-untrusted-marker-ignored)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[{"body":"Not mine to say.\n<!-- harness-orphan-notice: PR #12 -->\n","authorAssociation":"NONE","url":"https://example.invalid/50#issuecomment-9102"}]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_call "issue comment 50"
  expect "FIXED #50 (Deferred later): follow-up from PR #12, closed without merge — commented"
  expect_count "ignoring an orphan-notice marker from an untrusted comment author" 1
  expect "(NONE) at https://example.invalid/50#issuecomment-9102"
}

# followup-notice-untrusted-marker-no-fix — the untrusted-marker fixture, without --fix: the same
# single WARN still prints, STALE is still printed, expect_calls_empty.
# Mutation proof: (m), (n), (p), (v).
case_followup_notice_untrusted_marker_no_fix() {
  local dir; dir="$(mk_repo followup-notice-untrusted-marker-no-fix)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[{"body":"Not mine to say.\n<!-- harness-orphan-notice: PR #12 -->\n","authorAssociation":"NONE","url":"https://example.invalid/50#issuecomment-9102"}]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir"
  expect_rc 0
  expect "STALE #50 (Deferred later): filed as a follow-up from PR #12, which was closed without merging"
  expect_count "ignoring an orphan-notice marker from an untrusted comment author" 1
  expect "(NONE) at https://example.invalid/50#issuecomment-9102"
  expect_calls_empty
}

# followup-notice-missing-association-marker — --fix, the orphan-notice marker is on a comment
# with NO authorAssociation key at all: fail-closed untrusted (same rule as the multi-PR path),
# notice posted, one WARN naming the MISSING sentinel. Mutation proof: (m), (n), (p), (v).
case_followup_notice_missing_association_marker() {
  local dir; dir="$(mk_repo followup-notice-missing-association-marker)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[{"body":"Not mine to say.\n<!-- harness-orphan-notice: PR #12 -->\n","url":"https://example.invalid/50#issuecomment-9103"}]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_call "issue comment 50"
  expect "FIXED #50 (Deferred later): follow-up from PR #12, closed without merge — commented"
  expect_count "ignoring an orphan-notice marker from an untrusted comment author" 1
  expect "(MISSING) at https://example.invalid/50#issuecomment-9103"
}

# followup-notice-idempotent-lowercase-assoc (kickback K1, mirroring the multi-PR path's
# keep-marker-comment-lowercase-assoc) — --fix, the idempotent-second-run fixture with the seeded
# comment's authorAssociation spelled "owner" (lowercase, as GitHub never actually sends it, but
# pins the ascii_upcase normalisation no other #334 fixture distinguishes): still trusted, notice
# still suppressed, no untrusted-marker WARN. Mutation proof: (o), (v).
case_followup_notice_idempotent_lowercase_assoc() {
  local dir; dir="$(mk_repo followup-notice-idempotent-lowercase-assoc)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[{"body":"Already handled.\n<!-- harness-orphan-notice: PR #12 -->\n","authorAssociation":"owner","url":"https://example.invalid/50#issuecomment-9107"}]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_calls_empty
  expect_absent "FIXED #50"
  expect_absent "STALE #50"
  expect_absent "ignoring an orphan-notice marker from an untrusted comment author"
}

# followup-notice-view-failure-warns-and-keeps — --fix, the per-follow-up orphan-notice lookup
# itself fails (VIEW_MODE=fail): one WARN naming the fetch route phrase, expect_calls_empty, no
# FIXED/STALE line — the issue is left exactly as found for the next run to re-examine.
# Mutation proof: (m), (q).
case_followup_notice_view_failure_warns_and_keeps() {
  local dir; dir="$(mk_repo followup-notice-view-failure-warns-and-keeps)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir" ok ok fail
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_count "the orphan-notice lookup failed" 1
  expect "(gh issue view failed - rate limit, auth, or network?)"
  expect_calls_empty
  expect_absent "FIXED #50"
  expect_absent "STALE #50"
}

# followup-notice-view-failure-warns-no-fix — the same failed-lookup fixture, without --fix: the
# same single WARN still prints, no STALE line, expect_calls_empty.
# Mutation proof: (m), (q), (s).
case_followup_notice_view_failure_warns_no_fix() {
  local dir; dir="$(mk_repo followup-notice-view-failure-warns-no-fix)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir" ok ok fail
  run_cleanup "$dir"
  expect_rc 0
  expect_count "the orphan-notice lookup failed" 1
  expect "(gh issue view failed - rate limit, auth, or network?)"
  expect_absent "STALE #50"
  expect_calls_empty
}

# followup-notice-view-malformed-warns-and-keeps — the per-follow-up lookup SUCCEEDS but returns
# a non-JSON document (VIEW_MODE=malformed): same WARN discipline, distinguishing route phrase.
# Mutation proof: (m), (q), (r).
case_followup_notice_view_malformed_warns_and_keeps() {
  local dir; dir="$(mk_repo followup-notice-view-malformed-warns-and-keeps)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir" ok ok malformed
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_count "the orphan-notice lookup failed" 1
  expect "(the comments response was not valid JSON)"
  expect_calls_empty
  expect_absent "FIXED #50"
  expect_absent "STALE #50"
}

# followup-notice-view-malformed-warns-no-fix — the same malformed fixture, without --fix.
# Mutation proof: (m), (q), (r), (s).
case_followup_notice_view_malformed_warns_no_fix() {
  local dir; dir="$(mk_repo followup-notice-view-malformed-warns-no-fix)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir" ok ok malformed
  run_cleanup "$dir"
  expect_rc 0
  expect_count "the orphan-notice lookup failed" 1
  expect "(the comments response was not valid JSON)"
  expect_absent "STALE #50"
  expect_calls_empty
}

# followup-notice-marker-is-per-pr — --fix, a trusted orphan-notice marker naming PR #99 while
# the actual closed PR is #12: the notice IS posted (the marker is PR-keyed, the analogue of
# keep-wrong-issue-number for the multi-PR path). Mutation proof: (m) — none of the other #334
# mutants change this fixture's outcome, since its seeded comment never matches the real marker
# either way (see mutant (v)'s own note in the MEASURED MUTANTS block below).
case_followup_notice_marker_is_per_pr() {
  local dir; dir="$(mk_repo followup-notice-marker-is-per-pr)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[{"body":"From a different PR entirely.\n<!-- harness-orphan-notice: PR #99 -->\n","authorAssociation":"OWNER","url":"https://example.invalid/50#issuecomment-9104"}]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_call "issue comment 50"
  expect "FIXED #50 (Deferred later): follow-up from PR #12, closed without merge — commented"
}

# followup-notice-audit-marker-alone-does-not-suppress — --fix, a trusted comment carrying only
# <!-- harness-audit --> (no orphan-notice marker at all): the notice IS posted — pins that the
# idempotence key is the orphan marker, not the audit marker every harness comment opens with.
# Mutation proof: (m).
case_followup_notice_audit_marker_alone_does_not_suppress() {
  local dir; dir="$(mk_repo followup-notice-audit-marker-alone-does-not-suppress)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[{"body":"<!-- harness-audit -->\nSome unrelated harness comment, no orphan marker.\n","authorAssociation":"OWNER","url":"https://example.invalid/50#issuecomment-9105"}]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_call "issue comment 50"
  expect "FIXED #50 (Deferred later): follow-up from PR #12, closed without merge — commented"
}

# followup-notice-per-issue-state — --fix, two follow-ups from the SAME closed PR: #50 not yet
# noticed (comments-50.json empty) and #51 already noticed (comments-51.json seeded with a
# trusted orphan-notice marker) — exactly one issue comment call, naming #50 only. Pins per-issue
# state and the stub's new comments-<n>.json override; expect_count "issue comment" 1 against
# $calls is not available (expect_count reads $cleanup_out, not $calls — see that helper's own
# comment above), so this case uses expect_call + expect_no_call instead. Mutation proof: (m), (v).
case_followup_notice_per_issue_state() {
  local dir; dir="$(mk_repo followup-notice-per-issue-state)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Not yet noticed","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]},
 {"number":51,"title":"Already noticed","body":"Deferring this too.\n<!-- harness-follow-up: PR #12 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  cat > "$dir/comments-50.json" <<'EOF'
{"comments":[]}
EOF
  cat > "$dir/comments-51.json" <<'EOF'
{"comments":[{"body":"Already handled.\n<!-- harness-orphan-notice: PR #12 -->\n","authorAssociation":"OWNER","url":"https://example.invalid/51#issuecomment-9106"}]}
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_call "issue comment 50 --body"
  expect_no_call "issue comment 51"
  expect "FIXED #50 (Not yet noticed): follow-up from PR #12, closed without merge — commented"
  expect_absent "FIXED #51"
  expect_absent "STALE #51"
}

# ---------------------------------------------------------------------------------------------
# Part 6 cases (#355): a failed write (`gh issue comment`/`gh issue edit`/`gh issue close`) is
# best-effort, exactly like every pre-flight lookup already is — reported (one WARN naming the
# issue and which write failed), counted, and the remaining writes of that issue's own arm are
# skipped, but the run always continues to the next issue and reaches the closing Reminder. That
# per-write WARN line prints only for a FAILED write (never for a successful one) and prints
# exactly once per failed write. build_stub_gh's `reject-$2-once`/`reject-$2` marker files (see
# its own comment above) fail one write on demand; `$2` is literally `comment`/`edit`/`close`.

# write-failure-close-comment — close path (Closes #7, no sibling, no marker: the same shape as
# close-normal), `reject-comment` present, --fix: the comment write fails first, so nothing else
# in the close arm runs — no `issue close`, no `remove-label` — and no FIXED line. The one
# summary WARN line prints (exactly one write failed this run) and the closing Reminder still
# prints. The `expect_count` below pins the "exactly one" half of "the per-write WARN prints
# exactly once for a failed write" (the "only for a failed write, never a successful one" half is
# pinned by write-summary-absent-on-clean-run's own `expect_absent` instead — measured: (M16),
# which echoes try_write's WARN line in its own SUCCESS branch too, does not touch this fixture's
# single, failing try_write call, so this `expect_count` does not itself gain a citation from it).
# Mutation proof: (M1), (M7), (M11), (M15).
case_write_failure_close_comment() {
  local dir; dir="$(mk_repo write-failure-close-comment)"
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
  touch "$dir/reject-comment"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "WARN  #7 (Ordinary issue): posting the cleanup comment failed"
  expect_count "WARN  #7 (Ordinary issue): posting the cleanup comment failed" 1
  expect_call "issue comment 7"
  expect_no_call "issue close"
  expect_no_call "remove-label"
  expect_absent "FIXED #7"
  expect "WARN    1 repair write(s) failed this run"
  expect "Reminder:"
}

# write-failure-close-close — the same close-path shape, `reject-close`: the comment succeeds
# (logged), `issue close` is attempted (logged, then fails), and `remove-label` never runs — both
# the skip-the-rest contract AND the close→remove-label reorder are pinned by the SAME assertion:
# `expect_no_call "remove-label"` holds ONLY under the comment → close → remove-label order, which
# is why (M8) — reverting to the pre-#355 comment → remove-label → close order — kills this case
# too (remove-label now runs, and succeeds, before the still-failing close call). Mutation proof:
# (M3), (M7), (M8).
case_write_failure_close_close() {
  local dir; dir="$(mk_repo write-failure-close-close)"
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
  touch "$dir/reject-close"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_call "issue comment 7"
  expect_call "issue close 7"
  expect_no_call "remove-label"
  expect "WARN  #7 (Ordinary issue): closing the issue failed"
  expect_absent "FIXED #7"
}

# write-failure-close-edit — the same close-path shape, `reject-edit`: comment and close both
# succeed, `remove-label` is attempted (logged) and fails — the one bounded residue this plan
# documents (the issue ends up CLOSED but still carrying pr-open). No FIXED line (the arm never
# reaches its success branch). Mutation proof: (M2), (M8).
case_write_failure_close_edit() {
  local dir; dir="$(mk_repo write-failure-close-edit)"
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
  touch "$dir/reject-edit"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_call "issue comment 7"
  expect_call "issue close 7"
  expect_call "remove-label pr-open"
  expect "WARN  #7 (Ordinary issue): removing the pr-open label failed"
  expect_absent "FIXED #7"
}

# write-failure-keep-comment — the KEEP relabel arm (Part of #7, no sibling: the same shape as
# keep-part-of), `reject-comment`, --fix: the KEEP line still prints (it's unconditional, above
# the $FIX branch), the comment write fails, and `remove-label` never runs — no "pr-open removed"
# line. Mutation proof: (M4).
case_write_failure_keep_comment() {
  local dir; dir="$(mk_repo write-failure-keep-comment)"
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
  touch "$dir/reject-comment"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "KEEP  #7 (Multi-PR thing): PR #12 merged as part of a multi-PR issue"
  expect_no_call "remove-label"
  expect_absent "pr-open removed"
  expect "WARN  #7 (Multi-PR thing): posting the cleanup comment failed"
}

# write-failure-keep-edit — the same KEEP-arm shape, `reject-edit`: the comment succeeds
# (logged), `remove-label` is attempted (logged) and fails — no "pr-open removed" line.
# Mutation proof: (M5).
case_write_failure_keep_edit() {
  local dir; dir="$(mk_repo write-failure-keep-edit)"
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
  touch "$dir/reject-edit"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_call "issue comment 7"
  expect_call "remove-label pr-open"
  expect_absent "pr-open removed"
  expect "WARN  #7 (Multi-PR thing): removing the pr-open label failed"
}

# write-failure-requeue-comment — the requeue arm (a CLOSED, unmerged claude/7-* PR): comment
# fails, so `remove-label` never runs and no FIXED line prints. Mutation proof: (M6a).
case_write_failure_requeue_comment() {
  local dir; dir="$(mk_repo write-failure-requeue-comment)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/7-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Stale issue","body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  touch "$dir/reject-comment"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_call "issue comment 7"
  expect_no_call "remove-label"
  expect_absent "FIXED #7"
  expect "WARN  #7 (Stale issue): posting the cleanup comment failed"
}

# write-failure-requeue-edit — the same requeue-arm shape, `reject-edit`: comment succeeds
# (logged), `remove-label` is attempted (logged) and fails — no FIXED line.
# Mutation proof: (M6b).
case_write_failure_requeue_edit() {
  local dir; dir="$(mk_repo write-failure-requeue-edit)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/7-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"Stale issue","body":""}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  touch "$dir/reject-edit"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_call "issue comment 7"
  expect_call "remove-label pr-open"
  expect_absent "FIXED #7"
  expect "WARN  #7 (Stale issue): removing the pr-open label failed"
}

# write-failure-followup-comment — the follow-up arm, `"labels":[]` (the older-harness shape, the
# same as followup-notice-adds-no-plan-when-absent), `reject-comment`: `--add-label no-plan` is
# attempted FIRST (logged, succeeds — the #355 reorder), then the comment is attempted (logged)
# and fails — no FIXED line. Mutation proof: (M9b), (M10).
case_write_failure_followup_comment() {
  local dir; dir="$(mk_repo write-failure-followup-comment)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  touch "$dir/reject-comment"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_call "issue edit 50 --add-label no-plan"
  expect_call "issue comment 50"
  expect_absent "FIXED #50"
  expect "WARN  #50 (Deferred later): posting the orphan notice failed"
}

# write-failure-followup-label — the same follow-up shape, `"labels":[]`, `reject-edit`: the
# `--add-label no-plan` write is attempted (logged) and fails, so the comment never runs at all
# (`expect_no_call "issue comment 50"` pins both the skip-the-rest contract AND the #355 reorder —
# under the pre-#355 comment-then-label order this assertion would instead prove the comment ran
# and the label failed) — no FIXED line. Mutation proof: (M9a), (M10).
case_write_failure_followup_label() {
  local dir; dir="$(mk_repo write-failure-followup-label)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #12 -->\n","labels":[]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  touch "$dir/reject-edit"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_call "issue edit 50 --add-label no-plan"
  expect_no_call "issue comment 50"
  expect_absent "FIXED #50"
  expect "WARN  #50 (Deferred later): adding the no-plan label failed"
}

# write-failure-continues-to-next-issue — the headline claim: two pr-open issues on the close
# path (#7, #8) plus one CLOSED claude/50-* PR with a follow-up, `reject-comment-once` (a
# ONE-SHOT rejection, consumed by whichever `gh issue comment` call reaches the stub first — #7's,
# since issues.json lists it first and the pr-open section runs before the follow-up section):
# #7's comment fails and #7 gets no FIXED line, but #8 is fully repaired (FIXED #8, `issue close
# 8` logged), the run reaches "== follow-ups from rejected PRs ==", #50 is fully repaired too
# (FIXED #50 — the once-marker was already consumed by #7, so #50's own comment call succeeds),
# the closing Reminder prints, the summary line counts exactly 1 failed write, and rc is 0.
# Mutation proof: (M1), (M7), (M11), (M15).
case_write_failure_continues_to_next_issue() {
  local dir; dir="$(mk_repo write-failure-continues-to-next-issue)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"},
 {"number":13,"state":"MERGED","headRefName":"claude/8-x","body":"Closes #8"},
 {"number":14,"state":"CLOSED","headRefName":"claude/50-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[{"number":7,"title":"First issue","body":""},{"number":8,"title":"Second issue","body":""}]
EOF
  cat > "$dir/followups.json" <<'EOF'
[{"number":50,"title":"Deferred later","body":"Deferring this.\n<!-- harness-follow-up: PR #14 -->\n","labels":[{"name":"no-plan"}]}]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  build_stub_gh "$dir"
  touch "$dir/reject-comment-once"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "WARN  #7 (First issue): posting the cleanup comment failed"
  expect_absent "FIXED #7"
  expect "FIXED #8 (Second issue): PR #13 merged — commented, closed the issue, removed pr-open"
  expect_call "issue close 8"
  expect "== follow-ups from rejected PRs =="
  expect "FIXED #50 (Deferred later): follow-up from PR #14, closed without merge — commented (no-plan already present)"
  expect "Reminder:"
  expect "WARN    1 repair write(s) failed this run"
}

# write-failure-markers-inert-no-fix — write-failure-close-comment's tree, but with ALL THREE
# permanent reject markers present (reject-comment, reject-edit, reject-close) and run WITHOUT
# --fix: report-only mode never writes at all, so every marker is inert — expect_calls_empty, no
# write-failure WARN, and no summary line. Mutation proof: (M12), (M13).
case_write_failure_markers_inert_no_fix() {
  local dir; dir="$(mk_repo write-failure-markers-inert-no-fix)"
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
  touch "$dir/reject-comment" "$dir/reject-edit" "$dir/reject-close"
  run_cleanup "$dir"
  expect_rc 0
  expect_calls_empty
  expect_absent "repair write(s) failed"
  expect_absent "failed (gh exited non-zero"
}

# write-summary-absent-on-clean-run (control) — close-normal's shape, no reject markers, --fix: a
# clean run with no failed write never prints the summary line at all, while FIXED still prints.
# The `expect_absent "failed (gh exited non-zero"` below pins the "only for a FAILED write" half
# of the per-write WARN claim: every try_write call in this fixture succeeds, so that WARN text —
# which only try_write's own failure branch echoes — must never appear. Mutation proof: (M12),
# (M16).
case_write_summary_absent_on_clean_run() {
  local dir; dir="$(mk_repo write-summary-absent-on-clean-run)"
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
  expect_absent "repair write(s) failed"
  expect_absent "failed (gh exited non-zero"
  expect "FIXED #7 (Ordinary issue): PR #12 merged — commented, closed the issue, removed pr-open"
}

# write-failure-gh-stderr-not-swallowed — write-failure-close-comment's tree again: the stub's own
# diagnostic (printed on the STUB's stderr by its reject-$2(-once) branches — see build_stub_gh's
# own comment above) is not swallowed by try_write's `>/dev/null` (which redirects only stdout) —
# it lands in run_cleanup_at's MERGED `$cleanup_out` capture. Worded as "gh's own diagnostic is
# not swallowed", never "on stderr" (LESSON 2026-09-08(b) — this runner makes no split-stream
# capture; run_stub_gh's would, but this case deliberately goes through the real script instead).
# (M7) does NOT cite this case: its only assertions are `expect_rc 0` and the stub's own stderr
# diagnostic, neither of which the M7 mutation (dropping the close arm's skip-the-rest chain)
# touches. Mutation proof: (M1), (M14).
case_write_failure_gh_stderr_not_swallowed() {
  local dir; dir="$(mk_repo write-failure-gh-stderr-not-swallowed)"
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
  touch "$dir/reject-comment"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "stub: simulated gh issue comment failure"
}

# ---------------------------------------------------------------------------------------------
# Part 7 cases (#370): the closed-issue pr-open sweep, a second `gh issue list --label pr-open
# --state closed --json number,title --limit 100` query feeding a new "== closed issues still
# labelled pr-open ==" section, so a label #355 (or GitHub's own auto-close) leaves stranded on a
# CLOSED issue is swept on the next --fix run instead of sitting there forever (the open-issue
# hygiene query never revisits a closed issue). Every fixture writes prs.json, issues.json
# (usually `[]` — these fixtures deliberately keep the open-issue hygiene section a no-op so it
# can't interfere), comments.json (usually `{"comments":[]}`, unused unless noted) and
# closed-pr-open.json. Mutation proofs cite the `MEASURED MUTANTS, #370` block below. Since #370
# kickback round 3, the stub's closed arm also appends its own full argv to a separate
# DIR/gh-list-calls.log (read into $list_calls by run_cleanup_at, asserted via the new
# expect_list_call helper) — the pre-existing, mutation-only gh-calls.log/$calls/expect_call
# pair is untouched, so every expect_calls_empty above keeps its pre-#370 meaning — making the
# closed query's own literal argument list, including ` --limit 100`, observable to a fixture for
# the first time.

# closed-sweep-removes-label — closed #7, no claude/7-* PR open at all (PR #12 is MERGED): --fix
# removes the label through try_write alone, no comment, no close, and the logged closed-query
# call line contains the full literal `--label pr-open --state closed --json number,title --limit
# 100` (#370 kickback round 3, via expect_list_call). Since #370 kickback round 4, this fixture
# ALSO asserts the section header itself, `expect "== closed issues still labelled pr-open =="`
# (a verifier finding: deleting that one `echo` line from bin/cleanup-after-merge.sh survived every
# prior round of this suite, since no fixture had ever asserted on the header text — only on lines
# printed inside the section), plus its POSITION relative to its two neighbours via the new
# `expect_section_order "== pr-open label hygiene ==" "== closed issues still labelled pr-open =="
# "== follow-ups from rejected PRs =="` — this fixture already prints all three headers
# unconditionally (each is a bare `echo` reached regardless of that section's own data), so no new
# fixture is needed. This is also the fixture the round-4 literal sweep's own table (see the
# "Kickback round 4" paragraph below) cites for the sweep's full query line, the header and its
# position, the exact `gh issue edit <n> --remove-label pr-open` write, and (jointly with other
# fixtures) the "no comment, no close" and `first // empty` literals. Mutation proof (MEASURED,
# 2026-09-23, against
# the final 71-case registry, #370 kickback round 4): (C5), (C17), (C18), (C19), (C20), (C21), and
# (C22) are the only seven of the twenty-two mutants whose failing set includes this fixture;
# C1/C2/C11 need a --fix-mode/
# report-only split or a failed write, C9 needs an empty (or non-matching) claude/<n>-* PR set,
# and C16 needs an OPEN PR for a DIFFERENT issue — none of which this fixture has (its one PR,
# claude/7-x, is MERGED and matches issue #7's own prefix).
case_closed_sweep_removes_label() {
  local dir; dir="$(mk_repo closed-sweep-removes-label)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  cat > "$dir/closed-pr-open.json" <<'EOF'
[{"number":7,"title":"Ordinary issue"}]
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "FIXED #7 (Ordinary issue): closed issue"
  expect_call "issue edit 7 --remove-label pr-open"
  expect_no_call "issue comment"
  expect_no_call "issue close"
  expect_list_call "--label pr-open --state closed --json number,title --limit 100"
  expect "== closed issues still labelled pr-open =="
  expect_section_order "== pr-open label hygiene ==" "== closed issues still labelled pr-open ==" "== follow-ups from rejected PRs =="
}

# closed-sweep-report-only — the same tree without --fix: a STALE line, zero gh mutation calls.
# Mutation proof (MEASURED, 2026-09-23): (C1), (C5); ALSO (C22) (#370 kickback round 4 — see that
# mutant's own entry), since this fixture's closed issue has no matching open PR at all, the
# identical shape (C22)'s `first // empty` deletion always trips.
case_closed_sweep_report_only() {
  local dir; dir="$(mk_repo closed-sweep-report-only)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":12,"state":"MERGED","headRefName":"claude/7-x","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  cat > "$dir/closed-pr-open.json" <<'EOF'
[{"number":7,"title":"Ordinary issue"}]
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir"
  expect_rc 0
  expect "STALE #7 (Ordinary issue): closed but still labelled pr-open"
  expect_calls_empty
}

# closed-sweep-keeps-while-pr-open — PR #11 (claude/7-a) is OPEN, a higher-numbered PR #12
# (claude/7-b) is MERGED: the label is kept (an `ok` line naming the still-open PR), no write at
# all, even under --fix. Mutation proof (MEASURED, 2026-09-23): (C3), (C4), (C5).
case_closed_sweep_keeps_while_pr_open() {
  local dir; dir="$(mk_repo closed-sweep-keeps-while-pr-open)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":11,"state":"OPEN","headRefName":"claude/7-a","body":""},
 {"number":12,"state":"MERGED","headRefName":"claude/7-b","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  cat > "$dir/closed-pr-open.json" <<'EOF'
[{"number":7,"title":"Ordinary issue"}]
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "ok    #7 (Ordinary issue): closed, but PR #11 (claude/7-*) is still open — pr-open kept"
  expect_calls_empty
  expect_absent "FIXED #7"
}

# closed-sweep-keeps-while-pr-open-no-fix — the same tree, report-only: the `ok` line still
# prints (it sits outside the $FIX branch), and no STALE line for #7. Mutation proof (MEASURED,
# 2026-09-23): (C3), (C4), (C5), (C10).
case_closed_sweep_keeps_while_pr_open_no_fix() {
  local dir; dir="$(mk_repo closed-sweep-keeps-while-pr-open-no-fix)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":11,"state":"OPEN","headRefName":"claude/7-a","body":""},
 {"number":12,"state":"MERGED","headRefName":"claude/7-b","body":"Closes #7"}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  cat > "$dir/closed-pr-open.json" <<'EOF'
[{"number":7,"title":"Ordinary issue"}]
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir"
  expect_rc 0
  expect "ok    #7 (Ordinary issue): closed, but PR #11 (claude/7-*) is still open — pr-open kept"
  expect_absent "STALE #7"
  expect_calls_empty
}

# closed-sweep-no-pr-still-removes — no claude/7-* PR exists at all (prs.json is `[]`): the
# closed issue is still swept under --fix — the sweep never `continue`s just because a matching
# PR is missing. Mutation proof (MEASURED, 2026-09-23): (C5), (C9); ALSO (C21) and (C22) (#370
# kickback round 4), since this fixture also asserts the exact `--remove-label pr-open` write and
# has no matching open PR at all — see those mutants' own entries.
case_closed_sweep_no_pr_still_removes() {
  local dir; dir="$(mk_repo closed-sweep-no-pr-still-removes)"
  cat > "$dir/prs.json" <<'EOF'
[]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  cat > "$dir/closed-pr-open.json" <<'EOF'
[{"number":7,"title":"Ordinary issue"}]
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "FIXED #7 (Ordinary issue): closed issue"
  expect_call "issue edit 7 --remove-label pr-open"
}

# closed-sweep-write-failure-continues — two closed issues, #7 and #9, with reject-edit-once: #7's
# remove-label write fails (the standard try_write WARN, no FIXED for #7), but the loop continues
# to #9, which is fully repaired; the run still reaches the follow-ups section and the Reminder,
# with the one-failure summary line and rc 0. Mutation proof (MEASURED, 2026-09-23): (C2), (C5),
# (C9), (C11); ALSO (C22) (#370 kickback round 4 — see that mutant's own entry), since #9 has no
# matching open PR either.
case_closed_sweep_write_failure_continues() {
  local dir; dir="$(mk_repo closed-sweep-write-failure-continues)"
  cat > "$dir/prs.json" <<'EOF'
[]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  cat > "$dir/closed-pr-open.json" <<'EOF'
[{"number":7,"title":"Issue A"},{"number":9,"title":"Issue B"}]
EOF
  build_stub_gh "$dir"
  touch "$dir/reject-edit-once"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "WARN  #7 (Issue A): removing the pr-open label failed"
  expect_absent "FIXED #7"
  expect "FIXED #9 (Issue B): closed issue"
  expect "== follow-ups from rejected PRs =="
  expect "Reminder:"
  expect "WARN    1 repair write(s) failed this run"
}

# closed-sweep-query-failure-continues — reject-closed-list: exactly one WARN naming the failed
# closed-issue fetch, zero gh mutation calls, and the run still reaches the follow-ups section and
# the Reminder with rc 0. Mutation proof (MEASURED, 2026-09-23): (C5), (C8).
case_closed_sweep_query_failure_continues() {
  local dir; dir="$(mk_repo closed-sweep-query-failure-continues)"
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
  touch "$dir/reject-closed-list"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_count "could not fetch closed issues labelled pr-open" 1
  expect_calls_empty
  expect "== follow-ups from rejected PRs =="
  expect "Reminder:"
}

# closed-sweep-query-malformed-continues — malformed-closed-list: gh itself EXITS 0 but the body is
# not JSON (a response that failed to parse, distinct from the hard-failure route
# closed-sweep-query-failure-continues pins), the identical malformed-vs-failed distinction #249's
# view-malformed-warns-and-keeps draws for the multi-PR comment lookup, applied here to the #370
# closed-issue query's own `jq -e .` validity check. Same observable outcome as the hard-failure
# fixture — exactly one WARN naming the failed fetch, zero gh mutation calls, the run still reaches
# the follow-ups section and the Reminder with rc 0 — but reached through the guard's SECOND `||`
# clause rather than its first. Mutation proof (MEASURED, 2026-09-23): (C8), (C15) — (C15) is the
# one mutant this fixture alone catches: deleting the `jq -e .` clause entirely lets gh's non-JSON
# body reach `jq 'length'` unguarded.
case_closed_sweep_query_malformed_continues() {
  local dir; dir="$(mk_repo closed-sweep-query-malformed-continues)"
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
  touch "$dir/malformed-closed-list"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect_count "could not fetch closed issues labelled pr-open" 1
  expect_calls_empty
  expect "== follow-ups from rejected PRs =="
  expect "Reminder:"
}

# closed-sweep-independent-of-open-list — reject-open-list: the OPEN hygiene query fails (its own
# WARN prints), but the closed-issue sweep is unaffected and still repairs #7. Mutation proof
# (MEASURED, 2026-09-23): (C5), (C6), (C9), (C12); ALSO (C22) (#370 kickback round 4 — see that
# mutant's own entry), since #7 has no matching open PR here either.
case_closed_sweep_independent_of_open_list() {
  local dir; dir="$(mk_repo closed-sweep-independent-of-open-list)"
  cat > "$dir/prs.json" <<'EOF'
[]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  cat > "$dir/closed-pr-open.json" <<'EOF'
[{"number":7,"title":"Ordinary issue"}]
EOF
  build_stub_gh "$dir"
  touch "$dir/reject-open-list"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "could not fetch issues labelled pr-open"
  expect "FIXED #7 (Ordinary issue): closed issue"
}

# closed-sweep-skipped-when-pr-list-fails — the PR list itself is unavailable (PR_MODE=fail): the
# sweep prints its own skip WARN and makes zero writes, even with --fix and a non-empty closed
# list. Mutation proof (MEASURED, 2026-09-23): (C7). C5 does NOT catch this fixture — PR_MODE=fail
# means $prs_ok is false, so the sweep's own `if ! $prs_ok` gate short-circuits before either
# `--state` literal is ever sent to the stub, regardless of which one the script names.
case_closed_sweep_skipped_when_pr_list_fails() {
  local dir; dir="$(mk_repo closed-sweep-skipped-when-pr-list-fails)"
  cat > "$dir/prs.json" <<'EOF'
[]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  cat > "$dir/closed-pr-open.json" <<'EOF'
[{"number":7,"title":"Ordinary issue"}]
EOF
  build_stub_gh "$dir" ok fail
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "WARN    closed-issue pr-open sweep skipped (PR list unavailable — see WARN above)"
  expect_calls_empty
}

# closed-sweep-other-issue-pr-open-still-removes (#370 kickback round 2) — closed #7 has no
# claude/7-* PR at all, but TWO OPEN PRs for OTHER issues exist: claude/70-x (issue #70) and
# claude/8-x (issue #8). The RESOLVED decision and the acceptance criterion both say to keep the
# label only while a claude/<n>-* PR FOR THAT ISSUE is open — a PR for a different issue must
# never keep it. Pins the `<n>` scoping in the sweep's own `--arg p "claude/${n}-"` prefix match
# (bin/cleanup-after-merge.sh:436): claude/70-x alone would also catch a narrower, dropped-hyphen
# mutant (`--arg p "claude/${n}"`, no trailing `-`) — "claude/70-x" starts with "claude/7" even
# though it does NOT start with "claude/7-" — while claude/8-x alone catches the wider mutant this
# round's finding names, `--arg p "claude/"` (matches any claude/* PR, any issue). Mutation proof
# (MEASURED, 2026-09-23, #370 kickback round 2, against the final 71-case registry): (C5), (C9),
# (C16) — this fixture is caught by all three, each for a distinct reason: (C5), the `--state
# closed` -> `--state open` cascade, because this fixture's own `issues.json` is `[]` like every
# other #370 fixture in that failing set; (C9), the `continue`-past-no-matching-PR mutant, because
# NEITHER claude/70-x nor claude/8-x matches the `claude/7-*` prefix at all, the identical
# no-matching-PR condition (C9) already catches via an empty `prs.json`, reached here a different
# way; and (C16) — the `--arg p "claude/${n}-"` -> `--arg p "claude/"` mutant this round's finding
# names — which this fixture alone catches (no other case has an OPEN PR for a different issue
# number). The narrower dropped-hyphen variant of (C16) (`--arg p "claude/${n}"`) was also measured
# directly (self-mutation check, applied to the tracked working copy and restored): identical
# failing set, this fixture alone, for the identical reason (claude/70-x now matches too) — not
# entered as a separate letter since it produces no new information over (C16). ALSO (C21) and
# (C22) (#370 kickback round 4 — see those mutants' own entries): this fixture asserts the exact
# `--remove-label pr-open` write ((C21)), and neither of its two PRs matches the `claude/7-*`
# prefix, so `open_pr` is empty pre-mutation and becomes the literal string "null" under (C22)'s
# `first // empty` deletion, the identical no-matching-PR shape (C22)'s other members share.
case_closed_sweep_other_issue_pr_open_still_removes() {
  local dir; dir="$(mk_repo closed-sweep-other-issue-pr-open-still-removes)"
  cat > "$dir/prs.json" <<'EOF'
[{"number":20,"state":"OPEN","headRefName":"claude/70-x","body":""},
 {"number":21,"state":"OPEN","headRefName":"claude/8-x","body":""}]
EOF
  cat > "$dir/issues.json" <<'EOF'
[]
EOF
  cat > "$dir/comments.json" <<'EOF'
{"comments":[]}
EOF
  cat > "$dir/closed-pr-open.json" <<'EOF'
[{"number":7,"title":"Ordinary issue"}]
EOF
  build_stub_gh "$dir"
  run_cleanup "$dir" --fix
  expect_rc 0
  expect "FIXED #7 (Ordinary issue): closed issue"
  expect_call "issue edit 7 --remove-label pr-open"
  expect_absent "ok    #7"
}

# closed-sweep-none — no closed-pr-open.json at all (the stub's own absent-file default): prints
# the empty-list line, control for the eleven closed-sweep-* cases above (kickback round 1 placed
# the eleventh, closed-sweep-query-malformed-continues, above this one; kickback round 2 places
# the twelfth, closed-sweep-other-issue-pr-open-still-removes, above this one too — making eleven,
# not the nine a pre-kickback count would give). Mutation proof (MEASURED, 2026-09-23): (C14) —
# the only mutant whose failing set names this case; see (C14)'s own entry in the `MEASURED
# MUTANTS, #370` block for the self-mutation check.
case_closed_sweep_none() {
  local dir; dir="$(mk_repo closed-sweep-none)"
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
  expect "no closed issues labelled pr-open"
}

# MEASURED MUTANTS — the twelve entries (a)-(l) were first authored 2026-09-09; RE-MEASURED
# 2026-09-21 (including kickback K1's sixteenth fixture) against this file's then-final 46-case
# registry, RE-MEASURED AGAIN 2026-09-23 (#355) against this file's then-final 59-case
# registry, RE-MEASURED A THIRD TIME 2026-09-23 (#370) against this file's then-final 69-case
# registry, RE-MEASURED A FOURTH TIME 2026-09-23 (#370 kickback round 1) against this file's
# then-final 70-case registry, and RE-MEASURED A FIFTH TIME 2026-09-23 (#370 kickback round 2)
# against this file's now-final 71-case registry — see the #334 block below for the ten mutants
# that block added, and the #355 block further below for its own seventeen new mutants (M1-M15,
# two of them split a/b). Every
# measurement through the 59-case round was taken by extracting a fresh copy of the pristine tree
# from one `tar --exclude=.git` archive per mutation, applying exactly one
# mutation to that scratch copy, running `bash dev/cleanup-tests.sh` there and saving its full
# output to a file, then discarding the scratch copy before the next mutation; the #370 round
# instead edited the TRACKED working copy of the mutated file in place, ran the suite, then
# restored the pristine text and diffed to confirm a clean restore before the next mutation (see
# the `MEASURED MUTANTS, #370` block's own header for why) — both leave the tracked tree
# byte-identical once measurement is done, and neither ever mutates bin/cleanup-after-merge.sh or
# this file permanently:
#   (a) delete `validate_json_fields "$GH_ISSUE_JSON_FIELDS" "$@"` from the `issue) list)` arm
#       only: 67 pass, 3 fail, failing EXACTLY stub-json-unknown-field-rejected-issue-list,
#       stub-json-field-sets-are-subcommand-scoped, stub-json-missing-json-argument-fails-loud —
#       unchanged by #370 (RE-MEASURED 2026-09-23): the ten new closed-sweep fixtures never probe
#       the stub's own field-list validation, so the failing set is identical, +10 pass. Actually
#       re-run again (#370 kickback round 2, 2026-09-23, against the 71-case registry, per LESSON
#       2026-09-07 — one of three pre-#370 spot checks this round, see the growth-chain note's
#       kickback-round-2 paragraph): 68 pass, 3 fail, identical failing set, +1 pass — the twelfth
#       #370 fixture doesn't probe the stub's field-list validation either.
#   (b) delete the same call from the `issue) view)` arm only: 67 pass, 3 fail, failing EXACTLY
#       stub-json-unknown-field-rejected-issue-view, stub-json-field-sets-are-subcommand-scoped,
#       script-unknown-json-field-warns-and-keeps — unchanged by #370 (RE-MEASURED 2026-09-23),
#       +10 pass, identical failing set. Restated (#370 kickback round 2, mechanism-only): +1 pass,
#       identical failing set.
#   (c) delete `validate_json_fields "$GH_PR_JSON_FIELDS" "$@"` from the `pr) list)` arm only:
#       69 pass, 1 fail, failing EXACTLY stub-json-unknown-field-rejected-pr-list — unchanged by
#       #370 (RE-MEASURED 2026-09-23), +10 pass. Restated (#370 kickback round 2, mechanism-only):
#       +1 pass, identical failing set.
#   (d) swap GH_PR_JSON_FIELDS -> GH_ISSUE_JSON_FIELDS on the `pr) list)` arm: 13 pass, 57 fail —
#       a wide cascade (bin/cleanup-after-merge.sh's own `pr list --json
#       number,state,headRefName,body` call is rejected, so almost every fixture that depends on
#       the PR list loses it — the saved run shows `WARN    could not fetch the PR list (gh pr
#       list failed — rate limit, auth, or network?) — skipping pr-open label hygiene and the
#       follow-ups check below.` on the great majority of the failing cases); the remaining two,
#       stub-json-field-sets-are-subcommand-scoped and stub-json-script-field-lists-accepted, call
#       the stub's `pr list` arm directly and never run the script at all — the saved run shows
#       each failing on the stub's own rejection instead: `rc: expected 0, got 1` plus
#       `missing: "headRefName":"claude/1-x"` for the former, `rc: expected 0, got 1` plus
#       `missing: "headRefName":"claude/7-x"` for the latter —
#       re-run confirmed rather than assumed (LESSON 2026-09-07), passing set: pull-ok,
#       current-branch-failure-continues, pr-list-failure-continues, empty-needle-guard,
#       stub-json-unknown-field-rejected-issue-list, stub-json-unknown-field-rejected-issue-view,
#       stub-json-unknown-field-rejected-pr-list, stub-json-missing-json-argument-fails-loud,
#       followup-notice-idempotent-second-run, followup-notice-idempotent-report-only,
#       followup-notice-idempotent-lowercase-assoc (kickback K1's addition) — the three
#       #334 idempotent fixtures assert only ABSENCE of output/calls, which an empty candidate
#       list — the pr-open section's own gh pr list call is rejected before the follow-ups
#       section is ever reached — also produces, so they survive this cascade too (eleven
#       members), plus write-failure-markers-inert-no-fix (#355, the identical survival reason:
#       a report-only run whose assertions are also all satisfied by "the PR list fetch failed
#       before any write was ever attempted") as a twelfth. RE-MEASURED 2026-09-23 (#370) against
#       this file's grown 69-case registry: the passing set gains a THIRTEENTH survivor,
#       closed-sweep-skipped-when-pr-list-fails — its own fixture ALREADY builds a failed PR list
#       (`build_stub_gh "$dir" ok fail`) and asserts the sweep's own skip WARN plus
#       `expect_calls_empty`, both of which this mutant's rejection (a different underlying cause,
#       same `gh pr list` exit-1 outcome) also satisfies; the failing set gains the other NINE
#       #370 closed-sweep-* fixtures (every one of them except closed-sweep-skipped-when-pr-list-
#       fails), each failing for the identical "PR list unavailable" reason as the pre-existing
#       47 — the closed-issue sweep's own `if ! $prs_ok` gate fires identically to the open-issue
#       hygiene section's. RE-MEASURED A SECOND TIME (#370 kickback round 2, 2026-09-23, against
#       the 71-case registry): 13 pass, 58 fail — the twelfth fixture, closed-sweep-other-issue-
#       pr-open-still-removes, JOINS the failing set (pass count unchanged at 13): its own `gh pr
#       list` call is rejected identically to the other eleven closed-sweep-* fixtures, so it never
#       sees its own FIXED line either.
#   (e) swap GH_ISSUE_JSON_FIELDS -> GH_PR_JSON_FIELDS on BOTH issue arms: 69 pass, 1 fail,
#       failing EXACTLY stub-json-field-sets-are-subcommand-scoped (GH_PR_JSON_FIELDS is a
#       superset of every OTHER field any fixture's issue calls request, so only the
#       subcommand-scoping case, which specifically expects headRefName to be REJECTED on
#       issue list/view, notices) — unchanged by #370 (RE-MEASURED 2026-09-23), +10 pass. Restated
#       (#370 kickback round 2, mechanism-only): +1 pass, identical failing set.
#   (f) collapse the membership `case " $allowed " in *" $tok "*) : ;; ...` to an unconditional
#       accept (`*) : ;;` as the first arm): 65 pass, 5 fail, failing EXACTLY
#       stub-json-unknown-field-rejected-issue-list, stub-json-unknown-field-rejected-issue-view,
#       stub-json-unknown-field-rejected-pr-list, stub-json-field-sets-are-subcommand-scoped,
#       script-unknown-json-field-warns-and-keeps (stub-json-missing-json-argument-fails-loud is
#       untouched — that contract is checked before the membership loop runs at all) — unchanged
#       by #370 (RE-MEASURED 2026-09-23), +10 pass, identical failing set. Restated (#370 kickback
#       round 2, mechanism-only): +1 pass, identical failing set.
#   (g) delete `labels` from GH_ISSUE_JSON_FIELDS: 24 pass, 46 fail — the control's mutant, a wide
#       cascade (bin/cleanup-after-merge.sh's OWN `issue list --json number,title,labels` call is
#       now rejected — the saved run shows `WARN    could not fetch issues labelled pr-open (gh
#       issue list failed — rate limit, auth, or network?) — skipping pr-open label hygiene.` on
#       most of the failing cases, a DIFFERENT WARN than mutant (d)'s); the remaining one,
#       stub-json-script-field-lists-accepted, calls the stub directly and never runs the script —
#       the saved run shows it failing on the stub's own rejection instead: `rc: expected 0, got
#       1` plus `missing: "title":"T"` for its own `issue list --label pr-open` probe, then
#       `rc: expected 0, got 1` plus `expected [] from the follow-up candidates query, got: ` for
#       its `issue list --search` probe. stub-json-field-sets-are-subcommand-scoped PASSES under
#       this mutant: (g) removes `labels` from GH_ISSUE_JSON_FIELDS only, leaving the `pr list`
#       arm's GH_PR_JSON_FIELDS — the set that case probes — untouched; that case never runs the
#       script either. So almost every issue-list-dependent fixture fails, passing set: pull-ok,
#       current-branch-failure-continues, pr-list-failure-continues, empty-needle-guard,
#       stub-json-unknown-field-rejected-issue-list, stub-json-unknown-field-rejected-issue-view,
#       stub-json-unknown-field-rejected-pr-list, stub-json-field-sets-are-subcommand-scoped,
#       stub-json-missing-json-argument-fails-loud, followup-notice-idempotent-second-run,
#       followup-notice-idempotent-report-only, followup-notice-idempotent-lowercase-assoc
#       (kickback K1's addition; the same survival reason as mutant (d) above — all three
#       idempotent #334 fixtures assert only absence, which this cascade also produces), plus
#       write-failure-markers-inert-no-fix (#355, the identical reason as mutant (d)'s twelfth
#       member) as a thirteenth. RE-MEASURED 2026-09-23 (#370) against this file's grown 69-case
#       registry: the passing set gains ALL TEN #370 closed-sweep-* fixtures as its fourteenth
#       through twenty-third members — the identical mechanism (g)'s own doc-comment above already
#       documents for the open-issue hygiene section: the closed-issue sweep is by design
#       independent of `$issues_ok` (mutant (C6) in the `MEASURED MUTANTS, #370` block below proves
#       this the other direction), so rejecting the OPEN query's `labels` field never reaches the
#       CLOSED query at all (`--json number,title`, no `labels` requested); the failing set is
#       UNCHANGED at the same 46 pre-#370 members. RE-MEASURED A SECOND TIME (#370 kickback round
#       2, 2026-09-23, against the 71-case registry): 25 pass, 46 fail — the twelfth fixture,
#       closed-sweep-other-issue-pr-open-still-removes, JOINS the passing set as its 25th passing
#       member overall (the 12th closed-sweep-* member specifically; fail count unchanged at 46):
#       its own closed-issue query requests no `labels` field either, so this mutant never touches
#       it.
#   (h) `if [ "$found" -ne 1 ]` -> `if false`: 69 pass, 1 fail, failing EXACTLY
#       stub-json-missing-json-argument-fails-loud — unchanged by #370 (RE-MEASURED 2026-09-23),
#       +10 pass. Restated (#370 kickback round 2, mechanism-only): +1 pass, identical failing set.
#   (i) restore bin/cleanup-after-merge.sh's `issue_comments_doc="$(gh issue view "$n" --json
#       comments 2>/dev/null || echo '{"comments":[]}')"` swallow for the FETCH-FAILURE route
#       only (keeping the malformed-document check): 67 pass, 3 fail, failing EXACTLY
#       script-unknown-json-field-warns-and-keeps, view-failure-warns-and-keeps,
#       view-failure-warns-no-fix — unchanged by #370 (RE-MEASURED 2026-09-23), +10 pass. Restated
#       (#370 kickback round 2, mechanism-only): +1 pass, identical failing set.
#   (j) drop the malformed-document `elif` branch in bin/cleanup-after-merge.sh (folding it back
#       so only a hard fetch failure sets comments_ok=false): 68 pass, 2 fail, failing EXACTLY
#       view-malformed-warns-and-keeps, view-malformed-warns-no-fix — unchanged by #370
#       (RE-MEASURED 2026-09-23), +10 pass. Restated (#370 kickback round 2, mechanism-only): +1
#       pass, identical failing set.
#   (k) wrap the new `elif ! $comments_ok; then ... fi` decision branch in `if $FIX; then ... fi`
#       in bin/cleanup-after-merge.sh: 68 pass, 2 fail, failing EXACTLY view-failure-warns-no-fix,
#       view-malformed-warns-no-fix (LESSON 2026-09-08 — the --fix-only fixtures in this set
#       cannot see this mutant; only the report-only pair does) — unchanged by #370 (RE-MEASURED
#       2026-09-23), +10 pass. Restated (#370 kickback round 2, mechanism-only): +1 pass, identical
#       failing set.
#   (l) delete the `elif [[ "$has_multi_pr_label" == "true" ]]; then keep_reason=...` arm from
#       bin/cleanup-after-merge.sh's KEEP chain: 68 pass, 2 fail, failing EXACTLY
#       keep-multi-pr-label, keep-multi-pr-label-view-failure-short-circuits — unchanged by #370
#       (RE-MEASURED 2026-09-23), +10 pass. Actually re-run again (#370 kickback round 2,
#       2026-09-23, against the 71-case registry, per LESSON 2026-09-07 — one of three pre-#370
#       spot checks this round): 69 pass, 2 fail, identical failing set, +1 pass — the twelfth
#       fixture's own `issues.json` is `[]`, never reaching the multi-PR KEEP chain either.
#
# (a)-(l) RE-MEASURED 2026-09-23 (#355) against this file's then-final 59-case registry, and
# RE-MEASURED AGAIN 2026-09-23 (#370) against this file's then-final 69-case registry, by the
# workflows each round's own header above describes. Of
# the twelve, only (d) and (g) — both wide cascades reached through the `gh pr list`/`gh issue
# list --label pr-open` fetches every #370 closed-sweep-* fixture also depends on — picked up new
# members in the #370 round, exactly as LESSON 2026-09-15 predicts for a cascade mutant; the other
# ten shifted by a flat +10 pass with an unchanged failing set, confirmed by re-running every one
# of the twelve rather than assumed, per LESSON 2026-09-07. RE-MEASURED A THIRD TIME (#370
# kickback round 1, 2026-09-23) against this file's then-final 70-case registry: (d) was re-run (13
# pass, 57 fail — the eleventh #370 fixture's own `gh pr list` call is rejected identically to the
# other ten, joining the failing set) and (g) was re-run (24 pass, 46 fail — the eleventh #370
# fixture's own closed-issue query requests no `labels` field, so it joins the OTHER TEN
# closed-sweep-* fixtures already in the passing set as an eleventh survivor); the other ten
# ((a),(b),(c),(e),(f),(h),(i),(j),(k),(l)) are restated as a flat +1 pass with an unchanged failing
# set per the growth-chain note's kickback-round paragraph below (mechanism-only, not independently
# re-run — each touches only the `validate_json_fields`/multi-PR KEEP code the eleventh fixture's
# own empty `issues.json` never reaches). RE-MEASURED A FIFTH TIME (#370 kickback round 2,
# 2026-09-23) against this file's now-final 71-case registry: (d) was re-run again (13 pass, 58
# fail — the twelfth #370 fixture's own `gh pr list` call is rejected identically to the other
# eleven, joining the failing set) and (g) was re-run again (25 pass, 46 fail — the twelfth
# fixture's own closed-issue query requests no `labels` field either, so it joins the OTHER ELEVEN
# closed-sweep-* fixtures already in the passing set as a twelfth survivor); (a) and (l) were ALSO
# actually re-run this round as spot checks (see each entry above and the growth-chain note's
# kickback-round-2 paragraph), both shifting by a flat +1 pass with an unchanged failing set; the
# remaining eight ((b),(c),(e),(f),(h),(i),(j),(k)) are restated as a flat +1 pass with an unchanged
# failing set on the identical mechanism, without an individual re-run. Every entry's totals above
# are now current against the 71-case registry.
#
# MEASURED MUTANTS, #334 (2026-09-21, extended by kickback K1 — see mutant (o); RE-MEASURED
# 2026-09-23 against this file's then-final 59-case registry — see mutant (m) and mutant (t)
# below for the two entries whose failing set picked up a #355 fixture — and RE-MEASURED AGAIN
# 2026-09-23 (#370) against this file's then-final 69-case registry, by the in-place workflow the
# (a)-(l) block's own header describes above, on bin/cleanup-after-merge.sh's follow-up
# orphan-notice code (the "== follow-ups from rejected PRs ==" section) unless noted. None of the
# ten #370 closed-sweep-* fixtures exercises this code at all — every one of their `prs.json`
# fixtures is either `[]` or carries only MERGED/OPEN `claude/*` PRs, never a CLOSED-unmerged one,
# so `bin/cleanup-after-merge.sh`'s own `closed_prs` computation is empty and the follow-up loop
# body is never entered — confirmed by re-running every one of the eleven entries below (never
# assumed, per LESSON 2026-09-07): every entry shifts by a flat +10 pass with its failing set
# byte-identical to the 59-case measurement. RE-MEASURED AGAIN (#370 kickback, 2026-09-23)
# against this file's then-final 70-case registry: the eleventh #370 fixture,
# closed-sweep-query-malformed-continues, has the identical empty-`prs.json`/no-CLOSED-`claude/*`
# shape, so every entry (m)-(v) below is restated as a flat +1 pass with its failing set
# unchanged, per the growth-chain note's kickback-round paragraph (mechanism-only, not
# independently re-run). RE-MEASURED A THIRD TIME (#370 kickback round 2, 2026-09-23) against this
# file's now-final 71-case registry: the twelfth #370 fixture, closed-sweep-other-issue-pr-open-
# still-removes, has the identical shape (its own `prs.json` carries two PRs, both `state: "OPEN"`,
# never CLOSED), so every entry (m)-(v) below is restated a second time as a further flat +1 pass
# with its failing set unchanged, per the growth-chain note's kickback-round-2 paragraph
# (mechanism-only, not independently re-run):
#   (m) revert the candidate search predicate to its pre-#334 form (re-insert `-label:no-plan `
#       before `-label:pr-open` in the `gh issue list --search` string): 54 pass, 16 fail, failing
#       EXACTLY every #334 fixture EXCEPT followup-notice-idempotent-second-run,
#       followup-notice-idempotent-report-only, and followup-notice-idempotent-lowercase-assoc
#       (kickback K1's fixture) — build_stub_gh's `--search` arm (dev/cleanup-
#       tests.sh) matches the exact substring `is:open is:issue -label:pr-open`, which the
#       reverted string no longer contains contiguously, so the stub falls through to its
#       catch-all `[]`; the saved run shows the "== follow-ups from rejected PRs ==" section
#       printing nothing at all (no FIXED/STALE/WARN line) for every #334 fixture, and the three
#       idempotent fixtures survive because an empty candidate list also satisfies their own
#       "nothing posted" assertions. Since #355, the failing set also gains the three #355
#       fixtures whose own follow-up arm depends on this identical candidate query —
#       write-failure-continues-to-next-issue, write-failure-followup-comment, and
#       write-failure-followup-label — each failing for the identical reason (an empty candidate
#       list means the follow-up section never finds issue #50, so none of their FIXED/WARN/call
#       assertions about it are satisfied); the other ten #355 fixtures never reach the follow-up
#       candidate query at all (their own `prs.json` carries no CLOSED `claude/*` entry) and are
#       unaffected. Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass, identical 16-member
#       failing set.
#   (n) delete the trusted `select` clause from the orphan `trusted_notice_hits` jq filter (so ANY
#       marker-carrying comment counts as trusted, regardless of authorAssociation): 67 pass,
#       3 fail, failing EXACTLY followup-notice-untrusted-marker-ignored,
#       followup-notice-untrusted-marker-no-fix, followup-notice-missing-association-marker — all
#       three now treat the untrusted marker as already-noticed and go silent instead of warning.
#       The saved run shows, for the two `--fix` fixtures (followup-notice-untrusted-marker-ignored
#       and followup-notice-missing-association-marker), both `missing gh call: issue comment 50`
#       and `missing: FIXED #50 (Deferred later): follow-up from PR #12, closed without merge —
#       commented`, alongside the untrusted-WARN diagnostic (`count: expected 1 of 'ignoring an
#       orphan-notice marker from an untrusted comment author', got 0`); the report-only fixture,
#       followup-notice-untrusted-marker-no-fix, shows the identical WARN-count diagnostic but
#       `missing: STALE #50 (Deferred later): filed as a follow-up from PR #12, which was closed
#       without merging` in place of the missing comment call/FIXED line, since it asserts neither
#       in the first place. Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass, identical
#       failing set.
#   (o) delete `ascii_upcase` from BOTH orphan jq blocks (`trusted_notice_hits` and
#       `untrusted_notice_lines`): 69 pass, 1 fail, failing EXACTLY
#       followup-notice-idempotent-lowercase-assoc (kickback K1's fixture, mirroring the multi-PR
#       path's `keep-marker-comment-lowercase-assoc` control) — the saved run shows its seeded
#       comment's lowercase `owner` association no longer matching the uppercase
#       TRUSTED_ASSOCIATIONS list, so the marker is treated as untrusted: the script prints `WARN
#       #50 ... ignoring an orphan-notice marker from an untrusted comment author (owner) ...` and
#       reposts the notice (`FIXED #50` plus a fresh `issue comment 50` call), failing the
#       fixture's `expect_calls_empty`, `expect_absent "FIXED #50"`, and
#       `expect_absent "ignoring an orphan-notice marker ..."` assertions all three. Before
#       kickback K1 this mutant had no fixture whose orphan-notice comment carried a lowercase or
#       mixed-case authorAssociation (every #334 comment fixture used `OWNER`, `NONE`, or omitted
#       the field) and survived (45 pass, 0 fail against the 45-case registry) — the honest gap
#       kickback K1 (#334) closes. Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass, identical
#       failing set.
#   (p) delete the whole untrusted `if [[ -n "$untrusted_notice_lines" ]]; then ... fi` WARN block:
#       67 pass, 3 fail, failing EXACTLY followup-notice-untrusted-marker-ignored,
#       followup-notice-untrusted-marker-no-fix, followup-notice-missing-association-marker — the
#       identical failing set as mutant (n), reached a different way: the saved run shows the
#       script still reaches its notice branch — `FIXED #50` prints for the two `--fix` fixtures,
#       whose `issue comment 50` call is made (so their own `expect_call "issue comment 50"`
#       assertion still passes), and `STALE #50` prints for the report-only fixture, which posts
#       nothing with or without this mutant — but the "ignoring an orphan-notice marker" WARN line
#       never prints: all three show `count: expected 1 of 'ignoring an orphan-notice marker from
#       an untrusted comment author', got 0` plus a matching `missing: (NONE) at …`/`missing:
#       (MISSING) at …` line; followup-notice-untrusted-marker-no-fix has no `expect_call`
#       assertion to begin with (it asserts `expect_calls_empty`, already satisfied by report-only
#       mode regardless of this mutant), so only its `expect_count`/`missing:` pair fails there.
#       Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass, identical failing set.
#   (q) collapse the `if ! $notice_ok; then ... continue; fi` branch entirely (fold an unreadable
#       lookup into "proceed as normal" instead of "leave as found"): 66 pass, 4 fail, failing
#       EXACTLY followup-notice-view-failure-warns-and-keeps, followup-notice-view-failure-warns-
#       no-fix, followup-notice-view-malformed-warns-and-keeps, followup-notice-view-malformed-
#       warns-no-fix — with the guard gone, execution falls through to the trusted/untrusted jq
#       calls on `$followup_comments_doc` regardless of `$notice_ok`. The saved runs show the two
#       failure-route cases and the two malformed-route cases differ in what jq actually does:
#       for the failure-route pair, `$followup_comments_doc` is empty (the failed `gh issue view`
#       produces no stdout) and both jq calls (each fed via `|| true`) print no stderr at all and
#       exit cleanly with an empty captured value — jq given completely empty input produces no
#       output rather than "failing to parse" it; for the malformed-route pair,
#       `$followup_comments_doc` is the literal non-JSON text and both calls DO print `jq: parse
#       error: Invalid numeric literal at line 1, column 4` (once each, visible in the saved
#       merged output) before `|| true` empties the captured value the same way. Either route
#       leaves `$trusted_notice_hits`/`$untrusted_notice_lines` empty, so the script silently
#       posts the notice (or prints STALE) instead of warning. Unchanged by #370 (RE-MEASURED
#       2026-09-23): +10 pass, identical failing set.
#   (r) drop the malformed-document `elif` branch (fold it back so only a hard fetch failure sets
#       notice_ok=false): 68 pass, 2 fail, failing EXACTLY followup-notice-view-malformed-warns-
#       and-keeps, followup-notice-view-malformed-warns-no-fix. Unchanged by #370 (RE-MEASURED
#       2026-09-23): +10 pass, identical failing set.
#   (s) wrap the `echo "WARN ... orphan-notice lookup failed ..."` line (only the echo, not the
#       `continue` after it) in `if $FIX; then ... fi`: 68 pass, 2 fail, failing EXACTLY
#       followup-notice-view-failure-warns-no-fix, followup-notice-view-malformed-warns-no-fix —
#       the report-only pair, the only fixtures that can see a WARN gated behind $FIX (LESSON
#       2026-09-08, the same reason mutant (k) above names). Unchanged by #370 (RE-MEASURED
#       2026-09-23): +10 pass, identical failing set.
#   (t) make `--add-label no-plan` unconditional (in the #355-restructured code, always take the
#       `has_no_plan_label != "true"` branch's try_write chain, never the "comment alone" branch):
#       68 pass, 2 fail, failing EXACTLY followup-notice-first-run and (since #355, RE-MEASURED
#       2026-09-23) write-failure-continues-to-next-issue — the only two fixtures whose follow-up
#       is already born `no-plan` (the #308 shape) and assert the "commented (no-plan already
#       present)" tail text: both now see a spurious `--add-label no-plan` call and the WRONG tail
#       text, "commented, labelled no-plan", instead. followup-notice-first-run additionally
#       asserts NO `--add-label` call at all, so it fails on two counts; the twelve other #355
#       fixtures, the ten #370 closed-sweep-* fixtures, and the other #334 fixtures are all
#       unaffected — none of them exercises a follow-up that is already labelled `no-plan` AND
#       asserts the "already present" tail text. Unchanged by #370 (RE-MEASURED 2026-09-23): +10
#       pass, identical failing set.
#   (u) delete the second marker line (`${orphan_marker}`) from the posted comment body, leaving
#       only `${AUDIT_MARKER}` followed directly by the prose: 69 pass, 1 fail, failing EXACTLY
#       followup-notice-first-run — the only fixture that asserts the literal
#       `<!-- harness-orphan-notice: PR #12 -->` line appears in the posted call (RE-MEASURED
#       2026-09-23: none of the twelve #355 write-failure-* fixtures assert on that literal line;
#       RE-MEASURED AGAIN 2026-09-23 (#370): none of the ten closed-sweep-* fixtures does either).
#       Unchanged by #370: +10 pass, identical failing set.
#   (v) replace `${p}` with the literal `0` in the marker-key assignment (`orphan_marker=
#       "${ORPHAN_NOTICE_MARKER_PREFIX}0 -->"`, ignoring the actual closed PR number): 62 pass,
#       8 fail, failing EXACTLY followup-notice-first-run, followup-notice-idempotent-second-run,
#       followup-notice-idempotent-report-only, followup-notice-idempotent-lowercase-assoc
#       (kickback K1's fixture), followup-notice-untrusted-marker-ignored,
#       followup-notice-untrusted-marker-no-fix, followup-notice-missing-association-marker, and
#       followup-notice-per-issue-state. The saved run shows: followup-notice-first-run only
#       `missing gh call: <!-- harness-orphan-notice: PR #12 -->` (the notice IS still posted, now
#       naming PR #0, so every other assertion on that fixture still passes);
#       followup-notice-idempotent-second-run and followup-notice-idempotent-lowercase-assoc both
#       `expected no gh mutation calls, got: issue comment 50 --body <!-- harness-audit -->` /
#       `<!-- harness-orphan-notice: PR #0 -->` / the cleanup prose, plus `unexpected: FIXED #50`
#       — their seeded PR #12 markers no longer match the PR #0 the script now searches for, so
#       neither suppresses and the notice is reposted; followup-notice-idempotent-report-only
#       shows only `unexpected: STALE #50` — report-only mode makes no gh calls either way, so
#       there is no "expected no gh mutation calls" diagnostic here, only the reappearing STALE
#       line; followup-notice-untrusted-marker-ignored and followup-notice-untrusted-marker-no-fix
#       both `count: expected 1 of 'ignoring an orphan-notice marker from an untrusted comment
#       author', got 0` plus `missing: (NONE) at https://example.invalid/50#issuecomment-9102`;
#       followup-notice-missing-association-marker the same count line plus
#       `missing: (MISSING) at https://example.invalid/50#issuecomment-9103` — none of these three
#       seeded PR #12 markers matches PR #0, so neither the trusted-hits nor the untrusted-lines
#       filter ever finds it and the WARN never prints; and followup-notice-per-issue-state shows
#       `unexpected gh call: issue comment 51` plus `unexpected: FIXED #51` — issue #51's seeded
#       PR #12 "already noticed" marker no longer matches, so it gets a second notice posted too.
#       A wider failing set than a same-value literal like `12` would have produced, confirmed by
#       re-running rather than assumed, per LESSON 2026-09-07; followup-notice-marker-is-per-pr and
#       followup-notice-audit-marker-alone-does-not-suppress are unaffected — neither fixture's
#       seeded comment ever matched the real marker in the first place. Unchanged by #370
#       (RE-MEASURED 2026-09-23): +10 pass, identical failing set.
#
# MEASURED MUTANTS, #355 (2026-09-23), taken by the identical scratch-copy workflow the (a)-(l)
# block's own header describes above — one fresh `tar --exclude=.git` extraction per mutation,
# never a mutation applied in place on the tracked working tree — against this file's then-final
# 59-case registry, one mutant at a time, on bin/cleanup-after-merge.sh's four write arms, the
# try_write helper, and the pr-open loop's heredoc restructure, RE-MEASURED 2026-09-23 (#370)
# against this file's then-final 69-case registry, by the in-place workflow the (a)-(l) block's own
# header describes above — (M15) alone is a two-part edit: its own sibling (M15b) reverts the
# closing `<<EOF ... EOF` terminator alongside (M15)'s own opening-line change, applied and
# restored together as a single combo mutation via the `combo` apply mode, never independently
# (the earlier #370-block measurement of this same two-part shape applied to the closed-issue
# sweep's own heredoc, (C11)/(C11b), uses the identical `combo` discipline). RE-MEASURED AGAIN
# (#370 kickback round 1, 2026-09-23) against this file's then-final 70-case registry: (M11) and
# (M12) were actually re-run (both by directly editing the tracked working copy in place, per the
# in-place workflow the `MEASURED MUTANTS, #370` block's own header describes) — (M11) unchanged
# at 67 pass, 3 fail (the eleventh #370 fixture never reaches `try_write`, its own
# `closed_issues_ok` gate short-circuits first) and (M12) unchanged at 68 pass, 2 fail (the
# eleventh fixture asserts nothing about the summary line's absence). Every other entry
# ((M1)-(M10), (M13)-(M16)) is restated as a flat +1 pass with its failing set unchanged, per the
# growth-chain note's kickback-round paragraph (mechanism-only, not independently re-run — none of
# them is reachable through the eleventh fixture's own empty-`issues.json`/no-CLOSED-`claude/*`
# shape, and `try_write`'s own shared-helper exception is exactly what (M11)/(M12) above confirm
# by direct re-run). RE-MEASURED A THIRD TIME (#370 kickback round 2, 2026-09-23) against this
# file's now-final 71-case registry: (M11) and (M12) were actually re-run again — (M11) unchanged
# at 68 pass, 3 fail (the twelfth #370 fixture's own writes all succeed, so `try_write`'s failure
# branch is never reached for it) and (M12) unchanged at 69 pass, 2 fail (the twelfth fixture
# asserts nothing about the summary line's absence either). (M2) was also actually re-run this
# round as a third spot check (see the growth-chain note's kickback-round-2 paragraph): 70 pass, 1
# fail, identical failing set, +1 pass. Every other entry ((M1),(M3)-(M10),(M13)-(M16)) is
# restated as a further flat +1 pass with its failing set unchanged, on the identical mechanism,
# without an individual re-run:
#   (M1) restore the bare, unguarded `gh issue comment` in the close arm (the pre-#355 shape):
#       67 pass, 3 fail, failing EXACTLY write-failure-close-comment,
#       write-failure-continues-to-next-issue, write-failure-gh-stderr-not-swallowed — the bare
#       call now trips `set -euo pipefail` the moment the stub's `reject-comment(-once)` marker
#       makes it exit 1, aborting the whole script (rc 1, no Reminder) instead of WARNing and
#       continuing; all three seed `reject-comment`/`reject-comment-once` on the close-arm shape.
#       Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass, identical failing set — none of the
#       ten closed-sweep-* fixtures touches the close arm's own comment write.
#   (M2) same for the close arm's `gh issue edit --remove-label pr-open` (leaving comment and
#       close try_write-guarded): 69 pass, 1 fail, failing EXACTLY write-failure-close-edit.
#       Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass, identical failing set. Actually
#       re-run again (#370 kickback round 2, 2026-09-23, against the 71-case registry, per LESSON
#       2026-09-07 — the third of three pre-#370 spot checks this round): 70 pass, 1 fail,
#       identical failing set, +1 pass — the twelfth fixture's own remove-label write succeeds, so
#       it never reaches this mutated call at all.
#   (M3) same for the close arm's `gh issue close` (leaving comment guarded, and re-guarding
#       remove-label around the now-bare close's exit status): 69 pass, 1 fail, failing EXACTLY
#       write-failure-close-close. Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass, identical
#       failing set.
#   (M4) same for the KEEP relabel arm's `gh issue comment`: 69 pass, 1 fail, failing EXACTLY
#       write-failure-keep-comment. Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass,
#       identical failing set.
#   (M5) same for the KEEP relabel arm's `gh issue edit --remove-label pr-open`: 69 pass, 1 fail,
#       failing EXACTLY write-failure-keep-edit. Unchanged by #370 (RE-MEASURED 2026-09-23): +10
#       pass, identical failing set.
#   (M6a) same for the requeue arm's `gh issue comment`: 69 pass, 1 fail, failing EXACTLY
#       write-failure-requeue-comment. Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass,
#       identical failing set.
#   (M6b) same for the requeue arm's `gh issue edit --remove-label pr-open`: 69 pass, 1 fail,
#       failing EXACTLY write-failure-requeue-edit. Unchanged by #370 (RE-MEASURED 2026-09-23):
#       +10 pass, identical failing set.
#   (M7) replace the close arm's `&&`-chained try_write calls with three semicolon-separated
#       statements, still inside the same `if …; then` list (no skip-the-rest — bash's `set -e`
#       exemption for an `if` condition covers EVERY statement in that list, not just the last one
#       tested, so none of the three aborts the script): 67 pass, 3 fail, failing EXACTLY
#       write-failure-close-comment (caught by `expect_no_call "issue close"`,
#       `expect_no_call "remove-label"`, AND `expect_absent "FIXED #7"` — all three trip),
#       write-failure-close-close (caught by
#       `expect_no_call "remove-label"` and `expect_absent "FIXED #7"`), and
#       write-failure-continues-to-next-issue (caught only by `expect_absent "FIXED #7"`) — with
#       the `&&` chain gone, `issue close`/`remove-label` are attempted (and logged) even after the
#       comment write fails, and since the `if` list's own truth value is the LAST statement's exit
#       status, the final try_write in the chain succeeding (its own reject-* marker doesn't apply
#       to it) still prints the FIXED line. write-failure-gh-stderr-not-swallowed SURVIVES this
#       mutant — its only assertions are `expect_rc 0` and the stub's own stderr diagnostic, and
#       this mutant changes neither. Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass,
#       identical failing set.
#   (M8) revert the close-arm reorder (comment -> remove-label -> close, the pre-#355 order):
#       68 pass, 2 fail, failing EXACTLY write-failure-close-close (caught by its
#       `expect_no_call "remove-label"`: under `reject-close`, the reordered remove-label call now
#       runs — and succeeds — BEFORE the still-failing close call, so it is logged) and
#       write-failure-close-edit (caught by its `expect_call "issue close 7"`: under `reject-edit`,
#       the reordered remove-label call now runs first, fails, and the `&&` chain skips the close
#       call entirely — the fixture's own claim, a CLOSED issue that still CARRIES pr-open, is
#       never reached under this order). Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass,
#       identical failing set.
#   (M9a) restore a bare `gh issue edit --add-label no-plan` in the follow-up arm's
#       label-then-comment branch: 69 pass, 1 fail, failing EXACTLY write-failure-followup-label.
#       Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass, identical failing set.
#   (M9b) same for that branch's `gh issue comment` (leaving add-label try_write-guarded):
#       69 pass, 1 fail, failing EXACTLY write-failure-followup-comment. Unchanged by #370
#       (RE-MEASURED 2026-09-23): +10 pass, identical failing set.
#   (M10) revert the follow-up reorder (comment -> add-label, the pre-#355 order): 68 pass, 2 fail,
#       failing EXACTLY write-failure-followup-comment, write-failure-followup-label — both assert
#       an add-label-then-comment call order or an `expect_no_call` that only holds under it.
#       Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass, identical failing set.
#   (M11) delete the `write_failures=$((write_failures + 1))` increment from `try_write` (keeping
#       its WARN and `return 1`): 67 pass, 3 fail, failing EXACTLY write-failure-close-comment,
#       write-failure-continues-to-next-issue, and (RE-MEASURED 2026-09-23, #370 — a GENUINE new
#       member, not a flat +10) closed-sweep-write-failure-continues — the three fixtures that
#       assert the summary `WARN    N repair write(s) failed this run` line; the #370 fixture
#       reaches this mutant through the identical shared `try_write` helper the closed-issue sweep
#       calls too (the sweep's own `MEASURED MUTANTS, #370` block has no separate "delete the
#       counter increment" mutant of its own — this IS that mutant, since `try_write` is shared
#       code, not duplicated per call site); every write-failure fixture that asserts only a
#       per-issue WARN (not the summary line), including the other nine closed-sweep-* fixtures,
#       is unaffected. RE-MEASURED A SECOND TIME (#370 kickback round 2, 2026-09-23, against the
#       71-case registry): 68 pass, 3 fail, identical failing set, +1 pass — the twelfth fixture's
#       own remove-label write succeeds, so it never reaches `try_write`'s failure branch either.
#   (M12) print the summary WARN line unconditionally (drop the `if [[ "$write_failures" -gt 0
#       ]]` guard): 68 pass, 2 fail, failing EXACTLY write-failure-markers-inert-no-fix,
#       write-summary-absent-on-clean-run — the two fixtures whose own claim is that the summary
#       line is ABSENT on a run with no failed write. Unchanged by #370 (RE-MEASURED 2026-09-23):
#       +10 pass, identical failing set — no #370 fixture asserts the summary line's absence.
#       RE-MEASURED A SECOND TIME (#370 kickback round 2, 2026-09-23, against the 71-case
#       registry): 69 pass, 2 fail, identical failing set, +1 pass — the twelfth fixture doesn't
#       assert the summary line's absence either.
#   (M13) drop the close arm's own `$FIX` guard (`elif $FIX; then` -> `elif true; then`):
#       68 pass, 2 fail, failing EXACTLY warn-untrusted-marker-no-fix,
#       write-failure-markers-inert-no-fix — both are report-only (no `--fix`) runs over a
#       close-path fixture; with the guard gone the close arm's writes are attempted even in
#       report-only mode, tripping both fixtures' `expect_calls_empty`. Unchanged by #370
#       (RE-MEASURED 2026-09-23): +10 pass, identical failing set — this mutant touches only the
#       MERGED-state close arm's own `$FIX` guard, a different `elif` from the closed-issue
#       sweep's own (proven the other direction by mutant (C1) in the `MEASURED MUTANTS, #370`
#       block below).
#   (M14) add `2>/dev/null` to `try_write`'s own `"$@"` invocation (swallowing gh's own stderr
#       diagnostic, not just its stdout): 69 pass, 1 fail, failing EXACTLY
#       write-failure-gh-stderr-not-swallowed — the one fixture whose claim is that this
#       diagnostic is NOT swallowed. Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass,
#       identical failing set — no closed-sweep-* fixture asserts on the stub's own stderr
#       diagnostic text.
#   (M15) revert the pr-open loop's heredoc restructure, putting it back as the last stage of a
#       `... | while read -r issue; do ... done` pipeline (so `write_failures` is incremented
#       inside a subshell and never reaches the parent shell): 68 pass, 2 fail, failing EXACTLY
#       write-failure-close-comment, write-failure-continues-to-next-issue — the two fixtures that
#       assert the summary line after a pr-open-loop write failure; write-failure-markers-
#       inert-no-fix and write-summary-absent-on-clean-run are unaffected because their own claim
#       is the summary line's ABSENCE, which an always-zero `$write_failures` also produces.
#       Unchanged by #370 (RE-MEASURED 2026-09-23): +10 pass, identical failing set — this mutant
#       reverts the OPEN-issue hygiene loop's own heredoc (lines ~256-410), a wholly separate
#       `while`/`done` pair from the closed-issue sweep's own heredoc loop the `MEASURED MUTANTS,
#       #370` block's own (C11) mutates; no #370 fixture's `issues.json` is ever non-empty, so this
#       loop body never executes for any of them.
#   (M16) echo `try_write`'s own WARN line in its SUCCESS branch too (leaving the failure branch's
#       echo, the counter, and `return 1` untouched): 69 pass, 1 fail, failing EXACTLY
#       write-summary-absent-on-clean-run — every try_write call in that fixture succeeds, so the
#       now-duplicated WARN text ("failed (gh exited non-zero") appears in `$cleanup_out` even
#       though no write actually failed, tripping its `expect_absent "failed (gh exited
#       non-zero"`. write-failure-close-comment's own `expect_count ... 1` does NOT gain a
#       citation from this mutant: that fixture's only try_write call fails (never reaching the
#       success branch this mutant edits), so the count stays 1 under (M16) too. Unchanged by #370
#       (RE-MEASURED 2026-09-23): +10 pass, identical failing set — every closed-sweep-* fixture
#       whose own try_write calls succeed (closed-sweep-removes-label, closed-sweep-no-pr-still-
#       removes) asserts neither `expect_absent "failed (gh exited non-zero"` nor any assertion
#       this mutant's duplicated success-branch WARN text would trip.

# MEASURED MUTANTS, #370 (2026-09-23), taken by directly editing the TRACKED working copy of
# bin/cleanup-after-merge.sh (or, for (C12)/(C13), this file's own stub) in place, running `bash
# dev/cleanup-tests.sh` against the final 69-case registry, saving its full output, then restoring
# the pristine text and diffing to confirm a clean restore before the next mutation — a variant of
# the (a)-(l) block's own tar-scratch-copy discipline that edits the SAME file in place instead of
# a disposable copy (both leave the tracked tree byte-identical once measurement is done), on
# bin/cleanup-after-merge.sh's new closed-issue pr-open sweep section (the "== closed issues still
# labelled pr-open ==" block) unless noted. RE-MEASURED (#370 kickback round 1, 2026-09-23) against
# this file's then-final 70-case registry, by the identical in-place workflow: every entry (C1)-(C13)
# below was ACTUALLY re-run (not assumed, per LESSON 2026-09-07) — the eleventh #370 fixture,
# closed-sweep-query-malformed-continues, shifts every one of them by a flat +1 pass with an
# UNCHANGED failing set, EXCEPT (C5) and (C8), both of which reach the closed-issue query arm the
# new fixture's own `malformed-closed-list` marker exercises, and both re-measured and restated
# below with their new failing set named in full (not assumed to be a flat +1, per the same
# lesson). Two new mutants were added in that round, each with its own killing fixture: (C14), on
# the `closed-sweep-none` control fixture, and (C15), on the eleventh fixture itself. RE-MEASURED A
# SECOND TIME (#370 kickback round 2, 2026-09-23) against this file's now-final 71-case registry, by
# the identical in-place workflow: every entry (C1)-(C15) below was AGAIN actually re-run (not
# assumed, per LESSON 2026-09-07) — the twelfth #370 fixture,
# closed-sweep-other-issue-pr-open-still-removes, shifts every one of them by a flat +1 pass with an
# UNCHANGED failing set, EXCEPT (C5) and (C9), both of which reach code the new fixture's own two
# OPEN PRs (for OTHER issues, neither matching the `claude/7-*` prefix) exercises, and both
# re-measured and restated below with their new failing set named in full (not assumed to be a flat
# +1, per the same lesson). One new mutant is added below, (C16), on the twelfth fixture itself —
# see that fixture's own comment for the self-mutation check that confirmed it fails under the
# mutation, and for a second, narrower variant also measured but not entered as a separate letter
# (it produces the identical failing set). RE-MEASURED A THIRD TIME (#370 kickback round 3,
# 2026-09-23): NO fixture was added this round (the registry stays 71-case) — instead,
# closed-sweep-removes-label gained one new assertion, `expect_list_call "--label pr-open --state
# closed --json number,title --limit 100"`, pinning the closed-issue query's own literal `--limit
# 100` argument (a verifier finding: deleting ` --limit 100` from
# bin/cleanup-after-merge.sh's closed-issue query previously survived every suite, since nothing
# observed the query's own argument list). Every one of (C1)-(C16) below is UNAFFECTED (no fixture
# was added or removed, and the new assertion inspects only the new, separate
# `gh-list-calls.log`/`$list_calls`, which none of (C1)-(C16)'s own mutations touch except (C5) —
# see (C5)'s own entry, already a failing member for unrelated reasons, so its failing-set
# membership and figures are unchanged). One new mutant is added below, (C17), on
# closed-sweep-removes-label itself. RE-MEASURED A FOURTH TIME (#370 kickback round 4, 2026-09-23):
# NO fixture was added this round either (the registry stays 71-case) — instead,
# closed-sweep-removes-label gained two more new assertions, `expect "== closed issues still
# labelled pr-open =="` (a verifier finding: deleting that section header's own `echo` line from
# bin/cleanup-after-merge.sh survived every prior round) and `expect_section_order "== pr-open
# label hygiene ==" "== closed issues still labelled pr-open ==" "== follow-ups from rejected PRs
# =="` (pinning the header's POSITION, not just its presence). (C5), (C16), and (C17) — the three
# mutants the round explicitly asked to be re-measured — were each ACTUALLY re-run (not assumed)
# against the grown assertion set and are UNCHANGED: (C5) still 54 pass/17 fail with the identical
# 17-member failing set (the header still prints unconditionally before the mutated query's own `if`
# gate, so rerouting the query to the open arm does not touch the header text or its position); (C16)
# still 70 pass/1 fail, failing EXACTLY closed-sweep-other-issue-pr-open-still-removes (that mutant
# never touches the header echo lines either); (C17) still 70 pass/1 fail, failing EXACTLY
# closed-sweep-removes-label (deleting ` --limit 100` changes only the query's own argument list).
# Every OTHER pre-round-4 mutant in this and the earlier blocks is UNAFFECTED by the same mechanism
# (none of their mutations touch the three header `echo` lines or reorder the sections), so none is
# individually re-run this round. Round 4 also ran a full literal sweep against the acceptance
# criteria (see the "Kickback round 4" paragraph below, after the (C1)-(C22) entries, for the
# literal -> fixture:assertion -> mutant table) and found three further literals with an existing
# assertion but no measured mutant of their own: the sweep's "no comment, no close" fact, its exact
# `gh issue edit <n> --remove-label pr-open` write, and its `first // empty` jq fallback. Five new
# mutants are added below: (C18) (deleting the section header's own `echo` line, the verifier's own
# suggested mutation), (C19) (physically moving the closed-issue-sweep block to run after the
# follow-ups block instead of before it, the "swap it after the follow-ups section" mutation the
# round itself suggested), (C20) (a spurious `gh issue comment` call, backing "no comment, no
# close"), (C21) (changing the write's own `--remove-label pr-open` argument, backing the exact
# write literal), and (C22) (deleting the ` // empty` fallback, backing that literal) — each with
# its own measured failing set; see their own entries below for the self-mutation check and the
# mechanism argument for why every other fixture is unaffected. Mutant count: seventeen -> twenty-two.
#   (C1) drop the sweep's own `$FIX` guard (`elif $FIX; then` -> `elif true; then`): 69 pass,
#       1 fail, failing EXACTLY closed-sweep-report-only — the only report-only fixture whose
#       closed issue has no open sibling PR (so it reaches the mutated `elif`), where an
#       unconditional write is now attempted, tripping `expect_calls_empty`. RE-MEASURED (#370
#       kickback round 1): unaffected, +1 pass — the eleventh fixture's own `closed_issues_ok` gate
#       is false before this `elif` is ever reached. RE-MEASURED (#370 kickback round 2): unaffected,
#       +1 pass — the twelfth fixture runs with `--fix`, so `$FIX` is already true and the mutation
#       changes nothing for it either.
#   (C2) replace the sweep's `try_write`-guarded `gh issue edit --remove-label pr-open` with a
#       bare, unguarded call: 69 pass, 1 fail, failing EXACTLY closed-sweep-write-failure-continues
#       — the only sweep fixture that seeds a reject marker (`reject-edit-once`) for this call; the
#       bare command trips `set -euo pipefail` on failure and aborts the whole script (no
#       Reminder, no follow-ups section, no summary line) instead of WARNing and continuing to #9.
#       RE-MEASURED (#370 kickback round 1): unaffected, +1 pass — the mutated line is never reached
#       by the eleventh fixture either. RE-MEASURED (#370 kickback round 2): unaffected, +1 pass —
#       the twelfth fixture seeds no reject marker either, so the mutated bare call still succeeds.
#   (C3) delete the open-PR guard (`if [[ -n "$open_pr" ]]; then` -> `if false; then`): 68 pass,
#       2 fail, failing EXACTLY closed-sweep-keeps-while-pr-open,
#       closed-sweep-keeps-while-pr-open-no-fix — the two fixtures whose closed issue has a
#       claude/7-* PR still OPEN; with the guard gone the sweep skips straight to the
#       $FIX/STALE branch and removes (or offers to remove) the label out from under the open PR
#       in both modes. RE-MEASURED (#370 kickback round 1): unaffected, +1 pass. RE-MEASURED (#370
#       kickback round 2): unaffected, +1 pass — the twelfth fixture's closed issue has no
#       claude/7-* PR at all (open or otherwise), so it never reaches this guard.
#   (C4) compute `open_pr` from the LATEST PR by number instead of any OPEN one (`sort_by(.number)
#       | last | if .state == "OPEN" then .number else empty end`): 68 pass, 2 fail, failing
#       EXACTLY closed-sweep-keeps-while-pr-open, closed-sweep-keeps-while-pr-open-no-fix — the
#       identical failing set as (C3), reached differently: both fixtures' higher-numbered PR #12
#       is MERGED, not OPEN, so "the latest PR's state" reports not-open even though the
#       lower-numbered PR #11 actually is. RE-MEASURED (#370 kickback round 1): unaffected, +1 pass.
#       RE-MEASURED (#370 kickback round 2): unaffected, +1 pass — the twelfth fixture's own
#       `select` still yields zero matches (neither claude/70-x nor claude/8-x starts with
#       "claude/7-"), so `sort_by(.number) | last` is empty either way.
#   (C5) the sweep's own literal `--state closed` changed to `--state open`: a WIDE cascade, the
#       (d)/(g)-shaped kind this file's own conventions warn must be measured, not assumed: the
#       mutated query now matches the stub's OPEN `--label pr-open` arm instead of the closed one
#       (so the closed arm's own `gh-list-calls.log` write, #370 kickback round 3, is never
#       reached either — closed-sweep-removes-label's own `expect_list_call` assertion also fails
#       under this mutant, though that fixture was already a failing member for the reasons
#       below), and the sweep silently re-processes whatever `issues.json` (projected to
#       `number,title` only) holds instead of `closed-pr-open.json`. Current measured figure
#       (RE-MEASURED 2026-09-23, #370 kickback round 3, against the final 71-case registry, re-run
#       rather than assumed per LESSON 2026-09-07, superseding every earlier round's own figure
#       for this mutant): 54 pass, 17 fail, failing EXACTLY the ten #370 closed-sweep-* fixtures
#       other than closed-sweep-none and closed-sweep-skipped-when-pr-list-fails
#       (closed-sweep-removes-label, closed-sweep-report-only, closed-sweep-keeps-while-pr-open,
#       closed-sweep-keeps-while-pr-open-no-fix, closed-sweep-no-pr-still-removes,
#       closed-sweep-write-failure-continues, closed-sweep-query-failure-continues,
#       closed-sweep-query-malformed-continues, closed-sweep-independent-of-open-list, and
#       closed-sweep-other-issue-pr-open-still-removes — closed-sweep-none has neither
#       `closed-pr-open.json` nor a non-empty `issues.json`, so it prints "no closed issues
#       labelled pr-open" either way; closed-sweep-skipped-when-pr-list-fails never reaches this
#       query at all, PR_MODE=fail short-circuiting it first; closed-sweep-query-malformed-continues
#       seeds a `malformed-closed-list` marker that the mutated, rerouted-to-OPEN code path never
#       consults (that check lives only in the closed arm's own `case "$*"` branch), so it instead
#       serves the fixture's empty `issues.json` and the expected `could not fetch closed issues
#       labelled pr-open` WARN never prints; closed-sweep-other-issue-pr-open-still-removes's own
#       `issues.json` is `[]` too, the identical shape every other member of this failing set
#       shares, so the mutated code serves an empty list instead of issue #7's real closed-list
#       entry and the expected `FIXED #7` line never prints) PLUS the seven pre-existing #249/#355
#       fixtures whose own `issues.json` names issue #7 with a claude/7-* PR the sweep's own
#       (now-open-query-sourced) re-processing acts on a second time: view-failure-warns-and-keeps,
#       view-malformed-warns-and-keeps, write-failure-close-comment, write-failure-close-close,
#       write-failure-keep-comment, write-failure-requeue-comment, and
#       write-failure-continues-to-next-issue — each trips an `expect_calls_empty` or an exact
#       gh-calls.log assertion the extra, second pass over issue #7 now violates. This is the one
#       #370 mutant whose failing set reaches OUTSIDE the closed-sweep-* fixtures.
#   (C6) gate the sweep on `$issues_ok` too (`if $closed_issues_ok; then` -> `if $closed_issues_ok
#       && $issues_ok; then`): 69 pass, 1 fail, failing EXACTLY
#       closed-sweep-independent-of-open-list — the only fixture that seeds `reject-open-list`
#       (setting `issues_ok=false`) while still expecting the closed-issue sweep to run and repair.
#       RE-MEASURED (#370 kickback round 1): unaffected, +1 pass — the eleventh fixture's own
#       `closed_issues_ok` is already false, so `&& $issues_ok` changes nothing for it. RE-MEASURED
#       (#370 kickback round 2): unaffected, +1 pass — the twelfth fixture never sets
#       `reject-open-list`, so `$issues_ok` is already true for it too.
#   (C7) drop the `$prs_ok` gate (`if ! $prs_ok; then` -> `if false; then`): 69 pass, 1 fail,
#       failing EXACTLY closed-sweep-skipped-when-pr-list-fails — the only fixture built with
#       `build_stub_gh "$dir" ok fail` (PR_MODE=fail); with the gate gone the sweep's own query
#       runs anyway (the stub's `issue list` arm is independent of PR_MODE) and removes the label,
#       contradicting both the missing skip WARN and `expect_calls_empty`. RE-MEASURED (#370
#       kickback round 1): unaffected, +1 pass — the eleventh fixture's own `prs_ok` is true either
#       way, so this gate already takes the `else` branch for it regardless of the mutation.
#       RE-MEASURED (#370 kickback round 2): unaffected, +1 pass — the twelfth fixture's own
#       `prs_ok` is true too (PR_MODE=ok, the default).
#   (C8) fold a failed closed-issue query into an empty list with no WARN
#       (`closed_issues_ok=false; echo WARN ...` -> `closed_issues="[]"`): 68 pass, 2 fail, failing
#       EXACTLY closed-sweep-query-failure-continues and (RE-MEASURED, #370 kickback, 2026-09-23,
#       against the 70-case registry — a GENUINE new member, not a flat +1)
#       closed-sweep-query-malformed-continues — the two fixtures seeding, respectively,
#       `reject-closed-list` and `malformed-closed-list`, each asserting `expect_count "could not
#       fetch closed issues labelled pr-open" 1`; the mutant's single `if` condition catches BOTH
#       the hard-failure route and the malformed-body route identically (they are the same `||`
#       guard), so folding its `then` branch into a silent `closed_issues="[]"` prints "no closed
#       issues labelled pr-open" instead for both, silently. RE-MEASURED (#370 kickback round 2):
#       unaffected, +1 pass, identical failing set — the twelfth fixture seeds neither
#       `reject-closed-list` nor `malformed-closed-list`, so its own closed-issue query still
#       succeeds unmutated.
#   (C9) `continue` past a closed issue with no claude/<n>-* PR at all (any state), instead of
#       sweeping it: 67 pass, 3 fail, failing EXACTLY closed-sweep-no-pr-still-removes,
#       closed-sweep-write-failure-continues, closed-sweep-independent-of-open-list — the three
#       #370 fixtures whose own `prs.json` is `[]`; every other #370 fixture has at least one PR
#       matching `claude/7-*`, so the new `any_pr` check never trips for them. RE-MEASURED (#370
#       kickback round 1): unaffected, +1 pass — the eleventh fixture never reaches the loop body at
#       all (`closed_issues_ok` is false). RE-MEASURED A SECOND TIME (#370 kickback round 2,
#       2026-09-23, against the 71-case registry): the twelfth fixture, closed-sweep-other-issue-
#       pr-open-still-removes, ALSO JOINS the failing set (67 pass, 4 fail): its own `prs.json` is
#       non-empty, but neither PR's `headRefName` (`claude/70-x`, `claude/8-x`) starts with
#       `claude/7-`, so the new `any_pr` check reads zero matches — the identical "no claude/<n>-*
#       PR at all" condition the three `prs.json: []` members already trip, reached a different way
#       — and the mutant `continue`s past issue #7 entirely, silently dropping both the expected
#       `FIXED #7` line and the `issue edit 7 --remove-label pr-open` call.
#   (C10) require `$FIX` for the `ok` line too (`if [[ -n "$open_pr" ]]; then` -> `if [[ -n
#       "$open_pr" ]] && $FIX; then`): 69 pass, 1 fail, failing EXACTLY
#       closed-sweep-keeps-while-pr-open-no-fix — the only report-only fixture with an open
#       sibling PR; with the `ok` line gated behind `$FIX`, the mutated code falls through to the
#       `else` arm and prints STALE instead, tripping both `expect "ok    #7"` and
#       `expect_absent "STALE #7"`. RE-MEASURED (#370 kickback round 1): unaffected, +1 pass.
#       RE-MEASURED (#370 kickback round 2): unaffected, +1 pass — the twelfth fixture runs with
#       `--fix` and has no open sibling PR, so it never reaches this `if` at all.
#   (C11) revert the sweep loop's heredoc to a pipe (`echo "$closed_issue_lines" | while IFS= read
#       -r ci; do ... done`, dropping the `<<EOF` form entirely, so `write_failures` increments in
#       a subshell and never reaches the parent shell — the identical shape (M15) pins for the
#       pr-open loop): 69 pass, 1 fail, failing EXACTLY closed-sweep-write-failure-continues — the
#       only #370 fixture that asserts the summary line after a sweep write failure. RE-MEASURED
#       (#370 kickback round 1): unaffected, +1 pass — the eleventh fixture never reaches the loop.
#       RE-MEASURED (#370 kickback round 2): unaffected, +1 pass — the twelfth fixture's own writes
#       all succeed, so it asserts nothing about `write_failures`.
#   (C12) delete the stub's `reject-open-list` check in `dev/cleanup-tests.sh` (the closed arm's
#       own `reject-closed-list` check is untouched): 69 pass, 1 fail, failing EXACTLY
#       closed-sweep-independent-of-open-list — with the marker file silently ignored, the open
#       query succeeds (serving `issues.json`, `[]` for this fixture) instead of failing, so the
#       "could not fetch issues labelled pr-open" WARN this fixture asserts never prints.
#       RE-MEASURED (#370 kickback round 1): unaffected, +1 pass — the eleventh fixture never sets
#       `reject-open-list`. RE-MEASURED (#370 kickback round 2): unaffected, +1 pass — the twelfth
#       fixture never sets it either.
#   (C13) delete the closed arm's own jq projection call in the stub (always `cat`s
#       `closed-pr-open.json` unprojected regardless of the requested `--json` field list): 69
#       pass, 1 fail, failing EXACTLY stub-json-script-field-lists-accepted — the extended fifth
#       probe's `expect_absent '"labels"'` assertion, the one case that ever inspects the closed
#       arm's raw payload for a field the script didn't request. RE-MEASURED (#370 kickback round
#       1): unaffected, +1 pass — the eleventh fixture's own `malformed-closed-list` marker short-
#       circuits before the mutated `cat` is ever reached. RE-MEASURED (#370 kickback round 2):
#       unaffected, +1 pass — the twelfth fixture's own field-projected read never inspects the raw
#       payload either.
#   (C14) replace the empty-list branch's own `echo "no closed issues labelled pr-open"` with `:`
#       (a no-op): 69 pass, 1 fail, failing EXACTLY closed-sweep-none — measured (self-mutation
#       check, 2026-09-23, applied to the TRACKED working copy and restored) — closed-sweep-none is
#       the only fixture whose own closed-issue query succeeds with a genuinely empty list AND
#       asserts on the "no closed issues labelled pr-open" line itself; every other closed-sweep-*
#       fixture's own `closed-pr-open.json` is non-empty (so it never reaches this branch) or its
#       query fails outright (so `closed_issues_ok` is already false and this branch is never
#       reached either). RE-MEASURED (#370 kickback round 2): unaffected, +1 pass, identical failing
#       set — the twelfth fixture's own `closed-pr-open.json` is non-empty too (it names issue #7),
#       so it never reaches this branch either.
#   (C15) delete the closed-issue query's own `jq -e .` validity clause entirely (`if !
#       closed_issues="$(gh issue list ...)" || ! printf '%s' "$closed_issues" | jq -e .
#       >/dev/null 2>&1; then` -> `if ! closed_issues="$(gh issue list ...)"; then`, dropping the
#       trailing `|| ! ... jq -e .` term): 69 pass, 1 fail, failing EXACTLY
#       closed-sweep-query-malformed-continues — the only fixture whose `gh issue list` call
#       EXITS 0 (so the guard's remaining first clause alone no longer catches it) but returns a
#       non-JSON body; with the `jq -e .` clause gone, `closed_issues_ok` stays true and execution
#       falls through to `jq 'length'` on the malformed text — measured (self-mutation check,
#       2026-09-23, applied to the TRACKED working copy and restored): `jq: parse error: Invalid
#       numeric literal at line 1, column 4` prints to stderr, `[[ $(...) -eq 0 ]]` evaluates true
#       on jq's empty stdout, and the script silently prints "no closed issues labelled pr-open"
#       instead of the expected WARN — NOT the `set -euo pipefail` abort a first guess might
#       expect, since a command substitution's failure inside an `if` condition is one of bash's
#       own documented `set -e` exemptions. No other fixture is affected: every fixture whose own
#       closed-issue query is expected to succeed serves a well-formed `closed-pr-open.json` (or
#       none, defaulting to `[]`), and closed-sweep-query-failure-continues's own `gh issue list`
#       call still exits 1 via `reject-closed-list`, still caught by the guard's surviving first
#       clause alone. RE-MEASURED (#370 kickback round 2): unaffected, +1 pass, identical failing
#       set — the twelfth fixture seeds neither `reject-closed-list` nor `malformed-closed-list`, so
#       its own closed-issue query still succeeds cleanly.
#   (C16) narrow the sweep's own `--arg p "claude/${n}-"` prefix to `--arg p "claude/"` (dropping
#       the issue-number scoping entirely, so ANY open `claude/*` PR, for any issue, keeps the
#       label): 70 pass, 1 fail, failing EXACTLY closed-sweep-other-issue-pr-open-still-removes —
#       the only #370 fixture with an OPEN PR for a DIFFERENT issue number (claude/70-x for #70,
#       claude/8-x for #8, neither for the closed issue #7 itself); with the scoping gone, either
#       PR satisfies `startswith("claude/")` and `open_pr` comes back non-empty, so the mutated code
#       prints the `ok` line and keeps the label instead of removing it — measured (self-mutation
#       check, 2026-09-23, applied to the tracked working copy and restored). A second, narrower
#       variant — `--arg p "claude/${n}"`, dropping only the trailing hyphen — was also measured
#       directly (self-mutation check, applied and restored): identical result (70 pass, 1 fail,
#       the identical single failing member), since claude/70-x alone still satisfies
#       `startswith("claude/7")` even without the hyphen; not entered as its own letter since it
#       produces no new information over (C16). No other fixture's `prs.json` contains a PR for a
#       different issue number, so neither mutation is reachable outside this one fixture. This
#       fixture is ALSO caught by (C5) and (C9) above, for unrelated reasons (its own `issues.json`
#       is `[]`, and neither PR matches the `claude/7-*` prefix at all) — see its own comment.
#   (C17) delete ` --limit 100` from the closed-issue query's own literal argument list (`gh issue
#       list --label pr-open --state closed --json number,title --limit 100` ->
#       `gh issue list --label pr-open --state closed --json number,title`, leaving the
#       `--state closed` substring the stub's `case "$*"` match depends on untouched, so the closed
#       arm still runs and still returns `closed-pr-open.json` unchanged): 70 pass, 1 fail, failing
#       EXACTLY closed-sweep-removes-label — the only fixture with an `expect_list_call` assertion
#       naming ` --limit 100`; every other assertion in that fixture (the `FIXED #7` line, the
#       `issue edit 7 --remove-label pr-open` call, the absence of a comment or close call) still
#       passes under this mutant, since deleting the flag changes only the query's own argument
#       list, never the stub's routing or the closed-pr-open.json payload it serves — measured
#       (self-mutation check, 2026-09-23, #370 kickback round 3, applied directly to the tracked
#       working copy of bin/cleanup-after-merge.sh and restored, diffed clean against the
#       pre-mutation backup before and after). No other fixture asserts on `$list_calls` at all, so
#       this is the only killing member; RESOLVED and the first acceptance criterion both name this
#       exact command line as the one this suite must observe.
#   (C18) delete the closed-issue sweep's own section-header `echo` line entirely (`echo "== closed
#       issues still labelled pr-open =="` at bin/cleanup-after-merge.sh:415 -> nothing, the exact
#       mutation the verifier's own finding names): 70 pass, 1 fail, failing EXACTLY
#       closed-sweep-removes-label — the only fixture asserting `expect "== closed issues still
#       labelled pr-open =="` (and, redundantly, `expect_section_order`'s own "missing" branch on
#       the same needle) — measured (self-mutation check, 2026-09-23, #370 kickback round 4, applied
#       directly to the tracked working copy of bin/cleanup-after-merge.sh and restored, diffed
#       clean against the pre-mutation backup before and after). No other fixture asserts on this
#       header text at all, so this is the only killing member.
#   (C19) physically move the whole closed-issue-sweep block (the `echo`/header through its closing
#       `fi`, bin/cleanup-after-merge.sh:414-452 pre-mutation) to run AFTER the follow-ups block
#       (:454-579 pre-mutation) instead of before it — the two blocks are mutually independent (the
#       closed sweep reads only `$prs`/`$FIX`/`try_write`, none of which the follow-ups block
#       redefines, and vice versa), so the mutated script still runs to completion and every
#       assertion that does not care about ORDER still passes, including
#       closed-sweep-removes-label's own `expect_list_call`, `expect_call`, `expect_no_call`, and the
#       (now merely relocated) `expect "== closed issues still labelled pr-open =="` line itself:
#       70 pass, 1 fail, failing EXACTLY closed-sweep-removes-label, via its `expect_section_order`
#       assertion alone (`section order: '== follow-ups from rejected PRs ==' at line 20 is not
#       after the previous section (line 23)` — the captured `$__why` diagnostic, confirming the
#       failure is the order check and nothing else) — measured (self-mutation check, 2026-09-23,
#       #370 kickback round 4, applied by extracting bin/cleanup-after-merge.sh into six line-range
#       fragments with `sed -n`, reassembling them in the swapped order, verifying with `bash -n`,
#       installing the result in place, then restoring the pre-mutation backup and diffing clean).
#       No other fixture asserts on section order at all, so this is the only killing member; this
#       is the "swap it after the follow-ups section" mutation the round's own instructions name.
#   (C20) add a spurious, unconditional `gh issue comment "$n" --body "..."` call (ignoring its own
#       exit code) inside the sweep's own `elif $FIX; then` branch, immediately before the guarded
#       `try_write ... gh issue edit ... --remove-label pr-open` call — backing the round-4 literal
#       sweep's "no comment, no close" fact (the closed-issue sweep is label-only BY CONSTRUCTION;
#       nothing in the pre-mutation code path ever calls `gh issue comment`/`gh issue close`, so no
#       PRE-EXISTING mutant happens to add one): 70 pass, 1 fail, failing EXACTLY
#       closed-sweep-removes-label — the only sweep fixture asserting `expect_no_call "issue
#       comment"`, tripped by the stub's `issue comment|edit|close` arm logging the spurious call to
#       `gh-calls.log` regardless of its own (ignored) exit status — measured (self-mutation check,
#       2026-09-23, #370 kickback round 4, applied directly to the tracked working copy of
#       bin/cleanup-after-merge.sh and restored, diffed clean against the pre-mutation backup before
#       and after; `$__why` read back as `unexpected gh call: issue comment`, confirming the
#       mechanism). No other fixture asserts `expect_no_call "issue comment"` on a --fix run through
#       this section, so this is the only killing member.
#   (C21) change the sweep's own write from `gh issue edit "$n" --remove-label pr-open` to `gh issue
#       edit "$n" --remove-label no-plan` (the label-removal call's own argument text, distinct from
#       (C2)'s guard-removal, which leaves this argument untouched) — backing the round-4 literal
#       sweep's "the exact write `gh issue edit <n> --remove-label pr-open`" fact: 68 pass, 3 fail,
#       failing EXACTLY closed-sweep-removes-label, closed-sweep-no-pr-still-removes, and
#       closed-sweep-other-issue-pr-open-still-removes — the three sweep fixtures with a successful,
#       label-removing --fix run whose own `expect_call "issue edit 7 --remove-label pr-open"`
#       assertion names the mutated argument by value; every other sweep fixture either never
#       reaches a successful removal (report-only, keeps-while-pr-open, write-failure, the two
#       query-failure fixtures) or asserts nothing about the write's own argument text — measured
#       (self-mutation check, 2026-09-23, #370 kickback round 4, applied directly to the tracked
#       working copy of bin/cleanup-after-merge.sh and restored, diffed clean against the
#       pre-mutation backup before and after).
#   (C22) delete the ` // empty` fallback from the sweep's own `open_pr` jq expression (`| first //
#       empty` -> `| first`) — backing the round-4 literal sweep's "`first // empty`" fact: on an
#       empty candidate array (no claude/<n>-* PR open at all), `jq -r`'s own null-to-"null" string
#       serialization (confirmed directly: `echo '[]' | jq -r '[...] | first'` prints the four-byte
#       string `null`, `... | first // empty` prints nothing) makes `open_pr` the non-empty string
#       `"null"` instead of empty, so `[[ -n "$open_pr" ]]` is now true and the mutated code takes
#       the `ok` (PR still open) branch instead of removing the label: 65 pass, 6 fail, failing
#       EXACTLY closed-sweep-removes-label, closed-sweep-report-only, closed-sweep-no-pr-still-
#       removes, closed-sweep-write-failure-continues, closed-sweep-independent-of-open-list, and
#       closed-sweep-other-issue-pr-open-still-removes — every sweep fixture whose closed issue has
#       NO matching open `claude/<n>-*` PR at all (so `open_pr` is empty pre-mutation), which is
#       every #370 fixture except closed-sweep-keeps-while-pr-open(-no-fix) (a REAL open PR, so
#       `first` already returns a real value, mutation or not), closed-sweep-skipped-when-pr-list-
#       fails (the `$prs_ok` gate short-circuits before this jq expression is ever reached),
#       closed-sweep-query-failure-continues/closed-sweep-query-malformed-continues (the
#       `closed_issues_ok` gate has the identical effect), and closed-sweep-none (the empty-list
#       branch never reaches the loop) — measured (self-mutation check, 2026-09-23, #370 kickback
#       round 4, applied directly to the tracked working copy of bin/cleanup-after-merge.sh and
#       restored, diffed clean against the pre-mutation backup before and after; `$__why` read back
#       as `missing: FIXED #7 (Ordinary issue): closed issue` / `missing gh call: issue edit 7
#       --remove-label pr-open` for closed-sweep-removes-label, confirming the mechanism).
#
# Growth-chain note (LESSON 2026-09-10): every #370 fixture's own `issues.json` is `[]`, so none
# of the ten new fixtures is reachable by any pre-#370 mutant that edits the multi-PR KEEP chain
# ((a)-(l), (i)-(l), (n)-(v) as applicable) or the follow-up quarantine ((m)-(v)) — those mutants'
# own code paths only execute when `$issues` (open-issue query) or the follow-up candidate search
# yields a non-empty match, and every #370 fixture's `issues.json` is empty and `prs.json` carries
# no CLOSED (unmerged) claude/* entry. This is a claim about MECHANISM, not merely a neighbouring
# proof's reason copied over, so every one of those blocks' own totals below was re-measured
# (never assumed) against the grown 69-case registry to confirm it, per the same lesson. The one
# EXCEPTION anywhere in the three pre-#370 blocks is mutant (M11) in the `MEASURED MUTANTS, #355`
# block above (see its own re-measured entry): unlike the multi-PR/follow-up code, `try_write` is
# a single shared helper the closed-issue sweep's own writes call too, so deleting its failure
# counter is reachable through the new closed-sweep-write-failure-continues fixture as well as its
# two pre-existing #355 write-failure-* fixtures — a genuine, measured growth, not a flat +10.
#
# Kickback round (2026-09-23, #370): an eleventh #370 fixture, closed-sweep-query-malformed-
# continues, was added (registry 69 -> 70) to pin a killing mutant for the `jq -e .` clause in
# the closed-issue query's own validity guard (see (C15) below; (C14) is the second new mutant
# this round adds, pinning closed-sweep-none instead — see that fixture's own comment). The new
# fixture's own `issues.json` is `[]` and its `prs.json` carries no CLOSED (unmerged) claude/*
# entry, the identical shape the growth-chain note above already establishes as unreachable by
# every pre-#370 mutant that edits the multi-PR KEEP chain or the follow-up quarantine — so every
# measured figure below gains a flat +1 pass, failing set unchanged, EXCEPT the mutants that reach
# the CLOSED-issue query arm itself: (C5) and (C8) (both gain the new fixture as an additional
# FAILING member), mutant (d) (the `pr list` field-set swap, which trips `prs_ok=false` and
# short-circuits the closed-issue sweep before the malformed body is ever read — also gains it as
# a failing member), and mutant (g) (the `labels` deletion, which never touches the closed
# query's own `--json number,title` field list — gains the new fixture as an additional PASSING
# member instead) — each re-measured below and in the `MEASURED MUTANTS, #370` block. Every
# #370-block mutant (C1)-(C13) plus (d), (g), (M11), and (M12) was actually re-run against the
# grown 70-case registry (not assumed) to confirm this; every OTHER pre-#370 mutant this file
# measures — reachable only through the multi-PR KEEP chain, the follow-up quarantine, or a
# helper (`try_write` aside, per the one EXCEPTION the growth-chain note above already names) the
# new fixture's own empty-issues.json/no-CLOSED-PR shape never exercises — is restated as a flat
# +1 pass with its failing set unchanged, on that same mechanism, without an individual re-run
# (LESSON 2026-09-10's mechanism-claim discipline, applied the same direction the growth-chain
# note above already
# applies it: NEW code unreachable by an OLD mutant, not the reverse this note documents).
#
# Kickback round 2 (2026-09-23, #370): a twelfth #370 fixture,
# closed-sweep-other-issue-pr-open-still-removes, was added (registry 70 -> 71) to pin a killing
# mutant for the sweep's own `<n>` scoping — an OPEN `claude/<n>-*` PR for a DIFFERENT issue must
# never keep the label (see (C16) above). The new fixture's own `issues.json` is `[]`, the
# identical shape the growth-chain note above already establishes as unreachable by every
# pre-#370 mutant that edits the multi-PR KEEP chain or the follow-up quarantine — so every
# measured figure in the (a)-(l)/(m)-(v)/M1-M16 blocks gains a flat +1 pass, failing set
# unchanged, EXCEPT the four mutants that reach code this new fixture's own shape actually
# exercises: (d) (the `pr list` field-set swap, which trips `prs_ok=false` and short-circuits the
# closed-issue sweep before the new fixture's own PRs are ever read — gains it as a failing
# member) and (g) (the `labels` deletion, which never touches the closed query's own `--json
# number,title` field list — gains it as a PASSING member instead), both restated in full above
# and in the #370/#355 blocks; (M11) and (M12) are UNAFFECTED (the new fixture's own writes all
# succeed, so neither try_write-failure mutant reaches it) — all four were actually re-run against
# the grown 71-case registry (not assumed), matching (d), (g), (M11), (M12)'s own updated entries.
# Inside the `MEASURED MUTANTS, #370` block itself, (C1)-(C15) were ALL actually re-run too (not
# assumed): every one shifts by a flat +1 pass with an unchanged failing set EXCEPT (C5) and (C9),
# both of which gain the new fixture as an additional failing member — (C5) because the new
# fixture's own `issues.json` is `[]` like every other member of that failing set; (C9) because
# neither of the new fixture's two PRs (`claude/70-x`, `claude/8-x`) matches the `claude/7-*`
# prefix at all, the identical "no claude/<n>-* PR at all" condition (C9) already catches via an
# empty `prs.json` — reached here a different way. (C16) itself is new. Every OTHER pre-#370
# mutant this file measures — reachable only through the multi-PR KEEP chain, the follow-up
# quarantine, or a helper the new fixture's own empty-`issues.json`/no-CLOSED-PR/no-failing-write
# shape never exercises — is restated as a flat +1 pass with its failing set unchanged, on that
# same mechanism, without an individual re-run (LESSON 2026-09-10's mechanism-claim discipline);
# three of those restated mutants — (a) (the `issue) list)` arm's own `validate_json_fields`
# deletion), (l) (the `has_multi_pr_label` `elif` arm's deletion), and (M2) (the close arm's
# `remove-label` call losing its `try_write` guard) — were additionally spot-checked by actual
# re-run (never assumed, per LESSON 2026-09-07) as a sample across the three pre-#370 blocks,
# confirming the mechanism argument: all three shifted by a flat +1 pass with an unchanged failing
# set, exactly as the mechanism predicts.
#
# Kickback round 3 (2026-09-23, #370): a verifier finding that no fixture observed the closed-issue
# query's own literal `--limit 100` argument (deleting it from bin/cleanup-after-merge.sh survived
# every suite) is fixed WITHOUT adding a fixture — the registry stays at 71 — by giving
# `build_stub_gh`'s closed arm a separate `DIR/gh-list-calls.log` (read into `$list_calls`, asserted
# via a new `expect_list_call` helper; the pre-existing, mutation-only `gh-calls.log`/`$calls`/
# `expect_call`/`expect_calls_empty` are untouched) and adding one new assertion,
# `expect_list_call "--label pr-open --state closed --json number,title --limit 100"`, to the
# existing closed-sweep-removes-label fixture. Since no fixture was added or removed, EVERY figure
# in the `MEASURED MUTANTS` blocks above (#334, #355, #370, and the (a)-(l) block) is unaffected —
# there is no new case for any of them to gain as a flat +1 — with the single exception of (C5)
# above, whose own entry is restated in this round (mechanism only, no shift in its 54 pass/17 fail
# figure or its 17-member failing set: closed-sweep-removes-label was already a failing member for
# reasons unrelated to the new assertion). One new mutant, (C17), is added above, on
# closed-sweep-removes-label itself, with its own measured failing set (70 pass, 1 fail, failing
# EXACTLY closed-sweep-removes-label).
#
# Kickback round 4 (2026-09-23, #370): two things, in the same round, so this is the last one.
# First, a verifier finding: no fixture observed the closed-issue sweep's own section header,
# `== closed issues still labelled pr-open ==` (deleting that one `echo` line from
# bin/cleanup-after-merge.sh:415 survived every prior round of this suite) — fixed WITHOUT adding a
# fixture (the registry stays at 71) by giving closed-sweep-removes-label two more assertions,
# `expect "== closed issues still labelled pr-open =="` and a new `expect_section_order` helper
# call pinning the header's POSITION between `== pr-open label hygiene ==` and `== follow-ups from
# rejected PRs ==`, backed by two new mutants, (C18) and (C19) (see their own entries above).
# Second, a full literal sweep against every literal RESOLVED and the acceptance criteria name for
# the #370 closed-issue sweep, each mapped to the fixture:assertion that observes it and the
# mutant letter that is MEASURED to catch a mutation to it — three of these (marked NEW below) had
# an existing assertion but no dedicated mutant before this round, so (C20)-(C22) were added and
# measured to close that gap; every other row already had both, cited here rather than duplicated:
#
#   literal                                    | fixture:assertion                                          | mutant
#   -------------------------------------------|-------------------------------------------------------------|-------
#   full query line (--limit 100 etc.)         | closed-sweep-removes-label:expect_list_call                 | (C17)
#   section header text                        | closed-sweep-removes-label:expect "== closed issues..."     | (C18)
#   section position (hygiene<closed<followups)| closed-sweep-removes-label:expect_section_order              | (C19)
#   FIXED line stem                            | closed-sweep-removes-label:expect "FIXED #7 ..."             | (C22)
#   STALE line stem                            | closed-sweep-report-only:expect "STALE #7 ..."               | (C1)
#   ok line stem                               | closed-sweep-keeps-while-pr-open-no-fix:expect "ok    #7 ..."| (C10)
#   "no closed issues labelled pr-open" line   | closed-sweep-none:expect "no closed issues labelled pr-open" | (C14)
#   (== the empty-list branch, same row)       |                                                               |
#   WARN: closed-issue query failure           | closed-sweep-query-failure-continues:expect_count            | (C8)
#   WARN: PR-list-unavailable skip             | closed-sweep-skipped-when-pr-list-fails:expect "WARN ... sweep skipped" | (C7)
#   try_write desc "removing the pr-open label"| closed-sweep-write-failure-continues:expect "WARN #7 ... removing the pr-open label failed" | (C2)
#   exact write --remove-label pr-open         | closed-sweep-removes-label:expect_call "issue edit 7 --remove-label pr-open" | (C21) NEW
#   "no comment, no close"                     | closed-sweep-removes-label:expect_no_call "issue comment"/"issue close" | (C20) NEW
#   heredoc loop (not a piped subshell)        | closed-sweep-write-failure-continues:expect "WARN    1 repair write(s) failed this run" | (C11)
#   $prs_ok gate                               | closed-sweep-skipped-when-pr-list-fails:expect_calls_empty   | (C7)
#   absence of an $issues_ok gate              | closed-sweep-independent-of-open-list:expect "FIXED #7 ..."  | (C6)
#   .state == "OPEN"                           | closed-sweep-keeps-while-pr-open:expect "ok    #7 ..."        | (C4)
#   claude/${n}- scoping                       | closed-sweep-other-issue-pr-open-still-removes:expect_absent "ok    #7" | (C16)
#   first // empty                             | closed-sweep-removes-label:expect "FIXED #7 ..." / expect_call | (C22) NEW
#
# (C20), (C21), and (C22) were each measured (self-mutation check, applied to the tracked working
# copy of bin/cleanup-after-merge.sh and restored, diffed clean before and after) — see their own
# entries above for the full failing sets. (C5), (C16), and (C17) — the three the round's own
# instructions named for re-measurement — were each actually re-run against the grown (two new
# assertions, no new fixture) registry and are UNCHANGED (see the block header's own "RE-MEASURED A
# FOURTH TIME" paragraph above for the confirmed figures); every other pre-round-4 mutant is unaffected by
# the identical mechanism (none of their mutations touch the header text, the section order, the
# spurious-write surface (C20) adds, the write argument (C21) changes, or the jq fallback (C22)
# deletes). Mutant count: seventeen -> twenty-two (five new: (C18)-(C22)). No new fixture, no new
# gate assertion — the registry stays 71-case and 1.9 (bash-3.2/BSD portability) stays green, since
# `expect_section_order`'s own `awk`/here-string idiom follows the identical portability rules
# every other helper in this file already does (no arrays, no `declare -A`, no GNU-only flags).

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
  "followup-notice-first-run|case_followup_notice_first_run|#334: a not-yet-noticed no-plan follow-up gets the orphan notice, comment carries both marker lines, no add-label call"
  "followup-notice-idempotent-second-run|case_followup_notice_idempotent_second_run|#334: a trusted comment already carrying the orphan-notice marker suppresses a repeat notice"
  "followup-notice-report-only|case_followup_notice_report_only|#334: the first-run fixture without --fix — one STALE line, no gh mutation call"
  "followup-notice-idempotent-report-only|case_followup_notice_idempotent_report_only|#334: the idempotent fixture without --fix — no STALE line, no calls"
  "followup-notice-adds-no-plan-when-absent|case_followup_notice_adds_no_plan_when_absent|#334: an older-harness follow-up with no labels gets both the comment and --add-label no-plan"
  "followup-notice-untrusted-marker-ignored|case_followup_notice_untrusted_marker_ignored|#334: an orphan-notice marker from a NONE-association comment does not suppress; exactly one WARN naming it"
  "followup-notice-untrusted-marker-no-fix|case_followup_notice_untrusted_marker_no_fix|#334: the untrusted-marker fixture without --fix — same WARN, STALE still printed, no calls"
  "followup-notice-missing-association-marker|case_followup_notice_missing_association_marker|#334: an orphan-notice marker from a comment with no authorAssociation field — fail-closed untrusted, same as NONE"
  "followup-notice-idempotent-lowercase-assoc|case_followup_notice_idempotent_lowercase_assoc|#334 kickback K1: a trusted orphan-notice marker whose comment authorAssociation is lowercase 'owner' still suppresses the notice (ascii_upcase)"
  "followup-notice-view-failure-warns-and-keeps|case_followup_notice_view_failure_warns_and_keeps|#334: the per-follow-up orphan-notice lookup fails — one WARN, no calls, issue left as found, with --fix"
  "followup-notice-view-failure-warns-no-fix|case_followup_notice_view_failure_warns_no_fix|#334: the same failed-lookup fixture without --fix — same WARN, no STALE"
  "followup-notice-view-malformed-warns-and-keeps|case_followup_notice_view_malformed_warns_and_keeps|#334: the per-follow-up lookup returns a non-JSON document — one WARN with the malformed route phrase, with --fix"
  "followup-notice-view-malformed-warns-no-fix|case_followup_notice_view_malformed_warns_no_fix|#334: the same malformed fixture without --fix — same WARN, no STALE"
  "followup-notice-marker-is-per-pr|case_followup_notice_marker_is_per_pr|#334: a trusted orphan-notice marker naming a different PR does not suppress — the marker is PR-keyed"
  "followup-notice-audit-marker-alone-does-not-suppress|case_followup_notice_audit_marker_alone_does_not_suppress|#334: a trusted comment carrying only the harness-audit marker does not suppress the notice"
  "followup-notice-per-issue-state|case_followup_notice_per_issue_state|#334: two follow-ups from one PR, one noticed and one not — exactly one comment call, naming the un-noticed issue"
  "write-failure-close-comment|case_write_failure_close_comment|#355: close arm, reject-comment: nothing else in the arm runs, one WARN, no FIXED, summary line, Reminder still prints"
  "write-failure-close-close|case_write_failure_close_close|#355: close arm, reject-close: comment logged, close attempted, remove-label never runs, one WARN, no FIXED"
  "write-failure-close-edit|case_write_failure_close_edit|#355: close arm, reject-edit: comment and close both succeed, remove-label attempted and fails, no FIXED (closed-but-labelled residue)"
  "write-failure-keep-comment|case_write_failure_keep_comment|#355: KEEP relabel arm, reject-comment: KEEP line still prints, remove-label never runs, no 'pr-open removed' line"
  "write-failure-keep-edit|case_write_failure_keep_edit|#355: KEEP relabel arm, reject-edit: comment succeeds, remove-label attempted and fails, no 'pr-open removed' line"
  "write-failure-requeue-comment|case_write_failure_requeue_comment|#355: requeue arm, reject-comment: remove-label never runs, no FIXED"
  "write-failure-requeue-edit|case_write_failure_requeue_edit|#355: requeue arm, reject-edit: comment logged, remove-label attempted and fails, no FIXED"
  "write-failure-followup-comment|case_write_failure_followup_comment|#355: follow-up arm, reject-comment: add-label no-plan attempted first (succeeds, the reorder), comment attempted and fails, no FIXED"
  "write-failure-followup-label|case_write_failure_followup_label|#355: follow-up arm, reject-edit: add-label attempted and fails, comment never runs (skip-the-rest and the reorder), no FIXED"
  "write-failure-continues-to-next-issue|case_write_failure_continues_to_next_issue|#355: the headline claim — a reject-comment-once failure on issue #7 still lets #8 and the follow-up #50 fully repair, reaches the follow-ups section, prints the Reminder and a summary counting 1"
  "write-failure-markers-inert-no-fix|case_write_failure_markers_inert_no_fix|#355: all three permanent reject markers present, no --fix: report-only performs no writes, so every marker is inert — no WARN, no summary line"
  "write-summary-absent-on-clean-run|case_write_summary_absent_on_clean_run|#355: control — a clean --fix run with no failed write never prints the summary line, FIXED still prints"
  "write-failure-gh-stderr-not-swallowed|case_write_failure_gh_stderr_not_swallowed|#355: the stub's own failure diagnostic is not swallowed by try_write's stdout-only redirect"
  "closed-sweep-removes-label|case_closed_sweep_removes_label|#370: closed issue, no claude/7-* PR open at all: --fix removes the label alone, no comment, no close"
  "closed-sweep-report-only|case_closed_sweep_report_only|#370: the same tree without --fix: STALE line, zero gh mutation calls"
  "closed-sweep-keeps-while-pr-open|case_closed_sweep_keeps_while_pr_open|#370: a lower-numbered OPEN claude/7-* PR beats a higher-numbered MERGED one: label kept, no write"
  "closed-sweep-keeps-while-pr-open-no-fix|case_closed_sweep_keeps_while_pr_open_no_fix|#370: the same tree without --fix: the ok line still prints (outside the FIX branch), no STALE"
  "closed-sweep-no-pr-still-removes|case_closed_sweep_no_pr_still_removes|#370: no claude/7-* PR exists at all: the closed issue is still swept under --fix"
  "closed-sweep-write-failure-continues|case_closed_sweep_write_failure_continues|#370: reject-edit-once on the first of two closed issues: one WARN, no FIXED for #7, #9 fully repaired, follow-ups section and Reminder still print, summary counts 1"
  "closed-sweep-query-failure-continues|case_closed_sweep_query_failure_continues|#370: reject-closed-list: exactly one WARN, zero writes, run still reaches follow-ups and the Reminder"
  "closed-sweep-query-malformed-continues|case_closed_sweep_query_malformed_continues|#370: malformed-closed-list: gh exits 0 with a non-JSON body — the same one WARN, zero writes, run still reaches follow-ups and the Reminder"
  "closed-sweep-independent-of-open-list|case_closed_sweep_independent_of_open_list|#370: reject-open-list: the OPEN hygiene query fails but the closed-issue sweep still repairs #7"
  "closed-sweep-skipped-when-pr-list-fails|case_closed_sweep_skipped_when_pr_list_fails|#370: PR list unavailable: the sweep prints its own skip WARN and makes zero writes"
  "closed-sweep-other-issue-pr-open-still-removes|case_closed_sweep_other_issue_pr_open_still_removes|#370 kickback round 2: an OPEN PR for a DIFFERENT issue (claude/70-x, claude/8-x) does not keep the label — the sweep is scoped to claude/<n>-* for that issue"
  "closed-sweep-none|case_closed_sweep_none|#370: no closed-pr-open.json at all: prints the empty-list line"
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
