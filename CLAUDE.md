# CLAUDE.md — trail-blazer-flow (the harness itself)

This repo **is** the Claude Code plugin (the harness), not a project that consumes it. The
README is the canonical spec; this file governs work **on** the harness's own code, docs, and
scripts — not the contract this harness expects of a *consumer* repo's `CLAUDE.md` (see the
README's "The CLAUDE.md contract" for that).

## Setup

Nothing to install. Requires `bash` and `jq` on the PATH. `gh` is only needed if you're running
the harness's own `bin/*.sh` scripts against a live GitHub repo — it is not required for the
verification gate below.

## Verification

The authoritative gate is one command, run from the repo root:

```bash
bash dev/selfcheck.sh
```

It prints a `PASS`/`FAIL` line per assertion (grouped and labelled in its own output) and a
`== summary: N pass, M fail ==` footer, and exits 0 iff nothing failed. The same command runs in
CI on every pull request (`.github/workflows/selfcheck.yml`, two jobs — `selfcheck` on
`ubuntu-latest` and `selfcheck-macos` on `macos-latest`, which prepends `/bin` to `PATH` so the
same commands run under Apple's bash 3.2 instead of a newer bash); a red check means one of the
jobs' six commands failed — reproduce locally with `bash dev/selfcheck.sh`,
`bash dev/selfcheck-tests.sh`, `bash dev/doctor-tests.sh`, `bash dev/hook-tests.sh`,
`bash dev/cleanup-tests.sh`, and `bash dev/planning-tests.sh` (on a Mac, prefix each with
`PATH=/bin:$PATH` to match the macOS job's shell, e.g. `PATH=/bin:$PATH bash dev/selfcheck.sh`).
There is no test suite and no build step: this repo is Markdown instruction files, Bash scripts,
and JSON manifests. The gate prints what it checks — run it. A change the gate can't catch needs
a new assertion in the gate, not a waiver, subject to the machine-parsed-artifacts rule below.

`dev/selfcheck-tests.sh` is the gate's own negative-test harness — a separate script, not part
of the gate itself, that copies this repo to a throwaway temp directory, applies one documented
perturbation per case, and asserts the gate fails with exactly the expected assertion id(s). It
also runs in CI, as the second step in each job; run it by hand
(`bash dev/selfcheck-tests.sh`) whenever `dev/selfcheck.sh` changes, and add a case for any
assertion that parses structure out of a file, compares two extracted sets, or exercises script
behavior; fixed-string and numeric-threshold assertions may ship without one, listed in the
harness's exempt comment with a one-line reason each.

`dev/doctor-tests.sh` is a separate negative-test harness for the *consumer* doctor
(`bin/check-harness.sh`) and its scoped-autonomy companion script (`bin/check-decision-record.sh`)
— it builds throwaway fixture repos under `mktemp` and pins verdicts
(the settings.json block, template-diff, the ratchet's never-execute guarantee, merge-autonomy
activation, default-branch guard coverage, the post-merge-verification declaration state —
declared/no-fence/not-declared, fence-aware and depth-aware, and (when declared) whether each
declared command's first token has a matching allow entry across the three-file settings
allow-list union (`.claude/settings.json`, `.claude/settings.local.json`, and the user-level
settings file — a grant living in any one of them counts), a pure string comparison that WARNs
rather than fails — the bare-name toolchain allow-list check and a path-qualified verification
interpreter probe such as `<repo>/api/.venv/bin/python`, both checked against that same
three-file union (#175 — a grant living only in `.claude/settings.local.json` no longer produces
a spurious toolchain WARN), the test-suite ratchet's fence-aware section slice with a
fence-delimiter-skipping span hunt, the verification baseline's short-SHA-as-prefix compare, the
`disableAllHooks: true` WARN across the three settings files, the stale-legacy-`-C`-allow WARN on
`.claude/settings.json`, and (#175, gated on a "Merge autonomy policy" section, widened by #179
and #186) a WARN naming any `uses:` ref in a consumer's `.github/workflows/*.yml`/`*.yaml` and in
any `action.yml`/`action.yaml` anywhere in the repo — local (`./…`, `../…`) and `docker://` refs
excepted in both — not pinned to a full 40-hex commit SHA) that would otherwise only be
hand-verified. It runs in CI as the third step, but it is not part of
`dev/selfcheck.sh` itself — run it by hand whenever `bin/check-harness.sh` or
`bin/check-decision-record.sh` changes.

`dev/hook-tests.sh` is a separate negative-test harness for the plugin-shipped PreToolUse guard
hook (`hooks/git-c-guard.sh`, #150): it feeds fixture stdin JSON straight into the real script
and pins its verdict — allow, or no opinion (empty stdout) — for every conforming `git -C
<worktree> <subcommand>` form and every rejection case (an injected `-c`/`--exec-path`, the
attached `-C<path>` form, a non-worktree path, an unknown subcommand, command substitution, an
unquoted shell metacharacter, an unterminated quote, the wrong tool, malformed stdin, and
`permission_mode: "plan"`), plus a booby-trapped `git`/`rm` on `PATH` proving the guard never
executes anything against the untrusted path it is validating. It runs in CI as the fourth step,
but it is not part of `dev/selfcheck.sh` itself — run it by hand whenever
`hooks/git-c-guard.sh` changes.

`dev/cleanup-tests.sh` is a separate negative-test harness for `bin/cleanup-after-merge.sh`: it
builds throwaway fixture git repos under `mktemp`, with a stub `gh` and stub `git` on `PATH`, and
runs the real script against them to pin the multi-PR `KEEP` behavior (a merged PR that is only
"Part of #n", an open sibling PR, or a `<!-- harness-multi-pr -->` marker must leave the issue
open and never call `gh issue close`), the ordinary close path, the `--ff-only` pull failure
continuing instead of aborting, and the pre-flight `gh repo view` / `git branch --show-current` /
`gh pr list` lookup failures each being reported (WARN) and survived rather than aborting the
script before any output. It runs in CI as the fifth step, but it is not part of
`dev/selfcheck.sh` itself — run it by hand whenever `bin/cleanup-after-merge.sh` changes.

`dev/planning-tests.sh` is a separate negative-test harness for BOTH of this repo's discovery
scripts, `bin/find-planning-work.sh` (#164) and, since #176, `bin/find-implementation-work.sh`:
it builds throwaway fixture directories under `mktemp`, with a stub `gh` on `PATH`, and runs the
real script under test against them. For `bin/find-planning-work.sh` it pins the
trusted-association gate — only a comment whose `authorAssociation` is `OWNER`, `MEMBER`, or
`COLLABORATOR` ever puts its issue into `needs_revision` or is honoured as the latest plan
comment; a `CONTRIBUTOR`/`NONE` comment, or one with no `authorAssociation` field at all
(fail-closed), posted after the issue's latest trusted plan (or any such comment, if there is no
trusted plan yet) is reported in the `untrusted_comments` output bucket instead of being silently
dropped or silently trusted, and an untrusted marker comment never shadows real, trusted feedback
posted before it (one posted before that plan is dropped with no bucket entry) — plus, since
#176, the same trust gate applied to WHO OPENED the issue: a non-maintainer-authored issue is
still planned, but is reported in `untrusted_issue_authors` and never auto-approved, and if the
REST author-association lookup fails the whole run fails closed (every issue untrusted, one warn
line, `counts.author_association_unavailable: true`) — plus, since
#182, a trusted comment containing `<!-- harness-audit -->` (a harness-authored audit/hygiene
record) or `<!-- verifier-verdict -->` (the orchestrator's own archive) never counts as feedback
either, so neither re-opens a plan for revision (`counts.audit_comments_skipped` /
`counts.verdict_archives_skipped`), while a forged marker from an untrusted author still lands in
`untrusted_comments`, never silently dropped. Since #211 the same faithfulness applies to the
revision-candidates query itself: the stub applies `find-planning-work.sh`'s own `--jq
'.[].number'` argument with the real `jq` to a JSON page-array fixture and propagates jq's exit
status, so a candidates filter that cannot process the returned document aborts the run under the
script's `set -euo pipefail` instead of silently yielding an empty candidate list. For
`bin/find-implementation-work.sh` (#176,
reusing the identical trust gate rather than forking it) it pins the implementer-side
plan-selection artifact: a plan-marker comment from an untrusted author is never selected as
`plan`; an untrusted post-plan comment never lands in `trusted_post_plan`; a trusted post-plan
comment containing `<!-- verifier-verdict -->` (the orchestrator's own archive) or, since #182,
`<!-- harness-audit -->` (a harness-authored audit/hygiene record) is excluded from
`trusted_post_plan` too (`counts.verdict_archives_skipped` / `counts.audit_comments_skipped`),
while a forged marker from an untrusted author still lands in `untrusted_post_plan`; a comment
missing `authorAssociation` entirely is fail-closed untrusted; and an issue with no trusted plan
comment yields `plan: null` but stays in `ready`. It also pins that script's plan-binding approval
provenance (#174, the same script's `plan_selection` entry gains `approval`/`binding_line`): a
plan comment posted after the newest `plan-approved` labeling event is not covered
(`covers_plan: false`, `reason: "plan-after-approval"`); the newest of several relabel events
decides, not the first; equal plan/label timestamps still count as covered; an unreadable events
lookup — whether the endpoint call itself is rejected, or the returned document errors the
script's own `--jq` filter (#204) — fails closed (`covers_plan: null`); and `--issue <n>`
single-issue mode (used by the
implementer skill's fresh per-issue revalidation) returns the identical output shape for exactly
one issue regardless of its labels, with an unknown flag or non-numeric `<n>` exiting 2 — and,
since #198, that same `--issue <n>` mode also carries the `covered_by_approval` split (not just
`binding_line`), the artifact the implementer skill's pre-push re-check (step 2e) diffs to surface
a trusted comment that arrives after dispatch. Since
#194 it additionally pins, on BOTH scripts: workstream A, a `has_harness_marker` boolean added to
each untrusted bucket entry (`untrusted_comments[].comments[]` / `untrusted_post_plan[]`) that
only ANNOTATES a forged `<!-- harness-audit -->`/`<!-- verifier-verdict -->` marker from an
untrusted author, never filters it out (`counts.untrusted_harness_markers`, gate assertion 4.29);
workstream B, `find-implementation-work.sh`'s `trusted_post_plan[].covered_by_approval`
(true/false/null against `approval.approved_at`, `counts.post_approval_comments` for the uncovered
total, `counts.trusted_post_plan` still the grand total); and workstream C, that the planner
skill's step-7 stalled-stage escalation — now posted as an issue comment opening with
`<!-- harness-audit -->` rather than kept summary-only — exercises the existing audit-marker
exclusion and does not re-open the plan for revision. It runs in CI as the sixth and last step, but it
is not part of `dev/selfcheck.sh` itself — run it by hand whenever `bin/find-planning-work.sh` or
`bin/find-implementation-work.sh` changes.

This repo deliberately does **not** aim to pass `bin/check-harness.sh` — that script is the
*consumer* doctor; see the README's "Working on the harness itself" for why.

## Conventions

- **Plugin/consumer boundary**: nothing project-specific belongs in `agents/` or `skills/` —
  that content belongs in a *consumer* repo's `CLAUDE.md`/`LESSONS.md` instead. See the README's
  "Distribution".
- `bin/` is on consumers' Bash PATH; every `bin/*.sh` needs a matching allow entry in
  `templates/repo-settings.json` (the gate's bijection assertion checks this). Scripts meant
  only for developing this repo (not for consumers) go in `dev/` instead. `hooks/*.sh` is a
  third case: invoked by Claude Code itself (via `hooks/hooks.json`), never by the model issuing
  a Bash command, so a hook script takes no permission allow entry and stays out of the `bin/`
  bijection — see the README's "Safety model".
- **Gate assertions compare machine-parsed artifacts only.** An assertion may only compare two
  mechanically extracted artifacts (JSON↔JSON, script↔script, script↔JSON, filename↔frontmatter);
  no assertion may parse or pin English prose. Duplicated spec text is resolved by **deleting a
  copy**, never by pinning both — pinning makes the duplication load-bearing and permanent.
- **Follow-ups must name a user-visible failure.** A follow-up issue filed from a PR must name a
  concrete failure a user of this plugin would experience; a verifier's "Notes for the PR
  reviewer" is not a finding and does not become a follow-up by default.
- `*.sh` files are LF-only (enforced by `.gitattributes`) and must stay portable across BSD
  (macOS) and Git-Bash userlands — no GNU-only flags (`sed -i` without a suffix, `grep -P`,
  `readlink -f`, `mapfile`/`readarray`, `declare -A`). Enforced mechanically on `bin/*.sh`
  (assertion 1.4); `dev/*.sh` follows the same rule by convention, and is exercised under
  BSD/bash 3.2 by the `selfcheck-macos` CI job.
- The README is part of "done": every factual claim it makes about this repo's behavior must be
  checkable against the code (the verifier's Documentation changes check applies to docs).
- Every `uses:` step in `.github/workflows/` is pinned to a full 40-hex commit SHA, with the
  human-readable release tag in a trailing comment — a mutable tag ref would let the action's
  owner change what CI executes with no diff visible here, and this repo's CI is the gate's own
  merge condition. The SHA pin is enforced mechanically (assertion 4.24); the trailing tag
  comment is a review-level convention, not machine-checked. `.github/dependabot.yml` is the
  weekly bump mechanism for those pins; assertion 4.25 enforces mechanically only that the file
  is present and declares an uncommented `package-ecosystem: "github-actions"` update with an
  `interval:` line — not that Dependabot actually opens a PR, and not that a bump rewrites the
  trailing tag comment.
- Release ritual: bump `version` in `.claude-plugin/plugin.json` and create the matching
  `vX.Y.Z` annotated tag, in the same commit — see the README's "Updating".
