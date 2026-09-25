# How the workflow works

> Part of the [reference documentation](README.md). A quoted section name such as "Safety model"
> or "The CLAUDE.md contract" refers to a heading in this reference set or in the top-level
> [README](../../README.md) — the [index](README.md#where-each-section-lives) says which file holds it.

## Starting a new project ("start a new project" / "I want to build …")

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

## Planning ("plan the open issues" / "plan issues 13 and 15")

The `issue-planner` skill:
1. Pre-flight: `cleanup-after-merge.sh --fix` (sync + queue hygiene), then makes sure plans are
   written against the current default branch.
2. Finds issues needing an **initial plan** (no `plan-*` label) or a **revision**
   (`plan-proposed` with maintainer — `OWNER`/`MEMBER`/`COLLABORATOR` — comments after the latest
   trusted plan), via `find-planning-work.sh`. Comments from anyone else are reported, never
   acted on — see "Safety model" below. Each issue also carries its author's association;
   non-maintainer-authored issues are still planned but can never be auto-approved (step 6).
3. Dispatches the read-only `planner` subagent per issue (parallel dispatches OK — each is
   scoped to one issue). Prompts include relevant `LESSONS.md` entries and any orchestrator
   context the issue lacks (recently merged PRs, corrected measurements).
4. Posts each plan as an issue comment tagged `<!-- planner-plan -->` as the comment's first
   line, labels `plan-proposed`.
5. **Handles stale and overlapping plans**: a pending `plan-proposed` plan whose affected files
   changed under it (PRs merged since posting) gets a staleness comment (deliberately unmarked —
   it's this run's revision feedback) and an immediate same-run revision; a stale `plan-approved`
   plan gets the same staleness note, but opening with `<!-- harness-audit -->` (it's a record for
   the human, not feedback), plus a prominent flag (the human approved *that* plan — re-approval
   is theirs). Since #208, that `plan-approved` note also carries a
   `<!-- harness-staleness: issue=<n> prs=<prs> -->` key naming the merged PRs that caused it, and
   is skipped (never re-posted) once a prior run already recorded that same cause — the flag to
   the human is never skipped, only the comment. Overlapping plans (same files → merge conflicts)
   are flagged and excluded from auto-approval.
6. **Proposes answers and revises in the same run**: for BLOCKING open questions the
   orchestrator can ground in code/measurements, it posts proposed answers as a comment, then
   immediately revises the plan, tagging each folded decision `RESOLVED
   (orchestrator-proposed):` so provenance is visible at approval time. The human reviews one
   artifact instead of two rounds. Ungroundable questions stay open for the human.
7. **Auto-approves under the repo's policy, if one exists** — see "Approval" below.

**Planner stalls (#395).** When a `planner` subagent dispatch produces no plan at all
(`stalled-dispatch`), the first and second consecutive stall on that issue are retried, not
escalated: the planner posts a trusted record — a comment opening with `<!-- harness-audit -->`
whose second line is `<!-- harness-stall: issue=<n> stage=<plan-initial|plan-revision>
reason=stalled-dispatch -->` — and the issue stays in discovery for the next run to retry
automatically. `find-planning-work.sh` counts these records itself: a `needs_initial_plan` or
`needs_revision` item's `prior_stalls` is the number of trusted stall records posted after the
issue's newest trusted plan comment (a posted plan resets the count), and `escalate_on_stall` is
true once `prior_stalls + 1` reaches the fixed threshold, 3 (`STALL_ESCALATE_AFTER` in the
script). Only on that third consecutive stall does the planner escalate durably, the same way it
already does for `stalled-post` and `stalled-unknown` (an issue whose plan/revision existed but
was never posted, or an unrecognised failure) — both of those still escalate immediately, never
retried. Honest limits: a stall record posted under a harness `gh` identity that isn't itself a
maintainer never counts, so that issue retries forever but is still reported every run rather than
silently dropped. Revision candidates are read in full, so their count is exact, but the
initial-plan query sees only each issue's oldest 100 comments. On an initial-plan issue with more
comments than that, the count can be off either way: stall records past the window are missed
(the issue keeps retrying), and a plan past the window is missed too, so older stall records still
count and a stall can escalate early — the pre-#395 outcome, a `needs-human` escalation you clear.

The plan template (see `agents/planner.md`) includes: Summary, **Acceptance criteria** (the
testable definition of done the verifier later checks against — derived even when the issue
didn't state any), Estimated size (S/M/L), Affected areas (including a **"Claims this change
falsifies"** sub-list: the docs, docstrings, comments, and ADR sentences the change invalidates,
found at planning time rather than by the verifier afterwards), Data/schema impact,
Implementation steps, Testing approach, Risks, **Verified facts**, **Open questions
(BLOCKING/ADVISORY)**, **Follow-ups to file** (each carrying a one-sentence justification), Out
of scope.

## Approval (human by default, policy-assisted if you opt in)

A maintainer (`OWNER`/`MEMBER`/`COLLABORATOR`) comments on the issue to request changes
(comment-driven, no label needed) — a comment from anyone else is reported to the human but
never treated as feedback. Add `plan-approved` to accept. **Approving a plan whose open questions are all ADVISORY accepts the stated
defaults** — no extra revision round; the orchestrator passes the defaults to the implementer as
resolved decisions. Plans with unanswered BLOCKING questions shouldn't be approved. The
approval binds to the *specific plan comment* the label's newest application postdates (#174,
see "Approval provenance" below) — approving, then commenting again to trigger a same-run
revision, returns the issue to review instead of letting the implementer build the revised plan
under the old approval.

**Plan auto-approval (opt-in).** If the repo's `CLAUDE.md` contains a section titled **"Plan
auto-approval policy"**, the planner may add `plan-approved` itself for plans that satisfy the
policy's conditions AND a non-negotiable hard floor (see "The CLAUDE.md contract" item 4). Every
auto-approval leaves an audit comment, opening with `<!-- harness-audit -->` — the marker (matched
anywhere in the body) is what excludes it from both discovery scripts' binding sets (which
conditions were met, how to veto). No policy section ⇒ no auto-approval — the default is fully
manual, UNLESS `CLAUDE.md`'s "Autonomy mode" section declares `mode: autonomous` (item 9), in
which case a missing policy section is read as present with no conditions beyond the hard floor —
schema, security, and reserve-touching work are still never opted in by the mode alone. The
**`no-auto-approve` label** opts any individual issue back out of the policy. Note that an auto-approved plan may be implemented in
the same run — for that work, PR review is the human gate.

