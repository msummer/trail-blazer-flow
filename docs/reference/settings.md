# The per-repo settings file

> Part of the [reference documentation](README.md). A quoted section name such as "Safety model"
> or "The CLAUDE.md contract" refers to a heading in this reference set or in the top-level
> [README](../../README.md) — the [index](README.md#where-each-section-lives) says which file holds it.

Plugins cannot ship permission rules, so each target repo keeps a thin, checked-in
`.claude/settings.json` — start from `templates/repo-settings.json`. It pre-allows the harness
scripts (bare names — `bin/` is on the PATH), the `gh`/`git` commands the orchestrator runs,
Edit/Write, the build/test runners, and carries the deny-list (no merge, no force-push, no
`reset --hard`). The `gh pr merge` deny is the merge-autonomy off-switch: it ships on, and
lifting it is a human edit reserved for repos that define a CLAUDE.md merge autonomy policy.
`Bash(gh pr edit:*)` lets the orchestrator refresh a PR body it already opened — writing in filed
follow-up issue numbers, and replacing the verifier status line and mutation-probe line with a
fresh verdict's after a CI-fix round; `gh pr comment` is deliberately **not** granted — the
verifier's verdict is archived on the *issue* instead (`Bash(gh issue comment:*)`, already
granted), which is also where the merge pass reads it back with one `gh issue view` call.
`Bash(gh pr update-branch:*)` is used only by the serial merge train's update-branch fallback
(item 9) — it merges the default branch into a held PR's own branch, never `--rebase`, and never
touches the default branch itself. The same
file also carries the non-permission keys a clone needs to bootstrap
the plugin — `extraKnownMarketplaces` (auto-registering + auto-updating the marketplace) and
`enabledPlugins` — covered in the README's [Getting started](../../README.md#getting-started). Four grants exist solely for the
resilience mechanism (see "Resilience: checkpointing, retries, and the dispatch ledger"):
`Bash(sleep:*)` (the retry ladder's backoff waits), `Bash(date:*)` (duration reporting in the
summary table — advisory only, its absence just costs `duration: unknown`),
`Bash(git reset --soft:*)` and `Bash(git merge-base:*)` (collapsing a run's WIP checkpoints into
one clean commit before the PR — `git reset --soft` never touches the working tree, only where
HEAD points; see "Safety model"). Worktree-parallel mode's `git -C <worktree> <subcommand>`
commands (see the `issue-implementer` skill's `references/worktree-mode.md`) are approved by a
plugin-shipped `PreToolUse` hook instead of a permission grant — through v2.3.0 the template
shipped nine `Bash(git -C * <sub> *)` allow entries for this, but a `*` before the subcommand
also matches any option inserted at that position (`-c core.pager=…`, `--exec-path=…`) and
approves it without a prompt, which Claude Code 2.1.246 started warning about at startup, and no
rewrite of the rule closes the gap — there is no "exactly one token" rule syntax. `hooks/`
ships a guard script instead (see "Safety model" for its contract and the fail-safe design).
Separately, the seven bare `git` deny entries above each gained a
`git -C * …` mirror, so a worktree-mode command can't slip past a guard the bare form already
stops — see "Safety model" for why the mirror matters. Two of those seven bare denies
(`branch -D main` and `push origin main`) name the default branch literally, so they guard
nothing on a repo whose default branch isn't `main` (`master`, `trunk`, `develop`, ...);
`check-harness.sh` derives the guarded operations from the template itself, checks them against
this repo's actual default branch, and — when coverage is missing — names the exact bare and
`-C` deny entries to add. The template allows `pnpm`, `npm`,
`yarn`, and `pytest`; if your repo uses a
different toolchain, add it — the doctor warns when it detects a toolchain no settings file's
allow-list covers — e.g.:

```json
"Bash(make:*)", "Bash(cargo:*)", "Bash(go:*)", "Bash(just:*)"
```

That bare-name check is a regex match prefix-anchored at `^Bash(` against the allow-list entries
across all three settings files (the same three-file union named in "The CLAUDE.md contract" item
5 above) — a grant
in `.claude/settings.local.json` or your user-level settings file counts too, not just
`.claude/settings.json` — and doesn't cover a *path-qualified* verification interpreter (e.g.
`api/.venv/bin/python`, as worktree-parallel mode's per-checkout virtualenvs require) — those need
their own literal-path allow entry (`Bash(<repo>/api/.venv/bin/python:*)`) instead of, or in
addition to, the bare `Bash(python:*)` form. When CLAUDE.md's verification scope names such a
path, `check-harness.sh` looks for a matching literal-path grant across all three settings files
and WARNs with the exact entry to add if none exists — the shell resolves an absolute venv path
just fine, but Claude Code's permission match is a literal prefix test, so a bare-name grant can't
produce a false reassurance for a path-qualified interpreter it doesn't actually cover.

`check-harness.sh` reads these files exclusively with `jq`, matching literal entries in the
`permissions.allow`/`permissions.deny` arrays it parses out — never a raw-text search of a whole
file, which could be fooled by a rule merely mentioned in an unrelated string (a comment, an
`env` value) or by a deny-side entry that a whole-file search can't tell apart from an allow-side
one. Every check here — the harness-script sentinel, template drift, the stale-`-C`-allow WARN,
and default-branch guard coverage — stays scoped to `.claude/settings.json` by design: they judge
the shared, checked-in file, not effective permission. The exceptions need *effective* state
across all three files: the toolchain bare-name check above, the path-qualified interpreter
probe, the merge-autonomy verdict (see "The CLAUDE.md contract" item 5), the post-merge
allow-entry check, the `disableAllHooks` WARN, and (#311, only in "Autonomy mode" item 9's
autonomous mode) the informational `permissions.defaultMode` report, which reads a SANITISED
bare word from all three files, including the user-level one, and never prints an allow/deny
entry from any of them. `settings.local.json` is machine-local (may hold
secrets) — never commit it.
