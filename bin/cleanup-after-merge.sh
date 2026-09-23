#!/usr/bin/env bash
#
# cleanup-after-merge.sh [--fix]
# Run after the human merges PR(s) opened by the issue-implementer skill. The planner /
# implementer / cycle skills also run it as part of their pre-flight, so manual runs are
# optional in the steady state.
#
# Every gh/git pre-flight lookup this script makes (the default branch via `gh repo view`, the
# current branch via `git branch --show-current`, the PR list via `gh pr list`, issues labelled
# pr-open via `gh issue list` (open, and, since #370, a second closed-issue query), the multi-PR
# comment-marker lookup via `gh issue view --json comments`, follow-up candidates via `gh issue
# list --search`, and each matched follow-up's own orphan-notice comments lookup via `gh issue
# view --json comments`) is best-effort: a rate
# limit, an auth problem, or a network blip on any one of them is reported (WARN) and only the
# section(s) that depend on it are skipped. With --fix, every mutating write (posting a cleanup
# or orphan-notice comment, closing an issue, adding or removing the pr-open/no-plan labels) is
# best-effort too (#355): a failed write is reported (one WARN line naming the issue and which
# write failed) and counted, and the remaining writes of that same issue's own arm are skipped —
# the loop always continues with the next issue. The script never aborts before printing output,
# and always reaches the "== follow-ups from rejected PRs ==" section and the closing reminder,
# even when one or more writes failed; a run with at least one failed write prints one extra
# summary WARN line just before the reminder. Exit status stays 0 regardless.
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
#          keyword, a "Part of #n" / "PR k of m" marker, an OPEN sibling PR, the multi-pr
#          label, or a maintainer (OWNER/MEMBER/COLLABORATOR) comment carrying
#          <!-- harness-multi-pr -->) -> KEEP, leave the issue open. The issue-body marker is
#          no longer honoured; an untrusted comment's marker is ignored and WARNed instead.
#        - PR merged, every cheaper KEEP signal absent, but the multi-PR comment-marker lookup
#          itself failed or returned a malformed document -> WARN once (naming the failure
#          route) and leave the issue exactly as found (pr-open still attached, not closed,
#          not commented, not relabelled), so the next run re-examines it
#        - PR closed WITHOUT merging       -> stale pr-open; the issue should requeue
#        - PR still open                   -> fine, awaiting review
#   4. Closed-issue pr-open sweep (#370; skipped, with a WARN, if the PR list or this
#      closed-issue query itself could not be fetched — independent of whether the open-issue
#      query above succeeded): every CLOSED issue still labelled pr-open is swept, up to 100 per
#      run, converging across runs — not just #355's own residue, but the whole historical
#      backlog, since nothing else in the harness ever removes pr-open from an issue GitHub
#      auto-closed when its PR merged. An issue is kept (label left in place, no write) while any
#      claude/<n>-* PR for it is still OPEN; otherwise the label is removed. Label-only: no
#      comment is posted, so a reopened issue re-entering the ready set keeps whatever
#      plan-approved state it already had.
#   5. Follow-ups filed from a claude/* PR that was closed WITHOUT merging (skipped, with a
#      WARN, if the PR list or the follow-up candidate search could not be fetched): reported;
#      with --fix, labelled no-plan (when not already present) and then commented, so the
#      planner skips the orphaned work. Since #334, idempotence no longer comes from the -label:no-plan
#      exclusion a follow-up is born under (#308) — the candidate query below covers every open,
#      non-pr-open issue naming a closed-unmerged claude/* PR — but from a per-candidate comments
#      lookup: a trusted (OWNER/MEMBER/COLLABORATOR) comment already carrying that PR's own
#      <!-- harness-orphan-notice: PR #<p> --> marker means the notice was already posted, so
#      nothing is posted again. That lookup's own failure or a response that is not valid JSON is
#      WARNed once (naming the failure route) and leaves the issue exactly as found. Honest limit:
#      a valid-JSON comments document of an unexpected shape is read as "not yet noticed", so the
#      worst case is a duplicate notice, never a lost one.
#
# Without --fix: read-mostly and conservative — never switches branches, never
# force-deletes work that isn't merged, never edits labels (it only reports).
#
# With --fix, it additionally repairs the label-hygiene cases — every COMMENT posted below opens
# with the "<!-- harness-audit -->" marker, so it's excluded from both discovery scripts' binding
# comment sets (a harness-authored audit/hygiene record is never fed back to the planner or
# implementer as human decision text); the closed-issue sweep further down (#370) is label-only —
# it posts no comment at all, so the label-removal event itself is the audit trail. Each arm's
# writes run in the order listed and stop at the first failure (#355), so every partial state
# below either leaves the issue re-examinable by the next --fix run, or is the one bounded
# residue named on the close arm:
#   - PR merged, issue still open, closing keyword present, no multi-PR signal -> comment,
#     close the issue, remove pr-open (audited with a marked issue comment). If the comment
#     fails, nothing else in this arm runs and the issue is left untouched; if closing fails
#     after a successful comment, pr-open stays attached and the next run posts another audit
#     comment before retrying; if only the final remove-label fails, the issue ends up CLOSED but
#     still carrying pr-open — the closed-issue sweep further down (#370) picks it up on the next
#     --fix run and removes the label then, with no further comment posted.
#   - PR merged but a multi-PR signal is present (KEEP: the multi-pr label, or a maintainer
#     comment carrying <!-- harness-multi-pr -->) -> issue stays open; when no other
#     claude/<n>-* PR is still open, the issue is commented (with the same marker) and pr-open is
#     removed so it re-queues for its next slice — a human closes it by hand if the work is
#     actually finished. If the comment fails, nothing else in this arm runs and pr-open is left
#     in place; if only the remove-label fails after a successful comment, pr-open stays attached
#     and the next run posts another audit comment before retrying the label removal (this
#     comment is best-effort like every other write here, not deduplicated by a marker check the
#     way the follow-up notice below is). A harness-multi-pr marker from an untrusted comment
#     author is ignored (never a KEEP signal) and WARNed, in both --fix and report-only modes,
#     naming the comment's url and association.
#   - PR closed without merging    -> comment, remove pr-open (requeues the issue; the
#     old claude/* branch is left alone — the implementer's branch-exists logic decides
#     whether it can be reset or needs a human). Same partial-failure shape as the KEEP arm
#     above: a failed comment leaves the issue untouched, a failed remove-label after a
#     successful comment leaves pr-open attached and duplicates the audit comment on the next run.
# ...and quarantines orphaned plan follow-ups (also audited with a marked issue comment), keyed
# on a trusted, PR-keyed <!-- harness-orphan-notice: PR #<p> --> marker rather than the no-plan
# label (#334) — so a follow-up born no-plan (#308) is reached too:
#   - follow-up filed from a claude/* PR closed without merging, not yet noticed -> add no-plan
#     when it isn't already present, then comment (carrying that marker) (never closes the
#     issue; a human removes no-plan to requeue it). If the label edit fails, nothing is
#     commented and the next run retries both; if only the comment fails after a successful
#     label edit, the issue is held with no-plan but carries no notice yet, and the next run
#     retries just the comment (the label edit is skipped a second time, since the label is
#     already present).
#   - already noticed (a trusted comment already carries this PR's own marker) -> nothing
#     posted, no label edit — the idempotence guarantee. Honest limit: this holds only when the
#     account running --fix is itself OWNER/MEMBER/COLLABORATOR on the repo, since a marker
#     counts as "already noticed" only from a trusted comment; if it isn't, its own notice
#     comment never satisfies that gate, and --fix posts another notice (plus the untrusted-
#     marker WARN naming its own comment) on every run.
#
# Requires: gh (authenticated), jq, git. Run from anywhere inside the repo.
set -euo pipefail

