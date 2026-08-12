#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/fast-export-range-smoke"
SOURCE_PATH="$BUILD_DIR/source.mp4"
OUTPUT_PATH="$BUILD_DIR/output.mp4"
LATER_OUTPUT_PATH="$BUILD_DIR/output.later.mp4"
RUNNER_PATH="$BUILD_DIR/fast-export-range-smoke"
FFMPEG="${FFMPEG:-$ROOT_DIR/vendor/ffmpeg/macos-arm64/ffmpeg}"

mkdir -p "$BUILD_DIR"

"$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=30000/1001:duration=8" \
  -f lavfi -i "sine=frequency=997:sample_rate=48000:duration=8" \
  -c:v libx264 -preset fast -g 120 -keyint_min 120 -sc_threshold 0 -bf 3 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -shortest \
  "$SOURCE_PATH"

xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -framework AVFoundation \
  -framework CoreGraphics \
  -framework CoreMedia \
  "$ROOT_DIR/src/FastExportUtilities.swift" \
  "$ROOT_DIR/scripts/fast_export_range_smoke.swift" \
  -o "$RUNNER_PATH"

"$RUNNER_PATH" "$SOURCE_PATH" "$OUTPUT_PATH"

first_frame_hash() {
  "$FFMPEG" -hide_banner -loglevel error "$@" \
    -map 0:v:0 -frames:v 1 -f framehash -hash md5 - \
    | awk -F',' '!/^#/ {gsub(/[[:space:]]/, "", $6); print $6; exit}'
}

SOURCE_FIRST_HASH="$(first_frame_hash -i "$SOURCE_PATH")"
OUTPUT_PHYSICAL_FIRST_HASH="$(first_frame_hash -ignore_editlist 1 -i "$OUTPUT_PATH")"
if [[ -z "$SOURCE_FIRST_HASH" || "$OUTPUT_PHYSICAL_FIRST_HASH" != "$SOURCE_FIRST_HASH" ]]; then
  echo "Fast export range smoke test failed: physical output does not begin on the preceding sync frame." >&2
  exit 1
fi

LATER_SOURCE_SYNC_HASH="$(first_frame_hash -ss 4.004 -i "$SOURCE_PATH")"
LATER_OUTPUT_PHYSICAL_FIRST_HASH="$(first_frame_hash -ignore_editlist 1 -i "$LATER_OUTPUT_PATH")"
if [[ -z "$LATER_SOURCE_SYNC_HASH" || "$LATER_OUTPUT_PHYSICAL_FIRST_HASH" != "$LATER_SOURCE_SYNC_HASH" ]]; then
  echo "Fast export range smoke test failed: later output does not physically begin on its nearest sync frame." >&2
  exit 1
fi
