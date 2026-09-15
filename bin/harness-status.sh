#!/usr/bin/env bash
#
# harness-status.sh
# One-shot status of the issue workflow, split by WHO acts next. Output is JSON:
#
#   harness_will_handle:
#     unplanned          : open issues with no plan-* label (next planner run plans them)
#     in_revision        : plan-proposed issues with unaddressed maintainer feedback (next planner run revises)
#     ready_to_implement : plan-approved, not pr-open / impl-blocked (next implementer run)
#   waiting_on_human:
#     plans_to_review    : plan-proposed issues with NO new maintainer feedback — your review/approval
#     prs_to_review      : open claude/* PRs, with a coarse CI state — your review/merge
#     blocked            : impl-blocked issues — remove the label to retry
#   degraded            : boolean (#284/#285) — true iff degraded_reasons is non-empty; a
#                         discovery query failed closed this run, so a bucket above may
#                         under-report the true queue rather than reflect it
#   degraded_reasons    : array of "planning.<key>" / "implementation.<key>" strings (planning
#                         half first) — computed by a GENERIC rule (see the degraded_reasons
#                         assignment below): every key in either find-planning-work.sh's or
#                         find-implementation-work.sh's own `counts` object whose name ends in
#                         "_unavailable" and whose value is exactly true becomes one entry, with
#                         no per-key enumeration to keep in sync as either script grows a new
#                         `*_unavailable` flag — already covers initial_query_unavailable,
#                         candidates_query_unavailable, author_association_unavailable, and (#284)
#                         ready_query_unavailable. counts.fetch_failures on either script
#                         deliberately does not participate: it drops one issue, not a whole
#                         bucket, and already produces its own per-issue warn line on stderr.
#   counts               : per-bucket counts + human_actions (total items waiting on you) +
#                         degraded (mirrors the top-level boolean, so a reader who only looks at
#                         counts still sees it)
#
# Read-only. Used by the issue-cycle skill's closing report, and handy standalone:
# "what is waiting on me?" Requires: gh (authenticated), jq, and the other harness
# scripts on the PATH. Run from anywhere inside the repo.
set -euo pipefail

LIMIT=100

planning=$(find-planning-work.sh)
implementation=$(find-implementation-work.sh)

# degraded_reasons (#284/#285) — see the header's own paragraph above for the generic rule this
# implements: select every `*_unavailable: true` key from EITHER script's own `counts` object,
# planning half first, implementation half second.
degraded_reasons=$(jq -n --argjson p "$planning" --argjson i "$implementation" '
  [ ($p.counts // {}) | to_entries[] | select((.key | endswith("_unavailable")) and .value == true) | "planning." + .key ]
  + [ ($i.counts // {}) | to_entries[] | select((.key | endswith("_unavailable")) and .value == true) | "implementation." + .key ]
')

unplanned=$(jq .needs_initial_plan <<<"$planning")
in_revision=$(jq .needs_revision <<<"$planning")
ready=$(jq .ready <<<"$implementation")

# plan-proposed issues NOT in the revision bucket = awaiting the human's review
proposed=$(gh issue list \
  --search "is:open is:issue label:plan-proposed -label:plan-approved -label:no-plan" \
  --json number,title,url --limit "$LIMIT")
plans_to_review=$(jq --argjson rev "$in_revision" \
  '[ .[] | select(.number as $n | ($rev | map(.number) | index($n)) | not) ]' <<<"$proposed")

blocked=$(gh issue list \
  --search "is:open is:issue label:impl-blocked" \
  --json number,title,url --limit "$LIMIT")

# Open claude/* PRs with a coarse CI state derived from statusCheckRollup.
# Rollup items are CheckRuns (status/conclusion) or StatusContexts (state); normalise
# via (conclusion // state // "PENDING").
prs_to_review=$(gh pr list --state open \
  --json number,title,url,headRefName,statusCheckRollup --limit "$LIMIT" \
  | jq '[ .[]
      | select(.headRefName | startswith("claude/"))
      | ([ (.statusCheckRollup // [])[] | (.conclusion // .state // "PENDING") | ascii_upcase ]) as $s
      | {number, title, url,
         ci: (if ($s | length) == 0 then "none"
              elif ($s | map(select(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED")) | length) > 0 then "failing"
              elif ($s | map(select(. == "PENDING" or . == "QUEUED" or . == "IN_PROGRESS" or . == "EXPECTED" or . == "")) | length) > 0 then "pending"
              else "passing" end)} ]')

jq -n \
  --argjson unplanned "$unplanned" \
  --argjson in_revision "$in_revision" \
  --argjson ready "$ready" \
  --argjson plans "$plans_to_review" \
  --argjson prs "$prs_to_review" \
  --argjson blocked "$blocked" \
  --argjson dr "$degraded_reasons" \
  '(($dr | length) > 0) as $deg
   | {
     harness_will_handle: {unplanned: $unplanned, in_revision: $in_revision, ready_to_implement: $ready},
     waiting_on_human:    {plans_to_review: $plans, prs_to_review: $prs, blocked: $blocked},
     degraded: $deg,
     degraded_reasons: $dr,
     counts: {
       unplanned: ($unplanned | length),
       in_revision: ($in_revision | length),
       ready_to_implement: ($ready | length),
       plans_to_review: ($plans | length),
       prs_to_review: ($prs | length),
       blocked: ($blocked | length),
       human_actions: (($plans | length) + ($prs | length) + ($blocked | length)),
       degraded: $deg
     }
   }'
