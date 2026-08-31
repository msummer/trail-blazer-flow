# Trail Blazer Flow - A portable Claude Code development harness

**Trail Blazer Flow** is a software development harness, designed as a plug-in for Claude
Code, that supports an agentic, GitHub issues driven development cycle. 

A project-agnostic Claude Code setup for driving GitHub issues through **planning**,
**implementation**, and **verification**, locally, on your Claude Code subscription (no API
keys, OAuth tokens, or GitHub Actions). The generic *mechanism* lives here; everything
project-specific lives in the target repo's `CLAUDE.md` and `.claude/LESSONS.md`.

> **Status: early access.** This harness is in active testing with a small group. Expect rough
> edges and occasional breaking changes — and note that, by default, updates arrive
> automatically (see "Updating"). Bug reports and feedback are very welcome: please
> [open an issue](https://github.com/msummer/trail-blazer-flow/issues). Licensed under
> [MIT](LICENSE).

This repo is a **Claude Code plugin** (and its own marketplace — see "Installing in a new
repo"). Keep the boundary in mind when editing: nothing project-specific belongs in the skills
or agent files — it belongs in the target repo's `CLAUDE.md` (conventions, verification
commands) or `.claude/LESSONS.md` (project gotchas), both of which stay with each project.
Four things always live on the project side, never here: `LESSONS.md` (seeded by the doctor
script), a thin `.claude/settings.json` (permission grants — plugins cannot ship permissions;
template provided), `.claude/BASELINE.md` (the machine-local verification baseline — gitignored,
harness-maintained), and `settings.local.json` (machine-local secrets/overrides — never commit
or share).

## What's in here

```
.
├── CLAUDE.md                     # this repo's OWN harness contract — governs work on the harness itself
├── .claude-plugin/
│   ├── plugin.json               # plugin manifest (semver version field — bump it to publish an update)
│   └── marketplace.json          # this repo doubles as its own marketplace
├── agents/
│   ├── planner.md                # read-only planning subagent (Opus 5)
│   ├── implementer.md            # code-writing subagent (Sonnet 5); no git/network
│   └── verifier.md               # plan-conformance reviewer (Opus 5); fresh context; restores anything it mutates
├── skills/
│   ├── project-kickoff/SKILL.md  # greenfield on-ramp: interview → brief + CLAUDE.md + repo + backlog
│   ├── harness-setup/SKILL.md    # one-time repo onboarding: doctor + CLAUDE.md audit + baseline
│   ├── issue-planner/SKILL.md    # orchestrates planning (answers → revision → policy auto-approval)
│   ├── issue-implementer/SKILL.md # orchestrates implementation → verification → PR (+ CI fix)
│   ├── issue-implementer/references/worktree-mode.md  # worktree-parallel procedure (read on demand)
│   ├── issue-cycle/SKILL.md      # steady-state loop: cleanup → plan → implement → status report
│   └── test-ratchet/SKILL.md     # optional, policy-gated: files coverage-increasing issues (never implements)
├── bin/                          # on the Bash PATH when the plugin is enabled
│   ├── check-harness.sh           # mechanical preflight ("doctor"); safe to re-run any time
│   ├── check-decision-record.sh   # scoped-autonomy: checks an issue body against a declared decision record
│   ├── find-planning-work.sh
│   ├── setup-labels.sh            # creates the workflow labels (run once per repo)
│   ├── find-implementation-work.sh
│   ├── harness-status.sh          # who acts next: harness queues vs. items waiting on the human
│   ├── reconcile-ledger.sh        # reconciles a cycle's dispatch ledger against live state
│   └── cleanup-after-merge.sh     # post-merge sync + branch/label hygiene (--fix repairs labels)
├── hooks/                        # plugin-shipped Claude Code hooks — never on the Bash PATH, never invoked by the model
│   ├── hooks.json                 # registers the PreToolUse guard below
│   └── git-c-guard.sh             # approves only the exact git -C <worktree> <subcommand> forms worktree-parallel mode issues
├── dev/
│   ├── selfcheck.sh              # this repo's OWN verification gate — see "Working on the harness itself"
│   ├── selfcheck-tests.sh        # the gate's own negative-test harness (not run by the gate itself)
│   ├── doctor-tests.sh           # fixture-based negative-test harness for bin/check-harness.sh (not run by the gate)
│   ├── hook-tests.sh             # fixture-based negative-test harness for hooks/git-c-guard.sh (not run by the gate)
│   ├── cleanup-tests.sh          # fixture-based negative-test harness for bin/cleanup-after-merge.sh (not run by the gate)
│   └── planning-tests.sh         # fixture-based negative-test harness for bin/find-planning-work.sh AND bin/find-implementation-work.sh (not run by the gate)
├── .github/
│   ├── workflows/selfcheck.yml # CI: gate, then its negative-test harness, then the doctor's negative-test harness, then the guard hook's negative-test harness, then the cleanup script's negative-test harness, then the two discovery scripts' shared negative-test harness — on ubuntu-latest and, pinned to Apple's bash 3.2, on macos-latest
│   └── dependabot.yml          # weekly github-actions update PRs, so the workflow's SHA pins don't age out
└── templates/
    └── repo-settings.json        # thin per-repo .claude/settings.json (permissions + marketplace + enabledPlugins)
```

Skills are invoked with the plugin namespace (`/trail-blazer-flow:issue-planner`, …) or by natural
language ("plan issue 14"). The `bin/` scripts are plain commands on the session's PATH — that
is why the per-repo permission entries are portable bare names (`Bash(check-harness.sh:*)`)
rather than machine-specific plugin-cache paths.

## The model tiering (deliberate design)

Three capability tiers, each placed where it pays:

| Role | Model | Why |
|------|-------|-----|
| **Orchestrator** (the main session) | most capable available | judgment calls: proposing answers to open questions, verifying premises with measurements, reconciling staged files vs. reports, deciding when something is a blocker |
| **planner** subagent | Opus 5 | codebase research and design; one dispatch per issue, read-only |
| **implementer** subagent | Sonnet 5 | execution of a fully-resolved plan; cheap enough to run often (and in parallel) |
| **verifier** subagent | Opus 5 | adversarial plan-conformance review of the diff with fresh context — the generator/critic split; judgment-heavy, so it gets the stronger model |

Two consequences are baked into the skills:
1. **Ambiguity is resolved top-down, before execution.** Plans classify questions
   BLOCKING/ADVISORY; the orchestrator proposes answers; the implementer receives only
   `RESOLVED:` decisions — it should never exercise design judgment.
2. **Research flows down as "Verified facts".** The planner writes down every codebase fact it
   confirmed (exact names, signatures, fixture contracts, ordering constraints), so every
   downstream dispatch — the implementer, the verifier, retries, parallel runs — works from one
   written account instead of re-deriving it: research gets paid for once, not per dispatch, and
   the implementer's context stays on the change instead of the exploration.

## How it works

### Starting a new project ("start a new project" / "I want to build …")

The `project-kickoff` skill is the **greenfield on-ramp** — the front door for a project that
doesn't exist yet. The rest of the harness consumes GitHub issues and reads `CLAUDE.md`; kickoff
produces the first of each. The main session (no subagents):
1. **Interviews** the user — document-first if they have a PRD/notes/link (ingest it, ask only
   about gaps), a fuller interview if they don't. Adaptive depth, batched recommendation-first
   questions, and an explicit nudge to **dictate by voice** to keep a thorough interview from
   feeling like an interrogation. Open points are tagged BLOCKING / ADVISORY / DEFERRED.
2. **Synthesizes** an opinionated brief, architecture/stack (with rationale and rejected
   alternatives), methodology, and a proposed issue backlog — presented for a **single approval**.
3. On approval, **connects GitHub** (creates or selects the repo, installs labels, lays down the
   thin `.claude/settings.json`), then emits the artifacts: `docs/PROJECT-BRIEF.md`, a drafted
   `CLAUDE.md`, and the **issue backlog whose first item is a walking skeleton** (project
   skeleton + verification setup — the thing that later makes the baseline green).
4. **Hands off:** plan+implement the skeleton issue first → run `harness-setup` to record the
   green baseline (which can't exist until there's code) → `issue-planner` on the rest.

Kickoff never writes feature code and never establishes the baseline itself (no buildable code
yet — that's `harness-setup`'s job after the skeleton lands). For an *existing* codebase, skip
kickoff and go straight to `harness-setup`.

### Planning ("plan the open issues" / "plan issues 13 and 15")

The `issue-planner` skill:
1. Pre-flight: `cleanup-after-merge.sh --fix` (sync + queue hygiene), then makes sure plans are
   written against the current default branch.
2. Finds issues needing an **initial plan** (no `plan-*` label) or a **revision**
   (`plan-proposed` with maintainer — `OWNER`/`MEMBER`/`COLLABORATOR` — comments after the latest
   trusted plan), via `find-planning-work.sh`. Comments from anyone else are reported, never
   acted on — see "Safety model" below. Each issue also carries its author's association;
   non-maintainer-authored issues are still planned but can never be auto-approved (step 6).
3. Dispatches the read-only `planner` subagent per issue (parallel dispatches OK — each is
   scoped to one issue). Prompts include relevant `LESSONS.md` entries and any orchestrator
   context the issue lacks (recently merged PRs, corrected measurements).
4. Posts each plan as an issue comment tagged `<!-- planner-plan -->`, labels `plan-proposed`.
5. **Handles stale and overlapping plans**: a pending `plan-proposed` plan whose affected files
   changed under it (PRs merged since posting) gets a staleness comment and an immediate
   same-run revision; a stale `plan-approved` plan gets the comment plus a prominent flag (the
   human approved *that* plan — re-approval is theirs). Overlapping plans (same files → merge
   conflicts) are flagged and excluded from auto-approval.
6. **Proposes answers and revises in the same run**: for BLOCKING open questions the
   orchestrator can ground in code/measurements, it posts proposed answers as a comment, then
   immediately revises the plan, tagging each folded decision `RESOLVED
   (orchestrator-proposed):` so provenance is visible at approval time. The human reviews one
   artifact instead of two rounds. Ungroundable questions stay open for the human.
7. **Auto-approves under the repo's policy, if one exists** — see "Approval" below.

The plan template (see `agents/planner.md`) includes: Summary, **Acceptance criteria** (the
testable definition of done the verifier later checks against — derived even when the issue
didn't state any), Estimated size (S/M/L), Affected areas (including a **"Claims this change
falsifies"** sub-list: the docs, docstrings, comments, and ADR sentences the change invalidates,
found at planning time rather than by the verifier afterwards), Data/schema impact,
Implementation steps, Testing approach, Risks, **Verified facts**, **Open questions
(BLOCKING/ADVISORY)**, **Follow-ups to file** (each carrying a one-sentence justification), Out
of scope.

### Approval (human by default, policy-assisted if you opt in)

A maintainer (`OWNER`/`MEMBER`/`COLLABORATOR`) comments on the issue to request changes
(comment-driven, no label needed) — a comment from anyone else is reported to the human but
never treated as feedback. Add `plan-approved` to accept. **Approving a plan whose open questions are all ADVISORY accepts the stated
defaults** — no extra revision round; the orchestrator passes the defaults to the implementer as
resolved decisions. Plans with unanswered BLOCKING questions shouldn't be approved.

**Plan auto-approval (opt-in).** If the repo's `CLAUDE.md` contains a section titled **"Plan
auto-approval policy"**, the planner may add `plan-approved` itself for plans that satisfy the
policy's conditions AND a non-negotiable hard floor (see "The CLAUDE.md contract" item 4). Every
auto-approval leaves an audit comment (which conditions were met, how to veto). No policy section
⇒ no auto-approval — the default is fully manual. The **`no-auto-approve` label** opts any
individual issue back out of the policy. Note that an auto-approved plan may be implemented in
the same run — for that work, PR review is the human gate.

### Implementation ("implement the approved issues" / "implement issue 14")

The `issue-implementer` skill, for each `plan-approved` issue (sequential by default):
1. Pre-flight: crash recovery (a dirty tree on a `claude/<n>-*` branch from an interrupted run
   is wip-committed, noted on the issue, and requeued; a dirty tree anywhere else is a hard
   stop — that's human work; stale worktrees left by a crashed swarm are swept in the same
   pre-flight (a dirty one is wip-committed first, then removed), so a sequential run no longer
   trips over a branch still checked out elsewhere), `cleanup-after-merge.sh --fix`, and the
   **baseline refresh**: if
   the default branch moved past `.claude/BASELINE.md`'s recorded commit, re-run the
   verification suite on it — green updates the baseline, red stops the whole run (a broken
   main makes every failure unattributable). Then a fresh `claude/<n>-<slug>` branch; a wip-only
   leftover branch is **resumed, not restarted** unless its newest commit is a `wip: blocked —
   …`, in which case it's reset fresh as before — see "Resilience" below. Branches with real
   (non-wip) commits still go to the human.
2. Dispatches the `implementer` subagent with: issue + full plan (incl. Verified facts) +
   **resolved answers to every open question** (including binding post-approval comments, taken
   from `find-implementation-work.sh`'s per-issue plan selection, not read from the thread by
   hand) + `LESSONS.md` entries. Missing a BLOCKING answer → don't dispatch; ask the human.
   Before reporting, the subagent runs a mandatory evidence pass — sweeping the repo for every
   claim its diff falsifies, mutation-checking each new or rewritten test, pasting every number
   from command output — and records it in its report's Evidence block.
3. On completion: **independently re-runs the verification commands** (the mechanical gate — the
   subagent may be wrong, and this re-run stays the authoritative gate), comparing against the
   recorded baseline (counts must not drop unexplained).
4. **Dispatches the `verifier` subagent** (the semantic gate): fresh-context review of the diff
   against the plan's steps, the plan's acceptance criteria, test quality — including a bounded
   mutation probe (3 to 5 mutants in the changed code, tests re-run against each, tree restored
   immediately after every mutant; a surviving mutant on a behavior the plan's criteria named is
   a `major` finding) — scope, declared constraints, and, when CLAUDE.md declares an "Autonomy
   reserve", the diff's changed paths against those same globs (an undeclared reserve touch is a
   `blocker` finding). **Verifier fail → kickback**: the
   implementer is re-dispatched with the findings ("fix ONLY these"), then re-checked — **max 2
   kickbacks**, then `impl-blocked` with the findings; **the orchestrator itself never patches a
   finding** — it never edits a source, test, or doc file to resolve one, only re-dispatches the
   implementer or, once kickbacks are exhausted, takes the blocked path. All of this happens
   *before* anything is pushed or a PR exists — the branch may already carry local WIP checkpoint
   commits by this point (see "Resilience: checkpointing, retries, and the dispatch ledger"
   below), but nothing leaves the machine until the verifier passes, so every PR the human sees is
   verifier-clean.
