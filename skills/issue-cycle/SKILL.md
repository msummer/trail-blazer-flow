---
name: issue-cycle
description: >
  Runs one full pass of the steady-state workflow: post-merge cleanup → plan (and revise,
  propose answers, policy auto-approve) → implement approved issues → report what now waits on
  the human. Use when the user asks to "run the cycle", "process everything pending", "run the
  harness", "do a full pass", or wants unattended/scheduled operation (pair with /loop or a
  scheduled routine). It composes the issue-planner and issue-implementer skills and adds no
  authority beyond what the repo's CLAUDE.md delegates.
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
auto-approval policy (hard floor always applies), implement approved plans through the verifier
gate, open PRs, merge PRs **only** under the repo's CLAUDE.md merge autonomy policy (its own
hard floor always applies — see the merge pass), and repair queue hygiene. If there is no
CLAUDE.md auto-approval policy, a cycle ends with plans awaiting review; if there is no
CLAUDE.md merge autonomy policy (or the `gh pr merge` deny is still in place), it ends with
PRs awaiting merge — both the human's.

## Dispatch ledger

A cycle tracks every issue it touches in a **per-issue dispatch ledger**, kept **in the run's
context only** — no state file, no `.claude/CYCLE-LEDGER.md`, no new label. Each row: issue
number, `planned` / `implemented` / `verified` / `merged` (each a stage outcome or "—" if not yet
reached this run), retry count (ladder retries + resume relaunches, summed per stage), wall-clock
duration (`unknown` if a clock is unavailable — never fail the cycle over a missing `date`),
final state, and escalations.

**Seeding:** at step 0, seed one row per issue named in the pre-flight discovery output (both the
planning and implementation discovery lists once step 1/2 run them), each starting with all four
stage columns empty.

**Updating:** each pass (planning, implementation, merge) fills in its own stage column for every
issue it touches, using the outcome each sub-skill's dispatch reports via the status line
contract (see the issue-implementer skill's "Resilient dispatch" — cited here by name, not
restated).

**Serialized form:** the ledger lives in context, but step 4 hands it to `reconcile-ledger.sh`
as one whitespace-separated record per line — `<issue> <stage> <outcome> [retries]`, where
`stage` is `seed` (the step-0 row, whose outcome is the discovery bucket the issue came from,
or `-`) or `planner` / `implementer` / `verifier` / `merge`. Write a record only for a stage
this run actually **dispatched**: a stage never reached is simply absent, never a `-` row —
that value means "dispatched, outcome not recorded", which the script flags. A dispatch's
verbatim status line counts as a record, so lines can be pasted instead of transcribed, and
the last record wins for the same issue+stage (a same-run revision just appends).

**Pre-advance check:** before moving an issue on to its next stage, check the ledger — a stage
with no ledger entry is **launched, not assumed**. This is what stops an issue from silently
skipping a stage: the cycle never infers "must have been fine" from an empty cell.

**Closing reconciliation (step 4):** `reconcile-ledger.sh` compares the serialized ledger
against the live queues and prints one line per discrepancy (invocation in step 4). It
**detects**; the judgment stays here — an issue still queued for a stage the ledger never
recorded is an **escalated skipped stage**, never a silent drop.

## Procedure

### 0. Pre-flight

Run the issue-implementer skill's pre-flight (step 0) **up front**: gh auth, the dirty-tree /
crash-recovery rules, `cleanup-after-merge.sh --fix`, and the **baseline refresh**. Doing the
baseline refresh before planning (not just before implementing) is deliberate: if the default
branch is red, STOP the cycle and report — planning against a broken main wastes a round, and
implementing on it is forbidden anyway.

If `.claude/BASELINE.md` is missing, warn once (run harness-setup) and continue — a missing
baseline degrades comparisons; it doesn't block the cycle.

**Seed the dispatch ledger.** Run `find-planning-work.sh` and `find-implementation-work.sh`
(both idempotent, read-only) to learn the full universe of issues this run might touch, and add
one ledger row per issue found (all four stage columns empty), noting which discovery bucket it
came from — that bucket is the row's `seed` record when step 4 serializes the ledger. Steps 1
and 2 below re-run their
own discovery internally as part of their normal procedure — that's expected, not wasted work —
but the ledger's up-front seed is what lets the pre-advance checks and step 4's reconciliation
catch a stage that never got touched.

### 1. Planning pass

