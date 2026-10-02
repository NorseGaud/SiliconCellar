#!/bin/sh
# Publish the next Wine Engine tag from the wine/ submodule, then record that commit here.
#
# 1. Push the wine siliconcellar branch.
# 2. Create and push the next sc-<crossover>-<n> tag. That starts the Engine build.
# 3. Commit and push the submodule pointer in this repo.
#
# Commit the Wine edits in wine/ before you run this. The script does not write that commit.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
WINE="$ROOT/wine"

if [ ! -e "$WINE/.git" ]; then
    echo "Missing wine submodule. Run: git submodule update --init wine" >&2
    exit 1
fi

if [ -n "$(git -C "$WINE" status --porcelain)" ]; then
    echo "wine/ has uncommitted changes. Commit them in wine/ first." >&2
    exit 1
fi

branch="$(git -C "$WINE" rev-parse --abbrev-ref HEAD)"
if [ "$branch" != "siliconcellar" ]; then
    echo "wine/ is on $branch. Check out siliconcellar first." >&2
    exit 1
fi

echo "Fetching NorseGaud/wine…"
git -C "$WINE" fetch origin siliconcellar --tags --quiet

if ! git -C "$WINE" merge-base --is-ancestor HEAD origin/siliconcellar; then
    echo "Pushing wine siliconcellar…"
    git -C "$WINE" push origin HEAD:siliconcellar
else
    echo "wine siliconcellar is already pushed."
fi

existing_tag="$(git -C "$WINE" tag --points-at HEAD 'sc-*' | awk 'NR==1')"
if [ -n "$existing_tag" ]; then
    tag="$existing_tag"
    echo "This Wine commit already has tag $tag."
else
    tag="$(
        python3 - "$WINE/build/deps.json" <<'PY'
import json, re, subprocess, sys
crossover = json.load(open(sys.argv[1]))["crossover"]["version"]
pattern = re.compile(rf"sc-{re.escape(crossover)}-(\d+)$")
tags = subprocess.check_output(["git", "-C", "wine", "tag", "-l", f"sc-{crossover}-*"], text=True).split()
numbers = []
for tag in tags:
    match = pattern.match(tag)
    if match:
        numbers.append(int(match.group(1)))
print(f"sc-{crossover}-{(max(numbers) + 1) if numbers else 1}")
PY
    )"
    echo "Tagging $tag…"
    git -C "$WINE" tag "$tag"
    git -C "$WINE" push origin "$tag"
fi

git add .gitmodules wine
if git diff --cached --quiet -- .gitmodules wine; then
    echo "Silicon Cellar already records this Wine commit."
else
    git commit -m "Point the Wine submodule at $tag." -- .gitmodules wine
    git push origin HEAD
fi

cat <<EOF

Pushed Wine tag $tag.
The Engine build runs on GitHub and takes about 1 to 2 hours.
Watch https://github.com/NorseGaud/wine/actions
A green run on $tag publishes the release. A run on the siliconcellar branch does not.

When that release exists:
  4. make engine
  5. make engine-pin
  6. make release
EOF
