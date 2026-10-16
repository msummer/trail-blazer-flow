#!/usr/bin/env bash
#
# agent-boundary.sh — plugin-shipped PreToolUse hook (#235) that mechanically enforces the implementer and
# verifier subagents' "no git, no gh" boundary, and a ".claude write" boundary for both roles.
#
# Contract: read the PreToolUse hook JSON on stdin. Print nothing and exit 0 ("no opinion") unless the call
# is a Bash command from a recognised implementer or verifier agent_type that the role policy (bottom of
# this file) denies. The no-opinion cases: the main session (no agent_type), any other agent,
# permission_mode "plan", malformed stdin, another tool, an absent tool_input.command, a missing jq. A deny
# prints exactly one reason line to stderr and exits 2; stdout is always empty. A deny is one of:
#   - the implementer: a command word that resolves, case-insensitively, to git or gh;
#   - the verifier: gh, and git unless the resolved subcommand is on VERIFIER_GIT_READONLY (an unlisted
#     subcommand, a global option before the subcommand, a bare git, a runtime expansion before git, or a
#     git behind a command prefix the scan cannot follow all deny);
#   - both roles: a path under a .claude segment in a write position (a redirect target, an argument of a
#     CLAUDE_PATH_ARG_COMMANDS member, an in-place sed argument) or an interpreter or one-step writer
#     (CLAUDE_CMDLINE_WRITE_COMMANDS) sharing the call with a .claude mention anywhere;
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
#   - the segment breaking, normalize(), the prefix-word skip including the repeat-count skip, the
#     empty-token skip, the command-word case fold, and the CR strip before any token is read (this hook
#     strips in bash after the jq extraction; push-guard strips first thing in its awk record block);
#   - rx_re and rx_word() (the #508 expansion predicate; the verdict differs per file);
#   - the #505 env arm and prefix triggers with strip_quotes(), quote_bearing(), quote_unbalanced() and the
#     ENV_* values; the #518 value context with PREFIX_VALUE_WORDS; the #537 interpreter-option rule with
#     PREFIX_INTERP_WORDS, INTERP_VALUE_OPTS and ip_kind().
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
# while, !, ...); eval and trap, which run their string argument as a command (the quote-blind scan already
# reads a quoted argument's words as command words); and the zsh precommand modifiers noglob, nocorrect, -
# and repeat N (repeat also consumes its count token). { } ( ) need no entry: they are segment breaks.
# for, select, case, function, in, fi, done, esac and [[ are left out because none runs the next word as a
# command. Keywords share the dash-token skip after a prefix word, harmless because no keyword precedes a
# dash-led command.
# Pinned byte-identical to hooks/push-guard.sh by 4.40(c); the hooks/claude-dir-guard.sh copy is by convention.
PREFIX_WORDS="env command builtin exec sudo nohup time nice stdbuf xargs bash sh zsh ksh dash if then elif else do while until ! coproc eval trap noglob nocorrect - repeat"
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
# ENV_NOVALUE_OPTS / ENV_UNSET_OPTS (#505): the env options the walk follows. The first list takes no value
# and is skipped alone; the second takes the NEXT token as its value (the attached -uNAME and --unset=NAME
# forms are read by shape). Any other option after env is one the walk cannot follow (the #505 trigger).
# Byte-identical to hooks/push-guard.sh PUSH_ENV_NOVALUE_OPTS / PUSH_ENV_UNSET_OPTS, by convention.
ENV_NOVALUE_OPTS="-i -0 -v -- --ignore-environment --null --debug"
ENV_UNSET_OPTS="-u --unset"
# PREFIX_VALUE_WORDS (#518): the PREFIX_WORDS members whose dash options can take a SEPARATE value word
# (nice -n 5, sudo -u root, exec -a foo). After one of these, a dash token followed by a non-option word is
# a point where the walk cannot tell the value from the command word. Interpreter words stay out (their -c
# value IS the command string; see PREFIX_INTERP_WORDS). Byte-identical to the push-guard.sh and
# claude-dir-guard.sh copies, by convention.
PREFIX_VALUE_WORDS="exec nice stdbuf sudo time xargs"
# PREFIX_INTERP_WORDS / INTERP_VALUE_OPTS (#537): the interpreter members of PREFIX_WORDS, and the long
# options of those interpreters that take a SEPARATE value word. While the most recent prefix word is an
# interpreter, a dash or plus token is classified by ip_kind() instead of skipped blindly. Byte-identical to
# the push-guard.sh and claude-dir-guard.sh copies, by convention.
PREFIX_INTERP_WORDS="bash dash ksh sh zsh"
INTERP_VALUE_OPTS="--init-file --rcfile -init-file -rcfile"
DENY_STEM="trail-blazer-flow agent boundary:"

