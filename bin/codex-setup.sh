#!/usr/bin/env bash
#
# codex-setup.sh — installs this plugin's Codex compatibility layer into the current repo (#408).
#
# Usage:
#   codex-setup.sh           Generate/update the files below in the current repo.
#   codex-setup.sh --check   Read-only drift check: same comparison, no write, ever (#410 consumes
#                            this mode). Exits 0 clean, 1 on any drift or unsupported path, 2 on a
#                            usage/environment error.
#   codex-setup.sh --help
#
# WHAT IT WRITES (relative to the repo's git toplevel):
#   .codex/agents/planner.toml, implementer.toml, verifier.toml
#                       — one Codex custom agent file per agents/<role>.md in this plugin, with
#                         name/description/developer_instructions only (no tools/model — see ADR
#                         0002 P2/decision 3's "no sandboxed read-only planner").
#   .codex/rules/trail-blazer-flow.rules
#                       — templates/codex.rules with the plugin-bin placeholder substituted for
#                         this install's own bin/ directory (absolute path, logical/non -P).
#   AGENTS.md (edited, never created) or .codex/config.toml
#                       — a repo that already has an AGENTS.md gets a marked pointer block naming
#                         CLAUDE.md; a repo without one gets a project_doc_fallback_filenames
#                         entry in .codex/config.toml instead (Codex suppresses the deterministic
#                         fallback whenever an AGENTS.md shim exists — ADR 0002 amendment
#                         2026-09-26 Q5).
#
# See docs/reference/codex.md for the rules file's allow/forbidden/gated sections, why each
# gated script needs a host_executable pin, this script's --check drift-token grammar, the lock's
# Codex owner contract, and the honest limits (rules match by prefix; forbidden rules mirror the
# Claude template's coarse deny list only).
#
# Re-run this after every plugin upgrade: the rules file's host_executable paths are pinned to
# THIS install's own bin/ directory, which carries the version.
set -uo pipefail

CODEX_AGENT_ROLES="planner implementer verifier"
BEGIN_MARKER="<!-- trail-blazer-flow:contract-pointer -->"
END_MARKER="<!-- /trail-blazer-flow:contract-pointer -->"
POINTER_BODY="The harness contract for this repo is CLAUDE.md. Read CLAUDE.md before any work."
CONFIG_KEY_LINE='project_doc_fallback_filenames = ["CLAUDE.md"]'
CONFIG_COMMENT_LINE="# trail-blazer-flow: load CLAUDE.md as Codex's project doc when AGENTS.md is absent (#408)."

