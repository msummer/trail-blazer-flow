#!/usr/bin/env bash
#
# push-guard.sh — plugin-shipped PreToolUse hook (#260) that mechanically narrows every Bash
# call's `git push` surface, main session included (unlike hooks/agent-boundary.sh, which only
# governs the implementer/verifier subagents): it denies (exit 2, one stderr line, empty stdout)
# any push whose resolved DESTINATION is the repo's default branch, ALSO denies a push segment
# whose target repository it cannot resolve at all (#292 — see "Fail-closed: an unresolvable push
# target" below), ALSO denies a push segment carrying git config supplied on the command line
# (#439 — see "Fail-closed: command-line git config" below), and says nothing (exit 0, empty
# stdout, empty stderr — "no opinion") about everything else, so the normal permission flow — a prompt, or a matching deny rule in
# templates/repo-settings.json, which always wins over this hook's decision — applies. This closes
# the gap #260 names: the settings deny entries
# `Bash(git push origin main:*)` / `Bash(git -C * push origin main*)` are prefix-matched and are
# bypassed by refspec spellings such as `HEAD:main`, `+HEAD:refs/heads/main`, or a remote other
# than `origin` — this hook parses the refspec instead of pattern-matching the raw command text.
#
# Enforces "deny a push whose destination is the default branch", "deny a push whose target
# repository cannot be resolved at all" (#292), and "deny a push segment carrying command-line git
# config" (#439); does NOT enforce an
# allow-list of `claude/<n>-<slug>` destinations (the Decision's other clause) — that would deny
# ordinary work (a `release/vX.Y.Z` branch, an annotated-tag push, any `git push origin
# feature/x` a human runs in ANY Claude Code session in a plugin-enabled repo, since this hook is
# plugin-wide, not harness-flow-scoped) for no matching safety gain, and a plugin that blocks
# ordinary pushes gets `disableAllHooks: true`, which would cost hooks/agent-boundary.sh's control
# too. The `claude/<n>-<slug>` shape is documented (see the README's "Safety model") as this
# harness's own convention, not mechanically required.
#
# Tokenizer: the POSIX-awk segment/token walker below is a near-twin of hooks/agent-boundary.sh's
# (see that script's "the scan" section) — same segment-break characters, same ADDITIVE standalone
# `]]` handling (an extra pass emitting only the FIRST segment of the text after each `]]`, DISJOINT
# from every other tail: that segment ends at whichever comes first, a real segment-break character
# OR the next standalone `]]`, up to DBRACKET_MAX matches per record, never a truncation of the
# segments the main split already produced, and never more than DBRACKET_MAX times the record length
# of work — a record carrying more `]]` than that denies unconditionally instead. A segment cut at a
# `]]` is passed to emit_segment() marked CUT, since the text on the far side of that `]]` was
# deliberately never read — see this file's own PUSH-class handling of a cut push for why), same
# normalize() (quote/backslash strip + basename), same empty-normalised-token
# skip in the command-word walk (and, in this file's own subcommand search below, the same
# empty-normalised-token skip there too), same repeat-until-exhausted PREFIX_WORDS skip (never
# once-only — a once-only skip is the M23 regression class agent-boundary.sh's own
# dev/hook-tests.sh table documents), same `repeat`-count skip, since #398 the same tolower() fold
# applied to the command word
# and to prefix-word matching (so `if true; then git push origin main; fi`, `! git push origin
# main`, and `GIT push origin main` all still resolve `git` as the command word — see PREFIX_WORDS'
# own declaration above for the added shell-keyword vocabulary), and, since #270, the same
# bash-native carriage-return strip
# of $cmd applied immediately after the jq extraction and before this script's own `[ -n "$cmd" ]`
# guard (see that same point in each file — a CRLF-carrying transport can otherwise deliver a
# command whose tokens carry a trailing `\r`, which every exact-match comparison below would miss).
# A future fix to either tokenizer's shared behaviour (segment breaking; the additive standalone
# `]]` handling; normalize(); the prefix-word skip, including the `repeat`-count skip; the
# empty-normalised-token skip; the command-word case fold; the CR strip) must be applied to BOTH
# files — see this repo's
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
# and `$HOME/.gitconfig`. Since #304/#305, a SYSTEM class is unioned in too, read FIRST (before the
# global candidates and this checkout's own repo-local config): `$GIT_CONFIG_SYSTEM` (when set and
# non-empty), the three PUSH_SYSTEM_CONFIG_PATHS candidates below, and the Apple CLT candidate
# (`PUSH_APPLE_CLT_CONFIG`) — all five skipped together when `$GIT_CONFIG_NOSYSTEM` holds a
# canonical true value (see `resolve_repo()`'s candidate loop for the exact parse; verified live
# that NOSYSTEM drops the CLT file's own scope too, so it sits INSIDE the same guard as the other
# three, not outside it). Every one of these paths is taken from the ENVIRONMENT (or this file's
# own fixed vocabulary), never from the untrusted command string, and read only when the checkout
# being resolved (session or a resolved `-C` target) has actually resolved a gitdir (see
# `resolve_repo()`'s config-candidate loop for the exact order: system candidates first, then
# global, then this checkout's own repo-local config last, so a last-wins scalar resolves to the
# repo's own value on any conflict). Since #304/#305, an `include`/`includeIf` directive found
# inside ANY parsed file (system, global, repo-local, a resolved `-C` target's, or another
# included file) is ALSO followed inline, at the point of the directive, in git's own order —
# `includeIf`'s own condition is ignored, so every conditional include is unconditionally followed
# (a union, over-blocking stance, like every other multi-file union this hook takes) — see
# `cfg_parse_file()` below for the resolution rules, the depth cap, and the cycle guard. Together,
# #268 (repo-local), #290 (global) and #304/#305 (system, plus includes inside all of them) close
# the global/system config class named in every version of this file before #290 — see "Documented
# under-blocking classes" below for what still stays unread (a system config at a path not on this
# static list, an unresolvable include form, and `config.worktree`) — the env-injected
# `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>` forms are no longer among them:
# since #439, a push segment carrying one of those is denied outright (see "Fail-closed:
# command-line git config" below), never silently read as config. A depth-0 top-level candidate is read whole, with
# no size, line-count, or line-length cap, never budgeted — a single pathological TOP-LEVEL file
# (very many lines, or a single very long line or whitespace run — `cfg_trim()`'s own pattern
# matching is not uniformly fast for the latter shape, see that function's header comment) simply
# degrades to Claude Code's 10s hook timeout (silence, the same fail-open every other resolution
# failure already has); this residual is unchanged and pre-existing, not introduced by this hook.
# An INCLUDED file (depth >= 1) is bounded on four independent axes instead: `CFG_INCLUDE_MAX_FOLLOWS`
# (below) caps how many times an include is ever followed across one whole `resolve_repo()` call;
# `CFG_INCLUDE_MAX_LINES` (below) separately caps the TOTAL lines read across every followed file
# combined, for that same whole call; `CFG_INCLUDE_MAX_LINE_CHARS` (below) caps a single line's own
# length, checked BEFORE comment-strip or trim ever run on it — closing the same
# long-line/whitespace-run cost `cfg_trim()`'s own header comment names, for included content
# specifically; and `CFG_INCLUDE_MAX_CHARS` (below) caps the TOTAL characters charged across every
# followed line combined, for that same whole call. Critically, the follow itself is gated on the
# CURRENT state of the line-count and character budgets too, not just the follow-count one: once
# EITHER runs out, no further include is ever OPENED at all — not even to attempt `[ -f ]` on it —
# so an adversarial tree cannot keep spending real time by having each of many still-available
# follows read just its own first line before its own per-line checks catch up. The one line this
# cannot prevent is the SINGLE line, in whichever file happens to already be open, whose own read
# is what drives the line-count or character budget past zero: that one line is read in full (the
# read loop's own builtin redirect takes a whole line at a time) before the check that follows it
# can break — grouped with the depth-0 top-level file's own long-line residual above as the same
# class: at most one very long line, read once per `resolve_repo()` call, not further processed.
# Every depth-0 top-level candidate is still always read in full, so none of these four axes can
# ever mask a pre-#304/#305 route WITHIN ONE RESOLUTION. All four axes, and the uncapped depth-0
# read itself, are bounded PER `resolve_repo()` call, never across the whole hook invocation: since
# #269 (below), this hook calls `resolve_repo()` once for the SESSION checkout and once MORE for
# every push segment whose own `-C` value resolves a checkout of its own, so a single command
# naming enough such resolved `-C` targets — each supplying its own at-cap-but-legal include
# content, or its own large top-level file — multiplies this same bounded work across resolutions
# exactly as it already multiplies the uncapped depth-0 read, and can still cross Claude Code's own
# hook timeout even though no single resolution ever exceeds its own caps: the same class of
# residual as the depth-0 long-line case above, reached a different way, not fixed here. See
# `cfg_parse_file()`'s own header comment for where every budget is spent. Any failure at
# any step leaves both branch values, and the config-derived variables, empty — never an error,
# never a non-zero exit from this hook on that account alone.
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
# today's guard by replacing the session's default outright). A `-C` value that satisfies the
# predicate but resolves to no gitdir of its own leaves the segment judged exactly as every segment
# was before #269 — solely against the session checkout (a documented residual, see "Under-blocking
# classes" below). A `-C` value that FAILS the predicate is judged against the session only when it
# is lexically the session checkout itself (#292) — see "Fail-closed: an unresolvable push target"
# further down for that one exception and for the other classes (the attached `-C<path>` form, two
# or more `-C` tokens, `--git-dir`/`--work-tree`, `GIT_DIR`/`GIT_WORK_TREE`/`GIT_COMMON_DIR`) this
# hook also denies outright. The containment argument for reading a
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
# (`$GIT_CONFIG_GLOBAL`, `$XDG_CONFIG_HOME/git/config` or its default, `$HOME/.gitconfig`), and,
# since #304/#305, the SYSTEM config candidates too (`$GIT_CONFIG_SYSTEM`, the three
# PUSH_SYSTEM_CONFIG_PATHS paths, and the Apple CLT path, together governed by
# `$GIT_CONFIG_NOSYSTEM`), are read from the environment identically for every checkout resolved
# (session or a resolved `-C` target), so a resolved segment still sees the SAME global and system
# routes the session would, independently re-derived from its own `resolve_repo()` call rather
# than literally inherited.
# The deny set for a segment whose `-C` value satisfies the predicate but resolves no gitdir of its
# own is `PUSH_DEFAULT_BRANCH_FALLBACK` (below) UNION the session's resolved default branch, if any
# — the fallback members are ALWAYS in force (even when a repo's real default branch resolves to
# something else), which is what lets this hook work with no `cwd`, no readable `.git`, or a
# predicate-matching `-C` value this hook does not resolve to a gitdir (see "Fail-closed: an
# unresolvable push target" below (#292) for every OTHER `-C`/`--git-dir`/`--work-tree`/`GIT_*`
# shape, which denies outright instead of degrading to this fallback set).
#
# Fail-closed: an unresolvable push target (#292). Every OTHER form a push segment's repository
# redirect can take — one this hook does not itself resolve to a checkout — is DENIED outright: a
# `-C` value that fails PATH_ERE above, UNLESS it is
# LEXICALLY the session checkout itself (see `is_session_checkout_path()` below: exactly `.`/`./`,
# the PreToolUse stdin `cwd`, or the session's own resolved root, each with or without one trailing
# `/`); the attached `-C<path>` form; two or more `-C` tokens in the same segment; `--git-dir` or
# `--work-tree` (detached or `=`-attached); and a `GIT_DIR=`, `GIT_WORK_TREE=`, or `GIT_COMMON_DIR=`
# assignment preceding `git` in the segment (the bare-prefix form, or the same behind an `env`
# prefix word). The deny reads nothing NEW from the untrusted value beyond what is already read
# above — GIT_REPO_OPTS/GIT_REPO_ENV_VARS membership, the PATH_ERE predicate, and the lexical
# session-equivalence check are all string comparisons; no filesystem path is read to reach this
# verdict. Over-blocking, deliberate: a `-C` into another checkout is denied whatever the push
# DESTINATION is, even one that is not that checkout's own default branch either; any
# `--git-dir`/`--work-tree`/`GIT_*` redirect is denied even when it points BACK at the session
# checkout itself (this hook never reads the redirected path to find out); and a literal `-C ..` or
# `-C "$PWD"` is denied (`..` is not lexically `.`, and a literal `$PWD` string token is not itself
# lexically equal to the session's own resolved cwd, even when the session actually runs from
# `$PWD`). Under-blocking, documented rather than fixed here (filed as a follow-up alongside this
# change): `cd <path> && git push` or a `pushd`/`popd` pair in the SAME Bash command, and `export
# GIT_DIR=…; git push` (or a bare `GIT_DIR=…;` segment) in a SEPARATE segment, are still judged
# against the session's own `cwd` — this hook's tokenizer tracks no `cd`/`pushd`/`export` state
# across segments. Whether git itself accepts an abbreviated long option (e.g. `--git-d <path>` for
# `--git-dir <path>`) is UNVERIFIED here; this hook does not recognise one, so such a form is judged
# as a plain unlisted dash token (the same "Documented under-blocking classes" sibling class below).
#
# Fail-closed: command-line git config (#439). A push segment carrying git config supplied ON THE
# COMMAND LINE — as an option before the subcommand (`-c <k=v>`/`-c<k=v>`, `--config-env <k=V>`/
# `--config-env=<k=V>`) or as a leading environment assignment, bare or behind `env`
# (`GIT_CONFIG_COUNT=`, `GIT_CONFIG_KEY_<n>=`, `GIT_CONFIG_VALUE_<n>=`, `GIT_CONFIG_PARAMETERS=`,
# `GIT_CONFIG_GLOBAL=`, or `GIT_CONFIG_SYSTEM=`) — is DENIED outright, whatever the key or the
# destination, e.g. `git -c core.pager=cat push origin feature/x` or `GIT_CONFIG_GLOBAL=/dev/null
# git push` deny exactly like `git -c remote.origin.push=HEAD:main push`: this hook never reads any
# of these forms (see the residual list below, before this change, and "Repo resolution" above for
# what it DOES read), so it cannot rule out that they redirect the push to the default branch.
# Detached `--config-env <arg>` and attached `-c<k=v>` are denied whether or not git itself accepts
# that exact spelling (UNVERIFIED here) — the same stance #292 already takes for attached
# `-C<path>`. The deny reads nothing from the untrusted value beyond what GIT_CMDCFG_OPTS/
# GIT_CMDCFG_ENV_VARS/GIT_CMDCFG_ENV_PREFIXES membership and a fixed-prefix `index()`/`substr()`
# check already need — no filesystem path is read, and the matched key/value/env-var name is never
# echoed in the deny message (a GIT_CONFIG_KEY_<n>/GIT_CONFIG_VALUE_<n> match stores a boolean
# only). Residuals this leaves, reasoned from the code but not run (see "Documented under-blocking
# classes" below and this issue's own follow-ups): cross-segment `export GIT_CONFIG_*=…; git push`
# or a bare `GIT_CONFIG_*=…;` segment (left to #433, which is expected to reuse these same three
# vocabulary constants); a git alias that expands to `push` (e.g. `git -c alias.p=push p origin
# main`); a quoted or escaped option spelling (`git "-c" k=v push`, which normalises the quoted
# option into the subcommand slot); a quoted value containing a space (splits the same way an ordinary `-C`/`GIT_DIR=` value does);
# and an inline `HOME=`/`XDG_CONFIG_HOME=` relocation of the global config this hook itself reads.
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
# string. Since #290, this hook ALSO reads a THIRD class of path: the global config candidates
# (`$GIT_CONFIG_GLOBAL`, `$XDG_CONFIG_HOME/git/config` or its default, `$HOME/.gitconfig`), and,
# since #304/#305, the SYSTEM config candidates alongside them (`$GIT_CONFIG_SYSTEM`, the three
# PUSH_SYSTEM_CONFIG_PATHS paths, the Apple CLT path, and the `TBF_PUSH_GUARD_SYSCONFIG_ROOT` test
# prefix that a fixture, never a real run, sets to keep those static paths off the host's own real
# system files) — every one of these comes from the ENVIRONMENT or this file's own fixed
# vocabulary, never from `cwd`/`$PWD` and never from the untrusted command string; an attacker who
# does not already control the session's environment cannot influence which global or system files
# this hook reads, and this class must not be conflated with the `-C`-derived containment argument
# above, which is specifically about paths taken from the command string. Since #304/#305, this
# hook ALSO reads a FOURTH class of path: an `include`/`includeIf` target taken from the CONTENT of
# a config file it already reads (system, global, repo-local, or another included file).
# Containment for this class rests on three points: the value is resolved with parameter expansion
# only (`~/` against `$HOME`, an absolute path as-is, anything else joined onto the including
# file's own directory with `${path%/*}`) — never `dirname`, `cd`, `realpath`, or any external
# command; the resolved value is only ever fed to a `[ -f ]`-guarded builtin redirect, the same way
# every other config candidate is read, so it can only be opened for reading, never written, and a
# FIFO or device is excluded exactly as elsewhere in this file; and content parsed out of an
# included file can only ADD a deny route (see `config_deny()`'s union stance) — the one exception,
# `branch.<current>.merge`, is a plain last-wins scalar across the WHOLE resolution, not just
# within one file's own inline order: the identical path can legitimately be read more than once
# in the same `resolve_repo()` call (a sibling include of the same target, or a later, unrelated
# top-level candidate that happens to name a path some earlier candidate's own include already
# pulled in — see `cfg_parse_file()`'s own header comment for why $cfg_seen does not, and must not,
# treat either of those as a cycle), and each independent read's own `merge` value can overwrite
# the last, in read order. That mirrors what git itself would do with the same files — the repo's
# own scope is always read, on its own, last — so it is
# not an evasion this hook introduces. The untrusted `-C` value itself is fed only to
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
# `git` (e.g. `Git push origin main`) — the same remedy; since the extended PREFIX_WORDS vocabulary
# also treats `-` and `repeat N` as prefix words and adds an `eval`/`trap`/`noglob`/`nocorrect`
# skip, a line or quote-blind segment starting `- git push origin main` (a markdown bullet in a
# heredoc body, a PR body, or a commit message — this applies in the MAIN session too, not only the
# implementer/verifier subagents, since this hook governs every session) or starting
# `eval`/`trap`/`noglob`/`nocorrect`/`repeat N` followed by `git push origin main` now also denies —
# the same Write/Edit-tools remedy; a command carrying more than DBRACKET_MAX standalone `]]`
# denies UNCONDITIONALLY, even when every one of them is genuinely benign and no `git push` is
# anywhere in the record — the fail-closed cost of the cap that keeps the additive `]]` pass from
# doing unbounded work; an additive `]]` tail that resolves to `git … push` but was cut short by a
# FOLLOWING standalone `]]` (not by a real break or the end of the record) denies UNCONDITIONALLY
# too, even when the destination on the far side of that `]]` (never read) would not itself have
# denied — the fail-closed cost of never reconnecting a push split across disjoint tails, which is
# what still catches `if [[ a ]] git push origin ]] main` without the additive pass re-reading the
# whole remaining record on every `]]` it finds. The identical cut-push deny also fires when a `git`
# tail is cut mid-subcommand-search (e.g. `git -C ]] push origin main`, where the search is still
# consuming `-C`'s own value token when the cut arrives): the subcommand is never resolved either
# way, and this hook cannot tell that unresolved case apart from a genuine, uncut `push` whose
# destination it simply has not reached yet; a remote literally named
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
# Since #304/#305, FOUR more over-blocking classes: `$GIT_CONFIG_SYSTEM` is UNIONED with (never a
# replacement for) the static PUSH_SYSTEM_CONFIG_PATHS candidates and the Apple CLT candidate —
# the same stance #290 already took for `$GIT_CONFIG_GLOBAL`; the static system candidates are
# read regardless of which git binary would actually run a given push, for example Homebrew's
# `/opt/homebrew/etc/gitconfig` even when Apple's `/usr/bin/git` is first on `$PATH`; `includeIf`'s
# own condition is ignored, so an include gated on a `gitdir:`/`onbranch:`/`hasconfig:` clause that
# would never actually match this checkout is still followed unconditionally; and a non-canonical
# true value such as `GIT_CONFIG_NOSYSTEM=2` does NOT disable the system read (only
# `1`/`true`/`yes`/`on`, case-insensitively, do) — measured: `GIT_CONFIG_NOSYSTEM=2` plus a denying
# `/etc/gitconfig` (under the test-only sysroot prefix) still denies (rc 2). None of these four is
# widened again by also reaching a RESOLVED `-C` segment, for the same reason the three #290
# classes above are not: the same system candidates are read identically for every checkout
# resolved.
#
# `$GIT_CONFIG_GLOBAL` set to exactly `/dev/null` — git's own documented "disable the global
# config" idiom — is excluded from this hook's own read naturally, not by any special-cased check:
# measured directly, `[ -f /dev/null ]` is false (a character device is not a regular file), so the
# existing `[ -f ]` guard on every config candidate already skips it, the same way it skips any
# other non-regular-file path.
#
# Documented under-blocking classes (evasions, named rather than hidden): `$(which git) push`
# (the literal `git` token is never in command position); `eval`/`trap` of a variable- or
# substitution-built payload (`eval "$c"`, `eval "$(printf …)"`) — the same class, since the literal
# `git`/`push` text is never in the string this tokenizer reads; a `repeat` count containing
# whitespace (`repeat "1 + 1" git push origin main` — the tokenizer skips exactly ONE token after
# `repeat`, so a quoted multi-word count is not fully consumed and its own remaining word, not
# `git`, is mistaken for the resolved command word); `sudo -u foo git push` (the argument to
# `-u` becomes the resolved command word, not `git`); interpreter indirection outside
# PREFIX_WORDS; a two-token global option NOT in GIT_GLOBAL_OPTS_WITH_VALUE that itself takes a
# separate value, e.g. `git --foo bar push origin main` (the unlisted `--foo` is skipped alone,
# and its separate value `bar` is then mistaken for the subcommand, so the real `push` token past
# it is never reached — this hook opines "no opinion" on the whole segment, not a deny; an
# ATTACHED `--opt=value` global option such as `--git-dir=<path>` does NOT evade this way: the
# generic single-dash-token skip consumes it whole in one step and the subcommand still resolves
# to `push` correctly — neither `--git-dir=<path>` nor an unresolved `-C` value evades WHICH repo
# gets resolved by staying silent about it: both deny outright instead (#292 — see "Fail-closed: an
# unresolvable push target" above); a CR *inside* a raw-stdin fast-path
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
# is UNVERIFIED here. Since #269 narrowed the next class to its residuals (see the "Repo resolution"
# paragraph above for what a `-C` value IS resolved against); of those residuals, only the two named
# just below remain open (#292 — see "Fail-closed: an unresolvable push target" above for the
# mechanism that denies the rest outright and the deliberate over-blocking it creates): a
# PATH_ERE-matching
# directory holding no `.git` of its own — git itself walks upward from a real `-C`, this hook does
# not (filed as a follow-up alongside this change) — measured: `git -C ../plain-wt-1 push origin
# main`, `../plain-wt-1` an ordinary, `.git`-less directory -> rc 2 (denies via the SESSION's own
# facts, unaffected by the unresolvable target); and a `-C` value containing a space: this hook's plain
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
# rule beyond it is claimed for shapes not listed here — except rows (f) and (i), where the #439
# command-line-config check (added after these rows were measured) also applies, and wins:
#
# (a) `git -C "../a-wt-1 -x" push origin trunk` -> rc 2 — `-x"` begins with `-` and is skipped,
# the real `push` is the candidate, the segment is recognised; the captured fragment
# (`../a-wt-1`) satisfies PATH_ERE and is resolved, so the deny names `../a-wt-1`'s own default
# — a directory OTHER than the one git would actually `-C` into (the literal, on-disk
# `../a-wt-1 -x`): a mis-resolution, not a containment breach (see the containment paragraph
# above). Controls: the same command with a non-matching first fragment (`../plain-dir -x`)
# -> rc 2 (denied as unresolved: `../plain-dir` fails PATH_ERE and is not lexically the session
# checkout either — see "Fail-closed: an unresolvable push target" above), and the session alone
# pushing to `trunk` with no `-C` -> rc 0, isolating that row (a)'s own deny comes from the
# fragment's own resolution, not from this control's separate unresolved-target route.
# (b) `git -C "../a-wt-1 foo" push origin main` -> rc 0 — `foo"` normalises to `foo`, not
# `push`: the segment is dropped as unrecognised, nothing is resolved, and a push whose
# destination is literally the session's own default branch gets no opinion (control: the
# session alone pushing to `main` -> rc 2).
# (c) `git -C "../plain-dir -x" push origin main` -> rc 2 — recognised exactly as (a); the
# captured fragment fails PATH_ERE and is not lexically the session checkout, so this denies as
# UNRESOLVED (`-C path outside the <name>-wt-<n> worktree shape`) unconditionally, regardless of
# what the destination is.
# (d) `git -C "../repo with space-wt-1" push origin develop` -> rc 0 — `with` normalises to
# `with`: hidden, the same way as (b).
# (e) `git -C "../a-wt-1 push" push origin trunk` -> rc 2 — `push"` normalises to `push`, so
# the REMAINDER is taken as the subcommand and the segment is recognised; the real `push`
# keyword one token later then lands in the segment's remote slot, which `evaluate_segment()`
# never evaluates as a destination, and `trunk` is still evaluated as a refspec; resolved via
# `../a-wt-1` as in (a). Control: `git -C "../a-wt-1 push" push origin main` -> rc 2.
# (f) `git -C "../a-wt-1 -c foo" push origin main` -> rc 2 — `-c` exactly matches a
# GIT_GLOBAL_OPTS_WITH_VALUE name, so it is consumed together with `foo"` and the real `push`
# is the candidate; recognised, but since #439 that same exact-`-c` token ALSO trips the
# command-line-config check first — this denies via #439 (command-line git config) BEFORE `-C`
# is ever resolved, never via `../a-wt-1`'s own facts.
# (g) `git -C "../a-wt-1 -C ../b-wt-1" push origin main` -> rc 2 — the interior `-C` is
# consumed together with `../b-wt-1"` and counts as a second `-C`, so the segment is recognised
# but, by the exactly-one-`-C` rule, NOT resolved; denies as UNRESOLVED (`more than one -C`).
# (h) `git -C "../a-wt-1 x/push" push origin main` -> rc 2 — `x/push"` normalises to its last
# `/`-component, `push`: recognised and resolved via `../a-wt-1`.
# (i) `git -C "../a-wt-1 -c" push origin main` -> rc 2 — `-c"` carries the glued closing quote,
# so it does NOT match the GIT_GLOBAL_OPTS_WITH_VALUE name and is merely skipped as a
# dash-prefixed fragment; the real `push` is the candidate; recognised, but since #439 the same
# `-c"` fragment starts with `-c` and trips the attached-`-c` command-line-config check — this
# denies via #439 (command-line git config) BEFORE `-C` is ever resolved, same as (f).
# (j) four more: `git -C "../a-wt-1 push -x" push origin trunk` -> rc 2 (as (e)); `git -C
# "../a-wt-1 pull" push origin main` -> rc 0 (as (b)); `git -C "../a-wt-1 push origin main"`
# with nothing after the closing quote -> rc 2 (as (e)); `git -C "../a-wt-1 --foo=bar baz"
# push origin main` -> rc 0 (`--foo=bar` skipped, `baz"` is the candidate — as (b)).
#
# Rows (b), (d) and the two rc-0 shapes in (j) are measured instances of a residual class that
# PRE-DATES #269 (the plain whitespace split that produces it is older than this issue and
# independent of whether `-C` resolution exists at all): a quoted `-C` value containing a
# space can hide the whole segment from this hook, including a push whose destination is
# literally the session's own default branch. Rows (a), (e), (h) and the two rc-2
# shapes in (j) share the one resolve-a-different-directory outcome that is new to this
# change, and it is a mis-resolution, not a containment breach: the facts applied still belong
# to a directory this hook itself derived and read under the same predicate, never an
# attacker-arbitrary one, but they are not necessarily the facts of the directory the push
# actually executes in (see the containment paragraph above for the qualification this
# residual class requires). Rows (f) and (i) no longer belong to that group: since #439, both
# deny via the command-line-config check before `-C` is ever resolved (see each row's own text
# above), so neither one reaches — or depends on — `../a-wt-1`'s own facts at all. Since #268 closed the repo-local
# `push.default`/`remote.<name>.push` class named here in every prior version of this file, #290
# closed the GLOBAL half of that same class (`$GIT_CONFIG_GLOBAL`, `$XDG_CONFIG_HOME/git/config`
# or its default, `$HOME/.gitconfig`), and #304/#305 closed most of the SYSTEM half plus
# `include`/`includeIf`, the residual config surface left open is: a system git config at a path
# NOT on the static PUSH_SYSTEM_CONFIG_PATHS/PUSH_APPLE_CLT_CONFIG list — a git built under
# another prefix, Xcode.app's `…/Contents/Developer/usr/share/git-core/gitconfig`, or a
# Git-for-Windows install path not visible as `/etc/gitconfig` (none of these is verified against
# a real install); an include form this hook cannot resolve — `%(prefix)/…`, `~user/…`, a path
# more than CFG_INCLUDE_MAX_DEPTH hops deep, a path that is already its own ANCESTOR in the current
# include chain (the seen-list dedupe — a termination guard for a self- or mutual-include cycle,
# scoped to one inclusion chain, never a whole-`resolve_repo()`-call history: a sibling include of
# the identical path, or a later, unrelated top-level candidate that happens to name a path some
# earlier candidate's own include already pulled in, is still read again, independently, exactly
# as real git would), an include tree needing more than `CFG_INCLUDE_MAX_FOLLOWS` follows, more
# than `CFG_INCLUDE_MAX_LINES` total lines read across every followed file combined, a single
# included line longer than `CFG_INCLUDE_MAX_LINE_CHARS` characters, or more than
# `CFG_INCLUDE_MAX_CHARS` total characters charged across every followed line combined, across the
# whole `resolve_repo()` call (all four: once any of these runs out, no FURTHER include is ever
# opened at all, so the excess include CONTENT past that point is never even read, let alone
# processed; the one exception is the single line, in whichever file already happens to be open,
# whose own read is what drives the line-count or character budget past zero — that one line is
# read in full before the check that follows it can break, the same "one very long line, read once"
# residual the depth-0 top-level case below already has; every depth-0 top-level candidate is still
# always read in full, with no such cap of its own, so none of the four can ever mask a
# pre-#304/#305 route WITHIN ONE RESOLUTION — though all four axes, like the depth-0 read itself,
# are bounded PER `resolve_repo()` call, never across the whole hook invocation (see the "Repo
# resolution" paragraph above): a depth-0 TOP-LEVEL file with very many lines, or a single very long
# line or whitespace run, can still exceed Claude Code's own hook timeout on its own, a pre-existing
# residual this class of fix does not close; so can a single command naming enough resolved `-C`
# push segments (#269 above), each supplying its own at-cap-but-legal include content or its own
# large top-level file, since every one of them gets its own fresh set of these same caps and the
# work each spends is not shared or capped across the whole command — the identical class of
# residual, reached a different way, also not closed here),
# or an
# include value or `includeIf` condition containing an unquoted `#`/`;` (truncated by the same
# comment-strip every other line goes through, or the header falls to the generic "other"
# section) — every one of these fails OPEN (silently not followed), never denies;
# `config.worktree` (`extensions.worktreeConfig`) inside any file this hook reads, still never
# followed; the legacy dotted `[remote.origin]` section
# spelling (only
# the quoted `[remote "origin"]` form is parsed); backslash-continued or backslash-escaped config
# values; a key on the same line as its own section header, e.g. `[remote "origin"] push =
# HEAD:main` (the parser reads only the section declaration on such a line, never any text after
# the closing `]`); and a remote/branch SUBSECTION NAME itself containing an unquoted `#`/`;`
# (e.g. `[remote "back#up"]`) loses its whole section — the header line is truncated before its
# own closing `"]`, so it matches none of the three named section patterns, falls through to the
# generic "other" section, and every key inside it (including a denying `push =` line) is silently
# never captured — measured: rc 0. Since #439, a command-line `-c`/`--config-env` option (any key,
# including `-c push.default=…`/`-c remote.<name>.push=…`) and an inline `GIT_CONFIG_COUNT`/
# `GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>`/`GIT_CONFIG_PARAMETERS`/`GIT_CONFIG_GLOBAL`/
# `GIT_CONFIG_SYSTEM` environment assignment, bare or behind `env`, are no longer read-and-ignored
# residuals — every push segment carrying one is denied outright (see "Fail-closed: command-line
# git config" above) whatever the key or destination. What remains residual there instead: an
# inline `HOME=`/`XDG_CONFIG_HOME=` relocation of the global config this hook itself reads, the
# quote-blind and alias-shaped forms that same paragraph names, and cross-segment `export
# GIT_CONFIG_*` (left to #433). This is a tripwire, not a sandbox — branch protection on the
# default branch remains the real backstop, exactly as hooks/git-c-guard.sh and
# hooks/agent-boundary.sh already document for their own scopes.
#
# Contract: read the PreToolUse hook JSON on stdin; print nothing and exit 0 ("no opinion") unless
# the call is a Bash `git push` whose resolved destination is the default branch (or the
# unconditional `main`/`master` fallback), OR whose target repository this hook cannot resolve at
# all (#292 — see "Fail-closed: an unresolvable push target" above), OR whose push segment carries
# git config supplied on the command line (#439 — see "Fail-closed: command-line git config"
# above), in which case print exactly
# one reason line to stderr and exit 2 ("deny"); stdout is always empty. Wired in hooks/hooks.json via
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
# Byte-identical to hooks/agent-boundary.sh's own PREFIX_WORDS (see that file's vocabulary comment
# for the full reasoning): the trailing words above `dash` are shell reserved words that can
# directly precede a command in the same segment (`if true; then git push origin main; fi`, `!
# git push origin main`), plus `eval`/`trap` (each runs its own string argument as a command) and
# zsh's precommand modifiers `noglob`/`nocorrect`/`-`/`repeat N` (`repeat` also consumes its count
# token — see the command-word walk below), sharing the ordinary prefix-word skip below.
PREFIX_WORDS="env command builtin exec sudo nohup time nice stdbuf xargs bash sh zsh ksh dash if then elif else do while until ! coproc eval trap noglob nocorrect - repeat"
GIT_GLOBAL_OPTS_WITH_VALUE="-c -C --git-dir --work-tree --namespace --config-env --exec-path"
# #269: byte-identical to hooks/git-c-guard.sh's own PATH_ERE (that script's twin declaration,
# a few lines above its own GIT_C_SUBCOMMANDS) — dev/selfcheck.sh's assertion 4.42 extracts both
# mechanically and FAILs the gate if they ever drift apart. Used below (is_c_target_path()) to
# decide whether a push segment's `git -C <path>` value is trusted enough to resolve against —
# see this file's header "Repo resolution" paragraph for the containment argument.
PATH_ERE='^([A-Za-z]:/|/|\.\./)([A-Za-z0-9._ +-]+/)*[A-Za-z0-9._+-]+-wt-[0-9]+/?$'
PUSH_OPTS_WITH_VALUE="-o --push-option --repo --receive-pack --exec"
PUSH_ALL_REFS_OPTS="--all --mirror"
# DBRACKET_MAX — byte-identical to hooks/agent-boundary.sh's own copy (by
# convention, unpinned): the most standalone `]]` matches the scan's additive pass (further down)
# will analyse per input record before failing closed; see that file's own declaration for the
# full reasoning.
DBRACKET_MAX="64"
PUSH_DENY_STEM="trail-blazer-flow push guard:"
# #304/#305: system config candidates governed by $GIT_CONFIG_NOSYSTEM — see the candidate loop in
# resolve_repo() below for the exact NOSYSTEM parse and for the Apple CLT file's own place INSIDE
# that same guard (verified live: GIT_CONFIG_NOSYSTEM=1 drops the CLT file's own scope from real
# git's `--show-origin --show-scope` output, so it is not read unconditionally).
PUSH_SYSTEM_CONFIG_PATHS="/etc/gitconfig /opt/homebrew/etc/gitconfig /usr/local/etc/gitconfig"
PUSH_APPLE_CLT_CONFIG="/Library/Developer/CommandLineTools/usr/share/git-core/gitconfig"
# #304/#305: caps how many `include`/`includeIf` hops cfg_parse_file() below will follow from a
# top-level candidate (itself depth 0) — a backstop alongside the seen-list cycle guard, not a
# claim that real git enforces the same limit.
CFG_INCLUDE_MAX_DEPTH=10
# #304/#305: caps the TOTAL number of include FOLLOW operations across one whole resolve_repo()
# call (session or "-C" alike) — never per ancestor chain, and never reset between sibling
# branches. Depth alone does not bound how many times cfg_parse_file() recurses: since a sibling
# include of the identical path is deliberately re-read every time (the ancestor-only seen-list's
# whole point — see cfg_parse_file()'s own header comment), a file that names the SAME child K
# times per level fans out to about K^depth follow operations, each one a re-open of that same
# target. This budget bounds that COUNT — how many times an include is ever followed, whether or
# not the target is a path already opened elsewhere. It says nothing, on its own, about how much of
# any one followed file is actually read (CFG_INCLUDE_MAX_LINES/CFG_INCLUDE_MAX_CHARS below); the
# include arm's own follow condition ANDs all three together, so a follow only happens while every
# one of the three still has room, closing the gap a follow-count check alone would leave: without
# it, a follow with budget still to spare would still OPEN its target and read its own first line
# in full even after the line-count or character budget had already run out.
CFG_INCLUDE_MAX_FOLLOWS=64
# #304/#305: caps the TOTAL number of LINES read across every included file combined, for one
# whole resolve_repo() call (depth >= 1 only, shared and never reset per file, the same way
# CFG_INCLUDE_MAX_FOLLOWS is never reset per follow — a depth-0 top-level candidate is always read
# in full, never budgeted). A follow-count budget alone does not bound total work: a handful of
# follows of one large file (well within CFG_INCLUDE_MAX_FOLLOWS) can still cost as many lines of
# parsing as the file is long. This caps that dimension: how many LINES of included content are
# ever read in total, independent of how many files are followed. It says nothing about how LONG
# any one of those lines is, or how many total CHARACTERS they cost — see CFG_INCLUDE_MAX_LINE_CHARS
# and CFG_INCLUDE_MAX_CHARS below for those two. See cfg_parse_file()'s own header comment for where
# every budget is spent.
CFG_INCLUDE_MAX_LINES=2048
# #304/#305: caps how many CHARACTERS a single included line (depth >= 1) may have before its
# comment-strip and trim are skipped entirely for that line — it still spends the line and
# character budgets, and parsing simply continues at the next line (fails open for that one line's
# own content, the same stance this hook already takes for any other unresolvable or over-budget
# construct). A line's own length is checked with `${#cfgline}` — a bash builtin, O(n) in the
# line's own length, but cheap relative to comment-strip or trim, which are NOT: see cfg_trim()'s
# own header comment for why a long whitespace run specifically must never reach either one.
# `${#cfgline}` counts CHARACTERS, not bytes, in a UTF-8 locale, so this cap bounds character count,
# never the (larger, for any multi-byte content) byte count of the line it is checking.
CFG_INCLUDE_MAX_LINE_CHARS=512
# #304/#305: caps the TOTAL number of CHARACTERS charged across every included line combined
# (depth >= 1 only), for one whole resolve_repo() call — shared and never reset per file, exactly
# like CFG_INCLUDE_MAX_FOLLOWS and CFG_INCLUDE_MAX_LINES. Charged once per line, `${#cfgline}+1`
# (the line's own CHARACTER length plus one for its own newline — not its byte length, in a UTF-8
# locale), BEFORE the length cap above is even checked, so a line skipped for being too long still
# counts fully against this budget too. Bounds total work a different way than
# CFG_INCLUDE_MAX_LINES: many lines just under CFG_INCLUDE_MAX_LINE_CHARS could otherwise still
# exhaust real time well before CFG_INCLUDE_MAX_LINES lines are reached.
CFG_INCLUDE_MAX_CHARS=65536
# #292: a push segment naming either of these two classes always redirects which repository the
# push actually runs in, and this hook does not resolve either one — GIT_REPO_OPTS is a global
# option (detached "<opt> <value>" or attached "<opt>=<value>"), GIT_REPO_ENV_VARS is a leading
# shell assignment (a bare "VAR=<value> git ..." prefix or the same behind an "env" prefix word).
# Consumed by the awk tokenizer below to flag the segment "unresolved" rather than to resolve
# anything — see the driver loop's own "unresolvable push target" comment for the fail-closed
# verdict this produces.
GIT_REPO_OPTS="--git-dir --work-tree"
GIT_REPO_ENV_VARS="GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR"
# #439: a push segment carrying git config supplied ON THE COMMAND LINE — as an option before the
# subcommand (GIT_CMDCFG_OPTS: detached "-c <k=v>"/"--config-env <k=V>", attached "-c<k=v>"/
# "--config-env=<k=V>") or as a leading environment assignment, bare or behind "env"
# (GIT_CMDCFG_ENV_VARS: an exact-name assignment; GIT_CMDCFG_ENV_PREFIXES: an assignment whose name
# STARTS WITH one of these, for the "_<n>"-suffixed GIT_CONFIG_KEY_/GIT_CONFIG_VALUE_ pair) — adds
# config on top of the files this hook reads above, and this hook never reads it, so (like #292) it
# fails closed: any push segment carrying one of these is denied outright, whatever the key or the
# destination. These three constants are push-guard-only, consumed only by this file's own awk
# tokenizer below — unlike GIT_REPO_OPTS/GIT_REPO_ENV_VARS they have no shared twin in
# hooks/agent-boundary.sh, the same way GIT_REPO_ENV_VARS itself has none.
GIT_CMDCFG_OPTS="-c --config-env"
GIT_CMDCFG_ENV_VARS="GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM"
GIT_CMDCFG_ENV_PREFIXES="GIT_CONFIG_KEY_ GIT_CONFIG_VALUE_"

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
# Emits one "PUSH<TAB><-C value, only when exactly one><TAB><#292 unresolved-reason, empty when
# none><TAB><space-joined remaining tokens>" line per push segment found; nothing for any other
# segment — except a push segment carrying command-line git config (#439), which emits the fixed
# sentinel "-cmdline-config-" instead of a "PUSH…" line (see emit_segment()'s own cmdcfg handling
# below). Neither the "-C" value, the reason, nor the remaining-tokens field can itself contain a
# TAB, since every token comes from splitting on "[ \t]+". Processes $cmd one input line (awk
# record) at a time — the same deliberate, documented false-positive class agent-boundary.sh's
# header explains (a heredoc line that starts with "git push" is scanned as its own segment).
scan_out="$(printf '%s\n' "$cmd" | awk -v prefix_words="$PREFIX_WORDS" -v gopts="$GIT_GLOBAL_OPTS_WITH_VALUE" -v repoopts="$GIT_REPO_OPTS" -v repoenv="$GIT_REPO_ENV_VARS" -v dbracket_max="$DBRACKET_MAX" -v cmdcfgopts="$GIT_CMDCFG_OPTS" -v cmdcfgenv="$GIT_CMDCFG_ENV_VARS" -v cmdcfgpfx="$GIT_CMDCFG_ENV_PREFIXES" '
BEGIN {
  sq = sprintf("%c", 39)
  n = split(prefix_words, pwarr, " ")
  for (i = 1; i <= n; i++) prefix_set[pwarr[i]] = 1
  ng = split(gopts, goarr, " ")
  for (i = 1; i <= ng; i++) gopt_set[goarr[i]] = 1
  nro = split(repoopts, roarr, " ")
  for (i = 1; i <= nro; i++) repoopt_set[roarr[i]] = 1
  nev = split(repoenv, evarr, " ")
  for (i = 1; i <= nev; i++) envvar_set[evarr[i]] = 1
  # #439
  ncco = split(cmdcfgopts, ccoarr, " ")
  for (i = 1; i <= ncco; i++) ccopt_set[ccoarr[i]] = 1
  nce = split(cmdcfgenv, cearr, " ")
  for (i = 1; i <= nce; i++) ccenv_set[cearr[i]] = 1
  nccp = split(cmdcfgpfx, ccparr, " ")
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
function emit_segment(seg, cut_flag,    ntok, toks, idx, tok, norm, saw_prefix, cmdword, j, subcmd, rest, sep, cpath, ccount, unres, aname, ro, cmdcfg, co, cp) {
  ntok = split(seg, toks, /[ \t]+/)
  idx = 1
  saw_prefix = 0
  cmdword = ""
  unres = ""
  cmdcfg = 0
  while (idx <= ntok) {
    tok = toks[idx]
    if (tok == "") { idx++; continue }
    if (match(tok, /^[A-Za-z_][A-Za-z0-9_]*=/) == 1) {
      aname = substr(tok, 1, index(tok, "=") - 1)
      if (unres == "" && (aname in envvar_set)) unres = aname "="
      # #439: a leading GIT_CONFIG_* assignment (bare or behind "env") adds command-line config —
      # store a boolean only, never $aname, so a GIT_CONFIG_KEY_<suffix> name is never echoed.
      if (!cmdcfg) {
        if (aname in ccenv_set) cmdcfg = 1
        else for (cp = 1; cp <= nccp; cp++) if (index(aname, ccparr[cp]) == 1) { cmdcfg = 1; break }
      }
      idx++
      continue
    }
    norm = tolower(normalize(tok))
    if (norm == "") { idx++; continue }
    if (norm in prefix_set) { saw_prefix = 1; idx += (norm == "repeat") ? 2 : 1; continue }
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
    if (unres == "") {
      if (tok in repoopt_set) {
        unres = tok
      } else {
        for (ro = 1; ro <= nro; ro++) {
          if (index(tok, roarr[ro] "=") == 1) { unres = roarr[ro]; break }
        }
      }
      if (unres == "" && substr(tok, 1, 2) == "-C" && tok != "-C") unres = "attached -C<path>"
    }
    # #439: a "-c"/"--config-env" option before the subcommand. A detached "-c"/"--config-env" is
    # an exact ccopt_set member; an attached "-c<k=v>" is caught by the middle substr() arm (which
    # also matches a detached "-c"); an attached "--config-env=<k=V>" by the final index() loop.
    # awk comparison is case-sensitive, so "-C" (the repo-redirect option) never matches here. This
    # only sets a flag; it does not change how gopt_set below still consumes "-c"/"--config-env"
    # together with their own value token.
    if (!cmdcfg) {
      if (tok in ccopt_set) cmdcfg = 1
      else if (substr(tok, 1, 2) == "-c") cmdcfg = 1
      else for (co = 1; co <= ncco; co++) if (index(tok, ccoarr[co] "=") == 1) { cmdcfg = 1; break }
    }
    if (tok in gopt_set) {
      if (tok == "-C") { ccount++; cpath = strip_quotes(toks[j + 1]) }
      j += 2
      continue
    }
    if (substr(tok, 1, 1) == "-") { j++; continue }
    if (normalize(tok) == "") { j++; continue }
    subcmd = normalize(tok)
    j++
    break
  }
  if (subcmd != "push") {
    if (subcmd == "" && cut_flag) print "-cut-push-"
    return
  }
  if (cut_flag) { print "-cut-push-"; return }
  # #439: a real push segment carrying command-line git config denies outright, ahead of the #292
  # unresolved-target reason (Q5) — either way the segment denies.
  if (cmdcfg) { print "-cmdline-config-"; return }
  if (unres == "" && ccount >= 2) unres = "more than one -C"
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
  print "PUSH\t" (ccount == 1 ? cpath : "") "\t" unres "\t" rest
}
{
  line = $0
  gsub(/[;&|(){}`]/, "\n", line)
  gsub(/[<>]/, " ", line)
  nseg = split(line, segs, /\n/)
  for (s = 1; s <= nseg; s++) emit_segment(segs[s])
  # Additive standalone-`]]` handling (see the identical mechanism and comment in
  # hooks/agent-boundary.sh): the segments above are computed EXACTLY as before this issue, so a
  # push segment whose own refspec tokens happen to have a literal `]]` token among them (e.g.
  # `git push origin ]] main`) is still fully resolved by the walk above, unchanged. Separately, for
  # every unquoted, whitespace-bounded `]]` found in a space-padded copy of this record, ONLY the
  # FIRST segment of the text AFTER that `]]` is walked the same way, resuming command position at
  # the word right after the closing `]]` of a zsh short `if [[ cond ]] cmd` form. DISJOINT tails:
  # that first segment ends at whichever comes FIRST, a real segment-break character OR the NEXT
  # standalone `]]` -- never running past a later `]]` into text that the later `]]` own first
  # segment, or the main split above, already covers, so the walk that resolves a git subcommand or a
  # push destination never scales with the remaining record, only with the short cut segment. At most
  # DBRACKET_MAX matches are handled per record, above which this loop fails closed with a fixed
  # sentinel instead of continuing -- see hooks/agent-boundary.sh own copy of this comment for the
  # full reasoning.
  db_rest = " " $0 " "
  db_n = 0
  db_go = 1
  while (db_go && match(db_rest, /[ \t]]][ \t]/)) {
    if (db_n >= dbracket_max) {
      print "-too-many-dbrackets-"
      db_go = 0
    } else {
      db_n++
      # db_next is captured IMMEDIATELY after this match() and used for both db_tail and the
      # db_rest update below: the INNER match() two lines down (finding where db_seg itself ends),
      # and emit_segment() (called via this block, itself calling match(), the assignment-prefix
      # check), would otherwise clobber the RSTART/RLENGTH globals this loop still needs to advance
      # past the JUST-matched "]]" occurrence -- reading RSTART/RLENGTH again after either call is
      # what hung this loop before this capture was added. It stops ONE character short of where
      # this match ends (RLENGTH - 1, not RLENGTH), deliberately leaving the matched trailing
      # whitespace byte in db_rest: two standalone `]]` separated by exactly one space or tab share
      # that one byte as boundary for BOTH of them, and consuming it here would leave the very next
      # `]]` with no leading whitespace of its own to match against, silently skipping every other
      # occurrence in a tightly packed run.
      db_next = RSTART + RLENGTH - 1
      db_tail = substr(db_rest, db_next)
      db_cut = 0
      if (match(db_tail, /[;&|(){}`]|[ \t]]][ \t]/) > 0) {
        db_seg = substr(db_tail, 1, RSTART - 1)
        if (RLENGTH == 4) db_cut = 1
      } else {
        db_seg = db_tail
      }
      gsub(/[<>]/, " ", db_seg)
      emit_segment(db_seg, db_cut)
      db_rest = substr(db_rest, db_next)
    }
  }
}
')"

