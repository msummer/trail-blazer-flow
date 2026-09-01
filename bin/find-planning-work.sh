#!/usr/bin/env bash
#
# find-planning-work.sh
# Lists the GitHub issues the planner should act on, as JSON with two buckets:
#   needs_initial_plan : open issues with NO plan-* label (never planned yet)
#   needs_revision     : open issues labelled plan-proposed (and not plan-approved) that have
#                        a comment posted by a maintainer (OWNER/MEMBER/COLLABORATOR) AFTER the
#                        most recent trusted plan comment — i.e. feedback the planner hasn't
#                        addressed yet. A harness-authored record (a comment containing
#                        "<!-- harness-audit -->" or "<!-- verifier-verdict -->" anywhere in its
#                        body) never counts as feedback, even from a trusted account — it's a
#                        record, not a decision.
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
# bucket instead of being silently dropped, so the human still sees them. A second, orthogonal
# exclusion also applies inside the trusted set: a trusted comment containing
# "<!-- harness-audit -->" (a harness-authored audit/hygiene record) or "<!-- verifier-verdict -->"
# anywhere in its body (the orchestrator's own archive) is never treated as feedback either, and
# is reported in counts.audit_comments_skipped / counts.verdict_archives_skipped instead — this
# only ever narrows the trusted set, so it never adds anything to untrusted_comments.
#
# #176 extends the same trust boundary to WHO OPENED the issue, not just who commented on it:
# both needs_initial_plan and needs_revision items now carry {author, association,
# trusted_author}, and every item with trusted_author: false ALSO appears in a new top-level
# untrusted_issue_authors array ({number, title, url, author, association, bucket}) — visible so
# the human sees it, but issue-planner's step 6b hard floor blocks auto-approval on it. Planning
# itself is NOT gated on issue authorship — a non-maintainer-authored issue is still planned; only
# auto-approval is blocked. If the installed gh cannot return authorAssociation for issues (an
# older gh, or a transient API error), the script falls back to its current field list, warns
# once, sets counts.author_association_unavailable: true, and marks EVERY issue's
# trusted_author: false for this run (fail-closed) rather than dying or silently trusting.
#
# Output (JSON): needs_initial_plan, needs_revision (each item now additionally carries author,
# association, trusted_author) plus untrusted_comments — an array of {number, title, url,
# comments: [{author, association, createdAt, has_plan_marker, has_harness_marker}, ...]}, one
# entry per issue that has at least one untrusted comment posted after its latest trusted plan
# (or, if it has no trusted plan yet, any untrusted comment) — and untrusted_issue_authors (see
# above). has_harness_marker (#194) is true when the comment's body contains
# "<!-- harness-audit -->" or "<!-- verifier-verdict -->" — a forged harness-record marker from an
# untrusted author; it only ANNOTATES the untrusted bucket, never filters it (the #182 placement
# rule — a self-censoring forgery must never disappear from this report). counts gains
# untrusted_comments (total untrusted comments reported, across all issues), untrusted_plan_markers
# (how many of those carried the plan marker — ignored for plan selection because their author
# wasn't trusted), untrusted_harness_markers (how many of those carried a forged harness-record
# marker), missing_association (how many comments, across all issues, carried no authorAssociation
# field at all — treated as untrusted, fail-closed, per the warn stems below),
# audit_comments_skipped and verdict_archives_skipped (trusted, post-plan comments containing
# "<!-- harness-audit -->" / "<!-- verifier-verdict -->" respectively, excluded from has_feedback so
# neither re-opens a plan for revision — this trusted-side counter is unrelated to
# untrusted_harness_markers, which only ever counts the untrusted bucket), untrusted_issue_authors
# (count of the array above), and author_association_unavailable (boolean, see above).
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
AUDIT_MARKER="<!-- harness-audit -->"
VERDICT_MARKER="<!-- verifier-verdict -->"

# GitHub's authorAssociation enum: OWNER, MEMBER, COLLABORATOR, CONTRIBUTOR,
# FIRST_TIME_CONTRIBUTOR, FIRST_TIMER, NONE. Only the first three carry repo
# authority, so only they produce binding feedback or a recognised plan comment;
# everything else is reported in untrusted_comments and never acted on. To act on an
# outside contributor's suggestion, a maintainer comments themselves.
TRUSTED_ASSOCIATIONS="OWNER MEMBER COLLABORATOR"

