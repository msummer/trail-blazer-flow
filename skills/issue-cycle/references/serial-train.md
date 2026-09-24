# Serial merge train (Autonomy mode only)

This file is the full serial-train procedure for the issue-cycle skill (ADR 0001 decision 7,
folding in #257's update-branch fallback). Eligibility for this mode is decided in `SKILL.md`,
not here — read this file only when step 2 there has told you to. Everything this file invokes
stays defined where it already is: step 3's floor, guards (a)–(e), the pre-first-merge recheck,
the status line and ledger column, and the implementer's own step 2. This file only orders them
and adds the update-branch fallback below. Merge authority stays defined in step 3 alone
(`SKILL.md`'s "Rules"); this file restates no floor command — in particular, the
`governance-paths.sh` line stays unique in `SKILL.md` (gate 4.43).

## Scope and activation

Active only when "Autonomy mode" declares `mode: autonomous` **and** step 3's activation (1)
holds (a declared or implied merge-autonomy policy). Activation (2) — that `gh pr merge` actually
runs — is discovered at guard (c), exactly as it is today. So with the `gh pr merge` deny still
in place the train still runs, but the fallback's own eligibility rule (below) allows at most one
update-branch and its CI wait before a merge is confirmed; guard (c)'s denial then makes the rest
of the run merge-halting (the doctor WARNs on this half-activated setup). Never otherwise: outside this mode, steps 2 and 3 run exactly as `SKILL.md` states, one
merge per pass, no update-branch.

## Stop-check mapping

No new check point is added:
- the pre-implementation check (before step 2) runs first, before the train;
- the pre-merge-pass check runs immediately before the drain;
- each issue's own check is the implementer's own step-2 per-issue stop check
  (`skills/issue-implementer/SKILL.md`'s per-issue check, before each issue in that loop);
- the per-PR check runs at the top of every floor evaluation, including a post-update
  re-evaluation, because that is a new evaluation of the PR;
- the pre-ratchet check is unchanged.

On stop: `SKILL.md`'s "Stop switch" paths apply unchanged. Undispatched train issues are the
`stage-skipped` lines attributed to the stop.

## Phase A — drain

Take the open harness PRs that exist at train start (and Dependabot PRs only if a declared
policy covers them). Evaluate them one at a time with step 3's per-PR evaluation, exactly as
written, applying the update-branch fallback below where eligible. Draining first means each
train branch this run cuts is cut from a tip that already contains them.

## Phase B — train

Run the implementer's step 1 once, which gives the ready list in its order. For each ready issue,
in order:

1. Run the implementer's step 2 (a through f, including 2e's CI watch, its one CI-fix attempt,
   and its durable escalations) for this issue alone. Worktree-parallel mode is never entered:
   the train hands the implementer one issue at a time. Its step 2g "move to the next issue" is
   this loop.
2. If a PR was opened, apply the pre-advance check (this issue's `verifier` ledger row has an
   outcome), then step 3's per-PR evaluation for that PR. This includes the pre-first-merge
   recheck if this is the run's first merge attempt, and fills the `merged` column and emits the
   merge status line.
3. After a confirmed merge, run the "One at a time" rule's `cleanup-after-merge.sh --fix` +
   baseline refresh + guard (e) as step 3 already defines. Then confirm the local default branch
   contains the merge: read `gh pr view <pr> --json mergeCommit --jq .mergeCommit.oid | tr -d
   '\r'`, then `git merge-base --is-ancestor <that oid> <default-branch>` must exit 0. Any other
   answer (including a failed fetch that left both local refs on the old tip) is a train-stopping
   event: the post-merge re-verification ran on a stale tip.
4. Before the next issue, every stage this issue reached must have a ledger outcome.

Run the implementer's step 3 summary once, at the end (composed run, no lock release — the
cycle's own lock release, step 0's, still applies once at step 5). With nothing approved, the
train is just its drain.

## Queue policy

Three classes:

- **Per-PR hold** (any floor "not eligible", including red CI after the implementer's fix
  attempt, a governance or `governance-paths.sh` hold, uncovered post-approval comments, a
  provenance mismatch, a transient pre-merge read still failing, a base-mismatch escalation, or a blocked
  issue with no PR): **continue with the next issue.** The held PR stays open with its one-line
  reason; the next pass's drain re-evaluates it.
- **Merge-halting**, for the rest of the run: guard (c) denial; guard (d) `merge attempted,
  unconfirmed`; the pre-first-merge recheck `failed`/`pending`; guard (e) `deploy=failed`. No
  further floor evaluation, update-branch, or merge attempt runs. Remaining issues are still
  implemented, with PRs opened (today's non-train behaviour). Each such PR is recorded
  `outcome=merge-blocked` with the halting event as its reason. Guard (c)'s exact-command
  hand-off covers only the PR guard (c) denied — never a later PR the floor did not evaluate —
  and does not apply after a recheck or deploy failure (as those rules already say). Guard (d)'s
  `merge attempted, unconfirmed` is merge-halting even when a failing read caused it.
- **Train-stopping**: a red baseline after a merge (the existing "One at a time" STOP), a
  fast-forward that did not land, or a stop-switch stop. No further issue is dispatched. Then
  continue exactly as `SKILL.md` already does after that event.

## Update-branch fallback (#257)

For a PR whose **only** hold is the up-to-date rail ("behind"), eligible only when all of these
hold:

- it is a harness PR (`claude/<n>-…` head branch — never Dependabot, never a human's PR);
- in this evaluation every floor check listed before the rail passed (verdict provenance,
  archived verdict, ledger cross-check, plan-binding provenance, CI green) and the *Post-approval
  comments* check passes on the same `find-implementation-work.sh --issue <n>` output;
- the rail's `git merge-base --is-ancestor` answered exit 1 (not a git error such as exit 128,
  and not a fetch failure);
- `mergeStateStatus` is not `DIRTY`/`BLOCKED`;
- no update was applied to this PR earlier this pass;
- this run has already confirmed a merge (guard (d) `MERGED`), or no update-branch has run yet
  this run — so until a merge proves `gh pr merge` works, at most one update runs;
- the repo's merge method is not rebase;
- no merge-halting event has occurred.

Then:

1. Run `gh pr update-branch <pr>`, one call. Never `--rebase`, never `gh api`, never a local
   merge or push, never a force-push. Not retried. A non-zero exit or a denial ⇒ held, quoting
   its stderr. A conflict names the conflict. A denial also names the grant
   `Bash(gh pr update-branch:*)` in the report, and is never routed around.
2. `gh pr view <pr> --json headRefOid --jq .headRefOid | tr -d '\r'` gives the new head. If it is
   unchanged, the PR stays held.
3. Bounded CI wait: poll `gh pr checks <pr>`. A pending result, or no checks reported yet, is not
   conclusive: `sleep 60` and re-poll, at most 30 times (guard (e)'s non-configurable 30-minute
   ceiling), stopping early on a conclusive result. If `sleep` is denied, re-poll once
   immediately, then hold with "backoff unavailable — grant `Bash(sleep:*)`". Budget spent ⇒
   held, "CI still pending on updated head `<sha>`".
4. Re-evaluate the whole floor for this PR from the top: the per-PR stop check, verdict
   provenance onward, the rail and `governance-paths.sh` re-run on the new head. A rail failing
   again ⇒ held, with no second update this pass.
5. Record "update-branch: `<old head>` → `<new head>`" in the PR's cycle-report row, held or
   merged alike, and in the merge's audit evidence when it merges.

Dependabot and human PRs are never updated.

## Ledger and report

Same rows, stages and vocabulary. Records are per issue, and `reconcile-ledger.sh` keeps the
last record per issue+stage, so the train's interleaving needs no reconciler change. Step 5 is
unchanged. Its "what this cycle did" half additionally names any merge-halting or train-stopping
event and each update-branch pair.
