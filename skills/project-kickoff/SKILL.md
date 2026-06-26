---
name: project-kickoff
description: >
  Kicks off a brand-new project from scratch onto the issue workflow harness. Use when the
  user wants to "start a new project", "set up a new project from scratch", "kick off a
  project", or says "I want to build ..." in an empty or near-empty repo. Interviews the user
  to capture the vision (document-first if they have one, a fuller interview if they don't),
  helps them settle on scope, architecture, and methodology, then emits the artifacts the rest
  of the harness consumes: a project brief, a drafted CLAUDE.md, a connected GitHub repo, and
  an initial issue backlog whose first item is a walking skeleton. Greenfield only — for an
  existing codebase use harness-setup. Never writes feature code; never commits without approval.
---

# Project Kickoff

This is the **front door** for a project that does not exist yet. The rest of the harness eats
**GitHub issues** and reads **CLAUDE.md**; this skill is what produces the first of each. It
turns a person with an idea into a connected repo with a drafted `CLAUDE.md`, a project brief,
and a small, well-scoped issue backlog — at which point `issue-planner` → `issue-implementer`
takes over. In the harness's terms, this skill **blazes the trail** the other skills then follow.

You (the main session) do everything here yourself — no subagent dispatches. You are the most
capable model in the stack, and kickoff is pure judgment work: drawing out the vision, proposing
an architecture, and right-sizing the first slice of work. Lean into being **opinionated** — the
user wants help *settling* on an approach, not a stenographer.

## What this skill produces (the definition of done)

1. A **Project Brief** at `docs/PROJECT-BRIEF.md` — vision, users, scope, non-goals, key
   decisions **with their rationale** (ADR-style, so the *why* survives context compaction).
2. A **drafted `CLAUDE.md`** — conventions, architecture, and the verification commands that
   will define "done" (often aspirational until the skeleton exists — see the scaffold issue).
3. A **connected GitHub repo** — created or selected with the user, labels installed, a thin
   `.claude/settings.json` laid down from the plugin template.
4. An **initial issue backlog** — a focused, vertically-sliced set whose **first issue is a
   walking skeleton** (project skeleton + the verification setup that makes the baseline green).

It does **not** write feature code, and it does **not** establish the green verification
baseline — there is no buildable code yet. That baseline is `harness-setup`'s job, run *after*
the scaffold issue is implemented (see "Handoff").

## Guiding principles

- **Document-first, but never blocked on one.** If the user has a PRD, brief, notes, or a
  doc/link, ingest it and only ask about genuine *gaps*. If they have nothing, the interview
  carries the full load — that's expected, just go deeper.
- **Thorough but not exhausting.** Cover every load-bearing area, but lead with one open prompt
  for the vision, then **batch** targeted questions (AskUserQuestion, recommendation-first) and
  **adapt depth to the project** — a CRUD app does not need distributed-systems questions. Never
  ask one trivial question per turn.
- **Suggest voice.** Early in the intake, tell the user they can **dictate** answers (voice
  input) for the open-ended parts instead of typing — it removes most of the friction of a
  thorough interview. Remind them again before any large open question.
- **Decide now vs. defer.** Reuse the harness idiom: tag every unresolved item BLOCKING (must
  settle before issues can be written), ADVISORY (a stated default the user can accept), or
  DEFERRED (a real choice that belongs to a future issue, not kickoff). Keeps kickoff short.
- **One review gate.** Synthesize, then present the brief + proposed architecture + the issue
  list for a **single approval**. Iterate until approved. Create nothing on GitHub before then.

## Procedure

### 0. Orient (is this the right skill?)

Confirm the repo is greenfield: an empty or near-empty working tree (no real source beyond
scaffolding, config, or this plugin's files). If there is already a substantial codebase, **stop
and redirect**: kickoff is for new projects; for an existing repo the user wants `harness-setup`
(onboarding) and then `issue-planner`.

Check for **prior kickoff progress** so a multi-session kickoff resumes instead of restarting:
does `docs/PROJECT-BRIEF.md` exist? a `CLAUDE.md`? a remote? open issues? If so, summarise what's
already done and pick up from the first incomplete step rather than re-interviewing.

### 1. Intake

Ask the user to share whatever they already have — a PRD, a one-pager, rough notes, a Google
Doc / Notion link, or just a few sentences. **Tell them they can dictate it by voice** rather
than typing. Ingest anything they provide (read the file/link) and extract: problem, users,
features, constraints, any tech preferences. Restate back the gist in a sentence or two so they
can correct course early. If they have nothing, say so is fine — the interview just goes deeper.

### 2. Interview (adaptive, batched)

Cover the areas below. **Skip what the intake already answered**; **batch related questions**
into single AskUserQuestion calls with recommendation-first options; **drill deeper only where
this project is high-stakes or genuinely ambiguous.** Aim for a handful of batched rounds, not
dozens of turns.

1. **Problem & vision** — what is being built and why; what changes for whom if it succeeds.
   (Open prompt — invite voice. This one is worth getting in the user's own words.)
2. **Users & core journeys** — who uses it; the 1–3 primary flows that define the product.
3. **Scope** — the MVP / first milestone vs. later; **explicit non-goals** (what it is *not*).
4. **Key features** — the functional must-haves for the first milestone.
5. **Non-functional needs** — expected scale, performance, security/privacy/compliance,
   availability — only those that actually shape the architecture.
6. **Tech context & preferences** — preferred language/stack/framework (or "you choose");
   systems to integrate with; data to store; **hosting/deployment target**.
7. **Constraints** — timeline/milestones, team size & experience, budget, licensing.
8. **Methodology expectations** — how work should proceed: issue granularity, testing
   expectations, CI, what "done" means. (Feeds CLAUDE.md's verification section.)

As you go, record each open point as BLOCKING / ADVISORY / DEFERRED. You don't need every
answer to be the user's — where you have a well-grounded recommendation, **propose it** as the
default and let them accept or override.

### 3. Synthesize & propose (the judgment payload)

This is where you earn your place in the stack. Produce, in the chat for review:

- **A Project Brief** — vision, users, core journeys, in-scope vs. non-goals, key requirements,
  constraints.
- **A proposed architecture & stack** — opinionated, with **rationale and the trade-offs you
  weighed** (and the credible alternatives you rejected and why). Match ambition to the
  constraints — pick boring, proven defaults unless a requirement demands otherwise.
- **A methodology** — branching/PR flow (the harness's: issue → plan → PR → human merge),
  testing approach, and what the verification commands will be once the skeleton exists.
- **The proposed issue backlog** — see step 5 for shape. Show the list (titles + one-line
  scope each) so the user approves the *plan of work*, not just the prose.

Present all of it together and ask for approval. Iterate on feedback. **Do not create the repo
or any issues until the user approves.** Surface any remaining BLOCKING items explicitly — they
must be resolved here, because the backlog is written against these decisions.

### 4. Connect GitHub

Once the brief is approved, get the project onto GitHub:

```bash
gh auth status          # if not authenticated, ask the user to run:  ! gh auth login
```

Then, **with the user**, establish the repo:

- **New repo:** confirm name, visibility (private by default unless they say otherwise), and
  owner/org, then `gh repo create <name> --private --source . --remote origin` (initialise local
  git first with `git init` + an initial commit if the directory isn't a repo yet). Confirm the
  default branch name.
- **Existing empty repo:** confirm which one (`gh repo list`), wire it up as `origin` if it
  isn't already, and verify it has no conflicting content.

Repo-creation and auth commands are interactive and the human is present, so a permission prompt
here is fine — don't pre-empt it. Confirm the resulting `nameWithOwner` and default branch back
to the user before continuing.

### 5. Lay down the harness + emit artifacts

Now write the project-side files (all project-owned — leave them in the working tree for the
user to review and commit; **never commit or push without explicit approval**):

1. **`.claude/settings.json`** — copy the plugin's `templates/repo-settings.json` (permission
   grants + marketplace + `enabledPlugins`). Add any toolchain entry the chosen stack needs that
   the template lacks (e.g. `Bash(cargo:*)`, `Bash(go:*)`). This is the file a clone needs to
   bootstrap the plugin; it must be committed (by the user).
2. **Labels:** `setup-labels.sh` (creates the lifecycle labels the planner/implementer use).
3. **`docs/PROJECT-BRIEF.md`** — the approved brief, including the key decisions and their
   rationale. This is the human-facing source of truth for *why*.
4. **`CLAUDE.md`** — drafted from the brief: conventions, architecture, and a **Verification**
   section. If the chosen stack's exact commands aren't pinned until the skeleton exists, state
   the intended commands and note that the walking-skeleton issue establishes and verifies them.
   Reference `docs/PROJECT-BRIEF.md` for product context.
5. **The issue backlog** (`gh issue create`, in dependency order). Shape:
   - **Issue #1 is the walking skeleton:** stand up the project skeleton, wire the toolchain,
     and make a thin end-to-end slice (e.g. "app boots / one endpoint returns / one test runs")
     **with the verification commands green**. Its acceptance criteria are what turns
     `CLAUDE.md`'s Verification section from aspirational into real. Everything else can depend
     on it.
   - **Then a focused first milestone** — vertically-sliced issues (each a usable increment, not
     a horizontal layer), sized roughly S/M/L, each with a short problem statement and
     acceptance criteria a planner can act on. **Resist over-producing** — a tight first slice
     beats a 40-issue waterfall; later work can be filed as the project takes shape.
   - Leave them **unlabelled** (`issue-planner` picks up anything without a `plan-*` label).
     Note any cross-issue dependencies in the issue bodies.

Then run the doctor to confirm the mechanics:

```bash
check-harness.sh
```

It should pass except the verification-baseline-related items, which are expected to be
outstanding until the skeleton is built.

### 6. Handoff

Tell the user the exact next steps and **why this order**:

1. **`issue-planner`** on issue #1 (the walking skeleton) → review/approve the plan →
   **`issue-implementer`** → review/merge the PR. Now there is buildable code.
2. **`harness-setup`** — audits the now-real `CLAUDE.md` against the actual scaffold and records
   the **green verification baseline** (which couldn't exist before there was code).
3. **`issue-planner`** on the rest of the backlog → the normal plan → implement → merge loop.

Close with a one-line readiness statement: the repo is connected, the brief and CLAUDE.md are
drafted (pending the user's commit), and the backlog is filed — ready for planning.

## Rules

- **Greenfield only.** If a real codebase already exists, redirect to `harness-setup`.
- **Never write feature code.** Kickoff produces understanding, decisions, and issues — not
  implementation. The walking skeleton is built later, through the normal pipeline.
- **One human gate before GitHub.** Nothing is created on GitHub (repo, issues) until the user
  approves the synthesized brief, architecture, and backlog.
- **Never commit or push without explicit approval.** Project-owned files (`CLAUDE.md`,
  `docs/PROJECT-BRIEF.md`, `.claude/settings.json`) are left in the working tree for the user to
  review and commit. Repo *creation* and *issue* creation are the user-approved GitHub actions.
- **Nothing project-specific goes into the toolset files** (this skill, the agents, the plugin).
  Everything you learn about the project lands in `CLAUDE.md`, `docs/PROJECT-BRIEF.md`, or the
  issues — the same boundary every other skill respects.
- **Streamline relentlessly.** Batch questions, propose defaults, suggest voice input, skip what
  the intake answered, and defer choices that belong to a future issue. A kickoff that feels
  like an interrogation is a failed kickoff.
