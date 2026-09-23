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
CI (`.github/workflows/selfcheck.yml`, two jobs running the same eight commands — `selfcheck` on
`ubuntu-latest`, the only required check on every pull request, and `selfcheck-macos` on
`macos-latest`, which prepends `/bin` to `PATH` so the same commands run under Apple's bash 3.2
instead of a newer bash, and which since #365 runs only post-merge on `main`, nightly, and on
manual dispatch — never on a pull request, because the maintainer's own local run already happens
under bash 3.2, so a BSD-only regression is caught on `main` within a day rather than holding
every merge for the ~12 minutes that job takes); a red check means one of the
jobs' eight commands failed — reproduce locally with `bash dev/selfcheck.sh`,
`bash dev/selfcheck-tests.sh`, `bash dev/doctor-tests.sh`, `bash dev/hook-tests.sh`,
`bash dev/cleanup-tests.sh`, `bash dev/planning-tests.sh`, `bash dev/lock-tests.sh`, and
`bash dev/stop-tests.sh` (on a
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
harness's exempt comment with a one-line reason each. Since #336, cases run concurrently by
default, in bounded waves: the job count is detected from the host's core count (clamped to at
most 16, falling back to 2 when no probe answers), overridable by `SELFCHECK_TESTS_JOBS=<n>` or
`-j <n>`, with `--serial` (`-j 1`) restoring one case at a time. Each case's result crosses back
to the parent through a result file written under the same one `mktemp -d` root, collected in the
cases' DECLARED order regardless of completion order — the PASS/FAIL line sequence, the totals,
and the exit status never depend on scheduling — and a case whose child dies before writing that
file is reported as a FAIL naming the case rather than silently dropped from the totals. The
single-case/filter form (`bash dev/selfcheck-tests.sh <case>`) is unchanged.

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

