#!/usr/bin/env bash
#
# doctor-tests.sh — fixture-based negative-test harness for the CONSUMER doctor
# (bin/check-harness.sh), its scoped-autonomy companion script (bin/check-decision-record.sh), and
# (#408) the Codex compatibility installer (bin/codex-setup.sh) — not this repo's own gate (that's
# dev/selfcheck.sh + dev/selfcheck-tests.sh). Builds throwaway
# git repos under mktemp, runs a COPY of the real scripts against each, and pins verdicts that
# were previously only hand-verified: the settings.json block, the template-diff scenarios, the
# ratchet's never-execute guarantee, entry_has's allow/deny distinction, the active verdict's
# no-CI note, default-branch guard coverage, the half-activated remediation's file naming, the
# scoped-autonomy declarations (the doctor's verdict block and check-decision-record.sh's
# per-element PASS/FAIL report — a fence-aware, depth-aware scan that requires each declared
# heading to be found nested under the record-section heading (strictly deeper, before the next
# same-or-shallower heading outside a fence — a same-depth heading is not nested) AND to have at
# least one non-blank content line in its in-section span, distinguishing "heading absent" from
# "heading found outside the record section" from "heading found, no content under it";
# counting content under a deeper sub-heading or inside a fenced block; requiring whitespace
# after the heading's '#' run; and tracking backtick- and tilde-fences of any matching length,
# indented up to 3 spaces, closing only on a same-character run at least as long followed by
# nothing but whitespace), the
# post-merge-verification declaration-state line (declared
# count / no-fence WARN / not-declared, with the same never-execute guarantee as the ratchet) and
# its allow-entry check (each declared command's first token against the three-file settings
# allow-list union — .claude/settings.json, .claude/settings.local.json, and the user-level
# settings file, so a grant that lives only in .claude/settings.local.json or the user-level file
# still counts as covered — a pure string comparison, WARN never FAIL when a grant is missing),
# the bare-name toolchain allow-list check and the path-qualified verification interpreter's
# literal-path grant check, both against that same three-file union (#175 — a toolchain grant
# living only in .claude/settings.local.json no longer produces a spurious WARN), the test-suite
# ratchet's fence-aware, depth-aware section slice and fence-delimiter-skipping span hunt (a '#'
# comment inside the fenced block must not truncate it, nor must a bare fence line itself be
# mistaken for the quoted command), the verification baseline's short-SHA-as-prefix compare (an
# abbreviated recorded commit of 7+ hex characters is accepted; fewer is a malformed-value WARN),
# the disableAllHooks: true WARN across the three settings files (#150 — silently disables the
# plugin's git -C guard hook, and every other hook, including (#235) the implementer/verifier
# agent-boundary hook, whose absence is silent rather than a prompt), the
# stale-legacy-'-C'-allow-entry WARN on
# .claude/settings.json (#150 — the entries the guard hook now supersedes), and (#175, ex-#166,
# widened by #179, widened again by #186) the CI action pinning WARN — gated on $merge_effective
# (merge autonomy effectively active: a "Merge autonomy policy" section, or #311's "Autonomy mode"
# implying it for harness PRs only), it lists any `uses:` ref in .github/workflows/*.yml|*.yaml
# AND in any action.yml/action.yaml anywhere in the repo (pruning .git/, node_modules/, and
# .github/workflows/ so a local composite action is found regardless of where it lives, and a
# workflow file literally named action.yml is never double-counted) — local (./…, ../…) and
# docker:// refs excepted in both file classes — not pinned to a full 40-hex commit SHA,
# comment-stripped by line, string comparison only, never executed, (#233) the installed
# harness version report — bin/harness-version.sh's printed "<version> <sha>" line surfaced
# verbatim as a PASS when resolvable, a WARN (never a FAIL) naming the expected fixed path when
# it isn't, (#234, review F4) the branch-protection document's up-to-date strictness — only when
# merge autonomy is effectively active ($merge_effective, same combination as the CI-pinning gate
# above) and a successful protection endpoint call,
# required_status_checks.strict (WARN when not exactly true), the required-status-check-context
# count via max(checks|length, contexts|length) (WARN when zero, including when
# required_status_checks itself is absent), and required PR reviews (informational PASS either
# way) — WARN-only, never FAIL, silent with the mode off and no policy section, and unaffected by
# (never reading) $has_merge_policy/$merge_effective while unset on a repo with no CLAUDE.md at
# all, (#262-2) bin/harness-version.sh's own `.git`-presence guard: run directly (not through the
# doctor), a cache-shaped copy nested inside an enclosing repo with a resolvable HEAD prints
# "<version> -", never that repo's short sha, paired with a non-vacuity control whose plugin root
# is itself the checkout, and (#311) the optional "Autonomy mode" section — validated as a
# combination, not a single flag: PASS off/WARN inert/PASS autonomous (naming the effective
# kickback budget, default 2, bounded 0-3 with a WARN and fallback to the default otherwise), the
# implied widening of merge autonomy above, and, only in autonomous mode, an informational
# permissions.defaultMode PASS reporting a validated bare word (or "(unset)"/"(unrecognised
# value)") per settings file read — never an allow/deny entry, from any of the three files,
# including the user-level one, and (#331, folds in #330) bin/governance-paths.sh — the merge
# floor's governance-path classifier — run directly in both its floor mode (base/head object ids)
# and its --check mode (a CLAUDE.md's "Governance paths" section), pinning the built-in rules,
# --no-renames, the declared-glob grammar (only the first fenced block, comment/blank lines
# skipped, case-insensitive, final-segment vs whole-path matching, trailing-slash-means-beneath),
# the add-only OR of built-in and declared, the base-tip-only read, the lessons-only exact-set
# compare, every malformed reason token, and every fail-closed error path (bad arguments before
# any git call, a git failure, an empty diff, a control-character path) — plus the doctor's own
# validation-only wrapper around it (PASS none/declared <n>, WARN malformed/could not validate,
# never FAIL), and (#408) bin/codex-setup.sh — the Codex compatibility installer, whose own
# `--check` drift mode is #410's companion, hence living here rather than in a new suite — run
# directly against a fake Codex plugin-cache install (mk_cx_plugin, a copy of this checkout's
# bin/*.sh, agents/*.md and templates/codex.rules) and fixture repos it builds for that purpose
# (mk_cx_repo): write mode and `--check` alike, pinning the generated agent TOMLs' byte-fidelity
# to agents/*.md (name, escaped description, developer_instructions body), the installed rules
# file's allow/forbidden/gated content against templates/repo-settings.json and bin/ themselves,
# contract loading into either an AGENTS.md pointer block or a .codex/config.toml fallback key,
# every `--check` drift token (missing/differs/stale-plugin-path/missing-fallback/
# fallback-conflict/missing-pointer/malformed-pointer), and the whitespace/unsupported-character
# path refusals — plus the never-writes guarantee `--check` makes, and (#410)
# `bin/check-harness.sh --provider codex` — a separate check set from the Claude branch above,
# run against fixtures built by mk_cx_doctor (a copy of THIS checkout's own hooks/hooks.json
# alongside a fake Codex plugin-cache install, plus a repo with the Codex compatibility layer
# already installed via run_cx) and a stub `codex` (build_stub_codex): the numeric (not lexical)
# version-floor compare, whitespace in the plugin/repo path, `codex-setup.sh --check` drift
# relayed verbatim, a bounded `codex app-server` `hooks/list` exchange (an initialize request
# naming this doctor and the plugin version in clientInfo — required before a real app-server
# answers anything else — plus the initialized notification and one hooks/list request, tolerant
# of a notification and a non-JSON line, bounded by up to CODEX_HOOKS_LIST_WAIT + 2 one-second
# polls plus a kill fallback so a hung app-server can never hang this suite) that only ever
# reports hook trust (`trusted`/`managed` pass; anything else, or a hook the plugin ships but
# Codex doesn't load, FAILs; a key is sanitised before it's ever printed; an empty expected-hook
# set — hooks/hooks.json missing, unreadable, or unparseable — FAILs before the exchange even
# starts; never trusts anything itself), the manual-merge report, and the Codex-specific FAIL
# arms on branch protection (a WARN on Claude Code) — plus that every settings/toolchain/policy
# line is absent on Codex, and that an unrecognised argument (including a bare --provider with no
# value) exits 2 on both providers.
#
# Usage: bash dev/doctor-tests.sh [name-filter] — same output contract as
# dev/selfcheck-tests.sh: one PASS/FAIL line per case, a `== summary: N pass, M fail ==` footer,
# exit 0 iff nothing failed; a filter with no match exits 1.
#
# Every write happens under one `mktemp -d` root, removed via an EXIT trap; this repo's own .git
# is never opened. Each fixture gets its OWN copy of bin/check-harness.sh + its template (the
# doctor derives the template path from $0, so "template missing" is otherwise untestable
# against the real tree); every run points HOME/CLAUDE_CONFIG_DIR into the fixture and prepends
# a stub `gh` (offline, deterministic, FAIL-free) to PATH, so a developer's real
# ~/.claude/settings.json or gh session can never leak into a verdict. Every `--provider codex`
# run also isolates CODEX_HOME into the fixture and puts a stub `codex` first on PATH (or, for
# the tool-absence cases, uses a codex-free tool farm with no fallback to the real PATH at all),
# so a developer's real Codex install can never leak into a verdict either.
#
# Prose coupling: the doctor has no verdict ids, so cases pin short, ASCII-only verdict STEMS
# (stop before its em dashes) plus machine-derived payloads — settings.json is always derived
# from the real template via jq, and the stub gh's labels come from bin/setup-labels.sh via the
# same sed idiom dev/selfcheck.sh's 4.6 uses. The stems themselves are the one hand-typed
# coupling left.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"

tmpbase="$(mktemp -d)"
cleanup() {
  if [ -n "$tmpbase" ] && [ -d "$tmpbase" ]; then
    rm -rf "$tmpbase"
  fi
}
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1; then
  echo "  FAIL  jq not installed — required to derive fixture settings.json variants from templates/repo-settings.json"
  exit 1
fi

# Captured before any PATH is handed to a fixture run — this process's own PATH is never
# mutated, only passed as an explicit PATHVAL to run_doctor's subprocess.
bash_bin="$(command -v bash)"

pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------------------------
# Fixture builders.

# write_settings DIR MODE — derives DIR/.claude/settings.json from the REAL
# templates/repo-settings.json via jq, so drift/merge payloads stay meaningful (never a
# hand-typed JSON blob that could drift from the template's actual shape).
write_settings() {
  local dir="$1" mode="$2" tmpl="$root/templates/repo-settings.json" out="$1/.claude/settings.json"
  case "$mode" in
    verbatim)
      jq '.' "$tmpl" > "$out" ;;
    unparseable)
      jq '.' "$tmpl" > "$out"
      printf '\nthis line is not valid JSON and breaks the parse\n' >> "$out" ;;
    drift)
      jq '.permissions.allow |= map(select(. != "Bash(git commit:*)")) |
          .permissions.deny  |= map(select(. != "Bash(git -C * clean*)"))' "$tmpl" > "$out" ;;
    merge-deny-lifted)
      jq '.permissions.deny |= map(select(. != "Bash(gh pr merge:*)"))' "$tmpl" > "$out" ;;
    merge-allow-only)
      jq '.permissions.deny  |= map(select(. != "Bash(gh pr merge:*)")) |
          .permissions.allow += ["Bash(gh pr merge:*)"]' "$tmpl" > "$out" ;;
    merge-mention-only)
      jq '.permissions.deny |= map(select(. != "Bash(gh pr merge:*)")) |
          . + {".env.NOTE": "mentions Bash(gh pr merge:*) here only, never in permissions.allow"}' "$tmpl" > "$out" ;;
    verify-path-grant)
      # Drops the bare "Bash(pytest:*)" template entry and replaces it with a literal-path grant
      # for THIS fixture's own venv interpreter (same $dir the CLAUDE.md fenced block's token is
      # built from — see mk_repo's verify-path-python variant) — deliberate, so the case proves
      # the path grant alone satisfies the Python toolchain check, with no bare-name entry left
      # to pass it by coincidence. This also re-raises the pre-existing allow-drift WARN (a
      # template entry is now missing); that WARN is expected and deliberately unasserted by the
      # cases that use this mode.
      jq --arg e "Bash($dir/.venv/bin/python:*)" \
        '.permissions.allow |= (map(select(. != "Bash(pytest:*)")) + [$e])' "$tmpl" > "$out" ;;
    postdeploy-grant)
      # merge-allow-only plus a grant for the boobytrap command the merge-postdeploy variant's
      # fenced block declares, so the post-merge allow-entry check (#138/#142) finds every
      # declared token covered.
      jq '.permissions.deny  |= map(select(. != "Bash(gh pr merge:*)")) |
          .permissions.allow += ["Bash(gh pr merge:*)", "Bash(tbf-boobytrap:*)"]' "$tmpl" > "$out" ;;
    stale-c-allow)
      # #150 deleted the nine `Bash(git -C * <sub> *)` allow entries from the live template, so
      # this fixture re-adds two of them by hand (necessarily a literal here — $tmpl no longer
      # carries any to copy from) to prove the doctor's stale-entry WARN fires on a repo that
      # never re-synced its settings.json after picking up the guard hook.
      jq '.permissions.allow += ["Bash(git -C * status *)", "Bash(git -C * push *)"]' "$tmpl" > "$out" ;;
    no-python-tool)
      # Drops the template's only Python-family entry so the bare-name toolchain check's Python
      # marker fails to match .claude/settings.json alone — a fixture then grants
      # "Bash(pytest:*)" only in .claude/settings.local.json (#175). Same note as
      # verify-path-grant above: this re-raises the pre-existing allow-drift WARN (a template
      # entry is now missing); that WARN is expected and deliberately unasserted by the cases
      # that use this mode.
      jq '.permissions.allow |= map(select(. != "Bash(pytest:*)"))' "$tmpl" > "$out" ;;
  esac
}

# mk_repo NAME VARIANT MODE — builds a fixture under $tmpbase/NAME: a fresh git repo with a
# fake, local-only origin remote, a private copy of the doctor + its template (own bin/ +
# templates/), home/ + claudecfg/ for HOME/CLAUDE_CONFIG_DIR isolation, a CLAUDE.md with a
# Verification heading plus VARIANT's optional policy section (merge|ratchet|none for base), and
# .claude/settings.json via write_settings — unless MODE is "missing". Prints the fixture path.
mk_repo() {
  local name="$1" variant="$2" mode="$3"
  local dir="$tmpbase/$name"
  mkdir -p "$dir/bin" "$dir/templates" "$dir/.claude" "$dir/home" "$dir/claudecfg"
  (cd "$dir" && git init -q && git remote add origin https://example.invalid/acme/demo.git)
  cp "$root/bin/check-harness.sh" "$dir/bin/check-harness.sh"
  chmod +x "$dir/bin/check-harness.sh"
  cp "$root/bin/check-decision-record.sh" "$dir/bin/check-decision-record.sh"
  chmod +x "$dir/bin/check-decision-record.sh"
  cp "$root/bin/harness-version.sh" "$dir/bin/harness-version.sh"
  chmod +x "$dir/bin/harness-version.sh"
  cp "$root/bin/governance-paths.sh" "$dir/bin/governance-paths.sh"
  chmod +x "$dir/bin/governance-paths.sh"
  mkdir -p "$dir/.claude-plugin"
  cp "$root/.claude-plugin/plugin.json" "$dir/.claude-plugin/plugin.json"
  cp "$root/templates/repo-settings.json" "$dir/templates/repo-settings.json"
  {
    printf '# CLAUDE.md\n\n## Verification\n\nRun `true` to verify. (fixture stub)\n'
    case "$variant" in
      merge)   printf '\n## Merge autonomy policy\n\nThe cycle may merge fixture PRs. (fixture stub policy)\n' ;;
      ratchet) printf '\n## Test-suite ratchet policy\n\nMeasure with `tbf-boobytrap --cov`. (fixture stub policy)\n' ;;
      ratchet-fenced)
        # Fence-aware-slice + fence-delimiter-skip regression pin (#137/#142,
        # .claude/LESSONS.md 2026-08-21): the "# a comment ..." line sits BETWEEN two data lines
        # inside the fenced block (not a heading, even though it starts with '#'), and the
        # backtick-quoted measurement command comes AFTER the fenced block closes — if it came
        # first, the old non-fence-aware slice would find it too and this case would not be a
        # regression pin.
        cat <<'EOF'

## Test-suite ratchet policy

Example measurement output:

```
lines 100
# a comment between two data lines
lines 200
```

Measure with `tbf-boobytrap --cov`. (fixture stub policy)
EOF
        ;;
      merge-postdeploy)
        # The fenced block's "# comment" line between two commands is the fence-awareness pin
        # .claude/LESSONS.md requires: a non-fence-aware section slice would read it as a
        # heading-shaped line and truncate before "tbf-boobytrap --health", undercounting the
        # declared-state line's non-blank-line count (3, not 2).
        cat <<'EOF'

## Merge autonomy policy

The cycle may merge fixture PRs. (fixture stub policy)

### Post-merge verification

```
tbf-boobytrap --smoke
# comment
tbf-boobytrap --health
```
EOF
        ;;
      merge-postdeploy-nofence)
        cat <<'EOF'

## Merge autonomy policy

The cycle may merge fixture PRs. (fixture stub policy)

### Post-merge verification

Prose only — a fenced block was never added.
EOF
        ;;
      verify-path-python)
        # No heading of its own: lands inside the base "## Verification" section above. The
        # interpreter token is built from $dir with printf, not a quoted heredoc, so it expands
        # (a quoted heredoc would emit the literal string "$dir"). The "# comment" line between
        # "pytest -q" and the path-qualified interpreter is the same fence-awareness pin as
        # merge-postdeploy's, for the verification-scope slice.
        printf '\n```\npytest -q\n# comment\n%s/.venv/bin/python -m pytest\n```\n' "$dir"
        ;;
      verify-bare-python)
        printf '\n```\npytest -q\n```\n'
        ;;
      scoped)
        cat <<'EOF'

## Autonomy reserve
```
CLAUDE.md
.claude/**
```

## Autonomy decision record
```
grant-label: scoped-autonomy
record-section: Binding decisions
element: Escalation triggers
element: Migration posture
element: Worked example
```
EOF
        ;;
      scoped-record-only)
        cat <<'EOF'

## Autonomy decision record
```
grant-label: scoped-autonomy
record-section: Binding decisions
element: Escalation triggers
element: Migration posture
element: Worked example
```
EOF
        ;;
      record-comment)
        cat <<'EOF'

## Autonomy decision record
```
grant-label: scoped-autonomy
record-section: Binding decisions
element: Escalation triggers
# the two below were added 2026-08
element: Migration posture
element: Rollback plan
```
EOF
        ;;
      autonomy)
        # (#311) mode: autonomous, no explicit kickback-budget -> the doctor's own default (2).
        cat <<'EOF'

## Autonomy mode
```
mode: autonomous
```
EOF
        ;;
      autonomy-budget)
        cat <<'EOF'

## Autonomy mode
```
mode: autonomous
kickback-budget: 3
```
EOF
        ;;
      autonomy-badbudget)
        cat <<'EOF'

## Autonomy mode
```
mode: autonomous
kickback-budget: 9
```
EOF
        ;;
      autonomy-unfenced)
        # (#311) `mode: autonomous` as a bare line OUTSIDE the fence, with the fence saying
        # `mode: manual` -> inert: only the first fenced block is read, so the mode fails closed.
        cat <<'EOF'

## Autonomy mode
mode: autonomous
```
mode: manual
```
EOF
        ;;
      autonomy-inert)
        # (#311) a section present but with no 'mode: autonomous' line -> inert, same as absent.
        cat <<'EOF'

## Autonomy mode
```
mode: manual
```
EOF
        ;;
      gov-declared)
        # (#331) a well-formed "Governance paths" section: three globs, a '#'-prefixed comment
        # line between two of them (must not be counted).
        cat <<'EOF'

## Governance paths
```
docs/policies/
# CI and bots
Jenkinsfile
.gitlab-ci.yml
```
EOF
        ;;
      gov-empty)
        # (#331) a fenced block with no globs at all (blank lines and a comment only) -> no-globs.
        cat <<'EOF'

## Governance paths
```
# nothing declared here yet

```
EOF
        ;;
      gov-unterminated)
        # (#331) an opening fence that is never closed -> unterminated-fence.
        cat <<'EOF'

## Governance paths
```
Jenkinsfile
EOF
        ;;
      gov-leading-slash)
        # (#331) a glob starting '/' -> leading-slash.
        cat <<'EOF'

## Governance paths
```
/Jenkinsfile
```
EOF
        ;;
    esac
  } > "$dir/CLAUDE.md"
  [ "$mode" = missing ] || write_settings "$dir" "$mode"
  printf '%s' "$dir"
}

# seed_commit DIR — records a local identity with gpgsign off (same idiom as
# dev/cleanup-tests.sh:66-78, so CI runners with no global git identity work), forces the branch
# name to "main" before the first commit (portable regardless of the machine's
# init.defaultBranch — a no-op on later calls, since HEAD already points there), and creates one
# empty commit. May be called more than once per fixture to build a short history. Prints the new
# HEAD SHA.
seed_commit() {
  local dir="$1"
  (
    cd "$dir" &&
    git config user.name "doctor-tests" &&
    git config user.email "doctor-tests@example.invalid" &&
    git config commit.gpgsign false &&
    git symbolic-ref HEAD refs/heads/main &&
    git commit -q --allow-empty -m "fixture commit"
  ) >/dev/null
  (cd "$dir" && git rev-parse HEAD)
}

# point_origin_ref DIR SHA — makes `git rev-parse origin/main` resolve entirely offline by
# writing the remote-tracking ref directly. No bare clone, push, or fetch is needed: mk_repo's
# origin URL (https://example.invalid/acme/demo.git) is deliberately unreachable, and this never
# touches it.
point_origin_ref() {
  local dir="$1" sha="$2"
  (cd "$dir" && git update-ref refs/remotes/origin/main "$sha")
}

# mk_gov_repo NAME (#331) — a bare fixture git repo for bin/governance-paths.sh's floor-mode
# cases, under $tmpbase/NAME: no doctor/settings/CLAUDE.md boilerplate (unlike mk_repo above) —
# each gov-* case writes its own CLAUDE.md and other fixture files directly, then commits with
# gov_commit below. Same local-identity idiom as seed_commit. Prints the fixture path.
mk_gov_repo() {
  local name="$1"
  local dir="$tmpbase/$name"
  mkdir -p "$dir"
  (
    cd "$dir" &&
    git init -q &&
    git config user.name "doctor-tests" &&
    git config user.email "doctor-tests@example.invalid" &&
    git config commit.gpgsign false &&
    git symbolic-ref HEAD refs/heads/main
  ) >/dev/null
  printf '%s' "$dir"
}

# gov_commit DIR (#331) — stages everything under DIR and commits; prints the new HEAD SHA. May be
# called more than once per fixture to build a short history (same pattern as seed_commit).
gov_commit() {
  local dir="$1"
  (cd "$dir" && git add -A && git commit -q -m "fixture commit") >/dev/null
  (cd "$dir" && git rev-parse HEAD)
}

# write_baseline DIR SHA_TEXT — writes DIR/.claude/BASELINE.md in harness-setup's documented
# shape (skills/harness-setup/SKILL.md), with the '- commit:' line carrying trailing prose after
# the SHA text (the real-world #141 report showed exactly this shape, and the doctor's `sed`
# extraction is tolerant of it), and appends .claude/BASELINE.md to DIR/.gitignore so the
# fixture also takes the gitignored-PASS branch instead of the unrelated "not gitignored" WARN.
write_baseline() {
  local dir="$1" sha_text="$2"
  cat > "$dir/.claude/BASELINE.md" <<EOF
# Verification baseline (harness-maintained)

The last known-green run of the project's verification commands on the default branch,
on THIS machine. Written by harness-setup; refreshed automatically by the
issue-implementer / issue-cycle pre-flight whenever the default branch moves past the
recorded commit. Machine-local — keep it gitignored. Do not edit by hand.

- commit: $sha_text (fixture stub)
- branch: main
- date: 2026-01-01
- results:
  - \`true\`: pass
EOF
  printf '.claude/BASELINE.md\n' >> "$dir/.gitignore"
}

# build_stub_gh DIR [BRANCH] [EXTRA_LABEL] [PROTECTION_MODE] — a deterministic, offline gh: auth
# always succeeds; repo view returns the fixture's fake nameWithOwner and BRANCH (default "main")
# as defaultBranchRef; label list returns the eleven lifecycle labels (extracted from
# bin/setup-labels.sh via the same sed idiom dev/selfcheck.sh's 4.6 uses — no second hard-coded
# copy) plus EXTRA_LABEL, if given (so a fixture repo can "have" a scoped-autonomy grant label);
# issue view returns DIR/gh-issue-body.json verbatim (a case writes that file before calling
# check-decision-record.sh against this stub); api (branch protection) serves DIR/gh-protection.json
# and exits 0, EXCEPT PROTECTION_MODE "fail", which exits 1 with no document (the pre-#234
# behaviour); anything else fails. PROTECTION_MODE (default "healthy") selects which document
# api serves — healthy (required_status_checks.strict true, one entry each in checks/contexts,
# required_pull_request_reviews present — modelled on a live `gh api
# .../branches/main/protection` response, LESSON 2026-09-01(c)), strict-false (strict false,
# checks/contexts non-empty, required_pull_request_reviews absent), zero-contexts (strict true,
# checks/contexts both empty), no-status-checks (required_status_checks key itself absent), or
# fail (see above). Making "healthy" the default means every one of the ~60 pre-#234 fixtures
# that reaches the branch-protection section now gets PASS lines there instead of the ad hoc
# empty-body WARNs an unparsed document produced before this stub understood protection
# documents at all — FAIL-free by design either way — no real network call, no gh-driven FAIL,
# ever, which is what makes the WARN-never-affects-exit pin (drift-missing-entries) meaningful.
build_stub_gh() {
  local dir="$1" branch="${2:-main}" extra_label="${3:-}" protection="${4:-healthy}"
  mkdir -p "$dir"
  sed -nE 's/^create_or_update "([^"]+)".*/\1/p' "$root/bin/setup-labels.sh" | sort -u > "$dir/gh-labels.txt"
  [ -n "$extra_label" ] && printf '%s\n' "$extra_label" >> "$dir/gh-labels.txt"
  case "$protection" in
    healthy)
      printf '%s\n' '{"url":"https://api.github.com/repos/acme/demo/branches/main/protection","required_status_checks":{"url":"https://api.github.com/repos/acme/demo/branches/main/protection/required_status_checks","strict":true,"contexts":["selfcheck","selfcheck-macos"],"contexts_url":"https://api.github.com/repos/acme/demo/branches/main/protection/required_status_checks/contexts","checks":[{"context":"selfcheck","app_id":15368},{"context":"selfcheck-macos","app_id":15368}]},"required_pull_request_reviews":{"url":"https://api.github.com/repos/acme/demo/branches/main/protection/required_pull_request_reviews","dismiss_stale_reviews":false,"require_code_owner_reviews":false,"require_last_push_approval":false,"required_approving_review_count":0},"enforce_admins":{"url":"https://api.github.com/repos/acme/demo/branches/main/protection/enforce_admins","enabled":false}}' \
        > "$dir/gh-protection.json" ;;
    strict-false)
      printf '%s\n' '{"url":"https://api.github.com/repos/acme/demo/branches/main/protection","required_status_checks":{"url":"https://api.github.com/repos/acme/demo/branches/main/protection/required_status_checks","strict":false,"contexts":["selfcheck","selfcheck-macos"],"contexts_url":"https://api.github.com/repos/acme/demo/branches/main/protection/required_status_checks/contexts","checks":[{"context":"selfcheck","app_id":15368},{"context":"selfcheck-macos","app_id":15368}]},"enforce_admins":{"url":"https://api.github.com/repos/acme/demo/branches/main/protection/enforce_admins","enabled":false}}' \
        > "$dir/gh-protection.json" ;;
    zero-contexts)
      printf '%s\n' '{"url":"https://api.github.com/repos/acme/demo/branches/main/protection","required_status_checks":{"url":"https://api.github.com/repos/acme/demo/branches/main/protection/required_status_checks","strict":true,"contexts":[],"contexts_url":"https://api.github.com/repos/acme/demo/branches/main/protection/required_status_checks/contexts","checks":[]},"required_pull_request_reviews":{"url":"https://api.github.com/repos/acme/demo/branches/main/protection/required_pull_request_reviews","dismiss_stale_reviews":false,"require_code_owner_reviews":false,"require_last_push_approval":false,"required_approving_review_count":0},"enforce_admins":{"url":"https://api.github.com/repos/acme/demo/branches/main/protection/enforce_admins","enabled":false}}' \
        > "$dir/gh-protection.json" ;;
    no-status-checks)
      printf '%s\n' '{"url":"https://api.github.com/repos/acme/demo/branches/main/protection","enforce_admins":{"url":"https://api.github.com/repos/acme/demo/branches/main/protection/enforce_admins","enabled":false}}' \
        > "$dir/gh-protection.json" ;;
    fail) : ;;
  esac
  { printf '#!%s\n' "$bash_bin"; cat <<'EOF'
case "$1" in
  auth) exit 0 ;;
