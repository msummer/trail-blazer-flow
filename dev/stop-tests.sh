#!/usr/bin/env bash
#
# stop-tests.sh — fixture-based negative-test harness for bin/harness-stop.sh (#310).
#
# Usage: bash dev/stop-tests.sh [name-filter] — same output contract as dev/lock-tests.sh: one
# PASS/FAIL line per case, a `== summary: N pass, M fail ==` footer, exit 0 iff nothing failed; a
# filter with no match exits 1.
#
# Every write happens under one `mktemp -d` root, removed via an EXIT trap.
#
# ISOLATION (deliberately NOT "prepend a stub dir to the ambient PATH"): each fixture gets its own
# small `tbin/` directory that becomes the SUBPROCESS's entire PATH when invoking
# bin/harness-stop.sh (`PATH="$tbin"`, no fallback to this developer's or CI runner's own PATH).
# bin/harness-stop.sh itself needs exactly five external commands — `git`, `jq`, `gh`, `sleep`,
# `cat` (the last only inside its own `usage()`, reached by `--help` or an unknown argument; cd,
# pwd, printf, case/if/test are shell builtins) — so `tbin/` holds up to those five, built fresh
# per fixture: `git`/`cat` are always symlinks to this machine's real binaries (resolved once, at
# the top of this file, via `command -v`); `jq` is either the same real-binary symlink ("ok",
# `build_normal_env`'s default JQMODE) or simply absent ("none", for the jq-missing cases); `sleep`
# is always the stub `build_stub_sleep_at` writes (so no fixture ever waits a real 30s); `gh` is
# either the stub `build_stub_gh_at` writes ("ok"), or simply absent ("none", for the gh-missing
# case) — since PATH is built from scratch, "absent" (for either `jq` or `gh`) means `command -v`
# genuinely fails, not "shadowed by a stub that happens to exit 1". Every generated stub script
# (`gh`, `sleep`, and the never-mutates case's `git`/booby-trap set below) is bash-only internally
# (no external `cat`/`rm`/`sed` in its own runtime logic — a one-shot reject/bad-body marker is
# consumed by OVERWRITING its own content, `printf 'spent' > file`, never by `rm`), so none of
# them need `cat` (or any other external tool) placed alongside them in `tbin/` to do their OWN
# job — `cat` is symlinked in only because bin/harness-stop.sh's `usage()` itself calls it.
#
# THE never-mutates CASE (approval addendum, 2026-09-21) builds a DIFFERENT env: `git` is a
# RECORDING wrapper (logs its argv, then `exec`s the real git — the script legitimately calls git
# once), `gh` is the ordinary logging stub (not booby-trapped — the script legitimately calls it),
# and `rm`/`mv`/`touch`/`mkdir`/`dirname` are booby-trapped: each records its own invocation and
# exits 1, so if bin/harness-stop.sh ever called one, that call would fail loudly AND leave a
# record. Two fixtures ("stop-set": local file + a labelled GitHub issue both present;
# "stop-absent": neither) each get a byte-identical `find . | sort` listing of the FIXTURE REPO
# (never `tbin/`, which is test scaffolding, not the tree under test) before and after the run.
# State only what each part proves (LESSON, this train): the listing proves nothing in the
# fixture tree was written; the git/gh call logs prove which calls were made — a `find` listing
# says nothing about what was merely READ.
#
# needle_required NAME NEEDLE (#262) — guards every needle-taking helper below: an empty NEEDLE
# degenerates `grep -qF -- ""` into an unconditional match, so `dev/stop-tests.sh` joins the
# enumeration of fixture harnesses (CLAUDE.md Conventions) that guard every such helper.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
filter="${1:-}"

tmpbase="$(mktemp -d)"
tmpbase="$(cd "$tmpbase" && pwd -P)"
cleanup() {
  if [ -n "$tmpbase" ] && [ -d "$tmpbase" ]; then
    rm -rf "$tmpbase"
  fi
}
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1; then
  echo "  FAIL  jq not installed — required by dev/stop-tests.sh's fixtures"
  exit 1
fi

bash_bin="$(command -v bash)"
real_git="$(command -v git)"
real_jq="$(command -v jq)"
real_cat="$(command -v cat)"
if [ -z "$real_git" ] || [ -z "$real_jq" ] || [ -z "$real_cat" ]; then
  echo "  FAIL  git, jq, or cat not resolvable via command -v — required to build this harness's fixtures"
  exit 1
fi

