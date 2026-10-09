#!/usr/bin/env bash
#
# push-guard.sh — plugin-shipped PreToolUse hook (#260) that mechanically narrows every Bash
# call's `git push` surface, main session included (unlike hooks/agent-boundary.sh, which only
# governs the implementer/verifier subagents): it denies (exit 2, one stderr line, empty stdout)
# any push whose resolved DESTINATION is the repo's default branch, ALSO denies a push segment
# whose target repository it cannot resolve at all (#292 — see "Fail-closed: an unresolvable push
# target" below), ALSO denies a push segment carrying git config supplied on the command line
# (#439 — see "Fail-closed: command-line git config" below), ALSO denies, since #435, a command
# whose analysis cannot finish inside this hook's own time budget, or a push that reads a git config
# file with a depth-0 line too long to analyse safely (see "Analysis deadline (#435)" below), ALSO
# denies, since #494, a Codex push whose shell `workdir` is not provably the session checkout (see
# "Fail-closed: Codex shell workdir (#494)" below), ALSO denies, since #448, any git command whose
# subcommand is a git alias that may expand to a push, or that runs under config this hook cannot read
# (see "Fail-closed: git aliases and config relocation (#448)" below), ALSO denies, since #510, a git
# command that reads a git config file holding a section header line it cannot split the way git does
# (see "Section headers and same-line keys (#510)" below), ALSO denies, since #517, a push whose
# destination is built at run time, a segment whose git alias name the tokenizer lost behind an
# ANSI-C or locale spelling, and a command longer than PUSH_CMD_MAX_BYTES (see "Fail-closed: a runtime
# expansion in the push destination (#517)" and "Analysis deadline (#435)" below), ALSO denies, since
# #518, a segment whose push may hide behind the separate value of a prefix word's option (see
# "Fail-closed: a value-taking option of a prefix word (#518)" below), and
# says nothing (exit 0, empty stdout, empty stderr — "no opinion") about everything else, so the
# normal permission flow — a prompt, or a matching deny rule in
# templates/repo-settings.json, which always wins over this hook's decision — applies. This closes
# the gap #260 names: the settings deny entries
# `Bash(git push origin main:*)` / `Bash(git -C * push origin main*)` are prefix-matched and are
# bypassed by refspec spellings such as `HEAD:main`, `+HEAD:refs/heads/main`, or a remote other
# than `origin` — this hook parses the refspec instead of pattern-matching the raw command text.
#
# Enforces "deny a push whose destination is the default branch", "deny a push whose target
# repository cannot be resolved at all" (#292), "deny a push segment carrying command-line git
# config" (#439), and, since #435, "deny a command (or a config line it reads) too large to analyse
# safely inside this hook's own time budget", and, since #494, "deny a Codex push whose shell
# `workdir` is not the session checkout as a plain string literal", and, since #448, "deny a git
# command whose subcommand may be an alias for a push, or an inline HOME=/XDG_CONFIG_HOME= relocation
# on a push", and, since #510, "deny a git command that reads a config file with a section header line
# this hook cannot split the way git does", and, since #517, "deny a push whose destination is built at
# run time", "deny a lost segment holding a dollar-quote word the hook cannot read as one name", and
# "deny a command longer than PUSH_CMD_MAX_BYTES", and, since #518, "deny a segment whose push may hide
# behind the separate value of a prefix word's option"; does NOT enforce an
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
# carriage-return strip of the command text before it is tokenized (agent-boundary.sh does it as a
# bash-native expansion right after the jq extraction; this file has done it, since #517, as the
# first statement of the awk record block — a CRLF-carrying transport can otherwise deliver a
# command whose tokens carry a trailing `\r`, which every exact-match comparison below would miss).
# A future fix to either tokenizer's shared behaviour (segment breaking; the additive standalone
# `]]` handling; normalize(); the prefix-word skip, including the `repeat`-count skip; the
# empty-normalised-token skip; the command-word case fold; the CR strip) must be applied to BOTH
# files — see this repo's
# CLAUDE.md and dev/selfcheck.sh's assertion 4.40 clause (c), which mechanically pins the two
# scripts' PREFIX_WORDS vocabulary stays byte-identical. Differences from agent-boundary.sh's
# tokenizer: after resolving a segment's command word as `git`, this script walks forward again
# skipping a GIT_GLOBAL_OPTS_WITH_VALUE token together with its next token (a value), or any other
# `-…` token alone, until the first non-dash token — the subcommand (except that a quote- or
# backslash-bearing option fails closed when a push can follow, see "Fail-closed: a segment the
# tokenizer cannot follow (#449)" below); and, in the command-word walk, this script alone has the
# git-option-slot trigger, while the `env` arm (the allowlisted `env` options, `-u`/`--unset` with
# their value), the two command-prefix #449 triggers and the #518 value-context trigger (with
# PREFIX_VALUE_WORDS) are applied by `hooks/agent-boundary.sh` too,
# each hook with its own verdict (see that file's header), the shared PREFIX_WORDS skip
# itself being unchanged; since #508 the expansion-word predicate (rx_re and rx_word(), see "Fail-closed:
# a runtime expansion in the command prefix or the git options (#508)" below) is the same text in both
# scripts, each with its own verdict; if that subcommand is exactly
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
# command-line git config" below), never silently read as config. A depth-0 top-level candidate is
# read whole, with no size or line-count cap of its own — never budgeted the way an included file's
# four axes below are. Since #435, a single line's own LENGTH is capped instead
# (`CFG_TOPLEVEL_MAX_LINE_CHARS`, checked before comment-strip or trim ever run on it) and denies
# outright rather than ever reaching `cfg_trim()`'s own pattern matching, which is not uniformly
# fast for a long line or whitespace run (see that function's header comment); and
# `check_deadline()` (see "Analysis deadline (#435)" below) samples this read loop on every line,
# so a pathological many-line TOP-LEVEL file that keeps this hook running past its own analysis
# budget now denies with a fixed reason instead of silently degrading all the way to Claude Code's
# 10s hook timeout (silence, the same fail-open every other resolution failure already has). That
# closes the many-line half of the residual this class used to name; the one full-line `read` of a
# single config line remains a residual at every depth (see below).
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
# can break — at most one very long line, read once per `resolve_repo()` call, not further
# processed (the same one-line `read` cost applies to a depth-0 line too — the length cap is
# checked only AFTER that `read` already has the whole line, so it does not avoid the read itself;
# since #435, though, once read, an over-cap depth-0 line is denied outright before it can ever
# reach the SLOW TRIM this residual is really about — see above and `cfg_trim()`'s own header
# comment). Every depth-0 top-level candidate is
# still always read in full, so none of these four axes can ever mask a pre-#304/#305 route WITHIN
# ONE RESOLUTION. All four axes, and the uncapped depth-0 read itself, are bounded PER
# `resolve_repo()` call, never across the whole hook invocation: since #269 (below), this hook calls
# `resolve_repo()` once for the SESSION checkout and once MORE for every push segment (or, since #448, alias-candidate segment) whose own `-C`
# value resolves a checkout of its own, so a single command naming enough such resolved `-C`
# targets — each supplying its own at-cap-but-legal include content, or its own large top-level
# file — multiplies this same bounded work across resolutions exactly as it already multiplies the
# uncapped depth-0 read; since #435, though, `check_deadline()` (see "Analysis deadline (#435)"
# below) is sampled inside `cfg_parse_file()`'s own read loop on every line, for every
# `resolve_repo()` call across the WHOLE hook invocation, against one deadline computed once at hook
# start — so this accumulated, per-resolution-uncapped work now denies with the fixed deadline
# reason well before it can cross Claude Code's own hook timeout, closing this residual rather than
# leaving it open. See
# `cfg_parse_file()`'s own header comment for where every budget is spent. Any failure at
# any step leaves both branch values, and the config-derived variables, empty — never an error,
# never a non-zero exit from this hook on that account alone. (The depth-0 line cap and the
# unparseable-header deny of "Section headers and same-line keys (#510)" below are deliberate denies,
# not failures.)
#
# Section headers and same-line keys (#510). Git reads whatever follows a section header's closing
# bracket on that line as variables of that section (`[alias] p = push`, `[remote "origin"] push =
# HEAD:main`), so cfg_parse_file() splits every header line into the header and the rest of the line:
# the rest goes through the ordinary comment strip and key/value split, under the section the header
# just set. The header's end is found on the RAW line, before the comment strip, the way git's grammar
# does: a `]`, `#` or `;` inside a quoted subsection stays part of its name (`[remote "a]b"]`,
# `[remote "back#up"]`, `[alias "zq;p"]`), and only keys and values are truncated at a comment marker.
# The section name is matched case-insensitively and may be followed by any run of blanks or TABs
# before the quote, or written in the legacy dotted form (`[remote.origin]`, `[branch.featx]`), or in
# the mixed form git also reads (`[branch.v1 "2"]` is the branch `v1.2`, `[remote.my "fork"]` the
# remote `my.fork`); `remote` and `branch` headers, and a quoted `includeIf`, are rewritten to the one
# canonical `[name "sub"]` text the section arms accept (the mixed form as `<dotted part>.<quoted
# part>`), so these spellings read the same section the quoted form does. `alias` headers need no
# rewrite: every alias spelling, the mixed `[alias.x "y"]` included, already reads its keys under one
# name-independent key. A dotted or mixed `includeIf` is never followed (git conditions need a colon).
# A UTF-8 byte-order mark at the start of a config file's first line is skipped, as git skips it: only
# the first line of each file opened (depth 0, an include, the global config) that reaches the strip
# is tested, by a byte-literal parameter expansion, so a BOM can no longer hide the file's first
# header. An included file's over-cap first line is skipped before the strip, so its next line is
# tested instead; a strip only ever adds reads.
# A header line this hook
# cannot classify denies with the fixed text of `deny_too_large confighdr`, which echoes no input:
#   - a chained header (`[core] [remote "origin"] push = HEAD:main`, or `[core] [user]`);
#   - text after a quoted subsection's closing quote that is not the closing bracket
#     (`[remote "origin" ] push = HEAD:main`, which git itself refuses);
#   - an escaped closing quote followed by more text (`[remote "a\"] push = HEAD:main"]`);
#   - junk or a missing blank before the quote, or whitespace inside a plain name (`[remote x
#     "origin"]`, `[remote"origin"]`, which git itself refuses);
#   - a backslash in a remote or branch subsection (git drops it, so `[remote "or\igin"]` is the
#     remote `origin`, which this hook would read as another name);
#   - an uppercase letter in the dotted part of a remote or branch header, dotted or mixed (git
#     lowercases it; a quoted subsection keeps its case, so `[remote "Upstream"]` reads normally).
# The last two are real catches; the junk-before-the-quote shapes only deny a config git itself
# refuses. Deliberate over-blocks: a chained header git accepts, in any file at any depth (an
# `includeIf` target that would not match included), a push with an explicit refspec or a non-push git
# command that reads such a file, a remote or branch name holding a backslash (git refnames cannot
# contain one), and any section whose quoted name ends in an escaped backslash and is followed by
# anything on the same line, a key, a comment or trailing blanks (`[core "x\\"] foo = bar`, which
# git reads). Cost: a fixed number of parameter
# expansions per header line, linear in the number of lines, run after the depth-0 line cap, the
# depth >= 1 budgets and the length skip, with no loop and no budget of its own and at most three
# `cfg_trim()` calls per line. A header line with a same-line key costs more than a key line of the
# same length; the per-line `check_deadline()` sample bounds the total, and the deadline fails closed.
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
# `--work-tree` (detached or `=`-attached); a `GIT_DIR=`, `GIT_WORK_TREE=`, or `GIT_COMMON_DIR=`
# assignment preceding `git` in the segment (the bare-prefix form, or the same behind an `env`
# prefix word); and, since #433, a push segment in the SAME Bash command as any OTHER segment whose
# resolved command word is `cd`/`pushd`/`popd`/`chdir`, or an `export`/`declare`/`typeset`/`local`/
# `readonly` segment (or a bare assignment) naming a GIT_REPO_ENV_VARS member — whatever the order
# of the two segments (see the "xseg" paragraph below for the mechanism). The deny reads nothing
# NEW from the untrusted value beyond what is already read
# above — GIT_REPO_OPTS/GIT_REPO_ENV_VARS membership, the PATH_ERE predicate, and the lexical
# session-equivalence check are all string comparisons; no filesystem path is read to reach this
# verdict. Over-blocking, deliberate: a `-C` into another checkout is denied whatever the push
# DESTINATION is, even one that is not that checkout's own default branch either; any
# `--git-dir`/`--work-tree`/`GIT_*` redirect is denied even when it points BACK at the session
# checkout itself (this hook never reads the redirected path to find out); and a literal `-C ..` or
# `-C "$PWD"` is denied (`..` is not lexically `.`, and a literal `$PWD` string token is not itself
# lexically equal to the session's own resolved cwd, even when the session actually runs from
# `$PWD`). Fail-closed (#433): a push segment in the SAME Bash command as any OTHER segment whose
# resolved command word is `cd`/`pushd`/`popd`/`chdir`, or an `export`/`declare`/`typeset`/`local`/
# `readonly` segment (or a bare assignment) naming a GIT_REPO_ENV_VARS member or one of #439's
# command-line-config names (GIT_CMDCFG_ENV_VARS, or a GIT_CMDCFG_ENV_PREFIXES-prefixed name), is
# ALSO denied outright as unresolved, whatever the order of the two segments in the command — see
# the "xseg"
# paragraph below for the mechanism, and "Documented over-blocking classes"/"Documented
# under-blocking classes" below for what this closes and what remains open. Whether git itself
# accepts an abbreviated long option (e.g. `--git-d <path>` for
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
# only). Both residuals this paragraph used to name, a git alias that expands to `push` and an inline
# `HOME=`/`XDG_CONFIG_HOME=` relocation of the global config this hook itself reads, are closed since
# #448 (see "Fail-closed: git aliases and config relocation (#448)" below). (The simple quoted or escaped option spelling, `git "-c" k=v push`, and a `-c` value whose
# quoted text holds a space and an odd count of one quote character are caught since #449; the forms
# that stay open are listed in "Fail-closed: a segment the tokenizer cannot follow (#449)" below.)
#
# Fail-closed: a segment the tokenizer cannot follow (#449, absorbing #451). This hook splits a
# segment on whitespace and strips quotes only to resolve a command word, so a quoted or escaped
# option, a quoted value containing a space, or an `env` option that takes a value can make it lose
# track of the segment while git itself still pushes. Three triggers in emit_segment() fail closed,
# each through the #292 "unresolved" deny with one FIXED reason (never command text): (a) in git's
# option slot, a token carrying a quote or backslash whose unquoted form starts with `-` —
# `git "-c" k=v push`, `git \-c k=v push`, `git "--git-dir=../other/.git" push origin develop`,
# `git -"c" k=v push`, `git '-c' k=v push` — reason `quoted or escaped git option`, tested with
# strip_quotes() (not normalize(), which keeps only the last path component); the same reason also
# covers the VALUE of a global option other than -C that the whitespace split cut in two (`git -c
# "user.name=A B" push origin feature/x`, `git "-c" "a b" push ...`, `git --namespace "a b" push
# ...`) and an attached option whose value was cut (`git --exec-path="a b" push ...`), where the
# leftover fragments would otherwise become the subcommand and drop the segment — the -C value is
# deliberately exempt, because failing closed there would deny the harness's own `git -C "<path with
# a space>" push`; (b) in the command prefix, an
# assignment (or an `env -u` value, or an attached `-uNAME`) with an odd count of `"`, an odd count
# of `'`, or a trailing backslash — the whitespace split cut a quoted or escaped value in two
# (`X="a b" git push origin main`, `X='a b' ...`, `X=a\ b ...`) — or, after a prefix word, a
# quote-bearing token that reads as an option or an assignment once unquoted (`env "X=a" git push
# ...`, `env "-C" ../other git push ...`), reason `quote or escape in the command prefix`; the
# command-word candidate itself is never a trigger, so heredoc or commit prose such as `Don't let
# git push skip the guard` stays silent; (c) after an `env` prefix word, any option outside
# PUSH_ENV_NOVALUE_OPTS (skipped alone) and the PUSH_ENV_UNSET_OPTS forms (`-u NAME`, `--unset
# NAME`, `-uNAME`, `--unset=NAME`, skipped with their value) — `env -C <dir>`, `--chdir=<dir>`,
# `-S <string>`, a clustered `-iu`, an abbreviation — reason `unsupported env option`; which
# options a given GNU or BSD `env` accepts is UNVERIFIED here, which is why the allowlist is
# narrow. A trigger denies only when lost_push() says the rest of the segment could still be a
# push — one token naming both git and push, or a token naming git followed only by option words
# (and the values of git global options) and then a token naming push — so `X="a b" git status`,
# `GIT_AUTHOR_NAME="A B" git commit -m "fix push"`, `git "--no-pager" log --grep push` and `env -C
# <dir> git status` keep no opinion. The two split-value triggers (a global option VALUE or attached
# option cut by the whitespace split) use a looser gate, armed == 2: the fragments after the cut are
# junk, so the walk never disarms on a non-option word and never applies the option-value skip (a
# fragment such as the -c" of `-c "k=a b -c" push` could otherwise swallow the real push), and ANY
# later token naming push counts. When the gate says no, the walk behaves exactly as before. A cut
# push keeps its `-cut-push-` sentinel, command-line git config (#439) keeps its own message, and
# an earlier #292 reason (`GIT_DIR=`) keeps precedence over the new reason; all three still deny.
# Every rule only adds denies, with one exception: `env -u git push origin main` and `env --unset
# git push origin main` no longer deny, because `-u`/`--unset` now consume `git` as their value and
# the command real `env` runs is `push`.
# Deliberate over-blocking, each measured rc 2: `X="a b" git -C ../x push-docs`, `sh -c 'FOO=1 git
# push origin feature/x'`, `HOME="/a b" git push origin feature/x`, `sudo "-u" root git push
# origin main`, `env -C . git push origin feature/x`, `env -iu X git push ...`, `env --ignor git
# push ...`, a lone `env - git push ...`, `git "--no-pager" push origin feature/x`, the looser
# split-value gate's `git -c "user.name=A B" commit -m "fix push"` and `git --namespace "a b" log
# --grep push`, and a heredoc or
# prose line led by a markdown bullet (`- env -C ../other git push origin x`, scanned as its own
# segment, where `-` is a PREFIX_WORDS member so the command-word exemption does not apply; write
# such text with an editor tool and `git commit -F <file>` instead). The
# harness's own shapes are unaffected: `git -C "<worktree>" push -u origin "claude/<n>-<slug>"`
# consumes the quoted `-C` value with its option. Residuals this leaves, each measured rc 0: a
# quote or escape split that keeps an EVEN count of the same quote character, which the odd-count
# test cannot see (`X="a'"'b c' git push origin main`, `X="\" x" git push origin main`,
# `X="a\" b" git push origin main`, `env -u "a'"'b c' git push origin main`, an option value `git -c
# "k=a'"'b c' push origin main`); a quoted `-C` value containing a space (`git -C
# "../a b" push origin main`, rows (b), (d) and (j) below, unchanged), which also hides any later
# option such as a `-c` after it (`git -C "../a b" -c "k=x y" push origin main`, and `git "-C"
# "../a b" push origin main`, are both rc 0); an
# assignment whose quoted value contains `;`, `&`, `|`, `(`, `)`, `{`, `}`, a backtick or a newline
# (`X="a;b" git push origin main` — the split-off segment starts with the closing-quote word, which
# as a command-word candidate is never checked); a `repeat` count containing a space (`repeat "2 3"
# git push origin main`); a lost segment that changes directory (`X="a b" cd ../x && git push
# origin trunk` — not added to the cross-segment rule above); and the git-alias form and inline
# `HOME=`/`XDG_CONFIG_HOME=` relocation of #448. hooks/agent-boundary.sh applies the same env arm and
# command-prefix triggers with a role verdict (see its header), not the push-reachability gate here.
#
# Fail-closed: a runtime expansion in the command prefix or the git options (#508). The command word
# is resolved from the literal token, but a word holding a runtime expansion may expand to nothing (or
# to several words) before the shell runs it, so `$X git push origin main` ran the push while the walk
# saw a non-git command word. An EXPANSION WORD is a token whose basename (the part after the last `/`)
# holds a dollar sign followed by a name character, a digit, a special parameter (`@ * # ? ! $ -`), one
# of zsh's expansion flags (`= ~ ^`, which expand to nothing for an unset name), an apostrophe or a
# double quote: `$X`, `$1`, `$@`, `$=X`, `"$X"`, `a$X`, `$''`, `$""`, `$'A=b'`. The predicate,
# rx_word() over rx_re, is quote-blind (`'$X'` and `\$X` count) and a lone `$` never counts; the
# directory part never counts, so `$D/git push` still resolves by its basename. `${...}`, `$(...)` and a
# backtick are not expansion words: the segmenter cuts at them. Since #508, (a) in command position an
# expansion word is SKIPPED as a possibly-empty prefix word (PREFIX_WORDS itself is unchanged), so the
# real command word behind it still resolves: `$X cd ../other && git push ...` is a cd, `$X git zqp ...`
# an alias candidate. The trigger is an expansion word in command position, in the dash slot of a prefix
# word (`sudo -$X`), as the value of `env -u` (detached or attached), or an assignment AFTER a prefix
# word (`env X=$Y git ...`); a bare assignment before any prefix word (`X=$Y git push ...`) is never
# word-split and never a trigger. The first trigger is remembered, and after the walk, when
# lost_push() says the rest of the segment could still be a push, the segment denies as UNRESOLVED with
# the fixed reason `runtime expansion in the command prefix` (an earlier #292 reason, command-line git
# config and a cut push keep their own precedence). A pure-expansion command word may be a runtime-built
# git (`$G push origin main`, whose raw stdin holds no git text), which is why the raw-stdin fast path
# below also admits a dollar sign together with `push`. (b) In the git option slot an expansion word is
# skipped the same way (`git $X push origin main`, `git -$X push ...`, `git $'-c' core.pager=cat push
# ...`, `git $X'push' origin main`) and remembered; after the subcommand loop the segment denies with
# the fixed reason `runtime expansion in the git options` when that word itself names push or the
# split-value gate (armed == 2: an expansion may stand for any number of options and values) finds one
# after it. ANSI-C (`$'...'`) and locale (`$"..."`) words in the option slot or the subcommand position
# are treated by one rule. A word that is EXACTLY one segment with a plain body (starting with a letter,
# digit or `_`, then letters, digits, `_`, `.` or `-`) is read as that name and substituted into the token list, so `git
# $'zqp' origin main` looks up the alias zqp and `git $'push' origin main` is a push, and every later
# scan sees the name. Any OTHER word there that holds a dollar sign followed by a quote (`p$'ush'`,
# `$'p'$'ush'`, `"p"$'ush'`, `z$'qp'`, a backslash body such as `$'\x70ush'`, mixed or unpaired quotes,
# an attached option value such as `--git-dir=$'/a b'`) fails closed under the git-options reason (an
# earlier #292 reason such as `--git-dir`, or command-line config, keeps its own precedence, as in (a)),
# whether or not a push follows: the shell value of such a word is never computed. That is a deliberate
# over-block that includes `git st$'atus'` and `git $'a b' status`. The check is two `index()` calls per word
# (linear in the word), and the value of a detached `-c`, `-C` or `--config-env` option is consumed with
# its option and never inspected, as before. When no subcommand follows the skipped words, the first skipped word that does not start with a
# dash is the candidate subcommand (the word taken before the skip existed; none when every skipped
# word is dash-led, so a cut push still fails closed), and the #448 alias and relocation scan covers the
# whole option slot, since an expansion may hide where it ends. A git alias behind the
# skipped word is judged by the #448 route as usual. (c) The segmenter
# cuts a record at `${`, `$(` and a backtick, so an `env -S` string such as
# `env -S'${X}git\_push\_origin\_main'` arrives in pieces and its unsupported `env` option (#449) was
# judged without the tail: for a record that holds one of those three and names `env`, lost_push() is
# run once over the whole record's tokens, and the unsupported-env-option trigger fires on it too.
# Every rule only adds denies. Deliberate over-blocking, each measured rc 2: `$DOCKER push img`, `$X
# pushd ../other`, any word that merely contains push after a pure-expansion command word, `git $X log
# --grep push`, `env FOO=$BAR git push origin feature/x`, `'$X' git push ...` and `\$X git push ...`
# (quote-blind), an unsupported `env` option in a record holding `${`, `$(` or a backtick that also
# holds `git ... push`, and a heredoc or multi-line line that starts with an expansion word followed
# by `git ... push` (scanned as its own segment, like every line). A commit message or prose with the
# expansion mid-line (`git commit -m "$X git push origin main"`, `echo $X git push ...`) keeps no
# opinion. Residuals, each measured rc 0: a `${...}`, `$(...)` or backtick prefix (the text after its
# close is judged precisely, so an injected prefix is not failed closed), a runtime-built git
# subcommand (`git $S origin main`), and `eval "$c"`. (A runtime-built refspec destination, `git push
# origin HEAD:$B`, was a residual until #517: it now denies, see the next paragraph.)
#
# Fail-closed: a runtime expansion in the push destination (#517). A destination the shell builds at
# run time (`B=main; git push origin HEAD:$B`, `"HEAD:${B}"`, `$B`, `+HEAD:$B`, `refs/heads/$B`) cannot
# be judged against the default branch from its text. The tokenizer's dest_word() reads the
# DESTINATION of every push-rest word (the text after its first colon, else the text after an optional
# leading plus, else the whole word): a destination with no dollar sign is unchanged; a destination
# that is EXACTLY one plain ANSI-C or locale segment (`$'main'`, `HEAD:$"main"`, `+$'main'`, the plain
# body rule of the #508 paragraph above) is read as the name it spells, so it denies with the ordinary
# default-branch line; any other destination holding a dollar sign becomes the single character dollar,
# and evaluate_segment() then denies it with the fixed reason `runtime expansion in the push
# destination` (kind rxdest) — never echoing the word. That covers every refspec position at two or more
# non-option arguments and the lone argument at one (`git push $B`). A word that is not an option and is
# longer than the awk variable tok_max is rewritten the same way, since no real remote, branch or refspec
# is that long and the bash side splits a refspec at its first colon with pattern removals whose cost
# grows with the square of the word on bash 3.2; a -C path longer than that denies as outside the
# worktree shape for the same reason. A source-only expansion stays judged by its literal destination
# (`git push origin $B:feature/x`, `git push origin $'feature-x'`, no opinion), as does an expansion in
# the REMOTE position at two or more arguments and the value of an option such as `-o $X`. Deliberate
# over-blocking, each measured rc 2: `git push origin "$(git branch --show-current)"` (push `HEAD`
# instead), `git push "$REMOTE"` (the lone argument is judged as a possible destination),
# `refs/tags/$T`, `$'feature/x'` (a slash is outside the plain body rule), and any non-plain
# dollar-quote word anywhere in a segment the tokenizer lost (`git "--no-pager" log --format=$'%h'`; in
# a lost segment the slot boundaries are unknowable, so emit_alias_lost() reads a plain word as the
# alias name it spells and fails any other closed with the git-options reason). Residuals, each measured
# rc 0: an expansion in the remote position at two or more arguments (including an unquoted `$R` that
# word-splits into refspecs), `eval "$c"`, and a runtime-built subcommand (`git $S`). The segmenter
# still cuts a record at `${`, `$(` and a backtick (owned by a separate issue); the dollar-sign
# remnant it leaves in a destination (`git push origin ${B}:main`) now denies through this rule.
#
# Fail-closed: a value-taking option of a prefix word (#518). A dash option of nice, sudo, stdbuf, exec,
# xargs or time (PREFIX_VALUE_WORDS) may take the NEXT word as its value (`nice -n 5 git push origin
# main`, `sudo -u root git push …`); the walk skips the option but not the value, so the value became the
# command word and the push went unseen. This hook models no prefix command's option grammar. While the
# most recent prefix word is in PREFIX_VALUE_WORDS, a token starting with a hyphen that is followed by a
# word not starting with one is a trigger: the rest of the segment AFTER that word (never the word
# itself, so `sudo -E git push origin feature/x` is still judged on `git`) is read with the segment's
# memoised lost_push(), and a hit denies as unresolved with the fixed reason `option value in the
# command prefix`, never echoing input. The precedence is the #449 triggers': an earlier #292 reason,
# command-line config (`-cmdline-config-`) and a cut push (`-cut-push-`) each keep their own deny. When
# no push can follow, emit_alias_lost() runs at most once per segment (al_done), starting one token later
# than the #449 triggers so that only tokens after the value word count toward its names-git gate:
# `nice -n 5 git zqp origin main` under a push alias denies through the #448 alias line, while `sudo -E
# git commit -m "fix include path" && git push origin feature/x` keeps no opinion. An expansion word in
# command position opens no value context here: #508's post-walk check already covers it. A later prefix
# word outside the vocabulary closes the context (`nice bash -x deploy.sh git push origin feature/x`
# keeps no opinion), and interpreter words stay out of it. Cost: O(1) checks per dash token and at most
# one memoised lost_push() and one emit_alias_lost() per segment, all inside the tokenizer and so inside
# T_prefix, bounded by PUSH_CMD_MAX_BYTES. Every rule only adds denies. Over-blocking, each measured rc
# 2: `nice -n 5 git push origin feature/x`, `sudo -u root git push origin feature/x`, `sudo -u root
# bash -c "echo git push origin feature/x"`, and `nice -n 10 git log --grep alias` (the segment names
# git behind the option value and a later word names an alias). Residuals, each measured rc 0: an
# interpreter prefix word's option (`bash -o pipefail -c 'git push origin main'`), a launcher outside
# PREFIX_WORDS (`timeout 5 git push origin main`), and a value-context segment that changes directory
# (`nice -n 5 cd ../x && git push origin trunk`), because the cross-segment directory rule keys on the
# segment's resolved command word, which here is the option value.
#
# Fail-closed: git aliases and config relocation (#448, absorbing #450). This hook once recognised only
# the literal subcommand `push`, so a git alias that expands to push hid it (a config-file alias such
# as `zqp = push` under `[alias]`, run as `git zqp origin main`, or `git -c alias.p=push p origin
# main`), and an inline `HOME=<dir>`/`XDG_CONFIG_HOME=<dir>` moved the global config this hook reads.
# Since #448: (a) every git segment whose subcommand is not `push` is an ALIAS CANDIDATE. The
# tokenizer prints one `ALIAS` line for it (its `-C` value when exactly one, and the lowercased
# subcommand) and the driver loop looks `alias.<subcommand>` up in the alias records cfg_parse_file()
# captures from the SAME routes the push routes read: the system, global, repo-local and include
# files, plus a `-C` target resolved under the PATH_ERE predicate exactly like a push segment's (the
# session's own records are restored for every segment, so an earlier `-C` segment never hides them).
# Git never lets an alias shadow a built-in command, so the lookup alone decides and there is no
# built-in list. The plain `[alias]` form, `<name> = <expansion>`, is matched by name (folded to lower
# case on both sides; git matches case-sensitively, so folding only over-blocks). The subsection forms
# (`[alias "<name>"]` with any run of blanks before the quote, an escaped or odd name, or the deprecated
# `[alias.<name>]`, each with `command = <expansion>`) are NAME-INDEPENDENT: the name is never read, so no
# spelling of it can be misread, and a checkout whose readable config holds a subsection alias whose
# command would deny under the classification below denies EVERY alias candidate resolved to it.
# Classification, after treating
# git-config whitespace escapes (a backslash then t, n or b) as word breaks, then quote and backslash
# stripping and lowercasing: the first word
# of the expansion denies when it is `push`, is empty, starts with `!` (a shell alias, opaque) or `-`
# (an option hides the subcommand behind it), or names another defined alias (a chain this hook does
# not follow); a value ending in a backslash (a continuation the line parser never joins) also denies;
# a raw CR strictly inside an alias line (which the line reader would delete, fusing the words around
# it) is recorded as an opaque `!` value, so it denies too; any other value is no opinion. The deny line names only the fixed source label (`.git/config`, `your
# global git config`, each optionally ` (via include)`) with `(blocked: git alias may push)`, never the
# alias name, its value or any command token. (b) Config this hook cannot read denies the candidate
# with the fixed text `(blocked: unreadable git config may define an alias)`: an inline
# `HOME=`/`XDG_CONFIG_HOME=`/`GIT_CONFIG_GLOBAL=`/`GIT_CONFIG_SYSTEM=` assignment (bare or behind
# `env`; GIT_CFG_RELOC_ENV_VARS), a command-line config token naming alias or include (`-c alias.p=…`,
# `-c include.path=…`, `--config-env=alias.p=…`, a `GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>` pair, or
# the value of a `-c`/`--config-env` option or a `GIT_CONFIG_*` assignment holding a dollar sign, which
# may build the key at run time, or any `-c`/`--config-env`/`GIT_CONFIG_*` segment of a record holding a
# backtick, which cuts the segment inside the value),
# and an export or bare assignment of any of those names in ANY other segment of the command (the
# tokenizer's `-xcfg-` marker). (c) On a PUSH segment, an inline `HOME=`/`XDG_CONFIG_HOME=` (the #450
# half) denies with the #439 command-line-config message, and an `export HOME=…` or bare
# `XDG_CONFIG_HOME=…;` in another segment denies through #433's cross-segment rule with the reason
# `HOME or XDG_CONFIG_HOME set earlier in this command`. An inline `GIT_CONFIG_COUNT=1 git st`, with
# no alias or include text and no dollar sign, stays no opinion by design. (d) The #449 interplay: a segment the
# tokenizer lost (a quoted or escaped option, a quote-split assignment, an unsupported `env` option)
# that lost_push() says is no push no longer drops silently. emit_alias_lost() hands the driver EVERY
# remaining token as a candidate alias name (a token that is exactly one plain ANSI-C or locale segment
# as the name it spells, #517; for a loss in the command prefix only when a later token names git), and
# fails the whole segment closed when any other token holds a dollar sign and a quote, and denies outright when a relocation or command-line-config name was assigned (quoted
# spellings included: `env "HOME=<d>" git p`, `env -S "HOME=<d> git p"`) or any token mentions alias or
# include, so `HOME="/tmp/a b" git p origin main`, `X="a b" git zqp origin main` and `git "--no-pager"
# zqp origin main` all deny while `X="a b" git status` stays no opinion. Union semantics, as
# everywhere in this file: an alias in any candidate file counts, whatever the file order. Containment:
# the alias lookup reads only the config files the push routes already read, plus the one `-C` path
# class above under the same predicate; alias names and values are only compared (one awk pass over
# a here-string), never executed, expanded or echoed. The raw-stdin `*push*` fast path is gone, because
# an alias push carries no `push` text; the early exit now also lets an ALIAS line through.
# Over-blocking, deliberate, each measured rc 2: any `!` shell alias run as a subcommand (`git up`
# with `up = !git pull`), an alias whose first word is a git option, a chain, and any push alias even
# to a feature branch; an alias NAMED like a built-in and expanding to push (`status = push`), which
# git itself ignores but this hook denies as `git status`; relocation or inline alias/include config
# on any git segment; an export of `HOME`/`XDG_CONFIG_HOME`/`GIT_CONFIG_*` anywhere in a command that
# also has a non-push git segment; a heredoc or commit-message line that starts `git <alias name>`; a
# lost segment whose text mentions alias or include (`X="a b" git log --grep=include`), or merely contains a
# relocation or config assignment as a substring (`-m "HOME=/x"`, `--grep=GIT_CONFIG_KEY_`; each measured
# rc 2); a self-referential
# alias named like a built-in (`log = log --oneline`, which git ignores) read as a chain, so `git log`
# denies; a dollar sign in a command-line config value, or a backtick anywhere in a record holding such
# config, on a non-push git segment; a checkout with a push-ish subsection alias, where every alias
# candidate denies whatever its subcommand; and an
# over-cap config line or the analysis deadline, which now deny non-push git commands too, still with
# their "denies this push" or "denies this command" text. Under-blocking residuals, each measured rc 0:
# an alias defined only in another checkout's config, reached by `cd`, an unresolvable `-C`,
# `GIT_DIR=` or `--git-dir`; a `git-<name>` external on `PATH` (or via `--exec-path`/`GIT_EXEC_PATH`);
# `env -u XDG_CONFIG_HOME`; the `HOME` that `sudo` sets; a subcommand
# built at runtime (`S=p; git $S`; an ANSI-C or locale spelling in the option slot, or anywhere in a
# lost segment, is read only as a whole plain word and otherwise fails closed, see the #508 and #517
# paragraphs; a locale word `$"zqp"` is read
# untranslated, so a bash locale catalog that translates it is not followed); an alias run through
# `xargs` or a script file; and `help.autocorrect`, where the hook says rc 0 for a mistyped
# subcommand (UNVERIFIED whether git then runs push); a relocation or config name built at run time
# (`V=HOME; env "$V=/x" git p`, the same class as `S=p; git $S`); a variable-setting builtin this hook does not
# track (`read HOME <<< /x; git p`, `printf -v HOME /x; git p`, the same class #433 lists for GIT_DIR);
# and a Codex session whose workdir holds the alias: an alias candidate never sets `saw_push`, so the
# #494 workdir check does not run for it (the same class as the `cd` residual above).
#
# Fail-closed: Codex shell workdir (#494). Codex's shell tool takes its own `workdir` parameter,
# which is NOT part of the PreToolUse payload (ADR 0002 U9, confirmed live on Codex 0.156.1: the
# payload carries only `tool_input.command` and the session `cwd`), so a push run through it
# executes in a checkout the command-string analysis above never sees. For a Codex-shaped payload
# (a non-empty `turn_id`; a Claude Code payload has none and never reaches this code) whose push
# would otherwise get no opinion, this hook therefore reads the tail (at most
# PUSH_TRANSCRIPT_TAIL_BYTES) of the rollout file the payload's `transcript_path` names and scans
# EVERY model tool-call record in that window — a `response_item` of type `custom_tool_call`,
# `function_call` or `local_shell_call` — whether or not an `*_output` record answers it: a code-mode
# `exec` cell can yield (its output record written) and keep running, so its inner push can fire
# long after its output exists, and completion therefore proves nothing. The live evidence this
# relies on: Codex 0.156.1 appends the call record to the rollout BEFORE PreToolUse fires for the
# inner command, and the payload carries no key that joins the hook call to its record, hence
# "every record", not "the newest". Each record's call text (code-mode JS `input`, `arguments`, or
# `action`, JSON-serialised when not a string) is scanned for EVERY occurrence of a
# PUSH_WORKDIR_KEYS name. The push is allowed only when every occurrence is `null` (never
# `undefined`: JS lets that identifier be shadowed) or a plain `"…"`/`'…'` string literal (no
# backslash, closed, then a comma or brace) that is LEXICALLY the session checkout
# (`is_session_checkout_path()`, the same test #292 applies to `-C`). Window edge: a line in the
# window that does not parse as JSON but contains a workdir key (a record cut by the window start,
# or garbage) is treated as a non-literal workdir; and when the window's first line does not parse
# and is at least half of PUSH_TRANSCRIPT_TAIL_BYTES long (UTF-8 bytes), the hook denies outright —
# a record cut that deep may have hidden its workdir. Otherwise it denies with one of five FIXED
# reasons: the workdir names another directory, the workdir is not a plain string literal (a
# variable, a concatenation, an escaped or shorthand form, `undefined`), the transcript is missing
# or unreadable, a transcript record exceeds the hook's read window, or the window holds no tool
# call at all (also the verdict for a jq failure or an empty pipeline output — nothing ever fails
# open past this point). An earlier deny of any class keeps precedence; the block only ever ADDS a
# deny. Containment: the transcript path is host-provided (never taken from the command string) and
# is used only as a `[ -f ]`/`[ -r ]`-guarded redirect into `tail -c` (never in any process's argv);
# its content is partly model-written and so untrusted, and is parsed as DATA by jq and awk, compared
# by string equality only, never `eval`ed, executed, or opened as a path, and never echoed — the
# deny messages are fixed strings. Over-blocking, deliberate: a workdir passed as a variable, or as
# `undefined`; a subdirectory or a symlinked spelling of the session path; ANY foreign or non-literal
# workdir in ANY call record still inside the window — an earlier, completed, unrelated call, or a
# non-push call, included — which keeps denying every later Codex push until it leaves the window;
# any non-literal mention of `workdir` anywhere in a code-mode program, even on a call that is not
# the push; an unparseable line in the window that mentions a workdir key; a window whose first
# line is an unparseable record of at least half the window; a window holding no tool call, as when
# very large inner-call output pushed every call record out of it; and a Codex session that writes
# no rollout at all (an interactive `--ephemeral` run, UNVERIFIED here), which denies every push. The
# remedy is the same each time: issue the push with no `workdir`, from a session started in that
# checkout, once the offending record has left the window. Under-blocking, documented residuals: a
# call record that lies wholly before the window, or is cut at the window start with its workdir
# before the cut and less than half a window of it left in view, while the window still holds
# another tool call (more than half a window of later records has pushed it out of view); a workdir
# key built at runtime or written with JS identifier or string escapes; a cwd-like parameter under
# any other name; a Codex that writes the call record only after the hook runs
# (every push would then deny, loud and fail-closed, not a bypass); and the existing `jq`-absent
# fail-open below.
#
# Never invokes `git`, `gh`, or anything else derived from the untrusted command string; never
# `eval`s; never writes a file. Since #269, this hook reads exactly one class of filesystem path
# taken from the untrusted command string — a push segment's own `-C <path>` value (since #448 also
# the `-C <path>` value of any non-push git segment, an alias candidate), and ONLY when
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
# not an evasion this hook introduces. Since #494, this hook ALSO reads a FIFTH class of path, on a
# Codex-shaped payload only: the rollout file named by the host-provided `transcript_path` (see
# "Fail-closed: Codex shell workdir (#494)" above), read through a `[ -f ]`/`[ -r ]`-guarded
# redirect into `tail -c`, parsed as data only, and never used as a path to anything else. The
# untrusted `-C` value itself is fed only to
# `grep` (a here-string, never a piped writer — assertion 1.7) as data, and to shell builtin `[ -f
# ]`/`[ -d ]` tests; resolving it caps its own upward walk at exactly one level (see
# `resolve_repo()`'s `MAX_DEPTH` parameter below), so that value never reaches `dirname`'s argv —
# or any other process's argv — is never `eval`ed, and is never opened for writing. bash + POSIX
# awk only — jq is not needed to PARSE the command (unlike its two siblings this hook parses
# `tool_input.command` with awk, not a JSON library), but the raw-stdin fast path below still gates
# on `jq`'s presence for the few scalar field reads (`tool_name`, `permission_mode`,
# `tool_input.command`, `cwd`, and, since #494, `turn_id` and `transcript_path`) this hook does
# need, and, since #494, a Codex push also runs one jq pass over the rollout tail (jq 1.5
# builtins only, no regex) — no python, no perl, no GNU-only flags (this
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
# Since #433, FIVE more over-blocking classes, all from the new cross-segment ("xseg") fail-closed
# rule above: any `cd`/`pushd`/`popd`/`chdir` ANYWHERE in a push command denies the whole command,
# including one that comes AFTER the push, one inside a subshell whose own directory change never
# reaches the push (`( cd ../x; true ); git push origin develop`), or one that changes into the
# session checkout itself (session-equivalence is never checked for this rule, unlike the `-C`
# rule above); a quote-blind or heredoc line whose FIRST word is one of those four builtins is
# denied the same way, the same per-line, quote-blind class named above for a heredoc `git push`
# line; an `export`/`declare`/`typeset`/`local`/`readonly` segment naming a GIT_REPO_ENV_VARS
# member denies even when that builtin does not actually export the name (`declare GIT_DIR=x`
# with no `-x`, `export -n GIT_DIR`, or `readonly`, none of which changes what `git` itself would
# see) — this hook does not model export state, only vocabulary membership; a bare assignment
# denies even when the named variable is never actually exported to `git`'s environment later in
# the command; and a RESOLVABLE `-C <path>` push after an unrelated `cd` denies as unresolved when
# nothing else denies it, even though the `-C` value alone would have resolved the push correctly.
# The `-C` resolution and every other per-segment check still run first, in the driver loop, and any
# deny they produce (a default-branch destination, including one resolved through `-C`, an all-refs
# push, a config route, a cut push, or a #292 in-segment reason such as `--git-dir`) keeps
# precedence; the xseg fallback runs only after the loop, and only turns what would otherwise be a
# no-opinion push into an unresolved deny (`push-xseg-deny-inseg-precedence` pins one such case).
#
# Documented under-blocking classes (evasions, named rather than hidden): `$(which git) push`
# (the literal `git` token is never in command position); `eval`/`trap` of a variable- or
# substitution-built payload (`eval "$c"`, `eval "$(printf …)"`) — the same class, since the literal
# `git`/`push` text is never in the string this tokenizer reads; a `repeat` count containing
# whitespace (`repeat "1 + 1" git push origin main` — the tokenizer skips exactly ONE token after
# `repeat`, so a quoted multi-word count is not fully consumed and its own remaining word, not
# `git`, is mistaken for the resolved command word); an interpreter prefix word's value-taking option
# (`bash -o pipefail -c 'git push origin main'`, `bash -O extglob -c …`, measured rc 0; see the #518
# paragraph below); a launcher outside PREFIX_WORDS (`timeout 5 git push origin main`, `ionice -c 2 …`,
# `doas -u root …`, measured rc 0); interpreter indirection outside
# PREFIX_WORDS; a two-token global option NOT in GIT_GLOBAL_OPTS_WITH_VALUE that itself takes a
# separate value, e.g. `git --foo bar push origin main` (the unlisted `--foo` is skipped alone,
# and its separate value `bar` is then mistaken for the subcommand, so the real `push` token past
# it is never reached — this hook opines "no opinion" on the whole segment, not a deny; an
# ATTACHED `--opt=value` global option such as `--git-dir=<path>` does NOT evade this way: the
# generic single-dash-token skip consumes it whole in one step and the subcommand still resolves
# to `push` correctly — neither `--git-dir=<path>` nor an unresolved `-C` value evades WHICH repo
# gets resolved by staying silent about it: both deny outright instead (#292 — see "Fail-closed: an
# unresolvable push target" above); a CR *inside* the raw-stdin `git`
# fast-path literal, e.g. `g<CR>it push origin main` — a conforming JSON writer escapes an embedded
# `\r` as the two characters `\`+`r`, so the raw stdin substring `git` never appears intact and the
# fast path (below) exits before the #270 CR strip ever runs, regardless of the strip's own
# correctness; the resulting command cannot execute as a real `git push` either, so this is
# documented, not fixed (see the fast-path comment below; since #448 a CR inside the push literal, `git
# pu<CR>sh origin main`, no longer evades, because there is no push fast path); since #398, `git PUSH origin main` — the command word is case-folded (so `GIT push
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
# is skipped — except that, since #449, one carrying a quote or backslash whose unquoted form
# begins with `-` (the `-x"` of row (a)) fails closed instead when a push can still follow;
# the first fragment left standing is the subcommand candidate, and the segment is
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
# (a) `git -C "../a-wt-1 -x" push origin trunk` -> rc 2 — `-x"` begins with `-` and carries the
# glued closing quote, so since #449 it fails closed as UNRESOLVED (`quoted or escaped git
# option`) before any `-C` resolution: a push follows it, so the segment could still be a push
# whose real option this hook cannot read. (Before #449 it was skipped as a dash fragment and the
# captured `../a-wt-1` was resolved, naming that directory's own default — a mis-resolution, not
# a containment breach; no row of this list reaches that outcome through a quoted option any
# more.) Controls: the same command with a non-matching first fragment (`../plain-dir -x`) -> rc
# 2, the same reason, and the session alone pushing to `trunk` with no `-C` -> rc 0.
# (b) `git -C "../a-wt-1 foo" push origin main` -> rc 0 — `foo"` normalises to `foo`, not
# `push`: the segment is dropped as unrecognised, nothing is resolved, and a push whose
# destination is literally the session's own default branch gets no opinion (control: the
# session alone pushing to `main` -> rc 2).
# (c) `git -C "../plain-dir -x" push origin main` -> rc 2 — fails closed exactly as (a), as
# UNRESOLVED (`quoted or escaped git option`), whatever the destination is. (Before #449 the
# captured fragment failed PATH_ERE and the deny named `-C path outside the <name>-wt-<n>
# worktree shape` instead; either way this denies.)
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
# literally the session's own default branch. Rows (e), (h) and the two rc-2
# shapes in (j) share the one resolve-a-different-directory outcome that is new to this
# change, and it is a mis-resolution, not a containment breach: the facts applied still belong
# to a directory this hook itself derived and read under the same predicate, never an
# attacker-arbitrary one, but they are not necessarily the facts of the directory the push
# actually executes in (see the containment paragraph above for the qualification this
# residual class requires). Rows (f) and (i) no longer belong to that group: since #439, both
# deny via the command-line-config check before `-C` is ever resolved (see each row's own text
# above), so neither one reaches — or depends on — `../a-wt-1`'s own facts at all; nor does row
# (a) since #449, which fails closed on its quoted option the same way. Since #268 closed the repo-local
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
# residual the depth-0 top-level case below already has too (that one `read` cost is unchanged by
# #435; since #435, though, once read, a depth-0 line over the cap denies outright before the same
# SLOW TRIM this residual is about ever runs on it — see above); every depth-0 top-level
# candidate is still always read in full, with no LINE-COUNT cap of its own, so none of the four can
# ever mask a pre-#304/#305 route WITHIN ONE RESOLUTION — though all four axes, like the depth-0
# read itself, are bounded PER `resolve_repo()` call, never across the whole hook invocation (see
# the "Repo resolution" paragraph above): since #435, `check_deadline()` samples this same read loop
# on every line, for every `resolve_repo()` call across the WHOLE hook invocation, against one
# deadline set once at hook start — so a depth-0 TOP-LEVEL file with very many lines, and a single
# command naming enough resolved `-C` push segments (#269 above) each supplying its own
# at-cap-but-legal include content or its own large top-level file, both now deny with the fixed
# deadline reason well before either can cross Claude Code's own hook timeout, closing this residual
# rather than leaving it open),
# or an
# include value containing an unquoted `#`/`;` (truncated by the same comment-strip every other
# value goes through) — every one of these fails OPEN (silently not followed), never denies;
# `config.worktree` (`extensions.worktreeConfig`) inside any file this hook reads, still never
# followed; and backslash-continued or backslash-escaped config values. (Since #510 the section
# header itself is read the way git reads it: a key on the header's line, the dotted and any-blank
# spellings, and a `#`/`;`/`]` inside a quoted subsection are no longer residuals — see "Section
# headers and same-line keys (#510)" above.) Since #439, a command-line `-c`/`--config-env` option (any key,
# including `-c push.default=…`/`-c remote.<name>.push=…`) and an inline `GIT_CONFIG_COUNT`/
# `GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>`/`GIT_CONFIG_PARAMETERS`/`GIT_CONFIG_GLOBAL`/
# `GIT_CONFIG_SYSTEM` environment assignment, bare or behind `env`, are no longer read-and-ignored
# residuals — every push segment carrying one is denied outright (see "Fail-closed: command-line
# git config" above) whatever the key or destination, and since #448 an inline `HOME=`/`XDG_CONFIG_HOME=`
# relocation of the global config this hook itself reads is denied the same way. What remains
# residual there instead: the quote and escape forms #449 does not catch (see its own paragraph) and
# the alias residuals listed in "Fail-closed: git aliases and config relocation (#448)". (A
# cross-segment `export GIT_CONFIG_*=…` or bare `GIT_CONFIG_*=…;` segment is denied by #433's
# cross-segment rule.)
#
# Since #433, the new cross-segment ("xseg") rule above still leaves these residuals open: a
# directory or `GIT_DIR`-family change made inside a SOURCED file (`.`/`source`) or a script FILE
# invoked from the command, rather than inline in the command string itself; a function or alias
# that itself runs `cd`/`pushd`/`popd`/`export`, defined outside the command being scanned; zsh
# `AUTO_CD` (a bare directory name treated as an implicit `cd`, never itself a `cd`/`pushd`/`popd`/
# `chdir` command word); a directory change whose command word is itself built from a variable
# (`c="cd ../x"; eval "$c"`, or `d=cd; $d ../x`) — the same class the `eval`/`trap` bullet above
# already names (a literal `cd` with a substituted ARGUMENT, e.g. `cd "$(dirname "$x")"`, is still
# a `cd` command word and denies); other variable-setting
# builtins this hook does not track, `read`/`printf -v` and `set -a` paired with a non-bare
# assignment. (`env --chdir=<dir> git push` and `env -C <dir> git push` are no longer residuals:
# since #449 an `env` option outside a short allowlist fails closed when a push can follow.) (Codex's shell `workdir`, which never appears in this hook's payload at
# all (ADR 0002 U9) and so cannot be tracked by any command-string mechanism, is closed since #494
# by reading the rollout instead — see "Fail-closed: Codex shell workdir (#494)" above for what that
# still leaves open: a workdir key built at runtime or written with escapes, a cwd-like parameter
# under another key name, and a call record outside the 1 MiB window while another call is in it.)
#
# This is a tripwire, not a sandbox — branch protection on the
# default branch remains the real backstop, exactly as hooks/git-c-guard.sh and
# hooks/agent-boundary.sh already document for their own scopes.
#
# Contract: read the PreToolUse hook JSON on stdin; print nothing and exit 0 ("no opinion") unless
# the call is a Bash `git push` (or, since #448, a git alias that may push) whose resolved destination is the default branch (or the
# unconditional `main`/`master` fallback), OR whose target repository this hook cannot resolve at
# all (#292 — see "Fail-closed: an unresolvable push target" above), OR whose push segment carries
# git config supplied on the command line (#439 — see "Fail-closed: command-line git config"
# above), OR, since #448, a git command whose subcommand is an alias that may push or that runs under
# config this hook cannot read (see "Fail-closed: git aliases and config relocation (#448)" above), OR
# whose push segment lost the tokenizer — a quoted or escaped git option, a quote or
# escape in the command prefix, or an unsupported `env` option (#449 — see "Fail-closed: a segment
# the tokenizer cannot follow (#449)" above), OR, since #508, a segment whose command prefix or git
# option slot holds a runtime expansion that may hide a push (see "Fail-closed: a runtime expansion
# in the command prefix or the git options (#508)" above), OR, since #435, whose analysis cannot finish inside this hook's own time budget, or that
# reads a git config file with a depth-0 line too long to analyse safely (see "Analysis deadline
# (#435)" below), OR, since #494, a Codex-shaped payload whose shell `workdir` is not provably the
# session checkout, whose transcript cannot be read, whose transcript window holds no tool call, or
# whose window starts with an unparseable record of at least half its size (see "Fail-closed: Codex shell workdir (#494)" above), OR, since #510, a git command that reads a git config file
# holding a section header line this hook cannot split the way git does (see "Section headers and
# same-line keys (#510)" above), in which case print exactly one reason line
# to stderr and exit 2 ("deny"); stdout
# is always empty. Wired in hooks/hooks.json via
# `${CLAUDE_PLUGIN_ROOT}`, with no `if` gate — an `if` filter matches only `tool_input.command`
# constituents after composite splitting and leading-assignment stripping, so it cannot see a
# `git -C <wt> push …`, `env git push …`, or `bash -c "git push …"` form; any `if` here would
# silence this hook for exactly the commands it exists to catch (same reasoning as
# hooks/agent-boundary.sh's own registration — see hooks/hooks.json's `.description`).
#
# Analysis deadline (#435). This hook's own analysis (everything from the tokenizer onward) is
# bounded by a whole-second wall-clock budget, `PUSH_ANALYSIS_BUDGET_SECS` below (5s in
# production), sampled from `$SECONDS` as an elapsed difference from `push_t0` (captured at the very
# top of this script, right after `set -f`): `check_deadline()` denies with a fixed reason
# (`deny_too_large deadline`) the first time `$SECONDS` reaches `push_deadline` (`push_t0 +
# push_budget`) — never by resetting `$SECONDS` itself. The sampling rule this binds on every future
# addition to this file — #439 has already landed entirely inside the awk tokenizer (its own
# "-cmdline-config-" sentinel, covered by `T_prefix` below, the pre-tokenizer cost this
# deadline cannot sample around at all), #449 likewise (its per-token shape checks and at most three
# lost_push() scans per segment, one memoised scan for each of three trigger families, all inside that tokenizer and so inside
# `T_prefix`), #508 likewise (rx_word() is linear in one token; at most two more lost_push() scans per
# segment, both after their loops and never at a trigger; two index() calls per git-slot word for the ANSI-C
# rule; at most one more split of the record plus one
# lost_push() per record; no emit_alias_lost() call is added), #518 likewise (O(1) checks per dash
# token; its lost_push() and emit_alias_lost() calls share the segment's m0 and al_done memos, so no
# scan is added per trigger), and #433 has landed in the awk tokenizer plus one
# constant-cost post-loop fallback: call `check_deadline` as the FIRST statement of every loop whose trip
# count grows with the command string or a config file's own content — never partway through a loop
# body, and never only once at the top of a function that itself contains such a loop. The early
# exit right after the tokenizer, before the deadline is ever sampled, continues only when the scan
# holds a "PUSH" line, an "ALIAS" candidate line (#448) or a `-too-many-dbrackets-`/`-cut-push-`/
# `-cmdline-config-` sentinel — a scan that is empty, or holds nothing but #433's own `-xseg-` or
# #448's `-xcfg-` marker line, exits with no opinion — so a command with no push segment and no git
# alias candidate is never denied merely for being large once it is under the command-size cap below:
# this is the identical verdict the driver
# loop below would reach anyway (nothing it would deny on), just reached without spending any of the
# budget getting there. Since #448 a command with a non-push git segment is no longer in that class:
# it is analysed (config read, alias lookup) and can be denied as too large, still with the "denies
# this command" text. The one step this deadline's sampling cannot reach MID-step is a single depth-0 (top-level)
# config line's own read and trim: `cfg_trim()`'s own pattern matching is not uniformly fast for a
# long whitespace run (see that function's header comment), so instead of merely sampling around it,
# `CFG_TOPLEVEL_MAX_LINE_CHARS` below caps that line's own length outright, checked with the cheap
# `${#cfgline}` before comment-strip or trim ever run on it, and denies (`deny_too_large configline`)
# rather than ever letting an over-cap line reach either one — fail-closed, not silently skipped, so
# a route on the far side of that line is never missed the way an over-budget include's excess
# content already is. A test-only knob, `TBF_PUSH_GUARD_BUDGET_SECS`, is read from the ENVIRONMENT
# only (never from the untrusted command string) and can only LOWER `push_budget` below
# `PUSH_ANALYSIS_BUDGET_SECS` — adopted only when it is exactly one or two ASCII digits and strictly
# less than the production budget; any other value (empty, non-numeric, three-plus digits, or a
# value that is not strictly less) is ignored outright, so this knob can make a fixture deny sooner
# against a small, fast payload, but can never raise the budget or reopen a fail-open path in
# production. Command-size cap (#517): a Bash command longer than `PUSH_CMD_MAX_BYTES` BYTES (counted
# in the C locale by pg_bytes(), so a multibyte payload is not undercounted), once it is past the
# fast path and the plan-mode exit, denies with the "too large to analyse" line before the tokenizer
# or any other use of the command text, because a timed-out hook gives no deny at all: the cap is what
# keeps the unsampled prefix below finishing inside Claude Code's own hook timeout. It applies to every
# such command, whether or not it holds a push, the same shape as hooks/claude-dir-guard.sh's own cap;
# a command whose raw stdin never names git (and holds no dollar sign together with `push`) still
# leaves through the fast path, and plan mode still leaves with no opinion. The carriage-return strip
# runs inside the awk tokenizer (one `gsub` per record, before anything else reads the record) rather
# than as a whole-text bash expansion, which does not finish within the timeout on a long run of
# carriage returns. Worst-case wall clock for the whole hook, stated here for review: at most
# `max(push_budget, T_prefix(L)) + U_max`, where `T_prefix` is the pre-tokenizer prefix this deadline
# cannot sample around at all: `cat`, the two fast-path globs and the three jq extractions of the raw
# stdin (linear in the stdin, unbounded by the cap), then, only for a command at or under the cap,
# the cwd jq and the awk tokenizer (which includes the CR strip), whose own additive `]]` pass costs
# at most `DBRACKET_MAX` times one record's length — counted by the wall clock even though unsampled,
# so the very next `check_deadline()` call denies at once if that prefix alone already spent the
# whole budget. The tokenizer is bounded by the cap, not claimed linear; its output is streamed, and
# a push word longer than its tok_max is rewritten so no bash-side split ever runs on one; and `U_max` is the largest single step this deadline cannot
# interrupt mid-step: one alias-lookup awk pass over the resolved alias records (#448, linear in what
# the sampled config read loop managed to read), one session upward walk (at most 64 levels, each an `[ -f ]`-guarded probe,
# plus up to 63 `dirname` subshell+exec forks — one per level that finds no `.git`, via
# `resolve_repo()`'s own `parent="$(dirname "$dir" …)"` — when no `.git` is ever found before the
# depth cap), one config line's comment-strip (a header line takes a second one, on the text after
# its header, plus a fixed number of header expansions, #510) plus up to three `cfg_trim()` calls (at most
# `CFG_TOPLEVEL_MAX_LINE_CHARS`/`CFG_INCLUDE_MAX_LINE_CHARS` characters, quadratic only in that
# capped length), one include open, up to two `grep` processes plus a depth-1 resolve's file stats,
# one `refspec_dest()` subshell, one word-split of a segment's remaining tokens, the `read` of a
# single config line (linear in that line's own length), or (#494, Codex push only) the one
# `tail -c` + jq + awk pass over the rollout tail, bounded by `PUSH_TRANSCRIPT_TAIL_BYTES`.
# Residuals this deadline does NOT close: the
# `T_prefix` work above is unsampled, though still bounded by the wall clock (and, for a command, by
# the cap) rather than by the deadline's own sampling; the single config-line `read` inside `U_max` is spent before
# `check_deadline` can run again; and the Codex CLI's own hook timeout, if any, is UNVERIFIED here —
# this deadline is sized against Claude Code's own documented 10s PreToolUse timeout only
# (`hooks/hooks.json`'s `"timeout": 10`), not against an unknown Codex figure. Two new over-blocking
# classes follow directly from this: a legitimately huge, but entirely benign, Bash command now
# denies as "too large to analyse" once its own analysis crosses the budget, with no way to widen
# the budget from the command itself; and any push in ANY Claude Code session now denies when a git
# config file it resolves (system, global, or repo-local, at depth 0) has a single line over
# `CFG_TOPLEVEL_MAX_LINE_CHARS` characters — since a single `$HOME/.gitconfig` or system file is
# shared across every repo a session might resolve, one such line denies every push segment that
# reads it, in every repo, until that line is shortened.
set -uo pipefail
set -f  # noglob: untrusted refspec tokens are word-split unquoted below (e.g. in evaluate_segment
        # and the token-array builders); a token shaped like "*:main" must never glob-expand
        # against files in $PWD or a resolved repo directory.

