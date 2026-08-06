#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/timecode-display-smoke"
EXECUTABLE="$BUILD_DIR/timecode-display-smoke"

mkdir -p "$BUILD_DIR"
xcrun swiftc \
  "$ROOT_DIR/src-core/CoreFormatting.swift" \
  "$ROOT_DIR/scripts/timecode-display-smoke/main.swift" \
  -o "$EXECUTABLE"
"$EXECUTABLE"
