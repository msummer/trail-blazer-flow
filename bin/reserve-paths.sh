#!/usr/bin/env bash
#
# reserve-paths.sh — the Autonomy reserve's mechanical path matcher (#552).
#
# Two modes:
#
#   reserve-paths.sh <base-sha> <head-oid>
#     "Diff mode" — what the implementer orchestrator runs before every verifier dispatch. <base-sha>
#     is `git merge-base <default-branch> HEAD`, <head-oid> is the recorded HEAD (each a 40- or
#     64-char lowercase hex object id — 64 for a SHA-256 repo). Reads the "Autonomy reserve" section
#     of CLAUDE.md AT <base-sha>, runs its own NUL-delimited, rename-free diff between the two, and
#     prints one line per reserved path, in diff order:
#       reserved: <path>   — a changed path, original case, that a reserve glob matches
#     followed by exactly one final line, always the LAST line of stdout:
#       verdict=reserved   — at least one reserved: line was printed
#       verdict=none       — nothing that changed is reserved (an empty diff included)
#       verdict=absent     — the base tree has no CLAUDE.md entry at all, or its CLAUDE.md has no
#                            "Autonomy reserve" section: the reserve is not declared, the verifier's
#                            reserve check is inert; nothing else is printed and the diff is not run
#       verdict=error      — see "Failure modes"; no reserved: line is ever printed for this run
#                            (stdout is buffered until every path is matched, so a forged path
#                            cannot smuggle a fake verdict line in ahead of a later error)
#     Exit 0 for reserved/none/absent. Exit 2 for a bad-arguments error (before any git call); exit
#     1 for every other error.
#
#   reserve-paths.sh --check <file>
#     The doctor's (bin/check-harness.sh) mode: parses FILE (a CLAUDE.md) for the section only, and
#     lists the repo's tracked schema paths (`git ls-files`, from the toplevel). FILE is read through
#     the filesystem, so a symlink is followed as the operating system follows it. Prints, and exits
#     0:
#       line 1:  absent             — no "Autonomy reserve" section
#                declared <n> <m>   — a well-formed section: <n> reserve globs, <m> `not reserved:`
#                                     lines
#                malformed <token>  — token is no-fence, unterminated-fence or no-globs; or
#                                     `unreadable-glob <entry>` (the first unreadable entry, every
#                                     non-printable byte shown as `?`); nothing else is printed
#       then, unless line 1 is malformed, one line per tracked path a built-in schema glob matches:
#                (nothing)               — a reserve glob covers it
#                acknowledged: <path>    — only a `not reserved:` glob covers it
#                schema: <path>          — nothing covers it
#     The built-in schema globs are `migrations`, `alembic/versions`, `prisma/schema.prisma` and
#     `*.sql`, matched with the dialect below. A control byte in a printed path is shown as `?`.
#     An unreadable FILE (missing, unreadable, not a regular file) exits 2 with no output; a git
#     failure, or a section that could not be parsed at all, exits 1 with no stdout and a one-line
#     reason on stderr.
#
# The section (docs/reference/claude-md-contract.md, item 7): a heading titled exactly "Autonomy
# reserve" at any '#' depth, read depth-aware (a deeper sub-heading does not end it, a sibling-or-
# shallower one does). Only the section's FIRST fenced block is read; blank lines and '#'-prefixed
# lines in it are skipped; every other line is trimmed and is one entry. An entry that starts with
# exactly `not reserved:` is an acknowledgment, its rest (trimmed) a glob that --check uses to stay
# quiet about a schema path on purpose (it never makes a path reserved, and diff mode ignores it);
# every other entry is a reserve glob. Prose in the section and any later fenced block are ignored.
#
# The dialect. Deliberately broad, so it never reserves less than any plausible prose reading of a
# list of paths:
#   - matching ignores case (the glob and the path are lower-cased first);
#   - a glob matches from the start of ANY path segment to the end of a segment, at any depth: it
#     is unanchored, so `migrations/**` reserves `db/migrations/0001.sql` and `CLAUDE.md` reserves
#     `pkg/sub/Claude.md`, but `docs/adr` does not reserve `docs/adr-notes/x.md`;
#   - `*` matches any run of characters, '/' included, the empty run too (`.env*` reserves `.env`);
#   - a match covers everything beneath it: one trailing '/', then one trailing `/**`, then one
#     leading `**/` are dropped, so `docs/adr/`, `docs/adr/**` and `**/docs/adr` all mean `docs/adr`;
#   - '[' and ']' are literal, never a character class, but only in a route-parameter group:
#     `[name]`, `[...name]`, `[[name]]` or `[[...name]]` with name = [A-Za-z_][A-Za-z0-9_]* — so
#     `app/api/[...slug]/` reserves `app/api/[...slug]/route.ts` and `pages/[id].tsx` reserves
#     exactly that file;
#   - --no-renames applies: a rename out of a reserved directory reports the old path.
# An entry outside that dialect is UNREADABLE, and an unreadable entry makes the whole section
# malformed (fail closed — a glob that quietly stops matching is exactly the failure this script
# exists to prevent). Unreadable means any of:
#   - a character outside letters, digits and . _ - / * @ + ( ) [ ] $ (so a space, ?, {, }, \, !,
#     #, a backtick, a control byte and any non-ASCII byte);
#   - a '[' or ']' outside a route-parameter group (`[0-9]`, `[a-z]`, `[!x]`, `[12]`);
#   - a `**` left after the leading `**/` and trailing `/**` are dropped (`src/**/schema.sql`);
#   - an empty, `.` or `..` segment after that normalisation (a leading '/' or `./`, `//`, `..`).
# A `not reserved:` entry follows the same rules; its reported entry is the whole line.
#
# Reading only at the base is deliberate: a PR cannot loosen the rule it is checked against by
# editing CLAUDE.md in the same PR. The base is read from its TREE, not by path: the tree entry
# named exactly CLAUDE.md decides what is read.
#   - A plain file (mode 100644 or 100755) is read as it is.
#   - A symlink (mode 120000, e.g. CLAUDE.md -> AGENTS.md) is followed exactly ONE hop, inside the
#     base tree: its text, after any leading `./` segments are dropped, must be a plain relative
#     path (no leading '/', no empty, `.` or `..` segment, no control character) naming a plain
#     file of that same tree, which is then read. A link that is absolute, escapes, is missing,
#     names another symlink, a symlinked directory or a directory is an error, never `absent`.
#     bin/governance-paths.sh reads its CLAUDE.md the same way, so the two stay identical by hand.
#   - No entry named exactly CLAUDE.md (a file tracked as claude.md is not read), or an entry that
#     is not a file or a symlink, is `absent` and an error respectively.
#
# --no-renames, `-z` and the `cd` to the toplevel carry the same reasons as in
# bin/governance-paths.sh: a rename-aware diff would drop the old path, `-z` reads each path
# byte-for-byte, and a diff.relative setting in a subdirectory would narrow the list silently.
#
# Failure modes (diff mode), every one `verdict=error` on stdout, a one-line reason on stderr (after
# the tool's own message when awk, sed or tr cannot run at all; the
# first line of git's own message when one is quoted), and NO reserved: line ever printed for that
# run:
#   - not exactly two arguments, or either one is not 40 or 64 lowercase hex characters — exit 2,
#     checked BEFORE any git call (so a value like `--output=/tmp/x` can never reach `git diff` and
#     make it write an arbitrary file);
#   - not inside a git repository, or the base commit does not exist — exit 1;
#   - the base CLAUDE.md entry cannot be listed or read, is not a file or a symlink, or is a
#     symlink the one-hop rule above rejects — exit 1;
#   - the base section is malformed (see above), reason and entry on stderr — exit 1;
#   - the section could not be parsed at all (a helper such as awk, sed or tr failed to run): the
#     parse state starts as an error and only a completed parse replaces it, so this is never
#     `absent` — exit 1;
#   - `git diff` itself fails (a missing head object, or any other git error) — exit 1;
#   - any changed path contains a control character (an embedded newline included) — exit 1.
#
# Nothing read from CLAUDE.md or from a diff is executed, expanded, or built into program text:
# globs reach the one awk matcher through the environment and meet a path only through index().
#
# Read-only: the only git calls are `git rev-parse`, `git cat-file`, `git diff` and `git ls-files`.
# No temp file is written and nothing is created, moved, deleted or staged. The script holds no
# here-string and no here-document, because bash 3.2 writes each of those to a temp file in the
# temp directory, and a write denied there would fail the redirect; every value moves through a
# pipe, a command substitution or a function argument instead.
#
# Honest limits: only the first fenced block is read; the heading search is not fence-aware (the
# same as bin/governance-paths.sh); only the first unreadable entry is reported; --check reads the
# working-tree file through the filesystem, so on a symlink (or, on a case-insensitive filesystem,
# a file tracked as claude.md) it can differ from diff mode's exact-name read of the base tree, and
# so can report a section as declared for a symlink diff mode rejects; and two hand-made link texts
# are misread rather than refused: one ending in a newline (a command substitution strips it) and
# one equal to git's quoted form of another tree name (the listing is matched as printed).
set -uo pipefail
export LC_ALL=C