# #435: sampled once, at hook start; every check_deadline() call below (see "Analysis deadline
# (#435)" in this file's header) measures elapsed time as the difference from this value, never by
# resetting $SECONDS itself.
push_t0=$SECONDS

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
# in full: never budgeted by line count or character count, though since #435 its own single-line
# LENGTH is capped separately, see CFG_TOPLEVEL_MAX_LINE_CHARS below). A follow-count budget alone
# does not bound total work: a handful of
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
# #435: whole-second budget (SECONDS granularity) this hook's own analysis may spend, sampled by
# check_deadline() below, before it denies as too large to analyse rather than risk running past
# Claude Code's 10s PreToolUse hook timeout — see "Analysis deadline (#435)" in this file's header.
PUSH_ANALYSIS_BUDGET_SECS=5
# #517: the longest Bash command, in BYTES, this hook analyses at all. A longer one that got past the
# fast path below denies as too large to analyse before the tokenizer ever runs, because a timed-out
# hook gives no deny. Sized so the worst-case shape at the cap finishes well inside the hook timeout.
PUSH_CMD_MAX_BYTES="524288"
# #435: a depth-0 (top-level) config line longer than this many characters denies outright, checked
# BEFORE comment-strip or trim ever run on it, instead of reaching cfg_trim() — see that function's
# own header comment for why a long line or whitespace run there is not uniformly fast.
CFG_TOPLEVEL_MAX_LINE_CHARS=2048
# #292: a push segment naming either of these two classes always redirects which repository the
# push actually runs in, and this hook does not resolve either one — GIT_REPO_OPTS is a global
# option (detached "<opt> <value>" or attached "<opt>=<value>"), GIT_REPO_ENV_VARS is a leading
# shell assignment (a bare "VAR=<value> git ..." prefix or the same behind an "env" prefix word).
# Consumed by the awk tokenizer below to flag the segment "unresolved" rather than to resolve
# anything — see the driver loop's own "unresolvable push target" comment for the fail-closed
# verdict this produces. Since #433, GIT_REPO_ENV_VARS is ALSO consumed by the cross-segment
# ("xseg") check below: an export-family segment naming one of these (NAME=value or bare NAME), or
# a segment consisting only of such an assignment, sets the xseg flag the same way a leading
# in-segment shell assignment does above.
GIT_REPO_OPTS="--git-dir --work-tree"
GIT_REPO_ENV_VARS="GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR"
# #433: a push segment in the same command as a segment resolving to one of these directory-change
# builtins is denied as unresolved (the "xseg" check below) — this hook cannot tell whether the
# change actually reaches the push segment's own cwd, so it fails closed instead.
PUSH_DIR_CHANGE_WORDS="cd pushd popd chdir"
# #433: an export-family builtin whose arguments name a GIT_REPO_ENV_VARS member also sets xseg,
# the same fail-closed reasoning as PUSH_DIR_CHANGE_WORDS above (this hook does not model whether
# the builtin actually exports the name).
PUSH_EXPORT_WORDS="export declare typeset local readonly"
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
# #448: an assignment that moves a config FILE this hook reads (HOME and XDG_CONFIG_HOME relocate
# the global config; GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM name the global and system files
# outright). Set inline (bare or behind "env") the hook reads the wrong file, so a push segment
# carrying one denies through the #439 command-line-config message, and a non-push git segment
# carrying one denies as an unreadable config that may define an alias. Push-guard-only, consumed
# only by the awk tokenizer below.
GIT_CFG_RELOC_ENV_VARS="HOME XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM"
# #449: the `env` options the prefix walk understands; byte-identical to hooks/agent-boundary.sh's
# ENV_NOVALUE_OPTS / ENV_UNSET_OPTS (by convention, unpinned). PUSH_ENV_NOVALUE_OPTS take no value and
# are skipped alone; PUSH_ENV_UNSET_OPTS (`-u NAME`, `--unset NAME`, attached `-uNAME`,
# `--unset=NAME`) are skipped together with their value. Any OTHER dash token after an `env` word
# (`-C`/`--chdir`, `-S`/`--split-string`, a clustered `-iu`, an abbreviation, ...) is an option this
# hook cannot follow, so a segment that could still be a push fails closed. UNVERIFIED which options
# a given GNU or BSD `env` accepts: the allowlist is deliberately narrow, so an unlisted option
# denies rather than being guessed at.
PUSH_ENV_NOVALUE_OPTS="-i -0 -v -- --ignore-environment --null --debug"
PUSH_ENV_UNSET_OPTS="-u --unset"
# PREFIX_VALUE_WORDS (#518) — the PREFIX_WORDS members whose dash options can take a SEPARATE value
# word (`nice -n 5`, `sudo -u root`, `stdbuf -o L`, `exec -a foo`, `xargs -n 1`, `time -o f`): after
# one of these, a dash token followed by a non-option word is a point where the walk cannot tell the
# value from the command word (see the header paragraph "Fail-closed: a value-taking option of a
# prefix word (#518)"). Interpreter words stay out: their `-c` value IS the command string.
# Byte-identical to hooks/agent-boundary.sh's and hooks/claude-dir-guard.sh's own copies (by
# convention, unpinned).
PREFIX_VALUE_WORDS="exec nice stdbuf sudo time xargs"
# #494: the most bytes read from the END of the Codex rollout file named by the payload's
# `transcript_path` when scanning the tool-call records (see the post-loop "#494" block and the
# header's "Fail-closed: Codex shell workdir (#494)" paragraph). A record pushed out of this window
# is not seen — the header's documented window residual — and a window holding no call record at
# all denies as "no Codex tool call"; half of this size is also the unparseable-first-line limit.
PUSH_TRANSCRIPT_TAIL_BYTES="1048576"
# #494: the JSON/JS property names the hook treats as a Codex shell tool's working-directory
# parameter when scanning a tool-call record's text (`workdir` for the exec_command tool,
# `working_directory` for a local_shell_call action). Consumed only by the jq stage of the post-loop
# "#494" block; a cwd-like parameter under any OTHER name is a documented under-blocking class.
PUSH_WORKDIR_KEYS="workdir working_directory"