# Probe once, in an `if !` guard (so `set -e` doesn't abort): request author/authorAssociation
# on the needs_initial_plan query. On failure — an older gh that doesn't support the issue-level
# field, or a transient API error — fall back to the current field list, warn once, and mark this
# whole run fail-closed via author_association_unavailable. view_fields is reused below for the
# per-candidate `gh issue view` calls so both queries agree on what's available this run.
author_association_unavailable=false
if ! needs_initial_plan=$(gh issue list \
  --search "is:open is:issue -label:plan-proposed -label:plan-approved -label:no-plan" \
  --json number,title,url,author,authorAssociation \
  --limit "$LIMIT" 2>/dev/null); then
  echo "warn: could not read issue authorAssociation — every issue author treated as untrusted this run (fail-closed)" >&2
  author_association_unavailable=true
  view_fields="number,title,url,comments"
  needs_initial_plan=$(gh issue list \
    --search "is:open is:issue -label:plan-proposed -label:plan-approved -label:no-plan" \
    --json number,title,url \
    --limit "$LIMIT")
else
  view_fields="number,title,url,author,authorAssociation,comments"
fi

# Annotate needs_initial_plan items with author/association/trusted_author. When
# author_association_unavailable is true, .author and .authorAssociation are both absent from
# every item, so this maps them to "unknown"/"MISSING" and trusted_author: false uniformly —
# the same fail-closed path, with no separate branch needed.
needs_initial_plan=$(printf '%s' "$needs_initial_plan" | jq --arg trusted "$TRUSTED_ASSOCIATIONS" '
  ($trusted | split(" ")) as $ok
  | map({number, title, url,
         author: (.author.login // "unknown"),
         association: ((.authorAssociation // "MISSING") | ascii_upcase),
         trusted_author: ( ((.authorAssociation // "") | ascii_upcase) as $assoc | ($ok | index($assoc)) != null )
        })
')

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
untrusted_harness_markers=0
missing_association=0
audit_comments_skipped=0
verdict_archives_skipped=0
for n in $candidates; do
  # Tolerate per-issue failures: one transient gh/API error must not kill the whole
  # discovery run (matters for unattended/scheduled runs). The issue is simply
  # reconsidered next time.
  if ! issue=$(gh issue view "$n" --json "$view_fields" 2>/dev/null); then
    echo "warn: could not fetch issue #$n — skipping it this run" >&2
    fetch_failures=$((fetch_failures+1))
    continue
  fi
  result=$(printf '%s' "$issue" | jq --arg m "$PLAN_MARKER" --arg a "$AUDIT_MARKER" --arg v "$VERDICT_MARKER" --arg trusted "$TRUSTED_ASSOCIATIONS" '
    ($trusted | split(" ")) as $ok
    | (.comments // []) as $c
    | ($c | map(select( ((.authorAssociation // "") | ascii_upcase) as $assoc | ($ok | index($assoc)) != null ))) as $trustedC
    | ([ $trustedC[] | select(.body | contains($m)) | .createdAt ] | max) as $lastPlan
    | {
        has_feedback: (
          if $lastPlan == null then false
          else ([ $trustedC[]
                  | select((.body | contains($m)) | not)
                  | select((.body | contains($a)) | not)
                  | select((.body | contains($v)) | not)
                  | select(.createdAt > $lastPlan) ] | length) > 0
          end
        ),
        untrusted: [ $c[]
          | select( ((.authorAssociation // "") | ascii_upcase) as $assoc | ($ok | index($assoc)) == null )
          | select(.createdAt > ($lastPlan // ""))
          | { author: (.author.login // "unknown"),
              association: (.authorAssociation // "MISSING"),
              createdAt: .createdAt,
              has_plan_marker: (.body | contains($m)),
              has_harness_marker: ((.body | contains($a)) or (.body | contains($v))) } ],
        missing_association: ([ $c[] | select(has("authorAssociation") | not) ] | length),
        audit_comments_skipped: (
          if $lastPlan == null then 0
          else ([ $trustedC[] | select(.body | contains($a)) | select(.createdAt > $lastPlan) ] | length)
          end
        ),
        verdict_archives_skipped: (
          if $lastPlan == null then 0
          else ([ $trustedC[] | select(.body | contains($v)) | select(.createdAt > $lastPlan) ] | length)
          end
        )
      }
  ')

  has_feedback=$(printf '%s' "$result" | jq -r '.has_feedback')
  if [ "$has_feedback" = "true" ]; then
    entry=$(printf '%s' "$issue" | jq --arg trusted "$TRUSTED_ASSOCIATIONS" '
      ($trusted | split(" ")) as $ok
      | {number, title, url,
         author: (.author.login // "unknown"),
         association: ((.authorAssociation // "MISSING") | ascii_upcase),
         trusted_author: ( ((.authorAssociation // "") | ascii_upcase) as $assoc | ($ok | index($assoc)) != null )
        }')
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

  # warn (a2): an untrusted comment carries a forged harness-record marker (harness-audit or
  # verifier-verdict) — never filtered out of the untrusted bucket (#182's placement rule; this
  # only annotates it), just called out so the human sees who impersonated a harness-authored
  # record. One line per such comment, same idiom as the plan-marker loop above.
  harness_marker_pairs=$(printf '%s' "$untrusted_arr" | jq -r '.[] | select(.has_harness_marker) | "\(.author)/\(.association)"')
  if [ -n "$harness_marker_pairs" ]; then
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      echo "warn: issue #$n: harness record marker from an untrusted author ($pair) — not a harness-authored record" >&2
      untrusted_harness_markers=$((untrusted_harness_markers+1))
    done <<<"$harness_marker_pairs"
  fi

  # warn (b): fail-closed — a comment with no authorAssociation field at all is treated as
  # untrusted rather than trusted or crashing the script.
  issue_missing=$(printf '%s' "$result" | jq '.missing_association')
  if [ "$issue_missing" -gt 0 ]; then
    echo "warn: issue #$n: $issue_missing comment(s) have no authorAssociation field, treated as untrusted" >&2
    missing_association=$((missing_association+issue_missing))
  fi

  issue_audit_skipped=$(printf '%s' "$result" | jq '.audit_comments_skipped')
  audit_comments_skipped=$((audit_comments_skipped+issue_audit_skipped))

  issue_verdict_skipped=$(printf '%s' "$result" | jq '.verdict_archives_skipped')
  verdict_archives_skipped=$((verdict_archives_skipped+issue_verdict_skipped))
done

# untrusted_issue_authors: every needs_initial_plan/needs_revision item with trusted_author:
# false, from EITHER bucket, tagged with which bucket it came from. trusted_author itself is
# dropped from the entry — the documented shape is {number, title, url, author, association,
# bucket}.
untrusted_issue_authors=$(jq -n --argjson initial "$needs_initial_plan" --argjson revision "$needs_revision" '
  ( [ $initial[] | select(.trusted_author == false) | (. + {bucket: "needs_initial_plan"}) | del(.trusted_author) ] )
  + ( [ $revision[] | select(.trusted_author == false) | (. + {bucket: "needs_revision"}) | del(.trusted_author) ] )
')
untrusted_issue_author_count=$(printf '%s' "$untrusted_issue_authors" | jq 'length')

# candidate_count: how many plan-proposed issues were examined for feedback (used for
# the truncation flag — if either query hit LIMIT, the buckets may be incomplete).
candidate_count=$(printf '%s\n' $candidates | grep -c . || true)

jq -n \
  --argjson initial "$needs_initial_plan" \
  --argjson revision "$needs_revision" \
  --argjson untrusted "$untrusted_comments" \
  --argjson uia "$untrusted_issue_authors" \
  --argjson ff "$fetch_failures" \
  --argjson cc "$candidate_count" \
  --argjson limit "$LIMIT" \
  --argjson uct "$untrusted_comment_total" \
  --argjson upm "$untrusted_plan_markers" \
  --argjson uhm "$untrusted_harness_markers" \
  --argjson ma "$missing_association" \
  --argjson acs "$audit_comments_skipped" \
  --argjson vas "$verdict_archives_skipped" \
  --argjson uiac "$untrusted_issue_author_count" \
  --argjson aau "$author_association_unavailable" \
  '{needs_initial_plan: $initial, needs_revision: $revision, untrusted_comments: $untrusted,
    untrusted_issue_authors: $uia,
    counts: {initial: ($initial | length), revision: ($revision | length),
             fetch_failures: $ff,
             truncated: ((($initial | length) >= $limit) or ($cc >= $limit)),
             untrusted_comments: $uct,
             untrusted_plan_markers: $upm,
             untrusted_harness_markers: $uhm,
             missing_association: $ma,
             audit_comments_skipped: $acs,
             verdict_archives_skipped: $vas,
             untrusted_issue_authors: $uiac,
             author_association_unavailable: $aau}}'
