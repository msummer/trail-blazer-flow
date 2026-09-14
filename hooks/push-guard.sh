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
# dev/hook-tests.sh table documents), and, since #270, the same bash-native carriage-return strip
# of $cmd applied immediately after the jq extraction and before this script's own `[ -n "$cmd" ]`
# guard (see that same point in each file — a CRLF-carrying transport can otherwise deliver a
# command whose tokens carry a trailing `\r`, which every exact-match comparison below would miss).
# A future fix to either tokenizer's shared behaviour (segment breaking, normalize(), the
# prefix-word skip, the CR strip) must be applied to BOTH files — see this repo's
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
# Repo resolution (reads only, NEVER executes anything, NEVER derives a path from the untrusted
# command string): starts from the PreToolUse stdin `cwd` field (documented in Claude Code's hooks
# reference; degrades to `$PWD` when absent) and walks upward, at most 64 parent directories,
# looking for `<dir>/.git` — a directory (an ordinary checkout) or a regular file (a worktree
# pointer, `gitdir: <path>`; a FIFO or a directory-shaped path is excluded by the `[ -f ]` guard
# every read here uses). The default branch is read from the common dir's
# `refs/remotes/origin/HEAD` symref; the current branch from the resolved gitdir's own `HEAD`
# symref; since #268, the same common dir's `config` file is also text-parsed (never executed as
# `git config`, never a second process) for `remote.<name>.push` and `push.default` /
# `branch.<current>.merge` — for a worktree this is the MAIN checkout's config, the identical
# common-dir rule the origin-HEAD symref read already uses, never the worktree pointer's own
# gitdir. The config file is read whole with no size cap — a pathological file simply degrades to
# Claude Code's 10s hook timeout (silence, the same fail-open every other resolution failure
# already has). Any failure at any step leaves both branch values, and the config-derived
# variables, empty — never an error, never a non-zero exit from this hook on that account alone.
# The deny set is `PUSH_DEFAULT_BRANCH_FALLBACK` (below) UNION the resolved default branch, if
# any — the fallback members are ALWAYS in force (even when a repo's real default branch resolves
# to something else), which is what lets this hook work with no `cwd`, no readable `.git`, or a
# `-C <other-checkout>` push it deliberately never resolves (see "Under-blocking classes" below).
#
# Never invokes `git`, `gh`, or anything else derived from the untrusted command string; never
# `eval`s; never writes a file — this hook only ever READS filesystem paths it derived from
# Claude Code's own `cwd`/`$PWD`, never from a `-C <path>` token inside the model-supplied command
# (reading THAT would let the model choose what this hook reads). bash + POSIX awk only — no jq is
# actually needed by this hook (unlike its two siblings) since it parses `tool_input.command` with
# awk, not a JSON library, but the raw-stdin fast paths below still gate on `jq`'s presence for the
# few scalar field reads (`tool_name`, `permission_mode`, `tool_input.command`, `cwd`) this hook
# does need — no python, no perl, no GNU-only flags (this repo's CLAUDE.md portability
# convention); exercised under Apple's bash 3.2 by the selfcheck-macos CI job, same as bin/*.sh,
# hooks/git-c-guard.sh, and hooks/agent-boundary.sh.
#
# Documented over-blocking classes (deliberate, not a bug): a heredoc body line beginning `git
# push origin main` (the same quote-blind, line-at-a-time class hooks/agent-boundary.sh documents
# — write file content with the Write/Edit tools, never a Bash heredoc); a remote literally named
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
# denies as `main` (rc 2) even though the actual destination branch is `main#hotfix`.
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
# to `push` correctly — what `--git-dir=<path>`/`-C` actually evade is WHICH repo gets resolved,
# already covered by the bullet below); a CR *inside* a raw-stdin fast-path literal, e.g. `git
# pu<CR>sh origin main` (measured: rc 0) — a conforming JSON writer escapes an embedded `\r` as the
# two characters `\`+`r`, so the raw stdin substring `push` never appears intact and fast path 1
# (below) exits before the #270 CR strip ever runs, regardless of the strip's own correctness; the
# resulting command cannot execute as a real `git push` either, so this is documented, not fixed
# (see the fast-path comment below); `nice -n 5 git push origin main` (the same class
# as the `sudo -u foo` bullet above — `nice`'s option value `5` becomes the resolved command word,
# not `git`); a `git -C <other-checkout> push` into a repo whose default branch differs from the
# session's own `cwd` (this hook deliberately never reads a `-C <path>` token from the untrusted
# command string, so a second checkout is judged only against the fallback set, not its own real
# default branch). Since #268 closed the repo-local `push.default`/`remote.<name>.push` class
# named here in every prior version of this file, the residual config surface left open is: a
# GLOBAL or system git config (`$GIT_CONFIG_GLOBAL`, `~/.gitconfig`,
# `$XDG_CONFIG_HOME/git/config`, `/etc/gitconfig`) setting either key (filed as a follow-up
# alongside this change — this hook reads only the repo-local common-dir `config`);
# `include`/`includeIf` directives and `config.worktree` (`extensions.worktreeConfig`) inside that
# repo-local config, neither followed; the legacy dotted `[remote.origin]` section spelling (only
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
PREFIX_WORDS="env command builtin exec sudo nohup time nice stdbuf xargs bash sh zsh ksh dash"
GIT_GLOBAL_OPTS_WITH_VALUE="-c -C --git-dir --work-tree --namespace --config-env --exec-path"
PUSH_OPTS_WITH_VALUE="-o --push-option --repo --receive-pack --exec"
PUSH_ALL_REFS_OPTS="--all --mirror"
PUSH_DENY_STEM="trail-blazer-flow push guard:"

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
# scope for this hook", which is also what the slower checks below it would conclude.
case "$input" in
  *push*) : ;;
  *) exit 0 ;;
