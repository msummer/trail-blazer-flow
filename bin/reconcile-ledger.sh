#!/usr/bin/env bash
#
# reconcile-ledger.sh — mechanical closing reconciliation for an issue-cycle dispatch ledger.
#
# Usage:
#   reconcile-ledger.sh <ledger-file|-> [status-json-file]
#   reconcile-ledger.sh --help
#
# Compares a cycle run's dispatch ledger against the live harness queues (harness-status.sh
# JSON) and prints one line per discrepancy. It DETECTS ONLY — what a discrepancy means, and
# what to do about it, stays with the orchestrator (see the issue-cycle skill, step 5).
#
# LEDGER RECORDS — one per line, whitespace-separated; blank lines and #-comments ignored:
#
#   <issue> <stage> <outcome> [retries] [further fields, ignored]
#
#   issue    bare integer
#   stage    seed | planner | implementer | verifier | merge
#   outcome  a slug from that stage's vocabulary (below); '-' means "dispatched, nothing
#            recorded". For 'seed', the discovery bucket the issue was seeded from:
#            unplanned | in_revision | ready_to_implement (harness-status.sh names) or
#            needs_initial_plan | needs_revision | ready (the discovery scripts' names), or '-'.
#   retries  accepted and ignored, so agent status lines can be pasted verbatim.
#
# A verbatim agent status line counts as a record:
#   <!-- harness-status: stage=planner issue=17 outcome=plan-posted retries=0 -->
#
# Write a record only for a stage the run actually DISPATCHED — a stage the run never reached
# is ABSENT, not '-'. For the same issue+stage the LAST record wins (append-friendly).
#
# Stage vocabularies (canonical source: the issue-implementer skill, "Resilient dispatch"):
#   planner      plan-posted | plan-revised | incomplete | died
#   implementer  complete | blocked | incomplete | died
#   verifier     pass | fail | incomplete | died
#   merge        merged | merge-blocked | not-eligible | merge-unconfirmed
#
# STATUS JSON: harness-status.sh output. Omit the argument and this script runs
# harness-status.sh itself (needs gh authenticated); pass a path to work offline.
#
# OUTPUT: one line per discrepancy on stdout, ascending issue order:
#
#   <code> issue=<n> bucket=<b> stage=<s>: <explanation>
#
#   stage-skipped    still queued for <stage>; the ledger records no outcome for it
#   unledgered       in a harness queue but absent from the ledger entirely
#   outcome-missing  a record exists for the stage with no outcome ('-')
#   unknown-outcome  the recorded outcome is not in that stage's vocabulary
#   contradiction    the ledger says the queue's stages advanced, yet the issue is still queued
#
# EXIT: 0 = clean (no output); 1 = discrepancies printed; 2 = usage/input error (stderr).
#
# Requires: jq (and gh only when the status-json argument is omitted).
#
# No 'set -e' here: a grep/awk miss is normal control flow, and the 0/1/2 contract above is
# what callers read. 'set -f' keeps ledger/JSON text out of pathname expansion.
set -uo pipefail
set -f

usage() {
  cat <<'EOF'
usage: reconcile-ledger.sh <ledger-file|-> [status-json-file]

Compares an issue-cycle dispatch ledger against the live harness queues and prints one line
per discrepancy (stage-skipped | unledgered | outcome-missing | unknown-outcome | contradiction).

  <ledger-file>       records, one per line: "<issue> <stage> <outcome> [retries]".
                      Use '-' to read the ledger from stdin.
  [status-json-file]  harness-status.sh JSON; if omitted, harness-status.sh is run.

exit 0 = clean (no output), 1 = discrepancies printed, 2 = usage/input error.
EOF
}
die() { echo "reconcile-ledger.sh: $1" >&2; exit 2; }

# THE stage list — dev/selfcheck.sh's 4.13 parses this exact line (STAGES="..."). 'seed' is
# ledger-only (a discovery bucket, not an agent stage); agent_stages() excludes it.
STAGES="seed planner implementer verifier merge"
LEDGER_ONLY_STAGES="seed"
agent_stages() {
  for s in $STAGES; do
    case " $LEDGER_ONLY_STAGES " in *" $s "*) continue ;; esac
    printf '%s ' "$s"
  done
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "")        usage >&2; exit 2 ;;
esac
[ "$#" -le 2 ] || die "too many arguments (expected at most 2)"
ledger_src="$1"; status_src="${2:-}"
command -v jq >/dev/null 2>&1 || die "jq is required but not on the PATH"

# --- ledger ------------------------------------------------------------------
if [ "$ledger_src" = "-" ]; then
  raw="$(cat)"
else
  [ -r "$ledger_src" ] || die "cannot read ledger file: $ledger_src"
  raw="$(cat "$ledger_src")"
fi

# CR-safe; rewrite agent status lines into plain records; drop comments and blanks.
norm="$(printf '%s\n' "$raw" \
  | tr -d '\r' \
  | sed -E 's/^.*<!-- harness-status: stage=([^ ]+) issue=([0-9]+) outcome=([^ ]+) retries=([^ ]+) -->.*$/\2 \1 \3 \4/' \
  | grep -v '^[[:space:]]*#' \
  | grep -v '^[[:space:]]*$')"

records=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in *harness-status:*) die "malformed harness-status line: $line" ;; esac
  read -r f_issue f_stage f_outcome _rest <<<"$line"
  case "$f_issue" in ''|*[!0-9]*) die "ledger record does not start with an issue number: $line" ;; esac
  case " $STAGES " in
    *" $f_stage "*) ;;
    *) die "unknown stage '$f_stage' in ledger record: $line" ;;
  esac
  [ -n "$f_outcome" ] || f_outcome="-"
  if [ "$f_stage" = "seed" ] && [ "$f_outcome" != "-" ]; then
    case "$f_outcome" in
      unplanned|in_revision|ready_to_implement|needs_initial_plan|needs_revision|ready) ;;
      *) die "unknown seed bucket '$f_outcome' in ledger record: $line" ;;
    esac
  fi
  records="${records}${f_issue} ${f_stage} ${f_outcome}
