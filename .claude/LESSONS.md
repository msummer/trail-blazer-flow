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
