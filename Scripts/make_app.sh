#!/bin/zsh
# Build Squelch.app from the SwiftPM executable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/Squelch.app"

echo "Building ($CONFIG)…"
swift build --package-path "$ROOT" -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/Squelch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Squelch"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"

# SwiftPM resource bundle (offline basemap, etc.) — Bundle.module looks in
# the main bundle's Resources
cp -R "$ROOT/.build/$CONFIG/Squelch_Squelch.bundle" "$APP/Contents/Resources/"

# App icon: rendered from the script so it's always regenerable
ICON_TMP=$(mktemp -d)
swift "$ROOT/Scripts/make_icon.swift" "$ICON_TMP" >/dev/null
iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"

# Ad-hoc signature so TCC (mic/location) prompts are attributed to the app.
# SANDBOX=1 applies the App Store entitlements — for smoke-testing that
# audio/serial/CAT survive the sandbox before a TestFlight upload.
if [[ "${SANDBOX:-0}" == "1" ]]; then
    codesign --force --sign - --entitlements "$ROOT/Scripts/Squelch.entitlements" "$APP"
    echo "Signed SANDBOXED (App Store entitlements)"
else
    codesign --force --sign - "$APP"
fi

echo "Built $APP"
echo "Launch with: open \"$APP\""
