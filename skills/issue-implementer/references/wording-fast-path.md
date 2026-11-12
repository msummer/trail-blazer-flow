# Wording fast path (optional)

This file is the full procedure for the one budget-free round that step 2e's `Verdict fail`
branch runs when every finding is `wording`. Read it only after `SKILL.md` has pointed here.
Every budget and vocabulary it uses (the kickback budget, the retry ladder, the WIP checkpoint
vocabulary, the verifier's re-verification) is defined in `SKILL.md` and is unchanged.

## When

Step 2e's verdict is `fail`, every finding is tagged `wording`, and no fast-path round has been
used for this issue in this run. The cap is 1, fixed. It applies in every mode and at every
kickback budget, including 0, on Claude Code and on Codex, sequential and worktree mode alike
(in worktree mode, note the use in that issue's worktree-table row). It does not apply to the
CI-fix re-verification. A verdict with any `blocker` or `major` finding is a normal kickback,
and its `wording` findings ride along in it.

## Dispatch

The round is shaped exactly like a step 2e kickback: the **implementer** applies the fixes,
never the orchestrator. Use the same prompt contents, the same ladder, the same LESSONS.md guard
compare, the same `wip: checkpoint kickback (#<n>)` checkpoint, and, on Codex, the same canary
and unattended blocks. The prompt keeps *"Fix ONLY these verification findings"* and adds:
*"Every one is a `wording` finding: apply each finding's replacement text exactly, and change
only Markdown files and comment lines — no code, test, or config line."*

## Route

- **The implementer's report names any change outside Markdown files and comment lines under
  Deviations:** the round is charged to the kickback budget and continues as a normal kickback.
  With no budget left, it takes step 2f's blocked path.
- **A mechanical check fails after the fix:** step 2f, exactly as after any kickback.
- **Otherwise:** run `reserve-paths.sh` as usual, then re-dispatch the verifier with the prior
  findings verbatim and `Previously reviewed commit: <sha>`, the existing delta-scoped
  re-verification. That re-verification is what produces the PR's `outcome=pass` line; the
  orchestrator never writes one itself.
- **The re-verification fails:** the normal budget-charged kickback loop takes over.

## Record

Under the PR body's verification section, add one `Wording fast path:` line per finding
(location and what changed), copied from the finding text. Never paste the failing verdict's
status line (the `outcome=fail` one) into the PR body: `bin/merge-floor.sh` holds a PR whose
body carries it. In the step 3 summary, count the round as "wording fast path". Status lines,
ledger rows and journal entries are the normal implementer and verifier ones; nothing new.

## Honest limit

No mechanical check decides that a delta is wording-only. An uncharged fast-path round is bounded
by the cap of 1, by the implementer's own Deviations report, and by the re-verification judging
the result as for any kickback. It is not bounded by a script.