# is_c_target_path PATH (#269) — true iff PATH satisfies the shared PATH_ERE predicate above.
# Here-string, not a `printf` writer piped into `grep`'s quiet mode (#255): that early-exit
# reader exits on its first match, which can send the printf writer SIGPIPE and, under this
# file's `set -uo pipefail`, turn a genuine match into a reported pipeline failure — a
# here-string has no writer process, so no SIGPIPE is possible (hooks/git-c-guard.sh's own
# validate_segment() use of PATH_ERE is the precedent this copies).
is_c_target_path() { grep -qE "$PATH_ERE" <<<"$1"; }

# #517: pg_bytes STRING sets pg_n to STRING's length in BYTES (a C-locale length, whatever locale
# the hook runs under); mirrors hooks/claude-dir-guard.sh's cdg_bytes.
pg_bytes() { local LC_ALL=C; pg_n="${#1}"; }

# #435: push_budget defaults to PUSH_ANALYSIS_BUDGET_SECS; TBF_PUSH_GUARD_BUDGET_SECS is a
# test-only, environment-only knob (never read from the untrusted command string) that can only
# LOWER it — adopted only when it is exactly one or two ASCII digits and strictly less than
# push_budget, so it can never raise the production budget or reopen a fail-open path.
push_budget="$PUSH_ANALYSIS_BUDGET_SECS"
case "${TBF_PUSH_GUARD_BUDGET_SECS:-}" in
  [0-9]|[0-9][0-9]) [ "$TBF_PUSH_GUARD_BUDGET_SECS" -lt "$push_budget" ] && push_budget="$TBF_PUSH_GUARD_BUDGET_SECS" ;;
