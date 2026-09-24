# The project-side contract: CLAUDE.md, LESSONS.md, BASELINE.md

> Part of the [reference documentation](README.md). A quoted section name such as "Safety model"
> or "The CLAUDE.md contract" refers to a heading in this reference set or in the top-level
> [README](../../README.md) — the [index](README.md#where-each-section-lives) says which file holds it.

## The CLAUDE.md contract (required)

These skills assume the repo has a **`CLAUDE.md`** documenting the project-specifics the generic
subagents need:

1. **Conventions & architecture** — stack, code style, patterns, security/data rules.
2. **Verification commands** — the checks that define "done" (typecheck/lint/tests/build or the
   project's equivalent), ideally under a clearly labelled "Verification" section.
3. **Setup command** (optional) — how to install dependencies.
4. **Plan auto-approval policy** (optional) — a section titled exactly "Plan auto-approval
   policy" stating, in plain language, which plans the planner may approve on your behalf,
   e.g.:

   ```markdown
   ## Plan auto-approval policy
   Auto-approve plans that are size S, with no data/schema impact and no
   security-sensitive risks. Everything under `payments/` requires manual approval.
   ```

   The hard floor always applies on top (no BLOCKING questions — none answered by the
   orchestrator itself, except a granted issue's record-citing answer, see item 8 below — not
   stale, no overlap, schema/security work only if explicitly opted in, and the issue's author is
   a maintainer), every auto-approval is audited with an issue comment, and the `no-auto-approve`
   label opts any issue out. **No section means no auto-approval** — this is a trust decision that
   belongs in your file, not the plugin's (or "Autonomy mode", item 9, which reads a missing
   section as present with no conditions beyond the hard floor above).

5. **Merge autonomy policy** (optional) — a section titled exactly "Merge autonomy policy"
   stating which PRs the `issue-cycle` merge pass may merge on your behalf, e.g.:

   ```markdown
   ## Merge autonomy policy
   The cycle may merge harness PRs whose plan was approved, whose verifier verdict
   is pass, and whose CI is green — plus Dependabot patch/minor updates with green
   CI. Never: anything touching `db/`, auth, CI/CD, or dependency majors.
   ```

   Activation is a **double opt-in**: the section alone does nothing until you also remove
   `Bash(gh pr merge:*)` from the deny list (and add it to the allow list, or unattended runs
   stall on the permission prompt). Edit `.claude/settings.json` to activate for everyone, or
   `.claude/settings.local.json` (machine-local, gitignored, never committed) to activate on
   one machine only — settings.local.json is the first-class way to do that. A deny in
   *either* file — or in your user-level settings file — wins over an allow anywhere else.
   Both edits are yours, never an agent's. The merge pass's hard floor always applies on
   top (standard-flow PRs only, the PR body carrying the verifier's own `outcome=pass` status
   line — not prose — checked mechanically and cross-checked against the dispatch ledger *and*
   against the verifier's verdict archived verbatim as an issue comment for that PR's head
   branch, *and* against the approval covering the specific plan comment implemented — the PR
   body carrying one of a fresh `find-implementation-work.sh` run's `approval.approved_at_history[]`
   `binding_line` values verbatim, newest first, so a body written under an earlier approval of the
   same plan still qualifies (#174, extended #213) — every one of these provenance reads, plus the
   head-branch key read and the archive's own match needle, and, since #300, the `gh pr checks`
   read, the up-to-date rail's `gh pr view` read, the merge pass's base-branch read and its
   one-time default-branch lookup, and its merge-landed read, and, since #319, the up-to-date
   rail's `git fetch origin` (answers by exiting 0, output unread, so any non-zero exit is the
   transient failure), each get one bounded retry on
   transient failure before the PR is held, never on a determinate answer — pending or failing
   checks, a base mismatch, and any non-`MERGED` state all count as an answer, never retried
   (#245, #277, #287, #300, #319) — CI
   green on the head commit, its head mechanically checked to contain the default branch's
   current tip (`git merge-base --is-ancestor`) immediately before each PR's own merge attempt,
   otherwise held with "PR is behind `<default>` at `<short-sha>` — update the branch and let CI
   re-run" (#234, review F4 — because merges are sequential, every PR queued behind the first one
   in a pass holds this way by construction, expected rather than an error, outside the serial
   merge train — item 9's "Autonomy mode" runs the update-branch fallback there instead) — never
   the governance surface, read mechanically per PR by
   `governance-paths.sh` (item 10 below) — CLAUDE.md, `.claude/`, policy/ADR docs, CI config, and
   any path this repo's own CLAUDE.md declares (harness PRs get
   one narrow, audited exception: a PR whose only
   governance-surface change is an end-of-file append to `.claude/LESSONS.md`, at most 40 lines,
   with no deletions, no changed lines, and no `<!--`, and whose added lines the orchestrator
   judges as recording only a project gotcha — any doubt holds — is not held on that account
   alone — see "The LESSONS.md contract" below) — nothing flagged for human decision, including, read from that
   same fresh `find-implementation-work.sh --issue <n>` run, any trusted post-plan comment the
   approval does not cover (`covered_by_approval` not `true`), so a maintainer's late objection
   parks the PR for you instead of merging past it (#206) — one merge at a time with
   re-verification between, every merge audited in the cycle report). **No section means no
   autonomous merges** — behavior is exactly the
   pre-1.5 default — UNLESS "Autonomy mode" (item 9) declares `mode: autonomous`, in which case a
   missing section here is read as present for harness PRs only (never Dependabot, never an
   opt-in for a repo with no CI). **"No checks configured" is not green.** A repo with no CI wired up gets a
   "no checks configured" result from `gh pr checks`, and the hard floor above treats that the
   same as red: no PR qualifies for the merge pass unless your "Merge autonomy policy" section
   explicitly opts a no-CI repo in. Absent that opt-in, the PR simply waits, with the reason
   recorded in the cycle report. Recommended pairing: branch protection with required status
   checks, so the policy has a technical rail under it, not just prompt adherence — once merge
   autonomy is effectively active (a "Merge autonomy policy" section present, or "Autonomy mode"
   implying it), `check-harness.sh` reads the protection document
   itself and WARNs (never FAILs) when `required_status_checks.strict` isn't exactly `true`, when
   zero status check contexts are required, and reports informationally whether required PR
   reviews are configured (#234).
   `check-harness.sh` judges activation from *effective* merge-permission state — across
   `.claude/settings.json`, `.claude/settings.local.json`, and your user-level settings file —
   and reports off, active (with a note when no `.github/workflows` file is found, naming the
   same no-checks-configured precondition), or (the trap it exists to catch) half-activated: a
   "Merge autonomy policy" section present (or "Autonomy mode" implying it) while `Bash(gh pr
   merge:*)` is still denied in one of
   those files, which the doctor WARNs on by naming the file, because it leaves the cycle
   reporting `verified, merge blocked` on every run. Once merge autonomy is effectively active,
   `check-harness.sh` also WARNs on any `uses:` ref in `.github/workflows/*.yml`/`*.yaml` and in
   any `action.yml`/`action.yaml` anywhere in the repo (so a local composite action gets its own
   refs checked no matter where it lives, not only under `.github/actions/`) — local (`./…`,
   `../…`) and `docker://` refs excepted in both — that isn't pinned to a full 40-hex commit
   SHA — under merge autonomy the cycle merges on "CI green", and a mutable tag lets its owner
   repoint what CI runs with no diff visible in this repo. An action metadata file inside a
   pruned `.git/` or `node_modules/` tree, a symlinked action directory whose target lies outside
   the repo, and the body of a reusable workflow owned by another repo (its ref is still checked,
   just not its contents) are not scanned.

   **Post-merge verification** (optional, nested under this same section) — a sub-heading titled
   exactly "Post-merge verification" (any `#` depth) followed by a fenced block of read-only
   commands, one per line, run in order from the repo root after a merge is confirmed, so a repo
   whose default branch auto-deploys stops reporting "done" when only "merged" is true, e.g.:

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

   An optional `Wait: <N> minutes` line before the fence sets the poll budget (default 10,
   clamped to a non-configurable 30-minute ceiling, beyond which the pass hands off rather than
   waiting longer). The `issue-cycle` merge pass runs exactly the declared commands — never one
   it synthesizes, adapts, or extends — and records the outcome as a trailing `deploy=` field on
   the merge stage's ledger row and status line: `verified` (every command exited 0 within the
   budget), `pending` (budget spent with no conclusive result, or a permission/`sleep` problem),
   or `failed` (a command exited non-zero — which additionally stops the merge pass for the rest
   of the run); `pending`/`failed` surface loudly in the cycle report with the command output's
   last lines. **No sub-block means the merge pass behaves exactly as it does today** — no extra
   step, no `deploy=` field. These commands are reads only: the harness never approves, promotes,
   or redeploys anything — see "Safety model". `check-harness.sh` reports the declaration state as
   part of the merge-autonomy verdict — declared (with a count of fenced command lines), heading
   present but no fenced commands, or not declared at all — without ever executing, eval'ing, or
   otherwise looking up any of the declared commands themselves. When declared, it additionally
   reports whether each declared command's first token has a matching `Bash(<token>:*)` allow entry
   in the same three-file union the merge-autonomy verdict reads (`.claude/settings.json`,
   `.claude/settings.local.json`, and the user-level settings file) — a literal string comparison
   only, never a lookup or an execution — WARNing (never failing) and naming the exact entry to add
   when one is missing, so an unattended cycle doesn't discover the missing grant only after a
   merge. Because the dispatch ledger lives in each run's context only, the next run's merge pass
   re-runs these same commands once, immediately before its first merge, and stops before merging
   anything if that recheck comes back anything but `verified`.

6. **Test-suite ratchet policy** (optional) — a section titled exactly "Test-suite ratchet
   policy" stating the measurement command the `test-ratchet` skill (standalone, and as the
   `issue-cycle` ratchet pass) runs to find coverage gaps, e.g.:

   ```markdown
   ## Test-suite ratchet policy
   Measure with `pytest --cov=app --cov-report=term-missing`. Propose coverage work for
   `app/` only — never `app/migrations/`, generated clients, or `scripts/`. At most 1 issue
   per run; target 80% per file.
   ```

   A non-configurable hard floor always applies on top: test-only (adds or extends tests,
   nothing else), monotonic (never deletes, skips, or weakens an existing test, assertion, or
   threshold), evidence-backed (every issue quotes the command, the commit, and a verbatim
   output excerpt), capped at 3 issues per run and 5 open `test-ratchet` issues, and never the
   governance surface (`CLAUDE.md`, `.claude/`, policy/ADR docs, CI config). **No section means
   the ratchet never runs.** Every filed issue carries `test-ratchet`, which the planner's
   auto-approval hard floor refuses outright and the harness never removes, so plan
   review always stays human (a human's own manual approval is unaffected); closing a ratchet
   issue as *not planned* vetoes that gap permanently.
   `check-harness.sh` reports whether the section exists and, if it does, whether it names a
   backtick-quoted measurement command that resolves on the PATH — it never runs that command
   itself; only the `harness-setup` skill does, once, at onboarding, with a human present.

7. **Autonomy reserve** (optional) — a section titled exactly "Autonomy reserve" declaring a
   fenced block of path globs, one per line (`**` allowed), naming paths a scoped-autonomy grant
   must never be treated as authorizing, e.g.:

   ````markdown
   ## Autonomy reserve
   ```
   CLAUDE.md
   .claude/**
   docs/adr/**
   ```
   ````

   The planner adds a "Reserve touch list" section to every plan when this section exists: every
   "Affected areas" entry matching a declared glob (naming the glob it matched), or "None". A
   non-empty Reserve touch list blocks auto-approval (item 4's hard floor) unless the "Plan
   auto-approval policy" section explicitly opts reserve-touching work in. The `verifier` subagent
   re-checks the same globs against the diff's actually-changed paths at review time (see
   "Implementation" step 4 above) — a changed path matching a declared glob that the plan's
   Reserve touch list never named is a `blocker` finding, whether or not the plan was
   auto-approved. **No section means the harness never populates a Reserve touch list, the hard
   floor's reserve bullet is inert, and the verifier's reserve-touch check never runs either.**
   What counts as reserved, and what a grant may override, stays this repo's decision — the
   harness only reads the declared globs and does the matching in prose.

8. **Autonomy decision record** (optional) — a section titled exactly "Autonomy decision record"
   declaring a fenced block of `key: value` lines describing the record a human-applied grant
   label requires an issue's body to carry, e.g.:

   ````markdown
   ## Autonomy decision record
   ```
   grant-label: scoped-autonomy
   record-section: Binding decisions
   element: Escalation triggers
   element: Migration posture
   element: Worked example
   ```
   ````

   `grant-label:` (required) names the label a human applies to an issue to grant it whatever
   autonomy this repo's own policy defines. `record-section:` (optional, default "Binding
   decisions") names the heading the issue body's record lives under. Each `element:` line (at
   least one required) names a required sub-heading under that section. When an issue this run
   carries the declared label, the `issue-planner` skill runs `check-decision-record.sh <n>` — a
   read-only script that fetches the issue body and checks it for the record-section heading
   (presence only) and, for each declared element, a heading nested under the record-section
   heading (strictly deeper, before the next same-or-shallower heading outside a fence — a
   same-depth heading is NOT nested) that has at least one non-blank line of content in its span
   — printing a PASS/FAIL line per check, with a distinct message for "heading absent" versus
   "heading found outside the record section" versus "heading found, no content under it" — and
   reports a `grant: will deliver` / `grant: will not deliver` verdict in its summary before
   implementation. The body scan recognises backtick- and tilde-fenced blocks of any matching
   length, indented up to 3 spaces, closing only on a same-character run at least as long
   followed by nothing but whitespace. A non-zero exit on a grant-labelled issue also joins item
   4's hard floor. **The harness never applies, removes, or creates the grant label** — that
   stays a human action — and never judges whether the record's *content* is any good, only
   whether each declared element's heading is nested under the record section, outside a fenced
   block, and has something written under it. **No 'Autonomy decision record' section means the
   check never runs and no grant is ever evaluated.** `check-harness.sh` reports
   `scoped autonomy: off` only when neither this section nor item 7's "Autonomy reserve" is
   declared; a repo that declares
   "Autonomy reserve" alone gets a WARN instead (no grant label is declared, so
   `check-decision-record.sh` never runs).

   **The body-hash grant pattern (documented convention, not harness behaviour).** A repo that
   wants its grant label to be tamper-evident against a re-label that skips a genuine re-review
   can adopt this convention in its own `CLAUDE.md`: when granting, the human posts a comment
   `grant: <sha256 of issue body>`. The canonical recipe, run as two plain commands (no allow rule
   approves a command containing command substitution — see "Safety model"):

   ```bash
   gh issue view <n> --json body --jq .body | tr -d '\r' > /tmp/body.txt
   shasum -a 256 /tmp/body.txt        # macOS/BSD
   sha256sum /tmp/body.txt            # Linux
   ```

   Both sides must use the same recipe or the digests won't match. **The harness computes and
   verifies nothing here** — a repo that wants a subagent to recompute the hash must say so in
   its own `CLAUDE.md` and add `Bash(shasum:*)` / `Bash(sha256sum:*)` to its allow-list; the
   template does not ship either grant.

9. **Autonomy mode** (optional) — a section titled exactly "Autonomy mode" declaring a fenced
   block of `key: value` lines that turns on several of the policies above together, as one
   combination, instead of requiring each declared separately (ADR 0001), e.g.:

   ````markdown
   ## Autonomy mode
   ```
   mode: autonomous
   kickback-budget: 2
   ```
   ````

   `mode: autonomous` (required) is the only recognised value — anything else, or the section's
   absence, leaves the mode off; a section present with no `mode: autonomous` line is **inert**,
   same as absent. `kickback-budget:` (optional) is an integer from 0 to 3, default 2 — any other
   value falls back to the default, with a WARN from `check-harness.sh` naming the bad value; the
   budget is never exceeded.

   In autonomous mode:
   - A missing "Plan auto-approval policy" section (item 4) is read as present with no conditions
     beyond item 4's own hard floor — that floor alone decides, so schema, security, and
     reserve-touching work are never opted in by the mode alone.
   - A missing "Merge autonomy policy" section (item 5) is read as present for harness PRs
     only — never Dependabot, and never an opt-in for a repo with no CI wired up (item 5's own
     "no checks configured is not green" hard floor still applies).
   - A section this repo DOES declare still applies in full, exactly as items 4/5 describe — the
     mode can only narrow what it allows, never widen a policy this repo wrote narrower.
   - The "Test-suite ratchet policy" (item 6), "Autonomy reserve" (item 7), and "Autonomy decision
     record" (item 8) sections stay separate opt-ins; the mode implies none of them.
   - Lifting the `Bash(gh pr merge:*)` deny stays a manual, human edit to `.claude/settings.json`
     or `.claude/settings.local.json` (item 5's own double opt-in) — the mode never lifts it and
     never edits a settings file itself.
   - Every hard floor named in items 4 through 8 is unchanged; the mode only widens *which*
     section is read as present, never *what* a present section is allowed to authorize.
   - The kickback budget (see "Implementation" step 4 above) bounds how many times the verifier's
     fail finding re-dispatches the implementer before the run takes the blocked path. The
     orchestrator never writes the fix itself; a spent budget always takes the blocked path,
     exactly like the fixed limit does without this section.
   - Auto-approval (item 4) is also evaluated on every run for each `plan-proposed` plan posted in
     an EARLIER run, not just one posted or revised this run (ADR 0001 decision 6), as long as its
     latest plan has no newer maintainer feedback. The same hard floor and the same approval
     binding (item 4's own plan-comment binding) apply — nothing is loosened for a carry-over
     candidate. A plan whose `plan-approved` label was added or removed after it was posted is
     never re-approved by the harness this way (a withdrawal is honoured); post new feedback or
     re-add the label yourself to get it reconsidered. A carry-over candidate that fails the floor
     gets no comment and no label — it is only reported in that run's summary.
   - **Serial merge train** (ADR 0001 decision 7, folds in #257): whenever this mode is on AND
     the merge pass's activation (1) holds, the `issue-cycle` skill runs its implementation and
     merge passes as one serial train instead of implementing everything first and merging after
     — see `skills/issue-cycle/references/serial-train.md` for the full procedure. It drains any
     open harness PRs left over from earlier passes first, then carries each ready issue through
     implement → verify → PR → CI → the merge floor → merge → post-merge re-verification before
     the next branch is cut; worktree-parallel mode is never entered inside the train. A held PR
     moves the train on to the next issue; a merge-halting event (e.g. a merge denial or an
     unconfirmed merge) makes the rest of the run implement-only, opening PRs but attempting no
     further merge; a train-stopping event (a red baseline after a merge, or a stop-switch stop)
     dispatches no further issue. For a PR whose only hold is the up-to-date rail ("behind"),
     the train tries `gh pr update-branch <pr>` once (merge-from-base, never `--rebase`, skipped
     when the repo's merge method is rebase), waits a bounded time for CI, then re-evaluates the
     whole merge floor from the top on the new head; a conflict or a further failure leaves the
     PR held, named, with the old → new head recorded in the report. Activation (1) does not
     require the `gh pr merge` deny to be lifted, so until a merge is confirmed in a run the train
     applies at most one update-branch (and its CI wait) — with the deny still in place, guard
     (c)'s denial then stops merging for the run.
     Outside this mode, the
     merge pass is unchanged: one merge per pass, no update-branch.

   `check-harness.sh` prints exactly one verdict line whenever `CLAUDE.md` exists — off (no
   section), autonomous (naming the effective kickback budget), or inert (section present, no
   `mode: autonomous` line) — and, in autonomous mode, widens the merge-autonomy, CI-pinning, and
   branch-protection checks (item 5's own WARN stems, unchanged) to fire from the implied
   activation too, even with no "Merge autonomy policy" section declared. Only in autonomous mode
   it also prints one informational line reporting each settings file's `permissions.defaultMode`
   value (a validated bare word, or `(unset)`/`(unrecognised value)` otherwise) —
   `.claude/settings.json`, `.claude/settings.local.json`, and the user-level settings file
   included — never an allow/deny entry from any of them.

   **Recommended headless invocation**, once this section is on:

   ```bash
   claude -p --permission-mode auto --permission-prompts none "run the cycle"
   ```

   Under `--permission-prompts none`, a would-be permission prompt becomes a denial instead of
   stalling unattended. The skills already escalate a denial durably (see "Durable escalation"
   under "Implementation") and never route around it, so this changes nothing about how a denial
   is handled. The plugin's `PreToolUse` hooks (see "Safety model") still run and still deny
   exactly what they deny today; `--permission-mode auto` and `--permission-prompts none` change
   the CLI's own prompting behavior, never the hooks'.

10. **Governance paths** (optional) — a section titled exactly "Governance paths" declaring extra
    path globs the merge pass's *Governance path list* read (item 5 above) treats as governance,
    on top of the built-in rules below, e.g.:

    ````markdown
    ## Governance paths
    ```
    docs/policies/
    .gitlab-ci.yml
    Jenkinsfile
    renovate.json
    ```
    ````

    Read mechanically by `bin/governance-paths.sh` — the same script the merge pass calls for
    item 5's read, and the one `check-harness.sh` calls (in a validation-only mode, never to
    compute a verdict) — from the section's first fenced code block only; blank lines and
    `#`-prefixed lines inside it are ignored, and every other line is trimmed and treated as one
    glob. **Built-in rules** (case-insensitive, always active whether or not this section exists):
    any path segment equal to `.claude`, `.github` (all of it, not only workflow files), `adr`, or
    `adrs`; or a final segment equal to `CLAUDE.md`, `action.yml`, or `action.yaml`. **Declared
    globs only ever ADD holds** — the result is the built-in test OR the declared test, never a
    replacement or a narrowing. **Glob dialect:** matching is case-insensitive; a glob with no `/`
    matches the path's final segment at any depth (`Jenkinsfile` also catches `ci/Jenkinsfile`); a
    glob with a `/` matches the whole repo-relative path, anchored at the repo root; a trailing
    `/` means "everything beneath" (`docs/policies/` becomes `docs/policies/*`); `*`, `?`, and
    `[...]` follow plain shell `case`-pattern (fnmatch) semantics, and `*` crosses `/` (so `**` is
    no different from `*`); a line starting `!` (negation) or `/` or `./` (a leading slash) makes
    the WHOLE section malformed, fail-closed, rather than silently matching nothing forever. Read
    from the **base tip's** CLAUDE.md only — never the PR head, never the working tree, so a PR
    can't loosen the rule it's held against by editing this section in the same PR. No section, or
    no CLAUDE.md at all at the base tip, means only the built-in rules apply — not an error. A
    malformed section means the merge pass holds every PR (`verdict=error`) until a human fixes
    it; `check-harness.sh` WARNs, never FAILs, naming the malformed reason (`no-fence`,
    `unterminated-fence`, `no-globs`, `negation`, or `leading-slash`) — or, with no section at all,
    PASSes `governance paths: none declared`, or, with a well-formed section, PASSes
    `governance paths: <n> declared glob(s)`. The rule's own words apply beyond any explicit list
    too — a policy/ADR document or CI/build config under a name these rules don't match, and **any
    doubt holds**. Only the merge pass's *Governance path list* read (item 5) and the doctor's
    validation ever read this section; nothing else in the harness does.

The subagents read `CLAUDE.md` at the start of every task — it is the real input that makes
the harness work well in a given repo. Too little and they're guessing; too much and the
contract above drowns in restatement of what the file system, manifests, and linter config
already say. The ten items above are the floor, not a template to pad: leave out directory
tours, framework defaults, and formatter-enforced style, and keep the non-obvious — invariants,
why-this-way decisions, traps a fresh reader would hit — instead. `check-harness.sh` turns "too
much" into a mechanical proxy: it WARNs once `CLAUDE.md` passes 300 lines or 20,000 bytes,
pointing at the harness-setup skill's leanness audit — not at the ten contract items themselves.

## The LESSONS.md contract (project-owned)

`.claude/LESSONS.md` holds project-specific traps — CI quirks, fixture contracts, naming
conventions — that subagents repeatedly trip over. The skills inject relevant entries into every
subagent prompt and append new entries when a failure traces to a gotcha. **The file belongs to
the project, not this toolset**: each project keeps its own `LESSONS.md` (the doctor script
seeds an empty one on install). Format: 1–3 lines per entry, dated, written as an instruction
to a future agent. Because the harness appends lessons mid-run but never commits to the default
branch, uncommitted `LESSONS.md` changes are treated as benign everywhere the skills check for
a dirty tree, and ride along with the next harness commit — but a change that appears while an
implementer or verifier subagent dispatch is in flight is the subagent's, not the harness's, and
blocks the issue instead (the LESSONS.md dispatch guard, #323) —
unless the file already existed untracked before that dispatch started, in which case the guard
has no baseline to take and says so instead of blocking. Since #327, this untracked-baseline gap
no longer applies to an `Edit` or `Write` of `.claude/LESSONS.md` specifically: the
`hooks/claude-dir-guard.sh` `PreToolUse` hook denies that call outright for both roles, tracked or
not, with no orchestrator compare required. Since #340, `hooks/agent-boundary.sh` also denies an
implementer/verifier Bash redirection, `tee`, `cp`, `mv`, `cd`/`pushd`, or in-place `sed` that
targets a `.claude` path segment — closing most of the Bash-issued write route into
`.claude/LESSONS.md` for those two roles specifically. The dispatch guard above is still the only
control on the remaining Bash writers (an interpreter such as `python3 -c "open(...)"` or `perl
-i`, `dd`, `install`, `ln`, or a variable-built path), and still carries the untracked-baseline gap
for those.

Under a Merge autonomy policy (#307, ADR 0001 decision 9), a harness PR that carries a lesson
this way is not automatically held by the *Never the governance surface* rule just because it
touches `.claude/`: `skills/issue-cycle/SKILL.md`'s *Lesson-append carve-out* releases it only
when the *Governance path list* read (#324) establishes `.claude/LESSONS.md` as the PR's sole
governance-surface path, the diff is a pure
end-of-file append (no deleted or changed lines) of at most 40 added lines with no `<!--` in
them, and the added lines, read as data, judge as only a project gotcha — any doubt holds the
PR. Editing, reordering, or deleting an existing entry still holds it, as does any other
`.claude/` change, exactly as before. Every carve-out merge is quoted word for word in the cycle
report and in a durable `<!-- harness-audit -->` issue comment, so a released lesson is never
merged silently.

## The BASELINE.md contract (machine-local)

`.claude/BASELINE.md` records the last **known-green** run of the verification commands on the
default branch: the full commit SHA it ran on, the date, and each command's outcome ("pytest:
631 passed"). It is what makes "the suite was green at N before my change" a checkable fact
across sessions rather than a memory of one chat. Written by `harness-setup`, refreshed
automatically by the implementer/cycle pre-flight whenever the default branch moves past the
recorded commit (green → new baseline; red → the run stops, because a broken main makes every
failure unattributable — that's also the mechanical "two green PRs can still compose badly"
check). It is **machine-local state, not a project document**: keep it gitignored
(`harness-setup` adds the entry; the doctor warns if it's missing or tracked), and never edit
it by hand. `harness-setup` and the implementer/cycle refresh both always write the full SHA; the
doctor's compare against it tolerates an abbreviated recorded value of 7 or more hex characters
as a prefix of the current tip.
