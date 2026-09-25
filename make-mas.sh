#!/bin/bash
# Builds the Mac App Store flavor of Cabin (sandboxed, no Sparkle, no iPod sync).
#
#   ./make-mas.sh --test   sandboxed .app, ad-hoc signed without iCloud — run it locally to find
#                          anything the sandbox breaks (no profile or store certificate needed)
#   ./make-mas.sh          signed Cabin.pkg for App Store Connect (needs the Mac App Store
#                          provisioning profile + "3rd Party Mac Developer Installer" cert)
#
# The DMG / Sparkle build (make-dmg.sh) is untouched: same code, different flavor.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-store}"
CABIN_APPSTORE=1 ./package.sh release
APP="$(swift build -c release --build-path .build-mas --show-bin-path)/Cabin.app"

if [ "$MODE" = "--test" ]; then
    echo "▸ Ad-hoc signing with the sandbox (test entitlements)…"
    codesign --force --options runtime --sign - --entitlements Cabin-MAS-test.entitlements "$APP"
    codesign -d --entitlements - "$APP" 2>/dev/null | grep -q app-sandbox && echo "✓ Sandboxed test build: $APP"
    exit 0
fi

APP_ID="${MAS_APP_IDENTITY:-Apple Distribution: MATTHIEU FRANCOIS MILO COMALADA (JLR4F273N8)}"
PKG_ID="${MAS_PKG_IDENTITY:-3rd Party Mac Developer Installer: MATTHIEU FRANCOIS MILO COMALADA (JLR4F273N8)}"
PROFILE="${MAS_PROFILE:-Cabin_MacAppStore.provisionprofile}"
[ -f "$PROFILE" ] || { echo "✗ Missing $PROFILE (Mac App Store profile for com.cabin.player, iCloud on)"; exit 1; }

echo "▸ Signing for the Mac App Store…"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
codesign --force --timestamp --sign "$APP_ID" --entitlements Cabin-MAS.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▸ Packaging Cabin.pkg…"
rm -f Cabin.pkg
productbuild --component "$APP" /Applications --sign "$PKG_ID" Cabin.pkg
echo "✓ Built Cabin.pkg — upload: xcrun altool --upload-app -t macos -f Cabin.pkg --apiKey … --apiIssuer …"