input="$(cat)"

# --- fast paths ----------------------------------------------------------------------------
# Both are performance shortcuts, semantics-preserving with the check they stand in for EXCEPT for a command
# word split by quote, backslash or carriage-return characters (see fast path 2): a documented limit of the
# same tripwire class as the scan quote-blind behaviour. A miss on either means the call is out of scope for
# this hook, which is also what the slower checks below conclude.
#
# Fast path 1: a main-session Bash call (no agent_type key in the JSON) can never resolve to a role, so skip
# jq. A raw substring hit only means the JSON has an agent_type key worth asking jq about (a subagent cwd can
# match by coincidence); the role check below still needs an exact match.
case "$input" in
  *agent_type*) : ;;
  *) exit 0 ;;
esac

# Fast path 2: this hook only denies a command word that resolves, case-insensitively, to git or gh, or a
# write to a .claude path, or an interpreter sharing the call with a .claude mention. If none of git, gh or
# claude (each case-insensitively) appears anywhere in the raw stdin, no segment can do any of those, so
# skip the jq/awk spawn. The case fold is the POSIX-glob [Gg][Ii][Tt] idiom, not nocasematch or ,, / ^^,
# which bash 3.2 lacks.
# Semantics-preserving except for a command word split by quote, backslash or carriage-return characters:
# normalize() strips quotes and backslashes before comparing and the CR strip removes a real CR byte, so
# g"i"t push normalises to git while the raw literal git never appears, and this path exits silently where
# the scan would have denied. A CR inside the raw JSON literal (escaped as backslash and r) or a .claude
# segment split by a quote or backslash inside it can miss the same way. How often this path
# short-circuits a subagent call is UNVERIFIED; a miss costs one extra jq/awk spawn, never a verdict.
case "$input" in
  *[Gg][Ii][Tt]*|*[Gg][Hh]*|*[Cc][Ll][Aa][Uu][Dd][Ee]*) : ;;
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

