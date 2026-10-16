#!/usr/bin/env bash
#
# merge-floor.sh — the issue-cycle merge pass's mechanical hard floor for ONE pull request (#550),
# as a read-only, fail-closed script. skills/issue-cycle/SKILL.md step 3 calls it once per PR and
# keeps only what needs judgment: activation, the repo's own policy, the ledger cross-check, the
# content reviews, and merge guards (b)-(e).
#
# USAGE: merge-floor.sh <pr> [--allow-no-ci] [--dependabot]   (flags in any order; -h/--help)
#   <pr>           the pull request number, digits only.
#   --allow-no-ci  a PR whose head commit has no checks at all passes the CI check. Passed only when
#                  a declared "Merge autonomy policy" opts a no-CI repo in; this script never reads
#                  policy prose.
#   --dependabot   Dependabot mode: skips the harness-only checks (provenance, archive, binding,
#                  post-approval, lessons carve-out) and refuses a claude/ head branch.
#
# EXIT CODES: 0 = floor=pass; 1 = floor=hold; 3 = floor=stop; 2 = usage/environment error (a bad
# argument, jq/gh/git missing, not inside a git repository) with a stderr reason and no stdout.
# Any other status is a crash, and a crash is a hold.
#
# STDOUT, printed once at the end (line 1 is always the verdict):
#   floor=pass|hold|stop
#   fail=<check> <reason>      one line per failed check, in check order; none on a pass
#   evidence, in this fixed order, each line only when its value was obtained: pr=, mode=,
#     head-branch=, issue=, default-branch=, base-ref=, base-tip=, head-oid=, merge-state=,
#     ancestry-rc=, ci=, check| <name,state,bucket as a JSON array>, verifier-line=, archive-url=,
#     approved-at=, approved-by=, the governance:/changed: lines governance-paths.sh printed,
#     governance=<none|lessons-only|hold>, lessons-files=, added| <LESSONS.md added line>,
#     stop-check=install-fault exit=<rc>
# A pass needs no fail= line AND every check its mode requires recorded a pass, so a skipped or
# forgotten check can never read as a pass. Untrusted text appears only behind a fixed prefix, and
# is cleaned per line type: fail=, governance:, changed: and the key= evidence lines that carry it
# (head-branch=, verifier-line=, approved-by=, ...) have every control character, TAB included,
# replaced by "?"; a check| line is one JSON array, so the controls are JSON-escaped; an added| line
# has every control character except TAB replaced by "?". The governance-paths.sh verdict line is
# never echoed, only re-emitted as governance=. Untrusted values reach jq only through --arg, never
# spliced into program text; nothing is eval'd.
# floor=stop (exit 3) prints harness-stop.sh's stdout verbatim after line 1 and nothing else.
#
# CHECKS, in this order. A check whose prerequisite failed is skipped (the prerequisite's own fail=
# line is the reason); every independent check still runs, so one run reports every hold.
#   stop           harness-stop.sh first, before any gh or git remote read. Exit 0 passes; exit 2 or
#                  127 (an install fault) passes and adds stop-check=install-fault; any other
#                  status (3, 4, 126, ...) is floor=stop. harness-stop.sh retries its own query.
#   default branch gh repo view --json defaultBranchRef (retried)                  fail=read
#   fetch          git fetch origin (retried; never fetches pull refs)             fail=fetch
#   rail           git rev-parse origin/<default> -> base-tip=                     fail=rail
#   PR read        one gh pr view (retried): head branch/OID, base, body, merge state  fail=read
#   branch         the head branch is claude/<n>-... (<n> never taken from body prose)  fail=branch
#   provenance     the PR body carries the verifier's outcome=pass status line for issue <n> and
#                  not an outcome=fail one                                         fail=provenance
#   archive        the newest verifier-verdict comment keyed to this head branch exists, its status
#                  line starts as expected, and the PR body contains it (retried read) fail=archive
#   binding        find-implementation-work.sh --issue <n> (retried): covers_plan is true and the PR
#                  body contains a binding line of an approved_at_history entry, newest first
#                                                                                   fail=binding
#   post-approval  every trusted_post_plan entry is covered_by_approval == true, read from the same
#                  final discovery run as binding                                   fail=post-approval
#   ci             gh pr checks <pr> --json name,state,bucket (retried): fail/cancel is failing;
#                  else pending; else green iff every bucket is pass or skipping and at least one is
#                  pass; any other bucket value, or all-skipped, holds. Exit 1 with "no checks
#                  reported on the ..." is no-checks: a hold unless --allow-no-ci   fail=ci
#   ancestry       git merge-base --is-ancestor <base-tip> <head-oid>; any non-zero exit holds, and
#                  ancestry-rc= records which                                       fail=behind
#   merge-state    mergeStateStatus DIRTY or BLOCKED holds                          fail=merge-state
#   governance     governance-paths.sh <base-tip> <head-oid> (not retried)          fail=governance
#   lessons-files  harness mode, governance=lessons-only: the PR file list is a LESSONS.md append
#   lessons-eof    ... and its diff is an end-of-file append with no "<!--"  fail=lessons-files/-eof
#   base           the PR's base branch is the default branch                       fail=base
# The skill still reviews what a script cannot decide: the changed: paths on governance=none, the
# added| lines of a lessons carve-out, the ledger cross-check, and the repo's policy.
#
# RETRY RULE: each read marked "retried" is attempted at most twice with one sleep 30 between. An
# attempt is the call PLUS its shape validation; a failed attempt's output is discarded, so every
# value comes from one attempt. A determinate answer (CI pending, failing or no checks,
# covers_plan false, no archive, an archive mismatch) is read once and never retried. Not retried:
# harness-stop.sh, git rev-parse, git merge-base, governance-paths.sh, and the two lessons reads.
#
# READ-ONLY: the only gh calls are pr view, pr checks, issue view and repo view; the only git calls
# are rev-parse, fetch origin (the remote-tracking update the floor always made), merge-base
# --is-ancestor and diff. It writes no file and never merges or edits a label or comment: the merge
# stays the model-issued, head-pinned call in the skill's guard (b), gated by the human's deny.
#
# SIBLINGS (harness-stop.sh, find-implementation-work.sh, governance-paths.sh) are resolved from
# this script's own directory only, never by PATH lookup, so a planted copy earlier on PATH cannot
# forge a pass.
#
# WALL CLOCK: worst case is about seven 30-second backoffs (default branch, fetch, PR read, archive,
# discovery, checks, plus harness-stop.sh's own), longer than a default Bash timeout. A killed run is
# a hold in the skill, so this fails closed.
#
# HONEST LIMITS:
#   - No-checks is recognised by the stem NO_CHECKS_STEM on exit 1 (measured on gh 2.102.0). If gh
#     rewords it, an --allow-no-ci repo holds every PR: fail closed, and loud.
#   - The end-of-file check leaves GIT_DIFF_OPTS alone. A width-0 value renders no leading context
#     line, so even a genuine append holds.
#   - A fork PR reusing a harness branch name is held only because git fetch origin does not fetch
#     fork commits, so the ancestry check errors. Keep the fetch plain.
set -uo pipefail
export LC_ALL=C