esac
push_deadline=$((push_t0 + push_budget))

# deny_too_large KIND (#435) — KIND is "configline" (the depth-0 line-length cap in
# cfg_parse_file() below), "confighdr" (#510: a section header line cfg_parse_file() cannot split
# the way git does) or anything else (the deadline case, via check_deadline() below, and, since #517,
# KIND "command": a Bash command over PUSH_CMD_MAX_BYTES, denied before the tokenizer runs);
# prints exactly one fixed stderr line, echoing no input from the command or config it
# denies, then exits 2.
deny_too_large() {
  case "$1" in
    confighdr)
      printf '%s denies this git command: a git config file it reads has a section header line it cannot split the way git does (blocked: unparseable config header line) — put that section header on a line of its own, or run the command from a terminal; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" >&2
      ;;
    configline)
      printf '%s denies this push: a git config file it reads has a line too long to analyse (blocked: config line too long to analyse) — shorten that line, or run the push from a terminal; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" >&2
      ;;
    *)
      printf '%s denies this command: too large to analyse before the hook'"'"'s time limit (blocked: command too large to analyse) — split it into smaller Bash calls; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" >&2
      ;;
  esac
  exit 2
}

# check_deadline (#435) — called as the first statement of every loop whose trip count grows with
# the command or a config file's content (see "Analysis deadline (#435)" in this file's header for
# the full call-site list and the sampling rule this binds on every future addition). Kept on one
# line so a mutant that neuters its body has a single, unique `from` to target.
check_deadline() { [ "$SECONDS" -lt "$push_deadline" ] || deny_too_large deadline; }

