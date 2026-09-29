#!/bin/sh
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/app-bundle.sh"

DEV_APP="$ROOT/.build/dev/SiliconCellar.app"
PREFIX="${HOME}/Library/Application Support/SiliconCellar/prefix"
pid=""

stop_wine() {
    echo "Stopping Wine / Steam session…"
    # wineserver -k can Abort (trap 6) when Engine libs are mid-replace or already dying.
    # Kill by path instead — Wine keeps Engine dylibs open after the app exits.
    pkill -TERM -f "SiliconCellar[.]app/Contents/Resources/Engine/.*/wineserver" 2>/dev/null || true
    pkill -TERM -f "[.]build/engine/bin/wineserver" 2>/dev/null || true
    # Give processes time to drop file locks before we replace Engine.
    sleep 0.8
    pkill -KILL -f "SiliconCellar[.]app/Contents/Resources/Engine/.*/wineserver" 2>/dev/null || true
    pkill -KILL -f "[.]build/engine/bin/wineserver" 2>/dev/null || true
    # Best-effort clean stop when the binary and libs are still intact.
    wineserver=""
    engine_lib=""
    if [ -x "$DEV_APP/Contents/Resources/Engine/bin/wineserver" ]; then
        wineserver="$DEV_APP/Contents/Resources/Engine/bin/wineserver"
        engine_lib="$DEV_APP/Contents/Resources/Engine/lib"
    elif [ -x "$ROOT/.build/engine/bin/wineserver" ]; then
        wineserver="$ROOT/.build/engine/bin/wineserver"
        engine_lib="$ROOT/.build/engine/lib"
    fi
    if [ -n "$wineserver" ] && [ -d "$PREFIX" ]; then
        DYLD_FALLBACK_LIBRARY_PATH="$engine_lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}" \
            WINEPREFIX="$PREFIX" "$wineserver" -k >/dev/null 2>&1 || true
    fi
}

stop_app() {
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    pid=""
    # Wine keeps Engine dylibs open after the app exits — stop it before we replace Engine.
    stop_wine
}

source_stamp() {
    find Sources Package.swift Recipes -type f \( -name '*.swift' -o -name '*.json' -o -name '*.png' \) \
        -exec stat -f '%m %N' {} + 2>/dev/null | sort | shasum | awk '{print $1}'
}

wait_until_stable() {
    current="$(source_stamp)"
    while true; do
        sleep 0.5
        next="$(source_stamp)"
        if [ "$next" = "$current" ]; then
            printf '%s\n' "$current"
            return 0
        fi
        echo "Still writing. Waiting…"
        current="$next"
    done
}

build_app() {
    attempt=1
    while [ "$attempt" -le 6 ]; do
        if swift build --product SiliconCellar; then
            return 0
        fi
        echo "Build did not finish. Retrying ($attempt/6)…"
        sleep 0.6
        attempt=$((attempt + 1))
    done
    return 1
}

start_app() {
    echo "Building SiliconCellar…"
    if ! build_app; then
        echo "Build failed. The last window stays open if it is still running."
        return 0
    fi
    stop_app
    write_app_bundle "$DEV_APP" "$(swift build --show-bin-path)/SiliconCellar" com.norsegaud.siliconcellar.dev
    if [ $? -ne 0 ]; then
        echo "Could not write $DEV_APP."
        return 0
    fi
    ENGINE_SRC="$ROOT/.build/engine"
    if [ -x "$ENGINE_SRC/bin/wine" ]; then
        # stop_app already killed Wine; replace Engine without "Operation not permitted".
        rm -rf "$DEV_APP/Contents/Resources/Engine"
        mkdir -p "$DEV_APP/Contents/Resources/Engine"
        if ! cp -R "$ENGINE_SRC"/. "$DEV_APP/Contents/Resources/Engine"/; then
            echo "Could not copy Engine into the app bundle (is Wine still running?)."
            return 0
        fi
    fi
    echo "Launching $DEV_APP"
    "$DEV_APP/Contents/MacOS/SiliconCellar" &
    pid=$!
}

trap 'stop_app; exit 0' INT TERM

start_app
stamp="$(source_stamp)"
echo "Watching Sources for changes. Ctrl+C stops."
while true; do
    sleep 1
    now="$(source_stamp)"
    if [ "$now" != "$stamp" ]; then
        echo "Files changed. Waiting 5s for edits to settle…"
        sleep 5
        stamp="$(wait_until_stable)"
        start_app
    fi
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        echo "The app exited. Waiting for the next file change."
        pid=""
    fi
done
