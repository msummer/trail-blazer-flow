# Claude Code issue workflow — portable harness

A project-agnostic Claude Code setup for driving GitHub issues through **planning**,
**implementation**, and **verification**, locally, on your Claude Code subscription (no API
keys, OAuth tokens, or GitHub Actions). The generic *mechanism* lives here; everything
project-specific lives in the target repo's `CLAUDE.md` and `.claude/LESSONS.md`.

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

1. **Add the marketplace and install the plugin** (once per machine; private repos work via
   your existing `gh` credentials):
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
`.claude-plugin/plugin.json`). *To publish a release* (author side): bump that version, commit,
and push — that is the whole release process. *To receive updates* (consumer side): the template
registers the marketplace with `"autoUpdate": true`, so each new version is picked up
automatically at the start of a session (Claude Code refreshes the marketplace and reports what
it updated; run `/reload-plugins` if prompted). To update by hand instead, run
`/plugin marketplace update trail-blazer-flow` then
`/plugin update trail-blazer-flow@trail-blazer-flow`.

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
