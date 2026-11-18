#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/transcript-cleanup-smoke"
MODULE_DIR="$BUILD_DIR/module"
mkdir -p "$MODULE_DIR"
xcrun swiftc -target arm64-apple-macos14.0 -parse-as-library \
  -emit-library -emit-module -emit-module-path "$MODULE_DIR/InOutCore.swiftmodule" -module-name InOutCore \
  "$ROOT_DIR/src-core/CoreFormatting.swift" "$ROOT_DIR/src-core/CoreTypes.swift" \
  "$ROOT_DIR/src-core/CaptionFormatting.swift" -o "$BUILD_DIR/libInOutCore.dylib"
xcrun swiftc -target arm64-apple-macos14.0 -parse-as-library \
  -I "$MODULE_DIR" -L "$BUILD_DIR" -lInOutCore \
  "$ROOT_DIR/src/TranscriptCleanup.swift" "$ROOT_DIR/src/TranscriptCleanupExecution.swift" \
  "$ROOT_DIR/src/TranscriptCleanupSession.swift" \
  "$ROOT_DIR/src/TranscriptCleanupPhrases.swift" "$ROOT_DIR/src/TranscriptCleanupSimilarity.swift" \
  "$ROOT_DIR/scripts/transcript_cleanup_smoke.swift" \
  -o "$BUILD_DIR/transcript-cleanup-smoke"
DYLD_LIBRARY_PATH="$BUILD_DIR" "$BUILD_DIR/transcript-cleanup-smoke"
