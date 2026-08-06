#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/timecode-preset-smoke"
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
  -framework Combine \
  -framework SwiftUI \
  "$ROOT_DIR/src/AppCoreTypes.swift" \
  "$ROOT_DIR/src/TimecodePresetStore.swift" \
  "$ROOT_DIR/scripts/timecode_preset_smoke.swift" \
  -o "$OUTPUT_DIR/timecode-preset-smoke"

DYLD_LIBRARY_PATH="$CORE_DIR" "$OUTPUT_DIR/timecode-preset-smoke"
