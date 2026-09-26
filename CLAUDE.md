# CLAUDE.md — trail-blazer-flow (the harness itself)

This repo **is** the Claude Code plugin (the harness), not a project that consumes it. The
README (the user guide) and `docs/reference/` (the detailed rules behind it) are the canonical
spec; this file governs work **on** the harness's own code, docs, and scripts — not the contract
this harness expects of a *consumer* repo's `CLAUDE.md` (see the README's "The CLAUDE.md contract"
and `docs/reference/claude-md-contract.md` for that).

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
CI (`.github/workflows/selfcheck.yml`, two jobs — `selfcheck` on `ubuntu-latest`, the only
required check on every pull request, and `selfcheck-macos` on `macos-latest`, which prepends
`/bin` to `PATH` so the same commands run under Apple's bash 3.2 instead of a newer bash, and
which since #365 runs only post-merge on `main`, nightly, and on manual dispatch — never on a pull
request, because the maintainer's own local run already happens under bash 3.2, so a BSD-only
regression is caught on `main` within a day rather than holding every merge for the still-longer
time that job now takes with `dev/mutant-driver.sh` appended (`timeout-minutes: 35`, since #359,
raised from 20 to absorb the driver's own post-merge run). Each job runs ten commands, but the
ninth, `bash dev/mutant-driver.sh` (#359), is
gated `if: github.event_name != 'pull_request'`, so a pull request runs nine of them on `ubuntu`
only (driver-tests still runs; the driver itself, and the whole `selfcheck-macos` job, run only
post-merge/nightly/dispatch); a red check means one of the commands that ran failed — reproduce
locally with `bash dev/selfcheck.sh`, `bash dev/selfcheck-tests.sh`, `bash dev/doctor-tests.sh`,
`bash dev/hook-tests.sh`, `bash dev/cleanup-tests.sh`, `bash dev/planning-tests.sh`,
`bash dev/lock-tests.sh`, `bash dev/stop-tests.sh`, `bash dev/mutant-driver.sh`, and
`bash dev/mutant-driver-tests.sh` (on a
Mac, prefix each with `PATH=/bin:$PATH` to match the macOS job's shell, e.g.
`PATH=/bin:$PATH bash dev/selfcheck.sh`).
There is no test suite and no build step: this repo is Markdown instruction files, Bash scripts,
and JSON manifests. The gate prints what it checks — run it. A change existing checks can't catch
is closed by a new fixture or case in the relevant suite, not waived; a new gate assertion is the
exception, governed by the machine-parsed-artifacts convention below.

**Iterate narrow, finish full.** While iterating, run only the suite your change touches — the
paragraphs below name which script each suite covers, and a suite takes a name filter for a
single case. Run the full command set once, before reporting done; on a Mac, that final pass also
runs under `PATH=/bin:$PATH`, not every iteration.

`dev/selfcheck-tests.sh` is the gate's own negative-test harness — a separate script, not part of
`dev/selfcheck.sh` itself, that copies this repo to a throwaway temp directory, applies one
documented perturbation per case, and asserts the gate fails with exactly the expected assertion
id(s). It runs in CI as the second command; run it by hand whenever `dev/selfcheck.sh` changes,
and add a case for any assertion that parses structure out of a file, compares two extracted
sets, or exercises script behavior — a fixed-string or numeric-threshold assertion may ship
without one, listed in the harness's exempt comment with a one-line reason each. Cases run
concurrently by default, in bounded waves sized from the host's core count (clamped at 16,
falling back to 2 when no probe answers), overridable with `SELFCHECK_TESTS_JOBS=<n>` or
`-j <n>`, with `--serial` (`-j 1`) restoring one case at a time; the PASS/FAIL line sequence, the
totals, and the exit status always follow the cases' declared order regardless of completion
order, and a case whose child dies before reporting a verdict is counted as a FAIL naming the
case rather than silently dropped. The single-case/filter form
(`bash dev/selfcheck-tests.sh <case>`) is unchanged.

`dev/doctor-tests.sh` is a separate negative-test harness for the *consumer* doctor
(`bin/check-harness.sh`), its scoped-autonomy companion (`bin/check-decision-record.sh`), the
merge floor's governance-path classifier (`bin/governance-paths.sh`, #331), and the Codex
compatibility installer (`bin/codex-setup.sh`, #408 — its own `--check` drift mode is #410's
companion, hence living here rather than in a new suite): it
builds throwaway fixture repos under `mktemp` and pins each check's verdict (PASS/WARN/FAIL, by
ASCII stem) against a copy of the doctor script — settings-file grants, the template diff, the
test-suite ratchet, merge-autonomy activation, the default-branch guard, post-merge-verification
declarations, and branch-protection strictness among them — covering cases that would otherwise
only be hand-verified. It also runs `bin/harness-version.sh`'s own `.git`-presence guard
directly, not only through the doctor, `bin/governance-paths.sh`'s own floor mode and
`--check` mode directly, against fixture git repos it builds for that purpose, not only through
the doctor's own validation of it, and `bin/codex-setup.sh` directly against a fake Codex
plugin-cache install and fixture repos it builds for that purpose (write mode and its `--check`
twin alike — the generated agent TOMLs' byte-fidelity to `agents/*.md`, the installed rules
file's allow/forbidden/gated content, contract-loading into an `AGENTS.md` or a
`.codex/config.toml`, and every `--check` drift token). It runs in CI as the third command, but
it is not part of `dev/selfcheck.sh` itself; run it by hand whenever `bin/check-harness.sh`,
`bin/check-decision-record.sh`, `bin/governance-paths.sh`, or `bin/codex-setup.sh` changes.

`dev/hook-tests.sh` is a separate negative-test harness for all four plugin-shipped `PreToolUse`
hooks (`hooks/git-c-guard.sh`, `hooks/agent-boundary.sh`, `hooks/push-guard.sh`, and
`hooks/claude-dir-guard.sh`): it feeds fixture stdin JSON straight into each real script and pins
its verdict — allow, deny, or no opinion, per hook's own documented contract — across every
conforming and rejecting case each hook's own header describes. A booby-trapped `PATH` entry for
the executables each hook would otherwise invoke proves `hooks/git-c-guard.sh` (traps `git`/`rm`)
and `hooks/agent-boundary.sh` (traps `git`/`gh`/`rm`) never execute anything against the untrusted
string they scan — sentinel-absence only, no fixture-tree listing for either.
`hooks/push-guard.sh` and `hooks/claude-dir-guard.sh` (the latter trapping several more tools)
pair that same booby-trapped-`PATH` idiom with a byte-identical fixture-tree listing, proving
those two hooks also never write anything. `run_push_guard` isolates `HOME`, `XDG_CONFIG_HOME`,
and `GIT_CONFIG_GLOBAL` for every push-guard fixture, so no fixture can read the developer's or CI
runner's real global `git` config. It runs in CI as the fourth command, but it is not part of
`dev/selfcheck.sh` itself; run it by hand whenever any of the four `hooks/*.sh` scripts changes.

`dev/cleanup-tests.sh` is a separate negative-test harness for `bin/cleanup-after-merge.sh`: it
builds throwaway fixture repos under `mktemp`, with a stub `gh` (and, where needed, a stub
`git`) on `PATH`, and runs the real script against each, pinning the multi-PR KEEP
behaviour, the best-effort treatment of both the script's pre-flight lookups and `--fix`'s own
mutating writes, the orphaned-follow-up quarantine sweep, and the closed-issue `pr-open` sweep.
The stub validates every `--json` field list the script sends against `gh`'s own live-probed
field sets, `GH_ISSUE_JSON_FIELDS` and `GH_PR_JSON_FIELDS` — its `repo)` arm stays deliberately
unvalidated, a third, unprobed field set. `GH_ISSUE_JSON_FIELDS` is a byte-identical copy shared by
`dev/cleanup-tests.sh`, `dev/planning-tests.sh`, and `dev/stop-tests.sh`. It runs in CI as the
fifth command, but it is not part of `dev/selfcheck.sh` itself; run it by hand whenever
`bin/cleanup-after-merge.sh` changes.

`dev/planning-tests.sh` is a separate negative-test harness for both of this repo's discovery
scripts, `bin/find-planning-work.sh` and `bin/find-implementation-work.sh`, and for their
consumer, `bin/harness-status.sh`: it builds throwaway fixture directories under `mktemp`, with a
stub `gh` on `PATH`, and runs the real script(s) against each, pinning the comment-
and issue-author trust gate, plan selection, plan-binding approval provenance, and
`bin/harness-status.sh`'s own degraded-run reporting. Part 13 runs both discovery scripts for
real, end to end; Part 14 exercises `bin/harness-status.sh`'s own `gh` call sites and its
stop check behind a canned `build_stub_discovery`/`build_stub_stop` stand-in for both discovery
scripts — so an in-place mutant to either discovery script is reachable only through Part 13's
own `run_status` fixtures, never Part 14's. The stub validates every `--json` field list a call
sends against `gh`'s own documented field set, a family of `reject-<site>(-once)` fixture
markers pins a bounded-retry-then-fail-closed shape at each script's batch `gh` call sites (the
implementer script's `--issue <n>` prefetch is deliberately not retried, pinned by its own
fixture), and a stub `sleep` keeps the suite's wall clock free of the real backoff wait. It runs
in CI as the sixth command, but it is not part of `dev/selfcheck.sh` itself; run it by hand
whenever `bin/find-planning-work.sh`, `bin/find-implementation-work.sh`, or
`bin/harness-status.sh` changes.