pass=0; fail=0
case_ok()  { echo "  PASS  $1 — $2"; pass=$((pass+1)); }
case_bad() { echo "  FAIL  $1 — $2"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------------------------
# Fixture builders.

# mk_repo NAME — a fresh, throwaway git repo under $tmpbase/NAME: one empty commit on a branch
# renamed to "main", local identity + gpgsign off, its own home/xdgcfg dirs (the dev/lock-tests.sh
# idiom). Prints the fixture path (already under the resolved $tmpbase).
mk_repo() {
  local name="$1"
  local dir="$tmpbase/$name"
  mkdir -p "$dir/home" "$dir/xdgcfg"
  (
    cd "$dir" &&
    git init -q &&
    git config user.name "stop-tests" &&
    git config user.email "stop-tests@example.invalid" &&
    git config commit.gpgsign false &&
    git symbolic-ref HEAD refs/heads/main &&
    git commit -q --allow-empty -m init
  )
  printf '%s' "$dir"
}

# build_stub_sleep_at TBIN DATADIR — writes an executable TBIN/sleep that appends "$*" to
# DATADIR/.sleep-calls before checking DATADIR/sleep-fails (never actually sleeps — the whole
# point, same rationale as dev/planning-tests.sh's build_stub_sleep). Bash-only internally: no
# external command in its own body.
build_stub_sleep_at() {
  local tbin="$1" datadir="$2"
  local tmpl="$tbin/sleep.tmpl"
  {
    printf '#!%s\n' "$bash_bin"
    cat <<'EOF'
printf '%s\n' "$*" >> "__DATADIR__/.sleep-calls"
if [ -f "__DATADIR__/sleep-fails" ]; then
  exit 1
fi
exit 0
EOF
  } > "$tmpl"
  sed "s#__DATADIR__#$datadir#g" "$tmpl" > "$tbin/sleep"
  rm -f "$tmpl"
  chmod +x "$tbin/sleep"
}

# build_stub_gh_at TBIN DATADIR — writes an executable TBIN/gh modelling exactly the one call
# shape bin/harness-stop.sh makes (`gh issue list --label <name> --state open --json ... --limit
# ...`); no other dev/*.sh stub's shape is reused here (this script gets its own stub, per the
# approved plan). Logs every invocation ("$*") to DATADIR/.gh-calls FIRST, unconditionally
# (before validation or dispatch), so a case can prove which calls were made even when a call is
# rejected. Bash-only internally: no external `cat`/`rm` — a fixture's canned response is read
# with bash's own `$(< file)`, and the one-shot reject marker (armed/spent) is consumed by
# OVERWRITING its own content, never deleted.
#
# DATADIR/reject-stop(-once) makes the call itself fail (gh exit 1, no body) — a NON-ZERO-EXIT
# failed attempt (#310 kickback K1's first failure class). DATADIR/badbody-always /
# DATADIR/badbody-once (armed/spent, same idiom as reject-stop-once) instead make the call EXIT 0
# but print DATADIR/badbody-payload's raw bytes verbatim — a ZERO-EXIT-BUT-UNPARSABLE-OR-WRONG-
# SHAPE failed attempt (K1's second failure class: an HTML error page, an empty body, or a JSON
# object/scalar), so a case can pin that bin/harness-stop.sh's own `is_json_array` check — not just
# `gh`'s own exit code — is what decides whether an attempt counts as a read. The SAME
# badbody-always/-once mechanism also serves kickback N1's own case (github-multi-document), whose
# payload — two concatenated, individually well-formed JSON array documents — is NOT one of K1's
# failure classes at all: `is_json_array` accepts it (a stream, judged only by its last document),
# so the attempt succeeds; that fixture instead pins bin/harness-stop.sh's SEPARATE length-parsing
# guard, one layer further down.
#
# GH_ISSUE_JSON_FIELDS / validate_json_fields (#217 idiom; ADVISORY default accepted) is a
# byte-identical copy of dev/planning-tests.sh's and dev/cleanup-tests.sh's constant of the same
# name (CLAUDE.md names all three) — gh 2.97.0 (2026-07-31)'s real accepted field set for `issue
# list`/`issue view`, so a `--json` field bin/harness-stop.sh sends that gh itself does not accept
# is rejected here the same way it would be live.
build_stub_gh_at() {
  local tbin="$1" datadir="$2"
  local tmpl="$tbin/gh.tmpl"
  {
    printf '#!%s\n' "$bash_bin"
    cat <<'EOF'
GH_ISSUE_JSON_FIELDS="assignees author blockedBy blocking body closed closedAt closedByPullRequestsReferences comments createdAt id isPinned issueType labels milestone number parent projectCards projectItems reactionGroups state stateReason subIssues subIssuesSummary title updatedAt url"
validate_json_fields() {
  local orig="$*"
  local list="" found=0 tok
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--json" ]; then
      shift
      list="${1:-}"
      found=1
      break
    fi
    shift
  done
  if [ "$found" -ne 1 ]; then
    echo "stub: no --json argument in: gh $orig" >&2
    exit 1
  fi
  local IFS=,
  for tok in $list; do
    case " $GH_ISSUE_JSON_FIELDS " in
      *" $tok "*) : ;;
      *)
        echo "Unknown JSON field: \"$tok\"" >&2
        exit 1
        ;;
    esac
  done
}
D="__DATADIR__"
printf '%s\n' "$*" >> "$D/.gh-calls"
case "$1" in
  issue)
    case "$2" in
      list)
        validate_json_fields "$@"
        if [ -f "$D/reject-stop-once" ] && [ "$(< "$D/reject-stop-once")" != "spent" ]; then
          printf 'spent' > "$D/reject-stop-once"
          exit 1
        fi
        if [ -f "$D/reject-stop" ]; then
          exit 1
        fi
        if [ -f "$D/badbody-once" ] && [ "$(< "$D/badbody-once")" != "spent" ]; then
          printf 'spent' > "$D/badbody-once"
          printf '%s' "$(< "$D/badbody-payload")"
          exit 0
        fi
        if [ -f "$D/badbody-always" ]; then
          printf '%s' "$(< "$D/badbody-payload")"
          exit 0
        fi
        if [ -f "$D/issues.json" ]; then
          printf '%s\n' "$(< "$D/issues.json")"
        else
          printf '[]\n'
        fi
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
  } > "$tmpl"
  sed "s#__DATADIR__#$datadir#g" "$tmpl" > "$tbin/gh"
  rm -f "$tmpl"
  chmod +x "$tbin/gh"
}

# build_git_recorder_at TBIN DATADIR — writes an executable TBIN/git that appends "$*" to
# DATADIR/.git-calls, then `exec`s the REAL git (absolute path resolved once, at file scope) with
# the same arguments — never-mutates only; every other fixture uses a plain symlink to the real
# git instead (see build_normal_env below).
build_git_recorder_at() {
  local tbin="$1" datadir="$2"
  local tmpl="$tbin/git.tmpl"
  {
    printf '#!%s\n' "$bash_bin"
    cat <<EOF
printf '%s\n' "\$*" >> "$datadir/.git-calls"
exec "$real_git" "\$@"
EOF
  } > "$tmpl"
  mv "$tmpl" "$tbin/git"
  chmod +x "$tbin/git"
}

