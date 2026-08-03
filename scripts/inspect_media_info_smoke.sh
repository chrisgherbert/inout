#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/inspect-media-info-smoke"
MEDIA_PATH="$BUILD_DIR/offset.mp4"
RUNNER_PATH="$BUILD_DIR/inspect-media-info-smoke"

mkdir -p "$BUILD_DIR"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=320x180:rate=30:duration=2 \
  -itsoffset 0.25 -f lavfi -i sine=frequency=1000:sample_rate=48000:duration=1.5 \
  -map 0:v -map 1:a \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest \
  "$MEDIA_PATH"

xcrun swiftc \
  -framework AVFoundation \
  "$ROOT_DIR/src/MediaInspectionUtilities.swift" \
  "$ROOT_DIR/scripts/inspect_media_info_smoke.swift" \
  -o "$RUNNER_PATH"

"$RUNNER_PATH" "$MEDIA_PATH"
