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
CI on every pull request (`.github/workflows/selfcheck.yml`, one job on `ubuntu-latest`); a red
check there means one of the job's two commands failed — reproduce locally with
`bash dev/selfcheck.sh` and `bash dev/selfcheck-tests.sh`. There
is no test suite and no build step: this repo is Markdown instruction files, Bash scripts, and
JSON manifests, so the gate checks shell syntax/portability (including no GNU-only shell
constructs in `bin/*.sh` or `dev/*.sh`), JSON manifest validity, and the cross-file
instruction-file contracts the skills silently depend on (the `<!-- planner-plan -->` marker, one
`# Constraints` section per agent, the harness-status line grammar, no constraint keyword
restated across sections of the same file — extended to `skills/*/SKILL.md`'s merge-authority,
push-boundary, sequencing, and read-only language — the `<!-- ratchet-issue -->` marker, the
follow-up justification phrase shared by `agents/planner.md`'s plan template and the implementer
skill's filing step, the `setup-labels.sh` ↔ doctor label bijection, the policy-section titles the
skills read, that
`bin/check-harness.sh` reads `.claude/settings.json` only through `jq` (never a raw-text
grep/sed/awk of the file), the CI workflow's gate command, `agents/verifier.md`'s lettered
Process checks `a.`–`g.` matching
CLAUDE.md's own `rule Nx` citations, and the git permission-mirror invariants in
`templates/repo-settings.json` — the `-C` allow forms `skills/issue-implementer/SKILL.md`
mandates, and the bare↔`-C` mirroring of its own git allow/deny entries), plus the behavior of
`bin/reconcile-ledger.sh` against fabricated inputs. A change the gate can't catch needs a new
assertion in the gate, not a waiver.

`dev/selfcheck-tests.sh` is the gate's own negative-test harness — a separate script, not part
of the gate itself, that copies this repo to a throwaway temp directory, applies one documented
perturbation per case, and asserts the gate fails with exactly the expected assertion id(s). It
also runs in CI, as a second step after the gate in the same job; run it by hand
(`bash dev/selfcheck-tests.sh`) whenever `dev/selfcheck.sh` changes, and add a case for every new
assertion.

This repo deliberately does **not** aim to pass `bin/check-harness.sh` — that script is the
*consumer* doctor. Onboarding it here would mean checking in a `.claude/settings.json` that
registers this repo's own published marketplace (with `autoUpdate: true`) and enables a cached
copy of itself over the working tree being edited; see the README's "Working on the harness
itself".

## Conventions

- **Plugin/consumer boundary**: nothing project-specific belongs in `agents/` or `skills/` —
  that content belongs in a *consumer* repo's `CLAUDE.md`/`LESSONS.md` instead. See the README's
  "Distribution".
- `bin/` is on consumers' Bash PATH; every `bin/*.sh` needs a matching allow entry in
  `templates/repo-settings.json` (the gate's bijection assertion checks this). Scripts meant
  only for developing this repo (not for consumers) go in `dev/` instead.
- `*.sh` files are LF-only (enforced by `.gitattributes`) and must stay portable across BSD
  (macOS) and Git-Bash userlands — no GNU-only flags (`sed -i` without a suffix, `grep -P`,
  `readlink -f`, `mapfile`/`readarray`, `declare -A`). Assertion 1.4 enforces this on `bin/*.sh`
  and `dev/*.sh`.
- The README is part of "done": every factual claim it makes about this repo's behavior must be
  checkable against the code (the verifier applies its rule 3g to docs).
- Release ritual: bump `version` in `.claude-plugin/plugin.json` and create the matching
  `vX.Y.Z` annotated tag, in the same commit — see the README's "Updating".
