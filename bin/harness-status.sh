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
#     stop_routes        : (#353) one entry per SET stop-switch carrier — {route, clear}, both
#                         fields pasted verbatim from harness-stop.sh's own stdout (never
#                         re-derived) — fed by the top-level stop check below rather than a second
#                         query; empty under "false"/"unknown" because harness-stop.sh itself never
#                         prints a carrier line in either state (measured, see
#                         stop-measure-353.md), empty under "unavailable" because this script
#                         discards whatever an untrusted exit printed rather than trust it, or
#                         "true" with no carrier line printed at all (see the honest limits below)
#   stop                 : (#353) {state, reason, exit_code} — one bin/harness-stop.sh invocation's
#                         verdict for THIS run: state is one of harness-stop.sh's own three tokens,
#                         "false"/"true"/"unknown", or this script's OWN "unavailable" slug for
#                         every outcome that script never prints (a usage/environment error, a
#                         not-found exit, an rc/token disagreement, or stdout with no parseable
#                         stop=<state> first line at all — see counts.stop_check_unavailable below);
#                         reason is the exact reason=<slug> line harness-stop.sh printed, prefix
#                         stripped, or null; exit_code is its raw exit status. The skills treat
#                         "true" and "unknown" identically — both halt dispatch at the next stage
#                         boundary — see skills/issue-cycle/SKILL.md's "Stop switch" section.
#   degraded            : boolean (#284/#285, #297, #333, #309, #353) — true iff degraded_reasons is
#                         non-empty; a discovery query, one of this script's OWN five gh call sites
#                         below, or its stop check, failed closed this run, so a bucket above may
#                         under-report the true queue rather than reflect it
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
#                         status half (#297, #333, #309, #353) is the SAME generic rule applied to
#                         this script's OWN `counts` (see the final jq -n below), covering, in this
#                         script's own $sf key order, proposed_query_unavailable,
#                         blocked_query_unavailable, prs_query_unavailable, (#333)
#                         followups_query_unavailable, (#309) escalations_query_unavailable, and,
#                         appended last, (#353) stop_check_unavailable.
#                         counts.fetch_failures on either discovery script deliberately does not
#                         participate: it drops one issue, not a whole bucket, and already
#                         produces its own per-issue warn line on stderr.
#   counts               : per-bucket counts + human_actions (see the sum note below for exactly
#                         what this sums) + degraded (mirrors the top-level boolean, so a
#                         reader who only looks at counts still sees it) + (#297, #333, #309, #353)
#                         this script's own eleven proposed_query_retried/proposed_query_unavailable/
#                         blocked_query_retried/blocked_query_unavailable/
#                         prs_query_retried/prs_query_unavailable/followups_query_retried/
#                         followups_query_unavailable/escalations_query_retried/
#                         escalations_query_unavailable/stop_check_unavailable booleans
#
# human_actions and its exclusion list (#333, #346, #353): human_actions is a GENERIC sum over
# every waiting_on_human array EXCEPT the ones named in a small exclusion list bound right next to
# the sum in the final jq -n below (today empty, kept as the extension point a future member can
# still use — see below) — so a future waiting_on_human member that is NOT named there joins the
# total automatically, with no edit to the human_actions expression itself: one list_* function,
# one retry block, one waiting_on_human member, one counts key, and two flags are enough;
# degraded_reasons and human_actions both follow for free. followups_to_triage was excluded from
# #333 through v2.7.6: the query behind it — open + no-plan + body opens with the harness marker —
# could not tell a follow-up nobody had triaged yet from one a maintainer already read and decided
# to keep held (both kept no-plan and the marker forever), so folding it into the total would have
# meant the total could never return to zero in a repo with any parked follow-up. Since #346, the
# query itself excludes -label:$TRIAGED_HELD_LABEL (see list_followups() below), so the bucket is
# untriaged-only and joined the sum by removing its name from the exclusion list. escalations
# (#309) was never named in the exclusion list, so it already joined the sum automatically, by the
# same generic rule. stop_routes (#353) is likewise never named in the exclusion list, so a SET
# stop with N carriers raises the total by exactly N — an unknown stop, or a determinate "true"
# with no carrier line at all, contributes 0 because harness-stop.sh itself never prints a carrier
# line in either case (measured, see stop-measure-353.md); an unavailable stop also contributes 0,
# but for a different reason — this script discards whatever an untrusted exit printed and
# publishes stop_routes as [] regardless (see the discard step further below) — so stop.state,
# never stop_routes' own length, is the authority on whether a stop is in effect. human_actions is
# therefore, today, the sum of every waiting_on_human member: plans_to_review, prs_to_review,
# blocked, followups_to_triage, escalations, and stop_routes.
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
# filed from a red-CI site (ci-red-after-fix, ci-red-unrelated) or from step 2b's open-PR
# sub-branch (branch-has-open-pr) sits on an issue whose open PR is already in prs_to_review —
# list_prs carries no --search string of its own for anything to be excluded from — so that one
# problem counts twice in human_actions too (once as the PR, once as the escalated issue).
# GitHub's issue search can trail a label edit
# (measured on this repo, 2026-09-17 and again 2026-09-19: a list query made right after a label
# edit missed an issue that a later run returned), so an issue escalated moments earlier may be
# missing from the same run's escalations bucket.
#
# Honest limits on stop / stop_routes (#353): (a) a stop=true carrying NO carrier line at all —
# harness-stop.sh's own documented non-issue-element response class, in that script's STDOUT
# GRAMMAR section — yields state: "true" with an EMPTY stop_routes, so human_actions does not count
# it; stop.state, never stop_routes' own length, is the authority on whether a stop is in effect.
# (b) the freshness lag harness-stop.sh's own header documents (a label edit can trail the query
# that reads it) applies unchanged here — a stop applied moments before this run may not yet be
# visible. (c) this check is read ONCE per run and never retried at this layer: harness-stop.sh
# already performs its own one bounded retry around its GitHub-route query (see that script's own
# header), so a second retry here would only double the wait, not the confidence.
#
# Wall clock (#297, #333, #309): this script's own five gh call sites below (plan-proposed,
# impl-blocked, open PRs, held follow-ups, escalations) each get one guarded 30s backoff and one
# retry, the same RETRY_SLEEP-driven shape find-implementation-work.sh already uses — worst case,
# when all five fail twice, 5 × 30s = 150s added to this script's own run. (#353) The stop check
# below is a SIXTH check but not a sixth gh call site — it shells out to harness-stop.sh, never
# calls gh itself — and is never retried at this layer; harness-stop.sh's own single bounded retry
# can add up to 30s more on top of the 150s above. In a broad outage where every list query
# anywhere fails twice, the total across one harness-status.sh invocation is about 300s: the
# planning script's up to 3 retries (needs_initial_plan, revision-candidates, the
# author-association REST lookup) + the implementation script's up to 1 retry on its own ready
# query (its per-issue fetch retry is per-issue, not counted here) + this script's own up to 5
# retries above + (#353) harness-stop.sh's own up to 1 retry. The per-issue fetch worst cases on
# either discovery script are unchanged by this addition.
#
# Read-only. Used by the issue-cycle skill's closing report, and handy standalone:
# "what is waiting on me?" Requires: gh (authenticated), jq, harness-stop.sh, and the other harness
# scripts on the PATH. Run from anywhere inside the repo.
set -euo pipefail

