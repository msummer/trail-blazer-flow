# Serial merge train (Autonomy mode, or as a full-auto run directs)

This file is the full serial-train procedure for the issue-cycle skill (ADR 0001 decision 7,
folding in #257's update-branch fallback). Eligibility for this mode is decided in `SKILL.md`,
not here — read this file only when step 2 there, or `full-auto.md`, has told you to. Everything this file invokes
stays defined where it already is: step 3's floor, guards (a)–(e), the pre-first-merge recheck,
the status line and ledger column, and the implementer's own step 2. This file only orders them
and adds the update-branch fallback and the post-merge CI watch below. Merge authority stays defined in step 3 alone
(`SKILL.md`'s "Rules"); this file restates no floor command — the floor is the
`merge-floor.sh` run in step 3.

## Scope and activation

Active only when "Autonomy mode" declares `mode: autonomous` **and** step 3's activation (1)
holds (a declared or implied merge-autonomy policy). Activation (2) — that `gh pr merge` actually
runs — is discovered at guard (c), exactly as it is today. So with the `gh pr merge` deny still
in place the train still runs, but the fallback's own eligibility rule (below) allows at most one
update-branch and its CI wait before a merge is confirmed; guard (c)'s denial then makes the rest
of the run merge-halting (the doctor WARNs on this half-activated setup). Never otherwise: outside this mode, steps 2 and 3 run exactly as `SKILL.md` states, one
merge per pass, no update-branch — except that `references/full-auto.md` also runs this
procedure, with the differences it lists (in-scope drain, waves in worktree mode); outside those,
everything here applies as written.

## Stop-check mapping

No new check point is added:
- the pre-implementation check (before step 2) runs first, before the train;
- the pre-merge-pass check runs immediately before the drain;
- each issue's own check is the implementer's own step-2 per-issue stop check
  (`skills/issue-implementer/SKILL.md`'s per-issue check, before each issue in that loop);
- the per-PR check runs as `merge-floor.sh`'s first step in every floor evaluation, including a
  post-update re-evaluation, because that is a new evaluation of the PR;
- the pre-ratchet check is unchanged.

On stop: `SKILL.md`'s "Stop switch" paths apply unchanged. Undispatched train issues are the
`stage-skipped` lines attributed to the stop.

## Phase A — drain

When a "Post-merge CI" section is declared, its Read (see "Post-merge CI watch") runs first.
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
  provenance mismatch, a transient pre-merge read still failing, a base-mismatch escalation, a
  guard (d) `head moved` refusal (not re-evaluated or updated again this pass), or a blocked
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
  fast-forward that did not land, a stop-switch stop, a non-green post-merge CI watch or
  pre-first-merge check result, or a malformed "Post-merge CI" section (see "Post-merge CI
  watch", which also says what stopping means for it). No further issue is dispatched. Then
  continue exactly as `SKILL.md` already does after that event.

## Update-branch fallback (#257)

For a PR whose **only** hold is the up-to-date rail ("behind") — or, for the changelog route below,
that rail plus a textual conflict — eligible only when all of these hold:

- it is a harness PR (`claude/<n>-…` head branch — never Dependabot, never a human's PR);
- in this evaluation `merge-floor.sh` printed `floor=hold` with `fail=behind` as its only `fail=`
  line and `ancestry-rc=1` (a git error such as 128, a failed fetch, and every other failed check
  each print a `fail=` line of their own) — or with exactly two `fail=` lines, that one and
  `fail=merge-state mergeStateStatus is DIRTY`, which only the changelog route handles — and
  step 3's ledger cross-check passes;
- no update was applied to this PR earlier this pass;
- this run has already confirmed a merge (guard (d) `MERGED`), or no update-branch has run yet
  this run — so until a merge proves `gh pr merge` works, at most one update runs;
- the repo's merge method is not rebase;
- no merge-halting event has occurred.

Then:

1. Run `gh pr update-branch <pr>`, one call. Never `--rebase`, never `gh api`, never a local
   merge or push, never a force-push — the one exception is the changelog route below. Not
   retried. A non-zero exit or a denial ⇒ held, quoting its stderr, unless the changelog route
   applies. A conflict names the conflict. A denial also names the grant
   `Bash(gh pr update-branch:*)` in the report, and is never routed around.
2. `gh pr view <pr> --json headRefOid --jq .headRefOid | tr -d '\r'` gives the new head. If it is
   unchanged, the PR stays held.
3. Bounded CI wait: poll `gh pr checks <pr>`. A pending result, or no checks reported yet, is not
   conclusive: `sleep 60` and re-poll, at most 30 times (guard (e)'s non-configurable 30-minute
   ceiling), stopping early on a conclusive result. If `sleep` is denied, re-poll once
   immediately, then hold with "backoff unavailable — grant `Bash(sleep:*)`". Budget spent ⇒
   held, "CI still pending on updated head `<sha>`".
4. Re-evaluate the whole floor for this PR from the top: re-run `merge-floor.sh <pr>` (its stop
   check included) and step 3's judgment checks on the new head. A `fail=behind` again ⇒ held,
   with no second update this pass. Guard (b)'s `--match-head-commit` pin and guard (c)'s
   hand-off then use the `head-oid=` this re-run printed, never the pre-update head and never
   step 2's read.
5. Record "update-branch: `<old head>` → `<new head>`" (or "update-branch (changelog route):
   `<old head>` → `<new head>`") in the PR's cycle-report row, held or merged alike, and in the
   merge's audit evidence when it merges.

### Changelog route (#631)

It runs **instead of step 1** when the floor printed the `fail=merge-state mergeStateStatus is
DIRTY` line next to `fail=behind`, and **after step 1** when `gh pr update-branch` ran and exited non-zero (never after a denial, which
holds the PR as step 1 says).
It is still this PR's one update this pass. It settles one conflict only: the repo's declared
append-only changelog section (`docs/reference/claude-md-contract.md`, item 12).

1. Run `changelog-merge.sh '<base-tip>' '<head-oid>' '<head-branch>'`, the three values pasted
   from that floor run's `base-tip=`, `head-oid=` and `head-branch=` lines, each inside its own
   pair of single quotes. It writes git objects only and moves no ref. Before pasting, check the
   `head-branch=` value: it must be `claude/`, digits, `-`, then only letters, digits, `.`, `_`,
   `/` and `-`. The floor holds any other branch on `fail=branch`, so this never fires on a PR
   that reached this route; if it does anyway, run nothing and hold the PR with "unsafe head
   branch". A branch name is never pasted into a shell line outside single quotes.
2. Only exit 0 with `verdict=updated` as the last line continues. `verdict=absent` holds the PR with
   "conflict; no Append-only changelog declared". Any other result — `verdict=hold` (quote its
   `reason=` line and every `overlap:` line), `verdict=error`, a non-zero exit, a crash — holds the
   PR, quoting stderr when there is any.
3. Push the printed commit with one plain `git push origin '<new-head>:refs/heads/<head-branch>'`,
   `<new-head>` from the script's `new-head=` line (40 or 64 lowercase hex characters, or hold) and
   `<head-branch>` from the floor run (the value step 1 checked), the whole refspec inside one pair
   of single quotes. Never forced, never retried; a non-zero exit or a denial holds the PR.
4. Steps 2–5 above then run as written, with step 2 also requiring the head it reads to equal
   `new-head=`; any other value holds the PR.

Dependabot and human PRs are never updated.

## Post-merge CI watch

Optional, and only for a repo whose `CLAUDE.md` declares a "Post-merge CI" section
(`docs/reference/claude-md-contract.md`, item 13): its PR checks do not run every suite, so a
merge can turn the default branch red where no pull request could show it. No section means no
watch and no pre-first-merge check, silently, and the train runs exactly as written above. The
train never runs on Codex (`SKILL.md`'s Codex paragraph), so neither does this.

- **Read.** Once, at the train's start: after the pre-merge-pass stop check, before Phase A's
  drain. A full-auto run reads it earlier instead (`full-auto.md`'s Scope). A malformed section
  (the item's own rules) is train-stopping, naming the offending line. `wait` is the declared
  minutes (1–60), default 30.
- **Pre-first-merge check.** Once per run, immediately before the run's first merge attempt:
  after the pre-first-merge deploy recheck (if declared) proceeds, before guard (b) for the first
  PR that reaches it. It never runs again, and never runs if no PR reaches guard (b). The commit
  polled is `<tip>`, the `base-tip=` value that PR's most recent `merge-floor.sh` run printed
  (after an update-branch, the re-run's), pasted literally. Poll, Classify and Wait below apply
  with `<tip>` in place of `<oid>`. `green` proceeds to guard (b); anything else is
  train-stopping before any merge.
- **When.** After every merge this run confirms (Phase A or Phase B), once the "One at a time"
  refresh is green, guard (e) has passed and the merge-commit ancestry check has passed. For a
  Phase A merge, read the oid first (`gh pr view <pr> --json mergeCommit --jq .mergeCommit.oid |
  tr -d '\r'`) and run the same `git merge-base --is-ancestor <oid> <default-branch>` check;
  anything but exit 0 is train-stopping, as in Phase B.
- **Poll.** One call per declared workflow:
  `gh run list --workflow "<name>" --commit <oid> --event push --limit 20 --json databaseId,status,conclusion,url --jq '.[] | "\(.databaseId) \(.status) \(if .conclusion == "" then "-" else .conclusion end) \(.url)"'`
  (a run that is not completed prints `-` as its conclusion).
- **Classify** the workflows together, first match wins in this order:
  - `unknown`: a non-zero exit, a denial, a line that does not parse, or a completed run whose
    conclusion is none of `success`, `skipped`, `neutral`, `failure`;
  - `red`: any run `completed failure`;
  - `pending`: some workflow has no line yet, or some run is not `completed`;
  - `green`: every workflow has at least one line, and every line is `completed` with
    `success`, `skipped` or `neutral`.
- **Wait.** On `pending`, `sleep 60` and poll again, at most `wait` polls in all. A spent
  budget is `pending`. If `sleep` is denied, poll once more immediately, then `pending` with
  "backoff unavailable — grant `Bash(sleep:*)`". If `gh run list` is denied, the result is
  `unknown`, naming the grant `Bash(gh run list:*)`.
- **Outcome.** `green`: continue. `red`, `pending` or `unknown`, and a malformed section, are
  train-stopping (Queue policy). The one exception is a `red` after a merge a full-auto run
  confirmed, which `full-auto.md`'s Fix forward attribution decides. On every train-stopping
  result, journal `harness-lock.sh journal <run-id> stage=run outcome=stopped reason=post-merge-ci`;
  quote the last poll's lines and never guess, never run another query in its place. This file
  never fixes forward: that is a full-auto grant's power only.

### What stopping means

- No further floor evaluation, update-branch or merge.
- The PR the pre-first-merge check gated (if any) and every PR Phase A had not yet evaluated are
  recorded `outcome=merge-blocked`, with `post-merge-ci <state> on <first 12 of commit>` as the
  one-line reason.
- No further issue is dispatched; the `stage-skipped` lines for undispatched issues are reported
  as attributed to the watch, not escalated.
- The implementer's step 3 summary still runs once, as Phase B says.
- No ratchet pass runs.
- Step 5 runs in full (status, reconciliation, tracker sync, report, lock release).
- One journal record is written: the `reason=post-merge-ci` call above.
- The run adds no label, posts no issue or PR comment, files no issue, writes no file and never
  sets the stop switch.
- "What waits on the human" names the default branch, the commit, the state, the run URLs and
  the last poll's lines, plus the way out: push a fix or revert so a new default-branch tip's
  push run is green. The next run's pre-first-merge check keeps later runs from merging on top
  of the red tip until then.

### Report and limits

- **Report.** One line per merge: `post-merge-ci: PR #<pr> <first 12 of oid> <state> <run urls>`,
  and one for the pre-first-merge check: `post-merge-ci: base <first 12 of tip> <state> <run urls>`.
- **Limits.** Classification is prompt-enforced. A declared workflow that does not run on every
  push to the default branch (path filters, skip-ci commits) leaves the result `pending` and
  stops the run. A flaky red is not re-run (`gh run rerun` is a write and is not granted).

## Ledger and report

Same rows, stages and vocabulary. Records are per issue, and `reconcile-ledger.sh` keeps the
last record per issue+stage, so the train's interleaving needs no reconciler change. Step 5 is
unchanged. Its "what this cycle did" half additionally names any merge-halting or train-stopping
event, each update-branch pair (a changelog-route pair marked as such) and the watch's
`post-merge-ci:` report lines.
