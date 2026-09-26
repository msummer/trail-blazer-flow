#!/usr/bin/env bash
#
# check-harness.sh — preflight "doctor" for the issue-workflow harness.
#
# Checks everything mechanical the harness needs in a repo: gh/jq, the git remote, the lifecycle
# labels, executable scripts, a CLAUDE.md with a verification section and a size guideline,
# LESSONS.md, the toolchain allow-list (checked against the three-file settings union — see
# below — read exclusively through jq, never a raw-text grep/sed/awk of any settings* path
# variable), whether a path-qualified verification interpreter (e.g. <repo>/api/.venv/bin/python,
# as worktree-parallel mode instructs) has a matching literal-path allow entry across the same
# three-file union the next clause names, whether the "Merge autonomy policy" section is
# activated by the effective merge-permission state across .claude/settings.json,
# .claude/settings.local.json, and the user-level settings file (a deny in any of them wins,
# regardless of allows elsewhere — union semantics, not just the checked-in file), whether an
# optional "Autonomy mode" section (#311) declares `mode: autonomous` — validated as a
# COMBINATION, not read as a single flag: it makes merge autonomy effectively active for harness
# PRs only even with no "Merge autonomy policy" section declared, so every WARN merge autonomy
# already has (half-activated, CI pinning, branch-protection strictness/contexts) fires from the
# implied state too, while a section the repo DOES declare still applies in full and can only
# narrow what the mode allows — the mode never lifts the `Bash(gh pr merge:*)` deny itself, only
# reports it, whether a consumer's CI workflows and every action.yml/action.yaml anywhere in the
# repo pin every `uses:` ref to a full 40-hex commit SHA rather than a mutable tag or branch, when
# merge autonomy is effectively active (#166, #179, #186 — under merge autonomy the cycle merges
# on "CI green", so a repointed tag would change what CI runs with no diff visible in this repo;
# string comparison only — never executes, evals, or expands anything read from a workflow file or
# an action.yml/action.yaml anywhere in the repo), whether its optional "Post-merge verification"
# declaration is present and, if so, fenced (declared/no-fence/not-declared — never whether the
# declared commands are any good; gated on a declared "Merge autonomy policy" section only, never
# on the "Autonomy mode" implication) and whether each declared command's first token has a
# matching allow entry in that same three-file union, whether a "Test-suite ratchet policy"
# section exists and names a measurement command via a fence-aware, depth-aware section slice
# (looked up with `command -v`, never executed), whether "Autonomy reserve" and "Autonomy decision
# record" sections are declared and well-formed (and, when gh is ready, whether the declared grant
# label exists — never applied, removed, or judged for content), and, only in autonomous mode,
# each settings file's `permissions.defaultMode` value (a validated bare word only — never an
# allow/deny entry from any of the three files), the verification baseline
# (.claude/BASELINE.md, machine-local — an abbreviated recorded commit SHA of 7+ hex characters
# is accepted as a prefix), whether the template's branch-scoped deny entries actually cover this
# repo's default branch, whether any of the three settings files disables all hooks (silently
# disabling the plugin's `git -C` guard hook, and every other hook), whether
# `.claude/settings.json` still carries legacy `Bash(git -C * <sub> *)` allow entries the guard
# hook now supersedes (#150 — Claude Code 2.1.246+ warns about these at startup), the installed
# harness plugin's own version and short commit SHA (#233, via bin/harness-version.sh, run by a
# fixed path — never derived from repo content), and branch protection — presence (WARN on
# Claude Code; FAIL under `--provider codex`), plus, only when merge autonomy is effectively
# active (a declared "Merge autonomy policy" section, or an
# "Autonomy mode" section's implied merge autonomy) and the protection endpoint call succeeds,
# whether required_status_checks.strict is true, the number of required status check contexts,
# and whether required PR reviews are configured (#234 — all three WARN-only, never FAIL), and
# (#331, folds in #330) whether an optional "Governance paths" section — read by the merge floor's
# own governance-path classifier, bin/governance-paths.sh, run here by a FIXED path (same
# precedent as bin/harness-version.sh) via its `--check` mode — is absent, declared (naming the
# glob count), or malformed (naming the reason token); never FAILs, and never runs the classifier
# against anything but this repo's own CLAUDE.md.
#
# --provider codex (#410, default: claude) runs a different, additive check set after the shared
# preamble above instead of the settings/toolchain/policy-activation checks below (all skipped on
# Codex — wrapped in one unindented `if [ "$provider" = claude ]; then … fi`): a Codex version
# floor (top-level CODEX_MIN_VERSION), whitespace in the plugin/repo path, bin/codex-setup.sh
# --check drift (#408), a bounded codex app-server hooks/list exchange that only ever REPORTS
# hook trust (auto-trusting would defeat Codex's own review gate — it never writes trust state),
# and a manual-merge report (merge autonomy does not exist on Codex). The shared baseline and
# branch-protection checks below still run afterward, unchanged except that a missing/unreadable
# branch-protection document is a FAIL rather than a WARN on Codex. See docs/reference/codex.md's
# "The doctor on Codex" section for the fix for each FAIL.
#
# The test-suite-ratchet check never executes, evals, or shells out to anything read from
# CLAUDE.md: it only looks up the measurement command's first word with `command -v` (a lookup,
# not an execution) and prints it back, quoted, as a report. The post-merge-verification
# declaration-state check carries a related guarantee: it never executes, evals, `command -v`'s,
# or expands a declared command either — the derived values it prints are an integer count of
# fenced command lines and, when a declared command's first token has no matching allow entry, a
# WARN echoing that token and the literal `Bash(<token>:*)` entry to add, produced by a pure
# string comparison (entry_has) against the three-file settings allow-list union, never a lookup
# or an execution.
#
# Read-only except two safe, idempotent fixes it applies automatically:
#   - chmod +x on the harness's own scripts
#   - seeding an empty .claude/LESSONS.md if the project has none
# On --provider codex, it also creates and removes a temp dir under ${TMPDIR:-/tmp} and briefly
# starts the user's own `codex app-server` to read (never write) hook trust state — the repo
# itself is still written only by the two fixes above.
#
# Quality judgments (is CLAUDE.md actually good enough? do the verification commands
# pass?) are NOT this script's job — that's the harness-setup skill, which runs this
# script first and then does the audit.
#
# Exit 0 = no FAILs (WARNs allowed). Exit 1 = at least one FAIL. Exit 2 = usage error
# (--provider requires claude or codex; see -h/--help).
set -uo pipefail

