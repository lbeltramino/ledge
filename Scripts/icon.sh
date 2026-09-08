#!/bin/bash
# Renders the app icon at every size macOS asks for and packs it into an .icns.
#
# Drawn by the app itself, from the same palette as the deck, so the icon cannot
# drift away from the thing it stands for.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Ledge.app}"
[ -x "$APP/Contents/MacOS/Ledge" ] || { echo "build first: ./Scripts/bundle.sh"; exit 1; }

SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
"$APP/Contents/MacOS/Ledge" --render-icon "$SET" > /dev/null

mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "built Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
