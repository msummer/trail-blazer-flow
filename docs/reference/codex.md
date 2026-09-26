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

## The doctor on Codex

`bin/check-harness.sh --provider codex` (#410) runs a different, additive check set after the
shared preamble (git remote, `gh`, `jq`, default branch, labels, exec bits, harness version,
`CLAUDE.md`, `LESSONS.md`) — with `--provider claude` (the default) or no flag at all, the doctor
is byte-for-byte unchanged. An unrecognised `--provider` value, or any other unrecognised
argument, exits 2 before any check runs; `-h`/`--help` exits 0.

- **git/jq preflight.** If `git` isn't on `PATH`, the doctor FAILs and exits 1 immediately (before
  even locating the repo). The `jq` FAIL adds a Codex-specific clause: the plugin's hooks
  (`hooks/planner-guard.sh` included) fail open without it, so a missing `jq` is silently
  unenforced, not merely unchecked.
- **Codex version.** FAILs below a floor (`CODEX_MIN_VERSION` in `bin/check-harness.sh`, currently
  `0.156.1`), compared numerically component-by-component against the first `X.Y.Z` triple on
  `codex --version`'s first line (a pre-release suffix like `-alpha` is ignored). Fix: upgrade
  Codex. FAILs the same way when `codex --version` prints no triple, or when `codex` isn't
  installed at all.
- **Plugin/repo paths.** FAILs when the plugin's install root or this repo's own path contains
  whitespace — both would break the rules file's `sed` substitution (see "What `codex-setup.sh`
  writes" above). Fix: move the install or the repo to a path with no spaces.
- **Setup in sync.** Runs `bin/codex-setup.sh --check` by a fixed path. FAILs "out of sync" and
  lists up to six of its `drift=`/`unsupported=` lines (see "Upgrades and `--check`" above) when
  anything has drifted; fix by re-running `bin/codex-setup.sh` from a normal terminal. FAILs
  "could not check" when the script is missing, not executable, or exits any other way.
- **Hook trust.** Starts `codex app-server` and sends exactly two read-only JSON-RPC requests plus
  the `initialized` notification — `initialize` (naming this doctor and the installed plugin
  version in `clientInfo`, which a real `codex app-server` requires before it will answer
  anything else), `initialized`, and `hooks/list` scoped to this repo's git toplevel — bounded so
  the exchange can never hang (a kill fallback fires after at most `CODEX_HOOKS_LIST_WAIT + 2`
  one-second polls). **This check only ever lists hook trust state; it never trusts a hook
  itself** — auto-trusting would defeat Codex's own review gate, and doing it from a doctor script
  would make the floor meaningless. FAILs "could not check" when `codex` or `jq` is missing, or
  when the plugin's expected hook set can't be determined at all (`hooks/hooks.json` missing,
  unreadable, or unparseable); FAILs "no hooks/list reply" or "rejected hooks/list" when the
  exchange itself fails; FAILs "hook configuration error(s)" when Codex itself reports one; FAILs
  "not loaded by Codex" when a plugin hook the plugin ships isn't an enabled `source: "plugin"`
  entry in the reply; FAILs "hook(s) not trusted" when any enabled hook (plugin, user, or project)
  reports a `trustStatus` other than `trusted` or `managed` — its key sanitised to
  `[A-Za-z0-9._:/@-]` (any other character becomes `?`) before it's ever printed. Fix for the last
  two: open Codex's own hook review and trust all of this plugin's hooks ("Trust all") — an
  untrusted hook is skipped silently by Codex, with no other warning.
- **Manual merge.** Always PASSes — merge autonomy doesn't exist on Codex, so every PR merge is
  manual. When `CLAUDE.md` declares a "Merge autonomy policy" and/or "Autonomy mode" section, the
  PASS names them as not applying here; neither section's own verdict line (`merge autonomy:`,
  `autonomy mode:`) ever prints on Codex.

The shared baseline check and the branch-protection check still run afterward. Branch protection
gets one Codex-specific change: a missing or unreadable protection document is a **FAIL** on
Codex (`push-guard.sh` and branch protection are all that stand between an allowed `git push` and
the default branch), where it's only a WARN on Claude Code; `gh` not ready, or an unknown default
branch, is also a FAIL on Codex rather than a silent skip. The strictness sub-checks
(`required_status_checks.strict`, required contexts, required reviews) stay gated on merge
autonomy being effectively active, which never happens on Codex, so they never print here.
**Rulesets limit:** the doctor detects protection only through GitHub's legacy
`repos/<r>/branches/<b>/protection` endpoint, which doesn't see a repository ruleset — a repo
protected only by a ruleset gets a FAIL here even though pushes are, in fact, blocked (tracked as
a follow-up).

