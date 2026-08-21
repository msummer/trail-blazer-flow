#!/usr/bin/env bash
#
# cleanup-after-merge.sh [--fix]
# Run after the human merges PR(s) opened by the issue-implementer skill. The planner /
# implementer / cycle skills also run it as part of their pre-flight, so manual runs are
# optional in the steady state.
#
# Every gh/git pre-flight lookup this script makes (the default branch via `gh repo view`, the
# current branch via `git branch --show-current`, the PR list via `gh pr list`, issues labelled
# pr-open via `gh issue list`, and follow-up candidates via `gh issue list --search`) is
# best-effort: a rate limit, an auth problem, or a network blip on any one of them is reported
# (WARN) and only the section(s) that depend on it are skipped — the script never aborts before
# printing output, and always reaches the closing reminder.
#
#   1. Best-effort fast-forward of the default branch (only if currently checked out, and only
#      when the default-branch and current-branch lookups above both succeeded): a diverged
#      local branch, a missing upstream, or a network blip is reported (WARN) and the script
#      continues — it never aborts the run.
#   2. Deletes local claude/<n>-<slug> branches whose PRs are MERGED. A merged branch still
#      held by a worktree can't be deleted (-D refuses); that's reported (SKIP) and skipped,
#      never fatal — same for any other delete failure (WARN, with git's stderr).
#   3. Label hygiene for open issues still labelled pr-open (skipped, with a WARN, if the PR
#      list or the pr-open issue list could not be fetched):
#        - PR merged, closing keyword present, no multi-PR signal -> issue should have
#          auto-closed but didn't; close it
#        - PR merged but the issue looks like one slice of a multi-PR issue (no closing
#          keyword, a "Part of #n" / "PR k of m" marker, an OPEN sibling PR, or a
#          <!-- harness-multi-pr --> opt-out) -> KEEP, leave the issue open
#        - PR closed WITHOUT merging       -> stale pr-open; the issue should requeue
#        - PR still open                   -> fine, awaiting review
#   4. Follow-ups filed from a claude/* PR that was closed WITHOUT merging (skipped, with a
#      WARN, if the PR list or the follow-up candidate search could not be fetched): reported;
#      with --fix, commented and labelled no-plan so the planner skips the orphaned work.
#
# Without --fix: read-mostly and conservative — never switches branches, never
# force-deletes work that isn't merged, never edits labels (it only reports).
#
# With --fix, it additionally repairs the label-hygiene cases:
#   - PR merged, issue still open, closing keyword present, no multi-PR signal -> comment,
#     remove pr-open, close the issue (audited with an issue comment)
#   - PR merged but a multi-PR signal is present (KEEP) -> issue stays open; pr-open is
#     removed (and the issue commented, once) only when no other claude/<n>-* PR is still
#     open, so the issue re-queues for its next slice — a human closes it by hand if the
#     work is actually finished
#   - PR closed without merging    -> comment, remove pr-open (requeues the issue; the
#     old claude/* branch is left alone — the implementer's branch-exists logic decides
#     whether it can be reset or needs a human)
# ...and quarantines orphaned plan follow-ups (also audited with an issue comment):
#   - follow-up filed from a claude/* PR closed without merging -> comment, add no-plan
#     (never closes the issue; a human removes no-plan to requeue it)
#
# Requires: gh (authenticated), jq, git. Run from anywhere inside the repo.
set -euo pipefail

FIX=false
[[ "${1:-}" == "--fix" ]] && FIX=true

default_branch_known=true
default_branch="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null | tr -d '\r' || true)"
if [[ -z "$default_branch" ]]; then
  default_branch_known=false
  default_branch=main  # message text only — the sync step below is skipped regardless
fi

current_known=true
if current="$(git branch --show-current 2>/dev/null)"; then
  :
else
  current=""
  current_known=false
fi

echo "== sync ${default_branch} =="
if ! $default_branch_known; then
  echo "WARN    could not determine the default branch (gh repo view failed — rate limit, auth, or network?) — skipping sync; the branch name '${default_branch}' above (and in messages below) is a guess and may be wrong."
elif ! $current_known; then
  echo "WARN    could not determine the current branch (git branch --show-current failed) — skipping sync; branch and label hygiene below are unaffected."
elif [[ "$current" == "$default_branch" ]]; then
  if ! git pull --ff-only; then
    echo "WARN    could not fast-forward ${default_branch} (diverged, no upstream, or network) — continuing; branch and label hygiene below are unaffected, but this checkout is NOT synced."
  fi