"
done <<EOF
$norm
EOF

# --- live state --------------------------------------------------------------
if [ -n "$status_src" ]; then
  [ -r "$status_src" ] || die "cannot read status JSON file: $status_src"
  status_json="$(cat "$status_src")"
else
  command -v harness-status.sh >/dev/null 2>&1 \
    || die "harness-status.sh not on the PATH — pass its JSON as the second argument"
  status_json="$(harness-status.sh </dev/null)" \
    || die "harness-status.sh failed (is gh authenticated?)"
fi
jq -e . >/dev/null 2>&1 <<<"$status_json" || die "status input is not valid JSON"
jq -e '.harness_will_handle' >/dev/null 2>&1 <<<"$status_json" \
  || die "status JSON has no .harness_will_handle — expected harness-status.sh output"

live="$(jq -r '.harness_will_handle as $h
  | ( (($h.unplanned // [])          | map("unplanned "          + (.number|tostring)))
    + (($h.in_revision // [])        | map("in_revision "        + (.number|tostring)))
    + (($h.ready_to_implement // []) | map("ready_to_implement " + (.number|tostring))) )
  | .[]' <<<"$status_json")"

# forward-compat: a bucket this script doesn't know about is announced, not silently ignored.
for b in $(jq -r '.harness_will_handle | keys[]
                  | select(. != "unplanned" and . != "in_revision" and . != "ready_to_implement")' \
           <<<"$status_json"); do
  echo "reconcile-ledger.sh: warning: unknown harness_will_handle bucket '$b' — not reconciled" >&2
done

# --- lookups -----------------------------------------------------------------
vocab() {
  case "$1" in
    planner)     printf '%s' 'plan-posted plan-revised incomplete died' ;;
    implementer) printf '%s' 'complete blocked incomplete died' ;;
    verifier)    printf '%s' 'pass fail incomplete died' ;;
    merge)       printf '%s' 'merged merge-blocked not-eligible merge-unconfirmed' ;;
    *) die "no outcome vocabulary defined for stage '$1' — add it to vocab()" ;;
  esac
}
in_vocab()   { case " $(vocab "$1") " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }
advancing()  { case "$1:$2" in
                 planner:plan-posted|planner:plan-revised|implementer:complete|verifier:pass) return 0 ;;
                 *) return 1 ;;
               esac; }
chain()      { case "$1" in
                 unplanned|in_revision) printf '%s' 'planner' ;;
                 ready_to_implement)    printf '%s' 'implementer verifier' ;;
               esac; }
row_exists() { printf '%s\n' "$records" | awk -v n="$1" -v s="$2" '$1==n && $2==s {f=1} END{exit !f}'; }
row_outcome(){ printf '%s\n' "$records" | awk -v n="$1" -v s="$2" '$1==n && $2==s {o=$3} END{if (o!="") print o}'; }
has_rows()   { printf '%s\n' "$records" | awk -v n="$1" '$1==n {f=1} END{exit !f}'; }
in_bucket()  { printf '%s\n' "$live"    | awk -v b="$1" -v n="$2" '$1==b && $2==n {f=1} END{exit !f}'; }

issues="$( { printf '%s\n' "$records" | awk '{print $1}'
             printf '%s\n' "$live"    | awk '{print $2}'; } \
           | grep -E '^[0-9]+$' | sort -n -u )"

found=0
emit() { printf '%s\n' "$1"; found=1; }

for n in $issues; do
  # (a) record-level checks, fixed stage order
  for s in $(agent_stages); do
    row_exists "$n" "$s" || continue
    o="$(row_outcome "$n" "$s")"
    if [ "$o" = "-" ]; then
      emit "outcome-missing issue=$n bucket=- stage=$s: ledger row for this stage records no outcome"
    elif ! in_vocab "$s" "$o"; then
      emit "unknown-outcome issue=$n bucket=- stage=$s: outcome '$o' is not in the $s vocabulary ($(vocab "$s" | tr ' ' '|'))"
    fi
  done
  # (b) queue checks, fixed bucket order
  for b in unplanned in_revision ready_to_implement; do
    in_bucket "$b" "$n" || continue
    if ! has_rows "$n"; then
      emit "unledgered issue=$n bucket=$b stage=-: in a harness queue but absent from the ledger (filed mid-run, or never seeded)"
      continue
    fi
    all_advanced=1; last_stage=""
    for s in $(chain "$b"); do
      last_stage="$s"
      if ! row_exists "$n" "$s"; then
        emit "stage-skipped issue=$n bucket=$b stage=$s: still queued for this stage and the ledger records no outcome for it"
        all_advanced=0; break
      fi
      o="$(row_outcome "$n" "$s")"
      # '-' and unknown slugs were already reported above; a non-advancing outcome
      # (blocked/fail/incomplete/died) is a REPORTED stage, not a silent skip.
      if [ "$o" = "-" ] || ! in_vocab "$s" "$o" || ! advancing "$s" "$o"; then
        all_advanced=0; break
      fi
    done
    if [ "$all_advanced" -eq 1 ]; then
      emit "contradiction issue=$n bucket=$b stage=$last_stage: ledger records this stage advanced but the issue is still in this queue"
    fi
  done
done

[ "$found" -eq 0 ] && exit 0
exit 1
