#!/bin/sh
# Stage dist/SiliconCellar.app into a temporary folder and create a versioned DMG.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/SiliconCellar.app"
test -d "$APP"

version="${1:?version required}"
build="${2:?build required}"
dmg="$ROOT/SiliconCellar-${version}-${build}.dmg"
stage="$(mktemp -d "${TMPDIR:-/tmp}/siliconcellar-dmg.XXXXXX")"
cleanup() {
    rm -rf "$stage"
}
trap cleanup EXIT

mkdir -p "$stage"
ln -sf /Applications "$stage/Applications"
cp -R "$APP" "$stage/SiliconCellar.app"

rm -f "$ROOT"/SiliconCellar-"${version}"-*.dmg
hdiutil create -fs HFS+ -format ULMO -volname "Silicon Cellar" -srcfolder "$stage" -ov "$dmg"
echo "Created $dmg"
