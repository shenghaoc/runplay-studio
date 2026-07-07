#!/bin/bash
# package-demo.sh — Create a macOS .app bundle from SwiftPM release build.
#
# Usage:
#   ./scripts/package-demo.sh [output-dir]
#
# Produces:
#   <output-dir>/RunPlayStudio.app   (unsigned, not notarized)
#   <output-dir>/RunPlayStudio.app.zip
#
# Requirements:
#   - macOS 14.0+
#   - Xcode 15.0+ (Swift 5.9)
#
# This script is intended for CI demo artifact packaging only.
# The resulting .app is unsigned and not notarized — for demo/testing only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$REPO_ROOT/.build/artifacts}"

APP_NAME="RunPlayStudio"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
BINARY="$REPO_ROOT/.build/release/$APP_NAME"

echo "==> Building release binary..."
swift build -c release --package-path "$REPO_ROOT"

if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: Release binary not found at $BINARY" >&2
    exit 1
fi

echo "==> Creating app bundle at $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy resources bundled by SwiftPM
RESOURCES_DIR="$REPO_ROOT/RunPlayStudio/Resources"
if [[ -d "$RESOURCES_DIR" ]]; then
    cp -R "$RESOURCES_DIR/"* "$APP_BUNDLE/Contents/Resources/"
fi

# Write Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.shenghaoc.runplay-studio</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Create zip for artifact upload
echo "==> Creating zip archive..."
(cd "$OUTPUT_DIR" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME.app.zip")

echo "==> Done!"
echo "    App bundle: $APP_BUNDLE"
echo "    Zip archive: $OUTPUT_DIR/$APP_NAME.app.zip"
