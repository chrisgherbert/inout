#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT_DIR/vendor/ffmpeg/macos-arm64"
DEST_BIN="$DEST_DIR/ffmpeg"
DEST_SHA="$DEST_DIR/ffmpeg.sha256"
DEST_PROBE="$DEST_DIR/ffprobe"
DEST_PROBE_SHA="$DEST_DIR/ffprobe.sha256"

SOURCE="${1:-/opt/homebrew/bin/ffmpeg}"
PROBE_SOURCE="${2:-}"
if [[ -z "$PROBE_SOURCE" ]]; then
  PROBE_SOURCE="$(cd "$(dirname "$SOURCE")" && pwd)/ffprobe"
fi

if [[ ! -x "$SOURCE" ]]; then
  echo "ffmpeg executable not found: $SOURCE"
  echo "Usage: $(basename "$0") [/path/to/ffmpeg] [/path/to/ffprobe]"
  exit 1
fi

if [[ ! -x "$PROBE_SOURCE" ]]; then
  echo "ffprobe executable not found: $PROBE_SOURCE"
  echo "Usage: $(basename "$0") [/path/to/ffmpeg] [/path/to/ffprobe]"
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SOURCE" "$DEST_BIN"
chmod +x "$DEST_BIN"
cp "$PROBE_SOURCE" "$DEST_PROBE"
chmod +x "$DEST_PROBE"

SHA="$(shasum -a 256 "$DEST_BIN" | awk '{print $1}')"
echo "$SHA  ffmpeg" > "$DEST_SHA"
PROBE_SHA="$(shasum -a 256 "$DEST_PROBE" | awk '{print $1}')"
echo "$PROBE_SHA  ffprobe" > "$DEST_PROBE_SHA"

if ! "$ROOT_DIR/scripts/ffmpeg_dependency_audit.sh" "$DEST_BIN"; then
  echo ""
  echo "WARNING: pinned ffmpeg is not portable across machines."
  echo "It may work locally but fail on other Macs."
fi
if ! "$ROOT_DIR/scripts/ffmpeg_dependency_audit.sh" "$DEST_PROBE"; then
  echo ""
  echo "WARNING: pinned ffprobe is not portable across machines."
fi

echo "Pinned ffmpeg:"
echo "  Binary:   $DEST_BIN"
echo "  Checksum: $DEST_SHA"
echo "Pinned ffprobe:"
echo "  Binary:   $DEST_PROBE"
echo "  Checksum: $DEST_PROBE_SHA"
echo ""
echo "Release builds will now use these pinned ffmpeg/ffprobe binaries by default."
