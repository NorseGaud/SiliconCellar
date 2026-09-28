#!/bin/sh
# Check that update-cask.sh rewrites only the version and sha256 lines.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/siliconcellar-cask-test.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

original_cask="$work_dir/original.rb"
test_cask="$work_dir/siliconcellar.rb"
fake_dmg="$work_dir/SiliconCellar-9.8.7-65.dmg"
cat >"$original_cask" <<'EOF'
cask "siliconcellar" do
  version "0.1.0,1"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/NorseGaud/SiliconCellar/releases/download/#{version.csv.first}/SiliconCellar-#{version.csv.first}-#{version.csv.second}.dmg"
  name "Silicon Cellar"

  app "SiliconCellar.app"
end
EOF
cp "$original_cask" "$test_cask"
printf 'siliconcellar cask test\n' >"$fake_dmg"
expected_sha256="$(shasum -a 256 "$fake_dmg" | awk '{print $1}')"

CASK_FILE="$test_cask" "$ROOT/scripts/update-cask.sh" 9.8.7 65 "$fake_dmg" >/dev/null

grep -qx '  version "9.8.7,65"' "$test_cask" || fail "version line not updated"
grep -qx "  sha256 \"$expected_sha256\"" "$test_cask" || fail "sha256 line not updated"

unchanged_lines_pattern='^  (version|sha256) "'
grep -Ev "$unchanged_lines_pattern" "$original_cask" >"$work_dir/before"
grep -Ev "$unchanged_lines_pattern" "$test_cask" >"$work_dir/after"
cmp -s "$work_dir/before" "$work_dir/after" || fail "lines other than version and sha256 changed"

if CASK_FILE="$test_cask" "$ROOT/scripts/update-cask.sh" 9.8 x "$fake_dmg" 2>/dev/null; then
    fail "non-numeric build accepted"
fi
if CASK_FILE="$test_cask" "$ROOT/scripts/update-cask.sh" 9.8.7 65 "$work_dir/missing.dmg" 2>/dev/null; then
    fail "missing DMG accepted"
fi

tap_dir="$work_dir/homebrew-siliconcellar"
mkdir -p "$tap_dir/Casks"
cp "$original_cask" "$tap_dir/Casks/siliconcellar.rb"
HOMEBREW_TAP_DIR="$tap_dir" "$ROOT/scripts/update-cask.sh" 9.8.7 66 "$fake_dmg" >/dev/null
grep -qx '  version "9.8.7,66"' "$tap_dir/Casks/siliconcellar.rb" || fail "HOMEBREW_TAP_DIR cask not updated"

echo "update-cask.sh: ok"