esac
case "$input" in
  *git*) : ;;
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
function emit_segment(seg,    ntok, toks, idx, tok, norm, saw_prefix, cmdword, j, subcmd, rest, sep) {
  ntok = split(seg, toks, /[ \t]+/)
  idx = 1
  saw_prefix = 0
  cmdword = ""
  while (idx <= ntok) {
    tok = toks[idx]
    if (tok == "") { idx++; continue }
    if (match(tok, /^[A-Za-z_][A-Za-z0-9_]*=/) == 1) { idx++; continue }
    norm = normalize(tok)
    if (norm in prefix_set) { saw_prefix = 1; idx++; continue }
    if (saw_prefix && substr(tok, 1, 1) == "-") { idx++; continue }
    cmdword = norm
    idx++
    break
  }
  if (cmdword != "git") return
  j = idx
  subcmd = ""
  while (j <= ntok) {
    tok = toks[j]
    if (tok == "") { j++; continue }
    if (tok in gopt_set) { j += 2; continue }
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
  print "PUSH\t" rest
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

dir="$resolve_cwd"
gitdir=""
depth=0
while [ "$depth" -lt 64 ]; do
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
  parent="$(dirname "$dir" 2>/dev/null || printf '%s' "$dir")"
  [ "$parent" != "$dir" ] || break
  dir="$parent"
  depth=$((depth + 1))
done

default_branch=""
current_branch=""
# #268: config-derived push routes, always initialized (even when $gitdir never resolves) so
# config_deny() below can reference them unconditionally under this script's `set -uo pipefail`.
cfg_push_lines=""
cfg_push_default=""
cfg_branch_merge=""
cfg_tab="$(printf '\t')"
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

  # #268: text-parse the common dir's config for the two push-affecting keys git itself would
  # otherwise consult on THIS push (remote.<name>.push, push.default/branch.<n>.merge) — same
  # [ -f ]-guarded builtin-redirect idiom as the two reads above; never `git config`, never a
  # second process. See this file's header "Repo resolution" paragraph for the reasoning and the
  # resulting over-blocking class, and "Documented under-blocking classes" for what this parser
  # deliberately leaves unread.
  cfgf="$common/config"
  if [ -f "$cfgf" ]; then
    # A SEPARATE carriage-return literal from $cr (declared above for the #270 command-string
    # strip): the push mutation table's M23 mutant deletes both of $cr's declaration and its
    # use, and a config parser referencing $cr here would blow up under `set -u` instead of
    # producing that mutant's documented, measured result.
    cfg_cr=$'\r'
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
              cfg_push_lines="${cfg_push_lines}${cfg_subsection}${cfg_tab}${cfg_val}"$'\n'
              ;;
          esac
          ;;
        push)
          case "$cfg_key" in
            [Dd][Ee][Ff][Aa][Uu][Ll][Tt]) cfg_push_default="$cfg_val" ;;
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
  fi
