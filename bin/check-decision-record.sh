#!/usr/bin/env bash
#
# check-decision-record.sh — read-only checker for a GitHub issue's scoped-autonomy decision
# record (see the README's "The CLAUDE.md contract", "Autonomy decision record" declaration).
#
# Usage:
#   check-decision-record.sh <issue-number>
#   check-decision-record.sh --help
#
# Reads $root/CLAUDE.md for a section titled exactly "Autonomy decision record": a fenced block
# of 'key: value' lines — grant-label: <label> (required, first occurrence wins), record-section:
# <heading text> (optional, default "Binding decisions", first occurrence wins), and one or more
# element: <heading text> lines (required, declaration order preserved); blank lines and
# '#'-prefixed comment lines are ignored, unknown keys are ignored. It then fetches the named
# issue's body (gh issue view --json body) and checks it for a heading matching the record
# section (presence only — any '#' depth, matched literally with grep -qxF, never as a regex,
# anywhere outside a fenced block), and for each declared element, a heading that is nested under
# the record-section heading (strictly deeper, before the next same-or-shallower heading outside
# a fence — the same depth rule the section span itself uses; a same-depth heading is NOT nested)
# AND has at least one non-blank line of content in its span. A heading present only outside the
# record section's span, a heading present inside the span but empty, and a heading entirely
# absent each fail with a distinct message.
#
# This script never executes, evals, or shells out to anything read from CLAUDE.md or the issue
# body: the issue body is parsed by a single awk pass that takes no '-v' input at all — nothing
# read from CLAUDE.md or the issue body ever reaches awk as a -v value, a dynamic regex, or an
# ENVIRON lookup. The awk pass emits a "<depth> <filled> <heading text>" line per outside-fence
# heading, in document order; every comparison against a CLAUDE.md- or body-derived value (the
# record-section text, an element's declared heading text) happens afterwards, in the shell, as a
# literal 'grep -qxF --' membership test or a plain '[ "$a" = "$b" ]' string compare — never
# expanded, substituted, or passed to command -v/exec (mirrors the never-execute guarantee
# documented in bin/check-harness.sh's test-suite-ratchet check).
#
# Documented limitations, still true after this change: a heading must start at column 0 (no
# indentation); its quality is never judged, only whether the element's span has at least one
# non-blank line of content. A fence's opening delimiter may be indented up to 3 spaces (matching
# the closing rule); a leading tab is never eligible as fence indentation, so a tab-indented
# '```' is read as ordinary content, not a fence. claude_md_block() and first_fence() (below),
# which slice CLAUDE.md rather than the issue body, deliberately keep their simpler column-0,
# backtick-only fence rule: CLAUDE.md is checked-in, repo-controlled content whose fenced shape
# the README's CLAUDE.md contract fixes, unlike an issue body pasted by anyone with issue-write
# access.
#
# This script's exit code is one input to the plan auto-approval hard floor (see
# skills/issue-planner/SKILL.md's step 6a and its grant verdict): a false PASS here can let an
# autonomous implementation proceed on a grant-labelled issue whose decision record does not
# actually say what the harness will treat it as saying — not merely cost a human's attention.
#
# Exit: 0 = the record section and every declared element were found (each element's heading also
# nested under the section and non-empty); 1 = at least one was missing, found only outside the
# record section, or present but empty; 2 = usage/input error (non-numeric issue, no CLAUDE.md, no
# declaration, no grant-label:/element: lines, missing jq/gh, or a failed issue fetch).
#
# Requires: gh (authenticated), jq. Read-only — makes no mutating gh call, writes no file.
set -uo pipefail

usage() {
  cat <<'EOF'
usage: check-decision-record.sh <issue-number>
       check-decision-record.sh --help

Checks whether a GitHub issue's body satisfies the "Autonomy decision record" CLAUDE.md
declares: the record-section heading (presence only), plus every declared element heading
nested under it (outside a fenced code block) AND with at least one non-blank line of content
under it. Prints one PASS/FAIL line per check and a summary footer.

exit 0 = record section found + every declared element found nested and non-empty
exit 1 = at least one is missing, found outside the record section, or empty
exit 2 = usage/input error
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "")        usage >&2; exit 2 ;;
esac

issue="$1"
case "$issue" in
  ''|*[!0-9]*) echo "check-decision-record.sh: issue number must be a positive integer, got: '$issue'" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "check-decision-record.sh: too many arguments (expected exactly 1: <issue-number>)" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "check-decision-record.sh: jq is required but not on the PATH" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "check-decision-record.sh: gh is required but not on the PATH" >&2; exit 2; }

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "check-decision-record.sh: not inside a git repository" >&2; exit 2; }
claude_md="$root/CLAUDE.md"
[ -f "$claude_md" ] || { echo "check-decision-record.sh: no CLAUDE.md at $claude_md" >&2; exit 2; }

