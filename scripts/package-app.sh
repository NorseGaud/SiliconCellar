#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/app-bundle.sh"

version_file="$ROOT/VERSION"
if [ -n "${VERSION:-}" ]; then
    short_version="$VERSION"
elif [ -s "$version_file" ]; then
    short_version="$(tr -d ' \t\r\n' <"$version_file")"
else
    short_version="0.1.0"
fi

if [ -n "${BUILD_NUMBER:-}" ]; then
    bundle_version="$BUILD_NUMBER"
else
    bundle_version="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
fi

swift build -c release --product SiliconCellar
swift build -c release --product siliconcellar-cli
BIN="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/SiliconCellar.app"
write_app_bundle "$APP" "$BIN/SiliconCellar" com.norsegaud.siliconcellar "$short_version" "$bundle_version"
cp "$BIN/siliconcellar-cli" "$APP/Contents/MacOS/siliconcellar-cli"
mkdir -p "$APP/Contents/Resources/Recipes"
cp Recipes/*.json "$APP/Contents/Resources/Recipes/"

ENGINE_SRC="$ROOT/.build/engine"
ENGINE_DST="$APP/Contents/Resources/Engine"
copy_slim_engine() {
    rm -rf "$ENGINE_DST"
    mkdir -p "$ENGINE_DST"
    cp -R "$ENGINE_SRC"/. "$ENGINE_DST"/
    python3 "$ROOT/scripts/slim-engine.py" "$ENGINE_DST"
}
if [ -n "${CI:-}" ]; then
    echo "CI: skipping Wine Engine copy"
elif [ "${SKIP_ENGINE_BUILD:-}" = "1" ]; then
    if [ -x "$ENGINE_SRC/bin/wine" ]; then
        copy_slim_engine
    else
        echo "SKIP_ENGINE_BUILD=1 and Engine missing; packaging without Engine" >&2
    fi
else
    FORCE_ENGINE_BUILD="${FORCE_ENGINE_BUILD:-}" "$ROOT/scripts/build-wine-engine.sh"
    copy_slim_engine
fi
if [ -z "${CI:-}" ] && [ "${SKIP_ENGINE_BUILD:-}" != "1" ]; then
    test -x "$ENGINE_DST/bin/wine"
fi

# LGPL: ship the Wine licence and say where the exact Engine source is.
write_engine_licenses() {
    licenses="$APP/Contents/Resources/Licenses"
    mkdir -p "$licenses"
    if [ -f "$ENGINE_DST/share/doc/wine/COPYING.LIB" ]; then
        cp "$ENGINE_DST/share/doc/wine/COPYING.LIB" "$licenses/Wine-LGPL.txt"
    fi
    python3 - "$ROOT/engine/manifest.json" >"$licenses/Wine-SOURCE.txt" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print(f"Silicon Cellar Wine Engine {m['version']} (LGPL-2.1-or-later)")
print(f"Source: {m['source_repository']}/tree/{m['version']}")
print(f"Build: {m['url']}")
print("Licences of the bundled libraries: Contents/Resources/Engine/share/doc")
PY
}
write_engine_licenses

echo "Built $APP ($short_version build $bundle_version)"
