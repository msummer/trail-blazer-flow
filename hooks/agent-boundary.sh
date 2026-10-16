#!/usr/bin/env bash
#
# agent-boundary.sh — plugin-shipped PreToolUse hook (#235) that mechanically enforces the implementer and
# verifier subagents' "no git, no gh" boundary, a ".claude write" boundary for both roles, and a "no deploy
# or cloud CLI" boundary for both roles (#551).
#
# Contract: read the PreToolUse hook JSON on stdin. Print nothing and exit 0 ("no opinion") unless the call
# is a Bash command from a recognised implementer or verifier agent_type that the role policy (bottom of
# this file) denies. The no-opinion cases: the main session (no agent_type), any other agent,
# permission_mode "plan", malformed stdin, another tool, an absent tool_input.command, a missing jq. A deny
# prints exactly one reason line to stderr and exits 2; stdout is always empty. A deny is one of:
#   - the implementer: a command word that resolves, case-insensitively, to git or gh;
#   - the verifier: gh, and git unless the resolved subcommand is on VERIFIER_GIT_READONLY (an unlisted
#     subcommand, a global option before the subcommand, a bare git, or a git behind a command prefix the scan
#     cannot follow all deny);
#   - both roles: a path under a .claude segment in a write position (a redirect target, an argument of a
#     CLAUDE_PATH_ARG_COMMANDS member, an in-place sed argument) or an interpreter or one-step writer
#     (CLAUDE_CMDLINE_WRITE_COMMANDS) sharing the call with a .claude mention anywhere;
#   - both roles (#551): a DEPLOY_COMMANDS entry as the command word, as the word a LAUNCH_WORDS launcher hands
#     on to, or in a segment tail the scan cannot follow; and, after npm, pnpm, yarn or bun, a script name
#     containing "deploy". package.json is never read. This deny is printed last, so any other deny decides first;
#   - both roles (#543): a command over AB_CMD_MAX_BYTES bytes, or over AB_CR_MAX_BYTES bytes when it carries a
#     carriage return, denied before the carriage-return strip and the scan with one line that names the limit;
#   - both roles: an awk scan that exits non-zero (an abort, a resource limit, a killed process, or no
#     runnable awk), denied with the fixed reason "command scan failed" (#559).
# Never executes anything (no git, no gh, nothing derived from the untrusted command), never evals, never
# writes a file. bash + jq + POSIX awk only: no python, no perl, no GNU-only flag; exercised under Apple
# bash 3.2 by the macOS CI job.
#
# No `if` gate in hooks/hooks.json: the `if` field is permission-rule syntax over tool input only and cannot
# see agent_type, so any `if` would silence the boundary for exactly the commands it exists to block.
#
# Live probe (#259; one Claude Code version, one platform, one install shape): the agent_type a plugin
# subagent sends is the namespaced trail-blazer-flow:<agent-name>. The bare spelling is matched too as
# insurance against a future de-namespacing, not as a hedge against an unknown live value. A Claude Code that
# sends neither leaves this hook inert, removing no permission it would otherwise have removed. This hook's
# exit 2 outranks hooks/git-c-guard.sh's allow for the same call (measured by replaying one call through both).
# The full record is "Live-probe record (#259)" in docs/reference/safety-model.md.
#
# Shared with hooks/push-guard.sh, which inlines a near-twin of this tokenizer for its own emitter. Each
# change to one of these must be applied in BOTH files:
#   - the segment breaking, normalize(), the prefix-word skip, the empty-token skip, the command-word case
#     fold, and the CR strip before any token is read (this hook strips in bash after the jq extraction;
#     push-guard strips first thing in its awk record block);
#   - the #505 assignment-parity trigger with quote_unbalanced(); the #518 value context with
#     PREFIX_VALUE_WORDS, except that this hook's PREFIX_VALUE_WORDS also holds the interpreter words bash dash
#     ksh sh zsh (#576), so it differs from the push-guard.sh copy; push-guard.sh keeps its own #537
#     interpreter-option rule.
# Pinned by the gate: PREFIX_WORDS is byte-identical to push-guard.sh (4.40(c)); the AGENT_TYPES_* lines
# match hooks/claude-dir-guard.sh (4.45) and agents/*.md (4.39). Every other copy is by convention, unpinned.
#
# This is a tripwire against an off-script subagent, not a sandbox. The spellings the scan does not see and
# the harmless commands it denies are listed in docs/reference/safety-model.md, under "Known gaps" and
# "Known over-blocks".
set -uo pipefail