RETRY_SLEEP=30
NO_CHECKS_STEM='no checks reported on the'
# The jq programs below are single-quoted one-liners so dev/selfcheck.sh can extract and run them
# offline (assertions 5.5-5.9, 5.15). Untrusted values arrive as --arg n/outcome/branch/needle.
PROVENANCE_JQ='(.body // "") | contains("<!-- harness-status: stage=verifier issue=" + $n + " outcome=" + $outcome + " ")'
ARCHIVE_JQ='[.comments[] | select((.body | contains("<!-- verifier-verdict -->")) and (.body | contains("<!-- verifier-verdict-branch: " + $branch + " -->")))] | sort_by(.createdAt) | last | ((.url // "none"), ((.body // "") | split("\n") | map(select(startswith("<!-- harness-status:"))) | last // "none"))'
BODY_CONTAINS_JQ='(.body // "") | contains($needle)'
LESSONS_FILES_JQ='[.files[] | select(.path | ascii_downcase | startswith(".claude/"))] as $c | if (.files | length) != .changedFiles then "incomplete" elif ([.files[] | select(.changeType == "RENAMED")] | length) > 0 then "renamed" elif ($c | length) != 1 or $c[0].path != ".claude/LESSONS.md" then "not-lessons-only" elif (["ADDED","MODIFIED"] | index($c[0].changeType)) == null or $c[0].deletions != 0 or $c[0].additions < 1 then "not-add-only" elif $c[0].additions > 40 then "too-large" else "lessons-append" end'
CI_JQ='if type != "array" or length == 0 or any(.[]; type != "object") then "invalid" else (map(.bucket)) as $b | if any($b[]; . == "fail" or . == "cancel") then "failing" elif any($b[]; . == "pending") then "pending" elif all($b[]; . == "pass" or . == "skipping") then (if any($b[]; . == "pass") then "green" else "skipped" end) else "failing" end end'
POST_APPROVAL_JQ='.plan_selection[0].trusted_post_plan[] | select(.covered_by_approval != true) | (if (.url | type) == "string" and (.url | length) > 0 then .url else (((.author // "unknown") | tostring) + " " + ((.createdAt // "unknown") | tostring)) end)'

