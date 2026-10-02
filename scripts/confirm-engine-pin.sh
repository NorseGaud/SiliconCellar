#!/bin/sh
# Before a release, compare the local Engine pin with the latest NorseGaud/wine release.
# stdout is 0 when they match, and 1 when the user chooses to package the local pin.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MANIFEST="$ROOT/engine/manifest.json"

local_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST")"
repository="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_repository"].removeprefix("https://github.com/"))' "$MANIFEST")"

latest_tag=""
if latest_json="$(curl -fsSL --max-time 20 --proto '=https' "https://api.github.com/repos/$repository/releases/latest")"; then
    latest_tag="$(printf '%s' "$latest_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
fi

if [ -n "$latest_tag" ] && [ "$latest_tag" = "$local_version" ]; then
    echo "Engine pin $local_version is the latest release" >&2
    echo 0
    exit 0
fi

if [ -n "$latest_tag" ]; then
    echo "The latest NorseGaud/wine release is $latest_tag." >&2
else
    echo "Could not read the latest NorseGaud/wine release." >&2
fi
cat >&2 <<EOF
The local Engine pin is $local_version (engine/manifest.json).

To package with the latest Engine, stop and run:
  make engine
Then commit engine/manifest.json and run make release again.
EOF
printf 'Package this release with the local Engine %s anyway? [y/N] ' "$local_version" >&2
if [ ! -r /dev/tty ]; then
    echo "No terminal for the question. Stopped." >&2
    exit 1
fi
read -r answer </dev/tty || exit 1
case "$answer" in
    y | Y | yes | YES)
        echo "Packaging with the local Engine $local_version." >&2
        echo 1
        ;;
    *)
        echo "Stopped. Update the Engine with: make engine" >&2
        exit 1
        ;;
esac
