#!/usr/bin/env bash
#
# push-guard.sh — plugin-shipped PreToolUse hook (#260) that mechanically narrows every Bash call's
# `git push` surface in EVERY session, the main session included (unlike hooks/agent-boundary.sh, which
# governs only the implementer and verifier subagents). The settings deny entries (`Bash(git push origin
# main:*)`) are prefix-matched and are bypassed by refspec spellings such as `HEAD:main`,
# `+HEAD:refs/heads/main` or a remote other than origin; this hook parses the refspec instead of
# pattern-matching the raw command text.
#
# Contract: read the PreToolUse hook JSON on stdin. Print nothing and exit 0 ("no opinion") unless the call is
# a Bash command that one of the rules below denies; a deny prints exactly one reason line to stderr and exits
# 2, stdout empty. With no opinion the normal permission flow applies (a prompt, or a matching deny rule in
# templates/repo-settings.json, which always wins over this hook). No opinion also for plan mode, a missing
# jq, malformed stdin, another tool, an absent command, and a command whose raw stdin never names git.
# Denies, one class per line; the mechanism of each is described at its code (see "Rule index" below):
#   - a push whose resolved DESTINATION is the default branch, or one of the unconditional fallback members
#     main and master (PUSH_DEFAULT_BRANCH_FALLBACK, pinned against the settings template by gate 4.40(a)(b)),
#     or a destination built at run time (#517); --all and --mirror; and a push with no refspec or one remote
#     argument whose config routes (remote.<name>.push, push.default) resolve to such a destination;
#   - a push segment whose target repository it cannot resolve (#292): a -C value outside the <name>-wt-<n>
#     shape (PATH_ERE) that is not lexically the session checkout, an attached -C<path>, two or more -C,
#     --git-dir, --work-tree, a GIT_DIR, GIT_WORK_TREE or GIT_COMMON_DIR assignment; and, in the same
#     command, a cd, pushd, popd or chdir, or an export or assignment of such a name, in another segment (#433);
#   - a push segment carrying git config supplied on the command line (#439: -c, --config-env, GIT_CONFIG_*
#     assignments), or an inline HOME or XDG_CONFIG_HOME relocation (#448);
#   - a git command whose subcommand is a git alias that may expand to a push, or that runs under config this
#     hook cannot read (#448);
#   - a segment the tokenizer cannot follow while a push could still be in it: a quoted or escaped git option
#     or a quote-split assignment (#449); the separate value of a prefix word's option (#518); an interpreter
#     prefix word's options (#537); a $( or ${ substitution, or a backtick that starts a word or follows a
#     double quote, in the git option slot on a line naming push (#572);
#   - a Codex push whose shell workdir is not provably the session checkout (#494);
#   - an analysis that cannot finish: a command over PUSH_CMD_MAX_BYTES; the deadline; a depth-0 config line
#     over CFG_TOPLEVEL_MAX_LINE_CHARS (#435, #517); an awk scan that exits non-zero (an abort, a resource
#     limit, a killed process, or no runnable awk), denied with the fixed reason "command scan failed" (#559).
# There is deliberately no allow-list of `claude/<n>-<slug>` destinations: it would deny ordinary work (a
# release branch, an annotated-tag push, any `git push origin feature/x` a human runs in ANY Claude Code session
# of a plugin-enabled repo, since this hook is plugin-wide) for no matching safety gain, and a plugin that
# blocks ordinary pushes gets `disableAllHooks: true`, which would cost hooks/agent-boundary.sh's control too.
# That branch shape is this harness's own convention, not mechanically required.
# No `if` gate in hooks/hooks.json: an `if` filter matches only `tool_input.command` constituents after
# composite splitting and leading-assignment stripping, so it cannot see `git -C <wt> push`, `env git push` or
# `bash -c "git push"`; any `if` would silence this hook for exactly the commands it exists to catch.
# This is a tripwire, not a sandbox: branch protection on the default branch remains the real backstop. The
# spellings the hook does not see and the harmless commands it denies (with the remedy for each) are listed in
# docs/reference/safety-model.md, under "Known gaps" and "Known over-blocks".
#
# Rule index. #292, #433, #439, #448, #449, #518, #537 and #572 are described at emit_segment() and
# the tokenizer helpers above it; #517 at dest_word() and evaluate_segment(); the #448 alias lookup at
# emit_segment() and alias_deny(); #494 at the post-loop Codex block; the include and line budgets at
# cfg_parse_file(); the cross-segment fallback at the driver loop.
#
# Repo resolution (reads only, NEVER executes anything). The SESSION checkout is resolved from the stdin
# `cwd` field (degrades to $PWD when absent) by walking up at most 64 parent directories for `<dir>/.git`: a
# directory (an ordinary checkout) or a regular file (a worktree pointer, `gitdir: <path>`; a FIFO or a
# directory-shaped path is excluded by the `[ -f ]` guard every read here uses). The default branch is read
# from the common dir's `refs/remotes/origin/HEAD` symref and the current branch from the resolved gitdir's
# own `HEAD` symref. Config is text-parsed, never run as `git config`: remote.<name>.push, push.default,
# branch.<current>.merge and alias.* records are collected from these candidates, read in this order and
# UNIONED (a route from any file can deny; the repo-local config is read last so a last-wins scalar resolves to
# the repo's own value): the system candidates ($GIT_CONFIG_SYSTEM, the three PUSH_SYSTEM_CONFIG_PATHS and the
# Apple CLT file PUSH_APPLE_CLT_CONFIG, all skipped together when $GIT_CONFIG_NOSYSTEM holds a canonical true
# value), the global candidates ($GIT_CONFIG_GLOBAL, $XDG_CONFIG_HOME/git/config or $HOME/.config/git/config,
# and $HOME/.gitconfig), and the checkout's own config (for a worktree, the MAIN checkout's common-dir
# config). Every such path comes from the ENVIRONMENT or this file's fixed vocabulary, never from the untrusted
# command string, and is read only once the checkout has resolved a gitdir. An `include` or `includeIf` found
# in any parsed file is followed inline in git's own order with the includeIf condition ignored (every
# conditional include is followed: a union); cfg_parse_file() holds the resolution rules, the depth cap, the
# cycle guard and the budgets. Any failure at any step leaves the branch values and the config-derived
# variables empty, never an error; the depth-0 line cap is a deliberate deny, not a failure.
# A resolved -C target (#269). A push (or, #448, alias-candidate) segment carrying exactly one DETACHED `-C
# <path>` token whose value satisfies PATH_ERE (byte-identical to hooks/git-c-guard.sh's predicate, pinned by
# gate 4.42) is ALSO resolved: the named directory itself, one level only (never walking upward the way git does
# from a real -C). When that resolves a gitdir, the segment's current branch and config-derived values come
# SOLELY from that checkout, and its default-branch deny set becomes the union of the fallback, the session's
# default and the resolved checkout's default (a checkout lacking refs/remotes/origin/HEAD, which only
# `git clone` sets, must not silently lose the guard). A value that satisfies the predicate but resolves no
# gitdir leaves the segment judged against the session. The global and system candidates are re-read
# identically for every checkout resolved. Containment: the facts of a resolved target apply ONLY to the
# segment that names it, so a fully attacker-controlled <name>-wt-<n> directory can mis-judge only a push
# executed inside itself, never the session's own segments (every segment starts from apply_session_repo()).
# Other -C shapes deny instead (#292, "Rule index").
# Containment of the other reads. The command string supplies exactly one class of path, the -C value above,
# fed to resolve_repo() with MAX_DEPTH 1 (so it never reaches dirname's argv or any process argv), to `grep`
# only as data through a here-string (never a piped writer, gate 1.7), and to `[ -f ]` / `[ -d ]` builtins;
# it is never eval'd or opened for writing. An include target taken from the CONTENT of a config file already
# read is resolved by parameter expansion only (`~/` against $HOME, an absolute path as is, anything else joined
# onto the including file's directory with ${path%/*}; never dirname, cd or realpath) and fed only to a
# `[ -f ]`-guarded read redirect, so it can only be opened for reading. Content parsed from an included file
# can only ADD a deny route (config_deny's union), except branch.<current>.merge: a last-wins scalar across the
# whole resolution, because one path can legitimately be read more than once in a resolve_repo() call (a
# sibling include, or a later top-level candidate an earlier include already pulled in; see cfg_parse_file()
# on why cfg_seen is ancestor-only), mirroring git itself. For a Codex payload the host-provided
# `transcript_path` is also read (#494), through a `[ -f ]`/`[ -r ]`-guarded redirect into `tail -c`, parsed as
# data only. jq is used only for a few scalar field reads and, for a Codex push, one pass over the rollout tail
# (jq 1.5 builtins, no regex); the command itself is parsed with awk. bash + POSIX awk, no python, perl or
# GNU-only flag; exercised under Apple bash 3.2.
#
# Tokenizer. The POSIX-awk segment/token walker below is a near-twin of hooks/agent-boundary.sh's (see its
# "the scan" section) with a different emitter. A change to any of the following must be applied by hand to
# BOTH files: segment breaking; normalize(); the empty-normalised-token skip (also in the subcommand
# search); the repeat-until-exhausted PREFIX_WORDS skip (a once-only skip is a known regression
# class); the command-word case fold; the CR strip; the #449 assignment-parity
# trigger; the #518 value context. The #537 interpreter-option rule is this script's own: agent-boundary.sh
# reads interpreter options through its #518 value context instead (its PREFIX_VALUE_WORDS also holds the
# interpreter words, #576), and claude-dir-guard.sh does not read them.
# Gate 4.40(c) pins PREFIX_WORDS byte-identical to agent-boundary.sh's; every other shared value is by
# convention, unpinned. Differences: after a segment's command word resolves as `git`, this script walks forward
# again, skipping a GIT_GLOBAL_OPTS_WITH_VALUE token together with its value and any other dash token alone,
# to the first non-dash token, the subcommand (a quote- or backslash-bearing option fails closed when a push
# can follow, #449); only this script has the git-option-slot trigger. If the subcommand is exactly `push`,
# the remaining tokens are emitted quote/backslash-stripped but WITHOUT normalize()'s basename step: a
# refspec destination such as refs/heads/main is a path-shaped value whose slash is load-bearing, and the
# refs/heads/ prefix is what refspec_dest() reads. The CR strip runs inside the awk record block, not as a
# bash expansion.
#
# Destination rules (evaluate_segment, refspec_dest, config_deny). Push options in PUSH_OPTS_WITH_VALUE take
# the next word; n is the count of other non-option words. With n >= 2 the first is the remote (never
# evaluated as a destination: it may be a URL with a colon) and the rest are refspecs. refspec_dest() drops a
# leading plus, takes the text after the first colon (else the whole word), resolves HEAD and @ to the current
# branch, strips refs/heads/, and treats any other refs/ ref as no branch. With n == 1 the lone word is judged
# BOTH as the remote (the scope of the config routes) and defensively as a destination, so a remote literally
# named main denies; the current branch is checked too. With n == 0 the current branch decides. Config routes
# are consulted only for n <= 1, as a union across every remote, file and line (this hook models neither
# git's remote selection nor its last-wins precedence); a configured destination containing * and
# push.default=matching deny unconditionally, like --all and --mirror.
#
# Analysis deadline (#435). This hook's own analysis (everything from the tokenizer onward) is bounded by a
# whole-second wall-clock budget, PUSH_ANALYSIS_BUDGET_SECS (5s), sampled from $SECONDS as an elapsed
# difference from push_t0 (captured right after `set -f`): check_deadline() denies with a fixed reason
# (`deny_too_large deadline`) the first time $SECONDS reaches push_deadline (push_t0 + push_budget), and never
# resets $SECONDS. The sampling rule binds every future addition: call `check_deadline` as the FIRST statement
# of every loop whose trip count grows with the command string or a config file's content, never partway
# through a loop body and never only once at the top of a function that itself contains such a loop. Work
# inside the awk tokenizer (every awk-side rule) is not sampled: it is T_prefix below, bounded by
# PUSH_CMD_MAX_BYTES. The early exit right after the tokenizer, before the deadline is sampled, continues
# only when the scan holds a PUSH line, an ALIAS candidate line or the -cmdline-config- sentinel (a scan that
# is empty or holds only the -xseg- marker exits with no opinion), so a command with no push
# segment and no git alias candidate is never denied merely for being large once it is under the size cap.
# The one step sampling cannot reach mid-step is a depth-0 config line's
# own read and trim: cfg_trim() is not uniformly fast on a long whitespace run, so
# CFG_TOPLEVEL_MAX_LINE_CHARS caps that line's length, checked with ${#cfgline} before comment-strip or trim
# run, and denies (`deny_too_large configline`) instead of ever reaching them. A test-only knob,
# TBF_PUSH_GUARD_BUDGET_SECS, is read from the ENVIRONMENT only and can only LOWER push_budget (exactly one or
# two ASCII digits and strictly less than the production budget; anything else is ignored).
# Command-size cap (#517): a Bash command longer than PUSH_CMD_MAX_BYTES bytes (counted in the C locale by
# pg_bytes(), so a multibyte payload is not undercounted), once past the fast path and the plan-mode exit,
# denies "too large to analyse" before the tokenizer or any other use of the command text, because a timed-out
# hook gives no deny at all. It applies to every such command, whether or not it holds a push (the same shape as
# hooks/claude-dir-guard.sh's cap). Worst-case wall clock, for review: at most `max(push_budget, T_prefix(L)) +
# U_max`. T_prefix is the pre-tokenizer prefix the deadline cannot sample around: `cat`, the fast-path
# glob and the three jq extractions of the raw stdin (linear in the stdin, not bounded by the cap), then, for a
# command at or under the cap, the cwd jq and the awk tokenizer (CR strip included). The tokenizer is bounded
# by the cap, not claimed linear; its output is streamed, and a push word longer than tok_max is rewritten so
# no bash-side split runs on one. U_max is the
# largest single step the deadline cannot interrupt: one alias-lookup awk pass over the resolved alias records,
# one session upward walk (at most 64 levels, each an `[ -f ]` probe, plus up to 63 `dirname` forks), one
# config line's comment-strip plus up to three cfg_trim() calls (at most CFG_TOPLEVEL_MAX_LINE_CHARS or
# CFG_INCLUDE_MAX_LINE_CHARS characters, quadratic only in that capped length), one include open, up to two
# `grep` processes plus a depth-1 resolve's file stats, one refspec_dest() subshell, one word-split of a
# segment's remaining tokens, the `read` of a single config line (linear in its length), or, for a Codex push,
# the one `tail -c` + jq + awk pass over the rollout tail (bounded by PUSH_TRANSCRIPT_TAIL_BYTES). Not closed:
# T_prefix is unsampled (though counted by the wall clock); the single config-line `read` inside U_max is spent
# before check_deadline can run again; and the Codex CLI's own hook timeout, if any, is UNVERIFIED: the
# deadline is sized against Claude Code's documented 10s PreToolUse timeout only (hooks/hooks.json,
# "timeout": 10).
set -uo pipefail
set -f  # noglob: untrusted refspec tokens are word-split unquoted below (e.g. in evaluate_segment
        # and the token-array builders); a token shaped like "*:main" must never glob-expand
        # against files in $PWD or a resolved repo directory.