LIMIT=100
# RETRY_SLEEP (#297): mirrors find-implementation-work.sh's own RETRY_SLEEP — same value (30s),
# guarding this script's own five gh call sites below (proposed, blocked, prs, (#333) followups,
# and (#309) escalations). (#353) The stop check further below is NOT one of these five gh sites —
# it is never retried at this layer (see the header's own Wall clock paragraph) — so it does not
# use RETRY_SLEEP.
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
# STOP_*_PREFIX / STOP_STATE_{SET,CLEAR,UNKNOWN} (#353) — the literal stdout-grammar tokens
# bin/harness-stop.sh prints and this script parses (see that script's own header, STDOUT GRAMMAR);
# load-bearing on both sides — gate assertion 4.51 cross-checks these against bin/harness-stop.sh's
# own source as fixed strings, never renaming one without the other. Declared one per anchored
# NAME="value" line so the sed -nE 's/^NAME="([^"]*)"$/\1/p' extraction idiom
# (2.5/4.13/4.35/4.36/4.48/4.49/4.50/4.51) can read them.
STOP_STATE_PREFIX="stop="
STOP_ROUTE_PREFIX="route="
STOP_CLEAR_PREFIX="clear="
STOP_REASON_PREFIX="reason="
STOP_STATE_SET="true"
STOP_STATE_CLEAR="false"
STOP_STATE_UNKNOWN="unknown"
# STOP_STATE_UNAVAILABLE (#353) — this script's OWN slug, never printed by bin/harness-stop.sh
# itself (deliberately excluded from gate assertion 4.51's clause (b) for that reason) — covers
# every outcome that script does not document: a usage/environment error (exit 2), a not-found
# exit (127), any other exit status, an rc/token disagreement, or stdout with no parseable
# stop=<state> first line at all.
STOP_STATE_UNAVAILABLE="unavailable"

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

