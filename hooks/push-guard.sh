#!/usr/bin/env bash
#
# push-guard.sh — plugin-shipped PreToolUse hook (#260) that mechanically narrows every Bash
# call's `git push` surface, main session included (unlike hooks/agent-boundary.sh, which only
# governs the implementer/verifier subagents): it denies (exit 2, one stderr line, empty stdout)
# any push whose resolved DESTINATION is the repo's default branch, and says nothing (exit 0,
# empty stdout, empty stderr — "no opinion") about everything else, so the normal permission flow
# — a prompt, or a matching deny rule in templates/repo-settings.json, which always wins over this
# hook's decision — applies. This closes the gap #260 names: the settings deny entries
# `Bash(git push origin main:*)` / `Bash(git -C * push origin main*)` are prefix-matched and are
# bypassed by refspec spellings such as `HEAD:main`, `+HEAD:refs/heads/main`, or a remote other
# than `origin` — this hook parses the refspec instead of pattern-matching the raw command text.
#
# Enforces only "deny a push whose destination is the default branch"; does NOT enforce an
# allow-list of `claude/<n>-<slug>` destinations (the Decision's other clause) — that would deny
# ordinary work (a `release/vX.Y.Z` branch, an annotated-tag push, any `git push origin
# feature/x` a human runs in ANY Claude Code session in a plugin-enabled repo, since this hook is
# plugin-wide, not harness-flow-scoped) for no matching safety gain, and a plugin that blocks
# ordinary pushes gets `disableAllHooks: true`, which would cost hooks/agent-boundary.sh's control
# too. The `claude/<n>-<slug>` shape is documented (see the README's "Safety model") as this
# harness's own convention, not mechanically required.
#
# Tokenizer: the POSIX-awk segment/token walker below is a near-twin of hooks/agent-boundary.sh's
# (see that script's "the scan" section, lines 143-236) — same segment-break characters, same
# normalize() (quote/backslash strip + basename), same repeat-until-exhausted PREFIX_WORDS skip
# (never once-only — a once-only skip is the M23 regression class agent-boundary.sh's own
# dev/hook-tests.sh table documents), since #398 the same tolower() fold applied to the command word
# and to prefix-word matching (so `if true; then git push origin main; fi`, `! git push origin
# main`, and `GIT push origin main` all still resolve `git` as the command word — see PREFIX_WORDS'
# own declaration above for the added shell-keyword vocabulary), and, since #270, the same
# bash-native carriage-return strip
# of $cmd applied immediately after the jq extraction and before this script's own `[ -n "$cmd" ]`
# guard (see that same point in each file — a CRLF-carrying transport can otherwise deliver a
# command whose tokens carry a trailing `\r`, which every exact-match comparison below would miss).
# A future fix to either tokenizer's shared behaviour (segment breaking, normalize(), the
# prefix-word skip, the command-word case fold, the CR strip) must be applied to BOTH files — see
# this repo's
# CLAUDE.md and dev/selfcheck.sh's assertion 4.40 clause (c), which mechanically pins the two
# scripts' PREFIX_WORDS vocabulary stays byte-identical. Differences from agent-boundary.sh's
# tokenizer: after resolving a segment's command word as `git`, this script walks forward again
# skipping a GIT_GLOBAL_OPTS_WITH_VALUE token together with its next token (a value), or any other
# `-…` token alone, until the first non-dash token — the subcommand; if that subcommand is exactly
# `push`, the segment's REMAINING tokens (the push's own options/remote/refspecs) are emitted
# quote/backslash-stripped but WITHOUT a basename normalisation — a refspec destination like
# `refs/heads/main` or `claude/17-a` is a path-shaped value whose `/` is semantically load-bearing,
# unlike a command word's path, so collapsing it to a basename would silently destroy the very
# `refs/heads/` prefix the refspec_dest() function below needs to read.
#
# Repo resolution (reads only, NEVER executes anything): the SESSION checkout is resolved by
# starting from the PreToolUse stdin `cwd` field (documented in Claude Code's hooks reference;
# degrades to `$PWD` when absent) and walking upward, at most 64 parent directories, looking for
# `<dir>/.git` — a directory (an ordinary checkout) or a regular file (a worktree pointer, `gitdir:
# <path>`; a FIFO or a directory-shaped path is excluded by the `[ -f ]` guard every read here
# uses). The default branch is read from the common dir's `refs/remotes/origin/HEAD` symref; the
# current branch from the resolved gitdir's own `HEAD` symref; since #268, the same common dir's
# `config` file is also text-parsed (never executed as `git config`, never a second process) for
# `remote.<name>.push` and `push.default`/`branch.<current>.merge` — for a worktree this is the
# MAIN checkout's config, the identical common-dir rule the origin-HEAD symref read already uses,
# never the worktree pointer's own gitdir. Since #290, THREE global candidates are text-parsed the
# same way and UNIONED with that repo-local config: `$GIT_CONFIG_GLOBAL` (when set and non-empty),
# `$XDG_CONFIG_HOME/git/config` (or, when `$XDG_CONFIG_HOME` is unset or empty, `$HOME/.config/git/config`),
# and `$HOME/.gitconfig` — every path taken from the ENVIRONMENT, never from the untrusted command
# string, and read only when the checkout being resolved (session or a resolved `-C` target) has
# actually resolved a gitdir (see `resolve_repo()`'s config-candidate loop for the exact order:
# every global candidate first, this checkout's own repo-local config last, so a last-wins scalar
# resolves to the repo's own value on any conflict). This closes only the REPO-LOCAL half of the
# global/system config class named in every version of this file before #290 — see "Documented
# under-blocking classes" below for what still stays unread (`/etc/gitconfig`,
# `GIT_CONFIG_SYSTEM`/`GIT_CONFIG_NOSYSTEM`, `include`/`includeIf`, and the env-injected
# `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_<n>` forms). The config file(s) are read whole with no size
# cap — a pathological file simply degrades to Claude Code's 10s hook timeout (silence, the same
# fail-open every other resolution failure already has). Any failure at any step leaves both
# branch values, and the config-derived variables, empty — never an error, never a non-zero exit
# from this hook on that account alone.
#
# Since #269, a push segment carrying exactly one DETACHED `-C <path>` token (not the attached
# `-C<path>` form, and not a segment with a second `-C`) whose value satisfies the PATH_ERE
# predicate below — byte-identical to, and mechanically pinned against (dev/selfcheck.sh's
# assertion 4.42), hooks/git-c-guard.sh's own predicate of the same name — is ALSO resolved: the
# named directory itself (never walking upward the way git itself would from a real `-C`; a
# documented residual class below), at most one level deep. When that resolves a gitdir, the
# segment's CURRENT BRANCH and its three config-derived values (`remote.<name>.push`,
# `push.default`, `branch.<current>.merge`) come SOLELY from that resolved checkout — never a mix
# with the session's own — while the DEFAULT-BRANCH deny member becomes the union of
# `PUSH_DEFAULT_BRANCH_FALLBACK`, the SESSION checkout's own default branch, and the RESOLVED
# checkout's own default branch (a deliberate fail-toward-deny: a second checkout that happens to
# lack its own `refs/remotes/origin/HEAD`, which only `git clone` sets, must not silently lose
# today's guard by replacing the session's default outright). A `-C` value that fails the
# predicate, or that resolves to no gitdir of its own, leaves the segment judged exactly as every
# segment was before #269 — solely against the session checkout (see "Under-blocking classes"
# below for the residual `-C` shapes this never covers). The containment argument for reading a
# path taken from the untrusted command string at all: a resolved target's facts are applied ONLY
# to the segment that names it — ordinarily, only to a push actually executed inside that
# directory (measured exceptions exist for a quoted `-C` value containing a space — see the
# measured rows in the under-blocking inventory below for the exact shapes and rc's; in the
# rows where a captured fragment resolves to a gitdir, the facts applied are still those of a
# DIFFERENT directory this hook itself derived and read under the same predicate, never an
# attacker-arbitrary one) — so even a fully attacker-controlled `<name>-wt-<n>`
# directory can only mis-judge a push executed inside ITSELF or, in those measured shapes,
# inside the fragment resolved from its own quoted value, never the session repo's own push
# segments (every segment starts from a fresh `apply_session_repo()` call, below, before its own
# `-C` value, if any, is considered). Two
# verdicts NARROW as a result and are disclosed, not hidden: a bare `git -C <worktree> push` where
# the session checkout sits on its own default branch (worktree-parallel mode's real shape — see
# `references/worktree-mode.md`) no longer denies merely because the SESSION happens to be on the
# default branch, since the segment is judged against the worktree's own (non-default) current
# branch instead; and a resolved segment no longer inherits the session's REPO-LOCAL `.git/config`
# routes — since #290, this qualification is REPO-LOCAL only: the GLOBAL config candidates
# (`$GIT_CONFIG_GLOBAL`, `$XDG_CONFIG_HOME/git/config` or its default, `$HOME/.gitconfig`) are read
# from the environment identically for every checkout resolved (session or a resolved `-C`
# target), so a resolved segment still sees the SAME global routes the session would, independently
# re-derived from its own `resolve_repo()` call rather than literally inherited.
# The deny set for an UNRESOLVED segment is `PUSH_DEFAULT_BRANCH_FALLBACK` (below) UNION the
# session's resolved default branch, if any — the fallback members are ALWAYS in force (even when
# a repo's real default branch resolves to something else), which is what lets this hook work with
# no `cwd`, no readable `.git`, or a `-C` value this hook does not resolve.
#
# Never invokes `git`, `gh`, or anything else derived from the untrusted command string; never
# `eval`s; never writes a file. Since #269, this hook reads exactly one class of filesystem path
# taken from the untrusted command string — a push segment's own `-C <path>` value, and ONLY when
# it satisfies PATH_ERE below — for `<path>/.git` (directory or `gitdir:` pointer file), that
# gitdir's `HEAD`, and that gitdir's common dir's `refs/remotes/origin/HEAD` and `config`, every
# read the same `[ -f ]`/`[ -d ]`-guarded builtin redirection every other read in this file uses;
# every OTHER filesystem path this hook derives from a resolved checkout (the two symref reads and
# the repo-local `config` read) still comes solely from Claude Code's own `cwd`/`$PWD` or, for a
# resolved `-C` segment, that same `-C <path>` value — never from any other part of the command
# string. Since #290, this hook ALSO reads a THIRD class of path: the three global config
# candidates (`$GIT_CONFIG_GLOBAL`, `$XDG_CONFIG_HOME/git/config` or its default, `$HOME/.gitconfig`)
# — every one of these comes from the ENVIRONMENT, never from `cwd`/`$PWD` and never from the
# untrusted command string; an attacker who does not already control the session's environment
# cannot influence which global files this hook reads, and this class must not be conflated with
# the `-C`-derived containment argument above, which is specifically about paths taken from the
# command string. The untrusted `-C` value itself is fed only to
# `grep` (a here-string, never a piped writer — assertion 1.7) as data, and to shell builtin `[ -f
# ]`/`[ -d ]` tests; resolving it caps its own upward walk at exactly one level (see
# `resolve_repo()`'s `MAX_DEPTH` parameter below), so that value never reaches `dirname`'s argv —
# or any other process's argv — is never `eval`ed, and is never opened for writing. bash + POSIX
# awk only — no jq is actually needed by this hook (unlike its two siblings) since it parses
# `tool_input.command` with awk, not a JSON library, but the raw-stdin fast paths below still gate
# on `jq`'s presence for the few scalar field reads (`tool_name`, `permission_mode`,
# `tool_input.command`, `cwd`) this hook does need — no python, no perl, no GNU-only flags (this
# repo's CLAUDE.md portability convention); exercised under Apple's bash 3.2 by the
# selfcheck-macos CI job, same as bin/*.sh, hooks/git-c-guard.sh, and hooks/agent-boundary.sh.
#
# Documented over-blocking classes (deliberate, not a bug): a heredoc body line beginning `git
# push origin main` (the same quote-blind, line-at-a-time class hooks/agent-boundary.sh documents
# — write file content with the Write/Edit tools, never a Bash heredoc); since #398, that same
# per-line class also denies a heredoc body line whose first word is a shell keyword followed by
# `git push origin main` (e.g. `  then git push origin main`) or whose first word case-folds to
# `git` (e.g. `Git push origin main`) — the same remedy; a remote literally named
# `main`/`master` (`git push main` is evaluated defensively as if `main` might be a branch, not
# only a remote name — see evaluate_segment()'s "n == 1" handling below); `--all`/`--mirror` deny
# unconditionally, since both push every local branch, including the default one; a repo whose
# default branch is not `main`/`master` but which legitimately has an unrelated branch named
# `main` (the fallback deny set is unconditional); since #268, a bare `git push` (n == 0) unions
# EVERY configured remote's `remote.<name>.push` refspecs, not only the remote git would actually
# pick — this hook does not model git's own remote-selection precedence
# (`branch.<n>.pushRemote` -> `remote.pushDefault` -> `branch.<n>.remote` -> `origin`), so a
# route configured on some OTHER remote than the one git would use for this exact push is denied
# too; `push.default = matching` denies unconditionally, the same reasoning as `--all`/`--mirror`
# (`matching` pushes every branch that exists on both ends, which includes the default branch in
# essentially every real repo); a configured `remote.<name>.push` destination containing `*`
# (a wildcard refspec such as `refs/heads/*:refs/heads/*`) denies unconditionally for the same
# reason; and a configured destination whose real value continues past an unquoted `#`/`;` (the
# config-line comment-strip's own marker below) is truncated at that marker and evaluated as the
# shorter, un-suffixed name — measured: `[remote "origin"] push = HEAD:refs/heads/main#hotfix`
# denies as `main` (rc 2) even though the actual destination branch is `main#hotfix`. Since #290,
# THREE new over-blocking classes (alongside every one already named above):
# `$GIT_CONFIG_GLOBAL` is UNIONED with (never a replacement for) `$XDG_CONFIG_HOME/git/config`/
# `$HOME/.config/git/config` and `$HOME/.gitconfig` — real git reads only `$GIT_CONFIG_GLOBAL`,
# when it is set, in place of `$HOME/.gitconfig` — measured: `$GIT_CONFIG_GLOBAL` set to a BENIGN
# file plus a denying `$HOME/.gitconfig` still denies (rc 2), even though real git would never
# consult `$HOME/.gitconfig` once `$GIT_CONFIG_GLOBAL` is set; a `push.default` value from BOTH the
# repo-local config AND a global one is evaluated unconditionally (the same union stance #268 took
# across remotes, now also across files) — this hook does not model git's own precedence, where
# `push.default` is a single scalar with the repo's own value always winning — measured: repo
# `push.default = current` (git's own value, which alone never denies) plus global
# `push.default = upstream` (with a repo `[branch]` section supplying the needed `merge` ref) still
# denies (rc 2); and TWO `push.default = ...` lines inside the SAME file are likewise both
# evaluated — `cfg_push_defaults` accumulates one record per parsed line, never collapsing to a
# file's own last value, so this hook does not model git's own last-wins precedence WITHIN one
# file either, not just across files — measured: a global config carrying `default = upstream`
# then, on the very next line, `default = current` (git itself resolves that file's own
# `push.default` to `current`, its LAST value, and would not deny) plus a repo
# `[branch "feature/x"] merge = refs/heads/main` still denies (rc 2, `via push.default=upstream in
# your global git config` — the FIRST record in accumulation order, not git's own last-wins
# resolution). None of these three is widened again by also reaching a RESOLVED `-C` segment: the
# same global candidates are read identically for every checkout resolved (session or target, from
# the environment, never the untrusted command string — see `resolve_repo()`'s config-candidate
# loop) — measured: a session `cwd` resolving to NO repo at all, `-C <target>` resolving to an
# ordinary repo with no config of its own, and a denying `remote.<name>.push` record in
# `$HOME/.gitconfig` alone, still denies (rc 2) via the `-C` TARGET's own resolution. This is a
# widening of WHICH checkouts see the three classes above, not a fourth class of its own — each
# route it exposes on a resolved `-C` target is already counted above.
#
# `$GIT_CONFIG_GLOBAL` set to exactly `/dev/null` — git's own documented "disable the global
# config" idiom — is excluded from this hook's own read naturally, not by any special-cased check:
# measured directly, `[ -f /dev/null ]` is false (a character device is not a regular file), so the
# existing `[ -f ]` guard on every config candidate already skips it, the same way it skips any
# other non-regular-file path.
#
# Documented under-blocking classes (evasions, named rather than hidden): `$(which git) push`
# (the literal `git` token is never in command position); `sudo -u foo git push` (the argument to
# `-u` becomes the resolved command word, not `git`); interpreter indirection outside
# PREFIX_WORDS; a two-token global option NOT in GIT_GLOBAL_OPTS_WITH_VALUE that itself takes a
# separate value, e.g. `git --foo bar push origin main` (the unlisted `--foo` is skipped alone,
# and its separate value `bar` is then mistaken for the subcommand, so the real `push` token past
# it is never reached — this hook opines "no opinion" on the whole segment, not a deny; an
# ATTACHED `--opt=value` global option such as `--git-dir=<path>` does NOT evade this way: the
# generic single-dash-token skip consumes it whole in one step and the subcommand still resolves
# to `push` correctly — what `--git-dir=<path>` always evades, and what an UNRESOLVED `-C` value
# also evades (see below), is WHICH repo gets resolved); a CR *inside* a raw-stdin fast-path
# literal, e.g. `git
# pu<CR>sh origin main` (measured: rc 0) — a conforming JSON writer escapes an embedded `\r` as the
# two characters `\`+`r`, so the raw stdin substring `push` never appears intact and fast path 1
# (below) exits before the #270 CR strip ever runs, regardless of the strip's own correctness; the
# resulting command cannot execute as a real `git push` either, so this is documented, not fixed
# (see the fast-path comment below); `nice -n 5 git push origin main` (the same class
# as the `sudo -u foo` bullet above — `nice`'s option value `5` becomes the resolved command word,
# not `git`); since #398, `git PUSH origin main` — the command word is case-folded (so `GIT push
# origin main` IS caught), but the subcommand comparison (`subcmd == "push"` in emit_segment()
# below) stays exact, out of scope per this issue's decision, so an uppercase or mixed-case
# subcommand is never recognised as a push and this hook opines "no opinion" on the whole segment;
# whether a given git build would itself execute `PUSH` as `push` on a case-insensitive filesystem
# is UNVERIFIED here. Since #269 narrowed this next class to its residuals (see the "Repo resolution"
# paragraph above for what a `-C` value IS now resolved against), a `git -C <path> push` into a
# repo whose default branch differs from the session's is STILL judged only against the session's
# own facts in every one of these shapes — each measured directly, exact command -> rc, session on
# `main` throughout: a `-C` value failing PATH_ERE, including the issue's own literal example,
# `git -C ../other-checkout push origin develop` -> rc 0 (filed as a follow-up alongside this
# change — the issue's own headline shape is outside the bound the maintainer's decision drew); the
# attached form, `git -C../other-checkout-wt-1 push origin develop` -> rc 0 (same follow-up); two or
# more `-C` tokens, `git -C ../a-wt-1 -C ../b-wt-1 push origin develop` -> rc 0; `--git-dir=<path>`/
# `--work-tree=<path>`, neither ever resolved (same follow-up); a PATH_ERE-matching directory
# holding no `.git` of its own — git itself walks upward from a real `-C`, this hook does not
# (filed as a second, separate follow-up) — measured: `git -C ../plain-wt-1 push origin main`,
# `../plain-wt-1` an ordinary, `.git`-less directory -> rc 2 (denies via the SESSION's own facts,
# unaffected by the unresolvable target); and a `-C` value containing a space: this hook's plain
# whitespace tokenizer (unlike git-c-guard.sh's quote-aware lexer) splits the quoted value at
# the interior space and captures only its first fragment as the `-C` path. Whether the rest of
# the segment is then still recognised as a push is decided by ONE piece of code — the
# subcommand search in `emit_segment()` (the awk `while (j <= ntok)` loop that assigns
# `subcmd`) — applied to the RAW whitespace fragments that follow, with any quote characters
# still glued to them: an empty fragment is skipped; a fragment that exactly equals a
# GIT_GLOBAL_OPTS_WITH_VALUE name (so `-c` does, but `-c"` with the closing quote glued on does
# not) is consumed together with the fragment after it; any other fragment beginning with `-`
# is skipped; the first fragment left standing is the subcommand candidate, and the segment is
# recognised iff `normalize()` of it — quote characters and backslashes removed, then the last
# `/`-separated component — is exactly `push`. Nothing about the captured `-C` fragment itself
# enters that decision; whether that fragment is then RESOLVED is decided separately, by
# PATH_ERE and the exactly-one-`-C` rule. The rows below are every shape measured against this
# script (session default `main` on `claude/17-a`; `../a-wt-1` and `../b-wt-1`, sibling repos
# whose own defaults are `trunk` and `release`; `../plain-dir`, an ordinary, `.git`-less
# directory with no `-wt-<n>` suffix); each row's outcome follows from that one rule, and no
# rule beyond it is claimed for shapes not listed here:
#
# (a) `git -C "../a-wt-1 -x" push origin trunk` -> rc 2 — `-x"` begins with `-` and is skipped,
# the real `push` is the candidate, the segment is recognised; the captured fragment
# (`../a-wt-1`) satisfies PATH_ERE and is resolved, so the deny names `../a-wt-1`'s own default
# — a directory OTHER than the one git would actually `-C` into (the literal, on-disk
# `../a-wt-1 -x`): a mis-resolution, not a containment breach (see the containment paragraph
# above). Controls: the same command with a non-matching first fragment (`../plain-dir -x`)
# -> rc 0, and the session alone pushing to `trunk` with no `-C` -> rc 0, isolating that the
# deny comes from the fragment's own resolution.
# (b) `git -C "../a-wt-1 foo" push origin main` -> rc 0 — `foo"` normalises to `foo`, not
# `push`: the segment is dropped as unrecognised, nothing is resolved, and a push whose
# destination is literally the session's own default branch gets no opinion (control: the
# session alone pushing to `main` -> rc 2).
# (c) `git -C "../plain-dir -x" push origin main` -> rc 2 — recognised exactly as (a); the
# captured fragment fails PATH_ERE so nothing is resolved, and the segment is judged against
# the session's own facts (`main`).
# (d) `git -C "../repo with space-wt-1" push origin develop` -> rc 0 — `with` normalises to
# `with`: hidden, the same way as (b).
# (e) `git -C "../a-wt-1 push" push origin trunk` -> rc 2 — `push"` normalises to `push`, so
# the REMAINDER is taken as the subcommand and the segment is recognised; the real `push`
# keyword one token later then lands in the segment's remote slot, which `evaluate_segment()`
# never evaluates as a destination, and `trunk` is still evaluated as a refspec; resolved via
# `../a-wt-1` as in (a). Control: `git -C "../a-wt-1 push" push origin main` -> rc 2.
# (f) `git -C "../a-wt-1 -c foo" push origin main` -> rc 2 — `-c` exactly matches a
# GIT_GLOBAL_OPTS_WITH_VALUE name, so it is consumed together with `foo"` and the real `push`
# is the candidate; recognised and resolved via `../a-wt-1`.
# (g) `git -C "../a-wt-1 -C ../b-wt-1" push origin main` -> rc 2 — the interior `-C` is
# consumed together with `../b-wt-1"` and counts as a second `-C`, so the segment is
# recognised but, by the exactly-one-`-C` rule, NOT resolved: judged against the session's
# own `main`.
# (h) `git -C "../a-wt-1 x/push" push origin main` -> rc 2 — `x/push"` normalises to its last
# `/`-component, `push`: recognised and resolved via `../a-wt-1`.
# (i) `git -C "../a-wt-1 -c" push origin main` -> rc 2 — `-c"` carries the glued closing quote,
# so it does NOT match the GIT_GLOBAL_OPTS_WITH_VALUE name and is merely skipped as a
# dash-prefixed fragment; the real `push` is the candidate; recognised and resolved.
# (j) four more: `git -C "../a-wt-1 push -x" push origin trunk` -> rc 2 (as (e)); `git -C
# "../a-wt-1 pull" push origin main` -> rc 0 (as (b)); `git -C "../a-wt-1 push origin main"`
# with nothing after the closing quote -> rc 2 (as (e)); `git -C "../a-wt-1 --foo=bar baz"
# push origin main` -> rc 0 (`--foo=bar` skipped, `baz"` is the candidate — as (b)).
#
# Rows (b), (d) and the two rc-0 shapes in (j) are measured instances of a residual class that
# PRE-DATES #269 (the plain whitespace split that produces it is older than this issue and
# independent of whether `-C` resolution exists at all): a quoted `-C` value containing a
# space can hide the whole segment from this hook, including a push whose destination is
# literally the session's own default branch. Rows (a), (e), (f), (h), (i) and the two rc-2
# shapes in (j) share the one resolve-a-different-directory outcome that is new to this
# change, and it is a mis-resolution, not a containment breach: the facts applied still belong
# to a directory this hook itself derived and read under the same predicate, never an
# attacker-arbitrary one, but they are not necessarily the facts of the directory the push
# actually executes in (see the containment paragraph above for the qualification this
# residual class requires). Since #268 closed the repo-local
# `push.default`/`remote.<name>.push` class named here in every prior version of this file, and
# #290 closed the GLOBAL half of that same class (`$GIT_CONFIG_GLOBAL`, `$XDG_CONFIG_HOME/git/config`
# or its default, `$HOME/.gitconfig`), the residual config surface left open is: a SYSTEM git
# config (`/etc/gitconfig`, or a path named by `$GIT_CONFIG_SYSTEM`, unless `$GIT_CONFIG_NOSYSTEM`
# is set) setting either key (filed as a follow-up alongside this change); the env-injected
# `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>` config form (never consulted);
# `include`/`includeIf` directives and `config.worktree` (`extensions.worktreeConfig`) inside ANY
# of the four files this hook DOES read (repo-local or global), neither followed (filed as a
# second, separate follow-up); the legacy dotted `[remote.origin]` section spelling (only
# the quoted `[remote "origin"]` form is parsed); backslash-continued or backslash-escaped config
# values; a key on the same line as its own section header, e.g. `[remote "origin"] push =
# HEAD:main` (the parser reads only the section declaration on such a line, never any text after
# the closing `]`); and a remote/branch SUBSECTION NAME itself containing an unquoted `#`/`;`
# (e.g. `[remote "back#up"]`) loses its whole section — the header line is truncated before its
# own closing `"]`, so it matches none of the three named section patterns, falls through to the
# generic "other" section, and every key inside it (including a denying `push =` line) is silently
# never captured — measured: rc 0. This is a tripwire, not a sandbox — branch protection on the
# default branch remains the real backstop, exactly as hooks/git-c-guard.sh and
# hooks/agent-boundary.sh already document for their own scopes.
#
# Contract: read the PreToolUse hook JSON on stdin; print nothing and exit 0 ("no opinion") unless
# the call is a Bash `git push` whose resolved destination is the default branch (or the
# unconditional `main`/`master` fallback), in which case print exactly one reason line to stderr
# and exit 2 ("deny"); stdout is always empty. Wired in hooks/hooks.json via
# `${CLAUDE_PLUGIN_ROOT}`, with no `if` gate — an `if` filter matches only `tool_input.command`
# constituents after composite splitting and leading-assignment stripping, so it cannot see a
# `git -C <wt> push …`, `env git push …`, or `bash -c "git push …"` form; any `if` here would
# silence this hook for exactly the commands it exists to catch (same reasoning as
# hooks/agent-boundary.sh's own registration — see hooks/hooks.json's `.description`).
set -uo pipefail
set -f  # noglob: untrusted refspec tokens are word-split unquoted below (e.g. in evaluate_segment
        # and the token-array builders); a token shaped like "*:main" must never glob-expand
        # against files in $PWD or a resolved repo directory.

