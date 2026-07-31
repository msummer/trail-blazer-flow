#!/usr/bin/env bash
#
# check-harness.sh — preflight "doctor" for the issue-workflow harness.
#
# Checks everything mechanical the harness needs in a repo: gh/jq, the git remote,
# the lifecycle labels, executable scripts, a CLAUDE.md with a verification section and a
# size guideline, LESSONS.md, the settings.json toolchain allow-list (read exclusively through
# jq — never a raw-text grep/sed/awk of the file), whether the "Merge autonomy policy" section
# is activated by its companion .claude/settings.json edits, whether a "Test-suite ratchet
# policy" section exists and names a measurement command (looked up with `command -v`, never
# executed), the verification baseline (.claude/BASELINE.md, machine-local), and branch
# protection.
#
# The test-suite-ratchet check never executes, evals, or shells out to anything read from
# CLAUDE.md: it only looks up the measurement command's first word with `command -v` (a lookup,
# not an execution) and prints it back, quoted, as a report.
#
# Read-only except two safe, idempotent fixes it applies automatically:
#   - chmod +x on the harness's own scripts
#   - seeding an empty .claude/LESSONS.md if the project has none
#
# Quality judgments (is CLAUDE.md actually good enough? do the verification commands
# pass?) are NOT this script's job — that's the harness-setup skill, which runs this
# script first and then does the audit.
#
# Exit 0 = no FAILs (WARNs allowed). Exit 1 = at least one FAIL.
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

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "  FAIL  not inside a git repository"; exit 1; }
cd "$root"
claude_dir="$root/.claude"
echo "== harness doctor: $root =="

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
if command -v jq >/dev/null 2>&1; then
  ok "jq installed"
  jq_ready=true
else
  bad "jq not installed — the discovery scripts need it"
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
if $gh_ready; then
  existing="$(gh label list --limit 200 --json name --jq '.[].name' 2>/dev/null | tr -d '\r' || true)"
  missing=""
  for l in plan-proposed plan-approved pr-open impl-blocked no-plan no-auto-approve test-ratchet; do
    echo "$existing" | grep -qx "$l" || missing="$missing $l"
  done
  if [ -z "$missing" ]; then
    ok "all 7 lifecycle labels exist"
  else
    bad "missing labels:$missing — run: setup-labels.sh"
  fi
else
  wrn "skipped label check (gh not ready)"
fi

# --- harness scripts executable (auto-fix) -------------------------------------
# The harness scripts live alongside this one (the plugin's bin/, or .claude copies).
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
    wrn "CLAUDE.md size: $cm_lines lines / $cm_bytes bytes — over the 300-line/20000-byte guideline; run the harness-setup skill's leanness audit to trim restatement (directory tours, framework defaults, formatter-enforced style — not the contract's six items themselves)"
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

# --- settings.json toolchain allow-list ----------------------------------------
# Read only through jq below — never a raw-text grep/sed/awk of $settings. A raw-text read
# makes a rule merely *mentioned* in an unrelated string (an env value, a comment-ish string)
# count as present, and can't tell the allow array from the deny array (a deny-side `-C` mirror
# pasted into the allow array would still read as "present" to a whole-file grep). Pre-initialise
# allow_raw/deny_raw/settings_ok unconditionally: the script runs under set -u, and the policy
# activation section below reads them regardless of which branch this if/elif/elif/else takes.
settings="$claude_dir/settings.json"
allow_raw=""
deny_raw=""
settings_ok=false
if [ ! -f "$settings" ]; then
  bad "no .claude/settings.json — create one from the plugin's templates/repo-settings.json (permissions + enabledPlugins); plugins cannot ship permission grants"
elif ! $jq_ready; then
  wrn "skipped the .claude/settings.json permission checks (jq not installed — see the FAIL above)"
elif ! jq -e . "$settings" >/dev/null 2>&1; then
  bad ".claude/settings.json does not parse as JSON — Claude Code cannot load these rules, so every grant and deny in the file is inoperative; fix the syntax (a trailing comma is the usual cause) and re-run"