# claude_md_block TITLE — slices $claude_md by exact heading (any '#' depth, no trailing text) —
# same idiom as bin/check-harness.sh's has_policy_section/ratchet section-slice; kept standalone
# here rather than sourced, deliberately, per this repo's bin/ convention (no sourcing between
# bin/ scripts). Fence-aware: a '#'-prefixed line only ends the section when outside a fenced
# block, so a '#' comment declared inside the block (see this script's own doc comment above)
# does not truncate it.
claude_md_block() {
  awk -v t="$1" '
    $0 ~ "^#+[[:space:]]+" t "[[:space:]]*$" { inx=1; next }
    inx && /^```/ { infence = !infence }
    inx && !infence && /^#+[[:space:]]/ { exit }
    inx { print }
  ' "$claude_md"
}

# first_fence — prints the contents of the first fenced block (opening fence: a line starting
# with three backticks, info string ignored) found on stdin; stops at the closing fence.
first_fence() {
  awk '
    /^```/ { if (infence) { exit } else { infence=1; next } }
    infence { print }
  '
}

record_raw="$(claude_md_block "Autonomy decision record" | first_fence)"
if [ -z "$record_raw" ]; then
  echo "check-decision-record.sh: CLAUDE.md has no 'Autonomy decision record' section (or its fenced block is empty) — nothing to check; see the README's CLAUDE.md contract" >&2
  exit 2
fi

grant_label=""
record_section="Binding decisions"
record_section_set=false
elements=""
while IFS= read -r raw_line; do
  trimmed="$(printf '%s\n' "$raw_line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [ -n "$trimmed" ] || continue
  case "$trimmed" in
    '#'*) continue ;;
    grant-label:*)
      if [ -z "$grant_label" ]; then
        grant_label="$(printf '%s\n' "$trimmed" | sed -E 's/^grant-label:[[:space:]]*//')"
      fi
      ;;
    record-section:*)
      if ! $record_section_set; then
        record_section="$(printf '%s\n' "$trimmed" | sed -E 's/^record-section:[[:space:]]*//')"
        record_section_set=true
      fi
      ;;
    element:*)
      val="$(printf '%s\n' "$trimmed" | sed -E 's/^element:[[:space:]]*//')"
      elements="${elements}${val}
"
      ;;
    *) continue ;;
  esac
done <<EOF
$record_raw
EOF

[ -n "$grant_label" ] || { echo "check-decision-record.sh: 'Autonomy decision record' section has no 'grant-label:' line" >&2; exit 2; }
[ -n "$elements" ] || { echo "check-decision-record.sh: 'Autonomy decision record' section has no 'element:' line (at least one required)" >&2; exit 2; }

body="$(gh issue view "$issue" --json body 2>/dev/null | jq -r '.body' | tr -d '\r')" \
  || { echo "check-decision-record.sh: could not fetch issue #$issue's body (gh issue view failed — check the issue number and gh auth)" >&2; exit 2; }

