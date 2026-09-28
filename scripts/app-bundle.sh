# Sourced by package-app.sh and dev.sh. The caller sets ROOT.
# Functions run in a subshell with set -e. Call them as plain commands, not in if/||/&&, or set -e is ignored.

ICON_MASTER="$ROOT/Sources/SiliconCellarApp/Resources/AppIcon.png"
ICON_CACHE="$ROOT/.build/AppIcon.icns"

build_app_icon() (
    set -e
    if [ "$ICON_CACHE" -nt "$ICON_MASTER" ]; then exit 0; fi
    iconset="$ROOT/.build/AppIcon.iconset"
    rm -rf "$iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_MASTER" --out "$iconset/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$ICON_MASTER" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$ICON_CACHE"
    rm -rf "$iconset"
)

# write_app_bundle APP_PATH EXECUTABLE BUNDLE_IDENTIFIER [VERSION] [BUILD]
write_app_bundle() (
    set -e
    app="$1"
    executable="$2"
    bundle_identifier="$3"
    short_version="${4:-0.1.0}"
    bundle_version="${5:-1}"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$executable" "$app/Contents/MacOS/SiliconCellar"
    build_app_icon
    cp "$ICON_CACHE" "$app/Contents/Resources/AppIcon.icns"
    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>Silicon Cellar</string>
	<key>CFBundleExecutable</key>
	<string>SiliconCellar</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$bundle_identifier</string>
	<key>CFBundleName</key>
	<string>Silicon Cellar</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$short_version</string>
	<key>CFBundleVersion</key>
	<string>$bundle_version</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF
)
