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
# Four groups, 17 assertions total:
#   1. shell syntax and portability (bin/*.sh, this script)
#   2. JSON manifests (plugin.json, marketplace.json, templates/repo-settings.json)
#   3. agent instruction-file invariants (agents/*.md: frontmatter, one fenced template
#      block, the harness-status line grammar, the #4 dedupe invariant, required headings)
#   4. cross-file markers and skills (the planner-plan marker, skill frontmatter, README
#      model-pin strings)
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

echo "== trail-blazer-flow selfcheck: $root =="

# ============================================================================
echo
echo "-- Group 1: shell syntax and portability --"

# 1.1 — bash -n on every bin/*.sh and on this script itself.
bad_files=""
for s in "$root"/bin/*.sh "$root"/dev/selfcheck.sh; do
  [ -f "$s" ] || continue
  err="$(bash -n "$s" 2>&1 >/dev/null)" || bad_files="$bad_files $s: $err;"
done
if [ -z "$bad_files" ]; then
  ok "1.1 bash -n passes on all bin/*.sh and dev/selfcheck.sh"
else
  bad "1.1 bash -n failed —$bad_files"
fi

# 1.2 — every bin/*.sh line 1 is exactly '#!/usr/bin/env bash' and has a 'set -' line.
bad_files=""
for s in "$root"/bin/*.sh; do
  [ -f "$s" ] || continue
  first="$(head -n1 "$s")"
  if [ "$first" != "#!/usr/bin/env bash" ]; then
    bad_files="$bad_files $s(shebang: '$first')"
    continue
  fi
  grep -q '^set -' "$s" || bad_files="$bad_files $s(no 'set -' line)"
done
if [ -z "$bad_files" ]; then
  ok "1.2 every bin/*.sh starts with '#!/usr/bin/env bash' and has a 'set -' line"
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
_lines() { [ -n "$1" ] && printf '%s\n' "$1" || true; }
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

# 3.2 — exactly one '# Constraints' heading.
bad_list=""
for f in "$root"/agents/*.md; do
  n="$(grep -c '^# Constraints$' "$f")"
  [ "$n" -eq 1 ] || bad_list="$bad_list $f(count=$n)"
done
if [ -z "$bad_list" ]; then
  ok "3.2 every agents/*.md has exactly one '# Constraints' heading"
else
  bad "3.2 wrong '# Constraints' count:$bad_list"
fi

# 3.3 — exactly two fence lines (one fenced template block).
bad_list=""
for f in "$root"/agents/*.md; do
  n="$(grep -c '^```$' "$f")"
  [ "$n" -eq 2 ] || bad_list="$bad_list $f(count=$n)"
done
if [ -z "$bad_list" ]; then
  ok "3.3 every agents/*.md has exactly two \`\`\` lines (one fenced template block)"
else
  bad "3.3 wrong fence count:$bad_list"
fi

# 3.4 — exactly one harness-status line; inside the fence; last non-blank line inside it;
# matches the canonical grammar with stage == the frontmatter name.
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

  last_nonblank_rel="$(sed -n "$((t1+1)),$((t2-1))p" "$f" | grep -n '[^[:space:]]' | tail -1 | cut -d: -f1)"
  expected_lineno=$((t1 + last_nonblank_rel))
  if [ "$hs_lineno" -ne "$expected_lineno" ]; then
    bad_list="$bad_list $f(status line at $hs_lineno is not the fence's last non-blank line, $expected_lineno)"
    continue
  fi

  if ! printf '%s' "$hs_text" | grep -qE "^<!-- harness-status: stage=${base} issue=<n> outcome=<[A-Za-z|-]+> retries=<k> -->\$"; then
    bad_list="$bad_list $f(status line doesn't match the canonical grammar for stage=$base)"
  fi
done
if [ -z "$bad_list" ]; then
  ok "3.4 harness-status line: exactly one, inside the fence, last non-blank, grammar+stage correct"
else
  bad "3.4 harness-status problems:$bad_list"
fi

# 3.5 — every '|'-separated outcome alternative from 3.4's status line appears as a fixed
# string in skills/issue-implementer/SKILL.md (the canonical Status-line vocabulary).
canon="$root/skills/issue-implementer/SKILL.md"
bad_list=""
for f in "$root"/agents/*.md; do
  hs_text="$(grep '<!-- harness-status:' "$f" | head -1)"
  alt_list="$(printf '%s' "$hs_text" | sed -nE 's/.*outcome=<([^>]*)>.*/\1/p' | tr '|' '\n')"
  for alt in $alt_list; do
    [ -z "$alt" ] && continue
    grep -qF -- "$alt" "$canon" || bad_list="$bad_list $f:$alt"
  done
done
if [ -z "$bad_list" ]; then
  ok "3.5 every agent outcome alternative appears in skills/issue-implementer/SKILL.md"
