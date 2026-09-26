# Safety model

> Part of the [reference documentation](README.md). A quoted section name such as "Safety model"
> or "The CLAUDE.md contract" refers to a heading in this reference set or in the top-level
> [README](../../README.md) — the [index](README.md#where-each-section-lives) says which file holds it.

The implementer subagent can edit files and run the build tool, but does **no** git or network —
the orchestrator does all git/GitHub. The **git/gh** half of that is mechanically enforced, not
just prompt convention (#235, review F3): a second plugin-shipped `PreToolUse` hook,
`hooks/agent-boundary.sh` (its full contract is further down in this section), denies any Bash
command whose command-position word resolves to `git`/`gh` for the implementer subagent. The
**network** half remains a prompt-level rule only — blocking it by command pattern is not
enforceable without also breaking dependency installs during verification, so #235 left it out of
scope. The verifier subagent writes nothing
durable: its mutation
probe edits an already-tracked file inside the tree under review, runs the tests, restores it
with `git restore <file>` (working tree only — never a commit, ref, or push), and re-checks
`git status --porcelain` against its pre-probe output before returning; if the repo doesn't grant
the restore, it skips the probe and says so. Guarantees: branch isolation (work never lands on the
default branch directly — mechanically enforced for any push refspec, not just the
pattern-matched deny entries below, by the third plugin-shipped `PreToolUse` hook,
`hooks/push-guard.sh` (#260, main session included, described further down in this section)), a
deny-list (no merge by default, no force-push, no `reset --hard`,
no `rm -rf`), independent re-verification + staged-file reconciliation before every commit, and
**human review of every PR before merge unless the repo has double-opted-in to merge autonomy**
(CLAUDE.md policy + lifted deny — see "The CLAUDE.md contract"). The deny-list is best-effort pattern matching; branch protection +
PR review are the real backstops, and — because two of the seven bare denies name the default
branch literally — `check-harness.sh` reports per-repo whether those two entries (and their `-C`
mirrors) actually cover this repo's default branch. The pre-merge guarantee is "nothing pushed, no PR exists" —
not "nothing committed": WIP checkpoint commits accumulate locally during a run (see
"Resilience"), but never leave the machine before the verifier passes. `git reset --soft`, added
for collapsing those checkpoints, only moves what a branch points at — it never touches the
working tree or deletes any file, so it carries none of the risk `reset --hard` does; the
`Bash(git reset --hard:*)` deny is unchanged and, like every deny, takes precedence over any
allow entry. Bash rules are prefix-matched, and a `git -C <path> …` command does **not** match a
bare-subcommand rule — allow or deny — so a `-C` command needs its own coverage on each side of
the permission model, and the two sides use different mechanisms. On the deny side, every bare
git deny — not only the ones worktree mode itself issues — gets a no-space trailing-wildcard `-C`
mirror, e.g. `Bash(git -C * push --force*)` and `Bash(git -C * clean*)` (see "The per-repo
settings file"): an unmirrored deny would be a real bypass (e.g. `git -C <worktree> push --force`
slipping past a guard that stops the bare form). On the allow side, a permission *rule* cannot do
this safely at all: the only syntax available is an exact match, a trailing `:*`, or a `*` that
matches any text including spaces, so `Bash(git -C * push *)` — the form the template shipped
through v2.3.0 — also approves `git -C <worktree> -c core.sshCommand=… push …` (the injected
option lands inside the first `*`), and there is no "exactly one token" rule syntax to close that
gap; Claude Code 2.1.246 added a startup warning naming exactly this shape. The plugin ships
`hooks/git-c-guard.sh` (a `PreToolUse` hook, registered in `hooks/hooks.json`) to do the job
instead: it sees the whole command string and can require exactly one `-C` token, one path token
matching the `<repo-dirname>-wt-<number>` worktree shape (the predicate's real reach is any path
whose final component is `<name>-wt-<digits>`, not only a sibling of the CURRENT session repo —
since #269 also reuses it, verbatim, to decide whether `hooks/push-guard.sh` resolves a push
segment's own `-C` target; see that hook's "Safety model" entry below), and then one of the ten covered
subcommands (`status`, `add`, `commit`, `push`, `restore`, `diff`, `rev-parse`, `merge-base`,
`reset --soft`, `log`), with nothing else in between — an injected `-c`/`--exec-path`, a second
`-C`, an unrecognized path or subcommand, a non-conforming composite part, or any command
substitution all get **no opinion** (empty stdout, exit 0), so the normal permission flow
applies. A handler `"if": "Bash(git -C *)"` gate on the hook's registration (Claude Code 2.1.85+)
restricts when the hook process is even spawned to Bash commands whose constituents — matched
after composite splitting and after any leading `VAR=value` assignment is stripped — match that
pattern; it can only *reduce* spawns, never widen approval, since the hook itself is the only
thing that ever emits `allow`; a command the filter doesn't match simply gets no hook opinion and
follows the normal permission flow, and per Claude Code's own docs the filter fails open (spawns
the hook anyway) on `$()`/backtick, `$VAR`, or an otherwise-unparseable command — which the guard
then rejects on its own terms, same as if `if` weren't there at all. Hook decisions
never override a deny: Claude Code evaluates deny and ask rules regardless of what a `PreToolUse`
hook returns, so the `-C` deny mirrors above keep winning over the hook's allow, and the guard
itself never emits anything but `allow` or nothing — never `deny`/`ask` — so a bug in it degrades
to a prompt, not a bypass. It also never invokes `git` (or anything else) against the untrusted
`-C` path it is validating, which matters because — per the same docs — a plain `cd` into a
different directory prompts before the `git` command that follows it, since running `git` in a
new directory can execute that directory's hooks; `cd`-with-`git` is therefore not a simpler
escape hatch for either the template or the guard. Hooks shipped by a plugin fire inside
subagents too (carrying `agent_id`/`agent_type` alongside the usual fields), which matters here
because the implementer and verifier subagents issue most of the `-C` commands, not just the
orchestrator — and it is also the mechanism `hooks/agent-boundary.sh` (#235, below) reads to
resolve which role, if any, issued a given Bash call. The guard fails open in every direction: no `jq` on `PATH`, the plugin disabled or
not yet updated, `disableAllHooks: true` in any of the three settings files, or a headless
`--bare` run all leave a `-C` call unapproved by the hook — a prompt in default mode (or a
recorded denial headless), never a silent bypass. Below the `if` gate's 2.1.85 floor (see
"Prerequisites"), Claude Code predates support for the handler's `if` field, and its handling
there is unverified: either it runs the hook on every Bash call as before — prior behaviour,
with `-C` calls still approved by the guard — or it rejects the handler and the guard never
fires, degrading to the same prompt (or recorded denial headless) as above; either way, never a
silent bypass. `check-harness.sh` WARNs when it finds
`disableAllHooks: true`, and separately when `.claude/settings.json` still carries a legacy
`Bash(git -C * …)` allow entry the hook now supersedes. A heredoc body
(e.g. `reconcile-ledger.sh - <<'LEDGER'`, used by `issue-cycle`) is not split into
separately-matched subcommands, so it stays covered by its single prefix grant. A third fact from
the same probe series: no allow rule can approve a Bash command containing command substitution
— `$(...)` or backticks, which behave identically — even when every constituent command is
individually granted; such a command instead falls through to the session's permission mode
(prompt on manual/default, a recorded denial headless, silent auto-approval under `auto`), while
a deny rule *does* match inside a substitution body and blocks the whole composite. That's why
the WIP-collapse step ("Resilience") runs as two plain `git` calls — a `merge-base` lookup
followed by `reset --soft` on its literal SHA — rather than one command with the SHA substituted
in, and it is also why the guard hook rejects any `$(...)`/backtick span outright rather than
trying to reason about what it might expand to. Composites joined by `&&` or `|` behave the
opposite way to substitution, and identically to each other: they **are** statically split, and
each constituent is matched on its own, so such a command is approved exactly when every
constituent that requires approval has its own matching allow entry. One part's grant does not
cover the whole (`Bash(git add:*)` alone does not approve `git add -A && git commit …`, and the
reverse fails too), and a single rule written across the operator — `Bash(git add -A && git
commit:*)` — matches nothing at all. Not every constituent needs an entry: some commands are
approved without one (`cd`, `tr` and `head` were each confirmed), which is why the three
`… | tr -d '\r'` pipelines the harness issues need no `tr` grant; the bare-form WIP checkpoint
(`git add -A && git commit …`) is covered because both of its constituents are already granted, while its
`-C` counterpart is covered by the guard hook validating `git -C <worktree> add -A` and `git -C
<worktree> commit …` as two conforming segments of the same `&&`-joined command (the
`checkpoint-composite` case in `dev/hook-tests.sh` pins this, including the double-quoted `#`,
`(`, `)`, and `:` a WIP commit message carries). A path-qualified invocation matches no bare-name
rule — allow or deny — so such a command needs its own grant on the literal path prefix (this is
why a worktree's venv-interpreter verification command needs a dedicated entry; see the
issue-implementer skill's worktree-parallel reference). Every command the harness issues across
either operator is therefore approved — by the template's allow rules for the bare-form and
path-qualified-grant cases, and by the guard hook for the worktree `-C` forms — exactly as the
plugin and template ship. As with substitution, a deny matching any one constituent blocks the
entire composite.

All of the bare-form facts above (prefix matching, the substitution gap, and the `&&`/`|`
composite split) were verified by live probe against Claude Code 2.1.220 (#41, #39, #55, #79,
#80) and are unaffected by the `-C` guard hook. The hook's own allow/no-opinion boundary — the
ten `-C` forms, the injected-option and malformed-input rejections, the composite checkpoint, and
the never-execute-`git` guarantee — is pinned by fixture in `dev/hook-tests.sh`, and was also
confirmed live against Claude Code **2.1.246** on macOS (2026-08-26): a throwaway consumer repo
with a real sibling worktree, the template's `permissions` block copied verbatim (49 allows, the
seven `-C` deny mirrors, no `-C` allows), run both headless (`-p`, model-driven) and through a
real interactive session. Two controls proved the method: with the template's permissions alone
and no plugin loaded, the same `git -C <worktree> status --porcelain` command is **denied**, so
every "ran" below is attributable to the hook, not the permissions block alone; and the startup
wildcard warning is independently observable by this method — a single `Bash(git -C * status *)`
allow prints exactly one such warning line on a fresh start in an already-trusted workspace
(never in `-p` mode, and never on the run where the trust dialog is first accepted).

| row | tested against | command / observation | expected | observed |
|---|---|---|---|---|
| (a) / (a-rel) | the hook as shipped before this issue | `git -C <worktree> status --porcelain` (absolute and relative-sibling forms) | runs, no prompt | **ran**, `?? probe-anchor.txt`, no denial |
| (b) | as shipped | `git -C <worktree> -c core.pager=cat status` | prompts | **"This command requires approval"** |
| (c) | as shipped | `git -C <worktree> push --force` | blocked by the deny mirror | **"Permission to use Bash with command … has been denied."** — deny-rule wording, distinct from (b)'s prompt wording: the deny mirror wins over the hook's allow |
| (d) | as shipped | `git -C <worktree> add -A && git -C <worktree> commit -m "wip: checkpoint verifier (#12)"` | runs, no prompt | **ran**, one commit; both `&&` constituents validated as conforming segments |
| (g-pre) | as shipped (no `log`) | `git -C <worktree> log main..HEAD --format=%s` | the #154 gap | **"This command requires approval"** — gap confirmed live |
| (g) | this issue's state (`log` added) | same `log` command | runs | **ran** |
| (a-if) / (d-if) | this issue's state (`if` gate added) | rows (a) and (d) again | run, no prompt | **ran** — the `if` gate matched each constituent of the (d) composite too |
| (b-if) | this issue's state | row (b) again | prompts | **"This command requires approval"** — the `if` gate loosens nothing |
| spawn trace | no `if` | `echo hi` | hook spawns | **1 spawn** |
| spawn trace | with `if` | `echo hi` | no spawn | **0 spawns** |
| spawn trace | with `if` | `git -C <worktree> status --porcelain` | spawns and runs | **1 spawn**, ran |
| (e) | as shipped | interactive session start, template block only | zero wildcard warnings | **0** (a positive control on the same path printed 1) |
| (f) | this issue's state | interactive session start with the `if` gate on the handler | zero wildcard warnings; hook still fires | **0** warnings; firing shown by (a-if)/(d-if)/the spawn trace |

The seven `Bash(git -C * …)` deny mirrors were present throughout and produced no warning in any
row above — Claude Code 2.1.246's startup scan is allow-only. The one item this probe left
unconfirmed is the Windows/Git-Bash spot-check of row (a) — see the README's
["Windows"](../../README.md#windows) section.

**Five PreToolUse hooks.** `hooks/git-c-guard.sh` above is one of five plugin-shipped
`PreToolUse` hooks registered in `hooks/hooks.json` — three matching `Bash`, and two matching
`Bash|Edit|Write|apply_patch`: the fourth, `hooks/claude-dir-guard.sh` (#327, widened to that
matcher by #407; described in its own paragraph after the third hook below), and the fifth,
`hooks/planner-guard.sh` (#407, its own paragraph further below); the second `Bash`-matching hook, `hooks/agent-boundary.sh`
(#235, review F3), is what the "no git, no gh" caveat earlier in this section now names. It reads each Bash
call's `agent_type` from the hook's own stdin JSON — the field a `PreToolUse` handler's `if` gate
cannot see, which is why this handler carries no `if` at all, unlike the guard hook's — and
resolves it against a role (both the bare `implementer`/`verifier` and the namespaced
`trail-blazer-flow:implementer`/`trail-blazer-flow:verifier` spellings are matched — the
namespaced form is the live spelling, confirmed by the live-probe record below; the bare form is
retained as insurance against a future de-namespacing). For the implementer role it denies
(exit 2, one stderr line, empty stdout) any Bash command whose parsed command-position word
resolves, case-insensitively and after skipping a leading shell reserved word (`if`/`then`/`elif`/
`else`/`do`/`while`/`until`/`!`/`coproc`, since #398 — see "Known evasions" below for the
remaining residuals), to `git` or `gh`, regardless of `git`
subcommand — the implementer needs neither. For the verifier role it denies `gh` outright and
denies `git` unless the resolved subcommand is one of `status diff log show rev-parse ls-files
merge-base blame grep restore`; an unlisted subcommand, a global option before the subcommand, and
a bare `git` all deny too — fail-closed, not an enumerated allow-list of "safe" subcommands. Only
the command word and the shell-keyword skip are case-folded (since #398) — the resolved `git`
subcommand itself stays an exact match, so a case-variant subcommand such as `git STATUS` also
denies (fail closed), never widening the verifier's read-only allowance. Since
#340, both roles ALSO deny a Bash command that puts a `.claude`-segment path in a write position —
a `>`-family redirect target, an argument to `tee`/`cp`/`mv`/`cd`/`pushd`, or an in-place `sed`'s
argument — closing most of the Bash-issued write route into `.claude/` (see `hooks/claude-dir-guard.sh`'s
own paragraph below for the Edit/Write-issued route that hook already closed). Since #387, both
roles ALSO deny a Bash command whose command word is an interpreter or one-step writer (`python`,
`perl`, `dd`, `install`, and the rest of `CLAUDE_CMDLINE_WRITE_COMMANDS`) when that same command
text names a `.claude` segment anywhere — closing the interpreter/one-step-writer gap #340 left
open, at the cost of denying a vocabulary command sharing a call with a `.claude` *read* too (see
the over-blocking list below). Every other case —
the main session (no `agent_type`), the planner or another agent, `permission_mode: "plan"`,
malformed stdin, another tool, or `tool_input.command` absent — is "no opinion" (exit 0, empty
stdout, empty stderr), the same convention `git-c-guard.sh` uses; a blocked call's stderr names the
role and the command it blocked, since a subagent can't answer a permission prompt the way an
interactive session could. Pinned by fixture cases in `dev/hook-tests.sh`, including the same
never-executes-anything guarantee (a booby-trapped `git`/`gh`/`rm` on `PATH` proves nothing runs)
and the same fail-open properties as the guard hook: the plugin disabled, `disableAllHooks: true`,
no `jq` on `PATH`, an unresolved `${CLAUDE_PLUGIN_ROOT}` on Windows, or a Claude Code that omits
`agent_type` all leave this hook silent — but unlike the guard hook (whose non-firing degrades to
an ordinary permission prompt), this hook's non-firing removes a control with **no** visible sign,
since nothing else in the permission model was narrowing the implementer/verifier's `git`/`gh`
surface to begin with. The scan is deliberately quote-blind (it strips quote characters rather than
tracking quote state, the same trade-off `git-c-guard.sh` makes in the opposite direction) and
processes `tool_input.command` one line at a time, so several over-blocking classes are expected
and documented in the script's own header: a literal `git`/`gh` word starting a quoted span right
after a separator (e.g. `echo "a; git push"`) denies; **any line of a multi-line Bash command that
begins with `git`/`gh`** is a command-position token after its own newline break and denies,
including a heredoc line that merely *writes* a fixture file containing the text `git push`; since
#398, that same per-line rule also denies any line whose first word is a shell keyword followed by
`git`/`gh` (e.g. a heredoc writing a shell script with `  then git push`) or whose first word
case-folds to `git`/`gh`/a vocabulary member (a heredoc prose line starting `Git …`/`Then gh …`,
or `echo "a; Git push"`), a case-variant vocabulary command sharing a call with `.claude` (`CP`,
`Tee`, `Python3`), and a genuinely distinct program named `GIT`/`GH`/etc. on a case-sensitive
filesystem — the remedy is the same Write/Edit-tools remedy already given above; and,
since #340, a `.claude`-segment write class covering quoted prose (`echo "tip: >> .claude/x"`), a
heredoc body line, a `sed -i` whose script text itself spells a `.claude` segment, a copy or move
*out of* `.claude`, a `cd` into any `.claude` directory, an input redirect from `.claude` into
one of those commands (`tee /tmp/x < .claude/x`), and any `~/.claude/...` write; and, since #387,
a `CLAUDE_CMDLINE_WRITE_COMMANDS` command word sharing a call with any `.claude` mention anywhere
(every line, heredoc bodies included) — even a pure read (`python3 -c "json.load(open('.claude/x'))"`,
`awk 'NR<5' .claude/x`), an unrelated vocabulary command sharing the call
(`cat .claude/x && python3 -m pytest`), or a checkout/worktree path carrying a `.claude` segment —
the remedy for a file-content case is to write through the Write/Edit tools rather than a Bash
heredoc, and for the #387 read-adjacent case, the Read/Grep tools or a separate Bash call. Known
evasions, documented rather than hidden: `$(which git) push` (the literal `git` token is never in
command position), `sudo -u foo git push` (the argument to `-u` becomes the resolved command word
instead of `git`), interpreter indirection outside the recognised prefix words (`env`, `command`,
`builtin`, `exec`, `sudo`, `nohup`, `time`, `nice`, `stdbuf`, `xargs`, `bash`, `sh`, `zsh`, `ksh`,
`dash`, and, since #398, the shell reserved words `if`, `then`, `elif`, `else`, `do`, `while`,
`until`, `!`, `coproc`); a `!` glued directly to the following word (`!git push` — not a reserved
word in that glued form, so a non-interactive shell treats it as a command literally named `!git`,
which does not exist); zsh's precommand modifiers `noglob`/`nocorrect`/`repeat N`; and the `eval`
builtin (`eval git push`) — all three residuals are out of scope for #398 and documented rather
than closed; and, for the `.claude`-write class specifically, a writer outside
`CLAUDE_CMDLINE_WRITE_COMMANDS` (`sort -o`, `split`, `unzip -d`, `scp`, `cpio`, `vim -es`, `sed`'s
`w` command), a launcher that becomes the resolved command word instead of a vocabulary member
(`uv run python`, `npx`, `poetry run`, `sudo -u x python3`), a script file whose own CONTENTS name
the path rather than the command line itself (`python3 /tmp/w.py`), or a variable-built, glob, or
quote/backslash-split target — this is a
tripwire against an off-script subagent, the same framing this document already uses for the
body-hash grant pattern, not a sandbox against a determined adversary.

**The third hook, `hooks/push-guard.sh` (#260), governs every session — main session included,**
unlike `hooks/agent-boundary.sh` above, which only governs the implementer/verifier subagents.
It closes the gap the settings template's own default-branch deny entries leave open: those two
entries (`Bash(git push origin main:*)` and its `-C` mirror) are prefix-matched, so a refspec
spelling such as `git push origin HEAD:main`, `git push origin +HEAD:refs/heads/main`, a remote
other than `origin`, or `git push origin :main` slips past them. This hook instead parses the
`git push` refspec itself: it denies (exit 2, one stderr line naming the blocked destination,
empty stdout) any push whose resolved DESTINATION — after stripping a leading `+`, taking
everything after a refspec's first `:`, and substituting `HEAD`/`@` with the current branch — is
the repo's default branch, or unconditionally denies `--all`/`--mirror` (both push every local
branch, including the default one). The default branch is resolved by reading (never executing)
the current repo's `refs/remotes/origin/HEAD` symref, located by walking up from the PreToolUse
hook's own `cwd` field (a documented stdin field; this hook falls back to `$PWD` when `cwd` is
absent) through at most 64 parent directories, following a worktree pointer file
(`gitdir: <path>`) when `.git` is a file rather than a directory — the same shape
`hooks/git-c-guard.sh`'s worktree-parallel forms use. An unconditional fallback deny set,
`main`/`master`, is always in force in addition to whatever default branch actually resolves, so
the hook still denies a plain `git push origin main` even with no `cwd` or an unreadable `.git`.
Since #269, a push segment's own `git -C <path>` value is ALSO resolved, but only when it satisfies
the same `PATH_ERE` predicate `hooks/git-c-guard.sh` already enforces for its own worktree-parallel
allow forms (a byte-identical declaration in both hooks, mechanically pinned by the gate): the
current branch and any REPO-LOCAL `.git/config` route for that segment then come solely from the
RESOLVED checkout (since #290, the GLOBAL config candidates below are read identically for every
checkout resolved, so a resolved segment still sees the same global routes the session would),
while the default-branch deny member becomes the union of the fallback, the session's own
default, and the resolved checkout's own default — never a pure replacement, so a target lacking its
own `refs/remotes/origin/HEAD` cannot silently lose the guard. A `-C` value that does not match the
predicate (including a plain `git -C ../other-checkout push` with no `-wt-<n>` suffix), the attached
`-C<path>` form, two or more `-C` tokens, `--git-dir=<path>`/`--work-tree`, or a predicate-matching
directory holding no `.git` of its own (this resolution never walks upward the way git itself would
from a real `-C`) all stay judged only against the session — see the hook's own header for the full,
measured evasion/over-blocking inventory. It enforces only the
"deny the default branch" half of this issue's Decision, not an allow-list of
`claude/<n>-<slug>` destinations — that would also deny a `release/vX.Y.Z` branch, an annotated
tag push, or any ordinary `git push origin feature/x` a human runs in any plugin-enabled session,
for no matching safety gain. Since #268, a push carrying no explicit refspec (a bare `git push` or
`git push <remote>`) also consults the same common dir's `config` file — text-parsed, never
executed as `git config` — for `remote.<name>.push` and `push.default`/`branch.<n>.merge`: a
repo's own `remote.origin.push = HEAD:main` or `push.default = upstream` with the current
branch's upstream on the default branch now denies where this hook was previously silent, closing
the gap #260's own settings-template entries and this hook's earlier refspec parser both left
open. This closed only the repo-local half of that class — a GLOBAL or system git config setting
either key was, at the time, filed as a follow-up. **Closed in v2.7.3 by #290**: the same two keys
are now also read from `$GIT_CONFIG_GLOBAL`, `$XDG_CONFIG_HOME/git/config` (or its
`$HOME/.config/git/config` default), and `$HOME/.gitconfig`, unioned with the repo-local routes
above — `$GIT_CONFIG_GLOBAL` is itself unioned with (not a replacement for) the other two global
paths, and a repo-local AND a global `push.default` value are both evaluated unconditionally, each
a deliberate, documented over-block (real git reads only one file for `$GIT_CONFIG_GLOBAL` and
gives a single scalar precedence to `push.default`). A SYSTEM git config (`/etc/gitconfig`) and
`include`/`includeIf` directives inside any of the four files this hook now reads remain unread,
each filed as its own follow-up (see the hook's own header for the full, measured inventory). The
union is deliberately
over-broad rather than modelling git's own remote-selection precedence: a bare push checks EVERY
configured remote's push
route (not only the one git would actually pick) union the `push.default` route, and
`push.default = matching` or a wildcard (`*`) configured destination both deny unconditionally,
the same reasoning as `--all`/`--mirror` — three of the four new documented over-blocking classes
named in the hook's own header (the fourth, an unquoted `#`/`;` truncating a configured
destination mid-value, is described there instead). A segment carrying an explicit refspec
(including the harness's own `git push
-u origin "claude/<n>-<slug>"`) never consults config at all. Pinned by fixture in
`dev/hook-tests.sh`, including the same never-executes-anything guarantee and a
byte-identical-file-listing fixture proving this hook only reads the filesystem, never writes to
it — extended to the config-read route specifically. Composition with the deny-outranks-allow mechanism
`hooks/agent-boundary.sh`'s live-probe record establishes below was **not** separately
re-measured for this third hook — it uses the identical mechanism, but only two hooks were ever
replayed together live.

**The fourth hook, `hooks/claude-dir-guard.sh` (#327; apply_patch, `.codex`, and a Bash
apply_patch-shim route added #407), denies an implementer or verifier subagent's `Edit`, `Write`,
`apply_patch`, or apply_patch-shaped `Bash` call whose target path carries a `.claude` or `.codex`
path segment.** It closes #323's LESSONS.md dispatch guard's own documented blind spot: that guard
is orchestrator prose that detects a subagent's `.claude/LESSONS.md` change only after the
dispatch returns, and has no baseline at all to compare against while the file exists untracked.
This hook instead denies the `Edit`/`Write`/`apply_patch` itself, mechanically, before it can land
— tracked or not. It was measured live matching `Edit|Write` exactly (below); #407 widened its
matcher to `Bash|Edit|Write|apply_patch` for two reasons: Codex's own `apply_patch` tool call
carries no `file_path` at all (ADR 0002 amendment, P4), and Codex separately puts an
`apply_patch`/`applypatch` shim on the shell PATH, so a shell-issued `apply_patch <<'EOF' … EOF`
heredoc can reach this hook as an ordinary `Bash` call instead — an S0 spike (ADR 0002 "Amendment
2026-09-26 (2)", #412, Q7) captured exactly that shape writing `.claude/settings.local.json` inside
the Codex sandbox. It reuses `hooks/agent-boundary.sh`'s identical `agent_type` role vocabulary
(both spellings, per role) — a role the `if` field cannot see, so this handler also carries no
`if` key, for a widened reason since #407: the `if` field also cannot parse `apply_patch`'s own
patch-header grammar or distinguish a Bash command's own command word from an argument. Its
classifier is a pure string decision with **no filesystem access at all**, strictly less than
`hooks/push-guard.sh` above (the apply_patch and Bash-shim routes read the stdin JSON's own `cwd`
field to resolve a relative header path, but never open, stat, or list anything): it denies (exit
2, one stderr line naming the role, the tool, and the blocked path, empty stdout) when a target
path carries any path segment equal to `.claude` or `.codex` case-insensitively — nested, a
relative path's own first segment, or the path's final segment, and whether spelled with a forward
slash, a Windows drive-letter prefix, or a backslash (normalised to a forward slash first) — and
denies, fail-closed, when the path cannot be classified as absolute (`/…` or `[A-Za-z]:/…`) and
free of a `..` segment, or when an apply_patch (or apply_patch-shaped Bash) command cannot be
parsed at all (an absent command, an unrecognised `*** ` marker, an empty header path, or zero
headers found); a case that matches more than one class resolves to the most specific message. For
a plain Bash call, whenever `apply_patch`/`applypatch` (bare, or a path-qualified spelling such as
`./apply_patch`, matched by basename) resolves as the command word of any `;`/`&`/`|`/`(`/`)`/`{`/
`}`/backtick-delimited segment — skipping a leading redirect's own target/source and a bare-digits
file-descriptor token immediately before one (a `>>`/`<>` run counts as one redirect, and an fd
duplication such as `>&2` or `2>&1` keeps its `&`), so a LEADING redirect cannot hide the command word
either (`< x.patch apply_patch`, `2>/dev/null apply_patch < x`) — a belt-and-braces check runs
FIRST and UNCONDITIONALLY, before any structured parse: if the raw command text mentions
`.claude`/`.codex` anywhere at all (case-insensitive), it denies immediately, regardless of
whether the text also happens to contain a genuine `*** Begin Patch` line elsewhere (this is what
defeats a decoy built to slip a `.claude` mention past the structured parse — an ANSI-C-quoted
(`$'…'`) line whose own `\n`s are literal backslash-n bytes rather than real line breaks, or a
Unicode-whitespace-hidden header sitting next to a genuinely benign one). Only when that check
finds no `.claude`/`.codex` mention does the command fall through to: a genuine, exactly-matched,
fully-trimmed `*** Begin Patch` line (which triggers the same structured parse as the apply_patch
tool route), or — command word present but no such line — a fail-closed "no inline patch text"
deny (the hook cannot verify what it writes when the patch itself is invisible, e.g. `apply_patch
< x.patch`). The command-word walk is quote-blind and backslash-blind, the same tripwire-not-
sandbox trade-off every scan in this directory makes: a backslash-quoted spelling, a quoted or
variable-built name, a PREFIX_WORDS option that itself takes a separate argument
(`nice -n 5 apply_patch`), `eval`, a quoted `bash -c "apply_patch < x.patch"`, or an unrecognised
launcher can all still evade both checks — while the SAME quote-blindness can also over-block: a
commit message or `echo` that merely mentions `apply_patch`/`applypatch` between a matching pair
of BACKTICKS, or right after a `;`, `(`, `|` or `&` (all segment-break characters of this walk)
denies too, even inside an enclosing pair of ordinary quotes — `git commit -m "See
\`apply_patch\` docs"` or `git commit -m "fix; apply_patch now works"` denies on Claude Code as
readily as on Codex. A quoted mention that follows ordinary words (`git commit -m "the
apply_patch shim"`) gets no opinion. `apply_patch`/`applypatch` appearing only as an ordinary argument
(`rg apply_patch hooks/`) still gets no opinion. Every other case — the main session (no `agent_type`), another
agent, `permission_mode: "plan"`, a tool other than `Edit`/`Write`/`apply_patch`/`Bash`, malformed
stdin, an absent or empty `file_path`/command, an ordinary Bash call that neither carries an inline
patch nor invokes the shim as its command word, or an ordinary absolute path outside any
`.claude`/`.codex` segment — is "no opinion" (exit 0, empty stdout, empty stderr), including two
release-blocker controls: the orchestrator's own main-session `.claude/LESSONS.md` append still
works, and so does the verifier's own transient mutation-probe `Edit` of a tracked source file.
Pinned by fixture cases in `dev/hook-tests.sh` (prefixes `cdg-`, `cdg-patch-`, `cdg-codexseg-`, and
`cdg-bash-`): the same booby-trapped-`PATH` idiom (widened here to
`git`/`gh`/`rm`/`dirname`/`tr`/`awk`/`grep`/`sed`, since this hook uses none of them) proves it
executes none of them, and a byte-identical fixture-tree listing proves the `Edit`/`Write` route
writes nothing to the filesystem — this hook also never *reads* the filesystem at all, true by
construction (it opens no path), not something either fixture demonstrates — backed by a
mutation-proof table (the `Edit`/`Write` route) and a registry of `dev/mutants/hook-tests.json`
records re-run by `dev/mutant-driver.sh` (the apply_patch, `.codex`, and Bash-shim routes). A
future Claude Code or Codex that ever sends a relative `file_path`/header path with no `cwd` to
resolve against would deny every implementer/verifier call on that route, with the unclassifiable
message's own distinct wording naming the path so the cause is visible in the first blocked call —
mass-deny risk, disclosed rather than hidden. The same fail-open properties as its siblings apply
here too: the plugin disabled, `disableAllHooks: true`, no `jq` on `PATH`, an unresolved
`${CLAUDE_PLUGIN_ROOT}`, or a Claude Code/Codex that stops sending `agent_type` all leave this hook
silent, with no prompt and no visible sign — `templates/repo-settings.json` declares no
`Edit(`/`Write(` entry at all, so this hook is the only mechanical control on this surface. A live
probe run 2026-09-17 against Claude Code **2.1.274** (macOS, a temporary logging `PreToolUse` hook
matching `Edit|Write`) measured the matcher this hook was registered with AT THE TIME (`Edit|Write`,
exactly — since widened by #407) and a verifier subagent's `Edit` payload, not just an
implementer's: it carried `agent_type: "trail-blazer-flow:verifier"` (the same namespaced spelling
`hooks/agent-boundary.sh` already measures for `Bash`), so this hook's verifier-role coverage is
measured, not inferred, on `Edit` — the verifier role has no `Write` tool (`agents/verifier.md`),
so there is no verifier `Write` payload to measure — the same way `hooks/agent-boundary.sh`'s own
record already measures verifier coverage on `Bash`. The apply_patch and Bash-shim routes are NOT
separately live-probe-measured against Codex; see "On Codex" below for what #407 relied on
instead.

**The fifth hook, `hooks/planner-guard.sh` (#407), enforces the planner subagent's read-only
boundary — the whole point of P2 of the ADR 0002 amendment, which found that Codex's own
`sandbox_mode = "read-only"` does not hold: the model can still invoke `apply_patch` regardless of
what the sandbox mode claims, and P3 found that a Codex plugin's hook rules apply to every agent
regardless of its own declared tool grant, so an off-script planner is not stopped by tool
configuration alone.** Unlike every sibling hook above, this one is an ALLOWLIST, not a denylist:
an unclassifiable shell command denies (fails closed), never passes silently. It denies (exit 2,
one stderr line, empty stdout) `Edit`/`Write`/`apply_patch` outright for a recognised planner
`agent_type` (both spellings), and denies a `Bash` call unless every `;`/`|`/`||`/`&&`-separated
segment's command word is an exact member of `PLANNER_READONLY_COMMANDS` (`cat head tail ls pwd wc
grep rg nl sed git echo printf true diff cmp stat basename dirname jq cut tr`), with extra shape
constraints for three of them: `git`'s own subcommand must be one of `status diff log show
rev-parse ls-files merge-base blame` (deliberately excluding `restore`, which writes the working
tree, and `grep`: real git accepts abbreviated long options and bundled short options, so `git
grep` could be steered into `-O`/`--open-files-in-pager`, an arbitrary-pager-program option, in a
shape a per-token check cannot reliably catch — the planner already has the `rg`/`grep` TOOLS for
searching), with no later token starting `--output` or equal to `--ext-diff`; `rg` may carry no
`--pre*`/`--hostname-bin*` argument (the latter also runs an arbitrary program, to resolve a
hyperlink's hostname); and `sed` is accepted only as the exact shape `sed -n '<N|$>[,<N|$>]p'
[files]` — an in-place flag, a `w` command, or any other `-`-leading argument after the range all
deny. The lexer is a copy of `hooks/git-c-guard.sh`'s own awk
state machine, with `;`/a single `|`/`||`/`&&` turned into segment breaks instead of outright
rejections (this hook validates each segment on its own), and a narrower reject set (`$` backtick
`\` `<` `>` `(` `)` `{` `}` `!` — a lone `&` still rejects, which also covers `|&`) — but UNLIKE
`git-c-guard.sh`, a lexer rejection here means DENY, fail-closed, never "no opinion": this hook's
whole purpose is a read-only guarantee, not a convenience shortcut. There is deliberately **no**
`permission_mode: "plan"` skip, unlike every sibling hook — `permission_mode` cannot be relied on
under Codex (P1), and a read-only role loses nothing from a denial during a genuine plan-mode
turn. An absent or empty `tool_input.command` also denies fail-closed here, unlike every sibling
hook's "no opinion": there is nothing to classify as read-only, so there is nothing to allow. Every
other case — the main session (no `agent_type`), any other agent, a tool outside `Edit`/`Write`/
`apply_patch`/`Bash`, or malformed stdin — is "no opinion". On Claude Code, this hook is a
documented no-op today: `agents/planner.md`'s own `tools:` line lists only `Read, Grep, Glob`, so
the planner is never given a tool this hook's matcher covers at all; it exists for Codex, where
tool configuration alone does not stop an off-script call (P2/P3 above). Never executes anything
other than `jq` and `awk` (the lexer) — pinned by a never-executes fixture trapping
`git`/`gh`/`rm`/`touch` specifically (not the wider `awk`/`grep`/`sed`/`tr`/`dirname` set the
`Edit`/`Write`/`apply_patch`-only hooks trap, since this hook's own lexer legitimately uses `awk`).
Documented over-blocking, since this is an allowlist with no carve-outs: `2>/dev/null` and every
other unquoted `$VAR`/redirect/substitution denies; a heredoc or any other multi-line command
denies outright; and a genuinely read-only command excluded from the allowlist (`find`, `sort`,
`uniq`, `awk`, `less`, `xargs`, `cd` — each excluded because it can write, run another command, or
leave the checkout) denies too. An allowlisted `git diff`/`show`/`log` can still run a textconv or
external-diff driver the repo's OWN git config declares (`--ext-diff` itself is denied, but a
driver configured via `diff.<driver>.command` and invoked through a `diff=<driver>` gitattribute is
not distinguishable from an ordinary `git diff` by this lexer); the same repo config can also
declare `core.fsmonitor = <script>`, an external filesystem-monitor hook that `status`/`diff`
(among others) invoke on every run, regardless of any command-line option — documented residuals,
not code changes.

**Hook canary (#407).** `gh --version` is denied for the implementer, verifier, and planner roles
(through `hooks/agent-boundary.sh` and `hooks/planner-guard.sh` respectively), and gets no opinion
in the main session, across every hook that could plausibly see it. It is harmless if it ever runs
(it only prints a version string), so denying it costs nothing; a denial for one of these roles is
a live signal that the hooks are loaded, trusted by the host (Claude Code or Codex), and actually
firing for that session — the opposite of every fail-open class this document catalogues, which
degrade silently. It is documented here and pinned only by `dev/hook-tests.sh` fixtures (prefix
`canary-`), with no separate mechanical declaration tying this specific command to the skill text
that might one day use it as a pre-dispatch self-test (see #409, out of scope for #407).

**On Codex (ADR 0002 amendment).** `hooks/git-c-guard.sh`'s `if` gate is dropped entirely under
Codex, leaving that hook inert there — worktree-parallel mode is off on Codex regardless.
`hooks/agent-boundary.sh` and `hooks/push-guard.sh` work as written: neither relies on an `if` gate,
and both read only the same documented stdin fields a Codex payload also carries. Codex's
`apply_patch` tool call (and the shell-issued heredoc/shim form it can also take) is covered by
`hooks/claude-dir-guard.sh`'s own routes above; for the planner role specifically, it is ALSO
covered by `hooks/planner-guard.sh`'s own denial of every non-allowlisted `Bash` command (a
multi-line `apply_patch <<'EOF' … EOF` heredoc denies there via the lexer's own NR>1 rejection,
independent of which tool_name Codex ultimately reports it as).

**Live-probe record (#259).** The two limits #235 shipped unresolved were closed by a probe the
maintainer ran on 2026-09-08 against Claude Code **2.1.263** (plugin 2.7.0 from the marketplace
cache), on macOS: a temporary logging `PreToolUse` hook (matcher `Bash`, appending each call's
stdin JSON to a log file) declared in `.claude/settings.local.json` alongside the plugin's own two
hooks, then one `implementer` and one `verifier` subagent each dispatched via the Agent tool to
run a single `git -C <repo> status --porcelain`. Captured stdin carried `agent_type` as the
namespaced `trail-blazer-flow:implementer` / `trail-blazer-flow:verifier` form for both roles
(alongside `agent_id`, `tool_name: "Bash"`, and `permission_mode: "auto"`) — the current Claude
Code hooks reference documents `agent_type` as present "when the session uses `--agent` or the
hook fires inside a subagent" and lists namespaced `plugin-name:agent-name` forms in its
matcher-patterns table, but had not stated the `PreToolUse` stdin spelling explicitly until this
probe. Both spellings still ship: the namespaced form is now the confirmed live value, and the
bare form is retained as insurance against a future de-namespacing, not as a hedge against an
unknown one. Replaying the implementer's captured stdin through both installed hooks,
`git-c-guard.sh` emitted `allow` (rc 0) for the identical `git -C <worktree> status --porcelain`
call and this hook exited 2 (deny); Claude Code's composed verdict was a **block** — the
implementer reported the call never ran — while the verifier's identical read-only call **ran**
(then failed on a nonexistent path, rc 128, unrelated to this hook). Scope: one Claude Code
version, one platform (macOS), one install shape (marketplace cache) — not verified across
versions, platforms, or install shapes; the Windows spot-check named under "Prerequisites" is
still open, and `dev/hook-tests.sh`'s own `git -C <worktree> push`/`commit` cases keep pinning
this hook's OWN verdict independent of that composition.

**Verdict provenance.** The kickback loop is enforced the same way as the rest of this section:
the orchestrator never edits a source, test, or doc file to resolve a verifier finding or a red
CI run itself — its only edits anywhere in this pipeline are harness bookkeeping
(`.claude/LESSONS.md`, the PR body, issue comments) — and the merge pass's hard floor requires
three artifacts to agree before any autonomous merge: the PR body carries the verifier's own
closing status line (`<!-- harness-status: stage=verifier issue=<n> outcome=pass retries=<k>
harness=<version> -->`) verbatim, checked mechanically (`gh pr view … --jq 'contains(...)'`); the dispatch ledger's
`verifier` row for that issue reads `pass`; and the verifier's verdict is separately archived,
also verbatim, as an issue comment opening with `<!-- verifier-verdict -->` — posted by the
orchestrator after every verifier pass, including a CI-fix re-verification — whose second line
keys the archive to this PR's head branch (`<!-- verifier-verdict-branch: claude/<n>-<slug>
-->`). The merge pass matches the newest verdict archived **for that branch**, not the newest on
the issue, so a deliberately multi-PR issue split across several `claude/<n>-*` branches has each
slice match its own verdict instead of an earlier slice losing to whichever slice verified last.
That keyed comment's own closing status line is what the PR body's line is checked against
literally before the merge pass proceeds. A prose "verifier verdict: pass" without the PR-body
line, or a PR body with no archived comment keyed to its head branch, does not qualify —
including a PR opened before this keying existed, whose archive carries no key line and which
therefore waits for a human merge rather than being retrofitted. Since #287 (consolidating #277's
narrower original), a rejected or unparseable read of that archive comment — never a determinate
"no archive for this branch" — gets the same one bounded re-check every floor provenance read now
gets (`sleep 30`, then one more `gh issue view`, per #223's rule) before the PR is held; a read
still failing after that one retry holds the PR **not eligible** exactly as before — the retry
narrows how often a transient API blip strands an otherwise-mergeable PR, it does not relax what
the floor accepts. Honest limit: the check proves
a matching line is present in the PR body, agrees with the ledger, and agrees with a comment
independently timestamped on the issue —
not that a human witnessed the dispatch. All three artifacts are still orchestrator-written, so a
misreporting orchestrator can still fabricate them; the gain is that doing so now requires two
consistent, durably visible artifacts instead of one, raising the cost of asserting a verification
event that didn't happen rather than eliminating the possibility.

**Approval provenance** (#174, content binding added by #192, current-label-state pre-filter added
by #229). The `plan-approved` label attaches
to the *issue*, not to a specific plan comment, so a naive read of the label alone can't tell a
still-current approval from one a later revision has silently outrun — or one whose text has
since been edited in place. The single cheapest check runs first, at zero extra API cost, reading
a field on a call `find-implementation-work.sh` already makes: is `plan-approved` currently in the
issue's `labels`? Its absence (`reason: "approval-label-absent"`) means the human withdrew the
approval, or never applied it, and short-circuits everything below — no events lookup, no
plan-edit lookup, `covers_plan: false`, `binding_line: null`. Only once the label is confirmed
present does `find-implementation-work.sh` compute an
identity-timing-and-content binding, fresh every time it's asked: it reads the newest
`labeled` event for `plan-approved` from GitHub's own issue-events API and compares its timestamp
against the selected plan comment's `createdAt` — the approval **covers** the plan only when the
label's newest application is not earlier than the comment (equal timestamps count, so the
auto-approval path — which labels immediately after posting — always covers its own plan) — AND
(#192) against that same comment's REST `updated_at`: an in-place edit made *after* the approval
event un-covers the plan too (`reason: "plan-edited-after-approval"`, no `binding_line`, one
extra read-only API call made only on this otherwise-covered branch AND ONLY when gh's own
per-comment `includesCreatedEdit` on the plan comment is not exactly `false` — see
`CHANGELOG.md` (the archived v2.7.2 migration notes, #240) for the cost reduction), the implementer's gate and
the merge floor holding exactly as they do for `plan-after-approval`, with no changes of their
own; an edit made *before* approval stays covered on purpose (the approver read the edited text);
an unreadable edit-state lookup fails closed to `covers_plan: null`, an **unknown** verdict
(`reason: "plan-edit-unreadable"`), the same tri-state `approval-unreadable` already used. The
same events call (#375) also reports a `closed` event: a close at or after the newest labeling
means that approval was consumed by the close (`reason: "closed-after-approval"`,
`covers_plan: false`, handled exactly like `plan-after-approval`) at no extra API cost, and
re-approving after a reopen (removing and re-adding `plan-approved`) restores coverage. When
the plan covers, the script emits a `binding_line` naming the specific plan comment and approval
timestamp; the `issue-implementer` skill revalidates this **before dispatch and again before
push**, splitting its remedy by verdict since #219: a same-run revision (or in-place edit)
landing in between and demonstrably un-covering the plan (`covers_plan: false`) makes the skill
remove `plan-approved` and return the issue to review rather than build a plan nobody approved;
**at the pre-push re-check only, a same-plan re-approval is accepted instead (#238)** —
`covers_plan: true` still naming the *same* plan comment, only `approved_at` moved because a human
removed and re-added `plan-approved` while the implementer worked — and the run proceeds, pasting
this run's fresh `binding_line`, never the one captured before dispatch, into the PR body; a
`covers_plan: true` verdict naming a *different* plan comment is a real change of plan, not a
re-approval, and still returns the issue to review exactly as before, with `plan-approved` removed;
an **unknown** verdict — a GitHub API call failed, so a same-run outage is indistinguishable from
one that revoked nothing — first gets one bounded re-check at both checkpoints (`sleep 30`, then
`find-implementation-work.sh --issue <n>` once more, #223) before the verdict is concluded; only a
verdict still unknown after that retry holds
non-destructively: no label is touched; before dispatch,
the issue is simply left undispatched for the next run to re-check; before push, the
already-staged, already-implemented tree is checkpointed (`wip: checkpoint binding-recheck`)
rather than discarded. Either way one `<!-- harness-audit -->`-marked comment records the hold —
its second line carrying the key `<!-- harness-hold: issue=<n> stage=<stage> reason=<reason>
comments=<ids> -->` (#222, the same de-dup treatment #208 gives the planner's staleness note) —
and is skipped when the issue's newest maintainer-authored hold
comment already carries the identical key, so a multi-hour outage no longer buries the issue under
one duplicate hold per scheduled cycle; the run-summary flag is never suppressed, only the comment
is, and only `OWNER`/`MEMBER`/`COLLABORATOR` comments satisfy the guard, so a forged key cannot
silence a real hold. The `approval-label-absent` hold above is deliberately unkeyed: batch
discovery already excludes any issue without `plan-approved`, so it cannot repeat across scheduled
runs, and keying it would suppress a genuine second withdrawal notice after a re-approval. Either
way, the issue stays queued for the next run's fresh check rather than being bounced back to the
human. One accepted consequence of the pre-push hold: a held issue keeps `plan-approved`, gains no
`impl-blocked`,
and so is reported as a `contradiction` by `issue-cycle`'s closing reconciliation (its chain
otherwise shows the implementer complete and the verifier passing) — expected, not a bug, and
`issue-cycle` treats a `contradiction` as "report with evidence, unfinished," never an escalation.
The `issue-cycle` merge pass revalidates the covered case once more, requiring that the PR body
carry one of `approval.approved_at_history[]`'s `binding_line` values verbatim before an
autonomous merge (#213 — see below for why the check now accepts more than just the freshest
`binding_line`) — the held case never reaches a PR, so the merge pass never sees it. Since #287
(consolidating #245's narrower original), an **unknown** `covers_plan` verdict at that same
merge-floor read gets the same one bounded re-check every floor provenance read now gets — the
implementer's two checkpoints already get an identical one above (`sleep 30`, then one more
`find-implementation-work.sh --issue <n>`, per #223's rule) — before the PR is held; a verdict
still unknown after that one retry holds the PR **not eligible** exactly as before — the retry
narrows how often a transient API blip strands an otherwise-mergeable PR, it does not relax what
the floor accepts. Honest limit:
like verdict
provenance above, all three checkpoints (the discovery script, the PR body, the merge pass) are
orchestrator-written and share one `gh` identity, so this raises the cost of asserting an approval
that didn't happen rather than eliminating it; the edit check itself is a **tripwire, not a
control**, for the same reason — the same `gh` identity that edits the comment can also re-approve
it (removing and re-adding `plan-approved` moves `approved_at` past the edit and re-covers it, the
audited path already documented below), and the comment's content is never hashed or otherwise
verified, only its *edit timestamp*. #240 adds a second, narrower honest limit on top of that one:
the plan-comment and every covered decision-comment lookup below are skipped entirely — no
`updated_at` read at all — when gh's own per-comment `includesCreatedEdit` reports exactly `false`.
This can only ever WIDEN the covered set on a determinate `false`; it is a tripwire, not a control,
in the same sense as the edit check itself — a `false` GitHub reports for a comment that WAS
genuinely edited would skip the lookup silently, same as any other tripwire the harness trusts
GitHub's own field for. The same binding also governs each trusted post-plan
*comment*, not just the plan (#194): `find-implementation-work.sh` marks every `trusted_post_plan`
entry `covered_by_approval: true` when the comment's `createdAt` is not later than
`approval.approved_at` and `false` when it is later — a maintainer who comments after approving is
not silently treated as having amended the approved plan; the comment is reported to the human
(`counts.post_approval_comments`, a `warn:` line) instead of becoming a binding `RESOLVED:`
decision. Since #230, the same content-edit binding #192 applies to the plan comment ALSO applies
to every decision comment workstream B marked covered: one extra read-only REST call per *covered*
comment (never an already-uncovered one, never on an already-uncovered issue, and — since #240,
see `CHANGELOG.md` (the archived v2.7.2 migration notes) — never a comment gh's own `includesCreatedEdit`
already reports as never edited) compares its own
`updated_at` against `approval.approved_at` — a covered decision comment edited in place strictly
*after* approval flips that entry to `covered_by_approval: false`,
`covered_by_approval_reason: "decision-edited-after-approval"`, and collapses the ISSUE-LEVEL
verdict to `covers_plan: false` too (the same `RESOLVED:` decision nobody actually approved, #192's
gap closed for decisions as well as the plan); an entry whose own edit state cannot be established
(an unparseable comment id, a rejected lookup, or an unreadable `updated_at`) instead collapses the
verdict to **unknown** (`covered_by_approval_reason: "decision-edit-unreadable"`), with edited
beating unreadable when an issue has both. `counts.post_approval_comments` keeps its name but
narrows: it now counts only entries whose `false` comes from postdating the label, not from their
own edit (which is counted separately, `counts.decision_edited_after_approval` /
`counts.decision_edit_unreadable`) — the same tripwire-not-a-control caveat as the plan-comment
check applies identically here (a re-approval, not a content hash, is the remedy). To
make a post-approval comment binding **before a PR exists**, remove and re-add `plan-approved` —
the same audited path #174 already documents, not a new surface (see below — since #213, this
same act also releases an already-open PR, provided the plan itself is unchanged). A comment that
arrives *while the implementer is
working* is not silently missed either (#198): the pre-push re-validation above diffs that same
fresh run's uncovered `trusted_post_plan` set against the set captured before dispatch, and any
newly-arrived entry is quoted verbatim in the PR body and the run summary — still non-binding,
still never holding the push; **on a same-plan re-approval (#238), that same re-check also
surfaces any comment the re-approval itself newly covered** — one whose `covered_by_approval`
flips to `true` and whose `createdAt` postdates the `approval.approved_at` captured before
dispatch — quoted verbatim in the PR body and the run summary and flagged as covered by the
re-approval but **not** implemented, so the human decides whether the PR is still what they want;
the residual race between that re-check and `gh pr create` itself
is a named, out-of-scope honest limit. Since #206, the merge pass's hard floor goes further: it
reads that same uncovered `trusted_post_plan` set at merge time, from the identical fresh
`find-implementation-work.sh --issue <n>` run it already makes for the plan-binding check above
(the retry run, when one ran, #245), so a comment posted even *after* the PR opened is caught
too, not just the dispatch-window race
above. One or more uncovered entries hold the PR in the normal "waits on the human" queue
(`outcome=not-eligible`), with each entry's comment URL (or author + `createdAt` when the URL is
null) as the one-line reason — a normal wait, not an escalation. Release path: the human merges
the PR themselves, withdraws the comment and lets the next cycle re-evaluate a clean set, **or
re-adds `plan-approved` (#213)** — since re-approving covers every comment posted before it (the
same rule the sentence above already states for the pre-PR case), and since the *plan-binding*
check above now accepts a PR body written under any real earlier approval of the same plan, not
just the freshest one, re-approval also **releases an already-open PR**. This is a deliberate
widening: a maintainer who comments on an open PR's issue and then re-approves the same plan
releases that PR **without the comment having been implemented**. The documented remedy is
ordering, not a new marker: **close the PR first, then re-approve** — the comment then binds the
next dispatch instead of being silently released underneath the old one. A different plan
comment's url, a timestamp matching no real `plan-approved` labeling event, an empty approval
history, or an unreadable events lookup all still hold the PR exactly as before — re-approval only
ever pastes a needle this issue's own history actually produced.

**The body-hash grant pattern is a tripwire, not a control** (see "The CLAUDE.md contract" item
8). It exists only as a documented convention a consuming repo may adopt in its own CLAUDE.md —
this harness never computes or verifies a body hash itself. Even where a repo adopts it, the
harness and the human share one `gh` identity, so anyone able to post the `grant: <sha256>`
comment can also edit the issue body and re-post a matching hash; a mismatch means "grant void,
standard flow" only because the repo's own instructions say so, not because the harness enforces
anything. Separately, and unconditionally: the harness never applies or removes a scoped-autonomy
grant label itself, on any issue — `check-harness.sh` and `check-decision-record.sh` only report
whether the label exists and whether the declared record is present.

Two honest caveats. First, the implementer/verifier "no git, no gh" rule is mechanically
enforced, not just prompt convention (#235, review F3): the settings allow-list must still permit
`git`/`gh` for the orchestrator, and permission grants are session-wide — but a second
plugin-shipped `PreToolUse` hook, `hooks/agent-boundary.sh`, reads each Bash call's `agent_type`
and denies (exit 2, before permission rules are even evaluated) any command whose command-position
word resolves to `git`/`gh` for the implementer, or to `gh`/a non-read-only `git` subcommand for
the verifier; see "Safety model" for the full contract, including its live-probe record
(2026-09-08, Claude Code 2.1.263: the namespaced `agent_type` spelling, and this hook's `deny`
beating `git-c-guard.sh`'s `allow` on the same call) and its no-opinion edges (the main
session, any other agent, `permission_mode: "plan"`, and a Claude Code that omits `agent_type`
altogether all leave the hook silent — the same session-wide allow list this caveat used to
describe in full, now narrowed to exactly those cases). The staged-file reconciliation and branch
isolation remain the backstop for whatever this mechanical boundary doesn't reach. Second, plan auto-approval and
merge autonomy (each opt-in via `CLAUDE.md` — see "The CLAUDE.md contract" items 4–5, or item 9's
"Autonomy mode" section, which turns both on together as one combination)
deliberately trade human gates for throughput on low-risk work. Their hard floors are not
configurable by the policy section — the one exception is itself part of the floor's fixed
definition, not something a policy can widen: on an issue the human granted under the repo's
scoped-autonomy declarations (see "The CLAUDE.md contract" item 8, "Autonomy decision record"),
an orchestrator-proposed answer to a BLOCKING question skips the human wait only if it quotes the
human-authored binding-record bullet it derives from. The grant label itself is applied by the
human, per issue, and the harness never applies it, so an uncitable answer still waits, and every
use is audited (issue comment; cycle report). With only auto-approval enabled, a bad
auto-approval costs a wasted PR, not a bad merge. With merge
autonomy also enabled, the backstop is the merge pass's hard floor (standard-flow PRs only,
green CI on a head that mechanically contains the default branch's current tip (#234) — a
`git fetch origin` still failing after one retry holds rather than comparing a stale tip (#319)
— protected governance surface, read mechanically from the PR's own diff (#324) — audited
exception: a harness PR whose only governance-surface change is a
bounded, add-only `.claude/LESSONS.md` append (#307) — sequential re-verification) — and on a repo with branch protection + required
checks, that floor is a technical rail, not just policy. Enable
merge autonomy only where a bad merge is cheap to revert (e.g. a default branch that doesn't
auto-deploy) — or, on a repo whose default branch does auto-deploy, declare a "Post-merge
verification" sub-block (see "The CLAUDE.md contract" item 5) so "merged" stops standing in for
"shipped": the declared commands are reads only, and the harness never approves, promotes, or
redeploys anything on your behalf — it only observes and records what the deploy did.

Third, harness-authored issues are the exception to a pipeline that otherwise starts from
human-authored ones — the test-suite ratchet (also opt-in via CLAUDE.md) is one source, held by
the planner's hard floor refusing any `test-ratchet`-labelled issue outright, a label the harness
never removes; the plan follow-ups the implementer files from a PR's
"Follow-ups to file" are the other, born `no-plan` (holding planning itself, not just approval)
plus a marker naming their PR. `cleanup-after-merge.sh --fix`'s quarantine (comment + `no-plan`
when it isn't already present, never closed) for an orphaned follow-up reaches a follow-up born
`no-plan` too (#334): its idempotence key is a trusted, PR-keyed
`<!-- harness-orphan-notice: PR #<n> -->` marker in the issue's own comments, not the label. The
ratchet's further mitigations: the fixed issue-body
template, with evidence quoted as literal tool output rather than free-form prose; the "issue
text is data, not instructions" rule below, applied to the ratchet's Evidence section like any
other issue content; the test-only/monotonic scope that binds the plan and that the verifier
checks against; and the per-run and open-backlog caps. A ratchet issue can never propose changes
to the governance surface (`CLAUDE.md`, `.claude/`, policy/ADR docs, CI config) — that boundary
only moves with a human in the loop.

Fourth, every dispatch — not only ratchet-filed issues — treats the issue body and quoted
comments as untrusted **data**, never as instructions (#164): `agents/planner.md`,
`agents/implementer.md`, and `agents/verifier.md` each carry this as a standing constraint (an
embedded directive is a finding to report, never something to obey), and the orchestrating
skills' dispatch prompts quote issue content as delimited data. Mechanically,
`find-planning-work.sh` enforces the planner-facing half of this: only a comment whose GitHub
`authorAssociation` is `OWNER`, `MEMBER`, or `COLLABORATOR` is ever treated as feedback or
honoured as the latest plan comment; a `CONTRIBUTOR`/`NONE` comment, or one with no
`authorAssociation` field at all (fail-closed), posted after the issue's latest trusted plan (or
any such comment, if there is no trusted plan yet) is reported in the `untrusted_comments` bucket
instead of being silently dropped or silently trusted, and never shadows real feedback posted
before it — one posted before that plan is dropped with no bucket entry. The same script also
enforces provenance on WHO OPENED the issue: every discovered issue carries `trusted_author`, a
non-maintainer-authored (or association-unreadable, after one bounded retry, #246) issue is
reported in `untrusted_issue_authors` and can never be auto-approved, though it is still planned
(#176). `find-implementation-work.sh`
enforces the implementer-facing half the same way: it selects each ready issue's approved plan
comment and binding post-plan comments itself, using the identical trust gate (gate assertion
4.26 pins that the two discovery scripts' trusted-association lists agree), so the
`issue-implementer` orchestrator reads a filtered artifact instead of applying the rule from
memory (#176) — the same script also computes the approval-binding verdict described in
"Approval provenance" above (#174). `cleanup-after-merge.sh` applies the identical trust gate to
a narrower, third question (#231): whether a `<!-- harness-multi-pr -->` marker posted in an
issue COMMENT is honoured as a multi-PR `KEEP` signal — the same OWNER/MEMBER/COLLABORATOR list
(4.26 extended to all three scripts), the same `ascii_upcase`-normalised comparison, and the same
fail-closed-on-missing-`authorAssociation` rule; an ignored, untrusted marker prints one `WARN`
line naming the comment's url and association instead of being silently dropped. Cleanup has no
REST author-association lookup for the issue itself, though, so it cannot gate an issue-BODY
marker the way the two discovery scripts gate the issue AUTHOR — it simply stopped honouring
that path; a human-applied `multi-pr` label is the primary, permission-controlled signal instead
(see "Label lifecycle"). Both
scripts share a second, orthogonal exclusion inside the trusted set (#182): any trusted comment
containing `<!-- harness-audit -->` (a harness-authored audit/hygiene record — the planner's
auto-approval audit trail, its `plan-approved` staleness note — whose second line, since #208,
also carries a `<!-- harness-staleness: issue=<n> prs=<prs> -->` key naming the merged PRs that
caused the staleness, so a repeat run skips re-posting it once the issue's newest
maintainer-authored staleness comment already records that same PR set — the
implementer's unknown-verdict hold comment (see "Approval provenance" above) — whose second line
also carries a `<!-- harness-hold: issue=<n> stage=<stage> reason=<reason> comments=<ids> -->`
key, so a repeat run skips re-posting it once the issue's newest maintainer-authored hold comment
already records that same key (#222) — the planner's own step-7 stall record (#395), whose second
line carries a `<!-- harness-stall: issue=<n> stage=<plan-initial|plan-revision>
reason=stalled-dispatch -->` key — posted on a `stalled-dispatch` run (the subagent dispatch
produced no plan) that has not yet reached the escalation threshold; unlike the staleness/hold
comments above it has NO de-dup guard, because it is meant to be counted, not collapsed:
`find-planning-work.sh` sums every trusted stall record posted after the issue's newest trusted
plan comment into `prior_stalls` (a posted plan resets the count), so it is always a record, never
feedback and never a plan candidate (excluded by the same audit-marker rules as every other
harness-authored comment here) — the
implementer's interrupted-run and worktree-sweep notes, `cleanup-after-merge.sh`'s hygiene
comments), `<!-- verifier-verdict
-->` (the orchestrator's own archive), or, since #309, `<!-- harness-escalation -->` — the marker
every durable escalation opens with, whether posted by the implementer (see
`skills/issue-implementer/SKILL.md`'s "Durable escalation" subsection) or, since #349, by the
planner's own step 7 for a stalled stage — whose second line
carries a `<!-- harness-escalation-key: issue=<n> stage=<stage> reason=<slug> comments=<ids> -->`
key (an older planner's step-7 record instead opened with `<!-- harness-audit -->` and carried a
`<!-- harness-escalation: bucket=<bucket> stage=<stage> -->` key; such legacy comments are still
excluded above by the audit marker) — anywhere in its body is excluded from
`find-planning-work.sh`'s feedback detection (counted in `counts.escalation_records_skipped`) and
`find-implementation-work.sh`'s
`trusted_post_plan` alike — a harness-authored record is never binding context, on either side of
the pipeline. All three markers are matched with `contains` for these two sets, not anchored to the
comment's first line (the same behaviour the verdict marker has always had) — a maintainer who
quotes a marker verbatim inside their own feedback, without opening the comment with it, still has
that comment dropped from both binding sets (no revision, no `trusted_post_plan` entry), but since
v2.7.6 (#321, extended #309) it is no longer silent: both scripts name it in a `warn:` line and
count it in `counts.harness_marker_quoters` (see `CHANGELOG.md` for the archived v2.7.6
migration notes for #321 and #309). Only a comment that itself
OPENS WITH a verbatim marker copy at byte 0 is still silently dropped, indistinguishable from a
genuine harness-authored record — accepted as an inherited risk rather than fixed here, for the
feedback/binding sets specifically. Since #281
(superseding #275), plan selection on both scripts is a POSITIVE, first-line anchor rather than a
harness-marker exclusion: the newest trusted comment either script would treat as "the plan" must
itself OPEN WITH (`startswith`, anchored to the comment's first line) the plan marker
(`<!-- planner-plan -->`) — not merely `contains` it, the strength the feedback/binding sets above
still use. Because opening with the plan marker implies both containing it and not opening with
either harness marker, this positive anchor subsumes #275's original exclusion (a harness-authored
record opens with its OWN marker, never the plan marker) and additionally closes the gap #275 left
open: a record whose harness marker is preceded by prose, that also quotes the plan marker
mid-body, is excluded from plan selection too, because it does not open with the plan marker
either. This asymmetry (anchored at plan selection, `contains` at feedback/binding) is deliberate,
not an oversight: over-excluding at the feedback/binding sets is safe (a record is merely
dropped), but over-excluding at plan selection is destructive (an approved plan would be thrown
away, and `issue-implementer`'s step 2a remedy for the resulting `no-plan` verdict is to strip
`plan-approved` and post a revision-triggering comment) — so a plan comment that merely quotes a
harness marker in its own prose is still selected as the plan, while a maintainer-authored record
that quotes the plan marker verbatim, wherever its own harness marker sits (or absent entirely) —
the live #245 shape, generalised — is not. The named limit is now split differently: a maintainer
who quotes a harness marker inside their own FEEDBACK, without opening the comment with it, is
named and counted since v2.7.6 (#321, above); a trusted comment that quotes the plan marker
mid-body is still excluded from BOTH plan selection and the feedback/binding sets, and since
v2.7.4 (#302) both scripts now name it in a `warn:` line (author, createdAt, url) and count it in
`counts.plan_marker_quoters` — but only when that same comment was posted after the latest plan
(or at any time when there is none) AND carries neither harness-record marker of its own; a
trusted comment that quotes the plan marker mid-body AND also carries `<!-- harness-audit -->` or
`<!-- verifier-verdict -->` without opening with it (a maintainer's own prose-then-harness-marker
copy) is a harness-marker quoter too — disjoint from `counts.plan_marker_quoters`, it is named and
counted instead in `counts.harness_marker_quoters`; a genuine harness record, which opens with its
own marker, is counted in neither key and is not warned about, as before (#321). For both
classes, the drop is no longer silent — #302's own diagnosis also covers a
hand-posted plan with text before its own marker,
since the window covers "any time" when there is no selectable plan yet; and a hand-posted plan
comment with anything before the marker is not selectable — repost it with the
marker as the comment's first line (editing the comment in place would trip the
plan-edited-after-approval check instead). The filter only ever narrows the trusted set: a forged marker from an untrusted
author still surfaces, unfiltered, in `untrusted_comments` / `untrusted_post_plan`, exactly like
a forged plan marker does — and, since #194, is additionally FLAGGED there: both scripts add a
`has_harness_marker: true` boolean to that entry (alongside the existing `has_plan_marker`),
counted in `counts.untrusted_harness_markers` and named in a `warn:` line, so the human sees the
impersonation called out rather than having to notice the marker text themselves — annotation
only, the untrusted bucket is still never filtered by it (gate assertion 4.29 pins that the two
scripts' flag names agree; gate
assertion 4.27 pins the marker's presence in every writer and consumer). Three comment surfaces
stay deliberately unmarked because they *are* the feedback that drives a subsequent dispatch, not
a record of one: the planner's `plan-proposed` staleness note, its proposed-answers comment, and
the implementer's blocked-path comment (which step 2b explicitly reads back into the retry
dispatch). The honest limit: this mechanical coverage (the `has_harness_marker` annotation, the
`<!-- harness-audit -->` exclusion) is planner- and implementer-side only, and stays that way for
`cleanup-after-merge.sh` too — its comment-marker trust gate (#231, above) is real, but the
verifier-side half of the untrusted-data rule is still prompt-enforced, not mechanically checked.

**One active cycle per checkout (#232).** `bin/harness-lock.sh` is a single-flight lock: an
atomic `mkdir` of `<git-common-dir>/trail-blazer/lock` (`git rev-parse --git-common-dir`, so
every worktree of one checkout — including a worktree-parallel swarm — shares a single lock;
never inside the tracked working tree, never committed). The lock directory holds six plain
files: `run-id`, `pid`, `host`, `started-at`, `harness-version`, `checkout-path`. The
`issue-cycle`, `issue-planner`, and `issue-implementer` skills each `acquire` it at their own
step 0 and `release` it at their closing step — except that the outermost run owns the lock:
when `issue-cycle` runs the planner or implementer's own step 0 as part of a composed pass, that
sub-skill's acquire/release are skipped, because `acquire` is deliberately not
same-pid-idempotent (a second acquire from the same live session would itself refuse and abort
the run). A refused acquire aborts the run loudly, before any tree-mutating command, printing the
holder record and the exact `harness-lock.sh release --force` remedy; the lock is released on
every STOP/abort path too, not only the normal close, since the recorded pid outlives the run
that acquired it. The recorded pid follows a precedence (#408): `acquire --owner-pid <pid>` >
`TBF_OWNER_PID` > `${CLAUDE_PID:-$PPID}` (the original rule). Under Claude Code, `CLAUDE_PID` is
the long-lived session process (exported to every Bash tool call), while a Bash tool call's own
`$PPID` is already dead by the time the next call starts — measured live (two separate Bash tool
invocations, same `CLAUDE_PID`, the second `acquire` refusing rather than reclaiming); recording
bare `$PPID` would make the very next `acquire` see a dead pid and reclaim its own lock, an inert
guard. `$PPID` remains the fallback for a human running the script by hand from an interactive
shell; Claude Code passes neither flag nor env var, so its own behavior is unchanged. On Codex,
where `$PPID` is the session's own `codex` process under `codex exec`/`codex --no-daemon` (ADR
0002 P6), a caller that can't rely on that fallback passes it explicitly:
`harness-lock.sh acquire --owner-pid "$PPID"`. Before creating anything, `acquire` also refuses
(exit 2) when the resolved owner's own command line names a Codex `app-server` daemon — such an
owner never dies, so a lock recorded against it could never be reclaimed; see
`docs/reference/codex.md`. **Reclaim rule:** a lock held by a live process on the SAME host, or by ANY process on a
DIFFERENT host, refuses; a same-host holder whose pid is no longer alive is reclaimed
automatically (one audit line quoting the stale record); a record with a missing or non-digits
`pid`/`host` file always refuses rather than reclaiming — the remedy is always
`harness-lock.sh release --force`. **Honest limits:** this is an advisory lock, not a kernel
mutex — `mkdir` atomicity holds on a local filesystem only, not a synced/shared network volume;
liveness is same-host only, so a lock held on a different machine is never inspected, only
refused; a dead pid recycled by an unrelated process before the next check fails CLOSED (refuses,
never silently reclaims); and a run interrupted (Ctrl-C, crash) inside a still-live Claude Code
session leaves its lock held until that session exits or a human runs `release --force`, since
the recorded pid is the session, not the interrupted run. `dev/lock-tests.sh` pins the script's
own behavior above — the acquire/reclaim/release/status semantics, the shared-worktree lock path,
and the recorded-pid rule; see CLAUDE.md's "Verification" section. The skills' acquire-at-step-0 /
release-at-close-or-abort placement is prompt-enforced, not mechanically checked — gate assertion
4.36 pins only the subcommand vocabulary the three skills invoke against `LOCK_SUBCOMMANDS`.
