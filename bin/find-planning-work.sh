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
#                        record, not a decision. #281 (superseding #275): plan candidates are
#                        restricted to trusted comments that OPEN WITH the plan marker itself, so
#                        a harness-authored record — which opens with its own marker, never the
#                        plan marker — is never a plan candidate either (see below).
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
# bucket instead of being silently dropped, so the human still sees them. A second restriction
# narrows the trusted set for a different purpose: a trusted comment containing
# "<!-- harness-audit -->" (a harness-authored audit/hygiene record) or "<!-- verifier-verdict -->"
# (the orchestrator's own archive) ANYWHERE in its body (contains, not anchored) is never treated
# as feedback, and is reported in counts.audit_comments_skipped / counts.verdict_archives_skipped
# instead. Separately, #281 (superseding #275) restricts which trusted comments are even eligible
# to become the latest plan: only a comment that OPENS WITH (startswith, anchored to the comment's
# first line, not contains) the plan marker itself is a plan candidate at all — a
# maintainer-authored record that merely QUOTES the plan marker in its prose, wherever its own
# harness marker sits (or absent entirely), is never mistaken for the plan (see the $planC comment
# in the script body for the anchoring rationale — over-exclusion there would throw an approved
# plan back into revision). Both restrictions only ever narrow the trusted set, so neither ever
# adds anything to untrusted_comments.
#
# #176 extends the same trust boundary to WHO OPENED the issue, not just who commented on it:
# both needs_initial_plan and needs_revision items now carry {author, association,
# trusted_author}, and every item with trusted_author: false ALSO appears in a new top-level
# untrusted_issue_authors array ({number, title, url, author, association, bucket}) — visible so
# the human sees it, but issue-planner's step 6b hard floor blocks auto-approval on it. Planning
# itself is NOT gated on issue authorship — a non-maintainer-authored issue is still planned; only
# auto-approval is blocked. #202: gh has never exposed an issue-level authorAssociation `--json`
# field (only on comments), so this association is read from GitHub's REST issues endpoint
# (author_association) into a number -> {author, association} map built once per run. An open
# issue absent from the map gets association "MISSING" and trusted_author: false — the same
# fail-closed rule the comment-side gate uses below. #246: if the REST call fails, the script
# retries it once after a single bounded backoff before giving up — mirroring the shape #223 (PR
# #244) gave the implementer side's re-run. Only if BOTH attempts fail does the script warn, set
# counts.author_association_unavailable: true, and leave the map empty, so EVERY issue's
# trusted_author is false for this run (fail-closed) rather than dying or silently trusting; a
# retry that succeeds sets counts.author_association_retried: true but never
# author_association_unavailable, and the map is built from the SECOND attempt's output. #272/#273
# extend the identical one-retry-then-fail-closed shape to the script's other three `gh` calls — the
# needs_initial_plan query, the revision-candidates query, and the per-candidate issue fetch inside
# the loop below — each with its own pair of counts flags/counter (see "counts gains" below); all
# four sites share the single ASSOCIATION_RETRY_SLEEP backoff constant (see its own comment ahead
# of the retry block).
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
# (count of the array above), author_association_unavailable (boolean, see above), and (#246)
# author_association_retried (boolean, true iff the first REST attempt failed, regardless of
# whether the retry succeeded — so retried && !unavailable is exactly "a blip was absorbed").
# #272/#273 add five more: initial_query_retried / initial_query_unavailable (the needs_initial_plan
# query below), candidates_query_retried / candidates_query_unavailable (the revision-candidates
# query below), and fetch_retries (how many per-candidate issue fetches inside the loop needed a
# retry, regardless of whether that retry succeeded) — the same *_retried / *_unavailable boolean
# pair #246 established, applied to the two `gh issue list` calls: *_retried is true iff that
# query's FIRST attempt failed; *_unavailable is true only if BOTH attempts failed, in which case
# that query's bucket (needs_initial_plan or needs_revision respectively) is reported empty for
# this run instead of aborting the script — every fail-closed and retry path still exits 0 with one
# complete JSON document. fetch_failures now counts only POST-RETRY per-candidate fetch failures (a
# candidate skipped after BOTH attempts) — a candidate whose first fetch failed but whose retry
# succeeded is a fetch_retries occurrence, not a fetch_failures one.
#
# #302 adds one more: plan_marker_quoters (how many trusted, post-latest-plan comments carried the
# plan marker somewhere in their body without opening with it — never a plan candidate, and, via
# the pre-existing contains($m) test, never counted as feedback either) plus one warn: line per
# such comment, naming its author, createdAt, and url (or the literal "no url"), so a comment that
# is dropped from both plan selection and feedback for this reason is no longer silent. Harness
# records are excluded from this count exactly as they are excluded from has_feedback above.
#
# #321 adds one more: harness_marker_quoters (how many trusted, post-latest-plan comments carried
# any marker in the harness-record marker set — HARNESS_RECORD_MARKERS below — somewhere in their
# body without opening with one) plus one warn: line per such comment ("... carries a harness
# record marker but does not open with it — not a harness record, and not counted as feedback"),
# naming its author, createdAt, and url (or the literal "no url"). The window is the same as
# plan_marker_quoters above (posted after the latest trusted plan, or at any time when there is
# none). Harness records are excluded positively, by a startswith test against the same set: every
# record this harness posts opens with its own marker as the first line of the body, so this count
# never fires on a genuine harness-authored comment. Honest limit: a harness record with anything
# (even whitespace) before its marker would be counted here, and a maintainer comment that begins
# with a verbatim marker copy at byte 0 is still dropped from feedback silently — no count, no
# warn — tracked as a separate follow-up.
#
# #309 adds a third marker to HARNESS_RECORD_MARKERS, ESCALATION_MARKER ("<!-- harness-escalation
# -->" — distinct from, and never cross-matched with, the pre-existing
# "<!-- harness-escalation: bucket=... stage=... -->" key the planner skill's own step-7
# stalled-stage record uses — see skills/issue-planner/SKILL.md), and one more counter to go with
# it: escalation_records_skipped (how many trusted, post-latest-plan comments contained the
# escalation marker — a durable-escalation record itself, or a trusted comment quoting that marker
# mid-body — excluded from has_feedback via the same contains($e)/createdAt > $lastPlan shape
# audit_comments_skipped/verdict_archives_skipped already use). A quoter comment is therefore
# counted by BOTH escalation_records_skipped and harness_marker_quoters, the same double-counting
# the pre-existing per-marker counters already have with harness_marker_quoters.
#
# Wall clock: the retry budget is deliberately UNCAPPED — one retry per site (the REST
# author-association lookup, the needs_initial_plan query, the revision-candidates query) plus one
# retry per candidate in the per-candidate fetch loop, no run-level ceiling on top of that. Worst
# case this run sleeps ASSOCIATION_RETRY_SLEEP seconds × (1 author-association retry + 1
# initial-query retry + 1 candidates-query retry + up to LIMIT candidate-fetch retries) — at the
# current LIMIT=100 and a 30s backoff, ~50 minutes if every single call in the run fails once and
# then succeeds on its retry. In practice a broad outage fails the candidates query on BOTH
# attempts first (it runs before the per-candidate loop), which fails closed and skips the loop
# entirely, so the run only ever pays for the handful of retries that precede the loop, never for
# N candidates.
#
# Skipped automatically:
#   - plan-proposed with no newer trusted non-plan comment -> awaiting your review, nothing to do
#   - plan-approved                                -> handed off to the implementer
#   - needs-human (#309)                           -> a durable escalation is waiting on a human;
#                                                      excluded from both buckets until they remove
#                                                      the label (see ESCALATION_LABEL below)
#
# To request a revision: a maintainer (OWNER/MEMBER/COLLABORATOR) comments on the issue. To
# approve: add the plan-approved label.
#
# Requires: gh (authenticated), jq. Run from anywhere inside the repo.
set -euo pipefail

