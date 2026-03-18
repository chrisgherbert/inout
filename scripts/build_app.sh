#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT_DIR/src"
CORE_SRC_DIR="$ROOT_DIR/src-core"
DIST="$ROOT_DIR/dist"
MODULE_CACHE="$ROOT_DIR/.build/module-cache"
SWIFTC_TMP_DIR="$ROOT_DIR/.build/tmp"
SWIFTC_BUILD_DIR="$ROOT_DIR/.build/swiftc"
SWIFTC_OBJECTS_DIR="$SWIFTC_BUILD_DIR/objects"
SWIFTC_DEPS_DIR="$SWIFTC_BUILD_DIR/deps"
SWIFTC_DIAGNOSTICS_DIR="$SWIFTC_BUILD_DIR/diagnostics"
SWIFTC_MODULE_DIR="$SWIFTC_BUILD_DIR/module"
SWIFTC_OUTPUT_FILE_MAP="$SWIFTC_BUILD_DIR/output-file-map.json"
CORE_BUILD_DIR="$ROOT_DIR/.build/core"
CORE_OBJECTS_DIR="$CORE_BUILD_DIR/objects"
CORE_DEPS_DIR="$CORE_BUILD_DIR/deps"
CORE_DIAGNOSTICS_DIR="$CORE_BUILD_DIR/diagnostics"
CORE_MODULE_DIR="$CORE_BUILD_DIR/module"
CORE_OUTPUT_FILE_MAP="$CORE_BUILD_DIR/output-file-map.json"
SWIFTC_INCREMENTAL_FLAGS=()
APP_NAME="In-Out"
APP_EXECUTABLE="BulwarkVideoTools"
CORE_MODULE_NAME="InOutCore"
BUNDLE_ID="com.bulwark.BulwarkVideoTools"
APP_VERSION="${APP_VERSION:-1.0}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-1}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-13.0}"
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
PINNED_FFPROBE_DEFAULT="$ROOT_DIR/vendor/ffmpeg/macos-arm64/ffprobe"
PINNED_FFPROBE_SHA_FILE_DEFAULT="$ROOT_DIR/vendor/ffmpeg/macos-arm64/ffprobe.sha256"
PINNED_YTDLP_DEFAULT="$ROOT_DIR/vendor/yt-dlp/macos-arm64/yt-dlp"
PINNED_YTDLP_SHA_FILE_DEFAULT="$ROOT_DIR/vendor/yt-dlp/macos-arm64/yt-dlp.sha256"

