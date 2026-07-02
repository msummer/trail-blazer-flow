#!/usr/bin/env bash
#
# cleanup-after-merge.sh [--fix]
# Run after the human merges PR(s) opened by the issue-implementer skill. The planner /
# implementer / cycle skills also run it as part of their pre-flight, so manual runs are
# optional in the steady state.
#   1. Fast-forwards the default branch (only if currently checked out).
#   2. Deletes local claude/<n>-<slug> branches whose PRs are MERGED.
#   3. Label hygiene for open issues still labelled pr-open:
#        - PR merged but issue still open  -> "Closes #n" linkage probably missing
#        - PR closed WITHOUT merging       -> stale pr-open; the issue should requeue
#        - PR still open                   -> fine, awaiting review
#
# Without --fix: read-mostly and conservative — never switches branches, never
# force-deletes work that isn't merged, never edits labels (it only reports).
#
# With --fix, it additionally repairs the two label-hygiene cases (both audited with an
# issue comment):
#   - PR merged, issue still open  -> comment, remove pr-open, close the issue
#   - PR closed without merging    -> comment, remove pr-open (requeues the issue; the
#     old claude/* branch is left alone — the implementer's branch-exists logic decides
#     whether it can be reset or needs a human)
#
# Requires: gh (authenticated), jq, git. Run from anywhere inside the repo.
set -euo pipefail

FIX=false
[[ "${1:-}" == "--fix" ]] && FIX=true

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
      MERGED)
        if $FIX; then
          gh issue comment "$n" --body "🧹 Harness cleanup: PR #${prnum} for this issue was merged, but the issue didn't auto-close (the PR body was probably missing a working \`Closes #${n}\` link). Closing it now." >/dev/null
          gh issue edit "$n" --remove-label pr-open >/dev/null
          gh issue close "$n" >/dev/null
          echo "FIXED #${n} (${title}): PR #${prnum} merged — commented, removed pr-open, closed the issue"
        else
          echo "WARN  #${n} (${title}): PR #${prnum} merged but issue still open — check 'Closes #' linkage, close manually (or re-run with --fix)"
        fi
        ;;
      CLOSED)
        if $FIX; then
          gh issue comment "$n" --body "🧹 Harness cleanup: PR #${prnum} was closed without merging, so this issue has been requeued for implementation (\`pr-open\` removed). The old \`claude/${n}-*\` branch was left in place — the next implementer run resets it if it only contains wip commits, and asks a human otherwise." >/dev/null
          gh issue edit "$n" --remove-label pr-open >/dev/null
          echo "FIXED #${n} (${title}): PR #${prnum} closed without merge — commented, removed pr-open (issue requeued)"
        else
          echo "STALE #${n} (${title}): PR #${prnum} closed WITHOUT merge — remove pr-open to requeue (or re-run with --fix)"
        fi
        ;;
      OPEN)   echo "ok    #${n} (${title}): PR #${prnum} open, awaiting review" ;;
    esac
  done
fi

echo
echo "Reminder: the verification suite should be re-run on merged ${default_branch} — two green PRs can still compose badly. The implementer/cycle skills do this automatically in pre-flight (baseline refresh) when ${default_branch} has moved past .claude/BASELINE.md."
