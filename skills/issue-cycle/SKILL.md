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

One invocation = **one bounded pass** over everything currently pending — so the steady state
("plan" → approve → "implement" → merge → cleanup) is a single command, and a `/loop` or
scheduled routine has one thing to call. It is a *conductor*: the planning and implementation
logic lives entirely in the `issue-planner` and `issue-implementer` skills, invoked unchanged —
do not re-implement their procedures here. Unattended, a cycle can: turn new issues into plans,
revise on feedback, propose grounded answers, auto-approve plans **only** under CLAUDE.md's
auto-approval policy (hard floor always applies), implement through the verifier gate, open PRs,
merge PRs **only** under a merge autonomy policy (own hard floor — see the merge pass), file
coverage-increasing issues **only** under a test-suite ratchet policy (see the ratchet pass), and
repair queue hygiene. No auto-approval policy → ends with plans awaiting review; no merge
autonomy policy (or `gh pr merge` still denied) → ends with PRs awaiting merge — both the
human's.

## Dispatch ledger

A cycle tracks every issue it touches in a **per-issue dispatch ledger**, kept **in the run's
context only** — no state file, no new label. Each row: issue number, `planned` / `implemented`
/ `verified` / `merged` (outcome or "—" if not yet reached), retry count (ladder + resume,
summed per stage), wall-clock duration (`unknown` if no clock), final state, escalations.
- **Seeding:** at step 0, seed one row per issue from the pre-flight discovery output (planning
  + implementation lists), all four stage columns empty — the discovery bucket becomes the row's
  `seed` record when step 5 serializes it. **Updating:** each pass then fills in its own stage
  column per issue touched, from the outcome each dispatch reports via the status line contract
  (issue-implementer's "Resilient dispatch"); the ratchet pass fills in nothing (step 4).
- **Serialized form:** step 5 hands it to `reconcile-ledger.sh` as one record per line —
  `<issue> <stage> <outcome> [retries] [deploy=<slug>]` (format/vocabulary owned by that script —
  see its header / `--help`; the `deploy` field is merge-only, from guard (e)). A stage never
  reached is absent, never a `-` row.
- **Pre-advance check:** before advancing an issue, check the ledger — a stage with no entry is
  **launched, not assumed**; never infer "must have been fine" from an empty cell. **Closing
  reconciliation (step 5):** `reconcile-ledger.sh` then compares the serialized ledger against
  the live queues, one line per discrepancy.

## Procedure

### 0. Pre-flight

Run the issue-implementer skill's pre-flight (step 0) **up front**: gh auth, dirty-tree /
crash-recovery rules (incl. the stale-worktree sweep, before the hygiene script),
`cleanup-after-merge.sh --fix`, and the **baseline refresh** — before planning too, since a red
default branch STOPs the cycle with a report (planning wastes a round; implementing is forbidden
anyway). Missing `.claude/BASELINE.md` → warn once (harness-setup) and continue; it degrades
comparisons, doesn't block the cycle.

**Seed the dispatch ledger.** Run `find-planning-work.sh` and `find-implementation-work.sh`
(idempotent, read-only) to learn the full universe of issues this run might touch, and add one
ledger row per issue found, noting its discovery bucket. Steps 1 and 2 re-run their own
discovery as part of their normal procedure (expected, not wasted work), but this up-front seed
is what lets the pre-advance checks and step 5's reconciliation catch an untouched stage.

### 1. Planning pass

Invoke the **`issue-planner`** skill and let it run its full procedure (discovery, initial plans,
revisions, stale/overlap handling, proposed answers + same-run revision, policy auto-approval,
summary), skipping its step 0 (pre-flight already covered it). As it reports each outcome, fill
in the `planned` column (incl. retry counts from each status line); **pre-advance check** applies
— a blank cell after this pass means the stage was skipped, escalate it, don't carry it forward.

### 2. Implementation pass

Invoke the **`issue-implementer`** skill for everything now `plan-approved` — including plans
auto-approved in step 1 (the PR gate still applies) — skipping its step 0. Sequential by
default; its worktree-parallel mode applies under its own rules and changes nothing here (one
worktree is one issue, so the ledger row, status lines, and step 5's reconciliation are the
same). Fill in the `implemented` and `verified` columns from its summary table; **pre-advance
check** applies as in step 1. If step 1 produced nothing to implement and nothing was already
approved, skip this pass.

### 3. Merge pass (only under a repo merge autonomy policy)

Skip this pass entirely — **silently** — when there is no "Merge autonomy
policy" section at all; that silence is the only silent case, everything past activation is
loud. Activation requires **both**: (1) `CLAUDE.md` has a section titled exactly **"Merge
autonomy policy"** — no section means merging stays fully manual, exactly as before, that trust
decision belongs in the repo's file, not this plugin (skip silently); (2) `gh pr merge` actually
runs, i.e. the human has removed it from the deny list in `.claude/settings.json` — if the
section exists but the command is denied or prompts, that is the **loud** case (guard (c)
below), not a silent skip: the half-finished double opt-in gets escalated, not passed over
quietly.

When active, evaluate each open harness PR (and Dependabot PRs, if the policy covers them)
against the repo's policy. The policy defines *which* PRs qualify; this **hard floor applies
on top and is not configurable**:

- **Only PRs from the standard flow** — harness branches whose plan was approved (by the human
  or the auto-approval policy, mechanically checked against the specific plan comment approved —
  see *Plan-binding provenance* below) and whose PR body carries **the verifier's own closing
  status line** for that issue with `outcome=pass` — or Dependabot PRs of the update classes the
  policy names. Never a human's PR. A prose "verifier verdict: pass" without that line is **not**
  green.
  - *Verdict provenance, checked mechanically, before guard (a):* with `<n>` the issue number
    taken from the PR's `claude/<n>-…` head branch (never from prose in the body):
    `gh pr view <pr> --json body --jq '(.body // "") | contains("<!-- harness-status: stage=verifier issue=<n> outcome=pass ")' | tr -d '\r'`
    must print `true`, and the same command with `outcome=fail` in place of `outcome=pass` must
    print `false`. Keep the trailing space after `outcome=pass` in the needle so extra trailing
    `key=value` fields on the line stay tolerated.
  - *Archived verdict, checked mechanically*, between the check above and the *Ledger
    cross-check* below, same `<n>`-from-the-head-branch scoping (harness PRs only; Dependabot PRs
    skip this bullet): the archive is keyed to the PR's head branch, so a multi-PR issue's
    earlier slice matches its own verdict rather than the newest on the issue. Read the key
    first — `gh pr view <pr> --json headRefName --jq .headRefName | tr -d '\r'` (also where `<n>`
    comes from) — then paste that branch name literally into the placeholder below, in this
    one-line, substitution-free command:
    `gh issue view <n> --json comments --jq '[.comments[] | select((.body | contains("<!-- verifier-verdict -->")) and (.body | contains("<!-- verifier-verdict-branch: <paste the head branch here> -->")))] | sort_by(.createdAt) | last | ((.url // "none"), ((.body // "") | split("\n") | map(select(startswith("<!-- harness-status:"))) | last // "none"))' | tr -d '\r'`
    — prints the comment URL, then the archived closing status line. A second line reading
    `none`, or one that does not begin `<!-- harness-status: stage=verifier issue=<n>
    outcome=pass `, is **not eligible** ("no archived verifier verdict for head branch
    <branch>"), one-line reason in the report. Otherwise paste that second line literally as the
    needle of a second, equally substitution-free command:
    `gh pr view <pr> --json body --jq '(.body // "") | contains("<paste the printed line here>")' | tr -d '\r'`
    — anything but `true` is **not eligible** ("the PR body's verifier line does not match the
    verdict archived for head branch <branch>"), one-line reason in the report. Cite the printed
    comment URL as merge evidence.
  - *Ledger cross-check*, against the pre-advance check above: the issue's `verifier` ledger row
    must read `pass`; a row reading `fail`/`incomplete`/`died` against a pass line in the PR body
    is a contradiction — don't merge, escalate with both pieces of evidence.
  - *Plan-binding provenance, checked mechanically* (#174), same `<n>`-from-the-head-branch
    scoping (harness PRs only; Dependabot PRs skip this bullet): run `find-implementation-work.sh
    --issue <n>` and read `.plan_selection[0].approval.covers_plan` and
    `.plan_selection[0].binding_line` — the literal `<!-- harness-plan-binding: issue=<n>
    plan=<url> approved-at=<ts> -->` when covered, `null` otherwise. `covers_plan` must be `true`
    and `binding_line` non-null — otherwise **not eligible** ("plan binding:
    `<approval.reason>`"), one-line reason. Otherwise paste `binding_line` literally as the
    needle of this one-line, substitution-free command:
    `gh pr view <pr> --json body --jq '(.body // "") | contains("<paste the binding line here>")' | tr -d '\r'`
    — anything but `true` is **not eligible** ("the PR body does not carry the printed
    plan-binding line").
- **CI green on the head commit**, verified fresh (`gh pr checks`), not remembered; **"no checks
  configured" is not green** unless the policy section explicitly opts a no-CI repo in.
- **Never the governance surface**: any PR touching `CLAUDE.md`, `.claude/`, the repo's
  policy/ADR documents, or CI configuration waits for the human regardless of what the policy
  says — the autonomy boundary only moves with a human in the loop.
- **Nothing flagged**: if the plan, the verifier's notes, or the implementer's report flags a
  decision needing human sign-off, the PR waits. Any ambiguity about whether the policy covers
  a PR resolves to "no".
- **One at a time, re-verified between**: merge, then run `cleanup-after-merge.sh --fix` and
  the baseline refresh before the next merge — if merged `main` goes red, STOP the pass and
  report (two green PRs can still compose badly; sequential re-verification attributes the
  breakage). Match the repo's existing merge method (merge/squash/rebase) from recent history.
- **Every autonomous merge is audited**: it appears in the cycle report with its evidence —
  PR link, verifier verdict, the archived verdict comment's URL, CI run — never merged silently.

**Pre-first-merge deploy recheck.** Active only when guard (e)'s "Post-merge verification"
sub-block is declared — no sub-block, this step does not exist, silently, exactly like guard (e)
itself. The dispatch ledger lives in this run's context only, so a `deploy=failed` recorded by an
earlier cycle is already forgotten by the next one, which is exactly the gap this recheck closes.
**When:** once per run, immediately before the first merge attempt of the pass — before guard (b)
for the first PR that reaches it, never again for later merges (guard (e) covers those); if no PR
ever reaches guard (b), this never runs. **How:** run guard (e)'s declared commands exactly as
guard (e) defines them — same read-only contract, same bounded wait, same
`verified|pending|failed` outcome mapping, not restated here. **Outcome:** `verified` ⇒ proceed to
guard (a) as normal; `failed` or `pending` ⇒ **STOP the merge pass for the rest of the run before
any merge happens**, reported the same way a red baseline is, quoting the last ~10 lines of
command output verbatim, and named in the cycle report. **Bookkeeping:** no status line, no ledger
row, no `deploy=` field of its own; PRs that had qualified for this pass but were not merged
because of the stop are recorded `outcome=merge-blocked`, the recheck's result as their one-line
reason — guard (c)'s "print the exact `gh pr merge` command" hand-off does **not** apply here,
since production is unverified and whether to merge onto it is the human's call.

**Merge guards, applied per PR, in order:**

(a) **Base assertion.** Before attempting the merge, confirm the PR targets the repo's default
    branch (`gh pr view <n> --json baseRefName --jq .baseRefName | tr -d '\r'`, resolved once via
    `gh repo view --json defaultBranchRef` — the same lookup the issue-implementer pre-flight
    already does, not a hardcoded `main`). A mismatch **aborts that merge and escalates** — the
    harness never merges a PR whose base is a feature branch, even if every other guard passes.

(b) **Attempt the merge**, matching the repo's existing merge method as today.

(c) **Permission-denied escalates loudly.** If the policy section exists but `gh pr merge` comes
    back permission-denied (the human hasn't lifted the deny on this machine), the stage fails
    loudly: report the issue as **`verified, merge blocked`** (never `done`), and print the
    **exact command** for the human in the run summary, including the PR number and the repo's
    merge method, e.g. `gh pr merge <n> --squash` (adjust the flag to match). Never route around
    the denial — no API calls, no web merges, no asking the user mid-cycle.

(d) **Merge-landed confirmation.** After the merge command returns, confirm it actually landed
    before reporting it merged (`gh pr view <n> --json state --jq .state | tr -d '\r'` must
    return `MERGED`). If it doesn't, the state is **`merge attempted, unconfirmed`** and the
    merge pass stops for that PR — don't proceed to the next merge assuming success.

(e) **Post-merge verification (optional, CLAUDE.md-declared).** Only when the "Merge autonomy
    policy" section carries a sub-heading titled exactly **"Post-merge verification"** (any `#`
    depth) followed by a fenced block: detection mirrors the policy sections above — exact
    heading match, then the fenced block under it. No sub-block means this step does not exist —
    silent, like the merge pass's own activation check: the pass behaves exactly as it does
    today, no `deploy=` field, no report line. When present, every non-blank fenced line is one
    command, read-only by contract, run in order from the repo root, exactly as written — never
    a command the fence does not contain, never synthesized, adapted, or extended. An optional
    `Wait: <N> minutes` line in the sub-block before the fence sets the poll budget (absent →
    10; clamped to a non-configurable 30-minute ceiling — beyond it the pass records
    `deploy=pending` and hands to the human).

    Runs after guard (d) confirms `MERGED` **and** after this PR's `cleanup-after-merge.sh --fix`
    + baseline refresh, before the next PR is merged.

    **Read-only contract:** these commands are reads; the harness never approves a deployment,
    promotes a build, or re-runs a deploy — that authority stays with the human, always. A
    declared command with no matching allow entry, or one containing command substitution (no
    allow rule can approve those — README "Safety model"), records `deploy=pending` and names
    the exact problem in the report; never route around a denial.

    **Bounded wait, `sleep` only:** run the declared commands; if the result is not yet
    conclusive, `sleep 60` and re-run, at most N times (N = the declared minutes, clamped at
    30). If `sleep` is denied, re-run once immediately and record `deploy=pending` with "backoff
    unavailable — grant `Bash(sleep:*)`".

    **Outcome mapping:** all declared commands exit 0 within the budget → `deploy=verified`;
    budget spent with no conclusive result, or a permission/`sleep` problem → `deploy=pending`;
    any command exits non-zero → `deploy=failed`.

    **Escalation:** `pending`/`failed` are loud in step 5's "waits on the human" half, quoting
    the last ~10 lines of the command output verbatim; `deploy=failed` additionally **STOPs the
    merge pass for the rest of the run** (no further merges), reported the same way a red
    baseline is.

Fill in the `merged` ledger column **for every PR the pass evaluated** and emit the merge
stage's status line yourself (there is no merge agent) — `stage=merge`, `issue=<n>`,
`retries=0` (the merge pass doesn't retry through the ladder — a denial or base mismatch is a
policy/config fact, not a transient failure), and an outcome from the issue-implementer skill's
"Resilient dispatch" vocabulary for `merge`. When guard (e) ran, the status line and ledger row
also carry a trailing `deploy=<verified|pending|failed>` field, e.g.
`<!-- harness-status: stage=merge issue=<n> outcome=merged retries=0 deploy=verified -->`; no
field is emitted when there is no declaration or the outcome is not `merged`.

PRs that fail any check (guard or policy) simply stay in the "waits on the human" queue with a
one-line reason — a normal outcome, not an error (the loud escalations above are for cases
needing the human's attention beyond just "PR waits").

### 4. Ratchet pass (only under a repo test-suite ratchet policy)

Skip this pass entirely — **silently** — when `CLAUDE.md` has no section titled exactly
**"Test-suite ratchet policy"**; everything past activation is loud. Runs after the merge pass
(measurement then reflects everything that landed). When active, invoke the **`test-ratchet`**
skill and let it run its full procedure (activation check, measurement, gap selection under its
hard floor, filing, report) unmodified — this pass is sequencing plus one cost guard: skip the
measurement (say so) when this run merged nothing **and** the pre-flight found the default
branch unchanged from baseline (a standalone invocation always measures).

**No ledger row, no status line** — touches no issue already in the pipeline, dispatches no
agent. Note the issue numbers it filed: step 5 lists each as `unledgered`. Report what it filed
in "what this cycle did" — issue links, the measurement figure, and that each carries
`no-auto-approve`.

### 5. Close the loop

```bash
harness-status.sh
```

**Closing reconciliation.** Pipe the ledger (serialized per "Dispatch ledger" above) through the
reconciler — it re-reads live state itself, no temp file needed:

```bash
reconcile-ledger.sh - <<'LEDGER'
14 seed unplanned 0
14 planner plan-posted 0
17 seed ready_to_implement 0
17 implementer complete 0
17 verifier pass 0
LEDGER
```
This heredoc form is covered by the single `Bash(reconcile-ledger.sh:*)` grant — a heredoc body
is not split into separately-matched subcommands — verified live; see README "Safety model".
No output, exit 0 → every queued issue accounted for. Otherwise one line per discrepancy, exit 1
(expected, not a tool failure); `reconcile-ledger.sh`'s own output defines each code. Per class:
`stage-skipped` / `outcome-missing` / `unknown-outcome` → escalate. `contradiction` → report
with evidence, treat as unfinished. `unledgered` → usually a mid-run filing (say so, let the next
cycle take it; name a ratchet-pass filing as such, not a discrepancy) — unless it was in the
pre-flight discovery output, in which case the seed step missed it: escalate that. No script on
PATH → fall back to comparing the ledger against the JSON by hand, same criteria.

**Per-issue summary table**, before the two-halves report: issue, planned / implemented /
verified / merged (outcome or "—"), retries, duration, final state, escalations.

Two-halves report, from the status JSON and the sub-skills' summaries: **(1) what this cycle
did** — plans posted/revised/auto-approved, PRs opened/merged (links + evidence), issues blocked,
CI outcomes, lessons, hygiene fixes; **(2) what waits on the human** — plans to review
(BLOCKING/ADVISORY counts), PRs to review/merge (CI state, the one-line reason each didn't
qualify for the merge pass, `verified, merge blocked` PRs with their exact command), blocked
issues (blocker, one line each) — copy-paste actionable. Nothing done and nothing waiting → say
"all quiet" in one line and stop (still an empty ledger, not a skipped reconciliation — only
applies when there was truly nothing to seed).

## Unattended operation

- **Recurring runs:** pair with `/loop` (e.g. "loop the issue-cycle every 30m") or a scheduled
  routine; each invocation stays ONE bounded pass — recurrence is the wrapper's job, never this
  skill's (never polls for new work or repeats a pass; the merge pass's declared deploy waits —
  guard (e) and the pre-first-merge recheck — are the two bounded exceptions).
- **Single-flight:** never start a cycle while another runs in the same checkout (they'd share a
  working tree exactly like two implementers would); if evidence of a live concurrent run
  appears, stop and say so.
- **Human-latency, not machine-latency, is the throughput limit.** The cycle keeps the queues
  drained; the report's "waits on the human" half is the backlog that matters — say so explicitly
  if the same items recur rather than repeating the list mechanically.

## Rules

- **No authority beyond the repo's delegation.** Every rule of the composed skills applies
  verbatim — this skill adds sequencing plus the merge pass, nothing else. Never approve outside
  the auto-approval policy path and its hard floor; merge authority is defined once, in the merge
  pass's activation conditions and hard floor (step 3), nowhere else; the ratchet pass files
  issues and nothing else; never touch a dirty tree that isn't the harness's own.
- **Fail towards the human.** Any pass in an unexpected state (red baseline, repeated crash
  recovery on the same issue, discovery truncation that won't drain, a resume cap exceeded, an
  exhausted retry ladder) stops that issue's progress and reports, rather than looping through
  the damage.
- **No stage skipped but unreported.** Every ledger row gets an outcome (success, blocked, or
  escalated) for every stage it reached — enforced by the pre-advance checks per pass and the
  closing reconciliation in step 5.
- **One cycle, one report.** Even when both passes ran, the human gets a single consolidated
  report at the end, not two skill summaries stitched mid-run.
