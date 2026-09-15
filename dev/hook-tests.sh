#!/usr/bin/env bash
#
# hook-tests.sh — fixture-based negative-test harness for the three plugin-shipped PreToolUse
# hooks, in the style of dev/doctor-tests.sh: feeds fixture stdin JSON straight into the real
# script and pins its verdict.
#
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
# no longer inherits the session's `.git/config` routes, and a bare push in a sibling worktree no
# longer denies merely because the SESSION sits on its own default branch), the predicate's
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
# resolved `-C` target left behind.
#
# Usage: bash dev/hook-tests.sh [name-filter] — same output contract as dev/selfcheck-tests.sh
# and dev/doctor-tests.sh: one PASS/FAIL line per case, a `== summary: N pass, M fail ==`
# footer, exit 0 iff nothing failed; a filter with no match exits 1.
#
# Every write happens under one `mktemp -d` root, removed via an EXIT trap; this repo's own
# hooks/git-c-guard.sh, hooks/agent-boundary.sh, and hooks/push-guard.sh are read-only here —
# each script is run directly, never copied or edited (push-guard.sh's own fixture-repo builder
# below writes ONLY under that same mktemp root, never inside this checkout).
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"
guard="$root/hooks/git-c-guard.sh"
boundary="$root/hooks/agent-boundary.sh"
push_guard="$root/hooks/push-guard.sh"

tmpbase="$(mktemp -d)"
cleanup() {
  if [ -n "$tmpbase" ] && [ -d "$tmpbase" ]; then
    rm -rf "$tmpbase"
  fi
}
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1; then
  echo "  FAIL  jq not installed — required to build fixture stdin JSON and to parse the guard's output"
  exit 1
fi

bash_bin="$(command -v bash)"

pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------------------------
# Fixture builders. jq -n --arg builds the JSON so a command string containing quotes, '#', or
# '(' '/' ')' is never hand-escaped.