# --- vocabulary ----------------------------------------------------------------------------
# Grep-extractable single-line KEY="value" declarations (the 2.5/4.36-4.39 idiom) — kept on their
# own lines with this exact shape so dev/selfcheck.sh's assertion 4.40 can extract them
# mechanically.
PUSH_DEFAULT_BRANCH_FALLBACK="main master"
# Since #398, byte-identical to hooks/agent-boundary.sh's own PREFIX_WORDS (see that file's
# vocabulary comment for the full reasoning): the trailing words above `dash` are shell reserved
# words that can directly precede a command in the same segment (`if true; then git push origin
# main; fi`, `! git push origin main`), sharing the ordinary prefix-word skip below.
PREFIX_WORDS="env command builtin exec sudo nohup time nice stdbuf xargs bash sh zsh ksh dash if then elif else do while until ! coproc"
GIT_GLOBAL_OPTS_WITH_VALUE="-c -C --git-dir --work-tree --namespace --config-env --exec-path"
# #269: byte-identical to hooks/git-c-guard.sh's own PATH_ERE (that script's twin declaration,
# a few lines above its own GIT_C_SUBCOMMANDS) — dev/selfcheck.sh's assertion 4.42 extracts both
# mechanically and FAILs the gate if they ever drift apart. Used below (is_c_target_path()) to
# decide whether a push segment's `git -C <path>` value is trusted enough to resolve against —
# see this file's header "Repo resolution" paragraph for the containment argument.
PATH_ERE='^([A-Za-z]:/|/|\.\./)([A-Za-z0-9._ +-]+/)*[A-Za-z0-9._+-]+-wt-[0-9]+/?$'
PUSH_OPTS_WITH_VALUE="-o --push-option --repo --receive-pack --exec"
PUSH_ALL_REFS_OPTS="--all --mirror"
PUSH_DENY_STEM="trail-blazer-flow push guard:"

