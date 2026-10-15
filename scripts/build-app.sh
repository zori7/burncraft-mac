#!/bin/bash
# Builds build/<APP_NAME>.app from the Swift package, using names from app.config.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/app.config"

"$ROOT/scripts/gen-config.sh"

swift build -c release --package-path "$ROOT" --product App
BIN_DIR="$(swift build -c release --package-path "$ROOT" --show-bin-path)"

APP="$ROOT/build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/App" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
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
echo "Built $APP"