# A CRLF-carrying transport can deliver tokens with a trailing carriage return (#270); every comparison
# below is an exact match, so an unstripped CR would make git<CR> a command word never matched. Stripped
# once here, before the tokenizer (hooks/push-guard.sh strips inside its awk record block instead, before
# reading any token). Pure parameter expansion: no new process, so this hook still executes nothing.
cr=$'\r'
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
#                             the sentinel -none-, -globalopt-, -expansion- (#508) or -prefix- (#505)
#   -claude-write- <token>    a .claude path in a write position, or an interpreter word sharing the call
#                             with a .claude mention (#340, #387)
#
# Each rule is described next to its code: the per-record block (redirect pass, base split,
# command-level capture) and emit_segment() (the walk; #505 lost prefix, #508 expansion, #518 value
# context, #537 interpreter options).
scan_out="$(printf '%s\n' "$cmd" | awk -v prefix_words="$PREFIX_WORDS" -v arg_cmds="$CLAUDE_PATH_ARG_COMMANDS" -v cw_cmds="$CLAUDE_CMDLINE_WRITE_COMMANDS" -v envnov="$ENV_NOVALUE_OPTS" -v envunset="$ENV_UNSET_OPTS" -v vpwords="$PREFIX_VALUE_WORDS" -v ipwords="$PREFIX_INTERP_WORDS" -v ipvopts="$INTERP_VALUE_OPTS" '
BEGIN {
  sq = sprintf("%c", 39)
  n = split(prefix_words, pwarr, " ")
  for (i = 1; i <= n; i++) prefix_set[pwarr[i]] = 1
  na = split(arg_cmds, acarr, " ")
  for (i = 1; i <= na; i++) arg_set[acarr[i]] = 1
  ncw = split(cw_cmds, cwarr, " ")
  for (i = 1; i <= ncw; i++) cw_set[cwarr[i]] = 1
  nenv = split(envnov, envnovarr, " ")
  for (i = 1; i <= nenv; i++) envnov_set[envnovarr[i]] = 1
  neun = split(envunset, envunsetarr, " ")
  for (i = 1; i <= neun; i++) envunset_set[envunsetarr[i]] = 1
  nvp = split(vpwords, vparr, " ")
  for (i = 1; i <= nvp; i++) vprefix_set[vparr[i]] = 1
  # #537: the interpreter prefix words, and the long options of those interpreters that take a value
  nip = split(ipwords, iparr, " ")
  for (i = 1; i <= nip; i++) ip_set[iparr[i]] = 1
  nipv = split(ipvopts, ipvarr, " ")
  for (i = 1; i <= nipv; i++) ipv_set[ipvarr[i]] = 1
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
# rx_word (#508): TRUE iff the basename of tok holds a runtime expansion: a dollar sign followed by a name
# character, a digit, a special parameter (@ * # ? ! $ -), a zsh flag (= ~ ^), an apostrophe or a double
# quote. The directory part never counts ($D/gh still resolves by its last component); the split is on a
# literal slash. emit_segment() skips such a word as a possibly-empty prefix word and sets saw_exp: a git
# reached past one prints -expansion-, which the verifier denies like any unlisted subcommand and the
# implementer denies as any git. An assignment after a prefix word that holds an expansion sets saw_exp too;
# a bare assignment before any prefix word never does. Same rx_re as hooks/push-guard.sh, a per-hook verdict.
function rx_word(tok,    parts, np) {
  if (index(tok, "$") == 0) return 0
  np = split(tok, parts, "/")
  return match(parts[np], rx_re) > 0
}
# rx_env_scan (#508): over the current record, the first exact word git or gh (each env -S backslash-
# underscore read as a space), so an env -S string that holds an expansion, or that the segmenter cut at
# ${, $( or a backtick, and that names either, is found. Returns the sentinel to print, or empty.
function rx_env_scan(    t, w, n, i) {
  t = tolower($0)
  gsub(/\\_/, " ", t)
  n = split(t, w, /[^a-z0-9._-]+/)
  for (i = 1; i <= n; i++) {
    if (w[i] == "gh") return "gh"
    if (w[i] == "git") return "git -expansion-"
  }
  return ""
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
# whitespace, so a prefix whose real extent it cannot see leaves a bogus word in command position. Three
# triggers, each a token shape, never the command-word candidate itself (so a heredoc or commit-message
# line stays quiet):
#   (1) an assignment with an odd count of double quotes, an odd count of single quotes or a trailing
#       backslash (the whitespace split cut its value in two);
#   (2) after an env word, an option outside ENV_NOVALUE_OPTS / ENV_UNSET_OPTS (env -C DIR, env -S STR);
#   (3) after a prefix word, a quote-bearing token that reads as an option or an assignment once unquoted.
# The env arm follows -u / --unset (the value is skipped with it), the attached -uNAME / --unset=NAME and
# the no-value options; an expansion in a -u value sets saw_exp; a -u value with unbalanced quotes is
# trigger (1) again. An option trigger also reads its own token (lost_word with LEAD, so -Sgh and -vSgit
# count). Every trigger then reads, once per segment, every later token (lost_scan): a word that is exactly
# gh prints gh, exactly git prints the sentinel git -prefix- (denied for both roles), a token with a .claude
# segment prints the -claude-write- line; a hit ends the segment, no hit leaves the walk unchanged. Cost: a
# constant number of checks per token and at most one lost_scan() per segment, O(segment).
# This program is single-quoted shell: it must never contain a literal apostrophe, comments included (use
# sq). strip_quotes: the token without quote or backslash characters. quote_bearing: the token carries a
# quote or a backslash. quote_unbalanced: an odd count of double quotes, an odd count of single quotes or a
# trailing backslash. Same bodies as hooks/push-guard.sh.
function strip_quotes(tok,    t) {
  t = tok
  gsub(sq, "", t)
  gsub(/"/, "", t)
  gsub(/\\/, "", t)
  return t
}
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
# lost_word (#505) -- read one token the way env -S reads its string: case-folded, each backslash-
# underscore read as a space, quote and backslash characters deleted, split into words at every run of
# characters outside letters, digits, dot, underscore and hyphen. Returns gh for the first word that is
# exactly gh, git -prefix- for the first that is exactly git, else empty. With LEAD set, the first non-empty
# word also counts when it starts with a hyphen and ends in gh or git (an attached option value: -Sgh).
function lost_word(tok, lead,    lx, lwa, lwn, lwi, lwf, lwv) {
  lx = tolower(tok)
  gsub(/\\_/, " ", lx)
  gsub(sq, "", lx)
  gsub(/"/, "", lx)
  gsub(/\\/, "", lx)
  lwn = split(lx, lwa, /[^a-z0-9._-]+/)
  lwf = 1
  for (lwi = 1; lwi <= lwn; lwi++) {
    lwv = lwa[lwi]
    if (lwv == "") continue
    if (lwv == "gh") return "gh"
    if (lwv == "git") return "git -prefix-"
    if (lead && lwf && substr(lwv, 1, 1) == "-") {
      if (length(lwv) > 2 && substr(lwv, length(lwv) - 1) == "gh") return "gh"
      if (length(lwv) > 3 && substr(lwv, length(lwv) - 2) == "git") return "git -prefix-"
    }
    lwf = 0
  }
  return ""
}
# lost_scan (#505) -- once per segment (ls_done): the verdict for the rest of a segment whose command word
# the walk can no longer find: the first word that is exactly gh or git in toks[from..ntok] (lost_word),
# else the first token carrying a .claude segment as a -claude-write- line, else empty. A later trigger in
# the same segment reads a suffix of what the first scan read, so it returns empty at once. It also
# records, into the global cw_word, the first token whose version-stripped, case-folded basename is a
# CLAUDE_CMDLINE_WRITE_COMMANDS member, so an interpreter hidden behind a lost prefix meets the #387 rule.
function lost_scan(toks, from, ntok,    i, r, c, lw, cwf) {
  if (ls_done) return ""
  ls_done = 1
  c = ""
  for (i = from; i <= ntok; i++) {
    r = lost_word(toks[i], 0)
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
# #537 fail-closed: an option of an interpreter prefix word (PREFIX_INTERP_WORDS). Interpreters stay out of
# PREFIX_VALUE_WORDS because the value of -c IS the command string, so reading past it would deny
# `bash -e -o pipefail -c "echo gh"`; their options are classified instead. While the most recent prefix
# word is an interpreter, a token that starts with a dash or plus, is longer than one character, is not
# --, holds no slash and is not read as a prefix word is one of three kinds (ip_kind): "v", a value option
# (a member of INTERP_VALUE_OPTS, or a dash or plus followed by letters of which exactly one is o or O and
# it is the last: -o, +O, -eo), skipped together with the NEXT word when ip_value_ok() accepts that word;
# "f", a flag (letters with no o or O: -e, -c, -lc, +e), skipped alone; "u", anything else (two value
# letters, a value letter that is not last, an unlisted long option, a non-letter), or a "v" whose next
# word failed the test. For a "u", when the next word is no option, lost_scan() reads the rest of the
# segment AFTER that word (the word itself stays the command word, so `zsh -cO gh pr merge 5` still
# resolves gh) through the scan memo the #505 and #518 triggers share, and the option is skipped alone. A
# token holding a dollar sign is never skipped by this rule: it falls through to the #508 expansion skip.
# A word is skipped only when the old walk, which took it for the command word, could not have denied on it,
# so no deny turns into an allow. Cost: per token after an interpreter word one regex match, one gsub and a
# constant number of set lookups, O(token); a value option consumes its value with no rescan; at most one
# lost_scan() per segment.
function ip_kind(t,    u, c) {
  if (t in ipv_set) return "v"
  if (t !~ /^[-+][A-Za-z]+$/) return "u"
  u = t
  c = gsub(/[oO]/, "", u)
  if (c == 0) return "f"
  if (c == 1 && substr(t, length(t)) ~ /[oO]/) return "v"
  return "u"
}
# ip_value_ok (#537) -- TRUE iff w, the word after a value option of an interpreter, may be skipped with it:
# a plain word the old walk could not have denied on. Not empty, not option-led, no quote, backslash or
# dollar sign, not an assignment, and not a prefix word, gh, git, a CLAUDE_PATH_ARG_COMMANDS member, sed or
# (version-stripped) a CLAUDE_CMDLINE_WRITE_COMMANDS member.
function ip_value_ok(w,    h, n, lv) {
  if (w == "") return 0
  h = substr(w, 1, 1)
  if (h == "-" || h == "+") return 0
  if (quote_bearing(w) || index(w, "$") > 0) return 0
  if (match(w, /^[A-Za-z_][A-Za-z0-9_]*=/) == 1) return 0
  n = tolower(normalize(w))
  if (n == "" || (n in prefix_set) || n == "gh" || n == "git" || (n in arg_set) || n == "sed") return 0
  lv = n
  sub(/[0-9.]+$/, "", lv)
  if (lv in cw_set) return 0
  return 1
}
# emit_segment: walk the tokens of one segment to its command word and print the finding. Per token, in order:
# an assignment (after the #505 parity check) and a token whose normalised, case-folded form is empty (a
# lone quote left by a leading space inside a quoted eval argument) are skipped; then the env, quote-bearing,
# #518 and #537 triggers below; then a runtime-expansion word is skipped (#508); then a PREFIX_WORDS member
# is skipped and sets saw_prefix (repeat also skips its count token); after a prefix word a dash token is
# skipped as an option of that word. The first surviving token is the command word, printed normalised and
# case-folded. For git the tokens after it are walked once more: -C and its value are skipped, any other
# dash token gives -globalopt-, no subcommand gives -none-, saw_exp gives -expansion-; the subcommand is
# never case-folded, so the verifier read-only match stays exact and fails closed. For a
# CLAUDE_PATH_ARG_COMMANDS member the later tokens are searched for a .claude segment (-claude-write-);
# sed does the same only with an in-place flag (-i, -i.bak, --in-place), since sed -n only reads. A segment
# with no surviving token prints nothing.
function emit_segment(seg,    ntok, toks, idx, tok, norm, saw_prefix, cmdword, j, gitsub, inplace, lw, saw_exp, in_env, in_vp, in_ip, ipw, ipk, ipf, lost, s0) {
  ntok = split(seg, toks, /[ \t]+/)
  ls_done = 0
  idx = 1
  saw_prefix = 0
  cmdword = ""
  saw_exp = 0
  in_env = 0
  in_vp = 0
  in_ip = 0
  while (idx <= ntok) {
    tok = toks[idx]
    if (tok == "") { idx++; continue }
    if (match(tok, /^[A-Za-z_][A-Za-z0-9_]*=/) == 1 && quote_unbalanced(tok)) { lost = lost_scan(toks, idx + 1, ntok); if (lost != "") { print lost; return } }
    if (match(tok, /^[A-Za-z_][A-Za-z0-9_]*=/) == 1) { if (saw_prefix && rx_word(tok)) saw_exp = 1; idx++; continue }
    norm = tolower(normalize(tok))
    if (norm == "") { idx++; continue }
    # #508: an env -S option whose string holds (or was cut at) a runtime expansion and names git or gh
    if (in_env && (index(tok, "-S") == 1 || index(tok, "--split-string") == 1) && (rx_word(tok) || rx_cut) && rx_env_hit != "") { print rx_env_hit; return }
    # #505: an option after an env word. The allowlisted no-value options are skipped alone, -u/--unset
    # take their value with them, and any other option is one this walk cannot follow (-C/--chdir change
    # the directory, -S splits a string into more words): read the rest of the segment for gh or git.
    if (in_env && substr(tok, 1, 1) == "-") {
      if (tok in envnov_set) { idx++; continue }
      if (tok in envunset_set) {
        if (rx_word(toks[idx + 1])) saw_exp = 1
        if (quote_unbalanced(toks[idx + 1])) { lost = lost_scan(toks, idx + 1, ntok); if (lost != "") { print lost; return } }
        idx += 2
        continue
      }
      if (substr(tok, 1, 2) == "-u" || index(tok, "--unset=") == 1) {
        if (rx_word(tok)) saw_exp = 1
        if (quote_unbalanced(tok)) { lost = lost_scan(toks, idx + 1, ntok); if (lost != "") { print lost; return } }
        idx++
        continue
      }
      lost = lost_word(tok, 1)
      if (lost == "") lost = lost_scan(toks, idx + 1, ntok)
      if (lost != "") { print lost; return }
    }
    # #505: after a prefix word, a quote-bearing token that reads as an option or an assignment once
    # unquoted ("X=a", "-C") is skipped by the real shell or env but is no command word here.
    if (saw_prefix && quote_bearing(tok)) {
      s0 = strip_quotes(tok)
      if (substr(s0, 1, 1) == "-" || match(s0, /^[A-Za-z_][A-Za-z0-9_]*=/) == 1) {
        lost = lost_word(tok, 1)
        if (lost == "") lost = lost_scan(toks, idx + 1, ntok)
        if (lost != "") { print lost; return }
      }
    }
    # #518 fail-closed: a dash option of a PREFIX_VALUE_WORDS member (or of an expansion word, which may
    # expand to one) can take the NEXT word as its value, and the walk models no prefix command option
    # grammar, so that value would become the command word. A dash token followed by a word that does not
    # start with a dash is a trigger: lost_scan() reads the rest of the segment AFTER that word (never the
    # word itself, so `sudo -E git status` is still judged on git). A later prefix word outside the
    # vocabulary closes the context. Cost: O(1) per dash token plus the shared lost_scan().
    if (in_vp && substr(tok, 1, 1) == "-" && idx < ntok && toks[idx + 1] != "" && substr(toks[idx + 1], 1, 1) != "-") {
      lost = lost_scan(toks, idx + 2, ntok)
      if (lost != "") { print lost; return }
    }
    # #537: an option of an interpreter prefix word is classified by ip_kind() (see its comment). A value
    # option is skipped with its plain value word, a flag alone; an unclassified one reads the rest of the
    # segment after the next word. A dollar-sign token is never skipped by this rule: after the scan it
    # falls through to the #508 expansion skip. A token with a slash, or one read as a prefix word, keeps
    # the walk it had before this rule.
    if (in_ip && length(tok) > 1 && tok != "--" && (substr(tok, 1, 1) == "-" || substr(tok, 1, 1) == "+") && index(tok, "/") == 0 && !(norm in prefix_set)) {
      ipw = (idx < ntok) ? toks[idx + 1] : ""
      if (index(tok, "$") == 0) {
        ipk = ip_kind(tok)
        if (ipk == "v" && ip_value_ok(ipw)) { idx += 2; continue }
        if (ipk == "f") { idx++; continue }
      }
      if (ipw != "" && substr(ipw, 1, 1) != "-") {
        ipf = idx + 2
        lost = lost_scan(toks, ipf, ntok)
        if (lost != "") { print lost; return }
      }
      if (index(tok, "$") == 0) { idx++; continue }
    }
    # #508: a runtime expansion in command position may expand to nothing: skip it so the real command
    # word behind it still resolves
    if (rx_word(tok)) { saw_exp = 1; saw_prefix = 1; if (substr(tok, 1, 1) != "-") in_vp = 1; idx++; continue }
    if (norm != "-" && (norm in prefix_set)) in_ip = (norm in ip_set)
    if (norm in prefix_set && norm != "-") { in_env = (norm == "env"); in_vp = (norm in vprefix_set) }
    if (norm in prefix_set) { saw_prefix = 1; idx += (norm == "repeat") ? 2 : 1; continue }
    if (saw_prefix && substr(tok, 1, 1) == "-") { idx++; continue }
    cmdword = norm
    idx++
    break
  }
  if (cmdword == "") return
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
    if (saw_exp) gitsub = "-expansion-"
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
  # Per record: (1) the #508 facts the env -S check reads; (2) the #340 redirect pass: every >, >>, >| or >&
  # in the raw line (before the segment-break gsub blanks its target) yields -claude-write- <target> when the
  # target token has a .claude segment; < is never matched (an input redirect is ignored) and >&2 / 2>&1 give
  # the targets 2 / 1; (3) the base split: ; & | ( ) { } and a backtick start a new segment, < and > are plain
  # separators, and each segment goes to emit_segment(); (4) the #387 cw_tok capture.
  rx_cut = (index($0, "${") > 0 || index($0, "$(") > 0 || index($0, "`") > 0)
  rx_env_hit = ""
  if ((index($0, "$") > 0 || index($0, "`") > 0) && (index($0, "-S") > 0 || index($0, "--split-string") > 0)) rx_env_hit = rx_env_scan()
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
# -expansion-, -prefix- and any unlisted subcommand deny, fail closed). BOTH roles deny a -claude-write-
# line: the verifier's own writes are transient probe edits restored before it returns (agents/verifier.md),
# never a .claude write from Bash. The first offending line (scan order) decides; stdout stays empty on every
# path.
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
