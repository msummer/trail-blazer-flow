#!/usr/bin/env bash
#
# tracker-sync.sh — the read-only, mechanical half of the opt-in live tracker (#622). It projects
# this repo's live GitHub state (and its local verification baseline file) into ONE snapshot
# document (JSON) and writes it to a file; the
# `tracker` skill — the only place the Artifact/ArtifactData tools exist — pushes that file to the
# tracker's database. This script never calls an artifact tool and never writes to GitHub.
#
# USAGE: tracker-sync.sh [page | cycle-note <run-id> -] [-h|--help]
#   (no argument)  sync mode: read the repo's "Tracker" section, query GitHub, write state.json.
#   page           write a copy of templates/tracker/index.html with @REPO_NAME@ replaced by the
#                  repo's short name, to the same directory, for the skill to publish.
#   cycle-note <run-id> -   with `cycle-note: on` in the section, read dispatch-ledger records from
#                  stdin and write <dir>/last-cycle.json, the opt-in cycle note's document (#650).
#
# THE "TRACKER" SECTION of the working-tree CLAUDE.md: a heading titled exactly "Tracker" (any '#'
# depth) whose FIRST fenced block holds `url: https://...` and, optionally, up to 8 repeatable
# `section: <id> <path>#<heading>` lines, up to 8 repeatable `label-state: <label>=<state>`
# lines and at most one `cycle-note: on|off` line — blank lines and '#' comment lines are
# skipped; any other line is an unknown key. Exactly one url is required, https, no whitespace, quote, angle bracket
# or backtick. A section value is an id of 1-40 [a-z0-9-] characters (unique, starting with
# [a-z0-9]), whitespace, a repo-relative .md path of [A-Za-z0-9._/-] (no leading or trailing '/',
# no empty, '.' or '..' segment, at most 200 characters), '#', and an exact heading of 1-120
# characters (no control character, not starting with '#'). A label-state value is a
# label (1-50 characters of [A-Za-z0-9 ._:/+-], trailing whitespace trimmed), '=', and a state that
# is exactly parked, external or held; the label may not be one the state chain reads itself
# (plan-proposed, plan-approved, pr-open, impl-blocked, needs-human, no-plan, triaged-held), and
# no two labels may be equal ignoring ASCII case. No such heading, or no CLAUDE.md, means the repo
# has no tracker.
#
# EXIT CODES: 0 = ready (or absent); 1 = malformed section or skip (a query failed, the snapshot
# was too large, or it could not be built); 2 = usage or environment error (an unknown argument,
# not inside a git repository, jq or gh missing) with a stderr reason and no stdout.
#
# STDOUT, sync mode:
#   no section:  tracker=absent                      (exit 0; no gh call, nothing written)
#   malformed:   tracker=malformed, then reason=<no-fence|unknown-key|no-url|multiple-urls|bad-url|
#                bad-section|bad-label-state|bad-cycle-note>, checked in that order (exit 1; no gh
#                call, nothing written)
#   skip:        result=skip, then reason=query-failed site=<repo|milestones|issues-open|
#                issues-closed|issues-recent|prs|pr-files|branch|ci|tree|section|issues-refs> | reason=too-large bytes=<n> |
#                reason=build-failed
#                (exit 1; no state.json is left behind — a stale one from an earlier run is removed)
#   ready (exit 0), in this order: tracker=present, url=<url>, dir=<dir>, file=<dir>/state.json,
#                collection=harness, doc=state, issues=<n>, milestones=<m>, truncated=<true|false>,
#                checked=<the snapshot's checkedAt>, then one `warn=<token> section=<id>` line per
#                dropped section (tokens section-missing|section-too-large|section-no-heading|
#                section-empty, in declaration order), then result=ready
# <dir> is <absolute git-common-dir>/trail-blazer/tracker — never inside the tracked tree.
# STDOUT, cycle-note mode: tracker=absent (exit 0) or tracker=malformed, reason=<token> (exit 1) as in
#   sync mode; tracker=present, cycle-note=off (exit 0) when the key is absent or off — in these three
#   neither the run id nor stdin is read; else result=skip with reason=bad-run-id |
#   bad-ledger line=<n> | too-large issues=<n> | build-failed (exit 1, no ledger text printed), or
#   tracker=present, url, dir, file=<dir>/last-cycle.json, collection=sections, doc=last-cycle,
#   issues=<n>, result=ready. A stale last-cycle.json is removed first; no gh call; state.json is
#   never touched. A wrong argument count or a third argument other than - is exit 2.
# STDOUT, page mode: tracker=<absent|present|malformed>, then url=<url> (present) or
#   reason=<token> (malformed), then page=<dir>/index.html and result=ready; a failed repo read is
#   result=skip with reason=query-failed site=repo, and an unusable repo name is
#   reason=bad-repo-name (both exit 1). Page mode does not need a well-formed section.
#
# READ-ONLY toward GitHub: only `gh repo view`, `gh issue list`, `gh pr list` and GET `gh api`
# calls (a declared file is read through GET git/trees and git/blobs at the default branch's
# commit; its path is only compared as data inside jq, never put in a URL, argv or shell). The only files written are state.json, index.html,
# last-cycle.json and short-lived temp files in <dir>.
# No retry: any failed call fails closed and the next sync heals it; GitHub stays the source of
# truth and the snapshot is a projection.
#
# SNAPSHOT (state.json, compact JSON, schema 1): schema, repo, repoUrl, checkedAt, defaultBranch,
# mainSha, health {ci,ciUrl,baseline,baselineCurrent}, truncated, milestones[] {number,title,url,dueOn,open,closed}, issues[] {number,title,
# url,state,milestone,pr,blockedBy[],waiting}, counts, sections[] (one per `section:` line whose
# file yields a table or list: {id,title,kind:"table",source,columns[],rows[{cells[],issues[]}],
# truncated} or {id,title,kind:"list",source,rows[{text,issues[]}],truncated}; at most 50 rows, 8
# columns, 200 characters per cell), refs[] {number,title,url,state} (closed issues that section
# rows reference by #<n> and issues[] does not hold), recentSince, recent[], openPrs[],
# waitingOnYou[]. Scope of issues[]: the open and closed issues of the
# open milestones (only the first 100 open milestones are read), plus every other open issue. An
# open issue with no milestone, or whose milestone is closed or not read, is listed with milestone
# null. Issue state, first match wins: closed and
# NOT_PLANNED -> not-planned; any other closed -> done; then needs-human > blocked (impl-blocked)
# > pr-open > approved (plan-approved) > parked (the triaged-held label) > the state a label-state:
# line maps one of the issue's labels to (labels compared ignoring ASCII case; the first declared
# mapping wins; the label names are never stored) > held (no-plan) > planned (plan-proposed) >
# unplanned.
# A PR is linked only from a claude/<n>-... head branch (the newest one wins; only the newest 200 PRs are read, and
# that limit does not set truncated). blockedBy comes
# from GitHub's native issue dependencies only; waiting is true iff any blocker is open. A
# section's own truncated never sets the snapshot's.
#
# HEALTH: ci is passing|failing|pending|null from ONE GET of the check runs on mainSha (hex-checked
# before it enters the path; only the first 100 runs GitHub returns are read; legacy commit
# statuses are not). The newest run per check name counts (highest id), then first match wins:
# failing (completed with a conclusion other than success, neutral or skipped), pending (not
# completed), else passing; null when no run came back. ciUrl is the https html_url of the first
# run of that class by [name, id], else null. A failed or malformed CI read is a skip with site=ci.
# baseline is read from BASELINE.md in the working tree's .claude directory and never written:
# {commit, date, results[] {command, detail}} from the first `- commit:` (7-40 lowercase hex), the
# `- date:` (YYYY-MM-DD, else null) and the indented "- `<command>`: <detail>" lines under
# `- results:` (at most 50, each string cut to 200). A missing, over-64KiB or unparseable file is
# baseline null, never a skip. baselineCurrent is mainSha starting with baseline.commit, or null
# without a baseline.
# RECENT AND WAITING (#644, #645): recentSince is checkedAt minus 14 days (one jq computation, no
# second `date`). recent[] lists, newest first, the PRs merged and the issues closed since then:
# a PR row {kind,number,title,url,mergedAt,author,mergedBy,issue,ci,verifier,soloMerge}, an issue
# row {kind,number,title,url,closedAt,state}. author/mergedBy are logins only, never display
# names. ci is none|pending|passing|failing from statusCheckRollup (an unknown conclusion is
# failing). verifier is pass|fail|incomplete|died from the last verifier status line in the PR
# body whose issue equals the linked issue, else null; no other body text is kept. soloMerge is
# true iff author and merger are the same login and no other login's latest review APPROVED.
# openPrs[] lists every open PR, any branch or author, with reasons[] (ci-failing, then
# governance-path, then awaiting-review; none for a draft). waitingOnYou[] is {kind,number,reason}
# sorted by reason in the order needs-human, ci-failing, governance-path, awaiting-review,
# plan-proposed, solo-merge, then number;
# plan-proposed is omitted when CLAUDE.md has a "Plan auto-approval policy" heading or an
# "Autonomy mode" section whose first fence's first mode: line is autonomous. Reaching the 200
# recent closed issues sets truncated; the PR read limit still does not.
# GOVERNANCE PATH (#659): one more list query reads the changed paths of the newest 50 open PRs.
# They go through the merge floor's classifier (governance-paths.sh --paths, resolved from this
# script's own directory only, with the declared globs of the working-tree CLAUDE.md; the sibling
# reads that file and stdin only). A PR is cleared of the reason only when it appears once, its
# file list is complete (length equals changedFiles, above zero) and well-formed (a non-empty
# path with no control character, a plain changeType) and the classifier exits 0 with
# verdict=none. A truncated or renamed-file list, a PR past the 50, lessons-only, hold, an
# error or a missing sibling all leave governance-path on. A failed or non-array query is
# site=pr-files. No path is stored or printed.