# (#353) one bin/harness-stop.sh invocation — never a second gh query (see the STOP_* constants
# above and the header's own "stop" paragraph): harness-stop.sh already performs its own one
# bounded retry around its GitHub-route query, so this site adds no second retry of its own, unlike
# the five gh call sites above.
stop_rc=0
stop_out="$(harness-stop.sh)" || stop_rc=$?
# Never pipe this through `head -1` (CLAUDE.md's grep-quiet-mode class, #255, the same SIGPIPE
# risk): parameter expansion keeps this a pure bash operation with no second process to signal.
stop_line1="${stop_out%%$'\n'*}"
case "$stop_rc" in
  0)
    if [ "$stop_line1" = "${STOP_STATE_PREFIX}${STOP_STATE_CLEAR}" ]; then
      stop_state="$STOP_STATE_CLEAR"
    else
      stop_state="$STOP_STATE_UNAVAILABLE"
    fi
    ;;
  3)
    if [ "$stop_line1" = "${STOP_STATE_PREFIX}${STOP_STATE_SET}" ]; then
      stop_state="$STOP_STATE_SET"
    else
      stop_state="$STOP_STATE_UNAVAILABLE"
    fi
    ;;
  4)
    if [ "$stop_line1" = "${STOP_STATE_PREFIX}${STOP_STATE_UNKNOWN}" ]; then
      stop_state="$STOP_STATE_UNKNOWN"
    else
      stop_state="$STOP_STATE_UNAVAILABLE"
    fi
    ;;
  *)
    stop_state="$STOP_STATE_UNAVAILABLE"
    ;;
esac
if [ "$stop_state" = "$STOP_STATE_SET" ] || [ "$stop_state" = "$STOP_STATE_CLEAR" ]; then
  stop_check_unavailable=false
else
  stop_check_unavailable=true
fi
case "$stop_state" in
  "$STOP_STATE_UNKNOWN")
    echo "warn: could not confirm the stop switch's GitHub route (harness-stop.sh exit 4) — reporting stop.state \"unknown\" this run; the skills treat an unknown stop as a stop" >&2
    ;;
  "$STOP_STATE_UNAVAILABLE")
    echo "warn: could not read the stop switch (harness-stop.sh exit $stop_rc) — reporting stop.state \"unavailable\" this run (fail-closed)" >&2
    ;;
