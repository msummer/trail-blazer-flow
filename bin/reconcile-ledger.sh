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
#   <issue> <stage> <outcome> [retries] [deploy=<slug>] [harness=<version>] [further fields, ignored]
#
#   issue    bare integer
#   stage    seed | planner | implementer | verifier | merge
#   outcome  a slug from that stage's vocabulary (below); '-' means "dispatched, nothing
#            recorded". For 'seed', the discovery bucket the issue was seeded from:
#            unplanned | in_revision | ready_to_implement (harness-status.sh names) or
#            needs_initial_plan | needs_revision | ready (the discovery scripts' names), or '-'.
#   retries  accepted and ignored, so agent status lines can be pasted verbatim.
#   deploy   optional, valid only when stage=merge: a slug from the deploy vocabulary (below),
#            from the merge pass's optional post-merge verification step (issue-cycle guard
#            (e)). Absent on any other record; a deploy= token on a non-merge stage is a
#            parse-time error (die, exit 2).
#
# A verbatim agent status line counts as a record:
#   <!-- harness-status: stage=planner issue=17 outcome=plan-posted retries=0 -->
#   <!-- harness-status: stage=planner issue=17 outcome=plan-posted retries=0 harness=2.7.0 -->
#   <!-- harness-status: stage=merge issue=17 outcome=merged retries=0 deploy=verified -->
#   <!-- harness-status: stage=merge issue=17 outcome=merged retries=0 deploy=verified harness=2.7.0 -->
#
# Write a record only for a stage the run actually DISPATCHED — a stage the run never reached
# is ABSENT, not '-'. For the same issue+stage the LAST record wins (append-friendly).
#
# Stage vocabularies (canonical source: the issue-implementer skill, "Resilient dispatch"):
#   planner      plan-posted | plan-revised | incomplete | died
#   implementer  complete | blocked | incomplete | died
#   verifier     pass | fail | incomplete | died
#   merge        merged | merge-blocked | not-eligible | merge-unconfirmed
#   deploy       verified | pending | failed (merge-only; see DEPLOY_OUTCOMES below —
#                dev/selfcheck.sh's 4.13 parses that exact line)
#
# STATUS JSON: harness-status.sh output. Omit the argument and this script runs
# harness-status.sh itself (needs gh authenticated); pass a path to work offline. (#298) Also
# read: the top-level `degraded` boolean and `degraded_reasons` array — see the `degraded` OUTPUT
# code below.
#
# OUTPUT: one line per discrepancy on stdout. A `degraded` line, if any, comes FIRST (see below) —
# then per-issue discrepancy lines in ascending issue order:
#
#   <code> issue=<n> bucket=<b> stage=<s>: <explanation>
#
#   degraded         (#298) a discovery query (planning.* or implementation.*) failed closed this
#                    run — or degraded:true carries no reasons at all (the "unspecified" backstop
#                    below) — so a harness_will_handle bucket this reconciliation compares against
#                    may under-report the true queue rather than reflect it. harness-status.sh's
#                    OWN query/check failures (status.<key>) never produce this line by themselves: they
#                    describe the waiting_on_human buckets this reconciliation never compares.
#                    issue=- bucket=- stage=-. One line per degraded_reasons entry that does NOT
#                    start with "status." (a "status." entry never refuses on its own); a
#                    degraded:true document whose degraded_reasons is empty or absent yields one
#                    "unspecified" line instead (this backstop does NOT fire on a status-only-
#                    reasons document — that one stays silent, exit 0). Every refusing entry
#                    renders as exactly one non-empty stdout line: every control character (an
#                    embedded newline, a bare NUL byte, a carriage return, ...) is escaped, and an
#                    entry that escapes to the empty string becomes a visible placeholder, so no
#                    entry is ever silently dropped or split across lines. These lines print
#                    before every per-issue line, and force exit 1 — the per-issue comparison
#                    below still runs.
#   stage-skipped    still queued for <stage>; the ledger records no outcome for it
#   unledgered       in a harness queue but absent from the ledger entirely
#   outcome-missing  a record exists for the stage with no outcome ('-')
#   unknown-outcome  the recorded outcome is not in that stage's vocabulary
#   contradiction    the ledger says the queue's stages advanced, yet the issue is still queued
#
# EXIT: 0 = clean (no output); 1 = discrepancies printed; 2 = usage/input error (stderr) — a status
# JSON whose degraded_reasons is present but not an array is one such usage/input error.
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
per discrepancy (degraded | stage-skipped | unledgered | outcome-missing | unknown-outcome |
contradiction). A degraded status JSON refuses a clean reconciliation: one "degraded" line per
non-"status." degraded_reasons entry, printed before any per-issue line; a degraded:true document
whose degraded_reasons is empty or absent gets one "unspecified" line instead (the "unspecified"
backstop) rather than silence.

  <ledger-file>       records, one per line: "<issue> <stage> <outcome> [retries] [deploy=<slug>]".
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

