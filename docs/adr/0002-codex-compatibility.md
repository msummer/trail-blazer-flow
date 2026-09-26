# ADR 0002 — Codex compatibility

- **Status:** Accepted, 2026-09-16, for direction and sequencing (maintainer decision). Choices
  marked *pending probe* are settled by the probe issue (#314) and recorded by amending this ADR.
  Amended 2026-09-26 with the probe results — see "Amendment 2026-09-26" at the end, which
  supersedes the sections above wherever they disagree.
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

## Amendment 2026-09-26: probe results (#314)

- **Verified against:** plugin at `main` `5b7ceb9` (v2.9.0), installed unchanged; Codex CLI
  0.156.1 (P1–P7) and 0.157.1, the latest release on npm that day (P1–P7 repeated with the same
  results, plus the `forbidden`-rule check, which ran on 0.157.1 only); macOS Seatbelt sandbox. The coupling table above stays
  pinned to `4402354` and was not recounted.
- **Method:** a throwaway fixture repo and a separate `CODEX_HOME`, both outside this repo.
  `config.toml` set `sandbox_mode = "workspace-write"` and trusted the fixture project. A user
  hook on `SessionStart`, `PreToolUse` (matcher `.*`), `PermissionRequest`, `SubagentStart` and
  `SubagentStop` logged every stdin payload and the hook's parent pid. Custom agents `probe_ro`
  (`sandbox_mode = "read-only"`), `probe_rw`, `implementer` and `verifier` lived in
  `.codex/agents/`. The bare remote was served over `git://127.0.0.1`, so a push needs the
  network; a remote on disk under `/tmp` doesn't, because `/tmp` and `$TMPDIR` are writable roots.
  Every run was `codex exec --json` with a prompt naming the exact commands. Hooks were trusted by
  writing the `hooks.state.<key>.trusted_hash` values that app-server `hooks/list` reports (what
  the TUI's "Trust all" persists), not with `--dangerously-bypass-hook-trust`.

### Answers

**P1: yes.** Every `PreToolUse`, `SubagentStart` and `SubagentStop` payload from a spawned
custom agent carries `agent_type` (the agent file's bare `name`) and `agent_id`. The main
session's payloads carry neither key:

```
{"hook_event_name":"PreToolUse","agent_type":"probe_ro","agent_id":"01a0dc89-e95b-…","tool_name":"Bash","tool_input":{"command":"touch ro_test.txt && echo touched"},"permission_mode":"bypassPermissions",…}
```

With agents named `implementer` and `verifier`, the unchanged `hooks/agent-boundary.sh` enforced
both roles live: `implementer role may not run any of: git gh (blocked: git push)`, and `verifier
role may only run read-only git (…) (blocked: git commit)`. `permission_mode` reads
`bypassPermissions` under `codex exec` even with the sandbox on, so no hook may rely on it.

**P2: no.** The parent's `workspace-write` came from `config.toml`, with no `-s` and no `-c`. A
custom agent with `sandbox_mode = "read-only"` still ran `touch ro_test.txt` successfully. Its
rollout shows the agent file loaded (`agent_role: "probe_ro"`, its instructions present) and
`"sandbox_policy":{"type":"workspace-write",…}`. The agent-file key doesn't hold against a
config-sourced parent sandbox either.

**P3: yes, for both, through rules; no permission profile is needed.** Two allow rules were in
`$CODEX_HOME/rules/default.rules`: `prefix_rule(pattern = ["git", ["add", "commit", "push"]],
decision = "allow")` and `prefix_rule(pattern = ["gh"], decision = "allow")`. The matching
commands then ran outside the sandbox automatically, with no escalation request and under
`codex exec`'s forced `never` approvals. This held for the orchestrator and for a subagent alike:
both committed, pushed to the network remote, and got `5000` from `gh api rate_limit --jq
.rate.limit`. The control run used the same prompt with `--ignore-rules`, and every one of these
commands failed:

- `git add`: `Unable to create '…/.git/index.lock': Operation not permitted`;
- `git push`: `unable to connect to 127.0.0.1: … Operation not permitted`;
- `gh`: `error connecting to api.github.com`.

An unlisted command (`git tag`) stayed sandboxed and failed in both runs. Three consequences:

- `.git` protection doesn't constrain a subagent once rules exist, because rules apply to the
  whole session, not per agent.
- An allow rule is an unsandboxed pass. `hooks/push-guard.sh` is all that stands between an
  allowed `git push` and the default branch, and it held (`denies pushing to "main"`).
- A command with a redirection is matched as one invocation, so `echo one > orch.txt && git add
  orch.txt` missed the `git add` rule and failed in the sandbox. A command that relies on a rule
  must be issued on its own.

**P4.** `apply_patch` reaches `PreToolUse` as `tool_name: "apply_patch"`, with the whole patch in
`tool_input.command`. Paths are relative to the cwd, and there is no `file_path`:

```
{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: allowed.txt\n+allowed\n*** End Patch"},…}
```

A hook's exit 2 stops the edit, for the orchestrator and for a subagent: the file is not
created. The model sees `Command blocked by PreToolUse hook: <stderr>. Command: *** Begin Patch
…`. A matcher of `Edit|Write` also fires on `apply_patch`.

**P5: installs unchanged, with gaps.**

- **Install.** `codex plugin marketplace add <clone>` reads `.claude-plugin/marketplace.json`, and
  `codex plugin add trail-blazer-flow@trail-blazer-flow` installs 2.9.0.
- **Skills.** All six load, named `trail-blazer-flow:<skill>`.
- **Hooks.** All four `hooks/hooks.json` handlers load with `${CLAUDE_PLUGIN_ROOT}` expanded. They
  start `untrusted`: plugin hooks need the same trust review as any other hook. `git-c-guard`'s
  `if` key is dropped without a warning, so that hook now runs on every shell call.
- **`push-guard.sh` and `agent-boundary.sh`** work as written (P1, P3). A logged Codex payload
  replayed through `agent-boundary.sh` also gets the #387 interpreter `.claude`-write deny.
- **`claude-dir-guard.sh`** has no effect. It fires on `apply_patch` through `Edit|Write`, but it
  reads `tool_input.file_path`, which Codex doesn't send, so it exits 0. The implementer created
  `.claude/settings.local.json`.
- **`git-c-guard.sh`.** Its allow is ignored silently: no warning appears in stderr, the `--json`
  stream or the rollout. `git -C ../repo-wt-1 commit --allow-empty` still ran sandboxed and failed
  on `.git/worktrees/repo-wt-1/index.lock`.
- **Scripts.** `bin/` isn't on the shell PATH, and `CLAUDE_PLUGIN_ROOT` and `PLUGIN_ROOT` are
  unset in shell commands.

**P6: the `codex` process.** Under `codex exec`, one native `codex` process is every shell call's
`$PPID` and every hook's parent, for the whole session, subagents included. `$$` changes on
every call: `shell pid=47459 ppid=47319`, then `shell pid=47483 ppid=47319`, then subagent `sub
pid=47584 ppid=47319`, with hook parent `47319 … /bin/codex`. A shell command can therefore pass
`CLAUDE_PID=$PPID`. Two caveats:

- An interactive TUI session was not probed, because it can't be driven headless. Its lineage is
  checked in slice (ii). A TUI attached to the shared app-server daemon (`daemon_auto_start` is
  off by default) would put a daemon shared across sessions in that position.
- A Codex started from inside a Claude Code session inherits that session's `CLAUDE_PID`: the
  probe's shells saw the parent Claude Code session's pid. The adapter must always set the
  variable and never rely on it already being set.

**P7: it reaches the orchestrator only through the subagent's own report.**

- **Approvals are pinned.** `codex exec` forces approvals to `never`. The config's
  `approval_policy = "on-request"` and a `-c approval_policy="on-request"` override both came out
  as `Approval policy is currently never`.
- **Needs approval.** A command that needs approval (a `prompt` rule) is rejected before it runs:
  `Rejected("approval required by policy, but AskForApproval is set to Never")`.
- **Escalation.** An escalation request is rejected outright: `approval policy is Never; reject
  command — you cannot ask for escalated permissions if the approval policy is Never`.
- **Where it shows up.** Both errors reach only the calling agent's tool result:
  - no `PermissionRequest` hook fires;
  - the `--json` stream has no approval event;
  - the only other trace is an `ERROR codex_core::tools::router` line on stderr that doesn't
    name the agent.

The orchestrator learns of a failed approval only if the subagent's final message reports it.

### Corrections to "What doesn't carry over"

- **Deny list.** There is one after all. A `forbidden` rule rejects a matching command before it
  runs, sandboxed or not: `` `/bin/zsh -lc 'git stash list'` rejected: probe: forbidden ``
  (0.157.1). A `prompt` rule does the same under `codex exec` (P7, both versions). Rules match by
  prefix, with the same single-invocation limit as P3.
- **Sandbox inheritance.** An agent file's `sandbox_mode` doesn't hold against a config-sourced
  parent sandbox either, not only against a runtime override (P2).
- **`hooks/git-c-guard.sh`.** Codex ignores its allow silently. It isn't reported as a failure.
- **Writable roots.** `/tmp` and `$TMPDIR` are writable roots by default, alongside the workspace.
- **Headless errors.** The manual says Codex "surfaces the error back to the parent workflow".
  In practice the error reaches only the subagent (P7).

### Minimum supported Codex version

**0.156.1.**

### Effect on the decisions

- **Decision 3.** The sandbox adds no layer for subagents. It can't make an agent read-only
  (P2), and a rule that allows the orchestrator's git/`gh` allows them for every agent (P3). On
  Codex the floor is hooks and rules only:
  - `hooks/agent-boundary.sh` and `hooks/push-guard.sh`, unchanged;
  - a `claude-dir-guard` and a planner read-only hook that read the `apply_patch` patch text;
  - a rules file installed per repo: `allow` for the harness's own git/`gh` prefixes, and
    `forbidden` for the template's deny entries.
- **Decision 6.** Slice (iv)'s prerequisite (ADR 0001's durable escalations and stop switch)
  shipped in v2.8.0. Under `codex exec`, a subagent's failed approval is visible only in its own
  report (P7). Slice (iv) must therefore treat a missing or malformed report as an escalation.
