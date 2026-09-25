#!/usr/bin/env bash
#
# find-implementation-work.sh
# Lists the issues ready for implementation, as JSON.
#   ready : open issues labelled plan-approved, NOT already pr-open, NOT impl-blocked, and
#           (#309) NOT needs-human
#
# An issue leaves this queue when it gets pr-open (a PR was opened), impl-blocked (needs a
# human), or needs-human (a durable escalation is waiting on a human — #309, see
# skills/issue-implementer/SKILL.md's "Durable escalation" subsection). To retry a blocked issue,
# remove the impl-blocked label; to release an escalated one, remove needs-human.
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
#   plan               : the newest comment that OPENS WITH "<!-- planner-plan -->" (startswith,
#                         anchored to the comment's first line — #281, superseding #275) AND has a
#                         trusted authorAssociation (OWNER/MEMBER/COLLABORATOR, ascii_upcase
#                         normalised) — see the $planC comment in the script body: a
#                         maintainer-authored audit/hygiene record (which opens with its own
#                         marker, never the plan marker) or a comment that merely quotes the plan
#                         marker mid-body is never mistaken for the plan — {author, association,
#                         createdAt, url}, or null when no such comment exists.
#   trusted_post_plan  : trusted comments posted after that plan — the window itself is anchored
#                         to $lastPlan, which #281 derives from the same $planC set `plan` is
#                         selected from, so this window re-anchors to the real plan rather than to
#                         a marker-quoting record — excluding the plan marker itself and any
#                         comment containing "<!-- verifier-verdict -->" (the orchestrator's own
#                         archive) or "<!-- harness-audit -->" (a harness-authored audit/hygiene
#                         record) anywhere in its body — neither is human context — same field
#                         shape, PLUS covered_by_approval (#194, see below) and
#                         covered_by_approval_reason (#230, see below) — a string naming why an
#                         otherwise-covered comment was un-covered, or null.
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
# approved_at itself is unknown, matching approval.reason's own unknown states. #230 adds a
# second field, covered_by_approval_reason: null on every entry EXCEPT one this workstream marked
# true but whose own in-place edit un-covers it (see below) — that entry's covered_by_approval
# becomes false ("decision-edited-after-approval") or null ("decision-edit-unreadable") and
# covered_by_approval_reason names which. The existing counts.trusted_post_plan total is
# unchanged: it still counts EVERY trusted_post_plan entry, covered and uncovered alike.
#
# #230 extends #194 workstream B with decision-comment CONTENT binding, closing for decision
# comments the same gap #192 closed for the plan comment itself: on the branch that would
# otherwise leave this issue's approval.covers_plan "true" (after the #229 label pre-filter, the
# #375 close check, and the #192 plan-edit check below all pass), the script looks up every trusted_post_plan entry
# whose covered_by_approval workstream B computed as true AND whose own gh-reported
# includesCreatedEdit is not exactly false (#240, see below) — via one read-only
# `gh api repos/{owner}/{repo}/issues/comments/<id> --jq '.updated_at // empty'` call per such
# entry, <id> parsed from that entry's url with the same #issuecomment-<id> two-clause idiom
# plan_comment_id uses below (outer presence gate, inner digits-only guard — this id is
# interpolated into a `gh api` path). A covered comment's updated_at strictly later than
# approval.approved_at means the maintainer's decision text was edited after the plan-approved
# label was applied — nobody approved the edited text — so that entry's covered_by_approval flips
# to false, covered_by_approval_reason to "decision-edited-after-approval", and the ISSUE-LEVEL
# approval.covers_plan/reason ALSO flip (folded into the same #219 verdict split every reader
# already inherits, so all three call sites — dispatch, the pre-push re-check, and the
# issue-cycle merge floor — hold with no new branching prose). An unparseable comment id, a
# rejected comments-endpoint call, a document the script's own --jq filter cannot process, or an
# empty updated_at all fail closed the same way: that entry's covered_by_approval flips to null,
# covered_by_approval_reason to "decision-edit-unreadable", and covers_plan/reason follow suit
# UNLESS some other covered comment on the same issue was also edited, in which case edited wins
# (false is definitive). approval.approved_at/approved_by stay populated in both new states — the
# events lookup itself already succeeded. There is NO author-plus-createdAt fallback for binding:
# an entry whose edit state cannot be established is unreadable, never silently covered. A
# comment already uncovered by workstream B (covered_by_approval: false/null before this check
# runs), or one gh itself already reports as never edited (#240), is never looked up — the first
# is already non-binding, the second's edit history is already known, so either way an API call
# would tell us nothing new.
#
# #240 pre-filters BOTH the #192 plan-comment check above and the #230 decision-comment check just
# described on gh's own per-comment includesCreatedEdit boolean — already present in the
# `comments` field this script fetches today, at no extra API cost: exactly false means gh itself
# reports the comment was never edited (updated_at == createdAt), so the id-parse and the REST
# lookup are both moot and are skipped with no warn, leaving the entry (or the plan) covered;
# exactly true keeps today's lookup and every fail-closed state unchanged; the key being ABSENT
# (every comment on every issue before GitHub added this field) falls through to today's lookup —
# no new state, no new behaviour. Honest limit: this is a tripwire, not a control — it can only
# ever WIDEN the covered set on a determinate `false`, but a `false` GitHub reports for a comment
# that WAS genuinely edited would skip the lookup silently, same as any other tripwire the harness
# trusts GitHub's own field for.
#
# #174 adds two more members to each plan_selection entry, binding plan approval to the specific
# plan comment a human (or the auto-approval policy) actually saw, not just the issue-level
# plan-approved label — a later revision must not silently inherit an earlier approval:
#   approval    : {approved_at, approved_by, covers_plan, reason, approved_at_history} —
#                 approved_at/approved_by come from the newest `labeled` event for plan-approved on
#                 GitHub's issue-events API (null when unknown); covers_plan is true iff that
#                 label's newest application is not earlier than the selected plan comment's
#                 createdAt (the plan comment posted after the label fails it), the plan comment's
#                 own REST updated_at is not later than that same approved_at (#192 — an in-place
#                 edit of the comment made AFTER approval un-covers it too, not just a later
#                 revision's own createdAt), every trusted_post_plan comment covered_by_approval
#                 already marked true has its own REST updated_at no later than approved_at either
#                 (#230, see below), AND no `closed` event on the issue is at or after that label's
#                 newest application (#375 — a close consumes the approval; a reopened issue needs
#                 a fresh one); reason is one of covered (covers_plan: true),
#                 approval-label-absent, plan-after-approval, closed-after-approval, no-approval-event,
#                 no-plan, plan-url-missing, plan-edited-after-approval, decision-edited-after-approval
#                 (covers_plan: false), or approval-unreadable / plan-edit-unreadable /
#                 decision-edit-unreadable (covers_plan: null — the events lookup, the plan
#                 comment's, or a covered decision comment's updated_at lookup respectively failed,
#                 fail-closed, matching find-planning-work.sh's precedent for an unreadable
#                 authorAssociation). approval-label-absent (#229) fires when the plan-approved
#                 label is not on the issue's CURRENT label set — this beats every other reason
#                 including no-plan, since the human's withdrawal is the most actionable fact
#                 regardless of whether a trusted plan comment also exists.
#   approved_at_history (#213): every real plan-approved `labeled` event for this issue, newest
#                 first, deduplicated, as {approved_at, approved_by, binding_line} — so a PR body
#                 written under an EARLIER approval of the same plan still has a binding line the
#                 merge floor recognises after a later, unrelated re-approval (removing and
#                 re-adding plan-approved to bind a post-approval comment, per skills/issue-cycle/
#                 SKILL.md's *Post-approval comments* rule, no longer permanently strands an open
#                 PR). Each entry's binding_line is built exactly like the top-level one below, but
#                 is null on every entry when covers_plan is not true (nothing pasteable for a plan
#                 that isn't covered) — entry [0]'s approved_at/approved_by/binding_line are always
#                 identical to approval's own top-level approved_at/approved_by/binding_line (one
#                 template, derived once, not two). The events lookup being unreadable, or
#                 returning no plan-approved event at all, or the approval-label-absent pre-filter
#                 above short-circuiting before the events lookup ever runs, all yield [] — an
#                 events-readable-but-not-covered issue (plan-after-approval, closed-after-approval,
#                 plan-edited-after-approval, decision-edited-after-approval, or the plan-edit or a
#                 covered decision comment's edit lookup itself being unreadable) still yields a
#                 non-empty history, just with every binding_line null.
#   binding_line: derived from approved_at_history[0].binding_line — the literal
#                 `<!-- harness-plan-binding: issue=<n> plan=<plan.url> approved-at=<approved_at>
#                 -->` when and only when covers_plan is true; null in every other case. Revalidated
#                 by the issue-implementer skill before dispatch and again before push, then pasted
#                 verbatim into the PR body for the issue-cycle merge floor to grep for; the floor
#                 itself (since #213) walks the whole approved_at_history array instead of matching
#                 only this one field — see that skill and skills/issue-cycle/SKILL.md.
# One warn: line per non-covered issue, one distinct ASCII stem per reason — except reason:
# no-plan, which reuses the existing "no maintainer-authored plan comment" line rather than
# doubling up, and the two plan-edit-unreadable routes (an unparseable comment id, and a rejected
# or unprocessable updated_at lookup), which share the same "plan edit state unreadable" stem
# family since both mean the same thing to a reader: the edit state could not be determined.
# approval-label-absent (#229) gets its own distinct stem, "the plan-approved label is not on the
# issue now"; when it also wins precedence over no-plan, the "no maintainer-authored plan comment"
# warn still fires too, so nothing about the missing plan comment is hidden by the label check.
# #230 is the one exception to "per non-covered ISSUE": its decision-edit warns ("decision edit
# state unreadable" / "was edited … after the plan-approved label") fire once per AFFECTED
# trusted_post_plan COMMENT, since one issue can have more than one covered decision comment.
#
# --issue <n> (new): skip the `ready` query and evaluate exactly one issue via `gh issue view`,
# regardless of its labels — this fetch still happens no matter what labels the issue carries —
# used by the issue-implementer skill for a fresh, per-issue revalidation immediately before
# dispatch and again before push. Output shape is identical to the no-argument form, with `ready`
# and `plan_selection` each holding at most one entry; the resulting VERDICT does now depend on
# the issue's current label set (#229 — see approval.reason: approval-label-absent above). An
# unknown flag, a non-numeric <n>, or extra arguments print a usage message on stderr and exit 2.
# No arguments: unchanged behaviour and output shape (bin/harness-status.sh's own
# `implementation=$(find-implementation-work.sh)` call depends on this). #284 — this single-issue
# prefetch is deliberately NOT retried, unlike the two sites below: both of its callers
# (skills/issue-implementer/SKILL.md step 2a/2e and skills/issue-cycle/SKILL.md's merge floor)
# already re-run this whole script once on an unknown verdict, which explicitly covers "no
# plan_selection entry at all" — a script-level retry here would stack a second 30s backoff on top
# of that existing re-run for one transient blip. Pinned by the
# impl-single-issue-fetch-not-retried fixture: byte-identical behaviour to before #284 (one
# attempt, warn, `counts.fetch_failures: 1`) plus a direct assertion on each of
# `counts.fetch_retries` (0), `counts.ready_query_retried` (false), and
# `counts.ready_query_unavailable` (false) staying at their reset values, and zero sleeps.
#
# #284 adds a bounded-retry-then-fail-closed shape — the SAME shape #272/#273 gave
# bin/find-planning-work.sh, one guarded 30-second backoff (RETRY_SLEEP, below) then one
# re-attempt — to the two batch-mode `gh` call sites this script makes: the `ready` query itself,
# and the per-issue `gh issue view` inside the `for n in $ready_numbers` loop.
#   - The `ready` query: a first-attempt failure retries once; if the retry succeeds,
#     counts.ready_query_retried is true and `ready` is built from the SECOND attempt's output
#     (one warn: "ready query failed once — retried after 30s and succeeded"); if BOTH attempts
#     fail, counts.ready_query_retried AND counts.ready_query_unavailable are both true, `ready`
#     is reported as an empty array (so the loop below makes zero iterations), and the script
#     still exits 0 with one complete JSON document — never an abort with no stdout (one warn:
#     "could not list ready issues (gh issue list) — reporting an empty ready bucket this run
#     (fail-closed)"). Exactly one sleep fires per run for this site, bounded, never two against a
#     permanently failing query.
#   - The per-issue fetch: a first-attempt failure retries once after the identical backoff;
#     fetch_retries counts every first-attempt failure regardless of the retry's own outcome (a
#     retried-then-successful fetch increments fetch_retries and NOT fetch_failures); only a
#     failure on BOTH attempts keeps today's warn-and-skip ("could not fetch issue #$n — skipping
#     it this run") and increments fetch_failures — narrowed, since #284, to post-retry failures
#     only.
# Both sleeps are guarded (`sleep "$RETRY_SLEEP" || true`) so a failing `sleep` itself can never
# abort the run under this script's own set -euo pipefail. Fail-closed direction: every new path
# fails toward "less work reported" (an empty `ready` bucket, or one skipped issue), never toward
# dispatching something unapproved.
#
# Wall clock (#284, mirroring bin/find-planning-work.sh's identical note): the retry budget is
# UNCAPPED per site, exactly like the planner's. Worst case this run sleeps RETRY_SLEEP seconds ×
# (1 ready-query retry + up to LIMIT per-issue fetch retries) — at the current LIMIT=100 and a 30s
# backoff, ~50 minutes if every single ready issue's fetch fails once and then succeeds on its
# retry. In practice a broad outage fails the ready query on BOTH attempts first (it runs before
# the per-issue loop), which fails closed and skips the loop entirely, so the run only ever pays
# for the one ready-query retry, never for N issues.
#
# counts gains: fetch_failures (a gh issue view failure for one ready issue is survived — that
# issue gets no plan_selection entry, every other ready issue still gets one — narrowed, since
# #284, to POST-RETRY failures only: a retried-then-successful fetch is a fetch_retries occurrence,
# not a fetch_failures one), no_trusted_plan,
# trusted_post_plan, untrusted_post_plan (totals across all issues), untrusted_plan_markers,
# untrusted_harness_markers (#194 workstream A, see above), verdict_archives_skipped (trusted,
# post-plan, verdict-marker-carrying comments excluded from trusted_post_plan),
# audit_comments_skipped (trusted, post-plan, harness-audit-marker-carrying comments excluded from
# trusted_post_plan the same way), missing_association, plan_after_approval, closed_after_approval
# (#375, one per issue whose newest closed event is at or after its newest plan-approved labeling —
# see approval.reason above), no_approval_event,
# and approval_unreadable (from #174's approval binding, one per corresponding `reason`),
# post_approval_comments (#194 workstream B, see above — trusted_post_plan entries with
# covered_by_approval: false AND covered_by_approval_reason: null (#230) — an entry uncovered
# because ITS OWN edit postdates approval is reported by decision_edited_after_approval instead,
# never double-counted here), plan_edited_after_approval / plan_edit_unreadable (#192, one per
# corresponding `reason` — see the plan_selection[].approval doc above),
# decision_edited_after_approval / decision_edit_unreadable (#230, one per AFFECTED
# trusted_post_plan COMMENT, not per issue — see the plan_selection[].approval doc above),
# approval_label_absent (#229, one per issue where the plan-approved label is not currently on the
# issue — see approval.reason above), and (#284) ready_query_retried / ready_query_unavailable
# (true iff the ready query's first attempt failed / iff BOTH attempts failed, see above) and
# fetch_retries (how many per-issue fetches inside the loop needed a retry, regardless of whether
# that retry succeeded). ready and counts.ready/counts.truncated keep their current names and
# computation — ready_query_unavailable: true still yields counts.truncated: false (a complete,
# merely empty, document was still printed). #302 adds one more: plan_marker_quoters (how many
# trusted, post-latest-plan comments carried the plan marker somewhere in their body without
# opening with it — never a plan candidate, and, via the pre-existing contains($m) test, never
# counted as trusted_post_plan either) plus one warn: line per such comment, naming its author,
# createdAt, and url (or the literal "no url"), so a comment dropped from both plan and
# trusted_post_plan for this reason is no longer silent. Harness records are excluded from this
# count exactly as they are excluded from trusted_post_plan above.
#
# #321 adds one more: harness_marker_quoters (how many trusted, post-latest-plan comments carried
# any marker in the harness-record marker set — HARNESS_RECORD_MARKERS below — somewhere in their
# body without opening with one) plus one warn: line per such comment ("... carries a harness
# record marker but does not open with it — not a harness record, and not in trusted_post_plan
# (not binding context)"), naming its author, createdAt, and url (or the literal "no url"). The
# window is the same as plan_marker_quoters above (posted after the latest trusted plan, or at any
# time when there is none). Harness records are excluded positively, by a startswith test against
# the same set: every record this harness posts opens with its own marker as the first line of the
# body, so this count never fires on a genuine harness-authored comment. Honest limit: a harness
# record with anything (even whitespace) before its marker would be counted here, and a maintainer
# comment that begins with a verbatim marker copy at byte 0 is still dropped from trusted_post_plan
# silently — no count, no warn — tracked as a separate follow-up.
#
# #309 adds a third marker to HARNESS_RECORD_MARKERS, ESCALATION_MARKER ("<!-- harness-escalation
# -->" — also the first line of the planner skill's own step-7 stalled-stage record (#349) — see
# skills/issue-planner/SKILL.md, which reuses this same marker unmodified, never a separate
# colon-keyed marker), and one more counter to go with
# it: escalation_records_skipped (how many trusted, post-latest-plan comments contained the
# escalation marker — a durable-escalation record itself, or a trusted comment quoting that marker
# mid-body — excluded from trusted_post_plan via the same contains($e)/createdAt > $lastPlan shape
# audit_comments_skipped/verdict_archives_skipped already use). A quoter comment is therefore
# counted by BOTH escalation_records_skipped and harness_marker_quoters, the same double-counting
# the pre-existing per-marker counters already have with harness_marker_quoters.
#
# Requires: gh (authenticated), jq. Run from anywhere inside the repo.
set -euo pipefail

