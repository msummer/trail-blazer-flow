#!/usr/bin/env bash
#
# governance-paths.sh — the merge floor's governance-path classifier (#331, folds in #330).
#
# Two modes:
#
#   governance-paths.sh <base-sha> <head-oid>
#     "Floor mode" — the issue-cycle merge pass's *Governance path list* read. Runs its own
#     NUL-delimited, rename-free diff between <base-sha> and <head-oid> (each a 40- or 64-char
#     lowercase hex object id — 64 for a SHA-256 repo), classifies every changed path, and prints
#     one line per path, in diff order:
#       governance: <path>   — the path is governance (see the rules below), original case
#       changed: <path>      — the path is not governance, original case
#     followed by exactly one final line, always the LAST line of stdout:
#       verdict=none          — no governance path changed
#       verdict=lessons-only  — the governance set is EXACTLY {.claude/LESSONS.md}, compared
#                                case-sensitively (a non-governance path alongside it is fine)
#       verdict=hold          — any other non-empty governance set
#       verdict=error         — see "Failure modes" below; exits non-zero, and NO governance:/
#                                changed: line is ever printed for this run (stdout is buffered
#                                until every path is classified — a forged path can't smuggle a
#                                fake verdict line in ahead of a later error)
#     Exit 0 for none/lessons-only/hold. Exit 2 for a bad-arguments error (before any git call —
#     see "Failure modes"); exit 1 for every other error.
#
#   governance-paths.sh --check <file>
#     The doctor's (bin/check-harness.sh) validation mode: parses FILE (a CLAUDE.md) for the
#     "Governance paths" section only, prints exactly one of:
#       absent            — no "Governance paths" section
#       declared <n>       — a well-formed section declaring <n> glob(s)
#       malformed <token>  — see the malformed tokens below
#     and exits 0. An unreadable FILE exits 2 (no line printed).
#
# Governance rules (README "The CLAUDE.md contract", item 10). A changed path is governance when
# EITHER of these fires (declared globs only ever ADD holds — the result is the built-in test OR
# the declared test, never a replacement):
#   - Built-in (case-insensitive, unconditional): any path segment equal to `.claude`, `.github`,
#     `adr`, or `adrs`; or a final path segment equal to `claude.md`, `action.yml`, or
#     `action.yaml`.
#   - Declared (only when the base tip's CLAUDE.md carries a well-formed "Governance paths"
#     section — see below): the path matches one of the section's declared globs.
#
# Declared globs (README item 10; ADVISORY defaults accepted for #331's approved plan):
#   - read from a section titled exactly "Governance paths" (any '#' depth) in CLAUDE.md AT THE
#     BASE TIP — never the PR head, never the working tree (a PR can't loosen the rule it's held
#     against by editing CLAUDE.md itself in the same PR);
#   - only the section's FIRST fenced code block is read; blank lines and '#'-prefixed lines
#     inside it are ignored; every other line is trimmed and is one glob;
#   - matching is case-insensitive (both the glob and the path are lower-cased first);
#   - a glob with no '/' matches the path's FINAL segment at any depth (e.g. `Jenkinsfile` also
#     catches `ci/Jenkinsfile`);
#   - a glob with a '/' matches the WHOLE repo-relative path, anchored at the repo root;
#   - a trailing '/' means "everything beneath" (`docs/policies/` becomes `docs/policies/*`);
#   - '*', '?', and '[...]' follow plain shell `case`-pattern (fnmatch) semantics — '*' crosses
#     '/', so `**` is no different from `*`;
#   - a line starting '!' (negation) or '/' or './' (a leading slash) makes the WHOLE section
#     malformed, fail-closed — a glob that would otherwise silently never match is exactly the
#     failure this script exists to prevent, not something to tolerate;
#   - no CLAUDE.md at the base tip at all ⇒ NOT an error — only the built-in rules apply;
#   - CLAUDE.md present but no "Governance paths" section ⇒ same as above (no declared globs);
#   - CLAUDE.md present with a "Governance paths" section that IS malformed ⇒ floor mode errors
#     out (verdict=error, exit 1) rather than silently falling back to "built-in only" — a
#     malformed section holds every PR until a human fixes it (see the README's item 10 and the
#     doctor's WARN, which never FAILs on this).
#
# Nothing read from CLAUDE.md is ever executed, eval'd, or expanded as anything but an unquoted
# `case` pattern (plain fnmatch matching only — no command substitution, no tilde expansion, no
# re-splitting on '|' — a `case` pattern built from an unquoted parameter expansion is matched
# literally, never re-parsed as shell syntax; confirmed live under bash 3.2). A declared glob line
# is never echoed anywhere in this script's output, including in a malformed-section error.
#
# --no-renames (moved here from skills/issue-cycle/SKILL.md, #324): a renamed governance file
# would otherwise disappear from a rename-aware `git diff --name-only` (it prints only the new
# path) and skip the OLD path it moved from; --no-renames instead prints both the old path (still
# `governance:`, since it's the change the floor must catch) and the new one, unaffected by the
# repo's own `diff.renames` config. `-z` (NUL-delimited paths, read via `read -r -d ''`) sidesteps
# `core.quotePath` entirely — no path is ever quoted/escaped, so a path is read byte-for-byte.
# `cd` to the repo toplevel before the diff neutralises `diff.relative` (confirmed live under bash
# 3.2: run from a subdirectory with `diff.relative=true`, `git diff --name-only` silently drops
# every path outside that subdirectory instead of erroring — a governance path could vanish from
# the list with no error at all; cd'ing to the toplevel first makes cwd == the diff's own root, so
# `diff.relative` has nothing left to narrow).
#
# Failure modes (floor mode), every one `verdict=error` on stdout, a one-line reason on stderr,
# and NO governance:/changed: line ever printed for that run:
#   - not exactly two arguments, or either one isn't 40 or 64 lowercase hex characters — exit 2,
#     checked BEFORE any git call (so a value like `--output=/tmp/x` can never reach `git diff`
#     and make it write an arbitrary file — option injection via a pasted argument);
#   - not inside a git repository, or the base commit doesn't exist — exit 1;
#   - the base tip's CLAUDE.md exists but can't be read as a blob — exit 1;
#   - the base tip's "Governance paths" section is malformed (see above) — exit 1, reason one of
#     `no-fence`, `unterminated-fence`, `no-globs`, `negation`, `leading-slash`;
#   - `git diff` itself fails (bad head object, or any other git error) — exit 1, quoting git's
#     own stderr;
#   - the diff prints zero paths, INCLUDING when the two arguments name the same commit — exit 1
#     (a PR that changed nothing is not a "safe to merge" verdict, it's a hold-and-investigate);
#   - any changed path contains a control character — exit 1 (a crafted path could otherwise
#     smuggle a fake `verdict=` line into this script's own stdout).
#
# Read-only: this script never writes to the repository, never stages, commits, or pushes
# anything, and never mutates CLAUDE.md or any other file it reads.
set -uo pipefail
export LC_ALL=C