# --- repo resolution (reads only, never executes) ---------------------------------------------
# cfg_trim VALUE — strips leading/trailing [:space:], setting the plain global $cfg_trim_out (the
# same "set a plain global, caller reads it after the call returns" idiom evaluate_segment() uses
# for __deny_dest/__deny_kind, and resolve_repo() uses for gitdir/default_branch) — NEVER called
# inside "$(…)": a config file can carry thousands of lines, each needing up to three trim calls
# (the whole line, the key, the value), and every "$(…)" forks a full bash process image (a
# fork(), not an exec() of a separate program — the forked child still runs the SAME bash script);
# that per-call fork cost made an include chain a timing DoS in its own right, independent of the
# file-count and line-count budgets below (which is why this rewrite exists — see
# CFG_INCLUDE_MAX_LINES's own vocabulary comment). Pure parameter expansion only (bash 3.2-safe: no
# ${var,,}, no declare -A, no tr/sed, no extglob) — a caller must read $cfg_trim_out on the very
# next statement, before any other cfg_trim call or recursive cfg_parse_file call can overwrite it
# (every call site below does exactly this). Byte-for-byte the same trimming behaviour as the
# pre-rewrite char-by-char loop version: checked directly against it over a table of inputs
# including embedded CR, tabs, newlines, mixed whitespace, and an all-whitespace or empty value,
# and separately fuzz-checked over a large random-string corpus; every existing push-guard fixture
# that touches config parsing still passes against this rewrite, unchanged. This pure-expansion
# form is NOT, however, uniformly fast for every input shape: matching the bracket-class pattern
# below against a long run of trailing (or leading) whitespace can cost far more than the input's
# own length in bash's own glob engine — see CFG_INCLUDE_MAX_LINE_CHARS's own vocabulary comment
# for the cap that keeps this function from ever seeing such an input for an included (depth >= 1)
# line; a depth-0 top-level candidate has no such cap and remains a named residual (see this file's
# header). Used only by the #268 config parser below; defined
# here (rather than alongside is_deny_member()/refspec_dest() further down) because it must exist
# before the config-parsing loop inside the "if [ -n "$gitdir" ]" block below runs — earlier in
# this file's execution order than those two.
cfg_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  cfg_trim_out="$s"
}

