#!/usr/bin/env bash
#
# selfcheck.sh — mechanical verification gate for the trail-blazer-flow harness itself
# (this repo, not a repo that consumes the plugin).
#
# Usage: dev/selfcheck.sh [root]
#   root defaults to the directory above this script, so `bash dev/selfcheck.sh` from
#   anywhere works, and a `root` argument lets you point it at a perturbed temp copy for
#   negative testing without touching this checkout.
#
# Five groups, 48 assertions total. The gate prints what it checks — run it.
#
# Read-only: writes no files, mutates nothing (no chmod, no auto-fix), makes no network
# calls. Prints one PASS/FAIL line per assertion and a `== summary: N pass, M fail ==`
# footer; exits 0 iff nothing failed.
set -uo pipefail

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$root" 2>/dev/null || { echo "  FAIL  cannot cd to root: $root"; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "  FAIL  jq not installed — required for the JSON-manifest and skill-frontmatter checks"
  exit 1
fi

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

# frontmatter_text FILE — prints lines 1..(second '^---$' line), inclusive.
frontmatter_text() {
  awk '
    $0 == "---" {
      c++
      print
      if (c == 2) exit
      next
    }
    { print }
  ' "$1"
}

# fence_lines FILE — prints the 1-indexed line numbers of the two '^```$' lines (one per
# line of output; empty output for a missing marker).
fence_lines() {
  grep -n '^```$' "$1" | cut -d: -f1
}

# _lines STR — prints STR followed by a newline, or nothing for an empty STR — so an empty set
# feeds `comm`/`sort` as zero lines rather than one blank line.
_lines() { [ -n "$1" ] && printf '%s\n' "$1" || true; }

echo "== trail-blazer-flow selfcheck: $root =="

# ============================================================================
echo
echo "-- Group 1: shell syntax, portability, and error handling --"

