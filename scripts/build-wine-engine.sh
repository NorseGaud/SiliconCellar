#!/bin/sh
# Fetch the pinned Gcenx Wine Staging macOS package into .build/engine.
#
# Pin: engine/manifest.json
# Release source: https://github.com/Gcenx/macOS_Wine_builds/releases
#
# Needs: curl, tar (xz), shasum, python3. No local Wine compile.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

MANIFEST="$ROOT/engine/manifest.json"
CACHE="$ROOT/.build/engine-cache"
PREFIX="$ROOT/.build/engine"
MARKER="$PREFIX/.siliconcellar-engine-version"

if [ ! -f "$MANIFEST" ]; then
    echo "missing $MANIFEST" >&2
    exit 1
fi

eval "$(
    python3 - "$MANIFEST" <<'PY'
import json, shlex, sys
m = json.load(open(sys.argv[1]))
version = m["version"]
provider = m.get("provider", "gcenx")
print(f"VERSION={shlex.quote(version)}")
print(f"PROVIDER={shlex.quote(provider)}")
print(f"PIN_ID={shlex.quote(f'{provider}-{version}')}")
print(f"URL={shlex.quote(m['url'])}")
print(f"SHA={shlex.quote(m['sha256'])}")
print(f"WINE_SUBDIR={shlex.quote(m['wine_subdir'])}")
PY
)"

if [ "${FORCE_ENGINE_BUILD:-}" != "1" ] \
    && [ -x "$PREFIX/bin/wine" ] \
    && [ -f "$MARKER" ] \
    && [ "$(cat "$MARKER")" = "$PIN_ID" ]; then
    echo "Engine $PIN_ID already installed at $PREFIX (set FORCE_ENGINE_BUILD=1 to refresh)"
    exit 0
fi

if [ "${FORCE_ENGINE_BUILD:-}" = "1" ]; then
    echo "FORCE_ENGINE_BUILD=1: refreshing Engine $PIN_ID"
fi

mkdir -p "$CACHE"
ARCHIVE="$CACHE/wine-staging-${VERSION}-osx64.tar.xz"

fetch() {
    url="$1"
    sha="$2"
    out="$3"
    if [ -f "$out" ] && echo "$sha  $out" | shasum -a 256 -c - >/dev/null 2>&1; then
        echo "Using cached $out"
        return 0
    fi
    echo "Downloading $url"
    curl -fL --proto '=https' --proto-redir '=https' -o "$out.partial" "$url"
    mv "$out.partial" "$out"
    echo "$sha  $out" | shasum -a 256 -c -
}

fetch "$URL" "$SHA" "$ARCHIVE"

EXTRACT="$CACHE/extract-$PIN_ID"
rm -rf "$EXTRACT" "$PREFIX"
mkdir -p "$EXTRACT" "$PREFIX"

echo "Extracting Wine Staging ${VERSION}..."
tar -xJf "$ARCHIVE" -C "$EXTRACT"

WINE_TREE="$EXTRACT/$WINE_SUBDIR"
if [ ! -x "$WINE_TREE/bin/wine" ]; then
    echo "expected wine at $WINE_TREE/bin/wine" >&2
    find "$EXTRACT" -name wine -type f 2>/dev/null | head -20 >&2 || true
    exit 1
fi

# Engine layout: Contents/Resources/Engine/{bin,lib,share}
cp -R "$WINE_TREE"/. "$PREFIX"/

if [ ! -x "$PREFIX/bin/wine" ]; then
    echo "install finished but $PREFIX/bin/wine is missing" >&2
    exit 1
fi

printf '%s\n' "$PIN_ID" >"$MARKER"
echo "Installed Engine $PIN_ID → $PREFIX"
file "$PREFIX/bin/wine" || true
"$PREFIX/bin/wine" --version || true
