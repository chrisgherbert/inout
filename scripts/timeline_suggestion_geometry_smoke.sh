#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/timeline-suggestion-geometry-smoke"
mkdir -p "$OUTPUT_DIR"

xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -framework AppKit \
  -framework QuartzCore \
  "$ROOT_DIR/src/TimelineSuggestionLayout.swift" \
  "$ROOT_DIR/scripts/timeline_suggestion_geometry_smoke.swift" \
  -o "$OUTPUT_DIR/timeline-suggestion-geometry-smoke"

"$OUTPUT_DIR/timeline-suggestion-geometry-smoke"
