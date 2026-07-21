#!/bin/zsh
# Build RadioFun.app from the SwiftPM executable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/RadioFun.app"

echo "Building ($CONFIG)…"
swift build --package-path "$ROOT" -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/RadioFun"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RadioFun"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"

# App icon: rendered from the script so it's always regenerable
ICON_TMP=$(mktemp -d)
swift "$ROOT/Scripts/make_icon.swift" "$ICON_TMP" >/dev/null
iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"

# Ad-hoc signature so TCC (mic/location) prompts are attributed to the app
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Launch with: open \"$APP\""