NL=$'\n'
TAB=$'\t'

# error_out MESSAGE EXIT_CODE — the one exit path for every diff-mode failure: MESSAGE to stderr,
# then the single fixed line "verdict=error" to stdout, then exit.
error_out() {
  printf '%s\n' "$1" >&2
  echo "verdict=error"
  exit "$2"
}

# check_fail MESSAGE EXIT_CODE — --check's failure path: MESSAGE to stderr, nothing on stdout.
check_fail() {
  printf '%s\n' "$1" >&2
  exit "$2"
}

# The built-in schema globs --check lists (already in normalised, lower-case form).
RS_SCHEMA_GLOBS='migrations
alembic/versions
prisma/schema.prisma
*.sql'

# The characters an entry may hold, as one case pattern matching any byte OUTSIDE the set. ']' first
# in the bracket expression is a literal ']'; '-' last is a literal '-'.
RS_BAD_CHARS='*[!]A-Za-z0-9._/@+*()[$-]*'

# The one matcher, used by both modes. Globs arrive through the environment (RES_GLOBS, RES_ACKS,
# RES_SCHEMA — newline-separated, already normalised and lower-case); paths arrive on stdin, one
# per line. hit() splits the glob at '*' and finds the pieces in order with index(), so no regular
# expression is ever built from an entry or a path. Both sides are wrapped in '/' so a piece can
# only start and end on a segment boundary or at a '*'.
RES_AWK='
function hit(p, g,   s, k, piece) {
  s = "/" p "/"
  g = "/" g "/"
  while (g != "") {
    k = index(g, "*")
    if (k) { piece = substr(g, 1, k - 1); g = substr(g, k + 1) } else { piece = g; g = "" }
    if (piece == "") continue
    k = index(s, piece)
    if (!k) return 0
    s = substr(s, k + length(piece))
  }
  return 1
}
function any(p, arr, n,   i) {
  for (i = 1; i <= n; i++) if (arr[i] != "" && hit(p, arr[i])) return 1
  return 0
}
BEGIN {
  mode = ENVIRON["RES_MODE"]
  ng = split(ENVIRON["RES_GLOBS"], G, "\n")
  na = split(ENVIRON["RES_ACKS"], A, "\n")
  nsch = split(ENVIRON["RES_SCHEMA"], S, "\n")
}
{
  if ($0 == "") next
  lp = tolower($0)
  if (mode == "diff") {
    if (any(lp, G, ng)) print "reserved: " $0
    next
  }
  if (!any(lp, S, nsch)) next
  if (any(lp, G, ng)) next
  if (any(lp, A, na)) print "acknowledged: " $0
  else print "schema: " $0
}
'

