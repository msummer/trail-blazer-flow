#!/usr/bin/env bash
#
# changelog-merge.sh — settles the one conflict full auto's parallel lanes share, an append-only
# changelog section, by building a merge-from-base commit with git plumbing (#631).
#
# Two modes:
#
#   changelog-merge.sh --declared
#     Reads the "Append-only changelog" section of the CLAUDE.md in HEAD's tree and prints:
#       changelog=absent                     — no CLAUDE.md entry, or no such section (exit 0)
#       changelog=declared / file=<path> / section=<heading>
#                                            — a well-formed section (exit 0)
#       changelog=malformed / reason=<token> — a malformed section (exit 1)
#     Not inside a git repository, an unreadable HEAD, or any argument after --declared: a stderr
#     message only, exit 2. Full auto's wave planning runs this once to drop the declared file from
#     the overlap test.
#
#   changelog-merge.sh <base-tip> <head-oid> <head-branch>
#     <base-tip> is the default branch's tip and <head-oid> the PR's head (each 40 or 64 lowercase
#     hex characters; both as the merge floor prints base-tip= and head-oid=), <head-branch> the PR's
#     head branch (`claude/<digits>-<rest>`). Builds a new commit whose first parent is <head-oid>
#     and whose second is <base-tip>, and prints it for the caller to push. Stdout is written only once
#     the result is known, and its LAST line is always the verdict:
#       file=<path>                          \
#       resolved=rebuilt|not-shared           |  only with verdict=updated, in this order
#       base-tip=<oid> / old-head=<oid>       |
#       new-head=<oid>                        |
#       verdict=updated                      /   exit 0
#       verdict=absent                       — the base tip declares no changelog; nothing is built
#                                              (exit 0)
#       [overlap: <path> ...] reason=<token> verdict=hold
#                                            — the conflict is not one this script settles (exit 1)
#       verdict=error                        — bad arguments or a missing commit; stderr has the
#                                              reason (exit 2)
#     Any other exit status is a crash, which a caller treats as a hold.
#
# The declaration (docs/reference/claude-md-contract.md, item 12): a heading titled exactly
# "Append-only changelog" at any '#' depth, read fence-aware and depth-aware; in its FIRST fenced
# block, blank and '#'-prefixed lines are skipped and every other line must be `file: <path>` or
# `section: <heading>`, each exactly once. The heading is the full Markdown heading line the
# changelog's section starts with (for example `## Unreleased`). Malformed tokens: no-fence,
# unknown-key, no-file, multiple-files, bad-file, no-section, multiple-sections, bad-section and
# claude-md-not-a-file (an entry named CLAUDE.md that is not a plain file, a symlink included).
# Merge mode reads the declaration from the BASE TIP's tree only, so a lane that adds, edits or
# removes the section cannot change what is settled.
#
# Merge-mode algorithm (every refusal is a hold with a named reason):
#   1. Validate the three arguments before any git call; then both commits must exist.
#   2. `refs/remotes/origin/<head-branch>` must exist and equal <head-oid> (no-remote-branch,
#      head-moved).
#   3. The base tip's declaration must be declared (absent -> verdict=absent; malformed -> hold).
#   4. `git merge-base --all <base-tip> <head-oid>` must print exactly one commit M
#      (no-single-merge-base).
#   5. A path changed by BOTH sides since M (rename-free, NUL-delimited diffs, submodule paths
#      included whatever the repo's ignore settings), other than the declared file, is an overlap
#      (overlap), and so is a path on one side that is a leading directory of a path on the other; a
#      path holding a control character, newline included, is refused (control-char-path).
#   6. If both sides changed the declared file F, it is rebuilt: F must be a plain file in M, the
#      head and the base tip (changelog-not-a-file), none holding a NUL byte (binary-file) and each
#      ending in a newline (no-final-newline),
#      the section heading must occur exactly once in each (section-missing, section-repeated), and
#      the section runs from its heading to the next heading of the same or a shallower depth.
#      The lane must have changed nothing outside the section (outside-section) and only inserted
#      one contiguous block of lines into it (not-an-insertion); the block must sit at the top or
#      the bottom edge, where an edge is the section's body ignoring blank lines (mid-section). The
#      result is the base tip's F with that block inserted at the same edge of the base's section.
#   7. The new tree is the base tip's tree, plus every path the lane changed at the head's version
#      (deletions included), plus the rebuilt F; built in a temporary index, never the repo's own.
#      Before the commit, the new tree must differ from the base tip only in lane-changed paths and
#      from the head only in base-changed paths, the declared file excepted (tree-check).
#      The commit message is `Merge <base-tip> into <head-branch> (changelog-merge.sh)`.
#
# What it writes: git objects only (`hash-object -w`, `write-tree`, `commit-tree`) and a temporary
# directory it removes on exit. No ref, no working-tree file and not the repo's own index is
# touched. A commit identity that git cannot detect falls back to `changelog-merge.sh` /
# `changelog-merge@localhost.invalid`. Nothing read from CLAUDE.md or a diff is executed or built
# into program text: the section heading reaches awk through the environment.
#
# Honest limits: only a single contiguous insertion at the top or bottom edge is settled; the
# section end search is not fence-aware; a symlinked CLAUDE.md holds instead of being followed; a
# heading inside a fenced block of the changelog counts as a heading.
set -uo pipefail
export LC_ALL=C

