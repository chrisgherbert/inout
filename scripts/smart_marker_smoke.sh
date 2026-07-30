#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/smart-marker-smoke"
mkdir -p "$OUTPUT_DIR"

xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -Xlinker -weak_framework \
  -Xlinker FoundationModels \
  -framework Security \
  "$ROOT_DIR/src/SecureCredentialStore.swift" \
  "$ROOT_DIR/src/SmartMarkerProviders.swift" \
  "$ROOT_DIR/src/SmartMarkerCloudProviders.swift" \
  "$ROOT_DIR/src/SmartMarkerAnalysis.swift" \
  "$ROOT_DIR/src/SmartMarkerRecipeStore.swift" \
  "$ROOT_DIR/scripts/smart_marker_smoke.swift" \
  -o "$OUTPUT_DIR/smart-marker-smoke"

"$OUTPUT_DIR/smart-marker-smoke" "$@"
