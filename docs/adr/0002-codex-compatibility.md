# ADR 0002 — Codex compatibility

- **Status:** Accepted, 2026-09-16, for direction and sequencing (maintainer decision). Choices
  marked *pending probe* are settled by the probe issue (#314) and recorded by amending this ADR.
- **Verified against:** `main` at `4402354` (v2.7.3); Codex CLI 0.136.0 as installed
  (`codex features list`, `codex exec --help`); the Codex manual (developers.openai.com/codex,
  fetched 2026-09-16, which describes CLI 0.147.0); and the openai/codex source on `main`.

## Context

Two external reviews written with Codex (2026-08-30 of v2.4.0 and 2026-09-06 of v2.6.0; not in
this repo) sketched Codex support: a provider-neutral layout, an `AGENTS.md` shim, Codex
packaging, and a `codex exec --output-schema` adapter. Since then the harness has gained three
PreToolUse hooks, the run lock and version provenance, and the Codex CLI has gained hooks, skills,
plugins and custom agents. This ADR re-baselines against both.

### What carries over

- **Scripts.** About 5% of `bin/` (183 of 3,896 lines) mentions Claude or a Claude permission
  rule, and `bin/find-planning-work.sh` and `bin/reconcile-ledger.sh` mention neither. Most of
  those lines (119) are in `bin/check-harness.sh`, which reads Claude settings files.
- **Skills.** Codex loads `SKILL.md` skills with `name`/`description` frontmatter — the only keys
  these skills use (manual, "Skills").
- **Shell-command hooks.** Codex's `PreToolUse` event fires for shell commands matched as `Bash`,
  with the command string in `tool_input.command`. Exit 2 blocks, and when several hooks match, any
  block wins (openai/codex, `pre_tool_use.rs`). `hooks/push-guard.sh` and
  `hooks/agent-boundary.sh` fit that contract as written. The boundary hook also needs the calling
  agent's role in `agent_type`, a field present in the 0.136.0 hook input schema but not yet
  observed at runtime.
- **File-edit hooks.** `apply_patch` reaches `PreToolUse` as well, matchable as `apply_patch`,
  `Edit` or `Write` (manual, hooks, "Tool coverage").
- **Packaging and the contract file.** The 0.136.0 binary recognises `.claude-plugin/plugin.json`.
  `project_doc_fallback_filenames` lets Codex load `CLAUDE.md` where `AGENTS.md` is missing, and
  the skills read `CLAUDE.md` by path anyway.
- **Headless runs.** `codex exec` supports `--json`, `--output-schema`, `--ephemeral` and
  `--sandbox`. In non-interactive flows, "an action that needs new approval fails and Codex
  surfaces the error back to the parent workflow" (manual, subagents, "Approvals and sandbox
  controls").

### What doesn't

- **The sandbox protects `.git`.** In `workspace-write`, `.git` — including a worktree's resolved
  gitdir — is read-only, and network access is off by default (manual, "Protected paths in
  writable roots"). Committing, pushing and every `gh` call need escalation outside the sandbox, or
  `danger-full-access`.
- **Subagents inherit the parent's sandbox.** Codex "reapplies the parent turn's live runtime
  overrides … even if the selected custom agent file sets different defaults" (manual, "Approvals
  and sandbox controls"). A custom agent can be marked read-only, but that doesn't hold against a
  runtime override such as `--yolo`.
- **Agents can't be limited to certain tools.** A custom agent file (`.codex/agents/*.toml`)
  requires `name`, `description` and `developer_instructions`, and may set config keys such as
  `model` and `sandbox_mode` (manual, "Custom agent file schema"). Nothing in it corresponds to the
  `tools:` list that makes `agents/planner.md` read-only today.
- **No deny list inside the sandbox.** Codex rules (`.rules` files, `prefix_rule`) allow, prompt
  for, or forbid command prefixes for commands run *outside* the sandbox (manual, "Rules"). The 16
  deny entries in `templates/repo-settings.json` have no direct equivalent.
- **Hooks are documented as a guardrail.** "Treat tool hooks as a useful guardrail, not a complete
  enforcement boundary" (manual, hooks, "Tool coverage").
- **`hooks/git-c-guard.sh` has no effect.** Codex rejects a `PreToolUse`
  `permissionDecision: "allow"` without `updatedInput` as unsupported (`output_parser.rs`);
  approving a command takes a `PermissionRequest` hook. The per-handler `if` filter in
  `hooks/hooks.json` isn't a Codex field and is ignored.
- **Plugins can't ship agents or put scripts on PATH.** A Codex plugin manifest carries skills,
  MCP servers, apps, hooks and interface metadata (`core-plugins/src/manifest.rs`), but not
  agents, and nothing adds a plugin's `bin/` to the shell PATH.
- **Doctor and lock.** About 390 of `bin/check-harness.sh`'s 1,055 lines read Claude settings
  files. `bin/harness-lock.sh` records `CLAUDE_PID`, which Codex doesn't set.
- **Scheduling.** The CLI has no `/loop`; unattended runs need an external scheduler driving
  `codex exec`.

### Coupling at `4402354`

Matching lines per `git grep -n`, excluding `docs/`; counts include the `dev/` test harnesses.

| Dependency | Lines / files |
|---|---|
| `claude/` branch prefix | 145 / 15 |
| `.claude/` paths | 155 / 16 |
| `CLAUDE.md` as the contract file | 248 / 24 |
| `CLAUDE_*` environment variables | 57 / 11 (`CLAUDE_PID`: 35 lines) |
| `Bash(…)` permission-rule syntax | 216 / 14 |
| Hook payload fields: `agent_type` / `tool_input` / `tool_name` / `permission_mode` | 68 / 38 / 33 / 20 lines |

### Where the earlier reviews are out of date

- "git-c-guard emits a Codex-compatible decision": it doesn't; Codex rejects the allow.
- A read-only sandbox for the verifier: today's verifier makes transient mutation-probe edits.
- A separate `.codex-plugin/` manifest with bundled `.codex/agents/`: the 0.136.0 binary
  recognises the existing manifest format, and plugins can't bundle agents.
- Neither review names the constraints that decide feasibility: the protected `.git` and sandbox
  inheritance.

## Decision

1. **Probe before building.** Run the probe session (#314) against a current Codex CLI before
   any implementation issue is filed. Its results amend this ADR and set the minimum supported
   Codex version.
2. **One plugin tree, no fork.** `skills/`, `bin/` and `hooks/` stay shared. Codex-specific pieces
   are added alongside them: agent definitions installed by `harness-setup` (plugins can't ship
   them), a way for skills to find the scripts, and a Codex branch in the doctor.
3. **On Codex, hooks are the enforcement layer.** The git/`gh` boundary, the default-branch push
   guard, and a hook port of the template's deny entries enforce the floor. The planner's
   read-only guarantee becomes a role-keyed hook that denies edits and commands that aren't
   read-only. The sandbox adds an outer layer wherever a probe shows it holds (*pending probe*: P2,
   P3).
4. **Codex runs start supervised.** Because Codex itself describes hooks as a guardrail, Codex
   support ships without merge autonomy or autonomous mode (ADR 0001) until a live trial has
   exercised the hook layer.
5. **Names stay.** `CLAUDE.md` stays the contract file, and the `claude/` branch prefix and
   `.claude/` paths stay, on both providers. A provider-neutral rename remains a 3.0 breaking
   change, because `bin/cleanup-after-merge.sh` and the issue-cycle merge floor key on
   `claude/<n>-`.
6. **Slices, in order:** (i) the probe session; (ii) planning on Codex — read-only, lowest risk;
   (iii) supervised implement and verify; (iv) unattended runs via `codex exec` and an external
   scheduler, once ADR 0001's durable escalations and stop switch exist.

### Probes

| Probe | Question | Unlocks |
|---|---|---|
| P1 | Does `PreToolUse` carry the spawned custom agent's name in `agent_type` at runtime? | `hooks/agent-boundary.sh` unchanged; the planner read-only hook |
| P2 | Does a custom agent's `sandbox_mode = "read-only"` hold when the parent's sandbox comes from configuration rather than a runtime override? | A sandbox-level read-only planner |
| P3 | Can the orchestrator stay in `workspace-write` and run only `git` commit/push and `gh` outside the sandbox through rules or a permission profile — and can a subagent use the same escalation? | Whether `.git` protection also constrains subagents |
| P4 | What payload does an `apply_patch` call give `PreToolUse` on the installed version, and does a block stop the edit? | The planner read-only hook |
| P5 | Does this repo install as a Codex plugin unchanged — do its skills and hooks load, and what does Codex do with `hooks/git-c-guard.sh`'s unsupported allow? | Packaging |
| P6 | Which process id stays alive across shell calls within one Codex session? | The `bin/harness-lock.sh` adapter |
| P7 | Under `codex exec`, how does a subagent's escalation or failed approval reach the orchestrator? | A headless cycle; ADR 0001 decision 3 |

## Consequences

- Most of the harness logic ports as is; the provider-specific layer is packaging, the doctor, the
  lock and the hook contract.
- Codex's safety posture is weaker by construction: three layers on Claude Code (agent tool lists,
  the settings allow/deny list, hooks) become hooks plus a coarse sandbox. Decision 4 is the
  mitigation.
- From then on, every hook change is tested against both payload shapes in `dev/hook-tests.sh` — a
  standing cost on the part of the repo that has needed the most review rounds.
- Nothing here changes behavior for Claude Code consumers.