else
  settings_ok=true
  allow_raw="$(jq -r '.permissions.allow[]? // empty' "$settings" 2>/dev/null)"
  deny_raw="$(jq -r '.permissions.deny[]? // empty' "$settings" 2>/dev/null)"

  has_marker() { find "$root" -maxdepth 2 -name "$1" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | grep -q .; }
  # entry_has LIST PREFIX — literal prefix test over a newline-separated entry list (no regex),
  # mirroring how Claude Code matches Bash permission rules against a command string.
  entry_has() { printf '%s\n' "$1" | awk -v p="$2" 'index($0, p) == 1 { hit = 1 } END { exit !hit }'; }
  allow_has()  { printf '%s\n' "$allow_raw" | grep -qE "^Bash\\(($1)"; }
  tool_warns=0
  if has_marker package.json   && ! allow_has "npm|pnpm|yarn|bun";          then wrn "package.json found but no npm/pnpm/yarn/bun in the settings.json allow-list"; tool_warns=1; fi
  if { has_marker pyproject.toml || has_marker requirements.txt || has_marker pytest.ini; } && ! allow_has "pytest|python|uv|poetry|tox"; then wrn "Python project files found but no pytest/python/uv/poetry in the allow-list"; tool_warns=1; fi
  if has_marker Cargo.toml     && ! allow_has "cargo";                      then wrn "Cargo.toml found but no cargo in the allow-list"; tool_warns=1; fi
  if has_marker go.mod         && ! allow_has "go";                         then wrn "go.mod found but no go in the allow-list"; tool_warns=1; fi
  if has_marker Makefile       && ! allow_has "make";                       then wrn "Makefile found but no make in the allow-list"; tool_warns=1; fi
  if has_marker Gemfile        && ! allow_has "bundle|rake|rspec";          then wrn "Gemfile found but no bundle/rake/rspec in the allow-list"; tool_warns=1; fi
  if [ "$tool_warns" -eq 0 ]; then
    ok "settings.json allow-list covers the detected toolchain(s) (subagents can't prompt for permissions — this matters)"
  fi
  # Sentinel: are the harness's own commands allowed? Deliberately a *substring* test over the
  # extracted allow entries, not a prefix test like entry_has — this matches both the bare-name
  # plugin entries and legacy .claude-path entries (e.g.
  # "Bash(.claude/scripts/find-planning-work.sh:*)"), which contain the script name but not as
  # a prefix of the entry.
  if printf '%s\n' "$allow_raw" | grep -qF -- "find-planning-work.sh"; then
    ok "harness script commands are in the allow-list"
  else
    wrn "harness script commands (e.g. find-planning-work.sh) not found in the allow-list — copy the permissions block from the plugin's templates/repo-settings.json"
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
        printf '%s\n' "$2" | grep -qxF -- "$e" && continue
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
  fi
fi

# --- policy activation state (informational) -------------------------------------
# Reports whether an optional CLAUDE.md policy section is *activated* by its companion
# permission-file edit — never whether the policy prose itself is any good (that quality
# judgment stays with the harness-setup skill), and never auto-fixes anything: every WARN below
# names the human's edit. Permission-state accuracy is per-file (.claude/settings.json only) —
# a deny/allow in .claude/settings.local.json or ~/.claude/settings.json can still change the
# effective answer; messages are worded about this file, not about effective permission.
if [ ! -f "$root/CLAUDE.md" ]; then
  wrn "policy activation checks skipped (no CLAUDE.md)"
