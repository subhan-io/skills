#!/usr/bin/env bash
# Fixture and consistency tests for Antigravity plugin packaging, install.sh --agy,
# and update-skills.sh Antigravity support.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

check() { # check <name> <command...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    fails=$((fails + 1))
  fi
}

root_manifest="$root/.antigravity-plugin/plugin.json"
check "root manifest is valid JSON with kebab-case name" \
  jq -e '(.name | test("^[a-z0-9]+(-[a-z0-9]+)*$")) and (.description | length > 0) and (.version | length > 0) and (.repository == "https://github.com/subhan-io/skills") and (.skills | type == "array" and length > 0)' \
  "$root_manifest"

# Verify every skill path in root manifest exists and contains a matching SKILL.md.
root_plugins=()
while IFS= read -r rel; do
  dir="$root/${rel#./}"
  check "root skill dir exists: $rel" test -d "$dir"
  skill_count=0
  for skill_md in "$dir"/*/SKILL.md; do
    [ -f "$skill_md" ] || continue
    skill_count=$((skill_count + 1))
    skill_dir="$(basename "$(dirname "$skill_md")")"
    check "SKILL.md frontmatter name matches dir ($skill_dir)" \
      grep -q "^name: ${skill_dir}$" "$skill_md"
  done
  check "root skill dir contains at least one SKILL.md: $rel" test "$skill_count" -gt 0
  plugin_name="$(basename "$(dirname "$dir")")"
  root_plugins+=("$plugin_name")
done < <(jq -r '.skills[]' "$root_manifest")

# Verify per-plugin manifests match the root bundle list.
sub_plugins=()
for manifest in "$root"/plugins/*/.antigravity-plugin/plugin.json; do
  [ -f "$manifest" ] || continue
  plugin_dir="$(dirname "$(dirname "$manifest")")"
  plugin_name="$(basename "$plugin_dir")"
  sub_plugins+=("$plugin_name")
  check "plugin manifest valid ($plugin_name)" \
    jq -e --arg n "$plugin_name" \
      '.name == $n and (.description | length > 0) and (.version | length > 0) and (.repository == "https://github.com/subhan-io/skills")' \
      "$manifest"
done

root_sorted="$(printf '%s\n' "${root_plugins[@]}" | sort)"
sub_sorted="$(printf '%s\n' "${sub_plugins[@]}" | sort)"
check "root bundle skills match per-plugin Antigravity manifests" test "$root_sorted" = "$sub_sorted"

# If agy is available locally, run its strict validator on root + every sub-plugin.
if command -v agy >/dev/null 2>&1; then
  check "agy plugin validate --strict (root)" agy plugin validate --strict "$root"
  for plugin_name in "${sub_plugins[@]}"; do
    check "agy plugin validate --strict ($plugin_name)" \
      agy plugin validate --strict "$root/plugins/$plugin_name"
  done
fi

# Test install.sh --agy into a throwaway destination.
agy_dest="$tmp/agy-skills"
check "install.sh --agy links compatible skills" \
  env AGY_SKILLS_DIR="$agy_dest" "$root/install.sh" --agy
linked_sorted="$(find "$agy_dest" -mindepth 1 -maxdepth 1 -type l -exec basename {} \; | sort)"
check "install.sh --agy linked exact set of Antigravity skills" test "$linked_sorted" = "$sub_sorted"
check "install.sh --agy excludes ship-issue-omp" test ! -e "$agy_dest/ship-issue-omp"
check "install.sh --agy excludes ship-issue by default" test ! -e "$agy_dest/ship-issue"

# Test update-skills.sh Antigravity section with stub binaries.
stub="$tmp/stub"
fake_home="$tmp/home"
agy_log="$tmp/agy.log"
mkdir -p "$stub" "$fake_home/.gemini/config/plugins/subhan-skills/.antigravity-plugin" \
  "$fake_home/.gemini/config/plugins/pr-media-upload/.antigravity-plugin" \
  "$fake_home/.gemini/config/plugins/other-plugin/.antigravity-plugin"

cp "$root_manifest" "$fake_home/.gemini/config/plugins/subhan-skills/.antigravity-plugin/plugin.json"
cp "$root/plugins/pr-media-upload/.antigravity-plugin/plugin.json" \
  "$fake_home/.gemini/config/plugins/pr-media-upload/.antigravity-plugin/plugin.json"
cat > "$fake_home/.gemini/config/plugins/other-plugin/.antigravity-plugin/plugin.json" <<'EOF'
{"name":"other-plugin","version":"1.0.0","repository":"https://github.com/other/repo"}
EOF

cat > "$stub/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "list" ]; then echo "[]"; fi
exit 0
EOF
cat > "$stub/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$stub/agy" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$agy_log"
if [ "\${1:-}" = "plugin" ] && [ "\${2:-}" = "list" ] && [ "\${3:-}" = "--json" ]; then
  cat <<'JSON'
[
  {"name":"subhan-skills","path":"$fake_home/.gemini/config/plugins/subhan-skills"},
  {"name":"pr-media-upload","path":"$fake_home/.gemini/config/plugins/pr-media-upload"},
  {"name":"other-plugin","path":"$fake_home/.gemini/config/plugins/other-plugin"}
]
JSON
fi
exit 0
EOF
chmod +x "$stub/claude" "$stub/codex" "$stub/agy"

check "update-skills.sh runs cleanly with stub CLIs" \
  env PATH="$stub:$PATH" HOME="$fake_home" \
  bash "$root/plugins/update-skills/skills/update-skills/scripts/update-skills.sh"
check "update-skills.sh reinstalls root subhan-skills bundle" \
  grep -qx 'plugin install https://github.com/subhan-io/skills' "$agy_log"
check "update-skills.sh reinstalls individual subhan-io/skills plugin" \
  grep -qx 'plugin install https://github.com/subhan-io/skills/tree/main/plugins/pr-media-upload' "$agy_log"
check "update-skills.sh skips unrelated agy plugins" \
  bash -c "! grep -q 'other-plugin' '$agy_log'"

if [ "$fails" -ne 0 ]; then
  echo "$fails check(s) failed" >&2
  exit 1
fi
echo "all antigravity manifest checks passed"