# --- vocabulary --------------------------------------------------------------------------------
# One-line KEY="value" declarations, so dev/selfcheck.sh (4.39) can extract the two AGENT_TYPES_* lines
# mechanically; keep their exact shape.
AGENT_TYPES_IMPLEMENTER="implementer trail-blazer-flow:implementer"
AGENT_TYPES_VERIFIER="verifier trail-blazer-flow:verifier"
VERIFIER_GIT_READONLY="status diff log show rev-parse ls-files merge-base blame grep restore"
BLOCKED_COMMANDS="git gh"
# PREFIX_WORDS: words after which the next word is still in command position. Interpreter-indirection
# words (env, bash, xargs, ...); the shell reserved words that directly precede a command (if, then, do,
# while, !, ...); and eval, which runs its string argument as a command (the quote-blind scan already reads a
# quoted argument's words as command words). { } ( ) need no entry: they are segment breaks. for, select,
# case, function, in, fi, done, esac and [[ are left out because none runs the next word as a command. The
# signal-handler word and the zsh command modifiers do run one, and are left out too, a documented gap (see
# "Known gaps" in docs/reference/safety-model.md). Keywords share the dash-token skip after a prefix word,
# harmless because no keyword precedes a dash-led command.
# Pinned byte-identical to hooks/push-guard.sh by 4.40(c); the hooks/claude-dir-guard.sh copy is by convention.
PREFIX_WORDS="env command builtin exec sudo nohup time nice stdbuf xargs bash sh zsh ksh dash if then elif else do while until ! coproc eval"
# CLAUDE_PATH_ARG_COMMANDS (#340): command words whose first argument carrying a .claude segment is a
# one-step write (tee, cp, mv) or a move into the directory that lets a later write skip the redirect check
# (cd, pushd). See the arg_set walk in emit_segment().
CLAUDE_PATH_ARG_COMMANDS="tee cp mv cd pushd"
# CLAUDE_CMDLINE_WRITE_COMMANDS (#387): interpreter and one-step-writer basenames. When one is a
# segment's command word and the same command text names a .claude segment anywhere (any line, heredoc
# bodies included), the call is denied, even for a read: neither the interpreter's program text nor the
# writer's argument list is walked per token. Membership is tested after stripping a trailing [0-9.]+
# version suffix (python3.12 is python). tee, cp, mv, cd, pushd and sed keep their per-segment rules above.
CLAUDE_CMDLINE_WRITE_COMMANDS="python perl ruby node nodejs deno bun php lua awk gawk ed ex dd install ln touch truncate rsync tar patch curl wget"
# PREFIX_VALUE_WORDS (#518): the PREFIX_WORDS members whose dash options can take a SEPARATE value word
# (nice -n 5, sudo -u root, exec -a foo). After one of these, a dash token followed by a non-option word is
# a point where the walk cannot tell the value from the command word. Unlike the push-guard.sh copy, this one
# also holds the interpreter words bash dash ksh sh zsh (#576): the value of their -c IS the command string, so
# reading past it denies a -c string that names gh, git or a .claude path after its first word, an accepted
# over-block (docs/reference/safety-model.md, "Known over-blocks").
PREFIX_VALUE_WORDS="exec nice stdbuf sudo time xargs bash dash ksh sh zsh"
# DEPLOY_COMMANDS (#551): a comma-separated list of deploy and cloud CLIs, denied whatever their subcommand or
# flags (no carve-outs). An entry of two or three words is a phrase (prisma db push). LAUNCH_WORDS: the
# launchers and package managers whose next non-option word is the CLI they run, plus the sub-words skipped
# after one (exec x dlx run run-script). After npm, pnpm, yarn or bun that word is read the way a
# launcher's is, unless it is one of the package manager own subcommands (add, install, remove, ...; the
# regex in dep_check), which ends the read with no hit. So a script named for a listed CLI denies as that CLI (npm run
# vercel), a word containing "deploy" denies as a package script, and package.json is never opened, so any
# other script name is not judged. Every head word of DEPLOY_COMMANDS, and "deploy", also sits in fast path 2
# below.
DEPLOY_COMMANDS="vercel,netlify,fly,flyctl,wrangler,railway,heroku,aws,gcloud,az,doctl,terraform,pulumi,supabase,stripe,kubectl,helm,prisma migrate deploy,prisma db push,drizzle-kit push"
LAUNCH_WORDS="npx bunx pnpx uvx pipx npm pnpm yarn bun exec x dlx run run-script"
# AB_CMD_MAX_BYTES (#543): the longest Bash command, in BYTES, analysed at all. A longer one denies before the
# carriage-return strip and the scan: this hook has no deadline, so only a cap keeps the scan inside the hook
# timeout, and a timed-out hook gives no deny. Sized above every cooperative subagent command measured.
AB_CMD_MAX_BYTES="131072"
# AB_CR_MAX_BYTES (#535): the longest command, in BYTES, analysed when it carries a carriage return. The
# whole-text strip below grows faster than its input under bash 3.2, so a command with any CR gets this lower cap.
AB_CR_MAX_BYTES="2048"
DENY_STEM="trail-blazer-flow agent boundary:"

