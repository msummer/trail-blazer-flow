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
#                         context — same field shape, PLUS covered_by_approval (#194, see below).
#   untrusted_post_plan: non-trusted comments posted after the plan (or after nothing, if there
#                         is no trusted plan yet) — same field shape plus has_plan_marker and
#                         has_harness_marker (#194, see below), so a forged plan comment or a
#                         forged harness-record marker from an untrusted author is visible but
#                         never selected as `plan` or treated as a harness-authored record.
# A plan-marker comment from an untrusted author is never selected as `plan`; it is reported in
# untrusted_post_plan with has_plan_marker: true, counted in counts.untrusted_plan_markers, and
# produces a `warn:` line. An issue with no trusted plan comment yields plan: null, a `warn:`
# line, and counts.no_trusted_plan >= 1, but stays in `ready` — the label state defines the queue;
# the implementer skill skips-and-reports it. A comment with no authorAssociation field at all is
# treated as untrusted, fail-closed, counted in counts.missing_association, and warned about.
#
# #194 workstream A adds has_harness_marker to untrusted_post_plan entries — true when the
# comment's body contains "<!-- harness-audit -->" or "<!-- verifier-verdict -->", i.e. someone
# without repo authority impersonated a harness-authored record. It only ANNOTATES the untrusted
# bucket, never filters it (the #182 placement rule — a self-censoring forgery must never
# disappear from this report); counted in counts.untrusted_harness_markers and warned about, one
# line per comment, mirroring find-planning-work.sh's identical field (gate assertion 4.29 pins
# that the two scripts' flag names agree).
#
# #194 workstream B adds covered_by_approval to each trusted_post_plan entry: true when the
# comment's createdAt is not later than this entry's own approval.approved_at (below), false when
# it is later — posted after the plan-approved label, so it is reported (counts.
# post_approval_comments plus a `warn:` line) but never treated as binding — and null when
# approved_at itself is unknown, matching approval.reason's own unknown states. The existing
# counts.trusted_post_plan total is unchanged: it still counts EVERY trusted_post_plan entry,
# covered and uncovered alike.
#
# #174 adds two more members to each plan_selection entry, binding plan approval to the specific
# plan comment a human (or the auto-approval policy) actually saw, not just the issue-level
# plan-approved label — a later revision must not silently inherit an earlier approval:
#   approval    : {approved_at, approved_by, covers_plan, reason} — approved_at/approved_by come
#                 from the newest `labeled` event for plan-approved on GitHub's issue-events API
#                 (null when unknown); covers_plan is true iff that label's newest application is
#                 not earlier than the selected plan comment's createdAt (the plan comment posted
#                 after the label fails it) AND the plan comment's own REST updated_at is not later
#                 than that same approved_at (#192 — an in-place edit of the comment made AFTER
#                 approval un-covers it too, not just a later revision's own createdAt); reason is
#                 one of covered (covers_plan: true), plan-after-approval, no-approval-event,
#                 no-plan, plan-url-missing, plan-edited-after-approval (covers_plan: false), or
#                 approval-unreadable / plan-edit-unreadable (covers_plan: null — the events lookup
#                 or, respectively, the plan comment's updated_at lookup itself failed, fail-closed,
#                 matching find-planning-work.sh's precedent for an unreadable authorAssociation).
#   binding_line: the literal `<!-- harness-plan-binding: issue=<n> plan=<plan.url>
#                 approved-at=<approved_at> -->` when and only when covers_plan is true; null in
#                 every other case. Revalidated by the issue-implementer skill before dispatch and
#                 again before push, then pasted verbatim into the PR body for the issue-cycle
#                 merge floor to grep for — see that skill and skills/issue-cycle/SKILL.md.
# One warn: line per non-covered issue, one distinct ASCII stem per reason — except reason:
# no-plan, which reuses the existing "no maintainer-authored plan comment" line rather than
# doubling up, and the two plan-edit-unreadable routes (an unparseable comment id, and a rejected
# or unprocessable updated_at lookup), which share the same "plan edit state unreadable" stem
# family since both mean the same thing to a reader: the edit state could not be determined.
#
# --issue <n> (new): skip the `ready` query and evaluate exactly one issue via `gh issue view`,
# regardless of its labels — used by the issue-implementer skill for a fresh, per-issue
# revalidation immediately before dispatch and again before push. Output shape is identical to
# the no-argument form, with `ready` and `plan_selection` each holding at most one entry. An
# unknown flag, a non-numeric <n>, or extra arguments print a usage message on stderr and exit 2.
# No arguments: unchanged behaviour and output shape (bin/harness-status.sh:24 depends on this).
#
# counts gains: fetch_failures (a gh issue view failure for one ready issue is survived — that
# issue gets no plan_selection entry, every other ready issue still gets one), no_trusted_plan,
# trusted_post_plan, untrusted_post_plan (totals across all issues), untrusted_plan_markers,
# untrusted_harness_markers (#194 workstream A, see above), verdict_archives_skipped (trusted,
# post-plan, verdict-marker-carrying comments excluded from trusted_post_plan),
# audit_comments_skipped (trusted, post-plan, harness-audit-marker-carrying comments excluded from
# trusted_post_plan the same way), missing_association, plan_after_approval, no_approval_event,
# and approval_unreadable (from #174's approval binding, one per corresponding `reason`),
# post_approval_comments (#194 workstream B, see above — trusted_post_plan entries with
# covered_by_approval: false), and plan_edited_after_approval / plan_edit_unreadable (#192, one per
# corresponding `reason` — see the plan_selection[].approval doc above). ready and
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

