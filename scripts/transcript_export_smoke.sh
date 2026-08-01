#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/transcript-export-smoke"
CORE_DIR="$OUTPUT_DIR/core"
mkdir -p "$CORE_DIR"

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
  -framework NaturalLanguage \
  -framework QuartzCore \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  "$ROOT_DIR/src/AppCoreTypes.swift" \
  "$ROOT_DIR/src/TranscriptLayoutUtilities.swift" \
  "$ROOT_DIR/src/TranscriptTableViews.swift" \
  "$ROOT_DIR/src/TranscriptUtilities.swift" \
  "$ROOT_DIR/scripts/transcript_export_smoke.swift" \
  -o "$OUTPUT_DIR/transcript-export-smoke"

DYLD_LIBRARY_PATH="$CORE_DIR" "$OUTPUT_DIR/transcript-export-smoke"
