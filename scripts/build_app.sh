#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT_DIR/src"
DIST="$ROOT_DIR/dist"
MODULE_CACHE="$ROOT_DIR/.build/module-cache"
SWIFTC_TMP_DIR="$ROOT_DIR/.build/tmp"
SWIFTC_BUILD_DIR="$ROOT_DIR/.build/swiftc"
SWIFTC_OBJECTS_DIR="$SWIFTC_BUILD_DIR/objects"
SWIFTC_DEPS_DIR="$SWIFTC_BUILD_DIR/deps"
SWIFTC_DIAGNOSTICS_DIR="$SWIFTC_BUILD_DIR/diagnostics"
SWIFTC_MODULE_DIR="$SWIFTC_BUILD_DIR/module"
SWIFTC_OUTPUT_FILE_MAP="$SWIFTC_BUILD_DIR/output-file-map.json"
APP_NAME="In-Out"
APP_EXECUTABLE="BulwarkVideoTools"
BUNDLE_ID="com.bulwark.BulwarkVideoTools"
APP_VERSION="${APP_VERSION:-1.0}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-1}"
APP_NAME_XML="$(python3 - <<'PY'
from xml.sax.saxutils import escape
print(escape("In/Out"))
PY
)"
APP="$DIST/$APP_NAME.app"
LEGACY_APP_1="$DIST/Bulwark Video Tools.app"
LEGACY_APP_2="$DIST/CheckBlackFrames.app"
BIN="$APP/Contents/MacOS/$APP_EXECUTABLE"
PLIST="$APP/Contents/Info.plist"
APP_RESOURCES="$APP/Contents/Resources"
ICON_SOURCE_PNG="$ROOT_DIR/assets/AppIcon-1024.png"
ICON_BASE_NAME="AppIcon"
ICON_ICNS_NAME="${ICON_BASE_NAME}.icns"
ICON_PNG_NAME="${ICON_BASE_NAME}.png"
ICON_ICNS_PATH="$APP_RESOURCES/$ICON_ICNS_NAME"
ICON_PNG_PATH="$APP_RESOURCES/$ICON_PNG_NAME"
FRAME_SOUND_SOURCE="$ROOT_DIR/assets/FrameShutter.aiff"
FRAME_SOUND_DEST="$APP_RESOURCES/FrameShutter.aiff"
QUICK_EXPORT_SOUND_SOURCE="$ROOT_DIR/assets/QuickExportSnip.aiff"
QUICK_EXPORT_SOUND_DEST="$APP_RESOURCES/QuickExportSnip.aiff"
PINNED_FFMPEG_DEFAULT="$ROOT_DIR/vendor/ffmpeg/macos-arm64/ffmpeg"
PINNED_FFMPEG_SHA_FILE_DEFAULT="$ROOT_DIR/vendor/ffmpeg/macos-arm64/ffmpeg.sha256"

BUILD_MODE="${1:-dev}"
QUICK_BUILD=0
case "$BUILD_MODE" in
  dev)
    SWIFTC_OPT_FLAGS=(-Onone -g)
    ;;
  quick)
    SWIFTC_OPT_FLAGS=(-O)
    QUICK_BUILD=1
    ;;
  release)
    SWIFTC_OPT_FLAGS=(-O)
    ;;
  *)
    echo "Usage: $0 [dev|quick|release]"
    exit 1
    ;;
esac

mkdir -p "$DIST"
mkdir -p "$MODULE_CACHE"
mkdir -p "$SWIFTC_TMP_DIR"
mkdir -p "$SWIFTC_OBJECTS_DIR" "$SWIFTC_DEPS_DIR" "$SWIFTC_DIAGNOSTICS_DIR" "$SWIFTC_MODULE_DIR"
export TMPDIR="$SWIFTC_TMP_DIR/"
# Remove legacy app bundle names to avoid launching stale builds by accident.
rm -rf "$LEGACY_APP_1" "$LEGACY_APP_2"
if [[ "$QUICK_BUILD" -eq 0 ]]; then
  rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP_RESOURCES"
mkdir -p "$ROOT_DIR/assets"