LIMIT=100
# RETRY_SLEEP (#284): the implementer-side twin of bin/find-planning-work.sh's
# ASSOCIATION_RETRY_SLEEP — same value (30s), a different name because this script has no
# author-association lookup to name it after. Shared by both retry sites below (the ready query
# and the per-issue fetch inside the loop). Guarded (`|| true`) at every use so a failing sleep
# itself can never abort the run under set -euo pipefail.
RETRY_SLEEP=30
# ESCALATION_LABEL (#309) — the durable-escalation label a skill applies (see
# skills/issue-implementer/SKILL.md's "Durable escalation" subsection) and the dedupe mechanism:
# the ready query below excludes it, so an escalated issue is never rediscovered until a human
# removes it. Declared byte-identically in bin/find-planning-work.sh and bin/harness-status.sh
# (gate assertion 4.48).
ESCALATION_LABEL="needs-human"
PLAN_MARKER="<!-- planner-plan -->"
VERDICT_MARKER="<!-- verifier-verdict -->"
AUDIT_MARKER="<!-- harness-audit -->"
ESCALATION_MARKER="<!-- harness-escalation -->"

# HARNESS_RECORD_MARKERS (#321, extended by #309) — the harness-record marker SET, one marker per
# line. A later marker is a ONE-LINE addition here and nowhere else in the harness_marker_quoters
# member below. The per-marker counters above/below keep their own $a/$v/$e tests on purpose: each
# names its marker in its own counts key.
HARNESS_RECORD_MARKERS="$AUDIT_MARKER
$VERDICT_MARKER
$ESCALATION_MARKER"