resolve_cwd="${cwd:-$PWD}"
[ -n "$resolve_cwd" ] || resolve_cwd="."

# #268: cfg_tab is the tab byte cfg_push_lines records use as a field separator inside
# resolve_repo() below; #269 hoists it to file scope (computed once, not per call) since
# resolve_repo() is now called once for the session checkout and, per resolved "-C" segment,
# once more.
cfg_tab="$(printf '\t')"
# #304/#305: nl is the newline byte cfg_seen (below) uses as a delimiter around each already-parsed
# path, so a bracketed substring match (`*"$nl$path$nl"*`) can never be fooled by one path being a
# textual substring of another. File scope, like cfg_tab, since cfg_parse_file() is called both
# from resolve_repo() and, recursively, from itself.
nl=$'\n'
# #304/#305: a SEPARATE carriage-return literal from $cr (declared above for the #270
# command-string strip): the push mutation table's M23 mutant deletes both of $cr's declaration
# and its use, and a config parser referencing $cr here would blow up under `set -u` instead of
# producing that mutant's documented, measured result. File scope (not per candidate file), since
# it is a fixed literal independent of which candidate is being parsed.
cfg_cr=$'\r'

# cfg_parse_file PATH LABEL DEPTH (#304/#305) — parses one config file inline, recursively
# following `include`/`includeIf` directives found in its own content (conditions ignored — the
# union stance every other multi-file read in this hook already takes). PATH is a candidate config
# file (a system/global/repo-local candidate from resolve_repo()'s own list, or an include target
# resolved by this function itself); LABEL is the free-text source label #268/#290 already use in
# the deny message — a child include gets "LABEL (via include)", added exactly once no matter how
# deep the nesting goes (see the `include)` key arm below); DEPTH is PATH's own include depth (0
# for a candidate straight from resolve_repo()'s list). Guards, in order: PATH non-empty, PATH a
# regular file (`[ -f ]`; excludes a FIFO or device — never opened any other way), and PATH not
# already present in $cfg_seen, a newline-delimited membership string. $cfg_seen is ANCESTOR-ONLY,
# not a whole-call history: this function saves it to a `local` on entry, appends PATH, and
# restores the saved value right before it returns — so PATH is only ever "seen" while ITS OWN
# call frame (and every descendant `include` it triggers) is still on the stack. This is exactly
# enough to stop a self- or mutual-include cycle (an ancestor including itself back), without
# relying on CFG_INCLUDE_MAX_DEPTH alone, while still letting two SIBLING includes of the identical
# path — or a later, unrelated top-level candidate that happens to name a path some earlier
# candidate's own include already pulled in — each be read independently, in git's own order (a
# global, never-restored $cfg_seen under-blocked exactly this: an absolute-path include inside a
# GLOBAL candidate that happens to point at the session's own repo-local `config` file would
# permanently mark that path "seen", so the repo-local top-level candidate's own later, mandatory
# re-read of that same file — which must always run, and always run LAST, for the repo's own
# last-wins scalars to resolve correctly — was wrongly skipped; killed by the
# push-include-deny-repo-config-reincluded fixture and the `304-inc-seen-global` mutant, which
# reverts to a whole-call $cfg_seen to prove the fixture actually depends on the ancestor-only
# scope). Re-reading every sibling of an identical path is exactly what makes an adversarial
# config tree able to FAN OUT: a file naming the SAME child K times per level, K levels deep, costs
# about K^depth follow operations. Four independent mechanisms bound the resulting work, checked in
# the read loop below (depth >= 1 only): $cfg_inc_budget, a GLOBAL, monotonically decreasing
# per-`resolve_repo()`-call counter (never saved/restored per ancestor frame the way $cfg_seen is —
# see the vocabulary declaration for CFG_INCLUDE_MAX_FOLLOWS), caps the TOTAL number of follow
# operations, regardless of fan-out shape; $cfg_inc_line_budget (see CFG_INCLUDE_MAX_LINES's own
# vocabulary declaration), reset the same way and likewise never saved/restored per ancestor frame,
# caps the TOTAL number of LINES read across every followed file combined for the whole call,
# `break`ing out of the CURRENT frame's own read loop once exhausted — never `return`ing, so the
# `cfg_seen` restore below still runs; a per-line length check against CFG_INCLUDE_MAX_LINE_CHARS,
# using `${#cfgline}` — a bash builtin, O(n) in the line's own length but cheap relative to
# comment-strip or trim — skips comment-strip and trim entirely for one over-length line
# (`continue`, not `break` — the line and character budgets are still spent for it) — this is the
# one of the four that exists for a DIFFERENT reason than fan-out: `cfg_trim()`'s own pattern
# matching is not uniformly fast for a long line or whitespace run (see that function's header
# comment), so this check keeps such a line from ever reaching it, independent of how many files or
# lines are involved at all; and $cfg_inc_char_budget (see CFG_INCLUDE_MAX_CHARS's own vocabulary
# declaration), reset and scoped the same way as the line-count budget, charges `${#cfgline}+1` per
# line BEFORE the length check above even runs (so an over-length line still spends this budget
# too, and note `${#cfgline}` counts CHARACTERS, not bytes, in a UTF-8 locale) and `break`s once it
# goes negative, bounding a shape the line-count budget alone cannot: many lines each just under
# CFG_INCLUDE_MAX_LINE_CHARS. The include arm's own follow condition (below) additionally requires
# BOTH the line-count and character budgets to still be positive before a follow is even attempted
# — once either reaches zero, no FURTHER include is ever opened at all, not even to try `[ -f ]` on
# it, so a fan-out with follow-budget still to spare cannot keep costing real time one first-line
# read at a time; the one line this cannot prevent is whichever SINGLE line, in whichever file is
# already open, is what drives the line-count or character budget below zero — that line is read in
# full (a read loop takes one whole line at a time) before the check that follows it can break. None
# of these four checks ever applies to a depth-0 top-level candidate — those are always read in
# full, unconditionally, exactly as they always were, so none of the four can ever mask a
# pre-#304/#305 route WITHIN ONE RESOLUTION (see the "Repo resolution" paragraph above for how
# multiple resolutions per hook invocation multiply this same bounded work instead). Declares every
# per-file variable `local`, so a nested call (an include's
# own include) never clobbers the includer's own section state — proven by the
# push-include-deny-second-path-after-return fixture, which pins that parsing resumes, in the
# includer's own section, right after an inline include returns. Reads only through `done < "$1"`,
# a `[ -f ]`-guarded builtin redirect — never `cat`, `dirname`, `cd`, or any external command on
# PATH or a value taken from its content; an include's own path is resolved with parameter
# expansion only (see the `include)` key arm below), so no include-derived string ever reaches any
# process's argv. Still appends to the plain (non-local) globals cfg_push_lines/cfg_push_defaults/
# cfg_branch_merge, and reads the plain global current_branch, exactly as the pre-#304/#305 inline
# loop did.
cfg_parse_file() {
  local path="$1" label="$2" depth="$3"
  [ -n "$path" ] || return 0
  [ -f "$path" ] || return 0
  case "$cfg_seen" in
    *"$nl$path$nl"*) return 0 ;;
  esac
  local saved_seen="$cfg_seen"
  cfg_seen="${cfg_seen}${path}${nl}"

  local cfg_section="" cfg_subsection="" cfgline cfg_h cfg_s cfg_key cfg_val
  local inc_resolved inc_childlabel
  while IFS= read -r cfgline || [ -n "$cfgline" ]; do
    # Three depth->=1-only budgets, checked here, in this order, before comment-strip or trim ever
    # runs -- CFG_INCLUDE_MAX_LINES bounds total LINE-reading work across every included file
    # combined for this whole resolve_repo() call (shared, like $cfg_inc_budget -- never reset per
    # file); CFG_INCLUDE_MAX_CHARS separately bounds total CHARACTERS charged the same way; and
    # CFG_INCLUDE_MAX_LINE_CHARS caps any single line's own length, checked with the cheap (though
    # O(n) in the line's own length) `${#cfgline}` -- never by running comment-strip or trim on it
    # first (see cfg_trim()'s own header comment for why that specific ordering matters: a single
    # line far past this cap could cost real seconds in trim's own pattern matching, independent of
    # how many lines or files are involved at all). The include arm's own follow condition also
    # requires the line and character budgets below to still be positive before opening a NEW
    # include at all -- see that arm's own comment. None of these three per-line checks ever
    # applies to a depth-0 top-level candidate (those are always read in full) -- see each
    # vocabulary declaration's own comment.
    if [ "$depth" -ge 1 ]; then
      [ "$cfg_inc_line_budget" -gt 0 ] || break
      cfg_inc_line_budget=$((cfg_inc_line_budget - 1))
      cfg_inc_char_budget=$((cfg_inc_char_budget - ${#cfgline} - 1))
      [ "$cfg_inc_char_budget" -ge 0 ] || break
      [ "${#cfgline}" -le "$CFG_INCLUDE_MAX_LINE_CHARS" ] || continue
    fi
    cfgline="${cfgline//$cfg_cr/}"
    # Strip a trailing comment: whichever of '#'/';' appears first, with no quote-tracking -- git
    # ref names MAY legitimately contain '#' or ';' (e.g. refs/heads/feat#123 and
    # refs/heads/feat;123 are both accepted by git itself), so this is a known, documented parsing
    # gap, not a safe assumption. See this file's header "Documented over-blocking classes" (a
    # destination value truncated at the marker) and "Documented under-blocking classes" (a
    # remote/branch subsection name, or an include value/includeIf condition, truncated at the
    # marker) for the behaviour classes this creates.
    cfg_h="${cfgline%%#*}"
    cfg_s="${cfgline%%;*}"
    if [ "${#cfg_h}" -le "${#cfg_s}" ]; then cfgline="$cfg_h"; else cfgline="$cfg_s"; fi
    cfg_trim "$cfgline"; cfgline="$cfg_trim_out"
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
      \[[Ii][Nn][Cc][Ll][Uu][Dd][Ee]\]*)
        # #304/#305: a plain [include] section — the child path key is dispatched below.
        cfg_section="include"
        cfg_subsection=""
        continue
        ;;
      \[[Ii][Nn][Cc][Ll][Uu][Dd][Ee][Ii][Ff]\ \"*\"\]*)
        # #304/#305: an [includeIf "<condition>"] section — the condition itself is never
        # evaluated (the union, over-blocking stance Open question 3 settles): every conditional
        # include is followed exactly like an unconditional one.
        cfg_section="include"
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
        cfg_trim "${cfgline%%=*}"; cfg_key="$cfg_trim_out"
        cfg_trim "${cfgline#*=}"; cfg_val="$cfg_trim_out"
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
            # cfg_push_defaults' own "${label}${cfg_tab}${cfg_val}" shape below), with the
            # configured value as the record's unbounded TAIL, never a bounded middle field — a
            # `push =` value containing a literal TAB byte is unusual but not impossible (this
            # config parser never rejects one), and a bounded middle field would let such a value
            # truncate at the embedded TAB and leak its own remainder into config_deny()'s
            # source-label field. cfg_subsection (the remote name) is read from a quoted section
            # header, never a value that could itself carry a raw TAB in any fixture this file
            # constructs.
            cfg_push_lines="${cfg_push_lines}${label}${cfg_tab}${cfg_subsection}${cfg_tab}${cfg_val}"$'\n'
            ;;
        esac
        ;;
      push)
        case "$cfg_key" in
          [Dd][Ee][Ff][Aa][Uu][Ll][Tt])
            cfg_push_defaults="${cfg_push_defaults}${label}${cfg_tab}${cfg_val}"$'\n'
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
      include)
        case "$cfg_key" in
          [Pp][Aa][Tt][Hh])
            # #304/#305: resolve cfg_val with parameter expansion only — never dirname, cd,
            # realpath, or any external command, so an include target never reaches any process's
            # argv. Order matters: the empty/tilde-slash/absolute/prefix-or-bare-tilde arms must be
            # tried before the generic relative-path fallback.
            inc_resolved=""
            case "$cfg_val" in
              "") : ;;
              \~/*)
                [ -n "${HOME:-}" ] && inc_resolved="$HOME/${cfg_val#\~/}"
                ;;
              /*|[A-Za-z]:/*)
                inc_resolved="$cfg_val"
                ;;
              %\(prefix\)/*|\~*)
                : ;;
              *)
                inc_resolved="${path%/*}/$cfg_val"
                ;;
            esac
            # The line-count and character budgets, not just the follow-count one, gate whether a
            # follow happens AT ALL: without them, a follow with budget still to spare would still
            # OPEN its target and read its own first line in full even after either budget had
            # already run out elsewhere -- see CFG_INCLUDE_MAX_FOLLOWS's own vocabulary comment.
            if [ -n "$inc_resolved" ] && [ "$((depth + 1))" -le "$CFG_INCLUDE_MAX_DEPTH" ] \
              && [ "$cfg_inc_budget" -gt 0 ] \
              && [ "$cfg_inc_line_budget" -gt 0 ] && [ "$cfg_inc_char_budget" -gt 0 ]; then
              cfg_inc_budget=$((cfg_inc_budget - 1))
              case "$label" in
                *" (via include)") inc_childlabel="$label" ;;
                *) inc_childlabel="$label (via include)" ;;
              esac
              cfg_parse_file "$inc_resolved" "$inc_childlabel" $((depth + 1))
            fi
            ;;
        esac
        ;;
    esac
  done < "$path"
  cfg_seen="$saved_seen"
}

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
# #290, EVERY call (session and "-C") also unions in the GLOBAL config candidates below, and,
# since #304/#305, the SYSTEM config candidates too, plus every `include`/`includeIf` target found
# inside any of them (see cfg_parse_file() above) — the environment (and this file's own fixed
# system-path vocabulary) is read identically regardless of MAX_DEPTH, so a resolved "-C" segment
# sees the same global, system and include routes the session does (see "Cross-feature" in
# dev/hook-tests.sh's push mutation table for the fixture pinning the #290 half of this, and the
# push-sysconf-deny-c-target fixture for the #304/#305 half).
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
  # not a scalar — see the config-candidate loop below for why. cfg_seen (#304/#305) is reset to a
  # single newline on every resolve_repo() call (session and "-C" alike), so cfg_parse_file()'s
  # own seen-list dedupe never leaks a prior call's state. cfg_inc_budget (#304/#305) is reset to
  # CFG_INCLUDE_MAX_FOLLOWS on the same schedule — a single counter, GLOBAL for the whole call,
  # never saved/restored per ancestor frame the way cfg_seen is: it must monotonically decrease
  # across every follow, sibling branches included, or a fan-out shape could still give each
  # sibling its own fresh allowance and reproduce the same unbounded blowup this budget exists to
  # cap (see cfg_parse_file()'s own header comment and the vocabulary declaration above).
  # cfg_inc_line_budget (#304/#305) is reset to CFG_INCLUDE_MAX_LINES the same way, for the same
  # reason (a SINGLE shared counter, never per file), bounding the OTHER dimension: total lines
  # read across every followed file combined, not how many files are followed.
  # cfg_inc_char_budget (#304/#305) is reset to CFG_INCLUDE_MAX_CHARS the same way, bounding a
  # THIRD dimension: total characters charged, since many lines just under
  # CFG_INCLUDE_MAX_LINE_CHARS could otherwise still add up to real time before
  # CFG_INCLUDE_MAX_LINES lines are reached.
  cfg_push_lines=""
  cfg_push_defaults=""
  cfg_branch_merge=""
  cfg_seen="$nl"
  cfg_inc_budget="$CFG_INCLUDE_MAX_FOLLOWS"
  cfg_inc_line_budget="$CFG_INCLUDE_MAX_LINES"
  cfg_inc_char_budget="$CFG_INCLUDE_MAX_CHARS"
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

    # #290/#304/#305: config CANDIDATES, system routes first, then global routes, this checkout's
    # own repo-local config LAST — never derived from the untrusted command string, only from the
    # environment ($GIT_CONFIG_SYSTEM, $GIT_CONFIG_NOSYSTEM, $TBF_PUSH_GUARD_SYSCONFIG_ROOT,
    # $GIT_CONFIG_GLOBAL, $XDG_CONFIG_HOME, $HOME), this file's own fixed system-path vocabulary
    # (PUSH_SYSTEM_CONFIG_PATHS, PUSH_APPLE_CLT_CONFIG), and $common above (every environment
    # reference ${VAR:-}-guarded under `set -uo pipefail`). Repo-local read last so a last-wins
    # scalar (cfg_branch_merge) resolves to the repo's own value on any conflict with a system or
    # global file, matching git's own unconditional deference to the repo config for that key;
    # cfg_push_lines and cfg_push_defaults both ACCUMULATE across every candidate (and every
    # include followed from one — see cfg_parse_file() above) regardless of order — a route from
    # any file can deny (the union stance #268 already took across remotes, now also across files
    # and, since #304/#305, across an include chain) — so this order only decides which route's
    # label is named first when more than one denies. $GIT_CONFIG_GLOBAL is UNIONED with (never a
    # replacement for) the other two global paths, and $GIT_CONFIG_SYSTEM is likewise UNIONED with
    # (never a replacement for) the static system paths: real git reads only the corresponding
    # *_GLOBAL/*_SYSTEM env var, when set, in place of the matching default path; this hook
    # deliberately reads both, a documented over-block (see "Documented over-blocking classes"
    # above). $nosys below parses $GIT_CONFIG_NOSYSTEM for a canonical true value ONLY
    # (`1`/`true`/`yes`/`on`, case-insensitively) — any other value, including a non-canonical
    # truthy-looking one such as `2`, leaves the system candidates in force (fail-toward-deny, a
    # documented over-block). Verified live that GIT_CONFIG_NOSYSTEM also drops the Apple CLT
    # candidate's own scope from real git's `--show-scope` output, so PUSH_APPLE_CLT_CONFIG sits
    # INSIDE the same $nosys guard as the three PUSH_SYSTEM_CONFIG_PATHS entries, not outside it.
    # See this file's header "Repo resolution" paragraph for the full reasoning and "Documented
    # under-blocking classes" for what stays unread (a system config at a path not on this static
    # list, an include form this hook cannot resolve, config.worktree, and an inline HOME=/
    # XDG_CONFIG_HOME= relocation) — since #439 a command-line "-c"/"--config-env" option or a
    # GIT_CONFIG_* environment assignment denies the push outright instead of being read as config.
    xdg_cfg=""
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
      xdg_cfg="$XDG_CONFIG_HOME/git/config"
    elif [ -n "${HOME:-}" ]; then
      xdg_cfg="$HOME/.config/git/config"
    fi
    home_cfg=""
    [ -n "${HOME:-}" ] && home_cfg="$HOME/.gitconfig"

    # #304/#305: $sysroot is a TEST-ONLY prefix (empty in every real run) applied solely to the
    # static system paths below, never to $GIT_CONFIG_SYSTEM, any HOME/XDG path, or an include
    # target — see dev/hook-tests.sh's run_push_guard for how the fixture harness sets it so this
    # suite never touches the host's own real system config files.
    sysroot="${TBF_PUSH_GUARD_SYSCONFIG_ROOT:-}"
    case "${GIT_CONFIG_NOSYSTEM:-}" in
      [Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]|1) nosys=1 ;;
      *) nosys=0 ;;
    esac
    sys_records=""
    if [ "$nosys" -eq 0 ]; then
      sys_records="your system git config${cfg_tab}${GIT_CONFIG_SYSTEM:-}"$'\n'
      for syspath in $PUSH_SYSTEM_CONFIG_PATHS; do
        sys_records="${sys_records}your system git config${cfg_tab}${sysroot}${syspath}"$'\n'
      done
      sys_records="${sys_records}your system git config${cfg_tab}${sysroot}${PUSH_APPLE_CLT_CONFIG}"
    fi

    # #304/#305: every candidate now travels as a "<label>${cfg_tab}<path>" record — the label no
    # longer needs a path-based case switch keyed off $common/config (the pre-#304/#305 shape of
    # this loop); each record already carries its own label. Split on the FIRST cfg_tab and hand
    # both fields to cfg_parse_file() above, which does the actual per-file, include-following
    # parse — see that function's own header comment for what it reads and how it resolves an
    # include target.
    while IFS= read -r cfgrec; do
      [ -n "$cfgrec" ] || continue
      cfg_reclabel="${cfgrec%%"$cfg_tab"*}"
      cfg_recpath="${cfgrec#*"$cfg_tab"}"
      cfg_parse_file "$cfg_recpath" "$cfg_reclabel" 0
    done <<CFGLIST
$sys_records
your global git config${cfg_tab}${GIT_CONFIG_GLOBAL:-}
your global git config${cfg_tab}$xdg_cfg
your global git config${cfg_tab}$home_cfg
.git/config${cfg_tab}$common/config
CFGLIST
  fi
}

resolve_repo "$resolve_cwd" 64
# #292: session_root is the directory $dir (a plain global left holding the .git-bearing directory
# where resolve_repo()'s own upward walk broke, or unchanged from START_DIR when it never found
# one) was left at by THIS session-scoped call specifically — captured here, before apply_c_target
# below ever calls resolve_repo() again (which would overwrite $dir with a "-C" target's own
# result), so a later comparison against it always reflects the SESSION, never a resolved segment.
# Empty when the session itself never resolved a gitdir at all.
session_root=""
[ -n "$gitdir" ] && session_root="$dir"
session_default_branch="$default_branch"
session_current_branch="$current_branch"
session_cfg_push_lines="$cfg_push_lines"
session_cfg_push_defaults="$cfg_push_defaults"
session_cfg_branch_merge="$cfg_branch_merge"

# is_session_checkout_path PATH (#292) — true iff PATH is LEXICALLY the session checkout: exactly
# "." (or "./", once its own trailing "/" is stripped below), $resolve_cwd (the PreToolUse stdin
# "cwd", or $PWD when absent) with or without one trailing "/", or $session_root (captured just
# above) with or without one trailing "/". Builtins only — no filesystem access, no process spawned
# — consulted by the driver loop below only to decide whether an otherwise-unresolvable "-C" value
# should still be treated as "this segment IS the session" rather than denied as unresolved (see
# the driver loop's own "unresolvable push target" comment). Guards the "= /" case before stripping
# a trailing slash so the root path itself is never turned into an empty string by "${p%/}".
is_session_checkout_path() {
  local p="$1" rc="$resolve_cwd" sr="$session_root"
  [ "$p" = "/" ] || p="${p%/}"
  [ "$rc" = "/" ] || rc="${rc%/}"
  [ -z "$sr" ] || [ "$sr" = "/" ] || sr="${sr%/}"
  [ "$p" = "." ] && return 0
  [ "$p" = "$rc" ] && return 0
  [ -n "$sr" ] && [ "$p" = "$sr" ] && return 0
  return 1
}

# apply_session_repo (#269) — (re)applies the session checkout's own resolved facts (captured
# above, right after the one and only session-scoped resolve_repo call) to
# default_branch/current_branch/cfg_*, and rebuilds deny_set/default_display exactly as the
# pre-#269 file-scope statements did. Called once per push segment (see the driver loop below),
# before that segment's own "-C" value (if any) is considered — so a segment with no "-C", or one
# whose "-C" value satisfies PATH_ERE but resolves no gitdir of its own, is judged by these session
# facts alone. A "-C" value that fails PATH_ERE (and is not lexically the session checkout) never
# reaches this function's facts at all: the driver loop below denies it outright first (#292).
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

# config_deny SCOPE_REMOTE — evaluates the #268/#290/#304/#305 config-derived push routes
# (remote.<name>.push, push.default) captured by the repo-resolution parse above, from every
# candidate file that was actually read (repo-local, global, system, and any file reached via
# `include`/`includeIf`); on a deny, sets $__deny_dest/
# $__deny_kind ("config" or "configall")/$__deny_via/$__deny_src (the source label — one of
# ".git/config", "your global git config" or "your system git config", each optionally suffixed
# " (via include)" exactly once no matter how deep the include nesting goes — see
# cfg_parse_file() above for how the suffix is built) the same way evaluate_segment's other checks
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
    "-too-many-dbrackets-")
      deny_dest="too many ]] tokens to analyse"
      deny_kind="dbracket"
      break
      ;;
    "-cut-push-")
      deny_dest="split by ]]"
      deny_kind="cutpush"
      break
      ;;
    "-cmdline-config-")
      # #439: fixed reason, no input — see the cmdcfg) message arm below.
      deny_dest="command-line git config"
      deny_kind="cmdcfg"
      break
      ;;
    "PUSH$TAB"*) : ;;
    *) continue ;;
  esac
  seg_body="${line#PUSH$TAB}"
  seg_cpath="${seg_body%%"$TAB"*}"
  seg_rest2="${seg_body#*"$TAB"}"
  seg_unres="${seg_rest2%%"$TAB"*}"
  seg_rest="${seg_rest2#*"$TAB"}"
  apply_session_repo
  # #292: fail closed on an UNRESOLVABLE push target, before apply_c_target/evaluate_segment ever
  # run for this segment — the first-offender rule applies here too. seg_unres already carries a
  # reason when the tokenizer itself recognised an evasion (an attached "-C<path>", 2+ "-C" tokens,
  # a GIT_REPO_OPTS global option, or a GIT_REPO_ENV_VARS assignment — see emit_segment() above).
  # The remaining evasion, an ordinary detached "-C <path>" that fails is_c_target_path() (so it
  # will never be resolved by apply_c_target below) and is not lexically the session checkout
  # either (is_session_checkout_path(), above), is caught here instead, since it takes both
  # $resolve_cwd and $session_root to decide — neither is available inside the awk tokenizer.
  if [ -z "$seg_unres" ] && [ -n "$seg_cpath" ] && ! is_c_target_path "$seg_cpath" && ! is_session_checkout_path "$seg_cpath"; then
    seg_unres="-C path outside the <name>-wt-<n> worktree shape"
  fi
  if [ -n "$seg_unres" ]; then
    deny_dest="$seg_unres"
    deny_kind="unresolved"
    break
  fi
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
    dbracket)
      printf '%s denies this command: too many standalone ]] tokens to analyse safely (blocked: too many ]] tokens to analyse) — open a PR from a claude/<n>-<slug> branch instead; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" >&2
      ;;
    cutpush)
      printf '%s denies this command (cannot analyse a push split by ]]) — open a PR from a claude/<n>-<slug> branch instead; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" >&2
      ;;
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
    unresolved)
      printf '%s denies this push: it cannot resolve which repository the push runs in (%s), so it cannot rule out that repository'"'"'s default branch — the harness never pushes this way; a human can run it from a terminal inside that checkout, or use a <repo>-wt-<n> worktree path; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" "$deny_dest" >&2
      ;;
    cmdcfg)
      # #439: fixed message, no %s for input — never echoes the -c key/value or a matched
      # GIT_CONFIG_KEY_<suffix>/GIT_CONFIG_VALUE_<suffix> name.
      printf '%s denies this push: it carries git config supplied on the command line (git -c, --config-env, or a GIT_CONFIG_* environment assignment), which this hook does not read, so it cannot rule out the default branch — the harness never pushes this way; drop the command-line config, or a human can run it from a terminal; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" >&2
      ;;
    *)
      printf '%s denies pushing to "%s" (resolves to the default branch: %s) — open a PR from a claude/<n>-<slug> branch instead; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" "$deny_dest" "$default_display" >&2
      ;;
  esac
  exit 2
fi

exit 0