NL=$'\n'
TAB=$'\t'

# is_hex S — exactly 40 or 64 lowercase hex characters.
is_hex() {
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
  esac
  case "${#1}" in
    40|64) return 0 ;;
    *) return 1 ;;
  esac
}

# valid_branch S — `claude/<digits>-<rest>`, <rest> only [A-Za-z0-9._/-], no `..`, `//` or `/.`, and
# not ending in `/`, `.` or `.lock`.
valid_branch() {
  local b digits after rest
  case "$1" in
    claude/*) b="${1#claude/}" ;;
    *) return 1 ;;
  esac
  digits="${b%%[!0-9]*}"
  [ -n "$digits" ] || return 1
  after="${b#"$digits"}"
  case "$after" in
    -?*) rest="${after#-}" ;;
    *) return 1 ;;
  esac
  case "$rest" in
    *[!A-Za-z0-9._/-]*) return 1 ;;
    *..*|*//*|*/.*|*.lock/*|*/|*.|*.lock) return 1 ;;
  esac
  return 0
}

# error_out MESSAGE — merge mode's bad-arguments path: stderr, the fixed verdict, exit 2.
error_out() {
  printf '%s\n' "$1" >&2
  echo "verdict=error"
  exit 2
}

# hold REASON [LINE...] — merge mode's refusal: the extra lines, then the reason and the verdict.
hold() {
  local reason="$1"
  shift
  local l
  for l in "$@"; do
    printf '%s\n' "$l"
  done
  printf 'reason=%s\n' "$reason"
  echo "verdict=hold"
  exit 1
}

# trim_into S — sets cd_t to S without leading and trailing whitespace.
trim_into() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  cd_t="$s"
}

