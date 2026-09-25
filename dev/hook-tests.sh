#!/usr/bin/env bash
#
# hook-tests.sh — fixture-based negative-test harness for the four plugin-shipped PreToolUse
# hooks, in the style of dev/doctor-tests.sh: feeds fixture stdin JSON straight into the real
# script and pins its verdict.
#
# Per-PR history of what this harness pins: CHANGELOG.md (archive, #363). Each hook's own header
# and each case's own comment state its mechanism.
#
# Usage: bash dev/hook-tests.sh [name-filter] — same output contract as dev/selfcheck-tests.sh
# and dev/doctor-tests.sh: one PASS/FAIL line per case, a `== summary: N pass, M fail ==`
# footer, exit 0 iff nothing failed; a filter with no match exits 1.
#
# Every write happens under one `mktemp -d` root, removed via an EXIT trap; this repo's own
# hooks/git-c-guard.sh, hooks/agent-boundary.sh, hooks/push-guard.sh, and hooks/claude-dir-guard.sh
# are read-only here — each script is run directly, never copied or edited (push-guard.sh's own
# fixture-repo builder below writes ONLY under that same mktemp root, never inside this checkout).
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"
guard="$root/hooks/git-c-guard.sh"
boundary="$root/hooks/agent-boundary.sh"
push_guard="$root/hooks/push-guard.sh"
claude_dir_guard="$root/hooks/claude-dir-guard.sh"

tmpbase="$(mktemp -d)"
cleanup() {
  if [ -n "$tmpbase" ] && [ -d "$tmpbase" ]; then
    rm -rf "$tmpbase"
  fi
}
trap cleanup EXIT

# #290: a neutral, empty HOME for every push-guard fixture (see run_push_guard below) — created
# once, up front, so hooks/push-guard.sh's new $HOME/$XDG_CONFIG_HOME/$GIT_CONFIG_GLOBAL reads
# never see the developer's or CI runner's real global git config.
neutral_home="$tmpbase/neutral-home"
mkdir -p "$neutral_home"

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
# expect_ab_deny_claude (#340) — the .claude-write deny class's own assertion: rc 2, empty stdout,
# exactly one non-blank stderr line, containing BOTH the DENY_STEM literal (hand-typed here, same
# convention as expect_deny above) and the fixed "a path under a .claude segment" phrase
# hooks/agent-boundary.sh's role-policy printf emits for this deny kind specifically (distinguishing
# it from a git/gh deny, which expect_deny alone cannot). Both literals are hand-typed inline, not
# extracted from the script, so no needle parameter and no needle_required guard is needed.
expect_ab_deny_claude() {
  [ "$boundary_rc" -eq 2 ] || { __ok=0; __why="${__why}rc: expected 2, got $boundary_rc\n"; }
  [ -z "$boundary_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$boundary_out'\n"; }
  local err_lines
  err_lines="$(printf '%s\n' "$boundary_err" | grep -c '[^[:space:]]')"
  [ "$err_lines" -eq 1 ] || { __ok=0; __why="${__why}expected exactly 1 non-blank stderr line, got $err_lines: '$boundary_err'\n"; }
  case "$boundary_err" in
    *"trail-blazer-flow agent boundary:"*"a path under a .claude segment"*) ;;
    *) __ok=0; __why="${__why}stderr does not contain both the DENY_STEM literal and 'a path under a .claude segment': '$boundary_err'\n" ;;
  esac
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

# --- hooks/agent-boundary.sh: the #340 `.claude` Bash-write deny class -----------------------
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter
# "ab-claude-"), re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table.
# mutant:340-fastpath — deletes the widened fast path 2's `*[Cc]…[Ee]*` alternative, so every
#   deny fixture below whose raw stdin carries no "git"/"gh" substring exits silently before ever
#   reaching the scan.
# mutant:340-fastpath-case — narrows that same alternative to the literal `*claude*` (no case
#   fold), isolating ab-claude-deny-case-variant's `.Claude` spelling as the one fixture that
#   depends on the fast path's OWN case-insensitivity (the scan's tolower() still runs regardless).
# mutant:340-redirect-pass — disables the redirect pass's own `print`, so a bare `>`/`>>` target
#   carrying a `.claude` segment is never emitted, even though the scan still runs.
# mutant:340-arg-vocab — empties CLAUDE_PATH_ARG_COMMANDS, so `tee`/`cp`/`cd` writing into
#   `.claude` via a plain argument (not a redirect) is never checked.
# mutant:340-sed-short — makes the `^-[A-Za-z]*i` in-place-flag regex unmatchable, isolating the
#   short `sed -i`/`-i.bak` spelling from the long `--in-place` one.
# mutant:340-sed-long — makes the `--in-place` regex unmatchable, the long-spelling mirror of
#   340-sed-short.
# mutant:340-segment-exact — widens has_claude_seg()'s `index("/" u "/", "/.claude/")` exact-
#   segment check to a bare substring test, so `.claude-backup` would start matching too.
# mutant:340-tolower — removes has_claude_seg()'s `tolower()`, so a case-variant segment like
#   `.Claude` no longer matches.
# mutant:340-backslash — removes has_claude_seg()'s backslash-to-slash `gsub`, so a
#   backslash-separated path never normalises to a `.claude` segment.
# mutant:340-input-redirect — widens the redirect pass's `>` to `[<>]`, so an input redirect
#   (`wc -l < .claude/LESSONS.md`) starts wrongly denying.
# mutant:340-quote-strip-dq — turns has_claude_seg()'s double-quote strip into a no-op, so a double
#   quote directly adjacent to the segment (`".claude/…`) hides it.
# mutant:340-quote-strip-sq — the single-quote mirror of 340-quote-strip-dq (`'.claude/…`).
# mutant:340-sed-combined — narrows the short in-place regex to a bare `-i`, so a combined flag
#   cluster such as `-Ei` is no longer recognised as in-place.
# mutant:340-arg-gate — applies the vocabulary walk to every command word, not only tee/cp/mv/cd/
#   pushd, so reading a `.claude` path with `cat` starts wrongly denying.
# mutant:340-inplace-gate — applies the sed `.claude` walk without an in-place flag, so a read-only
#   `sed -n` on a `.claude` path starts wrongly denying.
# mutant:340-policy-arm — makes the role-policy loop's `"-claude-write- "*)` arm unmatchable, so
#   a `-claude-write-` line the scan emits is never turned into a deny at all.
case_ab_claude_deny_append_redirect() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' "printf '%s\n' '- 2026-09-24: always do X' >> .claude/LESSONS.md")"
  expect_ab_deny_claude
}
case_ab_claude_deny_redirect_nospace_quoted() {
  run_boundary "$(mk_agent_cmd 'verifier' 'echo x >"/Users/x/proj/.claude/LESSONS.md"')"
  expect_ab_deny_claude
}
case_ab_claude_deny_heredoc() {
  run_boundary "$(mk_agent_cmd 'implementer' "cat >> /repo/.claude/LESSONS.md <<'EOF'${LF}- lesson${LF}EOF")"
  expect_ab_deny_claude
}
case_ab_claude_deny_case_variant() {
  run_boundary "$(mk_agent_cmd 'implementer' 'echo x >> .Claude/LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_claude_deny_backslash() {
  run_boundary "$(mk_agent_cmd 'implementer' "echo x >> 'C:\\repo\\.claude\\LESSONS.md'")"
  expect_ab_deny_claude
}
case_ab_claude_deny_tee() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:verifier' 'cat notes.txt | tee -a .claude/LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_claude_deny_cp() {
  run_boundary "$(mk_agent_cmd 'implementer' 'cp /tmp/lesson.md .claude/LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_claude_deny_cd() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' 'cd .claude && cat /tmp/l >> LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_claude_deny_sed_short() {
  run_boundary "$(mk_agent_cmd 'implementer' "sed -i.bak '\$a x' .claude/LESSONS.md")"
  expect_ab_deny_claude
}
case_ab_claude_deny_sed_long() {
  run_boundary "$(mk_agent_cmd 'verifier' "sed --in-place '\$a x' .claude/LESSONS.md")"
  expect_ab_deny_claude
}
case_ab_claude_deny_quoted_double() {
  run_boundary "$(mk_agent_cmd 'implementer' 'echo x >> ".claude/LESSONS.md"')"
  expect_ab_deny_claude
}
case_ab_claude_deny_quoted_single() {
  run_boundary "$(mk_agent_cmd 'verifier' "cat notes.txt | tee -a '.claude/LESSONS.md'")"
  expect_ab_deny_claude
}
case_ab_claude_deny_sed_combined() {
  run_boundary "$(mk_agent_cmd 'implementer' "sed -Ei 's/a/b/' .claude/LESSONS.md")"
  expect_ab_deny_claude
}
case_ab_claude_deny_never_writes() {
  local trapdir="$tmpbase/trapbin-ab-claude-never-writes" sentinel="$tmpbase/sentinel-ab-claude-never-writes"
  local target_dir="$tmpbase/ab-claude-tree/.claude"
  local target_file="$target_dir/LESSONS.md"
  mkdir -p "$trapdir" "$target_dir"
  rm -f "$sentinel"
  for bin in git gh rm; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  # Run from inside the fixture tree with a RELATIVE target: the scanned command text then carries no
  # random mktemp characters, which could otherwise contain "gh" and defeat the 340-fastpath mutant.
  local oldpwd="$PWD"
  cd "$tmpbase/ab-claude-tree" || { __ok=0; __why="${__why}cannot cd into the fixture tree\n"; return; }
  run_boundary "$(mk_agent_cmd 'implementer' 'echo x >> .claude/LESSONS.md')" "$trapdir:$PATH"
  cd "$oldpwd" || { __ok=0; __why="${__why}cannot cd back to $oldpwd\n"; return; }
  expect_ab_deny_claude
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — the boundary invoked something on the booby-trapped PATH\n"; }
  [ ! -e "$target_file" ] || { __ok=0; __why="${__why}target file present — the boundary performed the redirect it was scanning\n"; }
}
case_ab_claude_noop_input_redirect() {
  run_boundary "$(mk_agent_cmd 'implementer' 'wc -l < .claude/LESSONS.md')"
  expect_no_opinion
}
case_ab_claude_noop_tee_elsewhere() {
  run_boundary "$(mk_agent_cmd 'implementer' 'cat .claude/LESSONS.md | tee /tmp/out.txt')"
  expect_no_opinion
}
case_ab_claude_noop_sed_no_inplace() {
  run_boundary "$(mk_agent_cmd 'verifier' "sed -n '1,5p' .claude/LESSONS.md")"
  expect_no_opinion
}
case_ab_claude_noop_near_miss() {
  run_boundary "$(mk_agent_cmd 'implementer' 'echo x >> .claude-backup/notes.md')"
  expect_no_opinion
}
case_ab_claude_noop_main_session() {
  run_boundary "$(mk_plain_cmd 'echo x >> .claude/LESSONS.md')"
  expect_no_opinion
}

# --- hooks/agent-boundary.sh: the #387 .claude command-level interpreter/writer class -----------
# Mutation proof lives in dev/mutants/hook-tests.json (suite dev/hook-tests.sh, filter
# "ab-cwrite-"), re-run by dev/mutant-driver.sh — the #359 registry idiom, not a prose table.
# mutant:387-vocab-empty — empties CLAUDE_CMDLINE_WRITE_COMMANDS, so no command word is ever a
#   member and the command-level rule never fires at all.
# mutant:387-version-strip — makes the trailing-version-suffix strip a no-op, isolating a versioned
#   command word (e.g. python3.12) from an unversioned one.
# mutant:387-cross-line — resets cw_word/cw_tok at the start of every record instead of letting them
#   accumulate across the whole tool_input.command, isolating the heredoc-fed case whose command
#   word and .claude mention are on different lines.
# mutant:387-word-gate — drops the END block's cw_word != "" condition, so a .claude mention alone
#   (with no vocabulary command word anywhere) starts wrongly denying.
# mutant:387-tok-gate — drops the END block's cw_tok != "" condition, so a vocabulary command word
#   alone (with no .claude mention anywhere) starts wrongly denying.
# mutant:387-boundary-lead — widens claude_seg_in_text()'s LEADING boundary class to match any
#   character, so a near-miss segment like "my.claude" starts wrongly matching.
# mutant:387-boundary-trail — widens claude_seg_in_text()'s TRAILING boundary class to match any
#   character, so a near-miss segment like ".claude-plugin" starts wrongly matching.
# mutant:387-tolower — removes claude_seg_in_text()'s tolower(), so a case-variant segment like
#   ".Claude" no longer matches.
case_ab_cwrite_deny_python_c() {
  run_boundary "$(mk_agent_cmd 'implementer' "python3 -c \"open('.claude/LESSONS.md','a').write('- lesson')\"")"
  expect_ab_deny_claude
}
case_ab_cwrite_deny_python_heredoc() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:implementer' "python3 - <<'EOF'${LF}open('.claude/LESSONS.md','a').write('- lesson')${LF}EOF")"
  expect_ab_deny_claude
}
case_ab_cwrite_deny_perl_i() {
  run_boundary "$(mk_agent_cmd 'verifier' "perl -i.bak -pe 's/a/b/' .claude/LESSONS.md")"
  expect_ab_deny_claude
}
case_ab_cwrite_deny_dd() {
  run_boundary "$(mk_agent_cmd 'implementer' 'dd if=/tmp/lesson.md of=.claude/LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_cwrite_deny_install() {
  run_boundary "$(mk_agent_cmd 'trail-blazer-flow:verifier' 'install -m 644 /tmp/lesson.md .claude/LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_cwrite_deny_versioned_abs() {
  run_boundary "$(mk_agent_cmd 'implementer' "/usr/local/bin/python3.12 -c \"open('.claude/LESSONS.md','a')\"")"
  expect_ab_deny_claude
}
case_ab_cwrite_deny_case_variant() {
  run_boundary "$(mk_agent_cmd 'implementer' 'install -m 644 /tmp/lesson.md .Claude/LESSONS.md')"
  expect_ab_deny_claude
}
case_ab_cwrite_deny_never_writes() {
  local trapdir="$tmpbase/trapbin-ab-cwrite-never-writes" sentinel="$tmpbase/sentinel-ab-cwrite-never-writes"
  local target_dir="$tmpbase/ab-cwrite-tree/.claude"
  local target_file="$target_dir/LESSONS.md"
  mkdir -p "$trapdir" "$target_dir"
  rm -f "$sentinel"
  for bin in git gh rm; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  # Run from inside the fixture tree with a RELATIVE target: the scanned command text then carries no
  # random mktemp characters, which could otherwise contain "gh" and defeat the 340-fastpath mutant.
  local oldpwd="$PWD"
  cd "$tmpbase/ab-cwrite-tree" || { __ok=0; __why="${__why}cannot cd into the fixture tree\n"; return; }
  run_boundary "$(mk_agent_cmd 'implementer' "python3 -c \"open('.claude/LESSONS.md','a').write('x')\"")" "$trapdir:$PATH"
  cd "$oldpwd" || { __ok=0; __why="${__why}cannot cd back to $oldpwd\n"; return; }
  expect_ab_deny_claude
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — the boundary invoked something on the booby-trapped PATH\n"; }
  [ ! -e "$target_file" ] || { __ok=0; __why="${__why}target file present — the boundary performed the write it was scanning\n"; }
}
case_ab_cwrite_noop_reader() {
  run_boundary "$(mk_agent_cmd 'implementer' 'npm install && grep -n lesson .claude/LESSONS.md && cat .claude/BASELINE.md')"
  expect_no_opinion
}
case_ab_cwrite_noop_no_claude_seg() {
  run_boundary "$(mk_agent_cmd 'implementer' 'python3 -m pytest tests/test_claude_client.py')"
  expect_no_opinion
}
case_ab_cwrite_noop_claude_plugin() {
  run_boundary "$(mk_agent_cmd 'verifier' "python3 -c \"import json; json.load(open('.claude-plugin/plugin.json'))\"")"
  expect_no_opinion
}
case_ab_cwrite_noop_my_claude() {
  run_boundary "$(mk_agent_cmd 'implementer' 'touch build/my.claude')"
  expect_no_opinion
}
case_ab_cwrite_noop_main_session() {
  run_boundary "$(mk_plain_cmd "python3 -c \"open('.claude/LESSONS.md','a').write('- lesson')\"")"
  expect_no_opinion
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

LF=$'\n'   # one literal line feed — the #327 round-1 kickback's embedded-LF claude-dir-guard.sh
           # fixtures below (jq --arg escapes it into the JSON as \n, so no raw LF byte ever passes
           # through command substitution).

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
# explicit cwd for this reason too. AMBIENT-$HOME ANALOGUE (#290): hooks/push-guard.sh now also
# reads $HOME/$XDG_CONFIG_HOME/$GIT_CONFIG_GLOBAL — run_push_guard below isolates all three for
# EVERY push fixture (a neutral, empty $HOME under $tmpbase by default), so no fixture in this
# file can ever read the developer's or CI runner's real global git config; a fixture that wants a
# GLOBAL route present sets $push_home_override/$push_xdg_home/$push_git_config_global immediately
# before calling run_push_guard instead (see mk_fixture_global_config below).
mk_fixture_config() {
  local dir="$1" body="$2"
  mkdir -p "$dir/.git"
  printf '%s' "$body" > "$dir/.git/config"
}

# mk_fixture_global_config PATH BODY (#290) — writes BODY to PATH, creating parent directories as
# needed, for a GLOBAL config candidate ($GIT_CONFIG_GLOBAL's own target, $HOME/.gitconfig, or
# $XDG_CONFIG_HOME/git/config) — the analogue of mk_fixture_config above for the global routes
# #290 added. Never writes anywhere but under PATH, which every caller places under $tmpbase.
mk_fixture_global_config() {
  local path="$1" body="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s' "$body" > "$path"
}