usage() {
  cat <<'EOF'
usage: codex-setup.sh [--check]
       codex-setup.sh --help

Installs this plugin's Codex compatibility layer into the current repo: three .codex/agents/*.toml
files (one per agents/*.md role), .codex/rules/trail-blazer-flow.rules, and either a marked
pointer block in an existing AGENTS.md or a project_doc_fallback_filenames entry in
.codex/config.toml (never both, and AGENTS.md is never created).

  (no flags)   Write mode. Prints one `wrote=<relpath>` or `unchanged=<relpath>` line per file,
               then, only if at least one file was written, three `next:` lines naming the
               project-trust, plugin-hook-trust and `codex --no-daemon` steps.
  --check      Read-only: never writes, never creates .codex/. Prints `ok=<relpath>` when a file
               is already current, or `drift=<relpath> reason=<token>` otherwise (token one of
               missing, differs, stale-plugin-path, missing-fallback, fallback-conflict,
               missing-pointer, malformed-pointer), or `unsupported=<plugin-root|repo-path>
               reason=<whitespace|unsupported-character> path=<p>` for an unsupported path. Exits
               0 when everything is current, 1 when anything drifted or a path is unsupported.
  -h, --help   This text (exit 0).

Exit codes: 0 = success/clean, 1 = drift found (--check only), 2 = usage or environment error
(not inside a git repository, a whitespace/unsupported-character path in write mode, a malformed
agents/*.md, a malformed contract-pointer marker, or a .codex/config.toml fallback conflict).
EOF
}

check_mode=false
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --check) check_mode=true; shift ;;
  "") : ;;
  *) usage >&2; exit 2 ;;
esac
if [ "$#" -gt 0 ]; then
  usage >&2
  exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
plugin_root="$(cd "$script_dir/.." && pwd)"
plugin_bin="$plugin_root/bin"

repo_top="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "codex-setup.sh: not inside a git repository (git rev-parse --show-toplevel failed)" >&2
  exit 2
}

# --- path validation (#408) --------------------------------------------------------------------
# Whitespace anywhere in either path is unsupported (it would break the sed substitution below and
# any shell quoting a consumer might build around this script's output); a plugin_root character
# outside this allowlist is unsupported too, for the same reason plus the Starlark rules string.
unsupported_found=false
report_unsupported() {
  local label="$1" reason="$2" path="$3"
  if $check_mode; then
    echo "unsupported=$label reason=$reason path=$path"
  fi
  unsupported_found=true
}
case "$plugin_root" in
  *[[:space:]]*) report_unsupported plugin-root whitespace "$plugin_root" ;;
  *[!A-Za-z0-9._/@+:-]*) report_unsupported plugin-root unsupported-character "$plugin_root" ;;
esac
case "$repo_top" in
  *[[:space:]]*) report_unsupported repo-path whitespace "$repo_top" ;;
esac
if $unsupported_found; then
  if $check_mode; then
    exit 1
  fi
  echo "codex-setup.sh: unsupported plugin root or repo path — refusing to write anything" >&2
  exit 2
fi

# --- required inputs (this plugin install's own files) ------------------------------------------
for role in $CODEX_AGENT_ROLES; do
  if [ ! -f "$plugin_root/agents/$role.md" ]; then
    echo "codex-setup.sh: missing $plugin_root/agents/$role.md — broken plugin install" >&2
    exit 2
  fi
done
if [ ! -f "$plugin_root/templates/codex.rules" ]; then
  echo "codex-setup.sh: missing $plugin_root/templates/codex.rules — broken plugin install" >&2
  exit 2
fi

scratch_dir="$(mktemp -d)"
cleanup() { rm -rf "$scratch_dir"; }
trap cleanup EXIT

any_drift=false
any_written=false

# install_rel/install_tmpfile/install_reason (#408 kickback finding 1) — every generator below
# calls queue_install instead of installing straight away, so a later role's or a later step's
# validation failure (a malformed agents/*.md, a malformed AGENTS.md marker, a config.toml
# conflict) can still exit 2 before anything has touched $repo_top, no matter how many earlier
# outputs were already generated. Only the drain loop after every generator has run (see "install"
# below) ever calls emit_result, so a mid-run exit 2 always leaves the repo untouched.
install_rel=()
install_tmpfile=()
install_reason=()
queue_install() {
  install_rel+=("$1")
  install_tmpfile+=("$2")
  install_reason+=("${3:-differs}")
}

# emit_result REL TMPFILE [DIFFERS_REASON] — REL is relative to $repo_top. Compares TMPFILE
# against the existing $repo_top/REL (if any). Write mode: mkdir -p + mv on missing/differs,
# printing wrote=/unchanged=. --check mode: NEVER creates a directory or file — only compares and
# prints ok=/drift=, leaving TMPFILE for the trap to clean up. Called only from the drain loop
# below, never directly from a generator.
emit_result() {
  local rel="$1" tmpfile="$2" differs_reason="${3:-differs}"
  local dest="$repo_top/$rel"
  if [ -f "$dest" ] && cmp -s "$tmpfile" "$dest"; then
    if $check_mode; then echo "ok=$rel"; else echo "unchanged=$rel"; fi
    return
  fi
  if $check_mode; then
    if [ -f "$dest" ]; then
      echo "drift=$rel reason=$differs_reason"
    else
      echo "drift=$rel reason=missing"
    fi
    any_drift=true
    return
  fi
  mkdir -p "$(dirname "$dest")"
  mv "$tmpfile" "$dest"
  echo "wrote=$rel"
  any_written=true
}

# --- agent TOMLs ---------------------------------------------------------------------------------
# parse_frontmatter FILE — sets fm_name/fm_descform/fm_desc/fm_end from FILE's YAML frontmatter.
# descform is "folded" (a `>`/`>-` block scalar, continuation lines stripped of leading whitespace
# and joined with single spaces), "inline" (a single-line scalar), or "bad" (anything else, e.g. an
# empty value or a `|`-style literal block).
parse_frontmatter() {
  local file="$1" out
  out="$(awk '
    $0 == "---" && fmend == 0 {
      if (NR == 1) { next }
      fmend = NR
      next
    }
    fmend == 0 {
      if ($0 ~ /^name:[ \t]*/) {
        v = $0; sub(/^name:[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
        name = v; indesc = 0
      } else if ($0 ~ /^description:[ \t]*/) {
        v = $0; sub(/^description:[ \t]*/, "", v)
        if (v == ">" || v == ">-") { indesc = 1; desc = ""; descform = "folded" }
        else if (v != "") { desc = v; indesc = 0; descform = "inline" }
        else { descform = "bad"; indesc = 0 }
      } else if (indesc == 1 && $0 ~ /^[ \t]+[^ \t]/) {
        v = $0; sub(/^[ \t]+/, "", v)
        if (desc == "") { desc = v } else { desc = desc " " v }
      } else {
        indesc = 0
      }
    }
    END {
      print "NAME\t" name
      print "DESCFORM\t" descform
      print "DESC\t" desc
      print "FMEND\t" fmend
    }
  ' "$file")"
  fm_name=""; fm_descform=""; fm_desc=""; fm_end=0
  while IFS= read -r fm_line; do
    case "$fm_line" in
      NAME$'\t'*)     fm_name="${fm_line#NAME$'\t'}" ;;
      DESCFORM$'\t'*) fm_descform="${fm_line#DESCFORM$'\t'}" ;;
      DESC$'\t'*)     fm_desc="${fm_line#DESC$'\t'}" ;;
      FMEND$'\t'*)    fm_end="${fm_line#FMEND$'\t'}" ;;
    esac
  done <<EOF
