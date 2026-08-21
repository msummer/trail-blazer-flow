---
name: harness-setup
description: >
  Onboards a repository onto the issue workflow harness (planner → implementer → verifier).
  Use when the user asks to "set up the harness", "onboard this repo", "check the harness
  installation", or right after installing the plugin in a repo. Runs the
  mechanical preflight (doctor script), audits the repo's CLAUDE.md against the harness
  contract (drafting one if needed), establishes a green verification baseline on the default
  branch, and reports readiness. Advisory only — it never gates the other skills, never
  commits, and never overwrites project-owned files without explicit human approval.
---

# Harness Setup

Run this ONCE when the harness is installed into a repo (and any time something feels
misconfigured). It answers one question: **is this repo ready for the planner/implementer/
verifier workflow?** The harness's quality ceiling is set by two things this skill exists to
secure: a contract-satisfying `CLAUDE.md`, and a **known-green verification baseline** — every
implementation run compares against "the suite was green at N before my change", so that
baseline must exist and be true.

You (the main session) do everything here yourself — no subagent dispatches needed.

## Procedure

### 1. Mechanical preflight (the doctor)

```bash
check-harness.sh   # on PATH via the plugin's bin/
```

Report the full PASS/WARN/FAIL output to the user. The script auto-fixes two safe things
(script exec bits, seeding an empty `LESSONS.md`) and tells you the fix command for everything
else. Then resolve what you can directly:

- Missing labels → run `setup-labels.sh` and say so.
- Toolchain allow-list WARNs → propose the exact `"Bash(<tool>:*)"` entries to add to
  `.claude/settings.json` (subagents cannot answer permission prompts, so a missing entry
  silently stalls them mid-implementation). Edit the file once the user confirms the tools.
- `gh` auth / `jq` / branch protection → these are the human's to fix; state the command or
  setting and move on.

Re-run the script after fixes; it is idempotent.

### 2. CLAUDE.md audit (the judgment step)

Read the repo's `CLAUDE.md` and judge it against the contract (see "The CLAUDE.md contract"
in the plugin README) — not "does it exist" but **"could a fresh-context implementer act on
it without guessing?"**:

1. **Verification commands** — are the commands that define "done" stated, copy-pasteable from
   the repo root, and complete (tests AND typecheck/lint/build where the project has them)? Is
   it clear which are authoritative gates vs. advisory?
2. **Setup command** — how dependencies are installed (needed for fresh checkouts/worktrees).
3. **Conventions** — concrete enough that a plan can cite them: code style, patterns,
   security/data rules, schema/migration rules if there is a database.
4. **Leanness** — does a section just restate what an implementer could find in ten seconds (a
   directory listing, "we use React; components live in `src/components`", a framework's own
   defaults, a style rule the linter/formatter already enforces)? Flag it as a trim proposal —
   section, why it's discoverable, proposed action (drop / compress / relocate to
   `.claude/LESSONS.md` if it's really a recurring, incident-derived trap) — for the human to
   decide, never an unapproved edit (see "Project-owned files need approval" below). The
   contract sections above, and any auto-approval / merge-autonomy / test-suite-ratchet policy,
   are never trim targets — lean removes restatement, not the contract. When unsure, keep it.
