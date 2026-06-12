#!/usr/bin/env bash
#
# cleanup-after-merge.sh
# Run after the human merges PR(s) opened by the issue-implementer skill.
#   1. Fast-forwards the default branch (only if currently checked out).
#   2. Deletes local claude/<n>-<slug> branches whose PRs are MERGED.
#   3. Label hygiene report for open issues still labelled pr-open:
#        - PR merged but issue still open  -> "Closes #n" linkage probably missing
#        - PR closed WITHOUT merging       -> stale pr-open; remove label to requeue
#        - PR still open                   -> fine, awaiting review
#
# Read-mostly and conservative: never switches branches, never force-deletes work
# that isn't merged, never edits labels itself (it only reports).
#
# Requires: gh (authenticated), jq, git. Run from anywhere inside the repo.
set -euo pipefail

default_branch=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
current=$(git branch --show-current)

echo "== sync ${default_branch} =="
if [[ "$current" == "$default_branch" ]]; then
  git pull --ff-only
else
  echo "On '${current}', not '${default_branch}' — skipping pull (switch manually first)."
fi

echo
echo "== local claude/* branches =="
branches=$(git for-each-ref --format='%(refname:short)' 'refs/heads/claude/*' || true)
if [[ -z "$branches" ]]; then
  echo "none"
else
  for b in $branches; do
    state=$(gh pr view "$b" --json state --jq .state 2>/dev/null || echo "NO_PR")
    if [[ "$state" == "MERGED" ]]; then
      if [[ "$b" == "$current" ]]; then
        echo "SKIP    $b — currently checked out; switch to ${default_branch} and re-run"
      else
        # -D because squash/rebase merges leave the branch tip unreachable from main
        git branch -D "$b" >/dev/null
        echo "deleted $b (PR merged)"
      fi
    else
      echo "kept    $b (PR state: ${state})"
    fi
  done
fi

echo
echo "== pr-open label hygiene =="
prs=$(gh pr list --state all --limit 200 --json number,state,headRefName)
issues=$(gh issue list --label pr-open --state open --json number,title --limit 100)

if [[ $(echo "$issues" | jq 'length') -eq 0 ]]; then
  echo "no open issues labelled pr-open"
else
  echo "$issues" | jq -c '.[]' | while read -r issue; do
    n=$(echo "$issue" | jq -r .number)
    title=$(echo "$issue" | jq -r .title)
    match=$(echo "$prs" | jq -c --arg p "claude/${n}-" \
      '[.[] | select(.headRefName | startswith($p))] | sort_by(.number) | last // empty')
    if [[ -z "$match" ]]; then
      echo "WARN  #${n} (${title}): labelled pr-open but no claude/${n}-* PR found"
      continue
    fi
    state=$(echo "$match" | jq -r .state)
    prnum=$(echo "$match" | jq -r .number)
    case "$state" in
      MERGED) echo "WARN  #${n} (${title}): PR #${prnum} merged but issue still open — check 'Closes #' linkage, close manually" ;;
      CLOSED) echo "STALE #${n} (${title}): PR #${prnum} closed WITHOUT merge — remove pr-open to requeue (and delete its branch)" ;;
      OPEN)   echo "ok    #${n} (${title}): PR #${prnum} open, awaiting review" ;;
    esac
  done
fi

echo
echo "Reminder: re-run the project's verification command on merged ${default_branch} — two green PRs can still compose badly."