`dev/hook-tests.sh` is a separate negative-test harness for all four of this repo's
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
executes anything on it. Since #268, the same common dir's `config` file is also pinned: a bare
push and a named-remote push both denied via a configured `remote.<name>.push` refspec (the
issue's own `remote.origin.push = HEAD:main` shape, plus a 0/1/2+ boundary on two `push =` lines
under one remote, and a `key=value` assignment with no surrounding spaces), `push.default =
upstream`/`tracking` resolved through the current branch's recorded `merge` ref — including,
since a round-2 kickback, alongside a NON-denying `remote.<name>.push` record on the SAME remote,
pinning the RESOLVED union of routes (git's own precedence, consulting `push.default` only when
the applicable remote has no push refspec, is deliberately not modelled), and, since a round-3
kickback, a bare push denied via a denying `remote.<name>.push` record under a DIFFERENT
(non-`origin`) remote plus a benign `origin` section, pinning the RESOLVED union across EVERY
configured remote at n==0 (not just git's own default-remote pick) — `push.default = matching`
and a wildcard (`*`) configured destination each denied unconditionally as new documented
over-blocking classes, exact n==1 remote-name scoping in both directions (a different remote's
own route must not apply; the named remote's own route must), the harness's own explicit-refspec
push shape confirmed as a release-blocker no-opinion control even against a denying config,
current-branch scoping on `branch.<n>.merge`, `#`/`;` comment lines and irregular whitespace, a
CRLF-carrying config line (both a line-ending CR and, since the round-2 kickback, an interior
CR inside a refspec value), a config setting neither key at all, a worktree's config resolved from
the MAIN checkout rather than the pointer's own gitdir, a final config line with no trailing
newline, case-insensitive section/key names, and the same booby-trapped/byte-identical-listing
guarantee applied to the config route specifically. Since #269, a push segment's own `git -C
<path>` value is ALSO resolved, but only when it satisfies the same `PATH_ERE` predicate
`hooks/git-c-guard.sh` enforces — a byte-identical declaration in both hooks, mechanically pinned
by `dev/selfcheck.sh`'s assertion 4.42: the current-branch check, the `HEAD` refspec substitution,
and the default-branch deny-set member each denying via a resolved sibling worktree or a wholly
separate checkout, the resolved checkout's own config denying where the session has none, two
documented narrowings (a resolved segment no longer inherits the session's REPO-LOCAL `.git/config`
routes, and a bare push in a sibling worktree no longer denies merely because the session sits on its own
default branch), the predicate's boundaries (no `-wt-<n>` suffix, the attached `-C<path>` form,
0/1/2+ occurrences of `-C`), an unresolvable-but-shape-matching target degrading to the session's
own facts rather than clearing them, the session's own default branch staying in the deny-set
union for a resolved segment, and the same booby-trapped/byte-identical-listing guarantee applied
to BOTH the session repo and the resolved `-C` target. Since a round-2 kickback, that
booby-trapped-PATH guarantee additionally names `dirname`: an unresolvable-but-shape-matching `-C`
target's failed resolution never reaches `dirname`'s argv either, pinned specifically by a fixture
whose target does not resolve at depth 0 (the original never-executes fixture's own target does,
so it cannot discriminate this guard), and a two-push-segment command pins the per-segment reset
itself — the SECOND, `-C`-less segment stays judged by the SESSION's own facts (denying via the
session's own `remote.<name>.push` config), never by whatever the first segment's resolved `-C`
target left behind. Since #290, the same common-dir config read is extended to three GLOBAL
candidates — `$GIT_CONFIG_GLOBAL` (when set and non-empty), `$XDG_CONFIG_HOME/git/config` (or
its `$HOME/.config/git/config` default, when `$XDG_CONFIG_HOME` is unset or empty), and
`$HOME/.gitconfig` — unioned with the repo-local routes above and read identically for every
checkout resolved (session or a resolved `-C` target, since this class comes from the
environment, never the untrusted command string): one deny fixture per global candidate path,
the "none present"/loop-boundary fixture, a benign value in one file never masking a denying
value in another and the reverse (a denying global value still denying over a benign
repo-local one), two `push.default` lines inside ONE file also both evaluated rather than the
file's own last value winning, `$GIT_CONFIG_GLOBAL` unioned with (not replacing) the other two
global paths, the deny message's own two-literal source label (repo-local vs. global) — kept
intact even across a literal TAB byte embedded in a configured `remote.<name>.push` value,
since the record's source field is its own bounded first slot and the value its unbounded
tail, never the reverse — the harness's own explicit-refspec push shape reconfirmed as a
release-blocker no-opinion control against a denying GLOBAL config (bare and `-C`), a resolved
`-C` segment still seeing the global routes, and the same booby-trapped/byte-identical-listing
guarantee extended to the fixture `HOME` tree; `dev/hook-tests.sh`'s own `run_push_guard`
runner isolates `HOME`/`XDG_CONFIG_HOME`/`GIT_CONFIG_GLOBAL` for every push fixture (a neutral,
empty fixture `HOME` by default) so no fixture can read the developer's or CI runner's real
global git config.

For `hooks/claude-dir-guard.sh` (#327, the fourth `PreToolUse` hook, matching `Edit|Write` rather
than `Bash`) it feeds fixture stdin JSON straight into that real script and pins its verdict —
deny via the `.claude`-segment class, deny via the unclassifiable/fail-closed class (each exit 2,
empty stdout, exactly one stderr line, the two classes' wording distinct), or no opinion (exit 0,
empty stdout, empty stderr) — for the implementer/verifier role scope (reusing
`hooks/agent-boundary.sh`'s identical `agent_type` vocabulary, pinned script<->script by
`dev/selfcheck.sh`'s assertion 4.45) across both guarded tools and all four `agent_type` spellings,
a nested segment, a path entirely outside any repo checkout (deliberate location-independence — this
hook performs no filesystem access at all), a case-variant spelling, the Windows drive-letter and
backslash-spelled forms, `.claude` as the path's final segment, a CR-carrying spelling, the
relative-`.claude`-vs-relative-plain pair that discriminates the two deny classes, a `..`-carrying
path with and without a `.claude` segment, every no-opinion shape including two release-blocker
controls (the orchestrator's own main-session lesson append, and the verifier's transient
mutation-probe `Edit`), and the same booby-trapped `git`/`gh`/`rm`/`dirname`/`tr`/`awk`/`grep`/`sed`
`PATH` idiom plus a byte-identical fixture-tree listing proving this hook never executes or writes
anything, backed by its own 14-mutant measured mutation-proof table.

It runs in CI as the fourth
step, but it is not part of `dev/selfcheck.sh` itself — run it by hand whenever
`hooks/git-c-guard.sh`, `hooks/agent-boundary.sh`, `hooks/push-guard.sh`, or
`hooks/claude-dir-guard.sh` changes.

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
`dev/planning-tests.sh`'s and `dev/stop-tests.sh`'s constants of the same name) and
`GH_PR_JSON_FIELDS` (a different,
46-field set — `pr list` accepts fields, like `headRefName`, that the issue set does not) — wired
as the first statement of those three arms, so an unsupported field is rejected with gh's own
`Unknown JSON field: "<name>"` line on stderr and exit 1; the stub's `repo)` arm stays
deliberately unvalidated (a third, unprobed field set). Since #249, a failed or malformed
`gh issue view --json comments` (the multi-PR comment-marker lookup) no longer falls back to "no
marker found": the harness pins a `WARN` naming the failure route (a hard fetch failure or a
non-JSON response) and leaves the issue open with `pr-open` still attached, in both `--fix` and
report-only modes, and that the cheaper `multi-pr`-label KEEP signal still short-circuits before
this lookup is ever attempted. Since #334, the follow-up quarantine's idempotence key moved off
the `no-plan` label onto a trusted, PR-keyed `<!-- harness-orphan-notice: PR #<p> -->` marker read
from a per-candidate `gh issue view --json comments` lookup, the same trust gate and #249
fail-closed shape (WARN once, naming the failure route, leaving the issue exactly as found, in
both `--fix` and report-only modes) the multi-PR comment-marker lookup above already uses; the
candidate search itself drops its `-label:no-plan` exclusion (now `is:open is:issue -label:pr-open`,
`--json number,title,body,labels`), since a follow-up is born `no-plan` (#308) and would otherwise
never be a candidate. `build_stub_gh` gains an `is:open is:issue -label:pr-open`-matched `--search`
case serving a new `followups.json` fixture file (field-projected identically to the `--label
pr-open` arm, `[]` when absent so the thirty pre-#334 fixtures stay byte-identical) and an `issue
view` "ok"-mode override, `comments-<n>.json`, letting one fixture give two different follow-up
issues distinct comment state; sixteen new fixtures (30 → 46, the sixteenth — pinning the
`ascii_upcase` normalisation on the new path — added by #334 kickback K1) cover both modes, both
notice-lookup failure routes, the trust gate, the PR-number key boundary, the conditional
`--add-label no-plan`, and per-issue idempotence state, each with a measured mutation proof,
alongside the twelve pre-existing mutation proofs re-measured against the grown suite. Since
#355, the harness also pins that a failed write — `gh issue comment`/`gh issue edit`/`gh issue
close` — inside `--fix` is best-effort rather than fatal, exactly like every pre-flight lookup
already was: `build_stub_gh`'s `comment|edit|close` arm gains a `reject-$2-once`/`reject-$2`
marker-file pair (mirroring `dev/planning-tests.sh`'s `reject-X(-once)` one-shot-then-permanent
contract) that fails one write on demand, with `$2` literally `comment`/`edit`/`close`; thirteen
new fixtures (46 → 59) cover the per-arm skip-the-rest behaviour, the close-arm and
follow-up-arm write reorderings that put the write which keeps an issue re-examinable last, the
one summary WARN line printed only when a write failed this run, that the per-write WARN prints
only for a failed write (never for a successful one), and that report-only mode still
performs zero writes regardless of which reject markers are present, each with a measured
mutation proof, alongside all twenty-two pre-existing mutation proofs re-measured against the
grown registry. It runs in
CI as the fifth step, but it is not part of `dev/selfcheck.sh` itself — run it by hand whenever
`bin/cleanup-after-merge.sh` changes.

`dev/planning-tests.sh` is a separate negative-test harness for BOTH of this repo's discovery
scripts, `bin/find-planning-work.sh` (#164) and, since #176, `bin/find-implementation-work.sh`,
and, since #285, their consumer `bin/harness-status.sh` — end-to-end via Part 13's fixtures (both
discovery scripts run for real), and, since #297 (extended #333, #309, #353), via Part 14's
fixtures against `bin/harness-status.sh`'s own five `gh` call sites, plus (#353) its own stop check
(not a `gh` call site — one `bin/harness-stop.sh` invocation instead), behind a
`build_stub_discovery`-built canned stand-in for both discovery scripts (so, among the fixtures that invoke `run_status`, an
in-place mutant to either discovery script is reachable only through Part 13's own `run_status`
fixtures, never Part 14's — this file's many OTHER Parts, which call the discovery scripts
directly rather than through `run_status`, reach those same mutants too):
it builds throwaway fixture directories under `mktemp`, with a stub `gh` on `PATH`, and runs the
real script(s) under test against them. For `bin/find-planning-work.sh` it pins the
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
`untrusted_comments`, never silently dropped. Since #281 (superseding #275), the latest-plan
computation itself is restricted to trusted comments that OPEN WITH (first-line anchored,
`startswith` — not the `contains` the feedback exclusion above still uses) the plan marker itself,
positively, so neither a harness-authored record nor a record whose harness marker is preceded by
prose but which quotes the plan marker mid-body (the residual gap #275 left open) is ever mistaken
for the plan (the live #245 shape, generalised); a plan comment that itself quotes a harness marker
in its own prose is unaffected and still becomes the latest plan (the anchoring is what prevents
the over-exclusion regression); gate assertion 4.41 pins that this one `$planC` expression is
spelled identically on both discovery scripts. Since #302, a trusted comment posted after the
latest plan (or, when there is none, at any time) whose body contains the plan marker somewhere
other than its first line — dropped from both plan selection and feedback/binding context by the
rules above, previously with no diagnostic — is now named on stderr (`warn:` naming its author,
createdAt, and url) and counted in a new, additive `counts.plan_marker_quoters` key on both
scripts, spelled byte-identically (no `startswith`, no reference to `$planC`) and excluding
harness records exactly as the feedback/binding sets already exclude them. Since #321, both
scripts additionally warn on the twin class #302 left unwarned: a trusted, in-window comment whose
body contains any marker in a new shared declaration, `HARNESS_RECORD_MARKERS` (one marker per
line, built from the `$AUDIT_MARKER`/`$VERDICT_MARKER` constants, joined since #309 by a third,
`$ESCALATION_MARKER`), but does not open with
one — a maintainer quoting a harness-authored record, not a record itself — named on stderr and
counted in a new, additive `counts.harness_marker_quoters` key, disjoint from
`counts.plan_marker_quoters` (a comment quoting both markers is counted in exactly one); gate
assertion 4.46 pins that the two scripts' `HARNESS_RECORD_MARKERS` declarations are spelled
identically. Since #309, a durable-escalation record (opening with `<!-- harness-escalation -->`,
distinct from the planner's own colon-suffixed `<!-- harness-escalation: bucket=... stage=... -->`
key) or a comment quoting it is excluded from feedback/`trusted_post_plan` the identical way, via a
new, additive `counts.escalation_records_skipped` key (the same contains/`createdAt > $lastPlan`
shape `counts.audit_comments_skipped`/`counts.verdict_archives_skipped` already use); the label
that dedupes the resulting `needs-human` escalation across discovery passes is named
`ESCALATION_LABEL`, and gate assertion 4.48 pins that it is declared identically (one line each)
across all three of `bin/find-planning-work.sh`, `bin/find-implementation-work.sh`, and
`bin/harness-status.sh`, is one of the labels `bin/setup-labels.sh` creates, is excluded by every
discovery `--search` line, and is named in `skills/issue-implementer/SKILL.md`. Since #211 the same faithfulness applies to the
revision-candidates query itself: the stub applies `find-planning-work.sh`'s own `--jq
'.[].number'` argument with the real `jq` to a JSON page-array fixture and propagates jq's exit
status, so a candidates filter that cannot process the returned document fails the call the same
way a rejected `gh issue list` invocation does (see #272/#273 immediately below) — retried once,
then (#273) reported as an empty candidate list rather than a silently different one, never a
`set -euo pipefail` abort. Since #272/#273, `find-planning-work.sh`'s other three `gh` calls get
the identical one-retry-then-fail-closed shape #246 already gave the REST author-association
lookup: the `needs_initial_plan` query and the revision-candidates query each retry once after the
same guarded 30s backoff, then — instead of the bare command-substitution assignments that used to
let one transient failure abort the whole run before any stdout was produced — fail closed to an
empty bucket with a dedicated `counts` flag (`initial_query_unavailable` /
`candidates_query_unavailable`) and a warn line on stderr, while the run continues and still exits
0 with whatever half succeeded; the per-candidate `gh issue view` inside the revision loop gets the
same one-retry treatment before its pre-existing warn-and-skip fallback runs, narrowing
`counts.fetch_failures` to post-retry failures only and adding `counts.fetch_retries` for the
retried-regardless-of-outcome count. `dev/planning-tests.sh` pins all three sites with a
`reject-initial`/`reject-initial-once`, `reject-candidates`/`reject-candidates-once`, and
`reject-view-<n>-once` fixture-marker family (the same one-shot-then-permanent contract #246
established), a `.issue-calls` stub call log and `expect_issue_calls` helper (mirroring
`.api-calls`/`expect_api_calls`) that discriminates a retried call from one that merely slept
without re-attempting, and six new 0/1/2-failure-boundary fixtures. Since #217 the
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
comment yields `plan: null` but stays in `ready`. Since #281 (superseding #275), the identical
positive first-line-anchor `find-planning-work.sh` gained also applies here, at BOTH the
`$lastPlan` computation and the `plan:` selection expression itself (proven by a fixture where the
real plan and a marker-quoting record share one `createdAt`, discriminating the two sites) — so
neither a trusted record that opens with a harness marker nor one whose harness marker is preceded
by prose but which quotes the plan marker mid-body is ever selected as `plan`, re-anchoring
`trusted_post_plan`'s window to the real plan comment instead of the record; an issue whose only
marker-carrying trusted comment is such a record now reports `plan: null` rather than binding to
the record. It also pins that script's plan-binding approval
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
reason too, not just batch mode (since #240, see below, this REST lookup is skipped entirely when
gh's own `includesCreatedEdit` on the plan comment is exactly `false`; the check above still runs
identically whenever that flag is `true` or absent). Since
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
mechanically — an uncovered comment, an issue already uncovered for another reason, or (since
#240, see below) a covered comment gh itself already reports as never edited, is never looked up);
plus `--issue <n>` mode carrying both new reasons. `dev/selfcheck.sh`'s assertion 4.34
pins only that `bin/find-implementation-work.sh` and `skills/issue-implementer/SKILL.md` spell
both new reason strings identically, the same fixed-string-agreement contract as 4.33 —
`skills/issue-cycle/SKILL.md` is excluded for the identical, already-documented reason (its
*Plan-binding provenance* bullet prints `approval.reason` verbatim and names no individual
reason). Since #240, `bin/find-implementation-work.sh` pre-filters BOTH the #192 plan-comment check
and the #230 decision-comment check just described on gh's own per-comment `includesCreatedEdit`
boolean — already present in the `comments` field both calls already fetch, at no extra API cost:
exactly `false` means gh itself reports the comment was never edited, so the REST lookup is skipped
entirely, with no warn, leaving the plan or the entry covered; exactly `true` keeps today's lookup
and every fail-closed state unchanged; the key being absent (every fixture that predates this PR)
falls through to today's lookup unchanged — no new reason string, no new `counts` key, and no new
`--json` field, so gate assertions 4.34 and 4.41 are both unaffected. Honest limit: this is a
tripwire, not a control — a `false` GitHub reports for a comment that *was* genuinely edited would
skip the lookup silently too. `dev/planning-tests.sh` pins the skip with six new fixtures
(`impl-plan-edit-skipped-when-never-edited`, `impl-plan-edit-checked-when-flag-true`,
`impl-decision-edit-skipped-when-never-edited`, `impl-decision-edit-checked-when-flag-true`,
`impl-decision-edit-flags-are-per-entry`, and `impl-single-issue-edit-flags-skipped`), each proving
the skip mechanically via `expect_api_calls` rather than inferring it from the JSON, plus eight
measured mutants pinning both pre-filters, the index-alignment between `trusted_post_plan[]` and
its internal edit-flag array, and the jq `//`-operator trap that would otherwise treat a real
`false` as "missing". Since #284, `bin/find-implementation-work.sh` gets the identical
bounded-retry-then-fail-closed shape #272/#273 gave the planner script, applied to its own two
`gh` call sites — the batch `ready` query and the per-issue `gh issue view` inside the ready
loop — with the same `*_retried`/`*_unavailable` counts pair for the query and a `fetch_retries`
counter for the fetch (narrowing `fetch_failures` to post-retry failures only); `--issue <n>`
mode's own prefetch is deliberately NOT retried (both its callers already re-run the whole script
once on an unknown verdict), pinned by a dedicated fixture proving byte-identical behaviour to
before #284. Since #285, `bin/harness-status.sh` — the consumer both discovery scripts already
have — gains a top-level `degraded` boolean and `degraded_reasons` array (`"planning.<key>"` /
`"implementation.<key>"` strings), computed by a GENERIC rule (every key in either script's own
`counts` object whose name ends in `_unavailable` and whose value is exactly `true`, so it already
covers `initial_query_unavailable`, `candidates_query_unavailable`,
`author_association_unavailable`, and #284's own `ready_query_unavailable` with no per-key
enumeration to drift), plus `counts.degraded` mirroring the same boolean — pinned end-to-end via a
new `run_status` runner that invokes the real `bin/harness-status.sh`, which in turn resolves both
discovery scripts by bare name on the same stub `gh` PATH. Since #297, `bin/harness-status.sh`
gives its OWN three `gh` call sites — the plan-proposed query, the impl-blocked query, and the
open-PR query — the identical bounded-retry-then-fail-closed shape, publishing six new
`counts` booleans and extending `degraded_reasons` with a third, `"status.<key>"` half (the same
generic rule applied to this script's own new flags) after the planning and implementation
halves; pinned by nine new Part 14 fixtures that drive `run_status` too, but behind a
`build_stub_discovery`-built canned stand-in for both discovery scripts, new reject-marker
families (`reject-proposed(-once)`, `reject-blocked(-once)`, `reject-prs(-once)`) mirroring
`reject-ready(-once)`, and a new `.pr-calls` log (mirroring `.issue-calls`) read by a new
`expect_pr_calls` helper, since the open-PR query is a separate top-level `gh pr ...` call the
existing `.issue-calls` log never captures. Since #333, `bin/harness-status.sh` gains a FOURTH such
site, `waiting_on_human.followups_to_triage`: open, `no-plan` issues whose body opens with the
harness-filed follow-up marker (#308), fed by a fourth `gh issue list` call with the identical
bounded-retry-then-fail-closed shape, publishing `followups_query_retried`/`_unavailable` and a
`"status.followups_query_unavailable"` `degraded_reasons` entry appended after the three #297
entries. Per the maintainer's decision, `counts.human_actions` did NOT include this bucket through
v2.7.6 — the query could not tell a follow-up nobody had triaged from one a maintainer read and
deliberately parked (both kept `no-plan` and the marker), so `human_actions` was a generic sum over
every `waiting_on_human` array member EXCEPT a small, named exclusion list (through v2.7.6, exactly
`["followups_to_triage"]`) bound next to the sum, so a future member joins the
total automatically unless it too is named there (see #346 below for how #333's own bucket later
joined); pinned by four new Part 14 fixtures (a populated bucket whose `human_actions` stayed
unchanged at the time, a retry-succeeds case, a both-attempts-fail case, and a status-half-ordering
case) plus two extended Part 14 fixtures (the healthy and guarded-sleep-failure cases), a new stub
`gh issue list` arm (content-exclusive, needing no arm-ordering trick unlike the plan-proposed
arm), and a `reject-followups(-once)` marker family mirroring `reject-proposed(-once)`. Since #309,
`bin/harness-status.sh` gains a FIFTH such site, `waiting_on_human.escalations`: open, `needs-human`
issues, served verbatim with no filter, fed by a fifth `gh issue list` call with the identical
bounded-retry-then-fail-closed shape, publishing `escalations_query_retried`/`_unavailable` and a
`"status.escalations_query_unavailable"` `degraded_reasons` entry appended after the four existing
status-half entries. Unlike `followups_to_triage` at the time, this member was NOT named in the
exclusion list, so it joined `counts.human_actions` automatically by the same generic rule, with no
edit to the sum itself; pinned by three new Part 14 fixtures (a populated bucket whose
`human_actions` DOES change, a retry-succeeds case, and a both-attempts-fail case) plus two extended
Part 14 fixtures (the healthy and guarded-sleep-failure cases), a new stub `gh issue list` arm
(content-exclusive, the identical class as the no-plan arm), and a `reject-escalations(-once)`
marker family mirroring `reject-followups(-once)`. Since #346, `bin/harness-status.sh` gains a new
lifecycle label constant, `TRIAGED_HELD_LABEL` (`triaged-held`, human-applied only — the harness
never adds or removes it), and `list_followups()`'s own `--search` string gains a trailing
`-label:$TRIAGED_HELD_LABEL` exclusion, narrowing `followups_to_triage` to untriaged-only; with that
narrowing in place the `$excluded` binding is emptied (`[] as $excluded`, kept as the extension
point #333 designed), so `followups_to_triage` joins `counts.human_actions` too, by the identical
generic rule #309's own escalations member already used — `human_actions` is therefore, today, the
sum of every `waiting_on_human` member. New gate assertion 4.50 (the 4.48/4.49 shape reused) pins
the label's vocabulary end to end and that no `--label`/`--add-label`/`--remove-label` argument
names it in `skills/*/SKILL.md`, `skills/*/references/*.md`, `agents/*.md`, or `bin/*.sh`. No new
fixture is required in `dev/planning-tests.sh`: the six
`expect_issue_calls` needles pin the new query token, and the 0/1/2+ `human_actions` boundary is
pinned by three existing Part 14 fixtures (`status-followups-bucket-populated` at 2,
`status-followups-query-retry-succeeds` at 1, and `status-followups-query-unavailable`, whose own
bucket stays empty either way at 0); the pre-existing mutant (N8) is restated as its own inverse (adding
`"followups_to_triage"` back to the now-empty exclusion list) and a new mutant deletes the query's
own label token — both measured, alongside every pre-existing mutant in the four `MEASURED MUTANTS`
blocks whose target is `bin/harness-status.sh`, against the re-shaped code. Since #353,
`bin/harness-status.sh` gains a SIXTH such check, but not a sixth `gh` call site — it still makes
exactly five — one `bin/harness-stop.sh` invocation, fed by that script's own stdout grammar rather
than a second query and never retried at this layer (`bin/harness-stop.sh` already performs its own
one bounded retry). The status JSON gains a top-level `stop` object (`{state, reason, exit_code}`)
and a new `waiting_on_human.stop_routes` array (one `{route, clear}` entry per SET carrier, both
fields pasted verbatim, never re-derived), plus `counts.stop_routes` and, in `$sf`,
`counts.stop_check_unavailable` (appended last, after `escalations_query_unavailable`).
`stop_routes` was never named in the `human_actions` exclusion list either, so a SET stop with N
carriers joins the sum automatically, the identical generic rule `escalations` and (since #346)
`followups_to_triage` already use — `human_actions` is therefore, today, the sum of every
`waiting_on_human` member: `plans_to_review`, `prs_to_review`, `blocked`, `followups_to_triage`,
`escalations`, and `stop_routes`. Tested behind a new canned `build_stub_stop` stand-in (the
identical canned-not-real design `build_stub_discovery` already uses for this file's Part 14),
installed by DEFAULT from `run_status` so no pre-#353 `run_status` fixture needed changing to keep
passing (the default stand-in is why) and no fixture ever executes the real
`bin/harness-stop.sh` — `status-own-queries-healthy` gained three `expect_jq` assertions plus
`expect_stop_calls` as the default stand-in's own non-vacuity control; the other twenty are
byte-identical. Twelve new Part 14 fixtures pin the state mapping (fail-closed to `"unavailable"`
on every outcome `bin/harness-stop.sh` does not document, including a determinate-looking carrier
line printed alongside an untrusted exit — discarded rather than trusted), the verbatim
carrier/`clear=` pairing and GitHub-before-local ordering, the
`stop_check_unavailable`/`degraded_reasons` participation, and the `human_actions` arithmetic at
N=0/1/3 carriers; new gate assertion 4.51 pins that the stop-grammar tokens
`bin/harness-status.sh` parses appear as fixed strings in `bin/harness-stop.sh`'s own source.
It runs in CI as the sixth step, but it
is not part of `dev/selfcheck.sh` itself — run it by hand whenever `bin/find-planning-work.sh`,
`bin/find-implementation-work.sh`, or `bin/harness-status.sh` changes.

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
`CLAUDE_PID` is unset or non-digits. It runs in CI as the seventh of eight steps, but it is not
part of `dev/selfcheck.sh` itself — run it by hand whenever `bin/harness-lock.sh` changes.

`dev/stop-tests.sh` is a separate negative-test harness for `bin/harness-stop.sh` (#310), the
read-only maintainer stop switch checked before each stage and before each merge (ADR 0001
decision 8). It builds throwaway git repos under `mktemp`, each with its own small `tbin/`
directory that becomes the SUBPROCESS's entire PATH when invoking the real `bin/harness-stop.sh`
(never a fallback to the developer's or CI runner's own PATH) — `git`/`cat` always symlinked to
this machine's real binaries, `jq` symlinked or omitted entirely per fixture (the jq-missing
cases), a stub `sleep` (never a real 30s wait), and its own stub `gh` (a byte-identical
`GH_ISSUE_JSON_FIELDS` copy of `dev/planning-tests.sh`'s and `dev/cleanup-tests.sh`'s constant of
the same name, ADVISORY default accepted; `dev/planning-tests.sh`'s own stub is not reused — this
script's one call shape, `gh issue list --label ... --state open --json ... --limit ...`, gets its
own, smaller stub, plus a `badbody-once`/`badbody-always` marker pair letting a fixture serve an
arbitrary raw response body on an otherwise-zero-exit call) — and pins: the union semantics (a
labelled open GitHub issue, the local file `<git-common-dir>/trail-blazer/stop`, or both, all
yield `stop=true`/exit 3; neither yields `stop=false`/exit 0; a local stop plus an unreadable
GitHub route still yields exit 3 with a `reason=` line, since a determinate set route beats
unknown; an unreadable GitHub route with neither route set yields `stop=unknown`/exit 4); the
stdout grammar (`route=`/`clear=` pairs, at most one `reason=` line); the literal `--state open`
spelling in the logged query (#310 kickback K2); that a `gh issue list` attempt counts as a read
only when `gh` exits 0 AND the body parses as a JSON array — a non-zero exit, an empty body, a
body that fails to parse, and a well-formed JSON object are all a FAILED attempt, retried
identically once, never silently counted as "zero issues" (#310 kickback K1); that a SUCCESSFUL
attempt whose own `jq 'length'` count is not a single plain number — a body of more than one
concatenated JSON array document, which the array-shape check alone accepts since it judges only
the last document in the stream — closes the same "zero issues" fallback one layer further down,
with no retry (the attempt itself already succeeded) and the identical
`reason=github-query-unavailable` (#310 kickback N1, the `github-multi-document` case); that `jq`
absent from `PATH` makes the GitHub route unreadable with `reason=jq-not-found`, no sleep, no retry
attempted, while the local route (needing no `jq`) still works; the one-bounded-retry GitHub
query, proven via a stub-`sleep` call count and a stub-`gh` call log showing two attempts; a `git
worktree add` fixture proving a worktree shares its main checkout's local stop file; `--help`/an
unknown argument/not-a-git-repository; and (the approval addendum, since this script actually
executes `git`/`gh` unlike the `hooks/*.sh` never-executes idiom) a `never-mutates` case using a
*recording* `git` wrapper (logs its args, then runs the real `git`) and the stub `gh`'s own call
log (proving every call is `rev-parse --git-common-dir` / `issue list`, never a mutating one)
alongside booby-trapped `rm`/`mv`/`touch`/`mkdir`/`dirname` and a byte-identical fixture-tree
`find` listing before and after, across a stop-set and a stop-absent fixture — proving the script
never writes to the tree it reads. It runs in CI as the eighth and last step, but it is not part
of `dev/selfcheck.sh` itself — run it by hand whenever `bin/harness-stop.sh` changes.

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
  BSD/bash 3.2 by the `selfcheck-macos` CI job (post-merge and nightly, not per PR — #365).
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
  `dev/doctor-tests.sh`, `dev/cleanup-tests.sh`, `dev/lock-tests.sh`, `dev/planning-tests.sh`, and
  `dev/stop-tests.sh` each guard every needle-taking helper with a `needle_required` check that fails the case
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