# build_trap_at TBIN DATADIR NAME — writes an executable TBIN/NAME that appends "$*" to
# DATADIR/.trap-calls, then exits 1 — never-mutates only, for rm/mv/touch/mkdir/dirname: a script
# that never calls any of them leaves DATADIR/.trap-calls absent; one that does gets a recorded,
# failed call.
build_trap_at() {
  local tbin="$1" datadir="$2" name="$3"
  local tmpl="$tbin/$name.tmpl"
  {
    printf '#!%s\n' "$bash_bin"
    cat <<EOF
printf '%s %s\n' "$name" "\$*" >> "$datadir/.trap-calls"
exit 1
EOF
  } > "$tmpl"
  mv "$tmpl" "$tbin/$name"
  chmod +x "$tbin/$name"
}

# build_normal_env TBIN DATADIR GHMODE [JQMODE] — the PATH env for every case except
# never-mutates: real git/cat (symlinks), the stub sleep (always), gh per GHMODE: "ok" (the stub
# above) or "none" (omitted entirely — command -v gh then genuinely fails), and jq per JQMODE
# (default "ok"): "ok" (real jq, symlinked) or "none" (omitted entirely — command -v jq then
# genuinely fails, same "not merely shadowed" guarantee the ISOLATION note gives gh).
build_normal_env() {
  local tbin="$1" datadir="$2" ghmode="$3" jqmode="${4:-ok}"
  mkdir -p "$tbin"
  ln -s "$real_git" "$tbin/git"
  ln -s "$real_cat" "$tbin/cat"
  case "$jqmode" in
    ok) ln -s "$real_jq" "$tbin/jq" ;;
    none) : ;;
  esac
  build_stub_sleep_at "$tbin" "$datadir"
  case "$ghmode" in
    ok) build_stub_gh_at "$tbin" "$datadir" ;;
    none) : ;;
  esac
}

# build_nm_env TBIN DATADIR — the never-mutates env: recording git, real jq/cat, stub sleep, stub
# gh, and booby-trapped rm/mv/touch/mkdir/dirname.
build_nm_env() {
  local tbin="$1" datadir="$2" t
  mkdir -p "$tbin"
  build_git_recorder_at "$tbin" "$datadir"
  ln -s "$real_jq" "$tbin/jq"
  ln -s "$real_cat" "$tbin/cat"
  build_stub_sleep_at "$tbin" "$datadir"
  build_stub_gh_at "$tbin" "$datadir"
  for t in rm mv touch mkdir dirname; do
    build_trap_at "$tbin" "$datadir" "$t"
  done
}

# ---------------------------------------------------------------------------------------------
# Runner + assertion helpers.

stop_rc=0
stop_out=""
stop_stdout=""
stop_stderr=""

# run_stop DIR TBIN ARGS... — runs bin/harness-stop.sh with PATH=TBIN (see the header's ISOLATION
# note) and HOME/XDG_CONFIG_HOME scoped to DIR, from inside DIR. stdout/stderr captured to
# SEPARATE files (LESSON 2026-09-08b) so a case can pin which stream carries a claim.
run_stop() {
  local dir="$1" tbin="$2"; shift 2
  local orig; orig="$(pwd)"
  cd "$dir" || { stop_rc=90; stop_out="cd $dir failed"; stop_stdout=""; stop_stderr=""; return; }
  PATH="$tbin" HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdgcfg" \
    "$bash_bin" "$root/bin/harness-stop.sh" "$@" > "$dir/.stop-out" 2> "$dir/.stop-err"
  stop_rc=$?
  cd "$orig" || true
  stop_stdout="$(cat "$dir/.stop-out" 2>/dev/null)"
  stop_stderr="$(cat "$dir/.stop-err" 2>/dev/null)"
  stop_out="$(cat "$dir/.stop-out" "$dir/.stop-err" 2>/dev/null)"
}

# run_stop_nm REPO TBIN OUTDIR ARGS... — the never-mutates-only sibling of run_stop: identical
# except stdout/stderr are captured under OUTDIR (the fixture's DATADIR, outside REPO) instead of
# inside REPO itself, so the runner's OWN redirect files never appear in a `find REPO` listing —
# run_stop's ordinary `$dir/.stop-out`/`.stop-err` placement would otherwise show up as a spurious
# "the tree changed" finding that has nothing to do with bin/harness-stop.sh's own behaviour.
run_stop_nm() {
  local repo="$1" tbin="$2" outdir="$3"; shift 3
  local orig; orig="$(pwd)"
  cd "$repo" || { stop_rc=90; stop_out="cd $repo failed"; stop_stdout=""; stop_stderr=""; return; }
  PATH="$tbin" HOME="$repo/home" XDG_CONFIG_HOME="$repo/xdgcfg" \
    "$bash_bin" "$root/bin/harness-stop.sh" "$@" > "$outdir/.stop-out" 2> "$outdir/.stop-err"
  stop_rc=$?
  cd "$orig" || true
  stop_stdout="$(cat "$outdir/.stop-out" 2>/dev/null)"
  stop_stderr="$(cat "$outdir/.stop-err" 2>/dev/null)"
  stop_out="$(cat "$outdir/.stop-out" "$outdir/.stop-err" 2>/dev/null)"
}

# needle_required NAME NEEDLE (#262) — see the header note; identical contract to
# dev/lock-tests.sh's own helper.
needle_required() {
  if [ -z "$2" ]; then
    __ok=0
    __why="${__why}$1: empty needle (harness bug)\n"
    return 1
  fi
  return 0
}

