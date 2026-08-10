#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/In-Out.app}"
BUILD_DIR="$ROOT_DIR/.build/media-framing-smoke"
MODULE_DIR="$BUILD_DIR/module"
FFMPEG="$APP_PATH/Contents/Resources/ffmpeg"
FFPROBE="$APP_PATH/Contents/Resources/ffprobe"

for required in "$FFMPEG" "$FFPROBE"; do
  if [[ ! -x "$required" ]]; then
    echo "Media framing smoke test failed: missing executable $required" >&2
    exit 1
  fi
done

mkdir -p "$MODULE_DIR"

xcrun swiftc \
  -parse-as-library \
  -emit-library \
  -emit-module \
  -module-name InOutCore \
  -emit-module-path "$MODULE_DIR/InOutCore.swiftmodule" \
  "$ROOT_DIR/src-core/MediaFraming.swift" \
  -o "$BUILD_DIR/libInOutCore.dylib"

xcrun swiftc \
  -I "$MODULE_DIR" \
  -L "$BUILD_DIR" \
  -lInOutCore \
  "$ROOT_DIR/scripts/media_framing_smoke.swift" \
  -o "$BUILD_DIR/media-framing-smoke"

DYLD_LIBRARY_PATH="$BUILD_DIR" "$BUILD_DIR/media-framing-smoke" "$FFMPEG" "$FFPROBE"
