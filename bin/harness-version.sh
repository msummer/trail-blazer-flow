#!/usr/bin/env bash
#
# harness-version.sh — prints the installed harness plugin's version and, when resolvable, its
# short commit SHA: one durable line, "<version> <sha>", that every plan comment, verifier-verdict
# archive, PR body, cycle report header, and harness-status line records (see the RESOLVED
# rationale below for which surfaces carry it and which deliberately don't — #233).
#
# Usage:
#   harness-version.sh
#   harness-version.sh --help
#
# The plugin root is resolved from THIS SCRIPT'S OWN LOCATION (its parent directory), never from
# the caller's cwd — so it works identically from a marketplace cache
# (~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/bin/harness-version.sh) and from a
# developer checkout (<repo>/bin/harness-version.sh).
#
# VERSION: read from <plugin-root>/.claude-plugin/plugin.json's top-level "version" field via jq.
# A missing file, a missing field, unparseable JSON, or jq itself absent from PATH all resolve to
# the literal "unknown" (exit 1, diagnostic on stderr) — never a guess.
#
# SHA: a short commit SHA ONLY when <plugin-root>/.git exists — a marketplace cache is a plain
# directory tree, not a git checkout, so this is "-" there — and only then does this run
# `git -C <plugin-root> rev-parse --short HEAD`. The `.git`-presence guard is load-bearing:
# `git rev-parse` walks UP the directory tree looking for a repository, so without this guard a
# cache directory nested inside some enclosing repository (e.g. a dotfiles repo covering
# ~/.claude/) would silently report THAT repository's SHA instead of "-". A repo that copies the
# harness's bin/ scripts into its own .claude/ (rather than installing the plugin) resolves
# neither half and gets "unknown -".
#
# `git -C` inside this script is fine even though it's a `bin/` script the model can invoke:
# hooks/git-c-guard.sh's PreToolUse guard only inspects Bash commands the MODEL issues, never
# what a plain bin/ script does internally once it's already been approved to run as a whole.
#
# OUTPUT: exactly one line on stdout, "<version> <sha>" — always printed, even on failure, so a
# caller that only checks exit status still gets a best-effort line to paste.
#
# EXIT CODES: 0 = version resolved; 1 = version unresolved ("unknown", diagnostic on stderr);
# -h/--help = usage on stdout, exit 0; any other argument = usage on stderr, exit 2.
#
# RESOLVED (#233): the version line is recorded on exactly the four durable artifacts the issue's
# Decision names — the planner's plan comment, the verifier-verdict archive comment, the PR body,
# and the cycle report header — plus every `<!-- harness-status: ... -->` line, as a trailing
# `harness=<version>` field. It deliberately does NOT appear on: audit/hold/staleness/escalation
# comments (pure bookkeeping, not an artifact a human diffs run-to-run), the proposed-answers and
# plan-staleness-note comments (deliberately unmarked already — see issue-planner SKILL.md's
# "Harness-authored records" section — adding a version line would put a second marker on a
# comment that must stay unmarked to keep working as feedback), and the implementer's blocked-path
# comment (also deliberately unmarked, for the identical reason).
#
# Read-only: makes no network call, writes nothing, touches only its own plugin directory (a
# `git rev-parse` inside it).
set -uo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
plugin_root="$script_dir/.."

# The two machine-readable literals dev/selfcheck.sh's assertion 4.37 extracts (anchored
# sed -nE) and requires verbatim in the writer surfaces (skills/issue-planner/SKILL.md,
# skills/issue-implementer/SKILL.md) and the reader surfaces (bin/reconcile-ledger.sh,
# skills/issue-implementer/SKILL.md, skills/issue-cycle/SKILL.md, and the three agents/*.md
# templates) — the same anchored KEY="value" extraction idiom as bin/harness-lock.sh's
# LOCK_SUBCOMMANDS= line.
HARNESS_VERSION_STEM="<!-- harness-version:"
HARNESS_STATUS_FIELD="harness=<version>"

usage() {
  cat <<'EOF'
usage: harness-version.sh
       harness-version.sh --help

Prints the installed harness plugin's version and short commit SHA (when resolvable) as one
line: "<version> <sha>". The plugin root is this script's own parent directory, so it works from
a marketplace cache or a developer checkout alike; "<sha>" is "-" outside a git checkout.

Exit codes: 0 = version resolved, 1 = version unresolved (still prints a best-effort line,
diagnostic on stderr), 2 = usage error (unknown argument).
EOF
  printf '\nMachine-readable literals this script defines (dev/selfcheck.sh assertion 4.37 matches\nthem against the writer/reader surfaces): HARNESS_VERSION_STEM=%s HARNESS_STATUS_FIELD=%s\n' \
    "\"$HARNESS_VERSION_STEM\"" "\"$HARNESS_STATUS_FIELD\""
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ "$#" -gt 0 ]; then
  usage >&2
  exit 2
fi

version="unknown"
resolved=false
if command -v jq >/dev/null 2>&1; then
  v="$(jq -r '.version // empty' "$plugin_root/.claude-plugin/plugin.json" 2>/dev/null || true)"
  if [ -n "$v" ] && [ "$v" != "null" ]; then
    version="$v"
    resolved=true
  fi
fi

sha="-"
if command -v git >/dev/null 2>&1 && [ -e "$plugin_root/.git" ]; then
  s="$(git -C "$plugin_root" rev-parse --short HEAD 2>/dev/null || true)"
  [ -n "$s" ] && sha="$s"
fi

printf '%s %s\n' "$version" "$sha"

if $resolved; then
  exit 0
fi
echo "harness-version.sh: could not resolve the plugin version from $plugin_root/.claude-plugin/plugin.json (missing file, missing .version field, unparseable JSON, or jq not on PATH)" >&2
exit 1
