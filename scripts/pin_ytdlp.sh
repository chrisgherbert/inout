#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT_DIR/vendor/yt-dlp/macos-arm64"
DEST_BIN="$DEST_DIR/yt-dlp"
DEST_SHA="$DEST_DIR/yt-dlp.sha256"
OFFICIAL_YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"

SOURCE="${1:-}"

mkdir -p "$DEST_DIR"

if [[ -z "$SOURCE" ]]; then
  echo "Downloading official script-style yt-dlp..."
  curl -fL "$OFFICIAL_YTDLP_URL" -o "$DEST_BIN"
else
  if [[ ! -f "$SOURCE" ]]; then
    echo "yt-dlp file not found: $SOURCE"
    echo "Usage: $(basename "$0") [/path/to/yt-dlp]"
    exit 1
  fi
  SOURCE_REAL="$(cd "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE")"
  DEST_REAL="$(cd "$(dirname "$DEST_BIN")" && pwd)/$(basename "$DEST_BIN")"
  if [[ "$SOURCE_REAL" != "$DEST_REAL" ]]; then
    cp "$SOURCE" "$DEST_BIN"
  fi
fi
chmod +x "$DEST_BIN"

SHA="$(shasum -a 256 "$DEST_BIN" | awk '{print $1}')"
echo "$SHA  yt-dlp" > "$DEST_SHA"

if ! "$ROOT_DIR/scripts/ytdlp_portability_audit.sh" "$DEST_BIN"; then
  echo ""
  echo "WARNING: pinned yt-dlp may not be portable across machines."
  echo "It may work locally but fail on other Macs."
fi

echo "Pinned yt-dlp:"
echo "  Binary:   $DEST_BIN"
echo "  Checksum: $DEST_SHA"
echo ""
echo "Release builds will now use this pinned yt-dlp by default."
