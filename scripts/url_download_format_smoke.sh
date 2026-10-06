#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/url-download-format-smoke"
EXECUTABLE="$BUILD_DIR/url-download-format-smoke"
YTDLP_BIN="${YTDLP_BIN:-$ROOT_DIR/vendor/yt-dlp/macos-arm64/yt-dlp}"

if [[ ! -x "$YTDLP_BIN" ]]; then
  echo "ERROR: yt-dlp is required for the URL download format smoke test" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"

xcrun swiftc \
  -parse-as-library \
  "$ROOT_DIR/src/URLDownloadUtilities.swift" \
  "$ROOT_DIR/scripts/url_download_format_smoke.swift" \
  -framework AppKit \
  -framework Foundation \
  -o "$EXECUTABLE"

"$EXECUTABLE" "$YTDLP_BIN"
