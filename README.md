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
├── .claude-plugin/
│   ├── plugin.json               # plugin manifest (semver version field — bump it to publish an update)
│   └── marketplace.json          # this repo doubles as its own marketplace
├── agents/
│   ├── planner.md                # read-only planning subagent (Opus 5)
│   ├── implementer.md            # code-writing subagent (Sonnet 5); no git/network
│   └── verifier.md               # read-only plan-conformance reviewer (Opus 5); fresh context
├── skills/
│   ├── project-kickoff/SKILL.md  # greenfield on-ramp: interview → brief + CLAUDE.md + repo + backlog
│   ├── harness-setup/SKILL.md    # one-time repo onboarding: doctor + CLAUDE.md audit + baseline
│   ├── issue-planner/SKILL.md    # orchestrates planning (answers → revision → policy auto-approval)
│   ├── issue-implementer/SKILL.md # orchestrates implementation → verification → PR (+ CI fix)
│   └── issue-cycle/SKILL.md      # steady-state loop: cleanup → plan → implement → status report
├── bin/                          # on the Bash PATH when the plugin is enabled
│   ├── check-harness.sh           # mechanical preflight ("doctor"); safe to re-run any time
│   ├── find-planning-work.sh
│   ├── setup-labels.sh            # creates the workflow labels (run once per repo)
│   ├── find-implementation-work.sh
│   ├── harness-status.sh          # who acts next: harness queues vs. items waiting on the human
│   └── cleanup-after-merge.sh     # post-merge sync + branch/label hygiene (--fix repairs labels)
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
1. Pre-flight: `cleanup-after-merge.sh --fix` (sync + queue hygiene), then makes sure plans are
   written against the current default branch.
2. Finds issues needing an **initial plan** (no `plan-*` label) or a **revision**
   (`plan-proposed` with comments after the latest plan), via `find-planning-work.sh`.
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
didn't state any), Estimated size (S/M/L), Affected areas, Data/schema impact, Implementation
steps, Testing approach, Risks, **Verified facts**, **Open questions (BLOCKING/ADVISORY)**,
**Follow-ups to file**, Out of scope.

### Approval (human by default, policy-assisted if you opt in)

Comment on the issue to request changes (comment-driven, no label needed). Add `plan-approved`
to accept. **Approving a plan whose open questions are all ADVISORY accepts the stated
defaults** — no extra revision round; the orchestrator passes the defaults to the implementer as
resolved decisions. Plans with unanswered BLOCKING questions shouldn't be approved.

**Plan auto-approval (opt-in).** If the repo's `CLAUDE.md` contains a section titled **"Plan
auto-approval policy"**, the planner may add `plan-approved` itself for plans that satisfy the
policy's conditions AND a non-negotiable hard floor: no unanswered BLOCKING questions, no
BLOCKING questions resolved by the orchestrator's own proposed answers (it never approves its
own answers), not stale, no overlap with other pending plans, no schema impact and nothing
security-sensitive unless the policy explicitly opts those in, and no `no-auto-approve` label
on the issue. Every auto-approval leaves an audit comment (which conditions were met, how to
veto). No policy section ⇒ no auto-approval — the default is fully manual. The
**`no-auto-approve` label** opts any individual issue back out of the policy. Note that an
auto-approved plan may be implemented in the same run — for that work, PR review is the human
gate.

### Implementation ("implement the approved issues" / "implement issue 14")