# Sampled once, at hook start (#435): check_deadline() measures elapsed time as the difference from this value,
# never by resetting $SECONDS (see "Analysis deadline (#435)" in the header).
push_t0=$SECONDS

# --- vocabulary ----------------------------------------------------------------------------
# Grep-extractable single-line KEY="value" declarations (the 2.5/4.36-4.39 idiom), kept on their own lines so
# dev/selfcheck.sh can extract them mechanically.
PUSH_DEFAULT_BRANCH_FALLBACK="main master"
# PREFIX_WORDS: byte-identical to hooks/agent-boundary.sh's, pinned by gate 4.40(c); that file holds the
# reasoning. Words after which the next word is still in command position: interpreter-indirection words, the
# shell reserved words that directly precede a command (if, then, do, while, !), and eval.
PREFIX_WORDS="env command builtin exec sudo nohup time nice stdbuf xargs bash sh zsh ksh dash if then elif else do while until ! coproc eval"
GIT_GLOBAL_OPTS_WITH_VALUE="-c -C --git-dir --work-tree --namespace --config-env --exec-path"
# PATH_ERE (#269): byte-identical to hooks/git-c-guard.sh's, pinned by gate 4.42. is_c_target_path() uses it to
# decide whether a push segment's `git -C <path>` value is trusted enough to resolve ("Repo resolution").
PATH_ERE='^([A-Za-z]:/|/|\.\./)([A-Za-z0-9._ +-]+/)*[A-Za-z0-9._+-]+-wt-[0-9]+/?$'
PUSH_OPTS_WITH_VALUE="-o --push-option --repo --receive-pack --exec"
PUSH_ALL_REFS_OPTS="--all --mirror"
PUSH_DENY_STEM="trail-blazer-flow push guard:"
# System config candidates (#304/#305), governed by $GIT_CONFIG_NOSYSTEM; see the candidate loop in
# resolve_repo(). The Apple CLT file sits INSIDE that guard too (verified live: NOSYSTEM drops its scope).
PUSH_SYSTEM_CONFIG_PATHS="/etc/gitconfig /opt/homebrew/etc/gitconfig /usr/local/etc/gitconfig"
PUSH_APPLE_CLT_CONFIG="/Library/Developer/CommandLineTools/usr/share/git-core/gitconfig"
# CFG_INCLUDE_MAX_DEPTH: the most include hops cfg_parse_file() follows from a depth-0 candidate; a backstop
# beside the cycle guard, not a claim that git enforces the same limit.
CFG_INCLUDE_MAX_DEPTH=10
# CFG_INCLUDE_MAX_FOLLOWS: the most include FOLLOW operations across one whole resolve_repo() call, never reset
# between sibling branches. Depth alone does not bound the work: a sibling include of the same path is
# deliberately re-read every time (cfg_seen is ancestor-only), so a file naming one child K times per level
# fans out to about K^depth follows. The include arm follows only while the follow, line and character
# budgets all still have room.
CFG_INCLUDE_MAX_FOLLOWS=64
# CFG_INCLUDE_MAX_LINES: the most LINES read across every included file combined, per resolve_repo() call
# (depth >= 1 only, shared, never reset per file). A follow count alone does not bound total work: a few
# follows of one large file can cost as many lines as the file is long. A depth-0 candidate is read in full;
# only its single-line length is capped (CFG_TOPLEVEL_MAX_LINE_CHARS).
CFG_INCLUDE_MAX_LINES=2048
# CFG_INCLUDE_MAX_LINE_CHARS: an included line (depth >= 1) longer than this skips comment-strip and trim
# entirely (it still spends the line and character budgets) and parsing continues at the next line. Checked
# with ${#cfgline}, O(n) but cheap relative to cfg_trim(), whose cost on a long whitespace run is not linear.
# The length counts characters, not bytes.
CFG_INCLUDE_MAX_LINE_CHARS=512
# CFG_INCLUDE_MAX_CHARS: the most CHARACTERS charged across every included line combined (depth >= 1), per
# resolve_repo() call. Charged once per line, ${#cfgline}+1, BEFORE the line cap above, so a skipped long line
# counts fully. It bounds a different shape than CFG_INCLUDE_MAX_LINES: many lines just under the line cap.
CFG_INCLUDE_MAX_CHARS=65536
# PUSH_ANALYSIS_BUDGET_SECS (#435): the whole-second budget this hook's analysis may spend before check_deadline()
# denies; see "Analysis deadline (#435)" in the header.
PUSH_ANALYSIS_BUDGET_SECS=5
# PUSH_CMD_MAX_BYTES (#517): the longest Bash command, in BYTES, analysed at all. A longer one that got past the
# fast path denies before the tokenizer runs, because a timed-out hook gives no deny.
PUSH_CMD_MAX_BYTES="524288"
# CFG_TOPLEVEL_MAX_LINE_CHARS (#435): a depth-0 config line longer than this denies outright, checked BEFORE
# comment-strip or trim, instead of reaching cfg_trim() (see its comment).
CFG_TOPLEVEL_MAX_LINE_CHARS=2048
# GIT_REPO_OPTS / GIT_REPO_ENV_VARS (#292): a push segment naming one of these always redirects which repository
# the push runs in, and this hook resolves neither: GIT_REPO_OPTS is a global option (detached or attached),
# GIT_REPO_ENV_VARS a leading shell assignment (bare, or behind env). The tokenizer flags the segment
# unresolved and the driver loop denies it. GIT_REPO_ENV_VARS also feeds the cross-segment (xseg) check.
GIT_REPO_OPTS="--git-dir --work-tree"
GIT_REPO_ENV_VARS="GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR"
# PUSH_DIR_CHANGE_WORDS (#433): a push segment in the same command as a segment resolving to one of these is
# denied as unresolved (the xseg check): the hook cannot tell whether the change reaches the push's cwd.
PUSH_DIR_CHANGE_WORDS="cd pushd popd chdir"
# PUSH_EXPORT_WORDS (#433): an export-family builtin naming a GIT_REPO_ENV_VARS member also sets xseg (the hook
# does not model whether the builtin actually exports the name).
PUSH_EXPORT_WORDS="export declare typeset local readonly"
# GIT_CMDCFG_OPTS / GIT_CMDCFG_ENV_VARS / GIT_CMDCFG_ENV_PREFIXES (#439): git config supplied ON THE COMMAND
# LINE, as an option before the subcommand (detached or attached -c, --config-env) or as a leading assignment,
# bare or behind env (exact names, or a name starting with one of the prefixes for the GIT_CONFIG_KEY_<n> /
# GIT_CONFIG_VALUE_<n> pair). It adds config on top of the files this hook reads, and the hook never reads it,
# so a push segment carrying one is denied outright, whatever the key or the destination. Push-guard-only: no
# twin in agent-boundary.sh.
GIT_CMDCFG_OPTS="-c --config-env"
GIT_CMDCFG_ENV_VARS="GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM"
GIT_CMDCFG_ENV_PREFIXES="GIT_CONFIG_KEY_ GIT_CONFIG_VALUE_"
# GIT_CFG_RELOC_ENV_VARS (#448): an assignment that moves a config FILE this hook reads (HOME and
# XDG_CONFIG_HOME relocate the global config; GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM name files outright). Set
# inline (bare or behind env) the hook reads the wrong file: a push segment carrying one denies through the #439
# message, a non-push git segment as unreadable config that may define an alias. Push-guard-only.
GIT_CFG_RELOC_ENV_VARS="HOME XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM"
# PREFIX_VALUE_WORDS (#518): the PREFIX_WORDS members whose dash options can take a SEPARATE value word (nice -n
# 5, sudo -u root). Interpreter words stay out (their -c value IS the command string; see PREFIX_INTERP_WORDS).
# Matches no other copy: the agent-boundary.sh copy also holds the interpreter words (#576).
PREFIX_VALUE_WORDS="exec nice stdbuf sudo time xargs"
# PREFIX_INTERP_WORDS / INTERP_VALUE_OPTS (#537): the interpreter members of PREFIX_WORDS, and the long options
# of those interpreters that take a SEPARATE value word. Their options are classified by ip_kind(). This rule is
# this hook's own (#576): agent-boundary.sh and claude-dir-guard.sh carry no copy of these two lines.
PREFIX_INTERP_WORDS="bash dash ksh sh zsh"
INTERP_VALUE_OPTS="--init-file --rcfile -init-file -rcfile"
# PUSH_TRANSCRIPT_TAIL_BYTES (#494): the most bytes read from the END of the Codex rollout file named by the
# payload's transcript_path. A record pushed out of this window is not seen, a window holding no call record
# denies, and half of this size is the unparseable-first-line limit.
PUSH_TRANSCRIPT_TAIL_BYTES="1048576"
# PUSH_WORKDIR_KEYS (#494): the property names treated as a Codex shell tool's working-directory parameter
# (workdir for exec_command, working_directory for a local_shell_call action), consumed by the jq stage of the
# post-loop Codex block. A cwd-like parameter under any other name is not seen.
PUSH_WORKDIR_KEYS="workdir working_directory"

