#!/usr/bin/env bash
#
# find-planning-work.sh
# Lists the GitHub issues the planner should act on, as JSON with two buckets:
#   needs_initial_plan : open issues with NO plan-* label (never planned yet)
#   needs_revision     : open issues labelled plan-proposed (and not plan-approved) that have
#                        a comment posted by a maintainer (OWNER/MEMBER/COLLABORATOR) AFTER the
#                        most recent trusted plan comment — i.e. feedback the planner hasn't
#                        addressed yet.
#
# Issues labelled "no-plan" are excluded from BOTH buckets — add that label to keep an issue
# (tracking, discussion, question, etc.) out of the planning workflow entirely.
#
# Plan comments are identified by the marker "<!-- planner-plan -->" that the issue-planner
# skill puts at the top of every plan it posts — the marker still discriminates plans from
# feedback, but a trusted association (see TRUSTED_ASSOCIATIONS below) is now ALSO required for
# a comment to be recognised as either: an untrusted comment never becomes the latest plan and
# never counts as feedback, regardless of the marker or its position in the thread. Untrusted
# comments posted after the latest trusted plan are reported in the untrusted_comments output
# bucket instead of being silently dropped, so the human still sees them.
#
# Output (JSON): needs_initial_plan, needs_revision (as before, unchanged shape) plus
# untrusted_comments — an array of {number, title, url, comments: [{author, association,
# createdAt, has_plan_marker}, ...]}, one entry per issue that has at least one untrusted
# comment posted after its latest trusted plan (or, if it has no trusted plan yet, any untrusted
# comment). counts gains untrusted_comments (total untrusted comments reported, across all
# issues), untrusted_plan_markers (how many of those carried the plan marker — ignored for plan
# selection because their author wasn't trusted), and missing_association (how many comments,
# across all issues, carried no authorAssociation field at all — treated as untrusted,
# fail-closed, per the warn stems below).
#
# Skipped automatically:
#   - plan-proposed with no newer trusted non-plan comment -> awaiting your review, nothing to do
#   - plan-approved                                -> handed off to the implementer
#
# To request a revision: a maintainer (OWNER/MEMBER/COLLABORATOR) comments on the issue. To
# approve: add the plan-approved label.
#
# Requires: gh (authenticated), jq. Run from anywhere inside the repo.
set -euo pipefail

LIMIT=100
PLAN_MARKER="<!-- planner-plan -->"

# GitHub's authorAssociation enum: OWNER, MEMBER, COLLABORATOR, CONTRIBUTOR,
# FIRST_TIME_CONTRIBUTOR, FIRST_TIMER, NONE. Only the first three carry repo
# authority, so only they produce binding feedback or a recognised plan comment;
# everything else is reported in untrusted_comments and never acted on. To act on an
# outside contributor's suggestion, a maintainer comments themselves.
TRUSTED_ASSOCIATIONS="OWNER MEMBER COLLABORATOR"

needs_initial_plan=$(gh issue list \
  --search "is:open is:issue -label:plan-proposed -label:plan-approved -label:no-plan" \
  --json number,title,url \
  --limit "$LIMIT")

# Candidates for revision: awaiting review, not yet approved, not opted out.
candidates=$(gh issue list \
  --search "is:open is:issue label:plan-proposed -label:plan-approved -label:no-plan" \
  --json number \
  --limit "$LIMIT" --jq '.[].number' | tr -d '\r')

