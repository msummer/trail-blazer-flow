# Project lessons for workflow subagents

Project-specific gotchas that the issue-planner and issue-implementer skills inject into
every subagent prompt. **This file is owned by THIS project** — it stays with the repo if
the skills toolset is updated or reinstalled. Append a dated entry whenever something
bites: 1–3 lines, written as an instruction to a future agent.


- 2026-08-21: `dev/selfcheck.sh` 4.14 caps every `skills/*/SKILL.md` at a line budget with only 1-5
  lines of headroom (table `budget_table` in the script). Any change that lengthens a SKILL.md must
  raise that file's cap in the same PR, using the script's recipe (cap = next multiple of 5 strictly
  above the new line count); a forgotten cap is a red gate, not a style nit. `references/*.md` and
  `agents/*.md` are unbudgeted.
- 2026-08-21: Any awk/sed slice of a CLAUDE.md section (`/^#+[[:space:]]+Title/ … exit on the next
  heading`) must be fence-aware: a `#`-prefixed comment INSIDE the section's fenced block is not a
  heading. Toggle on ``` lines and only exit on a heading-shaped line outside a fence (see
  `bin/check-decision-record.sh` `claude_md_block`), and pin it with a fixture whose block carries a
  `#` comment between two data lines. Found by the verifier on #107 (false "grant will deliver").
- 2026-08-26: `hooks/git-c-guard.sh` exits before `jq` unless the raw stdin contains the literal
  substring `git -C`, so every `dev/hook-tests.sh` no-opinion fixture must carry that substring
  (usually as a second, conforming `&& git -C <wt> …` segment) or it passes vacuously without ever
  reaching the check it claims to pin. Prove a new case by deleting the guarded line and watching it
  fail. Found by the verifier on #150 (`attached-C`/`double-C` never reached the `t1 == "-C"` check).
- 2026-08-26: When a plan asks for a comment or README sentence that says where another block lives
  ("above", "below", "right after", "in the toolchain block"), pin every such word against
  `grep -n '^# ---' <script>` (the section banners) before reporting, and keep parallel enumerations
  (a README list and a script-comment list of the same checks) identical item-for-item. The verifier
  re-derives each location claim from line numbers; on #156 two contradictory direction words and a
  four-vs-five item list were the only round-1 findings.
- 2026-08-30: A doc bullet that says a rule is "enforced mechanically (assertion N)" must scope the
  claim to exactly what that assertion checks — split enforced-vs-convention clauses like the
  assertion-1.4 bullet does. On #163 the only kickback was an unqualified "enforced mechanically"
  covering a two-clause rule of which 4.24 checks one clause.
- 2026-09-01: A shipped test comment or doc sentence claiming a mutation proof or a "pins X"
  guarantee must state the proof that was ACTUALLY run: apply the mutant, watch the named case
  fail, then write that measured result into the artifact. Disclosing a substituted proof only in
  the report is not enough — the artifact still lies. All three round-1 kickbacks on the
  #179/#182/#174 train were this class (a disproven proof left in a comment; a "pins" claim whose
  mutant survived the whole suite; a "no second warn" claim with no assertion behind it).
- 2026-09-01 (b): When a diff deletes or reshapes code, walk EVERY existing test-case comment whose
  mutation recipe names that code — including comments in cases the diff doesn't touch — and restate
  + re-measure each one against the new shape. On #186 the only kickback was a neighbouring #179
  case comment still "measuring" a mutant against a deleted `[ -d .github/actions ]` gate; the plan
  had even listed it under "Claims this change falsifies".