set -uo pipefail

LBL_PROPOSED="plan-proposed"
LBL_APPROVED="plan-approved"
LBL_PR_OPEN="pr-open"
LBL_BLOCKED="impl-blocked"
LBL_NEEDS_HUMAN="needs-human"
LBL_NO_PLAN="no-plan"
LBL_TRIAGED_HELD="triaged-held"
MAX_BYTES=1000000
BASELINE_MAX_BYTES=65536
CI_PER_PAGE=100
OPEN_LIMIT=1000
CLOSED_LIMIT=500
PR_LIMIT=200
GOV_PR_LIMIT=50
GOV_FIELDS="number,changedFiles,files"
MAX_SECTIONS=8
MAX_LABEL_STATES=8
MAX_LABEL_LEN=50
MAX_ROWS=50
MAX_COLS=8
MAX_CELL=200
MAX_FILE_BYTES=262144
MAX_REFS=50
REF_LIMIT=500
ISSUE_FIELDS="number,title,url,state,stateReason,labels,milestone,blockedBy"
PR_FIELDS="number,url,state,headRefName,title,author,isDraft,mergedAt,mergedBy,body,statusCheckRollup,latestReviews"
RECENT_DAYS=14
RECENT_LIMIT=200
RECENT_FIELDS="number,title,url,state,stateReason,closedAt"
# Cycle-note vocabularies (#650): mirror bin/reconcile-ledger.sh's vocab(), seed case and
# DEPLOY_OUTCOMES; the tracker-cycle-note-vocab fixture pins that they stay equal.
NOTE_SEED="unplanned in_revision ready_to_implement needs_initial_plan needs_revision ready"
NOTE_PLANNER="plan-posted plan-revised incomplete died"
NOTE_IMPLEMENTER="complete blocked incomplete died"
NOTE_VERIFIER="pass fail incomplete died"
NOTE_MERGE="merged merge-blocked not-eligible merge-unconfirmed"
NOTE_DEPLOY="verified pending failed"
MAX_NOTE_ISSUES=200

usage() {
  sed -n '3,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

mode="sync"
case "${1:-}" in
  "") : ;;
  page) mode="page" ;;
  cycle-note) mode="cycle-note" ;;
  -h|--help) usage; exit 0 ;;
  *) echo "tracker-sync.sh: unknown argument: $1 (usage: tracker-sync.sh [page | cycle-note <run-id> -])" >&2; exit 2 ;;
esac
note_run_id=""
if [ "$mode" = "cycle-note" ]; then
  if [ "$#" -ne 3 ] || [ "$3" != "-" ]; then
    echo "tracker-sync.sh: cycle-note takes a run id and - (usage: tracker-sync.sh [page | cycle-note <run-id> -])" >&2
    exit 2
  fi
  note_run_id="$2"
elif [ "$#" -gt 1 ]; then
  echo "tracker-sync.sh: too many arguments (usage: tracker-sync.sh [page | cycle-note <run-id> -])" >&2
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
tracker_cycle_note="off"

# The declared repo-file sections, filled by parse_section_values: sec_n entries in declaration
# order. Always iterate by index up to sec_n, never "${sec_id[@]}": an empty array is an unbound
# variable under `set -u` on bash 3.2.
sec_n=0
sec_count=0
sec_raw=""
sec_id=()
sec_path=()
sec_head=()

# The declared label-to-state mappings, filled by parse_label_states: one "<lowercased label>TAB
# <state>" line per mapping, in declaration order. Newline-joined text, never an array.
ls_n=0
ls_raw=""
ls_lines=""