fi

deny_set="$PUSH_DEFAULT_BRANCH_FALLBACK"
[ -n "$default_branch" ] && deny_set="$deny_set $default_branch"
default_display="${default_branch:-fallback}"

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

# config_deny SCOPE_REMOTE — evaluates the #268 config-derived push routes (remote.<name>.push,
# push.default) captured by the repo-resolution parse above; on a deny, sets $__deny_dest/
# $__deny_kind ("config" or "configall")/$__deny_via the same way evaluate_segment's other checks
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
# here at all (today's current-branch check, above, is the only thing that can still deny).
config_deny() {
  local scope="$1" rec sub refspec dest
  if [ -n "$cfg_push_lines" ]; then
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      sub="${rec%%"$cfg_tab"*}"
      refspec="${rec#*"$cfg_tab"}"
      if [ -n "$scope" ] && [ "$sub" != "$scope" ]; then
        continue
      fi
      dest="$(refspec_dest "$refspec")"
      case "$dest" in
        *'*'*)
          __deny_dest="$refspec"; __deny_kind="configall"; __deny_via="remote.$sub.push"
          return
          ;;
      esac
      if [ -n "$dest" ] && is_deny_member "$dest"; then
        __deny_dest="$dest"; __deny_kind="config"; __deny_via="remote.$sub.push"
        return
      fi
    done <<CFGEOF
$cfg_push_lines
CFGEOF
  fi
  case "$cfg_push_default" in
    [Uu][Pp][Ss][Tt][Rr][Ee][Aa][Mm]|[Tt][Rr][Aa][Cc][Kk][Ii][Nn][Gg])
      dest="$(refspec_dest "$cfg_branch_merge")"
      if [ -n "$dest" ] && is_deny_member "$dest"; then
        __deny_dest="$dest"; __deny_kind="config"; __deny_via="push.default=$cfg_push_default"
      fi
      ;;
    [Mm][Aa][Tt][Cc][Hh][Ii][Nn][Gg])
      __deny_dest="$cfg_push_default"; __deny_kind="configall"; __deny_via="push.default=$cfg_push_default"
      ;;
  esac
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
while IFS= read -r line; do
  case "$line" in
    "PUSH$TAB"*) : ;;
    *) continue ;;
  esac
  seg_rest="${line#PUSH$TAB}"
  evaluate_segment "$seg_rest"
  if [ -n "$__deny_dest" ]; then
    deny_dest="$__deny_dest"
    deny_kind="$__deny_kind"
    deny_via="$__deny_via"
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
      printf '%s denies pushing to "%s" (resolves to the default branch: %s, via %s in .git/config) — open a PR from a claude/<n>-<slug> branch instead; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" "$deny_dest" "$default_display" "$deny_via" >&2
      ;;
    configall)
      printf '%s denies "%s" (pushes every matching branch, including the default branch: %s, via %s in .git/config) — open a PR from a claude/<n>-<slug> branch instead; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" "$deny_dest" "$default_display" "$deny_via" >&2
      ;;
    *)
      printf '%s denies pushing to "%s" (resolves to the default branch: %s) — open a PR from a claude/<n>-<slug> branch instead; see README.md'"'"'s Safety model\n' \
        "$PUSH_DENY_STEM" "$deny_dest" "$default_display" >&2
      ;;
  esac
  exit 2
fi

exit 0