# 1.1 — bash -n on every bin/*.sh, every dev/*.sh, and every hooks/*.sh.
bad_files=""
for s in "$root"/bin/*.sh "$root"/dev/*.sh "$root"/hooks/*.sh; do
  [ -f "$s" ] || continue
  err="$(bash -n "$s" 2>&1 >/dev/null)" || bad_files="$bad_files $s: $err;"
done
if [ -z "$bad_files" ]; then
  ok "1.1 bash -n passes on all bin/*.sh, dev/*.sh, and hooks/*.sh"
else
  bad "1.1 bash -n failed —$bad_files"
fi

# 1.2 — every bin/*.sh, dev/*.sh, and hooks/*.sh line 1 is exactly '#!/usr/bin/env bash' and has
# a 'set -' line.
bad_files=""
for s in "$root"/bin/*.sh "$root"/dev/*.sh "$root"/hooks/*.sh; do
  [ -f "$s" ] || continue
  first="$(head -n1 "$s")"
  if [ "$first" != "#!/usr/bin/env bash" ]; then
    bad_files="$bad_files $s(shebang: '$first')"
    continue
  fi
  grep -q '^set -' "$s" || bad_files="$bad_files $s(no 'set -' line)"
done
if [ -z "$bad_files" ]; then
  ok "1.2 every bin/*.sh, dev/*.sh, and hooks/*.sh starts with '#!/usr/bin/env bash' and has a 'set -' line"
else
  bad "1.2 shebang/set- check failed —$bad_files"
fi

# 1.4 — no GNU-only shell constructs in bin/*.sh or hooks/*.sh: grep -P/--perl-regexp, sed
# -i/--in-place without a suffix (sed -i.bak stays legal), readlink -f/--canonicalize,
# mapfile/readarray, declare/typeset/local -A. Full-line comments are stripped before matching;
# the pattern then matches anywhere else in the line, including inside quotes/heredocs — a
# comment is the only safe place to name these constructs in bin/*.sh or hooks/*.sh. dev/*.sh
# follows the same rule by convention (CLAUDE.md), not mechanically — dev/ is exempt so this gate
# never has to self-scan its own vocabulary of forbidden words.
genopt='([[:space:]]+--?[A-Za-z][A-Za-z-]*)*'
forbidden_pat="(grep${genopt}[[:space:]]+(-[A-Za-z]*P|--perl-regexp)([[:space:]]|\$)|sed${genopt}[[:space:]]+(-[A-Za-z]*i|--in-place)([[:space:]]|\$)|readlink${genopt}[[:space:]]+(-[A-Za-z]*f|--canonicalize)([[:space:]]|\$)|(declare|typeset|local)${genopt}[[:space:]]+(-[A-Za-z]*A)([[:space:]]|\$)|mapfile([[:space:]]|\$)|readarray([[:space:]]|\$))"
bad_list=""
for s in "$root"/bin/*.sh "$root"/hooks/*.sh; do
  [ -f "$s" ] || continue
  hits="$(grep -vnE '^[[:space:]]*#' "$s" | grep -E "$forbidden_pat")"
  [ -z "$hits" ] || bad_list="$bad_list $s: $(printf '%s' "$hits" | tr '\n' ' ');"
done
if [ -z "$bad_list" ]; then
  ok "1.4 no GNU-only constructs (grep -P, sed -i without suffix, readlink -f, mapfile/readarray, declare -A) in bin/*.sh or hooks/*.sh"
else
  bad "1.4 GNU-only construct(s) found —$bad_list"
fi

# 1.6 — no 'eval' in hooks/*.sh: the guard hook must never eval anything derived from an
# untrusted Bash command string. Same comment-stripping idiom as 1.4/1.5.
bad_list=""
for s in "$root"/hooks/*.sh; do
  [ -f "$s" ] || continue
  hits="$(grep -vnE '^[[:space:]]*#' "$s" | grep -E '(^|[^A-Za-z0-9_])eval([^A-Za-z0-9_]|$)')"
  [ -z "$hits" ] || bad_list="$bad_list $s: $(printf '%s' "$hits" | tr '\n' ' ');"
done
if [ -z "$bad_list" ]; then
  ok "1.6 no 'eval' in hooks/*.sh"
else
  bad "1.6 'eval' found in hooks/*.sh —$bad_list"
fi

# 1.5 — no unguarded 'git branch -d/-D/--delete' in bin/*.sh: a bare delete aborts the whole
# script the moment git refuses (e.g. a stale worktree still holds the branch) under
# 'set -euo pipefail' — see cleanup-after-merge.sh's history. A delete is safe only when its
# line is an if/elif/while/until condition (so a failing command substitution doesn't trip
# set -e) or carries a '||' fallback. Known limitation: a delete invocation split across
# continuation lines is out of reach here — keep it on one line. Scans bin/*.sh only, not
# dev/*.sh, for the same reason as 1.4 — dev/selfcheck-tests.sh's own perturbation functions
# must be free to contain the unguarded form (that's the point of the 1.5 test case) without
# self-flagging.
del_pat='git[[:space:]]+branch[[:space:]]+(-[A-Za-z]*[dD][A-Za-z]*|--delete)([[:space:]]|$)'
guard_pat='(^[0-9]+:[[:space:]]*((el)?if|while|until)[[:space:]]|\|\|)'
bad_list=""
for s in "$root"/bin/*.sh; do
  [ -f "$s" ] || continue
  hits="$(grep -vnE '^[[:space:]]*#' "$s" | grep -E "$del_pat" | grep -vE "$guard_pat")"
  [ -z "$hits" ] || bad_list="$bad_list $s: $(printf '%s' "$hits" | tr '\n' ' ');"
done
if [ -z "$bad_list" ]; then
  ok "1.5 no unguarded 'git branch -d/-D/--delete' in bin/*.sh"
else
  bad "1.5 unguarded 'git branch' delete found —$bad_list"
fi

# ============================================================================
echo
echo "-- Group 2: JSON manifests --"

plugin_json="$root/.claude-plugin/plugin.json"
marketplace_json="$root/.claude-plugin/marketplace.json"
settings_json="$root/templates/repo-settings.json"
hooks_json="$root/hooks/hooks.json"

# 2.1 — all four JSON files parse.
bad_files=""
for f in "$plugin_json" "$marketplace_json" "$settings_json" "$hooks_json"; do
  jq -e . "$f" >/dev/null 2>&1 || bad_files="$bad_files $f"
done
if [ -z "$bad_files" ]; then
  ok "2.1 plugin.json, marketplace.json, templates/repo-settings.json, and hooks/hooks.json all parse as JSON"
else
  bad "2.1 invalid/unreadable JSON:$bad_files"
fi

# 2.2 — plugin.json .version matches semver X.Y.Z.
version="$(jq -r '.version // empty' "$plugin_json" 2>/dev/null)"
if printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  ok "2.2 plugin.json .version ('$version') matches ^[0-9]+\\.[0-9]+\\.[0-9]+\$"
else
  bad "2.2 plugin.json .version ('$version') does not match ^[0-9]+\\.[0-9]+\\.[0-9]+\$"
fi

# 2.3 — marketplace.json .plugins[0].name equals plugin.json .name.
mname="$(jq -r '.plugins[0].name // empty' "$marketplace_json" 2>/dev/null)"
pname="$(jq -r '.name // empty' "$plugin_json" 2>/dev/null)"
if [ -n "$pname" ] && [ "$mname" = "$pname" ]; then
  ok "2.3 marketplace.json .plugins[0].name ('$mname') matches plugin.json .name"
else
  bad "2.3 marketplace.json .plugins[0].name ('$mname') != plugin.json .name ('$pname')"
fi

# 2.4 — bijection: bin/*.sh basenames <-> 'Bash(<name>.sh:*)' allow entries in
# templates/repo-settings.json. Report both directions separately.
allow_list="$(jq -r '.permissions.allow[]? // empty' "$settings_json" 2>/dev/null \
  | grep -oE '^Bash\([A-Za-z0-9._-]+\.sh:' \
  | sed -E 's/^Bash\(//; s/:$//' \
  | sort -u)"
bin_list="$( (cd "$root/bin" 2>/dev/null && ls -1 *.sh 2>/dev/null) | sort -u)"
scripts_without_grant="$(comm -13 <(_lines "$allow_list") <(_lines "$bin_list"))"
grants_without_script="$(comm -23 <(_lines "$allow_list") <(_lines "$bin_list"))"
if [ -z "$scripts_without_grant" ] && [ -z "$grants_without_script" ]; then
  ok "2.4 bin/*.sh <-> templates/repo-settings.json allow-list bijection holds"
else
  msg="2.4 bijection broken:"
  [ -n "$scripts_without_grant" ] && msg="$msg bin/ script(s) with no allow entry: $(printf '%s' "$scripts_without_grant" | tr '\n' ' ');"
  [ -n "$grants_without_script" ] && msg="$msg allow entry(ies) with no bin/ script: $(printf '%s' "$grants_without_script" | tr '\n' ' ');"
  bad "$msg"
fi

# 2.5 — permission mirror, allow side, re-pointed at the guard hook (#150 deleted the nine
# `Bash(git -C * <sub> *)` allow entries; hooks/git-c-guard.sh covers those forms instead). Three
# clauses, folded into one assertion so the count stays unchanged:
#   (a) the hook's subcommand list extracts with an anchored sed -nE, same idiom as 4.13's
#       STAGES= extraction — an empty extraction FAILs loudly ("structure changed"), never a
#       vacuous pass;
#   (b) every extracted subcommand has a bare `Bash(git <sub>` allow entry in the template — the
#       mechanical pin that no bare-form rule was removed while the hook still lists it
#       (sequential mode depends on the bare forms existing independently; `reset` legitimately
#       matches `Bash(git reset --soft:*)`);
#   (c) the template's allow array contains NO entry beginning `Bash(git -C ` — the
#       wildcard-warning regression pin (deleting the nine allows is the whole point of #150; if
#       one comes back, clause (a)/(b) alone would stay vacuously green because the hook's own
#       list is the only source they compare against).
allow_raw="$(jq -r '.permissions.allow[]? // empty' "$settings_json" 2>/dev/null)"
hook_subs="$(sed -nE 's/^GIT_C_SUBCOMMANDS="([^"]*)"$/\1/p' "$root/hooks/git-c-guard.sh" | tr ' ' '\n' | grep -v '^$' | sort -u)"
c_allow_present="$(printf '%s\n' "$allow_raw" | grep -c '^Bash(git -C ')"
if [ -z "$hook_subs" ]; then
  bad "2.5 permission mirror (allow): hooks/git-c-guard.sh's GIT_C_SUBCOMMANDS= line didn't match (structure changed) — extraction failed"
else
  missing_bare=""
  for sub in $hook_subs; do
    printf '%s\n' "$allow_raw" | grep -qF -- "Bash(git $sub" || missing_bare="$missing_bare $sub"
  done
  if [ -n "$missing_bare" ] || [ "$c_allow_present" -ne 0 ]; then
    msg="2.5 permission mirror (allow) broken:"
    [ -n "$missing_bare" ] && msg="$msg hook subcommand(s) with no bare-form counterpart:$missing_bare;"
    [ "$c_allow_present" -ne 0 ] && msg="$msg $c_allow_present legacy 'Bash(git -C ...)' allow entry(ies) present — these trip Claude Code's startup wildcard warning and are superseded by the guard hook;"
    bad "$msg"
  else
    ok "2.5 permission mirror (allow): every hook subcommand has a bare-form counterpart, and no legacy -C allow entry remains"
  fi
fi

# 2.6 — permission mirror, deny side: every bare git deny has a `-C` mirror, and vice versa.
# An unmirrored deny is a real bypass (deny rules are prefix-matched the same way as allows, so
# `git -C <worktree> push --force` would slip past a guard that stops the bare form). The bare
# extraction pattern excludes `-C` entries automatically — they don't end in `:*)` — and the `*`
# must be escaped (`:\*)`), or a BRE reads `:*` as "zero or more colons".
deny_raw="$(jq -r '.permissions.deny[]? // empty' "$settings_json" 2>/dev/null)"
bare_deny_phrases="$(printf '%s\n' "$deny_raw" | sed -n 's/^Bash(git \(.*\):\*)$/\1/p' | sort -u)"
c_deny_phrases="$(printf '%s\n' "$deny_raw" | sed -n 's/^Bash(git -C \* \(.*\)\*)$/\1/p' | sort -u)"
bare_without_mirror="$(comm -23 <(_lines "$bare_deny_phrases") <(_lines "$c_deny_phrases"))"
mirror_without_bare="$(comm -13 <(_lines "$bare_deny_phrases") <(_lines "$c_deny_phrases"))"
if [ -z "$bare_without_mirror" ] && [ -z "$mirror_without_bare" ]; then
  ok "2.6 permission mirror (deny): every bare git deny has a -C mirror and vice versa"
else
  msg="2.6 permission mirror (deny) broken:"
  [ -n "$bare_without_mirror" ] && msg="$msg bare git deny(ies) with no -C mirror: $(printf '%s' "$bare_without_mirror" | tr '\n' ' ');"
  [ -n "$mirror_without_bare" ] && msg="$msg -C deny mirror(s) with no bare counterpart: $(printf '%s' "$mirror_without_bare" | tr '\n' ' ');"
  bad "$msg"
fi

# 2.7 — hooks/hooks.json structure ↔ filesystem: parses (2.1 already checked); .hooks.PreToolUse
# is a non-empty array; its first element's .matcher == "Bash"; every type=="command" handler's
# .command, with ${CLAUDE_PLUGIN_ROOT} textually replaced by $root and the surrounding
# 'bash "' / '"' stripped, names a file that exists; and every type=="command" handler's `if`
# field (jq's `.["if"]`, since `if` is a jq keyword) equals the literal Bash(git -C *) (#155) —
# same shape as this assertion's own `.matcher == "Bash"` comparison: a jq-extracted JSON value
# compared to a script literal. Fails loudly on an empty extraction rather than a vacuous pass,
# same guard as 2.5/4.13: a missing or renamed "if" key makes handler_ifs shorter than
# handler_cmds, which the count comparison in this same clause catches instead of silently
# reading as zero mismatches.
pretooluse_n="$(jq -r '.hooks.PreToolUse? // [] | length' "$hooks_json" 2>/dev/null)"
first_matcher="$(jq -r '.hooks.PreToolUse[0].matcher? // empty' "$hooks_json" 2>/dev/null)"
handler_cmds="$(jq -r '.hooks.PreToolUse[]?.hooks[]? | select(.type == "command") | .command // empty' "$hooks_json" 2>/dev/null)"
expected_if='Bash(git -C *)'
handler_ifs="$(jq -r '.hooks.PreToolUse[]?.hooks[]? | select(.type == "command") | .["if"] // empty' "$hooks_json" 2>/dev/null)"
if [ -z "$pretooluse_n" ] || [ "$pretooluse_n" -eq 0 ] || [ -z "$handler_cmds" ]; then
  bad "2.7 hooks/hooks.json structure: .hooks.PreToolUse extraction failed or came back empty (structure changed)"
elif [ "$first_matcher" != "Bash" ]; then
  bad "2.7 hooks/hooks.json structure: .hooks.PreToolUse[0].matcher is '$first_matcher', expected 'Bash'"
else
  missing_script=""
  while IFS= read -r hc; do
    [ -n "$hc" ] || continue
    resolved="${hc//\$\{CLAUDE_PLUGIN_ROOT\}/$root}"
    path="$(printf '%s' "$resolved" | sed -E 's/^bash "//; s/"$//')"
    [ -f "$path" ] || missing_script="$missing_script $path"
  done <<EOF
$handler_cmds
EOF
  cmd_n="$(printf '%s\n' "$handler_cmds" | grep -c '[^[:space:]]')"
  if_ok_n="$(printf '%s\n' "$handler_ifs" | grep -c -x -F -- "$expected_if")"
  bad_if=""
  [ "$if_ok_n" -eq "$cmd_n" ] || bad_if=" only $if_ok_n of $cmd_n command handler(s) carry \"if\": \"$expected_if\";"
  if [ -z "$missing_script" ] && [ -z "$bad_if" ]; then
    ok "2.7 hooks/hooks.json structure: PreToolUse present with matcher 'Bash', every command handler resolves to an existing file and carries \"if\": \"$expected_if\""
  else
    msg="2.7 hooks/hooks.json structure broken:"
    [ -n "$missing_script" ] && msg="$msg command handler(s) resolve to a nonexistent file:$missing_script;"
    [ -n "$bad_if" ] && msg="$msg$bad_if"
    bad "$msg"
  fi
fi

# ============================================================================
echo
echo "-- Group 3: agent instruction-file invariants --"

# 3.1 — frontmatter has name/description/tools/model; name equals the filename without .md.
bad_list=""
for f in "$root"/agents/*.md; do
  base="$(basename "$f" .md)"
  fm="$(frontmatter_text "$f")"
  for k in 'name:' 'description:' 'tools:' 'model:'; do
    printf '%s\n' "$fm" | grep -q "^$k" || bad_list="$bad_list $f(missing '$k')"
  done
  name_field="$(printf '%s\n' "$fm" | sed -n 's/^name: *//p' | head -1 | tr -d '[:space:]')"
  [ "$name_field" = "$base" ] || bad_list="$bad_list $f(name='$name_field' != '$base')"
done
if [ -z "$bad_list" ]; then
  ok "3.1 every agents/*.md frontmatter has name/description/tools/model, name == filename"
else
  bad "3.1 frontmatter problems:$bad_list"
fi

