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

# Ad-hoc signature so TCC (mic/location) prompts are attributed to the app
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Launch with: open \"$APP\""
