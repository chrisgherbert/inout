#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/video-export-encoding-smoke"
CORE_DIR="$OUTPUT_DIR/core"
FFMPEG="${FFMPEG:-$ROOT_DIR/vendor/ffmpeg/macos-arm64/ffmpeg}"
mkdir -p "$CORE_DIR" "$OUTPUT_DIR/renders"

xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -emit-library \
  -emit-module \
  -module-name InOutCore \
  -emit-module-path "$CORE_DIR/InOutCore.swiftmodule" \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework CoreVideo \
  "$ROOT_DIR"/src-core/*.swift \
  -o "$CORE_DIR/libInOutCore.dylib"

xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -I "$CORE_DIR" \
  -L "$CORE_DIR" \
  -lInOutCore \
  -framework AppKit \
  -framework AVFoundation \
  -framework Combine \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  "$ROOT_DIR/src/AppCoreTypes.swift" \
  "$ROOT_DIR/src/VideoExportEncodingPolicy.swift" \
  "$ROOT_DIR/scripts/video_export_encoding_smoke.swift" \
  -o "$OUTPUT_DIR/video-export-encoding-smoke"

DYLD_LIBRARY_PATH="$CORE_DIR" "$OUTPUT_DIR/video-export-encoding-smoke"

if [[ ! -x "$FFMPEG" ]]; then
  echo "Video export encoding smoke test requires ffmpeg: $FFMPEG" >&2
  exit 1
fi

render() {
  local name="$1"
  local extension="$2"
  shift 2
  "$FFMPEG" \
    -y \
    -hide_banner \
    -loglevel error \
    -f lavfi \
    -i "testsrc2=size=320x180:rate=30:duration=0.35" \
    -an \
    "$@" \
    -pix_fmt yuv420p \
    -b:v 500k \
    "$OUTPUT_DIR/renders/$name.$extension"
}

render h264-hardware mp4 \
  -c:v h264_videotoolbox -prio_speed true
render hevc-hardware mov \
  -c:v hevc_videotoolbox -prio_speed true
render h264-balanced mp4 \
  -c:v libx264 -preset veryfast
render hevc-balanced mov \
  -c:v libx265 -preset faster
render vp9-fast webm \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 7 -row-mt 1
render vp9-balanced webm \
  -c:v libvpx-vp9 -deadline good -cpu-used 5 -row-mt 1
render webm-caption-stage mkv \
  -c:v h264_videotoolbox
"$FFMPEG" \
  -y \
  -hide_banner \
  -loglevel error \
  -i "$OUTPUT_DIR/renders/webm-caption-stage.mkv" \
  -an \
  -c:v libvpx-vp9 \
  -deadline good \
  -cpu-used 5 \
  -row-mt 1 \
  -pix_fmt yuv420p \
  -b:v 500k \
  "$OUTPUT_DIR/renders/webm-caption-final.webm"

echo "Video export encoder launch smoke test passed."