## Implementation ("implement the approved issues" / "implement issue 14")

The `issue-implementer` skill, for each `plan-approved` issue (sequential by default):
1. Pre-flight: crash recovery (a dirty tree on a `claude/<n>-*` branch from an interrupted run
   is wip-committed, noted on the issue, and requeued; a dirty tree anywhere else is a hard
   stop — that's human work; stale worktrees left by a crashed swarm are swept in the same
   pre-flight (a dirty one is wip-committed first, then removed), so a sequential run no longer
   trips over a branch still checked out elsewhere), `cleanup-after-merge.sh --fix`, and the
   **baseline refresh**: if
   the default branch moved past `.claude/BASELINE.md`'s recorded commit, re-run the
   verification suite on it — green updates the baseline, red stops the whole run (a broken
   main makes every failure unattributable). Then a fresh `claude/<n>-<slug>` branch; a wip-only
   leftover branch is **resumed, not restarted** unless its newest commit is a `wip: blocked —
   …`, in which case it's reset fresh as before — see "Resilience" below. Branches with real
   (non-wip) commits still go to the human.
2. Runs a fresh `find-implementation-work.sh --issue <n>` immediately before dispatch and
   dispatches the `implementer` subagent with: issue + full plan (incl. Verified facts) +
   **resolved answers to every open question** (as `RESOLVED:` decisions built ONLY from the trusted
   post-plan comments that `find-implementation-work.sh` marks `covered_by_approval: true` — a
   comment posted after the `plan-approved` label is `covered_by_approval: false`, reported to the
   human instead of folded in as a binding decision, per #194; since #230, a comment that WAS
   covered but was itself edited in place after approval is also un-covered
   (`covered_by_approval_reason: "decision-edited-after-approval"`), and one whose own edit state
   cannot be established is un-covered too (`"decision-edit-unreadable"`) — taken from that fresh, per-issue
   run, not read from the thread by hand) + `LESSONS.md` entries.
   **Plan-binding gate (#174, split by verdict since #219; #229 adds a label pre-filter, checked
   first, at zero extra API cost):** `plan-approved` must currently be on the issue — its absence
   ("approval-label-absent") means the human withdrew (or never applied) it, so the issue is
   **not dispatched**, but the remedy is non-destructive: no label change (nothing to remove), no
   revision-triggering comment (nothing to revise); a `<!-- harness-audit -->`-marked comment
   records the withdrawal, and the issue resumes automatically once a human re-adds the label. If
   the label IS present, the approval must also cover the specific plan comment selected — the
   newest `plan-approved` labeling event must not be earlier than that comment; if it demonstrably
   doesn't (e.g. the plan was revised after approval), the issue is **not dispatched**:
   `plan-approved` is removed and a revision-triggering comment posted, naming why. If the verdict
   is merely **unknown** instead — a GitHub API call failed — the issue is re-checked once (a
   `sleep 30` wait, then one more lookup, #223) before the verdict is concluded; still unknown
   after that retry, the issue is still not dispatched,
   but nothing destructive happens: no label is removed, no revision-triggering comment is posted;
   a `<!-- harness-audit -->`-marked comment, keyed and de-duplicated across runs (#222 — see
   "Approval provenance"), records the hold and the issue stays queued for the
   next run. Missing a BLOCKING answer → don't dispatch; escalate durably (#309, see
   `skills/issue-implementer/SKILL.md`'s "Durable escalation" subsection) and move on to the
   next issue.
   Before reporting, the subagent runs a mandatory evidence pass — sweeping the repo for every
   claim its diff falsifies, mutation-checking each new or rewritten test, pasting every number
   from command output — and records it in its report's Evidence block.
3. On completion: **independently re-runs the verification commands** (the mechanical gate — the
   subagent may be wrong, and this re-run stays the authoritative gate), comparing against the
   recorded baseline (counts must not drop unexplained).
4. **Dispatches the `verifier` subagent** (the semantic gate): fresh-context review of the diff
   against the plan's steps, the plan's acceptance criteria, test quality — including a bounded
   mutation probe (3 to 5 mutants in the changed code, tests re-run against each, tree restored
   immediately after every mutant; a surviving mutant on a behavior the plan's criteria named is
   a `major` finding) — scope, declared constraints, and, when CLAUDE.md declares an "Autonomy
   reserve", the diff's changed paths against those same globs (an undeclared reserve touch is a
   `blocker` finding). **Verifier fail → kickback**: the
   implementer is re-dispatched with the findings ("fix ONLY these"), then re-checked. The
   re-check confirms each prior finding is resolved and reviews only the fix's own delta. Its
   mutation probe targets only production code the fix changed, and a new surviving mutant on
   code the previous round already reviewed is a Note, not a finding, so the loop converges.
   **The kickback budget — 2 by default, or `CLAUDE.md`'s "Autonomy mode" `kickback-budget:`
   value (item 9) when that section declares `mode: autonomous` — is never exceeded**, then
   `impl-blocked` with the findings; **the orchestrator itself never patches a
   finding** — it never edits a source, test, or doc file to resolve one, only re-dispatches the
   implementer or, once the budget is spent, takes the blocked path. All of this happens
   *before* anything is pushed or a PR exists — the branch may already carry local WIP checkpoint
   commits by this point (see "Resilience: checkpointing, retries, and the dispatch ledger"
   below), but nothing leaves the machine until the verifier passes, so every PR the human sees is
   verifier-clean.