# expect*/expect_absent* — fed via here-strings (#255: never a writer piped into grep's quiet
# mode), guarded by needle_required (#262).
expect() {
  needle_required expect "$1" || return 0
  grep -qF -- "$1" <<<"$stop_out" || { __ok=0; __why="${__why}missing: $1\n"; }
}
expect_out() {
  needle_required expect_out "$1" || return 0
  grep -qF -- "$1" <<<"$stop_stdout" || { __ok=0; __why="${__why}missing on stdout: $1\n"; }
}
expect_err() {
  needle_required expect_err "$1" || return 0
  grep -qF -- "$1" <<<"$stop_stderr" || { __ok=0; __why="${__why}missing on stderr: $1\n"; }
}
expect_absent_out() {
  needle_required expect_absent_out "$1" || return 0
  grep -qF -- "$1" <<<"$stop_stdout" && { __ok=0; __why="${__why}unexpected on stdout: $1\n"; }
}
expect_rc() {
  [ "$stop_rc" -eq "$1" ] || { __ok=0; __why="${__why}rc: expected $1, got $stop_rc\n"; }
}
expect_first_line() {
  needle_required expect_first_line "$1" || return 0
  local first; first="$(printf '%s\n' "$stop_stdout" | head -1)"
  [ "$first" = "$1" ] || { __ok=0; __why="${__why}first line of stdout: expected '$1', got '$first'\n"; }
}
# expect_consecutive LINE1 LINE2 — asserts LINE2 is the line immediately after LINE1 in stdout
# (the "route= ... immediately followed by its own clear= line" grammar rule) — a presence check
# on each line separately would not pin the adjacency the grammar actually names.
expect_consecutive() {
  needle_required expect_consecutive "$1" || return 0
  needle_required expect_consecutive "$2" || return 0
  local pair
  pair="$(grep -A1 -F -- "$1" <<<"$stop_stdout" | tail -1)"
  [ "$pair" = "$2" ] || { __ok=0; __why="${__why}expected '$2' immediately after '$1' in stdout, got '$pair'\n"; }
}
expect_count_err() {
  local needle="$1" want="$2" got
  needle_required expect_count_err "$needle" || return 0
  got="$(grep -cF -- "$needle" <<<"$stop_stderr")"
  [ "$got" -eq "$want" ] || { __ok=0; __why="${__why}count(stderr): expected $want of '$needle', got $got\n"; }
}
expect_stdout_empty() {
  [ -z "$stop_stdout" ] || { __ok=0; __why="${__why}stdout not empty: $stop_stdout\n"; }
}
expect_stderr_empty() {
  [ -z "$stop_stderr" ] || { __ok=0; __why="${__why}stderr not empty: $stop_stderr\n"; }
}

# expect_sleep_calls DATADIR N / expect_gh_list_calls DATADIR N — count-only helpers reading the
# stub logs directly from a file (no writer/pipe involved, so no SIGPIPE exposure regardless of
# flags); no needle_required guard needed (not grep-based on a variable needle — mirrors
# dev/planning-tests.sh's expect_sleep_calls/expect_pr_calls, which take the identical shape).
expect_sleep_calls() {
  local dir="$1" want="$2" got=0
  [ -f "$dir/.sleep-calls" ] && got="$(wc -l < "$dir/.sleep-calls" | tr -d '[:space:]')"
  [ "$got" -eq "$want" ] || { __ok=0; __why="${__why}sleep calls: expected $want, got $got\n"; }
}
expect_gh_list_calls() {
  local dir="$1" want="$2" got=0
  [ -f "$dir/.gh-calls" ] && got="$(grep -cF -- "issue list" "$dir/.gh-calls" || true)"
  [ "$got" -eq "$want" ] || { __ok=0; __why="${__why}gh issue-list calls: expected $want, got $got\n"; }
}
# expect_gh_call DATADIR NEEDLE (K2, #310 kickback) — asserts NEEDLE is a substring of the logged
# `.gh-calls` file (fed via a here-string, #255), guarded by needle_required (#262). Pins the
# EXPLICIT spelling of a flag the query sends, distinct from expect_gh_list_calls's call-count.
expect_gh_call() {
  local dir="$1" needle="$2" log=""
  needle_required expect_gh_call "$needle" || return 0
  [ -f "$dir/.gh-calls" ] && log="$(< "$dir/.gh-calls")"
  grep -qF -- "$needle" <<<"$log" || { __ok=0; __why="${__why}gh call log missing: $needle\n"; }
}

# check_gh_calls_are_list_only DATADIR — never-mutates: every logged `gh` call's first two words
# must be "issue list" (never edit/comment/close/label/api). Requires at least one call (the
# script always attempts the GitHub route in these fixtures).
check_gh_calls_are_list_only() {
  local f="$1/.gh-calls" line
  [ -s "$f" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "issue list"|"issue list "*) : ;;
      *) return 1 ;;
    esac
  done < "$f"
  return 0
}
# check_git_calls_are_rev_parse DATADIR — never-mutates: every logged `git` call must be exactly
# `rev-parse --git-common-dir` (the script's only git invocation).
check_git_calls_are_rev_parse() {
  local f="$1/.git-calls" line
  [ -s "$f" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "rev-parse --git-common-dir") : ;;
      *) return 1 ;;
    esac
  done < "$f"
  return 0
}

# ---------------------------------------------------------------------------------------------
# The cases.

# 1. clear-both — no route set.
case_clear_both() {
  local dir; dir="$(mk_repo clear-both)"
  local tbin="$tmpbase/clear-both-bin" datadir="$tmpbase/clear-both-data"
  mkdir -p "$tbin" "$datadir"
  printf '[]\n' > "$datadir/issues.json"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin"
  expect_rc 0
  expect_first_line "stop=false"
  expect_absent_out "route="
}

# 2. github-one — one labelled issue.
case_github_one() {
  local dir; dir="$(mk_repo github-one)"
  local tbin="$tmpbase/github-one-bin" datadir="$tmpbase/github-one-data"
  mkdir -p "$tbin" "$datadir"
  printf '[{"number":42,"title":"stop it","url":"https://example.invalid/42"}]\n' > "$datadir/issues.json"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin"
  expect_rc 3
  expect_first_line "stop=true"
  expect_consecutive "route=github issue=42 url=https://example.invalid/42" "clear=gh issue edit 42 --remove-label harness-stop"
}