# trim_into S — sets rs_t to S without leading and trailing whitespace.
trim_into() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  rs_t="$s"
}

# norm_glob G — G is one trimmed glob. Returns 0 and sets rs_norm to its normalised, lower-cased
# form, 1 when the glob is unreadable (see the dialect in this file's header), or 2 when a helper
# (sed, tr) failed to run, so the glob could not be judged.
norm_glob() {
  local g="$1" rest
  case "$g" in
    $RS_BAD_CHARS) return 1 ;;
  esac
  case "$g" in
    *'['*|*']'*)
      rest="$(printf '%s\n' "$g" | sed -E \
        -e 's/\[\[\.\.\.[A-Za-z_][A-Za-z0-9_]*\]\]//g' \
        -e 's/\[\[[A-Za-z_][A-Za-z0-9_]*\]\]//g' \
        -e 's/\[\.\.\.[A-Za-z_][A-Za-z0-9_]*\]//g' \
        -e 's/\[[A-Za-z_][A-Za-z0-9_]*\]//g')" || return 2
      case "$rest" in
        *'['*|*']'*) return 1 ;;
      esac
      ;;
  esac
  case "$g" in
    */) g="${g%/}" ;;
  esac
  case "$g" in
    */'**') g="${g%'/**'}" ;;
  esac
  case "$g" in
    '**/'*) g="${g#'**/'}" ;;
  esac
  case "$g" in
    *'**'*) return 1 ;;
  esac
  [ -n "$g" ] || return 1
  case "/$g/" in
    *//*|*/./*|*/../*) return 1 ;;
  esac
  rs_norm="$(printf '%s' "$g" | tr '[:upper:]' '[:lower:]')" || return 2
  [ -n "$rs_norm" ] || return 2
  return 0
}

