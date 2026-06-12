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
# Requires: gh (authenticated), jq. Run from anywhere inside the repo.
set -euo pipefail

LIMIT=100

ready=$(gh issue list \
  --search "is:open is:issue label:plan-approved -label:pr-open -label:impl-blocked" \
  --json number,title,url \
  --limit "$LIMIT")

jq -n --argjson ready "$ready" \
  '{ready: $ready, counts: {ready: ($ready | length)}}'