esac
# Parse $stop_out into JSON once: reason (the first reason=<slug> line, prefix stripped, else
# null) and routes (one {route, clear} object per route=... line, both fields byte-identical to
# the printed lines — never re-derived from $STOP_LABEL or a path, the same verbatim rule
# skills/issue-cycle/SKILL.md's "Stop switch" section states for the report), preserving printed
# order (GitHub carriers before the local carrier, harness-stop.sh's own order).
stop_parsed=$(jq -n \
  --arg out "$stop_out" \
  --arg rp "$STOP_ROUTE_PREFIX" \
  --arg cp "$STOP_CLEAR_PREFIX" \
  --arg zp "$STOP_REASON_PREFIX" \
  '
  ($out | split("\n")) as $lines
  | (([ $lines[] | select(startswith($zp)) ])[0]) as $reason_line
  | (if $reason_line == null then null else $reason_line[($zp | length):] end) as $reason
  | [ range(0; $lines | length)
      | select($lines[.] | startswith($rp))
      | . as $i
      | { route: $lines[$i],
          clear: (if (($i + 1) < ($lines | length)) and ($lines[$i + 1] | startswith($cp))
                  then $lines[$i + 1] else null end) }
    ] as $routes
  | { reason: $reason, routes: $routes }
  ')
# An "unavailable" verdict comes from an untrusted exit (a usage/environment error, a not-found
# exit, an rc/token disagreement, or unparseable stdout) — this script does not trust whatever
# carrier-shaped lines that exit happened to print, so it discards them here regardless of what
# $stop_parsed.routes came out as: stop.state, never stop_routes' own length, stays the sole
# authority on whether a stop is in effect (AC6 of #353's plan; see the header's own honest limits).
if [ "$stop_state" = "$STOP_STATE_UNAVAILABLE" ]; then
  stop_parsed=$(jq -c '.routes = []' <<<"$stop_parsed")
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
  --arg sst "$stop_state" \
  --argjson src "$stop_rc" \
  --argjson scu "$stop_check_unavailable" \
  --argjson sp "$stop_parsed" \
  '{proposed_query_retried: $pqr, proposed_query_unavailable: $pqu,
    blocked_query_retried: $bqr, blocked_query_unavailable: $bqu,
    prs_query_retried: $prqr, prs_query_unavailable: $prqu,
    followups_query_retried: $fqr, followups_query_unavailable: $fqu,
    escalations_query_retried: $eqr, escalations_query_unavailable: $equ,
    stop_check_unavailable: $scu} as $sf
   | ($dr + [ $sf | to_entries[] | select((.key|endswith("_unavailable")) and .value == true) | "status." + .key ]) as $all
   | (($all | length) > 0) as $deg
   | {state: $sst, reason: $sp.reason, exit_code: $src} as $stop
   | {plans_to_review: $plans, prs_to_review: $prs, blocked: $blocked, followups_to_triage: $followups, escalations: $escalations, stop_routes: $sp.routes} as $woh
   | [] as $excluded
   | {
     harness_will_handle: {unplanned: $unplanned, in_revision: $in_revision, ready_to_implement: $ready},
     waiting_on_human:    $woh,
     degraded: $deg,
     degraded_reasons: $all,
     stop: $stop,
     counts: ({
       unplanned: ($unplanned | length),
       in_revision: ($in_revision | length),
       ready_to_implement: ($ready | length),
       plans_to_review: ($woh.plans_to_review | length),
       prs_to_review: ($woh.prs_to_review | length),
       blocked: ($woh.blocked | length),
       followups_to_triage: ($woh.followups_to_triage | length),
       escalations: ($woh.escalations | length),
       stop_routes: ($woh.stop_routes | length),
       human_actions: ([ $woh | to_entries[]
                         | select((.value | type) == "array")
                         | .key as $k | select(($excluded | index($k)) | not)
                         | (.value | length) ] | add // 0),
       degraded: $deg
     } + $sf)
   }'