EOF
  printf '  repo) case "$*" in *nameWithOwner*) echo acme/demo ;; *) echo %s ;; esac; exit 0 ;;\n' "$branch"
  printf '  label) cat "%s/gh-labels.txt"; exit 0 ;;\n' "$dir"
  printf '  issue) cat "%s/gh-issue-body.json"; exit 0 ;;\n' "$dir"
  if [ "$protection" = "fail" ]; then
    printf '  api) exit 1 ;;\n  *) exit 1 ;;\nesac\n'
  else
    printf '  api) cat "%s/gh-protection.json"; exit 0 ;;\n  *) exit 1 ;;\nesac\n' "$dir"
  fi
  } > "$dir/gh"
  chmod +x "$dir/gh"
}

# ---------------------------------------------------------------------------------------------
# Runner + assertion helpers.

# run_doctor DIR PATHVAL — runs the fixture's OWN copy of the doctor with HOME/CLAUDE_CONFIG_DIR
# pointed into the fixture and PATH set to PATHVAL, leaving $doctor_out/$doctor_rc set as
# globals. Deliberately NOT invoked via command substitution itself (same idiom as
# dev/selfcheck-tests.sh's run_gate) — call as a plain statement and read the globals after.
doctor_out=""
doctor_rc=0
run_doctor() {
  local dir="$1" pathval="$2"
  doctor_out="$(cd "$dir" && HOME="$dir/home" CLAUDE_CONFIG_DIR="$dir/claudecfg" PATH="$pathval" "$bash_bin" "$dir/bin/check-harness.sh" 2>&1)"
  doctor_rc=$?
}

# run_record_check DIR PATHVAL ISSUE — same idiom as run_doctor (a plain statement, never a
# command substitution), running the fixture's own copy of bin/check-decision-record.sh against
# ISSUE; leaves $doctor_out/$doctor_rc set, so the same expect/expect_rc/expect_absent helpers
# apply unchanged.
run_record_check() {
  local dir="$1" pathval="$2" issue="$3"
  doctor_out="$(cd "$dir" && HOME="$dir/home" CLAUDE_CONFIG_DIR="$dir/claudecfg" PATH="$pathval" "$bash_bin" "$dir/bin/check-decision-record.sh" "$issue" 2>&1)"
  doctor_rc=$?
}

# run_version_script SCRIPT (#262-2) — same never-a-command-substitution idiom as run_doctor, but
# captures stdout and stderr to SEPARATE files (.claude/LESSONS.md 2026-09-08(b): a capture that
# merges both streams cannot pin a criterion that names a stream), leaving $version_out/
# $version_err/$version_rc set as globals. Also copies a merged view into $doctor_out/$doctor_rc
# so a failing version-* case's captured output still reaches the generic runner loop's
# diagnostics dump below.
version_out=""
version_err=""
version_rc=0
run_version_script() {
  local script="$1" outfile errfile
  outfile="$(mktemp)"; errfile="$(mktemp)"
  "$bash_bin" "$script" >"$outfile" 2>"$errfile"
  version_rc=$?
  version_out="$(cat "$outfile")"
  version_err="$(cat "$errfile")"
  rm -f "$outfile" "$errfile"
  doctor_out="OUT: $version_out
ERR: $version_err"
  doctor_rc=$version_rc
}

# run_gov DIR ARGS… (#331) — same never-a-command-substitution idiom as run_doctor/
# run_version_script, running bin/governance-paths.sh FROM THIS CHECKOUT (never a fixture copy —
# these fixtures are plain git repos, not doctor fixtures, and the script never writes anywhere)
# with cwd = DIR and HOME/XDG_CONFIG_HOME pointed into DIR (so a developer's real global git
# config can never leak into a verdict) and GIT_CONFIG_NOSYSTEM=1. Captures stdout/stderr to
# SEPARATE files, same rationale as run_version_script (a capture that merges both streams cannot
# pin a criterion that names a stream), leaving $gov_out/$gov_err/$gov_rc set as globals, and
# copies a merged view into $doctor_out/$doctor_rc so a failing gov-* case's captured output still
# reaches the generic runner loop's diagnostics dump below.
gov_out=""
gov_err=""
gov_rc=0
run_gov() {
  local dir="$1" outfile errfile
  shift
  outfile="$(mktemp)"; errfile="$(mktemp)"
  (cd "$dir" && HOME="$dir/home" XDG_CONFIG_HOME="$dir/home/.config" GIT_CONFIG_NOSYSTEM=1 "$bash_bin" "$root/bin/governance-paths.sh" "$@") >"$outfile" 2>"$errfile"
  gov_rc=$?
  gov_out="$(cat "$outfile")"
  gov_err="$(cat "$errfile")"
  rm -f "$outfile" "$errfile"
  doctor_out="OUT: $gov_out
ERR: $gov_err"
  doctor_rc=$gov_rc
}

# needle_required NAME NEEDLE (#262) — guards every needle-taking helper below: an empty NEEDLE
# degenerates `grep -qF -- ""` into an unconditional match (expect "" always passes,
# expect_absent "" always fails, regardless of $doctor_out), so treat an empty needle as a harness
# bug IN THE CASE, not a fact about the script under test. Sets $__ok=0, appends
# "<NAME>: empty needle (harness bug)\n" to $__why, and returns 1; returns 0 when the needle is
# non-empty. Callers do `needle_required <own-name> "$1" || return 0` — returning 0 to the
# CALLER's caller (not 1), so a guarded helper never leaves a stray non-zero exit status behind
# for an `&&`/`||`/`if` chain built on it.
needle_required() {
  if [ -z "$2" ]; then
    __ok=0
    __why="${__why}$1: empty needle (harness bug)\n"
    return 1
  fi
  return 0
}

# expect/expect_absent/expect_rc/expect_no_file — assert against $doctor_out/$doctor_rc, setting
# $__ok=0 and appending to $__why on failure. ASCII-only short stems: stop before the doctor's
# em dashes. expect/expect_absent are guarded by needle_required (#262). Fed via a here-string
# (`<<<"$doctor_out"`, #255) rather than piping a `printf '%s\n' "$doctor_out"` writer into
# `grep`'s quiet mode: that early-exit reader exits on its first match, which can send the printf
# writer SIGPIPE and, under this file's `set -uo pipefail`, turn a genuine match into a reported
# pipeline failure — a here-string has no writer process, so no SIGPIPE is possible, and it
# appends exactly one trailing newline, the same as the piped printf did, so grep's fixed-string
# semantics are unchanged.
__ok=1
__why=""
expect() {
  needle_required expect "$1" || return 0
  grep -qF -- "$1" <<<"$doctor_out" || { __ok=0; __why="${__why}missing: $1\n"; }
}
expect_absent() {
  needle_required expect_absent "$1" || return 0
  grep -qF -- "$1" <<<"$doctor_out" && { __ok=0; __why="${__why}unexpected: $1\n"; }
}
expect_rc() {
  [ "$doctor_rc" -eq "$1" ] || { __ok=0; __why="${__why}rc: expected $1, got $doctor_rc\n"; }
}
expect_no_file() {
  [ ! -e "$1" ] || { __ok=0; __why="${__why}unexpected file present: $1\n"; }
}

# expect_gov_out/expect_gov_out_absent/expect_gov_err/expect_gov_last (#331) — same idiom as
# expect/expect_absent above, but against $gov_out/$gov_err specifically (run_gov's own captures)
# rather than the merged $doctor_out, so a floor-mode case can pin a claim about one stream without
# the other stream's content being able to satisfy it by coincidence. All four are guarded by
# needle_required (#262). expect_gov_last additionally asserts the needle is $gov_out's LAST line
# exactly — the floor mode's own contract (this file's header: "the last stdout line is always
# exactly one verdict=<token>").
expect_gov_out() {
  needle_required expect_gov_out "$1" || return 0
  grep -qF -- "$1" <<<"$gov_out" || { __ok=0; __why="${__why}missing (stdout): $1\n"; }
}
expect_gov_out_absent() {
  needle_required expect_gov_out_absent "$1" || return 0
  grep -qF -- "$1" <<<"$gov_out" && { __ok=0; __why="${__why}unexpected (stdout): $1\n"; }
}
expect_gov_err() {
  needle_required expect_gov_err "$1" || return 0
  grep -qF -- "$1" <<<"$gov_err" || { __ok=0; __why="${__why}missing (stderr): $1\n"; }
}
expect_gov_last() {
  needle_required expect_gov_last "$1" || return 0
  local last
  last="$(printf '%s\n' "$gov_out" | tail -1)"
  [ "$last" = "$1" ] || { __ok=0; __why="${__why}last stdout line: expected '$1', got '$last'\n"; }
}

# ---------------------------------------------------------------------------------------------
# The cases. Every fixture also emits the LESSONS.md auto-seed line — expected, deliberately
# unasserted below. Every fixture except the three baseline-* ones also emits a no-baseline WARN
# (also unasserted); the baseline-* fixtures write their own .claude/BASELINE.md instead, via
# seed_commit/point_origin_ref/write_baseline, so they exercise the baseline compare itself.

case_settings_missing() {
  local dir; dir="$(mk_repo settings-missing base missing)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 1
  expect "no .claude/settings.json"
  expect "merge autonomy: activation state unknown"
}

case_settings_unparseable() {
  local dir; dir="$(mk_repo settings-unparseable base unparseable)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 1
  expect "does not parse as JSON"
  expect "merge autonomy: activation state unknown"
}

case_settings_parsed() {
  local dir; dir="$(mk_repo settings-parsed base verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "permissions match the plugin's template"
  expect "merge autonomy: off"
  expect "scoped autonomy: off"
  # #150 controls: a verbatim-template fixture trips neither new WARN.
  expect_absent "disableAllHooks: true"
  expect_absent "legacy 'Bash(git -C ...)' entries"
}

# hooks-disabled (#150, #235) — disableAllHooks: true in .claude/settings.local.json (a file the
# doctor already reads for the merge-autonomy scan) silently disables the plugin's git -C guard
# hook and every other hook, including the implementer/verifier agent-boundary hook — whose
# absence is silent rather than a prompt, unlike the guard hook's; WARN, never FAIL.
case_hooks_disabled() {
  local dir; dir="$(mk_repo hooks-disabled base verbatim)"
  printf '{"disableAllHooks": true}' > "$dir/.claude/settings.local.json"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "disableAllHooks: true in .claude/settings.local.json"
}

# stale-c-allows (#150) — .claude/settings.json still carries legacy `Bash(git -C * ...)` allow
# entries the guard hook now supersedes: WARN naming them, never FAIL (the rules still work,
# they're just noisy and superseded — see the startup wildcard warning they trip).
case_stale_c_allows() {
  local dir; dir="$(mk_repo stale-c-allows base stale-c-allow)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "legacy 'Bash(git -C ...)' entries"
  expect "Bash(git -C * status *)"
  expect "Bash(git -C * push *)"
}

case_drift_missing_entries() {
  local dir; dir="$(mk_repo drift-missing-entries base drift)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "Bash(git commit:*)"
  expect "Bash(git -C * clean*)"
}

case_drift_merge_deny_lifted() {
  local dir; dir="$(mk_repo drift-merge-deny-lifted base merge-deny-lifted)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect_absent "deny-list missing"
  expect "permissions match the plugin's template"
}

case_template_missing() {
  local dir; dir="$(mk_repo template-missing base verbatim)"
  rm -f "$dir/templates/repo-settings.json"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "could not read the plugin's templates/repo-settings.json"
  expect_absent "deny-list missing"
  expect_absent "allow-list missing"
}

case_ratchet_never_executes() {
  local dir; dir="$(mk_repo ratchet-never-executes ratchet verbatim)"
  local trapdir="$dir/boobytrap-bin" sentinel="$dir/sentinel-touched"
  mkdir -p "$trapdir"
  { printf '#!%s\n' "$bash_bin"; printf 'touch %s\n' "$sentinel"; } > "$trapdir/tbf-boobytrap"
  chmod +x "$trapdir/tbf-boobytrap"
  run_doctor "$dir" "$stub_gh_dir:$trapdir:$PATH"
  expect_rc 0
  expect_no_file "$sentinel"
  expect "tbf-boobytrap"
  # This fixture's variant is "ratchet" — no "Merge autonomy policy" section at all — so the
  # post-merge-verification declaration-state line (#132/#125) must not print; it would tell a
  # merge-autonomy-off consumer to add a sub-heading under a section they don't have.
  expect_absent "post-merge verification"
}

case_merge_allow_only() {
  local dir; dir="$(mk_repo merge-allow-only merge merge-allow-only)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "merge autonomy: active"
  expect_absent "half-activated"
  expect "no checks configured"
}

# This fixture's settings mode (merge-allow-only) grants no allow entry for "tbf-boobytrap", so
# the post-merge allow-entry check (#138/#142) also fires its missing-grant WARN here — expected
# and deliberately unasserted, same idiom as write_settings's verify-path-grant mode note above.
case_merge_postdeploy() {
  local dir; dir="$(mk_repo merge-postdeploy merge-postdeploy merge-allow-only)"
  local trapdir="$dir/boobytrap-bin" sentinel="$dir/sentinel-touched"
  mkdir -p "$trapdir"
  { printf '#!%s\n' "$bash_bin"; printf 'touch %s\n' "$sentinel"; } > "$trapdir/tbf-boobytrap"
  chmod +x "$trapdir/tbf-boobytrap"
  run_doctor "$dir" "$stub_gh_dir:$trapdir:$PATH"
  expect_rc 0
  expect "merge autonomy: active"
  expect_absent "half-activated"
  expect_no_file "$sentinel"
  expect "post-merge verification: declared (3 command line(s))"
}

# postdeploy-no-fence (#132/#125) — "Post-merge verification" heading present with prose only,
# no fenced block: WARN, not a FAIL — the cycle silently skips deploy verification, which is
# exactly the failure this check exists to surface.
case_postdeploy_no_fence() {
  local dir; dir="$(mk_repo postdeploy-no-fence merge-postdeploy-nofence merge-allow-only)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "post-merge verification: heading present but no fenced commands"
}

# postdeploy-absent (#132/#125) — "Merge autonomy policy" present, no "Post-merge verification"
# sub-heading at all: informational PASS, silent-by-design (no extra step, no deploy= field).
case_postdeploy_absent() {
  local dir; dir="$(mk_repo postdeploy-absent merge merge-allow-only)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "post-merge verification: not declared"
}

case_merge_ci_present() {
  local dir; dir="$(mk_repo merge-ci-present merge merge-allow-only)"
  mkdir -p "$dir/.github/workflows"
  printf 'name: ci\non: [pull_request]\njobs: {}\n' > "$dir/.github/workflows/ci.yml"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "merge autonomy: active"
  expect_absent "no checks configured"
  # zero `uses:` lines anywhere in the scanned files (.github/workflows plus every
  # action.yml/action.yaml in the repo — this fixture has no action.yml/action.yaml anywhere at
  # all) must not produce a "CI action pinning" PASS or WARN at all (acceptance criterion 6):
  # confirmed by mutating check-harness.sh's `ci_uses_total -gt 0` guard to `-ge 0`, which turns
  # this into a false-reassurance PASS line.
  expect_absent "CI action pinning:"
}

# ci-uses-tag-pinned (#175, ex-#166) — under merge autonomy the cycle merges on "CI green", so a
# workflow `uses:` ref pinned to a mutable tag (not a full 40-hex commit SHA) gets a WARN naming
# the exact <repo-relative-path>:<ref>, never a FAIL.
case_ci_uses_tag_pinned() {
  local dir; dir="$(mk_repo ci-uses-tag-pinned merge merge-allow-only)"
  mkdir -p "$dir/.github/workflows"
  printf 'name: ci\non: [pull_request]\njobs:\n  build:\n    steps:\n      - uses: actions/checkout@v4\n' > "$dir/.github/workflows/ci.yml"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "CI action pinning:"
  expect ".github/workflows/ci.yml:actions/checkout@v4"
}

# ci-uses-sha-pinned (#175, ex-#166, control) — a full 40-hex SHA ref passes clean; a
# commented-out unpinned `uses:` line is the comment-stripping control (same idiom as
# dev/selfcheck.sh's assertion 4.24) — if the doctor read commented-out lines, this case would
# also WARN.
case_ci_uses_sha_pinned() {
  local dir; dir="$(mk_repo ci-uses-sha-pinned merge merge-allow-only)"
  mkdir -p "$dir/.github/workflows"
  {
    printf 'name: ci\non: [pull_request]\n'
    printf '# uses: actions/checkout@v4\n'
    printf 'jobs:\n  build:\n    steps:\n      - uses: actions/checkout@1de3ae0b2b1e8c1a35e6d3e6f4d3a06b6fa5db47\n'
  } > "$dir/.github/workflows/ci.yml"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "are pinned to a full commit SHA"
  expect_absent "are not pinned"
}

# ci-uses-no-merge-policy (#175, ex-#166) — a tag-pinned workflow with no "Merge autonomy policy"
# section in CLAUDE.md at all: the CI-pinning check stays completely silent, not just WARN-free —
# a repo that never activates merge autonomy shouldn't see a line about it.
case_ci_uses_no_merge_policy() {
  local dir; dir="$(mk_repo ci-uses-no-merge-policy base verbatim)"
  mkdir -p "$dir/.github/workflows"
  printf 'name: ci\non: [pull_request]\njobs:\n  build:\n    steps:\n      - uses: actions/checkout@v4\n' > "$dir/.github/workflows/ci.yml"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect_absent "CI action pinning:"
}

# ci-uses-composite-tag-pinned (#179) — the issue's exact reproduction: a workflow's only step
# calls a LOCAL composite action (`uses: ./.github/actions/local`, a `./…` ref the
# workflow-only scan skips), and the action itself contains a tag-pinned `uses:` ref.
# Non-vacuity, proof (a): against the pre-#179 doctor this fixture produces no
# "CI action pinning:" line at all — the workflow's only ref is `./…`, which the old code skips,
# leaving ci_uses_total at 0 and the `-gt 0` guard silencing both verdicts, so both expectations
# below fail against it. The "1 uses: ref(s)" count additionally pins that the in-action
# `./.github/actions/other` ref stays skipped as local — mutation proof (b): drop the
# `./*|../*|docker://*` case from the helper and the count becomes 3, not 2 (the workflow's own
# `./.github/actions/local` ref is skipped by that same arm, so removing it adds two refs, not
# one — measured: `.github/workflows/ci.yml:./.github/actions/local`,
# `.github/actions/local/action.yml:actions/checkout@v4`,
# `.github/actions/local/action.yml:./.github/actions/other`).
case_ci_uses_composite_tag_pinned() {
  local dir; dir="$(mk_repo ci-uses-composite-tag-pinned merge merge-allow-only)"
  mkdir -p "$dir/.github/workflows" "$dir/.github/actions/local"
  printf 'name: ci\non: [pull_request]\njobs:\n  build:\n    steps:\n      - uses: ./.github/actions/local\n' > "$dir/.github/workflows/ci.yml"
  cat > "$dir/.github/actions/local/action.yml" <<'EOF'
name: local
runs:
  using: composite
  steps:
    - uses: actions/checkout@v4
    - uses: ./.github/actions/other
EOF
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "CI action pinning: 1 uses: ref(s)"
  expect ".github/actions/local/action.yml:actions/checkout@v4"
}

# ci-uses-composite-sha-pinned (#179) — union counter across BOTH file classes. Non-vacuity,
# proof (a): the pre-#179 doctor prints "all 1 uses: ref(s) …" (it never reads .github/actions/
# at all), so `expect "all 2 uses: ref(s)"` fails against it. Mutation proof (b), measured:
# neutering the repo-wide `action.yml`/`action.yaml` `find` — deleting the `while … <<EOF
# $action_files` loop that walks it (bin/check-harness.sh, right after the `find` assignment) —
# makes all three #179 composite cases fail, this one included: measured output drops from "all 2
# uses: ref(s) …" to "CI action pinning: all 1 uses: ref(s) …" (the workflow's own ref only) — the
# action file's ref is never read, so `ci_uses_total` stays 1. The commented-out
# `# uses: actions/cache@v3` line inside the action file is NOT a comment-stripping control: the
# anchored extraction grep (`^[[:space:]]*-?[[:space:]]*uses:`) can never match a line whose first
# non-blank character is `#`, so the earlier `grep -vE '^[[:space:]]*#'` pre-filter is redundant,
# and this case does not exercise it.
case_ci_uses_composite_sha_pinned() {
  local dir; dir="$(mk_repo ci-uses-composite-sha-pinned merge merge-allow-only)"
  mkdir -p "$dir/.github/workflows" "$dir/.github/actions/setup"
  printf 'name: ci\non: [pull_request]\njobs:\n  build:\n    steps:\n      - uses: actions/checkout@1de3ae0b2b1e8c1a35e6d3e6f4d3a06b6fa5db47\n' > "$dir/.github/workflows/ci.yml"
  cat > "$dir/.github/actions/setup/action.yml" <<'EOF'
name: setup
runs:
  using: composite
  steps:
    # uses: actions/cache@v3
    - uses: actions/checkout@1de3ae0b2b1e8c1a35e6d3e6f4d3a06b6fa5db47
EOF
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "all 2 uses: ref(s)"
  expect_absent "are not pinned"
}

# ci-uses-composite-nested (#179) — depth independence: the action file sits TWO levels below
# .github/actions/ (group/inner/action.yml), and there is no workflow `uses:` ref at all.
# Non-vacuity, proof (a): the pre-#179 doctor prints nothing (it never reads .github/actions/).
# Mutation proof (b): replace the `find` enumeration with a one-level
# `for … in "$root"/.github/actions/*/action.yml` glob and this case fails while
# ci-uses-composite-tag-pinned (one level deep) still passes — this is the case that catches a
# depth-limited implementation.
case_ci_uses_composite_nested() {
  local dir; dir="$(mk_repo ci-uses-composite-nested merge merge-allow-only)"
  mkdir -p "$dir/.github/actions/group/inner"
  cat > "$dir/.github/actions/group/inner/action.yml" <<'EOF'
name: inner
runs:
  using: composite
  steps:
    - uses: actions/setup-node@v4
EOF
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "CI action pinning:"
  expect ".github/actions/group/inner/action.yml:actions/setup-node@v4"
}

# ci-uses-outside-actions-dir (#186) — the issue's exact repro: a local composite action lives
# OUTSIDE .github/actions/ entirely (tools/ci-setup/, referenced only as `uses: ./tools/ci-setup`,
# a ref the workflow-only scan skips as local). Non-vacuity, MEASURED proof (a): a scratch copy of
# this repo with bin/check-harness.sh restored to its pre-#186 content (main@e9bfd91) run against
# this exact fixture prints no "CI action pinning:" line at all (ci_uses_total stays 0 — the
# workflow's only ref is `./…`, skipped, and the action file sits outside the old
# `.github/actions`-gated find, so it is never read) — both expectations below fail against it.
# Mutation proof (b), MEASURED: re-scoping the new `find` back to "$root/.github/actions" (i.e.
# restoring the `[ -d "$root/.github/actions" ]`-gated old find) makes this case fail identically
# to proof (a) — the file is once again unreached.
case_ci_uses_outside_actions_dir() {
  local dir; dir="$(mk_repo ci-uses-outside-actions-dir merge merge-allow-only)"
  mkdir -p "$dir/.github/workflows" "$dir/tools/ci-setup"
  printf 'name: ci\non: [pull_request]\njobs:\n  build:\n    steps:\n      - uses: ./tools/ci-setup\n' > "$dir/.github/workflows/ci.yml"
  cat > "$dir/tools/ci-setup/action.yml" <<'EOF'
name: ci-setup
runs:
  using: composite
  steps:
    - uses: actions/checkout@v4
EOF
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "CI action pinning: 1 uses: ref(s)"
  expect "tools/ci-setup/action.yml:actions/checkout@v4"
}

# ci-uses-unreferenced-action-yaml (#186) — pins that the enumeration is repo-wide and extension-
# agnostic, independent of any workflow reference: packages/build/action.yaml (the .yaml
# extension, no .github/ directory anywhere in the fixture, no workflow ever mentions it) is still
# scanned. Non-vacuity, MEASURED proof (a): against the pre-#186 doctor (main@e9bfd91) this
# fixture prints no "CI action pinning:" line at all (there is no .github/workflows and no
# .github/actions, so both the workflow loop and the old `[ -d "$root/.github/actions" ]` guard
# are inert) — both expectations below fail against it. Mutation proof (b), MEASURED: re-scoping
# the new `find` back to "$root/.github/actions" makes this case fail identically — the file lives
# nowhere near that directory.
case_ci_uses_unreferenced_action_yaml() {
  local dir; dir="$(mk_repo ci-uses-unreferenced-action-yaml merge merge-allow-only)"
  mkdir -p "$dir/packages/build"
  cat > "$dir/packages/build/action.yaml" <<'EOF'
name: build
runs:
  using: composite
  steps:
    - uses: actions/setup-node@v4
EOF
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "CI action pinning:"
  expect "packages/build/action.yaml:actions/setup-node@v4"
}