# ab_bytes STRING (#543) sets ab_n to STRING's length in BYTES (C locale, whatever locale the hook runs under);
# mirrors hooks/push-guard.sh's pg_bytes.
ab_bytes() { local LC_ALL=C; ab_n="${#1}"; }

# deny_over_cap LIMIT (#543) prints the one fixed over-cap line, naming LIMIT, and exits 2. Builtins only.
deny_over_cap() {
  printf '%s %s role: the command is longer than the %s-byte limit this hook analyses (blocked: command over the size cap) — split it into smaller Bash calls, or write file content with the Write tool; see agents/%s.md\n' \
    "$DENY_STEM" "$role" "$1" "$role" >&2
  exit 2
}

input="$(cat)"

# --- fast paths ----------------------------------------------------------------------------
# Both are performance shortcuts, semantics-preserving with the check they stand in for EXCEPT for a command
# word split by quote, backslash or carriage-return characters (see fast path 2): a documented limit of the
# same tripwire class as the scan quote-blind behaviour. A miss on either means no scan below could deny the
# call, so the call exits before the size cap too; that is harmless, because the cap only bounds the scan.
#
# Fast path 1: a main-session Bash call (no agent_type key in the JSON) can never resolve to a role, so skip
# jq. A raw substring hit only means the JSON has an agent_type key worth asking jq about (a subagent cwd can
# match by coincidence); the role check below still needs an exact match.
case "$input" in
  *agent_type*) : ;;
  *) exit 0 ;;
esac

# Fast path 2: this hook only denies a command word that resolves, case-insensitively, to git or gh, a write
# to a .claude path, an interpreter sharing the call with a .claude mention, or (#551) a deploy or cloud CLI.
# If none of git, gh or claude (each case-insensitively) appears anywhere in the raw stdin, no segment can do
# any of the first three. The second arm names every DEPLOY_COMMANDS head word (the CLI itself, a launcher
# that hands on to it, or a lost tail that holds it), plus "deploy" for the package-script name rule; a
# payload naming none of them cannot be a deploy deny either. With no arm matching, skip the jq/awk spawn.
# The namespaced agent_type (trail-blazer-flow:implementer) contains az, so with that spelling the arm always
# matches; the bare spelling a Codex subagent sends does not.
# The case fold is the POSIX-glob [Gg][Ii][Tt] idiom, not nocasematch or ,, / ^^, which bash 3.2 lacks. The
# ab-deploy-deny-direct and ab-deploy-deny-script cases pin the second arm: their payloads name none of git,
# gh or claude.
# Semantics-preserving except for a command word split by quote, backslash or carriage-return characters:
# normalize() strips quotes and backslashes before comparing and the CR strip removes a real CR byte, so
# g"i"t push normalises to git while the raw literal git never appears, and this path exits silently where
# the scan would have denied. A CR inside the raw JSON literal (escaped as backslash and r) or a .claude
# segment split by a quote or backslash inside it can miss the same way, and so can a deploy word split the
# same way. The second arm also lets a payload that names an arm word but none of git, gh or claude reach the
# scan, where a split git or gh spelling, or a split .claude write target (echo hi > .cl"aude"/x), can deny.
# How often this path short-circuits a subagent call is UNVERIFIED; a payload it lets through costs the
# jq/awk spawns and meets the size cap and the scan below.
case "$input" in
  *[Gg][Ii][Tt]*|*[Gg][Hh]*|*[Cc][Ll][Aa][Uu][Dd][Ee]*) : ;;
  *[Vv][Ee][Rr][Cc][Ee][Ll]*|*[Nn][Ee][Tt][Ll][Ii][Ff][Yy]*|*[Ff][Ll][Yy]*|*[Ww][Rr][Aa][Nn][Gg][Ll][Ee][Rr]*|*[Rr][Aa][Ii][Ll][Ww][Aa][Yy]*|\
  *[Hh][Ee][Rr][Oo][Kk][Uu]*|*[Aa][Ww][Ss]*|*[Gg][Cc][Ll][Oo][Uu][Dd]*|*[Aa][Zz]*|*[Dd][Oo][Cc][Tt][Ll]*|\
  *[Tt][Ee][Rr][Rr][Aa][Ff][Oo][Rr][Mm]*|*[Pp][Uu][Ll][Uu][Mm][Ii]*|*[Ss][Uu][Pp][Aa][Bb][Aa][Ss][Ee]*|*[Ss][Tt][Rr][Ii][Pp][Ee]*|*[Kk][Uu][Bb][Ee][Cc][Tt][Ll]*|\
  *[Hh][Ee][Ll][Mm]*|*[Pp][Rr][Ii][Ss][Mm][Aa]*|*[Dd][Rr][Ii][Zz][Zz][Ll][Ee]*|*[Dd][Ee][Pp][Ll][Oo][Yy]*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

