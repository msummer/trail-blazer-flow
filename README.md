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
Three things always live on the project side, never here: `LESSONS.md` (seeded by the doctor
script), a thin `.claude/settings.json` (permission grants — plugins cannot ship permissions;
template provided), and `settings.local.json` (machine-local secrets/overrides — never commit
or share).

## What's in here

```
.
├── .claude-plugin/
│   ├── plugin.json               # plugin manifest (semver version field — bump it to publish an update)
│   └── marketplace.json          # this repo doubles as its own marketplace
├── agents/
│   ├── planner.md                # read-only planning subagent (Opus)
│   ├── implementer.md            # code-writing subagent (Sonnet); no git/network
│   └── verifier.md               # read-only plan-conformance reviewer (Opus); fresh context
├── skills/
│   ├── project-kickoff/SKILL.md  # greenfield on-ramp: interview → brief + CLAUDE.md + repo + backlog
│   ├── harness-setup/SKILL.md    # one-time repo onboarding: doctor + CLAUDE.md audit + baseline
│   ├── issue-planner/SKILL.md    # orchestrates planning (+ proposed-answers step)
│   └── issue-implementer/SKILL.md # orchestrates implementation → verification → PR
├── bin/                          # on the Bash PATH when the plugin is enabled
│   ├── check-harness.sh           # mechanical preflight ("doctor"); safe to re-run any time
│   ├── find-planning-work.sh
│   ├── setup-labels.sh            # creates the workflow labels (run once per repo)
│   ├── find-implementation-work.sh
│   └── cleanup-after-merge.sh     # post-merge sync + branch/label hygiene
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
| **planner** subagent | Opus | codebase research and design; one dispatch per issue, read-only |
| **implementer** subagent | Sonnet | execution of a fully-resolved plan; cheap enough to run often (and in parallel) |
| **verifier** subagent | Opus | adversarial plan-conformance review of the diff with fresh context — the generator/critic split; judgment-heavy, so it gets the stronger model |

Two consequences are baked into the skills:
1. **Ambiguity is resolved top-down, before execution.** Plans classify questions
   BLOCKING/ADVISORY; the orchestrator proposes answers; the implementer receives only
   `RESOLVED:` decisions — it should never exercise design judgment.
2. **Research flows down as "Verified facts".** The planner writes down every codebase fact it
   confirmed (exact names, signatures, fixture contracts, ordering constraints) so the smaller
   implementer model executes without re-deriving — the single best defence against
   plausible-but-wrong code.

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
1. Finds issues needing an **initial plan** (no `plan-*` label) or a **revision**
   (`plan-proposed` with comments after the latest plan), via `find-planning-work.sh`.
2. Dispatches the read-only `planner` subagent per issue (parallel dispatches OK — each is
   scoped to one issue). Prompts include relevant `LESSONS.md` entries and any orchestrator
   context the issue lacks (recently merged PRs, corrected measurements).
3. Posts each plan as an issue comment tagged `<!-- planner-plan -->`, labels `plan-proposed`.
4. Summarises: open questions split BLOCKING/ADVISORY, **overlapping plans** (same files → merge
   conflicts), and **stale plans** (pending plans whose affected files changed under them since
   posting).
5. **Offers proposed answers** to open questions — drafted by the orchestrator, grounded in
   code/measurements, posted as a normal comment for human review. The next planner run folds
   them into a revision.

The plan template (see `agents/planner.md`) includes: Summary, Estimated size (S/M/L), Affected
areas, Data/schema impact, Implementation steps, Testing approach, Risks, **Verified facts**,
**Open questions (BLOCKING/ADVISORY)**, **Follow-ups to file**, Out of scope.

### Approval (human)

Comment on the issue to request changes (comment-driven, no label needed). Add `plan-approved`
to accept. **Approving a plan whose open questions are all ADVISORY accepts the stated
defaults** — no extra revision round; the orchestrator passes the defaults to the implementer as
resolved decisions. Plans with unanswered BLOCKING questions shouldn't be approved.

### Implementation ("implement the approved issues" / "implement issue 14")

The `issue-implementer` skill, for each `plan-approved` issue (sequential by default):
1. Pre-flight: clean tree (hard stop if dirty), fresh default branch, `claude/<n>-<slug>` branch.
2. Dispatches the `implementer` subagent with: issue + full plan (incl. Verified facts) +
   **resolved answers to every open question** + `LESSONS.md` entries. Missing a BLOCKING answer
   → don't dispatch; ask the human.
3. On completion: **independently re-runs the verification commands** (the mechanical gate — the
   subagent may be wrong).
4. **Dispatches the `verifier` subagent** (the semantic gate): fresh-context, read-only review of
   the diff against the plan's steps, the issue's acceptance criteria, test quality, scope, and
   declared constraints. **Verifier fail → kickback**: the implementer is re-dispatched with the
   findings ("fix ONLY these"), then re-checked — **max 2 kickbacks**, then `impl-blocked` with
   the findings. All of this happens *before* anything is committed, so every PR the human sees
   is verifier-clean.
5. On verifier pass: stages everything, **reconciles the staged list against the report's "Files
   changed"** (unexplained files = blocker, not a commit), commits, pushes, opens the PR
   (`Closes #n`, verification results, verifier notes, schema notes), labels `pr-open`.
