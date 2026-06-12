#!/usr/bin/env bash
#
# setup-labels.sh
# One-time (idempotent) creation of all plan/implementation lifecycle labels this workflow uses.
# Safe to re-run: existing labels are updated, not duplicated.
#
# Labels:
#   plan-proposed  -> a plan has been posted; awaiting your review
#   plan-approved  -> you approved the plan; ready for the implementer
#   pr-open        -> a PR has been opened for the issue; awaiting your review/merge
#   impl-blocked   -> implementation hit a blocker; needs your input (remove to retry)
#   no-plan        -> opt-out: the planner ignores this issue entirely (tracking/discussion)
#
# Requesting plan changes does NOT use a label — just comment on the issue and the planner
# revises on its next run. Approval and the implementation states ARE labels (unambiguous signals).
#
# Requires: gh (authenticated). Run once per repo.
set -euo pipefail

create_or_update() {
  local name="$1" color="$2" desc="$3"
  if gh label list --limit 200 --json name --jq '.[].name' | grep -qx "$name"; then
    gh label edit "$name" --color "$color" --description "$desc"
  else
    gh label create "$name" --color "$color" --description "$desc"
  fi
}

create_or_update "plan-proposed" "0E8A16" "Planner posted a plan; awaiting human review (comment to request changes)"
create_or_update "plan-approved" "1D76DB" "Plan approved; ready for the implementer"
create_or_update "pr-open"       "5319E7" "PR opened for this issue; awaiting human review/merge"
create_or_update "impl-blocked"  "B60205" "Implementation hit a blocker; needs human input (remove to retry)"
create_or_update "no-plan"       "EEEEEE" "Excluded from the planning workflow; the planner ignores this issue"

echo "Labels are set up."
echo "Note: the old 'plan-changes-requested' label is no longer used. Delete it if you like:"
echo "  gh label delete plan-changes-requested --yes"
