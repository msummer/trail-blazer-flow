# Architecture and repository layout

> Part of the [reference documentation](README.md). A quoted section name such as "Safety model"
> or "The CLAUDE.md contract" refers to a heading in this reference set or in the top-level
> [README](../../README.md) — the [index](README.md#where-each-section-lives) says which file holds it.

## What's in here

```
.
├── CLAUDE.md                     # this repo's OWN harness contract — governs work on the harness itself
├── CHANGELOG.md                  # per-PR history (not governance, not a spec)
├── .claude-plugin/
│   ├── plugin.json               # plugin manifest (semver version field — bump it to publish an update)
│   └── marketplace.json          # this repo doubles as its own marketplace
├── agents/
│   ├── planner.md                # read-only planning subagent (Opus 5.5)
│   ├── implementer.md            # code-writing subagent (Sonnet 5); no git/gh, mechanically enforced (hooks/agent-boundary.sh)
│   └── verifier.md               # plan-conformance reviewer (Opus 5.5); fresh context; restores anything it mutates; read-only git only, no gh, mechanically enforced
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
│   ├── harness-lock.sh            # single-flight lock: at most one active cycle per checkout
│   ├── harness-version.sh         # prints the installed plugin's "<version> <sha>", one line
│   ├── harness-stop.sh            # read-only maintainer stop switch: GitHub label or local file (#310)
│   ├── governance-paths.sh        # merge floor's governance-path classifier + doctor's --check validator (#331)
│   └── cleanup-after-merge.sh     # post-merge sync + branch/label hygiene (--fix repairs labels)
├── hooks/                        # plugin-shipped Claude Code hooks — never on the Bash PATH, never invoked by the model
│   ├── hooks.json                 # registers the four PreToolUse hooks below
│   ├── git-c-guard.sh             # approves only the exact git -C <worktree> <subcommand> forms worktree-parallel mode issues
│   ├── agent-boundary.sh          # mechanically denies git/gh Bash commands, and a Bash write into .claude/, for the implementer/verifier subagents (#235, #340, #387)
│   ├── push-guard.sh              # mechanically denies any git push whose destination is the default branch, every session (#260)
│   └── claude-dir-guard.sh        # mechanically denies an implementer/verifier Edit or Write to any .claude/ path (#327)
├── dev/
│   ├── selfcheck.sh              # this repo's OWN verification gate — see "Working on the harness itself"
│   ├── selfcheck-tests.sh        # the gate's own negative-test harness (not run by the gate itself)
│   ├── doctor-tests.sh           # fixture-based negative-test harness for bin/check-harness.sh AND bin/governance-paths.sh (not run by the gate)
│   ├── hook-tests.sh             # fixture-based negative-test harness for hooks/git-c-guard.sh, hooks/agent-boundary.sh, hooks/push-guard.sh, AND hooks/claude-dir-guard.sh (not run by the gate)
│   ├── cleanup-tests.sh          # fixture-based negative-test harness for bin/cleanup-after-merge.sh (not run by the gate)
│   ├── planning-tests.sh         # fixture-based negative-test harness for bin/find-planning-work.sh AND bin/find-implementation-work.sh (not run by the gate)
│   ├── lock-tests.sh             # fixture-based negative-test harness for bin/harness-lock.sh (not run by the gate)
│   ├── stop-tests.sh             # fixture-based negative-test harness for bin/harness-stop.sh (not run by the gate)
│   ├── mutant-driver.sh          # checked-in mutant driver: applies dev/mutants/*.json's recorded edits to a scratch copy and re-runs each record's suite (#359)
│   ├── mutant-driver-tests.sh    # the driver's own negative-test harness, over synthetic targets/suites (not run by the gate)
│   └── mutants/                  # machine-readable mutant registries the driver reads — {name,target,suite,filter,edits,expect_fail} per record
├── docs/
│   ├── reference/                # the detailed spec: workflow, CLAUDE.md contract, settings, safety model
│   └── adr/                      # architecture decision records: direction the spec doesn't cover yet
├── .github/
│   ├── workflows/selfcheck.yml # CI: gate, then its negative-test harness, then the doctor's negative-test harness, then the four hooks' shared negative-test harness, then the cleanup script's negative-test harness, then the two discovery scripts' shared negative-test harness, then the lock script's negative-test harness, then the stop switch script's negative-test harness, then the mutant driver (post-merge/nightly/dispatch only), then the driver's own negative-test harness — on ubuntu-latest per PR and, pinned to Apple's bash 3.2, on macos-latest post-merge and nightly (#365)
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
| **planner** subagent | Opus 5.5 | codebase research and design; one dispatch per issue, read-only |
| **implementer** subagent | Sonnet 5 | execution of a fully-resolved plan; cheap enough to run often (and in parallel) |
| **verifier** subagent | Opus 5.5 | adversarial plan-conformance review of the diff with fresh context — the generator/critic split; judgment-heavy, so it gets the stronger model |

Two consequences are baked into the skills:
1. **Ambiguity is resolved top-down, before execution.** Plans classify questions
   BLOCKING/ADVISORY; the orchestrator proposes answers; the implementer receives only
   `RESOLVED:` decisions — it should never exercise design judgment.
2. **Research flows down as "Verified facts".** The planner writes down every codebase fact it
   confirmed (exact names, signatures, fixture contracts, ordering constraints), so every
   downstream dispatch — the implementer, the verifier, retries, parallel runs — works from one
   written account instead of re-deriving it: research gets paid for once, not per dispatch, and
   the implementer's context stays on the change instead of the exploration.

## Distribution

This repo **is the plugin and its own marketplace** (`.claude-plugin/plugin.json` +
`marketplace.json`): skills + agents versioned together, installable per-project, with the
agent model pins (`planner: claude-opus-5-5`, `implementer: claude-sonnet-5`, `verifier: claude-opus-5-5`) travelling with
the plugin. Install/update flow is in the README's [Getting started](../../README.md#getting-started)
and [Updating](../../README.md#updating).

Project-side files that never live in this repo: `LESSONS.md`, `BASELINE.md`,
`settings.local.json`, and the label setup (per-repo, via `setup-labels.sh`). This repo does
carry its own root `CLAUDE.md` — see the README's "Working on the harness itself" — but that file
governs work *on* the harness itself, not on a project that consumes it; a consumer repo's own
`CLAUDE.md` (conventions, verification commands) is a separate, project-owned file that never
lives here. Nothing in the skills/agents should reference a specific project — if you find such
a reference, that content belongs in the target repo's `CLAUDE.md` or `LESSONS.md` instead.