# The section slice: prints SECTION when the heading is found, then FENCE and one `L:<line>` per
# line of the section's first fenced block when that block is closed. Fence-aware and depth-aware.
# Every input line is read (no early exit), so no writer is cut off by a closed pipe.
CD_AWK='
{
  sub(/\r$/, "")
  if (!inx) {
    if ($0 ~ /^```/) { tf = !tf; next }
    if (!tf && $0 ~ "^#+[ \t]+Append-only changelog[ \t]*$") { found = 1; inx = 1; match($0, /^#+/); d = RLENGTH }
    next
  }
  if (done) next
  if ($0 ~ /^```/) {
    if (!infence) { infence = 1; if (!opened) { opened = 1; next } }
    else { infence = 0; if (opened && !closed) { closed = 1; next } }
  } else if (!infence && $0 ~ /^#+[ \t]/) {
    match($0, /^#+/)
    if (RLENGTH <= d) { done = 1; next }
  }
  if (opened && !closed) { nb++; body[nb] = $0 }
}
END {
  if (found) print "SECTION"
  if (found && closed) { print "FENCE"; for (i = 1; i <= nb; i++) print "L:" body[i] }
}
'

# parse_decl TEXT — parses a CLAUDE.md's text and sets cd_state (absent|declared|malformed|error),
# cd_token (only when malformed), cd_file and cd_section. The state starts as `error` and only a
# completed parse replaces it, so a helper that failed to run can never read as `absent`.
parse_decl() {
  local content="$1" slice rest line v key nfile=0 nsec=0 unknown=0 h n text
  cd_state="error"
  cd_token=""
  cd_file=""
  cd_section=""
  slice="$(printf '%s\n' "$content" | awk "$CD_AWK")" || return 0
  case "$slice" in
    "") cd_state="absent"; return 0 ;;
    SECTION) cd_state="malformed"; cd_token="no-fence"; return 0 ;;
    SECTION"$NL"FENCE*) : ;;
    *) return 0 ;;
  esac
  rest="${slice#SECTION"$NL"FENCE}"
  while [ -n "$rest" ]; do
    rest="${rest#"$NL"}"
    case "$rest" in
      *"$NL"*) line="${rest%%"$NL"*}"; rest="${rest#*"$NL"}" ;;
      *) line="$rest"; rest="" ;;
    esac
    line="${line#L:}"
    trim_into "$line"
    v="$cd_t"
    case "$v" in
      ""|"#"*) continue ;;
      file:*) key="file"; trim_into "${v#file:}" ;;
      section:*) key="section"; trim_into "${v#section:}" ;;
      *) unknown=1; continue ;;
    esac
    if [ "$key" = "file" ]; then
      nfile=$((nfile + 1))
      cd_file="$cd_t"
    else
      nsec=$((nsec + 1))
      cd_section="$cd_t"
    fi
  done
  cd_state="malformed"
  if [ "$unknown" -eq 1 ]; then cd_token="unknown-key"; return 0; fi
  if [ "$nfile" -eq 0 ]; then cd_token="no-file"; return 0; fi
  if [ "$nfile" -gt 1 ]; then cd_token="multiple-files"; return 0; fi
  if [ "$nsec" -eq 0 ]; then cd_token="no-section"; return 0; fi
  if [ "$nsec" -gt 1 ]; then cd_token="multiple-sections"; return 0; fi
  case "$cd_file" in
    ""|*[!A-Za-z0-9._/-]*) cd_token="bad-file"; return 0 ;;
  esac
  case "/$cd_file/" in
    *//*|*/./*|*/../*) cd_token="bad-file"; return 0 ;;
  esac
  h="$cd_section"
  n=0
  while [ "${h#"#"}" != "$h" ]; do
    h="${h#"#"}"
    n=$((n + 1))
  done
  if [ "$n" -lt 1 ] || [ "$n" -gt 6 ] || [ "${h# }" = "$h" ]; then cd_token="bad-section"; return 0; fi
  text="${h# }"
  case "$text" in
    ""|" "*|*[[:cntrl:]]*) cd_token="bad-section"; return 0 ;;
  esac
  cd_state="declared"
  cd_token=""
  return 0
}

# tree_file TREEISH PATH — sets tf_state (absent|file|notfile|error), tf_sha and tf_mode for the
# entry named exactly PATH in TREEISH's tree.
tree_file() {
  local line meta name
  tf_state="error"
  tf_sha=""
  tf_mode=""
  line="$(git ls-tree "$1" -- "$2" 2>/dev/null)" || return 0
  if [ -z "$line" ]; then tf_state="absent"; return 0; fi
  case "$line" in
    *"$NL"*) return 0 ;;
    *"$TAB"*) : ;;
    *) return 0 ;;
  esac
  meta="${line%%"$TAB"*}"
  name="${line#*"$TAB"}"
  if [ "$name" != "$2" ]; then tf_state="absent"; return 0; fi
  tf_mode="${meta%% *}"
  tf_sha="${meta##* }"
  case "$tf_mode" in
    100644|100755) tf_state="file" ;;
    *) tf_state="notfile" ;;
  esac
  return 0
}