SWIFT_SOURCES=("$SRC_DIR"/*.swift)

# Clean stale module outputs that can trigger swiftc temp-path resolution errors.
find "$SWIFTC_MODULE_DIR" -maxdepth 1 -type f \
  \( -name "$APP_EXECUTABLE.swiftmodule" \
     -o -name "$APP_EXECUTABLE.swiftdoc" \
     -o -name "$APP_EXECUTABLE.swiftsourceinfo" \
     -o -name "$APP_EXECUTABLE.swiftdeps" \
     -o -name "$APP_EXECUTABLE.d" \
     -o -name "$APP_EXECUTABLE-master.dia" \
     -o -name "$APP_EXECUTABLE-*.swiftmodule" \
     -o -name "$APP_EXECUTABLE-*.swiftdoc" \
     -o -name "$APP_EXECUTABLE-*.swiftsourceinfo" \
     -o -name "$APP_EXECUTABLE-*.swiftdeps" \
     -o -name "$APP_EXECUTABLE-*.d" \
     -o -name "$APP_EXECUTABLE-*.dia" \) \
  -delete

python3 - "$SWIFTC_OUTPUT_FILE_MAP" "$SWIFTC_OBJECTS_DIR" "$SWIFTC_DEPS_DIR" "$SWIFTC_DIAGNOSTICS_DIR" "$SWIFTC_MODULE_DIR" "$APP_EXECUTABLE" "${SWIFT_SOURCES[@]}" <<'PY'
import hashlib
import json
import os
import sys

ofm_path = sys.argv[1]
objects_dir = sys.argv[2]
deps_dir = sys.argv[3]
diagnostics_dir = sys.argv[4]
module_dir = sys.argv[5]
module_name = sys.argv[6]
sources = sys.argv[7:]

os.makedirs(objects_dir, exist_ok=True)
os.makedirs(deps_dir, exist_ok=True)
os.makedirs(diagnostics_dir, exist_ok=True)
os.makedirs(module_dir, exist_ok=True)

result = {
    "": {
        "swift-dependencies": os.path.join(module_dir, f"{module_name}.swiftdeps"),
        "swiftmodule": os.path.join(module_dir, f"{module_name}.swiftmodule"),
        "swiftdoc": os.path.join(module_dir, f"{module_name}.swiftdoc"),
        "swiftsourceinfo": os.path.join(module_dir, f"{module_name}.swiftsourceinfo"),
        "dependencies": os.path.join(module_dir, f"{module_name}.d"),
        "diagnostics": os.path.join(module_dir, f"{module_name}-master.dia"),
    }
}

for source in sources:
    base = os.path.splitext(os.path.basename(source))[0]
    digest = hashlib.sha1(source.encode("utf-8")).hexdigest()[:8]
    stem = f"{base}-{digest}"
    result[source] = {
        "object": os.path.join(objects_dir, f"{stem}.o"),
        "swift-dependencies": os.path.join(deps_dir, f"{stem}.swiftdeps"),
        "dependencies": os.path.join(deps_dir, f"{stem}.d"),
        "diagnostics": os.path.join(diagnostics_dir, f"{stem}.dia"),
    }

with open(ofm_path, "w", encoding="utf-8") as f:
    json.dump(result, f, indent=2, sort_keys=True)
PY

swiftc \
  "${SWIFTC_OPT_FLAGS[@]}" \
  -parse-as-library \
  -incremental \
  -output-file-map "$SWIFTC_OUTPUT_FILE_MAP" \
  -module-name "$APP_EXECUTABLE" \
  -module-cache-path "$MODULE_CACHE" \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreVideo \
  -framework CoreMedia \
  -framework Foundation \
  "${SWIFT_SOURCES[@]}" \
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
  <string>$APP_NAME_XML</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME_XML</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
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
  if [[ "$QUICK_BUILD" -eq 1 && -f "$ICON_ICNS_PATH" ]]; then
    echo "Quick mode: keeping existing app icon."
  else
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
  fi
else
  echo "App icon not bundled (missing $ICON_SOURCE_PNG)."
fi

if [[ -f "$FRAME_SOUND_SOURCE" ]]; then
  cp "$FRAME_SOUND_SOURCE" "$FRAME_SOUND_DEST"
  echo "Bundled frame capture sound: $FRAME_SOUND_SOURCE"
else
  echo "Frame capture sound not bundled (missing $FRAME_SOUND_SOURCE)."
fi

if [[ -f "$QUICK_EXPORT_SOUND_SOURCE" ]]; then
  cp "$QUICK_EXPORT_SOUND_SOURCE" "$QUICK_EXPORT_SOUND_DEST"
  echo "Bundled quick export sound: $QUICK_EXPORT_SOUND_SOURCE"
else
  echo "Quick export sound not bundled (missing $QUICK_EXPORT_SOUND_SOURCE)."
fi

FFMPEG_SOURCE="${BUNDLED_FFMPEG_PATH:-}"
PINNED_FFMPEG_SHA_FILE="${BUNDLED_FFMPEG_SHA_FILE:-$PINNED_FFMPEG_SHA_FILE_DEFAULT}"
EXPECTED_FFMPEG_SHA="${BUNDLED_FFMPEG_SHA256:-}"

if [[ "$BUILD_MODE" == "release" ]]; then
  if [[ -z "$FFMPEG_SOURCE" ]]; then
    FFMPEG_SOURCE="$PINNED_FFMPEG_DEFAULT"
  fi

  if [[ ! -x "$FFMPEG_SOURCE" ]]; then
    echo "ERROR: release build requires a pinned ffmpeg binary."
    echo "Missing executable: $FFMPEG_SOURCE"
    echo "Use scripts/pin_ffmpeg.sh or set BUNDLED_FFMPEG_PATH."
    exit 1
  fi

  if [[ -z "$EXPECTED_FFMPEG_SHA" && -f "$PINNED_FFMPEG_SHA_FILE" ]]; then
    EXPECTED_FFMPEG_SHA="$(awk '{print $1}' "$PINNED_FFMPEG_SHA_FILE" | head -n 1)"
  fi
  if [[ -z "$EXPECTED_FFMPEG_SHA" ]]; then
    echo "ERROR: release build requires ffmpeg checksum pinning."
    echo "Set BUNDLED_FFMPEG_SHA256 or provide: $PINNED_FFMPEG_SHA_FILE"
    exit 1
  fi

  ACTUAL_FFMPEG_SHA="$(shasum -a 256 "$FFMPEG_SOURCE" | awk '{print $1}')"
  if [[ "$ACTUAL_FFMPEG_SHA" != "$EXPECTED_FFMPEG_SHA" ]]; then
    echo "ERROR: ffmpeg checksum mismatch."
    echo "Expected: $EXPECTED_FFMPEG_SHA"
    echo "Actual:   $ACTUAL_FFMPEG_SHA"
    echo "Binary:   $FFMPEG_SOURCE"
    exit 1
  fi
else
  if [[ -z "$FFMPEG_SOURCE" && -x "$PINNED_FFMPEG_DEFAULT" ]]; then
    FFMPEG_SOURCE="$PINNED_FFMPEG_DEFAULT"
  fi
  if [[ -z "$FFMPEG_SOURCE" ]]; then
    for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg /usr/bin/ffmpeg; do
      if [[ -x "$candidate" ]]; then
        FFMPEG_SOURCE="$candidate"
        break
      fi
    done
  fi
fi

if [[ -n "$FFMPEG_SOURCE" && -x "$FFMPEG_SOURCE" ]]; then
  if [[ "$QUICK_BUILD" -eq 1 && -x "$APP_RESOURCES/ffmpeg" && "$BUILD_MODE" != "release" ]]; then
    echo "Quick mode: keeping existing bundled ffmpeg."
  else
    cp "$FFMPEG_SOURCE" "$APP_RESOURCES/ffmpeg"
    chmod +x "$APP_RESOURCES/ffmpeg"
    if [[ -n "${ACTUAL_FFMPEG_SHA:-}" ]]; then
      echo "Bundled ffmpeg: $FFMPEG_SOURCE (sha256: $ACTUAL_FFMPEG_SHA)"
    else
      echo "Bundled ffmpeg: $FFMPEG_SOURCE"
    fi
  fi
else
  echo "ffmpeg not bundled (set BUNDLED_FFMPEG_PATH to include one)."
fi

WHISPER_SOURCE="${BUNDLED_WHISPER_PATH:-}"
if [[ -z "$WHISPER_SOURCE" ]]; then
  local_vendor_nocoreml="$ROOT_DIR/vendor/whisper.cpp/build-bvt-nocoreml/bin/whisper-cli"
  if [[ -x "$local_vendor_nocoreml" ]]; then
    WHISPER_SOURCE="$local_vendor_nocoreml"
  elif [[ "$QUICK_BUILD" -eq 0 && -d "$ROOT_DIR/vendor/whisper.cpp" ]] && command -v cmake >/dev/null 2>&1; then
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
  if [[ "$QUICK_BUILD" -eq 1 && -x "$APP_RESOURCES/whisper-cli" ]]; then
    echo "Quick mode: keeping existing bundled whisper-cli."
  else
    cp "$WHISPER_SOURCE" "$APP_RESOURCES/whisper-cli"
    chmod +x "$APP_RESOURCES/whisper-cli"
    echo "Bundled whisper-cli: $WHISPER_SOURCE"
  fi
else
  echo "whisper-cli not bundled (set BUNDLED_WHISPER_PATH to include one)."
fi

WHISPER_MODEL_SOURCE="${BUNDLED_WHISPER_MODEL_PATH:-}"
if [[ -n "$WHISPER_MODEL_SOURCE" && -f "$WHISPER_MODEL_SOURCE" ]]; then
  if [[ "$QUICK_BUILD" -eq 1 && -f "$APP_RESOURCES/profanity-model.bin" ]]; then
    echo "Quick mode: keeping existing bundled Whisper model."
  else
    cp "$WHISPER_MODEL_SOURCE" "$APP_RESOURCES/profanity-model.bin"
    echo "Bundled Whisper model: $WHISPER_MODEL_SOURCE"
  fi
else
  local_vendor_model=""
  if [[ -f "$ROOT_DIR/vendor/models/ggml-tiny.en.bin" ]]; then
    local_vendor_model="$ROOT_DIR/vendor/models/ggml-tiny.en.bin"
  else
    local_vendor_model="$(ls "$ROOT_DIR"/vendor/models/ggml-*.bin 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -n "$local_vendor_model" && -f "$local_vendor_model" ]]; then
    if [[ "$QUICK_BUILD" -eq 1 && -f "$APP_RESOURCES/profanity-model.bin" ]]; then
      echo "Quick mode: keeping existing bundled Whisper model."
    else
      cp "$local_vendor_model" "$APP_RESOURCES/profanity-model.bin"
      echo "Bundled Whisper model: $local_vendor_model"
    fi
  else
    echo "Whisper model not bundled (set BUNDLED_WHISPER_MODEL_PATH or place a model in $ROOT_DIR/vendor/models)."
  fi
fi

echo "Built: $APP"
echo "Mode: $BUILD_MODE"