# parse_section_values — validate every collected `section: <id> <path>#<heading>` value, filling
# sec_id/sec_path/sec_head; returns 1 on the first violation.
parse_section_values() {
  local entry v id rest path head seen=" " seg
  [ "$sec_count" -le "$MAX_SECTIONS" ] || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    v="${entry#=}"
    case "$v" in
      *[[:space:]]*) : ;;
      *) return 1 ;;
    esac
    id="${v%%[[:space:]]*}"
    rest="${v#"$id"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    case "$id" in
      ""|-*|*[!a-z0-9-]*) return 1 ;;
    esac
    [ "${#id}" -le 40 ] || return 1
    case "$seen" in
      *" $id "*) return 1 ;;
    esac
    seen="$seen$id "
    case "$rest" in
      *#*) : ;;
      *) return 1 ;;
    esac
    path="${rest%%#*}"
    head="${rest#*#}"
    head="${head#"${head%%[![:space:]]*}"}"
    head="${head%"${head##*[![:space:]]}"}"
    case "$path" in
      ""|/*|*/|*[!A-Za-z0-9._/-]*) return 1 ;;
      *.md) : ;;
      *) return 1 ;;
    esac
    [ "${#path}" -le 200 ] || return 1
    case "/$path/" in
      *//*|*/./*|*/../*) return 1 ;;
    esac
    seg="${path##*/}"
    [ "$seg" != ".md" ] || return 1
    [ -n "$head" ] || return 1
    [ "${#head}" -le 120 ] || return 1
    case "$head" in
      "#"*|*[[:cntrl:]]*) return 1 ;;
    esac
    sec_id[$sec_n]="$id"
    sec_path[$sec_n]="$path"
    sec_head[$sec_n]="$head"
    sec_n=$((sec_n + 1))
  done <<<"$sec_raw"
  return 0
}

# parse_label_states — validate every collected `label-state: <label>=<state>` value, filling
# ls_lines; returns 1 on the first violation.
parse_label_states() {
  local val label st low nl=$'\n' tab=$'\t'
  [ "$ls_n" -gt 0 ] || return 0
  [ "$ls_n" -le "$MAX_LABEL_STATES" ] || return 1
  while IFS= read -r val; do
    [ -n "$val" ] || continue
    case "$val" in
      *=*=*) return 1 ;;
      *=*) : ;;
      *) return 1 ;;
    esac
    label="${val%%=*}"
    label="${label%"${label##*[![:space:]]}"}"
    st="${val#*=}"
    st="${st#"${st%%[![:space:]]*}"}"
    [ -n "$label" ] || return 1
    [ "${#label}" -le "$MAX_LABEL_LEN" ] || return 1
    case "$label" in
      *[!A-Za-z0-9\ ._:/+-]*) return 1 ;;
    esac
    case "$st" in
      parked|external|held) : ;;
      *) return 1 ;;
    esac
    low="$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"$label")"
    case "$low" in
      "$LBL_PROPOSED"|"$LBL_APPROVED"|"$LBL_PR_OPEN"|"$LBL_BLOCKED"|"$LBL_NEEDS_HUMAN"|"$LBL_NO_PLAN"|"$LBL_TRIAGED_HELD") return 1 ;;
    esac
    case "$nl$ls_lines" in
      *"$nl$low$tab"*) return 1 ;;
    esac
    ls_lines="$ls_lines$low$tab$st$nl"
  done <<<"$ls_raw"
  return 0
}

parse_section() {
  local cm="$top/CLAUDE.md" section fence line v urls=0 unknown=0 cnotes=0 cn_val=""
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
      section:*)
        v="${v#section:}"
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        sec_count=$((sec_count + 1))
        sec_raw="$sec_raw=$v"$'\n'
        ;;
      label-state:*)
        v="${v#label-state:}"
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        [ -n "$v" ] || v="="
        ls_n=$((ls_n + 1))
        ls_raw="$ls_raw$v"$'\n'
        ;;
      cycle-note:*)
        v="${v#cycle-note:}"
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        cnotes=$((cnotes + 1))
        cn_val="$v"
        ;;
      *) unknown=1 ;;
    esac
  done <<<"$fence"
  # Extension shape for a further key: one case arm above collecting its values, one validator
  # after the previous key's validator that sets its own reason token, and its own parsed
  # variables (label-state: is the second instance of this shape).
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
  if ! parse_section_values; then tracker_reason="bad-section"; return 0; fi
  if ! parse_label_states; then tracker_reason="bad-label-state"; return 0; fi
  if [ "$cnotes" -gt 1 ]; then tracker_reason="bad-cycle-note"; return 0; fi
  if [ "$cnotes" -eq 1 ]; then
    case "$cn_val" in
      on|off) tracker_cycle_note="$cn_val" ;;
      *) tracker_reason="bad-cycle-note"; return 0 ;;
    esac
  fi
  tracker_state="present"
  tracker_reason=""
}
parse_section

skip() {
  echo "result=skip"
  echo "reason=$1"
  exit 1
}

if [ "$mode" != "page" ]; then
  case "$tracker_state" in
    absent) echo "tracker=absent"; exit 0 ;;
    malformed) echo "tracker=malformed"; echo "reason=$tracker_reason"; exit 1 ;;
  esac
fi
if [ "$mode" = "cycle-note" ] && [ "$tracker_cycle_note" != "on" ]; then
  echo "tracker=present"
  echo "cycle-note=off"
  exit 0
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

