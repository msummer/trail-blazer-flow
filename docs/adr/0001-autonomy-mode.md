# ADR 0001 — Autonomy mode

- **Status:** Accepted, 2026-09-16 (maintainer decision)
- **Verified against:** `main` at `4402354` (v2.7.3); Claude Code 2.1.273
- **Tracking issues:** see [Implementation](#implementation)

## Context

### Autonomy today is a set of separate opt-ins

A consumer repo turns on unattended behavior by declaring separate `CLAUDE.md` sections, each
described in the README's "The CLAUDE.md contract": the Plan auto-approval policy (item 4), the
Merge autonomy policy with its nested Post-merge verification (item 5, which also needs the
`Bash(gh pr merge:*)` deny lifted by hand), the Test-suite ratchet policy (item 6), the Autonomy
reserve (item 7) and the Autonomy decision record (item 8). `bin/check-harness.sh` validates each
section on its own; nothing declares or checks the combination an unattended run needs. With no
sections the harness is fully manual.

### The maintainer's own practice goes further than the skills allow

This repo is developed under a standing delegation recorded on #275: approve any plan with zero
BLOCKING questions, implement, allow two kickbacks and one CI-fix attempt, merge on a verifier pass
plus green CI plus the merge floor, and hold follow-ups for triage. Across the 2.7.2 and 2.7.3
release trains that delegation needed things the skills either don't provide or forbid:

| Practice | What the skills say at `4402354` |
|---|---|
| Plans approved in a later session than the one that posted them | Auto-approval evaluates only plans "posted or revised **this run**" (`skills/issue-planner/SKILL.md` step 6b, line 387). A plan that misses auto-approval once — for example because the author-association lookup was unavailable that run — waits for a human indefinitely. |
| Follow-ups held with `no-plan` until triaged, then planned and approved despite carrying `no-auto-approve` | Follow-ups are filed with `no-auto-approve` only (`skills/issue-implementer/SKILL.md`, *File the plan's follow-ups*, line 603), and step 6b's hard floor refuses any issue carrying it. The label ends up meaning both "routine harness hold" and "human veto". |
| Kickback budget spent → the maintainer was asked, then authorised a third round or an orchestrator-written comment fix | A spent budget means the blocked path, and the orchestrator never edits a source, test or doc file to resolve a finding (`skills/issue-implementer/SKILL.md` lines 44–48). |
| One issue carried through to merge before the next branch is cut | The cycle implements every approved issue, then runs the merge pass, and "after the first merge of a pass every other queued PR is behind by construction and holds" (`skills/issue-cycle/SKILL.md` lines 213–216). Without an update-branch step (#257, parked) at most one harness PR merges per pass. |
| PRs that append a lesson merged | The merge floor holds "any PR touching `CLAUDE.md`, `.claude/`, …" (`skills/issue-cycle/SKILL.md` line 219), while lessons are appended to `.claude/LESSONS.md` mid-run and "ride along with the next harness commit" (README, "The LESSONS.md contract"). Under merge autonomy, every PR that records a lesson waits for a human. |
| Stop on the maintainer's word at a stage boundary | No stop mechanism exists. |

### Unattended runs can stall without a trace

Several steps end in "ask the human" or "stop and warn" without saying how — for example
`skills/issue-implementer/SKILL.md` line 359 (a trusted comment contradicts the plan), line 382 (a
branch with non-`wip:` commits and no open PR) and line 404 (a mislabelled issue). None of the
issue-planner, issue-implementer or issue-cycle skills calls a question tool, and the merge stage
forbids "asking the user mid-cycle" (`skills/issue-cycle/SKILL.md` line 285). Under `/loop` or a
scheduled routine such a question lands only in a transcript: no label, no comment, and the next
pass meets the same stop again. A run interrupted inside a still-live session also leaves the
lock held until that session exits or a human forces a release (`bin/harness-lock.sh`, header,
"HONEST LIMITS").

### Claude Code's auto mode solves a different problem

Auto mode (`claude --permission-mode auto`) decides, per tool call, whether the call may run
without a prompt. It does not decide workflow questions such as whether a plan may be approved or
a PR merged, and the harness's PreToolUse hooks still apply under it (observed live on 2026-09-16:
`hooks/push-guard.sh` denied a command in a session running in auto mode). For headless runs,
`--permission-prompts none` together with `-p` means "nobody: anything that would prompt is denied
automatically; the permission mode still decides everything else" (`claude --help`, 2.1.273). That
turns a would-be hang into a denial — useful only if the skills treat a denial as an escalation
rather than something to route around.

## Decision

1. **One switch.** Add an optional `CLAUDE.md` section titled "Autonomy mode" that declares
   `mode: autonomous`. Without the section, behavior is unchanged. In autonomous mode:
   - an absent "Plan auto-approval policy" section is read as present, with no conditions beyond
     step 6b's hard floor;
   - an absent "Merge autonomy policy" section is read as present, covering harness PRs only (not
     Dependabot). Lifting the `gh pr merge` deny stays a manual settings change the harness never
     makes;
   - a policy section the repo does declare still applies in full — its conditions can only narrow
     what the mode allows, never widen it;
   - the Test-suite ratchet policy, Autonomy reserve and Autonomy decision record stay separate
     opt-ins.

   The doctor validates the combination: for example, autonomous mode with the merge deny still in
   place, branch protection that isn't strict, or no required status checks is a WARN.

2. **The hard floors don't move.** Autonomous mode changes who answers workflow questions, never
   the safety floor: the three PreToolUse hooks and the template deny list; the single-flight lock;
   every retry and wait cap; a verifier pass plus the orchestrator's own verification and
   staged-file check before any push; the full merge floor (provenance, green CI, the up-to-date
   rail, the base check, landed confirmation, one merge at a time, the audit comment); trust gates
   and plan-comment approval binding; label withdrawals honoured; a red default branch stops the
   run; deploys and schema changes are never applied; and the governance surface (CI
   configuration, settings files, hooks, the policy sections themselves) is never merged
   autonomously.

3. **Escalations are durable and never block — in every mode.** Every "ask the human" or "stop
   and warn" site becomes an issue comment stating the question and its evidence, plus a label
   marking the issue as waiting on a human; the run then continues with the next issue. The
   escalation is deduplicated across passes, excluded from discovery until the human acts, and
   surfaced by `bin/harness-status.sh` under `waiting_on_human`. A tool call denied because nobody
   can answer a permission prompt is escalated the same way, never routed around. An attended
   session may also ask in the conversation, but the run never waits on the answer. The label
   name, comment marker and dedupe key are settled in the implementing plan.

4. **Follow-ups are held with `no-plan`; `no-auto-approve` is a human-only veto — in every
   mode.** The harness files a plan's follow-ups with `no-plan` only, and triage (a human) lifts
   it. `no-auto-approve` is applied only by a human, and no policy, mode or delegation overrides
   it. The test-ratchet skill applies `no-auto-approve` to the issues it files too; the
   implementing plan decides how those are held under this rule, and migrates open follow-ups that
   carry a harness-applied `no-auto-approve`.

5. **The kickback budget can be configured but never exceeded.** Autonomous mode never grants an
   extra kickback and never lets the orchestrator write the fix: when the budget is spent, the
   issue takes the blocked path with a durable escalation (decision 3). The "Autonomy mode"
   section may set the budget (default 2, within fixed bounds). In every mode the orchestrator's
   own edits stay harness bookkeeping, so the model that writes the code never fixes its own
   review findings.

6. **Carry-over auto-approval (autonomous mode).** The planner evaluates auto-approval for every
   `plan-proposed` issue whose latest plan has no newer trusted feedback, not only for plans posted
   this run. The hard floor and the plan-comment approval binding are unchanged.

7. **Serial merge train (autonomous mode with merge autonomy).** The cycle carries one approved
   issue through implement → verify → PR → CI → merge before cutting the next branch, so no PR is
   behind by construction. Worktree-parallel implementation isn't used in this mode.

8. **A stop switch — in every mode.** A signal the maintainer can set on GitHub (so it works from
   the phone) is checked at every stage boundary and before every merge. On stop, the run finishes
   the current stage, dispatches nothing new, releases the lock, and reports.

9. **Appending a lesson doesn't trigger the governance hold — in every mode.** A PR whose only
   governance-surface change adds lines to `.claude/LESSONS.md` (no deletions or modified lines) is
   not held by the governance rule. Any other `.claude/` change still is.

10. **What stays human:** triage (the harness may draft a proposal but never lifts `no-plan`),
    releases and tags, a budget beyond the section's bounds, settings and deny-list changes, CI
    workflows, and the policy sections themselves.

## Alternatives considered

- **Document a recommended combination of the existing sections.** Rejected: it doesn't fix the
  silent stalls, the missing stop switch, the behind-by-construction holds, or the lesson hold.
- **Rely on Claude Code's auto mode.** Rejected as a substitute: it gates tool calls, not workflow
  decisions. It complements this mode and is the recommended way to run an unattended cycle
  headless.
- **Let the orchestrator fix findings once the budget is spent.** Rejected: it removes the
  separation between the model that writes the code and the verifier that judges it, which the
  kickback loop depends on. A larger declared budget is the supported lever.
- **A supervisor process (a deterministic state machine outside the model).** Not pursued; the
  harness stays prompt-orchestrated, and autonomous mode lives in the contract, skills and scripts.

## Consequences

- One section to declare, one combination for the doctor to check, and the same behavior whether
  a maintainer delegates in a session or a routine runs headless.
- Decisions 3, 4, 8 and 9 change behavior for every consumer, not only repos that opt in, so each
  needs a README migration note.
- New vocabulary (the escalation label, the stop signal, the mode section and its budget key)
  needs matching updates to `bin/setup-labels.sh`, the doctor, and the gate's fixed-string
  agreements.
- The serial train trades throughput for mergeability: each issue's wall-clock time now includes
  its CI run.
- Autonomous mode lives in `CLAUDE.md`, the skills and `bin/` rather than in Claude Code settings,
  so it carries to a Codex-driven harness (ADR 0002) with the same adapters the rest of the skills
  need.

## Implementation

Filed with `no-plan` for the maintainer's triage, in the suggested order:

| Order | Issue | Decisions | Depends on |
|---|---|---|---|
| 1 | #307 An appended `.claude/LESSONS.md` entry holds an otherwise-eligible PR | 9 | — (a bug today) |
| 2 | #308 Hold harness-filed follow-ups with `no-plan`; `no-auto-approve` human-only | 4 | — |
| 3 | #309 Durable, non-blocking escalations | 3 | — |
| 4 | #310 Stop switch | 8 | — |
| 5 | #311 "Autonomy mode" section, budget key and doctor combination check | 1, 2, 5 | #309 |
| 6 | #312 Carry-over auto-approval | 6 | #311 |
| 7 | #313 Serial merge train | 7 | #311 |
