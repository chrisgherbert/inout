#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/caption-formatting-smoke"
MODULE_DIR="$BUILD_DIR/module"

mkdir -p "$MODULE_DIR"

xcrun swiftc \
  -parse-as-library \
  -emit-library \
  -emit-module \
  -module-name InOutCore \
  -emit-module-path "$MODULE_DIR/InOutCore.swiftmodule" \
  "$ROOT_DIR/src-core/CoreFormatting.swift" \
  "$ROOT_DIR/src-core/CoreTypes.swift" \
  "$ROOT_DIR/src-core/CaptionFormatting.swift" \
  -o "$BUILD_DIR/libInOutCore.dylib"

xcrun swiftc \
  -I "$MODULE_DIR" \
  -L "$BUILD_DIR" \
  -lInOutCore \
  "$ROOT_DIR/scripts/caption_formatting_smoke.swift" \
  -o "$BUILD_DIR/caption-formatting-smoke"

DYLD_LIBRARY_PATH="$BUILD_DIR" "$BUILD_DIR/caption-formatting-smoke"
