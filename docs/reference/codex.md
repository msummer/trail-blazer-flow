# Codex compatibility

> Part of the [reference documentation](README.md). See [`docs/adr/0002-codex-compatibility.md`](../adr/0002-codex-compatibility.md)
> for the direction, the probe results this reference draws on, and the decisions still pending a
> live check.

This plugin installs unchanged on the Codex CLI (`codex plugin add trail-blazer-flow@trail-blazer-flow`,
or from a local clone / a public GitHub repo). Its skills and hooks load; `bin/codex-setup.sh`
adds the pieces Codex needs that a Claude Code consumer gets for free: custom agent files, an
unsandboxed-command rules file, and a way to load `CLAUDE.md` as the project contract. Codex
support ships **supervised only** — see "Honest limits" below.

## Setup

Run once per repo, from a normal (non-sandboxed) terminal, after trusting the plugin in Codex:

```
bash <plugin root>/bin/codex-setup.sh
```

It writes or updates the files below, printing one `wrote=<relpath>` or `unchanged=<relpath>`
line per file, then — only if it wrote at least one file — three `next:` lines naming the
remaining trust steps (see "Trust steps"). Run it again after every plugin upgrade: the
installed rules file's paths carry the version.

## What `codex-setup.sh` writes

Relative to the repo's git toplevel:

- **`.codex/agents/planner.toml`, `implementer.toml`, `verifier.toml`** — one Codex custom agent
  file per `agents/<role>.md` in this plugin. Each has `name` (the bare role), `description`
  (the frontmatter's folded or inline description, `\` then `"` escaped), and
  `developer_instructions` (a TOML multi-line literal string byte-identical to the agent's body —
  everything after the frontmatter's closing `---`). No `tools` or `model` key: Codex's custom
  agent schema has nothing corresponding to `agents/planner.md`'s `tools:` read-only list (ADR
  0002 P2), and `sandbox_mode`/`model` keys don't hold against a config-sourced parent sandbox
  either (ADR 0002 P2, amendment 2026-09-26).
- **`.codex/rules/trail-blazer-flow.rules`** — `templates/codex.rules` with the plugin-bin
  placeholder substituted for this install's own `bin/` directory (an absolute, logical path —
  never resolved through a symlink). See "Rules" below.
- **`AGENTS.md` (edited, never created) or `.codex/config.toml`** — see "Contract loading" below.

A repo path or plugin install path containing whitespace is unsupported: write mode refuses
(exit 2, nothing written); `--check` reports it and exits 1. A plugin install path containing a
character outside `[A-Za-z0-9._/@+:-]` is unsupported the same way — this keeps the rules
template's `sed` substitution and the generated Starlark string both safe.

## Rules

Codex's rules format (`.rules` files, `prefix_rule`/`host_executable`, matched by
[ADR 0002](../adr/0002-codex-compatibility.md)'s P3/Q1 probes) lets a command run **outside the
sandbox** when it matches an `allow` rule, refuses it outright when it matches a `forbidden`
rule, and otherwise leaves it to the sandbox. `templates/codex.rules` has three sections:

