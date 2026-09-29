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
    # 1) Ask wineserver to end the whole prefix (best clean stop).
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
    # 2) Force-kill leftovers. After wineserver dies, Steam often stays as ppid-1
    #    orphans whose argv looks like Windows paths (no Engine path in the string).
    kill_matching_pids() {
        signal="$1"
        ps -ax -o pid=,command= 2>/dev/null | awk '
            /SiliconCellar\/prefix/ { print $1; next }
            /SiliconCellar\.app\/Contents\/Resources\/Engine/ { print $1; next }
            /\.build\/engine\/(bin|lib)\// { print $1; next }
            /steam\.exe -nofriendsui -nochatui -noverifyfiles/ { print $1; next }
            /steamwebhelper(-valve)?\.exe/ { print $1; next }
            /winedevice\.exe/ { print $1; next }
        ' | while IFS= read -r kill_pid; do
            [ -n "$kill_pid" ] || continue
            kill "-$signal" "$kill_pid" 2>/dev/null || true
        done
    }
    kill_matching_pids TERM
    sleep 0.8
    kill_matching_pids KILL
    sleep 0.3
}

# Restart app only — keep Wine/Steam alive across file-change rebuilds.
stop_app() {
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    pid=""
}

stop_all() {
    stop_app
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

copy_engine() {
    ENGINE_SRC="$ROOT/.build/engine"
    if [ ! -x "$ENGINE_SRC/bin/wine" ]; then
        return 0
    fi
    rm -rf "$DEV_APP/Contents/Resources/Engine"
    mkdir -p "$DEV_APP/Contents/Resources/Engine"
    if ! cp -R "$ENGINE_SRC"/. "$DEV_APP/Contents/Resources/Engine"/; then
        echo "Could not copy Engine into the app bundle (is Wine still running?)."
        return 1
    fi
    return 0
}

# Usage: start_app first | reload
# first  — kill Wine/Steam leftovers, copy Engine, launch
# reload — keep Wine/Steam, refresh app binary only
start_app() {
    mode="${1:-reload}"
    echo "Building SiliconCellar…"
    if ! build_app; then
        echo "Build failed. The last window stays open if it is still running."
        return 0
    fi
    stop_app
    if [ "$mode" = "first" ]; then
        stop_wine
    fi
    write_app_bundle "$DEV_APP" "$(swift build --show-bin-path)/SiliconCellar" com.norsegaud.siliconcellar.dev
    if [ $? -ne 0 ]; then
        echo "Could not write $DEV_APP."
        return 0
    fi
    if [ "$mode" = "first" ] || [ ! -x "$DEV_APP/Contents/Resources/Engine/bin/wine" ]; then
        if [ "$mode" != "first" ]; then
            # Engine missing mid-session — must stop Wine to replace it safely.
            stop_wine
        fi
        if ! copy_engine; then
            return 0
        fi
    fi
    echo "Launching $DEV_APP"
    "$DEV_APP/Contents/MacOS/SiliconCellar" &
    pid=$!
}

trap 'stop_all; exit 0' INT TERM

start_app first
stamp="$(source_stamp)"
echo "Watching Sources for changes. Ctrl+C stops."
while true; do
    sleep 1
    now="$(source_stamp)"
    if [ "$now" != "$stamp" ]; then
        echo "Files changed. Waiting 5s for edits to settle…"
        sleep 5
        stamp="$(wait_until_stable)"
        start_app reload
    fi
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        echo "The app exited. Waiting for the next file change."
        pid=""
    fi
done