tool_name="$(printf '%s' "$input" | jq -r '.tool_name? // empty' 2>/dev/null)"
[ "$tool_name" = "Bash" ] || exit 0

# Role resolution: exact string match against space-delimited membership. No match, an empty or an absent
# agent_type resolves to no role, i.e. no opinion.
agent_type="$(printf '%s' "$input" | jq -r '.agent_type? // empty' 2>/dev/null)"
role=""
if [ -n "$agent_type" ]; then
  case " $AGENT_TYPES_IMPLEMENTER " in
    *" $agent_type "*) role="implementer" ;;
  esac
  if [ -z "$role" ]; then
    case " $AGENT_TYPES_VERIFIER " in
      *" $agent_type "*) role="verifier" ;;
    esac
  fi
fi
[ -n "$role" ] || exit 0

# Never opine during a planning turn — same rationale as git-c-guard.sh's identical check: a
# denial during plan mode could read as though the command had actually been attempted.
pmode="$(printf '%s' "$input" | jq -r '.permission_mode? // empty' 2>/dev/null)"
[ "$pmode" != "plan" ] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command? // empty' 2>/dev/null)"

# #543: the command-size cap, before the strip and the scan (see AB_CMD_MAX_BYTES above). Both roles, every
# command that got past the fast paths and the role and plan-mode exits above, whatever it holds.
ab_bytes "$cmd"
[ "$ab_n" -le "$AB_CMD_MAX_BYTES" ] || deny_over_cap "$AB_CMD_MAX_BYTES"

# A CRLF-carrying transport can deliver tokens with a trailing carriage return (#270); every comparison
# below is an exact match, so an unstripped CR would make git<CR> a command word never matched. Stripped
# once here, before the tokenizer (hooks/push-guard.sh strips inside its awk record block instead, before
# reading any token). Pure parameter expansion: no new process, so this hook still executes nothing. Under
# bash 3.2 that substitution's cost grows faster than its input and the cap above does not bound it, so a
# command that carries any CR also meets the lower AB_CR_MAX_BYTES first (#535).
cr=$'\r'
case "$cmd" in
  *"$cr"*) [ "$ab_n" -le "$AB_CR_MAX_BYTES" ] || deny_over_cap "$AB_CR_MAX_BYTES" ;;
esac
cmd="${cmd//$cr/}"

[ -n "$cmd" ] || exit 0