else
  bad "3.5 outcome alternative(s) missing from skills/issue-implementer/SKILL.md:$bad_list"
fi

# 3.6 — the #4 dedupe invariant: walk the prose body only (frontmatter and the fenced
# template block excluded), tracking the current '^# ' heading as the section; FAIL if any
# keyword occurs in more than one section OF THE SAME FILE.
#
# Keyword table (case-insensitive ERE). A false positive is resolved by rewording the prose
# or by adjusting this table with a comment explaining why — never by deleting the check.
kw_ids="read-only git-boundary write-boundary deploy migration"
kw_pattern() {
  case "$1" in
    read-only)      printf '%s' 'read-only' ;;
    git-boundary)   printf '%s' 'no git|never .*run git|runs git' ;;
    write-boundary) printf '%s' 'never (edit|write)|no .*push|never push' ;;
    deploy)         printf '%s' 'deployment|deployed' ;;
    migration)      printf '%s' 'migration' ;;
  esac
}
prose_tsv() {
  awk '
    $0 == "---" { fm++; next }
    fm < 2 { next }
    $0 == "```" { fence++; next }
    fence == 1 { next }
    /^# / { section = substr($0, 3) }
    { printf "%d\t%s\t%s\n", NR, section, $0 }
  ' "$1"
}
bad_list=""
for f in "$root"/agents/*.md; do
  tsv="$(prose_tsv "$f")"
  for kwid in $kw_ids; do
    pat="$(kw_pattern "$kwid")"
    matches="$(printf '%s\n' "$tsv" | grep -iE -- "$pat")"
    [ -z "$matches" ] && continue
    sections="$(printf '%s\n' "$matches" | cut -f2 | sort -u)"
    nsec="$(printf '%s\n' "$sections" | grep -c '.')"
    if [ "$nsec" -gt 1 ]; then
      detail="$(printf '%s\n' "$matches" | awk -F'\t' -v ff="$f" '{print ff":"$1" ["$2"]"}' | tr '\n' ' ')"
      bad_list="$bad_list keyword=$kwid: $detail;"
    fi
  done
done
if [ -z "$bad_list" ]; then
  ok "3.6 no constraint keyword restated across more than one section of the same file"
else
  bad "3.6 keyword restated across sections —$bad_list"
fi

# 3.7 — required template headings (referenced by exact name elsewhere) exist inside the
# fenced block.
pairs=(
  "planner.md|## Acceptance criteria"       # referenced by agents/verifier.md
  "planner.md|## Verified facts"            # referenced by agents/verifier.md and skills/issue-implementer/SKILL.md
  "planner.md|## Follow-ups to file"        # referenced by skills/issue-implementer/SKILL.md
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

# 4.2 — every skills/*/SKILL.md has frontmatter name == its containing directory, and a
# non-empty description.
bad_list=""
for f in "$root"/skills/*/SKILL.md; do
  dir="$(dirname "$f")"
  base="$(basename "$dir")"
  name_field="$(sed -n 's/^name: *//p' "$f" | head -1 | tr -d '[:space:]')"
  [ "$name_field" = "$base" ] || bad_list="$bad_list $f(name='$name_field' != '$base')"
  if ! grep -q '^description:' "$f"; then
    bad_list="$bad_list $f(no description key)"
  else
    desc_lineno="$(grep -n '^description:' "$f" | head -1 | cut -d: -f1)"
    next_content="$(sed -n "$((desc_lineno+1))p" "$f")"
    [ -n "$(printf '%s' "$next_content" | tr -d '[:space:]')" ] || bad_list="$bad_list $f(empty description)"
  fi
done
if [ -z "$bad_list" ]; then
  ok "4.2 every skills/*/SKILL.md has frontmatter name == its directory, non-empty description"
else
  bad "4.2 skill frontmatter problems:$bad_list"
fi

# 4.3 — for each agent, the string '<name>: <model>' (from its own frontmatter) appears in
# README.md — pins the documented model tiering to the actual pins.
bad_list=""
for f in "$root"/agents/*.md; do
  fm="$(frontmatter_text "$f")"
  name_field="$(printf '%s\n' "$fm" | sed -n 's/^name: *//p' | head -1 | tr -d '[:space:]')"
  model_field="$(printf '%s\n' "$fm" | sed -n 's/^model: *//p' | head -1 | tr -d '[:space:]')"
  needle="${name_field}: ${model_field}"
  grep -qF -- "$needle" "$root/README.md" || bad_list="$bad_list [$needle]"
done
if [ -z "$bad_list" ]; then
  ok "4.3 README.md contains '<name>: <model>' for every agent"
else
  bad "4.3 README.md missing model-pin string(s):$bad_list"
fi

# ============================================================================
echo
echo "== summary: $pass pass, $fail fail =="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