else
  echo "On '${current}', not '${default_branch}' — skipping pull (switch manually first)."
fi

echo
echo "== local claude/* branches =="
branches=$(git for-each-ref --format='%(refname:short)' 'refs/heads/claude/*' || true)
# Which branches a worktree holds, so a refused delete can be explained without parsing
# git's (localizable) error text. Read once — nothing removes worktrees mid-loop.
worktrees=$(git worktree list --porcelain 2>/dev/null || true)
if [[ -z "$branches" ]]; then
  echo "none"
else
  for b in $branches; do
    state=$(gh pr view "$b" --json state --jq .state 2>/dev/null | tr -d '\r' || echo "NO_PR")
    if [[ "$state" == "MERGED" ]]; then
      if [[ "$b" == "$current" ]]; then
        echo "SKIP    $b — currently checked out; switch to ${default_branch} and re-run"
      # -D because squash/rebase merges leave the branch tip unreachable from main
      elif err=$(git branch -D "$b" 2>&1 >/dev/null); then
        echo "deleted $b (PR merged)"
      else
        wt=$(printf '%s\n' "$worktrees" | awk -v ref="branch refs/heads/$b" '
          /^worktree / { p = substr($0, 10) }
          $0 == ref    { hit = p }
          END          { if (hit != "") print hit }')
        if [[ -n "$wt" ]]; then
          echo "SKIP    $b — checked out in a worktree at ${wt}; remove it and re-run"
        else
          echo "WARN    $b — PR merged but delete failed: ${err}"
        fi
      fi
    else
      echo "kept    $b (PR state: ${state})"
    fi
  done
fi

echo
echo "== pr-open label hygiene =="
prs=""
prs_ok=true
if ! prs="$(gh pr list --state all --limit 200 --json number,state,headRefName,body 2>/dev/null)" \
   || ! printf '%s' "$prs" | jq -e . >/dev/null 2>&1; then
  prs_ok=false
  echo "WARN    could not fetch the PR list (gh pr list failed — rate limit, auth, or network?) — skipping pr-open label hygiene and the follow-ups check below."
fi

issues=""
issues_ok=true
if $prs_ok; then
  if ! issues="$(gh issue list --label pr-open --state open --json number,title,body --limit 100 2>/dev/null)" \
     || ! printf '%s' "$issues" | jq -e . >/dev/null 2>&1; then
    issues_ok=false
    echo "WARN    could not fetch issues labelled pr-open (gh issue list failed — rate limit, auth, or network?) — skipping pr-open label hygiene."
  fi
fi

if $prs_ok && $issues_ok; then
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
          pr_body=$(printf '%s' "$match" | jq -r '.body // ""' | tr -d '\r')
          issue_body=$(printf '%s' "$issue" | jq -r '.body // ""' | tr -d '\r')
          open_siblings=$(printf '%s' "$prs" | jq --arg p "claude/${n}-" \
            '[.[] | select((.headRefName | startswith($p)) and .state == "OPEN")] | length')
          marker='<!-- harness-multi-pr -->'

          # Number-bounded so e.g. "Closes #70" can never satisfy issue #7.
          part_of_pat="(^|[^0-9])part of #${n}([^0-9]|\$)"
          slice_pat="(^|[^a-z])pr[[:space:]]+[0-9]+[[:space:]]+of[[:space:]]+[0-9]+"
          close_pat="(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]*#${n}([^0-9]|\$)"

          keep_reason=""
          if printf '%s\n' "$pr_body" | grep -qiE "$part_of_pat"; then
            keep_reason="the PR body marks it as one of several ('Part of #${n}')"
          elif printf '%s\n' "$pr_body" | grep -qiE "$slice_pat"; then
            keep_reason="the PR body marks it as one of several ('PR k of m')"
          elif ! printf '%s\n' "$pr_body" | grep -qiE "$close_pat"; then
            keep_reason="the PR body has no Closes/Fixes/Resolves #${n} keyword"
          elif [[ "$open_siblings" -gt 0 ]]; then
            keep_reason="another claude/${n}-* PR is still open"
          elif printf '%s\n' "$issue_body" | grep -qF -- "$marker"; then
            keep_reason="the issue carries the harness-multi-pr marker"
          else
            # Only fetched when every cheaper signal above came up empty — the marker may
            # still be sitting in a comment rather than the issue body itself.
            issue_comments=$(gh issue view "$n" --json comments 2>/dev/null | jq -r '.comments[]?.body // empty' || echo "")
            if printf '%s\n' "$issue_comments" | grep -qF -- "$marker"; then
              keep_reason="the issue carries the harness-multi-pr marker"
            fi
          fi

          if [[ -n "$keep_reason" ]]; then
            echo "KEEP  #${n} (${title}): PR #${prnum} merged as part of a multi-PR issue (${keep_reason}); leaving the issue open"
            if $FIX; then
              if [[ "$open_siblings" -eq 0 ]]; then
                gh issue comment "$n" --body "🧹 Harness cleanup: PR #${prnum} for this issue merged, but this looks like one slice of a multi-PR issue (${keep_reason}), so it was left open. \`pr-open\` has been removed so it re-queues for its next slice — if this issue is actually finished, close it by hand." >/dev/null
                gh issue edit "$n" --remove-label pr-open >/dev/null
                echo "        pr-open removed — re-queued for its next slice"
              else
                echo "        pr-open kept — another claude/${n}-* PR is still open"
              fi
            else
              echo "        re-run with --fix to drop pr-open so it re-queues (once no sibling PR is open)"
            fi
          elif $FIX; then
            gh issue comment "$n" --body "🧹 Harness cleanup: PR #${prnum} for this issue links it with a closing keyword, but the issue didn't auto-close (e.g. it merged into a non-default branch). Closing it now." >/dev/null
            gh issue edit "$n" --remove-label pr-open >/dev/null
            gh issue close "$n" >/dev/null
            echo "FIXED #${n} (${title}): PR #${prnum} merged — commented, removed pr-open, closed the issue"
          else
            echo "WARN  #${n} (${title}): PR #${prnum} merged, links this issue with a closing keyword, but the issue is still open — close manually (or re-run with --fix)"
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
fi

echo
echo "== follow-ups from rejected PRs =="
if ! $prs_ok; then
  echo "WARN    skipped (PR list unavailable — see WARN above)"
else
  # Closed-unmerged claude/* PR numbers, derived from the already-fetched $prs — no extra API
  # call for this step alone. MERGED is a distinct jq value from CLOSED, so merged PRs never
  # reach this list.
  closed_prs=$(echo "$prs" | jq -r '.[] | select(.state == "CLOSED" and (.headRefName | startswith("claude/"))) | .number')

  if [[ -z "$closed_prs" ]]; then
    echo "none"
  else
    # Fetch candidate follow-up issues once. Excluding no-plan is what makes --fix idempotent
    # (an already-quarantined follow-up drops out of the query on the next run); excluding
    # pr-open skips a follow-up already in review under its own PR.
    candidates=""
    candidates_ok=true
    if ! candidates="$(gh issue list --search "is:open is:issue -label:no-plan -label:pr-open" --json number,title,body --limit 200 2>/dev/null)" \
       || ! printf '%s' "$candidates" | jq -e . >/dev/null 2>&1; then
      candidates_ok=false
      echo "WARN    could not fetch follow-up candidate issues (gh issue list --search failed — rate limit, auth, or network?) — skipping follow-up quarantine."
    fi
    if $candidates_ok; then
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        marker="<!-- harness-follow-up: PR #${p} -->"
        hits=$(echo "$candidates" | jq -c --arg m "$marker" '.[] | select(.body != null and (.body | contains($m)))')
        [[ -z "$hits" ]] && continue
        while IFS= read -r hit; do
          [[ -n "$hit" ]] || continue
          n=$(echo "$hit" | jq -r .number)
          title=$(echo "$hit" | jq -r .title)
          if $FIX; then
            gh issue comment "$n" --body "🧹 Harness cleanup: this issue was filed automatically as a follow-up from PR #${p}, which was closed without merging, so the work it defers may never have landed. It has been labelled \`no-plan\` so the planner skips it — remove \`no-plan\` to requeue it (and \`no-auto-approve\` when you have confirmed you want it), or just close it." >/dev/null
            gh issue edit "$n" --add-label no-plan >/dev/null
            echo "FIXED #${n} (${title}): follow-up from PR #${p}, closed without merge — commented, labelled no-plan"
          else
            echo "STALE #${n} (${title}): filed as a follow-up from PR #${p}, which was closed without merging — label it no-plan or close it (or re-run with --fix)"
          fi
        done <<EOF
$hits
EOF
      done <<EOF
$closed_prs
EOF
    fi
  fi
fi

echo
echo "Reminder: the verification suite should be re-run on merged ${default_branch} — two green PRs can still compose badly. The implementer/cycle skills do this automatically in pre-flight (baseline refresh) when ${default_branch} has moved past .claude/BASELINE.md."
