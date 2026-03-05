#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/In-Out.app"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--refresh-tools] [--verify-tools] [--run]

Fast local iteration build:
  - Uses quick build mode
  - Preserves bundled ffmpeg/yt-dlp/whisper/model by default
  - Skips signing/notarization/release

Options:
  --refresh-tools  Re-copy bundled ffmpeg/yt-dlp/whisper/model into app resources
  --verify-tools   Run dependency audits on bundled ffmpeg + whisper in dist app
  --run            Launch built app after successful build
USAGE
}

REFRESH_TOOLS=0
VERIFY_TOOLS=0
RUN_APP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --refresh-tools) REFRESH_TOOLS=1 ;;
    --verify-tools) VERIFY_TOOLS=1 ;;
    --run) RUN_APP=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

cd "$ROOT_DIR"

echo "Building quick (fast iteration)..."
REFRESH_BUNDLED_TOOLS="$REFRESH_TOOLS" ./scripts/build_app.sh quick

if [[ "$VERIFY_TOOLS" -eq 1 ]]; then
  echo "Verifying bundled tool portability..."
  ./scripts/ffmpeg_dependency_audit.sh "$APP_PATH/Contents/Resources/ffmpeg"
  ./scripts/ytdlp_portability_audit.sh "$APP_PATH/Contents/Resources/yt-dlp"
  ./scripts/whisper_dependency_audit.sh "$APP_PATH"
  if [[ ! -x "$APP_PATH/Contents/Resources/yt-dlp" ]]; then
    echo "Missing bundled yt-dlp: $APP_PATH/Contents/Resources/yt-dlp"
    exit 1
  fi
  "$APP_PATH/Contents/Resources/yt-dlp" --version >/dev/null
fi

if [[ "$RUN_APP" -eq 1 ]]; then
  echo "Launching app..."
  open "$APP_PATH"
fi

echo "Done: $APP_PATH"