FIX=false
[[ "${1:-}" == "--fix" ]] && FIX=true

AUDIT_MARKER='<!-- harness-audit -->'

# GitHub's authorAssociation enum: OWNER, MEMBER, COLLABORATOR, CONTRIBUTOR,
# FIRST_TIME_CONTRIBUTOR, FIRST_TIMER, NONE. Only the first three carry repo authority, so only
# a comment from one of them can make the <!-- harness-multi-pr --> marker below a KEEP signal;
# everything else (including a comment with no authorAssociation at all) is untrusted and WARNed
# instead. Must stay identical to bin/find-planning-work.sh's and bin/find-implementation-work.sh's
# TRUSTED_ASSOCIATIONS (gate assertion 4.26, extended to all three scripts).
TRUSTED_ASSOCIATIONS="OWNER MEMBER COLLABORATOR"

# The primary multi-PR signal: a label on the issue itself (permission-controlled, visible),
# created by bin/setup-labels.sh (gate assertion 4.35 pins that this value is one of the labels
# that script creates).
MULTI_PR_LABEL="multi-pr"

# The per-PR idempotence key for the follow-up orphan notice below (#334): a trusted comment on
# the follow-up issue carrying this PR-keyed marker means the notice was already posted, so
# nothing is posted again. Deliberately neither a substring of, nor a superstring containing, the
# <!-- harness-follow-up: PR #<p> --> marker a follow-up is filed with (gate assertion 4.16), so
# neither marker can satisfy a `contains` test meant for the other. Must stay spelled identically
# in README.md (gate assertion 4.47 pins the prefix; the PR number varies per issue).
ORPHAN_NOTICE_MARKER_PREFIX='<!-- harness-orphan-notice: PR #'

