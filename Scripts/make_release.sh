#!/bin/zsh
# Build, sign (Developer ID), notarize, staple, and zip Squelch for a
# GitHub release.
#
# Prerequisites:
#   - "Developer ID Application: ..." certificate in the login keychain
#   - App Store Connect API key at ~/.appstoreconnect/private_keys
#
# Usage: Scripts/make_release.sh   → dist/Squelch-<version>.zip
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Squelch.app"
DIST="$ROOT/dist"
ENTITLEMENTS="$ROOT/Scripts/Release.entitlements"

API_KEY_ID="${API_KEY_ID:-4983673253}"
API_ISSUER_ID="${API_ISSUER_ID:-4fcc87e2-93c8-4e78-be26-6af70bdf75a9}"
API_KEY_FILE="$HOME/.appstoreconnect/private_keys/AuthKey_${API_KEY_ID}.p8"

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [[ -z "$IDENTITY" ]]; then
    echo "ERROR: no 'Developer ID Application' identity in the keychain." >&2
    echo "Create one: Xcode → Settings → Accounts → Manage Certificates → +" >&2
    exit 1
fi
echo "Signing identity: $IDENTITY"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ROOT/Scripts/Info.plist")
ZIP="$DIST/Squelch-$VERSION.zip"

echo "Building release…"
swift build --package-path "$ROOT" -c release

BIN="$ROOT/.build/release/Squelch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"
cp "$BIN" "$APP/Contents/MacOS/Squelch"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/.build/release/Squelch_Squelch.bundle" "$APP/Contents/Resources/"

ICON_TMP=$(mktemp -d)
swift "$ROOT/Scripts/make_icon.swift" "$ICON_TMP" >/dev/null
iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"

echo "Signing (hardened runtime)…"
codesign --force --sign "$IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    "$APP"
codesign --verify --strict --deep "$APP"

echo "Notarizing (this takes a few minutes)…"
rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
    --key "$API_KEY_FILE" \
    --key-id "$API_KEY_ID" \
    --issuer "$API_ISSUER_ID" \
    --wait

echo "Stapling…"
xcrun stapler staple "$APP"

# Re-zip with the stapled ticket inside
rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"

echo "Gatekeeper check:"
spctl --assess --type execute -vv "$APP"

echo "Release artifact: $ZIP"