# --- cycle-note mode (#650) -------------------------------------------------------------------
# Reads plain dispatch-ledger records on stdin, validates every field against closed vocabularies
# and writes <dir>/last-cycle.json. Ledger text never reaches stdout or stderr; a bad line is
# reported by number only. Makes no gh call.
NOTE_AWK='
function inset(w, set,   a, n, i) {
  n = split(set, a, " ")
  for (i = 1; i <= n; i++) if (a[i] == w) return 1
  return 0
}
function isnum(s) { return (s ~ /^[1-9][0-9]*$/ && length(s) <= 10) }
function flag(ln) { if (!bad) { bad = 1; badline = ln } }
{
  sub(/\r$/, "")
  if (NF == 0 || $1 ~ /^#/) next
  ok = 1
  if (NF < 3 || !isnum($1)) ok = 0
  st = $2; oc = $3
  if (ok) {
    if (st == "seed") ok = (oc == "-" || inset(oc, seed))
    else if (st == "planner") ok = (oc == "-" || inset(oc, pl))
    else if (st == "implementer") ok = (oc == "-" || inset(oc, im))
    else if (st == "verifier") ok = (oc == "-" || inset(oc, ve))
    else if (st == "merge") ok = (oc == "-" || inset(oc, me))
    else ok = 0
  }
  dp = "-"; pr = "-"; sr = 0; sd = 0; sp = 0; sh = 0
  for (i = 4; ok && i <= NF; i++) {
    t = $i
    if (t ~ /^[0-9]+$/ && length(t) <= 4) { if (sr) ok = 0; sr = 1 }
    else if (t ~ /^deploy=/) {
      v = substr(t, 8)
      if (sd || st != "merge" || !inset(v, dep)) ok = 0
      sd = 1; dp = v
    }
    else if (t ~ /^pr=/) {
      v = substr(t, 4)
      if (sp || (st != "implementer" && st != "merge") || !isnum(v)) ok = 0
      sp = 1; pr = v
    }
    else if (t ~ /^harness=[A-Za-z0-9.+-]+$/ && length(t) <= 40) { if (sh) ok = 0; sh = 1 }
    else ok = 0
  }
  if (!ok) { flag(NR); next }
  printf "%s\t%s\t%s\t%s\t%s\n", $1, st, oc, dp, pr
}
END { if (bad) printf "BAD\t%d\n", badline }
'
NOTE_JQ='
split("\n") | map(select(length > 0) | split("\t") | {i: (.[0] | tonumber), s: .[1], o: .[2], d: .[3], p: .[4]})
| group_by(.i)
| map(
    . as $g
    | (reduce $g[] as $r ({}; .[$r.s] = {o: $r.o, d: $r.d})) as $st
    | ([ $g[] | select(.p != "-") | .p ] | .[-1]) as $pr
    | ([ ("planner", "implementer", "verifier", "merge") as $s | select($st[$s] != null) | "\($s) \($st[$s].o)" ]
       + (if $st.merge != null and $st.merge.d != "-" then ["deploy " + $st.merge.d] else [] end)) as $parts
    | {text: (if ($parts | length) == 0 then "not dispatched" else ($parts | join("; ")) end), issues: [$g[0].i]}
      + (if $pr != null then {pr: ($pr | tonumber)} else {} end)
  ) as $items
| {schema: 1, title: "Last cycle", order: -1, kind: "list", titles: true, runId: $rid, finishedAt: $at,
   source: ("issue-cycle " + $rid + ", finished " + $at), updated: $at, items: $items}
'
if [ "$mode" = "cycle-note" ]; then
  rm -f "$dir/last-cycle.json"
  nd='[0123456789]'
  case "$note_run_id" in
    run-$nd$nd$nd$nd$nd$nd$nd${nd}T$nd$nd$nd$nd$nd${nd}Z-*) : ;;
    *) skip "bad-run-id" ;;
  esac
  note_suffix="${note_run_id#run-????????T??????Z-}"
  case "$note_suffix" in
    ""|*[!0123456789]*) skip "bad-run-id" ;;
  esac
  [ "${#note_suffix}" -le 10 ] || skip "bad-run-id"
  cat > "$work/ledger.txt" || skip "build-failed"
  LC_ALL=C awk -v seed="$NOTE_SEED" -v pl="$NOTE_PLANNER" -v im="$NOTE_IMPLEMENTER" \
    -v ve="$NOTE_VERIFIER" -v me="$NOTE_MERGE" -v dep="$NOTE_DEPLOY" \
    "$NOTE_AWK" "$work/ledger.txt" > "$work/ledger.tsv" || skip "build-failed"
  note_bad="$(sed -n 's/^BAD\t\([0-9][0-9]*\)$/\1/p' "$work/ledger.tsv" 2>/dev/null)"
  [ -z "$note_bad" ] || skip "bad-ledger line=$note_bad"
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -R -s -c --arg rid "$note_run_id" --arg at "$at" "$NOTE_JQ" "$work/ledger.tsv" > "$work/last-cycle.json" 2>/dev/null || skip "build-failed"
  n="$(jq '.items | length' "$work/last-cycle.json" 2>/dev/null)"
  case "$n" in
    ""|*[!0123456789]*) skip "build-failed" ;;
  esac
  [ "$n" -le "$MAX_NOTE_ISSUES" ] || skip "too-large issues=$n"
  mv "$work/last-cycle.json" "$dir/last-cycle.json" || skip "build-failed"
  echo "tracker=present"
  echo "url=$tracker_url"
  echo "dir=$dir"
  echo "file=$dir/last-cycle.json"
  echo "collection=sections"
  echo "doc=last-cycle"
  echo "issues=$n"
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

if ! out="$(gh pr list --state all --limit "$PR_LIMIT" --json "$PR_FIELDS" 2>/dev/null)"; then q_fail prs; fi
printf '%s\n' "$out" > "$work/prs.json"
jq -e 'type == "array"' "$work/prs.json" >/dev/null 2>&1 || q_fail prs