clean_swift_module_outputs() {
  local module_dir="$1"
  local module_name="$2"

  if [[ ${#SWIFTC_INCREMENTAL_FLAGS[@]} -eq 0 ]]; then
    find "$module_dir" -maxdepth 1 -type f \
      \( -name "$module_name.swiftmodule" \
         -o -name "$module_name.swiftdoc" \
         -o -name "$module_name.swiftsourceinfo" \
         -o -name "$module_name.swiftdeps" \
         -o -name "$module_name.d" \
         -o -name "$module_name-master.dia" \
         -o -name "$module_name-*.swiftmodule" \
         -o -name "$module_name-*.swiftdoc" \
         -o -name "$module_name-*.swiftsourceinfo" \
         -o -name "$module_name-*.swiftdeps" \
         -o -name "$module_name-*.d" \
         -o -name "$module_name-*.dia" \) \
      -delete
  else
    find "$module_dir" -maxdepth 1 -type f \
      \( -name "$module_name-*.swiftmodule" \
         -o -name "$module_name-*.swiftdoc" \
         -o -name "$module_name-*.swiftsourceinfo" \
         -o -name "$module_name-*.swiftdeps" \
         -o -name "$module_name-*.d" \
         -o -name "$module_name-*.dia" \) \
      -delete
  fi
}

generate_output_file_map() {
  local ofm_path="$1"
  local objects_dir="$2"
  local deps_dir="$3"
  local diagnostics_dir="$4"
  local module_dir="$5"
  local module_name="$6"
  shift 6

  python3 - "$ofm_path" "$objects_dir" "$deps_dir" "$diagnostics_dir" "$module_dir" "$module_name" "$@" <<'PY'
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
}

should_refresh_bundle_item() {
  local src="$1"
  local dest="$2"

  if [[ ! -e "$src" ]]; then
    return 1
  fi
  if [[ "$BUILD_MODE" == "release" ]]; then
    return 0
  fi
  if [[ "$REFRESH_BUNDLED_TOOLS" -eq 1 ]]; then
    return 0
  fi
  if [[ ! -e "$dest" ]]; then
    return 0
  fi
  if [[ "$src" -nt "$dest" ]]; then
    return 0
  fi
  return 1
}

copy_whisper_runtime_libs() {
  local whisper_cli_path="$1"
  local whisper_root
  whisper_root="$(cd "$(dirname "$whisper_cli_path")/.." && pwd)"
  local -a search_dirs=(
    "$whisper_root/src"
    "$whisper_root/ggml/src"
    "$whisper_root/ggml/src/ggml-blas"
    "$whisper_root/ggml/src/ggml-metal"
  )

  local deps
  deps="$(
    otool -L "$whisper_cli_path" \
      | awk '/@rpath\/.*\.dylib/ { print $1 }' \
      | sed 's#^@rpath/##'
  )"

  if [[ -z "$deps" ]]; then
    echo "No @rpath whisper runtime dependencies found."
    return 0
  fi

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    local src_path=""
    local dir
    for dir in "${search_dirs[@]}"; do
      if [[ -e "$dir/$dep" ]]; then
        src_path="$dir/$dep"
        break
      fi
    done

    if [[ -z "$src_path" ]]; then
      echo "ERROR: could not locate whisper runtime dependency: $dep"
      exit 1
    fi

    local src_real
    src_real="$(python3 - "$src_path" <<'PY'
import os,sys
print(os.path.realpath(sys.argv[1]))
PY
)"
    local real_base
    real_base="$(basename "$src_real")"

    cp "$src_real" "$APP_RESOURCES/$real_base"
    chmod +x "$APP_RESOURCES/$real_base"

    if [[ "$dep" != "$real_base" ]]; then
      ln -sf "$real_base" "$APP_RESOURCES/$dep"
    fi
  done <<< "$deps"

  # Ensure whisper-cli resolves @rpath from app resources, not build-machine paths.
  if ! otool -l "$APP_RESOURCES/whisper-cli" | grep -q "path @executable_path "; then
    install_name_tool -add_rpath "@executable_path" "$APP_RESOURCES/whisper-cli" || true
  fi

  # Remove absolute build-dir rpaths from whisper-cli.
  local rpaths
  rpaths="$(otool -l "$APP_RESOURCES/whisper-cli" | awk '/path / { print $2 }' | grep '^/' || true)"
  while IFS= read -r rp; do
    [[ -z "$rp" ]] && continue
    install_name_tool -delete_rpath "$rp" "$APP_RESOURCES/whisper-cli" || true
  done <<< "$rpaths"

  # For each bundled whisper dylib, ensure @rpath is resolvable locally and strip absolute rpaths.
  local lib
  for lib in "$APP_RESOURCES"/libwhisper*.dylib "$APP_RESOURCES"/libggml*.dylib; do
    [[ -e "$lib" ]] || continue
    if ! otool -l "$lib" | grep -q "path @loader_path "; then
      install_name_tool -add_rpath "@loader_path" "$lib" || true
    fi
    local lib_rpaths
    lib_rpaths="$(otool -l "$lib" | awk '/path / { print $2 }' | grep '^/' || true)"
    while IFS= read -r rp; do
      [[ -z "$rp" ]] && continue
      install_name_tool -delete_rpath "$rp" "$lib" || true
    done <<< "$lib_rpaths"
  done
}

BUILD_MODE="${1:-dev}"
QUICK_BUILD=0
PRESERVE_APP_BUNDLE=0
REFRESH_BUNDLED_TOOLS="${REFRESH_BUNDLED_TOOLS:-0}"
case "$BUILD_MODE" in
  dev)
    SWIFTC_OPT_FLAGS=(-Onone -g)
    SWIFTC_INCREMENTAL_FLAGS=(-incremental)
    PRESERVE_APP_BUNDLE=1
    ;;
  quick)
    SWIFTC_OPT_FLAGS=(-O)
    QUICK_BUILD=1
    SWIFTC_INCREMENTAL_FLAGS=(-incremental)
    PRESERVE_APP_BUNDLE=1
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
mkdir -p "$CORE_OBJECTS_DIR" "$CORE_DEPS_DIR" "$CORE_DIAGNOSTICS_DIR" "$CORE_MODULE_DIR"
export TMPDIR="$SWIFTC_TMP_DIR/"
# Remove legacy app bundle names to avoid launching stale builds by accident.
rm -rf "$LEGACY_APP_1" "$LEGACY_APP_2"
if [[ "$PRESERVE_APP_BUNDLE" -eq 0 ]]; then
  rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP_RESOURCES"
