#!/usr/bin/env bash
#
# tracker-sync.sh — the read-only, mechanical half of the opt-in live tracker (#622). It projects
# this repo's live GitHub state into ONE snapshot document (JSON) and writes it to a file; the
# `tracker` skill — the only place the Artifact/ArtifactData tools exist — pushes that file to the
# tracker's database. This script never calls an artifact tool and never writes to GitHub.
#
# USAGE: tracker-sync.sh [page] [-h|--help]
#   (no argument)  sync mode: read the repo's "Tracker" section, query GitHub, write state.json.
#   page           write a copy of templates/tracker/index.html with @REPO_NAME@ replaced by the
#                  repo's short name, to the same directory, for the skill to publish.
#
# THE "TRACKER" SECTION of the working-tree CLAUDE.md: a heading titled exactly "Tracker" (any '#'
# depth) whose FIRST fenced block holds `url: https://...` — blank lines and '#' comment lines are
# skipped; any other line is an unknown key. Exactly one url is required, https, no whitespace,
# quote, angle bracket or backtick. No such heading, or no CLAUDE.md, means the repo has no tracker.
#
# EXIT CODES: 0 = ready (or absent); 1 = malformed section or skip (a query failed, the snapshot
# was too large, or it could not be built); 2 = usage or environment error (an unknown argument,
# not inside a git repository, jq or gh missing) with a stderr reason and no stdout.
#
# STDOUT, sync mode:
#   no section:  tracker=absent                      (exit 0; no gh call, nothing written)
#   malformed:   tracker=malformed, then reason=<no-fence|no-url|multiple-urls|bad-url|unknown-key>
#                (exit 1; no gh call, nothing written)
#   skip:        result=skip, then reason=query-failed site=<repo|milestones|issues-open|
#                issues-closed|prs|branch> | reason=too-large bytes=<n> | reason=build-failed
#                (exit 1; no state.json is left behind — a stale one from an earlier run is removed)
#   ready (exit 0), in this order: tracker=present, url=<url>, dir=<dir>, file=<dir>/state.json,
#                collection=harness, doc=state, issues=<n>, milestones=<m>, truncated=<true|false>,
#                checked=<the snapshot's checkedAt>, result=ready
# <dir> is <absolute git-common-dir>/trail-blazer/tracker — never inside the tracked tree.
# STDOUT, page mode: tracker=<absent|present|malformed>, then url=<url> (present) or
#   reason=<token> (malformed), then page=<dir>/index.html and result=ready; a failed repo read is
#   result=skip with reason=query-failed site=repo, and an unusable repo name is
#   reason=bad-repo-name (both exit 1). Page mode does not need a well-formed section.
#
# READ-ONLY toward GitHub: only `gh repo view`, `gh issue list`, `gh pr list` and GET `gh api`
# calls. The only files written are state.json, index.html and short-lived temp files in <dir>.
# No retry: any failed call fails closed and the next sync heals it; GitHub stays the source of
# truth and the snapshot is a projection.
#
# SNAPSHOT (state.json, compact JSON, schema 1): schema, repo, repoUrl, checkedAt, defaultBranch,
# mainSha, truncated, milestones[] {number,title,url,dueOn,open,closed}, issues[] {number,title,
# url,state,milestone,pr,blockedBy[],waiting}, counts. Scope: the open and closed issues of the
# open milestones (only the first 100 open milestones are read), plus every other open issue. An
# open issue with no milestone, or whose milestone is closed or not read, is listed with milestone
# null. Issue state, first match wins: closed and
# NOT_PLANNED -> not-planned; any other closed -> done; then needs-human > blocked (impl-blocked)
# > pr-open > approved (plan-approved) > held (no-plan) > planned (plan-proposed) > unplanned.
# A PR is linked only from a claude/<n>-... head branch (the newest one wins; only the newest 200 PRs are read, and
# that limit does not set truncated). blockedBy comes
# from GitHub's native issue dependencies only; waiting is true iff any blocker is open.

set -uo pipefail

LBL_PROPOSED="plan-proposed"
LBL_APPROVED="plan-approved"
LBL_PR_OPEN="pr-open"
LBL_BLOCKED="impl-blocked"
LBL_NEEDS_HUMAN="needs-human"
LBL_NO_PLAN="no-plan"
MAX_BYTES=1000000
OPEN_LIMIT=1000
CLOSED_LIMIT=500
PR_LIMIT=200
ISSUE_FIELDS="number,title,url,state,stateReason,labels,milestone,blockedBy"

