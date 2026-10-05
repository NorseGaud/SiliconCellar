#!/bin/sh
# Write the release version and DMG SHA-256 into the Homebrew cask.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
usage='usage: update-cask.sh VERSION BUILD PATH/to/SiliconCellar.dmg'
version="${1:?$usage}"
build="${2:?$usage}"
dmg="${3:?$usage}"
. "$ROOT/scripts/homebrew-tap.sh"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

printf '%s\n' "$version" | grep -Eqx '[0-9]+(\.[0-9]+)+' || fail "version must look like 1.2.3, got: $version"
printf '%s\n' "$build" | grep -Eqx '[0-9]+' || fail "build must be a number, got: $build"
test -f "$dmg" || fail "missing DMG: $dmg"
test -f "$cask_file" || fail "missing cask: $cask_file (run git submodule update --init homebrew-siliconcellar, or set HOMEBREW_TAP_DIR)"
grep -Eq '^  version "' "$cask_file" || fail "no version line in $cask_file"
grep -Eq '^  sha256 "' "$cask_file" || fail "no sha256 line in $cask_file"

dmg_sha256="$(shasum -a 256 "$dmg" | awk '{print $1}')"
sed -i '' \
    -e "s/^  version \".*\"\$/  version \"${version},${build}\"/" \
    -e "s/^  sha256 \".*\"\$/  sha256 \"${dmg_sha256}\"/" \
    "$cask_file"
echo "Updated $cask_file to ${version},${build} (sha256 ${dmg_sha256})"