# 3. github-many — two labelled issues.
case_github_many() {
  local dir; dir="$(mk_repo github-many)"
  local tbin="$tmpbase/github-many-bin" datadir="$tmpbase/github-many-data"
  mkdir -p "$tbin" "$datadir"
  printf '[{"number":10,"title":"a","url":"https://example.invalid/10"},{"number":11,"title":"b","url":"https://example.invalid/11"}]\n' > "$datadir/issues.json"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin"
  expect_rc 3
  expect_first_line "stop=true"
  expect_consecutive "route=github issue=10 url=https://example.invalid/10" "clear=gh issue edit 10 --remove-label harness-stop"
  expect_consecutive "route=github issue=11 url=https://example.invalid/11" "clear=gh issue edit 11 --remove-label harness-stop"
}

# 4. local-only — stop file present, gh returns [].
case_local_only() {
  local dir; dir="$(mk_repo local-only)"
  mkdir -p "$dir/.git/trail-blazer"
  : > "$dir/.git/trail-blazer/stop"
  local tbin="$tmpbase/local-only-bin" datadir="$tmpbase/local-only-data"
  mkdir -p "$tbin" "$datadir"
  printf '[]\n' > "$datadir/issues.json"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin"
  expect_rc 3
  expect_first_line "stop=true"
  local resolved; resolved="$(cd "$dir/.git" && pwd -P)"
  expect_consecutive "route=local path=$resolved/trail-blazer/stop" "clear=rm $resolved/trail-blazer/stop"
}

# 5. both-routes — both set, neither short-circuits the other.
case_both_routes() {
  local dir; dir="$(mk_repo both-routes)"
  mkdir -p "$dir/.git/trail-blazer"
  : > "$dir/.git/trail-blazer/stop"
  local tbin="$tmpbase/both-routes-bin" datadir="$tmpbase/both-routes-data"
  mkdir -p "$tbin" "$datadir"
  printf '[{"number":7,"title":"x","url":"https://example.invalid/7"}]\n' > "$datadir/issues.json"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin"
  expect_rc 3
  expect_first_line "stop=true"
  local resolved; resolved="$(cd "$dir/.git" && pwd -P)"
  expect_consecutive "route=github issue=7 url=https://example.invalid/7" "clear=gh issue edit 7 --remove-label harness-stop"
  expect_consecutive "route=local path=$resolved/trail-blazer/stop" "clear=rm $resolved/trail-blazer/stop"
}

# 6. github-unreadable — stub rejects both attempts.
case_github_unreadable() {
  local dir; dir="$(mk_repo github-unreadable)"
  local tbin="$tmpbase/github-unreadable-bin" datadir="$tmpbase/github-unreadable-data"
  mkdir -p "$tbin" "$datadir"
  printf 'always' > "$datadir/reject-stop"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin"
  expect_rc 4
  expect_first_line "stop=unknown"
  expect_out "reason=github-query-unavailable"
  expect_count_err "warn:" 1
  expect_sleep_calls "$datadir" 1
  expect_gh_list_calls "$datadir" 2
}

# 7. github-unreadable-once — stub rejects the first attempt only.
case_github_unreadable_once() {
  local dir; dir="$(mk_repo github-unreadable-once)"
  local tbin="$tmpbase/github-unreadable-once-bin" datadir="$tmpbase/github-unreadable-once-data"
  mkdir -p "$tbin" "$datadir"
  printf 'armed' > "$datadir/reject-stop-once"
  printf '[]\n' > "$datadir/issues.json"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin"
  expect_rc 0
  expect_first_line "stop=false"
  expect_count_err "warn:" 1
  expect_sleep_calls "$datadir" 1
  expect_gh_list_calls "$datadir" 2
}

# 8. local-set-github-unreadable — a determinate set route beats unknown.
case_local_set_github_unreadable() {
  local dir; dir="$(mk_repo local-set-github-unreadable)"
  mkdir -p "$dir/.git/trail-blazer"
  : > "$dir/.git/trail-blazer/stop"
  local tbin="$tmpbase/local-set-github-unreadable-bin" datadir="$tmpbase/local-set-github-unreadable-data"
  mkdir -p "$tbin" "$datadir"
  printf 'always' > "$datadir/reject-stop"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin"
  expect_rc 3
  expect_first_line "stop=true"
  local resolved; resolved="$(cd "$dir/.git" && pwd -P)"
  expect_out "route=local path=$resolved/trail-blazer/stop"
  expect_out "reason=github-query-unavailable"
}

# 9. gh-missing — gh absent from PATH entirely (see the header's ISOLATION note: not merely
# "shadowed", genuinely unresolvable).
case_gh_missing() {
  local dir; dir="$(mk_repo gh-missing)"
  local tbin="$tmpbase/gh-missing-bin" datadir="$tmpbase/gh-missing-data"
  mkdir -p "$tbin" "$datadir"
  build_normal_env "$tbin" "$datadir" none
  run_stop "$dir" "$tbin"
  expect_rc 4
  expect_first_line "stop=unknown"
  expect_out "reason=gh-not-found"
  expect_sleep_calls "$datadir" 0
}

# 10. github-non-json — stub returns a non-JSON body (an HTML error page) on both attempts (#310
# kickback K1): a zero-exit `gh` call whose body fails to parse is a FAILED attempt, retried
# identically to a non-zero exit.
case_github_non_json() {
  local dir; dir="$(mk_repo github-non-json)"
  local tbin="$tmpbase/github-non-json-bin" datadir="$tmpbase/github-non-json-data"
  mkdir -p "$tbin" "$datadir"
  printf '<html>502 Bad Gateway</html>' > "$datadir/badbody-payload"
  printf 'always' > "$datadir/badbody-always"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin"
  expect_rc 4
  expect_first_line "stop=unknown"
  expect_out "reason=github-query-unavailable"
  expect_count_err "warn:" 1
  expect_sleep_calls "$datadir" 1
  expect_gh_list_calls "$datadir" 2
}