$out
EOF
}

for role in $CODEX_AGENT_ROLES; do
  md_file="$plugin_root/agents/$role.md"
  parse_frontmatter "$md_file"
  if [ "$fm_end" -eq 0 ]; then
    echo "codex-setup.sh: $md_file has no closing frontmatter delimiter" >&2
    exit 2
  fi
  if [ "$fm_name" != "$role" ]; then
    echo "codex-setup.sh: $md_file's frontmatter name '$fm_name' does not match role '$role'" >&2
    exit 2
  fi
  case "$fm_descform" in
    folded|inline) : ;;
    *)
      echo "codex-setup.sh: $md_file's description is neither an inline scalar nor a >/>- folded block" >&2
      exit 2
      ;;
  esac

  bodyfile="$scratch_dir/$role.body"
  tail -n +"$((fm_end + 1))" "$md_file" | tr -d '\r' > "$bodyfile"
  if grep -qF -- "'''" "$bodyfile"; then
    echo "codex-setup.sh: $md_file's body contains a triple single-quote (''') — cannot embed it in a TOML literal string" >&2
    exit 2
  fi
  if [ -s "$bodyfile" ] && [ -n "$(tail -c1 "$bodyfile")" ]; then
    printf '\n' >> "$bodyfile"
  fi

  desc_esc="${fm_desc//\\/\\\\}"
  desc_esc="${desc_esc//\"/\\\"}"

  tomlfile="$scratch_dir/$role.toml"
  {
    printf '# Generated by codex-setup.sh from agents/%s.md - do not edit by hand.\n' "$role"
    printf 'name = "%s"\n' "$role"
    printf 'description = "%s"\n' "$desc_esc"
    printf "developer_instructions = '''\n"
    cat "$bodyfile"
    printf "'''\n"
  } > "$tomlfile"
  queue_install ".codex/agents/$role.toml" "$tomlfile"
done

# --- rules ----------------------------------------------------------------------------------------
rulesfile="$scratch_dir/trail-blazer-flow.rules"
sed "s|@PLUGIN_BIN@|$plugin_bin|g" "$plugin_root/templates/codex.rules" > "$rulesfile"

