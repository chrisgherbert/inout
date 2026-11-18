#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/transcript-sidebar-smoke"
CORE_DIR="$OUTPUT_DIR/core"
mkdir -p "$CORE_DIR"
SPARKLE_DIR="$($ROOT_DIR/scripts/fetch_sparkle.sh)"
xcrun swiftc -target arm64-apple-macos14.0 -emit-library -emit-module -module-name InOutCore \
  -emit-module-path "$CORE_DIR/InOutCore.swiftmodule" \
  -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  "$ROOT_DIR"/src-core/*.swift -o "$CORE_DIR/libInOutCore.dylib"
SOURCES=("$ROOT_DIR"/src/*.swift)
SOURCES=("${(@)SOURCES:#*/AppEntry.swift}")
xcrun swiftc -target arm64-apple-macos14.0 -parse-as-library -Onone \
  -I "$CORE_DIR" -L "$CORE_DIR" -lInOutCore -F "$SPARKLE_DIR" \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework CoreVideo \
  -framework CoreMedia -framework Foundation -framework Security -framework Sparkle -lsqlite3 \
  -Xlinker -rpath -Xlinker "$SPARKLE_DIR" \
  -Xlinker -weak_framework -Xlinker FoundationModels \
  "${SOURCES[@]}" "$ROOT_DIR/scripts/transcript_sidebar_smoke.swift" \
  -o "$OUTPUT_DIR/transcript-sidebar-smoke"
INOUT_SKIP_KEYCHAIN=1 DYLD_LIBRARY_PATH="$CORE_DIR" "$OUTPUT_DIR/transcript-sidebar-smoke" "$@"
