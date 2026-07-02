---
name: issue-cycle
description: >
  Runs one full pass of the steady-state workflow: post-merge cleanup → plan (and revise,
  propose answers, policy auto-approve) → implement approved issues → report what now waits on
  the human. Use when the user asks to "run the cycle", "process everything pending", "run the
  harness", "do a full pass", or wants unattended/scheduled operation (pair with /loop or a
  scheduled routine). It composes the issue-planner and issue-implementer skills; it adds no
  new authority — the same human gates apply (plan approval unless the repo's CLAUDE.md policy
  covers it; PR merge always).
---

# Issue Cycle

One invocation = **one bounded pass** over everything currently pending. This skill exists so
the steady state ("plan the open issues" → approve → "implement the approved issues" → merge →
cleanup) is a single command instead of four — and so a `/loop` or scheduled routine has one
thing to call. It is a *conductor*: the planning and implementation logic lives entirely in the
`issue-planner` and `issue-implementer` skills, which you invoke unchanged. Do not re-implement
their procedures here.

What a cycle can do unattended: turn new issues into plans, revise on feedback, propose
grounded answers to open questions, auto-approve plans **only** under the repo's CLAUDE.md
policy (hard floor always applies), implement approved plans through the verifier gate, open
PRs, and repair queue hygiene. What it can never do: merge a PR, or approve a plan outside the
policy path. If there is no CLAUDE.md auto-approval policy, a cycle ends with plans awaiting
review and PRs awaiting merge — both the human's.

## Procedure

### 0. Pre-flight

Run the issue-implementer skill's pre-flight (step 0) **up front**: gh auth, the dirty-tree /
crash-recovery rules, `cleanup-after-merge.sh --fix`, and the **baseline refresh**. Doing the
baseline refresh before planning (not just before implementing) is deliberate: if the default
branch is red, STOP the cycle and report — planning against a broken main wastes a round, and
implementing on it is forbidden anyway.

If `.claude/BASELINE.md` is missing, warn once (run harness-setup) and continue — a missing
baseline degrades comparisons; it doesn't block the cycle.

### 1. Planning pass

Invoke the **`issue-planner`** skill and let it run its full procedure: discovery, initial
plans, revisions, stale/overlap handling, proposed answers + same-run revision, policy
auto-approval, summary. Skip its step 0 (your pre-flight already covered it).

### 2. Implementation pass

Invoke the **`issue-implementer`** skill for everything now `plan-approved` — including plans
auto-approved in step 1 (that's the point of the policy; the PR gate remains). Skip its step 0
(already covered). Sequential by default; its worktree-parallel mode applies under its own
rules if the batch qualifies.

If step 1 produced nothing to implement and nothing was already approved, skip this pass.

### 3. Close the loop

```bash
harness-status.sh
```

End with a report in two halves, drawn from the status JSON and the sub-skills' summaries:

1. **What this cycle did** — plans posted/revised/auto-approved, PRs opened (links), issues
   blocked, CI outcomes, lessons recorded, hygiene fixes.
2. **What waits on the human** — plans to review (with BLOCKING/ADVISORY counts), PRs to
   review/merge (with CI state), blocked issues (with the blocker, one line each). This is the
   human's work queue; make it copy-paste actionable (issue/PR links).

If the cycle did nothing and nothing waits on anyone, say "all quiet" in one line and stop —
an empty cycle must be cheap and unceremonious.

## Unattended operation

- **Recurring runs:** pair with `/loop` (e.g. "loop the issue-cycle every 30m") or a scheduled
  routine. Each invocation stays ONE bounded pass — recurrence is the wrapper's job, never this
  skill's (no internal polling or sleeping).
- **Single-flight:** never start a cycle while another is running in the same checkout (two
  cycles share a working tree exactly like two implementers would). If evidence of a live
  concurrent run appears, stop and say so.
- **Human-latency, not machine-latency, is the throughput limit.** In the steady state the
  cycle keeps the queues drained; the report's "waits on the human" half is the backlog that
  matters. If the same items appear cycle after cycle, say so explicitly rather than repeating
  the list mechanically.

## Rules

- **No new authority.** Every rule of the composed skills applies verbatim — this skill adds
  sequencing, not permissions. Never merge; never approve outside the policy path; never touch
  a dirty tree that isn't the harness's own.
- **Fail towards the human.** If any pass ends in an unexpected state (red baseline, repeated
  crash recovery on the same issue, discovery truncation that won't drain), stop the cycle and
  report rather than looping through the damage.
- **One cycle, one report.** Even when both passes ran, the human gets a single consolidated
  report at the end — not two skill summaries stitched mid-run. (The sub-skills' summary steps
  feed it; don't emit them separately.)
