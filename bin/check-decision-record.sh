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
# section, and one for each declared element — exact heading text, any '#' depth, matched
# literally (grep -qxF), never as a regex.
#
# This script never executes, evals, or shells out to anything read from CLAUDE.md or the issue
# body: every value pulled from either is used only as a literal string compared with
# 'grep -qxF' — never expanded, substituted, or passed to command -v/exec (mirrors the
# never-execute guarantee documented in bin/check-harness.sh's test-suite-ratchet check).
#
# Documented limitation: heading detection is depth-insensitive (any '#' level counts as a
# heading) and does not track fenced code blocks inside the issue body — a heading-shaped line
# written inside a fenced block in the body would be read as a real heading. Accepted: this
# script only ever produces a PASS/FAIL report, never an action, so a false PASS costs a human's
# attention, not an autonomous side effect.
#
# Exit: 0 = the record section and every declared element were found; 1 = at least one was
# missing; 2 = usage/input error (non-numeric issue, no CLAUDE.md, no declaration, no
# grant-label:/element: lines, missing jq/gh, or a failed issue fetch).
#
# Requires: gh (authenticated), jq. Read-only — makes no mutating gh call, writes no file.
set -uo pipefail

usage() {
  cat <<'EOF'
usage: check-decision-record.sh <issue-number>
       check-decision-record.sh --help

Checks whether a GitHub issue's body satisfies the "Autonomy decision record" CLAUDE.md
declares: the record-section heading plus every declared element heading. Prints one PASS/FAIL
line per check and a summary footer.

exit 0 = record section + every declared element found
exit 1 = at least one is missing
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

headings="$(printf '%s\n' "$body" | grep '^#' | sed -E 's/^#+[[:space:]]*//; s/[[:space:]]+$//')"
has_heading() { printf '%s\n' "$headings" | grep -qxF -- "$1"; }

echo "== decision record: issue #$issue =="
p=0; f=0
if has_heading "$record_section"; then
  echo "  PASS  section: $record_section"
  p=$((p+1))
else
  echo "  FAIL  section: $record_section"
  f=$((f+1))
fi

while IFS= read -r el; do
  [ -n "$el" ] || continue
  if has_heading "$el"; then
    echo "  PASS  element: $el"
    p=$((p+1))
  else
    echo "  FAIL  element: $el"
    f=$((f+1))
  fi
done <<EOF
$elements
EOF

echo
echo "== summary: $p pass, $f fail =="
[ "$f" -eq 0 ] || exit 1
exit 0