input="$(cat)"

# --- fast paths ------------------------------------------------------------------------------
# One fast path, a pure performance optimisation, semantics-preserving with the check it stands in
# for below except for a command word split by quote, backslash, or carriage-return characters —
# the same documented, quote-blind limit hooks/agent-boundary.sh's fast paths carry. Since #448
# there is no `push` fast path: a git alias that expands to push carries no `push` literal in the
# command text at all (`git zqp origin main`), so a call may only skip the tokenizer when it never
# names git. Since #508 it must also never hold a dollar sign together with `push` (a runtime-built
# command word: `$G push origin main` names no git at all). The #270 CR strip (since #517, inside the awk tokenizer below) fixes an unstripped `\r` for every
# command that reaches the tokenizer, but a CR *inside* the `git` literal this fast path scans (a raw
# stdin substring like `g<CR>it`, where a conforming JSON writer has already escaped the `\r`) still
# exits here, before the strip ever runs — see this file's header "Documented under-blocking
# classes" for that residual case. A miss on this fast path always means "this call is out of scope
# for this hook", which is also what the slower checks below it would conclude. Since #398 it
# case-folds `git`.
case "$input" in
  *[Gg][Ii][Tt]*) : ;;
  *'$'*push*|*push*'$'*) : ;;
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

# #517: the command-size cap, before anything else touches $cmd (see PUSH_CMD_MAX_BYTES above).
pg_bytes "$cmd"
[ "$pg_n" -le "$PUSH_CMD_MAX_BYTES" ] || deny_too_large command

# A CRLF-carrying transport (Git Bash, a CRLF-translating layer) can deliver a command whose
# tokens carry a trailing \r; every comparison below is an exact match, so an unstripped \r
# made `git push origin main\r` no-opinion (#270). Since #517 the strip runs inside the awk
# tokenizer below (one gsub per record, before anything else reads the record), not as a
# whole-text bash expansion here: that expansion does not finish within the hook timeout on a
# very long run of carriage returns. It is not done in normalize(), which the refspec
# destination tokens never pass through.

[ -n "$cmd" ] || exit 0

# cwd is a documented PreToolUse stdin field (Claude Code's hooks reference lists it in the
# common-fields table and in the PreToolUse Bash example); its absence here is not an exit —
# see the repo-resolution step below, which falls back to $PWD and, ultimately, to the
# unconditional PUSH_DEFAULT_BRANCH_FALLBACK deny set.
cwd="$(printf '%s' "$input" | jq -r '.cwd? // empty' 2>/dev/null)"