# is_c_target_path PATH (#269) — true iff PATH satisfies the shared PATH_ERE predicate above.
# Here-string, not a `printf` writer piped into `grep`'s quiet mode (#255): that early-exit
# reader exits on its first match, which can send the printf writer SIGPIPE and, under this
# file's `set -uo pipefail`, turn a genuine match into a reported pipeline failure — a
# here-string has no writer process, so no SIGPIPE is possible (hooks/git-c-guard.sh's own
# validate_segment() use of PATH_ERE is the precedent this copies).
is_c_target_path() { grep -qE "$PATH_ERE" <<<"$1"; }

input="$(cat)"

# --- fast paths ------------------------------------------------------------------------------
# Both are pure performance optimisations, each semantics-preserving with the check it stands in
# for below except for a command word/subcommand split by quote, backslash, or carriage-return
# characters — the same documented, quote-blind limit hooks/agent-boundary.sh's fast paths carry.
# The #270 CR strip below (after the jq extraction) fixes an unstripped `\r` for every command
# that reaches the tokenizer, but a CR *inside* the literal these fast paths scan (a raw stdin
# substring like `pu<CR>sh`, where a conforming JSON writer has already escaped the `\r`) still
# exits here, before the strip ever runs — see this file's header "Documented under-blocking
# classes" for that residual case. A miss on either fast path always means "this call is out of
# scope for this hook", which is also what the slower checks below it would conclude. Since #398,
# the second fast path (below) case-folds `git` — `*push*` (the first fast path, immediately below)
# stays case-sensitive: the push SUBCOMMAND itself is never case-folded (see this file's header
# "Documented under-blocking classes" for the `git PUSH …` residual this leaves), so a
# case-sensitive `*push*` never rejects a call the slower tokenizer would still recognise.
case "$input" in
  *push*) : ;;
  *) exit 0 ;;