`dev/lock-tests.sh` is a separate negative-test harness for `bin/harness-lock.sh`, the
single-flight lock that guards against two harness cycles running concurrently in one checkout:
it builds throwaway repos (and, for the shared-lock case, a worktree-added sibling) under
`mktemp`, with `CLAUDE_PID` and (#408) `TBF_OWNER_PID` set explicitly per fixture, and runs the
real script against them. It pins the six-file lock record (`run-id`, `pid`, `host`,
`started-at`, `harness-version`, `checkout-path`), refusal against a live same- or
different-host holder, reclaiming a same-host holder whose pid is no longer alive,
`release`/`release --force` semantics, that `status` always
exits 0, that a worktree of the same checkout shares one lock, that the recorded pid follows the
precedence `--owner-pid` > `TBF_OWNER_PID` > `${CLAUDE_PID:-$PPID}` (#408), and that `acquire`
refuses outright, before creating anything, when the resolved owner's own command line names a
Codex `app-server` daemon (#408). It runs in CI as the seventh command, but it is not part of
`dev/selfcheck.sh` itself; run it by hand whenever `bin/harness-lock.sh` changes.

`dev/stop-tests.sh` is a separate negative-test harness for `bin/harness-stop.sh`, the read-only
maintainer stop switch checked before each stage and before each merge: it builds throwaway repos
under `mktemp`, each with its own small `tbin/` directory that becomes the real script's entire
`PATH` (never a fallback to the developer's or CI runner's own PATH), including a stub `gh`
carrying the same `GH_ISSUE_JSON_FIELDS` copy `dev/cleanup-tests.sh` and
`dev/planning-tests.sh` use. It pins the union semantics across the GitHub-issue and local-file
stop routes, the stdout grammar, the one-bounded-retry `gh` query, and a
`never-mutates` case (a recording `git` wrapper plus a byte-identical fixture-tree
listing) proving the script only reads the tree it checks, never writes to it. It runs in CI as
the eighth command, but it is not part of `dev/selfcheck.sh` itself; run it by hand
whenever `bin/harness-stop.sh` changes.

`dev/mutant-driver.sh` (#359) is a checked-in mutant driver: it reads every `dev/mutants/*.json`
registry file, and for each record applies the recorded exact-text `{from,to}` edits (each
required to match exactly once) to a scratch copy of the record's `target` file — never the
tracked tree — then runs the record's own `suite`, name-filtered by its own `filter`, from inside
that copy, and compares the observed failing-case set against the record's `expect_fail`. A
baseline run (no edits) proves each distinct `(suite, filter)` pair is clean before any dependent
mutant is trusted; a red baseline short-circuits every mutant that depends on it. It runs mutants
in bounded concurrent waves (the same idiom `dev/selfcheck-tests.sh` uses) and prints results in
declared order regardless of completion order, with its own `PASS <name> <total> <set>`/
`FAIL <name> <total|-> <set|->` grammar and a `== summary: N pass, M fail ==` footer. Run it by
hand before pushing any change to a registry `target`, a registry `suite`, or the registry itself
— it runs in CI as the ninth command, but only post-merge on `main`, nightly, and on manual
dispatch (never on a pull request, `if: github.event_name != 'pull_request'`), so a stale recorded
set turns the post-merge/nightly run red within a day rather than blocking the pull request that
introduced it.

`dev/mutant-driver-tests.sh` is the driver's own negative-test harness: over synthetic targets and
suites built under `mktemp`, it pins the driver's registry validation (name/target/suite/edits/
expect_fail shape, each violation exiting 2 before any suite ever runs), the exactly-once edit
match, multi-edit sequencing, multi-line edits, the preserved executable bit, that the tracked
fixture tree is never touched, that a same-named decoy earlier on `PATH` is never invoked, the
`MUTANT_DRIVER_FAULT=die:<name>`/`slow:<name>` self-tests (mirroring
`dev/selfcheck-tests.sh`'s own), and the CLI (`-j <n>`/`--serial`/`MUTANT_DRIVER_JOBS`/an unknown
filter). It runs in CI as the tenth and last command in both jobs — but since #365's job-level
`if:` already keeps `selfcheck-macos` off pull requests entirely, a pull request runs it only via
the `selfcheck` (ubuntu) job; both jobs run it post-merge, nightly, and on manual dispatch. It is
not part of `dev/selfcheck.sh` itself — run it by hand whenever `dev/mutant-driver.sh` changes.

Per-PR history of what each suite pins — the "Since #N, X gains…" narrative — lives in
`CHANGELOG.md`'s archive, not here; each suite's own header comment and fixture/case comments
state its current mechanism instead.

This repo deliberately does **not** aim to pass `bin/check-harness.sh` — that script is the
*consumer* doctor; see the README's "Working on the harness itself" for why.

## Conventions

- **Plugin/consumer boundary**: nothing project-specific belongs in `agents/` or `skills/` —
  that content belongs in a *consumer* repo's `CLAUDE.md`/`LESSONS.md` instead. See
  `docs/reference/architecture.md`'s "Distribution".
- `bin/` is on consumers' Bash PATH **on Claude Code**; every `bin/*.sh` needs a matching allow
  entry in `templates/repo-settings.json` (the gate's bijection assertion checks this). On Codex,
  `bin/` is never on the shell PATH (ADR 0002 P5) — `bin/codex-setup.sh` (#408) installs a rules
  file that gates each script that calls `gh` (directly, or through `harness-status.sh`) or
  writes `.git`, by its absolute install path instead (see `docs/reference/codex.md`), and
  `bin/harness-status.sh` and `bin/reconcile-ledger.sh`
  resolve their own sibling scripts with PATH first, falling back to their own directory. Scripts
  meant only for developing this repo (not for consumers) go in `dev/` instead. `hooks/*.sh` is a
  third case: invoked by Claude Code itself (via `hooks/hooks.json`), never by the model issuing
  a Bash command, so a hook script takes no permission allow entry and stays out of the `bin/`
  bijection — see `docs/reference/safety-model.md`.
- **Gate assertions compare machine-parsed artifacts only.** An assertion may only compare two
  mechanically extracted artifacts (JSON↔JSON, script↔script, script↔JSON, filename↔frontmatter);
  no assertion may parse or pin English prose. Duplicated spec text is resolved by **deleting a
  copy**, never by pinning both — pinning makes the duplication load-bearing and permanent.
  Default: no new gate assertion. A plan may add one only when its "Testing approach" names (a)
  the specific cross-artifact drift the assertion prevents — the two artifacts that must agree —
  and (b) why no existing gate assertion or `dev/*-tests.sh` fixture already catches it; a check a
  fixture suite already exercises (such as a stdout token vocabulary the fixtures themselves
  consume) does not qualify. The maintainer's plan approval is where that justification is judged;
  this is a review-level convention, and no gate assertion checks it.
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
- The README and `docs/reference/` are part of "done": every factual claim they make about this
  repo's behavior must be checkable against the code (the verifier's Documentation changes check
  applies to docs). The README stays a user guide — short recipes that link to `docs/reference/`
  for the full rules — so a new mechanism's detail goes in the matching `docs/reference/` file.
- **Per-PR history lives in `CHANGELOG.md`, never in CLAUDE.md, a `dev/*.sh` header, or a README
  migration note.** (1) A new entry goes under `CHANGELOG.md`'s `## Unreleased` heading;
  `CHANGELOG.md` is history — not governance, not a gate target, and never updated to track later
  behaviour. (2) CLAUDE.md's Verification paragraphs describe each suite in the present tense; a
  change edits one only when it becomes false. (3) A README migration note is one line per version
  hop unless the hop has a consumer step (a grant, label, script, settings entry, baseline step,
  one-time manual action, or upgrade precondition), in which case it states the step and nothing
  else. (4) A new fixture or case comment states its mechanism — what it pins, which mutant kills
  it — never a pass/fail figure or a failing-set enumeration; a mutant migrated into
  `dev/mutants/*.json` (#359) is replaced by one `# mutant:<name> — <mechanism>` comment (gate
  assertion 4.52 cross-checks the two). A newly measured mutant goes straight into a
  `dev/mutants/*.json` record with its `# mutant:` comment, never into prose. An existing prose
  figure in `dev/*-tests.sh` (a pass total, a mutant tally, a "killed N of M") that a change would
  make stale is deleted, keeping the mechanism sentence, never recounted. (5) This is a
  review-level convention; no gate assertion checks it.
- Every `uses:` step in `.github/workflows/` is pinned to a full 40-hex commit SHA, with the
  human-readable release tag in a trailing comment — a mutable tag ref would let the action's
  owner change what CI executes with no diff visible here, and this repo's CI is the gate's own
  merge condition. The SHA pin is enforced mechanically (assertion 4.24); the trailing tag
  comment is a review-level convention, not machine-checked. `.github/dependabot.yml` is the
  weekly bump mechanism for those pins; assertion 4.25 enforces mechanically only that the file
  is present and declares an uncommented `package-ecosystem: "github-actions"` update with an
  `interval:` line — not that Dependabot actually opens a PR, and not that a bump rewrites the
  trailing tag comment.
- Release ritual: bump `version` in `.claude-plugin/plugin.json`, create the matching `vX.Y.Z`
  annotated tag, and retitle `CHANGELOG.md`'s `## Unreleased` heading to `## vX.Y.Z`, all in the
  same commit — see the README's "Releasing a new version".
- **Fixture comment urls in `dev/planning-tests.sh` use GitHub's real shape**,
  `https://example.invalid/<issue>#issuecomment-<id>`, never the invented `...#c<n>` form —
  a future URL-parsing change could otherwise pass the whole fixture suite against a shape no
  real GitHub comment url has and fail closed on every live run (#220), with one deliberate,
  gate-required exception (the `impl-plan-comment-id-unparseable` fixture, documented in that
  file's header comment). Assertion 4.31 enforces this mechanically for the full-url literal
  values in that one file only; it does not check the id-allocation scheme (documented in the
  file's own header comment) or a bare `#c<n>` mention in prose.
