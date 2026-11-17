# The live tracker (opt-in)

> Part of the [reference documentation](README.md). A quoted section name such as "Safety model"
> or "The CLAUDE.md contract" refers to a heading in this reference set or in the top-level
> [README](../../README.md) — the [index](README.md#where-each-section-lives) says which file holds it.

A repo can have one **live tracker**: a private artifact page showing every open milestone's issues
with their state, PR links, dependencies and progress, what is waiting on you, and what shipped
in the last 14 days. GitHub stays the source of truth; the tracker
is a projection of it, rebuilt in full on every sync, so a missed or failed sync fixes itself on
the next one. **Nothing flows from the tracker to GitHub**: it never changes an issue, label, PR or
comment, and each row links to its issue, where you comment directly.

Three parts:

- `bin/tracker-sync.sh` — read-only and mechanical. It reads the repo's "Tracker" section, queries
  `gh`, reads the checkout's local verification baseline file, and writes one snapshot file; its
  `cycle-note` mode writes the opt-in cycle note's document (see "The cycle note"). It never calls
  an artifact tool.
- `skills/tracker/SKILL.md` — the procedures (Create, Sync, People read-back, Hand-written update).
  Only the orchestrating session can run them: the `Artifact` and `ArtifactData` tools exist
  nowhere else.
- `templates/tracker/index.html` — one generic page, with no project content apart from the
  repo's short name. Everything specific to a repo lives in the artifact's database.

## The "Tracker" section (CLAUDE.md contract item 11)

A heading titled exactly "Tracker" (any `#` depth) whose first fenced block holds the `url:` line
and, optionally, `section:` and `label-state:` lines:

````markdown
## Tracker

```
url: https://<the artifact's address>
section: milestones docs/roadmap.md#Milestones
label-state: waiting-on-vendor=external
cycle-note: on
```
````

Blank lines and `#` comment lines inside the fence are skipped; any other line is an unknown key.

| Key | Times | Value |
|---|---|---|
| `url:` | exactly once | starts `https://` and holds no whitespace, control character, quote, angle bracket or backtick (`bad-url` otherwise) |
| `section:` | 0 to 8 | `<id> <path>#<heading>` (`bad-section` otherwise): an id of 1-40 characters from `a-z0-9-`, starting with `a-z0-9` and unique; whitespace; a repo-relative path of 1-200 characters from `A-Za-z0-9._/-` ending in `.md` (a last segment of exactly `.md` is rejected), with no leading or trailing `/` and no empty, `.` or `..` segment; `#`; and the exact heading text, trimmed, 1-120 characters, with no control character and not starting with `#` |
| `label-state:` | 0 to 8 | `<label>=<state>` (`bad-label-state` otherwise): a label of 1-50 characters from `A-Za-z0-9 ._:/+-` (a space is allowed; whitespace before the `=` is trimmed), exactly one `=`, and a state that is exactly `parked`, `external` or `held`. The label may not be one the state chain reads itself (`plan-proposed`, `plan-approved`, `pr-open`, `impl-blocked`, `needs-human`, `no-plan`, `triaged-held`), and no two labels may be equal ignoring ASCII case |
| `cycle-note:` | 0 or 1 | exactly `on` or `off` (`bad-cycle-note` otherwise, also for a repeated key); absent means `off` |

No heading, or no `CLAUDE.md`, means the repo has no tracker. A malformed section makes each sync
print `tracker=malformed` and `reason=<token>` (`no-fence`, `unknown-key`, `no-url`,
`multiple-urls`, `bad-url`, `bad-section`, `bad-label-state`, `bad-cycle-note`, checked in the order `unknown-key`,
`no-url`/`multiple-urls`, `bad-url`, `bad-section`, `bad-label-state`, `bad-cycle-note`) and skip. The section is read from the working
tree; a `section:` file is read from the default branch at the snapshot's `mainSha`, never from the
working tree (see "Repo-file sections"). The doctor does not validate it. The section
is committed, so a wrong URL is a reviewed change; a URL copied from another repo's tracker would
be overwritten by this repo's snapshot, and the page's `repo` field makes that visible.

## `tracker-sync.sh`

`tracker-sync.sh` (sync), `tracker-sync.sh page` and `tracker-sync.sh cycle-note <run-id> -`. Exit 0 = ready or absent; 1 = malformed
section or skip; 2 = usage or environment error (unknown argument, not in a git repository, `jq`
or `gh` missing). Output goes to `<absolute git-common-dir>/trail-blazer/tracker/`, never into the
tracked tree.

Sync prints, one `key=value` per line:

| Outcome | Lines |
|---|---|
| no section | `tracker=absent` (no `gh` call, nothing written) |
| malformed | `tracker=malformed`, `reason=<token>` (exit 1, no `gh` call) |
| ready | `tracker=present`, `url=`, `dir=`, `file=<dir>/state.json`, `collection=harness`, `doc=state`, `issues=<n>`, `milestones=<m>`, `truncated=<true\|false>`, `checked=<checkedAt>`, then one `warn=<token> section=<id>` line per dropped section (tokens `section-missing`, `section-too-large`, `section-no-heading`, `section-empty`, in declaration order), then `result=ready` |
| skip (exit 1) | `result=skip`, then `reason=query-failed site=<repo\|milestones\|issues-open\|issues-closed\|issues-recent\|prs\|branch\|ci\|tree\|section\|issues-refs>`, `reason=too-large bytes=<n>` or `reason=build-failed` |

Every `gh` call is a read (`repo view`, `issue list`, `pr list`, GET `api`), and none is retried:
any failure fails closed, removes `state.json` (a stale one from an earlier run included) and
skips, so a partial or outdated snapshot is never pushed. A snapshot over 1,000,000 bytes is
skipped the same way.

`page` writes `templates/tracker/index.html` with `@REPO_NAME@` replaced by the repo's short name
to `<dir>/index.html` and prints `tracker=<absent|present|malformed>` (plus `url=` or `reason=`),
`page=<dir>/index.html` and `result=ready`. It does not need a well-formed section.

`cycle-note <run-id> -` reads the ledger on stdin (see "The cycle note") and prints, in this
order, one of:

| Outcome | Lines |
|---|---|
| no section | `tracker=absent` (exit 0) |
| malformed | `tracker=malformed`, `reason=<token>` (exit 1) |
| key absent or `off` | `tracker=present`, `cycle-note=off` (exit 0) |
| skip (exit 1) | `result=skip`, then `reason=bad-run-id`, `reason=bad-ledger line=<n>`, `reason=too-large issues=<n>` or `reason=build-failed` |
| ready | `tracker=present`, `url=`, `dir=`, `file=<dir>/last-cycle.json`, `collection=sections`, `doc=last-cycle`, `issues=<n>`, `result=ready` |

In the first three rows it reads neither the run id nor stdin. It makes no `gh` call, and apart
from short-lived temp files in `<dir>`, removed on exit, the only file it writes is
`<dir>/last-cycle.json`, which it removes first, so a skip never leaves a stale one. It never touches `state.json`. A wrong argument count, or a third argument other than `-`, is
exit 2 with no stdout. The `cycle-note:` key changes nothing about a sync's stdout or `state.json`.

## The snapshot document

One document, `harness/state`, written only by Sync as a full `set`:

```
{schema:1, repo, repoUrl, checkedAt, defaultBranch, mainSha,
 health:{ci:"passing"|"failing"|"pending"|null, ciUrl:<https url>|null,
         baseline:{commit,date|null,results:[{command,detail}]}|null, baselineCurrent:bool|null},
 truncated,
 milestones:[{number,title,url,dueOn|null,open,closed}],
 issues:[{number,title,url,state,milestone:<number>|null,
          pr:{number,url,state}|null, blockedBy:[{number,url,open}], waiting}],
 counts:{<state>:n..., total, waiting},
 sections:[{id,title,kind:"table",source,columns:[..],rows:[{cells:[..],issues:[n..]}],truncated}
          |{id,title,kind:"list",source,rows:[{text,issues:[n..]}],truncated}],
 refs:[{number,title,url,state}],
 recentSince, recent:[...], openPrs:[...], waitingOnYou:[...]}
```

`sections` and `refs` are always present, and empty when the "Tracker" section declares no
`section:`.

The last four keys are described under "Recently shipped and waiting on you"; they are additive,
so `schema` stays 1.

Issues are sorted by number, milestones by due date (none last), then number. Scope of `issues[]`:
the open and closed issues of the open milestones (only the first 100 open milestones are read), plus every
other open issue. An open issue with no milestone, or whose milestone is closed or not read, is
listed with `milestone` null and shown under "No milestone". A milestone's `open` and
`closed` count the issues listed. `refs` holds the closed issues that a section row references by
`#<n>` and `issues` does not hold (see "Repo-file sections"); it never changes `issues`, `counts` or
a milestone's counts. `state`, first match wins:

1. closed with reason `NOT_PLANNED` → `not-planned`; any other closed issue → `done`
2. label `needs-human` → `needs-human`
3. `impl-blocked` → `blocked`
4. `pr-open` → `pr-open`
5. `plan-approved` → `approved`
6. `triaged-held` → `parked`
7. a label a `label-state:` line maps → that line's state
8. `no-plan` → `held`
9. `plan-proposed` → `planned`
10. otherwise `unplanned`

A `label-state:` mapping is compared with the issue's labels ignoring ASCII case, and the first
declared mapping that matches wins. It never overrides a closed issue or items 2 to 6, and always
overrides `held`, `planned` and `unplanned`. The vocabulary is closed: `waiting` is not in it,
because `counts.waiting` is the open-blocker count. The mapping is read from the working-tree
`CLAUDE.md` like the rest of the section, adds no query, and its label names are never stored in
the snapshot. `counts` holds a `parked` or `external` key only when some issue has that state. A
label with a character outside the mapping's charset (an emoji, for example) cannot be mapped. A
page published before this change shows the two new states as muted badges until it is
re-published.

`pr` is the highest-numbered PR whose head branch is `claude/<n>-...` (the harness's own
branches); a human-authored PR is not linked there (it still appears in `openPrs`). `blockedBy` is GitHub's native issue dependencies
only, and `waiting` is true iff any blocker is open. One snapshot document, rather than one per
issue, means a sync carries a single `if_version` (the database refuses a write to an existing
document without one), needs no chunking and no deletes for issues that leave scope, and updates
the page atomically.

`health` is the page's strip under the header. `ci` comes from one GET of the check runs on
`mainSha` (checked as lowercase hex before it enters the API path). Only the newest run of each
check name counts. Then, first match wins: `failing` if any is completed with a conclusion other
than `success`, `neutral` or `skipped`; `pending` if any is not completed; otherwise `passing`; `null`
when no run came back. `ciUrl` is the `https` link of the first run of the deciding class, by
name then id. A failed or malformed CI read is a skip with `site=ci`, like every other query.
`baseline` is read from the working tree's `.claude/BASELINE.md` (the file the harness writes),
never written: the first `- commit:` (7 to 40 lowercase hex), the `- date:` (`YYYY-MM-DD`, else
`null`) and the indented ``- `<command>`: <detail>`` lines directly under `- results:`, at most 50,
each string cut to 200 characters. A missing file, a non-file, one over 65,536 bytes, or one with
no valid commit is `baseline: null` and never a skip. `baselineCurrent` is true iff `mainSha`
starts with the baseline commit, and `null` without a baseline; the page shows "baseline behind
main" only when it is `false`.

Honest limits: PR links come from the newest 200 PRs only, so an older issue's PR may show no link
(this does not set `truncated`). `truncated` is true when the open list reaches 1,000 issues, a
milestone's closed list reaches 500, the recent closed-issue search reaches 200, or a dependency
list is longer than GitHub returned.
CI reads check runs only (a CI that reports only legacy commit statuses shows "no checks"), and only
the first 100 runs GitHub returns, so a check whose newest run is not among them is not shown; a
token without checks read access makes every sync skip with `site=ci`. The baseline belongs to the
machine that syncs: another checkout's baseline is not seen, and a missing file shows "no baseline".
Baseline command names and outcomes are stored in the artifact too.
Issue and PR titles, author and merger logins, head branch names, people notes and the content of
every declared repo-file section of a private repo are stored in the artifact: it is created
private, and sharing it exposes them to the people you share with. Only owners and editors
can write to its database (the `admin` write rule); collaborators who cannot edit see the page but
get a refusal when they try. A page-template upgrade is not pushed to an existing tracker: it is
re-published by hand from the same checkout, because "re-publishing the same file path updates the
same URL" and the page path is per checkout.

## The cycle note

With `cycle-note: on`, the `issue-cycle` closing step writes one more document, `sections/last-cycle`
(`kind:"list"`, `order:-1`, so the page shows it first), from the run's dispatch ledger. The model
never composes or reads it: `skills/issue-cycle/references/cycle-note.md` runs `tracker-sync.sh
cycle-note` and pushes the file it names with a pinned `batch` `set`, the way Sync pushes the
snapshot.

```
sections/last-cycle: {schema:1, title:"Last cycle", order:-1, kind:"list", titles:true, runId,
                      finishedAt, source, updated, items:[{text, issues:[n], pr?:n}]}
```

- **Ledger grammar.** Plain records only, one per line (blank and `#` lines skipped, CR stripped):
  `<issue> <stage> <outcome> [retries] [deploy=<slug>] [pr=<n>] [harness=<v>]`. The issue is digits
  with no leading zero, 10 at most. The stage is `seed`, `planner`, `implementer`, `verifier` or
  `merge`; the outcome is `-` or a slug of that stage in `bin/reconcile-ledger.sh`'s vocabulary
  (a fixture pins that the script's copy stays equal). Each optional token appears at most once;
  `deploy=` is merge-only, `pr=` implementer- or merge-only, `harness=` is ignored. Any other line,
  a status line included, skips the whole note with `bad-ledger line=<n>`; no ledger text is ever
  printed. The run id must have `harness-lock.sh`'s shape.
- **Content.** One item per issue in ascending order: the stages present (planner, implementer,
  verifier, merge; the last record per stage wins) as `<stage> <outcome>` joined by `; `, then
  `deploy <slug>` when the merge record carries one; an issue with only a seed record reads
  `not dispatched`. `pr` is the last `pr=` seen for the issue. More than 200 issues skips with
  `too-large`. `finishedAt` is the UTC time the script ran.
- **Rendering.** `titles:true` makes the page join each issue's title from the snapshot after its
  `#n` link, as text; an item's `pr` is a `PR #<n>` link built from the snapshot's `repoUrl`. A
  hand-written list without `titles` renders as before.
- **Limits.** Titles show only for issues in the snapshot (open issues, closed issues of open
  milestones and `refs[]`); others show a bare `#n`. Turning the key off leaves the last document
  in place until a Hand-written update deletes it. The ledger is model-composed but checked
  against closed vocabularies, so the document can only hold numbers and slugs. Only the
  `issue-cycle` writes it, and the id `last-cycle` is reserved: a hand-written document with that
  id is overwritten at the next noted cycle. Codex, headless and subagent runs have no artifact
  tools, so they never write it. An existing page shows the note without titles or PR links until
  it is re-published.

## Repo-file sections

Each `section:` line projects one table or list from a committed Markdown file onto the page. On
every sync the script reads the file from the default branch at the snapshot's commit, through GET
`git/trees/<tree sha>?recursive=1` and then GET `git/blobs/<sha>` for each declared section; the
working tree is never read for it, and a declared path is only compared as data against GitHub's
tree listing — it is never put in a URL or a command. A tree entry counts only when it is a regular
file (mode `100644` or `100755`): a symlink, a submodule or a directory reads as missing.

The extractor finds the first ATX heading (`#` to `######`) whose text equals the declared heading
exactly, outside fenced code blocks, and takes the first GFM table (a header row followed by a
delimiter row) or the first list under it, up to the next heading of the same or a shallower depth.
A table's cells are split on `|` (`\|` is a literal pipe) and each body row is padded or cut to
the header's width. A list's items are the top-level items; continuation lines and nested items are
folded into their parent's text with one space, and a line at the list's own indent that is not an
item ends it. Limits: 50 rows per section, 8 columns, 200 characters per cell or item, 262,144
bytes per file, 8 sections. A cut sets that section's `truncated`; it never sets the snapshot's.

A `#<n>` in a row counts as a reference unless it follows a letter, digit, `_`, `&`, `/` or `#`, or
is followed by a letter, digit or `_`; at most 10 per row, and a number is at least 1. A referenced
issue that `issues` already holds shows its state from there. For the others, one
`issue list --state closed --limit 500` read (made only when at least one such reference exists,
for the 50 lowest numbers) fills `refs`; a reference that is not among the newest 500 closed issues
stays a bare link.

A section that cannot be projected prints one `warn=<token> section=<id>` line and is left out; the
sync still succeeds. `section-missing`: the path is not a regular file in the tree.
`section-too-large`: the file is over 262,144 bytes (no blob is read). `section-no-heading`: no such
heading outside a fence. `section-empty`: the heading has no table or list under it. A failed query
is never a warning: it skips the sync with `site=tree` (the tree read, or a response that is not a
tree), `site=section` (the blob read, or a blob that is not base64 or does not decode) or
`site=issues-refs`.

The page shows each projected section after the hand-written sections, in declaration order. The
sync never reads or writes the hand-written `sections/<id>` documents, so a snapshot section cannot
overwrite one.

Honest limits: only ATX headings; the heading must match exactly (it is not a GitHub anchor slug);
the first match wins; inline Markdown is shown as typed; a table needs its delimiter row; a very
large repo's tree read can come back truncated, and the file then reads as missing; `refs` covers
only the newest 500 closed issues; section content counts toward the 1,000,000-byte snapshot cap,
so eight large sections plus a large issue set can make the whole sync skip with `too-large`.

## Recently shipped and waiting on you

Two page blocks, "Waiting on you" then "Recently shipped", read four snapshot keys that
`bin/tracker-sync.sh` projects in a second jq pass over the finished snapshot. A snapshot without
those keys, or a page without the blocks, shows no such block; the page needs a manual re-publish
(above) to gain them.

- `recentSince` is `checkedAt` minus 14 days, computed from that one timestamp (no second clock
  read). `recent[]` lists, newest first, every PR merged and every issue closed since then. A PR row
  is `{kind:"pr", number, title, url, mergedAt, author, mergedBy, issue, ci, verifier, soloMerge}`;
  an issue row is `{kind:"issue", number, title, url, closedAt, state:"done"|"not-planned"}`. One
  extra query, site `issues-recent`, searches closed issues by day, and the script filters again on
  the exact time. `author` and `mergedBy` are logins only, never display names.
- `issue` is `<n>` from a `claude/<n>-` head branch, else null. `ci` is `none`, `pending`,
  `passing` or `failing` from the PR's check rollup; a conclusion outside the passing set
  (`SUCCESS`, `NEUTRAL`, `SKIPPED`) and the pending set reads `failing`. `verifier` is
  `pass|fail|incomplete|died` from the last `<!-- harness-status: stage=verifier issue=<n> outcome=<token> `
  line in the PR body whose `<n>` is the linked issue, else null; no other body text is stored.
  `soloMerge` is true when the author and the merger are the same login and no other login's latest
  review is `APPROVED` (the author's own approval is not a second review). It is a flag, never an
  error: when one account both authors and merges, most such PRs carry it.
- `openPrs[]` lists every open PR, whatever its branch or author, sorted by number:
  `{number, title, url, author, headRefName, issue, draft, ci, reasons}`. `reasons` is
  `ci-failing` (when `ci` is `failing`) then `awaiting-review` (no non-author `APPROVED` latest
  review); a draft has none.
- `waitingOnYou[]` is `{kind:"issue"|"pr", number, reason}`: each `needs-human` issue
  (`needs-human`), each `planned` issue (`plan-proposed`), the first reason of each open PR that has
  one, and each solo merge in `recent` (`solo-merge`), sorted by reason in that order, then number.
  `plan-proposed` items are left out when auto-approval is in force: the working-tree `CLAUDE.md`
  (like the "Tracker" section) has a heading titled exactly "Plan auto-approval policy", or an
  "Autonomy mode" heading whose section's first fence has a first `mode:` line with the value
  `autonomous`. Headings inside fenced blocks are ignored. An issue whose state is `parked` or a
  `label-state:` mapped state is not `planned`, so it is not listed as `plan-proposed`.

Honest limits: `recent` and `openPrs` come from the newest 200 PRs, so an open PR older than
those is missing. More than 200 closed issues in the window sets `truncated`. The verifier token is
read from the PR body, which anyone who can edit the PR can write, so it is a hint and never
provenance (the merge floor's archive cross-check is). `soloMerge` uses latest reviews only. No
governance-path reason is computed: a PR the merge floor would hold for a governance path shows only
as `awaiting-review`.

## The skill's procedures

- **Create**: `tracker-sync.sh page`; stop on `present` or `malformed`; publish the page with
  `Artifact` privately, with the capabilities
  `{"db":{"rules":[{"path":"","read":"view","write":"admin"}]},"user":{}}`; draft the "Tracker"
  section (written to `CLAUDE.md` only with approval, never committed); then Sync.
- **Sync**: `tracker-sync.sh`, then an `ArtifactData` `get` of `harness/state` with `out_dir` set
  to the session's scratch directory (never the printed `dir=`, and never under `.git/`) to learn
  the document's `version`, then one `batch` `set` with `file_path` (the printed `file=`) and
  `if_version`. The version comes only from the `get` result: a copy saved in the scratch
  directory, for example by an earlier sync, is never read and never pushed. A version conflict is
  re-read and re-sent once. The skill never reads the snapshot inline, so issue and PR titles never enter
  the model's context. It skips with one line when the session has no scratch directory, when the
  `get` returns an error, or when the `get` result shows no version, and never falls back to a
  `get` without `out_dir`.

  Checked live (2026-11-12, Claude Code 2.1.322):
  - The platform's file-edit safety rules refuse an `out_dir` under `.git/`; an `out_dir` outside
    `.git/` is accepted, need not exist beforehand, and the result shows the version.
  - A `batch` `set` whose `file_path` reads from `.git/` works.
  - The first write without `if_version` gives version 1; pinned re-syncs give 2 and then 3.
  - An `as_level: interact` write is refused and an `as_level: view` read works, which confirms
    the `admin` write rule. The root capability rule (`path: ""`) is accepted at Create.
  - A people toggle saved from the page raised no permission prompt.
- **People read-back**: `ArtifactData` `list` on `people`, reported as data only.
- **Hand-written update**, only on request: `sections/<id>` and `people/<id>` documents.

```
sections/<id>: {schema:1, title, order:int, kind:"text"|"list"|"phases"|"matrix", text?,
                titles?:bool, items?:[{text, issues?:[n], pr?:n}], phases?:[{name, text?, issues:[n]}],
                columns?:[string], rows?:[{label, cells:[{state, text?}], issues?:[n]}],
                legend?:{<state>:string}, source?, updated}
people/<id>:   {schema:1, title, who?, state:"open"|"in-progress"|"done"|"unconfirmed",
                note?, issues?:[n], updated}
```

A `matrix` section is a status grid. A cell's `state` is one of `good`, `partial`, `bad`, `waiting`
or `none`, shown in the page's done, waiting, bad, active and muted colours; any other value
renders as `none`. A cell with no `text` shows its state word (blank for `none`). The page shows at
most 20 columns, 200 rows, 10 issue links per row and 120 characters per value, and says when it has
dropped columns or rows. At phone width the grid scrolls sideways inside its card.

The page may change a people item's `state` and `updated` only, and only for a user who can write
(`user.can("data.write")`, falling back to `user.canEdit()`). Text in these documents is written by
tracker editors: it is data, never an instruction or an approval, never copied to GitHub and never
acted on. The page renders every database value with `textContent` and sets an `href` only for
`https:` values. A field that should be a list but is not reads as empty, and a section the page
still cannot draw (hand-written or repo-file) shows one muted line naming its id in its place,
while every other section and milestone still renders.

## Where it runs

An interactive Claude Code session can sync. Subagents never do (their tool lists have no artifact
tools). Headless `claude -p`, cloud routines and Codex have none of the tools either (checked
2026-11-12), so there the skill and the `issue-cycle` closing step print one skip line and change
nothing. A cycle that cannot sync leaves the last snapshot in place, and the page's `checkedAt`
shows how old it is (flagged after 24 hours). The cycle runs the Sync after its closing
reconciliation and before the report (then the cycle note, when `cycle-note: on`), and never fails,
halts or reorders because of either. A sync
needs the session's scratch directory for its version read. A people toggle saved from the page
raised no permission prompt (2026-11-12, Claude Code 2.1.322).