esac
case "$input" in
  *[Gg][Ii][Tt]*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

tool_name="$(printf '%s' "$input" | jq -r '.tool_name? // empty' 2>/dev/null)"
[ "$tool_name" = "Bash" ] || exit 0

# Never opine during a planning turn — same rationale as the other two hooks: a denial during
# plan mode could read as though the command had actually been attempted.
pmode="$(printf '%s' "$input" | jq -r '.permission_mode? // empty' 2>/dev/null)"
[ "$pmode" != "plan" ] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command? // empty' 2>/dev/null)"

# A CRLF-carrying transport (Git Bash, a CRLF-translating layer) can deliver a command whose
# tokens carry a trailing \r; every comparison below is an exact match, so an unstripped \r
# made `git push origin main\r` no-opinion (#270). Stripped here, once, before the tokenizer —
# not inside normalize(), which the refspec destination tokens never pass through (they take
# strip_quotes() at line ~241 and the Bash membership tests, is_deny_member() at line ~316,
# below). Pure parameter expansion: no new process, so this hook still executes nothing (see
# this file's header).
cr=$'\r'
cmd="${cmd//$cr/}"

[ -n "$cmd" ] || exit 0

# cwd is a documented PreToolUse stdin field (Claude Code's hooks reference lists it in the
# common-fields table and in the PreToolUse Bash example); its absence here is not an exit —
# see the repo-resolution step below, which falls back to $PWD and, ultimately, to the
# unconditional PUSH_DEFAULT_BRANCH_FALLBACK deny set.
cwd="$(printf '%s' "$input" | jq -r '.cwd? // empty' 2>/dev/null)"