# 11. github-non-json-once — the non-JSON body appears on the first attempt only; the retry gets a
# real (empty) array and the run proceeds as stop=false — proving a bad-shaped body is retried
# exactly like a non-zero exit, not treated as a permanent failure.
case_github_non_json_once() {
  local dir; dir="$(mk_repo github-non-json-once)"
  local tbin="$tmpbase/github-non-json-once-bin" datadir="$tmpbase/github-non-json-once-data"
  mkdir -p "$tbin" "$datadir"
  printf '<html>502 Bad Gateway</html>' > "$datadir/badbody-payload"
  printf 'armed' > "$datadir/badbody-once"
  printf '[]\n' > "$datadir/issues.json"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin"
  expect_rc 0
  expect_first_line "stop=false"
  expect_count_err "warn:" 1
  expect_sleep_calls "$datadir" 1
  expect_gh_list_calls "$datadir" 2
}

# 12. github-empty-body — stub returns a wholly empty body (gh exits 0, prints nothing) on both
# attempts: empty input is not a JSON array either, so this is the same failed-attempt class as
# github-non-json, not a vacuous "zero issues".
case_github_empty_body() {
  local dir; dir="$(mk_repo github-empty-body)"
  local tbin="$tmpbase/github-empty-body-bin" datadir="$tmpbase/github-empty-body-data"
  mkdir -p "$tbin" "$datadir"
  : > "$datadir/badbody-payload"
  printf 'always' > "$datadir/badbody-always"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin"
  expect_rc 4
  expect_first_line "stop=unknown"
  expect_out "reason=github-query-unavailable"
  expect_sleep_calls "$datadir" 1
  expect_gh_list_calls "$datadir" 2
}

# 13. github-json-object — stub returns a well-formed JSON OBJECT (gh's own real shape for an
# error response, e.g. a rate-limit body) on both attempts: valid JSON, but not an array, so
# `is_json_array` rejects it the same way — no route= line is ever printed (the union check never
# sees a positive github_n), unlike the pre-K1 script, which would have counted the object's own
# key count as "issues" and printed stop=true.
case_github_json_object() {
  local dir; dir="$(mk_repo github-json-object)"
  local tbin="$tmpbase/github-json-object-bin" datadir="$tmpbase/github-json-object-data"
  mkdir -p "$tbin" "$datadir"
  printf '{"message":"API rate limit exceeded"}' > "$datadir/badbody-payload"
  printf 'always' > "$datadir/badbody-always"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin"
  expect_rc 4
  expect_first_line "stop=unknown"
  expect_out "reason=github-query-unavailable"
  expect_absent_out "route="
  expect_sleep_calls "$datadir" 1
  expect_gh_list_calls "$datadir" 2
}

# 14. jq-missing-with-issue — jq absent from PATH entirely, one labelled issue present in the
# (never-consulted) stub gh fixture: jq is checked BEFORE gh, so the GitHub route is unreadable
# with reason=jq-not-found and the maintainer's stop is never silently ignored (#310 kickback K1 —
# an earlier version would have fallen through to a zero count here and returned stop=false). Zero
# gh calls at all proves the query is never even attempted, not merely that it fails.
case_jq_missing_with_issue() {
  local dir; dir="$(mk_repo jq-missing-with-issue)"
  local tbin="$tmpbase/jq-missing-with-issue-bin" datadir="$tmpbase/jq-missing-with-issue-data"
  mkdir -p "$tbin" "$datadir"
  printf '[{"number":5,"title":"stop it","url":"https://example.invalid/5"}]\n' > "$datadir/issues.json"
  build_normal_env "$tbin" "$datadir" ok none
  run_stop "$dir" "$tbin"
  expect_rc 4
  expect_first_line "stop=unknown"
  expect_out "reason=jq-not-found"
  expect_sleep_calls "$datadir" 0
  expect_gh_list_calls "$datadir" 0
}

# 15. jq-missing-local-set — jq absent from PATH, the local stop file IS set: the local route
# needs no jq at all (a plain `[ -e ... ]` test and plain `echo` lines), so it still stops the run
# and still prints its own reason= line for the unreadable GitHub route (#310 kickback K1's
# "the local route is still honoured" requirement).
case_jq_missing_local_set() {
  local dir; dir="$(mk_repo jq-missing-local-set)"
  mkdir -p "$dir/.git/trail-blazer"
  : > "$dir/.git/trail-blazer/stop"
  local tbin="$tmpbase/jq-missing-local-set-bin" datadir="$tmpbase/jq-missing-local-set-data"
  mkdir -p "$tbin" "$datadir"
  build_normal_env "$tbin" "$datadir" ok none
  run_stop "$dir" "$tbin"
  expect_rc 3
  expect_first_line "stop=true"
  local resolved; resolved="$(cd "$dir/.git" && pwd -P)"
  expect_out "route=local path=$resolved/trail-blazer/stop"
  expect_out "reason=jq-not-found"
  expect_sleep_calls "$datadir" 0
  expect_gh_list_calls "$datadir" 0
}

# 16. state-open-explicit (#310 kickback K2) — pins the LITERAL `--state open` spelling in the
# logged gh call. Orchestrator measurement, quoted exactly as worded: `gh issue list --help` on gh
# 2.97.0 (2026-07-31) reads `-s, --state string   Filter by state: {open|closed|all} (default
# "open")` — so on that gh version, dropping `--state open` changes nothing gh itself observes;
# THIS case's own assertion on the call log, not gh's own default, is what makes mutant (g)
# measurable at all.
case_state_open_explicit() {
  local dir; dir="$(mk_repo state-open-explicit)"
  local tbin="$tmpbase/state-open-explicit-bin" datadir="$tmpbase/state-open-explicit-data"
  mkdir -p "$tbin" "$datadir"
  printf '[]\n' > "$datadir/issues.json"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin"
  expect_rc 0
  expect_gh_call "$datadir" "--state open"
}

# 17. worktree-shares-local — a git worktree add-ed sibling of a fixture whose stop file exists.
case_worktree_shares_local() {
  local dir; dir="$(mk_repo worktree-shares-local)"
  local wt="$tmpbase/worktree-shares-local-wt"
  ( cd "$dir" && git worktree add -q -b wt-branch "$wt" ) >/dev/null 2>&1
  mkdir -p "$wt/home" "$wt/xdgcfg"
  mkdir -p "$dir/.git/trail-blazer"
  : > "$dir/.git/trail-blazer/stop"
  local tbin="$tmpbase/worktree-shares-local-bin" datadir="$tmpbase/worktree-shares-local-data"
  mkdir -p "$tbin" "$datadir"
  printf '[]\n' > "$datadir/issues.json"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$wt" "$tbin"
  expect_rc 3
  local resolved; resolved="$(cd "$dir/.git" && pwd -P)"
  expect_out "route=local path=$resolved/trail-blazer/stop"
}