# body_headings — a single fence-aware, depth-aware awk pass over $body (same depth rule as
# bin/check-harness.sh's claude_md_section: a heading's span runs to the next same-or-shallower
# heading OUTSIDE a fenced block, so a deeper sub-heading nested inside it does not end it), with
# no '-v' input at all. Prints one line per outside-fence ATX heading, in document order:
#   <depth> <0|1> <normalised heading text>
# depth is 1-9 (capped); the second field is 1 iff the heading's span contains at least one
# non-blank, non-delimiter line (a line under a deeper sub-heading, or inside a fenced block,
# counts; a fence-delimiter line and a blank line do not). Depth-indexed bookkeeping (not a
# stack), so a deeper sub-heading continues its ancestors' spans rather than starting a new one.
# Requires whitespace after the '#' run (matches claude_md_block/claude_md_section) —
# "#Heading" is not a heading.
#
# Fence tracking is CommonMark-lite: a line with 0-3 leading spaces followed by a run of 3+ '`'
# or 3+ '~' opens a fence (its info string, if any, is ignored); the fence closes only on a line
# with 0-3 leading spaces whose run uses the SAME character, is at least as long as the opener's,
# and is followed by nothing but whitespace — a shorter run, a different character, or a run
# followed by an info string is ordinary in-fence content, never a delimiter. A leading tab is
# never eligible as fence indentation (the space-count loop never advances past it, and a tab is
# neither '`' nor '~', so the candidate test fails on its own).
#
# The shell walks this heading map (below) to build three lists — all_headings (every heading,
# for the section's presence-only check), in_section (headings strictly nested under the
# record-section heading, by the same depth rule), and filled_in (the in_section subset whose
# span has content) — as literal grep -qxF membership tests; the record-section text and each
# declared element's text are compared only that way, never passed to awk.
body_headings() {
  printf '%s\n' "$body" | awk '
    function fence_candidate(s,    i, len, c, runlen) {
      len = length(s)
      i = 0
      while (i < len && substr(s, i + 1, 1) == " ") i++
      if (i > 3 || i >= len) return 0
      c = substr(s, i + 1, 1)
      if (c != "`" && c != "~") return 0
      runlen = 0
      while (i + runlen < len && substr(s, i + runlen + 1, 1) == c) runlen++
      if (runlen < 3) return 0
      fc_char = c; fc_len = runlen; fc_rest = substr(s, i + runlen + 1)
      return 1
    }
    {
      is_cand = fence_candidate($0)
      if (infence) {
        if (is_cand && fc_char == fchar && fc_len >= flen && fc_rest ~ /^[[:space:]]*$/) {
          infence = 0
          next
        }
        if ($0 !~ /^[[:space:]]*$/) for (j = 1; j <= 9; j++) if (open[j]) filled[idx[j]] = 1
        next
      }
      if (is_cand) { infence = 1; fchar = fc_char; flen = fc_len; next }
      if ($0 ~ /^#+[[:space:]]/) {
        match($0, /^#+/); d = RLENGTH; if (d > 9) d = 9
        t = $0; sub(/^#+[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
        for (j = d; j <= 9; j++) open[j] = 0
        n++; depth[n] = d; text[n] = t; filled[n] = 0
        open[d] = 1; idx[d] = n
        next
      }
      if ($0 ~ /^[[:space:]]*$/) next
      for (j = 1; j <= 9; j++) if (open[j]) filled[idx[j]] = 1
    }
    END { for (i = 1; i <= n; i++) print depth[i], filled[i], text[i] }
  '
}
body_map="$(body_headings)"

# Shell-side section walk: sec_depth tracks the currently-open record-section span (0 = outside).
# A heading text equal to $record_section (re)opens the span at its own depth; a same-or-shallower
# heading outside a fence closes it first (a same-depth heading is NOT nested, per the README's
# CLAUDE.md contract). Repeated record-section headings union their spans, since in_section/
# filled_in are only ever appended to, never reset. Guard "$d" before any numeric test — the awk
# pass only ever emits 1-9, but the guard keeps this loop safe against a stray blank line.
sec_depth=0
all_headings=""
in_section=""
filled_in=""
while IFS=' ' read -r d fl t; do
  case "$d" in
    ''|*[!0-9]*) continue ;;
  esac
  all_headings="${all_headings}${t}
"
  if [ "$sec_depth" -gt 0 ] && [ "$d" -le "$sec_depth" ]; then
    sec_depth=0
  fi
  if [ "$t" = "$record_section" ]; then
    sec_depth="$d"
    continue
  fi
  if [ "$sec_depth" -gt 0 ]; then
    in_section="${in_section}${t}
"
    if [ "$fl" = "1" ]; then
      filled_in="${filled_in}${t}
"
    fi
  fi
done <<EOF
$body_map
EOF
has_heading() { printf '%s\n' "$all_headings" | grep -qxF -- "$1"; }
has_in_section() { printf '%s\n' "$in_section" | grep -qxF -- "$1"; }
has_content() { printf '%s\n' "$filled_in" | grep -qxF -- "$1"; }

echo "== decision record: issue #$issue =="
p=0; f=0
if has_heading "$record_section"; then
  echo "  PASS  section: $record_section"
  p=$((p+1))
else
  echo "  FAIL  section: $record_section (no heading found)"
  f=$((f+1))
fi

while IFS= read -r el; do
  [ -n "$el" ] || continue
  if ! has_heading "$el"; then
    echo "  FAIL  element: $el (no heading found)"
    f=$((f+1))
  elif ! has_in_section "$el"; then
    echo "  FAIL  element: $el (heading found outside the record section)"
    f=$((f+1))
  elif ! has_content "$el"; then
    echo "  FAIL  element: $el (heading found, no content under it)"
    f=$((f+1))
  else
    echo "  PASS  element: $el"
    p=$((p+1))
  fi
done <<EOF
$elements
EOF

echo
if [ "$f" -gt 0 ]; then
  echo "  note: a heading inside a fenced code block does not count, an element heading must be nested under the record section, and a heading with no content under it fails"
fi
echo "== summary: $p pass, $f fail =="
[ "$f" -eq 0 ] || exit 1
exit 0
