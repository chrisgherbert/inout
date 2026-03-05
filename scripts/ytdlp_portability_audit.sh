#!/bin/zsh
set -euo pipefail

YTDLP_BIN="${1:-}"
if [[ -z "$YTDLP_BIN" ]]; then
  echo "Usage: $(basename "$0") /path/to/yt-dlp"
  exit 1
fi
if [[ ! -f "$YTDLP_BIN" ]]; then
  echo "yt-dlp binary missing: $YTDLP_BIN"
  exit 1
fi
if [[ ! -x "$YTDLP_BIN" ]]; then
  echo "yt-dlp is not executable: $YTDLP_BIN"
  exit 1
fi

if strings -a "$YTDLP_BIN" 2>/dev/null | grep -q "_MEIXXXX"; then
  echo "ERROR: yt-dlp appears to be a PyInstaller onefile build."
  echo "This variant is not reliable under hardened-runtime notarized app bundles"
  echo "and can fail at runtime with:"
  echo "  Failed to load Python shared library .../_MEI.../Python"
  echo ""
  echo "Use the official script-style yt-dlp asset instead:"
  echo "  https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"
  exit 1
fi

first_line="$(head -n 1 "$YTDLP_BIN" 2>/dev/null || true)"
if [[ "$first_line" == '#!'* ]]; then
  interpreter="${first_line#\#!}"
  if [[ "$interpreter" == /opt/homebrew/* || "$interpreter" == /usr/local/* ]]; then
    echo "ERROR: yt-dlp shebang uses non-portable interpreter:"
    echo "  $interpreter"
    echo ""
    echo "Use a standalone yt-dlp binary or rewrite shebang to /usr/bin/env python3."
    exit 1
  fi
fi

echo "yt-dlp portability audit passed."
