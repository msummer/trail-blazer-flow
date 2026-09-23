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
#     followups_to_triage: (#333, #346) open no-plan issues, not triaged-held, whose body opens
#                         with the harness-filed follow-up marker (#308) — read them, then either
#                         remove no-plan to release one into planning, or add the triaged-held
#                         label to park it (drops it out of this bucket, and out of the
#                         human_actions sum — see the sum note below)
#     escalations        : (#309) open needs-human issues — a durable escalation from a skill's
#                         "ask the human, then move on" stop (see skills/issue-implementer/
#                         SKILL.md's "Durable escalation" subsection); read the comment opening
#                         with <!-- harness-escalation -->, then remove needs-human to release the
#                         issue back into discovery
#   degraded            : boolean (#284/#285, #297, #333, #309) — true iff degraded_reasons is
#                         non-empty; a discovery query OR one of this script's OWN five queries
#                         below failed closed this run, so a bucket above may under-report the
#                         true queue rather than reflect it
#   degraded_reasons    : array of "planning.<key>" / "implementation.<key>" / "status.<key>"
#                         strings (planning half first, implementation half second, status half
#                         third) — the planning/implementation halves are computed by a GENERIC
#                         rule (see the degraded_reasons assignment below): every key in either
#                         find-planning-work.sh's or find-implementation-work.sh's own `counts`
#                         object whose name ends in "_unavailable" and whose value is exactly true
#                         becomes one entry, with no per-key enumeration to keep in sync as either
#                         script grows a new `*_unavailable` flag — already covers
#                         initial_query_unavailable, candidates_query_unavailable,
#                         author_association_unavailable, and (#284) ready_query_unavailable. The
#                         status half (#297, #333, #309) is the SAME generic rule applied to this
#                         script's OWN `counts` (see the final jq -n below), covering, in this
#                         script's own $sf key order, proposed_query_unavailable,
#                         blocked_query_unavailable, prs_query_unavailable, (#333)
#                         followups_query_unavailable, and (#309) escalations_query_unavailable.
#                         counts.fetch_failures on either discovery script deliberately does not
#                         participate: it drops one issue, not a whole bucket, and already
#                         produces its own per-issue warn line on stderr.
#   counts               : per-bucket counts + human_actions (see the sum note below for exactly
#                         what this sums) + degraded (mirrors the top-level boolean, so a
#                         reader who only looks at counts still sees it) + (#297, #333, #309) this
#                         script's own ten proposed_query_retried/proposed_query_unavailable/
#                         blocked_query_retried/blocked_query_unavailable/
#                         prs_query_retried/prs_query_unavailable/followups_query_retried/
#                         followups_query_unavailable/escalations_query_retried/
#                         escalations_query_unavailable booleans
#
# human_actions and its exclusion list (#333, #346): human_actions is a GENERIC sum over every
# waiting_on_human array EXCEPT the ones named in a small exclusion list bound right next to the
# sum in the final jq -n below (today empty, kept as the extension point a future member can still
# use — see below) — so a future waiting_on_human member that is NOT named there joins the total
# automatically, with no edit to the human_actions expression itself: one list_* function, one
# retry block, one waiting_on_human member, one counts key, and two flags are enough;
# degraded_reasons and human_actions both follow for free. followups_to_triage was excluded from
# #333 through v2.7.6: the query behind it — open + no-plan + body opens with the harness marker —
# could not tell a follow-up nobody had triaged yet from one a maintainer already read and decided
# to keep held (both kept no-plan and the marker forever), so folding it into the total would have
# meant the total could never return to zero in a repo with any parked follow-up. Since #346, the
# query itself excludes -label:$TRIAGED_HELD_LABEL (see list_followups() below), so the bucket is
# untriaged-only and joined the sum by removing its name from the exclusion list. escalations
# (#309) was never named in the exclusion list, so it already joined the sum automatically, by the
# same generic rule. human_actions is therefore, today, the sum of every waiting_on_human member:
# plans_to_review, prs_to_review, blocked, followups_to_triage, and escalations.
#
# Honest limits on followups_to_triage (#333, #346): (a) a follow-up a maintainer read and parked
# WITHOUT applying the triaged-held label still counts; (b) a hand-written no-plan issue whose
# body happens to open with the same marker text would count too even though the harness never
# filed it; (c) GitHub's issue search can trail a label edit (measured once on this repo,
# 2026-09-17: a `gh issue list --search` run made right after a label edit missed an issue that a
# later run returned), so a just-parked follow-up may still appear in the very next run's bucket —
# and now also in counts.human_actions; (d) --limit "$LIMIT" (100) caps this listing the same way
# it caps plans_to_review's, prs_to_review's, blocked's, and escalations' own queries.
#
# Honest limits on escalations (#309): list_proposed and list_blocked do not exclude needs-human,
# so an issue carrying needs-human alongside plan-proposed or impl-blocked appears in both buckets
# and counts twice in human_actions — removing either label clears its own entry; and an escalation
# filed from a red-CI site (ci-red-after-fix, ci-red-unrelated) sits on an issue whose open PR is
# already in prs_to_review — list_prs carries no --search string of its own for anything to be
# excluded from — so that one problem counts twice in human_actions too (once as the PR, once as
# the escalated issue). GitHub's issue search can trail a label edit
# (measured on this repo, 2026-09-17 and again 2026-09-19: a list query made right after a label
# edit missed an issue that a later run returned), so an issue escalated moments earlier may be
# missing from the same run's escalations bucket.
#
# Wall clock (#297, #333, #309): this script's own five queries below (plan-proposed,
# impl-blocked, open PRs, held follow-ups, escalations) each get one guarded 30s backoff and one
# retry, the same RETRY_SLEEP-driven shape find-implementation-work.sh already uses — worst case,
# when all five fail twice, 5 × 30s = 150s added to this script's own run. In a broad outage where
# every list query anywhere fails twice, the total across one harness-status.sh invocation is
# about 270s: the planning script's up to 3 retries (needs_initial_plan, revision-candidates, the
# author-association REST lookup) + the implementation script's up to 1 retry on its own ready
# query (its per-issue fetch retry is per-issue, not counted here) + this script's own up to 5
# retries above. The per-issue fetch worst cases on either discovery script are unchanged by this
# addition.
#
# Read-only. Used by the issue-cycle skill's closing report, and handy standalone:
# "what is waiting on me?" Requires: gh (authenticated), jq, and the other harness
# scripts on the PATH. Run from anywhere inside the repo.
set -euo pipefail

