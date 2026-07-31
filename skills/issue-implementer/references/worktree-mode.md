# Worktree-parallel mode (optional)

This file is the full worktree-parallel dispatch procedure for the issue-implementer skill.
Eligibility for this mode is decided in `SKILL.md`, not here — read this file only after
`SKILL.md` has told you to enter the mode. Every budget, vocabulary, and contract this file
references (the retry ladder, the WIP checkpoint vocabulary, the resume cap, the kickback limit)
is defined in `SKILL.md`'s "Resilient dispatch" and is unchanged by the fan-out.

When the batch has 2+ ready issues whose approved plans have **pairwise disjoint "Affected
areas"** (production files AND test files — compare carefully, including shared fixtures like a
test `conftest`), you may implement them in parallel using git worktrees instead of sequentially.
Any overlap, any doubt, or any plan lacking an Affected areas section → sequential.

**Concurrency bound: at most 4 implementer dispatches in flight at once.** Two to four
small/medium disjoint issues is the sweet spot; a fifth eligible issue waits for a free slot
rather than widening the fan-out — beyond 4, queue depth beats fan-out. Only implementer
dispatches fan out. The mechanical checks, the verifier dispatch, the commit/push/PR sequence
and the blocked path all stay **serialized**, one worktree at a time: they share the main
checkout's toolchain (the issue-implementer skill's step 2d) and your own git/`gh` hands.

## Supervisor loop

There is no separate coordinator process — **you are the supervisor**. Keep a **worktree table**
in context for the life of the swarm, one row per issue: issue number, worktree path, branch,
current stage (`implementer` → `checks` → `verifier` → `pr` → `ci` → terminal), dispatch attempt
`k`, kickbacks used (of 2), resume relaunches used (of 2), last WIP SHA, and whether a dispatch
is in flight. Every budget in the issue-implementer skill's "Resilient dispatch" is **per
issue**: a ladder retry or a resume relaunch in one worktree never consumes another's.

Work in **rounds, not barriers.** A round is: launch every currently-launchable dispatch as one
batch (never exceeding the concurrency bound in flight), then take the returned reports **one at
a time**, in completion order, carrying that worktree's serial work (Swarm procedure step e,
below) through to its PR or its blocked commit before picking up the next report. Never hold a
finished worktree behind an unfinished one. Whatever the round produces — kickbacks, resume
relaunches, ladder retries, newly freed slots — becomes the next round's batch.

Three rules keep one sick worktree from stalling the swarm:

- **Checkpoint in the worktree before every re-dispatch into it** — ladder retry, resume
  relaunch, or kickback. For a death that is `git -C <worktree> add -A && git -C <worktree>
  commit -m "wip: implementer died (#<n>)"` (skip if nothing changed); otherwise the
  stage-appropriate message from the issue-implementer skill's "WIP checkpoint vocabulary".
  This is the one place the swarm does *more* than sequential mode, deliberately. The commit is
  a no-op when nothing changed, so the vocabulary and the classification rule are untouched.
- **Backoff waits go last.** Run the ladder's `sleep` for a dead worktree only after every other
  worktree's ready work in that round is drained — a 240s wait must never be why another
  worktree's PR is late.
- **Defer the CI watch.** `gh pr checks --watch` blocks for as long as CI takes; run inline it
  would serialize the whole swarm behind one repo's slowest check. Open the PR, record the watch
  as pending, and drain the pending watches one at a time once no implementer dispatch is in
  flight — each with its single bounded CI-fix attempt exactly per the issue-implementer skill's
  step 2e, re-dispatching the implementer into that issue's worktree. A worktree stays alive
  until its watch is drained.

**Relaunch is always into the same worktree on the same branch.** Never recreate the worktree,
never re-cut the branch, never `git worktree add -b` twice for one issue: after step b (below)
the branch exists and already carries the work, so a resumed dispatch is exactly the
issue-implementer skill's step 2c's relaunch with `-C <worktree>` in front of the git commands.

**Every worktree reaches a terminal state before the swarm ends** — PR open with a CI outcome
recorded, `impl-blocked` via the issue-implementer skill's step 2f, or a stage escalated as
failed after the ladder — and every one leaves a status line and a ledger record. Exhausting the
ladder or the resume cap in one worktree routes that issue to the blocked path and leaves the
rest of the swarm running; it never ends the swarm. A worktree you launched and never accounted
for is exactly the failure this loop exists to prevent.