script_dir="$(cd "$(dirname "$0")" && pwd)"
[ -n "$script_dir" ] || { echo "merge-floor.sh: could not resolve its own directory" >&2; exit 2; }
usage_line="usage: merge-floor.sh <pr> [--allow-no-ci] [--dependabot]"

die_usage() {
  echo "merge-floor.sh: $1" >&2
  echo "$usage_line" >&2
  exit 2
}

pr=""
allow_no_ci=false
dependabot=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      echo "$usage_line"
      echo "Read-only merge floor for one PR. Exit 0 = floor=pass, 1 = floor=hold, 3 = floor=stop,"
      echo "2 = usage/environment error. See this script's header for the checks and the output."
      exit 0
      ;;
    --allow-no-ci) allow_no_ci=true ;;
    --dependabot) dependabot=true ;;
    -*) die_usage "unknown option: $1" ;;
    *)
      [ -z "$pr" ] || die_usage "more than one pull request number"
      pr="$1"
      ;;
  esac
  shift
done
case "$pr" in
  '') die_usage "missing pull request number" ;;
  *[!0-9]*) die_usage "pull request number must be digits only, got '$pr'" ;;
esac

for tool in jq gh git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "merge-floor.sh: $tool not found on PATH" >&2; exit 2; }
done
toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$toplevel" ] || { echo "merge-floor.sh: not inside a git repository" >&2; exit 2; }
cd "$toplevel" 2>/dev/null || { echo "merge-floor.sh: could not cd to the repo toplevel: $toplevel" >&2; exit 2; }

# ---- helpers -------------------------------------------------------------------------------------

FAILS=""
PASSED=" "
add_fail() { FAILS="${FAILS}fail=$1 $2"$'\n'; }
add_pass() { PASSED="${PASSED}$1 "; }
has_passed() { case "$PASSED" in *" $1 "*) return 0 ;; esac; return 1; }

# c VALUE — VALUE with every control character (newline and CR included) replaced by "?", so an
# untrusted value cannot start a line of its own.
c() { printf '%s' "$1" | tr '[:cntrl:]' '?'; }

is_hex() {
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
  case "${#1}" in 40|64) return 0 ;; esac
  return 1
}

# retry_read ATTEMPT_FN — the attempt (the call plus its shape validation) returns 0 on success and
# sets its result variables only then; on failure it sets ATTEMPT_ERR to a fixed phrase. One retry
# after RETRY_SLEEP seconds.
ATTEMPT_ERR=""
retry_read() {
  ATTEMPT_ERR=""
  "$1" && return 0
  sleep "$RETRY_SLEEP" || true
  ATTEMPT_ERR=""
  "$1"
}

attempt_default() {
  local out name
  if ! out="$(gh repo view --json defaultBranchRef)"; then ATTEMPT_ERR="gh repo view failed"; return 1; fi
  name="$(printf '%s' "$out" | jq -r 'if (.defaultBranchRef.name | type) == "string" then .defaultBranchRef.name else "" end' 2>/dev/null | tr -d '\r')"
  case "$name" in
    ''|*[[:space:]]*|*[[:cntrl:]]*) ATTEMPT_ERR="no usable default branch name"; return 1 ;;
  esac
  default_branch="$name"
  return 0
}

attempt_fetch() {
  git fetch origin >/dev/null 2>&1 || { ATTEMPT_ERR="git fetch origin failed"; return 1; }
  return 0
}