LIMIT=100
# RETRY_SLEEP (#297): mirrors find-implementation-work.sh's own RETRY_SLEEP — same value (30s),
# guarding this script's own five gh call sites below (proposed, blocked, prs, (#333) followups,
# and (#309) escalations).
RETRY_SLEEP=30
# ESCALATION_LABEL (#309) — declared byte-identically in bin/find-planning-work.sh and
# bin/find-implementation-work.sh (gate assertion 4.48); this script's own list_escalations()
# query reads it below.
ESCALATION_LABEL="needs-human"
# TRIAGED_HELD_LABEL (#346) — human-applied only; the harness only ever reads it (gate assertion
# 4.50 forbids naming it in a --label/--add-label/--remove-label argument anywhere in
# skills/*/SKILL.md, skills/*/references/*.md, agents/*.md, or bin/*.sh). This script's own
# list_followups() query below excludes it.
TRIAGED_HELD_LABEL="triaged-held"

planning=$(find-planning-work.sh)
implementation=$(find-implementation-work.sh)

# degraded_reasons (#284/#285) — see the header's own paragraph above for the generic rule this
# implements: select every `*_unavailable: true` key from EITHER script's own `counts` object,
# planning half first, implementation half second. This is the planning+implementation halves
# ONLY — the final jq -n below appends a third, status half (#297) built from this script's OWN
# counts, using the identical generic rule.
degraded_reasons=$(jq -n --argjson p "$planning" --argjson i "$implementation" '
  [ ($p.counts // {}) | to_entries[] | select((.key | endswith("_unavailable")) and .value == true) | "planning." + .key ]
  + [ ($i.counts // {}) | to_entries[] | select((.key | endswith("_unavailable")) and .value == true) | "implementation." + .key ]
')

unplanned=$(jq .needs_initial_plan <<<"$planning")
in_revision=$(jq .needs_revision <<<"$planning")
ready=$(jq .ready <<<"$implementation")

# list_proposed / list_blocked / list_prs / list_followups / list_escalations (#297, #333, #309) —
# each call's last command is the gh call itself, with no pipe inside, so a retry can re-run just
# the call without repeating the whole invocation+transform.
list_proposed() {
  gh issue list \
    --search "is:open is:issue label:plan-proposed -label:plan-approved -label:no-plan" \
    --json number,title,url --limit "$LIMIT"
}
list_blocked() {
  gh issue list \
    --search "is:open is:issue label:impl-blocked" \
    --json number,title,url --limit "$LIMIT"
}
list_prs() {
  gh pr list --state open \
    --json number,title,url,headRefName,statusCheckRollup --limit "$LIMIT"
}
# (#333, #346) open + no-plan + not triaged-held + body opens with the harness-filed follow-up
# marker (#308) — the -label:$TRIAGED_HELD_LABEL exclusion (#346) narrows this bucket to
# untriaged-only, which is why it now joins human_actions (see the header's own sum note). Honest
# limit: the label only has an effect on an issue that also carries no-plan, because this query
# requires both. No --jq argument (a --jq would be claimed by dev/planning-tests.sh's stub *"--jq"*
# arm and silently served the wrong fixture document).
list_followups() {
  gh issue list \
    --search "is:open is:issue label:no-plan -label:$TRIAGED_HELD_LABEL" \
    --json number,title,url,body --limit "$LIMIT"
}
# (#309) open + needs-human — a durable escalation from a skill's "ask the human, then move on"
# stop (see skills/issue-implementer/SKILL.md's "Durable escalation" subsection). No --jq argument,
# for the identical reason list_followups() above states.
list_escalations() {
  gh issue list \
    --search "is:open is:issue label:$ESCALATION_LABEL" \
    --json number,title,url --limit "$LIMIT"
}

# plan-proposed issues NOT in the revision bucket = awaiting the human's review. (#297) One
# guarded 30s backoff, one retry, then fail closed to an empty bucket rather than letting one blip
# abort the whole run under set -euo pipefail.
proposed_query_retried=false; proposed_query_unavailable=false
if ! proposed=$(list_proposed); then
  proposed_query_retried=true
  sleep "$RETRY_SLEEP" || true
  if proposed=$(list_proposed); then
    echo "warn: plan-proposed query failed once — retried after 30s and succeeded (transient API blip absorbed)" >&2
  else
    echo "warn: could not list plan-proposed issues (gh issue list) — reporting an empty plans_to_review bucket this run (fail-closed)" >&2
    proposed_query_unavailable=true
    proposed='[]'
  fi
fi
plans_to_review=$(jq --argjson rev "$in_revision" \
  '[ .[] | select(.number as $n | ($rev | map(.number) | index($n)) | not) ]' <<<"$proposed")

# (#297) same bounded-retry-then-fail-closed shape as proposed above.
blocked_query_retried=false; blocked_query_unavailable=false
if ! blocked=$(list_blocked); then
  blocked_query_retried=true
  sleep "$RETRY_SLEEP" || true
  if blocked=$(list_blocked); then
    echo "warn: impl-blocked query failed once — retried after 30s and succeeded (transient API blip absorbed)" >&2
  else
    echo "warn: could not list impl-blocked issues (gh issue list) — reporting an empty blocked bucket this run (fail-closed)" >&2
    blocked_query_unavailable=true
    blocked='[]'
  fi
fi

# Open claude/* PRs with a coarse CI state derived from statusCheckRollup.
# Rollup items are CheckRuns (status/conclusion) or StatusContexts (state); normalise
# via (conclusion // state // "PENDING"). (#297) The gh call and the jq transform are split so
# only the gh call itself is retried; the transform always runs once, on whatever prs_raw ends up
# holding (real content or the fail-closed '[]').
prs_query_retried=false; prs_query_unavailable=false
if ! prs_raw=$(list_prs); then
  prs_query_retried=true
  sleep "$RETRY_SLEEP" || true
  if prs_raw=$(list_prs); then
    echo "warn: open-PR query failed once — retried after 30s and succeeded (transient API blip absorbed)" >&2
  else
    echo "warn: could not list open PRs (gh pr list) — reporting an empty prs_to_review bucket this run (fail-closed)" >&2
    prs_query_unavailable=true
    prs_raw='[]'
  fi
fi
prs_to_review=$(jq '[ .[]
    | select(.headRefName | startswith("claude/"))
    | ([ (.statusCheckRollup // [])[] | (.conclusion // .state // "PENDING") | ascii_upcase ]) as $s
    | {number, title, url,
       ci: (if ($s | length) == 0 then "none"
            elif ($s | map(select(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED")) | length) > 0 then "failing"
            elif ($s | map(select(. == "PENDING" or . == "QUEUED" or . == "IN_PROGRESS" or . == "EXPECTED" or . == "")) | length) > 0 then "pending"
            else "passing" end)} ]' <<<"$prs_raw")

# (#333) same bounded-retry-then-fail-closed shape as proposed/blocked/prs above, for this
# script's own held-follow-up query. The call and the jq transform are split so only the call
# itself is retried, matching the prs site's own split immediately above.
followups_query_retried=false; followups_query_unavailable=false
if ! followups_raw=$(list_followups); then
  followups_query_retried=true
  sleep "$RETRY_SLEEP" || true
  if followups_raw=$(list_followups); then
    echo "warn: held-follow-up query failed once — retried after 30s and succeeded (transient API blip absorbed)" >&2
  else
    echo "warn: could not list held follow-ups (gh issue list) — reporting an empty followups_to_triage bucket this run (fail-closed)" >&2
    followups_query_unavailable=true
    followups_raw='[]'
  fi
fi
followups=$(jq '[ .[] | select((.body // "") | startswith("<!-- harness-follow-up: PR #")) | {number, title, url} ]' <<<"$followups_raw")

# (#309) same bounded-retry-then-fail-closed shape as proposed/blocked/prs/followups above, for
# this script's own escalations query. list_escalations() already returns the {number,title,url}
# shape verbatim, so there is no separate jq transform to split from the retried call.
escalations_query_retried=false; escalations_query_unavailable=false
if ! escalations=$(list_escalations); then
  escalations_query_retried=true
  sleep "$RETRY_SLEEP" || true
  if escalations=$(list_escalations); then
    echo "warn: escalations query failed once — retried after 30s and succeeded (transient API blip absorbed)" >&2
  else
    echo "warn: could not list escalated issues (gh issue list) — reporting an empty escalations bucket this run (fail-closed)" >&2
    escalations_query_unavailable=true
    escalations='[]'
  fi
fi

# human_actions and its exclusion list (#333, #346) — see the header's own "human_actions and its
# exclusion list" paragraph for the full rationale; the exclusion binding sits right next to the
# sum it governs, on purpose, so the two are read together. Deliberately kept, empty (#346): the
# named-exclusion mechanism is retained as an extension point for a future waiting_on_human
# member, even though nothing is named today.
jq -n \
  --argjson unplanned "$unplanned" \
  --argjson in_revision "$in_revision" \
  --argjson ready "$ready" \
  --argjson plans "$plans_to_review" \
  --argjson prs "$prs_to_review" \
  --argjson blocked "$blocked" \
  --argjson followups "$followups" \
  --argjson escalations "$escalations" \
  --argjson dr "$degraded_reasons" \
  --argjson pqr "$proposed_query_retried" \
  --argjson pqu "$proposed_query_unavailable" \
  --argjson bqr "$blocked_query_retried" \
  --argjson bqu "$blocked_query_unavailable" \
  --argjson prqr "$prs_query_retried" \
  --argjson prqu "$prs_query_unavailable" \
  --argjson fqr "$followups_query_retried" \
  --argjson fqu "$followups_query_unavailable" \
  --argjson eqr "$escalations_query_retried" \
  --argjson equ "$escalations_query_unavailable" \
  '{proposed_query_retried: $pqr, proposed_query_unavailable: $pqu,
    blocked_query_retried: $bqr, blocked_query_unavailable: $bqu,
    prs_query_retried: $prqr, prs_query_unavailable: $prqu,
    followups_query_retried: $fqr, followups_query_unavailable: $fqu,
    escalations_query_retried: $eqr, escalations_query_unavailable: $equ} as $sf
   | ($dr + [ $sf | to_entries[] | select((.key|endswith("_unavailable")) and .value == true) | "status." + .key ]) as $all
   | (($all | length) > 0) as $deg
   | {plans_to_review: $plans, prs_to_review: $prs, blocked: $blocked, followups_to_triage: $followups, escalations: $escalations} as $woh
   | [] as $excluded
   | {
     harness_will_handle: {unplanned: $unplanned, in_revision: $in_revision, ready_to_implement: $ready},
     waiting_on_human:    $woh,
     degraded: $deg,
     degraded_reasons: $all,
     counts: ({
       unplanned: ($unplanned | length),
       in_revision: ($in_revision | length),
       ready_to_implement: ($ready | length),
       plans_to_review: ($woh.plans_to_review | length),
       prs_to_review: ($woh.prs_to_review | length),
       blocked: ($woh.blocked | length),
       followups_to_triage: ($woh.followups_to_triage | length),
       escalations: ($woh.escalations | length),
       human_actions: ([ $woh | to_entries[]
                         | select((.value | type) == "array")
                         | .key as $k | select(($excluded | index($k)) | not)
                         | (.value | length) ] | add // 0),
       degraded: $deg
     } + $sf)
   }'
