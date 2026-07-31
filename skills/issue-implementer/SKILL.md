---
name: issue-implementer
description: >
  Implements approved GitHub issues end to end, producing a pull request for each. Use when the
  user asks to "implement the approved issues", "run the implementer", "build the approved
  plans", or similar. Finds issues labelled plan-approved (excluding pr-open / impl-blocked),
  processes them ONE AT A TIME (never in parallel — they share a working tree), and for each:
  branches off the default branch, dispatches a single `implementer` subagent to write and verify
  the code, then commits, pushes, and opens a PR for review. Never merges.
---

# Issue Implementer

This is the **implementation** half of the workflow. Planning (the `issue-planner` skill) has
already produced and the human has approved a plan for each issue you handle here. You (the main
session) are the orchestrator: you delegate code-writing to
the `implementer` subagent (the plugin's `agents/implementer.md`), one dispatch per issue.
After the implementer completes and the mechanical checks pass, a `verifier` subagent
(the plugin's `agents/verifier.md`) adversarially reviews the diff against the plan and acceptance
criteria **before anything is pushed or a PR exists** (the branch may already carry local WIP
checkpoint commits by this point — see "Resilient dispatch") — failures are kicked back to the
implementer (max 2 kickbacks), so the PR the human reviews is already verifier-clean.

This skill is project-agnostic. All project-specific details — conventions, the verification
commands that define "done", how dependencies are installed, schema/migration rules — come from
the repo's **CLAUDE.md**, which the subagent reads at the start of every task. (See the
"CLAUDE.md contract" in the plugin README.)

The end state for each issue is **an open PR awaiting review**. The merge boundary — and where
merge authority lives when it exists at all — is stated once under "Hard rules" below.

## Labels involved

- `plan-approved` — the trigger. Set by the human after reviewing the plan.
- `pr-open` — set by this skill once a PR is open (removes the issue from the queue).
- `impl-blocked` — set by this skill if implementation hits a blocker (removes it from the queue;
  the human removes this label to retry).

## Hard rules

- **Sequential by default.** In the shared working tree, never dispatch more than one
  `implementer` subagent at a time — they would corrupt each other's work. The ONLY exception is
  the worktree-parallel procedure below, and only when every plan in the batch has pairwise
  disjoint "Affected areas".
- **Never merge in this skill** and **never push to the default branch**. One issue →
  one `claude/<n>-<slug>` branch → one PR. Merging happens afterwards and belongs to the
  human — or, where the repo's CLAUDE.md defines a merge autonomy policy and the human has
  lifted the default `gh pr merge` deny, to the `issue-cycle` skill's merge pass, the sole
  place any harness merge authority exists.
- **The subagent writes code; you do every git and `gh` command.**
- **A dirty working tree is only recoverable when it's clearly the harness's own.** If the
  dirty tree is on a `claude/<n>-*` branch, run the crash recovery in step 0. Anywhere else
  (the default branch, any human branch), STOP and tell the user — do not risk clobbering
  uncommitted work. Changes to `.claude/LESSONS.md` alone never count as dirty: that's harness
  bookkeeping, carried into the next harness commit (see step 2e).

## Resilient dispatch

Every subagent dispatch in this skill — and, by citation, in `issue-planner` and `issue-cycle` —
follows this contract. It is defined once, here; other sections cite it by name instead of
restating it.

### Retry ladder

Attempt 1 is the initial dispatch. On a **retryable failure**, back off and retry: 30s → attempt
2; 60s → attempt 3; 120s → attempt 4; 240s → attempt 5. After attempt 5 fails, STOP retrying —
escalate the stage as **failed** into the run report (issue number, stage, attempts used, last
error). Never silently skip the stage, and never advance to the next issue without a recorded row
for it. Use `sleep <seconds>` for the wait. If `sleep` is denied or unavailable, perform at most
ONE immediate retry, then escalate with the reason "backoff unavailable — grant
`Bash(sleep:*)`".

**Retryable:** a tool-level dispatch error; an API 429/500/529; a dispatch that returns nothing
or no parseable report — including a transient subagent death (an infrastructure error with no
usable output): re-dispatch per the ladder, not as a special case; only repeated identical
deaths through attempt 5 become the "failed stage" escalation above (this folds in and replaces
the old standalone "transient subagent deaths" note).
**Not retryable — different paths, not the ladder:** a well-formed report with `status: blocked`
(the existing blocked path, step 2f) or a verifier `fail` verdict (the existing kickback loop,
step 2e, which keeps its own max-2 limit). The ladder never composes with the kickback loop into
more than 3 implementer attempts per verification round, plus the ladder's own retries within
each attempt.

State the attempt number in every dispatch prompt ("Dispatch attempt: `<k>`", starting at 1) so
the subagent's echoed status line carries the right `retries` value (see below).

### Status line

Every `planner`, `implementer`, and `verifier` report ends with one machine-readable line:

`<!-- harness-status: stage=<planner|implementer|verifier|merge> issue=<n> outcome=<slug> retries=<k> -->`

- `stage` — the pipeline stage. `merge` has no agent; the orchestrator emits its line directly
  (see `issue-cycle`'s merge guards).
- `issue` — the GitHub issue number.
- `outcome` — per-stage vocabulary: planner `plan-posted|plan-revised|incomplete|died`;
  implementer `complete|blocked|incomplete|died`; verifier `pass|fail|incomplete|died`; merge
  `merged|merge-blocked|not-eligible|merge-unconfirmed`.
- `retries` — `k-1`, where `k` is the dispatch attempt number stated in the prompt. Agents echo
  it back; default to `0` when the prompt is silent (e.g. an older orchestrator that predates
  this contract).

The orchestrator emits the identical line itself, on the stage's behalf, whenever a stage died
(ladder exhausted, no usable report) or never reported at all, and always for the merge stage.
This is what makes the dispatch ledger and closing reconciliation in `issue-cycle` mechanically
checkable rather than adherence-checkable.

### WIP checkpoint vocabulary

All checkpoints keep the existing `wip:` prefix so branch classification (step 2b) stays a
simple grep:

- `wip: checkpoint <stage> (#<n>)` — a stage-boundary checkpoint (after the implementer returns
  `complete`, after each kickback round, after the CI-fix dispatch).
- `wip: <stage> died (#<n>)` — a hard death: the retry ladder exhausted with no usable report.
- `wip: context exhausted (#<n>)` — a clean early exit (`status: incomplete`).
- `wip: interrupted run (#<n>)` — unchanged: pre-flight crash recovery (step 0). Branches created
  by earlier plugin versions carry this message verbatim.
- `wip: blocked — <short reason> (#<n>)` — unchanged: the blocked path (step 2f).

**Classification rule** (used by step 2b): when every unique commit on a `claude/<n>-*` branch is
a `wip:` commit, look at the newest one. Newest = `wip: blocked — …` → **reset fresh** (existing
behavior: delete and recreate the branch). Newest = anything else (checkpoint, died, context
exhausted, or interrupted run) → **resume**: the branch carries real, preserved partial work and
must be continued, not discarded.

**Invariant this rule depends on:** a branch that step 2f has blocked always ends with a
`wip: blocked — …` commit as its newest commit — never a checkpoint, death, or context-exhausted
commit left over from before the block. Step 2f (below) guarantees this even when the tree was
already fully checkpointed by an earlier stage boundary, by falling back to an empty commit rather
than silently skipping. If this invariant ever broke, a blocked branch would misclassify as
resume and the harness would carry forward exactly the work that got it blocked in the first
place — so any future change to step 2f's commit must preserve it.

### Death / incomplete-exit checkpoint and resume brief

Whenever a dispatch dies with no usable report (ladder exhausted), or returns `status:
incomplete`, the orchestrator WIP-commits the tree **before doing anything else** —
`git add -A && git commit -m "wip: <stage> died (#<n>)"` or
`git add -A && git commit -m "wip: context exhausted (#<n>)"` respectively (skip the commit if
nothing changed) — then builds a **resume brief** and relaunches, bounded by a cap.

A resume brief has exactly five elements: issue number, branch, last WIP commit SHA, what was
completed, and what remains. Two derivations:

- **Clean exit** (`status: incomplete`) — copy the agent's own `## Resume brief` section
  verbatim, plus the WIP SHA the orchestrator just created.
- **Hard death** — reconstruct it: `git diff <default-branch>...<wip-sha> --stat` lists the files
  already touched; walk the approved plan's Implementation steps and Affected areas against that
  list to infer "completed" vs. "remains". Label this reconstruction as best-effort in the
  relaunch prompt so the implementer re-checks rather than trusts it.

**Relaunch instruction** (verbatim, adapted per stage): *"This branch already contains partial
work from a previous attempt at commit `<sha>`. Continue from it — do not revert it, do not redo
completed steps, and do not restart the stage from scratch."*

For the **planner** and **verifier** stages there is no commit to checkpoint: the orchestrator
retains the last completed artifact — the planner's prior `<!-- planner-plan -->` comment, or the
verifier's prior verdict — and relaunches with it as the resume brief, adapting the relaunch
instruction to "this plan/verdict is partial — continue it, do not restart."

**Cap:** at most 2 resume relaunches per issue per run (3 implementer contexts total for the
implementer stage), independent of and not counted against the 2-kickback limit. Exceeding the
cap routes to the existing blocked path (step 2f), which already WIP-commits and labels
`impl-blocked` — the work is preserved either way.

## Procedure

### 0. Pre-flight (once, before any issue)

```bash
gh auth status                 # must be authenticated
git status --porcelain         # see the dirty-tree rules below
git fetch origin
```
Determine the repo's default branch (e.g. via `gh repo view --json defaultBranchRef`); use it
everywhere this doc says "the default branch".

**Dirty tree → crash recovery or stop.** If `git status --porcelain` is non-empty (ignoring
`.claude/LESSONS.md`, which is harness bookkeeping):

- **On a `claude/<n>-*` branch** → a previous run died mid-issue. Recover mechanically:
  `git add -A && git commit -m "wip: interrupted run (#<n>)"`, post a short comment on issue
  `<n>` ("a previous implementation run was interrupted; work preserved on `<branch>`; the
  issue will be re-attempted"), check out the default branch, and continue the run. Do NOT
  label `impl-blocked` — the issue re-enters the queue and step 2b's branch logic resumes or
  resets the wip branch per the classification rule (see "Resilient dispatch"). Note the
  recovery in your summary.
- **Anywhere else** → STOP and tell the user. That's uncommitted human work; it is never yours
  to move.

This pre-flight recovery handles a dirty tree found at **startup** (a crash from a previous run).
A dispatch dying or exhausting context **within** the current run is a different case — see
"Resilient dispatch" for the ladder, checkpoints, and resume brief that cover it.

**Sync & hygiene:** run

```bash
cleanup-after-merge.sh --fix
```

(fast-forwards the default branch when checked out — check it out first if you aren't on it and
the tree is clean; prunes merged `claude/*` branches; repairs stale `pr-open` labels with
audited comments).

**Baseline refresh.** Read `.claude/BASELINE.md` (machine-local; format: a `- commit:` line
with the full SHA of the last known-green default-branch commit, plus per-command results). If
it's missing, warn the user to run the harness-setup skill, and proceed — you still have
CLAUDE.md's verification commands. If the default branch tip now differs from the recorded
commit (merges landed since the last green run), re-establish it **before implementing
anything**: on the clean default branch, run the project's verification commands from
CLAUDE.md.

- **Green** → rewrite `.claude/BASELINE.md` with the new commit SHA, today's date, and each
  command's outcome (e.g. "pytest: 631 passed"). This is also the "two green PRs can still
  compose badly" check, done mechanically.
- **Red** → STOP the whole run and report prominently. The default branch itself is broken;
  implementing on top of it would make every failure unattributable. Fixing main is the
  human's call.

Then install dependencies using the project's setup command from CLAUDE.md (e.g.
`pnpm install`, `npm install`, `bundle install`). If the project has no dependency step, skip
this.

### 1. Find the work

```bash
find-implementation-work.sh   # on PATH via the plugin's bin/
```
Returns JSON `{ ready: [...], counts: {...} }`. **Report the ready issues to the user** (number +
title). If empty, say so and stop.

### 2. For each ready issue, IN SEQUENCE

a. **Fetch the issue and its approved plan:**
```bash
gh issue view <number> --json number,title,body,url,comments
```
Find the latest comment containing the `<!-- planner-plan -->` marker — that is the approved
plan. If there is no such comment, skip the issue and warn (it's labelled approved but has no
plan; the human should check). Also read every comment posted *after* that plan: human comments
there are binding context (late instructions, clarified decisions) — restate them as
`RESOLVED:` decisions in the dispatch below. If one contradicts the approved plan outright,
treat the issue as mislabelled and ask the human instead of dispatching.

b. **Branch off a fresh default branch:**
```bash
git checkout <default-branch>
git pull --ff-only
```
Build a slug from the title (lowercase; non-alphanumerics → hyphens; trim; ~40 chars max), then:
```bash
git checkout -b "claude/<number>-<slug>"
```
**If a `claude/<number>-*` branch already exists**, decide by what's on it
(`git log <default-branch>..<branch> --format=%s`), applying the classification rule from
"Resilient dispatch":
- **Every unique commit is a `wip:` commit, and the newest is `wip: blocked — …`** → leftovers
  of a blocked attempt (the findings live in the issue's comments — carry them into the dispatch
  as context). Delete it (`git branch -D <branch>`) and create the branch fresh. Say so in the
  summary.
- **Every unique commit is a `wip:` commit, and the newest is anything else** (a checkpoint, a
  death, a context-exhausted exit, or an interrupted-run commit) → **resume**: `git checkout
  "claude/<number>-<slug>"` (do NOT delete or recreate it), capture the WIP SHA
  (`git rev-parse HEAD`), build the resume brief per "Resilient dispatch", and dispatch the
  implementer with it. As with the reset case above, check the issue's comments for findings from
  the prior attempt (e.g. a pre-flight interrupted-run comment, or earlier verifier/mechanical-check
  failures noted in the run's history) and carry them into the dispatch as context alongside the
  resume brief — a resumed dispatch must never lose information a previous attempt surfaced. Do
  not rebase or re-cut the branch from the default branch — the pre-flight baseline refresh plus
  the PR's own CI cover any divergence. If the checkout fails because the branch is already
  checked out in another worktree (a swarm run that died before cleanup), sweep that worktree
  first per step a of "Worktree-parallel mode", then retry. Say so in the summary.
- **Any non-wip commit** → real prior work. If an OPEN PR exists for the branch, skip the
  issue and warn (it should be labelled `pr-open`; the label was probably removed by mistake).
  Otherwise stop and warn for that issue — reusing or discarding committed work is the
  human's call.

c. **Dispatch the `implementer` subagent** (Task tool). The dispatch starts from a fresh context
   and sees only what you send, so the prompt must carry **every decision and verified fact** —
   it should never have to exercise design judgment or re-derive codebase facts. Include:
   - the issue number, title, and body;
   - the **full approved plan**, including its "Verified facts" section;
   - **resolved answers to ALL open questions** — the human's answer for each BLOCKING question,
     and each ADVISORY question's accepted default (or the human's override), restated as
     `RESOLVED:` decisions, not questions. Decisions the plan already carries as `RESOLVED
     (orchestrator-proposed):` were accepted when the human approved the plan — pass them
     through as-is;
   - relevant entries from `.claude/LESSONS.md` (if the project has one);
   - the standing caveat *"Line numbers and code excerpts in the plan are from when it was
     written — verify locally; if the code has drifted, trust the live code and note the drift
     in your report."* (Plans are often implemented after other PRs have merged.)
   - the instruction *"Implement this approved plan on the current branch following your process
     and constraints. Return your report."*
   - state the dispatch attempt number ("Dispatch attempt: `<k>`", starting at 1).
   If a BLOCKING question has no answer anywhere in the thread, do NOT dispatch — treat the issue
   as mislabelled (approved without a complete plan) and ask the human. If the dispatch itself
   fails (tool error, API 429/500/529, no parseable report), retry per the "Resilient dispatch"
   ladder rather than treating it as a blocker.

   **Checkpoint on `status: complete`:** before doing anything else, commit the tree —
   `git add -A && git commit -m "wip: checkpoint implementer (#<n>)"` (skip if nothing changed).
   This is what makes the verifier's diff (step 2e) non-empty and correct.

   **On `status: incomplete`:** checkpoint immediately (`git add -A && git commit -m "wip:
   context exhausted (#<n>)"`, skip if nothing changed), build the resume brief from the agent's
   own `## Resume brief` per "Resilient dispatch", and relaunch the implementer with it — bounded
   by the resume cap (2 relaunches per issue per run, 3 implementer contexts total). This is
   distinct from both a kickback and a ladder retry and consumes neither. Exceeding the cap
   routes to the blocked path (step f) — the work is preserved either way. Record the relaunch
   count for the summary table.

   **On a hard death** (the retry ladder exhausted with no usable report): checkpoint (`wip:
   implementer died (#<n>)`), reconstruct the resume brief per "Resilient dispatch", and relaunch
   under the same resume cap. Exceeding the cap routes to the blocked path (step f).

d. **On `status: complete`:** independently re-run the project's verification commands (from
   CLAUDE.md) as the authoritative gate — the subagent may be mistaken. Run the same checks that
   define "done" for this repo. If they fail, treat it as a blocker (step f). Compare the
   results against `.claude/BASELINE.md`: every check green at baseline must still be green,
   and counts should not drop without explanation (fewer tests passing than baseline usually
   means tests were deleted or skipped — investigate before proceeding; a legitimate drop, e.g.
   a planned test removal, must be explained by the plan or the report).

e. **Dispatch the `verifier` subagent** (Task tool, the plugin's `agents/verifier.md`) — the semantic
   gate the mechanical checks can't provide, retried per the "Resilient dispatch" ladder if the
   dispatch itself fails. Its prompt must contain: the issue, the full approved plan (Acceptance
   criteria + Verified facts + `RESOLVED:` decisions included), the implementer's report, the
   dispatch attempt number, the output of `git diff <default-branch>...HEAD --stat` (three-dot —
   diff from the merge base, so drift on the default branch never pollutes it; the implementer's
   checkpoint from step 2c means this is non-empty and correct), and the instruction
   *"Verify this implementation against the plan and acceptance criteria following your process.
   Return your verdict."*
   - **Verdict `pass`:** carry its "Notes for the PR reviewer" into the PR body, proceed to
     commit (next step).
   - **Verdict `fail`:** kick back. Re-dispatch the **implementer** (per the ladder if the
     dispatch itself fails) with: the full approved plan, its own previous report, and the
     verifier's findings verbatim, plus *"Fix ONLY these verification findings. Do not expand
     scope. Return your report."* On its return, checkpoint before anything else: `git add -A &&
     git commit -m "wip: checkpoint kickback (#<n>)"` (skip if nothing changed). Then re-run the
     mechanical checks and re-dispatch the **verifier** (include its prior findings so it
     confirms each is resolved). **Maximum 2 kickbacks** (3 implementer attempts total). Still
     failing after that → blocked path (step f), with the latest findings as the blocker
     explanation. Record the number of verification rounds, and any ladder retries used, for the
     summary table.

   - Once the verifier passes, first **collapse this run's WIP checkpoints** so the PR carries
     one clean commit instead of the checkpoint trail:
```bash
git reset --soft "$(git merge-base <default-branch> HEAD)"
```
     Reset to the **merge base**, not the default branch's current tip — a resumed branch (step
     2b) may be behind the default branch, and resetting to the moved tip would fold a revert of
     other people's commits into this PR. `git reset --soft` only moves HEAD and leaves the index
     and working tree untouched, so the fully-implemented tree survives intact, now fully staged
     against the new (older) HEAD — the existing reconciliation below then works verbatim. If the
     `git reset --soft` / `git merge-base` grants are not available, skip this step: leave the
     WIP commits in place and add the `feat:` commit on top of them (note in the summary that the
     PR carries WIP commits — squash-merging repos are unaffected either way).

     Then stage everything and sanity-check what got staged **before** committing:
```bash
git add -A
git status --porcelain   # review this list
```
     Compare the staged paths against the subagent report's "Files changed" list. Every staged
     path must be accounted for by the report (or be an obvious consequence of it, e.g. a
     lockfile — and `.claude/LESSONS.md` is always legitimate: harness bookkeeping rides along
     with the next commit). If anything unexpected is staged — test artifacts, stray outputs,
     files outside the plan's scope — unstage it (`git restore --staged <path>`) and
     investigate; if it can't be explained, treat the issue as blocked rather than committing
     files the report can't account for. Once the staged set is clean, commit, push, open the
     PR, and label the issue:
```bash
git commit -m "feat: <concise title> (#<number>)"   # use the project's commit convention
git push -u origin "claude/<number>-<slug>"
gh pr create --title "<concise title> (#<number>)" --body-file <tempfile>
gh issue edit <number> --add-label pr-open
```
     The PR body (written to the temp file) must include: a one-paragraph summary; `Closes
     #<number>`; the list of files changed; the verification results; any schema changes that need
     applying; and the reviewer notes from the subagent's report.

     **File the plan's follow-ups.** File each entry that carries the plan template's
     required justification sentence — the one answering "why this can't just be dropped?"
     — with `gh issue create`, quoting that sentence in the new issue body and referencing
     this PR; mention the new issue numbers in the PR body and your summary. An entry with
     no such sentence, or whose sentence names a capability wish rather than a concrete
     trigger or failure mode, is yours to decline — don't file it, and record the decline
     in the PR body (its title plus one line of why) so the judgement is visible to the
     reviewer instead of becoming an issue nobody triages.

     Then **watch CI** so a red run doesn't sit unnoticed:
```bash
gh pr checks "claude/<number>-<slug>" --watch
```
     Record the outcome (pass / fail / no checks configured) for the summary table.

     **Red CI → one bounded fix attempt.** The PR is not merged, so a fix here is exactly as
     safe as the kickback loop. First classify the failure (fetch the failing log, e.g.
     `gh run view <run-id> --log-failed`):
     - **Caused by this PR** (lint/test/build failures traceable to the changed code, incl.
       environment differences like a CI-only strictness flag) → re-dispatch the
       **implementer** (per the "Resilient dispatch" ladder if the dispatch itself fails) on the
       branch with the plan, its report, the failing log excerpt, and *"Fix ONLY this CI failure.
       Do not expand scope. Return your report."* On its return, checkpoint before anything else:
       `git add -A && git commit -m "wip: checkpoint ci-fix (#<n>)"` (skip if nothing changed) —
       this is what makes the re-verification's diff visible, same reason as step 2c/2e. Re-run
       the mechanical checks, re-dispatch the **verifier** (prior context included, scope: the
       fix); once it confirms: **if the ci-fix checkpoint above was created**, it already holds
       exactly the fix's content, so finalize it in place rather than creating an empty commit on
       top: `git commit --amend -m "fix: <what> (CI, #<number>)"`. **If that checkpoint was
       skipped** (the ci-fix implementer changed nothing), commit normally instead of amending —
       `git commit --allow-empty -m "fix: <what> (CI, #<number>)"` — never amend here (amending
       would rewrite the already-pushed `feat:` commit, and the following push would be rejected
       as non-fast-forward since force-push is denied). Then push — CI re-runs on the new
       commit; watch it again. **Maximum ONE CI-fix attempt per issue** (it does not count
       toward the kickback limit). Still red → note the failure in the summary and on the
       issue; the human decides.
     - **Not caused by this PR** (infra flake, unrelated breakage, quota) → don't burn the
       attempt; note it in the summary and on the issue so the human decides.

     **Distill the lesson:** when a failure (CI or your re-verification)
     traces to a project-specific gotcha the subagent couldn't have known, append it to
     `.claude/LESSONS.md` (1–3 lines, dated, written as an instruction) and include it in every
     subsequent dispatch this run. Finally, return to the default branch:
```bash
git checkout <default-branch>
```

f. **On `status: blocked`** (or failed mechanical checks, or a verifier fail that survived 2
   kickbacks): do NOT push or open a PR. Preserve the work for inspection on a local branch,
   flag the issue, and reset the tree. The blocked marker must land as the branch's newest
   commit even when a prior stage boundary (2c's or 2e's checkpoint) already committed
   everything, leaving nothing for `git add -A` to stage — in that case fall back to an empty
   commit rather than skipping, so step 2b's classification rule (see "Resilient dispatch") never
   sees a stale checkpoint as the newest commit and mistakes a blocked branch for one to resume:
```bash
git add -A
if git diff --cached --quiet; then
  git commit --allow-empty -m "wip: blocked — <short reason> (#<number>)"   # tree was already checkpointed — empty commit still marks it blocked
else
  git commit -m "wip: blocked — <short reason> (#<number>)"                # local only, not pushed
fi
gh issue comment <number> --body-file <tempfile>            # blocker explanation (incl. verifier findings, if any)
gh issue edit <number> --add-label impl-blocked
git checkout <default-branch>
```

g. Move to the next issue (back to step 2a).

### 3. Summarise

Report a table: issue number, title, outcome (PR opened → link / blocked → branch name),
verification rounds (1 = clean first pass; 2–3 = kickbacks happened — say what the verifier
caught), retries (ladder retries used per stage, and resume relaunches used out of the cap of 2),
CI status (pass / fixed after 1 attempt / fail / no checks), and any issues skipped and why. This
table is the human-facing form of the dispatch ledger `issue-cycle` maintains across a full pass;
when this skill runs standalone, build it the same way — a stage with no recorded outcome is a
gap to report, never a silent skip. Also note: any crash recovery, wip-branch resume or reset
from pre-flight/step 2b (say which), whether the baseline was refreshed (and its new numbers),
and whether discovery reported `truncated: true` (more approved issues exist than the query
returned — run again after this batch).

## Worktree-parallel mode (optional)

When the batch has 2+ ready issues whose approved plans have **pairwise disjoint "Affected
areas"** (production files AND test files — compare carefully, including shared fixtures like a
test `conftest`), you may implement them in parallel using git worktrees instead of sequentially.
Any overlap, any doubt, or any plan lacking an Affected areas section → sequential.

**Concurrency bound: at most 4 implementer dispatches in flight at once.** Two to four
small/medium disjoint issues is the sweet spot; a fifth eligible issue waits for a free slot
rather than widening the fan-out — beyond 4, queue depth beats fan-out. Only implementer
dispatches fan out. The mechanical checks, the verifier dispatch, the commit/push/PR sequence
and the blocked path all stay **serialized**, one worktree at a time: they share the main
checkout's toolchain (step d) and your own git/`gh` hands.

### Supervisor loop

There is no separate coordinator process — **you are the supervisor**. Keep a **worktree table**
in context for the life of the swarm, one row per issue: issue number, worktree path, branch,
current stage (`implementer` → `checks` → `verifier` → `pr` → `ci` → terminal), dispatch attempt
`k`, kickbacks used (of 2), resume relaunches used (of 2), last WIP SHA, and whether a dispatch
is in flight. Every budget in "Resilient dispatch" is **per issue**: a ladder retry or a resume
relaunch in one worktree never consumes another's.

Work in **rounds, not barriers.** A round is: launch every currently-launchable dispatch as one
batch (never exceeding the concurrency bound in flight), then take the returned reports **one at
a time**, in completion order, carrying that worktree's serial work (step e) through to its PR
or its blocked commit before picking up the next report. Never hold a finished worktree behind
an unfinished one. Whatever the round produces — kickbacks, resume relaunches, ladder retries,
newly freed slots — becomes the next round's batch.

Three rules keep one sick worktree from stalling the swarm:

- **Checkpoint in the worktree before every re-dispatch into it** — ladder retry, resume
  relaunch, or kickback. For a death that is `git -C <worktree> add -A && git -C <worktree>
  commit -m "wip: implementer died (#<n>)"` (skip if nothing changed); otherwise the
  stage-appropriate message from "WIP checkpoint vocabulary". This is the one place the swarm
  does *more* than sequential mode, deliberately: a worktree's dirty tree is invisible to the
  next run's pre-flight (`git status --porcelain` in the main checkout says nothing about it),
  and the supervisor is busy with other worktrees between a death and its retry. The commit is a
  no-op when nothing changed, so the vocabulary and the classification rule are untouched.
- **Backoff waits go last.** Run the ladder's `sleep` for a dead worktree only after every other
  worktree's ready work in that round is drained — a 240s wait must never be why another
  worktree's PR is late.
- **Defer the CI watch.** `gh pr checks --watch` blocks for as long as CI takes; run inline it
  would serialize the whole swarm behind one repo's slowest check. Open the PR, record the watch
  as pending, and drain the pending watches one at a time once no implementer dispatch is in
  flight — each with its single bounded CI-fix attempt exactly per step 2e, re-dispatching the
  implementer into that issue's worktree. A worktree stays alive until its watch is drained.

**Relaunch is always into the same worktree on the same branch.** Never recreate the worktree,
never re-cut the branch, never `git worktree add -b` twice for one issue: after step b the branch
exists and already carries the work, so a resumed dispatch is exactly step 2c's relaunch with
`-C <worktree>` in front of the git commands.

**Every worktree reaches a terminal state before the swarm ends** — PR open with a CI outcome
recorded, `impl-blocked` via step 2f, or a stage escalated as failed after the ladder — and every
one leaves a status line and a ledger record. Exhausting the ladder or the resume cap in one
worktree routes that issue to the blocked path and leaves the rest of the swarm running; it never
ends the swarm. A worktree you launched and never accounted for is exactly the failure this loop
exists to prevent.

**Ledger and status lines are unchanged by the fan-out.** One worktree = one issue = one ledger
row: each dispatch's status line is its record, with the same `stage`/`outcome`/`retries`
vocabulary, and you emit the line yourself for any worktree stage that died with no usable
report. Records land out of issue order as completions interleave — harmless:
`reconcile-ledger.sh` sorts by issue and keeps the last record per issue+stage, so a swarm run
reconciles exactly like a sequential one.

### Swarm procedure

a. **Sweep stale worktrees first** (once, before creating any). A run that died mid-swarm leaves
   worktrees registered, possibly dirty, and holding their branches checked out — and step 0's
   pre-flight inspects only the main checkout, so nothing else catches them:
```bash
git worktree prune                # forget registrations whose directory is gone
git worktree list --porcelain     # what is still attached, and to which branch
```
   For each surviving worktree named `<repo-dirname>-wt-<number>`: if
   `git -C <path> status --porcelain` is non-empty, preserve the work where it stands —
   `git -C <path> add -A && git -C <path> commit -m "wip: interrupted run (#<number>)"` — then
   `git worktree remove <path>`. If removal refuses over leftover untracked/ignored files
   (`node_modules`, a `.venv`), re-run it with `--force`: the tracked work is committed on the
   branch by then, and the branch outlives the worktree. A path that is **not** one of ours is
   never yours to remove — leave it; if it holds a branch this batch needs, skip that issue and
   tell the human. Report every sweep in the summary.

b. **Create one worktree per issue** (siblings of the repo, never nested inside it). The branch
   may already exist — resume-not-restart makes leftover wip branches routine — so classify
   before you create:
```bash
git branch --list "claude/<number>-*"      # this issue's existing branch, if any
```
   - **No such branch** → create branch and worktree together:
```bash
git worktree add "../<repo-dirname>-wt-<number>" -b "claude/<number>-<slug>" <default-branch>
```
   - **A `claude/<number>-*` branch exists** → work with its **actual** name (never a freshly
     built slug — the issue title may have changed since), and decide by what is on it
     (`git log <default-branch>..<branch> --format=%s`) using the classification rule from
     "Resilient dispatch". Same three cases as step 2b, same rules, different plumbing:
     - **every unique commit is a `wip:` commit and the newest is `wip: blocked — …`** → reset
       fresh: `git branch -D <branch>`, then the `-b` form above. Carry the blocked attempt's
       findings from the issue's comments into the dispatch, as in step 2b.
     - **every unique commit is a `wip:` commit and the newest is anything else** → **resume**:
       attach the existing branch — no `-b`, no base argument — so the worktree checks out that
       branch at its own tip:
```bash
git worktree add "../<repo-dirname>-wt-<number>" "<branch>"
```
       Do not reset it onto the default branch: that would discard precisely the partial work the
       resume exists to preserve. Capture the WIP SHA (`git -C <worktree> rev-parse HEAD`), build
       the resume brief per "Resilient dispatch", and carry the issue's prior-attempt comments
       into the dispatch alongside it — same as step 2b.
     - **any non-wip commit** → real prior work: skip that issue and warn (an open PR means the
       `pr-open` label was dropped by mistake; otherwise reusing or discarding committed work is
       the human's call). The rest of the batch proceeds without it.
   - **`git worktree add` refuses because the branch is already checked out in another
     worktree** → step a missed one whose directory still exists. Re-read
     `git worktree list --porcelain`, apply step a's rule to that path, and retry. If it instead
     refuses because the *path* exists but is not registered, stop and tell the human — never
     delete a directory to clear the way (`rm -rf` is deny-listed, and for good reason).

c. **Dispatch the implementers as one batch** (up to the concurrency bound; they run
   concurrently). Each prompt is exactly as in step 2c — including the dispatch attempt number,
   and the resume brief plus verbatim relaunch instruction wherever step b resumed a branch —
   PLUS: *"Work EXCLUSIVELY inside <absolute worktree path>. Every file you read, write, or edit
   and every command you run must use that path — never the main repository checkout."* A
   dispatch that fails is retried per the "Resilient dispatch" ladder, same as step 2c. Include
   the worktree path when stating verification commands. On Windows, write every path you embed
   in a prompt or command with **forward slashes** (`C:/Users/...` or `/c/Users/...`) — commands
   run under Git Bash, where backslash paths get mangled by quoting. Also name the sibling
   issues' affected files as explicitly out of scope ("issues <n>, <m> are being implemented
   concurrently — do NOT touch <their files>") so a subagent that discovers adjacent work doesn't
   drift into a concurrent issue's territory.

d. **Dependency caveat (critical):** ignored files don't exist in a fresh worktree — virtualenvs,
   `node_modules`, `.env`. Tell each subagent how to verify without reinstalling: e.g. for a
   Python project, run the MAIN checkout's venv interpreter against the worktree's tests
   (`cd <worktree>/api && <main-repo>/api/.venv/bin/python -m pytest` — on Windows the venv's
   interpreter is `.venv/Scripts/python.exe`, not `.venv/bin/python`; state the exact path in
   the prompt — the subagent works only inside its worktree and cannot discover the main
   checkout's layout). If a plan touches UI and needs `npm install`/`npm run build` per
   worktree, prefer sequential mode for that issue instead of duplicating installs.

e. **As each implementer completes, run steps 2d–2e for that worktree** (mechanical checks with
   the main venv as above, then the verifier — its prompt must also carry the worktree path),
   one worktree at a time. Everything in the sequential pipeline applies verbatim; what changes
   is only where it runs. **Identical:** the retry ladder and its escalation, the WIP checkpoint
   vocabulary and the classification rule, the resume brief's five elements and its cap of 2, the
   max-2 kickback limit, the status-line grammar, the mechanical checks as the authoritative
   gate, the staged-file reconciliation, and the PR contract. **Worktree-specific:**
   - **every git command takes `-C <worktree>`** — the verifier's diff is `git -C <worktree> diff
     <default-branch>...HEAD --stat` (three-dot, matching sequential mode now that checkpoints
     make it non-empty here too — the old two-dot form is retired so the two modes agree),
     checkpoints are `git -C <worktree> add -A && git -C <worktree> commit -m
     "wip: checkpoint <stage> (#<n>)"`, and the pre-final-commit collapse is `git -C <worktree>
     reset --soft "$(git -C <worktree> merge-base <default-branch> HEAD)"` — the merge base is
     computed per worktree, which is what makes a resumed branch collapse correctly. These forms
     need the `git -C` grants added in v1.8.1 — a permission prompt on any of them means this
     repo's `.claude/settings.json` predates them; finish that issue sequentially instead and
     tell the human to re-copy the `permissions` block from the plugin's
     `templates/repo-settings.json`;
   - **the checkpoint lands in the worktree, not the main checkout**, which stays on the default
     branch, untouched, for the whole swarm;
   - **on a resumed branch there is nothing to create** — step b already attached it, so the
     dispatch continues from the branch tip;
   - **the worktree path travels in every prompt** (the verifier's included) and in every
     verification command you quote.
   Kickbacks re-dispatch the implementer into the same worktree and rejoin the parallel lane,
   counting against the concurrency bound; the checks, the verifier, and your own git/gh work
   stay serialized. Then commit/push/PR, with push as
   `git -C <worktree> push -u origin "claude/<number>-<slug>"`.

f. **Clean up each worktree once its issue is terminal** — its PR is open *and* its deferred CI
   watch (plus any CI-fix attempt) has drained, or it took the blocked path and its `wip:` commit
   exists. Removing it earlier breaks the CI-fix attempt, which re-dispatches into it. The branch
   lives on in the repo:
```bash
git worktree remove "../<repo-dirname>-wt-<number>"
```

g. Everything else is unchanged: same labels, same PR contract, same CI-fix budget, same summary
   table — add a worktree/parallel column so the human knows which mode ran, and note per issue
   whether its branch was created fresh, resumed, or reset, and whether step a swept a stale
   worktree for it.

## Notes

- **After the human merges:** nothing is required — this skill's pre-flight runs
  `cleanup-after-merge.sh --fix` and the baseline refresh, which together cover branch sync,
  branch/label hygiene, and re-verifying merged main. Running `cleanup-after-merge.sh` by hand
  right after a merge is still fine (it's idempotent) if the human wants the tidy-up
  immediately.
- **Stale `pr-open` recovery:** if a PR is closed *without* merging, the issue keeps its
  `pr-open` label and silently never re-enters the queue. The pre-flight's
  `cleanup-after-merge.sh --fix` repairs this automatically (removes the label with an audit
  comment); step 2b then decides what to do with the old branch — wip-only branches are resumed
  or reset per the classification rule in "Resilient dispatch", branches with real commits go to
  the human.
- **Parallelism:** supported via the worktree-parallel mode above and its supervisor loop, gated
  on pairwise-disjoint Affected areas. Sequential remains the default and the fallback whenever
  eligibility is unclear.
- Schema changes: if the subagent created a migration or other schema change, the PR body must say
  so clearly — it has NOT been applied to any database. Applying it is a human step, per the
  project's process in CLAUDE.md.
- Branch protection on the default branch (require a PR) is the real safeguard against accidental
  direct pushes; recommend the user enables it if they haven't.
- Commit messages should follow whatever convention CLAUDE.md specifies (the `feat:` examples
  above assume Conventional Commits; adjust if the project differs).