# --- the tokenizer (POSIX awk, inlined) -------------------------------------------------------
# See this file's header for the full cross-reference to hooks/agent-boundary.sh's twin scan.
# Emits one "PUSH<TAB><-C value, only when exactly one><TAB><#292 unresolved-reason, empty when
# none><TAB><space-joined remaining tokens>" line per push segment found, and (#449) one with an
# empty -C value, a fixed reason and no remaining tokens for a segment that lost the tokenizer but
# could still be a push (see emit_lost()); for a git segment whose subcommand is not push (#448) one "ALIAS<TAB><-C value, only when exactly one><TAB><the
# lowercased subcommand, or, for a segment lost to the tokenizer, every remaining token>" candidate line, or the
# fixed sentinel "-alias-cmdline-config-" when that segment carries a relocation assignment or config naming an alias
# or include (see emit_segment() and emit_alias_lost()); nothing for any other segment, EXCEPT: a push segment carrying command-line git config (#439), which emits the fixed
# sentinel "-cmdline-config-" instead of a "PUSH…" line (see emit_segment()'s own cmdcfg
# handling below); and (#433) one final "-xseg-<TAB><reason>" line, emitted by the END block
# below, iff any segment anywhere in the whole command (a push segment or otherwise) resolved to a
# directory-change builtin or an export/bare-assignment of a GIT_REPO_ENV_VARS member or of one of
# #439's command-line-config names — see the "xseg" comment on emit_segment() below for the mechanism —
# and (#448) one final "-xcfg-" line iff any segment exported or bare-assigned a relocation or command-line-config name.
# Neither the "-C" value, the reason,
# nor the remaining-tokens field can itself contain a TAB, since every token comes from splitting
# on "[ \t]+". Processes $cmd one input line (awk record) at a time — the same deliberate,
# documented false-positive class agent-boundary.sh's header explains (a heredoc line that starts
# with "git push" is scanned as its own segment).
scan_out="$(printf '%s\n' "$cmd" | awk -v prefix_words="$PREFIX_WORDS" -v gopts="$GIT_GLOBAL_OPTS_WITH_VALUE" -v repoopts="$GIT_REPO_OPTS" -v repoenv="$GIT_REPO_ENV_VARS" -v dbracket_max="$DBRACKET_MAX" -v dirwords="$PUSH_DIR_CHANGE_WORDS" -v exportwords="$PUSH_EXPORT_WORDS" -v cmdcfgopts="$GIT_CMDCFG_OPTS" -v cmdcfgenv="$GIT_CMDCFG_ENV_VARS" -v cmdcfgpfx="$GIT_CMDCFG_ENV_PREFIXES" -v envnov="$PUSH_ENV_NOVALUE_OPTS" -v envunset="$PUSH_ENV_UNSET_OPTS" -v relocenv="$GIT_CFG_RELOC_ENV_VARS" -v vpwords="$PREFIX_VALUE_WORDS" '
BEGIN {
  sq = sprintf("%c", 39)
  cr = sprintf("%c", 13)
  # #517: the longest push-rest word (other than an option) whose destination is read at all; see dest_word()
  tok_max = 4096
  n = split(prefix_words, pwarr, " ")
  for (i = 1; i <= n; i++) prefix_set[pwarr[i]] = 1
  nvp = split(vpwords, vparr, " ")
  for (i = 1; i <= nvp; i++) vprefix_set[vparr[i]] = 1
  ng = split(gopts, goarr, " ")
  for (i = 1; i <= ng; i++) gopt_set[goarr[i]] = 1
  nro = split(repoopts, roarr, " ")
  for (i = 1; i <= nro; i++) repoopt_set[roarr[i]] = 1
  nev = split(repoenv, evarr, " ")
  for (i = 1; i <= nev; i++) envvar_set[evarr[i]] = 1
  ndw = split(dirwords, dwarr, " ")
  for (i = 1; i <= ndw; i++) dir_set[dwarr[i]] = 1
  nxw = split(exportwords, xwarr, " ")
  for (i = 1; i <= nxw; i++) export_set[xwarr[i]] = 1
  # #433: xseg is a per-COMMAND flag (never reset per record -- see the per-record block below),
  # first-writer-wins, order-independent across the whole command including the additive "]]"
  # pass: whichever segment sets it first, regardless of any push segment own position, decides
  # the reason text; the END block below emits it once the whole scan is done.
  xseg = ""
  # #439
  ncco = split(cmdcfgopts, ccoarr, " ")
  for (i = 1; i <= ncco; i++) ccopt_set[ccoarr[i]] = 1
  nce = split(cmdcfgenv, cearr, " ")
  for (i = 1; i <= nce; i++) ccenv_set[cearr[i]] = 1
  nccp = split(cmdcfgpfx, ccparr, " ")
  # #449
  nenv = split(envnov, envnovarr, " ")
  for (i = 1; i <= nenv; i++) envnov_set[envnovarr[i]] = 1
  neun = split(envunset, envunsetarr, " ")
  for (i = 1; i <= neun; i++) envunset_set[envunsetarr[i]] = 1
  # #448: config-file relocation names, and the per-COMMAND flag (like xseg, never reset per record)
  # that any segment exported or bare-assigned a relocation or command-line-config name.
  nrl = split(relocenv, rlarr, " ")
  for (i = 1; i <= nrl; i++) reloc_set[rlarr[i]] = 1
  xcfg = 0
  has_bt = 0
  # #508: a dollar sign followed by a name character, a digit, a special parameter, or a quote
  rx_re = "[$][A-Za-z0-9_@*#?!$=~^\"" sq "-]"
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
# #508: a runtime expansion in the token basename (the directory part never counts: $D/git is still
# resolved by its last component). split on a literal slash, never a greedy regex.
function rx_word(tok,    parts, np) {
  if (index(tok, "$") == 0) return 0
  np = split(tok, parts, "/")
  return match(parts[np], rx_re) > 0
}
# #508: the body of a word that is EXACTLY one ANSI-C or locale segment (a dollar sign, a quote, a plain
# name, the same quote): a letter, digit or `_`, then letters, digits, `_`, `.` or `-`. Else the empty string. (This
# program is single-quoted shell, so no literal apostrophe may appear in it.)
function whole_lit(tok,    q, b) {
  q = substr(tok, 2, 1)
  if (substr(tok, 1, 1) != "$" || (q != sq && q != "\"")) return ""
  if (length(tok) < 4 || substr(tok, length(tok)) != q) return ""
  b = substr(tok, 3, length(tok) - 3)
  if (b ~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/) return b
  return ""
}
# #517: the form a push-rest token takes on the PUSH line. A token whose destination (the text after
# the first colon, else the text after an optional leading plus, else the whole token) holds no
# dollar sign is just strip_quotes(tok). A destination that is exactly one plain ANSI-C or locale
# segment is read as the name it spells. Any other destination that holds a dollar sign becomes the
# single character dollar, so the bash side can deny it without echoing it. A word that is not an
# option and is longer than tok_max is rewritten the same way: no real remote, branch or refspec is
# that long, and the bash side splits a refspec at its first colon with pattern removals whose cost
# grows with the square of the word on the bash 3.2 that macOS ships. An OPTION is judged the way the
# bash side judges it, on the quote-stripped word (a leading dash): it is returned stripped and
# otherwise untouched, never rewritten, because a rewrite to the lone dollar would turn an option into
# a non-option argument there and shift the remote and refspec positions. O(length of tok).
function dest_word(tok,    p, hd, d, av, st) {
  st = strip_quotes(tok)
  if (substr(st, 1, 1) == "-") return st
  if (length(tok) > tok_max) return "$"
  p = index(tok, ":")
  if (p > 0) {
    hd = substr(tok, 1, p)
    d = substr(tok, p + 1)
  } else if (substr(tok, 1, 1) == "+") {
    hd = "+"
    d = substr(tok, 2)
  } else {
    hd = ""
    d = tok
  }
  if (index(d, "$") == 0) return st
  av = whole_lit(d)
  if (av != "") return strip_quotes(hd) av
  return strip_quotes(hd) "$"
}
function is_cmdcfg_name(n,    c) {
  if (n in ccenv_set) return 1
  for (c = 1; c <= nccp; c++) if (index(n, ccparr[c]) == 1) return 1
  return 0
}
# #449: token-shape predicates and the push-reachability gate for the fail-closed triggers in
# emit_segment() below. This program is single-quoted shell: it must never contain a literal
# apostrophe (use sq). quote_bearing: the token carries a quote or a backslash. quote_unbalanced:
# an odd count of double quotes, an odd count of single quotes, or a trailing backslash -- the
# token opens a quoted or escaped span that the whitespace split cut in two.
function quote_bearing(tok) {
  return (index(tok, "\"") > 0 || index(tok, sq) > 0 || index(tok, "\\") > 0)
}
function quote_unbalanced(tok,    t, n) {
  t = tok
  n = gsub(/"/, "", t)
  if (n % 2) return 1
  t = tok
  n = gsub(sq, "", t)
  if (n % 2) return 1
  return (substr(tok, length(tok)) == "\\")
}
# lost_push(toks, from, ntok, armed): one left-to-right pass over toks[from..ntok], true iff the
# rest of the segment could still be a push -- a single token naming both git and push, or a token
# naming git followed only by option words (and the values of git global options) and then a token
# naming push. armed starts the walk as if a git word had just been seen; armed == 2 additionally
# never disarms on a non-option word and never applies the option-value skip (the fragments a split
# quoted value leaves behind may themselves look like an option, e.g. the -c" of "k=a b -c", so any
# later token naming push counts). Never consulted for a
# segment that cannot be a push, so a non-push command keeps its old no-opinion verdict.
function lost_push(toks, from, ntok, armed,    i, tok, s, lo, skip, arm) {
  arm = armed
  skip = 0
  for (i = from; i <= ntok; i++) {
    tok = toks[i]
    if (tok == "") continue
    s = strip_quotes(tok)
    lo = tolower(s)
    if (index(lo, "git") > 0 && index(s, "push") > 0) return 1
    if (arm) {
      if (skip) { skip = 0; continue }
      if (substr(s, 1, 1) == "-") { if (armed != 2 && (s in gopt_set)) skip = 1; continue }
      if (index(s, "push") > 0) return 1
      if (armed != 2) arm = 0
    }
    if (index(lo, "git") > 0) { arm = 1; skip = 0 }
  }
  return 0
}
# emit_lost: the segment lost the tokenizer and could still be a push -- fail closed. A cut push
# keeps its own sentinel, command-line git config keeps its own message, and an earlier #292 reason
# (unres) keeps precedence over the fixed new reason; the reason is never input text.
function emit_lost(reason, unres, cc, cut) {
  if (cut) print "-cut-push-"
  else if (cc) print "-cmdline-config-"
  else print "PUSH\t\t" (unres != "" ? unres : reason) "\t"
}
# #448 (and the #449 interplay): a segment the tokenizer lost but that is no push still names git, so
# its real subcommand could be a git alias that expands to push. emit_alias_lost() runs at each #449
# trigger when lost_push() said no, once per segment (al_done keeps a many-token segment linear): it
# denies outright when a relocation name was assigned (reloc) or any token of the segment mentions an
# alias or include (a quoted -c option hides the config it carries), and otherwise hands the driver EVERY remaining token as an alias candidate name
# (#517: a token that is exactly one plain ANSI-C or locale segment is handed over as the name it spells,
# and any other token holding a dollar sign and a quote makes the whole segment fail closed with the
# git-options reason), since the fragments a split quoted value leaves behind make the real subcommand unlocatable. With
# needgit set (a prefix-position trigger, where the command word is unknown) it stays silent unless
# some later token names git. The output is fixed vocabulary or lowercased input tokens that the driver
# only ever compares, never echoes. Quote, backslash and apostrophe handling: strip_quotes() only.
function has_cfg_assign(u,    c) {
  if (index(u, "=") == 0) return 0
  for (c = 1; c <= nrl; c++) if (index(u, rlarr[c] "=") > 0) return 1
  for (c = 1; c <= nce; c++) if (index(u, cearr[c] "=") > 0) return 1
  for (c = 1; c <= nccp; c++) if (index(u, ccparr[c]) > 0) return 1
  return 0
}
function emit_alias_lost(toks, from, ntok, needgit, reloc, cpath,    i, t, u, av, al_rx, names, sep, saw_git, saw_alias, seen, nn, nc, chunk) {
  saw_git = 0
  saw_alias = 0
  al_rx = 0
  names = ""
  sep = ""
  nn = 0
  nc = 0
  for (i = 1; i <= ntok; i++) {
    t = tolower(strip_quotes(toks[i]))
    if (t == "") continue
    if (index(t, "alias") > 0 || index(t, "include") > 0) saw_alias = 1
    # a relocation or command-line-config assignment hidden behind quotes or inside an env -S string
    # (env "HOME=<d>" git ..., env -S"HOME=<d> git ...") is no unquoted assignment token, so the prefix
    # walk never saw it: a substring match, fail closed
    if (has_cfg_assign(strip_quotes(toks[i]))) reloc = 1
    # the trigger token itself may hold git (env -S"HOME=/x\_git\_p": the backslash-underscore is an
    # env -S separator), so it counts toward the names-git gate too
    if (i == from - 1 && index(t, "git") > 0) saw_git = 1
    if (i < from) continue
    # #517: a word that is exactly one plain ANSI-C or locale segment is the name it spells; any
    # other word holding one cannot be read, so the whole segment fails closed below
    u = toks[i]
    if (index(u, "$" sq) > 0 || index(u, "$\"") > 0) {
      av = whole_lit(u)
      if (av == "") al_rx = 1
      else t = tolower(av)
    }
    if (index(t, "git") > 0) saw_git = 1
    # unique names only, handed over in chunks of bounded size: the string append stays cheap however
    # many tokens a segment holds
    if (t in seen) continue
    seen[t] = 1
    names = names sep t
    sep = " "
    if (++nn >= 200) { chunk[++nc] = names; names = ""; sep = ""; nn = 0 }
  }
  if (needgit && !saw_git) return
  if (reloc || saw_alias) { print "-alias-cmdline-config-"; return }
  if (al_rx) { print "PUSH\t\truntime expansion in the git options\t"; return }
  for (i = 1; i <= nc; i++) print "ALIAS\t" cpath "\t" chunk[i]
  if (names != "") print "ALIAS\t" cpath "\t" names
}
function emit_segment(seg, cut_flag,    ntok, toks, idx, tok, norm, saw_prefix, cmdword, j, subcmd, rest, sep, cpath, ccount, unres, aname, in_env, in_vp, m0, m1, m2, s0, reloc, aliasish, at, rname, al_done, cfgdollar, cv, rx_at, rxg_at, rxn_at, rxbs, av, jend, ro, k, xname, cmdcfg, co, cp, cfgname, cpath_big) {
  ntok = split(seg, toks, /[ \t]+/)
  idx = 1
  saw_prefix = 0
  cmdword = ""
  unres = ""
  cmdcfg = 0
  # #449: per-segment memos of the lost_push() scans (-1 = not yet scanned) and the env-context flag
  in_env = 0
  in_vp = 0
  m0 = -1
  m1 = -1
  m2 = -1
  reloc = 0
  al_done = 0
  cfgdollar = 0
  rx_at = 0
  rxg_at = 0
  rxn_at = 0
  rxbs = 0
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
      # #448: an inline assignment that relocates a config file this hook reads -- boolean only, the
      # name is never echoed.
      if (aname in reloc_set) reloc = 1
      # #448: a dollar sign in the value of a command-line-config assignment may build an alias key
      if (index(tok, "$") > 0 && is_cmdcfg_name(aname)) cfgdollar = 1
      # #449: an assignment whose quoted or escaped value the whitespace split cut in two
      # (X="a b", X=a\ b) leaves the rest of the value as a bogus command word -- fail closed when
      # the remaining tokens could still be a push.
      if (quote_unbalanced(tok)) {
        if (m0 < 0) m0 = lost_push(toks, idx + 1, ntok, 0)
        if (m0) { emit_lost("quote or escape in the command prefix", unres, cmdcfg, cut_flag); return }
        if (!al_done) { al_done = 1; emit_alias_lost(toks, idx + 1, ntok, 1, reloc, "") }
      }
      if (saw_prefix && !rx_at && rx_word(tok)) rx_at = idx
      idx++
      continue
    }
    norm = tolower(normalize(tok))
    if (norm == "") { idx++; continue }
    # #449: an option after an env word. The allowlisted no-value options are skipped alone, -u/--unset
    # take their value with them, and any other option is one this hook cannot follow (-C/--chdir
    # change the directory, -S splits a string into more words): fail closed when a push can follow.
    # Anything not handled here falls through to the unchanged walk below.
    if (in_env && substr(tok, 1, 1) == "-") {
      if (tok in envnov_set) { idx++; continue }
      if (tok in envunset_set) {
        if (!rx_at && rx_word(toks[idx + 1])) rx_at = idx + 1
        if (quote_unbalanced(toks[idx + 1])) {
          if (m0 < 0) m0 = lost_push(toks, idx + 1, ntok, 0)
          if (m0) { emit_lost("quote or escape in the command prefix", unres, cmdcfg, cut_flag); return }
          if (!al_done) { al_done = 1; emit_alias_lost(toks, idx + 1, ntok, 1, reloc, "") }
        }
        idx += 2
        continue
      }
      if (substr(tok, 1, 2) == "-u" || index(tok, "--unset=") == 1) {
        if (!rx_at && rx_word(tok)) rx_at = idx
        if (quote_unbalanced(tok)) {
          if (m0 < 0) m0 = lost_push(toks, idx + 1, ntok, 0)
          if (m0) { emit_lost("quote or escape in the command prefix", unres, cmdcfg, cut_flag); return }
          if (!al_done) { al_done = 1; emit_alias_lost(toks, idx + 1, ntok, 1, reloc, "") }
        }
        idx++
        continue
      }
      if (m0 < 0) m0 = lost_push(toks, idx, ntok, 0)
      if (m0 || rec_lost) { emit_lost("unsupported env option", unres, cmdcfg, cut_flag); return }
      if (!al_done) { al_done = 1; emit_alias_lost(toks, idx + 1, ntok, 1, reloc, "") }
    }
    # #449: after a prefix word, a quote-bearing token that reads as an option or an assignment once
    # unquoted ("X=a", "-C") is skipped by the real shell or env but is no command word here.
    if (saw_prefix && quote_bearing(tok)) {
      s0 = strip_quotes(tok)
      if (substr(s0, 1, 1) == "-" || match(s0, /^[A-Za-z_][A-Za-z0-9_]*=/) == 1) {
        if (m0 < 0) m0 = lost_push(toks, idx + 1, ntok, 0)
        if (m0) { emit_lost("quote or escape in the command prefix", unres, cmdcfg, cut_flag); return }
        if (!al_done) { al_done = 1; emit_alias_lost(toks, idx + 1, ntok, 1, reloc, "") }
      }
    }
    # #518: a dash token in the value context of a prefix word (exec/nice/stdbuf/sudo/time/xargs)
    # followed by a non-option word W: W may be that option value, so a push could follow it. Read the
    # rest of the segment AFTER W (never W itself, so `sudo -E git push origin feature/x` is judged on
    # W as before); the m0 and al_done memos are shared with the triggers above.
    if (in_vp && substr(tok, 1, 1) == "-" && idx < ntok && toks[idx + 1] != "" && substr(toks[idx + 1], 1, 1) != "-") {
      if (m0 < 0) m0 = lost_push(toks, idx + 2, ntok, 0)
      if (m0) { emit_lost("option value in the command prefix", unres, cmdcfg, cut_flag); return }
      if (!al_done) { al_done = 1; emit_alias_lost(toks, idx + 3, ntok, 1, reloc, "") }
    }
    # #508: a runtime expansion in command position may expand to nothing (or to several words): skip
    # it as a possibly-empty prefix word so the real command word behind it still resolves
    if (rx_word(tok)) { if (!rx_at) rx_at = idx; saw_prefix = 1; idx++; continue }
    if (norm in prefix_set && norm != "-") { in_env = (norm == "env"); in_vp = (norm in vprefix_set) }
    if (norm in prefix_set) { saw_prefix = 1; idx += (norm == "repeat") ? 2 : 1; continue }
    if (saw_prefix && substr(tok, 1, 1) == "-") { idx++; continue }
    cmdword = norm
    idx++
    break
  }
  # #508: an expansion in the command prefix, and the rest of the segment could still be a push
  if (rx_at && lost_push(toks, rx_at + 1, ntok, 1)) { emit_lost("runtime expansion in the command prefix", unres, cmdcfg, cut_flag); return }
  # #433: cross-segment ("xseg") detection, order-independent -- first segment of any kind (a push
  # segment or otherwise) to match one of these three shapes sets the flag for the WHOLE command;
  # this push segment resolution below never reads xseg, only the driver post-loop fallback does
  # (see the driver loop own "unresolvable push target" comment), so an in-segment reason on the
  # push segment itself always keeps precedence.
  if (xseg == "") {
    if (cmdword in dir_set) xseg = "cd/pushd/popd earlier in this command"
    else if (cmdword in export_set) { for (k = idx; k <= ntok; k++) { xname = strip_quotes(toks[k]); sub(/=.*/, "", xname); if (xname in envvar_set) { xseg = xname " set earlier in this command"; break } } }
    else if (cmdword == "" && unres != "") xseg = substr(unres, 1, length(unres) - 1) " set earlier in this command"
  }
  # #433 + #439: the same cross-segment rule for the #439 command-line-config environment names
  # (GIT_CMDCFG_ENV_VARS, or a GIT_CMDCFG_ENV_PREFIXES-prefixed name) exported, or bare-assigned, in
  # another segment. The reason is fixed text: a prefix-matched name is input-derived, never echoed.
  if (xseg == "") {
    if (cmdword in export_set) { for (k = idx; k <= ntok; k++) { cfgname = strip_quotes(toks[k]); sub(/=.*/, "", cfgname); if (is_cmdcfg_name(cfgname)) { xseg = "GIT_CONFIG_* set earlier in this command"; break } } }
    else if (cmdword == "" && cmdcfg) xseg = "GIT_CONFIG_* set earlier in this command"
  }
  # #448: the same cross-segment rule for HOME / XDG_CONFIG_HOME exported or bare-assigned in another
  # segment (GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM are GIT_CMDCFG_ENV_VARS members, so the block above
  # already took them). Fixed reason text; the name is never echoed.
  if (xseg == "") {
    if (cmdword in export_set) { for (k = idx; k <= ntok; k++) { rname = strip_quotes(toks[k]); sub(/=.*/, "", rname); if (rname in reloc_set) { xseg = "HOME or XDG_CONFIG_HOME set earlier in this command"; break } } }
    else if (cmdword == "" && reloc) xseg = "HOME or XDG_CONFIG_HOME set earlier in this command"
  }
  # #448: unconditional per-COMMAND flag (xseg is first-writer-wins and push-gated, this one is neither):
  # some segment exported or bare-assigned a relocation or command-line-config name, so a git alias
  # candidate anywhere in the command may be defined by config this hook cannot read.
  if (!xcfg) {
    if (cmdword in export_set) { for (k = idx; k <= ntok; k++) { rname = strip_quotes(toks[k]); sub(/=.*/, "", rname); if ((rname in reloc_set) || is_cmdcfg_name(rname)) { xcfg = 1; break } } }
    else if (cmdword == "" && (reloc || cmdcfg)) xcfg = 1
  }
  if (cmdword != "git") return
  j = idx
  subcmd = ""
  cpath = ""
  cpath_big = 0
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
    # #448: the VALUE of a -c/--config-env option (the next token, or the attached remainder) holding a
    # dollar sign may build an alias key at run time
    if ((tok in ccopt_set) || substr(tok, 1, 2) == "-c" || index(tok, "--config-env=") == 1) {
      cv = (tok in ccopt_set) ? toks[j + 1] : tok
      if (index(cv, "$") > 0) cfgdollar = 1
    }
    # #449: a quoted or escaped option in the option slot ("-c", \-c, "--git-dir=...", -"c") is
    # applied by git but never read here -- it would otherwise normalise into the subcommand slot
    # or be skipped unread. Fail closed when a push can still follow. strip_quotes, not normalize:
    # normalize keeps only the last path component and would turn "--git-dir=../x/.git" into .git.
    # An attached option whose own quoted value was split by the whitespace tokenizer
    # (--git-dir="a b", -c"k=a b"), or the detached VALUE token of a global option other than -C that
    # is itself unbalanced (-c "k=a b"): the leftover fragments would become the subcommand and drop
    # the segment. The -C value stays exempt (the harness own worktree paths may hold a space).
    if (quote_unbalanced(tok) && substr(strip_quotes(tok), 1, 1) == "-") {
      if (m2 < 0) m2 = lost_push(toks, j + 1, ntok, 2)
      if (m2) { emit_lost("quoted or escaped git option", unres, cmdcfg, cut_flag); return }
      if (!al_done) { al_done = 1; emit_alias_lost(toks, j + 1, ntok, 0, reloc, ccount == 1 ? cpath : "") }
    }
    s0 = strip_quotes(tok)
    if ((s0 in gopt_set) && s0 != "-C" && quote_unbalanced(toks[j + 1])) {
      if (m2 < 0) m2 = lost_push(toks, j + 2, ntok, 2)
      if (m2) { emit_lost("quoted or escaped git option", unres, cmdcfg, cut_flag); return }
      if (!al_done) { al_done = 1; emit_alias_lost(toks, j + 1, ntok, 0, reloc, ccount == 1 ? cpath : "") }
    }
    if (quote_bearing(tok) && substr(strip_quotes(tok), 1, 1) == "-") {
      if (m1 < 0) m1 = lost_push(toks, j, ntok, 1)
      if (m1) { emit_lost("quoted or escaped git option", unres, cmdcfg, cut_flag); return }
      if (!al_done) { al_done = 1; emit_alias_lost(toks, j + 1, ntok, 0, reloc, ccount == 1 ? cpath : "") }
    }
    if (tok in gopt_set) {
      if (tok == "-C") {
        ccount++
        cpath = strip_quotes(toks[j + 1])
        # #517: a path longer than tok_max names no real directory; the bash side splits this field off
        # with pattern removals whose cost grows with the square of its length on bash 3.2
        if (length(cpath) > tok_max) { cpath = ""; cpath_big = 1 }
      }
      j += 2
      continue
    }
    # #508: a word that is exactly one plain ANSI-C or locale segment is the name it spells (a dollar-quoted
    # zqp is zqp), substituted into toks so every later scan sees it; any other word in the option slot
    # holding a dollar sign and a quote fails closed
    if (index(tok, "$" sq) > 0 || index(tok, "$\"") > 0) {
      av = whole_lit(tok)
      if (av != "") { tok = av; toks[j] = av }
      else { rxbs = 1; if (!rxg_at) rxg_at = j; j++; continue }
    }
    if (rx_word(tok)) { if (!rxg_at) rxg_at = j; if (!rxn_at && substr(tok, 1, 1) != "-") rxn_at = j; j++; continue }
    if (substr(tok, 1, 1) == "-") { j++; continue }
    if (normalize(tok) == "") { j++; continue }
    subcmd = normalize(tok)
    j++
    break
  }
  # #508: no subcommand followed the skipped expansion words. The first one that does not start with a
  # dash is the candidate subcommand, the word the walk took before the skip existed; when every
  # skipped word is dash-led there is none. The alias and relocation scan below then covers the whole
  # option slot, since an expansion may hide where the slot ends.
  jend = j
  if (subcmd == "" && rxn_at) { subcmd = normalize(toks[rxn_at]); j = jend + 1 }
  # #508: an expansion in the git option slot may stand for options, the subcommand, or nothing
  if (rxg_at && (rxbs || index(strip_quotes(toks[rxg_at]), "push") > 0 || lost_push(toks, rxg_at + 1, ntok, 2))) { emit_lost("runtime expansion in the git options", unres, cmdcfg, cut_flag); return }
  # #448: every git segment whose subcommand is not push is an alias candidate -- git never lets an
  # alias shadow a built-in, so the config lookup in the driver loop alone decides. Config this hook
  # cannot read (a relocation assignment, or command-line config naming an alias or include) denies
  # here with a fixed sentinel. Runs even for a CUT segment: a cut never matters to an alias verdict.
  # #448: command-line config on a git segment that is no push, whose VALUE holds a dollar sign (a
  # variable or substitution the hook cannot expand) or that sits in a record holding a backtick (a
  # command substitution splits the segment at the backtick, cutting the value off), may build an alias
  # key at run time: deny. Also runs when the subcommand was never reached.
  if (cmdcfg && subcmd != "push" && (cfgdollar || has_bt)) print "-alias-cmdline-config-"
  if (subcmd != "" && subcmd != "push") {
    aliasish = 0
    if (cmdcfg) for (k = 1; k <= j - 2; k++) { at = tolower(strip_quotes(toks[k])); if (index(at, "alias") > 0 || index(at, "include") > 0) { aliasish = 1; break } }
    if (reloc || aliasish) print "-alias-cmdline-config-"
    else print "ALIAS\t" (ccount == 1 ? cpath : "") "\t" tolower(subcmd)
  }
  if (subcmd != "push") {
    if (subcmd == "" && cut_flag) print "-cut-push-"
    return
  }
  if (cut_flag) { print "-cut-push-"; return }
  # #439: a real push segment carrying command-line git config denies outright, ahead of the #292
  # unresolved-target reason (Q5) — either way the segment denies.
  if (cmdcfg) { print "-cmdline-config-"; return }
  # #448: an inline HOME/XDG_CONFIG_HOME/GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM assignment on a push segment
  # moves a config file this hook reads, so it is denied the same way and with the same message.
  if (reloc) { print "-cmdline-config-"; return }
  if (unres == "" && ccount >= 2) unres = "more than one -C"
  if (unres == "" && ccount == 1 && cpath_big) unres = "-C path outside the <name>-wt-<n> worktree shape"
  # #517: streamed, never built by repeated appends to one string, so the cost stays linear in the
  # segment however many tokens it holds
  sep = ""
  printf "PUSH\t%s\t%s\t", (ccount == 1 ? cpath : ""), unres
  while (j <= ntok) {
    tok = toks[j]
    if (tok != "") {
      printf "%s%s", sep, dest_word(tok)
      sep = " "
    }
    j++
  }
  printf "\n"
}
{
  gsub(cr, "")
  line = $0
  gsub(/[;&|(){}`]/, "\n", line)
  gsub(/[<>]/, " ", line)
  has_bt = (index($0, "`") > 0)
  # #508: the segmenter cuts a record at ${, $( and a backtick, so an env -S string holding one is
  # judged without its tail: fail closed on the whole record instead
  rec_lost = 0
  if ((index($0, "${") > 0 || index($0, "$(") > 0 || has_bt) && index(tolower($0), "env") > 0) {
    rntok = split($0, rtoks, /[ \t]+/)
    rec_lost = lost_push(rtoks, 1, rntok, 0)
  }
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
END { if (xseg != "") print "-xseg-\t" xseg }
END { if (xcfg) print "-xcfg-" }
')"

# #435: nothing to judge anywhere in the scan — no "PUSH" line, no "ALIAS" candidate line (#448: a
# git segment whose subcommand is not push, which may be a git alias), and no dbracket/cut-push/
# command-line-config sentinel (the "-alias-cmdline-config-" sentinel contains the last one) — so the
# driver loop below would find nothing to deny and exit 0 anyway; this just gets there before ever
# sampling the deadline, so a command with no push segment and no git alias candidate at all is never
# denied by the deadline merely for being large (the command-size cap above is the one size rule that
# applies to it, and it runs before the tokenizer). #433's own "-xseg-" marker line and #448's "-xcfg-" marker alone do
# not count: the xseg fallback below denies only when a push segment was also seen, and an xcfg only
# denies an alias candidate, so a scan holding nothing but those markers exits here too. (None of the
# patterns can occur in a marker line: its reason is a fixed phrase or a GIT_REPO_ENV_VARS name.)
case "$scan_out" in
  *PUSH*|*ALIAS*|*-too-many-dbrackets-*|*-cut-push-*|*-cmdline-config-*) ;;
  *) exit 0 ;;
esac
check_deadline
# #448: a relocation or command-line-config name exported or bare-assigned anywhere in the command
# (the tokenizer's "-xcfg-" marker line) makes every alias candidate in it deny, since the alias may
# live in config this hook cannot read.
xcfg_seen=0
case "$scan_out" in
  *-xcfg-*) xcfg_seen=1 ;;