# is_c_target_path PATH (#269): true iff PATH satisfies the shared PATH_ERE predicate. A here-string, not a
# printf piped into `grep -q` (#255, gate 1.7): that early-exit reader can send the writer SIGPIPE and, under
# `set -uo pipefail`, turn a genuine match into a reported pipeline failure.
is_c_target_path() { grep -qE "$PATH_ERE" <<<"$1"; }

# pg_bytes STRING (#517) sets pg_n to STRING's length in BYTES (C locale, whatever locale the hook runs under);
# mirrors hooks/claude-dir-guard.sh's cdg_bytes.
pg_bytes() { local LC_ALL=C; pg_n="${#1}"; }

# push_budget defaults to PUSH_ANALYSIS_BUDGET_SECS. TBF_PUSH_GUARD_BUDGET_SECS (#435) is a test-only,
# environment-only knob that can only LOWER it (exactly one or two ASCII digits, strictly less than push_budget).
push_budget="$PUSH_ANALYSIS_BUDGET_SECS"
case "${TBF_PUSH_GUARD_BUDGET_SECS:-}" in
  [0-9]|[0-9][0-9]) [ "$TBF_PUSH_GUARD_BUDGET_SECS" -lt "$push_budget" ] && push_budget="$TBF_PUSH_GUARD_BUDGET_SECS" ;;
esac
push_deadline=$((push_t0 + push_budget))