# 3.4 — exactly one harness-status line, inside the fence, matching the canonical grammar with
# stage == the frontmatter name. bin/reconcile-ledger.sh:~95's `sed -E` is the consumer of this
# grammar — a drift here breaks its status-line-to-record rewrite.
bad_list=""
for f in "$root"/agents/*.md; do
  base="$(basename "$f" .md)"
  hs_count="$(grep -c '<!-- harness-status:' "$f")"
  if [ "$hs_count" -ne 1 ]; then
    bad_list="$bad_list $f(status-line count=$hs_count)"
    continue
  fi
  hs_lineno="$(grep -n '<!-- harness-status:' "$f" | cut -d: -f1)"
  hs_text="$(grep '<!-- harness-status:' "$f")"

  fences="$(fence_lines "$f")"
  t1="$(printf '%s\n' "$fences" | sed -n '1p')"
  t2="$(printf '%s\n' "$fences" | sed -n '2p')"
  if [ -z "$t1" ] || [ -z "$t2" ] || [ "$hs_lineno" -le "$t1" ] || [ "$hs_lineno" -ge "$t2" ]; then
    bad_list="$bad_list $f(status line not inside the fenced block)"
    continue
  fi

  if ! printf '%s' "$hs_text" | grep -qE "^<!-- harness-status: stage=${base} issue=<n> outcome=<[A-Za-z|-]+> retries=<k> -->\$"; then
    bad_list="$bad_list $f(status line doesn't match the canonical grammar for stage=$base)"
  fi
done
if [ -z "$bad_list" ]; then
  ok "3.4 harness-status line: exactly one, inside the fence, grammar+stage correct"
else
  bad "3.4 harness-status problems:$bad_list"
fi

# 3.7 — required template headings (referenced by exact name elsewhere, or required by a
# documented contract) exist inside the fenced block.
pairs=(
  "planner.md|## Acceptance criteria"       # referenced by agents/verifier.md
  "planner.md|## Verified facts"            # referenced by agents/verifier.md and skills/issue-implementer/SKILL.md
  "planner.md|## Follow-ups to file"        # referenced by README.md and skills/test-ratchet/SKILL.md
  "planner.md|### Claims this change falsifies" # referenced by README.md
  "planner.md|## Reserve touch list"        # referenced by skills/issue-planner/SKILL.md
  "implementer.md|## Resume brief"          # referenced by skills/issue-implementer/SKILL.md
  "implementer.md|## Evidence"              # the pre-report evidence contract; also referenced by skills/issue-implementer/SKILL.md; deleting the block must fail the gate
  "verifier.md|## Notes for the PR reviewer" # referenced by skills/issue-implementer/SKILL.md
  "verifier.md|## Mutation probe"           # referenced by skills/issue-implementer/SKILL.md
  "verifier.md|## Reserve touch check"      # referenced by skills/issue-implementer/SKILL.md
)
bad_list=""
for p in "${pairs[@]}"; do
  hfile="${p%%|*}"
  heading="${p#*|}"
  f="$root/agents/$hfile"
  fences="$(fence_lines "$f")"
  t1="$(printf '%s\n' "$fences" | sed -n '1p')"
  t2="$(printf '%s\n' "$fences" | sed -n '2p')"
  if [ -z "$t1" ] || [ -z "$t2" ]; then
    bad_list="$bad_list [$hfile:$heading (no fenced block)]"
    continue
  fi
  # search only inside the fenced block — the heading name may also be mentioned in prose
  # (e.g. backtick-quoted) outside it, which must not count as satisfying this assertion.
  found="$(sed -n "$((t1+1)),$((t2-1))p" "$f" | grep -cF -- "$heading")"
  [ "$found" -ge 1 ] || bad_list="$bad_list [$hfile:$heading]"
done
if [ -z "$bad_list" ]; then
  ok "3.7 required template headings present inside the fenced block"
else
  bad "3.7 missing or out-of-fence heading(s):$bad_list"
fi

# ============================================================================
echo
echo "-- Group 4: cross-file markers and skills --"

# 4.1 — the literal planner-plan marker appears in every file that selects a plan comment by it
# (fixed-string): the two discovery scripts and the planner skill. #176 gave
# bin/find-implementation-work.sh its own plan-selection jq program built on this same marker.
marker='<!-- planner-plan -->'
missing=""
grep -qF -- "$marker" "$root/bin/find-planning-work.sh" || missing="$missing bin/find-planning-work.sh"
grep -qF -- "$marker" "$root/bin/find-implementation-work.sh" || missing="$missing bin/find-implementation-work.sh"
grep -qF -- "$marker" "$root/skills/issue-planner/SKILL.md" || missing="$missing skills/issue-planner/SKILL.md"
if [ -z "$missing" ]; then
  ok "4.1 '$marker' present in bin/find-planning-work.sh, bin/find-implementation-work.sh, and skills/issue-planner/SKILL.md"
else
  bad "4.1 '$marker' missing from:$missing"
fi

# skill_description FILE — prints FILE's frontmatter 'description:' value with all whitespace
# removed: the inline text after 'description:' on its own line if present, otherwise (a bare
# block-scalar indicator '>'/'>-'/'>+'/'|'/'|-'/'|+' with nothing else on the line) the
# indented continuation lines that follow, up to the first non-indented line. Scoped to
# frontmatter_text so a 'description:'-looking line in the prose body can't satisfy this.
skill_description() {
  frontmatter_text "$1" | awk '
    /^description:/ && !found {
      found = 1
      val = $0
      sub(/^description:[[:space:]]*/, "", val)
      if (val ~ /^[|>][+-]?[[:space:]]*$/) { collecting = 1 } else { text = text val }
      next
    }
    collecting && /^[[:space:]]/ { text = text " " $0; next }
    collecting { collecting = 0 }
    END { gsub(/[[:space:]]+/, "", text); print text }
  '
}

# 4.2 — every skills/*/SKILL.md has frontmatter name == its containing directory, and a
# non-empty description (a bare 'description: >' with its folded body deleted must fail: the
# check extracts the actual collected value rather than just checking the next line is non-blank,
# which is also true of the next frontmatter key entirely).
bad_list=""
for f in "$root"/skills/*/SKILL.md; do
  dir="$(dirname "$f")"
  base="$(basename "$dir")"
  fm="$(frontmatter_text "$f")"
  name_field="$(printf '%s\n' "$fm" | sed -n 's/^name: *//p' | head -1 | tr -d '[:space:]')"
  [ "$name_field" = "$base" ] || bad_list="$bad_list $f(name='$name_field' != '$base')"
  desc="$(skill_description "$f")"
  [ -n "$desc" ] || bad_list="$bad_list $f(empty description)"
done
if [ -z "$bad_list" ]; then
  ok "4.2 every skills/*/SKILL.md has frontmatter name == its directory, non-empty description"
else
  bad "4.2 skill frontmatter problems:$bad_list"
fi

# 4.5 — the literal ratchet-issue marker appears in both files (fixed-string). Mirrors 4.1.
marker='<!-- ratchet-issue -->'
missing=""
grep -qF -- "$marker" "$root/skills/test-ratchet/SKILL.md" || missing="$missing skills/test-ratchet/SKILL.md"
grep -qF -- "$marker" "$root/skills/issue-planner/SKILL.md" || missing="$missing skills/issue-planner/SKILL.md"
if [ -z "$missing" ]; then
  ok "4.5 '$marker' present in skills/test-ratchet/SKILL.md and skills/issue-planner/SKILL.md"
else
  bad "4.5 '$marker' missing from:$missing"
fi

