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
# Five groups, 28 assertions total:
#   1. shell syntax, portability, and error handling (bin/*.sh, dev/*.sh; no GNU-only constructs
#      in bin/*.sh; no unguarded 'git branch -d/-D' in bin/*.sh)
#   2. JSON manifests (plugin.json, marketplace.json, templates/repo-settings.json), plus the
#      bin/*.sh <-> allow-list bijection, the git permission-mirror invariants, and whether
#      bin/check-harness.sh's tmpl_guarded_branch literal still names a branch that
#      templates/repo-settings.json actually deny-guards
#   3. agent instruction-file invariants (agents/*.md: frontmatter, one fenced template block,
#      the harness-status line grammar, required template headings)
#   4. cross-file markers and skills (the planner-plan and ratchet-issue markers, skill
#      frontmatter, the label bijection, skill/README coverage, policy-section titles, the CI
#      workflow's gate command, that bin/check-harness.sh reads .claude/settings.json only
#      through jq, the ledger stage vocabulary shared by bin/reconcile-ledger.sh and the
#      implementer skill's status-line grammar, a per-skill size budget, and that no
#      skill/agent instruction file contains an inline command-substitution token)
#   5. bin/ script behavior (reconcile-ledger.sh against fabricated ledger/status inputs)
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

# 1.1 — bash -n on every bin/*.sh and every dev/*.sh.
bad_files=""
for s in "$root"/bin/*.sh "$root"/dev/*.sh; do
  [ -f "$s" ] || continue
  err="$(bash -n "$s" 2>&1 >/dev/null)" || bad_files="$bad_files $s: $err;"
done
if [ -z "$bad_files" ]; then
  ok "1.1 bash -n passes on all bin/*.sh and dev/*.sh"
else
  bad "1.1 bash -n failed —$bad_files"
fi

# 1.2 — every bin/*.sh and dev/*.sh line 1 is exactly '#!/usr/bin/env bash' and has a 'set -' line.
bad_files=""
for s in "$root"/bin/*.sh "$root"/dev/*.sh; do
  [ -f "$s" ] || continue
  first="$(head -n1 "$s")"
  if [ "$first" != "#!/usr/bin/env bash" ]; then
    bad_files="$bad_files $s(shebang: '$first')"
    continue
  fi
  grep -q '^set -' "$s" || bad_files="$bad_files $s(no 'set -' line)"
done
if [ -z "$bad_files" ]; then
  ok "1.2 every bin/*.sh and dev/*.sh starts with '#!/usr/bin/env bash' and has a 'set -' line"
else
  bad "1.2 shebang/set- check failed —$bad_files"
fi

# 1.3 — no *.sh under bin/ or dev/ contains a CR byte.
bad_files=""
for s in "$root"/bin/*.sh "$root"/dev/*.sh; do
  [ -f "$s" ] || continue
  LC_ALL=C grep -q "$(printf '\r')" "$s" && bad_files="$bad_files $s"
done
if [ -z "$bad_files" ]; then
  ok "1.3 no CR bytes in bin/*.sh or dev/*.sh"
else
  bad "1.3 CR byte(s) found in:$bad_files"
fi

# 1.4 — no GNU-only shell constructs in bin/*.sh: grep -P/--perl-regexp, sed -i/--in-place
# without a suffix (sed -i.bak stays legal), readlink -f/--canonicalize, mapfile/readarray,
# declare/typeset/local -A. Full-line comments are stripped before matching; the pattern then
# matches anywhere else in the line, including inside quotes/heredocs — a comment is the only
# safe place to name these constructs in bin/*.sh. dev/*.sh follows the same rule by convention
# (CLAUDE.md), not mechanically — dev/ is exempt so this gate never has to self-scan its own
# vocabulary of forbidden words.
genopt='([[:space:]]+--?[A-Za-z][A-Za-z-]*)*'
forbidden_pat="(grep${genopt}[[:space:]]+(-[A-Za-z]*P|--perl-regexp)([[:space:]]|\$)|sed${genopt}[[:space:]]+(-[A-Za-z]*i|--in-place)([[:space:]]|\$)|readlink${genopt}[[:space:]]+(-[A-Za-z]*f|--canonicalize)([[:space:]]|\$)|(declare|typeset|local)${genopt}[[:space:]]+(-[A-Za-z]*A)([[:space:]]|\$)|mapfile([[:space:]]|\$)|readarray([[:space:]]|\$))"
bad_list=""
for s in "$root"/bin/*.sh; do
  [ -f "$s" ] || continue
  hits="$(grep -vnE '^[[:space:]]*#' "$s" | grep -E "$forbidden_pat")"
  [ -z "$hits" ] || bad_list="$bad_list $s: $(printf '%s' "$hits" | tr '\n' ' ');"
done
if [ -z "$bad_list" ]; then
  ok "1.4 no GNU-only constructs (grep -P, sed -i without suffix, readlink -f, mapfile/readarray, declare -A) in bin/*.sh"
else
  bad "1.4 GNU-only construct(s) found —$bad_list"
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

# 2.1 — all three JSON files parse.
bad_files=""
for f in "$plugin_json" "$marketplace_json" "$settings_json"; do
  jq -e . "$f" >/dev/null 2>&1 || bad_files="$bad_files $f"
done
if [ -z "$bad_files" ]; then
  ok "2.1 plugin.json, marketplace.json, and templates/repo-settings.json all parse as JSON"
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

# 2.5 — permission mirror, allow side: every `-C`-form allow entry's subcommand also has a bare
# `Bash(git <sub>` allow entry — the mechanical pin that no bare-form rule was removed while a
# `-C` form was added (sequential mode depends on the bare forms existing independently).
allow_raw="$(jq -r '.permissions.allow[]? // empty' "$settings_json" 2>/dev/null)"
c_allow_subs="$(printf '%s\n' "$allow_raw" \
  | grep -oE '^Bash\(git -C \* [a-z][a-z-]*' \
  | sed -E 's/^Bash\(git -C \* //' \
  | sort -u)"
missing_bare=""
for sub in $c_allow_subs; do
  printf '%s\n' "$allow_raw" | grep -qF -- "Bash(git $sub" || missing_bare="$missing_bare $sub"
done
if [ -z "$missing_bare" ]; then
  ok "2.5 permission mirror (allow): every -C grant has a bare-form counterpart"
else
  bad "2.5 permission mirror (allow) broken: -C grant(s) with no bare-form counterpart:$missing_bare"
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

# 2.7 — default-branch guard derivation: bin/check-harness.sh's tmpl_guarded_branch="..." literal
# must still name a branch that templates/repo-settings.json's branch-scoped bare deny entries
# actually guard — i.e. deriving operations from those entries for that literal branch must
# yield at least one operation. FAILs loudly (rather than passing vacuously) if either
# extraction comes back empty: the script-side literal, or the JSON-side deny list itself.
tmpl_guarded_branch="$(sed -nE 's/^tmpl_guarded_branch="([^"]*)"$/\1/p' "$root/bin/check-harness.sh")"
if [ -z "$tmpl_guarded_branch" ] || [ -z "$deny_raw" ]; then
  bad "2.7 could not extract tmpl_guarded_branch from bin/check-harness.sh (got '$tmpl_guarded_branch') or deny entries from templates/repo-settings.json"
else
  tmpl_branch_ops="$(printf '%s\n' "$deny_raw" | sed -n "s/^Bash(git \(.*\) $tmpl_guarded_branch:\*)\$/\1/p" | sort -u)"
  n_branch_ops="$(printf '%s\n' "$tmpl_branch_ops" | grep -c .)"
  if [ "$n_branch_ops" -eq 0 ]; then
    bad "2.7 templates/repo-settings.json has zero branch-scoped bare deny entries for '$tmpl_guarded_branch' (bin/check-harness.sh's tmpl_guarded_branch literal) — the doctor's derived-coverage check would guard nothing"
  else
    ok "2.7 bin/check-harness.sh's tmpl_guarded_branch ('$tmpl_guarded_branch') matches $n_branch_ops branch-scoped bare deny entries in templates/repo-settings.json"
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

# 3.7 — required template headings (referenced by exact name elsewhere) exist inside the
# fenced block.
pairs=(
  "planner.md|## Acceptance criteria"       # referenced by agents/verifier.md
  "planner.md|## Verified facts"            # referenced by agents/verifier.md and skills/issue-implementer/SKILL.md
  "planner.md|## Follow-ups to file"        # referenced by README.md and skills/test-ratchet/SKILL.md
  "implementer.md|## Resume brief"          # referenced by skills/issue-implementer/SKILL.md
  "verifier.md|## Notes for the PR reviewer" # referenced by skills/issue-implementer/SKILL.md
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

# 4.1 — the literal planner-plan marker appears in both files (fixed-string).
marker='<!-- planner-plan -->'
missing=""
grep -qF -- "$marker" "$root/bin/find-planning-work.sh" || missing="$missing bin/find-planning-work.sh"
grep -qF -- "$marker" "$root/skills/issue-planner/SKILL.md" || missing="$missing skills/issue-planner/SKILL.md"
if [ -z "$missing" ]; then
  ok "4.1 '$marker' present in bin/find-planning-work.sh and skills/issue-planner/SKILL.md"
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
EOF
if [ -z "$bad_list" ]; then
  ok "4.8 policy section titles cross-referenced in README.md and skills/harness-setup/SKILL.md"
else
  bad "4.8 policy-title cross-reference problem(s):$bad_list"
fi

# 4.9 — the CI workflow exists and runs the same command CLAUDE.md names as the gate.
wf="$root/.github/workflows/selfcheck.yml"
if [ -f "$wf" ] && grep -qF -- 'bash dev/selfcheck.sh' "$wf"; then
  ok "4.9 .github/workflows/selfcheck.yml runs 'bash dev/selfcheck.sh'"
else
  bad "4.9 .github/workflows/selfcheck.yml missing or does not run 'bash dev/selfcheck.sh'"
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

# 4.13 — ledger stage vocabulary, two clauses:
#   (a) cross-file: bin/reconcile-ledger.sh's `STAGES=` list must agree, both directions, with
#       skills/issue-implementer/SKILL.md's status-line grammar (`stage=<...>`) — 'seed' is the
#       one documented ledger-only exception (issue-cycle step 0 writes it from the discovery
#       bucket; no agent status line ever carries stage=seed). Anchored single-line extraction
#       on both sides; an empty extraction FAILs loudly rather than vacuously passing.
#   (b) folded former-3.5: every '|'-separated outcome alternative in each agents/*.md status
#       line appears as a fixed string in skills/issue-implementer/SKILL.md (the canonical
#       Status-line vocabulary).
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
if [ -z "$bad_list" ]; then
  ok "4.13 ledger stage vocabulary agrees with SKILL.md; every agent outcome alternative appears in SKILL.md"
else
  bad "4.13 ledger/status-line vocabulary drift:$bad_list"
fi

# 4.14 — per-skill size budget: wc -l on every skills/*/SKILL.md against a fixed table, plus a
# total — the anti-regrowth control replacing the old restated-keyword checks (former 3.6, 4.10):
# a line budget is cheaper to keep honest and catches regrowth regardless of which words come
# back. Raising a budget here is a legitimate, reviewable one-line edit when growth is justified
# — this assertion only says "look at this diff" (recipe: per-file cap = actual rounded up to
# the next multiple of 5, plus a small kept-tight headroom buffer; total = sum of actuals + 25).
# references/worktree-mode.md is deliberately unbudgeted (the glob is skills/*/SKILL.md only) —
# read on demand, not on every run.
budget_table="issue-implementer 410
issue-cycle 235
issue-planner 320
project-kickoff 225
test-ratchet 205
harness-setup 180"
bad_list=""
total=0
while IFS=' ' read -r skill cap; do
  [ -n "$skill" ] || continue
  f="$root/skills/$skill/SKILL.md"
  [ -f "$f" ] || { bad_list="$bad_list skills/$skill/SKILL.md missing;"; continue; }
  n="$(wc -l < "$f" | tr -d '[:space:]')"
  total=$((total + n))
  [ "$n" -le "$cap" ] || bad_list="$bad_list skills/$skill/SKILL.md: $n lines > budget $cap;"
done <<EOF
$budget_table
EOF
[ "$total" -le 1551 ] || bad_list="$bad_list total $total lines > budget 1551 across all skills/*/SKILL.md;"
if [ -z "$bad_list" ]; then
  ok "4.14 every skills/*/SKILL.md is within its size budget (total $total/1551)"
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

# ============================================================================
echo
echo "-- Group 5: bin/ script behavior --"

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

# ============================================================================
echo
echo "== summary: $pass pass, $fail fail =="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
