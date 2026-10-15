#!/bin/bash
# Regenerates Sources/BurnCore/AppConfig.swift from app.config.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/app.config"

cat > "$ROOT/Sources/BurnCore/AppConfig.swift" <<SWIFT
// Generated from app.config by scripts/gen-config.sh. Edit app.config, not this file.
enum AppConfig {
    static let name = "$APP_NAME"
    static let bundleID = "$BUNDLE_ID"
    static let version = "$VERSION"
}
SWIFT
echo "Generated AppConfig.swift ($APP_NAME, $BUNDLE_ID, $VERSION)"