# deny_too_large KIND (#435): KIND is configline (the depth-0 line cap), command (#517, a command over
# PUSH_CMD_MAX_BYTES) or anything else (the deadline). Prints exactly one fixed stderr line that echoes no
# input, then exits 2.
deny_too_large() {
  case "$1" in
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

# check_deadline (#435): called as the first statement of every loop whose trip count grows with the command or
# a config file's content (the sampling rule is in the header). Kept on one line so a mutant that neuters its
# body has a single, unique `from` to target.
check_deadline() { [ "$SECONDS" -lt "$push_deadline" ] || deny_too_large deadline; }

input="$(cat)"

# One fast path, a performance shortcut that is semantics-preserving with the check it stands in for EXCEPT for
# a command word split by quote, backslash or carriage-return characters (the same quote-blind limit as
# hooks/agent-boundary.sh's fast paths): a call may skip the tokenizer only when its raw stdin never names git
# (case-folded). A command word built at run time with no git text in the call (a variable that holds git)
# exits here unseen (safety-model.md, Known gaps). There is no `push` literal fast path: a git alias that
# expands to push carries no push text. A CR inside the raw git literal (`g<CR>it`, escaped by the JSON
# writer) exits here before the strip runs; such a command cannot run as a real git either. A miss means the
# call is out of scope for this hook.
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

# #517: the command-size cap, before anything else touches $cmd (see PUSH_CMD_MAX_BYTES above).
pg_bytes "$cmd"
[ "$pg_n" -le "$PUSH_CMD_MAX_BYTES" ] || deny_too_large command

# The carriage-return strip (#270) runs inside the awk tokenizer, one gsub per record before anything else reads
# the record, not as a whole-text bash expansion, which does not finish within the hook timeout on a long run of
# CRs. It is not done in normalize(), which refspec destination tokens never pass through.

[ -n "$cmd" ] || exit 0

# cwd is a documented PreToolUse stdin field; its absence is not an exit. Repo resolution falls back to $PWD
# and, ultimately, to the unconditional PUSH_DEFAULT_BRANCH_FALLBACK deny set.
cwd="$(printf '%s' "$input" | jq -r '.cwd? // empty' 2>/dev/null)"

# --- the tokenizer (POSIX awk, inlined) -------------------------------------------------------
# A near-twin of hooks/agent-boundary.sh's scan (see the header). Each output line is one of:
#   PUSH<TAB><-C value, only when exactly one><TAB><#292 unresolved reason, empty when none><TAB><space-joined
#       remaining tokens>   a push segment; with an empty -C value, a fixed reason and no tokens, a segment that
#       lost the tokenizer but could still be a push (emit_lost, #449, #518, #537, #572);
#   ALIAS<TAB><-C value><TAB><subcommand>   a git segment whose subcommand is not push (#448): the lowercased
#       subcommand;
#   -alias-cmdline-config-   a git segment under config the hook cannot read (#448);
#   -cmdline-config-         a push segment carrying command-line git config (#439);
#   -xseg-<TAB><reason>      last, once, iff any segment resolved to a directory-change builtin or exported or
#       bare-assigned a GIT_REPO_ENV_VARS member or a command-line-config name (#433).
# No field can contain a TAB, since tokens come from splitting on [ \t]+. Each input line (awk record) is
# processed on its own: the same deliberate false-positive class agent-boundary.sh documents.
scan_out="$(printf '%s\n' "$cmd" | awk -v prefix_words="$PREFIX_WORDS" -v gopts="$GIT_GLOBAL_OPTS_WITH_VALUE" -v repoopts="$GIT_REPO_OPTS" -v repoenv="$GIT_REPO_ENV_VARS" -v dirwords="$PUSH_DIR_CHANGE_WORDS" -v exportwords="$PUSH_EXPORT_WORDS" -v cmdcfgopts="$GIT_CMDCFG_OPTS" -v cmdcfgenv="$GIT_CMDCFG_ENV_VARS" -v cmdcfgpfx="$GIT_CMDCFG_ENV_PREFIXES" -v relocenv="$GIT_CFG_RELOC_ENV_VARS" -v vpwords="$PREFIX_VALUE_WORDS" -v ipwords="$PREFIX_INTERP_WORDS" -v ipvopts="$INTERP_VALUE_OPTS" '
BEGIN {
  sq = sprintf("%c", 39)
  cr = sprintf("%c", 13)
  # #517: the longest push-rest word (other than an option) whose destination is read at all; see dest_word()
  tok_max = 4096
  n = split(prefix_words, pwarr, " ")
  for (i = 1; i <= n; i++) prefix_set[pwarr[i]] = 1
  nvp = split(vpwords, vparr, " ")
  for (i = 1; i <= nvp; i++) vprefix_set[vparr[i]] = 1
  # #537: the interpreter prefix words, and the long options of those interpreters that take a value
  nip = split(ipwords, iparr, " ")
  for (i = 1; i <= nip; i++) ip_set[iparr[i]] = 1
  nipv = split(ipvopts, ipvarr, " ")
  for (i = 1; i <= nipv; i++) ipv_set[ipvarr[i]] = 1
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
  # #433: xseg is a per-COMMAND flag (never reset per record), first-writer-wins and order-independent across
  # the whole command; the END block emits it once.
  xseg = ""
  # #439
  ncco = split(cmdcfgopts, ccoarr, " ")
  for (i = 1; i <= ncco; i++) ccopt_set[ccoarr[i]] = 1
  nce = split(cmdcfgenv, cearr, " ")
  for (i = 1; i <= nce; i++) ccenv_set[cearr[i]] = 1
  nccp = split(cmdcfgpfx, ccparr, " ")
  # #448: the config-file relocation names
  nrl = split(relocenv, rlarr, " ")
  for (i = 1; i <= nrl; i++) reloc_set[rlarr[i]] = 1
  has_bt = 0
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
# whole_lit (#517): the body of a word that is EXACTLY one ANSI-C or locale segment (a dollar sign, a quote, a
# plain name, the same quote): a letter, digit or underscore, then letters, digits, underscore, dot or hyphen.
# Else the empty string. dest_word() reads such a word as the name it spells (a dollar-quoted zqp is the
# branch zqp). This program is single-quoted shell: it must never contain a literal apostrophe.
function whole_lit(tok,    q, b) {
  q = substr(tok, 2, 1)
  if (substr(tok, 1, 1) != "$" || (q != sq && q != "\"")) return ""
  if (length(tok) < 4 || substr(tok, length(tok)) != q) return ""
  b = substr(tok, 3, length(tok) - 3)
  if (b ~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/) return b
  return ""
}
# dest_word (#517): the form a push-rest token takes on the PUSH line. A token whose destination (the text
# after the first colon, else after an optional leading plus, else the whole token) holds no dollar sign is just
# strip_quotes(tok). A destination that is exactly one plain ANSI-C or locale segment is read as the name it
# spells. Any other destination holding a dollar sign becomes the single character dollar, so the bash side
# denies it (kind rxdest) without echoing it. A word that is not an option and is longer than tok_max is
# rewritten the same way: no real remote, branch or refspec is that long, and the bash side splits a refspec
# at its first colon with pattern removals whose cost grows with the square of the word on bash 3.2. An
# OPTION (a leading dash after the quote strip) is returned stripped and otherwise untouched, because a
# rewrite would turn it into a non-option argument and shift the remote and refspec positions. O(length).
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
# #449 fail-closed: a segment the tokenizer cannot follow. The walk splits on whitespace and strips quotes only
# to resolve a command word, so a quoted or escaped option or a quoted value with a space can make it lose
# track of the segment while git itself still pushes. Two triggers in emit_segment(), each denying through the
# #292 unresolved route with one FIXED reason, never command text:
# (a) in the git option slot, a token carrying a quote or backslash whose unquoted form starts with a dash
# (strip_quotes, not normalize, which keeps only the last path component), and the VALUE of a global option
# other than -C, or an attached option, that the whitespace split cut in two (the -C value is exempt: the
# harness own `git -C "<path with a space>" push` must not deny); (b) in the command prefix, an assignment
# with an odd count of double quotes, an odd count of single quotes or a trailing backslash; the command-word
# candidate itself is never a trigger, so heredoc or commit prose stays quiet. A trigger denies only when
# lost_push() says a push could still follow; the two split-value triggers use the looser armed == 2 gate.
# Precedence: command-line config (-cmdline-config-) keeps its own sentinel, and an earlier #292 reason keeps
# precedence over the new reason. The walk follows no option of env: env is a prefix word like any other, and
# its dash tokens are skipped as options of a prefix word.
# This program is single-quoted shell: it must never contain a literal apostrophe (use sq). quote_bearing: the
# token carries a quote or a backslash. quote_unbalanced: an odd count of double quotes, an odd count of single
# quotes, or a trailing backslash -- a quoted or escaped span the whitespace split cut in two.
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
# lost_push(toks, from, ntok, armed): one left-to-right pass over toks[from..ntok], true iff the rest of the
# segment could still be a push: a single token naming both git and push, or a token naming git followed only
# by option words (and the values of git global options) and then a token naming push. armed starts the walk
# as if a git word had just been seen; armed == 2 never disarms on a non-option word and never applies the
# option-value skip, so any later token naming push counts (the fragments a split quoted value leaves behind
# may themselves look like an option). Never consulted for a segment that cannot be a push. It is not
# monotone in its start (a scan from an earlier start can miss a push a later one finds), hence the separate
# per-segment memos m0, mi, m1 and m2 in emit_segment().
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
# emit_lost: the segment lost the tokenizer and could still be a push, so fail closed. Command-line git
# config keeps its own sentinel, and an earlier #292 reason (unres) keeps precedence over the fixed new
# reason; the reason is never input text.
function emit_lost(reason, unres, cc) {
  if (cc) print "-cmdline-config-"
  else print "PUSH\t\t" (unres != "" ? unres : reason) "\t"
}
# ip_kind (#537): how the walk reads a dash or plus token after an interpreter prefix word. "v", a value option
# (a member of INTERP_VALUE_OPTS, or letters of which exactly one is o or O and it is the last: -o, +O, -eo),
# takes the NEXT word as its value. "f", a flag (letters with no o or O: -e, -c, -lc, +e). "u", anything else
# (two value letters, a value letter that is not last, an unlisted long option, a non-letter), which the
# walk cannot classify.
function ip_kind(t,    u, c) {
  if (t in ipv_set) return "v"
  if (t !~ /^[-+][A-Za-z]+$/) return "u"
  u = t
  c = gsub(/[oO]/, "", u)
  if (c == 0) return "f"
  if (c == 1 && substr(t, length(t)) ~ /[oO]/) return "v"
  return "u"
}
# ip_value_ok (#537): TRUE iff w, the word after a value option of an interpreter, may be skipped with it: a
# plain word the old walk, which took it for the command word, could not have denied on. Not empty, not
# option-led, no quote, backslash or dollar sign, not an assignment, not a prefix word, git, or a
# directory-change or export word.
function ip_value_ok(w,    h, n) {
  if (w == "") return 0
  h = substr(w, 1, 1)
  if (h == "-" || h == "+") return 0
  if (quote_bearing(w) || index(w, "$") > 0) return 0
  if (match(w, /^[A-Za-z_][A-Za-z0-9_]*=/) == 1) return 0
  n = tolower(normalize(w))
  if (n == "" || (n in prefix_set) || n == "git" || (n in dir_set) || (n in export_set)) return 0
  return 1
}
# emit_segment: walk the tokens of one segment to its command word, then print what the driver loop needs: a
# PUSH line for a push, an ALIAS line for another git subcommand (#448), a fixed sentinel, or nothing. Per
# token, in order: an assignment (#292: a GIT_REPO_ENV_VARS name sets unres; #439: a GIT_CONFIG_* name sets
# cmdcfg; #448: a relocation name sets reloc; #449: an odd quote count or trailing backslash is a trigger); a
# token whose normalised, case-folded form is empty (skipped); then the #518 value-context trigger and the
# #537 interpreter-option arm, each described at its code; a PREFIX_WORDS member (skipped, sets saw_prefix); a
# dash token after a prefix word (skipped); otherwise the command word. After the walk: the cross-segment
# detection (#433, #439). For git the tokens after the command word are walked again in the option slot (#292: a
# GIT_REPO_OPTS option, an attached -C<path> or a second -C sets unres; #439: -c and --config-env set cmdcfg;
# #449 as described there; -C and its value are consumed), then the subcommand is taken. A non-push
# subcommand is an alias candidate (#448); a push prints its PUSH line, the remaining tokens passed through
# dest_word() (#517).
# An awk error anywhere in this program kills it as a whole: the scan then exits non-zero and the hook denies
# with the fixed scan-failure reason (#559), whatever the scan had printed so far.
# BWK awk allows at most 50 for arguments passed plus parameters declared; keep emit_segment() within it.
function emit_segment(seg,    ntok, toks, idx, tok, norm, saw_prefix, cmdword, j, subcmd, rest, sep, cpath, ccount, unres, aname, in_vp, in_ip, ipw, ipk, mi, m0, m1, m2, s0, reloc, aliasish, at, ro, k, xname, cmdcfg, co, cp, cfgname, cpath_big) {
  ntok = split(seg, toks, /[ \t]+/)
  idx = 1
  saw_prefix = 0
  cmdword = ""
  unres = ""
  cmdcfg = 0
  in_vp = 0
  in_ip = 0
  # #449: per-segment memos of the lost_push() scans (-1 = not yet scanned)
  m0 = -1
  mi = -1
  m1 = -1
  m2 = -1
  reloc = 0
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
      # #449: an assignment whose quoted or escaped value the whitespace split cut in two
      # (X="a b", X=a\ b) leaves the rest of the value as a bogus command word -- fail closed when
      # the remaining tokens could still be a push.
      if (quote_unbalanced(tok)) {
        if (m0 < 0) m0 = lost_push(toks, idx + 1, ntok, 0)
        if (m0) { emit_lost("quote or escape in the command prefix", unres, cmdcfg); return }
      }
      idx++
      continue
    }
    norm = tolower(normalize(tok))
    if (norm == "") { idx++; continue }
    # #518 fail-closed: a dash option of a PREFIX_VALUE_WORDS member (exec, nice, stdbuf, sudo, time, xargs) may
    # take the NEXT word as its value (nice -n 5 git push origin main), and the walk skips the option but not the
    # value, so the value became the command word and the push went unseen. This hook models no prefix command
    # option grammar. While the most recent prefix word is in PREFIX_VALUE_WORDS, a dash token followed by a
    # word that does not start with one is a trigger: the rest of the segment AFTER that word (never the word
    # itself, so `sudo -E git push origin feature/x` is still judged on git) is read with the memoised
    # lost_push() of the segment, and a hit denies with the fixed reason option value in the command prefix. The
    # precedence is that of the #449 triggers: an earlier #292 reason and -cmdline-config- keep their own
    # deny. A later prefix word outside the vocabulary closes the context. Cost: O(1) checks per dash token,
    # and at most one memoised lost_push() per segment, shared with the parity trigger above.
    if (in_vp && substr(tok, 1, 1) == "-" && idx < ntok && toks[idx + 1] != "" && substr(toks[idx + 1], 1, 1) != "-") {
      if (m0 < 0) m0 = lost_push(toks, idx + 2, ntok, 0)
      if (m0) { emit_lost("option value in the command prefix", unres, cmdcfg); return }
    }
    # #537 fail-closed: an option of an interpreter prefix word (PREFIX_INTERP_WORDS). Interpreters stay out of
    # PREFIX_VALUE_WORDS (the value of bash -c IS the command string, so reading past it would deny `bash -e -o
    # pipefail -c "git push origin feature/x"` in every session); their options are classified by ip_kind()
    # instead. While the most recent prefix word is an interpreter, a token that starts with a dash or plus, is
    # longer than one character, is not --, holds no slash and is not read as a prefix word is a value option
    # (skipped together with the NEXT word when ip_value_ok() accepts that word), a flag (skipped alone), or
    # unclassified. For an unclassified option followed by a word that is no option, a push could still follow:
    # the rest of the segment AFTER that word (never the word itself, which stays the command word) is read
    # through its own memo, mi, never m0 (a scan from an earlier start can miss a push a later one finds, e.g.
    # -u git --git-dir push, so writing m0 here would turn the deny of a later #518 trigger into an allow); a
    # hit denies with the #518 reason. Otherwise the option is skipped alone. A token holding a dollar sign is
    # never skipped by this rule: it falls through to the prefix-word and command-word steps below. A word is
    # skipped only when the old walk, which took it for the command word, could not have denied on it, so no
    # deny turns into an allow. Cost: per token after an interpreter word one regex match, one gsub and a
    # constant number of set lookups, O(token); a value option consumes its value word with no rescan; at most
    # one more memoised lost_push() per segment.
    if (in_ip && length(tok) > 1 && tok != "--" && (substr(tok, 1, 1) == "-" || substr(tok, 1, 1) == "+") && index(tok, "/") == 0 && !(norm in prefix_set)) {
      ipw = (idx < ntok) ? toks[idx + 1] : ""
      if (index(tok, "$") == 0) {
        ipk = ip_kind(tok)
        if (ipk == "v" && ip_value_ok(ipw)) { idx += 2; continue }
        if (ipk == "f") { idx++; continue }
      }
      if (ipw != "" && substr(ipw, 1, 1) != "-") {
        if (mi < 0) mi = lost_push(toks, idx + 2, ntok, 0)
        if (mi > 0) { emit_lost("option value in the command prefix", unres, cmdcfg); return }
      }
      if (index(tok, "$") == 0) { idx++; continue }
    }
    if (norm in prefix_set) in_ip = (norm in ip_set)
    if (norm in prefix_set) { in_vp = (norm in vprefix_set) }
    if (norm in prefix_set) { saw_prefix = 1; idx++; continue }
    if (saw_prefix && substr(tok, 1, 1) == "-") { idx++; continue }
    cmdword = norm
    idx++
    break
  }
  # #433 cross-segment (xseg) detection, order-independent: the first segment of any kind (a push segment or
  # otherwise) whose resolved command word is a PUSH_DIR_CHANGE_WORDS member, or an export-family segment
  # naming a GIT_REPO_ENV_VARS member, or a bare assignment of one, sets xseg for the WHOLE command. This push
  # segment own resolution never reads xseg; only the driver post-loop fallback does, so an in-segment reason
  # on the push segment itself always keeps precedence.
  if (xseg == "") {
    if (cmdword in dir_set) xseg = "cd/pushd/popd earlier in this command"
    else if (cmdword in export_set) { for (k = idx; k <= ntok; k++) { xname = strip_quotes(toks[k]); sub(/=.*/, "", xname); if (xname in envvar_set) { xseg = xname " set earlier in this command"; break } } }
    else if (cmdword == "" && unres != "") xseg = substr(unres, 1, length(unres) - 1) " set earlier in this command"
  }
  # #433 + #439: the same cross-segment rule for the #439 command-line-config environment names exported, or
  # bare-assigned, in another segment. The reason is fixed text: a prefix-matched name is input-derived.
  if (xseg == "") {
    if (cmdword in export_set) { for (k = idx; k <= ntok; k++) { cfgname = strip_quotes(toks[k]); sub(/=.*/, "", cfgname); if (is_cmdcfg_name(cfgname)) { xseg = "GIT_CONFIG_* set earlier in this command"; break } } }
    else if (cmdword == "" && cmdcfg) xseg = "GIT_CONFIG_* set earlier in this command"
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
    # #439: a -c or --config-env option before the subcommand. A detached one is an exact ccopt_set member; an
    # attached -c<k=v> is caught by the middle substr() arm; an attached --config-env=<k=V> by the final
    # index() loop. awk comparison is case-sensitive, so -C (the repo-redirect option) never matches. This only
    # sets a flag; gopt_set below still consumes the option together with its value token.
    if (!cmdcfg) {
      if (tok in ccopt_set) cmdcfg = 1
      else if (substr(tok, 1, 2) == "-c") cmdcfg = 1
      else for (co = 1; co <= ncco; co++) if (index(tok, ccoarr[co] "=") == 1) { cmdcfg = 1; break }
    }
    # #449: a quoted or escaped option in the option slot ("-c", \-c, "--git-dir=...", -"c") is applied by git
    # but never read here, so it would normalise into the subcommand slot or be skipped unread: fail closed
    # when a push can still follow. The same for an attached option whose quoted value the whitespace split cut
    # (--git-dir="a b", -c"k=a b") and for the detached VALUE of a global option other than -C that is itself
    # unbalanced (-c "k=a b"): the leftover fragments would become the subcommand and drop the segment.
    if (quote_unbalanced(tok) && substr(strip_quotes(tok), 1, 1) == "-") {
      if (m2 < 0) m2 = lost_push(toks, j + 1, ntok, 2)
      if (m2) { emit_lost("quoted or escaped git option", unres, cmdcfg); return }
    }
    s0 = strip_quotes(tok)
    if ((s0 in gopt_set) && s0 != "-C" && quote_unbalanced(toks[j + 1])) {
      if (m2 < 0) m2 = lost_push(toks, j + 2, ntok, 2)
      if (m2) { emit_lost("quoted or escaped git option", unres, cmdcfg); return }
    }
    if (quote_bearing(tok) && substr(strip_quotes(tok), 1, 1) == "-") {
      if (m1 < 0) m1 = lost_push(toks, j, ntok, 1)
      if (m1) { emit_lost("quoted or escaped git option", unres, cmdcfg); return }
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
    if (substr(tok, 1, 1) == "-") { j++; continue }
    if (normalize(tok) == "") { j++; continue }
    subcmd = normalize(tok)
    j++
    break
  }
  # #448: every git segment whose subcommand is not push is an alias candidate; git never lets an alias
  # shadow a built-in, so the config lookup in the driver loop alone decides. An inline relocation assignment,
  # or command-line config naming an alias or include, is config this hook cannot read: it denies here with a
  # fixed sentinel.
  if (subcmd != "" && subcmd != "push") {
    aliasish = 0
    if (cmdcfg) for (k = 1; k <= j - 2; k++) { at = tolower(strip_quotes(toks[k])); if (index(at, "alias") > 0 || index(at, "include") > 0) { aliasish = 1; break } }
    if (reloc || aliasish) print "-alias-cmdline-config-"
    else print "ALIAS\t" (ccount == 1 ? cpath : "") "\t" tolower(subcmd)
  }
  # #572 fail-closed: a command substitution that cuts the git option slot. The segmenter cuts a record at
  # $(, ${ and a backtick, so git -C "$(pwd)" push origin main arrives as git -C "$ with the push in a later
  # segment, unread. A git segment with no subcommand (none, or the dollar a cut left in its place) ends where
  # a substitution opened when it ends in a dollar, or, in a record holding a backtick, in a space or a double
  # quote; a code span that is only git ends in neither and stays quiet. If the record names push (rec_push,
  # set once per record, so this is O(1) per segment) the segment fails closed with a fixed reason. So a $( or
  # ${ substitution anywhere in the option slot denies, and so does a backtick that starts a word there or
  # follows a double quote, whatever the destination of the push; so does a non-push git command with such a
  # slot on a line that names push. A backtick glued to other text (git -C ~/`pwd` push) leaves no such end
  # and stays quiet.
  if (rec_push && (subcmd == "" || subcmd == "$") && (substr(toks[ntok], length(toks[ntok])) == "$" || (has_bt && (toks[ntok] == "" || substr(toks[ntok], length(toks[ntok])) == "\"")))) { emit_lost("command substitution in the git options", unres, cmdcfg); return }
  if (subcmd != "push") return
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
  rec_push = (index($0, "push") > 0)
  nseg = split(line, segs, /\n/)
  for (s = 1; s <= nseg; s++) emit_segment(segs[s])
}
END { if (xseg != "") print "-xseg-\t" xseg }
' 2>/dev/null)"
scan_rc=$?
# #559: a non-zero status means the scan stopped early (an awk abort, a resource limit, a killed process, or
# no runnable awk) and judged only part of the command, so deny with one fixed reason before anything reads
# scan_out. awk's own error text is dropped (2>/dev/null above) so the deny stays one stderr line.
if [ "$scan_rc" -ne 0 ]; then
  printf '%s denies this command: its command scan did not finish (blocked: command scan failed) — run the command from a terminal; see README.md'"'"'s Safety model\n' \
    "$PUSH_DENY_STEM" >&2
  exit 2
fi

# #435: nothing to judge anywhere in the scan -- no PUSH line, no ALIAS candidate line, and no command-line-config
# sentinel (the -alias-cmdline-config- sentinel contains it) -- so the driver loop would find nothing to deny
# and exit 0 anyway; this gets there before ever sampling the deadline, so a command with no push segment and
# no git alias candidate is never denied by the deadline merely for being large. The -xseg- marker line alone
# does not count: the xseg fallback denies only when a push segment was also seen.
case "$scan_out" in
  *PUSH*|*ALIAS*|*-cmdline-config-*) ;;
  *) exit 0 ;;
