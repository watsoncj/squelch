#!/bin/zsh
# Build, sign, and package Squelch for TestFlight (Mac App Store pipeline).
#
# Prerequisites (one-time, scripted via App Store Connect API elsewhere):
#   - "Apple Distribution: ..." certificate in the login keychain
#   - "3rd Party Mac Developer Installer: ..." certificate in the keychain
#   - Mac App Store provisioning profile at Scripts/Squelch_MAS.provisionprofile
#   - API key in ~/.appstoreconnect/private_keys (used by the upload step)
#
# Usage:
#   Scripts/make_pkg.sh                # build + sign + pkg
#   UPLOAD=1 API_KEY_ID=XXXX API_ISSUER_ID=uuid Scripts/make_pkg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Squelch.app"
PKG="$ROOT/Squelch.pkg"
PROFILE="$ROOT/Scripts/Squelch_MAS.provisionprofile"
ENTITLEMENTS="$ROOT/Scripts/Squelch.entitlements"

DIST_ID="${DIST_ID:-Apple Distribution}"
INSTALLER_ID="${INSTALLER_ID:-3rd Party Mac Developer Installer}"

echo "Building release…"
swift build --package-path "$ROOT" -c release

BIN="$ROOT/.build/release/Squelch"

rm -rf "$APP" "$PKG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Squelch"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/.build/release/Squelch_Squelch.bundle" "$APP/Contents/Resources/"

ICON_TMP=$(mktemp -d)
swift "$ROOT/Scripts/make_icon.swift" "$ICON_TMP" >/dev/null
iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"

if [[ ! -f "$PROFILE" ]]; then
    echo "ERROR: missing provisioning profile at $PROFILE" >&2
    exit 1
fi
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

echo "Signing with '$DIST_ID'…"
codesign --force --sign "$DIST_ID" \
    --entitlements "$ENTITLEMENTS" \
    "$APP"

echo "Building installer package…"
productbuild --component "$APP" /Applications \
    --sign "$INSTALLER_ID" \
    "$PKG"

echo "Built $PKG"

if [[ "${UPLOAD:-0}" == "1" ]]; then
    : "${API_KEY_ID:?set API_KEY_ID}" "${API_ISSUER_ID:?set API_ISSUER_ID}"
    echo "Uploading to App Store Connect…"
    xcrun iTMSTransporter -m upload \
        -assetFile "$PKG" \
        -apiKey "$API_KEY_ID" \
        -apiIssuer "$API_ISSUER_ID" \
        -v informational
fi
