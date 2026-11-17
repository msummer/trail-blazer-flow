# The cycle note (best-effort, opt-in)

This file is the procedure for the issue-cycle's closing tracker step when the Tracker fence holds
`cycle-note: on` (#650). `SKILL.md` decides when to run it; the document's format, caps and limits
are in `docs/reference/tracker.md`, "The cycle note". The script builds the whole document from the
ledger — you never compose it.

**Best effort.** Any failure is one `tracker: cycle note skipped — <reason>` line in "what this
cycle did"; it never fails, stops, delays or reorders the run.

## Steps

1. Stop silently if the Sync printed `tracker: skipped — artifact tools unavailable in this
   session` or stopped on `tracker=malformed`. That covers Codex, headless runs and subagents.
2. Run `tracker-sync.sh cycle-note <run-id> - <<'LEDGER'` … `LEDGER`, pasting step 0's run id
   literally as the argument (never a heredoc line), then the same plain ledger records step 5
   piped to `reconcile-ledger.sh`, ending with a line holding only `LEDGER`. Plain records only — never a
   `<!-- harness-status: … -->` line; the script rejects it. `tracker=absent` or `cycle-note=off`
   means stop silently. Anything other than exit 0 with `result=ready` means print
   `tracker: cycle note skipped — <first stderr or reason= line>` and stop.
3. `ArtifactData` `get` with the printed `url=`, collection `sections`, doc `last-cycle` and
   `out_dir` set to your session's scratch directory, never the printed `dir=` or anything under
   `.git/`. Take `version` from the get result only. A not-found doc is a first write (no
   `if_version`). No scratch directory, a get error, or a found doc with no version means print
   the skip line and stop.
4. `ArtifactData` `batch` with one entry `{op: set, collection: sections, doc_id: last-cycle,
   file_path: <the printed file=>, if_version: <version>}`. On a version conflict, re-get as in
   step 3 and re-send once; any other error is the skip line.
5. Report `tracker: cycle note written — <issues=> issues, <run-id>`.

## Rules

- Never read the printed `file=` or the fetched doc inline, never compose or edit the document,
  and never write another doc here.
- The heredoc is covered by the existing `Bash(tracker-sync.sh:*)` grant, the same way step 5's
  `reconcile-ledger.sh` heredoc is; if it is ever prompted or denied, that is the skip line.