6. **Files the plan's "Follow-ups to file"** as new issues, referencing the PR.
7. **Watches CI** (`gh pr checks --watch`). Red CI: no mid-queue fixes — note it on the issue,
   let the human decide. If the failure was a project gotcha, **append it to `LESSONS.md`**.
8. Never merges. Blockers → local `wip:` branch + `impl-blocked` label + explanatory comment.

**Worktree-parallel mode:** when 2+ approved plans have pairwise **disjoint Affected areas**
(production + test files), the orchestrator may create one git worktree per issue and dispatch
the implementers concurrently — each pipeline (mechanical checks → verifier → commit → PR) then
completes per-worktree, with the orchestrator's own git/gh work staying sequential. Ignored
files (venvs, `node_modules`) don't exist in fresh worktrees: verification runs the main
checkout's tool binaries against the worktree, and UI-heavy issues that need per-tree installs
fall back to sequential. Any overlap or doubt → sequential.

### After the human merges

```bash
cleanup-after-merge.sh
```
Syncs the default branch, deletes local `claude/*` branches whose PRs merged, and reports label
hygiene (issues still `pr-open` after a merge; stale `pr-open` from unmerged-closed PRs). Then
re-run the verification suite once on merged main — two green PRs can still compose badly.

## Greenfield walkthrough: from idea to first feature

This is the end-to-end story of starting a project on the harness — exactly what you say to the
orchestrator (Claude Code running in the project directory) at each stage, and what it does in
response. Lines in **quotes** are what *you* type or say (dictation works fine); everything else
is the harness acting. Approvals and merges are always yours.

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

The `issue-implementer` skill branches off the default branch, dispatches the `implementer`
subagent to build the skeleton, **independently re-runs the verification commands**, then runs
the `verifier` subagent against the plan — all before committing. It opens a PR (`Closes #1`) with
the verification results. Review the PR and **merge it** on GitHub. After merging:

```bash
cleanup-after-merge.sh
```

Now the repo has buildable code and a passing verification suite for the first time.

### Stage 3 — Record the baseline with harness-setup

> **"Run harness-setup: audit the CLAUDE.md against the real code now that the skeleton is
> merged, and record the green verification baseline."**

The `harness-setup` skill runs the doctor, reviews the now-real `CLAUDE.md` against the actual
scaffold (the verification commands kickoff drafted are no longer aspirational — they exist and
pass), runs them to capture the **green baseline numbers**, and reports the repo **ready**. From
here every implementation run compares against this baseline.

### Stage 4 — Build the rest of the backlog

From now on it's the steady-state loop, as many times as you like:

> **"Plan the open issues."** → review the plans on GitHub → approve the ones you want
> (`plan-approved`) → **"Implement the approved issues."** → review and merge each PR →
> `cleanup-after-merge.sh`.