esac
check_deadline

# --- repo resolution (reads only, never executes) ---------------------------------------------
# cfg_trim VALUE -- strips leading and trailing [:space:], setting the plain global $cfg_trim_out (the same
# "set a plain global, caller reads it after the call returns" idiom evaluate_segment() uses for __deny_dest).
# NEVER called inside "$(...)": a config file can carry thousands of lines, each needing up to three trim
# calls, and every "$(...)" forks a full bash process image, a per-call cost that made an include chain a
# timing DoS in its own right. Pure parameter expansion only (bash 3.2-safe: no ${var,,}, no declare -A, no
# tr/sed, no extglob). A caller must read $cfg_trim_out on the very next statement, before any other cfg_trim
# call or recursive cfg_parse_file call can overwrite it. This form is NOT uniformly fast for every input shape:
# matching the bracket-class pattern against a long run of trailing (or leading) whitespace can cost far more
# than the input's own length in bash's glob engine. CFG_INCLUDE_MAX_LINE_CHARS keeps an included (depth >= 1)
# line like that from ever reaching it, and CFG_TOPLEVEL_MAX_LINE_CHARS does the same for a depth-0 line
# (checked in cfg_parse_file() before this function is called). Used only by the config parser below; defined
# here because it must exist before the parsing loop runs.
cfg_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  cfg_trim_out="$s"
}