# --- the scan ------------------------------------------------------------------------------
# A POSIX-awk tokenizer that never REJECTS, unlike hooks/git-c-guard.sh's lexer, which rejects on any
# unquoted metacharacter: rejecting here would leave this hook silent for exactly the composite or injected
# forms it exists to catch. The scan is quote-blind by design (it strips quote characters instead of
# tracking quote state): a quote-aware lexer could mis-track an unterminated quote and let a real push
# through, the worse failure for a control whose only job is to fail closed. So a break character inside a
# quote or a substitution cuts a segment like any other, and the command hidden behind it is a known gap
# (docs/reference/safety-model.md, "Known gaps"). Each input line is scanned as its own segment start, so a
# heredoc body line that starts with git or gh is a deliberate over-block (write file content with the
# Write/Edit tools).
#
# Output contract, one finding per line:
#   gh | git <sub> | <word>   a resolved command word; git carries its subcommand (never case-folded), or
#                             the sentinel -none-, -globalopt- or -prefix- (#505)
#   -claude-write- <token>    a .claude path in a write position, or an interpreter word sharing the call
#                             with a .claude mention (#340, #387)
#   -deploy- <entry>          a DEPLOY_COMMANDS entry, or package script <name> (#551); printed once, last, by
#                             its own END block, so an earlier finding always decides first
#
# Each rule is described next to its code: the per-record block (redirect pass, base split, command-level
# capture) and emit_segment() (the walk; #505 lost prefix, #518 value context).
scan_out="$(printf '%s\n' "$cmd" | awk -v prefix_words="$PREFIX_WORDS" -v arg_cmds="$CLAUDE_PATH_ARG_COMMANDS" -v cw_cmds="$CLAUDE_CMDLINE_WRITE_COMMANDS" -v vpwords="$PREFIX_VALUE_WORDS" -v dep_cmds="$DEPLOY_COMMANDS" -v launch_words="$LAUNCH_WORDS" '
BEGIN {
  sq = sprintf("%c", 39)
  n = split(prefix_words, pwarr, " ")
  for (i = 1; i <= n; i++) prefix_set[pwarr[i]] = 1
  na = split(arg_cmds, acarr, " ")
  for (i = 1; i <= na; i++) arg_set[acarr[i]] = 1
  ncw = split(cw_cmds, cwarr, " ")
  for (i = 1; i <= ncw; i++) cw_set[cwarr[i]] = 1
  nvp = split(vpwords, vparr, " ")
  for (i = 1; i <= nvp; i++) vprefix_set[vparr[i]] = 1
  nd = split(dep_cmds, darr, ",")
  for (i = 1; i <= nd; i++) dep_set[darr[i]] = 1
  nl = split(launch_words, larr, " ")
  for (i = 1; i <= nl; i++) launch_set[larr[i]] = 1
}
function normalize(tok,    t, parts, np) {
  t = tok
  gsub(sq, "", t)
  gsub(/"/, "", t)
  gsub(/\\/, "", t)
  np = split(t, parts, "/")
  return parts[np]
}
# has_claude_seg (#340): TRUE iff tok, quote characters stripped and backslashes read as slashes,
# case-folded, has an EXACT .claude path segment (not .claude-backup, not a bare basename match, so
# normalize() is deliberately not used). The wrapping slashes turn a leading or trailing segment into an
# interior one.
function has_claude_seg(tok,    u) {
  u = tok
  gsub(sq, "", u)
  gsub(/"/, "", u)
  gsub(/\\/, "/", u)
  u = tolower(u)
  return index("/" u "/", "/.claude/") > 0
}
# claude_seg_in_text (#387): TRUE iff s, case-folded and space-wrapped, holds an exact .claude path segment
# bounded by non-filename characters (no quote stripping: s is a raw record or a whitespace-split token).
# The #387 command-level rule: emit_segment() captures into the global cw_word the first command word whose
# version-stripped basename is a CLAUDE_CMDLINE_WRITE_COMMANDS member, and the per-record block calls this
# function on the RAW, un-broken record (so a .claude mention buried in a parenthesised argument list is
# found) and records the first such whitespace token in cw_tok. Both globals accumulate across every line of
# the command, so a heredoc-fed interpreter and its .claude mention can sit on different lines. The first
# END block prints -claude-write- <cw_word> with <cw_tok> once both are set.
function claude_seg_in_text(s,    v) {
  v = tolower(" " s " ")
  return match(v, /[^a-z0-9_.-]\.claude[^a-z0-9_.-]/) > 0
}
# #505 fail-closed: a command prefix the scan cannot follow. The walk is quote-blind and splits on
# whitespace, so an assignment whose quoted or escaped value the split cut in two leaves a bogus word in
# command position. The one trigger is a token shape, never the command-word candidate itself (so a heredoc
# or commit-message line stays quiet): an assignment with an odd count of double quotes, an odd count of
# single quotes or a trailing backslash. It reads, once per segment, every later token (lost_scan, shared
# with the #518 trigger): a word that is exactly gh prints gh, exactly git prints the sentinel
# git -prefix- (denied for both roles), a token with a .claude segment prints the -claude-write- line; a hit
# ends the segment, no hit leaves the walk unchanged. Cost: a constant number of checks per token and at most
# one lost_scan() per segment, O(segment). The walk follows no option of env: env is a prefix word like any
# other, and its dash tokens are skipped as options of a prefix word.
# This program is single-quoted shell: it must never contain a literal apostrophe, comments included (use
# sq). quote_unbalanced: an odd count of double quotes, an odd count of single quotes or a trailing
# backslash. Same body as hooks/push-guard.sh.
function quote_unbalanced(tok,    t, n) {
  t = tok
  n = gsub(/"/, "", t)
  if (n % 2) return 1
  t = tok
  n = gsub(sq, "", t)
  if (n % 2) return 1
  return (substr(tok, length(tok)) == "\\")
}
# lost_word (#505) -- read one token: case-folded, quote and backslash characters deleted, split into words
# at every run of characters outside letters, digits, dot, underscore and hyphen. Returns gh for the first
# word that is exactly gh, git -prefix- for the first that is exactly git, else empty.
function lost_word(tok,    lx, lwa, lwn, lwi, lwv) {
  lx = tolower(tok)
  gsub(sq, "", lx)
  gsub(/"/, "", lx)
  gsub(/\\/, "", lx)
  lwn = split(lx, lwa, /[^a-z0-9._-]+/)
  for (lwi = 1; lwi <= lwn; lwi++) {
    lwv = lwa[lwi]
    if (lwv == "") continue
    if (lwv == "gh") return "gh"
    if (lwv == "git") return "git -prefix-"
  }
  return ""
}
# lost_scan (#505) -- once per segment (ls_done): the verdict for the rest of a segment whose command word
# the walk can no longer find: the first word that is exactly gh or git in toks[from..ntok] (lost_word),
# else the first token carrying a .claude segment as a -claude-write- line, else empty. A later trigger in
# the same segment reads a suffix of what the first scan read, so it returns empty at once. It also
# records, into the global cw_word, the first token whose version-stripped, case-folded basename is a
# CLAUDE_CMDLINE_WRITE_COMMANDS member, so an interpreter hidden behind a lost prefix meets the #387 rule, and,
# into the global dep_word, the first DEPLOY_COMMANDS entry that starts at one of those tokens (#551).
function lost_scan(toks, from, ntok,    i, r, c, lw, cwf) {
  if (ls_done) return ""
  ls_done = 1
  c = ""
  for (i = from; i <= ntok; i++) {
    if (dep_word == "") dep_word = dep_at(toks, i)
    r = lost_word(toks[i])
    if (r != "") return r
    # #518: an interpreter behind a lost prefix is the command word the #387 rule needs
    if (cw_word == "") {
      lw = tolower(normalize(toks[i]))
      cwf = lw
      sub(/[0-9.]+$/, "", lw)
      if (lw in cw_set) cw_word = cwf
    }
    if (c == "" && has_claude_seg(toks[i])) c = "-claude-write- " toks[i]
  }
  return c
}
# dep_norm (#551): one token as a deploy-list word: its basename with quotes and backslashes stripped
# (normalize), case-folded, and cut at a version marker (vercel@latest is vercel).
function dep_norm(tok,    w) { w = tolower(normalize(tok)); sub(/@.*/, "", w); return w }
# dep_at: the DEPLOY_COMMANDS entry that one, two or three consecutive dep_norm words starting at toks[j]
# spell, else empty. A phrase entry (prisma db push) matches only whole.
function dep_at(toks, j,    p) {
  p = dep_norm(toks[j])
  if (p in dep_set) return p
  p = p " " dep_norm(toks[j + 1])
  if (p in dep_set) return p
  p = p " " dep_norm(toks[j + 2])
  return (p in dep_set) ? p : ""
}
# dep_check: the deploy verdict for the command word at toks[at], recorded in the global dep_word (the second
# END block prints it). A listed entry is the verdict. A LAUNCH_WORDS member (npx, pnpm dlx, uvx, ...) hands on
# to the word it runs, so the words after it are read left to right: a dash option and the sub-words
# (exec x dlx run run-script) are skipped, as is the word right after a dash option (it may be that option
# value), and the first other word ends the read. Each word read is a listed entry, or, after npm, pnpm, yarn
# or bun, a word containing deploy (a package script name, tested before the option-value skip). After those
# four, a package manager own subcommand (add install i ci remove rm uninstall un update up upgrade link
# unlink outdated audit why ls list info view pack init create) ends the read with no hit, before it can be
# taken for an option value: pnpm -w add stripe installs stripe, it does not run it. run, run-script, exec, x
# and dlx are not on that list, and neither is publish. Cost: one pass over the segment, constant work per
# token.
function dep_check(toks, at, ntok,    j, w, h, pm, vd) {
  dep_word = dep_at(toks, at); w = dep_norm(toks[at])
  if (dep_word != "" || !(w in launch_set)) return
  pm = (w ~ /^(npm|pnpm|yarn|bun)$/)
  for (j = at + 1; j <= ntok; j++) {
    w = dep_norm(toks[j]); h = dep_at(toks, j)
    if (pm && w ~ /^(add|install|i|ci|remove|rm|uninstall|un|update|up|upgrade|link|unlink|outdated|audit|why|ls|list|info|view|pack|init|create)$/) return
    if (h == "" && substr(w, 1, 1) == "-") { vd = 1; continue }
    if (h == "" && pm && index(w, "deploy") > 0) h = "package script " w
    if (h != "") { dep_word = h; return }
    if (w == "" || vd || (w in launch_set)) { vd = 0; continue }
    return
  }
}
# emit_segment: walk the tokens of one segment to its command word and print the finding. Per token, in order:
# an assignment (after the #505 parity check) and a token whose normalised, case-folded form is empty (a
# lone quote left by a leading space inside a quoted eval argument) are skipped; then the #518 trigger
# below; then a PREFIX_WORDS member is skipped and sets saw_prefix; after a prefix word a dash token is
# skipped as an option of that word. The first surviving token is the
# command word, printed normalised and case-folded. For git the tokens after it are walked once more: -C and
# its value are skipped, any other dash token gives -globalopt-, no subcommand gives -none-; the subcommand
# is never case-folded, so the verifier read-only match stays exact and fails closed. For a
# CLAUDE_PATH_ARG_COMMANDS member the later tokens are searched for a .claude segment
# (-claude-write-); sed does the same only with an in-place flag (-i, -i.bak, --in-place), since sed -n only
# reads. The command word also meets dep_check (#551), which records a deploy finding in the global dep_word
# instead of printing it. A segment with no surviving token prints nothing.
function emit_segment(seg,    ntok, toks, idx, tok, norm, saw_prefix, cmdword, j, gitsub, inplace, lw, in_vp, lost) {
  ntok = split(seg, toks, /[ \t]+/)
  ls_done = 0
  idx = 1
  saw_prefix = 0
  cmdword = ""
  in_vp = 0
  while (idx <= ntok) {
    tok = toks[idx]
    if (tok == "") { idx++; continue }
    if (match(tok, /^[A-Za-z_][A-Za-z0-9_]*=/) == 1 && quote_unbalanced(tok)) { lost = lost_scan(toks, idx + 1, ntok); if (lost != "") { print lost; return } }
    if (match(tok, /^[A-Za-z_][A-Za-z0-9_]*=/) == 1) { idx++; continue }
    norm = tolower(normalize(tok))
    if (norm == "") { idx++; continue }
    # #518 fail-closed: a dash option of a PREFIX_VALUE_WORDS member can take the NEXT word as its value, and
    # the walk models no prefix command option grammar, so that value would become the command word. A dash
    # token followed by a word that does not start with a dash is a trigger: lost_scan() reads the rest of the
    # segment AFTER that word (never the word itself, so `sudo -E git status` is still judged on git). A later
    # prefix word outside the vocabulary closes the context. The interpreter words are value words too, so
    # bash -o pipefail -c "gh pr merge 5" denies; the price is that a -c string naming gh, git or a .claude
    # path after its first word denies as well, and a plus-led option is not read. Cost: O(1) per dash token
    # plus the shared lost_scan().
    if (in_vp && substr(tok, 1, 1) == "-" && idx < ntok && toks[idx + 1] != "" && substr(toks[idx + 1], 1, 1) != "-") {
      lost = lost_scan(toks, idx + 2, ntok)
      if (lost != "") { print lost; return }
    }
    if (norm in prefix_set) { in_vp = (norm in vprefix_set) }
    if (norm in prefix_set) { saw_prefix = 1; idx++; continue }
    if (saw_prefix && substr(tok, 1, 1) == "-") { idx++; continue }
    cmdword = norm
    idx++
    break
  }
  if (cmdword == "") return
  if (dep_word == "") dep_check(toks, idx - 1, ntok)
  if (cmdword == "git") {
    gitsub = ""
    j = idx
    while (j <= ntok) {
      tok = toks[j]
      if (tok == "") { j++; continue }
      if (tok == "-C") { j += 2; continue }
      if (substr(tok, 1, 1) == "-") { gitsub = "-globalopt-"; break }
      gitsub = normalize(tok)
      break
    }
    if (gitsub == "") gitsub = "-none-"
    print "git " gitsub
  } else {
    print cmdword
    lw = cmdword
    sub(/[0-9.]+$/, "", lw)
    if ((lw in cw_set) && cw_word == "") cw_word = cmdword
    if (cmdword in arg_set) {
      for (j = idx; j <= ntok; j++) {
        if (has_claude_seg(toks[j])) { print "-claude-write- " toks[j]; break }
      }
    } else if (cmdword == "sed") {
      inplace = 0
      for (j = idx; j <= ntok; j++) {
        if (match(toks[j], /^-[A-Za-z]*i/) == 1) { inplace = 1; break }
        if (match(toks[j], /^--in-place/) == 1) { inplace = 1; break }
      }
      if (inplace) {
        for (j = idx; j <= ntok; j++) {
          if (has_claude_seg(toks[j])) { print "-claude-write- " toks[j]; break }
        }
      }
    }
  }
}
{
  # Per record: (1) the #340 redirect pass: every >, >>, >| or >& in the raw line (before the segment-break
  # gsub blanks its target) yields -claude-write- <target> when the target token has a .claude segment; < is
  # never matched (an input redirect is ignored) and >&2 / 2>&1 give the targets 2 / 1; (2) the base split:
  # ; & | ( ) { } and a backtick start a new segment, < and > are plain separators, and each segment goes to
  # emit_segment(); (3) the #387 cw_tok capture.
  rd_rest = $0
  while (match(rd_rest, />[>|&]?[ \t]*[^ \t;&|(){}`<>]+/)) {
    rd_tgt = substr(rd_rest, RSTART, RLENGTH)
    sub(/^>[>|&]?[ \t]*/, "", rd_tgt)
    if (has_claude_seg(rd_tgt)) print "-claude-write- " rd_tgt
    rd_rest = substr(rd_rest, RSTART + RLENGTH)
  }
  line = $0
  gsub(/[;&|(){}`]/, "\n", line)
  gsub(/[<>]/, " ", line)
  nseg = split(line, segs, /\n/)
  for (s = 1; s <= nseg; s++) emit_segment(segs[s])
  if (cw_tok == "" && claude_seg_in_text($0)) {
    cw_ntok = split($0, cw_toks, /[ \t]+/)
    for (cw_j = 1; cw_j <= cw_ntok; cw_j++) {
      if (claude_seg_in_text(cw_toks[cw_j])) { cw_tok = cw_toks[cw_j]; break }
    }
  }
}
END { if (cw_word != "" && cw_tok != "") print "-claude-write- " cw_word " with " cw_tok }
END { if (dep_word != "") print "-deploy- " dep_word }
' 2>/dev/null)"
scan_rc=$?
# #559: a non-zero status means the scan stopped early (an awk abort, a resource limit, a killed process, or
# no runnable awk) and judged only part of the command, so deny with one fixed reason before the role policy
# reads scan_out. awk's own error text is dropped (2>/dev/null above) so the deny stays one stderr line.
if [ "$scan_rc" -ne 0 ]; then
  printf '%s %s role: the command scan did not finish, so the command cannot be checked (blocked: command scan failed) — see agents/%s.md\n' \
    "$DENY_STEM" "$role" "$role" >&2
  exit 2
fi

# --- role policy -----------------------------------------------------------------------------
# Implementer: deny on ANY segment whose command word is git or gh, whatever the subcommand. Verifier: deny
# gh outright, and git unless the resolved subcommand is on VERIFIER_GIT_READONLY (so -globalopt-, -none-,
# -prefix- and any unlisted subcommand deny, fail closed). BOTH roles deny a -claude-write-
# line: the verifier's own writes are transient probe edits restored before it returns (agents/verifier.md),
# never a .claude write from Bash. BOTH roles also deny a -deploy- line (#551), which the scan prints last,
# so every git, gh and .claude finding above keeps its exact reason. The first offending line (scan order)
# decides; stdout stays empty on every path.
deny_cmd=""
deny_kind="git"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    "-claude-write- "*)
      deny_kind="claude"
      deny_cmd="${line#-claude-write- }"
      break
      ;;
    "-deploy- "*)
      deny_kind="deploy"
      deny_cmd="${line#-deploy- }"
      break
      ;;
    "git "*)
      if [ "$role" = "implementer" ]; then
        deny_cmd="$line"
        break
      fi
      sub="${line#git }"
      case " $VERIFIER_GIT_READONLY " in
        *" $sub "*) ;;
        *) deny_cmd="$line"; break ;;
      esac
      ;;
    gh)
      deny_cmd="gh"
      break
      ;;
  esac
done <<EOF
$scan_out
EOF

if [ -n "$deny_cmd" ]; then
  if [ "$deny_kind" = "claude" ]; then
    printf '%s %s role may not write a path under a .claude segment from Bash (blocked: %s) — record it in your report'"'"'s Reviewer notes instead; see agents/%s.md\n' \
      "$DENY_STEM" "$role" "$deny_cmd" "$role" >&2
  elif [ "$deny_kind" = "deploy" ]; then
    printf '%s %s role may not run a deploy or cloud CLI, directly, through a launcher or through a package script (blocked: %s) — see agents/%s.md\n' \
      "$DENY_STEM" "$role" "$deny_cmd" "$role" >&2
  elif [ "$role" = "implementer" ]; then
    printf '%s implementer role may not run any of: %s (blocked: %s) — see agents/implementer.md\n' \
      "$DENY_STEM" "$BLOCKED_COMMANDS" "$deny_cmd" >&2
  else
    printf '%s verifier role may only run read-only git (%s), never gh (blocked: %s) — see agents/verifier.md\n' \
      "$DENY_STEM" "$VERIFIER_GIT_READONLY" "$deny_cmd" >&2
  fi
  exit 2
fi

exit 0
