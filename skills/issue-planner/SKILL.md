---
name: issue-planner
description: >
  Generates and revises implementation plans for open GitHub issues in this repo. Use when
  the user asks to "plan the issues", "run the planner", "draft plans for new issues", or
  similar. Finds open issues that need an initial plan (no plan-* label) or a revision (a
  plan-proposed issue with feedback comments posted after the latest plan), dispatches a
  read-only `planner` subagent for each, then posts each plan as an issue comment and sets
  labels. Planning only — it never writes code or implements anything.
---

# Issue Planner

This skill turns GitHub issues into review-ready implementation plans. It is the **planning**
half of the workflow; implementation is a separate, later step. You (the main session) act as
the orchestrator: you handle all GitHub I/O, and you delegate the actual plan-writing to the
read-only `planner` subagent (the plugin's `agents/planner.md`), one dispatch per issue.

## The label state machine

| State | Label | Meaning | Who sets it |
|-------|-------|---------|-------------|
| Needs initial plan | *(no plan-* label)* | New issue, never planned | — |
| Awaiting review | `plan-proposed` | Plan posted; waiting on human | this skill |
| Approved | `plan-approved` | Ready for the implementer | human, or this skill via the auto-approval policy (step 6) |
| Opted out | `no-plan` | Planner ignores this issue entirely (tracking/discussion/question) | human |
| Manual approval only | `no-auto-approve` | This issue's plans are never auto-approved, even under a CLAUDE.md policy | human |

**Requesting changes is comment-driven, not label-driven.** To ask for a revision, the human
simply comments on the issue. On the next run, any `plan-proposed` issue with a comment posted
*after* its latest plan is treated as having unaddressed feedback and is revised. To approve,
the human adds `plan-approved` — or, if the repo's CLAUDE.md defines a **plan auto-approval
policy**, this skill may add it for plans that clear both the policy and the non-negotiable
hard floor (step 6). Two known limits of feedback detection, worth telling users who hit them:
edits to the issue *body* are not detected (comment instead — or comment "revise against the
updated description"), and comments posted after `plan-approved` was added are not treated as
plan feedback (the implementer reads them as thread context instead).

**Approval semantics for open questions.** Plans tag each open question BLOCKING or ADVISORY
(advisory questions carry a recommended default inline). Approving a plan whose questions are
all ADVISORY accepts the stated defaults — no extra revision round is needed; the orchestrator
passes those defaults to the implementer as resolved decisions. A plan with unanswered BLOCKING
questions should not be approved until they're answered (via comment → revision, or via the
proposed-answers step below).

Plan comments are tagged with an HTML marker, `<!-- planner-plan -->`, at the top. That marker
is how both this skill and the discovery script tell plan comments apart from feedback comments
(everything is posted by the same gh user, so author can't be the discriminator).

## Prerequisites (check once)

- `gh` is installed and authenticated (`gh auth status`). If not, stop and tell the user.
- `jq` is installed.
- Note: the harness scripts (`*.sh` commands below) are provided on the Bash PATH by the plugin's `bin/` directory.
- The lifecycle labels exist. If a label-related command fails, run
  `setup-labels.sh` once, then continue.

## Project lessons (inject into every dispatch)

If the project has a `.claude/LESSONS.md`, include its relevant entries verbatim in every
`planner` subagent prompt (initial plans and revisions alike). It records project-specific traps
— fixture contracts, CI quirks, naming conventions — that subagents repeatedly trip over. The
file is owned by the project, not by this toolset. When you (the orchestrator) learn such a
lesson during a run — a wrong premise a revision had to correct, a fact every plan needs —
append it: 1–3 lines, dated, written as an instruction to a future agent.

## Procedure

### 0. Pre-flight: sync & hygiene

Plans must be written against current code, and the queue state must be clean before you read
it:

```bash
cleanup-after-merge.sh --fix
```

This fast-forwards the default branch (when checked out), prunes local `claude/*` branches
whose PRs merged, and repairs stale `pr-open` labels (each fix is audited with an issue
comment). Then make sure the planner subagents will explore current code:

- **Clean tree, not on the default branch** → check out the default branch and `git pull
  --ff-only` (mention the switch in your summary).
- **Dirty tree** → do NOT switch branches or touch the changes. Proceed on the current
  checkout, and caveat the summary: plans may be written against drifted code. (Changes to
  `.claude/LESSONS.md` alone don't count as dirty — that's harness bookkeeping awaiting its
  next commit.)

### 1. Find the work

Run:

```bash
find-planning-work.sh
```

This returns JSON with `needs_initial_plan` and `needs_revision` arrays (each item has
`number`, `title`, `url`) and a `counts` object. The script has already done the
feedback-after-latest-plan detection, so `needs_revision` contains only issues with genuine
unaddressed feedback.

**Report the findings to the user before doing anything else** — list the issue numbers and
titles in each bucket. If both buckets are empty, say so and stop.

### 2. For each issue needing an INITIAL plan

a. Fetch the full issue:
```bash
gh issue view <number> --json number,title,body,url,labels
```

b. Dispatch the **`planner` subagent** (via the Task tool) with a prompt containing the issue
   number, title, and body, relevant `.claude/LESSONS.md` entries, and this instruction:
   *"Produce an implementation plan for this issue following your output template. This is an
   initial plan (no prior feedback)."* Let the subagent explore the codebase and return the
   plan. If you (the orchestrator) hold context the issue lacks — recently merged PRs that
   changed the files it names, corrected measurements, related pending plans — put it in the
   prompt with a note that line numbers/claims in the issue may be stale and must be verified.

c. Post the returned plan as an issue comment. Write the plan body to a temp file first to
   avoid shell-quoting problems, then:
```bash
gh issue comment <number> --body-file <tempfile>
```
   The comment body must be exactly:
```
<!-- planner-plan -->
## 🤖 Implementation plan

<the subagent's plan>

---
*To request changes, just reply with a comment — the planner will revise on its next run.
To accept, add the `plan-approved` label.*
```

d. Add the awaiting-review label:
```bash
gh issue edit <number> --add-label plan-proposed
```

### 3. For each issue needing a REVISION

a. Fetch the issue with its full comment thread:
```bash
gh issue view <number> --json number,title,body,url,labels,comments
```

b. Identify (i) the **most recent prior plan** — the last comment whose body contains the
   `<!-- planner-plan -->` marker — and (ii) the **feedback** — every comment posted *after*
   that plan that does NOT contain the marker.

c. Dispatch the **`planner` subagent** with a prompt containing: the issue title and body, the
   prior plan, the feedback comments, and relevant `.claude/LESSONS.md` entries, plus the
   instruction: *"This is a REVISION. Address every point of feedback. Begin with a short 'What
   changed since the last plan' note, then give the full revised plan following your template.
   Treat the feedback's decisions as binding but verify its factual claims against the live
   code. The revised plan must be self-contained."*

d. Post the revised plan as a new comment, using the same marker and format as step 2c.

e. **No label change is needed** — the issue is already `plan-proposed` and stays there. Posting
   the new plan makes it the latest plan comment, so the same feedback won't re-trigger on the
   next run. (Do NOT add `plan-approved`; that's the human's decision.)

### 4. Stale and overlapping plans (active hygiene)

**Handle stale plans, don't just report them.** For each *other* pending plan (`plan-proposed` /
`plan-approved` issues you did not just touch), check whether PRs merged since that plan was
posted changed files in its "Affected areas" (compare the plan comment's timestamp against
`gh pr list --state merged --json mergedAt,files,number,title --limit 30`, or spot-check the
obvious recent merges). A plan written against code that has since changed may cite stale line
numbers or vanished functions. When you find one:

- **`plan-proposed` and stale** → post a normal comment (no marker) naming the merged PRs and
  the affected files, e.g. *"Staleness note: PRs #12 and #14 merged after this plan and changed
  `api/routes.py`, which this plan's Affected areas names. Revising."* — then treat the issue as
  needing a revision **in this same run** (the comment is the feedback; dispatch per step 3).
- **`plan-approved` and stale** → post the same staleness comment but do NOT revise (the human
  approved *that* plan; a revision would need re-approval). Flag it prominently in the summary
  so the human decides: implement anyway (the implementer's standing drift caveat covers small
  drift) or pull the approval and ask for a revision.

**Flag overlapping plans.** Compare the "Affected areas" sections of the plans you just posted —
against each other and against any other pending plans (`plan-proposed` / `plan-approved`
issues). If two plans touch the same files, say so in the summary: the implementer cuts every
branch from the default branch, so overlapping changes will conflict at PR time, and the human
may want to approve and merge them one at a time. Overlap also disqualifies a plan from
auto-approval (step 6) — sequencing overlapping work is a human call.

### 5. Propose answers and revise (orchestrator judgment step)

For each plan just posted or revised whose open questions include **BLOCKING** items, resolve
what you can yourself — this step is deliberately yours, not the subagent's: you are the most
capable model in the stack, and resolving ambiguity well *before* the smaller implementer model
sees it is the cheapest quality lever in the workflow. (Plans whose questions are all ADVISORY
need nothing here: approving accepts the stated defaults.)

a. **Draft proposed answers, grounded in evidence.** Verify the plan's (and the issue's)
   load-bearing claims against the code rather than taking them on faith; where a number
   matters, measure it (e.g. a quick script) instead of estimating. State corrections
   prominently. A question you cannot ground in code or measurements stays open for the human —
   say so rather than guessing.