pass=0; warn=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
wrn() { echo "  WARN  $1"; warn=$((warn+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

# has_policy_section TITLE — does $root/CLAUDE.md have a heading matching TITLE exactly (any
# '#' depth, case-sensitive, no trailing text)? '#+', not an interval expression, because
# interval expressions are portable in `grep -E` but not guaranteed in every `awk`, and the
# ratchet section-slice below uses awk with the same shape. Exact match is the contract wording
# all three skills use ("a section titled exactly …").
has_policy_section() { grep -qE "^#+[[:space:]]+$1[[:space:]]*\$" "$root/CLAUDE.md"; }

# entry_has LIST PREFIX — literal prefix test over a newline-separated entry list (no regex),
# mirroring how Claude Code matches Bash permission rules against a command string. Top-level
# (not scoped to .claude/settings.json) because the merge-autonomy scan below applies it across
# every settings file it reads: .claude/settings.json, .claude/settings.local.json, and the
# user-level settings file.
entry_has() { printf '%s\n' "$1" | awk -v p="$2" 'index($0, p) == 1 { hit = 1 } END { exit !hit }'; }

# bt — a single backtick, hoisted here (was previously local to the test-suite-ratchet check
# below) so both that check and the verification-scope candidate scan (see
# claude_md_verification_scope/verification_candidates below) can build the same documented
# grep -o "${bt}...${bt}" backtick-quoted-span heuristic without a second, drifting copy.
bt="$(printf '\140')"

# claude_md_section TITLE — depth-aware, fence-aware slice of $root/CLAUDE.md: starts right
# after the heading matching TITLE exactly (any '#' depth, same match shape as
# has_policy_section) and ends only at the next heading-shaped line OUTSIDE a fenced block whose
# '#' depth is <= the starting heading's own depth — so a deeper sub-heading nested under TITLE
# (e.g. "### Post-merge verification" under "## Merge autonomy policy") does NOT end the slice,
# only a sibling-or-shallower heading does. Fence-aware like bin/check-decision-record.sh's
# claude_md_block (a '#'-prefixed comment inside a fenced block is not a heading — see
# .claude/LESSONS.md); depth-aware unlike it, which is why that idiom (also used by the
# scoped-autonomy reserve/record slices below) isn't reused here: it would stop at the very
# sub-heading this exists to see past. Fence-delimiter lines are included in the output (so a
# downstream first-fence extractor can still find them), same as claude_md_block.
claude_md_section() {
  awk -v t="$1" '
    $0 ~ "^#+[[:space:]]+" t "[[:space:]]*$" { inx=1; match($0, /^#+/); d=RLENGTH; next }
    inx && /^```/ { infence = !infence }
    inx && !infence && /^#+[[:space:]]/ {
      match($0, /^#+/)
      if (RLENGTH <= d) exit
    }
    inx { print }
  ' "$root/CLAUDE.md"
}

# has_verification_heading — is there a heading in $root/CLAUDE.md whose text, lower-cased,
# starts with "verification"? The CLAUDE.md contract only asks for the verification commands to
# live "ideally under a clearly labelled 'Verification' section" (not an exact title, unlike the
# policy sections above), so this is a looser, case-insensitive prefix match, not
# has_policy_section's exact one.
# Capture-then-test (#255), not the awk piped into `grep`'s quiet mode: that early-exit reader
# exits on its first match, which can send the awk writer SIGPIPE — awk's own `exit` already
# makes it an early-exit reader of $root/CLAUDE.md too, but that's a direct file read, not a pipe,
# so it carries no writer to signal — and, under this file's `set -uo pipefail`, a piped `grep -q`
# on top could turn a genuine match into a reported pipeline failure. Capturing first removes the
# second pipe entirely.
has_verification_heading() {
  local hit
  hit="$(awk '
    /^#+[[:space:]]/ {
      h = $0
      sub(/^#+[[:space:]]+/, "", h)
      sub(/[[:space:]]+$/, "", h)
      if (tolower(h) ~ /^verification/) { print "found"; exit }
    }
  ' "$root/CLAUDE.md")"
  [ -n "$hit" ]
}

# claude_md_verification_scope — depth-aware, fence-aware slice (same shape as
# claude_md_section) of $root/CLAUDE.md starting at the first heading matched by
# has_verification_heading. Only ever called after has_verification_heading confirms one exists
# — see the whole-file fallback (Q2, ACCEPTED) at the call site below.
claude_md_verification_scope() {
  awk '
    !inx && /^#+[[:space:]]/ {
      h = $0
      sub(/^#+[[:space:]]+/, "", h)
      sub(/[[:space:]]+$/, "", h)
      if (tolower(h) ~ /^verification/) { inx=1; match($0, /^#+/); d=RLENGTH; next }
    }
    inx && /^```/ { infence = !infence }
    inx && !infence && /^#+[[:space:]]/ {
      match($0, /^#+/)
      if (RLENGTH <= d) exit
    }
    inx { print }
  ' "$root/CLAUDE.md"
}

# verification_candidates SCOPE — extracts candidate command strings from a verification-scope
# slice (or the whole file, when there's no "Verification…" heading — Q2, ACCEPTED: coverage
# over precision, since the only outcome downstream is a WARN naming a grant, never a FAIL or an
# action): every non-blank line inside ANY fenced block, plus every backtick-quoted span outside
# one (the same documented grep -o "${bt}...${bt}" heuristic the test-suite ratchet uses below).
# One candidate per output line. Consumed only to look up an interpreter token's basename below
# — never executed, eval'd, or expanded.
verification_candidates() {
  printf '%s\n' "$1" | awk '
    /^```/ { infence = !infence; next }
    infence && NF { print }
  '
  printf '%s\n' "$1" | grep -o "${bt}[^${bt}]*${bt}" | tr -d "$bt"
}

# --- arguments (#410) -----------------------------------------------------------
# --provider selects the check set: claude (default, unchanged) or codex. Parsed before any
# check runs, so a usage error (exit 2) never leaves a partial report on stdout.
usage() {
  cat <<'EOF'
usage: check-harness.sh [--provider claude|codex]
       check-harness.sh -h|--help

--provider selects which checks run: claude (default) or codex.
EOF
}

provider=claude
while [ $# -gt 0 ]; do
  case "$1" in
    --provider)
      if [ $# -lt 2 ]; then
        echo "check-harness.sh: --provider needs a value (claude or codex)" >&2
        usage >&2
        exit 2
      fi
      provider="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "check-harness.sh: unrecognized argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done
case "$provider" in
  claude|codex) : ;;
  *)
    echo "check-harness.sh: unknown --provider value: $provider (expected claude or codex)" >&2
    usage >&2
    exit 2
    ;;
esac

if [ "$provider" = codex ] && ! command -v git >/dev/null 2>&1; then
  echo "  FAIL  git not installed"
  exit 1
fi

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "  FAIL  not inside a git repository"; exit 1; }
cd "$root"
claude_dir="$root/.claude"
if [ "$provider" = codex ]; then
  echo "== harness doctor (codex): $root =="
else
  echo "== harness doctor: $root =="
fi

# --- git remote ---------------------------------------------------------------
if git remote get-url origin >/dev/null 2>&1; then
  ok "git remote 'origin' configured"
else
  bad "no 'origin' remote — the implementer pushes branches and opens PRs against origin"
fi

# --- gh -----------------------------------------------------------------------
gh_ready=false
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "gh installed and authenticated"
    gh_ready=true
  else
    bad "gh installed but not authenticated — run: gh auth login"
  fi
else
  bad "gh (GitHub CLI) not installed"
fi

# --- jq -----------------------------------------------------------------------
jq_ready=false
jq_fail_msg="jq not installed — the discovery scripts need it"
if [ "$provider" = codex ]; then
  jq_fail_msg="${jq_fail_msg}, and on Codex the plugin's hooks (hooks/planner-guard.sh included) fail open without it"
fi
if command -v jq >/dev/null 2>&1; then
  ok "jq installed"
  jq_ready=true
else
  bad "$jq_fail_msg"
fi

# --- default branch -----------------------------------------------------------
# tr -d '\r' on gh outputs used in comparisons/paths: gh itself emits LF, but a
# CRLF-translating layer between gh and Bash (some Windows/WSL interop setups) would
# otherwise poison exact-match greps and command arguments.
default_branch=""
if $gh_ready; then
  default_branch="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null | tr -d '\r' || true)"
fi
if [ -n "$default_branch" ]; then
  ok "default branch: $default_branch"
else
  wrn "could not determine the default branch via gh (remote/auth issue?)"
fi

# --- lifecycle labels ---------------------------------------------------------
existing=""
if $gh_ready; then
  existing="$(gh label list --limit 200 --json name --jq '.[].name' 2>/dev/null | tr -d '\r' || true)"
  missing=""
  for l in plan-proposed plan-approved pr-open impl-blocked no-plan no-auto-approve test-ratchet multi-pr needs-human harness-stop triaged-held; do
    # Here-string, not an `echo` writer piped into `grep`'s quiet mode (#255): that early-exit
    # reader exits on its first match, which can send the echo writer SIGPIPE and, under this
    # file's `set -uo pipefail`, turn a genuine match into a reported pipeline failure.
    grep -qx -- "$l" <<<"$existing" || missing="$missing $l"
  done
  if [ -z "$missing" ]; then
    ok "all 11 lifecycle labels exist"
  else
    bad "missing labels:$missing — run: setup-labels.sh"
  fi
else
  wrn "skipped label check (gh not ready)"
fi

# --- harness scripts executable (auto-fix) -------------------------------------
# The harness scripts live alongside this one (the plugin's bin/).
script_dir="$(cd "$(dirname "$0")" && pwd)"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    # NTFS has no POSIX exec bit: Git Bash emulates one from the shebang, so chmod is a
    # no-op here and a "fixed it" message would be theatre. The real Windows risks —
    # CRLF corruption and bin/ not on the PATH — are both exercised by the fact that
    # this script is running at all (see the README's Windows smoke test).
    ok "harness scripts runnable (Windows: exec bits are emulated from the shebang; chmod check not applicable)"
    ;;
  *)
    fixed=""
    for s in "$script_dir"/*.sh; do
      [ -f "$s" ] || continue
      if [ ! -x "$s" ]; then chmod +x "$s" && fixed="$fixed $(basename "$s")"; fi
    done
    if [ -n "$fixed" ]; then
      ok "harness scripts executable (auto-fixed:$fixed)"
    else
      ok "harness scripts are executable"
    fi
    ;;
esac

# --- harness version (#233) -----------------------------------------------------
# Runs bin/harness-version.sh by a FIXED path — $script_dir/harness-version.sh, alongside this
# script — never a path derived from repo content, so the doctor's guarantee that it never
# executes anything read from CLAUDE.md stays untouched. Reports the script's own printed
# "<version> <sha>" line verbatim on success. Missing, non-executable, or a non-zero exit (e.g. no
# .claude-plugin/plugin.json alongside a repo that copied the harness's bin/ scripts into its own
# .claude/ rather than installing the plugin) is a WARN, never a FAIL — this doctor never blocks a
# run on a fact this cosmetic.
hv_script="$script_dir/harness-version.sh"
if [ -x "$hv_script" ] && hv_out="$("$hv_script" 2>/dev/null)" && [ -n "$hv_out" ]; then
  ok "harness version: $hv_out"
else
  wrn "could not determine the installed harness version — expected $hv_script to print '<version> <sha>' (run it directly for the diagnostic)"
fi

# --- CLAUDE.md ----------------------------------------------------------------
if [ -f "$root/CLAUDE.md" ]; then
  if grep -qiE '(verif|## *test|test suite|typecheck|lint gate|npm run build|pytest|cargo test|go test|make test)' "$root/CLAUDE.md"; then
    ok "CLAUDE.md present with a verification-ish section (quality audit = harness-setup skill)"
  else
    wrn "CLAUDE.md present but no verification/test section found — subagents won't know what 'done' means; run the harness-setup skill"
  fi
  # Mechanical proxy for "too much and the contract drowns in restatement" (README, "The
  # CLAUDE.md contract"): the file is re-read by the planner, implementer, and verifier on
  # every dispatch and every retry, so its cost is multiplied by the run, not paid once.
  # tr -d strips the leading spaces BSD `wc` pads its output with.
  cm_lines="$(wc -l < "$root/CLAUDE.md" | tr -d '[:space:]')"
  cm_bytes="$(wc -c < "$root/CLAUDE.md" | tr -d '[:space:]')"
  if [ "$cm_lines" -gt 300 ] || [ "$cm_bytes" -gt 20000 ]; then
    wrn "CLAUDE.md size: $cm_lines lines / $cm_bytes bytes — over the 300-line/20000-byte guideline; run the harness-setup skill's leanness audit to trim restatement (directory tours, framework defaults, formatter-enforced style — not the contract's ten items themselves)"
  else
    ok "CLAUDE.md size: $cm_lines lines / $cm_bytes bytes"
  fi
else
  bad "no CLAUDE.md — the harness contract requires one (conventions + verification commands); the harness-setup skill can draft it"
fi

# --- LESSONS.md (auto-seed) ----------------------------------------------------
if [ -f "$claude_dir/LESSONS.md" ]; then
  ok "LESSONS.md present"
else
  mkdir -p "$claude_dir"
  cat > "$claude_dir/LESSONS.md" <<'EOF'
# Project lessons for workflow subagents

Project-specific gotchas that the issue-planner and issue-implementer skills inject into
every subagent prompt. **This file is owned by THIS project** — it stays with the repo if
the skills toolset is updated or reinstalled. Append a dated entry whenever something
bites: 1–3 lines, written as an instruction to a future agent.

(No lessons yet.)
EOF
  ok "seeded empty .claude/LESSONS.md (project-owned; append dated gotchas as they bite)"
fi

# --- top-level literals (anchored `NAME="..."` lines, never indented) --------------------------
# PROTECTION_STRICT_WARN_STEM/PROTECTION_CHECKS_WARN_STEM (#234) are matched verbatim against
# dev/doctor-tests.sh by dev/selfcheck.sh assertion 4.38 — keep them anchored, top-level
# `NAME="..."` literals so the assertion's sed extraction keeps working, and never let either
# contain the substring "no checks configured" (a different, unrelated WARN in the settings
# section) or "branch protection enabled on" (the PASS line in the branch-protection section). CODEX_MIN_VERSION and CODEX_HOOKS_LIST_WAIT (#410) are grouped here for the
# same reason — every top-level literal a fixture or a mutant might anchor on lives in one place —
# even though both are consumed only inside the Codex block below, well before branch protection
# runs; a plain top-level assignment is visible to everything that runs after it, so the physical
# distance to branch protection's own use of the WARN stems is not a problem.
PROTECTION_STRICT_WARN_STEM="branch protection: up-to-date branches are not required"
PROTECTION_CHECKS_WARN_STEM="branch protection: zero required status check contexts"
CODEX_MIN_VERSION="0.156.1"
CODEX_HOOKS_LIST_WAIT=15

# --- Codex checks (#410) ---------------------------------------------------------------------
# --provider codex runs this block instead of the settings/toolchain/policy-activation checks
# wrapped in the Claude-only `if` just below: a Codex version floor, plugin/repo path whitespace,
# bin/codex-setup.sh's own --check drift, a bounded codex app-server hooks/list exchange that
# only ever REPORTS hook trust (never grants it — auto-trusting would defeat Codex's own review
# gate), and a manual-merge report. merge_effective stays false: the branch-protection section
# further down reads it (skipping the strictness sub-checks, which are merge-autonomy-gated), the
# Claude-only hoist that normally sets it is skipped on Codex, and merge autonomy doesn't exist
# on Codex at all.
if [ "$provider" = codex ]; then
  merge_effective=false

  # --- Codex version ------------------------------------------------------------
  cx_found=false
  if command -v codex >/dev/null 2>&1; then
    cx_found=true
    cx_version_line="$(codex --version 2>/dev/null | head -1)"
    cx_triple="$(printf '%s\n' "$cx_version_line" | sed -nE 's/^[^0-9]*([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9}).*/\1 \2 \3/p')"
    if [ -z "$cx_triple" ]; then
      bad "codex version: could not parse"
    else
      cx_min_triple="$(printf '%s\n' "$CODEX_MIN_VERSION" | sed -nE 's/^([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})$/\1 \2 \3/p')"
      cx_maj="$(printf '%s' "$cx_triple" | awk '{print $1}')"
      cx_min="$(printf '%s' "$cx_triple" | awk '{print $2}')"
      cx_pat="$(printf '%s' "$cx_triple" | awk '{print $3}')"
      cx_min_maj="$(printf '%s' "$cx_min_triple" | awk '{print $1}')"
      cx_min_min="$(printf '%s' "$cx_min_triple" | awk '{print $2}')"
      cx_min_pat="$(printf '%s' "$cx_min_triple" | awk '{print $3}')"
      cx_version="$((10#$cx_maj)).$((10#$cx_min)).$((10#$cx_pat))"
      cx_ge=false
      if [ "$((10#$cx_maj))" -gt "$((10#$cx_min_maj))" ]; then
        cx_ge=true
      elif [ "$((10#$cx_maj))" -eq "$((10#$cx_min_maj))" ]; then
        if [ "$((10#$cx_min))" -gt "$((10#$cx_min_min))" ]; then
          cx_ge=true
        elif [ "$((10#$cx_min))" -eq "$((10#$cx_min_min))" ]; then
          [ "$((10#$cx_pat))" -ge "$((10#$cx_min_pat))" ] && cx_ge=true
        fi
      fi
      if $cx_ge; then
        ok "codex version: $cx_version"
      else
        bad "codex version: $cx_version is below the supported floor $CODEX_MIN_VERSION"
      fi
    fi
  else
    bad "codex version: codex not installed"
  fi

  # --- Codex plugin/repo paths ----------------------------------------------------
  cx_plugin_root="$(cd "$script_dir/.." && pwd)"
  # cx_has_ws VALUE — does VALUE contain whitespace? Shared by both path checks below, so one
  # mutation to this single case arm breaks detection for both.
  cx_has_ws() {
    case "$1" in
      *[[:space:]]*) return 0 ;;
      *) return 1 ;;
    esac
  }
  cx_paths_ok=true
  if cx_has_ws "$cx_plugin_root"; then
    bad "codex plugin paths: the plugin root contains whitespace"
    cx_paths_ok=false
  fi
  if cx_has_ws "$root"; then
    bad "codex plugin paths: the repo path contains whitespace"
    cx_paths_ok=false
  fi
  $cx_paths_ok && ok "codex plugin paths: no whitespace in the plugin root or repo path"

  # --- Codex setup in sync (bin/codex-setup.sh --check, #408) ----------------------
  cx_setup="$script_dir/codex-setup.sh"
  if [ -x "$cx_setup" ]; then
    cx_setup_out="$(cd "$root" && "$cx_setup" --check 2>/dev/null)"
    cx_setup_rc=$?
  else
    cx_setup_out=""
    cx_setup_rc=127
  fi
  case "$cx_setup_rc" in
    0) ok "codex setup: in sync" ;;
    1)
      cx_setup_lines="$(printf '%s\n' "$cx_setup_out" | grep -E '^(drift|unsupported)=')"
      n_missing="$(printf '%s\n' "$cx_setup_lines" | grep -c .)"
      more=""; [ "$n_missing" -gt 6 ] && more=" (+$((n_missing-6)) more)"
      cx_setup_list="$(printf '%s\n' "$cx_setup_lines" | head -6 | tr '\n' ',' | sed 's/,/, /g; s/, $//')"
      bad "codex setup: out of sync: $cx_setup_list$more — run bin/codex-setup.sh from a normal terminal to re-sync"
      ;;
    *) bad "codex setup: could not check (missing, not executable, or exited $cx_setup_rc)" ;;
  esac

  # --- Codex plugin version (#410) — the initialize request's clientInfo
  # names this doctor and the installed plugin's own version, or "0" when it can't be resolved
  # (missing/unreadable/unparseable plugin.json, or jq not ready); a real codex app-server (0.156.1
  # confirmed live) rejects initialize outright without clientInfo, so a doctor that omitted it
  # could never reach hooks/list at all.
  cx_client_version="0"
  if $jq_ready; then
    cx_v="$(jq -r '.version // empty' "$cx_plugin_root/.claude-plugin/plugin.json" 2>/dev/null)"
    [ -n "$cx_v" ] && [ "$cx_v" != "null" ] && cx_client_version="$cx_v"
  fi

  # --- Codex hook trust (bounded codex app-server hooks/list exchange) -------------
  # cx_expected — the plugin's own hook script basenames, derived from hooks/hooks.json. Computed
  # up front, before ever starting codex app-server: an empty result —
  # from a missing, unreadable, or unparseable hooks.json, or one with no recognisable hook
  # entries — fails the same "can't tell" way as codex/jq being absent, rather than only being
  # caught later (or not at all) once the exchange has already run.
  cx_expected="$(jq -r '.hooks[][]?.hooks[]?.command // empty' "$cx_plugin_root/hooks/hooks.json" 2>/dev/null | sed -n 's|.*/hooks/\([A-Za-z0-9._-]*\.sh\).*|\1|p')"
  cx_reply=""
  # cx_hooks_list — starts `codex app-server`, sends exactly two JSON-RPC requests plus the
  # `initialized` notification through a background pipeline writer (initialize with clientInfo,
  # initialized, hooks/list with params.cwds == [$root]), polls in THIS shell (bounded, at most
  # CODEX_HOOKS_LIST_WAIT + 2 one-second polls) for the process to exit on its own once it has
  # emitted the id==2 reply, kills it if it hasn't, then signals the writer to stop and waits for
  # it (bounded — the writer notices within a second) before extracting $cx_reply (the id==2 line,
  # or empty on no reply). Never sends anything but those two requests and the notification; never
  # trusts anything — read-only throughout.
  cx_hooks_list() {
    local tmp req_init req_inited req_hooks pid n m have
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/tbf-codex-hooks.XXXXXX" 2>/dev/null)" || return 1
    req_init="$(jq -cn --arg version "$cx_client_version" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"check-harness","version":$version}}}')"
    req_inited="$(jq -cn '{"jsonrpc":"2.0","method":"initialized","params":{}}')"
    req_hooks="$(jq -cn --arg cwd "$root" '{"jsonrpc":"2.0","id":2,"method":"hooks/list","params":{"cwds":[$cwd]}}')"
    (
      printf '%s\n%s\n%s\n' "$req_init" "$req_inited" "$req_hooks"
      n=0
      while [ "$n" -lt "$CODEX_HOOKS_LIST_WAIT" ]; do
        [ -f "$tmp/done" ] && break
        have="$(jq -R -c 'fromjson? | select(type=="object" and .id==2)' "$tmp/out" 2>/dev/null | head -1)"
        [ -n "$have" ] && break
        sleep 1
        n=$((n+1))
      done
    ) 2>/dev/null | codex app-server >"$tmp/out" 2>"$tmp/err" &
    pid=$!
    m=0
    while [ "$m" -lt "$((CODEX_HOOKS_LIST_WAIT + 2))" ]; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
      m=$((m+1))
    done
    kill "$pid" 2>/dev/null
    : >"$tmp/done"
    wait 2>/dev/null
    cx_reply="$(jq -R -c 'fromjson? | select(type=="object" and .id==2)' "$tmp/out" 2>/dev/null | head -1)"
    rm -rf "$tmp"
  }

  cx_hooks_fix=" — trust the hooks in Codex (its hook review, \"Trust all\"), because Codex skips an untrusted hook silently; see docs/reference/codex.md"
  if ! $cx_found; then
    bad "hook trust: could not check (codex not installed)"
  elif ! $jq_ready; then
    bad "hook trust: could not check (jq not installed)"
  elif [ -z "$cx_expected" ]; then
    bad "hook trust: could not check (could not determine the plugin's hooks — hooks/hooks.json is missing, unreadable, or unparseable)"
  else
    cx_hooks_list
    if [ -z "$cx_reply" ]; then
      bad "hook trust: no hooks/list reply$cx_hooks_fix"
    else
      cx_has_error="$(printf '%s' "$cx_reply" | jq -r 'if .error then "true" else "false" end' 2>/dev/null)"
      if [ "$cx_has_error" = "true" ]; then
        bad "hook trust: codex app-server rejected hooks/list$cx_hooks_fix"
      else
        cx_has_cfg_errors="$(printf '%s' "$cx_reply" | jq -r 'if ([.result.data[]?.errors[]?] | length) > 0 then "true" else "false" end' 2>/dev/null)"
        if [ "$cx_has_cfg_errors" = "true" ]; then
          bad "hook trust: Codex reported hook configuration error(s)$cx_hooks_fix"
        else
          cx_loaded="$(printf '%s' "$cx_reply" | jq -r '.result.data[]?.hooks[]? | select(.source=="plugin" and .enabled!=false) | .command' 2>/dev/null)"
          cx_missing=""
          while IFS= read -r cx_hook_name; do
            [ -n "$cx_hook_name" ] || continue
            grep -qF -- "/hooks/$cx_hook_name" <<<"$cx_loaded" || cx_missing="$cx_missing $cx_hook_name"
          done <<EOF
$cx_expected
EOF
          if [ -n "$cx_missing" ]; then
            bad "hook trust: plugin hook(s) not loaded by Codex:$cx_missing$cx_hooks_fix"
          else
            cx_untrusted="$(printf '%s' "$cx_reply" | jq -r '
              .result.data[]?.hooks[]? |
              select(.enabled!=false and (.trustStatus!="trusted" and .trustStatus!="managed")) |
              "\(.source):\(.key|gsub("[^A-Za-z0-9._:/@-]";"?")) (\(.trustStatus))"
            ' 2>/dev/null)"
            if [ -n "$cx_untrusted" ]; then
              n_missing="$(printf '%s\n' "$cx_untrusted" | grep -c .)"
              more=""; [ "$n_missing" -gt 6 ] && more=" (+$((n_missing-6)) more)"
              cx_untrusted_list="$(printf '%s\n' "$cx_untrusted" | head -6 | tr '\n' ',' | sed 's/,/, /g; s/, $//')"
              bad "hook(s) not trusted: $cx_untrusted_list$more$cx_hooks_fix"
            else
              ok "hook trust: every hook Codex loads for this repo is trusted"
            fi
          fi
        fi
      fi
    fi
  fi

  # --- manual merge (Codex has no merge autonomy) ----------------------------------
  cx_merge_names=""
  if [ -f "$root/CLAUDE.md" ]; then
    has_policy_section "Merge autonomy policy" && cx_merge_names="${cx_merge_names}'Merge autonomy policy', "
    has_policy_section "Autonomy mode" && cx_merge_names="${cx_merge_names}'Autonomy mode', "
    cx_merge_names="${cx_merge_names%, }"
  fi
  if [ -n "$cx_merge_names" ]; then
    ok "merge: manual on Codex — $cx_merge_names does not apply here; merge autonomy doesn't exist on Codex, so every PR merge is manual"
  else
    ok "merge: manual on Codex — every PR merge is manual"
  fi
fi

if [ "$provider" = claude ]; then  # Claude Code-only checks (settings, toolchain, hooks toggle, policy activation) — skipped with --provider codex; closes at "end of Claude Code-only checks"
# --- settings-file candidates: the three-file union (#66, #147) ------------------------------
# The three files whose union this script consults more than once: the merge-autonomy verdict
# below (deny-and-allow-aware, via merge_deny_src/merge_allow_src — never $allow_union), the
# bare-name toolchain allow-list check and the path-qualified interpreter probe — both via
# allow_union — in the toolchain block right after this one, and the post-merge allow-entry
# check — also via allow_union — further down, in the post-merge-verification block under
# "policy activation state" (all three allow-only; none of them looks at deny — that asymmetry is
# unchanged from before this union existed). Read ONLY through jq (every settings-file path
# variable in this script is named settings*, so dev/selfcheck.sh's assertion 4.11 catches a
# raw-text read of any of them).
settings="$claude_dir/settings.json"
settings_local="$claude_dir/settings.local.json"
settings_user="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/settings.json"
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  settings_user_label="$CLAUDE_CONFIG_DIR/settings.json"
else
  settings_user_label="~/.claude/settings.json"
fi

# Per-file scan, read ONLY through jq (see above, and #66). NEVER piped from the heredoc's
# producer side — a `| while read` here would run the loop in a subshell and lose every
# accumulator below the moment the loop exits (same idiom as diff_side/guard_missing further
# down). The user-level file is read no differently than the other two — same two jq paths,
# .permissions.deny[]?/.permissions.allow[]? — and only ever contributes its LABEL to
# merge_deny_src/merge_allow_src, its allow entries to allow_union, and (#311) a SANITISED
# `permissions.defaultMode` bare word to default_mode_report; no entry from it, nor anything else
# in the file, is ever printed, diffed, or counted on its own — defaultMode is the sole,
# deliberate carve-out from that rule, and only a value matching `[A-Za-z]+` exactly is ever
# printed (anything else prints as the fixed string "(unrecognised value)", never echoed), and
# only when "Autonomy mode" is on (see the autonomy-mode block below). allow_union is only ever
# consumed by entry_has and allow_has, both boolean tests (entry_has a literal-prefix test,
# allow_has a regex prefix test) — neither ever prints an entry: never print allow_union or any
# slice of it in a verdict, or a user's private grants would leak into doctor output.
broken_list=""
read_list=""
merge_deny_src=""
merge_allow_src=""
disable_hooks_src=""
allow_union=""
default_mode_report=""
if $jq_ready; then
  while IFS='|' read -r settings_file settings_label; do
    [ -n "$settings_file" ] || continue
    [ -f "$settings_file" ] || continue
    if ! jq -e . "$settings_file" >/dev/null 2>&1; then
      broken_list="$broken_list$settings_label, "
      continue
    fi
    read_list="$read_list$settings_label, "
    file_deny="$(jq -r '.permissions.deny[]? // empty' "$settings_file" 2>/dev/null)"
    file_allow="$(jq -r '.permissions.allow[]? // empty' "$settings_file" 2>/dev/null)"
    entry_has "$file_deny" "Bash(gh pr merge" && merge_deny_src="$merge_deny_src$settings_label, "
    entry_has "$file_allow" "Bash(gh pr merge" && merge_allow_src="$merge_allow_src$settings_label, "
    allow_union="${allow_union}${file_allow}"$'\n'
    file_disable="$(jq -r '.disableAllHooks? // empty' "$settings_file" 2>/dev/null)"
    [ "$file_disable" = "true" ] && disable_hooks_src="$disable_hooks_src$settings_label, "
    file_default_mode="$(jq -r '.permissions.defaultMode? // empty' "$settings_file" 2>/dev/null)"
    if [ -z "$file_default_mode" ]; then
      dm_display="(unset)"
    else
      case "$file_default_mode" in
        *[!A-Za-z]*) dm_display="(unrecognised value)" ;;
        *) dm_display="$file_default_mode" ;;
      esac
    fi
    default_mode_report="$default_mode_report$settings_label: $dm_display, "
  done <<EOF
$settings|.claude/settings.json
$settings_local|.claude/settings.local.json
$settings_user|$settings_user_label
EOF
fi
broken_list="${broken_list%, }"
read_list="${read_list%, }"
merge_deny_src="${merge_deny_src%, }"
merge_allow_src="${merge_allow_src%, }"
disable_hooks_src="${disable_hooks_src%, }"
default_mode_report="${default_mode_report%, }"

# --- settings.json toolchain allow-list ----------------------------------------
# Read only through jq below — never a raw-text grep/sed/awk of any settings* path variable
# (every settings-file path variable in this script is named settings*, so dev/selfcheck.sh's
# assertion 4.11 catches a raw-text read of any of them). A raw-text read makes a rule merely
# *mentioned* in an unrelated string (an env value, a comment-ish string) count as present, and
# can't tell the allow array from the deny array (a deny-side `-C` mirror pasted into the allow
# array would still read as "present" to a whole-file grep). Pre-initialise allow_raw/deny_raw
# unconditionally: the script runs under set -u. The harness-script sentinel, template-drift,
# stale-`-C`-allow WARN, and #54 guard-coverage checks below judge .claude/settings.json by
# design (it is the shared, checked-in file) and read $allow_raw, not the union. The
# merge-autonomy verdict below consumes the same three-file scan too, but via
# merge_deny_src/merge_allow_src (deny-aware), never $allow_union. The bare-name toolchain
# allow-list check (allow_has, right below), the path-qualified interpreter probe (below, in this
# same toolchain block), and the post-merge allow-entry check (further down, in the
# post-merge-verification block under "policy activation state") all read the three-file
# $allow_union computed above instead — they judge effective permission, not just this file — see
# the "settings-file candidates" block.
allow_raw=""
deny_raw=""
allow_list_read=false
if [ ! -f "$settings" ]; then
  bad "no .claude/settings.json — create one from the plugin's templates/repo-settings.json (permissions + enabledPlugins); plugins cannot ship permission grants"
elif ! $jq_ready; then
  wrn "skipped the .claude/settings.json permission checks (jq not installed — see the FAIL above)"
elif ! jq -e . "$settings" >/dev/null 2>&1; then
  bad ".claude/settings.json does not parse as JSON — Claude Code cannot load these rules, so every grant and deny in the file is inoperative; fix the syntax (a trailing comma is the usual cause) and re-run"
else
  allow_raw="$(jq -r '.permissions.allow[]? // empty' "$settings" 2>/dev/null)"
  deny_raw="$(jq -r '.permissions.deny[]? // empty' "$settings" 2>/dev/null)"
  allow_list_read=true

  # Capture-then-test (#255), not a `find` writer piped into `grep`'s quiet mode: that early-exit
  # reader exits on its first match, which can send the find writer SIGPIPE and, under this file's
  # `set -uo pipefail`, turn a genuine match (a marker file present) into a reported pipeline
  # failure — a false "not found" verdict on the consumer's own repo, not just a CI flake.
  has_marker() { [ -n "$(find "$root" -maxdepth 2 -name "$1" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null)" ]; }
  # allow_has tests $allow_union (the three-file union), not $allow_raw — it judges effective
  # permission, matching the WARN/PASS text below. It is still defined only inside this
  # .claude/settings.json-readable else branch, so the toolchain block as a whole stays gated on
  # that file being present and parseable, exactly like the post-merge allow-entry check's
  # allow_list_read gate further down (see its rationale comment) — even though the values it
  # tests come from the union. Here-string, not a `printf` writer piped into `grep`'s quiet mode
  # (#255): same SIGPIPE exposure as has_marker above, removed the same way.
  allow_has()  { grep -qE "^Bash\\(($1)" <<<"$allow_union"; }
  tool_warns=0
  # tool_warn MARKER_TEXT TOOLS — one uniform WARN for the six toolchain marker checks below:
  # scope (the three-file union, named via $read_list) and remediation (which file to edit,
  # depending on whether the grant should be shared or machine-specific) stated once, so the six
  # marker/tool pairs below don't carry six independent copies of the same sentence.
  tool_warn() {
    wrn "$1 found but no $2 in the allow-list (checked across $read_list) — add \"Bash(<tool>:*)\" to permissions.allow in .claude/settings.json, or .claude/settings.local.json for a machine-specific grant"
    tool_warns=1
  }

  # --- path-qualified verification interpreter (#132/#128, #147) --- a bare-name allow entry
  # (Bash(pytest:*)) does not cover a path-qualified interpreter
  # (<repo>/api/.venv/bin/python -m pytest, which worktree-parallel mode's step d instructs —
  # see skills/issue-implementer/references/worktree-mode.md): Claude Code's permission matching
  # is a literal prefix test, not a basename match, so allow_has's regex would falsely reassure
  # (it only checks whether some allow-union ENTRY starts with a bare interpreter name like
  # Bash(python — it never looks at the path-qualified token itself) while the grant that
  # actually covers the command is the literal path itself. Scan the verification-scope
  # candidates (whole file when no "Verification…" heading exists — Q2, ACCEPTED), take each
  # candidate's first whitespace-delimited token, and keep the FIRST one that both contains a
  # '/' and whose basename is a known Python-family interpreter name. entry_has (literal prefix
  # test) probes the grant against $allow_union, the three-file union computed above — never
  # allow_has (a regex test over bare marker names like `pytest|python`, unsuited to matching an
  # arbitrary literal path string, even though it too now reads $allow_union).
  py_path_tok=""
  py_path_covered=false
  if [ -f "$root/CLAUDE.md" ]; then
    if has_verification_heading; then
      verify_scope="$(claude_md_verification_scope)"
    else
      verify_scope="$(cat "$root/CLAUDE.md")"
    fi
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      [ -n "$py_path_tok" ] && continue
      tok="$(printf '%s\n' "$cand" | awk '{print $1}')"
      case "$tok" in
        */*)
          base="${tok##*/}"
          case "$base" in
            python|python3|python.exe|pytest|uv|poetry|tox) py_path_tok="$tok" ;;
          esac
          ;;
      esac
    done <<EOF
$(verification_candidates "$verify_scope")
EOF
    if [ -n "$py_path_tok" ]; then
      if entry_has "$allow_union" "Bash($py_path_tok"; then
        py_path_covered=true
      else
        case "$py_path_tok" in
          /*|?:/*) : ;;
          *) entry_has "$allow_union" "Bash($root/$py_path_tok" && py_path_covered=true ;;
        esac
      fi
      if $py_path_covered; then
        ok "path-qualified verification interpreter '$py_path_tok' is covered by a literal-path allow entry"
      else
        wrn "path-qualified verification interpreter '$py_path_tok' has no matching allow entry — add \"Bash($py_path_tok:*)\" to permissions.allow in .claude/settings.json (or .claude/settings.local.json if the path is machine-specific to one worktree) — see the issue-implementer skill's worktree-mode.md step d"
        tool_warns=1
      fi
    fi
  fi

  if has_marker package.json   && ! allow_has "npm|pnpm|yarn|bun";          then tool_warn "package.json"           "npm/pnpm/yarn/bun"; fi
  if { has_marker pyproject.toml || has_marker requirements.txt || has_marker pytest.ini; } && ! allow_has "pytest|python|uv|poetry|tox" && ! $py_path_covered; then tool_warn "Python project files"     "pytest/python/uv/poetry"; fi
  if has_marker Cargo.toml     && ! allow_has "cargo";                      then tool_warn "Cargo.toml"              "cargo"; fi
  if has_marker go.mod         && ! allow_has "go";                         then tool_warn "go.mod"                 "go"; fi
  if has_marker Makefile       && ! allow_has "make";                       then tool_warn "Makefile"               "make"; fi
  if has_marker Gemfile        && ! allow_has "bundle|rake|rspec";          then tool_warn "Gemfile"                "bundle/rake/rspec"; fi
  if [ "$tool_warns" -eq 0 ]; then
    ok "allow-list covers the detected toolchain(s) across $read_list (subagents can't prompt for permissions — this matters)"
  fi
  # Sentinel: are the harness's own commands allowed? Deliberately a *substring* test over the
  # extracted allow entries, not a prefix test like entry_has — this matches both the bare-name
  # plugin entries and legacy .claude-path entries (e.g.
  # "Bash(.claude/scripts/find-planning-work.sh:*)"), which contain the script name but not as
  # a prefix of the entry.
  # Here-string, not a `printf` writer piped into `grep`'s quiet mode (#255): that early-exit
  # reader exits on its first match, which can send the printf writer SIGPIPE and, under this
  # file's `set -uo pipefail`, turn a genuine match into a reported pipeline failure.
  if grep -qF -- "find-planning-work.sh" <<<"$allow_raw"; then
    ok "harness script commands are in the allow-list"
  else
    wrn "harness script commands (e.g. find-planning-work.sh) not found in .claude/settings.json's allow-list — copy the permissions block from the plugin's templates/repo-settings.json"
  fi
  # --- template drift (generic diff; replaces the old per-version blocks) ------
  # Reports template entries missing from this repo; repo-only extras are legitimate and
  # never reported. Bash(gh pr merge:*) is excluded from the deny comparison: its absence is
  # the documented merge-autonomy opt-in (see "policy activation state" below), not drift.
  tmpl="$script_dir/../templates/repo-settings.json"
  if [ ! -f "$tmpl" ] || ! jq -e . "$tmpl" >/dev/null 2>&1; then
    wrn "could not read the plugin's templates/repo-settings.json (expected at $tmpl) — skipping the permission drift check"
  else
    tmpl_allow="$(jq -r '.permissions.allow[]? // empty' "$tmpl")"
    tmpl_deny="$(jq -r '.permissions.deny[]? // empty' "$tmpl" | grep -vxF 'Bash(gh pr merge:*)')"
    diff_side() {  # $1=template list  $2=already-extracted repo list -> sets n_missing/out_missing
      n_missing=0; out_missing=""
      while IFS= read -r e; do
        [ -n "$e" ] || continue
        # Here-string, not a `printf` writer piped into `grep`'s quiet mode (#255): same SIGPIPE
        # exposure as the sentinel check above, removed the same way.
        grep -qxF -- "$e" <<<"$2" && continue
        n_missing=$((n_missing+1))
        [ "$n_missing" -le 6 ] && out_missing="$out_missing$e, "
      done <<EOF
$1
EOF
    }
    diff_side "$tmpl_allow" "$allow_raw"; n_allow=$n_missing; miss_allow="${out_missing%, }"
    diff_side "$tmpl_deny" "$deny_raw";   n_deny=$n_missing;  miss_deny="${out_missing%, }"
    if [ "$n_allow" -eq 0 ] && [ "$n_deny" -eq 0 ]; then
      ok "settings.json permissions match the plugin's template ($(printf '%s\n' "$tmpl_allow" | grep -c .) allow / $(printf '%s\n' "$tmpl_deny" | grep -c .) deny entries checked)"
    fi
    if [ "$n_allow" -gt 0 ]; then
      more=""; [ "$n_allow" -gt 6 ] && more=" (+$((n_allow-6)) more)"
      wrn "settings.json allow-list missing $n_allow template entries: $miss_allow$more; re-copy the permissions block from the plugin's templates/repo-settings.json"
    fi
    if [ "$n_deny" -gt 0 ]; then
      more=""; [ "$n_deny" -gt 6 ] && more=" (+$((n_deny-6)) more)"
      wrn "settings.json deny-list missing $n_deny template entries: $miss_deny$more — a missing -C mirror makes the bare-form guard bypassable; re-copy the permissions block from the plugin's templates/repo-settings.json"
    fi

    # --- stale -C allow entries (#150) -------------------------------------------
    # v2.4.0 deleted the nine `Bash(git -C * <sub> *)` allow entries from the template — a
    # plugin-shipped PreToolUse guard hook (hooks/git-c-guard.sh) covers those forms instead, and
    # Claude Code 2.1.246+ prints a startup wildcard warning for each one still present. The
    # template-diff block above only ever reports MISSING template entries, never repo-only
    # extras, so a repo that never re-syncs gets no cue from it — this is that cue. Never FAILs:
    # the stale rules still work, they're just noisy and superseded.
    stale_c_allow="$(printf '%s\n' "$allow_raw" | grep -E '^Bash\(git -C ' | sort -u)"
    if [ -n "$stale_c_allow" ]; then
      n_stale="$(printf '%s\n' "$stale_c_allow" | grep -c .)"
      more=""; [ "$n_stale" -gt 6 ] && more=" (+$((n_stale-6)) more)"
      stale_list="$(printf '%s\n' "$stale_c_allow" | head -6 | tr '\n' ',' | sed 's/,/, /g; s/, $//')"
      wrn "settings.json allow-list still carries $n_stale legacy 'Bash(git -C ...)' entries: $stale_list$more — Claude Code 2.1.246+ prints a startup wildcard warning for each; the plugin's guard hook now covers these forms, so delete them by re-copying the permissions block from the plugin's templates/repo-settings.json"
    fi

    # --- default-branch guard coverage (#54) ------------------------------------
    # Two of the seven bare git denies in templates/repo-settings.json name the branch literally
    # ("main") rather than deriving it from the repo — on a repo whose default branch is
    # something else (master, trunk, develop, ...) those two denies, and their -C mirrors, guard
    # nothing. This derives the guarded operations from the template itself (no second
    # hard-coded operation list — $tmpl_deny is the only source) and checks whether THIS repo's
    # actual default branch has equivalent deny coverage. Deliberately overlaps the WARNs above:
    # a 'main' repo with an uncopied template can trip both — those say the repo is behind the
    # template, this one says the deny-list doesn't cover this repo's actual default branch.
    # Different diagnoses; don't collapse them. Lives inside THIS else branch, not the
    # unreadable-template branch above: it must only ever run with a real $tmpl_deny to derive
    # from, never fall back to an empty list and manufacture a vacuous pass — that's the failure
    # mode #54 exists to surface, and the WARN above (unreadable template) is the sole signal
    # for that path.
    #
    # tmpl_guarded_branch must stay a bare literal, free of regex metacharacters (it is
    # interpolated into a sed script below).
    tmpl_guarded_branch="main"
    if [ -n "$default_branch" ]; then
      tmpl_branch_ops="$(printf '%s\n' "$tmpl_deny" | sed -n "s/^Bash(git \(.*\) $tmpl_guarded_branch:\*)\$/\1/p" | sort -u)"
      # deny_guards PREFIX — does deny_raw contain an entry that starts with PREFIX and is
      # immediately followed by a rule-boundary character ('*', ':', or ')')? A plain
      # substring/prefix test would let a same-prefix branch name (e.g. "mainline") false-positive
      # as covering "main". '*' comes first in the bracket expression — a leading '[:' opens a
      # POSIX class, not a literal ':'.
      deny_guards() { printf '%s\n' "$deny_raw" | awk -v p="$1" 'index($0, p) == 1 { r = substr($0, length(p) + 1); if (r ~ /^[*:)]/) hit = 1 } END { exit !hit }'; }
      guard_missing=""
      while IFS= read -r op; do
        [ -n "$op" ] || continue
        deny_guards "Bash(git $op $default_branch" || guard_missing="$guard_missing Bash(git $op $default_branch:*),"
        deny_guards "Bash(git -C * $op $default_branch" || guard_missing="$guard_missing Bash(git -C * $op $default_branch*),"
      done <<EOF
$tmpl_branch_ops
EOF
      guard_missing="${guard_missing%,}"
      if [ -z "$guard_missing" ]; then
        ok "default-branch guard coverage: '$default_branch' has deny entries for every branch-scoped operation the template guards on '$tmpl_guarded_branch'"
      else
        wrn "default-branch guard coverage: '$default_branch' is missing deny entries:$guard_missing — add these to permissions.deny in .claude/settings.json (a missing -C mirror makes the bare-form guard bypassable)"
      fi
    fi
  fi
fi

# --- disableAllHooks (#150, #235) --------------------------------------------------------------
# A true value in ANY of the three settings files silently disables every hook, including the
# plugin's `git -C` guard hook — worktree-parallel mode's `git -C` commands then prompt in
# default mode (or, headless, stall unattended, since a subagent can't answer a prompt) — AND the
# implementer/verifier agent-boundary hook (#235), whose absence is a DIFFERENT failure shape: it
# never prompts, it just goes silently missing, so a misbehaving implementer/verifier subagent's
# `git`/`gh` command executes under the session-wide permission allow list exactly as if the
# mechanical boundary had never shipped. Never FAILs: disabling hooks is a legitimate choice, this
# just names both consequences.
if [ -n "$disable_hooks_src" ]; then
  wrn "disableAllHooks: true in $disable_hooks_src — the plugin's git -C guard hook (and every other hook) cannot run, so worktree-parallel mode's git -C commands prompt in default mode and an unattended run stalls; the implementer/verifier agent-boundary hook also cannot run, so its git/gh denial is silently absent rather than a prompt — a misbehaving subagent's git/gh command then executes under the ordinary permission allow list"
fi

# --- policy activation state (informational) -------------------------------------
# Reports whether an optional CLAUDE.md policy section is *activated* by its companion
# permission-file edit, where it has one (the ratchet activates by naming a measurement command
# instead; plan auto-approval has no companion edit at all) — never whether the policy prose
# itself is any good (that quality judgment stays with the harness-setup skill), and never
# auto-fixes anything: every WARN below names the human's edit. Enterprise/managed settings are
# not read by this script at all.
# Hoisted above the CLAUDE.md-exists check below (rather than left to the assignment inside it)
# so the "# --- branch protection ---" section further down can read it under `set -u` even on a
# repo with no CLAUDE.md at all (#234) — the policy-gated branch-protection report is otherwise
# reachable with its gate variable never assigned. Since #311 that gate reads $merge_effective
# ($has_merge_policy widened by autonomous mode), hoisted here with autonomy_on/kickback_budget;
# has_merge_policy stays hoisted as the default the CLAUDE.md-exists branch reassigns.
has_merge_policy=false
autonomy_on=false
merge_effective=false
kickback_budget=2
if [ ! -f "$root/CLAUDE.md" ]; then
  wrn "policy activation checks skipped (no CLAUDE.md)"
else
  # --- autonomy mode (#311) --- an optional "Autonomy mode" section, same fenced key: value
  # shape as "Autonomy decision record". `mode: autonomous` is the only value this doctor
  # recognises; anything else (including the section's absence) leaves the mode off. Read BEFORE
  # the merge-autonomy block below, which consumes $autonomy_on to compute $merge_effective —
  # never itself lifts the `Bash(gh pr merge:*)` deny, only reports the combination.
  has_autonomy_section=false
  has_policy_section "Autonomy mode" && has_autonomy_section=true
  if $has_autonomy_section; then
    autonomy_sec="$(claude_md_section "Autonomy mode")"
    autonomy_blk="$(printf '%s\n' "$autonomy_sec" | awk '
      /^```/ { if (infence) { exit } else { infence=1; next } }
      infence { print }
    ')"
    autonomy_mode_val="$(printf '%s\n' "$autonomy_blk" | sed -nE 's/^[[:space:]]*mode:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' | head -1)"
    [ "$autonomy_mode_val" = "autonomous" ] && autonomy_on=true
    autonomy_budget_val="$(printf '%s\n' "$autonomy_blk" | sed -nE 's/^[[:space:]]*kickback-budget:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' | head -1)"
    if [ -n "$autonomy_budget_val" ]; then
      case "$autonomy_budget_val" in
        0|1|2|3) kickback_budget="$autonomy_budget_val" ;;
        *) wrn "autonomy mode: kickback-budget '$autonomy_budget_val' is not an integer from 0 to 3 — the default 2 applies" ;;
      esac
    fi
  fi
  if ! $has_autonomy_section; then
    ok "autonomy mode: off — no 'Autonomy mode' section in CLAUDE.md"
  elif ! $autonomy_on; then
    wrn "autonomy mode: inert — 'Autonomy mode' section present but its fenced block declares no 'mode: autonomous' line; the harness behaves as if it were absent"
  else
    ok "autonomy mode: autonomous (kickback budget $kickback_budget) — an absent 'Plan auto-approval policy' / 'Merge autonomy policy' section is read as present (merge: harness PRs only); declared sections still apply in full"
    if $jq_ready && [ -n "$read_list" ]; then
      ok "permissions.defaultMode: $default_mode_report (informational)"
    fi
  fi

  # --- merge autonomy (#28, #66) --- exactly one 'merge autonomy: ' line; states mutually
  # exclusive. merge_effective (#311) is $has_merge_policy widened by autonomous mode: a
  # declared "Merge autonomy policy" section still applies in full either way, but its absence no
  # longer silences the merge/CI/branch-protection gates when "Autonomy mode" declares
  # mode: autonomous — that implied activation covers harness PRs only, never Dependabot or a
  # no-CI opt-in (the merge pass's own hard floor still requires CI green).
  has_merge_policy=false
  has_policy_section "Merge autonomy policy" && has_merge_policy=true
  merge_effective="$has_merge_policy"
  $autonomy_on && merge_effective=true
  if $has_merge_policy; then
    merge_decl="'Merge autonomy policy' section present"
  else
    merge_decl="'Autonomy mode' declares mode: autonomous (merge autonomy implied, harness PRs only)"
  fi

  if ! $jq_ready; then
    wrn "merge autonomy: activation state unknown — jq not installed (see the FAIL above)"
  elif [ -n "$broken_list" ]; then
    wrn "merge autonomy: activation state unknown — $broken_list does not parse as JSON, so Claude Code cannot load its rules; fix the syntax and re-run"
  elif [ -z "$read_list" ]; then
    wrn "merge autonomy: activation state unknown — none of .claude/settings.json, .claude/settings.local.json, $settings_user_label were found"
  else
    merge_denied=false
    [ -n "$merge_deny_src" ] && merge_denied=true
    merge_allowed=false
    [ -n "$merge_allow_src" ] && merge_allowed=true

    # The merge pass's hard floor treats a "no checks configured" result from `gh pr checks` as
    # NOT green (see skills/issue-cycle/SKILL.md). No workflow file is a proxy for that, not proof
    # of it (an external CI app can still report checks) — so this is an informational note on the
    # active PASS, never a WARN or a gate on its own.
    has_ci_workflow=false
    for wf in "$root"/.github/workflows/*.yml "$root"/.github/workflows/*.yaml; do
      [ -f "$wf" ] && { has_ci_workflow=true; break; }
    done
    merge_ci_note=""
    $has_ci_workflow || merge_ci_note=" — but no .github/workflows file exists, so gh pr checks likely reports 'no checks configured', which the merge pass's hard floor treats as NOT green: no PR qualifies unless a declared 'Merge autonomy policy' section explicitly opts a no-CI repo in (the policy 'Autonomy mode' implies never does)"

    if $merge_effective && $merge_denied; then
      wrn "merge autonomy: half-activated — $merge_decl but 'Bash(gh pr merge:*)' is still denied in $merge_deny_src — a deny wins over any allow, in any settings file; to activate, remove \"Bash(gh pr merge:*)\" from permissions.deny in $merge_deny_src AND add it to permissions.allow in .claude/settings.json (both edits are yours, never an agent's)"
    elif $merge_effective && ! $merge_denied && $merge_allowed; then
      ok "merge autonomy: active ($merge_decl, no deny found in $read_list, allow present in $merge_allow_src)$merge_ci_note"
    elif $merge_effective && ! $merge_denied && ! $merge_allowed; then
      wrn "merge autonomy: deny on 'Bash(gh pr merge:*)' lifted (no deny found in $read_list) but no matching allow entry — unattended cycles will stall on the permission prompt; add the allow entry to .claude/settings.json, or to .claude/settings.local.json to opt in on this machine only"
    elif ! $merge_effective && ! $merge_denied; then
      wrn "merge autonomy: 'Bash(gh pr merge:*)' deny lifted (no deny found in $read_list) but no 'Merge autonomy policy' section in CLAUDE.md — the cycle skips the merge pass anyway; add the section (or restore the deny)"
    else
      ok "merge autonomy: off (default — no 'Merge autonomy policy' section, deny in place in $merge_deny_src; every PR merge is manual)"
    fi
  fi

  # --- CI action pinning (#166, #179, #186) --- gated on $merge_effective (#311: $has_merge_policy
  # widened by "Autonomy mode"'s implied merge autonomy): under merge autonomy
  # the cycle merges on "CI green" (see the merge-autonomy verdict above), so a `uses:` ref pinned
  # to a mutable tag or branch lets that tag's owner repoint what CI executes with no diff visible
  # in this repo — the workflow's own green check is the blast radius. String comparison only:
  # never `eval`, `command -v`, or expand anything read from a workflow or action file. Scans two
  # file classes into one shared counter and one WARN/PASS pair: (1) "$root"/.github/workflows/
  # *.yml|*.yaml, and (2) every action.yml/action.yaml anywhere in the repo, found via a
  # repo-wide `find` pruning `.git`, `node_modules`, and "$root"/.github/workflows (the last so a
  # workflow file literally named action.yml is never scanned twice) — because a workflow that
  # only calls a local composite action (`uses: ./tools/ci-setup`) would otherwise get a clean
  # PASS while an unpinned `uses:` inside that composite stays repointable (#179, #186 — a local
  # composite action can live anywhere, not just under .github/actions/, so enumeration is
  # repo-wide rather than scoped to that one directory; this also catches an action.yml not yet
  # referenced by any workflow, and never turns an untrusted `uses:` ref string into a filesystem
  # path — the `find` only ever walks paths the doctor already owns). The per-file extraction
  # (ci_scan_uses_file) mirrors this repo's own dev/selfcheck.sh assertion 4.24 as an idiom
  # (comment-stripped by LINE first, so a commented-out unpinned `uses:` line can't
  # false-positive, plus a CRLF strip and a surrounding-quote strip that 4.24 doesn't need — a
  # consumer's file may be CRLF and/or quoted, unlike this repo's own) — 4.24's own *scope* stays
  # workflows-only (dev/selfcheck.sh:809-855), so this check's scope is now wider than 4.24's.
  # Same skip inside both file classes for local (`./…`, `../…`) and `docker://` refs — not
  # SHA-pinnable / a different pinning syntax, documented here rather than left silent, same as
  # 4.24's own comment on that same gap. Refs found inside an action file are never followed:
  # coverage of a nested local composite comes from *enumerating* every action.yml/action.yaml in
  # the repo, not from chasing `./…` refs, so gaps remain unscanned and are named honestly rather
  # than implied covered: an action metadata file inside a pruned .git/ or node_modules/ tree, a
  # symlinked action directory (`find` does not descend symlinks by default, so a target outside
  # the repo is unreachable — and unexecutable by GitHub's own runner either), and the internals
  # of a reusable workflow owned by another repo (the ref to it is still checked, just not its
  # body). Never FAILs: this is a WARN-only, advisory check, so the doctor's exit code is
  # unaffected.
  if $merge_effective; then
    ci_uses_total=0
    ci_bad_count=0
    ci_bad_list=""
    # ci_scan_uses_file FILE — extracts every non-commented `uses:` line from FILE, skips local
    # (`./…`, `../…`) and `docker://` refs, and updates the ci_uses_total/ci_bad_count/ci_bad_list
    # globals in the current shell (a plain function, no subshell, matching the has_marker/
    # allow_has precedent above). FILE is only ever read with grep/sed and sliced with parameter
    # expansion — never executed, evaled, or passed to command -v.
    ci_scan_uses_file() {
      uses_lines="$(grep -vE '^[[:space:]]*#' "$1" | grep -E '^[[:space:]]*-?[[:space:]]*uses:')"
      [ -n "$uses_lines" ] || return 0
      while IFS= read -r ul; do
        [ -n "$ul" ] || continue
        ref="$(printf '%s\n' "$ul" | tr -d '\r' | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//; s/[[:space:]].*$//')"
        case "$ref" in
          \"*\") ref="${ref#\"}"; ref="${ref%\"}" ;;
          \'*\') ref="${ref#\'}"; ref="${ref%\'}" ;;
        esac
        case "$ref" in
          ./*|../*|docker://*) continue ;;
        esac
        ci_uses_total=$((ci_uses_total+1))
        case "$ref" in
          *@*) ci_sha="${ref##*@}" ;;
          *)   ci_sha="" ;;
        esac
        ci_pinned=false
        case "$ci_sha" in
          ''|*[!0-9a-f]*) : ;;
          *) [ "${#ci_sha}" -eq 40 ] && ci_pinned=true ;;
        esac
        if ! $ci_pinned; then
          ci_bad_count=$((ci_bad_count+1))
          [ "$ci_bad_count" -le 6 ] && ci_bad_list="$ci_bad_list${1#$root/}:$ref, "
        fi
      done <<EOF
$uses_lines
EOF
    }
    for wf in "$root"/.github/workflows/*.yml "$root"/.github/workflows/*.yaml; do
      [ -f "$wf" ] || continue
      ci_scan_uses_file "$wf"
    done
    action_files="$(find "$root" \( -name .git -o -name node_modules -o -path "$root/.github/workflows" \) -prune -o -type f \( -name 'action.yml' -o -name 'action.yaml' \) -print 2>/dev/null | LC_ALL=C sort)"
    while IFS= read -r af; do
      [ -f "$af" ] || continue
      ci_scan_uses_file "$af"
    done <<EOF
$action_files
EOF
    ci_bad_list="${ci_bad_list%, }"
    if [ "$ci_uses_total" -gt 0 ]; then
      if [ "$ci_bad_count" -gt 0 ]; then
        more=""; [ "$ci_bad_count" -gt 6 ] && more=" (+$((ci_bad_count-6)) more)"
        wrn "CI action pinning: $ci_bad_count uses: ref(s) in .github/workflows and in any action.yml/action.yaml in the repo are not pinned to a full 40-hex commit SHA: $ci_bad_list$more — under merge autonomy the cycle merges on 'CI green', so a repointed tag changes what CI runs with no diff in your repo; pin each to a full commit SHA (keep the tag in a trailing comment)"
      else
        ok "CI action pinning: all $ci_uses_total uses: ref(s) in .github/workflows and in any action.yml/action.yaml in the repo are pinned to a full commit SHA"
      fi
    fi
  fi

  # --- post-merge verification declaration state (#132, #142) --- reports whether the optional
  # "Post-merge verification" sub-heading (nested, any '#' depth, under "Merge autonomy policy")
  # is declared, how many non-blank fenced command lines it holds, and — when declared and
  # .claude/settings.json was readable — whether each declared command's first token has a
  # matching allow entry there (a literal string comparison via entry_has, never a lookup or an
  # execution of the command itself; see the allow-entry loop below). Never judges whether the
  # declared commands are any good. Deliberately placed OUTSIDE the jq_ready/broken_list chain
  # above, so the declaration state still reports even when the merge-autonomy activation state
  # itself is unknown (no settings file, unparseable, ...) — the declaration lives in CLAUDE.md,
  # not in any settings file, and doesn't depend on activation state. Never executes, evals,
  # command -v's, or expands anything read from the declaration. Deliberately gated on
  # $has_merge_policy, NOT $merge_effective (#311): a "Post-merge verification" sub-block only
  # ever lives nested under a declared "Merge autonomy policy" heading, so "Autonomy mode"'s
  # implied merge autonomy has no such sub-block to find.
  if $has_merge_policy; then
    merge_sec="$(claude_md_section "Merge autonomy policy")"
    postdeploy_found=false
    # Here-string into awk, then capture-then-test (#255), not a `printf` writer piped through
    # `awk` into `grep`'s quiet mode: awk's own `exit` already makes it an early-exit reader, and
    # the trailing quiet-mode grep is a second one — either can send its upstream writer SIGPIPE
    # and, under this file's `set -uo pipefail`, turn a genuine match into a reported pipeline
    # failure. The here-string removes the first pipe's writer process entirely; capturing awk's
    # own output and testing it with `[ -n ... ]` removes the second.
    postdeploy_hit="$(awk '
      /^```/ { infence = !infence; next }
      !infence && /^#+[[:space:]]+Post-merge verification[[:space:]]*$/ { print "found"; exit }
    ' <<<"$merge_sec")"
    if [ -n "$postdeploy_hit" ]; then
      postdeploy_found=true
    fi

    if ! $postdeploy_found; then
      ok "post-merge verification: not declared — the cycle's merge pass runs no post-merge commands (add a 'Post-merge verification' sub-heading under 'Merge autonomy policy' to opt in; see the README's CLAUDE.md contract)"
    else
      postdeploy_sec="$(printf '%s\n' "$merge_sec" | awk '
        /^#+[[:space:]]+Post-merge verification[[:space:]]*$/ { inx=1; next }
        inx && /^```/ { infence = !infence }
        inx && !infence && /^#+[[:space:]]/ { exit }
        inx { print }
      ')"
      postdeploy_blk="$(printf '%s\n' "$postdeploy_sec" | awk '
        /^```/ { if (infence) { exit } else { infence=1; next } }
        infence { print }
      ')"
      postdeploy_count="$(printf '%s\n' "$postdeploy_blk" | grep -c '[^[:space:]]')"
      if [ "$postdeploy_count" -eq 0 ]; then
        wrn "post-merge verification: heading present but no fenced commands ('Post-merge verification' sub-heading found, but the cycle silently skips deploy verification with no fenced block — 'No command ⇒ no check', same rule as the test-suite ratchet below) — add a fenced block with at least one command"
      else
        ok "post-merge verification: declared ($postdeploy_count command line(s)) — the cycle's merge pass runs these read-only commands after a merge; this doctor never previews or executes them"

        # --- post-merge allow-entry check (#138, #142, #147) --- when .claude/settings.json was
        # readable (allow_list_read), checks each declared line's first whitespace-delimited
        # token against allow_union (the three-file union computed above) with entry_has: a plain
        # prefix test, NOT the rule-boundary variant deny_guards uses above — deliberately, so an
        # arg-scoped grant such as Bash(tbf-boobytrap --smoke:*) still counts as covering the bare
        # command. A pure string comparison: never command -v's, evals, or expands the token.
        # Still gated on allow_list_read (.claude/settings.json itself, not the union) rather than
        # "any of the three files parsed" — see the "settings-file candidates" block for why.
        # Skipped silently when allow_list_read is false — the settings block above already
        # FAILs/WARNs loudly about the unreadable file, so a second "check skipped" line here
        # would be noise.
        if $allow_list_read; then
          pd_seen=""; pd_missing=""; pd_entries=""; pd_checked=0
          while IFS= read -r line; do
            [ -n "$line" ] || continue
            tok="$(printf '%s\n' "$line" | awk '{print $1}')"
            [ -n "$tok" ] || continue
            case "$tok" in
              '#'*) continue ;;
            esac
            # Here-strings, not a `printf` writer piped into `grep`'s quiet mode (#255): that
            # early-exit reader exits on its first match, which can send the printf writer
            # SIGPIPE and, under this file's `set -uo pipefail`, turn a genuine match into a
            # reported pipeline failure.
            grep -qE '^[A-Za-z0-9._/-][A-Za-z0-9._/+-]*$' <<<"$tok" || continue
            grep -qxF -- "$tok" <<<"$pd_seen" && continue
            pd_seen="${pd_seen}${tok}"$'\n'
            pd_checked=$((pd_checked+1))
            if entry_has "$allow_union" "Bash($tok"; then
              :
            else
              pd_missing="$pd_missing$tok, "
              pd_entries="$pd_entries\"Bash($tok:*)\", "
            fi
          done <<EOF
$postdeploy_blk
EOF
          pd_missing="${pd_missing%, }"
          pd_entries="${pd_entries%, }"
          if [ -n "$pd_missing" ]; then
            wrn "post-merge verification: declared command(s) with no matching allow entry: $pd_missing — add $pd_entries to permissions.allow in .claude/settings.json (or .claude/settings.local.json for a machine-specific grant); checked against $read_list; without the grant the cycle's merge pass records deploy=pending, not shipped"
          elif [ "$pd_checked" -gt 0 ]; then
            ok "post-merge verification: every declared command has a matching allow entry ($pd_checked checked across $read_list; string comparison only, never executed or looked up)"
          fi
        fi
      fi
    fi
  fi

  # --- test-suite ratchet (#45) --- the doctor never executes the measurement command it finds:
  # command -v is a lookup, not an execution, and the extracted token is only ever a quoted
  # argument — never eval'd, never expanded. See the header comment for why.
  if ! has_policy_section "Test-suite ratchet policy"; then
    ok "test-suite ratchet: off — no 'Test-suite ratchet policy' section in CLAUDE.md, so the ratchet never runs"
  else
    # Documented heuristic (like 1.4 in dev/selfcheck.sh): the first backtick-quoted span in
    # the section is taken as the measurement command. $bt (a single backtick) is hoisted near
    # the top of this file, shared with the verification-scope candidate scan. Routed through
    # claude_md_section (fence-aware AND depth-aware, .claude/LESSONS.md 2026-08-21) instead of
    # a local inline slice, so a '#'-prefixed comment inside the section's fenced block does not
    # truncate it, and a nested sub-heading no longer ends the slice early either.
    sec="$(claude_md_section "Test-suite ratchet policy")"
    # Fence-delimiter lines must be filtered out before the backtick-span hunt: claude_md_section
    # deliberately keeps them in its output, and a bare ``` line's own two backticks would
    # otherwise be the first match `grep -o` finds, making `head -1` return an empty span even
    # though a real command follows later in the section. Do not "simplify" this away.
    span="$(printf '%s\n' "$sec" | awk '/^```/ { next } { print }' | grep -o "${bt}[^${bt}]*${bt}" | head -1 | tr -d "$bt")"
    if [ -z "$span" ]; then
      wrn "test-suite ratchet: 'Test-suite ratchet policy' section present but names no backtick-quoted measurement command ('No command ⇒ no ratchet') — the ratchet won't run until one is added"
    else
      tok="$(printf '%s' "$span" | awk '{print $1}')"
      # Here-string, not a `printf` writer piped into `grep`'s quiet mode (#255): same SIGPIPE
      # exposure as the post-merge token check above, removed the same way.
      if grep -qE '^[A-Za-z0-9._/-][A-Za-z0-9._/+-]*$' <<<"$tok"; then
        if command -v "$tok" >/dev/null 2>&1; then
          ok "test-suite ratchet: measurement command \`$span\` found (the doctor only looks it up — command -v, never runs it; the harness-setup skill runs it once, with a human present)"
        else
          wrn "test-suite ratchet: measurement command names '$tok', not found on PATH (the doctor only looks it up — command -v, never runs it) — a project venv may still provide it once activated"
        fi
      else
        ok "test-suite ratchet: 'Test-suite ratchet policy' section names a measurement command (\`$span\`) — the doctor does not run it; the harness-setup skill does, once, with a human present"
      fi
    fi
  fi

  # --- scoped autonomy (#107) --- reads the "Autonomy reserve" and "Autonomy decision record"
  # declarations verbatim; the policy itself (what's reserved, what a record must contain, what
  # a grant permits) stays in the repo's own CLAUDE.md, and the grant label is the human's to
  # apply or remove — this only reports whether the declarations are well-formed and, when gh is
  # ready, whether the declared label exists on the repo.
  has_reserve=false
  has_policy_section "Autonomy reserve" && has_reserve=true
  has_record=false
  has_policy_section "Autonomy decision record" && has_record=true

  if ! $has_reserve && ! $has_record; then
    ok "scoped autonomy: off — no 'Autonomy reserve' or 'Autonomy decision record' section in CLAUDE.md, so no grant is ever evaluated"
  else
    scoped_grant_label=""
    scoped_element_count=0
    scoped_record_ok=true
    if $has_record; then
      scoped_record_sec="$(awk '/^#+[[:space:]]+Autonomy decision record[[:space:]]*$/ { inx=1; next } inx && /^```/ { infence = !infence } inx && !infence && /^#+[[:space:]]/ { exit } inx { print }' "$root/CLAUDE.md")"
      scoped_record_blk="$(printf '%s\n' "$scoped_record_sec" | awk '/^```/ { if (infence) { exit } else { infence=1; next } } infence { print }')"
      scoped_grant_label="$(printf '%s\n' "$scoped_record_blk" | sed -nE 's/^[[:space:]]*grant-label:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' | head -1)"
      scoped_element_count="$(printf '%s\n' "$scoped_record_blk" | grep -cE '^[[:space:]]*element:')"
      if [ -z "$scoped_grant_label" ]; then
        wrn "scoped autonomy: 'Autonomy decision record' section present but names no 'grant-label:' line — add one (see the README's CLAUDE.md contract)"
        scoped_record_ok=false
      fi
      if [ "$scoped_element_count" -eq 0 ]; then
        wrn "scoped autonomy: 'Autonomy decision record' section present but names no 'element:' line — add at least one (see the README's CLAUDE.md contract)"
        scoped_record_ok=false
      fi
    fi

    if $has_record && ! $has_reserve; then
      wrn "scoped autonomy: no 'Autonomy reserve' section, so every plan's Reserve touch list is omitted and a granted issue always looks reserve-free — add the section if reserved paths matter to your grant"
    fi
    if $has_reserve && ! $has_record; then
      wrn "scoped autonomy: 'Autonomy reserve' section present but no 'Autonomy decision record' section — no grant label is declared, so check-decision-record.sh never runs"
    fi

    if $has_reserve && $has_record && $scoped_record_ok; then
      scoped_reserve_sec="$(awk '/^#+[[:space:]]+Autonomy reserve[[:space:]]*$/ { inx=1; next } inx && /^```/ { infence = !infence } inx && !infence && /^#+[[:space:]]/ { exit } inx { print }' "$root/CLAUDE.md")"
      scoped_reserve_blk="$(printf '%s\n' "$scoped_reserve_sec" | awk '/^```/ { if (infence) { exit } else { infence=1; next } } infence { print }')"
      scoped_reserve_count="$(printf '%s\n' "$scoped_reserve_blk" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' | grep -v '^#' | grep -c .)"
      ok "scoped autonomy: declared (grant label '$scoped_grant_label', $scoped_reserve_count reserve pattern(s), $scoped_element_count required record element(s))"
    fi

    if [ -n "$scoped_grant_label" ]; then
      if $gh_ready; then
        # Here-string, not a `printf` writer piped into `grep`'s quiet mode (#255): same SIGPIPE
        # exposure as the lifecycle-labels check above, removed the same way.
        if grep -qx -- "$scoped_grant_label" <<<"$existing"; then
          :
        else
          wrn "scoped autonomy: grant label '$scoped_grant_label' does not exist on this repo — run: gh label create \"$scoped_grant_label\" (the harness never applies or removes it, only reports whether it exists)"
        fi
      else
        wrn "scoped autonomy: grant label '$scoped_grant_label' existence unknown (gh not ready)"
      fi
    fi
  fi

  # --- governance paths (#331, folds in #330) --- validates the optional "Governance paths"
  # section (README item 10) that the merge floor's governance-path classifier,
  # bin/governance-paths.sh, reads from a repo's base-tip CLAUDE.md. Run here by a FIXED path,
  # $script_dir/governance-paths.sh --check "$root/CLAUDE.md" — same precedent as
  # bin/harness-version.sh above (#233) — never a path derived from repo content, and never
  # against anything but THIS repo's own CLAUDE.md (never the classifier's floor mode, never a
  # git object). Missing, non-executable, a non-zero exit, or any stdout shape but the three the
  # script documents (absent / declared <n> / malformed <token>) is the same "could not validate"
  # WARN, never a FAIL — this doctor never blocks a run on this, matching the ratchet and
  # post-merge-verification declaration checks above.
  gov_script="$script_dir/governance-paths.sh"
  gov_out=""
  if [ -x "$gov_script" ] && gov_out="$("$gov_script" --check "$root/CLAUDE.md" 2>/dev/null)"; then
    case "$gov_out" in
      absent)
        ok "governance paths: none declared" ;;
      declared\ *)
        ok "governance paths: ${gov_out#declared } declared glob(s)" ;;
      malformed\ *)
        wrn "governance paths: 'Governance paths' section is malformed (${gov_out#malformed }) — every PR is held until this is fixed (README's CLAUDE.md contract, item 10)" ;;
      *)
        wrn "governance paths: could not validate" ;;
    esac
  else
    wrn "governance paths: could not validate"
  fi
fi
fi  # end of Claude Code-only checks

# --- verification baseline ------------------------------------------------------
# BASELINE.md records THIS machine's last known-green run of the verification commands
# on the default branch (commit SHA + per-command results). It is machine-local
# state: gitignored, written by harness-setup, refreshed by the implementer/cycle skills.
# harness-setup and the implementer/cycle refresh both still write the full 40-char SHA; the
# doctor merely tolerates an abbreviated recorded value of at least 7 hex characters, treating it
# as a prefix of the remote tip.
baseline="$claude_dir/BASELINE.md"
if [ -f "$baseline" ]; then
  recorded="$(sed -nE 's/^- commit:[[:space:]]*([0-9a-f]+).*/\1/p' "$baseline" | head -1)"
  current=""
  [ -n "$default_branch" ] && current="$(git rev-parse "origin/$default_branch" 2>/dev/null || true)"
  # A case statement isn't usable directly in an elif condition, so compute both booleans first.
  baseline_short=false; baseline_matches=false
  if [ -n "$recorded" ] && [ -n "$current" ]; then
    if [ "${#recorded}" -lt 7 ]; then
      baseline_short=true
    else
      case "$current" in "$recorded"*) baseline_matches=true ;; esac
    fi
  fi
  if [ -z "$recorded" ]; then
    wrn "BASELINE.md present but no '- commit:' line found — re-run the harness-setup skill to re-record it"
  elif $baseline_short; then
    wrn "BASELINE.md's '- commit:' value ('$recorded') is under 7 hex characters and cannot reliably identify a commit — re-run the harness-setup skill to re-record it with the full SHA"
  elif [ -n "$current" ] && ! $baseline_matches; then
    wrn "verification baseline is behind origin/$default_branch (recorded ${recorded:0:12}, remote at ${current:0:12}) — the next implementer/cycle run refreshes it"
  else
    ok "verification baseline recorded (BASELINE.md at ${recorded:0:12})"
  fi
  if git check-ignore -q "$baseline" 2>/dev/null; then
    ok "BASELINE.md is gitignored (machine-local state)"
  else
    wrn "BASELINE.md is not gitignored — add '.claude/BASELINE.md' to .gitignore; it records this machine's green run and must not be committed (dirty-tree/merge noise otherwise)"
  fi
else
  wrn "no verification baseline (.claude/BASELINE.md) — run the harness-setup skill to record one; implementation runs compare against it"
fi

# --- branch protection ----------------------------------------------------------
# PROTECTION_STRICT_WARN_STEM/PROTECTION_CHECKS_WARN_STEM (used below) are defined as top-level
# literals near CODEX_MIN_VERSION/CODEX_HOOKS_LIST_WAIT, well before this section — see that
# block's comment.
if $gh_ready && [ -n "$default_branch" ]; then
  repo_slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null | tr -d '\r' || true)"
  if [ -n "$repo_slug" ] && prot="$(gh api "repos/$repo_slug/branches/$default_branch/protection" 2>/dev/null)"; then
    ok "branch protection enabled on $default_branch"
    # Only when merge autonomy is effectively active ($merge_effective, #311 — a declared "Merge
    # autonomy policy" section OR "Autonomy mode"'s implied merge autonomy) AND jq is available:
    # read the protection document itself (through jq only — never a raw-text grep/sed/awk of
    # $prot) and report on exactly the fields the merge floor's up-to-date rail and CI-greenness
    # check care about. WARN-only, never FAIL — an unparseable document collapses both signals
    # closed (both WARNs fire) rather than silently passing.
    if $merge_effective && $jq_ready; then
      strict="$(printf '%s' "$prot" | jq -r 'if .required_status_checks.strict == true then "true" else "false" end' 2>/dev/null || true)"
      if [ "$strict" = "true" ]; then
        ok "branch protection: up-to-date branches are required before merge (required_status_checks.strict)"
      else
        wrn "$PROTECTION_STRICT_WARN_STEM — a PR can merge whose CI ran against a base the default branch has since moved past; the merge floor's own up-to-date rail mitigates this on the harness side, but GitHub itself won't enforce it"
      fi
      ctx_count="$(printf '%s' "$prot" | jq -r '[((.required_status_checks.checks // []) | length), ((.required_status_checks.contexts // []) | length)] | max' 2>/dev/null || true)"
      case "$ctx_count" in
        ''|*[!0-9]*) ctx_count=0 ;;
      esac
      if [ "$ctx_count" -gt 0 ]; then
        ok "branch protection: $ctx_count required status check context(s) configured"
      else
        wrn "$PROTECTION_CHECKS_WARN_STEM — a green mergeStateStatus proves nothing about CI when nothing is required to pass before merge"
      fi
      reviews="$(printf '%s' "$prot" | jq -r 'if .required_pull_request_reviews then "configured" else "not configured" end' 2>/dev/null || true)"
      case "$reviews" in
        configured) ok "branch protection: required PR reviews are configured" ;;
        *) ok "branch protection: required PR reviews are not configured" ;;
      esac
    fi
  else
    if [ "$provider" = codex ]; then
      bad "no branch protection detected on $default_branch (or no admin scope to check) — on Codex this is a FAIL: push-guard.sh and branch protection are all that stand between an allowed git push and $default_branch; require a PR before merging"
    else
      wrn "no branch protection detected on $default_branch (or no admin scope to check) — recommended: require a PR before merge; it's the real backstop behind the deny-list"
    fi
  fi
elif [ "$provider" = codex ]; then
  bad "branch protection: could not check (gh not ready or default branch unknown) — push-guard.sh and branch protection are all that stand between an allowed git push and the default branch; run gh auth login and re-run"
fi

# --- summary --------------------------------------------------------------------
echo
echo "== summary: $pass pass, $warn warn, $fail fail =="
if [ "$fail" -gt 0 ]; then
  echo "Fix the FAIL items above before running the planner/implementer skills."
  exit 1
fi
if [ "$warn" -gt 0 ]; then
  echo "WARN items are advisory — the harness-setup skill helps resolve them."
fi
exit 0
