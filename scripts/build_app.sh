#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT_DIR/src/main.swift"
DIST="$ROOT_DIR/dist"
MODULE_CACHE="$ROOT_DIR/.build/module-cache"
APP_NAME="Bulwark Video Tools"
APP_EXECUTABLE="BulwarkVideoTools"
BUNDLE_ID="com.bulwark.BulwarkVideoTools"
APP="$DIST/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_EXECUTABLE"
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
  <string>$APP_EXECUTABLE</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Media Files</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>public.video</string>
        <string>public.audiovisual-content</string>
      </array>
    </dict>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$BIN"

FFMPEG_SOURCE="${BUNDLED_FFMPEG_PATH:-}"
if [[ -z "$FFMPEG_SOURCE" ]]; then
  for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg /usr/bin/ffmpeg; do
    if [[ -x "$candidate" ]]; then
      FFMPEG_SOURCE="$candidate"
      break
    fi
  done
fi

if [[ -n "$FFMPEG_SOURCE" && -x "$FFMPEG_SOURCE" ]]; then
  cp "$FFMPEG_SOURCE" "$APP_RESOURCES/ffmpeg"
  chmod +x "$APP_RESOURCES/ffmpeg"
  echo "Bundled ffmpeg: $FFMPEG_SOURCE"
else
  echo "ffmpeg not bundled (set BUNDLED_FFMPEG_PATH to include one)."
fi

echo "Built: $APP"