resolve_cwd="${cwd:-$PWD}"
[ -n "$resolve_cwd" ] || resolve_cwd="."

# cfg_tab is the tab byte the cfg_push_lines records use as a field separator inside resolve_repo(); at file
# scope (computed once, not per call) since resolve_repo() runs once for the session and once per resolved -C.
cfg_tab="$(printf '\t')"
# nl is the newline byte cfg_seen uses as a delimiter around each already-parsed path, so a bracketed substring
# match (`*"$nl$path$nl"*`) can never be fooled by one path being a substring of another. File scope,
# like cfg_tab, since cfg_parse_file() is called both from resolve_repo() and, recursively, from itself.
nl=$'\n'
# The carriage-return literal the config parser strips from a config line. (The command-string strip is not
# bash: it lives in the awk tokenizer.)
cfg_cr=$'\r'

# cfg_parse_file PATH LABEL DEPTH (#304/#305) -- parses one config file inline, recursively following
# include/includeIf directives found in its own content (conditions ignored: the union stance of every
# multi-file read here). PATH is a candidate (a system, global or repo-local candidate from resolve_repo(), or
# an include target this function resolved); LABEL is the free-text source label used in the deny message (a
# child include gets "LABEL (via include)", added exactly once however deep); DEPTH is PATH's include depth (0
# for a candidate straight from resolve_repo()'s list). Guards, in order: PATH non-empty, a regular file
# (`[ -f ]`; a FIFO or device is never opened any other way), and not already in $cfg_seen, a newline-delimited
# membership string. $cfg_seen is ANCESTOR-ONLY, not a whole-call history: this function saves it to a local
# on entry, appends PATH, and restores the saved value right before it returns, so PATH is "seen" only while
# its own call frame (and every descendant include) is on the stack. That stops a self- or mutual-include
# cycle while still letting two SIBLING includes of one path, or a later top-level candidate naming a path an
# earlier include already pulled in, each be read independently in git's own order (a whole-call cfg_seen
# under-blocked: a global candidate that included the repo-local config file would mark it seen, and the
# repo-local candidate's mandatory last re-read would be skipped). The price is fan-out, bounded at depth >= 1
# by four mechanisms checked in the read loop: $cfg_inc_budget (follow count), $cfg_inc_line_budget (lines)
# and $cfg_inc_char_budget (characters) are GLOBAL per-resolve_repo()-call counters, never saved or restored
# per frame, and a per-line length cap skips comment-strip and trim for one over-length line (`continue`, not
# `break`; the budgets are still spent). The line and character budgets `break` out of the current read loop,
# never `return`, so the cfg_seen restore still runs. The include arm also requires all three budgets to be
# positive before it follows, so once either runs out no further include is even opened; the one line this
# cannot prevent is whichever single line, in whichever open file, drives a budget below zero (a read takes
# a whole line). None of the four applies to a depth-0 candidate, which is read in full, so none can mask a
# route within one resolution (the hook resolves once for the session and once more per resolved -C segment,
# and check_deadline() samples every line across all of them); a depth-0 line's own LENGTH is capped
# separately (CFG_TOPLEVEL_MAX_LINE_CHARS). Every per-file variable is local, so a nested call never clobbers
# the includer's section state. The file is read only through `done < "$1"`, a `[ -f ]`-guarded builtin
# redirect, never cat, dirname, cd or any external command, and an include path is resolved with parameter
# expansion only. It appends to the plain globals cfg_push_lines, cfg_alias_lines, cfg_push_defaults and
# cfg_branch_merge, and reads current_branch.
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
    check_deadline
    # Three depth->=1-only budgets, checked here, in this order, before comment-strip or trim ever
    # runs -- CFG_INCLUDE_MAX_LINES and CFG_INCLUDE_MAX_CHARS bound the total lines read and characters charged
    # across every included file for this whole resolve_repo() call (shared, never reset per file), and
    # CFG_INCLUDE_MAX_LINE_CHARS caps one line's length, checked with the cheap ${#cfgline}, never by running
    # comment-strip or trim first (trim can cost real seconds on a very long line). None of the three applies
    # to a depth-0 candidate, which is read in full; its line LENGTH is capped separately just below.
    if [ "$depth" -ge 1 ]; then
      [ "$cfg_inc_line_budget" -gt 0 ] || break
      cfg_inc_line_budget=$((cfg_inc_line_budget - 1))
      cfg_inc_char_budget=$((cfg_inc_char_budget - ${#cfgline} - 1))
      [ "$cfg_inc_char_budget" -ge 0 ] || break
      [ "${#cfgline}" -le "$CFG_INCLUDE_MAX_LINE_CHARS" ] || continue
    fi
    # #435: the depth-0 counterpart to the depth >= 1 length check above. A top-level candidate is read in full,
    # but an over-cap line fails closed instead of reaching cfg_trim(), whose pattern matching is not uniformly
    # fast for a long line or whitespace run.
    [ "$depth" -ge 1 ] || [ "${#cfgline}" -le "$CFG_TOPLEVEL_MAX_LINE_CHARS" ] || deny_too_large configline
    cfgline="${cfgline//$cfg_cr/}"
    # Strip a trailing comment: whichever of # or ; appears first, with no quote-tracking. Git ref names MAY
    # legitimately contain # or ; (refs/heads/feat#123), so this is a known parsing gap: a destination value is
    # truncated at the marker (an over-block), and so is an include value (which then fails open). A SECTION
    # HEADER line is cut the same way, so a quoted remote, branch or includeIf name holding # or ; is not
    # recognised (an alias subsection still is: its arm reads no name).
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
    # A section header must sit on its own line: it only sets the section above, and text after its
    # closing bracket is never read as a key.
    case "$cfgline" in
      \[*) continue ;;
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
            # The source label goes FIRST, with the configured value as the record's unbounded TAIL (mirroring
            # cfg_push_defaults' shape below), never a bounded middle field: a `push =` value holding a literal
            # TAB would otherwise truncate there and leak its remainder into config_deny()'s source-label field.
            # cfg_subsection (the remote name) is read from a section header, never from a value.
            cfg_push_lines="${cfg_push_lines}${label}${cfg_tab}${cfg_subsection}${cfg_tab}${cfg_val}"$'\n'
            ;;
        esac
        ;;
      alias)
        # #448: label first, then key, then the value as the unbounded tail (the same reasoning as
        # cfg_push_lines above): a value holding a TAB byte cannot truncate into another field.
        cfg_alias_lines="${cfg_alias_lines}${label}${cfg_tab}${cfg_key}${cfg_tab}${cfg_val}"$'\n'
        ;;
      aliassub)
        # #448: a subsection alias, command = <expansion>, recorded under the name-independent key "*".
        case "$cfg_key" in
          [Cc][Oo][Mm][Mm][Aa][Nn][Dd])
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