rules_reason="differs"
rules_dest="$repo_top/.codex/rules/trail-blazer-flow.rules"
if [ -f "$rules_dest" ]; then
  while IFS= read -r hx_path; do
    case "$hx_path" in
      "$plugin_bin"/*) : ;;
      *) rules_reason="stale-plugin-path" ;;
    esac
  done < <(grep -oE 'paths = \["[^"]*"\]' "$rules_dest" 2>/dev/null | sed -E 's/paths = \["(.*)"\]/\1/')
fi
queue_install ".codex/rules/trail-blazer-flow.rules" "$rulesfile" "$rules_reason"

# --- contract loading -------------------------------------------------------------------------
# Marker detection (#408 kickback finding 2) uses grep -x (whole-LINE match), the same rule the
# rewrite awk below applies via `$0 == begin`/`$0 == end`; a substring match would let the awk
# miss the end marker and delete every line after the begin marker. Any line that carries a marker
# string but is not an exact match (a CR terminator, trailing text, indentation, a prose mention)
# makes the file malformed: the substring counts must equal the exact counts, or the script
# refuses (write mode) / reports malformed-pointer (--check) rather than guess.
agents_md="$repo_top/AGENTS.md"
if [ -f "$agents_md" ]; then
  begin_count="$(grep -xcF -- "$BEGIN_MARKER" "$agents_md")"
  end_count="$(grep -xcF -- "$END_MARKER" "$agents_md")"
  begin_line="$(grep -xnF -- "$BEGIN_MARKER" "$agents_md" | head -1 | cut -d: -f1)"
  end_line="$(grep -xnF -- "$END_MARKER" "$agents_md" | head -1 | cut -d: -f1)"
  begin_any="$(grep -cF -- "$BEGIN_MARKER" "$agents_md")"
  end_any="$(grep -cF -- "$END_MARKER" "$agents_md")"
  exact_only=true
  if [ "$begin_any" -ne "$begin_count" ] || [ "$end_any" -ne "$end_count" ]; then
    exact_only=false
  fi

  malformed=false
  pointer_reason="differs"
  if $exact_only && [ "$begin_count" -eq 0 ] && [ "$end_count" -eq 0 ]; then
    pointer_reason="missing-pointer"
  elif $exact_only && [ "$begin_count" -eq 1 ] && [ "$end_count" -eq 1 ] && [ "$begin_line" -lt "$end_line" ]; then
    : # exactly one well-ordered pair — rewrite in place below
  else
    malformed=true
  fi

  if $malformed; then
    if $check_mode; then
      echo "drift=AGENTS.md reason=malformed-pointer"
      any_drift=true
    else
      echo "codex-setup.sh: AGENTS.md has a malformed trail-blazer-flow:contract-pointer marker (unpaired, duplicated, out of order, or a marker string on a line that is not exactly the marker) — refusing to edit it" >&2
      exit 2
    fi
  else
    agentsfile="$scratch_dir/AGENTS.md"
    if [ "$pointer_reason" = "missing-pointer" ]; then
      cp "$agents_md" "$agentsfile"
      if [ -s "$agentsfile" ] && [ -n "$(tail -c1 "$agentsfile")" ]; then
        printf '\n' >> "$agentsfile"
      fi
      {
        printf '%s\n' "$BEGIN_MARKER"
        printf '%s\n' "$POINTER_BODY"
        printf '%s\n' "$END_MARKER"
      } >> "$agentsfile"
    else
      awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v body="$POINTER_BODY" '
        $0 == begin { print; print body; skip = 1; next }
        skip == 1 { if ($0 == end) { print; skip = 0 }; next }
        { print }
      ' "$agents_md" > "$agentsfile"
    fi
    queue_install "AGENTS.md" "$agentsfile" "$pointer_reason"
  fi
else
  config_dest="$repo_top/.codex/config.toml"
  config_reason=""
  if [ -f "$config_dest" ]; then
    first_table_line="$(grep -n '^\[' "$config_dest" | head -1 | cut -d: -f1)"
    if [ -z "$first_table_line" ]; then
      first_table_line=$(($(wc -l < "$config_dest") + 1))
    fi
    existing_key_line="$(awk -v lim="$first_table_line" 'NR < lim && /^project_doc_fallback_filenames[ \t]*=/ { print; exit }' "$config_dest")"
    if [ -n "$existing_key_line" ]; then
      case "$existing_key_line" in
        *'"CLAUDE.md"'*) config_reason="" ;;
        *) config_reason="fallback-conflict" ;;
      esac
    else
      config_reason="missing-fallback"
    fi
  fi

  if [ "$config_reason" = "fallback-conflict" ]; then
    if $check_mode; then
      echo "drift=.codex/config.toml reason=fallback-conflict"
      any_drift=true
    else
      echo "codex-setup.sh: .codex/config.toml already sets project_doc_fallback_filenames without \"CLAUDE.md\" — refusing to override it" >&2
      exit 2
    fi
  else
    configfile="$scratch_dir/config.toml"
    if [ "$config_reason" = "missing-fallback" ]; then
      {
        printf '%s\n' "$CONFIG_COMMENT_LINE"
        printf '%s\n' "$CONFIG_KEY_LINE"
        cat "$config_dest"
      } > "$configfile"
    elif [ -f "$config_dest" ]; then
      cp "$config_dest" "$configfile"
    else
      {
        printf '%s\n' "$CONFIG_COMMENT_LINE"
        printf '%s\n' "$CONFIG_KEY_LINE"
      } > "$configfile"
    fi
    queue_install ".codex/config.toml" "$configfile" "missing-fallback"
  fi
fi

# --- install (#408 kickback finding 1) --------------------------------------------------------
# Every output above was generated into $scratch_dir and merely queued — nothing above this point
# ever touched $repo_top. Only now, after every validation step that can `exit 2` has already run
# to completion, do we compare and (write mode only) move files into place.
i=0
while [ "$i" -lt "${#install_rel[@]}" ]; do
  emit_result "${install_rel[$i]}" "${install_tmpfile[$i]}" "${install_reason[$i]}"
  i=$((i + 1))
done

# --- final verdict ---------------------------------------------------------------------------
if $check_mode; then
  if $any_drift; then
    exit 1
  fi
  exit 0
fi

if $any_written; then
  echo "next: trust this project in Codex (its rules and agents load only once trusted)"
  echo "next: trust this plugin's hooks — they install untrusted and are skipped silently otherwise"
  echo "next: run harness sessions with codex --no-daemon (see docs/reference/codex.md)"
fi
exit 0
