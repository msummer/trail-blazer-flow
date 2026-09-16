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
#   degraded            : boolean (#284/#285, #297) — true iff degraded_reasons is non-empty; a
#                         discovery query OR one of this script's OWN three queries below failed
#                         closed this run, so a bucket above may under-report the true queue
#                         rather than reflect it
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
#                         status half (#297) is the SAME generic rule applied to this script's OWN
#                         `counts` (see the final jq -n below), covering
#                         proposed_query_unavailable, blocked_query_unavailable, and
#                         prs_query_unavailable. counts.fetch_failures on either discovery script
#                         deliberately does not participate: it drops one issue, not a whole
#                         bucket, and already produces its own per-issue warn line on stderr.
#   counts               : per-bucket counts + human_actions (total items waiting on you) +
#                         degraded (mirrors the top-level boolean, so a reader who only looks at
#                         counts still sees it) + (#297) this script's own six
#                         proposed_query_retried/proposed_query_unavailable/
#                         blocked_query_retried/blocked_query_unavailable/
#                         prs_query_retried/prs_query_unavailable booleans
#
# Wall clock (#297): this script's own three queries below (plan-proposed, impl-blocked, open
# PRs) each get one guarded 30s backoff and one retry, the same RETRY_SLEEP-driven shape
# find-implementation-work.sh already uses — worst case, when all three fail twice, 3 × 30s = 90s
# added to this script's own run. In a broad outage where every list query anywhere fails twice,
# the total across one harness-status.sh invocation is about 210s: the planning script's up to 3
# retries (needs_initial_plan, revision-candidates, the author-association REST lookup) + the
# implementation script's up to 1 retry on its own ready query (its per-issue fetch retry is
# per-issue, not counted here) + this script's own up to 3 retries above. The per-issue fetch
# worst cases on either discovery script are unchanged by this addition.
#
# Read-only. Used by the issue-cycle skill's closing report, and handy standalone:
# "what is waiting on me?" Requires: gh (authenticated), jq, and the other harness
# scripts on the PATH. Run from anywhere inside the repo.
set -euo pipefail

LIMIT=100
# RETRY_SLEEP (#297): mirrors find-implementation-work.sh's own RETRY_SLEEP — same value (30s),
# guarding this script's own three gh call sites below (proposed, blocked, prs).
RETRY_SLEEP=30

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

# list_proposed / list_blocked / list_prs (#297) — each call's last command is the gh call itself,
# with no pipe inside, so a retry can re-run just the call without repeating the whole
# invocation+transform.
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

jq -n \
  --argjson unplanned "$unplanned" \
  --argjson in_revision "$in_revision" \
  --argjson ready "$ready" \
  --argjson plans "$plans_to_review" \
  --argjson prs "$prs_to_review" \
  --argjson blocked "$blocked" \
  --argjson dr "$degraded_reasons" \
  --argjson pqr "$proposed_query_retried" \
  --argjson pqu "$proposed_query_unavailable" \
  --argjson bqr "$blocked_query_retried" \
  --argjson bqu "$blocked_query_unavailable" \
  --argjson prqr "$prs_query_retried" \
  --argjson prqu "$prs_query_unavailable" \
  '{proposed_query_retried: $pqr, proposed_query_unavailable: $pqu,
    blocked_query_retried: $bqr, blocked_query_unavailable: $bqu,
    prs_query_retried: $prqr, prs_query_unavailable: $prqu} as $sf
   | ($dr + [ $sf | to_entries[] | select((.key|endswith("_unavailable")) and .value == true) | "status." + .key ]) as $all
   | (($all | length) > 0) as $deg
   | {
     harness_will_handle: {unplanned: $unplanned, in_revision: $in_revision, ready_to_implement: $ready},
     waiting_on_human:    {plans_to_review: $plans, prs_to_review: $prs, blocked: $blocked},
     degraded: $deg,
     degraded_reasons: $all,
     counts: ({
       unplanned: ($unplanned | length),
       in_revision: ($in_revision | length),
       ready_to_implement: ($ready | length),
       plans_to_review: ($plans | length),
       prs_to_review: ($prs | length),
       blocked: ($blocked | length),
       human_actions: (($plans | length) + ($prs | length) + ($blocked | length)),
       degraded: $deg
     } + $sf)
   }'
