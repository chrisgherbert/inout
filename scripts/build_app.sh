#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT_DIR/src/main.swift"
DIST="$ROOT_DIR/dist"
MODULE_CACHE="$ROOT_DIR/.build/module-cache"
APP_NAME="CheckBlackFrames"
APP="$DIST/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"
PLIST="$APP/Contents/Info.plist"
APP_RESOURCES="$APP/Contents/Resources"

mkdir -p "$DIST"
mkdir -p "$MODULE_CACHE"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP_RESOURCES"

swiftc \
  -O \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreVideo \
  -framework CoreMedia \
  -framework Foundation \
  "$SRC" \
  -o "$BIN"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.bulwark.$APP_NAME</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$BIN"

echo "Built: $APP"
