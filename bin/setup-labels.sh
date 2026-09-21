#!/usr/bin/env bash
#
# setup-labels.sh
# One-time (idempotent) creation of all plan/implementation lifecycle labels this workflow uses.
# Safe to re-run: existing labels are updated, not duplicated.
#
# Labels:
#   plan-proposed   -> a plan has been posted; awaiting your review
#   plan-approved   -> you approved the plan; ready for the implementer
#   pr-open         -> a PR has been opened for the issue; awaiting your review/merge
#   impl-blocked    -> implementation hit a blocker; needs your input (remove to retry)
#   no-plan         -> opt-out: the planner ignores this issue entirely (tracking/discussion);
#                      the issue-implementer skill also applies it to every follow-up issue it
#                      files, holding each one out of planning until a human triages it and
#                      removes the label; and cleanup-after-merge.sh --fix applies it to a plan
#                      follow-up (filed by an older harness version) orphaned when its source PR
#                      was closed without merging
#   no-auto-approve -> human-only veto: this issue's plans are never auto-approved, even if
#                      CLAUDE.md defines an auto-approval policy; approval must be manual. The
#                      harness never applies this label to any issue it files — only a human does.
#   test-ratchet    -> provenance: filed by the test-ratchet skill under the repo's CLAUDE.md
#                      "Test-suite ratchet policy". The planner's hard floor refuses to
#                      auto-approve any issue carrying this label, so it always waits for a
#                      human's manual approval; close it as "not planned" to veto that gap for
#                      good.
#   multi-pr        -> human-applied: the primary signal cleanup-after-merge.sh reads to leave
#                      a multi-PR issue open when one of its slices merges (the issue-body
#                      marker is no longer honoured; a maintainer comment marker still is).
#   needs-human     -> a durable escalation (#309): a skill asked a question and moved on rather
#                      than blocking. The label is the dedupe — all three discovery queries
#                      exclude it, so the issue stays out of planning and implementation until a
#                      human answers and removes it. See skills/issue-implementer/SKILL.md's
#                      "Durable escalation" subsection.
#   harness-stop    -> human-only, repo-wide stop signal (#310): any open issue carrying it stops
#                      an issue-cycle run — one already in progress included — at its next checked
#                      stage boundary, and a standalone issue-planner or issue-implementer run at
#                      its own per-issue dispatch loop (bin/harness-stop.sh reads it — see that
#                      script's own header). The harness only ever reads this label; it never
#                      applies or removes it, and gate assertion 4.49 forbids naming it in a
#                      --label/--add-label/--remove-label argument anywhere in skills/*/SKILL.md,
#                      skills/*/references/*.md, agents/*.md, or bin/*.sh (dev/stop-tests.sh's own
#                      fixture legitimately carries that literal as an expected test-output
#                      string, outside that scanned surface).
#
# Requesting plan changes does NOT use a label — just comment on the issue and the planner
# revises on its next run. Approval and the implementation states ARE labels (unambiguous signals).
#
# Requires: gh (authenticated). Run once per repo.
set -euo pipefail

create_or_update() {
  local name="$1" color="$2" desc="$3" existing
  # Capture first, then a here-string membership test (#255) — not `gh label list | tr ... |
  # grep -qx ...`, whose `grep -qx` would exit on its first match and could send the upstream `gh`
  # a SIGPIPE, which `set -euo pipefail` would then report as a failed pipeline even on a genuine
  # match. The capture itself stays inside the `if` condition (`if existing="$(...)" && grep ...;
  # then`), preserving today's `set -e` exemption: a failing `gh label list` still falls through to
  # the `else` (create) branch instead of aborting the whole script, exactly as the old pipeline's
  # non-zero exit status did.
  if existing="$(gh label list --limit 200 --json name --jq '.[].name' | tr -d '\r')" && grep -qx -- "$name" <<<"$existing"; then
    gh label edit "$name" --color "$color" --description "$desc"
  else
    gh label create "$name" --color "$color" --description "$desc"
  fi
}

create_or_update "plan-proposed"   "0E8A16" "Planner posted a plan; awaiting human review (comment to request changes)"
create_or_update "plan-approved"   "1D76DB" "Plan approved; ready for the implementer"
create_or_update "pr-open"         "5319E7" "PR opened for this issue; awaiting human review/merge"
create_or_update "impl-blocked"    "B60205" "Implementation hit a blocker; needs human input (remove to retry)"
create_or_update "no-plan"         "EEEEEE" "Excluded from the planning workflow; the planner ignores this issue"
create_or_update "no-auto-approve" "FBCA04" "Human-only veto: never auto-approve this issue's plans (the harness never applies it)"
create_or_update "test-ratchet"    "006B75" "Filed by the test-suite ratchet; harness-authored coverage work"
create_or_update "multi-pr"        "C5DEF5" "Multi-PR issue: cleanup leaves it open when a slice's PR merges"
create_or_update "needs-human"     "D93F0B" "Harness asked a question and moved on; answer, then remove this label to release the issue"
create_or_update "harness-stop"    "000000" "Human-only stop switch: stops a run in progress, not just the next one (harness-stop.sh)"

echo "Labels are set up."
echo "Note: the old 'plan-changes-requested' label is no longer used. Delete it if you like:"
echo "  gh label delete plan-changes-requested --yes"