# run_push_guard JSON [PATHVAL] — runs the real push-guard script against JSON on stdin, with
# PATH set to PATHVAL (defaults to this process's own PATH), leaving $push_out (stdout)/
# $push_err (stderr, read back from a file under $tmpbase)/$push_rc set as globals. Same "call as
# a plain statement, read the globals after" idiom as run_boundary above.
#
# #290: hooks/push-guard.sh now reads $HOME/$XDG_CONFIG_HOME/$GIT_CONFIG_GLOBAL, so this runner
# ISOLATES all three for EVERY call: a neutral, empty fixture HOME under $tmpbase by default
# (never the developer's or CI runner's real one), with XDG_CONFIG_HOME and GIT_CONFIG_GLOBAL
# unset unless a fixture sets $push_home_override/$push_xdg_home/$push_git_config_global
# immediately before calling run_push_guard (all three cleared again right after the call, so a
# later fixture that asks for none of them never inherits a prior fixture's values). The
# environment mutation happens inside the "$(...)" command substitution's own implicit subshell —
# a portable, bash-3.2/Git-Bash-safe idiom (this file's own convention prefers it to `env -u`,
# which is not obviously safe across Git-Bash) — so it can never leak into this harness's own
# environment or any later call. run_hook and run_boundary above are deliberately UNCHANGED:
# neither hooks/git-c-guard.sh nor hooks/agent-boundary.sh reads any of these three variables.
push_out=""
push_err=""
push_rc=0
push_home_override=""
push_xdg_home=""
push_git_config_global=""
run_push_guard() {
  local json="$1" pathval="${2:-$PATH}" errfile="$tmpbase/push-guard-stderr"
  local home_val="${push_home_override:-$neutral_home}"
  push_out="$(
    unset XDG_CONFIG_HOME GIT_CONFIG_GLOBAL
    export HOME="$home_val"
    [ -z "$push_xdg_home" ] || export XDG_CONFIG_HOME="$push_xdg_home"
    [ -z "$push_git_config_global" ] || export GIT_CONFIG_GLOBAL="$push_git_config_global"
    printf '%s' "$json" | PATH="$pathval" "$bash_bin" "$push_guard" 2>"$errfile"
  )"
  push_rc=$?
  push_err="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
  push_home_override=""
  push_xdg_home=""
  push_git_config_global=""
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
case_pd_config_tab_in_value() {
  # #290 kickback finding F4: cfg_push_lines records are "src<TAB>sub<TAB>refspec" (source FIRST,
  # a bounded field; the configured value is the record's UNBOUNDED tail) so a "push =" value
  # containing a literal TAB byte cannot truncate at that TAB and leak its own remainder into
  # config_deny()'s source-label field. A wildcard destination denies regardless of what follows
  # the embedded TAB, so this fixture stays a DENY either way (pre-F4-fix or post) -- what this
  # case pins is whether $src stays exactly one of the two literal labels (measured pre-fix, with
  # the OLD "sub<TAB>val<TAB>src" record order: still denies, rc 2, but stderr names
  # "junklabel<TAB>.git/config" -- neither declared literal -- instead of ".git/config").
  local dir="$tmpbase/repo-cfg-tab-in-value"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[remote "origin"]\n\tpush = refs/heads/*:refs/heads/*\tjunklabel\n'
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
  # "junklabel" is the DENIED destination's own text too (the full, untruncated wildcard refspec
  # -- correct: git itself would treat the whole value as one refspec), so these assertions pin
  # the SOURCE-LABEL field specifically ("in <source>)", the printf format's own trailing clause),
  # never a plain substring test against the whole message.
  case "$push_err" in
    *"in .git/config)"*) ;;
    *) __ok=0; __why="${__why}stderr's source-label field is not exactly '.git/config': '$push_err'\n" ;;
  esac
  case "$push_err" in
    *"in junklabel"*) __ok=0; __why="${__why}stderr's source-label field is corrupted by the TAB-carrying value's own remainder: '$push_err'\n" ;;
    *) ;;
  esac
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

# --- #290: GLOBAL git config candidates ($GIT_CONFIG_GLOBAL, $XDG_CONFIG_HOME/git/config or its
# $HOME/.config/git/config default, $HOME/.gitconfig), unioned with the repo-local config #268
# already reads -- every fixture below passes an explicit cwd (mk_fixture_config's AMBIENT-$PWD
# rule) and sets $push_home_override (and, where noted, $push_xdg_home/$push_git_config_global)
# immediately before its own run_push_guard call, so its own global route is visible ONLY to that
# call -- run_push_guard clears all three right after every call, so no fixture below can leak its
# global config into a sibling fixture.
case_pd_global_gitconfig_upstream() {
  # Per-path coverage 1/4: $HOME/.gitconfig. Repo carries only a [branch] merge record (no
  # push.default of its own); the GLOBAL push.default=upstream is what denies. Also asserts
  # inline that stderr names the GLOBAL source label, not ".git/config".
  local dir="$tmpbase/repo-global-gitconfig-upstream" home="$tmpbase/home-global-gitconfig-upstream"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$home/.gitconfig" $'[push]\n\tdefault = upstream\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *"your global git config"*) ;;
    *) __ok=0; __why="${__why}stderr does not name the global source label 'your global git config': '$push_err'\n" ;;
  esac
}
case_pd_global_xdg_upstream() {
  # Per-path coverage 2/4: explicit $XDG_CONFIG_HOME/git/config, with a neutral (no-.gitconfig)
  # HOME override so the OTHER two global paths are absent for this fixture.
  local dir="$tmpbase/repo-global-xdg-upstream" home="$tmpbase/home-global-xdg-upstream"
  local xdg="$tmpbase/xdg-global-xdg-upstream"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$xdg/git/config" $'[push]\n\tdefault = upstream\n'
  push_home_override="$home"
  push_xdg_home="$xdg"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_xdg_home_default_upstream() {
  # Per-path coverage 3/4: $XDG_CONFIG_HOME UNSET -- pins the default-path branch,
  # $HOME/.config/git/config, distinct from case_pd_global_xdg_upstream's explicit-XDG branch.
  local dir="$tmpbase/repo-global-xdg-home-default-upstream"
  local home="$tmpbase/home-global-xdg-home-default-upstream"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$home/.config/git/config" $'[push]\n\tdefault = upstream\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_env_var_upstream() {
  # Per-path coverage 4/4: $GIT_CONFIG_GLOBAL pointing at a fixture file OUTSIDE HOME entirely --
  # the neutral HOME (no override) has no .gitconfig, so only the env-var route can deny here.
  local dir="$tmpbase/repo-global-env-var-upstream"
  local gcg="$tmpbase/gcg-global-env-var-upstream/customconfig"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$gcg" $'[push]\n\tdefault = upstream\n'
  push_git_config_global="$gcg"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_remote_push_refspec() {
  # Route coverage: remote.<name>.push via a GLOBAL file; the repo has NO config file at all.
  local dir="$tmpbase/repo-global-remote-push-refspec"
  local home="$tmpbase/home-global-remote-push-refspec"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$home/.gitconfig" $'[remote "origin"]\n\tpush = HEAD:main\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_default_matching() {
  # Route coverage: push.default=matching via a GLOBAL file, unconditional -- no [branch] section
  # anywhere (this route never consults branch.<n>.merge).
  local dir="$tmpbase/repo-global-default-matching"
  local home="$tmpbase/home-global-default-matching"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$home/.gitconfig" $'[push]\n\tdefault = matching\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_benign_does_not_mask_repo_route() {
  # Union/precedence: a benign GLOBAL push.default (current) must not mask a denying REPO
  # push.default (upstream) -- the mutation-discriminating case for "evaluate every value, not
  # just the first". Also asserts inline that stderr names the REPO source label, ".git/config".
  local dir="$tmpbase/repo-global-benign-mask" home="$tmpbase/home-global-benign-mask"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = upstream\n[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$home/.gitconfig" $'[push]\n\tdefault = current\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *".git/config"*) ;;
    *) __ok=0; __why="${__why}stderr does not name the repo-local source label '.git/config': '$push_err'\n" ;;
  esac
}
case_pd_global_overrides_benign_repo_route() {
  # Union/precedence, the other direction: a denying GLOBAL push.default (upstream) must still
  # deny even though the REPO's own push.default (current) is benign -- the documented over-block
  # (git itself would honour the repo's "current" and never consult the global value at all).
  local dir="$tmpbase/repo-global-overrides-benign" home="$tmpbase/home-global-overrides-benign"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[push]\n\tdefault = current\n[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$home/.gitconfig" $'[push]\n\tdefault = upstream\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_env_var_union_not_replace() {
  # Union-not-replace over-block: $GIT_CONFIG_GLOBAL is set to a BENIGN file, and $HOME/.gitconfig
  # (which real git would never consult once $GIT_CONFIG_GLOBAL is set) still supplies the deny --
  # also the "denier read LAST" half of the 2+ boundary, with the XDG candidate absent in between.
  local dir="$tmpbase/repo-global-union-not-replace" home="$tmpbase/home-global-union-not-replace"
  local gcg="$tmpbase/gcg-global-union-not-replace/customconfig"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$gcg" $'[core]\n\teditor = vi\n'
  mk_fixture_global_config "$home/.gitconfig" $'[remote "origin"]\n\tpush = HEAD:main\n'
  push_home_override="$home"
  push_git_config_global="$gcg"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_two_files_first_denies() {
  # The "denier read FIRST" half of the 2+ boundary: $GIT_CONFIG_GLOBAL (read first) denies,
  # $HOME/.gitconfig (read after it) is benign.
  local dir="$tmpbase/repo-global-two-files-first-denies"
  local home="$tmpbase/home-global-two-files-first-denies"
  local gcg="$tmpbase/gcg-global-two-files-first-denies/customconfig"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$gcg" $'[remote "origin"]\n\tpush = HEAD:main\n'
  mk_fixture_global_config "$home/.gitconfig" $'[core]\n\teditor = vi\n'
  push_home_override="$home"
  push_git_config_global="$gcg"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
}
case_pd_global_two_defaults_one_file() {
  # #290 kickback finding F1: TWO "[push] default = ..." lines inside ONE file (global here) are
  # BOTH accumulated by cfg_push_defaults' list and evaluated in file-order -- so the FIRST value
  # denies even though git itself (last-wins WITHIN one file -- this hook's own pre-#290 scalar
  # behaviour) resolves that file's own push.default to the SECOND, benign value and would not
  # deny. Repo carries only a [branch] merge record (no push.default of its own). Also asserts
  # inline that the deny is attributed to the FIRST ("upstream") record's own via/source, not the
  # second.
  local dir="$tmpbase/repo-global-two-defaults-one-file"
  local home="$tmpbase/home-global-two-defaults-one-file"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$home/.gitconfig" $'[push]\n\tdefault = upstream\n\tdefault = current\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_deny
  case "$push_err" in
    *"push.default=upstream in your global git config"*) ;;
    *) __ok=0; __why="${__why}stderr does not name push.default=upstream via the global source label: '$push_err'\n" ;;
  esac
}
case_pd_c_target_global_route() {
  # Cross-feature: a resolved "-C" segment sees the GLOBAL routes (read from the environment, the
  # same for every segment, never derived from the "-C" value itself) INDEPENDENTLY of the
  # session's own facts. The SESSION's own cwd resolves to NO repo at all (mkdir only, no
  # mk_fixture_repo call) -- RESOLVED decision: global routes are consulted only when a repo
  # actually resolves, so the SESSION's own resolve_repo() call never attempts the global-config
  # read at all here. This isolates that the deny comes SOLELY from the "-C" TARGET's own
  # resolution reading the same global files -- a session that itself also resolved a real repo
  # would independently pick up the identical global route and mask this discriminator (measured:
  # an earlier draft of this fixture, with the session resolving an ordinary repo, was NOT flipped
  # by apply_c_target()'s own body-replaced-with-":" mutant, M46, because the session's own
  # apply_session_repo() facts already carried the same deny).
  local main="$tmpbase/repo-c-g1" target="$tmpbase/target-g1-wt-1"
  local home="$tmpbase/home-c-g1"
  mkdir -p "$main"
  mk_fixture_repo "$target" trunk "feature/y"
  mk_fixture_global_config "$home/.gitconfig" $'[remote "origin"]\n\tpush = HEAD:main\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../target-g1-wt-1 push' "$main")"
  expect_push_deny
}
case_pd_global_never_executes() {
  # Safety: the never-executes/reads-only guarantee on the GLOBAL route specifically -- booby-traps
  # git/gh/rm/dirname and asserts byte-identical listings of BOTH the fixture repo AND the fixture
  # HOME tree (never just the repo, which the pre-existing never-executes cases already cover).
  local dir="$tmpbase/repo-global-never-executes" home="$tmpbase/home-global-never-executes"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_config "$dir" $'[branch "feature/x"]\n\tmerge = refs/heads/main\n'
  mk_fixture_global_config "$home/.gitconfig" $'[push]\n\tdefault = upstream\n'
  local trapdir="$tmpbase/trapbin-global-deny" sentinel="$tmpbase/sentinel-global-deny"
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
  local before_repo after_repo before_home after_home
  before_repo="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  before_home="$(find "$home" -type f -exec ls -la {} \; | sort)"
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")" "$trapdir:$PATH"
  after_repo="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  after_home="$(find "$home" -type f -exec ls -la {} \; | sort)"
  expect_push_deny
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — push-guard.sh invoked something on the booby-trapped PATH while evaluating a global config route\n"; }
  [ "$before_repo" = "$after_repo" ] || { __ok=0; __why="${__why}fixture repo's file listing changed — push-guard.sh wrote to or altered a file it should only read (global config route)\n"; }
  [ "$before_home" = "$after_home" ] || { __ok=0; __why="${__why}fixture HOME's file listing changed — push-guard.sh wrote to or altered a file it should only read (global config route)\n"; }
}
case_pn_global_upstream_no_tracking() {
  # Negative control / honest scope: global push.default=upstream, current branch claude/17-a, NO
  # [branch] section ANYWHERE -- refspec_dest() of an empty merge value resolves to no destination.
  local dir="$tmpbase/repo-global-upstream-no-tracking"
  local home="$tmpbase/home-global-upstream-no-tracking"
  mk_fixture_repo "$dir" main "claude/17-a"
  mk_fixture_global_config "$home/.gitconfig" $'[push]\n\tdefault = upstream\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push' "$dir")"
  expect_push_no_opinion
}
case_pn_global_explicit_refspec() {
  # Release-blocker control: the harness's OWN bare-C-less push -u origin "claude/<n>-<slug>"
  # shape against a GLOBAL config carrying BOTH a denying remote.origin.push AND
  # push.default=matching -- config is NEVER consulted for an explicit-refspec segment (n>=2),
  # global or repo-local.
  local dir="$tmpbase/repo-global-explicit-refspec"
  local home="$tmpbase/home-global-explicit-refspec"
  mk_fixture_repo "$dir" main feature/x
  mk_fixture_global_config "$home/.gitconfig" $'[remote "origin"]\n\tpush = HEAD:main\n[push]\n\tdefault = matching\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git push -u origin "claude/17-a"' "$dir")"
  expect_push_no_opinion
}
case_pn_global_explicit_refspec_c() {
  # Release-blocker control, the "-C" variant: the harness's OWN "-C <wt>"-prefixed explicit-
  # refspec push shape, against the SAME denying GLOBAL config as case_pn_global_explicit_refspec.
  local main="$tmpbase/repo-global-explicit-refspec-c" target="$tmpbase/target-g2-wt-1"
  local home="$tmpbase/home-global-explicit-refspec-c"
  mk_fixture_repo "$main" main feature/x
  mk_fixture_repo "$target" trunk feature/y
  mk_fixture_global_config "$home/.gitconfig" $'[remote "origin"]\n\tpush = HEAD:main\n[push]\n\tdefault = matching\n'
  push_home_override="$home"
  run_push_guard "$(mk_push_cmd_cwd 'git -C ../target-g2-wt-1 push -u origin "claude/17-a"' "$main")"
  expect_push_no_opinion
}
case_pn_global_none_present() {
  # The "none present" boundary AND the isolation positive control: a dedicated, empty fixture
  # HOME with no .gitconfig and no .config/git/config, XDG_CONFIG_HOME and GIT_CONFIG_GLOBAL both
  # unset, repo config absent -- must stay no opinion (proves this file's own isolation actually
  # works: without it, the developer's or CI runner's real global config could flip this).
  local dir="$tmpbase/repo-global-none-present" home="$tmpbase/home-global-none-present"
  mkdir -p "$home"
  mk_fixture_repo "$dir" main "claude/17-a"
  push_home_override="$home"
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
# hooks/claude-dir-guard.sh (#327) fixture builders, runner, and assertions. This hook has three
# verdicts — deny via the ".claude" segment class (exit 2, empty stdout, one stderr line naming
# the role, the tool, and the blocked path), deny via the unclassifiable/fail-closed class (exit
# 2, empty stdout, one stderr line with DISTINCT wording naming the path), or no opinion (exit 0,
# empty stdout, empty stderr) — for every case listed in the approved #327 plan's "Testing
# approach": the ".claude" segment class across both tools (Edit/Write), both roles
# (implementer/verifier), and all four agent_type spellings distributed across those combinations;
# a nested segment; a user-level path entirely outside any repo checkout (pins deliberate
# location-independence — this hook reads no cwd/repo-root at all); a case-variant spelling; the
# Windows drive-letter and backslash-spelled forms; ".claude" as the path's final segment; a
# CR-carrying spelling; a relative path that IS ".claude/..." (still denies via the ".claude"
# message, discriminated from a relative PLAIN path via the unclassifiable message by
# cdg-deny-rel-claude/cdg-deny-rel-plain below); a ".."-carrying path with ".claude" present
# (still the ".claude" message, since that class is checked first) and one without (the
# unclassifiable message); every documented no-opinion shape, including the two release-blocker
# controls (a main-session Write to .claude/LESSONS.md, the orchestrator's own lesson-append path,
# and a verifier-role Edit of a tracked source file, the mutation probe's own shape); and the same
# booby-trapped git/gh/rm/dirname/tr/awk/grep/sed PATH idiom plus a byte-identical fixture-tree
# listing proving this hook — which performs NO filesystem access at all, stricter than either
# hooks/agent-boundary.sh or hooks/push-guard.sh — never executes or writes anything.

mk_cdg_agent_path() { jq -n --arg agent "$1" --arg tool "$2" --arg fp "$3" '{tool_name: $tool, agent_type: $agent, tool_input: {file_path: $fp}}'; }
mk_cdg_agent_path_mode() { jq -n --arg agent "$1" --arg tool "$2" --arg fp "$3" --arg mode "$4" '{tool_name: $tool, agent_type: $agent, tool_input: {file_path: $fp}, permission_mode: $mode}'; }
# mk_cdg_missing_file_path AGENT TOOL — tool_input.file_path absent, but the raw JSON still
# contains the literal 'agent_type' substring (via the agent_type field itself) so this case
# actually reaches the "file_path empty" check instead of passing vacuously via the fast path
# (LESSON 2026-08-26's analogue, mirroring mk_agent_missing_command/mk_push_missing_command above).
mk_cdg_missing_file_path() { jq -n --arg agent "$1" --arg tool "$2" '{tool_name: $tool, agent_type: $agent, tool_input: {}}'; }
# mk_cdg_main_session TOOL FILE_PATH — no agent_type key at all (the main-session shape, M1).
mk_cdg_main_session() { jq -n --arg tool "$1" --arg fp "$2" '{tool_name: $tool, tool_input: {file_path: $fp}}'; }

# run_claude_guard JSON [PATHVAL] — runs the real claude-dir-guard.sh script against JSON on
# stdin, with PATH set to PATHVAL (defaults to this process's own PATH), leaving $cdg_out
# (stdout)/$cdg_err (stderr, read back from a file under $tmpbase)/$cdg_rc set as globals. Same
# separate-stdout/stderr-capture idiom as run_boundary/run_push_guard above (LESSON 2026-09-08b) —
# a merged capture cannot pin "exactly one line on stderr, nothing on stdout".
cdg_out=""
cdg_err=""
cdg_rc=0
run_claude_guard() {
  local json="$1" pathval="${2:-$PATH}" errfile="$tmpbase/cdg-stderr"
  cdg_out="$(printf '%s' "$json" | PATH="$pathval" "$bash_bin" "$claude_dir_guard" 2>"$errfile")"
  cdg_rc=$?
  cdg_err="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
}

# expect_cdg_deny_claude/expect_cdg_deny_unclassifiable/expect_cdg_no_opinion — assert against
# $cdg_out/$cdg_err/$cdg_rc. Each deny helper hand-types its own literal stem/phrase inline rather
# than taking a needle parameter, keeping this file's documented property (CLAUDE.md: "its only
# substring test hand-types the literal inline, never through a needle-taking helper").
expect_cdg_deny_claude() {
  [ "$cdg_rc" -eq 2 ] || { __ok=0; __why="${__why}rc: expected 2, got $cdg_rc\n"; }
  [ -z "$cdg_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$cdg_out'\n"; }
  local err_lines
  err_lines="$(printf '%s\n' "$cdg_err" | grep -c '[^[:space:]]')"
  [ "$err_lines" -eq 1 ] || { __ok=0; __why="${__why}expected exactly 1 non-blank stderr line, got $err_lines: '$cdg_err'\n"; }
  case "$cdg_err" in
    *"trail-blazer-flow claude-dir guard:"*"a path under a .claude segment"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the .claude-segment deny stem/phrase: '$cdg_err'\n" ;;
  esac
}
expect_cdg_deny_unclassifiable() {
  [ "$cdg_rc" -eq 2 ] || { __ok=0; __why="${__why}rc: expected 2, got $cdg_rc\n"; }
  [ -z "$cdg_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$cdg_out'\n"; }
  local err_lines
  err_lines="$(printf '%s\n' "$cdg_err" | grep -c '[^[:space:]]')"
  [ "$err_lines" -eq 1 ] || { __ok=0; __why="${__why}expected exactly 1 non-blank stderr line, got $err_lines: '$cdg_err'\n"; }
  case "$cdg_err" in
    *"trail-blazer-flow claude-dir guard:"*"could not be classified as absolute or normalised"*) ;;
    *) __ok=0; __why="${__why}stderr does not carry the unclassifiable deny stem/phrase: '$cdg_err'\n" ;;
  esac
}
expect_cdg_no_opinion() {
  [ "$cdg_rc" -eq 0 ] || { __ok=0; __why="${__why}rc: expected 0, got $cdg_rc\n"; }
  [ -z "$cdg_out" ] || { __ok=0; __why="${__why}expected empty stdout, got: '$cdg_out'\n"; }
  [ -z "$cdg_err" ] || { __ok=0; __why="${__why}expected empty stderr, got: '$cdg_err'\n"; }
}

# --- deny: ".claude" segment ---------------------------------------------------------------
# The four agent_type spellings distributed across both tools and both roles (LESSON 2026-09-08:
# both spellings exercised per role).
case_cdg_deny_impl_write_bare() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Write' '/repo/.claude/settings.json')"; expect_cdg_deny_claude; }
case_cdg_deny_impl_edit_ns()    { run_claude_guard "$(mk_cdg_agent_path 'trail-blazer-flow:implementer' 'Edit' '/repo/.claude/foo.md')"; expect_cdg_deny_claude; }
case_cdg_deny_verif_write_ns()  { run_claude_guard "$(mk_cdg_agent_path 'trail-blazer-flow:verifier' 'Write' '/repo/.claude/bar.json')"; expect_cdg_deny_claude; }
case_cdg_deny_verif_edit_bare() { run_claude_guard "$(mk_cdg_agent_path 'verifier' 'Edit' '/repo/.claude/baz.md')"; expect_cdg_deny_claude; }
case_cdg_deny_nested() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Write' '/Users/x/proj/.claude/settings.json')"; expect_cdg_deny_claude; }
case_cdg_deny_user_level() {
  # Deliberate location-independence: this path is OUTSIDE any repo checkout entirely (not even
  # shaped like one), and the hook still denies it — the classifier judges the string alone, with
  # no cwd/repo-root notion at all.
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/Users/x/.claude/settings.json')"
  expect_cdg_deny_claude
}
case_cdg_deny_case_variant() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/.Claude/x')"; expect_cdg_deny_claude; }
case_cdg_deny_drive_letter() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' 'C:/Users/x/.claude/foo')"; expect_cdg_deny_claude; }
case_cdg_deny_backslash()    { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' 'C:\Users\x\.claude\foo')"; expect_cdg_deny_claude; }
case_cdg_deny_final_segment() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/foo/.claude')"; expect_cdg_deny_claude; }
case_cdg_deny_crlf() {
  # A CR embedded inside the ".claude" spelling itself ($CR, declared above alongside the
  # push-guard/agent-boundary CRLF fixtures) — the strip can only WIDEN toward deny (see the
  # hook's own header), so this must still deny via the SAME ".claude" message.
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' "/repo/.clau${CR}de/foo")"
  expect_cdg_deny_claude
}
case_cdg_deny_rel_claude() {
  # A relative path whose very FIRST segment is ".claude" — no leading "/" for a naive
  # "*/.claude/*" pattern to anchor against; still denies via the ".claude" message (see the
  # hook's own header note on why the classifier checks "/$p/", not "$p/" alone).
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '.claude/LESSONS.md')"
  expect_cdg_deny_claude
}
case_cdg_deny_dotdot_claude() {
  # A ".."-carrying ABSOLUTE path that also carries a real ".claude" segment: the MORE SPECIFIC
  # ".claude" message wins (checked first), never the unclassifiable one.
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/Users/x/../.claude/y')"
  expect_cdg_deny_claude
}
case_cdg_deny_lf_claude() {
  # #327 round-1 kickback (K1): an embedded LF elsewhere in an otherwise-denying ".claude" path
  # must still print exactly ONE stderr line, not two — pre-fix, this printed 2 (measured). The
  # classifier still matches the raw $p (with the LF intact); only the PRINTED copy folds it.
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Write' "/repo/.claude/a${LF}b.md")"
  expect_cdg_deny_claude
}

# --- deny: unclassifiable (fail-closed) -----------------------------------------------------
case_cdg_deny_rel_plain() {
  # Discriminates the two deny classes against case_cdg_deny_rel_claude above: the identical
  # "relative, no leading slash" shape, but with NO ".claude" segment anywhere -> the OTHER,
  # distinctly-worded deny message.
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' 'src/main.rs')"
  expect_cdg_deny_unclassifiable
}
case_cdg_deny_dotdot_no_claude() {
  # A ".."-carrying ABSOLUTE path with no ".claude" segment anywhere: denies fail-closed, per the
  # triage record, even though it never mentions ".claude" at all.
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/Users/x/../etc/passwd')"
  expect_cdg_deny_unclassifiable
}
case_cdg_deny_lf_unclassifiable() {
  # #327 round-1 kickback (K1), the unclassifiable class's own copy of case_cdg_deny_lf_claude
  # above: an embedded LF in a relative, no-".claude" path (K1's own example) must still print
  # exactly ONE stderr line via the DISTINCT unclassifiable message.
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' "src/a${LF}b.rs")"
  expect_cdg_deny_unclassifiable
}

# --- no opinion --------------------------------------------------------------------------------
case_cdg_noop_ordinary_abs() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/src/main.rs')"; expect_cdg_no_opinion; }
case_cdg_noop_claude_backup() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/.claude-backup/x')"; expect_cdg_no_opinion; }
case_cdg_noop_my_claude() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/my.claude/x')"; expect_cdg_no_opinion; }
case_cdg_noop_main_session_lessons() {
  # Release-blocker control: the orchestrator's own main-session lesson append (no agent_type key
  # at all — reaches only this hook's fast path, never spawns jq) must keep working.
  run_claude_guard "$(mk_cdg_main_session 'Write' '/repo/.claude/LESSONS.md')"
  expect_cdg_no_opinion
}
case_cdg_noop_unrecognised_agent() { run_claude_guard "$(mk_cdg_agent_path 'Explore' 'Edit' '/repo/.claude/x')"; expect_cdg_no_opinion; }
case_cdg_noop_empty_agent() { run_claude_guard "$(mk_cdg_agent_path '' 'Edit' '/repo/.claude/x')"; expect_cdg_no_opinion; }
case_cdg_noop_plan_mode() { run_claude_guard "$(mk_cdg_agent_path_mode 'implementer' 'Edit' '/repo/.claude/x' 'plan')"; expect_cdg_no_opinion; }
case_cdg_noop_wrong_tool() { run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Read' '/repo/.claude/x')"; expect_cdg_no_opinion; }
case_cdg_noop_malformed_json() {
  # Deliberately contains both literal substrings 'agent_type' and '.claude' so this exercises
  # jq's own parse failure rather than passing vacuously via the raw-stdin fast path.
  run_claude_guard 'not json at all, but mentions agent_type and .claude anyway'
  expect_cdg_no_opinion
}
case_cdg_noop_missing_file_path() { run_claude_guard "$(mk_cdg_missing_file_path 'implementer' 'Edit')"; expect_cdg_no_opinion; }
case_cdg_noop_verifier_mutation_probe() {
  # Release-blocker control: the verifier's transient mutation-probe Edit of a tracked source file
  # (agents/verifier.md's only durable-looking write, restored before the dispatch returns) must
  # keep working.
  run_claude_guard "$(mk_cdg_agent_path 'verifier' 'Edit' '/repo/bin/find-planning-work.sh')"
  expect_cdg_no_opinion
}

# --- never-executes / writes-nothing ----------------------------------------------------------
# Same booby-trapped-PATH idiom as the two siblings above, widened to the full trap set the #327
# plan's acceptance criteria name (git, gh, rm, dirname, tr, awk, grep, sed) — this hook's own
# header claims it uses NONE of these, so every one is a valid trap.
case_cdg_never_executes_deny() {
  local trapdir="$tmpbase/trapbin-cdg-deny" sentinel="$tmpbase/sentinel-cdg-deny"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname tr awk grep sed; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/.claude/x')" "$trapdir:$PATH"
  expect_cdg_deny_claude
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — claude-dir-guard.sh invoked something on the booby-trapped PATH\n"; }
}
case_cdg_never_executes_noop() {
  local trapdir="$tmpbase/trapbin-cdg-noop" sentinel="$tmpbase/sentinel-cdg-noop"
  mkdir -p "$trapdir"
  rm -f "$sentinel"
  for bin in git gh rm dirname tr awk grep sed; do
    {
      printf '#!%s\n' "$bash_bin"
      printf 'touch "%s"\n' "$sentinel"
      printf 'exit 1\n'
    } > "$trapdir/$bin"
    chmod +x "$trapdir/$bin"
  done
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' '/repo/src/main.rs')" "$trapdir:$PATH"
  expect_cdg_no_opinion
  [ ! -e "$sentinel" ] || { __ok=0; __why="${__why}sentinel file present — claude-dir-guard.sh invoked something on the booby-trapped PATH\n"; }
}
case_cdg_writes_nothing() {
  # This hook performs NO filesystem access at all (stricter than either agent-boundary.sh or
  # push-guard.sh) — pin that a fixture tree containing .claude/LESSONS.md is byte-identical
  # before and after a deny run.
  local dir="$tmpbase/cdg-fixture-tree"
  mkdir -p "$dir/.claude"
  printf '# lessons\n' > "$dir/.claude/LESSONS.md"
  local before after
  before="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  run_claude_guard "$(mk_cdg_agent_path 'implementer' 'Edit' "$dir/.claude/LESSONS.md")"
  after="$(find "$dir" -type f -exec ls -la {} \; | sort)"
  expect_cdg_deny_claude
  [ "$before" = "$after" ] || { __ok=0; __why="${__why}fixture tree's file listing changed — claude-dir-guard.sh wrote to or altered a file it should only judge by its path string\n"; }
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
  # growing the whole-file total to 181 and the push-filtered unit to 98; #290 then added sixteen
  # more push-* fixtures, growing the whole-file total to 197 and the push-filtered unit to 114;
  # the #290 ROUND-2 KICKBACK then added two more push-* fixtures, growing the whole-file total to
  # 199 and the push-filtered unit to 116 — none of the seven rounds touched
  # agent-boundary.sh vocabulary or behaviour, so none of this section's own historical
  # "143-case"/"140 pass"/"143 pass" figures were re-measured. #327 then added 29 cdg-* fixtures
  # (none containing the substring "push"), growing the whole-file total to 228; the #327 round-1
  # kickback then added two more cdg-* fixtures (also push-free), growing the whole-file total to
  # the then-current 230 while leaving the push-filtered unit at 116 — see hooks/claude-dir-guard.sh's
  # own header for the fourth hook's own paragraph, and the cdg-* section's own mutation-proof
  # table further below for its 14 mutants.
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
  #       kickback (grown to 181 by #269 below and its own round-2 kickback, then to 197 by #290,
  #       then to 199 by #290's own round-2 kickback, then to the then-current 230 by #327's cdg-*
  #       section and its round-1 kickback, none of which touched agent-boundary.sh either) — see
  #       this section's header note above)
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
  # #327: the cdg-* section further below runs ONLY hooks/claude-dir-guard.sh, via its own
  # run_claude_guard — no mutant M1-M25 in THIS table edits that file, so this table's recorded
  # failing sets are unchanged by that addition, and its whole-file PASS figures above all predate
  # it. Made non-vacuous, not just reasoned by inspection (LESSON 2026-09-15): M1 (fast path 1
  # pattern corrupted) re-run against the then-current 230-case file (re-measured after the #327
  # round-1 kickback's two new cdg-* fixtures) still fails exactly its own 31-case set (199 pass,
  # 31 fail) with NO cdg-* case among them.
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
  # --- hooks/agent-boundary.sh: the #340 `.claude` Bash-write deny class -----------------------
  "ab-claude-deny-append-redirect|case_ab_claude_deny_append_redirect|.claude deny: implementer, printf appended via >> .claude/LESSONS.md (the exact shape the issue names) -- mutation proof: dev/mutants/hook-tests.json (340-fastpath)"
  "ab-claude-deny-redirect-nospace-quoted|case_ab_claude_deny_redirect_nospace_quoted|.claude deny: verifier, echo x >\"...\" (no space after >, quoted, absolute path) -- mutation proof: dev/mutants/hook-tests.json (340-fastpath)"
  "ab-claude-deny-heredoc|case_ab_claude_deny_heredoc|.claude deny: implementer, a multi-line heredoc whose first line redirects into .claude/LESSONS.md -- mutation proof: dev/mutants/hook-tests.json (340-fastpath)"
  "ab-claude-deny-case-variant|case_ab_claude_deny_case_variant|.claude deny: implementer, echo x >> .Claude/LESSONS.md (case-variant segment) -- mutation proof: dev/mutants/hook-tests.json (340-fastpath-case, 340-tolower)"
  "ab-claude-deny-backslash|case_ab_claude_deny_backslash|.claude deny: implementer, echo x >> 'C:\\repo\\.claude\\LESSONS.md' (backslash-separated path) -- mutation proof: dev/mutants/hook-tests.json (340-backslash)"
  "ab-claude-deny-tee|case_ab_claude_deny_tee|.claude deny: trail-blazer-flow:verifier, cat notes.txt piped into tee -a .claude/LESSONS.md (the vocabulary walk, not a redirect target) -- mutation proof: dev/mutants/hook-tests.json (340-arg-vocab)"
  "ab-claude-deny-cp|case_ab_claude_deny_cp|.claude deny: implementer, cp /tmp/lesson.md .claude/LESSONS.md (a plain-argument write, not a redirect) -- mutation proof: dev/mutants/hook-tests.json (340-arg-vocab)"
  "ab-claude-deny-cd|case_ab_claude_deny_cd|.claude deny: trail-blazer-flow:implementer, cd .claude && cat /tmp/l >> LESSONS.md (cd defeats the redirect target check on its own; the arg-vocab walk catches it instead) -- mutation proof: dev/mutants/hook-tests.json (340-arg-vocab)"
  "ab-claude-deny-sed-short|case_ab_claude_deny_sed_short|.claude deny: implementer, sed -i.bak '\$a x' .claude/LESSONS.md (short in-place flag) -- mutation proof: dev/mutants/hook-tests.json (340-sed-short)"
  "ab-claude-deny-sed-long|case_ab_claude_deny_sed_long|.claude deny: verifier, sed --in-place '\$a x' .claude/LESSONS.md (long in-place flag) -- mutation proof: dev/mutants/hook-tests.json (340-sed-long)"
  "ab-claude-deny-quoted-double|case_ab_claude_deny_quoted_double|.claude deny: implementer, echo x >> \".claude/LESSONS.md\" (a double quote directly adjacent to the segment) -- mutation proof: dev/mutants/hook-tests.json (340-quote-strip-dq)"
  "ab-claude-deny-quoted-single|case_ab_claude_deny_quoted_single|.claude deny: verifier, tee -a '.claude/LESSONS.md' (a single quote directly adjacent to the segment, via the vocabulary walk) -- mutation proof: dev/mutants/hook-tests.json (340-quote-strip-sq)"
  "ab-claude-deny-sed-combined|case_ab_claude_deny_sed_combined|.claude deny: implementer, sed -Ei (in-place flag combined with another short flag) -- mutation proof: dev/mutants/hook-tests.json (340-sed-combined)"
  "ab-claude-deny-never-writes|case_ab_claude_deny_never_writes|.claude deny, AND the boundary never invokes git/gh/rm on the booby-trapped PATH, AND the redirect target file is never actually created — sentinel absent, target file absent -- mutation proof: dev/mutants/hook-tests.json (340-policy-arm)"
  "ab-claude-noop-input-redirect|case_ab_claude_noop_input_redirect|.claude no opinion: implementer, wc -l < .claude/LESSONS.md (an input redirect, never a write position) -- mutation proof: dev/mutants/hook-tests.json (340-input-redirect)"
  "ab-claude-noop-tee-elsewhere|case_ab_claude_noop_tee_elsewhere|.claude no opinion: implementer, cat .claude/LESSONS.md piped into tee /tmp/out.txt (the READ is under .claude, tee's own target isn't) -- mutation proof: dev/mutants/hook-tests.json (340-arg-gate)"
  "ab-claude-noop-sed-no-inplace|case_ab_claude_noop_sed_no_inplace|.claude no opinion: verifier, sed -n '1,5p' .claude/LESSONS.md (no in-place flag) -- mutation proof: dev/mutants/hook-tests.json (340-inplace-gate)"
  "ab-claude-noop-near-miss|case_ab_claude_noop_near_miss|.claude no opinion: implementer, echo x >> .claude-backup/notes.md (a near-miss segment, not an exact .claude match) -- mutation proof: dev/mutants/hook-tests.json (340-segment-exact)"
  "ab-claude-noop-main-session|case_ab_claude_noop_main_session|.claude no opinion: main session (no agent_type key), echo x >> .claude/LESSONS.md (blocking this would stop a release -- the orchestrator's own lesson append) -- release-blocker control, not part of the mutation-proof registry"
  # --- hooks/agent-boundary.sh: the #387 .claude command-level interpreter/writer class -----------
  "ab-cwrite-deny-python-c|case_ab_cwrite_deny_python_c|.claude command-level deny: implementer, python3 -c \"open('.claude/LESSONS.md','a').write('- lesson')\" (the issue's exact shape) -- mutation proof: dev/mutants/hook-tests.json (387-vocab-empty)"
  "ab-cwrite-deny-python-heredoc|case_ab_cwrite_deny_python_heredoc|.claude command-level deny: trail-blazer-flow:implementer, a heredoc whose command word (python3) and .claude mention are on DIFFERENT lines -- mutation proof: dev/mutants/hook-tests.json (387-cross-line)"
  "ab-cwrite-deny-perl-i|case_ab_cwrite_deny_perl_i|.claude command-level deny: verifier, perl -i.bak -pe 's/a/b/' .claude/LESSONS.md -- mutation proof: dev/mutants/hook-tests.json (387-vocab-empty)"
  "ab-cwrite-deny-dd|case_ab_cwrite_deny_dd|.claude command-level deny: implementer, dd if=/tmp/lesson.md of=.claude/LESSONS.md (segment bounded by =) -- mutation proof: dev/mutants/hook-tests.json (387-vocab-empty)"
  "ab-cwrite-deny-install|case_ab_cwrite_deny_install|.claude command-level deny: trail-blazer-flow:verifier, install -m 644 /tmp/lesson.md .claude/LESSONS.md -- mutation proof: dev/mutants/hook-tests.json (387-vocab-empty)"
  "ab-cwrite-deny-versioned-abs|case_ab_cwrite_deny_versioned_abs|.claude command-level deny: implementer, /usr/local/bin/python3.12 -c \"open('.claude/LESSONS.md','a')\" (versioned basename after path stripping) -- mutation proof: dev/mutants/hook-tests.json (387-version-strip)"
  "ab-cwrite-deny-case-variant|case_ab_cwrite_deny_case_variant|.claude command-level deny: implementer, install -m 644 /tmp/lesson.md .Claude/LESSONS.md (case-variant segment) -- mutation proof: dev/mutants/hook-tests.json (387-tolower)"
  "ab-cwrite-deny-never-writes|case_ab_cwrite_deny_never_writes|.claude command-level deny, AND the boundary never invokes git/gh/rm on the booby-trapped PATH, AND the target file is never actually created -- sentinel absent, target file absent -- mutation proof: dev/mutants/hook-tests.json (387-vocab-empty)"
  "ab-cwrite-noop-reader|case_ab_cwrite_noop_reader|.claude command-level no opinion: implementer, npm install && grep -n lesson .claude/LESSONS.md && cat .claude/BASELINE.md (install appears only as an argument, never a command word) -- mutation proof: dev/mutants/hook-tests.json (387-word-gate)"
  "ab-cwrite-noop-no-claude-seg|case_ab_cwrite_noop_no_claude_seg|.claude command-level no opinion: implementer, python3 -m pytest tests/test_claude_client.py (a vocabulary command word, no .claude segment anywhere) -- mutation proof: dev/mutants/hook-tests.json (387-tok-gate)"
  "ab-cwrite-noop-claude-plugin|case_ab_cwrite_noop_claude_plugin|.claude command-level no opinion: verifier, python3 -c \"import json; json.load(open('.claude-plugin/plugin.json'))\" (trailing-boundary near-miss) -- mutation proof: dev/mutants/hook-tests.json (387-boundary-trail)"
  "ab-cwrite-noop-my-claude|case_ab_cwrite_noop_my_claude|.claude command-level no opinion: implementer, touch build/my.claude (leading-boundary near-miss) -- mutation proof: dev/mutants/hook-tests.json (387-boundary-lead)"
  "ab-cwrite-noop-main-session|case_ab_cwrite_noop_main_session|.claude command-level no opinion: main session (no agent_type key), the D1 command (blocking this would stop a release -- the orchestrator's own lesson append) -- release-blocker control, not part of the mutation-proof registry"
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
  # push-deny-c-per-segment-session-reset (D1) — growing the push-* set to 98 cases (114 after
  # #290 below, then 116 after #290's own round-2 kickback), and TWO more mutants, M56 and M57
  # (below M55). Re-running M46-M55 plus the
  # thirteen RE-POINTED mutants above against that then-current 98-case set changes only the PASS
  # count (+2 throughout, from the two new passing fixtures) for every one of them EXCEPT four,
  # which each gain exactly one more failing case purely because C2/D1 happen to share a code path
  # an UNCHANGED existing mutant already covered (no code moved this round — this is a
  # new-fixture-matches-an-old-mutant event, not a re-pointing event): M14 and M15 (current_branch
  # / default_branch forced empty) and M52 (unresolvable "-C" target clears instead of degrading)
  # each gain C2, since C2 shares B4's exact verdict mechanism (a bare push judged by the
  # SESSION's own current/default branch after a failed "-C" resolution restores them); M26 (the
  # config-read guard disabled) gains D1, since D1's second segment shares
  # push-deny-config-remote-push-bare's exact mechanism (a bare push denied via the SESSION's own
  # remote.origin.push config). Every other M1-M55 entry's failing SET is unchanged by this
  # kickback (verified directly, not assumed — each of M17, M18, M28, M33, M34, M35, M36, M37,
  # M38, M43, M46, M47, M48, M49, M50, M51, M53, M54, M55 was re-run against that then-current
  # 98-case set and produces the identical failing-case list, +2 pass).
  # #290 adds SIXTEEN more push-* fixtures (the global-config candidates: $GIT_CONFIG_GLOBAL,
  # $XDG_CONFIG_HOME/git/config or its $HOME/.config/git/config default, and $HOME/.gitconfig,
  # unioned with the repo-local routes #268 already reads), growing the push-* set to 114 cases
  # (116 after #290's own round-2 kickback below), and TWELVE more mutants, M58-M69 (below M57).
  # Per the mandate accompanying this issue, EVERY existing mutant whose recipe names code inside
  # resolve_repo()'s config block or config_deny() is RE-MEASURED (not reasoned about) against
  # this 114-case set (the CURRENT 116-case set is covered below, in the round-2 kickback
  # paragraph), not merely
  # the fourteen #269 already re-pointed: M14, M15, M17, M18 (current/default-branch resolution and
  # the common-dir/upward-walk derivations, all upstream of the config candidate list), M26-M45
  # (the whole #268 config-parsing and config_deny() surface, including M27/M29-M32/M39-M42/M44/M45,
  # which #269 never touched since none of their recipes named code that moved into
  # resolve_repo() at that time), and M54 (the resolved-config-not-applied mutant, whose recipe
  # names cfg_push_lines/cfg_push_defaults/cfg_branch_merge by name and so needed re-pointing for
  # #290's cfg_push_default -> cfg_push_defaults rename regardless of #269). Round-1 of this issue
  # incorrectly claimed M46, M47, M48, M49, M50, M51, M52, M53, M55, M56, and M57 were ALL NOT
  # re-measured for #290, reasoning (not measuring) that none of their recipes touches the
  # config-candidate list or the push.default list #290 added. A verifier kickback (finding F3)
  # measured every one of these directly against the #290 114-case push-* set and found the claim false
  # for M46 and M47 specifically: each newly discriminates push-deny-c-target-global-route (#290's
  # own fixture, whose SESSION deliberately resolves NO repo at all — see the dated
  # .claude/LESSONS.md entry — so the "-C" TARGET's own resolution, which both M46
  # (apply_c_target()'s body) and M47 (the tokenizer's "-C" field) each disable by a different
  # route, becomes the ONLY path to this fixture's deny). M48, M49, M50, M51, M52, M53, M55, M56,
  # and M57 ARE genuinely unaffected — each individually re-measured (not reasoned about) and
  # confirmed to keep its EXACT pre-#290 failing set; their own "CURRENT 98-case" figures below are
  # relabeled "the 98-case set" (no longer current, but still an accurate historical measurement)
  # rather than re-run again. Of the TWENTY-SEVEN RE-MEASURED EXISTING mutants (M14, M15, M17, M18,
  # M26-M45, M46, M47, M54 — M46/M47 newly added to this set by the kickback correction above),
  # every one's PASS count grows by exactly +16 (from the sixteen new #290 passing fixtures) EXCEPT
  # NINE, which each gain additional failing cases from #290's own fixtures — M14 (+7: every #290
  # fixture whose deny resolves push.default=upstream/tracking through a real [branch] section),
  # M26 (+12: every #290 DENY fixture, since disabling the whole per-file read loop removes every
  # route regardless of source), M29 (+2), M31 (+1), M39 (+2: both #290 release-blocker "-C"
  # controls, alongside the pre-existing push-noop-config-explicit-refspec), M42 (+9), M46 (+7,
  # corrected as above), M47 (+7, corrected as above), and M54 (+1: the one #290 "-C" fixture whose
  # SESSION deliberately resolves no repo at all, unlike every #269 "-C" fixture's session) — each
  # entry below states its own gained set; the other eighteen (M15, M17, M18, M27, M28, M30, M32,
  # M33, M34, M35, M36, M37, M38, M40, M41, M43, M44, M45) keep their EXACT pre-#290 failing sets
  # (verified directly, not assumed), +16 pass each. The TWELVE NEW mutants, M58-M69 (below M57),
  # are each measured fresh against this 114-case set — see their own entries (and the round-2
  # kickback paragraph immediately below) for what each discriminates against the CURRENT 116-case
  # set.
  # The #290 ROUND-2 KICKBACK (verifier findings F1-F4) adds TWO more push-* fixtures:
  # push-deny-global-two-defaults-one-file (F1 — TWO "[push] default = ..." lines inside ONE file,
  # both accumulated and evaluated rather than the file's own last value winning) and
  # push-deny-config-tab-in-value (F4 — a literal TAB byte inside a configured
  # "remote.<name>.push" value, pinning that it stays in the record's own UNBOUNDED tail rather
  # than corrupting the source label), growing the push-* set to the CURRENT 116 cases, and ONE
  # more mutant, M70 (below M69, reverts F4's field-order fix). M33's own recipe is RESTATED (not
  # re-pointed to different code) for F4's field-order change — the mutation's INTENT (only the
  # FIRST remote.<name>.push record survives) and its figure are unaffected. EVERY mutant in this
  # table, M14 through M70, is RE-MEASURED (not reasoned about) against this CURRENT 116-case set.
  # ELEVEN gain a new failing case beyond their already-recorded 114-case figure: M14 (+1:
  # push-deny-global-two-defaults-one-file, the same push.default=upstream-through-a-real-
  # [branch]-section mechanism M14's own 114-case gain already documents), M26 (+2: BOTH new
  # fixtures, since disabling the whole per-file read loop removes every route regardless of
  # source), M32 (+1: push-deny-config-tab-in-value — the wildcard-destination check M32 disables
  # is exactly what lets this fixture's embedded-TAB value still deny), M42 (+1:
  # push-deny-global-two-defaults-one-file, the same push.default-disabled-entirely mechanism
  # M42's own 114-case gain already documents), M58 (+1: push-deny-global-two-defaults-one-file —
  # its ONLY route is global), M60 (+1: push-deny-global-two-defaults-one-file — its denying record
  # lives in $HOME/.gitconfig specifically), M63 (+2: BOTH new fixtures, corrected below per
  # finding F2b), M64 (+1: push-deny-global-two-defaults-one-file — read as the first EXISTING
  # candidate, so the break-after-first-existing-candidate mutant loses $common/config's own
  # branch.merge before this fixture's "upstream" record can resolve a destination), M65 (+1:
  # push-deny-global-two-defaults-one-file, per finding F1's own fixture design), M67 (+1:
  # push-deny-global-two-defaults-one-file — its inline source-label assertion, not its rc, is what
  # this mutant flips), and M68 (+1: push-deny-config-tab-in-value — likewise its inline
  # source-label assertion). Every other mutant (M15, M17, M18, M27, M28, M29, M30, M31, M33, M34,
  # M35, M36, M37, M38, M39, M40, M41, M43, M44, M45, M46, M47, M48, M49, M50, M51, M52, M53, M54,
  # M55, M56, M57, M59, M61, M62, M66, M69) keeps its EXACT pre-kickback failing set, +2 pass each.
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
  #       the session's. RE-MEASURED again for the #269 round-2 kickback against the then-current
  #       98-case push-* set: -> 89 pass, 9 fail — the same eight cases plus
  #       push-deny-c-unresolvable-never-executes (C2), which shares push-deny-c-unresolvable-
  #       degrades' (B4's) exact mechanism: a bare push judged by the SESSION's own current_branch
  #       after a failed "-C" resolution restores it — no code moved for this addition, C2 simply
  #       exercises the identical existing dependency. RE-MEASURED again for #290 against the
  #       114-case push-* set: -> 98 pass, 16 fail — the same nine cases plus SEVEN of the
  #       sixteen new #290 fixtures: push-deny-global-gitconfig-upstream, push-deny-global-xdg-
  #       upstream, push-deny-global-xdg-home-default-upstream, push-deny-global-env-var-upstream,
  #       push-deny-global-benign-does-not-mask-repo-route, push-deny-global-overrides-benign-repo-
  #       route, and push-deny-global-never-executes — every #290 fixture whose deny resolves
  #       push.default=upstream through a REAL [branch] section (the identical
  #       cfg_subsection==current_branch dependency); the other nine #290 fixtures either use a
  #       remote.<name>.push route, push.default=matching (never consults current_branch), or are
  #       no-opinion controls. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT
  #       116-case push-* set: -> 99 pass, 17 fail — the same sixteen cases plus
  #       push-deny-global-two-defaults-one-file (F1), the identical mechanism: its denying record
  #       also resolves push.default=upstream through a real [branch] section; push-deny-config-
  #       tab-in-value (F4) is unaffected, since its route is remote.<name>.push, never
  #       push.default)
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
  #       unaffected. RE-MEASURED again for the #269 round-2 kickback against the then-current
  #       98-case push-* set: -> 88 pass, 10 fail — the same nine cases plus
  #       push-deny-c-unresolvable-never-executes (C2), for the identical reason M14 above gained
  #       it: C2 mirrors B4's dependency on the session's own default_branch too. RE-MEASURED again
  #       for #290 against the 114-case push-* set: -> 104 pass, 10 fail — UNCHANGED failing
  #       set, +16 pass; none of the sixteen new #290 fixtures denies via a NON-fallback default
  #       branch value — every #290 deny route resolves either through PUSH_DEFAULT_BRANCH_FALLBACK's
  #       unconditional "main"/"master" members or through a remote.<name>.push/matching route that
  #       never reads default_branch at all. RE-MEASURED again for the #290 ROUND-2 KICKBACK against
  #       the CURRENT 116-case push-* set: -> 106 pass, 10 fail — UNCHANGED failing set, +2 pass;
  #       neither new kickback fixture denies via a non-fallback default branch value either)
  #   M16 PUSH_DEFAULT_BRANCH_FALLBACK emptied                            -> 55 pass,  1 fail
  #   M17 the worktree common-dir derivation broken (never strips        -> 55 pass,  1 fail
  #       /worktrees/* from gitdir)
  #       (kills only push-deny-trunk-worktree. #269 RE-POINTED (shared resolve_repo()) and
  #       RE-MEASURED against the then-current 96-case push-* set: -> 94 pass, 2 fail — the
  #       historical case plus push-deny-config-worktree-commondir, #268's own worktree-config
  #       fixture, which depends on the identical common-dir derivation. RE-MEASURED again for the
  #       #269 round-2 kickback against the then-current 98-case push-* set: -> 96 pass, 2 fail —
  #       unchanged failing set, +2 pass from the two new #269-round-2 fixtures, neither a
  #       worktree. RE-MEASURED again for #290 against the 114-case push-* set: -> 112
  #       pass, 2 fail — UNCHANGED failing set, +16 pass; none of the sixteen new #290 fixtures is
  #       a worktree either. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT
  #       116-case push-* set: -> 114 pass, 2 fail — UNCHANGED failing set, +2 pass; neither new
  #       kickback fixture is a worktree either)
  #   M18 the upward .git walk disabled (dir="$parent" -> dir="$dir",     -> 55 pass,  1 fail
  #       so it never leaves the starting directory)
  #       (kills only push-deny-trunk-subdir. #269 RE-POINTED (shared resolve_repo()) and
  #       RE-MEASURED against the then-current 96-case push-* set: -> 95 pass, 1 fail — unchanged
  #       failing set; no #268/#269 fixture depends on a multi-level upward walk. RE-MEASURED
  #       again for the #269 round-2 kickback against the then-current 98-case push-* set: -> 97
  #       pass, 1 fail — unchanged failing set, +2 pass; neither new fixture depends on a
  #       multi-level upward walk either. RE-MEASURED again for #290 against the 114-case
  #       push-* set: -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass; no #290 fixture
  #       depends on a multi-level upward walk either. RE-MEASURED again for the #290 ROUND-2
  #       KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED failing
  #       set, +2 pass; neither new kickback fixture depends on a multi-level upward walk either)
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
  #       then-current 98-case push-* set: -> 80 pass, 18 fail — the same seventeen cases plus
  #       push-deny-c-per-segment-session-reset (D1), whose SECOND segment shares
  #       push-deny-config-remote-push-bare's exact mechanism: a bare push denied via the
  #       SESSION's own remote.origin.push config, disabled here for the SESSION-scope
  #       resolve_repo() call too, not just the "-C" one -- this is the same shared-function
  #       dependency, not new code. #290 RE-POINTED: this line now lives inside the per-candidate-
  #       file loop (`[ -f "$cfgf" ] || continue` -> `continue` unconditionally), so EVERY
  #       candidate file -- global or repo-local -- is skipped, not just the repo-local one;
  #       RE-MEASURED against the 114-case push-* set: -> 84 pass, 30 fail — the same
  #       eighteen cases plus TWELVE of the sixteen new #290 fixtures (every #290 DENY fixture; the
  #       four #290 no-opinion fixtures are unaffected, since disabling every config read can only
  #       ever remove a route, never add one). RE-MEASURED again for the #290 ROUND-2 KICKBACK
  #       against the CURRENT 116-case push-* set: -> 84 pass, 32 fail — the same thirty cases plus
  #       BOTH new #290 kickback fixtures, push-deny-global-two-defaults-one-file (F1) and
  #       push-deny-config-tab-in-value (F4) -- each a DENY fixture whose only route is a config
  #       read this mutant disables entirely, the identical mechanism as the other twelve)
  #   M27 the n==1 exact-remote-scoping guard disabled (if [ -n "$scope" ] &&             -> 79 pass,
  #       [ "$sub" != "$scope" ]; then -> if false && ...)                                 1 fail
  #       (kills only push-noop-config-other-remote-named -- "origin"'s own push route wrongly
  #       applies to a "git push backup". NOT RE-POINTED by #269 (no code moved); #290
  #       RE-MEASURED for the first time since this #268 round-1 80-case baseline, against the
  #       114-case push-* set: -> 113 pass, 1 fail — UNCHANGED failing set, +34 pass; none
  #       of the #269/#290 fixtures added since names a non-origin remote in this shape.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture names
  #       a non-origin remote in this shape either)
  #   M28 the [branch "<current>"] scoping guard disabled (if [ "$cfg_subsection" =       -> 79 pass,
  #       "$current_branch" ]; then -> if true || ...)                                     1 fail
  #       (kills only push-noop-config-branch-other -- a DIFFERENT branch's merge value wrongly
  #       applies to the current branch. #269 RE-POINTED (shared resolve_repo()) and RE-MEASURED
  #       against the then-current 96-case push-* set: -> 95 pass, 1 fail — unchanged failing set;
  #       no #269 fixture depends on this guard, since none of the twelve new fixtures configures a
  #       [branch] section at all. RE-MEASURED again for the #269 round-2 kickback against the
  #       then-current 98-case push-* set: -> 97 pass, 1 fail — unchanged failing set, +2 pass;
  #       neither new fixture configures a [branch] section either. RE-MEASURED again for #290
  #       against the 114-case push-* set: -> 113 pass, 1 fail — UNCHANGED failing set,
  #       +16 pass; none of the sixteen new #290 fixtures configures a [branch] section either.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; push-deny-global-two-defaults-
  #       one-file's own [branch "feature/x"] section already equals its current branch, so this
  #       guard's absence changes nothing for it, and push-deny-config-tab-in-value configures no
  #       [branch] section at all)
  #   M29 the push.default mode-check pattern widened to match every value               -> 77 pass,
  #       ([Uu][Pp][Ss][Tt][Rr][Ee][Aa][Mm]|[Tt][Rr][Aa][Cc][Kk][Ii][Nn][Gg]) -> *))         3 fail
  #       (kills push-noop-config-push-default-current and push-noop-config-push-default-simple,
  #       whose branch sections WOULD deny if their mode were mistaken for upstream; also kills
  #       push-deny-config-push-default-matching as a side effect -- the "matching" case arm
  #       becomes unreachable once "*)" matches everything first, so that fixture's config, which
  #       has no branch section, resolves to no destination at all instead of denying. NOT
  #       RE-POINTED by #269; #290 RE-MEASURED for the first time since this #268 round-1 80-case
  #       baseline, against the 114-case push-* set: -> 109 pass, 5 fail — the same three
  #       cases plus TWO of the sixteen new #290 fixtures, as a side effect: push-deny-global-
  #       default-matching (its "matching" case arm becomes unreachable too) and
  #       push-deny-global-benign-does-not-mask-repo-route -- NOT because its deny is masked
  #       (measured, correcting a verifier-round-1 finding, F2a: this fixture STILL denies, rc 2,
  #       under this mutant); its benign GLOBAL "current" record is evaluated FIRST in
  #       cfg_push_defaults' accumulation order and NOW ALSO matches the widened "*)" arm, so this
  #       mutant denies via that GLOBAL record's own push.default=current -- resolving "main" from
  #       cfg_branch_merge exactly as the "upstream" arm normally would -- and only the fixture's
  #       OWN inline source-label assertion fails, since the deny is attributed to "your global git
  #       config" (correct for THIS mutant's own record) rather than the REPO's ".git/config" label
  #       the fixture's assertion expects. RE-MEASURED again for the #290 ROUND-2 KICKBACK against
  #       the CURRENT 116-case push-* set: -> 111 pass, 5 fail — UNCHANGED failing set, +2 pass;
  #       neither new kickback fixture's FIRST-accumulated push.default record is a value this
  #       mutant's widened arm newly reaches ahead of a genuine deny (push-deny-global-two-
  #       defaults-one-file's own first record, "upstream", already matched this arm before the
  #       mutation, so widening it changes nothing for that fixture; push-deny-config-tab-in-value
  #       uses remote.<name>.push, never push.default, at all))
  #   M30 "tracking" dropped from the upstream/tracking pattern (...[Mm]|[Tt]...[Gg])      -> 79 pass,
  #       -> [Uu][Pp][Ss][Tt][Rr][Ee][Aa][Mm]))                                              1 fail
  #       (kills only push-deny-config-push-default-tracking. NOT RE-POINTED by #269; #290
  #       RE-MEASURED for the first time since this #268 round-1 80-case baseline, against the
  #       114-case push-* set: -> 113 pass, 1 fail — UNCHANGED failing set, +34 pass; none
  #       of the sixteen new #290 fixtures uses push.default=tracking. RE-MEASURED again for the
  #       #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail —
  #       UNCHANGED failing set, +2 pass; neither new kickback fixture uses push.default=tracking
  #       either)
  #   M31 the push.default=matching deny arm's body replaced with a no-op (:              -> 79 pass,
  #       instead of __deny_dest=.../__deny_kind=.../__deny_via=...)                        1 fail
  #       (kills only push-deny-config-push-default-matching. NOT RE-POINTED by #269; #290
  #       RE-MEASURED for the first time since this #268 round-1 80-case baseline, against the
  #       114-case push-* set: -> 112 pass, 2 fail — the same case plus ONE of the sixteen
  #       new #290 fixtures, push-deny-global-default-matching, whose deny depends entirely on this
  #       same arm's body. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT
  #       116-case push-* set: -> 114 pass, 2 fail — UNCHANGED failing set, +2 pass; neither new
  #       kickback fixture's deny depends on this arm)
  #   M32 the wildcard-destination ("*") deny check removed from config_deny()'s          -> 79 pass,
  #       per-record loop (the case "$dest" in *'*'*) ... esac block deleted)               1 fail
  #       (kills only push-deny-config-wildcard-refspec -- its resolved destination, a literal
  #       "*", falls through to an ordinary is_deny_member compare and does not match. NOT
  #       RE-POINTED by #269; #290 RE-MEASURED for the first time since this #268 round-1 80-case
  #       baseline, against the 114-case push-* set: -> 113 pass, 1 fail — UNCHANGED
  #       failing set, +34 pass; no #290 fixture's config carries a wildcard destination.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 114 pass, 2 fail — the same case plus push-deny-config-tab-in-value (F4): that
  #       fixture's own wildcard destination ("refs/heads/*:refs/heads/*<TAB>junklabel") relies on
  #       this exact check to deny; removing it falls through to the same is_deny_member compare,
  #       which does not match either)
  #   M33 only the FIRST remote.<name>.push record is ever kept (F4's field-reorder            -> 79 pass,
  #       kickback restates this recipe: [ -n "$cfg_push_lines" ] || cfg_push_lines=...           1 fail
  #       guard added before the append, now writing "${cfg_src}${cfg_tab}${cfg_subsection}
  #       ${cfg_tab}${cfg_val}" -- the field ORDER changed by finding F4, the mutation's INTENT
  #       and figure did not)
  #       (kills only push-deny-config-remote-push-second-line -- the fixture's first, harmless
  #       push= line wins and the second, offending one is never seen. #269 RE-POINTED (shared
  #       resolve_repo()) and RE-MEASURED against the then-current 96-case push-* set: -> 95 pass,
  #       1 fail — unchanged failing set; no #269 fixture's config carries two push= lines under
  #       one remote. RE-MEASURED again for the #269 round-2 kickback against the then-current
  #       98-case push-* set: -> 97 pass, 1 fail — unchanged failing set, +2 pass; neither new
  #       fixture's config carries two push= lines under one remote either. RE-MEASURED again for
  #       #290 against the 114-case push-* set: -> 113 pass, 1 fail — UNCHANGED failing
  #       set, +16 pass; no #290 fixture's config carries two push= lines under one remote either.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK, with the recipe restated for F4's field
  #       reorder as noted above, against the CURRENT 116-case push-* set: -> 115 pass, 1 fail —
  #       UNCHANGED failing set, +2 pass; neither new kickback fixture's config carries two push=
  #       lines under one remote either)
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
  #       again for the #269 round-2 kickback against the then-current 98-case push-* set: -> 98
  #       pass, 0 fail — still NOT flipped, same reason (neither new fixture's config carries a
  #       "#"/";"-commented directive either). RE-MEASURED again for #290 against the
  #       114-case push-* set: -> 114 pass, 0 fail — still NOT flipped, same reason (no #290
  #       fixture's config carries a "#"/";"-commented directive either). RE-MEASURED again for the
  #       #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 116 pass, 0 fail —
  #       still NOT flipped, same reason (neither new kickback fixture's config carries a
  #       "#"/";"-commented directive either))
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
  #       RE-MEASURED again for the #269 round-2 kickback against the then-current 98-case push-*
  #       set: -> 97 pass, 1 fail — unchanged failing set, +2 pass; neither new fixture's config
  #       carries a CR either. RE-MEASURED again for #290 against the 114-case push-* set:
  #       -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass; no #290 fixture's config carries a
  #       CR either. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case
  #       push-* set: -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; neither new kickback
  #       fixture's config carries a CR either.
  #   M36 the config path changed from "$common/config" to "$gitdir/config"               -> 79 pass,
  #                                                                                          1 fail
  #       (kills only push-deny-config-worktree-commondir -- the worktree pointer's own gitdir
  #       has no config file at all, so [ -f ] fails and config is silently never read; every
  #       non-worktree fixture has $gitdir == $common already, so this mutant is inert for them.
  #       #269 RE-POINTED (shared resolve_repo()) and RE-MEASURED against the then-current 96-case
  #       push-* set: -> 95 pass, 1 fail — unchanged failing set; every #269 "-C" target fixture is
  #       an ordinary checkout, not a worktree, so $gitdir == $common for all of them too.
  #       RE-MEASURED again for the #269 round-2 kickback against the then-current 98-case push-*
  #       set: -> 97 pass, 1 fail — unchanged failing set, +2 pass; C2/D1's checkouts are likewise
  #       ordinary, not worktrees. #290 RE-POINTED: this line now lives in the config-CANDIDATE
  #       heredoc's own repo-local line ($common/config -> $gitdir/config), the same effect one
  #       level up; RE-MEASURED against the 114-case push-* set: -> 113 pass, 1 fail —
  #       UNCHANGED failing set, +16 pass; every #290 fixture's own checkout (session or "-C"
  #       target) is likewise an ordinary checkout, not a worktree. RE-MEASURED again for the #290
  #       ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED
  #       failing set, +2 pass; neither new kickback fixture's own checkout is a worktree either)
  #   M37 the last-line-without-a-trailing-newline read rescue removed (while             -> 79 pass,
  #       IFS= read -r cfgline || [ -n "$cfgline" ] -> while IFS= read -r cfgline)          1 fail
  #       (kills only push-deny-config-no-trailing-newline -- its one and only config line, which
  #       has no trailing newline, is silently dropped by `read`'s own EOF behaviour. #269
  #       RE-POINTED (shared resolve_repo()) and RE-MEASURED against the then-current 96-case
  #       push-* set: -> 95 pass, 1 fail — unchanged failing set; every #269 fixture's config,
  #       where one is written at all, ends in a trailing newline. RE-MEASURED again for the #269
  #       round-2 kickback against the then-current 98-case push-* set: -> 97 pass, 1 fail —
  #       unchanged failing set, +2 pass; D1's config (the only new fixture with one) also ends in
  #       a trailing newline. RE-MEASURED again for #290 against the 114-case push-* set:
  #       -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass; every #290 fixture's config, where
  #       one is written at all, also ends in a trailing newline. RE-MEASURED again for the #290
  #       ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED
  #       failing set, +2 pass; both new kickback fixtures' configs also end in a trailing newline)
  #   M38 the [remote "<name>"] section-header pattern narrowed to lowercase-only         -> 79 pass,
  #       ([Rr][Ee][Mm][Oo][Tt][Ee] -> remote)                                              1 fail
  #       (kills only push-deny-config-mixed-case -- "[Remote ...]" no longer matches the section
  #       pattern at all and falls through to the catch-all "other" section, so its "Push = ..."
  #       key is never captured. #269 RE-POINTED (shared resolve_repo()) and RE-MEASURED against
  #       the then-current 96-case push-* set: -> 95 pass, 1 fail — unchanged failing set; no #269
  #       fixture's config uses mixed-case section/key names. RE-MEASURED again for the #269
  #       round-2 kickback against the then-current 98-case push-* set: -> 97 pass, 1 fail —
  #       unchanged failing set, +2 pass; neither new fixture's config uses mixed-case section/key
  #       names either. RE-MEASURED again for #290 against the 114-case push-* set: -> 113
  #       pass, 1 fail — UNCHANGED failing set, +16 pass; no #290 fixture's config uses mixed-case
  #       section/key names either. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the
  #       CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; neither
  #       new kickback fixture's config uses mixed-case section/key names either)
  #   M39 the n<=1 gate removed (config_deny is also called after the n>=2 refspec        -> 79 pass,
  #       loop, using nonopt[0] as scope)                                                   1 fail
  #       (kills only push-noop-config-explicit-refspec -- the harness's own
  #       `git push -u origin "claude/17-a"` shape wrongly denies via the fixture's
  #       remote.origin.push=HEAD:main config; a release-blocker regression if this ever shipped.
  #       NOT RE-POINTED by #269; #290 RE-MEASURED for the first time since this #268 round-1
  #       80-case baseline, against the 114-case push-* set: -> 111 pass, 3 fail — the same
  #       case plus BOTH #290 release-blocker "-C" controls, push-noop-global-explicit-refspec and
  #       push-noop-global-explicit-refspec-c — the release-blocker class this gate exists for.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 113 pass, 3 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture
  #       carries an explicit refspec)
  #   M40 a matched remote.<name>.push record denies unconditionally, regardless          -> 78 pass,
  #       of its resolved destination (the is_deny_member "$dest" compare after the         2 fail
  #       wildcard check is removed)
  #       (kills push-noop-config-remote-push-other-dest, whose configured refspec resolves to a
  #       non-default destination, and push-noop-config-commented-out, whose one REAL harmless
  #       key -- "push = feature/x" -- is a genuine, correctly-parsed remote.origin.push record
  #       that must NOT deny on its own; this is the mutant that actually exercises
  #       push-noop-config-commented-out's parsing, not M34 above. NOT RE-POINTED by #269; #290
  #       RE-MEASURED for the first time since this #268 round-1 80-case baseline, against the
  #       114-case push-* set: -> 112 pass, 2 fail — UNCHANGED failing set, +34 pass; no
  #       #290 fixture's benign remote.<name>.push record resolves to a non-default destination.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 114 pass, 2 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture's
  #       route resolves to a non-default destination either)
  #   M41 the n==1 config route removed ([ -n "$__deny_dest" ] || config_deny             -> 79 pass,
  #       "$scope_remote" -> ... || [ "$n" -eq 1 ] || config_deny "$scope_remote")          1 fail
  #       (kills only push-deny-config-remote-push-named-remote -- the n==1 positive control for
  #       exact-remote scoping. NOT RE-POINTED by #269; #290 RE-MEASURED for the first time since
  #       this #268 round-1 80-case baseline, against the 114-case push-* set: -> 113 pass,
  #       1 fail — UNCHANGED failing set, +34 pass; no #290 fixture exercises the n==1 config route.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture
  #       exercises the n==1 config route either)
  #   M42 the push.default LIST evaluation disabled entirely (if [ -n                    -> 102 pass,
  #       "$cfg_push_defaults" ]; then -> if [ -n "" ]; then)                              12 fail
  #       (HISTORICAL RECIPE, #268 round 1: "case "$cfg_push_default" in -> case "" in", against a
  #       scalar `case` statement that no longer exists after #290 turned cfg_push_default into the
  #       cfg_push_defaults LIST evaluated by a `while` loop -- restated above against the CURRENT
  #       code shape, same intent (disable the whole push.default route unconditionally); historical
  #       figure at the #268 round-1 80-case baseline: 77 pass, 3 fail, killing
  #       push-deny-config-push-default-upstream, push-deny-config-push-default-tracking, and
  #       push-deny-config-push-default-matching -- the only three deny fixtures whose config
  #       carries no remote.<name>.push record at all, so denying depends entirely on this route.
  #       NOT RE-POINTED by #269; #290 RE-MEASURED (with the restated recipe) against the CURRENT
  #       114-case push-* set: -> 102 pass, 12 fail — the same three historical cases plus NINE
  #       more: EIGHT of the sixteen new #290 fixtures whose deny depends on the push.default route
  #       with no remote.<name>.push record of its own (push-deny-global-gitconfig-upstream,
  #       push-deny-global-xdg-upstream, push-deny-global-xdg-home-default-upstream,
  #       push-deny-global-env-var-upstream, push-deny-global-default-matching,
  #       push-deny-global-benign-does-not-mask-repo-route,
  #       push-deny-global-overrides-benign-repo-route, push-deny-global-never-executes), plus ONE
  #       PRE-#290 fixture that also newly flips, push-deny-config-union-benign-refspec-plus-
  #       upstream: its remote.origin.push record resolves to a benign, non-denying destination, so
  #       its deny ALSO depends entirely on this route, same as the three historical cases -- an
  #       existing dependency this restated recipe now surfaces explicitly that the #268 round-1
  #       recipe's own citation never named. RE-MEASURED again for the #290 ROUND-2 KICKBACK
  #       against the CURRENT 116-case push-* set: -> 103 pass, 13 fail — the same twelve cases plus
  #       push-deny-global-two-defaults-one-file (F1): its deny depends entirely on the push.default
  #       route too (a global file, no remote.<name>.push record at all); push-deny-config-tab-in-
  #       value (F4) is unaffected, since its route is remote.<name>.push, never push.default)
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
  #       RE-MEASURED again for the #269 round-2 kickback against the then-current 98-case push-*
  #       set: -> 97 pass, 1 fail — unchanged failing set, +2 pass; D1's config also keeps the
  #       spaces around "=". RE-MEASURED again for #290 against the 114-case push-* set:
  #       -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass; no #290 fixture's config omits the
  #       spaces around "=" either. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the
  #       CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; neither
  #       new kickback fixture's config omits the spaces around "=" either)
  #   M44 the push.default route gated on git's OWN precedence instead of the RESOLVED    -> 113 pass,
  #       union (if [ -n "$cfg_push_defaults" ]; then -> if [ -z "$cfg_push_lines" ] &&      1 fail
  #       [ -n "$cfg_push_defaults" ]; then)
  #       (HISTORICAL RECIPE, #268 round-2 kickback: "case "$cfg_push_default" in -> if [ -z
  #       "$cfg_push_lines" ]; then case "$cfg_push_default" in ... esac; fi", against a scalar
  #       `case` statement that no longer exists after #290's cfg_push_defaults LIST rename --
  #       restated above against the CURRENT code shape, same intent (gate the whole push.default
  #       route on git's own precedence -- consulted only when the remote has no push refspec --
  #       instead of the RESOLVED union both routes are meant to get); historical figure at the
  #       then-current 83-case baseline: 82 pass, 1 fail, killing only
  #       push-deny-config-union-benign-refspec-plus-upstream -- its remote.origin.push record
  #       resolves to a NON-denying destination (feature/x), so $cfg_push_lines is non-empty and
  #       this mutant's precedence gate skips the push.default resolution entirely, even though
  #       push.default=upstream alone denies; every other push-default-* deny fixture has NO
  #       remote.<name>.push record at all, so $cfg_push_lines is empty for them and this mutant is
  #       inert. NOT RE-POINTED by #269; #290 RE-MEASURED (with the restated recipe) against the
  #       114-case push-* set: -> 113 pass, 1 fail — UNCHANGED failing set, +31 pass; none
  #       of the sixteen new #290 fixtures pairs a non-denying remote.<name>.push record with a
  #       denying push.default record on the SAME checkout. RE-MEASURED again for the #290 ROUND-2
  #       KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED failing
  #       set, +2 pass; neither new kickback fixture pairs a non-denying remote.<name>.push record
  #       with a denying push.default record on the same checkout either)
  # #268 round-3 kickback mutant (M45), measured against the then-current 84-case push-* set (the
  # 83-case baseline plus one more fixture, push-deny-config-union-other-remote-bare; grown to 98
  # by #269 below and its own round-2 kickback, then to 114 by #290, then to the CURRENT 116 by
  # #290's own round-2 kickback):
  #   M45 the n==1/n==0 scope gate narrowed from "every configured remote at n==0"       -> 83 pass,
  #       to "git's own default remote" (if [ -n "$scope" ] && [ "$sub" != "$scope" ];      1 fail
  #       then -> if [ "$sub" != "${scope:-origin}" ]; then)
  #       (kills only push-deny-config-union-other-remote-bare -- its config carries a denying
  #       remote.<name>.push record ONLY under a non-origin remote name ("backup"), plus a benign
  #       origin section with no push key at all; the shipped scope gate considers every remote's
  #       records at n==0 and denies, while this mutant narrows the n==0 scope to only the
  #       "origin" record, whose absence leaves nothing to deny on -- every other config deny
  #       fixture names "origin" as its offending remote, so this mutant is inert for them. NOT
  #       RE-POINTED by #269; #290 RE-MEASURED for the first time since this #268 round-3
  #       84-case baseline, against the 114-case push-* set: -> 113 pass, 1 fail —
  #       UNCHANGED failing set, +30 pass; no #290 fixture's config carries a denying
  #       remote.<name>.push record under a non-origin remote name. RE-MEASURED again for the #290
  #       ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED
  #       failing set, +2 pass; neither new kickback fixture's config carries a denying
  #       remote.<name>.push record under a non-origin remote name either)
  # #269's "-C <path>" resolution mutants (M46-M55), FIRST measured against the then-current
  # 96-case push-* set (the 84-case #268-round-3 baseline plus the twelve new #269 fixtures
  # directly below); each RE-MEASURED again for the #269 round-2 kickback against the then-current
  # 98-case push-* set (the 96-case baseline plus C2 and D1, added by that kickback — see M56/M57
  # below). Round-1 of this issue incorrectly claimed M46-M53, M55, M56, and M57 were ALL NOT
  # re-measured for #290, reasoning that none of their recipes touches the config-candidate list or
  # the push.default list #290 added. A verifier kickback (finding F3) measured every one of these
  # directly and found this false for M46 and M47 specifically — see their own entries below for
  # the corrected figures and mechanism. M48, M49, M50, M51, M52, M53, M55, M56, and M57 ARE
  # genuinely unaffected — each individually re-measured (not reasoned about) and confirmed to keep
  # its EXACT pre-#290 failing set — so their own "CURRENT 98-case" wording below is downgraded to
  # "the 98-case set" — an accurate historical label, not a current one, now that #290 and its own
  # round-2 kickback have grown the push-* set to the CURRENT 116:
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
  #       deny comes from its SECOND, "-C"-less segment. CORRECTED (verifier finding F3): round-1 of
  #       #290 wrongly claimed this recipe was unaffected by the config-candidate list without
  #       measuring it; RE-MEASURED against the #290 114-case push-* set: -> 106 pass, 8 fail — the
  #       same seven cases plus push-deny-c-target-global-route: that fixture's SESSION deliberately
  #       resolves NO repo at all (see the dated .claude/LESSONS.md entry), so the "-C" TARGET's own
  #       resolution -- which this mutant disables entirely -- is the ONLY path to its deny.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 108 pass, 8 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture uses
  #       "-C" at all)
  #   M47 the tokenizer's emitted "-C" field forced empty unconditionally (print "PUSH\t"         -> 89 pass,
  #       (ccount == 1 ? cpath : "") "\t" rest -> print "PUSH\t" "" "\t" rest)                     7 fail
  #       (kills the IDENTICAL seven-case set as M46 -- a different code site, the awk tokenizer
  #       rather than the bash resolution function, with the same observable effect: apply_c_target()
  #       never receives a real value to resolve. RE-MEASURED for the round-2 kickback: -> 91 pass,
  #       7 fail — unchanged failing set, +2 pass, same reason as M46 above. CORRECTED (verifier
  #       finding F3, identically to M46 above): RE-MEASURED against the #290 114-case push-* set:
  #       -> 106 pass, 8 fail — the same seven cases plus push-deny-c-target-global-route, for the
  #       identical reason M46 gains it (a different code site, the awk tokenizer's "-C" field,
  #       with the same observable effect). RE-MEASURED again for the #290 ROUND-2 KICKBACK against
  #       the CURRENT 116-case push-* set: -> 108 pass, 8 fail — UNCHANGED failing set, +2 pass;
  #       neither new kickback fixture uses "-C" at all)
  #   M48 the is_c_target_path() predicate call removed from apply_c_target() (every non-empty    -> 95 pass,
  #       "-C" value is resolved, regardless of shape)                                            1 fail
  #       (kills only push-noop-c-nonsibling-path -- its "../other-checkout" value has no
  #       "-wt-<n>" suffix at all and would otherwise never be resolved; every other fixture's
  #       "-C" value either already satisfies the predicate or is never emitted as a candidate.
  #       RE-MEASURED for the round-2 kickback: -> 97 pass, 1 fail — unchanged failing set, +2 pass.
  #       RE-MEASURED (per finding F3's directive to measure, not reason) against the #290 114-case
  #       push-* set: -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass. RE-MEASURED again for
  #       the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail —
  #       UNCHANGED failing set, +2 pass; neither new kickback fixture's "-C" value shape changes)
  #   M49 the tokenizer's "-C" match widened to also capture the ATTACHED "-C<path>" form (a      -> 95 pass,
  #       new branch inserted before the gopt_set check: substr(tok,1,2)=="-C" && tok!="-C")       1 fail
  #       (kills only push-noop-c-attached-form. RE-MEASURED for the round-2 kickback: -> 97 pass,
  #       1 fail — unchanged failing set, +2 pass. RE-MEASURED against the #290 114-case push-* set:
  #       -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass. RE-MEASURED again for the #290
  #       ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED
  #       failing set, +2 pass; neither new kickback fixture uses an attached "-C<path>" form)
  #   M50 the tokenizer's exactly-one-"-C" guard widened to "one or more" (ccount == 1 ->         -> 95 pass,
  #       ccount >= 1 in the emitted-field ternary -- the LAST "-C" token's value wins, since       1 fail
  #       cpath is overwritten on each "-C" occurrence)
  #       (kills only push-noop-c-double-c. RE-MEASURED for the round-2 kickback: -> 97 pass,
  #       1 fail — unchanged failing set, +2 pass. RE-MEASURED against the #290 114-case push-* set:
  #       -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass. RE-MEASURED again for the #290
  #       ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED
  #       failing set, +2 pass; neither new kickback fixture carries two "-C" tokens)
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
  #       returns before reaching it) and D1's own deny doesn't depend on current_branch either.
  #       RE-MEASURED against the #290 114-case push-* set: -> 111 pass, 3 fail — UNCHANGED failing
  #       set, +16 pass. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT
  #       116-case push-* set: -> 113 pass, 3 fail — UNCHANGED failing set, +2 pass; neither new
  #       kickback fixture uses "-C" at all)
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
  #       mutant discriminates it identically to B4, with no code having moved for this addition.
  #       RE-MEASURED against the #290 114-case push-* set: -> 112 pass, 2 fail — UNCHANGED failing
  #       set, +16 pass. RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT
  #       116-case push-* set: -> 114 pass, 2 fail — UNCHANGED failing set, +2 pass; neither new
  #       kickback fixture uses "-C" at all)
  #   M53 the deny-set union narrowed to fallback ∪ resolved only (the session's own default       -> 95 pass,
  #       branch line dropped from the union)                                                      1 fail
  #       (kills only push-deny-c-session-default-union -- the fixture whose deny is explained
  #       SOLELY by the session's own default branch staying in the union; every other deny
  #       fixture's session default either equals the resolved default already (A1/A3/B4) or is
  #       not what explains the deny at all (A2/A4/C1, decided by the RESOLVED default or config).
  #       RE-MEASURED for the round-2 kickback: -> 97 pass, 1 fail — unchanged failing set, +2
  #       pass; C2 never reaches this mutated line (its "-C" target never resolves) and D1's deny
  #       comes from its config-driven second segment, not this union. RE-MEASURED against the #290
  #       114-case push-* set: -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass. RE-MEASURED
  #       again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass,
  #       1 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture uses "-C" at all)
  #   M54 the resolved config not applied (the three cfg_push_lines/cfg_push_defaults/            -> 94 pass,
  #       cfg_branch_merge assignments re-pointed at the session_* copies instead of the            2 fail
  #       resolved_* locals -- #290 RE-POINTED: the middle assignment's variable name itself
  #       renamed, cfg_push_default -> cfg_push_defaults, same mutation intent)
  #       (kills push-deny-c-other-repo-config-route and push-noop-c-other-repo-ignores-session-
  #       config -- the only two fixtures whose verdict is decided by which checkout's config
  #       applies. RE-MEASURED for the round-2 kickback: -> 96 pass, 2 fail — unchanged failing
  #       set, +2 pass; neither C2 (no config at all) nor D1's second segment (cpath empty, an
  #       early return well before this mutated line) reaches this code. RE-MEASURED again for
  #       #290 (with the renamed variable) against the 114-case push-* set: -> 111 pass,
  #       3 fail — the same two historical cases plus ONE of the sixteen new #290 fixtures,
  #       push-deny-c-target-global-route, whose SESSION deliberately resolves to NO repo at all
  #       (so session_cfg_push_lines is empty), unlike every #269 "-C" deny fixture's session,
  #       which always resolves some repo of its own -- this is the one #290 fixture whose verdict
  #       genuinely depends on which checkout's config is applied at this assignment site, not
  #       merely on whether a repo resolved at all. RE-MEASURED again for the #290 ROUND-2 KICKBACK
  #       against the CURRENT 116-case push-* set: -> 113 pass, 3 fail — UNCHANGED failing set, +2
  #       pass; neither new kickback fixture uses "-C" at all)
  #   M55 the resolved default branch omitted from the deny-set union (the                        -> 94 pass,
  #       "[ -n "$resolved_default" ] && deny_set=..." line deleted)                                2 fail
  #       (kills push-deny-c-other-repo-explicit-develop and push-deny-c-never-executes -- the two
  #       fixtures whose deny depends on the RESOLVED checkout's own default branch, "develop",
  #       entering the union; A1/A3/B4's resolved default already equals the session's own, so
  #       dropping it changes nothing for them. RE-MEASURED for the round-2 kickback: -> 96 pass,
  #       2 fail — unchanged failing set, +2 pass; C2 never resolves a default at all and D1's
  #       first segment never denies regardless of this union, see M46 above. RE-MEASURED against
  #       the #290 114-case push-* set: -> 112 pass, 2 fail — UNCHANGED failing set, +16 pass.
  #       RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 114 pass, 2 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture uses
  #       "-C" at all)
  # #269 round-2 kickback mutants (M56-M57), measured against the 98-case push-* set (the 96-case
  # #269 baseline plus push-deny-c-unresolvable-never-executes (C2) and
  # push-deny-c-per-segment-session-reset (D1), the two fixtures this kickback adds; per finding
  # F3, individually RE-MEASURED (not reasoned about) against both the #290 114-case push-* set and
  # the CURRENT 116-case push-* set, and confirmed genuinely unaffected by every fixture #290 and
  # its own round-2 kickback added):
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
  #       only case that can discriminate this mutant. RE-MEASURED against the #290 114-case push-*
  #       set: -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass. RE-MEASURED again for the #290
  #       ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED
  #       failing set, +2 pass; neither new kickback fixture has more than one push segment)
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
  #       already have for the "-C" route generally. RE-MEASURED against the #290 114-case push-*
  #       set: -> 113 pass, 1 fail — UNCHANGED failing set, +16 pass. RE-MEASURED again for the #290
  #       ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1 fail — UNCHANGED
  #       failing set, +2 pass; neither new kickback fixture's "-C" target is unresolvable)
  # #290's global-config-candidate mutants (M58-M69), each FIRST measured against the #290
  # 114-case push-* set (the 98-case #269-round-2 baseline plus the sixteen new #290 fixtures
  # directly below); each RE-MEASURED again for the #290 ROUND-2 KICKBACK against the CURRENT
  # 116-case push-* set (the 114-case baseline plus push-deny-global-two-defaults-one-file (F1) and
  # push-deny-config-tab-in-value (F4), the two fixtures that kickback adds):
  #   M58 the whole global contribution removed (the config-candidate heredoc's                    -> 103 pass,
  #       $GIT_CONFIG_GLOBAL/$xdg_cfg/$home_cfg lines all deleted, leaving only                      11 fail
  #       $common/config)
  #       (kills ELEVEN of the sixteen new #290 fixtures -- every one whose deny depends on SOME
  #       global candidate resolving: push-deny-global-gitconfig-upstream, push-deny-global-xdg-
  #       upstream, push-deny-global-xdg-home-default-upstream, push-deny-global-env-var-upstream,
  #       push-deny-global-remote-push-refspec, push-deny-global-default-matching, push-deny-
  #       global-overrides-benign-repo-route, push-deny-global-env-var-union-not-replace, push-
  #       deny-global-two-files-first-denies, push-deny-c-target-global-route, and push-deny-
  #       global-never-executes; does NOT kill push-deny-global-benign-does-not-mask-repo-route
  #       (its deny comes from the REPO route alone) or any of the four no-opinion #290 controls.
  #       RE-MEASURED for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 104 pass, 12 fail — the same eleven cases plus push-deny-global-two-defaults-one-file
  #       (F1): its ONLY route is global too; push-deny-config-tab-in-value (F4) is unaffected,
  #       since its route is repo-local)
  #   M59 the $GIT_CONFIG_GLOBAL candidate branch removed (the heredoc's                            -> 112 pass,
  #       "${GIT_CONFIG_GLOBAL:-}" line deleted)                                                      2 fail
  #       (kills push-deny-global-env-var-upstream, whose ONLY denying route is
  #       $GIT_CONFIG_GLOBAL itself (HOME has no .gitconfig), and push-deny-global-two-files-
  #       first-denies, whose $GIT_CONFIG_GLOBAL-pointed file is the denier read FIRST.
  #       RE-MEASURED for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 114 pass, 2 fail — UNCHANGED failing set, +2 pass; neither new kickback fixture uses
  #       $GIT_CONFIG_GLOBAL)
  #   M60 the $HOME/.gitconfig candidate branch removed (the heredoc's "$home_cfg"                  -> 107 pass,
  #       line deleted)                                                                               7 fail
  #       (kills every #290 fixture whose ONLY or FIRST-READ denying route lives at
  #       $HOME/.gitconfig specifically: push-deny-global-gitconfig-upstream, push-deny-global-
  #       remote-push-refspec, push-deny-global-default-matching, push-deny-global-overrides-
  #       benign-repo-route, push-deny-global-env-var-union-not-replace (the "denier read LAST"
  #       fixture -- its denying route lives at $HOME/.gitconfig), push-deny-c-target-global-route,
  #       and push-deny-global-never-executes; does NOT kill push-deny-global-two-files-first-
  #       denies, whose denier is $GIT_CONFIG_GLOBAL, read first and unaffected by this mutant.
  #       RE-MEASURED for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 108 pass, 8 fail — the same seven cases plus push-deny-global-two-defaults-one-file
  #       (F1): its denying record lives at $HOME/.gitconfig specifically too)
  #   M61 the XDG git config candidate branch removed entirely (the heredoc's                       -> 112 pass,
  #       "$xdg_cfg" line deleted)                                                                    2 fail
  #       (kills push-deny-global-xdg-upstream and push-deny-global-xdg-home-default-upstream --
  #       the two fixtures whose ONLY denying route is the XDG candidate, explicit and default-path
  #       respectively. RE-MEASURED for the #290 ROUND-2 KICKBACK against the CURRENT 116-case
  #       push-* set: -> 114 pass, 2 fail — UNCHANGED failing set, +2 pass; neither new kickback
  #       fixture uses the XDG candidate)
  #   M62 the XDG-unset default path removed (the "elif [ -n \"${HOME:-}\" ]; then                  -> 113 pass,
  #       xdg_cfg=\"$HOME/.config/git/config\"; fi" branch deleted)                                   1 fail
  #       (kills only push-deny-global-xdg-home-default-upstream -- the fixture that leaves
  #       $XDG_CONFIG_HOME unset specifically to pin this default-path branch; does NOT kill
  #       push-deny-global-xdg-upstream, which sets $XDG_CONFIG_HOME explicitly and so never
  #       reaches this branch at all. RE-MEASURED for the #290 ROUND-2 KICKBACK against the CURRENT
  #       116-case push-* set: -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; neither new
  #       kickback fixture uses the XDG candidate either)
  #   M63 the per-file loop stopping at the FIRST missing candidate (the "[ -f              -> 85 pass,
  #       \"$cfgf\" ] || continue" line changed to "|| break")                               29 fail
  #       (CORRECTED, verifier finding F2b: round-1 of #290 claimed this mutant kills "every
  #       push-deny-config-* fixture (repo-local routes) plus every push-deny-global-* deny fixture
  #       except push-deny-global-benign-does-not-mask-repo-route" -- measured (not reasoned about)
  #       against the #290 114-case push-* set, the ACTUAL twenty-nine-case failing set is: every
  #       push-deny-config-* fixture (repo-local routes: remote-push-bare, remote-push-named-remote,
  #       remote-push-second-line, push-default-upstream, push-default-tracking, push-default-
  #       matching, wildcard-refspec, crlf-line, crlf-interior, worktree-commondir, no-space-assign,
  #       no-trailing-newline, mixed-case, never-executes, union-benign-refspec-plus-upstream,
  #       union-other-remote-bare -- SIXTEEN total), every push-deny-global-* deny fixture except
  #       push-deny-global-two-files-first-denies (TEN: gitconfig-upstream, xdg-upstream, xdg-
  #       home-default-upstream, env-var-upstream, remote-push-refspec, default-matching, benign-
  #       does-not-mask-repo-route, overrides-benign-repo-route, env-var-union-not-replace, and
  #       never-executes), and THREE push-deny-c-*
  #       fixtures the round-1 claim omitted entirely: push-deny-c-other-repo-config-route,
  #       push-deny-c-per-segment-session-reset, and push-deny-c-target-global-route (each denies
  #       via a config route this mutant's break can also strand, whether on the SESSION's own
  #       resolve_repo() call or a resolved "-C" target's). The actual EXCEPTION is
  #       push-deny-global-two-files-first-denies, not push-deny-global-benign-does-not-mask-repo-
  #       route: with the default fixture HOME (no override) empty, the FIRST non-blank candidate
  #       most fixtures reach is $HOME/.config/git/config (the XDG default path), which does not
  #       exist there, so the loop breaks before ever reaching $HOME/.gitconfig or $common/config
  #       -- a single missing candidate silently disables every LATER candidate in the list,
  #       including the repo-local one; this is exactly the coarse, near-M26-sized failure this
  #       mutant is meant to demonstrate. push-deny-global-two-files-first-denies is spared only
  #       because its $GIT_CONFIG_GLOBAL candidate -- the FIRST non-blank one in the list -- is
  #       itself the denier and already exists, so it is read in full BEFORE the break (at the
  #       next, missing candidate) ever fires; push-deny-global-benign-does-not-mask-repo-route is
  #       NOT spared, since its own denying record lives in the REPO-local $common/config, the
  #       LAST candidate, never reached once the break fires at the second candidate. RE-MEASURED
  #       for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 85 pass, 31
  #       fail — the same twenty-nine cases plus BOTH new kickback fixtures, push-deny-global-two-
  #       defaults-one-file (F1, a global deny fixture reached only past the break point) and
  #       push-deny-config-tab-in-value (F4, a repo-local deny fixture reached only past the break
  #       point too))
  #   M64 the per-file loop stopping AFTER the first EXISTING candidate (an                          -> 106 pass,
  #       unconditional "break" added immediately after "done < \"$cfgf\"")                            8 fail
  #       (kills EIGHT of the sixteen new #290 fixtures, in two mechanically distinct groups sharing
  #       one root cause -- once ANY candidate exists and is read, this mutant stops before reading
  #       every LATER candidate, silently dropping whatever route a later file would have supplied:
  #       (1) FIVE fixtures whose denying push.default=upstream route lives in the SAME single
  #       global file this mutant reads first, but whose DESTINATION resolution also needs
  #       branch.<current>.merge, which lives only in the REPO-local $common/config, always the
  #       LAST candidate and so never reached: push-deny-global-gitconfig-upstream, push-deny-
  #       global-xdg-upstream, push-deny-global-xdg-home-default-upstream, push-deny-global-env-
  #       var-upstream, and push-deny-global-overrides-benign-repo-route (the GLOBAL upstream
  #       record denies, but its branch.merge lives in the repo config, never reached); (2) THREE
  #       fixtures whose FIRST EXISTING candidate is a BENIGN file, with the actual denying route
  #       in a LATER candidate this mutant never reaches: push-deny-global-benign-does-not-mask-
  #       repo-route (the GLOBAL file read first is benign "current"; the REPO's own denying
  #       "upstream" in $common/config, read last, is never reached), push-deny-global-env-var-
  #       union-not-replace ($GIT_CONFIG_GLOBAL, read first, is benign; $HOME/.gitconfig's denying
  #       remote route is never reached), and push-deny-global-never-executes (same class as group
  #       1 -- listed separately only because its own case also pins the never-executes property).
  #       Does NOT kill push-deny-global-remote-push-refspec or push-deny-global-default-matching
  #       (each fixture's ONE route is fully self-contained in the single file this mutant DOES
  #       read -- neither remote.<name>.push nor push.default=matching ever consults
  #       branch.<current>.merge), push-deny-global-two-files-first-denies (its denying
  #       $GIT_CONFIG_GLOBAL file IS the first existing candidate, already fully read before the
  #       break fires), or push-deny-c-target-global-route (the "-C" TARGET's own resolve_repo()
  #       call finds its one denying $HOME/.gitconfig record as the first existing candidate,
  #       already fully read; its target has no local config of its own to lose). RE-MEASURED for
  #       the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 107 pass, 9 fail —
  #       the same eight cases plus push-deny-global-two-defaults-one-file (F1): its denying record
  #       is read as the first EXISTING candidate ($HOME/.gitconfig), so this mutant's break fires
  #       immediately after it, before ever reaching $common/config for cfg_branch_merge -- group
  #       (1)'s exact mechanism; push-deny-config-tab-in-value (F4) is unaffected, since it is
  #       repo-local and never reaches a global candidate at all)
  #   M65 cfg_push_defaults collapsed to a last-wins SCALAR (the accumulating                        -> 113 pass,
  #       "cfg_push_defaults=\"${cfg_push_defaults}...\"" assignment narrowed to a plain              1 fail
  #       overwrite, "cfg_push_defaults=\"${cfg_src}...\"", dropping the leading
  #       "${cfg_push_defaults}" so only the LAST "[push] default = ..." line parsed survives)
  #       (kills only push-deny-global-overrides-benign-repo-route -- its LAST-parsed push.default
  #       record (the REPO's own, benign "current", read after the GLOBAL's denying "upstream" in
  #       file-list order) silently overwrites the denying one under this mutant; does NOT kill
  #       push-deny-global-benign-does-not-mask-repo-route, whose LAST-parsed record (the REPO's
  #       own denying "upstream") already IS the one that must survive, so a last-wins collapse is
  #       inert for it. RE-MEASURED for the #290 ROUND-2 KICKBACK against the CURRENT 116-case
  #       push-* set: -> 114 pass, 2 fail — the same case plus push-deny-global-two-defaults-
  #       one-file (F1, finding F1's own discriminating mutant): its FIRST-accumulated record (the
  #       GLOBAL file's own "upstream", read before that SAME file's later "current" line) is what
  #       must survive to deny; under a last-wins collapse, only the LAST line parsed overall
  #       survives, which (no OTHER push.default record exists in this fixture) is that same file's
  #       own "current" -- silently losing the deny. push-deny-config-tab-in-value (F4) is
  #       unaffected, since it uses remote.<name>.push, never push.default, at all)
  #   M66 config_deny()'s push-default loop evaluating only the FIRST value (an                      -> 113 pass,
  #       unconditional "break" added at the end of the while loop's body, right                       1 fail
  #       before "done <<CFGEOF")
  #       (kills only push-deny-global-benign-does-not-mask-repo-route -- its FIRST-accumulated
  #       record (the GLOBAL's benign "current") is evaluated and the loop stops there, never
  #       reaching the REPO's own denying "upstream" record that follows it; does NOT kill push-
  #       deny-global-overrides-benign-repo-route, whose FIRST-accumulated record (the GLOBAL's
  #       denying "upstream") already denies on its own, so stopping after it changes nothing.
  #       RE-MEASURED for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set:
  #       -> 115 pass, 1 fail — UNCHANGED failing set, +2 pass; push-deny-global-two-defaults-
  #       one-file's own FIRST-accumulated record ("upstream") already denies on its own, so
  #       stopping after it (as this mutant does) changes nothing for that fixture either -- the
  #       same reason push-deny-global-overrides-benign-repo-route is unaffected)
  #   M67 __deny_src forced to ".git/config" unconditionally (the case "$cfgf"                       -> 113 pass,
  #       in ... esac source-label arms both assign ".git/config")                                    1 fail
  #       (kills only push-deny-global-gitconfig-upstream -- the fixture whose inline assertion
  #       checks the deny message names the GLOBAL label, "your global git config"; every other
  #       fixture either asserts no source label at all or (push-deny-global-benign-does-not-mask-
  #       repo-route) asserts ".git/config", which this mutant does not disturb. RE-MEASURED for
  #       the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 114 pass, 2 fail —
  #       the same case plus push-deny-global-two-defaults-one-file (F1): its own inline assertion
  #       likewise checks the GLOBAL label, "your global git config", which this mutant never
  #       produces)
  #   M68 __deny_src forced to "your global git config" unconditionally (the case                    -> 113 pass,
  #       "$cfgf" in ... esac source-label arms both assign "your global git config")                 1 fail
  #       (kills only push-deny-global-benign-does-not-mask-repo-route -- the fixture whose inline
  #       assertion checks the deny message names the REPO label, ".git/config"; does NOT kill
  #       push-deny-global-gitconfig-upstream, whose own inline assertion checks the GLOBAL label,
  #       which this mutant still produces. RE-MEASURED for the #290 ROUND-2 KICKBACK against the
  #       CURRENT 116-case push-* set: -> 114 pass, 2 fail — the same case plus push-deny-config-
  #       tab-in-value (F4): its own inline assertion checks the REPO-LOCAL label, ".git/config",
  #       which this mutant never produces; push-deny-global-two-defaults-one-file (F1) is
  #       unaffected, since its own inline assertion checks the GLOBAL label, which this mutant
  #       still produces)
  #   M69 the global candidates dropped for a resolved "-C" segment specifically                     -> 113 pass,
  #       (immediately after computing $home_cfg, "if [ \"$2\" = \"1\" ]; then                        1 fail
  #       GIT_CONFIG_GLOBAL=\"\"; xdg_cfg=\"\"; home_cfg=\"\"; fi" -- MAX_DEPTH is exactly
  #       "1" only on the per-"-C"-segment resolve_repo() call, never the session's own
  #       MAX_DEPTH-64 call)
  #       (kills only push-deny-c-target-global-route -- the one #290 fixture whose SESSION
  #       deliberately resolves to NO repo at all (so it independently reads no global config of
  #       its own), isolating that the deny comes SOLELY from the "-C" TARGET's own resolution
  #       reading the same global files; every other #290 fixture's session DOES resolve an
  #       ordinary repo, so it would independently pick up the identical global route regardless of
  #       this mutant, which is exactly why this fixture's session was deliberately built with no
  #       repo at all -- see this fixture's own case_pd_c_target_global_route() comment. RE-MEASURED
  #       for the #290 ROUND-2 KICKBACK against the CURRENT 116-case push-* set: -> 115 pass, 1
  #       fail — UNCHANGED failing set, +2 pass; neither new kickback fixture uses "-C" at all)
  # M70 (below, the #290 ROUND-2 KICKBACK's own new mutant, finding F4) reverts BOTH sites of the
  # F4 field-order fix together -- the cfg_push_lines record write (back to
  # "${cfg_subsection}${cfg_tab}${cfg_val}${cfg_tab}${cfg_src}") and config_deny()'s split (back to
  # reading sub/refspec/src in that order, with refspec bounded and src the unbounded tail) -- since
  # reverting only one site while the other still reads/writes the NEW order would misinterpret
  # every field, not just corrupt the source label the way the original defect did:
  #   M70 F4's field-order fix reverted (cfg_push_lines record back to                               -> 115 pass,
  #       "sub<TAB>val<TAB>src", both the write in the "remote" case arm and the read              1 fail
  #       in config_deny(), together)
  #       (kills only push-deny-config-tab-in-value (F4) -- with src back on the record's UNBOUNDED
  #       tail, the value's own embedded TAB byte again truncates the BOUNDED refspec field at that
  #       TAB and leaks its own remainder ("junklabel") into the source-label field, exactly the
  #       pre-fix defect finding F4 named; no other fixture's config value contains a literal TAB
  #       byte, so this mutant is inert for every one of them)
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
  # #327: the cdg-* section further below runs ONLY hooks/claude-dir-guard.sh, via its own
  # run_claude_guard -- no mutant M1-M70 in THIS table edits that file, so this table's recorded
  # failing sets are unchanged by that addition, and its whole-file PASS figures above all predate
  # it. Made non-vacuous, not just reasoned by inspection (LESSON 2026-09-15): M16
  # (PUSH_DEFAULT_BRANCH_FALLBACK emptied) re-run against the then-current 230-case file (re-measured
  # after the #327 round-1 kickback's two new cdg-* fixtures) still fails exactly
  # push-deny-origin-master/push-deny-c-per-segment-session-reset/push-deny-c-target-global-route
  # (227 pass, 3 fail) with NO cdg-* case among them.
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
  "push-deny-c-never-executes|case_pd_c_never_executes|deny via the -C resolution route, AND push-guard.sh never invokes git/gh/rm/dirname on the booby-trapped PATH, AND BOTH the session repo's and the resolved -C target's file listings are byte-identical before/after (C1, A2's shape; \"dirname\" added to the trap in the #269 round-2 kickback, harmless here since this fixture's -C target resolves at depth 0 -- see M57 below and C2) -- measured: M46, 89 pass 7 fail (also M47, 89 pass 7 fail; also M55, 94 pass 2 fail); NOT flipped by M57 (measured: 97 pass 1 fail against the 98-case set, not re-measured for #290 -- this fixture's -C target resolves at depth 0 and never reaches the ascent guard M57 removes; see C2 below, which does)"
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
  "push-deny-config-tab-in-value|case_pd_config_tab_in_value|deny: [remote \"origin\"] push = refs/heads/*:refs/heads/*<TAB>junklabel (#290 kickback finding F4 -- a literal TAB byte inside a configured value must not corrupt the two-literal source label) -- measured: M70, 115 pass 1 fail (also M32, 114 pass 2 fail; also M63, 85 pass 31 fail; also M68, 114 pass 2 fail, the inline source-label assertion)"
  "push-noop-config-neither-key|case_pn_config_neither_key|no opinion: config sets NEITHER remote.<name>.push nor push.default at all (the decision's required control) -- measured: not flipped by M26-M45 (this fixture's config never reaches any of the twenty mutated clauses)"
  "push-noop-config-remote-push-other-dest|case_pn_config_remote_push_other_dest|no opinion: [remote \"origin\"] push = HEAD:refs/heads/feature/x (a configured refspec whose destination is not the default branch) -- measured: M40, 78 pass 2 fail (with push-noop-config-commented-out)"
  "push-noop-config-other-remote-named|case_pn_config_other_remote_named|no opinion: [remote \"origin\"] push = HEAD:main, command git push backup (n==1 exact remote scoping -- a DIFFERENT remote's own push route must not apply) -- measured: M27, 79 pass 1 fail"
  "push-noop-config-explicit-refspec|case_pn_config_explicit_refspec|no opinion: git push -u origin \"claude/17-a\" against a repo whose config carries push = HEAD:main (n>=2 -- config routes are NEVER consulted here; a deny would be a release blocker) -- measured: M39, 79 pass 1 fail"
  "push-noop-config-branch-other|case_pn_config_branch_other|no opinion: push.default=upstream but [branch \"other\"] merge=refs/heads/main -- current branch (feature/x) has no section of its own -- measured: M28, 79 pass 1 fail"
  "push-noop-config-commented-out|case_pn_config_commented_out|no opinion: a #-commented push line, a ;-commented push.default line, and odd leading whitespace on the one real harmless key -- measured: M40, 78 pass 2 fail (with push-noop-config-remote-push-other-dest); NOT flipped by M34, 80 pass 0 fail (the comment strip's absence is masked by exact-key matching -- see M34's own table entry)"
  "push-noop-config-push-default-current|case_pn_config_push_default_current|no opinion: [push] default = current + a branch section that WOULD deny if this mode were mistaken for upstream (the sharp form of the mode-check clause) -- measured: M29, 77 pass 3 fail (with push-noop-config-push-default-simple)"
  "push-noop-config-push-default-simple|case_pn_config_push_default_simple|no opinion: [push] default = simple, git's own default mode, same branch-section trap as push-default-current -- measured: M29, 77 pass 3 fail (with push-noop-config-push-default-current)"
  "push-deny-global-gitconfig-upstream|case_pd_global_gitconfig_upstream|deny: GLOBAL \$HOME/.gitconfig carries [push] default = upstream, repo config carries only a [branch] merge record (per-path 1/4); also asserts inline the deny message names the GLOBAL source label -- measured: M58, 103 pass 11 fail (also M67, 113 pass 1 fail, the inline source-label assertion)"
  "push-deny-global-xdg-upstream|case_pd_global_xdg_upstream|deny: explicit \$XDG_CONFIG_HOME/git/config carries [push] default = upstream, neutral HOME (per-path 2/4) -- measured: M58, 103 pass 11 fail (also M61, 112 pass 2 fail)"
  "push-deny-global-xdg-home-default-upstream|case_pd_global_xdg_home_default_upstream|deny: \$XDG_CONFIG_HOME UNSET, [push] default = upstream at the DEFAULT \$HOME/.config/git/config path (per-path 3/4) -- measured: M62, 113 pass 1 fail (also M58, 103 pass 11 fail; also M61, 112 pass 2 fail)"
  "push-deny-global-env-var-upstream|case_pd_global_env_var_upstream|deny: \$GIT_CONFIG_GLOBAL points at a fixture file OUTSIDE HOME, [push] default = upstream (per-path 4/4) -- measured: M59, 112 pass 2 fail (also M58, 103 pass 11 fail)"
  "push-deny-global-remote-push-refspec|case_pd_global_remote_push_refspec|deny: GLOBAL [remote \"origin\"] push = HEAD:main, repo has NO config file at all -- measured: M58, 103 pass 11 fail (also M60, 107 pass 7 fail; also M26, 84 pass 30 fail)"
  "push-deny-global-default-matching|case_pd_global_default_matching|deny: GLOBAL [push] default = matching, unconditional, no [branch] section anywhere -- measured: M58, 103 pass 11 fail (also M60, 107 pass 7 fail; also M29, 109 pass 5 fail; also M31, 112 pass 2 fail)"
  "push-deny-global-benign-does-not-mask-repo-route|case_pd_global_benign_does_not_mask_repo_route|deny: a benign GLOBAL push.default=current must not mask a denying REPO push.default=upstream (the \"evaluate every value\" discriminator); also asserts inline the deny message names the REPO source label -- measured: M66, 115 pass 1 fail (also M68, 114 pass 2 fail, the inline source-label assertion; also M29, 111 pass 5 fail -- this fixture still denies under M29, via the GLOBAL record, and fails only its own inline source-label assertion, see M29's own table entry)"
  "push-deny-global-two-defaults-one-file|case_pd_global_two_defaults_one_file|deny: [push] default = upstream THEN, on the next line, default = current, both inside the SAME global file (#290 kickback finding F1 -- git's own last-wins-within-a-file resolves this to \"current\" and would not deny; this hook evaluates every line and denies via the FIRST, \"upstream\"); also asserts inline the deny message names push.default=upstream via the global source label -- measured: M65, 114 pass 2 fail (also M14, 99 pass 17 fail; also M26, 84 pass 32 fail; also M42, 103 pass 13 fail; also M58, 104 pass 12 fail; also M60, 108 pass 8 fail; also M63, 85 pass 31 fail; also M64, 107 pass 9 fail; also M67, 114 pass 2 fail, the inline source-label assertion)"
  "push-deny-global-overrides-benign-repo-route|case_pd_global_overrides_benign_repo_route|deny: a denying GLOBAL push.default=upstream still denies over a benign REPO push.default=current (documented over-block -- real git would honour the repo's \"current\" alone) -- measured: M65, 113 pass 1 fail (also M58, 103 pass 11 fail; also M60, 107 pass 7 fail)"
  "push-deny-global-env-var-union-not-replace|case_pd_global_env_var_union_not_replace|deny: \$GIT_CONFIG_GLOBAL set to a BENIGN file, \$HOME/.gitconfig (real git would never consult it once \$GIT_CONFIG_GLOBAL is set) still denies -- union-not-replace over-block, denier read LAST -- measured: M60, 107 pass 7 fail (also M58, 103 pass 11 fail)"
  "push-deny-global-two-files-first-denies|case_pd_global_two_files_first_denies|deny: \$GIT_CONFIG_GLOBAL (read first) denies, \$HOME/.gitconfig (read after it) is benign -- denier read FIRST, the 2+ boundary's other half -- measured: M59, 112 pass 2 fail (also M58, 103 pass 11 fail)"
  "push-deny-c-target-global-route|case_pd_c_target_global_route|deny: a resolved \"-C\" segment still sees the GLOBAL routes (session resolves NO repo at all; the \"-C\" target has its own default and no config of its own) -- measured: M69, 113 pass 1 fail (also M58, 103 pass 11 fail; also M60, 107 pass 7 fail; also M54, 111 pass 3 fail -- the only #290 fixture that mutant discriminates)"
  "push-deny-global-never-executes|case_pd_global_never_executes|deny via a GLOBAL route, AND push-guard.sh never invokes git/gh/rm/dirname on the booby-trapped PATH, AND BOTH the fixture repo's and the fixture HOME's file listings are byte-identical before/after -- measured: M58, 103 pass 11 fail (also M26, 84 pass 30 fail)"
  "push-noop-global-upstream-no-tracking|case_pn_global_upstream_no_tracking|no opinion: GLOBAL [push] default = upstream, current branch claude/17-a, NO [branch] section anywhere (honest-scope control) -- measured: not flipped by M14-M69 (this fixture's [branch] section is absent everywhere, so refspec_dest() of an empty branch.merge always yields no destination regardless of how push.default is parsed or which file supplies it)"
  "push-noop-global-explicit-refspec|case_pn_global_explicit_refspec|no opinion: git push -u origin \"claude/17-a\" (release-blocker control, bare) against a GLOBAL config carrying BOTH a denying remote.origin.push AND push.default=matching -- config is never consulted for an explicit refspec -- measured: M39, 111 pass 3 fail (with push-noop-config-explicit-refspec and push-noop-global-explicit-refspec-c)"
  "push-noop-global-explicit-refspec-c|case_pn_global_explicit_refspec_c|no opinion: git -C <wt> push -u origin \"claude/17-a\" (release-blocker control, the \"-C\" variant) against the SAME denying GLOBAL config -- measured: M39, 111 pass 3 fail (with push-noop-config-explicit-refspec and push-noop-global-explicit-refspec)"
  "push-noop-global-none-present|case_pn_global_none_present|no opinion: a dedicated, empty fixture HOME with no .gitconfig/.config/git/config, XDG_CONFIG_HOME and GIT_CONFIG_GLOBAL both unset, repo config absent (the \"none present\" boundary AND this file's own isolation positive control) -- measured: not flipped by M14-M69 (this fixture's dedicated HOME has no candidate file at all, so no mutant in this table -- none of which invents a route from a file that does not exist -- can produce a deny here)"
  # --- hooks/claude-dir-guard.sh (#327) cases -----------------------------------------------------
  # Mutation-proof table (LESSON 2026-09-01/2026-09-07(b), one mutant per classifier clause,
  # applied in place with an immediately-refreshed backup and a full `diff` verify after every
  # restore -- LESSON 2026-09-07), measured against THIS section's own 31-case set (29 plus the
  # #327 round-1 kickback's two embedded-LF fixtures, K1) embedded in the then-current 230-case whole
  # file (a fresh mktemp copy of hooks/claude-dir-guard.sh, never `mv`-ed over -- LESSON 2026-09-15b's
  # exec-bit concern does not apply here, since run_claude_guard always invokes the script through
  # an explicit `bash <path>`, never by PATH lookup); M1-M13 were RE-MEASURED against the
  # then-current 230-case file for the round-1 kickback (LESSON 2026-09-15 -- reasoning by inspection undercounted
  # M10's own kill set, below):
  #   M1  role resolution forced to "implementer" regardless of match                -> 228 pass,
  #       (role="" -> role="implementer", unconditionally)                              2 fail
  #       (kills cdg-noop-unrecognised-agent and cdg-noop-empty-agent -- a genuinely unrecognised
  #       or empty agent_type no longer exits "no opinion" early; every already-matching
  #       implementer/verifier case is unaffected, since role only ever changes the DENY MESSAGE
  #       text, never the policy itself)
  #   M2  fast path deleted (*agent_type*) widened to *) so it always matches         -> 230 pass,
  #       0 fail -- NOT FLIPPED (a measured finding, not an oversight): every payload that reaches
  #       jq via the fast path already re-derives the identical "no opinion" from an empty/absent
  #       .agent_type extraction, exactly the redundancy hooks/agent-boundary.sh's own M1/M2-class
  #       fast paths do NOT have (there, breaking a fast path is coarse and flips every deny case,
  #       since jq is never reached to re-derive the verdict another way)
  #   M3  the GUARDED_TOOLS membership check disabled (always matches)               -> 229 pass,
  #                                                                                      1 fail
  #       (kills cdg-noop-wrong-tool only)
  #   M4  the permission_mode == "plan" check disabled                               -> 229 pass,
  #                                                                                      1 fail
  #       (kills cdg-noop-plan-mode only)
  #   M5  the CR strip disabled (p="${file_path//$cr/}" -> p="$file_path")           -> 229 pass,
  #                                                                                      1 fail
  #       (kills cdg-deny-crlf only)
  #   M6  the backslash-to-slash separator normalisation disabled (p="${p//\\//}"    -> 229 pass,
  #       -> p="$p")                                                                    1 fail
  #       (kills cdg-deny-backslash only)
  #   M7  the case-insensitive bracket classes narrowed to a bare lowercase literal  -> 229 pass,
  #       (*/.[Cc][Ll][Aa][Uu][Dd][Ee]/* -> */.claude/*)                                1 fail
  #       (kills cdg-deny-case-variant only)
  #   M8  the classifier's leading+trailing slash boundary wrap removed              -> 228 pass,
  #       (case "/$p/" in -> case "$p" in)                                              2 fail
  #       (kills cdg-deny-final-segment and cdg-deny-rel-claude -- the two shapes whose own
  #       natural string has no PRE-EXISTING "/" immediately before ".claude": a final segment
  #       with nothing after it, and a relative path whose FIRST segment is ".claude". Every other
  #       deny-claude fixture's path already contains a naturally-occurring "/.claude/" substring
  #       without either boundary character added, so this mutant is inert for them -- INCLUDING
  #       cdg-deny-lf-claude, whose ".claude" segment is likewise naturally bounded by real "/"
  #       characters on both sides; re-measured directly, not merely reasoned by analogy.)
  #   M9  the segment match widened to a bare substring test                         -> 228 pass,
  #       (*/.[Cc][Ll][Aa][Uu][Dd][Ee]/* -> *[Cc][Ll][Aa][Uu][Dd][Ee]*)                  2 fail
  #       (kills cdg-noop-claude-backup and cdg-noop-my-claude -- the two near-miss fixtures whose
  #       segment CONTAINS, but does not EQUAL, ".claude")
  #  M10  the absoluteness check's deny arm disabled (the trailing "*)" case          -> 228 pass,
  #       becomes a no-op)                                                              2 fail
  #       (kills cdg-deny-rel-plain AND cdg-deny-lf-unclassifiable -- the two fixtures whose deny
  #       verdict depends solely on this clause, not the ".claude" segment class checked earlier;
  #       re-measured for the round-1 kickback -- cdg-deny-lf-unclassifiable is the SAME
  #       no-".claude"/relative shape as cdg-deny-rel-plain, so this mutant flips both, a kill-set
  #       widening LESSON 2026-09-15 warns reasoning-by-inspection alone would have missed)
  #  M11  the ".." segment check's deny arm disabled (the trailing "*)" case          -> 229 pass,
  #       becomes a no-op)                                                              1 fail
  #       (kills cdg-deny-dotdot-no-claude only -- cdg-deny-dotdot-claude denies earlier, via the
  #       ".claude" segment class, and never reaches this clause at all; cdg-deny-lf-unclassifiable
  #       carries no ".." segment, so it is unaffected by this mutant, unlike M10 above)
  #  M12  every "exit 2" in the classifier changed to "exit 0"                        -> 211 pass,
  #                                                                                     19 fail
  #       (coarse -- like hooks/agent-boundary.sh's own M1/M2, this silences EVERY deny verdict at
  #       once, so it only distinguishes an intended-deny case from everything else, never one
  #       deny case from another: kills every cdg-deny-* case (now including cdg-deny-lf-claude and
  #       cdg-deny-lf-unclassifiable) plus cdg-never-executes-deny and cdg-writes-nothing, i.e.
  #       every fixture whose correct verdict is "deny")
  #  M13  the AGENT_TYPES_VERIFIER="..." line deleted entirely                        -> 226 pass,
  #                                                                                      4 fail
  #       (kills cdg-deny-verif-write-ns, cdg-deny-verif-edit-bare, cdg-noop-verifier-mutation-probe
  #       -- the verifier-role fixtures, which no longer resolve a role at all -- AND
  #       cdg-noop-unrecognised-agent: with the variable gone entirely, referencing
  #       $AGENT_TYPES_VERIFIER for ANY non-empty, IMPLEMENTER-non-matching agent_type -- not just
  #       a genuine "verifier" spelling -- trips this script's own `set -uo pipefail` "unbound
  #       variable" abort; cdg-noop-empty-agent is unaffected, since an EMPTY agent_type never
  #       enters the `[ -n "$agent_type" ]` block that references the deleted variable at all)
  #  M14  the print-only LF-fold reverted (p_disp="${p//$lf/\\n}" -> p_disp="$p") (#327 round-1
  #       kickback K1, new this round)                                                -> 228 pass,
  #                                                                                       2 fail
  #       (kills cdg-deny-lf-claude and cdg-deny-lf-unclassifiable -- both fixtures' deny verdict is
  #       unaffected (the classifier still matches $p, unchanged by this mutant), but the printed
  #       message reverts to embedding the raw LF byte, so expect_cdg_deny_claude/
  #       expect_cdg_deny_unclassifiable's "exactly 1 non-blank stderr line" assertion now sees 2)
  # Five fixtures are, verified by direct measurement, NOT flipped by any of M1-M14:
  # cdg-noop-ordinary-abs and cdg-never-executes-noop (the identical "ordinary absolute path, no
  # .claude/".." segment" shape, with and without the booby-trapped PATH) survive every mutant in
  # this table, since none of M1-M14 makes an ordinary path deny; cdg-noop-main-session-lessons
  # carries no `agent_type` substring at all, so it never reaches past the fast path regardless of
  # which downstream check M1-M14 breaks; cdg-noop-malformed-json's failure mode is jq's own parse
  # error, independent of which check runs afterward; and cdg-noop-missing-file-path exits before
  # the classifier itself ever runs, on every mutant in this table (none of M1-M14 touches the
  # `[ -n "$file_path" ] || exit 0` gate). Their row states this instead of citing a mutant that
  # was never observed to fail them.
  "cdg-deny-impl-write-bare|case_cdg_deny_impl_write_bare|.claude deny: implementer (bare), Write, /repo/.claude/settings.json -- measured: M12, 211 pass 19 fail"
  "cdg-deny-impl-edit-ns|case_cdg_deny_impl_edit_ns|.claude deny: trail-blazer-flow:implementer (namespaced), Edit, /repo/.claude/foo.md -- measured: M12, 211 pass 19 fail"
  "cdg-deny-verif-write-ns|case_cdg_deny_verif_write_ns|.claude deny: trail-blazer-flow:verifier (namespaced), Write, /repo/.claude/bar.json -- measured: M13, 226 pass 4 fail (also M12, 211 pass 19 fail)"
  "cdg-deny-verif-edit-bare|case_cdg_deny_verif_edit_bare|.claude deny: verifier (bare), Edit, /repo/.claude/baz.md -- measured: M13, 226 pass 4 fail (also M12, 211 pass 19 fail)"
  "cdg-deny-nested|case_cdg_deny_nested|.claude deny: a nested segment, /Users/x/proj/.claude/settings.json -- measured: M12, 211 pass 19 fail"
  "cdg-deny-user-level|case_cdg_deny_user_level|.claude deny: a path entirely outside any repo checkout, /Users/x/.claude/settings.json (pins deliberate location-independence -- this hook reads no cwd/repo-root at all) -- measured: M12, 211 pass 19 fail"
  "cdg-deny-case-variant|case_cdg_deny_case_variant|.claude deny: case-varied spelling, /repo/.Claude/x -- measured: M7, 229 pass 1 fail (also M12, 211 pass 19 fail)"
  "cdg-deny-drive-letter|case_cdg_deny_drive_letter|.claude deny: Windows drive-letter absolute form, C:/Users/x/.claude/foo -- measured: M12, 211 pass 19 fail"
  "cdg-deny-backslash|case_cdg_deny_backslash|.claude deny: backslash-spelled form, C:\Users\x\.claude\foo (separator normalisation) -- measured: M6, 229 pass 1 fail (also M12, 211 pass 19 fail)"
  "cdg-deny-final-segment|case_cdg_deny_final_segment|.claude deny: .claude as the path's FINAL segment, /repo/foo/.claude -- measured: M8, 228 pass 2 fail (with cdg-deny-rel-claude; also M12, 211 pass 19 fail)"
  "cdg-deny-crlf|case_cdg_deny_crlf|.claude deny: a CR embedded inside the spelling itself, /repo/.clau<CR>de/foo (the strip can only widen toward deny) -- measured: M5, 229 pass 1 fail (also M12, 211 pass 19 fail)"
  "cdg-deny-rel-claude|case_cdg_deny_rel_claude|.claude deny: a RELATIVE path whose first segment is .claude, .claude/LESSONS.md (discriminated from cdg-deny-rel-plain below) -- measured: M8, 228 pass 2 fail (with cdg-deny-final-segment; also M12, 211 pass 19 fail)"
  "cdg-deny-dotdot-claude|case_cdg_deny_dotdot_claude|.claude deny: a \"..\"-carrying ABSOLUTE path that also carries a real .claude segment, /Users/x/../.claude/y (the more specific message wins) -- measured: M12, 211 pass 19 fail"
  "cdg-deny-lf-claude|case_cdg_deny_lf_claude|.claude deny: an embedded LF elsewhere in the path, /repo/.claude/a<LF>b.md (#327 round-1 kickback K1 -- pre-fix this printed 2 stderr lines) -- measured: M14, 228 pass 2 fail (with cdg-deny-lf-unclassifiable; also M12, 211 pass 19 fail)"
  "cdg-deny-rel-plain|case_cdg_deny_rel_plain|unclassifiable deny: the SAME relative, no-leading-slash shape as cdg-deny-rel-claude, but no .claude segment anywhere, src/main.rs (discriminates the two deny classes) -- measured: M10, 228 pass 2 fail (with cdg-deny-lf-unclassifiable; also M12, 211 pass 19 fail)"
  "cdg-deny-dotdot-no-claude|case_cdg_deny_dotdot_no_claude|unclassifiable deny: a \"..\"-carrying ABSOLUTE path with no .claude segment anywhere, /Users/x/../etc/passwd -- measured: M11, 229 pass 1 fail (also M12, 211 pass 19 fail)"
  "cdg-deny-lf-unclassifiable|case_cdg_deny_lf_unclassifiable|unclassifiable deny: an embedded LF in a relative, no-.claude path, src/a<LF>b.rs (#327 round-1 kickback K1's own second example -- pre-fix this printed 2 stderr lines) -- measured: M10, 228 pass 2 fail (with cdg-deny-rel-plain -- the SAME no-.claude/relative shape, a kill-set widening found only by re-measuring, not by inspection); also M14, 228 pass 2 fail (with cdg-deny-lf-claude; also M12, 211 pass 19 fail)"
  "cdg-noop-ordinary-abs|case_cdg_noop_ordinary_abs|no opinion: an ordinary absolute path with no .claude segment, /repo/src/main.rs -- measured: not flipped by M1-M14 (an ordinary absolute path never denies under any of these mutants)"
  "cdg-noop-claude-backup|case_cdg_noop_claude_backup|no opinion: near-miss segment spelling, /repo/.claude-backup/x (pins exact-segment matching) -- measured: M9, 228 pass 2 fail (with cdg-noop-my-claude)"
  "cdg-noop-my-claude|case_cdg_noop_my_claude|no opinion: near-miss segment spelling, /repo/my.claude/x (pins exact-segment matching) -- measured: M9, 228 pass 2 fail (with cdg-noop-claude-backup)"
  "cdg-noop-main-session-lessons|case_cdg_noop_main_session_lessons|no opinion: main session (no agent_type key), Write, /repo/.claude/LESSONS.md (release-blocker control -- the orchestrator's own lesson append) -- measured: not flipped by M1-M14 (no agent_type key anywhere in the raw stdin -- the fast path alone already excludes it)"
  "cdg-noop-unrecognised-agent|case_cdg_noop_unrecognised_agent|no opinion: agent_type is \"Explore\" (unrecognised role) -- measured: M1, 228 pass 2 fail (with cdg-noop-empty-agent; also M13, 226 pass 4 fail)"
  "cdg-noop-empty-agent|case_cdg_noop_empty_agent|no opinion: agent_type is the empty string -- measured: M1, 228 pass 2 fail (with cdg-noop-unrecognised-agent)"
  "cdg-noop-plan-mode|case_cdg_noop_plan_mode|no opinion: implementer Edit of /repo/.claude/x under permission_mode: \"plan\" -- measured: M4, 229 pass 1 fail"
  "cdg-noop-wrong-tool|case_cdg_noop_wrong_tool|no opinion: tool_name is \"Read\", not Edit/Write -- measured: M3, 229 pass 1 fail"
  "cdg-noop-malformed-json|case_cdg_noop_malformed_json|no opinion: unparseable stdin (carries both agent_type and .claude substrings) -- measured: not flipped by M1-M14 (jq's own parse failure independently yields an empty extraction regardless of which downstream check runs)"
  "cdg-noop-missing-file-path|case_cdg_noop_missing_file_path|no opinion: tool_input.file_path absent -- measured: not flipped by M1-M14 (an empty file_path exits before the classifier itself ever runs, on every mutant in this table)"
  "cdg-noop-verifier-mutation-probe|case_cdg_noop_verifier_mutation_probe|no opinion: verifier Edit of a tracked source file, /repo/bin/find-planning-work.sh (release-blocker control -- the mutation probe) -- measured: M13, 226 pass 4 fail"
  "cdg-never-executes-deny|case_cdg_never_executes_deny|deny, AND claude-dir-guard.sh never invokes git/gh/rm/dirname/tr/awk/grep/sed on the booby-trapped PATH — sentinel absent -- measured: M12, 211 pass 19 fail"
  "cdg-never-executes-noop|case_cdg_never_executes_noop|no opinion, AND claude-dir-guard.sh never invokes git/gh/rm/dirname/tr/awk/grep/sed on the booby-trapped PATH — sentinel absent -- measured: not flipped by M1-M14 (the identical \"ordinary absolute path\" shape as cdg-noop-ordinary-abs, plus a booby-trapped PATH none of these mutants ever reads)"
  "cdg-writes-nothing|case_cdg_writes_nothing|deny, AND a fixture tree containing .claude/LESSONS.md has a byte-identical recursive file listing before/after — this hook performs no filesystem access at all -- measured: M12, 211 pass 19 fail"
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
  # mutant:383-fn-hook — renames a cases=() row's target function in a scratch copy of this
  #   suite; this declare -F guard must report that row FAIL naming the missing function, instead
  #   of a silent PASS the row would otherwise get by falling through with $__ok unchanged.
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn"
  else
    __ok=0; __why="${__why}case function '$fn' is not defined (deleted or renamed?) — this row never ran\n"
  fi
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