# THE deploy outcome vocabulary — dev/selfcheck.sh's 4.13 parses this exact line
# (DEPLOY_OUTCOMES="..."). Valid only on a merge-stage record's optional deploy= field.
DEPLOY_OUTCOMES="verified pending failed"
in_deploy_vocab() { case " $DEPLOY_OUTCOMES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

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
  # No access() pre-test on this path (dropped #336): this argument accepts any path a caller
  # passes, including a process-substitution <(...) — this repo's own gate does exactly that
  # (sheet A3) — and on macOS an access()-style readability test on a /dev/fd/N path races (~1 in
  # 2000) when several processes touch /dev/fd at once — measured, sheet A4-A6 — while the content
  # read itself never failed in 42,000 reads under that same load (A5). Attempt the read directly
  # and die on failure instead;
  # incidentally, a *directory* argument now dies here too (exit 2, "cannot read ledger file");
  # previously it exited 0 with an empty ledger, with only cat's own "Is a directory" message on
  # stderr.
  raw="$(cat "$ledger_src" 2>/dev/null)" || die "cannot read ledger file: $ledger_src"
fi

# CR-safe; rewrite agent status lines into plain records; drop comments and blanks. Four
# sed -E passes, not one optional-group expression: both-fields, deploy-only, harness-only,
# neither. The four accepted forms are mutually exclusive — each pass anchors its match on
# " -->" immediately after its own last captured field, so a line carrying a trailing field a
# given pass doesn't expect (e.g. the both-fields line against the deploy-only pass) simply
# doesn't match that pass at all and falls through unchanged, rather than matching short and
# stranding the extra field. Each pass that DOES match rewrites the line to a plain record that
# no longer contains '<!--', so a line already rewritten by an earlier pass can never be
# re-matched by a later one. Listing most-specific-first is defensive convention, not
# load-bearing: swapping the both-fields and deploy-only passes still parses every accepted form
# identically (measured — see dev/selfcheck.sh's 5.13). Preferred over a single expression with
# a back-reference to a possibly-unmatched capture, whose behavior under BSD sed -E is
# unverified.
norm="$(printf '%s\n' "$raw" \
  | tr -d '\r' \
  | sed -E 's/^.*<!-- harness-status: stage=([^ ]+) issue=([0-9]+) outcome=([^ ]+) retries=([^ ]+) (deploy=[^ ]+) (harness=[^ ]+) -->.*$/\2 \1 \3 \4 \5 \6/' \
  | sed -E 's/^.*<!-- harness-status: stage=([^ ]+) issue=([0-9]+) outcome=([^ ]+) retries=([^ ]+) (deploy=[^ ]+) -->.*$/\2 \1 \3 \4 \5/' \
  | sed -E 's/^.*<!-- harness-status: stage=([^ ]+) issue=([0-9]+) outcome=([^ ]+) retries=([^ ]+) (harness=[^ ]+) -->.*$/\2 \1 \3 \4 \5/' \
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
  # deploy= is positional-independent inside the remaining fields, so a record with no
  # retries still works (e.g. a hand-written "17 merge merged deploy=verified").
  f_deploy="-"
  for tok in $_rest; do
    case "$tok" in deploy=*) f_deploy="${tok#deploy=}" ;; esac
  done
  if [ "$f_deploy" != "-" ] && [ "$f_stage" != "merge" ]; then
    die "deploy= field only valid for stage=merge, found on stage '$f_stage' in ledger record: $line"
  fi
  records="${records}${f_issue} ${f_stage} ${f_outcome} ${f_deploy}
"
done <<EOF
$norm
EOF

# --- live state --------------------------------------------------------------
if [ -n "$status_src" ]; then
  # See the ledger-read comment above (#336, sheet A4-A6): no access() pre-test on a path that
  # can be a /dev/fd/N process substitution. Attempt the read directly and die on failure instead.
  status_json="$(cat "$status_src" 2>/dev/null)" || die "cannot read status JSON file: $status_src"
