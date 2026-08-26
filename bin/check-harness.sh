#!/usr/bin/env bash
#
# check-harness.sh — preflight "doctor" for the issue-workflow harness.
#
# Checks everything mechanical the harness needs in a repo: gh/jq, the git remote,
# the lifecycle labels, executable scripts, a CLAUDE.md with a verification section and a
# size guideline, LESSONS.md, the settings.json toolchain allow-list (read exclusively through
# jq — never a raw-text grep/sed/awk of any settings* path variable), whether a path-qualified
# verification interpreter (e.g. <repo>/api/.venv/bin/python, as worktree-parallel mode
# instructs) has a matching literal-path allow entry, whether the "Merge autonomy
# policy" section is activated by the effective merge-permission state across
# .claude/settings.json, .claude/settings.local.json, and the user-level settings file (a deny in
# any of them wins, regardless of allows elsewhere — union semantics, not just the checked-in
# file), whether its optional "Post-merge verification" declaration is present and, if so,
# fenced (declared/no-fence/not-declared — never whether the declared commands are any good) and
# whether each declared command's first token has a matching allow entry in
# .claude/settings.json, whether a "Test-suite ratchet policy" section exists and names a
# measurement command via a fence-aware, depth-aware section slice (looked up with `command -v`,
# never executed), whether "Autonomy reserve" and "Autonomy decision record" sections are
# declared and well-formed (and, when gh is ready, whether the declared grant label exists —
# never applied, removed, or judged for content), the verification baseline (.claude/BASELINE.md,
# machine-local — an abbreviated recorded commit SHA of 7+ hex characters is accepted as a
# prefix), whether the template's branch-scoped deny entries actually cover this repo's default
# branch, whether any of the three settings files disables all hooks (silently disabling the
# plugin's `git -C` guard hook, and every other hook), whether `.claude/settings.json` still
# carries legacy `Bash(git -C * <sub> *)` allow entries the guard hook now supersedes (#150 —
# Claude Code 2.1.246+ warns about these at startup), and branch protection.
#
# The test-suite-ratchet check never executes, evals, or shells out to anything read from
# CLAUDE.md: it only looks up the measurement command's first word with `command -v` (a lookup,
# not an execution) and prints it back, quoted, as a report. The post-merge-verification
# declaration-state check carries a related guarantee: it never executes, evals, `command -v`'s,
# or expands a declared command either — the derived values it prints are an integer count of
# fenced command lines and, when a declared command's first token has no matching allow entry, a
# WARN echoing that token and the literal `Bash(<token>:*)` entry to add, produced by a pure
# string comparison (entry_has) against the settings allow list, never a lookup or an execution.
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
has_verification_heading() {
  awk '
    /^#+[[:space:]]/ {
      h = $0
      sub(/^#+[[:space:]]+/, "", h)
      sub(/[[:space:]]+$/, "", h)
      if (tolower(h) ~ /^verification/) { print "found"; exit }
    }
  ' "$root/CLAUDE.md" | grep -q .
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
existing=""
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
    wrn "CLAUDE.md size: $cm_lines lines / $cm_bytes bytes — over the 300-line/20000-byte guideline; run the harness-setup skill's leanness audit to trim restatement (directory tours, framework defaults, formatter-enforced style — not the contract's eight items themselves)"
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
# Read only through jq below — never a raw-text grep/sed/awk of any settings* path variable
# (every settings-file path variable in this script is named settings*, so dev/selfcheck.sh's
# assertion 4.11 catches a raw-text read of any of them). A raw-text read makes a rule merely
# *mentioned* in an unrelated string (an env value, a comment-ish string) count as present, and
# can't tell the allow array from the deny array (a deny-side `-C` mirror pasted into the allow
# array would still read as "present" to a whole-file grep). Pre-initialise allow_raw/deny_raw
# unconditionally: the script runs under set -u. Both are scoped to THIS file only — the
# toolchain allow-list, harness-script sentinel, template-drift, and #54 guard-coverage checks
# below all judge .claude/settings.json by design (it is the shared, checked-in file). The
# merge-autonomy verdict further down runs its own three-file scan instead (see below).
settings="$claude_dir/settings.json"
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

  has_marker() { find "$root" -maxdepth 2 -name "$1" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | grep -q .; }
  allow_has()  { printf '%s\n' "$allow_raw" | grep -qE "^Bash\\(($1)"; }
  tool_warns=0

  # --- path-qualified verification interpreter (#132/#128) --- a bare-name allow entry
  # (Bash(pytest:*)) does not cover a path-qualified interpreter
  # (<repo>/api/.venv/bin/python -m pytest, which worktree-parallel mode's step d instructs —
  # see skills/issue-implementer/references/worktree-mode.md): Claude Code's permission matching
  # is a literal prefix test, not a basename match, so allow_has's regex would falsely reassure
  # (it only checks whether some settings.json allow ENTRY starts with a bare interpreter name
  # like Bash(python — it never looks at the path-qualified token itself) while the grant that
  # actually covers the command is the literal path itself. Scan the verification-scope
  # candidates (whole file when no "Verification…" heading exists — Q2, ACCEPTED), take each
  # candidate's first whitespace-delimited token, and keep the FIRST one that both contains a
  # '/' and whose basename is a known Python-family interpreter name. entry_has (literal prefix
  # test) is used to probe the grant — never allow_has (a regex test unsuited to matching a
  # literal path).
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
      if entry_has "$allow_raw" "Bash($py_path_tok"; then
        py_path_covered=true
      else
        case "$py_path_tok" in
          /*|?:/*) : ;;
          *) entry_has "$allow_raw" "Bash($root/$py_path_tok" && py_path_covered=true ;;
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

  if has_marker package.json   && ! allow_has "npm|pnpm|yarn|bun";          then wrn "package.json found but no npm/pnpm/yarn/bun in the settings.json allow-list"; tool_warns=1; fi
  if { has_marker pyproject.toml || has_marker requirements.txt || has_marker pytest.ini; } && ! allow_has "pytest|python|uv|poetry|tox" && ! $py_path_covered; then wrn "Python project files found but no pytest/python/uv/poetry in the allow-list"; tool_warns=1; fi
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

# --- settings-file candidates for the merge-autonomy verdict (#66) ---------------------------
# The three files whose union decides effective merge permission — see the header.
settings_local="$claude_dir/settings.local.json"
settings_user="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/settings.json"
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  settings_user_label="$CLAUDE_CONFIG_DIR/settings.json"
else
  settings_user_label="~/.claude/settings.json"
fi

# Per-file merge-rule scan, read ONLY through jq (see above, and #66). NEVER piped from the
# heredoc's producer side — a `| while read` here would run the loop in a subshell and lose
# every accumulator below the moment the loop exits (same idiom as diff_side/guard_missing
# above). The user-level file is read no differently than the other two — same two jq paths,
# .permissions.deny[]?/.permissions.allow[]? — and only ever contributes its LABEL to
# merge_deny_src/merge_allow_src below; no entry from it, nor anything else in the file, is ever
# printed, diffed, or counted.
broken_list=""
read_list=""
merge_deny_src=""
merge_allow_src=""
disable_hooks_src=""
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
    file_disable="$(jq -r '.disableAllHooks? // empty' "$settings_file" 2>/dev/null)"
    [ "$file_disable" = "true" ] && disable_hooks_src="$disable_hooks_src$settings_label, "
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

# --- disableAllHooks (#150) -------------------------------------------------------------------
# A true value in ANY of the three settings files silently disables every hook, including the
# plugin's `git -C` guard hook — worktree-parallel mode's `git -C` commands then prompt in
# default mode (or, headless, stall unattended, since a subagent can't answer a prompt). Never
# FAILs: disabling hooks is a legitimate choice, this just names the consequence.
if [ -n "$disable_hooks_src" ]; then
  wrn "disableAllHooks: true in $disable_hooks_src — the plugin's git -C guard hook (and every other hook) cannot run, so worktree-parallel mode's git -C commands prompt in default mode and an unattended run stalls"
fi

# --- policy activation state (informational) -------------------------------------
# Reports whether an optional CLAUDE.md policy section is *activated* by its companion
# permission-file edit, where it has one (the ratchet activates by naming a measurement command
# instead; plan auto-approval has no companion edit at all) — never whether the policy prose
# itself is any good (that quality judgment stays with the harness-setup skill), and never
# auto-fixes anything: every WARN below names the human's edit. Enterprise/managed settings are
# not read by this script at all.
if [ ! -f "$root/CLAUDE.md" ]; then
  wrn "policy activation checks skipped (no CLAUDE.md)"
else
  # --- merge autonomy (#28, #66) --- exactly one 'merge autonomy: ' line; states mutually
  # exclusive.
  has_merge_policy=false
  has_policy_section "Merge autonomy policy" && has_merge_policy=true

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
    $has_ci_workflow || merge_ci_note=" — but no .github/workflows file exists, so gh pr checks likely reports 'no checks configured', which the merge pass's hard floor treats as NOT green: no PR qualifies unless your 'Merge autonomy policy' section explicitly opts a no-CI repo in"

    if $has_merge_policy && $merge_denied; then
      wrn "merge autonomy: half-activated — 'Merge autonomy policy' section present but 'Bash(gh pr merge:*)' is still denied in $merge_deny_src — a deny wins over any allow, in any settings file; to activate, remove \"Bash(gh pr merge:*)\" from permissions.deny in $merge_deny_src AND add it to permissions.allow in .claude/settings.json (both edits are yours, never an agent's)"
    elif $has_merge_policy && ! $merge_denied && $merge_allowed; then
      ok "merge autonomy: active ('Merge autonomy policy' section present, no deny found in $read_list, allow present in $merge_allow_src)$merge_ci_note"
    elif $has_merge_policy && ! $merge_denied && ! $merge_allowed; then
      wrn "merge autonomy: deny on 'Bash(gh pr merge:*)' lifted (no deny found in $read_list) but no matching allow entry — unattended cycles will stall on the permission prompt; add the allow entry to .claude/settings.json, or to .claude/settings.local.json to opt in on this machine only"
    elif ! $has_merge_policy && ! $merge_denied; then
      wrn "merge autonomy: 'Bash(gh pr merge:*)' deny lifted (no deny found in $read_list) but no 'Merge autonomy policy' section in CLAUDE.md — the cycle skips the merge pass anyway; add the section (or restore the deny)"
    else
      ok "merge autonomy: off (default — no 'Merge autonomy policy' section, deny in place in $merge_deny_src; every PR merge is manual)"
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
  # command -v's, or expands anything read from the declaration.
  if $has_merge_policy; then
    merge_sec="$(claude_md_section "Merge autonomy policy")"
    postdeploy_found=false
    if printf '%s\n' "$merge_sec" | awk '
      /^```/ { infence = !infence; next }
      !infence && /^#+[[:space:]]+Post-merge verification[[:space:]]*$/ { print "found"; exit }
    ' | grep -q .; then
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

        # --- post-merge allow-entry check (#138, #142) --- when .claude/settings.json was
        # readable (allow_list_read), checks each declared line's first whitespace-delimited
        # token against allow_raw with entry_has: a plain prefix test, NOT the rule-boundary
        # variant deny_guards uses above — deliberately, so an arg-scoped grant such as
        # Bash(tbf-boobytrap --smoke:*) still counts as covering the bare command. A pure string
        # comparison: never command -v's, evals, or expands the token. Skipped silently when
        # allow_list_read is false — the settings block above already FAILs/WARNs loudly about
        # the unreadable file, so a second "check skipped" line here would be noise.
        if $allow_list_read; then
          pd_seen=""; pd_missing=""; pd_entries=""; pd_checked=0
          while IFS= read -r line; do
            [ -n "$line" ] || continue
            tok="$(printf '%s\n' "$line" | awk '{print $1}')"
            [ -n "$tok" ] || continue
            case "$tok" in
              '#'*) continue ;;
            esac
            printf '%s' "$tok" | grep -qE '^[A-Za-z0-9._/-][A-Za-z0-9._/+-]*$' || continue
            printf '%s\n' "$pd_seen" | grep -qxF -- "$tok" && continue
            pd_seen="${pd_seen}${tok}"$'\n'
            pd_checked=$((pd_checked+1))
            if entry_has "$allow_raw" "Bash($tok"; then
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
            wrn "post-merge verification: declared command(s) with no matching allow entry: $pd_missing — add $pd_entries to permissions.allow in .claude/settings.json (checked against .claude/settings.json only); without the grant the cycle's merge pass records deploy=pending, not shipped"
          elif [ "$pd_checked" -gt 0 ]; then
            ok "post-merge verification: every declared command has a matching allow entry ($pd_checked checked; string comparison only, never executed or looked up)"
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
        if printf '%s\n' "$existing" | grep -qx "$scoped_grant_label"; then
          :
        else
          wrn "scoped autonomy: grant label '$scoped_grant_label' does not exist on this repo — run: gh label create \"$scoped_grant_label\" (the harness never applies or removes it, only reports whether it exists)"
        fi
      else
        wrn "scoped autonomy: grant label '$scoped_grant_label' existence unknown (gh not ready)"
      fi
    fi
  fi
fi

# --- verification baseline ------------------------------------------------------
# BASELINE.md records THIS machine's last known-green run of the verification commands
# on the default branch (commit SHA + per-command results). It is machine-local
# state: gitignored, written by harness-setup, refreshed by the implementer/cycle skills.
# harness-setup still writes the full 40-char SHA; the doctor merely tolerates an abbreviated
# recorded value of at least 7 hex characters, treating it as a prefix of the remote tip.
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
