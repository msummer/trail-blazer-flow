---
name: harness-setup
description: >
  Onboards a repository onto the issue workflow harness (planner → implementer → verifier).
  Use when the user asks to "set up the harness", "onboard this repo", "check the harness
  installation", or right after copying/installing the .claude/ toolset into a repo. Runs the
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
bash .claude/skills/harness-setup/scripts/check-harness.sh
```

Report the full PASS/WARN/FAIL output to the user. The script auto-fixes two safe things
(script exec bits, seeding an empty `LESSONS.md`) and tells you the fix command for everything
else. Then resolve what you can directly:

- Missing labels → run `bash .claude/skills/issue-planner/scripts/setup-labels.sh` and say so.
- Toolchain allow-list WARNs → propose the exact `"Bash(<tool>:*)"` entries to add to
  `.claude/settings.json` (subagents cannot answer permission prompts, so a missing entry
  silently stalls them mid-implementation). Edit the file once the user confirms the tools.
- `gh` auth / `jq` / branch protection → these are the human's to fix; state the command or
  setting and move on.

Re-run the script after fixes; it is idempotent.

### 2. CLAUDE.md audit (the judgment step)

Read the repo's `CLAUDE.md` and judge it against the contract (see "The CLAUDE.md contract"
in `.claude/README.md`) — not "does it exist" but **"could a smaller-model implementer act on
it without guessing?"**:

1. **Verification commands** — are the commands that define "done" stated, copy-pasteable from
   the repo root, and complete (tests AND typecheck/lint/build where the project has them)? Is
   it clear which are authoritative gates vs. advisory?
2. **Setup command** — how dependencies are installed (needed for fresh checkouts/worktrees).
3. **Conventions** — concrete enough that a plan can cite them: code style, patterns,
   security/data rules, schema/migration rules if there is a database.

If `CLAUDE.md` is missing or thin: explore the repo (manifests, CI workflow files, test
configs, existing docs) and **draft** the missing sections — or a full `CLAUDE.md` — and
present the draft to the user for review. `CLAUDE.md` is project-owned: never write or
overwrite it without explicit approval of the draft. CI workflow files are the best source of
truth for verification commands — what CI runs IS the gate.

### 3. Verification baseline

On a clean default branch (run the setup command from CLAUDE.md first if dependencies aren't
installed), run each verification command and record the outcome — e.g. "pytest: 631 passed",
"build: green".

- **All green** → record the baseline numbers in your report. This is the reference every
  future implementation run compares against.
- **Anything red on the default branch** → report it prominently and stop short of declaring
  readiness. A repo whose own gate is red on main cannot use the harness: the implementer
  skill would misattribute the pre-existing failure to the subagent's change. Fixing it is the
  human's call (it may be a known-flaky test — if so, that belongs in CLAUDE.md's verification
  section as a documented exclusion, and in LESSONS.md).

### 4. Readiness report

Summarise for the user:

- Doctor results (after fixes) — anything still WARN/FAIL and who owns it.
- CLAUDE.md verdict — satisfies the contract / draft pending review / gaps named.
- Verification baseline — the exact commands and their green outcomes.
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
  the toolset — drafts are proposals. (The empty LESSONS seed from the doctor script is the
  one exception: it contains nothing project-specific.)
- **Nothing project-specific goes into the toolset files** (skills, agents, this file). Repo
  facts belong in `CLAUDE.md`; gotchas in `LESSONS.md`.
