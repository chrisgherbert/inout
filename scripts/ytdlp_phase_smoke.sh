#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/ytdlp-phase-smoke"
CORE_DIR="$BUILD_DIR/core"
EXECUTABLE="$BUILD_DIR/ytdlp-phase-smoke"

mkdir -p "$CORE_DIR"

xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -emit-library \
  -emit-module \
  -module-name InOutCore \
  -emit-module-path "$CORE_DIR/InOutCore.swiftmodule" \
  "$ROOT_DIR/src-core/YTDLPDownloadPhase.swift" \
  -o "$CORE_DIR/libInOutCore.dylib"

xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -I "$CORE_DIR" \
  -L "$CORE_DIR" \
  -lInOutCore \
  "$ROOT_DIR/scripts/ytdlp_phase_smoke.swift" \
  -o "$EXECUTABLE"

DYLD_LIBRARY_PATH="$CORE_DIR" "$EXECUTABLE"