needs_revision="[]"
untrusted_comments="[]"
fetch_failures=0
untrusted_comment_total=0
untrusted_plan_markers=0
missing_association=0
for n in $candidates; do
  # Tolerate per-issue failures: one transient gh/API error must not kill the whole
  # discovery run (matters for unattended/scheduled runs). The issue is simply
  # reconsidered next time.
  if ! issue=$(gh issue view "$n" --json number,title,url,comments 2>/dev/null); then
    echo "warn: could not fetch issue #$n — skipping it this run" >&2
    fetch_failures=$((fetch_failures+1))
    continue
  fi
  result=$(printf '%s' "$issue" | jq --arg m "$PLAN_MARKER" --arg trusted "$TRUSTED_ASSOCIATIONS" '
    ($trusted | split(" ")) as $ok
    | (.comments // []) as $c
    | ($c | map(select( ((.authorAssociation // "") | ascii_upcase) as $assoc | ($ok | index($assoc)) != null ))) as $trustedC
    | ([ $trustedC[] | select(.body | contains($m)) | .createdAt ] | max) as $lastPlan
    | {
        has_feedback: (
          if $lastPlan == null then false
          else ([ $trustedC[]
                  | select((.body | contains($m)) | not)
                  | select(.createdAt > $lastPlan) ] | length) > 0
          end
        ),
        untrusted: [ $c[]
          | select( ((.authorAssociation // "") | ascii_upcase) as $assoc | ($ok | index($assoc)) == null )
          | select(.createdAt > ($lastPlan // ""))
          | { author: (.author.login // "unknown"),
              association: (.authorAssociation // "MISSING"),
              createdAt: .createdAt,
              has_plan_marker: (.body | contains($m)) } ],
        missing_association: ([ $c[] | select(has("authorAssociation") | not) ] | length)
      }
  ')

  has_feedback=$(printf '%s' "$result" | jq -r '.has_feedback')
  if [ "$has_feedback" = "true" ]; then
    entry=$(printf '%s' "$issue" | jq '{number, title, url}')
    needs_revision=$(jq -n --argjson arr "$needs_revision" --argjson e "$entry" '$arr + [$e]')
  fi

  untrusted_arr=$(printf '%s' "$result" | jq -c '.untrusted')
  issue_untrusted_count=$(printf '%s' "$untrusted_arr" | jq 'length')
  if [ "$issue_untrusted_count" -gt 0 ]; then
    entry=$(printf '%s' "$issue" | jq --argjson u "$untrusted_arr" '{number, title, url, comments: $u}')
    untrusted_comments=$(jq -n --argjson arr "$untrusted_comments" --argjson e "$entry" '$arr + [$e]')
    untrusted_comment_total=$((untrusted_comment_total+issue_untrusted_count))
  fi

  # warn (a): an untrusted plan-marker comment is ignored for plan selection — one line per
  # such comment, so the human sees exactly which comment(s) shadowed nothing.
  marker_pairs=$(printf '%s' "$untrusted_arr" | jq -r '.[] | select(.has_plan_marker) | "\(.author)/\(.association)"')
  if [ -n "$marker_pairs" ]; then
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      echo "warn: issue #$n: plan marker from an untrusted author ($pair) ignored for plan selection" >&2
      untrusted_plan_markers=$((untrusted_plan_markers+1))
    done <<<"$marker_pairs"
  fi

  # warn (b): fail-closed — a comment with no authorAssociation field at all is treated as
  # untrusted rather than trusted or crashing the script.
  issue_missing=$(printf '%s' "$result" | jq '.missing_association')
  if [ "$issue_missing" -gt 0 ]; then
    echo "warn: issue #$n: $issue_missing comment(s) have no authorAssociation field, treated as untrusted" >&2
    missing_association=$((missing_association+issue_missing))
  fi
done

# candidate_count: how many plan-proposed issues were examined for feedback (used for
# the truncation flag — if either query hit LIMIT, the buckets may be incomplete).
candidate_count=$(printf '%s\n' $candidates | grep -c . || true)

jq -n \
  --argjson initial "$needs_initial_plan" \
  --argjson revision "$needs_revision" \
  --argjson untrusted "$untrusted_comments" \
  --argjson ff "$fetch_failures" \
  --argjson cc "$candidate_count" \
  --argjson limit "$LIMIT" \
  --argjson uct "$untrusted_comment_total" \
  --argjson upm "$untrusted_plan_markers" \
  --argjson ma "$missing_association" \
  '{needs_initial_plan: $initial, needs_revision: $revision, untrusted_comments: $untrusted,
    counts: {initial: ($initial | length), revision: ($revision | length),
             fetch_failures: $ff,
             truncated: ((($initial | length) >= $limit) or ($cc >= $limit)),
             untrusted_comments: $uct,
             untrusted_plan_markers: $upm,
             missing_association: $ma}}'