mk_cmd() { jq -n --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'; }
mk_cmd_mode() { jq -n --arg cmd "$1" --arg mode "$2" '{tool_name: "Bash", tool_input: {command: $cmd}, permission_mode: $mode}'; }
mk_tool() { jq -n --arg tool "$1" --arg cmd "$2" '{tool_name: $tool, tool_input: {command: $cmd}}'; }

# run_hook JSON [PATHVAL] — runs the real guard script against JSON on stdin, with PATH set to
# PATHVAL (defaults to this process's own PATH), leaving $hook_out (stdout only)/$hook_rc set as
# globals. Deliberately NOT invoked via command substitution itself (same idiom as
# dev/doctor-tests.sh's run_doctor and dev/selfcheck-tests.sh's run_gate) — call as a plain
# statement and read the globals after.
hook_out=""
hook_rc=0
run_hook() {
  local json="$1" pathval="${2:-$PATH}"
  hook_out="$(printf '%s' "$json" | PATH="$pathval" "$bash_bin" "$guard" 2>/dev/null)"
  hook_rc=$?
}

# expect_allow/expect_silent/expect_rc — assert against $hook_out/$hook_rc, setting $__ok=0 and
# appending to $__why on failure.
__ok=1
__why=""
expect_allow() {
  if ! printf '%s' "$hook_out" | jq -e . >/dev/null 2>&1; then
    __ok=0; __why="${__why}stdout is not valid JSON: '$hook_out'\n"; return
  fi
  local pd
  pd="$(printf '%s' "$hook_out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
  [ "$pd" = "allow" ] || { __ok=0; __why="${__why}permissionDecision is '$pd', expected 'allow'\n"; }
}
expect_silent() {
  [ -z "$hook_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$hook_out'\n"; }
}
expect_rc() {
  [ "$hook_rc" -eq "$1" ] || { __ok=0; __why="${__why}rc: expected $1, got $hook_rc\n"; }
}

# ---------------------------------------------------------------------------------------------
# hooks/agent-boundary.sh (#235) fixture builders and assertions. Documented vs. assumed stdin
# field names (LESSON 2026-09-01c): tool_name, tool_input.command, agent_id, agent_type, and
# permission_mode are all documented PreToolUse hook input fields; this harness never invents an
# undocumented field. agent_type, agent_id, tool_name: "Bash", and permission_mode: "auto" were
# also observed together in a live capture on 2026-09-08 (Claude Code 2.1.263, #259), with the
# observed agent_type being the namespaced form, which the fixtures below exercise alongside the
# bare form.

mk_agent_cmd() { jq -n --arg agent "$1" --arg cmd "$2" '{tool_name: "Bash", agent_type: $agent, tool_input: {command: $cmd}}'; }
mk_agent_cmd_mode() { jq -n --arg agent "$1" --arg cmd "$2" --arg mode "$3" '{tool_name: "Bash", agent_type: $agent, tool_input: {command: $cmd}, permission_mode: $mode}'; }
mk_agent_tool() { jq -n --arg agent "$1" --arg tool "$2" --arg cmd "$3" '{tool_name: $tool, agent_type: $agent, tool_input: {command: $cmd}}'; }
mk_agent_id_only() { jq -n --arg id "$1" --arg cmd "$2" '{tool_name: "Bash", agent_id: $id, tool_input: {command: $cmd}}'; }

# run_boundary JSON [PATHVAL] — runs the real boundary script against JSON on stdin, with PATH
# set to PATHVAL (defaults to this process's own PATH), leaving $boundary_out (stdout)/
# $boundary_err (stderr, read back from a file under $tmpbase)/$boundary_rc set as globals. Same
# "call as a plain statement, read the globals after" idiom as run_hook above — the existing
# run_hook discards stderr entirely (2>/dev/null), which cannot pin a "reason on stderr"
# criterion (LESSON 2026-09-08b), hence this separate runner with its own stderr capture file.
boundary_out=""
boundary_err=""
boundary_rc=0
run_boundary() {
  local json="$1" pathval="${2:-$PATH}" errfile="$tmpbase/boundary-stderr"
  boundary_out="$(printf '%s' "$json" | PATH="$pathval" "$bash_bin" "$boundary" 2>"$errfile")"
  boundary_rc=$?
  boundary_err="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
}

# expect_deny/expect_no_opinion — assert against $boundary_out/$boundary_err/$boundary_rc.
# DENY_STEM's literal text is hand-typed here (not extracted from the script), matching this
# repo's convention of pinning a script's own defined literal against an independent surface
# (e.g. dev/doctor-tests.sh hand-types bin/check-harness.sh's WARN stems, per 4.38's comment).
expect_deny() {
  [ "$boundary_rc" -eq 2 ] || { __ok=0; __why="${__why}rc: expected 2, got $boundary_rc\n"; }
  [ -z "$boundary_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$boundary_out'\n"; }
  local err_lines
  err_lines="$(printf '%s\n' "$boundary_err" | grep -c '[^[:space:]]')"
  [ "$err_lines" -eq 1 ] || { __ok=0; __why="${__why}expected exactly 1 non-blank stderr line, got $err_lines: '$boundary_err'\n"; }
  case "$boundary_err" in
    *"trail-blazer-flow agent boundary:"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain the DENY_STEM literal 'trail-blazer-flow agent boundary:': '$boundary_err'\n" ;;
  esac
}
expect_no_opinion() {
  [ "$boundary_rc" -eq 0 ] || { __ok=0; __why="${__why}rc: expected 0, got $boundary_rc\n"; }
  [ -z "$boundary_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$boundary_out'\n"; }
  [ -z "$boundary_err" ] || { __ok=0; __why="${__why}expected empty stderr, got: '$boundary_err'\n"; }
}

# ---------------------------------------------------------------------------------------------
# Allow cases — every one of the ten `-C` forms worktree-parallel mode issues, plus quoting,
# path-shape, and composite variants.

case_status_rel()          { run_hook "$(mk_cmd 'git -C ../demo-wt-3 status --porcelain')"; expect_rc 0; expect_allow; }
case_status_abs()          { run_hook "$(mk_cmd 'git -C /Users/x/proj/demo-wt-3 status --porcelain')"; expect_rc 0; expect_allow; }
case_status_quoted()       { run_hook "$(mk_cmd 'git -C "../demo-wt-3" status --porcelain')"; expect_rc 0; expect_allow; }
case_path_windows()        { run_hook "$(mk_cmd 'git -C C:/Users/x/proj/demo-wt-12 diff main...HEAD --stat')"; expect_rc 0; expect_allow; }
case_path_trailing_slash() { run_hook "$(mk_cmd 'git -C ../demo-wt-3/ rev-parse HEAD')"; expect_rc 0; expect_allow; }
case_checkpoint_composite() {
  # probe row (d): the double-quoted '#', '(', ')', ':' in the WIP commit message must survive
  # the lexer (worktree-mode.md:35-37, 156-157).
  run_hook "$(mk_cmd 'git -C ../demo-wt-1 add -A && git -C ../demo-wt-1 commit -m "wip: checkpoint verifier (#12)"')"
  expect_rc 0
  expect_allow
}
case_reset_soft()   { run_hook "$(mk_cmd 'git -C ../demo-wt-1 reset --soft 0123abc')"; expect_rc 0; expect_allow; }
case_merge_base()   { run_hook "$(mk_cmd 'git -C ../demo-wt-1 merge-base main HEAD')"; expect_rc 0; expect_allow; }
case_restore()      { run_hook "$(mk_cmd 'git -C ../demo-wt-1 restore file.txt')"; expect_rc 0; expect_allow; }
case_push_upstream() { run_hook "$(mk_cmd 'git -C ../demo-wt-1 push -u origin "claude/17-a"')"; expect_rc 0; expect_allow; }
case_diff_name_only() { run_hook "$(mk_cmd 'git -C ../demo-wt-1 diff --name-only')"; expect_rc 0; expect_allow; }
case_log() { run_hook "$(mk_cmd 'git -C ../demo-wt-1 log main..HEAD --format=%s')"; expect_rc 0; expect_allow; }

# never-executes-git — a conforming command run with a booby-trapped git (and rm) earlier on
# PATH that touches a sentinel file: expect allow AND no sentinel. This is the guard's central
# safety property (never touch the filesystem via the untrusted -C path), pinned mechanically
# rather than by a text grep of the script.
case_never_executes_git() {
  local trapdir="$tmpbase/trapbin" sentinel="$tmpbase/sentinel-touched"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  {
    printf '#!%s\n' "$bash_bin"
    printf 'touch "%s"\n' "$sentinel"
    printf 'exit 1\n'
  } > "$trapdir/git"
  chmod +x "$trapdir/git"
  {
    printf '#!%s\n' "$bash_bin"
    printf 'touch "%s"\n' "$sentinel"
    printf 'exit 1\n'
  } > "$trapdir/rm"
  chmod +x "$trapdir/rm"
  run_hook "$(mk_cmd 'git -C ../demo-wt-1 status --porcelain')" "$trapdir:$PATH"
  expect_rc 0
  expect_allow
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — the guard invoked something on the booby-trapped PATH\n"; }
}

# ---------------------------------------------------------------------------------------------
# No-opinion cases — expect empty stdout, rc 0.

case_inject_config()      { run_hook "$(mk_cmd 'git -C ../demo-wt-1 -c core.pager=cat status')"; expect_rc 0; expect_silent; }
case_inject_execpath()    { run_hook "$(mk_cmd 'git -C ../demo-wt-1 --exec-path=/tmp/evil status')"; expect_rc 0; expect_silent; }
case_attached_c()         { run_hook "$(mk_cmd 'git -C../demo-wt-1 status')"; expect_rc 0; expect_silent; }
case_double_c()           { run_hook "$(mk_cmd 'git -C ../demo-wt-1 -C /etc status')"; expect_rc 0; expect_silent; }
case_token1_not_c() {
  # Isolates the "token 1 must be exactly -C" comparison (git-c-guard.sh's validate_segment)
  # from every other check: this first segment has 4+ tokens, a conforming worktree path at
  # position 2, and a conforming subcommand at position 3 — only the exact "-C" match rejects
  # it. attached-C/double-C above don't reach that comparison at all (they're rejected earlier,
  # by the token-count floor and by sub_allowed respectively), so a deleted exact-match check
  # would leave --exec-path= (arbitrary git helper-lookup injection) silently approved whenever
  # it rides along with a second, genuinely conforming `git -C` segment. That second segment is
  # required here for another reason too: only a literal 'git -C' substring anywhere in $cmd
  # clears the script's raw-stdin fast path before jq is ever invoked (hooks/git-c-guard.sh:26-29).
  run_hook "$(mk_cmd 'git --exec-path=/tmp/evil ../demo-wt-1 status && git -C ../demo-wt-1 status')"
  expect_rc 0
  expect_silent
}
case_attached_c_4tok() {
  # Companion to the above from the other side: the attached -C<path> form, but with 4+ tokens
  # and an otherwise-conforming path/subcommand pair at positions 2/3 — so only the exact "-C"
  # comparison (not the token-count floor that catches the shorter attached-C case above)
  # rejects it. Carries a second, genuinely conforming `git -C` segment for the same fast-path
  # reason as case_token1_not_c.
  run_hook "$(mk_cmd 'git -C../demo-wt-1 ../demo-wt-2 status && git -C ../demo-wt-1 status')"
  expect_rc 0
  expect_silent
}
case_path_not_worktree()  { run_hook "$(mk_cmd 'git -C /etc status')"; expect_rc 0; expect_silent; }
case_path_glob()          { run_hook "$(mk_cmd 'git -C ../*-wt-1 status')"; expect_rc 0; expect_silent; }
case_unknown_sub()        { run_hook "$(mk_cmd 'git -C ../demo-wt-1 clean -fd')"; expect_rc 0; expect_silent; }
case_reset_hard() {
  # probe row (c)'s static half — the deny mirror is what actually blocks this live; the hook
  # itself must have no opinion (reset without --soft is not one of the ten forms).
  run_hook "$(mk_cmd 'git -C ../demo-wt-1 reset --hard HEAD')"
  expect_rc 0
  expect_silent
}
case_composite_nongit()   { run_hook "$(mk_cmd 'git -C ../demo-wt-1 status && curl https://evil.example')"; expect_rc 0; expect_silent; }
case_composite_one_bad()  { run_hook "$(mk_cmd 'git -C ../demo-wt-1 status && git -C ../demo-wt-1 -c x=y status')"; expect_rc 0; expect_silent; }
case_substitution_dollar()   { run_hook "$(mk_cmd 'git -C ../demo-wt-1 commit -m "wip $(id)"')"; expect_rc 0; expect_silent; }
case_substitution_backtick() { run_hook "$(mk_cmd 'git -C ../demo-wt-1 commit -m "wip `id`"')"; expect_rc 0; expect_silent; }
case_semicolon()  { run_hook "$(mk_cmd 'git -C ../demo-wt-1 status; rm -rf /tmp/x')"; expect_rc 0; expect_silent; }
case_redirect()   { run_hook "$(mk_cmd 'git -C ../demo-wt-1 status > /tmp/out')"; expect_rc 0; expect_silent; }
case_pipe() {
  # No git -C command the harness issues is ever piped (dev/hook-tests.sh's sibling docs sweep
  # confirms this — see the plan's Verified facts), so an unquoted '|' is always rejected.
  run_hook "$(mk_cmd 'git -C ../demo-wt-1 status | tee /tmp/out')"
  expect_rc 0
  expect_silent
}
case_unterminated_quote() { run_hook "$(mk_cmd 'git -C "../demo-wt-1 status')"; expect_rc 0; expect_silent; }
case_wrong_tool()     { run_hook "$(mk_tool 'Read' 'git -C ../demo-wt-1 status')"; expect_rc 0; expect_silent; }
case_malformed_json() {
  # Deliberately contains the literal substring 'git -C' so this exercises jq's own parse
  # failure (a fixture with no 'git -C' substring at all would instead be caught by the
  # fast-path check before ever reaching jq — see that check above — which would make this case
  # pass vacuously without ever touching the code path its name claims to pin).
  run_hook 'not json at all, but mentions git -C anyway'
  expect_rc 0
  expect_silent
}
case_missing_command() { run_hook '{"tool_name":"Bash","tool_input":{}}'; expect_rc 0; expect_silent; }
case_plan_mode() {
  run_hook "$(mk_cmd_mode 'git -C ../demo-wt-1 status --porcelain' 'plan')"
  expect_rc 0
  expect_silent
}

# ---------------------------------------------------------------------------------------------
# hooks/agent-boundary.sh (#235) cases. Grouped by verdict/role, counts as shipped (not the
# approved plan's original enumeration, which this comment previously — and wrongly — cited
# verbatim; see LESSON 2026-09-06): implementer deny (16), implementer no opinion (5), verifier
# no opinion (7), verifier deny (14), role-agnostic no opinion (8), never-executes (2) = 52
# total (#270 added one CRLF case to each of implementer-deny, verifier-no-opinion, and
# verifier-deny). Both agent_type spellings ("implementer"/"trail-blazer-flow:implementer",
# "verifier"/"trail-blazer-flow:verifier") are exercised across each role's case set (LESSON
# 2026-09-08).

# --- implementer, deny ------------------------------------------------------------------------
case_ib_push_bare()   { run_boundary "$(mk_agent_cmd 'implementer' 'git push')"; expect_deny; }
case_ib_push_ns()     { run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' 'git push')"; expect_deny; }
case_ib_gh_pr_bare()  { run_boundary "$(mk_agent_cmd 'implementer' 'gh pr create')"; expect_deny; }
case_ib_gh_pr_ns()    { run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' 'gh pr create')"; expect_deny; }
case_ib_gh_issue_edit() { run_boundary "$(mk_agent_cmd 'implementer' 'gh issue edit 1 --add-label plan-approved')"; expect_deny; }
case_ib_git_c_push() {
  # The exact git -C <worktree> push form hooks/git-c-guard.sh's own allow cases approve
  # (dev/hook-tests.sh's case_push_upstream above) — this hook must deny it. Composition with
  # that other hook was separately measured live on 2026-09-08 (deny beat allow — see
  # hooks/agent-boundary.sh's header); this fixture pins THIS hook's own verdict independently.
  run_boundary "$(mk_agent_cmd 'implementer' 'git -C ../demo-wt-1 push -u origin claude/1-x')"
  expect_deny
}
case_ib_composite_and() { run_boundary "$(mk_agent_cmd 'implementer' 'pytest && git push')"; expect_deny; }
case_ib_assignment()    { run_boundary "$(mk_agent_cmd 'implementer' 'FOO=1 git push')"; expect_deny; }
case_ib_command_prefix() { run_boundary "$(mk_agent_cmd 'implementer' 'command git push')"; expect_deny; }
case_ib_abs_path()      { run_boundary "$(mk_agent_cmd 'implementer' '/usr/bin/git push')"; expect_deny; }
case_ib_bash_c()        { run_boundary "$(mk_agent_cmd 'implementer' 'bash -c "git push"')"; expect_deny; }
case_ib_semicolon()     { run_boundary "$(mk_agent_cmd 'implementer' 'echo hi; gh pr create')"; expect_deny; }
case_ib_subshell()      { run_boundary "$(mk_agent_cmd 'implementer' '(cd x && git push)')"; expect_deny; }
case_ib_readonly_subcommand() {
  # Isolates the implementer/verifier role-policy split itself: "git status" is on
  # VERIFIER_GIT_READONLY (see case_vn_status's no-opinion verdict for the identical command
  # under agent_type: verifier), but the implementer denies ANY git subcommand, read-only or
  # not — a mutant that swapped the implementer onto the verifier's read-only membership test
  # would flip only this case (every other impl-deny-* fixture above uses a non-readonly
  # subcommand, so it would keep denying under either policy and this mutant would slip past
  # unnoticed).
  run_boundary "$(mk_agent_cmd 'implementer' 'git status --porcelain')"
  expect_deny
}
case_ib_chained_prefix() {
  # Regression fixture for the round-1 kickback finding: TWO chained PREFIX_WORDS tokens
  # ("sudo" then "bash") in front of the command word. hooks/agent-boundary.sh:167 originally
  # read `if (!saw_prefix && (norm in prefix_set))`, which stops skipping after the FIRST
  # recognised prefix word, so the second one ("bash") became the wrongly-resolved command word
  # and this command denied nothing. impl-deny-command-prefix and impl-deny-bash-c above each
  # carry only ONE prefix word, so neither isolates this clause.
  run_boundary "$(mk_agent_cmd 'implementer' 'sudo bash -c "git push"')"
  expect_deny
}
case_ib_crlf_cmdword() {
  # #270: CR on the command word -- the only place a CR actually evades this hook (a CR elsewhere,
  # e.g. `git push<CR>`, still resolves cmdword to a clean "git" and already denies). Raw stdin
  # carries "agent_type" (via mk_agent_cmd) and "git" before the escaped \r, satisfying both
  # fast paths.
  run_boundary "$(mk_agent_cmd 'implementer' "git${CR} push")"
  expect_deny
}

# --- implementer, no opinion -------------------------------------------------------------------
case_in_npm_test()  { run_boundary "$(mk_agent_cmd 'implementer' 'npm test')"; expect_no_opinion; }
case_in_pytest()    { run_boundary "$(mk_agent_cmd 'implementer' 'pytest -q')"; expect_no_opinion; }
case_in_selfcheck() { run_boundary "$(mk_agent_cmd 'implementer' 'bash dev/selfcheck.sh')"; expect_no_opinion; }
case_in_grep_arg() {
  # Control proving the command-position rule: 'git' appears only as grep's own argument, never
  # as a command word.
  run_boundary "$(mk_agent_cmd 'implementer' 'grep -rn "git push" .')"
  expect_no_opinion
}
case_in_git_c_guard_script() {
  # Control proving exact-match, not substring-match: the command word's basename is
  # "git-c-guard.sh", which CONTAINS "git" but does not EQUAL it.
  run_boundary "$(mk_agent_cmd 'implementer' 'bash hooks/git-c-guard.sh')"
  expect_no_opinion
}

# --- verifier, no opinion -----------------------------------------------------------------------
case_vn_diff()      { run_boundary "$(mk_agent_cmd 'verifier' 'git diff main...HEAD --stat')"; expect_no_opinion; }
case_vn_log()       { run_boundary "$(mk_agent_cmd 'verifier' 'git log main..HEAD --format=%s')"; expect_no_opinion; }
case_vn_status()    { run_boundary "$(mk_agent_cmd 'verifier' 'git status --porcelain')"; expect_no_opinion; }
case_vn_restore()   { run_boundary "$(mk_agent_cmd 'verifier' 'git restore api/x.py')"; expect_no_opinion; }
case_vn_c_log()     { run_boundary "$(mk_agent_cmd 'verifier' 'git -C ../demo-wt-1 log main..HEAD --format=%s')"; expect_no_opinion; }
case_vn_show_ns()   { run_boundary "$(mk_agent_cmd 'trail-blazer-flow:verifier' 'git show HEAD')"; expect_no_opinion; }
case_vn_crlf_status() {
  # #270: verifier, git status<CR> -- pins the subcommand-resolution side of the strip. Before the
  # fix this DENIES (fail-closed: "status<CR>" is not an exact VERIFIER_GIT_READONLY member,
  # unlike case_vn_status's clean "status --porcelain"); after the fix it is no opinion. The only
  # new case whose pre-fix failure is a deny rather than a no-opinion, which is why it is worth
  # having: it proves the fix is not a blanket widening of denials. Raw stdin carries "agent_type"
  # and "git" before the escaped \r.
  run_boundary "$(mk_agent_cmd 'verifier' "git status${CR}")"
  expect_no_opinion
}

# --- verifier, deny ------------------------------------------------------------------------------
case_vd_commit()      { run_boundary "$(mk_agent_cmd 'verifier' 'git commit -m x')"; expect_deny; }
case_vd_stash()       { run_boundary "$(mk_agent_cmd 'verifier' 'git stash')"; expect_deny; }
case_vd_checkout()    { run_boundary "$(mk_agent_cmd 'verifier' 'git checkout -- api/x.py')"; expect_deny; }
case_vd_gh_comment_bare() { run_boundary "$(mk_agent_cmd 'verifier' 'gh issue comment 1 -b x')"; expect_deny; }
case_vd_gh_comment_ns()   { run_boundary "$(mk_agent_cmd 'trail-blazer-flow:verifier' 'gh issue comment 1 -b x')"; expect_deny; }
case_vd_inject_config()   { run_boundary "$(mk_agent_cmd 'verifier' 'git -c core.pager=cat log')"; expect_deny; }
case_vd_no_pager_log() {
  # Isolates the "-globalopt-" sentinel from every other verifier-deny case above: --no-pager
  # takes no value, so a scan that merely SKIPPED an unrecognised dashed token (instead of
  # sentinel-and-stop) would land on "log" — itself a genuine VERIFIER_GIT_READONLY member — and
  # wrongly allow. Every other injected-option fixture here (-c core.pager=cat, --git-dir=...)
  # happens to have its very next token also be non-readonly, so a naive "skip past" mutant would
  # still deny them for the wrong reason; only this fixture's outcome flips.
  run_boundary "$(mk_agent_cmd 'verifier' 'git --no-pager log')"
  expect_deny
}
case_vd_git_dir()         { run_boundary "$(mk_agent_cmd 'verifier' 'git --git-dir=/tmp/x push')"; expect_deny; }
case_vd_c_commit()        { run_boundary "$(mk_agent_cmd 'verifier' 'git -C ../demo-wt-1 commit -m x')"; expect_deny; }
case_vd_clean()            { run_boundary "$(mk_agent_cmd 'verifier' 'git clean -fd')"; expect_deny; }
case_vd_bare_git()         { run_boundary "$(mk_agent_cmd 'verifier' 'git')"; expect_deny; }
case_vd_composite()        { run_boundary "$(mk_agent_cmd 'verifier' 'pytest && git commit -m x')"; expect_deny; }
case_vd_chained_prefix() {
  # Verifier-side sibling of impl-deny-chained-prefix — same regression, two chained
  # PREFIX_WORDS tokens ("env" then "sudo") in front of the command word.
  run_boundary "$(mk_agent_cmd 'verifier' 'env sudo git commit -m x')"
  expect_deny
}
case_vd_crlf_gh() {
  # #270: verifier, gh<CR> ... -- the gh branch, whose role policy compares the printed command
  # word exactly ("gh" vs. the scan's emitted cmdword). Raw stdin carries "agent_type" and "gh"
  # before the escaped \r.
  run_boundary "$(mk_agent_cmd 'verifier' "gh${CR} issue comment 1 -b x")"
  expect_deny
}

# --- role-agnostic, no opinion -------------------------------------------------------------------
mk_plain_cmd() { jq -n --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'; }
# mk_agent_missing_command AGENT — tool_input.command absent, but the raw JSON still contains
# both the literal 'agent_type' and a 'git' substring (in an unrelated field) so this case
# actually reaches the "cmd empty" check (step 7) instead of passing vacuously via fast path 2
# (LESSON 2026-08-26's analogue — see the plan's step 10).
mk_agent_missing_command() { jq -n --arg agent "$1" --arg note "was going to run git push" '{tool_name: "Bash", agent_type: $agent, tool_input: {}, note: $note}'; }

case_ra_no_agent_type_key() {
  # No 'agent_type' substring anywhere in the raw stdin at all — reaches only fast path 1 (the
  # main session issuing a Bash call never carries this key), never spawns jq.
  run_boundary "$(mk_plain_cmd 'git push')"
  expect_no_opinion
}
case_ra_explore()        { run_boundary "$(mk_agent_cmd 'Explore' 'git push')"; expect_no_opinion; }
case_ra_empty_agent_type() { run_boundary "$(mk_agent_cmd '' 'git push')"; expect_no_opinion; }
case_ra_agent_id_only() {
  # agent_id present (so this IS inside a subagent call) but no agent_type key at all — same
  # "no agent_type substring" fast-path-1 exit as the no-agent-type-key case above.
  run_boundary "$(mk_agent_id_only 'agent-123' 'git push')"
  expect_no_opinion
}
case_ra_plan_mode() { run_boundary "$(mk_agent_cmd_mode 'implementer' 'git push' 'plan')"; expect_no_opinion; }
case_ra_wrong_tool() {
  # Contains 'agent_type' AND 'git' (the real command word), so this reaches the .tool_name
  # check (step 4) rather than passing vacuously via either fast path.
  run_boundary "$(mk_agent_tool 'implementer' 'Read' 'git push')"
  expect_no_opinion
}
case_ra_malformed_json() {
  # Deliberately contains both literal substrings 'agent_type' and 'git' so this exercises jq's
  # own parse failure (step 3's jq spawn, then a failed .tool_name read) rather than passing
  # vacuously via either fast path.
  run_boundary 'not json at all, but mentions agent_type and git push anyway'
  expect_no_opinion
}
case_ra_missing_command() {
  run_boundary "$(mk_agent_missing_command 'implementer')"
  expect_no_opinion
}

# --- never-executes --------------------------------------------------------------------------
# Same booby-trapped-PATH idiom as case_never_executes_git above (git-c-guard.sh), applied to
# this hook on both the deny path and the no-opinion path: the boundary never invokes git, gh,
# or rm on the untrusted command string it is scanning — it only ever reads it as text.
case_boundary_never_executes_deny() {
  local trapdir="$tmpbase/trapbin-boundary-deny" sentinel="$tmpbase/sentinel-boundary-deny"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_boundary "$(mk_agent_cmd 'implementer' 'git push')" "$trapdir:$PATH"
  expect_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — the boundary invoked something on the booby-trapped PATH\n"; }
}
case_boundary_never_executes_noop() {
  local trapdir="$tmpbase/trapbin-boundary-noop" sentinel="$tmpbase/sentinel-boundary-noop"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_boundary "$(mk_agent_cmd 'verifier' 'git status --porcelain')" "$trapdir:$PATH"
  expect_no_opinion
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — the boundary invoked something on the booby-trapped PATH\n"; }
}

# ---------------------------------------------------------------------------------------------
# hooks/push-guard.sh (#260) fixture builders, runner, and assertions.

mk_push_cmd() { jq -n --arg cmd "$1" '{tool_name: "Bash", tool_input: {command: $cmd}}'; }
mk_push_cmd_cwd() { jq -n --arg cmd "$1" --arg cwd "$2" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}'; }
mk_push_cmd_mode() { jq -n --arg cmd "$1" --arg mode "$2" '{tool_name: "Bash", tool_input: {command: $cmd}, permission_mode: $mode}'; }
mk_push_tool() { jq -n --arg tool "$1" --arg cmd "$2" '{tool_name: $tool, tool_input: {command: $cmd}}'; }
# mk_push_missing_command — tool_input.command absent, but the raw JSON still contains both the
# literal 'push' and 'git' substrings (in an unrelated field) so this case actually reaches the
# "cmd empty" check instead of passing vacuously via either raw-stdin fast path (LESSON
# 2026-08-26's analogue, mirroring mk_agent_missing_command above).
mk_push_missing_command() { jq -n --arg note 'was going to run git push origin main' '{tool_name: "Bash", tool_input: {}, note: $note}'; }

CR=$'\r'   # one literal carriage return — the #270 CRLF fixtures below (jq --arg escapes it into
           # the JSON as \r, so no raw CR byte ever passes through command substitution). Shared
           # by both the push-guard and agent-boundary CRLF cases below.

# mk_fixture_repo DIR DEFAULT_BRANCH CURRENT — builds an ordinary (non-worktree) .git directory
# under DIR: refs/remotes/origin/HEAD names DEFAULT_BRANCH; HEAD names CURRENT, unless CURRENT is
# "detached" (a raw 40-hex SHA, no symref — an unresolvable current branch) or "unreadable" (no
# HEAD file at all). Writes only under DIR, which every caller places under $tmpbase.
mk_fixture_repo() {
  local dir="$1" default_branch="$2" current="$3"
  mkdir -p "$dir/.git/refs/remotes/origin"
  printf 'ref: refs/remotes/origin/%s\n' "$default_branch" > "$dir/.git/refs/remotes/origin/HEAD"
  case "$current" in
    detached) printf '0123456789abcdef0123456789abcdef01234567\n' > "$dir/.git/HEAD" ;;
    unreadable) : ;;
    *) printf 'ref: refs/heads/%s\n' "$current" > "$dir/.git/HEAD" ;;
  esac
}

# mk_fixture_worktree MAINDIR WTDIR DEFAULT_BRANCH WT_BRANCH — builds a main checkout under
# MAINDIR (refs/remotes/origin/HEAD only) and a worktree pointer file at WTDIR/.git
# (gitdir: MAINDIR/.git/worktrees/wt1) whose own HEAD names WT_BRANCH — the same worktree-pointer
# shape hooks/git-c-guard.sh's own `-C <worktree>` forms navigate into.
mk_fixture_worktree() {
  local main="$1" wt="$2" default_branch="$3" wt_branch="$4"
  mkdir -p "$main/.git/refs/remotes/origin" "$main/.git/worktrees/wt1"
  printf 'ref: refs/remotes/origin/%s\n' "$default_branch" > "$main/.git/refs/remotes/origin/HEAD"
  mkdir -p "$wt"
  printf 'gitdir: %s/.git/worktrees/wt1\n' "$main" > "$wt/.git"
  printf 'ref: refs/heads/%s\n' "$wt_branch" > "$main/.git/worktrees/wt1/HEAD"
}

# mk_fixture_config DIR BODY (#268) — writes BODY (already newline-terminated by the caller's own
# heredoc/printf, or not, per case) to DIR/.git/config. DIR is the directory that HOLDS .git — for
# a worktree fixture that is the MAIN dir (mk_fixture_worktree's first argument), never the
# pointer dir, mirroring where hooks/push-guard.sh itself reads (the common dir, not the resolved
# gitdir). AMBIENT-$PWD RULE: every push fixture below that builds a config has n <= 1 non-option
# tokens (a bare `git push` or `git push <remote>`), because config is consulted ONLY in that
# branch — so every one of them MUST pass an explicit cwd via mk_push_cmd_cwd, or push-guard.sh
# resolves the developer's own checkout and reads THAT machine's real .git/config (today, before
# this builder existed, no such flake was possible: every no-cwd push fixture in this file has
# n >= 2 — see this file's push mutation table header). Since #269, the SAME rule also binds any
# fixture whose command carries a predicate-matching (PATH_ERE-shaped) "-C" path: a relative one
# is joined to resolve_cwd (the session's own cwd, or $PWD with none passed), so a "-C ../<name>
# -wt-<n>" fixture with no explicit cwd resolves against the developer's own checkout's sibling
# directory, not a fixture the test built — every "-C"-carrying config fixture below passes an
# explicit cwd for this reason too.
mk_fixture_config() {
  local dir="$1" body="$2"
  mkdir -p "$dir/.git"
  printf '%s' "$body" > "$dir/.git/config"
}

# run_push_guard JSON [PATHVAL] — runs the real push-guard script against JSON on stdin, with
# PATH set to PATHVAL (defaults to this process's own PATH), leaving $push_out (stdout)/
# $push_err (stderr, read back from a file under $tmpbase)/$push_rc set as globals. Same "call as
# a plain statement, read the globals after" idiom as run_boundary above.
push_out=""
push_err=""
push_rc=0
run_push_guard() {
  local json="$1" pathval="${2:-$PATH}" errfile="$tmpbase/push-guard-stderr"
  push_out="$(printf '%s' "$json" | PATH="$pathval" "$bash_bin" "$push_guard" 2>"$errfile")"
  push_rc=$?
  push_err="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
}

# expect_push_deny/expect_push_no_opinion — assert against $push_out/$push_err/$push_rc.
# PUSH_DENY_STEM's literal text is hand-typed here (not extracted from the script), the same
# convention expect_deny above uses for agent-boundary.sh's DENY_STEM.
expect_push_deny() {
  [ "$push_rc" -eq 2 ] || { __ok=0; __why="${__why}rc: expected 2, got $push_rc\n"; }
  [ -z "$push_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$push_out'\n"; }
  local err_lines
  err_lines="$(printf '%s\n' "$push_err" | grep -c '[^[:space:]]')"
  [ "$err_lines" -eq 1 ] || { __ok=0; __why="${__why}expected exactly 1 non-blank stderr line, got $err_lines: '$push_err'\n"; }
  case "$push_err" in
    *"trail-blazer-flow push guard:"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain the PUSH_DENY_STEM literal 'trail-blazer-flow push guard:': '$push_err'\n" ;;
  esac
}
expect_push_no_opinion() {
  [ "$push_rc" -eq 0 ] || { __ok=0; __why="${__why}rc: expected 0, got $push_rc\n"; }
  [ -z "$push_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$push_out'\n"; }
  [ -z "$push_err" ] || { __ok=0; __why="${__why}expected empty stderr, got: '$push_err'\n"; }
}

# --- deny: plain command and refspec-parsing clauses, derived from the parser's boundaries
# (LESSON 2026-09-04), not from happy paths -------------------------------------------------------
case_pd_origin_main()       { run_push_guard "$(mk_push_cmd 'git push origin main')"; expect_push_deny; }
case_pd_head_colon_main()   { run_push_guard "$(mk_push_cmd 'git push origin HEAD:main')"; expect_push_deny; }
case_pd_plus_head_refs()    { run_push_guard "$(mk_push_cmd 'git push origin +HEAD:refs/heads/main')"; expect_push_deny; }
case_pd_nonorigin_remote()  { run_push_guard "$(mk_push_cmd 'git push upstream HEAD:main')"; expect_push_deny; }
case_pd_url_remote_colon()  { run_push_guard "$(mk_push_cmd 'git push git@github.com:o/r.git HEAD:main')"; expect_push_deny; }
case_pd_refspec_full()      { run_push_guard "$(mk_push_cmd 'git push origin refs/heads/x:refs/heads/main')"; expect_push_deny; }
case_pd_colon_main()        { run_push_guard "$(mk_push_cmd 'git push origin :main')"; expect_push_deny; }
case_pd_plus_main_no_colon() {
  # Isolates the leading-'+' strip from the colon-split: a colon-BEARING token like
  # "+HEAD:refs/heads/main" still resolves correctly even without stripping '+' first, because
  # the colon-split alone discards everything before and including the first ':'. Only a
  # colon-LESS forced refspec like "+main" needs the strip on its own.
  run_push_guard "$(mk_push_cmd 'git push origin +main')"
  expect_push_deny
}
case_pd_delete_main()       { run_push_guard "$(mk_push_cmd 'git push origin --delete main')"; expect_push_deny; }
case_pd_opt_before_remote() { run_push_guard "$(mk_push_cmd 'git push --force origin main')"; expect_push_deny; }
case_pd_opt_after_refspec() { run_push_guard "$(mk_push_cmd 'git push origin main --force')"; expect_push_deny; }
case_pd_o_one()              { run_push_guard "$(mk_push_cmd 'git push -o ci.skip origin main')"; expect_push_deny; }
case_pd_o_two()              { run_push_guard "$(mk_push_cmd 'git push -o a -o b origin main')"; expect_push_deny; }
case_pd_all()                { run_push_guard "$(mk_push_cmd 'git push --all origin')"; expect_push_deny; }
case_pd_mirror()             { run_push_guard "$(mk_push_cmd 'git push --mirror origin')"; expect_push_deny; }
case_pd_c_worktree()         { run_push_guard "$(mk_push_cmd 'git -C ../demo-wt-1 push origin main')"; expect_push_deny; }
case_pd_composite_and()      { run_push_guard "$(mk_push_cmd 'pytest && git push origin main')"; expect_push_deny; }
case_pd_prefix_one()         { run_push_guard "$(mk_push_cmd 'env git push origin main')"; expect_push_deny; }
case_pd_prefix_two() {
  # TWO chained PREFIX_WORDS tokens (sudo, then bash) — the M23-class regression
  # hooks/agent-boundary.sh's own fixtures pin for its twin tokenizer; push-guard.sh's scan must
  # not regress the same way (0/1/2+ occurrences of a skipped class — LESSON 2026-09-08d).
  run_push_guard "$(mk_push_cmd 'sudo bash -c "git push origin main"')"
  expect_push_deny
}
case_pd_assignment()         { run_push_guard "$(mk_push_cmd 'FOO=1 git push origin main')"; expect_push_deny; }
case_pd_abs_path()           { run_push_guard "$(mk_push_cmd '/usr/bin/git push origin main')"; expect_push_deny; }
case_pd_global_opt_value()   { run_push_guard "$(mk_push_cmd 'git -c core.pager=cat push origin main')"; expect_push_deny; }
case_pd_global_opt_two() {
  # TWO chained GIT_GLOBAL_OPTS_WITH_VALUE tokens (-c <value>, then -C <value>) before the
  # subcommand — the 0/1/2+ boundary LESSON 2026-09-08(d) asks for on this skipped class too.
  run_push_guard "$(mk_push_cmd 'git -c core.pager=cat -C ../demo-wt-1 push origin main')"
  expect_push_deny
}
case_pd_origin_master()      { run_push_guard "$(mk_push_cmd 'git push origin master')"; expect_push_deny; }
case_pd_n1_refspec() {
  # A single non-option argument after "push" is evaluated BOTH as the current branch AND,
  # defensively, as a refspec destination in its own right (a remote literally named "main" is
  # treated as if it might be a branch — see the hook's own header). Isolates that second
  # evaluation from the first with an explicit fixture repo whose CURRENT branch is feature/x (a
  # real, resolvable, non-deny-set value, not an ambient/unresolvable one) — only the
  # refspec-as-destination check on "main" itself can explain this deny.
  local dir="$tmpbase/repo-n1-refspec"
  mk_fixture_repo "$dir" main feature/x
  run_push_guard "$(mk_push_cmd_cwd 'git push main' "$dir")"
  expect_push_deny
}
case_pd_crlf_dest() {
  # #270: the exact command the issue measured. Isolates the destination compare, which goes
  # through strip_quotes() + is_deny_member (NOT normalize() — push destinations never pass
  # through it, see the hook's own header). Raw stdin carries both required fast-path substrings
  # ("push", "git") ahead of the escaped \r, so this reaches the tokenizer.
  run_push_guard "$(mk_push_cmd "git push origin main${CR}")"
  expect_push_deny
}
case_pd_crlf_interior() {
  # #270 round-2 kickback: three CRs, with the verdict-bearing one (the second) NEITHER the
  # command's first NOR its final byte — the original two-CR fixture's verdict-bearing CR was
  # its FIRST, so a once-only ("strip the first \r found") mutant happened to strip it too and
  # survived the whole suite undetected; this shape kills both a trailing-only strip (the first
  # two CRs, including the verdict-bearing one, are untouched) AND a once-only strip (the
  # verdict-bearing CR is the SECOND, not the one a once-only strip removes) — see M23/M24/M25
  # below. Raw stdin carries both fast-path substrings ("git", "push") intact after the first
  # escaped \r — the fast paths are whole-string substring tests, so position is irrelevant here
  # (unlike case_pd_crlf_cmdword, where the "g","i","t" run must survive ahead of the escape).
  run_push_guard "$(mk_push_cmd "echo a${CR} && git push origin main${CR} && echo b${CR}")"
  expect_push_deny
}
case_pd_crlf_cmdword() {
  # #270: isolates normalize() on the command word — the site the issue's filed shape ("strip in
  # both tokenizers' normalize()") names, and which alone is insufficient to fix the issue's own
  # measured case (see case_pd_crlf_dest). Raw stdin carries "push" (unescaped, later in the
  # string) and the three literal characters "g","i","t" before the escaped \r, satisfying both
  # fast paths.
  run_push_guard "$(mk_push_cmd "git${CR} push origin main")"
  expect_push_deny
}
case_pn_crlf_feature() {
  # #270: the strip must not widen the deny set — exact match is still required against a
  # non-default destination. Raw stdin carries both fast-path substrings.
  run_push_guard "$(mk_push_cmd "git push origin feature/x${CR}")"
  expect_push_no_opinion
}

# --- deny: default-branch symref resolution against fixture repos --------------------------------
case_pd_trunk_base() {
  local dir="$tmpbase/repo-trunk-base"
  mk_fixture_repo "$dir" trunk main
  run_push_guard "$(mk_push_cmd_cwd 'git push origin trunk' "$dir")"
  expect_push_deny
}
case_pd_trunk_subdir() {
  local dir="$tmpbase/repo-trunk-subdir"
  mk_fixture_repo "$dir" trunk main
  mkdir -p "$dir/sub"
  run_push_guard "$(mk_push_cmd_cwd 'git push origin trunk' "$dir/sub")"
  expect_push_deny
}
case_pd_trunk_worktree() {
  local main="$tmpbase/repo-trunk-wt-main" wt="$tmpbase/repo-trunk-wt-pointer"
  mk_fixture_worktree "$main" "$wt" trunk "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'git push origin trunk' "$wt")"
  expect_push_deny
}
case_pd_head_on_main() {
  local dir="$tmpbase/repo-head-main"
  mk_fixture_repo "$dir" main main
  run_push_guard "$(mk_push_cmd_cwd 'git push origin HEAD' "$dir")"
  expect_push_deny
}
case_pd_bare_on_main() {
  local dir="$tmpbase/repo-bare-main"
  mk_fixture_repo "$dir" main main
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_no_cwd_fallback() {
  # No 'cwd' key at all in stdin (mk_push_cmd emits none): must still deny via the unconditional
  # PUSH_DEFAULT_BRANCH_FALLBACK, regardless of what $PWD resolves to.
  run_push_guard "$(mk_push_cmd 'git push origin main')"
  expect_push_deny
}

# --- no opinion: the shapes this harness itself issues, and every other non-default destination --
case_pn_push_upstream_claude()   { run_push_guard "$(mk_push_cmd 'git push -u origin "claude/17-a"')"; expect_push_no_opinion; }
case_pn_c_push_upstream_claude() { run_push_guard "$(mk_push_cmd 'git -C ../demo-wt-1 push -u origin "claude/17-a"')"; expect_push_no_opinion; }
case_pn_release_branch()         { run_push_guard "$(mk_push_cmd 'git push origin release/v2.7.1')"; expect_push_no_opinion; }
case_pn_tag_shaped_version()     { run_push_guard "$(mk_push_cmd 'git push origin v2.7.0')"; expect_push_no_opinion; }
case_pn_feature_branch()         { run_push_guard "$(mk_push_cmd 'git push origin feature/x')"; expect_push_no_opinion; }
case_pn_main_ish() {
  # Exact-match, not prefix — mirroring the "mainline" concern bin/check-harness.sh:585 documents
  # for its own default-branch literal.
  run_push_guard "$(mk_push_cmd 'git push origin main-ish')"
  expect_push_no_opinion
}
case_pn_refs_tags() { run_push_guard "$(mk_push_cmd 'git push origin refs/tags/v1.0')"; expect_push_no_opinion; }
case_pn_head_on_claude() {
  local dir="$tmpbase/repo-head-claude"
  mk_fixture_repo "$dir" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'git push origin HEAD' "$dir")"
  expect_push_no_opinion
}
case_pn_bare_on_claude() {
  local dir="$tmpbase/repo-bare-claude"
  mk_fixture_repo "$dir" main "claude/17-a"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_bare_detached() {
  local dir="$tmpbase/repo-detached"
  mk_fixture_repo "$dir" main detached
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_trunk_no_repo() {
  local dir="$tmpbase/norepo"
  mkdir -p "$dir"
  run_push_guard "$(mk_push_cmd_cwd 'git push origin trunk' "$dir")"
  expect_push_no_opinion
}
case_pn_grep_arg() {
  # Control proving the command-position rule: 'git'/'push' appear only inside grep's own
  # argument, never as a command word/subcommand.
  run_push_guard "$(mk_push_cmd 'grep -rn "git push origin main" .')"
  expect_push_no_opinion
}
case_pn_bash_script() {
  # Control proving exact-match, not substring-match: the command word after the "bash" prefix
  # skip is "hooks/push-guard.sh" (basename "push-guard.sh"), which CONTAINS "push" but is not
  # "git". The trailing shell comment supplies a literal "git" token so the raw stdin JSON
  # contains BOTH "push" and "git" (LESSON — a fixture whose raw JSON is missing either literal
  # exits at one of the two raw-stdin fast paths above and never reaches the tokenizer, which
  # would make this case's own claim about normalize()'s basename step vacuous); the comment
  # text itself is never reached by emit_segment, since cmdword already resolves (to
  # "push-guard.sh") from the tokens before it.
  run_push_guard "$(mk_push_cmd 'bash hooks/push-guard.sh # not a git push')"
  expect_push_no_opinion
}
case_pn_o_value_two_token_remote() {
  # Isolates PUSH_OPTS_WITH_VALUE's pair semantics: "-o v" must be skipped as EXACTLY two tokens,
  # so "main" lands at position 0 of the remaining tokens — the remote, per step 8, which is
  # NEVER itself evaluated as a destination (it may be a URL containing a colon) — leaving only
  # "other" evaluated, which isn't a deny-set member. A skip that consumed only one token would
  # instead treat "v" as the remote and evaluate BOTH "main" and "other" as candidate refspecs,
  # wrongly denying on "main".
  run_push_guard "$(mk_push_cmd 'git push -o v main other')"
  expect_push_no_opinion
}

# --- #269: "-C <path>" resolution, only when the path satisfies the shared PATH_ERE predicate --
# Every fixture below passes an explicit cwd (mk_fixture_config's AMBIENT-$PWD rule, extended by
# #269, applies here too: a relative "-C" value would otherwise resolve against the developer's
# own $PWD). "…-wt-<n>" directory names are the predicate-matching shape; a bare "…-wt-<n>" with
# no cwd anywhere in this file (e.g. the pre-existing push-deny-c-worktree/push-noop-c-upstream-
# claude/push-deny-global-opt-two fixtures' "../demo-wt-1") never exists on disk beside this
# script's own checkout, so those three pre-existing fixtures degrade under #269 exactly as they
# did before it (see this file's header for the ambient-$PWD flake class this predicate widens).
case_pd_c_sibling_wt_bare_on_default() {
  # A1: session default develop, HEAD claude/17-a; sibling worktree ALSO on develop; a bare push
  # in the worktree. Isolates the n<=1 current-branch check (evaluate_segment's own check, not a
  # refspec) on the RESOLVED checkout's current branch. Measured pre-#269 (main's script, before
  # this issue): no opinion (rc 0) -- the "-C" value was never read at all, so the segment was
  # judged only against the SESSION's own current branch, claude/17-a, which is not a deny member.
  local main="$tmpbase/repo-c-a1" wt="$tmpbase/repo-c-a1-wt-1"
  mk_fixture_worktree "$main" "$wt" develop develop
  printf 'ref: refs/heads/claude/17-a\n' > "$main/.git/HEAD"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../repo-c-a1-wt-1 push' "$main")"
  expect_push_deny
}
case_pd_c_other_repo_explicit_develop() {
  # A2: the issue's own headline shape. Session default main/HEAD claude/17-a; a SEPARATE repo
  # (not a worktree of the session) whose own default is develop; an explicit refspec destination.
  # Measured pre-#269 (main's script): no opinion (rc 0) -- the "-C" value was never read, so
  # "develop" was judged only against the session's own deny set (fallback ∪ main), of which it
  # is not a member.
  local main="$tmpbase/repo-c-a2" other="$tmpbase/other-checkout-wt-1"
  mk_fixture_repo "$main" main "claude/17-a"
  mk_fixture_repo "$other" develop "feature/x"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../other-checkout-wt-1 push origin develop' "$main")"
  expect_push_deny
}
case_pd_c_sibling_wt_head_refspec() {
  # A3: as A1, but the refspec is "HEAD" rather than a bare push -- isolates refspec_dest()'s HEAD
  # substitution (n==1, evaluated as an explicit refspec) from A1's separate n<=1 current-branch
  # check. Measured pre-#269 (main's script): no opinion (rc 0) -- same reason as A1 (the "-C"
  # value was never read, so "HEAD" resolved against the SESSION's own current branch,
  # claude/17-a, not a deny member).
  local main="$tmpbase/repo-c-a3" wt="$tmpbase/repo-c-a3-wt-1"
  mk_fixture_worktree "$main" "$wt" develop develop
  printf 'ref: refs/heads/claude/17-a\n' > "$main/.git/HEAD"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../repo-c-a3-wt-1 push origin HEAD' "$main")"
  expect_push_deny
}
case_pd_c_other_repo_config_route() {
  # A4: target (absolute-path "-C" form, covering the "/*" join branch) has a config denying via
  # remote.origin.push=HEAD:main; the SESSION has no config at all -- isolates the resolved
  # checkout's own config being applied, not the session's (which has none to fall back on).
  # Measured pre-#269 (main's script): no opinion (rc 0) -- the "-C" value was never read, so the
  # target's config was never consulted at all. This is the one fixture in this suite using the
  # absolute-path join branch ("$target" is already `$tmpbase/target-wt-1`, an absolute path) --
  # if $TMPDIR itself ever contained a character outside PATH_ERE's class, is_c_target_path would
  # reject the whole absolute path and this case would FAIL LOUDLY (expect_push_deny would see rc
  # 0, not silently pass for the wrong reason), since no other route in this fixture can produce a
  # deny.
  local main="$tmpbase/repo-c-a4" target="$tmpbase/target-wt-1"
  mk_fixture_repo "$main" develop "claude/17-a"
  mk_fixture_repo "$target" main "feature/x"
  mk_fixture_config "$target" $'[remote "origin"]\n\tpush = HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd "git -C $target push" "$main")"
  expect_push_deny
}
case_pn_c_other_repo_ignores_session_config() {
  # A5 (documented narrowing): the SESSION's own config would deny (push=HEAD:main, HEAD
  # feature/x), but the resolved segment must ignore it -- the target has its OWN default (trunk)
  # and no config of its own. Measured pre-#269: deny (rc 2, via the session's remote.origin.push
  # route) -- this fixture's whole point is that #269 removes that inherited deny.
  local main="$tmpbase/repo-c-a5" target="$tmpbase/target-a5-wt-1"
  mk_fixture_repo "$main" main "feature/x"
  mk_fixture_config "$main" $'[remote "origin"]\n\tpush = HEAD:main\n'
  mk_fixture_repo "$target" trunk "feature/y"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../target-a5-wt-1 push' "$main")"
  expect_push_no_opinion
}
case_pn_c_nonsibling_path() {
  # B1: the predicate's path-shape boundary -- no "-wt-<n>" suffix at all. Measured pre-#269
  # (main's script): no opinion (rc 0) -- the "-C" value was never read either way, so this
  # command's verdict is unchanged by #269 (the fixture's value is purely as the predicate
  # boundary, not a Today-vs-After widening).
  local main="$tmpbase/repo-c-b1" other="$tmpbase/other-checkout"
  mk_fixture_repo "$main" main "claude/17-a"
  mk_fixture_repo "$other" develop "feature/x"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../other-checkout push origin develop' "$main")"
  expect_push_no_opinion
}
case_pn_c_attached_form() {
  # B2: the ATTACHED "-C<path>" form -- validate_segment's own t1=="-C" exact-match boundary,
  # mirrored here: this hook's tokenizer only records a value for the detached, two-token form.
  # Measured pre-#269 (main's script): no opinion (rc 0) -- same reason as B1, unchanged by #269.
  local main="$tmpbase/repo-c-b2" other="$tmpbase/other-checkout-b2-wt-1"
  mk_fixture_repo "$main" main "claude/17-a"
  mk_fixture_repo "$other" develop "feature/x"
  run_push_guard "$(mk_push_cmd_cwd 'git -C../other-checkout-b2-wt-1 push origin develop' "$main")"
  expect_push_no_opinion
}
case_pn_c_double_c() {
  # B3: TWO "-C" tokens in one segment -- the 0/1/2+ boundary (LESSON 2026-09-08d) on "-C"
  # occurrences specifically; the tokenizer's ccount guard means neither is resolved. Measured
  # pre-#269 (main's script): no opinion (rc 0) -- same reason as B1/B2, unchanged by #269.
  local main="$tmpbase/repo-c-b3" benign="$tmpbase/benign-wt-1" other="$tmpbase/other-checkout-b3-wt-1"
  mk_fixture_repo "$main" main "claude/17-a"
  mk_fixture_repo "$benign" main "feature/w"
  mk_fixture_repo "$other" develop "feature/x"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../benign-wt-1 -C ../other-checkout-b3-wt-1 push origin develop' "$main")"
  expect_push_no_opinion
}
case_pd_c_unresolvable_degrades() {
  # B4: the "-C" value matches PATH_ERE's shape but nothing exists there -- resolve_repo("…", 1)
  # never finds a gitdir, so the segment must DEGRADE to exactly the session's own facts, not
  # clear them (M52's own discriminator). A BARE push, with the session's own HEAD ON its own
  # default branch (develop) -- not an explicit refspec, which never reads current_branch at all
  # and so cannot tell "degrade" from "clear" apart: current_branch is exactly what a "clear"
  # (leaving it blank after the failed resolve_repo() call) would silently drop.
  local main="$tmpbase/repo-c-b4"
  mk_fixture_repo "$main" develop develop
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../missing-wt-9 push' "$main")"
  expect_push_deny
}
case_pn_c_sibling_wt_session_on_default() {
  # B5 (documented narrowing): worktree-parallel mode's REAL shape -- the session checkout itself
  # sits on its own default branch (main) while a sibling worktree sits on claude/17-a; a bare
  # push in that worktree. Measured pre-#269: deny (rc 2, via the SESSION's current branch, which
  # happens to equal its own default) -- this is the false-positive #269 is meant to remove.
  local main="$tmpbase/repo-c-b5" wt="$tmpbase/repo-c-b5-wt-1"
  mk_fixture_worktree "$main" "$wt" main "claude/17-a"
  printf 'ref: refs/heads/main\n' > "$main/.git/HEAD"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../repo-c-b5-wt-1 push' "$main")"
  expect_push_no_opinion
}
case_pd_c_session_default_union() {
  # B6: the RESOLVED (2) union clause's own discriminator. Session default develop; target's OWN
  # default is trunk (and no config); explicit refspec destination "develop". Measured pre-#269:
  # this ALREADY denies (rc 2) via the session's own deny set alone (develop is the session's
  # default, and #269's tokenizer/driver changes do not touch the plain refspec-parsing path a
  # segment with no resolvable "-C" already had) -- so this fixture's value is as the M53
  # discriminator (below), not as a Today-vs-After widening: under M53 (the union narrowed to
  # fallback ∪ resolved only), "develop" drops out of the deny set and this flips to no opinion.
  local main="$tmpbase/repo-c-b6" target="$tmpbase/target-b6-wt-1"
  mk_fixture_repo "$main" develop "feature/z"
  mk_fixture_repo "$target" trunk "feature/x"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../target-b6-wt-1 push origin develop' "$main")"
  expect_push_deny
}
case_pd_c_never_executes() {
  # C1: the safety property on the NEW "-C" resolution route specifically -- A2's shape, run with
  # the booby-trapped git/gh/rm/dirname PATH, asserting deny AND byte-identical file listings of
  # BOTH the session repo and the resolved "-C" target (never just the session repo, which the
  # pre-existing push-never-executes-* cases already cover). "dirname" was added to the trap set
  # in the #269 round-2 kickback (finding: the depth-1 ascent guard at resolve_repo()'s
  # `[ "$((depth + 1))" -lt "$2" ] || break` line was otherwise unpinned) -- measured: this
  # fixture's own "-C" target resolves a gitdir at depth 0 (mk_fixture_repo writes .git directly
  # at other-c1-wt-1), so dirname is never reached here regardless of that guard, in EITHER the
  # shipped script or under the guard-deleted mutant (both measured: sentinel absent, rc 2); the
  # dirname trap is harmless here, and the guard itself is pinned by push-deny-c-unresolvable-
  # never-executes (C2) below instead, whose "-C" target does NOT resolve at depth 0. This hook
  # otherwise legitimately spawns jq/awk/grep (and dirname when a SESSION checkout resolution
  # requires upward ascent -- not exercised by this fixture's own cwd, which already has ".git").
  # Measured pre-#269 (main's script): no opinion (rc 0) -- the "-C" route (and so this whole
  # safety property on it) did not exist yet; the pre-#269 script never read the "-C" value at
  # all, so it could not have executed anything derived from it either.
  local main="$tmpbase/repo-c-c1" other="$tmpbase/other-c1-wt-1"
  mk_fixture_repo "$main" main "claude/17-a"
  mk_fixture_repo "$other" develop "feature/x"
  local trapdir="$tmpbase/trapbin-c-c1" sentinel="$tmpbase/sentinel-c-c1"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before_main after_main before_other after_other
  before_main="$(find "$main" -type f -exec ls -la {} \; | sort)"
  before_other="$(find "$other" -type f -exec ls -la {} \; | sort)"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../other-c1-wt-1 push origin develop' "$main")" "$trapdir:$PATH"
  after_main="$(find "$main" -type f -exec ls -la {} \; | sort)"
  after_other="$(find "$other" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH while resolving a -C target\n"; }
  [ "$before_main" = "$after_main" ] || { __ok=0; __why="${__why}session repo's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
  [ "$before_other" = "$after_other" ] || { __ok=0; __why="${__why}resolved -C target's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
}
case_pd_c_unresolvable_never_executes() {
  # C2 (#269 round-2 kickback): pins resolve_repo()'s depth-1 ascent guard specifically -- unlike
  # C1 (whose "-C" target resolves a gitdir at depth 0 and so never reaches the ascent code at
  # all, measured), this fixture's "-C" target does NOT exist on disk (B4's own shape), so
  # resolve_repo() falls through both "[ -d ... ]"/"[ -f ... ]" checks to the ascent guard itself.
  # Booby-traps git/gh/rm/dirname; measured: shipped script -- sentinel absent, rc 2 (degrades to
  # the session's own facts, exactly as B4). With the guard deleted (M57 below), dirname IS
  # invoked (sentinel present) even though the verdict itself (rc 2) is unaffected -- the
  # resolve-then-degrade path still lands on the session's facts either way, so this fixture pins
  # the SAFETY property (never executes/never reaches an argv), not the verdict, the same
  # division of labor B4 (verdict) and C1 (safety, on the resolving route) already have.
  local main="$tmpbase/repo-c-c2"
  mk_fixture_repo "$main" develop develop
  local trapdir="$tmpbase/trapbin-c-c2" sentinel="$tmpbase/sentinel-c-c2"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before_main after_main
  before_main="$(find "$main" -type f -exec ls -la {} \; | sort)"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../missing-c2-wt-9 push' "$main")" "$trapdir:$PATH"
  after_main="$(find "$main" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH (dirname, on the unresolvable -C ascent path) while resolving a -C target\n"; }
  [ "$before_main" = "$after_main" ] || { __ok=0; __why="${__why}session repo's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
}
case_pd_c_per_segment_session_reset() {
  # D1 (#269 round-2 kickback finding): acceptance criterion 4 ("per push segment ... no leakage
  # between iterations") had NO fixture with more than one push segment -- every A/B/C fixture
  # above is single-segment, so hoisting apply_session_repo() out of the driver loop (called once
  # before the loop instead of once per segment) passed the whole committed suite. TWO push
  # segments: the FIRST carries a resolving "-C" (a separate repo, own default trunk, no config);
  # the SECOND is a bare "git push" with no "-C" at all and must be judged by the SESSION's own
  # facts, not by whatever the first segment's "-C" target left behind. Session config denies via
  # remote.origin.push=HEAD:main (main is always a PUSH_DEFAULT_BRANCH_FALLBACK member regardless
  # of the session's own default, develop) -- the sharpest shape, per the reviewing finding,
  # because a per-segment reset failure silently DROPS a real deny rather than merely mis-scoping
  # one. Measured directly against this exact fixture: shipped script -- rc 2 (deny, via
  # remote.origin.push in the SESSION's own .git/config); with apply_session_repo() hoisted above
  # the loop (the exact mutation named below as M56) -- rc 0 (deny silently lost: the second
  # segment inherits the resolved -C target's cfg_push_lines, empty, and its current_branch,
  # never resets to the session's own).
  local main="$tmpbase/repo-c-d1" other="$tmpbase/other-d1-wt-1"
  mk_fixture_repo "$main" develop "feature/x"
  mk_fixture_config "$main" $'[remote "origin"]\n\tpush = HEAD:main\n'
  mk_fixture_repo "$other" trunk "feature/y"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../other-d1-wt-1 push origin claude/99-z && git push' "$main")"
  expect_push_deny
}

# --- deny/no-opinion: #268 config-derived push routes (remote.<name>.push / push.default) -----
# Unless stated, the fixture repo has default branch main, current branch feature/x, and the
# command is a bare "git push" against an explicit cwd (see mk_fixture_config's ambient-$PWD
# comment above for why every one of these MUST pass cwd).
case_pd_config_remote_push_bare() {
  local dir="$tmpbase/repo-cfg-remote-push-bare"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_remote_push_named_remote() {
  local dir="$tmpbase/repo-cfg-remote-push-named"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push origin' "$dir")"
  expect_push_deny
}
case_pd_config_remote_push_second_line() {
  # Two "push =" lines under one remote; only the SECOND is offending -- the 0/1/2+ boundary
  # (LESSON 2026-09-08d) for a config record set, and reuse of refspec_dest()'s own
  # refs/heads/ strip on the destination side.
  local dir="$tmpbase/repo-cfg-remote-push-2nd"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:refs/heads/feature/y\n\tpush = HEAD:refs/heads/main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_no_space_assign() {
  # key=value with NO surrounding spaces (the acceptance criterion's own "key=value without
  # spaces" clause, #268 kickback finding 1) -- the *=*) split guard must recognise this form,
  # not only the "key = value" spacing every other fixture in this table happens to use.
  local dir="$tmpbase/repo-cfg-no-space-assign"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\npush=HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_push_default_upstream() {
  local dir="$tmpbase/repo-cfg-push-default-upstream"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = upstream\n[branch "feature/x"]\n\tremote = origin\n\tmerge = refs/heads/main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_push_default_tracking() {
  # "tracking" is git's documented synonym for "upstream".
  local dir="$tmpbase/repo-cfg-push-default-tracking"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = tracking\n[branch "feature/x"]\n\tremote = origin\n\tmerge = refs/heads/main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_push_default_matching() {
  # push.default = matching pushes every branch that exists on both ends -- including the
  # default branch in essentially every real repo -- so this denies unconditionally, the same
  # reasoning as --all/--mirror (Q2's default). No branch section is needed: this route never
  # consults branch.<n>.merge.
  local dir="$tmpbase/repo-cfg-push-default-matching"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = matching\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_union_benign_refspec_plus_upstream() {
  # RESOLVED Q1 union semantics (#268 kickback finding 2): a remote.origin.push refspec that
  # resolves to a NON-denying destination must not suppress the push.default route -- this hook
  # deliberately does NOT model git's own precedence (push.default consulted only when the
  # applicable remote has no push refspec); both routes are evaluated unconditionally, so a
  # config carrying a benign remote.<name>.push record AND a denying push.default still denies.
  local dir="$tmpbase/repo-cfg-union-benign-plus-upstream"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:refs/heads/feature/x\n[push]\n\tdefault = upstream\n[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_union_other_remote_bare() {
  # #268 kickback 2 finding (RESOLVED Q1's CROSS-REMOTE union, distinct from
  # push-deny-config-union-benign-refspec-plus-upstream above, which pins the union across
  # ROUTES on the SAME remote): a bare push considers EVERY configured remote's push refspecs,
  # not just the remote git's own precedence would pick (origin, absent
  # remote.pushDefault/branch.<n>.pushRemote/branch.<n>.remote). Config here carries only a
  # NON-origin remote's denying push refspec, plus a benign origin section with no push key at
  # all -- this is the fixture that makes the scope gate's "n==0 -> every remote" reading
  # observable and distinguishes it from "n==0 -> only git's own default remote".
  local dir="$tmpbase/repo-cfg-union-other-remote"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "backup"]\n\tpush = HEAD:main\n[remote "origin"]\n\turl = https://example.invalid/r.git\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_wildcard_refspec() {
  # A configured destination containing "*" pushes every matching branch; deny unconditionally
  # (Q3's default), the same reasoning as push.default=matching above.
  local dir="$tmpbase/repo-cfg-wildcard"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = refs/heads/*:refs/heads/*\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_crlf_line() {
  # #270's class, in the NEW config reader: every config line carries a CRLF ending.
  local dir="$tmpbase/repo-cfg-crlf"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\r\n\tpush = HEAD:main\r\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_crlf_interior() {
  # #268 kickback finding 3: an INTERIOR CR (not a line-ending one) inside the refspec value
  # itself -- "HEAD:ma<CR>in" -- denies via the cfg_cr strip specifically; push-deny-config-crlf-line
  # (above)'s CR is line-ending, already masked by cfg_trim()'s own [[:space:]] handling regardless
  # of cfg_cr, so it cannot distinguish "the CR strip runs" from "it doesn't" -- this fixture is
  # the one M35 (below) actually flips, making that mutant non-inert.
  local dir="$tmpbase/repo-cfg-crlf-interior"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:ma\rin\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_worktree_commondir() {
  # Config lives in the MAIN checkout's .git/config (mk_fixture_worktree's first argument), never
  # the worktree pointer dir's own gitdir -- the same common-dir rule the origin-HEAD symref read
  # already uses.
  local main="$tmpbase/repo-cfg-wt-main" wt="$tmpbase/repo-cfg-wt-pointer"
  mk_fixture_worktree "$main" "$wt" main "claude/17-a"
  mk_fixture_config "$main" $'[remote "origin"]\n\tpush = HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$wt")"
  expect_push_deny
}
case_pd_config_no_trailing_newline() {
  # The final (only) config line has no trailing newline -- the read ... || [ -n "$line" ]
  # rescue this file's while-loop needs, mirroring the idiom used elsewhere in this hook.
  local dir="$tmpbase/repo-cfg-no-trailing-nl"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:main'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_mixed_case() {
  # Section keyword and key name are both mixed-case; git treats both case-insensitively (a
  # quoted subsection name, "origin" here, stays case-sensitive and is unaffected).
  local dir="$tmpbase/repo-cfg-mixed-case"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[Remote "origin"]\n\tPush = HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_config_never_executes() {
  # Combines the never-executes-anything guarantee (booby-trapped git/gh/rm) AND the
  # byte-identical-file-listing property, both on the CONFIG deny route specifically (the
  # existing push-never-executes-* / push-never-executes-reads-only cases exercise only the
  # plain refspec-parsing routes, never the config reader added by this issue).
  local dir="$tmpbase/repo-cfg-never-executes"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:main\n'
  local trapdir="$tmpbase/trapbin-cfg-deny" sentinel="$tmpbase/sentinel-cfg-deny"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  local before after
  before="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")" "$trapdir:$PATH"
  after="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH while evaluating a config route\n"; }
  [ "$before" = "$after" ] || { __ok=0; __why="${__why}fixture repo's file listing changed — push-guard.sh wrote to or altered a file it should only read (config route)\n"; }
}
case_pn_config_neither_key() {
  # The decision's required control: a config file that sets NEITHER remote.<name>.push nor
  # push.default at all must stay no opinion.
  local dir="$tmpbase/repo-cfg-neither-key"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[core]\n\tbare = false\n[remote "origin"]\n\turl = https://example.invalid/o/r.git\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_config_remote_push_other_dest() {
  # A configured refspec that resolves to a destination other than the default branch.
  local dir="$tmpbase/repo-cfg-other-dest"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:refs/heads/feature/x\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_config_other_remote_named() {
  # n==1 exact remote scoping: "origin"'s push route must not apply to a "git push backup".
  local dir="$tmpbase/repo-cfg-other-remote"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push backup' "$dir")"
  expect_push_no_opinion
}
case_pn_config_explicit_refspec() {
  # The harness's own shape (n >= 2): config routes are NEVER consulted for a segment carrying
  # an explicit refspec -- a deny here would be a release blocker.
  local dir="$tmpbase/repo-cfg-explicit-refspec"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = HEAD:main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push -u origin "claude/17-a"' "$dir")"
  expect_push_no_opinion
}
case_pn_config_branch_other() {
  # push.default=upstream, but the [branch] section names a DIFFERENT branch than the current
  # one -- current-branch scoping on the merge lookup.
  local dir="$tmpbase/repo-cfg-branch-other"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = upstream\n[branch "other"]\n\tmerge = refs/heads/main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_config_commented_out() {
  # Comment/whitespace handling: a "#"-commented push line, a ";"-commented push.default line,
  # odd leading whitespace on the one REAL (harmless) key, none of which may be mistaken for an
  # active directive.
  local dir="$tmpbase/repo-cfg-commented-out"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n  # push = HEAD:main\n     push = feature/x\n[push]\n  ; default = matching\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_config_push_default_current() {
  # git's own default mode since 2.x: "current" is never resolved by this hook's push.default
  # route at all (only "upstream"/"tracking"/"matching" are) -- the sharp form of the clause,
  # since a branch section for the current branch IS present and WOULD deny if this mode were
  # mistaken for "upstream".
  local dir="$tmpbase/repo-cfg-default-current"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = current\n[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_config_push_default_simple() {
  local dir="$tmpbase/repo-cfg-default-simple"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = simple\n[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}

# --- role-agnostic no-opinion edges ----------------------------------------------------------------
case_pr_plan_mode()      { run_push_guard "$(mk_push_cmd_mode 'git push origin main' 'plan')"; expect_push_no_opinion; }
case_pr_wrong_tool()     { run_push_guard "$(mk_push_tool 'Read' 'git push origin main')"; expect_push_no_opinion; }
case_pr_malformed_json() {
  # Deliberately contains both literal substrings 'push' and 'git' so this exercises jq's own
  # parse failure rather than passing vacuously via either raw-stdin fast path.
  run_push_guard 'not json at all, but mentions push and git anyway'
  expect_push_no_opinion
}
case_pr_missing_command() { run_push_guard "$(mk_push_missing_command)"; expect_push_no_opinion; }

# --- never-executes / reads-only --------------------------------------------------------------
case_push_never_executes_deny() {
  local trapdir="$tmpbase/trapbin-push-deny" sentinel="$tmpbase/sentinel-push-deny"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_push_guard "$(mk_push_cmd 'git push origin main')" "$trapdir:$PATH"
  expect_push_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH\n"; }
}
case_push_never_executes_noop() {
  local trapdir="$tmpbase/trapbin-push-noop" sentinel="$tmpbase/sentinel-push-noop"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_push_guard "$(mk_push_cmd 'git push origin feature/x')" "$trapdir:$PATH"
  expect_push_no_opinion
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH\n"; }
}
case_push_reads_only() {
  # This is the first hook in this repo that reads the filesystem (git-c-guard.sh and
  # agent-boundary.sh never do) — pin that it only reads: a fixture repo's recursive file listing
  # must be byte-identical before and after a run, deny path included. No portable, reliably
  # non-hanging FIFO fixture was added for the [ -f ] guard itself (the plan's optional case) —
  # the guard is exercised implicitly by every fixture-repo case above, all of which read ordinary
  # regular files.
  local dir="$tmpbase/repo-reads-only"
  mk_fixture_repo "$dir" main feature/x
  local before after
  before="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  run_push_guard "$(mk_push_cmd_cwd 'git push origin main' "$dir")"
  after="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  [ "$before" = "$after" ] || { __ok=0; __why="${__why}fixture repo's file listing changed — push-guard.sh wrote to or altered a file it should only read\n"; }
}

# ---------------------------------------------------------------------------------------------
# name|fn|desc
cases=(
  "status-rel|case_status_rel|allow: relative sibling path, status"
  "status-abs|case_status_abs|allow: absolute path, status"
  "status-quoted|case_status_quoted|allow: double-quoted path, status"
  "path-windows|case_path_windows|allow: Windows drive-letter path, diff"
  "path-trailing-slash|case_path_trailing_slash|allow: trailing slash on the worktree path, rev-parse"
  "checkpoint-composite|case_checkpoint_composite|allow: add -A && commit composite, quoted '#'/'('/')'/'':'' survive the lexer (probe row d)"
  "reset-soft|case_reset_soft|allow: reset --soft with a literal SHA"
  "merge-base|case_merge_base|allow: merge-base"
  "restore|case_restore|allow: restore"
  "push-upstream|case_push_upstream|allow: push -u origin with a quoted branch name"
  "diff-name-only|case_diff_name_only|allow: diff --name-only"
  "log|case_log|allow: log with a <default-branch>..HEAD range and --format=%s (probe row g)"
  "never-executes-git|case_never_executes_git|allow, AND the guard never invokes git (or rm) on the untrusted PATH — sentinel absent"
  "inject-config|case_inject_config|no opinion: -c core.pager=cat inserted before the subcommand (probe row b)"
  "inject-execpath|case_inject_execpath|no opinion: --exec-path= inserted before the subcommand"
  "attached-C|case_attached_c|no opinion: -C<path> attached form"
  "double-C|case_double_c|no opinion: a second -C"
  "token1-not-C|case_token1_not_c|no opinion: --exec-path= at token 1 with an otherwise-conforming path/subcommand and a second git -C segment (isolates the exact -C match)"
  "attached-C-4tok|case_attached_c_4tok|no opinion: attached -C<path> with 4+ tokens, an otherwise-conforming path/subcommand, and a second git -C segment"
  "path-not-worktree|case_path_not_worktree|no opinion: path is not <name>-wt-<n>"
  "path-glob|case_path_glob|no opinion: unquoted glob in the path"
  "unknown-sub|case_unknown_sub|no opinion: subcommand not in the ten (clean)"
  "reset-hard|case_reset_hard|no opinion: reset --hard is not reset --soft (probe row c's static half)"
  "composite-nongit|case_composite_nongit|no opinion: composite with a non-git constituent"
  "composite-one-bad|case_composite_one_bad|no opinion: composite where one constituent injects -c"
  "substitution-dollar|case_substitution_dollar|no opinion: \$(...) inside the double-quoted commit message"
  "substitution-backtick|case_substitution_backtick|no opinion: backtick substitution inside the double-quoted commit message"
  "semicolon|case_semicolon|no opinion: unquoted ';'"
  "redirect|case_redirect|no opinion: unquoted '>'"
  "pipe|case_pipe|no opinion: unquoted '|'"
  "unterminated-quote|case_unterminated_quote|no opinion: unterminated double quote"
  "wrong-tool|case_wrong_tool|no opinion: tool_name is not Bash"
  "malformed-json|case_malformed_json|no opinion: unparseable stdin"
  "missing-command|case_missing_command|no opinion: tool_input.command absent"
  "plan-mode|case_plan_mode|no opinion: permission_mode is exactly 'plan'"
  # --- hooks/agent-boundary.sh (#235) cases -----------------------------------------------------
  # Mutation-proof table (LESSON 2026-09-01, LESSON 2026-09-07(b)): each row below cites one of
  # the single-clause mutants actually applied to hooks/agent-boundary.sh via a `cp` backup
  # refreshed immediately before every mutation, with the observed `bash dev/hook-tests.sh`
  # pass/fail delta measured against this file's case set AT THE TIME of that mutation, then
  # restored and verified with a full `diff` before the next mutation. M1-M22 were measured
  # against the round-1 47-case/82-total addition; M23 was added by the round-2 kickback
  # that fixed hooks/agent-boundary.sh:167's chained-PREFIX_WORDS bug and was measured against
  # the 49-case/84-total addition — M1-M22's own numbers were NOT re-measured against
  # the 84-total baseline (LESSON 2026-09-06 asks only for bookkeeping, i.e. count words, to be
  # reconciled after the last case is added; re-running 22 already-verified mutants is out of
  # scope for this fix). M24 (below) was added by #270's CRLF-strip fix and was measured
  # (whole-file convention — bash dev/hook-tests.sh with no filter) against the then-current
  # 143-case file (agent-boundary's own addition 52 cases; push-guard's own addition then 56
  # cases — a DIFFERENT, larger figure, 60, was the `push`-name-filtered measurement unit the push
  # mutation table below used at that point: the 56 push-section rows plus four rows from the
  # OTHER two sections whose names happen to contain the substring "push" (push-upstream,
  # impl-deny-push-bare, impl-deny-push-ns, impl-deny-git-c-push) — M1-M23's own numbers were NOT
  # re-measured against that 143-case total: the 82/84-case figures above predate #260's
  # push-guard section entirely (it did not exist yet when M1-M22 were measured, and held 52
  # cases, not 56, immediately before #270 added four CRLF fixtures to it). M25 (below) was also
  # added by the #270 round-2 kickback, probing this file for the same trailing-vs-once-only gap
  # the push table's M24/M25 close for hooks/push-guard.sh — see M25's own entry for why no
  # fixture here closes it (a boundary interior-CR fixture is not added: not required unless
  # judged necessary to make a table sentence true, and none currently claims that coverage).
  # M1-M25 (this section) were NOT re-run for #268 — that issue added twenty push-* fixtures
  # (below), growing the whole-file total from 143 to 163 and the push-filtered unit from 60 to
  # 80; the #268 round-2 kickback then added three more push-* fixtures, growing the whole-file
  # total to 166 and the push-filtered unit to 83; the #268 round-3 kickback then added one more
  # push-* fixture, growing the whole-file total to 167 and the push-filtered unit to 84; #269
  # (below) then added twelve more push-* fixtures, growing the whole-file total to 179 and the
  # push-filtered unit to 96; the #269 round-2 kickback then added two more push-* fixtures,
  # growing the whole-file total to the CURRENT 181 and the push-filtered unit to 98 — none of the
  # five rounds touched agent-boundary.sh vocabulary or behaviour, so none of this section's own
  # historical "143-case"/"140 pass"/"143 pass" figures were re-measured.
  # M1/M2 (the two raw-stdin fast paths) are
  # coarse — breaking either silences the WHOLE hook, so they only distinguish a deny-verdict
  # case from everything else, never one deny case from another:
  #   M1  fast path 1 pattern corrupted (*agent_type* -> *agentXtype*)      -> 55 pass, 27 fail
  #   M2  fast path 2 pattern corrupted (*git*|*gh* -> *gitX*|*ghX*)        -> 55 pass, 27 fail
  #       (M1 and M2 fail the identical 27-case set: every impl-deny-*/verif-deny-* case plus
  #       boundary-never-executes-deny — i.e. every case whose correct verdict is "deny", from
  #       the round-1 82-case set; the round-2 chained-prefix cases were not yet added.)
  #   M3  the .tool_name == "Bash" check disabled                          -> 81 pass,  1 fail
  #   M4  AGENT_TYPES_IMPLEMENTER's bare spelling renamed (-> implementerX) -> 69 pass, 13 fail
  #   M5  AGENT_TYPES_VERIFIER's bare spelling renamed (-> verifierX)      -> 71 pass, 11 fail
  #   M6  the permission_mode == "plan" check disabled                     -> 81 pass,  1 fail
  #   M7  the PREFIX_WORDS membership skip disabled                        -> 80 pass,  2 fail
  #   M8  the assignment-prefix regex made unmatchable                     -> 81 pass,  1 fail
  #   M9  normalize()'s basename-after-last-/ step removed                 -> 81 pass,  1 fail
  #   M10 normalize()'s double-quote strip disabled                        -> 81 pass,  1 fail
  #   M11 the "-C" skip-with-its-argument step disabled                    -> 81 pass,  1 fail
  #   M12 the "-globalopt-" sentinel replaced with skip-and-keep-scanning  -> 81 pass,  1 fail
  #   M13 "log" dropped from VERIFIER_GIT_READONLY                         -> 80 pass,  2 fail
  #   M13b "status" dropped from VERIFIER_GIT_READONLY                     -> 80 pass,  2 fail
  #   M13c "diff" dropped from VERIFIER_GIT_READONLY                       -> 81 pass,  1 fail
  #   M13d "restore" dropped from VERIFIER_GIT_READONLY                    -> 81 pass,  1 fail
  #   M13e "show" dropped from VERIFIER_GIT_READONLY                       -> 81 pass,  1 fail
  #   M14 implementer's deny branch gated on an unmatchable role string    -> 81 pass,  1 fail
  #   M15 the resolved-role empty-guard ([ -n "$role" ] || exit 0) removed -> 80 pass,  2 fail
  #   (M16, M17, M19 were retired during drafting — no mutant was ever run under those numbers;
  #   left unused rather than renumbered, so every table row's M-number always matches the
  #   case-row citation that names it.)
  #   M18 tool_input.command's jq default changed from empty to "git push" -> 81 pass,  1 fail
  #   M20 the awk cmdword=="git" exact match widened to a substring test   -> 81 pass,  1 fail
  #   M21 command-position broken: a later exact "git"/"gh" token in the   -> 81 pass,  1 fail
  #       same segment overrides an already-resolved, non-git command word
  #   M22 "-C" exact match widened to also match lowercase "-c"            -> 81 pass,  1 fail
  #   M23 hooks/agent-boundary.sh:167's saw_prefix once-only guard restored -> 82 pass,  2 fail
  #       (!saw_prefix && (norm in prefix_set)), so only the FIRST recognised PREFIX_WORDS token
  #       in a segment is skipped instead of every one — measured against the then-current
  #       49-case/84-total addition (#235 round 2); not re-run for #270 (the two new
  #       chained-prefix fixtures were the only cases that flipped then)
  #   M24 the two #270 CR-strip lines deleted (cr=$'\r'; cmd="${cmd//$cr/}") -> 140 pass,  3 fail
  #       (whole-file convention, measured against the then-current 143-case file — the three new
  #       #270 boundary CRLF fixtures, impl-deny-crlf-cmdword/verif-deny-crlf-gh/
  #       verif-noop-crlf-status, are the only cases that flip; NOT re-measured against the
  #       167-case file that stood after #268 (round 1), its round-2 kickback, or its round-3
  #       kickback (grown to the CURRENT 181 by #269 below and its own round-2 kickback, neither
  #       of which touched agent-boundary.sh either) — see this section's header note above)
  #   M25 the shipped global strip narrowed to once-only                    -> 143 pass,  0 fail
  #       (cmd="${cmd//$cr/}" -> cmd="${cmd/$cr/}"; #270 round-2 kickback probe, whole-file
  #       convention) -- NOT flipped by any fixture in this file: each of the three #270
  #       boundary CRLF fixtures carries exactly one CR, so removing "the first" is identical
  #       to removing "every" for all three — a real gap in this table's own coverage (the push
  #       table's analogous M24/M25 close the same gap for hooks/push-guard.sh because
  #       push-deny-crlf-interior carries a second, non-edge CR that none of these three
  #       boundary fixtures do); left open here rather than papered over, since adding a
  #       boundary interior-CR fixture is not required unless judged necessary to make a table
  #       sentence true, and no sentence in this table claims this coverage
  # Six fixtures (impl-noop-npm-test/pytest/selfcheck, role-noop-no-agent-type,
  # role-noop-agent-id-only, and role-noop-malformed-json) are, verified by direct measurement,
  # NOT flipped by any of M1-M25: their raw JSON never contains the literal substring their
  # governing fast path requires (fast path 1's `agent_type` for the two role-agnostic fixtures,
  # fast path 2's `git`/`gh` for the three implementer no-opinion commands), or — for the
  # malformed-JSON fixture — jq's own parse failure independently yields an empty extraction no
  # matter which downstream check is broken. Widening either fast path's pattern to let them
  # through (checked directly, not merely inferred) still leaves them correctly "no opinion",
  # because the checks below re-derive the identical answer from the same absent/unparseable
  # data — the redundancy the header's fast-path comment describes (semantics-preserving except
  # for a command word split by quote/backslash characters, which none of these six fixtures'
  # commands are) is holding for them, not a coverage gap. Their comment below says so instead of
  # citing a mutant that was never observed to fail them.
  "impl-deny-push-bare|case_ib_push_bare|implementer deny: git push (agent_type: implementer) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-push-ns|case_ib_push_ns|implementer deny: git push (agent_type: trail-blazer-flow:implementer) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-gh-pr-bare|case_ib_gh_pr_bare|implementer deny: gh pr create (agent_type: implementer) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-gh-pr-ns|case_ib_gh_pr_ns|implementer deny: gh pr create (agent_type: trail-blazer-flow:implementer) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-gh-issue-edit|case_ib_gh_issue_edit|implementer deny: gh issue edit --add-label plan-approved -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-git-c-push|case_ib_git_c_push|implementer deny: git -C <worktree> push (the form git-c-guard.sh's own allow cases approve) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-composite-and|case_ib_composite_and|implementer deny: pytest && git push (second segment) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-assignment|case_ib_assignment|implementer deny: FOO=1 git push (assignment-prefix skip) -- measured: M8, 81 pass 1 fail"
  "impl-deny-command-prefix|case_ib_command_prefix|implementer deny: command git push (PREFIX_WORDS skip) -- measured: M7, 80 pass 2 fail (with impl-deny-bash-c)"
  "impl-deny-abs-path|case_ib_abs_path|implementer deny: /usr/bin/git push (basename normalisation) -- measured: M9, 81 pass 1 fail"
  "impl-deny-bash-c|case_ib_bash_c|implementer deny: bash -c \"git push\" (PREFIX_WORDS + quote-strip) -- measured: M10, 81 pass 1 fail (also M7, 80 pass 2 fail, with impl-deny-command-prefix)"
  "impl-deny-semicolon|case_ib_semicolon|implementer deny: echo hi; gh pr create (second segment) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-subshell|case_ib_subshell|implementer deny: (cd x && git push) (paren segment breaks) -- measured: M1/M2, 55 pass 27 fail"
  "impl-deny-readonly-subcommand|case_ib_readonly_subcommand|implementer deny: git status --porcelain (implementer denies even a VERIFIER_GIT_READONLY subcommand -- isolates the role-policy split) -- measured: M14, 81 pass 1 fail"
  "impl-deny-chained-prefix|case_ib_chained_prefix|implementer deny: sudo bash -c \"git push\" (TWO chained PREFIX_WORDS tokens) -- measured: M23, 82 pass 2 fail (with verif-deny-chained-prefix)"
  "impl-deny-crlf-cmdword|case_ib_crlf_cmdword|implementer deny: git<CR> push (#270, CR on the command word -- the only place a CR evades this hook) -- measured: M24, 140 pass 3 fail (with verif-deny-crlf-gh and verif-noop-crlf-status)"
  "impl-noop-npm-test|case_in_npm_test|implementer no opinion: npm test -- measured: not flipped by M1-M24 (no git/gh substring anywhere in the raw stdin -- fast path 2 alone already excludes it; see the table header note above)"
  "impl-noop-pytest|case_in_pytest|implementer no opinion: pytest -q -- measured: not flipped by M1-M24 (same as impl-noop-npm-test)"
  "impl-noop-selfcheck|case_in_selfcheck|implementer no opinion: bash dev/selfcheck.sh -- measured: not flipped by M1-M24 (same as impl-noop-npm-test)"
  "impl-noop-grep-arg|case_in_grep_arg|implementer no opinion: grep -rn \"git push\" . (git as argument, not command word) -- measured: M21, 81 pass 1 fail"
  "impl-noop-git-c-guard-script|case_in_git_c_guard_script|implementer no opinion: bash hooks/git-c-guard.sh (basename contains, but isn't, \"git\") -- measured: M20, 81 pass 1 fail"
  "verif-noop-diff|case_vn_diff|verifier no opinion: git diff <default>...HEAD --stat -- measured: M13c, 81 pass 1 fail"
  "verif-noop-log|case_vn_log|verifier no opinion: git log <default>..HEAD --format=%s -- measured: M13, 80 pass 2 fail (with verif-noop-c-log)"
  "verif-noop-status|case_vn_status|verifier no opinion: git status --porcelain -- measured: M13b, 80 pass 2 fail (with boundary-never-executes-noop)"
  "verif-noop-restore|case_vn_restore|verifier no opinion: git restore <file> -- measured: M13d, 81 pass 1 fail"
  "verif-noop-c-log|case_vn_c_log|verifier no opinion: git -C <worktree> log <default>..HEAD --format=%s -- measured: M11, 81 pass 1 fail (also M13, 80 pass 2 fail, with verif-noop-log)"
  "verif-noop-show-ns|case_vn_show_ns|verifier no opinion: git show HEAD (agent_type: trail-blazer-flow:verifier) -- measured: M13e, 81 pass 1 fail"
  "verif-noop-crlf-status|case_vn_crlf_status|verifier no opinion: git status<CR> (#270 -- pre-fix this DENIES, fail-closed; the only new case whose pre-fix failure is a deny, proving the fix is not a blanket widening) -- measured: M24, 140 pass 3 fail (with impl-deny-crlf-cmdword and verif-deny-crlf-gh)"
  "verif-deny-commit|case_vd_commit|verifier deny: git commit -m x -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-stash|case_vd_stash|verifier deny: git stash -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-checkout|case_vd_checkout|verifier deny: git checkout -- <file> -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-gh-comment-bare|case_vd_gh_comment_bare|verifier deny: gh issue comment (agent_type: verifier) -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-gh-comment-ns|case_vd_gh_comment_ns|verifier deny: gh issue comment (agent_type: trail-blazer-flow:verifier) -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-inject-config|case_vd_inject_config|verifier deny: git -c core.pager=cat log (unrecognised global option -> -globalopt-) -- measured: M22, 81 pass 1 fail"
  "verif-deny-no-pager-log|case_vd_no_pager_log|verifier deny: git --no-pager log (no-argument global option before a genuinely readonly subcommand -- isolates the -globalopt- sentinel) -- measured: M12, 81 pass 1 fail"
  "verif-deny-git-dir|case_vd_git_dir|verifier deny: git --git-dir=... push (unrecognised global option -> -globalopt-) -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-c-commit|case_vd_c_commit|verifier deny: git -C <worktree> commit -m x -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-clean|case_vd_clean|verifier deny: git clean -fd (unlisted subcommand, fail-closed) -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-bare-git|case_vd_bare_git|verifier deny: bare git (-none-, fail-closed) -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-composite|case_vd_composite|verifier deny: pytest && git commit -m x (second segment) -- measured: M1/M2, 55 pass 27 fail"
  "verif-deny-chained-prefix|case_vd_chained_prefix|verifier deny: env sudo git commit -m x (TWO chained PREFIX_WORDS tokens) -- measured: M23, 82 pass 2 fail (with impl-deny-chained-prefix)"
  "verif-deny-crlf-gh|case_vd_crlf_gh|verifier deny: gh<CR> issue comment 1 -b x (#270, the gh branch's exact command-word compare) -- measured: M24, 140 pass 3 fail (with impl-deny-crlf-cmdword and verif-noop-crlf-status)"
  "role-noop-no-agent-type|case_ra_no_agent_type_key|role-agnostic no opinion: no agent_type key at all (main session), git push -- measured: not flipped by M1-M24 (no 'agent_type' substring anywhere in the raw stdin -- fast path 1 alone already excludes it, and independently the jq .agent_type extraction below would also come back empty; see the table header note above)"
  "role-noop-explore|case_ra_explore|role-agnostic no opinion: agent_type is \"Explore\" (unrecognised role) -- measured: M15 ([ -n \"\$role\" ] || exit 0 removed), 80 pass 2 fail (with role-noop-empty-agent-type)"
  "role-noop-empty-agent-type|case_ra_empty_agent_type|role-agnostic no opinion: agent_type is the empty string -- measured: M15, 80 pass 2 fail (with role-noop-explore)"
  "role-noop-agent-id-only|case_ra_agent_id_only|role-agnostic no opinion: agent_id present, no agent_type key -- measured: not flipped by M1-M24 (same reason as role-noop-no-agent-type -- 'agent_id' does not contain the substring 'agent_type')"
  "role-noop-plan-mode|case_ra_plan_mode|role-agnostic no opinion: implementer git push under permission_mode: \"plan\" -- measured: M6, 81 pass 1 fail"
  "role-noop-wrong-tool|case_ra_wrong_tool|role-agnostic no opinion: tool_name is \"Read\", not \"Bash\" -- measured: M3, 81 pass 1 fail"
  "role-noop-malformed-json|case_ra_malformed_json|role-agnostic no opinion: unparseable stdin (carries both agent_type and git substrings) -- measured: not flipped by M1-M24, including M3 (jq's own parse failure independently yields an empty .tool_name/.agent_type extraction regardless of which downstream check runs)"
  "role-noop-missing-command|case_ra_missing_command|role-agnostic no opinion: tool_input.command absent -- measured: M18, 81 pass 1 fail"
  "boundary-never-executes-deny|case_boundary_never_executes_deny|deny, AND the boundary never invokes git/gh/rm on the booby-trapped PATH — sentinel absent -- measured: M1/M2, 55 pass 27 fail"
  "boundary-never-executes-noop|case_boundary_never_executes_noop|no opinion, AND the boundary never invokes git/gh/rm on the booby-trapped PATH — sentinel absent -- measured: M13b, 80 pass 2 fail (with verif-noop-status)"
  # --- hooks/push-guard.sh (#260) cases -----------------------------------------------------------
  # Mutation-proof table (LESSON 2026-09-01, LESSON 2026-09-07(b)): each row below cites one of
  # the mutants actually applied to hooks/push-guard.sh via a Python literal-string replace
  # asserting exactly one occurrence (never a regex, to avoid a silent no-op substitution), with
  # the observed `bash dev/hook-tests.sh push` pass/fail delta measured against this file's
  # 56-case push-* set AS IT STOOD AT #260, then restored and verified with a full `diff` before
  # the next mutation. M1-M22 were NOT re-run for #270 — only M23-M25 were measured against the
  # 60-case push-* set (the #260 56-case baseline plus the four new #270 CRLF fixtures). M1-M25
  # were NOT re-run for #268 — only M26-M42 were measured against the then-current 80-case
  # push-* set (the #270 60-case baseline plus the twenty new #268 config-route fixtures). M26-M42
  # were NOT re-run for the #268 round-2 kickback — only M43/M44 (below), plus a re-measurement of
  # M35, were measured against the then-current 83-case push-* set (the 80-case baseline plus three
  # more fixtures: a no-space key=value assignment, a benign-refspec-plus-upstream union probe, and
  # an interior-CR refspec value). M26-M44 were NOT re-run for the #268 round-3 kickback — only
  # M45 (below) was measured against the then-current 84-case push-* set (the 83-case baseline
  # plus one more fixture: a cross-remote union bare-push probe). #269 adds the "-C <path>"
  # resolution mutants M46-M55 (below), each FIRST measured against the then-current 96-case
  # push-* set (the 84-case baseline plus the twelve new #269 fixtures); #269 ALSO re-points and
  # re-measures, against that same then-current 96-case set, every existing mutant whose recipe
  # names a line that moved into the new resolve_repo() function — M14, M15, M17, M18, M26, M28,
  # M33, M34, M35, M36, M37, M38, and M43 — each entry above carries its historical figure
  # (measured at its own baseline) followed by its RE-POINTED/RE-MEASURED figure against that
  # 96-case set; several (M14, M15, M17, M26) gained NEW failing cases beyond their historical
  # set, since resolve_repo() is now called for both the session checkout and any resolved "-C"
  # target, so a mutation to its shared body can now also decide a "-C" fixture's verdict, not
  # only a session-only one. No other mutant in M1-M45 (M46-M55's own predecessors) names code
  # that moved. The #269 ROUND-2 KICKBACK (a verifier finding that the per-segment reset had no
  # multi-segment fixture, plus a Note that the depth-1 ascent guard had no fixture at all) adds
  # TWO more fixtures — push-deny-c-unresolvable-never-executes (C2) and
  # push-deny-c-per-segment-session-reset (D1) — growing the push-* set to the CURRENT 98 cases,
  # and TWO more mutants, M56 and M57 (below M55). Re-running M46-M55 plus the thirteen
  # RE-POINTED mutants above against this CURRENT 98-case set changes only the PASS count (+2
  # throughout, from the two new passing fixtures) for every one of them EXCEPT four, which each
  # gain exactly one more failing case purely because C2/D1 happen to share a code path an
  # UNCHANGED existing mutant already covered (no code moved this round — this is a
  # new-fixture-matches-an-old-mutant event, not a re-pointing event): M14 and M15 (current_branch
  # / default_branch forced empty) and M52 (unresolvable "-C" target clears instead of degrading)
  # each gain C2, since C2 shares B4's exact verdict mechanism (a bare push judged by the
  # SESSION's own current/default branch after a failed "-C" resolution restores them); M26 (the
  # config-read guard disabled) gains D1, since D1's second segment shares
  # push-deny-config-remote-push-bare's exact mechanism (a bare push denied via the SESSION's own
  # remote.origin.push config). Every other M1-M55 entry's failing SET is unchanged by this
  # kickback (verified directly, not assumed — each of M17, M18, M28, M33, M34, M35, M36, M37,
  # M38, M43, M46, M47, M48, M49, M50, M51, M53, M54, M55 was re-run against the CURRENT 98-case
  # set and produces the identical failing-case list, +2 pass).
  # M1/M2 (the two raw-stdin fast paths) are coarse — breaking either silences the WHOLE hook, so
  # they only distinguish a deny-verdict case from everything else, never one deny case from
  # another:
  #   M1  fast path 1 pattern corrupted (*push* -> *pushX*)                -> 23 pass, 33 fail
  #   M2  fast path 2 pattern corrupted (*git* -> *gitX*)                  -> 23 pass, 33 fail
  #       (M1 and M2 fail the identical 33-case set, measured against the #260 56-case baseline:
  #       every push-deny-* case plus push-never-executes-deny and
  #       push-never-executes-reads-only — the four new #270 push-deny-crlf-* /
  #       push-noop-crlf-feature fixtures did not exist yet)
  #   M3  the .tool_name == "Bash" check disabled                         -> 55 pass,  1 fail
  #   M4  the .permission_mode == "plan" check disabled                   -> 55 pass,  1 fail
  #   M5  PREFIX_WORDS emptied                                            -> 54 pass,  2 fail
  #   M6  GIT_GLOBAL_OPTS_WITH_VALUE skip changed from j+=2 to j+=1       -> 53 pass,  3 fail
  #   M7  PREFIX_WORDS once-only regression (the agent-boundary.sh M23    -> 55 pass,  1 fail
  #       class: !saw_prefix && (norm in prefix_set), so only the FIRST
  #       recognised token in a segment is skipped instead of every one)
  #   M8  PUSH_ALL_REFS_OPTS emptied                                      -> 54 pass,  2 fail
  #   M9  PUSH_OPTS_WITH_VALUE skip changed from idx+=2 to idx+=1         -> 55 pass,  1 fail
  #   M10 the leading-'+' strip removed                                   -> 55 pass,  1 fail
  #   M11 the colon-split removed (dest always = the whole token)         -> 50 pass,  6 fail
  #   M12 the HEAD/@ -> current-branch substitution removed               -> 55 pass,  1 fail
  #   M13 the refs/heads/ prefix-strip removed                            -> 54 pass,  2 fail
  #   M14 current_branch resolution forced empty                         -> 54 pass,  2 fail
  #       (kills push-deny-head-on-main, push-deny-bare-on-main. #269 RE-POINTED: this line now
  #       lives inside the shared resolve_repo() function, called once for the session and, per
  #       resolved "-C" segment, once more; RE-MEASURED against the then-current 96-case push-* set:
  #       -> 88 pass, 8 fail — the same two historical cases plus six the shared function now also
  #       decides: push-deny-c-sibling-wt-bare-on-default, push-deny-c-sibling-wt-head-refspec,
  #       push-deny-c-unresolvable-degrades, push-deny-config-push-default-upstream,
  #       push-deny-config-push-default-tracking, push-deny-config-union-benign-refspec-plus-
  #       upstream — the last three because branch.<current>.merge is captured only under
  #       cfg_subsection==current_branch, and current_branch is now empty on every call, not just
  #       the session's. RE-MEASURED again for the #269 round-2 kickback against the CURRENT
  #       98-case push-* set: -> 89 pass, 9 fail — the same eight cases plus
  #       push-deny-c-unresolvable-never-executes (C2), which shares push-deny-c-unresolvable-
  #       degrades' (B4's) exact mechanism: a bare push judged by the SESSION's own current_branch
  #       after a failed "-C" resolution restores it — no code moved for this addition, C2 simply
  #       exercises the identical existing dependency)
  #   M15 default_branch resolution forced empty                         -> 53 pass,  3 fail
  #       (kills push-deny-trunk-base, push-deny-trunk-subdir, push-deny-trunk-worktree. #269
  #       RE-POINTED (same shared resolve_repo() function) and RE-MEASURED against the then-current
  #       96-case push-* set: -> 87 pass, 9 fail — the three historical cases plus six more:
  #       push-deny-c-sibling-wt-bare-on-default, push-deny-c-other-repo-explicit-develop,
  #       push-deny-c-sibling-wt-head-refspec, push-deny-c-unresolvable-degrades, push-deny-c-
  #       session-default-union, push-deny-c-never-executes — every "-C" deny fixture whose verdict
  #       depends on SOME default branch resolving, session's or the resolved target's; the two
  #       fixtures that deny via CONFIG rather than a default-branch match
  #       (push-deny-c-other-repo-config-route, push-noop-c-other-repo-ignores-session-config) are
  #       unaffected. RE-MEASURED again for the #269 round-2 kickback against the CURRENT 98-case
  #       push-* set: -> 88 pass, 10 fail — the same nine cases plus
  #       push-deny-c-unresolvable-never-executes (C2), for the identical reason M14 above gained
  #       it: C2 mirrors B4's dependency on the session's own default_branch too)
  #   M16 PUSH_DEFAULT_BRANCH_FALLBACK emptied                            -> 55 pass,  1 fail
  #   M17 the worktree common-dir derivation broken (never strips        -> 55 pass,  1 fail
  #       /worktrees/* from gitdir)
  #       (kills only push-deny-trunk-worktree. #269 RE-POINTED (shared resolve_repo()) and
  #       RE-MEASURED against the then-current 96-case push-* set: -> 94 pass, 2 fail — the
  #       historical case plus push-deny-config-worktree-commondir, #268's own worktree-config
  #       fixture, which depends on the identical common-dir derivation. RE-MEASURED again for the
  #       #269 round-2 kickback against the CURRENT 98-case push-* set: -> 96 pass, 2 fail —
  #       unchanged failing set, +2 pass from the two new #269-round-2 fixtures, neither a
  #       worktree)
  #   M18 the upward .git walk disabled (dir="$parent" -> dir="$dir",     -> 55 pass,  1 fail
  #       so it never leaves the starting directory)
  #       (kills only push-deny-trunk-subdir. #269 RE-POINTED (shared resolve_repo()) and
  #       RE-MEASURED against the then-current 96-case push-* set: -> 95 pass, 1 fail — unchanged
  #       failing set; no #268/#269 fixture depends on a multi-level upward walk. RE-MEASURED
  #       again for the #269 round-2 kickback against the CURRENT 98-case push-* set: -> 97 pass,
  #       1 fail — unchanged failing set, +2 pass; neither new fixture depends on a multi-level
  #       upward walk either)
  #   M19 is_deny_member widened from an exact word match to a per-      -> 55 pass,  1 fail
  #       member PREFIX match (main* matches "main-ish")
  #   M20 the "refs/* (a tag, a note) -> skip" clause changed to a       -> 56 pass,  0 fail
  #       no-op (dest left unchanged) -- NOT flipped: confirms
  #       push-noop-refs-tags is unaffected because this implementation
  #       only ever strips the "refs/heads/" prefix specifically, so an
  #       un-skipped tag ref's full literal path can never coincidentally
  #       equal a plain branch name in the deny set
  #   M21 normalize()'s basename-after-last-/ step removed                -> 55 pass,  1 fail
  #   M22 tool_input.command's jq default changed from empty to a real   -> 55 pass,  1 fail
  #       command string
  #   M23 the two #270 CR-strip lines deleted (cr=$'\r'; cmd="${cmd//$cr/}") -> 57 pass,  3 fail
  #       (measured against the then-current 60-case push-* set — the three new #270 push-deny-crlf-*
  #       fixtures are the only cases that flip; push-noop-crlf-feature is NOT flipped, see below.
  #       Re-measured after the #270 round-2 kickback rewrote push-deny-crlf-interior's raw
  #       command from two CRs to three — the figures and failing set are unchanged from the
  #       original two-CR fixture)
  #   M24 the shipped global strip narrowed to trailing-only                -> 58 pass,  2 fail
  #       (cmd="${cmd//$cr/}" -> cmd="${cmd%$cr}"; #270 round-2 kickback, added because M23 alone
  #       cannot distinguish "strips every \r" from "strips only a trailing \r" — measured against
  #       the then-current 60-case push-* set: kills push-deny-crlf-interior and push-deny-crlf-cmdword,
  #       neither of whose verdict-bearing CR is the command's final byte; does NOT kill
  #       push-deny-crlf-dest, whose single CR IS the final byte)
  #   M25 the shipped global strip narrowed to once-only                    -> 59 pass,  1 fail
  #       (cmd="${cmd//$cr/}" -> cmd="${cmd/$cr/}"; #270 round-2 kickback finding — the original
  #       two-CR push-deny-crlf-interior fixture's verdict-bearing CR happened to be its FIRST, so
  #       this mutant survived the whole 60-case set undetected until the fixture was rewritten to
  #       a three-CR command whose verdict-bearing CR is the SECOND, not the first — measured
  #       against the then-current 60-case push-* set: kills only push-deny-crlf-interior; does NOT
  #       kill push-deny-crlf-dest or push-deny-crlf-cmdword, each of whose single CR IS the first
  #       (and only) one)
  # #268's config-route mutants (M26-M42), measured against the then-current 80-case push-* set
  # (NOT re-run for the #268 round-2 kickback below — see this section's header note above); each
  # applied via a Python literal-string replace asserting exactly one occurrence, restored and
  # verified with a full `diff` + sha256 before the next mutation:
  #   M26 the config read guard disabled (if [ -f "$cfgf" ]; then -> if false           -> 68 pass,
  #       && [ -f "$cfgf" ]; then)                                                       12 fail
  #       (fails all twelve push-deny-config-* cases: remote-push-bare, remote-push-named-remote,
  #       remote-push-second-line, push-default-upstream, push-default-tracking,
  #       push-default-matching, wildcard-refspec, crlf-line, worktree-commondir,
  #       no-trailing-newline, mixed-case, and never-executes -- config is never read at all, so
  #       none of the twelve config-derived deny routes fire. #269 RE-POINTED: this line now lives
  #       inside the shared resolve_repo() function, so the guard is disabled for the "-C" target
  #       call too; RE-MEASURED against the then-current 96-case push-* set: -> 79 pass, 17 fail --
  #       every one of the SIXTEEN push-deny-config-* fixtures now in the suite (the original
  #       twelve plus the four #268 round-2/round-3 additions: no-space-assign, union-benign-
  #       refspec-plus-upstream, union-other-remote-bare, crlf-interior) plus the new #269
  #       push-deny-c-other-repo-config-route (A4), whose deny is likewise decided entirely by a
  #       resolved checkout's config. RE-MEASURED again for the #269 round-2 kickback against the
  #       CURRENT 98-case push-* set: -> 80 pass, 18 fail — the same seventeen cases plus
  #       push-deny-c-per-segment-session-reset (D1), whose SECOND segment shares
  #       push-deny-config-remote-push-bare's exact mechanism: a bare push denied via the
  #       SESSION's own remote.origin.push config, disabled here for the SESSION-scope
  #       resolve_repo() call too, not just the "-C" one -- this is the same shared-function
  #       dependency, not new code)
  #   M27 the n==1 exact-remote-scoping guard disabled (if [ -n "$scope" ] &&             -> 79 pass,
  #       [ "$sub" != "$scope" ]; then -> if false && ...)                                 1 fail
  #       (kills only push-noop-config-other-remote-named -- "origin"'s own push route wrongly
  #       applies to a "git push backup")
  #   M28 the [branch "<current>"] scoping guard disabled (if [ "$cfg_subsection" =       -> 79 pass,
  #       "$current_branch" ]; then -> if true || ...)                                     1 fail
  #       (kills only push-noop-config-branch-other -- a DIFFERENT branch's merge value wrongly
  #       applies to the current branch. #269 RE-POINTED (shared resolve_repo()) and RE-MEASURED
  #       against the then-current 96-case push-* set: -> 95 pass, 1 fail — unchanged failing set;
  #       no #269 fixture depends on this guard, since none of the twelve new fixtures configures a
  #       [branch] section at all. RE-MEASURED again for the #269 round-2 kickback against the
  #       CURRENT 98-case push-* set: -> 97 pass, 1 fail — unchanged failing set, +2 pass; neither
  #       new fixture configures a [branch] section either)
  #   M29 the push.default mode-check pattern widened to match every value               -> 77 pass,
  #       ([Uu][Pp][Ss][Tt][Rr][Ee][Aa][Mm]|[Tt][Rr][Aa][Cc][Kk][Ii][Nn][Gg]) -> *))         3 fail
  #       (kills push-noop-config-push-default-current and push-noop-config-push-default-simple,
  #       whose branch sections WOULD deny if their mode were mistaken for upstream; also kills
  #       push-deny-config-push-default-matching as a side effect -- the "matching" case arm
  #       becomes unreachable once "*)" matches everything first, so that fixture's config, which
  #       has no branch section, resolves to no destination at all instead of denying)
  #   M30 "tracking" dropped from the upstream/tracking pattern (...[Mm]|[Tt]...[Gg])      -> 79 pass,
  #       -> [Uu][Pp][Ss][Tt][Rr][Ee][Aa][Mm]))                                              1 fail
  #       (kills only push-deny-config-push-default-tracking)
  #   M31 the push.default=matching deny arm's body replaced with a no-op (:              -> 79 pass,
  #       instead of __deny_dest=.../__deny_kind=.../__deny_via=...)                        1 fail
  #       (kills only push-deny-config-push-default-matching)
  #   M32 the wildcard-destination ("*") deny check removed from config_deny()'s          -> 79 pass,
  #       per-record loop (the case "$dest" in *'*'*) ... esac block deleted)               1 fail
  #       (kills only push-deny-config-wildcard-refspec -- its resolved destination, a literal
  #       "*", falls through to an ordinary is_deny_member compare and does not match)
  #   M33 only the FIRST remote.<name>.push record is ever kept ([ -n                     -> 79 pass,
  #       "$cfg_push_lines" ] || cfg_push_lines=... guard added before the append)          1 fail
  #       (kills only push-deny-config-remote-push-second-line -- the fixture's first, harmless
  #       push= line wins and the second, offending one is never seen. #269 RE-POINTED (shared
  #       resolve_repo()) and RE-MEASURED against the then-current 96-case push-* set: -> 95 pass,
  #       1 fail — unchanged failing set; no #269 fixture's config carries two push= lines under
  #       one remote. RE-MEASURED again for the #269 round-2 kickback against the CURRENT 98-case
  #       push-* set: -> 97 pass, 1 fail — unchanged failing set, +2 pass; neither new fixture's
  #       config carries two push= lines under one remote either)
  #   M34 the comment-stripping assignment disabled (if [ "${#cfg_h}" -le               -> 80 pass,
  #       "${#cfg_s}" ]; then cfgline="$cfg_h"; else cfgline="$cfg_s"; fi -> :)             0 fail
  #       -- NOT flipped: every "#"/";"-commented directive in this table's fixtures keeps its
  #       comment marker as a literal, non-whitespace prefix character on the key (e.g. "# push"
  #       or "; default"), which the exact case patterns below ([Pp][Uu][Ss][Hh],
  #       [Dd][Ee][Ff][Aa][Uu][Ll][Tt]) can never match regardless of whether the comment is
  #       stripped -- confirms push-noop-config-commented-out's comment lines are harmless for a
  #       DIFFERENT, more fundamental reason than the strip itself (exact-key matching), a
  #       genuine measured finding, not an assumption (see M40 below for the mutant that DOES
  #       exercise that fixture). #269 RE-POINTED (shared resolve_repo()) and RE-MEASURED against
  #       the then-current 96-case push-* set: -> 96 pass, 0 fail — still NOT flipped, same reason
  #       (no #269 fixture's config carries a "#"/";"-commented directive either). RE-MEASURED
  #       again for the #269 round-2 kickback against the CURRENT 98-case push-* set: -> 98 pass,
  #       0 fail — still NOT flipped, same reason (neither new fixture's config carries a
  #       "#"/";"-commented directive either)
  #   M35 the config-line CR strip disabled (cfgline="${cfgline//$cfg_cr/}" -> :) -- FIRST
  #       measured (then-current 80-case push-* set, #268 round 1): -> 80 pass, 0 fail (not
  #       flipped). RE-MEASURED for the #268 round-2 kickback (finding 3), after
  #       push-deny-config-crlf-interior (below) was added, against the then-current 83-case
  #       push-* set: -> 82 pass, 1 fail. NOT re-run for the #268 round-3 kickback.
  #       -- push-deny-config-crlf-line is STILL not flipped: cfg_trim()'s [[:space:]]
  #       bracket-class strip (applied to every line regardless) already removes a trailing CR as
  #       an incidental side effect, since a carriage return is itself classified as [:space:],
  #       and that fixture's line-ending CR is at the very end of the line, already covered by
  #       cfg_trim's existing whitespace strip -- a genuine measured finding (defense in depth,
  #       not a coverage gap), not an assumption. push-deny-config-crlf-interior IS flipped: its
  #       CR sits in the MIDDLE of the refspec value ("HEAD:ma<CR>in"), a position cfg_trim's
  #       leading/trailing-only strip never reaches, so removing cfg_cr's own strip leaves the CR
  #       in the parsed destination, which then fails the exact is_deny_member compare -- this is
  #       the fixture that makes M35 non-inert. #269 RE-POINTED (shared resolve_repo()) and
  #       RE-MEASURED against the then-current 96-case push-* set: -> 95 pass, 1 fail — unchanged
  #       failing set (push-deny-config-crlf-interior only); no #269 fixture's config carries a CR.
  #       RE-MEASURED again for the #269 round-2 kickback against the CURRENT 98-case push-* set:
  #       -> 97 pass, 1 fail — unchanged failing set, +2 pass; neither new fixture's config
  #       carries a CR either.
  #   M36 the config path changed from "$common/config" to "$gitdir/config"               -> 79 pass,
  #                                                                                          1 fail
  #       (kills only push-deny-config-worktree-commondir -- the worktree pointer's own gitdir
  #       has no config file at all, so [ -f ] fails and config is silently never read; every
  #       non-worktree fixture has $gitdir == $common already, so this mutant is inert for them.
  #       #269 RE-POINTED (shared resolve_repo()) and RE-MEASURED against the then-current 96-case
  #       push-* set: -> 95 pass, 1 fail — unchanged failing set; every #269 "-C" target fixture is
  #       an ordinary checkout, not a worktree, so $gitdir == $common for all of them too.
  #       RE-MEASURED again for the #269 round-2 kickback against the CURRENT 98-case push-* set:
  #       -> 97 pass, 1 fail — unchanged failing set, +2 pass; C2/D1's checkouts are likewise
  #       ordinary, not worktrees)
  #   M37 the last-line-without-a-trailing-newline read rescue removed (while             -> 79 pass,
  #       IFS= read -r cfgline || [ -n "$cfgline" ] -> while IFS= read -r cfgline)          1 fail
  #       (kills only push-deny-config-no-trailing-newline -- its one and only config line, which
  #       has no trailing newline, is silently dropped by `read`'s own EOF behaviour. #269
  #       RE-POINTED (shared resolve_repo()) and RE-MEASURED against the then-current 96-case
  #       push-* set: -> 95 pass, 1 fail — unchanged failing set; every #269 fixture's config,
  #       where one is written at all, ends in a trailing newline. RE-MEASURED again for the #269
  #       round-2 kickback against the CURRENT 98-case push-* set: -> 97 pass, 1 fail — unchanged
  #       failing set, +2 pass; D1's config (the only new fixture with one) also ends in a
  #       trailing newline)
  #   M38 the [remote "<name>"] section-header pattern narrowed to lowercase-only         -> 79 pass,
  #       ([Rr][Ee][Mm][Oo][Tt][Ee] -> remote)                                              1 fail
  #       (kills only push-deny-config-mixed-case -- "[Remote ...]" no longer matches the section
  #       pattern at all and falls through to the catch-all "other" section, so its "Push = ..."
  #       key is never captured. #269 RE-POINTED (shared resolve_repo()) and RE-MEASURED against
  #       the then-current 96-case push-* set: -> 95 pass, 1 fail — unchanged failing set; no #269
  #       fixture's config uses mixed-case section/key names. RE-MEASURED again for the #269
  #       round-2 kickback against the CURRENT 98-case push-* set: -> 97 pass, 1 fail — unchanged
  #       failing set, +2 pass; neither new fixture's config uses mixed-case section/key names
  #       either)
  #   M39 the n<=1 gate removed (config_deny is also called after the n>=2 refspec        -> 79 pass,
  #       loop, using nonopt[0] as scope)                                                   1 fail
  #       (kills only push-noop-config-explicit-refspec -- the harness's own
  #       `git push -u origin "claude/17-a"` shape wrongly denies via the fixture's
  #       remote.origin.push=HEAD:main config; a release-blocker regression if this ever shipped)
  #   M40 a matched remote.<name>.push record denies unconditionally, regardless          -> 78 pass,
  #       of its resolved destination (the is_deny_member "$dest" compare after the         2 fail
  #       wildcard check is removed)
  #       (kills push-noop-config-remote-push-other-dest, whose configured refspec resolves to a
  #       non-default destination, and push-noop-config-commented-out, whose one REAL harmless
  #       key -- "push = feature/x" -- is a genuine, correctly-parsed remote.origin.push record
  #       that must NOT deny on its own; this is the mutant that actually exercises
  #       push-noop-config-commented-out's parsing, not M34 above)
  #   M41 the n==1 config route removed ([ -n "$__deny_dest" ] || config_deny             -> 79 pass,
  #       "$scope_remote" -> ... || [ "$n" -eq 1 ] || config_deny "$scope_remote")          1 fail
  #       (kills only push-deny-config-remote-push-named-remote -- the n==1 positive control for
  #       exact-remote scoping)
  #   M42 the push.default case statement disabled entirely (case "$cfg_push_default"     -> 77 pass,
  #       in -> case "" in)                                                                 3 fail
  #       (kills push-deny-config-push-default-upstream, push-deny-config-push-default-tracking,
  #       and push-deny-config-push-default-matching -- the only three deny fixtures whose config
  #       carries no remote.<name>.push record at all, so denying depends entirely on this case
  #       statement)
  # #268 round-2 kickback mutants (M43-M44), measured against the then-current 83-case push-* set
  # (the 80-case baseline plus push-deny-config-no-space-assign, push-deny-config-union-benign-
  # refspec-plus-upstream, and push-deny-config-crlf-interior):
  #   M43 the *=*) split guard narrowed to require spaces around the "="              -> 82 pass,
  #       (*=*) -> *" = "*))                                                             1 fail
  #       (kills only push-deny-config-no-space-assign -- a "key=value" record with no
  #       surrounding spaces no longer matches the split guard at all and falls through to the
  #       "continue" arm, so the key/value pair is silently never parsed. #269 RE-POINTED (shared
  #       resolve_repo()) and RE-MEASURED against the then-current 96-case push-* set: -> 95 pass,
  #       1 fail — unchanged failing set; no #269 fixture's config omits the spaces around "=".
  #       RE-MEASURED again for the #269 round-2 kickback against the CURRENT 98-case push-* set:
  #       -> 97 pass, 1 fail — unchanged failing set, +2 pass; D1's config also keeps the spaces
  #       around "=")
  #   M44 the push.default case gated on git's OWN precedence instead of the RESOLVED           -> 82 pass,
  #       union (case "$cfg_push_default" in -> if [ -z "$cfg_push_lines" ]; then case            1 fail
  #       "$cfg_push_default" in ... esac; fi)
  #       (kills only push-deny-config-union-benign-refspec-plus-upstream -- its
  #       remote.origin.push record resolves to a NON-denying destination (feature/x), so
  #       $cfg_push_lines is non-empty and this mutant's precedence gate skips the push.default
  #       resolution entirely, even though push.default=upstream alone denies; every other
  #       push-default-* deny fixture has NO remote.<name>.push record at all, so $cfg_push_lines
  #       is empty for them and this mutant is inert)
  # #268 round-3 kickback mutant (M45), measured against the then-current 84-case push-* set (the
  # 83-case baseline plus one more fixture, push-deny-config-union-other-remote-bare; grown to the
  # CURRENT 98 by #269 below and its own round-2 kickback):
  #   M45 the n==1/n==0 scope gate narrowed from "every configured remote at n==0"       -> 83 pass,
  #       to "git's own default remote" (if [ -n "$scope" ] && [ "$sub" != "$scope" ];      1 fail
  #       then -> if [ "$sub" != "${scope:-origin}" ]; then)
  #       (kills only push-deny-config-union-other-remote-bare -- its config carries a denying
  #       remote.<name>.push record ONLY under a non-origin remote name ("backup"), plus a benign
  #       origin section with no push key at all; the shipped scope gate considers every remote's
  #       records at n==0 and denies, while this mutant narrows the n==0 scope to only the
  #       "origin" record, whose absence leaves nothing to deny on -- every other config deny
  #       fixture names "origin" as its offending remote, so this mutant is inert for them)
  # #269's "-C <path>" resolution mutants (M46-M55), FIRST measured against the then-current
  # 96-case push-* set (the 84-case #268-round-3 baseline plus the twelve new #269 fixtures
  # directly below); each RE-MEASURED again for the #269 round-2 kickback against the CURRENT
  # 98-case push-* set (the 96-case baseline plus C2 and D1, added by that kickback — see M56/M57
  # below):
  #   M46 apply_c_target()'s entire body replaced with ":" (the "-C" route never applies         -> 89 pass,
  #       anything, regardless of predicate or resolution)                                        7 fail
  #       (kills push-deny-c-sibling-wt-bare-on-default, push-deny-c-other-repo-explicit-develop,
  #       push-deny-c-sibling-wt-head-refspec, push-deny-c-other-repo-config-route,
  #       push-noop-c-other-repo-ignores-session-config, push-noop-c-sibling-wt-session-on-default,
  #       and push-deny-c-never-executes -- every fixture whose verdict actually depends on the
  #       "-C" target resolving to something; the four fixtures that never resolve in the first
  #       place (B1-B4) and the one whose deny is already fully explained by the session's own
  #       facts alone (B6) are unaffected. RE-MEASURED for the round-2 kickback: -> 91 pass,
  #       7 fail — unchanged failing set, +2 pass; neither C2 nor D1 depends on the "-C" target
  #       actually resolving to something -- C2 never resolves at all (B4's shape) and D1's own
  #       deny comes from its SECOND, "-C"-less segment)
  #   M47 the tokenizer's emitted "-C" field forced empty unconditionally (print "PUSH\t"         -> 89 pass,
  #       (ccount == 1 ? cpath : "") "\t" rest -> print "PUSH\t" "" "\t" rest)                     7 fail
  #       (kills the IDENTICAL seven-case set as M46 -- a different code site, the awk tokenizer
  #       rather than the bash resolution function, with the same observable effect: apply_c_target()
  #       never receives a real value to resolve. RE-MEASURED for the round-2 kickback: -> 91 pass,
  #       7 fail — unchanged failing set, +2 pass, same reason as M46 above)
  #   M48 the is_c_target_path() predicate call removed from apply_c_target() (every non-empty    -> 95 pass,
  #       "-C" value is resolved, regardless of shape)                                            1 fail
  #       (kills only push-noop-c-nonsibling-path -- its "../other-checkout" value has no
  #       "-wt-<n>" suffix at all and would otherwise never be resolved; every other fixture's
  #       "-C" value either already satisfies the predicate or is never emitted as a candidate.
  #       RE-MEASURED for the round-2 kickback: -> 97 pass, 1 fail — unchanged failing set, +2 pass)
  #   M49 the tokenizer's "-C" match widened to also capture the ATTACHED "-C<path>" form (a      -> 95 pass,
  #       new branch inserted before the gopt_set check: substr(tok,1,2)=="-C" && tok!="-C")       1 fail
  #       (kills only push-noop-c-attached-form. RE-MEASURED for the round-2 kickback: -> 97 pass,
  #       1 fail — unchanged failing set, +2 pass)
  #   M50 the tokenizer's exactly-one-"-C" guard widened to "one or more" (ccount == 1 ->         -> 95 pass,
  #       ccount >= 1 in the emitted-field ternary -- the LAST "-C" token's value wins, since       1 fail
  #       cpath is overwritten on each "-C" occurrence)
  #       (kills only push-noop-c-double-c. RE-MEASURED for the round-2 kickback: -> 97 pass,
  #       1 fail — unchanged failing set, +2 pass)
  #   M51 the resolved current branch not applied (current_branch="$resolved_current" ->          -> 93 pass,
  #       current_branch="$session_current_branch")                                                3 fail
  #       (kills push-deny-c-sibling-wt-bare-on-default (the n<=1 current-branch check reads the
  #       SESSION's claude/17-a instead of the resolved worktree's own develop), push-deny-c-
  #       sibling-wt-head-refspec (the same substitution feeding refspec_dest()'s HEAD case), and
  #       push-noop-c-sibling-wt-session-on-default (the session's own main, which IS its own
  #       default, wrongly denies instead of the worktree's non-default claude/17-a); does NOT
  #       kill push-deny-c-other-repo-explicit-develop or push-deny-c-never-executes, whose denial
  #       comes from an EXPLICIT refspec destination, never current_branch. RE-MEASURED for the
  #       round-2 kickback: -> 95 pass, 3 fail — unchanged failing set, +2 pass; C2 never reaches
  #       this mutated line at all (its "-C" target never resolves a gitdir, so apply_c_target()
  #       returns before reaching it) and D1's own deny doesn't depend on current_branch either)
  #   M52 an unresolvable "-C" target clears the session's facts instead of degrading             -> 95 pass,
  #       ([ -n "$gitdir" ] || { apply_session_repo; return 0; } -> [ -n "$gitdir" ] || return 0)   1 fail
  #       (kills only push-deny-c-unresolvable-degrades -- resolve_repo()'s own internal reset
  #       already blanks current_branch/cfg_* unconditionally before this check runs, so skipping
  #       the restore silently drops the SESSION's own current branch, a bare push's only
  #       remaining deny route, for a target that was never actually resolved; deny_set itself is
  #       untouched by this mutant either way, so a fixture depending on an EXPLICIT refspec
  #       destination rather than current_branch cannot discriminate it -- why this fixture is a
  #       bare push, not push origin <branch>. RE-MEASURED for the round-2 kickback: -> 96 pass,
  #       2 fail — GAINS push-deny-c-unresolvable-never-executes (C2), the #269 round-2 kickback's
  #       own B4-shaped fixture: C2 shares this exact mechanism, a bare push whose only deny route
  #       is the SESSION's own current_branch after a failed "-C" resolution, so this pre-existing
  #       mutant discriminates it identically to B4, with no code having moved for this addition)
  #   M53 the deny-set union narrowed to fallback ∪ resolved only (the session's own default       -> 95 pass,
  #       branch line dropped from the union)                                                      1 fail
  #       (kills only push-deny-c-session-default-union -- the fixture whose deny is explained
  #       SOLELY by the session's own default branch staying in the union; every other deny
  #       fixture's session default either equals the resolved default already (A1/A3/B4) or is
  #       not what explains the deny at all (A2/A4/C1, decided by the RESOLVED default or config).
  #       RE-MEASURED for the round-2 kickback: -> 97 pass, 1 fail — unchanged failing set, +2
  #       pass; C2 never reaches this mutated line (its "-C" target never resolves) and D1's deny
  #       comes from its config-driven second segment, not this union)
  #   M54 the resolved config not applied (the three cfg_push_lines/cfg_push_default/             -> 94 pass,
  #       cfg_branch_merge assignments re-pointed at the session_* copies instead of the            2 fail
  #       resolved_* locals)
  #       (kills push-deny-c-other-repo-config-route and push-noop-c-other-repo-ignores-session-
  #       config -- the only two fixtures whose verdict is decided by which checkout's config
  #       applies. RE-MEASURED for the round-2 kickback: -> 96 pass, 2 fail — unchanged failing
  #       set, +2 pass; neither C2 (no config at all) nor D1's second segment (cpath empty, an
  #       early return well before this mutated line) reaches this code)
  #   M55 the resolved default branch omitted from the deny-set union (the                        -> 94 pass,
  #       "[ -n "$resolved_default" ] && deny_set=..." line deleted)                                2 fail
  #       (kills push-deny-c-other-repo-explicit-develop and push-deny-c-never-executes -- the two
  #       fixtures whose deny depends on the RESOLVED checkout's own default branch, "develop",
  #       entering the union; A1/A3/B4's resolved default already equals the session's own, so
  #       dropping it changes nothing for them. RE-MEASURED for the round-2 kickback: -> 96 pass,
  #       2 fail — unchanged failing set, +2 pass; C2 never resolves a default at all and D1's
  #       first segment never denies regardless of this union, see M46 above)
  # #269 round-2 kickback mutants (M56-M57), measured against the CURRENT 98-case push-* set (the
  # 96-case #269 baseline plus push-deny-c-unresolvable-never-executes (C2) and
  # push-deny-c-per-segment-session-reset (D1), the two fixtures this kickback adds):
  #   M56 apply_session_repo() hoisted from inside the driver loop (called once, per segment) to   -> 97 pass,
  #       immediately before the loop (called once, before ANY segment) -- verifier finding: the      1 fail
  #       per-segment reset (acceptance criterion 4, "no leakage between iterations") had no
  #       fixture with more than one push segment
  #       (kills only push-deny-c-per-segment-session-reset (D1) -- its SECOND segment (a bare
  #       "git push", no "-C") must be judged by the SESSION's own config, restored by a FRESH
  #       apply_session_repo() call for that segment; under this mutant, that call never happens
  #       again after the first segment's own "-C" target resolution left current_branch/cfg_*
  #       pointed at the FIRST segment's resolved (config-less) target, so the second segment's
  #       real deny -- via the session's own remote.origin.push=HEAD:main -- is silently lost (rc
  #       2 -> rc 0). No other fixture in this suite has more than one push segment, so D1 is the
  #       only case that can discriminate this mutant)
  #   M57 resolve_repo()'s depth-1 ascent guard deleted (the                                       -> 97 pass,
  #       "[ "$((depth + 1))" -lt "$2" ] || break" line removed) -- Note from the #269 round-1        1 fail
  #       verifier: this guard is what keeps the untrusted "-C" path from ever reaching dirname's
  #       argv, and it had no fixture pinning it at all
  #       (kills only push-deny-c-unresolvable-never-executes (C2) -- its "-C" target does not
  #       exist, so resolve_repo() falls through both the "[ -d ... ]" and "[ -f ... ]" checks to
  #       this guard; with the guard intact (MAX_DEPTH=1, depth=0), the loop breaks before ever
  #       calling dirname; with it deleted, dirname IS invoked (measured: C2's booby-trapped
  #       sentinel fires). Does NOT flip C1 (push-deny-c-never-executes), whose "-C" target DOES
  #       exist and resolves a gitdir at depth 0, so C1 never reaches this guard at all regardless
  #       of the mutation -- measured directly: C1 stays sentinel-absent/rc-2 both with the guard
  #       intact and with it deleted. Nor does this mutant change C2's own VERDICT (rc 2 either
  #       way, since the degrade-to-session-facts path is unaffected) -- it pins the SAFETY
  #       property (never reaches an argv), not the verdict, the same division of labor B4/C1
  #       already have for the "-C" route generally)
  # Nine fixtures (measured against the #260 56-case baseline) are, verified by direct measurement,
  # NOT flipped by any of M1-M22: their
  # destination never coincides with a deny-set member under any of these mutants (the two
  # release-blocker positive controls this harness itself issues, an ordinary feature/release/tag
  # branch, a fixture repo whose current branch is a non-default claude/<n>-<slug> branch, a
  # detached HEAD, cwd resolving to no repo at all, and the malformed-JSON control, whose failure
  # mode is jq's own parse error regardless of which downstream check runs); their comment below
  # says so instead of citing a mutant that was never observed to fail them. push-noop-crlf-feature
  # (#270) is a TENTH no-opinion fixture, measured only against M23-M25 (it did not exist when
  # M1-M22 were run): under each of those three mutants the destination stays a non-deny-set value
  # ("feature/x<CR>" under M23, "feature/x" under M24/M25), so "no opinion" is the verdict either
  # way. push-noop-config-neither-key (#268) is an ELEVENTH no-opinion fixture never flipped by
  # any mutant in this table, measured against M26-M45 (the #268 round-2 kickback's M43/M44 and
  # the round-3 kickback's M45 included -- none of the three appeared in its governing mutant's
  # one-case failing set, measured directly): its config sets neither remote.<name>.push nor
  # push.default at all, so every one of those twenty mutants changes behaviour only inside code
  # this fixture's own config never reaches; its row states this instead of citing a mutant that
  # was never observed to fail it.
  "push-deny-origin-main|case_pd_origin_main|deny: git push origin main (the plain form) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-head-colon-main|case_pd_head_colon_main|deny: git push origin HEAD:main (HEAD substituted via the current branch, then the dest side of the colon read directly) -- measured: M1/M2, 23 pass 33 fail (also M11, 50 pass 6 fail)"
  "push-deny-plus-head-refs-main|case_pd_plus_head_refs|deny: git push origin +HEAD:refs/heads/main (leading + stripped, refs/heads/ prefix stripped) -- measured: M1/M2, 23 pass 33 fail (also M11 and M13, each 50/54 pass)"
  "push-deny-nonorigin-remote|case_pd_nonorigin_remote|deny: git push upstream HEAD:main (remote other than origin is never itself evaluated as a destination) -- measured: M1/M2, 23 pass 33 fail (also M11, 50 pass 6 fail)"
  "push-deny-url-remote-colon|case_pd_url_remote_colon|deny: git push git@github.com:o/r.git HEAD:main (a URL remote containing a colon is skipped as tokens[0], never evaluated as a destination) -- measured: M1/M2, 23 pass 33 fail (also M11, 50 pass 6 fail)"
  "push-deny-refspec-full|case_pd_refspec_full|deny: git push origin refs/heads/x:refs/heads/main (full src:dst refspec, dst read after the FIRST colon) -- measured: M1/M2, 23 pass 33 fail (also M11 and M13, each 50/54 pass)"
  "push-deny-colon-main|case_pd_colon_main|deny: git push origin :main (empty source, dest read after the colon) -- measured: M1/M2, 23 pass 33 fail (also M11, 50 pass 6 fail)"
  "push-deny-delete-main|case_pd_delete_main|deny: git push origin --delete main (--delete is skipped as an ordinary dashed option) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-opt-before-remote|case_pd_opt_before_remote|deny: git push --force origin main (option BEFORE the remote) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-opt-after-refspec|case_pd_opt_after_refspec|deny: git push origin main --force (option AFTER the refspec) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-o-one|case_pd_o_one|deny: git push -o ci.skip origin main (ONE -o value occurrence, skipped as a pair) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-o-two|case_pd_o_two|deny: git push -o a -o b origin main (TWO -o value occurrences, the 0/1/2+ boundary -- LESSON 2026-09-08d) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-all|case_pd_all|deny: git push --all origin (unconditional -- pushes every ref, including the default branch) -- measured: M1/M2, 23 pass 33 fail (also M8, 54 pass 2 fail)"
  "push-deny-mirror|case_pd_mirror|deny: git push --mirror origin (unconditional, same reason as --all) -- measured: M1/M2, 23 pass 33 fail (also M8, 54 pass 2 fail)"
  "push-deny-c-worktree|case_pd_c_worktree|deny: git -C ../demo-wt-1 push origin main (the exact form hooks/git-c-guard.sh's own allow cases approve -- composition with that hook's allow was NOT re-measured, see hooks/hooks.json's .description) -- measured: M1/M2, 23 pass 33 fail (also M6, 53 pass 3 fail)"
  "push-deny-composite-and|case_pd_composite_and|deny: pytest && git push origin main (second && segment) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-prefix-one|case_pd_prefix_one|deny: env git push origin main (ONE PREFIX_WORDS token) -- measured: M1/M2, 23 pass 33 fail (also M5, 54 pass 2 fail)"
  "push-deny-prefix-two|case_pd_prefix_two|deny: sudo bash -c \"git push origin main\" (TWO chained PREFIX_WORDS tokens -- the M23 class) -- measured: M1/M2, 23 pass 33 fail (also M5, 54 pass 2 fail; also M7, 55 pass 1 fail)"
  "push-deny-assignment|case_pd_assignment|deny: FOO=1 git push origin main (assignment-prefix skip) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-abs-path|case_pd_abs_path|deny: /usr/bin/git push origin main (basename normalisation) -- measured: M1/M2, 23 pass 33 fail (also M21, 55 pass 1 fail)"
  "push-deny-global-opt-value|case_pd_global_opt_value|deny: git -c core.pager=cat push origin main (ONE git global option with a separate value before the subcommand) -- measured: M1/M2, 23 pass 33 fail (also M6, 53 pass 3 fail)"
  "push-deny-global-opt-two|case_pd_global_opt_two|deny: git -c core.pager=cat -C ../demo-wt-1 push origin main (TWO chained global-option-with-value pairs, the 0/1/2+ boundary -- LESSON 2026-09-08d) -- measured: M1/M2, 23 pass 33 fail (also M6, 53 pass 3 fail)"
  "push-deny-origin-master|case_pd_origin_master|deny: git push origin master (the second PUSH_DEFAULT_BRANCH_FALLBACK member) -- measured: M1/M2, 23 pass 33 fail (also M16, 55 pass 1 fail)"
  "push-deny-n1-refspec|case_pd_n1_refspec|deny: git push main against a fixture repo whose current branch is feature/x (n==1 -- the single argument is ALSO evaluated as a refspec destination, isolated from a real, non-denying current branch) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-crlf-dest|case_pd_crlf_dest|deny: git push origin main<CR> (#270, the exact command the issue measured -- isolates the destination compare, which goes through strip_quotes()+is_deny_member, not normalize()) -- measured: M23, 57 pass 3 fail (with push-deny-crlf-interior and push-deny-crlf-cmdword); NOT flipped by M24 or M25 (its one CR is both the first and the last, so either a trailing-only or a once-only strip removes it too)"
  "push-deny-crlf-interior|case_pd_crlf_interior|deny: echo a<CR> && git push origin main<CR> && echo b<CR> (#270, three CRs, the verdict-bearing one (second) neither first nor last -- distinguishes a global strip from both a trailing-only AND a once-only strip) -- measured: M23, 57 pass 3 fail (with push-deny-crlf-dest and push-deny-crlf-cmdword); M24 (trailing-only), 58 pass 2 fail (with push-deny-crlf-cmdword); M25 (once-only), 59 pass 1 fail (this case alone)"
  "push-deny-crlf-cmdword|case_pd_crlf_cmdword|deny: git<CR> push origin main (#270, isolates normalize() on the command word -- the site the issue's filed shape names, and which alone would not fix the issue's own measured command) -- measured: M23, 57 pass 3 fail (with push-deny-crlf-dest and push-deny-crlf-interior); also M24 (trailing-only), 58 pass 2 fail (with push-deny-crlf-interior) -- its one CR is not the command's final byte, so a trailing-only strip leaves it in place; NOT flipped by M25 (its one CR is also the only/first one, so a once-only strip removes it too)"
  "push-deny-trunk-base|case_pd_trunk_base|deny: git push origin trunk against a fixture repo whose refs/remotes/origin/HEAD symref names trunk (default-branch resolution, base cwd) -- measured: M1/M2, 23 pass 33 fail (also M15, 53 pass 3 fail)"
  "push-deny-trunk-subdir|case_pd_trunk_subdir|deny: same trunk fixture repo, cwd a SUBDIRECTORY of it (the upward .git walk) -- measured: M1/M2, 23 pass 33 fail (also M15, 53 pass 3 fail; also M18, 55 pass 1 fail)"
  "push-deny-trunk-worktree|case_pd_trunk_worktree|deny: same trunk default branch, cwd a WORKTREE POINTER FILE (gitdir: ... resolution, common-dir derivation) -- measured: M1/M2, 23 pass 33 fail (also M15, 53 pass 3 fail; also M17, 55 pass 1 fail)"
  "push-deny-head-on-main|case_pd_head_on_main|deny: git push origin HEAD against a fixture repo whose HEAD is main (current-branch resolution, HEAD substitution) -- measured: M1/M2, 23 pass 33 fail (also M12, 55 pass 1 fail; also M14, 54 pass 2 fail)"
  "push-deny-bare-on-main|case_pd_bare_on_main|deny: bare git push against the same HEAD-is-main fixture repo (n==0, destination is the current branch) -- measured: M1/M2, 23 pass 33 fail (also M14, 54 pass 2 fail)"
  "push-deny-no-cwd-fallback|case_pd_no_cwd_fallback|deny: git push origin main with NO cwd key at all in stdin (must still deny via the unconditional fallback) -- measured: M1/M2, 23 pass 33 fail"
  "push-deny-plus-main-no-colon|case_pd_plus_main_no_colon|deny: git push origin +main (colon-LESS forced refspec -- isolates the leading-+ strip from the colon-split) -- measured: M1/M2, 23 pass 33 fail (also M10, 55 pass 1 fail)"
  "push-noop-upstream-claude|case_pn_push_upstream_claude|no opinion: git push -u origin \"claude/17-a\" (the exact shape skills/issue-implementer/SKILL.md:527 issues -- a deny here is a release blocker) -- measured: not flipped by M1-M22 (destination \"claude/17-a\" never coincides with a deny-set member under any of these mutants)"
  "push-noop-c-upstream-claude|case_pn_c_push_upstream_claude|no opinion: git -C ../demo-wt-1 push -u origin \"claude/17-a\" (the exact shape worktree-mode.md:201 issues -- a deny here is a release blocker) -- measured: not flipped by M1-M22, same reason as push-noop-upstream-claude"
  "push-noop-release-branch|case_pn_release_branch|no opinion: git push origin release/v2.7.1 (this repo's own release-ritual branch shape) -- measured: not flipped by M1-M22 (destination never coincides with a deny-set member under any of these mutants)"
  "push-noop-tag-shaped-version|case_pn_tag_shaped_version|no opinion: git push origin v2.7.0 (a tag-shaped destination, not the default branch) -- measured: not flipped by M1-M22, same reason as push-noop-release-branch"
  "push-noop-feature-branch|case_pn_feature_branch|no opinion: git push origin feature/x (an ordinary feature branch) -- measured: not flipped by M1-M22, same reason as push-noop-release-branch"
  "push-noop-main-ish|case_pn_main_ish|no opinion: git push origin main-ish (exact match required, not a prefix match) -- measured: M19, 55 pass 1 fail"
  "push-noop-refs-tags|case_pn_refs_tags|no opinion: git push origin refs/tags/v1.0 (a tag ref is skipped, never a branch destination) -- measured: M20, 56 pass 0 fail (NOT flipped -- see the table header note on M20)"
  "push-noop-head-on-claude|case_pn_head_on_claude|no opinion: git push origin HEAD against a fixture repo whose HEAD is claude/17-a (current branch resolves, but isn't in the deny set) -- measured: not flipped by M1-M22 (the resolved destination \"claude/17-a\" never coincides with a deny-set member under any of these mutants, including M12/M14's HEAD-substitution mutants, which only affect the SEPARATE push-deny-head-on-main fixture's fixture repo)"
  "push-noop-bare-on-claude|case_pn_bare_on_claude|no opinion: bare git push against the same claude/17-a fixture repo -- measured: not flipped by M1-M22, same reason as push-noop-head-on-claude"
  "push-noop-bare-detached|case_pn_bare_detached|no opinion: bare git push against a fixture repo with a DETACHED HEAD (current branch unresolvable -- a documented limit, not denied) -- measured: not flipped by M1-M22 (current_branch is already empty by construction here, so M14's force-empty mutant changes nothing observable)"
  "push-noop-trunk-no-repo|case_pn_trunk_no_repo|no opinion: git push origin trunk with cwd resolving to NO repo at all (the 64-level upward walk finds nothing; falls back to the fallback set alone, which trunk isn't in) -- measured: not flipped by M1-M22 (no .git is ever found here, so M15/M17/M18's resolution mutants change nothing observable)"
  "push-noop-grep-arg|case_pn_grep_arg|no opinion: grep -rn \"git push origin main\" . (git/push as grep's own argument, never a command word) -- measured: not flipped by M1-M22 (the command-word AND subcommand checks both independently require an exact \"git\"/\"push\" resolution; no single-clause mutant here defeats both layers at once)"
  "push-noop-bash-script|case_pn_bash_script|no opinion: bash hooks/push-guard.sh # not a git push (basename contains, but isn't, \"git\"; the trailing comment supplies the raw-stdin \"git\" literal so this case actually reaches the tokenizer) -- measured: not flipped by M1-M22, including M21 (removing the basename step here still leaves the FULL path \"hooks/push-guard.sh\", not \"git\") and M5/M7 (PREFIX_WORDS emptied or made once-only still leaves the resolved command word as \"bash\" or \"push-guard.sh\", neither \"git\")"
  "push-noop-plan-mode|case_pr_plan_mode|role-agnostic no opinion: git push origin main under permission_mode: \"plan\" -- measured: M4, 55 pass 1 fail"
  "push-noop-wrong-tool|case_pr_wrong_tool|role-agnostic no opinion: tool_name is \"Read\", not \"Bash\" -- measured: M3, 55 pass 1 fail"
  "push-noop-malformed-json|case_pr_malformed_json|role-agnostic no opinion: unparseable stdin (carries both push and git substrings) -- measured: not flipped by M1-M22, including M3/M4 (jq's own parse failure independently yields empty extractions regardless of which downstream check runs)"
  "push-noop-missing-command|case_pr_missing_command|role-agnostic no opinion: tool_input.command absent -- measured: M22, 55 pass 1 fail"
  "push-never-executes-deny|case_push_never_executes_deny|deny, AND push-guard.sh never invokes git/gh/rm on the booby-trapped PATH — sentinel absent -- measured: M1/M2, 23 pass 33 fail"
  "push-never-executes-noop|case_push_never_executes_noop|no opinion, AND push-guard.sh never invokes git/gh/rm on the booby-trapped PATH — sentinel absent -- measured: not flipped by M1-M22 (its command's destination, feature/x, never coincides with a deny-set member under any of these mutants)"
  "push-never-executes-reads-only|case_push_reads_only|deny, AND a fixture repo's recursive file listing is byte-identical before/after — this hook reads the filesystem but never writes to it -- measured: M1/M2, 23 pass 33 fail"
  "push-noop-o-value-two-token-remote|case_pn_o_value_two_token_remote|no opinion: git push -o v main other (isolates PUSH_OPTS_WITH_VALUE's two-token skip: main lands as the never-evaluated remote, not a refspec) -- measured: M9, 55 pass 1 fail"
  "push-noop-crlf-feature|case_pn_crlf_feature|no opinion: git push origin feature/x<CR> (#270 -- the strip does not widen the deny set; exact match still required) -- measured: not flipped by M23, 57 pass 3 fail; also not flipped by M24, 58 pass 2 fail, or M25, 59 pass 1 fail (destination stays feature/x<CR> or feature/x under every one of these mutants, still not a deny-set member, so no opinion either way)"
  # --- #269: "git -C <path> push" resolution, gated on the shared PATH_ERE predicate -----------
  "push-deny-c-sibling-wt-bare-on-default|case_pd_c_sibling_wt_bare_on_default|deny: git -C ../<repo>-wt-1 push, session default develop/HEAD claude/17-a, sibling worktree ALSO on develop (A1 -- isolates the n<=1 current-branch check on the RESOLVED checkout) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M51, 93 pass 3 fail)"
  "push-deny-c-other-repo-explicit-develop|case_pd_c_other_repo_explicit_develop|deny: git -C ../other-checkout-wt-1 push origin develop, session default main/HEAD claude/17-a, a SEPARATE repo's own default is develop (A2, the issue's own headline shape) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M55, 94 pass 2 fail)"
  "push-deny-c-sibling-wt-head-refspec|case_pd_c_sibling_wt_head_refspec|deny: as A1 but push origin HEAD (A3 -- isolates refspec_dest()'s HEAD substitution on the RESOLVED checkout's current branch) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M51, 93 pass 3 fail)"
  "push-deny-c-other-repo-config-route|case_pd_c_other_repo_config_route|deny: git -C <abs>/target-wt-1 push (absolute-path form), target's config denies via remote.origin.push=HEAD:main, SESSION has no config at all (A4) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M54, 94 pass 2 fail)"
  "push-noop-c-other-repo-ignores-session-config|case_pn_c_other_repo_ignores_session_config|no opinion: git -C ../target-a5-wt-1 push, SESSION config denies via push=HEAD:main but the resolved segment must ignore it (A5, documented narrowing -- measured pre-#269: deny) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M54, 94 pass 2 fail)"
  "push-noop-c-nonsibling-path|case_pn_c_nonsibling_path|no opinion: git -C ../other-checkout push origin develop, no -wt-<n> suffix at all (B1, the predicate's path-shape boundary) -- measured: M48, 95 pass 1 fail"
  "push-noop-c-attached-form|case_pn_c_attached_form|no opinion: git -C../other-checkout-b2-wt-1 push origin develop, the ATTACHED -C<path> form (B2) -- measured: M49, 95 pass 1 fail"
  "push-noop-c-double-c|case_pn_c_double_c|no opinion: git -C ../benign-wt-1 -C ../other-checkout-b3-wt-1 push origin develop, TWO -C tokens (B3, the 0/1/2+ boundary -- LESSON 2026-09-08d) -- measured: M50, 95 pass 1 fail"
  "push-deny-c-unresolvable-degrades|case_pd_c_unresolvable_degrades|deny: git -C ../missing-wt-9 push (bare), path matches the shape but nothing exists there, session HEAD ON its own default (develop) -- degrades to the session's own facts, never clears them (B4, unchanged verdict) -- measured: M52, 95 pass 1 fail"
  "push-noop-c-sibling-wt-session-on-default|case_pn_c_sibling_wt_session_on_default|no opinion: git -C ../repo-c-b5-wt-1 push, session ITSELF on its own default (main), sibling worktree on claude/17-a (B5, documented narrowing, worktree-parallel mode's real shape -- measured pre-#269: deny) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M51, 93 pass 3 fail)"
  "push-deny-c-session-default-union|case_pd_c_session_default_union|deny: git -C ../target-b6-wt-1 push origin develop, session default develop, target's OWN default is trunk (B6 -- measured pre-#269: ALREADY denies via the session's own deny set alone; this fixture's value is as the M53 discriminator, not a Today-vs-After widening) -- measured: M53, 95 pass 1 fail"
  "push-deny-c-never-executes|case_pd_c_never_executes|deny via the -C resolution route, AND push-guard.sh never invokes git/gh/rm/dirname on the booby-trapped PATH, AND BOTH the session repo's and the resolved -C target's file listings are byte-identical before/after (C1, A2's shape; \"dirname\" added to the trap in the #269 round-2 kickback, harmless here since this fixture's -C target resolves at depth 0 -- see M57 below and C2) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M55, 94 pass 2 fail); NOT flipped by M57 (measured: 97 pass 1 fail against the CURRENT 98-case set -- this fixture's -C target resolves at depth 0 and never reaches the ascent guard M57 removes; see C2 below, which does)"
  "push-deny-c-unresolvable-never-executes|case_pd_c_unresolvable_never_executes|deny (degrades to the session's own facts, B4's shape) via the -C resolution route, AND push-guard.sh never invokes git/gh/rm/dirname on the booby-trapped PATH (C2, #269 round-2 kickback -- pins the depth-1 ascent guard resolve_repo() would otherwise call dirname past, unlike C1 whose target resolves at depth 0 and never reaches that code) -- measured: M57, 97 pass 1 fail (also M14, 89 pass 9 fail; M15, 88 pass 10 fail; M52, 96 pass 2 fail -- all four discriminate this fixture, mirroring B4's exact dependency on the session's own current_branch/default_branch after a failed -C resolution)"
  "push-deny-c-per-segment-session-reset|case_pd_c_per_segment_session_reset|deny: TWO push segments -- git -C ../other-d1-wt-1 push origin claude/99-z (resolves, no opinion on its own) && git push (bare, no -C) -- the SECOND segment must be judged by the SESSION's own config (push=HEAD:main), not by whatever the first segment's -C target left behind (D1, #269 round-2 kickback -- acceptance criterion 4's per-segment reset had no multi-segment fixture) -- measured: M56, 97 pass 1 fail (also M26, 80 pass 18 fail -- the SAME session-config mechanism push-deny-config-remote-push-bare uses, see M26's own table entry)"
  "push-deny-config-remote-push-bare|case_pd_config_remote_push_bare|deny: git push against a repo whose config carries [remote \"origin\"] push = HEAD:main (#268, the issue's own shape) -- measured: M26, 68 pass 12 fail"
  "push-deny-config-remote-push-named-remote|case_pd_config_remote_push_named_remote|deny: git push origin against the same config (n==1, the positive side of the exact-remote-scoping clause) -- measured: M26, 68 pass 12 fail (also M41, 79 pass 1 fail)"
  "push-deny-config-remote-push-second-line|case_pd_config_remote_push_second_line|deny: two push = lines under [remote \"origin\"], only the SECOND offending (0/1/2+ boundary) -- measured: M26, 68 pass 12 fail (also M33, 79 pass 1 fail)"
  "push-deny-config-no-space-assign|case_pd_config_no_space_assign|deny: push=HEAD:main with NO surrounding spaces (#268 kickback finding 1 -- the *=*) split guard must accept this form) -- measured: M43, 82 pass 1 fail"
  "push-deny-config-push-default-upstream|case_pd_config_push_default_upstream|deny: [push] default = upstream + [branch \"feature/x\"] merge = refs/heads/main -- measured: M26, 68 pass 12 fail (also M42, 77 pass 3 fail)"
  "push-deny-config-push-default-tracking|case_pd_config_push_default_tracking|deny: [push] default = tracking (git's documented synonym for upstream) -- measured: M26, 68 pass 12 fail (also M30, 79 pass 1 fail; also M42, 77 pass 3 fail)"
  "push-deny-config-push-default-matching|case_pd_config_push_default_matching|deny: [push] default = matching (Q2, unconditional, same reasoning as --all/--mirror) -- measured: M26, 68 pass 12 fail (also M29, 77 pass 3 fail, as a side effect; also M31, 79 pass 1 fail; also M42, 77 pass 3 fail)"
  "push-deny-config-union-benign-refspec-plus-upstream|case_pd_config_union_benign_refspec_plus_upstream|deny: [remote \"origin\"] push = HEAD:refs/heads/feature/x (a NON-denying refspec) alongside [push] default = upstream + [branch \"feature/x\"] merge = refs/heads/main (#268 kickback finding 2 -- the RESOLVED Q1 union, not git's own precedence) -- measured: M44, 82 pass 1 fail"
  "push-deny-config-union-other-remote-bare|case_pd_config_union_other_remote_bare|deny: bare git push against a config carrying ONLY [remote \"backup\"] push = HEAD:main plus a benign origin section with no push key (#268 kickback 2 finding -- RESOLVED Q1's CROSS-REMOTE union at n==0: every configured remote's push refspecs, not just git's own default-remote pick) -- measured: M45, 83 pass 1 fail"
  "push-deny-config-wildcard-refspec|case_pd_config_wildcard_refspec|deny: [remote \"origin\"] push = refs/heads/*:refs/heads/* (Q3, unconditional wildcard destination) -- measured: M26, 68 pass 12 fail (also M32, 79 pass 1 fail)"
  "push-deny-config-crlf-line|case_pd_config_crlf_line|deny: the config FILE carries CRLF line endings (#270's class, in the new config reader) -- measured: M26, 68 pass 12 fail; NOT flipped by M35 (re-measured, #268 kickback finding 3), 82 pass 1 fail -- only push-deny-config-crlf-interior fails (its line-ending CR is already stripped by cfg_trim's own [[:space:]] handling -- a genuine measured finding, not a coverage gap)"
  "push-deny-config-crlf-interior|case_pd_config_crlf_interior|deny: an INTERIOR CR inside the refspec value itself, HEAD:ma<CR>in (#268 kickback finding 3 -- distinct from push-deny-config-crlf-line's line-ending CR, and the fixture that makes M35 non-inert) -- measured: M35, 82 pass 1 fail"
  "push-deny-config-worktree-commondir|case_pd_config_worktree_commondir|deny: config lives in the MAIN checkout's .git/config, cwd is the worktree POINTER dir (the common-dir derivation, not \$gitdir) -- measured: M26, 68 pass 12 fail (also M36, 79 pass 1 fail)"
  "push-deny-config-no-trailing-newline|case_pd_config_no_trailing_newline|deny: the config file's last (only) line has no trailing newline (the read rescue) -- measured: M26, 68 pass 12 fail (also M37, 79 pass 1 fail)"
  "push-deny-config-mixed-case|case_pd_config_mixed_case|deny: [Remote \"origin\"] / Push = HEAD:main (Q4, case-insensitive section keyword and key name) -- measured: M26, 68 pass 12 fail (also M38, 79 pass 1 fail)"
  "push-deny-config-never-executes|case_pd_config_never_executes|deny via the CONFIG route, AND push-guard.sh never invokes git/gh/rm on the booby-trapped PATH, AND the fixture repo's file listing is byte-identical before/after -- measured: M26, 68 pass 12 fail"
  "push-noop-config-neither-key|case_pn_config_neither_key|no opinion: config sets NEITHER remote.<name>.push nor push.default at all (the decision's required control) -- measured: not flipped by M26-M45 (this fixture's config never reaches any of the twenty mutated clauses)"
  "push-noop-config-remote-push-other-dest|case_pn_config_remote_push_other_dest|no opinion: [remote \"origin\"] push = HEAD:refs/heads/feature/x (a configured refspec whose destination is not the default branch) -- measured: M40, 78 pass 2 fail (with push-noop-config-commented-out)"
  "push-noop-config-other-remote-named|case_pn_config_other_remote_named|no opinion: [remote \"origin\"] push = HEAD:main, command git push backup (n==1 exact remote scoping -- a DIFFERENT remote's own push route must not apply) -- measured: M27, 79 pass 1 fail"
  "push-noop-config-explicit-refspec|case_pn_config_explicit_refspec|no opinion: git push -u origin \"claude/17-a\" against a repo whose config carries push = HEAD:main (n>=2 -- config routes are NEVER consulted here; a deny would be a release blocker) -- measured: M39, 79 pass 1 fail"
  "push-noop-config-branch-other|case_pn_config_branch_other|no opinion: push.default=upstream but [branch \"other\"] merge=refs/heads/main -- current branch (feature/x) has no section of its own -- measured: M28, 79 pass 1 fail"
  "push-noop-config-commented-out|case_pn_config_commented_out|no opinion: a #-commented push line, a ;-commented push.default line, and odd leading whitespace on the one real harmless key -- measured: M40, 78 pass 2 fail (with push-noop-config-remote-push-other-dest); NOT flipped by M34, 80 pass 0 fail (the comment strip's absence is masked by exact-key matching -- see M34's own table entry)"
  "push-noop-config-push-default-current|case_pn_config_push_default_current|no opinion: [push] default = current + a branch section that WOULD deny if this mode were mistaken for upstream (the sharp form of the mode-check clause) -- measured: M29, 77 pass 3 fail (with push-noop-config-push-default-simple)"
  "push-noop-config-push-default-simple|case_pn_config_push_default_simple|no opinion: [push] default = simple, git's own default mode, same branch-section trap as push-default-current -- measured: M29, 77 pass 3 fail (with push-noop-config-push-default-current)"
)

matched=0
for row in "${cases[@]}"; do
  name="${row%%|*}"
  case "$name" in
    *"$filter"*) : ;;
    *) continue ;;
  esac
  matched=$((matched+1))
  rest="${row#*|}"
  fn="${rest%%|*}"
  desc="${rest#*|}"
  __ok=1; __why=""
  "$fn"
  if [ "$__ok" -eq 1 ]; then
    case_ok "$name" "$desc"
  else
    case_bad "$name" "$desc"
    printf '%b' "$__why" | sed 's/^/    /'
  fi
done

if [ "$matched" -eq 0 ]; then
  echo "no case name contains '$filter'"
  exit 1
fi

echo
echo "== summary: $pass pass, $fail fail =="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