- **Allow** — the harness's own git/`gh` usage: `git add`, `commit`, `push`, `fetch`, `pull`,
  `checkout`, `switch`, `restore --staged`, `reset --soft`, and `gh` (widened from the issue's own
  list per the maintainer's ADVISORY Q1 decision — the orchestrator skills also issue `git
  checkout <default-branch>`, `git pull --ff-only`, and `git restore --staged`, none of which the
  narrower list would have covered).
- **Forbidden** — a port of `templates/repo-settings.json`'s bare deny entries (the ones with no
  `git -C` prefix, which Codex's rules can't express at all): `gh pr merge`, `git push --force`
  (and `-f`, `--force-with-lease`), `git reset --hard`, `git clean`, `rm -rf`, `git branch -D
  main`, `git push origin main`.
- **Gated** — the ten harness scripts that call `gh` (directly, or through `harness-status.sh`)
  or write inside `.git` (`check-decision-record.sh`, `check-harness.sh`, `cleanup-after-merge.sh`,
  `find-implementation-work.sh`, `find-planning-work.sh`, `harness-lock.sh`, `harness-status.sh`,
  `harness-stop.sh`, `reconcile-ledger.sh`, `setup-labels.sh`) each get an `allow` rule on their
  bare name **plus** a `host_executable` pin to this install's own absolute `bin/` path. The pin
  matters: an ungated bare-name rule matches *any* file with that basename, anywhere — including
  one a subagent writes into the workspace — so every `.sh` allow rule in the installed file is
  `host_executable`-gated, with no exception. `codex-setup.sh`, `harness-version.sh`, and
  `governance-paths.sh` are read-only (or, for `codex-setup.sh`, run once from a normal terminal —
  ADVISORY Q4) and so are never gated.

### Script reach

A skill invokes each harness script by its own absolute install path, resolved from the skill
file's own location — never `bash <path>` (a rule matches the program name, and `bash` is the
program when a script is invoked that way, not the script itself — ADR 0002 amendment
2026-09-26(2), Q1) — and always as one invocation with no redirection or `&&` chain folded in (a
command carrying a redirection is matched as a single unit against the rule, and the redirected
part has no rule of its own — ADR 0002 amendment 2026-09-26, P3).

## Contract loading

Codex loads `CLAUDE.md` as the project contract one of two ways, and the two don't compose (an
`AGENTS.md` shim suppresses the deterministic fallback entirely — ADR 0002 amendment
2026-09-26(2), Q5):

- **The repo already has an `AGENTS.md`.** `codex-setup.sh` adds exactly one marked block:

  ```
  <!-- trail-blazer-flow:contract-pointer -->
  The harness contract for this repo is CLAUDE.md. Read CLAUDE.md before any work.
  <!-- /trail-blazer-flow:contract-pointer -->
  ```

  appended if absent, rewritten in place if present but different. A malformed marker is
  refused (write mode exits 2; `--check` reports `malformed-pointer`) rather than guessed at:
  an unpaired, duplicated, or out-of-order marker, or any line that carries a marker string
  without being exactly that marker (trailing text, a CR line ending, indentation, or a mention in
  prose). A lone or non-exact mention is refused until it is edited; a quoted begin/end pair that
  sits on its own two lines (for example inside a code fence) is indistinguishable from a real
  pointer block and is rewritten as one. `.codex/config.toml`'s fallback key is never touched in this branch.
- **No `AGENTS.md`.** `codex-setup.sh` writes
  `project_doc_fallback_filenames = ["CLAUDE.md"]` into the repo's `.codex/config.toml` (inserted
  before the first `[table]` header if the file already exists without the key). A pre-existing
  top-level value that doesn't name `CLAUDE.md` is a conflict: write mode refuses (exit 2, file
  untouched); `--check` reports `reason=fallback-conflict`.

`codex-setup.sh` never creates a new `AGENTS.md` — doing so would suppress the fallback it just
configured. Only a repo-root `AGENTS.md` is recognised; `AGENTS.override.md` and any nested
`AGENTS.md` are ignored.

## Upgrades and `--check`

`.codex/rules/trail-blazer-flow.rules`' `host_executable` paths carry the installed plugin's own
version, so re-run `codex-setup.sh` after every upgrade. `--check` is the read-only drift mode
#410's doctor consumes: it never writes, never creates `.codex/`, and reports one of two line
shapes per file:

- `ok=<relpath>` — already current.
- `drift=<relpath> reason=<token>` — one of `missing`, `differs`, `stale-plugin-path` (the rules
  file's own content differs AND at least one installed `host_executable` path's directory isn't
  this install's `bin/`), `missing-fallback`, `fallback-conflict`, `missing-pointer`, or
  `malformed-pointer`.

An unsupported path instead prints `unsupported=<plugin-root|repo-path>
reason=<whitespace|unsupported-character> path=<p>`. `--check` exits 0 when everything is
current, 1 when anything drifted or a path is unsupported, 2 on a usage or environment error
(not inside a git repository, a broken plugin install missing its own `agents/*.md` or
`templates/codex.rules`).

## Lock owner on Codex

`bin/harness-lock.sh acquire` records an owner pid with precedence `--owner-pid <pid>` >
`TBF_OWNER_PID` > `${CLAUDE_PID:-$PPID}` (the original Claude Code rule, unchanged when neither
flag nor env var is given). Under `codex exec` or `codex --no-daemon`, the session's own native
`codex` process is every shell call's `$PPID` for the whole session (ADR 0002 P6), so a Codex
caller that can't rely on that fallback passes it explicitly:

```
harness-lock.sh acquire --owner-pid "$PPID"
```

The **default Codex TUI** instead starts a shared, long-lived `app-server` daemon and runs the
session inside it — that daemon's pid outlives every session it serves, so a lock recorded
against it would never be reclaimed. `acquire` refuses outright (exit 2, before creating
anything) whenever the resolved owner's own command line contains `app-server`, and names `codex
--no-daemon` in its stderr. **Run harness sessions with `codex --no-daemon`.** The check reads
`ps -o command= -p <pid>` and fails open (proceeds) when `ps` can't answer — a daemon owner that
slips through this way only ever produces a never-reclaimed lock, with the same
`harness-lock.sh release --force` remedy as any other unreclaimable lock.

## Trust steps

After a successful write, `codex-setup.sh` prints three reminders:

1. **Trust the project in Codex** — its rules and agents load only once the project is trusted.
2. **Trust the plugin's hooks** — they install `untrusted` and are skipped silently otherwise
   (ADR 0002 amendment 2026-09-26, P5); trusting them needs the same review as any other hook.
3. **Run harness sessions with `codex --no-daemon`** — see "Lock owner on Codex" above.

## Honest limits

- **Supervised only.** Per [ADR 0002](../adr/0002-codex-compatibility.md) decision 4, Codex
  support ships without merge autonomy or autonomous mode until a live trial has exercised the
  hook layer that is Codex's entire enforcement floor (the sandbox adds nothing for a subagent —
  it can't be made read-only, and an allow rule that lets the orchestrator's `git`/`gh` through
  lets every agent's through, ADR 0002 amendment 2026-09-26, P2/P3).
- **Forbidden rules match by prefix, the same coarse shape as the Claude template's bare deny
  entries.** `git push origin --force`, `rm -fr`, `--force-with-lease=<ref>`, anything behind a
  redirection or a `bash -c` wrapper, and every `git -C <path> ...` form (which Codex's rules
  can't express at all) are not matched. The hooks (`agent-boundary.sh`, `push-guard.sh`) remain
  the floor regardless of what the rules file allows.
- **Not yet live-verified; deferred to #411's release gate:** that Codex actually loads a
  project-level `.codex/rules/*.rules` file the way its documented rules
  precedence implies (the ADR's own probes used `$CODEX_HOME/rules/default.rules`); that a
  command carrying an expanded `$PPID` (`harness-lock.sh acquire --owner-pid "$PPID"`) still
  matches a gated prefix rule; and that `host_executable` matching resolves a command's logical
  absolute path the way this file assumes. If any of these doesn't hold, the affected scripts run
  sandboxed and fail loudly (a permission error), which is safe — just noisy — rather than unsafe.
- **The installed rules file is machine-specific.** Its `host_executable` paths embed this
  install's own absolute plugin path, which varies by machine and by plugin version. Keep
  `.codex/rules/trail-blazer-flow.rules` out of version control (for example, via
  `.git/info/exclude`) — `codex-setup.sh` never edits `.gitignore` itself. The generated agent
  TOMLs and `.codex/config.toml` carry no machine-specific paths and may be committed.