LIMIT=100
# ESCALATION_LABEL (#309) — the durable-escalation label a skill applies (see
# skills/issue-implementer/SKILL.md's "Durable escalation" subsection) and the dedupe mechanism:
# every discovery query below excludes it, so an escalated issue is never rediscovered until a
# human removes it. Declared byte-identically in bin/find-implementation-work.sh and
# bin/harness-status.sh (gate assertion 4.48).
ESCALATION_LABEL="needs-human"
PLAN_MARKER="<!-- planner-plan -->"
AUDIT_MARKER="<!-- harness-audit -->"
VERDICT_MARKER="<!-- verifier-verdict -->"
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
# everything else is reported in untrusted_comments and never acted on. To act on an
# outside contributor's suggestion, a maintainer comments themselves.
TRUSTED_ASSOCIATIONS="OWNER MEMBER COLLABORATOR"

# #202: gh has never exposed an issue-level authorAssociation `--json` field, so author
# provenance is read from GitHub's REST issues endpoint into a number -> {author, association}
# map, joined into both buckets below by issue number. read_issue_authors is the ONE copy of that
# REST call (below, retried on failure) — the leading `.[] | ` in its --jq filter is load-bearing:
# `gh api --paginate --jq` applies the filter to each page as ONE array document, not once per
# element (the #196 lesson) — drop it and jq errors on the array, gh exits 1, and this branch
# fail-closes for the wrong reason instead of building the map.
read_issue_authors() {
  gh api "repos/{owner}/{repo}/issues?state=open&per_page=100" --paginate --jq '
    .[] | select(.pull_request == null)
    | "\(.number) \(.author_association // "MISSING") \(.user.login // "unknown")"
  ' 2>/dev/null
}