# read_claude_md TREEISH — sets cm_state (absent|file|notfile|error) and cm_content.
read_claude_md() {
  cm_content=""
  tree_file "$1" "CLAUDE.md"
  cm_state="$tf_state"
  if [ "$cm_state" = "file" ]; then
    cm_content="$(git cat-file blob "$tf_sha" 2>/dev/null)" || cm_state="error"
  fi
}

# decl_at TREEISH — read_claude_md plus parse_decl, with the not-a-file shape as a malformed state.
decl_at() {
  read_claude_md "$1"
  case "$cm_state" in
    absent) cd_state="absent"; cd_token=""; cd_file=""; cd_section="" ;;
    notfile) cd_state="malformed"; cd_token="claude-md-not-a-file"; cd_file=""; cd_section="" ;;
    file) parse_decl "$cm_content" ;;
    *) cd_state="error" ;;
  esac
}

run_declared() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "changelog-merge.sh: not inside a git repository" >&2
    exit 2
  }
  cd "$top" 2>/dev/null || { echo "changelog-merge.sh: could not cd to the repo toplevel" >&2; exit 2; }
  decl_at HEAD
  case "$cd_state" in
    absent) echo "changelog=absent"; exit 0 ;;
    declared)
      echo "changelog=declared"
      echo "file=$cd_file"
      echo "section=$cd_section"
      exit 0
      ;;
    malformed)
      echo "changelog=malformed"
      echo "reason=$cd_token"
      exit 1
      ;;
    *)
      echo "changelog-merge.sh: could not read CLAUDE.md at HEAD" >&2
      exit 2
      ;;
  esac
}