else
  command -v harness-status.sh >/dev/null 2>&1 \
    || die "harness-status.sh not on the PATH — pass its JSON as the second argument"
  status_json="$(harness-status.sh </dev/null)" \
    || die "harness-status.sh failed (is gh authenticated?)"
fi
jq -e . >/dev/null 2>&1 <<<"$status_json" || die "status input is not valid JSON"
jq -e '.harness_will_handle' >/dev/null 2>&1 <<<"$status_json" \
  || die "status JSON has no .harness_will_handle — expected harness-status.sh output"

# --- degraded (#298) -----------------------------------------------------------------------
# A degraded live read means a query failed closed this run, so a harness_will_handle bucket
# below may under-report the true queue rather than reflect it — this reconciliation cannot
# then conclude "every queued issue accounted for" just because nothing else disagrees.
# Refuse (one line, forcing exit 1) on every degraded_reasons entry that does NOT start with
# "status." — including an unrecognised future prefix (fail toward the human) and
# "planning.author_association_unavailable" (which hides no harness_will_handle bucket at all;
# an accepted over-refusal — see the header's OUTPUT note). A "status." entry never refuses on
# its own: it describes a waiting_on_human bucket this reconciliation never compares. A
# degraded:true document whose degraded_reasons is empty or absent still gets one "unspecified"
# line rather than silence.
# --- degraded-lines-start ---
# escline (below) guarantees every refusing entry renders as exactly one non-empty stdout line no
# matter what characters it contains: tojson JSON-escapes EVERY control character it finds (an
# embedded newline, a bare NUL byte, a carriage return, and so on), so the raw reason is what
# startswith("status.") filters on, but the ESCAPED reason is what reaches emit() below — an entry
# that escapes to the empty string becomes a visible placeholder instead of a silently dropped
# blank line, and no entry's own characters can ever split it across lines or vanish. jq's own
# stderr is discarded on this call (2>/dev/null) so a malformed document's error() only surfaces
# once, through die's own message below.
degraded_lines="$(jq -r '
  def escline: (tojson | .[1:-1]) as $e
    | if $e == "" then "(empty reason)" else $e end;
  ((.degraded_reasons // []) | if type == "array" then . else error("x") end) as $r
  | [ $r[] | tostring | select(startswith("status.") | not) ] as $refuse
  | if ($refuse|length) > 0 then ($refuse[] | escline)
    elif (.degraded == true) and (($r|length) == 0) then "unspecified"
    else empty end
' <<<"$status_json" 2>/dev/null)" \
  || die "status JSON has a malformed degraded_reasons (expected an array)"
# --- degraded-lines-end ---

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
row_deploy() { printf '%s\n' "$records" | awk -v n="$1" -v s="$2" '$1==n && $2==s {d=$4} END{if (d!="") print d}'; }
has_rows()   { printf '%s\n' "$records" | awk -v n="$1" '$1==n {f=1} END{exit !f}'; }
in_bucket()  { printf '%s\n' "$live"    | awk -v b="$1" -v n="$2" '$1==b && $2==n {f=1} END{exit !f}'; }

issues="$( { printf '%s\n' "$records" | awk '{print $1}'
             printf '%s\n' "$live"    | awk '{print $2}'; } \
           | grep -E '^[0-9]+$' | sort -n -u )"

found=0
emit() { printf '%s\n' "$1"; found=1; }

# (#298) degraded lines print FIRST, before any per-issue line — see the header's OUTPUT note.
# This wording holds for every reason, including "planning.author_association_unavailable" and
# the "unspecified" backstop: it never names what the query was, only that a live read failed
# closed and this reconciliation cannot vouch for the queue it's comparing against. The refusal
# never cuts the per-issue comparison below short — nothing here exits; found=1 (set by emit())
# only turns the FINAL exit code non-zero.
# --- degraded-emit-start ---
while IFS= read -r reason; do
  [ -n "$reason" ] || continue
  emit "degraded issue=- bucket=- stage=-: harness-status.sh marked its live read degraded ($reason) — a query failed closed, so this reconciliation cannot confirm every queued issue is accounted for"
done <<DEGRADED
$degraded_lines
DEGRADED
# --- degraded-emit-end ---

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
    if [ "$s" = "merge" ]; then
      d="$(row_deploy "$n" "$s")"
      if [ -n "$d" ] && [ "$d" != "-" ] && ! in_deploy_vocab "$d"; then
        emit "unknown-outcome issue=$n bucket=- stage=$s: deploy outcome '$d' is not in the deploy vocabulary ($(printf '%s' "$DEPLOY_OUTCOMES" | tr ' ' '|'))"
      fi
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