# #246: one bounded retry of read_issue_authors before fail-closing the whole run — the common
# transient-API-blip case would otherwise cost an entire unattended cycle's auto-approval floor
# (skills/issue-planner/SKILL.md step 6b), mirroring the shape #223 (PR #244) gave the implementer
# side's own re-run. ASSOCIATION_RETRY_SLEEP is the single backoff constant — named for its first
# use here (#246), it is now shared by all four retry sites in this script (#272/#273): this REST
# lookup, the needs_initial_plan query, the revision-candidates query, and the per-candidate issue
# fetch inside the loop below. The sleep is guarded
# (`|| true`) so a failing `sleep` itself can never abort the run under this script's own
# set -euo pipefail (M3's fixture in dev/planning-tests.sh pins the guard). The map is built once, from whichever
# attempt succeeded (never from a failed attempt's empty capture) — guarded on
# author_association_unavailable being false rather than on $rest_lines' post-failure value.
ASSOCIATION_RETRY_SLEEP=30
author_association_unavailable=false
author_association_retried=false
issue_authors="{}"
if ! rest_lines=$(read_issue_authors); then
  author_association_retried=true
  sleep "$ASSOCIATION_RETRY_SLEEP" || true
  if rest_lines=$(read_issue_authors); then
    echo "warn: issue author association lookup failed once — retried after 30s and succeeded (transient API blip absorbed)" >&2
  else
    echo "warn: could not read issue author association (REST issues endpoint) — every issue author treated as untrusted this run (fail-closed)" >&2
    author_association_unavailable=true
  fi
