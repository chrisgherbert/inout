#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT_DIR/vendor/ffmpeg/macos-arm64"
DEST_BIN="$DEST_DIR/ffmpeg"
DEST_SHA="$DEST_DIR/ffmpeg.sha256"

SOURCE="${1:-/opt/homebrew/bin/ffmpeg}"

if [[ ! -x "$SOURCE" ]]; then
  echo "ffmpeg executable not found: $SOURCE"
  echo "Usage: $(basename "$0") [/path/to/ffmpeg]"
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SOURCE" "$DEST_BIN"
chmod +x "$DEST_BIN"

SHA="$(shasum -a 256 "$DEST_BIN" | awk '{print $1}')"
echo "$SHA  ffmpeg" > "$DEST_SHA"

echo "Pinned ffmpeg:"
echo "  Binary:   $DEST_BIN"
echo "  Checksum: $DEST_SHA"
echo ""
echo "Release builds will now use this pinned ffmpeg by default."