Invoke the **`issue-planner`** skill and let it run its full procedure: discovery, initial
plans, revisions, stale/overlap handling, proposed answers + same-run revision, policy
auto-approval, summary. Skip its step 0 (your pre-flight already covered it). As it reports each
outcome, fill in the `planned` column for the corresponding ledger rows (including the retry
count from each dispatch's status line). **Pre-advance check:** before treating an issue as
planned, confirm the ledger shows an outcome for it — a blank cell after this pass means the
stage was skipped and must be escalated, not silently carried forward.

### 2. Implementation pass

Invoke the **`issue-implementer`** skill for everything now `plan-approved` — including plans
auto-approved in step 1 (that's the point of the policy; the PR gate remains). Skip its step 0
(already covered). Sequential by default; its worktree-parallel mode applies under its own
rules if the batch qualifies. Fill in the `implemented` and `verified` ledger columns from its
summary table (outcome, retry/kickback counts, CI status). **Pre-advance check:** the same rule
as step 1 — an issue this pass should have touched with no ledger outcome is launched (or
escalated if it can't be), never assumed done.

If step 1 produced nothing to implement and nothing was already approved, skip this pass.

### 3. Merge pass (only under a repo merge autonomy policy)

Skip this pass entirely — **silently, exactly as v1.5.0** — when there is no "Merge autonomy
policy" section at all (activation condition 1 below unmet). That silence is the only silent
case; everything past activation is loud (see the guards below).

Activation requires **both**:

1. The repo's `CLAUDE.md` has a section titled exactly **"Merge autonomy policy"**. No section
   means merging stays fully manual, exactly as before — that trust decision belongs in the
   repo's file, not this plugin. (No section → skip silently, per above.)
2. `gh pr merge` actually runs — i.e. the human has removed it from the deny list in
   `.claude/settings.json`. If the policy section exists but the command is denied or prompts,
   that is the **loud** case (see guard (c) below), not a silent skip: the half-finished double
   opt-in gets escalated, not passed over quietly.

When active, evaluate each open harness PR (and Dependabot PRs, if the policy covers them)
against the repo's policy. The policy defines *which* PRs qualify; this **hard floor applies
on top and is not configurable**:

- **Only PRs from the standard flow** — harness branches whose plan was approved (by the human
  or the auto-approval policy) and whose PR body carries a verifier pass — or Dependabot PRs of
  the update classes the policy names. Never a human's PR.
- **CI green on the head commit**, verified fresh (`gh pr checks`), not remembered.
- **Never the governance surface**: any PR touching `CLAUDE.md`, `.claude/`, or the repo's
  policy/ADR documents waits for the human regardless of what the policy says — the autonomy
  boundary only moves with a human in the loop.
- **Nothing flagged**: if the plan, the verifier's notes, or the implementer's report flags a
  decision needing human sign-off, the PR waits. Any ambiguity about whether the policy covers
  a PR resolves to "no".
- **One at a time, re-verified between**: merge, then run `cleanup-after-merge.sh --fix` and
  the baseline refresh before the next merge — if merged `main` goes red, STOP the pass and
  report (two green PRs can still compose badly; sequential re-verification attributes the
  breakage). Match the repo's existing merge method (merge/squash/rebase) from recent history.
- **Every autonomous merge is audited**: it appears in the cycle report with its evidence —
  PR link, verifier verdict, CI run — never merged silently.

**Merge guards, applied per PR, in order:**

(a) **Base assertion.** Before attempting the merge, confirm the PR targets the repo's default
    branch:
    ```bash
    gh pr view <n> --json baseRefName --jq .baseRefName | tr -d '\r'
    ```
    resolved once via `gh repo view --json defaultBranchRef` (the same lookup the
    issue-implementer pre-flight already does — not a hardcoded `main`). A mismatch **aborts
    that merge and escalates** — the harness never merges a PR whose base is a feature branch,
    even if every other guard passes.

(b) **Attempt the merge**, matching the repo's existing merge method as today.

(c) **Permission-denied escalates loudly.** If the policy section exists but `gh pr merge` comes
    back permission-denied (the human hasn't lifted the deny on this machine), the stage fails
    loudly: report the issue as **`verified, merge blocked`** (never `done`), and print the
    **exact command** for the human in the run summary, including the PR number and the repo's
    merge method, e.g. `gh pr merge <n> --squash` (adjust the flag to match). Never route around
    the denial — no API calls, no web merges, no asking the user mid-cycle.

(d) **Post-merge verification.** After the merge command returns, confirm it actually landed
    before reporting it merged:
    ```bash
    gh pr view <n> --json state --jq .state | tr -d '\r'
    ```
    must return `MERGED`. If it doesn't, the state is **`merge attempted, unconfirmed`** and the
    merge pass stops for that PR — don't proceed to the next merge assuming success.

Fill in the `merged` ledger column with the outcome (`merged` / `merge-blocked` / `not-eligible`
/ `merge-unconfirmed`) for every PR the pass evaluated, and emit the merge stage's status line
yourself (there is no merge agent) per the issue-implementer skill's "Resilient dispatch":
`stage=merge`, `issue=<n>`, that same outcome, `retries=0` (the merge pass doesn't retry through
the ladder — a denial or a base mismatch is a policy/config fact, not a transient failure).

PRs that fail any check (guard or policy) simply stay in the "waits on the human" queue with a
one-line reason. That is a normal outcome, not an error — the loud escalations above (guard (c),
a hard `main`-red stop) are for cases that need the human's attention beyond just "PR waits".

### 4. Close the loop

```bash
harness-status.sh
```

**Closing reconciliation.** Pipe the ledger (serialized per "Dispatch ledger" above) through the
reconciler — it re-reads live state itself, so no temp file is needed:

```bash
reconcile-ledger.sh - <<'LEDGER'
14 seed unplanned 0
14 planner plan-posted 0
17 seed ready_to_implement 0
17 implementer complete 0
17 verifier pass 0
LEDGER
```

No output and exit 0 means every queued issue is accounted for. Otherwise it prints one line per
discrepancy and exits 1 (an expected non-zero exit, not a tool failure). The script detects; the
call is yours:

- `stage-skipped`, `outcome-missing`, `unknown-outcome` → an **escalated skipped stage**, not a
  clean "still pending" item. This is the mechanical backstop behind the pre-advance checks in
  steps 1-3.
- `contradiction` → the stage reported success but the issue never left the queue (a label edit
  or PR step that didn't land). Report it with its evidence and treat the issue as unfinished.
- `unledgered` → usually an issue filed *during* the run: say so and let the next cycle take it.
  If it was in the pre-flight discovery output, the seed step missed it — escalate that.

If the script isn't on the PATH (an older install), fall back to comparing the ledger against
the JSON by hand, on the same criteria.

**Per-issue summary table.** Before the two-halves report below, print the ledger as a table:
issue, planned / implemented / verified / merged (outcome or "—"), retries (ladder + resume,
summed), duration (wall-clock per issue if `date` is available, else `unknown` — never fail the
cycle over a missing clock), final state, escalations. This is the single artifact that answers
"what happened to every issue this run touched," including the ones that ended up escalated
rather than progressed.

End with a report in two halves, drawn from the status JSON and the sub-skills' summaries:

1. **What this cycle did** — plans posted/revised/auto-approved, PRs opened (links), PRs
   merged autonomously (link + one-line evidence each: verifier verdict, CI run), issues
   blocked, CI outcomes, lessons recorded, hygiene fixes.
2. **What waits on the human** — plans to review (with BLOCKING/ADVISORY counts), PRs to
   review/merge (with CI state, and the one-line reason each PR didn't qualify for the merge
   pass, when one ran — including any `verified, merge blocked` issue and its exact merge
   command), blocked issues (with the blocker, one line each). This is the human's work queue;
   make it copy-paste actionable (issue/PR links).

If the cycle did nothing and nothing waits on anyone, say "all quiet" in one line and stop —
an empty cycle must be cheap and unceremonious. (An empty cycle still means an empty ledger, not
a skipped reconciliation — the "all quiet" shortcut only applies when there was truly nothing to
seed.)

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

- **No authority beyond the repo's delegation.** Every rule of the composed skills applies
  verbatim — this skill adds sequencing plus the merge pass, nothing else. Never approve a plan
  outside the auto-approval policy path and its hard floor; merge authority is defined once, in
  the merge pass's activation conditions and hard floor (step 3), and exists nowhere else;
  never touch a dirty tree that isn't the harness's own.
- **Fail towards the human.** If any pass ends in an unexpected state (red baseline, repeated
  crash recovery on the same issue, discovery truncation that won't drain, a resume cap exceeded,
  a stage that exhausted the retry ladder), stop that issue's progress and report rather than
  looping through the damage — the resume cap and the ladder's escalation are themselves the
  bounded version of this rule, not an exception to it.
- **No stage skipped but unreported.** A cycle may not end with an issue silently missing a
  stage it should have gone through. Every ledger row gets an outcome (success, blocked, or
  escalated) for every stage it reached — enforced by the pre-advance checks per pass and the
  closing reconciliation in step 4.
- **One cycle, one report.** Even when both passes ran, the human gets a single consolidated
  report at the end — not two skill summaries stitched mid-run. (The sub-skills' summary steps
  feed it; don't emit them separately.)
