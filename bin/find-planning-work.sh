#!/usr/bin/env bash
#
# find-planning-work.sh
# Lists the GitHub issues the planner should act on, as JSON with two buckets:
#   needs_initial_plan : open issues with NO plan-* label (never planned yet)
#   needs_revision     : open issues labelled plan-proposed (and not plan-approved) that have
#                        a comment posted AFTER the most recent plan comment — i.e. feedback
#                        the planner hasn't addressed yet.
#
# Issues labelled "no-plan" are excluded from BOTH buckets — add that label to keep an issue
# (tracking, discussion, question, etc.) out of the planning workflow entirely.
#
# Plan comments are identified by the marker "<!-- planner-plan -->" that the issue-planner
# skill puts at the top of every plan it posts. Any later comment WITHOUT that marker counts
# as feedback to address. (Author can't be used to tell plans from feedback: everything is
# posted by the same gh user, so the marker is the discriminator.)
#
# Skipped automatically:
#   - plan-proposed with no newer non-plan comment -> awaiting your review, nothing to do
#   - plan-approved                                -> handed off to the implementer
#
# To request a revision: just comment on the issue. To approve: add the plan-approved label.
#
# Requires: gh (authenticated), jq. Run from anywhere inside the repo.
set -euo pipefail

LIMIT=100
PLAN_MARKER="<!-- planner-plan -->"

needs_initial_plan=$(gh issue list \
  --search "is:open is:issue -label:plan-proposed -label:plan-approved -label:no-plan" \
  --json number,title,url \
  --limit "$LIMIT")

# Candidates for revision: awaiting review, not yet approved, not opted out.
candidates=$(gh issue list \
  --search "is:open is:issue label:plan-proposed -label:plan-approved -label:no-plan" \
  --json number \
  --limit "$LIMIT" --jq '.[].number')

needs_revision="[]"
fetch_failures=0
for n in $candidates; do
  # Tolerate per-issue failures: one transient gh/API error must not kill the whole
  # discovery run (matters for unattended/scheduled runs). The issue is simply
  # reconsidered next time.
  if ! issue=$(gh issue view "$n" --json number,title,url,comments 2>/dev/null); then
    echo "warn: could not fetch issue #$n — skipping it this run" >&2
    fetch_failures=$((fetch_failures+1))
    continue
  fi
  has_feedback=$(printf '%s' "$issue" | jq --arg m "$PLAN_MARKER" '
    .comments as $c
    | ([ $c[] | select(.body | contains($m)) | .createdAt ] | max) as $lastPlan
    | if $lastPlan == null then false
      else ([ $c[]
              | select((.body | contains($m)) | not)
              | select(.createdAt > $lastPlan) ] | length) > 0
      end
  ')
  if [ "$has_feedback" = "true" ]; then
    entry=$(printf '%s' "$issue" | jq '{number, title, url}')
    needs_revision=$(jq -n --argjson arr "$needs_revision" --argjson e "$entry" '$arr + [$e]')
  fi
done

# candidate_count: how many plan-proposed issues were examined for feedback (used for
# the truncation flag — if either query hit LIMIT, the buckets may be incomplete).
candidate_count=$(printf '%s\n' $candidates | grep -c . || true)

jq -n \
  --argjson initial "$needs_initial_plan" \
  --argjson revision "$needs_revision" \
  --argjson ff "$fetch_failures" \
  --argjson cc "$candidate_count" \
  --argjson limit "$LIMIT" \
  '{needs_initial_plan: $initial, needs_revision: $revision,
    counts: {initial: ($initial | length), revision: ($revision | length),
             fetch_failures: $ff,
             truncated: ((($initial | length) >= $limit) or ($cc >= $limit))}}'
