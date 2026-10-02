#!/bin/sh
# Compile the wine/ submodule into .build/engine (instead of the release download).
#
# Needs: the tools in wine/build/README.md (Xcode, x86_64 Homebrew in /usr/local).
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MANIFEST="$ROOT/engine/manifest.json"
SOURCE_DIR="$ROOT/wine"
PREFIX="$ROOT/.build/engine"
MARKER="$PREFIX/.siliconcellar-engine-version"

if [ ! -e "$SOURCE_DIR/.git" ]; then
    echo "Missing wine submodule. Run: git submodule update --init wine" >&2
    exit 1
fi

eval "$(
    python3 - "$MANIFEST" <<'PY'
import json, shlex, sys
m = json.load(open(sys.argv[1]))
print(f"VERSION={shlex.quote(m['version'])}")
print(f"PROVIDER={shlex.quote(m['provider'])}")
PY
)"

head_commit="$(git -C "$SOURCE_DIR" rev-parse --short HEAD)"
echo "Compiling wine/ at $head_commit (pin is $VERSION)"

rm -rf "$PREFIX"
"$SOURCE_DIR/build/build-engine.sh" "$PREFIX"
printf '%s\n' "$PROVIDER-$head_commit-source" >"$MARKER"
echo "Built Engine $PROVIDER-$head_commit-source → $PREFIX"