# ci-uses-pruned-paths (#186) — pins the two non-.github/workflows prunes by BOTH count and
# expect_absent: tools/setup/action.yml (the file that should be scanned) sits alongside
# node_modules/pkg/action.yml and .git/vendored/action.yml, each carrying a different unpinned
# ref. Writing under the fixture's real .git/ (mk_repo runs `git init` there) did not interfere
# with git usage in this case — no git command in mk_repo/run_doctor reads that subtree — so both
# prunes are pinned in one case per the plan's fallback clause. Non-vacuity, MEASURED proof (a):
# against the pre-#186 doctor (main@e9bfd91, no .github/actions/ directory at all) this fixture
# prints no "CI action pinning:" line — the expected total-1 assertion fails (got no line, not
# "1"). Mutation proof (b), MEASURED: deleting the `.git`/`node_modules` prune terms from the new
# `find` (`-name .git -o -name node_modules -o -path …` → just `-path "$root/.github/workflows"`)
# makes ci_uses_total become 3, not 1, and both expect_absent lines fail — the pruned refs'
# file:ref strings appear in the WARN.
case_ci_uses_pruned_paths() {
  local dir; dir="$(mk_repo ci-uses-pruned-paths merge merge-allow-only)"
  mkdir -p "$dir/tools/setup" "$dir/node_modules/pkg" "$dir/.git/vendored"
  cat > "$dir/tools/setup/action.yml" <<'EOF'
name: setup
runs:
  using: composite
  steps:
    - uses: actions/checkout@v4
EOF
  cat > "$dir/node_modules/pkg/action.yml" <<'EOF'
name: vendored-pkg
runs:
  using: composite
  steps:
    - uses: actions/cache@v3
EOF
  cat > "$dir/.git/vendored/action.yml" <<'EOF'
name: vendored-git
runs:
  using: composite
  steps:
    - uses: actions/setup-node@v4
EOF
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "CI action pinning: 1 uses: ref(s)"
  expect "tools/setup/action.yml:actions/checkout@v4"
  expect_absent "node_modules/pkg/action.yml:actions/cache@v3"
  expect_absent ".git/vendored/action.yml:actions/setup-node@v4"
}

# ci-uses-workflow-named-action-yml (#186) — no-double-count control: a workflow file literally
# named action.yml sits in .github/workflows/ (a valid, if unusual, workflow filename), with one
# unpinned `uses:` ref. Without the .github/workflows prune, the same file would be picked up
# twice — once by the workflow-glob loop, once by the repo-wide action.yml/action.yaml find — and
# double-counted. Non-vacuity, MEASURED proof (a): against the pre-#186 doctor (main@e9bfd91,
# scoped to .github/actions/) this fixture already prints "CI action pinning: 1 uses: ref(s)" (no
# .github/actions/ directory exists, so the old code never double-scanned it either) — this proof
# shows proof (a) does NOT distinguish this case, so it is the mutation proof (b) that carries the
# pin. Mutation proof (b), MEASURED: deleting the `-path "$root/.github/workflows"` prune term
# from the new `find` makes the count become 2, not 1 — the workflow-glob loop and the repo-wide
# find both read .github/workflows/action.yml.
case_ci_uses_workflow_named_action_yml() {
  local dir; dir="$(mk_repo ci-uses-workflow-named-action-yml merge merge-allow-only)"
  mkdir -p "$dir/.github/workflows"
  printf 'name: ci\non: [pull_request]\njobs:\n  build:\n    steps:\n      - uses: actions/checkout@v4\n' > "$dir/.github/workflows/action.yml"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "CI action pinning: 1 uses: ref(s)"
}

case_merge_deny_only() {
  local dir; dir="$(mk_repo merge-deny-only merge verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "half-activated"
  expect_absent "merge autonomy: active"
}

case_merge_deny_local_only() {
  local dir; dir="$(mk_repo merge-deny-local-only merge merge-deny-lifted)"
  local label=".claude/settings.local.json"
  jq '{permissions: {deny: [.permissions.deny[] | select(. == "Bash(gh pr merge:*)")]}}' \
    "$dir/templates/repo-settings.json" > "$dir/$label"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "half-activated"
  expect "permissions.deny in $label"
}

case_merge_mention_only() {
  local dir; dir="$(mk_repo merge-mention-only merge merge-mention-only)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "no matching allow entry"
  expect_absent "merge autonomy: active"
}

case_guard_coverage_offbranch() {
  local dir; dir="$(mk_repo guard-coverage-offbranch base verbatim)"
  run_doctor "$dir" "$stub_gh_alt_dir:$PATH"
  expect_rc 0
  expect "default-branch guard coverage: '$alt_branch' is missing deny entries:"
  while IFS= read -r op; do
    [ -n "$op" ] || continue
    expect "Bash(git $op $alt_branch:*)"
    expect "Bash(git -C * $op $alt_branch*)"
  done <<EOF
$tmpl_branch_ops
EOF
}

# verify-path-grant-missing (#132/#128) — the verification section names a path-qualified
# interpreter (<dir>/.venv/bin/python) and settings.json carries the template's bare
# "Bash(pytest:*)" only: WARN naming the exact literal-path entry to add, and the reassuring
# "covers the detected toolchain(s)" PASS is suppressed even though the marker-based Python
# check (pyproject.toml present, bare pytest entry present) would otherwise pass on its own.
case_verify_path_grant_missing() {
  local dir; dir="$(mk_repo verify-path-grant-missing verify-path-python verbatim)"
  : > "$dir/pyproject.toml"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "path-qualified verification interpreter '$dir/.venv/bin/python' has no matching allow entry"
  expect "Bash($dir/.venv/bin/python:*)"
  expect_absent "covers the detected toolchain(s)"
}

# verify-path-grant-present (#132/#128) — same CLAUDE.md, but settings.json carries a
# literal-path grant for that exact interpreter and NO bare-name entry (write_settings's
# verify-path-grant mode drops "Bash(pytest:*)" deliberately): PASS, and the pre-existing Python
# toolchain WARN (pyproject.toml present, no bare pytest/python/uv/poetry entry) does not fire
# even though there is no bare-name entry to satisfy it on its own.
case_verify_path_grant_present() {
  local dir; dir="$(mk_repo verify-path-grant-present verify-path-python verify-path-grant)"
  : > "$dir/pyproject.toml"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "path-qualified verification interpreter '$dir/.venv/bin/python' is covered by a literal-path allow entry"
  expect "covers the detected toolchain(s)"
  expect_absent "Python project files found but no pytest/python/uv/poetry"
}

# verify-path-grant-local-only (#147) — the literal-path grant for the interpreter lives ONLY in
# .claude/settings.local.json, not in the checked-in .claude/settings.json (write_settings's
# verbatim mode leaves only the template's bare "Bash(pytest:*)" entry there): PASS, covered by
# the literal-path allow entry. Pins the three-file union the interpreter probe now reads instead
# of .claude/settings.json alone.
case_verify_path_grant_local_only() {
  local dir; dir="$(mk_repo verify-path-grant-local-only verify-path-python verbatim)"
  jq -n --arg e "Bash($dir/.venv/bin/python:*)" '{permissions:{allow:[$e]}}' > "$dir/.claude/settings.local.json"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "path-qualified verification interpreter '$dir/.venv/bin/python' is covered by a literal-path allow entry"
  expect_absent "has no matching allow entry"
}

# verify-bare-command (#132/#128, control) — the verification section names only a bare
# "pytest -q" (no path-qualified token anywhere), verbatim template settings: unchanged
# behaviour — neither new stem prints, and the pre-existing bare-name PASS still does.
case_verify_bare_command() {
  local dir; dir="$(mk_repo verify-bare-command verify-bare-python verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "covers the detected toolchain(s)"
  expect_absent "path-qualified verification interpreter"
}

# toolchain-grant-local-only (#175, ex-#158) — the bare-name toolchain allow-list check now reads
# the three-file settings union: a "Bash(pytest:*)" grant living ONLY in
# .claude/settings.local.json (write_settings's no-python-tool mode drops it from the checked-in
# .claude/settings.json) still satisfies the Python toolchain check — the exact scenario in the
# issue's user-visible failure (a consumer whose test runner is granted only in
# settings.local.json no longer gets a permanent spurious WARN).
case_toolchain_grant_local_only() {
  local dir; dir="$(mk_repo toolchain-grant-local-only base no-python-tool)"
  : > "$dir/pyproject.toml"
  printf '{"permissions":{"allow":["Bash(pytest:*)"]}}' > "$dir/.claude/settings.local.json"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "covers the detected toolchain(s)"
  expect_absent "Python project files found but no pytest/python/uv/poetry"
}

# toolchain-grant-absent (#175, non-vacuity control) — identical fixture minus the
# .claude/settings.local.json write: the Python toolchain WARN fires and the reassuring PASS is
# absent, proving toolchain-grant-local-only isn't passing regardless of the grant. Hand-verified:
# deleting the settings.local.json write from that case reproduces this case's expectations.
case_toolchain_grant_absent() {
  local dir; dir="$(mk_repo toolchain-grant-absent base no-python-tool)"
  : > "$dir/pyproject.toml"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "Python project files found but no pytest/python/uv/poetry"
  expect_absent "covers the detected toolchain(s)"
}

# record_body TEXT_LINES — writes a synthetic issue body to $tmpbase/<caller-provided path> via
# jq -Rs '{body: .}', never a hand-escaped JSON literal (see the header's fixture contract note).
# Callers pass the destination gh-stub directory; this writes DIR/gh-issue-body.json.
write_record_body() {
  local ghdir="$1" text="$2"
  printf '%s\n' "$text" > "$tmpbase/record-body-src.txt"
  jq -Rs '{body: .}' "$tmpbase/record-body-src.txt" > "$ghdir/gh-issue-body.json"
}

case_record_complete() {
  local dir; dir="$(mk_repo record-complete scoped verbatim)"
  local ghdir="$tmpbase/record-complete-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Migration posture
text

### Worked example
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 0
  expect "PASS  section: Binding decisions"
  expect "PASS  element: Escalation triggers"
  expect "PASS  element: Migration posture"
  expect "PASS  element: Worked example"
  expect_absent "FAIL"
}

case_record_missing_element() {
  local dir; dir="$(mk_repo record-missing-element scoped verbatim)"
  local ghdir="$tmpbase/record-missing-element-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Worked example
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "PASS  element: Escalation triggers"
  expect "FAIL  element: Migration posture"
  expect "PASS  element: Worked example"
}

case_record_no_declaration() {
  local dir; dir="$(mk_repo record-no-declaration base verbatim)"
  local ghdir="$tmpbase/record-no-declaration-gh"
  build_stub_gh "$ghdir"
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 2
  expect_absent "PASS  element:"
  expect_absent "FAIL  element:"
}

case_record_comment_preserved() {
  local dir; dir="$(mk_repo record-comment-preserved record-comment verbatim)"
  local ghdir="$tmpbase/record-comment-preserved-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Migration posture
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "PASS  element: Escalation triggers"
  expect "PASS  element: Migration posture"
  expect "FAIL  element: Rollback plan"
}

# record-fenced-body (#162) — the whole record (section + all three elements) lives only inside
# one fenced code block; the unrelated "## Overview" heading sits outside it. A fence-blind scan
# would find every heading anyway; the fence-aware scan must find none of them.
case_record_fenced_body() {
  local dir; dir="$(mk_repo record-fenced-body scoped verbatim)"
  local ghdir="$tmpbase/record-fenced-body-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Overview

Overview text, outside the fence.

```
## Binding decisions

### Escalation triggers
text

### Migration posture
text

### Worked example
text
```'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "FAIL  section: Binding decisions (no heading found)"
  expect "FAIL  element: Escalation triggers (no heading found)"
  expect "FAIL  element: Migration posture (no heading found)"
  expect "FAIL  element: Worked example (no heading found)"
  expect_absent "PASS  element:"
}

# record-empty-element (#162) — happy body except "### Migration posture" has nothing before the
# next heading: heading found, but no content, must FAIL distinguishably from "heading absent".
case_record_empty_element() {
  local dir; dir="$(mk_repo record-empty-element scoped verbatim)"
  local ghdir="$tmpbase/record-empty-element-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Migration posture

### Worked example
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "PASS  element: Escalation triggers"
  expect "FAIL  element: Migration posture (heading found, no content under it)"
  expect "PASS  element: Worked example"
}

# record-nested-content (#162) — "### Migration posture" is immediately followed by a deeper
# "#### Details" sub-heading, then prose: the prose counts toward the parent element's span.
case_record_nested_content() {
  local dir; dir="$(mk_repo record-nested-content scoped verbatim)"
  local ghdir="$tmpbase/record-nested-content-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Migration posture
#### Details
prose under the sub-heading

### Worked example
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 0
  expect "PASS  element: Migration posture"
  expect_absent "no content under it"
}

# record-fenced-content (#162) — "### Worked example"'s only content is a fenced block whose
# first line looks like a heading ("# not a heading"): the fenced block's inner line counts as
# content (the delimiter lines do not), and the in-fence "#" line must not be read as a heading
# (it stays invisible to the heading scan).
case_record_fenced_content() {
  local dir; dir="$(mk_repo record-fenced-content scoped verbatim)"
  local ghdir="$tmpbase/record-fenced-content-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Migration posture
text

### Worked example
```
# not a heading
fenced content line
```'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 0
  expect "PASS  element: Worked example"
  expect_absent "no content under it"
}

# record-no-space-heading (#162) — the complete record written with no whitespace after the '#'
# run ("#Binding decisions", "###Escalation triggers", ...): none of it counts as a heading,
# matching claude_md_block/claude_md_section's own whitespace-required rule.
case_record_no_space_heading() {
  local dir; dir="$(mk_repo record-no-space-heading scoped verbatim)"
  local ghdir="$tmpbase/record-no-space-heading-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '#Binding decisions

###Escalation triggers
text

###Migration posture
text

###Worked example
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "FAIL  section: Binding decisions (no heading found)"
  expect_absent "PASS  element:"
}

# record-element-outside-section (#177) — "### Worked example" is a real, filled heading, but it
# sits under an unrelated later "## Appendix" section instead of nested under "## Binding
# decisions": it must FAIL distinguishably from both "no heading found" and "no content under
# it". Non-vacuity: method (a) — under the pre-#177 script (no nesting requirement), "Worked
# example" is found anywhere in the body and has content, so it PASSes and the whole check exits
# 0; observed pre-change verdict: rc 0, "PASS  element: Worked example", no FAIL lines at all.
case_record_element_outside_section() {
  local dir; dir="$(mk_repo record-element-outside-section scoped verbatim)"
  local ghdir="$tmpbase/record-element-outside-section-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Migration posture
text

## Appendix

### Worked example
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "PASS  element: Escalation triggers"
  expect "PASS  element: Migration posture"
  expect "FAIL  element: Worked example (heading found outside the record section)"
}

# record-element-sibling-depth (#177) — "## Worked example" is a direct same-depth sibling of
# "## Binding decisions" (no intervening section), pinning the documented "same depth is not
# nested" consequence: the record-section span closes as soon as a same-or-shallower heading is
# seen outside a fence, so a same-depth heading never counts as inside it. Non-vacuity: method
# (a) — the pre-#177 script has no nesting requirement at all, so "Worked example" PASSes;
# observed pre-change verdict: rc 0, "PASS  element: Worked example", no FAIL lines at all.
case_record_element_sibling_depth() {
  local dir; dir="$(mk_repo record-element-sibling-depth scoped verbatim)"
  local ghdir="$tmpbase/record-element-sibling-depth-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
text

### Migration posture
text

## Worked example
text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "PASS  element: Escalation triggers"
  expect "PASS  element: Migration posture"
  expect "FAIL  element: Worked example (heading found outside the record section)"
}

# record-tilde-fence (#177) — the whole record (section + all three filled elements) lives only
# inside a '~~~' block; the unrelated "## Overview" heading sits outside it. The pre-#177 fence
# tracker only recognises backtick runs, so a '~~~' fence is invisible to it and every heading
# inside leaks through as if it were outside any fence. Non-vacuity: method (a) — observed
# pre-change verdict: rc 0, every heading (section + all three elements) PASSes, no FAIL lines.
case_record_tilde_fence() {
  local dir; dir="$(mk_repo record-tilde-fence scoped verbatim)"
  local ghdir="$tmpbase/record-tilde-fence-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Overview

Overview text, outside the fence.

~~~
## Binding decisions

### Escalation triggers
text

### Migration posture
text

### Worked example
text
~~~'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "FAIL  section: Binding decisions (no heading found)"
  expect "FAIL  element: Escalation triggers (no heading found)"
  expect "FAIL  element: Migration posture (no heading found)"
  expect "FAIL  element: Worked example (no heading found)"
  expect_absent "PASS  element:"
}

# record-nested-fence (#177) — a four-backtick-opened block (info string "markdown") whose
# content includes an inner, unmatched three-backtick line before the record and another right
# after it, before the real four-backtick closer; the record itself lives between them. The
# pre-#177 tracker toggles on ANY run of 3+ backticks regardless of length, so the inner
# three-backtick line right after the opener flips it back to "outside a fence" — leaking the
# whole record's headings through — and the second inner three-backtick line flips it "inside"
# again just before the real closer. The new fence-length-aware tracker requires a closer at
# least as long as the four-backtick opener, so neither inner three-backtick line closes it and
# the record stays hidden throughout. Non-vacuity: method (a) — observed pre-change verdict: rc
# 0, every heading (section + all three elements) PASSes, no FAIL lines.
case_record_nested_fence() {
  local dir; dir="$(mk_repo record-nested-fence scoped verbatim)"
  local ghdir="$tmpbase/record-nested-fence-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Overview

Overview text, outside the fence.

````markdown
```
## Binding decisions

### Escalation triggers
text

### Migration posture
text

### Worked example
text
```
````'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "FAIL  section: Binding decisions (no heading found)"
  expect "FAIL  element: Escalation triggers (no heading found)"
  expect "FAIL  element: Migration posture (no heading found)"
  expect "FAIL  element: Worked example (no heading found)"
  expect_absent "PASS  element:"
}

# record-indented-fence (#177) — the whole record lives inside a 2-space-indented '```' fence
# (opener and closer both indented; the record's own headings sit at column 0 inside it). The
# leading spaces on the fence lines are load-bearing source text, not formatting — do not
# reindent this heredoc. The pre-#177 tracker requires the fence delimiter at column 0
# (`/^```/`), so an indented delimiter is never recognised as a fence at all, and the scan runs
# the whole body as if it were never fenced — every heading (inside the "fence" and out) is found
# and, since it has following text or a nested heading, filled. Non-vacuity: method (a) —
# observed pre-change verdict: rc 0, every heading PASSes, no FAIL lines.
case_record_indented_fence() {
  local dir; dir="$(mk_repo record-indented-fence scoped verbatim)"
  local ghdir="$tmpbase/record-indented-fence-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Overview

- a list item

  ```
## Binding decisions

### Escalation triggers
text

### Migration posture
text

### Worked example
text
  ```'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 1
  expect "FAIL  section: Binding decisions (no heading found)"
  expect "FAIL  element: Escalation triggers (no heading found)"
  expect "FAIL  element: Migration posture (no heading found)"
  expect "FAIL  element: Worked example (no heading found)"
  expect_absent "PASS  element:"
}

# record-fence-close-rules (#177) — control case, all PASS: pins that the stricter closing rule
# genuinely closes (a broken closer would swallow every later element as "no heading found") and
# that a wrong-character run and an info-string run never close a fence early. "Escalation
# triggers"'s content is a '```' block containing a same-char, same-length run followed by an
# info string ("```js", must not close) and a wrong-character run ("~~~ still inside", must not
# close), then a real closer. "Migration posture"'s content is a '~~~' block containing a
# wrong-character run ("``` still inside", must not close), then a real closer. "Worked example"
# has plain text, no fence at all. Non-vacuity: method (a) — the pre-#177 tracker toggles on
# every 3+-backtick run regardless of character or trailing text ('~~~' runs never toggle it,
# only tilde-prefixed lines were ever invisible to it in other fixtures above), so "```js" inside
# "Escalation triggers"'s block toggles it back "outside" mid-block, the block's own closing
# "```" toggles it "inside" again, and "### Migration posture" is then read while "inside" — its
# heading pattern is gated on being outside a fence, so the line is swallowed as ordinary content
# instead of recorded as a heading at all, and the heading text "Migration posture" never enters
# the pre-#177 script's heading list. "Migration posture"'s own '~~~'-delimited block never
# toggles the backtick-only tracker, so its inner "``` still inside" line toggles it "outside"
# again in time for "### Worked example" to be read correctly. Observed pre-change verdict: rc 1,
# "PASS  element: Escalation triggers", "FAIL  element: Migration posture (no heading found)",
# "PASS  element: Worked example" — the new script's PASS for Migration posture is exactly what
# the old script's toggle-count coincidence gets wrong.
case_record_fence_close_rules() {
  local dir; dir="$(mk_repo record-fence-close-rules scoped verbatim)"
  local ghdir="$tmpbase/record-fence-close-rules-gh"
  build_stub_gh "$ghdir"
  write_record_body "$ghdir" '## Binding decisions

### Escalation triggers
```
```js
still inside
~~~ still inside
```

### Migration posture
~~~
``` still inside
~~~

### Worked example
plain text'
  run_record_check "$dir" "$ghdir:$PATH" 42
  expect_rc 0
  expect "PASS  element: Escalation triggers"
  expect "PASS  element: Migration posture"
  expect "PASS  element: Worked example"
  expect_absent "FAIL"
}

case_scoped_declared() {
  local dir; dir="$(mk_repo scoped-declared scoped verbatim)"
  run_doctor "$dir" "$stub_gh_scoped_dir:$PATH"
  expect_rc 0
  expect "scoped autonomy: declared"
  expect_absent "scoped autonomy: off"
  expect_absent "no 'Autonomy reserve' section"
  expect_absent "no 'Autonomy decision record' section"
}

case_scoped_reserve_missing() {
  local dir; dir="$(mk_repo scoped-reserve-missing scoped-record-only verbatim)"
  run_doctor "$dir" "$stub_gh_scoped_dir:$PATH"
  expect_rc 0
  expect "no 'Autonomy reserve' section"
  expect_absent "scoped autonomy: off"
}

# ratchet-fence-comment (#137/#142) — a '#' comment BETWEEN two data lines inside the ratchet
# section's fenced block must not truncate the section slice, and a bare ``` fence-delimiter
# line must not itself be mistaken for the backtick-quoted measurement command: the real command
# (after the fence) is still found, never executed (sentinel absent).
case_ratchet_fence_comment() {
  local dir; dir="$(mk_repo ratchet-fence-comment ratchet-fenced verbatim)"
  local trapdir="$dir/boobytrap-bin" sentinel="$dir/sentinel-touched"
  mkdir -p "$trapdir"
  { printf '#!%s\n' "$bash_bin"; printf 'touch %s\n' "$sentinel"; } > "$trapdir/tbf-boobytrap"
  chmod +x "$trapdir/tbf-boobytrap"
  run_doctor "$dir" "$stub_gh_dir:$trapdir:$PATH"
  expect_rc 0
  expect "tbf-boobytrap --cov"
  expect_absent "names no backtick-quoted measurement command"
  expect_no_file "$sentinel"
}

# postdeploy-grant-missing (#138/#142) — a declared post-merge command with no matching allow
# entry in .claude/settings.json: WARN naming the exact token and the literal
# "Bash(<token>:*)" entry to add, never a FAIL.
case_postdeploy_grant_missing() {
  local dir; dir="$(mk_repo postdeploy-grant-missing merge-postdeploy merge-allow-only)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "post-merge verification: declared command(s) with no matching allow entry: tbf-boobytrap"
  expect "Bash(tbf-boobytrap:*)"
  expect_absent "post-merge verification: every declared command has a matching allow entry"
}

# postdeploy-grant-present (#138/#142) — every declared command's first token has a matching
# allow entry: PASS, no missing-grant WARN, and the check never executes the command it found a
# grant for (sentinel absent) — the never-execute guarantee applies to the present-grant branch
# too, not just the missing-grant one. The pre-existing declared-count line is unchanged (the
# '#' comment line is still counted there, while being skipped by the grant check itself).
case_postdeploy_grant_present() {
  local dir; dir="$(mk_repo postdeploy-grant-present merge-postdeploy postdeploy-grant)"
  local trapdir="$dir/boobytrap-bin" sentinel="$dir/sentinel-touched"
  mkdir -p "$trapdir"
  { printf '#!%s\n' "$bash_bin"; printf 'touch %s\n' "$sentinel"; } > "$trapdir/tbf-boobytrap"
  chmod +x "$trapdir/tbf-boobytrap"
  run_doctor "$dir" "$stub_gh_dir:$trapdir:$PATH"
  expect_rc 0
  expect "post-merge verification: every declared command has a matching allow entry"
  expect_absent "no matching allow entry"
  expect_no_file "$sentinel"
  expect "post-merge verification: declared (3 command line(s))"
}

# postdeploy-grant-local-only (#147) — the grant for the declared post-merge command lives ONLY
# in .claude/settings.local.json (the documented, machine-specific place for it), not in the
# checked-in .claude/settings.json: PASS, every declared command covered, no missing-grant WARN.
# Pins the three-file union the post-merge allow-entry check now reads instead of
# .claude/settings.json alone.
case_postdeploy_grant_local_only() {
  local dir; dir="$(mk_repo postdeploy-grant-local-only merge-postdeploy merge-allow-only)"
  printf '{"permissions":{"allow":["Bash(tbf-boobytrap:*)"]}}' > "$dir/.claude/settings.local.json"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "post-merge verification: every declared command has a matching allow entry"
  expect_absent "no matching allow entry"
}

# postdeploy-grant-user-only (#147) — same as postdeploy-grant-local-only, but the grant lives
# only in the user-level settings file. run_doctor already points CLAUDE_CONFIG_DIR at
# $dir/claudecfg, so this resolves to $dir/claudecfg/settings.json — hermetic, never the
# developer's real ~/.claude/settings.json.
case_postdeploy_grant_user_only() {
  local dir; dir="$(mk_repo postdeploy-grant-user-only merge-postdeploy merge-allow-only)"
  printf '{"permissions":{"allow":["Bash(tbf-boobytrap:*)"]}}' > "$dir/claudecfg/settings.json"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "post-merge verification: every declared command has a matching allow entry"
  expect_absent "no matching allow entry"
}

# baseline-short-sha (#141/#142) — a recorded '- commit:' value of exactly 7 hex characters that
# is a genuine prefix of origin/main's tip: treated as identifying that commit, not "behind".
case_baseline_short_sha() {
  local dir; dir="$(mk_repo baseline-short-sha base verbatim)"
  local sha; sha="$(seed_commit "$dir")"
  point_origin_ref "$dir" "$sha"
  write_baseline "$dir" "${sha:0:7}"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "verification baseline recorded (BASELINE.md at"
  expect_absent "verification baseline is behind"
}

