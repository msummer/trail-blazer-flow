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
# the strip does not widen the deny set.
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
  # (whole-file convention — bash dev/hook-tests.sh with no filter) against the CURRENT 143-case
  # file (agent-boundary's own addition now 52 cases; push-guard's own addition now 56 cases — a
  # DIFFERENT, larger figure, 60, is the `push`-name-filtered measurement unit the push mutation
  # table below uses: the 56 push-section rows below plus four rows from the OTHER two sections
  # whose names happen to contain the substring "push" (push-upstream, impl-deny-push-bare,
  # impl-deny-push-ns, impl-deny-git-c-push) — M1-M23's own numbers were NOT
  # re-measured against that 143-case total: the 82/84-case figures above predate #260's
  # push-guard section entirely (it did not exist yet when M1-M22 were measured, and held 52
  # cases, not 56, immediately before #270 added four CRLF fixtures to it). M25 (below) was also
  # added by the #270 round-2 kickback, probing this file for the same trailing-vs-once-only gap
  # the push table's M24/M25 close for hooks/push-guard.sh — see M25's own entry for why no
  # fixture here closes it (a boundary interior-CR fixture is not added: not required unless
  # judged necessary to make a table sentence true, and none currently claims that coverage).
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
  #       (whole-file convention, measured against the CURRENT 143-case file — the three new
  #       #270 boundary CRLF fixtures, impl-deny-crlf-cmdword/verif-deny-crlf-gh/
  #       verif-noop-crlf-status, are the only cases that flip)
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
  # the next mutation. M1-M22 were NOT re-run for #270 — only M23-M25 (below) are measured against
  # the CURRENT 60-case push-* set (the #260 56-case baseline plus the four new #270 CRLF
  # fixtures).
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
  #   M15 default_branch resolution forced empty                         -> 53 pass,  3 fail
  #   M16 PUSH_DEFAULT_BRANCH_FALLBACK emptied                            -> 55 pass,  1 fail
  #   M17 the worktree common-dir derivation broken (never strips        -> 55 pass,  1 fail
  #       /worktrees/* from gitdir)
  #   M18 the upward .git walk disabled (dir="$parent" -> dir="$dir",     -> 55 pass,  1 fail
  #       so it never leaves the starting directory)
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
  #       (measured against the CURRENT 60-case push-* set — the three new #270 push-deny-crlf-*
  #       fixtures are the only cases that flip; push-noop-crlf-feature is NOT flipped, see below.
  #       Re-measured after the #270 round-2 kickback rewrote push-deny-crlf-interior's raw
  #       command from two CRs to three — the figures and failing set are unchanged from the
  #       original two-CR fixture)
  #   M24 the shipped global strip narrowed to trailing-only                -> 58 pass,  2 fail
  #       (cmd="${cmd//$cr/}" -> cmd="${cmd%$cr}"; #270 round-2 kickback, added because M23 alone
  #       cannot distinguish "strips every \r" from "strips only a trailing \r" — measured against
  #       the CURRENT 60-case push-* set: kills push-deny-crlf-interior and push-deny-crlf-cmdword,
  #       neither of whose verdict-bearing CR is the command's final byte; does NOT kill
  #       push-deny-crlf-dest, whose single CR IS the final byte)
  #   M25 the shipped global strip narrowed to once-only                    -> 59 pass,  1 fail
  #       (cmd="${cmd//$cr/}" -> cmd="${cmd/$cr/}"; #270 round-2 kickback finding — the original
  #       two-CR push-deny-crlf-interior fixture's verdict-bearing CR happened to be its FIRST, so
  #       this mutant survived the whole 60-case set undetected until the fixture was rewritten to
  #       a three-CR command whose verdict-bearing CR is the SECOND, not the first — measured
  #       against the CURRENT 60-case push-* set: kills only push-deny-crlf-interior; does NOT
  #       kill push-deny-crlf-dest or push-deny-crlf-cmdword, each of whose single CR IS the first
  #       (and only) one)
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
  # way.
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
  "push-noop-c-upstream-claude|case_pn_c_push_upstream_claude|no opinion: git -C ../demo-wt-1 push -u origin \"claude/17-a\" (the exact shape worktree-mode.md:189 issues -- a deny here is a release blocker) -- measured: not flipped by M1-M22, same reason as push-noop-upstream-claude"
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
