#!/bin/sh
# Commit and push engine/manifest.json after `make engine` moved it to a new release.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
MANIFEST="engine/manifest.json"

if git diff --quiet -- "$MANIFEST" && git diff --cached --quiet -- "$MANIFEST"; then
    echo "$MANIFEST matches HEAD. Run make engine after the Wine release exists." >&2
    exit 1
fi

version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST")"
git commit -m "Pin the Wine Engine to $version." -- "$MANIFEST"
git push origin HEAD
echo "Pushed the Engine pin $version. Next: make release"
