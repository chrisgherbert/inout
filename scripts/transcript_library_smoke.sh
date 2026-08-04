#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/transcript-library-smoke"
MODULE_DIR="$BUILD_DIR/module"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/inout-transcript-library-smoke.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$BUILD_DIR" "$MODULE_DIR"

xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -emit-library \
  -emit-module \
  -emit-module-path "$MODULE_DIR/InOutCore.swiftmodule" \
  -module-name InOutCore \
  "$ROOT_DIR/src-core/CoreFormatting.swift" \
  "$ROOT_DIR/src-core/CoreTypes.swift" \
  -o "$BUILD_DIR/libInOutCore.dylib"

xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -I "$MODULE_DIR" \
  -L "$BUILD_DIR" \
  -lInOutCore \
  -lsqlite3 \
  "$ROOT_DIR/src/TranscriptLibrary.swift" \
  "$ROOT_DIR/scripts/transcript_library_smoke.swift" \
  -o "$BUILD_DIR/transcript-library-smoke"

DYLD_LIBRARY_PATH="$BUILD_DIR" "$BUILD_DIR/transcript-library-smoke" "$TMP_DIR"
