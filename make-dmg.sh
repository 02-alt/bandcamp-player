#!/bin/bash
# Builds Yoin.app (via package.sh), re-signs it with a Developer ID + hardened
# runtime, notarizes it, staples the ticket, and packages a notarized,
# drag-to-Applications .dmg. Output: ./Yoin.dmg
#
# Requires (one-time, already done on this Mac):
#   - "Developer ID Application" cert in the keychain.
#   - notarytool profile "yoin-notary":
#       xcrun notarytool store-credentials "yoin-notary" \
#         --apple-id "matthieu.coma@pm.me" --team-id "JLR4F273N8" --password "<app-specific-pw>"
#
# Set SKIP_NOTARIZE=1 to sign + package only (quick local build).
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-yoin-notary}"
ENTITLEMENTS="Yoin.entitlements"
VOL="Yoin"
DMG="Yoin.dmg"

# Build the .app bundle (release; produces Yoin.app in the SwiftPM bin dir).
./package.sh release
BIN="$(swift build -c release --show-bin-path)"
APP="$BIN/Yoin.app"

echo "▸ Signing Sparkle.framework helpers (inside-out)…"
# Sparkle ships nested Mach-O helpers (XPC services, Autoupdate, Updater.app) that
# each need their own Developer ID + hardened-runtime signature for notarization.
# Sign them before the framework, and the framework before the app (codesign does
# not deep-sign by default). The B version is the only concrete one; the top-level
# names are symlinks into it.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/XPCServices/Installer.xpc"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/XPCServices/Downloader.xpc"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Autoupdate"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE/Updater.app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"

echo "▸ Signing with Developer ID (hardened runtime)…"
# Yoin_Yoin.bundle is a flat resource-only bundle (no Mach-O) — it gets sealed
# as a resource when the app is signed, so we sign only the .app itself.
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo "▸ Notarizing app (a few minutes)…"
    ZIP="Yoin-notarize.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$ZIP"
    echo "▸ Stapling app…"
    xcrun stapler staple "$APP"
fi

echo "▸ Packaging ${DMG}…"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo "▸ Signing + notarizing the DMG…"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "▸ Verifying Gatekeeper acceptance…"
    spctl -a -t open --context context:primary-signature -vv "$DMG" || true
fi

echo "✓ Built $DMG"
