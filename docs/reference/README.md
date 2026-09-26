# Reference documentation

The top-level [README](../../README.md) is the guide: what the harness is, how to get started, the
day-to-day recipes, and how to turn on autonomous mode. This directory is the detailed spec behind
it: every mechanism, guarantee, and honest limit, stated precisely enough to check against the
code. Read the README first; come here when you need the exact rule.

| File | What it covers |
|---|---|
| [workflow.md](workflow.md) | Every stage in detail: kickoff, planning, approval, implementation, resilience, post-merge cleanup, the cycle, the test ratchet, working from the phone, the stop switch, and the full label lifecycle |
| [claude-md-contract.md](claude-md-contract.md) | The sections your repo's `CLAUDE.md` can declare (items 1–10, including every autonomy policy and its hard floor), plus `LESSONS.md` and `BASELINE.md` |
| [settings.md](settings.md) | The per-repo `.claude/settings.json`: every grant and deny, and what the doctor checks |
| [safety-model.md](safety-model.md) | The permission model, the four `PreToolUse` hooks, verdict and approval provenance, trust gates on comments and issue authors, and the single-flight lock |
| [architecture.md](architecture.md) | Repository layout, the model tiering, and the plugin/consumer boundary |
| [codex.md](codex.md) | Installing and running this plugin on the Codex CLI: `codex-setup.sh`, the rules file, contract loading, `--check` drift, the lock's Codex owner contract, and the honest limits |

Decisions about where the harness is heading, rather than how it behaves today, are recorded as
ADRs in [`docs/adr/`](../adr/README.md). Per-PR history lives in [`CHANGELOG.md`](../../CHANGELOG.md).

## Where each section lives

Text in these files often points at another section by its quoted name. This table maps each name
to its file.

| Section | File |
|---|---|
| "Starting a new project", "Planning", "Approval", "Implementation", "Resilience: checkpointing, retries, and the dispatch ledger", "After the human merges", "The steady state, as one command", "The test-suite ratchet", "Working the human gates from the phone" (with its "Returning to a laptop" and "Stopping a cycle" paragraphs), "Label lifecycle" | [workflow.md](workflow.md) |
| "The CLAUDE.md contract" (items 1–10: "Plan auto-approval policy", "Merge autonomy policy", "Post-merge verification", "Test-suite ratchet policy", "Autonomy reserve", "Autonomy decision record", "Autonomy mode", "Governance paths"), "The LESSONS.md contract", "The BASELINE.md contract" | [claude-md-contract.md](claude-md-contract.md) |
| "The per-repo settings file" | [settings.md](settings.md) |
| "Safety model" (with its "Four PreToolUse hooks", "Live-probe record", "Verdict provenance", "Approval provenance", and "One active cycle per checkout" paragraphs) | [safety-model.md](safety-model.md) |
| "What's in here", "The model tiering", "Distribution" | [architecture.md](architecture.md) |
| "Setup", "What `codex-setup.sh` writes", "Rules", "Contract loading", "Upgrades and `--check`", "Lock owner on Codex", "Trust steps", "Honest limits" (Codex) | [codex.md](codex.md) |
| "Prerequisites", "Windows", "Getting started", "Updating", "Working on the harness itself" | the top-level [README](../../README.md) |
| "Durable escalation", "Resilient dispatch" | [`skills/issue-implementer/SKILL.md`](../../skills/issue-implementer/SKILL.md) |