# 18. not-a-repo — run outside any git repo.
case_not_a_repo() {
  local dir="$tmpbase/not-a-repo"
  mkdir -p "$dir/home" "$dir/xdgcfg"
  local tbin="$tmpbase/not-a-repo-bin" datadir="$tmpbase/not-a-repo-data"
  mkdir -p "$tbin" "$datadir"
  build_normal_env "$tbin" "$datadir" ok
  local orig; orig="$(pwd)"
  cd "$dir" || { __ok=0; __why="${__why}cd failed\n"; return; }
  GIT_CEILING_DIRECTORIES="$tmpbase" PATH="$tbin" HOME="$dir/home" XDG_CONFIG_HOME="$dir/xdgcfg" \
    "$bash_bin" "$root/bin/harness-stop.sh" > "$dir/.stop-out" 2> "$dir/.stop-err"
  stop_rc=$?
  cd "$orig" || true
  stop_stdout="$(cat "$dir/.stop-out" 2>/dev/null)"
  stop_stderr="$(cat "$dir/.stop-err" 2>/dev/null)"
  stop_out="$(cat "$dir/.stop-out" "$dir/.stop-err" 2>/dev/null)"
  expect_rc 2
  expect_err "not inside a git repository"
  expect_stdout_empty
  [ -e "$dir/.git" ] && { __ok=0; __why="${__why}.git unexpectedly created\n"; }
}

# 19. unknown-arg — there is no clear subcommand.
case_unknown_arg() {
  local dir; dir="$(mk_repo unknown-arg)"
  local tbin="$tmpbase/unknown-arg-bin" datadir="$tmpbase/unknown-arg-data"
  mkdir -p "$tbin" "$datadir"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin" clear
  expect_rc 2
  expect_err "usage"
  expect_stdout_empty
}

# 20. help.
case_help() {
  local dir; dir="$(mk_repo help)"
  local tbin="$tmpbase/help-bin" datadir="$tmpbase/help-data"
  mkdir -p "$tbin" "$datadir"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin" --help
  expect_rc 0
  expect_out "usage: harness-stop.sh"
  expect_stderr_empty
}

# 21. never-mutates (approval addendum, 2026-09-21 — see the file header's own paragraph on this
# case) — two fixtures, "stop-set" (local file + a labelled GitHub issue) and "stop-absent"
# (neither), each proving: (1) a byte-identical `find` listing of the FIXTURE REPO before/after —
# nothing in the tree was written; (2) every logged `git` call is `rev-parse --git-common-dir`;
# (3) every logged `gh` call is an `issue list` call; (4) no booby-trapped rm/mv/touch/mkdir/
# dirname was ever invoked.
case_never_mutates() {
  local repo1 data1 tbin1 before1 after1
  repo1="$(mk_repo never-mutates-set)"
  mkdir -p "$repo1/.git/trail-blazer"
  : > "$repo1/.git/trail-blazer/stop"
  data1="$tmpbase/nm-data-set"; tbin1="$tmpbase/nm-bin-set"
  mkdir -p "$data1" "$tbin1"
  printf '[{"number":9001,"title":"stop","url":"https://example.invalid/9001"}]\n' > "$data1/issues.json"
  build_nm_env "$tbin1" "$data1"
  before1="$(cd "$repo1" && find . | sort)"
  run_stop_nm "$repo1" "$tbin1" "$data1"
  after1="$(cd "$repo1" && find . | sort)"
  [ "$before1" = "$after1" ] || { __ok=0; __why="${__why}fixture tree changed (stop-set)\n"; }
  expect_rc 3
  check_gh_calls_are_list_only "$data1" || { __ok=0; __why="${__why}gh call log (stop-set) contained a non-issue-list call\n"; }
  check_git_calls_are_rev_parse "$data1" || { __ok=0; __why="${__why}git call log (stop-set) contained a call other than rev-parse --git-common-dir\n"; }
  [ -s "$data1/.trap-calls" ] && { __ok=0; __why="${__why}a booby-trapped command was invoked (stop-set): $(cat "$data1/.trap-calls")\n"; }

  local repo2 data2 tbin2 before2 after2
  repo2="$(mk_repo never-mutates-absent)"
  data2="$tmpbase/nm-data-absent"; tbin2="$tmpbase/nm-bin-absent"
  mkdir -p "$data2" "$tbin2"
  printf '[]\n' > "$data2/issues.json"
  build_nm_env "$tbin2" "$data2"
  before2="$(cd "$repo2" && find . | sort)"
  run_stop_nm "$repo2" "$tbin2" "$data2"
  after2="$(cd "$repo2" && find . | sort)"
  [ "$before2" = "$after2" ] || { __ok=0; __why="${__why}fixture tree changed (stop-absent)\n"; }
  expect_rc 0
  check_gh_calls_are_list_only "$data2" || { __ok=0; __why="${__why}gh call log (stop-absent) contained a non-issue-list call\n"; }
  check_git_calls_are_rev_parse "$data2" || { __ok=0; __why="${__why}git call log (stop-absent) contained a call other than rev-parse --git-common-dir\n"; }
  [ -s "$data2/.trap-calls" ] && { __ok=0; __why="${__why}a booby-trapped command was invoked (stop-absent): $(cat "$data2/.trap-calls")\n"; }
}