5. On verifier pass: **archives the verdict verbatim as an issue comment** (opening with
   `<!-- verifier-verdict -->`, its second line keying the archive to this PR's head branch,
   after every pass, including a later CI-fix re-verification), then
   **collapses the run's WIP checkpoint commits** into the working tree (one
   `git reset --soft` to the branch's merge base with the default branch — never the working
   tree itself, which is untouched), stages everything, **reconciles the staged list against the
   report's "Files changed"** (unexplained files = blocker, not a commit), commits once, pushes,
   opens the PR (`Closes #n`, verification results, **the verifier's own closing status line
   pasted verbatim** — never one the orchestrator composes on its behalf — a `Mutation probe:`
   line carrying the verdict's mutation-probe result, the implementer's Evidence block condensed
   to its Claims-swept and Mutation-checks lines, schema notes, verifier notes), labels
   `pr-open`. The PR still ends up as one clean commit, exactly as before.
6. **Files the plan's "Follow-ups to file"** as new issues referencing the PR — each entry whose
   justification names a concrete failure a user of this software would experience, filed with
   `no-auto-approve` (machine-authored — a human removes the label to release it into approval)
   and a marker naming the PR it came from — then **writes the new issue numbers back into the PR
   body with `gh pr edit`**, not merely mentioned in the summary; entries that only name a
   capability wish or an unnoticeable drift risk are declined with a note in the PR body instead
   of becoming issues. If this PR is later closed without merging, the next
   `cleanup-after-merge.sh --fix` comments on and labels `no-plan` any of those follow-ups still
   open.
7. **Watches CI** (`gh pr checks --watch`). Red CI caused by the PR itself gets **one bounded
   fix attempt** (implementer → mechanical checks → verifier → push; the PR isn't merged, so
   this is as safe as the kickback loop) — once that re-verification passes, its verdict is
   archived too, and the PR body's verifier status line and `Mutation probe:` line are refreshed
   with `gh pr edit` so the body always describes the tree the head commit actually carries (a
   denied `gh pr edit` is reported loudly, never routed around); still red — or not the PR's
   fault — is noted on the issue for the human. If the failure was a project gotcha, **append it
   to `LESSONS.md`**.
8. Never merges (merging is the human's, or the cycle's merge pass under an opt-in policy —
   see "The CLAUDE.md contract"). Blockers → local `wip:` branch + `impl-blocked` label +
   explanatory comment.

**Worktree-parallel mode:** when 2+ approved plans have pairwise **disjoint Affected areas**
(production + test files), the orchestrator may create one git worktree per issue and dispatch up
to **4 implementers concurrently**, acting as their **supervisor**: it tracks each worktree in an
in-context table, handles each completion as it arrives instead of waiting for the batch,
checkpoints a dead subagent's worktree *before* re-dispatching it under the same retry ladder and
resume cap as sequential mode, and defers the blocking CI watches until no implementer is still
running. Only the implementer dispatches fan out — the mechanical checks, the verifier, and the
orchestrator's own git/gh work stay sequential, one worktree at a time. Leftover state from an
earlier run is handled rather than fatal: the pre-flight's stale-worktree sweep (above) has
already run for both modes, and an existing `claude/<n>-*` branch is attached and
resumed instead of failing a `git worktree add -b` — reset fresh only when its newest commit is a
`wip: blocked — …`, exactly as sequential mode decides. Ignored files (venvs, `node_modules`)
don't exist in fresh worktrees: verification runs the main checkout's tool binaries against the
worktree, and UI-heavy issues that need per-tree installs fall back to sequential. Any overlap or
doubt → sequential.

### Resilience: checkpointing, retries, and the dispatch ledger

Recovery is an owned mechanism, not improvisation (canonical spec: the `issue-implementer`
skill's "Resilient dispatch", cited by name from `issue-planner`/`issue-cycle`): WIP
checkpointing with resume-not-restart, bounded exponential backoff before a stage escalates as
**failed**, a clean exit on context exhaustion under a capped relaunch budget, a status-line-fed
dispatch ledger reconciled by `reconcile-ledger.sh`, and merge guards — see "The steady state"
below for the ledger and the guards.

### After the human merges

Nothing is required: every planner/implementer/cycle run starts with
`cleanup-after-merge.sh --fix` (best-effort sync — a diverged/missing upstream is reported and
the run continues, never aborts, prune merged `claude/*` branches — a merged branch a
worktree still holds is reported and skipped, never fatal — repair stale `pr-open` labels with
audited comments, and quarantine any plan follow-up orphaned by a `claude/*` PR that closed
without merging — comment + `no-plan`, never closed) and the implementer's baseline refresh
re-verifies merged main — two green PRs can still compose badly, and that check is now
mechanical. The script's own pre-flight lookups (the default branch, the current branch, the
open-PR list, the `pr-open`-labelled issue list, and the follow-up-candidate issue search) are
best-effort too — a failure on any of them is reported (`WARN`) and the run continues, degrading
gracefully (skipping just the sync, or just the label/follow-up steps that depend on it) rather
than aborting before producing any output. Running `cleanup-after-merge.sh` by hand right after a
merge is still fine (it's idempotent); without `--fix` it only reports label problems instead of
repairing them.

A merged `claude/<n>-*` PR only closes its issue when the PR body carries a closing keyword
(`Closes`/`Fixes`/`Resolves #<n>`) for that issue and no multi-PR signal is present. A PR that
delivers only part of an issue — its body says `Part of #<n>` / `PR <k> of <m>`, another
`claude/<n>-*` PR is still open, or the issue body/a comment carries a
`<!-- harness-multi-pr -->` marker — leaves the issue open (reported as `KEEP`) instead of
closing it. `--fix` still drops `pr-open` in that case, but only once no other `claude/<n>-*`
PR is open, so the issue re-queues for its next slice; a human closes it by hand if the work is
actually finished.

### The steady state, as one command ("run the cycle")

The `issue-cycle` skill composes the above into a single bounded pass: pre-flight → planning
pass → implementation pass → merge pass (**opt-in**: only with a CLAUDE.md "Merge autonomy
policy" *and* the `gh pr merge` deny lifted; guarded per PR, one at a time, re-verified between,
audited in the report) → a closing reconciliation, comparing the run's **dispatch ledger**
against `harness-status.sh`'s live queues via `reconcile-ledger.sh` (an issue with no recorded
outcome is escalated, never dropped), then a **per-issue summary table** and a two-halves report
— *what the cycle did* and *what waits on the human* (plans to review, PRs to merge, blocked
issues). It adds no authority beyond what CLAUDE.md delegates — it just removes the
hand-cranking between stages. Pair it with `/loop` or a scheduled routine for unattended
operation; each invocation stays one bounded pass, and an empty cycle reports "all quiet" in one
line. See the `issue-cycle` skill for the full procedure.

