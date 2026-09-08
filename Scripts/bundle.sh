#!/bin/bash
# Builds Ledge.app. No Xcode required — SwiftPM produces the binary and we
# assemble the bundle by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
VERSION="${LEDGE_VERSION:-0.1.0}"
APP="build/Ledge.app"

swift build -c "$CONFIG" --product LedgeApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/LedgeApp" "$APP/Contents/MacOS/Ledge"

# Bundled note face, if it has been fetched. Typography falls back gracefully.
if [ -d Resources/Fonts ]; then
  cp Resources/Fonts/*.ttf "$APP/Contents/Resources/" 2>/dev/null || true
  cp Resources/Fonts/OFL.txt "$APP/Contents/Resources/" 2>/dev/null || true
fi

FONTS=""
for f in "$APP/Contents/Resources/"*.ttf; do
  [ -e "$f" ] || continue
  FONTS="$FONTS        <string>$(basename "$f")</string>\n"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Ledge</string>
    <key>CFBundleDisplayName</key><string>Ledge</string>
    <key>CFBundleIdentifier</key><string>com.lisandro.Ledge</string>
    <key>CFBundleExecutable</key><string>Ledge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <!-- No Dock icon, no menu bar. The deck is the whole interface. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
$(if [ -n "$FONTS" ]; then printf '    <key>ATSApplicationFontsPath</key><string>.</string>\n'; fi)
</dict>
</plist>
PLIST

echo "built $APP"
