#!/bin/bash
# Builds Cabin and packages it into a proper macOS .app bundle (with Dock/Finder icon).
set -euo pipefail
cd "$(dirname "$0")"

APP="Cabin"
SRC_ICON="Sources/Cabin/Resources/AppIcon.png"
ICON_COMPOSER="Icon/AppIcon.icon"   # Icon Composer bundle (Liquid Glass); takes precedence
BUILD_CONFIG="${1:-release}"

echo "▶ Building ($BUILD_CONFIG)…"
swift build -c "$BUILD_CONFIG"
BIN="$(swift build -c "$BUILD_CONFIG" --show-bin-path)"

APPDIR="$BIN/$APP.app"
CONTENTS="$APPDIR/Contents"
rm -rf "$APPDIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# --- Generate the app icon ---
# Prefer the Icon Composer bundle (Liquid Glass): actool emits both a rasterized
# AppIcon.icns fallback AND an Assets.car that the OS renders live with the glass
# material (macOS 15+/Tahoe). Info.plist below adds CFBundleIconName for the .car.
ICON_HAS_COMPOSER=0
if [ -d "$ICON_COMPOSER" ]; then
    echo "▶ Compiling Icon Composer icon (Liquid Glass)…"
    xcrun actool "$PWD/$ICON_COMPOSER" \
        --compile "$CONTENTS/Resources" \
        --app-icon AppIcon \
        --output-partial-info-plist "$(mktemp -d)/icon-partial.plist" \
        --platform macosx --minimum-deployment-target 14.0 \
        --errors --warnings >/dev/null
    ICON_HAS_COMPOSER=1
else
    echo "▶ Generating icon from PNG…"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size        "$SRC_ICON" --out "$ICONSET/icon_${size}x${size}.png"      >/dev/null
        sips -z $((size*2)) $((size*2)) "$SRC_ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
fi

# --- Copy the executable and its resource bundle ---
cp "$BIN/$APP" "$CONTENTS/MacOS/$APP"
# SwiftPM emits the bundled resources as <Target>_<Target>.bundle next to the binary.
cp -R "$BIN/${APP}_${APP}.bundle" "$CONTENTS/Resources/" 2>/dev/null || true

# --- Compile Metal shaders (SwiftPM doesn't build .metal in this setup) ---
# Emit default.metallib into the module resource bundle so Bundle.module + ShaderLibrary find it.
METAL_SRC=(Sources/Cabin/*.metal)
if ls "${METAL_SRC[@]}" >/dev/null 2>&1; then
    echo "▶ Compiling Metal shaders…"
    # SwiftPM's macOS resource bundle is FLAT (resources at the bundle root, next to AppIcon.png),
    # so default.metallib must go there for Bundle.module.url(forResource:) to find it.
    MODULE_RES="$CONTENTS/Resources/${APP}_${APP}.bundle"
    mkdir -p "$MODULE_RES"
    AIRS=()
    for m in "${METAL_SRC[@]}"; do
        air="${m##*/}.air"
        xcrun -sdk macosx metal -c "$m" -o "/tmp/$air"
        AIRS+=("/tmp/$air")
    done
    xcrun -sdk macosx metallib "${AIRS[@]}" -o "$MODULE_RES/default.metallib"
fi

# --- Embed Sparkle.framework (auto-update) ---
# swift build copies Sparkle.framework next to the binary; the app finds it via the
# @executable_path/../Frameworks rpath set in Package.swift. make-dmg.sh signs its
# nested XPC/helper components for notarization.
echo "▶ Embedding Sparkle.framework…"
mkdir -p "$CONTENTS/Frameworks"
ditto "$BIN/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"

# AppleScript terminology (OSAScriptingDefinition looks for it directly under Resources).
cp "Sources/Cabin/Resources/Cabin.sdef" "$CONTENTS/Resources/Cabin.sdef"

# --- Info.plist ---
# CFBundleIconName points the OS at the Assets.car icon (Liquid Glass). Only emit it
# when the .car exists, otherwise the icon silently fails to resolve.
ICON_NAME_KEY=""
if [ "$ICON_HAS_COMPOSER" = "1" ]; then
    ICON_NAME_KEY='    <key>CFBundleIconName</key>       <string>AppIcon</string>'
fi
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP</string>
    <key>CFBundleDisplayName</key>     <string>$APP</string>
    <key>CFBundleIdentifier</key>      <string>com.cabin.player</string>
    <key>CFBundleExecutable</key>      <string>$APP</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
$ICON_NAME_KEY
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.09.26.32</string>
    <key>CFBundleVersion</key>         <string>40</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.music</string>
    <key>NSAppleScriptEnabled</key>     <true/>
    <key>OSAScriptingDefinition</key>   <string>Cabin.sdef</string>
    <!-- Sparkle auto-update. Feed lives in the (public) GitHub repo; the DMG is a
         GitHub release asset. Every update is verified against SUPublicEDKey. -->
    <key>SUFeedURL</key>               <string>https://raw.githubusercontent.com/02-alt/bandcamp-player/main/appcast.xml</string>
    <key>SUPublicEDKey</key>           <string>F9r6QZCmbCoizKT7BHR94ZM8e7Hp2OLxs8IJiy7zxOU=</string>
    <key>SUEnableAutomaticChecks</key> <true/>
</dict>
</plist>
PLIST

echo "✓ Built $APPDIR"
echo "  open \"$APPDIR\""