### The test-suite ratchet (opt-in)

The `test-ratchet` skill is the harness's only skill that files **machine-authored** issues —
proposals derived from tool output, closing measurable test coverage gaps. Off unless `CLAUDE.md`
has a section titled exactly **"Test-suite ratchet policy"**, which must state a measurement
command (required — no command means no ratchet) and may add a scope, per-run/open-backlog caps
(each may only lower the hard floor's numbers, never raise them), and a per-file target.

A non-configurable hard floor applies on top (see "The CLAUDE.md contract" item 6); closing an
issue as *not planned* vetoes that gap permanently.

Runs as `issue-cycle`'s **step 4, after the merge pass**, so the measurement reflects everything
that landed this run; an issue it files this run can't be planned, approved, or implemented
until the *next* cycle. It only files issues — never plans, approves, implements, or merges what
it files.

### Working the human gates from the phone

Every gate the harness waits on is an ordinary GitHub object — a label, an issue comment, a pull
request — so a cycle running unattended (via `/loop` or a scheduled routine) can be driven
entirely from wherever you read GitHub notifications, including the GitHub mobile app, without a
laptop in reach.

**What a cycle leaves behind.** A plan is a comment on the issue carrying a `<!-- planner-plan
-->` marker, with the `plan-proposed` label added to the issue. Implementation work becomes a
pull request, opened once the verifier passes, with the verification results in its body. You
only see either one if you're watching the repo or subscribed to the issue/PR — GitHub's own
notification settings govern that, not this harness.

**Reviewing a plan.** Read the issue comment. To accept it, add the `plan-approved` label. To
request changes, comment on the issue with what to change — no label needed; the next cycle
reads your comment and revises. To take an issue out of planning entirely, add `no-plan`.

**Reviewing a PR.** Read the PR body (summary, files changed, verification results, the
verifier's own status line, its mutation-probe line, the implementer's condensed Evidence lines)
and its CI checks. Merge it, or close it, the same as any other PR; comment on it first if you
want changes made before either.

**Returning to a laptop.** Run `harness-status.sh` to see what's left: `counts.human_actions` is
the total waiting on you, broken into `waiting_on_human.plans_to_review`,
`waiting_on_human.prs_to_review` (each PR entry carries a coarse `ci`: `passing`, `failing`,
`pending`, or `none`), and `waiting_on_human.blocked`. Nothing in that JSON is phone-specific —
it's the same summary a scheduled routine's own report already gives you.

## Greenfield walkthrough: from idea to first feature

This is the end-to-end story of starting a project on the harness — exactly what you say to the
orchestrator (Claude Code running in the project directory) at each stage, and what it does in
response. Lines in **quotes** are what *you* type or say (dictation works fine); everything else
is the harness acting. Approvals and merges are yours by default (each is delegable only
through an explicit policy section you write into CLAUDE.md — see "The CLAUDE.md contract").

**Before you start:** an empty (or nearly empty) directory, `gh` authenticated, and the plugin
installed (see "Installing in a new repo" step 1). You do **not** need a GitHub repo yet —
kickoff creates one with you.

### Why the order is what it is (read this once)

The harness's quality gate is a **green verification baseline** — "the suite was green at N
before my change". A brand-new project has no buildable code, so that baseline cannot exist yet.
That is the whole reason kickoff's **issue #1 is a walking skeleton**: it stands up the project
and its verification commands, and only once it's merged does a green baseline exist to record.
So the sequence is deliberately: **kickoff → build issue #1 → `harness-setup` (baseline) → build
everything else.** `harness-setup` runs *after* the first merge, not before. (Trade-off: this
means one trip through the normal plan→implement→merge loop before the baseline is locked in. We
chose this so kickoff stays code-free like every other skill — it never writes implementation,
the pipeline does.)

### Stage 1 — Kick off the project

> **"Let's start a new project — I want to build &lt;your idea&gt;."** (paste a PRD, notes, or a
> doc link if you have one; otherwise just describe it — and feel free to dictate by voice)

The `project-kickoff` skill runs. It ingests anything you shared, then interviews you — adaptive
depth, batched multiple-choice questions, going deeper only where the project is ambiguous or
high-stakes. It then shows you a synthesized **project brief**, an opinionated
**architecture/stack** (with rationale and the alternatives it rejected), a **methodology**, and
the **proposed issue backlog**, all for a single approval.

> **"Looks good — go ahead."** (or give feedback: *"use Postgres not SQLite, and drop the admin
> panel from the MVP"* — it revises and re-presents)

On approval it creates or selects the GitHub repo, installs the lifecycle labels, and writes the
project-owned files (`.claude/settings.json`, `docs/PROJECT-BRIEF.md`, a drafted `CLAUDE.md`)
plus the issue backlog — **issue #1 the walking skeleton**, the rest a focused first milestone.
It leaves the files uncommitted for your review and runs the doctor (`check-harness.sh`); the
only outstanding items will be baseline-related, which is expected.

> **"Commit and push the setup files."** (kickoff never commits on its own)

### Stage 2 — Plan and build the walking skeleton (issue #1)

> **"Plan issue 1."**

The `issue-planner` skill dispatches the read-only `planner` subagent, then posts an
implementation plan as a comment on issue #1 and labels it `plan-proposed`. Review the plan on
GitHub. To request changes, just comment on the issue and say *"revise the plan for issue 1"*; to
accept it, approve it:

```bash
gh issue edit 1 --add-label plan-approved   # or click the label in the GitHub UI
```

> **"Implement issue 1."**

The `issue-implementer` skill runs the full loop described under "Implementation" above and opens
a PR (`Closes #1`) with the verification results. Review the PR and **merge it** on GitHub. (No
cleanup step needed — the next skill run's pre-flight syncs and tidies automatically; run
`cleanup-after-merge.sh` by hand if you want the tidy-up immediately.)

Now the repo has buildable code and a passing verification suite for the first time.

### Stage 3 — Record the baseline with harness-setup

> **"Run harness-setup: audit the CLAUDE.md against the real code now that the skeleton is
> merged, and record the green verification baseline."**

The `harness-setup` skill runs the doctor, reviews the now-real `CLAUDE.md` against the actual
scaffold (the verification commands kickoff drafted are no longer aspirational — they exist and
pass), runs them and **persists the green baseline to `.claude/BASELINE.md`** (gitignored,
machine-local — see "The BASELINE.md contract"), and reports the repo **ready**. From here every
implementation run compares against this baseline, and refreshes it as merges land.

### Stage 4 — Build the rest of the backlog

From now on it's the steady-state loop, as many times as you like:

> **"Run the cycle."** → review the plans it posted (approve with `plan-approved`, or let a
> CLAUDE.md auto-approval policy handle the low-risk ones) → review and merge the PRs (or let
> a CLAUDE.md merge autonomy policy land the low-risk ones once you've opted in) →
> **"Run the cycle"** again.

(The stages are still available individually — **"Plan the open issues"** /
**"Implement the approved issues"** — and cleanup happens automatically in every run's
pre-flight.)

That's the whole lifecycle: kickoff blazed the trail (repo, conventions, backlog, skeleton), and
the planner → implementer → verifier loop walks it for every feature after.

## Label lifecycle

*(no label)* → `plan-proposed` → *(human adds, or the auto-approval policy)* `plan-approved` →
`pr-open`, with `impl-blocked` for issues needing human input, `no-plan` to opt an issue out of
planning entirely (tracking/discussion/question issues — also applied automatically by
`cleanup-after-merge.sh --fix` to a plan follow-up whose source PR closed without merging), and
`no-auto-approve` to keep an individual issue's approval manual even when CLAUDE.md defines an
auto-approval policy. `test-ratchet` marks an issue the test-suite ratchet filed, and a plan
follow-up the implementer files carries a `<!-- harness-follow-up: PR #<n> -->` marker naming
its source PR; both are harness-authored, so both also carry `no-auto-approve`. Humans gate
twice: plan approval and PR merge — each manual unless the repo's CLAUDE.md explicitly
delegates it (see "The CLAUDE.md contract"; merge delegation additionally requires the human
to lift the `gh pr merge` deny).

## The CLAUDE.md contract (required)

These skills assume the repo has a **`CLAUDE.md`** documenting the project-specifics the generic
subagents need:

1. **Conventions & architecture** — stack, code style, patterns, security/data rules.
2. **Verification commands** — the checks that define "done" (typecheck/lint/tests/build or the
   project's equivalent), ideally under a clearly labelled "Verification" section.
3. **Setup command** (optional) — how to install dependencies.
4. **Plan auto-approval policy** (optional) — a section titled exactly "Plan auto-approval
   policy" stating, in plain language, which plans the planner may approve on your behalf,
   e.g.:

   ```markdown
   ## Plan auto-approval policy
   Auto-approve plans that are size S, with no data/schema impact and no
   security-sensitive risks. Everything under `payments/` requires manual approval.
   ```

   The hard floor always applies on top (no BLOCKING questions — none answered by the
   orchestrator itself, except a granted issue's record-citing answer, see item 8 below — not
   stale, no overlap, schema/security work only if explicitly opted in, and the issue's author is
   a maintainer), every auto-approval is audited with an issue comment, and the `no-auto-approve`
   label opts any issue out. **No section means no auto-approval** — this is a trust decision that
   belongs in your file, not the plugin's.

5. **Merge autonomy policy** (optional) — a section titled exactly "Merge autonomy policy"
   stating which PRs the `issue-cycle` merge pass may merge on your behalf, e.g.:

   ```markdown
   ## Merge autonomy policy
   The cycle may merge harness PRs whose plan was approved, whose verifier verdict
   is pass, and whose CI is green — plus Dependabot patch/minor updates with green
   CI. Never: anything touching `db/`, auth, CI/CD, or dependency majors.
   ```

   Activation is a **double opt-in**: the section alone does nothing until you also remove
   `Bash(gh pr merge:*)` from the deny list (and add it to the allow list, or unattended runs
   stall on the permission prompt). Edit `.claude/settings.json` to activate for everyone, or
   `.claude/settings.local.json` (machine-local, gitignored, never committed) to activate on
   one machine only — settings.local.json is the first-class way to do that. A deny in
   *either* file — or in your user-level settings file — wins over an allow anywhere else.
   Both edits are yours, never an agent's. The merge pass's hard floor always applies on
   top (standard-flow PRs only, the PR body carrying the verifier's own `outcome=pass` status
   line — not prose — checked mechanically and cross-checked against the dispatch ledger *and*
   against the verifier's verdict archived verbatim as an issue comment for that PR's head
   branch, CI green on the head commit, never the governance surface — CLAUDE.md, `.claude/`,
   policy/ADR docs, CI config — nothing flagged for human decision, one merge at a time with
   re-verification between, every merge audited in the cycle report). **No section means no
   autonomous merges** — behavior is exactly the
   pre-1.5 default. **"No checks configured" is not green.** A repo with no CI wired up gets a
   "no checks configured" result from `gh pr checks`, and the hard floor above treats that the
   same as red: no PR qualifies for the merge pass unless your "Merge autonomy policy" section
   explicitly opts a no-CI repo in. Absent that opt-in, the PR simply waits, with the reason
   recorded in the cycle report. Recommended pairing: branch protection with required status
   checks, so the policy has a technical rail under it, not just prompt adherence.
   `check-harness.sh` judges activation from *effective* merge-permission state — across
   `.claude/settings.json`, `.claude/settings.local.json`, and your user-level settings file —
   and reports off, active (with a note when no `.github/workflows` file is found, naming the
   same no-checks-configured precondition), or (the trap it exists to catch) half-activated: a
   "Merge autonomy policy" section present while `Bash(gh pr merge:*)` is still denied in one of
   those files, which the doctor WARNs on by naming the file, because it leaves the cycle
   reporting `verified, merge blocked` on every run. Once this section is present,
   `check-harness.sh` also WARNs on any `uses:` ref in `.github/workflows/*.yml`/`*.yaml` —
   local (`./…`, `../…`) and `docker://` refs excepted — that isn't pinned to a full 40-hex
   commit SHA — under merge autonomy the cycle merges on "CI green", and a mutable tag lets its
   owner repoint what CI runs with no diff visible in this repo.

   **Post-merge verification** (optional, nested under this same section) — a sub-heading titled
   exactly "Post-merge verification" (any `#` depth) followed by a fenced block of read-only
   commands, one per line, run in order from the repo root after a merge is confirmed, so a repo
   whose default branch auto-deploys stops reporting "done" when only "merged" is true, e.g.:

   ````markdown
   ## Merge autonomy policy
   The cycle may merge harness PRs whose plan was approved, whose verifier verdict
   is pass, and whose CI is green.

   ### Post-merge verification
   Wait: 10 minutes
   ```
   railway status --service api --json
   curl -fsS https://api.example.com/readyz
   ```
   ````

   An optional `Wait: <N> minutes` line before the fence sets the poll budget (default 10,
   clamped to a non-configurable 30-minute ceiling, beyond which the pass hands off rather than
   waiting longer). The `issue-cycle` merge pass runs exactly the declared commands — never one
   it synthesizes, adapts, or extends — and records the outcome as a trailing `deploy=` field on
   the merge stage's ledger row and status line: `verified` (every command exited 0 within the
   budget), `pending` (budget spent with no conclusive result, or a permission/`sleep` problem),
   or `failed` (a command exited non-zero — which additionally stops the merge pass for the rest
   of the run); `pending`/`failed` surface loudly in the cycle report with the command output's
   last lines. **No sub-block means the merge pass behaves exactly as it does today** — no extra
   step, no `deploy=` field. These commands are reads only: the harness never approves, promotes,
   or redeploys anything — see "Safety model". `check-harness.sh` reports the declaration state as
   part of the merge-autonomy verdict — declared (with a count of fenced command lines), heading
   present but no fenced commands, or not declared at all — without ever executing, eval'ing, or
   otherwise looking up any of the declared commands themselves. When declared, it additionally
   reports whether each declared command's first token has a matching `Bash(<token>:*)` allow entry
   in the same three-file union the merge-autonomy verdict reads (`.claude/settings.json`,
   `.claude/settings.local.json`, and the user-level settings file) — a literal string comparison
   only, never a lookup or an execution — WARNing (never failing) and naming the exact entry to add
   when one is missing, so an unattended cycle doesn't discover the missing grant only after a
   merge. Because the dispatch ledger lives in each run's context only, the next run's merge pass
   re-runs these same commands once, immediately before its first merge, and stops before merging
   anything if that recheck comes back anything but `verified`.

6. **Test-suite ratchet policy** (optional) — a section titled exactly "Test-suite ratchet
   policy" stating the measurement command the `test-ratchet` skill (standalone, and as the
   `issue-cycle` ratchet pass) runs to find coverage gaps, e.g.:

   ```markdown
   ## Test-suite ratchet policy
   Measure with `pytest --cov=app --cov-report=term-missing`. Propose coverage work for
   `app/` only — never `app/migrations/`, generated clients, or `scripts/`. At most 1 issue
   per run; target 80% per file.
   ```

   A non-configurable hard floor always applies on top: test-only (adds or extends tests,
   nothing else), monotonic (never deletes, skips, or weakens an existing test, assertion, or
   threshold), evidence-backed (every issue quotes the command, the commit, and a verbatim
   output excerpt), capped at 3 issues per run and 5 open `test-ratchet` issues, and never the
   governance surface (`CLAUDE.md`, `.claude/`, policy/ADR docs, CI config). **No section means
   the ratchet never runs.** Every filed issue carries `no-auto-approve`, so plan review stays
   human by default; closing a ratchet issue as *not planned* vetoes that gap permanently.
   `check-harness.sh` reports whether the section exists and, if it does, whether it names a
   backtick-quoted measurement command that resolves on the PATH — it never runs that command
   itself; only the `harness-setup` skill does, once, at onboarding, with a human present.

7. **Autonomy reserve** (optional) — a section titled exactly "Autonomy reserve" declaring a
   fenced block of path globs, one per line (`**` allowed), naming paths a scoped-autonomy grant
   must never be treated as authorizing, e.g.:

   ````markdown
   ## Autonomy reserve
   ```
   CLAUDE.md
   .claude/**
   docs/adr/**
   ```
   ````

   The planner adds a "Reserve touch list" section to every plan when this section exists: every
   "Affected areas" entry matching a declared glob (naming the glob it matched), or "None". A
   non-empty Reserve touch list blocks auto-approval (item 4's hard floor) unless the "Plan
   auto-approval policy" section explicitly opts reserve-touching work in. The `verifier` subagent
   re-checks the same globs against the diff's actually-changed paths at review time (see
   "Implementation" step 4 above) — a changed path matching a declared glob that the plan's
   Reserve touch list never named is a `blocker` finding, whether or not the plan was
   auto-approved. **No section means the harness never populates a Reserve touch list, the hard
   floor's reserve bullet is inert, and the verifier's reserve-touch check never runs either.**
   What counts as reserved, and what a grant may override, stays this repo's decision — the
   harness only reads the declared globs and does the matching in prose.

8. **Autonomy decision record** (optional) — a section titled exactly "Autonomy decision record"
   declaring a fenced block of `key: value` lines describing the record a human-applied grant
   label requires an issue's body to carry, e.g.:

   ````markdown
   ## Autonomy decision record
   ```
   grant-label: scoped-autonomy
   record-section: Binding decisions
   element: Escalation triggers
   element: Migration posture
   element: Worked example
   ```
   ````

   `grant-label:` (required) names the label a human applies to an issue to grant it whatever
   autonomy this repo's own policy defines. `record-section:` (optional, default "Binding
   decisions") names the heading the issue body's record lives under. Each `element:` line (at
   least one required) names a required sub-heading under that section. When an issue this run
   carries the declared label, the `issue-planner` skill runs `check-decision-record.sh <n>` — a
   read-only script that fetches the issue body and checks it for the record-section heading
   (presence only) and, for each declared element, a heading nested under the record-section
   heading (strictly deeper, before the next same-or-shallower heading outside a fence — a
   same-depth heading is NOT nested) that has at least one non-blank line of content in its span
   — printing a PASS/FAIL line per check, with a distinct message for "heading absent" versus
   "heading found outside the record section" versus "heading found, no content under it" — and
   reports a `grant: will deliver` / `grant: will not deliver` verdict in its summary before
   implementation. The body scan recognises backtick- and tilde-fenced blocks of any matching
   length, indented up to 3 spaces, closing only on a same-character run at least as long
   followed by nothing but whitespace. A non-zero exit on a grant-labelled issue also joins item
   4's hard floor. **The harness never applies, removes, or creates the grant label** — that
   stays a human action — and never judges whether the record's *content* is any good, only
   whether each declared element's heading is nested under the record section, outside a fenced
   block, and has something written under it. **No 'Autonomy decision record' section means the
   check never runs and no grant is ever evaluated.** `check-harness.sh` reports
   `scoped autonomy: off` only when neither this section nor item 7's "Autonomy reserve" is
   declared; a repo that declares
   "Autonomy reserve" alone gets a WARN instead (no grant label is declared, so
   `check-decision-record.sh` never runs).

   **The body-hash grant pattern (documented convention, not harness behaviour).** A repo that
   wants its grant label to be tamper-evident against a re-label that skips a genuine re-review
   can adopt this convention in its own `CLAUDE.md`: when granting, the human posts a comment
   `grant: <sha256 of issue body>`. The canonical recipe, run as two plain commands (no allow rule
   approves a command containing command substitution — see "Safety model"):

   ```bash
   gh issue view <n> --json body --jq .body | tr -d '\r' > /tmp/body.txt
   shasum -a 256 /tmp/body.txt        # macOS/BSD
   sha256sum /tmp/body.txt            # Linux
   ```

   Both sides must use the same recipe or the digests won't match. **The harness computes and
   verifies nothing here** — a repo that wants a subagent to recompute the hash must say so in
   its own `CLAUDE.md` and add `Bash(shasum:*)` / `Bash(sha256sum:*)` to its allow-list; the
   template does not ship either grant.

The subagents read `CLAUDE.md` at the start of every task — it is the real input that makes
the harness work well in a given repo. Too little and they're guessing; too much and the
contract above drowns in restatement of what the file system, manifests, and linter config
already say. The eight items above are the floor, not a template to pad: leave out directory
tours, framework defaults, and formatter-enforced style, and keep the non-obvious — invariants,
why-this-way decisions, traps a fresh reader would hit — instead. `check-harness.sh` turns "too
much" into a mechanical proxy: it WARNs once `CLAUDE.md` passes 300 lines or 20,000 bytes,
pointing at the harness-setup skill's leanness audit — not at the eight contract items themselves.

## The LESSONS.md contract (project-owned)

`.claude/LESSONS.md` holds project-specific traps — CI quirks, fixture contracts, naming
conventions — that subagents repeatedly trip over. The skills inject relevant entries into every
subagent prompt and append new entries when a failure traces to a gotcha. **The file belongs to
the project, not this toolset**: each project keeps its own `LESSONS.md` (the doctor script
seeds an empty one on install). Format: 1–3 lines per entry, dated, written as an instruction
to a future agent. Because the harness appends lessons mid-run but never commits to the default
branch, uncommitted `LESSONS.md` changes are treated as benign everywhere the skills check for
a dirty tree, and ride along with the next harness commit.

## The BASELINE.md contract (machine-local)

`.claude/BASELINE.md` records the last **known-green** run of the verification commands on the
default branch: the full commit SHA it ran on, the date, and each command's outcome ("pytest:
631 passed"). It is what makes "the suite was green at N before my change" a checkable fact
across sessions rather than a memory of one chat. Written by `harness-setup`, refreshed
automatically by the implementer/cycle pre-flight whenever the default branch moves past the
recorded commit (green → new baseline; red → the run stops, because a broken main makes every
failure unattributable — that's also the mechanical "two green PRs can still compose badly"
check). It is **machine-local state, not a project document**: keep it gitignored
(`harness-setup` adds the entry; the doctor warns if it's missing or tracked), and never edit
it by hand. `harness-setup` and the implementer/cycle refresh both always write the full SHA; the
doctor's compare against it tolerates an abbreviated recorded value of 7 or more hex characters
as a prefix of the current tip.

## Installing in a new repo

**Starting a brand-new project?** Do step 1 below to get the plugin, then just run the
`project-kickoff` skill ("start a new project") — it does steps 2–3 *for* you (creates/selects
the GitHub repo, lays down `.claude/settings.json`, installs labels, drafts `CLAUDE.md`) as part
of the interview, and files the initial backlog. The manual steps below are for onboarding an
*existing* repo.

1. **Add the marketplace and install the plugin** (once per machine; the repo is public, so any
   GitHub-authenticated machine can install it — no special access needed):
   ```
   /plugin marketplace add msummer/trail-blazer-flow
   /plugin install trail-blazer-flow@trail-blazer-flow
   ```
   (Or skip this entirely and let step 2 do it — see the note there.)
2. **Create the thin per-repo settings.** Copy `templates/repo-settings.json` from this repo to
   the target repo as `.claude/settings.json` (or merge into an existing one). It carries the
   three things a plugin cannot ship: the **permission grants** (subagents can't answer
   permission prompts, so their commands must be pre-allowed), `extraKnownMarketplaces` (which
   registers this marketplace — with `autoUpdate` on, see "Updating") and `enabledPlugins` (so
   the plugin is enabled after the trust dialog). Because the checked-in settings register the
   marketplace, **anyone who clones the repo gets the plugin installed and enabled on their first
   trusted session — they don't need step 1 at all.** Commit it.
3. **Run the `harness-setup` skill** — in a Claude Code session in the repo, say:
   > Run the harness-setup skill: check this repo's harness installation, audit CLAUDE.md
   > against the contract (draft what's missing for my review), and establish the
   > verification baseline.
   It runs the mechanical preflight (`check-harness.sh`), creates the labels, audits/drafts
   `CLAUDE.md`, runs the verification commands on the default branch and persists the **green
   baseline** to `.claude/BASELINE.md` (gitignored — see "The BASELINE.md contract"), and
   reports readiness. Don't skip the baseline: every implementation run compares against it,
   and a repo that is red on its own default branch can't use the harness meaningfully.
4. Recommended: enable branch protection on the default branch (require a PR before merge) —
   the doctor checks and reminds you.

**Updating:** the plugin uses semantic versioning (the `version` field in
`.claude-plugin/plugin.json`). *To publish a release* (author side):

```bash
# 1. bump "version" in .claude-plugin/plugin.json (e.g. 1.1.0 -> 1.2.0)
git commit -am "Release vX.Y.Z: <summary>"
git tag -a vX.Y.Z -m "trail-blazer-flow vX.Y.Z"   # match the version field exactly
git push origin main
git push origin vX.Y.Z
```

That is the whole release process. The `version` field on the default branch is what actually
drives updates; the matching `vX.Y.Z` **annotated tag is an immutable anchor** for
rollback/bisect (and pinning), not the update trigger — so always tag in the same step as the
bump to keep the two from drifting. (`main` is branch-protected: collaborators land changes via
pull request — no required approvals while the project is solo — while the maintainer pushes
directly via admin bypass, which is what keeps this direct-push ritual working. Force-pushes and
branch deletion are blocked for everyone.) *To receive updates* (consumer side): the template
registers the marketplace with `"autoUpdate": true`, so each new version is picked up
automatically at the start of a session (Claude Code refreshes the marketplace and reports what
it updated; run `/reload-plugins` if prompted). To update by hand instead, run
`/plugin marketplace update trail-blazer-flow` then
`/plugin update trail-blazer-flow@trail-blazer-flow`.

**Heads-up for testers — `autoUpdate` is a trust choice.** With `"autoUpdate": true` you pull
each new push to `main` automatically at session start; convenient, but it means taking the
author's latest commit sight-unseen. If you'd rather vet updates first, set
`"autoUpdate": false` in your `.claude/settings.json` and run the two manual commands above once
you've reviewed what changed. The published `vX.Y.Z` tags give you known-good points to compare
against or roll back to.

### Updating an already-onboarded repo (per-repo migration)

An update replaces the plugin's skills/agents/scripts everywhere, but the **project-side
artifacts don't update themselves**: the labels, the permissions in `.claude/settings.json`,
and the baseline all live in your repo. The migration tool is the doctor — after any update,
run:

```bash
check-harness.sh
```

It names exactly what the new version needs that your repo lacks; fix what it flags and you're
migrated.

For **v1.9.0 → v2.0.0**, exactly one thing migrates: a new permission grant,
`"Bash(gh auth status:*)"`. Three skills run `gh auth status` as their first command, so without
it a repo on the default permission mode stalls at the start of every run. Re-copy the
permissions block from `templates/repo-settings.json`, or add that one entry by hand — the doctor
names it either way. No new label, script, or baseline step.

Two behaviour changes worth knowing, both of which *narrow* what the harness does unattended, so
neither can surprise you into a merge you didn't want. The merge pass now treats CI configuration
as governance surface, and treats a repo that reports "no checks configured" as **not** green —
if you run merge autonomy on a repo with no CI, no PR qualifies until your own policy section
explicitly opts a no-CI repo in. Follow-up issues the harness files now carry `no-auto-approve`
(remove the label to release one into planning) and are commented and labelled `no-plan` by
`cleanup-after-merge.sh --fix` if the PR that filed them is closed without merging.

This release adds one further grant your repo must add: `"Bash(gh pr edit:*)"` — the orchestrator
needs it to refresh a PR body it already opened (writing filed follow-up issue numbers into it,
and replacing the verifier status line and mutation-probe line after a CI-fix round). Re-copy the
permissions block from `templates/repo-settings.json`, or add that one entry by hand — the doctor
names it either way. Under merge autonomy, this release also makes the merge floor stricter: it
now additionally requires the PR body's verifier line to match a verifier verdict the orchestrator
archived as an issue comment (see "Verdict provenance" under "Safety model"). Any PR opened before
your repo picks up this version carries no such comment, so it is not eligible for autonomous
merge — it simply waits in the "waits on the human" queue until you merge it by hand.

**v2.2.0 → v2.3.0** adds no grant, label, script, or baseline step — the doctor reports nothing
new to migrate. Three doctor checks got sharper: a `#` comment inside the ratchet policy's fenced
block no longer truncates the section slice; a declared "Post-merge verification" block now gets an
advisory WARN naming the exact `Bash(<command>:*)` entry for any declared command that has no
matching allow entry (a string comparison — nothing declared is ever executed); and an abbreviated
`- commit:` value of 7+ hex characters in `.claude/BASELINE.md` no longer trips the "baseline is
behind" WARN, while a shorter value WARNs as malformed. Under merge autonomy the merge floor is
stricter again: the archived verifier verdict is now keyed to the PR's head branch (a second
`<!-- verifier-verdict-branch: … -->` line in the archive comment), so a PR opened before your repo
picks up this version carries an unkeyed archive and is not eligible for autonomous merge — it
waits for one manual merge, exactly like the v2.2.0 transition above.

**v2.3.0 → v2.4.0** removes a grant rather than adding one: the nine `Bash(git -C * <sub> *)`
allow entries worktree-parallel mode used to depend on are gone from the template, replaced by a
plugin-shipped `PreToolUse` guard hook (`hooks/hooks.json` + `hooks/git-c-guard.sh`) that
auto-updates with the plugin and needs no per-repo file. Re-copy the permissions block from
`templates/repo-settings.json` (or delete the nine entries by hand) to pick this up — the nine
"has a wildcard before the rest of the command" warnings Claude Code 2.1.246+ prints at the start
of every session are the visible cue that your repo is still on the old template. Because the
plugin's marketplace entry ships `"autoUpdate": true`, the plugin itself updates before you next
sync settings in practice, so the guard hook is already active by the time you delete the old
entries — worktree-parallel mode's `git -C` commands stay prompt-free throughout the transition.
`check-harness.sh` now also WARNs when it finds `disableAllHooks: true` in any of the three
settings files (silently disabling the guard hook, and every other hook) and, separately, when
`.claude/settings.json` still carries one of the superseded legacy `-C` allow entries. The
post-merge allow-entry check and the path-qualified interpreter probe now also consult this same
three-file union instead of `.claude/settings.json` alone, so a grant that lives only in
`.claude/settings.local.json` or the user-level settings file no longer produces a spurious "no
matching allow entry" WARN — no consumer action required. The guard also now covers
`git -C <worktree> log` (#155) — the verifier's read-only commit-message evidence call, which
previously hit an unanswerable prompt inside a worktree — and its handler is registered with an
`"if": "Bash(git -C *)"` filter so the hook process is only spawned for `git -C` Bash commands,
which needs Claude Code **2.1.85+** (see "Prerequisites").

## The per-repo settings file (required)

Plugins cannot ship permission rules, so each target repo keeps a thin, checked-in
`.claude/settings.json` — start from `templates/repo-settings.json`. It pre-allows the harness
scripts (bare names — `bin/` is on the PATH), the `gh`/`git` commands the orchestrator runs,
Edit/Write, the build/test runners, and carries the deny-list (no merge, no force-push, no
`reset --hard`). The `gh pr merge` deny is the merge-autonomy off-switch: it ships on, and
lifting it is a human edit reserved for repos that define a CLAUDE.md merge autonomy policy.
`Bash(gh pr edit:*)` lets the orchestrator refresh a PR body it already opened — writing in filed
follow-up issue numbers, and replacing the verifier status line and mutation-probe line with a
fresh verdict's after a CI-fix round; `gh pr comment` is deliberately **not** granted — the
verifier's verdict is archived on the *issue* instead (`Bash(gh issue comment:*)`, already
granted), which is also where the merge pass reads it back with one `gh issue view` call. The same
file also carries the non-permission keys a clone needs to bootstrap
the plugin — `extraKnownMarketplaces` (auto-registering + auto-updating the marketplace) and
`enabledPlugins` — covered in "Installing in a new repo". Four grants exist solely for the
resilience mechanism (see "Resilience: checkpointing, retries, and the dispatch ledger"):
`Bash(sleep:*)` (the retry ladder's backoff waits), `Bash(date:*)` (duration reporting in the
summary table — advisory only, its absence just costs `duration: unknown`),
`Bash(git reset --soft:*)` and `Bash(git merge-base:*)` (collapsing a run's WIP checkpoints into
one clean commit before the PR — `git reset --soft` never touches the working tree, only where
HEAD points; see "Safety model"). Worktree-parallel mode's `git -C <worktree> <subcommand>`
commands (see the `issue-implementer` skill's `references/worktree-mode.md`) are approved by a
plugin-shipped `PreToolUse` hook instead of a permission grant — through v2.3.0 the template
shipped nine `Bash(git -C * <sub> *)` allow entries for this, but a `*` before the subcommand
also matches any option inserted at that position (`-c core.pager=…`, `--exec-path=…`) and
approves it without a prompt, which Claude Code 2.1.246 started warning about at startup, and no
rewrite of the rule closes the gap — there is no "exactly one token" rule syntax. `hooks/`
ships a guard script instead (see "Safety model" for its contract and the fail-safe design).
Separately, the seven bare `git` deny entries above each gained a
`git -C * …` mirror, so a worktree-mode command can't slip past a guard the bare form already
stops — see "Safety model" for why the mirror matters. Two of those seven bare denies
(`branch -D main` and `push origin main`) name the default branch literally, so they guard
nothing on a repo whose default branch isn't `main` (`master`, `trunk`, `develop`, ...);
`check-harness.sh` derives the guarded operations from the template itself, checks them against
this repo's actual default branch, and — when coverage is missing — names the exact bare and
`-C` deny entries to add. The template allows `pnpm`, `npm`,
`yarn`, and `pytest`; if your repo uses a
different toolchain, add it — the doctor warns when it detects a toolchain no settings file's
allow-list covers — e.g.:

```json
"Bash(make:*)", "Bash(cargo:*)", "Bash(go:*)", "Bash(just:*)"
```

That bare-name check is a regex match prefix-anchored at `^Bash(` against the allow-list entries
across all three settings files (the same three-file union named in "The CLAUDE.md contract" item
5 above) — a grant
in `.claude/settings.local.json` or your user-level settings file counts too, not just
`.claude/settings.json` — and doesn't cover a *path-qualified* verification interpreter (e.g.
`api/.venv/bin/python`, as worktree-parallel mode's per-checkout virtualenvs require) — those need
their own literal-path allow entry (`Bash(<repo>/api/.venv/bin/python:*)`) instead of, or in
addition to, the bare `Bash(python:*)` form. When CLAUDE.md's verification scope names such a
path, `check-harness.sh` looks for a matching literal-path grant across all three settings files
and WARNs with the exact entry to add if none exists — the shell resolves an absolute venv path
just fine, but Claude Code's permission match is a literal prefix test, so a bare-name grant can't
produce a false reassurance for a path-qualified interpreter it doesn't actually cover.

`check-harness.sh` reads these files exclusively with `jq`, matching literal entries in the
`permissions.allow`/`permissions.deny` arrays it parses out — never a raw-text search of a whole
file, which could be fooled by a rule merely mentioned in an unrelated string (a comment, an
`env` value) or by a deny-side entry that a whole-file search can't tell apart from an allow-side
one. Every check here — the harness-script sentinel, template drift, the stale-`-C`-allow WARN,
and default-branch guard coverage — stays scoped to `.claude/settings.json` by design: they judge
the shared, checked-in file, not effective permission. Four checks are the exception, because
they need *effective* state across all three files: the toolchain bare-name check above, the
path-qualified interpreter probe, the merge-autonomy verdict (see "The CLAUDE.md contract" item
5), and the post-merge allow-entry check. `settings.local.json` is machine-local (may hold
secrets) — never commit it.

## Safety model

The implementer subagent can edit files and run the build tool, but does **no** git or network —
the orchestrator does all git/GitHub. The verifier subagent writes nothing durable: its mutation
probe edits an already-tracked file inside the tree under review, runs the tests, restores it
with `git restore <file>` (working tree only — never a commit, ref, or push), and re-checks
`git status --porcelain` against its pre-probe output before returning; if the repo doesn't grant
the restore, it skips the probe and says so. Guarantees: branch isolation (work never lands on the
default branch directly), a deny-list (no merge by default, no force-push, no `reset --hard`,
no `rm -rf`), independent re-verification + staged-file reconciliation before every commit, and
**human review of every PR before merge unless the repo has double-opted-in to merge autonomy**
(CLAUDE.md policy + lifted deny — see "The CLAUDE.md contract"). The deny-list is best-effort pattern matching; branch protection +
PR review are the real backstops, and — because two of the seven bare denies name the default
branch literally — `check-harness.sh` reports per-repo whether those two entries (and their `-C`
mirrors) actually cover this repo's default branch. The pre-merge guarantee is "nothing pushed, no PR exists" —
not "nothing committed": WIP checkpoint commits accumulate locally during a run (see
"Resilience"), but never leave the machine before the verifier passes. `git reset --soft`, added
for collapsing those checkpoints, only moves what a branch points at — it never touches the
working tree or deletes any file, so it carries none of the risk `reset --hard` does; the
`Bash(git reset --hard:*)` deny is unchanged and, like every deny, takes precedence over any
allow entry. Bash rules are prefix-matched, and a `git -C <path> …` command does **not** match a
bare-subcommand rule — allow or deny — so a `-C` command needs its own coverage on each side of
the permission model, and the two sides use different mechanisms. On the deny side, every bare
git deny — not only the ones worktree mode itself issues — gets a no-space trailing-wildcard `-C`
mirror, e.g. `Bash(git -C * push --force*)` and `Bash(git -C * clean*)` (see "The per-repo
settings file"): an unmirrored deny would be a real bypass (e.g. `git -C <worktree> push --force`
slipping past a guard that stops the bare form). On the allow side, a permission *rule* cannot do
this safely at all: the only syntax available is an exact match, a trailing `:*`, or a `*` that
matches any text including spaces, so `Bash(git -C * push *)` — the form the template shipped
through v2.3.0 — also approves `git -C <worktree> -c core.sshCommand=… push …` (the injected
option lands inside the first `*`), and there is no "exactly one token" rule syntax to close that
gap; Claude Code 2.1.246 added a startup warning naming exactly this shape. The plugin ships
`hooks/git-c-guard.sh` (a `PreToolUse` hook, registered in `hooks/hooks.json`) to do the job
instead: it sees the whole command string and can require exactly one `-C` token, one path token
matching the `<repo-dirname>-wt-<number>` worktree shape, and then one of the ten covered
subcommands (`status`, `add`, `commit`, `push`, `restore`, `diff`, `rev-parse`, `merge-base`,
`reset --soft`, `log`), with nothing else in between — an injected `-c`/`--exec-path`, a second
`-C`, an unrecognized path or subcommand, a non-conforming composite part, or any command
substitution all get **no opinion** (empty stdout, exit 0), so the normal permission flow
applies. A handler `"if": "Bash(git -C *)"` gate on the hook's registration (Claude Code 2.1.85+)
restricts when the hook process is even spawned to Bash commands whose constituents — matched
after composite splitting and after any leading `VAR=value` assignment is stripped — match that
pattern; it can only *reduce* spawns, never widen approval, since the hook itself is the only
thing that ever emits `allow`; a command the filter doesn't match simply gets no hook opinion and
follows the normal permission flow, and per Claude Code's own docs the filter fails open (spawns
the hook anyway) on `$()`/backtick, `$VAR`, or an otherwise-unparseable command — which the guard
then rejects on its own terms, same as if `if` weren't there at all. Hook decisions
never override a deny: Claude Code evaluates deny and ask rules regardless of what a `PreToolUse`
hook returns, so the `-C` deny mirrors above keep winning over the hook's allow, and the guard
itself never emits anything but `allow` or nothing — never `deny`/`ask` — so a bug in it degrades
to a prompt, not a bypass. It also never invokes `git` (or anything else) against the untrusted
`-C` path it is validating, which matters because — per the same docs — a plain `cd` into a
different directory prompts before the `git` command that follows it, since running `git` in a
new directory can execute that directory's hooks; `cd`-with-`git` is therefore not a simpler
escape hatch for either the template or the guard. Hooks shipped by a plugin fire inside
subagents too (carrying `agent_id`/`agent_type` alongside the usual fields), which matters here
because the implementer and verifier subagents issue most of the `-C` commands, not just the
orchestrator. The guard fails open in every direction: no `jq` on `PATH`, the plugin disabled or
not yet updated, `disableAllHooks: true` in any of the three settings files, or a headless
`--bare` run all leave a `-C` call unapproved by the hook — a prompt in default mode (or a
recorded denial headless), never a silent bypass. Below the `if` gate's 2.1.85 floor (see
"Prerequisites"), Claude Code predates support for the handler's `if` field, and its handling
there is unverified: either it runs the hook on every Bash call as before — prior behaviour,
with `-C` calls still approved by the guard — or it rejects the handler and the guard never
fires, degrading to the same prompt (or recorded denial headless) as above; either way, never a
silent bypass. `check-harness.sh` WARNs when it finds
`disableAllHooks: true`, and separately when `.claude/settings.json` still carries a legacy
`Bash(git -C * …)` allow entry the hook now supersedes. A heredoc body
(e.g. `reconcile-ledger.sh - <<'LEDGER'`, used by `issue-cycle`) is not split into
separately-matched subcommands, so it stays covered by its single prefix grant. A third fact from
the same probe series: no allow rule can approve a Bash command containing command substitution
— `$(...)` or backticks, which behave identically — even when every constituent command is
individually granted; such a command instead falls through to the session's permission mode
(prompt on manual/default, a recorded denial headless, silent auto-approval under `auto`), while
a deny rule *does* match inside a substitution body and blocks the whole composite. That's why
the WIP-collapse step ("Resilience") runs as two plain `git` calls — a `merge-base` lookup
followed by `reset --soft` on its literal SHA — rather than one command with the SHA substituted
in, and it is also why the guard hook rejects any `$(...)`/backtick span outright rather than
trying to reason about what it might expand to. Composites joined by `&&` or `|` behave the
opposite way to substitution, and identically to each other: they **are** statically split, and
each constituent is matched on its own, so such a command is approved exactly when every
constituent that requires approval has its own matching allow entry. One part's grant does not
cover the whole (`Bash(git add:*)` alone does not approve `git add -A && git commit …`, and the
reverse fails too), and a single rule written across the operator — `Bash(git add -A && git
commit:*)` — matches nothing at all. Not every constituent needs an entry: some commands are
approved without one (`cd`, `tr` and `head` were each confirmed), which is why the three
`… | tr -d '\r'` pipelines the harness issues need no `tr` grant; the bare-form WIP checkpoint
(`git add -A && git commit …`) is covered because both of its constituents are already granted, while its
`-C` counterpart is covered by the guard hook validating `git -C <worktree> add -A` and `git -C
<worktree> commit …` as two conforming segments of the same `&&`-joined command (the
`checkpoint-composite` case in `dev/hook-tests.sh` pins this, including the double-quoted `#`,
`(`, `)`, and `:` a WIP commit message carries). A path-qualified invocation matches no bare-name
rule — allow or deny — so such a command needs its own grant on the literal path prefix (this is
why a worktree's venv-interpreter verification command needs a dedicated entry; see the
issue-implementer skill's worktree-parallel reference). Every command the harness issues across
either operator is therefore approved — by the template's allow rules for the bare-form and
path-qualified-grant cases, and by the guard hook for the worktree `-C` forms — exactly as the
plugin and template ship. As with substitution, a deny matching any one constituent blocks the
entire composite.

All of the bare-form facts above (prefix matching, the substitution gap, and the `&&`/`|`
composite split) were verified by live probe against Claude Code 2.1.220 (#41, #39, #55, #79,
#80) and are unaffected by the `-C` guard hook. The hook's own allow/no-opinion boundary — the
ten `-C` forms, the injected-option and malformed-input rejections, the composite checkpoint, and
the never-execute-`git` guarantee — is pinned by fixture in `dev/hook-tests.sh`, and was also
confirmed live against Claude Code **2.1.246** on macOS (2026-08-26): a throwaway consumer repo
with a real sibling worktree, the template's `permissions` block copied verbatim (49 allows, the
seven `-C` deny mirrors, no `-C` allows), run both headless (`-p`, model-driven) and through a
real interactive session. Two controls proved the method: with the template's permissions alone
and no plugin loaded, the same `git -C <worktree> status --porcelain` command is **denied**, so
every "ran" below is attributable to the hook, not the permissions block alone; and the startup
wildcard warning is independently observable by this method — a single `Bash(git -C * status *)`
allow prints exactly one such warning line on a fresh start in an already-trusted workspace
(never in `-p` mode, and never on the run where the trust dialog is first accepted).

| row | tested against | command / observation | expected | observed |
|---|---|---|---|---|
| (a) / (a-rel) | the hook as shipped before this issue | `git -C <worktree> status --porcelain` (absolute and relative-sibling forms) | runs, no prompt | **ran**, `?? probe-anchor.txt`, no denial |
| (b) | as shipped | `git -C <worktree> -c core.pager=cat status` | prompts | **"This command requires approval"** |
| (c) | as shipped | `git -C <worktree> push --force` | blocked by the deny mirror | **"Permission to use Bash with command … has been denied."** — deny-rule wording, distinct from (b)'s prompt wording: the deny mirror wins over the hook's allow |
| (d) | as shipped | `git -C <worktree> add -A && git -C <worktree> commit -m "wip: checkpoint verifier (#12)"` | runs, no prompt | **ran**, one commit; both `&&` constituents validated as conforming segments |
| (g-pre) | as shipped (no `log`) | `git -C <worktree> log main..HEAD --format=%s` | the #154 gap | **"This command requires approval"** — gap confirmed live |
| (g) | this issue's state (`log` added) | same `log` command | runs | **ran** |
| (a-if) / (d-if) | this issue's state (`if` gate added) | rows (a) and (d) again | run, no prompt | **ran** — the `if` gate matched each constituent of the (d) composite too |
| (b-if) | this issue's state | row (b) again | prompts | **"This command requires approval"** — the `if` gate loosens nothing |
| spawn trace | no `if` | `echo hi` | hook spawns | **1 spawn** |
| spawn trace | with `if` | `echo hi` | no spawn | **0 spawns** |
| spawn trace | with `if` | `git -C <worktree> status --porcelain` | spawns and runs | **1 spawn**, ran |
| (e) | as shipped | interactive session start, template block only | zero wildcard warnings | **0** (a positive control on the same path printed 1) |
| (f) | this issue's state | interactive session start with the `if` gate on the handler | zero wildcard warnings; hook still fires | **0** warnings; firing shown by (a-if)/(d-if)/the spawn trace |

The seven `Bash(git -C * …)` deny mirrors were present throughout and produced no warning in any
row above — Claude Code 2.1.246's startup scan is allow-only. The one item this probe left
unconfirmed is the Windows/Git-Bash spot-check of row (a) — see "Prerequisites" and the Windows
section below.

**Verdict provenance.** The kickback loop is enforced the same way as the rest of this section:
the orchestrator never edits a source, test, or doc file to resolve a verifier finding or a red
CI run itself — its only edits anywhere in this pipeline are harness bookkeeping
(`.claude/LESSONS.md`, the PR body, issue comments) — and the merge pass's hard floor requires
three artifacts to agree before any autonomous merge: the PR body carries the verifier's own
closing status line (`<!-- harness-status: stage=verifier issue=<n> outcome=pass retries=<k>
-->`) verbatim, checked mechanically (`gh pr view … --jq 'contains(...)'`); the dispatch ledger's
`verifier` row for that issue reads `pass`; and the verifier's verdict is separately archived,
also verbatim, as an issue comment opening with `<!-- verifier-verdict -->` — posted by the
orchestrator after every verifier pass, including a CI-fix re-verification — whose second line
keys the archive to this PR's head branch (`<!-- verifier-verdict-branch: claude/<n>-<slug>
-->`). The merge pass matches the newest verdict archived **for that branch**, not the newest on
the issue, so a deliberately multi-PR issue split across several `claude/<n>-*` branches has each
slice match its own verdict instead of an earlier slice losing to whichever slice verified last.
That keyed comment's own closing status line is what the PR body's line is checked against
literally before the merge pass proceeds. A prose "verifier verdict: pass" without the PR-body
line, or a PR body with no archived comment keyed to its head branch, does not qualify —
including a PR opened before this keying existed, whose archive carries no key line and which
therefore waits for a human merge rather than being retrofitted. Honest limit: the check proves
a matching line is present in the PR body, agrees with the ledger, and agrees with a comment
independently timestamped on the issue —
not that a human witnessed the dispatch. All three artifacts are still orchestrator-written, so a
misreporting orchestrator can still fabricate them; the gain is that doing so now requires two
consistent, durably visible artifacts instead of one, raising the cost of asserting a verification
event that didn't happen rather than eliminating the possibility.

**The body-hash grant pattern is a tripwire, not a control** (see "The CLAUDE.md contract" item
8). It exists only as a documented convention a consuming repo may adopt in its own CLAUDE.md —
this harness never computes or verifies a body hash itself. Even where a repo adopts it, the
harness and the human share one `gh` identity, so anyone able to post the `grant: <sha256>`
comment can also edit the issue body and re-post a matching hash; a mismatch means "grant void,
standard flow" only because the repo's own instructions say so, not because the harness enforces
anything. Separately, and unconditionally: the harness never applies or removes a scoped-autonomy
grant label itself, on any issue — `check-harness.sh` and `check-decision-record.sh` only report
whether the label exists and whether the declared record is present.

Two honest caveats. First, the implementer's "no git" rule is enforced by prompt, not by
permissions: the settings allow-list must permit git for the orchestrator, and permission
grants are session-wide, so a misbehaving subagent *could* run git — the staged-file
reconciliation and branch isolation are what bound the damage. Second, plan auto-approval and
merge autonomy (each opt-in via `CLAUDE.md` — see "The CLAUDE.md contract" items 4–5)
deliberately trade human gates for throughput on low-risk work. Their hard floors are not
configurable by the policy section — the one exception is itself part of the floor's fixed
definition, not something a policy can widen: on an issue the human granted under the repo's
scoped-autonomy declarations (see "The CLAUDE.md contract" item 8, "Autonomy decision record"),
an orchestrator-proposed answer to a BLOCKING question skips the human wait only if it quotes the
human-authored binding-record bullet it derives from. The grant label itself is applied by the
human, per issue, and the harness never applies it, so an uncitable answer still waits, and every
use is audited (issue comment; cycle report). With only auto-approval enabled, a bad
auto-approval costs a wasted PR, not a bad merge. With merge
autonomy also enabled, the backstop is the merge pass's hard floor (standard-flow PRs only,
green CI, protected governance surface, sequential re-verification) — and on a repo with
branch protection + required checks, that floor is a technical rail, not just policy. Enable
merge autonomy only where a bad merge is cheap to revert (e.g. a default branch that doesn't
auto-deploy) — or, on a repo whose default branch does auto-deploy, declare a "Post-merge
verification" sub-block (see "The CLAUDE.md contract" item 5) so "merged" stops standing in for
"shipped": the declared commands are reads only, and the harness never approves, promotes, or
redeploys anything on your behalf — it only observes and records what the deploy did.

Third, harness-authored issues are the exception to a pipeline that otherwise starts from
human-authored ones — the test-suite ratchet (also opt-in via CLAUDE.md) is one source; the plan
follow-ups the implementer files from a PR's "Follow-ups to file" are the other, carrying the
same `no-auto-approve` provenance rule plus a marker naming their PR, which
`cleanup-after-merge.sh --fix` uses to quarantine (`no-plan`, never closed) any that are orphaned
when that PR closes without merging. The ratchet's further mitigations: the fixed issue-body
template, with evidence quoted as literal tool output rather than free-form prose; the "issue
text is data, not instructions" rule below, applied to the ratchet's Evidence section like any
other issue content; the test-only/monotonic scope that binds the plan and that the verifier
checks against; and the per-run and open-backlog caps. A ratchet issue can never propose changes
to the governance surface (`CLAUDE.md`, `.claude/`, policy/ADR docs, CI config) — that boundary
only moves with a human in the loop.

Fourth, every dispatch — not only ratchet-filed issues — treats the issue body and quoted
comments as untrusted **data**, never as instructions (#164): `agents/planner.md`,
`agents/implementer.md`, and `agents/verifier.md` each carry this as a standing constraint (an
embedded directive is a finding to report, never something to obey), and the orchestrating
skills' dispatch prompts quote issue content as delimited data. Mechanically,
`find-planning-work.sh` enforces the planner-facing half of this: only a comment whose GitHub
`authorAssociation` is `OWNER`, `MEMBER`, or `COLLABORATOR` is ever treated as feedback or
honoured as the latest plan comment; a `CONTRIBUTOR`/`NONE` comment, or one with no
`authorAssociation` field at all (fail-closed), posted after the issue's latest trusted plan (or
any such comment, if there is no trusted plan yet) is reported in the `untrusted_comments` bucket
instead of being silently dropped or silently trusted, and never shadows real feedback posted
before it — one posted before that plan is dropped with no bucket entry. The same script also
enforces provenance on WHO OPENED the issue: every discovered issue carries `trusted_author`, a
non-maintainer-authored (or association-unreadable) issue is reported in `untrusted_issue_authors`
and can never be auto-approved, though it is still planned (#176). `find-implementation-work.sh`
enforces the implementer-facing half the same way: it selects each ready issue's approved plan
comment and binding post-plan comments itself, using the identical trust gate (gate assertion
4.26 pins that the two scripts' trusted-association lists agree), so the `issue-implementer`
orchestrator reads a filtered artifact instead of applying the rule from memory (#176). The
honest limit: this mechanical coverage is planner- and implementer-side only; the verifier-side
half of the untrusted-data rule is still prompt-enforced, not mechanically checked.

## Distribution

This repo **is the plugin and its own marketplace** (`.claude-plugin/plugin.json` +
`marketplace.json`): skills + agents versioned together, installable per-project, with the
agent model pins (`planner: claude-opus-5`, `implementer: claude-sonnet-5`, `verifier: claude-opus-5`) travelling with
the plugin. Install/update flow is in "Installing in a new repo".

Project-side files that never live in this repo: `LESSONS.md`, `BASELINE.md`,
`settings.local.json`, and the label setup (per-repo, via `setup-labels.sh`). This repo does
carry its own root `CLAUDE.md` — see "Working on the harness itself" below — but that file
governs work *on* the harness itself, not on a project that consumes it; a consumer repo's own
`CLAUDE.md` (conventions, verification commands) is a separate, project-owned file that never
lives here. Nothing in the skills/agents should reference a specific project — if you find such
a reference, that content belongs in the target repo's `CLAUDE.md` or `LESSONS.md` instead.

## Working on the harness itself

This repo has its own root `CLAUDE.md` — separate from, and with a different audience than, the
`CLAUDE.md` contract this harness expects of a *consumer* repo (see "The CLAUDE.md contract"
above). It governs changes to this repo's own agents, skills, scripts, and docs. The gate is one
command, run from the repo root:

```bash
bash dev/selfcheck.sh
```

It prints a `PASS`/`FAIL` line per assertion and a `== summary: N pass, M fail ==` footer — run
it to see exactly what it checks. There is no test suite and no build step: this repo is
Markdown instruction files, Bash scripts, and JSON manifests. The gate and its five negative-test
harnesses (`dev/selfcheck-tests.sh`, `dev/doctor-tests.sh`, `dev/hook-tests.sh`,
`dev/cleanup-tests.sh`, `dev/planning-tests.sh`) all run in CI on every pull request — see this
repo's `CLAUDE.md` "Verification" section for the exact commands and jobs.

This repo deliberately does **not** aim to pass `bin/check-harness.sh` — that script is the
*consumer* doctor. Onboarding it here would mean checking in a `.claude/settings.json` that
registers this repo's own published marketplace (with `autoUpdate: true`) and enables a cached
copy of itself over the working tree being edited.

## Known future improvements

- **Parallel-mode ergonomics:** worktree-parallel is gated on manually comparing Affected areas;
  a small script that diffs the file lists of two plans could make eligibility mechanical. (The
  final batching call should stay with the orchestrator — wave sequencing sometimes depends on
  semantic ordering a file-diff can't see.)

*(Settled 2026-06: verifier calibration — across 10+ live runs the loop neither rubber-stamped
nor churned; it caught a real resource leak, a factual error in a docs change that originated in
the planner's Verified facts, and proved new tests non-tautological by mutation. Verdict semantics
were tightened to "any blocker/major finding ⇒ fail". Worktree-parallel validated at 2- and
4-wide.)*

## Prerequisites

- `gh` (GitHub CLI), authenticated.
- `jq`.
- A Claude Code subscription (Pro/Max). Runs entirely locally.
- Claude Code **2.1.85 or newer** — the plugin's `git -C` guard hook is registered with a handler
  `if` filter, added in 2.1.85 (composite `&&` matching fixed in 2.1.89; a `$()`/backtick
  false-fire fixed in 2.1.243). Probed against 2.1.246 on macOS — see "Safety model".

**On Windows:** the automation layer is Bash (`bin/*.sh`) plus `gh`/`jq`, so run Claude Code
under **Git Bash or WSL** — there is no native cmd/PowerShell path. Install `gh` and `jq` so
they're on the *Bash* PATH you launch Claude Code from (e.g. `winget install GitHub.cli
jqlang.jq`, or scoop/choco). This repo ships a `.gitattributes` that pins `*.sh` to LF so Git
for Windows' line-ending conversion can't corrupt the scripts after install. One thing to
confirm on first run: the harness invokes its scripts by bare name (e.g. `check-harness.sh`),
which assumes Claude Code puts the plugin's `bin/` on the Bash PATH — if a script "isn't found",
that's the cause. macOS and Linux need nothing beyond the three prerequisites above.

Windows specifics worth knowing:

- **WSL is its own machine.** `gh` inside WSL has its own credential store — run `gh auth
  login` there even if the Windows-side `gh` is already authenticated. And keep repos in the
  WSL filesystem (`~/...`), not under `/mnt/c/...`: NTFS-mounted repos are dramatically slower
  and reintroduce the exec-bit and line-ending quirks the harness otherwise avoids.
- **Prefer forward-slash paths** in anything that reaches a Bash command — worktree paths in
  parallel mode, `--body-file` temp files. Git Bash accepts `C:/Users/...` and `/c/Users/...`;
  backslash paths get mangled by quoting. (`mktemp` works in Git Bash and yields safe temp
  paths.) Python venvs on Windows put the interpreter at `.venv/Scripts/python.exe`, not
  `.venv/bin/python` — the worktree-parallel instructions account for this.
- **The doctor's exec-bit check is informational on Windows.** NTFS has no POSIX exec bit; Git
  Bash runs the scripts via their shebang, so the check reports that and moves on. The
  harness's `gh`-output parsing also strips stray `\r` defensively, in case a CRLF-translating
  layer sits between `gh` and Bash.
- **The `git -C` guard hook's `${CLAUDE_PLUGIN_ROOT}` path.** `hooks/hooks.json` invokes the
  guard as `bash "${CLAUDE_PLUGIN_ROOT}/hooks/git-c-guard.sh"`; if Claude Code ever exports that
  variable in backslash form on Windows, the quoted path could fail to resolve under Git Bash and
  the hook simply never runs for that session — fail-safe (worktree-mode `git -C` commands then
  prompt, same as if the plugin were disabled), but a Windows spot-check of the hook actually
  firing is worth doing before relying on unattended worktree-parallel mode there (the probe
  table under "Safety model" covers macOS only).

### Windows: first-run smoke test

Before relying on the harness on Windows, run this 30-second check from **Git Bash or WSL** (in
any git repo, after installing the plugin). It verifies the two Windows-specific risks at once —
the line-ending fix and the `bin/`-on-PATH assumption.

1. Confirm the toolchain is visible on the Bash PATH:
   ```bash
   bash --version && gh --version && jq --version && gh auth status
   ```
   If any of these is "command not found", install it / authenticate before continuing.
2. Run the harness doctor by **bare name** (this is the real test — it exercises both the PATH
   assumption and the scripts' line endings):
   ```bash
   check-harness.sh
   ```
   Or just tell Claude Code: *"run the harness-setup skill"*.

**Reading the result:**

- **Prints a `== harness doctor ==` PASS/WARN/FAIL table** → ✅ both risks are clear: `bin/` is on
  the Bash PATH and the LF fix held. The remaining WARN/FAIL items are normal setup, not Windows
  problems — proceed as on any platform.
- **`check-harness.sh: command not found`** → Claude Code did not put the plugin's `bin/` on the
  Bash PATH. As a fallback, invoke scripts via the plugin root, e.g.
  `bash "$CLAUDE_PLUGIN_ROOT/bin/check-harness.sh"`. Note this won't match the bare-name
  permission entries (`Bash(check-harness.sh:*)`), so you'll see permission prompts — please
  [report it](https://github.com/msummer/trail-blazer-flow/issues) so the fallback can be made
  first-class.
- **`bad interpreter` / `$'\r': command not found`** → a CRLF copy slipped through (shouldn't
  happen with the shipped `.gitattributes`). Re-clone/reinstall with `core.autocrlf=false`, or
  run `git config --global core.autocrlf input`, then reinstall the plugin.

## License

[MIT](LICENSE) © 2026 Mark Summer. You're free to use, modify, and redistribute it — please keep
the copyright notice. Provided as-is, without warranty; see the `LICENSE` file for the full text.