fi
if [ "$author_association_unavailable" = false ]; then
  issue_authors=$(printf '%s\n' "$rest_lines" | jq -R -s -c '
    split("\n") | map(select(length > 0) | split(" ")) | map(select(length >= 3))
    | map({key: .[0], value: {association: .[1], author: .[2]}}) | from_entries
  ')
fi

initial_query_retried=false
initial_query_unavailable=false
candidates_query_retried=false
candidates_query_unavailable=false
fetch_retries=0
if ! needs_initial_plan=$(gh issue list \
  --search "is:open is:issue -label:plan-proposed -label:plan-approved -label:no-plan -label:$ESCALATION_LABEL" \
  --json number,title,url,author \
  --limit "$LIMIT"); then
  initial_query_retried=true
  sleep "$ASSOCIATION_RETRY_SLEEP" || true
  if needs_initial_plan=$(gh issue list \
    --search "is:open is:issue -label:plan-proposed -label:plan-approved -label:no-plan -label:$ESCALATION_LABEL" \
    --json number,title,url,author \
    --limit "$LIMIT"); then
    echo "warn: needs_initial_plan query failed once — retried after 30s and succeeded (transient API blip absorbed)" >&2
  else
    echo "warn: could not list issues needing an initial plan (gh issue list) — reporting an empty needs_initial_plan bucket this run (fail-closed)" >&2
    initial_query_unavailable=true
    needs_initial_plan='[]'
  fi
fi

# Annotate needs_initial_plan items with author/association/trusted_author from the REST map.
# An issue absent from the map (author_association_unavailable, or simply not returned by the
# REST call this run) resolves to association "MISSING" and trusted_author: false — fail-closed,
# the same rule the comment-side gate uses.
needs_initial_plan=$(printf '%s' "$needs_initial_plan" | jq --arg trusted "$TRUSTED_ASSOCIATIONS" --argjson map "$issue_authors" '
  ($trusted | split(" ")) as $ok
  | map(($map[(.number|tostring)] // {}) as $p
        | {number, title, url,
           author: ($p.author // .author.login // "unknown"),
           association: (($p.association // "MISSING") | ascii_upcase),
           trusted_author: ((($p.association // "") | ascii_upcase) as $assoc | ($ok | index($assoc)) != null)
          })
')

# Candidates for revision: awaiting review, not yet approved, not opted out.
if ! candidates=$(gh issue list \
  --search "is:open is:issue label:plan-proposed -label:plan-approved -label:no-plan -label:$ESCALATION_LABEL" \
  --json number \
  --limit "$LIMIT" --jq '.[].number' | tr -d '\r'); then
  candidates_query_retried=true
  sleep "$ASSOCIATION_RETRY_SLEEP" || true
  if candidates=$(gh issue list \
    --search "is:open is:issue label:plan-proposed -label:plan-approved -label:no-plan -label:$ESCALATION_LABEL" \
    --json number \
    --limit "$LIMIT" --jq '.[].number' | tr -d '\r'); then
    echo "warn: revision-candidates query failed once — retried after 30s and succeeded (transient API blip absorbed)" >&2
  else
    echo "warn: could not list revision candidates (gh issue list) — reporting an empty needs_revision bucket this run (fail-closed)" >&2
    candidates_query_unavailable=true
    candidates=""
  fi
fi

needs_revision="[]"
untrusted_comments="[]"
fetch_failures=0
untrusted_comment_total=0
untrusted_plan_markers=0
untrusted_harness_markers=0
missing_association=0
audit_comments_skipped=0
verdict_archives_skipped=0
escalation_records_skipped=0
plan_marker_quoters=0
harness_marker_quoters=0
for n in $candidates; do
  # Tolerate per-issue failures: one transient gh/API error must not kill the whole
  # discovery run (matters for unattended/scheduled runs). #272: a first failure is retried once
  # after the same guarded ASSOCIATION_RETRY_SLEEP backoff used above; only if BOTH attempts fail
  # is the issue skipped — simply reconsidered next time.
  if ! issue=$(gh issue view "$n" --json number,title,url,author,comments 2>/dev/null); then
    fetch_retries=$((fetch_retries+1))
    sleep "$ASSOCIATION_RETRY_SLEEP" || true
    if issue=$(gh issue view "$n" --json number,title,url,author,comments 2>/dev/null); then
      echo "warn: issue #$n: fetch failed once — retried after 30s and succeeded (transient API blip absorbed)" >&2
    else
      echo "warn: could not fetch issue #$n — skipping it this run" >&2
      fetch_failures=$((fetch_failures+1))
      continue
    fi
  fi
  result=$(printf '%s' "$issue" | jq --arg m "$PLAN_MARKER" --arg a "$AUDIT_MARKER" --arg v "$VERDICT_MARKER" --arg e "$ESCALATION_MARKER" --arg hrm "$HARNESS_RECORD_MARKERS" --arg trusted "$TRUSTED_ASSOCIATIONS" '
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
    # open with the plan marker either (observed live on #245, and the #281 follow-up that
    # generalised it: an audit-style comment quoting "<!-- planner-plan -->" mid-body was picked
    # as the plan).
    #
    # startswith, not the contains() the feedback exclusion below still uses: over-excluding HERE
    # is the destructive direction — a real plan comment that quotes a harness marker in its own
    # prose (the plan comment for this very issue, for instance) would become unselectable,
    # throwing an approved plan back into needs_revision for no human reason. The planner skill
    # posts the plan marker as the first line of the comment (see step 2c, the "must be exactly"
    # block), so anchoring costs nothing against a harness-posted plan.
    #
    # Honest limit: a hand-posted plan comment with anything before the marker is not selectable
    # here (repost it with the marker as the first line — editing the comment in place would trip
    # the #192 plan-edited-after-approval check instead). A trusted comment that quotes the plan
    # marker mid-body is now excluded from plan candidacy here AND was already excluded from the
    # feedback set below by its own contains($m) test — #302 (see plan_marker_quoters below) warns
    # about exactly this class by name, instead of dropping it with no diagnostic.
    | ($trustedC | map(select(.body | startswith($m)))) as $planC
    | ([ $planC[] | .createdAt ] | max) as $lastPlan
    | {
        has_feedback: (
          if $lastPlan == null then false
          else ([ $trustedC[]
                  | select((.body | contains($m)) | not)
                  | select((.body | contains($a)) | not)
                  | select((.body | contains($v)) | not)
                  | select((.body | contains($e)) | not)
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
              has_harness_marker: ((.body | contains($a)) or (.body | contains($v)) or (.body | contains($e))) } ],
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
        ),
        # (#309) — comments dropped from the feedback set for the escalation-record reason alone,
        # the same contains($e)/createdAt > $lastPlan shape as audit_comments_skipped/
        # verdict_archives_skipped above: a durable-escalation record itself, or a trusted comment
        # quoting that marker mid-body, is not feedback.
        escalation_records_skipped: (
          if $lastPlan == null then 0
          else ([ $trustedC[] | select(.body | contains($e)) | select(.createdAt > $lastPlan) ] | length)
          end
        ),
        # #302 — comments dropped from BOTH plan selection and feedback for the plan-marker reason
        # alone: the window mirrors the untrusted bucket above (posted after the latest trusted
        # plan, or at any time when there is none); within that window, a trusted comment whose
        # body contains the plan marker anywhere already means it does not open with it (a comment
        # that DOES open with the marker is itself a plan candidate, so its createdAt cannot be
        # later than $lastPlan) — so this member needs no startswith and never references $planC;
        # harness records are excluded exactly as the feedback set above excludes them, so an
        # audit or verdict record that also quotes the plan marker is not warned about by this
        # member — the harness_marker_quoters member below names the ones that do not open with a
        # harness marker.
        plan_marker_quoters: [ $trustedC[]
          | select(.createdAt > ($lastPlan // ""))
          | select(.body | contains($m))
          | select((.body | contains($a)) | not)
          | select((.body | contains($v)) | not)
          | select((.body | contains($e)) | not)
          | { author: (.author.login // "unknown"), createdAt: .createdAt, url: (.url // null) } ],
        # (#321) — comments dropped from the feedback set for the harness-record reason
        # alone: the same window as the member above; within it, a trusted comment whose body
        # contains ANY marker in $hm anywhere but opens with NONE of them is a maintainer quoting a
        # harness record, not a harness record (every record this harness posts opens with its own
        # marker as the first line of the body). Harness records themselves are excluded by the
        # second select, positively, so this member never fires on a real run of the harness.
        harness_marker_quoters: [ $trustedC[]
          | . as $cm
          | select(.createdAt > ($lastPlan // ""))
          | select(any($hm[]; . as $k | $cm.body | contains($k)))
          | select((any($hm[]; . as $k | $cm.body | startswith($k))) | not)
          | { author: (.author.login // "unknown"), createdAt: .createdAt, url: (.url // null) } ]
      }
  ')

  has_feedback=$(printf '%s' "$result" | jq -r '.has_feedback')
  if [ "$has_feedback" = "true" ]; then
    entry=$(printf '%s' "$issue" | jq --arg trusted "$TRUSTED_ASSOCIATIONS" --argjson map "$issue_authors" '
      ($trusted | split(" ")) as $ok
      | ($map[(.number|tostring)] // {}) as $p
      | {number, title, url,
         author: ($p.author // .author.login // "unknown"),
         association: (($p.association // "MISSING") | ascii_upcase),
         trusted_author: ((($p.association // "") | ascii_upcase) as $assoc | ($ok | index($assoc)) != null)
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

  # warn (#302): a trusted comment posted after the latest plan (or, when there is none, at any
  # time) carries the plan marker somewhere in its body but does not open with it — never a plan
  # candidate, and (via the pre-existing contains($m) feedback test) never counted as feedback
  # either. One line per such comment; harness records are excluded (diagnosed separately by the
  # audit/verdict counters above, never by this one).
  quoter_lines=$(printf '%s' "$result" | jq -r '.plan_marker_quoters[] | "\(.author) (\(.createdAt), \(.url // "no url"))"')
  if [ -n "$quoter_lines" ]; then
    while IFS= read -r desc; do
      [ -n "$desc" ] || continue
      echo "warn: issue #$n: trusted comment by $desc carries the plan marker but does not open with it — not the plan, and not counted as feedback" >&2
      plan_marker_quoters=$((plan_marker_quoters+1))
    done <<<"$quoter_lines"
  fi

  # warn (#321): a trusted comment posted after the latest plan (or, when there is none, at any
  # time) carries a harness-record marker somewhere in its body but does not open with it — a
  # maintainer's quote, not a harness record, and (via the pre-existing contains($a)/contains($v)
  # feedback tests) never counted as feedback either. One line per such comment.
  record_quoter_lines=$(printf '%s' "$result" | jq -r '.harness_marker_quoters[] | "\(.author) (\(.createdAt), \(.url // "no url"))"')
  if [ -n "$record_quoter_lines" ]; then
    while IFS= read -r desc; do
      [ -n "$desc" ] || continue
      echo "warn: issue #$n: trusted comment by $desc carries a harness record marker but does not open with it — not a harness record, and not counted as feedback" >&2
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

  issue_audit_skipped=$(printf '%s' "$result" | jq '.audit_comments_skipped')
  audit_comments_skipped=$((audit_comments_skipped+issue_audit_skipped))

  issue_verdict_skipped=$(printf '%s' "$result" | jq '.verdict_archives_skipped')
  verdict_archives_skipped=$((verdict_archives_skipped+issue_verdict_skipped))

  issue_escalation_skipped=$(printf '%s' "$result" | jq '.escalation_records_skipped')
  escalation_records_skipped=$((escalation_records_skipped+issue_escalation_skipped))
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
  --argjson ers "$escalation_records_skipped" \
  --argjson uiac "$untrusted_issue_author_count" \
  --argjson aau "$author_association_unavailable" \
  --argjson aar "$author_association_retried" \
  --argjson iqr "$initial_query_retried" \
  --argjson iqu "$initial_query_unavailable" \
  --argjson cqr "$candidates_query_retried" \
  --argjson cqu "$candidates_query_unavailable" \
  --argjson fr "$fetch_retries" \
  --argjson pmq "$plan_marker_quoters" \
  --argjson hmq "$harness_marker_quoters" \
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
             escalation_records_skipped: $ers,
             untrusted_issue_authors: $uiac,
             author_association_unavailable: $aau,
             author_association_retried: $aar,
             initial_query_retried: $iqr,
             initial_query_unavailable: $iqu,
             candidates_query_retried: $cqr,
             candidates_query_unavailable: $cqu,
             plan_marker_quoters: $pmq,
             harness_marker_quoters: $hmq,
             fetch_retries: $fr}}'
