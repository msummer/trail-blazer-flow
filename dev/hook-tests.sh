#!/usr/bin/env bash
#
# hook-tests.sh — fixture-based negative-test harness for the two plugin-shipped PreToolUse
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
# role-agnostic no opinion, and the same booby-trapped `git`/`rm` idiom proving the boundary
# never executes anything either.
#
# Usage: bash dev/hook-tests.sh [name-filter] — same output contract as dev/selfcheck-tests.sh
# and dev/doctor-tests.sh: one PASS/FAIL line per case, a `== summary: N pass, M fail ==`
# footer, exit 0 iff nothing failed; a filter with no match exits 1.
#
# Every write happens under one `mktemp -d` root, removed via an EXIT trap; this repo's own
# hooks/git-c-guard.sh and hooks/agent-boundary.sh are read-only here — each script is run
# directly, never copied or edited.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"
guard="$root/hooks/git-c-guard.sh"
boundary="$root/hooks/agent-boundary.sh"

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
# permission_mode are all documented PreToolUse hook input fields (see the plan's Verified facts
# and the probe record); this harness never invents an undocumented field.

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
# verbatim; see LESSON 2026-09-06): implementer deny (15), implementer no opinion (5), verifier
# no opinion (6), verifier deny (13), role-agnostic no opinion (8), never-executes (2) = 49
# total. Both agent_type spellings ("implementer"/"trail-blazer-flow:implementer",
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
  # (dev/hook-tests.sh's case_push_upstream above) — this hook must deny it regardless of
  # composition with that other hook (see hooks/agent-boundary.sh's header on the unverified
  # hook-vs-hook precedence).
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
  # against the round-1 47-case/82-total addition; M23 (below) was added by the round-2 kickback
  # that fixed hooks/agent-boundary.sh:167's chained-PREFIX_WORDS bug and was measured against
  # the current 49-case/84-total addition — M1-M22's own numbers were NOT re-measured against
  # the 84-total baseline (LESSON 2026-09-06 asks only for bookkeeping, i.e. count words, to be
  # reconciled after the last case is added; re-running 22 already-verified mutants is out of
  # scope for this fix). M1/M2 (the two raw-stdin fast paths) are coarse — breaking either
  # silences the WHOLE hook, so they only distinguish a deny-verdict case from everything else,
  # never one deny case from another:
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
  #       in a segment is skipped instead of every one — measured against the current 49-case/
  #       84-total addition (the two new chained-prefix fixtures are the only cases that flip)
  # Six fixtures (impl-noop-npm-test/pytest/selfcheck, role-noop-no-agent-type,
  # role-noop-agent-id-only, and role-noop-malformed-json) are, verified by direct measurement,
  # NOT flipped by any of M1-M23: their raw JSON never contains the literal substring their
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
  "impl-noop-npm-test|case_in_npm_test|implementer no opinion: npm test -- measured: not flipped by M1-M23 (no git/gh substring anywhere in the raw stdin -- fast path 2 alone already excludes it; see the table header note above)"
  "impl-noop-pytest|case_in_pytest|implementer no opinion: pytest -q -- measured: not flipped by M1-M23 (same as impl-noop-npm-test)"
  "impl-noop-selfcheck|case_in_selfcheck|implementer no opinion: bash dev/selfcheck.sh -- measured: not flipped by M1-M23 (same as impl-noop-npm-test)"
  "impl-noop-grep-arg|case_in_grep_arg|implementer no opinion: grep -rn \"git push\" . (git as argument, not command word) -- measured: M21, 81 pass 1 fail"
  "impl-noop-git-c-guard-script|case_in_git_c_guard_script|implementer no opinion: bash hooks/git-c-guard.sh (basename contains, but isn't, \"git\") -- measured: M20, 81 pass 1 fail"
  "verif-noop-diff|case_vn_diff|verifier no opinion: git diff <default>...HEAD --stat -- measured: M13c, 81 pass 1 fail"
  "verif-noop-log|case_vn_log|verifier no opinion: git log <default>..HEAD --format=%s -- measured: M13, 80 pass 2 fail (with verif-noop-c-log)"
  "verif-noop-status|case_vn_status|verifier no opinion: git status --porcelain -- measured: M13b, 80 pass 2 fail (with boundary-never-executes-noop)"
  "verif-noop-restore|case_vn_restore|verifier no opinion: git restore <file> -- measured: M13d, 81 pass 1 fail"
  "verif-noop-c-log|case_vn_c_log|verifier no opinion: git -C <worktree> log <default>..HEAD --format=%s -- measured: M11, 81 pass 1 fail (also M13, 80 pass 2 fail, with verif-noop-log)"
  "verif-noop-show-ns|case_vn_show_ns|verifier no opinion: git show HEAD (agent_type: trail-blazer-flow:verifier) -- measured: M13e, 81 pass 1 fail"
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
  "role-noop-no-agent-type|case_ra_no_agent_type_key|role-agnostic no opinion: no agent_type key at all (main session), git push -- measured: not flipped by M1-M23 (no 'agent_type' substring anywhere in the raw stdin -- fast path 1 alone already excludes it, and independently the jq .agent_type extraction below would also come back empty; see the table header note above)"
  "role-noop-explore|case_ra_explore|role-agnostic no opinion: agent_type is \"Explore\" (unrecognised role) -- measured: M15 ([ -n \"\$role\" ] || exit 0 removed), 80 pass 2 fail (with role-noop-empty-agent-type)"
  "role-noop-empty-agent-type|case_ra_empty_agent_type|role-agnostic no opinion: agent_type is the empty string -- measured: M15, 80 pass 2 fail (with role-noop-explore)"
  "role-noop-agent-id-only|case_ra_agent_id_only|role-agnostic no opinion: agent_id present, no agent_type key -- measured: not flipped by M1-M23 (same reason as role-noop-no-agent-type -- 'agent_id' does not contain the substring 'agent_type')"
  "role-noop-plan-mode|case_ra_plan_mode|role-agnostic no opinion: implementer git push under permission_mode: \"plan\" -- measured: M6, 81 pass 1 fail"
  "role-noop-wrong-tool|case_ra_wrong_tool|role-agnostic no opinion: tool_name is \"Read\", not \"Bash\" -- measured: M3, 81 pass 1 fail"
  "role-noop-malformed-json|case_ra_malformed_json|role-agnostic no opinion: unparseable stdin (carries both agent_type and git substrings) -- measured: not flipped by M1-M23, including M3 (jq's own parse failure independently yields an empty .tool_name/.agent_type extraction regardless of which downstream check runs)"
  "role-noop-missing-command|case_ra_missing_command|role-agnostic no opinion: tool_input.command absent -- measured: M18, 81 pass 1 fail"
  "boundary-never-executes-deny|case_boundary_never_executes_deny|deny, AND the boundary never invokes git/gh/rm on the booby-trapped PATH — sentinel absent -- measured: M1/M2, 55 pass 27 fail"
  "boundary-never-executes-noop|case_boundary_never_executes_noop|no opinion, AND the boundary never invokes git/gh/rm on the booby-trapped PATH — sentinel absent -- measured: M13b, 80 pass 2 fail (with verif-noop-status)"
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
