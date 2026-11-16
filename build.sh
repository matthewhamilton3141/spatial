#!/bin/sh
# Builds Spatial.app. Needs only the Command Line Tools (no Xcode).
#   ./build.sh          build
#   ./build.sh run      build and open
set -e
cd "$(dirname "$0")"

swift build -c release

# App icon, drawn by the same code as the menu bar glyph (Icon.swift).
# Rebuilt only when the drawing code changes.
ICNS=build/Spatial.icns
if [ ! -f "$ICNS" ] || [ Sources/SpatialApp/Icon.swift -nt "$ICNS" ] || [ scripts/make-icon/main.swift -nt "$ICNS" ]; then
    mkdir -p build .build
    swiftc -O scripts/make-icon/main.swift Sources/SpatialApp/Icon.swift -o .build/make-icon
    rm -rf build/Spatial.iconset
    .build/make-icon iconset build/Spatial.iconset
    iconutil -c icns build/Spatial.iconset -o "$ICNS"
    rm -rf build/Spatial.iconset
fi

APP=build/Spatial.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Spatial "$APP/Contents/MacOS/Spatial"
cp "$ICNS" "$APP/Contents/Resources/Spatial.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Spatial</string>
    <key>CFBundleIdentifier</key><string>local.spatial</string>
    <key>CFBundleExecutable</key><string>Spatial</string>
    <key>CFBundleIconFile</key><string>Spatial</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Spatial reroutes Spotify's sound through Apple's spatial audio renderer. Nothing is recorded or sent anywhere.</string>
    <key>NSMotionUsageDescription</key>
    <string>Spatial reads your AirPods' head movement so the music stays in place when you turn your head.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"

if [ "$1" = "run" ]; then open "$APP"; fi