esac

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
# line; since #435, a depth-0 top-level candidate has its own cap of the same kind
# (CFG_TOPLEVEL_MAX_LINE_CHARS, checked in cfg_parse_file() before this function is ever called),
# so this function no longer sees an unbounded-length top-level line either — see "Analysis
# deadline (#435)" in this file's header. Used only by the #268 config parser below; defined
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
# #304/#305: the carriage-return literal the config parser strips from a config line. File scope
# (not per candidate file), since it is a fixed literal independent of which candidate is being
# parsed. (The command-string strip is not bash since #517: it lives in the awk tokenizer.)
cfg_cr=$'\r'
# #510: the three bytes of a UTF-8 byte-order mark, written as octal escapes so the match is byte-literal
# whatever the locale. git skips one at the start of a config file; cfg_parse_file() strips it from the
# first line of each file it opens.
cfg_bom=$'\357\273\277'

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
# of these four checks ever applies to a depth-0 top-level candidate — those are still always read
# in full, with no line-count or character budget of their own, so none of the four can ever mask a
# pre-#304/#305 route WITHIN ONE RESOLUTION (see the "Repo resolution" paragraph above for how
# multiple resolutions per hook invocation multiply this same bounded work instead). Since #435, a
# depth-0 candidate's own line LENGTH — never its line count or total characters — is capped
# separately (CFG_TOPLEVEL_MAX_LINE_CHARS, checked below before comment-strip or trim), the same
# reason cfg_trim() is capped for an included line; that new cap is not one of these four axes.
# Declares every
# per-file variable `local`, so a nested call (an include's
# own include) never clobbers the includer's own section state — proven by the
# push-include-deny-second-path-after-return fixture, which pins that parsing resumes, in the
# includer's own section, right after an inline include returns. Reads only through `done < "$1"`,
# a `[ -f ]`-guarded builtin redirect — never `cat`, `dirname`, `cd`, or any external command on
# PATH or a value taken from its content; an include's own path is resolved with parameter
# expansion only (see the `include)` key arm below), so no include-derived string ever reaches any
# process's argv. Still appends to the plain (non-local) globals cfg_push_lines/cfg_push_defaults/
# cfg_branch_merge, and reads the plain global current_branch, exactly as the pre-#304/#305 inline
# loop did. Since #510 a section header line is split before the comment strip, and the text after
# its closing bracket is read as a key of that section (see this file's header, "Section headers and
# same-line keys (#510)"); a header line it cannot classify denies via deny_too_large confighdr.
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
  local cfg_raw cfg_rest cfg_hdr cfg_pre cfg_q cfg_nm cfg_after cfg_np cfg_name cfg_ws cfg_sub cfg_lead cfg_form cfg_mix
  local cfg_first=1
  while IFS= read -r cfgline || [ -n "$cfgline" ]; do
    check_deadline
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
    # applies to a depth-0 top-level candidate (those are always read in full, with no line-count
    # or character budget) -- see each vocabulary declaration's own comment. Since #435, a depth-0
    # candidate's own line LENGTH is still capped separately, just below this loop's depth>=1 block
    # -- see CFG_TOPLEVEL_MAX_LINE_CHARS's own vocabulary comment.
    if [ "$depth" -ge 1 ]; then
      [ "$cfg_inc_line_budget" -gt 0 ] || break
      cfg_inc_line_budget=$((cfg_inc_line_budget - 1))
      cfg_inc_char_budget=$((cfg_inc_char_budget - ${#cfgline} - 1))
      [ "$cfg_inc_char_budget" -ge 0 ] || break
      [ "${#cfgline}" -le "$CFG_INCLUDE_MAX_LINE_CHARS" ] || continue
    fi
    # #448: a CR strictly inside the line is removed by the strip below, which would fuse the words
    # around it (an alias value split at a raw CR); remember it so the alias arms can fail closed. Only
    # a line within the top-level cap is scanned, so the glob never runs on an over-cap line.
    cfg_cr_mid=0
    if [ "${#cfgline}" -le "$CFG_TOPLEVEL_MAX_LINE_CHARS" ]; then
      case "$cfgline" in
        *"$cfg_cr"?*) cfg_cr_mid=1 ;;
      esac
    fi
    # #435: the depth-0 (top-level) counterpart to the depth>=1 length check just above — a
    # top-level candidate is still always read in full, never budgeted (CFG_INCLUDE_MAX_FOLLOWS/
    # _LINES/_LINE_CHARS/_CHARS above apply to an INCLUDED file only), but an over-cap line here now
    # fails closed instead of ever reaching cfg_trim(), for the same reason as the depth>=1 check:
    # cfg_trim()'s own pattern matching is not uniformly fast for a long line or whitespace run.
    [ "$depth" -ge 1 ] || [ "${#cfgline}" -le "$CFG_TOPLEVEL_MAX_LINE_CHARS" ] || deny_too_large configline
    cfgline="${cfgline//$cfg_cr/}"
    # #510: a UTF-8 BOM on the file's first line is skipped, as git skips it; only the first line of
    # each file this call opens that reaches this point is tested (see the header paragraph).
    if [ "$cfg_first" = 1 ]; then cfg_first=0; cfgline="${cfgline#"$cfg_bom"}"; fi
    cfg_raw="$cfgline"
    # Strip a trailing comment: whichever of '#'/';' appears first, with no quote-tracking -- git
    # ref names MAY legitimately contain '#' or ';' (e.g. refs/heads/feat#123 and
    # refs/heads/feat;123 are both accepted by git itself), so this is a known, documented parsing
    # gap, not a safe assumption. See this file's header "Documented over-blocking classes" (a
    # destination value truncated at the marker) and "Documented under-blocking classes" (an
    # include value truncated at the marker) for the behaviour classes this creates. A SECTION
    # HEADER line is split before this strip, on the raw line (see "Section headers and same-line
    # keys (#510)" in this file's header): only the keys and values after it are truncated.
    cfg_h="${cfgline%%#*}"
    cfg_s="${cfgline%%;*}"
    if [ "${#cfg_h}" -le "${#cfg_s}" ]; then cfgline="$cfg_h"; else cfgline="$cfg_s"; fi
    cfg_trim "$cfgline"; cfgline="$cfg_trim_out"
    [ -n "$cfgline" ] || continue
    # #510: a section header line is split on the RAW line (see "Section headers and same-line keys
    # (#510)" in this file's header), before the comment strip above could cut a quoted subsection
    # short. cfgline becomes the header text git reads as the declaration (remote/branch/includeIf
    # rewritten to the one canonical `[name "sub"]` spelling the arms below accept), and cfg_rest the
    # text after the header's closing bracket. A shape it cannot classify denies. Parameter
    # expansion and case only: no loop, no subshell, no external command.
    cfg_hdr=0
    cfg_rest=""
    case "$cfgline" in
      \[*)
        cfg_hdr=1
        cfgline="[${cfg_raw#*\[}"
        cfg_pre="${cfgline%%\]*}"
        cfg_name=""
        cfg_sub=""
        cfg_mix=""
        cfg_form=none
        if [ "$cfg_pre" != "$cfgline" ]; then
          case "$cfg_pre" in
            *\"*)
              cfg_q="${cfgline#*\"}"
              cfg_nm="${cfg_q%%\"*}"
              cfg_after="${cfg_q#*\"}"
              cfg_np="${cfgline%%\"*}"
              cfg_np="${cfg_np#\[}"
              cfg_name="${cfg_np%%[[:space:]]*}"
              cfg_ws="${cfg_np#"$cfg_name"}"
              [ -n "$cfg_name" ] || deny_too_large confighdr
              [ -n "$cfg_ws" ] || deny_too_large confighdr
              case "$cfg_ws" in
                *[![:space:]]*) deny_too_large confighdr ;;
              esac
              if [ "$cfg_nm" = "$cfg_q" ]; then
                cfg_name=""
              else
                case "$cfg_nm" in
                  *\\) [ "$cfg_after" = "]" ] || deny_too_large confighdr ;;
                esac
                case "$cfg_after" in
                  \]*) ;;
                  *) deny_too_large confighdr ;;
                esac
                cfg_rest="${cfg_after#\]}"
                cfg_sub="$cfg_nm"
                cfg_form=quoted
                case "$cfg_name" in
                  ?*.?*) cfg_mix="${cfg_name#*.}"; cfg_name="${cfg_name%%.*}" ;;
                esac
              fi
              ;;
            *)
              cfg_np="${cfg_pre#\[}"
              case "$cfg_np" in
                *[[:space:]]*) deny_too_large confighdr ;;
              esac
              cfg_rest="${cfgline#*\]}"
              cfg_name="$cfg_np"
              case "$cfg_np" in
                *.?*)
                  cfg_name="${cfg_np%%.*}"
                  cfg_sub="${cfg_np#*.}"
                  cfg_form=dotted
                  ;;
              esac
              ;;
          esac
          case "$cfg_form" in
            quoted|dotted)
              case "$cfg_name" in
                [Rr][Ee][Mm][Oo][Tt][Ee]|[Bb][Rr][Aa][Nn][Cc][Hh])
                  case "$cfg_mix$cfg_sub" in
                    *\\*) deny_too_large confighdr ;;
                  esac
                  if [ "$cfg_form" = dotted ]; then
                    case "$cfg_sub" in
                      *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]*) deny_too_large confighdr ;;
                    esac
                  fi
                  case "$cfg_mix" in
                    *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]*) deny_too_large confighdr ;;
                    ?*) cfg_sub="$cfg_mix.$cfg_sub" ;;
                  esac
                  cfgline="[$cfg_name \"$cfg_sub\"]"
                  ;;
                [Ii][Nn][Cc][Ll][Uu][Dd][Ee][Ii][Ff])
                  if [ "$cfg_form" = quoted ] && [ -z "$cfg_mix" ]; then cfgline="[$cfg_name \"$cfg_sub\"]"; fi
                  ;;
              esac
              ;;
          esac
        fi
        ;;
    esac
    case "$cfgline" in
      \[[Rr][Ee][Mm][Oo][Tt][Ee]\ \"*\"\]*)
        cfg_section="remote"
        cfg_subsection="${cfgline#*\"}"
        cfg_subsection="${cfg_subsection%%\"*}"
        ;;
      \[[Bb][Rr][Aa][Nn][Cc][Hh]\ \"*\"\]*)
        cfg_section="branch"
        cfg_subsection="${cfgline#*\"}"
        cfg_subsection="${cfg_subsection%%\"*}"
        ;;
      \[[Pp][Uu][Ss][Hh]\]*)
        cfg_section="push"
        cfg_subsection=""
        ;;
      \[[Aa][Ll][Ii][Aa][Ss]\ *|\[[Aa][Ll][Ii][Aa][Ss]$'\t'*|\[[Aa][Ll][Ii][Aa][Ss].*)
        # #448: any subsection spelling of an alias (alias.<name>.command): [alias "<name>"] with any
        # run of blanks before the quote, an escaped or odd name, or the deprecated dotted [alias.<name>].
        # The name is deliberately NOT read: a command key under any of them is recorded under the
        # name-independent key "*", so the verdict cannot depend on a name spelling this hook might misread.
        cfg_section="aliassub"
        cfg_subsection=""
        ;;
      \[[Aa][Ll][Ii][Aa][Ss]\]*)
        # #448: an [alias] section -- its keys are recorded, never executed or expanded.
        cfg_section="alias"
        cfg_subsection=""
        ;;
      \[[Ii][Nn][Cc][Ll][Uu][Dd][Ee]\]*)
        # #304/#305: a plain [include] section — the child path key is dispatched below.
        cfg_section="include"
        cfg_subsection=""
        ;;
      \[[Ii][Nn][Cc][Ll][Uu][Dd][Ee][Ii][Ff]\ \"*\"\]*)
        # #304/#305: an [includeIf "<condition>"] section — the condition itself is never
        # evaluated (the union, over-blocking stance Open question 3 settles): every conditional
        # include is followed exactly like an unconditional one.
        cfg_section="include"
        cfg_subsection=""
        ;;
      \[*)
        cfg_section="other"
        cfg_subsection=""
        ;;
    esac
    # #510: the text after a header's closing bracket is read as a key under the section that header
    # just set, with the same comment strip and key/value split as any other line. A second header
    # in that text (a chained header) is not classified: it denies.
    if [ "$cfg_hdr" = 1 ]; then
      cfg_h="${cfg_rest%%#*}"
      cfg_s="${cfg_rest%%;*}"
      if [ "${#cfg_h}" -le "${#cfg_s}" ]; then cfg_rest="$cfg_h"; else cfg_rest="$cfg_s"; fi
      case "$cfg_rest" in
        *[![:space:]]*) ;;
        *) continue ;;
      esac
      cfg_lead="${cfg_rest%%[![:space:]]*}"
      case "${cfg_rest#"$cfg_lead"}" in
        \[*) deny_too_large confighdr ;;
      esac
      cfgline="$cfg_rest"
    fi
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
            # source-label field. cfg_subsection (the remote name) is read from a section header
            # (a quoted, dotted or mixed spelling, rewritten to the canonical text above), never from
            # a value; a raw TAB inside a quoted name is possible but no fixture this file constructs
            # carries one.
            cfg_push_lines="${cfg_push_lines}${label}${cfg_tab}${cfg_subsection}${cfg_tab}${cfg_val}"$'\n'
            ;;
        esac
        ;;
      alias)
        # #448: label first, then key, then the value as the unbounded tail (the same reasoning as
        # cfg_push_lines above): a value holding a TAB byte cannot truncate into another field.
        [ "$cfg_cr_mid" = 0 ] || cfg_val="!"
        cfg_alias_lines="${cfg_alias_lines}${label}${cfg_tab}${cfg_key}${cfg_tab}${cfg_val}"$'\n'
        ;;
      aliassub)
        # #448: a subsection alias, command = <expansion>, recorded under the name-independent key "*".
        case "$cfg_key" in
          [Cc][Oo][Mm][Mm][Aa][Nn][Dd])
            [ "$cfg_cr_mid" = 0 ] || cfg_val="!"
            cfg_alias_lines="${cfg_alias_lines}${label}${cfg_tab}*${cfg_tab}${cfg_val}"$'\n'
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
# below) and, per push or alias-candidate segment whose "-C" value passes is_c_target_path(), once more with
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
  cfg_alias_lines=""
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
    # list, an include form this hook cannot resolve, and config.worktree) — since #439 a
    # command-line "-c"/"--config-env" option or a GIT_CONFIG_* environment assignment, and since #448 an
    # inline HOME=/XDG_CONFIG_HOME= relocation, denies the push outright instead of being read as config.
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
session_cfg_alias_lines="$cfg_alias_lines"
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
# pre-#269 file-scope statements did. Called once per push or alias-candidate segment (see the driver loop below),
# before that segment's own "-C" value (if any) is considered — so a segment with no "-C", or one
# whose "-C" value satisfies PATH_ERE but resolves no gitdir of its own, is judged by these session
# facts alone. A "-C" value that fails PATH_ERE (and is not lexically the session checkout) never
# reaches this function's facts at all: the driver loop below denies it outright first (#292).
apply_session_repo() {
  default_branch="$session_default_branch"
  current_branch="$session_current_branch"
  cfg_push_lines="$session_cfg_push_lines"
  cfg_alias_lines="$session_cfg_alias_lines"
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
  local resolved_default resolved_cfg_alias_lines
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
  resolved_cfg_alias_lines="$cfg_alias_lines"
  resolved_cfg_push_defaults="$cfg_push_defaults"
  resolved_cfg_branch_merge="$cfg_branch_merge"
  resolved_default="$default_branch"
  current_branch="$resolved_current"
  cfg_push_lines="$resolved_cfg_push_lines"
  cfg_alias_lines="$resolved_cfg_alias_lines"
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
    *:*) dest="${tok%%:*}"; dest="${tok:$((${#dest} + 1))}" ;;
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
      check_deadline
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
      check_deadline
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

