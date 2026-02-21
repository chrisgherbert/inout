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
ICON_SOURCE_PNG="$ROOT_DIR/assets/AppIcon-1024.png"
ICON_BASE_NAME="AppIcon"
ICON_ICNS_NAME="${ICON_BASE_NAME}.icns"
ICON_PNG_NAME="${ICON_BASE_NAME}.png"
ICON_ICNS_PATH="$APP_RESOURCES/$ICON_ICNS_NAME"
ICON_PNG_PATH="$APP_RESOURCES/$ICON_PNG_NAME"

mkdir -p "$DIST"
mkdir -p "$MODULE_CACHE"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP_RESOURCES"
mkdir -p "$ROOT_DIR/assets"

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
  <key>CFBundleIconFile</key>
  <string>${ICON_BASE_NAME}</string>
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

if [[ -f "$ICON_SOURCE_PNG" ]]; then
  ICONSET_DIR="$DIST/AppIcon.iconset"
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  /usr/bin/sips -z 16 16 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  /usr/bin/sips -z 32 32 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  /usr/bin/sips -z 32 32 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  /usr/bin/sips -z 64 64 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  /usr/bin/sips -z 128 128 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  /usr/bin/sips -z 256 256 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  /usr/bin/sips -z 256 256 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  /usr/bin/sips -z 512 512 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  /usr/bin/sips -z 512 512 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  /usr/bin/sips -z 1024 1024 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

  if /usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS_PATH"; then
    echo "Bundled app icon (.icns): $ICON_SOURCE_PNG"
  else
    cp "$ICON_SOURCE_PNG" "$ICON_PNG_PATH"
    echo "iconutil failed; bundled PNG fallback icon: $ICON_SOURCE_PNG"
  fi
  rm -rf "$ICONSET_DIR"
else
  echo "App icon not bundled (missing $ICON_SOURCE_PNG)."
fi

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

WHISPER_SOURCE="${BUNDLED_WHISPER_PATH:-}"
if [[ -z "$WHISPER_SOURCE" ]]; then
  local_vendor_nocoreml="$ROOT_DIR/vendor/whisper.cpp/build-bvt-nocoreml/bin/whisper-cli"
  if [[ -x "$local_vendor_nocoreml" ]]; then
    WHISPER_SOURCE="$local_vendor_nocoreml"
  elif [[ -d "$ROOT_DIR/vendor/whisper.cpp" ]] && command -v cmake >/dev/null 2>&1; then
    echo "Building local no-CoreML whisper-cli for app bundling..."
    cmake -S "$ROOT_DIR/vendor/whisper.cpp" -B "$ROOT_DIR/vendor/whisper.cpp/build-bvt-nocoreml" -DWHISPER_COREML=OFF >/dev/null 2>&1 || true
    cmake --build "$ROOT_DIR/vendor/whisper.cpp/build-bvt-nocoreml" -j >/dev/null 2>&1 || true
    if [[ -x "$local_vendor_nocoreml" ]]; then
      WHISPER_SOURCE="$local_vendor_nocoreml"
    fi
  fi
fi
if [[ -z "$WHISPER_SOURCE" ]]; then
  local_vendor_whisper="$ROOT_DIR/vendor/whisper.cpp/build/bin/whisper-cli"
  if [[ -x "$local_vendor_whisper" ]]; then
    WHISPER_SOURCE="$local_vendor_whisper"
  fi
fi
if [[ -z "$WHISPER_SOURCE" ]]; then
  for candidate in /opt/homebrew/bin/whisper-cli /usr/local/bin/whisper-cli; do
    if [[ -x "$candidate" ]]; then
      WHISPER_SOURCE="$candidate"
      break
    fi
  done
fi

if [[ -n "$WHISPER_SOURCE" && -x "$WHISPER_SOURCE" ]]; then
  cp "$WHISPER_SOURCE" "$APP_RESOURCES/whisper-cli"
  chmod +x "$APP_RESOURCES/whisper-cli"
  echo "Bundled whisper-cli: $WHISPER_SOURCE"
else
  echo "whisper-cli not bundled (set BUNDLED_WHISPER_PATH to include one)."
fi

WHISPER_MODEL_SOURCE="${BUNDLED_WHISPER_MODEL_PATH:-}"
if [[ -n "$WHISPER_MODEL_SOURCE" && -f "$WHISPER_MODEL_SOURCE" ]]; then
  cp "$WHISPER_MODEL_SOURCE" "$APP_RESOURCES/profanity-model.bin"
  echo "Bundled Whisper model: $WHISPER_MODEL_SOURCE"
else
  local_vendor_model=""
  if [[ -f "$ROOT_DIR/vendor/models/ggml-tiny.en.bin" ]]; then
    local_vendor_model="$ROOT_DIR/vendor/models/ggml-tiny.en.bin"
  else
    local_vendor_model="$(ls "$ROOT_DIR"/vendor/models/ggml-*.bin 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -n "$local_vendor_model" && -f "$local_vendor_model" ]]; then
    cp "$local_vendor_model" "$APP_RESOURCES/profanity-model.bin"
    echo "Bundled Whisper model: $local_vendor_model"
  else
    echo "Whisper model not bundled (set BUNDLED_WHISPER_MODEL_PATH or place a model in $ROOT_DIR/vendor/models)."
  fi
fi

echo "Built: $APP"
