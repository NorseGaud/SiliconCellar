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
if [ -n "${CI:-}" ]; then
    echo "CI: skipping Wine Staging Engine copy"
elif [ "${SKIP_ENGINE_BUILD:-}" = "1" ]; then
    if [ -x "$ENGINE_SRC/bin/wine" ]; then
        rm -rf "$ENGINE_DST"
        mkdir -p "$ENGINE_DST"
        cp -R "$ENGINE_SRC"/. "$ENGINE_DST"/
    else
        echo "SKIP_ENGINE_BUILD=1 and Engine missing; packaging without Engine" >&2
    fi
else
    if [ "${FORCE_ENGINE_BUILD:-}" = "1" ] || [ ! -x "$ENGINE_SRC/bin/wine" ]; then
        FORCE_ENGINE_BUILD="${FORCE_ENGINE_BUILD:-}" "$ROOT/scripts/build-wine-engine.sh"
    fi
    rm -rf "$ENGINE_DST"
    mkdir -p "$ENGINE_DST"
    cp -R "$ENGINE_SRC"/. "$ENGINE_DST"/
fi
if [ -z "${CI:-}" ] && [ "${SKIP_ENGINE_BUILD:-}" != "1" ]; then
    test -x "$ENGINE_DST/bin/wine"
fi

echo "Built $APP ($short_version build $bundle_version)"
