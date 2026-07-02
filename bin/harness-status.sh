#!/usr/bin/env bash
#
# harness-status.sh
# One-shot status of the issue workflow, split by WHO acts next. Output is JSON:
#
#   harness_will_handle:
#     unplanned          : open issues with no plan-* label (next planner run plans them)
#     in_revision        : plan-proposed issues with unaddressed feedback (next planner run revises)
#     ready_to_implement : plan-approved, not pr-open / impl-blocked (next implementer run)
#   waiting_on_human:
#     plans_to_review    : plan-proposed issues with NO new feedback — your review/approval
#     prs_to_review      : open claude/* PRs, with a coarse CI state — your review/merge
#     blocked            : impl-blocked issues — remove the label to retry
#   counts               : per-bucket counts + human_actions (total items waiting on you)
#
# Read-only. Used by the issue-cycle skill's closing report, and handy standalone:
# "what is waiting on me?" Requires: gh (authenticated), jq, and the other harness
# scripts on the PATH. Run from anywhere inside the repo.
set -euo pipefail

LIMIT=100

planning=$(find-planning-work.sh)
implementation=$(find-implementation-work.sh)

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
  '{
     harness_will_handle: {unplanned: $unplanned, in_revision: $in_revision, ready_to_implement: $ready},
     waiting_on_human:    {plans_to_review: $plans, prs_to_review: $prs, blocked: $blocked},
     counts: {
       unplanned: ($unplanned | length),
       in_revision: ($in_revision | length),
       ready_to_implement: ($ready | length),
       plans_to_review: ($plans | length),
       prs_to_review: ($prs | length),
       blocked: ($blocked | length),
       human_actions: (($plans | length) + ($prs | length) + ($blocked | length))
     }
   }'