attempt_pr() {
  local out oid
  if ! out="$(gh pr view "$pr" --json headRefName,baseRefName,body,headRefOid,mergeStateStatus)"; then
    ATTEMPT_ERR="gh pr view failed"; return 1
  fi
  if ! printf '%s' "$out" | jq -e 'type == "object" and (.headRefName | type) == "string" and (.baseRefName | type) == "string" and (.mergeStateStatus | type) == "string" and ((.body | type) == "string" or .body == null) and (.headRefOid | type) == "string"' >/dev/null 2>&1; then
    ATTEMPT_ERR="unexpected response shape"; return 1
  fi
  oid="$(printf '%s' "$out" | jq -r '.headRefOid' 2>/dev/null | tr -d '\r')"
  is_hex "$oid" || { ATTEMPT_ERR="headRefOid is not a 40- or 64-character hex id"; return 1; }
  pr_json="$out"
  head_oid="$oid"
  head_branch="$(printf '%s' "$out" | jq -r '.headRefName' | tr -d '\r')"
  base_ref="$(printf '%s' "$out" | jq -r '.baseRefName' | tr -d '\r')"
  merge_state="$(printf '%s' "$out" | jq -r '.mergeStateStatus' | tr -d '\r')"
  return 0
}

attempt_archive() {
  local out res
  if ! out="$(gh issue view "$issue_n" --json comments)"; then ATTEMPT_ERR="gh issue view failed"; return 1; fi
  if ! printf '%s' "$out" | jq -e 'type == "object" and (.comments | type) == "array"' >/dev/null 2>&1; then
    ATTEMPT_ERR="unexpected response shape"; return 1
  fi
  if ! res="$(printf '%s' "$out" | jq -r --arg branch "$head_branch" "$ARCHIVE_JQ" 2>/dev/null)"; then
    ATTEMPT_ERR="the archive program failed"; return 1
  fi
  res="$(printf '%s' "$res" | tr -d '\r')"
  if [ "$(printf '%s\n' "$res" | wc -l | tr -d ' ')" != "2" ]; then ATTEMPT_ERR="the archive program printed an unexpected shape"; return 1; fi
  archive_url="$(printf '%s\n' "$res" | sed -n '1p')"
  archive_line="$(printf '%s\n' "$res" | sed -n '2p')"
  return 0
}

# attempt_binding — impl_json keeps the LAST run's output whenever it carried plan_selection[0], so
# the binding and post-approval checks read one run; a pass needs covers_plan to be a boolean.
attempt_binding() {
  local out rc cov reason
  impl_json=""
  out="$("$script_dir/find-implementation-work.sh" --issue "$issue_n")"; rc=$?
  if [ "$rc" -ne 0 ]; then ATTEMPT_ERR="discovery exited $rc"; return 1; fi
  if ! printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1; then ATTEMPT_ERR="discovery printed no JSON object"; return 1; fi
  if ! printf '%s' "$out" | jq -e '(.plan_selection | type) == "array" and (.plan_selection[0] | type) == "object"' >/dev/null 2>&1; then
    ATTEMPT_ERR="no plan_selection entry"; return 1
  fi
  impl_json="$out"
  cov="$(printf '%s' "$out" | jq -r '.plan_selection[0].approval.covers_plan | if type == "boolean" then tostring else "unknown" end' 2>/dev/null)"
  case "$cov" in
    true|false) impl_cov="$cov"; return 0 ;;
  esac
  reason="$(printf '%s' "$out" | jq -r '.plan_selection[0].approval.reason | if type == "string" then . else "" end' 2>/dev/null | tr -d '\r')"
  ATTEMPT_ERR="${reason:-covers_plan unknown}"
  return 1
}

# attempt_ci — success means gh answered; ci_kind is green|pending|failing|skipped|none. A determinate
# answer is a success, so it is never retried.
attempt_ci() {
  local out rc kind
  out="$(gh pr checks "$pr" --json name,state,bucket 2>&1)"; rc=$?
  out="$(printf '%s' "$out" | tr -d '\r')"
  if [ "$rc" -eq 0 ]; then
    kind="$(printf '%s' "$out" | jq -r "$CI_JQ" 2>/dev/null)"
    case "$kind" in
      green|pending|failing|skipped)
        ci_kind="$kind"
        ci_lines="$(printf '%s' "$out" | jq -r '.[] | "check| " + ([.name, .state, .bucket] | @json)' 2>/dev/null)"
        return 0
        ;;
    esac
    ATTEMPT_ERR="gh pr checks printed no usable check list"; return 1
  fi
  if [ "$rc" -eq 1 ]; then
    case "$out" in
      "$NO_CHECKS_STEM"*) ci_kind="none"; ci_lines=""; return 0 ;;
    esac
  fi
  ATTEMPT_ERR="gh pr checks exited $rc"; return 1
}