# error_out MESSAGE EXIT_CODE — the one exit path for every floor-mode/--check failure: MESSAGE to
# stderr, then the single fixed line "verdict=error" to stdout (floor mode's contract: the last
# stdout line is always exactly one verdict=<token>, and an error prints no governance:/changed:
# line at all — this is the only place that prints "verdict=error", and it is the last thing this
# script ever does). --check's own unreadable-file failure exits 2 directly, without this
# function, since --check never prints a verdict= line at all.
error_out() {
  printf '%s\n' "$1" >&2
  echo "verdict=error"
  exit "$2"
}

# parse_section — reads a CLAUDE.md's full text on stdin and sets four globals: gp_state
# (absent|declared|malformed), gp_reason (a fixed token, only when malformed), gp_globs (the
# declared globs, one per line, already lower-cased) and gp_count (their number). Never echoes a
# declared line. Fence-aware, depth-aware slice: same idiom as bin/check-harness.sh's
# claude_md_section (its own header explains why: a fenced '#'-prefixed comment line is not a
# heading, and a deeper nested sub-heading doesn't end the slice, only a sibling-or-shallower one
# does), with the title fixed to "Governance paths" and reading stdin instead of a named file, so
# both floor mode (piped the base tip's blob) and --check mode (piped a file) share one parser.
parse_section() {
  local content heading_hit sec fence_status body line trimmed g lower_g n globs
  content="$(cat)"
  gp_state="absent"
  gp_reason=""
  gp_globs=""
  gp_count=0

  heading_hit="$(awk '
    $0 ~ "^#+[[:space:]]+Governance paths[[:space:]]*$" { print "found"; exit }
  ' <<<"$content")"
  [ -n "$heading_hit" ] || return 0

  sec="$(awk '
    $0 ~ "^#+[[:space:]]+Governance paths[[:space:]]*$" { inx=1; match($0, /^#+/); d=RLENGTH; next }
    inx && /^```/ { infence = !infence }
    inx && !infence && /^#+[[:space:]]/ {
      match($0, /^#+/)
      if (RLENGTH <= d) exit
    }
    inx { print }
  ' <<<"$content")"

  # Two-pass fence check: pass 1 decides whether the FIRST fence (if any) in the slice was ever
  # closed, without being thrown off by parity from an unrelated later fence line elsewhere in the
  # slice (a naive "count the ``` lines, check even/odd" test would wrongly call a well-formed
  # first block "unterminated" if any trailing prose in the same section happened to contain a
  # stray ``` of its own).
  fence_status="$(awk '
    /^```/ {
      if (opened) { status="OK"; exit }
      opened=1; next
    }
    END {
      if (status == "") { if (opened) status="UNTERMINATED"; else status="NOFENCE" }
      print status
    }
  ' <<<"$sec")"
  case "$fence_status" in
    NOFENCE) gp_state="malformed"; gp_reason="no-fence"; return 0 ;;
    UNTERMINATED) gp_state="malformed"; gp_reason="unterminated-fence"; return 0 ;;
  esac

  # Pass 2: extract only the lines strictly between the first opening fence and its matching
  # close — content after that first block (a second fenced block, trailing prose) is never read.
  body="$(awk '
    /^```/ {
      if (opened) { exit }
      opened=1; next
    }
    opened { print }
  ' <<<"$sec")"

  globs=""
  n=0
  while IFS= read -r line; do
    trimmed="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      '#'*) continue ;;
      '!'*) gp_state="malformed"; gp_reason="negation"; return 0 ;;
      /*|./*) gp_state="malformed"; gp_reason="leading-slash"; return 0 ;;
    esac
    lower_g="$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')"
    globs="${globs}${lower_g}
"
    n=$((n + 1))
  done <<<"$body"

  if [ "$n" -eq 0 ]; then
    gp_state="malformed"
    gp_reason="no-globs"
    return 0
  fi
  gp_state="declared"
  gp_globs="$globs"
  gp_count="$n"
  return 0
}

# is_builtin LP — LP is already lower-cased. The unchanged built-in rules (README item 10): any
# path segment equal to .claude, .github, adr, or adrs (matched by wrapping LP in a leading and
# trailing '/' so a segment match can never be fooled by a same-prefix neighbour like
# "adr-notes" or "my.github"), or a final segment equal to claude.md, action.yml, or action.yaml.
is_builtin() {
  local lp="$1"
  case "/$lp/" in
    */.claude/*|*/.github/*|*/adr/*|*/adrs/*) return 0 ;;
  esac
  case "${lp##*/}" in
    claude.md|action.yml|action.yaml) return 0 ;;
  esac
  return 1
}

