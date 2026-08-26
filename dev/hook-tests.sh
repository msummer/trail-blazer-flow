#!/usr/bin/env bash
#
# hook-tests.sh — fixture-based negative-test harness for the plugin-shipped PreToolUse guard
# hook (hooks/git-c-guard.sh, #150), in the style of dev/doctor-tests.sh: feeds fixture stdin
# JSON straight into the real script and pins its verdict — allow (a single
# hookSpecificOutput.permissionDecision == "allow" JSON object on stdout) or no opinion (empty
# stdout) — for every case listed in the approved plan's "Testing approach", plus a
# booby-trapped `git`/`rm` on PATH proving the guard never executes anything against the
# untrusted worktree path it is validating (that is exactly the risk the startup wildcard
# warning names — see hooks/git-c-guard.sh's header).
#
# Usage: bash dev/hook-tests.sh [name-filter] — same output contract as dev/selfcheck-tests.sh
# and dev/doctor-tests.sh: one PASS/FAIL line per case, a `== summary: N pass, M fail ==`
# footer, exit 0 iff nothing failed; a filter with no match exits 1.
#
# Every write happens under one `mktemp -d` root, removed via an EXIT trap; this repo's own
# hooks/git-c-guard.sh is read-only here — the script is run directly, never copied or edited.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"
guard="$root/hooks/git-c-guard.sh"

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