# --issue <n> (#174): a fresh, single-issue run, regardless of the issue's labels — used by the
# issue-implementer skill to revalidate approval immediately before dispatch and again before
# push. No arguments: today's behaviour, unchanged.
single_issue=""
if [ "$#" -gt 0 ]; then
  case "$1" in
    --issue)
      if [ "$#" -ne 2 ]; then
        echo "usage: find-implementation-work.sh [--issue <n>]" >&2
        exit 2
      fi
      case "$2" in
        ''|*[!0-9]*)
          echo "find-implementation-work.sh: --issue requires a numeric issue number, got '$2'" >&2
          exit 2
          ;;
      esac
      single_issue="$2"
      ;;
    *)
      echo "usage: find-implementation-work.sh [--issue <n>]" >&2
      exit 2
      ;;
  esac
fi

fetch_failures=0
prefetched_issue=""
if [ -n "$single_issue" ]; then
  if ! prefetched_issue=$(gh issue view "$single_issue" --json number,title,url,comments 2>/dev/null); then
    echo "warn: could not fetch issue #$single_issue — skipping it this run" >&2
    fetch_failures=1
    ready="[]"
    ready_numbers=""
    prefetched_issue=""
  else
    ready=$(printf '%s' "$prefetched_issue" | jq -c '[{number: .number, title: .title, url: .url}]')
    ready_numbers="$single_issue"
  fi
else
  ready=$(gh issue list \
    --search "is:open is:issue label:plan-approved -label:pr-open -label:impl-blocked" \
    --json number,title,url \
    --limit "$LIMIT")
  ready_numbers=$(printf '%s' "$ready" | jq -r '.[].number')
fi