The `issue-implementer` skill, for each `plan-approved` issue (sequential by default):
1. Pre-flight: crash recovery (a dirty tree on a `claude/<n>-*` branch from an interrupted run
   is wip-committed, noted on the issue, and requeued; a dirty tree anywhere else is a hard
   stop — that's human work), `cleanup-after-merge.sh --fix`, and the **baseline refresh**: if
   the default branch moved past `.claude/BASELINE.md`'s recorded commit, re-run the
   verification suite on it — green updates the baseline, red stops the whole run (a broken
   main makes every failure unattributable). Then a fresh `claude/<n>-<slug>` branch; wip-only
   leftover branches are reset automatically, branches with real commits go to the human.
2. Dispatches the `implementer` subagent with: issue + full plan (incl. Verified facts) +
   **resolved answers to every open question** (including binding post-approval comments from
   the thread) + `LESSONS.md` entries. Missing a BLOCKING answer → don't dispatch; ask the human.
3. On completion: **independently re-runs the verification commands** (the mechanical gate — the
   subagent may be wrong), comparing against the recorded baseline (counts must not drop
   unexplained).
4. **Dispatches the `verifier` subagent** (the semantic gate): fresh-context, read-only review of
   the diff against the plan's steps, the plan's acceptance criteria, test quality, scope, and
   declared constraints. **Verifier fail → kickback**: the implementer is re-dispatched with the
   findings ("fix ONLY these"), then re-checked — **max 2 kickbacks**, then `impl-blocked` with
   the findings. All of this happens *before* anything is committed, so every PR the human sees
   is verifier-clean.
5. On verifier pass: stages everything, **reconciles the staged list against the report's "Files
   changed"** (unexplained files = blocker, not a commit), commits, pushes, opens the PR
   (`Closes #n`, verification results, verifier notes, schema notes), labels `pr-open`.
6. **Files the plan's "Follow-ups to file"** as new issues, referencing the PR.
7. **Watches CI** (`gh pr checks --watch`). Red CI caused by the PR itself gets **one bounded
   fix attempt** (implementer → mechanical checks → verifier → push; the PR isn't merged, so
   this is as safe as the kickback loop); still red — or not the PR's fault — is noted on the
   issue for the human. If the failure was a project gotcha, **append it to `LESSONS.md`**.
8. Never merges (merging is the human's, or the cycle's merge pass under an opt-in policy —
   see "The CLAUDE.md contract"). Blockers → local `wip:` branch + `impl-blocked` label +
   explanatory comment.

**Worktree-parallel mode:** when 2+ approved plans have pairwise **disjoint Affected areas**
(production + test files), the orchestrator may create one git worktree per issue and dispatch
the implementers concurrently — each pipeline (mechanical checks → verifier → commit → PR) then
completes per-worktree, with the orchestrator's own git/gh work staying sequential. Ignored
files (venvs, `node_modules`) don't exist in fresh worktrees: verification runs the main
checkout's tool binaries against the worktree, and UI-heavy issues that need per-tree installs
fall back to sequential. Any overlap or doubt → sequential.

### After the human merges

Nothing is required: every planner/implementer/cycle run starts with
`cleanup-after-merge.sh --fix` (sync, prune merged `claude/*` branches, repair stale `pr-open`
labels with audited comments) and the implementer's baseline refresh re-verifies merged main —
two green PRs can still compose badly, and that check is now mechanical. Running
`cleanup-after-merge.sh` by hand right after a merge is still fine (it's idempotent); without
`--fix` it only reports label problems instead of repairing them.

### The steady state, as one command ("run the cycle")

The `issue-cycle` skill composes the above into a single bounded pass: pre-flight (cleanup +
baseline refresh) → planning pass (plans, revisions, proposed answers, policy auto-approvals) →
implementation pass (everything `plan-approved`) → merge pass (only when the repo opts in via
a CLAUDE.md "Merge autonomy policy" *and* the human has lifted the `gh pr merge` deny; one PR
at a time, re-verified between, audited in the report) → a closing report via
`harness-status.sh` that splits the world into *what the cycle did* and *what waits on the
human* (plans to review, PRs to merge, blocked issues). It adds no authority beyond what the
repo's CLAUDE.md delegates — it just removes the hand-cranking between stages. Pair it with `/loop` or a scheduled routine for unattended
operation; each invocation stays one bounded pass, and an empty cycle reports "all quiet" in
one line. With a conservative auto-approval policy in place, the unattended flow becomes:
issues in → verifier-clean PRs out, with the human reviewing PRs and answering BLOCKING
questions.

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

The `issue-implementer` skill branches off the default branch, dispatches the `implementer`
subagent to build the skeleton, **independently re-runs the verification commands**, then runs
the `verifier` subagent against the plan — all before committing. It opens a PR (`Closes #1`) with
the verification results. Review the PR and **merge it** on GitHub. (No cleanup step needed —
the next skill run's pre-flight syncs and tidies automatically; run `cleanup-after-merge.sh`
by hand if you want the tidy-up immediately.)

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
planning entirely (tracking/discussion/question issues), and `no-auto-approve` to keep an
individual issue's approval manual even when CLAUDE.md defines an auto-approval policy. Humans
gate twice: plan approval and PR merge — each manual unless the repo's CLAUDE.md explicitly
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
   orchestrator itself — not stale, no overlap, schema/security work only if explicitly opted
   in), every auto-approval is audited with an issue comment, and the `no-auto-approve` label
   opts any issue out. **No section means no auto-approval** — this is a trust decision that
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
   `Bash(gh pr merge:*)` from the deny list in `.claude/settings.json` (and add it to the
   allow list, or unattended runs stall on the permission prompt). Both edits are yours,
   never an agent's — and because the deny is machine-local state in a checked-in file, you
   can activate one machine at a time by leaving the removal uncommitted. The merge pass's
   hard floor always applies on top (standard-flow PRs only, CI green on the head commit,
   never the governance surface — CLAUDE.md, `.claude/`, policy/ADR docs — nothing flagged
   for human decision, one merge at a time with re-verification between, every merge audited
   in the cycle report). **No section means no autonomous merges** — behavior is exactly the
   pre-1.5 default. Recommended pairing: branch protection with required status checks, so
   the policy has a technical rail under it, not just prompt adherence.

The subagents read `CLAUDE.md` at the start of every task. A thin `CLAUDE.md` leaves them
guessing — it is the real input that makes the harness work well in a given repo.

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
it by hand.

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
migrated. For **≤ v1.2 → v1.3** specifically, expect three items:

1. **New label** — run `setup-labels.sh` once (idempotent); v1.3 adds `no-auto-approve`, the
   per-issue opt-out from plan auto-approval. Until it exists, you can't opt an issue out —
   though nothing auto-approves anyway until you add a policy (see 3).
2. **New permission grants** — re-copy (or merge) the `permissions` block from the plugin's
   `templates/repo-settings.json` into `.claude/settings.json`. v1.3 adds `harness-status.sh`,
   `gh pr list`, `gh run view`, `git rev-parse`, and `git worktree`; a missing grant silently
   stalls an unattended run behind a permission prompt, which is why the doctor checks for
   these specifically.
3. **Baseline file** — run the `harness-setup` skill once (or just its baseline step) to
   persist `.claude/BASELINE.md` and its `.gitignore` entry. Until then, runs warn and proceed
   without baseline comparisons.

For **v1.4 → v1.5** nothing migrates: merge autonomy is pure opt-in, and every repo without a
CLAUDE.md "Merge autonomy policy" section behaves exactly as before (PR merge always human).
To opt a repo in, see the double opt-in under "The CLAUDE.md contract" item 5.

Optional, not required: add a **"Plan auto-approval policy"** section to `CLAUDE.md` if you
want the planner to approve low-risk plans for you — without it, behavior stays fully manual,
exactly as before. Nothing else migrates: existing issues, labels, and plan comments keep
working (plans posted by older versions lack the "Acceptance criteria" section; the verifier
falls back to the issue body for those), and `LESSONS.md` is untouched.

## The per-repo settings file (required)

Plugins cannot ship permission rules, so each target repo keeps a thin, checked-in
`.claude/settings.json` — start from `templates/repo-settings.json`. It pre-allows the harness
scripts (bare names — `bin/` is on the PATH), the `gh`/`git` commands the orchestrator runs,
Edit/Write, the build/test runners, and carries the deny-list (no merge, no force-push, no
`reset --hard`). The `gh pr merge` deny is the merge-autonomy off-switch: it ships on, and
lifting it is a human edit reserved for repos that define a CLAUDE.md merge autonomy policy. The same file also carries the non-permission keys a clone needs to bootstrap
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
default branch directly), a deny-list (no merge by default, no force-push, no `reset --hard`,
no `rm -rf`), independent re-verification + staged-file reconciliation before every commit, and
**human review of every PR before merge unless the repo has double-opted-in to merge autonomy**
(CLAUDE.md policy + lifted deny — see "The CLAUDE.md contract"). The deny-list is best-effort pattern matching; branch protection +
PR review are the real backstops.

