#!/usr/bin/env bash
#
# find-implementation-work.sh
# Lists the issues ready for implementation, as JSON.
#   ready : open issues labelled plan-approved, NOT already pr-open and NOT impl-blocked
#
# An issue leaves this queue when it gets pr-open (a PR was opened) or impl-blocked (needs a
# human). To retry a blocked issue, remove the impl-blocked label.
#
# Recovery: if a PR is closed WITHOUT merging, its issue still carries pr-open and will never
# re-enter this queue. Remove the pr-open label (and delete the stale claude/<n>-<slug> branch)
# to requeue it.
#
# In addition to `ready`, this script now does the implementer-side half of the trust boundary
# #164 started on the planner side: for every ready issue it can fetch, it selects the approved
# plan comment and the binding post-plan comments itself, so the issue-implementer orchestrator
# reads a filtered artifact instead of applying the trusted-provenance rule from memory (#176).
#
# Output (JSON): ready (as before, unchanged shape: {number,title,url}) plus plan_selection — an
# array with one entry per ready issue that could be fetched, {number, plan, trusted_post_plan,
# untrusted_post_plan}:
#   plan               : the newest comment that both carries "<!-- planner-plan -->" and has a
#                         trusted authorAssociation (OWNER/MEMBER/COLLABORATOR, ascii_upcase
#                         normalised) — {author, association, createdAt, url}, or null when no
#                         such comment exists.
#   trusted_post_plan  : trusted comments posted after that plan, excluding the plan marker
#                         itself and any comment containing "<!-- verifier-verdict -->" (the
#                         orchestrator's own archive) or "<!-- harness-audit -->" (a harness-
#                         authored audit/hygiene record) anywhere in its body — neither is human
#                         context — same field shape.
#   untrusted_post_plan: non-trusted comments posted after the plan (or after nothing, if there
#                         is no trusted plan yet) — same field shape plus has_plan_marker, so a
#                         forged plan comment from an untrusted author is visible but never
#                         selected as `plan`.
# A plan-marker comment from an untrusted author is never selected as `plan`; it is reported in
# untrusted_post_plan with has_plan_marker: true, counted in counts.untrusted_plan_markers, and
# produces a `warn:` line. An issue with no trusted plan comment yields plan: null, a `warn:`
# line, and counts.no_trusted_plan >= 1, but stays in `ready` — the label state defines the queue;
# the implementer skill skips-and-reports it. A comment with no authorAssociation field at all is
# treated as untrusted, fail-closed, counted in counts.missing_association, and warned about.
#
# counts gains: fetch_failures (a gh issue view failure for one ready issue is survived — that
# issue gets no plan_selection entry, every other ready issue still gets one), no_trusted_plan,
# trusted_post_plan, untrusted_post_plan (totals across all issues), untrusted_plan_markers,
# verdict_archives_skipped (trusted, post-plan, verdict-marker-carrying comments excluded from
# trusted_post_plan), audit_comments_skipped (trusted, post-plan, harness-audit-marker-carrying
# comments excluded from trusted_post_plan the same way), and missing_association. ready and
# counts.ready/counts.truncated keep their current names and computation.
#
# Requires: gh (authenticated), jq. Run from anywhere inside the repo.
set -euo pipefail

LIMIT=100
PLAN_MARKER="<!-- planner-plan -->"
VERDICT_MARKER="<!-- verifier-verdict -->"
AUDIT_MARKER="<!-- harness-audit -->"

# GitHub's authorAssociation enum: OWNER, MEMBER, COLLABORATOR, CONTRIBUTOR,
# FIRST_TIME_CONTRIBUTOR, FIRST_TIMER, NONE. Only the first three carry repo
# authority, so only they produce binding feedback or a recognised plan comment;
# everything else is reported in untrusted_post_plan and never acted on. To act on an
# outside contributor's suggestion, a maintainer comments themselves.
TRUSTED_ASSOCIATIONS="OWNER MEMBER COLLABORATOR"

ready=$(gh issue list \
  --search "is:open is:issue label:plan-approved -label:pr-open -label:impl-blocked" \
  --json number,title,url \
  --limit "$LIMIT")

ready_numbers=$(printf '%s' "$ready" | jq -r '.[].number')