# lessons_eof — the end-of-file check over the LESSONS.md diff, one awk state machine. Lines before
# the first @@ are headers, every later line is hunk body. Prints "ok" plus each added line as
# "added| <line>", or "fail <rule>"; the caller reads the first line.
lessons_eof() {
  local d rc
  d="$(git diff --no-color --no-ext-diff --no-textconv -U3 "$base_tip" "$head_oid" -- .claude/LESSONS.md)"; rc=$?
  if [ "$rc" -ne 0 ]; then printf 'fail git diff exited %s\n' "$rc"; return 0; fi
  printf '%s\n' "$d" | awk '
    function bail(msg) { bad = msg; exit 1 }
    BEGIN { inhunk = 0; newfile = 0; lead = 0; plus = 0; seenplus = 0; after = 0; bad = "" }
    !inhunk {
      if ($0 ~ /^@@ /) {
        if ($0 !~ /^@@ -[0-9]+(,[0-9]+)? [+][0-9]+(,[0-9]+)? @@/) bail("malformed hunk header")
        o = $2; n = $3; sub(/^-/, "", o); sub(/^[+]/, "", n)
        k = split(o, op, ","); a = op[1] + 0; b = (k > 1) ? op[2] + 0 : 1
        k = split(n, np, ","); cc = np[1] + 0; d = (k > 1) ? np[2] + 0 : 1
        inhunk = 1; next
      }
      if ($0 == "new file mode 100644") { newfile = 1; next }
      if ($0 ~ /^new file mode /) bail("new file mode other than 100644")
      if ($0 ~ /^(old mode|new mode|deleted file mode) /) bail("mode change or deletion")
      if ($0 ~ /^index / && $NF == "120000") bail("symlink")
      next
    }
    {
      if ($0 ~ /^\\/) next
      ch = substr($0, 1, 1)
      if ($0 == "" || ch == " ") {
        if (newfile) bail("context line in a new-file hunk")
        if (seenplus) after++; else lead++
        next
      }
      if (ch == "+") {
        plus++; seenplus = 1; after = 0
        if (index($0, "<!--") > 0) bail("an added line contains <!--")
        added[plus] = "added| " substr($0, 2)
        next
      }
      if (ch == "-") bail("a removed line")
      bail("an unexpected line in the hunk")
    }
    END {
      if (bad == "") {
        if (!inhunk) bad = "no hunk"
        else if (plus == 0) bad = "no added line"
        else if (newfile) {
          if (!(a == 0 && b == 0 && cc == 1 && d == plus)) bad = "new-file hunk header does not match the added lines"
        } else if (lead < 1) bad = "no context line before the first added line"
        else if (after > 0) bad = "context line after the last added line"
        else if (b != lead) bad = "hunk old count does not match the leading context"
        else if (d != b + plus) bad = "hunk new count does not match the added lines"
      }
      if (bad != "") { print "fail " bad; exit 0 }
      print "ok"
      for (i = 1; i <= plus; i++) print added[i]
    }'
}

# ---- 1. stop -------------------------------------------------------------------------------------

stop_check=""
stop_out="$("$script_dir/harness-stop.sh")"; stop_rc=$?
case "$stop_rc" in
  0) add_pass stop ;;
  2|127) add_pass stop; stop_check="install-fault exit=$stop_rc" ;;
  *)
    printf 'floor=stop\n'
    [ -z "$stop_out" ] || printf '%s\n' "$stop_out"
    exit 3
    ;;
esac

# ---- 2-5. default branch, fetch, rail, PR read ---------------------------------------------------

default_branch=""
default_ok=false
if retry_read attempt_default; then
  default_ok=true
else
  add_fail read "default-branch: could not read the default branch after one retry ($ATTEMPT_ERR)"
fi

fetch_ok=false
if retry_read attempt_fetch; then
  fetch_ok=true
  add_pass fetch
else
  add_fail fetch "could not fetch origin — not comparing against a stale ${default_branch:-default branch} tip"
fi