# The section rebuild. Reads the merge base, the head and the base tip versions of the file (paths
# in CM_M, CM_H, CM_B), the section heading (CM_S) and the output path (CM_OUT) through the
# environment. Prints `ok` after writing the output, or one refusal token and writes nothing. Line
# comparisons are forced to strings, so numeric-looking lines never compare as numbers.
CM_AWK='
function blank(s) { return s ~ /^[ \t]*$/ }
function locate(f,   i, c, r) {
  c = 0
  for (i = 1; i <= n[f]; i++) if ((L[f, i] "") == (S "")) { c++; hd[f] = i }
  if (c == 0) return "section-missing"
  if (c > 1) return "section-repeated"
  en[f] = n[f] + 1
  for (i = hd[f] + 1; i <= n[f]; i++) {
    if (match(L[f, i], /^#+/)) {
      r = RLENGTH
      if (r <= d && substr(L[f, i], r + 1, 1) ~ /^[ \t]$/) { en[f] = i; break }
    }
  }
  return ""
}
BEGIN {
  S = ENVIRON["CM_S"]; OUT = ENVIRON["CM_OUT"]
  match(S, /^#+/); d = RLENGTH
  P[1] = ENVIRON["CM_M"]; P[2] = ENVIRON["CM_H"]; P[3] = ENVIRON["CM_B"]
}
{
  for (fi = 1; fi <= 3; fi++) if (FILENAME == P[fi]) break
  n[fi]++
  L[fi, n[fi]] = $0
}
END {
  for (f = 1; f <= 3; f++) { r = locate(f); if (r != "") { print r; exit } }
  m0 = hd[1]; h0 = hd[2]; b0 = hd[3]
  if (hd[1] != hd[2]) { print "outside-section"; exit }
  for (i = 1; i <= hd[1]; i++) if ((L[1, i] "") != (L[2, i] "")) { print "outside-section"; exit }
  post1 = n[1] - en[1] + 1; post2 = n[2] - en[2] + 1
  if (post1 != post2) { print "outside-section"; exit }
  for (i = 0; i < post1; i++) if ((L[1, en[1] + i] "") != (L[2, en[2] + i] "")) { print "outside-section"; exit }
  bm = en[1] - hd[1] - 1; bh = en[2] - hd[2] - 1; nn = bh - bm
  if (nn <= 0) { print "not-an-insertion"; exit }
  p = 0
  while (p < bm && (L[1, m0 + p + 1] "") == (L[2, h0 + p + 1] "")) p++
  for (j = 1; j <= bm - p; j++) if ((L[2, h0 + p + nn + j] "") != (L[1, m0 + p + j] "")) { print "not-an-insertion"; exit }
  topok = 1
  for (i = 1; i <= p; i++) if (!blank(L[1, m0 + i])) topok = 0
  botok = 1
  for (i = p + 1; i <= bm; i++) if (!blank(L[1, m0 + i])) botok = 0
  if (!topok && !botok) { print "mid-section"; exit }
  bb = en[3] - hd[3] - 1
  if (topok) { k = 0; while (k < bb && blank(L[3, b0 + k + 1])) k++ }
  else { k = bb; while (k > 0 && blank(L[3, b0 + k])) k-- }
  for (i = 1; i <= hd[3]; i++) print L[3, i] > OUT
  for (i = 1; i <= k; i++) print L[3, b0 + i] > OUT
  for (i = 1; i <= nn; i++) print L[2, h0 + p + i] > OUT
  for (i = k + 1; i <= bb; i++) print L[3, b0 + i] > OUT
  for (i = en[3]; i <= n[3]; i++) print L[3, i] > OUT
  close(OUT)
  print "ok"
}
'

# changed_names A B — the NUL-delimited, rename-free changed-path list between two tree-ish values
# (submodule paths always included, whatever the repo's ignore settings) as newline-separated text (an embedded newline becomes \001); returns 1 when git fails.
changed_names() {
  git diff --no-renames --ignore-submodules=none --name-only -z "$1" "$2" 2>/dev/null | tr '\000\n' '\n\001'
}

# dir_prefixes FILE — every leading directory of every path in FILE, sorted and unique.
dir_prefixes() {
  awk '{ for (i = 1; i <= length($0); i++) if (substr($0, i, 1) == "/") print substr($0, 1, i - 1) }' "$1" | sort -u
}

run_merge() {
  local base="$1" head="$2" branch="$3"
  local top mergebase mb_count remote lane_raw base_raw noctl shared pfx ovl p
  local new_lane new_base bad_lane bad_base
  local f_state lane_has_f m_sha m_mode h_sha h_mode b_sha b_mode out rebuilt tmp tree newhead
  local err

  top="$(git rev-parse --show-toplevel 2>&1)" || error_out "not inside a git repository: ${top%%"$NL"*}"
  cd "$top" 2>/dev/null || error_out "could not cd to the repo toplevel"
  git cat-file -e "${base}^{commit}" 2>/dev/null || error_out "base tip commit not found: $base"
  git cat-file -e "${head}^{commit}" 2>/dev/null || error_out "head commit not found: $head"

  remote="$(git rev-parse --verify -q "refs/remotes/origin/$branch" 2>/dev/null)" || remote=""
  [ -n "$remote" ] || hold "no-remote-branch"
  [ "$remote" = "$head" ] || hold "head-moved"

  decl_at "$base"
  case "$cd_state" in
    absent) echo "verdict=absent"; exit 0 ;;
    declared) : ;;
    malformed) hold "malformed-declaration $cd_token" ;;
    *) hold "unreadable-declaration" ;;
  esac
  local F="$cd_file" S="$cd_section"

  mergebase="$(git merge-base --all "$base" "$head" 2>/dev/null)" || mergebase=""
  mb_count=0
  if [ -n "$mergebase" ]; then
    mb_count="$(printf '%s\n' "$mergebase" | awk 'END { print NR }')" || mb_count=0
  fi
  [ "$mb_count" = "1" ] || hold "no-single-merge-base"
  local M="$mergebase"

  lane_raw="$(changed_names "$M" "$head")" || hold "git-failed"
  base_raw="$(changed_names "$M" "$base")" || hold "git-failed"
  noctl="$(printf '%s%s' "$lane_raw" "$base_raw" | tr -d '\001-\011\013-\037\177')"
  [ "${#noctl}" -eq $((${#lane_raw} + ${#base_raw})) ] || hold "control-char-path"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cm.XXXXXX" 2>/dev/null)" || hold "build-failed: mktemp"
  trap 'rm -rf "$tmp"' EXIT

  printf '%s\n' "$lane_raw" | awk 'length($0) > 0' | sort >"$tmp/lane-paths"
  printf '%s\n' "$base_raw" | awk 'length($0) > 0' | sort >"$tmp/base-paths"
  shared="$(comm -12 "$tmp/lane-paths" "$tmp/base-paths")" || hold "git-failed"
  # A path on one side that is a leading directory of a path on the other (a file against a
  # directory of the same name) collides too; update-index would silently replace one with the other.
  dir_prefixes "$tmp/lane-paths" >"$tmp/lane-anc"
  dir_prefixes "$tmp/base-paths" >"$tmp/base-anc"
  pfx="$({ comm -12 "$tmp/lane-anc" "$tmp/base-paths"; comm -12 "$tmp/base-anc" "$tmp/lane-paths"; } 2>/dev/null)" || hold "git-failed"
  rebuilt="no"
  printf '%s\n' "$shared" >"$tmp/shared"
  while IFS= read -r p; do
    [ "$p" = "$F" ] && rebuilt="yes"
  done <"$tmp/shared"
  ovl="$({ printf '%s\n' "$shared" | awk -v f="$F" 'length($0) > 0 && $0 != f'; printf '%s\n' "$pfx" | awk 'length($0) > 0'; } | sort -u | sed 's/^/overlap: /')" || hold "git-failed"
  [ -z "$ovl" ] || hold "overlap" "$ovl"

  if [ "$rebuilt" = "yes" ]; then
    tree_file "$M" "$F"
    [ "$tf_state" = "file" ] || hold "changelog-not-a-file"
    m_sha="$tf_sha"
    tree_file "$head" "$F"
    [ "$tf_state" = "file" ] || hold "changelog-not-a-file"
    h_sha="$tf_sha"
    tree_file "$base" "$F"
    [ "$tf_state" = "file" ] || hold "changelog-not-a-file"
    b_sha="$tf_sha"
    b_mode="$tf_mode"
    git cat-file blob "$m_sha" >"$tmp/m" 2>/dev/null || hold "build-failed: could not read the merge base file"
    git cat-file blob "$h_sha" >"$tmp/h" 2>/dev/null || hold "build-failed: could not read the head file"
    git cat-file blob "$b_sha" >"$tmp/b" 2>/dev/null || hold "build-failed: could not read the base tip file"
    for p in m h b; do
      if [ "$(( $(tr -d '\000' <"$tmp/$p" | wc -c) ))" -ne "$(( $(wc -c <"$tmp/$p") ))" ]; then
        hold "binary-file"
      fi
    done
    for p in m h b; do
      if [ -s "$tmp/$p" ] && [ -n "$(tail -c 1 "$tmp/$p")" ]; then
        hold "no-final-newline"
      fi
    done
    out="$(CM_M="$tmp/m" CM_H="$tmp/h" CM_B="$tmp/b" CM_S="$S" CM_OUT="$tmp/out" \
      awk "$CM_AWK" "$tmp/m" "$tmp/h" "$tmp/b")" || hold "build-failed: the section rebuild could not run"
    [ "$out" = "ok" ] || hold "$out"
  fi

  # The new tree, in a temporary index: the base tip's tree, then every lane-changed path at the
  # head's version (a deletion is mode 000000, which update-index removes), then the rebuilt file.
  git diff-tree -r -z --no-renames --ignore-submodules=none --raw "$M" "$head" 2>/dev/null | tr '\000' '\n' >"$tmp/raw"
  [ "${PIPESTATUS[0]}" -eq 0 ] || hold "git-failed"
  awk -v skip="$rebuilt" -v f="$F" '
    NR % 2 == 1 { split(substr($0, 2), a, " "); mode = a[2]; sha = a[4]; next }
    { if (skip == "yes" && $0 == f) next
      printf "%s %s\t%s\n", mode, sha, $0 }
  ' "$tmp/raw" | tr '\n' '\000' >"$tmp/info" || hold "build-failed: could not list the lane changes"
  if [ "$rebuilt" = "yes" ]; then
    h_sha="$(git hash-object -w --no-filters "$tmp/out" 2>/dev/null)" || hold "build-failed: could not write the rebuilt file"
    printf '%s %s\t%s\000' "$b_mode" "$h_sha" "$F" >>"$tmp/info"
  fi
  err="$(GIT_INDEX_FILE="$tmp/index" git read-tree "$base" 2>&1)" || hold "build-failed: $(printf '%s' "${err%%"$NL"*}" | tr -c '[:print:]' '?')"
  err="$(GIT_INDEX_FILE="$tmp/index" git update-index -z --index-info <"$tmp/info" 2>&1)" || hold "build-failed: $(printf '%s' "${err%%"$NL"*}" | tr -c '[:print:]' '?')"
  tree="$(GIT_INDEX_FILE="$tmp/index" git write-tree 2>/dev/null)" || hold "build-failed: write-tree"
  # Fail closed: the new tree may differ from the base tip only in lane-changed paths, and from the
  # head only in base-changed paths (the declared file excepted on both sides).
  new_lane="$(changed_names "$base" "$tree")" || hold "git-failed"
  new_base="$(changed_names "$head" "$tree")" || hold "git-failed"
  { cat "$tmp/lane-paths"; printf '%s\n' "$F"; } | sort -u >"$tmp/lane-ok"
  { cat "$tmp/base-paths"; printf '%s\n' "$F"; } | sort -u >"$tmp/base-ok"
  printf '%s\n' "$new_lane" | awk 'length($0) > 0' | sort >"$tmp/new-lane"
  printf '%s\n' "$new_base" | awk 'length($0) > 0' | sort >"$tmp/new-base"
  bad_lane="$(comm -23 "$tmp/new-lane" "$tmp/lane-ok")" || hold "git-failed"
  bad_base="$(comm -23 "$tmp/new-base" "$tmp/base-ok")" || hold "git-failed"
  [ -z "$bad_lane$bad_base" ] || hold "tree-check"
  if ! git var GIT_AUTHOR_IDENT >/dev/null 2>&1 || ! git var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
    export GIT_AUTHOR_NAME="changelog-merge.sh" GIT_AUTHOR_EMAIL="changelog-merge@localhost.invalid"
    export GIT_COMMITTER_NAME="changelog-merge.sh" GIT_COMMITTER_EMAIL="changelog-merge@localhost.invalid"
  fi
  newhead="$(git commit-tree "$tree" -p "$head" -p "$base" -m "Merge $base into $branch (changelog-merge.sh)" 2>/dev/null)" || \
    hold "build-failed: commit-tree"
  is_hex "$newhead" || hold "build-failed: commit-tree"

  echo "file=$F"
  if [ "$rebuilt" = "yes" ]; then echo "resolved=rebuilt"; else echo "resolved=not-shared"; fi
  echo "base-tip=$base"
  echo "old-head=$head"
  echo "new-head=$newhead"
  echo "verdict=updated"
  exit 0
}

if [ "${1:-}" = "--declared" ]; then
  [ "$#" -eq 1 ] || { echo "usage: changelog-merge.sh --declared" >&2; exit 2; }
  run_declared
fi

[ "$#" -eq 3 ] || error_out "usage: changelog-merge.sh <base-tip> <head-oid> <head-branch> | --declared"
is_hex "$1" && is_hex "$2" || error_out "usage: changelog-merge.sh <base-tip> <head-oid> <head-branch> (each oid exactly 40 or 64 lowercase hex characters)"
valid_branch "$3" || error_out "usage: changelog-merge.sh <base-tip> <head-oid> <head-branch> (the branch must look like claude/<digits>-<name>)"
run_merge "$1" "$2" "$3"