# baseline-behind (#141/#142) — a 7-hex-char recorded value that is NOT a prefix of origin/main's
# current tip (the branch moved on): the prefix compare must still catch a genuinely stale
# baseline, not over-permissively pass every short value.
case_baseline_behind() {
  local dir; dir="$(mk_repo baseline-behind base verbatim)"
  local c1 c2
  c1="$(seed_commit "$dir")"
  c2="$(seed_commit "$dir")"
  point_origin_ref "$dir" "$c2"
  write_baseline "$dir" "${c1:0:7}"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "verification baseline is behind origin/main"
  expect_absent "verification baseline recorded (BASELINE.md at"
}

# baseline-too-short (#141/#142) — a recorded value under 7 hex characters cannot reliably
# identify a commit: WARN as malformed, not a silent PASS and not the "behind" wording (a 3-char
# value would otherwise glob-prefix-match almost anything).
case_baseline_too_short() {
  local dir; dir="$(mk_repo baseline-too-short base verbatim)"
  local sha; sha="$(seed_commit "$dir")"
  point_origin_ref "$dir" "$sha"
  write_baseline "$dir" "${sha:0:3}"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "BASELINE.md's '- commit:' value"
  expect_absent "verification baseline is behind"
  expect_absent "verification baseline recorded (BASELINE.md at"
}

# version-report / version-unresolvable (#233) — bin/check-harness.sh's "harness version" section
# runs bin/harness-version.sh (mk_repo now copies it, plus a real .claude-plugin/plugin.json,
# into every fixture) by a fixed path and reports its printed "<version> <sha>" line verbatim as
# one PASS; missing/unresolvable is a WARN, never a FAIL. The expected version is measured at
# TEST time from THIS checkout's real .claude-plugin/plugin.json (jq -r .version), never
# hand-typed, so a release version bump can't break this case; the trailing space after the
# version in the `expect` needle is deliberate — it matches regardless of whether the fixture's
# fresh, commit-less git-init resolves a short SHA or "-".
case_version_report() {
  local dir want
  dir="$(mk_repo version-report base verbatim)"
  want="$(jq -r '.version' "$root/.claude-plugin/plugin.json")"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "harness version: $want "
}

case_version_unresolvable() {
  local dir
  dir="$(mk_repo version-unresolvable base verbatim)"
  rm -f "$dir/.claude-plugin/plugin.json"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "could not determine the installed harness version"
}

# version-cache-under-repo / version-plugin-root-checkout (#262-2) — pins bin/harness-version.sh's
# `.git`-presence guard (script line ~101: `[ -e "$plugin_root/.git" ]`) directly, rather than
# through the doctor: a fixture-version copy of the script (never the real jq -r .version, since
# .claude-plugin/plugin.json here is a throwaway fixture file, not this checkout's own) is placed
# two directories deep (cache/tbf/bin/) inside an ENCLOSING repo with a resolvable HEAD — the
# exact "a repo that copies the harness's bin/ scripts" shape the script's own header warns about
# (without the guard, `git -C <plugin_root> rev-parse` walks UP and finds the enclosing repo's
# .git). version-plugin-root-checkout is the non-vacuity control: the same fixture-version script,
# with the plugin root ITSELF the git checkout, so its own resolvable HEAD's short SHA is expected
# output, proving the harness can observe a real SHA at all. Measured mutant (delete
# `&& [ -e "$plugin_root/.git" ]` from bin/harness-version.sh's `if command -v git >/dev/null
# 2>&1 && [ -e "$plugin_root/.git" ]; then` line) — failing exactly: version-cache-under-repo (its
# stdout now contains the enclosing repo's short SHA instead of "-"); version-plugin-root-checkout
# stays green (its own checkout's SHA is the enclosing repo either way, so the mutant is a no-op
# there — the pairing that makes version-cache-under-repo's fail non-vacuous).
case_version_cache_under_repo() {
  local dir cache repo_sha
  dir="$tmpbase/version-cache-under-repo"
  mkdir -p "$dir"
  (cd "$dir" && git init -q) >/dev/null
  seed_commit "$dir" >/dev/null
  repo_sha="$(cd "$dir" && git rev-parse --short HEAD)"
  cache="$dir/cache/tbf"
  mkdir -p "$cache/bin" "$cache/.claude-plugin"
  cp "$root/bin/harness-version.sh" "$cache/bin/harness-version.sh"
  chmod +x "$cache/bin/harness-version.sh"
  printf '{"version": "0.0.0-fixture"}\n' > "$cache/.claude-plugin/plugin.json"
  run_version_script "$cache/bin/harness-version.sh"
  [ "$version_out" = "0.0.0-fixture -" ] || { __ok=0; __why="${__why}stdout: expected '0.0.0-fixture -', got '$version_out'\n"; }
  [ -z "$version_err" ] || { __ok=0; __why="${__why}stderr: expected empty, got '$version_err'\n"; }
  [ "$version_rc" -eq 0 ] || { __ok=0; __why="${__why}rc: expected 0, got $version_rc\n"; }
  case "$version_out" in
    *"$repo_sha"*) __ok=0; __why="${__why}stdout unexpectedly carries the enclosing repo's short sha ($repo_sha) — the .git-presence guard did not stop git from walking up to it\n" ;;
  esac
}

case_version_plugin_root_checkout() {
  local dir repo_sha
  dir="$tmpbase/version-plugin-root-checkout"
  mkdir -p "$dir/bin" "$dir/.claude-plugin"
  (cd "$dir" && git init -q) >/dev/null
  cp "$root/bin/harness-version.sh" "$dir/bin/harness-version.sh"
  chmod +x "$dir/bin/harness-version.sh"
  printf '{"version": "0.0.0-fixture"}\n' > "$dir/.claude-plugin/plugin.json"
  seed_commit "$dir" >/dev/null
  repo_sha="$(cd "$dir" && git rev-parse --short HEAD)"
  run_version_script "$dir/bin/harness-version.sh"
  [ "$version_out" = "0.0.0-fixture $repo_sha" ] || { __ok=0; __why="${__why}stdout: expected '0.0.0-fixture $repo_sha', got '$version_out'\n"; }
  [ -z "$version_err" ] || { __ok=0; __why="${__why}stderr: expected empty, got '$version_err'\n"; }
  [ "$version_rc" -eq 0 ] || { __ok=0; __why="${__why}rc: expected 0, got $version_rc\n"; }
}

# --- branch protection reporting (#234, review F4) -------------------------------------------
# The two WARN stems below are hand-typed literals that must match bin/check-harness.sh's
# PROTECTION_STRICT_WARN_STEM / PROTECTION_CHECKS_WARN_STEM verbatim — dev/selfcheck.sh
# assertion 4.38 pins that agreement mechanically. Each case's comment states the single-clause
# mutant actually run against bin/check-harness.sh and its measured result.

# protection-strict-true — merge policy + the stub's default "healthy" protection document
# (required_status_checks.strict true, non-empty checks/contexts, required_pull_request_reviews
# present): the strict PASS line prints, neither WARN stem prints, and the reviews line reads
# "configured". Measured mutant: inverting the strict compare (`= "true"` -> `= "false"` on the
# `if [ "$strict" = "true" ]` line) — failing exactly protection-strict-true, protection-strict-false,
# protection-zero-contexts, and protection-no-status-checks (every fixture whose document
# reaches the strict compare flips).
case_protection_strict_true() {
  local dir; dir="$(mk_repo protection-strict-true merge verbatim)"
  local ghdir="$tmpbase/protection-strict-true-gh"
  build_stub_gh "$ghdir" main "" healthy
  run_doctor "$dir" "$ghdir:$PATH"
  expect_rc 0
  expect "branch protection: up-to-date branches are required before merge"
  expect_absent "branch protection: up-to-date branches are not required"
  expect_absent "branch protection: zero required status check contexts"
  expect "branch protection: required PR reviews are configured"
}

# protection-strict-false — strict false, non-empty checks/contexts, required_pull_request_reviews
# absent: the strict WARN stem prints, the contexts WARN stem is absent (contexts are non-zero),
# and the reviews line reads "not configured". Measured mutant: the reviews jq filter's `if
# .required_pull_request_reviews then "configured" else "not configured" end` replaced by the
# constant "configured" — failing exactly protection-strict-false (the only new case whose fixture
# has required_pull_request_reviews absent and asserts the "not configured" line).
case_protection_strict_false() {
  local dir; dir="$(mk_repo protection-strict-false merge verbatim)"
  local ghdir="$tmpbase/protection-strict-false-gh"
  build_stub_gh "$ghdir" main "" strict-false
  run_doctor "$dir" "$ghdir:$PATH"
  expect_rc 0
  expect "branch protection: up-to-date branches are not required"
  expect_absent "branch protection: zero required status check contexts"
  expect "branch protection: required PR reviews are not configured"
}

# protection-zero-contexts — strict true, both checks and contexts empty: the contexts WARN stem
# prints, the strict WARN stem is absent. Measured mutant: the context-count comparison's `-gt 0`
# widened to `-ge 0` (`if [ "$ctx_count" -ge 0 ]`, true for the zero count this fixture and
# protection-no-status-checks both produce) — failing exactly protection-zero-contexts (its own
# contexts WARN goes missing) and protection-no-status-checks (its contexts WARN also goes
# missing, so its "both WARN stems" assertion fails too; its strict WARN, from a different clause,
# is unaffected).
case_protection_zero_contexts() {
  local dir; dir="$(mk_repo protection-zero-contexts merge verbatim)"
  local ghdir="$tmpbase/protection-zero-contexts-gh"
  build_stub_gh "$ghdir" main "" zero-contexts
  run_doctor "$dir" "$ghdir:$PATH"
  expect_rc 0
  expect "branch protection: zero required status check contexts"
  expect_absent "branch protection: up-to-date branches are not required"
}

# protection-no-status-checks — the protection document's required_status_checks key is entirely
# absent (not merely empty): both WARN stems print (fail-closed — an absent key is not treated as
# "nothing required, so nothing to warn about"). Measured mutant: a guard added before the whole
# strict/contexts/reviews block requiring `.required_status_checks != null`
# (`if $has_merge_policy && $jq_ready && printf '%s' "$prot" | jq -e '.required_status_checks !=
# null' >/dev/null 2>&1; then`), which skips the block entirely for this fixture's document only
# — failing exactly protection-no-status-checks (every other fixture's document has a non-null
# required_status_checks key, so the added guard never trips for them).
case_protection_no_status_checks() {
  local dir; dir="$(mk_repo protection-no-status-checks merge verbatim)"
  local ghdir="$tmpbase/protection-no-status-checks-gh"
  build_stub_gh "$ghdir" main "" no-status-checks
  run_doctor "$dir" "$ghdir:$PATH"
  expect_rc 0
  expect "branch protection: up-to-date branches are not required"
  expect "branch protection: zero required status check contexts"
}

# protection-no-policy — no "Merge autonomy policy" section at all (base variant), fed the
# strict-false protection document: today's single "branch protection enabled on main" PASS line
# prints and neither new stem prints — the widened report is silent without the policy gate,
# byte-for-byte the pre-#234 behaviour. Measured mutant: dropping the `$merge_effective` gate
# (`if $merge_effective && $jq_ready; then` -> `if $jq_ready; then`) — failing exactly
# protection-no-policy (the strict-false document now produces its WARN even with no policy
# section declared and no "Autonomy mode" section either).
case_protection_no_policy() {
  local dir; dir="$(mk_repo protection-no-policy base verbatim)"
  local ghdir="$tmpbase/protection-no-policy-gh"
  build_stub_gh "$ghdir" main "" strict-false
  run_doctor "$dir" "$ghdir:$PATH"
  expect_rc 0
  expect_absent "branch protection: up-to-date branches are not required"
  expect_absent "branch protection: zero required status check contexts"
  expect "branch protection enabled on main"
}

# protection-endpoint-fails — the protection endpoint call itself fails (stub `api) exit 1`, no
# document at all): today's "no branch protection detected on main" WARN prints and neither new
# stem prints (the widened report never runs — there is no document to read). Measured mutant:
# appending `|| true` to the api-capturing condition (`if [ -n "$repo_slug" ] && prot="$(gh api
# ... 2>/dev/null)"; then` -> `... 2>/dev/null)" || true; then`), which makes the branch always
# taken regardless of gh's exit status — failing exactly protection-endpoint-fails (the doctor now
# claims "branch protection enabled on main" instead of the no-protection WARN; every other new
# fixture's `gh api` call already succeeds, so `|| true` changes nothing for them).
case_protection_endpoint_fails() {
  local dir; dir="$(mk_repo protection-endpoint-fails merge verbatim)"
  local ghdir="$tmpbase/protection-endpoint-fails-gh"
  build_stub_gh "$ghdir" main "" fail
  run_doctor "$dir" "$ghdir:$PATH"
  expect_rc 0
  expect "no branch protection detected on main"
  expect_absent "branch protection: up-to-date branches are not required"
  expect_absent "branch protection: zero required status check contexts"
}

# protection-no-claude-md — no CLAUDE.md at all (removed after mk_repo, the only case that does
# so): the pre-existing "no CLAUDE.md" FAIL still fires (rc 1) and the `== summary:` footer still
# prints — the discriminator that proves the branch-protection section never reads $merge_effective
# (#311 — the variable it actually gates on now, in place of the pre-#311 $has_merge_policy) while
# unset under `set -u` (a hard abort cannot produce that footer). Neither new WARN stem prints
# (merge_effective is false with no CLAUDE.md to declare either the "Merge autonomy policy" or
# "Autonomy mode" section). Measured mutant: deleting the hoisted top-level `merge_effective=false`
# line (the assignment inside the CLAUDE.md-exists branch stays, so every other fixture — which
# always has a CLAUDE.md — is unaffected) — failing exactly protection-no-claude-md, with reason
# "missing: == summary:" (the doctor now dies with an unbound-variable error under `set -u` before
# reaching the branch-protection section's summary footer at all; `expect_rc 1` still happens to
# pass, since bash's own unbound-variable abort also exits 1 — the footer-presence assertion is
# what actually catches the crash).
case_protection_no_claude_md() {
  local dir; dir="$(mk_repo protection-no-claude-md merge verbatim)"
  rm -f "$dir/CLAUDE.md"
  local ghdir="$tmpbase/protection-no-claude-md-gh"
  build_stub_gh "$ghdir" main "" healthy
  run_doctor "$dir" "$ghdir:$PATH"
  expect_rc 1
  expect "no CLAUDE.md"
  expect "== summary:"
  expect_absent "branch protection: up-to-date branches are not required"
  expect_absent "branch protection: zero required status check contexts"
}

# --- autonomy mode (#311) -----------------------------------------------------------------------
# Mutation proof lives in dev/mutants/doctor-tests.json (suite dev/doctor-tests.sh, filter
# "autonomy-mode-"), re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table.
# mutant:311-merge-gate — reverts the merge verdict chain's $merge_effective back to
#   $has_merge_policy, so autonomous mode's implied merge autonomy no longer reaches it.
# mutant:311-ci-gate — reverts the CI-pinning gate back to $has_merge_policy, same regression for
#   that gate alone.
# mutant:311-protection-gate — reverts the branch-protection gate back to $has_merge_policy.
# mutant:311-first-fence — makes the first-fenced-block extraction pass the whole section through,
#   so a bare `mode: autonomous` line outside the fence switches the mode on (fail-open).
# mutant:311-mode-value — sets $autonomy_on on the "Autonomy mode" section's mere presence instead
#   of requiring a 'mode: autonomous' line, so an inert section (e.g. 'mode: manual') would
#   wrongly activate the mode.
# mutant:311-budget-bounds — widens the `0|1|2|3` kickback-budget case arm to also accept 9, so an
#   out-of-range value is silently honoured instead of falling back to the default with a WARN.
# mutant:311-defaultmode-sanitize — bypasses the bare-word `[A-Za-z]+` sanitiser, so an
#   unrecognised defaultMode value is echoed verbatim instead of printed as "(unrecognised value)".
# mutant:311-defaultmode-gate — prints the permissions.defaultMode line regardless of
#   $autonomy_on, so it leaks even with the mode off or inert.
case_autonomy_mode_off() {
  local dir; dir="$(mk_repo autonomy-mode-off base verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "autonomy mode: off"
  expect_absent "permissions.defaultMode"
}

case_autonomy_mode_deny_in_place() {
  local dir; dir="$(mk_repo autonomy-mode-deny-in-place autonomy verbatim)"
  mkdir -p "$dir/.github/workflows"
  printf 'name: ci\non: [pull_request]\njobs:\n  build:\n    steps:\n      - uses: actions/checkout@v4\n' > "$dir/.github/workflows/ci.yml"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "autonomy mode: autonomous (kickback budget 2)"
  expect "half-activated"
  expect_absent "merge autonomy: off"
  expect "CI action pinning: 1 uses: ref(s)"
  expect_absent "post-merge verification"
}

case_autonomy_mode_active() {
  local dir; dir="$(mk_repo autonomy-mode-active autonomy merge-allow-only)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "merge autonomy: active"
  expect_absent "half-activated"
}

case_autonomy_mode_protection() {
  local dir; dir="$(mk_repo autonomy-mode-protection autonomy merge-allow-only)"
  local ghdir="$tmpbase/autonomy-mode-protection-gh"
  build_stub_gh "$ghdir" main "" no-status-checks
  run_doctor "$dir" "$ghdir:$PATH"
  expect_rc 0
  expect "branch protection: up-to-date branches are not required"
  expect "branch protection: zero required status check contexts"
}

case_autonomy_mode_inert() {
  local dir; dir="$(mk_repo autonomy-mode-inert autonomy-inert verbatim)"
  local ghdir="$tmpbase/autonomy-mode-inert-gh"
  build_stub_gh "$ghdir" main "" strict-false
  run_doctor "$dir" "$ghdir:$PATH"
  expect_rc 0
  expect "autonomy mode: inert"
  expect "merge autonomy: off"
  expect_absent "branch protection: up-to-date branches are not required"
  expect_absent "permissions.defaultMode"
}

case_autonomy_mode_unfenced() {
  local dir; dir="$(mk_repo autonomy-mode-unfenced autonomy-unfenced verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "autonomy mode: inert"
  expect_absent "autonomy mode: autonomous"
}

case_autonomy_mode_budget() {
  local dir; dir="$(mk_repo autonomy-mode-budget autonomy-budget verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "autonomy mode: autonomous (kickback budget 3)"
}

case_autonomy_mode_budget_out_of_range() {
  local dir; dir="$(mk_repo autonomy-mode-budget-out-of-range autonomy-badbudget verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "autonomy mode: kickback-budget '9'"
  expect "(kickback budget 2)"
}

case_autonomy_mode_default_mode() {
  local dir; dir="$(mk_repo autonomy-mode-default-mode autonomy verbatim)"
  printf '{"permissions":{"defaultMode":"auto"}}' > "$dir/.claude/settings.local.json"
  mkdir -p "$dir/claudecfg"
  printf '{"permissions":{"defaultMode":"not a mode!"}}' > "$dir/claudecfg/settings.json"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "permissions.defaultMode:"
  expect ".claude/settings.json: (unset)"
  expect ".claude/settings.local.json: auto"
  expect "claudecfg/settings.json: (unrecognised value)"
  expect_absent "not a mode!"
}

# --- governance paths (#331, folds in #330) -----------------------------------------------------
# Mutation proof lives in dev/mutants/doctor-tests.json (suite dev/doctor-tests.sh, filter
# "gov-"), re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table.
# mutant:331-no-renames — drops --no-renames from the floor mode's own git diff call, so a rename
#   disappears instead of printing both its old and new path.
# mutant:331-case-fold — classifies the unlowered path, so case-insensitive matching breaks.
# mutant:331-seg-claude, mutant:331-seg-github, mutant:331-seg-adr, mutant:331-seg-adrs — each
#   removes one built-in path-segment alternative from is_builtin.
# mutant:331-final-claude-md, mutant:331-final-action-yml, mutant:331-final-action-yaml — each
#   removes one built-in final-segment alternative from is_builtin.
# mutant:331-seg-substring — widens */adr/* to *adr*, so a near-miss like src/adr-notes/x.txt
#   wrongly becomes governance.
# mutant:331-lessons-exact-case — folds both sides of the lessons-only comparison to lowercase,
#   so a case-varied .Claude/LESSONS.md wrongly qualifies for lessons-only.
# mutant:331-lessons-sole — treats ANY governance set containing .claude/LESSONS.md as
#   lessons-only, dropping the "exactly one path" requirement.
# mutant:331-declared-ignored — skips the declared-glob matcher entirely.
# mutant:331-declared-replaces-builtin — runs the declared matcher INSTEAD of the built-in one
#   whenever any glob is declared, rather than OR'ing the two.
# mutant:331-read-head — reads $head:CLAUDE.md instead of $base:CLAUDE.md for the declared
#   section, so a PR can loosen (or lose) the rule it's held against.
# mutant:331-negation-accepted — deletes the '!'-prefixed-line malformed check.
# mutant:331-no-fence-reason — deletes the no-fence malformed check.
# mutant:331-unterminated — deletes the unterminated-fence malformed check.
# mutant:331-empty-list — deletes the no-globs malformed check.
# mutant:331-leading-slash — deletes the leading-slash malformed check.
# mutant:331-comment-skip — stops skipping '#'-prefixed lines inside the fenced block.
# mutant:331-empty-diff — deletes the zero-paths error, so an empty diff silently reports
#   verdict=none instead of erroring.
# mutant:331-hex-args — deletes the hex-format argument validation inside run_floor.
# mutant:331-git-error — ignores git diff's own exit status.
# mutant:331-control-char — deletes the control-character path check.
# mutant:331-absent-is-error — treats a base tip with no CLAUDE.md at all as an error, instead of
#   "only the built-in rules apply".
# mutant:331-doctor-malformed-pass — maps the doctor's malformed verdict to `ok` (PASS) instead of
#   `wrn` (WARN) in bin/check-harness.sh.
# mutant:331-doctor-script-missing — deletes the doctor's "could not validate" fallback WARN when
#   bin/governance-paths.sh is missing or unrunnable.
# mutant:331-none-verdict — reports verdict=hold instead of verdict=none when the governance set
#   is empty.
# mutant:331-doctor-absent-pass — reports the doctor's "none declared" PASS as a WARN instead.
# mutant:331-hex-64 — accepts 40-hex arguments only, so a 64-hex (SHA-256) base gets the usage error.
# mutant:331-glob-anchor — unanchors a declared glob containing '/', so x/infra/net/main.tf matches
#   infra/*.tf.
# mutant:331-check-unreadable — makes --check print "absent" for a missing file instead of exiting 2.
# mutant:331-toplevel-cd — drops the cd to the repo toplevel, so diff.relative hides paths outside
#   the caller's subdirectory.
# mutant:331-unbuffered — prints each governance:/changed: line as it is classified, so an error
#   after the first path leaves a path line ahead of verdict=error.

# Floor-mode fixtures (bin/governance-paths.sh run directly via run_gov, on mk_gov_repo fixtures).

case_gov_none() {
  local dir base head
  dir="$(mk_gov_repo gov-none)"
  printf '# CLAUDE.md\n\n## Verification\nRun `true`.\n' > "$dir/CLAUDE.md"
  base="$(gov_commit "$dir")"
  mkdir -p "$dir/src"
  printf 'x\n' > "$dir/src/app.txt"
  head="$(gov_commit "$dir")"
  run_gov "$dir" "$base" "$head"
  expect_rc 0
  expect_gov_out "changed: src/app.txt"
  expect_gov_out_absent "governance:"
  expect_gov_last "verdict=none"
  [ -z "$gov_err" ] || { __ok=0; __why="${__why}stderr: expected empty, got '$gov_err'\n"; }
}

case_gov_builtin_rules() {
  local dir base head
  dir="$(mk_gov_repo gov-builtin-rules)"
  printf 'seed\n' > "$dir/seed.txt"
  base="$(gov_commit "$dir")"
  mkdir -p "$dir/.github" "$dir/.claude" "$dir/docs/adr" "$dir/adrs" "$dir/pkg/sub" \
    "$dir/tools/a" "$dir/tools/b" "$dir/src/adr-notes" "$dir/notes" "$dir/pkg/my.github"
  printf 'x\n' > "$dir/.github/dependabot.yml"
  printf 'x\n' > "$dir/.claude/settings.json"
  printf 'x\n' > "$dir/docs/adr/0001-x.md"
  printf 'x\n' > "$dir/adrs/0002-y.md"
  printf 'x\n' > "$dir/pkg/sub/CLAUDE.md"
  printf 'x\n' > "$dir/tools/a/action.yml"
  printf 'x\n' > "$dir/tools/b/Action.YAML"
  printf 'x\n' > "$dir/src/adr-notes/x.txt"
  printf 'x\n' > "$dir/notes/claude.md.txt"
  printf 'x\n' > "$dir/pkg/my.github/x.txt"
  head="$(gov_commit "$dir")"
  run_gov "$dir" "$base" "$head"
  expect_rc 0
  expect_gov_out "governance: .github/dependabot.yml"
  expect_gov_out "governance: .claude/settings.json"
  expect_gov_out "governance: docs/adr/0001-x.md"
  expect_gov_out "governance: adrs/0002-y.md"
  expect_gov_out "governance: pkg/sub/CLAUDE.md"
  expect_gov_out "governance: tools/a/action.yml"
  expect_gov_out "governance: tools/b/Action.YAML"
  expect_gov_out "changed: src/adr-notes/x.txt"
  expect_gov_out "changed: notes/claude.md.txt"
  expect_gov_out "changed: pkg/my.github/x.txt"
  expect_gov_out_absent "governance: src/adr-notes/x.txt"
  expect_gov_out_absent "governance: notes/claude.md.txt"
  expect_gov_out_absent "governance: pkg/my.github/x.txt"
  expect_gov_last "verdict=hold"
}

case_gov_github_renamed() {
  local dir base head
  dir="$(mk_gov_repo gov-github-renamed)"
  (cd "$dir" && git config diff.renames true) >/dev/null
  mkdir -p "$dir/.github/workflows"
  printf 'name: ci\nfiller filler filler filler filler filler filler filler filler filler\n' \
    > "$dir/.github/workflows/ci.yml"
  base="$(gov_commit "$dir")"
  mkdir -p "$dir/ci"
  (cd "$dir" && git mv .github/workflows/ci.yml ci/pipeline.yml) >/dev/null
  head="$(gov_commit "$dir")"
  run_gov "$dir" "$base" "$head"
  expect_rc 0
  expect_gov_out "governance: .github/workflows/ci.yml"
  expect_gov_out "changed: ci/pipeline.yml"
  expect_gov_last "verdict=hold"
}