**Ledger and status lines are unchanged by the fan-out.** One worktree = one issue = one ledger
row: each dispatch's status line is its record, with the same `stage`/`outcome`/`retries`
vocabulary, and you emit the line yourself for any worktree stage that died with no usable
report. Records land out of issue order as completions interleave — harmless:
`reconcile-ledger.sh` sorts by issue and keeps the last record per issue+stage, so a swarm run
reconciles exactly like a sequential one.

## Swarm procedure

a. **Stale worktrees are already swept.** The issue-implementer skill's step 0 pre-flight does
   it once per run, before any issue work and in both modes — nothing to repeat here. If a
   straggler survives it, step b's last bullet (below) routes back to that rule.

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
     (`git log <default-branch>..<branch> --format=%s`) using the classification rule from the
     issue-implementer skill's "Resilient dispatch". Same three cases as its step 2b, same
     rules, different plumbing:
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
     worktree** → the issue-implementer skill's step 0 sweep missed one whose directory still
     exists. Re-read `git worktree list --porcelain`, apply that sweep's rule to that path, and
     retry. If it instead refuses because the *path* exists but is not registered, stop and tell
     the human — never delete a directory to clear the way (`rm -rf` is deny-listed, and for
     good reason).

c. **Dispatch the implementers as one batch** (up to the concurrency bound; they run
   concurrently). Each prompt is exactly as in the issue-implementer skill's step 2c —
   including the dispatch attempt number, and the resume brief plus verbatim relaunch
   instruction wherever step b resumed a branch — PLUS: *"Work EXCLUSIVELY inside <absolute
   worktree path>. Every file you read, write, or edit and every command you run must use that
   path — never the main repository checkout."* A dispatch that fails is retried per the
   issue-implementer skill's "Resilient dispatch" ladder, same as step 2c. Include the worktree
   path when stating verification commands. On Windows, write every path you embed in a prompt
   or command with **forward slashes** (`C:/Users/...` or `/c/Users/...`) — commands run under
   Git Bash, where backslash paths get mangled by quoting. Also name the sibling issues'
   affected files as explicitly out of scope ("issues <n>, <m> are being implemented
   concurrently — do NOT touch <their files>") so a subagent that discovers adjacent work
   doesn't drift into a concurrent issue's territory.

d. **Dependency caveat (critical):** ignored files don't exist in a fresh worktree — virtualenvs,
   `node_modules`, `.env`. Tell each subagent how to verify without reinstalling: e.g. for a
   Python project, run the MAIN checkout's venv interpreter against the worktree's tests
   (`cd <worktree>/api && <main-repo>/api/.venv/bin/python -m pytest` — on Windows the venv's
   interpreter is `.venv/Scripts/python.exe`, not `.venv/bin/python`; state the exact path in
   the prompt — the subagent works only inside its worktree and cannot discover the main
   checkout's layout). If a plan touches UI and needs `npm install`/`npm run build` per
   worktree, prefer sequential mode for that issue instead of duplicating installs.

e. **As each implementer completes, run the issue-implementer skill's steps 2d–2e for that
   worktree** (mechanical checks with the main venv as above, then the verifier — its prompt
   must also carry the worktree path), one worktree at a time. Everything in the sequential
   pipeline applies verbatim; what changes is only where it runs. **Identical:** the retry
   ladder and its escalation, the WIP checkpoint vocabulary and the classification rule, the
   resume brief's five elements and its cap of 2, the max-2 kickback limit, the status-line
   grammar, the mechanical checks as the authoritative gate, the staged-file reconciliation, and
   the PR contract. **Worktree-specific:**
   - **every git command takes `-C <worktree>`** — the verifier's diff is `git -C <worktree> diff
     <default-branch>...HEAD --stat` (three-dot, matching sequential mode now that checkpoints
     make it non-empty here too), checkpoints are `git -C <worktree> add -A && git -C <worktree>
     commit -m "wip: checkpoint <stage> (#<n>)"`, and the pre-final-commit collapse is `git -C
     <worktree> reset --soft "$(git -C <worktree> merge-base <default-branch> HEAD)"` — the
     merge base is computed per worktree, which is what makes a resumed branch collapse
     correctly. These forms need the `git -C` grants added in v1.8.1 — a permission prompt on
     any of them means this repo's `.claude/settings.json` predates them; finish that issue
     sequentially instead and tell the human to re-copy the `permissions` block from the
     plugin's `templates/repo-settings.json`;
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
   whether its branch was created fresh, resumed, or reset, and whether the issue-implementer
   skill's step 0 pre-flight sweep swept a stale worktree for it.
