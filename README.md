# Claude Code issue workflow — portable harness

A project-agnostic Claude Code setup for driving GitHub issues through **planning**,
**implementation**, and **verification**, locally, on your Claude Code subscription (no API
keys, OAuth tokens, or GitHub Actions). The generic *mechanism* lives here; everything
project-specific lives in the target repo's `CLAUDE.md` and `.claude/LESSONS.md`.

This is the **standalone toolset repo**: its contents install as a target repo's `.claude/`
directory (packaging as a Claude Code plugin is the next step). Keep the boundary in mind when
editing: nothing project-specific belongs in the skills or agent files — it belongs in the
target repo's `CLAUDE.md` (conventions, verification commands) or `LESSONS.md` (project
gotchas), both of which stay with each project. Two files exist only on the project side and
are deliberately NOT in this repo: `LESSONS.md` (project-owned gotchas, seeded by the doctor
script) and `settings.local.json` (machine-local secrets/overrides — never commit or share).

## What's in here

```
.                                  # installs as the target repo's .claude/
├── settings.json                 # permissions: gh/git/edit/write + build tools, with a deny-list
├── agents/
│   ├── planner.md                # read-only planning subagent (Opus)
│   ├── implementer.md            # code-writing subagent (Sonnet); no git/network
│   └── verifier.md               # read-only plan-conformance reviewer (Opus); fresh context
└── skills/
    ├── harness-setup/
    │   ├── SKILL.md              # one-time repo onboarding: doctor + CLAUDE.md audit + baseline
    │   └── scripts/
    │       └── check-harness.sh   # mechanical preflight ("doctor"); safe to re-run any time
    ├── issue-planner/
    │   ├── SKILL.md              # orchestrates planning (+ proposed-answers step)
    │   └── scripts/
    │       ├── find-planning-work.sh
    │       └── setup-labels.sh    # creates the workflow labels (run once per repo)
    └── issue-implementer/
        ├── SKILL.md              # orchestrates implementation → PR
        └── scripts/
            ├── find-implementation-work.sh
            └── cleanup-after-merge.sh   # post-merge sync + branch/label hygiene
```

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
bash .claude/skills/issue-implementer/scripts/cleanup-after-merge.sh
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

1. Copy this repo's contents into the target repo as its `.claude/` directory (until the
   toolset is packaged as a plugin — see "Distribution" below), e.g. from the target repo root:
   ```bash
   git clone <this-repo-url> /tmp/claude-issue-harness
   mkdir -p .claude && cp -R /tmp/claude-issue-harness/{agents,skills,settings.json,README.md} .claude/
   ```
   If the target repo already has a `.claude/settings.json`, merge the allow/deny lists instead
   of overwriting.
2. Make the doctor runnable, then **run the `harness-setup` skill** — in a Claude Code session
   in the repo, say:
   > Run the harness-setup skill: check this repo's harness installation, audit CLAUDE.md
   > against the contract (draft what's missing for my review), and establish the
   > verification baseline.
   It runs the mechanical preflight (`check-harness.sh`), creates the labels, audits/drafts
   `CLAUDE.md`, runs the verification commands on the default branch to record a **green
   baseline**, and reports readiness. Don't skip the baseline: every implementation run
   compares against it, and a repo that is red on its own default branch can't use the
   harness meaningfully.
3. Recommended: enable branch protection on the default branch (require a PR before merge) —
   the doctor checks and reminds you.

Manual fallback (no Claude session): `chmod +x .claude/skills/*/scripts/*.sh`, then
`bash .claude/skills/harness-setup/scripts/check-harness.sh` and follow its FAIL/WARN
remediation hints; create labels via `setup-labels.sh`; write `CLAUDE.md` per the contract
above and confirm its verification commands pass on the default branch.

## The one project-specific setting

`settings.json` auto-allows the build/test runners the subagents invoke (subagents can't show
permission prompts, so their commands must be pre-allowed). The template allows `pnpm`, `npm`,
`yarn`, and `pytest`. If your repo uses a different toolchain, add it to the `allow` list —
the doctor script warns when it detects a toolchain the list doesn't cover — e.g.:

```json
"Bash(make:*)", "Bash(cargo:*)", "Bash(go:*)", "Bash(pytest:*)", "Bash(just:*)"
```

Everything else in `settings.json` (git, gh, Edit, Write, the deny-list) is generic.
`settings.local.json` is machine-local (may hold secrets) — never commit it and never include it
when extracting the toolset.

## Safety model

The implementer subagent can edit files and run the build tool, but does **no** git or network —
the orchestrator does all git/GitHub. Guarantees: branch isolation (work never lands on the
default branch directly), a deny-list (no merge, no force-push, no `reset --hard`, no `rm -rf`),
independent re-verification + staged-file reconciliation before every commit, and **human review
of every PR before merge**. The deny-list is best-effort pattern matching; branch protection +
PR review are the real backstops.

## Distribution

Current state: **this standalone repo** — install by copying into a target repo's `.claude/`
(see "Installing in a new repo"). Target state: **a Claude Code plugin** — skills + agents
versioned together, installable per-project, with the agent model pins (`planner: opus`,
`implementer: sonnet`, `verifier: opus`) travelling with the plugin.

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
