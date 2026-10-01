#!/bin/sh
# Compile the pinned Wine Engine from source into .build/engine (instead of the release download).
#
# Pin: engine/manifest.json ("version" is the tag in "source_repository").
# Needs: the tools in build/README.md of the Wine repository (Xcode, x86_64 Homebrew in /usr/local).
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MANIFEST="$ROOT/engine/manifest.json"
SOURCE_DIR="$ROOT/.build/wine-src"
PREFIX="$ROOT/.build/engine"
MARKER="$PREFIX/.siliconcellar-engine-version"

eval "$(
    python3 - "$MANIFEST" <<'PY'
import json, shlex, sys
m = json.load(open(sys.argv[1]))
print(f"VERSION={shlex.quote(m['version'])}")
print(f"PROVIDER={shlex.quote(m['provider'])}")
print(f"SOURCE_REPOSITORY={shlex.quote(m['source_repository'])}")
PY
)"

if [ -d "$SOURCE_DIR/.git" ]; then
    git -C "$SOURCE_DIR" fetch --depth 1 origin tag "$VERSION"
    git -C "$SOURCE_DIR" checkout --force "$VERSION"
else
    git clone --depth 1 --branch "$VERSION" "$SOURCE_REPOSITORY" "$SOURCE_DIR"
fi

rm -rf "$PREFIX"
"$SOURCE_DIR/build/build-engine.sh" "$PREFIX"
printf '%s\n' "$PROVIDER-$VERSION-source" >"$MARKER"
echo "Built Engine $PROVIDER-$VERSION-source → $PREFIX"
