#!/bin/sh
# Upload a notarized DMG to a draft GitHub release, then update the Homebrew cask.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

usage='usage: publish-release.sh check VERSION | publish VERSION BUILD PATH/to/SiliconCellar.dmg'
mode="${1:?$usage}"
version="${2:?$usage}"
release_repo="${RELEASE_REPO:-NorseGaud/SiliconCellar}"
. "$ROOT/scripts/homebrew-tap.sh"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# Prints draft, published, or missing.
release_state() {
    is_draft="$(gh release view "$version" -R "$release_repo" --json isDraft --jq .isDraft 2>/dev/null)" || {
        echo missing
        return
    }
    if [ "$is_draft" = "true" ]; then echo draft; else echo published; fi
}

check_release_preconditions() {
    command -v gh >/dev/null || fail "gh is not installed"
    gh auth status >/dev/null 2>&1 || fail "gh is not signed in; run gh auth login"
    test -f "$cask_file" || fail "missing cask: $cask_file (run git submodule update --init homebrew-siliconcellar, or set HOMEBREW_TAP_DIR)"
    # The cask is not in the DMG, and each release edits it before its commit.
    [ -z "$(git status --porcelain -- . ':(exclude)homebrew-siliconcellar')" ] || fail "working tree has uncommitted changes; commit them so the release matches the DMG"
    # GitHub releases own the version tags, so a stale local tag must not stop the check.
    git fetch origin --tags --force --quiet
    [ -n "$(git branch -r --contains HEAD)" ] || fail "HEAD is not pushed to origin; push it first"
    [ "$(release_state)" != "published" ] || fail "release $version is already published; bump VERSION"
}

write_release_notes() {
    notes_file="$1"
    previous_tag="$(gh release list -R "$release_repo" --exclude-drafts --exclude-pre-releases --limit 1 --json tagName --jq '.[0].tagName // empty')"
    {
        echo "## Changes"
        echo
        if [ -n "$previous_tag" ]; then
            git log "${previous_tag}..HEAD" --no-merges --format='- %s (%h)'
        else
            git log --no-merges --format='- %s (%h)'
        fi
        echo
        echo "## Install"
        echo
        echo '```sh'
        echo "brew install --cask norsegaud/siliconcellar/siliconcellar"
        echo '```'
    } >"$notes_file"
}

remove_old_dmg_assets() {
    gh release view "$version" -R "$release_repo" --json assets --jq '.assets[].name' |
        while read -r asset_name; do
            case "$asset_name" in
                SiliconCellar-"$version"-*.dmg)
                    echo "Deleting old asset $asset_name"
                    gh release delete-asset "$version" "$asset_name" -R "$release_repo" --yes
                    ;;
            esac
        done
}

publish_draft_release() {
    build="${3:?$usage}"
    dmg="${4:?$usage}"
    test -f "$dmg" || fail "missing DMG: $dmg"
    check_release_preconditions

    head_sha="$(git rev-parse HEAD)"
    notes_file="$(mktemp "${TMPDIR:-/tmp}/siliconcellar-notes.XXXXXX")"
    trap 'rm -f "$notes_file"' EXIT
    write_release_notes "$notes_file"

    if [ "$(release_state)" = "draft" ]; then
        gh release edit "$version" -R "$release_repo" --draft --title "$version" --target "$head_sha" --notes-file "$notes_file"
        remove_old_dmg_assets
    else
        gh release create "$version" -R "$release_repo" --draft --title "$version" --target "$head_sha" --notes-file "$notes_file"
    fi
    gh release upload "$version" "$dmg" -R "$release_repo" --clobber

    "$ROOT/scripts/update-cask.sh" "$version" "$build" "$dmg"

    draft_url="$(gh release view "$version" -R "$release_repo" --json url --jq .url)"
    cat <<EOF

Draft release: $draft_url
Next:
  1. Download the DMG from the draft and test it.
  2. Publish the release and set it as latest.
  3. Commit and push $cask_file (${homebrew_tap_repo}).
  4. Commit and push the homebrew-siliconcellar submodule pointer here.
EOF
}

case "$mode" in
    check) check_release_preconditions ;;
    publish) publish_draft_release "$@" ;;
    *) fail "$usage" ;;
esac