case_gov_case_varied_claude_dir() {
  local dir base head
  dir="$(mk_gov_repo gov-case-varied-claude-dir)"
  printf 'seed\n' > "$dir/seed.txt"
  base="$(gov_commit "$dir")"
  mkdir -p "$dir/.Claude"
  printf 'x\n' > "$dir/.Claude/LESSONS.md"
  head="$(gov_commit "$dir")"
  run_gov "$dir" "$base" "$head"
  expect_rc 0
  expect_gov_out "governance: .Claude/LESSONS.md"
  expect_gov_last "verdict=hold"
}

case_gov_lessons_only() {
  local dir base head
  dir="$(mk_gov_repo gov-lessons-only)"
  mkdir -p "$dir/.claude"
  printf 'line1\n' > "$dir/.claude/LESSONS.md"
  base="$(gov_commit "$dir")"
  printf 'line2\n' >> "$dir/.claude/LESSONS.md"
  mkdir -p "$dir/src"
  printf 'x\n' > "$dir/src/app.txt"
  head="$(gov_commit "$dir")"
  run_gov "$dir" "$base" "$head"
  expect_rc 0
  expect_gov_out "governance: .claude/LESSONS.md"
  expect_gov_out "changed: src/app.txt"
  expect_gov_last "verdict=lessons-only"
}

case_gov_lessons_plus_other() {
  local dir base head
  dir="$(mk_gov_repo gov-lessons-plus-other)"
  mkdir -p "$dir/.claude"
  printf 'line1\n' > "$dir/.claude/LESSONS.md"
  base="$(gov_commit "$dir")"
  printf 'line2\n' >> "$dir/.claude/LESSONS.md"
  mkdir -p "$dir/.github"
  printf 'x\n' > "$dir/.github/CODEOWNERS"
  head="$(gov_commit "$dir")"
  run_gov "$dir" "$base" "$head"
  expect_rc 0
  expect_gov_out "governance: .claude/LESSONS.md"
  expect_gov_out "governance: .github/CODEOWNERS"
  expect_gov_last "verdict=hold"
}

case_gov_declared_globs() {
  local dir base head
  dir="$(mk_gov_repo gov-declared-globs)"
  cat > "$dir/CLAUDE.md" <<'EOF'
# CLAUDE.md

## Governance paths
```
docs/policies/
# CI and bots
Jenkinsfile
.gitlab-ci.yml
infra/*.tf
```
EOF
  base="$(gov_commit "$dir")"
  mkdir -p "$dir/docs/policies/sec" "$dir/ci" "$dir/infra/net" "$dir/.github/workflows"
  printf 'x\n' > "$dir/docs/policies/sec/p.md"
  printf 'x\n' > "$dir/ci/Jenkinsfile"
  printf 'x\n' > "$dir/.GitLab-CI.yml"
  printf 'x\n' > "$dir/infra/net/main.tf"
  printf 'x\n' > "$dir/.github/workflows/ci.yml"
  printf 'x\n' > "$dir/docs/policy.md"
  printf 'x\n' > "$dir/Jenkinsfile.bak"
  mkdir -p "$dir/x/infra/net" "$dir/sub/docs/policies"
  printf 'x\n' > "$dir/x/infra/net/main.tf"
  printf 'x\n' > "$dir/sub/docs/policies/p.md"
  head="$(gov_commit "$dir")"
  run_gov "$dir" "$base" "$head"
  expect_rc 0
  expect_gov_out "governance: docs/policies/sec/p.md"
  expect_gov_out "governance: ci/Jenkinsfile"
  expect_gov_out "governance: .GitLab-CI.yml"
  expect_gov_out "governance: infra/net/main.tf"
  expect_gov_out "governance: .github/workflows/ci.yml"
  expect_gov_out "changed: docs/policy.md"
  expect_gov_out "changed: Jenkinsfile.bak"
  expect_gov_out "changed: x/infra/net/main.tf"
  expect_gov_out "changed: sub/docs/policies/p.md"
  expect_gov_last "verdict=hold"
}

case_gov_declared_from_base() {
  local dir base head
  dir="$(mk_gov_repo gov-declared-from-base)"
  cat > "$dir/CLAUDE.md" <<'EOF'
# CLAUDE.md

## Governance paths
```
ops/
```
EOF
  base="$(gov_commit "$dir")"
  rm "$dir/CLAUDE.md"
  mkdir -p "$dir/ops"
  printf 'x\n' > "$dir/ops/deploy.sh"
  head="$(gov_commit "$dir")"
  run_gov "$dir" "$base" "$head"
  expect_rc 0
  expect_gov_out "governance: ops/deploy.sh"
  expect_gov_out "governance: CLAUDE.md"
  expect_gov_last "verdict=hold"
}

case_gov_section_negation() {
  local dir base head
  dir="$(mk_gov_repo gov-section-negation)"
  cat > "$dir/CLAUDE.md" <<'EOF'
# CLAUDE.md

## Governance paths
```
!.github/**
docs/
```
EOF
  base="$(gov_commit "$dir")"
  mkdir -p "$dir/src"
  printf 'x\n' > "$dir/src/app.txt"
  head="$(gov_commit "$dir")"
  run_gov "$dir" "$base" "$head"
  expect_rc 1
  expect_gov_last "verdict=error"
  expect_gov_err "negation"
  expect_gov_out_absent "changed:"
}

case_gov_section_no_fence() {
  local dir base head
  dir="$(mk_gov_repo gov-section-no-fence)"
  cat > "$dir/CLAUDE.md" <<'EOF'
# CLAUDE.md

## Governance paths

Just prose, no fenced block at all.
EOF
  base="$(gov_commit "$dir")"
  printf 'x\n' > "$dir/app.txt"
  head="$(gov_commit "$dir")"
  run_gov "$dir" "$base" "$head"
  expect_rc 1
  expect_gov_last "verdict=error"
  expect_gov_err "no-fence"
}

case_gov_empty_diff() {
  local dir base head
  dir="$(mk_gov_repo gov-empty-diff)"
  printf 'seed\n' > "$dir/seed.txt"
  base="$(gov_commit "$dir")"
  (cd "$dir" && git commit -q --allow-empty -m "empty") >/dev/null
  head="$(cd "$dir" && git rev-parse HEAD)"
  run_gov "$dir" "$base" "$head"
  expect_rc 1
  expect_gov_last "verdict=error"
  expect_gov_err "no paths"
}

case_gov_bad_args() {
  local dir base head
  dir="$(mk_gov_repo gov-bad-args)"
  printf 'seed\n' > "$dir/seed.txt"
  base="$(gov_commit "$dir")"
  printf 'x\n' > "$dir/app.txt"
  head="$(gov_commit "$dir")"
  run_gov "$dir" "--output=$dir/leak.txt" "$head"
  expect_rc 2
  expect_gov_last "verdict=error"
  expect_no_file "$dir/leak.txt"
}

case_gov_missing_object() {
  local dir base fake_head
  dir="$(mk_gov_repo gov-missing-object)"
  printf 'seed\n' > "$dir/seed.txt"
  base="$(gov_commit "$dir")"
  # A well-formed-looking 40-hex value, derived from $base so it's guaranteed hex and (with
  # overwhelming probability) not a real object in this fixture's tiny history.
  fake_head="0${base%?}"
  run_gov "$dir" "$base" "$fake_head"
  expect_rc 1
  expect_gov_last "verdict=error"
  expect_gov_err "git diff failed"
}

case_gov_control_char_path() {
  local dir base head blob basetree newtree mktree_input
  dir="$(mk_gov_repo gov-control-char-path)"
  printf 'x\n' > "$dir/normal.txt"
  base="$(gov_commit "$dir")"
  blob="$(cd "$dir" && printf 'evil content\n' | git hash-object -w --stdin)"
  basetree="$(cd "$dir" && git rev-parse "$base^{tree}")"
  mktree_input="$(mktemp)"
  # a.txt sorts before the newline path, so an unbuffered writer would already have printed its
  # changed: line when the control-character check fires — that is what pins the buffering.
  { (cd "$dir" && git ls-tree -z "$basetree"); printf '100644 blob %s\ta.txt\0' "$blob";
    printf '100644 blob %s\tevil\nfile.txt\0' "$blob"; } \
    > "$mktree_input"
  newtree="$(cd "$dir" && git mktree -z < "$mktree_input")"
  rm -f "$mktree_input"
  head="$(cd "$dir" && git commit-tree "$newtree" -p "$base" -m "embedded newline path")"
  run_gov "$dir" "$base" "$head"
  expect_rc 1
  expect_gov_last "verdict=error"
  expect_gov_out_absent "changed:"
}

case_gov_sha256_arg() {
  local dir base head
  dir="$(mk_gov_repo gov-sha256-arg)"
  printf 'seed\n' > "$dir/seed.txt"
  base="$(gov_commit "$dir")"
  printf 'x\n' > "$dir/app.txt"
  head="$(gov_commit "$dir")"
  # A 64-hex base passes argument validation (rc 1, base not found), never the usage error (rc 2).
  # Not "$base" plus zero padding: git reads a SHA-1 zero-padded to 64 hex as that SHA-1.
  run_gov "$dir" "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" "$head"
  expect_rc 1
  expect_gov_last "verdict=error"
  expect_gov_err "base commit not found"
}

case_gov_diff_relative() {
  local dir base head
  dir="$(mk_gov_repo gov-diff-relative)"
  mkdir -p "$dir/src" "$dir/.github"
  printf 'seed\n' > "$dir/src/seed.txt"
  base="$(gov_commit "$dir")"
  printf 'x\n' > "$dir/src/app.txt"
  printf 'x\n' > "$dir/.github/CODEOWNERS"
  head="$(gov_commit "$dir")"
  (cd "$dir" && git config diff.relative true)
  # Run from src/ with diff.relative set: only the cd to the toplevel keeps .github/ in the list.
  run_gov "$dir/src" "$base" "$head"
  expect_rc 0
  expect_gov_out "governance: .github/CODEOWNERS"
  expect_gov_last "verdict=hold"
}

case_gov_check_unreadable() {
  local dir
  dir="$(mk_gov_repo gov-check-unreadable)"
  run_gov "$dir" --check "$dir/no-such-CLAUDE.md"
  expect_rc 2
  [ -z "$gov_out" ] || { __ok=0; __why="${__why}stdout: expected empty, got '$gov_out'\n"; }
}

case_gov_base_no_claude_md() {
  local dir base head
  dir="$(mk_gov_repo gov-base-no-claude-md)"
  printf 'seed\n' > "$dir/seed.txt"
  base="$(gov_commit "$dir")"
  mkdir -p "$dir/src"
  printf 'x\n' > "$dir/src/app.txt"
  head="$(gov_commit "$dir")"
  run_gov "$dir" "$base" "$head"
  expect_rc 0
  expect_gov_last "verdict=none"
}

# Doctor-mode fixtures (through run_doctor on mk_repo variants).

case_gov_doctor_absent() {
  local dir; dir="$(mk_repo gov-doctor-absent base verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "governance paths: none declared"
}

case_gov_doctor_declared() {
  local dir; dir="$(mk_repo gov-doctor-declared gov-declared verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "governance paths: 3 declared glob(s)"
}

case_gov_doctor_empty() {
  local dir; dir="$(mk_repo gov-doctor-empty gov-empty verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "WARN  governance paths: 'Governance paths' section is malformed (no-globs)"
}

case_gov_doctor_unterminated() {
  local dir; dir="$(mk_repo gov-doctor-unterminated gov-unterminated verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "WARN  governance paths: 'Governance paths' section is malformed (unterminated-fence)"
}

case_gov_doctor_leading_slash() {
  local dir; dir="$(mk_repo gov-doctor-leading-slash gov-leading-slash verbatim)"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "WARN  governance paths: 'Governance paths' section is malformed (leading-slash)"
}

case_gov_doctor_script_missing() {
  local dir; dir="$(mk_repo gov-doctor-script-missing base verbatim)"
  rm -f "$dir/bin/governance-paths.sh"
  run_doctor "$dir" "$stub_gh_dir:$PATH"
  expect_rc 0
  expect "governance paths: could not validate"
}

# ---------------------------------------------------------------------------------------------
stub_gh_dir="$tmpbase/stub-gh"
build_stub_gh "$stub_gh_dir"

# Third stub gh that additionally reports the "scoped-autonomy" grant label as existing, for the
# scoped-* cases above.
stub_gh_scoped_dir="$tmpbase/stub-gh-scoped"
build_stub_gh "$stub_gh_scoped_dir" "main" "scoped-autonomy"

# Second stub gh reporting a default branch the template does NOT guard, for
# guard-coverage-offbranch — trunk, which must differ from the branch the template's
# branch-scoped denies name (main).
alt_branch="trunk"
stub_gh_alt_dir="$tmpbase/stub-gh-alt"
build_stub_gh "$stub_gh_alt_dir" "$alt_branch"

# The operations templates/repo-settings.json's branch-scoped bare deny entries guard for
# "main" — same jq-then-sed idiom build_stub_gh uses for labels — so guard-coverage-offbranch's
# expectations are derived from the real template, never a second hard-coded copy.
tmpl_branch_ops="$(jq -r '.permissions.deny[]? // empty' "$root/templates/repo-settings.json" \
  | sed -n 's/^Bash(git \(.*\) main:\*)$/\1/p' | sort -u)"

# empty-needle-guard (#262-1) — exercises every guarded helper in this file (expect, expect_absent)
# with an empty needle, and asserts the guard fired for each: sets $doctor_out to a fixed non-empty
# value first (so a non-guarded regression couldn't pass vacuously against empty captured output),
# calls both helpers with "", then checks the ACCUMULATED __ok/__why saved off before this case's
# own __ok/__why are reset by the runner loop. Measured mutant: delete `needle_required expect
# "$1" || return 0` from expect() only — failing exactly empty-needle-guard (saved_why no longer
# names "expect:").
case_empty_needle_guard() {
  local saved_ok saved_why
  doctor_out="fixture output for the empty-needle guard (#262)"
  __ok=1; __why=""
  expect ""
  expect_absent ""
  saved_ok="$__ok"
  saved_why="$__why"
  __ok=1; __why=""
  if [ "$saved_ok" -ne 0 ]; then
    __ok=0; __why="${__why}empty-needle guard never fired (saved_ok=$saved_ok)\n"
  fi
  case "$saved_why" in
    *"expect: empty needle"*) : ;;
    *) __ok=0; __why="${__why}expect's empty-needle guard did not name itself: '$saved_why'\n" ;;
  esac
  case "$saved_why" in
    *"expect_absent: empty needle"*) : ;;
    *) __ok=0; __why="${__why}expect_absent's empty-needle guard did not name itself: '$saved_why'\n" ;;
  esac
}

# --- codex setup (#408) -------------------------------------------------------------------------
# bin/codex-setup.sh — the Codex compatibility installer. Its own --check drift mode is this
# script's own companion (#410 consumes it), so it lives here rather than in a new suite.

# mk_cx_plugin NAME VERSION [ROOTDIR] — builds a fake Codex plugin-cache install under
# $tmpbase/NAME/<ROOTDIR default "plugins">/cache/trail-blazer-flow/trail-blazer-flow/VERSION/,
# containing copies of THIS checkout's bin/*.sh, agents/{planner,implementer,verifier}.md and
# templates/codex.rules — the same copy-script-into-a-fake-plugin-root pattern
# version-cache-under-repo (#262-2) uses above, generalised to a whole plugin tree. Prints the
# VERSION directory (the plugin root codex-setup.sh itself would resolve from its own location).
mk_cx_plugin() {
  local name="$1" version="$2" rootdir="${3:-plugins}"
  local proot="$tmpbase/$name/$rootdir/cache/trail-blazer-flow/trail-blazer-flow/$version"
  mkdir -p "$proot/bin" "$proot/agents" "$proot/templates"
  cp "$root"/bin/*.sh "$proot/bin/"
  chmod +x "$proot"/bin/*.sh
  cp "$root/agents/planner.md" "$root/agents/implementer.md" "$root/agents/verifier.md" "$proot/agents/"
  cp "$root/templates/codex.rules" "$proot/templates/codex.rules"
  printf '%s' "$proot"
}

# mk_cx_repo NAME — a fresh throwaway git repo under $tmpbase/NAME with a CLAUDE.md and its own
# home/ (for HOME/XDG_CONFIG_HOME isolation, same idiom as mk_gov_repo). No AGENTS.md — codex-setup
# fixtures that need one write it themselves. Prints the fixture path.
mk_cx_repo() {
  local name="$1"
  local dir="$tmpbase/$name"
  mkdir -p "$dir/home"
  (
    cd "$dir" &&
    git init -q &&
    git config user.name "doctor-tests" &&
    git config user.email "doctor-tests@example.invalid" &&
    git config commit.gpgsign false &&
    git symbolic-ref HEAD refs/heads/main &&
    git commit -q --allow-empty -m init
  ) >/dev/null
  printf '# CLAUDE.md\n\n## Verification\n\nRun `true` to verify. (fixture stub)\n' > "$dir/CLAUDE.md"
  printf '%s' "$dir"
}

# run_cx PLUGIN REPO ARGS… — same never-a-command-substitution idiom as run_gov, running THIS
# fixture's own bin/codex-setup.sh (never $root's) with cwd = REPO and HOME/XDG_CONFIG_HOME pointed
# into REPO (so a developer's real global git config can never leak into a verdict) and
# GIT_CONFIG_NOSYSTEM=1. Captures stdout/stderr to SEPARATE files, leaving $cx_out/$cx_err/$cx_rc
# set as globals, and copies a merged view into $doctor_out/$doctor_rc so a failing codex-setup-*
# case's captured output still reaches the generic runner loop's diagnostics dump below.
cx_out=""
cx_err=""
cx_rc=0
run_cx() {
  local plugin="$1" repo="$2" outfile errfile
  shift 2
  outfile="$(mktemp)"; errfile="$(mktemp)"
  (cd "$repo" && HOME="$repo/home" XDG_CONFIG_HOME="$repo/home/.config" GIT_CONFIG_NOSYSTEM=1 "$bash_bin" "$plugin/bin/codex-setup.sh" "$@") >"$outfile" 2>"$errfile"
  cx_rc=$?
  cx_out="$(cat "$outfile")"
  cx_err="$(cat "$errfile")"
  rm -f "$outfile" "$errfile"
  doctor_out="OUT: $cx_out
ERR: $cx_err"
  doctor_rc=$cx_rc
}

# expect_cx_out/expect_cx_err/expect_cx_out_absent (#408) — same idiom as expect_gov_out/
# expect_gov_err above, against $cx_out/$cx_err specifically rather than the merged $doctor_out.
# All three are guarded by needle_required (#262).
expect_cx_out() {
  needle_required expect_cx_out "$1" || return 0
  grep -qF -- "$1" <<<"$cx_out" || { __ok=0; __why="${__why}missing (cx stdout): $1\n"; }
}
expect_cx_err() {
  needle_required expect_cx_err "$1" || return 0
  grep -qF -- "$1" <<<"$cx_err" || { __ok=0; __why="${__why}missing (cx stderr): $1\n"; }
}
expect_cx_out_absent() {
  needle_required expect_cx_out_absent "$1" || return 0
  grep -qF -- "$1" <<<"$cx_out" && { __ok=0; __why="${__why}unexpected (cx stdout): $1\n"; }
}

# codex-setup-fresh — no AGENTS.md: rc 0, all five files, no AGENTS.md created, the fallback line
# in .codex/config.toml, five wrote= lines, and the three next: lines including codex --no-daemon.
# mutant:408-cx-agents-md-inverted — inverting bin/codex-setup.sh's `if [ -f "$agents_md" ]; then`
#   test swaps the AGENTS.md and config.toml branches for every fixture that reaches contract
#   loading: this case's AGENTS.md-less repo takes the AGENTS.md branch and writes one, and
#   codex-setup-contract-agents-md's repo takes the config.toml branch instead.
case_codex_setup_fresh() {
  local plugin repo
  plugin="$(mk_cx_plugin cx-fresh-plugin 2.9.0)"
  repo="$(mk_cx_repo cx-fresh-repo)"
  run_cx "$plugin" "$repo"
  expect_rc 0
  expect_cx_out "wrote=.codex/agents/planner.toml"
  expect_cx_out "wrote=.codex/agents/implementer.toml"
  expect_cx_out "wrote=.codex/agents/verifier.toml"
  expect_cx_out "wrote=.codex/rules/trail-blazer-flow.rules"
  expect_cx_out "wrote=.codex/config.toml"
  expect_no_file "$repo/AGENTS.md"
  if [ -f "$repo/.codex/config.toml" ]; then
    grep -qF 'project_doc_fallback_filenames' "$repo/.codex/config.toml" \
      || { __ok=0; __why="${__why}config.toml missing the fallback key\n"; }
    grep -qF '"CLAUDE.md"' "$repo/.codex/config.toml" \
      || { __ok=0; __why="${__why}config.toml missing the CLAUDE.md fallback entry\n"; }
  else
    __ok=0; __why="${__why}config.toml was not written\n"
  fi
  expect_cx_out "next: trust this project in Codex"
  expect_cx_out "next: trust this plugin's hooks"
  expect_cx_out "codex --no-daemon"
}

# codex-setup-idempotent — a second run gives only unchanged= lines, every file byte-identical to
# the first run's copies, and --check afterward is rc 0 with no drift= line.
case_codex_setup_idempotent() {
  local plugin repo
  plugin="$(mk_cx_plugin cx-idem-plugin 2.9.0)"
  repo="$(mk_cx_repo cx-idem-repo)"
  run_cx "$plugin" "$repo"
  expect_rc 0
  local saved="$tmpbase/cx-idem-saved"
  mkdir -p "$saved"
  cp -R "$repo/.codex" "$saved/.codex"
  run_cx "$plugin" "$repo"
  expect_rc 0
  expect_cx_out_absent "wrote="
  expect_cx_out "unchanged=.codex/agents/planner.toml"
  expect_cx_out "unchanged=.codex/agents/implementer.toml"
  expect_cx_out "unchanged=.codex/agents/verifier.toml"
  expect_cx_out "unchanged=.codex/rules/trail-blazer-flow.rules"
  expect_cx_out "unchanged=.codex/config.toml"
  local f
  for f in agents/planner.toml agents/implementer.toml agents/verifier.toml \
           rules/trail-blazer-flow.rules config.toml; do
    cmp -s "$repo/.codex/$f" "$saved/.codex/$f" \
      || { __ok=0; __why="${__why}$f changed between runs\n"; }
  done
  run_cx "$plugin" "$repo" --check
  expect_rc 0
  expect_cx_out_absent "drift="
}

# codex-setup-agents-roundtrip — for each role: name == role; description == this fixture's own
# awk fold of the real agents/<role>.md (verifier's own line contains the escaped
# \"Resilient dispatch\"); the lines between developer_instructions = ''' and the closing ''' cmp
# equal to this fixture's own tail-based extraction of the md body; no ^tools/^model line. Where
# `python3 -c 'import tomllib'` succeeds, also parses each TOML and cross-checks the same values
# structurally (ADVISORY Q9).
# mutant:408-cx-desc-escape — dropping bin/codex-setup.sh's `"` escape on the description leaves
#   an unescaped quote in verifier.toml's generated line, breaking this case's own escaped compare.
case_codex_setup_agents_roundtrip() {
  local plugin repo role
  plugin="$(mk_cx_plugin cx-roundtrip-plugin 2.9.0)"
  repo="$(mk_cx_repo cx-roundtrip-repo)"
  run_cx "$plugin" "$repo"
  expect_rc 0
  for role in planner implementer verifier; do
    local toml="$repo/.codex/agents/$role.toml" md="$root/agents/$role.md"
    [ -f "$toml" ] || { __ok=0; __why="${__why}$role.toml missing\n"; continue; }
    grep -qF "name = \"$role\"" "$toml" \
      || { __ok=0; __why="${__why}$role.toml: name != $role\n"; }
    local fm_end want_desc
    fm_end="$(awk '$0=="---"{n++; if(n==2){print NR; exit}}' "$md")"
    want_desc="$(awk -v lim="$fm_end" '
      NR>=lim { exit }
      /^description:[ \t]*/ { v=$0; sub(/^description:[ \t]*/,"",v); if (v==">"||v==">-") { indesc=1 } else { desc=v; indesc=0 }; next }
      indesc==1 && /^[ \t]+[^ \t]/ { v=$0; sub(/^[ \t]+/,"",v); if (desc=="") desc=v; else desc=desc " " v; next }
      { indesc=0 }
      END { print desc }
    ' "$md")"
    local want_desc_esc="${want_desc//\\/\\\\}"
    want_desc_esc="${want_desc_esc//\"/\\\"}"
    grep -qF "description = \"$want_desc_esc\"" "$toml" \
      || { __ok=0; __why="${__why}$role.toml: description mismatch\n"; }
    if [ "$role" = "verifier" ]; then
      grep -qF '\"Resilient dispatch\"' "$toml" \
        || { __ok=0; __why="${__why}verifier.toml: description does not carry the escaped Resilient dispatch quote\n"; }
    fi
    grep -qE '^tools' "$toml" && { __ok=0; __why="${__why}$role.toml: unexpected tools line\n"; }
    grep -qE '^model' "$toml" && { __ok=0; __why="${__why}$role.toml: unexpected model line\n"; }
    local start end
    start="$(grep -n '^developer_instructions = ' "$toml" | head -1 | cut -d: -f1)"
    end="$(tail -n +"$((start + 1))" "$toml" | grep -n "^'''$" | head -1 | cut -d: -f1)"
    end=$((start + end))
    sed -n "$((start + 1)),$((end - 1))p" "$toml" > "$tmpbase/cx-extracted-$role.txt"
    tail -n +"$((fm_end + 1))" "$md" | tr -d '\r' > "$tmpbase/cx-real-$role.txt"
    cmp -s "$tmpbase/cx-extracted-$role.txt" "$tmpbase/cx-real-$role.txt" \
      || { __ok=0; __why="${__why}$role.toml: developer_instructions body is not byte-identical to agents/$role.md's body\n"; }
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
      python3 - "$toml" "$role" "$want_desc" <<'PYEOF' || { __ok=0; __why="${__why}$role.toml: tomllib cross-check failed\n"; }
import sys, tomllib
path, role, want_desc = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "rb") as f:
    data = tomllib.load(f)
assert data["name"] == role, (data.get("name"), role)
assert data["description"] == want_desc, (data.get("description"), want_desc)
assert "tools" not in data
assert "model" not in data
assert "developer_instructions" in data
PYEOF
    fi
  done
}

# codex-setup-agents-triple-quote-refused — the fixture plugin's own planner.md body gets ''' appended:
# rc 2, stderr names planner.md, and no .codex directory is created at all.
case_codex_setup_agents_triple_quote_refused() {
  local plugin repo
  plugin="$(mk_cx_plugin cx-triplequote-plugin 2.9.0)"
  repo="$(mk_cx_repo cx-triplequote-repo)"
  printf "\nsome text with a ''' triple quote\n" >> "$plugin/agents/planner.md"
  run_cx "$plugin" "$repo"
  expect_rc 2
  expect_cx_err "planner.md"
  expect_no_file "$repo/.codex"
}

# codex-setup-agents-triple-quote-verifier (#408 kickback finding 1) — the SAME corruption as
# above, but on verifier.md, the LAST role in CODEX_AGENT_ROLES: rc 2, stderr names verifier.md,
# and .codex is still entirely absent — planner.toml and implementer.toml were already generated
# (both earlier roles are clean) but never installed, proving generation for every role happens
# before any role's file is moved into place.
case_codex_setup_agents_triple_quote_verifier() {
  local plugin repo
  plugin="$(mk_cx_plugin cx-triplequote-verifier-plugin 2.9.0)"
  repo="$(mk_cx_repo cx-triplequote-verifier-repo)"
  printf "\nsome text with a ''' triple quote\n" >> "$plugin/agents/verifier.md"
  run_cx "$plugin" "$repo"
  expect_rc 2
  expect_cx_err "verifier.md"
  expect_no_file "$repo/.codex"
  expect_no_file "$repo/.codex/agents/planner.toml"
  expect_no_file "$repo/.codex/agents/implementer.toml"
}

# codex-setup-rules-content — every ADVISORY-Q1 allow line is present; the forbidden token-list
# SET equals the set derived by jq from templates/repo-settings.json's own .permissions.deny[]
# (bare Bash(<words>:*) entries only, excluding every `git -C *` entry); no @PLUGIN_BIN@ literal
# remains anywhere in the installed rules file.
# mutant:419-cx-restore-narrowed — narrowing templates/codex.rules' git-restore allow pattern back
#   to ["git", "restore", "--staged"] makes this case's token check fail to find the widened
#   ["git", "restore"] allow rule.
# mutant:419-cx-restore-prompt — changing that rule's decision from "allow" to "prompt" breaks the
#   restore token, which pins the pattern and the decision together.
case_codex_setup_rules_content() {
  local plugin repo rules
  plugin="$(mk_cx_plugin cx-rules-content-plugin 2.9.0)"
  repo="$(mk_cx_repo cx-rules-content-repo)"
  run_cx "$plugin" "$repo"
  expect_rc 0
  rules="$repo/.codex/rules/trail-blazer-flow.rules"
  [ -f "$rules" ] || { __ok=0; __why="${__why}rules file missing\n"; return; }
  local tok
  for tok in 'pattern = ["git", "add"]' 'pattern = ["git", "commit"]' 'pattern = ["git", "push"]' \
             'pattern = ["git", "fetch"]' 'pattern = ["git", "pull"]' 'pattern = ["git", "checkout"]' \
             'pattern = ["git", "switch"]' 'pattern = ["git", "restore"], decision = "allow"' \
             'pattern = ["git", "reset", "--soft"]' 'pattern = ["gh"]'; do
    grep -qF "$tok" "$rules" || { __ok=0; __why="${__why}missing allow rule: $tok\n"; }
  done
  grep -qF '@PLUGIN_BIN@' "$rules" && { __ok=0; __why="${__why}unsubstituted @PLUGIN_BIN@ literal remains\n"; }

  local want_forbidden got_forbidden
  want_forbidden="$(jq -r '.permissions.deny[]?' "$root/templates/repo-settings.json" \
    | sed -n 's/^Bash(\(.*\):\*)$/\1/p' \
    | grep -v '^git -C ' \
    | awk '{ printf "["; for(i=1;i<=NF;i++){ printf "%s\"%s\"", (i>1?", ":""), $i }; print "]" }' \
    | sort -u)"
  got_forbidden="$(grep -oE 'pattern = \[[^]]*\], decision = "forbidden"' "$rules" \
    | sed -E 's/pattern = (\[[^]]*\]), decision = "forbidden"/\1/' \
    | sort -u)"
  [ "$want_forbidden" = "$got_forbidden" ] \
    || { __ok=0; __why="${__why}forbidden token-list set mismatch\nwant:\n$want_forbidden\ngot:\n$got_forbidden\n"; }
}

