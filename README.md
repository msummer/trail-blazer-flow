# Trail Blazer Flow

**A Claude Code plugin that turns GitHub issues into reviewed, tested pull requests.** You write an
issue; the harness plans it, you approve the plan, it writes the code, an independent reviewer
checks the work, and a PR shows up for you to merge. Once you trust it, you can let it approve
low-risk plans and merge its own PRs as well.

Everything runs locally, on your Claude Code subscription or (supervised only, see
[Running on Codex](#running-on-codex)) your Codex CLI login. You don't need API keys, OAuth
tokens, or GitHub Actions.

> **Status: early access.** This harness is being tested by a small group. Expect rough edges and
> the occasional breaking change, and note that updates arrive automatically by default (see
> [Updating](#updating)). Bug reports and feedback are very welcome:
> [open an issue](https://github.com/msummer/trail-blazer-flow/issues). Licensed under
> [MIT](LICENSE).

**Contents**

- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Getting started](#getting-started): [a new project](#path-a--start-a-brand-new-project) or
  [an existing repo](#path-b--add-the-harness-to-an-existing-repo)
- [Everyday workflows](#everyday-workflows): step-by-step recipes
- [Autonomous mode](#autonomous-mode): what it is and how to turn it on
- [The CLAUDE.md contract](#the-claudemd-contract): configuring the harness for your repo
- [Labels at a glance](#labels-at-a-glance)
- [Safety model](#safety-model)
- [Running on Codex](#running-on-codex)
- [Updating](#updating)
- [Troubleshooting](#troubleshooting)
- [Reference documentation](#reference-documentation)
- [Working on the harness itself](#working-on-the-harness-itself)

---

## How it works

```
  you write      planner        you           implementer    verifier       you
  an issue  ──▶  drafts a  ──▶  approve  ──▶  writes code ──▶ reviews  ──▶  merge
                 plan           the plan      and tests       the diff      the PR
                    │                                            │
                    └─ posted as an issue comment                └─ fail? back to the implementer
                                                                    pass? PR opened, CI watched
```

The Claude Code session you start acts as the **orchestrator**. It does all the git and GitHub
work and hands focused jobs to three subagents:

| Agent | Model | Job |
|---|---|---|
| **planner** | Opus 5.5 | Reads the codebase (read-only) and writes a plan for one issue: acceptance criteria, steps, risks, open questions |
| **implementer** | Sonnet 5 | Writes the code and tests for an approved plan. It cannot run `git` or `gh` (a hook enforces this) |
| **verifier** | Opus 5.5 | Reviews the diff against the plan with fresh context, including a small mutation test of the new tests. Nothing is pushed until it passes |

**You have two gates: approving the plan and merging the PR.** By default both are yours. Each one
can be delegated to the harness through a policy you write into your repo's `CLAUDE.md` (see
[Autonomous mode](#autonomous-mode)).

**Every step leaves a trace on GitHub.** Plans are issue comments, approval is a label, finished
work is a PR, and questions it can't answer become issue comments with a `needs-human` label. You
can review everything from the GitHub web or mobile app.

**What lives where.** The plugin carries the generic machinery (skills, agents, scripts, hooks).
Anything specific to your project lives in your repo:

| File in your repo | What it is |
|---|---|
| `CLAUDE.md` | Your conventions, your verification commands (tests, lint, build), and any autonomy policies you opt into. The agents read it at the start of every task |
| `.claude/settings.json` | Permission grants the subagents need, checked in. Start from [`templates/repo-settings.json`](templates/repo-settings.json) |
| `.claude/LESSONS.md` | Gotchas the harness has learned about your project, one short entry each. Created for you |
| `.claude/BASELINE.md` | The last known-green run of your tests on the default branch. Machine-local and gitignored; the harness maintains it |

---

## Prerequisites

- **Claude Code 2.1.85 or newer**, on a Pro or Max subscription. Your account needs access to the
  models the agents pin: `claude-opus-5-5` and `claude-sonnet-5`.
- **`gh`** (GitHub CLI), authenticated (`gh auth status`).
- **`jq`** and **`bash`**. macOS and Linux work out of the box. On Windows, run Claude Code under
  Git Bash or WSL (see [Windows](#windows)).
- A GitHub repository where you can add labels and open PRs. The kickoff flow creates one for you
  if you're starting from scratch.

---

## Getting started

First, **install the plugin**. You only need to do this once per machine:

```
/plugin marketplace add msummer/trail-blazer-flow
/plugin install trail-blazer-flow@trail-blazer-flow
```

Teammates can skip this step: once your repo's `.claude/settings.json` is checked in, anyone who
clones the repo gets the plugin installed and enabled the first time they trust the folder.

Then pick your path.

### Path A — Start a brand-new project

Use this path for an empty or nearly empty directory. You don't need a GitHub repo yet.

**Why the order matters:** the harness measures every change against a green test baseline, and
a project with no code can't have one yet. So the first issue is always a **walking skeleton**:
the smallest runnable project plus its test setup. The baseline gets recorded once that skeleton
merges.

1. **Start Claude Code in the empty directory and describe what you want to build.**
   > "Let's start a new project — I want to build &lt;your idea&gt;."

   Paste a PRD, notes, or a doc link if you have one. The `project-kickoff` skill interviews you
   about whatever is missing. Answers can be dictated by voice.
2. **Review the proposal.** It shows you a project brief, an architecture and stack (with the
   alternatives it rejected), a methodology, and a first issue backlog. Give feedback until you're
   happy, then say *"Looks good — go ahead."*
3. **Let it set things up.** It creates or selects the GitHub repo, installs the labels, and
   writes `.claude/settings.json`, `docs/PROJECT-BRIEF.md`, a drafted `CLAUDE.md`, and the
   issues. Issue #1 is the walking skeleton. Kickoff never commits on its own, so review the files
   and then say:
   > "Commit and push the setup files."
4. **Build the skeleton (issue #1).**
   > "Plan issue 1."

   Read the plan it posts on the issue. If it looks right, approve it:
   ```bash
   gh issue edit 1 --add-label plan-approved   # or add the label in the GitHub UI
   ```
   > "Implement issue 1."

   Review the PR it opens and merge it.
5. **Record the baseline.**
   > "Run harness-setup."

   The `harness-setup` skill checks the installation, audits `CLAUDE.md` against the real code,
   runs your verification commands, and records the green baseline. The repo is now ready.
6. **Carry on with the [everyday workflows](#everyday-workflows).**

### Path B — Add the harness to an existing repo

1. **Add the per-repo settings file.** Copy the template into your repo as
   `.claude/settings.json`. The command below overwrites the file, so if you already have one,
   merge the template's entries into it by hand instead:
   ```bash
   mkdir -p .claude
   curl -fsSL https://raw.githubusercontent.com/msummer/trail-blazer-flow/main/templates/repo-settings.json \
     -o .claude/settings.json
   ```
   The template allows `pnpm`, `npm`, `yarn`, and `pytest`. If you build with something else, add
   it to `permissions.allow`, for example `"Bash(make:*)"` or `"Bash(cargo:*)"`. Subagents can't
   answer permission prompts, so a missing grant stalls them. Commit the file.
2. **Run the setup skill.** In a Claude Code session in the repo, say:
   > "Run harness-setup: check this repo's harness installation, audit CLAUDE.md against the
   > contract (draft what's missing for my review), and establish the verification baseline."

   The skill:
   - runs the doctor, `check-harness.sh`, and creates any missing labels
   - audits your `CLAUDE.md`, or drafts one if you don't have it. The part that matters most is a
     **Verification** section naming the commands that define "done" (tests, lint, typecheck,
     build)
   - runs those commands on the default branch and records the green baseline in
     `.claude/BASELINE.md`

   If your default branch is red, fix that first. The harness can't tell its own breakage apart
   from breakage that was already there.
3. **Review and commit the `CLAUDE.md` changes.** The skill never commits on its own.
4. **Recommended: protect the default branch.** Require a PR before merging, and require your CI
   checks to pass. The doctor reminds you if this is missing.
5. **Try it on one small issue:** *"Plan issue 42"* → approve → *"Implement issue 42"* → merge.

You can re-run `check-harness.sh` at any time. It's read-only apart from two safe fixes (script
executable bits, seeding an empty `LESSONS.md`), and it tells you exactly what to fix.

---

## Everyday workflows

You drive the harness in plain English from a Claude Code session in your repo. These phrases map
to the skills:

| Say… | Skill | What happens |
|---|---|---|
| "Run the cycle" | `issue-cycle` | One full pass: tidy up after merges → plan → implement → (merge, if enabled) → report what's waiting on you |
| "Plan the open issues" / "Plan issues 13 and 15" | `issue-planner` | Drafts or revises plans and posts them as issue comments |
| "Implement the approved issues" / "Implement issue 14" | `issue-implementer` | Builds each approved issue on its own branch, verifies it, and opens a PR |
| "Run harness-setup" | `harness-setup` | Checks the installation, audits `CLAUDE.md`, and refreshes the baseline |
| "Start a new project" | `project-kickoff` | The greenfield on-ramp ([Path A](#path-a--start-a-brand-new-project)) |
| "Run the test ratchet" | `test-ratchet` | Files issues that close test-coverage gaps. Opt-in, see [the CLAUDE.md contract](#the-claudemd-contract) |

You can also call a skill directly, for example `/trail-blazer-flow:issue-cycle`.

### The daily loop

1. **"Run the cycle."** It finishes with a report in two halves: what it did, and what's waiting on
   you.
2. **Review the plans it posted** ([recipe below](#review-a-plan)).
3. **Review and merge the PRs it opened** ([recipe below](#review-and-merge-a-pr)).
4. **Repeat.** Anything you approved gets built on the next run.

After a merge you don't need to do anything. The next run starts by syncing the default branch,
deleting merged `claude/*` branches, and repairing labels. Before building anything new, it also
re-runs your verification commands on the merged code, because two green PRs can still break each
other.

### Review a plan

A plan is an issue comment whose first line is a hidden `<!-- planner-plan -->` marker, and the
issue gets the `plan-proposed` label. Each plan includes acceptance criteria, implementation steps, a testing
approach, risks, and **open questions** marked **BLOCKING** or **ADVISORY**.

- **Approve it:** add the `plan-approved` label (`gh issue edit <n> --add-label plan-approved`).
  Approving a plan whose open questions are all ADVISORY accepts the defaults it proposes. Don't
  approve a plan that still has an unanswered BLOCKING question. Answer it in a comment instead.
- **Request changes:** comment on the issue saying what to change. You don't need a label. The next
  planning run reads your comment and posts a revised plan.
- **Take the issue out of planning:** add `no-plan`.

Only comments from repo owners, members, and collaborators count as feedback. Comments from anyone
else are reported to you and never acted on.

### Review and merge a PR

The PR is only opened after the verifier has passed the work. Its body includes the verification
results, the verifier's status line, the mutation-probe result, and `Closes #<n>`. Read it, check
CI, then merge it or close it like any other PR. If you want changes before doing either, comment
on it first.

### See what's waiting on you

```bash
harness-status.sh
```

This prints JSON with two halves. `harness_will_handle` lists work the next run will pick up
without you. `waiting_on_human` lists what needs you: `plans_to_review`, `prs_to_review` (each
with its CI state), `blocked`, `followups_to_triage`, `escalations`, and `stop_routes`. If
`degraded` is `true`, a GitHub query failed and one of those lists may be incomplete. The
`degraded_reasons` field says which one.

### Unblock an issue

- **`impl-blocked`:** the implementer hit something it couldn't resolve, for example the verifier
  still failing after the retry budget ran out. Its comment on the issue explains why. Fix the
  cause (usually by answering a question, or by revising the plan), then **remove `impl-blocked`**
  to put the issue back in the queue.
- **`needs-human`:** the harness hit a question only you can answer. It posted the question and
  its evidence as a comment and moved on to other work instead of stalling. Answer in a comment,
  then **remove `needs-human`**. The issue is invisible to every harness queue until you do.

### Triage follow-up issues

When a PR's plan lists follow-up work, the harness files each follow-up as a new issue labelled
`no-plan`, so it waits for you before any planning happens. For each one:

- **Build it:** remove `no-plan` and it enters planning on the next run.
- **Keep it parked:** add `triaged-held`. It then stops counting in `followups_to_triage`.
- **Drop it:** close it as *not planned*.

If the PR that filed a follow-up is closed without merging, the next run's cleanup quarantines that
follow-up. It makes sure the issue carries `no-plan` and leaves a comment keyed
`<!-- harness-orphan-notice: PR #<n> -->`. It never closes the issue.

### Split an issue across several PRs

Add the **`multi-pr`** label to the issue. When one slice's PR merges, cleanup then leaves the
issue open (reported as `KEEP`) instead of closing it, and the issue re-queues for its next slice.
A maintainer comment containing `<!-- harness-multi-pr -->` works too, but the label is the
primary signal. Close the issue yourself when the last slice lands.

### Pause, veto, or stop

| You want to… | Do this |
|---|---|
| Keep one issue's approval manual, even under an auto-approval policy | Add `no-auto-approve` |
| Halt one issue mid-flight | Remove `plan-approved`. The harness honours this at its next check and resumes when you re-add it |
| **Stop a running cycle** from your phone | Add `harness-stop` to any open issue. Remove it to resume |
| **Stop a running cycle** at the keyboard | `mkdir -p "$(git rev-parse --git-common-dir)/trail-blazer" && touch "$(git rev-parse --git-common-dir)/trail-blazer/stop"`. Delete the file to resume |

The stop switch is checked before each stage and before each merge. It can't interrupt a subagent
that is already running, but nothing new starts after it's set.

### Work from your phone

Every gate is an ordinary GitHub object, so the GitHub mobile app is all you need while a cycle
runs unattended. Read a plan and add `plan-approved`, comment to request changes, merge a PR, or
add `harness-stop` to halt everything. Back at a laptop, `harness-status.sh` shows what's left.

### Run it on a schedule

Each cycle is one bounded pass, so you schedule the repetition from outside:

```
/loop 30m /trail-blazer-flow:issue-cycle
```

You can also run it from a scheduled routine or cron job. Only one cycle can run per checkout at a
time (a lock enforces this). For fully unattended runs, see
[Autonomous mode](#autonomous-mode).

---

## Autonomous mode

By default, a human approves every plan and merges every PR. Autonomous mode lets the harness do
both itself, but only inside fixed safety floors that no setting can loosen. It's meant for repos
where you want the backlog to keep moving while you're away, and where a bad merge is cheap to
revert.

### The four levels

Each level is something you opt into in your repo's `CLAUDE.md`, plus, for merging, one settings
edit that only a human can make.

| Level | Who approves plans | Who merges PRs | How to turn it on |
|---|---|---|---|
| **Manual** (default) | You | You | Nothing to do |
| **Auto-approve** | The harness, for plans matching your policy | You | Add a `## Plan auto-approval policy` section |
| **Merge autonomy** | You or your policy | The cycle, for PRs matching your policy | Add a `## Merge autonomy policy` section **and** lift the `gh pr merge` deny |
| **Autonomous mode** | The harness, within the hard floor | The cycle, for harness PRs, within the merge floor | Add a `## Autonomy mode` section with `mode: autonomous`, **and** lift the `gh pr merge` deny if you want merges |

### What autonomous mode changes

- **Plans get approved automatically** if they pass the hard floor, even if you haven't written a
  "Plan auto-approval policy". If you have written one, it still applies in full. The mode can
  only narrow your policies, never widen them.
- **Leftover plans are reconsidered on every run.** A plan posted in an earlier run that got no new
  feedback is re-checked against the floor and approved if it passes. If you removed or added the
  `plan-approved` label yourself, the harness respects that and leaves the plan alone.
- **Harness PRs get merged automatically** if they pass the merge floor, even if you haven't
  written a "Merge autonomy policy". This only happens after you lift the merge deny (step 3
  below). Dependabot and other non-harness PRs are never included.
- **The cycle becomes a serial merge train.** Each issue goes all the way through
  implement → verify → PR → CI → merge before the next branch is cut. Each issue then starts from
  a default branch that already contains the previous merge, so PRs don't pile up and conflict. If
  a PR is only held because it's behind, the train updates the branch once, waits for CI, and
  re-checks the whole floor.
- **The retry budget is configurable.** `kickback-budget:` (0–3, default 2) sets how many times a
  failed verifier review goes back to the implementer before the issue is marked `impl-blocked`.

### What it never does

These floors apply in every mode, and autonomous mode can't loosen any of them.

- **It never auto-approves a plan** that has a BLOCKING question no human has answered, is stale, overlaps another
  plan's files, touches schema or security (unless your policy explicitly opts that in), comes
  from an issue opened by someone who isn't a maintainer, or carries `no-auto-approve` or
  `test-ratchet`.
- **It never merges a PR** unless the verifier passed it (checked against three separate records),
  CI is green on the head commit, the branch contains the latest default branch, the approval still
  covers the exact plan that was built, and no maintainer comment arrived after approval.
  **"No checks configured" doesn't count as green**, so a repo without CI doesn't auto-merge.
  Autonomous mode never changes that; only a written "Merge autonomy policy" can explicitly opt a
  no-CI repo in.
- **It never merges a change to governance files:** `CLAUDE.md`, `.claude/`, `.github/`, ADRs,
  CI config, or any path you add under "Governance paths". Those always wait for you. The one
  exception is a small, append-only new entry in `.claude/LESSONS.md`, and every such merge is
  quoted in the cycle report.
- **Autonomous mode never lifts the merge deny or edits your settings files.** That switch is
  always yours.
- **It never pushes to the default branch** (a hook blocks this in every session) and never
  fixes a verifier finding itself. Fixes always go back through the implementer and get
  re-verified.
- **It never guesses when stuck.** It labels the issue `needs-human`, explains why, and moves on.

### Turn it on, step by step

1. **Make sure the rails are in place.**
   - CI runs on pull requests.
   - Branch protection on the default branch requires those checks and has "require branches to
     be up to date" turned on.
   - Your default branch doesn't auto-deploy. If it does, declare
     [Post-merge verification](#optional-post-merge-verification) so the harness confirms each
     deploy.
2. **Add the section to your repo's `CLAUDE.md`:**
   ````markdown
   ## Autonomy mode
   ```
   mode: autonomous
   kickback-budget: 2
   ```
   ````
   With only this step, the harness approves plans and builds PRs, and you still do the merging.
   That's a sensible first week. Until you do step 3, the doctor reports merge autonomy as
   `half-activated` and cycle reports show `verified, merge blocked`. That's expected.
3. **Let it merge (optional).** In `.claude/settings.json`, remove `"Bash(gh pr merge:*)"` from
   `permissions.deny`. Then add it to `permissions.allow`, either in `.claude/settings.json` (turns
   merging on for everyone) or in `.claude/settings.local.json` (this machine only, never
   committed). A deny in any settings file, including your user-level one, beats an allow
   anywhere else.
4. **Check it with the doctor.** Run `check-harness.sh`. Look for:
   - `autonomy mode: autonomous (kickback budget 2) …`
   - `merge autonomy: active (…)`. If you see `merge autonomy: half-activated` instead, a deny is
     still in place. The line names the file.
   - The doctor also warns about CI actions that aren't pinned to a commit SHA, and about branch
     protection that isn't strict.
5. **Run it unattended.** Use `/loop` or a schedule (see
   [Run it on a schedule](#run-it-on-a-schedule)), or run it headless:
   ```bash
   claude -p --permission-mode auto --permission-prompts none "run the cycle"
   ```
   With `--permission-prompts none`, a permission prompt becomes a denial instead of a stall, and
   the harness reports that denial as a `needs-human` escalation. The plugin's safety hooks still
   run.

**To turn it off**, delete the `## Autonomy mode` section, or change it to anything other than
`mode: autonomous`. To stop merges only, put `"Bash(gh pr merge:*)"` back in `permissions.deny`.
To stop a run in progress, use the [stop switch](#pause-veto-or-stop).

### Optional: post-merge verification

If merging to your default branch deploys something, add a **Post-merge verification** sub-block
under your "Merge autonomy policy" section. It lists read-only commands the cycle runs after each
merge. If one fails, merging stops for the rest of the run:

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

The harness only runs these commands and records what they report. It never approves, promotes,
or redeploys anything. Each command's first word needs a `Bash(<command>:*)` allow entry, and the
doctor names any that are missing.

### Finer-grained controls

To scope autonomy more tightly, `CLAUDE.md` can also declare an **Autonomy reserve** (paths that
always need a human), an **Autonomy decision record** (a per-issue grant label for pre-decided
work), and extra **Governance paths**. See
[the CLAUDE.md contract](#the-claudemd-contract).

---

## The CLAUDE.md contract

Your repo's `CLAUDE.md` is the harness's main input. Items 1–2 are what every repo needs. The rest
are opt-in sections. The harness looks for each one by its **exact title**. The full rules for each
item, including every hard floor, are in
[docs/reference/claude-md-contract.md](docs/reference/claude-md-contract.md).

| # | Section | Required? | What it does |
|---|---|---|---|
| 1 | Conventions & architecture | Yes | Stack, code style, patterns, security and data rules |
| 2 | Verification | Yes | The commands that define "done" (tests, lint, typecheck, build) |
| 3 | Setup command | Optional | How to install dependencies |
| 4 | `Plan auto-approval policy` | Optional | Which plans the harness may approve for you, in plain language |
| 5 | `Merge autonomy policy` | Optional | Which PRs the cycle may merge for you. Also needs the merge deny lifted. Can contain a `Post-merge verification` sub-block |
| 6 | `Test-suite ratchet policy` | Optional | Turns on the `test-ratchet` skill: names a coverage command, and the ratchet files test-only issues that always need your approval |
| 7 | `Autonomy reserve` | Optional | Path globs that autonomy may never touch without a human |
| 8 | `Autonomy decision record` | Optional | A human-applied grant label, plus the record an issue body must carry to qualify |
| 9 | `Autonomy mode` | Optional | `mode: autonomous` turns items 4 and 5 on together (see [Autonomous mode](#autonomous-mode)) |
| 10 | `Governance paths` | Optional | Extra paths the merge floor always holds for a human |

Example policy sections:

```markdown
## Plan auto-approval policy
Auto-approve plans that are size S, with no data/schema impact and no
security-sensitive risks. Everything under `payments/` requires manual approval.

## Test-suite ratchet policy
Measure with `pytest --cov=app --cov-report=term-missing`. Propose coverage work for
`app/` only. At most 1 issue per run; target 80% per file.
```

**Keep it lean.** The agents read `CLAUDE.md` at the start of every task, so describe what isn't
obvious: invariants, decisions and why you made them, and traps a newcomer would fall into. Leave
out directory tours and anything your linter already enforces. The doctor warns once the file
passes 300 lines or 20,000 bytes.

---

## Labels at a glance

`setup-labels.sh` creates all of these (the setup skills run it for you).

| Label | Applied by | Meaning |
|---|---|---|
| `plan-proposed` | harness | A plan is posted and waiting for your review |
| `plan-approved` | **you** (or an auto-approval policy) | Go ahead and build it. Remove it to halt the issue |
| `pr-open` | harness | A PR is open for this issue |
| `impl-blocked` | harness | Implementation hit a blocker. Read the comment, then remove the label to retry |
| `needs-human` | harness | The harness asked you a question and moved on. Answer it, then remove the label |
| `no-plan` | you, or the harness on follow-ups | Keep this issue out of planning |
| `no-auto-approve` | **you only** | Never auto-approve this issue's plans |
| `test-ratchet` | harness | Filed by the test ratchet. Always needs human approval |
| `multi-pr` | **you only** | This issue ships as several PRs, so keep it open when one merges |
| `triaged-held` | **you only** | A follow-up you've read and decided to park |
| `harness-stop` | **you only** | Stop switch. Any open issue carrying it stops every run |

The full label lifecycle is in [docs/reference/workflow.md](docs/reference/workflow.md#label-lifecycle).

---

## Safety model

The short version (full detail in
[docs/reference/safety-model.md](docs/reference/safety-model.md)):

- **The implementer and verifier can't touch git history or GitHub.** Plugin hooks deny their
  `git`/`gh` commands (the verifier gets a read-only `git` subset) and their `Edit`/`Write` calls
  under `.claude/`.
- **Nothing reaches the default branch directly.** Work happens on `claude/<n>-<slug>` branches.
  A hook denies any push to the default branch in every session, including yours.
- **Nothing is pushed until the verifier passes.** Before the PR's commit, the orchestrator re-runs
  your verification commands itself and checks the staged files against the implementer's report.
- **The settings template denies the dangerous commands:** merging (until you lift it), force-push,
  `reset --hard`, `git clean`, and `rm -rf`.
- **Issue and comment text is treated as data, not instructions,** and only maintainer comments
  count as feedback.
- **Every automatic decision leaves an audit comment** on the issue, and approvals are tied to the
  exact plan comment that was approved.
- **Branch protection is your real backstop.** The deny list is pattern-based, so require PRs and
  status checks on the default branch.

---

## Running on Codex

**Status: Codex CLI 0.156.1 or newer, macOS, supervised only.** Verified live at the v3.0.0
release gate (#411) — full detail in
[docs/reference/codex.md](docs/reference/codex.md) and
[ADR 0002](docs/adr/0002-codex-compatibility.md)'s amendment (3).

The recipe, in the same order the gate used:

1. Install the plugin (`codex plugin marketplace add msummer/trail-blazer-flow`, then
   `codex plugin add trail-blazer-flow@trail-blazer-flow`).
2. Run `<plugin root>/bin/codex-setup.sh` from a normal (non-sandboxed) terminal.
3. Trust the project and the plugin's hooks in Codex.
4. Start a session with `codex --no-daemon`.
5. Run `harness-setup`, then use the skills (`issue-planner`, `issue-implementer`, `issue-cycle`),
   with the differences listed below.
6. Merge every PR by hand — there is no merge autonomy on Codex — and re-run
   `bin/codex-setup.sh` after every plugin upgrade.

**What's different on Codex:**

- No merge autonomy and no Autonomy mode: every PR merge is by hand, and `gh pr merge` is
  additionally `forbidden` by the installed rules.
- No worktree-parallel mode: sessions stay sequential.
- No `codex exec` and no unattended or scheduled runs: only the interactive `codex --no-daemon`
  session is supported.
- No `project-kickoff` or standalone `test-ratchet`.

**Supported / not supported / not verified**, in short (full matrix, with reasons, in
[docs/reference/codex.md](docs/reference/codex.md#support-matrix)):

- **Supported:** Codex CLI 0.156.1+ on macOS, interactive `codex --no-daemon`, supervised.
- **Not supported:** the default TUI's managed daemon, `codex exec` and unattended runs,
  worktree-parallel mode, the merge pass and merge autonomy, Autonomy mode, `project-kickoff`, and
  standalone `test-ratchet`.
- **Not verified:** Linux, Windows, and the Codex desktop app.

---

## Updating

**Getting updates.** The settings template registers the plugin with `"autoUpdate": true`, so
Claude Code picks up each new version when a session starts (run `/reload-plugins` if it asks).
To update by hand:

```
/plugin marketplace update trail-blazer-flow
/plugin update trail-blazer-flow@trail-blazer-flow
```

**`autoUpdate` is a trust choice.** It means taking the latest release without reviewing it
first. If you'd rather check updates yourself, set `"autoUpdate": false` in
`.claude/settings.json`, and use the published `vX.Y.Z` tags as known-good points to compare
against or roll back to. Plans, verdict comments, PR bodies, and cycle reports all record the
plugin `<version> <sha>` that produced them (`harness-version.sh` prints the installed one).

### Updating an already-onboarded repo (per-repo migration)

An update replaces the plugin everywhere, but the files in your repo (labels, permissions,
baseline) don't update themselves. **After any update, run:**

```bash
check-harness.sh
```

It lists what the new version needs that your repo is missing. Fix what it flags and you're done.

<details>
<summary>Per-version migration notes (v1.9.0 → v3.0.0)</summary>

For older history, see `CHANGELOG.md`'s archive (the "README.md: per-repo migration notes, v1.9.0
to v2.7.7" subsection).

**v1.9.0 → v2.2.0** — add grants `"Bash(gh auth status:*)"` and `"Bash(gh pr edit:*)"`: re-copy
the permissions block from `templates/repo-settings.json`, or add both by hand.

**v2.2.0 → v2.3.0** needs no grant, label, script, or baseline step — sharper doctor checks and a
branch-keyed verifier verdict under merge autonomy.

**v2.3.0 → v2.4.0** — settings step: delete the nine legacy `Bash(git -C * <sub> *)` allow entries
(or re-copy the permissions block from `templates/repo-settings.json`). Prerequisite: Claude Code
**2.1.85+**.

**v2.4.0 → v2.5.0** needs no grant, label, script, or baseline step — comment- and issue-author
provenance, and plan-binding approval provenance, both narrow what runs unattended.

**v2.5.0 → v2.5.1** needs no grant, label, script, or baseline step — fixes a live
approval-binding bug; upgrade promptly.

**v2.5.1 → v2.5.2** needs no grant, label, script, or baseline step — fixes a live
auto-approval bug; upgrade promptly if you run a "Plan auto-approval policy".

**v2.5.2 → v2.6.0** needs no grant, label, script, or baseline step — approval now also binds to
the plan comment's own edit state.

**v2.6.0 → v2.6.1** needs no grant, label, script, or baseline step — approval now also requires
`plan-approved` to be currently on the issue; re-approving releases a held PR under merge autonomy.

**v2.6.1 → v2.7.0** — re-run `bin/setup-labels.sh` (creates `multi-pr`); re-copy the permissions
block from `templates/repo-settings.json` (adds `"Bash(harness-lock.sh:*)"` and
`"Bash(harness-version.sh:*)"`); one-time: apply `multi-pr` by hand to any open issue that relied
on the issue-body `<!-- harness-multi-pr -->` marker.

**v2.7.0 → v2.7.1** needs no grant, label, script, settings entry, or baseline step —
`hooks/push-guard.sh` now blocks in-session default-branch pushes.

**v2.7.1 → v2.7.2** needs no grant, label, script, settings entry, or baseline step.

**v2.7.2 → v2.7.3** needs no grant, label, script, settings entry, or baseline step.

**v2.7.3 → v2.7.4** needs no grant, label, script, settings entry, or baseline step.

**v2.7.4 → v2.7.5** — one-time migration, for open issues an older harness version filed as
follow-ups (skip if none are returned):

```bash
gh issue list --search "is:open is:issue label:no-auto-approve" --json number,body --limit 200 \
  --jq '.[] | select(.body | startswith("<!-- harness-follow-up:")) | .number'
# then, per issue number printed above:
gh issue edit <n> --add-label no-plan --remove-label no-auto-approve
```

`--limit 200` caps the listing at 200 results — gh's own default is 30 — so a repo with more than
200 such issues open at once should raise the limit and run it again. Re-running
`bin/setup-labels.sh` is optional (it only refreshes the `no-auto-approve` label's description).

**v2.7.5 → v2.7.6** — re-run `bin/setup-labels.sh` (creates `needs-human` and `harness-stop`);
re-copy the permissions block from `templates/repo-settings.json` or add
`"Bash(harness-stop.sh:*)"` by hand.

**v2.7.6 → v2.7.7** — re-run `bin/setup-labels.sh` (creates `triaged-held`); one-time: label
already-parked follow-ups `triaged-held` by hand. Precondition: your provider must serve
`claude-opus-5-5` (#358); otherwise stay on v2.7.6.

**v2.7.7 → v2.8.0** — re-copy the permissions block from `templates/repo-settings.json` or add
`"Bash(governance-paths.sh:*)"` and `"Bash(gh pr update-branch:*)"` by hand.

**v2.8.0 → v2.9.0** needs no grant, label, script, or baseline step — stricter subagent
hooks, reopened-issue fixes, and quiet retry of a stalled planner dispatch.

**v2.9.0 → v3.0.0** — re-copy the permissions block from `templates/repo-settings.json` or add
`"Bash(codex-setup.sh:*)"` by hand.

</details>

**Rolling back.** The published `vX.Y.Z` tags are the known-good points (`git show
vX.Y.Z:.claude-plugin/plugin.json` shows what shipped). Repo-side additions such as the
`Bash(codex-setup.sh:*)` grant can stay after rolling back a version: the doctor treats
repo-only allow entries as legitimate extras. Claude Code's own plugin installer tracks this
repo's `main` branch, so there's no documented command to pin it to an older tag; to run an older
version for one session, clone the repo at the target tag and start that session with
`claude --plugin-dir <path to that checkout>` (see `claude --help`). To leave the Codex layer
entirely, see [docs/reference/codex.md](docs/reference/codex.md#removing-the-codex-layer)'s
"Removing the Codex layer".

---

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| A subagent stalls or a step is denied | A permission grant is missing. Run `check-harness.sh`, which names the exact `Bash(...)` entry to add |
| A run aborts because the lock is held | Another session holds the checkout's lock. `harness-lock.sh status` shows who holds it. If that session is gone, run `harness-lock.sh release --force` |
| A run stops with a red baseline | Your default branch is failing its own verification commands. Fix `main` first, because the harness won't build on a broken base |
| The cycle never merges anything | Run `check-harness.sh`. The usual causes are `merge autonomy: half-activated` (the deny is still in place), no CI on the repo, or a PR that touches governance files |
| A plan you commented on wasn't revised | Only owner, member, and collaborator comments count as feedback, and only issues still labelled `plan-proposed` get revised |
| `check-harness.sh: command not found` | The plugin isn't enabled in this session, or (on Windows) its `bin/` isn't on the Bash PATH. See below |

### Windows

The automation layer is Bash plus `gh` and `jq`, so run Claude Code under **Git Bash or WSL**.
There is no native cmd or PowerShell path. Install `gh` and `jq` so they're on the *Bash* PATH you
launch Claude Code from (for example `winget install GitHub.cli jqlang.jq`, or scoop/choco). This
repo ships a `.gitattributes` that pins `*.sh` to LF line endings, so Git for Windows can't corrupt
the scripts.

- **WSL is its own machine.** `gh` inside WSL has its own credential store, so run
  `gh auth login` there even if the Windows-side `gh` is already authenticated. Keep repos in the
  WSL filesystem (`~/...`), not under `/mnt/c/...`. Repos mounted from NTFS are much slower and
  bring back the exec-bit and line-ending quirks the harness otherwise avoids.
- **Use forward-slash paths** in anything that reaches a Bash command. Git Bash accepts
  `C:/Users/...` and `/c/Users/...`, but backslash paths get mangled by quoting. Python venvs on
  Windows put the interpreter at `.venv/Scripts/python.exe`, not `.venv/bin/python`.
- **The doctor's exec-bit check is informational on Windows.** NTFS has no POSIX exec bit, and
  Git Bash runs the scripts through their shebang.
- **Check that the hooks fire.** `hooks/hooks.json` runs each hook as
  `bash "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh"`. If Claude Code ever exported that variable with
  backslashes, a hook could silently fail to run. For `git-c-guard.sh` that's harmless (you'd see
  permission prompts). For `agent-boundary.sh`, `push-guard.sh`, `claude-dir-guard.sh`, and
  `planner-guard.sh` it would silently remove a safety boundary. Spot-check this before relying on
  unattended runs on Windows. The live probes in the [safety model](docs/reference/safety-model.md)
  covered macOS only.

**First-run smoke test (30 seconds, from Git Bash or WSL, in any git repo):**

1. Confirm the toolchain is on the Bash PATH:
   ```bash
   bash --version && gh --version && jq --version && gh auth status
   ```
2. Run the doctor by **bare name**. This tests both the PATH and the line endings:
   ```bash
   check-harness.sh
   ```

- **A `== harness doctor ==` PASS/WARN/FAIL table prints:** both risks are clear. Any remaining
  WARN or FAIL items are normal setup, not Windows problems.
- **`check-harness.sh: command not found`:** Claude Code didn't put the plugin's `bin/` on the Bash
  PATH. As a fallback, run `bash "$CLAUDE_PLUGIN_ROOT/bin/check-harness.sh"`. That won't match the
  bare-name permission entries, so expect prompts, and please
  [report it](https://github.com/msummer/trail-blazer-flow/issues).
- **`bad interpreter` / `$'\r': command not found`:** a copy with CRLF line endings slipped
  through. Run `git config --global core.autocrlf input`, then reinstall the plugin.

---

## Reference documentation

This README is the guide. The detailed spec, meaning every mechanism, guarantee, and known limit,
lives in [`docs/reference/`](docs/reference/README.md):

- [How the workflow works](docs/reference/workflow.md): each stage in depth, resilience and
  retries, working from the phone, the stop switch, and the label lifecycle
- [The CLAUDE.md contract](docs/reference/claude-md-contract.md): every section and its hard
  floor, plus `LESSONS.md` and `BASELINE.md`
- [The per-repo settings file](docs/reference/settings.md): every grant and deny
- [Safety model](docs/reference/safety-model.md): hooks, provenance, trust gates, and the lock
- [Architecture](docs/reference/architecture.md): repo layout, model tiering, and distribution
- [Codex compatibility](docs/reference/codex.md): running this plugin on the Codex CLI —
  `codex-setup.sh`, the rules file, contract loading, the support matrix, removing the Codex
  layer, and the honest limits
- [Decision records](docs/adr/README.md): where the harness is heading
- [`CHANGELOG.md`](CHANGELOG.md): per-PR history

---

## Working on the harness itself

This repo **is** the plugin and its own marketplace (`.claude-plugin/plugin.json` +
`marketplace.json`). Its root `CLAUDE.md` governs changes to the harness's own agents, skills,
scripts, and docs. That's a separate audience from the `CLAUDE.md` contract above, which is what
the harness expects of a *consumer* repo. Nothing project-specific belongs in `agents/` or
`skills/`. That content belongs in a consumer repo's `CLAUDE.md` or `LESSONS.md` instead (see
[Distribution](docs/reference/architecture.md#distribution)).

The gate is one command, run from the repo root:

```bash
bash dev/selfcheck.sh
```

It prints a `PASS`/`FAIL` line per assertion and a `== summary: N pass, M fail ==` footer. There's
no build step: this repo is Markdown instruction files, Bash scripts, and JSON manifests. The gate
and its eight negative-test harnesses (`dev/selfcheck-tests.sh`, `dev/doctor-tests.sh`,
`dev/hook-tests.sh`, `dev/cleanup-tests.sh`, `dev/planning-tests.sh`, `dev/lock-tests.sh`,
`dev/stop-tests.sh`, and `dev/mutant-driver-tests.sh`) all run in CI on every pull request on
ubuntu, and again under Apple's bash 3.2 on macOS after each merge to `main` and nightly.
`dev/mutant-driver.sh`, which re-runs every `dev/mutants/*.json` record, runs only post-merge on
`main`, nightly, and on manual dispatch. This repo's `CLAUDE.md` "Verification" section lists the
exact commands and jobs.

This repo deliberately does **not** aim to pass `bin/check-harness.sh`, the *consumer* doctor.
Onboarding it here would mean checking in a `.claude/settings.json` that registers this repo's own
published marketplace (with `autoUpdate: true`) and enables a cached copy of itself over the
working tree being edited.

### Releasing a new version

The plugin uses semantic versioning (the `version` field in `.claude-plugin/plugin.json`):

```bash
# 1. bump "version" in .claude-plugin/plugin.json (e.g. 1.1.0 -> 1.2.0)
# 2. retitle CHANGELOG.md's "## Unreleased" heading to "## vX.Y.Z"
git commit -am "Release vX.Y.Z: <summary>"
git tag -a vX.Y.Z -m "trail-blazer-flow vX.Y.Z"   # match the version field exactly
git push origin main
git push origin vX.Y.Z
```

`hooks/push-guard.sh` denies the `git push origin main` step from inside a Claude Code session with
the plugin enabled. Run the ritual from a plain terminal, or ship the release through a
`release/vX.Y.Z` PR instead. The tag push is unaffected. The `version` field on the default branch
is what actually drives updates. The annotated tag is an immutable anchor for rollback, bisecting,
and pinning, so always tag in the same step as the bump. (`main` is branch-protected:
collaborators land changes by pull request, and the maintainer pushes directly through admin
bypass. Force-pushes and branch deletion are blocked for everyone.)

### Roadmap

- **Decided direction** lives in [`docs/adr/`](docs/adr/README.md).
  [ADR 0001 (Autonomy mode)](docs/adr/0001-autonomy-mode.md) is fully shipped as of v2.8.0 (#307–#313).
  [ADR 0002 (Codex compatibility)](docs/adr/0002-codex-compatibility.md), running the harness under
  OpenAI Codex, ships supervised only in v3.0.0, on the Codex CLI on macOS (see
  [Running on Codex](#running-on-codex)); unattended runs (slice iv) and the provider-neutral
  rename remain future work.
- **Parallel-mode ergonomics:** worktree-parallel mode (up to 4 implementers at once on issues
  whose files don't overlap) is currently gated on comparing Affected areas by hand. A small script
  that diffs two plans' file lists could make the eligibility check mechanical. The final batching
  call would stay with the orchestrator.

---

## License

[MIT](LICENSE) © 2026 Mark Summer. You're free to use, modify, and redistribute it. Please keep the
copyright notice. It's provided as-is, without warranty; see the `LICENSE` file for the full text.