# Count of failed writes this run, for the one summary WARN line before the closing Reminder.
# Deliberately `x=$((x + 1))`, never `((x++))`: the latter returns non-zero when the pre-increment
# value is 0, which would trip `set -e` at whichever call site isn't already inside an
# if/&&/condition.
write_failures=0

# try_write N TITLE DESC CMD… : runs CMD (stdout discarded, stderr deliberately NOT redirected,
# so gh's own diagnostic still reaches the transcript); on failure WARNs once, counts it, and
# returns 1 so an && chain skips the rest of this issue's arm. `set -e` is suppressed inside a
# function invoked from an if/&& condition, so every step here is tested explicitly — nothing in
# this helper relies on `set -e` to abort.
try_write() {
  local n="$1" title="$2" desc="$3"
  shift 3
  if "$@" >/dev/null; then
    return 0
  fi
  echo "WARN  #${n} (${title}): ${desc} failed (gh exited non-zero — rate limit, auth, or network?) — no further repair attempted on this issue; re-run cleanup-after-merge.sh --fix once the cause clears"
  write_failures=$((write_failures + 1))
  return 1
}

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
  if ! issues="$(gh issue list --label pr-open --state open --json number,title,labels --limit 100 2>/dev/null)" \
     || ! printf '%s' "$issues" | jq -e . >/dev/null 2>&1; then
    issues_ok=false
    echo "WARN    could not fetch issues labelled pr-open (gh issue list failed — rate limit, auth, or network?) — skipping pr-open label hygiene."
  fi
fi