b. **Post the answers as a normal issue comment** (no `<!-- planner-plan -->` marker), so the
   thread shows where each decision came from.

c. **Revise immediately (same run).** For every question you could answer, re-dispatch the
   `planner` subagent per step 3, treating your posted answers as the feedback, with this
   addition to the instruction: *"Fold each proposed answer in as a decision tagged `RESOLVED
   (orchestrator-proposed):` so reviewers can see its provenance. Questions the answers did not
   cover remain open questions."* Post the revised plan (step 2c format). The human now reviews
   ONE artifact — the revised plan with visible provenance — instead of an answers comment plus
   a later revision.

If you could answer none of the BLOCKING questions, leave the plan as posted; the open
questions are exactly the feedback the human needs to provide.

### 6. Auto-approval (policy-gated)

Read the repo's `CLAUDE.md` for a section titled **"Plan auto-approval policy"**. If there is
no such section, skip this step — every approval is the human's. If there is one, evaluate each
plan you posted or revised **this run** against BOTH of the following. The policy can loosen
nothing in the hard floor; it can only add conditions.

**Hard floor (non-negotiable, regardless of what the policy says):**
- the issue does NOT carry the `no-auto-approve` label;
- the plan has **zero unanswered BLOCKING questions** — and zero BLOCKING questions resolved by
  `RESOLVED (orchestrator-proposed):` decisions (you may not approve your own answers; those
  plans always wait for a human);
- the plan is not stale (step 4) and does not overlap another pending plan's Affected areas;
- the plan's "Data / schema impact" is "None" **unless** the policy explicitly opts schema work
  in;
- the plan's "Risks & considerations" flags nothing security-sensitive (auth, permissions,
  secrets, data access) **unless** the policy explicitly opts such work in.

**Policy conditions:** whatever the CLAUDE.md section states — typically a max size (e.g. "S
only"), allowed areas, excluded paths. Judge them honestly against the plan; when a condition
is ambiguous, the answer is no.

If everything passes: add the label and leave an audit trail —

```bash
gh issue edit <number> --add-label plan-approved
gh issue comment <number> --body-file <tempfile>
```

The audit comment (normal comment, no marker) must state: that this was an auto-approval under
the CLAUDE.md policy; which policy conditions it satisfied (one line); and how to veto — remove
`plan-approved`, and add `no-auto-approve` to keep this issue manual in future. Include the
warning: *"An auto-approved plan may be implemented in the same run — the PR review is your
gate for this work."*

In the summary, list auto-approved plans in their own group; they are the ones the human never
saw pre-implementation.

### 7. Summarise

Report a short table of what you did: issue number, title, action (planned / revised /
auto-revised with proposed answers / auto-approved), the comment URL, and the open-question
count split BLOCKING / ADVISORY. Note any issues you skipped and why, any stale or overlapping
plans and what you did about them, and whether discovery reported `truncated: true` (more
issues exist than the query limit returned — run again after this batch). Plans whose questions
are all ADVISORY can be approved as-is (the defaults are accepted); say so explicitly so the
human doesn't assume another round is needed.

## Rules

- **You never write code or modify the working tree in this skill.** Planning only. (The
  pre-flight's branch sync and the cleanup script's label fixes are the only mutations, and
  they never touch file contents.)
- **One subagent dispatch per issue.** You may dispatch several in parallel if there are
  multiple issues; each runs in its own context. Keep each subagent's prompt scoped to its
  one issue.
- **The subagent writes the plan; you do all `gh` calls.** The subagent is read-only and cannot
  post to GitHub.
- **`plan-approved` is set by the human — or by step 6's policy path, never otherwise.** No
  CLAUDE.md policy section ⇒ no auto-approval, full stop. The hard floor is not negotiable, and
  a plan containing orchestrator-proposed answers to BLOCKING questions always waits for a
  human.
- **If a subagent's plan is dominated by open questions** (i.e. it couldn't form a real plan),
  still post it — the open questions are exactly the feedback the human needs to provide — and
  say so in the summary.