# 22. github-multi-document (#310 kickback N1) — stub returns TWO concatenated JSON array
# documents, each carrying one labelled issue: `is_json_array` inspects only the LAST document and
# reports true (both parse as arrays), so the attempt itself succeeds with no retry — but `jq
# 'length'` over that same two-document body then prints one count per document (two lines), which
# is not a single plain number. This must make the GitHub route unreadable
# (reason=github-query-unavailable), never a silent zero count: the pre-N1 script fell through to
# github_n=0 here and reported stop=false, ignoring the labelled issues in the body entirely.
case_github_multi_document() {
  local dir; dir="$(mk_repo github-multi-document)"
  local tbin="$tmpbase/github-multi-document-bin" datadir="$tmpbase/github-multi-document-data"
  mkdir -p "$tbin" "$datadir"
  printf '[{"number":21,"title":"a","url":"https://example.invalid/21"}]\n[{"number":22,"title":"b","url":"https://example.invalid/22"}]\n' > "$datadir/badbody-payload"
  printf 'always' > "$datadir/badbody-always"
  build_normal_env "$tbin" "$datadir" ok
  run_stop "$dir" "$tbin"
  expect_rc 4
  expect_first_line "stop=unknown"
  expect_out "reason=github-query-unavailable"
  expect_absent_out "route="
  expect_absent_out "stop=false"
  expect_sleep_calls "$datadir" 0
  expect_gh_list_calls "$datadir" 1
}

# 23. json-field-rejected (ADVISORY default accepted) — a stub self-test: proves the stub's own
# validate_json_fields (modelling gh's real accepted field set) rejects an unsupported field the
# way real gh does. bin/harness-stop.sh's own field list (number,title,url) is never rejected by
# this stub — every other case above already proves that implicitly (they'd all fail otherwise).
case_json_field_rejected() {
  local dir; dir="$(mk_repo json-field-rejected)"
  local tbin="$tmpbase/json-field-rejected-bin" datadir="$tmpbase/json-field-rejected-data"
  mkdir -p "$tbin" "$datadir"
  build_normal_env "$tbin" "$datadir" ok
  local out rc
  out="$(PATH="$tbin" "$tbin/gh" issue list --label harness-stop --state open --json bogusField --limit 20 2>&1)"; rc=$?
  if [ "$rc" -ne 1 ]; then
    __ok=0; __why="${__why}expected rc=1 rejecting an unsupported --json field, got rc=$rc\n"
  fi
  grep -qF -- 'Unknown JSON field: "bogusField"' <<<"$out" || { __ok=0; __why="${__why}missing gh's own rejection line, got: $out\n"; }
}

# ---------------------------------------------------------------------------------------------
# name|fn|desc
cases=(
  "clear-both|case_clear_both|neither route set: stop=false, exit 0, no route= line"
  "github-one|case_github_one|one labelled issue: stop=true, exit 3, route=github/clear= pair naming the issue"
  "github-many|case_github_many|two labelled issues: two route/clear pairs, both named"
  "local-only|case_local_only|stop file present, gh returns []: stop=true, exit 3, route=local/clear=rm pair"
  "both-routes|case_both_routes|both routes set: exit 3, both route lines present, neither short-circuits the other"
  "github-unreadable|case_github_unreadable|stub rejects both attempts: stop=unknown, exit 4, one warn, reason=github-query-unavailable, one sleep, two gh calls"
  "github-unreadable-once|case_github_unreadable_once|stub rejects the first attempt only: stop=false, exit 0, absorbed-blip warn, one sleep, two gh calls (a retry, not a sleep-without-retry)"
  "local-set-github-unreadable|case_local_set_github_unreadable|local set, GitHub unreadable: exit 3, both route=local and reason= lines present"
  "gh-missing|case_gh_missing|gh absent from PATH entirely: stop=unknown, exit 4, reason=gh-not-found, zero sleeps"
  "github-non-json|case_github_non_json|non-JSON body (HTML) on both attempts: stop=unknown, exit 4, one warn, one sleep, two gh calls"
  "github-non-json-once|case_github_non_json_once|non-JSON body on the first attempt only: stop=false, exit 0, absorbed-blip warn, one sleep, two gh calls"
  "github-empty-body|case_github_empty_body|wholly empty body on both attempts: stop=unknown, exit 4, one sleep, two gh calls"
  "github-json-object|case_github_json_object|a well-formed JSON object (not an array) on both attempts: stop=unknown, exit 4, no route= line"
  "jq-missing-with-issue|case_jq_missing_with_issue|jq absent, one labelled issue present in the (never-consulted) fixture: stop=unknown, exit 4, reason=jq-not-found, zero sleeps, zero gh calls"
  "jq-missing-local-set|case_jq_missing_local_set|jq absent, local stop file set: stop=true, exit 3, route=local (no jq needed) plus the reason=jq-not-found line"
  "state-open-explicit|case_state_open_explicit|pins the literal --state open spelling in the logged gh call"
  "worktree-shares-local|case_worktree_shares_local|a git worktree add sibling of a fixture whose stop file exists: exit 3, one stop file via the common dir"
  "not-a-repo|case_not_a_repo|run outside any git repo: exit 2, message on stderr, empty stdout"
  "unknown-arg|case_unknown_arg|harness-stop.sh clear: usage on stderr, exit 2, empty stdout (there is no clear subcommand)"
  "help|case_help|--help: usage on stdout, exit 0, empty stderr"
  "never-mutates|case_never_mutates|booby-trapped rm/mv/touch/mkdir/dirname, a recording git, and the logging gh stub, across a stop-set and a stop-absent fixture: byte-identical tree listing, gh calls all issue-list, git calls all rev-parse --git-common-dir, no trap ever invoked"
  "github-multi-document|case_github_multi_document|two concatenated JSON array documents (is_json_array sees only the last, but jq length then prints two lines): stop=unknown, exit 4, reason=github-query-unavailable, no route= line, no stop=false, no retry"
  "json-field-rejected|case_json_field_rejected|stub self-test: an unsupported --json field is rejected the way real gh rejects it"
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
    if [ -n "$stop_stderr" ]; then
      printf '%s\n' "$stop_stderr" | sed -n '1,40p' | sed 's/^/    | /'
    fi
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
exit 0
