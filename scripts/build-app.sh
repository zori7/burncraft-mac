#!/bin/bash
# Builds build/<APP_NAME>.app (universal: Apple Silicon + Intel) plus release
# build/<APP_NAME>-<VERSION>.zip and .dmg, using names from app.config.
# Requires create-dmg (brew install create-dmg).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/app.config"

"$ROOT/scripts/gen-config.sh"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --package-path "$ROOT" "${ARCHS[@]}" --product App
BIN_DIR="$(swift build -c release --package-path "$ROOT" "${ARCHS[@]}" --show-bin-path)"

APP="$ROOT/build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/App" "$APP/Contents/MacOS/$APP_NAME"

# App icon: Resources/AppIcon.png (1024x1024, transparent) -> AppIcon.icns.
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSDesktopFolderUsageDescription</key><string>$APP_NAME reads the folders you choose to archive.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>$APP_NAME reads the folders you choose to archive.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>$APP_NAME reads the folders you choose to archive.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>$APP_NAME reads and writes archives on external drives and discs.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"

# ditto keeps the bundle structure and signature intact (plain zip can break them).
ZIP="$ROOT/build/$APP_NAME-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Packaged $ZIP"

# Drag-to-Applications disk image (brew install create-dmg).
DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"
STAGE="$ROOT/build/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
create-dmg \
    --volname "$APP_NAME" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --window-size 540 380 \
    --icon-size 128 \
    --icon "$APP_NAME.app" 140 180 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 400 180 \
    "$DMG" "$STAGE"
rm -rf "$STAGE"
codesign --force --sign - "$DMG"
echo "Packaged $DMG"