# is_declared LP — LP is already lower-cased; reads the global gp_globs (also already lower-cased
# by parse_section). Every glob is tried unquoted as a `case` pattern only — plain fnmatch
# matching, never re-parsed as shell syntax (see this file's header). A glob with no '/' matches
# LP's final segment only, at any depth; a glob with a '/' (including one synthesized below from a
# trailing-slash glob) matches LP's whole path, anchored at the repo root.
is_declared() {
  local lp="$1" g pat
  [ -n "$gp_globs" ] || return 1
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    pat="$g"
    case "$pat" in
      */) pat="${pat%/}/*" ;;
    esac
    case "$pat" in
      */*)
        case "$lp" in
          $pat) return 0 ;;
        esac
        ;;
      *)
        case "${lp##*/}" in
          $pat) return 0 ;;
        esac
        ;;
    esac
  done <<<"$gp_globs"
  return 1
}

# is_hex S — exactly 40 or 64 lowercase hex characters (40 for SHA-1, 64 for SHA-256 — ADVISORY
# default #10 in the approved plan).
is_hex() {
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
  esac
  case "${#1}" in
    40|64) return 0 ;;
    *) return 1 ;;
  esac
}

# run_check FILE — the doctor's validation mode. An unreadable (missing, unreadable, or not a
# regular file) FILE exits 2 with no output at all — everything else exits 0 with exactly one
# line.
run_check() {
  local file="$1"
  [ -f "$file" ] && [ -r "$file" ] || exit 2
  parse_section < "$file"
  case "$gp_state" in
    absent) echo "absent" ;;
    declared) echo "declared $gp_count" ;;
    malformed) echo "malformed $gp_reason" ;;
  esac
  exit 0
}