# --- governance-path read (#659): one list query for every open PR's changed paths, classified by
# the merge floor's own classifier (governance-paths.sh --paths) as a display-only hint. A PR is
# cleared (no governance-path reason) only when its file list is complete and well-formed and the
# classifier prints verdict=none; every other outcome leaves the reason on. Paths go to jq as data
# and to the classifier's stdin only; none is stored, printed or put in argv.
if ! out="$(gh pr list --state open --limit "$GOV_PR_LIMIT" --json "$GOV_FIELDS" </dev/null 2>/dev/null)"; then q_fail pr-files; fi
printf '%s\n' "$out" > "$work/pr-files.json"
jq -e 'type == "array"' "$work/pr-files.json" >/dev/null 2>&1 || q_fail pr-files
GOV_JQ='
  [.[] | objects] | group_by(.number) | map(select(length == 1) | .[0])
  | .[]
  | select((.number | type) == "number" and (.number | floor) == .number and .number > 0
           and (.changedFiles | type) == "number" and (.files | type) == "array"
           and (.files | length) == .changedFiles and .changedFiles > 0
           and all(.files[];
                   type == "object"
                   and (.path | type) == "string" and (.path | length) > 0
                   and ((.path | explode | any(. < 32 or . == 127)) | not)
                   and ((.changeType // "") | IN("ADDED", "MODIFIED", "DELETED", "CHANGED", "COPIED"))))
  | .number'
gov_candidates="$(jq -r "$GOV_JQ" "$work/pr-files.json" 2>/dev/null)" || skip "build-failed"
gov_clear=""
for gn in $gov_candidates; do
  case "$gn" in ""|*[!0-9]*) skip "build-failed" ;; esac
  gpaths="$(jq -r --argjson n "$gn" 'first(.[] | objects | select(.number == $n)) | .files[].path' "$work/pr-files.json" 2>/dev/null)" || skip "build-failed"
  gv="$(printf '%s\n' "$gpaths" | "$script_dir/governance-paths.sh" --paths "$top/CLAUDE.md" 2>/dev/null)"
  grc=$?
  glast="$(printf '%s\n' "$gv" | tail -n 1)"
  if [ "$grc" -eq 0 ] && [ "$glast" = "verdict=none" ]; then
    gov_clear="$gov_clear $gn"
  fi
done
jq -n -c --arg s "$gov_clear" '[$s | splits(" +") | select(length > 0) | tonumber]' > "$work/gov-clear.json" || skip "build-failed"

if ! out="$(gh api "repos/$nwo/branches/$default_branch" 2>/dev/null)"; then q_fail branch; fi
printf '%s\n' "$out" > "$work/branch.json"
main_sha="$(jq -r '.commit.sha // empty' "$work/branch.json" 2>/dev/null)"
[ -n "$main_sha" ] || q_fail branch

# --- health: CI on the default branch, and the local verification baseline (#648) --------------
# CI: one GET of the check runs on main's commit; a failed or malformed answer fails closed.
case "$main_sha" in
  ""|*[!0-9a-f]*) q_fail ci ;;
esac
if ! out="$(gh api "repos/$nwo/commits/$main_sha/check-runs?per_page=$CI_PER_PAGE" 2>/dev/null)"; then q_fail ci; fi
printf '%s\n' "$out" > "$work/ci.json"
jq -e 'type == "object" and ((.check_runs | type) == "array") and ((.total_count | type) == "number")' \
  "$work/ci.json" >/dev/null 2>&1 || q_fail ci

# Baseline: only the fields the harness writes, from this checkout's working tree. It never skips
# the sync: a missing, oversized or unparseable file is a null baseline.
bl="$top/.claude/BASELINE.md"
printf 'null\n' > "$work/baseline.json"
if [ -f "$bl" ]; then
  bl_bytes="$(wc -c < "$bl" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$bl_bytes" ] && [ "$bl_bytes" -le "$BASELINE_MAX_BYTES" ]; then
    if jq -R -s -c '
      def trim: sub("^[ \t]+"; "") | sub("[ \t]+$"; "");
      (split("\n") | map(sub("\r$"; ""))) as $L
      | ([$L[] | select(test("^- commit:"))] | .[0]) as $cl
      | if $cl == null then null
        else
          ($cl | sub("^- commit:"; "") | trim) as $commit
          | if ($commit | test("^[0-9a-f]{7,40}$")) | not then null
            else
              ([$L[] | select(test("^- date:"))] | .[0]) as $dl
              | (if $dl == null then null else ($dl | sub("^- date:"; "") | trim) end) as $d
              | ([range(0; $L | length)] | map(select($L[.] | test("^- results:[ \t]*$"))) | .[0]) as $ri
              | {commit: $commit,
                 date: (if $d != null and ($d | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then $d else null end),
                 results: (if $ri == null then []
                   else
                     ($L[$ri + 1:] | (map(test("^[ \t]")) | index(false)) as $e | if $e == null then . else .[:$e] end)
                     | map(capture("^[ \t]+-[ \t]+`(?<c>[^`]+)`:[ \t]*(?<d>.*)$")?)
                     | .[0:50]
                     | map({command: (.c | .[0:200]), detail: (.d | trim | .[0:200])})
                   end)}
            end
        end' "$bl" > "$work/baseline.tmp" 2>/dev/null; then
      mv "$work/baseline.tmp" "$work/baseline.json" || printf 'null\n' > "$work/baseline.json"
    fi
  fi
fi

# Health: the latest run per check name decides CI (never response order); a check whose newest
# run is outside the first CI_PER_PAGE returned is not seen.
jq -n -c \
  --slurpfile ci "$work/ci.json" \
  --slurpfile bl "$work/baseline.json" \
  --arg sha "$main_sha" '
  def cls:
    if .status != "completed" then "pending"
    elif (.conclusion as $k | ["success", "neutral", "skipped"] | index($k)) != null then "passing"
    else "failing" end;
  ($bl[0]) as $b
  | ([$ci[0].check_runs[] | select(type == "object")]
      | group_by(.name // "")
      | map(max_by(.id // 0) | . + {_c: cls})
      | sort_by([(.name // ""), (.id // 0)])) as $r
  | (if ($r | length) == 0 then null
     elif any($r[]; ._c == "failing") then "failing"
     elif any($r[]; ._c == "pending") then "pending"
     else "passing" end) as $c
  | ($r | map(select(._c == $c)) | .[0].html_url // null) as $u
  | {ci: $c,
     ciUrl: (if ($u | type) == "string" and ($u | startswith("https://")) then $u else null end),
     baseline: $b,
     baselineCurrent: (if $b == null then null else ($sha | startswith($b.commit)) end)}' \
  > "$work/health.json" || skip "build-failed"

# --- repo-file sections (#646) ----------------------------------------------------------------
# Each declared `section:` file is read from the default branch at the snapshot's commit (GET
# git/trees, then GET git/blobs), never from the working tree. A declared path is only compared as
# data inside jq against the tree listing — it never reaches a URL, an argv or a shell — and file
# content is only parsed by the constant awk program and jq below. A query failure is a skip; a
# missing, oversized or structureless file is one `warn=` line and the section is dropped.
# Extraction output, one record per line: H (heading found), K<TAB>table|list, C<TAB>header cell,
# R (a table row) then D<TAB>cell per cell, I<TAB>list item.
TK_SEC_AWK='
function trim(s) { sub(/^ +/, "", s); sub(/ +$/, "", s); return s }
function ncells(s, arr,   i, n) {
  s = trim(s)
  sub(/^[|]/, "", s)
  if (s ~ /[|]$/ && s !~ /\\[|]$/) sub(/[|]$/, "", s)
  gsub(/\\[|]/, SEP, s)
  n = split(s, arr, "|")
  for (i = 1; i <= n; i++) { gsub(SEP, "|", arr[i]); arr[i] = trim(arr[i]) }
  return n
}
function isdelim(s,   i) {
  if (s !~ /[|]/) return 0
  dn = ncells(s, dc)
  if (dn < 1) return 0
  for (i = 1; i <= dn; i++) if (dc[i] !~ /^:?-+:?$/) return 0
  return 1
}
function isbreak(s,   t) { t = s; gsub(/ /, "", t); return (t ~ /^(---+|[*][*][*]+|___+)$/) }
function isitem(s,   t, mk) {
  if (!match(s, /^ *([-*+]|[0-9]+[.)]) +[^ ]/)) return 0
  match(s, /^ */); ind = RLENGTH
  t = substr(s, ind + 1)
  match(t, /^[^ ]+/); mk = substr(t, 1, RLENGTH)
  if (length(mk) > 10) return 0
  itext = trim(substr(t, RLENGTH + 1))
  return 1
}
function fencechar(s) {
  if (s ~ /^ ? ? ?```/) return "`"
  if (s ~ /^ ? ? ?~~~/) return "~"
  return ""
}
function flushitem() {
  if (have) { nrows++; if (nrows <= maxrows) print "I\t" cur; have = 0; cur = "" }
}
function closeblock() {
  if (mode == 2) flushitem()
  if (mode > 0) { mode = 0; done = 1 }
}
BEGIN {
  SEP = "\001"
  want = ENVIRON["TK_HEADING"]; maxrows = ENVIRON["TK_ROWS"] + 0; maxcols = ENVIRON["TK_COLS"] + 0
}
{
  line = $0; sub(/\r$/, "", line); gsub(/\t/, " ", line); gsub(SEP, "", line)
  fc = fencechar(line)
  if (fence) {
    t = trim(line)
    if (fc == fch && ((fch == "`" && t ~ /^`+$/) || (fch == "~" && t ~ /^~+$/))) fence = 0
    next
  }
  if (fc != "") { fence = 1; fch = fc; if (inx) closeblock(); next }
  hd = 0
  if (line ~ /^ ? ? ?#+ +[^ ]/) {
    t = line; sub(/^ */, "", t); match(t, /^#+/); hd = RLENGTH
    if (hd > 6) hd = 0
    else {
      txt = trim(substr(t, hd + 1))
      if (txt ~ / #+$/) { sub(/ #+$/, "", txt); txt = trim(txt) }
    }
  }
  if (hd > 0) {
    if (!found && txt == want) { found = 1; inx = 1; d = hd; print "H"; next }
    if (inx) { closeblock(); if (hd <= d) { inx = 0; done = 1 } }
    next
  }
  if (!inx || done) next
  if (trim(line) == "") {
    if (mode == 1) closeblock()
    prev = ""
    next
  }
  if (mode == 1) {
    if (line ~ /[|]/) {
      nrows++
      if (nrows <= maxrows) {
        print "R"
        n = ncells(line, rc)
        for (i = 1; i <= n && i <= maxcols; i++) print "D\t" rc[i]
      }
    } else closeblock()
    next
  }
  if (mode == 2) {
    match(line, /^ */); li = RLENGTH
    it = (!isbreak(line) && isitem(line))
    if (it && li == lvl) { flushitem(); cur = itext; have = 1 }
    else if (it && li < lvl) closeblock()
    else if (li > lvl) cur = cur " " trim(line)
    else closeblock()
    next
  }
  if (prev != "" && line ~ /[|]/ && isdelim(line)) {
    hn = ncells(prev, hc)
    if (hn >= 1 && hn == dn) {
      print "K\ttable"
      for (i = 1; i <= hn && i <= maxcols; i++) print "C\t" hc[i]
      mode = 1; nrows = 0; prev = ""
      next
    }
  }
  if (!isbreak(line) && isitem(line) && ind <= 3) {
    print "K\tlist"
    mode = 2; lvl = ind; cur = itext; have = 1; nrows = 0; prev = ""
    next
  }
  prev = (line ~ /[|]/) ? line : ""
}
END { if (mode == 2) flushitem() }
'
TK_SEC_JQ='
def refs: [scan("(?<![A-Za-z0-9_&/#])#([0-9]{1,7})(?![A-Za-z0-9_])") | .[0] | tonumber | select(. >= 1)] | unique | .[0:10];
(split("\n") | map(select(length > 0))) as $L
| (reduce $L[] as $l ({kind: "", cols: [], rows: []};
    if ($l | startswith("K\t")) then .kind = $l[2:]
    elif ($l | startswith("C\t")) then .cols += [$l[2:]]
    elif $l == "R" then .rows += [[]]
    elif ($l | startswith("D\t")) then ((.rows | length) - 1) as $k | .rows[$k] += [$l[2:]]
    elif ($l | startswith("I\t")) then .rows += [$l[2:]]
    else . end)) as $p
| if $p.kind == "table" then
    ($p.cols[0:$maxcols]) as $cols
    | ($cols | length) as $w
    | ($p.rows[0:$maxrows] | map(((. + [range(0; $w) | ""])[0:$w] | map(.[0:$maxcell])))) as $rows
    | {id: $id, title: $title, kind: "table", source: $source,
       columns: ($cols | map(.[0:$maxcell])),
       rows: ($rows | map({cells: ., issues: (join(" ") | refs)})),
       truncated: ((($p.cols | length) > $maxcols) or (($p.rows | length) > $maxrows)
                   or any($p.cols[0:$maxcols][]; length > $maxcell)
                   or any(($p.rows[0:$maxrows][] | .[0:$w][]); length > $maxcell))}
  else
    {id: $id, title: $title, kind: "list", source: $source,
     rows: ($p.rows[0:$maxrows] | map({text: .[0:$maxcell], issues: (.[0:$maxcell] | refs)})),
     truncated: ((($p.rows | length) > $maxrows) or any($p.rows[0:$maxrows][]; length > $maxcell))}
  end'

warns=""
sec_files=""
printf '[]\n' > "$work/sections.json"
printf '[]\n' > "$work/refs.json"
if [ "$sec_n" -gt 0 ]; then
  nl=$'\n'
  tree_sha="$(jq -r '.commit.commit.tree.sha // empty' "$work/branch.json" 2>/dev/null)"
  [ -n "$tree_sha" ] || tree_sha="$main_sha"
  case "$tree_sha" in
    *[!0-9a-f]*) q_fail tree ;;
  esac
  case "${#tree_sha}" in
    40|64) : ;;
    *) q_fail tree ;;
  esac
  if ! out="$(gh api "repos/$nwo/git/trees/$tree_sha?recursive=1" </dev/null 2>/dev/null)"; then q_fail tree; fi
  printf '%s\n' "$out" > "$work/tree.json"
  jq -e '(.tree | type) == "array"' "$work/tree.json" >/dev/null 2>&1 || q_fail tree
  si=0
  while [ "$si" -lt "$sec_n" ]; do
    sid="${sec_id[$si]}"
    spath="${sec_path[$si]}"
    shead="${sec_head[$si]}"
    entry="$(jq -r --arg p "$spath" 'first(.tree[] | objects | select(.path == $p)) | [(.mode // "" | tostring), (.sha // "" | tostring), (.size // "" | tostring), (.type // "" | tostring)] | join(" ")' "$work/tree.json" 2>/dev/null)" || q_fail tree
    emode=""; esha=""; esize=""; etype=""
    if [ -n "$entry" ]; then read -r emode esha esize etype <<<"$entry"; fi
    warn_tok=""
    if [ "$etype" != "blob" ] || { [ "$emode" != "100644" ] && [ "$emode" != "100755" ]; }; then
      warn_tok="section-missing"
    else
      case "$esize" in
        ""|*[!0-9]*) q_fail tree ;;
      esac
      case "$esha" in
        ""|*[!0-9a-f]*) q_fail tree ;;
      esac
      if [ "$esize" -gt "$MAX_FILE_BYTES" ]; then warn_tok="section-too-large"; fi
    fi
    if [ -z "$warn_tok" ]; then
      if ! out="$(gh api "repos/$nwo/git/blobs/$esha" </dev/null 2>/dev/null)"; then q_fail section; fi
      printf '%s\n' "$out" > "$work/blob-$si.json"
      jq -e '.encoding == "base64" and ((.content | type) == "string")' "$work/blob-$si.json" >/dev/null 2>&1 || q_fail section
      if ! jq -r '.content | gsub("[\r\n]"; "")' "$work/blob-$si.json" 2>/dev/null | base64 --decode > "$work/sec-$si.md" 2>/dev/null; then q_fail section; fi
      awk_out="$(TK_HEADING="$shead" TK_ROWS=$((MAX_ROWS + 1)) TK_COLS=$((MAX_COLS + 1)) LC_ALL=C awk "$TK_SEC_AWK" "$work/sec-$si.md" 2>/dev/null)" || skip "build-failed"
      has_h=0; has_k=0
      case "$nl$awk_out$nl" in *"${nl}H${nl}"*) has_h=1 ;; esac
      case "$nl$awk_out$nl" in *"${nl}K"$'\t'*) has_k=1 ;; esac
      if [ "$has_h" -eq 0 ]; then
        warn_tok="section-no-heading"
      elif [ "$has_k" -eq 0 ]; then
        warn_tok="section-empty"
      else
        printf '%s\n' "$awk_out" | jq -R -s -c --arg id "$sid" --arg title "$shead" --arg source "$spath#$shead" \
          --argjson maxrows "$MAX_ROWS" --argjson maxcols "$MAX_COLS" --argjson maxcell "$MAX_CELL" \
          "$TK_SEC_JQ" > "$work/sec-$si.json" || skip "build-failed"
        sec_files="$sec_files $work/sec-$si.json"
      fi
    fi
    if [ -n "$warn_tok" ]; then warns="${warns}warn=${warn_tok} section=${sid}${nl}"; fi
    si=$((si + 1))
  done
  if [ -n "$sec_files" ]; then
    # shellcheck disable=SC2086
    jq -s -c '.' $sec_files > "$work/sections.json" || skip "build-failed"
  fi
  # Closed issues that section rows reference by #<n> and the issue set above does not hold.
  want="$(jq -c -n --slurpfile s "$work/sections.json" --slurpfile o "$work/open.json" --slurpfile c "$work/closed.json" --argjson max "$MAX_REFS" \
    '([$o[0][].number, $c[0][].number]) as $have
     | [$s[0][].rows[].issues[]] | unique | map(select(. as $n | any($have[]; . == $n) | not)) | .[0:$max]' 2>/dev/null)" || skip "build-failed"
  if [ "$want" != "[]" ]; then
    if ! out="$(gh issue list --state closed --limit "$REF_LIMIT" --json "$ISSUE_FIELDS" </dev/null 2>/dev/null)"; then q_fail issues-refs; fi
    printf '%s\n' "$out" > "$work/refs-all.json"
    jq -e 'type == "array"' "$work/refs-all.json" >/dev/null 2>&1 || q_fail issues-refs
    jq -c --argjson want "$want" '[.[] | select(.number as $n | any($want[]; . == $n))]' "$work/refs-all.json" > "$work/refs.json" || q_fail issues-refs
  fi
fi

checked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The recent window starts RECENT_DAYS before checkedAt, computed by jq from that one timestamp (no
# second `date` call). Only its date part reaches the search string, and only when well-formed.
recent_since="$(jq -rn --arg at "$checked_at" --argjson d "$RECENT_DAYS" '$at | fromdateiso8601 - ($d * 86400) | todate' 2>/dev/null)"
recent_day="${recent_since%%T*}"
case "$recent_day" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
  *) skip "build-failed" ;;
esac
if ! out="$(gh issue list --state closed --search "is:issue closed:>=$recent_day" --limit "$RECENT_LIMIT" --json "$RECENT_FIELDS" 2>/dev/null)"; then q_fail issues-recent; fi
printf '%s\n' "$out" > "$work/recent.json"
jq -e 'type == "array"' "$work/recent.json" >/dev/null 2>&1 || q_fail issues-recent
recent_trunc=false
[ "$(jq 'length' "$work/recent.json")" -ge "$RECENT_LIMIT" ] && recent_trunc=true

# read_auto_approval — auto_appr=true when the working-tree CLAUDE.md has a "Plan auto-approval
# policy" heading, or an "Autonomy mode" heading whose section's first fence has a first `mode:`
# line valued `autonomous` (the doctor's rule, bin/check-harness.sh). Headings and fences are read
# fence-aware: a heading inside a fenced block counts for nothing.
auto_appr=false
read_auto_approval() {
  local cm="$top/CLAUDE.md"
  [ -f "$cm" ] || return 0
  auto_appr="$(awk '
    /^```/ {
      f = !f
      if (inA && !fdone) { if (f) { inf = 1 } else { inf = 0; fdone = 1 } }
      next
    }
    !f && /^#+[[:space:]]/ {
      match($0, /^#+/); dep = RLENGTH
      if (inA && dep <= ad) { inA = 0; inf = 0 }
      if ($0 ~ /^#+[[:space:]]+Plan auto-approval policy[[:space:]]*$/) { on = 1 }
      if ($0 ~ /^#+[[:space:]]+Autonomy mode[[:space:]]*$/) { inA = 1; ad = dep; fdone = 0; inf = 0; mseen = 0 }
      next
    }
    inf && !mseen && /^[[:space:]]*mode:/ {
      mseen = 1
      v = $0; sub(/^[[:space:]]*mode:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      if (v == "autonomous") { on = 1 }
    }
    END { print (on ? "true" : "false") }' "$cm")"
  [ "$auto_appr" = "true" ] || auto_appr=false
}
read_auto_approval

jq -n -c \
  --slurpfile repo "$work/repo.json" \
  --slurpfile ms "$work/milestones.json" \
  --slurpfile open "$work/open.json" \
  --slurpfile closed "$work/closed.json" \
  --slurpfile prs "$work/prs.json" \
  --slurpfile health "$work/health.json" \
  --slurpfile secs "$work/sections.json" \
  --slurpfile refs "$work/refs.json" \
  --arg nwo "$nwo" --arg branch "$default_branch" --arg sha "$main_sha" --arg at "$checked_at" \
  --argjson trunc "$trunc_shell" \
  --arg l_prop "$LBL_PROPOSED" --arg l_appr "$LBL_APPROVED" --arg l_pro "$LBL_PR_OPEN" \
  --arg l_blk "$LBL_BLOCKED" --arg l_nh "$LBL_NEEDS_HUMAN" --arg l_np "$LBL_NO_PLAN" \
  --arg l_th "$LBL_TRIAGED_HELD" --arg lmap "$ls_lines" '
  def lbls: [(.labels // [])[] | .name];
  def tolist: if (. | type) == "array" then . else [] end;
  def lmap: [$lmap | split("\n")[] | select(length > 0) | split("\t") | {l: .[0], s: .[1]}];
  def mapped($l): ([$l[] | tostring | ascii_downcase]) as $ll
    | [lmap[] | select(.l as $x | any($ll[]; . == $x)) | .s] | .[0];
  def state_of:
    lbls as $l | mapped($l) as $m
    | if .state == "CLOSED" then (if .stateReason == "NOT_PLANNED" then "not-planned" else "done" end)
      elif any($l[]; . == $l_nh) then "needs-human"
      elif any($l[]; . == $l_blk) then "blocked"
      elif any($l[]; . == $l_pro) then "pr-open"
      elif any($l[]; . == $l_appr) then "approved"
      elif any($l[]; . == $l_th) then "parked"
      elif $m != null then $m
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
      health: $health[0],
      truncated: ($trunc or any($all[]; ._more)),
      milestones: ([$mraw[]
        | .number as $n
        | {number: .number, title: .title, url: .html_url, dueOn: (.due_on // null),
           open: ($issues | map(select(.milestone == $n and (.state != "done") and (.state != "not-planned"))) | length),
           closed: ($fin | map(select(.milestone == $n)) | length)}]
        | sort_by([(.dueOn == null), (.dueOn // ""), .number])),
      issues: $issues,
      counts: (reduce $issues[] as $i ({}; .[$i.state] += 1)
        | . + {total: ($issues | length), waiting: ($issues | map(select(.waiting)) | length)}),
      sections: ($secs[0] | tolist),
      refs: ([($refs[0] | tolist)[] | {number, title, url, state: state_of}] | sort_by(.number))
    }' > "$work/state.json" || skip "build-failed"

# Second pass over the finished snapshot: what shipped in the window, every open PR, and what waits
# on the maintainer. PR bodies are read only here, and only the four verifier tokens leave them.
ACTIVITY_JQ='
  def tolist: if (. | type) == "array" then . else [] end;
  def login: if type == "object" then (.login // null) else null end;
  def linked:
    (.headRefName // "") as $h
    | if ($h | test("^claude/[0-9]+-")) then ($h | capture("^claude/(?<n>[0-9]+)-").n | tonumber) else null end;
  def ci_of:
    (.statusCheckRollup | tolist) as $r
    | if ($r | length) == 0 then "none"
      else ([$r[] | (.conclusion // .state // "PENDING") | tostring | ascii_upcase]) as $s
        | if any($s[]; IN("SUCCESS", "NEUTRAL", "SKIPPED", "", "PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED", "WAITING", "REQUESTED") | not) then "failing"
          elif any($s[]; IN("", "PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED", "WAITING", "REQUESTED")) then "pending"
          else "passing" end
      end;
  def approved_by_other($a):
    any((.latestReviews | tolist)[]; .state == "APPROVED" and ((.author | login) != null) and ((.author | login) != $a));
  def verifier_of($n):
    if $n == null then null
    else ((.body // "") | tostring | split("\n") | map(sub("\r$"; ""))
      | map(capture("^<!-- harness-status: stage=verifier issue=(?<i>[0-9]+) outcome=(?<o>pass|fail|incomplete|died) ")?)
      | map(select(.i == ($n | tostring)))
      | if length == 0 then null else (last | .o) end)
    end;
  ($prs[0] | tolist) as $praw
  | ($gclear[0] | tolist) as $clear
  | ($ri[0] | tolist) as $iraw
  | (["needs-human", "ci-failing", "governance-path", "awaiting-review", "plan-proposed", "solo-merge"]) as $order
  | ([$praw[]
      | select(.state == "MERGED" and ((.mergedAt | type) == "string") and .mergedAt >= $cut)
      | linked as $n
      | (.author | login) as $a
      | {kind: "pr", number: .number, title: (.title // ""), url: .url, mergedAt: .mergedAt,
         author: $a, mergedBy: (.mergedBy | login), issue: $n, ci: ci_of, verifier: verifier_of($n),
         soloMerge: ($a != null and $a == (.mergedBy | login) and (approved_by_other($a) | not))}]) as $rpr
  | ([$iraw[]
      | select(.state == "CLOSED" and ((.closedAt | type) == "string") and .closedAt >= $cut)
      | {kind: "issue", number: .number, title: (.title // ""), url: .url, closedAt: .closedAt,
         state: (if .stateReason == "NOT_PLANNED" then "not-planned" else "done" end)}]) as $rissue
  | ([$praw[]
      | select(.state == "OPEN")
      | linked as $n
      | (.author | login) as $a
      | ci_of as $ci
      | .number as $pn
      | (.isDraft == true) as $d
      | {number: .number, title: (.title // ""), url: .url, author: $a, headRefName: (.headRefName // ""),
         issue: $n, draft: $d, ci: $ci,
         reasons: (if $d then []
                   else [(if $ci == "failing" then "ci-failing" else empty end),
                         (if any($clear[]; . == $pn) then empty else "governance-path" end),
                         (if approved_by_other($a) then empty else "awaiting-review" end)] end)}]
      | sort_by(.number)) as $open
  | ([.issues[] | select(.state == "needs-human") | {kind: "issue", number: .number, reason: "needs-human"}]
     + (if $auto then [] else [.issues[] | select(.state == "planned") | {kind: "issue", number: .number, reason: "plan-proposed"}] end)
     + [$open[] | select((.reasons | length) > 0) | {kind: "pr", number: .number, reason: .reasons[0]}]
     + [$rpr[] | select(.soloMerge) | {kind: "pr", number: .number, reason: "solo-merge"}]
     | sort_by([(.reason as $r | $order | index($r)), .number])) as $wait
  | . + {recentSince: $cut,
         recent: (($rpr + $rissue) | sort_by([(.mergedAt // .closedAt), .kind, .number]) | reverse),
         openPrs: $open,
         waitingOnYou: $wait}
  | .truncated = (.truncated or $rtrunc)'
jq -c --slurpfile prs "$work/prs.json" --slurpfile ri "$work/recent.json" \
  --slurpfile gclear "$work/gov-clear.json" \
  --arg cut "$recent_since" --argjson auto "$auto_appr" --argjson rtrunc "$recent_trunc" \
  "$ACTIVITY_JQ" "$work/state.json" > "$work/state2.json" || skip "build-failed"
mv "$work/state2.json" "$work/state.json" || skip "build-failed"

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
printf '%s' "$warns"
echo "result=ready"
exit 0