5. **Plan auto-approval policy (optional)** — if a section titled "Plan auto-approval policy"
   exists, the issue-planner may auto-approve plans that meet its conditions (a hard floor
   still always applies — see the plugin README). Explain the semantics to the user either
   way: no section means every approval is manual. If they want more autonomy, offer to draft
   a conservative starting policy (e.g. *"Auto-approve plans that are size S with no
   data/schema impact and no security-sensitive risks"*) for their review — it's their trust
   decision, in their file, and the `no-auto-approve` label opts individual issues back out.
6. **Merge autonomy policy (optional)** — if a section titled exactly "Merge autonomy
   policy" exists, the `issue-cycle` merge pass may merge PRs that meet its conditions (a
   non-configurable hard floor still applies on top — see the plugin README). Activation is
   a **double opt-in**: the section alone does nothing until the human also lifts the
   `Bash(gh pr merge:*)` deny in `.claude/settings.json`. Both halves are theirs — unlike
   the step-1 allow-list additions, never lift that deny yourself, even if asked to finish
   the setup. Explain the semantics either way: no section means no autonomous merges, and
   every PR merge stays manual. Report which halves are in place: a policy section with the
   deny still standing is inert — the cycle reports `verified, merge blocked` with the exact
   merge command instead of merging. If they want it, offer to draft a conservative starting
   policy (e.g. *"Merge harness PRs whose plan was approved, whose verifier verdict is pass,
   and whose CI is green; never anything touching `db/`, auth, or CI/CD"*) for their review,
   and recommend pairing it with branch protection and required status checks.
7. **Test-suite ratchet policy (optional)** — if a section titled exactly "Test-suite ratchet
   policy" exists, the `test-ratchet` skill (standalone, and as the `issue-cycle` ratchet pass)
   may file coverage-increasing issues on the repo's behalf; a non-configurable hard floor
   applies on top — test-only work, monotonic, capped per run and per open backlog, evidence
   required, `no-auto-approve` on every issue (see the plugin README). No section means the
   ratchet never runs. If the section exists, **run the measurement command it names once** and
   report the figure: a policy whose command doesn't run files nothing, and that is worth
   catching here rather than in an unattended cycle. If they want it, offer to draft a
   conservative starting policy (e.g. *"Measure with `<cmd>`; propose coverage work under
   `src/` only; at most 1 issue per run"*) for their review, and explain the flow — filed issues
   arrive labelled `test-ratchet` + `no-auto-approve`, so every one still gets a human's plan
   review, and closing one as *not planned* vetoes that gap permanently.
8. **Scoped autonomy (optional)** — if sections titled exactly "Autonomy reserve" and/or
   "Autonomy decision record" exist, they make a human-applied grant label checkable: the
   planner adds a "Reserve touch list" to plans and runs `check-decision-record.sh` on
   grant-labelled issues, reporting `grant: will deliver` / `grant: will not deliver` before
   implementation; `check-harness.sh` reports whether both declarations are present and
   well-formed, and whether the declared label exists. This only makes the grant checkable — it
   never decides what the grant means, and the harness never applies or removes the label; that
   stays entirely with this repo and its human. Neither section means nothing changes.

If `CLAUDE.md` is missing or thin: explore the repo (manifests, CI workflow files, test
configs, existing docs) and **draft** the missing sections — or a full `CLAUDE.md` — and
present the draft to the user for review. Draft lean from the start: repo purpose, the
contract sections above, and the non-obvious — invariants, why-this-way decisions, and
cross-cutting traps a fresh reader would violate. Point at the source of truth instead of
copying it, except the verification commands, which stay verbatim and copy-pasteable — they
*are* the contract. `CLAUDE.md` is project-owned: never write or overwrite it without explicit
approval of the draft. CI workflow files are the best source of truth for verification
commands — what CI runs IS the gate.

### 3. Verification baseline

On a clean default branch (run the setup command from CLAUDE.md first if dependencies aren't
installed), run each verification command and record the outcome — e.g. "pytest: 631 passed",
"build: green".

- **All green** → **persist the baseline to `.claude/BASELINE.md`** (don't just report it —
  a baseline that lives only in this chat is gone next session). Write exactly this shape:

  ```markdown
  # Verification baseline (harness-maintained)

  The last known-green run of the project's verification commands on the default branch,
  on THIS machine. Written by harness-setup; refreshed automatically by the
  issue-implementer / issue-cycle pre-flight whenever the default branch moves past the
  recorded commit. Machine-local — keep it gitignored. Do not edit by hand.

  - commit: <full 40-char SHA of the default-branch commit the suite ran on>
  - branch: <default branch>
  - date: <YYYY-MM-DD>
  - results:
    - `<command>`: <outcome, with counts where the tool reports them>
  ```

  Then make sure `.claude/BASELINE.md` is gitignored (append it to `.gitignore` if not — this
  edit is part of the baseline step; tell the user it needs committing). It must never be
  committed: it records one machine's state, and tracking it would dirty the tree on every
  refresh.
- **Anything red on the default branch** → report it prominently, write no baseline, and stop
  short of declaring readiness. A repo whose own gate is red on main cannot use the harness:
  the implementer skill would misattribute the pre-existing failure to the subagent's change.
  Fixing it is the human's call (it may be a known-flaky test — if so, that belongs in
  CLAUDE.md's verification section as a documented exclusion, and in LESSONS.md).

### 4. Readiness report

Summarise for the user:

- Doctor results (after fixes) — anything still WARN/FAIL and who owns it.
- CLAUDE.md verdict — satisfies the contract / draft pending review / gaps named, trim
  proposals if any — and which autonomy policies exist: plan auto-approval (and what it
  allows), and merge autonomy (and whether the `gh pr merge` deny has been lifted, i.e.
  whether the double opt-in is complete) — and the test-suite ratchet (present or absent, and
  whether its measurement command actually runs).
- Verification baseline — the exact commands and their green outcomes, and confirmation that
  `.claude/BASELINE.md` was written (and is gitignored).
- Remaining human items — typically: branch protection, allow-list confirmation, CLAUDE.md
  draft approval.
- An explicit closing line: whether the repo is **ready** for `issue-planner` /
  `issue-implementer`, and if not, the shortest path there.

## Rules

- **Advisory, never enforcing.** The other skills do not check whether this ran. Do not add
  gates, marker files, or state.
- **Never commit or push.** Everything this skill writes (allow-list entries, LESSONS seed,
  an approved CLAUDE.md) is left in the working tree for the human to review and commit.
- **Project-owned files need approval.** `CLAUDE.md` and `LESSONS.md` belong to the repo, not
  the toolset — drafts are proposals. (Two exceptions: the empty LESSONS seed from the doctor
  script, which contains nothing project-specific, and `.claude/BASELINE.md`, which is
  harness-maintained machine state — writing and refreshing it is the harness's job, which is
  why it stays gitignored.)
- **Nothing project-specific goes into the toolset files** (skills, agents, this file). Repo
  facts belong in `CLAUDE.md`; gotchas in `LESSONS.md`.