# run_floor BASE HEAD — the merge floor's own read. See this file's header for the full stdout
# grammar and failure-mode list.
run_floor() {
  local base="$1" head="$2"
  is_hex "$base" && is_hex "$head" || \
    error_out "usage: governance-paths.sh <base-sha> <head-oid> (each exactly 40 or 64 lowercase hex characters)" 2

  local toplevel
  toplevel="$(git rev-parse --show-toplevel 2>&1)" || error_out "not inside a git repository: $toplevel" 1
  cd "$toplevel" 2>/dev/null || error_out "could not cd to the repo toplevel: $toplevel" 1

  git cat-file -e "${base}^{commit}" 2>/dev/null || error_out "base commit not found: $base" 1

  # gp_state/gp_reason/gp_globs/gp_count are globals parse_section sets — initialised here
  # unconditionally (not only inside the `if` below) so is_declared can read $gp_globs under
  # `set -u` even when the base tip has no CLAUDE.md at all (acceptance: absent ⇒ built-in rules
  # only, never an error).
  gp_state="absent"
  gp_reason=""
  gp_globs=""
  gp_count=0
  if git cat-file -e "$base:CLAUDE.md" 2>/dev/null; then
    local claude_content
    claude_content="$(git cat-file blob "$base:CLAUDE.md" 2>&1)" || \
      error_out "could not read CLAUDE.md at $base: $claude_content" 1
    parse_section <<<"$claude_content"
    if [ "$gp_state" = "malformed" ]; then
      error_out "malformed 'Governance paths' section at $base: $gp_reason" 1
    fi
  fi

  local tmp
  tmp="$(mktemp)" || error_out "mktemp failed" 1
  trap 'rm -f "$tmp"' EXIT

  local diff_err diff_rc
  diff_err="$(git diff --no-renames --name-only -z "$base" "$head" 2>&1 >"$tmp")"
  diff_rc=$?
  [ "$diff_rc" -eq 0 ] || error_out "git diff failed: $diff_err" 1

  local paths_out="" gov_paths="" total_count=0 gov_count=0 p lp is_gov
  while IFS= read -r -d '' p; do
    total_count=$((total_count + 1))
    case "$p" in
      *[[:cntrl:]]*) error_out "a changed path contains a control character" 1 ;;
    esac
    lp="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
    is_gov=false
    is_builtin "$lp" && is_gov=true
    if ! $is_gov && is_declared "$lp"; then
      is_gov=true
    fi
    if $is_gov; then
      paths_out="${paths_out}governance: ${p}
"
      gov_paths="${gov_paths}${p}
"
      gov_count=$((gov_count + 1))
    else
      paths_out="${paths_out}changed: ${p}
"
    fi
  done < "$tmp"

  [ "$total_count" -gt 0 ] || error_out "git diff printed no paths" 1

  local verdict
  if [ "$gov_count" -eq 0 ]; then
    verdict="none"
  elif [ "$gov_count" -eq 1 ] && [ "$gov_paths" = $'.claude/LESSONS.md\n' ]; then
    verdict="lessons-only"
  else
    verdict="hold"
  fi

  printf '%s' "$paths_out"
  echo "verdict=$verdict"
  exit 0
}

if [ "${1:-}" = "--check" ]; then
  [ "$#" -eq 2 ] || { echo "usage: governance-paths.sh --check <file>" >&2; exit 2; }
  run_check "$2"
fi

[ "$#" -eq 2 ] || error_out "usage: governance-paths.sh <base-sha> <head-oid>" 2
run_floor "$1" "$2"