usage() {
  sed -n '3,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

mode="sync"
case "${1:-}" in
  "") : ;;
  page) mode="page" ;;
  -h|--help) usage; exit 0 ;;
  *) echo "tracker-sync.sh: unknown argument: $1 (usage: tracker-sync.sh [page])" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "tracker-sync.sh: too many arguments (usage: tracker-sync.sh [page])" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "tracker-sync.sh: jq is required but not on PATH" >&2
  exit 2
fi
top="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$top" ]; then
  echo "tracker-sync.sh: not inside a git repository" >&2
  exit 2
fi
script_dir="$(cd "$(dirname "$0")" && pwd -P)"

# --- the "Tracker" section --------------------------------------------------------------------
# tracker_state is absent|present|malformed; tracker_url / tracker_reason carry the detail.
tracker_state="absent"
tracker_url=""
tracker_reason=""

parse_section() {
  local cm="$top/CLAUDE.md" section fence line v urls=0 unknown=0
  [ -f "$cm" ] || return 0
  # Fence-aware like bin/check-harness.sh's claude_md_section: a heading inside a fenced block
  # neither starts the section nor ends it. The first output line is a marker proving the heading.
  section="$(awk -v t="Tracker" '
    {
      if (!inx) {
        if ($0 ~ /^```/) { tf = !tf; next }
        if (!tf && $0 ~ ("^#+[[:space:]]+" t "[[:space:]]*$")) {
          print "SECTION"; inx = 1; match($0, /^#+/); d = RLENGTH
        }
        next
      }
      if ($0 ~ /^```/) { infence = !infence }
      if (!infence && $0 ~ /^#+[[:space:]]/) { match($0, /^#+/); if (RLENGTH <= d) exit }
      print
    }' "$cm")"
  [ -n "$section" ] || return 0
  tracker_state="malformed"
  fence="$(awk '
    /^```/ { if (!f) { f = 1; print "FENCE"; next } else { exit } }
    f { print }' <<<"$section")"
  case "$fence" in
    FENCE*) : ;;
    *) tracker_reason="no-fence"; return 0 ;;
  esac
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [ "$line" = "FENCE" ] && continue
    case "$line" in
      ""|"#"*) continue ;;
    esac
    v="${line#"${line%%[![:space:]]*}"}"
    case "$v" in
      "") continue ;;
      "#"*) continue ;;
      url:*)
        v="${v#url:}"
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        urls=$((urls + 1))
        tracker_url="$v"
        ;;
      *) unknown=1 ;;
    esac
  done <<<"$fence"
  if [ "$unknown" -eq 1 ]; then tracker_reason="unknown-key"; return 0; fi
  if [ "$urls" -eq 0 ]; then tracker_reason="no-url"; return 0; fi
  if [ "$urls" -gt 1 ]; then tracker_reason="multiple-urls"; return 0; fi
  local q="'" dq='"' bt='`'
  case "$tracker_url" in
    https://?*) : ;;
    *) tracker_reason="bad-url"; return 0 ;;
  esac
  case "$tracker_url" in
    *[[:space:]]*|*[[:cntrl:]]*|*"$q"*|*"$dq"*|*"<"*|*">"*|*"$bt"*) tracker_reason="bad-url"; return 0 ;;
  esac
  tracker_state="present"
  tracker_reason=""
}
parse_section

skip() {
  echo "result=skip"
  echo "reason=$1"
  exit 1
}

if [ "$mode" = "sync" ]; then
  case "$tracker_state" in
    absent) echo "tracker=absent"; exit 0 ;;
    malformed) echo "tracker=malformed"; echo "reason=$tracker_reason"; exit 1 ;;
  esac
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "tracker-sync.sh: gh is required but not on PATH" >&2
  exit 2
fi

# --- the output directory ---------------------------------------------------------------------
common="$(git rev-parse --git-common-dir 2>/dev/null)"
if [ -z "$common" ]; then
  echo "tracker-sync.sh: git rev-parse --git-common-dir failed" >&2
  exit 2
fi
common_abs="$(cd "$common" 2>/dev/null && pwd -P)"
if [ -z "$common_abs" ]; then
  echo "tracker-sync.sh: could not resolve the git common dir to an absolute path: $common" >&2
  exit 2
fi
dir="$common_abs/trail-blazer/tracker"
mkdir -p "$dir" || { echo "tracker-sync.sh: cannot create $dir" >&2; exit 2; }
work="$dir/.work.$$"
cleanup() { [ -n "${work:-}" ] && rm -rf "$work"; }
trap cleanup EXIT
trap 'exit 1' INT TERM
mkdir -p "$work" || { echo "tracker-sync.sh: cannot create $work" >&2; exit 2; }

