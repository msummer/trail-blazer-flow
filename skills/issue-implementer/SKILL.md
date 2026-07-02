---
name: issue-implementer
description: >
  Implements approved GitHub issues end to end, producing a pull request for each. Use when the
  user asks to "implement the approved issues", "run the implementer", "build the approved
  plans", or similar. Finds issues labelled plan-approved (excluding pr-open / impl-blocked),
  processes them ONE AT A TIME (never in parallel — they share a working tree), and for each:
  branches off the default branch, dispatches a single `implementer` subagent to write and verify
  the code, then commits, pushes, and opens a PR for human review. Never merges.
---

# Issue Implementer

This is the **implementation** half of the workflow. Planning (the `issue-planner` skill) has
already produced and the human has approved a plan for each issue you handle here. You (the main
session) are the orchestrator: you do all git and GitHub work, and you delegate code-writing to
the read/write `implementer` subagent (the plugin's `agents/implementer.md`), one dispatch per issue.
After the implementer completes and the mechanical checks pass, a read-only `verifier` subagent
(the plugin's `agents/verifier.md`) adversarially reviews the diff against the plan and acceptance
criteria **before anything is committed** — failures are kicked back to the implementer (max 2
kickbacks), so the PR the human reviews is already verifier-clean.

This skill is project-agnostic. All project-specific details — conventions, the verification
commands that define "done", how dependencies are installed, schema/migration rules — come from
the repo's **CLAUDE.md**, which the subagent reads at the start of every task. (See the
"CLAUDE.md contract" in the plugin README.)

The end state for each issue is **an open PR awaiting human review** — never a merge.

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
- **Never merge** (`gh pr merge` is denied) and **never push to the default branch**. One issue →
  one `claude/<n>-<slug>` branch → one PR.
- **The subagent writes code; you do every git and `gh` command.**
- **A dirty working tree is only recoverable when it's clearly the harness's own.** If the
  dirty tree is on a `claude/<n>-*` branch, run the crash recovery in step 0. Anywhere else
  (the default branch, any human branch), STOP and tell the user — do not risk clobbering
  uncommitted work. Changes to `.claude/LESSONS.md` alone never count as dirty: that's harness
  bookkeeping, carried into the next harness commit (see step 2e).

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
  label `impl-blocked` — the issue re-enters the queue and step 2b's branch logic resets the
  wip branch for a fresh attempt. Note the recovery in your summary.
- **Anywhere else** → STOP and tell the user. That's uncommitted human work; it is never yours
  to move.

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
(`git log <default-branch>..<branch> --format=%s`):
- **Every unique commit is a `wip:` commit** → leftovers of a blocked or interrupted attempt
  (the findings live in the issue's comments — carry them into the dispatch as context).
  Delete it (`git branch -D <branch>`) and create the branch fresh.
- **Any non-wip commit** → real prior work. If an OPEN PR exists for the branch, skip the
  issue and warn (it should be labelled `pr-open`; the label was probably removed by mistake).
  Otherwise stop and warn for that issue — reusing or discarding committed work is the
  human's call.

c. **Dispatch the `implementer` subagent** (Task tool). The implementer runs on a smaller model
   than you: the prompt must contain **every decision and verified fact** so it never has to
   exercise design judgment or re-derive codebase facts. Include:
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
   If a BLOCKING question has no answer anywhere in the thread, do NOT dispatch — treat the issue
   as mislabelled (approved without a complete plan) and ask the human.

d. **On `status: complete`:** independently re-run the project's verification commands (from
   CLAUDE.md) as the authoritative gate — the subagent may be mistaken. Run the same checks that
   define "done" for this repo. If they fail, treat it as a blocker (step f). Compare the
   results against `.claude/BASELINE.md`: every check green at baseline must still be green,
   and counts should not drop without explanation (fewer tests passing than baseline usually
   means tests were deleted or skipped — investigate before proceeding; a legitimate drop, e.g.
   a planned test removal, must be explained by the plan or the report).

e. **Dispatch the `verifier` subagent** (Task tool, the plugin's `agents/verifier.md`) — the semantic
   gate the mechanical checks can't provide. Its prompt must contain: the issue, the full
   approved plan (Acceptance criteria + Verified facts + `RESOLVED:` decisions included), the
   implementer's report, the output of `git diff <default-branch>...HEAD --stat` (three-dot —
   diff from the merge base, so drift on the default branch never pollutes it), and the
   instruction
   *"Verify this implementation against the plan and acceptance criteria following your process.
   Return your verdict."*
   - **Verdict `pass`:** carry its "Notes for the PR reviewer" into the PR body, proceed to
     commit (next step).
   - **Verdict `fail`:** kick back. Re-dispatch the **implementer** with: the full approved plan,
     its own previous report, and the verifier's findings verbatim, plus *"Fix ONLY these
     verification findings. Do not expand scope. Return your report."* Then re-run the
     mechanical checks and re-dispatch the **verifier** (include its prior findings so it
     confirms each is resolved). **Maximum 2 kickbacks** (3 implementer attempts total). Still
     failing after that → blocked path (step f), with the latest findings as the blocker
     explanation. Record the number of verification rounds for the summary table.

   - Once the verifier passes: stage everything, then sanity-check what got staged **before**
     committing:
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

     **File the plan's follow-ups.** If the approved plan has a "Follow-ups to file" section
     (deferred phases, discovered out-of-scope work), file each one now with `gh issue create`,
     referencing this PR, and mention the new issue numbers in the PR body and your summary.

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
       **implementer** on the branch with the plan, its report, the failing log excerpt, and
       *"Fix ONLY this CI failure. Do not expand scope. Return your report."* Re-run the
       mechanical checks, re-dispatch the **verifier** (prior context included, scope: the
       fix), then commit (`fix: <what> (CI, #<number>)`) and push — CI re-runs on the new
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
   flag the issue, and reset the tree:
```bash
git add -A
git commit -m "wip: blocked — <short reason> (#<number>)"   # local only, not pushed (skip if nothing changed)
gh issue comment <number> --body-file <tempfile>            # blocker explanation (incl. verifier findings, if any)
gh issue edit <number> --add-label impl-blocked
git checkout <default-branch>
```

g. Move to the next issue (back to step 2a).

### 3. Summarise

Report a table: issue number, title, outcome (PR opened → link / blocked → branch name),
verification rounds (1 = clean first pass; 2–3 = kickbacks happened — say what the verifier
caught), CI status (pass / fixed after 1 attempt / fail / no checks), and any issues skipped
and why. Also note: any crash recovery or wip-branch reset from pre-flight/step 2b, whether the
baseline was refreshed (and its new numbers), and whether discovery reported `truncated: true`
(more approved issues exist than the query returned — run again after this batch).

## Worktree-parallel mode (optional)

When the batch has 2+ ready issues whose approved plans have **pairwise disjoint "Affected
areas"** (production files AND test files — compare carefully, including shared fixtures like a
test `conftest`), you may implement them in parallel using git worktrees instead of sequentially.
Any overlap, any doubt, or any plan lacking an Affected areas section → sequential. Worth using
for 2–4 small/medium disjoint issues; beyond that, queue depth beats fan-out.