# 4.6 — bijection: labels bin/setup-labels.sh creates <-> labels bin/check-harness.sh's doctor
# requires. Report both directions separately, like 2.4. Depends on 'for l in ...; do' being
# the doctor's only such loop (see bin/check-harness.sh).
setup_labels_list="$(sed -nE 's/^create_or_update "([^"]+)".*/\1/p' "$root/bin/setup-labels.sh" | sort -u)"
doctor_labels_list="$(sed -nE 's/^[[:space:]]*for l in (.*); do$/\1/p' "$root/bin/check-harness.sh" | tr ' ' '\n' | grep -v '^$' | sort -u)"
labels_without_doctor="$(comm -23 <(_lines "$setup_labels_list") <(_lines "$doctor_labels_list"))"
doctor_without_setup="$(comm -13 <(_lines "$setup_labels_list") <(_lines "$doctor_labels_list"))"
if [ -z "$labels_without_doctor" ] && [ -z "$doctor_without_setup" ]; then
  ok "4.6 setup-labels.sh <-> check-harness.sh doctor label bijection holds"
else
  msg="4.6 label bijection broken:"
  [ -n "$labels_without_doctor" ] && msg="$msg label(s) created with no doctor check: $(printf '%s' "$labels_without_doctor" | tr '\n' ' ');"
  [ -n "$doctor_without_setup" ] && msg="$msg doctor-required label(s) with no creator: $(printf '%s' "$doctor_without_setup" | tr '\n' ' ');"
  bad "$msg"
fi

# 4.7 — every skills/ directory's basename appears (fixed-string) in README.md.
bad_list=""
for d in "$root"/skills/*/; do
  base="$(basename "$d")"
  grep -qF -- "$base" "$root/README.md" || bad_list="$bad_list $base"
done
if [ -z "$bad_list" ]; then
  ok "4.7 every skills/ directory's basename appears in README.md"
else
  bad "4.7 skill(s) not documented in README.md:$bad_list"
fi

# 4.8 — policy section titles: each must appear (exact, fixed-string) in README.md and in
# skills/harness-setup/SKILL.md — the strings bin/check-harness.sh:39's has_policy_section
# greps for. Titles contain spaces, so iterate over a heredoc.
bad_list=""
while IFS= read -r title; do
  [ -n "$title" ] || continue
  grep -qF -- "$title" "$root/README.md" || bad_list="$bad_list [$title: missing from README.md]"
  grep -qF -- "$title" "$root/skills/harness-setup/SKILL.md" || bad_list="$bad_list [$title: missing from skills/harness-setup/SKILL.md]"
done <<EOF
Plan auto-approval policy
Merge autonomy policy
Test-suite ratchet policy
Autonomy reserve
Autonomy decision record
EOF
if [ -z "$bad_list" ]; then
  ok "4.8 policy section titles cross-referenced in README.md and skills/harness-setup/SKILL.md"
else
  bad "4.8 policy-title cross-reference problem(s):$bad_list"
fi

# 4.9 — bijection: dev/*.sh basenames <-> '- run: bash dev/<name>.sh' steps in
# .github/workflows/selfcheck.yml, PLUS a per-job coverage count: every dev/*.sh script's
# run-step line count must equal the workflow's job count, so a script wired into only one of
# several jobs — satisfying the set-based bijection while quietly losing coverage in the others
# (see #58) — still fails. Report all three failure modes separately, like 2.4 (closes #63).
# A legitimate exception needs an explicit exclusion here, not a silent gap.
wf="$root/.github/workflows/selfcheck.yml"
if [ ! -f "$wf" ]; then
  bad "4.9 .github/workflows/selfcheck.yml not found"
else
  wf_steps="$(sed -nE 's|^[[:space:]]*-[[:space:]]*run:[[:space:]]*bash[[:space:]]+dev/([A-Za-z0-9._-]+\.sh)[[:space:]]*$|\1|p' "$wf" | sort -u)"
  dev_list="$( (cd "$root/dev" 2>/dev/null && ls -1 *.sh 2>/dev/null) | sort -u)"
  scripts_without_step="$(comm -13 <(_lines "$wf_steps") <(_lines "$dev_list"))"
  steps_without_script="$(comm -23 <(_lines "$wf_steps") <(_lines "$dev_list"))"
  job_count="$(grep -cE '^[[:space:]]+runs-on:' "$wf")"
  uneven=""
  for s in $dev_list; do
    s_esc="${s//./\\.}"
    n="$(grep -cE "^[[:space:]]*-[[:space:]]*run:[[:space:]]*bash[[:space:]]+dev/${s_esc}[[:space:]]*\$" "$wf")"
    [ "$n" -eq "$job_count" ] || uneven="$uneven $s($n/$job_count)"
  done
  if [ -z "$scripts_without_step" ] && [ -z "$steps_without_script" ] && [ -z "$uneven" ]; then
    ok "4.9 dev/*.sh <-> .github/workflows/selfcheck.yml run-step bijection holds"
  else
    msg="4.9 bijection broken:"
    [ -n "$scripts_without_step" ] && msg="$msg dev/ script(s) with no CI run step: $(printf '%s' "$scripts_without_step" | tr '\n' ' ');"
    [ -n "$steps_without_script" ] && msg="$msg CI run step(s) naming a nonexistent dev/ script: $(printf '%s' "$steps_without_script" | tr '\n' ' ');"
    [ -n "$uneven" ] && msg="$msg dev/ script(s) not run in every job (script(run-steps/jobs)):$uneven;"
    bad "$msg"
  fi
fi

# 4.11 — bin/check-harness.sh reads every settings file only through jq: no raw-text
# grep/sed/awk of any $settings* path variable anywhere in the file (every settings-file path
# variable in bin/check-harness.sh is named settings*, e.g. $settings, $settings_local,
# $settings_user — see #66). A raw-text read makes a rule merely *mentioned* in an unrelated
# string count as present, and can't tell the allow array from the deny array — a deny-side
# `-C` mirror pasted into the allow array would still read as "present" to a whole-file grep,
# the dangerous direction. Comments are excluded by LINE, not by character, so an indented
# comment that merely quotes "$settings" doesn't false-positive.
raw_reads="$(grep -nE '(grep|sed|awk).*"\$settings[a-z_]*"' "$root/bin/check-harness.sh" | grep -vE '^[0-9]+:[[:space:]]*#')"
if [ -z "$raw_reads" ]; then
  ok "4.11 bin/check-harness.sh reads every settings file only through jq (no raw-text grep/sed/awk of any \$settings* path variable)"
else
  bad "4.11 raw-text grep/sed/awk of a \$settings* path variable found in bin/check-harness.sh — line(s): $(printf '%s' "$raw_reads" | tr '\n' ' ')"
fi

# 4.13 — ledger stage vocabulary, three clauses:
#   (a) cross-file: bin/reconcile-ledger.sh's `STAGES=` list must agree, both directions, with
#       skills/issue-implementer/SKILL.md's status-line grammar (`stage=<...>`) — 'seed' is the
#       one documented ledger-only exception (issue-cycle step 0 writes it from the discovery
#       bucket; no agent status line ever carries stage=seed). Anchored single-line extraction
#       on both sides; an empty extraction FAILs loudly rather than vacuously passing.
#   (b) folded former-3.5: every '|'-separated outcome alternative in each agents/*.md status
#       line appears as a fixed string in skills/issue-implementer/SKILL.md (the canonical
#       Status-line vocabulary).
#   (c) deploy vocabulary: bin/reconcile-ledger.sh's `DEPLOY_OUTCOMES=` list must agree, both
#       directions, with the optional `deploy=<...>` alternatives on SKILL.md's same status-line
#       grammar line. Anchored single-line extraction on both sides; an empty extraction FAILs
#       loudly rather than vacuously passing. Folded into the shared bad_list below so the
#       assertion count is unchanged by this clause.
rl="$root/bin/reconcile-ledger.sh"
sk="$root/skills/issue-implementer/SKILL.md"
bad_list=""
hs_count="$(grep -c 'harness-status: stage=<' "$sk")"
script_stages="$(sed -nE 's/^STAGES="([^"]*)"$/\1/p' "$rl" | tr ' ' '\n' | sort -u)"
if [ "$hs_count" -ne 1 ] || [ -z "$script_stages" ]; then
  bad_list=" extraction failed — SKILL.md's status-line grammar count is $hs_count (expected 1) or bin/reconcile-ledger.sh's STAGES= line didn't match (structure changed)"
else
  skill_stages="$(sed -nE 's/.*harness-status: stage=<([^>]*)>.*/\1/p' "$sk" | tr '|' '\n' | sort -u)"
  agent_stages="$(comm -23 <(_lines "$script_stages") <(_lines "seed"))"
  script_not_skill="$(comm -23 <(_lines "$agent_stages") <(_lines "$skill_stages"))"
  skill_not_script="$(comm -13 <(_lines "$agent_stages") <(_lines "$skill_stages"))"
  [ -n "$script_not_skill" ] && bad_list="$bad_list stage(s) the script accepts with no status-line alternative: $(printf '%s' "$script_not_skill" | tr '\n' ' ');"
  [ -n "$skill_not_script" ] && bad_list="$bad_list status-line stage(s) the script would reject: $(printf '%s' "$skill_not_script" | tr '\n' ' ');"
  printf '%s\n' "$script_stages" | grep -qxF -- "seed" || bad_list="$bad_list documented ledger-only stage 'seed' no longer accepted by the script;"
fi
for f in "$root"/agents/*.md; do
  hs_text="$(grep '<!-- harness-status:' "$f" | head -1)"
  alt_list="$(printf '%s' "$hs_text" | sed -nE 's/.*outcome=<([^>]*)>.*/\1/p' | tr '|' '\n')"
  for alt in $alt_list; do
    [ -z "$alt" ] && continue
    grep -qF -- "$alt" "$sk" || bad_list="$bad_list $f:$alt (outcome alternative missing from SKILL.md);"
  done
done
script_deploy="$(sed -nE 's/^DEPLOY_OUTCOMES="([^"]*)"$/\1/p' "$rl" | tr ' ' '\n' | sort -u)"
skill_deploy="$(sed -nE 's/.*deploy=<([^>]*)>.*/\1/p' "$sk" | tr '|' '\n' | sort -u)"
if [ -z "$script_deploy" ] || [ -z "$skill_deploy" ]; then
  bad_list="$bad_list deploy-vocabulary extraction failed — bin/reconcile-ledger.sh's DEPLOY_OUTCOMES= line or SKILL.md's deploy=<...> alternative didn't match (structure changed);"
else
  script_not_skill_deploy="$(comm -23 <(_lines "$script_deploy") <(_lines "$skill_deploy"))"
  skill_not_script_deploy="$(comm -13 <(_lines "$script_deploy") <(_lines "$skill_deploy"))"
  [ -n "$script_not_skill_deploy" ] && bad_list="$bad_list deploy outcome(s) the script accepts with no status-line alternative: $(printf '%s' "$script_not_skill_deploy" | tr '\n' ' ');"
  [ -n "$skill_not_script_deploy" ] && bad_list="$bad_list status-line deploy outcome(s) the script would reject: $(printf '%s' "$skill_not_script_deploy" | tr '\n' ' ');"
fi
if [ -z "$bad_list" ]; then
  ok "4.13 ledger stage vocabulary agrees with SKILL.md; every agent outcome alternative appears in SKILL.md"
else
  bad "4.13 ledger/status-line vocabulary drift:$bad_list"
fi

# 4.14 — per-skill size budget: wc -l on every skills/*/SKILL.md against a fixed table — the
# anti-regrowth control replacing the old restated-keyword checks (former 3.6, 4.10): a line
# budget is cheaper to keep honest and catches regrowth regardless of which words come back.
# Raising a budget here is a legitimate, reviewable one-line edit when growth is justified — this
# assertion only says "look at this diff" (recipe: per-file cap = the next multiple of 5 strictly
# above the actual, so every file keeps 1-5 lines of headroom. Caps ratchet down as files shrink).
# references/worktree-mode.md is deliberately unbudgeted (the glob is skills/*/SKILL.md only) —
# read on demand, not on every run.
budget_table="issue-implementer 490
issue-cycle 330
issue-planner 430
project-kickoff 215
test-ratchet 200
harness-setup 185"
bad_list=""
while IFS=' ' read -r skill cap; do
  [ -n "$skill" ] || continue
  f="$root/skills/$skill/SKILL.md"
  [ -f "$f" ] || { bad_list="$bad_list skills/$skill/SKILL.md missing;"; continue; }
  n="$(wc -l < "$f" | tr -d '[:space:]')"
  [ "$n" -le "$cap" ] || bad_list="$bad_list skills/$skill/SKILL.md: $n lines > budget $cap;"
done <<EOF
$budget_table
EOF
if [ -z "$bad_list" ]; then
  ok "4.14 every skills/*/SKILL.md is within its size budget"
else
  bad "4.14 size budget exceeded:$bad_list"
fi

# 4.15 — no inline command substitution in the instruction surface. Probe #55 found that no
# allow rule can approve a Bash command containing command substitution — dollar-paren or
# backtick, which behave identically — even when every constituent command is individually
# granted; such a command instead falls through to the session's permission mode, so one written
# into a skill/agent instruction degrades silently (silent auto-approval under 'auto') instead of
# failing loudly. Scoped to skills/*/SKILL.md, skills/*/references/*.md, and agents/*.md.
# README.md, bin/*.sh, and dev/*.sh are deliberately OUT of scope: README documents the literal
# syntax on purpose (that's the one place it should appear), and the bin/dev scripts are code,
# not instructions handed to a subagent. Backtick substitution isn't checkable here — Markdown
# inline-code spans use backticks legitimately — so the two-character dollar-paren token is used
# as the proxy for both forms; accepted cost: none of the scanned files can spell that token even
# in prose (e.g. to describe the syntax) without tripping this assertion.
bad_list=""
for f in "$root"/skills/*/SKILL.md "$root"/skills/*/references/*.md "$root"/agents/*.md; do
  [ -f "$f" ] || continue
  lines="$(grep -Fn '$(' "$f" | cut -d: -f1)"
  for ln in $lines; do
    bad_list="$bad_list $f:$ln"
  done
done
if [ -z "$bad_list" ]; then
  ok "4.15 no inline command substitution (dollar-paren/backtick proxy) in skills/*/SKILL.md, skills/*/references/*.md, or agents/*.md"
else
  bad "4.15 dollar-paren substitution found — run the inner command separately and paste its literal result instead:$bad_list"
fi

# 4.16 — the literal harness-follow-up marker prefix appears in both files (fixed-string).
# Mirrors 4.1/4.5. Pins only the prefix — the PR number varies per issue, so the full marker
# is never a fixed string.
marker='<!-- harness-follow-up: PR #'
missing=""
grep -qF -- "$marker" "$root/skills/issue-implementer/SKILL.md" || missing="$missing skills/issue-implementer/SKILL.md"
grep -qF -- "$marker" "$root/bin/cleanup-after-merge.sh" || missing="$missing bin/cleanup-after-merge.sh"
if [ -z "$missing" ]; then
  ok "4.16 '$marker' present in skills/issue-implementer/SKILL.md and bin/cleanup-after-merge.sh"
else
  bad "4.16 '$marker' missing from:$missing"
fi

# 4.17 — the literal harness-multi-pr marker appears in the script, the README, and the
# implementer skill (fixed-string). Mirrors 4.1/4.5/4.16 — a human plans a multi-PR issue split
# up front by putting this marker in the issue body or a comment, so cleanup-after-merge.sh's
# label hygiene never closes it after the first slice merges.
marker='<!-- harness-multi-pr -->'
missing=""
grep -qF -- "$marker" "$root/bin/cleanup-after-merge.sh" || missing="$missing bin/cleanup-after-merge.sh"
grep -qF -- "$marker" "$root/README.md" || missing="$missing README.md"
grep -qF -- "$marker" "$root/skills/issue-implementer/SKILL.md" || missing="$missing skills/issue-implementer/SKILL.md"
if [ -z "$missing" ]; then
  ok "4.17 '$marker' present in bin/cleanup-after-merge.sh, README.md, and skills/issue-implementer/SKILL.md"
else
  bad "4.17 '$marker' missing from:$missing"
fi

# 4.18 — the literal verifier closing-status-line prefix appears in the agent template that
# emits it, the skill that writes it into a PR body, and the skill that greps for it before
# merging. Mirrors 4.1/4.5/4.16/4.17 — this is not pinning duplicated prose (CLAUDE.md's rule):
# the needle is a marker literal that must appear in the file that writes it, the file that
# greps it, and the agent template that emits it, the same relationship 4.1 pins between the
# '<!-- planner-plan -->' marker and its consumer.
marker='<!-- harness-status: stage=verifier issue='
missing=""
for f in agents/verifier.md skills/issue-implementer/SKILL.md skills/issue-cycle/SKILL.md; do
  grep -qF -- "$marker" "$root/$f" || missing="$missing $f"
done
if [ -z "$missing" ]; then
  ok "4.18 '$marker' present in agents/verifier.md, skills/issue-implementer/SKILL.md, and skills/issue-cycle/SKILL.md"
else
  bad "4.18 '$marker' missing from:$missing"
fi

# 4.19 — the literal verifier-verdict marker and the verifier-verdict-branch key prefix both
# appear in the skill that writes them (as an issue comment, after every verifier pass) and the
# skill that checks for them before an autonomous merge. Mirrors 4.1/4.5/4.16/4.17/4.18 — a floor
# that greps for a marker nobody writes is the exact failure this pins. Like 4.16, the key marker
# is pinned only by its prefix (without the trailing space) — the branch name varies per PR, so
# the full key line is never a fixed string; the fine-grained spacing of the writer's key-line
# template is left to assertion 5.7. #176 gave bin/find-implementation-work.sh its own
# verdict-marker exclusion (a verifier-verdict comment is never binding human context, so it's
# excluded from trusted_post_plan), so the verdict marker is pinned there too; #182 gave
# bin/find-planning-work.sh the symmetric planner-side exclusion (a verdict archive never
# re-triggers a revision), so the verdict marker is pinned there too.
missing=""
for marker in '<!-- verifier-verdict -->' '<!-- verifier-verdict-branch:'; do
  for f in skills/issue-implementer/SKILL.md skills/issue-cycle/SKILL.md; do
    grep -qF -- "$marker" "$root/$f" || missing="$missing $f($marker)"
  done
done
grep -qF -- '<!-- verifier-verdict -->' "$root/bin/find-implementation-work.sh" || missing="$missing bin/find-implementation-work.sh(<!-- verifier-verdict -->)"
grep -qF -- '<!-- verifier-verdict -->' "$root/bin/find-planning-work.sh" || missing="$missing bin/find-planning-work.sh(<!-- verifier-verdict -->)"
if [ -z "$missing" ]; then
  ok "4.19 '<!-- verifier-verdict -->' and '<!-- verifier-verdict-branch:' present in skills/issue-implementer/SKILL.md, skills/issue-cycle/SKILL.md, bin/find-implementation-work.sh, and bin/find-planning-work.sh"
else
  bad "4.19 markers missing from:$missing"
fi

# 4.20 — bijection: 'gh pr <sub>' invocations named in skills/*/SKILL.md and
# skills/*/references/*.md <-> 'Bash(gh pr <sub>:*)' allow entries in
# templates/repo-settings.json, with 'merge' as the single documented exception (merge is only
# ever reached through the deny-lifted merge pass — see the merge pass's activation contract —
# never a plain allow grant). Report both directions separately, like 2.4, plus a clause that
# Bash(gh pr merge:*) is still present in permissions.deny (mirrors 4.13's 'seed' clause), so the
# exception can't be used to quietly hide a granted merge.
skill_pr_subs="$(grep -ohE 'gh pr [a-z]+' "$root"/skills/*/SKILL.md "$root"/skills/*/references/*.md 2>/dev/null \
  | sed -E 's/^gh pr //' \
  | sort -u)"
allow_pr_subs="$(jq -r '.permissions.allow[]? // empty' "$settings_json" 2>/dev/null \
  | grep -oE '^Bash\(gh pr [a-z]+:' \
  | sed -E 's/^Bash\(gh pr //; s/:$//' \
  | sort -u)"
skill_pr_subs_noexc="$(comm -23 <(_lines "$skill_pr_subs") <(_lines "merge"))"
subs_without_grant="$(comm -23 <(_lines "$skill_pr_subs_noexc") <(_lines "$allow_pr_subs"))"
grants_without_sub="$(comm -13 <(_lines "$skill_pr_subs_noexc") <(_lines "$allow_pr_subs"))"
deny_has_merge="no"
jq -r '.permissions.deny[]? // empty' "$settings_json" 2>/dev/null | grep -qxF 'Bash(gh pr merge:*)' && deny_has_merge="yes"
if [ -z "$subs_without_grant" ] && [ -z "$grants_without_sub" ] && [ "$deny_has_merge" = "yes" ]; then
  ok "4.20 'gh pr <sub>' <-> templates/repo-settings.json allow-list bijection holds ('merge' excepted, still denied)"
else
  msg="4.20 bijection broken:"
  [ -n "$subs_without_grant" ] && msg="$msg gh pr subcommand(s) named in skills/ with no allow entry: $(printf '%s' "$subs_without_grant" | tr '\n' ' ');"
  [ -n "$grants_without_sub" ] && msg="$msg allow entry(ies) for a gh pr subcommand no skill names: $(printf '%s' "$grants_without_sub" | tr '\n' ' ');"
  [ "$deny_has_merge" = "yes" ] || msg="$msg Bash(gh pr merge:*) missing from permissions.deny — the 'merge' exception must stay denied;"
  bad "$msg"
fi

# 4.21 — fixed-string presence of 'Autonomy reserve' in the three files that make up the
# run-time enforcement chain: the planner that populates the Reserve touch list, the orchestrator
# that hands the declared globs to the verifier, and the verifier that checks the diff against
# them. 4.8 already pins the *declaration* side (README + harness-setup); this pins the
# *enforcement* side — a drift in any one of the three silently disables the run-time check.
marker='Autonomy reserve'
missing=""
for f in agents/planner.md agents/verifier.md skills/issue-implementer/SKILL.md; do
  grep -qF -- "$marker" "$root/$f" || missing="$missing $f"
done
if [ -z "$missing" ]; then
  ok "4.21 '$marker' present in agents/planner.md, agents/verifier.md, and skills/issue-implementer/SKILL.md"
else
  bad "4.21 '$marker' missing from:$missing"
fi

# 4.22 — fixed-string presence of 'Post-merge verification' in README.md and
# skills/issue-cycle/SKILL.md. The README tells the user to title the sub-heading exactly this;
# the merge pass matches it exactly for both guard (e) and the pre-first-merge recheck, so a
# drift makes both silently inert.
marker='Post-merge verification'
missing=""
grep -qF -- "$marker" "$root/README.md" || missing="$missing README.md"
grep -qF -- "$marker" "$root/skills/issue-cycle/SKILL.md" || missing="$missing skills/issue-cycle/SKILL.md"
if [ -z "$missing" ]; then
  ok "4.22 '$marker' present in README.md and skills/issue-cycle/SKILL.md"
else
  bad "4.22 '$marker' missing from:$missing"
fi

# 4.23 — fixed-string presence of '-wt-' in hooks/git-c-guard.sh,
# skills/issue-implementer/references/worktree-mode.md, and skills/issue-implementer/SKILL.md.
# Mirrors 4.1/4.5/4.16/4.17 — the guard hook's path ERE and worktree-mode's directory-naming
# convention must agree on this literal, or a rename of the worktree directory convention
# silently stops the hook from ever matching (a permission prompt on every -C command, not a
# loud failure).
marker='-wt-'
missing=""
grep -qF -- "$marker" "$root/hooks/git-c-guard.sh" || missing="$missing hooks/git-c-guard.sh"
grep -qF -- "$marker" "$root/skills/issue-implementer/references/worktree-mode.md" || missing="$missing skills/issue-implementer/references/worktree-mode.md"
grep -qF -- "$marker" "$root/skills/issue-implementer/SKILL.md" || missing="$missing skills/issue-implementer/SKILL.md"
if [ -z "$missing" ]; then
  ok "4.23 '$marker' present in hooks/git-c-guard.sh, worktree-mode.md, and skills/issue-implementer/SKILL.md"
else
  bad "4.23 '$marker' missing from:$missing"
fi

# 4.24 — every `uses:` line in .github/workflows/*.yml|*.yaml is pinned to a full 40-hex commit
# SHA, never a mutable tag or branch ref: this workflow's own green check is the mechanical merge
# condition the harness's merge pass trusts, so a repointable tag (e.g. actions/checkout@v4) would
# let the action's owner substitute what CI executes with no diff visible here — the gate's own
# verdict is the blast radius. The extraction is comment-stripped by LINE first (same idiom as
# 4.11/1.4), so a commented-out unpinned `uses:` line can't false-positive. A zero-`uses:`
# extraction across every workflow file FAILs loudly ("structure changed") rather than passing
# vacuously, same guard as 2.5/2.7/4.13. Only the SHA is enforced here — the trailing `# vX.Y.Z`
# tag comment is left as a review-level convention, not machine-checked. A future local (`./…`) or
# `docker://` action ref cannot be SHA-pinned this way; that needs an explicit exclusion added to
# this assertion, not a silent gap — the same policy assertion 4.9's comment states.
uses_total=0
bad_uses=""
for wf24 in "$root"/.github/workflows/*.yml "$root"/.github/workflows/*.yaml; do
  [ -f "$wf24" ] || continue
  uses_lines="$(grep -vE '^[[:space:]]*#' "$wf24" | grep -E '^[[:space:]]*-?[[:space:]]*uses:')"
  [ -n "$uses_lines" ] || continue
  while IFS= read -r ul; do
    [ -n "$ul" ] || continue
    uses_total=$((uses_total+1))
    ref="$(printf '%s\n' "$ul" | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//; s/[[:space:]].*$//')"
    case "$ref" in
      *@*) sha="${ref##*@}" ;;
      *)   sha="" ;;
    esac
    case "$sha" in
      ''|*[!0-9a-f]*) bad_uses="$bad_uses $wf24:$ref;" ;;
      *) [ "${#sha}" -eq 40 ] || bad_uses="$bad_uses $wf24:$ref;" ;;
    esac
  done <<EOF
$uses_lines
EOF
done
if [ "$uses_total" -eq 0 ]; then
  bad "4.24 no \`uses:\` line found in .github/workflows/*.yml or *.yaml (structure changed) — extraction failed"
elif [ -n "$bad_uses" ]; then
  bad "4.24 uses: ref(s) not pinned to a full 40-hex commit SHA:$bad_uses"
else
  ok "4.24 every \`uses:\` line in .github/workflows/*.yml|*.yaml is pinned to a full 40-hex commit SHA"
fi

# 4.25 — .github/dependabot.yml exists and declares a weekly github-actions update, so the
# 4.24 SHA pin has a mechanism to age forward instead of only being enforced at the pin's
# current value forever: a SHA pin never moves on its own, and deleting or misconfiguring this
# file leaves the gate green while the pin ages out — exactly the gap #167 exists to close.
# The extraction is comment-stripped by LINE first (same idiom as 4.11/1.4/4.24), so a
# commented-out declaration can't false-positive. The two clauses (package-ecosystem and
# interval) are checked independently, file-wide, because the file declares a single `updates`
# entry — a second entry for another ecosystem would need block-scoped parsing added here
# explicitly, not left as a silent gap, the same policy 4.9's and 4.24's comments state.
dbot="$root/.github/dependabot.yml"
if [ ! -f "$dbot" ]; then
  bad "4.25 .github/dependabot.yml not found — nothing bumps the actions/checkout SHA pin (assertion 4.24) forward"
else
  dbot_body="$(grep -vE '^[[:space:]]*#' "$dbot")"
  miss_25=""
  printf '%s\n' "$dbot_body" | grep -qE '^[[:space:]]*-?[[:space:]]*package-ecosystem:[[:space:]]*"?github-actions"?[[:space:]]*$' \
    || miss_25="$miss_25 no uncommented package-ecosystem: \"github-actions\" line;"
  printf '%s\n' "$dbot_body" | grep -qE '^[[:space:]]*interval:' \
    || miss_25="$miss_25 no uncommented interval: line;"
  if [ -n "$miss_25" ]; then
    bad "4.25 .github/dependabot.yml missing:$miss_25"
  else
    ok "4.25 .github/dependabot.yml declares an uncommented github-actions package-ecosystem update with a weekly interval"
  fi
fi

# 4.26 — the two discovery scripts' TRUSTED_ASSOCIATIONS declarations agree (#176 extended
# bin/find-implementation-work.sh with the same trust gate bin/find-planning-work.sh already
# has, rather than forking it — this pins that they didn't drift apart). Anchored single-line
# extraction on both sides, same idiom as 2.5(a)/4.13 — an empty extraction on either side FAILs
# loudly ("structure changed") rather than passing vacuously; a non-empty extraction is
# normalised (space-separated -> one association per line, sorted, de-duplicated) and compared
# both directions with comm.
planning_trusted="$(sed -nE 's/^TRUSTED_ASSOCIATIONS="([^"]*)"$/\1/p' "$root/bin/find-planning-work.sh" | tr ' ' '\n' | grep -v '^$' | sort -u)"
impl_trusted="$(sed -nE 's/^TRUSTED_ASSOCIATIONS="([^"]*)"$/\1/p' "$root/bin/find-implementation-work.sh" | tr ' ' '\n' | grep -v '^$' | sort -u)"
if [ -z "$planning_trusted" ] || [ -z "$impl_trusted" ]; then
  bad "4.26 TRUSTED_ASSOCIATIONS extraction failed — bin/find-planning-work.sh's or bin/find-implementation-work.sh's TRUSTED_ASSOCIATIONS= line didn't match (structure changed)"
else
  planning_not_impl="$(comm -23 <(_lines "$planning_trusted") <(_lines "$impl_trusted"))"
  impl_not_planning="$(comm -13 <(_lines "$planning_trusted") <(_lines "$impl_trusted"))"
  if [ -z "$planning_not_impl" ] && [ -z "$impl_not_planning" ]; then
    ok "4.26 bin/find-planning-work.sh and bin/find-implementation-work.sh agree on TRUSTED_ASSOCIATIONS"
  else
    msg="4.26 TRUSTED_ASSOCIATIONS drift:"
    [ -n "$planning_not_impl" ] && msg="$msg association(s) in find-planning-work.sh but not find-implementation-work.sh: $(printf '%s' "$planning_not_impl" | tr '\n' ' ');"
    [ -n "$impl_not_planning" ] && msg="$msg association(s) in find-implementation-work.sh but not find-planning-work.sh: $(printf '%s' "$impl_not_planning" | tr '\n' ' ');"
    bad "$msg"
  fi
fi

# 4.27 — the literal harness-audit marker (a marker literal, not prose — CLAUDE.md's
# machine-parsed-artifacts rule) appears in every writer that must open a harness-authored
# record with it and every consumer that must exclude such a record from its binding comment
# set (#182): the two SKILL.md files that instruct posting it, the script that prefixes it onto
# cleanup-after-merge.sh's audit comments, and both discovery scripts that filter it out of
# their binding sets (find-implementation-work.sh's trusted_post_plan, find-planning-work.sh's
# has_feedback). Mirrors 4.16/4.17/4.19 — a floor that greps for a marker nobody writes, or that
# nobody filters, is the exact failure this pins.
marker='<!-- harness-audit -->'
missing=""
for f in skills/issue-planner/SKILL.md skills/issue-implementer/SKILL.md bin/cleanup-after-merge.sh bin/find-planning-work.sh bin/find-implementation-work.sh; do
  grep -qF -- "$marker" "$root/$f" || missing="$missing $f"
done
if [ -z "$missing" ]; then
  ok "4.27 '$marker' present in skills/issue-planner/SKILL.md, skills/issue-implementer/SKILL.md, bin/cleanup-after-merge.sh, bin/find-planning-work.sh, and bin/find-implementation-work.sh"
else
  bad "4.27 '$marker' missing from:$missing"
fi

# 4.28 — fixed-string presence of the literal '<!-- harness-plan-binding:' marker prefix in the
# script that writes binding_line, the skill that revalidates and pastes it into a PR body, and
# the skill that greps for it before an autonomous merge (#174). Modelled on 4.19 — a floor that
# greps for a marker nobody writes is the exact failure this pins. Proves only that the literal
# is present in writer, paster, and checker — not that the check actually runs.
marker='<!-- harness-plan-binding:'
missing=""
for f in bin/find-implementation-work.sh skills/issue-implementer/SKILL.md skills/issue-cycle/SKILL.md; do
  grep -qF -- "$marker" "$root/$f" || missing="$missing $f"
done
if [ -z "$missing" ]; then
  ok "4.28 '$marker' present in bin/find-implementation-work.sh, skills/issue-implementer/SKILL.md, and skills/issue-cycle/SKILL.md"
else
  bad "4.28 '$marker' missing from:$missing"
fi

# ============================================================================
echo
echo "-- Group 5: script and extracted-program behavior --"

# reconcile-ledger.sh, fed fabricated inputs through process substitution: no files written,
# no gh call (the status JSON is supplied), so the gate stays read-only and offline.
rl="$root/bin/reconcile-ledger.sh"
status_fixture='{"harness_will_handle":{"unplanned":[],"in_revision":[],"ready_to_implement":[{"number":17,"title":"t","url":"u"}]},"waiting_on_human":{"plans_to_review":[],"prs_to_review":[],"blocked":[]},"counts":{}}'

# 5.1 — accounted for: the issue is still queued, but the ledger reports why (implementer died,
# a reported non-advance) -> silence, exit 0.
out="$(bash "$rl" <(printf '%s\n' '17 seed ready_to_implement 0' '17 implementer died 4') \
                  <(printf '%s' "$status_fixture") 2>&1)"; rc=$?
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
  ok "5.1 reconcile-ledger.sh: silent, exit 0 on an accounted-for ledger"
else
  bad "5.1 reconcile-ledger.sh: expected silence and exit 0, got rc=$rc output='$out'"
fi

# 5.2 — seeded and still queued with no implementer record -> exactly one stage-skipped line, exit 1.
expected='stage-skipped issue=17 bucket=ready_to_implement stage=implementer: still queued for this stage and the ledger records no outcome for it'
out="$(bash "$rl" <(printf '%s\n' '17 seed ready_to_implement 0') \
                  <(printf '%s' "$status_fixture") 2>&1)"; rc=$?
if [ "$out" = "$expected" ] && [ "$rc" -eq 1 ]; then
  ok "5.2 reconcile-ledger.sh: reports the skipped stage and exits 1"
else
  bad "5.2 reconcile-ledger.sh: expected rc=1 and the stage-skipped line, got rc=$rc output='$out'"
fi

# empty-queue fixture for 5.3/5.4: a merge-only ledger row against no queued issues, so neither
# assertion's expected output is polluted by an unrelated seed/queue discrepancy.
empty_status_fixture='{"harness_will_handle":{"unplanned":[],"in_revision":[],"ready_to_implement":[]},"waiting_on_human":{"plans_to_review":[],"prs_to_review":[],"blocked":[]},"counts":{}}'

# 5.3 — a verbatim merge status line carrying deploy=verified parses into a record (proves the
# two-sed rewrite end to end) and a valid deploy value produces no discrepancy -> silence, exit 0.
out="$(bash "$rl" <(printf '%s\n' '<!-- harness-status: stage=merge issue=17 outcome=merged retries=0 deploy=verified -->') \
                  <(printf '%s' "$empty_status_fixture") 2>&1)"; rc=$?
if [ -z "$out" ] && [ "$rc" -eq 0 ]; then
  ok "5.3 reconcile-ledger.sh: verbatim merge status line with deploy=verified parses cleanly, exit 0"
else
  bad "5.3 reconcile-ledger.sh: expected silence and exit 0, got rc=$rc output='$out'"
fi

# 5.4 — a merge row with an out-of-vocabulary deploy slug -> exactly one unknown-outcome line, exit 1.
expected="unknown-outcome issue=17 bucket=- stage=merge: deploy outcome 'bogus' is not in the deploy vocabulary (verified|pending|failed)"
out="$(bash "$rl" <(printf '%s\n' '17 merge merged 0 deploy=bogus') \
                  <(printf '%s' "$empty_status_fixture") 2>&1)"; rc=$?
if [ "$out" = "$expected" ] && [ "$rc" -eq 1 ]; then
  ok "5.4 reconcile-ledger.sh: reports the unknown deploy outcome and exits 1"
else
  bad "5.4 reconcile-ledger.sh: expected rc=1 and the unknown-outcome line, got rc=$rc output='$out'"
fi

# 5.5/5.6/5.7 — extract the archived-verdict --jq program out of skills/issue-cycle/SKILL.md
# (the actual instruction text, not a copy of it) and execute it with jq against literal offline
# fixtures. Read-only, offline: no files written, no gh call. Each assertion fails loudly if the
# extraction is empty or malformed, rather than silently passing on nothing.
cyc="$root/skills/issue-cycle/SKILL.md"
q="'"
av_n="$(grep -c -- '--json comments --jq ' "$cyc")"
av_line="$(grep -F -- '--json comments --jq ' "$cyc" | head -1)"
av_prog="$(printf '%s\n' "$av_line" | sed -e "s/^.*--jq $q//" -e "s/$q | tr -d.*\$//")"
# av_for BRANCH — the extracted program with the head-branch placeholder substituted.
av_for() { printf '%s' "$av_prog" | sed "s|<paste the head branch here>|$1|"; }

extraction_ok=1
if [ "$av_n" != "1" ]; then
  bad "5.5 archived-verdict --jq extraction: expected exactly one matching line in skills/issue-cycle/SKILL.md, found $av_n"
  bad "5.6 archived-verdict --jq extraction: skipped (extraction did not find exactly one line)"
  bad "5.7 archived-verdict --jq extraction: skipped (extraction did not find exactly one line)"
  extraction_ok=0
elif [ -z "$av_prog" ]; then
  bad "5.5 archived-verdict --jq extraction: extracted program is empty"
  bad "5.6 archived-verdict --jq extraction: skipped (extracted program is empty)"
  bad "5.7 archived-verdict --jq extraction: skipped (extracted program is empty)"
  extraction_ok=0
else
  case "$av_prog" in
    '[.comments[]'*) : ;;
    *)
      bad "5.5 archived-verdict --jq extraction: extracted program does not start with [.comments[ -- got: $av_prog"
      bad "5.6 archived-verdict --jq extraction: skipped (extracted program malformed)"
      bad "5.7 archived-verdict --jq extraction: skipped (extracted program malformed)"
      extraction_ok=0
      ;;
  esac
fi

if [ "$extraction_ok" = "1" ]; then
  # 5.5 — none / one / two-out-of-createdAt-order (newest wins) on a single branch.
  fx_av_none='{"comments":[{"url":"https://example/none","createdAt":"2026-08-01T00:00:00Z","body":"no marker here at all"}]}'
  fx_av_one='{"comments":[{"url":"https://example/c2","createdAt":"2026-08-01T00:00:00Z","body":"<!-- verifier-verdict -->\n<!-- verifier-verdict-branch: claude/17-a -->\n<!-- harness-status: stage=verifier issue=17 outcome=pass retries=0 -->"}]}'
  fx_av_two='{"comments":[{"url":"https://example/c4","createdAt":"2026-08-05T00:00:00Z","body":"<!-- verifier-verdict -->\n<!-- verifier-verdict-branch: claude/17-a -->\n<!-- harness-status: stage=verifier issue=17 outcome=pass retries=1 -->"},{"url":"https://example/c3","createdAt":"2026-08-03T00:00:00Z","body":"<!-- verifier-verdict -->\n<!-- verifier-verdict-branch: claude/17-a -->\n<!-- harness-status: stage=verifier issue=17 outcome=pass retries=0 -->"}]}'

  fail_55=""
  out="$(printf '%s' "$fx_av_none" | jq -r "$(av_for claude/17-a)" 2>&1)"
  expected="$(printf 'none\nnone')"
  [ "$out" = "$expected" ] || fail_55="$fail_55 none-fixture: got '$out';"

  out="$(printf '%s' "$fx_av_one" | jq -r "$(av_for claude/17-a)" 2>&1)"
  expected="$(printf 'https://example/c2\n<!-- harness-status: stage=verifier issue=17 outcome=pass retries=0 -->')"
  [ "$out" = "$expected" ] || fail_55="$fail_55 one-fixture: got '$out';"

  out="$(printf '%s' "$fx_av_two" | jq -r "$(av_for claude/17-a)" 2>&1)"
  expected="$(printf 'https://example/c4\n<!-- harness-status: stage=verifier issue=17 outcome=pass retries=1 -->')"
  [ "$out" = "$expected" ] || fail_55="$fail_55 two-fixture (newest-wins, out of array order): got '$out';"

  if [ -z "$fail_55" ]; then
    ok "5.5 archived-verdict --jq program: none/one/two(newest-wins) fixtures all match"
  else
    bad "5.5 archived-verdict --jq program:$fail_55"
  fi

  # 5.6 — three branches on one issue: own verdict per branch, an absent branch, and the
  # prefix-collision guard (claude/17-slice-a must never resolve to claude/17-slice-ab's comment).
  fx_av_multi='{"comments":[{"url":"https://example/pa","createdAt":"2026-08-01T00:00:00Z","body":"<!-- verifier-verdict -->\n<!-- verifier-verdict-branch: claude/17-slice-a -->\n<!-- harness-status: stage=verifier issue=17 outcome=pass retries=0 -->"},{"url":"https://example/pab","createdAt":"2026-08-02T00:00:00Z","body":"<!-- verifier-verdict -->\n<!-- verifier-verdict-branch: claude/17-slice-ab -->\n<!-- harness-status: stage=verifier issue=17 outcome=pass retries=1 -->"},{"url":"https://example/pb","createdAt":"2026-08-03T00:00:00Z","body":"<!-- verifier-verdict -->\n<!-- verifier-verdict-branch: claude/17-slice-b -->\n<!-- harness-status: stage=verifier issue=17 outcome=pass retries=2 -->"}]}'

  fail_56=""
  out="$(printf '%s' "$fx_av_multi" | jq -r "$(av_for claude/17-slice-a)" 2>&1)"
  expected="$(printf 'https://example/pa\n<!-- harness-status: stage=verifier issue=17 outcome=pass retries=0 -->')"
  [ "$out" = "$expected" ] || fail_56="$fail_56 slice-a (prefix-collision guard): got '$out';"

  out="$(printf '%s' "$fx_av_multi" | jq -r "$(av_for claude/17-slice-b)" 2>&1)"
  expected="$(printf 'https://example/pb\n<!-- harness-status: stage=verifier issue=17 outcome=pass retries=2 -->')"
  [ "$out" = "$expected" ] || fail_56="$fail_56 slice-b: got '$out';"

  out="$(printf '%s' "$fx_av_multi" | jq -r "$(av_for claude/17-slice-zz)" 2>&1)"
  expected="$(printf 'none\nnone')"
  [ "$out" = "$expected" ] || fail_56="$fail_56 slice-zz (absent branch): got '$out';"

  if [ -z "$fail_56" ]; then
    ok "5.6 archived-verdict --jq program: three branches on one issue each resolve to their own verdict, absent branch -> none/none, prefix-collision guard holds"
  else
    bad "5.6 archived-verdict --jq program:$fail_56"
  fi

  # 5.7 — writer<->checker round-trip: extract the key-line template skills/issue-implementer/
  # SKILL.md mandates writers emit, build a fixture comment from it, and prove the cycle skill's
  # --jq program selects it. A drift in the writer's key-line spelling would silently stop every
  # autonomous merge, which 4.19 alone (a prefix-only presence check) would not catch.
  impl="$root/skills/issue-implementer/SKILL.md"
  key_n="$(grep -c -- '<!-- verifier-verdict-branch:' "$impl")"
  key_tpl="$(grep -o '<!-- verifier-verdict-branch: [^`]*-->' "$impl" | head -1)"
  if [ "$key_n" != "1" ] || [ -z "$key_tpl" ]; then
    bad "5.7 writer/checker round-trip: expected exactly one verifier-verdict-branch key-line template in skills/issue-implementer/SKILL.md, found $key_n (extracted: '$key_tpl')"
  else
    key_line="$(printf '%s' "$key_tpl" | sed 's|claude/<number>-<slug>|claude/17-a|')"
    fx_av_writer='{"comments":[{"url":"https://example/w1","createdAt":"2026-08-04T00:00:00Z","body":"<!-- verifier-verdict -->\n'"$key_line"'\n<!-- harness-status: stage=verifier issue=17 outcome=pass retries=0 -->"}]}'
    out="$(printf '%s' "$fx_av_writer" | jq -r "$(av_for claude/17-a)" 2>&1)"
    expected="$(printf 'https://example/w1\n<!-- harness-status: stage=verifier issue=17 outcome=pass retries=0 -->')"
    if [ "$out" = "$expected" ]; then
      ok "5.7 writer/checker round-trip: the writer's mandated key-line template resolves through the checker's --jq program"
    else
      bad "5.7 writer/checker round-trip: expected '$expected', got '$out'"
    fi
  fi
fi

# 5.8/5.9 — execute the merge floor's two PR-body --jq needles out of skills/issue-cycle/SKILL.md
# (the actual instruction lines, not copies of them) against literal offline fixtures. Read-only,
# offline: no files written, no gh call. Each fails loudly if its own extraction finds a wrong
# number of matching lines, an empty program, or a malformed one, rather than silently passing on
# nothing. $cyc and $q are the 5.5-5.7 block's; reused as-is.

# --- 5.8: verdict-provenance needle (SKILL.md:104) ---
vp_n="$(grep -F -- '--json body --jq' "$cyc" | grep -c -F -- '<!-- harness-status:')"
vp_line="$(grep -F -- '--json body --jq' "$cyc" | grep -F -- '<!-- harness-status:' | head -1)"
vp_prog="$(printf '%s\n' "$vp_line" | sed -e "s/^.*--jq $q//" -e "s/$q | tr -d.*\$//")"
# vp_for N — the extracted verdict-provenance program with <n> substituted.
vp_for() { printf '%s' "$vp_prog" | sed "s|<n>|$1|"; }
# vp_fail_for N — the same, with outcome=fail in place of outcome=pass (the SKILL.md line's "the
# same command with outcome=fail in place of outcome=pass" twin).
vp_fail_for() { printf '%s' "$vp_prog" | sed -e "s|<n>|$1|" -e "s|outcome=pass |outcome=fail |"; }

vp_ok=1
if [ "$vp_n" != "1" ]; then
  bad "5.8 verdict-provenance --jq extraction: expected exactly one matching line in skills/issue-cycle/SKILL.md, found $vp_n"
  vp_ok=0
elif [ -z "$vp_prog" ]; then
  bad "5.8 verdict-provenance --jq extraction: extracted program is empty"
  vp_ok=0
else
  case "$vp_prog" in
    '(.body'*) : ;;
    *)
      bad "5.8 verdict-provenance --jq extraction: extracted program does not start with (.body -- got: $vp_prog"
      vp_ok=0
      ;;
  esac
fi

if [ "$vp_ok" = "1" ]; then
  fx_vp_present='{"body":"some prose <!-- harness-status: stage=verifier issue=17 outcome=pass retries=0 --> more prose"}'
  fx_vp_extra='{"body":"prose <!-- harness-status: stage=verifier issue=17 outcome=pass retries=2 deploy=verified --> prose"}'
  fx_vp_longer='{"body":"prose <!-- harness-status: stage=verifier issue=17 outcome=passed retries=0 --> prose"}'
  fx_vp_fail='{"body":"prose <!-- harness-status: stage=verifier issue=17 outcome=fail retries=1 --> prose"}'
  fx_vp_prose='{"body":"verifier verdict: pass"}'
  fx_vp_other_issue='{"body":"prose <!-- harness-status: stage=verifier issue=18 outcome=pass retries=0 --> prose"}'
  fx_vp_null='{"body":null}'

  fail_58=""
  out="$(printf '%s' "$fx_vp_present" | jq -r "$(vp_for 17)" 2>&1)"
  [ "$out" = "true" ] || fail_58="$fail_58 present-fixture (pass-needle): got '$out';"

  out="$(printf '%s' "$fx_vp_present" | jq -r "$(vp_fail_for 17)" 2>&1)"
  [ "$out" = "false" ] || fail_58="$fail_58 present-fixture (fail-twin): got '$out';"

  out="$(printf '%s' "$fx_vp_extra" | jq -r "$(vp_for 17)" 2>&1)"
  [ "$out" = "true" ] || fail_58="$fail_58 extra-trailing-fields fixture: got '$out';"

  out="$(printf '%s' "$fx_vp_longer" | jq -r "$(vp_for 17)" 2>&1)"
  [ "$out" = "false" ] || fail_58="$fail_58 longer-outcome-token (outcome=passed) fixture: got '$out';"

  out="$(printf '%s' "$fx_vp_fail" | jq -r "$(vp_for 17)" 2>&1)"
  [ "$out" = "false" ] || fail_58="$fail_58 outcome=fail fixture (pass-needle): got '$out';"

  out="$(printf '%s' "$fx_vp_fail" | jq -r "$(vp_fail_for 17)" 2>&1)"
  [ "$out" = "true" ] || fail_58="$fail_58 outcome=fail fixture (fail-twin): got '$out';"

  out="$(printf '%s' "$fx_vp_prose" | jq -r "$(vp_for 17)" 2>&1)"
  [ "$out" = "false" ] || fail_58="$fail_58 prose-only fixture: got '$out';"

  out="$(printf '%s' "$fx_vp_other_issue" | jq -r "$(vp_for 17)" 2>&1)"
  [ "$out" = "false" ] || fail_58="$fail_58 different-issue fixture: got '$out';"

  out="$(printf '%s' "$fx_vp_null" | jq -r "$(vp_for 17)" 2>&1)"
  [ "$out" = "false" ] || fail_58="$fail_58 null-body fixture: got '$out';"

  if [ -z "$fail_58" ]; then
    ok "5.8 verdict-provenance --jq program: present, fail-twin, extra-trailing-fields, longer-outcome-token, outcome=fail, prose-only, different-issue and null-body fixtures all match"
  else
    bad "5.8 verdict-provenance --jq program:$fail_58"
  fi
fi

# --- 5.9: archived-verdict match needle (SKILL.md:121) ---
mn_n="$(grep -F -- '--json body --jq' "$cyc" | grep -c -F -- 'paste the printed line here')"
mn_line_src="$(grep -F -- '--json body --jq' "$cyc" | grep -F -- 'paste the printed line here' | head -1)"
mn_prog="$(printf '%s\n' "$mn_line_src" | sed -e "s/^.*--jq $q//" -e "s/$q | tr -d.*\$//")"
# mn_for LINE — the extracted archived-verdict match program with the placeholder substituted by
# a literal status line. The substituted line contains no |, & or \, so a |-delimited BRE is safe.
mn_for() { printf '%s' "$mn_prog" | sed "s|<paste the printed line here>|$1|"; }

mn_ok=1
if [ "$mn_n" != "1" ]; then
  bad "5.9 archived-verdict match --jq extraction: expected exactly one matching line in skills/issue-cycle/SKILL.md, found $mn_n"
  mn_ok=0
elif [ -z "$mn_prog" ]; then
  bad "5.9 archived-verdict match --jq extraction: extracted program is empty"
  mn_ok=0
else
  case "$mn_prog" in
    '(.body'*) : ;;
    *)
      bad "5.9 archived-verdict match --jq extraction: extracted program does not start with (.body -- got: $mn_prog"
      mn_ok=0
      ;;
  esac
fi

if [ "$mn_ok" = "1" ]; then
  mn_line='<!-- harness-status: stage=verifier issue=17 outcome=pass retries=0 -->'
  fx_mn_present='{"body":"some prose\n'"$mn_line"'\nmore prose"}'
  fx_mn_retries='{"body":"some prose\n<!-- harness-status: stage=verifier issue=17 outcome=pass retries=1 -->\nmore prose"}'
  fx_mn_none='{"body":"no status line here"}'
  fx_mn_null='{"body":null}'

  fail_59=""
  out="$(printf '%s' "$fx_mn_present" | jq -r "$(mn_for "$mn_line")" 2>&1)"
  [ "$out" = "true" ] || fail_59="$fail_59 line-present fixture: got '$out';"

  out="$(printf '%s' "$fx_mn_retries" | jq -r "$(mn_for "$mn_line")" 2>&1)"
  [ "$out" = "false" ] || fail_59="$fail_59 retries-differ fixture: got '$out';"

  out="$(printf '%s' "$fx_mn_none" | jq -r "$(mn_for "$mn_line")" 2>&1)"
  [ "$out" = "false" ] || fail_59="$fail_59 no-status-line fixture: got '$out';"

  out="$(printf '%s' "$fx_mn_null" | jq -r "$(mn_for "$mn_line")" 2>&1)"
  [ "$out" = "false" ] || fail_59="$fail_59 null-body fixture: got '$out';"

  if [ -z "$fail_59" ]; then
    ok "5.9 archived-verdict match --jq program: line-present, retries-differ, no-status-line and null-body fixtures all match"
  else
    bad "5.9 archived-verdict match --jq program:$fail_59"
  fi
fi

# ============================================================================
echo
echo "== summary: $pass pass, $fail fail =="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