# alias_deny NAMES (#448) — NAMES is the space-joined, already lowercased candidate list from one
# "ALIAS" tokenizer line: the single subcommand of an ordinary alias candidate, or every remaining
# token of a segment the tokenizer lost (see emit_alias_lost()). Looks each up as `alias.<name>` in
# the alias records the repo-resolution parse above captured (every candidate file read, the
# resolved checkout's own `-C` target included) and denies when the expansion COULD push. One awk
# pass over the records, fed by a here-string — never a pipe, never argv, never the shell: the
# candidate names and the alias values are only ever compared, never executed or echoed. The first
# word of the value, with quotes and backslashes stripped and lowercased, decides: `push`, an empty
# word, a `!` shell alias, an option (a leading `-` hides the subcommand behind it), or the name of
# ANOTHER defined alias (a chain this hook does not follow) all deny, and so does a value ending in
# a backslash (a continuation the line parser does not join). Any other value gives no opinion. Git
# never lets an alias shadow a built-in command, so the lookup alone decides and no built-in list is
# needed; the price is that an alias NAMED like a built-in and expanding to push denies that built-in
# here although git ignores it. On a deny sets __deny_src to the source label (one of the fixed
# labels cfg_parse_file() builds, never input text), __deny_dest/__deny_kind to "alias".
alias_deny() {
  __deny_dest=""
  __deny_kind=""
  __deny_via=""
  __deny_src=""
  [ -n "$cfg_alias_lines" ] || return 0
  local alias_hit
  alias_hit="$(awk -F "$cfg_tab" '
    NR == 1 { n = split($0, cand, " "); for (i = 1; i <= n; i++) want[cand[i]] = 1; next }
    {
      lab[NR] = $1
      key[NR] = tolower($2)
      val[NR] = substr($0, length($1) + length($2) + 3)
      defined[key[NR]] = 1
    }
    END {
      for (r = 2; r <= NR; r++) {
        if (!(key[r] in want) && key[r] != "*") continue
        v = val[r]
        if (substr(v, length(v)) == "\\") { print lab[r]; exit }
        w = v
        gsub(/\\[tnb]/, " ", w)
        sub(/^[ \t]+/, "", w)
        sub(/[ \t].*$/, "", w)
        gsub(/[\\"\047]/, "", w)
        w = tolower(w)
        if (w == "" || substr(w, 1, 1) == "!" || substr(w, 1, 1) == "-" || w == "push" || (w in defined)) { print lab[r]; exit }
      }
    }
  ' <<<"$1$nl$cfg_alias_lines")"
  if [ -n "$alias_hit" ]; then
    __deny_dest="alias"
    __deny_kind="alias"
    __deny_src="$alias_hit"
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
  for t in $rest; do check_deadline; toks+=("$t"); done
  local ntok="${#toks[@]}"
  local idx=0

  while [ "$idx" -lt "$ntok" ]; do
    check_deadline
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
    check_deadline
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
      if [ "$d1" = '$' ]; then __deny_dest='$'; __deny_kind="rxdest"; return; fi
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
    check_deadline
    local d
    d="$(refspec_dest "${nonopt[$idx]}")"
    if [ "$d" = '$' ]; then __deny_dest='$'; __deny_kind="rxdest"; return; fi
    if [ -n "$d" ] && is_deny_member "$d"; then
      __deny_dest="$d"; __deny_kind="dest"
      return
    fi
    idx=$((idx + 1))
  done
}

# --- drive the verdict over every push segment and alias candidate found (first offender decides)
TAB="$(printf '\t')"
deny_dest=""
deny_kind=""
deny_via=""
deny_src=""
# #433: xseg_reason/saw_push back the post-loop cross-segment fallback below (after this `while`
# exits with no other deny) — see that fallback's own comment for why it runs last.
xseg_reason=""
saw_push=0
while IFS= read -r line; do
  check_deadline
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
    "-alias-cmdline-config-")
      # #448: fixed reason, no input — see the aliascfg) message arm below.
      deny_dest="unreadable config"
      deny_kind="aliascfg"
      break
      ;;
    "-xcfg-") continue ;;
    "-xseg-$TAB"*) xseg_reason="${line#-xseg-"$TAB"}"; continue ;;
    "ALIAS$TAB"*)
      # #448: an alias candidate (a git segment whose subcommand is not push). A relocation or
      # command-line-config export elsewhere in the command denies it outright; otherwise the alias
      # records of the session checkout (or its resolved -C target) decide. Never sets saw_push: the
      # push-gated fallbacks below stay push-only.
      al_body="${line#ALIAS$TAB}"
      al_cpath="${al_body%%"$TAB"*}"
      al_names="${al_body#*"$TAB"}"
      if [ "$xcfg_seen" = 1 ]; then
        deny_dest="unreadable config"
        deny_kind="aliascfg"
        break
      fi
      apply_session_repo
      apply_c_target "$al_cpath"
      alias_deny "$al_names"
      if [ -n "$__deny_dest" ]; then
        deny_dest="$__deny_dest"
        deny_kind="$__deny_kind"
        deny_src="$__deny_src"
        break
      fi
      continue
      ;;
    "PUSH$TAB"*) : ;;
    *) continue ;;
  esac
  saw_push=1
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

# #433: cross-segment ("xseg") fallback — runs only after every push segment above already got a
# chance to deny for its OWN reason (an in-segment reason always keeps precedence: guarded by
# `[ -z "$deny_dest" ]`, though see dev/hook-tests.sh's own "xseg" section header for why no
# fixture can independently exercise that one guard given this loop's own break-on-deny shape),
# and only when this command actually contains a push segment at all (`[ "$saw_push" = 1 ]` — a
# bare `cd`/`export` with no push must stay a no-opinion; since #448 a scan can pass the #435 early exit
# on an ALIAS candidate line alone, so this guard is what keeps that command a no-opinion). Reuses the existing "unresolved" verdict
# below unchanged; xseg_reason is always either a fixed phrase or "<NAME> set earlier in this
# command" for a GIT_REPO_ENV_VARS member NAME (see emit_segment()'s "xseg" comment above), so this
# echoes no input.
if [ -z "$deny_dest" ] && [ "$saw_push" = 1 ] && [ -n "$xseg_reason" ]; then
  deny_dest="$xseg_reason"
  deny_kind="unresolved"
fi

# #494: Codex shell `workdir` fail-closed fallback — see this file's header "Fail-closed: Codex
# shell workdir (#494)" paragraph for the full rule and its containment argument. Runs LAST, after
# every other verdict above had its chance (an existing reason always keeps precedence: guarded by
# `[ -z "$deny_dest" ]`), only for a push this hook would otherwise let through, and only for a
# Codex-shaped payload (a non-empty `turn_id`) — a Claude Code payload never reaches the body.
# Every failure mode below denies, with one of five FIXED reason strings; the transcript is parsed
# as data by jq and awk, compared by string equality only, never executed, never opened as a path,
# and never echoed. An empty or garbled pipeline output is "no tool call", which also denies.
if [ -z "$deny_dest" ] && [ "$saw_push" = 1 ]; then
  codex_turn="$(printf '%s' "$input" | jq -r '.turn_id? // empty' 2>/dev/null)"
  if [ -n "$codex_turn" ]; then
    check_deadline
    wd_reason=""
    wd_tp="$(printf '%s' "$input" | jq -r '.transcript_path? // empty' 2>/dev/null)"
    if [ -z "$wd_tp" ] || [ ! -f "$wd_tp" ] || [ ! -r "$wd_tp" ]; then
      wd_reason="Codex transcript missing or unreadable"
    else
      # jq stage: every model tool-call record in the window, completed or not (a code-mode cell can
      # yield its output record and keep running, so completion proves nothing), then every
      # occurrence of a workdir key in its call text, each printed as one `T<TAB><the text after the
      # key>` line (newlines flattened, 1024 chars). Window edge: a line that does not parse as JSON
      # but contains a workdir key prints BAD, and an unparseable FIRST line of at least half the
      # window (its UTF-8 bytes, summed from `explode`) prints EDGE alone. No regex builtin (jq 1.5
      # without Oniguruma) and no `IN`; the first line is EDGE, CALLS or NONE.
      # awk stage: classifies each T line as no workdir (null: no output), a plain string literal
      # (`LIT<TAB><body>`), or anything else (`BAD`).
      wd_out="$(tail -c "$PUSH_TRANSCRIPT_TAIL_BYTES" 2>/dev/null < "$wd_tp" \
        | jq -R -n -r --arg keys "$PUSH_WORKDIR_KEYS" --argjson half "$((PUSH_TRANSCRIPT_TAIL_BYTES / 2))" '
            [inputs] as $lines
            | ($keys | split(" ")) as $ks
            | [$lines[] | . as $l | ([try ($l | fromjson | [.]) catch null] | .[0])] as $parsed
            | [$parsed[] | select(. != null) | .[0]
                | select(type == "object" and .type == "response_item") | .payload | select(type == "object")
                | select(.type == "custom_tool_call" or .type == "function_call" or .type == "local_shell_call")] as $calls
            | if ($lines | length) > 0 and $parsed[0] == null
                 and (($lines[0] | explode | map(if . < 128 then 1 elif . < 2048 then 2 elif . < 65536 then 3 else 4 end) | add // 0) >= $half)
              then "EDGE"
              elif ($calls | length) == 0 then "NONE"
              else "CALLS",
                (range(0; $lines | length) as $i | select($parsed[$i] == null)
                  | $lines[$i] as $l | select(any($ks[]; . as $k | ($l | split($k) | length) > 1)) | "BAD"),
                ($calls[] | [.input, .arguments, .action] | map(select(. != null) | if type == "string" then . else tojson end) | .[] as $txt
                  | $ks[] as $k
                  | $txt | split($k) | .[1:][]
                  | split("\n") | join(" ") | split("\r") | join(" ") | "T\t" + .[0:1024])
              end' 2>/dev/null \
        | awk '
            BEGIN {
              sq = sprintf("%c", 39)
              dq = sprintf("%c", 34)
              pre = "^[ \t]*[" dq sq "]?[ \t]*:[ \t]*"
            }
            $0 == "EDGE" || $0 == "CALLS" || $0 == "NONE" || $0 == "BAD" { print; next }
            substr($0, 1, 2) != "T\t" { print "BAD"; next }
            {
              t = substr($0, 3)
              if (!match(t, pre)) { print "BAD"; next }
              rest = substr(t, RLENGTH + 1)
              if (rest ~ /^null[ \t]*[,}]/) next
              q = substr(rest, 1, 1)
              if (q != dq && q != sq) { print "BAD"; next }
              lit = substr(rest, 2)
              p = index(lit, q)
              if (p == 0) { print "BAD"; next }
              body = substr(lit, 1, p - 1)
              after = substr(lit, p + 1)
              if (index(body, "\\") > 0) { print "BAD"; next }
              if (after !~ /^[ \t]*[,}]/) { print "BAD"; next }
              print "LIT\t" body
            }' 2>/dev/null)"
      wd_first="${wd_out%%"$nl"*}"
      if [ "$wd_first" = "EDGE" ]; then
        wd_reason="Codex transcript record exceeds the hook's read window"
      elif [ "$wd_first" != "CALLS" ]; then
        wd_reason="no Codex tool call in its transcript"
      else
        while IFS= read -r wd_line; do
          check_deadline
          case "$wd_line" in
            CALLS) continue ;;
            "LIT$TAB"*)
              if ! is_session_checkout_path "${wd_line#LIT"$TAB"}"; then
                wd_reason="Codex shell workdir names another directory"
                break
              fi
              ;;
            *)
              wd_reason="Codex shell workdir is not a plain string literal"
              break
              ;;
          esac
        done <<<"$wd_out"
      fi
    fi
    if [ -n "$wd_reason" ]; then
      deny_dest="$wd_reason"
      deny_kind="workdir"
    fi
  fi
fi

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
    workdir)
      # #494: deny_dest is always one of the FIXED reason strings set by the Codex workdir block
      # above — never any transcript or command text.
      printf '%s denies this push: it cannot resolve which repository the push runs in (%s) — a Codex shell workdir is not in the hook payload, and any recent tool call in the session transcript whose workdir is not the session directory as a plain string literal keeps this denying; issue the push with no workdir from a session started in that checkout, or a human can run it from a terminal; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" "$deny_dest" >&2
      ;;
    alias)
      # #448: the only %s is the fixed source label cfg_parse_file() builds — never the alias name,
      # its value, or any command token.
      printf '%s denies this git command (blocked: git alias may push) — defined in %s: a git alias that may expand to a push is never run here, since this hook cannot tell where it pushes — run the real subcommand instead, or a human can run it from a terminal; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" "$deny_src" >&2
      ;;
    aliascfg)
      # #448: fixed message, no %s for input.
      printf '%s denies this git command (blocked: unreadable git config may define an alias): it runs under git config this hook does not read (git -c, --config-env, a GIT_CONFIG_* assignment, or an inline or exported HOME=/XDG_CONFIG_HOME=), so it cannot rule out that the subcommand is an alias for a push — the harness never runs git this way; drop the extra config, or a human can run it from a terminal; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" >&2
      ;;
    rxdest)
      # #517: fixed message, no %s for input -- the destination is never echoed.
      printf '%s denies this push: its destination is built at run time (blocked: runtime expansion in the push destination), so it cannot rule out the default branch — spell the destination branch literally, or push HEAD; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" >&2
      ;;
    cmdcfg)
      # #439: fixed message, no %s for input — never echoes the -c key/value or a matched
      # GIT_CONFIG_KEY_<suffix>/GIT_CONFIG_VALUE_<suffix> name.
      printf '%s denies this push: it carries git config supplied on the command line (git -c, --config-env, a GIT_CONFIG_* environment assignment, or an inline HOME=/XDG_CONFIG_HOME= that relocates the global git config), which this hook does not read, so it cannot rule out the default branch — the harness never pushes this way; drop the command-line config, or a human can run it from a terminal; see README.md'"'"'s Safety model\n' \
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