# --- page mode --------------------------------------------------------------------------------
if [ "$mode" = "page" ]; then
  echo "tracker=$tracker_state"
  case "$tracker_state" in
    present) echo "url=$tracker_url" ;;
    malformed) echo "reason=$tracker_reason" ;;
  esac
  if ! out="$(gh repo view --json nameWithOwner 2>/dev/null)"; then skip "query-failed site=repo"; fi
  nwo="$(jq -r '.nameWithOwner // empty' <<<"$out" 2>/dev/null)"
  name="${nwo#*/}"
  case "$name" in
    ""|*[!A-Za-z0-9._-]*) skip "bad-repo-name" ;;
  esac
  tmpl="$script_dir/../templates/tracker/index.html"
  [ -f "$tmpl" ] || { echo "tracker-sync.sh: missing template $tmpl" >&2; exit 2; }
  sed "s#@REPO_NAME@#$name#g" "$tmpl" > "$work/index.html" || skip "build-failed"
  mv "$work/index.html" "$dir/index.html" || skip "build-failed"
  echo "page=$dir/index.html"
  echo "result=ready"
  exit 0
fi

# --- sync mode --------------------------------------------------------------------------------
rm -f "$dir/state.json"

q_fail() { skip "query-failed site=$1"; }

if ! out="$(gh repo view --json nameWithOwner,url,defaultBranchRef 2>/dev/null)"; then q_fail repo; fi
printf '%s\n' "$out" > "$work/repo.json"
nwo="$(jq -r '.nameWithOwner // empty' "$work/repo.json" 2>/dev/null)"
default_branch="$(jq -r '.defaultBranchRef.name // empty' "$work/repo.json" 2>/dev/null)"
case "$nwo" in
  ""|*[!A-Za-z0-9._/-]*) q_fail repo ;;
esac
[ -n "$default_branch" ] || q_fail repo

if ! out="$(gh api "repos/$nwo/milestones?state=open&per_page=100" 2>/dev/null)"; then q_fail milestones; fi
printf '%s\n' "$out" > "$work/milestones.json"
jq -e 'type == "array"' "$work/milestones.json" >/dev/null 2>&1 || q_fail milestones

if ! out="$(gh issue list --state open --limit "$OPEN_LIMIT" --json "$ISSUE_FIELDS" 2>/dev/null)"; then q_fail issues-open; fi
printf '%s\n' "$out" > "$work/open.json"
jq -e 'type == "array"' "$work/open.json" >/dev/null 2>&1 || q_fail issues-open
open_n="$(jq 'length' "$work/open.json")"
trunc_shell=false
[ "$open_n" -ge "$OPEN_LIMIT" ] && trunc_shell=true

closed_files=""
i=0
nums="$(jq -r '.[] | .number' "$work/milestones.json" 2>/dev/null)"
while IFS= read -r mnum; do
  [ -n "$mnum" ] || continue
  i=$((i + 1))
  if ! out="$(gh issue list --state closed --milestone "$mnum" --limit "$CLOSED_LIMIT" --json "$ISSUE_FIELDS" 2>/dev/null)"; then q_fail issues-closed; fi
  printf '%s\n' "$out" > "$work/closed-$i.json"
  jq -e 'type == "array"' "$work/closed-$i.json" >/dev/null 2>&1 || q_fail issues-closed
  n="$(jq 'length' "$work/closed-$i.json")"
  [ "$n" -ge "$CLOSED_LIMIT" ] && trunc_shell=true
  closed_files="$closed_files $work/closed-$i.json"
done <<<"$nums"
if [ -n "$closed_files" ]; then
  # shellcheck disable=SC2086
  jq -c -s 'add // []' $closed_files > "$work/closed.json" || q_fail issues-closed
else
  printf '[]\n' > "$work/closed.json"
fi

if ! out="$(gh pr list --state all --limit "$PR_LIMIT" --json number,url,state,headRefName 2>/dev/null)"; then q_fail prs; fi
printf '%s\n' "$out" > "$work/prs.json"
jq -e 'type == "array"' "$work/prs.json" >/dev/null 2>&1 || q_fail prs

if ! out="$(gh api "repos/$nwo/branches/$default_branch" 2>/dev/null)"; then q_fail branch; fi
printf '%s\n' "$out" > "$work/branch.json"
main_sha="$(jq -r '.commit.sha // empty' "$work/branch.json" 2>/dev/null)"
[ -n "$main_sha" ] || q_fail branch