base_tip=""
rail_ok=false
if $default_ok && $fetch_ok; then
  base_tip="$(git rev-parse "origin/$default_branch" 2>/dev/null)" || base_tip=""
  if is_hex "$base_tip"; then
    rail_ok=true
    add_pass rail
  else
    base_tip=""
    add_fail rail "could not resolve origin/$(c "$default_branch")"
  fi
fi

pr_json=""
head_oid=""
head_branch=""
base_ref=""
merge_state=""
pr_ok=false
if retry_read attempt_pr; then
  pr_ok=true
else
  add_fail read "pr: could not read pull request #$pr after one retry ($ATTEMPT_ERR)"
fi

# ---- 6-10. branch, provenance, archive, binding, post-approval -----------------------------------

issue_n=""
harness_ok=false
if $pr_ok; then
  if $dependabot; then
    case "$head_branch" in
      claude/*) add_fail branch "--dependabot given for the claude/ head branch $(c "$head_branch") — not a Dependabot PR" ;;
      *) add_pass branch ;;
    esac
  else
    rest="${head_branch#claude/}"
    n="${rest%%-*}"
    case "$head_branch" in
      claude/*-*)
        case "$n" in
          ''|*[!0-9]*) n="" ;;
        esac
        ;;
      *) n="" ;;
    esac
    if [ -n "$n" ]; then
      issue_n="$n"
      harness_ok=true
      add_pass branch
    else
      add_fail branch "head branch $(c "$head_branch") is not claude/<n>-… — not a standard-flow PR"
    fi
  fi
fi

archive_url=""
archive_line=""
approved_at=""
approved_by=""
impl_json=""
impl_cov=""
if $harness_ok; then
  vp_pass="$(printf '%s' "$pr_json" | jq -r --arg n "$issue_n" --arg outcome pass "$PROVENANCE_JQ" 2>/dev/null | tr -d '\r')"
  vp_fail="$(printf '%s' "$pr_json" | jq -r --arg n "$issue_n" --arg outcome fail "$PROVENANCE_JQ" 2>/dev/null | tr -d '\r')"
  if [ "$vp_pass" != "true" ]; then
    add_fail provenance "PR body lacks the verifier's outcome=pass status line for issue $issue_n"
  elif [ "$vp_fail" != "false" ]; then
    add_fail provenance "PR body carries an outcome=fail verifier status line for issue $issue_n"
  else
    add_pass provenance
  fi

  if retry_read attempt_archive; then
    case "$archive_line" in
      "<!-- harness-status: stage=verifier issue=$issue_n outcome=pass "*)
        m="$(printf '%s' "$pr_json" | jq -r --arg needle "$archive_line" "$BODY_CONTAINS_JQ" 2>/dev/null | tr -d '\r')"
        if [ "$m" = "true" ]; then
          add_pass archive
        else
          add_fail archive "the PR body's verifier line does not match the verdict archived for head branch $(c "$head_branch")"
        fi
        ;;
      *)
        archive_url=""
        archive_line=""
        add_fail archive "no archived verifier verdict for head branch $(c "$head_branch")"
        ;;
    esac
  else
    add_fail read "archive: could not read the verifier-verdict archive for issue $issue_n after one retry ($ATTEMPT_ERR)"
  fi

  if retry_read attempt_binding; then
    if [ "$impl_cov" = "true" ]; then
      hist_n="$(printf '%s' "$impl_json" | jq -r '.plan_selection[0].approval.approved_at_history | if type == "array" then length else 0 end' 2>/dev/null)"
      case "$hist_n" in ''|*[!0-9]*) hist_n=0 ;; esac
      i=0
      matched=false
      while [ "$i" -lt "$hist_n" ]; do
        bl="$(printf '%s' "$impl_json" | jq -r --argjson i "$i" '.plan_selection[0].approval.approved_at_history[$i].binding_line | if type == "string" and length > 0 then . else "" end' 2>/dev/null)"
        if [ -n "$bl" ]; then
          m="$(printf '%s' "$pr_json" | jq -r --arg needle "$bl" "$BODY_CONTAINS_JQ" 2>/dev/null | tr -d '\r')"
          if [ "$m" = "true" ]; then
            approved_at="$(printf '%s' "$impl_json" | jq -r --argjson i "$i" '.plan_selection[0].approval.approved_at_history[$i].approved_at | if type == "string" then . else "" end' 2>/dev/null | tr -d '\r')"
            approved_by="$(printf '%s' "$impl_json" | jq -r --argjson i "$i" '.plan_selection[0].approval.approved_at_history[$i].approved_by | if type == "string" then . else "" end' 2>/dev/null | tr -d '\r')"
            matched=true
            break
          fi
        fi
        i=$((i + 1))
      done
      if $matched; then
        add_pass binding
      else
        add_fail binding "the PR body's binding line matches no plan-approved event for this plan — re-approve that plan to release it"
      fi
    else
      reason="$(printf '%s' "$impl_json" | jq -r '.plan_selection[0].approval.reason | if type == "string" then . else "" end' 2>/dev/null | tr -d '\r')"
      add_fail binding "plan binding: $(c "$reason")"
    fi
  else
    add_fail binding "plan binding unknown after one retry: $(c "$ATTEMPT_ERR")"
  fi

  if [ -n "$impl_json" ]; then
    if printf '%s' "$impl_json" | jq -e '(.plan_selection[0].trusted_post_plan | type) == "array"' >/dev/null 2>&1; then
      pa_out="$(printf '%s' "$impl_json" | jq -r "$POST_APPROVAL_JQ" 2>/dev/null)"; pa_rc=$?
      if [ "$pa_rc" -ne 0 ]; then
        add_fail post-approval "trusted_post_plan could not be read — not confirming the post-approval comments are covered"
      elif [ -z "$pa_out" ]; then
        add_pass post-approval
      else
        while IFS= read -r pa_line; do
          add_fail post-approval "post-approval comment not covered by the approval: $(c "$pa_line")"
        done <<<"$pa_out"
      fi
    else
      add_fail post-approval "trusted_post_plan is not a list — not confirming the post-approval comments are covered"
    fi
  fi
fi

# ---- 11. ci --------------------------------------------------------------------------------------

ci_kind=""
ci_lines=""
ci_ev=""
if retry_read attempt_ci; then
  case "$ci_kind" in
    green) add_pass ci; ci_ev="green" ;;
    pending) add_fail ci "CI pending on the head commit"; ci_ev="pending" ;;
    failing) add_fail ci "CI failing on the head commit"; ci_ev="failing" ;;
    skipped) add_fail ci "no check passed on the head commit — every check was skipped"; ci_ev="skipped" ;;
    none)
      if $allow_no_ci; then
        add_pass ci
        ci_ev="none-allowed"
      else
        add_fail ci "no checks configured — not green without an explicit no-CI opt-in"
        ci_ev="none"
      fi
      ;;
  esac
else
  add_fail read "checks: could not read the CI result after one retry ($ATTEMPT_ERR)"
fi

# ---- 12-13. ancestry, merge-state, governance ----------------------------------------------------

ancestry_rc=""
gov_lines=""
governance=""
if $rail_ok && $pr_ok; then
  anc_err="$(git merge-base --is-ancestor "$base_tip" "$head_oid" 2>&1)"; ancestry_rc=$?
  if [ "$ancestry_rc" -eq 0 ]; then
    add_pass ancestry
  else
    msg="PR is behind $(c "$default_branch") at $(printf '%s' "$base_tip" | cut -c1-12) — update the branch and let CI re-run"
    if [ "$ancestry_rc" -ne 1 ]; then
      msg="$msg; git: $(c "$(printf '%s\n' "$anc_err" | sed -n '1p')")"
    fi
    add_fail behind "$msg"
  fi

  case "$merge_state" in
    DIRTY|BLOCKED) add_fail merge-state "mergeStateStatus is $merge_state" ;;
    *) add_pass merge-state ;;
  esac

  gov_out="$("$script_dir/governance-paths.sh" "$base_tip" "$head_oid" 2>&1)"; gov_rc=$?
  gov_last="$(printf '%s\n' "$gov_out" | tail -n 1)"
  gov_token=""
  if [ "$gov_rc" -eq 0 ]; then
    case "$gov_last" in
      verdict=none) gov_token="none" ;;
      verdict=lessons-only) gov_token="lessons-only" ;;
      verdict=hold) gov_token="hold" ;;
    esac
  fi
  if [ -z "$gov_token" ]; then
    gov_msg=""
    while IFS= read -r gl; do
      case "$gl" in verdict=*) continue ;; esac
      gov_msg="$gl"
      break
    done <<<"$gov_out"
    add_fail governance "governance-paths.sh failed: $(c "$gov_msg")"
  else
    governance="$gov_token"
    gov_paths=""
    while IFS= read -r gl; do
      case "$gl" in
        "governance: "*) gov_lines="${gov_lines}$(c "$gl")"$'\n'; gov_paths="${gov_paths:+$gov_paths, }$(c "${gl#governance: }")" ;;
        "changed: "*) gov_lines="${gov_lines}$(c "$gl")"$'\n' ;;
      esac
    done <<<"$gov_out"
    case "$gov_token" in
      none) add_pass governance ;;
      hold) add_fail governance "governance path(s): $gov_paths" ;;
      lessons-only)
        if $dependabot; then
          add_fail governance ".claude/LESSONS.md — the lesson-append carve-out releases harness PRs only"
        else
          add_pass governance
        fi
        ;;
    esac
  fi
fi

# ---- 14-15. lessons carve-out reads (harness mode, governance=lessons-only) ----------------------

lessons_files_ev=""
added_lines=""
if [ "$governance" = "lessons-only" ] && $harness_ok; then
  lf_out="$(gh pr view "$pr" --json changedFiles,files)"; lf_rc=$?
  lf_token=""
  if [ "$lf_rc" -eq 0 ]; then
    lf_token="$(printf '%s' "$lf_out" | jq -r "$LESSONS_FILES_JQ" 2>/dev/null | tr -d '\r')"
  fi
  if [ -z "$lf_token" ]; then
    add_fail lessons-files "could not read the PR file list"
  else
    lessons_files_ev="$(c "$lf_token")"
    if [ "$lf_token" = "lessons-append" ]; then
      add_pass lessons-files
      eof="$(lessons_eof)"
      eof_first="$(printf '%s\n' "$eof" | sed -n '1p')"
      if [ "$eof_first" = "ok" ]; then
        add_pass lessons-eof
        added_lines="$(printf '%s\n' "$eof" | sed -n '2,$p' | tr '\000-\010\013-\037\177' '?')"
      else
        add_fail lessons-eof "end-of-file check failed: $(c "${eof_first#fail }")"
      fi
    else
      add_fail lessons-files "$(c "$lf_token")"
    fi
  fi
fi

# ---- 16. base ------------------------------------------------------------------------------------

if $default_ok && $fetch_ok && $pr_ok; then
  if [ "$base_ref" = "$default_branch" ]; then
    add_pass base
  else
    add_fail base "base branch $(c "$base_ref") is not the default branch $(c "$default_branch")"
  fi
fi

# ---- verdict and output --------------------------------------------------------------------------

if $dependabot; then
  required="stop branch ci fetch rail ancestry merge-state governance base"
  mode="dependabot"
else
  required="stop branch provenance archive binding post-approval ci fetch rail ancestry merge-state governance base"
  mode="harness"
  [ "$governance" = "lessons-only" ] && required="$required lessons-files lessons-eof"
fi
verdict="pass"
[ -z "$FAILS" ] || verdict="hold"
for req in $required; do
  has_passed "$req" || verdict="hold"
done

out="floor=$verdict"$'\n'"$FAILS"
ev() { [ -z "$2" ] || out="${out}$1=$2"$'\n'; }
ev pr "$pr"
ev mode "$mode"
ev head-branch "$(c "$head_branch")"
ev issue "$issue_n"
ev default-branch "$(c "$default_branch")"
ev base-ref "$(c "$base_ref")"
ev base-tip "$base_tip"
ev head-oid "$head_oid"
ev merge-state "$(c "$merge_state")"
ev ancestry-rc "$ancestry_rc"
ev ci "$ci_ev"
[ -z "$ci_lines" ] || out="${out}${ci_lines}"$'\n'
ev verifier-line "$(c "$archive_line")"
ev archive-url "$(c "$archive_url")"
ev approved-at "$(c "$approved_at")"
ev approved-by "$(c "$approved_by")"
[ -z "$gov_lines" ] || out="${out}${gov_lines}"
ev governance "$governance"
ev lessons-files "$lessons_files_ev"
[ -z "$added_lines" ] || out="${out}${added_lines}"$'\n'
ev stop-check "$stop_check"

printf '%s' "$out"
[ "$verdict" = "pass" ] && exit 0
exit 1
