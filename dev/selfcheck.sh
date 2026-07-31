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
# Five groups, 30 assertions total:
#   1. shell syntax and portability (bin/*.sh, dev/*.sh, and no GNU-only constructs in either)
#   2. JSON manifests (plugin.json, marketplace.json, templates/repo-settings.json), plus the
#      permission allow/deny mirroring between templates/repo-settings.json's `git -C` entries
#      and the `-C` forms skills/issue-implementer/SKILL.md mandates
#   3. agent instruction-file invariants (agents/*.md: frontmatter, one fenced template
#      block, the harness-status line grammar, the #4 dedupe invariant, required headings, and
#      the verifier's lettered Process checks a.-g. plus CLAUDE.md's `rule Nx` citations)
#   4. cross-file markers and skills (the planner-plan and ratchet-issue markers, skill
#      frontmatter, README model-pin strings, WIP-message vocabulary, the label bijection,
#      skill/README coverage, policy-section titles, the CI workflow's gate command, and the
#      #4 dedupe invariant extended to skills/*/SKILL.md)
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

# bt — a literal backtick, built via printf rather than embedded in a quoted string (used by
# assertions 1.4 and 4.4, both of which need a backtick inside a single-quoted awk/ERE body).
bt="$(printf '\140')"

# code_segments FILE — awk helper for assertion 1.4. Emits one *command segment* per line as
# "FILE:LINE:segment", having (a) skipped full-line comments, (b) skipped heredoc bodies
# (detects '<<'/'<<-' with an optional quoted word, never '<<<'), (c) split each remaining line
# on '; | & ( ) { }' and backtick, and (d) stripped, repeatedly, leading whitespace, leading
# shell keywords, and leading VAR=value assignments — so the emitted segment always starts with
# the leading command word. The single-quote character is passed in via -v sq rather than
# embedded in the single-quoted awk program (same trick as the $bt precedent above).
code_segments() {
  awk -v sq="'" -v bt="$bt" '
    function strip(s,   keep) {
      keep = 1
      while (keep) {
        keep = 0
        if (match(s, /^[[:space:]]+/)) { s = substr(s, RLENGTH+1); keep = 1; continue }
        if (match(s, /^(if|while|until|then|else|elif|do|time|!|command|exec|env|sudo|xargs)([[:space:]]|$)/)) {
          s = substr(s, RLENGTH+1); keep = 1; continue
        }
        if (match(s, /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/)) {
          s = substr(s, RLENGTH+1); keep = 1; continue
        }
      }
      return s
    }
    function emit(codepart, file, lineno,    n, i, seg, s) {
      n = split(codepart, parts, sq_class)
      for (i = 1; i <= n; i++) {
        seg = parts[i]
        gsub(/^[[:space:]]+/, "", seg)
        gsub(/[[:space:]]+$/, "", seg)
        if (seg == "") continue
        s = strip(seg)
        if (s == "") continue
        print file ":" lineno ":" s
      }
    }
    BEGIN { sq_class = "[;|&(){}" bt "]"; in_hd = 0 }
    {
      line = $0
      if (in_hd) {
        t = line
        if (strip_tabs) gsub(/^\t+/, "", t)
        if (t == hd_term) in_hd = 0
        next
      }
      if (line ~ /^[[:space:]]*#/) next
      protected_line = line
      gsub(/<<</, "@@@", protected_line)
      if (match(protected_line, /<<-?[[:space:]]*/)) {
        op_start = RSTART; op_len = RLENGTH
        after = substr(line, op_start + op_len)
        opstr = substr(protected_line, op_start, op_len)
        strip_tabs = (opstr ~ /^<<-/)
        word = ""
        if (match(after, "^" sq "[^" sq "]*" sq)) {
          word = substr(after, 2, RLENGTH-2)
        } else if (match(after, /^"[^"]*"/)) {
          word = substr(after, 2, RLENGTH-2)
        } else if (match(after, /^[A-Za-z_][A-Za-z0-9_]*/)) {
          word = substr(after, 1, RLENGTH)
        }
        if (word != "") {
          codepart = substr(line, 1, op_start-1)
          emit(codepart, FILENAME, FNR)
          in_hd = 1
          hd_term = word
          next
        }
      }
      emit(line, FILENAME, FNR)
    }
  ' "$1"
}

echo "== trail-blazer-flow selfcheck: $root =="

# ============================================================================
echo
echo "-- Group 1: shell syntax and portability --"

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

# 1.4 — no GNU-only shell constructs in bin/*.sh or dev/*.sh: grep -P/--perl-regexp, sed
# -i/--in-place without a suffix (sed -i.bak stays legal), readlink -f/--canonicalize,
# mapfile/readarray, declare/typeset/local -A. Matched against code_segments' output, anchored
# right after the FILE:LINE: prefix so the flag is only recognised in the leading option
# cluster (a run of clean '-x'/'--word' tokens right after the command name) — a flag typed
# after a non-flag argument is deliberately not policed (documented heuristic limit, same as
# 3.6's false-positive escape hatch). Because this loop scans dev/*.sh, it polices its own
# table and dev/selfcheck-tests.sh — including this very pattern: 'mapfile'/'readarray' spelled
# out next to '(' '|' ')' would otherwise land as their own bare, delimiter-bounded segments and
# self-trip the rule below. map[f]ile / read[a]rray are single-char bracket expressions — an ERE
# match for the literal word, just not the literal *substring* the self-scan would isolate.
genopt='([[:space:]]+--?[A-Za-z][A-Za-z-]*)*'
forbidden_pat="^[^:]*:[0-9]+:(grep${genopt}[[:space:]]+(-[A-Za-z]*P|--perl-regexp)([[:space:]]|\$)|sed${genopt}[[:space:]]+(-[A-Za-z]*i|--in-place)([[:space:]]|\$)|readlink${genopt}[[:space:]]+(-[A-Za-z]*f|--canonicalize)([[:space:]]|\$)|(declare|typeset|local)${genopt}[[:space:]]+(-[A-Za-z]*A)([[:space:]]|\$)|(map[f]ile|read[a]rray)([[:space:]]|\$))"
bad_list=""
for s in "$root"/bin/*.sh "$root"/dev/*.sh; do
  [ -f "$s" ] || continue
  hits="$(code_segments "$s" | grep -E "$forbidden_pat")"
  [ -z "$hits" ] || bad_list="$bad_list $(printf '%s' "$hits" | tr '\n' ' ')"
done
if [ -z "$bad_list" ]; then
  ok "1.4 no GNU-only constructs (grep -P, sed -i without suffix, readlink -f, mapfile/readarray, declare -A) in bin/*.sh or dev/*.sh"
else
  bad "1.4 GNU-only construct(s) found —$bad_list"
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

# 2.5 — permission mirror, allow side. Two directions:
#   (a) coverage: every `git -C <worktree> <sub> ...` form skills/issue-implementer/SKILL.md
#       mandates has an allow entry `Bash(git -C * <sub> )`. Deliberately one-directional: step
#       e's blanket "every git command takes `-C <worktree>`" mandates forms the prose never
#       spells out as a literal command (e.g. `restore --staged`), so the grants may legitimately
#       exceed what this text extraction finds — that is not a failure.
#   (b) bare counterpart: every `-C`-form allow entry's subcommand still has a bare `Bash(git
#       <sub>` allow entry — the mechanical pin that no bare-form rule was removed (sequential
#       mode depends on them).
# Whitespace-normalize the skill text first: two of the documented forms wrap across lines, so a
# line-based grep would silently miss them.
skill_text="$root/skills/issue-implementer/SKILL.md"
mandated_subs="$(tr '\n' ' ' < "$skill_text" \
  | grep -oE 'git -C [^[:space:]]+[[:space:]]+[a-z][a-z-]*' \
  | sed -E 's/.*[[:space:]]//' \
  | sort -u)"
allow_raw="$(jq -r '.permissions.allow[]? // empty' "$settings_json" 2>/dev/null)"
missing_grant=""
for tok in $mandated_subs; do
  printf '%s\n' "$allow_raw" | grep -qF -- "Bash(git -C * $tok " || missing_grant="$missing_grant $tok"
done
c_allow_subs="$(printf '%s\n' "$allow_raw" \
  | grep -oE '^Bash\(git -C \* [a-z][a-z-]*' \
  | sed -E 's/^Bash\(git -C \* //' \
  | sort -u)"
missing_bare=""
for sub in $c_allow_subs; do
  printf '%s\n' "$allow_raw" | grep -qF -- "Bash(git $sub" || missing_bare="$missing_bare $sub"
done
if [ -z "$missing_grant" ] && [ -z "$missing_bare" ]; then
  ok "2.5 permission mirror (allow): every -C form the skill mandates is granted, every -C grant has a bare-form counterpart"
else
  msg="2.5 permission mirror (allow) broken:"
  [ -n "$missing_grant" ] && msg="$msg -C form(s) the skill mandates but not granted:$missing_grant;"
  [ -n "$missing_bare" ] && msg="$msg -C grant(s) with no bare-form counterpart:$missing_bare;"
  bad "$msg"
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
# prose_tsv FILE [HEADING_ERE] — walks FILE's prose body (frontmatter and fenced blocks
# excluded via a fence toggle, so files with more than two fence markers — e.g. skills/*/SKILL.md
# — are handled the same as agents/*.md's exactly-two-fence case), tracking the current heading
# (matched by HEADING_ERE, default '^# ') as the section id. The section starts as the literal
# "(preamble)" rather than empty, so a keyword occurring before the first heading is attributed
# to a real, countable section instead of silently vanishing from the restated-keyword check.
prose_tsv() {
  awk -v hre="${2:-^# }" '
    BEGIN { section = "(preamble)" }
    $0 == "---" { fm++; next }
    fm < 2 { next }
    /^```/ { fence = !fence; next }
    fence { next }
    $0 ~ hre { section = $0 }
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

# next_numbered_step_line FILE START_LINE — first '^[0-9]+\. ' line after START_LINE, or
# (file's last line + 1) if there is none (so callers can slice an open-ended trailing range).
next_numbered_step_line() {
  local n
  n="$(awk -v s="$2" 'NR>s && /^[0-9]+\. /{print NR; exit}' "$1")"
  if [ -z "$n" ]; then
    n=$(( $(wc -l < "$1") + 1 ))
  fi
  printf '%s' "$n"
}

# 3.8 — verifier Process lettering. agents/verifier.md's step 3 ("Check, in order:") must list
# exactly a.-g., contiguous and in order, each with its pinned bold title — full-table pinning
# (not just letter 'g') because CLAUDE.md's 'rule 3g' citation only means what it says if the
# whole table is stable: reordering would keep 'g' a valid letter while silently changing what
# it refers to. Also: every 'rule [0-9][a-z]' citation anywhere in CLAUDE.md must resolve to a
# real numbered Process step and a real letter inside it.
vf="$root/agents/verifier.md"
bad_list=""
start_ln="$(grep -n '^3\. \*\*Check, in order:\*\*' "$vf" | head -1 | cut -d: -f1)"
if [ -z "$start_ln" ]; then
  bad_list="$bad_list [agents/verifier.md: step 3 header '3. **Check, in order:**' not found]"
else
  end_ln="$(next_numbered_step_line "$vf" "$start_ln")"
  letter_lines="$(sed -n "$((start_ln+1)),$((end_ln-1))p" "$vf" | grep -E '^[[:space:]]+[a-g]\. \*\*')"
  seq="$(printf '%s\n' "$letter_lines" | sed -E 's/^[[:space:]]+([a-g])\..*/\1/' | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
  [ "$seq" = "a b c d e f g" ] || bad_list="$bad_list [letter sequence '$seq' != 'a b c d e f g']"
  letter_pairs=(
    "a|Plan conformance"
    "b|Acceptance criteria"
    "c|Test quality"
    "d|Scope"
    "e|Declared constraints"
    "f|Report honesty"
    "g|Documentation"
  )
  for lp in "${letter_pairs[@]}"; do
    ltr="${lp%%|*}"
    title="${lp#*|}"
    line="$(printf '%s\n' "$letter_lines" | grep -E "^[[:space:]]+${ltr}\. \*\*")"
    if [ -z "$line" ]; then
      bad_list="$bad_list [letter $ltr missing from step 3]"
    else
      printf '%s' "$line" | grep -qF -- "$title" || bad_list="$bad_list [letter $ltr's title doesn't name '$title']"
    fi
  done
fi
cm="$root/CLAUDE.md"
citations="$(grep -oE 'rule [0-9][a-z]' "$cm" | sort -u)"
while IFS= read -r cite; do
  [ -z "$cite" ] && continue
  cnum="$(printf '%s' "$cite" | sed -E 's/^rule ([0-9])[a-z]$/\1/')"
  cltr="$(printf '%s' "$cite" | sed -E 's/^rule [0-9]([a-z])$/\1/')"
  step_ln="$(grep -n "^${cnum}\. \*\*" "$vf" | head -1 | cut -d: -f1)"
  if [ -z "$step_ln" ]; then
    bad_list="$bad_list [CLAUDE.md citation '$cite': no numbered step $cnum in agents/verifier.md]"
    continue
  fi
  step_end="$(next_numbered_step_line "$vf" "$step_ln")"
  sed -n "$((step_ln+1)),$((step_end-1))p" "$vf" | grep -qE "^[[:space:]]+${cltr}\. \*\*" \
    || bad_list="$bad_list [CLAUDE.md citation '$cite': letter $cltr not found in step $cnum]"
done <<EOF
$citations
EOF
if [ -z "$bad_list" ]; then
  ok "3.8 agents/verifier.md's step 3 lists a.-g. contiguous with pinned titles; every CLAUDE.md 'rule Nx' citation resolves"
else
  bad "3.8 verifier lettering/citation problem(s):$bad_list"
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
# non-empty description (Gap B: a bare 'description: >' with its folded body deleted used to
# pass, because the old check only looked at whether the line *after* 'description:' was
# non-blank — which is also true of the next frontmatter key entirely. Extracting the actual
# collected value closes that).
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

# 4.4 — WIP-message vocabulary: every 'wip: …' string in the canonical skill file is one of the
# five forms documented in its "WIP checkpoint vocabulary" section, written complete on ONE line.
# Step 2b classifies a leftover branch by these messages, and worktree mode emits them with
# 'git -C <worktree>' in front — a new variant, or one wrapped across lines, breaks that silently.
# ($bt is defined once, near the top-level helpers, and reused here.)
wip_canon="$root/skills/issue-implementer/SKILL.md"
wip_ok='^wip: (checkpoint ([a-z-]+|<stage>)|([a-z-]+|<stage>) died|context exhausted|interrupted run|blocked — .*) \(#<n(umber)?>\)$|^wip: blocked — …$'
wip_list="$(grep -o "wip: [^${bt}\"]*" "$wip_canon")"
bad_list=""
while IFS= read -r s; do
  [ -n "$s" ] || continue
  printf '%s' "$s" | grep -qE "$wip_ok" || bad_list="$bad_list [$s]"
done <<EOF
$wip_list
EOF
if [ -z "$bad_list" ]; then
  ok "4.4 every 'wip: …' string in issue-implementer/SKILL.md matches the documented vocabulary"
else
  bad "4.4 undocumented or line-wrapped wip message(s):$bad_list"
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
# skills/harness-setup/SKILL.md (the audit must cover every policy), and in at least two
# skills/*/SKILL.md files in total. Titles contain spaces, so iterate over a heredoc — 4.4
# already uses this shape.
bad_list=""
while IFS= read -r title; do
  [ -n "$title" ] || continue
  grep -qF -- "$title" "$root/README.md" || bad_list="$bad_list [$title: missing from README.md]"
  grep -qF -- "$title" "$root/skills/harness-setup/SKILL.md" || bad_list="$bad_list [$title: missing from skills/harness-setup/SKILL.md]"
  n=0
  for f in "$root"/skills/*/SKILL.md; do
    grep -qF -- "$title" "$f" && n=$((n+1))
  done
  [ "$n" -ge 2 ] || bad_list="$bad_list [$title: present in only $n skills/*/SKILL.md file(s), need >= 2]"
done <<EOF
Plan auto-approval policy
Merge autonomy policy
Test-suite ratchet policy
EOF
if [ -z "$bad_list" ]; then
  ok "4.8 policy section titles cross-referenced in README.md, harness-setup, and >=2 skills"
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

# 4.10 — one-statement dedupe for skills/*/SKILL.md: the #4/#21 invariant 3.6 applies to
# agents/*.md, extended here to skills at any '#'-'####' heading granularity (frontmatter and
# fenced blocks excluded via prose_tsv's fence toggle). A line matching the cross-reference ERE
# ("stated once", "defined once", "lives solely in", "exists nowhere else") is the pointer the
# #21 dedupe pass deliberately introduced and is excluded before counting — it names where the
# real statement lives rather than restating it. Within-section repetition stays legal: that is
# what the merge pass's legitimate concentration of merge-authority phrasing in one section
# looks like. Same note as 3.6: a false positive is resolved by rewording the prose or by
# adjusting this table with a comment — never by deleting the check.
kw10_ids="merge-authority push-boundary sequencing read-only"
kw10_pattern() {
  case "$1" in
    merge-authority) printf '%s' 'merge authority|never merge' ;;
    push-boundary)   printf '%s' 'never push to the default|push to the default branch' ;;
    sequencing)      printf '%s' 'one at a time|never in parallel' ;;
    read-only)       printf '%s' 'read-only' ;;
  esac
}
xref10_pat='(stated|defined) once|lives solely in|exists nowhere else'
bad_list=""
for f in "$root"/skills/*/SKILL.md; do
  tsv="$(prose_tsv "$f" '^(#|##|###|####) ')"
  for kwid in $kw10_ids; do
    pat="$(kw10_pattern "$kwid")"
    matches="$(printf '%s\n' "$tsv" | grep -iE -- "$pat" | grep -viE -- "$xref10_pat")"
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
  ok "4.10 no merge-authority/push-boundary/sequencing/read-only keyword restated across more than one section of the same skills/*/SKILL.md"
else
  bad "4.10 keyword restated across sections —$bad_list"
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
