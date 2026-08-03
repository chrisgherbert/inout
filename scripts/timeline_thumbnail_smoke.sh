#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/timeline-thumbnail-smoke"
FFMPEG="${FFMPEG:-$(command -v ffmpeg)}"
mkdir -p "$OUTPUT_DIR"

"$FFMPEG" -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=30:duration=12" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  "$OUTPUT_DIR/source.mp4"

xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -framework AVFoundation \
  -framework CoreGraphics \
  -framework CoreMedia \
  "$ROOT_DIR/src/TimelineThumbnailUtilities.swift" \
  "$ROOT_DIR/scripts/timeline_thumbnail_smoke.swift" \
  -o "$OUTPUT_DIR/timeline-thumbnail-smoke"

"$OUTPUT_DIR/timeline-thumbnail-smoke" "$OUTPUT_DIR/source.mp4"