plan_selection="[]"
no_trusted_plan=0
trusted_post_plan_total=0
untrusted_post_plan_total=0
untrusted_plan_markers=0
untrusted_harness_markers=0
verdict_archives_skipped=0
audit_comments_skipped=0
missing_association=0
plan_after_approval=0
no_approval_event=0
approval_unreadable=0
post_approval_comments=0
plan_edited_after_approval=0
plan_edit_unreadable=0
for n in $ready_numbers; do
  # Tolerate per-issue failures: one transient gh/API error must not kill the whole
  # discovery run (matters for unattended/scheduled runs). The issue is simply
  # reconsidered next time. In --issue mode, `issue` was already fetched above — reuse it
  # rather than fetching it twice.
  if [ -n "$prefetched_issue" ]; then
    issue="$prefetched_issue"
  elif ! issue=$(gh issue view "$n" --json number,title,url,comments 2>/dev/null); then
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
              has_plan_marker: (.body | contains($m)),
              has_harness_marker: ((.body | contains($a)) or (.body | contains($v))) } ],
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

  # #174 — approval binding: bind plan-approved to the SPECIFIC plan comment that was newest
  # when the label was last applied, not just to the issue-level label. Only makes the events
  # API call when there is a plan to bind (skips the issues already skipped for no_trusted_plan).
  # #196 — the --jq filter below MUST open with `.[] | `: `gh api --paginate --jq 'EXPR'` applies
  # EXPR once to each page's response document AS-IS (a JSON array of event objects), not once per
  # element — gh never prepends its own `.[] | `. Without the leading `.[] | `, `select(...)` runs
  # against the whole array, jq errors ("expected an object but got: array"), gh exits 1, the
  # `2>/dev/null` below swallows it, and this issue silently fails closed to approval-unreadable
  # on every real run (live-verified against this repo's own issue #194, 2026-09-01).
  approved_at=""
  approved_by=""
  covers_plan="false"
  reason="no-plan"
  if [ "$plan" != "null" ]; then
    plan_url=$(printf '%s' "$plan" | jq -r '.url // empty')
    plan_created=$(printf '%s' "$plan" | jq -r '.createdAt')
    # #192 — parse the REST comment id (the `#issuecomment-<id>` suffix of plan_url) up front so
    # the content-binding check below (inside the branch that would otherwise conclude "covered")
    # has it ready; digits-only validated here, the same idiom the --issue argument parser above
    # uses, since this id is interpolated into a `gh api` path.
    plan_comment_id=""
    case "$plan_url" in
      *"#issuecomment-"*)
        plan_comment_id="${plan_url##*#issuecomment-}"
        case "$plan_comment_id" in
          ''|*[!0-9]*) plan_comment_id="" ;;
        esac
        ;;
    esac
    if [ -z "$plan_url" ]; then
      reason="plan-url-missing"
      echo "warn: issue #$n: plan comment has no url — cannot bind approval to it" >&2
    elif ! events=$(gh api "repos/{owner}/{repo}/issues/$n/events?per_page=100" --paginate --jq '
        .[] | select(.event == "labeled" and .label.name == "plan-approved")
        | "\(.created_at) \(.actor.login // "unknown")"
      ' 2>/dev/null); then
      covers_plan="null"
      reason="approval-unreadable"
      echo "warn: issue #$n: could not read plan-approved label events — approval unreadable" >&2
      approval_unreadable=$((approval_unreadable+1))
    else
      # sed, not `grep -v`, to drop blank lines: with `set -o pipefail`, a `grep -v` that
      # matches nothing (the common "no events" case) exits 1 and would abort the whole script
      # under `set -e`; `sed` exits 0 regardless of how many lines it deletes.
      latest=$(printf '%s\n' "$events" | sed '/^$/d' | sort | tail -1)
      if [ -z "$latest" ]; then
        reason="no-approval-event"
        echo "warn: issue #$n: no plan-approved labeling event found — approval does not cover this plan" >&2
        no_approval_event=$((no_approval_event+1))
      else
        approved_at=$(printf '%s' "$latest" | cut -d' ' -f1)
        approved_by=$(printf '%s' "$latest" | cut -d' ' -f2-)
        if [[ "$plan_created" > "$approved_at" ]]; then
          reason="plan-after-approval"
          echo "warn: issue #$n: plan comment ($plan_created) postdates the plan-approved label ($approved_at) — approval does not cover this plan" >&2
          plan_after_approval=$((plan_after_approval+1))
        else
          # #192 — plan-comment content binding: everything above proves WHICH comment and WHEN,
          # but an in-place edit of an already-approved comment moves neither its url, createdAt,
          # nor the plan-approved label. One extra read-only call, made ONLY here (an approval
          # that would otherwise cover the plan), compares the plan comment's REST updated_at
          # against the CURRENT (newest) approved_at computed above: an edit strictly after
          # approval un-covers the plan (a human must re-approve — removing and re-adding
          # plan-approved moves approved_at past the edit and re-covers it, the same audited path
          # #174/#194 already document); an edit before approval is covered on purpose (the
          # approver read the edited text); a tie counts as covered (same inclusive-boundary
          # convention as the plan_created/approved_at compare above). An unparseable comment id
          # or an unreadable/unprocessable lookup fails closed, matching #204's precedent for the
          # events lookup — approved_at/approved_by stay populated in that state, since the events
          # lookup itself already succeeded.
          if [ -z "$plan_comment_id" ]; then
            covers_plan="null"
            reason="plan-edit-unreadable"
            echo "warn: issue #$n: plan comment url ($plan_url) carries no #issuecomment-<id> — plan edit state unreadable" >&2
            plan_edit_unreadable=$((plan_edit_unreadable+1))
          elif ! plan_updated=$(gh api "repos/{owner}/{repo}/issues/comments/$plan_comment_id" --jq '.updated_at // empty' 2>/dev/null); then
            covers_plan="null"
            reason="plan-edit-unreadable"
            echo "warn: issue #$n: could not read the plan comment's updated_at — plan edit state unreadable" >&2
            plan_edit_unreadable=$((plan_edit_unreadable+1))
          elif [ -z "$plan_updated" ]; then
            covers_plan="null"
            reason="plan-edit-unreadable"
            echo "warn: issue #$n: could not read the plan comment's updated_at — plan edit state unreadable" >&2
            plan_edit_unreadable=$((plan_edit_unreadable+1))
          elif [[ "$plan_updated" > "$approved_at" ]]; then
            reason="plan-edited-after-approval"
            echo "warn: issue #$n: plan comment was edited ($plan_updated) after the plan-approved label ($approved_at) — the approval does not cover the edited text" >&2
            plan_edited_after_approval=$((plan_edited_after_approval+1))
          else
            covers_plan="true"
            reason="covered"
          fi
        fi
      fi
    fi
  fi

  binding_line="null"
  if [ "$covers_plan" = "true" ]; then
    binding_line=$(jq -n --arg s "<!-- harness-plan-binding: issue=$n plan=$plan_url approved-at=$approved_at -->" '$s')
  fi
  approval_json=$(jq -n \
    --arg at "$approved_at" --arg by "$approved_by" --arg reason "$reason" --argjson covers "$covers_plan" \
    '{approved_at: (if $at == "" then null else $at end),
      approved_by: (if $by == "" then null else $by end),
      covers_plan: $covers,
      reason: $reason}')

  # #194 workstream B — bind each trusted_post_plan comment to the SAME approval this entry's
  # binding_line uses: covered_by_approval is true when the comment did not arrive after the
  # newest plan-approved labeling event, false when it did (context only, reported, never
  # binding), and null when approved_at itself is unknown (fail-closed, mirrors approval.reason's
  # own unknown states). Reuses the same string `>` comparison already load-bearing on
  # $lastPlan/createdAt above.
  trusted_post_plan=$(printf '%s' "$trusted_post_plan" | jq -c --arg at "$approved_at" \
    'map(. + {covered_by_approval: (if $at == "" then null else ((.createdAt > $at) | not) end)})')

  entry=$(jq -n --argjson n "$n" --argjson p "$plan" --argjson tpp "$trusted_post_plan" --argjson upp "$untrusted_post_plan" \
    --argjson appr "$approval_json" --argjson bl "$binding_line" \
    '{number: $n, plan: $p, trusted_post_plan: $tpp, untrusted_post_plan: $upp, approval: $appr, binding_line: $bl}')
  plan_selection=$(jq -n --argjson arr "$plan_selection" --argjson e "$entry" '$arr + [$e]')

  if [ "$plan" = "null" ]; then
    echo "warn: issue #$n: no maintainer-authored plan comment — nothing to implement this run" >&2
    no_trusted_plan=$((no_trusted_plan+1))
  fi

  tpp_count=$(printf '%s' "$trusted_post_plan" | jq 'length')
  trusted_post_plan_total=$((trusted_post_plan_total+tpp_count))

  upp_count=$(printf '%s' "$untrusted_post_plan" | jq 'length')
  untrusted_post_plan_total=$((untrusted_post_plan_total+upp_count))

  # warn (#194 workstream B): a trusted post-plan comment posted after the plan-approved label —
  # reported (context only), never folded into the binding set; one line per such comment, same
  # idiom as the plan-marker loop below.
  uncovered_pairs=$(printf '%s' "$trusted_post_plan" | jq -r '.[] | select(.covered_by_approval == false) | "\(.author) (\(.createdAt))"')
  if [ -n "$uncovered_pairs" ]; then
    while IFS= read -r who; do
      [ -n "$who" ] || continue
      echo "warn: issue #$n: trusted comment by $who was posted after the plan-approved label (approved-at=$approved_at) — context only, not a binding decision" >&2
      post_approval_comments=$((post_approval_comments+1))
    done <<<"$uncovered_pairs"
  fi

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

  # warn (a2): an untrusted post-plan comment carries a forged harness-record marker
  # (harness-audit or verifier-verdict) — never filtered out of untrusted_post_plan (#182's
  # placement rule; this only annotates it), just called out.
  harness_marker_pairs=$(printf '%s' "$untrusted_post_plan" | jq -r '.[] | select(.has_harness_marker) | "\(.author)/\(.association)"')
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
  --argjson uhm "$untrusted_harness_markers" \
  --argjson vas "$verdict_archives_skipped" \
  --argjson acs "$audit_comments_skipped" \
  --argjson ma "$missing_association" \
  --argjson paa "$plan_after_approval" \
  --argjson nae "$no_approval_event" \
  --argjson au "$approval_unreadable" \
  --argjson pac "$post_approval_comments" \
  --argjson peaa "$plan_edited_after_approval" \
  --argjson peu "$plan_edit_unreadable" \
  '{ready: $ready,
    plan_selection: $selection,
    counts: {ready: ($ready | length), truncated: (($ready | length) >= $limit),
             fetch_failures: $ff,
             no_trusted_plan: $ntp,
             trusted_post_plan: $tpp,
             untrusted_post_plan: $upp,
             untrusted_plan_markers: $upm,
             untrusted_harness_markers: $uhm,
             verdict_archives_skipped: $vas,
             audit_comments_skipped: $acs,
             missing_association: $ma,
             plan_after_approval: $paa,
             no_approval_event: $nae,
             approval_unreadable: $au,
             post_approval_comments: $pac,
             plan_edited_after_approval: $peaa,
             plan_edit_unreadable: $peu}}'