# resolve_repo START_DIR MAX_DEPTH (#269) -- walks upward from START_DIR, at most MAX_DEPTH parent directories,
# looking for START_DIR/.git; resets gitdir, default_branch, current_branch and the cfg_* variables on every
# call so a second call (the -C route) never leaks a prior call's state. Sets those plain (non-local) globals
# for the caller to read afterward. Called once for the session checkout (MAX_DEPTH 64) and, per push or
# alias-candidate segment whose -C value passes is_c_target_path(), once more with MAX_DEPTH 1
# (apply_c_target): the named directory itself, never walking upward the way git does. The MAX_DEPTH guard
# makes the untrusted -C path on that call unreachable by dirname's argv, and so by any process's argv. EVERY
# call also unions in the global and system config candidates and every include target found inside them (see
# "Repo resolution" in the header), identically for the session and a -C checkout.
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
  # Config-derived routes, always initialized (even when $gitdir never resolves) so config_deny() can reference
  # them under `set -u`. cfg_push_defaults is a newline-separated LIST (one record per parsed line, across every
  # candidate file). cfg_seen is reset to a single newline on every call so the seen-list never leaks a prior
  # call's state; cfg_inc_budget, cfg_inc_line_budget and cfg_inc_char_budget are reset to their
  # CFG_INCLUDE_MAX_* values: single counters, GLOBAL for the whole call and never saved or restored per
  # ancestor frame (see cfg_parse_file()).
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

    # Config CANDIDATES, system first, then global, this checkout's own repo-local config LAST -- never derived
    # from the untrusted command string, only from the environment ($GIT_CONFIG_SYSTEM, $GIT_CONFIG_NOSYSTEM,
    # $TBF_PUSH_GUARD_SYSCONFIG_ROOT, $GIT_CONFIG_GLOBAL, $XDG_CONFIG_HOME, $HOME; every reference
    # ${VAR:-}-guarded under set -u), this file's fixed system-path vocabulary and $common. Repo-local is read
    # last so a last-wins scalar (cfg_branch_merge) resolves to the repo's own value; cfg_push_lines and
    # cfg_push_defaults ACCUMULATE across every candidate and include, so this order only decides which
    # route's label is named first. $GIT_CONFIG_GLOBAL is UNIONED with (never a replacement for) the other two
    # global paths, and $GIT_CONFIG_SYSTEM with the static system paths, though real git reads only the env var
    # when it is set: a deliberate over-block. $nosys parses $GIT_CONFIG_NOSYSTEM for a canonical true value
    # ONLY (1, true, yes, on, case-insensitively); any other value, such as 2, leaves the system candidates in
    # force. PUSH_APPLE_CLT_CONFIG sits INSIDE the same $nosys guard as the three PUSH_SYSTEM_CONFIG_PATHS
    # entries. A command-line -c or --config-env option, a GIT_CONFIG_* assignment and an inline HOME or
    # XDG_CONFIG_HOME relocation deny the push outright instead of being read as config (#439, #448).
    xdg_cfg=""
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
      xdg_cfg="$XDG_CONFIG_HOME/git/config"
    elif [ -n "${HOME:-}" ]; then
      xdg_cfg="$HOME/.config/git/config"
    fi
    home_cfg=""
    [ -n "${HOME:-}" ] && home_cfg="$HOME/.gitconfig"

    # $sysroot is a TEST-ONLY prefix (empty in every real run) applied solely to the static system paths below,
    # never to $GIT_CONFIG_SYSTEM, any HOME or XDG path, or an include target; dev/hook-tests.sh's
    # run_push_guard sets it so the suite never touches the host's real system config files.
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

    # Every candidate travels as a "<label>${cfg_tab}<path>" record, split on the FIRST cfg_tab, and both
    # fields go to cfg_parse_file(), which does the per-file, include-following parse.
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
# session_root: the directory $dir (a plain global) holds after THIS session-scoped call -- the .git-bearing
# directory where the upward walk broke, or START_DIR unchanged when it never found one. Captured here, before
# apply_c_target() calls resolve_repo() again, so a later comparison always reflects the SESSION. Empty when
# the session itself never resolved a gitdir.
session_root=""
[ -n "$gitdir" ] && session_root="$dir"
session_default_branch="$default_branch"
session_current_branch="$current_branch"
session_cfg_push_lines="$cfg_push_lines"
session_cfg_alias_lines="$cfg_alias_lines"
session_cfg_push_defaults="$cfg_push_defaults"
session_cfg_branch_merge="$cfg_branch_merge"

# is_session_checkout_path PATH (#292) -- true iff PATH is LEXICALLY the session checkout: "." (or "./"),
# $resolve_cwd (the stdin cwd, or $PWD when absent), or $session_root, each with or without one trailing
# slash. Builtins only: no filesystem access, no process. The driver loop uses it to decide whether an
# otherwise-unresolvable -C value still means "this segment IS the session" rather than a deny. The "/" case
# is guarded before stripping a trailing slash so the root path is never turned into an empty string.
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

# apply_session_repo (#269) -- (re)applies the session checkout's resolved facts to default_branch,
# current_branch and cfg_*, and rebuilds deny_set and default_display. Called once per push or
# alias-candidate segment before that segment's -C value (if any) is considered, so a segment with no -C, or
# one whose -C value satisfies PATH_ERE but resolves no gitdir, is judged by these session facts alone.
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

# apply_c_target CPATH (#269) -- CPATH is the tokenizer's emitted -C value for the segment about to be
# evaluated (empty unless the segment carried exactly one detached `-C <path>`). No-op when CPATH is empty or
# fails is_c_target_path(): the segment keeps the session facts. Otherwise it resolves CPATH at depth 1 only
# and, only if a gitdir resolved there, applies current_branch and the cfg_* variables from the resolved
# checkout (each assignment its own statement, on purpose, so a regression in just one is isolated) and
# rebuilds deny_set as the union of the fallback, the SESSION's default branch and the RESOLVED checkout's
# default branch, never a replacement of the session's (a checkout lacking its own refs/remotes/origin/HEAD
# must not silently lose the guard). If no gitdir resolved, the segment's facts stay as apply_session_repo()
# set them.
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