That's the whole lifecycle: kickoff blazed the trail (repo, conventions, backlog, skeleton), and
the planner → implementer → verifier loop walks it for every feature after.

## Label lifecycle

*(no label)* → `plan-proposed` → *(human adds)* `plan-approved` → `pr-open`, with `impl-blocked`
for issues needing human input and `no-plan` to opt an issue out of planning entirely (tracking/
discussion/question issues). Humans gate twice: plan approval and PR merge.

## The CLAUDE.md contract (required)

These skills assume the repo has a **`CLAUDE.md`** documenting the project-specifics the generic
subagents need:

1. **Conventions & architecture** — stack, code style, patterns, security/data rules.
2. **Verification commands** — the checks that define "done" (typecheck/lint/tests/build or the
   project's equivalent), ideally under a clearly labelled "Verification" section.
3. **Setup command** (optional) — how to install dependencies.

The subagents read `CLAUDE.md` at the start of every task. A thin `CLAUDE.md` leaves them
guessing — it is the real input that makes the harness work well in a given repo.

## The LESSONS.md contract (project-owned)

`.claude/LESSONS.md` holds project-specific traps — CI quirks, fixture contracts, naming
conventions — that subagents repeatedly trip over. The skills inject relevant entries into every
subagent prompt and append new entries when a failure traces to a gotcha. **The file belongs to
the project, not this toolset**: each project keeps its own `LESSONS.md` (the doctor script
seeds an empty one on install). Format: 1–3 lines per entry, dated, written as an instruction
to a future agent.

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
   `CLAUDE.md`, runs the verification commands on the default branch to record a **green
   baseline**, and reports readiness. Don't skip the baseline: every implementation run
   compares against it, and a repo that is red on its own default branch can't use the
   harness meaningfully.
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

## The per-repo settings file (required)

Plugins cannot ship permission rules, so each target repo keeps a thin, checked-in
`.claude/settings.json` — start from `templates/repo-settings.json`. It pre-allows the harness
scripts (bare names — `bin/` is on the PATH), the `gh`/`git` commands the orchestrator runs,
Edit/Write, the build/test runners, and carries the deny-list (no merge, no force-push, no
`reset --hard`). The same file also carries the non-permission keys a clone needs to bootstrap
the plugin — `extraKnownMarketplaces` (auto-registering + auto-updating the marketplace) and
`enabledPlugins` — covered in "Installing in a new repo". The template allows `pnpm`, `npm`,
`yarn`, and `pytest`; if your repo uses a
different toolchain, add it — the doctor warns when it detects a toolchain the list doesn't
cover — e.g.:

```json
"Bash(make:*)", "Bash(cargo:*)", "Bash(go:*)", "Bash(just:*)"
```

`settings.local.json` is machine-local (may hold secrets) — never commit it.

## Safety model

The implementer subagent can edit files and run the build tool, but does **no** git or network —
the orchestrator does all git/GitHub. Guarantees: branch isolation (work never lands on the
default branch directly), a deny-list (no merge, no force-push, no `reset --hard`, no `rm -rf`),
independent re-verification + staged-file reconciliation before every commit, and **human review
of every PR before merge**. The deny-list is best-effort pattern matching; branch protection +
PR review are the real backstops.

## Distribution

This repo **is the plugin and its own marketplace** (`.claude-plugin/plugin.json` +
`marketplace.json`): skills + agents versioned together, installable per-project, with the
agent model pins (`planner: opus`, `implementer: sonnet`, `verifier: opus`) travelling with
the plugin. Install/update flow is in "Installing in a new repo".

Project-side files that never live in this repo: `CLAUDE.md`, `LESSONS.md`,
`settings.local.json`, and the label setup (per-repo, via `setup-labels.sh`). Nothing in the
skills/agents should reference a specific project — if you find such a reference, that content
belongs in the target repo's `CLAUDE.md` or `LESSONS.md` instead.

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

## License

[MIT](LICENSE) © 2026 Mark Summer. You're free to use, modify, and redistribute it — please keep
the copyright notice. Provided as-is, without warranty; see the `LICENSE` file for the full text.