checked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n -c \
  --slurpfile repo "$work/repo.json" \
  --slurpfile ms "$work/milestones.json" \
  --slurpfile open "$work/open.json" \
  --slurpfile closed "$work/closed.json" \
  --slurpfile prs "$work/prs.json" \
  --arg nwo "$nwo" --arg branch "$default_branch" --arg sha "$main_sha" --arg at "$checked_at" \
  --argjson trunc "$trunc_shell" \
  --arg l_prop "$LBL_PROPOSED" --arg l_appr "$LBL_APPROVED" --arg l_pro "$LBL_PR_OPEN" \
  --arg l_blk "$LBL_BLOCKED" --arg l_nh "$LBL_NEEDS_HUMAN" --arg l_np "$LBL_NO_PLAN" '
  def lbls: [(.labels // [])[] | .name];
  def tolist: if (. | type) == "array" then . else [] end;
  def state_of:
    lbls as $l
    | if .state == "CLOSED" then (if .stateReason == "NOT_PLANNED" then "not-planned" else "done" end)
      elif any($l[]; . == $l_nh) then "needs-human"
      elif any($l[]; . == $l_blk) then "blocked"
      elif any($l[]; . == $l_pro) then "pr-open"
      elif any($l[]; . == $l_appr) then "approved"
      elif any($l[]; . == $l_np) then "held"
      elif any($l[]; . == $l_prop) then "planned"
      else "unplanned" end;
  ($ms[0] | tolist) as $mraw
  | ($open[0] | tolist) as $oraw
  | ($closed[0] | tolist) as $craw
  | ($prs[0] | tolist) as $praw
  | ([$mraw[] | .number]) as $mnums
  | ([$praw[]
      | (.headRefName // "" | capture("^claude/(?<n>[0-9]+)-")?) as $c
      | select($c != null)
      | {n: ($c.n | tonumber), number: .number, url: .url, state: (.state | ascii_downcase)}]) as $pl
  | ([$oraw[], $craw[]]
      | map({
          number: .number,
          title: .title,
          url: .url,
          state: state_of,
          milestone: (if (.milestone.number // null) as $m | ($mnums | index($m)) != null then .milestone.number else null end),
          pr: (.number as $num | ($pl | map(select(.n == $num)) | if length == 0 then null else (max_by(.number) | {number, url, state}) end)),
          blockedBy: [((.blockedBy.nodes // [])[]) | {number: .number, url: .url, open: (.state == "OPEN")}],
          waiting: any(((.blockedBy.nodes // [])[]); .state == "OPEN"),
          _more: (((.blockedBy.totalCount // 0)) > ((.blockedBy.nodes // []) | length))
        })
      | sort_by(.number)) as $all
  | ($all | map(del(._more))) as $issues
  | ($issues | map(select(.state == "done" or .state == "not-planned"))) as $fin
  | {
      schema: 1,
      repo: $nwo,
      repoUrl: ($repo[0].url // ""),
      checkedAt: $at,
      defaultBranch: $branch,
      mainSha: $sha,
      truncated: ($trunc or any($all[]; ._more)),
      milestones: ([$mraw[]
        | .number as $n
        | {number: .number, title: .title, url: .html_url, dueOn: (.due_on // null),
           open: ($issues | map(select(.milestone == $n and (.state != "done") and (.state != "not-planned"))) | length),
           closed: ($fin | map(select(.milestone == $n)) | length)}]
        | sort_by([(.dueOn == null), (.dueOn // ""), .number])),
      issues: $issues,
      counts: (reduce $issues[] as $i ({}; .[$i.state] += 1)
        | . + {total: ($issues | length), waiting: ($issues | map(select(.waiting)) | length)})
    }' > "$work/state.json" || skip "build-failed"

bytes="$(wc -c < "$work/state.json" | tr -d '[:space:]')"
if [ "$bytes" -gt "$MAX_BYTES" ]; then
  skip "too-large bytes=$bytes"
fi
mv "$work/state.json" "$dir/state.json" || skip "build-failed"

issues_n="$(jq '.issues | length' "$dir/state.json")"
miles_n="$(jq '.milestones | length' "$dir/state.json")"
trunc_out="$(jq -r '.truncated' "$dir/state.json")"
echo "tracker=present"
echo "url=$tracker_url"
echo "dir=$dir"
echo "file=$dir/state.json"
echo "collection=harness"
echo "doc=state"
echo "issues=$issues_n"
echo "milestones=$miles_n"
echo "truncated=$trunc_out"
echo "checked=$checked_at"
echo "result=ready"
exit 0