Two honest caveats. First, the implementer's "no git" rule is enforced by prompt, not by
permissions: the settings allow-list must permit git for the orchestrator, and permission
grants are session-wide, so a misbehaving subagent *could* run git — the staged-file
reconciliation and branch isolation are what bound the damage. Second, plan auto-approval and
merge autonomy (each opt-in via CLAUDE.md; merge additionally requires the human to lift the
`gh pr merge` deny) deliberately trade human gates for throughput on low-risk work. Their hard
floors are not configurable and every use is audited (issue comment; cycle report). With only
auto-approval enabled, a bad auto-approval costs a wasted PR, not a bad merge. With merge
autonomy also enabled, the backstop is the merge pass's hard floor (standard-flow PRs only,
green CI, protected governance surface, sequential re-verification) — and on a repo with
branch protection + required checks, that floor is a technical rail, not just policy. Enable
merge autonomy only where a bad merge is cheap to revert (e.g. a default branch that doesn't
auto-deploy).

## Distribution

This repo **is the plugin and its own marketplace** (`.claude-plugin/plugin.json` +
`marketplace.json`): skills + agents versioned together, installable per-project, with the
agent model pins (`planner: claude-opus-5`, `implementer: claude-sonnet-5`, `verifier: claude-opus-5`) travelling with
the plugin. Install/update flow is in "Installing in a new repo".

Project-side files that never live in this repo: `CLAUDE.md`, `LESSONS.md`, `BASELINE.md`,
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