# --- the tokenizer (POSIX awk, inlined) -------------------------------------------------------
# See this file's header for the full cross-reference to hooks/agent-boundary.sh's twin scan.
# Emits one "PUSH<TAB><space-joined remaining tokens>" line per push segment found; nothing for
# any other segment. Processes $cmd one input line (awk record) at a time — the same deliberate,
# documented false-positive class agent-boundary.sh's header explains (a heredoc line that starts
# with "git push" is scanned as its own segment).
scan_out="$(printf '%s\n' "$cmd" | awk -v prefix_words="$PREFIX_WORDS" -v gopts="$GIT_GLOBAL_OPTS_WITH_VALUE" '
BEGIN {
  sq = sprintf("%c", 39)
  n = split(prefix_words, pwarr, " ")
  for (i = 1; i <= n; i++) prefix_set[pwarr[i]] = 1
  ng = split(gopts, goarr, " ")
  for (i = 1; i <= ng; i++) gopt_set[goarr[i]] = 1
}
function normalize(tok,    t, parts, np) {
  t = tok
  gsub(sq, "", t)
  gsub(/"/, "", t)
  gsub(/\\/, "", t)
  np = split(t, parts, "/")
  return parts[np]
}
function strip_quotes(tok,    t) {
  t = tok
  gsub(sq, "", t)
  gsub(/"/, "", t)
  gsub(/\\/, "", t)
  return t
}
function emit_segment(seg,    ntok, toks, idx, tok, norm, saw_prefix, cmdword, j, subcmd, rest, sep, cpath, ccount) {
  ntok = split(seg, toks, /[ \t]+/)
  idx = 1
  saw_prefix = 0
  cmdword = ""
  while (idx <= ntok) {
    tok = toks[idx]
    if (tok == "") { idx++; continue }
    if (match(tok, /^[A-Za-z_][A-Za-z0-9_]*=/) == 1) { idx++; continue }
    norm = tolower(normalize(tok))
    if (norm in prefix_set) { saw_prefix = 1; idx++; continue }
    if (saw_prefix && substr(tok, 1, 1) == "-") { idx++; continue }
    cmdword = norm
    idx++
    break
  }
  if (cmdword != "git") return
  j = idx
  subcmd = ""
  cpath = ""
  ccount = 0
  while (j <= ntok) {
    tok = toks[j]
    if (tok == "") { j++; continue }
    if (tok in gopt_set) {
      if (tok == "-C") { ccount++; cpath = strip_quotes(toks[j + 1]) }
      j += 2
      continue
    }
    if (substr(tok, 1, 1) == "-") { j++; continue }
    subcmd = normalize(tok)
    j++
    break
  }
  if (subcmd != "push") return
  rest = ""
  sep = ""
  while (j <= ntok) {
    tok = toks[j]
    if (tok != "") {
      rest = rest sep strip_quotes(tok)
      sep = " "
    }
    j++
  }
  print "PUSH\t" (ccount == 1 ? cpath : "") "\t" rest
}
{
  line = $0
  gsub(/[;&|(){}`]/, "\n", line)
  gsub(/[<>]/, " ", line)
  nseg = split(line, segs, /\n/)
  for (s = 1; s <= nseg; s++) emit_segment(segs[s])
}
')"

# --- repo resolution (reads only, never executes) ---------------------------------------------
# cfg_trim VALUE — strips leading/trailing [:space:] (bash 3.2-safe bracket-class case patterns;
# no ${var,,}, no declare -A, no tr/sed). Used only by the #268 config parser below; defined here
# (rather than alongside is_deny_member()/refspec_dest() further down) because it must exist
# before the config-parsing loop inside the "if [ -n "$gitdir" ]" block below runs — earlier in
# this file's execution order than those two.
cfg_trim() {
  local s="$1"
  while :; do
    case "$s" in
      [[:space:]]*) s="${s#?}" ;;
      *) break ;;
    esac
  done
  while :; do
    case "$s" in
      *[[:space:]]) s="${s%?}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$s"
}

resolve_cwd="${cwd:-$PWD}"
[ -n "$resolve_cwd" ] || resolve_cwd="."

# #268: cfg_tab is the tab byte cfg_push_lines records use as a field separator inside
# resolve_repo() below; #269 hoists it to file scope (computed once, not per call) since
# resolve_repo() is now called once for the session checkout and, per resolved "-C" segment,
# once more.
cfg_tab="$(printf '\t')"

# resolve_repo START_DIR MAX_DEPTH (#269) — walks upward from START_DIR, at most MAX_DEPTH parent
# directories, looking for START_DIR/.git; resets gitdir/default_branch/current_branch/cfg_* on
# every call so a second call (the "-C" route, below) never leaks a prior call's state. Sets the
# plain (non-local) globals gitdir, default_branch, current_branch, cfg_push_lines,
# cfg_push_defaults, cfg_branch_merge for the caller to read afterward — the same "set a plain
# global, caller reads it after the call returns" idiom evaluate_segment() below already uses for
# __deny_dest/__deny_kind/__deny_via. Called once for the session checkout (MAX_DEPTH 64, just
# below) and, per push segment whose "-C" value passes is_c_target_path(), once more with
# MAX_DEPTH 1 (see apply_c_target() further down) — examining the named directory itself only,
# never walking upward the way git itself would from a real "-C" (a documented residual class,
# see this file's header). The MAX_DEPTH guard below makes the untrusted "-C" path passed on that
# second call unreachable by dirname's argv, and therefore by any process's argv at all. Since
# #290, EVERY call (session and "-C") also unions in the GLOBAL config candidates below — the
# environment is read identically regardless of MAX_DEPTH, so a resolved "-C" segment sees the
# same global routes the session does (see "Cross-feature" in dev/hook-tests.sh's push mutation
# table for the fixture pinning this).
resolve_repo() {
  dir="$1"
  gitdir=""
  depth=0
  while [ "$depth" -lt "$2" ]; do
    if [ -d "$dir/.git" ]; then
      gitdir="$dir/.git"
      break
    fi
    if [ -f "$dir/.git" ]; then
      gline=""
      IFS= read -r gline < "$dir/.git" 2>/dev/null || gline=""
      case "$gline" in
        "gitdir: "*)
          gp="${gline#gitdir: }"
          case "$gp" in
            /*) gitdir="$gp" ;;
            *) gitdir="$dir/$gp" ;;
          esac
          ;;
      esac
      break
    fi
    [ "$((depth + 1))" -lt "$2" ] || break
    parent="$(dirname "$dir" 2>/dev/null || printf '%s' "$dir")"
    [ "$parent" != "$dir" ] || break
    dir="$parent"
    depth=$((depth + 1))
  done

  default_branch=""
  current_branch=""
  # #268/#290: config-derived push routes, always initialized (even when $gitdir never resolves)
  # so config_deny() below can reference them unconditionally under this script's `set -uo
  # pipefail`. cfg_push_defaults (#290, was cfg_push_default) is a newline-separated LIST now,
  # not a scalar — see the config-candidate loop below for why.
  cfg_push_lines=""
  cfg_push_defaults=""
  cfg_branch_merge=""
  if [ -n "$gitdir" ]; then
    common="${gitdir%/worktrees/*}"
    ohf="$common/refs/remotes/origin/HEAD"
    if [ -f "$ohf" ]; then
      oline=""
      IFS= read -r oline < "$ohf" 2>/dev/null || oline=""
      case "$oline" in
        "ref: refs/remotes/origin/"*) default_branch="${oline#ref: refs/remotes/origin/}" ;;
      esac
    fi
    hf="$gitdir/HEAD"
    if [ -f "$hf" ]; then
      hline=""
      IFS= read -r hline < "$hf" 2>/dev/null || hline=""
      case "$hline" in
        "ref: refs/heads/"*) current_branch="${hline#ref: refs/heads/}" ;;
      esac
    fi

    # #290: config CANDIDATES, global routes first, this checkout's own repo-local config LAST —
    # never derived from the untrusted command string, only from the environment
    # ($GIT_CONFIG_GLOBAL, $XDG_CONFIG_HOME, $HOME) and $common above (every reference
    # ${VAR:-}-guarded under `set -uo pipefail`). Repo-local read last so a last-wins scalar
    # (cfg_branch_merge) resolves to the repo's own value on any conflict with a global file,
    # matching git's own unconditional deference to the repo config for that key; cfg_push_lines
    # and cfg_push_defaults both ACCUMULATE across every candidate regardless of order — a route
    # from any file can deny (the union stance #268 already took across remotes, now also across
    # files) — so this order only decides which route's label is named first when more than one
    # denies. $GIT_CONFIG_GLOBAL is UNIONED with (never a replacement for) the other two global
    # paths: real git reads only $GIT_CONFIG_GLOBAL, when it is set, in place of $HOME/.gitconfig;
    # this hook deliberately reads both, a documented over-block (see "Documented over-blocking
    # classes" above). See this file's header "Repo resolution" paragraph for the full reasoning
    # and "Documented under-blocking classes" for what stays unread ($GIT_CONFIG_SYSTEM/
    # /etc/gitconfig, include/includeIf, and the env-injected GIT_CONFIG_COUNT/GIT_CONFIG_KEY_<n>
    # forms — filed as follow-ups, not read here).
    xdg_cfg=""
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
      xdg_cfg="$XDG_CONFIG_HOME/git/config"
    elif [ -n "${HOME:-}" ]; then
      xdg_cfg="$HOME/.config/git/config"
    fi
    home_cfg=""
    [ -n "${HOME:-}" ] && home_cfg="$HOME/.gitconfig"

    # A SEPARATE carriage-return literal from $cr (declared above for the #270 command-string
    # strip): the push mutation table's M23 mutant deletes both of $cr's declaration and its
    # use, and a config parser referencing $cr here would blow up under `set -u` instead of
    # producing that mutant's documented, measured result. Declared once here (not per candidate
    # file below), since it is a fixed literal independent of which candidate is being parsed.
    cfg_cr=$'\r'
    while IFS= read -r cfgf; do
      [ -n "$cfgf" ] || continue
      [ -f "$cfgf" ] || continue
      # #290: exactly two source literals for the deny message below — this checkout's own
      # repo-local config is always named "$common/config" (never the resolved gitdir's own path,
      # for a worktree — the same common-dir rule the origin-HEAD symref read above already uses);
      # every OTHER candidate in the list below is a global path, named with one shared neutral
      # label regardless of which of the three it is (the deny message never needs to distinguish
      # among them).
      case "$cfgf" in
        "$common/config") cfg_src=".git/config" ;;
        *) cfg_src="your global git config" ;;
      esac
      cfg_section=""
      cfg_subsection=""
      while IFS= read -r cfgline || [ -n "$cfgline" ]; do
        cfgline="${cfgline//$cfg_cr/}"
        # Strip a trailing comment: whichever of '#'/';' appears first, with no quote-tracking --
        # git ref names MAY legitimately contain '#' or ';' (e.g. refs/heads/feat#123 and
        # refs/heads/feat;123 are both accepted by git itself), so this is a known, documented
        # parsing gap, not a safe assumption. See this file's header "Documented over-blocking
        # classes" (a destination value truncated at the marker) and "Documented under-blocking
        # classes" (a remote/branch subsection name truncated at the marker, losing its whole
        # section) for the two behaviour classes this creates.
        cfg_h="${cfgline%%#*}"
        cfg_s="${cfgline%%;*}"
        if [ "${#cfg_h}" -le "${#cfg_s}" ]; then cfgline="$cfg_h"; else cfgline="$cfg_s"; fi
        cfgline="$(cfg_trim "$cfgline")"
        [ -n "$cfgline" ] || continue
        case "$cfgline" in
          \[[Rr][Ee][Mm][Oo][Tt][Ee]\ \"*\"\]*)
            cfg_section="remote"
            cfg_subsection="${cfgline#*\"}"
            cfg_subsection="${cfg_subsection%%\"*}"
            continue
            ;;
          \[[Bb][Rr][Aa][Nn][Cc][Hh]\ \"*\"\]*)
            cfg_section="branch"
            cfg_subsection="${cfgline#*\"}"
            cfg_subsection="${cfg_subsection%%\"*}"
            continue
            ;;
          \[[Pp][Uu][Ss][Hh]\]*)
            cfg_section="push"
            cfg_subsection=""
            continue
            ;;
          \[*)
            cfg_section="other"
            cfg_subsection=""
            continue
            ;;
        esac
        case "$cfgline" in
          *=*)
            cfg_key="$(cfg_trim "${cfgline%%=*}")"
            cfg_val="$(cfg_trim "${cfgline#*=}")"
            ;;
          *) continue ;;
        esac
        case "$cfg_val" in
          \"*\") cfg_val="${cfg_val#\"}"; cfg_val="${cfg_val%\"}" ;;
        esac
        case "$cfg_section" in
          remote)
            case "$cfg_key" in
              [Pp][Uu][Ss][Hh])
                # #290 kickback finding F4: the source label goes FIRST (mirroring
                # cfg_push_defaults' own "${cfg_src}${cfg_tab}${cfg_val}" shape below), with the
                # configured value as the record's unbounded TAIL, never a bounded middle field —
                # a `push =` value containing a literal TAB byte is unusual but not impossible
                # (this config parser never rejects one), and a bounded middle field would let
                # such a value truncate at the embedded TAB and leak its own remainder into
                # config_deny()'s source-label field. cfg_subsection (the remote name) is read
                # from a quoted section header, never a value that could itself carry a raw TAB
                # in any fixture this file constructs.
                cfg_push_lines="${cfg_push_lines}${cfg_src}${cfg_tab}${cfg_subsection}${cfg_tab}${cfg_val}"$'\n'
                ;;
            esac
            ;;
          push)
            case "$cfg_key" in
              [Dd][Ee][Ff][Aa][Uu][Ll][Tt])
                cfg_push_defaults="${cfg_push_defaults}${cfg_src}${cfg_tab}${cfg_val}"$'\n'
                ;;
            esac
            ;;
          branch)
            if [ "$cfg_subsection" = "$current_branch" ]; then
              case "$cfg_key" in
                [Mm][Ee][Rr][Gg][Ee]) cfg_branch_merge="$cfg_val" ;;
              esac
            fi
            ;;
        esac
      done < "$cfgf"
    done <<CFGLIST