# codex-setup-rules-gated — the .sh prefix_rule names, the host_executable names, and the set of
# ten listed scripts are all the SAME set; every host_executable path is exactly
# <plugin>/bin/<name>; every one of those names exists under $root/bin; codex-setup.sh,
# harness-version.sh and governance-paths.sh are absent from both sets.
# mutant:408-cx-host-exec-dropped — deleting one host_executable line from templates/codex.rules
#   drops it from the installed rules file's own host_executable-name set, breaking the equality.
case_codex_setup_rules_gated() {
  local plugin repo rules
  plugin="$(mk_cx_plugin cx-rules-gated-plugin 2.9.0)"
  repo="$(mk_cx_repo cx-rules-gated-repo)"
  run_cx "$plugin" "$repo"
  expect_rc 0
  rules="$repo/.codex/rules/trail-blazer-flow.rules"
  [ -f "$rules" ] || { __ok=0; __why="${__why}rules file missing\n"; return; }
  local sh_names hx_names want_names
  sh_names="$(grep -oE '^prefix_rule\(pattern = \["[a-z-]+\.sh"\]' "$rules" \
    | sed -E 's/^prefix_rule\(pattern = \["([a-z-]+\.sh)"\]/\1/' | sort -u)"
  hx_names="$(grep -oE '^host_executable\(name = "[a-z-]+\.sh"' "$rules" \
    | sed -E 's/^host_executable\(name = "([a-z-]+\.sh)"/\1/' | sort -u)"
  want_names="$(printf '%s\n' check-decision-record.sh check-harness.sh cleanup-after-merge.sh \
    find-implementation-work.sh find-planning-work.sh harness-lock.sh harness-status.sh \
    harness-stop.sh reconcile-ledger.sh setup-labels.sh | sort -u)"
  [ "$sh_names" = "$want_names" ] || { __ok=0; __why="${__why}gated .sh prefix_rule names != the ten listed scripts\ngot:\n$sh_names\n"; }
  [ "$hx_names" = "$want_names" ] || { __ok=0; __why="${__why}host_executable names != the ten listed scripts\ngot:\n$hx_names\n"; }
  local n
  for n in $want_names; do
    grep -qF "host_executable(name = \"$n\", paths = [\"$plugin/bin/$n\"])" "$rules" \
      || { __ok=0; __why="${__why}host_executable path for $n is not exactly <plugin>/bin/$n\n"; }
    [ -f "$root/bin/$n" ] || { __ok=0; __why="${__why}$n does not exist under $root/bin\n"; }
  done
  local absent
  for absent in codex-setup.sh harness-version.sh governance-paths.sh; do
    case " $sh_names $hx_names " in
      *" $absent "*) __ok=0; __why="${__why}$absent unexpectedly gated\n" ;;
    esac
  done
}

# codex-setup-contract-agents-md — a pre-existing AGENTS.md keeps its original content, gains
# exactly one begin marker with CLAUDE.md named in the block, and .codex/config.toml never gets the
# fallback key; a second run still leaves exactly one begin marker. --check before the first run
# pins the missing-pointer token (#408 kickback finding 3).
case_codex_setup_contract_agents_md() {
  local plugin repo
  plugin="$(mk_cx_plugin cx-agents-md-plugin 2.9.0)"
  repo="$(mk_cx_repo cx-agents-md-repo)"
  printf '# AGENTS.md\n\nSome pre-existing repo-specific note.\n' > "$repo/AGENTS.md"
  run_cx "$plugin" "$repo" --check
  expect_rc 1
  expect_cx_out "drift=AGENTS.md reason=missing-pointer"
  expect_no_file "$repo/.codex"
  run_cx "$plugin" "$repo"
  expect_rc 0
  expect_cx_out "wrote=AGENTS.md"
  grep -qF "Some pre-existing repo-specific note." "$repo/AGENTS.md" \
    || { __ok=0; __why="${__why}original AGENTS.md content lost\n"; }
  cx_marker_count() { grep -cF -- "$1" "$repo/AGENTS.md"; }
  [ "$(cx_marker_count '<!-- trail-blazer-flow:contract-pointer -->')" = "1" ] \
    || { __ok=0; __why="${__why}begin marker count != 1\n"; }
  grep -qF "CLAUDE.md" "$repo/AGENTS.md" || { __ok=0; __why="${__why}block does not name CLAUDE.md\n"; }
  [ -f "$repo/.codex/config.toml" ] && grep -qF 'project_doc_fallback_filenames' "$repo/.codex/config.toml" \
    && { __ok=0; __why="${__why}config.toml unexpectedly got the fallback key alongside AGENTS.md\n"; }
  run_cx "$plugin" "$repo"
  expect_rc 0
  expect_cx_out "unchanged=AGENTS.md"
  [ "$(cx_marker_count '<!-- trail-blazer-flow:contract-pointer -->')" = "1" ] \
    || { __ok=0; __why="${__why}begin marker count != 1 after a second run\n"; }
}

# codex-setup-agents-md-malformed (#408 kickback) — AGENTS.md shapes whose marker lines are not
# exact whole-line matches, or are unpaired: a trailing-text end marker, a CRLF end marker, an
# unpaired begin marker, CRLF on both markers, trailing text on both markers, a trailing-text begin
# marker before an exact end marker, and a valid pair plus a prose line quoting the begin marker
# or the end marker.
# Each: write mode rc 2 with AGENTS.md byte-identical (tail content preserved) and no .codex at all
# (the pre-flight installs nothing, rules file included); --check reports
# drift=AGENTS.md reason=malformed-pointer (rc 1).
# mutant:408-cx-malformed-off — forcing bin/codex-setup.sh's `malformed=true` assignment to
#   `malformed=false` makes the malformed shapes rewrite instead of refuse.
# mutant:408-cx-substring-guard — disabling the substring-vs-exact count comparison lets a file
#   carrying a non-exact begin-marker line read as missing-pointer or a valid pair.
# mutant:408-cx-end-guard — exact-matching the end marker's substring count switches the guard off
#   for the end marker, so a prose mention of it next to a valid pair is rewritten.
case_codex_setup_agents_md_malformed() {
  local plugin
  plugin="$(mk_cx_plugin cx-malformed-plugin 2.9.0)"

  local variant content repo before
  for variant in trailing-text crlf unpaired-begin crlf-both trailing-both begin-trailing prose-mention end-prose-mention; do
    repo="$(mk_cx_repo "cx-malformed-repo-$variant")"
    case "$variant" in
      trailing-text)
        printf '# AGENTS.md\n\nNote.\n\n<!-- trail-blazer-flow:contract-pointer -->\nold body\n<!-- /trail-blazer-flow:contract-pointer --> extra\n\nTail content.\n' > "$repo/AGENTS.md"
        ;;
      crlf)
        printf '# AGENTS.md\n\nNote.\n\n<!-- trail-blazer-flow:contract-pointer -->\nold body\n<!-- /trail-blazer-flow:contract-pointer -->\r\n\nTail content.\n' > "$repo/AGENTS.md"
        ;;
      unpaired-begin)
        printf '# AGENTS.md\n\nNote.\n\n<!-- trail-blazer-flow:contract-pointer -->\nold body\n\nTail content.\n' > "$repo/AGENTS.md"
        ;;
      crlf-both)
        printf '# AGENTS.md\r\n\r\n<!-- trail-blazer-flow:contract-pointer -->\r\nold body\r\n<!-- /trail-blazer-flow:contract-pointer -->\r\n\r\nTail content.\r\n' > "$repo/AGENTS.md"
        ;;
      trailing-both)
        printf '# AGENTS.md\n\n<!-- trail-blazer-flow:contract-pointer --> x\nold body\n<!-- /trail-blazer-flow:contract-pointer --> x\n\nTail content.\n' > "$repo/AGENTS.md"
        ;;
      begin-trailing)
        printf '# AGENTS.md\n\n<!-- trail-blazer-flow:contract-pointer --> x\nold body\n<!-- /trail-blazer-flow:contract-pointer -->\n\nTail content.\n' > "$repo/AGENTS.md"
        ;;
      end-prose-mention)
        printf '# AGENTS.md\n\n<!-- trail-blazer-flow:contract-pointer -->\nold body\n<!-- /trail-blazer-flow:contract-pointer -->\n\nThe marker <!-- /trail-blazer-flow:contract-pointer --> closes the block.\n\nTail content.\n' > "$repo/AGENTS.md"
        ;;
      prose-mention)
        printf '# AGENTS.md\n\nThe marker <!-- trail-blazer-flow:contract-pointer --> opens the block.\n\n<!-- trail-blazer-flow:contract-pointer -->\nold body\n<!-- /trail-blazer-flow:contract-pointer -->\n\nTail content.\n' > "$repo/AGENTS.md"
        ;;
    esac
    before="$(cat "$repo/AGENTS.md")"
    run_cx "$plugin" "$repo"
    expect_rc 2
    [ "$(cat "$repo/AGENTS.md")" = "$before" ] \
      || { __ok=0; __why="${__why}$variant: AGENTS.md was modified despite the malformed marker\n"; }
    grep -qF "Tail content." "$repo/AGENTS.md" \
      || { __ok=0; __why="${__why}$variant: tail content after the marker was lost\n"; }
    expect_no_file "$repo/.codex"
    run_cx "$plugin" "$repo" --check
    expect_rc 1
    expect_cx_out "drift=AGENTS.md reason=malformed-pointer"
  done
}

# codex-setup-config-merge — a pre-existing .codex/config.toml with a top-level key plus a
# [profiles.x] table: the fallback key is inserted ABOVE the first table header, and both the
# original top-level key and the table survive untouched. --check before the first run pins the
# missing-fallback token (#408 kickback finding 3).
# mutant:408-cx-config-append — reordering bin/codex-setup.sh's insert block to write the
#   existing content FIRST puts the fallback key after the table instead of before it.
case_codex_setup_config_merge() {
  local plugin repo
  plugin="$(mk_cx_plugin cx-config-merge-plugin 2.9.0)"
  repo="$(mk_cx_repo cx-config-merge-repo)"
  mkdir -p "$repo/.codex"
  printf 'some_other_key = "keep-me"\n\n[profiles.x]\nmodel = "gpt-5"\n' > "$repo/.codex/config.toml"
  run_cx "$plugin" "$repo" --check
  expect_rc 1
  expect_cx_out "drift=.codex/config.toml reason=missing-fallback"
  run_cx "$plugin" "$repo"
  expect_rc 0
  expect_cx_out "wrote=.codex/config.toml"
  grep -qF 'some_other_key = "keep-me"' "$repo/.codex/config.toml" \
    || { __ok=0; __why="${__why}pre-existing top-level key lost\n"; }
  grep -qF '[profiles.x]' "$repo/.codex/config.toml" \
    || { __ok=0; __why="${__why}pre-existing table lost\n"; }
  local key_line table_line
  key_line="$(grep -n 'project_doc_fallback_filenames' "$repo/.codex/config.toml" | head -1 | cut -d: -f1)"
  table_line="$(grep -n '^\[' "$repo/.codex/config.toml" | head -1 | cut -d: -f1)"
  [ -n "$key_line" ] && [ -n "$table_line" ] && [ "$key_line" -lt "$table_line" ] \
    || { __ok=0; __why="${__why}fallback key not inserted above the first table header\n"; }
}

# codex-setup-config-conflict — a pre-existing top-level project_doc_fallback_filenames value that
# does NOT name CLAUDE.md: write mode refuses (rc 2, file unchanged, and .codex/agents absent —
# #408 kickback finding 1, proving the conflict is caught before any earlier-generated agent TOML
# is installed); --check reports reason=fallback-conflict (rc 1).
# mutant:408-cx-rules-preflight — installing the rules file directly instead of queueing it for the
#   post-validation drain leaves .codex/rules behind when a later step refuses.
case_codex_setup_config_conflict() {
  local plugin repo before
  plugin="$(mk_cx_plugin cx-config-conflict-plugin 2.9.0)"
  repo="$(mk_cx_repo cx-config-conflict-repo)"
  mkdir -p "$repo/.codex"
  printf 'project_doc_fallback_filenames = ["README.md"]\n' > "$repo/.codex/config.toml"
  before="$(cat "$repo/.codex/config.toml")"
  run_cx "$plugin" "$repo"
  expect_rc 2
  [ "$(cat "$repo/.codex/config.toml")" = "$before" ] \
    || { __ok=0; __why="${__why}config.toml was modified despite the conflict\n"; }
  expect_no_file "$repo/.codex/agents"
  expect_no_file "$repo/.codex/rules"
  run_cx "$plugin" "$repo" --check
  expect_rc 1
  expect_cx_out "drift=.codex/config.toml reason=fallback-conflict"
}

# codex-setup-check-drift — --check on a fresh repo: rc 1, reason=missing for every file, and no
# .codex directory created. After a real setup, one agent TOML is hand-edited: --check then
# reports reason=differs for exactly that file.
case_codex_setup_check_drift() {
  local plugin repo
  plugin="$(mk_cx_plugin cx-check-drift-plugin 2.9.0)"
  repo="$(mk_cx_repo cx-check-drift-repo)"
  run_cx "$plugin" "$repo" --check
  expect_rc 1
  expect_cx_out "drift=.codex/agents/planner.toml reason=missing"
  expect_cx_out "drift=.codex/rules/trail-blazer-flow.rules reason=missing"
  expect_cx_out "drift=.codex/config.toml reason=missing"
  expect_no_file "$repo/.codex"

  run_cx "$plugin" "$repo"
  expect_rc 0
  printf '\n# hand-edited\n' >> "$repo/.codex/agents/planner.toml"
  run_cx "$plugin" "$repo" --check
  expect_rc 1
  expect_cx_out "drift=.codex/agents/planner.toml reason=differs"
  expect_cx_out_absent "drift=.codex/agents/implementer.toml"
}

# codex-setup-check-stale-version — rules generated from a 2.9.0 plugin root, then --checked from
# a COPY of the repo at 3.0.0, report reason=stale-plugin-path (rc 1) and write nothing at all — a
# find-listing plus per-file checksums taken immediately before and after that --check call prove
# it. A write from 3.0.0 then pins the 3.0.0 path, and a further --check from 3.0.0 is rc 0.
# mutant:408-cx-stale-reason — replacing bin/codex-setup.sh's `rules_reason="stale-plugin-path"`
#   assignment with "differs" reports the generic reason instead of naming the stale path.
case_codex_setup_check_stale_version() {
  local old_plugin new_plugin repo before after
  old_plugin="$(mk_cx_plugin cx-stale-plugin 2.9.0)"
  new_plugin="$(mk_cx_plugin cx-stale-plugin 3.0.0)"
  repo="$(mk_cx_repo cx-stale-repo)"
  run_cx "$old_plugin" "$repo"
  expect_rc 0

  before="$( (cd "$repo" && find .codex -type f | sort && find .codex -type f -exec cksum {} \; | sort) )"
  run_cx "$new_plugin" "$repo" --check
  expect_rc 1
  expect_cx_out "drift=.codex/rules/trail-blazer-flow.rules reason=stale-plugin-path"
  after="$( (cd "$repo" && find .codex -type f | sort && find .codex -type f -exec cksum {} \; | sort) )"
  [ "$before" = "$after" ] || { __ok=0; __why="${__why}--check modified .codex despite reporting drift only\n"; }

  run_cx "$new_plugin" "$repo"
  expect_rc 0
  expect_cx_out "wrote=.codex/rules/trail-blazer-flow.rules"
  run_cx "$new_plugin" "$repo" --check
  expect_rc 0
  expect_cx_out_absent "drift="
}

# codex-setup-whitespace-plugin-root — a plugin root containing a space (via mk_cx_plugin's
# ROOTDIR override): write mode rc 2 with nothing written; --check rc 1 with
# unsupported=plugin-root reason=whitespace.
case_codex_setup_whitespace_plugin_root() {
  local plugin repo
  plugin="$(mk_cx_plugin cx-ws-plugin 2.9.0 "plug ins")"
  repo="$(mk_cx_repo cx-ws-repo)"
  run_cx "$plugin" "$repo"
  expect_rc 2
  expect_no_file "$repo/.codex"
  run_cx "$plugin" "$repo" --check
  expect_rc 1
  expect_cx_out "unsupported=plugin-root reason=whitespace"
}

# codex-setup-whitespace-repo — a repo directory whose own path contains a space: write mode rc 2;
# --check rc 1 with unsupported=repo-path reason=whitespace.
# mutant:408-cx-whitespace-off — neutralising bin/codex-setup.sh's repo_top whitespace case-arm
#   pattern (its only guard, unlike plugin_root's own character-class backstop) lets it through.
case_codex_setup_whitespace_repo() {
  local plugin repo
  plugin="$(mk_cx_plugin cx-ws-repo-plugin 2.9.0)"
  local base="$tmpbase/cx ws repo"
  mkdir -p "$base/home"
  (
    cd "$base" &&
    git init -q &&
    git config user.name "doctor-tests" &&
    git config user.email "doctor-tests@example.invalid" &&
    git config commit.gpgsign false &&
    git symbolic-ref HEAD refs/heads/main &&
    git commit -q --allow-empty -m init
  ) >/dev/null
  printf '# CLAUDE.md\n' > "$base/CLAUDE.md"
  repo="$base"
  run_cx "$plugin" "$repo"
  expect_rc 2
  run_cx "$plugin" "$repo" --check
  expect_rc 1
  expect_cx_out "unsupported=repo-path reason=whitespace"
}

# codex-setup-unsupported-character — a plugin root containing '&' (via ROOTDIR): write mode rc 2
# with nothing written.
case_codex_setup_unsupported_character() {
  local plugin repo
  plugin="$(mk_cx_plugin cx-amp-plugin 2.9.0 "plug&ins")"
  repo="$(mk_cx_repo cx-amp-repo)"
  run_cx "$plugin" "$repo"
  expect_rc 2
  expect_no_file "$repo/.codex"
}

# codex-setup-usage — --help rc 0; an unrecognised flag rc 2; run outside a git repository (via
# GIT_CEILING_DIRECTORIES) rc 2.
case_codex_setup_usage() {
  local plugin repo
  plugin="$(mk_cx_plugin cx-usage-plugin 2.9.0)"
  repo="$(mk_cx_repo cx-usage-repo)"
  run_cx "$plugin" "$repo" --help
  expect_rc 0
  expect_cx_out "usage: codex-setup.sh"

  run_cx "$plugin" "$repo" --bogus
  expect_rc 2

  local nogit="$tmpbase/cx-usage-nogit"
  mkdir -p "$nogit/home"
  (cd "$nogit" && HOME="$nogit/home" GIT_CEILING_DIRECTORIES="$tmpbase" "$bash_bin" "$plugin/bin/codex-setup.sh") \
    >"$tmpbase/cx-nogit-out" 2>"$tmpbase/cx-nogit-err"
  cx_rc=$?
  cx_out="$(cat "$tmpbase/cx-nogit-out")"
  cx_err="$(cat "$tmpbase/cx-nogit-err")"
  doctor_out="OUT: $cx_out
ERR: $cx_err"
  doctor_rc=$cx_rc
  expect_rc 2
}

# --- codex doctor (#410) ----------------------------------------------------------------------
# bin/check-harness.sh --provider codex — a separate check set from the Claude branch above,
# sharing only the preamble (git remote/gh/jq/default-branch/labels/exec-bits/harness-version/
# CLAUDE.md/LESSONS.md), the baseline section, and (with a Codex-specific FAIL arm) the
# branch-protection section. Every fixture isolates CODEX_HOME (never a developer's real Codex
# install) the same way the rest of this suite isolates HOME/CLAUDE_CONFIG_DIR, and every case
# uses a stub `codex` (never the real binary, even when one is on the developer's PATH) so this
# suite can pin exact requests without depending on a live app-server.

# build_stub_codex DIR MODE VERSION_LINE — writes DIR/codex, a stub standing in for the real
# `codex` CLI. `--version` prints VERSION_LINE. `app-server` reads stdin lines (each appended
# verbatim to DIR/requests.log, the request-log pin), replies to an "initialize" line with an
# id-1 result, a remoteControl/status/changed notification, and a non-JSON line (tolerance pins),
# and to a "hooks/list" line depending on MODE: reply (cats DIR/hooks-list.json, built by
# mk_hooks_reply below), error (a JSON-RPC error object), or silent/hang (nothing at all). At
# EOF, every mode but hang exits 0; hang execs the REAL sleep (resolved via `command -v` at BUILD
# time, in this process's own PATH — never the fixture's restricted one) for 30s, standing in for
# an app-server that ignores stdin EOF, so the doctor's own kill fallback is what ends it.
build_stub_codex() {
  local dir="$1" mode="$2" version_line="$3" real_sleep
  real_sleep="$(command -v sleep)"
  cat > "$dir/codex" <<EOF
#!$bash_bin
case "\$1" in
  --version)
    printf '%s\n' "$version_line"
    exit 0
    ;;
  app-server)
    initialized_ok=false
    while IFS= read -r line; do
      printf '%s\n' "\$line" >> "$dir/requests.log"
      case "\$line" in
        *'"method":"initialize"'*)
          case "\$line" in
            *'"clientInfo"'*)
              initialized_ok=true
              printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
              printf '%s\n' '{"jsonrpc":"2.0","method":"remoteControl/status/changed","params":{}}'
              printf '%s\n' 'stub: not json'
              ;;
            *)
              printf '%s\n' '{"error":{"code":-32600,"message":"Invalid request: missing field \`clientInfo\`"},"id":1}'
              ;;
          esac
          ;;
        *'"method":"hooks/list"'*)
          if ! \$initialized_ok; then
            printf '%s\n' '{"error":{"code":-32600,"message":"Not initialized"},"id":2}'
          else
            case "$mode" in
              reply) cat "$dir/hooks-list.json" ;;
              error) printf '%s\n' '{"id":2,"error":{"code":-32601,"message":"stub: method not found"}}' ;;
              silent|hang) : ;;
            esac
          fi
          ;;
      esac
    done
    case "$mode" in
      hang) exec "$real_sleep" 30 ;;
      *) exit 0 ;;
    esac
    ;;
esac
EOF
  chmod +x "$dir/codex"
}

# build_stub_sleep_instant DIR — writes DIR/sleep, exiting 0 immediately regardless of its
# argument (the dev/planning-tests.sh build_stub_sleep precedent). Placed first on PATH for the
# hooks-no-reply/hooks-hang cases below, so the doctor's own CODEX_HOOKS_LIST_WAIT-bounded polling
# (and the stub app-server's own writer loop) burns no real wall-clock time; build_stub_codex's
# "hang" exec always resolves the REAL sleep at build time regardless of this stub's PATH position.
build_stub_sleep_instant() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/sleep" <<EOF
#!$bash_bin
exit 0
EOF
  chmod +x "$dir/sleep"
}

