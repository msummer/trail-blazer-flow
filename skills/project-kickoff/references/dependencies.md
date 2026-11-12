# Recording backlog dependencies

GitHub, and the tracker, read only **native issue dependencies** (the `blockedBy` field). The
prose "depends on" notes in the issue bodies stay as context for planners and are never parsed.
So once the backlog is filed, record each dependency as a native link, as below.

## Order: create first, link after

1. Create the whole backlog in dependency order (walking skeleton first) with plain
   `gh issue create`, exactly as step 5 says. Note each new issue's number from the URL `gh`
   prints; never assume numbers (an existing empty repo may not number the skeleton #1).
2. **Never** pass `--blocked-by` or `--blocking` at create time. An older `gh` without the flag
   would reject the whole create and the issue would be lost. Linking afterwards keeps creation
   independent of `gh`'s version: the worst case is a missing link, never a missing issue.

## Link pass

After the last create, for each issue that waits on others, run one call on its own:

```bash
gh issue edit <n> --add-blocked-by <m>[,<m>...]
```

One call per dependent issue, comma-separated blockers, no `&&` or `;` chaining and no
substitution. Link only the dependencies shown in the backlog the user approved in step 3, and
only between issues this kickoff filed (or found already filed on resume).

## Resume

If step 0 found the backlog already filed, first read each dependent's existing links with
`gh issue view <n> --json blockedBy` and add only blockers not already listed in
`.blockedBy.nodes[].number`, so no duplicate link is sent.

## Failure is soft

The first non-zero exit from any call in this pass (`gh issue edit` or the resume `gh issue view`) stops the pass. That includes an older `gh` rejecting
the flag, a permission error and an API error. Do not retry, and do not substitute `gh api` or
any other mechanism. The prose in the bodies stays. Print exactly one line to the user naming the
links not recorded, with the `gh issue edit <n> --add-blocked-by <m>` command for each, to run
after upgrading `gh` or to do in the GitHub UI. Then carry on to the doctor: a missing link never
aborts the kickoff.

## Codex

Each `gh issue edit` and `gh issue view` is its own command, per `docs/reference/codex.md`
"One simple command per call".