# config_deny SCOPE_REMOTE -- evaluates the config-derived push routes (remote.<name>.push, push.default)
# captured by the repo-resolution parse from every candidate file actually read. On a deny it sets
# $__deny_dest, $__deny_kind ("config" or "configall"), $__deny_via and $__deny_src (the source label: one of
# ".git/config", "your global git config" or "your system git config", each optionally suffixed " (via
# include)") as plain, non-local assignments, the way evaluate_segment's other checks do. SCOPE_REMOTE is the
# single non-option token at n == 1, or empty at n == 0 (a bare push): at n == 0 every remote.<name>.push
# record is considered regardless of remote (deliberately over-broad, the union default), while at n == 1 only
# records whose remote name equals SCOPE_REMOTE exactly. A configured destination containing "*" (after the
# refspec_dest() resolution every other route uses) denies unconditionally, like PUSH_ALL_REFS_OPTS. The
# push.default route is evaluated alongside it (this hook does not model git's precedence): "upstream" and
# "tracking" resolve via the current branch's recorded merge ref; "matching" denies unconditionally;
# "current", "simple", "nothing", absent or unrecognised add no route here. cfg_push_defaults is a LIST (one
# record per parsed line, each prefixed with its source label) and EVERY value is evaluated, so a benign
# value in one file never masks a denying value in another; the first denying record wins.
config_deny() {
  local scope="$1" rec sub refspec src rest dest
  local pdrec pdsrc pdval
  if [ -n "$cfg_push_lines" ]; then
    while IFS= read -r rec; do
      check_deadline
      [ -n "$rec" ] || continue
      # src is the BOUNDED first field; refspec is the UNBOUNDED tail, so a configured value holding a literal
      # TAB stays intact instead of truncating and leaking its remainder into $src.
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

# alias_deny NAMES (#448) -- NAMES is the lowercased subcommand from one ALIAS tokenizer line. Looks it up as
# `alias.<name>` in the alias records the repo-resolution parse captured (every candidate file read, the
# resolved -C checkout included) and denies when
# the expansion COULD push. One awk pass over the records, fed by a here-string -- never a pipe, never argv,
# never the shell: names and values are only compared, never executed or echoed. The first word of the value,
# with quotes and backslashes stripped and lowercased (git-config whitespace escapes backslash-t, -n, -b read as
# word breaks), decides: `push`, an empty word, a `!` shell alias, an option (a leading dash hides the
# subcommand behind it), or the name of ANOTHER defined alias (a chain this hook does not follow) all deny,
# and so does a value ending in a backslash (a continuation the line parser does not join). The subsection
# alias forms ([alias "<name>"] with any run of blanks before the quote, or [alias.<name>], each with
# `command = <expansion>`) are NAME-INDEPENDENT: the name is never read, and a readable subsection alias whose
# command would deny denies EVERY alias candidate resolved to that checkout. Names fold to lower case on both
# sides (git matches case-sensitively, so folding only over-blocks). Git never lets an alias shadow a
# built-in, so the lookup alone decides and no built-in list is needed; the price is that an alias NAMED like a
# built-in and expanding to push denies that built-in here although git ignores it. On a deny it sets
# __deny_src to a fixed source label and __deny_dest and __deny_kind to "alias".
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

# evaluate_segment REST -- REST is one push segment's remaining tokens (space-joined, already quote- and
# backslash-stripped by the tokenizer). Sets $__deny_dest (non-empty on deny) and $__deny_kind. It builds its
# token array from the REST string with `for t in $rest`, never from "$@" or an array argument: under bash 3.2's
# `set -u`, expanding a zero-length array with "${arr[@]}" raises "unbound variable" for a bare `git push`.
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
    # Config-derived routes are consulted ONLY here (never for a segment with an explicit refspec, n >= 2,
    # below) and only when nothing above has already denied.
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
# #433: xseg_reason and saw_push back the post-loop cross-segment fallback below, which runs after the loop
# found no other deny.
xseg_reason=""
saw_push=0
while IFS= read -r line; do
  check_deadline
  case "$line" in
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
    "-xseg-$TAB"*) xseg_reason="${line#-xseg-"$TAB"}"; continue ;;
    "ALIAS$TAB"*)
      # #448: an alias candidate (a git segment whose subcommand is not push). The alias records of the
      # session checkout (or its resolved -C target) decide. Never sets saw_push: the push-gated
      # fallbacks below stay push-only.
      al_body="${line#ALIAS$TAB}"
      al_cpath="${al_body%%"$TAB"*}"
      al_names="${al_body#*"$TAB"}"
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
  # #292: fail closed on an UNRESOLVABLE push target before apply_c_target and evaluate_segment run for this
  # segment (the first-offender rule applies here too). seg_unres already carries a reason when the tokenizer
  # recognised an evasion (an attached -C<path>, 2+ -C tokens, a GIT_REPO_OPTS option, a GIT_REPO_ENV_VARS
  # assignment). The remaining one, a detached -C <path> that fails is_c_target_path() and is not lexically
  # the session checkout (is_session_checkout_path()), is caught here, since it needs $resolve_cwd and
  # $session_root, neither available inside the awk tokenizer.
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

# #433: cross-segment ("xseg") fallback. It runs only after every push segment above had its chance to deny for
# its OWN reason (an in-segment reason keeps precedence: guarded by `[ -z "$deny_dest" ]`), and only when this
# command contains a push segment at all (`[ "$saw_push" = 1 ]`: a bare cd or export with no push stays a
# no-opinion, and a scan can pass the early exit on an ALIAS candidate line alone). It reuses the
# "unresolved" verdict; xseg_reason is always a fixed phrase or "<NAME> set earlier in this command" for a
# GIT_REPO_ENV_VARS member NAME, so it echoes no input.
if [ -z "$deny_dest" ] && [ "$saw_push" = 1 ] && [ -n "$xseg_reason" ]; then
  deny_dest="$xseg_reason"
  deny_kind="unresolved"
fi

# #494 fail-closed: Codex shell workdir. Codex's shell tool takes its own `workdir` parameter, which is NOT part
# of the PreToolUse payload (ADR 0002 U9, confirmed live on Codex 0.156.1: the payload carries only
# tool_input.command and the session cwd), so a push run through it executes in a checkout the command-string
# analysis never sees. For a Codex-shaped payload (a non-empty turn_id; a Claude Code payload has none and
# never reaches this code) whose push would otherwise get no opinion, this hook reads the tail (at most
# PUSH_TRANSCRIPT_TAIL_BYTES) of the rollout file the payload's transcript_path names and scans EVERY model
# tool-call record in that window (a response_item of type custom_tool_call, function_call or
# local_shell_call), whether or not an *_output record answers it: a code-mode exec cell can yield its output
# and keep running, so its inner push can fire long after its output exists. The live evidence: Codex 0.156.1
# appends the call record to the rollout BEFORE PreToolUse fires for the inner command, and the payload
# carries no key that joins the hook call to its record, hence "every record", not "the newest". Each
# record's call text (code-mode JS input, arguments, or action, JSON-serialised when not a string) is
# scanned for EVERY occurrence of a PUSH_WORKDIR_KEYS name. The push is allowed only when every occurrence is
# `null` (never `undefined`: JS lets that identifier be shadowed) or a plain "..." or '...' string literal (no
# backslash, closed, then a comma or brace) that is LEXICALLY the session checkout (is_session_checkout_path(),
# the same test #292 applies to -C). Window edge: a line that does not parse as JSON but contains a workdir
# key counts as a non-literal workdir, and when the window's first line does not parse and is at least half
# of PUSH_TRANSCRIPT_TAIL_BYTES long (UTF-8 bytes) the hook denies outright, since a record cut that deep may
# have hidden its workdir. Otherwise it denies with one of five FIXED reasons: another directory, not a plain
# string literal, transcript missing or unreadable, a record exceeding the read window, or no tool call in
# the window (also the verdict for a jq failure or an empty pipeline output: nothing fails open past this
# point). It runs LAST, after every other verdict had its chance (an existing reason keeps precedence:
# `[ -z "$deny_dest" ]`), and only ever ADDS a deny. Containment: the transcript path is host-provided (never
# from the command string) and used only as a `[ -f ]` / `[ -r ]`-guarded redirect into `tail -c`; its content
# is partly model-written and so untrusted, parsed as DATA by jq and awk, compared by string equality only,
# never eval'd, executed, opened as a path or echoed.
if [ -z "$deny_dest" ] && [ "$saw_push" = 1 ]; then
  codex_turn="$(printf '%s' "$input" | jq -r '.turn_id? // empty' 2>/dev/null)"
  if [ -n "$codex_turn" ]; then
    check_deadline
    wd_reason=""
    wd_tp="$(printf '%s' "$input" | jq -r '.transcript_path? // empty' 2>/dev/null)"
    if [ -z "$wd_tp" ] || [ ! -f "$wd_tp" ] || [ ! -r "$wd_tp" ]; then
      wd_reason="Codex transcript missing or unreadable"
    else
      # jq stage: every model tool-call record in the window, completed or not, then every occurrence of a
      # workdir key in its call text, each printed as one `T<TAB><the text after the key>` line (newlines
      # flattened, 1024 chars). Window edge: a line that does not parse as JSON but contains a workdir key prints
      # BAD, and an unparseable FIRST line of at least half the window (UTF-8 bytes, summed from `explode`)
      # prints EDGE alone. No regex builtin (jq 1.5 without Oniguruma) and no `IN`; the first line is EDGE,
      # CALLS or NONE. awk stage: classifies each T line as no workdir (null: no output), a plain string
      # literal (`LIT<TAB><body>`), or anything else (`BAD`).
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
      printf '%s denies this git command (blocked: unreadable git config may define an alias): it runs under git config this hook does not read (git -c, --config-env, a GIT_CONFIG_* assignment, or an inline HOME=/XDG_CONFIG_HOME=), so it cannot rule out that the subcommand is an alias for a push — the harness never runs git this way; drop the extra config, or a human can run it from a terminal; see README.md'"'"'s Safety model\n' \
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