# mk_hooks_reply STUBDIR PLUGIN TOPLEVEL STATUS [JQ_EDIT] — writes STUBDIR/hooks-list.json: the
# id-2 hooks/list result the stub codex's "reply" mode serves, derived from THIS checkout's own
# hooks/hooks.json via jq (never hand-typed), one hooks/list "data" entry for TOPLEVEL (the probed
# reply shape — cwd/hooks/warnings/errors). Each plugin hook's command has
# "${CLAUDE_PLUGIN_ROOT}" replaced by PLUGIN (split/join, no regex needed) and carries
# source:"plugin", pluginId:"trail-blazer-flow@trail-blazer-flow", eventName:"preToolUse",
# enabled:true, isManaged:false, trustStatus:STATUS, and a key in the probed shape
# ("<pluginId>:hooks/hooks.json:pre_tool_use:<i>:0"). JQ_EDIT (default identity) is applied last,
# so a case can add/mutate entries (an extra user/project hook, a config error) without hand-
# building the whole envelope.
mk_hooks_reply() {
  local stubdir="$1" plugin="$2" toplevel="$3" status="$4" jqedit="${5:-.}"
  local hooks_json envelope
  hooks_json="$(jq -c --arg plugin "$plugin" --arg status "$status" '
    [ .hooks[][]?.hooks[]? ] as $entries
    | [ range(0; ($entries|length)) as $i
        | ($entries[$i].command | split("${CLAUDE_PLUGIN_ROOT}") | join($plugin)) as $cmd
        | { command: $cmd, source: "plugin", pluginId: "trail-blazer-flow@trail-blazer-flow",
            eventName: "preToolUse", enabled: true, isManaged: false, trustStatus: $status,
            key: ("trail-blazer-flow@trail-blazer-flow:hooks/hooks.json:pre_tool_use:" + ($i|tostring) + ":0") }
      ]
  ' "$root/hooks/hooks.json")"
  envelope="$(jq -nc --argjson hooks "$hooks_json" --arg cwd "$toplevel" \
    '{"jsonrpc":"2.0","id":2,"result":{"data":[{"cwd":$cwd,"hooks":$hooks,"warnings":[],"errors":[]}]}}')"
  printf '%s\n' "$envelope" | jq -c "$jqedit" > "$stubdir/hooks-list.json"
}

# mk_cx_doctor NAME [ROOTDIR] [REPONAME] — builds one #410 doctor fixture: a fake Codex
# plugin-cache install (mk_cx_plugin, version 3.0.0, at ROOTDIR when given — the whitespace-path
# cases pass one) with THIS checkout's own hooks/hooks.json copied alongside it, and a repo
# (mk_cx_repo, at REPONAME when given — default "NAME-repo") with a fake origin remote. Then
# installs the Codex compatibility layer for real via run_cx (write mode, never --check) so
# "codex setup: in sync" is the default PASS — skipped when ROOTDIR or REPONAME contains
# whitespace, since codex-setup.sh's own path validation would refuse before writing anything.
# Sets globals cx_plugin/cx_repo (mirroring run_cx's cx_out/cx_err/cx_rc idiom) and cx_top (the
# repo's git toplevel via `rev-parse --show-toplevel`, since $tmpbase itself isn't -P-resolved).
cx_plugin=""
cx_repo=""
cx_top=""
mk_cx_doctor() {
  local name="$1" rootdir="${2:-plugins}" reponame="${3:-}"
  [ -n "$reponame" ] || reponame="$name-repo"
  cx_plugin="$(mk_cx_plugin "$name-plugin" 3.0.0 "$rootdir")"
  mkdir -p "$cx_plugin/hooks"
  cp "$root/hooks/hooks.json" "$cx_plugin/hooks/hooks.json"
  cx_repo="$(mk_cx_repo "$reponame")"
  (cd "$cx_repo" && git remote add origin https://example.invalid/acme/demo.git) >/dev/null
  case "$rootdir$reponame" in
    *[[:space:]]*) : ;;
    *) run_cx "$cx_plugin" "$cx_repo" ;;
  esac
  cx_top="$(cd "$cx_repo" && git rev-parse --show-toplevel)"
}