5. On verifier pass: **archives the verdict verbatim as an issue comment** (opening with
   `<!-- verifier-verdict -->`, its second line keying the archive to this PR's head branch,
   after every pass, including a later CI-fix re-verification), then
   **collapses the run's WIP checkpoint commits** into the working tree (one
   `git reset --soft` to the branch's merge base with the default branch — never the working
   tree itself, which is untouched), stages everything, **reconciles the staged list against the
   report's "Files changed"** (unexplained files = blocker, not a commit), **re-validates the
   plan binding** (#174: a fresh `find-implementation-work.sh --issue <n>` run's `binding_line`
   must either still match the one captured before dispatch, or come from a **same-plan
   re-approval** (#238: `covers_plan: true` naming the *same* `plan.url`, only the `approved-at=`
   field moved — a human removed and re-added `plan-approved` while the implementer worked) — in
   which case that fresh line, not the earlier one, is what the PR body carries — split by verdict
   since #219, plus #229's
   label check: if the label is currently absent (`approval-label-absent` — the human's own
   withdrawal), no commit, no push, no PR, and no `impl-blocked` either — instead the
   already-staged tree is committed as a `wip: checkpoint binding-recheck` commit exactly as the
   unknown-verdict branch below does, so the branch resumes next run once a human re-adds the
   label, and a `<!-- harness-audit -->`-marked comment records the withdrawal; if the label IS
   present but demonstrably doesn't cover the plan (`covers_plan: false` for any other reason, **or
   `covers_plan: true` naming a *different* plan comment (#238)** — a change of plan, not a
   re-approval), no
   commit, no push, the blocked path instead, and `plan-approved` removed; if the verdict is
   unknown instead, the same one-retry re-check as step 2 runs first (#223); still unknown after
   it, no commit, no push, but nothing destructive — `plan-approved` stays, the
   already-staged tree is committed as a `wip: checkpoint
   binding-recheck` commit so the branch resumes next run, and a `<!-- harness-audit -->`-marked
   comment, keyed and de-duplicated the same way (#222 — see "Approval provenance"), records the
   hold) **and diffs that same fresh run's (the retry run, when one ran) trusted post-approval comments**
   (#198) against the set captured before dispatch — a trusted comment that arrived while the
   implementer worked is surfaced (never binding, never holds the push) in the PR body when a PR
   exists, or in the blocker/hold comment otherwise, and the run summary; **on a same-plan
   re-approval the diff also surfaces (#238) any comment the re-approval itself newly covered,
   flagged as covered by the re-approval but not implemented — the human decides whether the PR is
   still what they want** — commits once, pushes,
   opens the PR (`Closes #n`, verification results, **the verifier's own closing status line
   pasted verbatim** — never one the orchestrator composes on its behalf — the re-validated
   `binding_line` pasted verbatim too, a `Mutation probe:`
   line carrying the verdict's mutation-probe result, the implementer's Evidence block condensed
   to its Claims-swept and Mutation-checks lines, schema notes, verifier notes), labels
   `pr-open`. The PR still ends up as one clean commit, exactly as before.
6. **Files the plan's "Follow-ups to file"** as new issues referencing the PR — each entry whose
   justification names a concrete failure a user of this software would experience, filed with
   `no-plan` (machine-authored — held out of planning entirely until a human triages the issue
   and removes the label; `no-auto-approve` is a separate, human-only veto the harness never
   applies) and a marker naming the PR it came from — then **writes the new issue numbers back
   into the PR body with `gh pr edit`**, not merely mentioned in the summary; entries that only
   name a capability wish or an unnoticeable drift risk are declined with a note in the PR body
   instead of becoming issues. A follow-up filed this way is born `no-plan`; if this PR is later
   closed without merging, `cleanup-after-merge.sh`'s follow-up quarantine still reaches it (#334)
   — keyed on a trusted, PR-keyed orphan-notice marker rather than the label — see "Returning to
   a laptop" and `CHANGELOG.md` (the archived v2.7.6 migration notes, #334).
7. **Watches CI** (`gh pr checks --watch`). Red CI caused by the PR itself gets **one bounded
   fix attempt** (implementer → mechanical checks → verifier → push; the PR isn't merged, so
   this is as safe as the kickback loop) — once that re-verification passes, its verdict is
   archived too, and the PR body's verifier status line and `Mutation probe:` line are refreshed
   with `gh pr edit` so the body always describes the tree the head commit actually carries (a
   denied `gh pr edit` escalates durably too, #309, never routed around); still red — or not the
   PR's fault — escalates durably instead of blocking the run (#309, see
   `skills/issue-implementer/SKILL.md`'s "Durable escalation" subsection). If the failure was a
   project gotcha, **append it to `LESSONS.md`**.
8. Never merges (merging is the human's, or the cycle's merge pass under an opt-in policy —
   see "The CLAUDE.md contract"). Blockers → local `wip:` branch + `impl-blocked` label +
   explanatory comment.

**Worktree-parallel mode:** never used inside the cycle's serial merge train (item 9) — the train
hands the implementer one issue at a time. When 2+ approved plans have pairwise **disjoint Affected areas**
(production + test files), the orchestrator may create one git worktree per issue and dispatch up
to **4 implementers concurrently**, acting as their **supervisor**: it tracks each worktree in an
in-context table, handles each completion as it arrives instead of waiting for the batch,
checkpoints a dead subagent's worktree *before* re-dispatching it under the same retry ladder and
resume cap as sequential mode, and defers the blocking CI watches until no implementer is still
running. Only the implementer dispatches fan out — the mechanical checks, the verifier, and the
orchestrator's own git/gh work stay sequential, one worktree at a time. Leftover state from an
earlier run is handled rather than fatal: the pre-flight's stale-worktree sweep (above) has
already run for both modes, and an existing `claude/<n>-*` branch is attached and
resumed instead of failing a `git worktree add -b` — reset fresh only when its newest commit is a
`wip: blocked — …`, exactly as sequential mode decides. Ignored files (venvs, `node_modules`)
don't exist in fresh worktrees: verification runs the main checkout's tool binaries against the
worktree, and UI-heavy issues that need per-tree installs fall back to sequential. Any overlap or
doubt → sequential.

## Resilience: checkpointing, retries, and the dispatch ledger

Recovery is an owned mechanism, not improvisation (canonical spec: the `issue-implementer`
skill's "Resilient dispatch", cited by name from `issue-planner`/`issue-cycle`): WIP
checkpointing with resume-not-restart, bounded exponential backoff before a stage escalates as
**failed**, a clean exit on context exhaustion under a capped relaunch budget, a status-line-fed
dispatch ledger reconciled by `reconcile-ledger.sh`, and merge guards — see "The steady state"
below for the ledger and the guards. Every status line also carries a trailing `harness=<version>`
field (#233) — the installed plugin revision that produced it, from `harness-version.sh` — which
`reconcile-ledger.sh` accepts as an optional trailing field but doesn't otherwise interpret.

## After the human merges

Nothing is required: every planner/implementer/cycle run starts with
`cleanup-after-merge.sh --fix` (best-effort sync — a diverged/missing upstream is reported and
the run continues, never aborts, prune merged `claude/*` branches — a merged branch a
worktree still holds is reported and skipped, never fatal — repair stale `pr-open` labels on open
issues with audited comments, sweep the whole historical backlog of CLOSED issues still labelled
`pr-open` (#370; up to 100 per run, converging across runs — just the label removed, no comment,
since the label-removal event is its own audit trail), and quarantine any plan follow-up orphaned
by a `claude/*` PR that closed
without merging — `no-plan` (when it isn't already present) then a comment, never closed) and the
implementer's baseline refresh re-verifies merged main — two green PRs can still compose badly,
and that check is now mechanical. The script's own pre-flight lookups (the default branch, the
current branch, the open-PR list, the `pr-open`-labelled issue list — open and, since #370, a
second closed-issue query — the multi-PR comment-marker
lookup, the follow-up-candidate issue search, and each matched follow-up's own orphan-notice
comments lookup) are best-effort too — a failure on any of them is reported
(`WARN`) and the run continues, degrading gracefully (skipping just the sync, or just the
label/follow-up/closed-sweep steps that depend on it) rather than aborting before producing any
output. Since
#355, `--fix`'s own mutating writes (posting a comment, closing an issue, adding or removing a
label) are best-effort in the same way: a failed write is reported (`WARN`, naming the issue and
which write failed) and the rest of that one issue's own repair is skipped, but the run always
continues on to the next issue and still reaches the closing reminder — one summary `WARN` line
prints when any write failed this run. Running `cleanup-after-merge.sh` by hand right after a
merge is still fine (it's idempotent for a clean run; a run whose writes partly failed can leave
an issue that the next run re-repairs, including posting a second audit comment, or, for the
closed-issue sweep, just retrying the label removal); without `--fix`
it only reports label problems instead of repairing them.

A merged `claude/<n>-*` PR only closes its issue when the PR body carries a closing keyword
(`Closes`/`Fixes`/`Resolves #<n>`) for that issue and no multi-PR signal is present. A PR that
delivers only part of an issue — its body says `Part of #<n>` / `PR <k> of <m>`, another
`claude/<n>-*` PR is still open, the issue carries the `multi-pr` label, or a maintainer
(`OWNER`/`MEMBER`/`COLLABORATOR`) comment carries a `<!-- harness-multi-pr -->` marker — leaves
the issue open (reported as `KEEP`) instead of closing it. The `multi-pr` label (applied by
hand, created by `setup-labels.sh`) is the primary signal — permission-controlled and visible in
the issue's label list, unlike an HTML comment. The comment-marker path still works but is
trust-gated (#231): a marker posted by anyone else is ignored and reported as one `WARN` line
naming the comment, and the issue's BODY carrying the marker is no longer honoured at all (a
maintainer has no way to prove they authored the issue body the way a comment carries its own
`authorAssociation`) — an issue that relied on the body marker before v2.7.0 needs the
`multi-pr` label applied instead. `--fix` still drops `pr-open` in the KEEP case, but only once
no other `claude/<n>-*` PR is open, so the issue re-queues for its next slice; a human closes it
by hand if the work is actually finished. Since v2.7.1 (#249), if every cheaper KEEP signal comes
up empty and the fallback comment-marker lookup (`gh issue view --json comments`) itself fails or
returns a document that isn't valid JSON, the script no longer falls back to "no marker found" —
it reports a `WARN` naming the failure route and leaves the issue exactly as found (`pr-open`
still attached, not closed, not commented, not relabelled) in both `--fix` and report-only modes,
so a rate-limit or auth blip during that one lookup can no longer manufacture a false close; the
next run re-examines it.

## The steady state, as one command ("run the cycle")

The `issue-cycle` skill composes the above into a single bounded pass: pre-flight → planning
pass → implementation pass → merge pass (**opt-in**: with a CLAUDE.md "Merge autonomy
policy" *and* the `gh pr merge` deny lifted, or with "Autonomy mode" declaring `mode: autonomous`
(item 9), which implies the policy for harness PRs only — the deny still has to be lifted by
hand either way; guarded per PR, one at a time, re-verified between,
audited in the report — in autonomous mode, item 9's serial merge train instead interleaves the
implementation and merge passes per issue) → a closing reconciliation, comparing the run's **dispatch ledger**
against `harness-status.sh`'s live queues via `reconcile-ledger.sh` (an issue with no recorded
outcome is escalated, never dropped; a degraded live read is escalated too, never reported
clean), then a **per-issue summary table** and a two-halves report
— *what the cycle did* and *what waits on the human* (plans to review, PRs to merge, blocked
issues, and (#333, #346) untriaged follow-ups, counted in the total).
It adds no authority beyond what CLAUDE.md delegates — it just removes the
hand-cranking between stages. Pair it with `/loop` or a scheduled routine for unattended
operation; each invocation stays one bounded pass, and an empty cycle — nothing done,
`counts.human_actions` at 0, and the stop switch clear (`stop.state` `"false"`) — reports
"all quiet" in one line. See the `issue-cycle` skill for the full procedure.

## The test-suite ratchet (opt-in)

The `test-ratchet` skill is the harness's only skill that files **machine-authored** issues —
proposals derived from tool output, closing measurable test coverage gaps. Off unless `CLAUDE.md`
has a section titled exactly **"Test-suite ratchet policy"**, which must state a measurement
command (required — no command means no ratchet) and may add a scope, per-run/open-backlog caps
(each may only lower the hard floor's numbers, never raise them), and a per-file target.

A non-configurable hard floor applies on top (see "The CLAUDE.md contract" item 6); closing an
issue as *not planned* vetoes that gap permanently.

Runs as `issue-cycle`'s **step 4, after the merge pass**, so the measurement reflects everything
that landed this run; an issue it files this run can't be planned, approved, or implemented
until the *next* cycle. It only files issues — never plans, approves, implements, or merges what
it files.

## Working the human gates from the phone

Every gate the harness waits on is an ordinary GitHub object — a label, an issue comment, a pull
request — so a cycle running unattended (via `/loop` or a scheduled routine) can be driven
entirely from wherever you read GitHub notifications, including the GitHub mobile app, without a
laptop in reach.

**What a cycle leaves behind.** A plan is a comment on the issue that OPENS WITH a
`<!-- planner-plan -->` marker — the marker must be the comment's first line for the harness to
recognise it (#281) — with the `plan-proposed` label added to the issue. Implementation work
becomes a pull request, opened once the verifier passes, with the verification results in its
body. You only see either one if you're watching the repo or subscribed to the issue/PR —
GitHub's own notification settings govern that, not this harness.

**Reviewing a plan.** Read the issue comment. To accept it, add the `plan-approved` label. To
request changes, comment on the issue with what to change — no label needed; the next cycle
reads your comment and revises. To take an issue out of planning entirely, add `no-plan`.

**Reviewing a PR.** Read the PR body (summary, files changed, verification results, the
verifier's own status line, its mutation-probe line, the implementer's condensed Evidence lines)
and its CI checks. Merge it, or close it, the same as any other PR; comment on it first if you
want changes made before either.

**Returning to a laptop.** Run `harness-status.sh` to see what's left: `waiting_on_human` has six
buckets — `plans_to_review`, `prs_to_review` (each PR entry carries a coarse `ci`: `passing`,
`failing`, `pending`, or `none`), `blocked`, (#333, #346) `followups_to_triage`, (#309)
`escalations` (open `needs-human` issues — a skill asked a question and moved on rather than
blocking; see `skills/issue-implementer/SKILL.md`'s "Durable escalation" subsection), and (#353)
`stop_routes` (one `{route, clear}` entry per SET stop-switch carrier, pasted verbatim from
`bin/harness-stop.sh`'s own stdout — see "Stopping a cycle" below and the new top-level `stop`
object it feeds) —
`counts.human_actions` is a generic sum over all six today (no bucket is excluded; the sum's
named-exclusion mechanism is retained, empty, as an extension point for a future member). Since
#346, `followups_to_triage` is untriaged-only: a harness-filed follow-up (#308) is born with
`no-plan`, and once you have read one and decided to keep it held, park it with
`gh issue edit <n> --add-label triaged-held` — it then drops out of both `followups_to_triage` and
`counts.human_actions`. To release a parked follow-up back into planning, remove `no-plan`; to see
the parked backlog, GitHub's own issue list is now the only view (`harness-status.sh` reports
nothing about it): `gh issue list --label triaged-held --state open`. To un-park one back into
`followups_to_triage`, remove the label: `gh issue edit <n> --remove-label triaged-held`. Check the
top-level `degraded` boolean too
(and `degraded_reasons`, and its `counts.degraded` mirror) — `true` means a discovery query, one
of `harness-status.sh`'s own five queries (plan-proposed, impl-blocked, open PRs, held follow-ups,
escalations), or its stop check, failed closed this run, so a bucket above may under-report the
true queue rather than reflect an empty one. Each `degraded_reasons` entry prefixed `status.` names
which `waiting_on_human` bucket above it affects (the plan-proposed query → `plans_to_review`,
impl-blocked → `blocked`, open PRs → `prs_to_review`, held follow-ups → `followups_to_triage`,
escalations → `escalations`, the stop check → `stop_routes`/`stop.state`); a
`planning.`/`implementation.`
entry usually affects `harness_will_handle`
instead — except `planning.candidates_query_unavailable`, which ALSO inflates `plans_to_review`
above: it fails the revision-candidates query closed, so `find-planning-work.sh`'s own
`needs_revision` bucket comes back empty, and this script subtracts that (now-empty) bucket from
the plan-proposed query — so a plan-proposed issue with real unaddressed maintainer feedback stays
counted as awaiting your review instead of the planner's. Nothing in that JSON is phone-specific —
it's the same summary a scheduled routine's own report already gives you. Since #395,
`harness_will_handle.unplanned`/`in_revision` items each carry `prior_stalls`, so a first or
second planner stall on an issue (see "Planner stalls" above) is visible between runs, before it
would otherwise escalate. Honest limits on
`followups_to_triage` (#333, #346): a follow-up you read and parked WITHOUT applying
`triaged-held` still counts; a hand-written `no-plan` issue whose body happens to open with the
same marker text would count too even though the harness never filed it; GitHub's issue search can
trail a label edit (measured once on this repo, 2026-09-17: a `gh issue list --search` run made
right after a label edit missed an issue that a later run returned), so a just-parked follow-up may
still appear — and now also count — in the very next run's bucket; and `--limit 100` caps this
listing the same way it caps `plans_to_review`'s, `prs_to_review`'s, `blocked`'s, and
`escalations`' own queries. Honest limits on
`escalations` (#309): this bucket's query is not excluded from `plans_to_review`/`blocked`, so an
issue carrying `needs-human` alongside `plan-proposed` or `impl-blocked` counts twice in
`counts.human_actions` until you remove one of the two labels; an escalation from a red-CI site
(`ci-red-after-fix`, `ci-red-unrelated`) or from the implementer's open-PR sub-branch
(`branch-has-open-pr`) sits on an issue whose open PR is already in `prs_to_review`, so that one
problem counts twice too (once as the PR, once as the escalated issue); and GitHub's issue search
can trail a label edit (measured on this repo, 2026-09-17 and
again 2026-09-19: a list query made right after a label edit missed an issue that a later run
returned), so an issue escalated moments earlier may be missing from the same run's `escalations`
bucket. Honest limits on `stop_routes` (#353): a `stop.state` of `"true"` carrying no carrier line
at all (`bin/harness-stop.sh`'s own documented non-issue-element response class) yields an EMPTY
`stop_routes`, so `human_actions` does not count it — `stop.state`, not `stop_routes`' own length,
is the authority on whether a stop is in effect; and the same freshness lag "Stopping a cycle"
below documents applies here unchanged.

**Stopping a cycle (#310).** `bin/harness-stop.sh` is a read-only stop switch, checked before each
stage and before each merge — see "One active cycle per checkout" below for the sibling lock
mechanism this complements. Two unioned routes; either one alone is enough to stop the next check:
set the GitHub route from a phone with `gh issue edit <n> --add-label harness-stop` (or tap the
label onto any issue in the mobile app) and clear it the same way, with `--remove-label
harness-stop`; set the local route at the keyboard with `mkdir -p
"<git-common-dir>/trail-blazer" && touch "<that dir>/stop"` (`<git-common-dir>` from `git
rev-parse --git-common-dir`) and clear it with `rm`. A local stop plus an unreadable GitHub route
still halts the run (a determinate set route beats an unconfirmable one); neither route set and
GitHub unreadable after one retry halts it too (an unconfirmable veto is not an absent one).
Honest limits: the query is capped at `--limit 20` open `harness-stop` issues; a label edit can
trail the query that checks it by several seconds (measured on this repo, 2026-09-19 — see
`bin/harness-stop.sh`'s own header for the figures), so the local route is the immediate one for
an operator at the keyboard; and the switch halts the harness's own dispatch loop — it cannot
interrupt a subagent already running, and it has no effect on a session that isn't running the
harness skills. (#353) `harness-status.sh` surfaces this exact check's own verdict rather than
running a second one — see "Returning to a laptop" above for the `stop`/`stop_routes` shape.

## Label lifecycle

*(no label)* → `plan-proposed` → *(human adds, or the auto-approval policy)* `plan-approved` →
`pr-open`, with `impl-blocked` for issues needing human input, `no-plan` to opt an issue out of
planning entirely (tracking/discussion/question issues; also applied automatically by the
`issue-implementer` skill to every follow-up issue it files, holding each one out of planning
until a human triages it and removes the label, and by `cleanup-after-merge.sh --fix` — when not
already present — to a plan follow-up orphaned when its source PR closed without merging), and
`no-auto-approve`, a **human-only veto** that keeps an individual issue's approval
manual even when CLAUDE.md defines an auto-approval policy — the harness never applies this
label itself. `test-ratchet` marks an issue the test-suite ratchet filed; the planner's
auto-approval hard floor refuses any issue carrying it outright, so a ratchet plan always waits
for a human; the harness never removes that label (manual approval is unaffected). A plan
follow-up the implementer files carries a `<!-- harness-follow-up: PR #<n> -->` marker naming
its source PR; `cleanup-after-merge.sh --fix`'s own notice for such an orphaned follow-up carries
a second marker, `<!-- harness-orphan-notice: PR #<n> -->` (#334) — the idempotence key for that
quarantine, checked against the issue's own comments rather than the `no-plan` label so it still
reaches a follow-up born with that label. `multi-pr`
(#231) is human-applied to a deliberately multi-PR issue: it's the primary signal
`cleanup-after-merge.sh` reads to leave the issue open when one of its slices merges, read only
by that script — nothing else in the lifecycle touches it. `needs-human` (#309) is a durable
escalation: a skill posted a comment stating a question and its evidence, applied the label, and
moved on to the next issue rather than blocking the run (see `skills/issue-implementer/SKILL.md`'s
"Durable escalation" subsection); it excludes the issue from every discovery query until a human
answers and removes the label. `harness-stop` (#310) is a human-only stop switch: any open issue
carrying it stops an `issue-cycle` run — one already in progress included — at its next checked
boundary, and a standalone `issue-planner`/`issue-implementer` run at its own per-issue dispatch
loop (`bin/harness-stop.sh`) — see "Stopping a cycle" above; the harness only ever reads this
label, and never applies or removes it. `triaged-held` (#346) is human-applied: it marks a held
follow-up issue you have read and deliberately decided to keep parked — see "Returning to a
laptop" above for the `followups_to_triage` bucket this excludes from and the `gh issue edit`
set/clear commands; the harness never applies or removes it either. `plan-approved`
can also come back off: the `issue-implementer` skill removes it (with an audit comment) when the
approval no longer covers the freshest plan comment — a same-run revision landed after the label
was applied (#174), the plan comment was itself edited in place after approval (#192), or, since
#230, a covered trusted decision comment was edited in place after approval — returning the issue
to the human's review queue rather than building the
wrong version. A human can also remove `plan-approved` directly, at any time, to veto an issue
mid-flight (#229): the harness never removes a label the human didn't ask it to here, but it
DOES honour the removal — dispatch, the pre-push recheck, and (under a merge autonomy policy) the
autonomous merge floor all re-check the label's CURRENT state and halt at the next check they run,
non-destructively (no label change, no revision-triggering comment — just a
`<!-- harness-audit -->` comment noting the withdrawal); the issue resumes automatically once a
human re-adds `plan-approved`. Humans gate
twice: plan approval and PR merge — each manual unless the repo's CLAUDE.md explicitly
delegates it (see "The CLAUDE.md contract"; merge delegation additionally requires the human
to lift the `gh pr merge` deny).