mkdir -p "$ROOT_DIR/assets"

SWIFT_SOURCES=("$SRC_DIR"/*.swift)
CORE_SOURCES=()
if [[ -d "$CORE_SRC_DIR" ]]; then
  CORE_SOURCES=("$CORE_SRC_DIR"/*.swift(N))
fi

clean_swift_module_outputs "$SWIFTC_MODULE_DIR" "$APP_EXECUTABLE"
generate_output_file_map \
  "$SWIFTC_OUTPUT_FILE_MAP" \
  "$SWIFTC_OBJECTS_DIR" \
  "$SWIFTC_DEPS_DIR" \
  "$SWIFTC_DIAGNOSTICS_DIR" \
  "$SWIFTC_MODULE_DIR" \
  "$APP_EXECUTABLE" \
  "${SWIFT_SOURCES[@]}"

CORE_LINK_INPUTS=()
if [[ ${#CORE_SOURCES[@]} -gt 0 ]]; then
  clean_swift_module_outputs "$CORE_MODULE_DIR" "$CORE_MODULE_NAME"
  generate_output_file_map \
    "$CORE_OUTPUT_FILE_MAP" \
    "$CORE_OBJECTS_DIR" \
    "$CORE_DEPS_DIR" \
    "$CORE_DIAGNOSTICS_DIR" \
    "$CORE_MODULE_DIR" \
    "$CORE_MODULE_NAME" \
    "${CORE_SOURCES[@]}"

  swiftc \
    "${SWIFTC_OPT_FLAGS[@]}" \
    "${SWIFTC_INCREMENTAL_FLAGS[@]}" \
    -target "arm64-apple-macos${MIN_MACOS_VERSION}" \
    -parse-as-library \
    -emit-module \
    -emit-module-path "$CORE_MODULE_DIR/$CORE_MODULE_NAME.swiftmodule" \
    -output-file-map "$CORE_OUTPUT_FILE_MAP" \
    -module-name "$CORE_MODULE_NAME" \
    -module-cache-path "$MODULE_CACHE" \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework Foundation \
    "${CORE_SOURCES[@]}" \
    -c

  rm -f \
    "$ROOT_DIR/$CORE_MODULE_NAME.abi.json" \
    "$ROOT_DIR/$CORE_MODULE_NAME.swiftdoc" \
    "$ROOT_DIR/$CORE_MODULE_NAME.swiftmodule" \
    "$ROOT_DIR/$CORE_MODULE_NAME.swiftsourceinfo"

  CORE_LINK_INPUTS=("$CORE_OBJECTS_DIR"/*.o(N))
fi

swiftc \
  "${SWIFTC_OPT_FLAGS[@]}" \
  "${SWIFTC_INCREMENTAL_FLAGS[@]}" \
  -target "arm64-apple-macos${MIN_MACOS_VERSION}" \
  -parse-as-library \
  -emit-executable \
  -emit-module \
  -emit-module-path "$SWIFTC_MODULE_DIR/$APP_EXECUTABLE.swiftmodule" \
  -output-file-map "$SWIFTC_OUTPUT_FILE_MAP" \
  -module-name "$APP_EXECUTABLE" \
  -module-cache-path "$MODULE_CACHE" \
  -I "$CORE_MODULE_DIR" \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreVideo \
  -framework CoreMedia \
  -framework Foundation \
  "${CORE_LINK_INPUTS[@]}" \
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
  <string>${MIN_MACOS_VERSION}</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$BIN"

if [[ -f "$ICON_SOURCE_PNG" ]]; then
  if [[ "$BUILD_MODE" != "release" && "$REFRESH_BUNDLED_TOOLS" -eq 0 && \
        (( -f "$ICON_ICNS_PATH" && ! "$ICON_SOURCE_PNG" -nt "$ICON_ICNS_PATH" ) || \
           ( -f "$ICON_PNG_PATH" && ! "$ICON_SOURCE_PNG" -nt "$ICON_PNG_PATH" )) ]]; then
    echo "Keeping existing app icon."
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
  if should_refresh_bundle_item "$FRAME_SOUND_SOURCE" "$FRAME_SOUND_DEST"; then
    cp "$FRAME_SOUND_SOURCE" "$FRAME_SOUND_DEST"
    echo "Bundled frame capture sound: $FRAME_SOUND_SOURCE"
  else
    echo "Keeping existing frame capture sound."
  fi
else
  echo "Frame capture sound not bundled (missing $FRAME_SOUND_SOURCE)."
fi

if [[ -f "$QUICK_EXPORT_SOUND_SOURCE" ]]; then
  if should_refresh_bundle_item "$QUICK_EXPORT_SOUND_SOURCE" "$QUICK_EXPORT_SOUND_DEST"; then
    cp "$QUICK_EXPORT_SOUND_SOURCE" "$QUICK_EXPORT_SOUND_DEST"
    echo "Bundled quick export sound: $QUICK_EXPORT_SOUND_SOURCE"
  else
    echo "Keeping existing quick export sound."
  fi
else
  echo "Quick export sound not bundled (missing $QUICK_EXPORT_SOUND_SOURCE)."
fi

FFMPEG_SOURCE="${BUNDLED_FFMPEG_PATH:-}"
PINNED_FFMPEG_SHA_FILE="${BUNDLED_FFMPEG_SHA_FILE:-$PINNED_FFMPEG_SHA_FILE_DEFAULT}"
EXPECTED_FFMPEG_SHA="${BUNDLED_FFMPEG_SHA256:-}"
FFPROBE_SOURCE="${BUNDLED_FFPROBE_PATH:-}"
PINNED_FFPROBE_SHA_FILE="${BUNDLED_FFPROBE_SHA_FILE:-$PINNED_FFPROBE_SHA_FILE_DEFAULT}"
EXPECTED_FFPROBE_SHA="${BUNDLED_FFPROBE_SHA256:-}"

if [[ "$BUILD_MODE" == "release" ]]; then
  if [[ -z "$FFMPEG_SOURCE" ]]; then
    FFMPEG_SOURCE="$PINNED_FFMPEG_DEFAULT"
  fi
  if [[ -z "$FFPROBE_SOURCE" && -n "$FFMPEG_SOURCE" ]]; then
    guessed_ffprobe="$(cd "$(dirname "$FFMPEG_SOURCE")" && pwd)/ffprobe"
    if [[ -x "$guessed_ffprobe" ]]; then
      FFPROBE_SOURCE="$guessed_ffprobe"
    fi
  fi
  if [[ -z "$FFPROBE_SOURCE" ]]; then
    FFPROBE_SOURCE="$PINNED_FFPROBE_DEFAULT"
  fi

  if [[ ! -x "$FFMPEG_SOURCE" ]]; then
    echo "ERROR: release build requires a pinned ffmpeg binary."
    echo "Missing executable: $FFMPEG_SOURCE"
    echo "Use scripts/pin_ffmpeg.sh or set BUNDLED_FFMPEG_PATH."
    exit 1
  fi
  if [[ ! -x "$FFPROBE_SOURCE" ]]; then
    echo "ERROR: release build requires a pinned ffprobe binary."
    echo "Missing executable: $FFPROBE_SOURCE"
    echo "Use scripts/pin_ffmpeg.sh or set BUNDLED_FFPROBE_PATH."
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
  if [[ -z "$EXPECTED_FFPROBE_SHA" && -f "$PINNED_FFPROBE_SHA_FILE" ]]; then
    EXPECTED_FFPROBE_SHA="$(awk '{print $1}' "$PINNED_FFPROBE_SHA_FILE" | head -n 1)"
  fi
  if [[ -z "$EXPECTED_FFPROBE_SHA" ]]; then
    echo "ERROR: release build requires ffprobe checksum pinning."
    echo "Set BUNDLED_FFPROBE_SHA256 or provide: $PINNED_FFPROBE_SHA_FILE"
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
  ACTUAL_FFPROBE_SHA="$(shasum -a 256 "$FFPROBE_SOURCE" | awk '{print $1}')"
  if [[ "$ACTUAL_FFPROBE_SHA" != "$EXPECTED_FFPROBE_SHA" ]]; then
    echo "ERROR: ffprobe checksum mismatch."
    echo "Expected: $EXPECTED_FFPROBE_SHA"
    echo "Actual:   $ACTUAL_FFPROBE_SHA"
    echo "Binary:   $FFPROBE_SOURCE"
    exit 1
  fi

  "$ROOT_DIR/scripts/ffmpeg_dependency_audit.sh" "$FFMPEG_SOURCE"
  "$ROOT_DIR/scripts/ffmpeg_dependency_audit.sh" "$FFPROBE_SOURCE"
else
  if [[ -z "$FFMPEG_SOURCE" && -x "$PINNED_FFMPEG_DEFAULT" ]]; then
    FFMPEG_SOURCE="$PINNED_FFMPEG_DEFAULT"
  fi
  if [[ -z "$FFPROBE_SOURCE" && -n "$FFMPEG_SOURCE" ]]; then
    guessed_ffprobe="$(cd "$(dirname "$FFMPEG_SOURCE")" && pwd)/ffprobe"
    if [[ -x "$guessed_ffprobe" ]]; then
      FFPROBE_SOURCE="$guessed_ffprobe"
    fi
  fi
  if [[ -z "$FFPROBE_SOURCE" && -x "$PINNED_FFPROBE_DEFAULT" ]]; then
    FFPROBE_SOURCE="$PINNED_FFPROBE_DEFAULT"
  fi
  if [[ -z "$FFMPEG_SOURCE" ]]; then
    if [[ -n "${PATH:-}" ]]; then
      IFS=: read -rA path_entries <<< "$PATH"
      for entry in "${path_entries[@]}"; do
        candidate="${entry}/ffmpeg"
        if [[ -x "$candidate" ]]; then
          FFMPEG_SOURCE="$candidate"
          break
        fi
      done
    fi
  fi
  if [[ -z "$FFMPEG_SOURCE" ]]; then
    for candidate in /usr/bin/ffmpeg; do
      if [[ -x "$candidate" ]]; then
        FFMPEG_SOURCE="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$FFPROBE_SOURCE" ]]; then
    if [[ -n "${PATH:-}" ]]; then
      IFS=: read -rA path_entries <<< "$PATH"
      for entry in "${path_entries[@]}"; do
        candidate="${entry}/ffprobe"
        if [[ -x "$candidate" ]]; then
          FFPROBE_SOURCE="$candidate"
          break
        fi
      done
    fi
  fi
  if [[ -z "$FFPROBE_SOURCE" ]]; then
    for candidate in /usr/bin/ffprobe; do
      if [[ -x "$candidate" ]]; then
        FFPROBE_SOURCE="$candidate"
        break
      fi
    done
  fi
fi

if [[ -n "$FFMPEG_SOURCE" && -x "$FFMPEG_SOURCE" ]]; then
  if should_refresh_bundle_item "$FFMPEG_SOURCE" "$APP_RESOURCES/ffmpeg"; then
    cp "$FFMPEG_SOURCE" "$APP_RESOURCES/ffmpeg"
    chmod +x "$APP_RESOURCES/ffmpeg"
    if [[ -n "${ACTUAL_FFMPEG_SHA:-}" ]]; then
      echo "Bundled ffmpeg: $FFMPEG_SOURCE (sha256: $ACTUAL_FFMPEG_SHA)"
    else
      echo "Bundled ffmpeg: $FFMPEG_SOURCE"
    fi
  else
    echo "Keeping existing bundled ffmpeg."
  fi
else
  echo "ffmpeg not bundled (set BUNDLED_FFMPEG_PATH to include one)."
fi

if [[ -n "$FFPROBE_SOURCE" && -x "$FFPROBE_SOURCE" ]]; then
  if should_refresh_bundle_item "$FFPROBE_SOURCE" "$APP_RESOURCES/ffprobe"; then
    cp "$FFPROBE_SOURCE" "$APP_RESOURCES/ffprobe"
    chmod +x "$APP_RESOURCES/ffprobe"
    if [[ -n "${ACTUAL_FFPROBE_SHA:-}" ]]; then
      echo "Bundled ffprobe: $FFPROBE_SOURCE (sha256: $ACTUAL_FFPROBE_SHA)"
    else
      echo "Bundled ffprobe: $FFPROBE_SOURCE"
    fi
  else
    echo "Keeping existing bundled ffprobe."
  fi
else
  echo "ffprobe not bundled (set BUNDLED_FFPROBE_PATH to include one)."
fi

YTDLP_SOURCE="${BUNDLED_YTDLP_PATH:-}"
PINNED_YTDLP_SHA_FILE="${BUNDLED_YTDLP_SHA_FILE:-$PINNED_YTDLP_SHA_FILE_DEFAULT}"
EXPECTED_YTDLP_SHA="${BUNDLED_YTDLP_SHA256:-}"
if [[ -z "$YTDLP_SOURCE" && -x "$PINNED_YTDLP_DEFAULT" ]]; then
  YTDLP_SOURCE="$PINNED_YTDLP_DEFAULT"
fi
if [[ -z "$YTDLP_SOURCE" ]]; then
  if [[ -n "${PATH:-}" ]]; then
    IFS=: read -rA path_entries <<< "$PATH"
    for entry in "${path_entries[@]}"; do
      candidate="${entry}/yt-dlp"
      if [[ -x "$candidate" ]]; then
        YTDLP_SOURCE="$candidate"
        break
      fi
    done
  fi
fi

if [[ "$BUILD_MODE" == "release" ]]; then
  if [[ -z "$YTDLP_SOURCE" || ! -x "$YTDLP_SOURCE" ]]; then
    echo "ERROR: release build requires a bundled yt-dlp binary."
    echo "Set BUNDLED_YTDLP_PATH or provide pinned binary at:"
    echo "  $PINNED_YTDLP_DEFAULT"
    exit 1
  fi

  if [[ -z "$EXPECTED_YTDLP_SHA" && -f "$PINNED_YTDLP_SHA_FILE" ]]; then
    EXPECTED_YTDLP_SHA="$(awk '{print $1}' "$PINNED_YTDLP_SHA_FILE" | head -n 1)"
  fi
  if [[ -z "$EXPECTED_YTDLP_SHA" ]]; then
    echo "ERROR: release build requires yt-dlp checksum pinning."
    echo "Set BUNDLED_YTDLP_SHA256 or provide: $PINNED_YTDLP_SHA_FILE"
    exit 1
  fi

  ACTUAL_YTDLP_SHA="$(shasum -a 256 "$YTDLP_SOURCE" | awk '{print $1}')"
  if [[ "$ACTUAL_YTDLP_SHA" != "$EXPECTED_YTDLP_SHA" ]]; then
    echo "ERROR: yt-dlp checksum mismatch."
    echo "Expected: $EXPECTED_YTDLP_SHA"
    echo "Actual:   $ACTUAL_YTDLP_SHA"
    echo "Binary:   $YTDLP_SOURCE"
    exit 1
  fi

  "$ROOT_DIR/scripts/ytdlp_portability_audit.sh" "$YTDLP_SOURCE"
fi

if [[ -n "$YTDLP_SOURCE" && -x "$YTDLP_SOURCE" ]]; then
  if should_refresh_bundle_item "$YTDLP_SOURCE" "$APP_RESOURCES/yt-dlp"; then
    cp "$YTDLP_SOURCE" "$APP_RESOURCES/yt-dlp"
    chmod +x "$APP_RESOURCES/yt-dlp"
    if [[ -n "${ACTUAL_YTDLP_SHA:-}" ]]; then
      echo "Bundled yt-dlp: $YTDLP_SOURCE (sha256: $ACTUAL_YTDLP_SHA)"
    else
      echo "Bundled yt-dlp: $YTDLP_SOURCE"
    fi
  else
    echo "Keeping existing bundled yt-dlp."
  fi
else
  echo "yt-dlp not bundled (set BUNDLED_YTDLP_PATH to include one)."
fi

WHISPER_SOURCE="${BUNDLED_WHISPER_PATH:-}"
WHISPER_VENDOR_ROOT="$ROOT_DIR/vendor/whisper.cpp"
WHISPER_BUILD_ROOT="$ROOT_DIR/.build/whisper.cpp"
WHISPER_BUILD_NOCOREML="$WHISPER_BUILD_ROOT/build-bvt-nocoreml"
WHISPER_BUILD_DEFAULT="$WHISPER_BUILD_ROOT/build"

if [[ -d "$WHISPER_VENDOR_ROOT" ]]; then
  mkdir -p "$WHISPER_BUILD_ROOT"
  if [[ -d "$WHISPER_VENDOR_ROOT/build-bvt-nocoreml" && ! -e "$WHISPER_BUILD_NOCOREML" ]]; then
    mv "$WHISPER_VENDOR_ROOT/build-bvt-nocoreml" "$WHISPER_BUILD_NOCOREML"
  fi
  if [[ -d "$WHISPER_VENDOR_ROOT/build" && ! -e "$WHISPER_BUILD_DEFAULT" ]]; then
    mv "$WHISPER_VENDOR_ROOT/build" "$WHISPER_BUILD_DEFAULT"
  fi
fi

if [[ -z "$WHISPER_SOURCE" ]]; then
  local_vendor_nocoreml="$WHISPER_BUILD_NOCOREML/bin/whisper-cli"
  if [[ -x "$local_vendor_nocoreml" ]]; then
    WHISPER_SOURCE="$local_vendor_nocoreml"
  elif [[ "$QUICK_BUILD" -eq 0 && -d "$WHISPER_VENDOR_ROOT" ]] && command -v cmake >/dev/null 2>&1; then
    echo "Building local no-CoreML whisper-cli for app bundling..."
    cmake -S "$WHISPER_VENDOR_ROOT" -B "$WHISPER_BUILD_NOCOREML" -DWHISPER_COREML=OFF >/dev/null 2>&1 || true
    cmake --build "$WHISPER_BUILD_NOCOREML" -j >/dev/null 2>&1 || true
    if [[ -x "$local_vendor_nocoreml" ]]; then
      WHISPER_SOURCE="$local_vendor_nocoreml"
    fi
  fi
fi
if [[ -z "$WHISPER_SOURCE" ]]; then
  local_vendor_whisper="$WHISPER_BUILD_DEFAULT/bin/whisper-cli"
  if [[ -x "$local_vendor_whisper" ]]; then
    WHISPER_SOURCE="$local_vendor_whisper"
  fi
fi
if [[ -z "$WHISPER_SOURCE" ]]; then
  if [[ -n "${PATH:-}" ]]; then
    IFS=: read -rA path_entries <<< "$PATH"
    for entry in "${path_entries[@]}"; do
      candidate="${entry}/whisper-cli"
      if [[ -x "$candidate" ]]; then
        WHISPER_SOURCE="$candidate"
        break
      fi
    done
  fi
fi

if [[ -n "$WHISPER_SOURCE" && -x "$WHISPER_SOURCE" ]]; then
  if should_refresh_bundle_item "$WHISPER_SOURCE" "$APP_RESOURCES/whisper-cli"; then
    cp "$WHISPER_SOURCE" "$APP_RESOURCES/whisper-cli"
    chmod +x "$APP_RESOURCES/whisper-cli"
    copy_whisper_runtime_libs "$WHISPER_SOURCE"
    echo "Bundled whisper-cli: $WHISPER_SOURCE"
  else
    echo "Keeping existing bundled whisper-cli/runtime libs."
  fi
else
  echo "whisper-cli not bundled (set BUNDLED_WHISPER_PATH to include one)."
fi

WHISPER_MODEL_SOURCE="${BUNDLED_WHISPER_MODEL_PATH:-}"
if [[ -n "$WHISPER_MODEL_SOURCE" && -f "$WHISPER_MODEL_SOURCE" ]]; then
  if should_refresh_bundle_item "$WHISPER_MODEL_SOURCE" "$APP_RESOURCES/profanity-model.bin"; then
    cp "$WHISPER_MODEL_SOURCE" "$APP_RESOURCES/profanity-model.bin"
    echo "Bundled Whisper model: $WHISPER_MODEL_SOURCE"
  else
    echo "Keeping existing bundled Whisper model."
  fi
else
  local_vendor_model=""
  if [[ -f "$ROOT_DIR/vendor/models/ggml-tiny.en.bin" ]]; then
    local_vendor_model="$ROOT_DIR/vendor/models/ggml-tiny.en.bin"
  else
    local_vendor_model="$(ls "$ROOT_DIR"/vendor/models/ggml-*.bin 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -n "$local_vendor_model" && -f "$local_vendor_model" ]]; then
    if should_refresh_bundle_item "$local_vendor_model" "$APP_RESOURCES/profanity-model.bin"; then
      cp "$local_vendor_model" "$APP_RESOURCES/profanity-model.bin"
      echo "Bundled Whisper model: $local_vendor_model"
    else
      echo "Keeping existing bundled Whisper model."
    fi
  else
    echo "Whisper model not bundled (set BUNDLED_WHISPER_MODEL_PATH or place a model in $ROOT_DIR/vendor/models)."
  fi
fi

echo "Built: $APP"
echo "Mode: $BUILD_MODE"
