#!/usr/bin/env bash
#
# check-harness.sh — preflight "doctor" for the issue-workflow harness.
#
# Checks everything mechanical the harness needs in a repo: gh/jq, the git remote,
# the lifecycle labels, executable scripts, a CLAUDE.md with a verification section,
# LESSONS.md, the settings.json toolchain allow-list, and branch protection.
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
if command -v jq >/dev/null 2>&1; then
  ok "jq installed"
else
  bad "jq not installed — the discovery scripts need it"
fi

# --- default branch -----------------------------------------------------------
default_branch=""
if $gh_ready; then
  default_branch="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || true)"
fi
if [ -n "$default_branch" ]; then
  ok "default branch: $default_branch"
else
  wrn "could not determine the default branch via gh (remote/auth issue?)"
fi

# --- lifecycle labels ---------------------------------------------------------
if $gh_ready; then
  existing="$(gh label list --limit 200 --json name --jq '.[].name' 2>/dev/null || true)"
  missing=""
  for l in plan-proposed plan-approved pr-open impl-blocked no-plan; do
    echo "$existing" | grep -qx "$l" || missing="$missing $l"
  done
  if [ -z "$missing" ]; then
    ok "all 5 lifecycle labels exist"
  else
    bad "missing labels:$missing — run: bash .claude/skills/issue-planner/scripts/setup-labels.sh"
  fi
else
  wrn "skipped label check (gh not ready)"
fi

# --- harness scripts executable (auto-fix) -------------------------------------
fixed=""
for s in "$claude_dir"/skills/*/scripts/*.sh; do
  [ -f "$s" ] || continue
  if [ ! -x "$s" ]; then chmod +x "$s" && fixed="$fixed ${s#"$root"/}"; fi
done
if [ -n "$fixed" ]; then
  ok "harness scripts executable (auto-fixed:$fixed)"
else
  ok "harness scripts are executable"
fi

# --- CLAUDE.md ----------------------------------------------------------------
if [ -f "$root/CLAUDE.md" ]; then
  if grep -qiE '(verif|## *test|test suite|typecheck|lint gate|npm run build|pytest|cargo test|go test|make test)' "$root/CLAUDE.md"; then
    ok "CLAUDE.md present with a verification-ish section (quality audit = harness-setup skill)"
  else
    wrn "CLAUDE.md present but no verification/test section found — subagents won't know what 'done' means; run the harness-setup skill"
  fi
else
  bad "no CLAUDE.md — the harness contract requires one (conventions + verification commands); the harness-setup skill can draft it"
fi

# --- LESSONS.md (auto-seed) ----------------------------------------------------
if [ -f "$claude_dir/LESSONS.md" ]; then
  ok "LESSONS.md present"
else
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
settings="$claude_dir/settings.json"
if [ -f "$settings" ]; then
  has_marker() { find "$root" -maxdepth 2 -name "$1" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | grep -q .; }
  allow_has()  { grep -qE "Bash\\(($1)" "$settings"; }
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
else
  bad "no .claude/settings.json — the harness's permission grants are missing"
fi

# --- branch protection ----------------------------------------------------------
if $gh_ready && [ -n "$default_branch" ]; then
  repo_slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
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
