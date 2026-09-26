# Architecture decision records

Decisions about the harness's direction that outlive a single issue or pull request. `README.md`
and [`docs/reference/`](../reference/README.md) stay the canonical spec of current behavior; an
ADR records *why* a direction was chosen and what it commits the project to. When a later decision changes one, the ADR is amended with a dated note
or superseded by a new ADR — never silently rewritten.

- Files are numbered `NNNN-kebab-title.md` and never renumbered.
- Sections: Status, Context, Decision, Consequences — plus Alternatives and Implementation where
  they help.
- Status is one of Proposed, Accepted, Amended (with a dated note), or Superseded by `NNNN`.
- Code references are pinned to the commit they were verified at; their line numbers are not
  maintained afterwards.

| ADR | Title | Status |
|---|---|---|
| [0001](0001-autonomy-mode.md) | Autonomy mode | Accepted 2026-09-16; amended 2026-09-25 |
| [0002](0002-codex-compatibility.md) | Codex compatibility | Accepted 2026-09-16 (direction); amended 2026-09-26 (probe results, min Codex 0.156.1) |
