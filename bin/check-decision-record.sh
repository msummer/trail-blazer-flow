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
# section (presence only — any '#' depth, matched literally with grep -qxF, never as a regex),
# and for each declared element, a heading that is both present outside any fenced code block
# AND has at least one non-blank line of content in its span (up to the next same-or-shallower
# heading outside a fence) — a heading found only inside a fence, or with nothing written under
# it, fails just like a heading that is entirely absent, with a distinct message for each case.
#
# This script never executes, evals, or shells out to anything read from CLAUDE.md or the issue
# body: the issue body is parsed by an awk program whose only '-v' input is a script-controlled
# literal mode string ("all" or "filled"), never a value read from CLAUDE.md or the body itself;
# every value pulled from either is used only as a literal string compared with 'grep -qxF' —
# never expanded, substituted, or passed to command -v/exec (mirrors the never-execute guarantee
# documented in bin/check-harness.sh's test-suite-ratchet check).
#
# Documented limitations, still true after this change: only backtick fences are tracked, and
# any run of three-or-more backticks toggles fence state, so a '~~~'-style fence, or a
# backtick-fenced block nested inside another, can still mislead the scan. A heading must start
# at column 0 (no indentation); an element heading is matched anywhere in the body, not required
# to be nested under the record section. Content is any non-blank line in a heading's span other
# than a nested heading line or a fence delimiter — its quality is never judged, only its
# presence.
#
# This script's exit code is one input to the plan auto-approval hard floor (see
# skills/issue-planner/SKILL.md's step 6a and its grant verdict): a false PASS here can let an
# autonomous implementation proceed on a grant-labelled issue whose decision record does not
# actually say what the harness will treat it as saying — not merely cost a human's attention.
#
# Exit: 0 = the record section and every declared element were found (elements also non-empty);
# 1 = at least one was missing or, for an element, present but empty; 2 = usage/input error
# (non-numeric issue, no CLAUDE.md, no declaration, no grant-label:/element: lines, missing
# jq/gh, or a failed issue fetch).
#
# Requires: gh (authenticated), jq. Read-only — makes no mutating gh call, writes no file.
set -uo pipefail

usage() {
  cat <<'EOF'
usage: check-decision-record.sh <issue-number>
       check-decision-record.sh --help

Checks whether a GitHub issue's body satisfies the "Autonomy decision record" CLAUDE.md
declares: the record-section heading (presence only), plus every declared element heading
found outside a fenced code block AND with at least one non-blank line of content under it.
Prints one PASS/FAIL line per check and a summary footer.

exit 0 = record section found + every declared element found and non-empty
exit 1 = at least one is missing or empty
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

# body_headings MODE — fence-aware, depth-aware awk scan of $body (same depth rule as
# bin/check-harness.sh's claude_md_section: a heading's span runs to the next same-or-shallower
# heading OUTSIDE a fenced block, so a deeper sub-heading nested inside it does not end it).
# mode=all prints every ATX heading's normalised text (leading '#'s and required whitespace
# stripped, trailing whitespace stripped) found outside a fenced block, in document order.
# mode=filled prints only the subset of those headings whose span contains at least one
# non-blank line — a line under a deeper sub-heading, or inside a fenced block, counts as
# content; a fence-delimiter line and a blank line do not. Depth-indexed arrays (not a stack) so
# a deeper sub-heading continues its ancestors' spans rather than starting a new one. Requires
# whitespace after the '#' run (matches claude_md_block/claude_md_section) — "#Heading" is not a
# heading. The only '-v' value is this literal "all"/"filled" mode string — nothing read from
# CLAUDE.md or the issue body is ever passed to awk as a -v value. Residual gaps (see the header
# above): only backtick fences are tracked, and headings must start at column 0.
body_headings() {
  printf '%s\n' "$body" | awk -v mode="$1" '
    /^```/ { infence = !infence; next }
    !infence && /^#+[[:space:]]/ {
      match($0, /^#+/); d = RLENGTH; if (d > 9) d = 9
      t = $0; sub(/^#+[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
      for (j = d; j <= 9; j++) if (open[j]) { if (mode == "filled" && full[j]) print txt[j]; open[j] = 0 }
      open[d] = 1; txt[d] = t; full[d] = 0
      if (mode == "all") print t
      next
    }
    /^[[:space:]]*$/ { next }
    { for (j = 1; j <= 9; j++) if (open[j]) full[j] = 1 }
    END { for (j = 1; j <= 9; j++) if (open[j] && mode == "filled" && full[j]) print txt[j] }
  '
}
headings="$(body_headings all)"
filled="$(body_headings filled)"
has_heading() { printf '%s\n' "$headings" | grep -qxF -- "$1"; }
has_content() { printf '%s\n' "$filled" | grep -qxF -- "$1"; }

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
  echo "  note: a heading inside a fenced code block does not count, and a heading with no content under it fails"
fi
echo "== summary: $p pass, $f fail =="
[ "$f" -eq 0 ] || exit 1
exit 0
