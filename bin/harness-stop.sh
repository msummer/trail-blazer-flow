#!/usr/bin/env bash
#
# harness-stop.sh — read-only maintainer stop switch (issue #310, ADR 0001 decision 8): a signal
# settable on GitHub (so it works from the phone) or on the local machine, checked before each
# stage and before each merge. On stop: finish the stage in flight, dispatch nothing new, release
# the lock, and report — see skills/issue-cycle/SKILL.md's "Stop switch" section for the full
# procedure.
#
# TWO UNIONED ROUTES — any route set means stop:
#   route=github  any OPEN issue carrying the `harness-stop` label (STOP_LABEL=, below), read with
#                 one `gh issue list --label` call (one bounded 30s-backoff retry — the same
#                 RETRY_SLEEP-driven shape bin/harness-status.sh already uses for its own queries).
#                 An attempt counts as a READ only when `gh` exits 0 AND the printed body parses as
#                 a JSON array — a non-zero exit, an empty body, a body that fails to parse, and a
#                 body that parses but is not an array (an error object included) are all a FAILED
#                 attempt, retried identically once. Both attempts failing (in any combination of
#                 those ways) makes the GitHub route unreadable, `reason=github-query-unavailable`
#                 (kickback K1, #310: an earlier version of this script silently counted an
#                 unparsable body as "zero issues", which could mask a set label). Even a
#                 SUCCESSFUL attempt's own issue count is guarded the same way: if `jq 'length'`
#                 over that body ever prints anything other than a single plain number (kickback
#                 N1, #310 — e.g. more than one JSON document concatenated in the body, which
#                 `is_json_array` only inspects the LAST document of), the GitHub route is
#                 unreadable with the same reason, never a silent zero count — no retry is
#                 attempted for this failure, since the attempt itself already succeeded.
#   route=local   the file <git-common-dir>/trail-blazer/stop, a sibling of bin/harness-lock.sh's
#                 own lock directory (bin/harness-lock.sh:285-296's identical
#                 `git rev-parse --git-common-dir` -> `cd ... && pwd -P` resolution, so every
#                 worktree of one checkout shares it) — for an operator at the keyboard, or a
#                 GitHub outage. This script never creates or removes it: an operator sets it with
#                 `mkdir -p "<that dir>/trail-blazer" && touch "<that dir>/trail-blazer/stop"` and
#                 clears it with `rm`.
#
# READ-ONLY, ON PURPOSE — no set/clear subcommand at all: every bin/*.sh script is granted to the
# model as `Bash(<name>.sh:*)`, so a mutating subcommand here would hand the model a way to lift
# the maintainer's own veto. Gate assertion 4.49 additionally forbids any `--label`/`--add-label`/
# `--remove-label` argument naming the stop label anywhere in the harness's instruction or script
# surface, so no skill can tell an agent to remove it either. This script's own printed `clear=`
# remedy is built from $STOP_LABEL, never the literal, for the same reason (see the GitHub-route
# code below).
#
# STDOUT GRAMMAR: line 1 is exactly one of `stop=true` / `stop=false` / `stop=unknown`; then, per
# carrier (a set route), a `route=github issue=<n> url=<url>` or `route=local path=<abs path>`
# line immediately followed by its own `clear=<exact command>` line — GitHub carriers print before
# the local carrier when both are set; then at most one `reason=<slug>` line when the GitHub route
# could not be read — printed whether or not a determinate route is also set, since an
# unconfirmable veto is not a confirmed absence of one. The route=github/clear= pair above is
# printed for each issue-object element of a well-formed GitHub response and for the local file.
# A GitHub response array whose elements are not issue objects has not been characterised as a
# whole class: for a body of `[1,2]`, the script printed `stop=true` (exit 3), a `jq` error on
# stderr, and no carrier line; other non-issue element shapes were not characterised here, and
# every shape measured so far — `[1,2]` and `[null]` — halts (none yields `stop=false`).
# `reason=` slugs: `jq-not-found` (no `jq`
# on PATH — checked first; no `gh` call is even attempted, since `jq` is required to tell a real
# answer from an unreadable one, and there is nothing to parse without it), `gh-not-found` (no
# `gh` on PATH — no retry attempted in that case), or `github-query-unavailable` (either both
# attempts failed to return a readable JSON array body, or a successful attempt's own issue count
# could not be parsed as a single plain number — see the route=github bullet above for both
# classes).
#
# EXIT CODES: 0 = stop=false; 3 = stop=true (a determinate set route always wins over an unknown
# one); 4 = stop=unknown (neither route set, GitHub route unreadable); 2 = usage/environment error
# (an unknown argument, or not inside a git repository). `--help` prints usage on stdout and exits
# 0; an unknown argument prints usage on stderr and exits 2. Argument vocabulary is exactly ``
# (none) and `-h`/`--help` — there is no `set`/`clear` subcommand (see above).
#
# HONEST LIMITS:
#   - Freshness: GitHub's own list/search index can trail a label edit by several seconds
#     (measured on this repo, 2026-09-19: a direct `gh issue view` showed a just-added label
#     immediately, while `gh issue list --label`, `gh issue list --search`, and the REST issues
#     listing each missed the issue for a few seconds — first seen at +3s to +14s across two
#     edits). So `--label` (this script's own query) does NOT avoid that lag: a stop label applied
#     moments before a check may be missed by that one check. The local route has no such lag and
#     is the immediate route for an operator at the keyboard.
#   - Who may apply the label: GitHub's own "Repository roles for an organization" doc (fetched
#     2026-09-19) lists apply/dismiss-label permission under Triage, Write, Maintain, and Admin —
#     not Read — so gating on the label's presence alone matches platform permissions, the same way
#     `plan-approved`'s presence already does; this repo is owner+collaborators only, so a second
#     account was not used to test this independently.
#   - The `--limit 20` cap on the GitHub query: a repo with more than 20 open `harness-stop` issues
#     could miss one past the cap (one is already enough to stop a run).
#   - This halts dispatch; it cannot interrupt a subagent already running, and it cannot stop a
#     session that is not running the harness skills.
#
# MEASURED MUTANT TABLE (bin/harness-stop.sh mutated on a `tar --exclude=.git` scratch copy of
# this checkout, `bash dev/stop-tests.sh` re-run against that copy, then the copy re-set from a
# pristine backup and diff-verified after each row — see dev/stop-tests.sh's own header;
# RE-MEASURED 2026-09-21 (#310), `bash dev/stop-tests.sh` each time, 23 cases total):
#   (a) delete the local-route test (`[ -e "$stopfile" ] && local_set=true` -> `[ -e "$stopfile"
#       ] && true`): local-only, both-routes, local-set-github-unreadable, jq-missing-local-set,
#       worktree-shares-local fail (5 fail, 18 pass) — never-mutates does NOT fail: its stop-set
#       fixture also carries a labelled GitHub issue, whose route alone still yields exit 3;
#       github-multi-document does NOT fail either: its own fixture never sets the local file.
#   (b) delete the GitHub-route test (`if $local_set || [ "$github_n" -gt 0 ]` -> `if $local_set`):
#       github-one, github-many fail (2 fail, 21 pass) — both-routes does NOT fail: its own local
#       route alone still yields exit 3, and the github route/clear lines print from a separate,
#       untouched `if [ "$github_n" -gt 0 ]` check inside that branch.
#   (c) change the union to require both routes (`||` -> `&&`): github-one, github-many,
#       local-only, local-set-github-unreadable, jq-missing-local-set, worktree-shares-local fail
#       (6 fail, 17 pass) — jq-missing-local-set fails too: with jq missing, github_n stays 0, so
#       `true && [ 0 -gt 0 ]` is false and the local-only stop is lost.
#   (d) remove the retry (sleep only, no second attempt): github-unreadable,
#       github-unreadable-once, github-non-json, github-non-json-once, github-empty-body,
#       github-json-object fail (6 fail, 17 pass) — github-unreadable-once and github-non-json-once
#       fail because their own real, successful SECOND attempt never happens (the verdict itself
#       flips, from stop=false/exit 0 to stop=unknown/exit 4); the other four fixtures return the
#       identical (failing) body on both attempts, so their own verdict is unchanged and they fail
#       only via their own two-gh-calls assertion (proving a retry happened, not just a sleep).
#       github-multi-document does NOT fail: its own attempt already succeeds on the first try
#       (is_json_array is true), so no retry is ever attempted regardless of this mutant.
#   (e) make the unavailable branch exit 0 instead of 4: github-unreadable, gh-missing,
#       github-non-json, github-empty-body, github-json-object, jq-missing-with-issue,
#       github-multi-document fail (7 fail, 16 pass) — github-non-json-once does NOT fail: its
#       second attempt already succeeds, so the unavailable branch is never reached.
#   (f) make a set route exit 0 instead of 3: github-one, github-many, local-only, both-routes,
#       local-set-github-unreadable, jq-missing-local-set, worktree-shares-local, never-mutates
#       fail (8 fail, 15 pass) — github-multi-document does NOT fail: it never sets a determinate
#       route, so it never reaches this branch at all.
#   (g) drop `--state open` from the query: state-open-explicit fails (1 fail, 22 pass) — added by
#       kickback K2 after the orchestrator's own measurement (`gh issue list --help` on gh 2.97.0,
#       2026-07-31: `-s, --state string   Filter by state: {open|closed|all} (default "open")`)
#       showed no fixture before it could distinguish the flag's absence on that gh version; this
#       case's own assertion on the logged call, not gh's default, is what makes this row
#       measurable now.
#   (h) drop the `clear=` lines: github-one, github-many, local-only, both-routes fail (4 fail, 19
#       pass) — local-set-github-unreadable and worktree-shares-local do NOT fail: neither
#       asserts the `clear=` line, only `route=local path=...`.
#   (i) (approval addendum) add an unconditional `gh issue edit 1` call that removes the stop
#       label, right after `stopfile=` is computed, spelling the label argument as a literal
#       rather than via $STOP_LABEL (deliberately, to also probe gate clause 4.49(b) — see below):
#       never-mutates fails (1 fail, 22 pass), via its own gh-call-log check ("gh call log ...
#       contained a non-issue-list call") — not gate clause 4.49(b), since `bash dev/stop-tests.sh`
#       never runs the gate. Re-measured with the SAME mutant in place: `bash dev/selfcheck.sh`
#       (with assertion 4.49 present) ALSO fails, naming this file at the line the mutant itself
#       inserted — the line immediately after `stopfile=` is computed (75 pass, 1 fail out of 76)
#       — the gate catching this file's own now-literal argument too, which is expected and
#       recorded, not what this row's own `dev/stop-tests.sh` measurement is about. (No line
#       number is quoted here: any edit above this point in the file, including an edit to this
#       table, would move it.)
#   (j) (#310 kickback K1) remove the is-it-a-JSON-array test (`attempt_list_stop`'s own
#       `is_json_array "$out"` check deleted, so any zero-exit `gh` call counts as a read
#       regardless of body): github-non-json, github-non-json-once, github-empty-body,
#       github-json-object fail (4 fail, 19 pass) — github-json-object's own failure is a `jq`
#       type error on stderr plus a wrong `stop=true`/exit 3 (`jq 'length'` on a JSON OBJECT
#       counts its KEYS, reproducing the exact pre-fix defect this kickback closes). The same four
#       cases also join row (d)'s failing set (both mutants remove the array-shape guard from a
#       different angle: (d) via losing the second attempt entirely, (j) via never checking the
#       shape at all) — a case joining more than one row's failing set is expected, not a defect.
#       github-multi-document does NOT fail: with the array-shape check gone, its first attempt
#       trivially "succeeds" on the raw two-document body, but the length step's own guard
#       (kickback N1, immediately below) still catches the resulting multi-line count and reaches
#       the identical stop=unknown/exit 4 verdict — this row cannot discriminate that guard; row
#       (l) does.
#   (k) (#310 kickback K1) let a missing jq fall through to a zero count (the `gh_reason=
#       "jq-not-found"` assignment deleted, leaving the branch's own `command -v jq` test and its
#       `warn:` line intact but not recording why): jq-missing-with-issue, jq-missing-local-set
#       fail (2 fail, 21 pass) — both fail only on their own now-missing `reason=jq-not-found`
#       line; the verdict itself is unchanged (jq-missing-with-issue stays `stop=unknown`/exit 4;
#       jq-missing-local-set stays `stop=true`/exit 3 with its `route=local` line intact), because
#       the length step's own N1 guard below — untouched by this mutant — still catches the
#       unparseable `jq 'length'` result (jq itself is still missing) and reports
#       `reason=github-query-unavailable` instead, with a "jq: command not found" line on stderr
#       from that later `jq 'length'` call. So this mutant no longer reproduces the pre-fix
#       `stop=false` defect; only the `reason=` slug is wrong.
#   (l) (#310 kickback N1) restore the length step's OWN pre-N1 fallback (the `gh_reason=
#       "github-query-unavailable"` assignment and its `warn:` line deleted from the length `case`,
#       leaving `github_n=0` as its only action on a non-numeric or multi-line `jq 'length'`
#       result): github-multi-document fails (1 fail, 22 pass) — its two-concatenated-JSON-array
#       body still passes `is_json_array` (which inspects only the LAST of the two documents), so
#       this is the one mutant that isolates the length step's own guard from is_json_array's
#       (contrast row (j), which removes is_json_array instead and does NOT fail this case, since
#       this guard alone still catches it).
#
# Reads: one `git rev-parse --git-common-dir` call, the local stop file's existence test, up to two
# `gh issue list` calls (a second happens only as the one retry, with one intervening `sleep`), and
# `jq` to parse the GitHub response and format the route/clear lines; `cat` runs only inside
# `usage()` (reached via `--help` or an unknown argument). Never writes, deletes, or executes
# anything else. Requires: git; jq (checked BEFORE gh — its absence makes the GitHub route
# unreadable with reason=jq-not-found and skips the gh call entirely, while the local route still
# works without jq); gh (only for the GitHub route — its absence degrades to a local-only check
# with reason=gh-not-found). The `reason=` line, whichever slug, prints whenever the GitHub route
# could not be read, regardless of whether the local route is also set (see the STDOUT GRAMMAR
# section above) — not only "when neither route is set". Run from anywhere inside a git checkout.
set -uo pipefail