a. **Create one worktree per issue** (siblings of the repo, never nested inside it):
```bash
git worktree add "../<repo-dirname>-wt-<number>" -b "claude/<number>-<slug>" <default-branch>
```

b. **Dispatch all implementer subagents in one batch** (they run concurrently). Each prompt is
   exactly as in step 2c, PLUS: *"Work EXCLUSIVELY inside <absolute worktree path>. Every file
   you read, write, or edit and every command you run must use that path — never the main
   repository checkout."* Include the worktree path when stating verification commands. Also
   name the sibling issues' affected files as explicitly out of scope ("issues <n>, <m> are
   being implemented concurrently — do NOT touch <their files>") so a subagent that discovers
   adjacent work doesn't drift into a concurrent issue's territory.

c. **Dependency caveat (critical):** ignored files don't exist in a fresh worktree — virtualenvs,
   `node_modules`, `.env`. Tell each subagent how to verify without reinstalling: e.g. for a
   Python project, run the MAIN checkout's venv binary against the worktree's tests
   (`cd <worktree>/api && <main-repo>/api/.venv/bin/python -m pytest`). If a plan touches UI and
   needs `npm install`/`npm run build` per worktree, prefer sequential mode for that issue
   instead of duplicating installs.

d. **As each implementer completes, run steps 2d–2e per worktree** (mechanical checks with the
   main venv as above, then the verifier — its prompt must also carry the worktree path, and its
   diff is `git -C <worktree> diff <default-branch>`). Kickbacks re-dispatch into the same
   worktree. Then commit/push/PR with `git -C <worktree> ...`. Process completions one at a time
   — your own git/gh work stays sequential even when subagents ran in parallel.

e. **Clean up each worktree** after its PR is open (the branch lives on in the repo):
```bash
git worktree remove "../<repo-dirname>-wt-<number>"
```
   On the blocked path, keep the worktree until the `wip:` commit exists, then remove it.

f. Everything else is unchanged: same labels, same PR contract, same CI watch, same summary
   table (add a worktree/parallel column so the human knows which mode ran).

## Notes

- **After the human merges:** nothing is required — this skill's pre-flight runs
  `cleanup-after-merge.sh --fix` and the baseline refresh, which together cover branch sync,
  branch/label hygiene, and re-verifying merged main. Running `cleanup-after-merge.sh` by hand
  right after a merge is still fine (it's idempotent) if the human wants the tidy-up
  immediately.
- **Stale `pr-open` recovery:** if a PR is closed *without* merging, the issue keeps its
  `pr-open` label and silently never re-enters the queue. The pre-flight's
  `cleanup-after-merge.sh --fix` repairs this automatically (removes the label with an audit
  comment); step 2b then decides what to do with the old branch — wip-only branches are reset,
  branches with real commits go to the human.
- **Parallelism:** supported via the worktree-parallel mode above, gated on pairwise-disjoint
  Affected areas. Sequential remains the default and the fallback whenever eligibility is
  unclear.
- **Transient subagent deaths:** if a subagent dispatch dies on an infrastructure error (API/
  socket failure with no usable output), re-dispatch fresh with the same prompt — it is a retry,
  not a kickback, and does not count toward the kickback limit. Only treat repeated identical
  deaths as a blocker.
- Schema changes: if the subagent created a migration or other schema change, the PR body must say
  so clearly — it has NOT been applied to any database. Applying it is a human step, per the
  project's process in CLAUDE.md.
- Branch protection on the default branch (require a PR) is the real safeguard against accidental
  direct pushes; recommend the user enables it if they haven't.
- Commit messages should follow whatever convention CLAUDE.md specifies (the `feat:` examples
  above assume Conventional Commits; adjust if the project differs).
