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
jobs' seven commands failed — reproduce locally with `bash dev/selfcheck.sh`,
`bash dev/selfcheck-tests.sh`, `bash dev/doctor-tests.sh`, `bash dev/hook-tests.sh`,
`bash dev/cleanup-tests.sh`, `bash dev/planning-tests.sh`, and `bash dev/lock-tests.sh` (on a
Mac, prefix each with `PATH=/bin:$PATH` to match the macOS job's shell, e.g.
`PATH=/bin:$PATH bash dev/selfcheck.sh`).
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
excepted in both — not pinned to a full 40-hex commit SHA, (#233) the installed harness
version report — `bin/harness-version.sh`'s printed `<version> <sha>` line surfaced verbatim as a
PASS when resolvable, a WARN (never a FAIL) naming the expected fixed path when it isn't, and
(#234, review F4) the branch-protection document's up-to-date strictness — only when a "Merge
autonomy policy" section is declared and the protection endpoint call succeeds,
`required_status_checks.strict` (WARN when not exactly `true`), the required-status-check-context
count via `max(checks|length, contexts|length)` (WARN when zero, including when
`required_status_checks` itself is absent from the document), and required PR reviews
(informational PASS either way) — all three WARN-only, never FAIL, silent with no policy section,
and the doctor completing (its `== summary:` footer printing) on a repo with no CLAUDE.md at all,
proving the branch-protection section never reads its policy-activation flag while unset under
`set -u`) that would otherwise only be hand-verified, and (#262-2) `bin/harness-version.sh`'s own
`.git`-presence guard, run directly rather than through the doctor: a cache-shaped copy of the
script nested two directories inside an enclosing repo with a resolvable HEAD prints `<version> -`
and never that enclosing repo's short SHA, paired with a non-vacuity control whose plugin root is
itself the checkout (prints that checkout's own short SHA). It runs in CI as the third step, but it is not part of
`dev/selfcheck.sh` itself — run it by hand whenever `bin/check-harness.sh` or
`bin/check-decision-record.sh` changes.

`dev/hook-tests.sh` is a separate negative-test harness for ALL THREE of this repo's
plugin-shipped PreToolUse hooks. For `hooks/git-c-guard.sh` (#150) it feeds fixture stdin JSON
straight into the real script and pins its verdict — allow, or no opinion (empty stdout) — for
every conforming `git -C <worktree> <subcommand>` form and every rejection case (an injected
`-c`/`--exec-path`, the attached `-C<path>` form, a non-worktree path, an unknown subcommand,
command substitution, an unquoted shell metacharacter, an unterminated quote, the wrong tool,
malformed stdin, and `permission_mode: "plan"`), plus a booby-trapped `git`/`rm` on `PATH` proving
the guard never executes anything against the untrusted path it is validating. For
`hooks/agent-boundary.sh` (#235, the implementer/verifier git+gh boundary) it feeds fixture stdin
JSON carrying `agent_type` straight into that real script and pins its verdict — deny (exit 2,
empty stdout, one stderr line naming the role and the blocked command), or no opinion (exit 0,
empty stdout, empty stderr) — for the implementer role (denies any `git`/`gh`, in both the bare
and `trail-blazer-flow:`-namespaced `agent_type` spellings, across composite/quoted/prefixed
command forms), the verifier role (denies `gh` and every non-read-only `git` subcommand — an
unlisted subcommand, a global option before the subcommand, and a bare `git` all fail closed —
while its read-only git subcommands pass), every role-agnostic no-opinion edge (no
`agent_type` key, an unrecognised role, `permission_mode: "plan"`, the wrong tool, malformed
stdin, and `tool_input.command` absent), a CRLF-carrying command word on both roles (`git<CR>
push`/`gh<CR> …`, #270) and a CRLF-carrying subcommand (`git status<CR>`, denied pre-fix,
no-opinion post-fix), plus the same booby-trapped `git`/`rm`/`gh` idiom proving
this hook likewise executes nothing. For `hooks/push-guard.sh` (#260, the default-branch push
guard that governs every session, main session included — not scoped to the implementer/verifier
subagents) it feeds fixture stdin JSON straight into that real script and pins its verdict — deny
(exit 2, empty stdout, exactly one stderr line naming the blocked destination), or no opinion
(exit 0, empty stdout, empty stderr) — for every refspec spelling `git push origin main` and
`git push origin HEAD:main` bypass (a non-`origin` remote, a URL remote containing a colon, a
full `refs/heads/…:refs/heads/main` refspec, `:main`, `--delete main`, `--all`/`--mirror`, an
option before or after the remote/refspec, one and two chained `-o value` occurrences, one and two
chained `PREFIX_WORDS`/global-option occurrences, the `git -C <worktree> push origin main` form
`git-c-guard.sh` itself would allow, and the second `main`/`master` fallback member), the
default-branch symref read against a fixture repo (base, subdirectory, and worktree-pointer-file
`cwd` variants), the two harness-issued no-opinion shapes (`git push -u origin
"claude/<n>-<slug>"`, bare and `-C`), every role-agnostic no-opinion edge, a CRLF-carrying
destination and command word (`git push origin main<CR>`, trailing and interior, and `git<CR>
push origin main`, #270) and a CRLF-carrying non-default destination proving the strip does not
widen the deny set, and the same booby-trapped `git`/`gh`/`rm` idiom plus a
byte-identical-file-listing fixture proving this hook reads the filesystem but never writes to or
executes anything on it. It runs in CI as the fourth
step, but it is not part of `dev/selfcheck.sh` itself — run it by hand whenever
`hooks/git-c-guard.sh`, `hooks/agent-boundary.sh`, or `hooks/push-guard.sh` changes.

`dev/cleanup-tests.sh` is a separate negative-test harness for `bin/cleanup-after-merge.sh`: it
builds throwaway fixture git repos under `mktemp`, with a stub `gh` and stub `git` on `PATH`, and
runs the real script (and, for one deliberately `--json`-mutated copy, that copy — never `bin/`
itself) against them to pin the multi-PR `KEEP` behavior — a merged PR that is only
"Part of #n", an open sibling PR, the `multi-pr` label, or a maintainer
(`OWNER`/`MEMBER`/`COLLABORATOR`) comment carrying a `<!-- harness-multi-pr -->` marker must leave
the issue open and never call `gh issue close`; a marker from anyone else is ignored and produces
exactly one `WARN` naming the comment, and the issue-body marker is no longer honoured at all
(#231) — the ordinary close path, the `--ff-only` pull failure continuing instead of aborting, and
the pre-flight `gh repo view` / `git branch --show-current` / `gh pr list` lookup failures each
being reported (WARN) and survived rather than aborting the script before any output. Since #248,
the stub `gh` itself validates `--json` FIELD NAMES against gh's own live-probed field sets — two
constants, `GH_ISSUE_JSON_FIELDS` (shared by `issue list`/`issue view`, byte-identical to
`dev/planning-tests.sh`'s constant of the same name) and `GH_PR_JSON_FIELDS` (a different,
46-field set — `pr list` accepts fields, like `headRefName`, that the issue set does not) — wired
as the first statement of those three arms, so an unsupported field is rejected with gh's own
`Unknown JSON field: "<name>"` line on stderr and exit 1; the stub's `repo)` arm stays
deliberately unvalidated (a third, unprobed field set). Since #249, a failed or malformed
`gh issue view --json comments` (the multi-PR comment-marker lookup) no longer falls back to "no
marker found": the harness pins a `WARN` naming the failure route (a hard fetch failure or a
non-JSON response) and leaves the issue open with `pr-open` still attached, in both `--fix` and
report-only modes, and that the cheaper `multi-pr`-label KEEP signal still short-circuits before
this lookup is ever attempted. It runs in
CI as the fifth step, but it is not part of `dev/selfcheck.sh` itself — run it by hand whenever
`bin/cleanup-after-merge.sh` changes.

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
REST author-association lookup fails, the script retries it once after a single bounded backoff
(#246, mirroring #223's implementer-side re-run) before the run fails closed (every issue
untrusted, one warn line, `counts.author_association_unavailable: true`); a retry that succeeds
instead sets `counts.author_association_retried: true` and builds the map from the SECOND
attempt's output, with a distinct one-line warn — pinned in `dev/planning-tests.sh` with a
one-shot `reject-association-once` fixture marker, a stub `sleep` recorder
(`expect_sleep_calls`/`expect_sleep_arg`) that keeps the suite's wall clock free of the real 30s
wait, and fixtures at 0/1/2 failures plus a sleep-itself-fails case — plus, since
#182, a trusted comment containing `<!-- harness-audit -->` (a harness-authored audit/hygiene
record) or `<!-- verifier-verdict -->` (the orchestrator's own archive) never counts as feedback
either, so neither re-opens a plan for revision (`counts.audit_comments_skipped` /
`counts.verdict_archives_skipped`), while a forged marker from an untrusted author still lands in
`untrusted_comments`, never silently dropped. Since #275, a trusted comment that OPENS WITH
(first-line anchored, `startswith` — not the `contains` the feedback exclusion above still uses)
one of those same markers is ALSO excluded from the latest-plan computation itself, so a
maintainer-authored record that merely quotes the plan marker verbatim in its prose is never
mistaken for the plan (the live #245 shape); a plan comment that itself quotes a harness marker
in its own prose is unaffected and still becomes the latest plan (the anchoring is what prevents
the over-exclusion regression); gate assertion 4.41 pins that this one `$planC` expression is
spelled identically on both discovery scripts. Since #211 the same faithfulness applies to the
revision-candidates query itself: the stub applies `find-planning-work.sh`'s own `--jq
'.[].number'` argument with the real `jq` to a JSON page-array fixture and propagates jq's exit
status, so a candidates filter that cannot process the returned document aborts the run under the
script's `set -euo pipefail` instead of silently yielding an empty candidate list. Since #217 the
stub's `gh issue list`/`gh issue view` calls also validate their `--json` field list generically —
against gh's own documented field set for those two subcommands (identical in the probed gh
version) — rejecting an unsupported field with `Unknown JSON field: "<name>"` and exit 1, replacing
(and subsuming) the earlier hard-coded arms that special-cased only `authorAssociation`; a
discovery-script change asking `gh` for a field it does not support now turns this repo's own CI
red instead of the stub silently serving the fixture anyway. For
`bin/find-implementation-work.sh` (#176,
reusing the identical trust gate rather than forking it) it pins the implementer-side
plan-selection artifact: a plan-marker comment from an untrusted author is never selected as
`plan`; an untrusted post-plan comment never lands in `trusted_post_plan`; a trusted post-plan
comment containing `<!-- verifier-verdict -->` (the orchestrator's own archive) or, since #182,
`<!-- harness-audit -->` (a harness-authored audit/hygiene record) is excluded from
`trusted_post_plan` too (`counts.verdict_archives_skipped` / `counts.audit_comments_skipped`),
while a forged marker from an untrusted author still lands in `untrusted_post_plan`; a comment
missing `authorAssociation` entirely is fail-closed untrusted; and an issue with no trusted plan
comment yields `plan: null` but stays in `ready`. Since #275, the identical first-line-anchored
exclusion `find-planning-work.sh` gained also applies here, at BOTH the `$lastPlan` computation
and the `plan:` selection expression itself (proven by a fixture where the real plan and a
marker-quoting record share one `createdAt`, discriminating the two sites) — so a trusted record
that opens with a harness marker and quotes the plan marker in its prose is never selected as
`plan`, re-anchoring `trusted_post_plan`'s window to the real plan comment instead of the record;
an issue whose only marker-carrying trusted comment is such a record now reports `plan: null`
rather than binding to the record. It also pins that script's plan-binding approval
provenance (#174, the same script's `plan_selection` entry gains `approval`/`binding_line`): a
plan comment posted after the newest `plan-approved` labeling event is not covered
(`covers_plan: false`, `reason: "plan-after-approval"`); the newest of several relabel events
decides, not the first; equal plan/label timestamps still count as covered; an unreadable events
lookup — whether the endpoint call itself is rejected, or the returned document errors the
script's own `--jq` filter (#204) — fails closed (`covers_plan: null`); and `--issue <n>`
single-issue mode (used by the
implementer skill's fresh per-issue revalidation) returns the identical output shape for exactly
one issue — the fetch itself always happens regardless of the issue's labels, but since #229 the
resulting verdict depends on the issue's CURRENT label set (see below) — with an unknown flag or
non-numeric `<n>` exiting 2 — and,
since #198, that same `--issue <n>` mode also carries the `covered_by_approval` split (not just
`binding_line`), the artifact the implementer skill's pre-push re-check (step 2e) diffs to surface
a trusted comment that arrives after dispatch. Since #192 that same `plan_selection` entry's
`approval` also binds to the selected plan comment's edit state, checked only on the branch that
would otherwise conclude covered: the plan comment's REST `updated_at` postdating the newest
`plan-approved` labeling event is not covered (`covers_plan: false`, `reason:
"plan-edited-after-approval"`, `counts.plan_edited_after_approval`); an edit predating that label,
or an edit-timestamp tie, both stay covered; three distinct routes — a rejected comments-endpoint
call, a document the script's own filter cannot process, and an unparseable or missing comment id,
or an empty `updated_at` field — all fail closed identically (`covers_plan: null`, `reason:
"plan-edit-unreadable"`, `counts.plan_edit_unreadable`, with `approval.approved_at`/`approved_by`
still populated since the EVENTS lookup itself succeeded); and `--issue <n>` mode carries the new
reason too, not just batch mode. Since
#194 it additionally pins, on BOTH scripts: workstream A, a `has_harness_marker` boolean added to
each untrusted bucket entry (`untrusted_comments[].comments[]` / `untrusted_post_plan[]`) that
only ANNOTATES a forged `<!-- harness-audit -->`/`<!-- verifier-verdict -->` marker from an
untrusted author, never filters it out (`counts.untrusted_harness_markers`, gate assertion 4.29);
workstream B, `find-implementation-work.sh`'s `trusted_post_plan[].covered_by_approval`
(true/false/null against `approval.approved_at`, `counts.post_approval_comments` for the uncovered
total, `counts.trusted_post_plan` still the grand total); and workstream C, that the planner
skill's step-7 stalled-stage escalation — now posted as an issue comment opening with
`<!-- harness-audit -->` rather than kept summary-only — exercises the existing audit-marker
exclusion and does not re-open the plan for revision. Since #229 it additionally pins, on
`bin/find-implementation-work.sh` only, a pre-filter checked BEFORE the #174 events lookup and the
#192 plan-edit lookup: `plan-approved` absent from the issue's CURRENT `labels` (fetched on the
same `gh issue view` call both modes already make, tolerant of gh's real `{"name": "..."}` element
shape and fail-closed on a missing `labels` key or an empty array) sets `covers_plan: false`,
`reason: "approval-label-absent"`, `binding_line: null`, and `counts.approval_label_absent`, and —
the short-circuit this pins mechanically via a stub call-log line count, not merely inferred from
the final JSON — makes NEITHER the events lookup NOR the plan-edit lookup, so a withdrawn approval
costs zero further API calls (a positive-control fixture asserts a non-zero call count on a
covered path, so the zero-call assertions can't pass vacuously). This reason wins precedence over
`no-plan` — the human's withdrawal is the more actionable fact — but the separate "no
maintainer-authored plan comment" warn and `counts.no_trusted_plan` still fire too, so the
missing-plan fact is never hidden; `--issue <n>` mode carries the same pre-filter and short-circuit.
Since #213 it additionally pins, on `bin/find-implementation-work.sh` only, the additive
`approval.approved_at_history[]` array a merge floor now walks to accept a PR body written under
an earlier approval of the same plan: one real `plan-approved` labeling event yields one entry
agreeing with `approval`'s own top-level `approved_at`/`approved_by`/`binding_line`; three events
posted OUT OF ORDER in the fixture still resolve newest-first (entry `[0]` matches what the
existing newest-wins compare already picks); two byte-identical events dedupe to one entry; a
not-covered plan (`plan-after-approval`) still yields a non-empty history whose every entry's
`binding_line` is null; the events lookup being unreadable, evaluated alongside a healthy sibling
issue, yields `[]` for the unreadable issue only — pinning the same per-iteration reset the #229
pre-filter above also depends on; and `--issue <n>` mode carries the same field, same shape.
Since #230 it additionally pins, on `bin/find-implementation-work.sh` only, decision-comment
content binding: on the branch that would otherwise conclude a `trusted_post_plan` entry
`covered_by_approval: true` (after #229's label pre-filter and #192's plan-edit check both pass),
the script fetches that COVERED comment's own REST `updated_at` and compares it against
`approval.approved_at`, the same idiom #192 already uses for the plan comment — never for an
already-uncovered entry, and never on an already-uncovered issue. A covered comment edited
strictly after approval flips that entry `covered_by_approval: false` and adds a new field,
`covered_by_approval_reason: "decision-edited-after-approval"`, collapsing the issue-level verdict
the same way (`covers_plan: false`, `counts.decision_edited_after_approval`); an entry whose own
edit state cannot be established (no parseable comment id, a rejected lookup, a document the
script's own filter cannot process, or an empty `updated_at`) collapses the verdict to **unknown**
instead (`covers_plan: null`, `covered_by_approval_reason: "decision-edit-unreadable"`,
`counts.decision_edit_unreadable`), with edited beating unreadable when one issue has both;
`approval.approved_at`/`approved_by` stay populated in both new states. Coverage: edited-after vs.
edited-before vs. an inclusive edit-timestamp tie (three sides of the comparison and its boundary);
a `null` url vs. a non-digits comment id (discriminating the outer `#issuecomment-` presence gate
from the inner digits-only guard, same split #192's own pair pins for the plan comment); a
rejected lookup vs. a filter-error document vs. a missing `updated_at` (three routes converging on
one fail-closed state); edited-plus-unreadable on one issue (pins precedence); and
`expect_api_calls` proofs for zero/one/two covered comments (pins the placement discipline
mechanically — an uncovered comment, or an issue already uncovered for another reason, is never
looked up); plus `--issue <n>` mode carrying both new reasons. `dev/selfcheck.sh`'s assertion 4.34
pins only that `bin/find-implementation-work.sh` and `skills/issue-implementer/SKILL.md` spell
both new reason strings identically, the same fixed-string-agreement contract as 4.33 —
`skills/issue-cycle/SKILL.md` is excluded for the identical, already-documented reason (its
*Plan-binding provenance* bullet prints `approval.reason` verbatim and names no individual
reason).
It runs in CI as the sixth step, but it
is not part of `dev/selfcheck.sh` itself — run it by hand whenever `bin/find-planning-work.sh` or
`bin/find-implementation-work.sh` changes.

`dev/lock-tests.sh` is a separate negative-test harness for `bin/harness-lock.sh` (#232), the
single-flight lock that guards against two harness cycles running concurrently in one checkout.
It builds throwaway git repos (and, for the shared-lock case, a `git worktree add`-ed sibling)
under `mktemp`, with `CLAUDE_PID` set explicitly per fixture, and runs the real
`bin/harness-lock.sh` against them, pinning: a fresh `acquire` creates the six-file lock
(`run-id`, `pid`, `host`, `started-at`, `harness-version`, `checkout-path`) and prints
`run-id=<id>` as the last stdout line; a second `acquire` against a live, same-host holder (or
any different-host holder) refuses (exit 3) with the holder record; a same-host holder whose pid
is no longer alive is reclaimed (exit 0, one audit line first); a lock record with a missing or
non-digits `pid`/`host` file refuses rather than reclaiming, naming `release --force`; `release
<run-id>` removes the lock only on a matching id, `release --force` removes it regardless,
`release` with neither exits 2; `status` always exits 0; a worktree of the same checkout shares
one lock (`git rev-parse --git-common-dir`); and the recorded pid is `${CLAUDE_PID:-$PPID}` (the
Claude Code session process, since a Bash tool call's own `$PPID` dies before the next call —
see the script's own header for the measured rationale), including the fallback to `$PPID` when
`CLAUDE_PID` is unset or non-digits. It runs in CI as the seventh and last step, but it is not
part of `dev/selfcheck.sh` itself — run it by hand whenever `bin/harness-lock.sh` changes.

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
- **No writer piped into `grep`'s quiet mode** (a `-q`/`-c`/`-x` flag cluster containing `q`, or
  `--quiet`) in `bin/*.sh`, `dev/*.sh`, or `hooks/*.sh`: every script in these three directories
  runs `set -uo pipefail`, under which that early-exit reader can send its upstream writer
  SIGPIPE and turn a genuine match into a reported pipeline failure (#255 — proven live,
  `dev/selfcheck-tests.sh`'s own `run_case`, CI run 34268473009). Use a here-string for a
  variable-fed site, or a capture-then-test for a command-fed one, instead. Enforced mechanically
  (assertion 1.7) for exactly that shape, including scanning `dev/*.sh` (unlike 1.4/1.5/1.6, which
  are `bin/`/`hooks/`-only by design) — a different early-exit reader (`awk ... exit`, `| head -N`)
  is not caught by this assertion.
- **A fixture harness's `expect`-family helper must refuse an empty needle.** `grep -qF -- ""`
  (or `-cF`) matches every line unconditionally, so an empty needle silently makes `expect ""`
  always pass and `expect_absent ""` always fail regardless of what was captured (#262).
  `dev/doctor-tests.sh`, `dev/cleanup-tests.sh`, `dev/lock-tests.sh`, and `dev/planning-tests.sh`
  each guard every needle-taking helper with a `needle_required` check that fails the case
  instead; `dev/hook-tests.sh` needs no guard (its only substring test hand-types the literal
  inline, never through a needle-taking helper).
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
- **Fixture comment urls in `dev/planning-tests.sh` use GitHub's real shape**,
  `https://example.invalid/<issue>#issuecomment-<id>`, never the invented `...#c<n>` form —
  a future URL-parsing change could otherwise pass the whole fixture suite against a shape no
  real GitHub comment url has and fail closed on every live run (#220), with one deliberate,
  gate-required exception (the `impl-plan-comment-id-unparseable` fixture, documented in that
  file's header comment). Assertion 4.31 enforces this mechanically for the full-url literal
  values in that one file only; it does not check the id-allocation scheme (documented in the
  file's own header comment) or a bare `#c<n>` mention in prose.
