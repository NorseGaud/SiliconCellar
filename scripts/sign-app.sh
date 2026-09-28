#!/bin/sh
# Sign SiliconCellar.app for Developer ID notarization (nested Engine Mach-O first).
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP="${1:?usage: sign-app.sh PATH/to/SiliconCellar.app}"
IDENTITY="${CODESIGN_IDENTITY:?CODESIGN_IDENTITY is required}"
ENTITLEMENTS="$ROOT/scripts/wine-engine.entitlements"

test -d "$APP"
test -f "$ENTITLEMENTS"

ENGINE="$APP/Contents/Resources/Engine"
if [ -d "$ENGINE" ]; then
    echo "Signing Wine Engine Mach-O under ${ENGINE}..."
    # Every Mach-O (wine, wineserver, *.so, tools), then the app binaries.
    find "$ENGINE" -type f -exec sh -c '
        identity="$1"
        entitlements="$2"
        shift 2
        for path in "$@"; do
            case "$(file -b "$path" 2>/dev/null || true)" in
                *Mach-O*)
                    codesign --force --options runtime --timestamp \
                        --entitlements "$entitlements" \
                        --sign "$identity" \
                        "$path"
                    ;;
            esac
        done
    ' sh "$IDENTITY" "$ENTITLEMENTS" {} +
fi

echo "Signing app binaries…"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "$APP/Contents/MacOS/siliconcellar-cli"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "$APP/Contents/MacOS/SiliconCellar"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signed $APP"