STOP_LABEL="harness-stop"
RETRY_SLEEP=30

# usage's set/clear example line is built from $STOP_LABEL at runtime (printf, never a literal in
# this file's own source), for the identical reason the GitHub-route clear= remedy below is: gate
# assertion 4.49 clause (b) scans bin/*.sh (this file included) for a --label/--add-label/
# --remove-label argument naming the stop label literally, and this help text would otherwise be
# exactly that shape.
usage() {
  cat <<'EOF'
usage: harness-stop.sh
       harness-stop.sh --help

Read-only maintainer stop switch (issue #310). No subcommand, no arguments: running it checks
both routes (GitHub label, local file) and reports. There is no set/clear subcommand, on purpose
(see the script's own header) — set the GitHub route with:
EOF
  printf '  gh issue edit <n> --add-label %s\n' "$STOP_LABEL"
  printf '(or the mobile app); clear it with --remove-label %s.\n' "$STOP_LABEL"
  cat <<'EOF'
Set the local route with
`mkdir -p "<git-common-dir>/trail-blazer" && touch "<that dir>/stop"` (resolve <git-common-dir>
with `git rev-parse --git-common-dir`), clear it with `rm`.

Exit codes: 0 = stop=false, 3 = stop=true, 4 = stop=unknown (GitHub route unreadable and neither
route set), 2 = usage/environment error (unknown argument, or not inside a git repository).
EOF
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
fi

common="$(git rev-parse --git-common-dir 2>/dev/null)"
if [ -z "$common" ]; then
  echo "harness-stop.sh: not inside a git repository (git rev-parse --git-common-dir failed)" >&2
  exit 2
fi
common_abs="$(cd "$common" 2>/dev/null && pwd -P)"
if [ -z "$common_abs" ]; then
  echo "harness-stop.sh: could not resolve the git common dir to an absolute path: $common" >&2
  exit 2
fi
stopfile="$common_abs/trail-blazer/stop"

local_set=false
[ -e "$stopfile" ] && local_set=true

# list_stop — last command is the `gh` call itself, no pipe inside, so a retry can re-run just the
# call (bin/harness-status.sh:136-166's list_* shape).
list_stop() {
  gh issue list --label "$STOP_LABEL" --state open --json number,title,url --limit 20
}

# is_json_array BODY — true only when BODY parses as a JSON array. Guards against a zero-exit `gh`
# call whose body is an error page, empty, or a JSON object/scalar (#310 kickback K1: an earlier
# version fed any zero-exit body straight to `jq 'length'` and let a parse failure or an object's
# own key count collapse silently to "zero issues"). HONEST LIMIT: a BODY consisting of more than
# one JSON document concatenated together (`jq` reads it as a stream) is judged here only by its
# LAST document — `jq -e`'s exit status follows the last value printed — so this check alone would
# call a two-document body "an array" even though `jq 'length'` below then prints one count per
# document. The length step below (kickback N1, #310) has its own guard for exactly that case,
# rather than relying on this function to catch it.
is_json_array() {
  printf '%s' "$1" | jq -e 'type == "array"' >/dev/null 2>&1
}

# attempt_list_stop — one `list_stop` call. Success (sets $out to the validated array body,
# returns 0) requires BOTH `gh` exiting 0 AND the body being a JSON array; anything else is a
# FAILED attempt (sets $attempt_fail_reason to a human-readable phrase, returns 1) — a non-zero
# `gh` exit and a zero-exit-but-unparsable/wrong-shape body are both failed attempts, retried
# identically (#310 kickback K1).
attempt_list_stop() {
  if ! out=$(list_stop); then
    attempt_fail_reason="the call failed"
    return 1
  fi
  if ! is_json_array "$out"; then
    attempt_fail_reason="the response was not a JSON array"
    return 1
  fi
  return 0
}

gh_reason=""
issues_json="[]"
if ! command -v jq >/dev/null 2>&1; then
  echo "warn: jq not found on PATH — GitHub route unreadable this run (no gh call attempted)" >&2
  gh_reason="jq-not-found"
elif ! command -v gh >/dev/null 2>&1; then
  echo "warn: gh not found on PATH — GitHub route unreadable this run" >&2
  gh_reason="gh-not-found"
else
  if attempt_list_stop; then
    issues_json="$out"
  else
    first_fail_reason="$attempt_fail_reason"
    sleep "$RETRY_SLEEP" || true
    if attempt_list_stop; then
      echo "warn: $STOP_LABEL query failed once ($first_fail_reason) — retried after ${RETRY_SLEEP}s and succeeded (transient API blip absorbed)" >&2
      issues_json="$out"
    else
      echo "warn: could not list $STOP_LABEL issues after one retry (first attempt: $first_fail_reason; retry: $attempt_fail_reason) — GitHub route unreadable this run" >&2
      gh_reason="github-query-unavailable"
    fi
  fi
fi

github_n=0
if [ -z "$gh_reason" ]; then
  raw_n="$(printf '%s' "$issues_json" | jq 'length')"
  case "$raw_n" in
    ''|*[!0-9]*)
      echo "warn: could not count the $STOP_LABEL query response (jq 'length' printed something other than a single plain number) — GitHub route unreadable this run" >&2
      gh_reason="github-query-unavailable"
      ;;
    *) github_n="$raw_n" ;;
  esac
fi

if $local_set || [ "$github_n" -gt 0 ]; then
  echo "stop=true"
  if [ "$github_n" -gt 0 ]; then
    printf '%s' "$issues_json" | jq -r --arg label "$STOP_LABEL" \
      '.[] | "route=github issue=" + (.number|tostring) + " url=" + .url + "\nclear=gh issue edit " + (.number|tostring) + " --remove-label " + $label'
  fi
  if $local_set; then
    echo "route=local path=$stopfile"
    echo "clear=rm $stopfile"
  fi
  [ -n "$gh_reason" ] && echo "reason=$gh_reason"
  exit 3
elif [ -n "$gh_reason" ]; then
  echo "stop=unknown"
  echo "reason=$gh_reason"
  exit 4
else
  echo "stop=false"
  exit 0
fi