${GIT_CONFIG_GLOBAL:-}
$xdg_cfg
$home_cfg
$common/config
CFGLIST
  fi
}

resolve_repo "$resolve_cwd" 64
session_default_branch="$default_branch"
session_current_branch="$current_branch"
session_cfg_push_lines="$cfg_push_lines"
session_cfg_push_defaults="$cfg_push_defaults"
session_cfg_branch_merge="$cfg_branch_merge"

# apply_session_repo (#269) — (re)applies the session checkout's own resolved facts (captured
# above, right after the one and only session-scoped resolve_repo call) to
# default_branch/current_branch/cfg_*, and rebuilds deny_set/default_display exactly as the
# pre-#269 file-scope statements did. Called once per push segment (see the driver loop below),
# before that segment's own "-C" value (if any) is considered — so a segment with no "-C", or one
# whose "-C" value does not resolve, is judged exactly as every segment was before this issue.
apply_session_repo() {
  default_branch="$session_default_branch"
  current_branch="$session_current_branch"
  cfg_push_lines="$session_cfg_push_lines"
  cfg_push_defaults="$session_cfg_push_defaults"
  cfg_branch_merge="$session_cfg_branch_merge"
  deny_set="$PUSH_DEFAULT_BRANCH_FALLBACK"
  [ -n "$default_branch" ] && deny_set="$deny_set $default_branch"
  default_display="${default_branch:-fallback}"
}

