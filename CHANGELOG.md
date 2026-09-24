# Changelog

This file is a historical record of what each pull request did — not governance, not a gate
target, and not a spec. `dev/selfcheck.sh` never reads it, and no skill, agent, or gate assertion
depends on its content. Current behaviour is always stated by README.md, CLAUDE.md, and the code
itself, never by an entry here. An entry records what a change did at the moment it landed and is
never edited afterward, so a later change can supersede what an entry describes without ever
falsifying the entry itself. A cross-reference inside archived text (for example "see CLAUDE.md's
'Verification' section") points at the file the text was moved from, as that file read at the time
of the move — it is not kept in sync with that file's current content.

To add a new entry: under `## Unreleased`, add one bullet per pull request, newest first, shaped
`- #<issue>: <one to three lines>` naming what changed and any consumer-facing step — no fixture
counts, mutation-proof figures, or other measured numbers (those live in each suite's own header
and fixture/case comments, or, for a migrated mutant, its `dev/mutants/*.json` record — see
CLAUDE.md's Conventions). At release time, retitle the `##
Unreleased` heading to `## vX.Y.Z` (see CLAUDE.md's "Release ritual" and README's "Updating").

## Unreleased

- #311: Added an optional "Autonomy mode" CLAUDE.md section (`mode: autonomous`,
  `kickback-budget:`) that turns on plan auto-approval and merge autonomy together as one
  combination: a missing "Plan auto-approval policy" section is read as present with no
  conditions beyond the hard floor, and a missing "Merge autonomy policy" section is read as
  present for harness PRs only. Declared policy sections still apply in full and only narrow the
  mode; hard floors and the `gh pr merge` deny are unchanged. `check-harness.sh` validates the
  combination and reports it, and, only in autonomous mode, each settings file's
  `permissions.defaultMode`. No consumer step (opt-in).
- #340: hooks/agent-boundary.sh denies an implementer/verifier Bash redirect/tee/cp/mv/cd/
  in-place-sed into a .claude path segment; gate 4.53 pins claude-dir-guard.sh's GUARDED_TOOLS
  against both roles' tools: lines (absorbs #341). No consumer step.
- #384: A kickback or CI-fix re-verification now checks only prior findings plus the fix's delta
  since the previously reviewed commit, and a new mutant surviving on unchanged code is a Note.
  Fix dispatches iterate narrow and run the full verification once. The implementer keeps counts
  in its report, not in source comments; this repo deletes a stale prose figure rather than
  recounting it.
- #359: Added `dev/mutant-driver.sh`, a checked-in mutant driver that reads `dev/mutants/*.json`
  registry records and re-runs each one's recorded exact-text edits against a scratch copy, and
  `dev/mutant-driver-tests.sh`, its own negative-test harness; gate assertion 4.52 cross-checks a
  `# mutant:<name>` comment token in `dev/*.sh` against its registry record. Migrated the
  `bin/harness-status.sh` mutants from `dev/planning-tests.sh`'s prose `MEASURED MUTANTS
  (#284/#285)`/`(#297)`/`(#333)`/`(#309)`/`(#353)` blocks — the harness-status tranche — into
  `dev/mutants/planning-tests.json`; the driver's own self-mutants live in
  `dev/mutants/mutant-driver-tests.json`. `dev/mutant-driver-tests.sh` runs on every pull request
  (ubuntu) and in both jobs post-merge/nightly/dispatch; `dev/mutant-driver.sh` runs only
  post-merge on `main`, nightly, and on manual dispatch.
- #364: `dev/selfcheck.sh`'s header no longer hand-maintains an assertion total (the summary
  footer's pass + fail is the total), so a new assertion never edits a shared line; the
  tautological header-count self-test is removed; CLAUDE.md now makes "no new gate assertion" the
  default, requiring a plan to name the drift one prevents and why no existing suite catches it.
- #363: Moved the per-PR "Since #N, X gains…" history out of CLAUDE.md's Verification section, out
  of `dev/cleanup-tests.sh`, `dev/hook-tests.sh`, and `dev/planning-tests.sh`'s own header
  comments, and out of README's per-repo migration notes, into the Archive below. CLAUDE.md's
  Verification section now states what each suite covers and how to run it in the present tense;
  the three test-header comments each carry a short pointer to this file instead; README's
  migration section now carries one line per version hop, expanding to the consumer step only when
  a hop has one. No code, fixture, or measured figure changed.

## Archive (moved verbatim by #363)

### CLAUDE.md: Verification section, per-suite paragraphs

Moved from `CLAUDE.md`'s "Verification" section (the per-suite narrative between the gate intro
and the Conventions section) by #363.

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
grown registry. Since #370, the script gains a SECOND hygiene query, `gh issue list --label
pr-open --state closed --json number,title --limit 100`, sweeping the whole historical backlog of
CLOSED issues still labelled `pr-open` — not just #355's own residue, since nothing else in the
harness ever removes the label from an issue GitHub auto-closed when its PR merged — up to 100 per
run, converging across runs; an issue is kept while any `claude/<n>-*` PR for it is still OPEN, and
the sweep runs whenever the PR list itself was fetched, independent of the open-issue query's own
success. The repair is label-only — `gh issue edit --remove-label pr-open` through the existing
`try_write` helper, no audit comment posted, since the label-removal event is its own audit trail.
`build_stub_gh`'s `issue list` arm gains a `--label pr-open --state closed` case (checked ahead of
the pre-existing `--label pr-open` open-state case, since bash `case` takes the first match), a
`malformed-closed-list` marker (gh exits 0 with a non-JSON body — the identical VIEW_MODE=malformed
shape, but call-scoped via a marker file rather than a `build_stub_gh` positional, since this query
has no MODE parameter of its own), and `reject-closed-list`/`reject-open-list` failure markers;
twelve new fixtures (59 → 71) cover the label-only removal, the report-only `STALE` line, keeping
the label while a sibling PR is open (in both modes), sweeping an issue with no matching PR at all,
a write failure that still lets a second issue repair, a failed OR non-JSON (malformed) query in
either direction, the PR-list-unavailable skip, the `<n>` scoping against an OPEN PR for a
DIFFERENT issue, and the empty-list control, each with a measured mutation proof, alongside the
four pre-existing mutants this section's own new code actually reaches — (d), (g), (M11), and
(M12) — each re-run against the grown registry, and the other thirty-six pre-existing mutation
proofs restated as +1 pass each by the file's own growth-chain mechanism argument, with three
((a), (l), and (M2)) spot-checked by actual re-run. Since #370 kickback round 3, the closed arm
additionally appends its own full argv to a separate `DIR/gh-list-calls.log` (read into
`$list_calls`, asserted via a new, needle-guarded `expect_list_call` helper — the pre-existing,
mutation-only `gh-calls.log`/`$calls`/`expect_calls_empty` are untouched), and
closed-sweep-removes-label gains one new assertion pinning the closed query's own literal
` --limit 100` argument — no fixture was added (the registry stays at 71), but a seventeenth
mutant, (C17) (deleting ` --limit 100` from the query), is added with its own measured proof
(70 pass, 1 fail, failing EXACTLY closed-sweep-removes-label). Since #370 kickback round 4, the
same fixture gains two more assertions — `expect "== closed issues still labelled pr-open =="`
(a verifier finding: deleting that section header's own `echo` line survived every prior round)
and a new `expect_section_order` helper call pinning the header's POSITION between `== pr-open
label hygiene ==` and `== follow-ups from rejected PRs ==` — backed by two new mutants, (C18)
(deleting the header line) and (C19) (physically moving the whole closed-issue-sweep block to run
after the follow-ups block instead of before it). The same round also ran a full literal sweep
against every literal RESOLVED and the acceptance criteria name for this section, mapping each to
the fixture:assertion that observes it and the mutant that is measured to catch it; three literals
had an assertion but no dedicated mutant before this round — the sweep's exact `gh issue edit <n>
--remove-label pr-open` write, its "no comment, no close" fact, and its `first // empty` jq
fallback — closed by three further new mutants, (C20) (a spurious `gh issue comment` call), (C21)
(changing the write's own `--remove-label pr-open` argument), and (C22) (deleting the ` // empty`
fallback, which otherwise lets jq's null-to-`"null"` string serialization masquerade an absent PR
match as a still-open one). No fixture was added or removed this round either (the registry stays
71-case); mutant count: seventeen -> twenty-two. It runs in
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

### README.md: per-repo migration notes, v1.9.0 to v2.7.7

Moved from `README.md`'s "Updating an already-onboarded repo (per-repo migration)" section by
#363.

For **v1.9.0 → v2.0.0**, exactly one thing migrates: a new permission grant,
`"Bash(gh auth status:*)"`. Three skills run `gh auth status` as their first command, so without
it a repo on the default permission mode stalls at the start of every run. Re-copy the
permissions block from `templates/repo-settings.json`, or add that one entry by hand — the doctor
names it either way. No new label, script, or baseline step.

Two behaviour changes worth knowing, both of which *narrow* what the harness does unattended, so
neither can surprise you into a merge you didn't want. The merge pass now treats CI configuration
as governance surface, and treats a repo that reports "no checks configured" as **not** green —
if you run merge autonomy on a repo with no CI, no PR qualifies until your own policy section
explicitly opts a no-CI repo in. Follow-up issues the harness files now carry `no-auto-approve`
(remove the label to release one into planning) and are commented and labelled `no-plan` by
`cleanup-after-merge.sh --fix` if the PR that filed them is closed without merging — since
v2.7.5 (see the v2.7.4 → v2.7.5 note below), a follow-up is filed with `no-plan` from birth
instead, so the "remove `no-auto-approve` to release" step now applies only to a follow-up filed
by an older harness version; since v2.7.6 (#334, see the v2.7.5 → v2.7.6 note below) the
quarantine-on-orphan behaviour described here reaches a follow-up born `no-plan` too, keyed on a
trusted comment marker rather than the label.

This release adds one further grant your repo must add: `"Bash(gh pr edit:*)"` — the orchestrator
needs it to refresh a PR body it already opened (writing filed follow-up issue numbers into it,
and replacing the verifier status line and mutation-probe line after a CI-fix round). Re-copy the
permissions block from `templates/repo-settings.json`, or add that one entry by hand — the doctor
names it either way. Under merge autonomy, this release also makes the merge floor stricter: it
now additionally requires the PR body's verifier line to match a verifier verdict the orchestrator
archived as an issue comment (see "Verdict provenance" under "Safety model"). Any PR opened before
your repo picks up this version carries no such comment, so it is not eligible for autonomous
merge — it simply waits in the "waits on the human" queue until you merge it by hand.

**v2.2.0 → v2.3.0** adds no grant, label, script, or baseline step — the doctor reports nothing
new to migrate. Three doctor checks got sharper: a `#` comment inside the ratchet policy's fenced
block no longer truncates the section slice; a declared "Post-merge verification" block now gets an
advisory WARN naming the exact `Bash(<command>:*)` entry for any declared command that has no
matching allow entry (a string comparison — nothing declared is ever executed); and an abbreviated
`- commit:` value of 7+ hex characters in `.claude/BASELINE.md` no longer trips the "baseline is
behind" WARN, while a shorter value WARNs as malformed. Under merge autonomy the merge floor is
stricter again: the archived verifier verdict is now keyed to the PR's head branch (a second
`<!-- verifier-verdict-branch: … -->` line in the archive comment), so a PR opened before your repo
picks up this version carries an unkeyed archive and is not eligible for autonomous merge — it
waits for one manual merge, exactly like the v2.2.0 transition above.

**v2.3.0 → v2.4.0** removes a grant rather than adding one: the nine `Bash(git -C * <sub> *)`
allow entries worktree-parallel mode used to depend on are gone from the template, replaced by a
plugin-shipped `PreToolUse` guard hook (`hooks/hooks.json` + `hooks/git-c-guard.sh`) that
auto-updates with the plugin and needs no per-repo file. Re-copy the permissions block from
`templates/repo-settings.json` (or delete the nine entries by hand) to pick this up — the nine
"has a wildcard before the rest of the command" warnings Claude Code 2.1.246+ prints at the start
of every session are the visible cue that your repo is still on the old template. Because the
plugin's marketplace entry ships `"autoUpdate": true`, the plugin itself updates before you next
sync settings in practice, so the guard hook is already active by the time you delete the old
entries — worktree-parallel mode's `git -C` commands stay prompt-free throughout the transition.
`check-harness.sh` now also WARNs when it finds `disableAllHooks: true` in any of the three
settings files (silently disabling the guard hook, and every other hook) and, separately, when
`.claude/settings.json` still carries one of the superseded legacy `-C` allow entries. The
post-merge allow-entry check and the path-qualified interpreter probe now also consult this same
three-file union instead of `.claude/settings.json` alone, so a grant that lives only in
`.claude/settings.local.json` or the user-level settings file no longer produces a spurious "no
matching allow entry" WARN — no consumer action required. The guard also now covers
`git -C <worktree> log` (#155) — the verifier's read-only commit-message evidence call, which
previously hit an unanswerable prompt inside a worktree — and its handler is registered with an
`"if": "Bash(git -C *)"` filter so the hook process is only spawned for `git -C` Bash commands,
which needs Claude Code **2.1.85+** (see "Prerequisites").

**v2.4.0 → v2.5.0** adds no grant, label, script, or baseline step — the doctor reports nothing
new to migrate. What changes is trust and provenance, and every change *narrows* what the harness
does unattended. (1) Comment- and issue-author provenance: only `OWNER`/`MEMBER`/`COLLABORATOR`
comments are binding feedback, only maintainer-authored issues can be auto-approved, and
everything untrusted is surfaced to you in new report buckets instead of silently acted on. A bug
(fixed in #202) had this lookup ask `gh` for an issue-level `authorAssociation` `--json` field it
has never returned on any version — not a version gap that would close as `gh` caught up — so
issue-author trust failed closed on every run and **plan auto-approval was effectively paused
wherever a policy exists**; manual approval was unaffected throughout. The lookup now reads the
same GitHub-computed association from the REST issues endpoint instead, which does return it
today, so auto-approval resumes for maintainer-authored issues wherever a policy exists — re-read
your policy before upgrading if you had come to rely on the (accidental) pause. (2) Harness-authored
record comments (auto-approval audits, staleness notes on approved plans, interrupted-run/worktree-sweep
notes, `cleanup-after-merge.sh`'s hygiene comments) now open with `<!-- harness-audit -->` and are
excluded from feedback detection and from the implementer's binding context — no more phantom
revisions after an audit comment. One-time transition note: such comments posted by *older*
versions carry no marker, so each can trigger at most one spurious revision before its issue's
next plan supersedes it. (3) Approval now binds to the plan artifact: the newest `plan-approved`
labeling event must post-date the plan comment, the implementer revalidates before dispatch and
before push (a plan revised after approval is returned to review — `plan-approved` removed, an
audit comment posted — never silently built), PR bodies carry a machine-generated
`<!-- harness-plan-binding: … -->` line, and under merge autonomy the floor requires it — so a PR
opened before your repo picks up this version is not eligible for autonomous merge and waits for
one manual merge, exactly like the v2.2.0 and v2.3.0 transitions. This costs one extra read-only
GitHub API call per ready issue. (4) The doctor's merge-gated CI action-pinning WARN now also
scans `action.yml`/`action.yaml` under `.github/actions/` — a repo that previously showed a clean
PASS may newly WARN if an unpinned ref hides inside a local composite action; that is the fix, not
a regression (that hop's scan stopped at `.github/actions/`; it has since widened to cover any
`action.yml`/`action.yaml` anywhere in the repo — see the "Merge autonomy policy" item in the
CLAUDE.md contract). (5) The
decision-record checker is stricter: fence-aware section slicing, required non-empty content, and
same-depth sibling headings no longer leak into a record's span — a record that passed by accident
under the looser scan can start failing; the failure names the element.

**v2.5.0 → v2.5.1** adds no grant, label, script, or baseline step — the doctor reports nothing
new to migrate — but **upgrade promptly: v2.5.0's approval binding is broken live**. (1) The bug
(#196): `find-implementation-work.sh`'s `plan-approved` events lookup applied its `gh api --jq`
filter to the wrong document shape (each response page arrives as a JSON array), the error was
swallowed, and every ready issue fail-closed to `approval-unreadable` — so under the v2.5.0
implementer skill's approval gate no approved issue could ever be dispatched, and the gate's
prescribed remedy would strip your fresh `plan-approved` labels and post revision-triggering
comments. v2.5.1 fixes the filter and makes the planning-tests stub faithful to real
`gh api --jq` document semantics, so the approval fixtures now pin the live shape instead of two
bugs canceling out. (2) Post-approval comments narrow further (#194): a trusted comment posted
*after* the `plan-approved` label is no longer restated to the implementer as a binding
`RESOLVED:` decision — it is marked `covered_by_approval: false`, warned about, and reported to
you; to make such a comment binding, remove and re-add `plan-approved`, which re-binds the
approval to the thread's current state. (3) Forged harness-record markers are flagged (#194): an
untrusted comment carrying `<!-- harness-audit -->` or `<!-- verifier-verdict -->` is annotated
`has_harness_marker: true` in the untrusted report buckets, with a warn line and a count — new
warns may appear where drive-by comments dress up as harness records; nothing is filtered out.
(4) Unattended planning runs leave a durable trace (#194): an issue that drops out of a pass with
no recorded outcome now gets a `<!-- harness-audit -->` escalation comment on the issue itself,
instead of only a line in the run summary that vanishes with the session. (5) The doctor's
merge-gated CI action-pinning WARN now scans every `action.yml`/`action.yaml` anywhere in the
repo, pruning `.git`, `node_modules`, and `.github/workflows` (#186) — a repo that previously
showed a clean PASS may newly WARN about an unpinned ref in a local composite action outside
`.github/actions/` (the exact exposure the widening closes) or in action files CI never runs;
WARN-only, the doctor's exit code is unaffected.

**v2.5.1 → v2.5.2** adds no grant, label, script, or baseline step — the doctor reports nothing
new to migrate — but **upgrade promptly if you run a "Plan auto-approval policy": it has been
silently paused since v2.5.0**. (1) **Auto-approval works again (#202).** `find-planning-work.sh`
read issue-author provenance from a `gh issue list --json authorAssociation` field `gh` has never
supported, so every run since v2.5.0 fail-closed — `counts.author_association_unavailable: true`,
every issue `trusted_author: false`, and plan auto-approval paused on every machine wherever a
policy exists. The lookup now uses GitHub's REST issues endpoint (`author_association`), which
returns the field today: auto-approval resumes for maintainer-authored issues wherever a "Plan
auto-approval policy" section exists — a **widening** back to the #176 design intent, so re-read
your policy before upgrading if you preferred the pause. The fail-closed branch behaves exactly
as before and now fires only when the REST lookup itself fails. Costs one extra read-only,
paginated API call per planning run. (2) Post-approval comments are surfaced at the pre-push
revalidation (#198): the implementer's step 2e compared only the binding line, so a trusted
comment that arrived while the implementer was working went unmentioned; it now diffs the
trusted-but-uncovered post-plan set against the one recorded at dispatch and quotes any newly
arrived comment (author, association, `createdAt`, `url`) in the PR body's verification section
and the run summary, or in the blocker comment when the binding-line check fails first. Such a
comment stays non-binding — no `RESOLVED:` decision, no re-dispatch, no push hold — so an empty
diff leaves behaviour byte-identical. (3) Planner escalation comments are de-duplicated across
runs (#199): the `<!-- harness-audit -->` escalation the planner posts on an issue that drops out
of a pass with no recorded outcome now carries a second line,
`<!-- harness-escalation: bucket=<bucket> stage=<stage> -->`, and is skipped when the newest
maintainer-authored escalation on the issue already carries the identical key — an issue stalled
across unattended cycles no longer collects one duplicate per run. The run-summary escalation is
never suppressed, and only `OWNER`/`MEMBER`/`COLLABORATOR` comments satisfy the guard, so a
forged key cannot silence a real escalation. One-time transition note: escalation comments
posted by v2.5.1 carry no key line, so such an issue receives at most one more comment before
the guard takes effect.

**v2.5.2 → v2.6.0** adds no grant, label, script, or baseline step — the doctor reports nothing
new to migrate. **Approval now also binds to the plan comment's edit state (#192).**
`find-implementation-work.sh` fetches the selected plan comment's REST `updated_at` and compares
it against the plan-approved label's timestamp — but only for an issue whose approval would
otherwise already cover the plan, so this costs one extra read-only API call per *covered* ready
issue, not per ready issue. **Refined in v2.7.2 by #240**: that per-covered-issue call is now ALSO
skipped when gh's own per-comment `includesCreatedEdit` reports the plan comment was never edited —
see the v2.7.1 → v2.7.2 migration entry below for the current cost. Consumer tooling reading this script's JSON may newly see two
`approval.reason` values it has never seen before, `plan-edited-after-approval` and
`plan-edit-unreadable`, plus two new `counts` keys, `counts.plan_edited_after_approval` and
`counts.plan_edit_unreadable` — additive only, no existing key renamed or removed. Behaviour
**narrows**: a plan comment edited in place after its approval, which every prior version treated
as still covered, now waits for a human to re-approve it (remove and re-add `plan-approved`)
instead of being built silently — the same "waits for a human" posture the v2.5.0 approval-binding
transition (and v2.5.1's fix to it) already established for a plan revised after approval, just
for one more way a plan can outrun its approval. **Behaviour also widens for an unknown approval
verdict (#219).** Every prior version treated `approval.covers_plan` values `false` and `null`
identically: an unreadable GitHub API call (`reason: "approval-unreadable"` or
`"plan-edit-unreadable"`, or a `plan_selection` entry missing entirely) triggered the same
destructive remedy as a demonstrably-uncovered plan — `plan-approved` removed and a
revision-triggering comment posted — so one transient outage during an unattended run could strip
approval from every ready issue. The `issue-implementer` skill now splits its remedy by verdict:
a demonstrably-uncovered plan (`covers_plan: false`) is byte-identical to before; an *unknown*
verdict instead holds non-destructively — no label change, no revision-triggering comment, one
`<!-- harness-audit -->`-marked comment recording the hold, and the issue stays queued for the
next run's fresh check, both before dispatch (step 2a) and again before push (step 2e, where the
already-staged tree is checkpointed as `wip: checkpoint binding-recheck` rather than lost). No
new grant, label, script, or baseline step; `bin/find-implementation-work.sh`'s tri-state and its
`counts` keys are unchanged — only the `issue-implementer` skill's remedy changes.
**Under merge autonomy the hard floor is stricter (#206).** The merge pass now reads the uncovered
`trusted_post_plan` set from the same fresh `find-implementation-work.sh --issue <n>` run it already
makes for the plan-binding check: a maintainer (`OWNER`/`MEMBER`/`COLLABORATOR`) comment posted on
the issue after its `plan-approved` label — even after the PR opened — holds that PR in the normal
"waits on the human" queue (`outcome=not-eligible`, one-line reason naming the comment's URL).
Behaviour **narrows**: no PR merges past a post-approval comment the approval does not cover.
Release path in this version: merge the PR yourself, or withdraw the comment and let the next cycle
re-evaluate; re-adding `plan-approved` does **not** release an open PR (it moves
`approval.approved_at`, so the PR body's older binding line no longer matches — see "Merge
autonomy policy"). One-time transition note: a PR already open when your repo picks up this
version is held if its issue carries any such comment — one manual merge, exactly like the v2.2.0
transition. Heads-up: #213 (approved, planned for the next release) is expected to let re-approval
of the *same* plan release a held PR, so do not build a habit around the interim rule. **Planner
staleness notes are de-duplicated across runs (#208).** The `<!-- harness-audit -->` note the
planner posts on a `plan-approved` issue whose plan predates merged PRs that touched its Affected
areas now carries a second line, `<!-- harness-staleness: issue=<n> prs=<prs> -->`, and is skipped
when the issue's newest maintainer-authored staleness note already carries the identical key — an
approved-but-stale plan no longer collects one duplicate note per unattended cycle. The run-summary
flag is never suppressed, and only `OWNER`/`MEMBER`/`COLLABORATOR` comments satisfy the guard.
One-time transition note: notes posted by earlier versions carry no key line, so such an issue
receives at most one more note before the guard takes effect. Repo-internal only, no consumer
effect: `dev/planning-tests.sh`'s stub `gh` now propagates jq errors on its events and candidates
arms (#204, #211) and validates every `gh issue … --json` field list against gh's documented set
(#217), its fixtures use GitHub's real comment-url shape under new gate assertion 4.31 (#220), and
the macOS CI job's timeout is 10 minutes (#224).

**v2.6.0 → v2.6.1** adds no grant, label, script, or baseline step — the doctor reports nothing
new to migrate. **Approval now also requires `plan-approved` to be currently on the issue (#229).**
`find-implementation-work.sh` fetches `labels` on the same `gh issue view` call it already makes
and checks first, before the events lookup and before #192's plan-edit lookup, at zero extra API
cost: `plan-approved` absent from the issue's current labels is a new `approval.reason` value,
`approval-label-absent`, and a new `counts` key, `counts.approval_label_absent` — additive only, no
existing key renamed or removed. Behaviour **narrows**: a maintainer who removes `plan-approved` to
veto an issue mid-flight — previously undetected between the historical labeling event this script
already read and the label's current state — now halts dispatch, the pre-push recheck, and (under
a merge autonomy policy) the autonomous merge floor at the next check each one runs, since
all three read `approval.reason` for this same issue. The remedy is **non-destructive**, unlike
every other `false` reason: no label change (there's nothing to remove), no revision-triggering
comment (there's nothing to revise) — instead the `issue-implementer` skill posts one
`<!-- harness-audit -->`-marked comment naming the withdrawal and, at the pre-push recheck, keeps
the already-implemented tree as a `wip: checkpoint binding-recheck` commit rather than discarding
it, so the branch resumes automatically via the normal WIP-branch classification rule once a human
re-adds `plan-approved`. No new grant, label, script, or baseline step.

**Re-approving the same plan now releases a held PR under merge autonomy (#213).** The interim
rule shipped in v2.6.0 — "re-adding `plan-approved` does not release an already-open PR" — is
reversed: `find-implementation-work.sh`'s `plan_selection[].approval` gains an additive
`approved_at_history[]` array (newest first, deduplicated, one `{approved_at, approved_by,
binding_line}` entry per real `plan-approved` labeling event the events API returns, each entry's
`binding_line` built for the plan selected *now*; entry `[0]`'s `approved_at`/`approved_by` equal
the top-level fields by construction (both resolve to the same newest event), and entry `[0]`'s
`binding_line` is what the top-level `binding_line` is now derived from — one template, not two).
The `issue-cycle` merge floor's *Plan-binding provenance* check
walks that array newest first, pasting each entry's `binding_line` into the same
substitution-free `contains(...)` needle it already used, stopping at the first match: a PR body
written under an *earlier* approval of the same plan is now accepted, so removing and re-adding
`plan-approved` — the README's own documented way to bind a post-approval comment (see "Merge
autonomy policy" → *Post-approval comments*) — releases an already-open PR instead of stranding it
forever. Behaviour **widens** on this one axis only: a maintainer who comments on an open PR's
issue and then re-approves the same plan releases that PR **without the comment having been
implemented**. The documented remedy, unchanged in spirit from before: **close the PR first, then
re-approve**, so the comment binds the next dispatch instead of being silently released underneath
it. Every other fail-closed axis is unchanged — a different plan comment's url, a timestamp
matching no real labeling event, an empty history, or an unreadable events lookup all still hold
the PR. At this version, `skills/issue-implementer/SKILL.md`'s pre-push re-check (step 2e) was
deliberately left unchanged: a bare re-approval landing *during* implementation still returned the
issue to review, same as before this release. **Superseded in v2.7.1 by #238**: step 2e now
accepts a same-plan re-approval too — see "Approval provenance" below for the current rule and the
release mechanism itself. No new grant, label, script, or baseline step.

**Approval binding now also checks every COVERED trusted decision comment's own edit timestamp,
not just the plan comment's (#230).** `find-implementation-work.sh`, on the branch that would
otherwise conclude a `trusted_post_plan` entry `covered_by_approval: true` (#194 workstream B —
after #229's label pre-filter and #192's plan-edit check both pass), fetches that comment's own
REST `updated_at` (one extra read-only `gh api` call per *covered* comment, never per uncovered
one) and compares it against `approval.approved_at`, the same idiom #192 already uses for the plan
comment itself. **Refined in v2.7.2 by #240**: that per-covered-comment call is now ALSO skipped
when gh's own per-comment `includesCreatedEdit` reports the comment was never edited — see the
v2.7.1 → v2.7.2 migration entry below for the current cost. A covered comment edited strictly
*after* approval flips that entry to
`covered_by_approval: false` and adds a new per-entry field, `covered_by_approval_reason:
"decision-edited-after-approval"` — additive only — and collapses the ISSUE-LEVEL verdict the same
way: `approval.covers_plan: false`, `approval.reason: "decision-edited-after-approval"`, a new
`counts.decision_edited_after_approval` key. An entry whose own edit state cannot be established
(no parseable comment id, a rejected lookup, or an unreadable `updated_at`) collapses the verdict
to **unknown** instead: `covers_plan: null`, `reason: "decision-edit-unreadable"`,
`covered_by_approval_reason: "decision-edit-unreadable"`, a new `counts.decision_edit_unreadable`
key — edited wins precedence when an issue has both. `approval.approved_at`/`approved_by` stay
populated in both new states (the events lookup itself succeeded), matching #192's precedent.
Behaviour **narrows** on one existing key: `counts.post_approval_comments` now excludes an entry
whose `false` comes from its own edit (`covered_by_approval_reason` non-null) rather than merely
postdating the label — the same comment is no longer double-reported under two different reasons,
but a warn-line count some tooling may have relied on can now read lower for an issue with an
edited decision comment. Remedy, unchanged in spirit from #192: **remove and re-add
`plan-approved`** — the human re-reads the edited decision and re-approves, moving `approved_at`
past the edit and re-covering it, the same audited path already documented above. One-time
transition note: on the first discovery run after upgrading, an issue with a covered decision
comment that was quietly edited some time ago will newly report `covers_plan: false` or `null` and
lose `plan-approved` (or hold, for the unknown verdict) — this is the intended tripwire firing
retroactively, not a regression. No new grant, label, script, or baseline step.

**v2.6.1 → v2.7.0** requires three consumer actions: **re-run `bin/setup-labels.sh`** to create the
new `multi-pr` label (until then, `check-harness.sh` reports it missing — see below); **re-copy
the permissions block** from `templates/repo-settings.json` to pick up the two new allow entries —
`"Bash(harness-lock.sh:*)"` the single-flight lock needs (#232, below) and
`"Bash(harness-version.sh:*)"` the harness-version report needs (#233, below) — until then,
`check-harness.sh` WARNs "settings.json allow-list missing 2 template entries"; and **no action**
for the version-provenance lines themselves (#233) — every new `harness=<version>` status-line
field and `<!-- harness-version: ... -->` marker line is purely additive, so an existing ledger
record, archived verdict, or PR body with neither keeps parsing exactly as before. **The
implementer's unknown-verdict
hold comment is de-duplicated across runs
(#222), the same treatment #199 and #208 already gave the planner's escalation and staleness
notes.** The `<!-- harness-audit -->` comment `issue-implementer` posts at step 2a and step 2e
when `approval.covers_plan` is unknown (a GitHub API call failed) now carries a second line,
`<!-- harness-hold: issue=<n> stage=<stage> reason=<reason> comments=<ids> -->`, and is skipped
when the issue's newest maintainer-authored hold comment already carries the identical key — an
issue held across an unattended multi-hour outage no longer collects one duplicate hold per
scheduled cycle. The run-summary flag is never suppressed — every held issue is still reported
every run, whether or not the comment posted — and only `OWNER`/`MEMBER`/`COLLABORATOR` comments
satisfy the guard, so a forged key cannot silence a real hold. The `approval-label-absent` hold
(#229, the human's own withdrawal) is deliberately **not** keyed: batch discovery already excludes
any issue without `plan-approved`, so that hold cannot repeat across scheduled runs, and keying it
would suppress a genuine *second* withdrawal notice after a re-approval. One-time transition note:
hold comments posted by v2.6.1 and earlier carry no key line, so such an issue receives at most one
more hold comment before the guard takes effect. No new grant, label, script, or baseline step.
**The implementer also retries an unknown verdict once before concluding it (#223):** at step 2a
and again at step 2e, before treating any of the three unknown triggers as final, the skill waits
`sleep 30` (the "Resilient dispatch" ladder's first rung) and re-runs
`find-implementation-work.sh --issue <n>` exactly once more, using that run's result for
everything the step reads — so a single momentary API blip no longer holds an otherwise-ready,
already-approved issue for the whole run. A determinate second verdict is acted on exactly as a
first-run verdict would be, including a `false` verdict's remedy; only a verdict still unknown
after the retry holds, keyed by the post-retry `approval.reason`. This adds no grant
(`Bash(sleep:*)` is already in `templates/repo-settings.json`), no label, no script, and no
baseline step; the only observable cost is one extra read-only discovery run plus up to 30s of
added wall clock, per held issue, per checkpoint.
**Multi-PR cleanup is now label-primary and the comment-marker path is trust-gated (#231):** the
new `multi-pr` label on the issue (see "Label lifecycle") is the primary signal
`cleanup-after-merge.sh` reads to leave a multi-PR issue open when one of its slices merges — the
consumer action named above. The `<!-- harness-multi-pr -->` **comment** marker is still honoured,
but only from an `OWNER`/`MEMBER`/`COLLABORATOR` comment; a marker from anyone else is ignored and
reported as one `WARN` line naming the comment, instead of silently trusted. The
**issue-body** marker is no longer honoured at all — cleanup has no author-association lookup for
the issue itself, so it cannot gate that path the way it gates a comment's. One-time transition
note: any issue that relied on the body marker before this release needs the `multi-pr` label
applied by hand; without it, that issue closes on the normal path the next time its slice's PR
merges — the intended, documented behaviour change, not a bug.
**A single-flight lock now guards against two harness cycles running concurrently in one
checkout (#232):** the `issue-cycle`, `issue-planner`, and `issue-implementer` skills each
acquire `bin/harness-lock.sh` (new script, the consumer action named above) at their own step 0
— unless they're being run as part of `issue-cycle`, which acquires once for the whole composed
run — and release it at their closing step, and on every STOP/abort path too. A refused acquire
(the lock already held) aborts the run loudly, before any tree-mutating command, with the
holder's record and the `harness-lock.sh release --force` remedy. See "Safety model" below for
the mechanism (the atomic `mkdir`, the reclaim rule, the recorded-pid rationale, and the honest
limits) and CLAUDE.md's "Verification" section for `dev/lock-tests.sh`, the new seventh CI
command.
**The merge pass's hard floor gains a mechanical up-to-date rail (#234, review F4):** before
attempting each PR's merge, the cycle now confirms the default branch's current tip is contained
in that PR's head commit (`git merge-base --is-ancestor`, re-checked per PR, immediately before
that PR's own merge attempt — the tip moves after every merge in the pass); a PR whose head does
not contain it is held with "PR is behind `<default>` at `<short-sha>` — update the branch and
let CI re-run" rather than merged on CI that ran against a base the default branch has since
moved past. **Behavior narrows, never widens:** this only ever holds a PR autonomous merge would
previously have taken. Because the pass merges one at a time with re-verification between, every
PR queued behind the first merge of a pass is behind by construction and holds this way too —
expected, not an error; auto-updating the held branch and waiting for its CI is a **named,
tracked follow-up**, not shipped here, so a queue with several ready PRs still drains at one merge
per cycle until it lands. The doctor also gains WARN-only reporting: only when a "Merge autonomy
policy" section is declared and the protection endpoint call succeeds, `check-harness.sh` now
reads the protection document itself and reports `required_status_checks.strict` (WARN when not
exactly `true`), the number of required status check contexts (WARN when zero), and whether
required PR reviews are configured (informational) — none of the three can FAIL, and with no
policy section the doctor's protection output is unchanged. No new grant, label, script, or
baseline step.
**The implementer/verifier "no git, no gh" boundary is now mechanically enforced (#235, review
F3):** a second plugin-shipped `PreToolUse` hook, `hooks/agent-boundary.sh` (see "Safety model"
for its full contract), denies `git`/`gh` Bash commands for those two subagent roles. Consumers
get it automatically with the plugin update — **no grant, no label, no script, no baseline step,
and no settings re-copy for this issue.** The boundary applies only to this plugin's own
`implementer`/`verifier` subagents, never to the main session, the planner, or any other agent,
and it can only **remove** permission a settings file would otherwise have granted — it never adds
any. A Claude Code that does not supply `agent_type` in `PreToolUse` stdin simply leaves the hook
silent, the same status quo as before this release — never a new block.

**v2.7.0 → v2.7.1 adds a new mechanical block** (#260), not just measurements and a SIGPIPE fix:
a third plugin-shipped `PreToolUse` hook, `hooks/push-guard.sh`, now denies any `git push` whose
destination resolves to your repo's default branch, inside **any** Claude Code session with the
plugin enabled — the main session included, unlike `hooks/agent-boundary.sh`, which only governs
the implementer/verifier subagents. If your workflow ever pushes to the default branch directly
from inside a Claude Code session (uncommon with branch protection enabled, but possible without
it, or via an `admin` bypass — see this repo's own release ritual above), that push is now
blocked. Two escape hatches: run that push from a plain terminal outside Claude Code, or set
`disableAllHooks: true` in a settings file — which also disables `git-c-guard.sh`'s and
`agent-boundary.sh`'s controls, so use it narrowly and briefly, not as a standing setting. No
grant, label, script, or baseline step is needed either way: the hook is plugin behaviour, not a
permission entry, so it applies automatically with the plugin update and the doctor reports
nothing to migrate for it. Everything else in this release adds no grant, label, script, or
baseline step either — the doctor reports nothing new to migrate for the rest. #235's two
documented limits are now measured (2026-09-08, Claude Code 2.1.263 —
see "Safety model"'s live-probe record): the `agent_type` spelling a plugin subagent sends in
`PreToolUse` stdin is the namespaced form, and this hook's `deny` does outrank
`git-c-guard.sh`'s `allow` for the same call. Both `agent_type` spellings still ship — the
namespaced one being the confirmed live form, the bare one retained as insurance against a future
de-namespacing — and nothing about the hook's behaviour changed. No consumer action either for
#255/#262's fix: `bin/check-harness.sh`'s piped `grep -q`/`find | grep -q` readers (the doctor's
own verdict-affecting checks — a marker-file lookup, an allow-list membership test) are rewritten
as here-strings or capture-then-test, so a writer killed by SIGPIPE under `pipefail` can no longer
invert one of the doctor's checks and report a false verdict on your repo. No consumer action
either for #246: `find-planning-work.sh` now retries its author-association REST lookup once,
after a single bounded backoff, before fail-closing the whole run — a script-internal behaviour
change with no new grant, label, script, or settings entry to migrate. No consumer action either
for #248: `dev/cleanup-tests.sh`'s own stub `gh` now validates `--json` field names against gh's
live-probed field set, a change to this repo's own test harness only — nothing a consumer's
checkout ships or runs. #249 IS a consumer-visible behaviour change, though it likewise needs no
grant, label, script, or baseline step: `cleanup-after-merge.sh`'s multi-PR comment-marker lookup
(`gh issue view --json comments`) no longer falls back to "no marker found" when it fails or
returns something that isn't valid JSON — during a rate-limit or auth blip on that one lookup, an
issue that previously auto-closed instead stays open with `pr-open` still attached until a later
successful run notices it (see "After the human merges" above). #245 IS a consumer-visible
behaviour change too, though it likewise needs no grant, label, script, or baseline step
(`Bash(sleep:*)` already ships in `templates/repo-settings.json`): the `issue-cycle` merge pass
now retries an **unknown** plan-binding verdict once before holding the PR — the same
bounded-retry rule #223 already gave the implementer's two checkpoints — so one transient GitHub
API blip no longer strands an approved, verifier-clean, CI-green PR until the next scheduled run
or a manual merge. Behaviour **widens** on exactly one axis: a PR a transient unknown would
previously have held for the rest of the pass can now merge in the same pass; a verdict still
unknown after the one retry still holds the PR **not eligible**, fail-closed exactly as before.
Cost is up to 30s plus one extra read-only discovery run, paid only on the PRs whose plan-binding
verdict comes back unknown. **#238 IS a consumer-visible behaviour change**, though it too needs no
grant, label, script, or baseline step: `skills/issue-implementer/SKILL.md`'s pre-push re-check
(step 2e) now accepts a **same-plan re-approval** landing while the implementer works — a human
removing and re-adding `plan-approved` without changing the approved plan comment. Behaviour
**widens**: the run no longer aborts, `plan-approved` is no longer removed, and this run's fresh
`binding_line` (not the one captured before dispatch) is what goes into the PR body. Any comment
the re-approval newly covers is surfaced verbatim (author, association, `createdAt`, `url`) in the
PR body and the run summary, flagged as covered by the re-approval but **not** implemented — the
human decides whether the PR is still what they want. A re-approval naming a *different* plan
comment is unchanged: a real change of plan, not a re-approval, still returns the issue to review
with `plan-approved` removed. The documented remedy for a comment the re-approval releases without
implementing it is unchanged from #213: **close the PR first, then re-approve**.

**v2.7.1 → v2.7.2** needs no grant, label, script, settings entry, or baseline step either (#275):
`find-implementation-work.sh` and `find-planning-work.sh` both now exclude a harness-authored
record (a comment that OPENS WITH `<!-- harness-audit -->` or `<!-- verifier-verdict -->`) from
plan selection, not just from the feedback/binding sets #182 already excluded it from — a
maintainer-authored audit or hygiene record that happens to quote the plan marker verbatim in its
own prose is no longer mistaken for the plan itself (see "Safety model" below for the
full behaviour, including the deliberate `contains`-vs-`startswith` asymmetry). The one
consumer-visible behaviour change: an issue whose only marker-carrying trusted comment is such a
record now reports `plan: null` (`reason: "no-plan"`) rather than binding to the record and
reporting whatever approval state that record happened to produce. Also in v2.7.2 (#270):
`hooks/push-guard.sh` and `hooks/agent-boundary.sh` both now strip every carriage return from
`tool_input.command` before tokenizing it, needing no grant, label, script, settings entry, or
baseline step. A CRLF-carrying command is now recognised and denied where the guard was
previously silent — a trailing `\r` on a destination, command word, or subcommand token (e.g.
`git push origin main\r`, `git\r push`, `gh\r …`) no longer evades either hook's exact-match
comparisons. The one loosening-direction consequence: a verifier subagent's `git status\r` is now
no opinion where it previously denied (fail-closed on a subcommand token no `git` invocation
could actually resolve to); the residual class the fix does not close — a CR *inside* a raw-stdin
fast-path literal, e.g. `git pu\rsh origin main` or `g\rit push`, whose escaped `\r` keeps the
substring the fast path scans for from ever appearing intact — is documented, not fixed, in each
hook's own header comment (`hooks/push-guard.sh`'s "Documented under-blocking classes" bullet and
`hooks/agent-boundary.sh`'s fast-path-2 comment), not in "Safety model" below. Also in v2.7.2
(#272/#273): `find-planning-work.sh`'s other three `gh` calls (the `needs_initial_plan` query, the
revision-candidates query, and the per-candidate `gh issue view` fetch) get the same bounded retry
#246 already gave the REST author-association lookup — one guarded 30-second backoff, one
re-attempt — before falling back to their existing behaviour. Two consumer-visible behaviour
changes, both needing no grant, label, script, settings entry, or baseline step: a momentary API
blip during a per-candidate fetch no longer drops that issue from the revision scan for the whole
run (it's simply retried once first); and a momentary blip on either `gh issue list` query no
longer aborts the run with no output at all — the query fails closed to an empty bucket
(`counts.initial_query_unavailable` / `counts.candidates_query_unavailable`) with a warn line on
stderr, and the run still prints a complete document with whatever half succeeded. A query that
fails BOTH attempts is not "nothing to do" — it's a degraded run — so `skills/issue-planner/
SKILL.md` step 1 and `skills/issue-cycle/SKILL.md`'s ledger-seed paragraph both now name these
flags explicitly. Also in v2.7.2 (#277): `skills/issue-cycle/SKILL.md`'s merge-floor *Archived
verdict* read (`gh issue view <n> --json comments`) gets the same bounded one-shot retry, needing
no grant, label, script, settings entry, or baseline step (`Bash(sleep:*)` and
`Bash(gh issue view:*)` already ship in `templates/repo-settings.json`). The one consumer-visible
widening: a PR a transient archive-read blip would have held for the rest of the pass can now
merge in the same pass instead; fail-closed is unchanged — a read still failing after the one
retry holds the PR not eligible exactly as before. Cost: up to 30s plus one extra read-only
`gh issue view` call, paid only on a PR whose archive read fails. Also in v2.7.2 (#240):
`find-implementation-work.sh` now pre-filters both the #192 plan-comment edit check and the #230
decision-comment edit check on gh's own per-comment `includesCreatedEdit` boolean — already present
in the `comments` field the script fetches today, at no extra API cost — needing no grant, label,
script, settings entry, or baseline step. A comment gh itself reports as never edited
(`includesCreatedEdit: false`) skips the REST `updated_at` lookup entirely and stays covered; a
comment gh reports as edited, or on which gh omits the flag entirely (every gh version predating
this field), keeps today's lookup and every existing fail-closed state unchanged. The one
consumer-visible improvement, the point of the issue: on a busy thread with many covered decision
comments, per-run lookups drop from one-per-covered-comment to one-per-*edited*-covered-comment,
bounding the API cost the #230/#192 workstreams added and reducing the odds an unattended
overnight run trips GitHub's secondary rate limit. Honest limit: this is a tripwire, not a
control — see "Safety model" below for the residual fail-open class. Also in v2.7.2 (#268):
`hooks/push-guard.sh` now text-parses the common dir's `config` file (never executed as `git
config`) for `remote.<name>.push` and `push.default`/`branch.<n>.merge` whenever a push segment
carries no explicit refspec, needing no grant, label, script, settings entry, or baseline step.
The consumer-visible widening: a repo whose `.git/config` carries `remote.origin.push =
HEAD:main`, or `push.default = upstream`/`tracking` with the current branch's upstream on the
default branch, now has a bare `git push` denied where this hook was previously silent — see
"Safety model" for the full behaviour, including the deliberate over-blocking union (a bare push
checks every configured remote's route, not only the one git would pick) and the two new
over-blocking classes (`push.default = matching`, a wildcard configured destination). The
residual gap: a GLOBAL or system git config (`~/.gitconfig`, `/etc/gitconfig`, etc.) setting
either key is not yet read (filed as a follow-up alongside this change). **Closed in v2.7.3 by
#290** for the GLOBAL half (`$GIT_CONFIG_GLOBAL`, `$XDG_CONFIG_HOME/git/config` or its default, and
`$HOME/.gitconfig`); the SYSTEM half (`/etc/gitconfig`) remains a follow-up. Also in v2.7.2 (#269):
`hooks/push-guard.sh` now resolves a push segment's own `git -C <path>` value too, but only when
it satisfies the same `PATH_ERE` predicate `hooks/git-c-guard.sh` already enforces for its own
worktree-parallel allow forms — the gate mechanically pins the two declarations byte-identical.
The consumer-visible widening: a `git -C <name>-wt-<n> push` into a sibling worktree or an
entirely separate checkout is now judged against THAT checkout's own default branch (and, for the
current branch and any REPO-LOCAL `.git/config` route, THAT checkout's own facts) rather than only
the session's — the deny-set's default-branch member becomes the union of the session's own default
and the resolved checkout's own default, never a pure replacement, so a target lacking its own
`refs/remotes/origin/HEAD` cannot silently lose today's guard. Two narrowings ship alongside it: a
bare `git -C <worktree> push` no longer denies merely because the SESSION happens to sit on its
own default branch (worktree-parallel mode's real shape, where the session stays on the default
branch while worktrees carry `claude/<n>-<slug>`); and a resolved segment no longer inherits the
session's own REPO-LOCAL `.git/config` routes (since v2.7.3/#290, this qualification is repo-local
only — the GLOBAL config candidates apply identically to every checkout resolved, session or
target). Residual, disclosed rather than hidden: a `-C` path that
doesn't match the predicate — including a plain `git -C ../other-checkout push` with no `-wt-<n>`
suffix — and `--git-dir=<path>`/`--work-tree` are still judged only against the session, and a
predicate-matching directory holding no `.git` of its own is judged against the session too, since
this resolution never walks upward the way git itself would from a real `-C`; both classes are
filed as a follow-up alongside this change.

**v2.7.2 → v2.7.3** needs no grant, label, script, settings entry, or baseline step (#284/#285):
`find-implementation-work.sh` gets the identical bounded-retry-then-fail-closed shape #272/#273
gave `find-planning-work.sh`, applied to its own two `gh` call sites — the batch `ready` query and
the per-issue `gh issue view` inside the ready loop. The consumer-visible behaviour change: a
momentary API blip during the ready query no longer aborts the run with no output at all (it fails
closed to an empty `ready` bucket, `counts.ready_query_unavailable`, with a warn line on stderr,
and the run still prints a complete document), and a momentary blip on a per-issue fetch is
retried once before that issue is skipped for the run (`counts.fetch_retries`;
`counts.fetch_failures` now counts only post-retry failures). `--issue <n>` mode's own prefetch is
deliberately NOT retried — both its callers (the issue-implementer skill's dispatch/pre-push
re-check and the issue-cycle merge floor) already re-run the whole script once on an unknown
verdict. A query that fails both attempts is not "nothing to do" — it's a degraded run — so
`skills/issue-implementer/SKILL.md` step 1 and `skills/issue-cycle/SKILL.md`'s ledger-seed
paragraph both now name this flag (the ledger-seed paragraph alongside the planner's own two; the
implementer's step 1 names only this script's own flag). Also in v2.7.3 (#285):
`harness-status.sh` — the consumer both discovery scripts already have — gains a top-level
`degraded` boolean and `degraded_reasons` array (`"planning.<key>"` / `"implementation.<key>"`
strings), computed by a GENERIC rule (every key in either script's own `counts` object whose name
ends in `_unavailable` and whose value is exactly `true`, so it already covers
`initial_query_unavailable`, `candidates_query_unavailable`, `author_association_unavailable`, and
#284's own `ready_query_unavailable` with no per-key enumeration to drift), plus `counts.degraded`
mirroring the same boolean — see "Returning to a laptop" above. Also in v2.7.3 (#287):
`skills/issue-cycle/SKILL.md`'s merge-floor transient-failure retry, previously stated per-read
for only two of its six provenance reads (the *Archived verdict* archive read, #277; the
*Plan-binding provenance* discovery run, #245), now covers all six, stated once at floor level —
the *Verdict provenance* needle pair, the head-branch key read, the archive read's own match
needle, and the discovery run's binding-line walk needle join the two reads already covered,
needing no grant, label, script, settings entry, or baseline step (`Bash(sleep:*)`,
`Bash(gh pr view:*)`, `Bash(gh issue view:*)`, and `find-implementation-work.sh` already ship in
`templates/repo-settings.json`). The consumer-visible widening: a PR a transient blip on any of
the four newly covered reads would have held for the rest of the pass can now merge in the same
pass instead; fail-closed is unchanged — a read still failing after the one retry holds the PR
**not eligible**, same one-line reason, exactly as before, and a determinate answer (a `false`
needle, a `false` `covers_plan`, a `none` archive line, or a wrong-prefix archived status line) is
never retried. Cost: up to 30s plus one extra read-only call per failing read, paid only on a PR
whose read fails — worst case six such waits in a single pass. Also in v2.7.3 (#281): plan
selection on both discovery scripts is now a positive, first-line anchor on the plan marker
itself, superseding #275's harness-marker exclusion — see "Safety model" below for the full shape.
The consumer-visible behaviour change: a hand-posted plan comment with anything before the
`<!-- planner-plan -->` marker is no longer selectable as the plan (repost it with the marker as
the comment's first line); a trusted comment that quotes the plan marker mid-body without opening
with it is now silently excluded from both plan selection and the feedback/binding sets, with no
warning (a filed follow-up). No published JSON key, `counts` key, or `reason` string changes.
**Closed in v2.7.4 by #302**: both scripts now print one `warn:` line (naming its author,
createdAt, and url) for every such trusted, in-window comment that carries neither harness-record
marker of its own, and publish an additive `counts.plan_marker_quoters` key counting them — a
comment that also carries `<!-- harness-audit -->` or `<!-- verifier-verdict -->` (a harness
record, or a maintainer's prose-then-harness-marker copy of one) is excluded from the warn, the
same way it was already excluded from the feedback/binding sets. **Also in v2.7.6 (#321)**: of
that excluded class, only the comment that carries a harness-record marker without opening with it
(a maintainer's own prose-then-harness-marker copy) gets its own twin warn and an additive
`counts.harness_marker_quoters` key; a genuine harness-authored record, which opens with its own
marker, is counted in neither key and is not warned about, as before — see "Also in v2.7.6 (#321)"
below for the full shape.
Also in v2.7.3 (#290): `hooks/push-guard.sh`'s #268 config read is extended to three GLOBAL
candidates — `$GIT_CONFIG_GLOBAL` (when set and non-empty), `$XDG_CONFIG_HOME/git/config` (or,
when `$XDG_CONFIG_HOME` is unset or empty, `$HOME/.config/git/config`), and `$HOME/.gitconfig` —
unioned with the repo-local `.git/config` routes #268 already read, needing no grant, label,
script, settings entry, or baseline step. The consumer-visible widening: a developer whose
`~/.gitconfig` (or `$GIT_CONFIG_GLOBAL`/`$XDG_CONFIG_HOME` target) sets
`push.default = upstream`/`tracking` with the current branch's upstream on the default branch,
`push.default = matching`, or a denying `remote.<name>.push` refspec now gets a bare `git push`
denied where this hook was previously silent, including for a resolved `-C` segment (the global
candidates are read
identically for every checkout resolved, session or target). The deny message now names its own
source — `.git/config` or "your global git config" — instead of always claiming the repo-local
file. Three new over-blocking classes, alongside #268's own: `$GIT_CONFIG_GLOBAL` is unioned with
(never a replacement for) the other two global paths; a repo-local AND a global `push.default`
value are both evaluated, so a benign value in one file can never mask a denying value in the
other; and two `push.default` lines inside ONE file are likewise both evaluated, so this hook does
not model git's own last-wins precedence within a single file either — a config's LAST
`push.default` line no longer overrides an earlier one in that same file. The residual gap: a
SYSTEM git config (`/etc/gitconfig`) and `include`/`includeIf` directives inside any of the four
files this hook now reads remain unread, each filed as its own follow-up.

**v2.7.3 → v2.7.4** needs no grant, label, script, settings entry, or baseline step (#297/#298).
Two behaviour changes: `harness-status.sh` gives its OWN three queries — plan-proposed,
impl-blocked, and the open-PR list — the identical bounded-retry-then-fail-closed shape
#272/#273/#284 already gave the two discovery scripts, publishing six new `counts` booleans
(`proposed_query_retried`/`_unavailable`, `blocked_query_retried`/`_unavailable`,
`prs_query_retried`/`_unavailable`) and extending `degraded_reasons` with a third, `"status.<key>"`
half after the planning and implementation halves. Worst case this adds
to `harness-status.sh`'s own run: 3 × 30s = 90s (all three sites fail twice); in a broad outage
where every list query anywhere fails twice, the total across one `harness-status.sh` invocation
rises to about 210s. Second: `reconcile-ledger.sh` now reads `degraded`/`degraded_reasons` from
the status JSON it compares against and refuses to report a clean reconciliation on a degraded
document — one new `degraded issue=- bucket=- stage=-: ...` line per `degraded_reasons` entry
that does NOT start with `"status."` (a `"status."` entry describes a `waiting_on_human` bucket
this reconciliation never compares, and never refuses on its own), printed before any per-issue
line, forcing exit 1; a `degraded: true` document whose `degraded_reasons` is empty or absent gets
one `unspecified` line instead of silence (a document whose reasons are all `"status."`-prefixed
still stays silent, exit 0 — the backstop fires only on an empty/absent array, never on a
filtered-to-nothing one). The consumer-visible fix: before this change, a discovery query that failed
both attempts (already silently fail-closed since v2.7.2's #272/#273) could make the closing
reconciliation report "every queued issue accounted for" even though the affected bucket had
silently dropped an issue — `skills/issue-cycle/SKILL.md`'s closing-reconciliation per-class list
and its two-halves report both now name this `degraded` class. Also in v2.7.4 (#300): the merge
floor's one-shot transient-failure retry (#245, #277, #287) now also covers the `gh pr checks`
read, the up-to-date rail's `gh pr view` read, the base-branch read and its one-time
default-branch lookup, and the merge-landed read — needing no grant, label, script, settings
entry, or baseline step (`Bash(sleep:*)`, `Bash(gh pr checks:*)`, `Bash(gh pr view:*)`, and
`Bash(gh repo view:*)` already ship in `templates/repo-settings.json`). The consumer-visible
change: a PR an API blip held for the rest of a pass can now merge in the same pass instead, and
a blip on the merge-landed read no longer reports a PR that actually merged as `merge attempted,
unconfirmed`. Answers are never retried — per-check results in any state (pending, exit 8, and
failing included) or a no-checks report from `gh pr checks`, a base mismatch, and any state other
than `MERGED` all count as an answer. Cost: up to 30s plus one extra read-only call per failing
read. Also in v2.7.4 (#302): both discovery scripts now diagnose one class #281 dropped with no
report of its own — a TRUSTED comment posted after the latest plan (or, when there is none, at any
time) whose body contains the plan marker somewhere other than its first line, and whose body
carries neither harness-record marker (`<!-- harness-audit -->` or `<!-- verifier-verdict -->`) —
printing one `warn:` line per such comment (author, createdAt, and url, or the literal "no url")
and publishing an additive `counts.plan_marker_quoters` key on both scripts, needing no grant,
label, script, settings entry, or baseline step. A trusted comment in that same window that DOES
carry a harness-record marker (a genuine harness-authored record, or a maintainer's
prose-then-harness-marker copy of one) is still excluded from both the warn and the count, exactly
as it already was from plan selection and the feedback/binding sets — since v2.7.6 (#321, see
below), only the prose-then-harness-marker-copy half of that narrower class gets its own twin
diagnostic; a genuine harness-authored record, which opens with its own marker, is still counted in
neither key and still not warned about. The consumer-visible change: a maintainer who quotes the
plan marker in feedback without opening the comment with it, or hand-posts a plan with prose before
the marker, now sees why the planner or
implementer skipped their comment instead of silence, unless that same comment also carries a
harness-record marker. The comment is still never acted on either way — see "Safety model" below
for the unchanged, security-relevant part of this behaviour.
Also in v2.7.4 (#307, ADR 0001 decision 9): under a Merge autonomy policy, the merge floor's
*Never the governance surface* rule gains its one exception, the *Lesson-append carve-out* —
needing no grant, label, script, settings entry, or baseline step (`Bash(gh pr view:*)`,
`Bash(git diff:*)`, and `Bash(gh issue comment:*)` already ship in `templates/repo-settings.json`).
The consumer-visible widening: a harness PR whose only governance-surface change is an
end-of-file, add-only append to `.claude/LESSONS.md` of at most 40 lines with no `<!--` in them
no longer waits for a human on that account alone; a PR that also touches any other governance
path, or whose `.claude/LESSONS.md` diff edits, reorders, or deletes any existing line, still
does, unchanged. Every carve-out merge is quoted word for word — both in the cycle report and in
a durable `<!-- harness-audit -->` issue comment posted after the merge lands — so a released
lesson is never merged silently. Honest limit: the new gate assertion (5.15) executes only the
files-check verdict program; both the end-of-file diff rule (check 2) and the content judgement
(check 3, that the added lines read as only a project gotcha, never an instruction) are prose the
orchestrator applies and the gate does not pin.

**v2.7.4 → v2.7.5** needs no grant, label, script, settings entry, or baseline step (#323). An
implementer or verifier subagent's `.claude/LESSONS.md` change now blocks the issue instead of
riding into the `feat:` commit: `skills/issue-implementer/SKILL.md`'s new *LESSONS.md dispatch
guard* snapshots the file immediately before each dispatch and compares it on that dispatch's
return, death, or `incomplete` exit; any output there takes the existing blocked path (step 2f),
never a silent commit — unless the file already existed untracked before the dispatch, in which
case the guard has no baseline to take and leaves it unstaged for a human to commit instead. The
orchestrator's own
distilled lesson (step 2e) is unchanged — it still runs after an issue's last dispatch and appends
only when that same compare prints nothing.
Honest limit: this is orchestrator prose, not a hook — it catches the change after the dispatch
returns rather than preventing the write; no `Edit`/`Write` PreToolUse hook exists yet.
**Closed in v2.7.6 by #327**: `hooks/claude-dir-guard.sh` denies the `Edit`/`Write` itself, for
both roles, whether or not `.claude/LESSONS.md` is tracked — see that section below. The
Bash-issued-write route (`cat >>`, `tee`, `sed -i`) is unaffected and still depends solely on the
dispatch guard described here, untracked-baseline gap included.
Also in v2.7.5 (#324, #319): needs no grant, label, script, settings entry, or baseline step
(`Bash(git diff:*)`, `Bash(git fetch:*)`, and `Bash(sleep:*)` already ship in
`templates/repo-settings.json`). Two consumer-visible changes, both of which **narrow** what
merges unattended. First (#324): the merge floor's *Never the governance surface* rule now reads
what "touching" means mechanically — `git diff --no-renames --name-only` over the up-to-date
rail's own base-tip/head-OID pair, so a rename (which reports under both its old and new path)
and a `gh`-reported file list (page-limited and rename-blind) can no longer let a governance-file
move slip past prose judgement; a PR that touches any `.github/` path, a nested `.claude/` or
`CLAUDE.md`, or renames a governance file elsewhere now holds where it might previously have
been judged clear. Second (#319): a `git fetch origin` still failing after its one retry now
holds the PR ("could not fetch origin — not comparing against a stale `<default>` tip") instead
of risking a comparison against a stale `origin/<default-branch>` tip. Honest limit: gate
assertion 4.43 pins only the presence and exact spelling of the `git diff --no-renames
--name-only` command line in `skills/issue-cycle/SKILL.md` — never the path-match rules or the
residual "any doubt holds" judgement, which stay prose the orchestrator applies.

Also in v2.7.5 (#308): needs no new grant, label, script, settings entry, or baseline step
(re-running `bin/setup-labels.sh` is optional — it only refreshes the `no-auto-approve` label's
description). `no-auto-approve` was overloaded: the harness applied it routinely to every
follow-up it filed, so a maintainer's own veto use of the same label got set aside once those
follow-ups were triaged. Three behaviour changes fix that. (1) A follow-up the implementer files
from a PR's "Follow-ups to file" now carries `no-plan`, not `no-auto-approve` — held out of
planning entirely until a human triages it and removes the label (see "Returning to a laptop").
Once that removal happens, no other hard-floor clause is keyed to the follow-up's own provenance,
so its plan becomes auto-approvable like any other issue's under the repo's own policy — triage
is the human gate (ADR 0001 decision 4). (2) An issue the test-suite ratchet files now carries
`test-ratchet` alone; the planner's auto-approval hard floor gained a clause refusing any issue
carrying that label outright, and the harness never removes it, so a ratchet plan waits for a
human. (3) `no-auto-approve` is now applied only by a human, in every mode — the harness never
applies it itself, so when you do add it, it stays a real, standing veto. Narrowing to know: a
human can no longer opt a `test-ratchet` issue *into* auto-approval by removing
`no-auto-approve`, because the hold moved to the `test-ratchet` label itself, which the harness
never removes; releasing such an issue now means a human deliberately stripping `test-ratchet` by
hand (which also drops it from the ratchet's own backlog cap and veto memory). Approving a
ratchet plan by hand is unaffected. An open `test-ratchet` issue still carrying the old
`no-auto-approve` label from before this hop needs no action — the hard floor now refuses it
regardless of that label's presence.

One-time migration, for open issues an older harness version filed as follow-ups (skip if none
are returned):

```bash
gh issue list --search "is:open is:issue label:no-auto-approve" --json number,body --limit 200 \
  --jq '.[] | select(.body | startswith("<!-- harness-follow-up:")) | .number'
# then, per issue number printed above:
gh issue edit <n> --add-label no-plan --remove-label no-auto-approve
```

`--limit 200` caps the listing at 200 results — gh's own default is 30 — so a repo with more than
200 such issues open at once should raise the limit and run it again; the listing above is not
claimed exhaustive beyond that count. Both labels move in the same `gh issue edit` call
deliberately: removing `no-auto-approve` alone would leave an untriaged, machine-authored issue
eligible for auto-approval the moment a policy exists, while adding `no-plan` in that same edit
is what keeps it held until a human triages it. Two honest limits carry over from the behaviour
changes above:
`harness-status.sh` had no bucket or count for a held follow-up (superseded by #333, below, and
narrowed again by #346 — since v2.7.7 the bucket is untriaged-only and counted inside
`counts.human_actions`; see the v2.7.6 → v2.7.7 notes below), and `cleanup-after-merge.sh`'s
follow-up quarantine — the "source PR
closed without merging" comment — never reached a follow-up filed with `no-plan` from birth,
since the same `-label:no-plan` exclusion that made `--fix` idempotent also excluded it (superseded
by #334, below — since v2.7.6 the quarantine's idempotence key moved off that label onto a
trusted, PR-keyed orphan-notice marker instead, so it now reaches a follow-up born `no-plan` too).

**v2.7.5 → v2.7.6** needs no grant, label, script, settings entry, or baseline step (#336). No
consumer action is required: of the three files this change touches — `bin/reconcile-ledger.sh`,
the gate (`dev/selfcheck.sh`), and the gate's own negative-test harness
(`dev/selfcheck-tests.sh`) — the only one a consumer repo runs is `bin/reconcile-ledger.sh`, and
it changes only on an error path: an unreadable path still dies with the same message and the
same exit 2 as before, plus the directory case described later in this paragraph. Two changes,
in order. First,
`reconcile-ledger.sh`'s ledger and status-JSON reads drop their `access()`-style readability
pre-test on the caller-supplied path (both arguments accept any path, including a
process-substitution `<(...)` — this repo's own gate passes exactly that) in favour of attempting
the read directly and dying on failure with
the identical message and exit code as before — the pre-test raced on macOS (roughly 1 in 2000)
when several processes touched `/dev/fd` at once, which is exactly what running this repo's own
gate concurrently now does; the read itself never failed under that same load. Incidentally, a
*directory* argument now dies too (exit 2, `cannot read ledger file`); previously it exited 0
with an empty ledger, with only `cat`'s own "Is a directory" message on stderr. Second,
`dev/selfcheck-tests.sh` runs its case rows concurrently by default, in bounded waves: the job
count is detected from the host's core count (clamped to at most 16, falling back to 2 when no
probe answers), overridable with `SELFCHECK_TESTS_JOBS=<n>` or `-j <n>`, and `--serial` (`-j 1`)
restores one case at a time. Declared case order, not completion order, still decides the
PASS/FAIL line sequence and the summary totals; a case whose child dies before reporting a
verdict is still counted as a FAIL naming the case, never silently dropped. The single-case/filter
form (`bash dev/selfcheck-tests.sh <case>`) is unchanged.

Also in v2.7.6 (#327): needs no grant, label, script, settings entry, or baseline step. A fourth
plugin-shipped `PreToolUse` hook, `hooks/claude-dir-guard.sh`, now denies an implementer or
verifier subagent's `Edit` or `Write` to any `.claude/` path — see "Safety model" below (the
"**Four PreToolUse hooks**" paragraph and its new fourth-hook paragraph) for the deny classes,
the no-filesystem-access property, and its own `cdg-*` fixture family in `dev/hook-tests.sh`.

Also in v2.7.6 (#321): needs no grant, label, script, settings entry, or baseline step. Both
discovery scripts diagnose the one class #302 deliberately left unwarned: a trusted, in-window
comment that carries a harness-record marker (`<!-- harness-audit -->` or `<!-- verifier-verdict
-->` — the set is now one shared declaration, `HARNESS_RECORD_MARKERS`, on both scripts) somewhere
in its body without opening with one — a maintainer quoting a harness-authored record, typically
to dispute it, not a record itself. Both scripts print one `warn:` line per such comment (author,
createdAt, and url, or the literal "no url") and publish an additive
`counts.harness_marker_quoters` key, disjoint from `counts.plan_marker_quoters` (a comment quoting
both markers is counted in exactly one). New gate assertion 4.46 pins that the two scripts'
`HARNESS_RECORD_MARKERS` declarations stay byte-identical. See "Safety model" below for the full
shape and its residual honest limit (a comment that itself opens with a verbatim marker copy at
byte 0 is still indistinguishable from a genuine harness record, and stays silently dropped).

Also in v2.7.6 (#333): needs no grant, label, script, settings entry, or baseline step.
`harness-status.sh` gains a fourth `waiting_on_human` bucket, `followups_to_triage` — open,
`no-plan` issues whose body opens with the harness-filed follow-up marker (#308) — fed by a fourth
`gh issue list` call with the identical bounded-retry-then-fail-closed shape the other three sites
already have, publishing `counts.followups_query_retried`/`counts.followups_query_unavailable` and
a `"status.followups_query_unavailable"` `degraded_reasons` entry appended after the three existing
status-half entries. `counts.human_actions` deliberately does NOT include this bucket: the query
cannot tell a follow-up nobody has triaged yet from one a maintainer already read and decided to
keep held (both keep `no-plan` and the marker forever), so folding it into the total would mean the
total could never return to zero in a repo with any parked follow-up (measured on this repo
2026-09-17: the filter matched 10 issues, every one already triaged and parked) — see "Returning to
a laptop" above for the reader-facing shape and honest limits (parked follow-ups keep counting, a
label edit can leave a just-filed entry missing from one run — measured once on this repo,
2026-09-17: a `gh issue list --search` run made right after a label edit missed an issue that a
later run returned; whether a just-triaged entry can likewise linger was not measured — and
`--limit 100` caps the listing). Since v2.7.7 (#346, see the v2.7.6 → v2.7.7 note below), the
query additionally excludes a new `triaged-held` label, narrowing this bucket to untriaged-only,
and `counts.human_actions` now DOES include it.

Also in v2.7.6 (#309): **needs a label step** — re-run `bin/setup-labels.sh` on any repo already
running an earlier harness version, so the new `needs-human` label exists before the next cycle;
this hop is not a no-op the way the four v2.7.6 notes above are (#336, #327, #321, #333) (measured
on this repo, 2026-09-19, before the label existed: a search naming a label the repo does not have
is harmless — the ready and needs_initial_plan queries returned identical results with and without
` -label:needs-human`, and the positive query returned `[]`, all rc 0. So a consumer who skips this
step keeps a working discovery and an empty `escalations` bucket; what actually fails is the
escalation's own `gh issue edit --add-label`). These sites in `skills/issue-implementer/SKILL.md`
(a contradicting trusted comment, a branch with committed work and no open PR, an unanswered
BLOCKING question, red CI after the one bounded fix attempt or unrelated to the PR, and a denied
`gh pr edit`) now escalate durably instead: posts an issue comment whose first line is exactly
`<!-- harness-escalation -->` and second line the key template
`<!-- harness-escalation-key: issue=<n> stage=<stage> reason=<slug> comments=<ids> -->`, labels the
issue `needs-human`, and continues with the next issue — see the "Durable escalation" subsection
under `skills/issue-implementer/SKILL.md`'s "Resilient dispatch" for the full procedure, the closed
`<stage>`/`<reason>` vocabulary, and the label rules. Step 2b's open-PR sub-branch is deliberately
left as skip-and-warn, not escalated (it writes nothing to GitHub); the run-level dirty-tree and
red-baseline stops halt the whole run before any issue is processed, so there is no issue yet to
escalate on — and the step 2f blocked path is untouched: its comment stays deliberately unmarked
and carries no `needs-human` label. The
`needs-human` label IS the dedupe: all three discovery queries (`find-planning-work.sh` ×2,
`find-implementation-work.sh` ×1) exclude it, so an escalated issue is out of the workflow until a
human answers and removes the label.
`harness-status.sh` gains a fifth `waiting_on_human` bucket, `escalations` — open `needs-human`
issues, served verbatim with no filter — fed by a fifth `gh issue list` call with the identical
bounded-retry-then-fail-closed shape the other four sites already have, publishing
`counts.escalations_query_retried`/`counts.escalations_query_unavailable` and a
`"status.escalations_query_unavailable"` `degraded_reasons` entry appended after the four existing
status-half entries. Unlike `followups_to_triage`, `counts.human_actions` DOES include this
bucket — see "Returning to a laptop" above for the reader-facing shape and its own honest limit
(an issue carrying `needs-human` alongside `plan-proposed` or `impl-blocked` counts twice until you
remove one of the two labels). Both discovery scripts' `HARNESS_RECORD_MARKERS` set (see "Also in
v2.7.6 (#321)" above) gains a third marker, `<!-- harness-escalation -->` — distinct from, and
never cross-matched with, the planner's own pre-existing `<!-- harness-escalation: bucket=...
stage=... -->` key — so a durable-escalation record and a comment quoting it are both excluded from
feedback/`trusted_post_plan` (counted in a new, additive `counts.escalation_records_skipped` key,
the identical shape `counts.audit_comments_skipped`/`counts.verdict_archives_skipped` already use)
and covered by #321's own quoter warning. New gate assertion 4.48 pins that the `ESCALATION_LABEL`
constant is declared identically in all three scripts, is one of the labels `bin/setup-labels.sh`
creates, is excluded by every discovery `--search` line, and is named in
`skills/issue-implementer/SKILL.md`. Since v2.7.7 (#346, see the v2.7.6 → v2.7.7 note below),
`followups_to_triage` joined `escalations` in the `counts.human_actions` sum too, by the identical
mechanism.

Also in v2.7.6 (#310): **needs two consumer actions** — re-copy the permissions block from
`templates/repo-settings.json` (or add `"Bash(harness-stop.sh:*)"` by hand) so the new script is
grantable, and re-run `bin/setup-labels.sh` so the `harness-stop` label exists. A new, read-only
script, `bin/harness-stop.sh`, is a maintainer-settable stop switch checked before each stage and
before each merge — see "Stopping a cycle" above for the reader-facing shape (both routes, the
set/clear commands, the union rule, the honest limits) and "Label lifecycle" above for the label
itself. It takes no subcommand and no mutating flag, on purpose (ADR 0001 decision 8): every
`bin/*.sh` script is granted to the model as `Bash(<name>.sh:*)`, so a mutating subcommand here
would hand the model a way to lift the maintainer's own veto. New gate assertion 4.49 pins that
its `STOP_LABEL` value is one of the labels `bin/setup-labels.sh` creates, and that no
`--label`/`--add-label`/`--remove-label` argument naming it appears anywhere in
`skills/*/SKILL.md`, `skills/*/references/*.md`, `agents/*.md`, or `bin/*.sh` — the same shape
4.44 already enforces for `no-auto-approve`, widened to also catch `--remove-label` (4.44's own
ERE has no `--remove-label` arm). `skills/issue-cycle/SKILL.md` gained a canonical "Stop switch"
section plus checks at the step-0, pre-implementation, pre-merge-pass, per-PR and pre-ratchet
boundaries; `skills/issue-implementer/SKILL.md` and `skills/issue-planner/SKILL.md` each gained
one check at their own per-issue dispatch sites, citing that section rather than restating it.
`dev/stop-tests.sh` is the new eighth CI command — see CLAUDE.md's "Verification" section.
Measured on this repo (gh 2.97.0, 2026-09-21) while the `harness-stop` label did not yet exist:
`gh issue list --label harness-stop --state open --json number,title,url --limit 20` returned
`[]` with exit 0 and `harness-stop.sh` printed `stop=false` — so a consumer who has not yet
re-run `bin/setup-labels.sh` gets no spurious stop; until they do, `bin/check-harness.sh` FAILs
on the missing label.

Also in v2.7.6 (#334): needs no grant, label, script, settings entry, or baseline step.
`cleanup-after-merge.sh`'s follow-up orphan-notice quarantine now reaches a follow-up born
`no-plan` (#308) too. The candidate search drops its `-label:no-plan` exclusion (now `is:open
is:issue -label:pr-open`, `--json number,title,body,labels`), and for each candidate whose body
names a closed-unmerged `claude/*` PR, a per-candidate `gh issue view --json comments` lookup
treats it as already noticed iff a trusted (OWNER/MEMBER/COLLABORATOR) comment already carries
that PR's own `<!-- harness-orphan-notice: PR #<n> -->` marker — the same trust gate and #249
fail-closed shape (WARN once naming the failure route, leaving the issue exactly as found) the
multi-PR comment-marker path already uses; an untrusted marker is ignored and WARNed the same way
too. Not yet noticed, `--fix`: comments (with both marker lines) and adds `no-plan` only when it
isn't already present. New gate assertion 4.47 pins the marker's fixed-string prefix in the
script and this README, mirroring 4.16/4.17. One-time migration effect: a follow-up the pre-#308
path already quarantined carries the OLD notice comment, which has no orphan-notice marker, so the
first `--fix` run after upgrading posts one more, near-identical notice on it; every run after
that posts nothing, since the new marker is now present — provided the account running `--fix` is
itself OWNER/MEMBER/COLLABORATOR on the repo (`TRUSTED_ASSOCIATIONS`, the same trust gate this
paragraph's WARN already describes): measured on this repo (gh 2.97.0, 2026-09-21), `gh` returns
`authorAssociation` on issue comments and the harness's own comments here are `OWNER`. On a repo
where that does not hold, the harness's own notice comment never counts as already-noticed, so
each `--fix` run posts another one and prints the untrusted-marker WARN naming that comment.

**v2.7.6 → v2.7.7** needs no grant, label, script, settings entry, or baseline step for the model
pin itself (#358) — but this hop as a whole is not a no-op: see "Also in v2.7.7 (#346)" below,
which needs a label step. The `planner` and `verifier` subagents' frontmatter `model:` pin
moves from `claude-opus-5` to `claude-opus-5-5` (Claude Opus 5.5); the `implementer` stays on
`claude-sonnet-5`. The pins are
full model IDs on purpose, not the `opus`/`sonnet` aliases Claude Code also accepts: an alias
resolves to a provider-chosen "recommended" version that changes over time and differs between
the Anthropic API and Bedrock/Vertex/Foundry, so a consumer could not tell from this repo's
history which model verified a given PR. Installing the update is the whole migration for the
pin — the pins travel with the plugin (see "Distribution"); a consumer whose provider does not yet
serve `claude-opus-5-5` should stay on v2.7.6 until it does.

Also in v2.7.7 (#346): **needs a label step** — re-run `bin/setup-labels.sh` on any repo already
running an earlier harness version, so the new `triaged-held` label exists before the next cycle;
until then `bin/check-harness.sh` FAILs on the missing label (the same shape as #310's
`harness-stop`, above), though `harness-status.sh`'s own held-follow-up query degrades gracefully
(see below). `harness-status.sh`'s `list_followups()` query gains a `-label:$TRIAGED_HELD_LABEL`
exclusion, narrowing the `followups_to_triage` bucket to untriaged-only, and the `$excluded`
binding that used to name `followups_to_triage` is emptied, so the bucket now joins
`counts.human_actions` by the same generic rule `escalations` (#309) already used — see "Returning
to a laptop" and "Label lifecycle" above for the reader-facing shape, the park/unpark commands, and
the honest limits. Measured on this repo, 2026-09-22, before the label existed:
`gh issue list --search "is:open is:issue label:no-plan" --json number,title,url,body --limit 100
| jq length` and the same query with ` -label:triaged-held` appended both returned 19, all rc 0,
and `gh label list` showed no `triaged-held` label — so a consumer who skips this step still gets a
working, merely un-narrowed bucket (every harness-filed follow-up, triaged or not, counts), not a
broken one. New gate assertion 4.50 pins the label's vocabulary end to end and that no
`--label`/`--add-label`/`--remove-label` argument names it in `skills/*/SKILL.md`,
`skills/*/references/*.md`, `agents/*.md`, or `bin/*.sh`, the same shape 4.48/4.49 already give
`needs-human`/`harness-stop`. **Migration note:** this label is new — no already-parked follow-up
carries it yet, so on upgrade every follow-up you have already triaged and decided to keep held
counts as untriaged (and therefore in `counts.human_actions`) until you label it `triaged-held` by
hand; there is no automatic migration of pre-existing parked state. (#362) The label's description
as first merged was 109 characters, over GitHub's 100-character API limit, so `bin/setup-labels.sh`
aborted at it with HTTP 422 and never created the label — fixed before the v2.7.7 release, with new
gate assertion 1.8 pinning every description in that script at 100 characters or fewer.

Also in v2.7.7 (#353): needs no grant, label, script, settings entry, or baseline step.
`harness-status.sh` gains a SIXTH check — not a sixth `gh` call site, it still makes exactly five —
one `bin/harness-stop.sh` invocation, fed by that script's own stdout grammar rather than a second
query and never retried at this layer (`bin/harness-stop.sh` already performs its own one bounded
retry). The status JSON gains a top-level `stop` object (`{state, reason, exit_code}` — `state` is
one of `bin/harness-stop.sh`'s own three tokens, `"false"`/`"true"`/`"unknown"`, or this script's
OWN `"unavailable"` slug for every outcome that script never prints) and a new
`waiting_on_human.stop_routes` array (one `{route, clear}` entry per SET carrier, both fields
pasted verbatim, never re-derived), plus `counts.stop_routes` and, in the status-half `$sf` object,
`counts.stop_check_unavailable` (appended last, so its own `status.stop_check_unavailable`
`degraded_reasons` entry — when present — is always the array's last entry too). `stop_routes` was
never named in the `human_actions` exclusion list either, so a SET stop with N carriers joins the
sum too, by the identical generic rule `escalations` and `followups_to_triage` already use — see
"Returning to a laptop" above for the reader-facing shape and its own honest limits. New gate
assertion 4.51 pins that the stop-grammar tokens `harness-status.sh` parses appear as fixed
strings in `bin/harness-stop.sh`'s source.

Also in v2.7.7 (#355): needs no grant, label, script, settings entry, or baseline step. A failed
`gh issue comment`/`gh issue edit`/`gh issue close` inside `cleanup-after-merge.sh --fix` no
longer aborts the run: each write is now best-effort, exactly like the script's own pre-flight
lookups already were (see "After the human merges" above) — a failed write is reported (`WARN`,
naming the issue and which write failed) and the rest of that one issue's own repair arm is
skipped, but the run always continues to the next issue, still reaches the follow-up quarantine
section, and still prints the closing reminder; one summary `WARN` line prints when any write
failed this run. The close arm's write order changes from comment/remove-label/close to
comment/close/remove-label, and the follow-up arm's changes from comment/add-label to
add-label/comment, so in both arms the write that keeps an issue re-examinable by the next `--fix`
run is the last one attempted — the one bounded residue this leaves is a CLOSED issue that still
carries a stale `pr-open` label if only the final `remove-label` call fails, which this script's
own `--label pr-open --state open` query never revisits (a closed-issue sweep added since #370
removes it on the next `--fix` run instead — see "After the human merges" above). New gate
assertion 1.9 (header 80 → 81 —
assertion 1.8, the #362 hotfix, landed in between) flags a bare, unguarded `gh issue
comment`/`gh issue edit`/`gh issue close` at command position in any `bin/*.sh`.

### dev/cleanup-tests.sh: header history

Moved from `dev/cleanup-tests.sh`'s own header comment by #363.

```text
# Since #231, the multi-PR KEEP signal is label-primary and the comment-marker path is
# trust-gated: the `multi-pr` label on the issue itself is the primary KEEP signal (read from
# the same `gh issue list --json number,title,labels` fetch the script already makes); the
# `<!-- harness-multi-pr -->` marker is honoured only in a comment whose `authorAssociation` is
# OWNER/MEMBER/COLLABORATOR (case-insensitively), with a comment carrying no `authorAssociation`
# field treated as untrusted (fail-closed) — an ignored untrusted marker prints exactly one WARN
# line naming the comment's association and url, in both `--fix` and report-only modes; and the
# issue-BODY marker is no longer honoured at all (an issue relying on it now closes on the
# normal path). `build_stub_gh`'s `issue list` arm projects the requested `--json` field list
# (see its own comment below) so a fixture can distinguish "the script requested labels" from
# "the script didn't" — proving the label case can't pass vacuously if the script stops asking
# for `labels`.
#
# Since #248, the stub `gh` also validates `--json` FIELD NAMES against gh's own live-probed
# field set, the same treatment #217 gave dev/planning-tests.sh's stub: `issue list`, `issue
# view`, and `pr list` each reject an unsupported field with gh's own `Unknown JSON field:
# "<name>"` line on stderr and exit 1, so a future cleanup change asking gh for a field it does
# not support turns THIS repo's CI red instead of being silently served a fixture (see
# `validate_json_fields`'s own comment below for the two constants and what stays unvalidated).
# Since #249, a failed or malformed `gh issue view --json comments` (the multi-PR comment-marker
# lookup) no longer falls back to "no marker found" — it WARNs once, naming the failure route,
# and leaves the issue exactly as found (open, `pr-open` still attached) in both `--fix` and
# report-only modes; `build_stub_gh`'s new `VIEW_MODE` parameter (`ok`/`fail`/`malformed`)
# fixtures both routes, and a fifth fixture pins that the cheaper `multi-pr`-label KEEP signal
# still short-circuits before this lookup is ever attempted.
#
# Since #334, the follow-up quarantine's idempotence key moved off the `no-plan` label (a
# follow-up is born `no-plan` since #308, so excluding it from the candidate query would exclude
# every follow-up outright) onto a trusted, PR-keyed `<!-- harness-orphan-notice: PR #<p> -->`
# marker read from a per-follow-up `gh issue view --json comments` lookup, the same trust gate and
# #249 fail-closed shape the multi-PR path above already uses. `build_stub_gh`'s `issue list` arm
# gains a `--search` case serving `followups.json` (field-projected exactly like the `pr-open`
# arm), and its `issue view` "ok" mode prefers a per-issue `comments-<n>.json` override when
# present — see `build_stub_gh`'s own comment below for both.
#
# Since #355, the best-effort treatment above extends to bin/cleanup-after-merge.sh's own
# MUTATING writes (`gh issue comment`/`gh issue edit`/`gh issue close`), not just its pre-flight
# lookups: a failed write is reported (one `WARN` line naming the issue and which write failed)
# and the remaining writes of that same issue's own arm are skipped, but the run always continues
# to the next issue, still reaches the "== follow-ups from rejected PRs ==" section, and still
# prints the closing Reminder — exit status stays 0. `build_stub_gh`'s `issue comment|edit|close`
# arm gains a `reject-$2-once`/`reject-$2` marker-file pair (see its own comment below) that fails
# one write on demand, mirroring `dev/planning-tests.sh`'s `reject-X(-once)` contract; thirteen new
# fixtures pin the per-arm skip-the-rest behaviour, the close-arm and follow-up-arm write
# reorderings that make the write which keeps an issue re-examinable the LAST one attempted, the
# one summary WARN line printed before the Reminder when any write failed this run, and that
# report-only mode still performs zero writes regardless of which reject markers are present.
#
# Since #370, a second `gh issue list --label pr-open --state closed --json number,title --limit
# 100` query feeds a new "== closed issues still labelled pr-open ==" section, sweeping the whole
# historical backlog of closed issues still carrying `pr-open` (not just the one #355 could leave
# behind), 100 per run: an issue with any OPEN `claude/<n>-*` PR is kept (an `ok` line, no write);
# otherwise, with `--fix`, the label is removed through `try_write` with no comment posted at all
# (the label-removal event is its own audit trail) — without `--fix`, a `STALE` line only. The
# sweep runs whenever the PR list itself was fetched, independent of the open-issue query's own
# success. `build_stub_gh`'s `issue list` arm gains a `--label pr-open --state closed` case ahead
# of the open one (see its own comment below), serving `closed-pr-open.json`, plus
# `reject-closed-list` and `reject-open-list` failure markers. Since #370 kickback round 3, that
# same closed arm also appends its own full argv to a separate `DIR/gh-list-calls.log` (the
# pre-existing, mutation-only `gh-calls.log` is untouched), read into `$list_calls` by
# `run_cleanup_at` and asserted via a new, needle-guarded `expect_list_call` helper — making the
# closed query's own literal argument list, including ` --limit 100`, observable to a fixture for
# the first time (RESOLVED and the first acceptance criterion both name this literal command
# line). Since #370 kickback round 4, that same fixture additionally asserts the section header
# text itself (`expect "== closed issues still labelled pr-open =="`) and, via a new
# `expect_section_order` helper, that header's POSITION between `== pr-open label hygiene ==` and
# `== follow-ups from rejected PRs ==` — see the `MEASURED MUTANTS, #370` block's own "Kickback
# round 4" paragraph for the full literal -> fixture:assertion -> mutant table this round's own
# sweep produced.
```

### dev/hook-tests.sh: header history

Moved from `dev/hook-tests.sh`'s own header comment by #363.

```text
# hooks/git-c-guard.sh (#150) has two verdicts — allow (a single
# hookSpecificOutput.permissionDecision == "allow" JSON object on stdout) or no opinion (empty
# stdout) — for every case listed in the approved #150 plan's "Testing approach", plus a
# booby-trapped `git`/`rm` on PATH proving the guard never executes anything against the
# untrusted worktree path it is validating (that is exactly the risk the startup wildcard
# warning names — see hooks/git-c-guard.sh's header).
#
# hooks/agent-boundary.sh (#235) has three verdicts — deny (exit 2, empty stdout, one stderr
# line naming the role and the blocked command), no opinion (exit 0, empty stdout, empty
# stderr), or (never observed here, since this hook's contract forbids it) anything else — for
# every case listed in the approved #235 plan's "Testing approach": implementer-role deny/no
# opinion, verifier-role deny/no opinion (both agent_type spellings represented per role),
# role-agnostic no opinion, the same booby-trapped `git`/`rm` idiom proving the boundary never
# executes anything either, and, since #270, a CRLF-carrying command word on both the
# implementer (`git<CR> push`) and verifier (`gh<CR> …`) roles, plus a CRLF-carrying subcommand
# (`git status<CR>`) that DENIES pre-fix and is no opinion post-fix.
#
# hooks/push-guard.sh (#260) has the same two observable verdicts as agent-boundary.sh — deny
# (exit 2, empty stdout, exactly one stderr line naming the blocked destination) or no opinion
# (exit 0, empty stdout, empty stderr) — for every case listed in the approved #260 plan's
# "Testing approach": one deny case per refspec-parsing clause/boundary (a non-`origin` remote, a
# URL remote containing a colon, a full `refs/heads/…` refspec, `:main`, `--delete`,
# `--all`/`--mirror`, an option before/after the remote or refspec, 0/1/2+ occurrences of a
# skipped option/prefix-word/global-option class, the `git -C <worktree> push origin main` form
# `git-c-guard.sh` itself would allow, and the `main`/`master` fallback pair), a default-branch
# symref read against a fixture repo (base/subdirectory/worktree-pointer-file `cwd` variants),
# every documented no-opinion shape (including the two exact forms this harness itself issues),
# role-agnostic no-opinion edges, the same booby-trapped `git`/`gh`/`rm` idiom plus a
# byte-identical-file-listing fixture proving this hook reads the filesystem but never writes to
# or executes anything on it, and, since #270, a CRLF-carrying destination (`git push origin
# main<CR>`, both trailing and interior), a CRLF-carrying command word (`git<CR> push origin
# main`), and a CRLF-carrying non-default destination (`git push origin feature/x<CR>`) proving
# the strip does not widen the deny set. Since #268, the same common dir's `config` file is also
# pinned for a push segment carrying no explicit refspec: a bare push and a named-remote push
# each denied via a configured `remote.<name>.push` refspec (a 0/1/2+ boundary on two `push =`
# lines under one remote, and a `key=value` assignment with no surrounding spaces), `push.default
# = upstream`/`tracking` resolved through the current branch's recorded `merge` ref — including,
# since the #268 round-2 kickback, alongside a NON-denying `remote.<name>.push` record on the
# SAME remote, pinning the RESOLVED union of routes (not git's own precedence), and, since the
# #268 round-3 kickback, a bare push denied via a denying `remote.<name>.push` record under a
# DIFFERENT (non-`origin`) remote plus a benign `origin` section, pinning the RESOLVED union
# across EVERY configured remote at n==0 (not just git's own default-remote pick) — `push.default
# = matching` and a wildcard (`*`) destination each denied unconditionally, n==1 exact
# remote-name scoping in both directions, the harness's own explicit-refspec shape confirmed as
# a release-blocker no-opinion control even
# against a denying config, current-branch scoping on `branch.<n>.merge`, comment/whitespace
# handling, a CRLF-carrying config line (both a line-ending CR and, since the #268 round-2
# kickback, an interior CR inside a refspec value), a config setting neither key at all, a
# worktree's config resolved from the MAIN checkout rather than the pointer's own gitdir, a final
# config line with no trailing newline, case-insensitive section/key names, and the same
# booby-trapped/byte-identical-listing guarantee applied to the config route specifically. Since
# #269, a push segment's own `git -C <path>` value is ALSO pinned, but only when it satisfies the
# same `PATH_ERE` predicate `hooks/git-c-guard.sh` enforces (mechanically pinned identical by
# dev/selfcheck.sh's assertion 4.42): the current-branch check, `refspec_dest()`'s `HEAD`
# substitution, and the default-branch deny-set member each denying via a RESOLVED sibling
# worktree or a wholly separate checkout (the issue's own headline shape), the resolved checkout's
# own config denying where the session has none, the two documented narrowings (a resolved segment
# no longer inherits the session's REPO-LOCAL `.git/config` routes, and a bare push in a sibling
# worktree no longer denies merely because the SESSION sits on its own default branch), the predicate's
# boundaries (no `-wt-<n>` suffix, the attached `-C<path>` form, 0/1/2+ occurrences of `-C`), an
# unresolvable-but-shape-matching target degrading to the session's own facts rather than clearing
# them, the session's own default branch staying in the deny-set union for a resolved segment, and
# the same booby-trapped/byte-identical-listing guarantee — applied to BOTH the session repo and
# the resolved `-C` target — proving the new resolution route reads but never executes or writes.
# Since the #269 round-2 kickback, that same guarantee's trap set also names `dirname`, pinned by a
# SEPARATE fixture whose `-C` target does not resolve at depth 0 (the original fixture's own target
# does, and so cannot discriminate the depth-1 ascent guard `dirname` exposure would otherwise
# leave unpinned), and a two-push-segment command pins the per-segment reset itself — the SECOND,
# `-C`-less segment stays judged by the SESSION's own facts, never by whatever the first segment's
# resolved `-C` target left behind. Since #290, the same common-dir config read is extended to
# three GLOBAL candidates — `$GIT_CONFIG_GLOBAL` (when set and non-empty),
# `$XDG_CONFIG_HOME/git/config` (or its `$HOME/.config/git/config` default, when
# `$XDG_CONFIG_HOME` is unset or empty), and `$HOME/.gitconfig` — unioned with the repo-local
# routes above and read identically for every
# checkout resolved (session or a resolved `-C` target, since this class comes from the
# environment, never the untrusted command string): one deny fixture per global candidate path,
# the "none present"/loop-boundary fixture, a benign value in one file never masking a denying
# value in another and the reverse (a denying global value still denying over a benign repo-local
# one), `$GIT_CONFIG_GLOBAL` unioned with (not replacing) the other two global paths, the deny
# message's own two-literal source label (repo-local vs. global), the harness's own
# explicit-refspec push shape reconfirmed as a release-blocker no-opinion control against a denying
# GLOBAL config (bare and `-C`), a resolved `-C` segment still seeing the global routes, and the
# same booby-trapped/byte-identical-listing guarantee extended to the fixture `HOME` tree. Because
# the hook now reads `$HOME`/`$XDG_CONFIG_HOME`/`$GIT_CONFIG_GLOBAL`, `run_push_guard` below
# isolates all three for EVERY push fixture (a neutral, empty fixture `HOME` under `$tmpbase` by
# default) so no fixture can read the developer's or CI runner's real global git config. Since the
# #290 ROUND-2 KICKBACK, two more classes are pinned: TWO `[push] default = ...` lines inside ONE
# file (global or repo-local) are BOTH accumulated and evaluated rather than the file's own last
# value winning, a documented over-block; and the `cfg_push_lines` record threads its source label
# FIRST, as a bounded field, with the configured value as the record's UNBOUNDED tail, so a
# `remote.<name>.push` value containing a literal TAB byte cannot truncate and leak its own
# remainder into that source label.
#
# hooks/claude-dir-guard.sh (#327) has three verdicts — deny via the ".claude" segment class,
# deny via the unclassifiable/fail-closed class (each exit 2, empty stdout, exactly one stderr
# line, the two classes' wording DISTINCT from each other), or no opinion (exit 0, empty stdout,
# empty stderr) — for every case listed in the approved #327 plan's "Testing approach": the four
# agent_type spellings distributed across both roles and both guarded tools (Edit/Write), a nested
# segment, a user-level path outside any repo checkout, a case-variant spelling, the Windows
# drive-letter and backslash-spelled forms, ".claude" as the final segment, a CR-carrying
# spelling, the relative-".claude"-vs-relative-plain pair that discriminates the two deny classes,
# a ".."-carrying path with and without a ".claude" segment, every documented no-opinion shape
# including the two release-blocker controls (the orchestrator's own main-session lesson append,
# and the verifier's transient mutation-probe Edit), and the same booby-trapped
# git/gh/rm/dirname/tr/awk/grep/sed PATH idiom plus a byte-identical fixture-tree listing proving
# this hook — which performs NO filesystem access at all, unlike either of its two Bash-matching
# siblings above — never executes or writes anything.
```

### dev/planning-tests.sh: header history

Moved from `dev/planning-tests.sh`'s own header comment by #363.

```text
#   bin/find-planning-work.sh (#164, planner-facing): only a comment whose authorAssociation is
#   OWNER, MEMBER, or COLLABORATOR ever puts its issue into needs_revision or is honoured as the
#   latest plan comment; everything else (CONTRIBUTOR, NONE, or a comment with no
#   authorAssociation field at all — fail-closed) posted after the issue's latest trusted plan
#   (or any such comment, if there is no trusted plan yet) is reported in the untrusted_comments
#   output bucket instead of being silently dropped or silently trusted, and never shadows a
#   real, trusted plan; one posted before that plan is dropped with no bucket entry. #176 added
#   issue-author provenance on the SAME script: every needs_initial_plan/needs_revision item now
#   carries {author, association, trusted_author}, a non-maintainer-authored issue is still
#   listed (planning is not gated on it) but also appears in the untrusted_issue_authors bucket,
#   and (#202: association is read from GitHub's REST issues endpoint, since gh has never exposed
#   an issue-level authorAssociation `--json` field) if that REST lookup fails, the script retries
#   it once after a single bounded backoff (#246, mirroring #223/PR #244's implementer-side
#   re-run) before the run fails closed (every issue untrusted, one warn line,
#   counts.author_association_unavailable: true); a retry that succeeds instead sets
#   counts.author_association_retried: true and populates the map from the SECOND attempt's
#   output, with a distinct one-line warn on stderr. #182
#   added a second, orthogonal exclusion inside the trusted set: a trusted comment containing
#   "<!-- harness-audit -->" (a harness-authored audit/hygiene record) or "<!-- verifier-verdict
#   -->" (the orchestrator's own archive) never counts as feedback either, so neither re-opens a
#   plan for revision — counted in counts.audit_comments_skipped / counts.verdict_archives_skipped
#   respectively, and never applied to the untrusted bucket (a forged marker from an untrusted
#   author still lands in untrusted_comments, never silently dropped). #281 (superseding #275)
#   restricts the plan-candidate set feeding the LATEST-PLAN computation itself to trusted
#   comments that OPEN WITH (first-line anchored, not the contains() the feedback exclusion above
#   uses) the plan marker — so neither a harness-authored record (which opens with its own marker,
#   never the plan marker) nor a record whose harness marker is preceded by prose but which quotes
#   the plan marker mid-body (the residual gap #275 left open) is ever mistaken for the plan (the
#   live #245 shape, generalised); a plan comment that itself quotes a harness marker in its own
#   prose is unaffected and still becomes the latest plan. #211 makes the SAME
#   script's revision-candidates query faithful too: the stub applies the script's own `--jq
#   '.[].number'` argument to a JSON page-array fixture with the real jq and propagates jq's exit
#   status, so a candidates filter that cannot process the returned document fails the call the
#   identical way a rejected `gh issue list` call does — see #272/#273 immediately below, which
#   retries that failure once before it can abort anything. #272/#273 extend #246's bounded-retry
#   shape (one guarded 30s sleep, one re-attempt) to the SAME script's other three `gh` calls: the
#   needs_initial_plan query and the revision-candidates query each retry once, then — instead of
#   the bare command-substitution assignments that used to let one transient failure abort the
#   whole run under `set -euo pipefail` before any stdout was produced — fail closed to an empty
#   bucket with a dedicated counts flag and a warn line on stderr, while the run continues and
#   still exits 0 with whatever half succeeded (#273); the per-candidate `gh issue view` inside the
#   revision loop gets the identical one-retry treatment before its pre-existing warn-and-skip
#   fallback runs (#272), narrowing counts.fetch_failures to post-retry failures only and adding
#   counts.fetch_retries for the retried-regardless-of-outcome count. All four sites (this REST
#   lookup included) share the one ASSOCIATION_RETRY_SLEEP backoff constant.
#
#   bin/find-implementation-work.sh (#176, implementer-facing): the same trust gate, reused
#   rather than forked (TRUSTED_ASSOCIATIONS agrees with find-planning-work.sh's — see gate
#   assertion 4.26), selects each ready issue's approved plan comment and its binding post-plan
#   comments itself: a plan-marker comment from an untrusted author is never selected as `plan`;
#   an untrusted post-plan comment never lands in trusted_post_plan; a trusted post-plan comment
#   containing "<!-- verifier-verdict -->" (the orchestrator's own archive) or, since #182,
#   "<!-- harness-audit -->" (a harness-authored audit/hygiene record) is excluded from
#   trusted_post_plan too (counted in counts.verdict_archives_skipped / counts.audit_comments_
#   skipped respectively, never applied to untrusted_post_plan); a comment with no
#   authorAssociation field at all is fail-closed untrusted; and an issue with no trusted plan
#   comment yields plan: null but stays in `ready`. #281 (superseding #275) restricts plan
#   candidacy itself to trusted comments that OPEN WITH the plan marker (first-line anchored),
#   applied identically at BOTH the underlying $lastPlan computation and the plan: selection
#   expression (a same-createdAt tie fixture discriminates the two sites), so neither a
#   harness-authored record nor a record whose harness marker is preceded by prose but which
#   quotes the plan marker mid-body is ever selected as plan; trusted_post_plan's own window
#   re-anchors to the real plan.
#   #174 added plan-binding provenance on the SAME script: each plan_selection entry's
#   `approval.covers_plan` is true iff the newest `plan-approved` labeling event is not earlier
#   than the selected plan comment (a plan posted AFTER the label is not covered — the issue's
#   named failure) — necessary but, since #192 also gates on the comment's content not having
#   changed after approval, no longer sufficient on its own — the newest of several relabel events
#   wins, ties count as covered, an unreadable events lookup fails closed (`covers_plan: null`),
#   and `binding_line` is non-null iff `covers_plan` is `true`. Also pins `--issue <n>`
#   single-issue mode's output shape and its exit-2 argument validation.
#   #194 adds three more pins, split across both scripts and one skill-facing behaviour:
#   workstream A — a `has_harness_marker` boolean (true when a comment's body contains
#   "<!-- harness-audit -->" or "<!-- verifier-verdict -->") is added to BOTH scripts' untrusted
#   buckets (`untrusted_comments[].comments[]` on the planner side, `untrusted_post_plan[]` on the
#   implementer side) — an ANNOTATION only, never a filter (the #182 placement rule): a forged
#   harness-record marker from a non-maintainer still surfaces, just flagged, counted in
#   counts.untrusted_harness_markers, and warned about, on both scripts, symmetrically (gate
#   assertion 4.29 pins that the two flag names agree). Workstream B — find-implementation-work.sh
#   marks each `trusted_post_plan` entry `covered_by_approval`: true when the comment's createdAt
#   is not later than that entry's own `approval.approved_at`, false when it is (reported —
#   counts.post_approval_comments, a warn line — never binding), null when approved_at itself is
#   unknown; `counts.trusted_post_plan` keeps counting every entry, covered and uncovered alike.
#   Workstream C — the planner skill's step-7 stalled-stage escalation is now a
#   "<!-- harness-audit -->"-opening issue comment rather than summary-only prose; pinned here by
#   confirming such a comment (posted by a trusted author, after the plan) still exercises the
#   existing audit-marker exclusion and does not re-open the plan for revision.
#   #192 adds plan-COMMENT-content binding on the SAME script, layered inside the branch that
#   #174's approval.covers_plan check would otherwise conclude "covered": the selected plan
#   comment's REST `updated_at` (fetched via `gh api .../issues/comments/<id>`, `<id>` parsed from
#   the comment url's `#issuecomment-<id>` suffix) is compared against the SAME `approved_at` the
#   events lookup above already computed — an edit strictly AFTER approval un-covers the plan
#   (`covers_plan: false`, `reason: "plan-edited-after-approval"`, `binding_line: null`,
#   `counts.plan_edited_after_approval`); an edit before approval, or an edit-timestamp tie, stays
#   covered on purpose (the approver read the edited text); an unparseable comment id, a rejected
#   lookup, or a document the script's own filter cannot process all fail closed identically
#   (`covers_plan: null`, `reason: "plan-edit-unreadable"`, `counts.plan_edit_unreadable`, with
#   `approval.approved_at`/`approved_by` still populated since the EVENTS lookup itself succeeded
#   — the contrast with `approval-unreadable`). The lookup is made ONLY on the
#   would-otherwise-be-covered branch AND ONLY when the #240 pre-filter below finds gh's own
#   includesCreatedEdit is not exactly false, so an issue already uncovered for another reason (no
#   plan, no approval event, plan-after-approval, events-unreadable) — or one whose plan comment gh
#   itself already reports as never edited — makes no extra API call and fires no extra warn line.
#   Also pins that `--issue <n>` single-issue mode carries the new reason too.
#   #229 adds a PRE-FILTER on the SAME script, checked before #174's events lookup and before
#   #192's plan-edit lookup: `plan-approved` absent from the issue's CURRENT `labels` (fetched on
#   the SAME `gh issue view` call both modes already make, tolerant of gh's real
#   `{"name": "..."}` element shape and fail-closed on a missing `labels` key or an empty array)
#   sets `covers_plan: false`, `reason: "approval-label-absent"`, `binding_line: null`, and
#   `counts.approval_label_absent`, and makes NEITHER the events lookup NOR the plan-edit lookup —
#   a maintainer who removes plan-approved to veto an issue mid-flight is caught, at zero API cost,
#   by both single-issue callers (the implementer skill's pre-push recheck and issue-cycle's merge
#   floor, both `--issue <n>`) and by batch mode (whose search result can be stale; the view fetch
#   below it is always fresher). This reason wins precedence over no-plan — the human's withdrawal
#   is the more actionable fact — but the separate "no maintainer-authored plan comment" warn and
#   counts.no_trusted_plan still fire too, so the missing-plan fact is never hidden.
#   #213 adds approval.approved_at_history[] on the SAME script (bin/find-implementation-work.sh):
#   every real plan-approved `labeled` event for the issue, newest first, deduplicated, as
#   {approved_at, approved_by, binding_line} — so a PR body written under an EARLIER approval of
#   the same plan still has a binding line the issue-cycle merge floor recognises after a later,
#   unrelated re-approval (see skills/issue-cycle/SKILL.md's *Plan-binding provenance* and
#   *Post-approval comments* sub-bullets — re-adding plan-approved to bind a post-approval comment
#   no longer permanently strands an open PR). Pinned here: a single labeled event => one entry
#   matching approval's own top-level approved_at/approved_by/binding_line; three events posted
#   OUT OF ORDER in the fixture => newest-first ordering (entry [0] is the newest, matching what
#   $latest already picked); two byte-identical events => deduplicated to one entry; covers_plan
#   not true (plan-after-approval) => every entry's binding_line is null even though the history
#   itself is non-empty; the events lookup being unreadable (reject-events-<n>), evaluated
#   alongside a healthy sibling issue, => approved_at_history: [] for the unreadable issue only —
#   pinning the same per-iteration reset #229's approval-label-absent pre-filter also depends on
#   (a stale value must never leak from one ready issue's loop iteration into the next); and
#   --issue <n> single-issue mode carries the same field, same shape.
#   #230 closes, for DECISION comments, the same content-binding gap #192 closed for the plan
#   comment: on the branch that would otherwise leave approval.covers_plan "true" (after #229's
#   label pre-filter and #192's plan-edit check both pass), the script fetches the REST updated_at
#   of every trusted_post_plan entry #194 workstream B already marked covered_by_approval: true AND
#   whose own gh-reported includesCreatedEdit is not exactly false (#240, see below) — and ONLY
#   those — comparing it against the SAME approved_at. A covered comment edited strictly
#   after approval flips that entry to covered_by_approval: false, covered_by_approval_reason:
#   "decision-edited-after-approval", and collapses the ISSUE-LEVEL verdict to covers_plan: false,
#   reason: "decision-edited-after-approval" too (folded into the same verdict split every reader
#   already inherits). An entry whose edit state cannot be established (unparseable id, rejected
#   call, a document the script's own filter cannot process, or an empty updated_at) flips to
#   covered_by_approval: null, covered_by_approval_reason: "decision-edit-unreadable", collapsing
#   the issue-level verdict the same way UNLESS some other covered comment on the same issue was
#   also edited (edited wins — false is definitive). An entry the workstream-B check already
#   marked uncovered, or one gh itself already reports as never edited (#240), is never looked up
#   (proved mechanically by expect_api_calls, not inferred from the JSON) — the comment-<id>.json /
#   reject-comment-<id> fixture contract above now serves EITHER the plan comment or a covered
#   decision comment whose own includesCreatedEdit is not exactly false, since both calls hit the
#   identical REST shape. Also pins that --issue <n> mode carries both new reasons.
#   #240 pre-filters BOTH #192's plan-comment check and #230's decision-comment check just described
#   on gh's own per-comment includesCreatedEdit boolean, already present in the `comments` field
#   both scripts' fixtures already carry, at no extra API cost: exactly false means gh itself
#   reports the comment was never edited, so the id-parse and the REST lookup are both skipped, with
#   no warn, leaving the entry (or the plan) covered; exactly true keeps today's lookup and every
#   fail-closed state unchanged; the key being ABSENT (every fixture that predates this PR) falls
#   through to today's lookup — no new state, no new reason, no new counts key, no new `--json`
#   field (the flag rides inside the `comments` field find-implementation-work.sh already fetches).
#   Both internal jq members (plan_includes_created_edit, trusted_post_plan_edit_flags) never appear
#   in the published JSON. Six new fixtures below (Part 11) pin the skip mechanically via
#   expect_api_calls in both batch and --issue <n> modes; the pre-existing fixtures (none of which
#   carries the key) pin the fall-through, non-vacuously, by continuing to pass unchanged.
#   #284 mirrors #272/#273's bounded-retry-then-fail-closed shape (one guarded 30s backoff, one
#   re-attempt) onto the SAME script's other two `gh` call sites: the batch `ready` query (a bare
#   command-substitution assignment before this PR, so one blip aborted the run with no stdout) and
#   the per-issue `gh issue view` inside the ready loop (previously warn-and-skip on the FIRST
#   failure). A retry that succeeds sets counts.ready_query_retried: true and builds `ready` from
#   the SECOND attempt's output; both attempts failing additionally sets
#   counts.ready_query_unavailable: true and reports `ready` as an empty array — the script still
#   exits 0 with one complete JSON document, never an abort. counts.fetch_retries counts every
#   per-issue first-attempt failure regardless of the retry's own outcome; counts.fetch_failures is
#   narrowed to post-retry failures only. `--issue <n>` mode's own prefetch is deliberately NOT
#   retried (both its callers already re-run the whole script once on an unknown verdict) — pinned
#   by a dedicated fixture proving byte-identical behaviour to before #284.
#   #285 teaches bin/harness-status.sh, the consumer both discovery scripts already have, to
#   surface a degraded discovery run instead of silently reporting an empty queue: a top-level
#   `degraded` boolean and `degraded_reasons` array (`"planning.<key>"` / `"implementation.<key>"`
#   strings, planning half first), computed by a GENERIC rule — every key in either script's own
#   `counts` object whose name ends in `_unavailable` and whose value is exactly `true` — plus
#   `counts.degraded` mirroring the same boolean. Being generic, it already covers
#   initial_query_unavailable, candidates_query_unavailable, author_association_unavailable, and
#   #284's own ready_query_unavailable with no per-key enumeration to drift; a non-zero
#   counts.fetch_failures on either script deliberately does NOT mark a run degraded (it drops one
#   issue, not a whole bucket, and already produces its own per-issue warn line on stderr).
#   #297 gives bin/harness-status.sh's OWN three gh call sites (plan-proposed, impl-blocked, open
#   PRs) the identical bounded-retry-then-fail-closed shape #272/#273/#284 already gave the two
#   discovery scripts, publishing six new `counts` booleans (`proposed_query_retried`/
#   `_unavailable`, `blocked_query_retried`/`_unavailable`, `prs_query_retried`/`_unavailable`) and
#   extending `degraded_reasons` with a third, status half — the SAME generic rule applied to this
#   script's own new flags, producing `"status.<key>"` entries after the planning and
#   implementation halves. The Part 14 fixtures below (#297, extended #333, extended #309, extended
#   #353) exercise this script's own five gh call sites — PLUS (#353) its own stop check, which is
#   not a gh call site (see build_stub_stop below) — via a new `build_stub_discovery` builder that
#   shadows BOTH discovery scripts with canned, non-gh-calling stand-ins — unlike Part 13's fixtures
#   above, which drive the real discovery scripts end-to-end through run_status too.
#   #333 adds a FOURTH such site, `waiting_on_human.followups_to_triage`: open, `no-plan` issues
#   whose body opens with the harness-filed follow-up marker (#308), fed by a fourth `gh issue
#   list` call with the identical bounded-retry-then-fail-closed shape, publishing
#   `followups_query_retried`/`_unavailable` and a `"status.followups_query_unavailable"`
#   degraded_reasons entry appended AFTER the three #297 status entries. From #333 through v2.7.6,
#   `counts.human_actions` did NOT include this bucket — it was reported beside the total, never
#   inside it, because the query could not tell a follow-up nobody had triaged from one a
#   maintainer read and deliberately parked (both kept `no-plan` and the marker forever; measured
#   on this repo 2026-09-17: the filter matched 10 issues, every one already triaged and parked).
#   `human_actions` is a generic sum over every `waiting_on_human` array member EXCEPT a small,
#   named exclusion list bound right next to the sum, so `waiting_on_human`'s escalations member
#   (#309) joins the total automatically, with no edit to the sum expression, since it is not named
#   in that exclusion list — the same mechanism any future member gets unless it too is named
#   there. Since #346, `list_followups()`'s own query additionally excludes
#   `-label:$TRIAGED_HELD_LABEL` (a new, human-applied-only lifecycle label the harness never adds
#   or removes), narrowing the bucket to untriaged-only; with that narrowing in place the exclusion
#   list is now empty (`[] as $excluded`, kept as the extension point #333 designed), so
#   `followups_to_triage` joins `counts.human_actions` too, by the identical generic rule. Four new
#   Part 14 fixtures (below) pin the new site; two existing Part 14 fixtures
#   (status-own-queries-healthy, status-own-retry-sleep-failure-survives) are extended to cover its
#   healthy path and its guarded sleep; a further #346 continuation (below the #309 fixtures
#   further down) restates the affected fixtures' human_actions expectations and mutant (N8) for
#   the new, empty-exclusion-list baseline.
#   #309 adds a FIFTH such site, `waiting_on_human.escalations`: open `needs-human` issues, served
#   verbatim with no filter, fed by a fifth `gh issue list` call with the identical
#   bounded-retry-then-fail-closed shape, publishing `counts.escalations`,
#   `counts.escalations_query_retried`/`_unavailable` and a
#   `"status.escalations_query_unavailable"` degraded_reasons entry appended AFTER the four
#   existing status-half entries (the three #297 entries plus #333's own). This member was never
#   named in the `human_actions` exclusion list, so it joined the total automatically by the same
#   generic rule, with no edit to the sum itself — the same rule #346 (above) now also applies to
#   `followups_to_triage`. Three new Part 14 fixtures pin the new site —
#   status-escalations-bucket-populated, status-escalations-query-retry-succeeds, and
#   status-escalations-query-unavailable — and the same two existing Part 14 fixtures
#   (status-own-queries-healthy, status-own-retry-sleep-failure-survives) are extended again, this
#   time to cover the escalations site's healthy path and its guarded sleep.
#   #302 adds a diagnostic for the one class #281's positive anchor drops with no report of its
#   own: a trusted comment posted after the latest plan (or, when there is none, at any time) whose
#   body contains the plan marker somewhere other than its first line — never a plan candidate
#   (#281 already excludes it) and never feedback/binding context either (the pre-existing
#   contains($m) exclusion already excludes it there too) — was previously dropped from both sets
#   with no diagnostic. Both scripts now print one `warn:` line per such comment (naming its
#   author, createdAt, and url, or the literal "no url") and publish `counts.plan_marker_quoters`,
#   spelled byte-identically between the two scripts (no `startswith`, no reference to `$planC`),
#   harness records excluded exactly as the feedback/binding sets already exclude them. Two new
#   combined fixtures (Part 5) tell apart every clause of the rule.
#   #321 adds the twin diagnostic for the class #302 deliberately left unwarned: a trusted comment
#   posted after the latest plan (or, when there is none, at any time) whose body contains a
#   harness-record marker (the harness-audit marker or the verifier-verdict marker — the set is now
#   one shared declaration, HARNESS_RECORD_MARKERS, on both scripts) somewhere other than its first
#   line — a maintainer quoting a harness record (to dispute it, for instance), not a harness
#   record itself, since every record this harness posts opens with its own marker. Both scripts now
#   print one `warn:` line per such comment (naming its author, createdAt, and url, or the literal
#   "no url") and publish `counts.harness_marker_quoters`, spelled byte-identically between the two
#   scripts, disjoint from `counts.plan_marker_quoters` (a comment quoting both markers is counted
#   in exactly one). Five new fixtures (Part 5) tell apart every clause of the rule, including the
#   no-plan window and (implementer only) `--issue <n>` mode.
#   #353 adds a SIXTH check site to bin/harness-status.sh, but not a sixth `gh` call site: one
#   bin/harness-stop.sh invocation, fed by that script's own stdout grammar rather than a second
#   query, never retried at this layer (harness-stop.sh already does its own one bounded retry).
#   The status JSON gains a top-level `stop` object ({state, reason, exit_code}) and a new
#   `waiting_on_human.stop_routes` array (one {route, clear} entry per SET carrier, both fields
#   pasted verbatim from harness-stop.sh's own printed lines), plus `counts.stop_routes` and, in
#   `$sf`, `counts.stop_check_unavailable` (appended LAST, after `escalations_query_unavailable`,
#   so its own `status.stop_check_unavailable` degraded_reasons entry — when present — is always
#   the array's last entry too). `stop_routes` was never named in the `human_actions` exclusion
#   list either, so a SET stop with N carriers joins the sum automatically, the identical
#   mechanism #309's escalations member and (since #346) followups_to_triage already use. Tested
#   behind a new canned `build_stub_stop` stand-in (mirroring `build_stub_discovery`'s own
#   canned-not-real design for this file's Part 14), installed by DEFAULT from `run_status` so no
#   pre-#353 `run_status` fixture needed changing to keep passing (the default stand-in is why) and
#   no fixture ever executes the real bin/harness-stop.sh against the developer's or CI runner's own
#   checkout — `status-own-queries-healthy` gained three `expect_jq` assertions plus
#   `expect_stop_calls` as the default stand-in's own non-vacuity control; the other twenty
#   pre-#353 `run_status` fixtures are byte-identical. Twelve new Part 14
#   fixtures (below, after the #309 ones) pin the state mapping (fail-closed to "unavailable" on
#   every outcome bin/harness-stop.sh does not document, including a determinate-looking carrier
#   line printed alongside an untrusted exit — discarded rather than trusted), the verbatim
#   carrier/`clear=` pairing and GitHub-before-local ordering, the
#   `stop_check_unavailable`/`degraded_reasons` participation, and the
#   `human_actions` arithmetic at N=0/1/3 carriers.
```