else
  # --- merge autonomy (#28) --- exactly one 'merge autonomy: ' line; states mutually exclusive.
  if ! $settings_ok; then
    wrn "merge autonomy: activation state unknown — .claude/settings.json is missing or unreadable (see the FAIL/WARN above)"
  else
    merge_denied=false
    entry_has "$deny_raw" "Bash(gh pr merge" && merge_denied=true
    merge_allowed=false
    entry_has "$allow_raw" "Bash(gh pr merge" && merge_allowed=true
    has_merge_policy=false
    has_policy_section "Merge autonomy policy" && has_merge_policy=true

    if $has_merge_policy && $merge_denied; then
      wrn "merge autonomy: half-activated — 'Merge autonomy policy' section present but 'Bash(gh pr merge:*)' is still denied in .claude/settings.json, so the cycle reports 'verified, merge blocked' instead of merging; to activate, remove \"Bash(gh pr merge:*)\" from permissions.deny AND add it to permissions.allow in .claude/settings.json (both edits are yours, never an agent's)"
    elif $has_merge_policy && ! $merge_denied && $merge_allowed; then
      ok "merge autonomy: active ('Merge autonomy policy' section present, deny lifted, allow entry present)"
    elif $has_merge_policy && ! $merge_denied && ! $merge_allowed; then
      wrn "merge autonomy: deny on 'Bash(gh pr merge:*)' lifted but no matching allow entry in .claude/settings.json — unattended cycles will stall on the permission prompt; add the allow entry"
    elif ! $has_merge_policy && ! $merge_denied; then
      wrn "merge autonomy: 'Bash(gh pr merge:*)' deny lifted but no 'Merge autonomy policy' section in CLAUDE.md — the cycle skips the merge pass anyway; add the section (or restore the deny)"
    else
      ok "merge autonomy: off (default — no 'Merge autonomy policy' section, deny in place; every PR merge is manual)"
    fi
  fi

  # --- test-suite ratchet (#45) --- the doctor never executes the measurement command it finds:
  # command -v is a lookup, not an execution, and the extracted token is only ever a quoted
  # argument — never eval'd, never expanded. See the header comment for why.
  if ! has_policy_section "Test-suite ratchet policy"; then
    ok "test-suite ratchet: off — no 'Test-suite ratchet policy' section in CLAUDE.md, so the ratchet never runs"
  else
    bt="$(printf '\140')"
    # Documented heuristic (like 1.4 in dev/selfcheck.sh): the first backtick-quoted span in
    # the section is taken as the measurement command.
    sec="$(awk '/^#+[[:space:]]+Test-suite ratchet policy[[:space:]]*$/ { inx=1; next } inx && /^#+[[:space:]]/ { exit } inx { print }' "$root/CLAUDE.md")"
    span="$(printf '%s\n' "$sec" | grep -o "${bt}[^${bt}]*${bt}" | head -1 | tr -d "$bt")"
    if [ -z "$span" ]; then
      wrn "test-suite ratchet: 'Test-suite ratchet policy' section present but names no backtick-quoted measurement command ('No command ⇒ no ratchet') — the ratchet won't run until one is added"
    else
      tok="$(printf '%s' "$span" | awk '{print $1}')"
      if printf '%s' "$tok" | grep -qE '^[A-Za-z0-9._/-][A-Za-z0-9._/+-]*$'; then
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
fi

# --- verification baseline ------------------------------------------------------
# BASELINE.md records THIS machine's last known-green run of the verification commands
# on the default branch (full commit SHA + per-command results). It is machine-local
# state: gitignored, written by harness-setup, refreshed by the implementer/cycle skills.
baseline="$claude_dir/BASELINE.md"
if [ -f "$baseline" ]; then
  recorded="$(sed -nE 's/^- commit:[[:space:]]*([0-9a-f]+).*/\1/p' "$baseline" | head -1)"
  current=""
  [ -n "$default_branch" ] && current="$(git rev-parse "origin/$default_branch" 2>/dev/null || true)"
  if [ -z "$recorded" ]; then
    wrn "BASELINE.md present but no '- commit:' line found — re-run the harness-setup skill to re-record it"
  elif [ -n "$current" ] && [ "$recorded" != "$current" ]; then
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
if $gh_ready && [ -n "$default_branch" ]; then
  repo_slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null | tr -d '\r' || true)"
  if [ -n "$repo_slug" ] && gh api "repos/$repo_slug/branches/$default_branch/protection" >/dev/null 2>&1; then
    ok "branch protection enabled on $default_branch"
  else
    wrn "no branch protection detected on $default_branch (or no admin scope to check) — recommended: require a PR before merge; it's the real backstop behind the deny-list"
  fi
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