# apply_c_target CPATH (#269) — CPATH is the tokenizer's emitted "-C" value for the segment about
# to be evaluated (empty unless the segment carried exactly one detached "-C <path>" token — see
# the tokenizer above), or the empty string. No-op when CPATH is empty or fails
# is_c_target_path() — the segment keeps exactly the session checkout's facts, just applied by
# apply_session_repo() above. Otherwise resolves CPATH at depth 1 only (the named directory
# itself — git itself walks upward from "-C"; this hook does not, a documented residual class)
# and, only if a gitdir actually resolved there, applies current_branch and the three cfg_*
# variables from the resolved checkout's own values (captured into resolved_* locals right after
# the resolve_repo call, then assigned explicitly below — each assignment its own statement, on
# purpose, so a future regression in just one of the four can be isolated) and rebuilds deny_set
# as the union of the always-in-force fallback, the SESSION checkout's own default branch, and the
# RESOLVED checkout's own default branch — never a pure replacement of the session's default: a
# second checkout that happens to lack its own refs/remotes/origin/HEAD (only `git clone` sets
# one) must not silently lose today's guard, which a replacement would do. default_display
# prefers the resolved checkout's own default branch. If no gitdir resolved at CPATH, this
# segment's facts are left exactly as apply_session_repo() above already set them (degrades to
# today's behaviour) — see the containment argument in this file's header for why an
# attacker-controlled CPATH can only ever mis-judge a push executed inside CPATH itself.
apply_c_target() {
  local cpath="$1" start
  local resolved_current resolved_cfg_push_lines resolved_cfg_push_defaults resolved_cfg_branch_merge
  local resolved_default
  [ -n "$cpath" ] || return 0
  is_c_target_path "$cpath" || return 0
  case "$cpath" in
    /*|[A-Za-z]:/*) start="$cpath" ;;
    *) start="$resolve_cwd/$cpath" ;;
  esac
  resolve_repo "$start" 1
  [ -n "$gitdir" ] || { apply_session_repo; return 0; }
  resolved_current="$current_branch"
  resolved_cfg_push_lines="$cfg_push_lines"
  resolved_cfg_push_defaults="$cfg_push_defaults"
  resolved_cfg_branch_merge="$cfg_branch_merge"
  resolved_default="$default_branch"
  current_branch="$resolved_current"
  cfg_push_lines="$resolved_cfg_push_lines"
  cfg_push_defaults="$resolved_cfg_push_defaults"
  cfg_branch_merge="$resolved_cfg_branch_merge"
  deny_set="$PUSH_DEFAULT_BRANCH_FALLBACK"
  [ -n "$session_default_branch" ] && deny_set="$deny_set $session_default_branch"
  [ -n "$resolved_default" ] && deny_set="$deny_set $resolved_default"
  default_display="${resolved_default:-$session_default_branch}"
  [ -n "$default_display" ] || default_display="fallback"
}

# --- verdict helpers -------------------------------------------------------------------------
is_deny_member() {
  case " $deny_set " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# refspec_dest TOKEN — prints the branch-name destination TOKEN resolves to, or empty if TOKEN
# is not a branch destination at all (a tag/note ref, or an unresolvable HEAD/@).
refspec_dest() {
  local tok="$1" dest
  case "$tok" in
    +*) tok="${tok#+}" ;;
  esac
  case "$tok" in
    *:*) dest="${tok#*:}" ;;
    *) dest="$tok" ;;
  esac
  case "$dest" in
    HEAD|@) dest="$current_branch" ;;
  esac
  case "$dest" in
    refs/heads/*) dest="${dest#refs/heads/}" ;;
    refs/*) dest="" ;;
  esac
  printf '%s' "$dest"
}

# config_deny SCOPE_REMOTE — evaluates the #268/#290 config-derived push routes
# (remote.<name>.push, push.default) captured by the repo-resolution parse above, from every
# candidate file that was actually read (repo-local and global); on a deny, sets $__deny_dest/
# $__deny_kind ("config" or "configall")/$__deny_via/$__deny_src (#290 — the two-literal source
# label, ".git/config" or "your global git config") the same way evaluate_segment's other checks
# do (plain, non-"local" assignments, so they escape this function exactly like $__deny_dest/
# $__deny_kind already do). SCOPE_REMOTE is the single non-option token at n==1, or empty at
# n==0 (a bare push): at n==0 every remote.<name>.push record is considered regardless of remote
# — deliberately over-broad, the RESOLVED union/fail-toward-deny default (see this file's
# header) — while at n==1 only records whose recorded remote name equals SCOPE_REMOTE exactly are
# considered. A configured destination containing "*" (after the same refspec_dest() resolution
# every other route uses) denies unconditionally, the same reasoning as PUSH_ALL_REFS_OPTS above.
# The push.default route is evaluated UNCONDITIONALLY alongside the remote.<name>.push route (the
# union decision again — this hook does not model git's own precedence, where push.default is
# consulted only when the applicable remote has no push refspec): "upstream"/"tracking" resolves
# via the current branch's recorded "merge" ref; "matching" denies unconditionally (same
# reasoning as the wildcard case); "current"/"simple"/"nothing"/absent/unrecognised add no route
# here at all (today's current-branch check, above, is the only thing that can still deny). #290:
# cfg_push_defaults is now a LIST (one record per parsed "[push] default = ..." line, across every
# candidate file, each prefixed with its own source label) — EVERY value is evaluated, not just
# the last one seen, so a benign value in one file never masks a denying value in another; the
# first record whose value denies wins (its own source label is what $__deny_src names).
config_deny() {
  local scope="$1" rec sub refspec src rest dest
  local pdrec pdsrc pdval
  if [ -n "$cfg_push_lines" ]; then
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      # #290 kickback finding F4: src is the BOUNDED first field (never a value that could
      # itself carry a raw TAB — see the record-building comment above); refspec is the
      # UNBOUNDED tail, so a configured value containing a literal TAB stays intact here instead
      # of truncating and leaking its own remainder into $src.
      src="${rec%%"$cfg_tab"*}"
      rest="${rec#*"$cfg_tab"}"
      sub="${rest%%"$cfg_tab"*}"
      refspec="${rest#*"$cfg_tab"}"
      if [ -n "$scope" ] && [ "$sub" != "$scope" ]; then
        continue
      fi
      dest="$(refspec_dest "$refspec")"
      case "$dest" in
        *'*'*)
          __deny_dest="$refspec"; __deny_kind="configall"; __deny_via="remote.$sub.push"; __deny_src="$src"
          return
          ;;
      esac
      if [ -n "$dest" ] && is_deny_member "$dest"; then
        __deny_dest="$dest"; __deny_kind="config"; __deny_via="remote.$sub.push"; __deny_src="$src"
        return
      fi
    done <<CFGEOF
$cfg_push_lines
CFGEOF
  fi
  if [ -n "$cfg_push_defaults" ]; then
    while IFS= read -r pdrec; do
      [ -n "$pdrec" ] || continue
      pdsrc="${pdrec%%"$cfg_tab"*}"
      pdval="${pdrec#*"$cfg_tab"}"
      case "$pdval" in
        [Uu][Pp][Ss][Tt][Rr][Ee][Aa][Mm]|[Tt][Rr][Aa][Cc][Kk][Ii][Nn][Gg])
          dest="$(refspec_dest "$cfg_branch_merge")"
          if [ -n "$dest" ] && is_deny_member "$dest"; then
            __deny_dest="$dest"; __deny_kind="config"; __deny_via="push.default=$pdval"; __deny_src="$pdsrc"
            return
          fi
          ;;
        [Mm][Aa][Tt][Cc][Hh][Ii][Nn][Gg])
          __deny_dest="$pdval"; __deny_kind="configall"; __deny_via="push.default=$pdval"; __deny_src="$pdsrc"
          return
          ;;
      esac
    done <<CFGEOF
$cfg_push_defaults
CFGEOF
  fi
}

# evaluate_segment REST — REST is one push segment's remaining tokens (space-joined, already
# quote/backslash-stripped by the tokenizer above). Sets $__deny_dest (non-empty on deny) and
# $__deny_kind ("allrefs" or "dest"). Builds its own token array from the REST string rather than
# receiving one as "$@"/an array, so an empty REST (a bare `git push`) never requires expanding a
# zero-length array with "${arr[@]}" — under bash 3.2's `set -u`, expanding an empty array that
# way raises "unbound variable" (measured on this machine's /bin/bash 3.2.57); building the array
# from a string via `for t in $rest` has no such failure mode, even when $rest is empty.
evaluate_segment() {
  __deny_dest=""
  __deny_kind=""
  __deny_via=""
  __deny_src=""
  local rest="$1"
  local toks
  toks=()
  local t
  for t in $rest; do toks+=("$t"); done
  local ntok="${#toks[@]}"
  local idx=0

  while [ "$idx" -lt "$ntok" ]; do
    t="${toks[$idx]}"
    case " $PUSH_ALL_REFS_OPTS " in
      *" $t "*) __deny_dest="$t"; __deny_kind="allrefs"; return ;;
    esac
    idx=$((idx + 1))
  done

  local nonopt
  nonopt=()
  idx=0
  while [ "$idx" -lt "$ntok" ]; do
    t="${toks[$idx]}"
    case " $PUSH_OPTS_WITH_VALUE " in
      *" $t "*) idx=$((idx + 2)); continue ;;
    esac
    case "$t" in
      -*) idx=$((idx + 1)); continue ;;
    esac
    nonopt+=("$t")
    idx=$((idx + 1))
  done
  local n="${#nonopt[@]}"

  if [ "$n" -le 1 ]; then
    local scope_remote=""
    if [ "$n" -eq 1 ]; then
      scope_remote="${nonopt[0]}"
      local d1
      d1="$(refspec_dest "${nonopt[0]}")"
      if [ -n "$d1" ] && is_deny_member "$d1"; then
        __deny_dest="$d1"; __deny_kind="dest"
        return
      fi
    fi
    if [ -n "$current_branch" ] && is_deny_member "$current_branch"; then
      __deny_dest="$current_branch"; __deny_kind="dest"
    fi
    # #268: config-derived routes (remote.<name>.push / push.default) are consulted ONLY here —
    # never for a segment carrying an explicit refspec (n >= 2, below) — and only when nothing
    # above has already denied, per the RESOLVED guard shape.
    [ -n "$__deny_dest" ] || config_deny "$scope_remote"
    return
  fi

  # n >= 2: nonopt[0] is the remote (never evaluated as a destination — it may be a URL
  # containing a colon, e.g. git@github.com:o/r.git); evaluate nonopt[1..] as refspecs.
  idx=1
  while [ "$idx" -lt "$n" ]; do
    local d
    d="$(refspec_dest "${nonopt[$idx]}")"
    if [ -n "$d" ] && is_deny_member "$d"; then
      __deny_dest="$d"; __deny_kind="dest"
      return
    fi
    idx=$((idx + 1))
  done
}

# --- drive the verdict over every push segment found (first offender decides) -----------------
TAB="$(printf '\t')"
deny_dest=""
deny_kind=""
deny_via=""
deny_src=""
while IFS= read -r line; do
  case "$line" in
    "PUSH$TAB"*) : ;;
    *) continue ;;
  esac
  seg_body="${line#PUSH$TAB}"
  seg_cpath="${seg_body%%"$TAB"*}"
  seg_rest="${seg_body#*"$TAB"}"
  apply_session_repo
  apply_c_target "$seg_cpath"
  evaluate_segment "$seg_rest"
  if [ -n "$__deny_dest" ]; then
    deny_dest="$__deny_dest"
    deny_kind="$__deny_kind"
    deny_via="$__deny_via"
    deny_src="$__deny_src"
    break
  fi
done <<EOF
$scan_out
EOF

if [ -n "$deny_dest" ]; then
  case "$deny_kind" in
    allrefs)
      printf '%s denies "%s" (pushes every ref, including the default branch: %s) — open a PR from a claude/<n>-<slug> branch instead; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" "$deny_dest" "$default_display" >&2
      ;;
    config)
      printf '%s denies pushing to "%s" (resolves to the default branch: %s, via %s in %s) — open a PR from a claude/<n>-<slug> branch instead; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" "$deny_dest" "$default_display" "$deny_via" "$deny_src" >&2
      ;;
    configall)
      printf '%s denies "%s" (pushes every matching branch, including the default branch: %s, via %s in %s) — open a PR from a claude/<n>-<slug> branch instead; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" "$deny_dest" "$default_display" "$deny_via" "$deny_src" >&2
      ;;
    *)
      printf '%s denies pushing to "%s" (resolves to the default branch: %s) — open a PR from a claude/<n>-<slug> branch instead; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" "$deny_dest" "$default_display" >&2
      ;;
  esac
  exit 2
fi

exit 0
