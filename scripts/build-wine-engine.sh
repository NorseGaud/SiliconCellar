#!/bin/sh
# Fetch the latest Silicon Cellar Wine Engine release into .build/engine.
#
# Pin: engine/manifest.json. When the latest release differs from the pin, the pin is rewritten
# to that release first (commit the change). Offline, the current pin is used.
# Release source: https://github.com/NorseGaud/wine/releases (built by build/build-engine.sh in that repo)
# To compile the Engine from source instead, run `make engine-source`.
#
# Needs: curl, tar (xz), shasum, python3.
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

pin_latest_release() {
    repository="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["source_repository"].removeprefix("https://github.com/"))' "$MANIFEST")"
    latest_release_json="$(curl -fsSL --max-time 20 --proto '=https' "https://api.github.com/repos/$repository/releases/latest")" || return 1
    python3 - "$MANIFEST" "$latest_release_json" <<'PY'
import json, sys
manifest_path, latest_release_json = sys.argv[1], sys.argv[2]
manifest = json.load(open(manifest_path))
release = json.loads(latest_release_json)
tag = release["tag_name"]
if tag == manifest["version"]:
    print(f"Engine pin {tag} is the latest release")
    sys.exit(0)
asset_name = f"siliconcellar-wine-{tag}-x86_64.tar.xz"
asset = next((a for a in release["assets"] if a["name"] == asset_name), None)
digest = (asset or {}).get("digest") or ""
if not digest.startswith("sha256:"):
    sys.exit(f"release {tag} has no {asset_name} with a sha256 digest")
print(f"Engine release {tag} differs from pin {manifest['version']}; updating {manifest_path}")
manifest.update(version=tag, url=asset["browser_download_url"], sha256=digest.removeprefix("sha256:"))
with open(manifest_path, "w") as file:
    json.dump(manifest, file, indent=2)
    file.write("\n")
PY
}

if [ "${KEEP_ENGINE_PIN:-}" = "1" ]; then
    echo "KEEP_ENGINE_PIN=1: packaging the Engine pin in $MANIFEST"
else
    pin_latest_release || echo "Could not check the latest Engine release; using the current pin" >&2
fi

eval "$(
    python3 - "$MANIFEST" <<'PY'
import json, shlex, sys
m = json.load(open(sys.argv[1]))
version = m["version"]
provider = m["provider"]
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
ARCHIVE="$CACHE/wine-${PIN_ID}.tar.xz"

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

echo "Extracting Wine Engine ${PIN_ID}..."
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