Everything the settings-file union, toolchain, template-drift, `disableAllHooks`, and
policy-activation sections check on Claude Code (`.claude/settings.json`, merge-autonomy
activation, the test-suite ratchet, scoped autonomy, governance paths) is skipped entirely on
Codex — none of those lines print. The doctor still writes only its two safe fixes (`chmod +x` on
harness scripts, seeding `.claude/LESSONS.md`); the Codex branch additionally creates and removes
a temp dir under `${TMPDIR:-/tmp}` and briefly starts the user's own `codex app-server`, which may
write Codex's own state under `CODEX_HOME` — the doctor sends it no write request.

## Lock owner on Codex

`bin/harness-lock.sh acquire` records an owner pid with precedence `--owner-pid <pid>` >
`TBF_OWNER_PID` > `${CLAUDE_PID:-$PPID}` (the original Claude Code rule, unchanged when neither
flag nor env var is given). Under `codex exec` or `codex --no-daemon`, the session's own native
`codex` process is every shell call's `$PPID` for the whole session (ADR 0002 P6), so a Codex
caller that can't rely on that fallback passes it explicitly — run `echo $PPID` as its own call,
then paste the printed digits literally into `--owner-pid <pid>` (never the inline
`--owner-pid "$PPID"` form: a variable folded into a gated command is exactly what "Running the
skills on Codex" below asks every Codex caller to avoid):

```
harness-lock.sh acquire --owner-pid <pid>
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
- **The hook canary relies on the subagent's own report.** "Running the skills on Codex" below
  opens every dispatch with a `gh --version` canary so the orchestrator can tell, per run, that
  the plugin's hooks are trusted and actually running before it trusts anything else that
  dispatch reports. The orchestrator only ever sees the subagent's final message (ADR 0002 P7) —
  a subagent that fabricated the canary's denial line, quoting the exact stem, would pass
  unnoticed. This is a per-run sanity check, not a proof.
- **The installed rules file is machine-specific.** Its `host_executable` paths embed this
  install's own absolute plugin path, which varies by machine and by plugin version. Keep
  `.codex/rules/trail-blazer-flow.rules` out of version control (for example, via
  `.git/info/exclude`) — `codex-setup.sh` never edits `.gitignore` itself. The generated agent
  TOMLs and `.codex/config.toml` carry no machine-specific paths and may be committed.

## Running the skills on Codex

This is the model-facing procedure `issue-cycle`, `issue-planner`, `issue-implementer`, and
`harness-setup` each point to for a Codex run. It changes HOW those skills run — script calls,
the lock, dispatch, and the shape of a git write — never WHAT they decide; every other rule in
each skill's own `SKILL.md` still applies. A composed run (`issue-cycle`) does the steps below
once, at its own step 0; `issue-planner` and `issue-implementer` skip their own copies exactly as
they already skip them under Claude Code.

### Plugin root and scripts

Codex shows each skill's file as `(file: r1/<skill>/SKILL.md)`, with an alias map entry for `r1`.
The plugin root is that alias value with the trailing `/skills` segment removed. Write every path
in full: `<plugin root>/bin/<script>.sh`, `<plugin root>/docs/reference/codex.md` — no `..`, no
`~`, no variable, no quotes, and never `bash <path>` (see "Script reach" above: a rule matches the
program name, and running a script through `bash` makes `bash` the program, not the script).
Report the resolved root once, in the run summary.

- **Gated** (run outside the sandbox only through the installed rules — see "Rules" above):
  `check-decision-record.sh`, `check-harness.sh`, `cleanup-after-merge.sh`,
  `find-implementation-work.sh`, `find-planning-work.sh`, `harness-lock.sh`, `harness-status.sh`,
  `harness-stop.sh`, `reconcile-ledger.sh`, `setup-labels.sh`.
- **Ungated** (run sandboxed): `harness-version.sh`, `governance-paths.sh`, and
  `codex-setup.sh`, whose write mode runs once from a normal terminal, never in-session, while its
  read-only `--check` runs in-session.

### Preamble (read-only, before step 0's lock)

Run, as its own call:
```
<plugin root>/bin/codex-setup.sh --check
```
Exit 0: continue. Any other exit: STOP before the lock, dispatching nothing. Quote every
`drift=`/`unsupported=` line verbatim, and give the remedy — the maintainer re-runs
`<plugin root>/bin/codex-setup.sh` from a normal terminal, completes its three `next:` lines
(see "Trust steps" above), and restarts the session with `codex --no-daemon`.

Then, as its own call:
```
echo $PPID
```
Copy the printed digits literally — they are this session's own pid, passed to the lock next.

### Lock

```
<plugin root>/bin/harness-lock.sh acquire --owner-pid <pid>
```
with `<pid>` the literal digits the preamble printed — never the inline `--owner-pid "$PPID"`
form (see "One simple command per call" below). Exit 0 and exit 3 are handled exactly as the
skill already handles them. Exit 2: abort the run before any mutating command and quote the
command's own stderr verbatim; when it names the Codex `app-server` daemon, tell the human to
restart with `codex --no-daemon` (see "Lock owner on Codex" above). Release the same
way, by absolute path: `<plugin root>/bin/harness-lock.sh release <run-id>`.

### One simple command per call

Every git write, `gh` call, and gated script is its own simple command: no pipe, `&&`/`;` chain,
redirection, heredoc, command substitution, or variable (see "Script reach" above). Read-only git
(`status`, `log`, `diff`, `rev-parse`, `merge-base`, `worktree list`) needs no rule and runs
exactly as the skill already writes it. Never run `bash <path>`, and never fold a variable or
`..` into a gated command. The Codex form of each composite the skills use elsewhere:

- **`git add -A && git commit -m "…"`** — two calls: `git add -A`, then `git commit -m "…"`.
- **The blocked path's `if git diff --cached --quiet; then … else … fi`** (issue-implementer step
  2f) — run `git diff --cached --quiet` alone; exit 0 means run
  `git commit --allow-empty -m "wip: blocked — <short reason> (#<n>)"` next; exit 1 means run
  `git commit -m "wip: blocked — <short reason> (#<n>)"` next.
- **Reset-fresh** (issue-implementer step 2b) — `git branch -D <branch>` has no allow rule; run
  `git checkout <default-branch>` then `git checkout -B <branch> <default-branch>` instead, the
  same end state.
- **`reconcile-ledger.sh`'s heredoc** — write the ledger as plain text to a file under `/tmp`
  (e.g. `/tmp/tbf-ledger-<run-id>.txt`) with a single redirect, never a multi-line heredoc; then
  run `<plugin root>/bin/reconcile-ledger.sh /tmp/tbf-ledger-<run-id>.txt` as its own call.
- **A `--body-file`** — write the body to its own file under `/tmp`, in its own call, before the
  `gh`/script call that reads it.
- **`gh … --jq … | tr -d '\r'` reads** — issue the `gh … --jq …` call alone, without the trailing
  pipe (the strip only guards a CRLF transport this path never carries).

Body and ledger files always land under `/tmp` (a writable root under the sandbox — see the ADR),
in a command of their own, before the command that reads them.

### Dispatch

Dispatch with `spawn_agent`, `agent_type` set to `planner`, `implementer`, or `verifier` and
`message` set to the prompt the skill specifies — prefixed with the canary block below — then
`wait_agent`. The subagent's final message is its entire report (ADR 0002 P7): there is no other
channel back. Every dispatch carries the canary block: the initial dispatch, every retry-ladder
attempt, every resume relaunch, every kickback, and every CI-fix re-dispatch.

### Canary

Prefix every Codex dispatch prompt with this block, verbatim:

> **Hook canary (Codex).** Before anything else, run exactly `gh --version`, alone, as your first
> action. If a hook blocked it, begin your final message with one line, `Canary: denied — `
> followed by the block message quoted verbatim, then continue with the rest of your task
> normally. Otherwise stop immediately: do nothing else at all, and your final message must be
> exactly `Canary: not denied — ` followed by the command's output.

On return, before anything else (including the LESSONS.md guard's own compare):

- **No final message at all** — the existing retry ladder; handle it as such.
- **A first line starting `Canary: denied — ` that quotes `trail-blazer-flow agent boundary:`**
  (implementer or verifier) **or `trail-blazer-flow planner guard:`** (planner) — strip that one
  line and continue normally; never carry it into a posted comment, an archive, or a PR body.
- **Anything else** — a **canary abort**:
  - Push nothing: whatever the agent did ran without its hooks. Run `git status --porcelain` and
    name every dirty path in the escalation.
  - Implementer or verifier stage (2c/2e): if the tree is dirty, `git add -A`; then
    `git commit --allow-empty -m "wip: blocked — hook canary failed (#<n>)"`; then
    `git checkout <default-branch>`. That commit is local and never pushed.
    - **Before the PR exists** (2c, and 2e's first verifier dispatch or a kickback): the branch
      holds only `wip:` commits, so the next run's step 2b sees `wip: blocked` as the newest and
      resets the branch fresh (codex.md's `git checkout -B` form), discarding the unguarded work
      instead of step 0's crash recovery resuming it — including that issue's implementation
      checkpoints; the next run re-implements.
    - **A CI-fix re-dispatch** (the branch already carries the pushed `feat:` commit and an open
      PR): also run `git checkout -B claude/<n>-<slug> origin/claude/<n>-<slug>` and then
      `git checkout <default-branch>`, re-pointing the local branch at its pushed head so the
      unguarded commit is unreachable and can never be pushed; the escalation says so.
  - Planner stage: no git.
  - Emit that stage's own status line yourself, `outcome=died` — the ledger stays complete; this
    is not the death/resume path.
  - Post a durable escalation — stage `2c`, `2e`, `plan-initial`, or `plan-revision`; reason
    `hook-canary-failed`; `comments=none` — quoting the canary line and naming the likely causes:
    the plugin's hooks are untrusted or not running (see "Trust steps" above); `jq` is missing
    (the hooks fail open); Codex did not send `agent_type`; or the installed agent TOMLs are stale
    (run `<plugin root>/bin/codex-setup.sh --check`).
  - Stop the run as a stop-switch stop does: dispatch nothing new, report the undispatched
    issues, and release the lock.

### Worktree mode

Never used on Codex: `git-c-guard`'s allow is ignored under Codex's own rules, and a worktree's
own gitdir is read-only in the sandbox (ADR 0002 P5) — stay sequential, always. At step 0's
stale-worktree sweep, skip `git worktree prune`/`remove` and every `git -C` sweep commit; run
only `git worktree list --porcelain`, report any surviving `<repo>-wt-<n>` worktree for the human
to clear, and skip any issue whose branch one holds.

### Merges and autonomy

The merge pass never runs on Codex, whatever `CLAUDE.md` delegates. When a "Merge autonomy
policy" section exists, say once, in "waits on the human": "merge pass not run: on Codex every
merge is the human's." List the PRs exactly as usual. `mode: autonomous` is read as **absent**:
no implied auto-approval or merge-autonomy section, no `--carry-over`, no serial train, and a
kickback budget of 2 (the skill's own default). A declared "Plan auto-approval policy" still
applies — every PR still waits for a human merge either way. `gh pr merge` is additionally
`forbidden` by the installed rules (see "Rules" above) — the mechanical backstop behind this.

### `harness-setup` on Codex

Matches the skill's own "0. Codex only" step:

1. The maintainer runs `<plugin root>/bin/codex-setup.sh` from the repo root, in a normal
   terminal — it cannot run in-session: the sandbox write-protects `.codex/`, and the script is
   deliberately ungated.
2. The maintainer follows its three `next:` lines: trust the project, trust the plugin's hooks,
   restart with `codex --no-daemon`.
3. Confirm with `<plugin root>/bin/codex-setup.sh --check`.
4. Dispatch one canary-only `planner` spawn, whose message is only the canary block above plus
   "then stop and report." Denied: continue. Anything else: STOP, naming the same likely causes
   the canary abort above names.
5. Run the doctor: `<plugin root>/bin/check-harness.sh --provider codex`.
6. Remind the maintainer to keep `.codex/rules/trail-blazer-flow.rules` out of version control
   (see "Honest limits" above).

### Attended only

Codex support is supervised only in 3.0.0: `codex exec` and `/loop`-style unattended scheduling
are not supported.