if $prs_ok && $issues_ok; then
  if [[ $(echo "$issues" | jq 'length') -eq 0 ]]; then
    echo "no open issues labelled pr-open"
  else
    issue_lines="$(echo "$issues" | jq -c '.[]')"
    while IFS= read -r issue; do
      [[ -n "$issue" ]] || continue
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
          open_siblings=$(printf '%s' "$prs" | jq --arg p "claude/${n}-" \
            '[.[] | select((.headRefName | startswith($p)) and .state == "OPEN")] | length')
          marker='<!-- harness-multi-pr -->'
          # Tolerant of gh's real {"name": "..."} label-element shape and a bare-string element,
          # and of a missing labels key entirely (same idiom as
          # bin/find-implementation-work.sh:273-275's plan-approved-label check).
          has_multi_pr_label=$(printf '%s' "$issue" | jq -r --arg l "$MULTI_PR_LABEL" '
            [ (.labels // [])[] | if type == "object" then (.name // "") else tostring end ]
            | index($l) != null')

          # Number-bounded so e.g. "Closes #70" can never satisfy issue #7.
          part_of_pat="(^|[^0-9])part of #${n}([^0-9]|\$)"
          slice_pat="(^|[^a-z])pr[[:space:]]+[0-9]+[[:space:]]+of[[:space:]]+[0-9]+"
          close_pat="(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]*#${n}([^0-9]|\$)"

          keep_reason=""
          # #249 — reset per issue (this branch runs once per `while read -r issue` iteration):
          # comments_ok tracks whether the multi-PR comment-marker lookup below produced a
          # readable document at all; lookup_failure names the failure route when it didn't. Both
          # are read only by the decision chain further down, never left stale across issues.
          comments_ok=true
          lookup_failure=""
          # Here-strings, not a `printf` writer piped into `grep`'s quiet mode (#255): that
          # early-exit reader exits on its first match, which can send the printf writer SIGPIPE
          # and, under this script's `set -euo pipefail`, turn a genuine match into a reported
          # pipeline failure — a here-string has no writer process, so no SIGPIPE is possible, and
          # it appends exactly one trailing newline, the same as the piped printf did, so grep's
          # regex semantics are unchanged.
          if grep -qiE "$part_of_pat" <<<"$pr_body"; then
            keep_reason="the PR body marks it as one of several ('Part of #${n}')"
          elif grep -qiE "$slice_pat" <<<"$pr_body"; then
            keep_reason="the PR body marks it as one of several ('PR k of m')"
          elif ! grep -qiE "$close_pat" <<<"$pr_body"; then
            keep_reason="the PR body has no Closes/Fixes/Resolves #${n} keyword"
          elif [[ "$open_siblings" -gt 0 ]]; then
            keep_reason="another claude/${n}-* PR is still open"
          elif [[ "$has_multi_pr_label" == "true" ]]; then
            keep_reason="the issue carries the multi-pr label"
          else
            # Only fetched when every cheaper signal above came up empty — the marker may
            # still be sitting in a maintainer comment. Fetched once. Since #249, a failed or
            # malformed fetch no longer falls back to the empty document (which used to read as
            # "no marker found" and send the issue down the close path) — it sets
            # comments_ok=false and a lookup_failure route phrase instead, and the extraction
            # below (and the untrusted-marker WARN it can produce) is skipped entirely: an
            # unreadable comment set is UNKNOWN, never "no marker present", so a rate limit or a
            # malformed response can no longer manufacture a false close. The third arm of the
            # decision chain below reads $comments_ok/$lookup_failure and WARNs once instead.
            # Trust-gated: only an OWNER/MEMBER/COLLABORATOR comment's marker counts as KEEP
            # (TRUSTED_ASSOCIATIONS, matching both discovery scripts); an untrusted marker
            # (including one with no authorAssociation at all — fail-closed) is ignored here but
            # WARNed below so the maintainer sees the attempt.
            if ! issue_comments_doc="$(gh issue view "$n" --json comments 2>/dev/null)"; then
              comments_ok=false
              lookup_failure="gh issue view failed - rate limit, auth, or network?"
            elif ! printf '%s' "$issue_comments_doc" | jq -e . >/dev/null 2>&1; then
              comments_ok=false
              lookup_failure="the comments response was not valid JSON"
            fi

            if $comments_ok; then
              trusted_hits=$(printf '%s' "$issue_comments_doc" | jq -r --arg m "$marker" --arg trusted "$TRUSTED_ASSOCIATIONS" '
                ($trusted | split(" ")) as $ok
                | [ (.comments // [])[]
                    | select((.body // "") | contains($m))
                    | select(((.authorAssociation // "") | ascii_upcase) as $a | ($ok | index($a)) != null) ]
                | length' || true)
              untrusted_marker_lines=$(printf '%s' "$issue_comments_doc" | jq -r --arg m "$marker" --arg trusted "$TRUSTED_ASSOCIATIONS" '
                ($trusted | split(" ")) as $ok
                | (.comments // [])[]
                | select((.body // "") | contains($m))
                | select(((.authorAssociation // "") | ascii_upcase) as $a | ($ok | index($a)) == null)
                | (.authorAssociation // "MISSING") + " " + (.url // "(no url)")' || true)

              if [[ "${trusted_hits:-0}" -gt 0 ]]; then
                keep_reason="a maintainer comment carries the harness-multi-pr marker"
              fi
              if [[ -n "$untrusted_marker_lines" ]]; then
                while IFS= read -r hitline; do
                  [[ -n "$hitline" ]] || continue
                  assoc="${hitline%% *}"
                  hit_url="${hitline#* }"
                  echo "WARN  #${n} (${title}): ignoring a harness-multi-pr marker from an untrusted comment author (${assoc}) at ${hit_url} — apply the multi-pr label instead if this really is a multi-PR split"
                done <<EOF
$untrusted_marker_lines
EOF
              fi
            fi
          fi

          if [[ -n "$keep_reason" ]]; then
            echo "KEEP  #${n} (${title}): PR #${prnum} merged as part of a multi-PR issue (${keep_reason}); leaving the issue open"
            if $FIX; then
              if [[ "$open_siblings" -eq 0 ]]; then
                if try_write "$n" "$title" "posting the cleanup comment" gh issue comment "$n" --body "${AUDIT_MARKER}
🧹 Harness cleanup: PR #${prnum} for this issue merged, but this looks like one slice of a multi-PR issue (${keep_reason}), so it was left open. \`pr-open\` has been removed so it re-queues for its next slice — if this issue is actually finished, close it by hand." \
                   && try_write "$n" "$title" "removing the pr-open label" gh issue edit "$n" --remove-label pr-open; then
                  echo "        pr-open removed — re-queued for its next slice"
                fi
              else
                echo "        pr-open kept — another claude/${n}-* PR is still open"
              fi
            else
              echo "        re-run with --fix to drop pr-open so it re-queues (once no sibling PR is open)"
            fi
          elif ! $comments_ok; then
            # #249 — fail closed on the KEEP side: an unreadable comment-marker lookup is
            # UNKNOWN, not "no marker found", so neither the close path nor the KEEP relabel
            # runs for this issue in EITHER mode (not gated behind $FIX) — pr-open stays exactly
            # as found and the next run re-examines it. Deliberately a sibling of the $FIX branch
            # below, not nested inside it.
            echo "WARN  #${n} (${title}): PR #${prnum} merged, but the multi-PR comment-marker lookup failed (${lookup_failure}) — leaving the issue open with pr-open in place for the next run to re-examine"
          elif $FIX; then
            if try_write "$n" "$title" "posting the cleanup comment" gh issue comment "$n" --body "${AUDIT_MARKER}
🧹 Harness cleanup: PR #${prnum} for this issue links it with a closing keyword, but the issue didn't auto-close (e.g. it merged into a non-default branch). Closing it now." \
               && try_write "$n" "$title" "closing the issue" gh issue close "$n" \
               && try_write "$n" "$title" "removing the pr-open label" gh issue edit "$n" --remove-label pr-open; then
              echo "FIXED #${n} (${title}): PR #${prnum} merged — commented, closed the issue, removed pr-open"
            fi
          else
            echo "WARN  #${n} (${title}): PR #${prnum} merged, links this issue with a closing keyword, but the issue is still open — close manually (or re-run with --fix)"
          fi
          ;;
        CLOSED)
          if $FIX; then
            if try_write "$n" "$title" "posting the cleanup comment" gh issue comment "$n" --body "${AUDIT_MARKER}
🧹 Harness cleanup: PR #${prnum} was closed without merging, so this issue has been requeued for implementation (\`pr-open\` removed). The old \`claude/${n}-*\` branch was left in place — the next implementer run resets it if it only contains wip commits, and asks a human otherwise." \
               && try_write "$n" "$title" "removing the pr-open label" gh issue edit "$n" --remove-label pr-open; then
              echo "FIXED #${n} (${title}): PR #${prnum} closed without merge — commented, removed pr-open (issue requeued)"
            fi
          else
            echo "STALE #${n} (${title}): PR #${prnum} closed WITHOUT merge — remove pr-open to requeue (or re-run with --fix)"
          fi
          ;;
        OPEN)   echo "ok    #${n} (${title}): PR #${prnum} open, awaiting review" ;;
      esac
    done <<EOF
$issue_lines
EOF
  fi
fi

echo
echo "== closed issues still labelled pr-open =="
if ! $prs_ok; then
  echo "WARN    closed-issue pr-open sweep skipped (PR list unavailable — see WARN above)"
else
  closed_issues=""
  closed_issues_ok=true
  if ! closed_issues="$(gh issue list --label pr-open --state closed --json number,title --limit 100 2>/dev/null)" \
     || ! printf '%s' "$closed_issues" | jq -e . >/dev/null 2>&1; then
    closed_issues_ok=false
    echo "WARN    could not fetch closed issues labelled pr-open (gh issue list failed — rate limit, auth, or network?) — skipping the closed-issue pr-open sweep."
  fi

  if $closed_issues_ok; then
    if [[ $(echo "$closed_issues" | jq 'length') -eq 0 ]]; then
      echo "no closed issues labelled pr-open"
    else
      closed_issue_lines="$(echo "$closed_issues" | jq -c '.[]')"
      while IFS= read -r ci; do
        [[ -n "$ci" ]] || continue
        n=$(echo "$ci" | jq -r .number)
        title=$(echo "$ci" | jq -r .title)
        open_pr=$(printf '%s' "$prs" | jq -r --arg p "claude/${n}-" \
          '[.[] | select((.headRefName | startswith($p)) and .state == "OPEN") | .number] | first // empty')
        if [[ -n "$open_pr" ]]; then
          echo "ok    #${n} (${title}): closed, but PR #${open_pr} (claude/${n}-*) is still open — pr-open kept"
        elif $FIX; then
          if try_write "$n" "$title" "removing the pr-open label" gh issue edit "$n" --remove-label pr-open; then
            echo "FIXED #${n} (${title}): closed issue — removed stale pr-open"
          fi
        else
          echo "STALE #${n} (${title}): closed but still labelled pr-open — re-run with --fix to remove it (a reopened issue would otherwise stay out of the implementer's queue)"
        fi
      done <<EOF
$closed_issue_lines
EOF
    fi
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
    # Fetch candidate follow-up issues once. Idempotence no longer comes from excluding no-plan
    # (#334; a follow-up born no-plan (#308) needs the orphan notice too) — it comes from the
    # per-candidate orphan-notice-marker check below. Excluding pr-open here still skips a
    # follow-up already in review under its own PR.
    candidates=""
    candidates_ok=true
    if ! candidates="$(gh issue list --search "is:open is:issue -label:pr-open" --json number,title,body,labels --limit 200 2>/dev/null)" \
       || ! printf '%s' "$candidates" | jq -e . >/dev/null 2>&1; then
      candidates_ok=false
      echo "WARN    could not fetch follow-up candidate issues (gh issue list --search failed — rate limit, auth, or network?) — skipping follow-up quarantine."
    fi
    if $candidates_ok; then
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        marker="<!-- harness-follow-up: PR #${p} -->"
        orphan_marker="${ORPHAN_NOTICE_MARKER_PREFIX}${p} -->"
        hits=$(echo "$candidates" | jq -c --arg m "$marker" '.[] | select(.body != null and (.body | contains($m)))')
        [[ -z "$hits" ]] && continue
        while IFS= read -r hit; do
          [[ -n "$hit" ]] || continue
          n=$(echo "$hit" | jq -r .number)
          title=$(echo "$hit" | jq -r .title)
          # Tolerant of gh's real {"name": "..."} label-element shape, a bare-string element, and
          # a missing labels key entirely (the same idiom as the pr-open section's
          # has_multi_pr_label above).
          has_no_plan_label=$(printf '%s' "$hit" | jq -r --arg l "no-plan" '
            [ (.labels // [])[] | if type == "object" then (.name // "") else tostring end ]
            | index($l) != null')

          # #249 — reset per iteration (this branch runs once per inner `while read -r hit`
          # iteration, itself nested inside the outer `while read -r p` loop — both fed by
          # heredocs, so `set -e` applies and neither variable leaks stale state across a
          # follow-up or a source PR): notice_ok tracks whether the per-follow-up orphan-notice
          # comments lookup produced a readable document at all; notice_failure names the failure
          # route when it didn't.
          notice_ok=true
          notice_failure=""
          if ! followup_comments_doc="$(gh issue view "$n" --json comments 2>/dev/null)"; then
            notice_ok=false
            notice_failure="gh issue view failed - rate limit, auth, or network?"
          elif ! printf '%s' "$followup_comments_doc" | jq -e . >/dev/null 2>&1; then
            notice_ok=false
            notice_failure="the comments response was not valid JSON"
          fi

          if ! $notice_ok; then
            # Sibling of the $FIX branch below, deliberately not nested inside it (the #249
            # idiom the multi-PR comment-marker lookup already uses above): an unreadable
            # orphan-notice lookup is UNKNOWN, never "not yet noticed", so the issue is left
            # exactly as found in both modes for the next run to re-examine.
            echo "WARN  #${n} (${title}): follow-up from PR #${p}, but the orphan-notice lookup failed (${notice_failure}) — leaving it as found for the next run to re-examine"
            continue
          fi

          # Trust-gated exactly like the multi-PR marker above: only an OWNER/MEMBER/COLLABORATOR
          # comment's marker counts as "already noticed" (TRUSTED_ASSOCIATIONS); a comment with no
          # authorAssociation at all is fail-closed untrusted. An untrusted marker is ignored here
          # but WARNed below so the maintainer sees the attempt — the notice is still posted.
          trusted_notice_hits=$(printf '%s' "$followup_comments_doc" | jq -r --arg m "$orphan_marker" --arg trusted "$TRUSTED_ASSOCIATIONS" '
            ($trusted | split(" ")) as $ok
            | [ (.comments // [])[]
                | select((.body // "") | contains($m))
                | select(((.authorAssociation // "") | ascii_upcase) as $a | ($ok | index($a)) != null) ]
            | length' || true)
          untrusted_notice_lines=$(printf '%s' "$followup_comments_doc" | jq -r --arg m "$orphan_marker" --arg trusted "$TRUSTED_ASSOCIATIONS" '
            ($trusted | split(" ")) as $ok
            | (.comments // [])[]
            | select((.body // "") | contains($m))
            | select(((.authorAssociation // "") | ascii_upcase) as $a | ($ok | index($a)) == null)
            | (.authorAssociation // "MISSING") + " " + (.url // "(no url)")' || true)

          if [[ "${trusted_notice_hits:-0}" -gt 0 ]]; then
            # Already noticed — the idempotence guarantee: print nothing, write nothing.
            continue
          fi
          if [[ -n "$untrusted_notice_lines" ]]; then
            while IFS= read -r hitline; do
              [[ -n "$hitline" ]] || continue
              assoc="${hitline%% *}"
              hit_url="${hitline#* }"
              echo "WARN  #${n} (${title}): ignoring an orphan-notice marker from an untrusted comment author (${assoc}) at ${hit_url} — it does not suppress the follow-up notice below"
            done <<EOF
$untrusted_notice_lines
EOF
          fi

          if $FIX; then
            if [[ "$has_no_plan_label" != "true" ]]; then
              if try_write "$n" "$title" "adding the no-plan label" gh issue edit "$n" --add-label no-plan \
                 && try_write "$n" "$title" "posting the orphan notice" gh issue comment "$n" --body "${AUDIT_MARKER}
${orphan_marker}
🧹 Harness cleanup: this issue was filed automatically as a follow-up from PR #${p}, which was closed without merging, so the work it defers may never have landed. It is held with \`no-plan\` so the planner skips it — remove \`no-plan\` to requeue it, or just close it."; then
                echo "FIXED #${n} (${title}): follow-up from PR #${p}, closed without merge — commented, labelled no-plan"
              fi
            else
              if try_write "$n" "$title" "posting the orphan notice" gh issue comment "$n" --body "${AUDIT_MARKER}
${orphan_marker}
🧹 Harness cleanup: this issue was filed automatically as a follow-up from PR #${p}, which was closed without merging, so the work it defers may never have landed. It is held with \`no-plan\` so the planner skips it — remove \`no-plan\` to requeue it, or just close it."; then
                echo "FIXED #${n} (${title}): follow-up from PR #${p}, closed without merge — commented (no-plan already present)"
              fi
            fi
          else
            echo "STALE #${n} (${title}): filed as a follow-up from PR #${p}, which was closed without merging — re-run with --fix to post the orphan notice (and add no-plan if it is missing), or close it"
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

if [[ "$write_failures" -gt 0 ]]; then
  echo "WARN    ${write_failures} repair write(s) failed this run (see the WARN lines above) — re-run cleanup-after-merge.sh --fix once the cause clears."
fi

echo
echo "Reminder: the verification suite should be re-run on merged ${default_branch} — two green PRs can still compose badly. The implementer/cycle skills do this automatically in pre-flight (baseline refresh) when ${default_branch} has moved past .claude/BASELINE.md."