# parse_section TEXT — parses a CLAUDE.md's full text (an argument, never stdin) and sets these
# globals: rs_state (absent|declared|malformed|error), rs_token (a fixed token, only when
# malformed), rs_entry (the first unreadable entry with every non-printable byte shown as `?`, only
# for unreadable-glob), rs_globs and rs_acks (the normalised reserve globs and acknowledgment globs,
# one per line), rs_nglobs and rs_nacks (their numbers). rs_state starts as `error` and only a
# completed parse replaces it, so a helper that failed to run can never read as `absent`. Fence-
# aware, depth-aware slice: the same idiom as bin/governance-paths.sh's parse_section, with the
# title fixed to "Autonomy reserve". Each awk reads its whole input (no early exit), so no writer
# is ever cut off by a closed pipe and every capture's status can be trusted.
parse_section() {
  local content="$1" heading_hit sec fence_status body rest line g is_ack nrc
  rs_state="error"
  rs_token=""
  rs_entry=""
  rs_globs=""
  rs_acks=""
  rs_nglobs=0
  rs_nacks=0

  heading_hit="$(printf '%s\n' "$content" | awk '
    $0 ~ "^#+[[:space:]]+Autonomy reserve[[:space:]]*$" { found = 1 }
    END { if (found) print "found"; else print "none" }
  ')" || return 0
  case "$heading_hit" in
    none) rs_state="absent"; return 0 ;;
    found) : ;;
    *) return 0 ;;
  esac

  sec="$(printf '%s\n' "$content" | awk '
    !done && $0 ~ "^#+[[:space:]]+Autonomy reserve[[:space:]]*$" { inx=1; match($0, /^#+/); d=RLENGTH; next }
    inx && !done && /^```/ { infence = !infence }
    inx && !done && !infence && /^#+[[:space:]]/ {
      match($0, /^#+/)
      if (RLENGTH <= d) done = 1
    }
    inx && !done { print }
  ')" || return 0

  # Two-pass fence check, as in bin/governance-paths.sh: pass 1 decides whether the FIRST fence in
  # the slice was ever closed, unmoved by a stray fence line later in the section.
  fence_status="$(printf '%s\n' "$sec" | awk '
    /^```/ {
      if (status == "") { if (opened) status = "OK"; else opened = 1 }
      next
    }
    END {
      if (status == "") { if (opened) status = "UNTERMINATED"; else status = "NOFENCE" }
      print status
    }
  ')" || return 0
  case "$fence_status" in
    NOFENCE) rs_state="malformed"; rs_token="no-fence"; return 0 ;;
    UNTERMINATED) rs_state="malformed"; rs_token="unterminated-fence"; return 0 ;;
    OK) : ;;
    *) return 0 ;;
  esac

  # Pass 2: only the lines strictly between the first opening fence and its matching close.
  body="$(printf '%s\n' "$sec" | awk '
    /^```/ {
      if (opened) closed = 1; else opened = 1
      next
    }
    opened && !closed { print }
  ')" || return 0

  rest="$body"
  while [ -n "$rest" ]; do
    case "$rest" in
      *"$NL"*) line="${rest%%"$NL"*}"; rest="${rest#*"$NL"}" ;;
      *) line="$rest"; rest="" ;;
    esac
    trim_into "$line"
    line="$rs_t"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    g="$line"
    is_ack=false
    case "$line" in
      'not reserved:'*) is_ack=true; trim_into "${line#"not reserved:"}"; g="$rs_t" ;;
    esac
    norm_glob "$g"
    nrc=$?
    if [ "$nrc" -eq 1 ]; then
      rs_state="malformed"
      rs_token="unreadable-glob"
      rs_entry="$(printf '%s' "$line" | tr -c '[:print:]' '?')"
      return 0
    elif [ "$nrc" -ne 0 ]; then
      return 0
    fi
    if $is_ack; then
      rs_acks="${rs_acks}${rs_norm}
"
      rs_nacks=$((rs_nacks + 1))
    else
      rs_globs="${rs_globs}${rs_norm}
"
      rs_nglobs=$((rs_nglobs + 1))
    fi
  done

  if [ $((rs_nglobs + rs_nacks)) -eq 0 ]; then
    rs_state="malformed"
    rs_token="no-globs"
    return 0
  fi
  rs_state="declared"
  return 0
}

# is_hex S — exactly 40 or 64 lowercase hex characters (40 for SHA-1, 64 for SHA-256).
is_hex() {
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
  esac
  case "${#1}" in
    40|64) return 0 ;;
    *) return 1 ;;
  esac
}

# tree_entry TREEISH NAME — lists the tree TREEISH (`git cat-file -p`) and sets te_found (yes|no)
# and, for the entry named exactly NAME, te_mode, te_type and te_sha. Returns 1 when the listing
# itself fails. A name git quotes in the listing is matched in its quoted form, so it equals a NAME
# only when NAME is that quoted text.
tree_entry() {
  local listing rest line meta name tail
  te_found="no"
  te_mode=""
  te_type=""
  te_sha=""
  listing="$(git cat-file -p "$1" 2>/dev/null)" || return 1
  rest="$listing"
  while [ -n "$rest" ]; do
    case "$rest" in
      *"$NL"*) line="${rest%%"$NL"*}"; rest="${rest#*"$NL"}" ;;
      *) line="$rest"; rest="" ;;
    esac
    case "$line" in
      *"$TAB"*) : ;;
      *) continue ;;
    esac
    meta="${line%%"$TAB"*}"
    name="${line#*"$TAB"}"
    [ "$name" = "$2" ] || continue
    te_mode="${meta%% *}"
    tail="${meta#* }"
    te_type="${tail%% *}"
    te_sha="${tail#* }"
    te_found="yes"
    return 0
  done
  return 0
}

# read_claude_md_at_base — sets claude_content to the text of the CLAUDE.md the base tree names, or
# leaves claude_found=no when the tree has no entry named exactly CLAUDE.md. Follows a symlink ONE
# hop, inside the base tree (see this file's header); every other shape is an error_out.
read_claude_md_at_base() {
  local src_sha target shown reason dir file treeish ty
  claude_found="no"
  claude_content=""
  tree_entry "${base}^{tree}" "CLAUDE.md" || \
    error_out "could not list the tree of $base" 1
  [ "$te_found" = "yes" ] || return 0
  case "$te_mode" in
    100644|100755)
      src_sha="$te_sha"
      ;;
    120000)
      target="$(git cat-file blob "$te_sha" 2>/dev/null)" || \
        error_out "CLAUDE.md at $base is a symlink whose text could not be read" 1
      shown="$(printf '%s' "$target" | tr -c '[:print:]' '?')"
      reason=""
      case "$target" in
        "") reason="is empty" ;;
        /*) reason="is an absolute path" ;;
        *[[:cntrl:]]*) reason="holds a control character" ;;
      esac
      if [ -z "$reason" ]; then
        while :; do
          case "$target" in
            ./*) target="${target#./}" ;;
            *) break ;;
          esac
        done
        case "/$target/" in
          *//*|*/./*|*/../*) reason="is not a plain relative path (it has an empty, . or .. segment)" ;;
        esac
      fi
      [ -z "$reason" ] || \
        error_out "CLAUDE.md at $base is a symlink to '$shown' that $reason" 1
      case "$target" in
        */*) dir="${target%/*}"; file="${target##*/}"; treeish="$base:$dir" ;;
        *) dir=""; file="$target"; treeish="${base}^{tree}" ;;
      esac
      if [ -n "$dir" ]; then
        ty="$(git cat-file -t "$treeish" 2>/dev/null)" || ty=""
        [ "$ty" = "tree" ] || \
          error_out "CLAUDE.md at $base is a symlink to '$shown' whose directory is missing from that tree" 1
      fi
      tree_entry "$treeish" "$file" || \
        error_out "CLAUDE.md at $base is a symlink to '$shown' whose directory could not be listed" 1
      [ "$te_found" = "yes" ] || \
        error_out "CLAUDE.md at $base is a symlink to '$shown' that points at a missing file" 1
      case "$te_mode" in
        100644|100755) src_sha="$te_sha" ;;
        120000) error_out "CLAUDE.md at $base is a symlink to '$shown' that points at another symlink" 1 ;;
        *) error_out "CLAUDE.md at $base is a symlink to '$shown' that does not point at a file" 1 ;;
      esac
      ;;
    *)
      error_out "CLAUDE.md at $base is neither a file nor a symlink (mode $te_mode)" 1
      ;;
  esac
  claude_content="$(git cat-file blob "$src_sha" 2>/dev/null)" || \
    error_out "could not read CLAUDE.md at $base" 1
  claude_found="yes"
  return 0
}

# run_check FILE — the doctor's mode. See this file's header for the stdout grammar.
run_check() {
  local file="$1" content
  [ -f "$file" ] && [ -r "$file" ] || exit 2
  content="$(cat "$file")" || exit 2
  parse_section "$content"
  case "$rs_state" in
    malformed)
      echo "malformed $rs_token${rs_entry:+ $rs_entry}"
      exit 0
      ;;
    absent|declared) : ;;
    *) check_fail "could not parse the 'Autonomy reserve' section of the file" 1 ;;
  esac

  local toplevel paths hits
  toplevel="$(git rev-parse --show-toplevel 2>&1)" || \
    check_fail "not inside a git repository: ${toplevel%%"$NL"*}" 1
  cd "$toplevel" 2>/dev/null || check_fail "could not cd to the repo toplevel" 1

  # NUL separators become newlines and an embedded newline becomes \001, so the whole list fits in
  # a variable without a temp file; the second tr shows every other control byte as `?`.
  if ! paths="$(git ls-files -z 2>/dev/null | tr '\000\n' '\n\001' | tr '\001-\011\013-\037\177' '?')"; then
    check_fail "git ls-files failed" 1
  fi
  hits=""
  if [ -n "$paths" ]; then
    hits="$(printf '%s\n' "$paths" | RES_MODE=check RES_GLOBS="$rs_globs" RES_ACKS="$rs_acks" \
      RES_SCHEMA="$RS_SCHEMA_GLOBS" awk "$RES_AWK")" || check_fail "the path matcher failed" 1
  fi

  if [ "$rs_state" = "absent" ]; then
    echo "absent"
  else
    echo "declared $rs_nglobs $rs_nacks"
  fi
  [ -z "$hits" ] || printf '%s\n' "$hits"
  exit 0
}

# run_diff BASE HEAD — the orchestrator's mode. See this file's header for the stdout grammar and
# the failure-mode list.
run_diff() {
  base="$1"
  local head="$2"
  is_hex "$base" && is_hex "$head" || \
    error_out "usage: reserve-paths.sh <base-sha> <head-oid> (each exactly 40 or 64 lowercase hex characters)" 2

  local toplevel
  toplevel="$(git rev-parse --show-toplevel 2>&1)" || \
    error_out "not inside a git repository: ${toplevel%%"$NL"*}" 1
  cd "$toplevel" 2>/dev/null || error_out "could not cd to the repo toplevel" 1

  git cat-file -e "${base}^{commit}" 2>/dev/null || error_out "base commit not found: $base" 1

  # The state is an error until something below says otherwise: only a base tree with no CLAUDE.md
  # entry at all sets `absent`, only a completed parse sets `declared`.
  rs_state="error"
  rs_token=""
  rs_entry=""
  rs_globs=""
  rs_acks=""
  rs_nglobs=0
  rs_nacks=0
  read_claude_md_at_base
  if [ "$claude_found" = "no" ]; then
    rs_state="absent"
  else
    parse_section "$claude_content"
  fi
  case "$rs_state" in
    absent)
      echo "verdict=absent"
      exit 0
      ;;
    declared) : ;;
    malformed)
      error_out "malformed 'Autonomy reserve' section at $base: $rs_token${rs_entry:+: $rs_entry}" 1
      ;;
    *)
      error_out "could not parse the 'Autonomy reserve' section at $base" 1
      ;;
  esac

  # NUL separators become newlines and an embedded newline becomes \001, so the whole list fits in
  # a variable without a temp file. A failed diff is the assignment's own status (pipefail); the
  # diff then runs once more, for its stderr only, to quote its first line.
  local paths hits diff_err noctl
  if ! paths="$(git diff --no-renames --name-only -z "$base" "$head" 2>/dev/null | tr '\000\n' '\n\001')"; then
    diff_err="$(git diff --no-renames --name-only -z "$base" "$head" 2>&1 >/dev/null)"
    error_out "git diff failed: ${diff_err%%"$NL"*}" 1
  fi

  # A control byte anywhere but the separating newline: delete every one and compare the lengths (a
  # pattern substitution over the whole list is quadratic in bash 3.2).
  noctl="$(printf '%s' "$paths" | tr -d '\001-\011\013-\037\177')"
  [ "${#noctl}" -eq "${#paths}" ] || error_out "a changed path contains a control character" 1

  hits=""
  if [ -n "$paths" ]; then
    hits="$(printf '%s\n' "$paths" | RES_MODE=diff RES_GLOBS="$rs_globs" awk "$RES_AWK")" || \
      error_out "the path matcher failed" 1
  fi

  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    echo "verdict=reserved"
  else
    echo "verdict=none"
  fi
  exit 0
}

if [ "${1:-}" = "--check" ]; then
  [ "$#" -eq 2 ] || { echo "usage: reserve-paths.sh --check <file>" >&2; exit 2; }
  run_check "$2"
fi

[ "$#" -eq 2 ] || error_out "usage: reserve-paths.sh <base-sha> <head-oid>" 2
run_diff "$1" "$2"