- 2026-09-01 (c): A stub that models an external tool must reproduce the tool's DOCUMENT semantics,
  not just its filter text: `gh api --jq` applies the filter to each page (a JSON array) as one
  document. The planning-tests stub prepended its own `.[] |`, so the script's missing prefix passed
  all fixtures while every live run failed closed (#196). Prove a stub faithful by running the real
  tool's exact invocation once against live data and diffing the shapes.
- 2026-09-04: When a plan enumerates the fixtures for a gate-executed jq program, derive one fixture per `select(...)` clause — a case whose ONLY distinguishing property is that clause (e.g. a trusted keyless comment NEWER than a trusted escalation, to pin the escalation-key select) — not one per happy path. On #199 the plan listed six fixtures, all blind to deleting the escalation-key filter, and the whole gate stayed green under that mutant; the verifier caught it (round-1 kickback). Prove each fixture by applying the clause-deleting mutant and watching that fixture, and only it, fail.
- 2026-09-04 (b): A negative-test perturbation that RENAMES an identifier must remove or alter
  characters inside it, never append a suffix — the gate's `grep -qF` substring-matches, so
  `covered_by_approval` → `covered_by_approvals` still matches and the case passes vacuously
  (found by the implementer on #206; the plan had copied the suffix recipe). Measure every new
  selfcheck-tests case with its mutant applied before writing its description.
- 2026-09-06: A stale-total sweep must grep the BARE old number (`grep -n '73' <file>`), never
  phrasings or an enumerated list — on #217 the pattern sweep (`grown to N|held N|N cases`) missed
  "now 73 after #217" and "then 73 (#217", costing a verification round; on #192 an enumerated list
  missed one site the same way. Then check every count word the diff wrote ("five cases") against
  the real count after the LAST case is added.
- 2026-09-06: An assertion's comment and its PASS/`ok` message must describe the predicate actually
  coded, not the intent: prove it by feeding the guarded file a value that satisfies the code but not
  the claim (on #220, 4.31 said "#issuecomment-<digits>" while the check was a `#issuecomment-`
  substring test, and the deliberate `12x3` fixture passed it). Same for a stub comment's claims
  about the scripts it models — grep the scripts before writing "the script checks X".
- 2026-09-07: When re-running an EXISTING mutation-proof claim to add a new fixture to its failing
  set, actually re-run it rather than assuming the failing set only grows by the new cases — on
  #230, `impl-plan-after-approval`'s own "65 pass/1 fail" claim (recorded 2026-09-05) had already
  gone stale when #213 landed a sibling fixture that reaches the identical branch, and nobody
  re-measured it before this PR; the true figure was 2 failures, not 1, predating #230 entirely.
- 2026-09-07: When doing a measure-mutate/run/revert loop with a plain `cp <backup> <file>`
  restore, refresh `<backup>` immediately before EVERY mutation, never once at the top of a long
  session of Edit-tool-and-sed interleaving — an Edit-tool text change made between two `cp`
  restores is invisible to `diff`/`cp` and gets silently discarded by the next revert. Verify every
  restore with a full (non-truncated) `diff <backup> <file>` showing exactly the one mutated hunk,
  never `diff | head`, which can hide a bigger discard.
- 2026-09-08: When an acceptance criterion names two modes or branches ("in both `--fix` and
  report-only modes", "at step 2a and step 2e"), the plan's fixture list must carry one case per
  mode — a criterion the fixture list covers only on one side ships with a surviving mutant on the
  other. On #231 the plan enumerated five `--fix` fixtures for a criterion that named both modes;
  the verifier's `if $FIX` wrap survived all six suites and cost a verification round. Derive the
  fixture set from the criterion's own enumeration, not from the happy path.
- 2026-09-08 (b): A fixture runner that captures `> out 2>&1` cannot pin any criterion that names a
  stream ("usage on stderr", "`run-id=` as the last line of stdout") — a `>&2` redirect mutant
  survives the whole suite. Capture stdout and stderr to separate files and assert on the named
  stream with stream-specific helpers; say in the runner comment which claims are asserted
  per-stream and which only against the merged capture. On #232 this class cost two of three
  verification rounds (round 1: usage-on-stderr; round 2: run-id-on-stdout).
- 2026-09-08 (c): A `see "X" above/below` cross-reference must name a heading that exists in the SAME
  file — run `grep -n '^#' <file>` and pin both the name and the direction word against the line
  numbers before writing it — and cite a section that lives in another file qualified (the
  implementer skill's "Status line" section). A fix that repairs one claim in a paragraph can introduce a
  fresh dangling one: on #233 the round-1 fix to the README's "Updating" paragraph pointed at a
  "Status line" section only `skills/issue-implementer/SKILL.md` has, costing a third round.
- 2026-09-08 (d): A token walk with a once-only skip or flag (`!saw_prefix && …`) ships with a surviving
  evasion unless the fixture set carries 0, 1 AND 2+ occurrences of the skipped class — on #235 every
  prefix fixture had exactly one prefix word, so `sudo bash -c "git push"` was no-opinion while the
  README's evasion enumeration said it was caught, and 22 measured mutants never touched it. Derive
  fixtures from each loop's boundary (none / one / repeated), not from the plan's one-of-each examples,
  and have the verifier feed the script its own chained forms.
- 2026-09-09: A script header's "documented evasions / under-blocking classes" inventory is a set of factual claims
  about the code — measure EVERY named class against the real script (feed it the exact command, record the rc)
  before writing it, and re-measure after any tokenizer edit. On #260 the shipped header named an attached
  `--git-dir=<path>` form as an evasion that the parser in fact denied, and omitted the real class the plan named
  (an unlisted two-token global option, `git --foo bar push …`); one verification round. Same rule as LESSON
  2026-09-01, applied to "what this control does NOT catch" claims, which reviewers read most closely.
- 2026-09-09 (b): For any script with raw-stdin fast paths (a substring test that exits before parsing), EVERY
  no-opinion fixture's raw stdin must contain every fast-path substring — or its case row must name the fast path
  that excludes it and state that the slow path re-derives the same verdict. On #260 `bash hooks/push-guard.sh`
  carried `push` but not `git`, so the case exited at fast path 2 while its comment claimed to exercise the
  tokenizer's basename step; LESSON 2026-08-26 stated this for `git -C` only — it is general.
- 2026-09-09 (c): When an acceptance criterion names TWO old totals for a bare-number sweep ("98, 97"),
  grep each number separately and walk every hit, including chains that were already stale on main
  before this PR (a gap a previous PR left is still in scope once the criterion names its number) —
  and record the sweep itself (the grep commands and the walked hits) in the report's Evidence, not
  a prose-regex sweep in its place. On #246 the `98` sweep was complete but six `97` growth chains
  and one survivor enumeration were left at 97 (suite: 100); one verification round.
- 2026-09-09 (d): When case comments cite a shared MEASURED-MUTANTS block by letter (`Mutation proof: (k) …`),
  finish by walking EVERY citation letter → block entry → "its recorded failing set names this case: yes",
  and confirm every new case carries one — a swapped letter pair reads as a proof that does not cover the
  case it sits under, and a case with no citation ships unproven even when the measurement exists in the
  block. On #248 two letters were crossed and two of twelve new cases had no citation; one verification round.
- 2026-09-10: A growth-chain note's "why the N new cases do / do not join this proof's failing set" reason is a
  factual claim about MECHANISM, distinct from its (measured) figure — verify each clause against what the fixture
  actually does (which script it runs, which fixture files it writes, which `--json` list that script sends, which
  stub arm answers, whether the MUTANT — not the case — touches that path) before writing it, never by copying the
  neighbouring proof's reason onto a new subject. On #275 eight such reasons shipped with correct-looking figures
  and false mechanisms across three verification rounds ("never reach `read_issue_authors()`" for planner fixtures
  that always do; the implementer's `--json` shape attributed to planner fixtures; a proof's "stub-direct-call"
  case property mistaken for its mutant's reach, hiding a genuinely stale 79/33 set), exhausting the kickback
  budget on prose alone. When a plan extends many chains at once, re-MEASURE every proof whose mutant edits a
  script the new fixtures run, and treat the reasons as a set to audit together — the defect recurs across sites
  written in the same sitting.
- 2026-09-14: A `dev/hook-tests.sh` case-description string that names a real shell variable (e.g. "not
  `$gitdir`") inside the double-quoted `cases=()` array literal is itself variable-expanded by THIS
  file's own `set -uo pipefail` — an unset variable in the HARNESS's scope (not the hook under test's)
  crashes the whole run with "unbound variable" before any case executes. Escape it as `\$gitdir` in
  prose. On #268 this crashed `bash dev/hook-tests.sh push` outright (caught immediately, no verification
  round lost, but only because the run was watched rather than piped to a summary line).
- 2026-09-14 (b): the shared `PATH_ERE` predicate (`hooks/git-c-guard.sh`/`hooks/push-guard.sh`)
  anchors on the path's FINAL component ending `-wt-[0-9]+` — a fixture directory name with any
  suffix AFTER that digit run (e.g. `target-wt-1-a5`, meant to read as "target A5, a worktree")
  silently fails the predicate and degrades to no-resolution, instead of raising an error. On #269
  three fixtures (and two of the ten new mutants' own discriminators) were originally named this
  way and passed anyway, for the WRONG reason — vacuously, via the pre-#269 session-only code path
  — until a mutant's failing set exposed each one; the fix was renaming to `target-a5-wt-1`
  (digits-then-suffix moved before `-wt-<n>`). When adding a `-wt-<n>`-shaped fixture path, put any
  disambiguating suffix BEFORE `-wt-<n>`, never after, and confirm the predicate actually matches
  with a direct `grep -qE "$PATH_ERE" <<<"$path"` probe before trusting the fixture's verdict.
- 2026-09-15: A header sentence that generalises how the push guard's whitespace tokenizer treats a QUOTED
  `-C` value ("a bare remainder hides the segment", "a remainder other than `push` hides it") failed four
  verification rounds on #269, each time to a freshly measured shape. The only statement that survived is the
  tokenizer's own rule applied to the RAW fragments with quote characters still glued on (`-c` pairs with the
  next fragment, `-c"` is merely dash-skipped; `x/push"` normalises to `push`), plus an enumerated row per
  measured shape and an explicit "no rule is claimed beyond these rows". Measure every row you cite (the
  orchestrator's own prediction for the `-c"` shape was wrong until measured) and cite code by function or
  loop name, never by line number — the edit that adds the citation shifts the lines it points at.
- 2026-09-15: When a new fixture set adds a runner that drives a SHARED stub through a NEW caller
  (dev/planning-tests.sh's `run_status`, calling `bin/harness-status.sh`, which in turn shells out to
  BOTH discovery scripts on the same stub `gh`), every PRE-EXISTING mutation proof whose mutant is an
  in-place edit to one of those discovery scripts (not a `run_script_at` mutant COPY, which a new
  caller can never reach) must be re-checked for reachability, not just proofs whose mutant lives in
  code the new fixtures' own assertions read. On #284/#285, three pre-existing proofs (an
  `authorAssociation`-field injection into `needs_initial_plan`, a `.[].number` deletion in the
  revision-candidates filter, and the `#272/#273` retry-collapse/counts-key-deletion mutants) turned
  out reachable through TWO distinct mechanisms neither obvious from reading the mutant alone: (1) a
  mutation that makes an ALREADY-HEALTHY query in the new fixture fail can abort the whole script
  under `set -euo pipefail`, propagating through the new caller's OWN `set -e`; (2) a mutation that
  merely deletes a PUBLISHED `_unavailable`-suffixed counts key changes nothing for the pre-existing
  suite's own assertions but silently narrows a NEW consumer's generic key-scanning rule (here,
  `harness-status.sh`'s `degraded_reasons`). Reasoning by inspection undercounted both classes on the
  first pass; only an actual re-run surfaced the true failing sets (128/6, 127/7, 129/5, 126/8, and
  more). Budget time to re-measure every in-place mutant on a script the new runner exercises, not
  just eyeball which ones "obviously" don't apply.
- 2026-09-15 (b): Apply a mutant to a `bin/*.sh` script IN PLACE (Edit tool, `sed -i ''`, and `git restore`
  to revert) — never by writing a temp file and `mv`-ing it over the script. `mv` drops the execute bit,
  and `dev/planning-tests.sh`'s runners put `$root/bin` on PATH ahead of an ambient PATH that also carries
  the INSTALLED plugin's `bin/`, so a non-executable repo copy silently falls through to the released
  script and the suite measures the wrong binary with a plausible figure (on #284 the verifier got 131/3
  for a true 133/1). Check `[ -x bin/<script> ]` after every mutation before trusting a figure.
- 2026-09-16: A jq comment block embedded inside `bin/find-planning-work.sh` or
  `bin/find-implementation-work.sh`'s single-quoted `jq '...'` bash string cannot contain a literal
  apostrophe anywhere in its prose — bash single quotes have no escape, so a possessive ("the
  comment's first line") or a contraction ends the string early and the remainder of the script
  becomes a syntax error (`bash -n` catches it immediately, but only if you run it). Header
  comments OUTSIDE the jq invocation (plain `#`-prefixed bash comments) have no such restriction —
  the two live side by side in these scripts, and it is easy to draft one paragraph in prose with
  apostrophes and paste half of it into the jq block by mistake. On #281 this broke both scripts on
  the first edit; `bash -n <script>` after every edit to a jq-embedded comment catches it for free.
- 2026-09-16: A fixture meant to isolate "a RESOLVED secondary checkout also reads route X" from
  "the SESSION already reads the identical route X" is silently confounded whenever BOTH checkouts
  independently satisfy the same read precondition — on #290, `push-deny-c-target-global-route`'s
  first draft gave the session an ordinary fixture repo, so the session's OWN `resolve_repo()` call
  ALSO read the same environment-sourced global config file the "-C" target was meant to isolate;
  `apply_c_target()`'s own body-replaced-with-":" mutant (M46) then failed to flip it, because the
  session's already-denying facts, never overwritten, denied on their own. The fix: make the
  SESSION resolve to NO repo at all (so its own read of the shared route never happens), leaving
  the "-C" target as the only path to the deny — discovered only by manually applying M46 to the
  first draft and watching it survive; reasoning about the fixture's prose was not enough. When a
  fixture's own claim is "route X applies to resolution path A, not just path B", and A and B are
  both read from an environment-wide or otherwise-shared source (not something scoped to a single
  checkout), build B so it does NOT independently satisfy the read precondition, and confirm by
  applying the discriminating mutant before trusting the fixture's citation.
- 2026-09-16 (b): A homemade `awk` sweep for a stale bare number (e.g. `grep -n '141'` per LESSON
  2026-09-06) must build its comparison buffer from `$0` alone. Annotating each line with its own
  `NR` (`buf = buf "\n" NR ": " $0`) can hide a genuinely stale block: one still naming the OLD
  total but never the new one reads as already-fixed whenever some line's own number happens to
  contain the NEW total as a substring (e.g. line 7150's `NR=7150` makes the buffer look like it
  mentions "150"). Grep the raw file text directly, never a debug-annotated copy.
- 2026-09-23: GitHub caps a label DESCRIPTION at 100 characters — `gh label create/edit --description` with
  a longer string is a 422 that, under `bin/setup-labels.sh`'s `set -euo pipefail`, aborts the whole
  script at that label (later labels never created, "Labels are set up." never printed). No suite
  catches it: `dev/doctor-tests.sh`'s stub `gh` serves the label list from `create_or_update` names
  and never validates the description. Before adding or editing a `create_or_update "…" "…" "…"`
  line, measure the description (`awk '{print length($0)}'`) and keep it ≤ 100 — #346 shipped 109
  characters and the live post-merge `bash bin/setup-labels.sh` run failed on the first run.