plan_selection="[]"
fetch_failures=0
no_trusted_plan=0
trusted_post_plan_total=0
untrusted_post_plan_total=0
untrusted_plan_markers=0
verdict_archives_skipped=0
audit_comments_skipped=0
missing_association=0
for n in $ready_numbers; do
  # Tolerate per-issue failures: one transient gh/API error must not kill the whole
  # discovery run (matters for unattended/scheduled runs). The issue is simply
  # reconsidered next time.
  if ! issue=$(gh issue view "$n" --json number,title,url,comments 2>/dev/null); then
    echo "warn: could not fetch issue #$n — skipping it this run" >&2
    fetch_failures=$((fetch_failures+1))
    continue
  fi
  result=$(printf '%s' "$issue" | jq --arg m "$PLAN_MARKER" --arg v "$VERDICT_MARKER" --arg a "$AUDIT_MARKER" --arg trusted "$TRUSTED_ASSOCIATIONS" '
    ($trusted | split(" ")) as $ok
    | (.comments // []) as $c
    | ($c | map(select( ((.authorAssociation // "") | ascii_upcase) as $assoc | ($ok | index($assoc)) != null ))) as $trustedC
    | ([ $trustedC[] | select(.body | contains($m)) | .createdAt ] | max) as $lastPlan
    | {
        plan: (
          [ $trustedC[] | select(.body | contains($m)) | select(.createdAt == $lastPlan) ] | last
          | if . == null then null
            else { author: (.author.login // "unknown"), association: (.authorAssociation // ""),
                   createdAt: .createdAt, url: (.url // null) }
            end
        ),
        trusted_post_plan: (
          if $lastPlan == null then []
          else [ $trustedC[]
                 | select((.body | contains($m)) | not)
                 | select((.body | contains($v)) | not)
                 | select((.body | contains($a)) | not)
                 | select(.createdAt > $lastPlan)
                 | { author: (.author.login // "unknown"), association: (.authorAssociation // ""),
                     createdAt: .createdAt, url: (.url // null) } ]
          end
        ),
        untrusted_post_plan: [ $c[]
          | select( ((.authorAssociation // "") | ascii_upcase) as $assoc | ($ok | index($assoc)) == null )
          | select(.createdAt > ($lastPlan // ""))
          | { author: (.author.login // "unknown"),
              association: (.authorAssociation // "MISSING"),
              createdAt: .createdAt,
              url: (.url // null),
              has_plan_marker: (.body | contains($m)) } ],
        missing_association: ([ $c[] | select(has("authorAssociation") | not) ] | length),
        verdict_archives_skipped: (
          if $lastPlan == null then 0
          else ([ $trustedC[] | select(.body | contains($v)) | select(.createdAt > $lastPlan) ] | length)
          end
        ),
        audit_comments_skipped: (
          if $lastPlan == null then 0
          else ([ $trustedC[] | select(.body | contains($a)) | select(.createdAt > $lastPlan) ] | length)
          end
        )
      }
  ')

  plan=$(printf '%s' "$result" | jq -c '.plan')
  trusted_post_plan=$(printf '%s' "$result" | jq -c '.trusted_post_plan')
  untrusted_post_plan=$(printf '%s' "$result" | jq -c '.untrusted_post_plan')
  entry=$(jq -n --argjson n "$n" --argjson p "$plan" --argjson tpp "$trusted_post_plan" --argjson upp "$untrusted_post_plan" \
    '{number: $n, plan: $p, trusted_post_plan: $tpp, untrusted_post_plan: $upp}')
  plan_selection=$(jq -n --argjson arr "$plan_selection" --argjson e "$entry" '$arr + [$e]')

  if [ "$plan" = "null" ]; then
    echo "warn: issue #$n: no maintainer-authored plan comment — nothing to implement this run" >&2
    no_trusted_plan=$((no_trusted_plan+1))
  fi

  tpp_count=$(printf '%s' "$trusted_post_plan" | jq 'length')
  trusted_post_plan_total=$((trusted_post_plan_total+tpp_count))

  upp_count=$(printf '%s' "$untrusted_post_plan" | jq 'length')
  untrusted_post_plan_total=$((untrusted_post_plan_total+upp_count))

  # warn (a): an untrusted plan-marker comment is ignored for plan selection — one line per
  # such comment, so the human sees exactly which comment(s) shadowed nothing.
  marker_pairs=$(printf '%s' "$untrusted_post_plan" | jq -r '.[] | select(.has_plan_marker) | "\(.author)/\(.association)"')
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

  issue_verdict_skipped=$(printf '%s' "$result" | jq '.verdict_archives_skipped')
  verdict_archives_skipped=$((verdict_archives_skipped+issue_verdict_skipped))

  issue_audit_skipped=$(printf '%s' "$result" | jq '.audit_comments_skipped')
  audit_comments_skipped=$((audit_comments_skipped+issue_audit_skipped))
done

jq -n \
  --argjson ready "$ready" \
  --argjson selection "$plan_selection" \
  --argjson limit "$LIMIT" \
  --argjson ff "$fetch_failures" \
  --argjson ntp "$no_trusted_plan" \
  --argjson tpp "$trusted_post_plan_total" \
  --argjson upp "$untrusted_post_plan_total" \
  --argjson upm "$untrusted_plan_markers" \
  --argjson vas "$verdict_archives_skipped" \
  --argjson acs "$audit_comments_skipped" \
  --argjson ma "$missing_association" \
  '{ready: $ready,
    plan_selection: $selection,
    counts: {ready: ($ready | length), truncated: (($ready | length) >= $limit),
             fetch_failures: $ff,
             no_trusted_plan: $ntp,
             trusted_post_plan: $tpp,
             untrusted_post_plan: $upp,
             untrusted_plan_markers: $upm,
             verdict_archives_skipped: $vas,
             audit_comments_skipped: $acs,
             missing_association: $ma}}'