# mk_farm DIR [EXCLUDE…] — symlinks a fixed, closed tool list into DIR (each resolved with
# `command -v` in THIS process's own PATH; only an absolute result is linked; any EXCLUDE name is
# skipped) so a fixture's PATH can be exactly this farm with no fallback to the real PATH — the
# only way to guarantee a tool the case means to test as ABSENT (codex, jq, or git) truly isn't
# reachable, even on a developer machine that has a real one installed. `codex` is never in this
# list, under any circumstance. Prints DIR.
mk_farm() {
  local dir="$1"
  shift
  local excl=" $* "
  mkdir -p "$dir"
  local tools="awk basename bash cat chmod cmp cp cut date dirname env find grep head jq ln ls mkdir mktemp mv ps rm sed sleep sort tail tr uname wc git"
  local t p
  for t in $tools; do
    case "$excl" in
      *" $t "*) continue ;;
    esac
    p="$(command -v "$t" 2>/dev/null)" || continue
    case "$p" in
      /*) ln -s "$p" "$dir/$t" ;;
    esac
  done
  printf '%s' "$dir"
}

# run_doctor_at PLUGIN REPO PATHVAL ARGS… — same never-a-command-substitution idiom as run_doctor,
# running PLUGIN/bin/check-harness.sh with cwd = REPO, PATH = PATHVAL (no fallback to the real
# PATH unless a caller appends ":$PATH" itself), and HOME/XDG_CONFIG_HOME/CLAUDE_CONFIG_DIR/
# CODEX_HOME all pointed into REPO (so neither a developer's real global git config, Claude
# settings, nor Codex state can ever leak into a verdict) plus GIT_CONFIG_NOSYSTEM=1. Leaves
# $doctor_out/$doctor_rc set, so the existing expect/expect_absent/expect_rc helpers apply
# unchanged.
run_doctor_at() {
  local plugin="$1" repo="$2" pathval="$3"
  shift 3
  doctor_out="$(cd "$repo" && HOME="$repo/home" XDG_CONFIG_HOME="$repo/home/.config" CLAUDE_CONFIG_DIR="$repo/claudecfg" CODEX_HOME="$repo/home/.codex" GIT_CONFIG_NOSYSTEM=1 PATH="$pathval" "$bash_bin" "$plugin/bin/check-harness.sh" "$@" 2>&1)"
  doctor_rc=$?
}

# codex-doctor-healthy — every #410 check PASSes: version, paths, setup, hook trust, manual
# merge, and (via the shared healthy stub_gh_dir) branch protection; every Claude-only line is
# absent; and the stub's own request log pins the three-request, notification/non-JSON-tolerant
# exchange contract.
# mutant:410-provider-wrapper — turning the `if [ "$provider" = claude ]` wrapper into `if true`
#   re-enables every Claude-only check on Codex too, so this case's expect_absent assertions
#   (settings.json, merge autonomy:, autonomy mode:, governance paths:, test-suite ratchet) fail.
# mutant:410-init-clientinfo — dropping clientInfo from the initialize request (#410 kickback
#   finding 1) makes the stub reject it and answer hooks/list with "Not initialized" instead of
#   the trust reply, so this case's "every hook Codex loads for this repo is trusted" PASS and
#   rc 0 both fail.
case_codex_doctor_healthy() {
  mk_cx_doctor cx-doctor-healthy
  local cxstub="$tmpbase/cx-doctor-healthy-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect_rc 0
  expect "codex version: 0.157.1"
  expect "codex plugin paths:"
  expect "codex setup: in sync"
  expect "hook trust: every hook Codex loads for this repo is trusted"
  expect "merge: manual on Codex"
  expect "branch protection enabled on main"
  expect_absent "settings.json"
  expect_absent "merge autonomy:"
  expect_absent "autonomy mode:"
  expect_absent "governance paths:"
  expect_absent "test-suite ratchet"
  local reqlog="$cxstub/requests.log" reqcount methods cwd3 clientname
  reqcount="$(grep -c . "$reqlog" 2>/dev/null)"
  [ "$reqcount" = "3" ] || { __ok=0; __why="${__why}requests.log: expected 3 lines, got $reqcount\n"; }
  methods="$(jq -r '.method' "$reqlog" 2>/dev/null | tr '\n' ',')"
  [ "$methods" = "initialize,initialized,hooks/list," ] || { __ok=0; __why="${__why}requests.log methods: $methods\n"; }
  # #410 kickback finding 1: a real codex app-server rejects initialize outright without
  # params.clientInfo, so this must never regress silently.
  clientname="$(sed -n '1p' "$reqlog" | jq -r '.params.clientInfo.name' 2>/dev/null)"
  [ "$clientname" = "check-harness" ] || { __ok=0; __why="${__why}requests.log line 1 clientInfo.name: $clientname (want check-harness)\n"; }
  cwd3="$(sed -n '3p' "$reqlog" | jq -c '.params.cwds' 2>/dev/null)"
  [ "$cwd3" = "[\"$cx_top\"]" ] || { __ok=0; __why="${__why}requests.log line 3 cwds: $cwd3 (want [\"$cx_top\"])\n"; }
}

# codex-doctor-version-floor — exactly at CODEX_MIN_VERSION -> PASS.
# mutant:410-version-inclusive — loosening the final component compare from -ge to -gt makes an
#   exact-floor version FAIL instead of PASS.
case_codex_doctor_version_floor() {
  mk_cx_doctor cx-doctor-version-floor
  local cxstub="$tmpbase/cx-doctor-version-floor-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.156.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "codex version: 0.156.1"
  expect_rc 0
}

# codex-doctor-version-below — one patch under the floor -> FAIL naming the floor.
case_codex_doctor_version_below() {
  mk_cx_doctor cx-doctor-version-below
  local cxstub="$tmpbase/cx-doctor-version-below-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.156.0"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "codex version: 0.156.0 is below the supported floor 0.156.1"
  expect_rc 1
}

# codex-doctor-version-lexical — 0.99.9 is lexically ABOVE 0.156.1 ('9' > '1') but numerically
# below -> FAIL, proving the compare is numeric, not a string compare.
# mutant:410-version-numeric — a string compare would read 0.99.9 as >= 0.156.1 and PASS.
case_codex_doctor_version_lexical() {
  mk_cx_doctor cx-doctor-version-lexical
  local cxstub="$tmpbase/cx-doctor-version-lexical-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.99.9"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "codex version: 0.99.9 is below the supported floor 0.156.1"
  expect_rc 1
}

# codex-doctor-version-unparseable — no X.Y.Z triple anywhere on the first line -> FAIL naming
# the parse failure, not a version.
case_codex_doctor_version_unparseable() {
  mk_cx_doctor cx-doctor-version-unparseable
  local cxstub="$tmpbase/cx-doctor-version-unparseable-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli dev"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "codex version: could not parse"
  expect_rc 1
}

# codex-doctor-version-missing — a closed farm with no codex anywhere on PATH -> FAIL codex not
# installed, and hook trust can't even try.
case_codex_doctor_version_missing() {
  mk_cx_doctor cx-doctor-version-missing
  local farm; farm="$(mk_farm "$tmpbase/cx-doctor-version-missing-farm")"
  run_doctor_at "$cx_plugin" "$cx_repo" "$stub_gh_dir:$farm" --provider codex
  expect "FAIL  codex version: codex not installed"
  expect "FAIL  hook trust: could not check"
  expect_rc 1
}

# codex-doctor-paths-plugin-space — a plugin root containing a space -> FAIL naming the plugin
# root, and codex-setup.sh's own --check (run from that same unsupported path) relays
# unsupported=plugin-root, proving the doctor's own path check and codex-setup.sh's agree.
# mutant:410-paths-whitespace — making cx_has_ws's single shared whitespace-detecting case arm
#   unmatchable breaks detection for BOTH this case and codex-doctor-paths-repo-space, since both
#   calls go through the one function.
case_codex_doctor_paths_plugin_space() {
  mk_cx_doctor cx-doctor-paths-plugin-space "plug ins"
  local cxstub="$tmpbase/cx-doctor-paths-plugin-space-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "FAIL  codex plugin paths: the plugin root contains whitespace"
  expect "unsupported=plugin-root"
  expect_rc 1
}

# codex-doctor-paths-repo-space — a repo directory whose own path contains a space -> FAIL naming
# the repo path.
case_codex_doctor_paths_repo_space() {
  mk_cx_doctor cx-doctor-paths-repo-space "" "cx doctor repo space"
  local cxstub="$tmpbase/cx-doctor-paths-repo-space-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "FAIL  codex plugin paths: the repo path contains whitespace"
  expect_rc 1
}

# codex-doctor-setup-drift — a hand-edited installed file after setup -> FAIL naming the exact
# drift= line codex-setup.sh --check reports.
# mutant:410-setup-drift-pass — turning the rc-1 arm's `bad` into `ok` reports drift as a PASS.
case_codex_doctor_setup_drift() {
  mk_cx_doctor cx-doctor-setup-drift
  printf '\n# drift\n' >> "$cx_repo/.codex/agents/planner.toml"
  local cxstub="$tmpbase/cx-doctor-setup-drift-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "codex setup: out of sync"
  expect "drift=.codex/agents/planner.toml"
  expect_rc 1
}

# codex-doctor-setup-script-missing — the fixture's own bin/codex-setup.sh deleted -> FAIL "could
# not check", never a crash, never a false PASS.
case_codex_doctor_setup_script_missing() {
  mk_cx_doctor cx-doctor-setup-script-missing
  rm -f "$cx_plugin/bin/codex-setup.sh"
  local cxstub="$tmpbase/cx-doctor-setup-script-missing-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "FAIL  codex setup: could not check"
  expect_rc 1
}

# codex-doctor-hooks-untrusted — every plugin hook untrusted -> FAIL naming the plugin source and
# the untrusted status.
case_codex_doctor_hooks_untrusted() {
  mk_cx_doctor cx-doctor-hooks-untrusted
  local cxstub="$tmpbase/cx-doctor-hooks-untrusted-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" untrusted
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "hook(s) not trusted"
  expect "plugin:"
  expect "(untrusted)"
  expect_rc 1
}

# codex-doctor-hooks-modified — one plugin hook reports "modified" (Codex's own tamper signal,
# distinct from "untrusted") -> FAIL, proving the not-trusted test isn't narrowed to untrusted
# alone.
# mutant:410-trust-untrusted-only — narrowing the not-trusted test to trustStatus=="untrusted"
#   lets a "modified" plugin hook pass silently.
case_codex_doctor_hooks_modified() {
  mk_cx_doctor cx-doctor-hooks-modified
  local cxstub="$tmpbase/cx-doctor-hooks-modified-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted '.result.data[0].hooks[0].trustStatus="modified"'
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "hook(s) not trusted"
  expect "(modified)"
  expect_rc 1
}

# codex-doctor-hooks-tolerated — every plugin hook "managed" (not user-trustable, so it must PASS
# same as "trusted"), plus an extra disabled, untrusted, non-plugin ("user") hook, which must be
# ignored because it's disabled -> PASS, rc 0.
# mutant:410-trust-managed — no longer excluding "managed" from the not-trusted test flags every
#   managed plugin hook as untrusted.
# mutant:410-trust-enabled — dropping the enabled!=false guard from the not-trusted test flags the
#   disabled untrusted user hook too.
case_codex_doctor_hooks_tolerated() {
  mk_cx_doctor cx-doctor-hooks-tolerated
  local cxstub="$tmpbase/cx-doctor-hooks-tolerated-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" managed \
    '.result.data[0].hooks += [{"command":"user hook","source":"user","pluginId":null,"eventName":"preToolUse","enabled":false,"isManaged":false,"trustStatus":"untrusted","key":"user:extra:0"}]'
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "hook trust: every hook Codex loads for this repo is trusted"
  expect_rc 0
}

# codex-doctor-hooks-user-untrusted — every plugin hook trusted, plus an ENABLED, untrusted
# "user"-source hook -> FAIL naming the user source, proving the trust test isn't restricted to
# plugin hooks.
# mutant:410-trust-plugin-only — restricting the not-trusted test to source=="plugin" lets an
#   enabled untrusted user hook pass silently.
case_codex_doctor_hooks_user_untrusted() {
  mk_cx_doctor cx-doctor-hooks-user-untrusted
  local cxstub="$tmpbase/cx-doctor-hooks-user-untrusted-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted \
    '.result.data[0].hooks += [{"command":"user hook","source":"user","pluginId":null,"eventName":"preToolUse","enabled":true,"isManaged":false,"trustStatus":"untrusted","key":"user:extra:0"}]'
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "hook(s) not trusted"
  expect "user:"
  expect_rc 1
}

# codex-doctor-hooks-plugin-absent — the push-guard.sh entry deleted from the reply entirely, and
# agent-boundary.sh's entry present but enabled:false -> FAIL naming BOTH scripts as not loaded,
# distinguishing "absent" from "disabled" (both count as "not loaded").
# mutant:410-plugin-expected — neutralising the presence loop (over hooks/hooks.json's own
#   expected names) always reports every plugin hook as loaded, even when it plainly isn't.
case_codex_doctor_hooks_plugin_absent() {
  mk_cx_doctor cx-doctor-hooks-plugin-absent
  local cxstub="$tmpbase/cx-doctor-hooks-plugin-absent-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted \
    '.result.data[0].hooks |= ([.[] | select((.command | contains("push-guard.sh")) | not)] | map(if (.command | contains("agent-boundary.sh")) then .enabled=false else . end))'
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "hook trust: plugin hook(s) not loaded by Codex:"
  expect "push-guard.sh"
  expect "agent-boundary.sh"
  expect_rc 1
}

# codex-doctor-hooks-no-reply — "silent" mode (app-server never answers hooks/list) with the
# instant sleep stub first on PATH -> FAIL "no hooks/list reply", fast (no real wall-clock wait).
# mutant:410-no-reply-pass — turning the no-reply arm's `bad` into `ok` reports silence as trust,
#   killing both this case and codex-doctor-hooks-hang.
case_codex_doctor_hooks_no_reply() {
  mk_cx_doctor cx-doctor-hooks-no-reply
  local cxstub="$tmpbase/cx-doctor-hooks-no-reply-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" silent "codex-cli 0.157.1"
  local sleepstub="$tmpbase/cx-doctor-hooks-no-reply-sleep"
  build_stub_sleep_instant "$sleepstub"
  run_doctor_at "$cx_plugin" "$cx_repo" "$sleepstub:$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "hook trust: no hooks/list reply"
  expect_rc 1
}

# codex-doctor-hooks-hang — "hang" mode (app-server keeps running past stdin EOF) with the instant
# sleep stub first on PATH -> the SAME FAIL as silent mode, and the suite's own "== summary:"
# footer still prints, proving the doctor's kill fallback actually bounds the exchange rather than
# hanging the whole suite. Deliberately no mutant here: one would remove the kill and hang this
# suite for real, not just fail a case.
case_codex_doctor_hooks_hang() {
  mk_cx_doctor cx-doctor-hooks-hang
  local cxstub="$tmpbase/cx-doctor-hooks-hang-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" hang "codex-cli 0.157.1"
  local sleepstub="$tmpbase/cx-doctor-hooks-hang-sleep"
  build_stub_sleep_instant "$sleepstub"
  run_doctor_at "$cx_plugin" "$cx_repo" "$sleepstub:$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "hook trust: no hooks/list reply"
  expect_rc 1
}

# codex-doctor-hooks-rpc-error — codex app-server itself rejects hooks/list (a JSON-RPC error
# object) -> FAIL naming the rejection, distinct from a plain no-reply.
case_codex_doctor_hooks_rpc_error() {
  mk_cx_doctor cx-doctor-hooks-rpc-error
  local cxstub="$tmpbase/cx-doctor-hooks-rpc-error-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" error "codex-cli 0.157.1"
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "hook trust: codex app-server rejected hooks/list"
  expect_rc 1
}

# codex-doctor-hooks-config-errors — Codex itself reports a per-cwd configuration error (a
# malformed hooks.json, from Codex's point of view) -> FAIL distinct from a trust problem.
# mutant:410-config-errors — skipping the configuration-error check lets a reported error pass
#   through to the trust checks below unnoticed (and, since every hook here is otherwise trusted,
#   the case would wrongly PASS).
case_codex_doctor_hooks_config_errors() {
  mk_cx_doctor cx-doctor-hooks-config-errors
  local cxstub="$tmpbase/cx-doctor-hooks-config-errors-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted \
    '.result.data[0].errors=[{"message":"stub: bad hooks.json","path":"/x"}]'
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "hook trust: Codex reported hook configuration error(s)"
  expect_rc 1
}

# codex-doctor-hooks-json-missing (#410 kickback finding 4) — the plugin's own hooks/hooks.json
# deleted -> FAIL could not check, before the app-server exchange even starts (no requests.log at
# all would be wrong too, but this case only pins the verdict — codex-doctor-hooks-json-unparseable
# below is the sibling that also proves cx_expected, not just the file's readability, is what
# gates this).
# mutant:410-hooks-json-empty-guard — neutralising the empty-cx_expected gate lets both this case
#   and codex-doctor-hooks-json-unparseable fall through to cx_hooks_list with nothing to compare
#   against.
case_codex_doctor_hooks_json_missing() {
  mk_cx_doctor cx-doctor-hooks-json-missing
  rm -f "$cx_plugin/hooks/hooks.json"
  local cxstub="$tmpbase/cx-doctor-hooks-json-missing-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "FAIL  hook trust: could not check"
  expect_rc 1
}

# codex-doctor-hooks-json-unparseable (#410 kickback finding 4) — the plugin's own hooks.json
# replaced with invalid JSON -> the same FAIL as a missing file, proving the guard is "can jq
# derive at least one expected hook name", not merely "does the file exist".
case_codex_doctor_hooks_json_unparseable() {
  mk_cx_doctor cx-doctor-hooks-json-unparseable
  printf 'not valid json{{{\n' > "$cx_plugin/hooks/hooks.json"
  local cxstub="$tmpbase/cx-doctor-hooks-json-unparseable-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect "FAIL  hook trust: could not check"
  expect_rc 1
}

# codex-doctor-hooks-key-sanitize (#410 kickback finding 7) — an untrusted entry's key contains a
# space and a '$', both outside the doctor's own [A-Za-z0-9._:/@-] allow-set: the
# printed line must carry the '?'-substituted form and never the raw key (a literal '$' or space
# in a FAIL line is, at minimum, confusing to a shell that copy-pastes it; at worst, in a
# differently-quoted context, live).
# mutant:410-key-sanitize — dropping the gsub prints the raw, unsanitised key instead.
case_codex_doctor_hooks_key_sanitize() {
  mk_cx_doctor cx-doctor-hooks-key-sanitize
  local cxstub="$tmpbase/cx-doctor-hooks-key-sanitize-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted \
    '.result.data[0].hooks[0].trustStatus="untrusted" | .result.data[0].hooks[0].key="plugin key$value"'
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect 'plugin?key?value'
  expect_absent 'plugin key$value'
  expect_rc 1
}

# codex-doctor-manual-merge — CLAUDE.md declares both 'Merge autonomy policy' and 'Autonomy mode'
# (mode: autonomous) -> PASS naming both section titles as not applying on Codex, rc 0, and
# neither Claude-only verdict line (merge autonomy:, autonomy mode: autonomous) ever prints.
case_codex_doctor_manual_merge() {
  mk_cx_doctor cx-doctor-manual-merge
  cat >> "$cx_repo/CLAUDE.md" <<'EOF'

## Merge autonomy policy

The cycle may merge fixture PRs. (fixture stub policy)

## Autonomy mode
```
mode: autonomous
```
EOF
  local cxstub="$tmpbase/cx-doctor-manual-merge-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$PATH" --provider codex
  expect_rc 0
  expect "merge: manual on Codex"
  expect "'Merge autonomy policy'"
  expect "'Autonomy mode'"
  expect_absent "merge autonomy:"
  expect_absent "autonomy mode: autonomous"
}

# codex-doctor-protection-missing — the branch-protection endpoint call itself fails (no document
# at all) -> FAIL naming the branch, and rc 1 (a hard floor on Codex, unlike Claude's WARN).
# mutant:410-protection-fail — turning the Codex arm's `bad` into `wrn` demotes this back to a
#   WARN, so rc stays 0.
case_codex_doctor_protection_missing() {
  mk_cx_doctor cx-doctor-protection-missing
  local ghdir="$tmpbase/cx-doctor-protection-missing-gh"
  build_stub_gh "$ghdir" main "" fail
  local cxstub="$tmpbase/cx-doctor-protection-missing-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$ghdir:$PATH" --provider codex
  expect "no branch protection detected on main"
  expect_rc 1
}

# codex-doctor-protection-unknown — gh installed but never authenticates, so gh_ready is false and
# the default branch is never determined -> FAIL "could not check", never a silent skip (unlike
# Claude, where the whole section is simply skipped).
# mutant:410-protection-unknown — removing the added `elif [ "$provider" = codex ]` clause drops
#   this FAIL entirely, so the section prints nothing and rc goes back to 0.
case_codex_doctor_protection_unknown() {
  mk_cx_doctor cx-doctor-protection-unknown
  local ghdir="$tmpbase/cx-doctor-protection-unknown-gh"
  mkdir -p "$ghdir"
  cat > "$ghdir/gh" <<EOF
#!$bash_bin
exit 1
EOF
  chmod +x "$ghdir/gh"
  local cxstub="$tmpbase/cx-doctor-protection-unknown-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  mk_hooks_reply "$cxstub" "$cx_plugin" "$cx_top" trusted
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$ghdir:$PATH" --provider codex
  expect "branch protection: could not check"
  expect_rc 1
}

# codex-doctor-jq-missing — a closed farm with no jq, but the stub codex still first on PATH -> the
# Codex-specific hooks/planner-guard.sh clause on the jq FAIL, and hook trust can't even try.
case_codex_doctor_jq_missing() {
  mk_cx_doctor cx-doctor-jq-missing
  local cxstub="$tmpbase/cx-doctor-jq-missing-stub"
  mkdir -p "$cxstub"
  build_stub_codex "$cxstub" reply "codex-cli 0.157.1"
  local farm; farm="$(mk_farm "$tmpbase/cx-doctor-jq-missing-farm" jq)"
  run_doctor_at "$cx_plugin" "$cx_repo" "$cxstub:$stub_gh_dir:$farm" --provider codex
  expect "FAIL  jq not installed"
  expect "fail open without it"
  expect "FAIL  hook trust: could not check"
  expect_rc 1
}

# codex-doctor-git-missing — a closed farm with no git anywhere on PATH -> the doctor's Codex-only
# git precheck FAILs and exits before anything else runs.
case_codex_doctor_git_missing() {
  mk_cx_doctor cx-doctor-git-missing
  local farm; farm="$(mk_farm "$tmpbase/cx-doctor-git-missing-farm" git)"
  run_doctor_at "$cx_plugin" "$cx_repo" "$farm" --provider codex
  expect "git not installed"
  expect_rc 1
}

# codex-doctor-usage — run on a plain mk_repo fixture (plugin and repo are the same dir, since
# this is an argument-parsing pin, not a Codex-specific one): an unknown --provider value names
# the bad token and exits 2; an unrelated unknown flag exits 2; a bare --provider with no
# following value exits 2 naming the missing value (#410 kickback finding 6); --help exits 0
# naming --provider; and --provider claude still exits 0 with the unchanged Claude branch's
# output (no "codex version" line).
case_codex_doctor_usage() {
  local dir; dir="$(mk_repo cx-doctor-usage base verbatim)"
  run_doctor_at "$dir" "$dir" "$stub_gh_dir:$PATH" --provider bogus
  expect_rc 2
  expect "bogus"

  run_doctor_at "$dir" "$dir" "$stub_gh_dir:$PATH" --frobnicate
  expect_rc 2

  run_doctor_at "$dir" "$dir" "$stub_gh_dir:$PATH" --provider
  expect_rc 2
  expect "--provider needs a value"

  run_doctor_at "$dir" "$dir" "$stub_gh_dir:$PATH" --help
  expect_rc 0
  expect "--provider"

  run_doctor_at "$dir" "$dir" "$stub_gh_dir:$PATH" --provider claude
  expect_rc 0
  expect "settings.json permissions match"
  expect_absent "codex version"
}

# name|fn|desc
cases=(
  "settings-missing|case_settings_missing|settings block: file missing"
  "settings-unparseable|case_settings_unparseable|settings block: invalid JSON"
  "settings-parsed|case_settings_parsed|settings block: verbatim template (clean control)"
  "drift-missing-entries|case_drift_missing_entries|template-diff: one allow + one deny entry missing"
  "drift-merge-deny-lifted|case_drift_merge_deny_lifted|template-diff: merge deny excluded from drift"
  "template-missing|case_template_missing|template-diff: fixture's own template deleted"
  "ratchet-never-executes|case_ratchet_never_executes|ratchet measurement command is looked up, never executed"
  "merge-allow-only|case_merge_allow_only|entry_has: merge rule in allow only"
  "merge-postdeploy|case_merge_postdeploy|post-merge verification sub-block: identical merge-autonomy verdict, declared command never executed, declared-state count correct across a fence-internal comment"
  "postdeploy-no-fence|case_postdeploy_no_fence|post-merge verification: heading present but no fenced commands -> WARN"
  "postdeploy-absent|case_postdeploy_absent|post-merge verification: no sub-heading at all -> informational PASS, not declared"
  "merge-ci-present|case_merge_ci_present|merge verdict: no-CI note absent when a workflow file exists"
  "ci-uses-tag-pinned|case_ci_uses_tag_pinned|CI action pinning: tag-pinned uses: ref under merge autonomy -> WARN naming file:ref"
  "ci-uses-sha-pinned|case_ci_uses_sha_pinned|CI action pinning: SHA-pinned uses: ref, commented-out unpinned line -> PASS, comment-stripping control"
  "ci-uses-no-merge-policy|case_ci_uses_no_merge_policy|CI action pinning: tag-pinned uses: ref with no Merge autonomy policy section -> no output at all"
  "ci-uses-composite-tag-pinned|case_ci_uses_composite_tag_pinned|CI action pinning: local composite action's tag-pinned uses: ref surfaced (#179 repro), local-to-local ref skipped"
  "ci-uses-composite-sha-pinned|case_ci_uses_composite_sha_pinned|CI action pinning: workflow + composite-action refs share one counter, commented-out uses: line inside action file excluded by the anchored extraction grep"
  "ci-uses-composite-nested|case_ci_uses_composite_nested|CI action pinning: action.yml two levels below .github/actions/ still scanned"
  "ci-uses-outside-actions-dir|case_ci_uses_outside_actions_dir|CI action pinning: local composite action outside .github/actions/ (#186 repro) surfaced, workflow's own ./… ref stays skipped"
  "ci-uses-unreferenced-action-yaml|case_ci_uses_unreferenced_action_yaml|CI action pinning: action.yaml with no .github/ directory and no workflow reference still scanned"
  "ci-uses-pruned-paths|case_ci_uses_pruned_paths|CI action pinning: .git/ and node_modules/ prunes exclude action.yml files by count and by absence"
  "ci-uses-workflow-named-action-yml|case_ci_uses_workflow_named_action_yml|CI action pinning: .github/workflows prune stops a workflow literally named action.yml from being double-counted"
  "merge-deny-only|case_merge_deny_only|entry_has: merge rule in deny only"
  "merge-deny-local-only|case_merge_deny_local_only|merge verdict: half-activated remediation names the file holding the deny (settings.local.json)"
  "merge-mention-only|case_merge_mention_only|entry_has: 'only' inside an unrelated JSON string"
  "guard-coverage-offbranch|case_guard_coverage_offbranch|default-branch guard coverage: WARN when the repo's default branch is one the template doesn't guard"
  "verify-path-grant-missing|case_verify_path_grant_missing|path-qualified verification interpreter with no literal-path grant -> WARN, reassuring PASS suppressed"
  "verify-path-grant-present|case_verify_path_grant_present|path-qualified verification interpreter with a literal-path grant -> PASS, Python toolchain WARN suppressed with no bare-name entry"
  "verify-path-grant-local-only|case_verify_path_grant_local_only|path-qualified verification interpreter: literal-path grant lives only in .claude/settings.local.json -> PASS, three-file union covers it"
  "verify-bare-command|case_verify_bare_command|control: bare-name-only verification command -> unchanged behaviour, neither new stem prints"
  "toolchain-grant-local-only|case_toolchain_grant_local_only|bare-name toolchain allow-list check: grant lives only in .claude/settings.local.json -> PASS, three-file union covers it"
  "toolchain-grant-absent|case_toolchain_grant_absent|bare-name toolchain allow-list check: non-vacuity control, no grant anywhere -> Python WARN, toolchain PASS absent"
  "record-complete|case_record_complete|check-decision-record.sh: every declared element present, rc 0"
  "record-missing-element|case_record_missing_element|check-decision-record.sh: one declared element missing, rc 1, named"
  "record-no-declaration|case_record_no_declaration|check-decision-record.sh: no 'Autonomy decision record' section, rc 2"
  "record-comment-preserved|case_record_comment_preserved|check-decision-record.sh: a '#' comment inside the fenced block does not truncate it, later elements still checked"
  "record-fenced-body|case_record_fenced_body|check-decision-record.sh: record lives only inside a fenced code block -> every heading FAILs as absent"
  "record-empty-element|case_record_empty_element|check-decision-record.sh: element heading present but no content under it -> FAIL, distinct message from heading-absent"
  "record-nested-content|case_record_nested_content|check-decision-record.sh: content under a deeper sub-heading counts toward the parent element's span -> PASS"
  "record-fenced-content|case_record_fenced_content|check-decision-record.sh: content inside a fenced block counts, and an in-fence '#' line is not read as a heading -> PASS"
  "record-no-space-heading|case_record_no_space_heading|check-decision-record.sh: no whitespace after the '#' run means no heading, matching claude_md_block/claude_md_section"
  "record-element-outside-section|case_record_element_outside_section|check-decision-record.sh: element heading found only outside the record section's span -> distinct FAIL, other elements still PASS"
  "record-element-sibling-depth|case_record_element_sibling_depth|check-decision-record.sh: element heading as a same-depth sibling of the record section -> not nested, same distinct FAIL"
  "record-tilde-fence|case_record_tilde_fence|check-decision-record.sh: whole record inside a '~~~' block -> every heading FAILs as absent"
  "record-nested-fence|case_record_nested_fence|check-decision-record.sh: whole record inside a four-backtick block flanked by unmatched inner three-backtick lines -> every heading FAILs as absent"
  "record-indented-fence|case_record_indented_fence|check-decision-record.sh: whole record inside a 2-space-indented fence -> every heading FAILs as absent"
  "record-fence-close-rules|case_record_fence_close_rules|control: an info-string run and a wrong-character run never close a fence early -> all three elements PASS"
  "scoped-declared|case_scoped_declared|scoped autonomy: declared PASS when both declarations and the grant label exist"
  "scoped-reserve-missing|case_scoped_reserve_missing|scoped autonomy: WARN when the reserve declaration is missing, rc still 0"
  "ratchet-fence-comment|case_ratchet_fence_comment|test-suite ratchet: fence-aware section slice + fence-delimiter-skip span hunt find the command past an in-fence comment"
  "postdeploy-grant-missing|case_postdeploy_grant_missing|post-merge verification: declared command with no matching allow entry -> WARN naming the entry to add"
  "postdeploy-grant-present|case_postdeploy_grant_present|post-merge verification: every declared command has a matching allow entry -> PASS, never executed"
  "postdeploy-grant-local-only|case_postdeploy_grant_local_only|post-merge verification: grant lives only in .claude/settings.local.json -> PASS, three-file union covers it"
  "postdeploy-grant-user-only|case_postdeploy_grant_user_only|post-merge verification: grant lives only in the user-level settings file -> PASS, three-file union covers it"
  "baseline-short-sha|case_baseline_short_sha|verification baseline: 7-hex-char recorded value that prefixes the remote tip -> recorded, not behind"
  "baseline-behind|case_baseline_behind|verification baseline: 7-hex-char recorded value that does NOT prefix the remote tip -> still behind"
  "baseline-too-short|case_baseline_too_short|verification baseline: recorded value under 7 hex characters -> malformed WARN, not recorded, not behind"
  "hooks-disabled|case_hooks_disabled|disableAllHooks: true in settings.local.json -> WARN naming the file, the guard-hook consequence, and the agent-boundary hook's silent-absence consequence"
  "stale-c-allows|case_stale_c_allows|legacy Bash(git -C * ...) allow entries still present -> WARN naming them and the guard hook that supersedes them"
  "version-report|case_version_report|harness version: bin/harness-version.sh's printed line reported verbatim as a PASS"
  "version-unresolvable|case_version_unresolvable|harness version: no .claude-plugin/plugin.json -> WARN, never FAIL"
  "version-cache-under-repo|case_version_cache_under_repo|harness-version.sh's .git-presence guard: a cache-shaped copy nested inside an enclosing repo prints '<version> -', never that repo's short sha (#262-2)"
  "version-plugin-root-checkout|case_version_plugin_root_checkout|non-vacuity control: the plugin root itself a checkout prints '<version> <that checkout's short sha>' (#262-2)"
  "protection-strict-true|case_protection_strict_true|branch protection (#234): healthy document -> strict PASS, both WARN stems absent, reviews configured"
  "protection-strict-false|case_protection_strict_false|branch protection (#234): strict false -> strict WARN, contexts WARN absent, reviews not configured"
  "protection-zero-contexts|case_protection_zero_contexts|branch protection (#234): zero required contexts -> contexts WARN, strict WARN absent"
  "protection-no-status-checks|case_protection_no_status_checks|branch protection (#234): required_status_checks key absent -> both WARN stems"
  "protection-no-policy|case_protection_no_policy|branch protection (#234): no Merge autonomy policy section -> neither WARN stem, today's PASS line unchanged"
  "protection-endpoint-fails|case_protection_endpoint_fails|branch protection (#234): protection endpoint call fails -> today's WARN only"
  "protection-no-claude-md|case_protection_no_claude_md|branch protection (#234): no CLAUDE.md at all -> set -u hoist proven by the summary footer still printing"
  "autonomy-mode-off|case_autonomy_mode_off|autonomy mode (#311): no 'Autonomy mode' section -> PASS off, no permissions.defaultMode line"
  "autonomy-mode-deny-in-place|case_autonomy_mode_deny_in_place|autonomy mode (#311): mode: autonomous with no Merge autonomy policy section and the deny still in place -> half-activated WARN and CI pinning WARN fire from the implied activation, post-merge verification stays silent"
  "autonomy-mode-active|case_autonomy_mode_active|autonomy mode (#311): mode: autonomous plus a lifted deny and allow entry -> merge autonomy: active"
  "autonomy-mode-protection|case_autonomy_mode_protection|autonomy mode (#311): mode: autonomous with no Merge autonomy policy section -> branch-protection gate still fires from the implied activation"
  "autonomy-mode-unfenced|case_autonomy_mode_unfenced|autonomy mode (#311): a bare mode: autonomous line outside the fenced block -> inert; only the first fence is read"
  "autonomy-mode-inert|case_autonomy_mode_inert|autonomy mode (#311): a section with no 'mode: autonomous' line -> inert WARN, none of the implied gates activate"
  "autonomy-mode-budget|case_autonomy_mode_budget|autonomy mode (#311): kickback-budget: 3 -> PASS names the declared budget"
  "autonomy-mode-budget-out-of-range|case_autonomy_mode_budget_out_of_range|autonomy mode (#311): kickback-budget: 9 -> WARN naming the bad value, default budget 2 applies"
  "autonomy-mode-default-mode|case_autonomy_mode_default_mode|autonomy mode (#311): permissions.defaultMode reported per settings file, sanitised to a bare word or '(unset)'/'(unrecognised value)'"
  "empty-needle-guard|case_empty_needle_guard|#262: expect/expect_absent both refuse an empty needle rather than degenerating into an unconditional match/never-match"
  "gov-none|case_gov_none|governance-paths.sh floor mode: no governance path changed -> verdict=none, empty stderr"
  "gov-builtin-rules|case_gov_builtin_rules|governance-paths.sh floor mode: every built-in alternative fires, three near-misses stay changed: -> verdict=hold"
  "gov-github-renamed|case_gov_github_renamed|governance-paths.sh floor mode: --no-renames prints both the old and new path of a rename regardless of diff.renames"
  "gov-case-varied-claude-dir|case_gov_case_varied_claude_dir|governance-paths.sh floor mode: .Claude/LESSONS.md is governance (case-insensitive built-in match) but not lessons-only (case-sensitive exact-set compare) -> hold"
  "gov-lessons-only|case_gov_lessons_only|governance-paths.sh floor mode: .claude/LESSONS.md alone (plus a non-governance path) -> verdict=lessons-only"
  "gov-lessons-plus-other|case_gov_lessons_plus_other|governance-paths.sh floor mode: a LESSONS.md append plus another governance path -> verdict=hold, not lessons-only"
  "gov-declared-globs|case_gov_declared_globs|governance-paths.sh floor mode: declared globs (fence-internal comment skipped) OR the built-in rule, both fire on the same PR -> verdict=hold"
  "gov-declared-from-base|case_gov_declared_from_base|governance-paths.sh floor mode: declared globs are read from the BASE tip's CLAUDE.md even after the head deletes the section"
  "gov-section-negation|case_gov_section_negation|governance-paths.sh floor mode: a '!'-prefixed declared line -> verdict=error, negation, no changed: line printed"
  "gov-section-no-fence|case_gov_section_no_fence|governance-paths.sh floor mode: a 'Governance paths' section with prose only -> verdict=error, no-fence"
  "gov-empty-diff|case_gov_empty_diff|governance-paths.sh floor mode: an empty diff (allow-empty head commit) -> verdict=error, not verdict=none"
  "gov-bad-args|case_gov_bad_args|governance-paths.sh floor mode: a --output= argument injection attempt -> rc 2, verdict=error, before any git call (no file written)"
  "gov-missing-object|case_gov_missing_object|governance-paths.sh floor mode: a well-formed but nonexistent head object -> verdict=error, quoting git diff's own failure"
  "gov-control-char-path|case_gov_control_char_path|governance-paths.sh floor mode: a changed path containing an embedded newline -> verdict=error, no changed: line printed (buffered output, forged-line guard)"
  "gov-sha256-arg|case_gov_sha256_arg|governance-paths.sh floor mode: a 64-hex base passes argument validation (rc 1, base not found), never the rc 2 usage error"
  "gov-diff-relative|case_gov_diff_relative|governance-paths.sh floor mode: run from a subdirectory with diff.relative=true still lists paths outside it (cd to the toplevel)"
  "gov-check-unreadable|case_gov_check_unreadable|governance-paths.sh --check on a missing file -> rc 2 with empty stdout, never 'absent'"
  "gov-base-no-claude-md|case_gov_base_no_claude_md|governance-paths.sh floor mode: no CLAUDE.md at all at the base tip -> not an error, built-in rules only, verdict=none"
  "gov-doctor-absent|case_gov_doctor_absent|governance-paths.sh --check via the doctor: no 'Governance paths' section -> PASS none declared"
  "gov-doctor-declared|case_gov_doctor_declared|governance-paths.sh --check via the doctor: a well-formed section with a fence-internal comment -> PASS 3 declared glob(s)"
  "gov-doctor-empty|case_gov_doctor_empty|governance-paths.sh --check via the doctor: a fenced block with no globs -> WARN malformed (no-globs), never FAIL"
  "gov-doctor-unterminated|case_gov_doctor_unterminated|governance-paths.sh --check via the doctor: an opening fence never closed -> WARN malformed (unterminated-fence), never FAIL"
  "gov-doctor-leading-slash|case_gov_doctor_leading_slash|governance-paths.sh --check via the doctor: a glob starting '/' -> WARN malformed (leading-slash), never FAIL"
  "gov-doctor-script-missing|case_gov_doctor_script_missing|governance-paths.sh --check via the doctor: the fixture's own bin/governance-paths.sh deleted -> WARN could not validate, never FAIL"
  "codex-setup-fresh|case_codex_setup_fresh|#408: no AGENTS.md: rc 0, all five files wrote=, no AGENTS.md created, config.toml carries the CLAUDE.md fallback, and the three next: lines including codex --no-daemon"
  "codex-setup-idempotent|case_codex_setup_idempotent|#408: a second run gives only unchanged= lines and byte-identical files; --check afterward is rc 0 with no drift="
  "codex-setup-agents-roundtrip|case_codex_setup_agents_roundtrip|#408: each agent TOML's name/description/developer_instructions round-trips against agents/*.md, byte-identical body, no tools/model lines"
  "codex-setup-agents-triple-quote-refused|case_codex_setup_agents_triple_quote_refused|#408: a ''' in planner.md's body: rc 2 naming planner.md, no .codex created"
  "codex-setup-agents-triple-quote-verifier|case_codex_setup_agents_triple_quote_verifier|#408 kickback: a ''' in verifier.md (the LAST role): rc 2 naming verifier.md, no .codex created — proves planner/implementer's already-generated TOMLs are never installed"
  "codex-setup-rules-content|case_codex_setup_rules_content|#408: every ADVISORY-Q1 allow line present; forbidden token-list set == templates/repo-settings.json's bare deny entries (jq-derived); no @PLUGIN_BIN@ literal remains"
  "codex-setup-rules-gated|case_codex_setup_rules_gated|#408: the gated .sh prefix_rule names and host_executable names both equal the ten listed scripts, each path <plugin>/bin/<s>, each name exists under bin/; codex-setup.sh/harness-version.sh/governance-paths.sh absent from both"
  "codex-setup-contract-agents-md|case_codex_setup_contract_agents_md|#408: a pre-existing AGENTS.md keeps its content, gains exactly one begin marker naming CLAUDE.md, no fallback key in config.toml, still one marker after a second run; --check before it pins reason=missing-pointer"
  "codex-setup-agents-md-malformed|case_codex_setup_agents_md_malformed|#408 kickback: non-exact or unpaired marker shapes (trailing text or CR on either or both markers, a prose mention of either marker, an unpaired begin) refuse (rc 2, byte-identical, tail content preserved, no .codex) and --check reports reason=malformed-pointer"
  "codex-setup-config-merge|case_codex_setup_config_merge|#408: a pre-existing config.toml with a top-level key plus a [profiles.x] table: the fallback key is inserted above the first table, both originals survive; --check before it pins reason=missing-fallback"
  "codex-setup-config-conflict|case_codex_setup_config_conflict|#408: a top-level project_doc_fallback_filenames not naming CLAUDE.md: write refuses (rc 2, unchanged, .codex/agents and .codex/rules absent); --check reports reason=fallback-conflict"
  "codex-setup-check-drift|case_codex_setup_check_drift|#408: --check on a fresh repo: rc 1, reason=missing per file, no .codex created; after setup, a hand-edited agent TOML gives reason=differs for exactly that file"
  "codex-setup-check-stale-version|case_codex_setup_check_stale_version|#408: rules generated from 2.9.0, then --checked from a 3.0.0 copy: reason=stale-plugin-path, proven to write nothing via a find-listing plus checksums; a write from 3.0.0 then --check is rc 0"
  "codex-setup-whitespace-plugin-root|case_codex_setup_whitespace_plugin_root|#408: a plugin root containing a space: write rc 2 nothing written; --check rc 1 unsupported=plugin-root reason=whitespace"
  "codex-setup-whitespace-repo|case_codex_setup_whitespace_repo|#408: a repo path containing a space: write rc 2; --check rc 1 unsupported=repo-path reason=whitespace"
  "codex-setup-unsupported-character|case_codex_setup_unsupported_character|#408: a plugin root containing '&': write rc 2, nothing written"
  "codex-setup-usage|case_codex_setup_usage|#408: --help rc 0; an unknown flag rc 2; run outside a git repository rc 2"
  "codex-doctor-healthy|case_codex_doctor_healthy|#410: --provider codex, healthy install: every check PASSes, every Claude-only line absent, requests.log pins the three-request exchange"
  "codex-doctor-version-floor|case_codex_doctor_version_floor|#410: codex version exactly at the floor (0.156.1) -> PASS"
  "codex-doctor-version-below|case_codex_doctor_version_below|#410: codex version one patch under the floor -> FAIL naming the floor"
  "codex-doctor-version-lexical|case_codex_doctor_version_lexical|#410: codex version 0.99.9 (lexically above the floor, numerically below) -> FAIL, proving the compare is numeric"
  "codex-doctor-version-unparseable|case_codex_doctor_version_unparseable|#410: codex --version prints no X.Y.Z triple -> FAIL could not parse"
  "codex-doctor-version-missing|case_codex_doctor_version_missing|#410: no codex anywhere on a closed PATH -> FAIL codex not installed, hook trust could not check"
  "codex-doctor-paths-plugin-space|case_codex_doctor_paths_plugin_space|#410: a plugin root containing a space -> FAIL naming the plugin root; codex-setup.sh --check relays unsupported=plugin-root"
  "codex-doctor-paths-repo-space|case_codex_doctor_paths_repo_space|#410: a repo path containing a space -> FAIL naming the repo path"
  "codex-doctor-setup-drift|case_codex_doctor_setup_drift|#410: a hand-edited installed file -> FAIL out of sync naming the drift= line"
  "codex-doctor-setup-script-missing|case_codex_doctor_setup_script_missing|#410: the fixture's own bin/codex-setup.sh deleted -> FAIL could not check"
  "codex-doctor-hooks-untrusted|case_codex_doctor_hooks_untrusted|#410: every plugin hook untrusted -> FAIL naming the plugin source and status"
  "codex-doctor-hooks-modified|case_codex_doctor_hooks_modified|#410: one plugin hook reports modified -> FAIL, not narrowed to untrusted alone"
  "codex-doctor-hooks-tolerated|case_codex_doctor_hooks_tolerated|#410: every plugin hook managed, plus a disabled untrusted user hook -> PASS, rc 0"
  "codex-doctor-hooks-user-untrusted|case_codex_doctor_hooks_user_untrusted|#410: every plugin hook trusted plus an enabled untrusted user hook -> FAIL naming the user source"
  "codex-doctor-hooks-plugin-absent|case_codex_doctor_hooks_plugin_absent|#410: one plugin hook entry missing, another present but disabled -> FAIL naming both scripts as not loaded"
  "codex-doctor-hooks-no-reply|case_codex_doctor_hooks_no_reply|#410: app-server never answers hooks/list -> FAIL no hooks/list reply (instant sleep stub, no real wait)"
  "codex-doctor-hooks-hang|case_codex_doctor_hooks_hang|#410: app-server ignores stdin EOF -> the same FAIL via the kill fallback, and the suite's own summary still prints"
  "codex-doctor-hooks-rpc-error|case_codex_doctor_hooks_rpc_error|#410: app-server rejects hooks/list with a JSON-RPC error -> FAIL naming the rejection"
  "codex-doctor-hooks-config-errors|case_codex_doctor_hooks_config_errors|#410: Codex reports a per-cwd hook configuration error -> FAIL distinct from a trust problem"
  "codex-doctor-hooks-json-missing|case_codex_doctor_hooks_json_missing|#410 kickback: the plugin's own hooks/hooks.json deleted -> FAIL could not check, before the app-server exchange starts"
  "codex-doctor-hooks-json-unparseable|case_codex_doctor_hooks_json_unparseable|#410 kickback: the plugin's own hooks.json replaced with invalid JSON -> the same FAIL as a missing file"
  "codex-doctor-hooks-key-sanitize|case_codex_doctor_hooks_key_sanitize|#410 kickback: an untrusted entry's key contains a space and a '\$' -> the printed line carries the '?'-substituted form, never the raw key"
  "codex-doctor-manual-merge|case_codex_doctor_manual_merge|#410: CLAUDE.md declares Merge autonomy policy and Autonomy mode -> PASS naming both as not applying on Codex; neither Claude-only verdict line prints"
  "codex-doctor-protection-missing|case_codex_doctor_protection_missing|#410: the branch-protection endpoint call fails -> FAIL (hard floor on Codex, unlike Claude's WARN)"
  "codex-doctor-protection-unknown|case_codex_doctor_protection_unknown|#410: gh never authenticates, default branch unknown -> FAIL could not check, never a silent skip"
  "codex-doctor-jq-missing|case_codex_doctor_jq_missing|#410: no jq anywhere on a closed PATH -> the Codex-specific hooks/planner-guard.sh clause on the jq FAIL, hook trust could not check"
  "codex-doctor-git-missing|case_codex_doctor_git_missing|#410: no git anywhere on a closed PATH -> the Codex-only git precheck FAILs and exits before anything else runs"
  "codex-doctor-usage|case_codex_doctor_usage|#410: --provider bogus and an unrelated unknown flag exit 2; --help exits 0 naming --provider; --provider claude is unchanged (no codex version line)"
)

matched=0
for row in "${cases[@]}"; do
  name="${row%%|*}"
  case "$name" in
    *"$filter"*) : ;;
    *) continue ;;
  esac
  matched=$((matched+1))
  rest="${row#*|}"
  fn="${rest%%|*}"
  desc="${rest#*|}"
  __ok=1; __why=""
  # mutant:383-fn-doctor — renames a cases=() row's target function in a scratch copy of this
  #   suite; this declare -F guard must report that row FAIL naming the missing function, instead
  #   of a silent PASS the row would otherwise get by falling through with $__ok unchanged.
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn"
  else
    __ok=0; __why="${__why}case function '$fn' is not defined (deleted or renamed?) — this row never ran\n"
  fi
  if [ "$__ok" -eq 1 ]; then
    case_ok "$name" "$desc"
  else
    case_bad "$name" "$desc"
    printf '%b' "$__why" | sed 's/^/    /'
    # #255 — bounded diagnostics: surface the doctor/check-decision-record script's own captured
    # output (never a full-consumption `head`) so a shell-level diagnostic (e.g. a broken-pipe
    # message) that leaked into $doctor_out isn't silently discarded.
    if [ -n "$doctor_out" ]; then
      printf '%s\n' "$doctor_out" | sed -n '1,40p' | sed 's/^/    | /'
    fi
  fi
done

if [ "$matched" -eq 0 ]; then
  echo "no case name contains '$filter'"
  exit 1
fi

echo
echo "== summary: $pass pass, $fail fail =="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