# GitHub's authorAssociation enum: OWNER, MEMBER, COLLABORATOR, CONTRIBUTOR,
# FIRST_TIME_CONTRIBUTOR, FIRST_TIMER, NONE. Only the first three carry repo
# authority, so only they produce binding feedback or a recognised plan comment;
# everything else is reported in untrusted_post_plan and never acted on. To act on an
# outside contributor's suggestion, a maintainer comments themselves.
TRUSTED_ASSOCIATIONS="OWNER MEMBER COLLABORATOR"

# --issue <n> (#174): a fresh, single-issue run — the EVALUATION always happens regardless of the
# issue's labels, but since #229 the resulting VERDICT depends on whether plan-approved is
# currently on the issue. Used by the issue-implementer skill to revalidate approval immediately
# before dispatch and again before push. No arguments: today's behaviour, unchanged.
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
ready_query_retried=false
ready_query_unavailable=false
fetch_retries=0
prefetched_issue=""
if [ -n "$single_issue" ]; then
  # #284 — deliberately NOT retried; see the script header's own paragraph on this narrowing.
  if ! prefetched_issue=$(gh issue view "$single_issue" --json number,title,url,comments,labels 2>/dev/null); then
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
  # #284 — bounded retry: one guarded backoff, one re-attempt, then fail closed to an empty
  # `ready` bucket rather than letting one blip abort the whole run under set -euo pipefail.
  if ! ready=$(gh issue list \
    --search "is:open is:issue label:plan-approved -label:pr-open -label:impl-blocked -label:$ESCALATION_LABEL" \
    --json number,title,url \
    --limit "$LIMIT"); then
    ready_query_retried=true
    sleep "$RETRY_SLEEP" || true
    if ready=$(gh issue list \
      --search "is:open is:issue label:plan-approved -label:pr-open -label:impl-blocked -label:$ESCALATION_LABEL" \
      --json number,title,url \
      --limit "$LIMIT"); then
      echo "warn: ready query failed once — retried after 30s and succeeded (transient API blip absorbed)" >&2
    else
      echo "warn: could not list ready issues (gh issue list) — reporting an empty ready bucket this run (fail-closed)" >&2
      ready_query_unavailable=true
      ready='[]'
    fi
  fi
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
escalation_records_skipped=0
plan_marker_quoters=0
harness_marker_quoters=0
missing_association=0
plan_after_approval=0
no_approval_event=0
approval_unreadable=0
post_approval_comments=0
plan_edited_after_approval=0
plan_edit_unreadable=0
decision_edited_after_approval=0
decision_edit_unreadable=0
approval_label_absent=0
closed_after_approval=0
for n in $ready_numbers; do
  # Tolerate per-issue failures: one transient gh/API error must not kill the whole
  # discovery run (matters for unattended/scheduled runs). #284: a first failure is retried once
  # after the same guarded RETRY_SLEEP backoff used above; only if BOTH attempts fail is the
  # issue skipped — simply reconsidered next time. In --issue mode, `issue` was already fetched
  # above — reuse it rather than fetching it twice (and never enter this retry at all).
  if [ -n "$prefetched_issue" ]; then
    issue="$prefetched_issue"
  elif ! issue=$(gh issue view "$n" --json number,title,url,comments,labels 2>/dev/null); then
    fetch_retries=$((fetch_retries+1))
    sleep "$RETRY_SLEEP" || true
    if issue=$(gh issue view "$n" --json number,title,url,comments,labels 2>/dev/null); then
      echo "warn: issue #$n: fetch failed once — retried after 30s and succeeded (transient API blip absorbed)" >&2
    else
      echo "warn: could not fetch issue #$n — skipping it this run" >&2
      fetch_failures=$((fetch_failures+1))
      continue
    fi
  fi
  # #229 — current label state, read from the SAME issue document as everything else here (no
  # extra API call): tolerant of both a `{"name": "..."}` object element (gh's real shape, live-
  # probed 2026-09-06) and a bare-string element, fail-closed to absent when the labels key is
  # missing entirely or an element's name can't be determined.
  has_approval_label=$(printf '%s' "$issue" | jq -r '
    [ (.labels // [])[] | if type == "object" then (.name // "") else tostring end ]
    | index("plan-approved") != null')

  result=$(printf '%s' "$issue" | jq --arg m "$PLAN_MARKER" --arg v "$VERDICT_MARKER" --arg a "$AUDIT_MARKER" --arg e "$ESCALATION_MARKER" --arg hrm "$HARNESS_RECORD_MARKERS" --arg trusted "$TRUSTED_ASSOCIATIONS" '
    ($trusted | split(" ")) as $ok
    | ($hrm | split("\n") | map(select(length > 0))) as $hm
    | (.comments // []) as $c
    | ($c | map(select( ((.authorAssociation // "") | ascii_upcase) as $assoc | ($ok | index($assoc)) != null ))) as $trustedC
    # #281 (superseding #275) — plan-candidate set: a trusted comment is a plan candidate only if
    # its body OPENS WITH (startswith, anchored to the first line of the comment) the plan marker
    # itself, positively — not "$trustedC minus a harness-marker exclusion" any more. Because
    # startswith($m) implies both contains($m) and the negation of startswith($a)/startswith($v)
    # (no marker string is a prefix of another), this positive anchor subsumes the #275 record
    # exclusion (a harness-authored record opens with its OWN marker, never the plan marker) and
    # additionally closes the gap #275 left open: a record whose harness marker is preceded by
    # prose, that also quotes the plan marker mid-body, is excluded here too, because it does not
    # open with the plan marker either (observed live on #245: an audit comment quoting
    # "<!-- planner-plan -->" was selected as `plan`, and because it postdated the plan-approved
    # label the approval was reported covers_plan: false — the real plan two comments earlier was
    # never considered; the #281 follow-up generalised the same failure to a record whose marker
    # is preceded by prose).
    #
    # startswith, not the contains() exclusion trusted_post_plan below still uses: over-excluding
    # HERE is the destructive direction — a real plan comment that quotes a harness marker in its
    # own prose (the plan comment for this very issue, for instance) would become unselectable,
    # reporting plan: null / reason: no-plan and prompting issue-implementer skill step 2a to strip
    # plan-approved and post a revision-triggering comment, reproducing this same failure through a
    # new trigger. The planner skill posts the plan marker as the first line of the comment (see
    # step 2c, the "must be exactly" block), so anchoring costs nothing against a harness-posted
    # plan.
    #
    # Honest limit: a hand-posted plan comment with anything before the marker is not selectable
    # here (repost it with the marker as the first line — editing the comment in place would trip
    # the #192 plan-edited-after-approval check instead). A trusted comment that quotes the plan
    # marker mid-body is now excluded from plan candidacy here AND was already excluded from
    # trusted_post_plan below by its own contains($m) test — #302 (see plan_marker_quoters below)
    # warns about exactly this class by name, instead of dropping it with no diagnostic (mirrors
    # the identical comment in the $planC binding of find-planning-work.sh).
    | ($trustedC | map(select(.body | startswith($m)))) as $planC
    | ([ $planC[] | .createdAt ] | max) as $lastPlan
    # #240 — bind the plan selection and the post-plan selection each exactly once, as the raw
    # (unprojected) comment objects, so both the projected `plan`/`trusted_post_plan` members below
    # AND the two internal edit-flag members can read the same selection without re-running the
    # filter twice or drifting out of index alignment with each other.
    | ([ $planC[] | select(.createdAt == $lastPlan) ] | last) as $planSel
    | (
        if $lastPlan == null then []
        else [ $trustedC[]
               | select((.body | contains($m)) | not)
               | select((.body | contains($v)) | not)
               | select((.body | contains($a)) | not)
               | select((.body | contains($e)) | not)
               | select(.createdAt > $lastPlan) ]
        end
      ) as $tppSel
    | {
        plan: (
          $planSel
          | if . == null then null
            else { author: (.author.login // "unknown"), association: (.authorAssociation // ""),
                   createdAt: .createdAt, url: (.url // null) }
            end
        ),
        trusted_post_plan: (
          $tppSel | map({ author: (.author.login // "unknown"), association: (.authorAssociation // ""),
                           createdAt: .createdAt, url: (.url // null) })
        ),
        untrusted_post_plan: [ $c[]
          | select( ((.authorAssociation // "") | ascii_upcase) as $assoc | ($ok | index($assoc)) == null )
          | select(.createdAt > ($lastPlan // ""))
          | { author: (.author.login // "unknown"),
              association: (.authorAssociation // "MISSING"),
              createdAt: .createdAt,
              url: (.url // null),
              has_plan_marker: (.body | contains($m)),
              has_harness_marker: ((.body | contains($a)) or (.body | contains($v)) or (.body | contains($e))) } ],
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
        ),
        # (#309) — comments dropped from trusted_post_plan for the escalation-record reason alone,
        # the same contains($e)/createdAt > $lastPlan shape as verdict_archives_skipped/
        # audit_comments_skipped above: a durable-escalation record itself, or a trusted comment
        # quoting that marker mid-body, is not binding context.
        escalation_records_skipped: (
          if $lastPlan == null then 0
          else ([ $trustedC[] | select(.body | contains($e)) | select(.createdAt > $lastPlan) ] | length)
          end
        ),
        # #302 — comments dropped from BOTH plan candidacy and trusted_post_plan for the
        # plan-marker reason alone: the window mirrors untrusted_post_plan above (posted after the
        # latest trusted plan, or at any time when there is none); within that window, a trusted
        # comment whose body contains the plan marker anywhere already means it does not open with
        # it (a comment that DOES open with the marker is itself a plan candidate, so its createdAt
        # cannot be later than $lastPlan) — so this member needs no startswith and never references
        # $planC; harness records are excluded exactly as trusted_post_plan excludes them above.
        # Internal only — never copied into `entry` below, published only via
        # counts.plan_marker_quoters.
        plan_marker_quoters: [ $trustedC[]
          | select(.createdAt > ($lastPlan // ""))
          | select(.body | contains($m))
          | select((.body | contains($a)) | not)
          | select((.body | contains($v)) | not)
          | select((.body | contains($e)) | not)
          | { author: (.author.login // "unknown"), createdAt: .createdAt, url: (.url // null) } ],
        # (#321) — comments dropped from trusted_post_plan for the harness-record reason alone:
        # the same window as the member above; within it, a trusted comment whose body contains
        # ANY marker in $hm anywhere but opens with NONE of them is a maintainer quoting a harness
        # record, not a harness record (every record this harness posts opens with its own marker
        # as the first line of the body). Harness records themselves are excluded by the second
        # select, positively, so this member never fires on a real run of the harness. Internal
        # only — never copied into `entry` below, published only via counts.harness_marker_quoters.
        harness_marker_quoters: [ $trustedC[]
          | . as $cm
          | select(.createdAt > ($lastPlan // ""))
          | select(any($hm[]; . as $k | $cm.body | contains($k)))
          | select((any($hm[]; . as $k | $cm.body | startswith($k))) | not)
          | { author: (.author.login // "unknown"), createdAt: .createdAt, url: (.url // null) } ],
        # #240 — internal only (never added to `entry` below, so the published JSON is byte-
        # identical to before this change): gh own per-comment includesCreatedEdit boolean, already
        # present in the `comments` field this script fetches today at no extra API cost. Read as a
        # bare `.includesCreatedEdit`, NEVER `.includesCreatedEdit // null` or `// false` — the `//`
        # operator treats a real `false` as empty and would silently convert every genuine
        # "never edited" reading into "missing" (confirmed locally, outside this file, that
        # false // 1 prints 1 in jq), delivering zero of the savings this exists for. A bare
        # `.includesCreatedEdit` already yields jq null when the key or $planSel itself is absent,
        # with no operator needed.
        plan_includes_created_edit: ($planSel | if . == null then null else .includesCreatedEdit end),
        trusted_post_plan_edit_flags: ($tppSel | map(.includesCreatedEdit))
      }
  ')

  plan=$(printf '%s' "$result" | jq -c '.plan')
  trusted_post_plan=$(printf '%s' "$result" | jq -c '.trusted_post_plan')
  untrusted_post_plan=$(printf '%s' "$result" | jq -c '.untrusted_post_plan')
  # #240 — assigned unconditionally on every loop iteration, before it is ever read, so (unlike
  # #213's plan_url) it needs no separate per-iteration reset for `set -u`. "false"/"true" as jq's
  # raw (unquoted) boolean text, or "null" when there is no plan or the key is absent.
  plan_edit_flag=$(printf '%s' "$result" | jq -r '.plan_includes_created_edit')

  # #174 — approval binding: bind plan-approved to the SPECIFIC plan comment that was newest
  # when the label was last applied, not just to the issue-level label. Only makes the events
  # API call when there is a plan to bind (skips the issues already skipped for no_trusted_plan)
  # AND the plan-approved label is currently on the issue (#229's pre-filter above skips this
  # whole branch, and its events/plan-edit lookups below, at zero extra API cost, when it isn't).
  # #375 — the same call also returns `closed` events (still one call per issue, no extra API
  # cost), so a close at or after the newest plan-approved labeling can be detected below.
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
  # #213 — plan_url is read unconditionally below (even outside the branch that assigns it) to
  # build approved_at_history's binding_line, and history_json/approved_at_history feed the same
  # unconditional jq call; under `set -u` a stale value surviving from the PREVIOUS issue in this
  # loop (rather than this issue's own state) would silently leak across iterations instead of
  # aborting, so all three get an explicit per-iteration reset alongside the ones above. The
  # approval-label-absent pre-filter below and any other branch that never re-assigns them leaves
  # approved_at_history at its reset value, "[]" — see the plan_selection[].approval doc above.
  plan_url=""
  history_json="[]"
  approved_at_history="[]"
  closed_latest=""
  # #229 — the pre-filter: current label state is the authority, checked BEFORE the events lookup
  # and the #192 plan-edit lookup below, so a withdrawn approval costs zero further API calls.
  # Wins over no-plan (the most actionable fact — "the human withdrew approval" — regardless of
  # whether a trusted plan comment also happens to be missing); the separate "no maintainer-
  # authored plan comment" warn and counts.no_trusted_plan below still fire independently.
  if [ "$has_approval_label" != "true" ]; then
    reason="approval-label-absent"
    echo "warn: issue #$n: the plan-approved label is not on the issue now — approval withdrawn or never applied; not eligible" >&2
    approval_label_absent=$((approval_label_absent+1))
  elif [ "$plan" != "null" ]; then
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
        .[] | select((.event == "labeled" and .label.name == "plan-approved") or .event == "closed")
        | "\(.event) \(.created_at) \(.actor.login // "unknown")"
      ' 2>/dev/null); then
      covers_plan="null"
      reason="approval-unreadable"
      echo "warn: issue #$n: could not read plan-approved label events — approval unreadable" >&2
      approval_unreadable=$((approval_unreadable+1))
    else
      # #375 — closed_latest first, then narrow $events back down to the pre-#375
      # "<created_at> <actor>" shape: sed, not grep, for the same pipefail reason as below (a
      # `grep -v`/`grep` that matches nothing would exit 1 under `set -o pipefail` and abort the
      # script). Dropping the "closed ..." lines and stripping the "labeled " prefix from what
      # remains keeps `latest`/`history_json` below byte-identical to before this change.
      closed_latest=$(printf '%s\n' "$events" | sed -n 's/^closed \([^ ]*\).*$/\1/p' | sort | tail -1)
      events=$(printf '%s\n' "$events" | sed -n 's/^labeled //p')
      # sed, not `grep -v`, to drop blank lines: with `set -o pipefail`, a `grep -v` that
      # matches nothing (the common "no events" case) exits 1 and would abort the whole script
      # under `set -e`; `sed` exits 0 regardless of how many lines it deletes.
      latest=$(printf '%s\n' "$events" | sed '/^$/d' | sort | tail -1)
      # #213 — expose every real plan-approved labeling event, not just the newest, so the merge
      # floor can accept a PR body written under an earlier approval of the same plan: same
      # $events, same blank-line drop as $latest above; `unique` sorts ascending and dedupes
      # byte-identical event lines (two labeled events with the same created_at and actor collapse
      # to one), `reverse` makes the result newest-first, so history_json's first element is always
      # the SAME event $latest picks via `sort | tail -1`. `(. / " ")` splits "<created_at> <actor>"
      # the same way `cut -d' ' -f1` / `-f2-` do below, so approved_at derived from $latest and
      # from history_json[0] always agree. approved_by can differ from history_json[0]'s in the
      # narrow case of two plan-approved events sharing the identical created_at second with
      # different actor logins: shell `sort` (locale collation) and jq's `unique` (codepoint
      # order) can then order those two event lines differently, picking a different login as
      # "last" — approved_at itself is untouched, so the merge floor (which matches on approved_at,
      # never approved_by) is unaffected.
      history_json=$(printf '%s\n' "$events" | jq -R -s '
        split("\n") | map(select(length > 0)) | unique | reverse
        | map((. / " ") as $p | {approved_at: $p[0], approved_by: ($p[1:] | join(" "))})')
      if [ -z "$latest" ]; then
        reason="no-approval-event"
        echo "warn: issue #$n: no plan-approved labeling event found — approval does not cover this plan" >&2
        no_approval_event=$((no_approval_event+1))
      else
        approved_at=$(printf '%s' "$latest" | cut -d' ' -f1)
        approved_by=$(printf '%s' "$latest" | cut -d' ' -f2-)
        # #375 — a close at or after the newest plan-approved labeling consumes that approval: a
        # reopened issue needs a fresh one. A tie counts as closed-after (fail-closed; there is no
        # auto-approval reason for a tie here, unlike the plan_created/approved_at tie below, which
        # favours the auto-approval path that labels immediately after posting). Multi-PR KEEP
        # (bin/cleanup-after-merge.sh) never closes the issue, so the slice re-queue shape (labeled/
        # unlabeled pr-open events with no closed event) is unaffected. Re-approving after a reopen
        # (removing and re-adding plan-approved) moves approved_at past the close and restores
        # coverage.
        if [ -n "$closed_latest" ] && ! [[ "$approved_at" > "$closed_latest" ]]; then
          reason="closed-after-approval"
          echo "warn: issue #$n: issue was closed ($closed_latest) at or after its newest plan-approved label ($approved_at) — that approval was consumed by the close; a reopened issue needs a fresh approval, so it does not cover this plan" >&2
          closed_after_approval=$((closed_after_approval+1))
        elif [[ "$plan_created" > "$approved_at" ]]; then
          reason="plan-after-approval"
          echo "warn: issue #$n: plan comment ($plan_created) postdates the plan-approved label ($approved_at) — approval does not cover this plan" >&2
          plan_after_approval=$((plan_after_approval+1))
        else
          # #192 — plan-comment content binding: everything above proves WHICH comment and WHEN,
          # but an in-place edit of an already-approved comment moves neither its url, createdAt,
          # nor the plan-approved label. One extra read-only call, made ONLY here (an approval
          # that would otherwise cover the plan) AND ONLY when the #240 pre-filter below finds gh's
          # own includesCreatedEdit is not exactly false, compares the plan comment's REST updated_at
          # against the CURRENT (newest) approved_at computed above: an edit strictly after
          # approval un-covers the plan (a human must re-approve — removing and re-adding
          # plan-approved moves approved_at past the edit and re-covers it, the same audited path
          # #174/#194 already document); an edit before approval is covered on purpose (the
          # approver read the edited text); a tie counts as covered (same inclusive-boundary
          # convention as the plan_created/approved_at compare above). An unparseable comment id
          # or an unreadable/unprocessable lookup fails closed, matching #204's precedent for the
          # events lookup — approved_at/approved_by stay populated in that state, since the events
          # lookup itself already succeeded.
          # #240 — pre-filter checked FIRST, before the id-parse guard: gh's own includesCreatedEdit
          # on the plan comment already told us it was never edited (updated_at == createdAt), so
          # the id and the lookup below are moot either way — skip both, conclude covered, and emit
          # no warn. A never-edited comment with an unparseable url therefore concludes covered
          # here rather than falling into plan-edit-unreadable below. Honest limit: this is a
          # tripwire, not a control — a `false` GitHub reports for a comment that WAS edited would
          # skip this check silently too (see the script header's #240 note).
          if [ "$plan_edit_flag" = "false" ]; then
            covers_plan="true"
            reason="covered"
          elif [ -z "$plan_comment_id" ]; then
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

  # #194 workstream B — bind each trusted_post_plan comment to the SAME approval this entry's
  # binding_line uses: covered_by_approval is true when the comment did not arrive after the
  # newest plan-approved labeling event, false when it did (context only, reported, never
  # binding), and null when approved_at itself is unknown (fail-closed, mirrors approval.reason's
  # own unknown states). Reuses the same string `>` comparison already load-bearing on
  # $lastPlan/createdAt above. covered_by_approval_reason (#230) is present on EVERY entry: null
  # unless the per-comment edit check immediately below flips this entry to false/null, in which
  # case it names which of the two new reasons applies. Moved here — before the approved_at_history
  # decoration — so that check can read $trusted_post_plan before anything else does; nothing
  # between the old position (after approval_json) and here reads $trusted_post_plan either way.
  trusted_post_plan=$(printf '%s' "$trusted_post_plan" | jq -c --arg at "$approved_at" \
    'map(. + {covered_by_approval: (if $at == "" then null else ((.createdAt > $at) | not) end),
              covered_by_approval_reason: null})')

  # #230 — decision-comment content binding: everything above proves the ISSUE-LEVEL approval
  # covers the plan comment itself, but a covered trusted_post_plan comment (a maintainer's
  # RESOLVED: decision, restated to the implementer as binding) can ALSO be edited in place after
  # approval, moving neither its url nor its createdAt. Guarded on covers_plan = "true" and
  # nothing weaker — the branch that would otherwise conclude covered, after the #229 label
  # pre-filter and the #192 plan-edit check above both passed — so an already-uncovered or
  # withdrawn approval spends zero extra calls. One extra read-only call per COVERED
  # trusted_post_plan entry ONLY WHEN that entry's own gh-reported includesCreatedEdit is not
  # exactly false (the #240 pre-filter inside the loop below) — never every entry, never an
  # uncovered one, and never a covered entry gh itself already told us was never edited. No
  # author-plus-createdAt fallback: an entry whose edit state cannot be established is unreadable,
  # never silently covered. The loop runs in the CURRENT shell (no `printf | while` subshell,
  # which would lose $i's increments) — bash 3.2 has no `declare -A`/`mapfile`/`seq`.
  if [ "$covers_plan" = "true" ]; then
    n_tpp=$(printf '%s' "$trusted_post_plan" | jq 'length')
    decision_verdicts=""
    any_decision_edited=""
    any_decision_unreadable=""
    i=0
    while [ "$i" -lt "$n_tpp" ]; do
      entry_covered=$(printf '%s' "$trusted_post_plan" | jq -r --argjson i "$i" '.[$i].covered_by_approval')
      if [ "$entry_covered" = "true" ]; then
        d_url=$(printf '%s' "$trusted_post_plan" | jq -r --argjson i "$i" '.[$i].url // empty')
        d_author=$(printf '%s' "$trusted_post_plan" | jq -r --argjson i "$i" '.[$i].author')
        # #240 — gh's own per-comment includesCreatedEdit, read from $result (not $trusted_post_plan,
        # which carries only the projected/decorated fields), index-aligned with this entry since
        # trusted_post_plan_edit_flags was built via `map(...)` over the same $tppSel this entry's
        # index ranges over.
        d_edit_flag=$(printf '%s' "$result" | jq -r --argjson i "$i" '.trusted_post_plan_edit_flags[$i]')
        # Same two-clause idiom as plan_comment_id above: outer #issuecomment- presence gate,
        # inner digits-only guard — this id is interpolated into a `gh api` path.
        d_id=""
        case "$d_url" in
          *"#issuecomment-"*)
            d_id="${d_url##*#issuecomment-}"
            case "$d_id" in
              ''|*[!0-9]*) d_id="" ;;
            esac
            ;;
        esac
        d_verdict=""
        # #240 — pre-filter checked FIRST: gh's own flag already told us this comment was never
        # edited, so the id and the lookup below are moot — no gh api call, no warn. Same "tripwire,
        # not a control" honest limit as the plan-comment pre-filter above.
        if [ "$d_edit_flag" = "false" ]; then
          : # never edited ⇒ stays covered
        elif [ -z "$d_id" ]; then
          d_verdict="unreadable"
          echo "warn: issue #$n: trusted decision comment by $d_author (${d_url:-no url}) carries no #issuecomment-<id> — decision edit state unreadable" >&2
        elif ! d_updated=$(gh api "repos/{owner}/{repo}/issues/comments/$d_id" --jq '.updated_at // empty' 2>/dev/null); then
          d_verdict="unreadable"
          echo "warn: issue #$n: could not read the decision comment's updated_at ($d_url) — decision edit state unreadable" >&2
        elif [ -z "$d_updated" ]; then
          d_verdict="unreadable"
          echo "warn: issue #$n: could not read the decision comment's updated_at ($d_url) — decision edit state unreadable" >&2
        elif [[ "$d_updated" > "$approved_at" ]]; then
          d_verdict="edited"
          echo "warn: issue #$n: trusted decision comment by $d_author ($d_url) was edited ($d_updated) after the plan-approved label ($approved_at) — the approval does not cover the edited decision" >&2
        fi
        if [ "$d_verdict" = "edited" ]; then
          decision_verdicts="$decision_verdicts$i edited
"
          decision_edited_after_approval=$((decision_edited_after_approval+1))
          any_decision_edited="true"
        elif [ "$d_verdict" = "unreadable" ]; then
          decision_verdicts="$decision_verdicts$i unreadable
"
          decision_edit_unreadable=$((decision_edit_unreadable+1))
          any_decision_unreadable="true"
        fi
      fi
      i=$((i+1))
    done
    if [ -n "$decision_verdicts" ]; then
      # Index-keyed, not url-keyed — a null-url entry must still be annotatable.
      trusted_post_plan=$(printf '%s' "$decision_verdicts" | jq -R -s -c --argjson tpp "$trusted_post_plan" '
        (split("\n") | map(select(length > 0) | split(" "))) as $verdicts
        | reduce $verdicts[] as $v ($tpp;
            .[($v[0] | tonumber)] += {
              covered_by_approval: (if $v[1] == "edited" then false else null end),
              covered_by_approval_reason: (if $v[1] == "edited"
                then "decision-edited-after-approval" else "decision-edit-unreadable" end)
            })')
    fi
    # Edited beats unreadable when both occur on the same issue — false is definitive.
    if [ "$any_decision_edited" = "true" ]; then
      covers_plan="false"
      reason="decision-edited-after-approval"
    elif [ "$any_decision_unreadable" = "true" ]; then
      covers_plan="null"
      reason="decision-edit-unreadable"
    fi
  fi

  # #213 — decorate every history entry with the binding_line it would carry if IT were the
  # accepted approval (null when $covers_plan isn't "true": nothing is pasteable for a plan that
  # isn't covered), then derive the top-level binding_line from entry [0] — one template, not two.
  # `.[0].binding_line` on an empty array is jq's `null`, exactly the JSON `null` the existing
  # `--argjson bl` consumer below already expects for every non-covered case. Since #230's
  # decision-comment check above can also flip $covers_plan to false/null before this point runs,
  # every history entry's binding_line and the top-level binding_line are already correctly
  # nulled for that case too — no separate branching needed here.
  approved_at_history=$(printf '%s' "$history_json" | jq -c --arg n "$n" --arg pu "$plan_url" --arg covers "$covers_plan" '
    map(. + {binding_line: (if $covers == "true"
      then "<!-- harness-plan-binding: issue=" + $n + " plan=" + $pu + " approved-at=" + .approved_at + " -->"
      else null end)})')
  binding_line=$(printf '%s' "$approved_at_history" | jq -c '.[0].binding_line')
  approval_json=$(jq -n \
    --arg at "$approved_at" --arg by "$approved_by" --arg reason "$reason" --argjson covers "$covers_plan" \
    --argjson history "$approved_at_history" \
    '{approved_at: (if $at == "" then null else $at end),
      approved_by: (if $by == "" then null else $by end),
      covers_plan: $covers,
      reason: $reason,
      approved_at_history: $history}')

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
  # idiom as the plan-marker loop below. Narrowed by #230's covered_by_approval_reason == null
  # filter: an entry uncovered because IT WAS EDITED after approval already got its own, more
  # specific "was edited" warn and its own count above — reporting it again here under "posted
  # after the plan-approved label" would assert something the code did not check.
  uncovered_pairs=$(printf '%s' "$trusted_post_plan" | jq -r '.[] | select(.covered_by_approval == false and .covered_by_approval_reason == null) | "\(.author) (\(.createdAt))"')
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

  # warn (#302): a trusted comment posted after the latest plan (or, when there is none, at any
  # time) carries the plan marker somewhere in its body but does not open with it — never a plan
  # candidate, and (via the pre-existing contains($m) trusted_post_plan test) never binding either.
  # One line per such comment; harness records are excluded (diagnosed separately by the
  # audit/verdict counters above, never by this one).
  quoter_lines=$(printf '%s' "$result" | jq -r '.plan_marker_quoters[] | "\(.author) (\(.createdAt), \(.url // "no url"))"')
  if [ -n "$quoter_lines" ]; then
    while IFS= read -r desc; do
      [ -n "$desc" ] || continue
      echo "warn: issue #$n: trusted comment by $desc carries the plan marker but does not open with it — not the plan, and not in trusted_post_plan (not binding context)" >&2
      plan_marker_quoters=$((plan_marker_quoters+1))
    done <<<"$quoter_lines"
  fi

  # warn (#321): a trusted comment posted after the latest plan (or, when there is none, at any
  # time) carries a harness-record marker somewhere in its body but does not open with it — a
  # maintainer's quote, not a harness record, and (via the pre-existing contains($a)/contains($v)
  # trusted_post_plan tests) never binding either. One line per such comment.
  record_quoter_lines=$(printf '%s' "$result" | jq -r '.harness_marker_quoters[] | "\(.author) (\(.createdAt), \(.url // "no url"))"')
  if [ -n "$record_quoter_lines" ]; then
    while IFS= read -r desc; do
      [ -n "$desc" ] || continue
      echo "warn: issue #$n: trusted comment by $desc carries a harness record marker but does not open with it — not a harness record, and not in trusted_post_plan (not binding context)" >&2
      harness_marker_quoters=$((harness_marker_quoters+1))
    done <<<"$record_quoter_lines"
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

  issue_escalation_skipped=$(printf '%s' "$result" | jq '.escalation_records_skipped')
  escalation_records_skipped=$((escalation_records_skipped+issue_escalation_skipped))
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
  --argjson ers "$escalation_records_skipped" \
  --argjson ma "$missing_association" \
  --argjson paa "$plan_after_approval" \
  --argjson nae "$no_approval_event" \
  --argjson au "$approval_unreadable" \
  --argjson pac "$post_approval_comments" \
  --argjson peaa "$plan_edited_after_approval" \
  --argjson peu "$plan_edit_unreadable" \
  --argjson deaa "$decision_edited_after_approval" \
  --argjson deu "$decision_edit_unreadable" \
  --argjson ala "$approval_label_absent" \
  --argjson caa "$closed_after_approval" \
  --argjson rqr "$ready_query_retried" \
  --argjson rqu "$ready_query_unavailable" \
  --argjson fr "$fetch_retries" \
  --argjson pmq "$plan_marker_quoters" \
  --argjson hmq "$harness_marker_quoters" \
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
             escalation_records_skipped: $ers,
             missing_association: $ma,
             plan_after_approval: $paa,
             no_approval_event: $nae,
             approval_unreadable: $au,
             post_approval_comments: $pac,
             plan_edited_after_approval: $peaa,
             plan_edit_unreadable: $peu,
             decision_edited_after_approval: $deaa,
             decision_edit_unreadable: $deu,
             approval_label_absent: $ala,
             closed_after_approval: $caa,
             ready_query_retried: $rqr,
             ready_query_unavailable: $rqu,
             plan_marker_quoters: $pmq,
             harness_marker_quoters: $hmq,
             fetch_retries: $fr}}'
